-- RV_Server: PlayerValidation responsibilities.
--
-- This module owns player identity/position validation, the single generation
-- Boundary-lease keep-alive, and the two server->client generation relocation
-- commands.  Relocation state is process-local: exact authoritative
-- coordinates and stable identities live only while this process is alive.
return function(ctx)
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND_RELOCATE = ctx.COMMAND_RELOCATE
local COMMAND_FINAL_RELOCATE = ctx.COMMAND_FINAL_RELOCATE
local Boundary = ctx.Boundary
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local RELOCATION_TIMEOUT_TICKS = ctx.RELOCATION_TIMEOUT_TICKS
local WORLD_MIN_Z = ctx.WORLD_MIN_Z
local WORLD_MAX_Z = ctx.WORLD_MAX_Z

-- One bounded resend cadence shared by both acknowledged stages.  A resend is
-- idempotent on the client and only re-states a server-selected destination.
local GENERATION_RESEND_TICKS = 30

local function readPlayerCoordinate(player, methodName, label)
    local ok, value = ServerUtil.invoke(player, methodName)
    if not ok then
        error("RailroaderRV: authoritative player " .. tostring(label) .. " is unavailable")
    end
    local number = ServerUtil.requiredNumber(value, "authoritative player " .. tostring(label))
    if methodName == "getZ" and (number < WORLD_MIN_Z or number > WORLD_MAX_Z) then
        error("RailroaderRV: authoritative player z is outside legal world range")
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
    local validOk, valid = ServerUtil.invoke(world, "isValidSquare", math.floor(px),
        math.floor(py), math.floor(pz))
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

-- Pure lookup of the live IsoPlayer for a record's stable online ID.  A missing
-- object is reported as a reason; this never rebinds a transaction, never
-- writes record state and never runs a side effect.
local function resolvePendingPlayer(record)
    if type(record) ~= "table" or type(record.identity) ~= "table"
        or not ServerUtil.isFiniteNumber(record.identity.onlineId) then
        return false, "relocation player identity is unavailable"
    end
    local foundOk, current = ServerUtil.callGlobal("getPlayerByOnlineID",
        record.identity.onlineId)
    if not foundOk or current == nil then
        return false, "requesting player disconnected or was replaced"
    end
    local identityOk, identityOrReason = playerIdentity(current)
    if not identityOk or identityOrReason.key ~= record.identity.key then
        return false, identityOk and "requesting player identity changed" or identityOrReason
    end
    return true, current
end

local function relocationPositionsEqual(left, right)
    return type(left) == "table" and type(right) == "table"
        and left.x == right.x and left.y == right.y and left.z == right.z
end

-- B42.20's IsoPlayer network path can normalize a half-cell teleport back to
-- the containing square before a token-only acknowledgement reaches the server.
-- Exact proof first; otherwise only that documented normalization is accepted,
-- and a different cell still fails closed.  This is the single position proof
-- shared by the final acknowledgement and the commit step.
local function generationPositionProof(player, target)
    if type(target) ~= "table" then
        return false, "generation destination is unavailable"
    end
    local positionOk, position = authoritativePlayerPosition(player)
    if not positionOk then return false, position, false end
    if relocationPositionsEqual(position, target) then return true, "exact" end
    if type(position) == "table" and position.x ~= nil and position.y ~= nil
        and position.z ~= nil and target.x ~= nil and target.y ~= nil
        and target.z ~= nil
        and math.floor(target.x) ~= target.x
        and math.floor(target.y) ~= target.y
        and position.z == target.z
        and math.floor(position.x) == math.floor(target.x)
        and math.floor(position.y) == math.floor(target.y) then
        return true, "target-cell"
    end
    return false, position, true
end

local function earlierTick(left, right)
    return left <= right and left or right
end

local function sendRelocate(player, payload)
    return ServerUtil.callGlobalSucceeded("sendServerCommand", player,
        COMMAND_MODULE, COMMAND_RELOCATE, payload)
end

-- Re-state the staging relocation for the record's current phase.  "temporary"
-- is the initial staging move; "return" is the single abort-path return to the
-- server-captured original position.  Both carry only a server-selected target.
local function sendStagingRelocation(record, phase)
    local target = phase == "return" and record.originalPosition
        or record.stagingDestination
    if type(target) ~= "table" then
        return false, "generation relocation destination is unavailable"
    end
    local payload = {
        token = record.token,
        onlineId = record.identity.onlineId,
        rvId = tostring(record.rvId),
        generation = record.generation,
        x = target.x,
        y = target.y,
        z = target.z,
        generationTransition = true,
        generationPhase = phase == "return" and "return" or "temporary",
    }
    -- Only a Railroader-backed generation carries a local Ride transition hint.
    -- A return must not re-enter a seat; seat truth stays with Railroader.
    if phase ~= "return" and type(record.railroader) == "table" then
        payload.railroaderTransition = true
        payload.action = "enter"
        payload.locoId = record.railroader.locoId
        payload.role = record.railroader.sourceRole
        payload.seat = record.railroader.sourceSeat
    end
    -- The staging target is an integer contract point; the return target is the
    -- exact captured position and must not be re-centered.
    local teleportX = phase == "return" and target.x or target.x + 0.5
    local teleportY = phase == "return" and target.y or target.y + 0.5
    if not sendRelocate(record.player, payload)
        or not RV.Server.teleportToPosition(record.player, {
            x = teleportX, y = teleportY, z = target.z,
        }) then
        return false, "server-to-client relocation command failed"
    end
    if phase == "return" then
        -- B42's float teleport overload floors x/y.  The return must land on the
        -- exact captured position; otherwise the abort path cannot release the
        -- transaction on a proved position.
        if not ServerUtil.callSucceeded(record.player, "setX", target.x)
            or not ServerUtil.callSucceeded(record.player, "setY", target.y)
            or not ServerUtil.callSucceeded(record.player, "setZ", target.z)
            or not ServerUtil.callSucceeded(record.player, "setLastX", target.x)
            or not ServerUtil.callSucceeded(record.player, "setLastY", target.y) then
            return false, "authoritative return relocation failed"
        end
    end
    record.lastSentTick = ctx.serverTick
    return true
