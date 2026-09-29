-- Client intent transport and read-only utility snapshot cache.
--
-- This module never writes a FluidContainer, registry, generator, or world
-- coordinate.  It sends only operation intent plus a server-revalidated hint.

require("RailroaderRV/Common/RV_Constants")
-- Register the same isolated sprite used by the server before hidden native
-- generator objects arrive in complete-object packets.
local UtilitySprite = require("RailroaderRV/Common/RV_UtilitySprite")
local hiddenSpritesReady, _, hiddenSpriteReason = UtilitySprite.install()
if not hiddenSpritesReady then
    error("RailroaderRVTest: client hidden sprite registration failed: "
        .. tostring(hiddenSpriteReason))
end
local U = require("RailroaderRV/Common/RV_UtilityConstants")

RailroaderRV = RailroaderRV or {}
RailroaderRV.UtilityClient = RailroaderRV.UtilityClient or {}
local Client = RailroaderRV.UtilityClient
local C = RailroaderRV.Constants

local requestSequence = 0
local sessionNonce
local pendingRequests = {}
local ACK_TIMEOUT_SECONDS = 15
Client.snapshot = nil

function Client.clearConnectionState()
    requestSequence = 0
    sessionNonce = nil
    pendingRequests = {}
    Client.snapshot = nil
    local rv = rawget(_G, "RailroaderRV")
    local menu = rv and rv.RailroaderContextMenu
    if menu and type(menu.clearUtilityMapping) == "function" then
        pcall(menu.clearUtilityMapping)
    end
    local dashboard = rv and rv.UtilityDashboard
    if dashboard and type(dashboard.onConnectionReset) == "function" then
        pcall(dashboard.onConnectionReset)
    end
end

local function finite(value)
    return type(value) == "number"
end

local function nowSeconds()
    local ok, value = pcall(os.time)
    return ok and finite(value) and value or nil
end

local function text(key, fallback)
    if type(getText) == "function" then
        local ok, value = pcall(getText, key)
        if ok and type(value) == "string" and value ~= "" and value ~= key then
            return value
        end
    end
    return fallback
end

function Client.showFeedback(player, message)
    if not player or type(player.setHaloNote) ~= "function" then return false end
    local ok = pcall(player.setHaloNote, player, tostring(message), 255, 255, 255, 5000)
    return ok
end

local function rejectSend(player)
    local dashboard = RailroaderRV.UtilityDashboard
    local shown = false
    if dashboard and type(dashboard.onSendFailure) == "function" then
        local ok, accepted = pcall(dashboard.onSendFailure, player)
        shown = ok and accepted == true
    end
    if not shown then
        Client.showFeedback(player, text("UI_RailroaderRVTest_Utility_SendFailed",
            "Utility request could not be sent"))
    end
    return false, nil
end

local function newNonce()
    local timestamp = os.time()
    local random = 0
    if type(ZombRand) == "function" then
        local ok, value = pcall(ZombRand, 1000000)
        if ok and finite(value) then random = value end
    end
    return tostring(timestamp) .. ":" .. tostring(random)
end

local function localPlayer(playerNum)
    if type(getSpecificPlayer) ~= "function" then return nil end
    local ok, player = pcall(getSpecificPlayer, playerNum)
    return ok and player or nil
end

local function nextRequestId()
    requestSequence = requestSequence + 1
    return tostring(sessionNonce) .. ":" .. tostring(requestSequence)
end

local function hintForObject(object)
    if not object or type(object.getSquare) ~= "function"
        or type(object.getObjectIndex) ~= "function" then return nil end
    local okSquare, square = pcall(function() return object:getSquare() end)
    if not okSquare or not square then return nil end
    local okX, x = pcall(function() return square:getX() end)
    local okY, y = pcall(function() return square:getY() end)
    local okZ, z = pcall(function() return square:getZ() end)
    local okIndex, index = pcall(function() return object:getObjectIndex() end)
    if not okX or not okY or not okZ or not okIndex then return nil end
    return { x = x, y = y, z = z, objectIndex = index }
