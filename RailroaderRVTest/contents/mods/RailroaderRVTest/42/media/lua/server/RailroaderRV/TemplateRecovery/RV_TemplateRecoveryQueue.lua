-- TemplateRecoveryQueue owns player sampling, FIFO scheduling, tick quota, and
-- the pause lifecycle around Boundary transitions. It delegates repair work.
return function(ctx)
local Boundary = ctx.Boundary
local Core = ctx.Core
local Constants = ctx.Constants
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local Index = require("RailroaderRV/TemplateRecovery/RV_TemplateRecoveryIndex")(ctx)

local queues = {}
local reportedFailures = {}
local transitionPauseUntil = {}
local previousActiveTransitions = {}
local lastServedQueueKey = nil
local sampleInterval = ServerUtil.toNumber(
    Constants.TEMPLATE_PROTECTION_REPAIR_SAMPLE_INTERVAL_TICKS)
if not sampleInterval or sampleInterval < 1
    or math.floor(sampleInterval) ~= sampleInterval then
    error("RailroaderRVTest: proximity template-guard limits are invalid")
end
local transitionReturnGraceTicks = 100

if type(Boundary) ~= "table"
    or type(Boundary.addTransitionLifecycleListener) ~= "function"
    or type(Boundary.transitionActivitySnapshot) ~= "function"
    or type(Boundary.addPostPlayerTickHandler) ~= "function"
    or type(Index.validCurrentContext) ~= "function"
    or type(Index.queueKey) ~= "function" then
    error("RailroaderRVTest: template-recovery queue dependencies are incomplete")
end

local function tickAfter(tick, delta)
    local result, reason = Core.tickAdd(tick, delta)
    if result == nil then
        error("invalid template-repair tick deadline: " .. tostring(reason), 0)
    end
    return result
end

local function clearQueuedIdentity(identityKey)
    if type(identityKey) ~= "string" then return end
    queues[identityKey] = nil
    reportedFailures[identityKey] = nil
end

local function isIdentityPaused(identityKey, tick)
    if type(identityKey) ~= "string" then return false end
    if previousActiveTransitions[identityKey] == true then return true end
    if not Core.isTick(tick) then return false end
    local untilTick = transitionPauseUntil[identityKey]
    if not Core.isTick(untilTick) then return false end
    if Core.tickReached(untilTick, tick) then return true end
    transitionPauseUntil[identityKey] = nil
    return false
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

local function activeForIdentity(activity, identityKey)
    local state = type(activity) == "table" and activity[identityKey] or nil
    return type(state) == "table" and state.active == true
end

local function observeBoundaryTransitions(tick)
    local snapshotOk, activity = Boundary.transitionActivitySnapshot(tick)
    if not snapshotOk or type(activity) ~= "table" then
        return false, "boundary transition state unavailable"
    end

    local activeIdentities, recentlyCompleted = {}, {}
    for key, state in pairs(activity) do
        if type(key) == "string" and type(state) == "table" then
            if state.active == true then
                activeIdentities[key] = true
            elseif state.recentlyCompleted == true then
                recentlyCompleted[key] = true
            end
        end
    end

    for key in pairs(activeIdentities) do
        transitionPauseUntil[key] = nil
        clearQueuedIdentity(key)
    end

    for key in pairs(previousActiveTransitions) do
        if not activeIdentities[key] then
            previousActiveTransitions[key] = nil
            transitionPauseUntil[key] = tickAfter(tick,
                transitionReturnGraceTicks)
            clearQueuedIdentity(key)
        end
    end

    for key in pairs(recentlyCompleted) do
        if not activeIdentities[key] then
            local requestedUntil = tickAfter(tick, transitionReturnGraceTicks)
            local previousUntil = transitionPauseUntil[key]
            if not Core.isTick(previousUntil)
                or Core.tickCompare(requestedUntil, previousUntil) == 1 then
                transitionPauseUntil[key] = requestedUntil
            end
            clearQueuedIdentity(key)
        end
    end

    for key in pairs(activeIdentities) do
        previousActiveTransitions[key] = true
    end
    for key, untilTick in pairs(transitionPauseUntil) do
        if not Core.isTick(untilTick)
            or Core.tickCompare(tick, untilTick) == 1 then
            transitionPauseUntil[key] = nil
        end
    end
    if type(ctx.pruneTemplateProtectionRemovalTrace) == "function" then
        pcall(ctx.pruneTemplateProtectionRemovalTrace, tick)
    end
    return true
end

local function identityHasActiveTransition(identity, tick)
    local snapshotOk, activity = Boundary.transitionActivitySnapshot(tick)
    if not snapshotOk or type(activity) ~= "table" then return nil end
    local key = Index.identityKey(identity.rvId, identity.generation)
    if not key then return nil end
    return activeForIdentity(activity, key)
end

local function onBoundaryTransitionLifecycle(eventName, _, identity, tick)
    if type(identity) ~= "table" then return end
    local key = Index.identityKey(identity.rvId, identity.generation)
    if not key then return end
    if not Core.isTick(tick) then tick = Core.getTick() end
    if not Core.isTick(tick) then
        previousActiveTransitions[key] = true
        transitionPauseUntil[key] = nil
        clearQueuedIdentity(key)
        return
    end
    if eventName == "begin" then
        previousActiveTransitions[key] = true
        transitionPauseUntil[key] = nil
        clearQueuedIdentity(key)
        return
    end
    if eventName ~= "complete" and eventName ~= "clear"
        and eventName ~= "timeout" then
        return
    end
    local active = identityHasActiveTransition(identity, tick)
    if active == nil or active then
        previousActiveTransitions[key] = true
        transitionPauseUntil[key] = nil
    else
        previousActiveTransitions[key] = nil
        transitionPauseUntil[key] = tickAfter(tick,
            transitionReturnGraceTicks)
    end
    clearQueuedIdentity(key)
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
    local server = type(RV) == "table" and RV.Server or nil
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
                    purgePreviousGenerations(boundary.rvId, key)
                    local queue = queues[key]
                    if isIdentityPaused(key, tick) then
                        clearQueuedIdentity(key)
                    elseif queue and queue.count > 0 then
                        ready[#ready + 1] = { key = key, queue = queue,
                            boundary = boundary, player = item.player }
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
    if not Core.isTick(tick) then return false, "invalid boundary tick" end
    local observeOk, observeReason = observeBoundaryTransitions(tick)
    if not observeOk then
        print("[RailroaderRVTest] template-protection-repair transition observation skipped: "
            .. tostring(observeReason))
        return false, observeReason
    end

    if Core.tickModulo(sampleInterval) == true
        and type(activePlayers) == "table" then
        for i = 1, #activePlayers do
            local item = activePlayers[i]
            local callOk, sampled, reason = pcall(samplePlayer,
                item and item.boundary, item and item.player)
            if not callOk or sampled ~= true then
                print("[RailroaderRVTest] template-protection-repair player sampling skipped: "
                    .. tostring(callOk and reason or sampled))
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

local lifecycleRegistered, lifecycleReason =
    Boundary.addTransitionLifecycleListener("TemplateProtectionRepairQueue",
        onBoundaryTransitionLifecycle)
if lifecycleRegistered ~= true then
    error("RailroaderRVTest: template-recovery lifecycle registration failed: "
        .. tostring(lifecycleReason))
end
local tickRegistered, tickReason = Boundary.addPostPlayerTickHandler(
    "TemplateRecoveryQueue", onPostPlayerTick)
if tickRegistered ~= true then
    error("RailroaderRVTest: template-recovery tick registration failed: "
        .. tostring(tickReason))
end
end
