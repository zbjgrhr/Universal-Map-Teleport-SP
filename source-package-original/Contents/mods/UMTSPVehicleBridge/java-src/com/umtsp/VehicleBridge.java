package com.umtsp;

import java.util.ArrayList;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;
import org.joml.Vector3f;
import se.krka.kahlua.integration.annotations.LuaMethod;
import zombie.characters.IsoPlayer;
import zombie.characters.animals.IsoAnimal;
import zombie.core.physics.Transform;
import zombie.core.physics.WorldSimulation;
import zombie.core.raknet.UdpConnection;
import zombie.iso.IsoChunk;
import zombie.iso.IsoGridSquare;
import zombie.iso.IsoWorld;
import zombie.iso.SpriteDetails.IsoFlagType;
import zombie.network.GameClient;
import zombie.network.GameServer;
import zombie.network.PacketTypes;
import zombie.network.ServerMap;
import zombie.network.packets.INetworkPacket;
import zombie.vehicles.BaseVehicle;

/** Vehicle movement bridge for B42.21. All mutations happen on the SP host or MP server. */
public final class VehicleBridge {
    private static final Object MOVE_LOCK = new Object();

    private VehicleBridge() {}

    private static IsoGridSquare squareAt(int x, int y) {
        if (GameServer.server) return ServerMap.instance.getGridSquare(x, y, 0);
        return IsoWorld.instance.currentCell.getGridSquare(x, y, 0);
    }

    private static boolean clearForVehicle(int x, int y, int radius) {
        for (int dx = -radius; dx <= radius; dx++) {
            for (int dy = -radius; dy <= radius; dy++) {
                IsoGridSquare square = squareAt(x + dx, y + dy);
                if (square == null || square.getFloor() == null || !square.isFree(false) ||
                    square.getFloor().getSprite() == null ||
                    square.getFloor().getSprite().getProperties().has(IsoFlagType.water)) return false;
            }
        }
        return true;
    }

    private static List<BaseVehicle> towingChain(BaseVehicle lead) {
        if (lead == null || lead.getVehicleTowedBy() != null) return null;
        List<BaseVehicle> chain = new ArrayList<>();
        Set<BaseVehicle> seen = Collections.newSetFromMap(new IdentityHashMap<>());
        BaseVehicle current = lead;
        while (current != null) {
            if (chain.size() >= 32 || !seen.add(current) || current.getScript() == null ||
                    current.getZ() > 0.5f || current.getCurrentAbsoluteSpeedKmHour() > 1.0f ||
                    (current != lead && current.hasPassenger())) return null;
            chain.add(current);
            BaseVehicle next = current.getVehicleTowing();
            if (next != null && next.getVehicleTowedBy() != current) return null;
            current = next;
        }
        return chain;
    }

    private static int vehicleRadius(BaseVehicle vehicle) {
        Vector3f extents = vehicle.getScript() == null ? null : vehicle.getScript().getExtents();
        if (extents == null) return -1;
        int radius = Math.max(2, (int)Math.ceil(Math.max(extents.x, extents.z) / 2f) + 1);
        return radius <= 16 ? radius : -1;
    }

    private static void moveOne(BaseVehicle vehicle, float x, float y, IsoGridSquare square) {
        vehicle.setNetPlayerAuthorization(BaseVehicle.Authorization.Server, -1);
        vehicle.lockServerUpdate(0L);
        vehicle.jniLinearVelocity.set(0f, 0f, 0f);
        vehicle.throttle = 0f;
        vehicle.setEngineSpeed(0.0);
        vehicle.shutOff();
        Transform transform = new Transform();
        vehicle.getWorldTransform(transform);
        transform.origin.set(x - WorldSimulation.instance.offsetX, 0f,
                y - WorldSimulation.instance.offsetY);
        vehicle.setWorldTransform(transform);
        vehicle.setX(x);
        vehicle.setY(y);
        vehicle.setZ(0f);
        vehicle.setCurrent(square);
        IsoChunk origin = vehicle.chunk;
        IsoChunk destination = square.chunk;
        if (origin != destination) {
            synchronized (destination) {
                if (!destination.vehicles.contains(vehicle)) destination.vehicles.add(vehicle);
            }
            vehicle.chunk = destination;
            if (origin != null) {
                synchronized (origin) { origin.vehicles.remove(vehicle); }
            }
        }
        if (GameServer.server) {
            for (int i = 0; i < GameServer.udpEngine.connections.size(); i++) {
                UdpConnection connection = GameServer.udpEngine.connections.get(i);
                if (connection.vehicleStates.containsKey(vehicle.getId())) {
                    INetworkPacket.send(connection, PacketTypes.PacketType.VehicleRemove, vehicle);
                    connection.vehicleStates.remove(vehicle.getId());
                }
            }
            vehicle.updateFlags = (short)(vehicle.updateFlags | 3);
        }
        for (IsoAnimal animal : vehicle.getAnimals()) {
            if (animal == null) continue;
            animal.setX(vehicle.getX());
            animal.setY(vehicle.getY());
            animal.setZ(vehicle.getZ());
            if (GameServer.server) animal.sendExtraUpdateToClients();
        }
    }

