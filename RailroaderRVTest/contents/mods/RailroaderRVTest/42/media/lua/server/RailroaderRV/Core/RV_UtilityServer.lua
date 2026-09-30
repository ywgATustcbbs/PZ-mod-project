-- Utility protocol facade. RV_Server owns event registration and calls this
-- module for server-validated generator intents and mapping sync.
--
-- One client command is handled as one straight-line server transaction: the
-- Lua server executes handlers sequentially, so no per-RV lock, session nonce
-- or idempotency replay window is required.

local C = require("RailroaderRV/Common/RV_Constants")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local Store = require("RailroaderRV/Core/RV_UtilityStore")
local Power = require("RailroaderRV/Power/RV_UtilityPower")
local Devices = require("RailroaderRV/Power/RV_UtilityPowerDevices")
local Water = require("RailroaderRV/Water/RV_UtilityWater")
local Util = require("RailroaderRV/Common/RV_ServerUtil")
local Core = require("RailroaderRV/Core/RV_Server_Core")

local M = {}
local mappingSyncState = {}
local lastTick = nil
local lastScanTick = nil

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
        or Util.integer(identity.generation) == nil then
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
    if type(server.isWallReloadTransactionActive) == "function" then
        local ok, active = pcall(server.isWallReloadTransactionActive)
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
    local allowed = { requestId = true, operation = true,
        targetHint = true, sourceHint = true }
    for field in pairs(args) do if not allowed[field] then return false, U.REASONS.INVALID_REQUEST end end
    if not validText(args.requestId, U.MAX_REQUEST_ID_LENGTH)
        or not validText(args.operation, 64)
        or not validHint(args.targetHint) or not validHint(args.sourceHint) then
        return false, U.REASONS.INVALID_REQUEST
    end
    return true
end

local function knownOperation(operation)
    return operation == U.OP_ADD_FUEL or operation == U.OP_ADD_BATTERY
        or operation == U.OP_CONNECT_WATER_DEVICE
        or operation == U.OP_REMOVE_BATTERY or operation == U.OP_INSTALL_CHARGER
        or operation == U.OP_REMOVE_CHARGER or operation == U.OP_INSTALL_INVERTER
        or operation == U.OP_REMOVE_INVERTER or operation == U.OP_REFRESH_DEVICES
        or operation == U.OP_REQUEST_SNAPSHOT or operation == U.OP_START_GENERATOR
        or operation == U.OP_STOP_GENERATOR
end

local function acknowledge(player, requestId, accepted, result)
    local payload = { requestId = requestId, ok = accepted == true }
    if accepted then
        payload.reason = U.REASONS.OK
        -- Only the water answer carries a client-visible boolean.
        payload.connected = type(result) == "table" and result.connected or nil
    else
        payload.reason = stableReason(result)
    end
    send(player, C.COMMAND_RV_UTILITY_ACK, payload)
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
            and context.identity.generation == identity.generation then
            broadcast(context, record)
        end
    end
end

local function currentMappingRecord(identity)
    local rv = rawget(_G, "RailroaderRV")
    local adapter = rv and rv.RailroaderServer
    local accepted, record = adapter.currentUtilityRecord(identity)
    if accepted ~= true then
        return false, C.INVALID_RV_DATA
    end
    return true, record
end

