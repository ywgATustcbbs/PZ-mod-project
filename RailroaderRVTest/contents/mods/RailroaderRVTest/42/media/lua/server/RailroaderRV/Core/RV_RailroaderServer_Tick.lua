-- RV_RailroaderServer: Tick responsibilities.
return function(ctx)
local Adapter = ctx.Adapter
local Core = require("RailroaderRV/Core/RV_Server_Core")
local C = ctx.C
local pendingWallRoofRefreshes = ctx.pendingWallRoofRefreshes
local followUpWallRemovalEvents = ctx.followUpWallRemovalEvents
local WALL_REMOVAL_FOLLOWUP_TICKS = ctx.WALL_REMOVAL_FOLLOWUP_TICKS
local function recordForLoco(...) return ctx.recordForLoco(...) end
local integer = ctx.integer
local call = ctx.call
local findTrain = ctx.findTrain
local trainPose = ctx.trainPose
local mapData = ctx.mapData
local markMappingChanged = ctx.markMappingChanged
local validRecord = ctx.validRecord
local pruneRoofRefreshDedupeState = ctx.pruneRoofRefreshDedupeState
local pruneRoofRefreshRooms = ctx.pruneRoofRefreshRooms
local restoreAfterGenerationFailure = ctx.restoreAfterGenerationFailure
local commitGeneration = ctx.commitGeneration
local validateGeneration = ctx.validateGeneration
local processStatelessRelocationSentinel = ctx.processStatelessRelocationSentinel
local sampleRoofRefreshPlayers = ctx.sampleRoofRefreshPlayers
local pauseFollowUpWallRemovalDeadlines = ctx.pauseFollowUpWallRemovalDeadlines
local cancelPendingWallRoofRefresh = ctx.cancelPendingWallRoofRefresh
local expireQueuedWallRoofRefreshes = ctx.expireQueuedWallRoofRefreshes
local processPendingWallRoofRefreshGroup = ctx.processPendingWallRoofRefreshGroup
local promoteFollowUpWallRemoval = ctx.promoteFollowUpWallRemoval
local revalidateQueuedRoofRefreshAfterGeneration = ctx.revalidateQueuedRoofRefreshAfterGeneration
Adapter._ticks = Core.getTick()

local function processPendingWallRoofRefreshes()
    local now = Adapter._ticks or Core.getTick()
    local hasWork = false
    for _ in pairs(pendingWallRoofRefreshes) do
        hasWork = true
        break
    end
    if not hasWork then
        for _, events in pairs(followUpWallRemovalEvents) do
            if type(events) == "table" then
                for _ in pairs(events) do
                    hasWork = true
                    break
                end
            end
            if hasWork then break end
        end
    end
    if not hasWork then return end
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.getRoofRefreshRelocationState) ~= "function"
        or type(server.isGenerationTransactionActive) ~= "function" then
        return
    end
    local generationCallOk, generationActive = pcall(
        server.isGenerationTransactionActive)
    if not generationCallOk or type(generationActive) ~= "boolean" then
        -- The cross-module mutex is authoritative.  If its read is
        -- unavailable, leave every accepted queue untouched and fail closed.
        return
    end
    if generationActive then
        if pauseFollowUpWallRemovalDeadlines then
            pauseFollowUpWallRemovalDeadlines(now)
        end
        for roomKey, pending in pairs(pendingWallRoofRefreshes) do
            if type(pending) == "table"
                and pending.relocationPhase == "queued"
                and pending.relocationStarted ~= true
                and pending.relocationToken == nil
                and pending.returnToken == nil then
                -- Do not resurrect a queued operation whose original lease
                -- was already exhausted before it entered the generation
                -- wait.  Once marked waiting, this old deadline is paused.
                if pending.waitingForGeneration ~= true then
                    local queuedDeadline = pending.queuedDeadlineTick
                    if not Core.isTick(queuedDeadline) then
                        cancelPendingWallRoofRefresh(roomKey, pending,
                            "malformed queued roof refresh deadline")
                    elseif Core.tickReached(now, queuedDeadline) then
                        cancelPendingWallRoofRefresh(roomKey, pending,
                            "queued roof refresh member rebind deadline expired")
                    else
                        pending.waitingForGeneration = true
                    end
                end
                if pendingWallRoofRefreshes[roomKey] == pending
                    and pending.waitingForGeneration == true then
                    -- Both the queued deadline and this revalidation window
                    -- are paused while generation owns the scope.  Refreshing
                    -- the absolute timestamp makes a long generation
                    -- disconnect incapable of consuming an accepted roof
                    -- event's budget.
                    pending.revalidateUntilTick = Core.tickAdd(now,
                        WALL_REMOVAL_FOLLOWUP_TICKS)
                end
            end
        end
        return
    end
    -- A queued item marked waiting above must first pass the current-record
    -- revalidation below; only then may its fresh queued deadline run.
    expireQueuedWallRoofRefreshes(now)
    local map = mapData()
    for roomKey in pairs(followUpWallRemovalEvents) do
        if pendingWallRoofRefreshes[roomKey] == nil then
            promoteFollowUpWallRemoval(map, roomKey)
        end
    end
    for roomKey, pending in pairs(pendingWallRoofRefreshes) do
        if type(pending) ~= "table"
            or integer(pending.generation) == nil
            or integer(pending.bitmapVersion) ~= C.BITMAP_VERSION
            or type(pending.returnPosition) ~= "table" then
            cancelPendingWallRoofRefresh(roomKey, pending, "malformed roof refresh schedule")
        elseif pendingWallRoofRefreshes[roomKey] == pending then
            local revalidation = revalidateQueuedRoofRefreshAfterGeneration(
                map, roomKey, pending, now)
            if revalidation == "wait" or revalidation == "revalidated" then
                -- The current generation is still unavailable, or the queue
                -- was moved to its new room key.  Both remain in memory for
                -- the next successful current-schema read.
            elseif revalidation == "expired" then
                cancelPendingWallRoofRefresh(roomKey, pending,
                    "roof refresh generation revalidation expired")
            else
                local state, stateDetail = server.getRoofRefreshRelocationState(
                    pending.rvId, pending.generation, pending.bitmapVersion,
                    pending.relocationToken or pending.returnToken)
                if state == "failed" then
                    server.consumeRoofRefreshRelocationFailure(pending.rvId,
                        pending.generation, pending.bitmapVersion,
                        pending.relocationToken or pending.returnToken)
                    cancelPendingWallRoofRefresh(roomKey, pending,
                        stateDetail or "roof refresh relocation failed")
                else
                    local record = recordForLoco(map, pending.rvId)
                    if not record or tostring(record.rvId) ~= pending.rvId
                        or integer(record.generation) ~= pending.generation
                        or integer(record.bitmapVersion) ~= pending.bitmapVersion
                        or not validRecord(record) then
                        cancelPendingWallRoofRefresh(roomKey, pending,
                            "identity-mismatch")
                    else
                        if type(pending.players) == "table" then
                            processPendingWallRoofRefreshGroup(map, pending,
                                record, server, now)
                        else
                            cancelPendingWallRoofRefresh(roomKey, pending,
                                "roof refresh schedule has no grouped authoritative players")
                        end
                    end
                end
            end
        end
    end
