-- Temporary callback timing for correlating RV removal hooks with JFR.
local M = {}

local WINDOW_MS = 10000
local CHECK_TICK_INTERVAL = 30
local currentServerTick = 0

local handlers = {
    utility = { label = "utility-fixture" },
    roomguard = { label = "room-ownership" },
    shellrepair = { label = "shell-roof-repair" },
}

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function nowMs()
    if type(getTimestampMs) ~= "function" then return nil end
    local ok, value = pcall(getTimestampMs)
    if not ok or not finiteNumber(value) then return nil end
    return value
end

local function reset(handler)
    handler.window = nil
    handler.active = 0
    handler.calls = 0
    handler.hit = 0
    handler.miss = 0
    handler.totalMs = 0
    handler.maxMs = 0
    handler.timed = 0
    handler.cheapReject = 0
    handler.preconditionReject = 0
    handler.candidate = 0
    handler.strictMatch = 0
    handler.repairQueued = 0
    handler.aboutToRemoveTotal = 0
    handler.destroyThumpableTotal = 0
    handler.firstTick = nil
    handler.lastTick = nil
    handler.firstMs = nil
    handler.lastMs = nil
end

local function emit(id, handler)
    local timedSpan = handler.firstMs and handler.lastMs
        and math.max(0, handler.lastMs - handler.firstMs) or 0
    local outcomeText = handler.trackOutcome
        and (" hit=" .. tostring(handler.hit)
            .. " miss=" .. tostring(handler.miss)) or ""
    -- `n` and objectRemoveTotal combine both removal callbacks. Keep their
    -- per-entry totals beside them so older OnObjectAboutToBeRemoved counts
    -- can be compared directly with aboutToRemoveTotal.
    local stageText = id == "shellrepair"
        and (" objectRemoveTotal=" .. tostring(handler.calls)
            .. " aboutToRemoveTotal=" .. tostring(handler.aboutToRemoveTotal)
            .. " destroyThumpableTotal=" .. tostring(handler.destroyThumpableTotal)
            .. " preconditionReject=" .. tostring(handler.preconditionReject)
            .. " cheapReject=" .. tostring(handler.cheapReject)
            .. " candidate=" .. tostring(handler.candidate)
            .. " strictMatch=" .. tostring(handler.strictMatch)
            .. " repairQueued=" .. tostring(handler.repairQueued)) or ""
    print("[RailroaderRVTest][PerfTrace] server/object-remove handler="
        .. handlers[id].label
        .. " winMs=" .. tostring(handler.window * WINDOW_MS)
        .. " ticks=" .. tostring(handler.firstTick or "na") .. ".."
        .. tostring(handler.lastTick or "na")
        .. " n=" .. tostring(handler.calls)
        .. outcomeText
        .. stageText
        .. " ms=" .. string.format("%.2f/%.2f/%d",
            handler.totalMs, handler.maxMs, handler.timed)
        .. " fromMs=" .. tostring(handler.firstMs or "na")
        .. " toMs=" .. tostring(handler.lastMs or "na")
        .. " spanMs=" .. string.format("%.2f", timedSpan))
    reset(handler)
end

local function maybeEmit(id, handler, now)
    if handler.calls == 0 or handler.window == nil or handler.active > 0 then
        return
    end
    local window = math.floor(now / WINDOW_MS)
    if window ~= handler.window or now - (handler.firstMs or now) >= WINDOW_MS then
        emit(id, handler)
    end
end

function M.begin(id)
    local handler = handlers[id]
    if not handler then return nil end
    local startedAt = nowMs()
    if startedAt == nil then return nil end

    local window = math.floor(startedAt / WINDOW_MS)
    if handler.calls > 0 and handler.window ~= window and handler.active == 0 then
        emit(id, handler)
        startedAt = nowMs()
        if startedAt == nil then return nil end
        window = math.floor(startedAt / WINDOW_MS)
    end
    if handler.calls == 0 then
        handler.window = window
        handler.firstTick = currentServerTick
        handler.firstMs = startedAt
    end
    handler.calls = handler.calls + 1
    handler.active = handler.active + 1
    return startedAt
end

function M.finish(id, startedAt, hit)
    local handler = handlers[id]
    if not handler or not finiteNumber(startedAt) then return end
    handler.active = math.max(0, handler.active - 1)
    local finishedAt = nowMs()
    if finishedAt == nil then return end

    local elapsed = math.max(0, finishedAt - startedAt)
    handler.totalMs = handler.totalMs + elapsed
    handler.maxMs = math.max(handler.maxMs, elapsed)
    handler.timed = handler.timed + 1
    handler.lastMs = finishedAt
    handler.lastTick = currentServerTick
    if hit ~= nil then
        handler.trackOutcome = true
        if hit then
            handler.hit = handler.hit + 1
        else
            handler.miss = handler.miss + 1
        end
    end
    maybeEmit(id, handler, finishedAt)
end

function M.count(id, stage)
    local handler = handlers[id]
    if not handler or id ~= "shellrepair" or handler.window == nil then return end
    if stage == "aboutToRemoveTotal" or stage == "destroyThumpableTotal"
        or stage == "preconditionReject" or stage == "cheapReject"
        or stage == "candidate" or stage == "strictMatch"
        or stage == "repairQueued" then
        handler[stage] = handler[stage] + 1
    end
end

function M.onTick(tick)
    if finiteNumber(tick) then currentServerTick = tick end
    if currentServerTick % CHECK_TICK_INTERVAL ~= 0 then return end
    -- OnTick runs after synchronous callbacks unwind; a leftover active count
    -- therefore belongs to a callback that raised before its normal exit.
    for _, handler in pairs(handlers) do handler.active = 0 end

    local hasPending = false
    for _, handler in pairs(handlers) do
        if handler.calls > 0 then
            hasPending = true
            break
        end
    end
    if not hasPending then return end

    local now = nowMs()
    if now == nil then return end
    for id, handler in pairs(handlers) do
        maybeEmit(id, handler, now)
    end
end

function M.lifecycle(event, subject, state, tick)
    local now = nowMs()
    print("[RailroaderRVTest][CycleTrace] event=" .. tostring(event)
        .. " subject=" .. tostring(subject)
        .. " state=" .. tostring(state)
        .. " tick=" .. tostring(tick or currentServerTick)
        .. " ms=" .. tostring(now or "unavailable"))
end

handlers.roomguard.trackOutcome = true
for _, handler in pairs(handlers) do reset(handler) end

return M
