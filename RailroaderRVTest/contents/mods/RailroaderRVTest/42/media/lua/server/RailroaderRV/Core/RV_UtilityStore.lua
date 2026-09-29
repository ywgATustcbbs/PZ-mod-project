-- Current-only persistence for RV power and native sink plumbing state.

local C = require("RailroaderRV/Common/RV_Constants")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local PowerConfig = require("RailroaderRV/Power/RV_UtilityPowerConfig")
local DevSaveSchemaGate = require("RailroaderRV/Core/RV_DevSaveSchemaGate")

local M = {}

local function integer(value)
    return type(value) == "number" and math.floor(value) == value and value or nil
end

local function number(value)
    return type(value) == "number" and value or nil
end

local function empty(value)
    if type(value) ~= "table" then return false end
    for _ in pairs(value) do return false end
    return true
end

local function copyTable(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, nested in pairs(value) do result[key] = copyTable(nested) end
    return result
end

local function identityValid(identity)
    return type(identity) == "table" and type(identity.rvId) == "string"
        and identity.rvId ~= "" and integer(identity.generation) ~= nil
        and integer(identity.generation) >= 1
        and integer(identity.bitmapVersion) == C.BITMAP_VERSION
end

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
-- Read-only root access. Persisted contents were deep-scanned once by the
-- startup gate; this path only requires the accepted root to remain readable.
local function readRoot()
    if not DevSaveSchemaGate.isReady() then error(C.INVALID_RV_DATA) end
    if not ModData or type(ModData.get) ~= "function" then
        error(C.INVALID_RV_DATA)
    end
    local ok, value = pcall(ModData.get, U.STORE_KEY)
    if not ok then error(C.INVALID_RV_DATA) end
    if value == nil then return nil end
    if type(value) ~= "table" then error(C.INVALID_RV_DATA) end
    if empty(value) then return value end
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
    if not DevSaveSchemaGate.isReady() or type(value) ~= "table"
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
    if not DevSaveSchemaGate.isReady() then return false, C.INVALID_RV_DATA end
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
            if tostring(persisted.rvId) ~= tostring(identity.rvId)
                or integer(persisted.generation) ~= integer(identity.generation)
                or integer(persisted.bitmapVersion) ~= integer(identity.bitmapVersion) then
                return false, C.INVALID_RV_DATA
            end
            record = copyTable(persisted)
        end
    end
    return true, record
end

function M.commit(record, identity)
    if not DevSaveSchemaGate.isReady() then return false, C.INVALID_RV_DATA end
    local gateOk, gateReason = currentIdentityGate(identity)
    if not gateOk then return false, gateReason end
    if type(record) ~= "table"
        or tostring(record.rvId) ~= tostring(identity.rvId)
        or integer(record.generation) ~= integer(identity.generation)
        or integer(record.bitmapVersion) ~= integer(identity.bitmapVersion) then
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
    if not DevSaveSchemaGate.isReady() then return false, C.INVALID_RV_DATA end
    local ok, value = pcall(readRoot)
    if not ok then return false, C.INVALID_RV_DATA end
    local result = {}
    if value == nil or empty(value) then return true, result end
    if type(value.records) ~= "table" then return false, C.INVALID_RV_DATA end
    for id, record in pairs(value.records) do
        if type(id) ~= "string" or type(record) ~= "table"
            or tostring(record.rvId) ~= id then
            return false, C.INVALID_RV_DATA
        end
        local identity = { rvId = record.rvId, generation = record.generation,
            bitmapVersion = record.bitmapVersion }
        if not identityValid(identity) then return false, C.INVALID_RV_DATA end
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
            and (integer(entry.identity.generation) ~= integer(identity.generation)
                or integer(entry.identity.bitmapVersion)
                    ~= integer(identity.bitmapVersion)) then
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
