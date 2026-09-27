-- Utility protocol facade. RV_Server owns event registration and calls this
-- module for server-validated generator intents and mapping sync.

local C = require("RailroaderRV/RV_Constants")
local U = require("RailroaderRV/RV_UtilityConstants")
local Store = require("RailroaderRV/RV_UtilityStore")
local Power = require("RailroaderRV/RV_UtilityPower")
local Devices = require("RailroaderRV/RV_UtilityPowerDevices")
local Util = require("RailroaderRV/RV_ServerUtil")

local M = {}
local locks = {}
local sessions = {}
local mappingSyncState = {}
local lastTick = -1
local lastScanTick = -1

local function key(identity)
    return tostring(identity.rvId) .. ":" .. tostring(identity.generation)
        .. ":" .. tostring(identity.bitmapVersion)
end

local function playerKey(player)
    local idOk, id = Util.invoke(player, "getOnlineID")
    local nameOk, name = Util.invoke(player, "getUsername")
    if not nameOk or name == nil then nameOk, name = Util.invoke(player, "getFullName") end
    local onlineId = idOk and id or nil
    local playerName = nameOk and name or nil
    if onlineId == nil and playerName == nil then return nil end
    return tostring(onlineId or "0") .. ":" .. tostring(playerName or "unknown")
end

local function stableReason(reason)
    if tostring(reason):find(C.INVALID_RV_DATA, 1, true) then
        return U.REASON_INVALID_RV_DATA
    end
    if reason == "outside-rv" then return U.REASONS.OUTSIDE_RV end
    if reason == "unmapped-rv" then return U.REASONS.RV_NOT_FOUND end
    if reason == "permission-denied" then return U.REASONS.PERMISSION end
    return tostring(reason or U.REASONS.API_ERROR)
end

local function send(player, command, payload)
    if not player then return false end
    return Util.callGlobalSucceeded("sendServerCommand", player, C.MOD_ID,
        command, payload)
end

local function resolveRV(player)
    local rv = rawget(_G, "RailroaderRV")
    local server = rv and rv.Server
    if not server or type(server.resolveCurrentUtilityRV) ~= "function" then
        return false, U.REASONS.RV_NOT_FOUND
    end
    local ok, accepted, context = pcall(server.resolveCurrentUtilityRV, player)
    if not ok or accepted ~= true or type(context) ~= "table"
        or context.authorized ~= true or type(context.identity) ~= "table" then
        return false, stableReason((not ok and accepted) or context
            or U.REASONS.RV_NOT_FOUND)
    end
    local identity = context.identity
    if type(identity.rvId) ~= "string" or identity.rvId == ""
        or Util.integer(identity.generation) == nil
        or Util.integer(identity.bitmapVersion) ~= C.BITMAP_VERSION then
        return false, U.REASON_INVALID_RV_DATA
    end
    context.player = player
    return true, context
end

local function serviceBusy()
    local rv = rawget(_G, "RailroaderRV")
    local server = rv and rv.Server
    if not server then return true end
    if type(server.isGenerationTransactionActive) == "function" then
        local ok, active = pcall(server.isGenerationTransactionActive)
        if not ok then return true end
        if active == true then return true end
    end
    if type(server.isRoofRefreshTransactionActive) == "function" then
        local ok, active = pcall(server.isRoofRefreshTransactionActive)
        if not ok then return true end
        if active == true then return true end
    end
    return false
end

local function validText(value, maxLength)
    return type(value) == "string" and value ~= "" and #value <= maxLength
end

local function validHint(value)
    if value == nil then return true end
    return type(value) == "table"
end

local function validRequest(args)
    if type(args) ~= "table" then return false, U.REASONS.INVALID_REQUEST end
    local allowed = { requestId = true, sessionNonce = true, operation = true,
        targetHint = true, sourceHint = true }
    for field in pairs(args) do if not allowed[field] then return false, U.REASONS.INVALID_REQUEST end end
    if not validText(args.requestId, U.MAX_REQUEST_ID_LENGTH)
        or not validText(args.sessionNonce, U.MAX_NONCE_LENGTH)
        or not validText(args.operation, 64)
        or not validHint(args.targetHint) or not validHint(args.sourceHint) then
        return false, U.REASONS.INVALID_REQUEST
    end
    return true
end

