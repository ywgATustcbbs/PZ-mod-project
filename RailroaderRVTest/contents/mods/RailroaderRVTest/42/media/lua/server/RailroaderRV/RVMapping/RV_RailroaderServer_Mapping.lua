-- RV_RailroaderServer: Mapping responsibilities.
return function(ctx)
local DevSaveSchemaGate = require("RailroaderRV/Core/RV_DevSaveSchemaGate")
local Core = require("RailroaderRV/Core/RV_Server_Core")
local Boundary = ctx.Boundary
local Adapter = ctx.Adapter
local C = ctx.C
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local WORLD_MIN_Z = ctx.WORLD_MIN_Z
local WORLD_MAX_Z = ctx.WORLD_MAX_Z
local roofRefreshRooms = ctx.roofRefreshRooms
local ROOF_REFRESH_CACHE_TTL_TICKS = ctx.ROOF_REFRESH_CACHE_TTL_TICKS
local roofRefreshPlayers = ctx.roofRefreshPlayers
local followUpWallRemovalEvents = ctx.followUpWallRemovalEvents
local suppressedRoomTransitions = ctx.suppressedRoomTransitions
local seenWallRemovalEvents = ctx.seenWallRemovalEvents
local ROOF_REFRESH_TRANSITION_SUPPRESSION_TICKS = ctx.ROOF_REFRESH_TRANSITION_SUPPRESSION_TICKS
local recordForLoco
local function serverTransactionMutexStatus(...) return ctx.serverTransactionMutexStatus(...) end
local number = ctx.number
local integer = ctx.integer
local call = ctx.call
local playerId = ctx.playerId
local playerName = ctx.playerName
local findTrain = ctx.findTrain
local trainPosition = ctx.trainPosition
local copyPosition = ctx.copyPosition

DevSaveSchemaGate.configureMapping({
    C = C,
    RegionSlots = RegionSlots,
    Boundary = Boundary,
    number = number,
    integer = integer,
    copyPosition = copyPosition,
    WORLD_MIN_Z = WORLD_MIN_Z,
    WORLD_MAX_Z = WORLD_MAX_Z,
})

local MAP_SCHEMA_VALIDATION_TTL_TICKS = 120
local validatedMapCache
local boundaryValidation

local function invalidateBoundaryValidationCache()
    validatedMapCache = nil
    if boundaryValidation then
        boundaryValidation.invalidate()
    else
        Adapter._boundaryValidationWarmPending = true
    end
end

local function mapData()
    if not DevSaveSchemaGate.isReady() then error(C.INVALID_RV_DATA) end
    if not ModData then
        error(C.INVALID_RV_DATA)
    end
    local map
    if type(ModData.get) == "function" then
        local ok, value = pcall(ModData.get, C.RV_MAP_KEY)
        if not ok then error(C.INVALID_RV_DATA) end
        map = value
    elseif type(ModData.getOrCreate) == "function" then
        local ok, value = pcall(ModData.getOrCreate, C.RV_MAP_KEY)
        if not ok then error("Railroader RV map ModData is unavailable") end
        map = value
    else
        error("Railroader RV map ModData is unavailable")
    end
    if map == nil then
        if type(ModData.getOrCreate) ~= "function" then
            error("Railroader RV map ModData is unavailable")
        end
        local ok, value = pcall(ModData.getOrCreate, C.RV_MAP_KEY)
        if not ok or type(value) ~= "table" then
            error("Railroader RV map ModData is unavailable")
        end
        map = value
        map.schemaVersion = C.MAP_SCHEMA_VERSION
        map.locomotives = {}
        map.players = {}
    elseif type(map) ~= "table" then
        error(C.INVALID_RV_DATA)
    else
        local empty = true
        for _ in pairs(map) do
            empty = false
            break
        end
        if empty then
            -- An empty key is a new save's uninitialised map, not a persisted
            -- This is an empty new container.  Initialise only the current
            -- schema; a non-empty incompatible container is rejected above.
            map.schemaVersion = C.MAP_SCHEMA_VERSION
            map.locomotives = {}
            map.players = {}
        end
    end
    return map
end

local function markMappingChanged(boundaryChanged)
    Adapter._mappingEpoch = (Adapter._mappingEpoch or 0) + 1
    if boundaryChanged ~= false then
        Adapter._boundaryValidationEpoch =
            (Adapter._boundaryValidationEpoch or 0) + 1
        invalidateBoundaryValidationCache()
    end
    -- The train map is server-persistent authority. ModData.transmit sends its
    -- entire table, including the static boundary bitmap; no client code reads
    -- this key, so keep the epoch/cache updates local and send no map snapshot.
