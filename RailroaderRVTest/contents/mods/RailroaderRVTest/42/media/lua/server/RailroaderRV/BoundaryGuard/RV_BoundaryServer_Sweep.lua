-- RV_BoundaryServer: player tracking and bounded proximity-queue work.
return function(ctx)
local Boundary = ctx.Boundary
local Core = ctx.Core
local integer = ctx.integer
local call = ctx.call
local callGlobal = ctx.callGlobal
local identity = ctx.identity
local boundaryKey = ctx.boundaryKey
local transitionActive = ctx.transitionActive
local guardContextForPlayer = ctx.guardContextForPlayer
local playerPosition = ctx.playerPosition
local postPlayerTickHandlers = {}

function Boundary.addPostPlayerTickHandler(name, callback)
    if type(name) ~= "string" or name == "" or type(callback) ~= "function" then
        return false, "invalid post-player tick handler"
    end
    local current = postPlayerTickHandlers[name]
    if current then
        if current == callback then return true end
        return false, "post-player tick handler name is already registered"
    end
    postPlayerTickHandlers[name] = callback
    return true
end

local function dispatchPostPlayerTickHandlers(tick, activePlayers,
    activeBoundaries)
    local names = {}
    for name in pairs(postPlayerTickHandlers) do
        names[#names + 1] = name
    end
    table.sort(names)
    for i = 1, #names do
        local callback = postPlayerTickHandlers[names[i]]
        local callOk, accepted, reason = pcall(callback, tick, activePlayers,
            activeBoundaries)
        if not callOk or accepted == false then
            print("[RailroaderRVTest] post-player tick handler "
                .. tostring(names[i]) .. " failed: "
                .. tostring(callOk and reason or accepted))
        end
    end
end

local UNTRACKED_OUTSIDE_PROBE_RETRY_TICKS = 300
local untrackedOutsideProbeDeadlines = {}
local untrackedOutsideProbeCursor = 0

local function untrackedOutsideProbeDue(identityKey)
    local retryAt = untrackedOutsideProbeDeadlines[identityKey]
    return not Core.isTick(retryAt)
        or Core.tickReached(Boundary._tick, retryAt)
end

local function deferUntrackedOutsideProbe(identityKey)
    local retryAt = Core.tickAdd(Boundary._tick,
        UNTRACKED_OUTSIDE_PROBE_RETRY_TICKS)
    if Core.isTick(retryAt) then
        untrackedOutsideProbeDeadlines[identityKey] = retryAt
    end
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

function Boundary.onTick(tick)
    Boundary._tick = Core.isTick(tick) and tick or Core.getTick()
    if type(Boundary.pruneBuilderActionLedger) == "function" then
        Boundary.pruneBuilderActionLedger(Boundary._tick)
    end
    local players = onlinePlayersSnapshot()
    local activePlayers, activeBoundaries = {}, {}
    local coldOutsideCandidates = {}
    for i = 1, #players do
        local player = players[i]
        local position, inRVRegion = playerPosition(player)
        if position then
            local id = identity(player)
            if id then
                local state = Boundary._states[id.key]
                if state then state.identity = id end
                -- Roof relocation owns the boundary lease while the player is
                -- temporarily outside the RV chunk. Normal position, queue,
                -- and guard work resumes only after transition completion.
                if state or inRVRegion then
                    if state and transitionActive(state) then
                        -- The transition lease owns this player's position.
                    else
                        local guard = guardContextForPlayer(player, position,
                            id, true)
                        local boundary = guard and guard.boundary
                        if boundary then
                            activePlayers[#activePlayers + 1] = {
                                boundary = boundary, player = player,
                            }
                            activeBoundaries[boundaryKey(boundary)] = {
                                boundary = boundary, player = player,
                            }
                        end
                    end
                elseif untrackedOutsideProbeDue(id.key) then
                    coldOutsideCandidates[#coldOutsideCandidates + 1] = {
                        identity = id, player = player, position = position,
                    }
                end
            end
        end
    end

    -- A restart loses process-local states and validation caches. Probe at
    -- most one untracked outside identity per tick, with a per-identity retry
    -- deadline, so unrelated world players do not trigger a full map check
    -- every tick while a persisted inside relation can still be recovered.
    if #coldOutsideCandidates > 0 then
        untrackedOutsideProbeCursor = untrackedOutsideProbeCursor
            % #coldOutsideCandidates + 1
        local candidate = coldOutsideCandidates[untrackedOutsideProbeCursor]
        deferUntrackedOutsideProbe(candidate.identity.key)
        local guard = guardContextForPlayer(candidate.player,
            candidate.position, candidate.identity, false)
        local boundary = guard and guard.boundary
        if boundary then
            activePlayers[#activePlayers + 1] = {
                boundary = boundary, player = candidate.player,
            }
            activeBoundaries[boundaryKey(boundary)] = {
                boundary = boundary, player = candidate.player,
            }
        end
    end

    dispatchPostPlayerTickHandlers(Boundary._tick, activePlayers,
        activeBoundaries)
end

end
