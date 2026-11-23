local C = require("RailroaderRV/Common/RV_Constants")
local AnimalCargo = require("RailroaderRV/Animals/RV_AnimalCargo")
local ClientDispatch = require("RailroaderRV/Core/RV_ServerClientDispatch")
local Body = require("Railroader/RR_Body")
local RRApi = require("Railroader/RR_API")
local Units = require("RailroaderRV/RVMapping/RV_RailroaderUnits")

local Cargo = {}
local RADIUS = 5
local OUTSIDE_HULL_CLEARANCE = 1.0
local OTHER_UNIT_CLEARANCE = 0.25

local function integer(value)
    local number = tonumber(value)
    if number == nil or math.floor(number) ~= number then return nil end
    return number
end

local function findNearbyAnimal(player, onlineId, animalId, unitId, inside,
        Adapter)
    local cell = player:getCell()
    local centerX, centerY, centerZ = math.floor(player:getX()),
        math.floor(player:getY()), math.floor(player:getZ())
    local match
    for dx = -RADIUS, RADIUS do
        for dy = -RADIUS, RADIUS do
            if AnimalCargo.withinRadius(0, 0, dx, dy, RADIUS) then
                local square = cell:getGridSquare(centerX + dx,
                    centerY + dy, centerZ)
                if square then
                    local animals = square:getAnimals()
                    for index = 0, animals:size() - 1 do
                        local animal = animals:get(index)
                        local matches = onlineId ~= nil
                            and animal:getOnlineID() == onlineId
                            or onlineId == nil
                                and animal:getAnimalID() == animalId
                        if matches and AnimalCargo.isEligible(animal)
                            and Adapter.animalCargoSquareAllowed(unitId,
                                square, inside) then
                            if match then return nil end
                            match = animal
                        end
                    end
                end
            end
        end
    end
    return match
end

local function saveAnimal(animal)
    local breed = animal:getBreed()
    local data = animal:getData()
    return {
        animalType = animal:getAnimalType(),
        breed = breed:getName(),
        female = data:isFemale(),
        ageDays = data:getAge(),
        ageHours = animal:getHoursSurvived(),
        weight = data:getWeight(),
        health = animal:getHealth(),
        customName = animal:getCustomName(),
    }
end

local function findInteriorPlacement(player, unitId, Adapter)
    local cell = player:getCell()
    local centerX, centerY, z = math.floor(player:getX()),
        math.floor(player:getY()), math.floor(player:getZ())
    for distanceSquared = 0, RADIUS * RADIUS do
        for dx = -RADIUS, RADIUS do
            for dy = -RADIUS, RADIUS do
                if dx * dx + dy * dy == distanceSquared then
                    local square = cell:getGridSquare(centerX + dx,
                        centerY + dy, z)
                    if square and square:getFloor() ~= nil
                        and square:isFree(true)
                        and square:isWaterSquare() == false
                        and Adapter.animalCargoSquareAllowed(unitId, square,
                            true) then
                        return square
                    end
                end
            end
        end
    end
    return nil
end

local function findUnitFrame(unitId)
    local consistId = RRApi.unitOf(unitId)
    if consistId == nil then return nil end

    local units = RRApi.units(consistId, {})
    for _, unit in ipairs(units or {}) do
        if tonumber(unit.id) == tonumber(unitId) then
            return unit
        end
    end
    return nil
end

