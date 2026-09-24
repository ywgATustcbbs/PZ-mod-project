-- RV_Server: GenerationFlow responsibilities.
return function(ctx)
local OWNER = ctx.OWNER
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND = ctx.COMMAND
local COMMAND_RELOCATE = ctx.COMMAND_RELOCATE
local COMMAND_FINAL_RELOCATE = ctx.COMMAND_FINAL_RELOCATE
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local ServerSchema = ctx.ServerSchema
local function safeErrorText(...) return ctx.safeErrorText(...) end
local function requireCurrentManifest(...) return ctx.requireCurrentManifest(...) end
local RELOCATION_TIMEOUT_TICKS = ctx.RELOCATION_TIMEOUT_TICKS
local removeOldGeneration = ctx.removeOldGeneration
local registerServerRoomOwnershipGuard = ctx.registerServerRoomOwnershipGuard
local refreshServerRoomOwnershipGuard = ctx.refreshServerRoomOwnershipGuard
local armClientRoomOwnershipGuard = ctx.armClientRoomOwnershipGuard
local removeGeneration = ctx.removeGeneration
local setManifestState = ctx.setManifestState
local manifestTable = ctx.manifestTable
local setGenerationPhase = ctx.setGenerationPhase
local clearGenerationArea = ctx.clearGenerationArea
local buildGeneration = ctx.buildGeneration
local finalizeGeneration = ctx.finalizeGeneration
local validateAuthoritativePlayer = ctx.validateAuthoritativePlayer
local authoritativePlayerPosition = ctx.authoritativePlayerPosition
local validateGenerationPermission = ctx.validateGenerationPermission
local playerIdentity = ctx.playerIdentity
local relocationPositionsEqual = ctx.relocationPositionsEqual
local selectGenerationStagingDestination = ctx.selectGenerationStagingDestination
local playerIsAtStagingDestination = ctx.playerIsAtStagingDestination

local function validateRequest(module, command, player, args)
    if module ~= COMMAND_MODULE then
        return false, "invalid command module"
    end
    if command ~= COMMAND then
        return false, "invalid command"
    end
    if not ServerUtil.isEmptyCommandArgs(args) then
        return false, "command args must be nil or an empty table"
    end
    local ok, positionOrReason = validateAuthoritativePlayer(player)
    if not ok then
        return false, positionOrReason
    end
    local permissionOk, permissionReason = validateGenerationPermission(player)
    if not permissionOk then
        return false, permissionReason
    end
    return true, positionOrReason
end

