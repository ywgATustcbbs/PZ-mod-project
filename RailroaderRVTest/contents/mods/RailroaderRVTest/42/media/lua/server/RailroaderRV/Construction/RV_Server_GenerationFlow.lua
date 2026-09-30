-- RV_Server: GenerationFlow responsibilities.
return function(ctx)
local Core = ctx.Core
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
local UtilityServer = ctx.UtilityServer
local GenerationTransaction = ctx.GenerationTransaction
local GENERATION_STAGING_Z = ctx.GENERATION_STAGING_Z
local function allocateRVRegion(...)
    local rv = rawget(_G, "RailroaderRV")
    local adapter = type(rv) == "table" and rv.RailroaderServer or nil
    if type(adapter) ~= "table" or type(adapter.allocateRVRegion) ~= "function" then
        return false, Constants.INVALID_RV_DATA
    end
    return adapter.allocateRVRegion(...)
end
local function safeErrorText(...) return ctx.safeErrorText(...) end
local RELOCATION_TIMEOUT_TICKS = ctx.RELOCATION_TIMEOUT_TICKS
local registerServerRoomOwnershipGuard = ctx.registerServerRoomOwnershipGuard
local refreshServerRoomOwnershipGuard = ctx.refreshServerRoomOwnershipGuard
local refreshGenerationRoomOwnershipGuard = ctx.refreshGenerationRoomOwnershipGuard
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

-- Generation staging belongs to this flow: roof refresh has a separate
-- remote relocation contract and must not publish these generation helpers.
local function selectGenerationStagingDestination(layout, bounds)
    if type(layout) ~= "table" or type(bounds) ~= "table"
        or type(layout.bitmap) ~= "table" then
        error("RailroaderRVTest: generation staging contract is incomplete")
    end
    local originX = ServerUtil.requiredInteger(bounds.managedOriginX,
        "generation managed origin x")
    local originY = ServerUtil.requiredInteger(bounds.managedOriginY,
        "generation managed origin y")
    local width = ServerUtil.requiredInteger(bounds.managedWidth,
        "generation managed width")
    local height = ServerUtil.requiredInteger(bounds.managedHeight,
        "generation managed height")
    if width ~= ServerUtil.requiredInteger(layout.bitmap.width, "generation bitmap width")
        or height ~= ServerUtil.requiredInteger(layout.bitmap.height,
            "generation bitmap height")
        or originX ~= ServerUtil.requiredInteger(layout.bitmap.originX,
            "generation bitmap origin x")
        or originY ~= ServerUtil.requiredInteger(layout.bitmap.originY,
            "generation bitmap origin y")
        or width <= 0 or height <= 0 then
        error("RailroaderRVTest: generation staging bitmap identity is stale")
    end
    local destination = {
        x = originX + math.floor(width / 2),
        y = originY + math.floor(height / 2),
        z = GENERATION_STAGING_Z,
        purpose = "generation-center",
    }
    local worldOk, world = ServerUtil.callGlobal("getWorld")
    if not worldOk or world == nil then
        error("RailroaderRVTest: getWorld is unavailable for generation staging")
    end
    local validOk, valid = ServerUtil.invoke(world, "isValidSquare", destination.x,
        destination.y, destination.z)
    if not validOk or valid ~= true then
        error("RailroaderRVTest: generation center staging coordinate is illegal")
    end
    return destination
end

local function playerIsAtStagingDestination(player, destination, bounds)
    local playerOk, positionOrReason = validateAuthoritativePlayer(player)
    if not playerOk then
        return false, positionOrReason
    end
    if positionOrReason.x ~= destination.x or positionOrReason.y ~= destination.y
        or positionOrReason.z ~= destination.z then
        return false, "server player has not reached the relocation destination"
    end
    if destination.purpose == "generation-center" then
        local expectedX = bounds.managedOriginX
            + math.floor(bounds.managedWidth / 2)
        local expectedY = bounds.managedOriginY
            + math.floor(bounds.managedHeight / 2)
        if destination.z ~= GENERATION_STAGING_Z
            or destination.x ~= expectedX or destination.y ~= expectedY then
            return false, "generation staging destination identity is stale"
        end
        return true
    end
    return false, "generation staging destination identity is stale"
