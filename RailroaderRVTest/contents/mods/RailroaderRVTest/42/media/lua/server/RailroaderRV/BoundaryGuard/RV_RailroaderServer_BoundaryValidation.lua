-- RV_RailroaderServer: boundary validation cache and prewarming.
return function(ctx)
local Core = require("RailroaderRV/Core/RV_Server_Core")
local Boundary = ctx.Boundary
local Adapter = ctx.Adapter
local mapData = ctx.mapData
local rvRegion = ctx.rvRegion
local playerPositionInRegion = ctx.playerPositionInRegion
local recordForLoco = ctx.recordForLoco
local validRecord = ctx.validRecord
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
    if type(server) ~= "table"
        or type(server.isWallReloadTransactionActive) ~= "function" then
        return true
    end
    local callOk, active = pcall(server.isWallReloadTransactionActive, rvId)
    return not callOk or type(active) ~= "boolean" or active
end

local function validatePlayer(player, suppliedIdentity, knownMap,
    forceRefresh, deferCacheMiss)
    local identityId, name, identityKey
    if type(suppliedIdentity) == "table"
        and type(suppliedIdentity.key) == "string"
        and type(suppliedIdentity.username) == "string"
        and integer(suppliedIdentity.onlineId) ~= nil then
        identityId = integer(suppliedIdentity.onlineId)
        name = suppliedIdentity.username
        identityKey = suppliedIdentity.key
    else
        identityId, name = playerId(player), playerName(player)
        if identityId ~= nil and name then
            identityKey = tostring(identityId) .. ":" .. name
        end
    end
    if identityId == nil or not name
        or identityKey ~= tostring(identityId) .. ":" .. name then
        return nil
    end

    local server = RailroaderRV and RailroaderRV.Server
    local generationBusy, wallBusy = serverTransactionMutexStatus()
    local transactionStateValid = type(generationBusy) == "boolean"
        and type(wallBusy) == "boolean"
    local state = Boundary and Boundary._states
        and Boundary._states[identityKey]
    local transitionActive = state ~= nil
        and type(state.leaseToken) == "string"
        and type(Boundary._tick) == "number"
        and type(state.leaseUntil) == "number"
        and state.leaseUntil >= Boundary._tick
    local now = Adapter._ticks or Core.getTick()
    local cached = cache[identityKey]
    if not forceRefresh
        and transactionStateValid
        and generationBusy == false and not transitionActive
        and type(cached) == "table"
        and type(cached.validatedAtTick) == "number"
        and now >= cached.validatedAtTick
        and (now - cached.validatedAtTick) < CACHE_TTL_TICKS then
        return cached.boundary, cached.record, cached.relation,
            cached.validatedIdentity, cached.manifest
    end
    if generationBusy ~= false or not transactionStateValid or transitionActive then
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

    local map = type(knownMap) == "table" and knownMap or mapData()
    local relation = map.players[name]
    local record = type(relation) == "table" and relation.locoId ~= nil
        and recordForLoco(map, relation.locoId) or nil
    local validatedIdentity = {
        username = name, onlineId = identityId, key = identityKey,
    }
    local function diagnose(reason)
        if type(Boundary.diagnoseGuardState) == "function" then
            Boundary.diagnoseGuardState(player, validatedIdentity,
                playerPositionInRegion(player, rvRegion()), relation, record,
                reason)
        end
    end
    if type(relation) ~= "table" or relation.inside ~= true
        or integer(relation.onlineId) ~= identityId then
        diagnose("mapping-relation-rejected")
        cache[identityKey] = nil
        return nil
    end
    if not record or not validRecord(record) then
        diagnose("mapping-record-rejected")
        cache[identityKey] = nil
        return nil
    end
    local rider = type(record.players) == "table" and record.players[name] or nil
    if type(rider) ~= "table" or rider.inside ~= true
        or integer(rider.onlineId) ~= identityId then
        diagnose("record-rider-rejected")
        cache[identityKey] = nil
        return nil
    end
    if not server
        or type(server.currentRVManifestForBoundary) ~= "function" then
        cache[identityKey] = nil
        return nil
    end
    local manifestCallOk, manifestAccepted, manifest = pcall(
        server.currentRVManifestForBoundary, record.locoId, record.generation)
    if not manifestCallOk or manifestAccepted ~= true
        or type(manifest) ~= "table" then
        diagnose("manifest-rejected")
        cache[identityKey] = nil
        return nil
    end
    if wallBusy == true and wallReloadActive(server, record.locoId) then
        diagnose("roof-refresh-transaction-rejected")
        cache[identityKey] = nil
        return nil
    end
    pending[identityKey] = nil
    now = Adapter._ticks or Core.getTick()
    local boundary = Boundary and Boundary.boundaryFor(record) or nil
    if not boundary then
        diagnose("geometry-rejected")
        cache[identityKey] = nil
        return nil
    end
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
    return type(cached) ~= "table"
        or type(cached.validatedAtTick) ~= "number"
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
    local generationBusy, roofBusy = serverTransactionMutexStatus()
    if generationBusy ~= false or type(roofBusy) ~= "boolean" then return false end
    local now = Adapter._ticks or Core.getTick()
    if now < prewarmAfterTick then return false end
    prewarmAfterTick = now + PREWARM_RETRY_TICKS
    local candidates = knownPlayers
    if type(candidates) ~= "table" then
        candidates = {}
        local players, region = onlinePlayersSnapshot(), rvRegion()
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
