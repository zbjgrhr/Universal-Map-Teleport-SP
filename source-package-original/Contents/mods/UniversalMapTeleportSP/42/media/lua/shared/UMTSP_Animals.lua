-- Preserve rope-led animals as vanilla AnimalInventoryItem objects while an area streams.
local Animals = {}

local function squareAt(x, y)
    local cell = getCell()
    return cell and cell:getGridSquare(x, y, 0)
end

local function usable(square)
    if not square or not square:getFloor() or not square:isFree(false) then return false end
    local sprite = square:getFloor():getSprite()
    local properties = sprite and sprite:getProperties()
    return not (properties and properties:has(IsoFlagType.water))
end

function Animals.capture(player)
    local attached = player:getAttachedAnimals()
    local result = {}
    if not attached then return result end
    for i = 0, attached:size() - 1 do
        local animal = attached:get(i)
        if not animal or not animal:isExistInTheWorld() or animal:isDead() or
            animal:getData():getAttachedPlayer() ~= player then
            return nil, "A led animal is unavailable; teleport cancelled."
        end
        result[#result + 1] = {animal=animal}
    end
    return result
end

function Animals.stage(player, records)
    if #records == 0 then return true end
    local inventory = player:getInventory()
    local attached = player:getAttachedAnimals()
    for _, record in ipairs(records) do
        local animal = record.animal
        local item = instanceItem("Base.Animal")
        if not item then return false, "Could not prepare an animal for travel." end
        item:setAnimal(animal)
        if not inventory:AddItem(item) then return false, "Could not hold an animal for travel." end
        record.item = item
        attached:remove(animal)
        animal:getData():setAttachedPlayer(nil)
        animal:removeFromWorld()
        animal:removeFromSquare()
        animal:setSquare(nil)
        if isServer() then sendPickupAnimal(animal, player, item) end
    end
    return true
end

local function planSquares(records, x, y)
    local result, used = {}, {}
    for _ = 1, #records do
        local chosen
        for radius = 1, 8 do
            for dx = -radius, radius do
                for dy = -radius, radius do
                    if math.max(math.abs(dx), math.abs(dy)) == radius then
                        local ax, ay = x + dx, y + dy
                        local key = ax .. ":" .. ay
                        local square = squareAt(ax, ay)
                        if not used[key] and usable(square) then
                            chosen = {x=ax, y=ay, square=square}
                            used[key] = true
                            break
                        end
                    end
                end
                if chosen then break end
            end
            if chosen then break end
        end
        if not chosen then return nil end
        result[#result + 1] = chosen
    end
    return result
end

function Animals.release(player, records, x, y)
    if #records == 0 then return true end
    local squares = planSquares(records, math.floor(x), math.floor(y))
    if not squares then return false, "No safe ground for the led animals; they remain in inventory." end
    local inventory = player:getInventory()
    local attached = player:getAttachedAnimals()
    for i, record in ipairs(records) do
        if record.item then
            local animal, target = record.animal, squares[i]
            local ok, err = pcall(function()
                local ax, ay = target.x + 0.5, target.y + 0.5
                animal:setX(ax)
                animal:setY(ay)
                animal:setZ(0)
                animal:setNextX(ax)
                animal:setNextY(ay)
                animal:setLastX(ax)
                animal:setLastY(ay)
                animal:setSquare(target.square)
                animal:setCurrent(target.square)
                animal:setMovingSquare(target.square)
                animal:addToWorld()
                if not animal:isExistInTheWorld() then error("animal did not enter the world") end
                attached:add(animal)
                animal:getData():setAttachedPlayer(player)
            end)
            if not ok then
                return false, "Could not place a led animal: " .. tostring(err) .. "; it remains in inventory."
            end
            inventory:Remove(record.item)
            if isServer() then
                pcall(function() sendRemoveItemFromContainer(inventory, record.item) end)
                pcall(function() animal:sendExtraUpdateToClients() end)
            end
            record.item = nil
        end
    end
    return true
end

return Animals
