-- Server-authoritative wall reload protection.
--
-- One exterior-wall change needs the complete RV chunk to leave the loaded set
-- and stream back in, so every authoritative player inside that RV is moved out
-- as ONE operation, held out until the reload is proven, and then put back on
-- the exact server-captured coordinate.
--
-- The module owns exactly one operation table per rvId and nothing else: no
-- queue, no retry ledger, no persisted transaction, no per-member attempt
-- counter.  It never requires RoofRefresh; the exterior-wall caller supplies
-- the completion callback that runs once after every member is home.
local Constants = require("RailroaderRV/Common/RV_Constants")
local ServerUtil = require("RailroaderRV/Common/RV_ServerUtil")
local Boundary = require("RailroaderRV/BoundaryGuard/RV_BoundaryServer")

local M = {}

-- One live operation per current RV identity.  A stale generation can never
-- adopt an operation, and the single managed world scope never runs two.
local operations = {}

-- The whole-operation budget.  Every deadline and every boundary lease in this
-- module is derived from this one value.
local OPERATION_TIMEOUT_TICKS = 600

-- Phases: IDLE -> MOVE_OUT -> WAIT_RELOAD -> RETURN -> DONE.
local PHASE_MOVE_OUT = "MOVE_OUT"
local PHASE_WAIT_RELOAD = "WAIT_RELOAD"
local PHASE_RETURN = "RETURN"

-- Two independent tick paths reach this module, so one logical tick must not
-- advance an operation twice.
local lastTick = nil

local function currentTick()
    local Core = require("RailroaderRV/Core/RV_Server_Core")
    return Core.getTick()
end

local function serverFacade()
    return RailroaderRV and RailroaderRV.Server or nil
end

local function operationKey(rvId, generation)
    if type(rvId) ~= "string" or rvId == "" then return nil end
    local value = ServerUtil.integer(generation)
    if value == nil or value < 1 then return nil end
    return rvId .. ":" .. tostring(value)
end

function M.isWallReloadActive(rvId)
    if rvId == nil then
        for _ in pairs(operations) do return true end
        return false
    end
    if type(rvId) ~= "string" or rvId == "" then return false end
    for _, op in pairs(operations) do
        if op.rvId == rvId then return true end
    end
    return false
end

-- The temporary destination is a pure function of the CURRENT validated managed
-- region: the region origin pushed far enough away that the RV chunk unloads.
-- It is never a persisted coordinate, a client value or a stored copy.
local function temporaryDestination(boundary)
    local managed = boundary.managed
    local originX = ServerUtil.integer(managed.originX)
    local originY = ServerUtil.integer(managed.originY)
    local minZ = ServerUtil.integer(managed.minZ)
    if originX == nil or originY == nil or minZ == nil then
        return false, Constants.INVALID_RV_DATA
    end
    local x = originX - Constants.ROOF_REFRESH_REMOTE_OFFSET_X
    local y = originY - Constants.ROOF_REFRESH_REMOTE_OFFSET_Y
    local z = minZ - Constants.ROOF_REFRESH_REMOTE_OFFSET_Z
    if z < Constants.WORLD_MIN_Z or z > Constants.WORLD_MAX_Z then
        return false, Constants.INVALID_RV_DATA
    end
    local worldOk, world = ServerUtil.callGlobal("getWorld")
    if not worldOk or not world then
        return false, "RV world is unavailable"
    end
    local validOk, valid = ServerUtil.invoke(world, "isValidSquare", x, y, z)
    if not validOk or valid ~= true then
        return false, "wall reload temporary target is outside the legal world"
    end
    return true, { x = x, y = y, z = z }
end

-- Validate the live player boundary before moving out.  The transition lease
-- blocks Boundary.boundaryForPlayer during the operation, so later phases
-- re-read the current mapping and generation instead.
local function currentContext(op, player, requireInside)
    if requireInside then
        local boundary, record, relation = Boundary.boundaryForPlayer(player)
        if type(boundary) ~= "table" or type(record) ~= "table"
            or type(relation) ~= "table" then
            return false, Constants.INVALID_RV_DATA
        end
        if tostring(boundary.rvId) ~= op.rvId
            or ServerUtil.integer(boundary.generation) ~= op.generation
            or ServerUtil.integer(record.generation) ~= op.generation then
            return false, "wall reload operation generation is stale"
        end
        if relation.inside ~= true then
            return false, Constants.INVALID_RV_DATA
        end
    end
    local api = serverFacade()
    if not api or type(api.currentRVManifestForBoundary) ~= "function" then
        return false, "RV manifest service is unavailable"
    end
    local manifestOk, accepted, manifest = pcall(
        api.currentRVManifestForBoundary, op.rvId, op.generation)
    if not manifestOk or accepted ~= true or type(manifest) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    return true
