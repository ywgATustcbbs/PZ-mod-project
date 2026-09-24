-- RV_RailroaderServer: Tick responsibilities.
return function(ctx)
local Adapter = ctx.Adapter
local C = ctx.C
local pendingWallRoofRepairs = ctx.pendingWallRoofRepairs
local followUpWallRemovalEvents = ctx.followUpWallRemovalEvents
local WALL_REMOVAL_FOLLOWUP_TICKS = ctx.WALL_REMOVAL_FOLLOWUP_TICKS
local function recordForLoco(...) return ctx.recordForLoco(...) end
local integer = ctx.integer
local call = ctx.call
local findTrain = ctx.findTrain
local trainPose = ctx.trainPose
local mapData = ctx.mapData
local transmitMap = ctx.transmitMap
local validRecord = ctx.validRecord
local pruneRoofRepairDedupeState = ctx.pruneRoofRepairDedupeState
local pruneRoofRepairRooms = ctx.pruneRoofRepairRooms
local restoreAfterGenerationFailure = ctx.restoreAfterGenerationFailure
local commitGeneration = ctx.commitGeneration
local validateGeneration = ctx.validateGeneration
local processStatelessRelocationSentinel = ctx.processStatelessRelocationSentinel
local repairInsidePlayers = ctx.repairInsidePlayers
local clearRoofRepairRuntimeState = ctx.clearRoofRepairRuntimeState
local cancelPendingWallRoofRepair = ctx.cancelPendingWallRoofRepair
local expireQueuedWallRoofRepairs = ctx.expireQueuedWallRoofRepairs
local processPendingWallRoofRepairGroup = ctx.processPendingWallRoofRepairGroup
local promoteFollowUpWallRemoval = ctx.promoteFollowUpWallRemoval
local revalidateQueuedRoofRepairAfterGeneration = ctx.revalidateQueuedRoofRepairAfterGeneration

local function processPendingWallRoofRepairs()
    local now = Adapter._ticks or 0
    local hasWork = false
    for _ in pairs(pendingWallRoofRepairs) do
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
    if not server or type(server.getRoofRepairRelocationState) ~= "function"
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
        for roomKey, pending in pairs(pendingWallRoofRepairs) do
            if type(pending) == "table"
                and pending.relocationPhase == "queued"
                and pending.relocationStarted ~= true
                and pending.relocationToken == nil
                and pending.returnToken == nil then
                -- Do not resurrect a queued operation whose original lease
                -- was already exhausted before it entered the generation
                -- wait.  Once marked waiting, this old deadline is paused.
                if pending.waitingForGeneration ~= true then
                    local queuedDeadline = integer(pending.queuedDeadlineTick)
                    if queuedDeadline == nil then
                        cancelPendingWallRoofRepair(roomKey, pending,
                            "malformed queued roof repair deadline")
                    elseif now >= queuedDeadline then
                        cancelPendingWallRoofRepair(roomKey, pending,
                            "queued roof repair member rebind deadline expired")
                    else
                        pending.waitingForGeneration = true
                    end
                end
                if pendingWallRoofRepairs[roomKey] == pending
                    and pending.waitingForGeneration == true then
                    -- Both the queued deadline and this revalidation window
                    -- are paused while generation owns the scope.  Refreshing
                    -- the absolute timestamp makes a long generation
                    -- disconnect incapable of consuming an accepted roof
                    -- event's budget.
                    pending.revalidateUntilTick = now
                        + WALL_REMOVAL_FOLLOWUP_TICKS
                end
            end
        end
        return
    end
    -- A queued item marked waiting above must first pass the current-record
    -- revalidation below; only then may its fresh queued deadline run.
    expireQueuedWallRoofRepairs(now)
    local mapOk, mapOrReason = pcall(mapData)
    if not mapOk or type(mapOrReason) ~= "table" then
        -- A transient ModData read/engine exception must not silently erase an
        -- already accepted follow-up.  Keep its bounded/expiring queue until
        -- the next successful current-schema read; the explicit schema gate
        -- below is the only path allowed to reject it.
        local detail = type(mapOrReason) == "string" and mapOrReason or ""
        if string.find(detail, C.SAVE_REBUILD_REQUIRED, 1, true) then
            clearRoofRepairRuntimeState(true)
        end
        return
    end
    local map = mapOrReason
    for roomKey in pairs(followUpWallRemovalEvents) do
        if pendingWallRoofRepairs[roomKey] == nil then
            promoteFollowUpWallRemoval(map, roomKey)
        end
    end
    for roomKey, pending in pairs(pendingWallRoofRepairs) do
        if type(pending) ~= "table"
            or integer(pending.generation) == nil
            or integer(pending.bitmapVersion) ~= C.BITMAP_VERSION
            or type(pending.returnPosition) ~= "table" then
            cancelPendingWallRoofRepair(roomKey, pending, "malformed roof repair schedule")
        elseif pendingWallRoofRepairs[roomKey] == pending then
            local revalidation = revalidateQueuedRoofRepairAfterGeneration(
                map, roomKey, pending, now)
            if revalidation == "wait" or revalidation == "revalidated" then
                -- The current generation is still unavailable, or the queue
                -- was moved to its new room key.  Both remain in memory for
                -- the next successful current-schema read.
            elseif revalidation == "expired" then
                cancelPendingWallRoofRepair(roomKey, pending,
                    "roof repair generation revalidation expired")
            else
                local state, stateDetail = server.getRoofRepairRelocationState(
                    pending.rvId, pending.generation, pending.bitmapVersion,
                    pending.relocationToken or pending.returnToken)
                if state == "failed" then
                    server.consumeRoofRepairRelocationFailure(pending.rvId,
                        pending.generation, pending.bitmapVersion,
                        pending.relocationToken or pending.returnToken)
                    cancelPendingWallRoofRepair(roomKey, pending,
                        stateDetail or "roof repair relocation failed")
                else
                    local record = recordForLoco(map, pending.rvId)
                    if not record or tostring(record.rvId) ~= pending.rvId
                        or integer(record.generation) ~= pending.generation
                        or integer(record.bitmapVersion) ~= pending.bitmapVersion
                        or not validRecord(record) then
                        cancelPendingWallRoofRepair(roomKey, pending,
                            "identity-mismatch")
                    else
                        if type(pending.players) == "table" then
                            processPendingWallRoofRepairGroup(map, pending,
                                record, server, now)
                        else
                            cancelPendingWallRoofRepair(roomKey, pending,
                                "roof repair schedule has no grouped authoritative players")
                        end
                    end
                end
            end
        end
    end