local function forCurrentRecords(callback)
    local _, entries = Store.allRecords()
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
    local operation = args.operation
    if not knownOperation(operation) then return false, U.REASONS.INVALID_REQUEST end
    if serviceBusy() then
        acknowledge(player, args.requestId, false, U.REASONS.BUSY)
        return false, U.REASONS.BUSY
    end
    local rvOk, contextOrReason = resolveRV(player)
    if not rvOk then
        acknowledge(player, args.requestId, false, contextOrReason)
        return false, contextOrReason
    end
    local context = contextOrReason
    if context.phase ~= "READY" then
        acknowledge(player, args.requestId, false, U.REASONS.PERMISSION)
        return false, U.REASONS.PERMISSION
    end
    local identity = context.identity
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then
        acknowledge(player, args.requestId, false, recordOrReason)
        return false, recordOrReason
    end
    if operation == U.OP_REQUEST_SNAPSHOT then
        -- A snapshot only reads current state: answer it directly.
        broadcast(context, recordOrReason)
        return true, { record = recordOrReason }
    end

    local settledBefore = nil
    local accepted, detail
    if operation == U.OP_CONNECT_WATER_DEVICE then
        accepted, detail = Water.setConnection(identity, context,
            args.targetHint, recordOrReason)
    elseif operation == U.OP_ADD_FUEL then
        local settled, updated = Power.settleAndRefreshLoad(identity,
            context.player, recordOrReason)
        if not settled then
            acknowledge(player, args.requestId, false, updated)
            return false, updated
        end
        settledBefore = updated
        accepted, detail = Power.addFuel(identity, context, args.sourceHint)
    elseif operation == U.OP_REFRESH_DEVICES then
        local settled, updated = Power.settleAndRefreshLoad(identity,
            context.player, recordOrReason)
        if not settled then
            acknowledge(player, args.requestId, false, updated)
            return false, updated
        end
        local scanned, scanReason = Devices.scanAll(identity, context.record,
            context.player)
        if not scanned then
            acknowledge(player, args.requestId, false, scanReason)
            return false, scanReason
        end
        local settledAgain, settledRecord = Power.settleAndRefreshLoad(identity,
            context.player)
        accepted, detail = settledAgain, settledAgain and { record = settledRecord }
            or settledRecord
    elseif operation == U.OP_ADD_BATTERY or operation == U.OP_REMOVE_BATTERY
        or operation == U.OP_INSTALL_CHARGER or operation == U.OP_REMOVE_CHARGER
        or operation == U.OP_INSTALL_INVERTER or operation == U.OP_REMOVE_INVERTER then
        -- Battery, charger and inverter operations settle the load first.
        local settled, updated = Power.settleAndRefreshLoad(identity,
            context.player, recordOrReason)
        if not settled then
            acknowledge(player, args.requestId, false, updated)
            return false, updated
        end
        settledBefore = updated
        local hint = args.targetHint
        if operation == U.OP_ADD_BATTERY or operation == U.OP_INSTALL_CHARGER
            or operation == U.OP_INSTALL_INVERTER then
            hint = args.sourceHint
        end
        accepted, detail = Power.handleIntent(identity, context, operation, hint)
    else
        -- Generator start/stop settles the load inside the intent handler.
        accepted, detail = Power.handleIntent(identity, context, operation,
            args.targetHint)
    end
    if accepted ~= true then
        if settledBefore then broadcastToRV(identity, settledBefore) end
        acknowledge(player, args.requestId, false, detail)
        return false, detail
    end
    local appliedRecord = type(detail) == "table" and detail.record or nil
    broadcastToRV(identity, appliedRecord or recordOrReason)
    acknowledge(player, args.requestId, true, detail)
    return true, detail
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
    if type(adapter.currentMappingEpoch) ~= "function" then return end
    local epoch = adapter.currentMappingEpoch()
    if type(epoch) ~= "number" then return end
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
    if type(tick) ~= "number" then return end
    if lastTick == tick then
        return
    end
    lastTick = tick
    if Core.tickModulo(30) then syncUtilityMappings() end
    if not Core.tickModulo(U.POWER.DEVICE_SCAN_INTERVAL_TICKS)
        or lastScanTick == tick then return end
    lastScanTick = tick
    forCurrentRecords(function(identity, record, mappingRecord)
        local started = Power.ensureRuntime(identity, record)
        if started then Devices.scanTick(identity, mappingRecord, nil) end
    end)
end

function M.onEveryTenMinutes()
    forCurrentRecords(function(identity, record)
        local settled, updated = Power.settleAndRefreshLoad(identity, nil, record)
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
    local settled, updated = Power.settleAndRefreshLoad(identity, player, record)
    if settled and type(updated) == "table" then
        broadcastToRV(identity, updated)
    end
    return settled, updated
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
