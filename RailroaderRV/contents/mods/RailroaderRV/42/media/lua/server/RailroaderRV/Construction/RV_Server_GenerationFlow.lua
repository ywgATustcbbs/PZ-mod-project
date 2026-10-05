-- RV_Server: GenerationFlow responsibilities.
return function(ctx)
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND = ctx.COMMAND
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local ServerSchema = ctx.ServerSchema
local GenerationTransaction = ctx.GenerationTransaction
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
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
local clearGenerationArea = ctx.clearGenerationArea
local buildGeneration = ctx.buildGeneration
local validateAuthoritativePlayer = ctx.validateAuthoritativePlayer
local authoritativePlayerPosition = ctx.authoritativePlayerPosition
local validateGenerationPermission = ctx.validateGenerationPermission
local playerIdentity = ctx.playerIdentity
local generationPositionProof = ctx.generationPositionProof
local sendStagingRelocation = ctx.sendStagingRelocation
local sendFinalRelocation = ctx.sendFinalRelocation

-- Generation staging belongs to this flow: roof refresh has a separate
-- remote relocation contract and must not publish these generation helpers.
-- The staging layer is this flow's own contract point; it is not derivable from
-- the layout, which only describes the managed base and roof layers.
local GENERATION_STAGING_Z = -15

local function selectGenerationStagingDestination(layout, bounds)
    local originX, originY = bounds.managedOriginX, bounds.managedOriginY
    local width, height = bounds.managedWidth, bounds.managedHeight
    local destination = {
        x = originX + math.floor(width / 2),
        y = originY + math.floor(height / 2),
        z = GENERATION_STAGING_Z,
        purpose = "generation-center",
    }
    local worldOk, world = ServerUtil.callGlobal("getWorld")
    if not worldOk or world == nil then
        error("RailroaderRV: getWorld is unavailable for generation staging")
    end
    local validOk, valid = ServerUtil.invoke(world, "isValidSquare", destination.x,
        destination.y, destination.z)
    if not validOk or valid ~= true then
        error("RailroaderRV: generation center staging coordinate is illegal")
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

local function validateRequest(module, command, player)
    if module ~= COMMAND_MODULE then
        return false, "invalid command module"
    end
    if command ~= COMMAND then
        return false, "invalid command"
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
-- The payload is created entirely from the server's prepared anchor; the client
-- never sends coordinates and completion uses a separate token-only ACK.
local function relocatePlayerIntoHouse(player, prepared)
    local destination = prepared.finalDestination
    local anchor = prepared.anchor
    local x, y, z = destination.x, destination.y, destination.z
    local anchorX, anchorY, anchorZ = anchor.x, anchor.y, anchor.z
    if x ~= anchorX + 0.5 or y ~= anchorY + 0.5 or z ~= anchorZ then
        error("RailroaderRV: final relocation is not the house interior center")
    end
    -- Do not commit here.  The client must complete its guard/room scan and
    -- prove the exact target with the token-only final ACK; the record owns the
    -- deadline and the single abort path.
    local sent, sendReason = sendFinalRelocation(prepared,
        ctx.serverTick + RELOCATION_TIMEOUT_TICKS)
    if not sent then
        error("RailroaderRV: " .. tostring(sendReason))
    end
    prepared.stage = "WAIT_FINAL"
    prepared.finalAcked = false
end

local function generateForPlayer(player, prepared)
    if GenerationTransaction.owns(player) ~= true
        or prepared.stage ~= "WAIT_STAGING" then
        return false, "generation already in progress"
    end
    prepared.stage = "BUILD"
    -- B42 Kahlua exposes pcall; this is the world-mutation boundary. A failure
    -- returns its reason to the abort path. The next unmapped request performs
    -- the full cleanup pass before it builds again.
    local ok, resultOrError = pcall(function()
        local playerOk, positionOrReason = validateAuthoritativePlayer(player)
        if not playerOk then
            error(positionOrReason)
        end
        -- The generation action requires the debug capability.
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
        local cell = ServerWorld.getCellForPlayer(player)
        local atStaging, stagingReason = playerIsAtStagingDestination(player,
            prepared.stagingDestination, bounds)
        if not atStaging then
            error(stagingReason)
        end
        local generation = prepared.generation
        if not Boundary then
            error("RailroaderRV: RV boundary service is unavailable")
        end
        local rvId = prepared.rvId
        prepared.rvId = tostring(rvId)
        -- Arm every connected client before any old captured object is removed.
        -- Reliable packet order installs the guard before the following world
        -- deltas; the requester remains at the validated staging square,
        -- outside both old and new structure footprints, while later client
        -- ticks repair any missed retired room ID.
        armClientRoomOwnershipGuard(generation, nil, bounds, prepared.rvId)
        local roomOwnershipGuard = registerServerRoomOwnershipGuard(generation,
            player, nil, bounds, prepared.rvId)
        -- No durable mutation record: the in-memory record is the gate.
        local buildOk, buildError = pcall(clearGenerationArea, cell, bounds,
            generation)
        -- Generation is allowed to start only after the complete cleanup pass
        -- succeeds.  Keep this explicit gate: pcall reports a cleanup error in
        -- buildOk, and a failed cleanup must never enter buildGeneration.
        if buildOk then
            buildOk, buildError = pcall(buildGeneration, player, layout, bounds,
                generation)
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
                ctx.setGenerationPhase(generation, "FINAL_RELOCATE")
                local finalRelocationOk, finalRelocationError = pcall(
                    relocatePlayerIntoHouse, player, prepared)
                if not finalRelocationOk then
                    error(finalRelocationError)
                end
                -- Keep the process-local record alive across the asynchronous
                -- client readiness proof.  The tick handler is the only path
                -- that can commit DONE.
                return "await-final-relocate"
            end
        end
        error(buildError)
    end)
    if not ok then
        return false, safeErrorText(resultOrError)
    end
    return true, resultOrError
