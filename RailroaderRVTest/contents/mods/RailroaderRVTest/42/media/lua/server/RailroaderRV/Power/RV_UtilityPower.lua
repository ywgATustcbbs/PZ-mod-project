-- Server-authoritative RV energy ledger and native generator power proxy.
-- Native generator fuel/condition are reset by maintenance and never settle RV energy.
local C = require("RailroaderRV/Common/RV_Constants")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local P = require("RailroaderRV/Power/RV_UtilityPowerConfig")
local Store = require("RailroaderRV/Core/RV_UtilityStore")
local Devices = require("RailroaderRV/Power/RV_UtilityPowerDevices")
local World = require("RailroaderRV/Common/RV_ServerWorld")
local Util = require("RailroaderRV/Common/RV_ServerUtil")

local M = {}

local function invoke(target, method, ...)
    return Util.invoke(target, method, ...)
end

local function finite(value)
    value = Util.toNumber(value)
    return value ~= nil and value == value and value < math.huge and value > -math.huge
end

local function worldAgeHours()
    local time = nil
    local getter = rawget(_G, "getGameTime")
    if type(getter) == "function" then
        local ok, value = pcall(getter)
        if ok then time = value end
    end
    if not time then
        local gameTime = rawget(_G, "GameTime")
        if gameTime then
            local ok, value = pcall(function()
                if type(gameTime.getInstance) == "function" then
                    return gameTime.getInstance()
                end
                return gameTime.instance
            end)
            if ok then time = value end
        end
    end
    local ok, hours = invoke(time, "getWorldAgeHours")
    hours = ok and Util.toNumber(hours) or nil
    return finite(hours) and math.max(0, hours) or nil
end

local function callSucceeded(target, method, ...)
    return Util.callSucceeded(target, method, ...)
end

local function objectFingerprint(object)
    local spriteOk, sprite = invoke(object, "getSprite")
    local nameOk, name = false, nil
    if spriteOk and sprite then nameOk, name = invoke(sprite, "getName") end
    return "generator:" .. tostring(nameOk and name or "")
end

local function generatedGenerator(object, identity)
    local data = World.objectModData(object)
    local tag = type(data) == "table" and data.RailroaderRVTest or nil
    return type(tag) == "table" and tag.owner == C.MOD_ID
        and tag.role == "generator"
        and tostring(tag.rvId) == tostring(identity.rvId)
        and Util.integer(tag.generation) == Util.integer(identity.generation)
end

local function objectAt(identity, binding, player)
    if type(binding) ~= "table" then return nil end
    local cellOk, cell = pcall(World.getCellForPlayer, player)
    if not cellOk or not cell then return nil end
    local squareOk, square = pcall(World.getSquare, cell, binding.x, binding.y, binding.z)
    if not squareOk or not square then return nil end
    local objectsOk, objects = pcall(World.squareSnapshot, square)
    if not objectsOk or type(objects) ~= "table" then return nil end
    for i = 1, #objects do
        local object = objects[i]
        if generatedGenerator(object, identity)
            and (binding.objectFingerprint == nil
                or objectFingerprint(object) == binding.objectFingerprint) then
            return object
        end
    end
    return nil
end

local function bindingFor(identity, record, player)
    local position = type(record) == "table" and record.rvPosition or nil
    if type(position) ~= "table" then return nil end
    local px, py = Util.toNumber(position.x), Util.toNumber(position.y)
    local pz = Util.integer(position.z)
    if not finite(px) or not finite(py) or pz == nil then return nil end
    local x = math.floor(px) + C.GENERATOR_OFFSET.x
    local y = math.floor(py) + C.GENERATOR_OFFSET.y
    local z = pz + C.GENERATOR_OFFSET.z
    local tentative = { x = x, y = y, z = z }
    local object = objectAt(identity, tentative, player)
    if not object then return nil end
    local squareOk, square = invoke(object, "getSquare")
    local xOk, ox = invoke(square, "getX")
    local yOk, oy = invoke(square, "getY")
    local zOk, oz = invoke(square, "getZ")
    ox, oy, oz = Util.integer(ox), Util.integer(oy), Util.integer(oz)
    if not squareOk or not xOk or not yOk or not zOk
        or ox ~= x or oy ~= y or oz ~= z then return nil end
    return { rvId = tostring(identity.rvId), generation = identity.generation,
        x = x, y = y, z = z,
        objectToken = tostring(identity.rvId) .. ":" .. tostring(identity.generation)
            .. ":" .. x .. ":" .. y .. ":" .. z,
        objectFingerprint = objectFingerprint(object) }