end

function Adapter.OnTick(tick)
    Adapter._ticks = Core.isTick(tick) and tick or Core.getTick()
    if Core.tickModulo(30) then
        pruneRoofRefreshDedupeState(Adapter._ticks)
        pruneRoofRefreshRooms(Adapter._ticks)
    end
    processPendingWallRoofRefreshes()
    -- Run the stateless z=-15 safety net only after ordinary in-memory roof
    -- transactions have had their phase/claim opportunity for this tick.
    processStatelessRelocationSentinel()
    if not Core.tickModulo(30) then return end
    local map = mapData()
    local changed = false
    if Core.tickModulo(120) then
        for _, record in pairs(map.locomotives or {}) do
            if type(record) == "table" and record.locoId ~= nil then
                local train = findTrain(record.locoId)
                local position = train and trainPose(train)
                if position then
                    local old = record.locoPosition
                    if not old or old.x ~= position.x or old.y ~= position.y
                        or old.z ~= position.z then
                        record.locoPosition = position
                        record.updatedAt = math.floor(os.time())
                        changed = true
                    end
                end
            end
        end
    end
    sampleRoofRefreshPlayers(map)
    if changed then markMappingChanged(false) end
end

-- PZ loads files in this directory alphabetically, so this adapter can be
-- evaluated before RV_Server.lua has created RailroaderRV.Server.  Expose a
-- one-shot installer and let RV_Server.lua call it again after its public
-- setters exist; require() then returns the cached adapter without rerunning
-- this file.
function Adapter.installTransactionHooks()
    local server = RailroaderRV and RailroaderRV.Server
    if not server
        or type(server.setRailroaderValidationHook) ~= "function"
        or type(server.setRailroaderCommitHook) ~= "function"
        or type(server.setRailroaderFailureHook) ~= "function" then
        return false
    end
    server.setRailroaderValidationHook(validateGeneration)
    server.setRailroaderCommitHook(commitGeneration)
    server.setRailroaderFailureHook(function(...)
        if type(Adapter.invalidateBoundaryValidationCache) == "function" then
            Adapter.invalidateBoundaryValidationCache()
        end
        return restoreAfterGenerationFailure(...)
    end)
    return true
end

Adapter._installed = true
Adapter.installTransactionHooks()
local function requireCoreRegistration(ok, reason)
    if not ok then
        error("RV Core registration failed: " .. tostring(reason), 0)
    end
end

requireCoreRegistration(Core.registerCommand(C.COMMAND_RV_ENTER,
    Adapter.OnClientCommand))
requireCoreRegistration(Core.registerCommand(C.COMMAND_RV_EXIT,
    Adapter.OnClientCommand))
requireCoreRegistration(Core.registerTick("RailroaderRV.Adapter", 1,
    Adapter.OnTick))
if type(Adapter.onObjectAboutToBeRemoved) == "function" then
    requireCoreRegistration(Core.registerEvent("OnObjectAboutToBeRemoved",
        "RailroaderRV.Adapter.ObjectAboutToBeRemoved",
        Adapter.onObjectAboutToBeRemoved))
end
if type(Adapter.onDestroyIsoThumpable) == "function" then
    requireCoreRegistration(Core.registerEvent("OnDestroyIsoThumpable",
        "RailroaderRV.Adapter.DestroyIsoThumpable",
        Adapter.onDestroyIsoThumpable))
end


end