-- Deliver the final in-house relocation only after buildGeneration succeeds.
-- The payload is created entirely from the server's prepared anchor; the
-- client never sends coordinates and completion uses a separate token-only ACK.
local function relocatePlayerIntoHouse(player, prepared)
    local destination = prepared.finalDestination
    local anchor = prepared.anchor
    if type(destination) ~= "table" or type(anchor) ~= "table" then
        error("RailroaderRVTest: final relocation contract is incomplete")
    end
    local x = ServerUtil.requiredNumber(destination.x, "final relocation x")
    local y = ServerUtil.requiredNumber(destination.y, "final relocation y")
    local z = ServerUtil.requiredNumber(destination.z, "final relocation z")
    local anchorX = ServerUtil.requiredInteger(anchor.x, "final relocation anchor x")
    local anchorY = ServerUtil.requiredInteger(anchor.y, "final relocation anchor y")
    local anchorZ = ServerUtil.requiredInteger(anchor.z, "final relocation anchor z")
    if x ~= anchorX + 0.5 or y ~= anchorY + 0.5 or z ~= anchorZ then
        error("RailroaderRVTest: final relocation is not the house interior center")
    end
    local finalPayload = {
            token = prepared.token,
            generation = ServerUtil.requiredInteger(prepared.generation,
                "final relocation generation"),
            rvId = tostring(prepared.rvId),
            bitmapVersion = ServerUtil.requiredInteger(prepared.boundary
                and prepared.boundary.bitmapVersion,
                "final relocation bitmapVersion"),
            mapSchemaVersion = Constants.MAP_SCHEMA_VERSION,
            onlineId = prepared.identity.onlineId,
            x = x,
            y = y,
            z = z,
    }
    -- Railroader generation removed the official seat before staging.  Carry
    -- only a transition hint so the client adapter can run Ride.dismount(true)
    -- before this final RV teleport; seat truth still comes from Railroader's
    -- next server snapshot.
    if type(prepared.railroader) == "table" then
        finalPayload.railroaderTransition = true
        finalPayload.action = "enter"
        finalPayload.locoId = prepared.railroader.locoId
        finalPayload.role = prepared.railroader.sourceRole
        finalPayload.seat = prepared.railroader.sourceSeat
    end
    local sentOk = ServerUtil.callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_FINAL_RELOCATE, finalPayload)
    if not sentOk then
        error("RailroaderRVTest: final server-to-client relocation command failed")
    end
    if not ServerUtil.callSucceeded(player, "teleportTo", x, y, z)
        or not ServerUtil.callSucceeded(player, "setX", x)
        or not ServerUtil.callSucceeded(player, "setY", y)
        or not ServerUtil.callSucceeded(player, "setZ", z)
        or not ServerUtil.callSucceeded(player, "setLastX", x)
        or not ServerUtil.callSucceeded(player, "setLastY", y) then
        error("RailroaderRVTest: final authoritative server relocation failed")
    end
    -- Do not advance the manifest here. The client must complete its guard/
    -- room scan and prove the exact target with the token-only final ACK; the
    -- in-memory transaction owns the deadline and rollback.
    prepared.finalRelocationSent = true
    prepared.finalRelocationAcked = false
    prepared.finalRelocationAckAtTick = nil
    prepared.finalRelocationDeadlineTick = ctx.serverTick + RELOCATION_TIMEOUT_TICKS
    prepared.finalDestination = {
        x = x, y = y, z = z,
    }
end