end

local function readProxy(object)
    if not object then return nil end
    local fuelOk, fuel = invoke(object, "getFuel")
    local maxOk, maxFuel = invoke(object, "getMaxFuel")
    local conditionOk, condition = invoke(object, "getCondition")
    local activeOk, active = invoke(object, "isActivated")
    fuel, maxFuel, condition = Util.toNumber(fuel), Util.toNumber(maxFuel),
        Util.toNumber(condition)
    if not fuelOk or not maxOk or not conditionOk or not activeOk
        or not finite(fuel) or not finite(maxFuel) or not finite(condition)
        or type(active) ~= "boolean" then return nil end
    return { fuel = fuel, maxFuel = maxFuel, condition = condition, active = active }
end

local function boundProxy(identity, power, player)
    local object = objectAt(identity, power.generator, player)
    if not object then return nil end
    local state = readProxy(object)
    return state and object or nil, state
end

local function bindProxy(identity, power, context)
    if power.generator then return true end
    local binding = bindingFor(identity, context and context.record,
        context and context.player)
    if not binding then return false, U.REASONS.GENERATOR_INVALID end
    power.generator = binding
    return true
end

local function inventoryItems(inventory, result, seen)
    if not inventory or seen[inventory] then return end
    seen[inventory] = true
    local itemsOk, collection = invoke(inventory, "getItems")
    local items = itemsOk and World.collectionSnapshot(collection) or {}
    for i = 1, #items do
        result[#result + 1] = { item = items[i], inventory = inventory }
        local nestedOk, nested = invoke(items[i], "getInventory")
        if nestedOk and nested then inventoryItems(nested, result, seen) end
    end
end

local function findInventoryItem(player, itemId)
    if itemId == nil then return nil end
    local ok, inventory = invoke(player, "getInventory")
    if not ok or not inventory then return nil end
    local all = {}
    inventoryItems(inventory, all, {})
    for i = 1, #all do
        local idOk, id = invoke(all[i].item, "getID")
        if idOk and tostring(id) == tostring(itemId) then return all[i] end
    end
    return nil
end

local function itemType(item)
    local ok, fullType = invoke(item, "getFullType")
    return ok and tostring(fullType or "") or ""
end

local function itemCondition(item)
    local conditionOk, condition = invoke(item, "getCondition")
    local maxOk, maxCondition = invoke(item, "getConditionMax")
    local usedOk, usedDelta = invoke(item, "getCurrentUsesFloat")
    condition, maxCondition = Util.integer(condition), Util.integer(maxCondition)
    usedDelta = usedOk and Util.toNumber(usedDelta) or 0
    if not conditionOk or not maxOk or maxCondition == nil or maxCondition <= 0
        or condition == nil or condition < 0 or condition > maxCondition
        or not finite(usedDelta) then return nil end
    return condition, maxCondition, math.max(0, math.min(1, usedDelta))
end

local function removeInventoryItem(found)
    if not found or not found.inventory or not found.item then return false end
    return callSucceeded(found.inventory, "Remove", found.item)
end

local function addInventoryItem(inventory, item)
    if not inventory or not item then return false end
    local ok, added = invoke(inventory, "AddItem", item)
    return ok and added ~= nil and added ~= false
end

local function createItem(fullType, condition, usedDelta)
    local factory = rawget(_G, "InventoryItemFactory")
    if not factory or type(factory.CreateItem) ~= "function" then return nil end
    local ok, item = pcall(factory.CreateItem, fullType)
    if not ok or not item then return nil end
    if condition ~= nil and not callSucceeded(item, "setCondition", condition) then return nil end
    if usedDelta ~= nil and type(item.setUsedDelta) == "function"
        and not callSucceeded(item, "setUsedDelta", usedDelta) then return nil end
    return item
end

local function syncItem(item)
    if item and type(item.syncItemFields) == "function" then
        callSucceeded(item, "syncItemFields")
    end
end

local function itemHintId(hint)
    return type(hint) == "table" and (hint.itemId or hint.id) or nil
end

local function recomputeBatteryPack(power)
    local capacity, charge, discharge = 0, 0, 0
    for _, battery in ipairs(power.batteries) do
        local values = P.batteryParameters(battery.condition, battery.maxCondition)
        if values then
            capacity = capacity + values.capacityWh
            charge = charge + values.maxChargePowerW
            discharge = discharge + values.maxDischargePowerW
        end
    end
    power.batteryCapacityWh = capacity
    power.maxChargePowerW = charge
    power.maxDischargePowerW = discharge
    power.batteryWh = math.max(0, math.min(power.batteryWh, capacity))
end

local function bump(power)
    power.sequence = power.sequence + 1
end

local function commit(record, identity)
    return Store.commit(record, identity)
end

local function circuitShouldBeOn(power)
    if power.circuitState == U.CIRCUIT_ON then
        return power.batteryWh > P.NUMERIC_EPSILON
    end
    return power.batteryCapacityWh > 0
        and power.batteryWh >= power.batteryCapacityWh * P.RESTART_CHARGE_FRACTION
end

local function syncCircuitProxy(identity, power, player)
    local on = circuitShouldBeOn(power)
    power.circuitState = on and U.CIRCUIT_ON or U.CIRCUIT_OFF
    local object, state = boundProxy(identity, power, player)
    if object and state and state.active ~= on then
        if not callSucceeded(object, "setActivated", on) then
            return false, U.REASONS.API_ERROR
        end
        if type(object.sync) == "function" and not callSucceeded(object, "sync") then
            return false, U.REASONS.API_ERROR
        end
    end
    return true
end

local function settleGeneration(power, elapsedHours)
    local sources = {}
    if power.generatorEnabled then
        sources[#sources + 1] = { id = "gasoline", generationPowerW =
            power.virtualFuelL > 0 and P.GAS_GENERATOR_POWER_W or 0,
            fuelL = power.virtualFuelL, fuelWhPerL = P.FUEL_WH_PER_L }
    end
    local generatedWh, fuelUsedL, reportPowerW = 0, 0, 0
    for i = 1, #sources do
        local source = sources[i]
        if source.generationPowerW > 0 and elapsedHours > 0 then
            local remainingCapacityWh = math.max(0,
                power.batteryCapacityWh - power.batteryWh)
            local canAccept = remainingCapacityWh > 0 and power.maxChargePowerW > 0
            if canAccept then
                local maxBatteryInputWh = math.min(remainingCapacityWh,
                    power.maxChargePowerW * elapsedHours)
                local generatorWh = math.min(source.generationPowerW * elapsedHours,
                    source.fuelL * source.fuelWhPerL,
                    maxBatteryInputWh / power.chargerEfficiency)
                local batteryInputWh = math.min(generatorWh * power.chargerEfficiency,
                    maxBatteryInputWh)
                generatedWh = generatedWh + batteryInputWh
                fuelUsedL = fuelUsedL + generatorWh / source.fuelWhPerL
                reportPowerW = reportPowerW + generatorWh / elapsedHours
            else
                -- A running generator without a battery load still burns ten percent fuel.
                local idleWh = source.generationPowerW * P.IDLE_FUEL_FRACTION
                    * elapsedHours
                local idleFuel = math.min(source.fuelL, idleWh / source.fuelWhPerL)
                fuelUsedL = fuelUsedL + idleFuel
            end
        end
    end
    power.virtualFuelL = math.max(0, power.virtualFuelL - fuelUsedL)
    power.batteryWh = power.batteryWh + generatedWh
    return reportPowerW
end

-- The persisted lastUpdateTime is the single source of truth for "this record
-- already has a runtime window"; a fresh record still carries its initial zero.
local function ensureRuntime(identity, record)
    if record.power.lastUpdateTime > 0 then return true end
    local now = worldAgeHours()
    if now == nil then return false, U.REASONS.API_ERROR end
    record.power.lastUpdateTime = now
    record.power.lastSettlementTime = now
    record.power.generationPowerW = 0
    record.power.state = U.POWER_STATE_READY
    local proxyOk, proxyReason = syncCircuitProxy(identity, record.power, nil)
    if not proxyOk then return false, proxyReason end
    bump(record.power)
    return commit(record, identity)
end

function M.beginRuntime(identity, record)
    return ensureRuntime(identity, record)
end

function M.settleAndRefreshLoad(identity, player, providedRecord)
    local record = providedRecord
    if not record then
        local recordOk, recordOrReason = Store.getRecord(identity, false)
        if not recordOk then return false, recordOrReason end
        record = recordOrReason
    end
    local runtimeOk, runtimeReason = ensureRuntime(identity, record)
    if not runtimeOk then return false, runtimeReason end
    local now = worldAgeHours()
    if now == nil then return false, U.REASONS.API_ERROR end
    local power = record.power
    -- Timestamps advance together after each successful settlement. max() prevents duplicate billing.
    local previous = math.max(power.lastUpdateTime, power.lastSettlementTime)
    local elapsedHours = math.max(0, now - previous)
    -- Bill the state sampled at the previous refresh point; only after settlement
    -- read current switch states. This accepts the documented ten-minute sampling error.
    -- Resolve coordinates first so unloaded/deleted objects never accrue stale load.
    Devices.resolveCached(identity, player)
    local loadW = Devices.currentLoadW(identity)
    local batteryOutputWh = math.min(power.batteryWh,
        power.maxDischargePowerW * elapsedHours,
        loadW / power.inverterEfficiency * elapsedHours)
    power.generationPowerW = settleGeneration(power, elapsedHours)
    power.batteryWh = math.max(0, math.min(power.batteryCapacityWh,
        power.batteryWh - batteryOutputWh))
    local proxyOk, proxyReason = syncCircuitProxy(identity, power, player)
    if not proxyOk then return false, proxyReason end
    Devices.refreshStates(identity, player, power.circuitState == U.CIRCUIT_ON)
    power.lastUpdateTime = now
    power.lastSettlementTime = now
    bump(power)
    local saved, reason = commit(record, identity)
    if not saved then return false, reason end
    return true, record
end

local function resolveFuelSource(player, hint)
    local found = findInventoryItem(player, itemHintId(hint))
    if not found then return false, U.REASONS.SOURCE_NOT_INVENTORY end
    local ok, container = invoke(found.item, "getFluidContainer")
    local fluid = rawget(_G, "Fluid")
    local petrol = fluid and fluid.Petrol
    if not ok or not container or petrol == nil then
        return false, U.REASONS.SOURCE_INVALID
    end
    local containsOk, contains = invoke(container, "contains", petrol)
    local mixtureOk, mixture = invoke(container, "isMixture")
    local amountOk, amount = invoke(container, "getAmount")
    amount = amountOk and Util.toNumber(amount) or nil
    if not containsOk or contains ~= true or not mixtureOk or mixture ~= false
        or not finite(amount) or amount <= 0 then
        return false, U.REASONS.SOURCE_INVALID
    end
    return true, found, container, amount, petrol
end

function M.addFuel(identity, context, hint)
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local sourceOk, foundOrReason, container, amount, petrol = resolveFuelSource(
        context and context.player, hint)
    if not sourceOk then return false, foundOrReason end
    local power = recordOrReason.power
    local room = P.VIRTUAL_FUEL_CAPACITY_L - power.virtualFuelL
    if room <= P.NUMERIC_EPSILON then return false, U.REASONS.CAPACITY_FULL end
    local transfer = math.min(room, amount)
    local removeOk, removeResult = invoke(container, "removeFluid", transfer, false)
    local verifyOk, after = invoke(container, "getAmount")
    after = verifyOk and Util.toNumber(after) or nil
    local confirmed = finite(after) and amount - after or nil
    if not removeOk or removeResult == false or not finite(after)
        or confirmed == nil or confirmed <= P.NUMERIC_EPSILON
        or confirmed > transfer + P.NUMERIC_EPSILON then
        return false, U.REASONS.API_ERROR
    end
    power.virtualFuelL = math.min(P.VIRTUAL_FUEL_CAPACITY_L,
        power.virtualFuelL + confirmed)
    bump(power)
    local saved, reason = commit(recordOrReason, identity)
    if not saved then
        -- The canonical record did not accept the fuel: return it to the can.
        local givenBack = invoke(container, "addFluid", petrol, confirmed)
        if not givenBack then return false, U.REASONS.POSTCONDITION_FAILED end
        return false, reason
    end
    return true, { record = recordOrReason }
end

local function isBatteryType(fullType)
    return fullType == "Base.CarBattery" or fullType == "Base.CarBattery1"
        or fullType == "Base.CarBattery2" or fullType == "Base.CarBattery3"
end

function M.addBattery(identity, context, hint)
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local found = findInventoryItem(context and context.player, itemHintId(hint))
    if not found then return false, U.REASONS.SOURCE_NOT_INVENTORY end
    local fullType = itemType(found.item)
    local condition, maxCondition, usedDelta = itemCondition(found.item)
    if not isBatteryType(fullType) or not condition then
        return false, U.REASONS.SOURCE_INVALID
    end
    local values = P.batteryParameters(condition, maxCondition)
    if not values or values.capacityWh <= 0 then return false, U.REASONS.SOURCE_INVALID end
    local power = recordOrReason.power
    -- The identifier only labels a slot in this list; it is derived here instead
    -- of being stored, so it can never drift from the battery array.
    local battery = { id = #power.batteries + 1, fullType = fullType,
        condition = condition, maxCondition = maxCondition, usedDelta = usedDelta }
    power.batteries[#power.batteries + 1] = battery
    -- Item charge contributes proportionally; condition independently shapes pack capacity.
    power.batteryWh = power.batteryWh + values.capacityWh * usedDelta
    recomputeBatteryPack(power)
    if not removeInventoryItem(found) then
        return false, U.REASONS.API_ERROR
    end
    bump(power)
    local saved, reason = commit(recordOrReason, identity)
    if not saved then
        -- Give the battery back when the canonical record did not accept it.
        if not addInventoryItem(found.inventory, found.item) then
            return false, U.REASONS.POSTCONDITION_FAILED
        end
        return false, reason
    end
    syncCircuitProxy(identity, power, context.player)
    return true, { record = recordOrReason }
end

function M.removeBattery(identity, context, hint)
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local batteryId = type(hint) == "table" and Util.integer(hint.batteryId) or nil
    if batteryId == nil then return false, U.REASONS.INVALID_REQUEST end
    local power = recordOrReason.power
    local index, battery
    for i = 1, #power.batteries do
        if power.batteries[i].id == batteryId then index, battery = i, power.batteries[i]; break end
    end
    if not battery then return false, U.REASONS.SOURCE_INVALID end
    local values = P.batteryParameters(battery.condition, battery.maxCondition)
    if not values then return false, U.REASONS.SOURCE_INVALID end
    local stateOfCharge = power.batteryCapacityWh > 0
        and power.batteryWh / power.batteryCapacityWh or 0
    local item = createItem(battery.fullType, battery.condition, stateOfCharge)
    if not item then return false, U.REASONS.API_ERROR end
    local inventoryOk, inventory = invoke(context and context.player, "getInventory")
    if not inventoryOk or not addInventoryItem(inventory, item) then
        return false, U.REASONS.API_ERROR
    end
    table.remove(power.batteries, index)
    power.batteryWh = math.max(0, power.batteryWh - values.capacityWh * stateOfCharge)
    recomputeBatteryPack(power)
    bump(power)
    local saved, reason = commit(recordOrReason, identity)
    if not saved then
        -- Take the created item back when the canonical record did not accept it.
        if not removeInventoryItem({ inventory = inventory, item = item }) then
            return false, U.REASONS.POSTCONDITION_FAILED
        end
        return false, reason
    end
    syncCircuitProxy(identity, power, context.player)
    syncItem(item)
    return true, { record = recordOrReason }
end

local function componentRow(item, expectedType)
    if itemType(item) ~= expectedType then return nil end
    local condition, maxCondition = itemCondition(item)
    if condition == nil or maxCondition ~= P.COMPONENT_CONDITION_MAX or condition <= 0 then
        return nil
    end
    return { fullType = expectedType, condition = condition,
        conditionMax = maxCondition }
end

local function installComponent(identity, context, hint, field, fullType)
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local power = recordOrReason.power
    if power[field] then return false, U.REASONS.CAPACITY_FULL end
    local found = findInventoryItem(context and context.player, itemHintId(hint))
    local component = found and componentRow(found.item, fullType) or nil
    if not found or not component then return false, U.REASONS.SOURCE_INVALID end
    if not removeInventoryItem(found) then
        return false, U.REASONS.API_ERROR
    end
    power[field] = component
    power[field .. "Efficiency"] = component.condition / component.conditionMax
    bump(power)
    local saved, reason = commit(recordOrReason, identity)
    if not saved then
        -- Give the component back when the canonical record did not accept it.
        if not addInventoryItem(found.inventory, found.item) then
            return false, U.REASONS.POSTCONDITION_FAILED
        end
        return false, reason
    end
    return true, { record = recordOrReason }
end

local function removeComponent(identity, context, field)
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local power = recordOrReason.power
    local component = power[field]
    if not component then return false, U.REASONS.SOURCE_INVALID end
    local item = createItem(component.fullType, component.condition)
    if not item then return false, U.REASONS.API_ERROR end
    local inventoryOk, inventory = invoke(context and context.player, "getInventory")
    if not inventoryOk or not addInventoryItem(inventory, item) then
        return false, U.REASONS.API_ERROR
    end
    power[field] = nil
    power[field .. "Efficiency"] = field == "charger"
        and P.DEFAULT_CHARGER_EFFICIENCY or P.DEFAULT_INVERTER_EFFICIENCY
    bump(power)
    local saved, reason = commit(recordOrReason, identity)
    if not saved then
        -- Take the created component back when the record did not accept it.
        if not removeInventoryItem({ inventory = inventory, item = item }) then
            return false, U.REASONS.POSTCONDITION_FAILED
        end
        return false, reason
    end
    syncItem(item)
    return true, { record = recordOrReason }
end

local function setGeneratorEnabled(identity, context, enabled)
    local ok, recordOrReason = M.settleAndRefreshLoad(identity,
        context and context.player)
    if not ok then return false, recordOrReason end
    local record = recordOrReason
    local power = record.power
    if power.generatorEnabled == enabled then return true, { record = record } end
    power.generatorEnabled = enabled
    if not enabled then power.generationPowerW = 0 end
    bump(power)
    local saved, reason = commit(record, identity)
    if not saved then return false, reason end
    return true, { record = record }
end

function M.handleIntent(identity, context, operation, hint)
    if type(context) ~= "table" or context.authorized ~= true
        or context.phase ~= "READY" then return false, U.REASONS.PERMISSION end
    if operation == U.OP_ADD_BATTERY then return M.addBattery(identity, context, hint) end
    if operation == U.OP_REMOVE_BATTERY then return M.removeBattery(identity, context, hint) end
    if operation == U.OP_INSTALL_CHARGER then
        return installComponent(identity, context, hint, "charger",
            "RailroaderRVTest.RVCharger")
    end
    if operation == U.OP_REMOVE_CHARGER then
        return removeComponent(identity, context, "charger")
    end
    if operation == U.OP_INSTALL_INVERTER then
        return installComponent(identity, context, hint, "inverter",
            "RailroaderRVTest.RVInverter")
    end
    if operation == U.OP_REMOVE_INVERTER then
        return removeComponent(identity, context, "inverter")
    end
    if operation == U.OP_START_GENERATOR then
        return setGeneratorEnabled(identity, context, true)
    end
    if operation == U.OP_STOP_GENERATOR then
        return setGeneratorEnabled(identity, context, false)
    end
    return false, U.REASONS.INVALID_REQUEST
end

function M.maintainNativeProxy(identity, record)
    local object, state = boundProxy(identity, record.power, nil)
    if not object or not state then return false end
    local changed = false
    if math.abs(state.fuel - state.maxFuel) > P.NUMERIC_EPSILON then
        if not callSucceeded(object, "setFuel", state.maxFuel) then return false end
        changed = true
    end
    if state.condition < P.NATIVE_GENERATOR_CONDITION_MAX then
        if not callSucceeded(object, "setCondition",
            P.NATIVE_GENERATOR_CONDITION_MAX) then return false end
        changed = true
    end
    local desired = record.power.circuitState == U.CIRCUIT_ON
    if state.active ~= desired then
        if not callSucceeded(object, "setActivated", desired) then return false end
        changed = true
    end
    if changed then
        if type(object.sync) ~= "function" or not callSucceeded(object, "sync") then
            return false
        end
    end
    local verifiedObject, verified = boundProxy(identity, record.power, nil)
    return verifiedObject ~= nil and verified ~= nil
        and math.abs(verified.fuel - verified.maxFuel) <= P.NUMERIC_EPSILON
        and math.abs(verified.condition - P.NATIVE_GENERATOR_CONDITION_MAX)
            <= P.NUMERIC_EPSILON
        and verified.active == desired
end

function M.initializeRecord(identity, context)
    local recordOk, recordOrReason = Store.getRecord(identity, true)
    if not recordOk then return false, recordOrReason end
    local record = recordOrReason
    local now = worldAgeHours()
    if now == nil then return false, U.REASONS.API_ERROR end
    record.power.lastUpdateTime = now
    record.power.lastSettlementTime = now
    local bound, bindReason = bindProxy(identity, record.power, context)
    if not bound then return false, bindReason end
    record.power.circuitState = U.CIRCUIT_OFF
    record.power.generatorEnabled = false
    record.power.generationPowerW = 0
    bump(record.power)
    local maintained, maintenanceReason = M.maintainNativeProxy(identity, record)
    if not maintained then
        return false, maintenanceReason or U.REASONS.API_ERROR
    end
    local saved, reason = commit(record, identity)
    if not saved then return false, reason end
    return true, record
end

function M.snapshot(record, identity, context)
    local result = Store.snapshot(record).power
    -- The load is a live reading of the resolved device cache, not ledger state;
    -- compute it here so the client never reads a stale persisted copy.
    result.currentLoadW = Devices.currentLoadW(identity)
    result.deviceCount = Devices.count(identity)
    result.proxyActive = false
    local object, native = boundProxy(identity, record.power,
        context and context.player)
    if object and native then result.proxyActive = native.active end
    return result
end

return M
