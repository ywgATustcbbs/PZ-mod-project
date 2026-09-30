-- RV_Server: GenerationTransaction owns the process-local generation record.
-- Callers receive detached snapshots and use semantic operations to advance it.
return function()
    local state

    local function copySnapshot(value, seen)
        if type(value) ~= "table" then return value end
        seen = seen or {}
        if seen[value] then return seen[value] end
        local result = {}
        seen[value] = result
        for key, entry in pairs(value) do
            result[copySnapshot(key, seen)] = copySnapshot(entry, seen)
        end
        return result
    end

    local function currentRecord()
        return state and state.record or nil
    end

    local function copyRecord(record)
        local view = {}
        local seen = { [record] = view }
        for key, value in pairs(record) do
            if key == "player" or key == "generationCell" then
                view[key] = value
            else
                view[copySnapshot(key, seen)] = copySnapshot(value, seen)
            end
        end
        -- Engine objects are identity-bearing references, not snapshot data.
        -- Keep them intact for owner checks and world rollback operations.
        return view
    end

    local function allowedStageTransition(from, to)
        if from == to then return true end
        if to == "cancelling" then return from ~= "ready" end
        if from == "queued" then return to == "building" end
        if from == "building" then return to == "final-relocation" end
        if from == "final-relocation" then return to == "committing" end
        if from == "committing" then return to == "ready" end
        return false
    end

    local stageFields = {
        ["final-relocation"] = {
            boundary = true,
            generationCell = true,
            finalRelocationSent = true,
            finalRelocationAcked = true,
            finalRelocationDeadlineTick = true,
        },
    }

    local function applyStageFields(record, stage, values)
        if values == nil then return true end
        if type(values) ~= "table" then return false end
        local accepted = stageFields[stage]
        if not accepted then
            for key in pairs(values) do return false end
            return true
        end
        for key, value in pairs(values) do
            if not accepted[key] then return false end
        end
        for key, value in pairs(values) do
            record[key] = key == "generationCell" and value
                or copySnapshot(value)
        end
        return true
    end

    local api = {}

    function api.begin(player, record)
        if state ~= nil then
            return false, "generation transaction already active"
        end
        if player == nil or type(record) ~= "table"
            or record.player ~= player
            or type(record.token) ~= "string" or record.token == ""
            or type(record.identity) ~= "table"
            or type(record.identity.key) ~= "string"
            or record.identity.key == "" then
            return false, "generation transaction identity is invalid"
        end
        local ownedRecord = copyRecord(record)
        -- IsoPlayer is an identity-bearing engine object, not snapshot data.
        -- Keep the exact reference so owner checks and disconnect rebinding
        -- continue to compare the live server object.
        ownedRecord.player = player
        ownedRecord.transactionStage = "queued"
        state = { record = ownedRecord, stage = "queued" }
        return true
    end

    function api.owns(player, token, stage)
        local record = currentRecord()
        if not record then return false end
        if player ~= nil and record.player ~= player then return false end
        if token ~= nil and record.token ~= token then return false end
        if stage ~= nil and state.stage ~= stage then return false end
        return true
    end

    function api.isActive()
        return state ~= nil
    end

    function api.current()
        local record = currentRecord()
        if not record then return nil end
        local view = copyRecord(record)
        view.transactionStage = state.stage
        return view
    end

    function api.advanceStage(stage, values)
        if not state or type(stage) ~= "string"
            or not allowedStageTransition(state.stage, stage) then
            return false
        end
        if not applyStageFields(state.record, stage, values) then
            return false
        end
        state.stage = stage
        state.record.transactionStage = stage
        return true
    end

    function api.recordAck(phase, tick)
        local record = currentRecord()
        if not record or phase == nil then return false end
        if phase == "temporary" then
            record.acknowledged = true
            record.acknowledgedAtTick = copySnapshot(tick)
            return true
        end
        if phase == "final" and record.finalRelocationSent == true then
            record.finalRelocationAcked = true
            record.finalRelocationAckAtTick = copySnapshot(tick)
            return true
        end
        return false
    end

    function api.markBoundaryCleared()
        local record = currentRecord()
        if not record then return false end
        record.boundaryCleared = true
        return true
    end

    function api.setPlayer(player, tick)
        local record = currentRecord()
        if not record or player == nil then return false end
        local previous = record.player
        record.player = player
        if previous ~= nil and previous ~= player then
            record.playerReboundAtTick = copySnapshot(tick)
            record.relocationNeedsResend = true
        end
        return true, previous, previous ~= player
    end

    function api.cancel(reason)
        local record = currentRecord()
        if not record or state.stage == "ready" then return false end
        record.failureReason = reason
        record.cancelled = true
        state.stage = "cancelling"
        record.transactionStage = state.stage
        return true
    end

    function api.rollback(outcome, retryAtTick)
        local record = currentRecord()
        if not record then return false end
        if outcome == "world-complete" then
            record.rollbackApplied = true
        elseif outcome == "world-retry" then
            record.rollbackWorldRetryAtTick = copySnapshot(retryAtTick)
        elseif outcome == "return-retry" then
            record.rollbackRetryAtTick = copySnapshot(retryAtTick)
        else
            return false
        end
        return true
    end

    function api.release(token)
        local record = currentRecord()
        if not record or (token ~= nil and token ~= record.token) then
            return false
        end
        state = nil
        return true
    end

    function api.pauseForDisconnect(tick)
        local record = currentRecord()
        if not record then return false end
        if record.disconnectStartedTick == nil then
            record.disconnectStartedTick = copySnapshot(tick)
        end
        return true
    end

    function api.resumeAfterDisconnect(now, elapsedTicks)
        local record = currentRecord()
        if not record or record.disconnectStartedTick == nil then
            return false
        end
        if type(elapsedTicks) == "number" and elapsedTicks > 0 then
            record.queuedAtTick = (record.queuedAtTick or now) + elapsedTicks
            if record.finalRelocationDeadlineTick ~= nil then
                record.finalRelocationDeadlineTick =
                    record.finalRelocationDeadlineTick + elapsedTicks
            end
        end
        record.disconnectStartedTick = nil
        record.relocationNeedsResend = true
        record.relocationRetryAtTick = copySnapshot(now)
        return true
    end

    function api.markRelocationSent(phase, sentAtTick, retryAtTick,
        finalDeadlineTick)
        local record = currentRecord()
        if not record then return false end
        if phase ~= "temporary" and phase ~= "final" and phase ~= "rollback" then
            return false
        end
        record.relocationLastSentTick = copySnapshot(sentAtTick)
        record.relocationRetryAtTick = copySnapshot(retryAtTick)
        record.relocationNeedsResend = false
        if phase == "temporary" then
            record.acknowledged = false
            record.acknowledgedAtTick = nil
        elseif phase == "final" then
            if record.finalRelocationDeadlineTick == nil
                and finalDeadlineTick ~= nil then
                record.finalRelocationDeadlineTick = copySnapshot(finalDeadlineTick)
            end
        else
            record.rollbackLastSentTick = copySnapshot(sentAtTick)
        end
        return true
    end

    function api.requestRelocationResend(retryAtTick)
        local record = currentRecord()
        if not record then return false end
        record.relocationNeedsResend = true
        if retryAtTick ~= nil then
            record.relocationRetryAtTick = copySnapshot(retryAtTick)
        end
        return true
    end

    function api.scheduleRelocationRetry(retryAtTick, needsResend)
        local record = currentRecord()
        if not record then return false end
        record.relocationRetryAtTick = copySnapshot(retryAtTick)
        record.relocationNeedsResend = needsResend == true
        return true
    end

    function api.markFinalRelocationReasserted()
        local record = currentRecord()
        if not record then return false end
        record.finalRelocationReasserted = true
        return true
    end

    function api.markInvalidRVDataNoticeSent()
        local record = currentRecord()
        if not record then return false end
        record.invalidRVDataNoticeSent = true
        return true
    end

    function api.markCommitApplied()
        local record = currentRecord()
        if not record then return false end
        record.commitApplied = true
        return true
    end

    return api
end
