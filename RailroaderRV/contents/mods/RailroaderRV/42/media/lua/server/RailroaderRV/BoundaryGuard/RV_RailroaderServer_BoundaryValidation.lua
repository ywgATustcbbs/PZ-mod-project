-- RV_RailroaderServer: boundary validation cache and prewarming.
return function(ctx)
local Core = require("RailroaderRV/Core/RV_Server_Core")
local Boundary = ctx.Boundary
local Adapter = ctx.Adapter
local mapData = ctx.mapData
local rvRegion = ctx.rvRegion
local playerPositionInRegion = ctx.playerPositionInRegion
local recordForLoco = ctx.recordForLoco
local serverTransactionMutexStatus = ctx.serverTransactionMutexStatus
local integer = ctx.integer
local playerId = ctx.playerId
local playerName = ctx.playerName
local onlinePlayersSnapshot = ctx.onlinePlayersSnapshot

local cache = {}
local pending = {}
local CACHE_TTL_TICKS = 60
local REFRESH_TICKS = 30
local PREWARM_RETRY_TICKS = 30
local prewarmAfterTick = 0

local function invalidate()
    cache = {}
    pending = {}
    prewarmAfterTick = 0
end

-- One question, one answer: is a wall reload operation active for this rvId?
-- The boundary service does not care which phase it is in, only that the scope
-- it must not fight over is owned by somebody else.
local function wallReloadActive(server, rvId)
    return server.isWallReloadTransactionActive(rvId)
end

local function validatePlayer(player, suppliedIdentity, knownMap,
    forceRefresh, deferCacheMiss)
    if suppliedIdentity == nil then return nil end
    local identityId = integer(suppliedIdentity.onlineId)
    local name = suppliedIdentity.username
    local identityKey = suppliedIdentity.key
    if identityId == nil or not name then return nil end
    if identityKey ~= tostring(identityId) .. ":" .. name then
        error("RailroaderRV: boundary identity key is inconsistent")
    end

    local server = RailroaderRV.Server
    local generationBusy, wallBusy = serverTransactionMutexStatus()
    local state = Boundary._states[identityKey]
    local transitionActive = false
    if state ~= nil and state.leaseToken ~= nil then
        transitionActive = state.leaseUntil >= Boundary._tick
    end
    local now = Adapter._ticks or Core.getTick()
    local cached = cache[identityKey]
    if not forceRefresh
        and generationBusy == false and not transitionActive
        and cached ~= nil
        and now >= cached.validatedAtTick
        and (now - cached.validatedAtTick) < CACHE_TTL_TICKS then
        return cached.boundary, cached.record, cached.relation,
            cached.validatedIdentity, cached.manifest
    end
    if generationBusy ~= false or transitionActive then
        cache[identityKey] = nil
        if forceRefresh or not deferCacheMiss then return nil end
        pending[identityKey] = true
        return nil, "validation-deferred"
    end
    if deferCacheMiss and not forceRefresh then
        cache[identityKey] = nil
        pending[identityKey] = true
        return nil, "validation-deferred"
    end

    local map = knownMap
    if map == nil then map = mapData() end
    local relation = map.players[name]
    local record = relation ~= nil and relation.locoId ~= nil
        and recordForLoco(map, relation.locoId) or nil
    local validatedIdentity = {
        username = name, onlineId = identityId, key = identityKey,
    }
    local function diagnose(reason)
        Boundary.diagnoseGuardState(player, validatedIdentity,
            playerPositionInRegion(player, rvRegion()), relation, record,
            reason)
    end
    if relation == nil or relation.inside ~= true then
        diagnose("mapping-relation-rejected")
        cache[identityKey] = nil
        return nil
    end
    if record == nil then
        diagnose("mapping-record-rejected")
        cache[identityKey] = nil
        return nil
    end
    local rider = record.players[name]
    if rider == nil or rider.inside ~= true then
        diagnose("record-rider-rejected")
        cache[identityKey] = nil
        return nil
    end
    local manifestAccepted, manifest = server.currentRVManifestForBoundary(
        record.locoId, record.generation)
    if manifestAccepted == false then
        diagnose("manifest-rejected")
        cache[identityKey] = nil
        return nil
    end
    if manifestAccepted ~= true then
        error("RailroaderRV: current RV manifest query returned invalid state")
    end
    if wallBusy == true and wallReloadActive(server, record.locoId) then
        diagnose("roof-refresh-transaction-rejected")
        cache[identityKey] = nil
        return nil
    end
    pending[identityKey] = nil
    now = Adapter._ticks or Core.getTick()
    local boundary = Boundary.boundaryFor(record)
    if not transitionActive then
        cache[identityKey] = {
            boundary = boundary,
            record = record,
            relation = relation,
            validatedIdentity = validatedIdentity,
            manifest = manifest,
            validatedAtTick = now,
        }
    end
    return boundary, record, relation, validatedIdentity, manifest