end

-- Re-state the final in-house relocation.  `deadline` is supplied only by the
-- initial build-step send; a resend keeps the deadline already granted.
local function sendFinalRelocation(record, deadline)
    local target = record.finalDestination
    if type(target) ~= "table" then
        return false, "final relocation destination is unavailable"
    end
    local payload = {
        token = record.token,
        onlineId = record.identity.onlineId,
        rvId = tostring(record.rvId),
        generation = record.generation,
        x = target.x,
        y = target.y,
        z = target.z,
    }
    -- Railroader generation removed the official seat before staging.  Carry
    -- only a transition hint so the client adapter can run Ride.dismount(true)
    -- before this final RV teleport; seat truth still comes from Railroader's
    -- next server snapshot.
    if type(record.railroader) == "table" then
        payload.railroaderTransition = true
        payload.action = "enter"
        payload.locoId = record.railroader.locoId
        payload.role = record.railroader.sourceRole
        payload.seat = record.railroader.sourceSeat
    end
    if not ServerUtil.callGlobalSucceeded("sendServerCommand", record.player,
        COMMAND_MODULE, COMMAND_FINAL_RELOCATE, payload) then
        return false, "final server-to-client relocation command failed"
    end
    -- B42.20's float teleport overload floors x/y.  Restore the server-selected
    -- half-cell center through the official setters so the authoritative proof
    -- and the client acknowledgement compare the same exact destination.
    if not RV.Server.teleportToPosition(record.player, target)
        or not ServerUtil.callSucceeded(record.player, "setX", target.x)
        or not ServerUtil.callSucceeded(record.player, "setY", target.y)
        or not ServerUtil.callSucceeded(record.player, "setZ", target.z)
        or not ServerUtil.callSucceeded(record.player, "setLastX", target.x)
        or not ServerUtil.callSucceeded(record.player, "setLastY", target.y) then
        return false, "final authoritative server relocation failed"
    end
    if deadline ~= nil then record.deadlineTick = deadline end
    record.lastSentTick = ctx.serverTick
    return true
end

-- Keep the token-scoped Boundary lease armed and re-state the current stage's
-- relocation while the record waits for its client acknowledgement.  The send
-- cadence is bounded so a transient failure cannot flood the network, and a
-- missing IsoPlayer only extends the deadline: the next tick after reconnect
-- re-sends naturally on the same token.
local function keepGenerationTransitionAlive(record)
    if type(record) ~= "table"
        or (record.stage ~= "WAIT_STAGING" and record.stage ~= "WAIT_FINAL") then
        return
    end
    if not Boundary or type(Boundary.extendTransition) ~= "function" then
        return
    end
    local resolved, playerOrReason = resolvePendingPlayer(record)
    if not resolved then
        record.deadlineTick = ctx.serverTick + RELOCATION_TIMEOUT_TICKS
        return
    end
    record.player = playerOrReason
    local leaseUntil = earlierTick(record.deadlineTick,
        ctx.serverTick + GENERATION_RESEND_TICKS)
    pcall(Boundary.extendTransition, playerOrReason, record.token, leaseUntil)
    local lastSentTick = record.lastSentTick
    if lastSentTick ~= nil
        and (ctx.serverTick - lastSentTick) < GENERATION_RESEND_TICKS then
        return
    end
    if record.stage == "WAIT_STAGING" then
        sendStagingRelocation(record, "temporary")
    else
        sendFinalRelocation(record)
    end
end

ctx.keepGenerationTransitionAlive = keepGenerationTransitionAlive
ctx.sendStagingRelocation = sendStagingRelocation
ctx.sendFinalRelocation = sendFinalRelocation
ctx.validateAuthoritativePlayer = validateAuthoritativePlayer
ctx.authoritativePlayerPosition = authoritativePlayerPosition
ctx.validateGenerationPermission = validateGenerationPermission
ctx.playerIdentity = playerIdentity
ctx.resolvePendingPlayer = resolvePendingPlayer
ctx.generationPositionProof = generationPositionProof
end
