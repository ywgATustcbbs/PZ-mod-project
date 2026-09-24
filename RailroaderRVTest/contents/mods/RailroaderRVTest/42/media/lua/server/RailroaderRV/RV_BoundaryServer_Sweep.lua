-- RV_BoundaryServer: Sweep responsibilities.
return function(ctx)
local Boundary = ctx.Boundary
local C = ctx.C
local integer = ctx.integer
local call = ctx.call
local callGlobal = ctx.callGlobal
local identity = ctx.identity
local playerCell = ctx.playerCell
local square = ctx.square
local boundaryKey = ctx.boundaryKey
local sameBoundary = ctx.sameBoundary
local transitionActive = ctx.transitionActive
local updatePlayer = ctx.updatePlayer
local playerPosition = ctx.playerPosition

-- TEMPORARY PerfTrace counters for correlating server cleanup with CPU
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
    onTick = 0,
    cleanupBatches = 0,
    cellLookups = 0,
    loadedSquares = 0,
    unloadedStops = 0,
    objectsAudited = 0,
    cleanupMsTotal = 0,
    cleanupMsMax = 0,
    cleanupTimed = 0,
}

local function finishCleanupTiming(startedAt)
    if type(startedAt) ~= "number" then return end
    local finishedAt = perfNowMs()
    if type(finishedAt) ~= "number" then return end
    local elapsed = math.max(0, finishedAt - startedAt)
    perfTrace.cleanupMsTotal = perfTrace.cleanupMsTotal + elapsed
    perfTrace.cleanupMsMax = math.max(perfTrace.cleanupMsMax, elapsed)
    perfTrace.cleanupTimed = perfTrace.cleanupTimed + 1
end

local function emitBoundaryPerfTrace(tick)
    if not perfTraceEnabled then return end
    local windowStart = perfWindowStart()
    if windowStart == nil then
        perfTraceEnabled = false
        return
    end
    if windowStart == perfTrace.windowStart then return end
    print("[RailroaderRVTest][PerfTrace] server/boundary win="
        .. tostring(perfTrace.windowStart)
        .. " t=" .. tostring(tick)
        .. " ot=" .. tostring(perfTrace.onTick)
        .. " cb=" .. tostring(perfTrace.cleanupBatches)
        .. " sq=" .. tostring(perfTrace.cellLookups)
        .. " hit=" .. tostring(perfTrace.loadedSquares)
        .. " miss=" .. tostring(perfTrace.unloadedStops)
        .. " obj=" .. tostring(perfTrace.objectsAudited)
        .. " ms=" .. string.format("%.2f/%.2f/%d",
            perfTrace.cleanupMsTotal, perfTrace.cleanupMsMax,
            perfTrace.cleanupTimed))
    for key in pairs(perfTrace) do
        if key ~= "windowStart" then perfTrace[key] = 0 end
    end
    perfTrace.windowStart = windowStart
end

