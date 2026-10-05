-- Server-only power-device scanning. Each RV process state owns one latest
-- snapshot; UtilityStore persists it for reuse after restart or unload.
local P = require("RailroaderRV/Power/RV_UtilityPowerConfig")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local World = require("RailroaderRV/Common/RV_ServerWorld")
local Util = require("RailroaderRV/Common/RV_ServerUtil")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")

local M = {}
local unknownLogged = {}
local oldListByRV = {}

local function invoke(target, method, ...)
    return Util.invoke(target, method, ...)
end

local instanceOf = Util.classInstance

local function spriteName(object)
    local sprite = object:getSprite()
    return sprite and sprite:getName() or ""
end

local function objectName(object)
    local value = object:getObjectName()
    return value ~= nil and tostring(value) or "IsoObject"
end

local function containerFor(object, kind)
    return object:getContainerByType(kind)
end

local function classify(object)
    local class = objectName(object)
    local deviceType, watts
    local fridge = containerFor(object, "fridge")
    local freezer = containerFor(object, "freezer")
    if fridge and freezer then
        deviceType, watts = "FridgeFreezer", P.DEVICE_POWER_W.FridgeFreezer
    elseif fridge then
        deviceType, watts = "Fridge", P.DEVICE_POWER_W.Fridge
    elseif freezer then
        deviceType, watts = "Freezer", P.DEVICE_POWER_W.Freezer
    elseif instanceOf(object, "IsoLightSwitch") then
        deviceType, class, watts = "Light", "IsoLightSwitch", P.DEVICE_POWER_W.Light
    elseif instanceOf(object, "IsoRadio") then
        deviceType, class, watts = "Radio", "IsoRadio", P.DEVICE_POWER_W.Radio
    elseif instanceOf(object, "IsoTelevision") then
        deviceType, class, watts = "TV", "IsoTelevision", P.DEVICE_POWER_W.TV
    elseif instanceOf(object, "IsoClothingWasher") then
        deviceType, class, watts = "Washer", "IsoClothingWasher", P.DEVICE_POWER_W.Washer
    elseif instanceOf(object, "IsoClothingDryer") then
        deviceType, class, watts = "Dryer", "IsoClothingDryer", P.DEVICE_POWER_W.Dryer
    elseif instanceOf(object, "IsoCombinationWasherDryer") then
        deviceType, class, watts = "WasherDryer", "IsoCombinationWasherDryer",
            P.DEVICE_POWER_W.Washer + P.DEVICE_POWER_W.Dryer
    elseif instanceOf(object, "IsoStackedWasherDryer") then
        deviceType, class, watts = "StackedWasherDryer", "IsoStackedWasherDryer",
            P.DEVICE_POWER_W.Washer + P.DEVICE_POWER_W.Dryer
    elseif instanceOf(object, "IsoStove") then
        local isMicrowave = object:isMicrowave()
        assert(type(isMicrowave) == "boolean",
            "RV powered stove returned an invalid microwave state")
        if isMicrowave then
            deviceType, class, watts = "Microwave", "IsoStove",
                P.DEVICE_POWER_W.Microwave
        else
            deviceType, class, watts = "Stove", "IsoStove", P.DEVICE_POWER_W.Stove
        end
    end
    if not deviceType then
        local key = class .. ":" .. spriteName(object)
        if not unknownLogged[key] then
            unknownLogged[key] = true
            print("[RailroaderRV] ignored powered object without a state adapter class="
                .. class .. " sprite=" .. spriteName(object))
        end
        return nil
    end
    return { deviceType = deviceType, objectClass = class,
        sprite = spriteName(object), ratedPowerW = watts }
end

local function poweredCandidate(object)
    local candidate = object:couldBePoweredByGenerator()
    assert(type(candidate) == "boolean",
        "RV powered object returned an invalid generator-power state")
    return candidate
end

local function stateError(deviceType, method)
    error("RV " .. deviceType .. " device getter failed: " .. method)
end

local function readBoolean(object, method, deviceType)
    local ok, value = invoke(object, method)
    if not ok or type(value) ~= "boolean" then stateError(deviceType, method) end
    return value
end

