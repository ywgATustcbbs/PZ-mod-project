-- RV_RailroaderServer: RoofRefreshFlow responsibilities.
return function(ctx)
local Core = require("RailroaderRV/Core/RV_Server_Core")
local Adapter = ctx.Adapter
local C = ctx.C
local roofRefreshRooms = ctx.roofRefreshRooms
local pendingWallRoofRefreshes = ctx.pendingWallRoofRefreshes
local followUpWallRemovalEvents = ctx.followUpWallRemovalEvents
local roofRefreshPlayers = ctx.roofRefreshPlayers
local roomMonitorPlayers = ctx.roomMonitorPlayers
local roomTransitionStates = ctx.roomTransitionStates
local suppressedRoomTransitions = ctx.suppressedRoomTransitions
local seenWallRemovalEvents = ctx.seenWallRemovalEvents
local ROOF_REFRESH_DELAY_TICKS = ctx.ROOF_REFRESH_DELAY_TICKS
local ROOF_REFRESH_ATTEMPTS = ctx.ROOF_REFRESH_ATTEMPTS
local WALL_REMOVAL_FOLLOWUP_TICKS = ctx.WALL_REMOVAL_FOLLOWUP_TICKS
local WALL_REMOVAL_FOLLOWUP_MAX = ctx.WALL_REMOVAL_FOLLOWUP_MAX
local ROOF_REFRESH_QUEUED_DEADLINE_TICKS = ctx.ROOF_REFRESH_QUEUED_DEADLINE_TICKS
local function recordForLoco(...) return ctx.recordForLoco(...) end
local function insidePlayersForRecord(...) return ctx.insidePlayersForRecord(...) end
local function scheduleRoofRefresh(...) return ctx.scheduleRoofRefresh(...) end
local beginRoofRefreshPhase
local integer = ctx.integer
local validRecord = ctx.validRecord
local roofRefreshRoomKey = ctx.roofRefreshRoomKey
local markSuppressedRoomTransition = ctx.markSuppressedRoomTransition
local refreshRoofForPlayer = ctx.refreshRoofForPlayer
local armRoomOwnershipMonitor = ctx.armRoomOwnershipMonitor
local sendResult = ctx.sendResult
local resolveSavedPlayer = ctx.resolveSavedPlayer
local rememberFollowUpWallRemoval = ctx.rememberFollowUpWallRemoval
local playerName = ctx.playerName

local promoteFollowUpWallRemoval

local function currentPendingRoomKey(roomKey, pending)
    if roomKey ~= nil and pendingWallRoofRefreshes[roomKey] == pending then
        return roomKey
    end
    for candidateRoomKey, candidate in pairs(pendingWallRoofRefreshes) do
        if candidate == pending then return candidateRoomKey end
    end
    return nil
end

local function cancelPendingWallRoofRefresh(roomKey, pending, reason)
    local currentRoomKey = currentPendingRoomKey(roomKey, pending)
    local reasonText = tostring(reason or "roof refresh transaction cancelled")
    if currentRoomKey == nil then
        print("[RailroaderRVTest] roof refresh cancellation rejected room="
            .. tostring(roomKey) .. " reason=pending-group-is-not-current detail="
            .. reasonText)
        return false
    end

    local phase = type(pending) == "table" and pending.relocationPhase or nil
    local serviceMayOwnLease = type(pending) ~= "table"
        or (phase ~= "queued" and phase ~= "complete")
        or phase == "queued" and (pending.relocationStarted == true
            or pending.relocationToken ~= nil or pending.returnToken ~= nil)
    if serviceMayOwnLease then
        local server = RailroaderRV and RailroaderRV.Server
        if not server or type(server.cancelRoofRefreshRelocation) ~= "function" then
            print("[RailroaderRVTest] roof refresh cancellation failed room="
                .. tostring(currentRoomKey)
                .. " reason=roof refresh relocation cancellation service is unavailable"
                .. " detail=" .. reasonText)
            return false
        end
        local callOk, cancelled, detail = pcall(
            server.cancelRoofRefreshRelocation, reasonText)
        if not callOk then
            print("[RailroaderRVTest] roof refresh cancellation failed room="
                .. tostring(currentRoomKey) .. " detail=" .. tostring(cancelled)
                .. " reason=" .. reasonText)
            return false
        end
        if cancelled ~= true
            and detail ~= "no roof refresh group relocation is active" then
            print("[RailroaderRVTest] roof refresh cancellation failed room="
                .. tostring(currentRoomKey) .. " detail=" .. tostring(detail
                    or cancelled) .. " reason=" .. reasonText)
            return false
        end
    end

    pendingWallRoofRefreshes[currentRoomKey] = nil
    print("[RailroaderRVTest] roof refresh group cancelled room="
        .. tostring(currentRoomKey) .. " reason=" .. reasonText)

    -- A queued group has not sent a relocation command, so the relocation
    -- service has not already reported the failure to its members.
    if not serviceMayOwnLease and type(pending) == "table" then
        local players = pending.players
        if type(players) == "table" then
            for i = 1, #players do
                local saved = players[i]
                local resolvedCallOk, resolved = pcall(resolveSavedPlayer, saved)
                if resolvedCallOk and resolved then
                    local resultCallOk, resultError = pcall(sendResult,
                        saved.player, false, reasonText)
                    if not resultCallOk then
                        print("[RailroaderRVTest] roof refresh cancellation notification failed room="
                            .. tostring(currentRoomKey) .. " player="
                            .. tostring(saved.identityKey) .. " detail="
                            .. tostring(resultError))
                    end
                elseif not resolvedCallOk then
                    print("[RailroaderRVTest] roof refresh cancellation player rebind failed room="
                        .. tostring(currentRoomKey) .. " detail="
                        .. tostring(resolved))
                end
            end
        end
    end
    return true
