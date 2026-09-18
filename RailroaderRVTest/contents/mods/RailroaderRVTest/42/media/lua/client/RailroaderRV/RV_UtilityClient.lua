-- Client intent transport and read-only utility snapshot cache.
--
-- This module never writes a FluidContainer, registry, generator, or world
-- coordinate.  It sends only operation intent plus a server-revalidated hint.

require("RailroaderRV/RV_Constants")
local U = require("RailroaderRV/RV_UtilityConstants")

RailroaderRV = RailroaderRV or {}
RailroaderRV.UtilityClient = RailroaderRV.UtilityClient or {}
local Client = RailroaderRV.UtilityClient
local C = RailroaderRV.Constants

local requestSequence = 0
local sessionNonce
Client.snapshot = nil
Client.lastAck = nil

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
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

local function playerForObject(object)
    if object and type(object.getSquare) == "function" then
        local ok, square = pcall(function() return object:getSquare() end)
        if ok and square and type(square.getMovingObjects) == "function" then
            -- The menu caller supplies the player in normal use; this fallback
            -- only keeps the public helper safe when called directly.
        end
    end
    return localPlayer(0)
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
    if not player or type(sendClientCommand) ~= "function" then return false end
    Client.ensureSession()
    local payload = { requestId = nextRequestId(), sessionNonce = sessionNonce,
        operation = operation }
    if targetHint ~= nil then payload.targetHint = targetHint end
    if sourceHint ~= nil then payload.sourceHint = sourceHint end
    local ok, result = pcall(sendClientCommand, player, C.MOD_ID,
        C.COMMAND_RV_UTILITY, payload)
    return ok and result ~= false
end

function Client.requestConnect(player, object)
    local hint = hintForObject(object)
    return hint and Client.send(player, U.OP_CONNECT_WATER_DEVICE, hint, nil) or false
end

function Client.requestAddWater(player, item)
    local hint = hintForItem(item)
    return hint and Client.send(player, U.OP_ADD_WATER, nil, hint) or false
end

function Client.requestSnapshot(player)
    return Client.send(player, U.OP_REQUEST_SNAPSHOT, nil, nil)
end

function Client.requestGenerator(player, operation, object)
    local hint = hintForObject(object)
    return hint and Client.send(player, operation, hint, nil) or false
end

local function showRebuildHint(player)
    if player and type(player.setHaloNote) == "function" then
        pcall(function()
            player:setHaloNote("Delete this test save and rebuild it", 255, 255, 255, 5000)
        end)
    end
end

function Client.onServerCommand(module, command, args)
    if module ~= C.MOD_ID or type(args) ~= "table" then return end
    if command == C.COMMAND_RV_UTILITY_SNAPSHOT then
        -- The snapshot is display state only.  No value from it is ever sent
        -- back as a trusted amount, capacity, profile, or registry mutation.
        Client.snapshot = args
        local dashboard = RailroaderRV.UtilityDashboard
        if dashboard and type(dashboard.show) == "function" then
            pcall(dashboard.show, localPlayer(0))
        end
        return
    end
    if command ~= C.COMMAND_RV_UTILITY_ACK then return end
    Client.lastAck = args
    if args.reason == U.REASON_SAVE_REBUILD_REQUIRED then
        showRebuildHint(localPlayer(0))
    end
end

Client.getSnapshot = function() return Client.snapshot end
Client.getLastAck = function() return Client.lastAck end
Client._sessionNonce = function() return sessionNonce end

if Events and Events.OnServerCommand and type(Events.OnServerCommand.Add) == "function" then
    Events.OnServerCommand.Add(Client.onServerCommand)
end

return Client
