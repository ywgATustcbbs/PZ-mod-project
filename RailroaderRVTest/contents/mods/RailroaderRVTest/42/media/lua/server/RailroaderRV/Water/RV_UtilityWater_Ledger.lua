-- Strict current-schema sink connection state. Fluid amounts remain native.

local C = require("RailroaderRV/Common/RV_Constants")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local Store = require("RailroaderRV/Core/RV_UtilityStore")

local M = {}

local function sameAnchor(a, b)
    return type(a) == "table" and type(b) == "table"
        and a.x == b.x and a.y == b.y and a.z == b.z
end

local function mappedEntry(entry, identity, mappingRecord, sink)
    return type(entry) == "table"
        and tostring(entry.rvId) == tostring(identity.rvId)
        and entry.generation == identity.generation
        and entry.bitmapVersion == identity.bitmapVersion
        and entry.slotIndex == mappingRecord.slotIndex
        and sameAnchor(entry.anchor, mappingRecord.anchor)
        and entry.x == sink.x and entry.y == sink.y and entry.z == sink.z
end

function M.validateMapping(water, identity, mappingRecord)
    if type(water) ~= "table" or water.schemaVersion ~= U.WATER_SCHEMA_VERSION
        or type(water.sinks) ~= "table"
        or (water.state ~= U.WATER_STATE_ACTIVE
            and water.state ~= U.WATER_STATE_NEEDS_RECONCILE)
        or type(identity) ~= "table" or type(mappingRecord) ~= "table" then
        return false, C.INVALID_RV_DATA
    end
    local anchor = RegionSlots.indexToAnchor(mappingRecord.slotIndex)
    if not anchor or not sameAnchor(anchor, mappingRecord.anchor)
        or RegionSlots.indexForAnchor(mappingRecord.anchor) ~= mappingRecord.slotIndex then
        return false, C.INVALID_RV_DATA
    end
    for _, entry in pairs(water.sinks) do
        if not mappedEntry(entry, identity, mappingRecord, entry) then
            return false, C.INVALID_RV_DATA
        end
    end
    if water.state ~= U.WATER_STATE_ACTIVE then return false, C.INVALID_RV_DATA end
    return true
end

function M.sinkKey(sink)
    if type(sink) ~= "table" then return nil end
    return Store.waterSinkKey(sink.x, sink.y, sink.z)
end

function M.getEntry(water, identity, mappingRecord, sink)
    local key = M.sinkKey(sink)
    if not key then return false, C.INVALID_RV_DATA end
    local entry = water.sinks[key]
    if entry ~= nil and not mappedEntry(entry, identity, mappingRecord, sink) then
        return false, C.INVALID_RV_DATA
    end
    return true, entry, key
end

function M.newEntry(identity, mappingRecord, sink, connected, sequence)
    return {
        rvId = identity.rvId,
        generation = identity.generation,
        bitmapVersion = identity.bitmapVersion,
        slotIndex = mappingRecord.slotIndex,
        anchor = { x = mappingRecord.anchor.x, y = mappingRecord.anchor.y,
            z = mappingRecord.anchor.z },
        x = sink.x, y = sink.y, z = sink.z,
        connected = connected == true,
        sequence = sequence or 0,
    }
end

function M.copyEntry(entry)
    if type(entry) ~= "table" then return nil end
    return {
        rvId = entry.rvId,
        generation = entry.generation,
        bitmapVersion = entry.bitmapVersion,
        slotIndex = entry.slotIndex,
        anchor = { x = entry.anchor.x, y = entry.anchor.y, z = entry.anchor.z },
        x = entry.x, y = entry.y, z = entry.z,
        connected = entry.connected,
        sequence = entry.sequence,
    }
end

return M
