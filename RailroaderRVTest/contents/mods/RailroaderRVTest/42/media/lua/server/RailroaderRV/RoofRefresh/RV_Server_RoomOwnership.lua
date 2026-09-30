-- RV_Server: RoomOwnership responsibilities.
return function(ctx)
local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND_REFRESH_ROOM_OWNERSHIP = ctx.COMMAND_REFRESH_ROOM_OWNERSHIP
local COMMAND_RV_TELEPORT = ctx.COMMAND_RV_TELEPORT
local Constants = ctx.Constants
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local ServerSchema = ctx.ServerSchema
local roomOwnershipGuards = ctx.roomOwnershipGuards

-- The server checks authoritative players' current squares each tick and
-- supplements that with a lower-frequency 3x3 neighborhood probe.
local ROOM_OWNERSHIP_3X3_INTERVAL_TICKS = 120

local function notifyFailure(player, reason)
    if not player then return end
    local idOk, onlineId = ServerUtil.invoke(player, "getOnlineID")
    onlineId = idOk and ServerUtil.toNumber(onlineId) or nil
    if not ServerUtil.isFiniteNumber(onlineId) or math.floor(onlineId) ~= onlineId
        or onlineId < 0 then
        return false
    end
    local reasonText = tostring(reason)
    local invalidRVData = Constants and Constants.INVALID_RV_DATA
    if type(invalidRVData) == "string" and invalidRVData ~= ""
        and string.find(reasonText, invalidRVData, 1, true) then
        reasonText = invalidRVData
    end
    return ServerUtil.callGlobalSucceeded("sendServerCommand", player,
        COMMAND_MODULE, COMMAND_RV_TELEPORT, {
            ok = false, onlineId = onlineId, reason = reasonText,
        })
end

local function clearInvalidRoomOwnershipSquare(square)
    local roomOk, room = ServerUtil.invoke(square, "getRoom")
    if not roomOk then
        error("RailroaderRVTest: room ownership inspection failed")
    end
    if room == nil then return false end
    local roomDefOk, roomDef = ServerUtil.invoke(square, "getRoomDef")
    if not roomDefOk then
        error("RailroaderRVTest: room definition inspection failed")
    end
    -- WorldRegionToMetaGrid.removeIsoRoom clears IsoRoom.def before every
    -- square has necessarily lost the retired room ID. Only that exact
    -- invalid reference is corrected. Valid old/new rooms, including an
    -- overlapping replacement, are never modified.
    if roomDef ~= nil then return false end
    if not ServerUtil.callSucceeded(square, "setRoomID", -1) then
        error("RailroaderRVTest: invalid room ownership reset failed")
    end
    local verifyOk, verifyRoom = ServerUtil.invoke(square, "getRoom")
    if not verifyOk or verifyRoom ~= nil then
        error("RailroaderRVTest: invalid room ownership reset did not take effect")
    end
    return true
end

-- The shared layout enumerator is the single template-derived source for the
-- wall shell and the roof host coordinates of one bounds set.
local function clearInvalidRoomOwnershipBounds(cell, bounds)
    if type(bounds) ~= "table" then return 0 end
    local cleared = 0
    Layout.eachStructureCoordinate(bounds, function(x, y, z)
        local square = ServerWorld.getSquare(cell, x, y, z)
        if square and clearInvalidRoomOwnershipSquare(square) then
            cleared = cleared + 1
        end
    end)
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
    local cellOk, cell = ServerUtil.invoke(target, "getCell")
    return x, y, z, cellOk and cell or nil
end

-- Object hooks can run before IsoRegions finishes rebuilding dynamic rooms, so
-- an event only marks its cell for one scan on the next tick; every event of
-- that tick merges into the same scan.
local function scheduleRoomOwnershipScan(guard, cell)
    if cell ~= nil then
        guard.pendingCells[cell] = true
    end
    if guard.scanDueTick == nil then
        guard.scanDueTick = ctx.serverTick + 1
    end
end

