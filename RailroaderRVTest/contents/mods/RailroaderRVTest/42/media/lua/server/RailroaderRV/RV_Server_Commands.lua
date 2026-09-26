-- RV_Server: Commands responsibilities.
return function(ctx)
local RemovalTrace = require("RailroaderRV/RV_Server_ObjectRemovalTrace")
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND_RELOCATE_ACK = ctx.COMMAND_RELOCATE_ACK
local COMMAND_FINAL_RELOCATE_ACK = ctx.COMMAND_FINAL_RELOCATE_ACK
local COMMAND_RV_ENTER = ctx.COMMAND_RV_ENTER
local COMMAND_RV_EXIT = ctx.COMMAND_RV_EXIT
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local RV = ctx.RV
local ServerSchema = ctx.ServerSchema
local UtilityServer = ctx.UtilityServer
local LayoutBuilder = ctx.LayoutBuilder
local function safeErrorText(...) return ctx.safeErrorText(...) end
local RELOCATION_MIN_TICKS = ctx.RELOCATION_MIN_TICKS
local RELOCATION_POST_ACK_TICKS = ctx.RELOCATION_POST_ACK_TICKS
local RELOCATION_TIMEOUT_TICKS = ctx.RELOCATION_TIMEOUT_TICKS
local notifyFailure = ctx.notifyFailure
local requestRoomOwnershipScan = ctx.requestRoomOwnershipScan
local requestRoomOwnershipRemovalScan = ctx.requestRoomOwnershipRemovalScan
local processServerRoomOwnershipGuards = ctx.processServerRoomOwnershipGuards
local generationDisconnected = ctx.generationDisconnected
local pauseGenerationForDisconnect = ctx.pauseGenerationForDisconnect
local resumeGenerationAfterDisconnect = ctx.resumeGenerationAfterDisconnect
local keepGenerationTransitionAlive = ctx.keepGenerationTransitionAlive
local validateAuthoritativePlayer = ctx.validateAuthoritativePlayer
local validateGenerationPermission = ctx.validateGenerationPermission
local resolvePendingPlayer = ctx.resolvePendingPlayer
local playerIsAtStagingDestination = ctx.playerIsAtStagingDestination
local relocationPositionStillSyncing = ctx.relocationPositionStillSyncing
local processRoofRepairGroupFinalReturn = ctx.processRoofRepairGroupFinalReturn
local keepRoofRepairTransitionAlive = ctx.keepRoofRepairTransitionAlive
local validateRequest = ctx.validateRequest
local generateForPlayer = ctx.generateForPlayer
local finalizeGenerationAfterRelocate = ctx.finalizeGenerationAfterRelocate
local queueGeneration = ctx.queueGeneration
local acknowledgeRelocation = ctx.acknowledgeRelocation
local acknowledgeFinalRelocation = ctx.acknowledgeFinalRelocation
local cancelPending = ctx.cancelPending
local processRoofRepairRelocationGroup = ctx.processRoofRepairRelocationGroup

