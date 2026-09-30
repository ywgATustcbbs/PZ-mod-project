-- RV_Server: PlayerValidation responsibilities.
return function(ctx)
local Core = ctx.Core
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND_RELOCATE = ctx.COMMAND_RELOCATE
local COMMAND_FINAL_RELOCATE = ctx.COMMAND_FINAL_RELOCATE
local Boundary = ctx.Boundary
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local RELOCATION_POST_ACK_TICKS = ctx.RELOCATION_POST_ACK_TICKS
local RELOCATION_TIMEOUT_TICKS = ctx.RELOCATION_TIMEOUT_TICKS
local GENERATION_RELOCATION_RETRY_TICKS = ctx.GENERATION_RELOCATION_RETRY_TICKS
local GenerationTransaction = ctx.GenerationTransaction
local WORLD_MIN_Z = ctx.WORLD_MIN_Z
local WORLD_MAX_Z = ctx.WORLD_MAX_Z
local function cancelPending(...) return ctx.cancelPending(...) end

local relocationServices = (function()
local function readPlayerCoordinate(player, methodName, label)
    local ok, value = ServerUtil.invoke(player, methodName)
    if not ok then
        error("RailroaderRVTest: authoritative player " .. tostring(label) .. " is unavailable")
    end
    local number = ServerUtil.requiredNumber(value, "authoritative player " .. tostring(label))
    if methodName == "getZ" and (number < WORLD_MIN_Z or number > WORLD_MAX_Z) then
        error("RailroaderRVTest: authoritative player z is outside legal world range")
    end
    return number
end

local function validateAuthoritativePlayer(player)
    if not player or not ServerUtil.classInstance(player, "IsoPlayer") then
        return false, "sender is not a valid IsoPlayer"
    end
    local deadOk, dead = ServerUtil.invoke(player, "isDead")
    if not deadOk or dead ~= false then
        return false, "sender is dead or has no authoritative death state"
    end
    local px = readPlayerCoordinate(player, "getX", "x")
    local py = readPlayerCoordinate(player, "getY", "y")
    local pz = readPlayerCoordinate(player, "getZ", "z")
    local worldOk, world = ServerUtil.callGlobal("getWorld")
    if not worldOk or not world then
        return false, "getWorld is unavailable"
    end
    local validOk, valid = ServerUtil.invoke(world, "isValidSquare", math.floor(px), math.floor(py), math.floor(pz))
    if not validOk or valid ~= true then
        return false, "authoritative player coordinate is outside the legal world"
    end
    return true, {
        x = math.floor(px),
        y = math.floor(py),
        z = math.floor(pz),
    }
end

-- teleportTo.  The ordinary validator intentionally returns floor squares for
-- the raw authoritative coordinates instead of inventing a square center.
local function authoritativePlayerPosition(player)
    if not player or not ServerUtil.classInstance(player, "IsoPlayer") then
        return false, "sender is not a valid IsoPlayer"
    end
    local deadOk, dead = ServerUtil.invoke(player, "isDead")
    if not deadOk or dead ~= false then
        return false, "sender is dead or has no authoritative death state"
    end
    local px = readPlayerCoordinate(player, "getX", "x")
    local py = readPlayerCoordinate(player, "getY", "y")
    local pz = readPlayerCoordinate(player, "getZ", "z")
    local worldOk, world = ServerUtil.callGlobal("getWorld")
    if not worldOk or not world then
        return false, "getWorld is unavailable"
    end
    local validOk, valid = ServerUtil.invoke(world, "isValidSquare", math.floor(px),
        math.floor(py), math.floor(pz))
    if not validOk or valid ~= true then
        return false, "authoritative player coordinate is outside the legal world"
    end
    return true, { x = px, y = py, z = pz }
end

local function validateGenerationPermission(player)
    local capabilityClass = rawget(_G, "Capability")
    local requiredCapability = capabilityClass and capabilityClass.UseDebugContextMenu or nil
    if requiredCapability == nil then
        return false, "UseDebugContextMenu capability is unavailable"
    end
    local roleOk, role = ServerUtil.invoke(player, "getRole")
    if not roleOk or role == nil then
        return false, "sender role is unavailable"
    end
    local capabilityOk, allowed = ServerUtil.invoke(role, "hasCapability", requiredCapability)
    if not capabilityOk or allowed ~= true then
        return false, "sender lacks UseDebugContextMenu capability"
    end
    return true
end

local function playerIdentity(player)
    local idOk, onlineId = ServerUtil.invoke(player, "getOnlineID")
    onlineId = idOk and ServerUtil.toNumber(onlineId) or nil
    if not ServerUtil.isFiniteNumber(onlineId) or math.floor(onlineId) ~= onlineId or onlineId < 0 then
        return false, "sender has no stable online ID"
    end
    local usernameOk, username = ServerUtil.invoke(player, "getUsername")
    if not usernameOk or type(username) ~= "string" or username == "" then
        return false, "sender has no stable username"
    end
    return true, {
        onlineId = onlineId,
        username = username,
        key = tostring(onlineId) .. ":" .. username,
    }
end

local function resolvePendingPlayer(pending)
    if type(pending) ~= "table" or type(pending.identity) ~= "table"
        or not ServerUtil.isFiniteNumber(pending.identity.onlineId) then
        return false, "relocation player identity is unavailable"
    end
    local foundOk, current = ServerUtil.callGlobal("getPlayerByOnlineID", pending.identity.onlineId)
    if not foundOk or current == nil then
        return false, "requesting player disconnected or was replaced"
    end
    local identityOk, identityOrReason = playerIdentity(current)
    if not identityOk or identityOrReason.key ~= pending.identity.key then
        return false, identityOk and "requesting player identity changed" or identityOrReason
    end
    -- The online ID is the stable server identity across a transient
    -- IsoPlayer object replacement. Generation state is rebound through its
    -- owner; RoofRelocation applies the same result to its member record.
    local previous = pending.player
    if type(GenerationTransaction) == "table"
        and type(GenerationTransaction.owns) == "function"
        and GenerationTransaction.owns(nil, pending.token) then
        local reboundOk, ownerPrevious = GenerationTransaction.setPlayer(
            current, ctx.serverTick)
        if not reboundOk then
            return false, "generation player could not be rebound"
        end
        previous = ownerPrevious
    end
    if previous ~= nil and previous ~= current then
        if type(ctx.invalidatePlayerPosition) == "function" then
            pcall(ctx.invalidatePlayerPosition, previous)
        end
    end
    return true, current, previous
end

local function relocationPositionsEqual(left, right)
    return type(left) == "table" and type(right) == "table"
        and left.x == right.x and left.y == right.y and left.z == right.z
end

return {
    readPlayerCoordinate = readPlayerCoordinate,
    validateAuthoritativePlayer = validateAuthoritativePlayer,
    authoritativePlayerPosition = authoritativePlayerPosition,
    validateGenerationPermission = validateGenerationPermission,
    playerIdentity = playerIdentity,
    resolvePendingPlayer = resolvePendingPlayer,
    relocationPositionsEqual = relocationPositionsEqual,
}
end)()

