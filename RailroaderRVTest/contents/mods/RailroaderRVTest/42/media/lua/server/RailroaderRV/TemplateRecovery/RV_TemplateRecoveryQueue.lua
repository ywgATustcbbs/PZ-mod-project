-- TemplateRecoveryQueue owns player sampling, FIFO scheduling, tick quota, and
-- the pause lifecycle around Boundary transitions. It delegates repair work.
-- The Boundary sweep calls onPostPlayerTick directly after it has validated the
-- active players and boundaries; this module registers no callback and the
-- published instance is looked up at runtime through RailroaderRV.RecoveryQueue.
local instance = nil
return function(ctx)
if instance then
    -- A later require carries the live script instance's context table; keep the
    -- published entry reading services from there.
    instance.ctx = ctx
    return instance
end
local Boundary = ctx.Boundary
local Core = ctx.Core
local Constants = ctx.Constants
local ServerUtil = ctx.ServerUtil
local Index = require("RailroaderRV/TemplateRecovery/RV_TemplateRecoveryIndex")(ctx)

local queues = {}
local reportedFailures = {}
local transitionPauseUntil = {}
local transitionWasActive = {}
local lastServedQueueKey = nil
local sampleInterval = ServerUtil.toNumber(
    Constants.TEMPLATE_PROTECTION_REPAIR_SAMPLE_INTERVAL_TICKS)
if not sampleInterval or sampleInterval < 1
    or math.floor(sampleInterval) ~= sampleInterval then
    error("RailroaderRVTest: proximity template-guard limits are invalid")
end
local transitionReturnGraceTicks = 100

if type(Boundary) ~= "table"
    or type(Boundary.transitionActive) ~= "function"
    or type(Index.validCurrentContext) ~= "function"
    or type(Index.queueKey) ~= "function" then
    error("RailroaderRVTest: template-recovery queue dependencies are incomplete")
end

local function clearQueuedIdentity(identityKey)
    if type(identityKey) ~= "string" then return end
    queues[identityKey] = nil
    reportedFailures[identityKey] = nil
end

-- A live transition lease pauses repair for that identity; after the lease ends
-- the bounded grace recorded in transitionPauseUntil keeps it paused while the
-- relocation return settles.
local function isIdentityPaused(identityKey, tick)
    if type(identityKey) ~= "string" then return false end
    if Boundary.transitionActive(identityKey) then return true end
    if type(tick) ~= "number" then return false end
    local untilTick = transitionPauseUntil[identityKey]
    if type(untilTick) ~= "number" then return false end
    if untilTick >= tick then return true end
    transitionPauseUntil[identityKey] = nil
    return false
end

-- Edge detection for one identity: a live lease is observed, and the tick it
-- disappears is the tick the bounded return grace starts.  The queue is dropped
-- either way so relocation-frame sampling cannot survive the transition.
local function trackTransitionEnd(identityKey, tick)
    if type(identityKey) ~= "string" then return end
    if Boundary.transitionActive(identityKey) then
        transitionWasActive[identityKey] = true
        transitionPauseUntil[identityKey] = nil
        clearQueuedIdentity(identityKey)
        return
    end
    if transitionWasActive[identityKey] ~= true then return end
    transitionWasActive[identityKey] = nil
    local requestedUntil = tick + transitionReturnGraceTicks
    local previousUntil = transitionPauseUntil[identityKey]
    if type(previousUntil) ~= "number" or requestedUntil > previousUntil then
        transitionPauseUntil[identityKey] = requestedUntil
    end
    clearQueuedIdentity(identityKey)
end

