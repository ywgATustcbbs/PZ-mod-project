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
local Water = require("RailroaderRV/Water/RV_UtilityWater")
local WaterConstants = Water.CONSTANTS
local RoofServer = require("RailroaderRV/Roof/RV_Server_RoofDevices")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local Util = require("RailroaderRV/Common/RV_ServerUtil")
local Core = require("RailroaderRV/Core/RV_Server_Core")
require("TimedActions/ISRVUtilityAction")

local M = {}
local mappingSyncState = {}
local lastTick = nil

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

local function resolveRV(player, operation, phase)
    local server = RailroaderRV.Server
    local diagnosticOperation = operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE
        and operation or nil
    local accepted, context = server.resolveCurrentUtilityRV(player,
        diagnosticOperation, phase)
    if accepted ~= true then return false, stableReason(context) end
    context.player = player
    return true, context
end

local function serviceBusy(identity)
    local server = RailroaderRV.Server
    return server.isGenerationTransactionActiveForRV(identity.rvId) == true
        or server.isWallReloadTransactionActive(identity.rvId) == true
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
    local allowed = { operation = true, targetHint = true, sourceHint = true }
    for field in pairs(args) do if not allowed[field] then return false, U.REASONS.INVALID_REQUEST end end
    if not validText(args.operation, 64)
        or not validHint(args.targetHint) or not validHint(args.sourceHint) then
        return false, U.REASONS.INVALID_REQUEST
    end
    return true
end

local function knownOperation(operation)
    return operation == U.OP_CONNECT_WATER_DEVICE
        or operation == U.OP_REFRESH_DEVICES
        or operation == U.OP_REQUEST_SNAPSHOT
        or operation == U.OP_START_GENERATOR
        or operation == U.OP_STOP_GENERATOR
        or operation == U.OP_OPEN_CIRCUIT_BREAKER
        or operation == U.OP_CLOSE_CIRCUIT_BREAKER
end

local function acknowledge(player, accepted, result)
    local payload = { ok = accepted == true }
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
    payload.templateId = context.record.templateId
    payload.roofDevices = RoofServer.devices(record)
    send(context.player, C.COMMAND_RV_UTILITY_SNAPSHOT, payload)
end

local function broadcastToRV(identity, record)
    local players = RailroaderRV.RailroaderServer.onlinePlayersSnapshot()
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
    local entries = Store.allRecords()
    for i = 1, #entries do
        local entry = entries[i]
        local identity = entry.identity
        local mappingOk, mappingRecord = currentMappingRecord(identity)
        if mappingOk then callback(identity, entry.record, mappingRecord) end
    end
end

local function actionContext(player, operation, phase)
    local accepted, contextOrReason = resolveRV(player, operation, phase)
    if not accepted then return false, contextOrReason end
    local context = contextOrReason
    if serviceBusy(context.identity) then
        return false, U.REASONS.BUSY, context
    end
    if context.phase ~= "READY" then
        return false, U.REASONS.PERMISSION, context
    end
    return true, context
end

local function logWaterDrawReject(phase, reason, context)
    print("[RailroaderRV] water draw rejected operation="
        .. WaterConstants.OP_DRAW_WATER_FROM_SOURCE
        .. " entry=timed-action phase=" .. phase
        .. " reason=" .. tostring(reason)
        .. " side=" .. tostring(context.locomotiveSide)
        .. " role=" .. tostring(context.locomotiveRole)
        .. " seat=" .. tostring(context.locomotiveSeat))
end

local function waterActionContext(player, operation, phase)
    local contextOk, contextOrReason, rejectedContext = actionContext(player,
        operation, phase)
    if not contextOk then
        if operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE
            and rejectedContext then
            logWaterDrawReject(phase, contextOrReason, rejectedContext)
        end
        return false, contextOrReason
    end
    local context = contextOrReason
    if operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
        if context.locomotiveSide ~= true
            or context.locomotiveRole ~= "external" then
            logWaterDrawReject(phase, U.REASONS.PERMISSION, context)
            return false, U.REASONS.PERMISSION
        end
    end
    return true, context
