package com.umtsp;

import java.util.ArrayList;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Set;
import org.joml.Vector3f;
import se.krka.kahlua.integration.annotations.LuaMethod;
import zombie.characters.IsoPlayer;
import zombie.characters.IsoGameCharacter;
import zombie.characters.animals.IsoAnimal;
import zombie.core.physics.Transform;
import zombie.core.physics.WorldSimulation;
import zombie.core.raknet.UdpConnection;
import zombie.debug.DebugLog;
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
import zombie.vehicles.VehiclesDB2;

/** Vehicle movement bridge for B42.21. All mutations happen on the SP host or MP server. */
public final class VehicleBridge {
    private static final Object MOVE_LOCK = new Object();
    private static final IdentityHashMap<IsoPlayer, List<SeatState>> EXITED_SEATS = new IdentityHashMap<>();
    private static volatile String lastError = "";

    private static final class SeatState {
        final BaseVehicle vehicle;
        final int seat;
        final IsoGameCharacter character;

        SeatState(BaseVehicle vehicle, int seat, IsoGameCharacter character) {
            this.vehicle = vehicle;
            this.seat = seat;
            this.character = character;
        }
    }

    private VehicleBridge() {}

    private static IsoGridSquare squareAt(int x, int y) {
        if (GameServer.server) return ServerMap.instance.getGridSquare(x, y, 0);
        return IsoWorld.instance.currentCell.getGridSquare(x, y, 0);
    }

    private static boolean fail(String reason) {
        lastError = reason;
        DebugLog.log("[UMTSP] vehicle: " + reason);
        return false;
    }

    private static boolean usableGround(IsoGridSquare square) {
        return square != null && square.getFloor() != null && square.isFree(false) &&
                square.getFloor().getSprite() != null &&
                !square.getFloor().getSprite().getProperties().has(IsoFlagType.water);
    }

    // B42 physics disables vehicle simulation without the surrounding 8-tile
    // chunks. A single loaded landing square is not enough for a stable move.
    private static boolean physicsAreaReady(float x, float y) {
        if (GameServer.server) return true;
        int cx = (int)Math.floor(x) / 8, cy = (int)Math.floor(y) / 8;
        for (int dx = -1; dx <= 1; dx++)
            for (int dy = -1; dy <= 1; dy++) {
                IsoChunk chunk = IsoWorld.instance.currentCell.getChunk(cx + dx, cy + dy);
                if (chunk == null || !chunk.loaded) return false;
            }
        return true;
    }

    /** Test the vehicle's rotated rectangular footprint instead of a large square. */
    private static boolean clearForVehicle(BaseVehicle vehicle, float centerX, float centerY) {
        Vector3f extents = vehicle.getScript() == null ? null : vehicle.getScript().getExtents();
        if (extents == null) return false;

        Vector3f origin = vehicle.getWorldPos(0f, 0f, 0f, new Vector3f());
        Vector3f xPoint = vehicle.getWorldPos(1f, 0f, 0f, new Vector3f());
        Vector3f zPoint = vehicle.getWorldPos(0f, 0f, 1f, new Vector3f());
        float ux = xPoint.x - origin.x, uy = xPoint.y - origin.y;
        float vx = zPoint.x - origin.x, vy = zPoint.y - origin.y;
        float uLength = (float)Math.sqrt(ux * ux + uy * uy);
        float vLength = (float)Math.sqrt(vx * vx + vy * vy);
        if (uLength < 0.01f || vLength < 0.01f) return false;
        ux /= uLength; uy /= uLength;
        vx /= vLength; vy /= vLength;

        float halfX = extents.x / 2f + 0.35f;
        float halfZ = extents.z / 2f + 0.35f;
        int bound = (int)Math.ceil(Math.sqrt(halfX * halfX + halfZ * halfZ)) + 1;
        boolean checked = false;
        for (int tx = (int)Math.floor(centerX) - bound; tx <= (int)Math.floor(centerX) + bound; tx++) {
            for (int ty = (int)Math.floor(centerY) - bound; ty <= (int)Math.floor(centerY) + bound; ty++) {
                float dx = tx + 0.5f - centerX;
                float dy = ty + 0.5f - centerY;
                float localX = dx * ux + dy * uy;
                float localZ = dx * vx + dy * vy;
                if (Math.abs(localX) > halfX || Math.abs(localZ) > halfZ) continue;
                checked = true;
                if (!usableGround(squareAt(tx, ty))) return false;
            }
        }
        return checked && physicsAreaReady(centerX, centerY);
    }

