-- Current-only persistence for the water/power utility layer.
--
-- The store intentionally has no migration, alias, fallback, or conversion
-- path.  A non-empty container must exactly match this file's schema or the
-- current RV operation is rejected with SAVE_REBUILD_REQUIRED.

local C = require("RailroaderRV/RV_Constants")
local U = require("RailroaderRV/RV_UtilityConstants")
local Catalog = require("RailroaderRV/RV_UtilityCatalog")

local M = {}
local sessionPrepared = {}

local function hiddenFingerprint(role, sprite)
    return tostring(role) .. ":" .. tostring(C.UTILITY_HIDDEN_OBJECT_CLASS)
        .. ":" .. tostring(sprite) .. ":"
end

local function integer(value)
    if type(value) == "string" then value = tonumber(value) end
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and math.floor(value) == value and value or nil
end

local function number(value)
    if type(value) == "string" then value = tonumber(value) end
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge and value or nil
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
    return number(value) ~= nil
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

local function validCheckpoint(value)
    return exactKeys(value, { "canonicalSequence", "usageSequence", "usageAmount", "state" })
        and integer(value.canonicalSequence) ~= nil and value.canonicalSequence >= 0
        and integer(value.usageSequence) ~= nil and value.usageSequence >= 0
        and finite(value.usageAmount) and value.usageAmount >= 0
        and value.usageAmount <= U.WATER_CAPACITY
        and (value.state == U.CHECKPOINT_SETTLED
            or value.state == U.CHECKPOINT_UNSETTLED
            or value.state == U.CHECKPOINT_DEFERRED)
end

local function validCanonical(value)
    local keys = { "capacity", "amount", "sequence", "state", "projectionPending",
        "pendingProjectionSequence", "pendingProjectionReason", "faultPolicy", "checkpoint" }
    local required = { "capacity", "amount", "sequence", "state", "projectionPending",
        "faultPolicy", "checkpoint" }
    if not exactKeysWithOptional(value, keys, required) or not finite(value.capacity)
        or value.capacity ~= U.WATER_CAPACITY or not finite(value.amount)
        or value.amount < 0 or value.amount > value.capacity
        or integer(value.sequence) == nil or value.sequence < 0
        or type(value.projectionPending) ~= "boolean"
        or not validCheckpoint(value.checkpoint)
        or (value.state ~= U.WATER_STATE_ACTIVE
            and value.state ~= U.WATER_STATE_NEEDS_RECONCILE
            and value.state ~= U.WATER_STATE_DEFERRED
            and value.state ~= U.WATER_STATE_QUARANTINE_PENDING
            and value.state ~= U.WATER_STATE_REBUILD_REQUIRED)
        or (value.faultPolicy ~= U.FAULT_NONE
            and value.faultPolicy ~= U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD) then
        return false
    end
    if value.projectionPending then
        if integer(value.pendingProjectionSequence) == nil
            or value.pendingProjectionSequence < 0
            or type(value.pendingProjectionReason) ~= "string"
            or value.pendingProjectionReason == "" then return false end
    elseif value.pendingProjectionSequence ~= nil or value.pendingProjectionReason ~= nil then
        return false
    end
    return true
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

local function validUsageSnapshot(value, identity)
    local keys = { "capacity", "amount", "baselineSequence", "usageSequence",
        "settledCanonicalSequence", "projectionSequence", "state" }
    return exactKeys(value, keys) and finite(value.capacity)
        and value.capacity == U.WATER_CAPACITY and finite(value.amount)
        and value.amount >= 0 and value.amount <= value.capacity
        and integer(value.baselineSequence) ~= nil and value.baselineSequence >= 0
        and integer(value.usageSequence) ~= nil and value.usageSequence >= 0
        and integer(value.settledCanonicalSequence) ~= nil
        and value.settledCanonicalSequence >= 0
        and integer(value.projectionSequence) ~= nil and value.projectionSequence >= 0
        and (value.state == U.CHECKPOINT_SETTLED
            or value.state == U.CHECKPOINT_UNSETTLED
            or value.state == U.CHECKPOINT_DEFERRED)
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
    local keys = { "deviceId", "amount", "capacity", "baselineSequence", "usageSequence",
        "projectionSequence", "status" }
    return exactKeys(value, keys) and tostring(value.deviceId) == tostring(deviceId)
        and finite(value.amount) and value.amount >= 0 and finite(value.capacity)
        and value.capacity == U.WATER_CAPACITY
        and integer(value.baselineSequence) ~= nil and value.baselineSequence >= 0
        and integer(value.usageSequence) ~= nil and value.usageSequence >= 0
        and integer(value.projectionSequence) ~= nil and value.projectionSequence >= 0
        and (value.status == U.STATUS_ACTIVE or value.status == U.STATUS_NEEDS_RECONCILE
            or value.status == U.STATUS_DEFERRED or value.status == U.STATUS_QUARANTINE_PENDING
            or value.status == U.STATUS_SUSPENDED or value.status == U.STATUS_REBUILD_REQUIRED)
