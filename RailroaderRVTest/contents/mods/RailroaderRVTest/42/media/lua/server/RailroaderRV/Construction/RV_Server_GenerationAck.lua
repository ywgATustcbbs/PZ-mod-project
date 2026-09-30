-- RV_Server: GenerationAck responsibilities.
return function(ctx)
local Core = ctx.Core
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND_RELOCATE = ctx.COMMAND_RELOCATE
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local GenerationTransaction = ctx.GenerationTransaction
local function safeErrorText(...) return ctx.safeErrorText(...) end
local RELOCATION_MIN_TICKS = ctx.RELOCATION_MIN_TICKS
local RELOCATION_POST_ACK_TICKS = ctx.RELOCATION_POST_ACK_TICKS
local GENERATION_RELOCATION_RETRY_TICKS = ctx.GENERATION_RELOCATION_RETRY_TICKS
local notifyFailure = ctx.notifyFailure
local function isInvalidRVData(reason)
    local marker = Constants and Constants.INVALID_RV_DATA
    return type(marker) == "string" and marker ~= ""
        and string.find(tostring(reason), marker, 1, true) ~= nil
end
local removeGeneration = ctx.removeGeneration
local manifestTable = ctx.manifestTable
local markGenerationFailed = ctx.markGenerationFailed
local tryAuthoritativePlayerPosition = ctx.tryAuthoritativePlayerPosition
local generationDisconnected = ctx.generationDisconnected
local pauseGenerationForDisconnect = ctx.pauseGenerationForDisconnect
local resumeGenerationAfterDisconnect = ctx.resumeGenerationAfterDisconnect
local rearmGenerationTransition = ctx.rearmGenerationTransition
local resendGenerationPhase = ctx.resendGenerationPhase
local authoritativePlayerPosition = ctx.authoritativePlayerPosition
local playerIdentity = ctx.playerIdentity
local resolvePendingPlayer = ctx.resolvePendingPlayer
local relocationPositionsEqual = ctx.relocationPositionsEqual

local function ackPayloadToken(args)
    if args == nil then
        return nil
    end
    local token = args.token
    if type(token) ~= "string" or token == "" then
        return nil
    end
    if type(args) == "table" then
        local count = 0
        for key in pairs(args) do
            if key ~= "token" then
                return nil
            end
            count = count + 1
        end
        return count == 1 and token or nil
    end
    if not ServerUtil.classInstance(args, "PZNetKahluaTableImpl") then
        return nil
    end
    local sizeOk, size = ServerUtil.invoke(args, "size")
    if not sizeOk or ServerUtil.toNumber(size) ~= 1 then
        return nil
    end
    return token
end

local function acknowledgeRelocation(player, args)
    local token = ackPayloadToken(args)
    local roofAck = ctx.acknowledgeRoofRefreshRelocation
    if type(roofAck) ~= "function" then
        return false, "roof refresh acknowledgement owner is unavailable"
    end
    local roofHandled, roofAccepted, roofReason = roofAck(player, token)
    if roofHandled then
        return roofAccepted, roofReason
    end
    local pending = GenerationTransaction.current()
    if pending == nil or token == nil or token ~= pending.token then
        return false, "unexpected or malformed relocation acknowledgement"
    end
    local resolved, playerOrReason = resolvePendingPlayer(pending)
    if not resolved then
        return false, playerOrReason
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk or identityOrReason.key ~= pending.identity.key then
        return false, identityOk and "acknowledgement sender does not own the request"
            or identityOrReason
    end
    return GenerationTransaction.recordAck("temporary", ctx.serverTick)
end

