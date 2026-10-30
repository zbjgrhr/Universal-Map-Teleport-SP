-- Server-authoritative teleport requests. The server only moves the requesting player.
local MODULE = "UMTSP"
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

local function returnToOrigin(player, session)
    sessions[player] = nil
    move(player, session.originX, session.originY, session.originZ)
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
        if not validPosition(x, y) or x ~= math.floor(x) or y ~= math.floor(y) or
            player:isDead() or player:getVehicle() then
            reply(player, "rejected", {id=id, reason="Invalid destination or player state."})
            return
        end
        local originX, originY, originZ = player:getX(), player:getY(), player:getZ()
        sessions[player] = {id=id, x=x, y=y, originX=originX, originY=originY,
            originZ=originZ, started=now, adjusted=false}
        lastRequest[player] = now
        local ok, err = move(player, x + 0.5, y + 0.5, 0)
        if not ok then
            sessions[player] = nil
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
        reply(player, "adjusted", {id=id, x=x, y=y})
    elseif command == "rollback" then
        sessions[player] = nil
        local ok, err = move(player, session.originX, session.originY, session.originZ)
        reply(player, ok and "returned" or "rejected", {id=id,
            reason=ok and "Returned to the starting point." or ("Return failed: " .. tostring(err))})
    elseif command == "finish" then
        sessions[player] = nil
    end
end

Events.OnClientCommand.Add(onClientCommand)
