-- Client intent transport and read-only utility snapshot cache.
--
-- This module never writes a FluidContainer, registry, generator, or world
-- coordinate.  It sends only operation intent plus a server-revalidated hint.
-- Requests carry a monotonically increasing requestId; the newest one is
-- correlated with the server acknowledgement for status feedback only.

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
local sentRequestId = nil
local sentOperation = nil
Client.snapshot = nil

function Client.clearConnectionState()
    requestSequence = 0
    sentRequestId = nil
    sentOperation = nil
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

local function localPlayer(playerNum)
    if type(getSpecificPlayer) ~= "function" then return nil end
    local ok, player = pcall(getSpecificPlayer, playerNum)
    return ok and player or nil
end

local function nextRequestId()
    requestSequence = requestSequence + 1
    return tostring(requestSequence)
end

local function transmit(player, payload)
    if not player or type(sendClientCommand) ~= "function" then return false end
    local ok, result = pcall(sendClientCommand, player, C.MOD_ID,
        C.COMMAND_RV_UTILITY, payload)
    return ok and result ~= false
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

function Client.send(player, operation, targetHint, sourceHint)
    local requestId = nextRequestId()
    local payload = { requestId = requestId, operation = operation }
    if targetHint ~= nil then payload.targetHint = targetHint end
    if sourceHint ~= nil then payload.sourceHint = sourceHint end
    if not transmit(player, payload) then return rejectSend(player) end
    sentRequestId, sentOperation = requestId, operation
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

-- A snapshot only reads current server state, so it is executed directly and
-- owns no pending acknowledgement or UI transaction.
function Client.requestSnapshot(player)
    local payload = { requestId = nextRequestId(),
        operation = U.OP_REQUEST_SNAPSHOT }
    if not transmit(player, payload) then return rejectSend(player) end
    return true
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
    return type(requestId) == "string" and requestId == sentRequestId
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
    if type(args.requestId) ~= "string" or args.requestId ~= sentRequestId then return end
    local operation = sentOperation
    sentRequestId, sentOperation = nil, nil
    local player = localPlayer(0)
    local dashboard = RailroaderRV.UtilityDashboard
    local displayed = false
    if dashboard and type(dashboard.onAck) == "function" then
        local ok, accepted = pcall(dashboard.onAck, player, args, operation)
        displayed = ok and accepted == true
    end
    if not displayed then
        local message
        if args.ok == true and operation == U.OP_CONNECT_WATER_DEVICE then
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
        Client.showFeedback(player, message)
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
return Client
