-- Current-only persistence for RV power and native sink plumbing state.

local C = require("RailroaderRV/Common/RV_Constants")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local PowerConfig = require("RailroaderRV/Power/RV_UtilityPowerConfig")

local M = {}

local function integer(value)
    return type(value) == "number" and math.floor(value) == value and value or nil
end

local function number(value)
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

local WATER_SINK_FIELDS = { "rvId", "generation", "bitmapVersion", "slotIndex",
    "anchor", "x", "y", "z", "connected", "sequence" }

local function waterInteger(value)
    return type(value) == "number" and value == value
        and value < math.huge and value > -math.huge
        and math.floor(value) == value and value or nil
end

local function waterSinkKey(x, y, z)
    x, y, z = waterInteger(x), waterInteger(y), waterInteger(z)
    if not x or not y or not z then return nil end
    return string.format("%d:%d:%d", x, y, z)
end

local function validWaterAnchor(anchor, slotIndex)
    if not exactKeys(anchor, { "x", "y", "z" })
        or waterInteger(anchor.x) == nil or waterInteger(anchor.y) == nil
        or waterInteger(anchor.z) == nil then return false end
    local expected = RegionSlots.indexToAnchor(slotIndex)
    return expected ~= nil and anchor.x == expected.x
        and anchor.y == expected.y and anchor.z == expected.z
end

local function validWaterSink(value, identity)
    if not exactKeys(value, WATER_SINK_FIELDS)
        or type(value.rvId) ~= "string" or value.rvId ~= tostring(identity.rvId)
        or waterInteger(value.generation) ~= identity.generation
        or waterInteger(value.bitmapVersion) ~= identity.bitmapVersion
        or waterInteger(value.slotIndex) == nil
        or not validWaterAnchor(value.anchor, value.slotIndex)
        or waterInteger(value.x) == nil or waterInteger(value.y) == nil
        or waterInteger(value.z) == nil or type(value.connected) ~= "boolean"
        or waterInteger(value.sequence) == nil or value.sequence < 0 then
        return false
    end
    local region = RegionSlots.indexToRegion(value.slotIndex)
    local minZ = value.anchor.z + C.RV_MANAGED_MIN_Z_OFFSET
    local maxZ = value.anchor.z + C.RV_MANAGED_MAX_Z_OFFSET
    return region ~= nil and value.x >= region.minX and value.x < region.maxX
        and value.y >= region.minY and value.y < region.maxY
        and value.z >= minZ and value.z < maxZ
end

local function validWater(value, identity)
    if not exactKeys(value, { "schemaVersion", "sinks", "state" })
        or waterInteger(value.schemaVersion) ~= U.WATER_SCHEMA_VERSION
        or type(value.sinks) ~= "table"
        or (value.state ~= U.WATER_STATE_ACTIVE
            and value.state ~= U.WATER_STATE_NEEDS_RECONCILE) then
        return false
    end
    for key, sink in pairs(value.sinks) do
        if type(key) ~= "string" or not validWaterSink(sink, identity)
            or waterSinkKey(sink.x, sink.y, sink.z) ~= key then
            return false
        end
    end
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
    return exactKeys(value, { "rvId", "generation", "bitmapVersion", "power", "water" })
        and identityMatches(value, identity)
        and validPower(value.power, identity)
        and validWater(value.water, identity)
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

local function newWater()
    return { schemaVersion = U.WATER_SCHEMA_VERSION, sinks = {},
        state = U.WATER_STATE_ACTIVE }
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
        bitmapVersion = identity.bitmapVersion, power = newPower(),
        water = newWater() }
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
    if not ModData or type(ModData.transmit) ~= "function" then
        value.records[id] = previous
        return false, U.REASONS.CANONICAL_COMMIT_FAILED
    end
    local sent, result = pcall(ModData.transmit, U.STORE_KEY)
    if not sent or result == false then
        -- Callers compensate inventory changes when commit fails. Restore the
        -- canonical in-memory record first so both sides stay aligned.
        value.records[id] = previous
        return false, U.REASONS.CANONICAL_COMMIT_FAILED
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
        bitmapVersion = record.bitmapVersion, power = power,
        water = copyTable(record.water) }
end

function M.waterSinkKey(x, y, z)
    return waterSinkKey(x, y, z)
end

return M