local function purgePreviousGenerations(rvId, currentKey)
    local id = tostring(rvId)
    for key, queue in pairs(queues) do
        if queue.rvId == id and key ~= currentKey then
            queues[key] = nil
            reportedFailures[key] = nil
        end
    end
    local prefix = id .. ":"
    for key in pairs(reportedFailures) do
        if string.sub(key, 1, #prefix) == prefix and key ~= currentKey then
            reportedFailures[key] = nil
        end
    end
    Index.purgeOtherGenerations(id, currentKey)
end

local function compactQueue(queue)
    if queue.head <= 64 or queue.head <= queue.tail / 2 then return end
    local compacted = {}
    local count = 0
    for i = queue.head, queue.tail do
        local entry = queue.entries[i]
        if entry then
            count = count + 1
            compacted[count] = entry
        end
    end
    queue.entries, queue.head, queue.tail = compacted, 1, count
end

local function enqueueXY(queue, x, y)
    local tileKey = tostring(x) .. ":" .. tostring(y)
    if queue.pending[tileKey] then return end
    queue.tail = queue.tail + 1
    queue.entries[queue.tail] = { x = x, y = y, key = tileKey }
    queue.pending[tileKey] = true
    queue.count = queue.count + 1
end

local function samplePlayer(expectedBoundary, player)
    pcall(function()
        if player == nil or type(expectedBoundary) ~= "table" then return end
        local key = Index.identityKey(expectedBoundary.rvId,
            expectedBoundary.generation)
        if not key then return end
        local xOk, playerX = ServerUtil.invoke(player, "getX")
        local yOk, playerY = ServerUtil.invoke(player, "getY")
        playerX, playerY = xOk and ServerUtil.toNumber(playerX),
            yOk and ServerUtil.toNumber(playerY)
        if not playerX or not playerY then return end
        local centerX, centerY = math.floor(playerX), math.floor(playerY)
        purgePreviousGenerations(expectedBoundary.rvId, key)
        local queue = queues[key]
        if not queue then
            queue = { rvId = tostring(expectedBoundary.rvId), entries = {},
                head = 1, tail = 0, pending = {}, count = 0 }
            queues[key] = queue
        end
        for offsetY = -1, 1 do
            for offsetX = -1, 1 do
                enqueueXY(queue, centerX + offsetX, centerY + offsetY)
            end
        end
    end)
    return true
end

local function popXY(queue)
    local entry = queue.entries[queue.head]
    if not entry then return nil end
    queue.entries[queue.head] = nil
    queue.head = queue.head + 1
    queue.pending[entry.key] = nil
    queue.count = queue.count - 1
    compactQueue(queue)
    return entry
end

local function restoreThroughConstruction(player, boundary, x, y)
    -- The construction service is published on the live script instance while
    -- RV_Server loads, so resolve it per call instead of capturing a snapshot.
    local liveCtx = instance and instance.ctx or ctx
    local rv = type(liveCtx.RV) == "table" and liveCtx.RV
        or rawget(_G, "RailroaderRV")
    local server = type(rv) == "table" and rv.Server or nil
    local construction = type(server) == "table" and server.Construction or nil
    if type(construction) ~= "table"
        or type(construction.restoreCurrentCell) ~= "function" then
        return false, "current Construction restore service is unavailable"
    end
    return construction.restoreCurrentCell(player, boundary, x, y)
end

local function processQueue(activeBoundaries, tick)
    if type(activeBoundaries) ~= "table" then
        return false, "active RV boundary list is unavailable"
    end
    local ready = {}
    for _, item in pairs(activeBoundaries) do
        if type(item) == "table" and item.boundary and item.player then
            local contextCallOk, contextOk, boundary, record = pcall(
                Index.validCurrentContext, item.player, item.boundary)
            if not contextCallOk then contextOk = false end
            if contextOk then
                local key = Index.queueKey(boundary, record)
                if key then
                    trackTransitionEnd(key, tick)
                    if isIdentityPaused(key, tick) then
                        -- A live lease and its return grace both own the queue.
                        clearQueuedIdentity(key)
                    else
                        purgePreviousGenerations(boundary.rvId, key)
                        local queue = queues[key]
                        if queue and queue.count > 0 then
                            ready[#ready + 1] = { key = key, queue = queue,
                                boundary = boundary, player = item.player }
                        end
                    end
                end
            else
                local staleBoundary = item.boundary
                local staleKey = type(staleBoundary) == "table"
                    and Index.identityKey(staleBoundary.rvId,
                        staleBoundary.generation) or nil
                if staleKey then
                    clearQueuedIdentity(staleKey)
                    Index.clear(staleKey)
                end
            end
        end
    end
    -- Removal-trace pruning belongs to the live script instance's context, which
    -- a cached instance only sees through the refreshed `instance.ctx`.
    local liveCtx = instance and instance.ctx or ctx
    if type(liveCtx.pruneTemplateProtectionRemovalTrace) == "function" then
        pcall(liveCtx.pruneTemplateProtectionRemovalTrace, tick)
    end
    if #ready == 0 then return false end
    table.sort(ready, function(left, right) return left.key < right.key end)
    local selected = ready[1]
    if lastServedQueueKey then
        for i = 1, #ready do
            if ready[i].key > lastServedQueueKey then
                selected = ready[i]
                break
            end
        end
    end
    lastServedQueueKey = selected.key
    local entry = popXY(selected.queue)
    if selected.queue.count == 0 then queues[selected.key] = nil end
    if not entry then
        return false, "template-protection repair queue entry is unavailable"
    end
    local callOk, repaired, reason = pcall(restoreThroughConstruction,
        selected.player, selected.boundary, entry.x, entry.y)
    if not callOk or repaired ~= true then
        local failure = tostring(callOk and reason or repaired)
        local failures = reportedFailures[selected.key]
        if type(failures) ~= "table" then
            failures = {}
            reportedFailures[selected.key] = failures
        end
        if not failures[entry.key] then
            failures[entry.key] = true
            print("[RailroaderRVTest] template-protection repair failed at "
                .. tostring(entry.x) .. "," .. tostring(entry.y)
                .. ": " .. failure)
        end
        return false, failure
    end
    return true
end

local function onPostPlayerTick(tick, activePlayers, activeBoundaries)
    if type(tick) ~= "number" then
        return false, "invalid boundary tick"
    end
    if type(Core) ~= "table" or type(Core.tickModulo) ~= "function" then
        return false, "server tick clock is unavailable"
    end
    if Core.tickModulo(sampleInterval)
        and type(activePlayers) == "table" then
        for i = 1, #activePlayers do
            local item = activePlayers[i]
            local boundary = type(item) == "table" and item.boundary or nil
            local key = type(boundary) == "table"
                and Index.identityKey(boundary.rvId, boundary.generation) or nil
            if not key or not isIdentityPaused(key, tick) then
                local callOk, sampled, reason = pcall(samplePlayer, boundary,
                    item and item.player)
                if not callOk or sampled ~= true then
                    print("[RailroaderRVTest] template-protection-repair player sampling skipped: "
                        .. tostring(callOk and reason or sampled))
                end
            end
        end
    end

    -- One queued XY tile is checked globally per server tick.
    local callOk, processed, reason = pcall(processQueue, activeBoundaries, tick)
    if not callOk or processed ~= true and reason ~= nil then
        print("[RailroaderRVTest] template-protection-repair queue step skipped: "
            .. tostring(callOk and reason or processed))
    end
    return true
end

instance = {
    onPostPlayerTick = onPostPlayerTick,
    ctx = ctx,
}
RailroaderRV = RailroaderRV or {}
RailroaderRV.RecoveryQueue = instance
return instance
end