local function knownOperation(operation)
    return operation == U.OP_ADD_FUEL or operation == U.OP_ADD_BATTERY
        or operation == U.OP_REMOVE_BATTERY or operation == U.OP_INSTALL_CHARGER
        or operation == U.OP_REMOVE_CHARGER or operation == U.OP_INSTALL_INVERTER
        or operation == U.OP_REMOVE_INVERTER or operation == U.OP_REFRESH_DEVICES
        or operation == U.OP_REQUEST_SNAPSHOT or operation == U.OP_START_GENERATOR
        or operation == U.OP_STOP_GENERATOR
end

local function acquire(identity)
    local identityKey = key(identity)
    if locks[identityKey] then return false, U.REASONS.BUSY end
    locks[identityKey] = true
    return true, identityKey
end

local function release(identityKey)
    if identityKey then locks[identityKey] = nil end
end

local function withGuard(identity, callback)
    local acquired, identityKeyOrReason = acquire(identity)
    if not acquired then return false, identityKeyOrReason end
    local ok, accepted, result = pcall(callback)
    release(identityKeyOrReason)
    if not ok then return false, stableReason(accepted) end
    return accepted, result
end

local function acknowledge(player, requestId, accepted, result)
    local payload = { requestId = requestId, ok = accepted == true }
    if accepted then
        payload.reason = U.REASONS.OK
        if type(result) == "table" then
            payload.sequence = result.sequence
            payload.plannedTransfer = result.plannedTransfer
            payload.confirmedTransfer = result.confirmedTransfer
            payload.projectionPending = result.projectionPending
        end
    else
        payload.reason = stableReason(result)
    end
    send(player, C.COMMAND_RV_UTILITY_ACK, payload)
end

local function remember(session, requestId, response)
    if type(session) ~= "table" then return end
    session.processed = session.processed or {}
    session.processed[requestId] = response
    local count = 0
    for _ in pairs(session.processed) do count = count + 1 end
    if count > 64 then
        for id in pairs(session.processed) do
            session.processed[id] = nil
            break
        end
    end
end

local function sessionFor(nonce, player, previous)
    local retired = previous and previous.retired or {}
    if previous and previous.nonce then retired[previous.nonce] = true end
    return { nonce = nonce, player = player, processed = {}, retired = retired }
end

local function replaceSession(id, player, nonce, previous)
    local session = sessionFor(nonce, player, previous)
    sessions[id] = session
    return session
end

local function broadcast(context, record)
    local identity = context.identity
    local payload = Store.snapshot(record)
    payload.power = Power.snapshot(record, identity, context)
    send(context.player, C.COMMAND_RV_UTILITY_SNAPSHOT, payload)
end

local function broadcastToRV(identity, record)
    local rv = rawget(_G, "RailroaderRV")
    local adapter = rv and rv.RailroaderServer
    if not adapter or type(adapter.onlinePlayersSnapshot) ~= "function" then return end
    local ok, players = pcall(adapter.onlinePlayersSnapshot)
    if not ok or type(players) ~= "table" then return end
    for i = 1, #players do
        local player = players[i]
        local contextOk, context = resolveRV(player)
        if contextOk and tostring(context.identity.rvId) == tostring(identity.rvId)
            and context.identity.generation == identity.generation
            and context.identity.bitmapVersion == identity.bitmapVersion then
            broadcast(context, record)
        end
    end
end

local function currentMappingRecord(identity)
    local rv = rawget(_G, "RailroaderRV")
    local adapter = rv and rv.RailroaderServer
    if not adapter or type(adapter.currentUtilityRecord) ~= "function" then
        return false, C.INVALID_RV_DATA
    end
    local ok, accepted, record = pcall(adapter.currentUtilityRecord, identity)
    if not ok or accepted ~= true or type(record) ~= "table" then
        return false, C.INVALID_RV_DATA
    end
    return true, record
end

local function forCurrentRecords(callback)
    local recordsOk, entries = Store.allRecords()
    if not recordsOk or type(entries) ~= "table" then
        print("[RailroaderRVTest] utility power scan skipped: invalid current schema")
        return
    end
    for i = 1, #entries do
        local entry = entries[i]
        local identity = entry.identity
        if Store.validateIdentity(identity) then
            local mappingOk, mappingRecord = currentMappingRecord(identity)
            if mappingOk then callback(identity, entry.record, mappingRecord) end
        end
    end
end

