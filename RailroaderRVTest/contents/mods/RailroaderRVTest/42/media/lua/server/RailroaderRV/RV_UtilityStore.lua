-- Current-only persistence for the native generator power layer.
--
-- The current contract has no water identity or hidden tank/proxy record.

local C = require("RailroaderRV/RV_Constants")
local U = require("RailroaderRV/RV_UtilityConstants")
local Catalog = require("RailroaderRV/RV_UtilityCatalog")
local PowerConfig = require("RailroaderRV/RV_UtilityPowerConfig")

local M = {}

local function hiddenFingerprint(role, sprite)
    return tostring(role) .. ":" .. tostring(C.UTILITY_HIDDEN_OBJECT_CLASS)
        .. ":" .. tostring(sprite) .. ":"
end

local function integer(value)
    if type(value) == "string" then value = tonumber(value) end
    return type(value) == "number" and math.floor(value) == value and value or nil
end

local function number(value)
    if type(value) == "string" then value = tonumber(value) end
    return type(value) == "number" and value or nil
end

local function exactKeys(value, keys)
    if type(value) ~= "table" then return false end
    local allowed = {}
    for _, key in ipairs(keys) do allowed[key] = true end
    for key in pairs(value) do if not allowed[key] then return false end end
    for _, key in ipairs(keys) do if value[key] == nil then return false end end
    return true
end

local function exactKeysWithOptional(value, allowedKeys, requiredKeys)
    if type(value) ~= "table" then return false end
    local allowed = {}
    for _, key in ipairs(allowedKeys) do allowed[key] = true end
    for key in pairs(value) do if not allowed[key] then return false end end
    for _, key in ipairs(requiredKeys) do if value[key] == nil then return false end end
    return true
end

local function empty(value)
    if type(value) ~= "table" then return false end
    for _ in pairs(value) do return false end
    return true
end