end

local function rvRegion(anchor)
    local size = integer(C.RV_REGION_SIZE)
    local baseX = integer(C.TELEPORT_X)
    local baseY = integer(C.TELEPORT_Y)
    if type(anchor) == "table" then
        baseX, baseY = integer(anchor.x), integer(anchor.y)
    end
    local minX = baseX + integer(C.RV_REGION_MIN_OFFSET_X)
    local minY = baseY + integer(C.RV_REGION_MIN_OFFSET_Y)
    -- Mapping identity covers the design's full world Z range. The 100x100x2
    -- construction/clear bounds remain in record.managed and the layout.
    local minZ = integer(C.RV_IDENTITY_MIN_Z)
    local maxZ = integer(C.RV_IDENTITY_MAX_Z)
    return { minX = minX, minY = minY,
        maxX = minX + size * RegionSlots.COLUMNS,
        maxY = minY + size * RegionSlots.ROWS, minZ = minZ, maxZ = maxZ }
end

local function regionForAnchor(anchor)
    local envelope = rvRegion(anchor)
    envelope.maxX = envelope.minX + integer(C.RV_REGION_SIZE)
    envelope.maxY = envelope.minY + integer(C.RV_REGION_SIZE)
    return envelope
end

local function playerPositionInRegion(player, region)
    if not player or type(region) ~= "table" then return nil end
    local zOk, z = call(player, "getZ")
    z = zOk and number(z) or nil
    local minZ, maxZ = number(region.minZ), number(region.maxZ)
    if z == nil or minZ == nil or maxZ == nil
        or math.floor(z) < math.floor(minZ)
        or math.floor(z) >= math.floor(maxZ) then
        return nil
    end
    local xOk, x = call(player, "getX")
    x = xOk and number(x) or nil
    local minX, maxX = number(region.minX), number(region.maxX)
    if x == nil or minX == nil or maxX == nil or x < minX or x >= maxX then
        return nil
    end
    local yOk, y = call(player, "getY")
    y = yOk and number(y) or nil
    local minY, maxY = number(region.minY), number(region.maxY)
    if y == nil or minY == nil or maxY == nil or y < minY or y >= maxY then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function inRegion(position, region)
    if type(position) ~= "table" or type(region) ~= "table" then return false end
    local z = number(position.z)
    local minZ, maxZ = number(region.minZ), number(region.maxZ)
    if z == nil or minZ == nil or maxZ == nil
        or math.floor(z) < math.floor(minZ)
        or math.floor(z) >= math.floor(maxZ) then
        return false
    end
    local x, y = number(position.x), number(position.y)
    local minX, minY = number(region.minX), number(region.minY)
    local maxX, maxY = number(region.maxX), number(region.maxY)
    if not x or not y or not minX or not minY or not maxX or not maxY then
        return false
    end
    return x >= minX and x < maxX and y >= minY and y < maxY
end

local function validRegion(region)
    if type(region) ~= "table" then return false end
    local size = integer(C.RV_REGION_SIZE)
    local minX, minY = integer(region.minX), integer(region.minY)
    local minZ, maxZ = integer(region.minZ), integer(region.maxZ)
    return minX ~= nil and minY ~= nil and integer(region.maxX) == minX + size
        and integer(region.maxY) == minY + size
        and minZ == integer(C.RV_IDENTITY_MIN_Z)
        and maxZ == integer(C.RV_IDENTITY_MAX_Z)
        and minZ >= WORLD_MIN_Z and maxZ <= WORLD_MAX_Z + 1
end

local function validMapRelation(relation, requireLocoId)
    return DevSaveSchemaGate.isReady() and type(relation) == "table"
        and type(relation.inside) == "boolean"
        and integer(relation.onlineId) ~= nil and integer(relation.onlineId) >= 0
        and (requireLocoId ~= true
            or type(relation.locoId) == "string" and relation.locoId ~= "")
end

local function validMappingRecord(record)
    return DevSaveSchemaGate.isReady() and type(record) == "table"
        and record.generated == true
        and type(record.rvId) == "string" and record.rvId ~= ""
        and tostring(record.locoId) == record.rvId
        and integer(record.generation) ~= nil and integer(record.generation) >= 1
        and integer(record.bitmapVersion) == integer(C.BITMAP_VERSION)