local function sampledDemand(object, description)
    local deviceType = description.deviceType
    if deviceType == "Fridge" or deviceType == "Freezer"
        or deviceType == "FridgeFreezer" then
        -- Cold storage requests power independently of whether the RV proxy
        -- currently supplies it; isPowered reports supply, not the request.
        return true, description.ratedPowerW
    end
    if deviceType == "WasherDryer" then
        if not readBoolean(object, "isActivated", deviceType) then return false, 0 end
        local isWasher = readBoolean(object, "isModeWasher", deviceType)
        return true, isWasher and P.DEVICE_POWER_W.Washer or P.DEVICE_POWER_W.Dryer
    end
    if deviceType == "StackedWasherDryer" then
        local washer = readBoolean(object, "isWasherActivated", deviceType)
        local dryer = readBoolean(object, "isDryerActivated", deviceType)
        local watts = (washer and P.DEVICE_POWER_W.Washer or 0)
            + (dryer and P.DEVICE_POWER_W.Dryer or 0)
        return watts > 0, watts
    end
    local active
    if deviceType == "Radio" or deviceType == "TV" then
        local data = object:getDeviceData()
        assert(data ~= nil, "RV powered entertainment device has no device data")
        local on = readBoolean(data, "getIsTurnedOn", deviceType)
        local batteryPowered = readBoolean(data, "getIsBatteryPowered", deviceType)
        active = on and not batteryPowered
        return active, active and description.ratedPowerW or 0
    end
    if deviceType == "Stove" or deviceType == "Microwave" then
        active = readBoolean(object, "Activated", deviceType)
    else
        active = readBoolean(object, "isActivated", deviceType)
    end
    return active, active and description.ratedPowerW or 0
end

local function staticDescription(class)
    local deviceType, watts
    if class == "IsoLightSwitch" then deviceType, watts = "Light", P.DEVICE_POWER_W.Light
    elseif class == "IsoRadio" then deviceType, watts = "Radio", P.DEVICE_POWER_W.Radio
    elseif class == "IsoTelevision" then deviceType, watts = "TV", P.DEVICE_POWER_W.TV
    elseif class == "IsoClothingWasher" then deviceType, watts = "Washer", P.DEVICE_POWER_W.Washer
    elseif class == "IsoClothingDryer" then deviceType, watts = "Dryer", P.DEVICE_POWER_W.Dryer
    elseif class == "IsoCombinationWasherDryer" then
        deviceType, watts = "WasherDryer", P.DEVICE_POWER_W.Washer + P.DEVICE_POWER_W.Dryer
    elseif class == "IsoStackedWasherDryer" then
        deviceType, watts = "StackedWasherDryer", P.DEVICE_POWER_W.Washer + P.DEVICE_POWER_W.Dryer
    end
    if not deviceType then return nil end
    return { deviceType = deviceType, objectClass = class,
        ratedPowerW = watts }
end

local function templateCandidates(template)
    local result = {}
    local objects = RoomTemplate.orderedObjects(template)
    for index = 1, #objects do
        local object = objects[index]
        if object.protected and (object.class == "IsoObject"
            or object.class == "IsoThumpable" or object.class == "IsoStove"
            or staticDescription(object.class)) then
            result[#result + 1] = {
                templateIndex = object.templateIndex,
                x = object.x, y = object.y, z = object.z,
                objectClass = object.class, sprite = object.sprite,
                description = staticDescription(object.class),
            }
        end
    end
    return result
end

local fixedTemplateCandidates = {}
for _, templateId in ipairs({ RoomTemplate.TEMPLATE_ID,
    RoomTemplate.ENGINE_AREA_TEMPLATE_ID }) do
    fixedTemplateCandidates[templateId] = templateCandidates(
        RoomTemplate.get(templateId))
end

local function cacheKey(device)
    return tostring(device.templateIndex or device.id)
end

local function copyDevice(device)
    local copy = {}
    for key, value in pairs(device) do copy[key] = value end
    return copy
end

local function emptyCache()
    return { template = {}, build = {} }
end

local function processState(identity, record)
    local rvId = tostring(identity.rvId)
    local cache = record.power.deviceCache
    assert(type(cache) == "table" and type(cache.template) == "table"
        and type(cache.build) == "table",
        "RV powered-device cache is missing a required list")
    local state = oldListByRV[rvId]
    if not state or state.generation ~= identity.generation then
        state = { generation = identity.generation,
            oldList = nil, isInitialized = false }
        oldListByRV[rvId] = state
    end
    if not state.isInitialized then
        state.oldList = cache
        state.isInitialized = true
    end
    record.power.deviceCache = state.oldList
    return state
end

function M.ensureInitialized(identity, record)
    return processState(identity, record).oldList
end

local function previousByTemplate(cache)
    local result = {}
    for i = 1, #cache do
        result[cacheKey(cache[i])] = cache[i]
    end
    return result
end

local function worldCoordinates(anchor, cell)
    return anchor.x + cell.x, anchor.y + cell.y,
        anchor.z + (cell.z or 0)
end

local function matchesTemplateObject(object, candidate)
    if spriteName(object) ~= candidate.sprite then return false end
    if candidate.objectClass == "IsoObject" then return true end
    if string.sub(candidate.objectClass, 1, 3) == "Iso" then
        return instanceOf(object, candidate.objectClass)
    end
    return objectName(object) == candidate.objectClass
end