-- ModData returns the live persistence table.  Records therefore never leave
-- this module by reference: every caller receives a working copy and commit
-- stores another copy.  This keeps mutations made while a world operation is
-- pending out of the autosave root until the transmit boundary succeeds.
local function copyTable(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, nested in pairs(value) do result[key] = copyTable(nested) end
    return result
end

local function finite(value)
    value = number(value)
    return value ~= nil and value == value and value < math.huge and value > -math.huge
end

local function validPlainData(value, depth, seen)
    if type(value) ~= "table" then
        if type(value) == "number" then
            return finite(value)
        end
        return type(value) == "string" or type(value) == "boolean"
    end
    if depth > 6 or seen[value] then return false end
    seen[value] = true
    for key, nested in pairs(value) do
        if (type(key) ~= "string" and type(key) ~= "number")
            or not validPlainData(nested, depth + 1, seen) then
            seen[value] = nil
            return false
        end
    end
    seen[value] = nil
    return true
end

local function identityValid(identity)
    return type(identity) == "table" and type(identity.rvId) == "string"
        and identity.rvId ~= "" and integer(identity.generation) ~= nil
        and integer(identity.generation) >= 1
        and integer(identity.bitmapVersion) == C.BITMAP_VERSION
end

local function identityMatches(value, identity)
    return identityValid(identity) and type(value) == "table"
        and tostring(value.rvId) == tostring(identity.rvId)
        and integer(value.generation) == integer(identity.generation)
        and integer(value.bitmapVersion) == integer(identity.bitmapVersion)
end

-- The disabled auto-refill channel deliberately has its own current schema:
-- its provider identity is scoped to the RV generation, while the exact
-- record does not persist the map bitmap version.  Do not route this check
-- through the full object/mapping identity contract.
local function autoRefillIdentityMatches(value, identity)
    return type(value) == "table" and type(identity) == "table"
        and tostring(value.rvId) == tostring(identity.rvId)
        and integer(value.generation) == integer(identity.generation)
end

local function validCanonical(value)
    local allowed = { "capacity", "amount", "sequence", "state", "projectionPending",
        "pendingProjectionSequence", "pendingProjectionReason", "faultPolicy", "checkpoint" }
    local required = { "capacity", "amount", "sequence", "state", "projectionPending" }
    return exactKeysWithOptional(value, allowed, required)
        and type(value.capacity) == "number" and value.capacity == U.WATER_CAPACITY
        and type(value.amount) == "number" and value.amount >= 0
        and value.amount <= value.capacity
        and integer(value.sequence) ~= nil and value.sequence >= 0
        and type(value.projectionPending) == "boolean"
end

local function validUsageIdentity(value, identity)
    local keys = { "role", "rvId", "generation", "bitmapVersion", "x", "y", "z",
        "objectToken", "objectFingerprint" }
    return exactKeys(value, keys) and value.role == C.UTILITY_ROLE_TANK
        and identityMatches(value, identity) and integer(value.x) ~= nil
        and integer(value.y) ~= nil and integer(value.z) ~= nil
        and type(value.objectToken) == "string" and value.objectToken ~= ""
        and type(value.objectFingerprint) == "string"
        and value.objectFingerprint == hiddenFingerprint(C.UTILITY_ROLE_TANK,
            C.SPRITES.utilityHidden.sprite)
end

local function validUsageSnapshot(value)
    local allowed = { "capacity", "amount", "baselineSequence", "usageSequence",
        "settledCanonicalSequence", "projectionSequence", "state" }
    return exactKeysWithOptional(value, allowed, { "capacity", "amount" })
        and type(value.capacity) == "number" and value.capacity == U.WATER_CAPACITY
        and type(value.amount) == "number" and value.amount >= 0
        and value.amount <= value.capacity
end

local function validRegistryEntry(value, identity)
    local keys = { "deviceId", "deviceType", "rvId", "generation", "bitmapVersion",
        "fixtureX", "fixtureY", "fixtureZ", "fixtureToken", "fixtureFingerprint",
        "proxyX", "proxyY", "proxyZ", "proxyToken", "proxyFingerprint",
        "registeredSequence", "status" }
    return exactKeys(value, keys) and identityMatches(value, identity)
        and type(value.deviceId) == "string" and value.deviceId ~= ""
        and type(value.deviceType) == "string" and value.deviceType ~= ""
        and type(Catalog.DEVICE_CATALOG[value.deviceType]) == "table"
        and Catalog.entryIsRuntimeTestEnabled(Catalog.DEVICE_CATALOG[value.deviceType])
        and integer(value.fixtureX) ~= nil and integer(value.fixtureY) ~= nil
        and integer(value.fixtureZ) ~= nil and type(value.fixtureToken) == "string"
        and value.fixtureToken ~= "" and type(value.fixtureFingerprint) == "string"
        and value.fixtureFingerprint ~= "" and integer(value.proxyX) ~= nil
        and integer(value.proxyY) ~= nil and integer(value.proxyZ) ~= nil
        and type(value.proxyToken) == "string" and value.proxyToken ~= ""
        and type(value.proxyFingerprint) == "string"
        and value.proxyFingerprint == hiddenFingerprint(C.UTILITY_ROLE_PROXY,
            C.SPRITES.utilityProxy.sprite)
        and integer(value.registeredSequence) ~= nil and value.registeredSequence >= 1
        and (value.status == U.STATUS_ACTIVE or value.status == U.STATUS_NEEDS_RECONCILE
            or value.status == U.STATUS_DEFERRED or value.status == U.STATUS_QUARANTINE_PENDING
            or value.status == U.STATUS_SUSPENDED or value.status == U.STATUS_REBUILD_REQUIRED)
end

local function validProxyLedger(value, deviceId)
    local allowed = { "deviceId", "amount", "capacity", "baselineSequence",
        "usageSequence", "projectionSequence", "status" }
    local required = { "deviceId", "amount", "capacity", "status" }
    return exactKeysWithOptional(value, allowed, required)
        and tostring(value.deviceId) == tostring(deviceId)
        and type(value.amount) == "number" and value.amount >= 0
        and type(value.capacity) == "number" and value.capacity == U.WATER_CAPACITY
end

local function validAutoRefill(value, identity)
    local keys = { "providerId", "channelId", "rvId", "generation", "schemaVersion",
        "sequence", "state", "confirmedDelta", "objectToken", "objectFingerprint" }
    return exactKeys(value, keys) and value.providerId == C.UTILITY_AUTO_REFILL_PROVIDER
        and value.channelId == C.UTILITY_AUTO_REFILL_CHANNEL
        and autoRefillIdentityMatches(value, identity)
        and integer(value.schemaVersion) == U.WATER_SCHEMA_VERSION
        and integer(value.sequence) == 0 and value.state == U.AUTO_REFILL_DISABLED
        and value.confirmedDelta == 0 and value.objectToken == ""
        and value.objectFingerprint == ""
end

local function validWater(value, identity)
    local keys = { "schemaVersion", "canonicalTank", "usageTankIdentity",
        "usageTankSnapshot", "registry", "proxyLedger", "requestLedger",
        "autoRefill", "state" }
    local required = { "schemaVersion", "canonicalTank", "usageTankIdentity",
        "usageTankSnapshot", "registry", "proxyLedger", "autoRefill", "state" }
    if not exactKeysWithOptional(value, keys, required)
        or integer(value.schemaVersion) ~= U.WATER_SCHEMA_VERSION
        or not validCanonical(value.canonicalTank)
        or not validUsageIdentity(value.usageTankIdentity, identity)
        or not validUsageSnapshot(value.usageTankSnapshot)
        or type(value.registry) ~= "table" or type(value.proxyLedger) ~= "table"
        or not validAutoRefill(value.autoRefill, identity)
        or (value.state ~= U.WATER_STATE_ACTIVE and value.state ~= U.WATER_STATE_NEEDS_RECONCILE
            and value.state ~= U.WATER_STATE_DEFERRED
            and value.state ~= U.WATER_STATE_QUARANTINE_PENDING
            and value.state ~= U.WATER_STATE_REBUILD_REQUIRED) then return false end
    local count = 0
    for deviceId, entry in pairs(value.registry) do
        if type(deviceId) ~= "string" or not validRegistryEntry(entry, identity)
            or tostring(entry.deviceId) ~= deviceId
            or not validProxyLedger(value.proxyLedger[deviceId], deviceId) then
            return false
        end
        count = count + 1
    end
    local proxyCount = 0
    for deviceId, entry in pairs(value.proxyLedger) do
        if type(deviceId) ~= "string" or not validProxyLedger(entry, deviceId)
            or value.registry[deviceId] == nil then return false end
        proxyCount = proxyCount + 1
    end
    if count ~= proxyCount then return false end
    return true
end

local function validGenerator(value, identity)
    if value == nil then return true end
    local keys = { "rvId", "generation", "bitmapVersion", "x", "y", "z",
        "objectToken", "objectFingerprint" }
    return exactKeys(value, keys) and identityMatches(value, identity)
        and integer(value.x) ~= nil and integer(value.y) ~= nil and integer(value.z) ~= nil
        and type(value.objectToken) == "string" and value.objectToken ~= ""
        and type(value.objectFingerprint) == "string" and value.objectFingerprint ~= ""
end

local BATTERY_TYPES = {
    ["Base.CarBattery"] = true,
    ["Base.CarBattery1"] = true,
    ["Base.CarBattery2"] = true,
    ["Base.CarBattery3"] = true,
}

local function validBattery(value)
    local keys = { "id", "fullType", "condition", "maxCondition", "usedDelta", "modData" }
    return exactKeys(value, keys) and integer(value.id) ~= nil and value.id >= 1
        and BATTERY_TYPES[value.fullType] == true
        and integer(value.condition) ~= nil and integer(value.maxCondition) ~= nil
        and value.maxCondition > 0 and value.condition >= 0
        and value.condition <= value.maxCondition and finite(value.usedDelta)
        and value.usedDelta >= 0 and value.usedDelta <= 1
        and type(value.modData) == "table" and validPlainData(value.modData, 1, {})
end

local function validComponent(value, fullType)
    if value == nil then return true end
    local keys = { "fullType", "condition", "conditionMax", "modData" }
    return exactKeys(value, keys) and value.fullType == fullType
        and integer(value.condition) ~= nil
        and integer(value.conditionMax) == PowerConfig.COMPONENT_CONDITION_MAX
        and value.condition > 0 and value.condition <= value.conditionMax
        and type(value.modData) == "table" and validPlainData(value.modData, 1, {})
end

local function validPower(value, identity)
    local keys = { "schemaVersion", "generator", "circuitState", "generatorEnabled",
        "virtualFuelL", "batteryWh", "batteryCapacityWh", "maxChargePowerW",
        "maxDischargePowerW", "generationPowerW", "currentLoadW", "chargerEfficiency",
        "inverterEfficiency", "batteries", "nextBatteryId", "charger", "inverter",
        "lastUpdateTime", "lastSettlementTime", "sequence", "state" }
    if not exactKeysWithOptional(value, keys,
        { "schemaVersion", "circuitState", "generatorEnabled", "virtualFuelL",
            "batteryWh", "batteryCapacityWh", "maxChargePowerW", "maxDischargePowerW",
            "generationPowerW", "currentLoadW", "chargerEfficiency", "inverterEfficiency",
            "batteries", "nextBatteryId", "lastUpdateTime", "lastSettlementTime",
            "sequence", "state" })
        or integer(value.schemaVersion) ~= U.POWER_SCHEMA_VERSION
        or not validGenerator(value.generator, identity)
        or (value.circuitState ~= U.CIRCUIT_OFF and value.circuitState ~= U.CIRCUIT_ON)
        or type(value.generatorEnabled) ~= "boolean"
        or not finite(value.virtualFuelL) or value.virtualFuelL < 0
        or value.virtualFuelL > PowerConfig.VIRTUAL_FUEL_CAPACITY_L
        or not finite(value.batteryWh) or value.batteryWh < 0
        or not finite(value.batteryCapacityWh) or value.batteryCapacityWh < 0
        or not finite(value.maxChargePowerW) or value.maxChargePowerW < 0
        or not finite(value.maxDischargePowerW) or value.maxDischargePowerW < 0
        or not finite(value.generationPowerW) or value.generationPowerW < 0
        or value.generationPowerW > PowerConfig.GAS_GENERATOR_POWER_W
        or not finite(value.currentLoadW) or value.currentLoadW < 0
        or not finite(value.chargerEfficiency) or value.chargerEfficiency <= 0
        or value.chargerEfficiency > 1
        or not finite(value.inverterEfficiency) or value.inverterEfficiency <= 0
        or value.inverterEfficiency > 1
        or type(value.batteries) ~= "table" or integer(value.nextBatteryId) == nil
        or value.nextBatteryId < 1 or not validComponent(value.charger,
            "RailroaderRVTest.RVCharger")
        or not validComponent(value.inverter, "RailroaderRVTest.RVInverter")
        or not finite(value.lastUpdateTime) or value.lastUpdateTime < 0
        or not finite(value.lastSettlementTime) or value.lastSettlementTime < 0
        or integer(value.sequence) == nil
        or value.sequence < 0 or (value.state ~= U.POWER_STATE_READY
            and value.state ~= U.POWER_STATE_DEGRADED) then return false end
    local count, capacity, chargePower, dischargePower, largestId = 0, 0, 0, 0, 0
    for key, battery in pairs(value.batteries) do
        if integer(key) == nil or key < 1 or not validBattery(battery) then return false end
        local parameters = PowerConfig.batteryParameters(battery.condition,
            battery.maxCondition)
        if not parameters then return false end
        count = count + 1
        capacity = capacity + parameters.capacityWh
        chargePower = chargePower + parameters.maxChargePowerW
        dischargePower = dischargePower + parameters.maxDischargePowerW
        largestId = math.max(largestId, battery.id)
    end
    if count ~= #value.batteries or value.nextBatteryId <= largestId
        or math.abs(value.batteryCapacityWh - capacity) > PowerConfig.PERSISTED_POWER_TOLERANCE
        or math.abs(value.maxChargePowerW - chargePower) > PowerConfig.PERSISTED_POWER_TOLERANCE
        or math.abs(value.maxDischargePowerW - dischargePower) > PowerConfig.PERSISTED_POWER_TOLERANCE
        or value.batteryWh > value.batteryCapacityWh + PowerConfig.PERSISTED_POWER_TOLERANCE then return false end
    local expectedCharger = value.charger
        and value.charger.condition / value.charger.conditionMax
        or PowerConfig.DEFAULT_CHARGER_EFFICIENCY
    local expectedInverter = value.inverter
        and value.inverter.condition / value.inverter.conditionMax
        or PowerConfig.DEFAULT_INVERTER_EFFICIENCY
    return math.abs(value.chargerEfficiency - expectedCharger) <= PowerConfig.NUMERIC_EPSILON
        and math.abs(value.inverterEfficiency - expectedInverter) <= PowerConfig.NUMERIC_EPSILON
end

local function validRecord(value, identity)
    return exactKeys(value, { "rvId", "generation", "bitmapVersion", "power" })
        and identityMatches(value, identity)
        and validPower(value.power, identity)
end

-- Read-only root access.  A nil/empty result is a genuinely fresh container;
-- a non-empty result must already be the exact current schema.  No fields are
-- written here, so failed initialization cannot seed a half-record in ModData.
local function readRoot()
    if not ModData or type(ModData.get) ~= "function" then
        error(C.INVALID_RV_DATA)
    end
    local ok, value = pcall(ModData.get, U.STORE_KEY)
    if not ok then error(C.INVALID_RV_DATA) end
    if value == nil then return nil end
    if type(value) ~= "table" then error(C.INVALID_RV_DATA) end
    if empty(value) then return value end
    if not exactKeys(value, { "schemaVersion", "records" })
        or integer(value.schemaVersion) ~= U.STORE_SCHEMA_VERSION
        or type(value.records) ~= "table" then
        error(C.INVALID_RV_DATA)
    end
    return value
end


local function root(allowCreate)
    local value = readRoot()
    if value == nil and allowCreate and ModData and type(ModData.getOrCreate) == "function" then
        local ok, result = pcall(ModData.getOrCreate, U.STORE_KEY)
        if not ok then error(C.INVALID_RV_DATA) end
        value = result
    end
    if type(value) == "table" and empty(value) and allowCreate == true then
        value.schemaVersion = U.STORE_SCHEMA_VERSION
        value.records = {}
    end
    if type(value) ~= "table" or not exactKeys(value, { "schemaVersion", "records" })
        or integer(value.schemaVersion) ~= U.STORE_SCHEMA_VERSION
        or type(value.records) ~= "table" then error(C.INVALID_RV_DATA) end
    return value
end

local function currentIdentityGate(identity)
    if not identityValid(identity) then return false, C.INVALID_RV_DATA end
    local rv = rawget(_G, "RailroaderRV")
    local server = rv and rv.Server
    if not server or type(server.currentRVManifestForBoundary) ~= "function"
        or type(server.validateCurrentUtilityIdentity) ~= "function" then
        return false, C.INVALID_RV_DATA
    end
    local ok, accepted = pcall(server.currentRVManifestForBoundary, identity.rvId,
        identity.generation, identity.bitmapVersion)
    if not ok or accepted ~= true then return false, C.INVALID_RV_DATA end
    local mapOk, mapAccepted = pcall(server.validateCurrentUtilityIdentity, identity)
    if not mapOk or mapAccepted ~= true then return false, C.INVALID_RV_DATA end
    return true
end

local function newWater(identity)
    local x = C.TELEPORT_X + C.UTILITY_TANK_OFFSET.x
    local y = C.TELEPORT_Y + C.UTILITY_TANK_OFFSET.y
    local z = C.TELEPORT_Z + C.UTILITY_TANK_OFFSET.z
    local token = tostring(identity.rvId) .. ":" .. tostring(identity.generation)
        .. ":" .. tostring(identity.bitmapVersion) .. ":tank:" .. tostring(x)
        .. ":" .. tostring(y) .. ":" .. tostring(z)
    local canonical = { capacity = U.WATER_CAPACITY, amount = 0, sequence = 0,
        state = U.WATER_STATE_ACTIVE, projectionPending = false,
        pendingProjectionSequence = nil, pendingProjectionReason = nil }
    return {
        schemaVersion = U.WATER_SCHEMA_VERSION,
        canonicalTank = canonical,
        usageTankIdentity = { role = C.UTILITY_ROLE_TANK, rvId = identity.rvId,
            generation = identity.generation, bitmapVersion = identity.bitmapVersion,
            x = x, y = y, z = z, objectToken = token,
            objectFingerprint = hiddenFingerprint(C.UTILITY_ROLE_TANK,
                C.SPRITES.utilityHidden.sprite) },
        usageTankSnapshot = { capacity = U.WATER_CAPACITY, amount = 0 },
        registry = {}, proxyLedger = {},
        autoRefill = { providerId = C.UTILITY_AUTO_REFILL_PROVIDER,
            channelId = C.UTILITY_AUTO_REFILL_CHANNEL, rvId = identity.rvId,
            generation = identity.generation, schemaVersion = U.WATER_SCHEMA_VERSION,
            sequence = 0, state = U.AUTO_REFILL_DISABLED, confirmedDelta = 0,
            objectToken = "", objectFingerprint = "" },
        state = U.WATER_STATE_ACTIVE,
    }
end

local function newPower()
    return { schemaVersion = U.POWER_SCHEMA_VERSION, generator = nil,
        circuitState = U.CIRCUIT_OFF, generatorEnabled = false,
        virtualFuelL = 0, batteryWh = 0, batteryCapacityWh = 0,
        maxChargePowerW = 0, maxDischargePowerW = 0, generationPowerW = 0,
        currentLoadW = 0,
        chargerEfficiency = PowerConfig.DEFAULT_CHARGER_EFFICIENCY,
        inverterEfficiency = PowerConfig.DEFAULT_INVERTER_EFFICIENCY,
        batteries = {}, nextBatteryId = 1, charger = nil, inverter = nil,
        lastUpdateTime = 0, lastSettlementTime = 0, sequence = 0,
        state = U.POWER_STATE_READY }
end

local function newRecord(identity)
    return { rvId = tostring(identity.rvId), generation = identity.generation,
        bitmapVersion = identity.bitmapVersion, power = newPower() }
end

function M.validateIdentity(identity)
    return currentIdentityGate(identity)
end

function M.getRecord(identity, allowCreate)
    local gateOk, gateReason = currentIdentityGate(identity)
    if not gateOk then return false, gateReason end
    local ok, value = pcall(readRoot)
    if not ok then return false, C.INVALID_RV_DATA end
    local id = tostring(identity.rvId)
    local record
    if value == nil or empty(value) then
        if allowCreate ~= true then return false, C.INVALID_RV_DATA end
        record = newRecord(identity)
    else
        local persisted = value.records[id]
        if persisted == nil then
            if allowCreate ~= true then return false, C.INVALID_RV_DATA end
            record = newRecord(identity)
        else
            if not validRecord(persisted, identity) then
                return false, C.INVALID_RV_DATA
            end
            if type(persisted.power) ~= "table" or persisted.power.generator == nil then
                return false, C.INVALID_RV_DATA
            end
            record = copyTable(persisted)
        end
    end
    if not validRecord(record, identity) then return false, C.INVALID_RV_DATA end
    return true, record
end

function M.commit(record, identity)
    local gateOk, gateReason = currentIdentityGate(identity)
    if not gateOk then return false, gateReason end
    if not validRecord(record, identity) or record.power.generator == nil then
        return false, C.INVALID_RV_DATA
    end
    local ok, value = pcall(root, true)
    if not ok then return false, C.INVALID_RV_DATA end
    -- Keep the caller's working copy detached even after a successful commit;
    -- later mutations must require another explicit commit.
    local id = tostring(identity.rvId)
    local previous = value.records[id]
    value.records[id] = copyTable(record)
    if ModData and type(ModData.transmit) == "function" then
        local sent, result = pcall(ModData.transmit, U.STORE_KEY)
        if not sent or result == false then
            -- Callers compensate inventory changes when commit fails. Restore
            -- the canonical in-memory record first so both sides stay aligned.
            value.records[id] = previous
            return false, U.REASONS.CANONICAL_COMMIT_FAILED
        end
    end
    return true
end

function M.allRecords()
    local ok, value = pcall(readRoot)
    if not ok then return false, C.INVALID_RV_DATA end
    local result = {}
    if value == nil or empty(value) then return true, result end
    for id, record in pairs(value.records) do
        if type(id) ~= "string" or type(record) ~= "table"
            or tostring(record.rvId) ~= id or type(record.power) ~= "table"
            or record.power.generator == nil then return false, C.INVALID_RV_DATA end
        local identity = { rvId = record.rvId, generation = record.generation,
            bitmapVersion = record.bitmapVersion }
        if not validRecord(record, identity) then return false, C.INVALID_RV_DATA end
        result[#result + 1] = { identity = identity, record = copyTable(record) }
    end
    return true, result
end

-- Validate the persistent utility contract before generation changes world state.
-- This deliberately does not call currentIdentityGate: the Railroader mapping
-- is committed later in the generation transaction and is required by that
-- gate.  A fresh root or a root with no record for this RV can be initialized
-- after the mapping is committed; an existing record must already match the
-- candidate generation exactly.
function M.validateGenerationUtilityState(identity)
    if not identityValid(identity) then return false, C.INVALID_RV_DATA end
    local callOk, recordsOk, entries = pcall(M.allRecords)
    if not callOk or recordsOk ~= true or type(entries) ~= "table" then
        return false, C.INVALID_RV_DATA
    end
    for _, entry in ipairs(entries) do
        if tostring(entry.identity.rvId) == tostring(identity.rvId)
            and not validRecord(entry.record, identity) then
            return false, C.INVALID_RV_DATA
        end
    end
    return true
end

function M.snapshot(record)
    local power = copyTable(record.power)
    for _, battery in ipairs(power.batteries) do battery.modData = nil end
    if power.charger then power.charger.modData = nil end
    if power.inverter then power.inverter.modData = nil end
    return { rvId = record.rvId, generation = record.generation,
        bitmapVersion = record.bitmapVersion, power = power }
end

return M