local function generateForPlayer(player, prepared)
    if ctx.transactionBusy then
        return false, "generation already in progress"
    end
    if type(prepared) ~= "table" or type(prepared.layout) ~= "table"
        or type(prepared.bounds) ~= "table" or type(prepared.anchor) ~= "table"
        or type(prepared.destination) ~= "table"
        or type(prepared.stagingDestination) ~= "table"
        or type(prepared.finalDestination) ~= "table" then
        return false, "prepared generation plan is incomplete"
    end
    ctx.transactionBusy = true
    ctx.transactionPlayer = player
    local manifest
    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            Boundary.clearPlayer(player)
        end
        ctx.transactionBusy = false
        ctx.transactionPlayer = nil
        return false, safeErrorText(manifestOrError)
    end
    manifest = manifestOrError
    local schemaOk, schemaError = pcall(requireCurrentManifest, manifest, true)
    if not schemaOk then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            Boundary.clearPlayer(player)
        end
        ctx.transactionBusy = false
        ctx.transactionPlayer = nil
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    if manifest.state == "RUNNING" then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            Boundary.clearPlayer(player)
        end
        ctx.transactionBusy = false
        ctx.transactionPlayer = nil
        return false, "generation already in progress"
    end
    -- B42 Kahlua exposes pcall; the protected body returns
    -- the raw error; finalizeGeneration formats it safely and records FAILED.
    local ok, resultOrError = pcall(function()
        local playerOk, positionOrReason = validateAuthoritativePlayer(player)
        if not playerOk then
            error(positionOrReason)
        end
        -- The ordinary technical-test button requires the debug capability.
        -- Railroader requests have already passed their own server-side train,
        -- range, seat and movement checks in RV_RailroaderServer.
        if prepared.railroader == nil then
            local permissionOk, permissionReason = validateGenerationPermission(player)
            if not permissionOk then
                error(permissionReason)
            end
        end
        if prepared.railroader ~= nil and not ctx.railroaderValidationHook then
            error("Railroader RV validation hook is unavailable")
        end
        if prepared.railroader ~= nil and ctx.railroaderValidationHook then
            local railOk, railResult, railReason = pcall(
                ctx.railroaderValidationHook, player, prepared.railroader, prepared)
            if not railOk then
                error(safeErrorText(railResult))
            end
            if railResult ~= true then
                error(railReason or "Railroader generation request is no longer valid")
            end
        end
        local identityOk, identityOrReason = playerIdentity(player)
        if not identityOk or identityOrReason.key ~= prepared.identity.key then
            error(identityOk and "requesting player identity changed" or identityOrReason)
        end
        local layout = prepared.layout
        local bounds = prepared.bounds
        local anchor = prepared.anchor
        local cell = ServerWorld.getCellForPlayer(player)
        local oldBounds = prepared.oldBounds
        local atStaging, stagingReason = playerIsAtStagingDestination(player,
            prepared.stagingDestination, bounds)
        if not atStaging then
            error(stagingReason)
        end
        -- No object/system mutation is allowed before this complete loaded
        -- region check.  In particular, an old generation is not removed
        -- until the new half-open 100x100 bitmap/base/wall/roof contract is ready.
        ServerSchema.preflightLoaded(cell, bounds)
        local generation = (manifest.generation == nil and 1
            or ServerUtil.requiredInteger(manifest.generation, "manifest generation") + 1)
        if not Boundary then
            error("RailroaderRVTest: RV boundary service is unavailable")
        end
        local rvId = prepared.railroader and prepared.railroader.locoId
            or ("technical:" .. tostring(anchor.x) .. ":" .. tostring(anchor.y))
        local boundaryOk, boundaryOrReason = pcall(Boundary.makeBoundary,
            layout, rvId, generation)
        if not boundaryOk or type(boundaryOrReason) ~= "table" then
            error(boundaryOk and "RailroaderRVTest: boundary manifest is unavailable"
                or safeErrorText(boundaryOrReason))
        end
        prepared.rvId = tostring(rvId)
        prepared.boundary = boundaryOrReason
        -- Arm every connected client before any old wall or roof is removed.
        -- Reliable packet order installs the guard before the following world
        -- deltas; the requester remains at the validated staging square,
        -- outside both old and new structure footprints, while later client
        -- ticks repair any missed retired room ID.
        armClientRoomOwnershipGuard(generation, oldBounds, bounds,
            prepared.rvId, boundaryOrReason.bitmapVersion)
        local roomOwnershipGuard = registerServerRoomOwnershipGuard(generation,
            player, oldBounds, bounds, prepared.rvId,
            boundaryOrReason.bitmapVersion)
        -- Remove only objects owned by a prior generation before taking the
        -- new generation lock in persistent state.
        removeOldGeneration(cell, manifest)
        refreshServerRoomOwnershipGuard(roomOwnershipGuard, "after-remove")
        manifest.schemaVersion = Constants.MANIFEST_SCHEMA_VERSION
        manifest.techVersion = Constants.TECH_VERSION
        manifest.generation = generation
        manifest.owner = OWNER
        manifest.anchor = { x = anchor.x, y = anchor.y, z = anchor.z }
        manifest.bounds = bounds
        manifest.rvId = prepared.rvId
        manifest.boundarySchemaVersion = boundaryOrReason.schemaVersion
        manifest.bitmapVersion = boundaryOrReason.bitmapVersion
        manifest.boundary = boundaryOrReason
        manifest.startedAt = math.floor(os.time())
        manifest.rollback = nil
        manifest.completedAt = nil
        manifest.lastError = nil
        setManifestState(manifest, "RUNNING")
        local buildOk, buildError = pcall(clearGenerationArea, cell, bounds,
            generation, manifest)
        -- Generation is allowed to start only after the complete cleanup pass
        -- succeeds.  Keep this explicit gate: pcall reports a cleanup error in
        -- buildOk, and a failed cleanup must never enter buildGeneration.
        if buildOk then
            buildOk, buildError = pcall(buildGeneration, player, layout, bounds,
                generation, manifest)
        end
        if buildOk then
            -- Scan once more on the server immediately before the final
            -- client command.  The client repeats the same scan synchronously
            -- before its teleport; neither side relies on a later OnTick to
            -- repair the square after the player enters the room.
            local refreshOk, refreshError = pcall(
                refreshServerRoomOwnershipGuard, roomOwnershipGuard,
                "before-final-relocate")
            if not refreshOk then
                buildOk = false
                buildError = refreshError
            else
                prepared.generation = generation
            end
            if buildOk then
                setGenerationPhase(manifest, generation, "FINAL_RELOCATE")
                local finalRelocationOk, finalRelocationError = pcall(
                    relocatePlayerIntoHouse, player, prepared)
                if not finalRelocationOk then
                    buildOk = false
                    buildError = finalRelocationError
                else
                    prepared.manifest = manifest
                    prepared.generationCell = cell
                    prepared.generationRoomOwnershipGuard = roomOwnershipGuard
                    prepared.generationNumber = generation
                    -- Keep the process-local transaction alive across the
                    -- asynchronous client readiness proof. The continuation
                    -- below is the only path that can commit READY.
                    return "await-final-relocate"
                end
            end
        end
        if not buildOk then
            -- The lamp is intentionally last, but any phase can fail.  Remove
            -- every object tagged by this generation before exposing FAILED;
            -- otherwise a failed lamp/API call would leave a powered
            -- generator, utility object or roof as a half-built cabin.
            local rollbackOk, rollbackError = pcall(function()
                removeGeneration(cell, bounds, generation, manifest.rvId,
                    manifest.bitmapVersion)
            end)
            if rollbackOk then
                manifest.rollback = "COMPLETE"
                manifest.phase = "ROLLED_BACK"
                print("[RailroaderRVTest] generation=" .. tostring(generation)
                    .. " rollback=COMPLETE")
            else
                manifest.rollback = "FAILED"
                print("[RailroaderRVTest] generation=" .. tostring(generation)
                    .. " rollback=FAILED: " .. safeErrorText(rollbackError))
                error(safeErrorText(buildError) .. " (rollback failed: "
                    .. safeErrorText(rollbackError) .. ")")
            end
            error(buildError)
        end
        error("RailroaderRVTest: generation did not enter final relocation")
    end)
    return finalizeGeneration(manifest, ok, resultOrError)