end

local function hintForItem(item)
    if not item or type(item.getID) ~= "function" then return nil end
    local ok, id = pcall(function() return item:getID() end)
    return ok and id ~= nil and { itemId = id } or nil
end

function Client.ensureSession()
    if not sessionNonce then sessionNonce = newNonce() end
    return sessionNonce
end

function Client.send(player, operation, targetHint, sourceHint)
    if not player or type(sendClientCommand) ~= "function" then
        return rejectSend(player)
    end
    Client.ensureSession()
    local requestId = nextRequestId()
    local payload = { requestId = requestId, sessionNonce = sessionNonce,
        operation = operation }
    if targetHint ~= nil then payload.targetHint = targetHint end
    if sourceHint ~= nil then payload.sourceHint = sourceHint end
    local ok, result = pcall(sendClientCommand, player, C.MOD_ID,
        C.COMMAND_RV_UTILITY, payload)
    local sent = ok and result ~= false
    if sent then
        pendingRequests[requestId] = { player = player, operation = operation,
            sentAt = nowSeconds() }
        local dashboard = RailroaderRV.UtilityDashboard
        local shown = false
        if dashboard and type(dashboard.onRequestSent) == "function" then
            local callbackOk, accepted = pcall(dashboard.onRequestSent,
                player, requestId, operation)
            shown = callbackOk and accepted == true
        end
        if not shown then
            Client.showFeedback(player, text("UI_RailroaderRVTest_Utility_Submitted",
                "Utility request sent; waiting for server"))
        end
        return true, requestId
    end
    return rejectSend(player)
end

function Client.requestAddFuel(player, item)
    local hint = hintForItem(item)
    if not hint then return false, nil end
    return Client.send(player, U.OP_ADD_FUEL, nil, hint)
end

function Client.requestAddBattery(player, item)
    local hint = hintForItem(item)
    if not hint then return false, nil end
    return Client.send(player, U.OP_ADD_BATTERY, nil, hint)
end

function Client.requestInstallComponent(player, operation, item)
    local hint = hintForItem(item)
    if not hint then return false, nil end
    return Client.send(player, operation, nil, hint)
end

function Client.requestRemoveBattery(player, batteryId)
    return Client.send(player, U.OP_REMOVE_BATTERY,
        { batteryId = batteryId }, nil)
end

function Client.requestPowerOperation(player, operation)
    return Client.send(player, operation, nil, nil)
end

function Client.requestRefreshDevices(player)
    return Client.send(player, U.OP_REFRESH_DEVICES, nil, nil)
end

function Client.requestSnapshot(player)
    return Client.send(player, U.OP_REQUEST_SNAPSHOT, nil, nil)
end

function Client.requestGenerator(player, operation, object)
    local hint = hintForObject(object)
    if not hint then return false, nil end
    return Client.send(player, operation, hint, nil)
end

function Client.requestWaterConnection(player, object, connected)
    if type(connected) ~= "boolean" then
        return rejectSend(player)
    end
    local hint = hintForObject(object)
    if not hint then
        return rejectSend(player)
    end
    hint.connected = connected
    return Client.send(player, U.OP_CONNECT_WATER_DEVICE, hint, nil)
end

function Client.isRequestPending(requestId)
    return type(requestId) == "string" and pendingRequests[requestId] ~= nil
end

local function notifyRequestTimeout(requestId, request)
    local dashboard = RailroaderRV.UtilityDashboard
    local shown = false
    if dashboard and type(dashboard.onTimeout) == "function" then
        local ok, accepted = pcall(dashboard.onTimeout, request.player,
            requestId, request.operation)
        shown = ok and accepted == true
    end
    if not shown then
        Client.showFeedback(request.player, text(
            "UI_RailroaderRVTest_Utility_AckTimeout",
            "No server response. The operation may still have completed."))
    end