-- These validators are shared by the rest of the server transaction code.
local readPlayerCoordinate = relocationServices.readPlayerCoordinate
local validateAuthoritativePlayer = relocationServices.validateAuthoritativePlayer
local authoritativePlayerPosition = relocationServices.authoritativePlayerPosition
local validateGenerationPermission = relocationServices.validateGenerationPermission
local playerIdentity = relocationServices.playerIdentity
local resolvePendingPlayer = relocationServices.resolvePendingPlayer
local relocationPositionsEqual = relocationServices.relocationPositionsEqual

-- pcall prepends its own success flag to every return value.  Normalize the
-- two-result authoritative position helper once so relocation paths never
-- mistake the pcall flag for the helper's `{ x, y, z }` position table.
local function tryAuthoritativePlayerPosition(player)
    local callOk, positionOk, positionOrReason = pcall(
        authoritativePlayerPosition, player)
    if not callOk then return false, positionOk end
    if positionOk ~= true then return false, positionOrReason end
    return true, positionOrReason
end

local function generationDisconnected(reason)
    return reason == "requesting player disconnected or was replaced"
end

local function pauseGenerationForDisconnect(pending)
    if type(pending) ~= "table" then return end
    if type(GenerationTransaction) == "table"
        and type(GenerationTransaction.pauseForDisconnect) == "function" then
        GenerationTransaction.pauseForDisconnect(ctx.serverTick)
    end