end

-- Continue generation only after the client has sent the strict
-- FinalRelocateAck.  This function is intentionally separate from the build
-- body: a client readiness failure can never fall through to READY, and the
-- in-memory transaction remains the idempotent retry owner.
local function finalizeGenerationAfterRelocate(player, prepared)
    if type(prepared) ~= "table"
        or prepared.finalRelocationSent ~= true
        or prepared.finalRelocationAcked ~= true then
        return false, "final relocation acknowledgement is still pending"
    end
    local ok, result = pcall(function()
        local positionOk, position = authoritativePlayerPosition(player)
        -- B42.20's IsoPlayer network path can normalize a half-cell
        -- teleport back to the containing square before the token-only final
        -- ACK reaches the server. Keep exact proof first; if only that
        -- documented normalization differs, prove the same selected cell and
        -- exact z. A different cell still fails closed.
        local finalPositionOk = positionOk
            and relocationPositionsEqual(position, prepared.finalDestination)
        if not finalPositionOk and positionOk
            and type(position) == "table"
            and type(prepared.finalDestination) == "table"
            and position.x ~= nil and position.y ~= nil
            and position.z ~= nil
            and prepared.finalDestination.x ~= nil
            and prepared.finalDestination.y ~= nil
            and prepared.finalDestination.z ~= nil
            and math.floor(prepared.finalDestination.x)
                ~= prepared.finalDestination.x
            and math.floor(prepared.finalDestination.y)
                ~= prepared.finalDestination.y
            and position.z == prepared.finalDestination.z
            and math.floor(position.x)
                == math.floor(prepared.finalDestination.x)
            and math.floor(position.y)
                == math.floor(prepared.finalDestination.y) then
            finalPositionOk = true
        end
        if not finalPositionOk then
            -- IsoPlayer.updateRemotePlayer runs immediately before OnTick and
            -- applies the last client PlayerPacket through realx/realy/realz.
            -- The final command can therefore be overwritten once by the
            -- stale staging packet even though the client has already sent a
            -- valid token-only ACK.  Reassert only the server-selected target
            -- and wait for the next post-update proof; accepting this same
            -- tick would release the lease while the engine could still snap
            -- the player back to staging on the following update.
            local target = prepared.finalDestination
            local reasserted = ServerUtil.callSucceeded(player,
                "teleportTo", target.x, target.y, target.z)
                and ServerUtil.callSucceeded(player, "setX", target.x)
                and ServerUtil.callSucceeded(player, "setY", target.y)
                and ServerUtil.callSucceeded(player, "setZ", target.z)
                and ServerUtil.callSucceeded(player, "setLastX", target.x)
                and ServerUtil.callSucceeded(player, "setLastY", target.y)
            local stateText = positionOk and type(position) == "table"
                and (tostring(position.x) .. "," .. tostring(position.y)
                    .. "," .. tostring(position.z)) or safeErrorText(position)
            print("[RailroaderRVTest] final relocation target pending target="
                .. tostring(target.x) .. "," .. tostring(target.y) .. ","
                .. tostring(target.z) .. " state=" .. stateText
                .. " reasserted=" .. tostring(reasserted))
            error("final relocation authoritative target is still synchronizing")
        end
        local manifest = prepared.manifest
        if type(manifest) ~= "table" then manifest = manifestTable() end
        local schemaOk = pcall(requireCurrentManifest, manifest, false)
        if not schemaOk or manifest.state ~= "RUNNING"
            or manifest.phase ~= "FINAL_RELOCATE"
            or tostring(manifest.rvId) ~= tostring(prepared.rvId)
            or ServerUtil.integer(manifest.generation) ~= prepared.generation
            or ServerUtil.integer(manifest.bitmapVersion) ~= prepared.bitmapVersion then
            error(Constants.SAVE_REBUILD_REQUIRED)
        end
        local anchor = manifest.anchor
        local anchorX = ServerUtil.requiredInteger(anchor.x, "final manifest anchor x")
        local anchorY = ServerUtil.requiredInteger(anchor.y, "final manifest anchor y")
        local anchorZ = ServerUtil.requiredInteger(anchor.z, "final manifest anchor z")
        if prepared.finalDestination.x ~= anchorX + 0.5
            or prepared.finalDestination.y ~= anchorY + 0.5
            or prepared.finalDestination.z ~= anchorZ then
            error(Constants.SAVE_REBUILD_REQUIRED)
        end
        local guard = prepared.generationRoomOwnershipGuard
        if guard then
            refreshServerRoomOwnershipGuard(guard, "before-commit")
        end
        if prepared.railroader ~= nil and not ctx.railroaderCommitHook then
            error("Railroader RV commit hook is unavailable")
        end
        if prepared.railroader ~= nil and not prepared.commitApplied then
            local commitOk, commitResult, commitReason = pcall(
                ctx.railroaderCommitHook, player, prepared.railroader, prepared)
            if not commitOk then error(commitResult) end
            if commitResult ~= true then
                error(commitReason or "Railroader RV mapping commit failed")
            end
            prepared.commitApplied = true
        end
        if not Boundary or type(Boundary.completeTransition) ~= "function"
            or Boundary.completeTransition(player, prepared.token) ~= true then
            error("generation boundary transition could not be completed")
        end
        setGenerationPhase(manifest, prepared.generation, "COMMITTED")
        manifest.completedAt = math.floor(os.time())
        setManifestState(manifest, "READY")
        if guard then refreshServerRoomOwnershipGuard(guard, "after-commit") end
        local readySchemaOk = pcall(requireCurrentManifest, manifest, false)
        if not readySchemaOk or manifest.state ~= "READY"
            or manifest.phase ~= "COMMITTED" then
            error(Constants.SAVE_REBUILD_REQUIRED)
        end
        prepared.finalizationReady = true
    end)
    if not ok then
        return false, safeErrorText(result)
    end
    ctx.transactionBusy = false
    ctx.transactionPlayer = nil
    return true
