-- Server-authoritative sink connection commands.
--
-- One call performs the whole transaction in order: resolve the world object,
-- check distance and permission, set the native plumbing state, then update the
-- canonical water record.

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
    if not hasPipeWrench(context.player) then
        return false, U.REASONS.MISSING_TOOL
    end
    local resolved, sinkOrReason = Objects.resolveSink(identity, context, hint)
    if not resolved then return false, sinkOrReason end
    local sink = sinkOrReason
    local _, deviceKey = Ledger.getEntry(record.water, sink)

    local tagged, tagReason = Objects.ensureSinkIdentity(sink.object, identity,
        context.record)
    if not tagged then return false, tagReason end

    local desired = sink.connected
    local applied, applyReason = Plumbing.apply(sink.object, desired)
    if not applied then return false, applyReason end

    if desired then
        record.water.sinks[deviceKey] = Ledger.newEntry(sink)
    else
        record.water.sinks[deviceKey] = nil
    end
    Store.commit(record, identity)
    return true, { record = record, connected = desired }
end

return M
