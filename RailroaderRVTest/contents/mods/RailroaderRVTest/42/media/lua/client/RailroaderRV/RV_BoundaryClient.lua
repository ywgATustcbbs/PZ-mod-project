-- Client-side RV movement feedback.
--
-- The server owns the bitmap decision and the authoritative correction.  This
-- module only predicts a blocked transition from an active cell into an
-- inactive cell so the local player does not visibly cross a hole while the
-- next server tick is in flight.  It never creates a collider or wall.

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

local BLOCK_HOLD_TICKS = 3

local function hasEntries(value)
    for _ in pairs(value) do return true end
    return false
end

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

local function position(player)
    local okZ, z = call(player, "getZ")
    z = number(z)
    if not okZ or z == nil
        or math.floor(z) < C.TELEPORT_Z + C.RV_MANAGED_MIN_Z_OFFSET
        or math.floor(z) >= C.TELEPORT_Z + C.RV_MANAGED_MAX_Z_OFFSET then
        return nil
    end
    local okX, x = call(player, "getX")
    local okY, y = call(player, "getY")
    x, y = number(x), number(y)
    if not okX or not okY or x == nil or y == nil
        or x < C.TELEPORT_X + C.RV_REGION_MIN_OFFSET_X
        or x >= C.TELEPORT_X + C.RV_REGION_MIN_OFFSET_X + C.RV_REGION_SIZE
        or y < C.TELEPORT_Y + C.RV_REGION_MIN_OFFSET_Y
        or y >= C.TELEPORT_Y + C.RV_REGION_MIN_OFFSET_Y + C.RV_REGION_SIZE then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function copyPosition(p)
    if type(p) ~= "table" then return nil end
    local x, y, z = number(p.x), number(p.y), number(p.z)
    if not x or not y or not z then return nil end
    return { x = x, y = y, z = z }
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

local function snapshotForPlayer(id)
    if id == nil then return nil end
    local current = states[id]
    if current and snapshotFresh(current.snapshot) then return current.snapshot end
    -- A reconnect can receive a snapshot before its state is created.
    for _, snapshot in pairs(snapshots) do
        if snapshot.onlineId == id and snapshotFresh(snapshot) then return snapshot end
    end
    return nil
end

local function releaseBlock(player, state)
    if state and state.blocked then
        call(player, "setBlockMovement", false)
        state.blocked = false
        state.blockedUntil = nil
    end
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

local function clampToLastValid(player, snapshot, state, current)
    local target = state.previous
    if not target or not Bitmap.isActive(snapshot.bitmap,
        target.x, target.y, target.z) then
        target = Bitmap.nearestActive(snapshot.bitmap, current.x, current.y,
            math.floor(current.z))
    end
    if not target then return false end
    if not applyPosition(player, target) then return false end
    call(player, "setBlockMovement", true)
    state.blocked = true
    state.blockedUntil = clientTick + BLOCK_HOLD_TICKS
    state.previous = copyPosition(target)
    state.previousInInner = false
    return true
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
    -- Bounds scan the compact 100x100 bitmap once per managed z layer. Keep
    -- that work on snapshot receipt so movement callbacks only read the cache.
    Bitmap.prepareWalkBounds(snapshot.bitmap)
    snapshots[snapshot.rvId] = snapshot
    snapshot.receivedTick = clientTick
    local state = states[snapshot.onlineId] or {}
    if state.blocked then
        local player = localPlayerByOnlineId(snapshot.onlineId)
        if player then
            releaseBlock(player, state)
        else
            -- No local object can still be held by setBlockMovement after a
            -- reconnect; discard the stale visual latch with the state.
            state.blocked = false
            state.blockedUntil = nil
        end
    end
    state.snapshot = snapshot
    state.lastCorrectionSequence = state.lastCorrectionSequence or 0
    state.previous = nil
    state.previousInInner = nil
    state.blocked = false
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
        local player = localPlayerByOnlineId(online)
        if player then releaseBlock(player, state) end
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
        -- a matching snapshot the client deliberately performs no prediction.
        return
    end
    if sequence <= (state.lastCorrectionSequence or 0)
        or not Bitmap.isActive(snapshot.bitmap, x, y, z) then return end
    state.lastCorrectionSequence = sequence
    state.previous = { x = x, y = y, z = z }
    state.previousInInner = nil
    states[online] = state
    -- Keep the movement history coherent with the authoritative correction.
    -- teleportTo alone only writes the coordinates; a stale next/last pair can
    -- otherwise replay the rejected trajectory on the following update.
    if not applyPosition(player, { x = x, y = y, z = z }) then return end
    releaseBlock(player, state)
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

