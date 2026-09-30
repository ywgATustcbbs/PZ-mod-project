-- RV_RailroaderServer: Mapping responsibilities.
return function(ctx)
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

local validatedMapCache
local boundaryValidation

local function invalidateBoundaryValidationCache()
    validatedMapCache = nil
    if boundaryValidation then
        boundaryValidation.invalidate()
    end
end

local function mapData()
    return ModData.get(C.RV_MAP_KEY)
end

local function markMappingChanged(boundaryChanged)
    Adapter.advanceMappingEpoch()
    if boundaryChanged ~= false then
        invalidateBoundaryValidationCache()
    end
    -- The train map is server-persistent authority. No client code reads this
    -- key, so keep the epoch/cache updates local and send no map snapshot.
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
    return type(relation) == "table"
        and type(relation.inside) == "boolean"
        and integer(relation.onlineId) ~= nil and integer(relation.onlineId) >= 0
        and (requireLocoId ~= true
            or type(relation.locoId) == "string" and relation.locoId ~= "")
end

local function recordRegion(record)
    return RegionSlots.indexToRegion(integer(record and record.slotIndex))
end

local function validMappingRecord(record)
    return type(record) == "table"
        and record.generated == true
        and type(record.locoId) == "string" and record.locoId ~= ""
        and integer(record.slotIndex) ~= nil
        and integer(record.generation) ~= nil and integer(record.generation) >= 1
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
    if type(record) ~= "table" or type(record.locoId) ~= "string"
        or record.locoId == ""
        or integer(record.generation) == nil or integer(record.generation) < 1 then
        return nil
    end
    return tostring(record.locoId) .. ":" .. tostring(record.generation)
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
        expiresAtTick = (Adapter._ticks or Core.getTick())
            + ROOF_REFRESH_TRANSITION_SUPPRESSION_TICKS,
    }
end

local function consumeSuppressedRoomTransition(roomKey)
    local suppression = suppressedRoomTransitions[roomKey]
    if type(suppression) ~= "table" then return false end
    if type(suppression.expiresAtTick) ~= "number"
        or (Adapter._ticks or Core.getTick()) > suppression.expiresAtTick then
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
    now = now or Adapter._ticks or Core.getTick()
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
            or type(seen.expiresAtTick) ~= "number"
            or now > seen.expiresAtTick then
            seenWallRemovalEvents[eventKey] = nil
        end
    end
    for roomKey, suppression in pairs(suppressedRoomTransitions) do
        if type(suppression) ~= "table"
            or type(suppression.expiresAtTick) ~= "number"
            or now > suppression.expiresAtTick then
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
                if type(event) ~= "table"
                    or type(expiresAt) ~= "number" then
                    print("[RailroaderRVTest] wall removal follow-up cancelled room="
                        .. tostring(roomKey) .. " event=" .. tostring(eventKey)
                        .. " reason=malformed-follow-up")
                    events[eventKey] = nil
                elseif event.waitingForGeneration == true then
                    -- This event already entered the generation wait.  Its
                    -- old absolute expiry is deliberately inert until the
                    -- post-generation current-identity revalidation.
                elseif now > expiresAt then
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
        and tostring(cached.rvId) == tostring(record.locoId)
        and integer(cached.generation) == integer(record.generation)
    if not force and cacheMatches then return true, "already refreshed" end
    local ok, refreshed, detail = pcall(server.refreshRoofVisuals, player, record)
    if not ok then
        print("[RailroaderRVTest] roof refresh error: " .. tostring(refreshed))
        return false, tostring(refreshed)
    end
    if refreshed == true then
        roofRefreshRooms[roomKey] = {
            roomKey = roomKey,
            rvId = tostring(record.locoId),
            generation = integer(record.generation),
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
    now = now or Adapter._ticks or Core.getTick()
    for roomKey, cached in pairs(roofRefreshRooms) do
        local updatedAt = cached and cached.updatedAtTick
        if type(cached) ~= "table"
            or type(cached.roomKey) ~= "string"
            or cached.roomKey ~= roomKey
            or type(updatedAt) ~= "number"
            or now < updatedAt
            or (now - updatedAt) >= ROOF_REFRESH_CACHE_TTL_TICKS + 1 then
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
        if type(record) == "table" and inRegion(position, recordRegion(record)) then
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
    local map = mapData()
    if locoId ~= nil then
        local existing = recordForLoco(map, tostring(locoId))
        if existing then
            if not validMappingRecord(existing) then
                return false, C.INVALID_RV_DATA
            end
            local slotIndex = integer(existing.slotIndex)
            local anchor = RegionSlots.indexToAnchor(slotIndex)
            if not anchor then return false, C.INVALID_RV_DATA end
            return true, slotIndex, anchor,
                RegionSlots.indexToRegion(slotIndex), integer(existing.generation)
        end
    end
    local occupied, occupiedSlots = {}, {}
    for _, record in pairs(map.locomotives or {}) do
        if not validMappingRecord(record) then return false, C.INVALID_RV_DATA end
        local region = recordRegion(record)
        local slotIndex = integer(record.slotIndex)
        if type(region) ~= "table" or occupiedSlots[slotIndex] then
            return false, C.INVALID_RV_DATA
        end
        occupiedSlots[slotIndex] = tostring(record.locoId)
        occupied[#occupied + 1] = { minX = integer(region.minX),
            minY = integer(region.minY), maxX = integer(region.maxX),
            maxY = integer(region.maxY) }
    end
    -- The published train map is the only persistent slot allocation.  An
    -- unmapped technical generation reserves nothing across a restart; its
    -- concurrency is owned by the in-memory generation transaction.
    local slotIndex, anchor = RegionSlots.findFirstFree(occupied)
    if not slotIndex or type(anchor) ~= "table" then
        return false, slotIndex == nil and "no free RV region slot" or C.INVALID_RV_DATA
    end
    return true, slotIndex, anchor, regionForAnchor(anchor)
end

local function currentMappingRecord(rvId, generation)
    local map = mapData()
    local record = recordForLoco(map, rvId)
    if not record or not validMappingRecord(record)
        or integer(record.generation) ~= integer(generation) then
        return false, C.INVALID_RV_DATA
    end
    return true, record
end

-- Utility commands resolve the current RV exclusively from the authoritative
-- mapping and player coordinate.  Client-supplied RV ids, generations and
-- object coordinates never enter this result. Identity checks run when an
-- operation consumes the mapped record.

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
