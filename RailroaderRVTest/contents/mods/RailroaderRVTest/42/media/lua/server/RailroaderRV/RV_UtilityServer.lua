-- Utility protocol facade. RV_Server owns event registration and calls this
-- module for server-validated generator intents and mapping sync.

local C = require("RailroaderRV/RV_Constants")
local U = require("RailroaderRV/RV_UtilityConstants")
local Store = require("RailroaderRV/RV_UtilityStore")
local Power = require("RailroaderRV/RV_UtilityPower")
local Util = require("RailroaderRV/RV_ServerUtil")

local M = {}
local locks = {}
local sessions = {}
local mappingSyncState = {}
local lastTick = -1

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
    if type(server.isRoofRepairTransactionActive) == "function" then
        local ok, active = pcall(server.isRoofRepairTransactionActive)
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
    return operation == U.OP_ADD_FUEL or operation == U.OP_REQUEST_SNAPSHOT
        or operation == U.OP_CONNECT_GENERATOR or operation == U.OP_START_GENERATOR
        or operation == U.OP_STOP_GENERATOR or operation == U.OP_REPAIR_GENERATOR
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
        local accepted, detail
        if args.operation == U.OP_ADD_FUEL then
            accepted, detail = Power.addFuel(identity, context, args.sourceHint)
        elseif args.operation == U.OP_REQUEST_SNAPSHOT then
            accepted, detail = true, { record = recordOrReason }
        else
            accepted, detail = Power.handleIntent(identity, context, args.operation,
                args.targetHint)
        end
        if accepted ~= true then return false, detail end
        local appliedRecord = type(detail) == "table" and detail.record or nil
        broadcast(context, appliedRecord or recordOrReason)
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
    local recordOk, recordOrReason = Store.getRecord(identity, true)
    if not recordOk then
        print("[RailroaderRVTest] utility init failed stage=get-record reason="
            .. tostring(recordOrReason))
        return false, recordOrReason
    end
    local committed, commitReason = Store.commit(recordOrReason, identity)
    if not committed then
        print("[RailroaderRVTest] utility init failed stage=commit reason="
            .. tostring(commitReason))
        return false, commitReason
    end
    print("[RailroaderRVTest] utility init committed rv=" .. tostring(identity.rvId)
        .. " generation=" .. tostring(identity.generation))
    if context and context.player then broadcast(context, recordOrReason) end
    return true, recordOrReason
end

return M
