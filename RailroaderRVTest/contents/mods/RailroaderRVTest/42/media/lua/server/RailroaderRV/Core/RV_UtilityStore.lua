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
local function readRoot()
    return ModData.get(U.STORE_KEY)
end


local function root(allowCreate)
    local value = readRoot()
    if value == nil and allowCreate and ModData and type(ModData.getOrCreate) == "function" then
        value = ModData.getOrCreate(U.STORE_KEY)
    end
    if type(value) == "table" and empty(value) and allowCreate == true then
        value.records = {}
    end
    return value
end

local function currentIdentityGate(identity)
    local valid = identityValid(identity)
    return valid, valid and nil or C.INVALID_RV_DATA
end

local function newWater()
    return { sinks = {},
        state = U.WATER_STATE_ACTIVE }
end

local function newPower()
    return { generator = nil,
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
        power = newPower(), water = newWater() }
end

function M.validateIdentity(identity)
    return currentIdentityGate(identity)
end

function M.getRecord(identity, allowCreate)
    local gateOk, gateReason = currentIdentityGate(identity)
    if not gateOk then return false, gateReason end
    local value = readRoot()
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
                or integer(persisted.generation) ~= integer(identity.generation) then
                return false, C.INVALID_RV_DATA
            end
            record = copyTable(persisted)
        end
    end
    return true, record
end

function M.commit(record, identity)
    local gateOk, gateReason = currentIdentityGate(identity)
    if not gateOk then return false, gateReason end
    if type(record) ~= "table"
        or tostring(record.rvId) ~= tostring(identity.rvId)
        or integer(record.generation) ~= integer(identity.generation) then
        return false, C.INVALID_RV_DATA
    end
    local value = root(true)
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
    local value = readRoot()
    local result = {}
    if value == nil or empty(value) then return true, result end
    for _, record in pairs(value.records) do
        local identity = { rvId = record.rvId, generation = record.generation }
        result[#result + 1] = { identity = identity, record = copyTable(record) }
    end
    return true, result
end

function M.snapshot(record)
    local power = copyTable(record.power)
    for _, battery in ipairs(power.batteries) do battery.modData = nil end
    if power.charger then power.charger.modData = nil end
    if power.inverter then power.inverter.modData = nil end
    return { rvId = record.rvId, generation = record.generation,
        power = power, water = copyTable(record.water) }
end

function M.waterSinkKey(x, y, z)
    return waterSinkKey(x, y, z)
end

return M
