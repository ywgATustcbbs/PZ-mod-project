-- RV_RailroaderServer: Mapping responsibilities.
return function(ctx)
local Core = require("RailroaderRV/Core/RV_Server_Core")
local Boundary = ctx.Boundary
local Adapter = ctx.Adapter
local C = ctx.C
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local WORLD_MIN_Z = ctx.WORLD_MIN_Z
local WORLD_MAX_Z = ctx.WORLD_MAX_Z
local recordForLoco
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

local function recordRegion(record)
    local region = RegionSlots.indexToRegion(integer(record and record.slotIndex))
    region.minZ = integer(C.RV_IDENTITY_MIN_Z)
    region.maxZ = integer(C.RV_IDENTITY_MAX_Z)
    return region
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
    serverTransactionMutexStatus = function()
        return ctx.serverTransactionMutexStatus()
    end,
    integer = integer,
    playerId = playerId,
    playerName = playerName,
    onlinePlayersSnapshot = function()
        local snapshot = ctx.onlinePlayersSnapshot
        if type(snapshot) == "function" then return snapshot() end
        return {}
    end,
})
-- Entry, generation-entry and wall-reload completion all register the same
-- four RV-id-only attempts against the Core logical tick.
local function refreshRoofForPlayer(_player, record, _force, _reason)
    RailroaderRV.Server.scheduleRoofRefreshForRV(record.locoId)
    return true
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
        print("[RailroaderRV] room ownership monitor error: " .. tostring(armed))
        return false, C.INVALID_RV_DATA
    end
    if armed ~= true then
        print("[RailroaderRV] room ownership monitor deferred reason="
            .. tostring(reason or "entry") .. ": " .. tostring(detail or "unknown"))
        return false, detail or "room ownership monitor could not be armed"
    end
    print("[RailroaderRV] room ownership monitor ready reason="
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
            return true, slotIndex, anchor, integer(existing.generation)
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
    return true, slotIndex, anchor
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

local function currentMappingRecordById(rvId)
    return recordForLoco(mapData(), rvId)
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
ctx.validMappingRecord = validMappingRecord
ctx.validRecord = validRecord
ctx.recordRegion = recordRegion
ctx.playerPositionInRegion = playerPositionInRegion
ctx.refreshRoofForPlayer = refreshRoofForPlayer
ctx.armRoomOwnershipMonitor = armRoomOwnershipMonitor
ctx.recordAtPlayerCoordinate = recordAtPlayerCoordinate
ctx.recordForLoco = recordForLoco
Adapter.allocateRVRegion = allocateRVRegion
Adapter.currentMappingRecord = currentMappingRecord
Adapter.currentMappingRecordById = currentMappingRecordById
Adapter.invalidateBoundaryValidationCache = invalidateBoundaryValidationCache
end