end

function Adapter.OnTick()
    Adapter._ticks = (Adapter._ticks or 0) + 1
    pruneRoofRepairDedupeState(Adapter._ticks)
    pruneRoofRepairRooms(Adapter._ticks)
    processPendingWallRoofRepairs()
    -- Run the stateless z=-15 safety net only after ordinary in-memory roof
    -- transactions have had their phase/claim opportunity for this tick.
    processStatelessRelocationSentinel()
    if Adapter._ticks % 30 ~= 0 then return end
    local ok, mapOrReason = pcall(mapData)
    if not ok or type(mapOrReason) ~= "table" then
        if not Adapter._schemaWarning then
            print("[RailroaderRVTest] " .. tostring(mapOrReason
                or C.SAVE_REBUILD_REQUIRED))
            Adapter._schemaWarning = true
        end
        local detail = type(mapOrReason) == "string" and mapOrReason or ""
        if string.find(detail, C.SAVE_REBUILD_REQUIRED, 1, true) then
            clearRoofRepairRuntimeState(true)
        end
        return
    end
    Adapter._schemaWarning = nil
    local map = mapOrReason
    local changed = false
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
    repairInsidePlayers(map)
    if changed then transmitMap() end
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
    server.setRailroaderFailureHook(restoreAfterGenerationFailure)
    return true
end

Adapter._installed = true
Adapter.installTransactionHooks()
if Events and Events.OnClientCommand and type(Events.OnClientCommand.Add) == "function" then
    Events.OnClientCommand.Add(Adapter.OnClientCommand)
end
if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(Adapter.OnTick)
end
if Events and Events.OnObjectAboutToBeRemoved
    and type(Events.OnObjectAboutToBeRemoved.Add) == "function" then
    Events.OnObjectAboutToBeRemoved.Add(Adapter.onObjectAboutToBeRemoved)
end
if Events and Events.OnDestroyIsoThumpable
    and type(Events.OnDestroyIsoThumpable.Add) == "function" then
    Events.OnDestroyIsoThumpable.Add(Adapter.onDestroyIsoThumpable)
end


end
