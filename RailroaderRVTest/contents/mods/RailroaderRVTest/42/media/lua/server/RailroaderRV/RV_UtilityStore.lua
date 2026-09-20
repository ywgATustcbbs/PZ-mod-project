-- Current-only persistence for per-RV water and power records.
--
-- The store has no migration path.  A malformed root, record, profile, or
-- identity is rejected with SAVE_REBUILD_REQUIRED; only an absent record in a
-- valid empty container can be initialized.

local C = require("RailroaderRV/RV_Constants")
local U = require("RailroaderRV/RV_UtilityConstants")
local Catalog = require("RailroaderRV/RV_UtilityCatalog")

local M = {}
local sessionPrepared = {}

local function integer(value)
    if type(value) ~= "number" then
        if type(value) ~= "string" then return nil end
        value = tonumber(value)
    end
    if type(value) ~= "number" or value ~= value or value == math.huge
        or value == -math.huge or math.floor(value) ~= value then return nil end
    return value
end

local function number(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) end
    if value == nil then return nil end
    local ok, result = pcall(function() return value + 0 end)
    return ok and type(result) == "number" and result or nil
end

local function finite(value)
    value = number(value)
    return value ~= nil and value == value and value ~= math.huge and value ~= -math.huge
end

local function exactKeys(value, keys)
    if type(value) ~= "table" then return false end
    local allowed = {}
    for _, key in ipairs(keys) do allowed[key] = true end
    for key in pairs(value) do if not allowed[key] then return false end end
    for _, key in ipairs(keys) do if value[key] == nil then return false end end
    return true
end

local function tableEmpty(value)
    if type(value) ~= "table" then return false end
    for _ in pairs(value) do return false end
    return true
end

local function identityValid(identity)
    return type(identity) == "table"
        and type(identity.rvId) == "string" and identity.rvId ~= ""
        and integer(identity.generation) ~= nil and identity.generation >= 1
        and integer(identity.bitmapVersion) == C.BITMAP_VERSION
end

local function identityMatches(value, identity)
    return identityValid(identity) and type(value) == "table"
        and tostring(value.rvId) == tostring(identity.rvId)
        and integer(value.generation) == integer(identity.generation)
        and integer(value.bitmapVersion) == integer(identity.bitmapVersion)
end

local function validProfile(value, capacity)
    if not Catalog.isAllowedProfile(value) then return false end
    local amount = Catalog.profileAmount(value)
    capacity = number(capacity)
    return finite(amount) and amount >= 0 and finite(capacity) and capacity >= 0
        and amount <= capacity + U.PROFILE_EPSILON
end

local function validSnapshot(snapshot, deviceId, capacity)
    if not exactKeys(snapshot, { "deviceId", "amount", "capacity", "fluidProfile", "status" })
        or tostring(snapshot.deviceId) ~= tostring(deviceId)
        or not finite(snapshot.amount) or snapshot.amount < 0
        or not finite(snapshot.capacity) or snapshot.capacity < 0
        or not finite(capacity) or math.abs(snapshot.capacity - capacity) > U.PROFILE_EPSILON
        or snapshot.status ~= U.STATUS_ACTIVE and snapshot.status ~= U.STATUS_NEEDS_INIT
        or not validProfile(snapshot.fluidProfile, snapshot.capacity) then return false end
    local profileAmount = Catalog.profileAmount(snapshot.fluidProfile)
    return profileAmount ~= nil and math.abs(profileAmount - snapshot.amount)
        <= U.PROFILE_EPSILON
end

