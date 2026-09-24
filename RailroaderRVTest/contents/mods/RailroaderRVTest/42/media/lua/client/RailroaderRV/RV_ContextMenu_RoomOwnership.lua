-- RV_ContextMenu: RoomOwnership responsibilities.
return function(ctx)
local C = ctx.C
local Layout = ctx.Layout
local roomOwnershipGuards = ctx.roomOwnershipGuards
local ROOM_OWNERSHIP_MIN_TICKS = ctx.ROOM_OWNERSHIP_MIN_TICKS
local ROOM_OWNERSHIP_REACTIVE_SCAN_INTERVAL_TICKS = 5
local ROOM_OWNERSHIP_EVENT_RESCAN_COUNT = 3
local ROOM_OWNERSHIP_EVENT_SCAN_COOLDOWN_TICKS =
    (ROOM_OWNERSHIP_EVENT_RESCAN_COUNT + 1)
        * ROOM_OWNERSHIP_REACTIVE_SCAN_INTERVAL_TICKS

-- TEMPORARY PerfTrace counters for correlating room ownership work with CPU
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
    localSquareReads = 0,
    localRoomInspections = 0,
    localCleared = 0,
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
    print("[RailroaderRVTest][PerfTrace] client/roomguard win="
        .. tostring(perfTrace.windowStart)
        .. " t=" .. tostring(tick)
        .. " gv=" .. tostring(perfTrace.guardsVisited)
        .. " lp=" .. tostring(perfTrace.localSquareReads)
        .. " li=" .. tostring(perfTrace.localRoomInspections)
        .. " lc=" .. tostring(perfTrace.localCleared)
        .. " fs=" .. tostring(perfTrace.fullScanCalls)
        .. " xy=" .. tostring(perfTrace.fullScanCoordinates)
        .. " hit=" .. tostring(perfTrace.fullScanLoadedSquares)
        .. " clr=" .. tostring(perfTrace.fullScanCleared)
        .. " err=" .. tostring(perfTrace.fullScanErrors)
        .. " ms=" .. string.format("%.2f/%.2f/%d",
            perfTrace.fullScanMsTotal, perfTrace.fullScanMsMax,
            perfTrace.fullScanTimed))
    for key, value in pairs(perfTrace) do
        if key ~= "windowStart" then perfTrace[key] = 0 end
    end
    perfTrace.windowStart = windowStart
end

local function roomOwnershipGuardKey(rvId, generation, bitmapVersion)
    return tostring(rvId) .. ":" .. tostring(generation) .. ":"
        .. tostring(bitmapVersion)
end

local finiteNumber = C.finiteNumber
local finiteInteger = C.finiteInteger

local function validRailroaderFinalHint(args)
    local generation = type(args) == "table" and finiteInteger(args.generation)
    local bitmapVersion = type(args) == "table"
        and finiteInteger(args.bitmapVersion)
    return type(args) == "table" and args.railroaderTransition == true
        and type(args.token) == "string" and args.token ~= ""
        and args.locoId ~= nil and tostring(args.locoId) ~= ""
        and args.rvId ~= nil and tostring(args.rvId) ~= ""
        and generation ~= nil and generation >= 1
        and bitmapVersion == C.BITMAP_VERSION
end

local function localPlayerByOnlineId(onlineId)
    local count = getNumActivePlayers()
    for playerNum = 0, count - 1 do
        local playerObj = getSpecificPlayer(playerNum)
        if playerObj and finiteInteger(playerObj:getOnlineID()) == onlineId then
            return playerObj
        end
    end
    return nil
end

