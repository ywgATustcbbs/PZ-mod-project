-- RV_RailroaderServer: Mapping responsibilities.
return function(ctx)
local Boundary = ctx.Boundary
local Adapter = ctx.Adapter
local C = ctx.C
local WORLD_MIN_Z = ctx.WORLD_MIN_Z
local WORLD_MAX_Z = ctx.WORLD_MAX_Z
local roofRepairRooms = ctx.roofRepairRooms
local ROOF_REPAIR_CACHE_TTL_TICKS = ctx.ROOF_REPAIR_CACHE_TTL_TICKS
local roofRepairPlayers = ctx.roofRepairPlayers
local followUpWallRemovalEvents = ctx.followUpWallRemovalEvents
local suppressedRoomTransitions = ctx.suppressedRoomTransitions
local seenWallRemovalEvents = ctx.seenWallRemovalEvents
local ROOF_REPAIR_TRANSITION_SUPPRESSION_TICKS = ctx.ROOF_REPAIR_TRANSITION_SUPPRESSION_TICKS
local function validateMapSchema(...) return ctx.validateMapSchema(...) end
local function recordForLoco(...) return ctx.recordForLoco(...) end
local function serverTransactionMutexStatus(...) return ctx.serverTransactionMutexStatus(...) end
local number = ctx.number
local integer = ctx.integer
local call = ctx.call
local playerId = ctx.playerId
local playerName = ctx.playerName
local copyPosition = ctx.copyPosition
local findTrain = ctx.findTrain
local trainPosition = ctx.trainPosition

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
        elseif integer(map.schemaVersion) ~= C.MAP_SCHEMA_VERSION
            or type(map.locomotives) ~= "table"
            or type(map.players) ~= "table" then
            error(C.INVALID_RV_DATA)
        end
    end
    local mappingEpoch = Adapter._boundaryValidationEpoch or 0
    local geometryEpoch = Boundary and Boundary._geometryEpoch or 0
    local now = Adapter._ticks or 0
    local cached = validatedMapCache
    if type(cached) == "table" and cached.map == map
        and cached.mappingEpoch == mappingEpoch
        and cached.geometryEpoch == geometryEpoch
        and now >= cached.validatedAtTick
        and now - cached.validatedAtTick < MAP_SCHEMA_VALIDATION_TTL_TICKS then
        return map
    end
    if validateMapSchema and not validateMapSchema(map) then
        error(C.INVALID_RV_DATA)
    end
    geometryEpoch = Boundary and Boundary._geometryEpoch or 0
    validatedMapCache = { map = map, mappingEpoch = mappingEpoch,
        geometryEpoch = geometryEpoch, validatedAtTick = now }
    return map
end

local function transmitMap(boundaryChanged)
    Adapter._mappingEpoch = (Adapter._mappingEpoch or 0) + 1
    if boundaryChanged ~= false then
        Adapter._boundaryValidationEpoch =
            (Adapter._boundaryValidationEpoch or 0) + 1
        invalidateBoundaryValidationCache()
    end
    if ModData and type(ModData.transmit) == "function" then
        pcall(ModData.transmit, C.RV_MAP_KEY)
    end
end

local function rvRegion()
    local minX = integer(C.TELEPORT_X) + integer(C.RV_REGION_MIN_OFFSET_X)
    local minY = integer(C.TELEPORT_Y) + integer(C.RV_REGION_MIN_OFFSET_Y)
    local size = integer(C.RV_REGION_SIZE)
    local minZ = integer(C.TELEPORT_Z) + integer(C.RV_MANAGED_MIN_Z_OFFSET)
    local maxZ = integer(C.TELEPORT_Z) + integer(C.RV_MANAGED_MAX_Z_OFFSET)
    return { minX = minX, minY = minY, maxX = minX + size,
        maxY = minY + size, minZ = minZ, maxZ = maxZ }
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
    local allowed = { minX = true, minY = true, maxX = true, maxY = true,
        minZ = true, maxZ = true }
    for key in pairs(region) do if not allowed[key] then return false end end
    local size = integer(C.RV_REGION_SIZE)
    local minX, minY = integer(region.minX), integer(region.minY)
    local minZ, maxZ = integer(region.minZ), integer(region.maxZ)
    return minX ~= nil and minY ~= nil and integer(region.maxX) == minX + size
        and integer(region.maxY) == minY + size
        and minZ ~= nil and maxZ ~= nil and maxZ > minZ
        and minZ >= WORLD_MIN_Z and maxZ <= WORLD_MAX_Z + 1
end

local function mapOnlyKeys(value, expected)
    if type(value) ~= "table" then return false end
    local allowed = {}
    for i = 1, #expected do allowed[expected[i]] = true end
    for key in pairs(value) do if not allowed[key] then return false end end
    return true
end