end

local function validRecord(record)
    return validMappingRecord(record)
end

recordForLoco = function(map, locoId)
    if not map or not map.locomotives or locoId == nil then return nil, nil end
    local wanted = tostring(locoId)
    for key, record in pairs(map.locomotives) do
        if type(record) == "table" and record.locoId ~= nil
            and tostring(record.locoId) == wanted then
            return record, key
        end
    end
    return nil, nil
end

boundaryValidation = require("RailroaderRV/BoundaryGuard/RV_RailroaderServer_BoundaryValidation")({
    Boundary = Boundary,
    Adapter = Adapter,
    mapData = mapData,
    rvRegion = rvRegion,
    playerPositionInRegion = playerPositionInRegion,
    recordForLoco = recordForLoco,
    validRecord = validRecord,
    serverTransactionMutexStatus = serverTransactionMutexStatus,
    integer = integer,
    playerId = playerId,
    playerName = playerName,
    onlinePlayersSnapshot = function()
        local snapshot = ctx.onlinePlayersSnapshot
        if type(snapshot) == "function" then return snapshot() end
        return {}
    end,
})
local function roofRefreshRoomKey(record)
    if type(record) ~= "table" or record.locoId == nil
        or record.rvId == nil or tostring(record.rvId) == ""
        or tostring(record.rvId) ~= tostring(record.locoId)
        or integer(record.generation) == nil or integer(record.generation) < 1
        or integer(record.bitmapVersion) ~= C.BITMAP_VERSION then
        return nil
    end
    return tostring(record.rvId) .. ":" .. tostring(record.generation)
        .. ":" .. tostring(record.bitmapVersion)
end

local function isWallRemovalSource(source)
    return source == "object-about-to-be-removed"
        or source == "destroy-iso-thumpable"
        or source == "follow-up-wall-removal"
end

local function markSuppressedRoomTransition(pending)
    if type(pending) ~= "table" or not isWallRemovalSource(pending.source)
        or type(pending.roomKey) ~= "string" then
        return
    end
    suppressedRoomTransitions[pending.roomKey] = {
        roomKey = pending.roomKey,
        token = pending.relocationToken or pending.returnToken,
        expiresAtTick = Core.tickAdd(Adapter._ticks or Core.getTick(),
            ROOF_REFRESH_TRANSITION_SUPPRESSION_TICKS),
    }
end

local function consumeSuppressedRoomTransition(roomKey)
    local suppression = suppressedRoomTransitions[roomKey]
    if type(suppression) ~= "table" then return false end
    if not Core.isTick(suppression.expiresAtTick)
        or Core.tickCompare(Adapter._ticks or Core.getTick(),
            suppression.expiresAtTick) == 1 then
        suppressedRoomTransitions[roomKey] = nil
        return false
    end
    suppressedRoomTransitions[roomKey] = nil
    print("[RailroaderRVTest] room transition suppressed room="
        .. tostring(roomKey) .. " token=" .. tostring(suppression.token)
        .. " reason=wall-removal-relocation")
    return true
end

-- The two removal hooks use only the stable coordinate/object-index event key
-- for the short duplicate-callback window.  Never retain userdata; the current
-- RV identity/room key owns the actual transaction below.
local function pruneRoofRefreshDedupeState(now)
    now = Core.isTick(now) and now or Adapter._ticks or Core.getTick()
    -- Follow-up expiry is paused while generation owns the shared scope.  If
    -- the mutex query is temporarily unavailable, fail closed by preserving
    -- the bounded queue until a later tick can classify it.
    local generationBusy = true
    if serverTransactionMutexStatus then
        local mutexCallOk, active = pcall(function()
            return select(1, serverTransactionMutexStatus())
        end)
        if mutexCallOk and type(active) == "boolean" then
            generationBusy = active
        end
    end
    for eventKey, seen in pairs(seenWallRemovalEvents) do
        if type(seen) ~= "table"
            or not Core.isTick(seen.expiresAtTick)
            or Core.tickCompare(now, seen.expiresAtTick) == 1 then
            seenWallRemovalEvents[eventKey] = nil
        end
    end
    for roomKey, suppression in pairs(suppressedRoomTransitions) do
        if type(suppression) ~= "table"
            or not Core.isTick(suppression.expiresAtTick)
            or Core.tickCompare(now, suppression.expiresAtTick) == 1 then
            suppressedRoomTransitions[roomKey] = nil
        end
    end
    for roomKey, events in pairs(followUpWallRemovalEvents) do
        if type(events) ~= "table" then
            followUpWallRemovalEvents[roomKey] = nil
        else
            for eventKey, event in pairs(events) do
                local expiresAt = type(event) == "table"
                    and event.expiresAtTick or nil
                if type(event) ~= "table" or not Core.isTick(expiresAt) then
                    print("[RailroaderRVTest] wall removal follow-up cancelled room="
                        .. tostring(roomKey) .. " event=" .. tostring(eventKey)
                        .. " reason=malformed-follow-up")
                    events[eventKey] = nil
                elseif event.waitingForGeneration == true then
                    -- This event already entered the generation wait.  Its
                    -- old absolute expiry is deliberately inert until the
                    -- post-generation current-identity revalidation.
                elseif Core.tickCompare(now, expiresAt) == 1 then
                    -- Do not resurrect an event whose ordinary lease expired
                    -- before generation became active on this tick.
                    events[eventKey] = nil
                elseif generationBusy and type(event) == "table" then
                    event.waitingForGeneration = true
                end
            end
            local empty = true
            for _ in pairs(events) do empty = false; break end
            if empty then followUpWallRemovalEvents[roomKey] = nil end
        end
    end