local function readRoomRefreshBounds(args, prefix)
    local fields = {
        "wallMinX", "wallMaxX", "wallMinY", "wallMaxY",
        "roomMinX", "roomMaxX", "roomMinY", "roomMaxY",
        "roofMinX", "roofMaxX", "roofMinY", "roofMaxY", "z", "roofZ",
    }
    local bounds = {}
    for i = 1, #fields do
        local field = fields[i]
        local value = finiteInteger(args[prefix .. field])
        if value == nil then
            return nil
        end
        bounds[field] = value
    end
    if bounds.wallMinX > bounds.wallMaxX or bounds.wallMinY > bounds.wallMaxY
        or bounds.roomMinX > bounds.roomMaxX or bounds.roomMinY > bounds.roomMaxY
        or bounds.roofMinX > bounds.roofMaxX or bounds.roofMinY > bounds.roofMaxY
        or bounds.wallMaxX - bounds.wallMinX + 1 ~= 7
        or bounds.wallMaxY - bounds.wallMinY + 1 ~= 41
        or bounds.roomMaxX - bounds.roomMinX + 1 ~= 6
        or bounds.roomMaxY - bounds.roomMinY + 1 ~= 40
        or bounds.roomMinX < bounds.wallMinX
        or bounds.roomMaxX > bounds.wallMaxX
        or bounds.roomMinY < bounds.wallMinY
        or bounds.roomMaxY > bounds.wallMaxY
        or bounds.roofMaxX - bounds.roofMinX + 1 ~= 6
        or bounds.roofMaxY - bounds.roofMinY + 1 ~= 40
        or bounds.z < -32 or bounds.z > 31
        or bounds.roofZ < -32 or bounds.roofZ > 31
        or bounds.roofZ ~= bounds.z + 1 then
        return nil
    end
    return bounds
end

local function eachStructureSquare(cell, bounds, callback)
    if not cell or not bounds then
        return
    end
    Layout.eachStructureCoordinate(bounds, function(x, y, z)
        if perfTraceEnabled then
            perfTrace.fullScanCoordinates = perfTrace.fullScanCoordinates + 1
        end
        local squareOk, square = pcall(function()
            return cell:getGridSquare(x, y, z)
        end)
        if perfTraceEnabled and squareOk and square then
            perfTrace.fullScanLoadedSquares = perfTrace.fullScanLoadedSquares + 1
        end
        callback(squareOk and square or nil, x, y, z)
    end)
end

local function squareCoordinates(square)
    if not square then return nil end
    local xOk, x = pcall(function() return square:getX() end)
    local yOk, y = pcall(function() return square:getY() end)
    local zOk, z = pcall(function() return square:getZ() end)
    x, y, z = finiteInteger(x), finiteInteger(y), finiteInteger(z)
    if not xOk or not yOk or not zOk or x == nil or y == nil or z == nil then
        return nil
    end
    return x, y, z
end

local function coordinatesInBounds(x, y, z, bounds)
    return type(bounds) == "table"
        and x >= bounds.wallMinX and x <= bounds.wallMaxX
        and y >= bounds.wallMinY and y <= bounds.wallMaxY
        and z == bounds.z
        or type(bounds) == "table"
        and x >= bounds.roofMinX and x <= bounds.roofMaxX
        and y >= bounds.roofMinY and y <= bounds.roofMaxY
        and z == bounds.roofZ
end

local function inspectRoomOwnershipSquare(square)
    local roomOk, room = pcall(function() return square:getRoom() end)
    if not roomOk then return false, 0 end
    if room == nil then return true, 0 end
    local roomDefOk, roomDef = pcall(function() return square:getRoomDef() end)
    if not roomDefOk then return false, 0 end
    if roomDef ~= nil then return true, 0 end
    local resetOk = pcall(function() square:setRoomID(-1) end)
    if not resetOk then return false, 0 end
    local verifyOk, remainingRoom = pcall(function() return square:getRoom() end)
    if not verifyOk or remainingRoom ~= nil then return false, 0 end
    return true, 1
end

local function refreshInvalidRoomOwnership(guard)
    if perfTraceEnabled then
        perfTrace.fullScanCalls = perfTrace.fullScanCalls + 1
    end
    local startedAt = perfNowMs()
    local cell = getCell()
    if not cell then
        if perfTraceEnabled then
            perfTrace.fullScanErrors = perfTrace.fullScanErrors + 1
        end
        recordFullScanTime(startedAt)
        return false, 0
    end
    local scanOk = true
    local coverageComplete = true
    local cleared = 0
    local seen = {}
    local function inspect(square, x, y, z)
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if seen[key] then return end
        seen[key] = true
        if not square then
            coverageComplete = false
            return
        end
        local inspected, reset = inspectRoomOwnershipSquare(square)
        if not inspected then
            scanOk = false
            return
        end
        cleared = cleared + reset
    end
    eachStructureSquare(cell, guard.oldBounds, inspect)
    eachStructureSquare(cell, guard.newBounds, inspect)
    if perfTraceEnabled and (not scanOk or not coverageComplete) then
        perfTrace.fullScanErrors = perfTrace.fullScanErrors + 1
    end
    if perfTraceEnabled then
        perfTrace.fullScanCleared = perfTrace.fullScanCleared + cleared
    end
    recordFullScanTime(startedAt)
    return scanOk and coverageComplete, cleared