local function validMapPosition(value, pose)
    local keys = pose and { "x", "y", "z", "dirX", "dirY" }
        or { "x", "y", "z" }
    local x, y, z = value and number(value.x), value and number(value.y),
        value and number(value.z)
    if not mapOnlyKeys(value, keys) or copyPosition(value) == nil
        or x == nil or y == nil or z == nil
        or z < WORLD_MIN_Z or z > WORLD_MAX_Z then
        return false
    end
    return not pose or number(value.dirX) ~= nil and number(value.dirY) ~= nil
end

local function validMapRelation(relation, requireLocoId)
    if type(relation) ~= "table"
        or not mapOnlyKeys(relation, { "schemaVersion", "locoId", "onlineId",
            "inside", "role", "seat", "enterPosition", "exitPosition" })
        or relation.locomotive ~= nil
        or relation.locoId ~= nil and type(relation.locoId) ~= "string"
        or requireLocoId == true and relation.locoId == nil
        or integer(relation.schemaVersion) ~= C.RV_RELATION_SCHEMA_VERSION
        or integer(relation.onlineId) == nil or integer(relation.onlineId) < 0
        or relation.role ~= nil and type(relation.role) ~= "string"
        or relation.seat ~= nil and integer(relation.seat) == nil
        or type(relation.inside) ~= "boolean" then
        return false
    end
    if relation.inside then
        return validMapPosition(relation.enterPosition, false)
    end
    return validMapPosition(relation.exitPosition, false)
end

local function validMappingRecord(record)
    if type(record) ~= "table" or record.generated ~= true
        or not mapOnlyKeys(record, { "schemaVersion", "generated", "locoId",
            "rvId", "generation", "region", "rvPosition", "enterPosition",
            "locoPosition", "boundarySchemaVersion", "bitmapVersion",
            "boundary", "managed", "players", "updatedAt" })
        or integer(record.schemaVersion) ~= C.RV_RECORD_SCHEMA_VERSION
        or type(record.locoId) ~= "string" or record.locoId == ""
        or type(record.rvId) ~= "string" or record.rvId ~= record.locoId
        or integer(record.boundarySchemaVersion) ~= C.BOUNDARY_SCHEMA_VERSION
        or integer(record.bitmapVersion) ~= C.BITMAP_VERSION
        or integer(record.generation) == nil or integer(record.generation) < 1
        or integer(record.updatedAt) == nil or integer(record.updatedAt) < 1
        or not validRegion(record.region) then
        return false
    end
    if type(record.boundary) ~= "table"
        or type(record.players) ~= "table"
        or not validMapPosition(record.rvPosition, false)
        or not validMapPosition(record.enterPosition, false)
        or not validMapPosition(record.locoPosition, true)
        or not mapOnlyKeys(record.managed, { "originX", "originY", "width",
            "height", "minZ", "maxZ" })
        or type(record.boundary.managed) ~= "table"
        or integer(record.managed.originX) ~= integer(record.boundary.managed.originX)
        or integer(record.managed.originY) ~= integer(record.boundary.managed.originY)
        or integer(record.managed.width) ~= integer(record.boundary.managed.width)
        or integer(record.managed.height) ~= integer(record.boundary.managed.height)
        or integer(record.managed.minZ) ~= integer(record.boundary.managed.minZ)
        or integer(record.managed.maxZ) ~= integer(record.boundary.managed.maxZ) then
        return false
    end
    if Boundary and type(Boundary.registerGeneration) == "function" then
        local ok, valid = pcall(Boundary.registerGeneration,
            record.locoId, record.generation, record.boundary, nil)
        if not ok or valid ~= true then return false end
    else
        return false
    end
    for name, rider in pairs(record.players) do
        if type(name) ~= "string" or not validMapRelation(rider, false) then
            return false
        end
    end
    return true
end

local function validRecord(record)
    return validMappingRecord(record)
end

validateMapSchema = function(map)
    if type(map) ~= "table"
        or not mapOnlyKeys(map, { "schemaVersion", "locomotives", "players" })
        or integer(map.schemaVersion) ~= C.MAP_SCHEMA_VERSION
        or type(map.locomotives) ~= "table"
        or type(map.players) ~= "table" then
        return false
    end
    for key, record in pairs(map.locomotives) do
        if type(key) ~= "string" or not validMappingRecord(record)
            or tostring(record.locoId) ~= key then
            return false
        end
    end
    for name, relation in pairs(map.players) do
        if type(name) ~= "string" or not validMapRelation(relation, true) then
            return false
        end
        if relation.inside == true then
            local record = relation.locoId and recordForLoco(map, relation.locoId)
            if not record or type(record.players) ~= "table"
                or type(record.players[name]) ~= "table"
                or record.players[name].inside ~= true then
                return false
            end
        end
    end
    return true
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

