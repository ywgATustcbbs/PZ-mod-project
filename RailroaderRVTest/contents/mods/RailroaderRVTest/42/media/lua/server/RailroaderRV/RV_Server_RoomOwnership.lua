-- RV_Server: RoomOwnership responsibilities.
return function(ctx)
local RemovalTrace = require("RailroaderRV/RV_Server_ObjectRemovalTrace")
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

-- Object hooks can run before IsoRegions finishes rebuilding dynamic rooms.
-- Merge an event burst into one scan series, then make a finite delayed tail.
local ROOM_OWNERSHIP_RECHECK_DELAYS = { 1, 5, 15, 30 }
-- The server checks authoritative players' current squares each tick and
-- supplements that with a lower-frequency 3x3 neighborhood probe.
local ROOM_OWNERSHIP_3X3_INTERVAL_TICKS = 120

-- TEMPORARY PerfTrace counters for correlating RoomDef checks with CPU
-- samples. Remove after the diagnostic capture is complete.
local PERF_TRACE_WINDOW_SECONDS = 10
local function perfWindowStart()
    local ok, windowStart = pcall(function()
        if type(os) ~= "table" or type(os.time) ~= "function" then return nil end
        local now = os.time()
        if type(now) ~= "number" or now ~= now
            or now <= -math.huge or now >= math.huge then
            return nil
        end
        return math.floor(now / PERF_TRACE_WINDOW_SECONDS)
            * PERF_TRACE_WINDOW_SECONDS
    end)
    if not ok or type(windowStart) ~= "number" then return nil end
    return windowStart
end

local initialPerfWindowStart = perfWindowStart()
local perfTraceEnabled = initialPerfWindowStart ~= nil
local function perfNowMs()
    if not perfTraceEnabled then return nil end
    local ok, value = pcall(function()
        if type(getTimestampMs) == "function" then return getTimestampMs() end
        return nil
    end)
    if ok and type(value) == "number" and value == value
        and value > -math.huge and value < math.huge then
        return value
    end
    return nil
end

local perfTrace = {
    windowStart = initialPerfWindowStart,
    lastTick = 0,
    tickCalls = 0,
    guardsVisited = 0,
    probeBatches = 0,
    centerLookups = 0,
    neighborLookups = 0,
    probeLoadedSquares = 0,
    probeCleared = 0,
    fullScanCalls = 0,
    fullScanCoordinates = 0,
    fullScanLoadedSquares = 0,
    fullScanCleared = 0,
    fullScanErrors = 0,
    fullScanMsTotal = 0,
    fullScanMsMax = 0,
    fullScanTimed = 0,
}

local function recordFullScanTime(startedAt)
    if type(startedAt) ~= "number" then return end
    local finishedAt = perfNowMs()
    if type(finishedAt) ~= "number" then return end
    local elapsed = math.max(0, finishedAt - startedAt)
    perfTrace.fullScanMsTotal = perfTrace.fullScanMsTotal + elapsed
    perfTrace.fullScanMsMax = math.max(perfTrace.fullScanMsMax, elapsed)
    perfTrace.fullScanTimed = perfTrace.fullScanTimed + 1
end