-- FinalRelocate has its own ACK namespace.  The payload is deliberately only
-- the opaque token; all RV identity, destination and room/guard evidence is
-- re-read from the server-owned pending plan and current manifest.
local function acknowledgeFinalRelocation(player, args)
    local pending = GenerationTransaction.current()
    local token = ackPayloadToken(args)
    if not pending or pending.finalRelocationSent ~= true
        or token == nil or token ~= pending.token then
        return false, "unexpected or malformed final relocation acknowledgement"
    end
    local resolved, livePlayerOrReason = resolvePendingPlayer(pending)
    if not resolved then return false, livePlayerOrReason end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk or identityOrReason.key ~= pending.identity.key then
        return false, identityOk
            and "final acknowledgement sender does not own the request"
            or identityOrReason
    end
    -- The in-flight stage is the authority for "this ACK belongs to a
    -- relocation that is still waiting"; the durable record never held it.
    if pending.transactionStage ~= "final-relocation" then
        return false, Constants.INVALID_RV_DATA
    end
    local anchor = pending.anchor
    local anchorX = type(anchor) == "table"
        and ServerUtil.requiredInteger(anchor.x, "final acknowledgement anchor x") or nil
    local anchorY = type(anchor) == "table"
        and ServerUtil.requiredInteger(anchor.y, "final acknowledgement anchor y") or nil
    local anchorZ = type(anchor) == "table"
        and ServerUtil.requiredInteger(anchor.z, "final acknowledgement anchor z") or nil
    local target = pending.finalDestination
    if anchorX == nil or anchorY == nil or anchorZ == nil
        or type(target) ~= "table"
        or target.x ~= anchorX + 0.5 or target.y ~= anchorY + 0.5
        or target.z ~= anchorZ then
        return false, Constants.INVALID_RV_DATA
    end
    local stateOk, state = authoritativePlayerPosition(livePlayerOrReason)
    local finalPositionOk = stateOk and relocationPositionsEqual(state, target)
    local finalPositionMatch = finalPositionOk and "exact" or "mismatch"
    -- The client ACK is sent only after its own room/guard proof, but the
    -- server's IsoPlayer can still expose the pre-teleport position for one
    -- network tick (or be normalized by the movement update).  Re-assert the
    -- server-selected target once before rejecting the token.  No coordinate
    -- from the client is used here; a second proof read remains mandatory.
    if not finalPositionOk and stateOk
        and pending.finalRelocationReasserted ~= true then
        GenerationTransaction.markFinalRelocationReasserted()
        local targetReasserted = RV.Server.teleportToPosition(
            livePlayerOrReason, target)
            and ServerUtil.callSucceeded(livePlayerOrReason, "setX", target.x)
            and ServerUtil.callSucceeded(livePlayerOrReason, "setY", target.y)
            and ServerUtil.callSucceeded(livePlayerOrReason, "setZ", target.z)
            and ServerUtil.callSucceeded(livePlayerOrReason, "setLastX", target.x)
            and ServerUtil.callSucceeded(livePlayerOrReason, "setLastY", target.y)
        if targetReasserted then
            stateOk, state = authoritativePlayerPosition(livePlayerOrReason)
            finalPositionOk = stateOk and relocationPositionsEqual(state, target)
            finalPositionMatch = finalPositionOk and "reasserted" or "mismatch"
            if not finalPositionOk and stateOk
                and type(state) == "table"
                and state.x ~= nil and state.y ~= nil and state.z ~= nil
                and target.x ~= nil and target.y ~= nil and target.z ~= nil
                and math.floor(target.x) ~= target.x
                and math.floor(target.y) ~= target.y
                and state.z == target.z
                and math.floor(state.x) == math.floor(target.x)
                and math.floor(state.y) == math.floor(target.y) then
                finalPositionOk = true
                finalPositionMatch = "target-cell"
            end
        end
    end
    if not finalPositionOk and stateOk
        and type(state) == "table"
        and state.x ~= nil and state.y ~= nil and state.z ~= nil
        and target.x ~= nil and target.y ~= nil and target.z ~= nil
        and math.floor(target.x) ~= target.x
        and math.floor(target.y) ~= target.y
        and state.z == target.z
        and math.floor(state.x) == math.floor(target.x)
        and math.floor(state.y) == math.floor(target.y) then
        finalPositionOk = true
        finalPositionMatch = "target-cell"
    end
    if not finalPositionOk then
        local stateText = stateOk and type(state) == "table"
            and (tostring(state.x) .. "," .. tostring(state.y) .. ","
                .. tostring(state.z)) or safeErrorText(state)
        print("[RailroaderRVTest] final relocation target proof mismatch target="
            .. tostring(target.x) .. "," .. tostring(target.y) .. ","
            .. tostring(target.z) .. " state=" .. stateText)
        return false, "final relocation acknowledgement has no authoritative target proof"
    end
    if finalPositionMatch == "target-cell" then
        print("[RailroaderRVTest] final relocation proof accepted target cell="
            .. tostring(math.floor(target.x)) .. ","
            .. tostring(math.floor(target.y)) .. ","
            .. tostring(target.z) .. " after B42 half-cell normalization")
    end
    return GenerationTransaction.recordAck("final", ctx.serverTick)
end

