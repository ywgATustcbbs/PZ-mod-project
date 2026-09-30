-- Server-only power-device discovery and type-specific state adapters.
-- The cache contains coordinates and primitive identity data, never IsoObject references.
local C = require("RailroaderRV/Common/RV_Constants")
local P = require("RailroaderRV/Power/RV_UtilityPowerConfig")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local World = require("RailroaderRV/Common/RV_ServerWorld")
local Util = require("RailroaderRV/Common/RV_ServerUtil")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local TemplateGeometry = require("RailroaderRV/RoomTemplate/RV_TemplateGeometry")
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)

local M = {}
local caches = {}
local scans = {}
local unknownLogged = {}

local function invoke(target, method, ...)
    return Util.invoke(target, method, ...)
end

local instanceOf = Util.classInstance

local function spriteName(object)
    local spriteOk, sprite = invoke(object, "getSprite")
    if not spriteOk or not sprite then return "" end
    local nameOk, name = invoke(sprite, "getName")
    return nameOk and tostring(name or "") or ""
end

local function objectName(object)
    local ok, value = invoke(object, "getObjectName")
    if ok and value ~= nil then return tostring(value) end
    return "IsoObject"
end

local function containerFor(object, kind)
    local ok, container = invoke(object, "getContainerByType", kind)
    return ok and container or nil
end

local function booleanResult(ok, value)
    if not ok or type(value) ~= "boolean" then return nil end
    return value
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
        local microwaveOk, isMicrowave = invoke(object, "isMicrowave")
        if microwaveOk and type(isMicrowave) == "boolean" then
            if isMicrowave then
                deviceType, class, watts = "Microwave", "IsoStove",
                    P.DEVICE_POWER_W.Microwave
            else
                deviceType, class, watts = "Stove", "IsoStove",
                    P.DEVICE_POWER_W.Stove
            end
        end
    end
    if not deviceType then
        local name = objectName(object)
        local sprite = spriteName(object)
        local key = name .. ":" .. sprite
        if not unknownLogged[key] then
            unknownLogged[key] = true
            print("[RailroaderRVTest] ignored powered object without a state adapter class="
                .. name .. " sprite=" .. sprite)
        end
        return nil
    end
    return { deviceType = deviceType, objectClass = class, sprite = spriteName(object),
        ratedPowerW = watts }
end

local function poweredCandidate(object)
    local ok, candidate = invoke(object, "couldBePoweredByGenerator")
    return ok and candidate == true
end

local function readActive(object, deviceType)
    if deviceType == "Light" then
        local ok, value = invoke(object, "isActivated")
        return booleanResult(ok, value)
    end
    if deviceType == "Radio" or deviceType == "TV" then
        local dataOk, data = invoke(object, "getDeviceData")
        if not dataOk or not data then return nil end
        local onOk, on = invoke(data, "getIsTurnedOn")
        local batteryOk, battery = invoke(data, "getIsBatteryPowered")
        if not onOk or type(on) ~= "boolean" or not batteryOk
            or type(battery) ~= "boolean" then return nil end
        return on and not battery
    end
    if deviceType == "Fridge" or deviceType == "Freezer"
        or deviceType == "FridgeFreezer" then
        local container = deviceType == "Fridge" and containerFor(object, "fridge")
            or deviceType == "Freezer" and containerFor(object, "freezer")
            or containerFor(object, "fridge") or containerFor(object, "freezer")
        local ok, powered = invoke(container, "isPowered")
        return booleanResult(ok, powered)
    end
    if deviceType == "Washer" or deviceType == "Dryer" or deviceType == "WasherDryer" then
        local ok, active = invoke(object, "isActivated")
        return booleanResult(ok, active)
    end
    if deviceType == "Stove" or deviceType == "Microwave" then
        local ok, active = invoke(object, "Activated")
        return booleanResult(ok, active)
    end
    return nil
end

