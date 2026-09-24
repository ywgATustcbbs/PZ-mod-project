-- RV_Server: GenerationAck responsibilities.
return function(ctx)
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND_RELOCATE = ctx.COMMAND_RELOCATE
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local function safeErrorText(...) return ctx.safeErrorText(...) end
local function requireCurrentManifest(...) return ctx.requireCurrentManifest(...) end
local RELOCATION_MIN_TICKS = ctx.RELOCATION_MIN_TICKS
local RELOCATION_POST_ACK_TICKS = ctx.RELOCATION_POST_ACK_TICKS
local ROOF_RELOCATION_RETRY_TICKS = ctx.ROOF_RELOCATION_RETRY_TICKS
local GENERATION_RELOCATION_RETRY_TICKS = ctx.GENERATION_RELOCATION_RETRY_TICKS
local ROOF_REPAIR_TEMP_Z = ctx.ROOF_REPAIR_TEMP_Z
local notifyFailure = ctx.notifyFailure
local removeGeneration = ctx.removeGeneration
local manifestTable = ctx.manifestTable
local markGenerationFailed = ctx.markGenerationFailed
local tryAuthoritativePlayerPosition = ctx.tryAuthoritativePlayerPosition
local generationDisconnected = ctx.generationDisconnected
local pauseGenerationForDisconnect = ctx.pauseGenerationForDisconnect
local resumeGenerationAfterDisconnect = ctx.resumeGenerationAfterDisconnect
local rearmGenerationTransition = ctx.rearmGenerationTransition
local resendGenerationPhase = ctx.resendGenerationPhase
local resolveRoofRepairGroupPlayer = ctx.resolveRoofRepairGroupPlayer
local validateAuthoritativePlayer = ctx.validateAuthoritativePlayer
local authoritativePlayerPosition = ctx.authoritativePlayerPosition
local playerIdentity = ctx.playerIdentity
local resolvePendingPlayer = ctx.resolvePendingPlayer
local relocationPositionsEqual = ctx.relocationPositionsEqual
local currentRoofRepairContext = ctx.currentRoofRepairContext
local applyRoofRepairTeleport = ctx.applyRoofRepairTeleport
local roofRepairTargetReady = ctx.roofRepairTargetReady
local roofRepairGroupMember = ctx.roofRepairGroupMember
local failRoofRepairRelocationGroup = ctx.failRoofRepairRelocationGroup

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
    if ctx.roofRepairRelocationGroup then
        local token = ackPayloadToken(args)
        local member = token and roofRepairGroupMember(
            ctx.roofRepairRelocationGroup, player, token) or nil
        if not member then
            return false, "unexpected or malformed roof repair group acknowledgement"
        end
        local resolved, playerOrReason = resolvePendingPlayer(member)
        if not resolved then
            return false, playerOrReason
        end
        local identityOk, identityOrReason = playerIdentity(player)
        if not identityOk or identityOrReason.key ~= member.identityKey then
            return false, identityOk
                and "acknowledgement sender does not own the group request"
                or identityOrReason
        end
        member.acknowledged = true
        member.acknowledgedAtTick = ctx.serverTick
        return true
    end
    local pending = ctx.pendingGeneration
    local token = ackPayloadToken(args)
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
    pending.acknowledged = true
    pending.acknowledgedAtTick = ctx.serverTick
    return true
end

-- FinalRelocate has its own ACK namespace.  The payload is deliberately only
-- the opaque token; all RV identity, destination and room/guard evidence is
-- re-read from the server-owned pending plan and current manifest.
local function acknowledgeFinalRelocation(player, args)
    local pending = ctx.pendingGeneration
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
    local manifestOk, manifest = pcall(manifestTable)
    if not manifestOk or type(manifest) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local schemaOk = pcall(requireCurrentManifest, manifest, false)
    if not schemaOk or manifest.state ~= "RUNNING"
        or manifest.phase ~= "FINAL_RELOCATE"
        or tostring(manifest.rvId) ~= tostring(pending.rvId)
        or ServerUtil.integer(manifest.generation) ~= pending.generation
        or ServerUtil.integer(manifest.bitmapVersion) ~= pending.bitmapVersion then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local anchor = manifest.anchor
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
        return false, Constants.SAVE_REBUILD_REQUIRED
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
        pending.finalRelocationReasserted = true
        local targetReasserted = ServerUtil.callSucceeded(livePlayerOrReason,
            "teleportTo", target.x, target.y, target.z)
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
    pending.finalRelocationAcked = true
    pending.finalRelocationAckAtTick = ctx.serverTick
    return true
