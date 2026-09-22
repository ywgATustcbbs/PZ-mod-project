-- Native-generator adapter for the RV utility layer.
--
-- Fuel and condition remain owned by IsoGenerator.  This record stores only
-- binding identity, circuit policy and sequence; it never mirrors a second
-- consumable fuel balance.

local C = require("RailroaderRV/RV_Constants")
local U = require("RailroaderRV/RV_UtilityConstants")
local Store = require("RailroaderRV/RV_UtilityStore")
local Water = require("RailroaderRV/RV_UtilityWater")
local World = require("RailroaderRV/RV_ServerWorld")
local Util = require("RailroaderRV/RV_ServerUtil")

local M = {}

local function invoke(target, method, ...)
    return Util.invoke(target, method, ...)
end

local function finite(value)
    value = Util.toNumber(value)
    return value ~= nil and value == value and value ~= math.huge and value ~= -math.huge
end

local function objectIndex(object)
    local ok, value = invoke(object, "getObjectIndex")
    return ok and Util.integer(value) or nil
end

local function objectToken(identity, object)
    local squareOk, square = invoke(object, "getSquare")
    if not squareOk or not square then return nil end
    local xOk, x = invoke(square, "getX")
    local yOk, y = invoke(square, "getY")
    local zOk, z = invoke(square, "getZ")
    x, y, z = Util.integer(x), Util.integer(y), Util.integer(z)
    local index = objectIndex(object)
    if not xOk or not yOk or not zOk or not x or not y or not z or not index then return nil end
    return tostring(identity.rvId) .. ":" .. tostring(identity.generation) .. ":"
        .. tostring(identity.bitmapVersion) .. ":" .. tostring(x) .. ":" .. tostring(y)
        .. ":" .. tostring(z) .. ":" .. tostring(index)
end

local function objectFingerprint(object)
    local sprite = ""
    local spriteOk, spriteObject = invoke(object, "getSprite")
    if spriteOk and spriteObject then
        local nameOk, name = invoke(spriteObject, "getName")
        if nameOk and name then sprite = tostring(name) end
    end
    return "generator:" .. sprite
end

local function insideRecord(object, context)
    local ok, square = invoke(object, "getSquare")
    if not ok or not square or not context or not context.record
        or type(context.record.region) ~= "table" then return false end
    local xOk, x = invoke(square, "getX")
    local yOk, y = invoke(square, "getY")
    local zOk, z = invoke(square, "getZ")
    x, y, z = Util.toNumber(x), Util.toNumber(y), Util.toNumber(z)
    local region = context.record.region
    local minX, maxX = Util.toNumber(region.minX), Util.toNumber(region.maxX)
    local minY, maxY = Util.toNumber(region.minY), Util.toNumber(region.maxY)
    local minZ, maxZ = Util.toNumber(region.minZ), Util.toNumber(region.maxZ)
    if not xOk or not yOk or not zOk or not finite(x) or not finite(y) or not finite(z)
        or not finite(minX) or not finite(maxX) or not finite(minY)
        or not finite(maxY) or not finite(minZ) or not finite(maxZ) then
        return false
    end
    z = math.floor(z)
    return x >= minX and x < maxX and y >= minY and y < maxY
        and z >= minZ and z < maxZ
end

local function isGeneratedGenerator(object, identity)
    local data = World.objectModData(object)
    local tag = type(data) == "table" and data.RailroaderRVTest or nil
    return type(tag) == "table" and tag.role == "generator"
        and tostring(tag.rvId) == tostring(identity.rvId)
        and Util.integer(tag.generation) == Util.integer(identity.generation)
        and Util.integer(tag.bitmapVersion) == Util.integer(identity.bitmapVersion)
end

local function readNativeState(object)
    local fuelOk, fuel = invoke(object, "getFuel")
    local capacityOk, capacity = invoke(object, "getMaxFuel")
    local conditionOk, condition = invoke(object, "getCondition")
    local activeOk, active = invoke(object, "isActivated")
    fuel, capacity, condition = Util.toNumber(fuel), Util.toNumber(capacity),
        Util.toNumber(condition)
    if not fuelOk or not capacityOk or not conditionOk or not activeOk
        or not finite(fuel) or not finite(capacity) or not finite(condition)
        or fuel < 0 or capacity <= 0 or fuel > capacity + U.PROFILE_EPSILON
        or condition < 0 or condition > 100 or type(active) ~= "boolean" then
        return false, U.REASONS.GENERATOR_INVALID
    end
    return true, { fuel = fuel, fuelCapacity = capacity, condition = condition,
        active = active == true }
end

local function bindingFor(identity, object)
    local token = objectToken(identity, object)
    if not token then return nil end
    return { rvId = tostring(identity.rvId), generation = identity.generation,
        bitmapVersion = identity.bitmapVersion,
        x = Util.integer(select(2, invoke(object, "getX"))),
        y = Util.integer(select(2, invoke(object, "getY"))),
        z = Util.integer(select(2, invoke(object, "getZ"))),
        objectToken = token, objectFingerprint = objectFingerprint(object) }
