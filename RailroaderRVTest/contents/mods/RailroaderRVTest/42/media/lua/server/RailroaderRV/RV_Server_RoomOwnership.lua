-- RV_Server: RoomOwnership responsibilities.
return function(ctx)
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND_REFRESH_ROOM_OWNERSHIP = ctx.COMMAND_REFRESH_ROOM_OWNERSHIP
local COMMAND_RV_TELEPORT = ctx.COMMAND_RV_TELEPORT
local Constants = ctx.Constants
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local ServerSchema = ctx.ServerSchema
local roomOwnershipGuards = ctx.roomOwnershipGuards
local function safeErrorText(...) return ctx.safeErrorText(...) end
local function requireCurrentManifest(...) return ctx.requireCurrentManifest(...) end
local ROOM_OWNERSHIP_MIN_TICKS = ctx.ROOM_OWNERSHIP_MIN_TICKS
local ROOM_OWNERSHIP_STABLE_TICKS = ctx.ROOM_OWNERSHIP_STABLE_TICKS
local ROOM_OWNERSHIP_MAX_TICKS = ctx.ROOM_OWNERSHIP_MAX_TICKS
local ROOM_OWNERSHIP_SCAN_INTERVAL_TICKS = ctx.ROOM_OWNERSHIP_SCAN_INTERVAL_TICKS

