-- Person-only travel uses the game's seat API and normal client exit packet.
local Seat = {}
local saved = {}
local returning = {}

function Seat.exit(player, vehicle)
    if not vehicle or player:getVehicle() ~= vehicle then return true end
    local index = vehicle:getSeat(player)
    if index < 0 then return false end
    saved[player] = {vehicle=vehicle, seat=index}
    if not vehicle:exit(player) then saved[player] = nil return false end
    player:PlayAnim("Idle")
    triggerEvent("OnExitVehicle", player)
    return player:getVehicle() == nil
end

function Seat.restore(player)
    local state = saved[player]
    if not state then return true end
    if player:getVehicle() then
        saved[player] = nil
        return player:getVehicle() == state.vehicle
    end
    -- Never put a returned player into a vehicle that has driven away.
    local vehicle = state.vehicle
    if math.abs(player:getX()-vehicle:getX()) + math.abs(player:getY()-vehicle:getY()) > 8 then return false end
    if not vehicle:getSquare() or vehicle:getCharacter(state.seat) then return false end
    if not vehicle:enter(state.seat, player) then return false end
    vehicle:setCharacterPosition(player, state.seat, "inside")
    vehicle:transmitCharacterPosition(state.seat, "inside")
    triggerEvent("OnEnterVehicle", player)
    saved[player] = nil
    return true
end

function Seat.forget(player) saved[player] = nil returning[player] = nil end
function Seat.requestRestore(player) if saved[player] then returning[player] = 600 end end
Events.OnTick.Add(function()
    for player, ticks in pairs(returning) do
        local ok, restored = pcall(Seat.restore, player)
        if (ok and restored) or ticks <= 0 or player:isDead() then
            Seat.forget(player)
        else returning[player] = ticks - 1 end
    end
end)
return Seat