end

local function resumeGenerationAfterDisconnect(pending)
    if type(pending) ~= "table"
        or pending.disconnectStartedTick == nil then
        return
    end
    local paused = Core.tickElapsed(ctx.serverTick,
        pending.disconnectStartedTick)
    if not Core.isTick(paused) then
        return
    end
    -- Do not let a missing IsoPlayer consume the normal transaction timeout.
    -- The in-memory owner remains live until this identity reconnects.
    if type(GenerationTransaction) == "table"
        and type(GenerationTransaction.resumeAfterDisconnect) == "function" then
        GenerationTransaction.resumeAfterDisconnect(ctx.serverTick, paused)
    end
end

local function rearmGenerationTransition(pending, player, kind)
    if type(pending) ~= "table" or pending.boundaryCleared == true
        or not Boundary then
        return false
    end
    local token = pending.token
    if type(token) ~= "string" or token == "" then return false end
    if type(Boundary.extendTransition) == "function" then
        local extendOk, extended = pcall(Boundary.extendTransition, player,
            token, Core.tickAdd(ctx.serverTick,
                RELOCATION_POST_ACK_TICKS + 2))
        if extendOk and extended == true then return true end
    end
    if type(Boundary.beginTransition) ~= "function" then return false end
    local beginOk, armed = pcall(Boundary.beginTransition, player,
        pending.rvId, pending.generation, token, kind or "generation")
    if not beginOk or armed ~= true then return false end
    if type(Boundary.extendTransition) == "function" then
        pcall(Boundary.extendTransition, player, token,
            Core.tickAdd(ctx.serverTick, RELOCATION_POST_ACK_TICKS + 2))
    end
    return true
end

-- Reissue only the currently owned phase after a stable identity rebind.  A
-- reconnect invalidates the client's pending command, but never changes the
-- server token or its exact destination.  The retry tick is deliberately
-- bounded so a transient send failure cannot flood the network every tick.
local function resendGenerationPhase(pending, player, phase)
    if type(pending) ~= "table" or not player then return false end
    local identity = pending.identity
    if type(identity) ~= "table" then return false end
    local payload
    if phase == "final" then
        local target = pending.finalDestination
        if type(target) ~= "table" then return false end
        payload = {
            token = pending.token,
            onlineId = identity.onlineId,
            rvId = tostring(pending.rvId),
            generation = pending.generation,
            x = target.x, y = target.y, z = target.z,
        }
        if type(pending.railroader) == "table" then
            payload.railroaderTransition = true
            payload.action = "enter"
            payload.locoId = pending.railroader.locoId
            payload.role = pending.railroader.sourceRole
            payload.seat = pending.railroader.sourceSeat
        end
        if not ServerUtil.callGlobalSucceeded("sendServerCommand", player,
            COMMAND_MODULE, COMMAND_FINAL_RELOCATE, payload) then
            return false
        end
        -- B42.20's float teleport overload floors x/y.  Restore the
        -- server-selected half-cell center through the official setters so
        -- the authoritative proof and the client ACK compare the same exact
        -- destination.  Keep the movement history coherent with the move.
        if not RV.Server.teleportToPosition(player, target)
            or not ServerUtil.callSucceeded(player, "setX", target.x)
            or not ServerUtil.callSucceeded(player, "setY", target.y)
            or not ServerUtil.callSucceeded(player, "setZ", target.z)
            or not ServerUtil.callSucceeded(player, "setLastX", target.x)
            or not ServerUtil.callSucceeded(player, "setLastY", target.y) then
            return false
        end
        local finalDeadline = pending.finalRelocationDeadlineTick
            or Core.tickAdd(ctx.serverTick, RELOCATION_TIMEOUT_TICKS)
        GenerationTransaction.markRelocationSent("final", ctx.serverTick,
            ctx.serverTick, finalDeadline)
        return true
    end

    local target
    if phase == "rollback" then
        target = pending.originalPosition
    else
        target = pending.stagingDestination
    end
    if type(target) ~= "table" then return false end
    payload = {
        token = pending.token,
        onlineId = identity.onlineId,
        rvId = tostring(pending.rvId),
        generation = pending.generation,
        x = target.x, y = target.y, z = target.z,
        generationTransition = true,
        generationPhase = phase == "rollback" and "return" or "temporary",
    }
    if phase == "rollback" then payload.action = "cancel" end
    if type(pending.railroader) == "table" and phase ~= "rollback" then
        payload.railroaderTransition = true
        payload.action = "enter"
        payload.locoId = pending.railroader.locoId
        payload.role = pending.railroader.sourceRole
        payload.seat = pending.railroader.sourceSeat
    end
    local teleportX = phase == "rollback" and target.x or target.x + 0.5
    local teleportY = phase == "rollback" and target.y or target.y + 0.5
    if not ServerUtil.callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_RELOCATE, payload)
        or not RV.Server.teleportToPosition(player, {
            x = teleportX, y = teleportY, z = target.z,
        }) then
        return false
    end
    if phase == "rollback" then
        -- B42's float teleport overload floors x/y.  A failed generation must
        -- return to the exact server-captured position before the transaction
        -- can complete; otherwise cancelPending sees the floored position and
        -- resends the same return command every retry tick.
        if not ServerUtil.callSucceeded(player, "setX", target.x)
            or not ServerUtil.callSucceeded(player, "setY", target.y)
            or not ServerUtil.callSucceeded(player, "setZ", target.z)
            or not ServerUtil.callSucceeded(player, "setLastX", target.x)
            or not ServerUtil.callSucceeded(player, "setLastY", target.y) then
            return false
        end
    end
    GenerationTransaction.markRelocationSent(phase == "rollback"
        and "rollback" or "temporary", ctx.serverTick, ctx.serverTick)
    return true
