-- Server-authoritative RV energy ledger and native generator power proxy.
-- Native generator fuel/condition are reset by maintenance and never settle RV energy.
local C = require("RailroaderRV/Common/RV_Constants")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local P = require("RailroaderRV/Power/RV_UtilityPowerConfig")
local WaterConstants = require("RailroaderRV/Water/RV_UtilityWaterConstants")
local Generation = require("RailroaderRV/Power/RV_Generation")
local Store = require("RailroaderRV/Core/RV_UtilityStore")
local InventoryTransaction = require("RailroaderRV/Core/RV_ServerInventoryTransaction")
local Devices = require("RailroaderRV/Power/RV_UtilityPowerDevices")
local World = require("RailroaderRV/Common/RV_ServerWorld")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local Util = require("RailroaderRV/Common/RV_ServerUtil")

local M = {}
local actionPumpLoads = {}

local function identityKey(identity)
    return tostring(identity.rvId) .. ":" .. tostring(identity.generation)
end

local function activePumpLoadW(identity)
    local loads = actionPumpLoads[identityKey(identity)]
    local result = 0
    if loads then
        for _, load in pairs(loads) do
            if load.running then result = result + load.watts end
        end
    end
    return result
end

local function finite(value)
    value = Util.toNumber(value)
    return value ~= nil and value == value and value < math.huge and value > -math.huge
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function worldAgeHours()
    local hours = getGameTime():getWorldAgeHours()
    assert(finite(hours) and hours >= 0,
        "RV utility world age is invalid")
    return hours
end

local function powerProxySquare(mappingRecord, player)
    local position = mappingRecord.rvPosition
    local proxy = RoomTemplate.get(mappingRecord.templateId).powerProxy
    local x = math.floor(position.x) + proxy.x
    local y = math.floor(position.y) + proxy.y
    local z = position.z + proxy.z
    local cell = World.getCellForPlayer(player)
    return World.getSquare(cell, x, y, z)
end

local function findInventoryItem(player, itemId)
    return InventoryTransaction.findItem(player, itemId)
end

local itemType = InventoryTransaction.itemType
local itemCondition = InventoryTransaction.itemCondition
local createItem = InventoryTransaction.createItem
local syncItem = InventoryTransaction.syncItem

local function itemHintId(hint)
    return type(hint) == "table" and (hint.itemId or hint.id) or nil
end

local function batteryPack(power)
    local capacity, charge, discharge = 0, 0, 0
    for _, battery in ipairs(power.batteries) do
        local values = P.batteryParameters(battery.fullType, battery.condition, battery.maxCondition)
        capacity = capacity + values.capacityWh
        charge = charge + values.maxChargePowerW
        discharge = discharge + values.maxDischargePowerW
    end
    return capacity, charge, discharge
end

local function fuelCapacity(power)
    local capacity = 0
    for _, tank in ipairs(power.fuelTanks) do
        capacity = capacity + tank.capacityL
    end
    return capacity
end

local function setNativeGeneratorState(generator, power)
    generator:setCondition(P.NATIVE_GENERATOR_CONDITION_MAX)
    generator:setFuel(C.GENERATOR_INITIAL_FUEL)
    generator:setActivated(power.circuitState == U.CIRCUIT_ON)
    generator:sync()
end

local function updateNativeGenerator(power, mappingRecord, player)
    local square = powerProxySquare(mappingRecord, player)
    if square then
        setNativeGeneratorState(square:getGenerator(), power)
    end
end

local function recomputeBatteryPack(power)
    local capacity = batteryPack(power)
    power.batteryWh = math.max(0, math.min(power.batteryWh, capacity))
end

local function commit(record, identity)
    return Store.commit(record, identity)
end

local function chargerEfficiency(power)
    return power.charger and power.charger.condition / power.charger.conditionMax or nil
end

local function inverterEfficiency(power)
    return power.inverter and power.inverter.condition / power.inverter.conditionMax or nil
end

local function breakerAllowsOutput(power)
    return not power.circuitBreakerInstalled or power.circuitBreakerClosed
end

local function batteryOutputDemandW(power, loadW)
    local inverter = inverterEfficiency(power)
    if not inverter or inverter <= 0 then return 0 end
    return loadW / inverter
end

