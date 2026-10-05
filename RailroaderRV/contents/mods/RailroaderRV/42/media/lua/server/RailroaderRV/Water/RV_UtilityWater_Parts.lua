-- Water component mutations and their reversible inventory transactions.

local U = require("RailroaderRV/Common/RV_UtilityConstants")
local W = require("RailroaderRV/Water/RV_UtilityWaterConstants")
local Inventory = require("RailroaderRV/Core/RV_ServerInventoryTransaction")
local Sources = require("RailroaderRV/Water/RV_UtilityWater_Sources")

local M = {}

local partOperations = {
    [W.OP_INSTALL_WATER_TANK] = true,
    [W.OP_REMOVE_WATER_TANK] = true,
    [W.OP_INSTALL_SUPPLY_PUMP] = true,
    [W.OP_INSTALL_EXTRACTION_PUMP] = true,
    [W.OP_REMOVE_EXTRACTION_PUMP] = true,
    [W.OP_INSTALL_WATER_FILTER] = true,
    [W.OP_REMOVE_WATER_FILTER] = true,
}

function M.isPartsOperation(operation)
    return partOperations[operation] == true
end

local function foundItem(player, itemId, expectedFullType)
    local found = Inventory.findItem(player, itemId)
    if not found then return nil, U.REASONS.SOURCE_NOT_INVENTORY end
    if found.item:getFullType() ~= expectedFullType then
        return nil, U.REASONS.SOURCE_INVALID
    end
    return found
end

local function installItem(context, itemId, fullType, transaction)
    local found, reason = foundItem(context.player, itemId, fullType)
    if not found then return false, reason end
    transaction:consumeFound(found)
    return true, found.item
end

function M.perform(context, operation, itemId, record)
    local water = record.water
    local transaction = Inventory.new(context.player)

    if operation == W.OP_INSTALL_WATER_TANK then
        if water.tankCount >= W.MAX_WATER_TANKS then
            return false, U.REASONS.CAPACITY_FULL
        end
        local installed, itemOrReason = installItem(context, itemId,
            W.WATER_TANK_ITEM, transaction)
        if not installed then return false, itemOrReason end
        water.tankCount = water.tankCount + 1
    elseif operation == W.OP_REMOVE_WATER_TANK then
        if water.tankCount <= 0 then return false, U.REASONS.DEVICE_INVALID end
        water.tankCount = water.tankCount - 1
        transaction:returnItem(context.player:getInventory(),
            Inventory.createItem(W.WATER_TANK_ITEM))
    elseif operation == W.OP_INSTALL_SUPPLY_PUMP then
        if water.supplyPumpInstalled then
            return false, U.REASONS.DEVICE_INVALID
        end
        local installed, itemOrReason = installItem(context, itemId,
            W.SMALL_PUMP_ITEM, transaction)
        if not installed then return false, itemOrReason end
        water.supplyPumpInstalled = true
    elseif operation == W.OP_INSTALL_EXTRACTION_PUMP then
        if water.extractionPump ~= nil then
            return false, U.REASONS.DEVICE_INVALID
        end
        local found = Inventory.findItem(context.player, itemId)
        if not found then return false, U.REASONS.SOURCE_NOT_INVENTORY end
        local fullType = found.item:getFullType()
        if fullType == W.SMALL_PUMP_ITEM then
            water.extractionPump = "small"
        elseif fullType == W.INDUSTRIAL_PUMP_ITEM then
            water.extractionPump = "industrial"
        else
            return false, U.REASONS.SOURCE_INVALID
        end
        transaction:consumeFound(found)
    elseif operation == W.OP_REMOVE_EXTRACTION_PUMP then
        if water.extractionPump == nil then
            return false, U.REASONS.DEVICE_INVALID
        end
        local fullType
        if water.extractionPump == "small" then
            fullType = W.SMALL_PUMP_ITEM
        elseif water.extractionPump == "industrial" then
            fullType = W.INDUSTRIAL_PUMP_ITEM
        else
            error("RailroaderRV: unknown installed water extraction pump")
        end
        water.extractionPump = nil
        transaction:returnItem(context.player:getInventory(),
            Inventory.createItem(fullType))
    elseif operation == W.OP_INSTALL_WATER_FILTER then
        if water.filter ~= nil then return false, U.REASONS.CAPACITY_FULL end
        local found, reason = foundItem(context.player, itemId,
            W.WATER_FILTER_ITEM)
        if not found then return false, reason end
        local condition = found.item:getCondition()
        transaction:consumeFound(found)
        water.filter = { fullType = W.WATER_FILTER_ITEM,
            condition = condition }
    elseif operation == W.OP_REMOVE_WATER_FILTER then
        if water.filter == nil then return false, U.REASONS.DEVICE_INVALID end
        local filter = water.filter
        local item = Inventory.createItem(filter.fullType,
            math.floor(filter.condition))
        water.filter = nil
        transaction:returnItem(context.player:getInventory(), item)
    else
        return false, U.REASONS.INVALID_REQUEST
    end

    return true, { record = record, transaction = transaction }
end

local function remainingFilterL(water)
    return water.filter
        and W.FILTER_CAPACITY_L * water.filter.condition
            / W.FILTER_CONDITION_MAX
        or 0
end

function M.validateContainerSource(player, itemId, record)
    local water = record.water
    if water.tankCount <= 0 or not water.supplyPumpInstalled then
        return false, U.REASONS.DEVICE_INVALID
    end
    if water.centralL >= water.tankCount * W.LITERS_PER_TANK then
        return false, U.REASONS.CAPACITY_FULL
    end
    local found = Inventory.findItem(player, itemId)
    if not found then return false, U.REASONS.SOURCE_NOT_INVENTORY end
    local fluidContainer = found.item:getFluidContainer()
    if fluidContainer == nil or fluidContainer:getAmount() <= 0 then
        return false, U.REASONS.SOURCE_INVALID
    end
    local kind = Sources.exactWaterKind(fluidContainer)
    if not kind or (kind == "tainted" and remainingFilterL(water) <= 0) then
        return false, U.REASONS.SOURCE_INVALID
    end
    return true, { item = found.item, kind = kind }
end

function M.validateDrawSource(player, sourceHint, water)
    if water.tankCount <= 0 or not water.supplyPumpInstalled then
        return false, U.REASONS.DEVICE_INVALID
    end
    if water.extractionPump == nil then
        return false, U.REASONS.DEVICE_INVALID
    end
    if water.centralL >= water.tankCount * W.LITERS_PER_TANK then
        return false, U.REASONS.CAPACITY_FULL
    end
    local inventory = player:getInventory()
    if not inventory:contains("Base.RubberHose") then
        return false, U.REASONS.MISSING_TOOL
    end
    local resolved, sourceOrReason = Sources.resolveNaturalSource(player,
        sourceHint)
    if not resolved then return false, sourceOrReason end
    if sourceOrReason.kind == "tainted" and remainingFilterL(water) <= 0 then
        return false, U.REASONS.SOURCE_INVALID
    end
    return true, sourceOrReason
end

return M
