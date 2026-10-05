-- Authoritative server-side Water entry points.

local W = require("RailroaderRV/Water/RV_UtilityWaterConstants")
local Commands = require("RailroaderRV/Water/RV_UtilityWater_Commands")
local Settlement = require("RailroaderRV/Water/RV_UtilityWater_Settlement")
local Parts = require("RailroaderRV/Water/RV_UtilityWater_Parts")
local Sources = require("RailroaderRV/Water/RV_UtilityWater_Sources")

local M = {}

M.CONSTANTS = W

function M.setConnection(identity, context, targetHint, record)
    return Commands.setConnection(identity, context, targetHint, record)
end

function M.settleWater(identity, mappingRecord, waterIntent, powerState)
    return Settlement.settleWater(identity, mappingRecord, waterIntent,
        powerState)
end

function M.initializeRecord(record, proxyDefinitions)
    return Settlement.initializeRecord(record, proxyDefinitions)
end

function M.isPartsOperation(operation)
    return Parts.isPartsOperation(operation)
end

function M.performPartsAction(context, operation, itemId, record)
    return Parts.perform(context, operation, itemId, record)
end

function M.isTransferOperation(operation)
    return operation == W.OP_ADD_WATER_FROM_CONTAINER
        or operation == W.OP_DRAW_WATER_FROM_SOURCE
end

function M.isTimedActionOperation(operation)
    return M.isTransferOperation(operation) or M.isPartsOperation(operation)
end

function M.validateContainerSource(player, itemId, record)
    return Parts.validateContainerSource(player, itemId, record)
end

function M.validateDrawSource(player, sourceHint, record)
    return Parts.validateDrawSource(player, sourceHint, record.water)
end

function M.resolveNaturalSource(player, sourceHint)
    return Sources.resolveNaturalSource(player, sourceHint)
end

function M.exactWaterKind(fluidContainer)
    return Sources.exactWaterKind(fluidContainer)
end

return M