end

local function wallRemovalEventKey(object, roomKey)
    if object == nil or type(roomKey) ~= "string" then return nil end
    local indexOk, index = call(object, "getObjectIndex")
    index = indexOk and integer(index) or nil
    if index ~= nil and index < 0 then index = nil end
    local squareOk, square = call(object, "getSquare")
    local x, y, z
    if squareOk and square then
        local xOk, squareX = call(square, "getX")
        local yOk, squareY = call(square, "getY")
        local zOk, squareZ = call(square, "getZ")
        if xOk and yOk and zOk then
            x, y, z = integer(squareX), integer(squareY), integer(squareZ)
        end
    end
    if x == nil or y == nil or z == nil then
        local xOk, objectX = call(object, "getX")
        local yOk, objectY = call(object, "getY")
        local zOk, objectZ = call(object, "getZ")
        if xOk and yOk and zOk then
            x, y, z = integer(objectX), integer(objectY), integer(objectZ)
        end
    end
    if x == nil or y == nil or z == nil then return nil end
    local coordinateKey = roomKey .. ":" .. tostring(x) .. ":" .. tostring(y)
        .. ":" .. tostring(z)
    if index ~= nil then
        -- Return both the object-index key and its coordinate alias.  The
        -- alias closes the common callback gap where the object index exists
        -- before removal but is unavailable in the later destroy callback.
        return coordinateKey .. ":" .. tostring(index), coordinateKey
    end
    -- Some direct destruction paths do not expose an object index.  A stable
    -- coordinate fallback keeps the same callback pair deduped while retaining
    -- distinct wall cells as independent follow-up events.  If even the
    -- authoritative coordinate is unavailable, the caller fails closed.
    return coordinateKey .. ":fallback-wall", coordinateKey
end

-- The roof refresh is deliberately best-effort: a missing target chunk must not
-- reject an otherwise valid RV entry.  OnTick retries it after the player has
-- streamed the persisted room into the authoritative server cell.
local function refreshRoofForPlayer(player, record, force, reason)
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.refreshRoofVisuals) ~= "function" then
        return false, "roof refresh service is unavailable"
    end
    local roomKey = roofRefreshRoomKey(record)
    if not roomKey then return false, "RV generation key is unavailable" end
    local cached = roofRefreshRooms[roomKey]
    local cacheMatches = type(cached) == "table"
        and tostring(cached.rvId) == tostring(record.rvId)
        and integer(cached.generation) == integer(record.generation)
        and integer(cached.bitmapVersion) == integer(record.bitmapVersion)
    if not force and cacheMatches then return true, "already refreshed" end
    local ok, refreshed, detail = pcall(server.refreshRoofVisuals, player, record)
    if not ok then
        print("[RailroaderRVTest] roof refresh error: " .. tostring(refreshed))
        return false, tostring(refreshed)
    end
    if refreshed == true then
        roofRefreshRooms[roomKey] = {
            roomKey = roomKey,
            rvId = tostring(record.rvId),
            generation = integer(record.generation),
            bitmapVersion = integer(record.bitmapVersion),
            updatedAtTick = Adapter._ticks or Core.getTick(),
        }
        local name = playerName(player)
        if name then roofRefreshPlayers[name .. ":" .. roomKey] = true end
        -- This confirms the server-side room/roof neighbour synchronization;
        -- it cannot prove that every client's rendered cache updated.
        print("[RailroaderRVTest] roof room synchronization applied room=" .. roomKey
            .. " reason=" .. tostring(reason or "entry")
            .. " detail=" .. tostring(detail or "ok"))
        return true, detail
    end
    print("[RailroaderRVTest] roof refresh deferred room=" .. roomKey
        .. " reason=" .. tostring(reason or "entry")
        .. ": " .. tostring(detail or "unknown"))
    return false, detail
