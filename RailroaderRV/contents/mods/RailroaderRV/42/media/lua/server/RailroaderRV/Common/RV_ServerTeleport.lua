-- Shared server-authoritative teleport operations.
local M = {}
local Common = require("RailroaderRV/Common/RV_Common")

function M.teleportToPosition(player, position)
    if not player or type(position) ~= "table"
        or not Common.isFiniteNumber(position.x) or not Common.isFiniteNumber(position.y)
        or not Common.isFiniteNumber(position.z) or type(player.teleportTo) ~= "function" then
        return false
    end
    local ok, result = pcall(player.teleportTo, player,
        position.x, position.y, position.z)
    return ok and result ~= false
end

-- Resolve the spawn from the server's current mapping. The caller supplies an
-- already validated mapping identity, never coordinates from a client packet.
function M.teleportToRVSpawn(player, source, expectedPosition)
    if type(source) ~= "table" then return false end
    local rv = rawget(_G, "RailroaderRV")
    local adapter = rv and rv.RailroaderServer
    if not adapter or type(adapter.currentMappingRecord) ~= "function" then
        return false
    end
    local ok, record = adapter.currentMappingRecord(source.rvId,
        source.generation)
    if ok ~= true or type(record) ~= "table"
        or type(record.rvPosition) ~= "table" then
        return false
    end
    local target = record.rvPosition
    if not Common.isFiniteNumber(target.x) or not Common.isFiniteNumber(target.y)
        or not Common.isFiniteNumber(target.z) then
        return false
    end
    if expectedPosition and (target.x ~= expectedPosition.x
        or target.y ~= expectedPosition.y or target.z ~= expectedPosition.z) then
        return false
    end
    if not M.teleportToPosition(player, target) then return false end
    return true, target
end

return M