end

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
    if not RV.Server.teleportToPosition(player, { x = x, y = y, z = z })
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
    local deadlineTick = Core.tickAdd(ctx.serverTick, RELOCATION_TIMEOUT_TICKS)
    local stageAdvanced = GenerationTransaction.advanceStage("final-relocation", {
        boundary = prepared.boundary,
        finalRelocationSent = true,
        finalRelocationAcked = false,
        finalRelocationDeadlineTick = deadlineTick,
    })
    if not stageAdvanced then
        error("RailroaderRVTest: generation transaction stage could not advance")
    end
    prepared.finalRelocationSent = true
    prepared.finalRelocationAcked = false
    prepared.finalRelocationAckAtTick = nil
    prepared.finalRelocationDeadlineTick = deadlineTick
    prepared.finalDestination = {
        x = x, y = y, z = z,
    }
end

local function generateForPlayer(player, prepared)
    if type(GenerationTransaction) ~= "table"
        or type(GenerationTransaction.advanceStage) ~= "function"
        or GenerationTransaction.owns(player) ~= true
        or GenerationTransaction.advanceStage("building") ~= true then
        return false, "generation already in progress"
    end
    prepared = GenerationTransaction.current()
    if type(prepared) ~= "table" or type(prepared.layout) ~= "table"
        or type(prepared.bounds) ~= "table" or type(prepared.anchor) ~= "table"
        or type(prepared.destination) ~= "table"
        or type(prepared.stagingDestination) ~= "table"
        or type(prepared.finalDestination) ~= "table" then
        return false, "prepared generation plan is incomplete"
    end
    if prepared.oldBounds ~= nil then
        return false, "RailroaderRVTest: same-slot rebuild is refused because "
            .. "the previous generation has no complete undo snapshot"
    end
    local manifest
    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            Boundary.clearPlayer(player)
        end
        return false, safeErrorText(manifestOrError)
    end
    manifest = manifestOrError
    if manifest.state == "RUNNING" then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            Boundary.clearPlayer(player)
        end
        return false, "generation already in progress"
    end
    -- Until the managed clear scope passes its read-only occupancy proof or
    -- the old generation starts removal, failures must leave the prior
    -- persistent manifest untouched.
    local preserveManifestOnFailure = true
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
        -- Validate the full target geometry and world coordinates before any
        -- mutation. Managed squares are sparse: cleanup inspects existing
        -- squares, while the build pass creates only captured-object hosts.
        ServerSchema.preflightLoaded(cell, bounds)
        local generation = ServerUtil.requiredInteger(prepared.generation,
            "prepared RV generation")
        if not Boundary then
            error("RailroaderRVTest: RV boundary service is unavailable")
        end
        local rvId = prepared.rvId
        local boundaryOk, boundaryOrReason = pcall(Boundary.makeBoundary,
            layout, rvId, generation)
        if not boundaryOk or type(boundaryOrReason) ~= "table" then
            error(boundaryOk and "RailroaderRVTest: boundary manifest is unavailable"
                or safeErrorText(boundaryOrReason))
        end
        prepared.rvId = tostring(rvId)
        prepared.boundary = boundaryOrReason
        local construction = ctx.constructionService
        if type(construction) ~= "table"
            or type(construction.preflightCurrentGeneration) ~= "function" then
            error("RailroaderRVTest: Construction clear preflight is unavailable")
        end
        local preflightOk, preflightAccepted, preflightReason = pcall(
            construction.preflightCurrentGeneration, player, cell, layout,
            bounds, generation, {
                rvId = prepared.rvId,
                generation = generation,
                bitmapVersion = boundaryOrReason.bitmapVersion,
                slotIndex = prepared.slotIndex,
                anchor = anchor,
            }, manifest)
        if not preflightOk or preflightAccepted ~= true then
            error(preflightOk and (preflightReason
                or "RailroaderRVTest: Construction target preflight was rejected")
                or safeErrorText(preflightAccepted))
        end
        -- Arm every connected client before any old captured object is removed.
        -- Reliable packet order installs the guard before the following world
        -- deltas; the requester remains at the validated staging square,
        -- outside both old and new structure footprints, while later client
        -- ticks repair any missed retired room ID.
        armClientRoomOwnershipGuard(generation, oldBounds, bounds,
            prepared.rvId, boundaryOrReason.bitmapVersion)
        local roomOwnershipGuard = registerServerRoomOwnershipGuard(generation,
            player, oldBounds, bounds, prepared.rvId,
            boundaryOrReason.bitmapVersion)
        -- Keep the player at staging while the build pass creates and verifies
        -- each captured-object host square and the room-ownership scan checks
        -- the captured roof.
        preserveManifestOnFailure = false
        manifest.techVersion = Constants.TECH_VERSION
        manifest.templateVersion = Constants.CAPTURED_TEMPLATE_VERSION
        manifest.generation = generation
        manifest.owner = OWNER
        manifest.slotIndex = prepared.slotIndex
        manifest.anchor = { x = anchor.x, y = anchor.y, z = anchor.z }
        manifest.bounds = bounds
        manifest.rvId = prepared.rvId
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
                "before-final-relocate", true)
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
                    local stageSaved = GenerationTransaction.advanceStage(
                        "final-relocation", {
                            boundary = boundaryOrReason,
                            generationCell = cell,
                        })
                    if not stageSaved then
                        buildOk = false
                        buildError = "generation transaction state could not be saved"
                    else
                        -- Keep the process-local transaction alive across the
                        -- asynchronous client readiness proof. The continuation
                        -- below is the only path that can commit READY.
                        return "await-final-relocate"
                    end
                end
            end
        end
        if not buildOk then
            -- The generator is intentionally last, but any phase can fail. Remove
            -- every object tagged by this generation before exposing FAILED;
            -- otherwise a failed generator/API call would leave a partial
            -- captured model or powered generator in the world.
            local rollbackOk, rollbackError = pcall(function()
                removeGeneration(cell, bounds, generation, manifest.rvId,
                    manifest.bitmapVersion, manifest.phase)
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
    return finalizeGeneration(manifest, ok, resultOrError,
        preserveManifestOnFailure)
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
    if GenerationTransaction.advanceStage("committing") ~= true then
        return false, "generation transaction could not enter commit"
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
            local reasserted = RV.Server.teleportToPosition(player, target)
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
        local manifest = manifestTable()
        if manifest.state ~= "RUNNING"
            or manifest.phase ~= "FINAL_RELOCATE"
            or tostring(manifest.rvId) ~= tostring(prepared.rvId)
            or ServerUtil.integer(manifest.generation) ~= prepared.generation
            or ServerUtil.integer(manifest.bitmapVersion) ~= prepared.bitmapVersion then
            error(Constants.INVALID_RV_DATA)
        end
        local anchor = manifest.anchor
        local anchorX = ServerUtil.requiredInteger(anchor.x, "final manifest anchor x")
        local anchorY = ServerUtil.requiredInteger(anchor.y, "final manifest anchor y")
        local anchorZ = ServerUtil.requiredInteger(anchor.z, "final manifest anchor z")
        if prepared.finalDestination.x ~= anchorX + 0.5
            or prepared.finalDestination.y ~= anchorY + 0.5
            or prepared.finalDestination.z ~= anchorZ then
            error(Constants.INVALID_RV_DATA)
        end
        if type(refreshGenerationRoomOwnershipGuard) ~= "function" then
            error("generation room ownership guard service is unavailable")
        end
        refreshGenerationRoomOwnershipGuard(prepared.rvId,
            prepared.generation, prepared.bitmapVersion, "before-commit")
        if prepared.railroader ~= nil and not ctx.railroaderCommitHook then
            error("Railroader RV commit hook is unavailable")
        end
        if not Boundary or type(Boundary.completeTransition) ~= "function"
            or Boundary.completeTransition(player, prepared.token) ~= true then
            error("generation boundary transition could not be completed")
        end
        setGenerationPhase(manifest, prepared.generation, "COMMITTED")
        manifest.completedAt = math.floor(os.time())
        setManifestState(manifest, "READY")
        refreshGenerationRoomOwnershipGuard(prepared.rvId,
            prepared.generation, prepared.bitmapVersion, "pre-mapping-commit")
        if manifest.state ~= "READY"
            or manifest.phase ~= "COMMITTED" then
            error(Constants.INVALID_RV_DATA)
        end
        -- The mapping is the persistent publication point. It runs only after
        -- the READY manifest and all room/transition checks pass; failure is
        -- handled by cancelPending, which marks this READY record FAILED and
        -- removes/verifies this generation before releasing the transaction.
        if prepared.railroader ~= nil and not prepared.commitApplied then
            local commitOk, commitResult, commitReason = pcall(
                ctx.railroaderCommitHook, player, prepared.railroader, prepared)
            if not commitOk then error(commitResult) end
            if commitResult ~= true then
                error(commitReason or "Railroader RV mapping commit failed")
            end
            GenerationTransaction.markCommitApplied()
        end
    end)
    if not ok then
        return false, safeErrorText(result)
    end
    if GenerationTransaction.advanceStage("ready") ~= true then
        return false, "generation transaction could not enter ready"
    end
    return true
