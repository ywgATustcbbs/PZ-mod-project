-- RV_RailroaderServer: boundary validation cache and prewarming.
return function(ctx)
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
    Adapter._boundaryValidationWarmPending = true
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
    local generationBusy, roofBusy = serverTransactionMutexStatus()
    local idle = generationBusy == false and roofBusy == false
    local state = Boundary and Boundary._states
        and Boundary._states[identityKey]
    local transitionActive = state and state.transitionToken ~= nil
        and (Boundary._tick or 0) <= (state.transitionUntil or 0)
    local mappingEpoch = Adapter._boundaryValidationEpoch or 0
    local geometryEpoch = Boundary and Boundary._geometryEpoch or 0
    local now = Adapter._ticks or 0
    local cached = cache[identityKey]
    if not forceRefresh and idle and not transitionActive
        and type(cached) == "table"
        and cached.mappingEpoch == mappingEpoch
        and cached.geometryEpoch == geometryEpoch
        and now >= cached.validatedAtTick
        and now - cached.validatedAtTick < CACHE_TTL_TICKS then
        return cached.boundary, cached.record, cached.relation,
            cached.validatedIdentity
    end
    if not idle or transitionActive then
        cache[identityKey] = nil
        if forceRefresh then return nil end
    end
    if deferCacheMiss then
        pending[identityKey] = true
        Adapter._boundaryValidationWarmPending = true
        return nil, "validation-deferred"
    end

    local map = knownMap
    if type(map) ~= "table" then
        local mapOk
        mapOk, map = pcall(mapData)
        if not mapOk then map = nil end
    end
    if type(map) ~= "table" then
        cache[identityKey] = nil
        return nil
    end
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
        or type(server.currentRVManifestForBoundary) ~= "function"
        or type(server.currentRVRecordGeometryConsistent) ~= "function" then
        cache[identityKey] = nil
        return nil
    end
    local manifestCallOk, manifestAccepted, manifest = pcall(
        server.currentRVManifestForBoundary, record.rvId, record.generation,
        record.bitmapVersion)
    if not manifestCallOk or manifestAccepted ~= true
        or type(manifest) ~= "table" then
        diagnose("manifest-rejected")
        cache[identityKey] = nil
        return nil
    end
    local geometryCallOk, geometryConsistent = pcall(
        server.currentRVRecordGeometryConsistent, record, manifest)
    if not geometryCallOk or geometryConsistent ~= true then
        diagnose("geometry-rejected")
        cache[identityKey] = nil
        return nil
    end
    pending[identityKey] = nil
    mappingEpoch = Adapter._boundaryValidationEpoch or 0
    geometryEpoch = Boundary and Boundary._geometryEpoch or 0
    now = Adapter._ticks or 0
    if idle and not transitionActive then
        cache[identityKey] = {
            boundary = record.boundary,
            record = record,
            relation = relation,
            validatedIdentity = validatedIdentity,
            mappingEpoch = mappingEpoch,
            geometryEpoch = geometryEpoch,
            validatedAtTick = now,
        }
    end
    return record.boundary, record, relation, validatedIdentity
end

function Adapter.validateCurrentBoundaryPlayer(player, suppliedIdentity,
    deferCacheMiss)
    return validatePlayer(player, suppliedIdentity, nil, false,
        deferCacheMiss == true)
end

local function needsRefresh(identityKey, forceRefresh)
    if forceRefresh then return true end
    local cached = cache[identityKey]
    local now = Adapter._ticks or 0
    return type(cached) ~= "table"
        or cached.mappingEpoch ~= (Adapter._boundaryValidationEpoch or 0)
        or cached.geometryEpoch ~= (Boundary and Boundary._geometryEpoch or 0)
        or now < cached.validatedAtTick
        or now - cached.validatedAtTick >= REFRESH_TICKS
end

function Adapter.prewarmCurrentBoundaryPlayer(player, knownMap, forceRefresh)
    local onlineId, name = playerId(player), playerName(player)
    if onlineId == nil or not name then return nil end
    local identity = { username = name, onlineId = onlineId,
        key = tostring(onlineId) .. ":" .. name }
    return validatePlayer(player, identity, knownMap,
        needsRefresh(identity.key, forceRefresh == true), false)
end

function Adapter.prewarmCurrentBoundaryPlayers(knownMap, knownPlayers)
    local generationBusy, roofBusy = serverTransactionMutexStatus()
    if generationBusy ~= false or roofBusy ~= false then return false end
    local now = Adapter._ticks or 0
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
        Adapter._boundaryValidationWarmPending = false
        return true
    end
    local map = knownMap
    if type(map) ~= "table" then
        local mapOk
        mapOk, map = pcall(mapData)
        if not mapOk or type(map) ~= "table" then return false end
    end
    for i = 1, #candidates do
        Adapter.prewarmCurrentBoundaryPlayer(candidates[i], map)
    end
    pending = {}
    Adapter._boundaryValidationWarmPending = false
    return true
end

local function prewarmAfterWorldLoad()
    Adapter.prewarmCurrentBoundaryPlayers()
end

local function prewarmCreatedPlayer(playerIndex, player)
    local candidate = player or playerIndex
    if not playerPositionInRegion(candidate, rvRegion()) then return end
    local mapOk, map = pcall(mapData)
    if not mapOk or type(map) ~= "table" then return end
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