function Client.onPlayerUpdate(player)
    if not player or (type(player.isDead) == "function" and player:isDead()) then return end
    local current = position(player)
    if not current then
        if hasEntries(states) then
            local id = onlineId(player)
            local state = id and states[id]
            if state then
                state.previous = nil
                state.previousInInner = nil
                releaseBlock(player, state)
            end
        end
        return
    end
    local id = onlineId(player)
    if id == nil then return end
    local snapshot = snapshotForPlayer(id)
    local state = states[id]
    if not snapshot then
        if state then releaseBlock(player, state) end
        return
    end
    state = state or { snapshot = snapshot, lastCorrectionSequence = 0 }
    state.snapshot = snapshot
    -- Scope guard precedes prediction.  The client is intentionally inert for
    -- positions outside its RV-local 100x100xZ region.
    if not Bitmap.containsScope(snapshot.bitmap, current.x, current.y, current.z) then
        state.previous = nil
        state.previousInInner = nil
        releaseBlock(player, state)
        states[id] = state
        return
    end
    if clientTick < (state.blockedUntil or 0) then return end
    local previous = state.previous
    if previous and previous.x == current.x and previous.y == current.y
        and previous.z == current.z then
        -- The exact last-valid position remains valid for this snapshot. A
        -- stationary player needs no repeated bitmap lookup or segment walk.
        releaseBlock(player, state)
        states[id] = state
        return
    end
    local active, inInner = Bitmap.walkableFast(snapshot.bitmap,
        current.x, current.y, current.z)
    local sameCell = previous
        and math.floor(previous.x) == math.floor(current.x)
        and math.floor(previous.y) == math.floor(current.y)
        and math.floor(previous.z) == math.floor(current.z)
    local staysInside = inInner and previous and state.previousInInner
        and math.floor(previous.z) == math.floor(current.z)
    local invalidSegment = active and previous and not sameCell and not staysInside
        and not Bitmap.segmentValid(snapshot.bitmap, previous, current)
    if not active or invalidSegment then
        if not clampToLastValid(player, snapshot, state, current) then
            state.previous = nil
            state.previousInInner = nil
        end
    else
        if not previous or previous.x ~= current.x or previous.y ~= current.y
            or previous.z ~= current.z then
            state.previous = copyPosition(current)
        end
        state.previousInInner = inInner
        releaseBlock(player, state)
    end
    states[id] = state
end

local function updateActivePlayers()
    if type(getNumActivePlayers) ~= "function" or type(getSpecificPlayer) ~= "function" then
        return
    end
    local ok, count = pcall(getNumActivePlayers)
    if not ok or type(count) ~= "number" then return end
    for playerNum = 0, count - 1 do
        local playerOk, player = pcall(getSpecificPlayer, playerNum)
        if playerOk and player then Client.onPlayerUpdate(player) end
    end
end

local hasRenderTick = Events and Events.OnRenderTick
    and type(Events.OnRenderTick.Add) == "function"

function Client.onTick()
    clientTick = clientTick + 1
    Client._tick = clientTick
    for id, state in pairs(states) do
        local player = localPlayerByOnlineId(id)
        if player and state.blocked and clientTick >= (state.blockedUntil or 0) then
            releaseBlock(player, state)
        end
    end
    if not hasEntries(snapshots) then return end
    -- RenderTick handles movement feedback when available. Poll from OnTick
    -- only as a fallback, avoiding a second local-player scan each tick.
    if not hasRenderTick then updateActivePlayers() end
end

function Client.onRenderTick()
    -- Render-tick prediction is bounded to active local players and uses the
    -- exact same canonical segment predicate as OnPlayerUpdate.  It improves
    -- input latency but never becomes a permission check.
    if not hasEntries(snapshots) then return end
    updateActivePlayers()
end

if Events and Events.OnServerCommand and type(Events.OnServerCommand.Add) == "function" then
    Events.OnServerCommand.Add(Client.onServerCommand)
end
if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(Client.onTick)
end
if Events and Events.OnRenderTick and type(Events.OnRenderTick.Add) == "function" then
    Events.OnRenderTick.Add(Client.onRenderTick)
end

return Client
