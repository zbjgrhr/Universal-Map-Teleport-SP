require "ISUI/Maps/ISWorldMap"
require "ISUI/ISContextMenu"
local config = require "UMTSP_Config"

-- B42.21 client. Multiplayer moves are requested from the server.
local UMT = {
    prefix = "[UniversalMapTeleportSP] ",
    binding = "UMTSP: Teleport Here (World Map)",
    debug = config.debug == true,
    searchRadius = math.max(0, math.min(5, tonumber(config.searchRadius) or 3)),
    arrivalTimeoutTicks = math.max(120, math.min(1200, tonumber(config.arrivalTimeoutTicks) or 600)),
    pending = nil,
    installed = nil,
    installedShow = nil,
    nextRequestId = 0,
}

local function log(message, verbose)
    if not verbose or UMT.debug then print(UMT.prefix .. tostring(message)) end
end

local function supportedSession()
    return not isServer() and getNumActivePlayers() >= 1
end

local function tell(message, player)
    log(message)
    player = player or getSpecificPlayer(0)
    if player then pcall(function() player:Say("[UMT] " .. message) end) end
end

local function finite(value)
    return type(value) == "number" and value == value and value > -10000000 and value < 10000000
end

local function mapCoordinates(map, x, y)
    if not map or not map.mapAPI or not finite(x) or not finite(y) then return nil end
    local ok, worldX, worldY = pcall(function()
        return map.mapAPI:uiToWorldX(x, y), map.mapAPI:uiToWorldY(x, y)
    end)
    if not ok or not finite(worldX) or not finite(worldY) then return nil end
    local wx, wy = math.floor(worldX), math.floor(worldY)
    local world = getWorld()
    if not world or not world:getMetaGrid():isValidChunk(wx / 10, wy / 10) then return nil end
    return wx, wy
end

local function safeSquare(x, y)
    local cell = getCell()
    if not cell then return nil end
    for radius = 0, UMT.searchRadius do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if math.max(math.abs(dx), math.abs(dy)) == radius then
                    local square = cell:getGridSquare(x + dx, y + dy, 0)
                    if square and square:getFloor() and square:isFree(false) then
                        local sprite = square:getFloor():getSprite()
                        local properties = sprite and sprite:getProperties()
                        if not (properties and properties:has(IsoFlagType.water)) then
                            return x + dx, y + dy
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function checkedSafeSquare(x, y)
    local ok, safeX, safeY = pcall(safeSquare, x, y)
    if not ok then
        log("landing validation failed: " .. tostring(safeX))
        return nil, nil, true
    end
    return safeX, safeY, false
end

local function rollback(reason)
    local request = UMT.pending
    UMT.pending = nil
    if request and request.player then
        local ok, err
        if isClient() then
            ok, err = pcall(function()
                sendClientCommand(request.player, "UMTSP", "rollback", {id=request.id})
            end)
        else
            ok, err = pcall(function()
                request.player:teleportTo(request.originX, request.originY, request.originZ)
            end)
        end
        if not ok then
            tell("Return to origin failed: " .. tostring(err))
            return
        end
    end
    tell(reason, request and request.player)
end

local function validateArrival()
    local request = UMT.pending
    if not request then return end
    request.ticks = request.ticks + 1
    local player = request.player
    if not player or player:isDead() then UMT.pending = nil return end
    if request.adjusting then
        if request.ticks >= UMT.arrivalTimeoutTicks then rollback("Landing adjustment timed out.") end
        return
    end
    local distance = math.abs(player:getX() - (request.x + 0.5)) + math.abs(player:getY() - (request.y + 0.5))
    if distance < 2 then
        local square = getCell() and getCell():getGridSquare(request.x, request.y, 0)
        if square then
            local safeX, safeY, validationError = checkedSafeSquare(request.x, request.y)
            if validationError or not safeX then
                rollback("No safe ground tile at the destination. Returned to origin.")
                return
            end
            if safeX ~= request.x or safeY ~= request.y then
                local ok, err
                if isClient() then
                    request.adjusting = true
                    ok, err = pcall(function()
                        sendClientCommand(player, "UMTSP", "adjust", {id=request.id, x=safeX, y=safeY})
                    end)
                else
                    request.x, request.y = safeX, safeY
                    ok, err = pcall(function() player:teleportTo(safeX + 0.5, safeY + 0.5, 0) end)
                end
                if not ok then rollback("Landing adjustment failed: " .. tostring(err)) end
                return
            end
            UMT.pending = nil
            if isClient() then
                pcall(function() sendClientCommand(player, "UMTSP", "finish", {id=request.id}) end)
            end
            log("teleport completed at " .. request.x .. "," .. request.y)
            return
        end
    end
    if request.ticks >= UMT.arrivalTimeoutTicks then
        rollback("Destination did not finish loading. Returned to origin.")
    end
end

