-- Central water ledger. Native fixtures consume the generated template
-- proxies; this module samples those proxies and projects the settled stock.

local C = require("RailroaderRV/Common/RV_Constants")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local W = require("RailroaderRV/Water/RV_UtilityWaterConstants")
local Store = require("RailroaderRV/Core/RV_UtilityStore")
local Inventory = require("RailroaderRV/Core/RV_ServerInventoryTransaction")
local Sources = require("RailroaderRV/Water/RV_UtilityWater_Sources")
local World = require("RailroaderRV/Common/RV_ServerWorld")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")

local M = {}

local function filterLiters(water)
    if water.filter == nil then return 0 end
    return W.FILTER_CAPACITY_L * water.filter.condition
        / W.FILTER_CONDITION_MAX
end

local function findProxy(square, identity, role)
    local matches = {}
    local objects = World.squareSnapshot(square)
    for index = 1, #objects do
        local object = objects[index]
        local data = object:getModData()
        local tag = data.RailroaderRV
        if type(tag) == "table" and tag.owner == C.MOD_ID
            and tag.role == role
            and tostring(tag.rvId) == tostring(identity.rvId)
            and tag.generation == identity.generation then
            matches[#matches + 1] = object
        end
    end
    if #matches ~= 1 then
        error("RailroaderRV: loaded template water proxy is missing or duplicated")
    end
    return matches[1]
end

local function accessibleProxies(identity, mappingRecord, player)
    local template = RoomTemplate.get(mappingRecord.templateId)
    local definitions = RoomTemplate.waterProxies(template)
    local position = mappingRecord.rvPosition
    local cell = World.getCellForPlayer(player)
    local result = {}
    for index = 1, #definitions do
        local definition = definitions[index]
        local x = math.floor(position.x) + definition.x
        local y = math.floor(position.y) + definition.y
        local z = position.z + definition.z
        local square = World.getSquare(cell, x, y, z)
        if square then
            result[#result + 1] = {
                key = definition.key,
                object = findProxy(square, identity,
                    RoomTemplate.PROXY_ROLES.water),
            }
        end
    end
    return result
end

local function collectorCapacity(water)
    local result = 0
    for _, collector in pairs(water.roofCollectors) do
        result = result + collector.capacityL
    end
    return result
end

local function collectorRainCatcher(water)
    local result = 0
    for _, collector in pairs(water.roofCollectors) do
        result = result + collector.rainCatcher
    end
    return result
end

local function extractionRate(water)
    if water.extractionPump == "small" then
        return W.SMALL_PUMP_FLOW_L_PER_MINUTE
    end
    if water.extractionPump == "industrial" then
        return W.INDUSTRIAL_PUMP_FLOW_L_PER_MINUTE
    end
    if water.extractionPump == nil then return 0 end
    error("RailroaderRV: unknown installed water extraction pump")
end

local function addContainerDelta(water, intent, supplyOpen, capacityL,
    manual)
    if intent.kind ~= "container" or not supplyOpen then return end
    local found = Inventory.findItem(intent.player, intent.itemId)
    if not found then return end
    local item = found.item
    local fluidContainer = item:getFluidContainer()
    local kind = Sources.exactWaterKind(fluidContainer)
    if not kind then return end

    local requestL = math.min(
        intent.serverElapsedMs / 60000 * W.CONTAINER_FLOW_L_PER_MINUTE,
        fluidContainer:getAmount(),
        math.max(0, capacityL - water.centralL))
    if kind == "tainted" then
        requestL = math.min(requestL, filterLiters(water))
    end
    if requestL <= 0 then return end

    local oldAmountL = fluidContainer:getAmount()
    fluidContainer:removeFluid(requestL)
    local removedL = oldAmountL - fluidContainer:getAmount()
    item:syncItemFields()
    sendItemStats(item)
    manual[kind] = removedL
end

local function addNaturalDelta(water, intent, supplyOpen, capacityL,
    pumpRateLPerMinute, powerState, manual)
    if intent.kind ~= "draw" or not supplyOpen then return end
    local extractionPumpRunning = powerState.extractionPumpRunning
    assert(type(extractionPumpRunning) == "boolean",
        "RailroaderRV: Power did not return extraction pump state")
    if not extractionPumpRunning then return end

    local resolved, sourceOrReason = Sources.resolveNaturalSource(
        intent.player, intent.sourceHint)
    if not resolved then return end
    local source = sourceOrReason.object
    local kind = sourceOrReason.kind
    local requestL = math.min(
        intent.serverElapsedMs / 60000 * pumpRateLPerMinute,
        source:getFluidAmount(),
        math.max(0, capacityL - water.centralL))
    if kind == "tainted" then
        requestL = math.min(requestL, filterLiters(water))
    end
    if requestL <= 0 then return end

    local temporaryContainer = source:moveFluidToTemporaryContainer(requestL)
    local actualL = temporaryContainer:getAmount()
    if actualL > 0 then
        local actualKind = Sources.exactWaterKind(temporaryContainer)
        if not actualKind then
            FluidContainer.DisposeContainer(temporaryContainer)
            error("RailroaderRV: natural source returned unsupported water fluid")
        end
        manual[actualKind] = actualL
    end
    FluidContainer.DisposeContainer(temporaryContainer)
end

local function updateFilter(water, acceptedL)
    if acceptedL <= 0 then return end
    local beforeL = filterLiters(water)
    water.filter.condition = (beforeL - acceptedL)
        * W.FILTER_CONDITION_MAX / W.FILTER_CAPACITY_L
end

local function settleManualAndAuto(water, capacityL, supplyOpen, manual)
    local cleanAcceptedL = math.min(manual.clean,
        math.max(0, capacityL - water.centralL))
    water.centralL = water.centralL + cleanAcceptedL

    local taintedAcceptedL = math.min(manual.tainted,
        math.max(0, capacityL - water.centralL), filterLiters(water))
    water.centralL = water.centralL + taintedAcceptedL
    updateFilter(water, taintedAcceptedL)

    if supplyOpen and water.filter then
        local autoAcceptedL = math.min(water.autoTankL,
            math.max(0, capacityL - water.centralL), filterLiters(water))
        water.centralL = water.centralL + autoAcceptedL
        water.autoTankL = water.autoTankL - autoAcceptedL
        updateFilter(water, autoAcceptedL)
    end
end

local function collectAuto(water, intent, autoCapacityL)
    water.autoTankL = math.min(water.autoTankL, autoCapacityL)
    if intent and intent.kind == "collectAuto" then
        local snowFactor
        if intent.isSnow == true then
            snowFactor = 0.5
        elseif intent.isSnow == false then
            snowFactor = 1
        else
            error("RailroaderRV: auto collection intent has no snow state")
        end
        local rateLPerSecond = 0.005 * intent.precipitationIntensity
            * snowFactor * collectorRainCatcher(water)
        water.autoTankL = math.min(autoCapacityL,
            water.autoTankL + rateLPerSecond * 600)
    end
end

local function projectProxies(water, proxies, capacityL, supplyOpen)
    local amountL = supplyOpen and water.centralL or 0
    for index = 1, #proxies do
        local proxy = proxies[index]
        proxy.object:getFluidContainer():setCapacity(math.max(0.05, capacityL))
        proxy.object:emptyFluid()
        if amountL > 0 then
            proxy.object:addFluid(FluidType.Water, amountL)
        end
        proxy.object:sync()
        water.lastWater[proxy.key] = amountL
    end
end

function M.initializeRecord(record, proxyDefinitions)
    local water = record.water
    water.lastWater = {}
    for index = 1, #proxyDefinitions do
        water.lastWater[proxyDefinitions[index].key] = 0
    end
    return record
end

function M.settleWater(identity, mappingRecord, waterIntent, powerState)
    local record = Store.getRecord(identity, false)
    local water = record.water
    local capacityL = water.tankCount * W.LITERS_PER_TANK
    local pumpRateLPerMinute = extractionRate(water)
    local autoCapacityL = collectorCapacity(water)
    local supplyPumpPowered = powerState.supplyPumpPowered
    assert(type(supplyPumpPowered) == "boolean",
        "RailroaderRV: Power did not return supply pump state")
    local supplyOpen = water.tankCount > 0
        and water.supplyPumpInstalled and supplyPumpPowered
    local player = waterIntent and waterIntent.player or nil
    local proxies = accessibleProxies(identity, mappingRecord, player)
    local usageL = 0

    for index = 1, #proxies do
        local proxy = proxies[index]
        usageL = usageL + water.lastWater[proxy.key]
            - proxy.object:getFluidAmount()
    end
    water.centralL = water.centralL - usageL

    collectAuto(water, waterIntent, autoCapacityL)

    local manual = { clean = 0, tainted = 0 }
    if waterIntent then
        if waterIntent.kind ~= "container" and waterIntent.kind ~= "draw"
            and waterIntent.kind ~= "collectAuto" then
            error("RailroaderRV: unknown internal water intent")
        end
        addContainerDelta(water, waterIntent, supplyOpen, capacityL, manual)
        addNaturalDelta(water, waterIntent, supplyOpen, capacityL,
            pumpRateLPerMinute, powerState, manual)
    end
    settleManualAndAuto(water, capacityL, supplyOpen, manual)
    water.centralL = math.min(capacityL, math.max(0, water.centralL))
    projectProxies(water, proxies, capacityL, supplyOpen)
    Store.commit(record, identity)
    return record
end

return M
