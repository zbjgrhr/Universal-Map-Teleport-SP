-- Server-authoritative teleport. Vehicle moves require the ZombieBuddy bridge.
local MODULE = "UMTSP"
local Animals = require "UMTSP_Animals"
local sessions = {}
local lastRequest = {}
local SEARCH_RADIUS = 3

local function validNumber(value)
    return type(value) == "number" and value == value and value > -10000000 and value < 10000000
end

local function reply(player, command, args)
    sendServerCommand(player, MODULE, command, args or {})
end

local function validPosition(x, y)
    local world = getWorld()
    return validNumber(x) and validNumber(y) and world and world:getMetaGrid() and
        world:getMetaGrid():isValidChunk(math.floor(x / 10), math.floor(y / 10))
end

local function move(player, x, y, z)
    return pcall(function() player:teleportTo(x, y, z) end)
end

local function vehicleError(fallback)
    if type(umtspVehicleLastError) == "function" then
        local ok, message = pcall(umtspVehicleLastError)
        if ok and type(message) == "string" and message ~= "" then return message end
    end
    return fallback
end

local function restoreVehicleSeat(player, vehicle)
    if not vehicle or type(umtspRestoreVehicleSeat) ~= "function" then return true end
    local ok, restored = pcall(umtspRestoreVehicleSeat, player, vehicle)
    if not ok or not restored then
        print("[UMTSP] seat restore failed: " .. vehicleError(tostring(restored)))
        return false
    end
    return true
end

