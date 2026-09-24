-- RV_RailroaderServer: WallRepair responsibilities.
return function(ctx)
local Boundary = ctx.Boundary
local Adapter = ctx.Adapter
local C = ctx.C
local roofRepairRooms = ctx.roofRepairRooms
local pendingWallRoofRepairs = ctx.pendingWallRoofRepairs
local followUpWallRemovalEvents = ctx.followUpWallRemovalEvents
local roomTransitionStates = ctx.roomTransitionStates
local suppressedRoomTransitions = ctx.suppressedRoomTransitions
local seenWallRemovalEvents = ctx.seenWallRemovalEvents
local ROOF_REPAIR_DELAY_TICKS = ctx.ROOF_REPAIR_DELAY_TICKS
local ROOF_REPAIR_ATTEMPTS = ctx.ROOF_REPAIR_ATTEMPTS
local WALL_REMOVAL_FOLLOWUP_TICKS = ctx.WALL_REMOVAL_FOLLOWUP_TICKS
local WALL_REMOVAL_FOLLOWUP_MAX = ctx.WALL_REMOVAL_FOLLOWUP_MAX
local ROOF_REPAIR_QUEUED_DEADLINE_TICKS = ctx.ROOF_REPAIR_QUEUED_DEADLINE_TICKS
local function recordForLoco(...) return ctx.recordForLoco(...) end
local function insidePlayersForRecord(...) return ctx.insidePlayersForRecord(...) end
local function scheduleRoofRepair(...) return ctx.scheduleRoofRepair(...) end
local function beginRoofRepairPhase(...) return ctx.beginRoofRepairPhase(...) end
local integer = ctx.integer
local validRecord = ctx.validRecord
local roofRepairRoomKey = ctx.roofRepairRoomKey
local markSuppressedRoomTransition = ctx.markSuppressedRoomTransition
local repairRoofForPlayer = ctx.repairRoofForPlayer
local sendResult = ctx.sendResult
local resolveSavedPlayer = ctx.resolveSavedPlayer
local rememberFollowUpWallRemoval = ctx.rememberFollowUpWallRemoval

local function clearRoofRepairRuntimeState(rejectQueued)
    -- These are transient requests and observations only; no persisted map
    -- field is changed. Keep an active grouped relocation alive when map
    -- validation is unavailable: its in-memory return loop still owns members.
    roomTransitionStates = {}
    suppressedRoomTransitions = {}
    seenWallRemovalEvents = {}
    if rejectQueued == true then
        -- A confirmed current-schema failure is fail-closed: accepted
        -- follow-ups must not be replayed against an incompatible save.
        local followUpCount = 0
        for _, events in pairs(followUpWallRemovalEvents) do
            if type(events) == "table" then
                for _ in pairs(events) do followUpCount = followUpCount + 1 end
            end
        end
        if followUpCount > 0 then
            print("[RailroaderRVTest] wall removal follow-up queue cancelled count="
                .. tostring(followUpCount) .. " reason="
                .. C.SAVE_REBUILD_REQUIRED)
        end
        followUpWallRemovalEvents = {}
    end
    for roomKey in pairs(pendingWallRoofRepairs) do
        local pending = pendingWallRoofRepairs[roomKey]
        local relocationActive = pending
            and pending.relocationPhase ~= "complete"
        if not relocationActive then
            print("[RailroaderRVTest] roof repair schedule cancelled room="
                .. tostring(roomKey) .. " reason=" .. C.SAVE_REBUILD_REQUIRED)
            pendingWallRoofRepairs[roomKey] = nil
        end
    end
end

local function cancelPendingWallRoofRepair(roomKey, pending, reason)
    local server = RailroaderRV and RailroaderRV.Server
    if pending and pending.relocationStarted and server
        and type(server.cancelRoofRepairRelocation) == "function" then
        pcall(server.cancelRoofRepairRelocation, reason)
    end
    if pendingWallRoofRepairs[roomKey] == pending then
        pendingWallRoofRepairs[roomKey] = nil
    end
    print("[RailroaderRVTest] roof repair schedule cancelled room="
        .. tostring(roomKey) .. " reason=" .. tostring(reason))
end