function M.handleCommand(player, args)
    local requestOk, requestReason = validRequest(args)
    if not requestOk then return false, requestReason end
    if not knownOperation(args.operation) then return false, U.REASONS.INVALID_REQUEST end
    local id = playerKey(player)
    if not id then return false, U.REASONS.INVALID_REQUEST end
    local session = sessions[id]
    if session then
        if session.retired and session.retired[args.sessionNonce] then
            acknowledge(player, args.requestId, false, U.REASONS.INVALID_NONCE)
            return false, U.REASONS.INVALID_NONCE
        elseif session.player == player and session.nonce == args.sessionNonce then
            -- Continue the active session; its idempotency table is scoped to
            -- this nonce and is never shared with a later reconnect.
        elseif session.player ~= player and session.nonce == args.sessionNonce then
            -- A replacement server player object cannot inherit the active
            -- session nonce.  The client must establish a fresh session.
            acknowledge(player, args.requestId, false, U.REASONS.INVALID_NONCE)
            return false, U.REASONS.INVALID_NONCE
        else
            -- A new nonce denotes a reconnect/reinitialised client, even when
            -- the authoritative player object is reused. Retire the old
            -- nonce so delayed packets cannot create another session with
            -- the old idempotency namespace.
            session = replaceSession(id, player, args.sessionNonce, session)
        end
    else
        session = replaceSession(id, player, args.sessionNonce, nil)
    end
    if session.processed and session.processed[args.requestId] then
        local old = session.processed[args.requestId]
        acknowledge(player, args.requestId, old.ok, old.result or old.reason)
        return old.ok, old.result or old.reason
    end
    if serviceBusy() then
        acknowledge(player, args.requestId, false, U.REASONS.BUSY)
        return false, U.REASONS.BUSY
    end
    local rvOk, contextOrReason = resolveRV(player)
    if not rvOk then
        acknowledge(player, args.requestId, false, contextOrReason)
        remember(session, args.requestId, { ok = false, reason = contextOrReason })
        return false, contextOrReason
    end
    local context = contextOrReason
    if context.phase ~= "READY" then
        local reason = U.REASONS.PERMISSION
        acknowledge(player, args.requestId, false, reason)
        remember(session, args.requestId, { ok = false, reason = reason })
        return false, reason
    end
    local identity = context.identity
    local guardOk, guardReason = withGuard(identity, function()
        local recordOk, recordOrReason = Store.getRecord(identity, false)
        if not recordOk then return false, recordOrReason end
        local settledBefore = nil
        local accepted, detail
        if args.operation == U.OP_ADD_FUEL then
            local settled, updated = Power.settleAndRefreshLoad(identity,
                context.player, recordOrReason)
            if not settled then return false, updated end
            settledBefore = updated
            accepted, detail = Power.addFuel(identity, context, args.sourceHint)
        elseif args.operation == U.OP_REFRESH_DEVICES then
            local settled, updated = Power.settleAndRefreshLoad(identity,
                context.player, recordOrReason)
            if not settled then return false, updated end
            local scanned, scanReason = Devices.scanAll(identity, context.record,
                context.player)
            if not scanned then return false, scanReason end
            local settled, settledRecord = Power.settleAndRefreshLoad(identity,
                context.player)
            accepted, detail = settled, settled and { record = settledRecord }
                or settledRecord
        elseif args.operation == U.OP_ADD_BATTERY
            or args.operation == U.OP_REMOVE_BATTERY
            or args.operation == U.OP_INSTALL_CHARGER
            or args.operation == U.OP_REMOVE_CHARGER
            or args.operation == U.OP_INSTALL_INVERTER
            or args.operation == U.OP_REMOVE_INVERTER then
            local settled, updated = Power.settleAndRefreshLoad(identity,
                context.player, recordOrReason)
            if not settled then return false, updated end
            settledBefore = updated
            local hint = args.targetHint
            if args.operation == U.OP_ADD_BATTERY
                or args.operation == U.OP_INSTALL_CHARGER
                or args.operation == U.OP_INSTALL_INVERTER then
                hint = args.sourceHint
            end
            accepted, detail = Power.handleIntent(identity, context, args.operation, hint)
        elseif args.operation == U.OP_REQUEST_SNAPSHOT then
            accepted, detail = true, { record = recordOrReason }
        else
            local hint = args.targetHint
            if args.operation == U.OP_ADD_BATTERY
                or args.operation == U.OP_INSTALL_CHARGER
                or args.operation == U.OP_INSTALL_INVERTER then
                hint = args.sourceHint
            end
            accepted, detail = Power.handleIntent(identity, context, args.operation,
                hint)
        end
        if accepted ~= true then
            if settledBefore then broadcastToRV(identity, settledBefore) end
            return false, detail
        end
        local appliedRecord = type(detail) == "table" and detail.record or nil
        broadcastToRV(identity, appliedRecord or recordOrReason)
        return true, detail
    end)
    local response = { ok = guardOk == true, result = guardOk and guardReason or nil,
        reason = guardOk and nil or guardReason }
    remember(session, args.requestId, response)
    acknowledge(player, args.requestId, guardOk, guardOk and guardReason or guardReason)
    return guardOk, guardOk and guardReason or guardReason
