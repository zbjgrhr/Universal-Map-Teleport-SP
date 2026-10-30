-- Preserve rope-led animals as vanilla AnimalInventoryItem objects while an area streams.
-- Putting an AnimalInventoryItem on a square is important: the engine creates a fresh
-- IsoAnimal and registers it with the animal manager. Re-adding the removed instance
-- directly leaves the rope attached to an invalid entity.
local Animals = {}

local function log(message)
    print("[UMTSP] animals: " .. tostring(message))
end

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
        record.onlineID = animal:getOnlineID()
        record.animalType = animal:getAnimalType()
        attached:remove(animal)
        animal:getData():setAttachedPlayer(nil)
        animal:setWild(false)
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

local function snapshotAnimals(square)
    local result = {}
    local animals = square and square:getAnimals()
    if not animals then return result end
    for i = 0, animals:size() - 1 do
        result[animals:get(i)] = true
    end
    return result
end

local function findDroppedAnimal(square, before, record)
    local animals = square and square:getAnimals()
    if not animals then return nil end
    local fallback
    for i = 0, animals:size() - 1 do
        local animal = animals:get(i)
        if animal and not before[animal] then
            if record.onlineID ~= nil and animal:getOnlineID() == record.onlineID then
                return animal
            end
            if not fallback and animal:getAnimalType() == record.animalType then
                fallback = animal
            end
        end
    end
    return fallback
end

local function dropAndAttach(player, record, target)
    local inventory = player:getInventory()
    local before = snapshotAnimals(target.square)
    -- The final true mirrors the game's animal-aware drop path and transmits the
    -- newly-created animal when this code runs on a multiplayer server.
    target.square:AddWorldInventoryItem(record.item, 0.5, 0.5, 0, true)
    local animal = findDroppedAnimal(target.square, before, record)
    if not animal then
        return false, "The game placed the animal but did not return its new entity."
    end

    inventory:Remove(record.item)
    if isServer() then
        pcall(function() sendRemoveItemFromContainer(inventory, record.item) end)
    end
    record.item = nil
    record.animal = animal

    local attached = player:getAttachedAnimals()
    if not attached:contains(animal) then attached:add(animal) end
    animal:getData():setAttachedPlayer(player)
    if isServer() then pcall(function() animal:sendExtraUpdateToClients() end) end
    return true
end

function Animals.release(player, records, x, y)
    if #records == 0 then return true end
    local squares = planSquares(records, math.floor(x), math.floor(y))
    if not squares then return false, "No safe ground for the led animals; they remain in inventory." end
    local inventory = player:getInventory()
    for i, record in ipairs(records) do
        if record.item then
            local ok, placed, why = pcall(dropAndAttach, player, record, squares[i])
            if not ok then
                log("native animal drop failed: " .. tostring(placed))
                return false, "Could not place a led animal; it remains in inventory."
            end
            if not placed then
                log(why)
                -- The native drop has already created the animal. Do not attempt a
                -- second drop during rollback, which would duplicate it.
                if record.item then
                    inventory:Remove(record.item)
                    if isServer() then
                        pcall(function() sendRemoveItemFromContainer(inventory, record.item) end)
                    end
                    record.item = nil
                end
                return true
            end
        end
    end
    log("restored " .. tostring(#records) .. " led animal(s)")
    return true
end

return Animals
