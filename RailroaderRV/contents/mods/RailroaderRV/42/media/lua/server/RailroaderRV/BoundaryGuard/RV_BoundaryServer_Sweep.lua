-- RV_BoundaryServer: player tracking and boundary correction.
return function(ctx)
local Boundary = ctx.Boundary
local Core = ctx.Core
local C = ctx.C
local integer = ctx.integer
local call = ctx.call
local callGlobal = ctx.callGlobal
local identity = ctx.identity
local square = ctx.square
local playerCell = ctx.playerCell
local stateFor = ctx.stateFor
local guardContextForPlayer = ctx.guardContextForPlayer
local playerPosition = ctx.playerPosition
local TemplateGeometry = require("RailroaderRV/RoomTemplate/RV_TemplateGeometry")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")

local function boundaryKey(boundary)
    return tostring(boundary.rvId) .. ":" .. tostring(boundary.generation)
end

local function onlinePlayersSnapshot()
    local result = {}
    local ok, players = callGlobal("getOnlinePlayers")
    if ok and players then
        local sizeOk, size = call(players, "size")
        size = sizeOk and integer(size) or nil
        if size ~= nil then
            for i = 0, size - 1 do
                local playerOk, player = call(players, "get", i)
                if playerOk and player then result[#result + 1] = player end
            end
        elseif type(players) == "table" then
            for _, player in pairs(players) do
                if player then result[#result + 1] = player end
            end
        end
    end
    if #result == 0 then
        local playerOk, player = callGlobal("getPlayer")
        if playerOk and player then result[1] = player end
    end
    return result
end

-- True while a relocation lease is live; an expired lease is cleared here.
local function leaseLive(state)
    if type(state.leaseToken) ~= "string" then return false end
    if type(state.leaseUntil) == "number"
        and state.leaseUntil >= Boundary._tick then
        return true
    end
    state.leaseToken, state.leaseUntil = nil, nil
    return false
end

-- The authoritative RV spawn from the current mapping record, but only while
-- that exact square is loaded in the player's cell.  Recovery must not
-- fabricate a teleport into an unloaded target square.
local function rvSpawnTarget(player, record)
    local position = type(record) == "table" and record.rvPosition or nil
    if type(position) ~= "table" then return nil end
    local x, y, z = position.x, position.y, position.z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    if not square(playerCell(player), math.floor(x), math.floor(y),
        math.floor(z)) then
        return nil
    end
    return { x = x, y = y, z = z }
end

-- One correction per player per tick: teleport the authoritative server object
-- and hand the same target to the owning client.  There is no queue and no
-- retry; a target that cannot be proven this tick waits for the next one.
local function correctOutside(state, player, boundary, record, onlineId)
    local template = RoomTemplate.get(boundary.templateId)
    if type(state.lastValid) ~= "table" then return false end
    local target = state.lastValid
    if type(target) ~= "table"
        or not TemplateGeometry.isWalkableInManagedRegion(target,
            boundary.managed, template)
        or not square(playerCell(player), math.floor(target.x),
            math.floor(target.y), math.floor(target.z)) then
        target = rvSpawnTarget(player, record)
    end
    if type(target) ~= "table"
        or not TemplateGeometry.isWalkableInManagedRegion(target,
            boundary.managed, template) then
        return false
    end
    local rv = rawget(_G, "RailroaderRV")
    local server = rv and rv.Server
    if server and type(server.teleportToPosition) == "function" then
        server.teleportToPosition(player, target)
    end
    state.lastValid = { x = target.x, y = target.y, z = target.z }
    callGlobal("sendServerCommand", player, C.MOD_ID,
        C.COMMAND_RV_BOUNDARY_CORRECTION, {
            rvId = boundary.rvId, generation = boundary.generation,
            onlineId = onlineId,
            x = target.x, y = target.y, z = target.z,
        })
    return true
end

function Boundary.onTick(tick)
    Boundary._tick = tick or Core.getTick()
    local actionLedger = Boundary.builderActionLedger
    if type(actionLedger) == "table" then
        actionLedger.prune(Boundary._tick)
    end
    local players = onlinePlayersSnapshot()
    local activePlayers, activeBoundaries = {}, {}
    for i = 1, #players do
        local player = players[i]
        local position, inRVRegion = playerPosition(player)
        if position then
            local id = identity(player)
            local boundary, record, onlineId
            if id then
                -- A live relocation lease owns this player's position.  Normal
                -- walkability work resumes after the lease expires.
                local tracked = Boundary._states[id.key]
                if not (type(tracked) == "table" and leaseLive(tracked)) then
                    boundary, record, onlineId = guardContextForPlayer(player,
                        position, id, true)
                end
            end
            -- Only a validated current mapping relation is tracked.  A player
            -- with no validated context is not guarded and is not corrected;
            -- the mapping re-seeds the state after a restart, and entry arms it.
            local state = boundary and stateFor(player, id) or nil
            -- `inside` is the gate for all normal per-player work, so the repair
            -- queue only ever sees an identity that a previous validated tick
            -- already confirmed inside; an entry-frame player is never sampled.
            local inside = state and state.inside == true or false
            if state then
                local template = RoomTemplate.get(boundary.templateId)
                -- The mapping relation is the authority: this identity is
                -- inside the RV, whether or not the current position is
                -- walkable (managed-region membership lives in the template).
                state.inside = true
                if TemplateGeometry.isWalkableInManagedRegion(position,
                    boundary.managed, template) then
                    state.lastValid = {
                        x = position.x, y = position.y, z = position.z,
                    }
                elseif state.lastValid ~= nil then
                    -- Only a player already observed walkable inside may be
                    -- corrected, so the engine's entry/exit teleport settles
                    -- first and a cleared state can never be dragged back.
                    correctOutside(state, player, boundary, record, onlineId)
                end
                if inside and inRVRegion then
                    activePlayers[#activePlayers + 1] = {
                        boundary = boundary, player = player,
                    }
                    activeBoundaries[boundaryKey(boundary)] = {
                        boundary = boundary, player = player,
                    }
                end
            end
        end
    end

    -- TemplateRecovery runs directly after the sweep with the players and
    -- boundaries this sweep validated.  It is looked up at runtime because the
    -- recovery queue is created by RV_Server, after this module loads; there is
    -- no registry and no handler wrapper.
    local rv = rawget(_G, "RailroaderRV")
    local Recovery = rv and rv.RecoveryQueue or nil
    if Recovery then
        Recovery.onPostPlayerTick(Boundary._tick, activePlayers,
            activeBoundaries)
    end
end

end