local function notifyFailure(player, reason)
    if not player then return end
    ServerUtil.callGlobal("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_RV_TELEPORT, { ok = false, reason = tostring(reason) })
end

local function removeOldGeneration(cell, manifest)
    requireCurrentManifest(manifest, true)
    if manifest.generation == nil then return end
    local generation = ServerUtil.requiredInteger(manifest.generation, "manifest generation")
    local oldBounds = manifest.bounds
    local rvId, bitmapVersion = manifest.rvId, manifest.bitmapVersion
    ServerSchema.walkBounds(cell, oldBounds, function(square)
        ServerWorld.clearSquare(square, generation, rvId, bitmapVersion)
    end)
end

local function clearInvalidRoomOwnershipReferences(cell, oldBounds, newBounds)
    local cleared = 0
    local seen = {}
    local function inspect(square, x, y, z)
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if seen[key] then
            return
        end
        seen[key] = true
        local roomOk, room = ServerUtil.invoke(square, "getRoom")
        if not roomOk or room == nil then
            return
        end
        local roomDefOk, roomDef = ServerUtil.invoke(square, "getRoomDef")
        if not roomDefOk then
            error("RailroaderRVTest: room definition inspection failed")
        end
        -- WorldRegionToMetaGrid.removeIsoRoom clears IsoRoom.def before every
        -- square has necessarily lost the retired room ID. Only that exact
        -- invalid reference is corrected. Valid old/new rooms, including an
        -- overlapping replacement, are never modified.
        if roomDef == nil then
            if not ServerUtil.callSucceeded(square, "setRoomID", -1) then
                error("RailroaderRVTest: invalid room ownership reset failed")
            end
            local verifyOk, verifyRoom = ServerUtil.invoke(square, "getRoom")
            if not verifyOk or verifyRoom ~= nil then
                error("RailroaderRVTest: invalid room ownership reset did not take effect")
            end
            cleared = cleared + 1
        end
    end
    ServerSchema.eachStructureSquare(cell, oldBounds, inspect)
    ServerSchema.eachStructureSquare(cell, newBounds, inspect)
    return cleared
end

local function coordinatesInRoomOwnershipBounds(x, y, z, bounds)
    if type(bounds) ~= "table" then return false end
    local inBase = x >= bounds.wallMinX and x <= bounds.wallMaxX
        and y >= bounds.wallMinY and y <= bounds.wallMaxY and z == bounds.z
    local inRoof = x >= bounds.roofMinX and x <= bounds.roofMaxX
        and y >= bounds.roofMinY and y <= bounds.roofMaxY and z == bounds.roofZ
    return inBase or inRoof
end

local function objectCoordinates(object)
    if not object then return nil end
    local squareOk, square = ServerUtil.invoke(object, "getSquare")
    local target = squareOk and square or object
    local xOk, x = ServerUtil.invoke(target, "getX")
    local yOk, y = ServerUtil.invoke(target, "getY")
    local zOk, z = ServerUtil.invoke(target, "getZ")
    x, y, z = ServerUtil.integer(x), ServerUtil.integer(y), ServerUtil.integer(z)
    if not xOk or not yOk or not zOk or x == nil or y == nil or z == nil then
        return nil
    end
    return x, y, z
end

local function requestRoomOwnershipScan(object)
    local x, y, z = objectCoordinates(object)
    if x == nil then return end
    for _, guard in pairs(roomOwnershipGuards) do
        if coordinatesInRoomOwnershipBounds(x, y, z, guard.oldBounds)
            or coordinatesInRoomOwnershipBounds(x, y, z, guard.newBounds) then
            guard.scanRequested = true
            guard.nextScanTick = ctx.serverTick
        end
    end
end

local function roomOwnershipGuardKey(rvId, generation, bitmapVersion)
    return tostring(rvId) .. ":" .. tostring(generation) .. ":"
        .. tostring(bitmapVersion)
end

local function registerServerRoomOwnershipGuard(generation, player, oldBounds,
    newBounds, rvId, bitmapVersion)
    if rvId == nil or tostring(rvId) == "" then
        error("RailroaderRVTest: room ownership RV identity is incomplete")
    end
    local generationNumber = ServerUtil.requiredInteger(generation,
        "room ownership generation")
    if generationNumber < 1 then
        error("RailroaderRVTest: room ownership generation is invalid")
    end
    local version = ServerUtil.requiredInteger(bitmapVersion,
        "room ownership bitmapVersion")
    if version < 1 then
        error("RailroaderRVTest: room ownership bitmapVersion is invalid")
    end
    local guard = {
        generation = generationNumber,
        rvId = tostring(rvId),
        bitmapVersion = version,
        player = player,
        oldBounds = oldBounds,
        newBounds = newBounds,
        ticks = 0,
        stableTicks = 0,
        totalCleared = 0,
        lastScanStable = false,
        scanRequested = false,
        nextScanTick = ctx.serverTick + ROOM_OWNERSHIP_SCAN_INTERVAL_TICKS,
    }
    guard.key = roomOwnershipGuardKey(guard.rvId, guard.generation, version)
    roomOwnershipGuards[guard.key] = guard
    return guard
end

local function refreshServerRoomOwnershipGuard(guard, phase)
    local cleared = clearInvalidRoomOwnershipReferences(ServerWorld.getCellForPlayer(guard.player),
        guard.oldBounds, guard.newBounds)
    guard.totalCleared = guard.totalCleared + cleared
    guard.lastScanStable = cleared == 0
    guard.scanRequested = false
    if phase ~= nil then
        guard.nextScanTick = ctx.serverTick + ROOM_OWNERSHIP_SCAN_INTERVAL_TICKS
    end
    if cleared > 0 or phase ~= nil then
        print("[RailroaderRVTest] room ownership refresh generation="
            .. tostring(guard.generation) .. " phase=" .. tostring(phase or "tick")
            .. " cleared=" .. tostring(cleared))
    end
    return cleared
end

local function processServerRoomOwnershipGuards()
    -- A roof-refresh relocation deliberately moves the authoritative player
    -- far outside the RV scope.  The guard's bounds are still the RV's
    -- current geometry, so running the normal scan through that player's
    -- remote cell can make IsoCell resolve repeated cross-chunk lookups on
    -- the same tick that must advance the relocation.  The roof service
    -- already owns the boundary lease and keeps the player out of the room;
    -- pause only this non-transactional cleanup until the member returns.
    if ctx.roofRepairRelocationGroup ~= nil or ctx.roofRepairGroupFinalReturn ~= nil then
        return
    end
    local finished = {}
    for generation, guard in pairs(roomOwnershipGuards) do
        guard.ticks = guard.ticks + 1
        if guard.scanRequested or ctx.serverTick >= (guard.nextScanTick or 0) then
            guard.nextScanTick = ctx.serverTick + ROOM_OWNERSHIP_SCAN_INTERVAL_TICKS
            local ok, clearedOrError = pcall(refreshServerRoomOwnershipGuard, guard, nil)
            if not ok then
                guard.lastScanStable = false
                guard.scanRequested = true
                guard.lastError = safeErrorText(clearedOrError)
            elseif clearedOrError > 0 then
                guard.lastScanStable = false
                guard.lastError = nil
            else
                guard.lastScanStable = true
                guard.lastError = nil
            end
            if guard.lastScanStable then
                -- stableTicks represents successful full scans, expressed in
                -- the configured fallback interval, not elapsed ticks since
                -- the last scan.
                guard.stableTicks = guard.stableTicks
                    + ROOM_OWNERSHIP_SCAN_INTERVAL_TICKS
            else
                guard.stableTicks = 0
            end
        end
        if guard.ticks >= ROOM_OWNERSHIP_MAX_TICKS then
            print("[RailroaderRVTest] room ownership guard expired generation="
                .. tostring(generation) .. " cleared=" .. tostring(guard.totalCleared)
                .. (guard.lastError and " error=" .. guard.lastError or ""))
            finished[#finished + 1] = generation
        elseif guard.ticks >= ROOM_OWNERSHIP_MIN_TICKS
            and guard.stableTicks >= ROOM_OWNERSHIP_STABLE_TICKS then
            print("[RailroaderRVTest] room ownership guard complete generation="
                .. tostring(generation) .. " cleared=" .. tostring(guard.totalCleared))
            finished[#finished + 1] = generation
        end
    end
    for i = 1, #finished do
        roomOwnershipGuards[finished[i]] = nil
    end
end

local function copyRoomRefreshBounds(target, prefix, bounds)
    local fields = {
        "wallMinX", "wallMaxX", "wallMinY", "wallMaxY",
        "roomMinX", "roomMaxX", "roomMinY", "roomMaxY",
        "roofMinX", "roofMaxX", "roofMinY", "roofMaxY", "z", "roofZ",
    }
    for i = 1, #fields do
        local field = fields[i]
        target[prefix .. field] = ServerUtil.requiredInteger(bounds[field],
            "room refresh " .. prefix .. field)
    end
end

local function armClientRoomOwnershipGuard(generation, oldBounds, newBounds,
    rvId, bitmapVersion)
    local payload = {
        generation = generation,
        rvId = tostring(rvId),
        bitmapVersion = ServerUtil.requiredInteger(bitmapVersion,
            "client room ownership bitmapVersion"),
        hasOld = type(oldBounds) == "table",
    }
    if payload.hasOld then
        copyRoomRefreshBounds(payload, "old", oldBounds)
    end
    copyRoomRefreshBounds(payload, "new", newBounds)
    -- The no-player overload broadcasts to every connected client. A player
    -- other than the requester may later walk through the retired footprint.
    if not ServerUtil.callGlobalSucceeded("sendServerCommand", COMMAND_MODULE,
        COMMAND_REFRESH_ROOM_OWNERSHIP, payload) then
        error("RailroaderRVTest: client room ownership guards could not be armed")
    end
end

local function removeGeneration(cell, bounds, generation, rvId, bitmapVersion)
    if not cell or type(bounds) ~= "table" or not generation then
        return
    end
    -- Failed builds are rolled back by the same owner+generation tag used by
    -- repeat generation.  This includes roof floors, generators and fixtures
    -- the final light, even when the failure occurs in the last phase.
    ServerSchema.walkBounds(cell, bounds, function(square)
        ServerWorld.clearSquare(square, generation, rvId, bitmapVersion)
    end)

    -- A successful pcall around ServerWorld.clearSquare is not enough on a dedicated
    -- server: transmitRemoveItemFromSquare owns the packet, event, local
    -- detach, and neighbour recalculation.  Verify the authoritative cell has
    -- no tagged object left before reporting rollback=COMPLETE.
    local remaining = 0
    ServerSchema.walkBounds(cell, bounds, function(square)
        local objects = ServerWorld.squareSnapshot(square)
        for i = 1, #objects do
            if ServerWorld.isTaggedForGeneration(objects[i], generation, rvId,
                bitmapVersion) then
                remaining = remaining + 1
            end
        end
    end)
    if remaining > 0 then
        error("RailroaderRVTest: rollback verification found " .. tostring(remaining)
            .. " tagged objects still present")
    end
end

-- Existing-RV entry/reconnects do not run the generation broadcast below.  Arm
-- only the corresponding client with the current manifest footprint so a fresh
-- client cannot enter a room whose IsoRoom reference may be retired later.
-- This helper intentionally accepts no client coordinates or client geometry;
-- its caller supplies the server-validated current manifest bounds.
local function armTargetedClientRoomOwnershipGuard(player, generation, newBounds,
    rvId, bitmapVersion)
    if player == nil then
        error("RailroaderRVTest: targeted room ownership player is unavailable")
    end
    local generationNumber = ServerUtil.requiredInteger(generation,
        "targeted room ownership generation")
    if generationNumber < 1 then
        error("RailroaderRVTest: targeted room ownership generation is invalid")
    end
    if rvId == nil or tostring(rvId) == "" then
        error("RailroaderRVTest: targeted room ownership RV identity is incomplete")
    end
    local version = ServerUtil.requiredInteger(bitmapVersion,
        "targeted room ownership bitmapVersion")
    if version ~= Constants.BITMAP_VERSION then
        error("RailroaderRVTest: targeted room ownership bitmapVersion is invalid")
    end
    local payload = {
        generation = generationNumber,
        rvId = tostring(rvId),
        bitmapVersion = version,
        hasOld = false,
    }
    copyRoomRefreshBounds(payload, "new", newBounds)
    if not ServerUtil.callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_REFRESH_ROOM_OWNERSHIP, payload) then
        error("RailroaderRVTest: targeted room ownership guard could not be armed")
    end
end


ctx.notifyFailure = notifyFailure
ctx.removeOldGeneration = removeOldGeneration
ctx.requestRoomOwnershipScan = requestRoomOwnershipScan
ctx.registerServerRoomOwnershipGuard = registerServerRoomOwnershipGuard
ctx.refreshServerRoomOwnershipGuard = refreshServerRoomOwnershipGuard
ctx.processServerRoomOwnershipGuards = processServerRoomOwnershipGuards
ctx.armClientRoomOwnershipGuard = armClientRoomOwnershipGuard
ctx.removeGeneration = removeGeneration
ctx.armTargetedClientRoomOwnershipGuard = armTargetedClientRoomOwnershipGuard
end