end

local function validRequest(value, key)
    local keys = { "requestId", "sessionNonce", "entryPoint", "operation", "status",
        "plannedTransfer", "confirmedSource", "confirmedCanonical", "sequence" }
    return exactKeys(value, keys) and type(value.requestId) == "string"
        and value.requestId ~= "" and type(value.sessionNonce) == "string"
        and value.sessionNonce ~= "" and type(value.entryPoint) == "string"
        and (value.entryPoint == U.ENTRY_INTERNAL or value.entryPoint == U.ENTRY_LOCOMOTIVE)
        and value.operation == U.OP_ADD_WATER
        and (value.status == "COMMITTED" or value.status == "REJECTED"
            or value.status == U.STATUS_REBUILD_REQUIRED)
        and finite(value.plannedTransfer) and value.plannedTransfer >= 0
        and finite(value.confirmedSource) and value.confirmedSource >= 0
        and finite(value.confirmedCanonical) and value.confirmedCanonical >= 0
        and integer(value.sequence) ~= nil and value.sequence >= 0
        and tostring(value.sessionNonce) .. ":" .. tostring(value.entryPoint) .. ":"
            .. tostring(value.requestId) == tostring(key)
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
    if not exactKeys(value, keys) or integer(value.schemaVersion) ~= U.WATER_SCHEMA_VERSION
        or not validCanonical(value.canonicalTank)
        or not validUsageIdentity(value.usageTankIdentity, identity)
        or not validUsageSnapshot(value.usageTankSnapshot, identity)
        or type(value.registry) ~= "table" or type(value.proxyLedger) ~= "table"
        or type(value.requestLedger) ~= "table" or not validAutoRefill(value.autoRefill, identity)
        or (value.state ~= U.WATER_STATE_ACTIVE and value.state ~= U.WATER_STATE_NEEDS_RECONCILE
            and value.state ~= U.WATER_STATE_DEFERRED
            and value.state ~= U.WATER_STATE_QUARANTINE_PENDING
            and value.state ~= U.WATER_STATE_REBUILD_REQUIRED) then return false end
    if value.canonicalTank.checkpoint.canonicalSequence > value.canonicalTank.sequence
        or value.usageTankSnapshot.settledCanonicalSequence > value.canonicalTank.sequence
        or value.canonicalTank.checkpoint.usageSequence > value.usageTankSnapshot.usageSequence
        or value.usageTankSnapshot.baselineSequence > value.usageTankSnapshot.usageSequence
        or value.usageTankSnapshot.projectionSequence > value.canonicalTank.sequence
        or (value.canonicalTank.checkpoint.state == U.CHECKPOINT_SETTLED
            and value.usageTankSnapshot.state == U.CHECKPOINT_SETTLED
            and math.abs(value.canonicalTank.checkpoint.usageAmount
                - value.usageTankSnapshot.amount) > U.PROFILE_EPSILON) then
        return false
    end
    local count = 0
    for deviceId, entry in pairs(value.registry) do
        if type(deviceId) ~= "string" or not validRegistryEntry(entry, identity)
            or tostring(entry.deviceId) ~= deviceId
            or not validProxyLedger(value.proxyLedger[deviceId], deviceId)
            or value.proxyLedger[deviceId].baselineSequence > value.usageTankSnapshot.usageSequence
            or value.proxyLedger[deviceId].usageSequence > value.usageTankSnapshot.usageSequence
            or value.proxyLedger[deviceId].projectionSequence > value.canonicalTank.sequence then
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
    local requestCount = 0
    for requestKey, request in pairs(value.requestLedger) do
        if type(requestKey) ~= "string" or not validRequest(request, requestKey) then return false end
        if request.sequence > value.canonicalTank.sequence then return false end
        requestCount = requestCount + 1
    end
    return requestCount <= 64
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

local function validPower(value, identity)
    local keys = { "schemaVersion", "generator", "circuitState", "devicePolicy",
        "sequence", "state" }
    if not exactKeysWithOptional(value, keys,
        { "schemaVersion", "circuitState", "devicePolicy", "sequence", "state" })
        or integer(value.schemaVersion) ~= U.POWER_SCHEMA_VERSION
        or not validGenerator(value.generator, identity)
        or (value.circuitState ~= U.CIRCUIT_OFF and value.circuitState ~= U.CIRCUIT_ON)
        or type(value.devicePolicy) ~= "table" or integer(value.sequence) == nil
        or value.sequence < 0 or (value.state ~= U.POWER_STATE_READY
            and value.state ~= U.POWER_STATE_DEGRADED) then return false end
    for key, flag in pairs(value.devicePolicy) do
        if type(key) ~= "string" or type(flag) ~= "boolean" then return false end
    end
    return true