end

function Client.onTick()
    local now = nowSeconds()
    if now == nil then return end
    for requestId, request in pairs(pendingRequests) do
        if type(request.sentAt) == "number"
            and now - request.sentAt >= ACK_TIMEOUT_SECONDS then
            pendingRequests[requestId] = nil
            notifyRequestTimeout(requestId, request)
        end
    end
end

local function showInvalidRVData(player)
    if player and type(player.setHaloNote) == "function" then
        local message = "RV data is invalid. Delete this test save and recreate it."
        if type(getText) == "function" then
            local ok, translated = pcall(getText,
                "UI_RailroaderRVTest_InvalidRVData")
            if ok and type(translated) == "string" and translated ~= ""
                and translated ~= "UI_RailroaderRVTest_InvalidRVData" then
                message = translated
            end
        end
        pcall(function()
            player:setHaloNote(message, 255, 255, 255, 5000)
        end)
    end
end

function Client.showInvalidRVData(player)
    showInvalidRVData(player or localPlayer(0))
end

function Client.onServerCommand(module, command, args)
    if module ~= C.MOD_ID or type(args) ~= "table" then return end
    if command == C.COMMAND_RV_UTILITY_MAPPING then
        local rv = rawget(_G, "RailroaderRV")
        local menu = rv and rv.RailroaderContextMenu
        if menu and type(menu.acceptUtilityMapping) == "function" then
            pcall(menu.acceptUtilityMapping, args)
        end
        return
    end
    if command == C.COMMAND_RV_UTILITY_SNAPSHOT then
        -- The snapshot is display state only.  No value from it is ever sent
        -- back as a trusted amount, capacity, profile, or registry mutation.
        Client.snapshot = args
        local dashboard = RailroaderRV.UtilityDashboard
        if dashboard and type(dashboard.onSnapshot) == "function" then
            pcall(dashboard.onSnapshot, localPlayer(0), args)
        end
        return
    end
    if command ~= C.COMMAND_RV_UTILITY_ACK then return end
    local request = type(args.requestId) == "string"
        and pendingRequests[args.requestId] or nil
    local player = localPlayer(0)
    if not request or request.player ~= player then return end
    pendingRequests[args.requestId] = nil
    local dashboard = RailroaderRV.UtilityDashboard
    local displayed = false
    if dashboard and type(dashboard.onAck) == "function" then
        local ok, accepted = pcall(dashboard.onAck, player, args, request)
        displayed = ok and accepted == true
    end
    if not displayed then
        local message
        if args.ok == true and request.operation == U.OP_CONNECT_WATER_DEVICE then
            message = args.connected == true
                and text("UI_RailroaderRVTest_Utility_WaterConnectedAck",
                    "Sink connected to water")
                or text("UI_RailroaderRVTest_Utility_WaterDisconnectedAck",
                    "Sink disconnected from water")
        elseif args.ok == true then
            message = text("UI_RailroaderRVTest_Utility_Confirmed", "Operation confirmed")
        else
            message = text("UI_RailroaderRVTest_Utility_Rejected", "Operation rejected")
                .. ": " .. tostring(args.reason or "unknown")
        end
        Client.showFeedback(request.player, message)
    end
    if args.reason == U.REASON_INVALID_RV_DATA then
        Client.showInvalidRVData(localPlayer(0))
    end
end

Client.getSnapshot = function() return Client.snapshot end

if Events and Events.OnServerCommand and type(Events.OnServerCommand.Add) == "function" then
    Events.OnServerCommand.Add(Client.onServerCommand)
end
if Events and Events.OnConnected and type(Events.OnConnected.Add) == "function" then
    Events.OnConnected.Add(Client.clearConnectionState)
end
if Events and Events.OnDisconnect and type(Events.OnDisconnect.Add) == "function" then
    Events.OnDisconnect.Add(Client.clearConnectionState)
end
if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(Client.onTick)
end
return Client