end

local function validateWaterTransfer(context, operation, item, sourceHint)
    local record = Store.getRecord(context.identity, false)
    if operation == WaterConstants.OP_ADD_WATER_FROM_CONTAINER then
        if not item then return false, U.REASONS.SOURCE_INVALID end
        return Water.validateContainerSource(context.player, item:getID(), record)
    end
    if operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
        return Water.validateDrawSource(context.player, sourceHint, record)
    end
    return false, U.REASONS.INVALID_REQUEST
end

function M.settleUtilities(identity, mappingRecord, waterIntent, player,
        providedRecord, action)
    local powerState = Power.settlePower(identity, mappingRecord, player,
        providedRecord, action)
    local waterRecord = Water.settleWater(identity, mappingRecord, waterIntent,
        powerState)
    return true, waterRecord, powerState
end

local function isRoofAction(operation)
    return operation == U.OP_INSTALL_ROOF_DEVICE
        or operation == U.OP_REMOVE_ROOF_DEVICE
end

local function actionHint(targetHint, item)
    local hint = {}
    if type(targetHint) == "table" then
        for key, value in pairs(targetHint) do hint[key] = value end
    end
    if item then hint.itemId = item:getID() end
    return hint
end

function M.validateTimedAction(player, operation, item, targetHint)
    if Water.isTimedActionOperation(operation) then
        if Water.isPartsOperation(operation) then
            local contextOk = actionContext(player)
            return contextOk
        end
        local contextOk, context = waterActionContext(player, operation,
            "validate")
        if not contextOk then return false end
        local valid, reason = validateWaterTransfer(context, operation, item,
            targetHint)
        if valid ~= true
            and operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
            logWaterDrawReject("validate-source", reason, context)
        end
        return valid == true
    end
    local timedOperation = operation == U.OP_ADD_FUEL
        or operation == U.OP_INSTALL_ROOF_DEVICE
        or operation == U.OP_REMOVE_ROOF_DEVICE
        or operation == U.OP_ADD_FUEL_TANK or operation == U.OP_REMOVE_FUEL_TANK
        or operation == U.OP_ADD_BATTERY or operation == U.OP_REMOVE_BATTERY
        or operation == U.OP_INSTALL_CHARGER or operation == U.OP_REMOVE_CHARGER
        or operation == U.OP_INSTALL_INVERTER or operation == U.OP_REMOVE_INVERTER
        or operation == U.OP_INSTALL_CONTROLLER or operation == U.OP_REMOVE_CONTROLLER
        or operation == U.OP_INSTALL_CIRCUIT_BREAKER
        or operation == U.OP_REMOVE_CIRCUIT_BREAKER
    if not timedOperation then return false end
    local contextOk, contextOrReason = actionContext(player)
    if not contextOk then return false end
    if operation == U.OP_ADD_FUEL then
        local accepted = Power.fuelActionCapacity(contextOrReason.identity,
            contextOrReason, item)
        return accepted
    end
    return true
end

function M.beginFuelTimedAction(player, item)
    local contextOk, contextOrReason = actionContext(player)
    if not contextOk then return false, contextOrReason end
    local context = contextOrReason
    M.settleUtilities(context.identity, context.record,
        nil, player)
    return Power.fuelActionCapacity(context.identity, context, item)
end

function M.progressFuelTimedAction(player, item, amount)
    local contextOk, contextOrReason = actionContext(player)
    if not contextOk then return false, contextOrReason end
    local context = contextOrReason
    M.settleUtilities(context.identity, context.record,
        nil, player)
    local accepted, detail = Power.addFuel(context.identity, context, item,
        amount)
    if not accepted then return false, detail end
    local _, refreshedRecord = M.settleUtilities(context.identity,
        context.record, nil, player, detail.record)
    broadcastToRV(context.identity, refreshedRecord)
    return true, { record = refreshedRecord }
end

function M.finishFuelTimedAction(player)
    local contextOk, context = actionContext(player)
    if not contextOk then return false end
    local _, record = M.settleUtilities(context.identity, context.record,
        nil, player)
    broadcastToRV(context.identity, record)
    return true