local function requestRoomOwnershipScan(object, includeOutcome)
    local hit = false
    local x, y, z, cell = objectCoordinates(object)
    if x == nil then
        if includeOutcome then return nil end
        return
    end
    for _, guard in pairs(roomOwnershipGuards) do
        if coordinatesInRoomOwnershipBounds(x, y, z, guard.oldBounds)
            or coordinatesInRoomOwnershipBounds(x, y, z, guard.newBounds) then
            hit = true
            scheduleRoomOwnershipScan(guard, cell)
        end
    end
    if includeOutcome then return hit end
end

local function requestRoomOwnershipRemovalScan(object)
    requestRoomOwnershipScan(object, true)
end

local function onlinePlayersSnapshot()
    local ok, collection = ServerUtil.callGlobal("getOnlinePlayers")
    if not ok or collection == nil then
        local singleOk, singlePlayer = ServerUtil.callGlobal("getPlayer")
        if singleOk and singlePlayer ~= nil then return { singlePlayer }, true end
        return {}, false
    end
    local result, seen = {}, {}
    local sizeOk, size = ServerUtil.invoke(collection, "size")
    size = ServerUtil.integer(size)
    if sizeOk and size ~= nil and size >= 0 then
        for index = 0, size - 1 do
            local playerOk, player = ServerUtil.invoke(collection, "get", index)
            if not playerOk then return result, false end
            if player ~= nil and not seen[player] then
                seen[player] = true
                result[#result + 1] = player
            end
        end
        return result, true
    end
    if type(collection) == "table" then
        for _, player in pairs(collection) do
            if player ~= nil and not seen[player] then
                seen[player] = true
                result[#result + 1] = player
            end
        end
        return result, true
    end
    return result, false
end

local function authoritativePlayerCoordinates(player)
    if type(ctx.serverTick) == "number"
        and type(ctx.samplePlayerPosition) == "function"
        and type(ctx.getPlayerPosition) == "function" then
        local sampled, positionOrReason = ctx.samplePlayerPosition(player,
            ctx.serverTick, 1)
        local positionOk, position
        if sampled then
            positionOk, position = true, positionOrReason
        elseif positionOrReason == "player sample is not due" then
            positionOk, position = ctx.getPlayerPosition(player, {
                now = ctx.serverTick,
                maxAge = 0,
            })
        elseif positionOrReason == "player sample identity or interval is invalid" then
            positionOk, position = ctx.getPlayerPosition(player, {
                fresh = true,
            })
        else
            return nil
        end
        if not positionOk or type(position) ~= "table" then return nil end
        local x, y, z = ServerUtil.toNumber(position.x),
            ServerUtil.toNumber(position.y), ServerUtil.toNumber(position.z)
        if x == nil or y == nil or z == nil or x ~= x or y ~= y or z ~= z
            or x <= -math.huge or x >= math.huge
            or y <= -math.huge or y >= math.huge
            or z <= -math.huge or z >= math.huge then
            return nil
        end
        return math.floor(x), math.floor(y), math.floor(z)
    end
    local xOk, x = ServerUtil.invoke(player, "getX")
    local yOk, y = ServerUtil.invoke(player, "getY")
    local zOk, z = ServerUtil.invoke(player, "getZ")
    x, y, z = ServerUtil.toNumber(x), ServerUtil.toNumber(y), ServerUtil.toNumber(z)
    if not xOk or not yOk or not zOk or x == nil or y == nil or z == nil then
        return nil
    end
    if x ~= x or y ~= y or z ~= z
        or x <= -math.huge or x >= math.huge
        or y <= -math.huge or y >= math.huge
        or z <= -math.huge or z >= math.huge then
        return nil
    end
    return math.floor(x), math.floor(y), math.floor(z)
end

local function authoritativePlayerStatesSnapshot()
    local players, snapshotOk = onlinePlayersSnapshot()
    if not snapshotOk then return {}, false end
    local states = {}
    for i = 1, #players do
        local player = players[i]
        local x, y, z = authoritativePlayerCoordinates(player)
        if x == nil then return states, false end
        states[#states + 1] = { player = player, x = x, y = y, z = z }
    end
    return states, true
end

local function playerNeighborhoodTouchesGuard(x, y, z, guard, radius)
    for dx = -radius, radius do
        for dy = -radius, radius do
            if coordinatesInRoomOwnershipBounds(x + dx, y + dy, z,
                guard.oldBounds)
                or coordinatesInRoomOwnershipBounds(x + dx, y + dy, z,
                    guard.newBounds) then
                return true
            end
        end
    end
    return false
end

local function addScanCell(cells, seen, player)
    local cell = ServerWorld.getCellForPlayer(player)
    if not seen[cell] then
        seen[cell] = true
        cells[#cells + 1] = cell
    end
end

local function relevantRoomOwnershipCells(guard, phase)
    local players, snapshotOk = onlinePlayersSnapshot()
    if not snapshotOk then
        error("RailroaderRVTest: online player snapshot unavailable for room ownership scan")
    end
    local cells, seen = {}, {}
    for cell in pairs(guard.pendingCells) do
        if not seen[cell] then
            seen[cell] = true
            cells[#cells + 1] = cell
        end
    end
    local guardPlayerIncluded = false
    for i = 1, #players do
        local player = players[i]
        local x, y, z = authoritativePlayerCoordinates(player)
        if x == nil then
            error("RailroaderRVTest: online player position unavailable for room ownership scan")
        end
        local nearGuard = playerNeighborhoodTouchesGuard(x, y, z, guard, 1)
        if nearGuard or phase ~= nil and player == guard.player then
            addScanCell(cells, seen, player)
        end
        if phase ~= nil and player == guard.player then
            guardPlayerIncluded = true
        end
    end
    -- A transaction's initiating player may be temporarily outside the RV,
    -- but its authoritative cell is the one preflighted for synchronous scans.
    if phase ~= nil and not guardPlayerIncluded then
        addScanCell(cells, seen, guard.player)
    end
    if #cells == 0 then
        error("RailroaderRVTest: no authoritative cell is available for room ownership scan")
    end
    return cells
end

local function clearInvalidRoomOwnershipNearPlayers(guards, playerStates,
    snapshotOk, neighborhoodDue)
    if not snapshotOk then
        error("RailroaderRVTest: online player snapshot unavailable for room ownership probe")
    end
    local maxRadius = 0
    for _, due in pairs(neighborhoodDue) do
        if due then
            maxRadius = 1
            break
        end
    end
    for i = 1, #playerStates do
        local state = playerStates[i]
        local player, x, y, z = state.player, state.x, state.y, state.z
        local cell = nil
        for dx = -maxRadius, maxRadius do
            for dy = -maxRadius, maxRadius do
                local matchingGuards = nil
                local squareX, squareY = x + dx, y + dy
                for guard in pairs(guards) do
                    local radius = neighborhoodDue[guard] and 1 or 0
                    if math.abs(dx) <= radius and math.abs(dy) <= radius
                        and (coordinatesInRoomOwnershipBounds(squareX, squareY, z,
                            guard.oldBounds)
                            or coordinatesInRoomOwnershipBounds(squareX, squareY, z,
                                guard.newBounds)) then
                        if matchingGuards == nil then matchingGuards = {} end
                        matchingGuards[#matchingGuards + 1] = guard
                    end
                end
                if matchingGuards ~= nil then
                    if cell == nil then
                        cell = ServerWorld.getCellForPlayer(player)
                    end
                    local square = ServerWorld.getSquare(cell, squareX, squareY, z)
                    if square and clearInvalidRoomOwnershipSquare(square) then
                        for j = 1, #matchingGuards do
                            scheduleRoomOwnershipScan(matchingGuards[j], cell)
                        end
                    end
                end
            end
        end
    end
end

local function roomOwnershipGuardKey(rvId, generation)
    return tostring(rvId) .. ":" .. tostring(generation)
end

local function registerServerRoomOwnershipGuard(generation, player, oldBounds,
    newBounds, rvId)
    if rvId == nil or tostring(rvId) == "" then
        error("RailroaderRVTest: room ownership RV identity is incomplete")
    end
    local generationNumber = ServerUtil.requiredInteger(generation,
        "room ownership generation")
    if generationNumber < 1 then
        error("RailroaderRVTest: room ownership generation is invalid")
    end
    local guard = {
        generation = generationNumber,
        rvId = tostring(rvId),
        player = player,
        oldBounds = oldBounds,
        newBounds = newBounds,
        pendingCells = {},
        scanDueTick = nil,
        nextNeighborhoodProbeTick = ctx.serverTick
            + ROOM_OWNERSHIP_3X3_INTERVAL_TICKS,
    }
    guard.key = roomOwnershipGuardKey(guard.rvId, guard.generation)
    -- One guard per RV identity, kept for that identity's lifetime: a later
    -- wall or floor removal must still be repaired after generation is READY.
    for key, existing in pairs(roomOwnershipGuards) do
        if existing.rvId == guard.rvId then
            roomOwnershipGuards[key] = nil
        end
    end
    roomOwnershipGuards[guard.key] = guard
    return guard
end

local function refreshServerRoomOwnershipGuard(guard, phase)
    local cells = relevantRoomOwnershipCells(guard, phase)
    local cleared = 0
    for i = 1, #cells do
        cleared = cleared + clearInvalidRoomOwnershipBounds(cells[i],
            guard.oldBounds)
        cleared = cleared + clearInvalidRoomOwnershipBounds(cells[i],
            guard.newBounds)
    end
    guard.pendingCells = {}
    guard.scanDueTick = nil
    if cleared > 0 then
        print("[RailroaderRVTest] room ownership refresh generation="
            .. tostring(guard.generation) .. " phase=" .. tostring(phase or "tick")
            .. " cleared=" .. tostring(cleared))
    end
    return cleared
end

local function refreshGenerationRoomOwnershipGuard(rvId, generation, phase)
    generation = ServerUtil.integer(generation)
    if type(rvId) ~= "string" or rvId == ""
        or generation == nil or generation < 1 then
        error("RailroaderRVTest: generation room ownership identity is invalid")
    end
    local guard = roomOwnershipGuards[roomOwnershipGuardKey(rvId, generation)]
    if type(guard) ~= "table" then
        error("RailroaderRVTest: generation room ownership guard is unavailable")
    end
    return refreshServerRoomOwnershipGuard(guard, phase)
end

local function processServerRoomOwnershipGuards()
    local hasGuards = false
    for _ in pairs(roomOwnershipGuards) do
        hasGuards = true
        break
    end
    if not hasGuards then return end
    -- A roof-refresh relocation deliberately moves the authoritative player
    -- far outside the RV scope.  The guard's bounds are still the RV's
    -- current geometry, so running the normal scan through that player's
    -- remote cell can make IsoCell resolve repeated cross-chunk lookups on
    -- the same tick that must advance the relocation.  The roof service
    -- already owns the boundary lease and keeps the player out of the room;
    -- pause only this non-transactional cleanup until the member returns.
    local server = type(RV) == "table" and RV.Server or nil
    if type(server) ~= "table"
        or type(server.isRoofRefreshTransactionActive) ~= "function" then
        return
    end
    local roofStateOk, roofActive = pcall(server.isRoofRefreshTransactionActive)
    if not roofStateOk or type(roofActive) ~= "boolean" or roofActive then
        return
    end
    -- Positions are read once per tick. Share each local square probe across
    -- all active generations so overlapping guards do not repeat engine calls.
    local playerStates, snapshotOk = authoritativePlayerStatesSnapshot()
    local neighborhoodDue = {}
    for _, guard in pairs(roomOwnershipGuards) do
        local nextNeighborhoodProbeTick = guard.nextNeighborhoodProbeTick
        local due = type(nextNeighborhoodProbeTick) ~= "number"
            or ctx.serverTick >= nextNeighborhoodProbeTick
        neighborhoodDue[guard] = due
        if due then
            guard.nextNeighborhoodProbeTick = ctx.serverTick
                + ROOM_OWNERSHIP_3X3_INTERVAL_TICKS
        end
    end
    if snapshotOk and #playerStates > 0 then
        clearInvalidRoomOwnershipNearPlayers(roomOwnershipGuards, playerStates,
            true, neighborhoodDue)
    end
    -- Event-triggered structure scans, merged per tick by scheduleRoomOwnershipScan.
    for _, guard in pairs(roomOwnershipGuards) do
        if guard.scanDueTick ~= nil and ctx.serverTick >= guard.scanDueTick then
            refreshServerRoomOwnershipGuard(guard, nil)
        end
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
    rvId)
    local payload = {
        generation = generation,
        rvId = tostring(rvId),
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

local function removeGeneration(cell, bounds, generation, rvId)
    if not cell or type(bounds) ~= "table"
        or ServerUtil.requiredInteger(generation, "rollback generation") < 1
        or type(rvId) ~= "string" or rvId == "" then
        error("RailroaderRVTest: rollback target identity or cell is unavailable")
    end
    local guard = roomOwnershipGuards[roomOwnershipGuardKey(rvId, generation)]
    if not guard then
        error("RailroaderRVTest: rollback room ownership guard is unavailable")
    end
    -- Failed builds are rolled back by the same owner+generation tag used by
    -- repeat generation.  This includes roof floors, generators and fixtures
    -- the final light, even when the failure occurs in the last phase.
    ServerSchema.walkBounds(cell, bounds, function(square)
        ServerWorld.clearSquare(square, generation, rvId)
    end)

    -- A successful pcall around ServerWorld.clearSquare is not enough on a dedicated
    -- server: transmitRemoveItemFromSquare owns the packet, event, local
    -- detach, and neighbour recalculation.  Verify the authoritative cell has
    -- no tagged object left before reporting rollback=COMPLETE.
    local remaining = 0
    ServerSchema.walkBounds(cell, bounds, function(square)
        local objects, complete, reason = ServerWorld.strictSquareSnapshot(square)
        if type(objects) ~= "table" or complete ~= true then
            error("RailroaderRVTest: rollback object verification is incomplete: "
                .. tostring(reason or "square snapshot failed"))
        end
        for i = 1, #objects do
            if ServerWorld.isTaggedForGeneration(objects[i], generation, rvId) then
                remaining = remaining + 1
            end
        end
    end)
    if remaining > 0 then
        error("RailroaderRVTest: rollback verification found " .. tostring(remaining)
            .. " tagged objects still present")
    end
    -- Rollback removes walls and floors, so the whole structure footprint is
    -- inspected again for a square that kept a retired room ID.
    refreshServerRoomOwnershipGuard(guard, "after-rollback")
end

-- Existing-RV entry/reconnects do not run the generation broadcast below.  Arm
-- only the corresponding client with the current manifest footprint so a fresh
-- client cannot enter a room whose IsoRoom reference may be retired later.
-- This helper intentionally accepts no client coordinates or client geometry;
-- its caller supplies the server-validated current manifest bounds.
local function armTargetedClientRoomOwnershipGuard(player, generation, newBounds,
    rvId)
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
    local payload = {
        generation = generationNumber,
        rvId = tostring(rvId),
        hasOld = false,
    }
    copyRoomRefreshBounds(payload, "new", newBounds)
    if not ServerUtil.callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_REFRESH_ROOM_OWNERSHIP, payload) then
        error("RailroaderRVTest: targeted room ownership guard could not be armed")
    end
end


ctx.notifyFailure = notifyFailure
ctx.removeGeneration = removeGeneration
ctx.requestRoomOwnershipScan = requestRoomOwnershipScan
ctx.requestRoomOwnershipRemovalScan = requestRoomOwnershipRemovalScan
ctx.registerServerRoomOwnershipGuard = registerServerRoomOwnershipGuard
ctx.refreshServerRoomOwnershipGuard = refreshServerRoomOwnershipGuard
ctx.refreshGenerationRoomOwnershipGuard = refreshGenerationRoomOwnershipGuard
ctx.processServerRoomOwnershipGuards = processServerRoomOwnershipGuards
ctx.armClientRoomOwnershipGuard = armClientRoomOwnershipGuard
ctx.armTargetedClientRoomOwnershipGuard = armTargetedClientRoomOwnershipGuard
end
