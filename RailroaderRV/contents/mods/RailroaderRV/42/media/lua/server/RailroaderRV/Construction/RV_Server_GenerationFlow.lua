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
    local expectedX = bounds.managedOriginX
        + math.floor(bounds.managedWidth / 2)
    local expectedY = bounds.managedOriginY
        + math.floor(bounds.managedHeight / 2)
    assert(destination.purpose == "generation-center"
        and destination.z == GENERATION_STAGING_Z
        and destination.x == expectedX and destination.y == expectedY,
        "generation staging destination identity is stale")
    local playerOk, positionOrReason = validateAuthoritativePlayer(player)
    if not playerOk then
        return false, positionOrReason
    end
    if positionOrReason.x ~= destination.x or positionOrReason.y ~= destination.y
        or positionOrReason.z ~= destination.z then
        return false, "server player has not reached the relocation destination"
    end
    return true
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
    assert(GenerationTransaction.owns(player) == true
        and prepared.stage == "WAIT_STAGING",
        "generation is not waiting at the staging boundary")
    prepared.stage = "BUILD"
    local playerOk, positionOrReason = validateAuthoritativePlayer(player)
    if not playerOk then
        return false, positionOrReason
    end
    -- The generation action requires the debug capability.
    -- Railroader requests have already passed their own server-side train,
    -- range, seat and movement checks in RV_RailroaderServer.
    if prepared.railroader == nil then
        local permissionOk, permissionReason = validateGenerationPermission(player)
        if not permissionOk then
            return false, permissionReason
        end
    else
        local railResult, railReason = ctx.railroaderValidationHook(
            player, prepared.railroader, prepared)
        if railResult ~= true then
            return false, railReason
        end
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk or identityOrReason.key ~= prepared.identity.key then
        return false, identityOk and "requesting player identity changed" or identityOrReason
    end
    local layout = prepared.layout
    local bounds = prepared.bounds
    local cell = ServerWorld.getCellForPlayer(player)
    local atStaging, stagingReason = playerIsAtStagingDestination(player,
        prepared.stagingDestination, bounds)
    if not atStaging then
        return false, stagingReason
    end
    local generation = prepared.generation
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
    clearGenerationArea(cell, bounds)
    buildGeneration(player, layout, bounds, generation)
    -- Scan once more on the server immediately before the final client command.
    -- The client repeats the same scan synchronously before its teleport; neither
    -- side relies on a later OnTick to repair the square after the player enters.
    refreshServerRoomOwnershipGuard(roomOwnershipGuard,
        "before-final-relocate", true)
    prepared.generation = generation
    relocatePlayerIntoHouse(player, prepared)
    -- Keep the process-local record alive across the asynchronous client
    -- readiness proof. The tick handler is the only path that can commit DONE.
    return true
end

-- Continue generation only after the client has sent its final ACK and the
-- server proves the authoritative position.  A client readiness failure can
-- never fall through to DONE; the record keeps the same token, deadline and
-- single abort path.
local function finalizeGenerationAfterRelocate(player, prepared)
    assert(prepared.stage == "WAIT_FINAL" and prepared.finalAcked == true,
        "final relocation acknowledgement is still pending")
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
            local sent, sendReason = sendFinalRelocation(prepared)
            if not sent then return false, sendReason end
            return false, "final relocation authoritative target is still synchronizing"
        end
        return false, proofOrPosition
    end
    refreshGenerationRoomOwnershipGuard(prepared.rvId,
        prepared.generation, "before-commit")
    if Boundary.completeTransition(player, prepared.token) ~= true then
        return false, "generation boundary transition could not be completed"
    end
    refreshGenerationRoomOwnershipGuard(prepared.rvId,
        prepared.generation, "pre-mapping-commit")
    -- The mapping is the persistent publication point. It runs once, only
    -- after every room/transition check has passed.
    if prepared.railroader ~= nil and prepared.commitApplied ~= true then
        local commitResult, commitReason = ctx.railroaderCommitHook(
            player, prepared.railroader, prepared)
        if commitResult ~= true then
            return false, commitReason
        end
        prepared.commitApplied = true
    end
    prepared.stage = "DONE"
    return true
end

local function queueGeneration(player, authoritativePosition, railroaderData)
    if GenerationTransaction.isActive() then
        return false, "generation already queued or in progress"
    end
    -- A generation and a wall reload both mutate the current managed scope and
    -- stream the same world region.  The wall reload operation holds the
    -- service-wide mutex until every captured member is back inside the RV.
    local wallActive, wallReason = RV.Server.isWallReloadTransactionActive()
    if wallActive then
        return false, wallReason
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
    local allocated, selectedSlot, anchor, priorGeneration =
        RailroaderRV.RailroaderServer.allocateRVRegion(
        railroaderData and railroaderData.locoId or nil)
    if allocated ~= true then
        return false, selectedSlot
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

    local transitionOk, transitionResult = pcall(Boundary.beginTransition,
        player, transitionRvId, transitionGeneration, token, "generation")
    if not transitionOk then
        local cleanupOk, cleanupError = pcall(Boundary.clearPlayer, player)
        GenerationTransaction.release()
        if not cleanupOk then error(cleanupError, 0) end
        error(transitionResult, 0)
    end
    if transitionResult ~= true then
        GenerationTransaction.release()
        return false, "RV boundary transition could not be armed"
    end

    -- GameServer.sendTeleport is not exposed to B42.20 Lua.  The targeted
    -- server command performs the client half of relocation; teleportTo is
    -- also applied to the authoritative server object.  The acknowledgement
    -- carries only an opaque token and cannot supply a trusted destination.
    local sentOk, sentReason = sendStagingRelocation(record, "temporary")
    if not sentOk then
        local cleanupOk, cleanupError = pcall(Boundary.clearPlayer, player)
        GenerationTransaction.release()
        if not cleanupOk then error(cleanupError, 0) end
        return false, sentReason
    end
    return true
end


ctx.validateRequest = validateRequest
ctx.generateForPlayer = generateForPlayer
ctx.finalizeGenerationAfterRelocate = finalizeGenerationAfterRelocate
ctx.queueGeneration = queueGeneration
ctx.selectGenerationStagingDestination = selectGenerationStagingDestination
ctx.playerIsAtStagingDestination = playerIsAtStagingDestination
end