local function teleport(_, x, y, playerNum)
    if not supportedSession() then return end
    if UMT.pending then tell("A previous teleport is still loading.") return end
    playerNum = playerNum or 0
    local player = getSpecificPlayer(playerNum)
    if not player or player:isDead() then tell("No living player is available.") return end
    if player:getVehicle() then tell("Leave the vehicle before teleporting.") return end
    if not finite(x) or not finite(y) or not getWorld():getMetaGrid():isValidChunk(x / 10, y / 10) then
        tell("Invalid map coordinates.") return
    end
    x, y = math.floor(x), math.floor(y)
    local squareLoaded = getCell() and getCell():getGridSquare(x, y, 0)
    local targetX, targetY = x, y
    if squareLoaded then
        local landingX, landingY, validationError = checkedSafeSquare(x, y)
        if validationError then tell("Could not validate the landing tile.") return end
        if not landingX then tell("No safe ground tile near the selected position.") return end
        targetX, targetY = landingX, landingY
    end
    UMT.nextRequestId = UMT.nextRequestId + 1
    UMT.pending = {
        id = UMT.nextRequestId,
        player = player, x = targetX, y = targetY, ticks = 0,
        originX = player:getX(), originY = player:getY(), originZ = player:getZ()
    }
    if ISWorldMap_instance and ISWorldMap_instance:isVisible() then ISWorldMap.HideWorldMap(playerNum) end
    local ok, err
    if isClient() then
        ok, err = pcall(function()
            sendClientCommand(player, "UMTSP", "start", {id=UMT.pending.id, x=targetX, y=targetY})
        end)
    else
        ok, err = pcall(function() player:teleportTo(targetX + 0.5, targetY + 0.5, 0) end)
    end
    if not ok then
        UMT.pending = nil
        tell("Teleport failed: " .. tostring(err), player)
        return
    end
    log("teleport requested at " .. targetX .. "," .. targetY ..
        (squareLoaded and " (loaded)" or " (waiting for destination to load)"))
    validateArrival()
end

local function addOption(map, x, y, upstreamResult)
    if not supportedSession() or not map or not map.mapAPI then return false end
    if map.symbolsUI and (map.symbolsUI.currentTool or map.symbolsUI.ignoreRightMouseUp) then return false end
    local wx, wy = mapCoordinates(map, x, y)
    if not wx then log("map coordinate conversion failed", true) return false end
    local playerNum = map.playerNum or 0
    local context = getPlayerContextMenu(playerNum)
    if not context or not context:isVisible() then
        if upstreamResult == true then return false end -- e.g. a symbol tool consumed the click
        context = ISContextMenu.get(playerNum, x + map:getAbsoluteX(), y + map:getAbsoluteY())
    end
    for _, option in ipairs(context.options or {}) do
        if option.UMTSP then return true end
    end
    local option = context:addOptionOnTop("Teleport Here", nil, teleport, wx, wy, playerNum)
    if not option then tell("Could not add Teleport Here to the map menu.") return false end
    option.UMTSP = true
    log("Teleport Here added at " .. wx .. "," .. wy, true)
    return true
end

local function installHook()
    if not ISWorldMap or type(ISWorldMap.onRightMouseUp) ~= "function" then
        log("ISWorldMap is not initialized")
        return
    end
    if ISWorldMap.onRightMouseUp == UMT.installed then return end
    if UMT.installed then log("map callback was replaced after installation; wrapping current callback") end
    local previous = ISWorldMap.onRightMouseUp
    local wrapper = function(self, x, y)
        log("map right click", true)
        local ok, result = pcall(previous, self, x, y)
        if not ok then log("upstream map callback failed: " .. tostring(result)) end
        local added, errorMessage = pcall(addOption, self, x, y, result)
        if not added then log("menu insertion failed: " .. tostring(errorMessage)) end
        if added and errorMessage then return true end
        if ok then return result end
        return false
    end
    ISWorldMap.onRightMouseUp = wrapper
    UMT.installed = wrapper
    log("map callback registered; multiplayer=" .. tostring(isClient()))
end

local function installShowHook()
    if not ISWorldMap or type(ISWorldMap.ShowWorldMap) ~= "function" or
        ISWorldMap.ShowWorldMap == UMT.installedShow then return end
    local previous = ISWorldMap.ShowWorldMap
    local wrapper = function(...)
        installHook()
        return previous(...)
    end
    ISWorldMap.ShowWorldMap = wrapper
    UMT.installedShow = wrapper
end

local function onServerCommand(module, command, args)
    if module ~= "UMTSP" or not UMT.pending or type(args) ~= "table" or
        args.id ~= UMT.pending.id then return end
    if command == "rejected" then
        local player = UMT.pending.player
        UMT.pending = nil
        tell(args.reason or "Server rejected teleport.", player)
    elseif command == "adjusted" then
        UMT.pending.x, UMT.pending.y = args.x, args.y
        UMT.pending.adjusting = false
        UMT.pending.ticks = 0
    end
end

local function onKeyPressed(key)
    local configured = getCore():getKey(UMT.binding)
    if not configured or configured == 0 or key ~= configured then return end
    local map = ISWorldMap_instance
    if not map or not map:isVisible() or not map.mapAPI then return end
    local x, y = getMouseX() - map:getAbsoluteX(), getMouseY() - map:getAbsoluteY()
    if x < 0 or y < 0 or x >= map:getWidth() or y >= map:getHeight() then return end
    local wx, wy = mapCoordinates(map, x, y)
    if not wx then tell("Point to a valid map location first.") return end
    teleport(nil, wx, wy, map.playerNum or 0)
end

local function registerBinding()
    if not keyBinding then log("key binding table unavailable") return end
    for _, binding in ipairs(keyBinding or {}) do
        if binding.value == UMT.binding then return end
    end
    table.insert(keyBinding, { value = "[Universal Map Teleport]" })
    table.insert(keyBinding, { value = UMT.binding, key = Keyboard.KEY_NONE })
    log("fallback key registered (unbound by default)")
end

Events.OnGameBoot.Add(registerBinding)
Events.OnGameStart.Add(installHook)
Events.OnGameStart.Add(installShowHook)
Events.OnKeyPressed.Add(onKeyPressed)
Events.OnTick.Add(validateArrival)
Events.OnServerCommand.Add(onServerCommand)
log("mod loaded")