local function returnToOrigin(player, session)
    sessions[player] = nil
    move(player, session.originX, session.originY, session.originZ)
    if session.animals then
        local ok, why = Animals.release(player, session.animals, session.originX, session.originY)
        if not ok then print("[UMTSP] " .. tostring(why)) end
    end
    restoreVehicleSeat(player, session.seatVehicle)
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or not player or type(args) ~= "table" then return end
    local id = args.id
    if not validNumber(id) or id < 1 then return end

    if command == "start" then
        if sessions[player] and getTimestampMs() - sessions[player].started > 180000 then
            sessions[player] = nil
        end
        if sessions[player] then reply(player, "rejected", {id=id, reason="A teleport is already in progress."}) return end
        local now = getTimestampMs()
        if lastRequest[player] and now - lastRequest[player] < 1000 then
            reply(player, "rejected", {id=id, reason="Wait before teleporting again."})
            return
        end
        local x, y = args.x, args.y
        if not validPosition(x, y) or x ~= math.floor(x) or y ~= math.floor(y) or player:isDead() then
            reply(player, "rejected", {id=id, reason="Invalid destination or player state."})
            return
        end
        local animals, animalError = Animals.capture(player)
        if not animals then
            reply(player, "rejected", {id=id, reason=animalError})
            return
        end
        local vehicle = player:getVehicle()
        local mode = args.mode
        if mode ~= "person" and mode ~= "vehicle" then
            reply(player, "rejected", {id=id, reason="Invalid teleport mode."})
            return
        end
        if mode == "vehicle" and not vehicle then
            reply(player, "rejected", {id=id, reason="Enter a vehicle to use vehicle teleport."})
            return
        end
        if vehicle and #animals > 0 then
            reply(player, "rejected", {id=id, reason="Leave the vehicle before teleporting led animals."})
            return
        end
        if vehicle then
            if type(umtspExitVehicle) ~= "function" or type(umtspMoveVehicle) ~= "function" or
                args.vehicleId ~= vehicle:getId() then
                reply(player, "rejected", {id=id, reason="Vehicle bridge unavailable or vehicle changed."})
                return
            end
        elseif args.vehicleId ~= nil then
            reply(player, "rejected", {id=id, reason="Vehicle changed before teleport."})
            return
        end
        if mode == "vehicle" then
            if type(umtspCanStageRemoteVehicle) ~= "function" or
                not umtspCanStageRemoteVehicle(player, vehicle) then
                reply(player, "rejected", {id=id,
                    reason=vehicleError("Distant vehicle transfer is unavailable.")})
                return
            end
            local session = {id=id, x=x, y=y, originX=player:getX(),
                originY=player:getY(), originZ=player:getZ(),
                originVehicleX=vehicle:getX(), originVehicleY=vehicle:getY(),
                started=now, adjusted=false, vehicle=vehicle,
                seatVehicle=vehicle, animals=animals}
            sessions[player] = session
            local exited, success = pcall(function() return umtspExitVehicle(player, vehicle) end)
            if not exited or not success then
                sessions[player] = nil
                reply(player, "rejected", {id=id,
                    reason=vehicleError("Could not release the original seat.")})
                return
            end
            local moved, moveError = move(player, x + 0.5, y + 0.5, 0)
            if not moved then
                returnToOrigin(player, session)
                reply(player, "rejected", {id=id,
                    reason="Destination loading failed: " .. tostring(moveError)})
                return
            end
            lastRequest[player] = now
            reply(player, "started", {id=id})
            return
        end
        local originX, originY, originZ = player:getX(), player:getY(), player:getZ()
        sessions[player] = {id=id, x=x, y=y, originX=originX, originY=originY,
            originZ=originZ, started=now, adjusted=false,
            vehicle=nil, seatVehicle=vehicle, animals=animals}
        lastRequest[player] = now
        if vehicle then
            local exited, success = pcall(function() return umtspExitVehicle(player, vehicle) end)
            if not exited or not success then
                sessions[player] = nil
                reply(player, "rejected", {id=id,
                    reason=vehicleError("Stop the vehicle and every vehicle in the towing chain.")})
                return
            end
        end
        local prepared, prepareError = pcall(function()
            local staged, why = Animals.stage(player, animals)
            if not staged then error(why) end
        end)
        if not prepared then
            returnToOrigin(player, sessions[player])
            reply(player, "rejected", {id=id, reason="Animal transfer failed: " .. tostring(prepareError)})
            return
        end
        local ok, err = move(player, x + 0.5, y + 0.5, 0)
        if not ok then
            returnToOrigin(player, sessions[player])
            reply(player, "rejected", {id=id, reason="Server teleport failed: " .. tostring(err)})
            return
        end
        reply(player, "started", {id=id})
        return
    end

    local session = sessions[player]
    if not session or session.id ~= id then return end
    if getTimestampMs() - session.started > 180000 then
        returnToOrigin(player, session)
        reply(player, "rejected", {id=id, reason="Teleport request expired; returned to origin."})
        return
    end

    if command == "adjust" then
        local x, y = args.x, args.y
        if session.adjusted or not validPosition(x, y) or
            math.abs(x - session.x) > SEARCH_RADIUS or math.abs(y - session.y) > SEARCH_RADIUS or
            x ~= math.floor(x) or y ~= math.floor(y) then
            returnToOrigin(player, session)
            reply(player, "rejected", {id=id, reason="Landing adjustment rejected."})
            return
        end
        session.adjusted = true
        local ok, err = move(player, x + 0.5, y + 0.5, 0)
        if not ok then
            returnToOrigin(player, session)
            reply(player, "rejected", {id=id, reason="Landing adjustment failed: " .. tostring(err)})
            return
        end
        session.x, session.y = x, y
        reply(player, "adjusted", {id=id, x=x, y=y})
    elseif command == "rollback" then
        returnToOrigin(player, session)
        reply(player, "returned", {id=id, reason="Returned to the starting point."})
    elseif command == "finish" then
        if session.vehiclePlaced then return end
        if session.vehicle then
            local emptyOk, empty = pcall(umtspEnsureVehicleEmpty,
                player, session.vehicle)
            if not emptyOk or not empty then
                local reason = vehicleError("A passenger could not leave the vehicle.")
                returnToOrigin(player, session)
                reply(player, "rejected", {id=id, reason=reason})
                return
            end
            local ok, moved = pcall(function()
                return umtspMoveVehicle(session.vehicle, session.x, session.y)
            end)
            if not ok or not moved then
                local reason = vehicleError("Vehicle could not be moved.")
                returnToOrigin(player, session)
                reply(player, "rejected", {id=id,
                    reason=reason .. " Returned to the starting point and restored the original seat."})
                return
            end
            session.vehiclePlaced = true
            session.expectedVehicleX = session.vehicle:getX()
            session.expectedVehicleY = session.vehicle:getY()
            session.verifyTicks = 0
            return
        end
        local placed, why = Animals.release(player, session.animals, session.x, session.y)
        if not placed then
            returnToOrigin(player, session)
            reply(player, "rejected", {id=id, reason=why})
            return
        end
        reply(player, "finished", {id=id,
            vehicleX=session.vehicle and session.vehicle:getX() or nil,
            vehicleY=session.vehicle and session.vehicle:getY() or nil})
        sessions[player] = nil
    end
end

Events.OnClientCommand.Add(onClientCommand)

local function verifyVehicles()
    for player, session in pairs(sessions) do
        if session.vehiclePlaced then
            session.verifyTicks = session.verifyTicks + 1
            if session.verifyTicks >= 30 then
                local vehicle = session.vehicle
                if math.abs(vehicle:getX() - session.expectedVehicleX) > 3 or
                    math.abs(vehicle:getY() - session.expectedVehicleY) > 3 then
                    returnToOrigin(player, session)
                    reply(player, "rejected", {id=session.id,
                        reason="Vehicle did not stay at the destination. Everyone returned to origin."})
                else
                    local ok, moved = pcall(umtspFinishVehiclePeople,
                        player, vehicle, session.x, session.y)
                    if not ok or not moved then
                        returnToOrigin(player, session)
                        reply(player, "rejected", {id=session.id,
                            reason=vehicleError("Could not bring passengers to the destination.")})
                    else
                        sessions[player] = nil
                        reply(player, "finished", {id=session.id,
                            vehicleX=vehicle:getX(), vehicleY=vehicle:getY()})
                    end
                end
            end
        end
    end
end

Events.OnTick.Add(verifyVehicles)