local function emitRoomOwnershipPerfTrace(tick)
    if not perfTraceEnabled then return end
    local windowStart = perfWindowStart()
    if windowStart == nil then
        perfTraceEnabled = false
        return
    end
    if windowStart == perfTrace.windowStart then return end
    print("[RailroaderRVTest][PerfTrace] server/roomguard win="
        .. tostring(perfTrace.windowStart)
        .. " t=" .. tostring(tick)
        .. " ot=" .. tostring(perfTrace.tickCalls)
        .. " gv=" .. tostring(perfTrace.guardsVisited)
        .. " pb=" .. tostring(perfTrace.probeBatches)
        .. " c1=" .. tostring(perfTrace.centerLookups)
        .. " c8=" .. tostring(perfTrace.neighborLookups)
        .. " ph=" .. tostring(perfTrace.probeLoadedSquares)
        .. " pc=" .. tostring(perfTrace.probeCleared)
        .. " fs=" .. tostring(perfTrace.fullScanCalls)
        .. " xy=" .. tostring(perfTrace.fullScanCoordinates)
        .. " hit=" .. tostring(perfTrace.fullScanLoadedSquares)
        .. " clr=" .. tostring(perfTrace.fullScanCleared)
        .. " err=" .. tostring(perfTrace.fullScanErrors)
        .. " ms=" .. string.format("%.2f/%.2f/%d",
            perfTrace.fullScanMsTotal, perfTrace.fullScanMsMax,
            perfTrace.fullScanTimed))
    for key in pairs(perfTrace) do
        if key ~= "windowStart" then perfTrace[key] = 0 end
    end
    perfTrace.windowStart = windowStart
end

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

local function structureCoordinates(bounds, callback, materializedRoofCoordinates)
    if bounds == nil then return end
    if type(bounds) ~= "table" then
        error("RailroaderRVTest: room ownership bounds are not a table")
    end
    local wallMinX = ServerUtil.requiredInteger(bounds.wallMinX,
        "room ownership wallMinX")
    local wallMaxX = ServerUtil.requiredInteger(bounds.wallMaxX,
        "room ownership wallMaxX")
    local wallMinY = ServerUtil.requiredInteger(bounds.wallMinY,
        "room ownership wallMinY")
    local wallMaxY = ServerUtil.requiredInteger(bounds.wallMaxY,
        "room ownership wallMaxY")
    local z = ServerUtil.requiredInteger(bounds.z, "room ownership z")
    local roofMinX = ServerUtil.requiredInteger(bounds.roofMinX,
        "room ownership roofMinX")
    local roofMaxX = ServerUtil.requiredInteger(bounds.roofMaxX,
        "room ownership roofMaxX")
    local roofMinY = ServerUtil.requiredInteger(bounds.roofMinY,
        "room ownership roofMinY")
    local roofMaxY = ServerUtil.requiredInteger(bounds.roofMaxY,
        "room ownership roofMaxY")
    local roofZ = ServerUtil.requiredInteger(bounds.roofZ,
        "room ownership roofZ")
    if wallMinX > wallMaxX or wallMinY > wallMaxY
        or roofMinX > roofMaxX or roofMinY > roofMaxY then
        error("RailroaderRVTest: room ownership bounds are invalid")
    end
    for x = wallMinX, wallMaxX do
        for y = wallMinY, wallMaxY do callback(x, y, z) end
    end
    if materializedRoofCoordinates == nil then
        for x = roofMinX, roofMaxX do
            for y = roofMinY, roofMaxY do callback(x, y, roofZ) end
        end
    else
        for i = 1, #materializedRoofCoordinates do
            local coordinate = materializedRoofCoordinates[i]
            if type(coordinate) ~= "table" then
                error("RailroaderRVTest: materialized roof coordinate is invalid")
            end
            local x = ServerUtil.requiredInteger(coordinate.x,
                "materialized roof x")
            local y = ServerUtil.requiredInteger(coordinate.y,
                "materialized roof y")
            local z = ServerUtil.requiredInteger(coordinate.z,
                "materialized roof z")
            if x < roofMinX or x > roofMaxX or y < roofMinY or y > roofMaxY
                or z ~= roofZ then
                error("RailroaderRVTest: materialized roof coordinate is outside bounds")
            end
            callback(x, y, z)
        end
    end
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