end

local function queueGeneration(player, authoritativePosition, railroaderData)
    if ctx.pendingGeneration ~= nil or ctx.transactionBusy then
        return false, "generation already queued or in progress"
    end
    -- Generation and roof refresh both mutate the current managed scope and
    -- stream the same world region.  The roof group owns the service-wide
    -- mutex until its active/repair/final-return state has fully retired.
    if ctx.roofRepairRelocationGroup ~= nil
        or ctx.roofRepairGroupFinalReturn ~= nil then
        return false, "roof repair refresh is in progress"
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then
        return false, identityOrReason
    end
    local positionOk, originalPosition = authoritativePlayerPosition(player)
    if not positionOk then
        return false, originalPosition
    end

    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        return false, safeErrorText(manifestOrError)
    end
    local manifest = manifestOrError
    local schemaOk = pcall(requireCurrentManifest, manifest, true)
    if not schemaOk then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    if manifest.state == "RUNNING" then
        return false, "generation already in progress"
    end

    -- Capture the fixed destination plan before relocation.  It is never
    -- recomputed from the client, and the client contributes no coordinates.
    local planOk, layoutOrError, bounds, destination, finalDestination,
        stagingDestination, oldBounds = pcall(function()
        local targetX = ServerUtil.requiredInteger(Constants.TELEPORT_X,
            "shared teleport target x")
        local targetY = ServerUtil.requiredInteger(Constants.TELEPORT_Y,
            "shared teleport target y")
        local targetZ = ServerUtil.requiredInteger(Constants.TELEPORT_Z,
            "shared teleport target z")
        local layout = ServerUtil.makeLayout(targetX, targetY, targetZ)
        local plannedBounds = ServerSchema.boundsFor(layout)
        local destination = { x = targetX, y = targetY, z = targetZ }
        local finalDestination = {
            x = targetX + 0.5,
            y = targetY + 0.5,
            z = targetZ,
        }
        -- This is a pure world-coordinate legality check.  It must precede
        -- both network relocation and the authoritative server teleport; it
        -- intentionally does not inspect loaded target squares.
        ServerSchema.validateTargetCoordinates(plannedBounds, destination)
        local oldBounds = manifest.generation ~= nil and manifest.bounds or nil
        local stagingDestination = selectGenerationStagingDestination(layout,
            plannedBounds)
        return layout, plannedBounds, destination, finalDestination,
            stagingDestination, oldBounds
    end)
    if not planOk then
        return false, safeErrorText(layoutOrError)
    end

    ctx.pendingSerial = ctx.pendingSerial + 1
    local token = identityOrReason.key .. ":" .. tostring(ctx.serverTick)
        .. ":" .. tostring(ctx.pendingSerial)
    local transitionRvId = railroaderData and railroaderData.locoId
        or ("technical:" .. tostring(destination.x) .. ":" .. tostring(destination.y))
    local transitionGeneration = (manifest.generation == nil and 1
        or ServerUtil.requiredInteger(manifest.generation, "manifest generation") + 1)
    local transitionBitmapVersion = ServerUtil.requiredInteger(
        layoutOrError.bitmap and layoutOrError.bitmap.bitmapVersion,
        "planned generation bitmapVersion")
    ctx.pendingGeneration = {
        player = player,
        identity = identityOrReason,
        originalPosition = {
            x = originalPosition.x,
            y = originalPosition.y,
            z = originalPosition.z,
        },
        token = token,
        rvId = tostring(transitionRvId),
        generation = transitionGeneration,
        bitmapVersion = transitionBitmapVersion,
        queuedAtTick = ctx.serverTick,
        acknowledged = false,
        relocationPhase = "temporary",
        relocationLastSentTick = nil,
        relocationRetryAtTick = ctx.serverTick,
        relocationNeedsResend = false,
        disconnectStartedTick = nil,
        layout = layoutOrError,
        bounds = bounds,
        oldBounds = oldBounds,
        anchor = {
            x = destination.x,
            y = destination.y,
            z = destination.z,
        },
        destination = { x = destination.x, y = destination.y, z = destination.z },
        finalDestination = {
            x = finalDestination.x,
            y = finalDestination.y,
            z = finalDestination.z,
        },
        stagingDestination = {
            x = stagingDestination.x,
            y = stagingDestination.y,
            z = stagingDestination.z,
            purpose = stagingDestination.purpose,
        },
        railroader = railroaderData,
    }
    if type(railroaderData) == "table" then
        -- Keep the complete generation identity on the adapter's asynchronous
        -- failure/commit payload as well as on pendingGeneration itself.
        railroaderData.rvId = tostring(transitionRvId)
        railroaderData.generation = transitionGeneration
        railroaderData.bitmapVersion = transitionBitmapVersion
    end

    if not Boundary or type(Boundary.beginTransition) ~= "function" then
        ctx.pendingGeneration = nil
        return false, "RV boundary transition service is unavailable"
    end
    local transitionOk, transitionResult = pcall(Boundary.beginTransition,
        player, transitionRvId, transitionGeneration, token, "generation",
        transitionBitmapVersion)
    if not transitionOk or transitionResult ~= true then
        ctx.pendingGeneration = nil
        return false, "RV boundary transition could not be armed"
    end

    -- GameServer.sendTeleport is not exposed to B42.20 Lua.  The targeted
    -- server command performs the client half of relocation; teleportTo is
    -- also applied to the authoritative server object.  The acknowledgement
    -- carries only an opaque token and cannot supply a trusted destination.
    local relocatePayload = {
        token = token,
        onlineId = identityOrReason.onlineId,
        rvId = tostring(transitionRvId),
        generation = transitionGeneration,
        bitmapVersion = transitionBitmapVersion,
        x = stagingDestination.x,
        y = stagingDestination.y,
        z = stagingDestination.z,
        generationTransition = true,
        generationPhase = "temporary",
    }
    -- Re-assert the complete generation identity after constructing the
    -- asynchronous payload.  The marker below is only valid with this exact
    -- RV/generation/bitmap snapshot; keep these assignments explicit so no
    -- later payload extension can silently drop or replace one token.
    relocatePayload.rvId = tostring(transitionRvId)
    relocatePayload.generation = transitionGeneration
    relocatePayload.bitmapVersion = transitionBitmapVersion
    -- Only a Railroader-backed generation carries a local Ride transition
    -- hint.  The marker is intentionally server-created and is not part of
    -- the ordinary technical Generate protocol; its coordinates remain the
    -- server-selected staging destination above.
    if type(railroaderData) == "table" then
        relocatePayload.railroaderTransition = true
        relocatePayload.action = "enter"
        relocatePayload.locoId = railroaderData.locoId
        relocatePayload.role = railroaderData.sourceRole
        relocatePayload.seat = railroaderData.sourceSeat
    end
    local sentOk = ServerUtil.callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_RELOCATE, relocatePayload)
    if not sentOk then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            pcall(Boundary.clearPlayer, player)
        end
        ctx.pendingGeneration = nil
        return false, "server-to-client relocation command failed"
    end
    if not ServerUtil.callSucceeded(player, "teleportTo", stagingDestination.x + 0.5,
        stagingDestination.y + 0.5, stagingDestination.z) then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            pcall(Boundary.clearPlayer, player)
        end
        ctx.pendingGeneration = nil
        return false, "authoritative server relocation failed"
    end
    ctx.pendingGeneration.relocationLastSentTick = ctx.serverTick
    ctx.pendingGeneration.relocationRetryAtTick = ctx.serverTick
    print("[RailroaderRVTest] generation queued after relocation player="
        .. identityOrReason.key .. " staging=" .. tostring(stagingDestination.x)
        .. "," .. tostring(stagingDestination.y) .. ","
        .. tostring(stagingDestination.z) .. " anchor=" .. tostring(destination.x)
        .. "," .. tostring(destination.y) .. "," .. tostring(destination.z))
    return true
end


ctx.validateRequest = validateRequest
ctx.generateForPlayer = generateForPlayer
ctx.finalizeGenerationAfterRelocate = finalizeGenerationAfterRelocate
ctx.queueGeneration = queueGeneration
end