local function collectionSnapshot(collection)
    local result = {}
    if collection == nil then return result end
    local sizeOk, size = call(collection, "size")
    size = sizeOk and integer(size) or nil
    if size ~= nil then
        for i = 0, size - 1 do
            local ok, object = call(collection, "get", i)
            if ok and object then result[#result + 1] = object end
        end
    elseif type(collection) == "table" then
        for _, object in pairs(collection) do
            if object then result[#result + 1] = object end
        end
    end
    return result
end

local function squareObjects(square)
    local result, seen = {}, {}
    local names = { "getObjects", "getSpecialObjects", "getWorldObjects",
        "getStaticMovingObjects", "getMovingObjects", "getDeadBodys" }
    for i = 1, #names do
        local ok, collection = call(square, names[i])
        if ok then
            for _, object in ipairs(collectionSnapshot(collection)) do
                if not seen[object] then seen[object] = true; result[#result + 1] = object end
            end
        end
    end
    local floorOk, floor = call(square, "getFloor")
    if floorOk and floor and not seen[floor] then result[#result + 1] = floor end
    return result
end

local function flushDirty()
    local deferred = {}
    for key, action in pairs(Boundary._dirty) do
        Boundary._dirty[key] = nil
        local cell = playerCell(action.player)
        local current, status = Boundary.boundaryForPlayer(action.player,
            action.identity, true)
        if status == "validation-deferred" then
            deferred[key] = action
        end
        if cell and action.boundary and action.identity
            and sameBoundary(current, action.boundary) then
            local sq = square(cell, action.x, action.y, action.z)
            if sq then
                for _, object in ipairs(squareObjects(sq)) do
                    Boundary.auditObject(object, action.player, action.boundary)
                end
            end
        end
    end
    for key, action in pairs(deferred) do
        Boundary._dirty[key] = Boundary._dirty[key] or action
    end
end

local function onlinePlayersSnapshot()
    local result = {}
    local ok, players = callGlobal("getOnlinePlayers")
    if ok and players then
        local sizeOk, size = call(players, "size")
        size = sizeOk and integer(size) or nil
        if size ~= nil then
            for i = 0, size - 1 do
                local playerOk, player = call(players, "get", i)
                if playerOk and player then result[#result + 1] = player end
            end
        elseif type(players) == "table" then
            for _, player in pairs(players) do if player then result[#result + 1] = player end end
        end
    end
    if #result == 0 then
        local playerOk, player = callGlobal("getPlayer")
        if player then result[1] = player end
    end
    return result
end

local function cleanupForBoundary(boundary, player)
    local key = boundaryKey(boundary)
    local cursor = Boundary._cleanups[key]
    if cursor and cursor.completedTick ~= nil then
        local rescanTicks = integer(C.BOUNDARY_CLEANUP_RESCAN_TICKS) or 600
        if Boundary._tick - cursor.completedTick < rescanTicks then
            cursor.player = player
            cursor.boundary = boundary
            return
        end
        cursor.x, cursor.y, cursor.z = boundary.bitmap.originX,
            boundary.bitmap.originY, boundary.bitmap.minZ
        cursor.completedTick = nil
    elseif not cursor then
        cursor = { player = player, boundary = boundary,
            x = boundary.bitmap.originX, y = boundary.bitmap.originY,
            z = boundary.bitmap.minZ, completedTick = nil }
        Boundary._cleanups[key] = cursor
    else
        -- Any online member of this RV can provide the authoritative cell;
        -- do not restart a shared cursor when player iteration order changes.
        cursor.player = player
        cursor.boundary = boundary
    end
    local cell = playerCell(player)
    if not cell then return end
    local budget = integer(C.BOUNDARY_CLEANUP_SQUARES_PER_STEP) or 64
    local bitmap = boundary.bitmap
    local startedAt = perfNowMs()
    if perfTraceEnabled then
        perfTrace.cleanupBatches = perfTrace.cleanupBatches + 1
    end
    while budget > 0 and cursor.z < bitmap.maxZ do
        if cursor.y >= bitmap.originY + bitmap.height then
            cursor.x, cursor.y = bitmap.originX, bitmap.originY
            cursor.z = cursor.z + 1
        elseif cursor.x >= bitmap.originX + bitmap.width then
            cursor.x, cursor.y = bitmap.originX, cursor.y + 1
        else
            if perfTraceEnabled then
                perfTrace.cellLookups = perfTrace.cellLookups + 1
            end
            local sq = square(cell, cursor.x, cursor.y, cursor.z)
            -- Leave the cursor on an unloaded square.  Advancing past it would
            -- make the bounded cleanup silently skip that cell forever, while
            -- forcing a load would violate the RV-local, already-loaded-only
            -- cleanup contract.
            if not sq then
                if perfTraceEnabled then
                    perfTrace.unloadedStops = perfTrace.unloadedStops + 1
                end
                finishCleanupTiming(startedAt)
                return
            end
            if perfTraceEnabled then
                perfTrace.loadedSquares = perfTrace.loadedSquares + 1
            end
            local objects = squareObjects(sq)
            if perfTraceEnabled then
                perfTrace.objectsAudited = perfTrace.objectsAudited + #objects
            end
            for _, object in ipairs(objects) do
                Boundary.auditObject(object, nil, boundary)
            end
            cursor.x = cursor.x + 1
            budget = budget - 1
        end
    end
    if cursor.z >= bitmap.maxZ then
        cursor.completedTick = Boundary._tick
    end
    finishCleanupTiming(startedAt)
end

function Boundary.onTick()
    emitBoundaryPerfTrace(Boundary._tick)
    Boundary._tick = Boundary._tick + 1
    if perfTraceEnabled then perfTrace.onTick = perfTrace.onTick + 1 end
    local players = onlinePlayersSnapshot()
    local cleanupInterval = integer(C.BOUNDARY_TICK_INTERVAL) or 1
    local activeBoundaries = Boundary._tick % cleanupInterval == 0 and {} or nil
    for i = 1, #players do
        local player = players[i]
        local position = playerPosition(player)
        if position then
            local id = identity(player)
            if id then
                local state = Boundary._states[id.key]
                if state then state.identity = id end
                -- Roof relocation owns the player's boundary lease while the
                -- authoritative object is intentionally in a different chunk.
                -- Do not revalidate RV geometry or run cleanup through the remote
                -- player's cell; those scans can stall the server tick before the
                -- grouped roof state machine reaches its due ticks.  The lease is
                -- extended by RV_Server before this callback and normal boundary
                -- processing resumes after completeTransition.
                if not state or not transitionActive(state) then
                    local boundary = updatePlayer(player, position, id, true)
                    if boundary and activeBoundaries then
                        activeBoundaries[boundaryKey(boundary)] = {
                            boundary = boundary, player = player,
                        }
                    end
                end
            end
        end
    end
    flushDirty()
    if activeBoundaries then
        for _, item in pairs(activeBoundaries) do cleanupForBoundary(item.boundary, item.player) end
    end
    for key, builder in pairs(Boundary._builders) do
        if not builder or Boundary._tick > (builder.expires or 0) then
            Boundary._builders[key] = nil
        end
    end
end


end