end

local function pruneRoofRefreshRooms(now)
    now = Core.isTick(now) and now or Adapter._ticks or Core.getTick()
    for roomKey, cached in pairs(roofRefreshRooms) do
        local updatedAt = cached and cached.updatedAtTick
        if type(cached) ~= "table"
            or type(cached.roomKey) ~= "string"
            or cached.roomKey ~= roomKey
            or not Core.isTick(updatedAt)
            or Core.tickCompare(now, updatedAt) < 0
            or Core.tickElapsedAtLeast(now, updatedAt,
                ROOF_REFRESH_CACHE_TTL_TICKS + 1) then
            roofRefreshRooms[roomKey] = nil
        end
    end
end

-- The generation transaction broadcasts a room guard, but an existing RV entry
-- or a newly connected player does not pass through that transaction.  Ask the
-- generic server layer to validate the current manifest/mapping identity and
-- send the current footprint only to this player.
local function armRoomOwnershipMonitor(player, record, reason)
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.armCurrentRoomOwnershipMonitor) ~= "function" then
        return false, "room ownership monitor service is unavailable"
    end
    local ok, armed, detail = pcall(server.armCurrentRoomOwnershipMonitor,
        player, record)
    if not ok then
        print("[RailroaderRVTest] room ownership monitor error: " .. tostring(armed))
        return false, C.INVALID_RV_DATA
    end
    if armed ~= true then
        print("[RailroaderRVTest] room ownership monitor deferred reason="
            .. tostring(reason or "entry") .. ": " .. tostring(detail or "unknown"))
        return false, detail or "room ownership monitor could not be armed"
    end
    print("[RailroaderRVTest] room ownership monitor ready reason="
        .. tostring(reason or "entry"))
    return true
end

-- The reverse lookup intentionally starts with the passenger coordinate.  It
-- never asks a world-room API, a room identifier, or a generated object which
-- RV the player belongs to.  A current-schema mapping whose live locomotive
-- is temporarily absent is retained for the persisted
-- vehicle-pose exit.  Coordinates outside the target 100x100 region are a
-- separate outside-rv rejection and are never corrected by this adapter.
local function recordAtPlayerCoordinate(map, player)
    local position = playerPositionInRegion(player, rvRegion())
    if not position then return nil, nil, nil, "outside-rv" end
    for key, record in pairs(map.locomotives or {}) do
        if type(record) == "table" and inRegion(position, record.region) then
            if not validMappingRecord(record) then
                error(C.INVALID_RV_DATA)
            end
            local train = findTrain(record.locoId)
            if train and trainPosition(train) then
                return record, key, train, "active-mapped"
            end
            return record, key, nil, "inactive-mapped"
        end
    end
    return nil, nil, nil, "unmapped-rv"
end

