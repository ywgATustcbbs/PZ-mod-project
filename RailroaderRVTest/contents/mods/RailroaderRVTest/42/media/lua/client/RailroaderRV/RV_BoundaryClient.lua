-- Client-side RV movement feedback.
--
-- The server owns RV boundary checks and applies corrections.  This module
-- accepts only identity-scoped corrections from that authority.

require "RailroaderRV/RV_Constants"
local Bitmap = require "RailroaderRV/RV_Bitmap"

RailroaderRV = RailroaderRV or {}
RailroaderRV.BoundaryClient = RailroaderRV.BoundaryClient or {}

local Client = RailroaderRV.BoundaryClient
local C = RailroaderRV.Constants
local snapshots = Client._snapshots or {}
local states = Client._states or {}
local clientTick = Client._tick or 0
Client._snapshots, Client._states = snapshots, states
Client._tick = clientTick

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

local function snapshotKey(rvId, generation, bitmapVersion)
    return tostring(rvId) .. ":" .. tostring(generation) .. ":"
        .. tostring(bitmapVersion)
end

local function snapshotFresh(snapshot)
    if not snapshot then return false end
    local received = integer(snapshot.receivedTick)
    if received == nil then return false end
    local age = clientTick - received
    return age >= 0 and age <= (integer(C.BOUNDARY_SNAPSHOT_TIMEOUT_TICKS) or 120)
end

local function applyPosition(player, target)
    -- Use the same engine teleport primitive as the correction handler, then
    -- refresh the movement-history fields that can otherwise reapply the
    -- rejected client-side trajectory on the next update.
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

local function validSnapshot(args)
    if type(args) ~= "table" then return nil end
    local rvId = args.rvId
    local generation = integer(args.generation)
    local bitmapVersion = integer(args.bitmapVersion)
    local online = integer(args.onlineId)
    local minZ, maxZ = integer(args.minZ), integer(args.maxZ)
    if rvId == nil or tostring(rvId) == "" or not generation or generation < 1
        or bitmapVersion ~= C.BITMAP_VERSION or online == nil
        or not minZ or not maxZ or maxZ <= minZ then
        return nil
    end
    local encoded = {
        schemaVersion = integer(args.schemaVersion),
        bitmapVersion = bitmapVersion,
        originX = integer(args.originX), originY = integer(args.originY),
        width = integer(args.width), height = integer(args.height),
        minZ = minZ, maxZ = maxZ, layers = args.layers, encoding = "hex",
    }
    if encoded.schemaVersion ~= Bitmap.SCHEMA_VERSION then return nil end
    local bitmap = Bitmap.decode(encoded)
    if not bitmap or not Bitmap.validate(bitmap) then return nil end
    return { rvId = tostring(rvId), generation = generation,
        bitmapVersion = bitmapVersion, onlineId = online, bitmap = bitmap,
        key = snapshotKey(rvId, generation, bitmapVersion) }
end

function Client.onBitmap(args)
    local snapshot = validSnapshot(args)
    if not snapshot then return end
    local old = snapshots[snapshot.rvId]
    if old and (snapshot.generation < old.generation
        or snapshot.generation == old.generation
            and snapshot.bitmapVersion < old.bitmapVersion) then
        return
    end
    snapshots[snapshot.rvId] = snapshot
    snapshot.receivedTick = clientTick
    local state = states[snapshot.onlineId] or {}
    state.snapshot = snapshot
    state.lastCorrectionSequence = state.lastCorrectionSequence or 0
    states[snapshot.onlineId] = state
end

function Client.onBitmapClear(args)
    if type(args) ~= "table" then return end
    local online = integer(args.onlineId)
    if online == nil then return end
    local key = type(args.key) == "string" and args.key or nil
    for rvId, snapshot in pairs(snapshots) do
        if snapshot.onlineId == online and (key == nil or snapshot.key == key) then
            snapshots[rvId] = nil
        end
    end
    local state = states[online]
    if state and (key == nil or not state.snapshot or state.snapshot.key == key) then
        states[online] = nil
    end
end

function Client.onCorrection(args)
    if type(args) ~= "table" then return end
    local online = integer(args.onlineId)
    local sequence = integer(args.sequence)
    local generation = integer(args.generation)
    local bitmapVersion = integer(args.bitmapVersion)
    local x, y, z = number(args.x), number(args.y), number(args.z)
    if online == nil or not sequence or not generation or not bitmapVersion
        or not x or not y or not z then return end
    local player = localPlayerByOnlineId(online)
    if not player or (type(player.isDead) == "function" and player:isDead()) then return end
    local state = states[online] or {}
    local snapshot = state.snapshot
    if not snapshot or snapshot.generation ~= generation
        or snapshot.bitmapVersion ~= bitmapVersion
        or tostring(snapshot.rvId) ~= tostring(args.rvId)
        or not snapshotFresh(snapshot) then
        -- The server has already applied its authoritative teleport.  Without
        -- a matching snapshot the client deliberately ignores the correction.
        return
    end
    if sequence <= (state.lastCorrectionSequence or 0)
        or not Bitmap.isActive(snapshot.bitmap, x, y, z) then return end
    state.lastCorrectionSequence = sequence
    states[online] = state
    -- Reset movement history so stale next/last coordinates cannot replay the
    -- trajectory that the server rejected.
    if not applyPosition(player, { x = x, y = y, z = z }) then return end
end

function Client.onServerCommand(module, command, args)
    if module ~= C.MOD_ID then return end
    if command == C.COMMAND_RV_BITMAP then
        Client.onBitmap(args)
    elseif command == C.COMMAND_RV_BITMAP_CLEAR then
        Client.onBitmapClear(args)
    elseif command == C.COMMAND_RV_BOUNDARY_CORRECTION then
        Client.onCorrection(args)
    end
end

function Client.onTick()
    clientTick = clientTick + 1
    Client._tick = clientTick
end

if Events and Events.OnServerCommand and type(Events.OnServerCommand.Add) == "function" then
    Events.OnServerCommand.Add(Client.onServerCommand)
end
if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(Client.onTick)
end
return Client