end

local function rollbackPendingGenerationWorld(pending, reason)
    if type(pending) ~= "table"
        or pending.finalRelocationSent ~= true
        or pending.rollbackApplied == true then
        return true
    end
    if ctx.serverTick < (pending.rollbackWorldRetryAtTick or 0) then
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
        pending.bounds, pending.generation, pending.rvId,
        pending.bitmapVersion)
    if not rollbackOk then
        manifest.rollback = "FAILED"
        pending.rollbackWorldRetryAtTick = ctx.serverTick
            + GENERATION_RELOCATION_RETRY_TICKS
        print("[RailroaderRVTest] final relocation rollback failed: "
            .. safeErrorText(rollbackReason))
        return false
    end
    manifest.rollback = "COMPLETE"
    local markedOk, marked, markedReason = pcall(markGenerationFailed, manifest,
        safeErrorText(reason or "final relocation acknowledgement failed"))
    if not markedOk or marked ~= true then
        pending.rollbackWorldRetryAtTick = ctx.serverTick
            + GENERATION_RELOCATION_RETRY_TICKS
        print("[RailroaderRVTest] final relocation failure marker deferred: "
            .. safeErrorText(markedOk and markedReason or marked))
        return false
    end
    pending.rollbackApplied = true
    ctx.transactionBusy = false
    ctx.transactionPlayer = nil
    return true
end

local function cancelPending(reason)
    local pending = ctx.pendingGeneration
    if not pending then return end
    pending.failureReason = reason
    pending.cancelled = true
    local resolved, livePlayerOrReason = resolvePendingPlayer(pending)
    if not resolved then
        if generationDisconnected(livePlayerOrReason) then
            pauseGenerationForDisconnect(pending)
        end
        ctx.transactionBusy = true
        ctx.transactionPlayer = nil
        print("[RailroaderRVTest] generation cancellation deferred identity="
            .. tostring(pending.identity and pending.identity.key or "unknown")
            .. " reason=" .. safeErrorText(livePlayerOrReason))
        return
    end
    local livePlayer = livePlayerOrReason
    pending.player = livePlayer
    resumeGenerationAfterDisconnect(pending)
    if pending.boundaryCleared ~= true
        and not rearmGenerationTransition(pending, livePlayer, "generation") then
        pending.rollbackRetryAtTick = ctx.serverTick
            + GENERATION_RELOCATION_RETRY_TICKS
        ctx.transactionBusy = true
        ctx.transactionPlayer = livePlayer
        return
    end
    if pending.finalRelocationSent == true and pending.rollbackApplied ~= true then
        local rollbackOk = rollbackPendingGenerationWorld(pending, reason)
        if not rollbackOk then
            ctx.transactionBusy = true
            ctx.transactionPlayer = livePlayer
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
            ctx.transactionBusy = true
            ctx.transactionPlayer = livePlayer
            return
        end
        if ctx.serverTick < (pending.rollbackRetryAtTick or 0) then
            ctx.transactionBusy = true
            ctx.transactionPlayer = livePlayer
            return
        end
        local returned = resendGenerationPhase(pending, livePlayer, "rollback")
        pending.rollbackRetryAtTick = ctx.serverTick
            + GENERATION_RELOCATION_RETRY_TICKS
        if not returned then
            ctx.transactionBusy = true
            ctx.transactionPlayer = livePlayer
            return
        end
        local afterOk, after = authoritativePlayerPosition(livePlayer)
        if not afterOk or not relocationPositionsEqual(after, original) then
            pending.rollbackRetryAtTick = ctx.serverTick
                + GENERATION_RELOCATION_RETRY_TICKS
            ctx.transactionBusy = true
            ctx.transactionPlayer = livePlayer
            return
        end
    end
    if pending.boundaryCleared ~= true and Boundary
        and type(Boundary.completeTransition) == "function"
        and pending.token ~= nil then
        local completeOk, complete = pcall(Boundary.completeTransition,
            livePlayer, pending.token)
        if not completeOk or complete ~= true then
            pending.rollbackRetryAtTick = ctx.serverTick
                + GENERATION_RELOCATION_RETRY_TICKS
            ctx.transactionBusy = true
            ctx.transactionPlayer = livePlayer
            return
        end
    end
    if pending.railroader ~= nil and ctx.railroaderFailureHook then
        pcall(ctx.railroaderFailureHook, livePlayer, pending.railroader, reason,
            pending)
    end
    notifyFailure(livePlayer, reason)
    ctx.pendingGeneration = nil
    ctx.transactionBusy = false
    ctx.transactionPlayer = nil
    print("[RailroaderRVTest] queued generation cancelled player="
        .. tostring(pending.identity and pending.identity.key or "unknown") .. ": "
        .. safeErrorText(reason))