end

local function refreshCurrentPlayerRoomOwnership(guard)
    if type(getNumActivePlayers) ~= "function"
        or type(getSpecificPlayer) ~= "function" then
        return true, 0
    end
    local countOk, count = pcall(getNumActivePlayers)
    if not countOk or type(count) ~= "number" then return false, 0 end
    local seen = {}
    local scanOk, cleared = true, 0
    for playerNum = 0, count - 1 do
        local playerOk, player = pcall(getSpecificPlayer, playerNum)
        if playerOk and player and type(player.getCurrentSquare) == "function" then
            if perfTraceEnabled then
                perfTrace.localSquareReads = perfTrace.localSquareReads + 1
            end
            local squareOk, square = pcall(function()
                return player:getCurrentSquare()
            end)
            if not squareOk then
                scanOk = false
            elseif square then
                local x, y, z = squareCoordinates(square)
                if x and (coordinatesInBounds(x, y, z, guard.oldBounds)
                    or coordinatesInBounds(x, y, z, guard.newBounds)) then
                    local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
                    if not seen[key] then
                        seen[key] = true
                        if perfTraceEnabled then
                            perfTrace.localRoomInspections =
                                perfTrace.localRoomInspections + 1
                        end
                        local inspected, reset = inspectRoomOwnershipSquare(square)
                        if not inspected then
                            scanOk = false
                        else
                            cleared = cleared + reset
                            if perfTraceEnabled then
                                perfTrace.localCleared =
                                    perfTrace.localCleared + reset
                            end
                        end
                    end
                end
            end
        end
    end
    return scanOk, cleared
end

local function objectCoordinates(object)
    if not object then return nil end
    local target = object
    if type(object.getSquare) == "function" then
        local squareOk, square = pcall(function() return object:getSquare() end)
        if squareOk and square then target = square end
    end
    return squareCoordinates(target)
end

local function scheduleRoomOwnershipScan(guard, delayedRetries)
    local delayedRetryCount = delayedRetries or 0
    local allowGuardScan = true
    if delayedRetryCount > 0 then
        local cooldownUntil = guard.eventScanCooldownUntil or -1
        if ctx.clientTick <= cooldownUntil then
            allowGuardScan = false
        else
            -- Object callbacks in this fixed window merge into one bounded
            -- delayed-recheck batch; later callbacks cannot refill its budget.
            guard.eventScanCooldownUntil = ctx.clientTick
                + ROOM_OWNERSHIP_EVENT_SCAN_COOLDOWN_TICKS
        end
    end

    if allowGuardScan then
        local nextTick = ctx.clientTick + 1
        if guard.lastReactiveScanTick ~= nil then
            nextTick = math.max(nextTick,
                guard.lastReactiveScanTick
                    + ROOM_OWNERSHIP_REACTIVE_SCAN_INTERVAL_TICKS)
        end

        local retries = guard.scanRetryRemaining or 0
        local scanPending = guard.scanRequested == true or retries > 0
        if not scanPending then
            guard.scanRetryRemaining = delayedRetryCount
        elseif retries == 0 and delayedRetryCount > 0 then
            guard.scanRetryRemaining = delayedRetryCount
        end

        guard.scanRequested = true
        if guard.nextScanTick == nil or nextTick < guard.nextScanTick then
            guard.nextScanTick = nextTick
        end
    end

    -- If the bounded transaction scan window was exhausted while client
    -- chunks were still arriving, a later matching world/local trigger opens
    -- one fresh bounded window. Unloaded data alone never counts as success.
    local pendingFinal = ctx.pendingFinalRelocation
    local args = type(pendingFinal) == "table" and pendingFinal.args
    local pendingPhase = pendingFinal
        and (pendingFinal.teleported and "post" or "pre")
    local triggerRetryKey = pendingPhase
        and (pendingPhase .. "TriggerRetryUsed")
    if type(args) == "table" and pendingFinal.failed == true
        and pendingFinal.failedPhase == pendingPhase
        and pendingFinal[triggerRetryKey] ~= true
        and tostring(args.rvId) == tostring(guard.rvId)
        and finiteInteger(args.generation) == guard.generation
        and finiteInteger(args.bitmapVersion) == guard.bitmapVersion then
        pendingFinal.failed = false
        pendingFinal.failedPhase = nil
        pendingFinal[triggerRetryKey] = true
        pendingFinal[pendingPhase .. "ScanAttempts"] = 0
        pendingFinal[pendingPhase .. "NextScanTick"] = ctx.clientTick
        print("[RailroaderRVTest] final relocation " .. pendingPhase
            .. " room scan resumed after a matching repair trigger")
    end