local function devicePowerW(object, deviceType, ratedPowerW, circuitOn)
    if not circuitOn then return 0 end
    if deviceType == "WasherDryer" then
        local active = readActive(object, deviceType)
        if active == nil then return nil end
        if not active then return 0 end
        local modeOk, isWasher = invoke(object, "isModeWasher")
        isWasher = booleanResult(modeOk, isWasher)
        if isWasher == nil then return nil end
        return isWasher and P.DEVICE_POWER_W.Washer or P.DEVICE_POWER_W.Dryer
    end
    if deviceType == "StackedWasherDryer" then
        local washerOk, washerActive = invoke(object, "isWasherActivated")
        local dryerOk, dryerActive = invoke(object, "isDryerActivated")
        if not washerOk or type(washerActive) ~= "boolean"
            or not dryerOk or type(dryerActive) ~= "boolean" then return nil end
        return (washerActive and P.DEVICE_POWER_W.Washer or 0)
            + (dryerActive and P.DEVICE_POWER_W.Dryer or 0)
    end
    local active = readActive(object, deviceType)
    if active == nil then return nil end
    return active and ratedPowerW or 0
end

local function squareCoordinates(square)
    local xOk, x = invoke(square, "getX")
    local yOk, y = invoke(square, "getY")
    local zOk, z = invoke(square, "getZ")
    x, y, z = Util.integer(x), Util.integer(y), Util.integer(z)
    if not xOk or not yOk or not zOk or x == nil or y == nil or z == nil then
        return nil
    end
    return x, y, z
end

local function objectIndex(object)
    local ok, value = invoke(object, "getObjectIndex")
    return ok and Util.integer(value) or nil
end

local function deviceId(device)
    return tostring(device.x) .. ":" .. tostring(device.y) .. ":"
        .. tostring(device.z) .. ":" .. tostring(device.objectIndex or 0)
end