end

local function keepGenerationTransitionAlive()
    local transactionOk, pending = pcall(GenerationTransaction.current)
    if not transactionOk then return false end
    if type(pending) ~= "table" then return true end
    local resolved, playerOrReason = resolvePendingPlayer(pending)
    if not resolved then
        if generationDisconnected(playerOrReason) then
            pauseGenerationForDisconnect(pending)
        end
        -- OnTick owns identity/death failure decisions.  A missing player is
        -- intentionally non-fatal while this process waits for rebind.
        return true
    end
    resumeGenerationAfterDisconnect(pending)
    pending = GenerationTransaction.current() or pending
    local player = playerOrReason
    local phase = pending.cancelled and "rollback"
        or pending.finalRelocationSent and "final" or "temporary"
    local rearmed = rearmGenerationTransition(pending, player,
        phase == "final" and "generation-final" or "generation")
    if not rearmed then
        -- Keep trying the same token; do not clear the pending transaction or
        -- invent a new one merely because a lease API briefly failed.
        GenerationTransaction.requestRelocationResend()
    end
    if pending.relocationNeedsResend and not pending.cancelled
        and Core.tickReached(ctx.serverTick,
            pending.relocationRetryAtTick or { hi32 = 0, lo32 = 0 }) then
        local resent = resendGenerationPhase(pending, player, phase)
        GenerationTransaction.scheduleRelocationRetry(Core.tickAdd(
            ctx.serverTick, GENERATION_RELOCATION_RETRY_TICKS), not resent)
    end
    return true
end

ctx.tryAuthoritativePlayerPosition = tryAuthoritativePlayerPosition
ctx.generationDisconnected = generationDisconnected
ctx.pauseGenerationForDisconnect = pauseGenerationForDisconnect
ctx.resumeGenerationAfterDisconnect = resumeGenerationAfterDisconnect
ctx.rearmGenerationTransition = rearmGenerationTransition
ctx.resendGenerationPhase = resendGenerationPhase
ctx.keepGenerationTransitionAlive = keepGenerationTransitionAlive
ctx.validateAuthoritativePlayer = validateAuthoritativePlayer
ctx.authoritativePlayerPosition = authoritativePlayerPosition
ctx.validateGenerationPermission = validateGenerationPermission
ctx.playerIdentity = playerIdentity
ctx.resolvePendingPlayer = resolvePendingPlayer
ctx.relocationPositionsEqual = relocationPositionsEqual
end