end

local function requestRoomOwnershipScan(object)
    local x, y, z = objectCoordinates(object)
    if x == nil then return end
    for _, guard in pairs(roomOwnershipGuards) do
        if coordinatesInBounds(x, y, z, guard.oldBounds)
            or coordinatesInBounds(x, y, z, guard.newBounds) then
            scheduleRoomOwnershipScan(guard, ROOM_OWNERSHIP_EVENT_RESCAN_COUNT)
        end
    end
end

local function beginRoomOwnershipRefresh(args)
    local rvId = args.rvId
    local generation = finiteInteger(args.generation)
    local bitmapVersion = finiteInteger(args.bitmapVersion)
    local newBounds = readRoomRefreshBounds(args, "new")
    if rvId == nil or tostring(rvId) == "" or generation == nil
        or generation < 1 or bitmapVersion ~= C.BITMAP_VERSION
        or newBounds == nil
        or args.hasOld ~= true and args.hasOld ~= false then
        return
    end
    local oldBounds = nil
    if args.hasOld == true then
        oldBounds = readRoomRefreshBounds(args, "old")
        if oldBounds == nil then return end
    end
    local key = roomOwnershipGuardKey(rvId, generation, bitmapVersion)
    -- A current generation packet contains the authoritative previous/current
    -- footprints needed for this swap.  Retain monitors for other RV IDs, but
    -- do not keep a prior generation's geometry alive after this identity has
    -- been accepted; that would turn old bounds into a permanent client path.
    for existingKey, existingGuard in pairs(roomOwnershipGuards) do
        if existingKey ~= key
            and tostring(existingGuard.rvId) == tostring(rvId) then
            roomOwnershipGuards[existingKey] = nil
        end
    end
    roomOwnershipGuards[key] = {
        key = key,
        rvId = tostring(rvId),
        generation = generation,
        bitmapVersion = bitmapVersion,
        oldBounds = oldBounds,
        newBounds = newBounds,
        ticks = 0,
        totalCleared = 0,
        monitorReady = false,
        scanRequested = false,
        scanRetryRemaining = 0,
        currentCheckErrorLatched = false,
        eventScanCooldownUntil = -1,
    }
    -- Arm immediately, before any ordered removal/rebuild packets that follow
    -- this broadcast server command are applied.
    local guard = roomOwnershipGuards[key]
    local scanOk, cleared = refreshInvalidRoomOwnership(guard)
    guard.totalCleared = cleared
    guard.lastFullScanComplete = scanOk
    guard.lastReactiveScanTick = ctx.clientTick
    if not scanOk then
        -- This packet can arrive before client chunks or IsoRegions are ready.
        -- Retry only this incomplete setup a bounded number of times; there is
        -- no recurring whole-footprint timer.
        guard.scanRequested = true
        guard.scanRetryRemaining = 2
        guard.nextScanTick = ctx.clientTick
            + ROOM_OWNERSHIP_REACTIVE_SCAN_INTERVAL_TICKS
    end
end

local function finalTargetSquare(x, y, z)
    local cell = getCell()
    if not cell then
        return nil
    end
    local squareCallOk, square = pcall(function()
        return cell:getGridSquare(math.floor(x), math.floor(y), z)
    end)
    if not squareCallOk then
        return nil
    end
    return square
end

local function finalTargetSquareIsLoaded(x, y, z)
    return finalTargetSquare(x, y, z) ~= nil
end

