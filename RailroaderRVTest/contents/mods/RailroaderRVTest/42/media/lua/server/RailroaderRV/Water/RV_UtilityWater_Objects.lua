-- Resolve one sink from an untrusted object hint against the current RV map.

local C = require("RailroaderRV/Common/RV_Constants")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local Catalog = require("RailroaderRV/Water/RV_UtilityCatalog")
local Util = require("RailroaderRV/Common/RV_ServerUtil")
local World = require("RailroaderRV/Common/RV_ServerWorld")
local StrictSchema = require("RailroaderRV/Common/RV_StrictSchema")

local M = {}

local function exactKeys(value, expected)
    if type(value) ~= "table" then return false end
    local allowed = {}
    for i = 1, #expected do allowed[expected[i]] = true end
    local count = 0
    for key in pairs(value) do
        if not allowed[key] then return false end
        count = count + 1
    end
    return count == #expected
end

local integer = StrictSchema.integer

local function validContext(context, identity)
    local record = context and context.record
    if type(identity) ~= "table" or type(record) ~= "table"
        or context.authorized ~= true or context.phase ~= "READY"
        or record.rvId ~= identity.rvId
        or integer(record.generation) ~= integer(identity.generation)
        or integer(record.bitmapVersion) ~= integer(identity.bitmapVersion)
        or integer(record.slotIndex) == nil then
        return false
    end
    local expectedAnchor = RegionSlots.indexToAnchor(record.slotIndex)
    local region = RegionSlots.indexToRegion(record.slotIndex)
    local anchor = record.anchor
    if not expectedAnchor or not region or type(anchor) ~= "table"
        or anchor.x ~= expectedAnchor.x or anchor.y ~= expectedAnchor.y
        or anchor.z ~= expectedAnchor.z
        or RegionSlots.indexForAnchor(anchor) ~= record.slotIndex then
        return false
    end
    return true, record, expectedAnchor, region
end

local function withinReach(player, x, y, z)
    local xOk, playerX = Util.invoke(player, "getX")
    local yOk, playerY = Util.invoke(player, "getY")
    local zOk, playerZ = Util.invoke(player, "getZ")
    if not xOk or not yOk or not zOk
        or not Util.isFiniteNumber(playerX) or not Util.isFiniteNumber(playerY)
        or not Util.isFiniteNumber(playerZ) then
        return false
    end
    local dx, dy, dz = playerX - x, playerY - y, playerZ - z
    return dx * dx + dy * dy + dz * dz <= U.DEVICE_REACH * U.DEVICE_REACH
end

local function hintValues(hint)
    if not exactKeys(hint, { "x", "y", "z", "objectIndex", "connected" })
        or type(hint.connected) ~= "boolean" then
        return nil
    end
    local x, y, z = integer(hint.x), integer(hint.y), integer(hint.z)
    local index = integer(hint.objectIndex)
    if not x or not y or not z or not index or index < 0 then return nil end
    return x, y, z, index, hint.connected
end

local function findHintedObject(square, index)
    local objects = World.squareSnapshot(square)
    local matches = {}
    for i = 1, #objects do
        local object = objects[i]
        local indexOk, objectIndex = Util.invoke(object, "getObjectIndex")
        if indexOk and integer(objectIndex) == index then
            matches[#matches + 1] = object
        end
    end
    if #matches ~= 1 then return nil end
    return matches[1]
end

function M.resolveSink(identity, context, hint)
    local x, y, z, objectIndex, connected = hintValues(hint)
    if x == nil then return false, U.REASONS.INVALID_REQUEST end
    local contextOk, record, anchor, region = validContext(context, identity)
    if not contextOk then return false, C.INVALID_RV_DATA end

    local minZ = anchor.z + C.RV_MANAGED_MIN_Z_OFFSET
    local maxZ = anchor.z + C.RV_MANAGED_MAX_Z_OFFSET
    if x < region.minX or x >= region.maxX or y < region.minY
        or y >= region.maxY or z < minZ or z >= maxZ then
        return false, U.REASONS.DEVICE_NOT_CURRENT
    end
    if not withinReach(context.player, x, y, z) then
        return false, U.REASONS.PERMISSION
    end

    local cellOk, cell = pcall(World.getCellForPlayer, context.player)
    if not cellOk or not cell then return false, U.REASONS.TARGET_NOT_LOADED end
    local square = World.getSquare(cell, x, y, z)
    if not square then return false, U.REASONS.TARGET_NOT_LOADED end
    local object = findHintedObject(square, objectIndex)
    if not object then return false, U.REASONS.DEVICE_INVALID end
    local squareOk, actualSquare = Util.invoke(object, "getSquare")
    if not squareOk or actualSquare ~= square
        or not Catalog.hasFluidContainer(object) then
        return false, U.REASONS.DEVICE_NOT_CURRENT
    end
    local externalOk, external = Util.invoke(object, "getUsesExternalWaterSource")
    if not externalOk or type(external) ~= "boolean" then
        return false, U.REASONS.API_ERROR
    end
    local hasIdentity = Catalog.hasSinkIdentity(object)
    if hasIdentity and not Catalog.isCurrentWaterSink(object, identity, record) then
        return false, U.REASONS.DEVICE_NOT_CURRENT
    end
    if not hasIdentity and not Catalog.isWaterPipedDevice(object) and external ~= true then
        return false, U.REASONS.DEVICE_NOT_SUPPORTED
    end
    return true, {
        object = object,
        x = x, y = y, z = z,
        slotIndex = record.slotIndex,
        anchor = anchor,
        connected = connected,
        currentConnected = external,
        hasIdentity = hasIdentity,
    }
end

function M.ensureSinkIdentity(object, identity, mappingRecord)
    if Catalog.hasSinkIdentity(object) then
        if Catalog.isCurrentWaterSink(object, identity, mappingRecord) then
            return true, { created = false }
        end
        return false, U.REASONS.DEVICE_NOT_CURRENT, true
    end
    local dataOk, data = Util.invoke(object, "getModData")
    if not dataOk or type(data) ~= "table" then
        return false, U.REASONS.API_ERROR, true
    end
    if data[Catalog.WATER_TAG_KEY] ~= nil then
        return false, U.REASONS.DEVICE_NOT_CURRENT, true
    end
    local tag = {
        owner = C.MOD_ID,
        role = "sink",
        rvId = identity.rvId,
        generation = identity.generation,
        bitmapVersion = identity.bitmapVersion,
        slotIndex = mappingRecord.slotIndex,
        anchor = { x = mappingRecord.anchor.x, y = mappingRecord.anchor.y,
            z = mappingRecord.anchor.z },
    }
    data[Catalog.WATER_TAG_KEY] = tag
    if Util.callSucceeded(object, "transmitModData")
        and Catalog.isCurrentWaterSink(object, identity, mappingRecord) then
        return true, { created = true, tag = tag }
    end
    data[Catalog.WATER_TAG_KEY] = nil
    local restored = Util.callSucceeded(object, "transmitModData")
        and not Catalog.hasSinkIdentity(object)
    return false, U.REASONS.POSTCONDITION_FAILED, restored
end

function M.rollbackSinkIdentity(object, identityToken)
    if type(identityToken) ~= "table" or identityToken.created ~= true then return true end
    local dataOk, data = Util.invoke(object, "getModData")
    if not dataOk or type(data) ~= "table"
        or data[Catalog.WATER_TAG_KEY] ~= identityToken.tag then return false end
    data[Catalog.WATER_TAG_KEY] = nil
    return Util.callSucceeded(object, "transmitModData")
        and not Catalog.hasSinkIdentity(object)
end

return M