local function validRegistryEntry(entry, identity, capacity)
    local keys = { "deviceId", "deviceType", "rvId", "generation", "bitmapVersion",
        "x", "y", "z", "objectToken", "objectFingerprint", "registeredSequence", "status" }
    if not exactKeys(entry, keys) or not identityMatches(entry, identity)
        or type(entry.deviceId) ~= "string" or entry.deviceId == ""
        or type(entry.deviceType) ~= "string" or entry.deviceType == ""
        or type(Catalog.DEVICE_CATALOG[entry.deviceType]) ~= "table"
        or not Catalog.entryIsValidated(Catalog.DEVICE_CATALOG[entry.deviceType])
        or integer(entry.x) == nil or integer(entry.y) == nil or integer(entry.z) == nil
        or type(entry.objectToken) ~= "string" or entry.objectToken == ""
        or type(entry.objectFingerprint) ~= "string" or entry.objectFingerprint == ""
        or integer(entry.registeredSequence) == nil or entry.registeredSequence < 1
        or (entry.status ~= U.STATUS_ACTIVE and entry.status ~= U.STATUS_NEEDS_INIT) then
        return false
    end
    return finite(capacity) and capacity >= 0
end

local function validWater(water, identity)
    local keys = { "schemaVersion", "capacity", "sharedAmount", "fluidProfile",
        "registry", "previousSnapshot", "sequence", "state" }
    if not exactKeys(water, keys)
        or integer(water.schemaVersion) ~= U.WATER_SCHEMA_VERSION
        or not finite(water.capacity) or water.capacity < 0
        or not finite(water.sharedAmount) or water.sharedAmount < 0
        or water.sharedAmount > water.capacity + U.PROFILE_EPSILON
        or not validProfile(water.fluidProfile, water.capacity)
        or type(water.registry) ~= "table" or type(water.previousSnapshot) ~= "table"
        or integer(water.sequence) == nil or water.sequence < 0
        or (water.state ~= U.WATER_STATE_READY and water.state ~= U.WATER_STATE_WAITING
            and water.state ~= U.WATER_STATE_DEGRADED) then return false end
    local profileAmount = Catalog.profileAmount(water.fluidProfile)
    if profileAmount == nil or math.abs(profileAmount - water.sharedAmount)
        > U.PROFILE_EPSILON then return false end
    local ids = {}
    for id, entry in pairs(water.registry) do
        if type(id) ~= "string" or not validRegistryEntry(entry, identity, water.capacity)
            or tostring(entry.deviceId) ~= id or ids[id] then return false end
        ids[id] = true
    end
    for id, snapshot in pairs(water.previousSnapshot) do
        if type(id) ~= "string" or not ids[id]
            or not validSnapshot(snapshot, id, water.capacity) then return false end
    end
    for id in pairs(ids) do
        if water.previousSnapshot[id] == nil then return false end
    end
    return true
end

local function validGenerator(generator, identity)
    if generator == nil then return true end
    local keys = { "rvId", "generation", "bitmapVersion", "x", "y", "z",
        "objectToken", "objectFingerprint" }
    return exactKeys(generator, keys) and identityMatches(generator, identity)
        and integer(generator.x) ~= nil and integer(generator.y) ~= nil
        and integer(generator.z) ~= nil and type(generator.objectToken) == "string"
        and generator.objectToken ~= "" and type(generator.objectFingerprint) == "string"
        and generator.objectFingerprint ~= ""
end

local function validPower(power, identity)
    local keys = { "schemaVersion", "generator", "circuitState", "devicePolicy",
        "sequence", "state" }
    if type(power) ~= "table" then return false end
    local allowed = {}
    for _, key in ipairs(keys) do allowed[key] = true end
    for key in pairs(power) do if not allowed[key] then return false end end
    if power.schemaVersion == nil or power.circuitState == nil
        or power.devicePolicy == nil or power.sequence == nil or power.state == nil
        or integer(power.schemaVersion) ~= U.POWER_SCHEMA_VERSION
        or not validGenerator(power.generator, identity)
        or (power.circuitState ~= U.CIRCUIT_OFF and power.circuitState ~= U.CIRCUIT_ON)
        or type(power.devicePolicy) ~= "table"
        or integer(power.sequence) == nil or power.sequence < 0
        or (power.state ~= U.POWER_STATE_READY and power.state ~= U.POWER_STATE_DEGRADED) then
        return false
    end
    for key, value in pairs(power.devicePolicy) do
        if type(key) ~= "string" or type(value) ~= "boolean" then return false end
    end
    return true