end

-- Continue generation only after the client has sent its final ACK and the
-- server proves the authoritative position.  A client readiness failure can
-- never fall through to DONE; the record keeps the same token, deadline and
-- single abort path.
local function finalizeGenerationAfterRelocate(player, prepared)
    if type(prepared) ~= "table" or prepared.stage ~= "WAIT_FINAL"
        or prepared.finalAcked ~= true then
        return false, "final relocation acknowledgement is still pending"
    end
    local target = prepared.finalDestination
    local proofOk, proofOrPosition, positionMismatch =
        generationPositionProof(player, target)
    if not proofOk then
        if positionMismatch == true then
            -- IsoPlayer.updateRemotePlayer runs immediately before OnTick and
            -- applies the last client PlayerPacket through realx/realy/realz.
            -- The final command can therefore be overwritten once by the stale
            -- staging packet even though the client has already sent a valid
            -- token-only ACK.  Re-assert only the server-selected target and
            -- wait for the next post-update proof; accepting this same tick
            -- would release the lease while the engine could still snap the
            -- player back to staging.  The deadline bounds the re-assert.
            sendFinalRelocation(prepared)
            local stateText = type(proofOrPosition) == "table"
                and (tostring(proofOrPosition.x) .. ","
                    .. tostring(proofOrPosition.y) .. ","
                    .. tostring(proofOrPosition.z))
                or safeErrorText(proofOrPosition)
            print("[RailroaderRV] final relocation target pending target="
                .. tostring(target.x) .. "," .. tostring(target.y) .. ","
                .. tostring(target.z) .. " state=" .. stateText)
            return false, "final relocation authoritative target is still synchronizing"
        end
        return false, proofOrPosition
    end
    local ok, result = pcall(function()
        if proofOrPosition == "target-cell" then
            print("[RailroaderRV] final relocation commit proof accepted target cell="
                .. tostring(math.floor(target.x)) .. ","
                .. tostring(math.floor(target.y)) .. ","
                .. tostring(target.z) .. " after B42 half-cell normalization")
        end
        if type(refreshGenerationRoomOwnershipGuard) ~= "function" then
            error("generation room ownership guard service is unavailable")
        end
        refreshGenerationRoomOwnershipGuard(prepared.rvId,
            prepared.generation, "before-commit")
        if not Boundary or type(Boundary.completeTransition) ~= "function"
            or Boundary.completeTransition(player, prepared.token) ~= true then
            error("generation boundary transition could not be completed")
        end
        refreshGenerationRoomOwnershipGuard(prepared.rvId,
            prepared.generation, "pre-mapping-commit")
        -- The mapping is the persistent publication point.  It runs once, only
        -- after every room/transition check has passed.
        if prepared.railroader ~= nil and prepared.commitApplied ~= true then
            if not ctx.railroaderCommitHook then
                error("Railroader RV commit hook is unavailable")
            end
            local commitOk, commitResult, commitReason = pcall(
                ctx.railroaderCommitHook, player, prepared.railroader, prepared)
            if not commitOk then error(commitResult) end
            if commitResult ~= true then
                error(commitReason or "Railroader RV mapping commit failed")
            end
            prepared.commitApplied = true
        end
    end)
    if not ok then
        return false, safeErrorText(result)
    end
    prepared.stage = "DONE"
    return true
end