local function otherRailroaderUnits(targetUnitId, targetZ)
    local out = {}
    local function appendUnits(units)
        for _, unit in ipairs(units) do
            if tonumber(unit.id) ~= tonumber(targetUnitId)
                and unit.x ~= nil and unit.y ~= nil
                and unit.dirX ~= nil and unit.dirY ~= nil
                and unit.halfLength ~= nil and unit.halfWidth ~= nil
                and unit.z ~= nil
                and math.floor(unit.z) == targetZ then
                out[#out + 1] = unit
            end
        end
    end

    for _, train in ipairs(RRApi.trains({}) or {}) do
        appendUnits(RRApi.units(train.id, {}) or {})
    end
    for _, cut in ipairs(RRApi.cuts({}) or {}) do
        appendUnits(RRApi.units(cut.id, {}) or {})
    end
    return out
end

local function clearOfRailroaderUnits(units, x, y)
    for _, unit in ipairs(units) do
        local inside = Body.containsBox(unit,
            unit.halfLength + OTHER_UNIT_CLEARANCE,
            unit.halfWidth + OTHER_UNIT_CLEARANCE, x, y)
        if inside then return false end
    end
    return true
end

local function findOutsidePlacement(player, unitId, Adapter)
    local unit = findUnitFrame(unitId)
    if not unit or unit.x == nil or unit.y == nil or unit.z == nil
        or unit.dirX == nil or unit.dirY == nil
        or unit.halfLength == nil or unit.halfWidth == nil then
        return nil
    end

    local playerX, playerY = player:getX(), player:getY()
    local z = math.floor(unit.z)
    local _, playerAcross = Body.toLocal(unit, playerX, playerY)
    local side = playerAcross >= 0 and 1 or -1
    local cell = player:getCell()
    local centerX, centerY = math.floor(playerX), math.floor(playerY)
    local otherUnits = otherRailroaderUnits(unitId, z)
    local best, bestDistanceSquared

    for dx = -RADIUS - 1, RADIUS + 1 do
        for dy = -RADIUS - 1, RADIUS + 1 do
            local x, y = centerX + dx + 0.5, centerY + dy + 0.5
            local along, across = Body.toLocal(unit, x, y)
            local outsideDistance = side * across
            local fromPlayerX, fromPlayerY = x - playerX, y - playerY
            local distanceSquared = fromPlayerX * fromPlayerX
                + fromPlayerY * fromPlayerY
            if outsideDistance >= unit.halfWidth + OUTSIDE_HULL_CLEARANCE
                and math.abs(along) <= unit.halfLength
                and distanceSquared <= RADIUS * RADIUS
                and clearOfRailroaderUnits(otherUnits, x, y) then
                local square = cell:getGridSquare(centerX + dx,
                    centerY + dy, z)
                if square and square:getFloor() ~= nil
                    and square:isFree(true)
                    and square:isWaterSquare() == false
                    and Adapter.animalCargoSquareAllowed(unitId, square,
                        false)
                    and (bestDistanceSquared == nil
                        or distanceSquared < bestDistanceSquared) then
                    best, bestDistanceSquared = square, distanceSquared
                end
            end
        end
    end
    return best
end

local function findPlacement(player, unitId, inside, Adapter)
    if inside then
        return findInteriorPlacement(player, unitId, Adapter)
    end
    return findOutsidePlacement(player, unitId, Adapter)
end

local function restoreAnimal(player, saved, unitId, inside, Adapter)
    local square = findPlacement(player, unitId, inside, Adapter)
    if not square then return false, "no-placement" end

    local definition = AnimalDefinitions.getDef(saved.animalType)
    local breed = definition:getBreedByName(saved.breed)
    local animal = addAnimal(square:getCell(), square:getX(), square:getY(),
        square:getZ(), saved.animalType, breed)
    local ok, reason = pcall(function()
        local data = animal:getData()
        data:setAge(saved.ageDays)
        data:setWeight(saved.weight)
        animal:setHoursSurvived(saved.ageHours)
        animal:setFemale(saved.female)
        animal:setHealth(saved.health)
        animal:setCustomName(saved.customName)
        animal:addToWorld()
        if isServer() then animal:sendExtraUpdateToClients() end
    end)
    if not ok then
        pcall(function() animal:delete() end)
        return false, reason
    end
    return true
end

local function sendResult(player)
    local onlineId = player:getOnlineID()
    if onlineId == nil or onlineId < 0 then onlineId = 0 end
    ClientDispatch.sendToPlayer(player, C.MOD_ID,
        C.COMMAND_RV_ANIMAL_CARGO_RESULT, {
            onlineId = onlineId,
            ok = true,
        })
end

function Cargo.handle(player, args, Adapter)
    if type(args) ~= "table" or not player or player:isDead() then
        return false, "player-unavailable"
    end
    local accepted, unitId, _, inside = Adapter.resolveAnimalCargoUnit(
        player, args.unitId)
    if accepted ~= true then
        return false, unitId
    end

    local map = ModData.get(C.RV_MAP_KEY)
    local operation = args.operation
    if operation == "load" then
        local onlineId = integer(args.animalOnlineId)
        if onlineId ~= nil and onlineId < 0 then onlineId = nil end
        local animalId = integer(args.animalId)
        if onlineId == nil and animalId == nil then
            return false, "invalid-animal"
        end
        local animal = findNearbyAnimal(player, onlineId, animalId,
            unitId, inside, Adapter)
        if not animal then return false, "animal-unavailable" end

        local saved = saveAnimal(animal)
        local unitKey = tostring(unitId)
        local rows = map.animalsByUnit[unitKey]
        local cargoId = map.nextAnimalCargoId
        local nextCargoId = cargoId + 1
        if rows == nil then rows = {} end
        local row = { id = cargoId, data = saved }
        rows[#rows + 1] = row
        map.animalsByUnit[unitKey] = rows
        map.nextAnimalCargoId = nextCargoId
        local deleted, deleteError = pcall(function() animal:delete() end)
        if not deleted then
            if animal:isExistInTheWorld() then
                table.remove(rows, #rows)
                map.nextAnimalCargoId = cargoId
            end
            return false, deleteError
        end
        ModData.transmit(C.RV_MAP_KEY)
        sendResult(player)
        return true
    end

    if operation == "unload" then
        local cargoId = integer(args.cargoId)
        if cargoId == nil then return false, "invalid-cargo" end
        local rows = map.animalsByUnit[tostring(unitId)]
        if rows == nil then return false, "cargo-unavailable" end
        for index, row in ipairs(rows) do
            if row.id == cargoId then
                local placed, reason = restoreAnimal(player, row.data,
                    unitId, inside, Adapter)
                if not placed then
                    return false, reason
                end
                table.remove(rows, index)
                ModData.transmit(C.RV_MAP_KEY)
                sendResult(player)
                return true
            end
        end
        return false, "cargo-unavailable"
    end

    return false, "invalid-operation"
end

return Cargo