function RV.Server.OnTick()
    ctx.serverTick = ctx.serverTick + 1
    RemovalTrace.onTick(ctx.serverTick)
    -- Extend the token-scoped boundary lease before Boundary.onTick runs.  The
    -- roof transaction may temporarily place the player outside the active
    -- bitmap while the engine settles room state; correction must stay paused
    -- for that bounded transaction only.
    if not keepRoofRepairTransitionAlive() then return end
    if not keepGenerationTransitionAlive() then return end
    if Boundary and type(Boundary.onTick) == "function" then
        pcall(Boundary.onTick)
    end
    processServerRoomOwnershipGuards()
    processRoofRepairRelocationGroup()
    processRoofRepairGroupFinalReturn()
    if UtilityServer and type(UtilityServer.onTick) == "function" then
        local utilityOk, utilityError = pcall(UtilityServer.onTick, ctx.serverTick)
        if not utilityOk then
            print("[RailroaderRVTest] utility tick error: " .. safeErrorText(utilityError))
        end
    end
    local pending = ctx.pendingGeneration
    if pending == nil then
        return
    end
    if pending.cancelled == true then
        cancelPending(pending.failureReason or "generation transaction cancelled")
        return
    end
    local resolved, playerOrReason = resolvePendingPlayer(pending)
    if not resolved then
        -- A live server keeps the exact-float transaction until the same stable
        -- identity reconnects; no timeout or failure callback is run on a
        -- missing player object.
        if not generationDisconnected(playerOrReason) then
            cancelPending(playerOrReason)
        else
            pauseGenerationForDisconnect(pending)
        end
        return
    end
    resumeGenerationAfterDisconnect(pending)
    local elapsed = ctx.serverTick - pending.queuedAtTick
    if pending.finalRelocationSent ~= true
        and elapsed > RELOCATION_TIMEOUT_TICKS then
        cancelPending("relocation acknowledgement timed out before world mutation")
        return
    end
    if pending.railroader == nil then
        local permissionOk, permissionReason = validateGenerationPermission(playerOrReason)
        if not permissionOk then
            cancelPending(permissionReason)
            return
        end
    end
    -- Keep the liveness/world-coordinate check active while waiting for the
    -- server-side player object to observe the client relocation.  A stale
    -- coordinate is retryable, but a dead/invalid player is not.
    local stateCallOk, stateOk, stateOrReason = pcall(validateAuthoritativePlayer,
        playerOrReason)
    if not stateCallOk then
        cancelPending(safeErrorText(stateOk))
        return
    end
    if not stateOk then
        cancelPending(stateOrReason)
        return
    end
    if pending.finalRelocationSent == true then
        if not pending.finalRelocationAcked then
            if ctx.serverTick > (pending.finalRelocationDeadlineTick
                or ctx.serverTick) then
                cancelPending("final relocation acknowledgement timed out")
            end
            return
        end
        if ctx.serverTick > (pending.finalRelocationDeadlineTick or ctx.serverTick) then
            cancelPending("final relocation target synchronization timed out")
            return
        end
        local finalOk, finalReason = finalizeGenerationAfterRelocate(
            playerOrReason, pending)
        if finalOk then
            ctx.pendingGeneration = nil
            print("[RailroaderRVTest] generation committed READY")
        elseif finalReason == "final relocation authoritative target is still synchronizing" then
            -- The server object may still carry the previous staging packet;
            -- finalizeGenerationAfterRelocate has reasserted the fixed target
            -- and will require a fresh post-update proof on the next tick.
            return
        else
            pending.failureReason = finalReason
            pending.cancelled = true
            cancelPending(finalReason)
            print("[RailroaderRVTest] generation finalization failed: "
                .. safeErrorText(finalReason))
        end
        return
    end
    if not pending.acknowledged or elapsed < RELOCATION_MIN_TICKS
        or ctx.serverTick - pending.acknowledgedAtTick < RELOCATION_POST_ACK_TICKS then
        return
    end
    local atStaging, stagingReason = playerIsAtStagingDestination(playerOrReason,
        pending.stagingDestination, pending.bounds)
    if not atStaging then
        if relocationPositionStillSyncing(stagingReason) then
            return
        end
        cancelPending(stagingReason)
        return
    end

    -- The relocation itself is what streams the remote target.  Wait until
    -- every base square in the exact 100x100 footprint is present; no cleanup
    -- or other world mutation is allowed while this preflight is incomplete.
    local targetLoaded, targetLoadReason = ServerSchema.targetAreaLoadStatus(playerOrReason,
        pending.bounds, safeErrorText)
    if targetLoaded == nil then
        cancelPending(targetLoadReason)
        return
    end
    if not targetLoaded then
        return
    end

    local completedPending = pending
    local ok, reason = generateForPlayer(playerOrReason, completedPending)
    if not ok then
        completedPending.failureReason = reason
        completedPending.cancelled = true
        cancelPending(reason)
        print("[RailroaderRVTest] generation failed: " .. tostring(reason))
    elseif reason == "await-final-relocate" then
        print("[RailroaderRVTest] generation awaiting FinalRelocateAck")
    else
        ctx.pendingGeneration = nil
        print("[RailroaderRVTest] generation committed READY")
    end
end

