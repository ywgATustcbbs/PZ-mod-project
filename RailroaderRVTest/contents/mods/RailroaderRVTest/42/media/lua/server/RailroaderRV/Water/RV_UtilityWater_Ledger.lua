-- Strict current-schema sink connection state. Fluid amounts remain native.

local C = require("RailroaderRV/Common/RV_Constants")
local Store = require("RailroaderRV/Core/RV_UtilityStore")

local M = {}

-- A sink entry is addressed by its world coordinates.  Its RV identity and slot
-- are already proven by the caller's current mapping record, and the anchor is a
-- pure function of the slot, so nothing but the connection facts is stored.
function M.sinkKey(sink)
    if type(sink) ~= "table" then return nil end
    return Store.waterSinkKey(sink.x, sink.y, sink.z)
end

function M.getEntry(water, identity, mappingRecord, sink)
    local key = M.sinkKey(sink)
    if not key then return false, C.INVALID_RV_DATA end
    return true, water.sinks[key], key
end

function M.newEntry(identity, mappingRecord, sink, connected, sequence)
    return {
        x = sink.x, y = sink.y, z = sink.z,
        connected = connected == true,
        sequence = sequence or 0,
    }
end

function M.copyEntry(entry)
    if type(entry) ~= "table" then return nil end
    return {
        x = entry.x, y = entry.y, z = entry.z,
        connected = entry.connected,
        sequence = entry.sequence,
    }
end

return M