local function queueGeneration(player, authoritativePosition, railroaderData)
    if type(GenerationTransaction) ~= "table"
        or type(GenerationTransaction.isActive) ~= "function"
        or GenerationTransaction.isActive() then
        return false, "generation already queued or in progress"
    end
    -- A generation and a wall reload both mutate the current managed scope and
    -- stream the same world region.  The wall reload operation holds the
    -- service-wide mutex until every captured member is back inside the RV.
    local wallServer = type(RV) == "table" and RV.Server or nil
    if type(wallServer) ~= "table"
        or type(wallServer.isWallReloadTransactionActive) ~= "function" then
        return false, "wall reload transaction state is unavailable"
    end
    local wallMutexOk, wallActive, wallReason = pcall(
        wallServer.isWallReloadTransactionActive)
    if not wallMutexOk or wallActive ~= false then
        return false, wallReason or "wall reload is in progress"
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then
        return false, identityOrReason
    end
    local positionOk, originalPosition = authoritativePlayerPosition(player)
    if not positionOk then
        return false, originalPosition
    end

    -- Concurrency is owned by the in-memory record (checked above); the
    -- durable record only remembers which slot the last generation claimed.
    local allocated, selectedSlot, anchor, priorGeneration = allocateRVRegion(
        railroaderData and railroaderData.locoId or nil)
    if allocated ~= true then
        return false, selectedSlot or "no free RV region slot"
    end
    local slotIndex = selectedSlot
    local targetX, targetY, targetZ = anchor.x, anchor.y, anchor.z
    local rvId = railroaderData and tostring(railroaderData.locoId)
        or ("technical:slot:" .. tostring(slotIndex))
    -- A published mapping means this locomotive already has a completed RV.
    -- Unmapped requests select a free slot and always begin at the full clear
    -- pass, which also removes objects left by a failed earlier attempt.
    if priorGeneration ~= nil then
        return false, "RailroaderRV: locomotive already has a completed RV mapping"
    end
    local generation = 1
    if railroaderData then
        railroaderData.slotIndex = slotIndex
    end
    local templateId = RoomTemplate.templateIdForEngineAreaBuilding(
        SandboxVars.RailroaderRV.AllowEngineAreaBuilding)
    local layout = Layout.make(targetX, targetY, targetZ, templateId)
    local bounds = ServerSchema.boundsFor(layout)
    local anchorPosition = { x = targetX, y = targetY, z = targetZ }
    local finalDestination = {
        x = targetX + 0.5,
        y = targetY + 0.5,
        z = targetZ,
    }
    -- Check map coordinates before either relocation. This is a live world
    -- boundary check, not a second validation of the compiled layout.
    ServerSchema.validateTargetCoordinates(bounds, anchorPosition)
    local stagingDestination = selectGenerationStagingDestination(layout, bounds)
    ctx.pendingSerial = ctx.pendingSerial + 1
    local token = identityOrReason.key .. ":" .. tostring(ctx.serverTick)
        .. ":" .. tostring(ctx.pendingSerial)
    local transitionRvId = rvId
    local transitionGeneration = generation
    if railroaderData then
        -- Keep the generation identity on the adapter's asynchronous payload.
        railroaderData.rvId = tostring(transitionRvId)
        railroaderData.generation = transitionGeneration
    end
    local record = {
        player = player,
        identity = identityOrReason,
        token = token,
        rvId = tostring(transitionRvId),
        generation = transitionGeneration,
        slotIndex = slotIndex,
        layout = layout,
        bounds = bounds,
        anchor = {
            x = anchorPosition.x,
            y = anchorPosition.y,
            z = anchorPosition.z,
        },
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
        originalPosition = {
            x = originalPosition.x,
            y = originalPosition.y,
            z = originalPosition.z,
        },
        railroader = railroaderData,
        deadlineTick = ctx.serverTick + RELOCATION_TIMEOUT_TICKS,
        stagingAcked = false,
        finalAcked = false,
    }
    GenerationTransaction.begin(player, record)

    if not Boundary or type(Boundary.beginTransition) ~= "function" then
        GenerationTransaction.release()
        return false, "RV boundary transition service is unavailable"
    end
    local transitionOk, transitionResult = pcall(Boundary.beginTransition,
        player, transitionRvId, transitionGeneration, token, "generation")
    if not transitionOk or transitionResult ~= true then
        GenerationTransaction.release()
        return false, "RV boundary transition could not be armed"
    end

    -- GameServer.sendTeleport is not exposed to B42.20 Lua.  The targeted
    -- server command performs the client half of relocation; teleportTo is
    -- also applied to the authoritative server object.  The acknowledgement
    -- carries only an opaque token and cannot supply a trusted destination.
    local sentOk, sentReason = sendStagingRelocation(record, "temporary")
    if not sentOk then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            pcall(Boundary.clearPlayer, player)
        end
        GenerationTransaction.release()
        return false, sentReason
    end
    print("[RailroaderRV] generation queued after relocation player="
        .. identityOrReason.key .. " staging=" .. tostring(stagingDestination.x)
        .. "," .. tostring(stagingDestination.y) .. ","
        .. tostring(stagingDestination.z) .. " anchor=" .. tostring(anchorPosition.x)
        .. "," .. tostring(anchorPosition.y) .. "," .. tostring(anchorPosition.z))
    return true
end


ctx.validateRequest = validateRequest
ctx.generateForPlayer = generateForPlayer
ctx.finalizeGenerationAfterRelocate = finalizeGenerationAfterRelocate
ctx.queueGeneration = queueGeneration
ctx.selectGenerationStagingDestination = selectGenerationStagingDestination
ctx.playerIsAtStagingDestination = playerIsAtStagingDestination
end