function RV.Server.OnClientCommand(module, command, player, args)
    -- OnClientCommand is shared by every mod.  Foreign Railroader/vanilla
    -- commands are not RV requests and must not be reported as malformed RV
    -- traffic.
    if module ~= COMMAND_MODULE then
        return
    end
    if command == Constants.COMMAND_RV_UTILITY then
        local utilityOk, utilityAccepted, utilityReason = pcall(
            UtilityServer.handleCommand, player, args)
        if not utilityOk then
            print("[RailroaderRVTest] utility command error: "
                .. safeErrorText(utilityAccepted))
        elseif utilityAccepted ~= true then
            print("[RailroaderRVTest] utility command rejected: "
                .. safeErrorText(utilityReason))
        end
        return
    end
    -- The Railroader adapter owns these two commands.  This handler is also
    -- registered on the same event, so do not let the generic empty-payload
    -- validator log them as malformed Generate requests.
    if module == COMMAND_MODULE
        and (command == COMMAND_RV_ENTER or command == COMMAND_RV_EXIT) then
        RemovalTrace.lifecycle("request",
            command == COMMAND_RV_ENTER and "EnterRV" or "ExitRV",
            "received", ctx.serverTick)
        return
    end
    if command == Constants.COMMAND_LAYOUT_BUILD
        or command == Constants.COMMAND_LAYOUT_FINISH then
        local builderOk, accepted, reason = pcall(LayoutBuilder.handleCommand,
            command, player, args)
        if not builderOk then
            reason = safeErrorText(accepted)
            accepted = false
        end
        if accepted ~= true then
            notifyFailure(player, reason or "layout-builder request rejected")
            print("[RailroaderRVTest] layout-builder request rejected: "
                .. safeErrorText(reason or "unspecified reason"))
        end
        return
    end
    if module == COMMAND_MODULE and command == COMMAND_FINAL_RELOCATE_ACK then
        local ackOk, accepted, reason = pcall(acknowledgeFinalRelocation,
            player, args)
        if not ackOk then
            reason = safeErrorText(accepted)
            accepted = false
        end
        if not accepted then
            print("[RailroaderRVTest] final relocation acknowledgement rejected: "
                .. safeErrorText(reason))
        end
        return
    end
    if module == COMMAND_MODULE and command == COMMAND_RELOCATE_ACK then
        local ackOk, accepted, reason = pcall(acknowledgeRelocation, player, args)
        if not ackOk then
            reason = safeErrorText(accepted)
            accepted = false
        end
        if not accepted then
            print("[RailroaderRVTest] relocation acknowledgement rejected: "
                .. safeErrorText(reason))
        end
        return
    end
    local checkOk, accepted, reason = pcall(validateRequest, module, command, player, args)
    if not checkOk then
        reason = safeErrorText(accepted)
        accepted = false
    end
    if not accepted then
        print("[RailroaderRVTest] command rejected: " .. safeErrorText(reason))
        return
    end
    -- Request validation and ownership come from the server-side player object;
    -- generation coordinates come from the shared fixed target. Args are
    -- intentionally ignored to prevent client-side placement spoofing.
    local ok, reason = queueGeneration(player, reason)
    if not ok then
        notifyFailure(player, reason)
        print("[RailroaderRVTest] generation request failed: " .. tostring(reason))
    end
end

if Events and Events.OnClientCommand and type(Events.OnClientCommand.Add) == "function" then
    Events.OnClientCommand.Add(RV.Server.OnClientCommand)
end
if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(RV.Server.OnTick)
end
if Boundary and Events and Events.OnProcessAction
    and type(Events.OnProcessAction.Add) == "function" then
    Events.OnProcessAction.Add(Boundary.onProcessAction)
end
if Boundary and Events and Events.OnObjectAdded
    and type(Events.OnObjectAdded.Add) == "function" then
    Events.OnObjectAdded.Add(Boundary.onObjectAdded)
end
if Events and Events.OnObjectAboutToBeRemoved
    and type(Events.OnObjectAboutToBeRemoved.Add) == "function" then
    Events.OnObjectAboutToBeRemoved.Add(requestRoomOwnershipRemovalScan)
end
if Events and Events.OnObjectAdded and type(Events.OnObjectAdded.Add) == "function" then
    Events.OnObjectAdded.Add(requestRoomOwnershipScan)
end

-- Load after RV.Server has been fully constructed.  The adapter is intentionally
-- a separate file so the generic generation transaction remains readable and
-- the Railroader dependency stays optional for the technical test button.
local railroaderAdapterOk, railroaderAdapterOrError = pcall(require,
    "RailroaderRV/RV_RailroaderServer")
if not railroaderAdapterOk then
    print("[RailroaderRVTest] Railroader RV adapter unavailable: "
        .. safeErrorText(railroaderAdapterOrError))
elseif type(railroaderAdapterOrError) == "table"
    and type(railroaderAdapterOrError.installTransactionHooks) == "function" then
    -- Utility persistence validates the same current Railroader mapping and
    -- geometry as the generation transaction.  Keep these adapter gates on
    -- the public server facade so the commit hook does not fail closed merely
    -- because the optional adapter was loaded in its own module table.
    if type(railroaderAdapterOrError.resolveCurrentUtilityRV) == "function" then
        RV.Server.resolveCurrentUtilityRV =
            railroaderAdapterOrError.resolveCurrentUtilityRV
    end
    if type(railroaderAdapterOrError.validateCurrentUtilityIdentity) == "function" then
        RV.Server.validateCurrentUtilityIdentity =
            railroaderAdapterOrError.validateCurrentUtilityIdentity
    end
    if railroaderAdapterOrError.installTransactionHooks() then
        print("[RailroaderRVTest] Railroader RV transaction hooks installed.")
    else
        print("[RailroaderRVTest] Railroader RV transaction hooks unavailable.")
    end
end


end
