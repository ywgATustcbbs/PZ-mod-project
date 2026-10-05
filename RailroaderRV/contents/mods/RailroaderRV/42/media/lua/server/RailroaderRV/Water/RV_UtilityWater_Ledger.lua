-- Strict current-schema sink connection state. Fluid amounts remain native.

local Store = require("RailroaderRV/Core/RV_UtilityStore")

local M = {}

-- A sink entry is addressed by its world coordinates.  Its RV identity and slot
-- are already proven by the caller's current mapping record, and the anchor is a
-- pure function of the slot, so nothing but the connection facts is stored.
function M.sinkKey(sink)
    return Store.waterSinkKey(sink.x, sink.y, sink.z)
end

function M.getEntry(water, sink)
    local key = M.sinkKey(sink)
    return water.sinks[key], key
end

function M.newEntry(sink)
    return {
        x = sink.x, y = sink.y, z = sink.z,
        connected = true,
    }
end

return M