end

local function validRecord(record, identity)
    return exactKeys(record, { "rvId", "generation", "bitmapVersion", "water", "power" })
        and identityMatches(record, identity)
        and validWater(record.water, identity) and validPower(record.power, identity)
end

local function root(allowCreate)
    local value
    if ModData and type(ModData.get) == "function" then
        local ok, result = pcall(ModData.get, U.STORE_KEY)
        if not ok then error(C.SAVE_REBUILD_REQUIRED) end
        value = result
    end
    if value == nil and allowCreate and ModData and type(ModData.getOrCreate) == "function" then
        local ok, result = pcall(ModData.getOrCreate, U.STORE_KEY)
        if not ok then error(C.SAVE_REBUILD_REQUIRED) end
        value = result
    end
    if type(value) == "table" and tableEmpty(value) and allowCreate == true then
        value.schemaVersion = U.STORE_SCHEMA_VERSION
        value.records = {}
    end
    if type(value) ~= "table" then error(C.SAVE_REBUILD_REQUIRED) end
    if not exactKeys(value, { "schemaVersion", "records" })
        or integer(value.schemaVersion) ~= U.STORE_SCHEMA_VERSION
        or type(value.records) ~= "table" then error(C.SAVE_REBUILD_REQUIRED) end
    for id, record in pairs(value.records) do
        if type(id) ~= "string" or type(record) ~= "table"
            or type(record.rvId) ~= "string" or tostring(record.rvId) ~= id then
            error(C.SAVE_REBUILD_REQUIRED)
        end
    end
    return value
end

local function profileCopy(value)
    return Catalog.copyProfile(value)
end

local function emptyWater()
    return {
        schemaVersion = U.WATER_SCHEMA_VERSION,
        capacity = U.WATER_CAPACITY,
        sharedAmount = 0,
        fluidProfile = Catalog.emptyProfile(),
        registry = {}, previousSnapshot = {}, sequence = 0,
        state = U.WATER_STATE_WAITING,
    }
end

local function emptyPower()
    return { schemaVersion = U.POWER_SCHEMA_VERSION, generator = nil,
        circuitState = U.CIRCUIT_OFF, devicePolicy = {}, sequence = 0,
        state = U.POWER_STATE_READY }
end

local function newRecord(identity)
    return { rvId = tostring(identity.rvId), generation = integer(identity.generation),
        bitmapVersion = integer(identity.bitmapVersion), water = emptyWater(), power = emptyPower() }
end

function M.validateIdentity(identity)
    if not identityValid(identity) then return false, C.SAVE_REBUILD_REQUIRED end
    local rv = rawget(_G, "RailroaderRV")
    local server = rv and rv.Server
    if not server or type(server.currentRVManifestForBoundary) ~= "function" then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local ok, accepted, manifest = pcall(server.currentRVManifestForBoundary,
        identity.rvId, identity.generation, identity.bitmapVersion)
    if not ok or accepted ~= true then
        print("[RailroaderRVTest] utility identity manifest gate failed ok="
            .. tostring(ok) .. " accepted=" .. tostring(accepted)
            .. " state=" .. tostring(type(manifest) == "table" and manifest.state)
            .. " phase=" .. tostring(type(manifest) == "table" and manifest.phase)
            .. " generation=" .. tostring(type(manifest) == "table" and manifest.generation)
            .. " bitmap=" .. tostring(type(manifest) == "table" and manifest.bitmapVersion))
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if type(server.validateCurrentUtilityIdentity) ~= "function" then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local mapOk, mapAccepted = pcall(server.validateCurrentUtilityIdentity, identity)
    if not mapOk or mapAccepted ~= true then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    return true
end