end

local function extractionPumpWatts(water)
    if water.extractionPump == "small" then
        return WaterConstants.SMALL_PUMP_WATTS
    end
    if water.extractionPump == "industrial" then
        return WaterConstants.INDUSTRIAL_PUMP_WATTS
    end
    if water.extractionPump == nil then
        error("RailroaderRV: draw action has no installed extraction pump")
    end
    error("RailroaderRV: unknown installed water extraction pump")
end

local function settleWaterActionWithoutIntent(action)
    local identity = action.serverWaterIdentity
    local mappingOk, mappingRecord = currentMappingRecord(identity)
    if not mappingOk then return false end
    local _, record = M.settleUtilities(identity, mappingRecord, nil,
        nil, nil, action)
    return true, record
end

local function endWaterTimedAction(action, settlementDone, record)
    if action.serverWaterEnded then return false end
    local recordAvailable = settlementDone
    if not settlementDone then
        recordAvailable, record = settleWaterActionWithoutIntent(action)
    end
    if action.operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE
        and action.serverWaterStarted then
        Power.clearPump(action.serverWaterIdentity, action)
    end
    action.serverWaterInvalid = true
    action.serverWaterEnded = true
    if recordAvailable then broadcastToRV(action.serverWaterIdentity, record) end
    action.netAction:forceComplete()
    return false
end

function M.beginWaterTimedAction(action)
    local player = action.character
    local contextOk, contextOrReason = waterActionContext(player,
        action.operation, "begin")
    if not contextOk then return false, contextOrReason end
    local context = contextOrReason
    local _, record, powerState = M.settleUtilities(context.identity,
        context.record, nil, player)
    if not powerState.supplyPumpPowered then
        if action.operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
            logWaterDrawReject("begin-power", U.REASONS.PERMISSION, context)
        end
        return false, U.REASONS.PERMISSION
    end
    local sourceOk, sourceReason = validateWaterTransfer(context,
        action.operation, action.item, action.targetHint)
    if not sourceOk then
        if action.operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
            logWaterDrawReject("begin-source", sourceReason, context)
        end
        return false, sourceReason
    end

    action.serverWaterIdentity = context.identity
    action.serverWaterLastMs = getTimestampMs()
    action.serverWaterStarted = true
    if action.operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
        Power.markPumpRunning(context.identity, action,
            extractionPumpWatts(record.water))
    end
    return true
end

function M.progressWaterTimedAction(action, deferBroadcast)
    if action.serverWaterInvalid or action.serverWaterEnded then return false end
    local player = action.character
    local contextOk, contextOrReason = waterActionContext(player,
        action.operation, deferBroadcast and "finish" or "progress")
    if not contextOk then return endWaterTimedAction(action) end
    local context = contextOrReason
    if tostring(context.identity.rvId)
            ~= tostring(action.serverWaterIdentity.rvId)
        or context.identity.generation
            ~= action.serverWaterIdentity.generation then
        if action.operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
            logWaterDrawReject(deferBroadcast and "finish" or "progress",
                "rv-context-changed", context)
        end
        return endWaterTimedAction(action)
    end
    local sourceOk, sourceReason = validateWaterTransfer(context, action.operation,
        action.item, action.targetHint)
    if not sourceOk then
        if action.operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
            logWaterDrawReject(deferBroadcast and "finish-source" or "progress-source",
                sourceReason, context)
        end
        return endWaterTimedAction(action)
    end

    local nowMs = getTimestampMs()
    local elapsedMs = nowMs - action.serverWaterLastMs
    assert(elapsedMs >= 0,
        "RV water action server clock moved backwards")
    action.serverWaterLastMs = nowMs
    local intent
    if action.operation == WaterConstants.OP_ADD_WATER_FROM_CONTAINER then
        intent = { kind = "container", player = player,
            itemId = action.item:getID(), serverElapsedMs = elapsedMs }
    elseif action.operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
        Power.markPumpRunning(context.identity, action,
            extractionPumpWatts(Store.getRecord(context.identity, false).water))
        intent = { kind = "draw", player = player,
            sourceHint = action.targetHint, serverElapsedMs = elapsedMs }
    else
        error("RailroaderRV: invalid water transfer action")
    end

    local _, record, powerState = M.settleUtilities(context.identity,
        context.record, intent, player, nil, action)
    local transferAllowed = powerState.supplyPumpPowered
    if action.operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
        transferAllowed = transferAllowed and powerState.extractionPumpRunning
    end
    if not transferAllowed then
        if action.operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
            logWaterDrawReject(deferBroadcast and "finish-power" or "progress-power",
                U.REASONS.PERMISSION, context)
        end
        return endWaterTimedAction(action, true, record)
    end

    local remainsValid, remainingReason = validateWaterTransfer(context,
        action.operation, action.item, action.targetHint)
    if not remainsValid then
        if action.operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
            logWaterDrawReject(deferBroadcast and "finish-source" or "progress-source",
                remainingReason, context)
        end
        return endWaterTimedAction(action, true, record)
    end
    if not deferBroadcast then broadcastToRV(context.identity, record) end
    return true, record