boundaryValidation = require("RailroaderRV/RV_RailroaderServer_BoundaryValidation")({
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
local function roofRepairRoomKey(record)
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
        expiresAtTick = (Adapter._ticks or 0)
            + ROOF_REPAIR_TRANSITION_SUPPRESSION_TICKS,
    }
end

local function consumeSuppressedRoomTransition(roomKey)
    local suppression = suppressedRoomTransitions[roomKey]
    if type(suppression) ~= "table" then return false end
    if (Adapter._ticks or 0) > (suppression.expiresAtTick or 0) then
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
local function pruneRoofRepairDedupeState(now)
    now = integer(now) or (Adapter._ticks or 0)
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
            or now > (integer(seen.expiresAtTick) or 0) then
            seenWallRemovalEvents[eventKey] = nil
        end
    end
    for roomKey, suppression in pairs(suppressedRoomTransitions) do
        if type(suppression) ~= "table"
            or now > (integer(suppression.expiresAtTick) or 0) then
            suppressedRoomTransitions[roomKey] = nil
        end
    end
    for roomKey, events in pairs(followUpWallRemovalEvents) do
        if type(events) ~= "table" then
            followUpWallRemovalEvents[roomKey] = nil
        else
            for eventKey, event in pairs(events) do
                local expiresAt = type(event) == "table"
                    and integer(event.expiresAtTick) or nil
                if type(event) ~= "table" or expiresAt == nil then
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

-- The repair is deliberately best-effort: a missing target chunk must not
-- reject an otherwise valid RV entry.  OnTick retries it after the player has
-- streamed the persisted room into the authoritative server cell.
local function repairRoofForPlayer(player, record, force, reason)
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.repairRoofVisuals) ~= "function" then
        return false, "roof repair service is unavailable"
    end
    local roomKey = roofRepairRoomKey(record)
    if not roomKey then return false, "RV generation key is unavailable" end
    local cached = roofRepairRooms[roomKey]
    local cacheMatches = type(cached) == "table"
        and tostring(cached.rvId) == tostring(record.rvId)
        and integer(cached.generation) == integer(record.generation)
        and integer(cached.bitmapVersion) == integer(record.bitmapVersion)
    if not force and cacheMatches then return true, "already repaired" end
    local ok, repaired, detail = pcall(server.repairRoofVisuals, player)
    if not ok then
        print("[RailroaderRVTest] roof visual repair error: " .. tostring(repaired))
        return false, tostring(repaired)
    end
    if repaired == true then
        roofRepairRooms[roomKey] = {
            roomKey = roomKey,
            rvId = tostring(record.rvId),
            generation = integer(record.generation),
            bitmapVersion = integer(record.bitmapVersion),
            updatedAtTick = Adapter._ticks or 0,
        }
        local name = playerName(player)
        if name then roofRepairPlayers[name .. ":" .. roomKey] = true end
        -- This confirms the server-side room/roof neighbour synchronization;
        -- it cannot prove that every client's rendered cache updated.
        print("[RailroaderRVTest] roof room synchronization applied room=" .. roomKey
            .. " reason=" .. tostring(reason or "entry")
            .. " detail=" .. tostring(detail or "ok"))
        return true, detail
    end
    print("[RailroaderRVTest] roof visual repair deferred room=" .. roomKey
        .. " reason=" .. tostring(reason or "entry")
        .. ": " .. tostring(detail or "unknown"))
    return false, detail
end

local function pruneRoofRepairRooms(now)
    now = integer(now) or (Adapter._ticks or 0)
    for roomKey, cached in pairs(roofRepairRooms) do
        if type(cached) ~= "table"
            or type(cached.roomKey) ~= "string"
            or cached.roomKey ~= roomKey
            or now - (integer(cached.updatedAtTick) or 0)
                > ROOF_REPAIR_CACHE_TTL_TICKS then
            roofRepairRooms[roomKey] = nil
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

-- Utility commands resolve the current RV exclusively from the authoritative
-- mapping and player coordinate.  Client-supplied RV ids, generations and
-- object coordinates never enter this result.  The generic server geometry
-- gate is run again so a water request cannot use a stale mapping snapshot.

ctx.mapData = mapData
ctx.transmitMap = transmitMap
ctx.rvRegion = rvRegion
ctx.inRegion = inRegion
ctx.validRegion = validRegion
ctx.validMapRelation = validMapRelation
ctx.validMappingRecord = validMappingRecord
ctx.validRecord = validRecord
ctx.roofRepairRoomKey = roofRepairRoomKey
ctx.isWallRemovalSource = isWallRemovalSource
ctx.markSuppressedRoomTransition = markSuppressedRoomTransition
ctx.consumeSuppressedRoomTransition = consumeSuppressedRoomTransition
ctx.pruneRoofRepairDedupeState = pruneRoofRepairDedupeState
ctx.wallRemovalEventKey = wallRemovalEventKey
ctx.repairRoofForPlayer = repairRoofForPlayer
ctx.pruneRoofRepairRooms = pruneRoofRepairRooms
ctx.armRoomOwnershipMonitor = armRoomOwnershipMonitor
ctx.recordAtPlayerCoordinate = recordAtPlayerCoordinate
ctx.recordForLoco = recordForLoco
Adapter.invalidateBoundaryValidationCache = invalidateBoundaryValidationCache
end