end

local function roofRepairRelocationPositionStillSyncing(reason)
    return reason == "server player has not reached the roof repair destination"
        or reason == "server player has no current square after roof repair relocation"
        or reason == "server player current square does not match roof repair destination"
        or reason == "roof repair temporary destination cell is not loaded"
        or reason == "roof repair temporary destination square is not loaded"
        or reason == "roof repair temporary destination is still room geometry"
end

local function processRoofRepairRelocationGroup()
    local group = ctx.roofRepairRelocationGroup
    if not group then return end
    -- A live process owns the exact-float group across a player disconnect.
    -- Defer all phase work until every stable identity has a live IsoPlayer;
    -- this avoids converting a reconnect into a failed/cancelled transaction.
    for i = 1, #(group.members or {}) do
        local resolved = resolveRoofRepairGroupPlayer(group,
            group.members[i])
        if not resolved then return end
    end
    if ctx.serverTick > (group.deadlineTick or ctx.serverTick) then
        failRoofRepairRelocationGroup("roof repair group relocation transaction timed out")
        return
    end
    for i = 1, #(group.members or {}) do
        local member = group.members[i]
        if not member.arrived then
            local resolved, playerOrReason = resolveRoofRepairGroupPlayer(
                group, member)
            if not resolved then
                return
            end
            local stateCallOk, stateOk, stateOrReason = pcall(
                validateAuthoritativePlayer, playerOrReason)
            if not stateCallOk then
                failRoofRepairRelocationGroup(safeErrorText(stateOk))
                return
            end
            if not stateOk then
                failRoofRepairRelocationGroup(stateOrReason)
                return
            end
            local contextCallOk, contextOk, contextOrReason = pcall(
                currentRoofRepairContext, playerOrReason, {
                    rvId = member.rvId, generation = member.generation,
                    bitmapVersion = member.bitmapVersion,
                    identityKey = member.identityKey,
                })
            if not contextCallOk then
                contextOrReason = safeErrorText(contextOk)
                contextOk = false
            end
            if not contextOk then
                failRoofRepairRelocationGroup(contextOrReason)
                return
            end
            local target = group.phase == "temporary"
                and group.target or member.target
            if group.phase == "return" then
                local exactCallOk, exactPosition =
                    tryAuthoritativePlayerPosition(playerOrReason)
                -- The client ACK plus floor/z proof is enough to stop a
                -- duplicate return packet.  If the engine normalized a
                -- fractional x/y, completeRoofRepairRelocation reasserts the
                -- captured float before it releases the lease.
                local atTarget = exactCallOk and type(exactPosition) == "table"
                    and math.floor(exactPosition.x) == math.floor(target.x)
                    and math.floor(exactPosition.y) == math.floor(target.y)
                    and math.floor(exactPosition.z) == math.floor(target.z)
                    and exactPosition.z ~= ROOF_REPAIR_TEMP_Z
                if not atTarget then
                    local waitLogTick = member.returnTargetLogTick or -math.huge
                    if ctx.serverTick - waitLogTick >= 30 then
                        local positionText = exactCallOk
                            and type(exactPosition) == "table"
                            and (tostring(exactPosition.x) .. ","
                                .. tostring(exactPosition.y) .. ","
                                .. tostring(exactPosition.z))
                            or safeErrorText(exactPosition)
                        print("[RailroaderRVTest] roof repair group return target wait room="
                            .. tostring(group.roomKey or "unknown") .. " player="
                            .. tostring(member.identityKey) .. " position="
                            .. positionText .. " target=" .. tostring(target.x) .. ","
                            .. tostring(target.y) .. "," .. tostring(target.z))
                        member.returnTargetLogTick = ctx.serverTick
                    end
                    if member.acknowledged == true then
                        -- The client has already proved that it applied this
                        -- token.  Do not clear that ACK and send an endless
                        -- stream of return commands just because a stale
                        -- PlayerPacket briefly put the server object back at
                        -- the remote point.  Reassert server coordinates only;
                        -- the normal target/current-square proof below still
                        -- gates arrival and lease release.
                        local moved = applyRoofRepairTeleport(playerOrReason,
                            target, false)
                        member.relocationNeedsResend = not moved
                        if moved then
                            exactCallOk, exactPosition =
                                tryAuthoritativePlayerPosition(playerOrReason)
                            atTarget = exactCallOk
                                and type(exactPosition) == "table"
                                and math.floor(exactPosition.x) == math.floor(target.x)
                                and math.floor(exactPosition.y) == math.floor(target.y)
                                and math.floor(exactPosition.z) == math.floor(target.z)
                                and exactPosition.z ~= ROOF_REPAIR_TEMP_Z
                        end
                    else
                        -- A stale/fallen member without an ACK needs the same
                        -- return command again, but never once per tick.
                        member.arrivalConsumed = false
                        member.completed = false
                        member.arrived = false
                        member.relocationNeedsResend = true
                        if ctx.serverTick < (member.relocationRetryAtTick or 0) then
                            -- Wait for the bounded retry cadence below.
                        elseif type(member.returnPayload) ~= "table" then
                            failRoofRepairRelocationGroup(
                                "roof repair group return payload is unavailable")
                            return
                        else
                            local sentOk = ServerUtil.callGlobalSucceeded("sendServerCommand",
                                playerOrReason, COMMAND_MODULE, COMMAND_RELOCATE,
                                member.returnPayload)
                            local moved = applyRoofRepairTeleport(playerOrReason,
                                target, false)
                            member.relocationLastSentTick = ctx.serverTick
                            member.relocationRetryAtTick = ctx.serverTick
                                + ROOF_RELOCATION_RETRY_TICKS
                            if not sentOk or not moved then
                                -- A transient send/teleport failure is retried
                                -- with this token; the transaction timeout is
                                -- still the final bounded failure path.
                                member.relocationNeedsResend = true
                            else
                                member.relocationNeedsResend = false
                            end
                        end
                    end
                end
            end
            local elapsed = ctx.serverTick - group.queuedAtTick
            if not member.acknowledged
                or elapsed < RELOCATION_MIN_TICKS
                or ctx.serverTick - (member.acknowledgedAtTick or ctx.serverTick)
                    < RELOCATION_POST_ACK_TICKS then
                -- The player may still be synchronizing its current square;
                -- do not treat an absent ACK as a permanent failure yet.
            else
                    local readyCallOk, ready, readyReason = pcall(
                        roofRepairTargetReady, playerOrReason, target,
                        group.phase, group.allowedPlayers)
                    if not readyCallOk then
                        readyReason = safeErrorText(ready)
                        ready = false
                    end
                if not ready then
                    if roofRepairRelocationPositionStillSyncing(readyReason) then
                        -- Wait for the authoritative square/current cell to
                        -- settle on the next server tick.
                    else
                        failRoofRepairRelocationGroup(readyReason)
                        return
                    end
                else
                    member.arrived = true
                    member.arrivedAtTick = ctx.serverTick
                    print("[RailroaderRVTest] roof repair group member arrived room="
                        .. tostring(group.roomKey or "unknown") .. " player="
                        .. tostring(member.identityKey) .. " phase="
                        .. tostring(group.phase) .. " target="
                        .. tostring(target.x) .. "," .. tostring(target.y)
                        .. "," .. tostring(target.z))
                end
            end
        end
    end
end


ctx.acknowledgeRelocation = acknowledgeRelocation
ctx.acknowledgeFinalRelocation = acknowledgeFinalRelocation
ctx.cancelPending = cancelPending
ctx.processRoofRepairRelocationGroup = processRoofRepairRelocationGroup
end
