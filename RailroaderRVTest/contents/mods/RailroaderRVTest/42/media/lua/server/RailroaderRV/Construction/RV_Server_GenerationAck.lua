-- RV_Server: GenerationAck responsibilities: the two client acknowledgements
-- the generation transaction genuinely waits for, and the single abort path.
return function(ctx)
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local ServerWorld = ctx.ServerWorld
local GenerationTransaction = ctx.GenerationTransaction
local function safeErrorText(...) return ctx.safeErrorText(...) end
local notifyFailure = ctx.notifyFailure
local removeGeneration = ctx.removeGeneration
local generationPositionProof = ctx.generationPositionProof
local playerIdentity = ctx.playerIdentity
local resolvePendingPlayer = ctx.resolvePendingPlayer

local function acknowledgeRelocation(player, args)
    -- RoofRefresh relocations share this command name; its own handler runs
    -- first so a roof acknowledgement is never mistaken for a generation one.
    local roofAck = ctx.acknowledgeRoofRefreshRelocation
    if type(roofAck) ~= "function" then
        return false, "roof refresh acknowledgement owner is unavailable"
    end
    local token = type(args) == "table" and args.token or nil
    local roofHandled, roofAccepted, roofReason = roofAck(player, token)
    if roofHandled then
        return roofAccepted, roofReason
    end
    local record = GenerationTransaction.current()
    if record == nil then
        return false, "no generation relocation is waiting for an acknowledgement"
    end
    if record.stage ~= "WAIT_STAGING" then
        return false, Constants.INVALID_RV_DATA
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk or identityOrReason.key ~= record.identity.key then
        return false, identityOk and "acknowledgement sender does not own the request"
            or identityOrReason
    end
    record.player = player
    record.stagingAcked = true
    -- The client only acknowledges after it has settled its current square, so
    -- this grant replaces the staging wait budget with the build wait budget.
    record.deadlineTick = ctx.serverTick
        + ctx.RELOCATION_TIMEOUT_TICKS
    return true
end

-- FinalRelocate has its own acknowledgement namespace.  The payload is
-- deliberately only the opaque token; every RV identity, destination and
-- room/guard fact is re-read from the server-owned in-memory record.
local function acknowledgeFinalRelocation(player, args)
    local record = GenerationTransaction.current()
    if record == nil or record.stage ~= "WAIT_FINAL" then
        return false, "no final relocation is waiting for an acknowledgement"
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk or identityOrReason.key ~= record.identity.key then
        return false, identityOk and "final acknowledgement sender does not own the request"
            or identityOrReason
    end
    local resolved, livePlayerOrReason = resolvePendingPlayer(record)
    if not resolved then return false, livePlayerOrReason end
    local target = record.finalDestination
    local proofOk, proofOrPosition = generationPositionProof(
        livePlayerOrReason, target)
    if not proofOk then
        local stateText = type(proofOrPosition) == "table"
            and (tostring(proofOrPosition.x) .. ","
                .. tostring(proofOrPosition.y) .. ","
                .. tostring(proofOrPosition.z))
            or safeErrorText(proofOrPosition)
        print("[RailroaderRVTest] final relocation target proof mismatch target="
            .. tostring(target.x) .. "," .. tostring(target.y) .. ","
            .. tostring(target.z) .. " state=" .. stateText)
        return false, "final relocation acknowledgement has no authoritative target proof"
    end
    if proofOrPosition == "target-cell" then
        print("[RailroaderRVTest] final relocation proof accepted target cell="
            .. tostring(math.floor(target.x)) .. ","
            .. tostring(math.floor(target.y)) .. ","
            .. tostring(target.z) .. " after B42 half-cell normalization")
    end
    record.player = livePlayerOrReason
    record.finalAcked = true
    return true
end

-- The one abort path.  This operation failed: log it, undo what the build
-- already touched, return the owner if it is still online, close the boundary
-- lease and let the player press the button again.  Nothing here retries or
-- defers; every step is best-effort, so one failure cannot block the rest.
local function abortGeneration(record, reason)
    if type(record) ~= "table" then return end
    local reasonText = safeErrorText(reason)
    print("[RailroaderRVTest] generation aborted identity="
        .. tostring(record.identity and record.identity.key or "unknown")
        .. " stage=" .. tostring(record.stage) .. " generation="
        .. tostring(record.generation) .. " reason=" .. reasonText)
    local resolved, livePlayerOrReason = resolvePendingPlayer(record)
    local livePlayer = resolved and livePlayerOrReason or record.player
    record.player = livePlayer
    if record.stage == "BUILD" or record.stage == "WAIT_FINAL" then
        -- The clear/build pass ran, so remove every object tagged for this
        -- generation before reporting the failure.  removeGeneration raises on
        -- any unverifiable rollback, so it is the one genuine protected step.
        local cellOk, cellOrReason = pcall(ServerWorld.getCellForPlayer, livePlayer)
        local rollbackOk, rollbackReason = false, cellOrReason
        if cellOk and cellOrReason then
            rollbackOk, rollbackReason = pcall(removeGeneration, cellOrReason,
                record.bounds, record.generation, record.rvId)
        end
        if not rollbackOk then
            print("[RailroaderRVTest] generation rollback failed: "
                .. safeErrorText(rollbackReason))
        end
    end
    if livePlayer ~= nil and type(record.originalPosition) == "table" then
        local returned, returnReason = ctx.sendStagingRelocation(record, "return")
        if not returned then
            print("[RailroaderRVTest] generation return relocation failed: "
                .. safeErrorText(returnReason))
        end
    end
    if livePlayer ~= nil and Boundary
        and type(Boundary.completeTransition) == "function" then
        pcall(Boundary.completeTransition, livePlayer, record.token)
    end
    if livePlayer ~= nil and record.railroader ~= nil
        and ctx.railroaderFailureHook then
        pcall(ctx.railroaderFailureHook, livePlayer, record.railroader,
            reason, record)
    end
    if type(reason) == "string" and Constants
        and type(Constants.INVALID_RV_DATA) == "string"
        and string.find(reason, Constants.INVALID_RV_DATA, 1, true) then
        notifyFailure(livePlayer, reason)
    end
    GenerationTransaction.release()
end

ctx.acknowledgeRelocation = acknowledgeRelocation
ctx.acknowledgeFinalRelocation = acknowledgeFinalRelocation
ctx.abortGeneration = abortGeneration
end