function M.getRecord(identity, allowCreate)
    local initializing = allowCreate == true
    if not identityValid(identity) then
        if initializing then
            print("[RailroaderRVTest] utility init rejected stage=identity")
        end
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local identityOk, identityReason = M.validateIdentity(identity)
    if not identityOk then
        if initializing then
            print("[RailroaderRVTest] utility init rejected stage=identity-gate")
        end
        return false, identityReason
    end
    local ok, value = pcall(root, allowCreate == true)
    if not ok then
        if initializing then
            print("[RailroaderRVTest] utility init rejected stage=root-schema")
        end
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local record = value.records[tostring(identity.rvId)]
    if record == nil and allowCreate == true then
        record = newRecord(identity)
        value.records[tostring(identity.rvId)] = record
    elseif record == nil then
        if initializing then
            print("[RailroaderRVTest] utility init rejected stage=record-missing")
        end
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if not validRecord(record, identity) then
        if initializing then
            print("[RailroaderRVTest] utility init rejected stage=record-schema")
        end
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local key = tostring(identity.rvId) .. ":" .. tostring(identity.generation)
        .. ":" .. tostring(identity.bitmapVersion)
    if not sessionPrepared[key] then
        for deviceId, entry in pairs(record.water.registry) do
            entry.status = U.STATUS_NEEDS_INIT
            local snapshot = record.water.previousSnapshot[deviceId]
            if snapshot then snapshot.status = U.STATUS_NEEDS_INIT end
        end
        record.water.state = U.WATER_STATE_WAITING
        sessionPrepared[key] = true
    end
    return true, record
end

function M.commit(record, identity)
    if not validRecord(record, identity) then
        print("[RailroaderRVTest] utility init rejected stage=commit-record-schema")
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local ok, value = pcall(root, true)
    if not ok then
        print("[RailroaderRVTest] utility init rejected stage=commit-root-schema")
        return false, C.SAVE_REBUILD_REQUIRED
    end
    value.records[tostring(identity.rvId)] = record
    if ModData and type(ModData.transmit) == "function" then
        local sent, result = pcall(ModData.transmit, U.STORE_KEY)
        if not sent or result == false then
            print("[RailroaderRVTest] utility init rejected stage=commit-transmit")
            return false, U.REASONS.CANONICAL_COMMIT_FAILED
        end
    end
    return true
end

function M.allRecords()
    local ok, value = pcall(root, true)
    if not ok then return false, C.SAVE_REBUILD_REQUIRED end
    local result = {}
    for rvId, record in pairs(value.records) do
        if type(rvId) ~= "string" or type(record) ~= "table"
            or type(record.rvId) ~= "string"
            or tostring(record.rvId) ~= rvId then
            return false, C.SAVE_REBUILD_REQUIRED
        end
        local identity = { rvId = record.rvId, generation = record.generation,
            bitmapVersion = record.bitmapVersion }
        if not validRecord(record, identity) then return false, C.SAVE_REBUILD_REQUIRED end
        result[#result + 1] = { identity = identity, record = record }
    end
    return true, result
end

function M.validateRecord(record, identity)
    return validRecord(record, identity)
end

function M.copyWater(water)
    local copy = { schemaVersion = water.schemaVersion, capacity = water.capacity,
        sharedAmount = water.sharedAmount, fluidProfile = profileCopy(water.fluidProfile),
        registry = {}, previousSnapshot = {}, sequence = water.sequence, state = water.state }
    for id, entry in pairs(water.registry) do
        copy.registry[id] = {}
        for key, value in pairs(entry) do copy.registry[id][key] = value end
    end
    for id, snapshot in pairs(water.previousSnapshot) do
        copy.previousSnapshot[id] = { deviceId = snapshot.deviceId, amount = snapshot.amount,
            capacity = snapshot.capacity, fluidProfile = profileCopy(snapshot.fluidProfile),
            status = snapshot.status }
    end
    return copy
end

function M.snapshot(record)
    return { rvId = record.rvId, generation = record.generation,
        bitmapVersion = record.bitmapVersion, water = M.copyWater(record.water),
        power = { schemaVersion = record.power.schemaVersion,
            generator = record.power.generator, circuitState = record.power.circuitState,
            devicePolicy = record.power.devicePolicy, sequence = record.power.sequence,
            state = record.power.state } }
end

return M