-- Expire unstarted queued ownership before reading map data.  This keeps the
-- finite pre-relocation lease effective even during a transient ModData read
-- failure; no Boundary lease, Relocate or return action exists to unwind.
local function expireQueuedWallRoofRepairs(now)
    for roomKey, pending in pairs(pendingWallRoofRepairs) do
        if type(pending) == "table"
            and pending.relocationPhase == "queued"
            and pending.waitingForGeneration ~= true
            and pending.relocationStarted ~= true
            and pending.relocationToken == nil
            and pending.returnToken == nil then
            local deadline = integer(pending.queuedDeadlineTick)
            if deadline == nil then
                cancelPendingWallRoofRepair(roomKey, pending,
                    "malformed queued roof repair deadline")
            elseif now >= deadline then
                cancelPendingWallRoofRepair(roomKey, pending,
                    "queued roof repair member rebind deadline expired")
            end
        end
    end
end

local function processPendingWallRoofRepairGroup(map, pending, record, server,
    now)
    if type(pending.players) ~= "table" or #pending.players < 1 then
        cancelPendingWallRoofRepair(pending.roomKey, pending,
            "roof repair group has no saved authoritative players")
        return
    end
    -- No Relocate or Boundary lease exists while the phase is queued.  A
    -- disconnected member can therefore be safely abandoned after this
    -- bounded rebind window; temporary/repair/return phases never use this
    -- deadline and retain their existing in-memory retry context.
    if pending.relocationPhase == "queued"
        and pending.relocationStarted ~= true
        and pending.relocationToken == nil
        and pending.returnToken == nil then
        local queuedDeadline = integer(pending.queuedDeadlineTick)
        if queuedDeadline == nil then
            cancelPendingWallRoofRepair(pending.roomKey, pending,
                "malformed queued roof repair deadline")
            return
        end
        if now >= queuedDeadline then
            cancelPendingWallRoofRepair(pending.roomKey, pending,
                "queued roof repair member rebind deadline expired")
            return
        end
    end
    for i = 1, #pending.players do
        if not resolveSavedPlayer(pending.players[i]) then
            -- Keep the grouped transaction in memory until every stable
            -- identity has a live player object again.
            return
        end
    end
    if pending.relocationPhase == "queued" then
        if now >= (pending.startTick or now + 1) then
            local started, detail = beginRoofRepairPhase(nil, pending,
                "temporary")
            if not started then
                -- A second wall operation may be observed while the first
                -- group's return lease is still completing.  Keep this new
                -- queued operation for the next idle tick; dropping it here
                -- would turn a genuinely independent wall action into a
                -- lost refresh.  Schema/identity/API failures remain hard
                -- cancellations below.
                if detail == "another RV relocation or generation is in progress"
                    or detail == "requesting player disconnected or was replaced" then
                    pending.startTick = now + 1
                else
                    cancelPendingWallRoofRepair(pending.roomKey, pending, detail)
                end
            else
                pending.relocationStarted = true
                pending.relocationPhase = "temporary"
                pending.relocationToken = detail
                print("[RailroaderRVTest] roof repair group temporary relocation started room="
                    .. pending.roomKey .. " members="
                    .. tostring(#pending.players) .. " token=" .. tostring(detail))
            end
        end
        return
    end
    if pending.relocationPhase == "temporary" then
        local readyFn = type(server.roofRepairRelocationGroupReady) == "function"
            and server.roofRepairRelocationGroupReady
        local ready = readyFn and readyFn(pending.rvId, pending.generation,
            pending.bitmapVersion) or false
        if not ready then return end
        for i = 1, #pending.players do
            local saved = pending.players[i]
            if not resolveSavedPlayer(saved) then return end
            local arrival = server.consumeRoofRepairRelocationArrival(
                saved.player)
            if not arrival then return end
            saved.player = arrival.player or saved.player
            saved.remoteArrived = true
        end
        pending.relocationPhase = "repairing"
        pending.repairStartTick = now
        pending.dueTicks = {}
        pending.nextAttempt = 1
        for attempt = 1, ROOF_REPAIR_ATTEMPTS do
            pending.dueTicks[attempt] = now
                + attempt * ROOF_REPAIR_DELAY_TICKS
        end
        print("[RailroaderRVTest] roof repair group remote relocation ready room="
            .. pending.roomKey .. " members=" .. tostring(#pending.players)
            .. " target=rv-center-minus-offset dueTicks="
            .. table.concat(pending.dueTicks, ","))
        return
    end
    if pending.relocationPhase == "repairing" then
        local attempt = integer(pending.nextAttempt)
        local dueTick = attempt and pending.dueTicks
            and integer(pending.dueTicks[attempt]) or nil
        if not attempt or attempt < 1 or attempt > ROOF_REPAIR_ATTEMPTS
            or not dueTick then
            cancelPendingWallRoofRepair(pending.roomKey, pending,
                "malformed roof repair group remote wait schedule")
            return
        end
        if now < dueTick then return end
        -- Keep the complete group remote for the requested cross-tick cycle;
        -- repair is intentionally invoked only after every member returns.
        print("[RailroaderRVTest] roof repair group remote wait room="
            .. pending.roomKey .. " attempt=" .. tostring(attempt) .. "/"
            .. tostring(ROOF_REPAIR_ATTEMPTS) .. " result=deferred")
        pending.nextAttempt = attempt + 1
        if attempt >= ROOF_REPAIR_ATTEMPTS then
            local started, detail = beginRoofRepairPhase(nil, pending, "return")
            if not started then
                if detail == "requesting player disconnected or was replaced"
                    or detail == "another RV relocation or generation is in progress" then
                    pending.nextAttempt = attempt
                    return
                end
                cancelPendingWallRoofRepair(pending.roomKey, pending, detail)
            else
                pending.relocationPhase = "returning"
                pending.returnToken = detail
                pending.returnArrived = false
                pending.returnCompleted = {}
                pending.repairWorldApplied = false
                pending.repairCompleted = false
                pending.repairContextIndex = nil
                -- Repair is a continuously required post-return step.  This
                -- is only a retry cadence, never a deadline that can retire
                -- the in-memory transaction while the squares are unloaded.
                pending.repairRetryAtTick = now
                print("[RailroaderRVTest] roof repair group return relocation started room="
                    .. pending.roomKey .. " members="
                    .. tostring(#pending.players) .. " token=" .. tostring(detail))
            end
        end
        return
    end
    if pending.relocationPhase == "returning" then
        for i = 1, #pending.players do
            local saved = pending.players[i]
            if not saved.returnArrived then
                local arrival = server.consumeRoofRepairRelocationArrival(
                    saved.player)
                if arrival then
                    saved.player = arrival.player or saved.player
                    saved.returnArrived = true
                end
            end
        end
        local allArrived = true
        for i = 1, #pending.players do
            if not pending.players[i].returnArrived then
                allArrived = false
                break
            end
        end
        if not allArrived then return end

        -- Complete the authoritative return for every member before invoking
        -- any repair/refresh callback.  A repair exception or a temporarily
        -- unavailable chunk must never strand a player in the remote target.
        for i = 1, #pending.players do
            local saved = pending.players[i]
            if not pending.returnCompleted[i] then
                local completeCallOk, completed, detail = pcall(
                    server.completeRoofRepairRelocation, saved.player,
                    pending.returnToken)
                if completeCallOk and completed == true then
                    pending.returnCompleted[i] = true
                elseif completeCallOk then
                    print("[RailroaderRVTest] roof repair group return wait player="
                        .. tostring(saved.identityKey) .. " detail="
                        .. tostring(detail or completed))
                else
                    print("[RailroaderRVTest] roof repair group return error player="
                        .. tostring(saved.identityKey) .. " detail="
                        .. tostring(completed))
                end
            end
        end

        -- This is a hard phase barrier. A repair callback is never allowed
        -- to mask one member's failed/unfinished authoritative return.
        local allCompleted = true
        for i = 1, #pending.players do
            if not pending.returnCompleted[i] then
                allCompleted = false
                break
            end
        end
        if not allCompleted then return end

        -- This is the same server-authoritative roof/geometry repair path used
        -- by existing RV entry. It runs only after the physical return has
        -- been observed; every callback is bounded/isolated so it cannot
        -- interrupt the remaining members' return handling.
        local representative = pending.repairContextIndex
            and pending.players[pending.repairContextIndex] or nil
        if not representative then
            representative = pending.players[1]
            pending.repairContextIndex = 1
        end
        if pending.repairWorldApplied ~= true
            and now >= (pending.repairRetryAtTick or 0) then
            local loaded, loadedDetail = false,
                "roof repair squares are not loaded after return"
            local loadedCallOk, loadedResult, loadedReason = pcall(
                server.roofRepairSquaresLoaded, representative.player, record)
            if loadedCallOk then
                loaded, loadedDetail = loadedResult, loadedReason
            else
                loadedDetail = tostring(loadedResult)
            end
            if loaded == true then
                local repairCallOk, repaired, detail = pcall(
                    repairRoofForPlayer, representative.player, record, true,
                    "remote-reload-return")
                if not repairCallOk then
                    detail = tostring(repaired)
                    repaired = false
                end
                print("[RailroaderRVTest] roof repair returned room="
                    .. tostring(pending.roomKey) .. " result="
                    .. (repaired and "applied" or "deferred") .. " detail="
                    .. tostring(detail or "unknown"))
                if repaired == true then
                    pending.repairWorldApplied = true
                    pending.repairRetryAtTick = nil
                else
                    pending.repairRetryAtTick = now + ROOF_REPAIR_DELAY_TICKS
                    sendResult(representative.player, false,
                        detail or "roof repair after remote reload was deferred")
                end
            else
                pending.repairRetryAtTick = now + ROOF_REPAIR_DELAY_TICKS
                print("[RailroaderRVTest] roof repair after return deferred room="
                    .. tostring(pending.roomKey) .. " detail=" .. tostring(loadedDetail
                        or "roof repair squares are not loaded after return"))
            end
        end
        if pending.repairWorldApplied == true
            and pending.repairCompleted ~= true then
            local ackCallOk, acknowledged, ackDetail = pcall(
                server.completeRoofRepairRepair, representative.player,
                pending.returnToken)
            if ackCallOk and acknowledged == true then
                pending.repairCompleted = true
            else
                print("[RailroaderRVTest] roof repair completion remains pending room="
                    .. tostring(pending.roomKey) .. " detail="
                    .. tostring(ackCallOk and ackDetail or acknowledged))
            end
        end
        if allCompleted and pending.repairCompleted == true then
            pending.relocationPhase = "complete"
            markSuppressedRoomTransition(pending)
            pendingWallRoofRepairs[pending.roomKey] = nil
            roofRepairRooms[pending.roomKey] = nil
            print("[RailroaderRVTest] roof repair group transaction complete room="
                .. pending.roomKey .. " members=" .. tostring(#pending.players)
                .. " repair=applied return=acknowledged")
        end
        return
    end
    cancelPendingWallRoofRepair(pending.roomKey, pending,
        "unknown roof repair group transaction phase")
end

beginRoofRepairPhase = function(player, pending, phase)
    local server = RailroaderRV and RailroaderRV.Server
    if not server then
        return false, "roof repair relocation service is unavailable"
    end
    if type(pending.players) == "table" then
        if type(server.beginRoofRepairRelocationGroup) ~= "function" then
            return false, "roof repair group relocation service is unavailable"
        end
        local descriptors = {}
        for i = 1, #pending.players do
            local saved = pending.players[i]
            if not resolveSavedPlayer(saved) then return false, "requesting player disconnected or was replaced" end
            descriptors[#descriptors + 1] = {
                player = saved.player,
                identityKey = saved.identityKey,
            }
        end
        local ok, started, detail = pcall(
            server.beginRoofRepairRelocationGroup, {
                roomKey = pending.roomKey,
                rvId = pending.rvId,
                generation = pending.generation,
                bitmapVersion = pending.bitmapVersion,
                phase = phase,
                players = phase == "temporary" and descriptors or nil,
            })
        if not ok then return false, tostring(started) end
        if started ~= true then
            return false, detail or "roof repair group relocation was rejected"
        end
        return true, detail
    end
end

local function promoteFollowUpWallRemoval(map, roomKey)
    if pendingWallRoofRepairs[roomKey] ~= nil then return false end
    local events = followUpWallRemovalEvents[roomKey]
    if type(events) ~= "table" then return false end
    local now = Adapter._ticks or 0
    for eventKey, event in pairs(events) do
        if type(event) ~= "table" then
            events[eventKey] = nil
        elseif event.waitingForGeneration ~= true
            and now > (integer(event.expiresAtTick) or 0) then
            events[eventKey] = nil
        else
            local waitingForGeneration = event.waitingForGeneration == true
            local record = recordForLoco(map, event.rvId)
            if not record or not validRecord(record) then
                if waitingForGeneration then
                    print("[RailroaderRVTest] wall removal follow-up cancelled room="
                        .. tostring(roomKey) .. " event=" .. tostring(eventKey)
                        .. " reason=" .. C.SAVE_REBUILD_REQUIRED)
                end
                events[eventKey] = nil
            else
                local currentRoomKey = roofRepairRoomKey(record)
                if not currentRoomKey then
                    if waitingForGeneration then
                        print("[RailroaderRVTest] wall removal follow-up cancelled room="
                            .. tostring(roomKey) .. " event=" .. tostring(eventKey)
                            .. " reason=" .. C.SAVE_REBUILD_REQUIRED)
                    end
                    events[eventKey] = nil
                elseif currentRoomKey ~= roomKey then
                    -- Generation may replace the current identity while this
                    -- bounded follow-up is waiting.  Re-key it to the new
                    -- current record and let the next pass run the complete
                    -- schedule/schema/player validation; do not discard it as
                    -- an old room merely because the generation changed.
                    local currentEvents = followUpWallRemovalEvents[currentRoomKey]
                    if type(currentEvents) ~= "table" then
                        currentEvents = {}
                        followUpWallRemovalEvents[currentRoomKey] = currentEvents
                    end
                    if currentEvents[eventKey] == nil then
                        local count = 0
                        for _ in pairs(currentEvents) do count = count + 1 end
                        if count < WALL_REMOVAL_FOLLOWUP_MAX then
                            event.roomKey = currentRoomKey
                            event.rvId = tostring(record.rvId)
                            if waitingForGeneration then
                                -- The current record/rvId/generation/
                                -- bitmapVersion is now proven complete.  Give
                                -- this accepted event a fresh full lease.
                                event.expiresAtTick = now
                                    + ROOF_REPAIR_QUEUED_DEADLINE_TICKS
                                event.waitingForGeneration = nil
                            end
                            currentEvents[eventKey] = event
                            events[eventKey] = nil
                        elseif waitingForGeneration then
                            print("[RailroaderRVTest] wall removal follow-up cancelled room="
                                .. tostring(roomKey) .. " event="
                                .. tostring(eventKey)
                                .. " reason=bounded-queue-after-generation")
                            events[eventKey] = nil
                        end
                    else
                        if waitingForGeneration then
                            print("[RailroaderRVTest] wall removal follow-up cancelled room="
                                .. tostring(roomKey) .. " event="
                                .. tostring(eventKey)
                                .. " reason=duplicate-current-event-after-generation")
                        end
                        events[eventKey] = nil
                    end
                else
                    if waitingForGeneration then
                        -- Revalidation succeeded against the complete current
                        -- record.  Only now does the follow-up re-enter its
                        -- bounded offline/rebind wait.
                        event.expiresAtTick = now
                            + ROOF_REPAIR_QUEUED_DEADLINE_TICKS
                        event.waitingForGeneration = nil
                    end
                    local scheduled = scheduleRoofRepair(map, record,
                        "follow-up-wall-removal", eventKey,
                        event.coordinateKey)
                    if scheduled then
                        events[eventKey] = nil
                        return true
                    end
                    -- A transient busy/identity gate must not swallow a distinct
                    -- wall operation.  Keep the stable event until its explicit
                    -- expiry; a schema-invalid record is still rejected by the
                    -- normal current-only gate on the next pass.
                    event.lastAttemptTick = now
                    break
                end
            end
        end
    end
    local empty = true
    for _ in pairs(events) do empty = false; break end
    if empty then followUpWallRemovalEvents[roomKey] = nil end
    return false
end

-- A wall event can be accepted while the independent generation transaction
-- is already moving the same managed scope.  Keep the queued operation
-- entirely in memory, then re-read the current record after generation has
-- released its mutex; never start a roof group against the old generation.
local function revalidateQueuedRoofRepairAfterGeneration(map, roomKey,
    pending, now)
    if type(pending) ~= "table" or pending.relocationPhase ~= "queued" then
        return "ready"
    end
    local waitingForGeneration = pending.waitingForGeneration == true
    local deadline = integer(pending.revalidateUntilTick)
        or (now + WALL_REMOVAL_FOLLOWUP_TICKS)
    pending.revalidateUntilTick = deadline
    local record = recordForLoco(map, pending.rvId)
    local currentRoomKey = record and validRecord(record)
        and roofRepairRoomKey(record) or nil
    local identityMatches = currentRoomKey == roomKey
        and integer(record and record.generation) == integer(pending.generation)
        and integer(record and record.bitmapVersion)
            == integer(pending.bitmapVersion)
    if not waitingForGeneration and identityMatches then
        pending.revalidateUntilTick = nil
        return "ready"
    end
    if not waitingForGeneration then
        -- The adapter may run after RV_Server has completed a generation on
        -- the same game tick.  Detect that identity swap even when the prior
        -- tick could not mark the queue as waiting.
        if currentRoomKey == nil then return "ready" end
        pending.waitingForGeneration = true
        waitingForGeneration = true
    end
    if not record or not validRecord(record) then
        if now <= deadline then return "wait" end
        return "expired"
    end
    if not currentRoomKey then
        if now <= deadline then return "wait" end
        return "expired"
    end
    if currentRoomKey == roomKey
        and integer(record.generation) == integer(pending.generation)
        and integer(record.bitmapVersion) == integer(pending.bitmapVersion) then
        -- A generation-owned queue had its old lease paused rather than
        -- consumed.  Once the complete current identity is confirmed, start
        -- a fresh bounded rebind window; never carry the pre-generation
        -- deadline into the new generation.
        if waitingForGeneration then
            pending.queuedDeadlineTick = now
                + ROOF_REPAIR_QUEUED_DEADLINE_TICKS
        end
        pending.waitingForGeneration = nil
        pending.revalidateUntilTick = nil
        return "ready"
    end

    -- Re-capture all authoritative inside players and the exact current RV
    -- identity.  This preserves one event/one transaction while preventing a
    -- pre-generation return coordinate from being used after a swap.
    local players = insidePlayersForRecord(map, record)
    if #players == 0 then
        if now <= deadline then return "wait" end
        return "expired"
    end
    local existing = pendingWallRoofRepairs[currentRoomKey]
    if existing ~= nil and existing ~= pending then
        -- A room observation may have accepted a fresh current-generation
        -- schedule on the same tick.  Keep the older wall event as a bounded
        -- follow-up instead of overwriting that active transaction.
        local eventKey = pending.wallEventKey
        if type(eventKey) == "string" and eventKey ~= "" then
            rememberFollowUpWallRemoval(record, currentRoomKey, eventKey,
                pending.wallCoordinateKey, now)
            pendingWallRoofRepairs[roomKey] = nil
            return "revalidated"
        end
        return "wait"
    end
    pendingWallRoofRepairs[roomKey] = nil
    pending.roomKey = currentRoomKey
    pending.player = players[1].player
    pending.players = players
    pending.rvId = tostring(record.rvId)
    pending.generation = integer(record.generation)
    pending.bitmapVersion = integer(record.bitmapVersion)
    pending.identityKey = players[1].identityKey
    pending.returnPosition = players[1].originalPosition
    pending.startTick = now + 1
    pending.queuedDeadlineTick = now + ROOF_REPAIR_QUEUED_DEADLINE_TICKS
    pending.dueTicks = nil
    pending.nextAttempt = 1
    pending.relocationStarted = false
    pending.relocationPhase = "queued"
    pending.relocationToken = nil
    pending.returnToken = nil
    pending.waitingForGeneration = nil
    pending.revalidateUntilTick = nil
    pendingWallRoofRepairs[currentRoomKey] = pending
    print("[RailroaderRVTest] roof repair queue revalidated after generation room="
        .. currentRoomKey .. " source=" .. tostring(pending.source))
    return "revalidated"
end


ctx.clearRoofRepairRuntimeState = clearRoofRepairRuntimeState
ctx.cancelPendingWallRoofRepair = cancelPendingWallRoofRepair
ctx.expireQueuedWallRoofRepairs = expireQueuedWallRoofRepairs
ctx.processPendingWallRoofRepairGroup = processPendingWallRoofRepairGroup
ctx.promoteFollowUpWallRemoval = promoteFollowUpWallRemoval
ctx.revalidateQueuedRoofRepairAfterGeneration = revalidateQueuedRoofRepairAfterGeneration
end
