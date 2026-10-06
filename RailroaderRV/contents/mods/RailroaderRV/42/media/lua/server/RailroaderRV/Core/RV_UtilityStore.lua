-- Current-only persistence for RV power and native sink plumbing state.

local U = require("RailroaderRV/Common/RV_UtilityConstants")
local W = require("RailroaderRV/Water/RV_UtilityWaterConstants")

local M = {}

local function copyTable(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, nested in pairs(value) do result[key] = copyTable(nested) end
    return result
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
    if value == nil and allowCreate then
        value = ModData.getOrCreate(U.STORE_KEY)
        value.records = {}
    end
    return value
end

local function newWater()
    return { centralL = 0, tankCount = 0,
        supplyPumpInstalled = false, extractionPump = nil, filter = nil,
        autoTankL = 0, sinks = {}, lastWater = {}, roofCollectors = {} }
end

local function newPower()
    return { generator = nil,
        circuitState = U.CIRCUIT_OFF, virtualFuelL = 0,
        fuelTanks = {}, nextFuelTankId = 1,
        generators = {}, nextGeneratorId = 1,
        batteryWh = 0, batteries = {}, nextBatteryId = 1,
        charger = nil, inverter = nil, controller = nil,
        circuitBreakerInstalled = false, circuitBreakerClosed = true,
        deviceCache = { template = {}, build = {} } }
end

local function newRecord(identity)
    return { rvId = tostring(identity.rvId), generation = identity.generation,
        power = newPower(), water = newWater() }
end

function M.getRecord(identity, allowCreate)
    local id = tostring(identity.rvId)
    local record
    local value = root(allowCreate == true)
    if value == nil then error("RV utility record root is not initialized") end
    local persisted = value.records[id]
    if persisted == nil or persisted.generation ~= identity.generation then
        if allowCreate ~= true then error("RV utility record is missing") end
        record = newRecord(identity)
    else
        record = copyTable(persisted)
    end
    return record
end

function M.copyRecord(record)
    return copyTable(record)
end

local function writeRecord(record, identity)
    local value = readRoot()
    local id = tostring(identity.rvId)
    value.records[id] = copyTable(record)
end

function M.commit(record, identity)
    writeRecord(record, identity)
    ModData.transmit(U.STORE_KEY)
    return true
end

function M.allRecords()
    local value = readRoot()
    local result = {}
    if value == nil then return result end
    for _, record in pairs(value.records) do
        local identity = { rvId = record.rvId, generation = record.generation }
        result[#result + 1] = { identity = identity, record = copyTable(record) }
    end
    return result
end

function M.snapshot(record)
    local power = copyTable(record.power)
    power.deviceCache = nil
    local water = copyTable(record.water)
    water.capacityL = water.tankCount * W.LITERS_PER_TANK
    local autoCapacityL, connectedSinkCount = 0, 0
    for _, collector in pairs(water.roofCollectors) do
        autoCapacityL = autoCapacityL + collector.capacityL
    end
    for _ in pairs(water.sinks) do
        connectedSinkCount = connectedSinkCount + 1
    end
    water.autoCapacityL = autoCapacityL
    water.filterRemainingL = W.remainingFilterLiters(water)
    assert(type(water.supplyPumpInstalled) == "boolean",
        "RailroaderRV: Water supply-pump installation state is invalid")
    assert(power.circuitState == U.CIRCUIT_ON
        or power.circuitState == U.CIRCUIT_OFF,
        "RailroaderRV: utility circuit state is invalid")
    water.supplyPumpPowered = water.supplyPumpInstalled
        and power.circuitState == U.CIRCUIT_ON
    water.connectedSinkCount = connectedSinkCount
    water.lastWater = nil
    return { rvId = record.rvId, generation = record.generation,
        power = power, water = water }
end

function M.waterSinkKey(x, y, z)
    return waterSinkKey(x, y, z)
end

return M