end

local function finishCompletedRoofRefresh(map, pending, record)
    if type(pending) ~= "table" or pending.relocationPhase ~= "complete" then
        print("[RailroaderRVTest] roof refresh completion rejected room="
            .. tostring(type(pending) == "table" and pending.roomKey or nil)
            .. " reason=group-is-not-complete")
        return false
    end
    local roomKey = currentPendingRoomKey(pending.roomKey, pending)
    if roomKey == nil then
        print("[RailroaderRVTest] roof refresh completion rejected room="
            .. tostring(pending.roomKey) .. " reason=pending-group-is-not-current")
        return false
    end

    pendingWallRoofRefreshes[roomKey] = nil
    print("[RailroaderRVTest] roof refresh group completion retired room="
        .. tostring(roomKey) .. " members="
        .. tostring(type(pending.players) == "table" and #pending.players or 0))

    if type(map) == "table" and validRecord(record)
        and roofRefreshRoomKey(record) == roomKey then
        promoteFollowUpWallRemoval(map, roomKey)
    else
        print("[RailroaderRVTest] roof refresh follow-up promotion deferred room="
            .. tostring(roomKey) .. " reason=current RV identity unavailable")
    end
    return true
end

-- Expire unstarted queued ownership before reading map data.  This keeps the
-- finite pre-relocation lease effective even during a transient ModData read
-- failure; no Boundary lease, Relocate or return action exists to unwind.
local function expireQueuedWallRoofRefreshes(now)
    for roomKey, pending in pairs(pendingWallRoofRefreshes) do
        if type(pending) == "table"
            and pending.relocationPhase == "queued"
            and pending.waitingForGeneration ~= true
            and pending.relocationStarted ~= true
            and pending.relocationToken == nil
            and pending.returnToken == nil then
            if now >= pending.queuedDeadlineTick then
                cancelPendingWallRoofRefresh(roomKey, pending,
                    "queued roof refresh member rebind deadline expired")
            end
        end
    end
end

local function processPendingWallRoofRefreshGroup(map, pending, record, server,
    now)
    if pending.relocationPhase == "complete" then
        finishCompletedRoofRefresh(map, pending, record)
        return
    end
    if type(pending.players) ~= "table" or #pending.players < 1 then
        cancelPendingWallRoofRefresh(pending.roomKey, pending,
            "roof refresh group has no saved authoritative players")
        return
    end
    -- No Relocate or Boundary lease exists while the phase is queued.  A
    -- disconnected member can therefore be safely abandoned after this
    -- bounded rebind window; temporary/room-refresh/return phases never use this
    -- deadline and retain their existing in-memory retry context.
    if pending.relocationPhase == "queued"
        and pending.relocationStarted ~= true
        and pending.relocationToken == nil
        and pending.returnToken == nil then
        if now >= pending.queuedDeadlineTick then
            cancelPendingWallRoofRefresh(pending.roomKey, pending,
                "queued roof refresh member rebind deadline expired")
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
        local startTick = pending.startTick or (now + 1)
        if now >= startTick then
            local started, detail = beginRoofRefreshPhase(nil, pending,
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
                    cancelPendingWallRoofRefresh(pending.roomKey, pending, detail)
                end
            else
                pending.relocationStarted = true
                pending.relocationPhase = "temporary"
                pending.relocationToken = detail
                print("[RailroaderRVTest] roof refresh group temporary relocation started room="
                    .. pending.roomKey .. " members="
                    .. tostring(#pending.players) .. " token=" .. tostring(detail))
            end
        end
        return
    end
    if pending.relocationPhase == "temporary" then
        local readyFn = type(server.roofRefreshRelocationGroupReady) == "function"
            and server.roofRefreshRelocationGroupReady
        local ready = readyFn and readyFn(pending.rvId, pending.generation) or false
        if not ready then return end
        for i = 1, #pending.players do
            local saved = pending.players[i]
            if not resolveSavedPlayer(saved) then return end
            local arrival = server.consumeRoofRefreshRelocationArrival(
                saved.player)
            if not arrival then return end
            saved.player = arrival.player or saved.player
            saved.remoteArrived = true
        end
        pending.relocationPhase = "refreshing"
        pending.refreshStartTick = now
        pending.dueTicks = {}
        pending.nextAttempt = 1
        for attempt = 1, ROOF_REFRESH_ATTEMPTS do
            pending.dueTicks[attempt] = now
                + attempt * ROOF_REFRESH_DELAY_TICKS
        end
        local dueTickText = {}
        for attempt = 1, #pending.dueTicks do
            dueTickText[attempt] = tostring(pending.dueTicks[attempt])
        end
        print("[RailroaderRVTest] roof refresh group remote relocation ready room="
            .. pending.roomKey .. " members=" .. tostring(#pending.players)
            .. " target=rv-center-minus-offset dueTicks="
            .. table.concat(dueTickText, ","))
        return
    end
    if pending.relocationPhase == "refreshing" then
        local attempt = integer(pending.nextAttempt)
        local dueTick = attempt and pending.dueTicks
            and pending.dueTicks[attempt] or nil
        if not attempt or attempt < 1 or attempt > ROOF_REFRESH_ATTEMPTS
            or type(dueTick) ~= "number" then
            cancelPendingWallRoofRefresh(pending.roomKey, pending,
                "malformed roof refresh group remote wait schedule")
            return
        end
        if now < dueTick then return end
        -- Keep the complete group remote for the requested cross-tick cycle;
        -- room refresh is intentionally invoked only after every member returns.
        print("[RailroaderRVTest] roof refresh group remote wait room="
            .. pending.roomKey .. " attempt=" .. tostring(attempt) .. "/"
            .. tostring(ROOF_REFRESH_ATTEMPTS) .. " result=deferred")
        pending.nextAttempt = attempt + 1
        if attempt >= ROOF_REFRESH_ATTEMPTS then
            local started, detail = beginRoofRefreshPhase(nil, pending, "return")
            if not started then
                if detail == "requesting player disconnected or was replaced"
                    or detail == "another RV relocation or generation is in progress" then
                    pending.nextAttempt = attempt
                    return
                end
                cancelPendingWallRoofRefresh(pending.roomKey, pending, detail)
            else
                pending.relocationPhase = "returning"
                pending.returnToken = detail
                pending.returnArrived = false
                pending.returnCompleted = {}
                pending.refreshWorldApplied = false
                pending.refreshCompleted = false
                pending.refreshContextIndex = nil
                -- Room refresh is a continuously required post-return step. This
                -- is only a retry cadence, never a deadline that can retire
                -- the in-memory transaction while the squares are unloaded.
                pending.refreshRetryAtTick = now
                print("[RailroaderRVTest] roof refresh group return relocation started room="
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
                local arrival = server.consumeRoofRefreshRelocationArrival(
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
        -- any room-refresh callback. A refresh exception or a temporarily
        -- unavailable chunk must never strand a player in the remote target.
        for i = 1, #pending.players do
            local saved = pending.players[i]
            if not pending.returnCompleted[i] then
                local completeCallOk, completed, detail = pcall(
                    server.completeRoofRefreshRelocation, saved.player,
                    pending.returnToken)
                if completeCallOk and completed == true then
                    pending.returnCompleted[i] = true
                elseif completeCallOk then
                    print("[RailroaderRVTest] roof refresh group return wait player="
                        .. tostring(saved.identityKey) .. " detail="
                        .. tostring(detail or completed))
                else
                    print("[RailroaderRVTest] roof refresh group return error player="
                        .. tostring(saved.identityKey) .. " detail="
                        .. tostring(completed))
                end
            end
        end

        -- This is a hard phase barrier. A refresh callback is never allowed
        -- to mask one member's failed/unfinished authoritative return.
        local allCompleted = true
        for i = 1, #pending.players do
            if not pending.returnCompleted[i] then
                allCompleted = false
                break
            end
        end
        if not allCompleted then return end

        -- This is the same server-authoritative roof/room refresh path used
        -- by existing RV entry. It runs only after the physical return has
        -- been observed; every callback is bounded/isolated so it cannot
        -- interrupt the remaining members' return handling.
        local representative = pending.refreshContextIndex
            and pending.players[pending.refreshContextIndex] or nil
        if not representative then
            representative = pending.players[1]
            pending.refreshContextIndex = 1
        end
        local refreshRetryAtTick = pending.refreshRetryAtTick or now
        if pending.refreshWorldApplied ~= true
            and now >= refreshRetryAtTick then
            local loaded, loadedDetail = false,
                "roof refresh squares are not loaded after return"
            local loadedCallOk, loadedResult, loadedReason = pcall(
                server.roofRefreshSquaresLoaded, representative.player, record)
            if loadedCallOk then
                loaded, loadedDetail = loadedResult, loadedReason
            else
                loadedDetail = tostring(loadedResult)
            end
            if loaded == true then
                local refreshCallOk, refreshed, detail = pcall(
                    refreshRoofForPlayer, representative.player, record, true,
                    "remote-reload-return")
                if not refreshCallOk then
                    detail = tostring(refreshed)
                    refreshed = false
                end
                print("[RailroaderRVTest] roof refresh returned room="
                    .. tostring(pending.roomKey) .. " result="
                    .. (refreshed and "applied" or "deferred") .. " detail="
                    .. tostring(detail or "unknown"))
                if refreshed == true then
                    pending.refreshWorldApplied = true
                    pending.refreshRetryAtTick = nil
                else
                    pending.refreshRetryAtTick = now + ROOF_REFRESH_DELAY_TICKS
                    sendResult(representative.player, false,
                        detail or "roof refresh after remote reload was deferred")
                end
            else
                pending.refreshRetryAtTick = now + ROOF_REFRESH_DELAY_TICKS
                print("[RailroaderRVTest] roof refresh after return deferred room="
                    .. tostring(pending.roomKey) .. " detail=" .. tostring(loadedDetail
                        or "roof refresh squares are not loaded after return"))
            end
        end
        if pending.refreshWorldApplied == true
            and pending.refreshCompleted ~= true then
            local ackCallOk, acknowledged, ackDetail = pcall(
                server.completeRoofRefresh, representative.player,
                pending.returnToken)
            if ackCallOk and acknowledged == true then
                pending.refreshCompleted = true
            else
                print("[RailroaderRVTest] roof refresh completion remains pending room="
                    .. tostring(pending.roomKey) .. " detail="
                    .. tostring(ackCallOk and ackDetail or acknowledged))
            end
        end
        if allCompleted and pending.refreshCompleted == true then
            pending.relocationPhase = "complete"
            markSuppressedRoomTransition(pending)
            finishCompletedRoofRefresh(map, pending, record)
        end
        return
    end
    cancelPendingWallRoofRefresh(pending.roomKey, pending,
        "unknown roof refresh group transaction phase")
end

beginRoofRefreshPhase = function(player, pending, phase)
    local server = RailroaderRV and RailroaderRV.Server
    if not server then
        return false, "roof refresh relocation service is unavailable"
    end
    if type(pending.players) == "table" then
        if type(server.beginRoofRefreshRelocationGroup) ~= "function" then
            return false, "roof refresh group relocation service is unavailable"
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
            server.beginRoofRefreshRelocationGroup, {
                roomKey = pending.roomKey,
                rvId = pending.rvId,
                generation = pending.generation,
                phase = phase,
                players = phase == "temporary" and descriptors or nil,
            })
        if not ok then return false, tostring(started) end
        if started ~= true then
            return false, detail or "roof refresh group relocation was rejected"
        end
        return true, detail
    end
end

promoteFollowUpWallRemoval = function(map, roomKey)
    if pendingWallRoofRefreshes[roomKey] ~= nil then return false end
    local events = followUpWallRemovalEvents[roomKey]
    if type(events) ~= "table" then return false end
    local now = Adapter._ticks or Core.getTick()
    for eventKey, event in pairs(events) do
        if type(event) ~= "table" then
            events[eventKey] = nil
        elseif event.waitingForGeneration ~= true
            and now > event.expiresAtTick then
            events[eventKey] = nil
        else
            local waitingForGeneration = event.waitingForGeneration == true
            local record = recordForLoco(map, event.rvId)
            if not record or not validRecord(record) then
                if waitingForGeneration then
                    print("[RailroaderRVTest] wall removal follow-up cancelled room="
                        .. tostring(roomKey) .. " event=" .. tostring(eventKey)
                        .. " reason=" .. C.INVALID_RV_DATA)
                end
                events[eventKey] = nil
            else
                local currentRoomKey = roofRefreshRoomKey(record)
                if not currentRoomKey then
                    if waitingForGeneration then
                        print("[RailroaderRVTest] wall removal follow-up cancelled room="
                            .. tostring(roomKey) .. " event=" .. tostring(eventKey)
                            .. " reason=" .. C.INVALID_RV_DATA)
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
                            event.rvId = tostring(record.locoId)
                            if waitingForGeneration then
                                -- The current record/rvId/generation is now
                                -- proven complete. Give
                                -- this accepted event a fresh full lease.
                                event.expiresAtTick = now
                                    + ROOF_REFRESH_QUEUED_DEADLINE_TICKS
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
                            + ROOF_REFRESH_QUEUED_DEADLINE_TICKS
                        event.waitingForGeneration = nil
                    end
                    local scheduled = scheduleRoofRefresh(map, record,
                        "follow-up-wall-removal", eventKey,
                        event.coordinateKey)
                    if scheduled then
                        events[eventKey] = nil
                        return true
                    end
                    -- A transient busy/identity gate must not swallow a distinct
                    -- wall operation.  Keep the stable event until its explicit
                    -- expiry; mapping identity is checked on the next pass.
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
local function revalidateQueuedRoofRefreshAfterGeneration(map, roomKey,
    pending, now)
    if type(pending) ~= "table" or pending.relocationPhase ~= "queued" then
        return "ready"
    end
    local waitingForGeneration = pending.waitingForGeneration == true
    local deadline = pending.revalidateUntilTick
        or (now + WALL_REMOVAL_FOLLOWUP_TICKS)
    pending.revalidateUntilTick = deadline
    local record = recordForLoco(map, pending.rvId)
    local currentRoomKey = record and validRecord(record)
        and roofRefreshRoomKey(record) or nil
    local identityMatches = currentRoomKey == roomKey
        and integer(record and record.generation) == integer(pending.generation)
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
        and integer(record.generation) == integer(pending.generation) then
        -- A generation-owned queue had its old lease paused rather than
        -- consumed.  Once the complete current identity is confirmed, start
        -- a fresh bounded rebind window; never carry the pre-generation
        -- deadline into the new generation.
        if waitingForGeneration then
            pending.queuedDeadlineTick = now
                + ROOF_REFRESH_QUEUED_DEADLINE_TICKS
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
    local existing = pendingWallRoofRefreshes[currentRoomKey]
    if existing ~= nil and existing ~= pending then
        -- A room observation may have accepted a fresh current-generation
        -- schedule on the same tick.  Keep the older wall event as a bounded
        -- follow-up instead of overwriting that active transaction.
        local eventKey = pending.wallEventKey
        if type(eventKey) == "string" and eventKey ~= "" then
            rememberFollowUpWallRemoval(record, currentRoomKey, eventKey,
                pending.wallCoordinateKey, now)
            pendingWallRoofRefreshes[roomKey] = nil
            return "revalidated"
        end
        return "wait"
    end
    pendingWallRoofRefreshes[roomKey] = nil
    pending.roomKey = currentRoomKey
    pending.player = players[1].player
    pending.players = players
    pending.rvId = tostring(record.locoId)
    pending.generation = integer(record.generation)
    pending.identityKey = players[1].identityKey
    pending.returnPosition = players[1].originalPosition
    pending.startTick = now + 1
    pending.queuedDeadlineTick = now
        + ROOF_REFRESH_QUEUED_DEADLINE_TICKS
    pending.dueTicks = nil
    pending.nextAttempt = 1
    pending.relocationStarted = false
    pending.relocationPhase = "queued"
    pending.relocationToken = nil
    pending.returnToken = nil
    pending.waitingForGeneration = nil
    pending.revalidateUntilTick = nil
    pendingWallRoofRefreshes[currentRoomKey] = pending
    print("[RailroaderRVTest] roof refresh queue revalidated after generation room="
        .. currentRoomKey .. " source=" .. tostring(pending.source))
    return "revalidated"
end

ctx.cancelPendingWallRoofRefresh = cancelPendingWallRoofRefresh
ctx.finishCompletedRoofRefresh = finishCompletedRoofRefresh
ctx.expireQueuedWallRoofRefreshes = expireQueuedWallRoofRefreshes
ctx.processPendingWallRoofRefreshGroup = processPendingWallRoofRefreshGroup
ctx.promoteFollowUpWallRemoval = promoteFollowUpWallRemoval
ctx.revalidateQueuedRoofRefreshAfterGeneration = revalidateQueuedRoofRefreshAfterGeneration
end