end

-- The departure proof.  A live IsoRegions rebuild retires the room on the
-- authoritative square, so "no room and no room definition" is the server-side
-- evidence that the room geometry the client held was actually released.  An
-- unsettled square reports not-yet-departed, which is the safe reading.
local function roomGeometryCleared(player)
    local squareOk, square = ServerUtil.invoke(player, "getCurrentSquare")
    if not squareOk or square == nil then return false end
    local roomOk, room = ServerUtil.invoke(square, "getRoom")
    local roomDefOk, roomDef = ServerUtil.invoke(square, "getRoomDef")
    return roomOk and room == nil and roomDefOk and roomDef == nil
end

-- B42.20 floors a float teleport on the authoritative server object on the next
-- packet, so an authoritative move is always teleportTo plus the official
-- setters.
local function applyTeleport(player, target, temporary)
    if type(target) ~= "table" then return false end
    local x = temporary and target.x + 0.5 or target.x
    local y = temporary and target.y + 0.5 or target.y
    local api = serverFacade()
    if not api or type(api.teleportToPosition) ~= "function" then return false end
    return api.teleportToPosition(player, { x = x, y = y, z = target.z }) == true
        and ServerUtil.callSucceeded(player, "setX", x)
        and ServerUtil.callSucceeded(player, "setY", y)
        and ServerUtil.callSucceeded(player, "setZ", target.z)
        and ServerUtil.callSucceeded(player, "setLastX", x)
        and ServerUtil.callSucceeded(player, "setLastY", y)
end

local function sendRelocate(op, member, target, phase)
    return ServerUtil.callGlobalSucceeded("sendServerCommand", member.player,
        Constants.MOD_ID, "Relocate", {
            token = op.token,
            onlineId = member.onlineId,
            rvId = op.rvId,
            generation = op.generation,
            x = target.x, y = target.y, z = target.z,
            wallReloadTransition = true,
            wallReloadPhase = phase,
        })
end

local function armLease(op, member)
    if type(Boundary.beginTransition) ~= "function" then return false end
    local ok, armed = pcall(Boundary.beginTransition, member.player, op.rvId,
        op.generation, op.token, "wall-reload")
    if not ok or armed ~= true then return false end
    member.leaseArmed = true
    if type(Boundary.extendTransition) == "function" then
        pcall(Boundary.extendTransition, member.player, op.token, op.deadlineTick)
    end
    return true
end

local function completeLease(op, member)
    if type(Boundary.completeTransition) ~= "function" then return false end
    local ok, completed = pcall(Boundary.completeTransition, member.player,
        op.token)
    if not ok or completed ~= true then return false end
    member.leaseArmed = false
    return true
end

-- Live player objects are rebuilt from the online snapshot each tick.  A member
-- whose stable identity is no longer present has disconnected or died.
local function livePlayersByKey()
    local result = {}
    local adapter = RailroaderRV and RailroaderRV.RailroaderServer or nil
    if not adapter or type(adapter.onlinePlayersSnapshot) ~= "function" then
        return result
    end
    local ok, players = pcall(adapter.onlinePlayersSnapshot)
    if not ok or type(players) ~= "table" then return result end
    for i = 1, #players do
        local player = players[i]
        if player ~= nil then
            local idOk, onlineId = ServerUtil.invoke(player, "getOnlineID")
            local nameOk, name = ServerUtil.invoke(player, "getUsername")
            local id = idOk and ServerUtil.integer(onlineId) or nil
            if id ~= nil and nameOk and type(name) == "string" and name ~= "" then
                local deadOk, dead = ServerUtil.invoke(player, "isDead")
                if deadOk and dead == false then
                    result[id .. ":" .. name] = player
                end
            end
        end
    end
    return result
end