end

function M.bindGenerator(identity, context, hint)
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local objectOk, objectOrReason = Water.resolveObjectForPower(context.player, hint,
        true)
    if not objectOk then return false, objectOrReason end
    local object = objectOrReason
    if not insideRecord(object, context) or not isGeneratedGenerator(object, identity) then
        return false, U.REASONS.GENERATOR_INVALID
    end
    local stateOk, stateOrReason = readNativeState(object)
    if not stateOk then return false, stateOrReason end
    local binding = bindingFor(identity, object)
    if not binding then return false, U.REASONS.GENERATOR_INVALID end
    local old = recordOrReason.power.generator
    if old and (old.objectToken ~= binding.objectToken
        or old.objectFingerprint ~= binding.objectFingerprint) then
        return false, U.REASONS.GENERATOR_CONFLICT
    end
    recordOrReason.power.generator = binding
    recordOrReason.power.sequence = recordOrReason.power.sequence + 1
    recordOrReason.power.circuitState = stateOrReason.active and U.CIRCUIT_ON or U.CIRCUIT_OFF
    local committed, reason = Store.commit(recordOrReason, identity)
    if not committed then return false, reason end
    return true, { record = recordOrReason, state = stateOrReason }
end

local function boundGenerator(identity, context, record)
    local binding = record.power.generator
    if not binding then return false, U.REASONS.POWER_NOT_AVAILABLE end
    local hint = { x = binding.x, y = binding.y, z = binding.z,
        objectIndex = tonumber(string.match(binding.objectToken, ":(%-?%d+)$")) }
    if not hint.objectIndex then return false, U.REASONS.GENERATOR_INVALID end
    local objectOk, objectOrReason = Water.resolveObjectForPower(context.player, hint,
        true)
    if not objectOk then return false, objectOrReason end
    local object = objectOrReason
    local token = objectToken(identity, object)
    if token ~= binding.objectToken or objectFingerprint(object) ~= binding.objectFingerprint
        or not isGeneratedGenerator(object, identity) then
        return false, U.REASONS.GENERATOR_CONFLICT
    end
    return true, object
end

function M.handleIntent(identity, context, operation, hint)
    if type(context) ~= "table" or context.authorized ~= true
        or context.phase ~= "READY" or type(context.record) ~= "table" then
        return false, U.REASONS.PERMISSION
    end
    if operation == U.OP_CONNECT_GENERATOR then return M.bindGenerator(identity, context, hint) end
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local objectOk, objectOrReason = boundGenerator(identity, context, recordOrReason)
    if not objectOk then return false, objectOrReason end
    local object = objectOrReason
    local initialOk, initialState = readNativeState(object)
    if not initialOk then return false, initialState end
    local expectedActive
    local expectedCondition
    if operation == U.OP_START_GENERATOR then
        if initialState.fuel <= U.PROFILE_EPSILON or initialState.condition <= 0 then
            return false, U.REASONS.POWER_NOT_AVAILABLE
        end
        if not Util.callSucceeded(object, "setActivated", true) then
            return false, U.REASONS.API_ERROR
        end
        expectedActive = true
    elseif operation == U.OP_STOP_GENERATOR then
        if not Util.callSucceeded(object, "setActivated", false) then
            return false, U.REASONS.API_ERROR
        end
        expectedActive = false
    elseif operation == U.OP_REPAIR_GENERATOR then
        if initialState.condition >= 100 then
            return false, U.REASONS.POWER_NOT_AVAILABLE
        end
        if not Util.callSucceeded(object, "setCondition", 100) then
            return false, U.REASONS.API_ERROR
        end
        expectedCondition = 100
    else
        return false, U.REASONS.INVALID_REQUEST
    end
    local stateOk, stateOrReason = readNativeState(object)
    if not stateOk then return false, stateOrReason end
    if expectedActive ~= nil and stateOrReason.active ~= expectedActive then
        return false, U.REASONS.API_ERROR
    end
    if expectedCondition ~= nil and stateOrReason.condition ~= expectedCondition then
        return false, U.REASONS.API_ERROR
    end
    recordOrReason.power.circuitState = stateOrReason.active and U.CIRCUIT_ON or U.CIRCUIT_OFF
    recordOrReason.power.sequence = recordOrReason.power.sequence + 1
    local committed, reason = Store.commit(recordOrReason, identity)
    if not committed then return false, reason end
    return true, { record = recordOrReason, state = stateOrReason }
end