end

function M.finishWaterTimedAction(action)
    if not action.serverWaterStarted or action.serverWaterEnded then
        return action.serverWaterEnded ~= true
    end
    local continued, record = M.progressWaterTimedAction(action, true)
    if continued and not action.serverWaterEnded then
        if action.operation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
            Power.clearPump(action.serverWaterIdentity, action)
        end
        action.serverWaterEnded = true
        broadcastToRV(action.serverWaterIdentity, record)
        return true
    end
    return false
end

function M.performTimedAction(player, operation, targetHint, item)
    local resolved, contextOrReason = resolveRV(player)
    if not resolved then return false, contextOrReason end
    local context = contextOrReason
    local identity = context.identity
    local persistedRecord = Store.getRecord(identity, false)
    local function reject(reason, record)
        broadcastToRV(identity, record or Store.getRecord(identity, false))
        return false, reason
    end
    if serviceBusy(identity) then
        return reject(U.REASONS.BUSY)
    end
    if context.phase ~= "READY" then
        return reject(U.REASONS.PERMISSION)
    end
    local _, beforeMutation = M.settleUtilities(identity,
        context.record, nil, player, persistedRecord)
    local candidateRecord = Store.copyRecord(beforeMutation)
    local accepted, detail
    if isRoofAction(operation) then
        accepted, detail = RoofServer.performAction(context, operation,
            targetHint, item, candidateRecord)
    elseif Water.isPartsOperation(operation) then
        local hint = actionHint(targetHint, item)
        accepted, detail = Water.performPartsAction(context, operation,
            hint.itemId, candidateRecord)
    else
        accepted, detail = Power.handleIntent(context, operation,
            actionHint(targetHint, item), candidateRecord)
    end
    if not accepted then return reject(detail, beforeMutation) end

    local _, refreshedRecord = M.settleUtilities(identity,
        context.record, nil, player, detail.record)
    if detail.transaction then detail.transaction:commit() end
    detail.record = refreshedRecord
    detail.transaction = nil
    broadcastToRV(identity, detail.record)
    return true, detail
end