end

local function queueGeneration(player, authoritativePosition, railroaderData)
    if type(GenerationTransaction) ~= "table"
        or type(GenerationTransaction.isActive) ~= "function"
        or GenerationTransaction.isActive() then
        return false, "generation already queued or in progress"
    end
    -- Generation and roof refresh both mutate the current managed scope and
    -- stream the same world region.  The roof group owns the service-wide
    -- mutex until its active/repair/final-return state has fully retired.
    local roofServer = type(RV) == "table" and RV.Server or nil
    if type(roofServer) ~= "table"
        or type(roofServer.isRoofRefreshTransactionActive) ~= "function" then
        return false, "roof refresh transaction state is unavailable"
    end
    local roofMutexOk, roofActive, roofReason = pcall(
        roofServer.isRoofRefreshTransactionActive)
    if not roofMutexOk or roofActive ~= false then
        return false, roofReason or "roof refresh is in progress"
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
    if manifest.state == "RUNNING" then
        return false, "generation already in progress"
    end

    -- Capture the selected free-slot plan before relocation. It is never
    -- recomputed from the client, and the client contributes no coordinates.
    local planOk, layoutOrError, bounds, destination, finalDestination,
        stagingDestination, oldBounds, slotIndex, rvId, generation = pcall(function()
        local allocated, selectedSlot, anchor, region, priorGeneration =
            allocateRVRegion(railroaderData and railroaderData.locoId or nil)
        if allocated ~= true or type(anchor) ~= "table"
            or type(region) ~= "table" then
            error(selectedSlot or Constants.INVALID_RV_DATA)
        end
        local slotIndex = ServerUtil.requiredInteger(selectedSlot,
            "allocated RV slot index")
        local targetX = ServerUtil.requiredInteger(anchor.x,
            "allocated RV target x")
        local targetY = ServerUtil.requiredInteger(anchor.y,
            "allocated RV target y")
        local targetZ = ServerUtil.requiredInteger(anchor.z,
            "allocated RV target z")
        local rvId = railroaderData and tostring(railroaderData.locoId)
            or ("technical:slot:" .. tostring(slotIndex))
        local oldBounds = nil
        if manifest.generation ~= nil then
            local manifestRvId = tostring(manifest.rvId)
            local manifestSlot = ServerUtil.integer(manifest.slotIndex)
            local expectedTechnicalId = "technical:slot:" .. tostring(slotIndex)
            if manifestSlot == slotIndex
                and (manifestRvId == rvId
                    or manifestRvId == expectedTechnicalId) then
                error("RailroaderRVTest: same-slot rebuild is refused because "
                    .. "the previous generation has no complete undo snapshot")
            elseif manifestSlot == slotIndex or manifestRvId == rvId then
                error("current generation identity does not match the selected RV slot")
            end
        end
        if priorGeneration ~= nil and oldBounds == nil then
            error("RailroaderRVTest: same-slot rebuild is refused because "
                .. "the previous generation has no complete undo snapshot")
        end
        if manifest.state == "FAILED" and manifest.rollback == "FAILED"
            and (ServerUtil.integer(manifest.slotIndex) == slotIndex
                or tostring(manifest.rvId) == rvId) then
            error("previous generation rollback failed; remove this test save and rebuild")
        end
        local generationBase = priorGeneration
        local generation = generationBase ~= nil and generationBase + 1 or 1
        if railroaderData then
            railroaderData.slotIndex = slotIndex
            railroaderData.anchor = { x = targetX, y = targetY, z = targetZ }
            railroaderData.region = region
            railroaderData.rvPosition = { x = targetX + 0.5,
                y = targetY + 0.5, z = targetZ }
        end
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
        local stagingDestination = selectGenerationStagingDestination(layout,
            plannedBounds)
        return layout, plannedBounds, destination, finalDestination,
            stagingDestination, oldBounds, slotIndex, rvId, generation
    end)
    if not planOk then
        return false, safeErrorText(layoutOrError)
    end

    ctx.pendingSerial = ctx.pendingSerial + 1
    local token = identityOrReason.key .. ":" .. Core.formatTick(ctx.serverTick)
        .. ":" .. tostring(ctx.pendingSerial)
    local transitionRvId = rvId
    local transitionGeneration = generation
    local transitionBitmapVersion = ServerUtil.requiredInteger(
        layoutOrError.bitmap and layoutOrError.bitmap.bitmapVersion,
        "planned generation bitmapVersion")
    if type(railroaderData) == "table" then
        -- Keep the complete generation identity on the adapter's asynchronous
        -- failure/commit payload as well as on the owned transaction record.
        railroaderData.rvId = tostring(transitionRvId)
        railroaderData.generation = transitionGeneration
        railroaderData.bitmapVersion = transitionBitmapVersion
    end
    local pending = {
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
        slotIndex = slotIndex,
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
    local beginOk = GenerationTransaction.begin(player, pending)
    if not beginOk then
        return false, "generation transaction could not be acquired"
    end

    if not Boundary or type(Boundary.beginTransition) ~= "function" then
        GenerationTransaction.release(token)
        return false, "RV boundary transition service is unavailable"
    end
    local transitionOk, transitionResult = pcall(Boundary.beginTransition,
        player, transitionRvId, transitionGeneration, token, "generation",
        transitionBitmapVersion)
    if not transitionOk or transitionResult ~= true then
        GenerationTransaction.release(token)
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
        GenerationTransaction.release(token)
        return false, "server-to-client relocation command failed"
    end
    if not RV.Server.teleportToPosition(player, {
        x = stagingDestination.x + 0.5,
        y = stagingDestination.y + 0.5,
        z = stagingDestination.z,
    }) then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            pcall(Boundary.clearPlayer, player)
        end
        GenerationTransaction.release(token)
        return false, "authoritative server relocation failed"
    end
    GenerationTransaction.markRelocationSent("temporary", ctx.serverTick,
        ctx.serverTick)
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
ctx.selectGenerationStagingDestination = selectGenerationStagingDestination
ctx.playerIsAtStagingDestination = playerIsAtStagingDestination
end