local function inventoryItems(inventory, result, seen)
    if not inventory or seen[inventory] then return end
    seen[inventory] = true
    local items = World.collectionSnapshot(select(2, invoke(inventory, "getItems")))
    for i = 1, #items do
        result[#result + 1] = items[i]
        local nestedOk, nested = invoke(items[i], "getInventory")
        if nestedOk and nested then inventoryItems(nested, result, seen) end
    end
end

local function resolveFuelSource(player, hint)
    if type(hint) ~= "table" then return false, U.REASONS.SOURCE_INVALID end
    local inventoryOk, inventory = invoke(player, "getInventory")
    if not inventoryOk or not inventory then return false, U.REASONS.SOURCE_NOT_INVENTORY end
    local fluid = rawget(_G, "Fluid")
    local petrol = fluid and fluid.Petrol
    if petrol == nil then return false, U.REASONS.SOURCE_INVALID end
    local wanted = hint.itemId or hint.id
    local items = {}
    inventoryItems(inventory, items, {})
    for i = 1, #items do
        local idOk, itemId = invoke(items[i], "getID")
        if wanted ~= nil and idOk and tostring(itemId) == tostring(wanted) then
            local containerOk, container = invoke(items[i], "getFluidContainer")
            if containerOk and container then
                local containsOk, contains = invoke(container, "contains", petrol)
                local amountOk, amount = invoke(container, "getAmount")
                amount = amountOk and Util.toNumber(amount) or nil
                if containsOk and contains == true and finite(amount)
                    and amount > U.PROFILE_EPSILON then
                    return true, items[i], container, amount
                end
            end
        end
    end
    return false, U.REASONS.SOURCE_NOT_INVENTORY
end

local function restoreFuel(container, amount)
    local fluid = rawget(_G, "Fluid")
    local petrol = fluid and fluid.Petrol
    if not container or petrol == nil or not finite(amount) or amount <= U.PROFILE_EPSILON then
        return false
    end
    local addOk, addResult = invoke(container, "addFluid", petrol, amount)
    return addOk and addResult ~= false
end

function M.addFuel(identity, context, hint)
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local objectOk, objectOrReason = boundGenerator(identity, context, recordOrReason)
    if not objectOk then return false, objectOrReason end
    local generator = objectOrReason
    local stateOk, initial = readNativeState(generator)
    if not stateOk then return false, initial end
    local sourceOk, sourceOrReason, container, sourceAmount = resolveFuelSource(
        context and context.player, hint)
    if not sourceOk then return false, sourceOrReason end
    local remaining = math.max(0, initial.fuelCapacity - initial.fuel)
    if remaining <= U.PROFILE_EPSILON then return false, U.REASONS.CAPACITY_FULL end
    local plannedTransfer = math.min(remaining, sourceAmount)
    local before = sourceAmount
    local removeOk, removeResult = invoke(container, "removeFluid", plannedTransfer, false)
    if not removeOk or removeResult == false then
        removeOk, removeResult = invoke(container, "adjustAmount", before - plannedTransfer)
    end
    if not removeOk or removeResult == false then return false, U.REASONS.API_ERROR end
    local afterOk, after = invoke(container, "getAmount")
    after = afterOk and Util.toNumber(after) or nil
    local confirmed = finite(after) and math.max(0, math.min(plannedTransfer, before - after)) or 0
    if confirmed <= U.PROFILE_EPSILON then return false, U.REASONS.SOURCE_INVALID end
    local targetFuel = initial.fuel + confirmed
    local setOk = Util.callSucceeded(generator, "setFuel", targetFuel)
    local verifyOk, verified = false, nil
    if setOk then verifyOk, verified = readNativeState(generator) end
    if not verifyOk or math.abs(verified.fuel - targetFuel) > U.PROFILE_EPSILON then
        restoreFuel(container, confirmed)
        Util.callSucceeded(generator, "setFuel", initial.fuel)
        return false, U.REASONS.API_ERROR
    end
    if not Util.callSucceeded(generator, "sync") then
        restoreFuel(container, confirmed)
        Util.callSucceeded(generator, "setFuel", initial.fuel)
        return false, U.REASONS.API_ERROR
    end
    recordOrReason.power.circuitState = verified.active and U.CIRCUIT_ON or U.CIRCUIT_OFF
    recordOrReason.power.sequence = recordOrReason.power.sequence + 1
    local committed, reason = Store.commit(recordOrReason, identity)
    if not committed then
        restoreFuel(container, confirmed)
        Util.callSucceeded(generator, "setFuel", initial.fuel)
        Util.callSucceeded(generator, "sync")
        return false, reason
    end
    return true, { record = recordOrReason, state = verified,
        plannedTransfer = plannedTransfer, confirmedTransfer = confirmed }
end

function M.snapshot(record, identity, context)
    local result = { schemaVersion = record.power.schemaVersion,
        generator = record.power.generator, circuitState = record.power.circuitState,
        devicePolicy = record.power.devicePolicy, sequence = record.power.sequence,
        state = record.power.state }
    if record.power.generator and context and context.player then
        local ok, object = boundGenerator(identity, context, record)
        if ok then
            local stateOk, state = readNativeState(object)
            if stateOk then result.native = state end
        end
    end
    return result
end

return M