function M.handleCommand(player, args)
    local requestOk, requestReason = validRequest(args)
    if not requestOk then return false, requestReason end
    local operation = args.operation
    if not knownOperation(operation) then return false, U.REASONS.INVALID_REQUEST end
    local rvOk, contextOrReason = resolveRV(player)
    if not rvOk then
        acknowledge(player, false, contextOrReason)
        return false, contextOrReason
    end
    local context = contextOrReason
    if serviceBusy(context.identity) then
        acknowledge(player, false, U.REASONS.BUSY)
        return false, U.REASONS.BUSY
    end
    if context.phase ~= "READY" then
        acknowledge(player, false, U.REASONS.PERMISSION)
        return false, U.REASONS.PERMISSION
    end
    local identity = context.identity
    local recordOrReason = Store.getRecord(identity, false)
    local _, updated = M.settleUtilities(identity, context.record, nil,
        context.player, recordOrReason)
    recordOrReason = updated

    if operation == U.OP_REQUEST_SNAPSHOT then
        broadcast(context, recordOrReason)
        return true, { record = recordOrReason }
    end

    local accepted, detail
    if operation == U.OP_CONNECT_WATER_DEVICE then
        accepted, detail = Water.setConnection(identity, context,
            args.targetHint, recordOrReason)
    elseif operation == U.OP_REFRESH_DEVICES then
        accepted, detail = true, { record = recordOrReason }
    else
        accepted, detail = Power.handleIntent(context, operation,
            args.targetHint, recordOrReason)
    end
    if accepted and operation ~= U.OP_REFRESH_DEVICES then
        local _, refreshedRecord = M.settleUtilities(identity,
            context.record, nil, context.player, detail.record)
        detail.record = refreshedRecord
    end
    if accepted ~= true then
        broadcastToRV(identity, recordOrReason)
        acknowledge(player, false, detail)
        return false, detail
    end
    local appliedRecord = detail.record
    broadcastToRV(identity, appliedRecord)
    acknowledge(player, true, detail)
    return true, detail
end

local function syncUtilityMappings()
    local adapter = RailroaderRV.RailroaderServer
    local list, snapshotOk = adapter.onlinePlayersSnapshot()
    if not snapshotOk then return end
    local epoch = adapter.currentMappingEpoch()
    local present = {}
    for i = 1, #list do
        local player = list[i]
        local recipientKey = playerKey(player)
        if recipientKey then
            present[recipientKey] = true
            local previous = mappingSyncState[recipientKey]
            local sameRecipient = previous ~= nil
                and previous.player == player and previous.epoch == epoch
            local accepted, identity = adapter.syncUtilityMapping(player,
                sameRecipient and previous.identity or nil)
            if accepted == true then
                mappingSyncState[recipientKey] = {
                    player = player, epoch = epoch,
                    identity = identity,
                }
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
    if Core.tickModulo(30) then syncUtilityMappings() end
end

function M.onEveryTenMinutes()
    local climate = getClimateManager()
    local waterIntent = {
        kind = "collectAuto",
        precipitationIntensity = climate:getPrecipitationIntensity(),
        isSnow = climate:getPrecipitationIsSnow(),
    }
    forCurrentRecords(function(identity, record, mappingRecord)
        local _, updated = M.settleUtilities(identity, mappingRecord,
            waterIntent, nil, record)
        broadcastToRV(identity, updated)
    end)
end

function M.onEveryHour()
    forCurrentRecords(function(identity, record, mappingRecord)
        Power.maintainNativeProxy(identity, record, mappingRecord)
    end)
end

function M.settleAndRefreshLoad(identity, player, mappingRecord)
    local record = Store.getRecord(identity, false)
    local _, updated = M.settleUtilities(identity, mappingRecord, nil,
        player, record)
    broadcastToRV(identity, updated)
    return true, updated
end

function M.initializeRecord(identity, context)
    local initialized, recordOrReason = Power.initializeRecord(identity, context)
    if not initialized then
        print("[RailroaderRV] utility init failed stage=power-init reason="
            .. tostring(recordOrReason))
        return false, recordOrReason
    end
    local template = RoomTemplate.get(context.record.templateId)
    Water.initializeRecord(recordOrReason,
        RoomTemplate.waterProxies(template))
    Store.commit(recordOrReason, identity)
    local _, settledRecord = M.settleUtilities(identity, context.record,
        nil, context.player, recordOrReason)
    if context and context.player then broadcast(context, settledRecord) end
    return true, settledRecord
end

if Events and Events.EveryTenMinutes
    and type(Events.EveryTenMinutes.Add) == "function" then
    Events.EveryTenMinutes.Add(M.onEveryTenMinutes)
end
if Events and Events.EveryHours and type(Events.EveryHours.Add) == "function" then
    Events.EveryHours.Add(M.onEveryHour)
end

return M