local function circuitShouldBeOn(power, requestedLoadW)
    local capacity, _, maxDischargePowerW = batteryPack(power)
    if not power.inverter or power.inverter.condition <= 0
        or not breakerAllowsOutput(power) or capacity <= 0
        or maxDischargePowerW <= 0 or power.batteryWh <= 0 then
        return false
    end
    local inverter = inverterEfficiency(power)
    return requestedLoadW <= maxDischargePowerW * inverter
end

local function effectiveLoadW(identity, power, water)
    local deviceLoadW = Devices.requestedLoadW(power)
    local waterLoadW = activePumpLoadW(identity)
    if water.supplyPumpInstalled then
        waterLoadW = waterLoadW + WaterConstants.SUPPLY_PUMP_WATTS
    end
    return deviceLoadW + waterLoadW
end

local function syncCircuitProxy(record, mappingRecord, player, identity)
    local power = record.power
    local requestedLoadW = effectiveLoadW(identity, power, record.water)
    local on = circuitShouldBeOn(power, requestedLoadW)
    power.circuitState = on and U.CIRCUIT_ON or U.CIRCUIT_OFF
    updateNativeGenerator(power, mappingRecord, player)
end

local function applyOverloadProtection(power, requestedLoadW)
    if not power.inverter or power.inverter.condition <= 0 then return false end
    local capacity, _, maxDischargePowerW = batteryPack(power)
    if capacity <= 0 or maxDischargePowerW <= 0 or power.batteryWh <= 0
        or not breakerAllowsOutput(power) then
        return false
    end
    local demandW = batteryOutputDemandW(power, requestedLoadW)
    if demandW <= maxDischargePowerW then return false end
    if power.circuitBreakerInstalled then
        power.circuitBreakerClosed = false
        return true
    end
    power.inverter.condition = 0
    return true
end

