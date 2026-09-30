-- Client-side RV movement feedback.
--
-- The server owns RV boundary checks and applies corrections. This module
-- accepts only identity-scoped corrections from that authority.

require "RailroaderRV/Common/RV_Constants"

RailroaderRV = RailroaderRV or {}
RailroaderRV.BoundaryClient = RailroaderRV.BoundaryClient or {}

local Client = RailroaderRV.BoundaryClient
local C = RailroaderRV.Constants
local states = Client._states or {}
Client._states = states

local function number(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) end
    if value ~= nil then
        local ok, result = pcall(function() return value + 0 end)
        if ok and type(result) == "number" then return result end
    end
    return nil
end

local function integer(value)
    local result = number(value)
    if result == nil or math.floor(result) ~= result then return nil end
    return result
end

local function call(target, method, ...)
    if target == nil or type(target[method]) ~= "function" then
        return false, nil
    end
    local ok, a, b, c = pcall(target[method], target, ...)
    if not ok then return false, a end
    return true, a, b, c
end

local function onlineId(player)
    local ok, value = call(player, "getOnlineID")
    local id = ok and integer(value) or nil
    if id ~= nil and id >= 0 then return id end
    local numOk, playerNum = call(player, "getPlayerNum")
    return numOk and integer(playerNum) or nil
end

local function localPlayerByOnlineId(id)
    if id == nil or type(getNumActivePlayers) ~= "function"
        or type(getSpecificPlayer) ~= "function" then return nil end
    local okCount, count = pcall(getNumActivePlayers)
    if not okCount or type(count) ~= "number" then return nil end
    for playerNum = 0, count - 1 do
        local ok, player = pcall(getSpecificPlayer, playerNum)
        if ok and player and onlineId(player) == id then return player end
    end
    return nil
end

local function applyPosition(player, target)
    -- Apply the server-authoritative correction, then refresh movement history
    -- so the rejected client-side trajectory is not replayed next update.
    local teleportCalled, teleportResult = call(player, "teleportTo",
        target.x, target.y, target.z)
    local changed = teleportCalled and teleportResult ~= false
    local methods = { "setX", "setY", "setZ", "setNextX", "setNextY",
        "setLastX", "setLastY", "setLastZ" }
    local values = { target.x, target.y, target.z, target.x, target.y,
        target.x, target.y, target.z }
    for i = 1, #methods do
        local ok = call(player, methods[i], values[i])
        changed = changed or ok
    end
    if type(player.setCurrentSquareFromPosition) == "function" then
        pcall(player.setCurrentSquareFromPosition, player,
            target.x, target.y, target.z)
    end
    return changed
end

function Client.onCorrection(args)
    if type(args) ~= "table" then return end
    local online = integer(args.onlineId)
    local sequence = integer(args.sequence)
    local generation = integer(args.generation)
    local rvId = args.rvId
    local x, y, z = number(args.x), number(args.y), number(args.z)
    if online == nil or not sequence or not generation or generation < 1
        or rvId == nil
        or tostring(rvId) == "" or not x or not y or not z then return end
    local player = localPlayerByOnlineId(online)
    if not player or (type(player.isDead) == "function" and player:isDead()) then return end
    local state = states[online] or { lastCorrectionSequence = 0 }
    if sequence <= (state.lastCorrectionSequence or 0) then return end
    if not applyPosition(player, { x = x, y = y, z = z }) then return end
    state.rvId = tostring(rvId)
    state.generation = generation
    state.lastCorrectionSequence = sequence
    states[online] = state
end

function Client.onServerCommand(module, command, args)
    if module ~= C.MOD_ID then return end
    if command == C.COMMAND_RV_BOUNDARY_CORRECTION then
        Client.onCorrection(args)
    end
end

if Events and Events.OnServerCommand and type(Events.OnServerCommand.Add) == "function" then
    Events.OnServerCommand.Add(Client.onServerCommand)
end
if Events and Events.OnDisconnect and type(Events.OnDisconnect.Add) == "function" then
    Events.OnDisconnect.Add(function()
        states = {}
        Client._states = states
    end)
end
return Client