local function templateSample(square, candidate, previous, x, y, z)
    local objects = square and World.squareSnapshot(square) or {}
    for i = 1, #objects do
        local object = objects[i]
        if matchesTemplateObject(object, candidate) and poweredCandidate(object) then
            local description = classify(object)
            if description then
                local active, demand = sampledDemand(object, description)
                return {
                    id = "template:" .. tostring(candidate.templateIndex),
                    templateIndex = candidate.templateIndex,
                    x = x, y = y, z = z,
                    objectClass = description.objectClass,
                    sprite = description.sprite,
                    deviceType = description.deviceType,
                    ratedPowerW = description.ratedPowerW,
                    active = active, demandPowerW = demand,
                }
            end
        end
    end
    if previous then return copyDevice(previous) end
    if candidate.description then
        return {
            id = "template:" .. tostring(candidate.templateIndex),
            templateIndex = candidate.templateIndex,
            x = x, y = y, z = z,
            objectClass = candidate.objectClass,
            sprite = candidate.sprite,
            deviceType = candidate.description.deviceType,
            ratedPowerW = candidate.description.ratedPowerW,
            active = false, demandPowerW = 0,
        }
    end
    return nil
end

local function buildSample(square, x, y, z, result)
    local objects = World.squareSnapshot(square)
    for i = 1, #objects do
        local object = objects[i]
        if poweredCandidate(object) then
            local description = classify(object)
            if description then
                local index = object:getObjectIndex()
                assert(type(index) == "number",
                    "RV powered build-area object has no object index")
                local active, demand = sampledDemand(object, description)
                local device = {
                    id = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
                        .. ":" .. tostring(index),
                    objectIndex = index, x = x, y = y, z = z,
                    objectClass = description.objectClass,
                    sprite = description.sprite,
                    deviceType = description.deviceType,
                    ratedPowerW = description.ratedPowerW,
                    active = active, demandPowerW = demand,
                }
                result[#result + 1] = device
            end
        end
    end
end

function M.initialize(record, identity)
    local oldList = emptyCache()
    oldListByRV[tostring(identity.rvId)] = {
        generation = identity.generation,
        oldList = oldList,
        isInitialized = true,
    }
    record.power.deviceCache = oldList
end

function M.scan(identity, record, player, slotIndex, templateId)
    local template = RoomTemplate.get(templateId)
    local state = processState(identity, record)
    local old = state.oldList
    local anchor = RegionSlots.indexToAnchor(slotIndex)
    local cell = World.getCellForPlayer(player)
    local squareMap, looked = {}, {}
    local function squareAt(rx, ry, rz)
        local x, y, z = anchor.x + rx, anchor.y + ry, anchor.z + rz
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if looked[key] then return squareMap[key], x, y, z, true end
        local square = World.getSquare(cell, x, y, z)
        if not square then return nil, x, y, z, false end
        squareMap[key] = square
        looked[key] = true
        return square, x, y, z, true
    end

    -- If any required square is unavailable, preserve the latest persisted
    -- snapshot. A later settlement can replace it after a complete scan.
    local buildSquares = {}
    for i = 1, #template.misc.buildCells do
        local definition = template.misc.buildCells[i]
        local square, x, y, z, loaded = squareAt(definition.x, definition.y,
            definition.z or 0)
        if not loaded then
            return false
        end
        buildSquares[i] = { square = square, x = x, y = y, z = z }
    end
    local templateSquares = {}
    local templateCandidates = fixedTemplateCandidates[templateId]
    for i = 1, #templateCandidates do
        local candidate = templateCandidates[i]
        local square, x, y, z, loaded = squareAt(candidate.x, candidate.y, candidate.z)
        if not loaded then
            return false
        end
        templateSquares[i] = { candidate = candidate, square = square,
            x = x, y = y, z = z }
    end

    local oldTemplate = previousByTemplate(old.template)
    local nextCache = emptyCache()
    for i = 1, #templateSquares do
        local entry = templateSquares[i]
        local previous = oldTemplate[tostring(entry.candidate.templateIndex)]
        local device = templateSample(entry.square, entry.candidate,
            previous, entry.x, entry.y, entry.z)
        if device then nextCache.template[#nextCache.template + 1] = device end
    end
    for i = 1, #buildSquares do
        local entry = buildSquares[i]
        if entry.square then
            buildSample(entry.square, entry.x, entry.y, entry.z, nextCache.build)
        end
    end
    state.oldList = nextCache
    record.power.deviceCache = state.oldList
    return true
end

function M.requestedLoadW(power)
    local total, activeCount = 0, 0
    local cache = power.deviceCache
    for i = 1, #cache.template do
        local device = cache.template[i]
        total = total + device.demandPowerW
        if device.active then activeCount = activeCount + 1 end
    end
    for i = 1, #cache.build do
        local device = cache.build[i]
        total = total + device.demandPowerW
        if device.active then activeCount = activeCount + 1 end
    end
    return total, activeCount
end

function M.count(power)
    local cache = power.deviceCache
    return #cache.template + #cache.build
end

function M.potentialLoadW(power)
    local total = 0
    local cache = power.deviceCache
    for i = 1, #cache.template do total = total + cache.template[i].ratedPowerW end
    for i = 1, #cache.build do total = total + cache.build[i].ratedPowerW end
    return total
end

return M
