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
local prewarmAfterTick = { hi32 = 0, lo32 = 0 }

local function invalidate()
    cache = {}
    pending = {}
    prewarmAfterTick = { hi32 = 0, lo32 = 0 }
    Adapter._boundaryValidationWarmPending = true
end

local function roofRefreshBoundaryReadAllowed(server, record, identityKey)
    if type(server) ~= "table"
        or type(server.isRoofRefreshBoundaryReadAllowed) ~= "function"
        or type(record) ~= "table" then
        return false
    end
    local callOk, allowed = pcall(server.isRoofRefreshBoundaryReadAllowed,
        record.rvId, record.generation, record.bitmapVersion, identityKey)
    return callOk and allowed == true
end

local function roofRefreshBoundaryContextReadAllowed(server, record,
    identityKey)
    if type(server) ~= "table"
        or type(server.isRoofRefreshBoundaryContextReadAllowed) ~= "function"
        or type(record) ~= "table" then
        return false
    end
    local callOk, allowed = pcall(
        server.isRoofRefreshBoundaryContextReadAllowed, record.rvId,
        record.generation, record.bitmapVersion, identityKey)
    return callOk and allowed == true
end

local function validatePlayer(player, suppliedIdentity, knownMap,
    forceRefresh, deferCacheMiss, roofRefreshContextRead,
    roofRefreshGuardRead)
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
    local transactionStateValid = type(generationBusy) == "boolean"
        and type(roofBusy) == "boolean"
    local state = Boundary and Boundary._states
        and Boundary._states[identityKey]
    local transitionActive = state and state.transitionToken ~= nil
        and Core.isTick(Boundary._tick)
        and Core.isTick(state.transitionUntil)
        and Core.tickReached(state.transitionUntil, Boundary._tick)
    local mappingEpoch = Adapter._boundaryValidationEpoch or 0
    local geometryEpoch = Boundary and Boundary._geometryEpoch or 0
    local now = Adapter._ticks or Core.getTick()
    local cached = cache[identityKey]
    if not forceRefresh and not roofRefreshContextRead
        and transactionStateValid
        and generationBusy == false and not transitionActive
        and type(cached) == "table"
        and cached.mappingEpoch == mappingEpoch
        and cached.geometryEpoch == geometryEpoch
        and Core.isTick(cached.validatedAtTick)
        and Core.tickCompare(now, cached.validatedAtTick) >= 0
        and not Core.tickElapsedAtLeast(now, cached.validatedAtTick,
            CACHE_TTL_TICKS)
        and (roofBusy == false
            or roofRefreshGuardRead
                and roofRefreshBoundaryReadAllowed(server, cached.record,
                    identityKey)) then
        return cached.boundary, cached.record, cached.relation,
            cached.validatedIdentity, cached.manifest
    end
    local transitionReadBlocked = transitionActive
        and (not roofRefreshContextRead or roofBusy ~= true)
    if generationBusy ~= false or not transactionStateValid
        or transitionReadBlocked then
        cache[identityKey] = nil
        if forceRefresh or not deferCacheMiss then return nil end
        pending[identityKey] = true
        Adapter._boundaryValidationWarmPending = true
        return nil, "validation-deferred"
    end
    if deferCacheMiss and not forceRefresh and not roofRefreshContextRead then
        cache[identityKey] = nil
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
    if roofBusy == true then
        local roofReadAllowed = roofRefreshContextRead
            and roofRefreshBoundaryContextReadAllowed(server, record, identityKey)
            or roofRefreshGuardRead and not roofRefreshContextRead
                and roofRefreshBoundaryReadAllowed(server, record, identityKey)
        if not roofReadAllowed then
            diagnose("roof-refresh-transaction-rejected")
            cache[identityKey] = nil
            return nil
        end
    end
    pending[identityKey] = nil
    mappingEpoch = Adapter._boundaryValidationEpoch or 0
    geometryEpoch = Boundary and Boundary._geometryEpoch or 0
    now = Adapter._ticks or Core.getTick()
    if not transitionActive and not roofRefreshContextRead then
        cache[identityKey] = {
            boundary = record.boundary,
            record = record,
            relation = relation,
            validatedIdentity = validatedIdentity,
            manifest = manifest,
            mappingEpoch = mappingEpoch,
            geometryEpoch = geometryEpoch,
            validatedAtTick = now,
        }
    end
    return record.boundary, record, relation, validatedIdentity, manifest
end

function Adapter.validateCurrentBoundaryPlayer(player, suppliedIdentity,
    deferCacheMiss, forceRefresh, roofRefreshContextRead,
    roofRefreshGuardRead)
    return validatePlayer(player, suppliedIdentity, nil, forceRefresh == true,
        deferCacheMiss == true, roofRefreshContextRead == true,
        roofRefreshGuardRead == true)
end

local function needsRefresh(identityKey, forceRefresh)
    if forceRefresh then return true end
    local cached = cache[identityKey]
    local now = Adapter._ticks or Core.getTick()
    return type(cached) ~= "table"
        or cached.mappingEpoch ~= (Adapter._boundaryValidationEpoch or 0)
        or cached.geometryEpoch ~= (Boundary and Boundary._geometryEpoch or 0)
        or not Core.isTick(cached.validatedAtTick)
        or Core.tickCompare(now, cached.validatedAtTick) < 0
        or Core.tickElapsedAtLeast(now, cached.validatedAtTick,
            REFRESH_TICKS)
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
    if Core.tickCompare(now, prewarmAfterTick) < 0 then return false end
    prewarmAfterTick = Core.tickAdd(now, PREWARM_RETRY_TICKS)
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