end

local function validRecord(value, identity)
    return exactKeys(value, { "rvId", "generation", "bitmapVersion", "water", "power" })
        and identityMatches(value, identity) and validWater(value.water, identity)
        and validPower(value.power, identity)
end

-- Read-only root access.  A nil/empty result is a genuinely fresh container;
-- a non-empty result must already be the exact current schema.  No fields are
-- written here, so failed initialization cannot seed a half-record in ModData.
local function readRoot()
    if not ModData or type(ModData.get) ~= "function" then
        error(C.SAVE_REBUILD_REQUIRED)
    end
    local ok, value = pcall(ModData.get, U.STORE_KEY)
    if not ok then error(C.SAVE_REBUILD_REQUIRED) end
    if value == nil then return nil end
    if type(value) ~= "table" then error(C.SAVE_REBUILD_REQUIRED) end
    if empty(value) then return value end
    if not exactKeys(value, { "schemaVersion", "records" })
        or integer(value.schemaVersion) ~= U.STORE_SCHEMA_VERSION
        or type(value.records) ~= "table" then
        error(C.SAVE_REBUILD_REQUIRED)
    end
    return value
end

-- Restore only the live root that this commit touched.  The snapshot is
-- either nil (no ModData container existed) or an exact current/fresh table.
-- A restoration failure is itself fail-closed: callers cannot safely infer
-- whether an ambiguous write reached the save layer.
local function restoreRoot(snapshot)
    if not ModData or type(ModData.get) ~= "function" then return snapshot == nil end
    local ok, value = pcall(ModData.get, U.STORE_KEY)
    if not ok then return false end
    if value == nil then return snapshot == nil end
    if type(value) ~= "table" then return false end
    for key in pairs(value) do value[key] = nil end
    if snapshot ~= nil then
        for key, nested in pairs(snapshot) do value[key] = copyTable(nested) end
    end
    return true
end

local function root(allowCreate)
    local value = readRoot()
    if value == nil and allowCreate and ModData and type(ModData.getOrCreate) == "function" then
        local ok, result = pcall(ModData.getOrCreate, U.STORE_KEY)
        if not ok then error(C.SAVE_REBUILD_REQUIRED) end
        value = result
    end
    if type(value) == "table" and empty(value) and allowCreate == true then
        value.schemaVersion = U.STORE_SCHEMA_VERSION
        value.records = {}
    end
    if type(value) ~= "table" or not exactKeys(value, { "schemaVersion", "records" })
        or integer(value.schemaVersion) ~= U.STORE_SCHEMA_VERSION
        or type(value.records) ~= "table" then error(C.SAVE_REBUILD_REQUIRED) end
    return value
end

local function currentIdentityGate(identity)
    if not identityValid(identity) then return false, C.SAVE_REBUILD_REQUIRED end
    local rv = rawget(_G, "RailroaderRV")
    local server = rv and rv.Server
    if not server or type(server.currentRVManifestForBoundary) ~= "function"
        or type(server.validateCurrentUtilityIdentity) ~= "function" then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local ok, accepted = pcall(server.currentRVManifestForBoundary, identity.rvId,
        identity.generation, identity.bitmapVersion)
    if not ok or accepted ~= true then return false, C.SAVE_REBUILD_REQUIRED end
    local mapOk, mapAccepted = pcall(server.validateCurrentUtilityIdentity, identity)
    if not mapOk or mapAccepted ~= true then return false, C.SAVE_REBUILD_REQUIRED end
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
        pendingProjectionSequence = nil, pendingProjectionReason = nil,
        faultPolicy = U.FAULT_NONE,
        checkpoint = { canonicalSequence = 0, usageSequence = 0,
            usageAmount = 0, state = U.CHECKPOINT_SETTLED } }
    return {
        schemaVersion = U.WATER_SCHEMA_VERSION,
        canonicalTank = canonical,
        usageTankIdentity = { role = C.UTILITY_ROLE_TANK, rvId = identity.rvId,
            generation = identity.generation, bitmapVersion = identity.bitmapVersion,
            x = x, y = y, z = z, objectToken = token,
            objectFingerprint = hiddenFingerprint(C.UTILITY_ROLE_TANK,
                C.SPRITES.utilityHidden.sprite) },
        usageTankSnapshot = { capacity = U.WATER_CAPACITY, amount = 0,
            baselineSequence = 0, usageSequence = 0, settledCanonicalSequence = 0,
            projectionSequence = 0, state = U.CHECKPOINT_SETTLED },
        registry = {}, proxyLedger = {}, requestLedger = {},
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
        circuitState = U.CIRCUIT_OFF, devicePolicy = {}, sequence = 0,
        state = U.POWER_STATE_READY }