end

local function syncUtilityMappings()
    local rv = rawget(_G, "RailroaderRV")
    local adapter = rv and rv.RailroaderServer
    if not adapter or type(adapter.onlinePlayersSnapshot) ~= "function"
        or type(adapter.syncUtilityMapping) ~= "function" then
        return
    end
    local listOk, list = pcall(adapter.onlinePlayersSnapshot)
    if not listOk or type(list) ~= "table" then return end
    local epoch = adapter._mappingEpoch or 0
    local present = {}
    for i = 1, #list do
        local player = list[i]
        local recipientKey = playerKey(player)
        if recipientKey then
            present[recipientKey] = true
            local previous = mappingSyncState[recipientKey]
            if not previous or previous.player ~= player or previous.epoch ~= epoch then
                local syncOk, accepted, identity = pcall(adapter.syncUtilityMapping, player)
                if syncOk and accepted == true and type(identity) == "table" then
                    mappingSyncState[recipientKey] = { player = player, epoch = epoch }
                end
            end
        end
    end
    for recipientKey in pairs(mappingSyncState) do
        if not present[recipientKey] then mappingSyncState[recipientKey] = nil end
    end
end

function M.onTick(tick)
    if lastTick == tick then
        return
    end
    lastTick = tick
    if type(tick) == "number" and tick % 30 == 0 then syncUtilityMappings() end
    if type(tick) ~= "number" or tick % U.POWER.DEVICE_SCAN_INTERVAL_TICKS ~= 0
        or lastScanTick == tick then return end
    lastScanTick = tick
    forCurrentRecords(function(identity, record, mappingRecord)
        local started = Power.beginRuntime(identity, record)
        if started then Devices.scanTick(identity, mappingRecord, nil) end
    end)
end

function M.onEveryTenMinutes()
    forCurrentRecords(function(identity, record)
        local settled, updated = withGuard(identity, function()
            return Power.settleAndRefreshLoad(identity, nil, record)
        end)
        if settled and type(updated) == "table" then
            broadcastToRV(identity, updated)
        end
    end)
end

function M.onEveryHour()
    forCurrentRecords(function(identity, record)
        Power.maintainNativeProxy(identity, record)
    end)
end

function M.settleAndRefreshLoad(identity, player)
    local recordOk, record = Store.getRecord(identity, false)
    if not recordOk then return false, record end
    local settled, updated = withGuard(identity, function()
        return Power.settleAndRefreshLoad(identity, player, record)
    end)
    if settled and type(updated) == "table" then
        broadcastToRV(identity, updated)
    end
    return settled, updated
end

function M.snapshotForPlayer(player)
    local ok, context = resolveRV(player)
    if not ok then return false, context end
    local recordOk, record = Store.getRecord(context.identity, false)
    if not recordOk then return false, record end
    broadcast(context, record)
    return true, record
end

function M.validateGenerationUtilityState(identity)
    if type(Store.validateGenerationUtilityState) ~= "function" then
        return false, C.INVALID_RV_DATA
    end
    return Store.validateGenerationUtilityState(identity)
end

function M.initializeRecord(identity, context)
    print("[RailroaderRVTest] utility init begin rv=" .. tostring(identity and identity.rvId)
        .. " generation=" .. tostring(identity and identity.generation))
    local initialized, recordOrReason = Power.initializeRecord(identity, context)
    if not initialized then
        print("[RailroaderRVTest] utility init failed stage=power-init reason="
            .. tostring(recordOrReason))
        return false, recordOrReason
    end
    print("[RailroaderRVTest] utility init committed rv=" .. tostring(identity.rvId)
        .. " generation=" .. tostring(identity.generation))
    if context and context.player then broadcast(context, recordOrReason) end
    return true, recordOrReason
end

if Events and Events.EveryTenMinutes
    and type(Events.EveryTenMinutes.Add) == "function" then
    Events.EveryTenMinutes.Add(M.onEveryTenMinutes)
end
if Events and Events.EveryHours and type(Events.EveryHours.Add) == "function" then
    Events.EveryHours.Add(M.onEveryHour)
end

return M
