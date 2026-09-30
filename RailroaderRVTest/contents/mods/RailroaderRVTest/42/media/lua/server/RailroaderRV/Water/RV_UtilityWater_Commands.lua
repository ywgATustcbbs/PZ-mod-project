-- Server-authoritative sink connection commands.
--
-- One call performs the whole transaction in order: resolve the world object,
-- check distance and permission, set the native plumbing state, then update the
-- canonical water record.

local C = require("RailroaderRV/Common/RV_Constants")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local Store = require("RailroaderRV/Core/RV_UtilityStore")
local Util = require("RailroaderRV/Common/RV_ServerUtil")
local Objects = require("RailroaderRV/Water/RV_UtilityWater_Objects")
local Ledger = require("RailroaderRV/Water/RV_UtilityWater_Ledger")
local Plumbing = require("RailroaderRV/Water/RV_UtilityWater_Plumbing")

local M = {}

local function hasPipeWrench(player)
    local inventoryOk, inventory = Util.invoke(player, "getInventory")
    if not inventoryOk or not inventory then return false end
    local containsOk, contains = Util.invoke(inventory, "contains", "Base.PipeWrench")
    return containsOk and contains == true
end

function M.setConnection(identity, context, hint, record)
    if type(record) ~= "table" or type(record.water) ~= "table" then
        return false, C.INVALID_RV_DATA
    end
    if record.water.state ~= U.WATER_STATE_ACTIVE then
        return false, C.INVALID_RV_DATA
    end
    if not hasPipeWrench(context and context.player) then
        return false, U.REASONS.MISSING_TOOL
    end
    local resolved, sinkOrReason = Objects.resolveSink(identity, context, hint)
    if not resolved then return false, sinkOrReason end
    local sink = sinkOrReason
    local entryOk, oldEntry, deviceKey = Ledger.getEntry(record.water, sink)
    if not entryOk then return false, C.INVALID_RV_DATA end

    local tagged, tagReason = Objects.ensureSinkIdentity(sink.object, identity,
        context.record)
    if not tagged then return false, tagReason end

    local desired = sink.connected
    local applied, applyReason = Plumbing.apply(sink.object, desired)
    if not applied then return false, applyReason end

    local sequence = oldEntry and oldEntry.sequence + 1 or 1
    record.water.sinks[deviceKey] = Ledger.newEntry(sink, desired, sequence)
    local committed, commitReason = Store.commit(record, identity)
    if not committed then return false, commitReason end
    return true, { record = record, connected = desired }
end

return M