end

local function newRecord(identity)
    return { rvId = tostring(identity.rvId), generation = identity.generation,
        bitmapVersion = identity.bitmapVersion, water = newWater(identity), power = newPower() }
end

function M.validateIdentity(identity)
    return currentIdentityGate(identity)
end

function M.getRecord(identity, allowCreate)
    local gateOk, gateReason = currentIdentityGate(identity)
    if not gateOk then return false, gateReason end
    local ok, value = pcall(readRoot)
    if not ok then return false, C.SAVE_REBUILD_REQUIRED end
    local id = tostring(identity.rvId)
    local record
    local recordFresh = false
    if value == nil or empty(value) then
        if allowCreate ~= true then return false, C.SAVE_REBUILD_REQUIRED end
        record = newRecord(identity)
        recordFresh = true
    else
        local persisted = value.records[id]
        if persisted == nil then
            if allowCreate ~= true then return false, C.SAVE_REBUILD_REQUIRED end
            record = newRecord(identity)
            recordFresh = true
        else
            if not validRecord(persisted, identity) then
                return false, C.SAVE_REBUILD_REQUIRED
            end
            record = copyTable(persisted)
        end
    end
    if not validRecord(record, identity) then return false, C.SAVE_REBUILD_REQUIRED end
    local preparedKey = id .. ":" .. tostring(identity.generation) .. ":"
        .. tostring(identity.bitmapVersion)
    if not sessionPrepared[preparedKey] then
        -- A process-local reconnect starts in reconcile mode.  It never changes
        -- fields or attempts a legacy conversion; loaded objects are handled by
        -- RV_UtilityWater before the next projection.
        record.water.state = U.WATER_STATE_NEEDS_RECONCILE
        record.water.canonicalTank.state = U.WATER_STATE_NEEDS_RECONCILE
        sessionPrepared[preparedKey] = true
    end
    return true, record, recordFresh
end

function M.commit(record, identity)
    local gateOk, gateReason = currentIdentityGate(identity)
    if not gateOk then return false, gateReason end
    if not validRecord(record, identity) then return false, C.SAVE_REBUILD_REQUIRED end
    local beforeOk, beforeRoot = pcall(readRoot)
    if not beforeOk then return false, C.SAVE_REBUILD_REQUIRED end
    local before = beforeRoot == nil and nil or copyTable(beforeRoot)
    local ok, value = pcall(root, true)
    if not ok then
        if not restoreRoot(before) then return false, C.SAVE_REBUILD_REQUIRED end
        return false, C.SAVE_REBUILD_REQUIRED
    end
    -- Keep the caller's working copy detached even after a successful commit;
    -- later mutations must require another explicit commit.
    value.records[tostring(identity.rvId)] = copyTable(record)
    if ModData and type(ModData.transmit) == "function" then
        local sent, result = pcall(ModData.transmit, U.STORE_KEY)
        if not sent or result == false then
            if not restoreRoot(before) then return false, C.SAVE_REBUILD_REQUIRED end
            return false, U.REASONS.CANONICAL_COMMIT_FAILED
        end
    end
    return true
end

function M.allRecords()
    local ok, value = pcall(readRoot)
    if not ok then return false, C.SAVE_REBUILD_REQUIRED end
    local result = {}
    if value == nil or empty(value) then return true, result end
    for id, record in pairs(value.records) do
        if type(id) ~= "string" or type(record) ~= "table"
            or tostring(record.rvId) ~= id then return false, C.SAVE_REBUILD_REQUIRED end
        local identity = { rvId = record.rvId, generation = record.generation,
            bitmapVersion = record.bitmapVersion }
        if not validRecord(record, identity) then return false, C.SAVE_REBUILD_REQUIRED end
        result[#result + 1] = { identity = identity, record = copyTable(record) }
    end
    return true, result
end

function M.validateRecord(record, identity)
    return validRecord(record, identity)
end

function M.copyWater(water)
    return copyTable(water)
end

function M.snapshot(record)
    return { rvId = record.rvId, generation = record.generation,
        bitmapVersion = record.bitmapVersion, water = copyTable(record.water),
        power = copyTable(record.power) }
end

return M