local function allocateRVRegion(locoId)
    local ok, map = pcall(mapData)
    if not ok or type(map) ~= "table" then return false, C.INVALID_RV_DATA end
    if locoId ~= nil then
        local existing = recordForLoco(map, tostring(locoId))
        if existing then
            if not validMappingRecord(existing) then
                return false, C.INVALID_RV_DATA
            end
            return true, integer(existing.slotIndex), {
                x = integer(existing.anchor.x), y = integer(existing.anchor.y),
                z = integer(existing.anchor.z),
            }, regionForAnchor(existing.anchor), integer(existing.generation)
        end
    end
    local occupied, occupiedSlots = {}, {}
    for _, record in pairs(map.locomotives or {}) do
        if not validMappingRecord(record) then return false, C.INVALID_RV_DATA end
        local region = record.region
        local slotIndex = integer(record.slotIndex)
        if occupiedSlots[slotIndex] then return false, C.INVALID_RV_DATA end
        occupiedSlots[slotIndex] = tostring(record.rvId)
        occupied[#occupied + 1] = { minX = integer(region.minX),
            minY = integer(region.minY), maxX = integer(region.maxX),
            maxY = integer(region.maxY) }
    end
    -- A current technical generation has no locomotive entry to reserve its
    -- slot in TrainMap. Keep its exact current manifest slot occupied so a
    -- different RV cannot reuse or silently overwrite that technical identity.
    if ModData and type(ModData.get) == "function" then
        local manifestOk, manifest = pcall(ModData.get, C.MANIFEST_KEY)
        if not manifestOk then return false, C.INVALID_RV_DATA end
        if type(manifest) == "table" then
            local empty = true
            for _ in pairs(manifest) do
                empty = false
                break
            end
            if not empty then
                local manifestSlot = integer(manifest.slotIndex)
                local manifestRvId = type(manifest.rvId) == "string"
                    and manifest.rvId or nil
                local state = manifest.state
                local manifestAnchor = manifest.anchor
                if not manifestSlot or manifestSlot < 1
                    or manifestSlot > RegionSlots.COUNT
                    or not manifestRvId or manifestRvId == ""
                    or type(state) ~= "string"
                    or RegionSlots.indexForAnchor(manifestAnchor) ~= manifestSlot then
                    return false, C.INVALID_RV_DATA
                end
                local mappedRvId = occupiedSlots[manifestSlot]
                if mappedRvId ~= nil and mappedRvId ~= manifestRvId then
                    return false, C.INVALID_RV_DATA
                end
                local rollbackComplete = state == "FAILED"
                    and manifest.rollback == "COMPLETE"
                if not mappedRvId and not rollbackComplete then
                    local region = RegionSlots.indexToRegion(manifestSlot)
                    if type(region) ~= "table" then
                        return false, C.INVALID_RV_DATA
                    end
                    occupiedSlots[manifestSlot] = manifestRvId
                    occupied[#occupied + 1] = region
                end
            end
        elseif manifest ~= nil then
            return false, C.INVALID_RV_DATA
        end
    end
    local slotIndex, anchor = RegionSlots.findFirstFree(occupied)
    if not slotIndex or type(anchor) ~= "table" then
        return false, slotIndex == nil and "no free RV region slot" or C.INVALID_RV_DATA
    end
    return true, slotIndex, anchor, regionForAnchor(anchor)
end

local function currentMappingRecord(rvId, generation, bitmapVersion)
    local ok, map = pcall(mapData)
    if not ok or type(map) ~= "table" then return false, C.INVALID_RV_DATA end
    local record = recordForLoco(map, rvId)
    if not record or not validMappingRecord(record)
        or integer(record.generation) ~= integer(generation)
        or integer(record.bitmapVersion) ~= integer(bitmapVersion) then
        return false, C.INVALID_RV_DATA
    end
    return true, record
end

-- Utility commands resolve the current RV exclusively from the authoritative
-- mapping and player coordinate.  Client-supplied RV ids, generations and
-- object coordinates never enter this result.  The generic server geometry
-- gate is run again so a water request cannot use a stale mapping snapshot.

ctx.mapData = mapData
ctx.markMappingChanged = markMappingChanged
ctx.rvRegion = rvRegion
ctx.inRegion = inRegion
ctx.validRegion = validRegion
ctx.validMapRelation = validMapRelation
ctx.validMappingRecord = validMappingRecord
ctx.validRecord = validRecord
ctx.roofRefreshRoomKey = roofRefreshRoomKey
ctx.isWallRemovalSource = isWallRemovalSource
ctx.markSuppressedRoomTransition = markSuppressedRoomTransition
ctx.consumeSuppressedRoomTransition = consumeSuppressedRoomTransition
ctx.pruneRoofRefreshDedupeState = pruneRoofRefreshDedupeState
ctx.wallRemovalEventKey = wallRemovalEventKey
ctx.refreshRoofForPlayer = refreshRoofForPlayer
ctx.pruneRoofRefreshRooms = pruneRoofRefreshRooms
ctx.armRoomOwnershipMonitor = armRoomOwnershipMonitor
ctx.recordAtPlayerCoordinate = recordAtPlayerCoordinate
ctx.recordForLoco = recordForLoco
ctx.allocateRVRegion = allocateRVRegion
ctx.currentMappingRecord = currentMappingRecord
Adapter.allocateRVRegion = allocateRVRegion
Adapter.currentMappingRecord = currentMappingRecord
Adapter.invalidateBoundaryValidationCache = invalidateBoundaryValidationCache
end
