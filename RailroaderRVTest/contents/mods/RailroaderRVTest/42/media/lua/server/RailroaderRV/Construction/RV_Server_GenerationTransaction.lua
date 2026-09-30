-- RV_Server: GenerationTransaction owns the process-local generation record and
-- the generation half of the service-wide mutex.
--
-- The record is a plain table owned by its caller.  Callers write record fields
-- directly and `record.stage` is the single stage authority:
--   WAIT_STAGING -> BUILD -> WAIT_FINAL -> DONE
-- There is no snapshot, whitelist, semantic stage API or rollback ledger here.
return function()
    local record

    local api = {}

    function api.begin(player, recordTable)
        if record ~= nil then
            error("RailroaderRVTest: a generation transaction is already active")
        end
        if type(recordTable) ~= "table" or player == nil
            or recordTable.player ~= player then
            error("RailroaderRVTest: generation transaction record is invalid")
        end
        recordTable.stage = "WAIT_STAGING"
        record = recordTable
        return true
    end

    function api.current()
        return record
    end

    function api.owns(player, token)
        if record == nil then return false end
        if player ~= nil and record.player ~= player then return false end
        if token ~= nil and record.token ~= token then return false end
        return true
    end

    function api.isActive()
        return record ~= nil
    end

    function api.cancel(reason)
        if record == nil then return false end
        record.cancelled = true
        record.failureReason = reason
        return true
    end

    function api.release()
        record = nil
    end

    return api
end