local function clearInvalidRoomOwnershipReferences(cell, oldBounds, newBounds,
    materializedNewRoofCoordinates)
    if cell == nil or type(newBounds) ~= "table" then
        error("RailroaderRVTest: room ownership full scan inputs are incomplete")
    end
    if perfTraceEnabled then
        perfTrace.fullScanCalls = perfTrace.fullScanCalls + 1
    end
    local startedAt = perfNowMs()
    local expected, visited = {}, {}
    local expectedCoordinates = {}
    local function markExpected(x, y, z)
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if not expected[key] then
            expected[key] = true
            expectedCoordinates[#expectedCoordinates + 1] = { x = x, y = y, z = z }
        end
    end
    structureCoordinates(oldBounds, markExpected)
    structureCoordinates(newBounds, markExpected, materializedNewRoofCoordinates)

    local cleared = 0
    local function inspect(square, x, y, z)
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if visited[key] then return end
        visited[key] = true
        if clearInvalidRoomOwnershipSquare(square) then
            cleared = cleared + 1
        end
    end
    for i = 1, #expectedCoordinates do
        local coordinate = expectedCoordinates[i]
        if perfTraceEnabled then
            perfTrace.fullScanCoordinates = perfTrace.fullScanCoordinates + 1
        end
        local square = ServerWorld.getSquare(cell, coordinate.x, coordinate.y,
            coordinate.z)
        if perfTraceEnabled and square then
            perfTrace.fullScanLoadedSquares = perfTrace.fullScanLoadedSquares + 1
            inspect(square, coordinate.x, coordinate.y, coordinate.z)
        end
    end
    local expectedCount, visitedCount = 0, 0
    for _ in pairs(expected) do expectedCount = expectedCount + 1 end
    for _ in pairs(visited) do visitedCount = visitedCount + 1 end
    if visitedCount ~= expectedCount then
        if perfTraceEnabled then
            perfTrace.fullScanErrors = perfTrace.fullScanErrors + 1
        end
        recordFullScanTime(startedAt)
        error("RailroaderRVTest: room ownership scan skipped required structure squares")
    end
    if perfTraceEnabled then
        perfTrace.fullScanCleared = perfTrace.fullScanCleared + cleared
    end
    recordFullScanTime(startedAt)
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

local function scheduleRoomOwnershipScan(guard, cell)
    guard.stableSinceTick = nil
    if cell ~= nil then
        guard.pendingCells[cell] = true
    end
    if guard.scanSeriesActive then return end
    guard.scanSeriesActive = true
    guard.scanSeriesStep = 1
    guard.scanDueTick = ctx.serverTick + ROOM_OWNERSHIP_RECHECK_DELAYS[1]
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
    local traceStartedAt = RemovalTrace.begin("roomguard")
    local hit = requestRoomOwnershipScan(object, true)
    RemovalTrace.finish("roomguard", traceStartedAt, hit)
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
    if perfTraceEnabled then
        perfTrace.probeBatches = perfTrace.probeBatches + 1
    end
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
                    if perfTraceEnabled and dx == 0 and dy == 0 then
                        perfTrace.centerLookups = perfTrace.centerLookups + 1
                    elseif perfTraceEnabled then
                        perfTrace.neighborLookups = perfTrace.neighborLookups + 1
                    end
                    local square = ServerWorld.getSquare(cell, squareX, squareY, z)
                    if perfTraceEnabled and square then
                        perfTrace.probeLoadedSquares =
                            perfTrace.probeLoadedSquares + 1
                    end
                    if square and clearInvalidRoomOwnershipSquare(square) then
                        if perfTraceEnabled then
                            perfTrace.probeCleared = perfTrace.probeCleared + 1
                        end
                        for j = 1, #matchingGuards do
                            scheduleRoomOwnershipScan(matchingGuards[j], cell)
                        end
                    end
                end
            end
        end
    end
end

local function roomOwnershipGuardKey(rvId, generation, bitmapVersion)
    return tostring(rvId) .. ":" .. tostring(generation) .. ":"
        .. tostring(bitmapVersion)
end

local ROOF_COMPLETE_GENERATION_PHASES = {
    STRUCTURE_RECALC = true,
    GENERATOR = true,
    COUNTER_SINK = true,
    LIGHT = true,
    FINAL_RELOCATE = true,
    COMMITTED = true,
}

local function collectMaterializedRoofCoordinates(cell, bounds)
    local coordinates = {}
    local roofZ = ServerUtil.requiredInteger(bounds.roofZ,
        "room ownership roofZ")
    structureCoordinates(bounds, function(x, y, z)
        if z == roofZ and ServerWorld.getSquare(cell, x, y, z) then
            coordinates[#coordinates + 1] = { x = x, y = y, z = z }
        end
    end)
    return coordinates
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
        -- Before the generation roof is proven complete, refreshes require
        -- every lower structure square and only upper squares actually
        -- materialized in the transaction cell.  Old bounds stay full-scope.
        newRoofCoordinates = {},
        newRoofComplete = false,
        ticks = 0,
        totalCleared = 0,
        stableSinceTick = nil,
        pendingCells = {},
        scanSeriesActive = false,
        scanSeriesStep = 0,
        scanDueTick = nil,
        nextNeighborhoodProbeTick = ctx.serverTick
            + ROOM_OWNERSHIP_3X3_INTERVAL_TICKS,
    }
    guard.key = roomOwnershipGuardKey(guard.rvId, guard.generation, version)
    roomOwnershipGuards[guard.key] = guard
    return guard
end

local function refreshServerRoomOwnershipGuard(guard, phase, requireFullNewRoof)
    local cells = relevantRoomOwnershipCells(guard, phase)
    local cleared = 0
    local materializedRoofCoordinates
    if requireFullNewRoof == true or guard.newRoofComplete == true then
        materializedRoofCoordinates = nil
    else
        materializedRoofCoordinates = guard.newRoofCoordinates or {}
    end
    for i = 1, #cells do
        cleared = cleared + clearInvalidRoomOwnershipReferences(cells[i],
            guard.oldBounds, guard.newBounds, materializedRoofCoordinates)
    end
    if requireFullNewRoof == true then
        guard.newRoofCoordinates = nil
        guard.newRoofComplete = true
    end
    guard.totalCleared = guard.totalCleared + cleared
    if cleared == 0 then
        guard.stableSinceTick = ctx.serverTick
    else
        guard.stableSinceTick = nil
    end
    if cleared > 0 or phase ~= nil then
        print("[RailroaderRVTest] room ownership refresh generation="
            .. tostring(guard.generation) .. " phase=" .. tostring(phase or "tick")
            .. " cleared=" .. tostring(cleared))
    end
    return cleared
end

local function processServerRoomOwnershipGuards()
    emitRoomOwnershipPerfTrace(perfTrace.lastTick)
    if perfTraceEnabled then
        perfTrace.tickCalls = perfTrace.tickCalls + 1
        perfTrace.lastTick = ctx.serverTick
    end
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
    if ctx.roofRepairRelocationGroup ~= nil or ctx.roofRepairGroupFinalReturn ~= nil then
        return
    end
    -- Positions are read once per tick. Share each local square probe across
    -- all active generations so overlapping guards do not repeat engine calls.
    local playerStates, snapshotOk = authoritativePlayerStatesSnapshot()
    local neighborhoodDue = {}
    for generation, guard in pairs(roomOwnershipGuards) do
        if perfTraceEnabled then
            perfTrace.guardsVisited = perfTrace.guardsVisited + 1
        end
        guard.ticks = guard.ticks + 1
        local due = ctx.serverTick
            >= (guard.nextNeighborhoodProbeTick or 0)
        neighborhoodDue[guard] = due
        if due then
            guard.nextNeighborhoodProbeTick = ctx.serverTick
                + ROOM_OWNERSHIP_3X3_INTERVAL_TICKS
        end
    end
    if not snapshotOk then
        for _, guard in pairs(roomOwnershipGuards) do
            guard.stableSinceTick = nil
            guard.lastError = "online player snapshot or position unavailable"
        end
    elseif #playerStates > 0 then
        local probeOk, probeError = pcall(clearInvalidRoomOwnershipNearPlayers,
            roomOwnershipGuards, playerStates, true, neighborhoodDue)
        if not probeOk then
            -- An inconclusive local probe neither asserts stability nor
            -- justifies an expensive full-scope scan.
            for _, guard in pairs(roomOwnershipGuards) do
                guard.stableSinceTick = nil
                guard.lastError = safeErrorText(probeError)
            end
        end
    end
    local finished = {}
    for generation, guard in pairs(roomOwnershipGuards) do
        if guard.scanSeriesActive and ctx.serverTick >= (guard.scanDueTick or 0) then
            local ok, clearedOrError = pcall(refreshServerRoomOwnershipGuard, guard, nil)
            if not ok then
                guard.stableSinceTick = nil
                guard.lastError = safeErrorText(clearedOrError)
            elseif clearedOrError > 0 then
                guard.lastError = nil
            else
                guard.lastError = nil
            end
            guard.scanSeriesStep = guard.scanSeriesStep + 1
            local nextDelay = ROOM_OWNERSHIP_RECHECK_DELAYS[guard.scanSeriesStep]
            if nextDelay ~= nil then
                guard.scanDueTick = ctx.serverTick + nextDelay
            else
                guard.scanSeriesActive = false
                guard.scanSeriesStep = 0
                guard.scanDueTick = nil
                guard.pendingCells = {}
            end
        end
        if guard.ticks >= ROOM_OWNERSHIP_MAX_TICKS and not guard.scanSeriesActive then
            print("[RailroaderRVTest] room ownership guard expired generation="
                .. tostring(generation) .. " cleared=" .. tostring(guard.totalCleared)
                .. (guard.lastError and " error=" .. guard.lastError or ""))
            finished[#finished + 1] = generation
        elseif guard.ticks >= ROOM_OWNERSHIP_MIN_TICKS
            and not guard.scanSeriesActive and guard.stableSinceTick ~= nil
            and ctx.serverTick - guard.stableSinceTick >= ROOM_OWNERSHIP_STABLE_TICKS then
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

local function removeGeneration(cell, bounds, generation, rvId, bitmapVersion,
    generationPhase)
    if not cell or type(bounds) ~= "table" or not generation then
        return
    end
    local guard = roomOwnershipGuards[roomOwnershipGuardKey(rvId, generation,
        bitmapVersion)]
    if not guard then
        error("RailroaderRVTest: rollback room ownership guard is unavailable")
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
    -- Before ROOF_FLOOR has completed, some upper squares may not exist by
    -- design. ensureRoofSquare connects each successful square to this cell,
    -- so the remaining existing upper squares are the authoritative set that
    -- rollback must inspect. Old bounds remain a strict full scan. After the
    -- build has passed the roof loop, rollback requires the full new roof.
    local roofBuildComplete = guard.newRoofComplete == true
        or ROOF_COMPLETE_GENERATION_PHASES[generationPhase] == true
    if roofBuildComplete then
        guard.newRoofCoordinates = nil
        guard.newRoofComplete = true
    else
        guard.newRoofCoordinates = collectMaterializedRoofCoordinates(cell,
            bounds)
        guard.newRoofComplete = false
    end
    refreshServerRoomOwnershipGuard(guard, "after-rollback", roofBuildComplete)
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
ctx.requestRoomOwnershipRemovalScan = requestRoomOwnershipRemovalScan
ctx.registerServerRoomOwnershipGuard = registerServerRoomOwnershipGuard
ctx.refreshServerRoomOwnershipGuard = refreshServerRoomOwnershipGuard
ctx.processServerRoomOwnershipGuards = processServerRoomOwnershipGuards
ctx.armClientRoomOwnershipGuard = armClientRoomOwnershipGuard
ctx.removeGeneration = removeGeneration
ctx.armTargetedClientRoomOwnershipGuard = armTargetedClientRoomOwnershipGuard
end