local function rebindMembers(op, live)
    local removed = {}
    for i = #op.members, 1, -1 do
        local member = op.members[i]
        local player = live[member.identityKey]
        if player == nil then
            table.remove(op.members, i)
            removed[#removed + 1] = member.identityKey
        else
            member.player = player
        end
    end
    return removed
end

local function clearOperation(op)
    operations[op.key] = nil
end

-- Every member still online is put back on its captured coordinate as best
-- effort; the operation is then cleared and no completion callback runs.
local function finishFailure(op, reason)
    local live = livePlayersByKey()
    local returned, unreturned = 0, 0
    for i = 1, #op.members do
        local member = op.members[i]
        local player = live[member.identityKey]
        if player ~= nil then
            member.player = player
            if sendRelocate(op, member, member.captured, "return")
                and applyTeleport(member.player, member.captured, false) then
                returned = returned + 1
                completeLease(op, member)
            else
                unreturned = unreturned + 1
            end
        end
    end
    local phase = op.phase
    local memberCount = #op.members
    clearOperation(op)
    print("[RailroaderRV] wall reload operation failed rvId=" .. op.rvId
        .. " generation=" .. tostring(op.generation) .. " phase=" .. phase
        .. " reason=" .. tostring(reason) .. " members="
        .. tostring(memberCount) .. " returned=" .. tostring(returned)
        .. " unreturned=" .. tostring(unreturned))
end

local function finishDone(op)
    local completed = op.onComplete
    local representative = op.members[1] and op.members[1].player or nil
    local bounds = op.manifest and op.manifest.bounds or nil
    local memberCount = #op.members
    clearOperation(op)
    print("[RailroaderRV] wall reload operation complete rvId=" .. op.rvId
        .. " generation=" .. tostring(op.generation) .. " members="
        .. tostring(memberCount))
    if type(completed) == "function" then
        -- The completion callback is the exterior-wall caller's own follow-up
        -- step; a failure inside it belongs to that caller.
        completed(representative, bounds, {
            rvId = op.rvId,
            generation = op.generation,
        })
    end
end

local function advanceMoveOut(op)
    for i = 1, #op.members do
        local member = op.members[i]
        local contextOk, contextOrReason = currentContext(op, member.player, true)
        if not contextOk then return finishFailure(op, contextOrReason) end
        local target = {
            x = op.destination.x, y = op.destination.y, z = op.destination.z,
        }
        if not armLease(op, member) then
            return finishFailure(op,
                "wall reload boundary lease could not be armed")
        end
        if not sendRelocate(op, member, target, "temporary")
            or not applyTeleport(member.player, target, true) then
            return finishFailure(op, "wall reload move-out teleport failed")
        end
    end
    op.phase = PHASE_WAIT_RELOAD
    print("[RailroaderRV] wall reload move-out queued rvId=" .. op.rvId
        .. " members=" .. tostring(#op.members) .. " target="
        .. tostring(op.destination.x) .. "," .. tostring(op.destination.y) .. ","
        .. tostring(op.destination.z))
end

-- One client "applied" signal plus the departure proof per member.  The single
-- operation deadline covers the whole wait.
local function advanceWaitReload(op)
    for i = 1, #op.members do
        local member = op.members[i]
        if member.applied ~= true then return end
        if not roomGeometryCleared(member.player) then return end
    end
    for i = 1, #op.members do
        local member = op.members[i]
        local contextOk, contextOrReason = currentContext(op, member.player, false)
        if not contextOk then return finishFailure(op, contextOrReason) end
        local target = {
            x = member.captured.x, y = member.captured.y, z = member.captured.z,
        }
        if not sendRelocate(op, member, target, "return")
            or not applyTeleport(member.player, target, false) then
            return finishFailure(op, "wall reload return teleport failed")
        end
    end
    op.phase = PHASE_RETURN
    print("[RailroaderRV] wall reload return queued rvId=" .. op.rvId
        .. " members=" .. tostring(#op.members))
end

local function advanceReturn(op)
    for i = 1, #op.members do
        local member = op.members[i]
        local contextOk, contextOrReason = currentContext(op, member.player, false)
        if not contextOk then return finishFailure(op, contextOrReason) end
        if not completeLease(op, member) then
            return finishFailure(op,
                "wall reload boundary transition could not be completed")
        end
    end
    finishDone(op)
end

function M.onTick()
    if not M.isWallReloadActive() then return end
    local now = currentTick()
    if lastTick == now then return end
    lastTick = now
    local live = livePlayersByKey()
    for _, op in pairs(operations) do
        if operations[op.key] == op then
            local removed = rebindMembers(op, live)
            if #op.members == 0 then
                clearOperation(op)
                print("[RailroaderRV] wall reload operation abandoned rvId="
                    .. op.rvId .. " reason=no-member-online")
            elseif #removed > 0 then
                finishFailure(op, "wall reload member left the operation: "
                    .. table.concat(removed, ","))
            elseif now > op.deadlineTick then
                finishFailure(op, "wall reload operation timed out in phase "
                    .. op.phase)
            else
                for i = 1, #op.members do
                    local member = op.members[i]
                    if member.leaseArmed
                        and type(Boundary.extendTransition) == "function" then
                        pcall(Boundary.extendTransition, member.player, op.token,
                            op.deadlineTick)
                    end
                end
                if op.phase == PHASE_MOVE_OUT then
                    advanceMoveOut(op)
                elseif op.phase == PHASE_WAIT_RELOAD then
                    advanceWaitReload(op)
                elseif op.phase == PHASE_RETURN then
                    advanceReturn(op)
                else
                    finishFailure(op, "wall reload phase is invalid")
                end
            end
        end
    end
end

-- The single client -> server "I applied the move" signal.  It is genuinely
-- needed: only the client's own teleportTo streams the destination chunk, so
-- the reload wait cannot start until the client reports it.  It is
-- coordinate-free and token-scoped; the server keeps its own arrival proof.
function M.acknowledge(player, token)
    if type(token) ~= "string" or token == "" then return false end
    for _, op in pairs(operations) do
        if op.token == token then
            for i = 1, #op.members do
                local member = op.members[i]
                if member.player == player then
                    member.applied = true
                    return true, true
                end
            end
            return true, false,
                "wall reload acknowledgement sender does not own the operation"
        end
    end
    return false
end

-- ALL players authoritatively inside the RV become members of the same
-- operation; a single occupant cannot unload the chunk while another stays in.
local function captureMembers(boundary)
    local live = livePlayersByKey()
    local members = {}
    local managed = boundary.managed
    for identityKey, player in pairs(live) do
        local xOk, x = ServerUtil.invoke(player, "getX")
        local yOk, y = ServerUtil.invoke(player, "getY")
        local zOk, z = ServerUtil.invoke(player, "getZ")
        local px = xOk and ServerUtil.toNumber(x) or nil
        local py = yOk and ServerUtil.toNumber(y) or nil
        local pz = zOk and ServerUtil.toNumber(z) or nil
        if not ServerUtil.isFiniteNumber(px) or not ServerUtil.isFiniteNumber(py)
            or not ServerUtil.isFiniteNumber(pz) then
            return false, "wall reload member position is unavailable"
        end
        if math.floor(px) >= managed.originX
            and math.floor(px) < managed.originX + managed.width
            and math.floor(py) >= managed.originY
            and math.floor(py) < managed.originY + managed.height
            and math.floor(pz) >= managed.minZ
            and math.floor(pz) < managed.maxZ then
            local idOk, onlineId = ServerUtil.invoke(player, "getOnlineID")
            local id = idOk and ServerUtil.integer(onlineId) or nil
            if id == nil then
                return false, "wall reload member identity is unavailable"
            end
            members[#members + 1] = {
                identityKey = identityKey,
                onlineId = id,
                player = player,
                captured = { x = px, y = py, z = pz },
                applied = false,
                leaseArmed = false,
            }
        end
    end
    return true, members
end

-- Begin one operation for the current RV identity.  `request` carries only
-- rvId/generation; `onComplete(player, bounds, identity)` runs once, after every
-- member is home, and is the exterior-wall caller's own follow-up step.
function M.begin(request, onComplete)
    if type(request) ~= "table" or type(onComplete) ~= "function" then
        return false, "wall reload request is malformed"
    end
    local key = operationKey(request.rvId, request.generation)
    if key == nil then return false, Constants.INVALID_RV_DATA end
    if operations[key] ~= nil then
        return false, "a wall reload operation is already active for this RV"
    end
    local api = serverFacade()
    if not api then return false, "RV server facade is unavailable" end
    if type(api.isGenerationTransactionActive) ~= "function" then
        return false, "RV generation transaction state is unavailable"
    end
    local generationOk, generationActive = pcall(
        api.isGenerationTransactionActive)
    if not generationOk or generationActive ~= false then
        return false, "RV generation transaction is in progress"
    end
    if type(api.currentRVManifestForBoundary) ~= "function" then
        return false, Constants.INVALID_RV_DATA
    end
    local manifestCallOk, accepted, manifest = pcall(
        api.currentRVManifestForBoundary, request.rvId,
        ServerUtil.integer(request.generation))
    if not manifestCallOk or accepted ~= true or type(manifest) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local boundary = manifest.boundary
    if type(boundary) ~= "table" or type(boundary.managed) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local destinationOk, destination = temporaryDestination(boundary)
    if not destinationOk then return false, destination end
    local capturedOk, members = captureMembers(boundary)
    if not capturedOk then return false, members end
    if #members == 0 then
        return false, "no authoritative player is inside this RV"
    end

    local generation = ServerUtil.integer(request.generation)
    local op = {
        key = key,
        rvId = tostring(request.rvId),
        generation = generation,
        manifest = manifest,
        destination = destination,
        members = members,
        phase = PHASE_MOVE_OUT,
        deadlineTick = currentTick() + OPERATION_TIMEOUT_TICKS,
        onComplete = onComplete,
        token = "wall-reload:" .. tostring(request.rvId) .. ":"
            .. tostring(generation) .. ":" .. tostring(currentTick()),
    }
    operations[key] = op
    print("[RailroaderRV] wall reload operation begin rvId=" .. op.rvId
        .. " generation=" .. tostring(generation) .. " members="
        .. tostring(#members) .. " target=" .. tostring(destination.x) .. ","
        .. tostring(destination.y) .. "," .. tostring(destination.z))
    return true, op.token
end

return M