local function finalTargetRoomIsValid(x, y, z)
    local square = finalTargetSquare(x, y, z)
    if not square then
        -- The server waits for the complete footprint, but the client may
        -- still be streaming its local cell. Keep the player at staging and
        -- retry the synchronous check on a later command/tick.
        return false
    end
    local roomCallOk, room = pcall(function()
        return square:getRoom()
    end)
    if not roomCallOk then
        return false
    end
    if room == nil then
        return true
    end
    local roomDefCallOk, roomDef = pcall(function()
        return square:getRoomDef()
    end)
    if not roomDefCallOk then
        return false
    end
    if roomDef ~= nil then
        return true
    end
    local resetCallOk = pcall(function()
        square:setRoomID(-1)
    end)
    if not resetCallOk then
        return false
    end
    local verifyCallOk, remainingRoom = pcall(function()
        return square:getRoom()
    end)
    return verifyCallOk and remainingRoom == nil
end

local function updateRoomOwnershipGuards()
    emitRoomOwnershipPerfTrace(perfTrace.lastTick)
    if perfTraceEnabled then
        perfTrace.tickCalls = perfTrace.tickCalls + 1
        perfTrace.lastTick = ctx.clientTick
    end
    for generation, guard in pairs(roomOwnershipGuards) do
        if perfTraceEnabled then
            perfTrace.guardsVisited = perfTrace.guardsVisited + 1
        end
        guard.ticks = guard.ticks + 1
        local currentScanOk, currentCleared = refreshCurrentPlayerRoomOwnership(guard)
        if not currentScanOk then
            if not guard.currentCheckErrorLatched then
                guard.currentCheckErrorLatched = true
                scheduleRoomOwnershipScan(guard, 0)
                print("[RailroaderRVTest] client current-square room check failed; "
                    .. "queued one full scan generation="
                    .. tostring(generation))
            end
        else
            -- A successful local check rearms edge detection for a future,
            -- separate API failure. A persistent failure cannot queue a sweep
            -- on every tick.
            guard.currentCheckErrorLatched = false
        end
        if currentScanOk and currentCleared > 0 then
            scheduleRoomOwnershipScan(guard, 0)
        end
        if guard.scanRequested
            and ctx.clientTick >= (guard.nextScanTick or 0) then
            guard.scanRequested = false
            local scanOk, cleared = refreshInvalidRoomOwnership(guard)
            guard.totalCleared = guard.totalCleared + cleared
            guard.lastFullScanComplete = scanOk
            guard.lastReactiveScanTick = ctx.clientTick
            if (guard.scanRetryRemaining or 0) > 0 then
                guard.scanRetryRemaining = guard.scanRetryRemaining - 1
                guard.scanRequested = true
                guard.nextScanTick = ctx.clientTick
                    + ROOM_OWNERSHIP_REACTIVE_SCAN_INTERVAL_TICKS
            else
                guard.nextScanTick = nil
            end
        end
        -- Keep the guard for the lifetime of this identity: a later wall or
        -- floor change can invalidate a room after generation has been READY.
        -- The current-square check runs each tick; full scans are scheduled
        -- only by a local repair/error or a relevant object event.
        if not guard.monitorReady
            and guard.ticks >= ROOM_OWNERSHIP_MIN_TICKS then
            guard.monitorReady = true
            print("[RailroaderRVTest] client room ownership guard active generation="
                .. tostring(generation) .. " cleared=" .. tostring(guard.totalCleared))
        end
    end
end


ctx.roomOwnershipGuardKey = roomOwnershipGuardKey
ctx.validRailroaderFinalHint = validRailroaderFinalHint
ctx.localPlayerByOnlineId = localPlayerByOnlineId
ctx.refreshInvalidRoomOwnership = refreshInvalidRoomOwnership
ctx.requestRoomOwnershipScan = requestRoomOwnershipScan
ctx.beginRoomOwnershipRefresh = beginRoomOwnershipRefresh
ctx.finalTargetSquareIsLoaded = finalTargetSquareIsLoaded
ctx.finalTargetRoomIsValid = finalTargetRoomIsValid
ctx.updateRoomOwnershipGuards = updateRoomOwnershipGuards
ctx.finiteNumber = finiteNumber
ctx.finiteInteger = finiteInteger
end