    private static List<BaseVehicle> towingChain(BaseVehicle lead) {
        if (lead == null) {
            fail("No vehicle was supplied.");
            return null;
        }
        if (lead.getVehicleTowedBy() != null) {
            fail("Start the teleport from the first vehicle in the towing chain.");
            return null;
        }
        List<BaseVehicle> chain = new ArrayList<>();
        Set<BaseVehicle> seen = Collections.newSetFromMap(new IdentityHashMap<>());
        BaseVehicle current = lead;
        while (current != null) {
            if (chain.size() >= 32) {
                fail("The towing chain exceeds the 32-vehicle safety limit.");
                return null;
            }
            if (!seen.add(current)) {
                fail("The towing chain contains a loop.");
                return null;
            }
            if (current.getScript() == null || current.getZ() > 0.5f) {
                fail("A vehicle in the towing chain has no supported ground vehicle definition.");
                return null;
            }
            if (current.getCurrentAbsoluteSpeedKmHour() > 1.0f) {
                fail("Stop every vehicle in the towing chain before teleporting.");
                return null;
            }
            chain.add(current);
            BaseVehicle next = current.getVehicleTowing();
            if (next != null && next.getVehicleTowedBy() != current) {
                fail("The towing connection is inconsistent.");
                return null;
            }
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
        // Return to the original ground-level transform used by the working
        // vehicle bridge. The loaded body's old height can be stale.
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
        // Streaming the origin out calls BaseVehicle.removeFromWorld(). Moving
        // its coordinates alone does not make it render or recreate its Bullet
        // body. Add the same object back after assigning the destination.
        if (!vehicle.addedToWorld || vehicle.isRemovedFromWorld()) {
            vehicle.addToWorld();
        }
        // A vehicle whose origin streamed out remains marked unloaded/static.
        // Re-evaluate it after assigning the loaded destination chunk.
        vehicle.checkSurroundingChunks();
        vehicle.setPhysicsActive(true);
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

    private static void persistVehicles(List<BaseVehicle> chain) {
        if (VehiclesDB2.instance == null) return;
        for (BaseVehicle member : chain) {
            VehiclesDB2.instance.setVehicleLoaded(member);
            VehiclesDB2.instance.updateVehicle(member);
        }
        VehiclesDB2.instance.setForceSave();
    }

    @LuaMethod(name = "umtspPersistVehicle", global = true)
    public static void persistVehicle(BaseVehicle vehicle) {
        if (GameClient.client || vehicle == null) return;
        List<BaseVehicle> chain = towingChain(vehicle);
        if (chain != null) persistVehicles(chain);
    }

    @LuaMethod(name = "umtspVehicleDiagnostics", global = true)
    public static String vehicleDiagnostics(BaseVehicle vehicle) {
        if (vehicle == null) return "vehicle missing";
        Transform transform = new Transform();
        vehicle.getWorldTransform(transform);
        float physicsX = transform.origin.x + WorldSimulation.instance.offsetX;
        float physicsY = transform.origin.z + WorldSimulation.instance.offsetY;
        return "id=" + vehicle.getId() + " entity=" + vehicle.getX() + "," + vehicle.getY() +
                " physics=" + physicsX + "," + physicsY +
                " active=" + vehicle.isActive + " static=" + vehicle.isStatic +
                " added=" + vehicle.addedToWorld + " removed=" + vehicle.isRemovedFromWorld() +
                " chunk=" + (vehicle.chunk == null ? "missing" :
                    vehicle.chunk.wx + "," + vehicle.chunk.wy) +
                " dbLoaded=" + VehiclesDB2.instance.isVehicleLoaded(vehicle);
    }

    private static boolean restorePeople(IsoPlayer player, List<SeatState> states) {
        boolean restored = true;
        for (SeatState state : states) {
            IsoGameCharacter character = state.character;
            if (state.vehicle.getCharacter(state.seat) == character) continue;
            if (character.getVehicle() != null || state.vehicle.getCharacter(state.seat) != null ||
                    !state.vehicle.enter(state.seat, character)) {
                restored = false;
                continue;
            }
            state.vehicle.setCharacterPosition(character, state.seat, "inside");
            if (GameServer.server && character instanceof IsoPlayer) {
                IsoPlayer passenger = (IsoPlayer) character;
                if (state.seat == 0) state.vehicle.authorizationServerOnSeat(passenger, true);
                INetworkPacket.sendToAll(PacketTypes.PacketType.VehicleEnter,
                        state.vehicle, passenger, state.seat);
                state.vehicle.transmitCharacterPosition(state.seat, "inside");
            }
        }
        return restored;
    }

    @LuaMethod(name = "umtspExitVehicle", global = true)
    public static boolean exitVehicle(IsoPlayer player, BaseVehicle vehicle) {
        lastError = "";
        if (GameClient.client || player == null || vehicle == null || player.getVehicle() != vehicle)
            return fail("The requesting player is not seated in this vehicle.");
        List<BaseVehicle> chain = towingChain(vehicle);
        if (chain == null) return false;
        List<SeatState> states = new ArrayList<>();
        for (BaseVehicle member : chain)
            for (int seat = 0; seat < member.getMaxPassengers(); seat++) {
                IsoGameCharacter character = member.getCharacter(seat);
                if (character != null) states.add(new SeatState(member, seat, character));
            }
        if (states.isEmpty()) return fail("No occupants were found in the vehicle.");
        List<SeatState> exited = new ArrayList<>();
        // Some NPC mods make companions exit when the player exits.
        states.sort((a, b) -> Boolean.compare(a.character == player, b.character == player));
        for (SeatState state : states) {
            if (!state.vehicle.exit(state.character)) {
                restorePeople(player, exited);
                return fail("The game refused to release a passenger seat.");
            }
            exited.add(state);
            if (GameServer.server && state.character instanceof IsoPlayer) {
                IsoPlayer passenger = (IsoPlayer) state.character;
                if (state.seat == 0) state.vehicle.authorizationServerOnSeat(passenger, false);
                INetworkPacket.sendToAll(PacketTypes.PacketType.VehicleExit,
                        state.vehicle, passenger, state.seat);
            }
        }
        synchronized (MOVE_LOCK) { EXITED_SEATS.put(player, states); }
        return true;
    }

    @LuaMethod(name = "umtspRestoreVehicleSeat", global = true)
    public static boolean restoreVehicleSeat(IsoPlayer player, BaseVehicle vehicle) {
        if (GameClient.client || player == null || vehicle == null)
            return fail("Could not restore the original vehicle seat.");
        List<SeatState> states;
        synchronized (MOVE_LOCK) { states = EXITED_SEATS.get(player); }
        if (states == null || !restorePeople(player, states))
            return fail("Could not restore every original vehicle seat.");
        synchronized (MOVE_LOCK) { EXITED_SEATS.remove(player); }
        lastError = "";
        return true;
    }

    @LuaMethod(name = "umtspVehicleLastError", global = true)
    public static String vehicleLastError() {
        return lastError;
    }

    @LuaMethod(name = "umtspCanStageRemoteVehicle", global = true)
    public static boolean canStageRemoteVehicle(IsoPlayer player, BaseVehicle vehicle) {
        lastError = "";
        if (GameClient.client || player == null || vehicle == null || player.getVehicle() != vehicle)
            return fail("The requesting player is not seated in this vehicle.");
        List<BaseVehicle> chain = towingChain(vehicle);
        if (chain == null) return false;
        return true;
    }

    @LuaMethod(name = "umtspEnsureVehicleEmpty", global = true)
    public static boolean ensureVehicleEmpty(IsoPlayer player, BaseVehicle vehicle) {
        List<SeatState> states;
        synchronized (MOVE_LOCK) { states = EXITED_SEATS.get(player); }
        if (states == null) return fail("Passenger transfer state is missing.");
        List<BaseVehicle> chain = towingChain(vehicle);
        if (chain == null) return false;
        for (BaseVehicle member : chain) {
            for (int seat = 0; seat < member.getMaxPassengers(); seat++) {
                IsoGameCharacter character = member.getCharacter(seat);
                if (character == null) continue;
                boolean expected = false;
                for (SeatState state : states)
                    if (state.vehicle == member && state.seat == seat && state.character == character)
                        expected = true;
                if (!expected) return fail("A new passenger entered while the destination was loading.");
                if (!member.exit(character) || member.getCharacter(seat) != null)
                    return fail("A passenger could not leave the vehicle for transfer.");
                if (GameServer.server && character instanceof IsoPlayer) {
                    IsoPlayer passenger = (IsoPlayer) character;
                    if (seat == 0) member.authorizationServerOnSeat(passenger, false);
                    INetworkPacket.sendToAll(PacketTypes.PacketType.VehicleExit,
                            member, passenger, seat);
                }
            }
        }
        return true;
    }

    @LuaMethod(name = "umtspFinishVehiclePeople", global = true)
    public static boolean finishVehiclePeople(IsoPlayer player, BaseVehicle vehicle, int x, int y) {
        List<SeatState> states;
        synchronized (MOVE_LOCK) { states = EXITED_SEATS.get(player); }
        if (states == null) return fail("Passenger transfer state is missing.");
        int offset = 0;
        for (SeatState state : states) {
            if (state.character == player) continue;
            state.character.teleportTo(x + 0.5f + offset * 0.3f, y + 0.5f, 0);
            offset++;
        }
        synchronized (MOVE_LOCK) { EXITED_SEATS.remove(player); }
        return true;
    }

    @LuaMethod(name = "umtspMoveVehicle", global = true)
    public static boolean moveVehicle(BaseVehicle vehicle, int x, int y) {
        lastError = "";
        if (GameClient.client || WorldSimulation.instance == null ||
                vehicle == null) return fail("The vehicle simulation is unavailable.");
        List<BaseVehicle> chain = towingChain(vehicle);
        if (chain == null) return false;
        if (GameServer.server) {
            if (ServerMap.instance == null || GameServer.udpEngine == null)
                return fail("The multiplayer vehicle map is unavailable.");
        } else {
            if (IsoWorld.instance == null || IsoWorld.instance.currentCell == null)
                return fail("The local vehicle map is unavailable.");
        }
        for (int i = 0; i < chain.size(); i++) {
            BaseVehicle member = chain.get(i);
            if (vehicleRadius(member) < 0) return fail("A vehicle has unsupported dimensions.");
            for (int seat = 0; seat < member.getMaxPassengers(); seat++) {
                if (member.getCharacter(seat) != null)
                    return fail("Everyone must leave the vehicle before it moves.");
            }
        }
        DebugLog.log("[UMTSP] vehicle transfer request: id=" + vehicle.getId() +
                " chain=" + chain.size() + " origin=" + vehicle.getX() + "," + vehicle.getY() +
                " target=" + x + "," + y);
        IsoGridSquare[] squares = null;
        float[] newX = null, newY = null;
        search:
        for (int radius = 3; radius <= 30; radius++) {
            for (int ox = -radius; ox <= radius; ox++) {
                for (int oy = -radius; oy <= radius; oy++) {
                    if (Math.max(Math.abs(ox), Math.abs(oy)) != radius) continue;
                    float cx = x + ox + 0.5f, cy = y + oy + 0.5f;
                    IsoGridSquare[] candidateSquares = new IsoGridSquare[chain.size()];
                    float[] candidateX = new float[chain.size()], candidateY = new float[chain.size()];
                    boolean valid = true;
                    for (int i = 0; i < chain.size(); i++) {
                        BaseVehicle member = chain.get(i);
                        candidateX[i] = cx + (member.getX() - vehicle.getX());
                        candidateY[i] = cy + (member.getY() - vehicle.getY());
                        if (!clearForVehicle(member, candidateX[i], candidateY[i])) {
                            valid = false;
                            break;
                        }
                        int tx = (int)Math.floor(candidateX[i]), ty = (int)Math.floor(candidateY[i]);
                        candidateSquares[i] = squareAt(tx, ty);
                        if (candidateSquares[i] == null || candidateSquares[i].chunk == null) {
                            valid = false;
                            break;
                        }
                    }
                    if (!valid) continue;
                    squares = candidateSquares;
                    newX = candidateX;
                    newY = candidateY;
                    break search;
                }
            }
        }
        if (squares == null)
            return fail("No clear road or open ground large enough for the vehicle or towing chain was found within 30 tiles.");
        synchronized (MOVE_LOCK) {
            if (towingChain(vehicle) == null) return false;
            float[] oldX = new float[chain.size()], oldY = new float[chain.size()];
            IsoGridSquare[] oldSquares = new IsoGridSquare[chain.size()];
            for (int i = 0; i < chain.size(); i++) {
                BaseVehicle member = chain.get(i);
                oldX[i] = member.getX();
                oldY[i] = member.getY();
                oldSquares[i] = squareAt((int)Math.floor(oldX[i]), (int)Math.floor(oldY[i]));
                // During a distant transfer the player has already streamed the
                // destination, so the origin square may legitimately be absent.
                // It is needed only for best-effort rollback, not for moving the
                // vehicle into the loaded destination.
                if (oldSquares[i] == null) oldSquares[i] = member.getSquare();
            }
            int started = -1;
            try {
                vehicle.setPhysicsActive(true);
                for (int i = 0; i < chain.size(); i++) {
                    started = i;
                    moveOne(chain.get(i), newX[i], newY[i], squares[i]);
                }
            } catch (Throwable movementError) {
                DebugLog.log("[UMTSP] vehicle move interrupted: " + movementError);
                boolean restored = true;
                for (int i = started; i >= 0; i--) {
                    try {
                        if (oldSquares[i] == null || oldSquares[i].chunk == null) {
                            restored = false;
                            DebugLog.log("[UMTSP] vehicle restore skipped because origin is unloaded: id=" +
                                    chain.get(i).getId());
                            continue;
                        }
                        moveOne(chain.get(i), oldX[i], oldY[i], oldSquares[i]);
                    } catch (Throwable restorationError) {
                        restored = false;
                        DebugLog.log("[UMTSP] vehicle restore failed: id=" +
                                chain.get(i).getId() + " error=" + restorationError);
                    }
                }
                if (restored) persistVehicles(chain);
                return fail(restored ? "Vehicle transfer failed; original positions restored." :
                        "Vehicle transfer failed and restoration was incomplete. Reload a backup save.");
            }
            if (GameServer.server) {
                for (BaseVehicle member : chain) {
                    IsoGameCharacter driver = member.getDriver();
                    if (driver instanceof IsoPlayer)
                        member.authorizationServerOnSeat((IsoPlayer) driver, true);
                }
            }
            persistVehicles(chain);
            DebugLog.log("[UMTSP] vehicle transfer completed: id=" + vehicle.getId() +
                    " chain=" + chain.size() + " result=" + vehicle.getX() + "," + vehicle.getY() +
                    " driver=" + (vehicle.getDriver() == null ? "none" :
                        vehicle.getDriver().getX() + "," + vehicle.getDriver().getY()) +
                    " " + vehicleDiagnostics(vehicle));
            lastError = "";
            return true;
        }
    }
}