local function scanSquare(identity, player, x, y, z)
    local cellOk, cell = pcall(World.getCellForPlayer, player)
    if not cellOk or not cell then return false end
    local squareOk, square = pcall(World.getSquare, cell, x, y, z)
    if not squareOk or not square then return false end
    local sx, sy, sz = squareCoordinates(square)
    if sx == nil then return false end
    local objectsOk, objects = pcall(World.squareSnapshot, square)
    if not objectsOk or type(objects) ~= "table" then return false end
    local key = Util.identityKey(identity.rvId, identity.generation)
    local cache = caches[key] or {}
    caches[key] = cache
    local prefix = tostring(sx) .. ":" .. tostring(sy) .. ":" .. tostring(sz) .. ":"
    local previous = {}
    for id, device in pairs(cache) do
        if string.sub(id, 1, #prefix) == prefix then
            previous[id] = device
            cache[id] = nil
        end
    end
    for i = 1, #objects do
        local object = objects[i]
        if poweredCandidate(object) then
            local description = classify(object)
            local index = objectIndex(object)
            if description and index ~= nil then
                local device = {
                    x = sx, y = sy, z = sz, objectIndex = index,
                    objectClass = description.objectClass,
                    sprite = description.sprite,
                    deviceType = description.deviceType,
                    ratedPowerW = description.ratedPowerW,
                    lastKnownActive = false,
                    stateKnown = false,
                    resolved = false,
                }
                device.id = deviceId(device)
                local old = previous[device.id]
                if old and old.objectClass == device.objectClass
                    and old.sprite == device.sprite and old.deviceType == device.deviceType then
                    device.lastKnownActive = old.lastKnownActive
                    device.lastKnownPowerW = old.lastKnownPowerW
                    device.stateKnown = old.stateKnown
                    device.resolved = old.resolved
                end
                cache[device.id] = device
            end
        end
    end
    return true
end

local function interior(record)
    local slotIndex = type(record) == "table" and record.slotIndex or nil
    local anchor = slotIndex and RegionSlots.indexToAnchor(slotIndex) or nil
    if not anchor then return nil end
    local coords, seen = {}, {}
    for _, box in ipairs(Template.misc.walkAabbs) do
        for z = box.minZ, box.maxZExclusive - 1 do
            for y = box.minY, box.maxY - 1 do
                for x = box.minX, box.maxX - 1 do
                    local world = { x = anchor.x + x, y = anchor.y + y,
                        z = anchor.z + z }
                    if TemplateGeometry.isWalkable(world, anchor, Template) then
                        local coordinate = tostring(world.x) .. ":"
                            .. tostring(world.y) .. ":" .. tostring(world.z)
                        if not seen[coordinate] then
                            seen[coordinate] = true
                            coords[#coords + 1] = world
                        end
                    end
                end
            end
        end
    end
    return coords
end

function M.scanAll(identity, record, player)
    local squares = interior(record)
    if not squares then return false, "RV interior coordinates are invalid" end
    for i = 1, #squares do
        local square = squares[i]
        if not scanSquare(identity, player, square.x, square.y, square.z) then
            return false, "RV device square scan failed"
        end
    end
    local key = Util.identityKey(identity.rvId, identity.generation)
    scans[key] = { cursor = 1 }
    return true
end

function M.scanTick(identity, record, player)
    local squares = interior(record)
    if not squares then return false end
    local key = Util.identityKey(identity.rvId, identity.generation)
    local state = scans[key] or { cursor = 1 }
    scans[key] = state
    for _ = 1, P.DEVICE_SCAN_SQUARES_PER_TICK do
        local square = squares[state.cursor]
        if not square then state.cursor = 1; square = squares[1] end
        scanSquare(identity, player, square.x, square.y, square.z)
        state.cursor = state.cursor + 1
        if state.cursor > #squares then state.cursor = 1 end
    end
    return true
end

local function resolveDevice(identity, device, player)
    local cellOk, cell = pcall(World.getCellForPlayer, player)
    if not cellOk or not cell then return nil end
    local squareOk, square = pcall(World.getSquare, cell, device.x, device.y, device.z)
    if not squareOk or not square then return nil end
    local objectsOk, objects = pcall(World.squareSnapshot, square)
    if not objectsOk or type(objects) ~= "table" then return nil end
    for i = 1, #objects do
        local object = objects[i]
        local sameClass = string.sub(device.objectClass, 1, 3) == "Iso"
            and instanceOf(object, device.objectClass)
            or objectName(object) == device.objectClass
        if objectIndex(object) == device.objectIndex
            and poweredCandidate(object)
            and sameClass
            and spriteName(object) == device.sprite then
            local description = classify(object)
            if description and description.deviceType == device.deviceType then
                return object
            end
        end
    end
    return nil
end

function M.refreshStates(identity, player, circuitOn)
    local cache = caches[Util.identityKey(identity.rvId, identity.generation)] or {}
    for _, device in pairs(cache) do
        local object = resolveDevice(identity, device, player)
        device.resolved = object ~= nil
        if object then
            local watts = devicePowerW(object, device.deviceType,
                device.ratedPowerW, circuitOn)
            if type(watts) == "number" then
                device.lastKnownPowerW = watts
                device.lastKnownActive = watts > 0
                device.stateKnown = true
            end
        end
    end
end

function M.resolveCached(identity, player)
    local cache = caches[Util.identityKey(identity.rvId, identity.generation)] or {}
    for _, device in pairs(cache) do
        device.resolved = resolveDevice(identity, device, player) ~= nil
    end
end

function M.currentLoadW(identity)
    local total, count = 0, 0
    local cache = caches[Util.identityKey(identity.rvId, identity.generation)] or {}
    for _, device in pairs(cache) do
        if device.resolved and device.stateKnown and device.lastKnownActive == true then
            total = total + (device.lastKnownPowerW or device.ratedPowerW)
            count = count + 1
        end
    end
    return total, count
end

function M.count(identity)
    local count = 0
    for _ in pairs(caches[Util.identityKey(identity.rvId, identity.generation)] or {}) do
        count = count + 1
    end
    return count
end

function M.clear(identity)
    local key = Util.identityKey(identity.rvId, identity.generation)
    caches[key] = nil
    scans[key] = nil
end

return M