    @LuaMethod(name = "umtspExitVehicle", global = true)
    public static boolean exitVehicle(IsoPlayer player, BaseVehicle vehicle) {
        if (GameClient.client || player == null || vehicle == null || player.getVehicle() != vehicle)
            return false;
        int seat = vehicle.getSeat(player);
        if (seat < 0 || towingChain(vehicle) == null) return false;
        for (int i = 0; i < vehicle.getMaxPassengers(); i++) {
            if (i != seat && vehicle.getCharacter(i) != null) return false;
        }
        if (!vehicle.exit(player)) return false;
        if (GameServer.server) {
            if (seat == 0) vehicle.authorizationServerOnSeat(player, false);
            INetworkPacket.sendToAll(PacketTypes.PacketType.VehicleExit, vehicle, player, seat);
        }
        return true;
    }

    @LuaMethod(name = "umtspMoveVehicle", global = true)
    public static boolean moveVehicle(BaseVehicle vehicle, int x, int y) {
        if (GameClient.client || WorldSimulation.instance == null ||
                vehicle == null || vehicle.hasPassenger()) return false;
        List<BaseVehicle> chain = towingChain(vehicle);
        if (chain == null) return false;
        if (GameServer.server) {
            if (ServerMap.instance == null || GameServer.udpEngine == null) return false;
        } else {
            if (IsoWorld.instance == null || IsoWorld.instance.currentCell == null) return false;
        }
        int[] radii = new int[chain.size()];
        int distance = 0;
        for (int i = 0; i < chain.size(); i++) {
            BaseVehicle member = chain.get(i);
            radii[i] = vehicleRadius(member);
            if (radii[i] < 0) return false;
            int reach = (int)Math.ceil(Math.max(Math.abs(member.getX() - vehicle.getX()),
                    Math.abs(member.getY() - vehicle.getY()))) + radii[i];
            distance = Math.max(distance, reach);
        }
        distance += 3;
        int[][] offsets = {{distance, 0}, {-distance, 0}, {0, distance}, {0, -distance},
            {distance, distance}, {-distance, distance}, {distance, -distance}, {-distance, -distance}};
        IsoGridSquare[] squares = null;
        float[] newX = null, newY = null;
        for (int[] offset : offsets) {
            int cx = x + offset[0], cy = y + offset[1];
            IsoGridSquare[] candidateSquares = new IsoGridSquare[chain.size()];
            float[] candidateX = new float[chain.size()], candidateY = new float[chain.size()];
            boolean valid = true;
            for (int i = 0; i < chain.size(); i++) {
                BaseVehicle member = chain.get(i);
                candidateX[i] = cx + 0.5f + (member.getX() - vehicle.getX());
                candidateY[i] = cy + 0.5f + (member.getY() - vehicle.getY());
                int tx = (int)Math.floor(candidateX[i]), ty = (int)Math.floor(candidateY[i]);
                if (!clearForVehicle(tx, ty, radii[i])) { valid = false; break; }
                candidateSquares[i] = squareAt(tx, ty);
                if (candidateSquares[i] == null || candidateSquares[i].chunk == null) {
                    valid = false; break;
                }
            }
            if (!valid) continue;
            squares = candidateSquares;
            newX = candidateX;
            newY = candidateY;
            break;
        }
        if (squares == null) return false;
        synchronized (MOVE_LOCK) {
            if (towingChain(vehicle) == null) return false;
            for (int i = 0; i < chain.size(); i++) {
                moveOne(chain.get(i), newX[i], newY[i], squares[i]);
            }
            return true;
        }
    }
}