end

function Adapter.validateCurrentBoundaryPlayer(player, suppliedIdentity,
    deferCacheMiss, forceRefresh)
    return validatePlayer(player, suppliedIdentity, nil, forceRefresh == true,
        deferCacheMiss == true)
end

local function needsRefresh(identityKey, forceRefresh)
    if forceRefresh then return true end
    local cached = cache[identityKey]
    local now = Adapter._ticks or Core.getTick()
    return cached == nil
        or now < cached.validatedAtTick
        or (now - cached.validatedAtTick) >= REFRESH_TICKS
end

function Adapter.prewarmCurrentBoundaryPlayer(player, knownMap, forceRefresh)
    local onlineId, name = playerId(player), playerName(player)
    if onlineId == nil or not name then return nil end
    local identity = { username = name, onlineId = onlineId,
        key = tostring(onlineId) .. ":" .. name }
    return validatePlayer(player, identity, knownMap,
        needsRefresh(identity.key, forceRefresh == true), false, false, true)
end

function Adapter.prewarmCurrentBoundaryPlayers(knownMap, knownPlayers)
    local generationBusy = serverTransactionMutexStatus()
    if generationBusy ~= false then return false end
    local now = Adapter._ticks or Core.getTick()
    if now < prewarmAfterTick then return false end
    prewarmAfterTick = now + PREWARM_RETRY_TICKS
    local candidates = knownPlayers
    if candidates == nil then
        candidates = {}
        local players, snapshotOk = onlinePlayersSnapshot()
        if not snapshotOk then return false end
        local region = rvRegion()
        for i = 1, #players do
            local player = players[i]
            if playerPositionInRegion(player, region) then
                candidates[#candidates + 1] = player
            end
        end
    end
    if #candidates == 0 then
        pending = {}
        return true
    end
    local map = type(knownMap) == "table" and knownMap or mapData()
    for i = 1, #candidates do
        Adapter.prewarmCurrentBoundaryPlayer(candidates[i], map)
    end
    pending = {}
    return true
end

local function prewarmAfterWorldLoad()
    Adapter.prewarmCurrentBoundaryPlayers()
end

local function prewarmCreatedPlayer(playerIndex, player)
    local candidate = player or playerIndex
    if not playerPositionInRegion(candidate, rvRegion()) then return end
    local map = mapData()
    Adapter.prewarmCurrentBoundaryPlayer(candidate, map)
end

if Events then
    if Events.OnGameStart and type(Events.OnGameStart.Add) == "function" then
        Events.OnGameStart.Add(prewarmAfterWorldLoad)
    end
    if Events.OnServerStarted and type(Events.OnServerStarted.Add) == "function" then
        Events.OnServerStarted.Add(prewarmAfterWorldLoad)
    end
    if Events.OnCreatePlayer and type(Events.OnCreatePlayer.Add) == "function" then
        Events.OnCreatePlayer.Add(prewarmCreatedPlayer)
    end
end

return { invalidate = invalidate }
end