local function generatorRates(power, loadW)
    local efficiency = chargerEfficiency(power)
    local inverter = inverterEfficiency(power)
    local batteryCapacityWh, maxChargePowerW, maxDischargePowerW =
        batteryPack(power)
    local batteryOutputW = 0
    if inverter and inverter > 0 and batteryCapacityWh > 0
        and power.batteryWh > 0 and breakerAllowsOutput(power) then
        batteryOutputW = math.min(loadW / inverter, maxDischargePowerW)
    end
    local chargingDemandW = 0
    if efficiency and batteryCapacityWh > 0 and maxChargePowerW > 0 then
        if power.batteryWh >= batteryCapacityWh then
            chargingDemandW = batteryOutputW / efficiency
        else
            chargingDemandW = maxChargePowerW / efficiency
        end
    end
    local totalFuelCapacityL = fuelCapacity(power)
    local eligible, maxFuelPowerW = {}, 0
    local renewablePowerW, generatorPower = 0, {}
    local solarPowerW, windPowerW
    for _, generator in ipairs(power.generators) do
        local profile = P.GENERATOR_TYPES[generator.fullType]
        if profile.renewableType ~= nil
            and profile.renewableType ~= "SOLAR"
            and profile.renewableType ~= "WIND" then
            error("RailroaderRV: unknown renewable generator type "
                .. tostring(profile.renewableType))
        end
        if profile.renewableType then
            local watts = 0
            if generator.enabled and profile.renewableType == "SOLAR" then
                if solarPowerW == nil then
                    solarPowerW = Generation.currentSolarPowerW()
                end
                watts = solarPowerW
            elseif generator.enabled then
                if windPowerW == nil then
                    windPowerW = Generation.currentWindPowerW()
                end
                watts = windPowerW
            end
            generatorPower[generator.id] = watts
            renewablePowerW = renewablePowerW + watts
        elseif generator.enabled and totalFuelCapacityL > 0
            and power.virtualFuelL > 0 then
            eligible[#eligible + 1] = { generator = generator, profile = profile }
            maxFuelPowerW = maxFuelPowerW + profile.maxPowerW
        end
    end
    local renewableUsedPowerW = math.min(chargingDemandW, renewablePowerW)
    local fuelDemandW = math.max(0, chargingDemandW - renewableUsedPowerW)
    local fuelPowerW = math.min(fuelDemandW, maxFuelPowerW)
    local totalPowerW = renewableUsedPowerW + fuelPowerW
    local fuelRate = 0
    for i = 1, #eligible do
        local entry = eligible[i]
        local watts = maxFuelPowerW > 0 and fuelPowerW
            * entry.profile.maxPowerW / maxFuelPowerW or 0
        generatorPower[entry.generator.id] = watts
        fuelRate = fuelRate + entry.profile.baseFuelLPerHour
            + watts / 1000 * entry.profile.fuelLPerKWh
    end
    if efficiency and batteryCapacityWh > 0
        and (#eligible > 0 or renewablePowerW > 0) then
        local batteryChargeW = math.min(maxChargePowerW,
            totalPowerW * efficiency)
        return totalPowerW, fuelRate, batteryOutputW, batteryChargeW,
            generatorPower, renewablePowerW, renewableUsedPowerW
    end
    return 0, fuelRate, batteryOutputW, 0, generatorPower,
        renewablePowerW, 0
end

local function setGeneratorEnabled(power, enabled)
    for _, generator in ipairs(power.generators) do
        if not P.GENERATOR_TYPES[generator.fullType].renewableType then
            generator.enabled = enabled
        end
    end
end

local function applyController(power)
    local batteryCapacityWh = batteryPack(power)
    if not power.controller or batteryCapacityWh <= 0 then return false end
    local charge = power.batteryWh / batteryCapacityWh
    local enabled = nil
    if charge < 0.10 then enabled = true end
    if charge > 0.30 then enabled = false end
    if enabled == nil then return false end
    local changed = false
    for _, generator in ipairs(power.generators) do
        local canRun = fuelCapacity(power) > 0
            and power.virtualFuelL > 0
        if not P.GENERATOR_TYPES[generator.fullType].renewableType then
            local desired = enabled and canRun
            if generator.enabled ~= desired then
                generator.enabled = desired
                changed = true
            end
        end
    end
    return changed
end

local function settleEnergy(power, elapsedHours, loadW)
    local _, fuelRate, batteryOutputW, batteryInputW =
        generatorRates(power, loadW)
    power.virtualFuelL = clamp(power.virtualFuelL
        - fuelRate * elapsedHours, 0, fuelCapacity(power))
    local batteryCapacityWh = batteryPack(power)
    power.batteryWh = clamp(power.batteryWh
        + (batteryInputW - batteryOutputW) * elapsedHours,
        0, batteryCapacityWh)
    if power.virtualFuelL == 0 then setGeneratorEnabled(power, false) end
    applyController(power)
end

function M.markPumpRunning(identity, action, watts)
    local key = identityKey(identity)
    local loads = actionPumpLoads[key]
    if not loads then
        loads = {}
        actionPumpLoads[key] = loads
    end
    loads[action] = { watts = watts, running = true }
end

function M.clearPump(identity, action)
    local key = identityKey(identity)
    local loads = actionPumpLoads[key]
    loads[action] = nil
    for _ in pairs(loads) do return end
    actionPumpLoads[key] = nil
end

function M.settlePower(identity, mappingRecord, player, providedRecord, action)
    local record = providedRecord
    if not record then
        record = Store.getRecord(identity, false)
    end
    assert(record.power.lastSettlementTime ~= nil,
        "RV utility last settlement time is missing")
    local power = record.power
    local now = worldAgeHours()
    Devices.scan(identity, record, player, mappingRecord.slotIndex,
        mappingRecord.templateId)
    assert(now >= power.lastSettlementTime, "RV utility world age moved backwards")
    local elapsedHours = now - power.lastSettlementTime
    local loadW = effectiveLoadW(identity, power, record.water)
    settleEnergy(power, elapsedHours, loadW)
    applyOverloadProtection(power, loadW)
    syncCircuitProxy(record, mappingRecord, player, identity)
    power.lastSettlementTime = now
    commit(record, identity)
    local water = record.water
    local powered = power.circuitState == U.CIRCUIT_ON
    local actionLoads = actionPumpLoads[identityKey(identity)]
    if actionLoads then
        for _, load in pairs(actionLoads) do load.running = powered end
    end
    local actionLoad = action ~= nil and actionLoads and actionLoads[action]
    local extractionPumpRunning = actionLoad ~= nil
        and actionLoad.running and water.extractionPump ~= nil
    return {
        supplyPumpPowered = water.supplyPumpInstalled and powered,
        extractionPumpRunning = extractionPumpRunning == true,
    }, record
end

local function resolveFuelSource(player, hint)
    local found = findInventoryItem(player, itemHintId(hint))
    if not found then return false, U.REASONS.SOURCE_NOT_INVENTORY end
    local container = found.item:getFluidContainer()
    local petrol = Fluid.Petrol
    if not container then
        return false, U.REASONS.SOURCE_INVALID
    end
    local contains = container:contains(petrol)
    local mixture = container:isMixture()
    local amount = Util.toNumber(container:getAmount())
    if contains ~= true or mixture ~= false
        or not finite(amount) or amount <= 0 then
        return false, U.REASONS.SOURCE_INVALID
    end
    return true, found, container, amount
end

function M.fuelActionCapacity(identity, context, item)
    local recordOrReason = Store.getRecord(identity, false)
    local itemId = item:getID()
    local sourceOk, foundOrReason, _, amount = resolveFuelSource(
        context.player, { itemId = itemId })
    if not sourceOk then return false, foundOrReason end
    local power = recordOrReason.power
    local room = fuelCapacity(power) - power.virtualFuelL
    if room <= P.NUMERIC_EPSILON then return false, U.REASONS.CAPACITY_FULL end
    return true, math.min(room, amount)
end

function M.addFuel(identity, context, item, requestedAmount)
    local recordOrReason = Store.getRecord(identity, false)
    local itemId = item:getID()
    local sourceOk, foundOrReason, container, amount = resolveFuelSource(
        context.player, { itemId = itemId })
    if not sourceOk then return false, foundOrReason end
    local power = recordOrReason.power
    assert(finite(requestedAmount) and requestedAmount > 0,
        "RV refueling action amount is invalid")
    local transfer = math.min(amount, requestedAmount)
    container:removeFluid(transfer, false)
    local after = Util.toNumber(container:getAmount())
    local confirmed = amount - after
    assert(finite(after) and confirmed > 0
        and confirmed <= transfer + P.NUMERIC_EPSILON,
        "RV refueling transfer did not match its source container")
    power.virtualFuelL = math.max(0, math.min(fuelCapacity(power),
        power.virtualFuelL + confirmed))
    syncItem(foundOrReason.item)
    commit(recordOrReason, identity)
    return true, { record = recordOrReason }
end

local function gasTankCapacity(item, condition)
    local maxCapacity = Util.toNumber(item:getMaxCapacity())
    if not finite(maxCapacity) or maxCapacity <= 0 then return nil end
    return P.gasTankCapacity(maxCapacity, condition)
end

local function itemFuel(item)
    local amount = Util.toNumber(item:getItemCapacity())
    if amount == -1 then return 0 end
    return finite(amount) and amount >= 0 and amount or nil
end

function M.addFuelTank(context, hint, recordOrReason)
    local power = recordOrReason.power
    if #power.fuelTanks >= P.MAX_FUEL_TANKS then
        return false, U.REASONS.CAPACITY_FULL
    end
    local found = findInventoryItem(context.player, itemHintId(hint))
    if not found then return false, U.REASONS.SOURCE_NOT_INVENTORY end
    local fullType = itemType(found.item)
    if not P.GAS_TANK_TYPES[fullType] then return false, U.REASONS.SOURCE_INVALID end
    local condition, maxCondition = itemCondition(found.item)
    if maxCondition ~= 100 then return false, U.REASONS.SOURCE_INVALID end
    local capacity = condition and gasTankCapacity(found.item, condition) or nil
    local fuel = itemFuel(found.item)
    local name = found.item:getName()
    if capacity == nil or fuel == nil or type(name) ~= "string" then
        return false, U.REASONS.SOURCE_INVALID
    end
    local transaction = InventoryTransaction.new(context.player)
    transaction:consumeFound(found)
    power.fuelTanks[#power.fuelTanks + 1] = {
        id = power.nextFuelTankId, fullType = fullType, name = tostring(name),
        condition = condition, maxCondition = maxCondition, capacityL = capacity,
    }
    power.nextFuelTankId = power.nextFuelTankId + 1
    local totalFuelCapacityL = fuelCapacity(power)
    totalFuelCapacityL = totalFuelCapacityL + capacity
    power.virtualFuelL = math.max(0, math.min(totalFuelCapacityL,
        power.virtualFuelL + fuel))
    return true, { record = recordOrReason, transaction = transaction }
end

function M.removeFuelTank(context, hint, recordOrReason)
    local tankId = type(hint) == "table" and Util.integer(hint.fuelTankId) or nil
    local power = recordOrReason.power
    local index, tank
    for i = 1, #power.fuelTanks do
        if power.fuelTanks[i].id == tankId then
            index, tank = i, power.fuelTanks[i]
            break
        end
    end
    if not tank then return false, U.REASONS.SOURCE_INVALID end
    local newFuelCapacityL = fuelCapacity(power) - tank.capacityL
    if power.virtualFuelL > newFuelCapacityL then
        return false, U.REASONS.CAPACITY_FULL
    end
    local item = createItem(tank.fullType, tank.condition)
    item:setItemCapacity(0)
    local inventory = context.player:getInventory()
    local transaction = InventoryTransaction.new(context.player)
    transaction:returnItem(inventory, item)
    table.remove(power.fuelTanks, index)
    if newFuelCapacityL == 0 then
        setGeneratorEnabled(power, false)
    elseif power.virtualFuelL == 0 then
        setGeneratorEnabled(power, false)
    end
    return true, { record = recordOrReason, transaction = transaction }
end

local function isBatteryType(fullType)
    return P.BATTERY_TYPES[fullType] ~= nil
end

function M.addBattery(context, hint, recordOrReason)
    local found = findInventoryItem(context.player, itemHintId(hint))
    if not found then return false, U.REASONS.SOURCE_NOT_INVENTORY end
    local fullType = itemType(found.item)
    local condition, maxCondition, usedDelta = itemCondition(found.item)
    if not isBatteryType(fullType) or not condition then
        return false, U.REASONS.SOURCE_INVALID
    end
    local values = P.batteryParameters(fullType, condition, maxCondition)
    if not values or values.capacityWh <= 0 then return false, U.REASONS.SOURCE_INVALID end
    local power = recordOrReason.power
    if #power.batteries >= P.MAX_BATTERIES then
        return false, U.REASONS.CAPACITY_FULL
    end
    local battery = { id = power.nextBatteryId, fullType = fullType,
        condition = condition, maxCondition = maxCondition, usedDelta = usedDelta }
    local transaction = InventoryTransaction.new(context.player)
    transaction:consumeFound(found)
    power.batteries[#power.batteries + 1] = battery
    power.nextBatteryId = power.nextBatteryId + 1
    -- Item charge contributes proportionally; condition independently shapes pack capacity.
    power.batteryWh = power.batteryWh + values.capacityWh * usedDelta
    recomputeBatteryPack(power)
    return true, { record = recordOrReason, transaction = transaction }
end

function M.removeBattery(context, hint, recordOrReason)
    local batteryId = type(hint) == "table" and Util.integer(hint.batteryId) or nil
    if batteryId == nil then return false, U.REASONS.INVALID_REQUEST end
    local power = recordOrReason.power
    local index, battery
    for i = 1, #power.batteries do
        if power.batteries[i].id == batteryId then index, battery = i, power.batteries[i]; break end
    end
    if not battery then return false, U.REASONS.SOURCE_INVALID end
    local values = P.batteryParameters(battery.fullType, battery.condition, battery.maxCondition)
    local batteryCapacityWh = batteryPack(power)
    local stateOfCharge = power.batteryWh / batteryCapacityWh
    local item = createItem(battery.fullType, battery.condition, stateOfCharge)
    local inventory = context.player:getInventory()
    local transaction = InventoryTransaction.new(context.player)
    transaction:returnItem(inventory, item)
    table.remove(power.batteries, index)
    power.batteryWh = math.max(0, power.batteryWh - values.capacityWh * stateOfCharge)
    recomputeBatteryPack(power)
    return true, { record = recordOrReason, transaction = transaction }
end

local function componentRow(item, expectedType)
    if itemType(item) ~= expectedType then return nil end
    local condition, maxCondition = itemCondition(item)
    local expectedConditionMax = expectedType == P.CONTROLLER_TYPE
        and 100 or P.COMPONENT_CONDITION_MAX
    if condition == nil or maxCondition ~= expectedConditionMax or condition <= 0 then
        return nil
    end
    return { fullType = expectedType, condition = condition,
        conditionMax = maxCondition }
end

local function installComponent(context, hint, field, fullType, recordOrReason)
    local power = recordOrReason.power
    if power[field] then return false, U.REASONS.CAPACITY_FULL end
    local found = findInventoryItem(context.player, itemHintId(hint))
    local component = found and componentRow(found.item, fullType) or nil
    if not found or not component then return false, U.REASONS.SOURCE_INVALID end
    local transaction = InventoryTransaction.new(context.player)
    transaction:consumeFound(found)
    power[field] = component
    if field == "controller" then applyController(power) end
    return true, { record = recordOrReason, transaction = transaction }
end

local function removeComponent(context, field, recordOrReason)
    local power = recordOrReason.power
    local component = power[field]
    if not component then return false, U.REASONS.SOURCE_INVALID end
    local transaction = InventoryTransaction.new(context.player)
    if field ~= "inverter" or component.condition > 0 then
        local item = createItem(component.fullType, component.condition)
        local inventory = context.player:getInventory()
        transaction:returnItem(inventory, item)
    end
    power[field] = nil
    return true, { record = recordOrReason, transaction = transaction }
end

local function installCircuitBreaker(context, hint, record)
    local power = record.power
    if power.circuitBreakerInstalled then
        return false, U.REASONS.CAPACITY_FULL
    end
    local found = findInventoryItem(context.player, itemHintId(hint))
    if not found or itemType(found.item) ~= P.CIRCUIT_BREAKER_TYPE then
        return false, U.REASONS.SOURCE_INVALID
    end
    local transaction = InventoryTransaction.new(context.player)
    transaction:consumeFound(found)
    power.circuitBreakerInstalled = true
    power.circuitBreakerClosed = true
    return true, { record = record, transaction = transaction }
end

local function removeCircuitBreaker(context, record)
    local power = record.power
    if not power.circuitBreakerInstalled then
        return false, U.REASONS.SOURCE_INVALID
    end
    local item = createItem(P.CIRCUIT_BREAKER_TYPE)
    local transaction = InventoryTransaction.new(context.player)
    transaction:returnItem(context.player:getInventory(), item)
    power.circuitBreakerInstalled = false
    power.circuitBreakerClosed = false
    return true, { record = record, transaction = transaction }
end

local function setCircuitBreaker(record, closed)
    local power = record.power
    if not power.circuitBreakerInstalled then
        return false, U.REASONS.SOURCE_INVALID
    end
    power.circuitBreakerClosed = closed
    return true, { record = record }
end

local function setGeneratorEnabled(context, hint, enabled, recordOrReason)
    local record = recordOrReason
    local power = record.power
    local generatorId = type(hint) == "table" and Util.integer(hint.generatorId) or nil
    local generator
    for i = 1, #power.generators do
        if power.generators[i].id == generatorId then
            generator = power.generators[i]
            break
        end
    end
    if not generator then return false, U.REASONS.SOURCE_INVALID end
    local profile = P.GENERATOR_TYPES[generator.fullType]
    if enabled and not profile.renewableType
        and (fuelCapacity(power) <= 0 or power.virtualFuelL <= 0) then
        return false, U.REASONS.SOURCE_INVALID
    end
    if generator.enabled == enabled then return true, { record = record } end
    generator.enabled = enabled
    return true, { record = record }
end

function M.handleIntent(context, operation, hint, record)
    assert(type(record) == "table", "RV utility intent has no settled record")
    if operation == U.OP_ADD_FUEL_TANK then return M.addFuelTank(context, hint, record) end
    if operation == U.OP_REMOVE_FUEL_TANK then return M.removeFuelTank(context, hint, record) end
    if operation == U.OP_ADD_BATTERY then return M.addBattery(context, hint, record) end
    if operation == U.OP_REMOVE_BATTERY then return M.removeBattery(context, hint, record) end
    if operation == U.OP_INSTALL_CHARGER then
        return installComponent(context, hint, "charger", P.CHARGER_TYPE, record)
    end
    if operation == U.OP_REMOVE_CHARGER then
        return removeComponent(context, "charger", record)
    end
    if operation == U.OP_INSTALL_INVERTER then
        return installComponent(context, hint, "inverter", P.INVERTER_TYPE, record)
    end
    if operation == U.OP_REMOVE_INVERTER then
        return removeComponent(context, "inverter", record)
    end
    if operation == U.OP_INSTALL_CONTROLLER then
        return installComponent(context, hint, "controller",
            P.CONTROLLER_TYPE, record)
    end
    if operation == U.OP_REMOVE_CONTROLLER then
        return removeComponent(context, "controller", record)
    end
    if operation == U.OP_INSTALL_CIRCUIT_BREAKER then
        return installCircuitBreaker(context, hint, record)
    end
    if operation == U.OP_REMOVE_CIRCUIT_BREAKER then
        return removeCircuitBreaker(context, record)
    end
    if operation == U.OP_OPEN_CIRCUIT_BREAKER then
        return setCircuitBreaker(record, false)
    end
    if operation == U.OP_CLOSE_CIRCUIT_BREAKER then
        return setCircuitBreaker(record, true)
    end
    if operation == U.OP_START_GENERATOR then
        return setGeneratorEnabled(context, hint, true, record)
    end
    if operation == U.OP_STOP_GENERATOR then
        return setGeneratorEnabled(context, hint, false, record)
    end
    return false, U.REASONS.INVALID_REQUEST
end

function M.maintainNativeProxy(identity, record, mappingRecord, player)
    updateNativeGenerator(record.power, mappingRecord, player)
end

function M.initializeRecord(identity, context)
    local record = Store.getRecord(identity, true)
    Devices.initialize(record, identity)
    local now = worldAgeHours()
    record.power.lastSettlementTime = now
    record.power.circuitState = U.CIRCUIT_OFF
    local square = powerProxySquare(context.record, context.player)
    setNativeGeneratorState(square:getGenerator(), record.power)
    commit(record, identity)
    return true, record
end

function M.snapshot(record, identity, context)
    Devices.ensureInitialized(identity, record)
    local result = Store.snapshot(record).power
    result.nextBatteryId = nil
    result.nextGeneratorId = nil
    result.nextFuelTankId = nil
    local loadW = effectiveLoadW(identity, record.power, record.water)
    local _, requestedActiveDeviceCount = Devices.requestedLoadW(record.power)
    result.potentialLoadW = Devices.potentialLoadW(record.power)
    result.deviceCount = Devices.count(record.power)
    local generationPowerW, fuelRate, batteryOutputW, batteryInputW,
        generatorPower, renewableAvailablePowerW, renewableUsedPowerW =
        generatorRates(record.power, loadW)
    result.activeDeviceCount = batteryOutputW > 0
        and requestedActiveDeviceCount or 0
    result.generationPowerW = generationPowerW
    result.renewableAvailablePowerW = renewableAvailablePowerW
    result.renewableUsedPowerW = renewableUsedPowerW
    local inverter = inverterEfficiency(record.power)
    result.currentLoadW = inverter and batteryOutputW * inverter or 0
    result.fuelConsumptionLPerHour = fuelRate
    result.batteryDischargePowerW = batteryOutputW
    result.batteryChargePowerW = batteryInputW
    for _, generator in ipairs(result.generators) do
        local profile = P.GENERATOR_TYPES[generator.fullType]
        local watts = generatorPower[generator.id] or 0
        local running = generator.enabled and (profile.renewableType ~= nil
            or (fuelCapacity(record.power) > 0
                and record.power.virtualFuelL > P.NUMERIC_EPSILON))
        generator.running = running
        generator.maxPowerW = profile.maxPowerW
        generator.currentPowerW = running and watts or 0
        generator.fuelConsumptionLPerHour = running
            and not profile.renewableType
            and (profile.baseFuelLPerHour + watts / 1000 * profile.fuelLPerKWh)
            or 0
    end
    result.generatorCount = #record.power.generators
    result.fuelTankCount = #record.power.fuelTanks
    result.batteryCount = #record.power.batteries
    result.fuelCapacityL = fuelCapacity(record.power)
    result.batteryCapacityWh, result.maxChargePowerW,
        result.maxDischargePowerW = batteryPack(record.power)
    result.chargerEfficiency = chargerEfficiency(record.power)
    result.inverterEfficiency = inverterEfficiency(record.power)
    result.circuitState = record.power.circuitState
    return result
end

return M
