-- Client intent transport and read-only utility snapshot cache.
--
-- This module never writes a FluidContainer, registry, generator, or world
-- coordinate.  It sends only operation intent plus a server-revalidated hint.

require("RailroaderRV/RV_Constants")
-- Register the same isolated sprite used by the server before hidden native
-- generator objects arrive in complete-object packets.
local UtilitySprite = require("RailroaderRV/RV_UtilitySprite")
local hiddenSpritesReady, _, hiddenSpriteReason = UtilitySprite.install()
if not hiddenSpritesReady then
    error("RailroaderRVTest: client hidden sprite registration failed: "
        .. tostring(hiddenSpriteReason))
end
local U = require("RailroaderRV/RV_UtilityConstants")

RailroaderRV = RailroaderRV or {}
RailroaderRV.UtilityClient = RailroaderRV.UtilityClient or {}
local Client = RailroaderRV.UtilityClient
local C = RailroaderRV.Constants

local requestSequence = 0
local sessionNonce
Client.snapshot = nil

function Client.clearConnectionState()
    requestSequence = 0
    sessionNonce = nil
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

function Client.send(player, operation, targetHint, sourceHint, entryPoint)
    if not player or type(sendClientCommand) ~= "function" then return false end
    Client.ensureSession()
    local payload = { requestId = nextRequestId(), sessionNonce = sessionNonce,
        operation = operation }
    if targetHint ~= nil then payload.targetHint = targetHint end
    if sourceHint ~= nil then payload.sourceHint = sourceHint end
    if entryPoint ~= nil then payload.entryPoint = entryPoint end
    local ok, result = pcall(sendClientCommand, player, C.MOD_ID,
        C.COMMAND_RV_UTILITY, payload)
    return ok and result ~= false
end

function Client.requestAddFuel(player, item)
    local hint = hintForItem(item)
    return hint and Client.send(player, U.OP_ADD_FUEL, nil, hint) or false
end

function Client.requestAddBattery(player, item)
    local hint = hintForItem(item)
    return hint and Client.send(player, U.OP_ADD_BATTERY, nil, hint) or false
end

function Client.requestInstallComponent(player, operation, item)
    local hint = hintForItem(item)
    return hint and Client.send(player, operation, nil, hint) or false
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
    return hint and Client.send(player, operation, hint, nil) or false
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
    local dashboard = RailroaderRV.UtilityDashboard
    if dashboard and type(dashboard.onAck) == "function" then
        pcall(dashboard.onAck, localPlayer(0), args)
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