local function rollbackPendingGenerationWorld(pending, reason)
    if type(pending) ~= "table"
        or pending.finalRelocationSent ~= true
        or pending.rollbackApplied == true then
        return true
    end
    if not Core.tickReached(ctx.serverTick,
        pending.rollbackWorldRetryAtTick or { hi32 = 0, lo32 = 0 }) then
        return false
    end
    local manifest = pending.manifest
    if type(manifest) ~= "table" then
        local manifestOk, manifestOrReason = pcall(manifestTable)
        if not manifestOk or type(manifestOrReason) ~= "table" then
            print("[RailroaderRVTest] final relocation rollback deferred reason="
                .. safeErrorText(manifestOrReason))
            return false
        end
        manifest = manifestOrReason
    end
    local cell = pending.generationCell
    if not cell then
        local cellOk, cellOrReason = pcall(ServerWorld.getCellForPlayer, pending.player)
        if not cellOk or not cellOrReason then
            print("[RailroaderRVTest] final relocation rollback deferred reason="
                .. safeErrorText(cellOrReason))
            return false
        end
        cell = cellOrReason
    end
    local rollbackOk, rollbackReason = pcall(removeGeneration, cell,
        pending.bounds, pending.generation, pending.rvId)
    if not rollbackOk then
        GenerationTransaction.rollback("world-retry",
            Core.tickAdd(ctx.serverTick, GENERATION_RELOCATION_RETRY_TICKS))
        print("[RailroaderRVTest] final relocation rollback failed: "
            .. safeErrorText(rollbackReason))
        return false
    end
    local markedOk, marked, markedReason = pcall(markGenerationFailed, manifest,
        safeErrorText(reason or "final relocation acknowledgement failed"))
    if not markedOk or marked ~= true then
        GenerationTransaction.rollback("world-retry",
            Core.tickAdd(ctx.serverTick, GENERATION_RELOCATION_RETRY_TICKS))
        print("[RailroaderRVTest] final relocation failure marker deferred: "
            .. safeErrorText(markedOk and markedReason or marked))
        return false
    end
    GenerationTransaction.rollback("world-complete")
    return true
end

local function cancelPending(reason)
    if not GenerationTransaction.cancel(reason) then return end
    local pending = GenerationTransaction.current()
    if not pending then return end
    local resolved, livePlayerOrReason = resolvePendingPlayer(pending)
    if not resolved then
        if generationDisconnected(livePlayerOrReason) then
            pauseGenerationForDisconnect(pending)
        end
        print("[RailroaderRVTest] generation cancellation deferred identity="
            .. tostring(pending.identity and pending.identity.key or "unknown")
            .. " reason=" .. safeErrorText(livePlayerOrReason))
        return
    end
    local livePlayer = livePlayerOrReason
    if isInvalidRVData(reason) and pending.invalidRVDataNoticeSent ~= true then
        if notifyFailure(livePlayer, reason) == true then
            GenerationTransaction.markInvalidRVDataNoticeSent()
        end
    end
    resumeGenerationAfterDisconnect(pending)
    pending = GenerationTransaction.current() or pending
    if pending.boundaryCleared ~= true
        and not rearmGenerationTransition(pending, livePlayer, "generation") then
        GenerationTransaction.rollback("return-retry", Core.tickAdd(
            ctx.serverTick, GENERATION_RELOCATION_RETRY_TICKS))
        return
    end
    if pending.finalRelocationSent == true and pending.rollbackApplied ~= true then
        local rollbackOk = rollbackPendingGenerationWorld(pending, reason)
        if not rollbackOk then
            return
        end
    end
    local positionOk, position = authoritativePlayerPosition(livePlayer)
    local original = pending.originalPosition
    local atOriginal = positionOk and type(position) == "table"
        and type(original) == "table"
        and relocationPositionsEqual(position, original)
    if not atOriginal then
        if type(original) ~= "table" then
            return
        end
        if not Core.tickReached(ctx.serverTick,
            pending.rollbackRetryAtTick or { hi32 = 0, lo32 = 0 }) then
            return
        end
        local returned = resendGenerationPhase(pending, livePlayer, "rollback")
        GenerationTransaction.rollback("return-retry", Core.tickAdd(
            ctx.serverTick, GENERATION_RELOCATION_RETRY_TICKS))
        if not returned then
            return
        end
        local afterOk, after = authoritativePlayerPosition(livePlayer)
        if not afterOk or not relocationPositionsEqual(after, original) then
            GenerationTransaction.rollback("return-retry", Core.tickAdd(
                ctx.serverTick, GENERATION_RELOCATION_RETRY_TICKS))
            return
        end
    end
    if pending.boundaryCleared ~= true and Boundary
        and type(Boundary.completeTransition) == "function"
        and pending.token ~= nil then
        local completeOk, complete = pcall(Boundary.completeTransition,
            livePlayer, pending.token)
        if not completeOk or complete ~= true then
            GenerationTransaction.rollback("return-retry", Core.tickAdd(
                ctx.serverTick, GENERATION_RELOCATION_RETRY_TICKS))
            return
        end
    end
    if pending.railroader ~= nil and ctx.railroaderFailureHook then
        pcall(ctx.railroaderFailureHook, livePlayer, pending.railroader, reason,
            pending)
    end
    if pending.invalidRVDataNoticeSent ~= true then
        notifyFailure(livePlayer, reason)
    end
    GenerationTransaction.release(pending.token)
    print("[RailroaderRVTest] queued generation cancelled player="
        .. tostring(pending.identity and pending.identity.key or "unknown") .. ": "
        .. safeErrorText(reason))
end

ctx.acknowledgeRelocation = acknowledgeRelocation
ctx.acknowledgeFinalRelocation = acknowledgeFinalRelocation
ctx.cancelPending = cancelPending
end
