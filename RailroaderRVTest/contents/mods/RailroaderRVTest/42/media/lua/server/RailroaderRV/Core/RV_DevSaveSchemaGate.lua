-- RELEASE REMOVE: remove this entire module before release.
-- 发行前必须整体移除此开发期存档 schema gate。
-- It scans the ModData roots after GlobalModData has loaded and caches one
-- pass/fail result for this server process. It never creates or migrates data.
local Gate = {}
local mappingDependencies
local manifestDependencies
local OWNER, Constants, Boundary, Bitmap, Layout, RegionSlots, ServerUtil
local ServerSchema
local BoundarySchemaConstants
local Template = require("RailroaderRV/RoomTemplate/RV_Template")
local validatedBoundaryCache = setmetatable({}, { __mode = "k" })
local validateUtilityAtStartup
local validateRecordGeometryAtStartup
local validatedManifestRoot
local required = { "mapping", "manifest", "utility", "record_geometry" }
local status = "pending"
local reason
local ran = false
local validating = false

local function fail(message)
    if status == "failed" then return end
    status = "failed"
    reason = tostring(message or "schema validation failed")
    print("[RailroaderRVTest] RV disabled: " .. reason
        .. ". Delete this test save and rebuild it with the current development version.")
end

-- Business code may supply data access and static helpers, but persisted
-- schema predicates live in this development-only gate.
function Gate.configureMapping(dependencies)
    if ran or status ~= "pending" or type(dependencies) ~= "table" then
        fail("mapping schema dependencies were unavailable before startup validation")
        return false
    end
    mappingDependencies = dependencies
    BoundarySchemaConstants = dependencies.C
    return true
end

function Gate.configureManifest(dependencies)
    if ran or status ~= "pending" or type(dependencies) ~= "table" then
        fail("manifest schema dependencies were unavailable before startup validation")
        return false
    end
    manifestDependencies = dependencies
    OWNER = dependencies.OWNER
    Constants = dependencies.Constants
    BoundarySchemaConstants = dependencies.Constants
    Boundary = dependencies.Boundary
    Bitmap = dependencies.Bitmap
    Layout = dependencies.Layout
    RegionSlots = dependencies.RegionSlots
    ServerUtil = dependencies.ServerUtil
    return true
end

function Gate.configureRecordGeometry(dependencies)
    if ran or status ~= "pending" or type(dependencies) ~= "table" then
        fail("record geometry schema dependencies were unavailable before startup validation")
        return false
    end
    ServerSchema = dependencies.ServerSchema
    return true
end

function Gate.isReady()
    return status == "passed"
end

function Gate.failureReason()
    return reason
end

function Gate.isValidating()
    return validating
end

local function exactKeys(value, expected)
    if type(value) ~= "table" then return false end
    local allowed = {}
    for i = 1, #expected do allowed[expected[i]] = true end
    for key in pairs(value) do if not allowed[key] then return false end end
    return true
end

local function boundaryInteger(value)
    if type(value) == "number" then
        return math.floor(value) == value and value or nil
    end
    if type(value) == "string" then
        value = tonumber(value)
        return value ~= nil and math.floor(value) == value and value or nil
    end
    if value ~= nil then
        local ok, result = pcall(function() return value + 0 end)
        if ok and type(result) == "number" and math.floor(result) == result then
            return result
        end
    end
    return nil
end

local function validShellEdges(edges, rvId, generation, bitmapVersion, managed, C, Template)
    if type(edges) ~= "table" or rvId == nil or tostring(rvId) == ""
        or boundaryInteger(generation) == nil or boundaryInteger(generation) < 1
        or boundaryInteger(bitmapVersion) ~= C.BITMAP_VERSION
        or type(managed) ~= "table" then
        return false
    end
    local originX, originY = boundaryInteger(managed.originX), boundaryInteger(managed.originY)
    local width, height = boundaryInteger(managed.width), boundaryInteger(managed.height)
    local anchorZ = boundaryInteger(managed.minZ)
    if not originX or not originY or not width or not height
        or not anchorZ or width ~= C.RV_MANAGED_WIDTH
        or height ~= C.RV_MANAGED_HEIGHT then return false end
    local anchorX = originX + math.floor(width / 2)
    local anchorY = originY + math.floor(height / 2)
    local edgeCount = 0
    local allowedEdgeKeys = {
        edgeKey = true, rvId = true, generation = true,
        bitmapVersion = true, hostX = true, hostY = true, z = true,
        axis = true, side = true, objectX = true, objectY = true,
        objectZ = true, role = true, corner = true,
        replacementAllowed = true, templateIndex = true, templateIndices = true,
        sprite = true,
        north = true,
    }
    for key, edge in pairs(edges) do
        edgeCount = edgeCount + 1
        if type(key) ~= "string" or type(edge) ~= "table"
            or edge.edgeKey ~= key then
            return false
        end
        for field in pairs(edge) do
            if not allowedEdgeKeys[field] then return false end
        end
        local axis, edgeX, edgeY, edgeZ = string.match(
            key, "^([NW]):(-?%d+):(-?%d+):(-?%d+)$")
        edgeX, edgeY, edgeZ = tonumber(edgeX), tonumber(edgeY), tonumber(edgeZ)
        if not axis or edgeX == nil or edgeY == nil or edgeZ == nil
            or edge.axis ~= axis
            or tostring(edge.rvId) ~= tostring(rvId)
            or boundaryInteger(edge.generation) ~= boundaryInteger(generation)
            or boundaryInteger(edge.bitmapVersion) ~= boundaryInteger(bitmapVersion)
            or boundaryInteger(edge.hostX) ~= edgeX
            or boundaryInteger(edge.hostY) ~= edgeY
            or boundaryInteger(edge.z) ~= edgeZ
            or boundaryInteger(edge.objectX) == nil
            or boundaryInteger(edge.objectY) == nil
            or boundaryInteger(edge.objectZ) == nil
            or (axis == "N" and edge.side ~= "north"
                and edge.side ~= "south")
            or (axis == "W" and edge.side ~= "west"
                and edge.side ~= "east")
            or boundaryInteger(edge.objectX) ~= edgeX
            or boundaryInteger(edge.objectY) ~= edgeY
            or boundaryInteger(edge.objectZ) ~= edgeZ
            or boundaryInteger(edge.templateIndex) == nil
            or type(edge.templateIndices) ~= "table"
            or #edge.templateIndices < 1
            or type(edge.sprite) ~= "string"
            or type(edge.north) ~= "boolean"
            or type(edge.role) ~= "string"
            or type(edge.corner) ~= "boolean"
            or type(edge.replacementAllowed) ~= "boolean" then
            return false
        end
        local captured = Template.objects[boundaryInteger(edge.templateIndex)]
        local expectedRole = edge.corner and "corner-nw"
            or (edge.north and "wall-north" or "wall-west")
        if not captured
            or (captured.class ~= "IsoThumpable" and captured.class ~= "IsoWindow")
            or captured.sprite ~= edge.sprite or captured.north ~= edge.north
            or captured.x ~= boundaryInteger(edge.objectX) - anchorX
            or captured.y ~= boundaryInteger(edge.objectY) - anchorY
            or captured.z ~= boundaryInteger(edge.objectZ) - anchorZ
            or edge.role ~= expectedRole
            or edge.corner and edge.north ~= true then
            return false
        end
        local partCount, partSeen = 0, {}
        for partKey in pairs(edge.templateIndices) do
            partCount = partCount + 1
            if type(partKey) ~= "number" or partKey < 1
                or math.floor(partKey) ~= partKey or partKey > #edge.templateIndices then
                return false
            end
        end
        if partCount ~= #edge.templateIndices
            or edge.templateIndices[1] ~= boundaryInteger(edge.templateIndex) then
            return false
        end
        for partPosition = 1, #edge.templateIndices do
            local partIndex = boundaryInteger(edge.templateIndices[partPosition])
            local part = partIndex and Template.objects[partIndex]
            if not part or partSeen[partIndex]
                or (part.class ~= "IsoThumpable" and part.class ~= "IsoWindow")
                or part.x ~= boundaryInteger(edge.objectX) - anchorX
                or part.y ~= boundaryInteger(edge.objectY) - anchorY
                or part.z ~= boundaryInteger(edge.objectZ) - anchorZ
                or part.north ~= edge.north then
                return false
            end
            partSeen[partIndex] = true
        end
    end
    return edgeCount == 59
end

local function validateBoundarySchema(boundary)
    if type(boundary) ~= "table" then return nil end
    local cached = validatedBoundaryCache[boundary]
    if cached then
        return cached.bitmap, cached.rvId, cached.generation,
            cached.bitmapVersion
    end
    local C = BoundarySchemaConstants
    if type(C) ~= "table" or not Bitmap
        or not exactKeys(boundary, { "schemaVersion", "rvId", "generation",
            "bitmapVersion", "managed", "bitmap", "shellEdges" })
        or boundaryInteger(boundary.schemaVersion) ~= C.BOUNDARY_SCHEMA_VERSION
        or type(boundary.bitmap) ~= "table" then
        return nil
    end
    local bitmapOk, bitmap = pcall(Bitmap.decode, boundary.bitmap)
    if not bitmapOk or type(bitmap) ~= "table" then return nil end
    local validOk, valid = pcall(Bitmap.validate, bitmap)
    if not validOk or valid ~= true then return nil end
    local managed = boundary.managed
    if not exactKeys(managed, { "originX", "originY", "width", "height",
        "minZ", "maxZ" })
        or boundaryInteger(managed.originX) ~= bitmap.originX
        or boundaryInteger(managed.originY) ~= bitmap.originY
        or boundaryInteger(managed.width) ~= bitmap.width
        or boundaryInteger(managed.height) ~= bitmap.height
        or boundaryInteger(managed.minZ) ~= bitmap.minZ
        or boundaryInteger(managed.maxZ) ~= bitmap.maxZ then
        return nil
    end
    local rvId = boundary.rvId
    local generation = boundaryInteger(boundary.generation)
    local bitmapVersion = boundaryInteger(boundary.bitmapVersion)
    local encodedVersion = boundaryInteger(boundary.bitmap.bitmapVersion)
    if rvId == nil or tostring(rvId) == "" or generation == nil or generation < 1
        or bitmapVersion ~= C.BITMAP_VERSION or encodedVersion ~= bitmapVersion
        or not validShellEdges(boundary.shellEdges, rvId, generation,
            bitmapVersion, boundary.managed, C, Template) then
        return nil
    end
    local decoded = { bitmap = bitmap, rvId = tostring(rvId),
        generation = generation, bitmapVersion = bitmapVersion }
    validatedBoundaryCache[boundary] = decoded
    return decoded.bitmap, decoded.rvId, decoded.generation,
        decoded.bitmapVersion
end

function Gate.validateBoundarySchema(boundary)
    return validateBoundarySchema(boundary)
end

function Gate.validatedBoundary(boundary)
    local decoded = type(boundary) == "table" and validatedBoundaryCache[boundary]
        or nil
    if not decoded then return nil end
    return decoded.bitmap, decoded.rvId, decoded.generation,
        decoded.bitmapVersion
end

local function validateMappingPosition(value, pose, dependencies)
    local fields = pose and { "x", "y", "z", "dirX", "dirY" }
        or { "x", "y", "z" }
    if not exactKeys(value, fields) then return false end
    local number = dependencies.number
    local x, y, z = number(value.x), number(value.y), number(value.z)
    if type(dependencies.copyPosition) ~= "function"
        or dependencies.copyPosition(value) == nil
        or x == nil or y == nil or z == nil
        or z < dependencies.WORLD_MIN_Z or z > dependencies.WORLD_MAX_Z then
        return false
    end
    return not pose or number(value.dirX) ~= nil and number(value.dirY) ~= nil
end

local function validateMappingRegion(region, dependencies)
    if not exactKeys(region, { "minX", "minY", "maxX", "maxY", "minZ", "maxZ" }) then
        return false
    end
    local C, integer = dependencies.C, dependencies.integer
    local size = integer(C.RV_REGION_SIZE)
    local minX, minY = integer(region.minX), integer(region.minY)
    local minZ, maxZ = integer(region.minZ), integer(region.maxZ)
    return minX ~= nil and minY ~= nil and integer(region.maxX) == minX + size
        and integer(region.maxY) == minY + size
        and minZ == integer(C.RV_IDENTITY_MIN_Z)
        and maxZ == integer(C.RV_IDENTITY_MAX_Z)
        and minZ >= dependencies.WORLD_MIN_Z
        and maxZ <= dependencies.WORLD_MAX_Z + 1
end

local function validateMappingRelation(relation, requireLocoId, dependencies)
    local C, integer = dependencies.C, dependencies.integer
    if not exactKeys(relation, { "schemaVersion", "locoId", "onlineId",
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
        return validateMappingPosition(relation.enterPosition, false, dependencies)
    end
    return validateMappingPosition(relation.exitPosition, false, dependencies)
end

local function validateMappingRecord(record, dependencies)
    local C, integer, number = dependencies.C, dependencies.integer, dependencies.number
    local RegionSlots, Boundary = dependencies.RegionSlots, dependencies.Boundary
    if type(record) ~= "table" or record.generated ~= true
        or not exactKeys(record, { "schemaVersion", "generated", "locoId",
            "rvId", "generation", "slotIndex", "anchor", "region", "rvPosition",
            "enterPosition", "locoPosition", "boundarySchemaVersion", "bitmapVersion",
            "boundary", "managed", "players", "updatedAt" })
        or integer(record.schemaVersion) ~= C.RV_RECORD_SCHEMA_VERSION
        or type(record.locoId) ~= "string" or record.locoId == ""
        or type(record.rvId) ~= "string" or record.rvId ~= record.locoId
        or integer(record.boundarySchemaVersion) ~= C.BOUNDARY_SCHEMA_VERSION
        or integer(record.bitmapVersion) ~= C.BITMAP_VERSION
        or integer(record.generation) == nil or integer(record.generation) < 1
        or integer(record.slotIndex) == nil or integer(record.slotIndex) < 1
        or integer(record.slotIndex) > RegionSlots.COUNT
        or type(record.anchor) ~= "table"
        or RegionSlots.indexForAnchor(record.anchor) ~= integer(record.slotIndex)
        or integer(record.updatedAt) == nil or integer(record.updatedAt) < 1
        or not validateMappingRegion(record.region, dependencies)
        or RegionSlots.indexForRegion({ minX = integer(record.region.minX),
            minY = integer(record.region.minY), maxX = integer(record.region.maxX),
            maxY = integer(record.region.maxY) }) ~= integer(record.slotIndex)
        or integer(record.region.minZ) ~= integer(C.RV_IDENTITY_MIN_Z)
        or integer(record.region.maxZ) ~= integer(C.RV_IDENTITY_MAX_Z)
        or not exactKeys(record.anchor, { "x", "y", "z" })
        or integer(record.anchor.x) == nil or integer(record.anchor.y) == nil
        or integer(record.anchor.z) == nil then
        return false
    end
    if type(record.boundary) ~= "table" or type(record.players) ~= "table"
        or not validateMappingPosition(record.rvPosition, false, dependencies)
        or number(record.rvPosition.x) ~= integer(record.anchor.x) + 0.5
        or number(record.rvPosition.y) ~= integer(record.anchor.y) + 0.5
        or number(record.rvPosition.z) ~= integer(record.anchor.z)
        or not validateMappingPosition(record.enterPosition, false, dependencies)
        or not validateMappingPosition(record.locoPosition, true, dependencies)
        or not exactKeys(record.managed, { "originX", "originY", "width", "height", "minZ", "maxZ" })
        or type(record.boundary.managed) ~= "table"
        or integer(record.managed.originX) ~= integer(record.boundary.managed.originX)
        or integer(record.managed.originY) ~= integer(record.boundary.managed.originY)
        or integer(record.managed.width) ~= integer(record.boundary.managed.width)
        or integer(record.managed.height) ~= integer(record.boundary.managed.height)
        or integer(record.managed.minZ) ~= integer(record.boundary.managed.minZ)
        or integer(record.managed.maxZ) ~= integer(record.boundary.managed.maxZ) then
        return false
    end
    if integer(record.managed.originX) ~= integer(record.anchor.x) + integer(C.RV_REGION_MIN_OFFSET_X)
        or integer(record.managed.originY) ~= integer(record.anchor.y) + integer(C.RV_REGION_MIN_OFFSET_Y)
        or integer(record.managed.width) ~= integer(C.RV_MANAGED_WIDTH)
        or integer(record.managed.height) ~= integer(C.RV_MANAGED_HEIGHT)
        or integer(record.managed.minZ) ~= integer(record.anchor.z) + integer(C.RV_MANAGED_MIN_Z_OFFSET)
        or integer(record.managed.maxZ) ~= integer(record.anchor.z) + integer(C.RV_MANAGED_MAX_Z_OFFSET) then
        return false
    end
    local decodedBitmap = validateBoundarySchema(record.boundary)
    if not decodedBitmap or not Boundary
        or type(Boundary.registerGeneration) ~= "function" then return false end
    local ok, valid = pcall(Boundary.registerGeneration, record.locoId,
        record.generation, record.boundary, nil)
    if not ok or valid ~= true then return false end
    for name, rider in pairs(record.players) do
        if type(name) ~= "string"
            or not validateMappingRelation(rider, false, dependencies) then
            return false
        end
    end
    return true
end

local function validateMappingRoot(map, dependencies)
    local C, integer = dependencies.C, dependencies.integer
    if not exactKeys(map, { "schemaVersion", "locomotives", "players" })
        or integer(map.schemaVersion) ~= C.MAP_SCHEMA_VERSION
        or type(map.locomotives) ~= "table" or type(map.players) ~= "table" then
        return false
    end
    local occupiedSlots, recordCount = {}, 0
    for key, record in pairs(map.locomotives) do
        recordCount = recordCount + 1
        if type(key) ~= "string" or not validateMappingRecord(record, dependencies)
            or tostring(record.locoId) ~= key or occupiedSlots[integer(record.slotIndex)] then
            return false
        end
        occupiedSlots[integer(record.slotIndex)] = true
    end
    if recordCount > dependencies.RegionSlots.COUNT then return false end
    for name, relation in pairs(map.players) do
        if type(name) ~= "string"
            or not validateMappingRelation(relation, true, dependencies) then
            return false
        end
        if relation.inside then
            local record
            for _, candidate in pairs(map.locomotives) do
                if type(candidate) == "table" and candidate.locoId ~= nil
                    and tostring(candidate.locoId) == tostring(relation.locoId) then
                    record = candidate
                    break
                end
            end
            if not record or type(record.players) ~= "table"
                or type(record.players[name]) ~= "table"
                or record.players[name].inside ~= true then
                return false
            end
        end
    end
    return true
end

local function validateMappingAtStartup()
    local dependencies = mappingDependencies
    if type(dependencies) ~= "table" or not ModData
        or type(ModData.get) ~= "function" then
        return false, "mapping ModData or schema dependencies are unavailable"
    end
    local ok, map = pcall(ModData.get, dependencies.C.RV_MAP_KEY)
    if not ok then return false, "mapping ModData read failed" end
    if map == nil then return true end
    if type(map) ~= "table" then return false, "mapping root is not a table" end
    if next(map) == nil then return true end
    return validateMappingRoot(map, dependencies), "mapping does not match the current schema"
end

local function currentBoundsValid(bounds, managed, bitmap, anchor)
    local function onlyKeys(value, expected)
        if type(value) ~= "table" then return false end
        local allowed = {}
        for i = 1, #expected do allowed[expected[i]] = true end
        for key in pairs(value) do
            if not allowed[key] then return false end
        end
        return true
    end
    local function sameTemplateIndices(left, right)
        if type(left) ~= "table" or type(right) ~= "table"
            or #left < 1 or #left ~= #right then
            return false
        end
        local leftCount, rightCount = 0, 0
        for key in pairs(left) do
            leftCount = leftCount + 1
            if type(key) ~= "number" or key < 1 or math.floor(key) ~= key
                or key > #left then
                return false
            end
        end
        for key in pairs(right) do
            rightCount = rightCount + 1
            if type(key) ~= "number" or key < 1 or math.floor(key) ~= key
                or key > #right then
                return false
            end
        end
        if leftCount ~= #left or rightCount ~= #right then return false end
        for i = 1, #left do
            if ServerUtil.requiredInteger(left[i], "manifest template part")
                ~= ServerUtil.requiredInteger(right[i], "current template part") then
                return false
            end
        end
        return true
    end
    local boundKeys = {
        "schemaVersion", "clearMinX", "clearMaxX", "clearMinY",
        "clearMaxY", "clearMinZ", "clearMaxZ", "managedOriginX",
        "managedOriginY", "managedWidth", "managedHeight", "managedMinZ",
        "managedMaxZ", "roomMinX", "roomMaxX", "roomMinY", "roomMaxY",
        "roomZ", "wallMinX", "wallMaxX", "wallMinY", "wallMaxY", "wallZ",
        "wallCoordinates", "wallObjectCount", "wallCoordinateCount",
        "wallEdgeCounts", "wallCornerCount", "northEdges", "westEdges",
        "roofMinX", "roofMaxX", "roofMinY", "roofMaxY", "z", "roofZ",
        "bitmap", "shellEdges",
    }
    if type(bounds) ~= "table" or type(managed) ~= "table"
        or type(bitmap) ~= "table"
        or not onlyKeys(bounds, boundKeys)
        or ServerUtil.requiredInteger(bounds.schemaVersion, "manifest bounds schemaVersion")
            ~= Constants.LAYOUT_SCHEMA_VERSION then
        return false
    end
    local fields = {
        "clearMinX", "clearMaxX", "clearMinY", "clearMaxY",
        "clearMinZ", "clearMaxZ", "managedOriginX", "managedOriginY",
        "managedWidth", "managedHeight", "managedMinZ", "managedMaxZ",
        "roomMinX", "roomMaxX", "roomMinY", "roomMaxY", "roomZ",
        "wallMinX", "wallMaxX", "wallMinY", "wallMaxY", "wallZ",
        "roofMinX", "roofMaxX", "roofMinY", "roofMaxY", "roofZ", "z",
        "wallObjectCount", "wallCoordinateCount", "northEdges", "westEdges",
        "wallCornerCount",
    }
    local values = {}
    for i = 1, #fields do
        local field = fields[i]
        values[field] = ServerUtil.requiredInteger(bounds[field], "manifest bounds " .. field)
    end
    if values.managedWidth ~= Constants.RV_MANAGED_WIDTH
        or values.managedHeight ~= Constants.RV_MANAGED_HEIGHT
        or values.managedOriginX ~= ServerUtil.requiredInteger(managed.originX,
            "manifest managed.originX")
        or values.managedOriginY ~= ServerUtil.requiredInteger(managed.originY,
            "manifest managed.originY")
        or values.managedMinZ ~= ServerUtil.requiredInteger(managed.minZ,
            "manifest managed.minZ")
        or values.managedMaxZ ~= ServerUtil.requiredInteger(managed.maxZ,
            "manifest managed.maxZ")
        or values.clearMinX ~= values.managedOriginX
        or values.clearMaxX ~= values.managedOriginX + values.managedWidth
        or values.clearMinY ~= values.managedOriginY
        or values.clearMaxY ~= values.managedOriginY + values.managedHeight
        or values.clearMinZ ~= values.managedMinZ
        or values.clearMaxZ ~= values.managedMaxZ
        or values.clearMaxX <= values.clearMinX
        or values.clearMaxY <= values.clearMinY
        or values.clearMaxZ <= values.clearMinZ
        or values.roomZ ~= values.z or values.wallZ ~= values.z
        or values.roofZ < values.managedMinZ
        or values.roofZ >= values.managedMaxZ
        or values.wallObjectCount ~= 59
        or values.wallCoordinateCount ~= 59
        or values.northEdges ~= 12 or values.westEdges ~= 47
        or values.wallCornerCount ~= 1 then
        return false
    end
    if type(anchor) ~= "table"
        or RegionSlots.indexForAnchor(anchor) == nil then
        return false
    end
    local expectedLayout = Layout.make(anchor.x, anchor.y, anchor.z)
    if values.roomMinX ~= expectedLayout.room.minX
        or values.roomMaxX ~= expectedLayout.room.maxX
        or values.roomMinY ~= expectedLayout.room.minY
        or values.roomMaxY ~= expectedLayout.room.maxY
        or values.roomZ ~= expectedLayout.room.z
        or values.wallMinX ~= expectedLayout.wall.minX
        or values.wallMaxX ~= expectedLayout.wall.maxX
        or values.wallMinY ~= expectedLayout.wall.minY
        or values.wallMaxY ~= expectedLayout.wall.maxY
        or values.wallZ ~= expectedLayout.wall.z
        or values.roofMinX ~= expectedLayout.roof.minX
        or values.roofMaxX ~= expectedLayout.roof.maxX
        or values.roofMinY ~= expectedLayout.roof.minY
        or values.roofMaxY ~= expectedLayout.roof.maxY
        or values.z ~= expectedLayout.anchor.z
        or values.roofZ ~= expectedLayout.roof.z then
        return false
    end
    -- `bounds.bitmap` is the decoded current-layout snapshot persisted inside
    -- manifest.bounds, while the boundary copy arrives in encoded form and is
    -- decoded by currentManifestValid before this function is called.  Both
    -- are part of the current schema: validating only boundary.bitmap would
    -- allow a stale/corrupt bounds snapshot to steer wall/region consumers.
    if not Bitmap or type(bounds.bitmap) ~= "table"
        or type(Bitmap.validate) ~= "function" then
        return false
    end
    local boundsBitmapOk, boundsBitmapValid = pcall(Bitmap.validate,
        bounds.bitmap)
    if not boundsBitmapOk or boundsBitmapValid ~= true then
        return false
    end
    local bitmapFields = { "schemaVersion", "bitmapVersion", "originX",
        "originY", "width", "height", "minZ", "maxZ", "encoding" }
    for i = 1, #bitmapFields do
        local field = bitmapFields[i]
        if bounds.bitmap[field] ~= bitmap[field] then return false end
    end
    for z = bitmap.minZ, bitmap.maxZ - 1 do
        local boundsLayer, boundaryLayer = Bitmap.layer(bounds.bitmap, z),
            Bitmap.layer(bitmap, z)
        if type(boundsLayer) ~= "table" or type(boundaryLayer) ~= "table"
            or boundsLayer.walkBits ~= boundaryLayer.walkBits
            or boundsLayer.buildBits ~= boundaryLayer.buildBits
            or boundsLayer.encoding ~= boundaryLayer.encoding then
            return false
        end
        local expectedLayer = Bitmap.layer(expectedLayout.bitmap, z)
        if type(expectedLayer) ~= "table"
            or boundsLayer.walkBits ~= expectedLayer.walkBits
            or boundsLayer.buildBits ~= expectedLayer.buildBits then
            return false
        end
    end
    if bitmap.originX ~= values.managedOriginX
        or bitmap.originY ~= values.managedOriginY
        or bitmap.width ~= values.managedWidth
        or bitmap.height ~= values.managedHeight
        or bitmap.minZ ~= values.managedMinZ
        or bitmap.maxZ ~= values.managedMaxZ
        or bounds.bitmap.originX ~= values.managedOriginX
        or bounds.bitmap.originY ~= values.managedOriginY
        or bounds.bitmap.width ~= values.managedWidth
        or bounds.bitmap.height ~= values.managedHeight
        or bounds.bitmap.minZ ~= values.managedMinZ
        or bounds.bitmap.maxZ ~= values.managedMaxZ then
        return false
    end
    if type(bounds.wallCoordinates) ~= "table"
        or #bounds.wallCoordinates ~= values.wallCoordinateCount
        or type(bounds.wallEdgeCounts) ~= "table"
        or not onlyKeys(bounds.wallEdgeCounts, { "north", "west" })
        or ServerUtil.requiredInteger(bounds.wallEdgeCounts.north,
            "manifest bounds wallEdgeCounts.north") ~= values.northEdges
        or ServerUtil.requiredInteger(bounds.wallEdgeCounts.west,
            "manifest bounds wallEdgeCounts.west") ~= values.westEdges
        or type(bounds.shellEdges) ~= "table" then
        return false
    end
    local wallCoordinateKeys = 0
    for key in pairs(bounds.wallCoordinates) do
        if type(key) ~= "number" or not ServerUtil.isFiniteNumber(key)
            or math.floor(key) ~= key or key < 1
            or key > values.wallCoordinateCount then
            return false
        end
        wallCoordinateKeys = wallCoordinateKeys + 1
    end
    if wallCoordinateKeys ~= values.wallCoordinateCount then return false end
    local shellEdgeKeys = 0
    for key in pairs(bounds.shellEdges) do
        if type(key) ~= "string" or key == "" then return false end
        shellEdgeKeys = shellEdgeKeys + 1
    end
    if shellEdgeKeys ~= values.wallCoordinateCount then return false end
    local function inside(minX, maxX, minY, maxY, z)
        return minX <= maxX and minY <= maxY
            and minX >= values.managedOriginX
            and maxX < values.managedOriginX + values.managedWidth
            and minY >= values.managedOriginY
            and maxY < values.managedOriginY + values.managedHeight
            and z >= values.managedMinZ and z < values.managedMaxZ
    end
    if not inside(values.roomMinX, values.roomMaxX, values.roomMinY,
            values.roomMaxY, values.roomZ)
        or not inside(values.wallMinX, values.wallMaxX, values.wallMinY,
            values.wallMaxY, values.wallZ)
        or not inside(values.roofMinX, values.roofMaxX, values.roofMinY,
            values.roofMaxY, values.roofZ) then
        return false
    end
    local wallEntryKeys = {
        "x", "y", "z", "north", "sprite", "role", "corner", "templateIndex",
        "templateIndices",
        "edgeNorth", "edgeWest", "axis", "edgeKey", "edgeSide",
        "edgeCellX", "edgeCellY", "edgeHostX", "edgeHostY",
    }
    local expectedShellKeys = {}
    local shellEntryKeys = {
        "edgeKey", "rvId", "generation", "hostX", "hostY", "z", "axis",
        "side", "objectX", "objectY", "objectZ", "role", "corner",
        "replacementAllowed", "templateIndex", "templateIndices", "sprite", "north",
    }
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        local expectedEntry = expectedLayout.wallCoordinates[i]
        if not onlyKeys(entry, wallEntryKeys)
            or type(expectedEntry) ~= "table"
            or type(entry) ~= "table"
            or type(entry.north) ~= "boolean"
            or type(entry.corner) ~= "boolean"
            or type(entry.edgeNorth) ~= "boolean"
            or type(entry.edgeWest) ~= "boolean"
            or entry.edgeNorth == entry.edgeWest
            or type(entry.edgeKey) ~= "string"
            or entry.edgeKey == ""
            or ServerUtil.requiredInteger(entry.x, "manifest wall coordinate x") == nil
            or ServerUtil.requiredInteger(entry.y, "manifest wall coordinate y") == nil
            or ServerUtil.requiredInteger(entry.z, "manifest wall coordinate z") == nil
            or ServerUtil.requiredInteger(entry.templateIndex,
                "manifest wall coordinate templateIndex") == nil
            or not sameTemplateIndices(entry.templateIndices,
                expectedEntry.templateIndices)
            or ServerUtil.requiredInteger(entry.edgeCellX,
                "manifest wall coordinate edgeCellX") == nil
            or ServerUtil.requiredInteger(entry.edgeCellY,
                "manifest wall coordinate edgeCellY") == nil
            or ServerUtil.requiredInteger(entry.edgeHostX,
                "manifest wall coordinate edgeHostX") == nil
            or ServerUtil.requiredInteger(entry.edgeHostY,
                "manifest wall coordinate edgeHostY") == nil
            or type(entry.sprite) ~= "string"
            or type(entry.role) ~= "string"
            or type(entry.axis) ~= "string"
            or (entry.axis ~= "N" and entry.axis ~= "W")
            or type(entry.edgeSide) ~= "string"
            or not Bitmap.containsScope(bitmap, entry.x, entry.y, entry.z) then
            return false
        end
        local expectedAxis = entry.north and "N" or "W"
        local expectedSide, expectedCellX, expectedCellY
        if entry.north then
            expectedSide = entry.y == values.wallMaxY and "south" or "north"
            expectedCellX = entry.x
            expectedCellY = entry.y - (expectedSide == "south" and 1 or 0)
        else
            expectedSide = entry.x == values.wallMaxX and "east" or "west"
            expectedCellX = entry.x - (expectedSide == "east" and 1 or 0)
            expectedCellY = entry.y
        end
        local expectedEdgeKey = Bitmap.edgeForSide and Bitmap.edgeForSide(
            expectedSide, expectedCellX, expectedCellY, entry.z) or nil
        if entry.axis ~= expectedAxis
            or entry.edgeNorth ~= (expectedAxis == "N")
            or entry.edgeWest ~= (expectedAxis == "W")
            or entry.edgeSide ~= expectedSide
            or ServerUtil.requiredInteger(entry.edgeCellX,
                "manifest wall coordinate edgeCellX") ~= expectedCellX
            or ServerUtil.requiredInteger(entry.edgeCellY,
                "manifest wall coordinate edgeCellY") ~= expectedCellY
            or ServerUtil.requiredInteger(entry.edgeHostX,
                "manifest wall coordinate edgeHostX") ~= entry.x
            or ServerUtil.requiredInteger(entry.edgeHostY,
                "manifest wall coordinate edgeHostY") ~= entry.y
            or entry.edgeKey ~= expectedEdgeKey
            or entry.x ~= expectedEntry.x or entry.y ~= expectedEntry.y
            or entry.z ~= expectedEntry.z or entry.north ~= expectedEntry.north
            or entry.role ~= expectedEntry.role or entry.sprite ~= expectedEntry.sprite
            or entry.corner ~= expectedEntry.corner
            or entry.templateIndex ~= expectedEntry.templateIndex then
            return false
        end
        expectedShellKeys[entry.edgeKey] = true
    end
    for key, edge in pairs(bounds.shellEdges) do
        if not expectedShellKeys[key]
            or type(edge) ~= "table"
            or not onlyKeys(edge, shellEntryKeys)
            or edge.edgeKey ~= key
            or edge.rvId ~= nil
            or edge.generation ~= nil
            or ServerUtil.requiredInteger(edge.hostX, "manifest shell edge hostX") == nil
            or ServerUtil.requiredInteger(edge.hostY, "manifest shell edge hostY") == nil
            or ServerUtil.requiredInteger(edge.z, "manifest shell edge z") == nil
            or ServerUtil.requiredInteger(edge.objectX, "manifest shell edge objectX") == nil
            or ServerUtil.requiredInteger(edge.objectY, "manifest shell edge objectY") == nil
            or ServerUtil.requiredInteger(edge.objectZ, "manifest shell edge objectZ") == nil
            or type(edge.axis) ~= "string"
            or type(edge.side) ~= "string"
            or type(edge.role) ~= "string"
            or type(edge.corner) ~= "boolean"
            or edge.replacementAllowed ~= true then
            return false
        end
        local wallEntry
        for i = 1, #bounds.wallCoordinates do
            if bounds.wallCoordinates[i].edgeKey == key then
                wallEntry = bounds.wallCoordinates[i]
                break
            end
        end
        if not wallEntry
            or edge.axis ~= wallEntry.axis
            or edge.side ~= wallEntry.edgeSide
            or edge.hostX ~= wallEntry.edgeHostX
            or edge.hostY ~= wallEntry.edgeHostY
            or edge.z ~= wallEntry.z
            or edge.objectX ~= wallEntry.x
            or edge.objectY ~= wallEntry.y
            or edge.objectZ ~= wallEntry.z
            or edge.role ~= wallEntry.role
            or edge.corner ~= wallEntry.corner
            or ServerUtil.requiredInteger(edge.templateIndex,
                "manifest shell edge templateIndex") ~= wallEntry.templateIndex
            or not sameTemplateIndices(edge.templateIndices,
                wallEntry.templateIndices)
            or edge.sprite ~= wallEntry.sprite or edge.north ~= wallEntry.north then
            return false
        end
    end
    for key in pairs(expectedShellKeys) do
        if bounds.shellEdges[key] == nil then return false end
    end
    return true
end

local function currentManifestValid(manifest, allowEmpty)
    if type(manifest) ~= "table" then return false end
    local hasField = false
    for _ in pairs(manifest) do
        hasField = true
        break
    end
    if not hasField then return allowEmpty == true end
    local manifestKeys = {
        schemaVersion = true, techVersion = true, templateVersion = true,
        generation = true,
        owner = true, slotIndex = true, anchor = true, bounds = true, rvId = true,
        boundarySchemaVersion = true, bitmapVersion = true, boundary = true,
        startedAt = true, rollback = true, state = true, updatedAt = true,
        phase = true, phaseGeneration = true, phaseUpdatedAt = true,
        completedAt = true, lastError = true,
    }
    for key in pairs(manifest) do
        if not manifestKeys[key] then return false end
    end
    local anchorFields = { x = true, y = true, z = true }
    if type(manifest.anchor) == "table" then
        for key in pairs(manifest.anchor) do
            if not anchorFields[key] then return false end
        end
    end
    if ServerUtil.requiredInteger(manifest.schemaVersion, "manifest schemaVersion")
        ~= Constants.MANIFEST_SCHEMA_VERSION
        or manifest.techVersion ~= Constants.TECH_VERSION
        or ServerUtil.requiredInteger(manifest.templateVersion,
            "manifest templateVersion") ~= Constants.CAPTURED_TEMPLATE_VERSION
        or manifest.owner ~= OWNER
        or type(manifest.state) ~= "string"
        or (manifest.state ~= "RUNNING" and manifest.state ~= "READY"
            and manifest.state ~= "FAILED")
        or ServerUtil.requiredInteger(manifest.generation, "manifest generation") < 1
        or type(manifest.rvId) ~= "string" or manifest.rvId == ""
        or ServerUtil.requiredInteger(manifest.bitmapVersion, "manifest bitmapVersion")
            ~= Constants.BITMAP_VERSION
        or ServerUtil.requiredInteger(manifest.boundarySchemaVersion,
            "manifest boundarySchemaVersion") ~= Constants.BOUNDARY_SCHEMA_VERSION
        or ServerUtil.requiredInteger(manifest.slotIndex, "manifest slotIndex") == nil
        or ServerUtil.requiredInteger(manifest.slotIndex, "manifest slotIndex") < 1
        or ServerUtil.requiredInteger(manifest.slotIndex, "manifest slotIndex")
            > RegionSlots.COUNT
        or RegionSlots.indexForAnchor(manifest.anchor)
            ~= ServerUtil.requiredInteger(manifest.slotIndex, "manifest slotIndex")
        or type(manifest.anchor) ~= "table"
        or ServerUtil.requiredInteger(manifest.anchor.x, "manifest anchor.x") == nil
        or ServerUtil.requiredInteger(manifest.anchor.y, "manifest anchor.y") == nil
        or ServerUtil.requiredInteger(manifest.anchor.z, "manifest anchor.z") == nil
        or type(manifest.bounds) ~= "table"
        or type(manifest.boundary) ~= "table"
        or ServerUtil.requiredInteger(manifest.boundary.schemaVersion,
            "manifest boundary schemaVersion") ~= Constants.BOUNDARY_SCHEMA_VERSION
        or tostring(manifest.boundary.rvId) ~= tostring(manifest.rvId)
        or ServerUtil.requiredInteger(manifest.boundary.generation,
            "manifest boundary generation") ~= ServerUtil.requiredInteger(manifest.generation,
            "manifest generation")
        or ServerUtil.requiredInteger(manifest.boundary.bitmapVersion,
            "manifest boundary bitmapVersion") ~= ServerUtil.requiredInteger(manifest.bitmapVersion,
            "manifest bitmapVersion")
        or type(manifest.boundary.managed) ~= "table"
        or type(manifest.boundary.bitmap) ~= "table"
        or type(manifest.boundary.shellEdges) ~= "table" then
        return false
    end
    local boundaryBitmap = validateBoundarySchema(manifest.boundary)
    if type(boundaryBitmap) ~= "table"
        or not currentBoundsValid(manifest.bounds,
            manifest.boundary.managed, boundaryBitmap, manifest.anchor) then
        return false
    end
    local startedAt = ServerUtil.requiredInteger(manifest.startedAt, "manifest startedAt")
    local updatedAt = ServerUtil.requiredInteger(manifest.updatedAt, "manifest updatedAt")
    local phaseGeneration = ServerUtil.requiredInteger(manifest.phaseGeneration,
        "manifest phaseGeneration")
    local phaseUpdatedAt = ServerUtil.requiredInteger(manifest.phaseUpdatedAt,
        "manifest phaseUpdatedAt")
    local generation = ServerUtil.requiredInteger(manifest.generation, "manifest generation")
    if type(manifest.phase) ~= "string"
        or (manifest.phase ~= "RUNNING"
            and manifest.phase ~= "CLEARING"
            and manifest.phase ~= "CAPTURED_TEMPLATE"
            and manifest.phase ~= "STRUCTURE_RECALC"
            and manifest.phase ~= "GENERATOR"
            and manifest.phase ~= "FINAL_RELOCATE"
            and manifest.phase ~= "COMMITTED"
            and manifest.phase ~= "ROLLED_BACK"
            and manifest.phase ~= "FAILED")
        or startedAt < 1 or updatedAt < startedAt
        or phaseGeneration ~= generation or phaseUpdatedAt < startedAt
        or manifest.rollback ~= nil
            and manifest.rollback ~= "COMPLETE"
            and manifest.rollback ~= "FAILED"
        or manifest.lastError ~= nil and type(manifest.lastError) ~= "string"
        or manifest.completedAt ~= nil
            and ServerUtil.requiredInteger(manifest.completedAt, "manifest completedAt") < 1
        or (manifest.state == "READY"
            and (manifest.phase ~= "COMMITTED"
                or ServerUtil.requiredInteger(manifest.completedAt,
                    "manifest completedAt") == nil)) then
        return false
    end
    local bitmap = boundaryBitmap
    if bitmap.bitmapVersion ~= Constants.BITMAP_VERSION
        or bitmap.originX ~= manifest.boundary.managed.originX
        or bitmap.originY ~= manifest.boundary.managed.originY
        or bitmap.width ~= manifest.boundary.managed.width
        or bitmap.height ~= manifest.boundary.managed.height
        or bitmap.minZ ~= manifest.boundary.managed.minZ
            or bitmap.maxZ ~= manifest.boundary.managed.maxZ then
        return false
    end
    if not Boundary or type(Boundary.registerGeneration) ~= "function" then
        return false
    end
    local boundaryOk, registered = pcall(Boundary.registerGeneration,
        manifest.rvId, manifest.generation, manifest.boundary, nil)
    if not boundaryOk or registered ~= true then return false end
    return true
end

local function validateManifestAtStartup()
    if type(manifestDependencies) ~= "table" or not ModData
        or type(ModData.get) ~= "function" then
        return false, "manifest ModData or schema dependencies are unavailable"
    end
    local ok, manifest = pcall(ModData.get, Constants.MANIFEST_KEY)
    if not ok then return false, "manifest ModData read failed" end
    if manifest == nil then
        validatedManifestRoot = nil
        return true
    end
    if type(manifest) ~= "table" then return false, "manifest root is not a table" end
    if next(manifest) == nil then
        validatedManifestRoot = manifest
        return true
    end
    local valid = currentManifestValid(manifest, false)
    if valid then validatedManifestRoot = manifest end
    return valid, "manifest does not match the current schema"
end
do
local C = require("RailroaderRV/Common/RV_Constants")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local PowerConfig = require("RailroaderRV/Power/RV_UtilityPowerConfig")local function integer(value)
    return type(value) == "number" and math.floor(value) == value and value or nil
end

local function number(value)
    return type(value) == "number" and value or nil
end

local function exactKeys(value, keys)
    if type(value) ~= "table" then return false end
    local allowed = {}
    for _, key in ipairs(keys) do allowed[key] = true end
    for key in pairs(value) do if not allowed[key] then return false end end
    for _, key in ipairs(keys) do if value[key] == nil then return false end end
    return true
end

local function exactKeysWithOptional(value, allowedKeys, requiredKeys)
    if type(value) ~= "table" then return false end
    local allowed = {}
    for _, key in ipairs(allowedKeys) do allowed[key] = true end
    for key in pairs(value) do if not allowed[key] then return false end end
    for _, key in ipairs(requiredKeys) do if value[key] == nil then return false end end
    return true
end

local function empty(value)
    if type(value) ~= "table" then return false end
    for _ in pairs(value) do return false end
    return true
end

-- ModData returns the live persistence table.  Records therefore never leave
-- this module by reference: every caller receives a working copy and commit
-- stores another copy.  This keeps mutations made while a world operation is
-- pending out of the autosave root until the transmit boundary succeeds.
local function copyTable(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, nested in pairs(value) do result[key] = copyTable(nested) end
    return result
end

local function finite(value)
    value = number(value)
    return value ~= nil and value == value and value < math.huge and value > -math.huge
end

local function validPlainData(value, depth, seen)
    if type(value) ~= "table" then
        if type(value) == "number" then
            return finite(value)
        end
        return type(value) == "string" or type(value) == "boolean"
    end
    if depth > 6 or seen[value] then return false end
    seen[value] = true
    for key, nested in pairs(value) do
        if (type(key) ~= "string" and type(key) ~= "number")
            or not validPlainData(nested, depth + 1, seen) then
            seen[value] = nil
            return false
        end
    end
    seen[value] = nil
    return true
end

local function identityValid(identity)
    return type(identity) == "table" and type(identity.rvId) == "string"
        and identity.rvId ~= "" and integer(identity.generation) ~= nil
        and integer(identity.generation) >= 1
        and integer(identity.bitmapVersion) == C.BITMAP_VERSION
end

local function identityMatches(value, identity)
    return identityValid(identity) and type(value) == "table"
        and tostring(value.rvId) == tostring(identity.rvId)
        and integer(value.generation) == integer(identity.generation)
        and integer(value.bitmapVersion) == integer(identity.bitmapVersion)
end

local WATER_SINK_FIELDS = { "rvId", "generation", "bitmapVersion", "slotIndex",
    "anchor", "x", "y", "z", "connected", "sequence" }

local function waterInteger(value)
    return type(value) == "number" and value == value
        and value < math.huge and value > -math.huge
        and math.floor(value) == value and value or nil
end

local function waterSinkKey(x, y, z)
    x, y, z = waterInteger(x), waterInteger(y), waterInteger(z)
    if not x or not y or not z then return nil end
    return string.format("%d:%d:%d", x, y, z)
end

local function validWaterAnchor(anchor, slotIndex)
    if not exactKeys(anchor, { "x", "y", "z" })
        or waterInteger(anchor.x) == nil or waterInteger(anchor.y) == nil
        or waterInteger(anchor.z) == nil then return false end
    local expected = RegionSlots.indexToAnchor(slotIndex)
    return expected ~= nil and anchor.x == expected.x
        and anchor.y == expected.y and anchor.z == expected.z
end

local function validWaterSink(value, identity)
    if not exactKeys(value, WATER_SINK_FIELDS)
        or type(value.rvId) ~= "string" or value.rvId ~= tostring(identity.rvId)
        or waterInteger(value.generation) ~= identity.generation
        or waterInteger(value.bitmapVersion) ~= identity.bitmapVersion
        or waterInteger(value.slotIndex) == nil
        or not validWaterAnchor(value.anchor, value.slotIndex)
        or waterInteger(value.x) == nil or waterInteger(value.y) == nil
        or waterInteger(value.z) == nil or type(value.connected) ~= "boolean"
        or waterInteger(value.sequence) == nil or value.sequence < 0 then
        return false
    end
    local region = RegionSlots.indexToRegion(value.slotIndex)
    local minZ = value.anchor.z + C.RV_MANAGED_MIN_Z_OFFSET
    local maxZ = value.anchor.z + C.RV_MANAGED_MAX_Z_OFFSET
    return region ~= nil and value.x >= region.minX and value.x < region.maxX
        and value.y >= region.minY and value.y < region.maxY
        and value.z >= minZ and value.z < maxZ
end

local function validWater(value, identity)
    if not exactKeys(value, { "schemaVersion", "sinks", "state" })
        or waterInteger(value.schemaVersion) ~= U.WATER_SCHEMA_VERSION
        or type(value.sinks) ~= "table"
        or (value.state ~= U.WATER_STATE_ACTIVE
            and value.state ~= U.WATER_STATE_NEEDS_RECONCILE) then
        return false
    end
    for key, sink in pairs(value.sinks) do
        if type(key) ~= "string" or not validWaterSink(sink, identity)
            or waterSinkKey(sink.x, sink.y, sink.z) ~= key then
            return false
        end
    end
    return true
end

local function validGenerator(value, identity)
    if value == nil then return true end
    local keys = { "rvId", "generation", "bitmapVersion", "x", "y", "z",
        "objectToken", "objectFingerprint" }
    return exactKeys(value, keys) and identityMatches(value, identity)
        and integer(value.x) ~= nil and integer(value.y) ~= nil and integer(value.z) ~= nil
        and type(value.objectToken) == "string" and value.objectToken ~= ""
        and type(value.objectFingerprint) == "string" and value.objectFingerprint ~= ""
end

local BATTERY_TYPES = {
    ["Base.CarBattery"] = true,
    ["Base.CarBattery1"] = true,
    ["Base.CarBattery2"] = true,
    ["Base.CarBattery3"] = true,
}

local function validBattery(value)
    local keys = { "id", "fullType", "condition", "maxCondition", "usedDelta", "modData" }
    return exactKeys(value, keys) and integer(value.id) ~= nil and value.id >= 1
        and BATTERY_TYPES[value.fullType] == true
        and integer(value.condition) ~= nil and integer(value.maxCondition) ~= nil
        and value.maxCondition > 0 and value.condition >= 0
        and value.condition <= value.maxCondition and finite(value.usedDelta)
        and value.usedDelta >= 0 and value.usedDelta <= 1
        and type(value.modData) == "table" and validPlainData(value.modData, 1, {})
end

local function validComponent(value, fullType)
    if value == nil then return true end
    local keys = { "fullType", "condition", "conditionMax", "modData" }
    return exactKeys(value, keys) and value.fullType == fullType
        and integer(value.condition) ~= nil
        and integer(value.conditionMax) == PowerConfig.COMPONENT_CONDITION_MAX
        and value.condition > 0 and value.condition <= value.conditionMax
        and type(value.modData) == "table" and validPlainData(value.modData, 1, {})
end

local function validPower(value, identity)
    local keys = { "schemaVersion", "generator", "circuitState", "generatorEnabled",
        "virtualFuelL", "batteryWh", "batteryCapacityWh", "maxChargePowerW",
        "maxDischargePowerW", "generationPowerW", "currentLoadW", "chargerEfficiency",
        "inverterEfficiency", "batteries", "nextBatteryId", "charger", "inverter",
        "lastUpdateTime", "lastSettlementTime", "sequence", "state" }
    if not exactKeysWithOptional(value, keys,
        { "schemaVersion", "circuitState", "generatorEnabled", "virtualFuelL",
            "batteryWh", "batteryCapacityWh", "maxChargePowerW", "maxDischargePowerW",
            "generationPowerW", "currentLoadW", "chargerEfficiency", "inverterEfficiency",
            "batteries", "nextBatteryId", "lastUpdateTime", "lastSettlementTime",
            "sequence", "state" })
        or integer(value.schemaVersion) ~= U.POWER_SCHEMA_VERSION
        or not validGenerator(value.generator, identity)
        or (value.circuitState ~= U.CIRCUIT_OFF and value.circuitState ~= U.CIRCUIT_ON)
        or type(value.generatorEnabled) ~= "boolean"
        or not finite(value.virtualFuelL) or value.virtualFuelL < 0
        or value.virtualFuelL > PowerConfig.VIRTUAL_FUEL_CAPACITY_L
        or not finite(value.batteryWh) or value.batteryWh < 0
        or not finite(value.batteryCapacityWh) or value.batteryCapacityWh < 0
        or not finite(value.maxChargePowerW) or value.maxChargePowerW < 0
        or not finite(value.maxDischargePowerW) or value.maxDischargePowerW < 0
        or not finite(value.generationPowerW) or value.generationPowerW < 0
        or value.generationPowerW > PowerConfig.GAS_GENERATOR_POWER_W
        or not finite(value.currentLoadW) or value.currentLoadW < 0
        or not finite(value.chargerEfficiency) or value.chargerEfficiency <= 0
        or value.chargerEfficiency > 1
        or not finite(value.inverterEfficiency) or value.inverterEfficiency <= 0
        or value.inverterEfficiency > 1
        or type(value.batteries) ~= "table" or integer(value.nextBatteryId) == nil
        or value.nextBatteryId < 1 or not validComponent(value.charger,
            "RailroaderRVTest.RVCharger")
        or not validComponent(value.inverter, "RailroaderRVTest.RVInverter")
        or not finite(value.lastUpdateTime) or value.lastUpdateTime < 0
        or not finite(value.lastSettlementTime) or value.lastSettlementTime < 0
        or integer(value.sequence) == nil
        or value.sequence < 0 or (value.state ~= U.POWER_STATE_READY
            and value.state ~= U.POWER_STATE_DEGRADED) then return false end
    local count, capacity, chargePower, dischargePower, largestId = 0, 0, 0, 0, 0
    for key, battery in pairs(value.batteries) do
        if integer(key) == nil or key < 1 or not validBattery(battery) then return false end
        local parameters = PowerConfig.batteryParameters(battery.condition,
            battery.maxCondition)
        if not parameters then return false end
        count = count + 1
        capacity = capacity + parameters.capacityWh
        chargePower = chargePower + parameters.maxChargePowerW
        dischargePower = dischargePower + parameters.maxDischargePowerW
        largestId = math.max(largestId, battery.id)
    end
    if count ~= #value.batteries or value.nextBatteryId <= largestId
        or math.abs(value.batteryCapacityWh - capacity) > PowerConfig.PERSISTED_POWER_TOLERANCE
        or math.abs(value.maxChargePowerW - chargePower) > PowerConfig.PERSISTED_POWER_TOLERANCE
        or math.abs(value.maxDischargePowerW - dischargePower) > PowerConfig.PERSISTED_POWER_TOLERANCE
        or value.batteryWh > value.batteryCapacityWh + PowerConfig.PERSISTED_POWER_TOLERANCE then return false end
    local expectedCharger = value.charger
        and value.charger.condition / value.charger.conditionMax
        or PowerConfig.DEFAULT_CHARGER_EFFICIENCY
    local expectedInverter = value.inverter
        and value.inverter.condition / value.inverter.conditionMax
        or PowerConfig.DEFAULT_INVERTER_EFFICIENCY
    return math.abs(value.chargerEfficiency - expectedCharger) <= PowerConfig.NUMERIC_EPSILON
        and math.abs(value.inverterEfficiency - expectedInverter) <= PowerConfig.NUMERIC_EPSILON
end

local function validRecord(value, identity)
    return exactKeys(value, { "rvId", "generation", "bitmapVersion", "power", "water" })
        and identityMatches(value, identity)
        and validPower(value.power, identity)
        and validWater(value.water, identity)
end

local function validateUtilityRoot(value)
    if value == nil then return true end
    if type(value) ~= "table" then return false end
    if next(value) == nil then return true end
    if not exactKeys(value, { "schemaVersion", "records" })
        or integer(value.schemaVersion) ~= U.STORE_SCHEMA_VERSION
        or type(value.records) ~= "table" then
        return false
    end
    for id, record in pairs(value.records) do
        if type(id) ~= "string" or type(record) ~= "table"
            or tostring(record.rvId) ~= id then
            return false
        end
        local identity = { rvId = record.rvId, generation = record.generation,
            bitmapVersion = record.bitmapVersion }
        if type(record.power) ~= "table" or record.power.generator == nil
            or not validRecord(record, identity) then return false end
    end
    return true
end

validateUtilityAtStartup = function()
    if not ModData or type(ModData.get) ~= "function" then
        return false, "utility ModData is unavailable"
    end
    local ok, value = pcall(ModData.get, U.STORE_KEY)
    if not ok then return false, "utility ModData read failed" end
    return validateUtilityRoot(value), "utility ledger does not match the current schema"
end
end
local function manifestViewForRecord(record)
    if type(record) ~= "table" or type(record.anchor) ~= "table"
        or type(record.boundary) ~= "table" or type(ServerSchema) ~= "table"
        or type(ServerSchema.boundsFor) ~= "function" then
        return nil
    end
    local anchor = { x = ServerUtil.integer(record.anchor.x),
        y = ServerUtil.integer(record.anchor.y), z = ServerUtil.integer(record.anchor.z) }
    local updatedAt = ServerUtil.integer(record.updatedAt)
    local generation = ServerUtil.integer(record.generation)
    local bitmapVersion = ServerUtil.integer(record.bitmapVersion)
    if anchor.x == nil or anchor.y == nil or anchor.z == nil
        or updatedAt == nil or generation == nil or bitmapVersion == nil then
        return nil
    end
    local layout = Layout.make(anchor.x, anchor.y, anchor.z)
    local bounds = ServerSchema.boundsFor(layout)
    return {
        schemaVersion = Constants.MANIFEST_SCHEMA_VERSION,
        techVersion = Constants.TECH_VERSION,
        templateVersion = Constants.CAPTURED_TEMPLATE_VERSION,
        generation = generation,
        owner = OWNER,
        slotIndex = ServerUtil.integer(record.slotIndex),
        anchor = anchor,
        bounds = bounds,
        rvId = tostring(record.rvId),
        boundarySchemaVersion = Constants.BOUNDARY_SCHEMA_VERSION,
        bitmapVersion = bitmapVersion,
        boundary = record.boundary,
        startedAt = updatedAt,
        state = "READY",
        updatedAt = updatedAt,
        phase = "COMMITTED",
        phaseGeneration = generation,
        phaseUpdatedAt = updatedAt,
        completedAt = updatedAt,
    }
end
local function validateCurrentRVRecordGeometrySchema(record, manifest)
    local function exactKeys(value, fields)
        if type(value) ~= "table" then return false end
        local allowed = {}
        for i = 1, #fields do allowed[fields[i]] = true end
        for key in pairs(value) do
            if not allowed[key] then return false end
        end
        for i = 1, #fields do
            if value[fields[i]] == nil then return false end
        end
        return true
    end

    local function integerFieldsEqual(left, right, fields)
        if not exactKeys(left, fields) or not exactKeys(right, fields) then
            return false
        end
        for i = 1, #fields do
            if ServerUtil.integer(left[fields[i]]) ~= ServerUtil.integer(right[fields[i]]) then
                return false
            end
        end
        return true
    end

    local function integerFieldsMatch(left, right, fields)
        if type(left) ~= "table" or type(right) ~= "table" then return false end
        for i = 1, #fields do
            if ServerUtil.integer(left[fields[i]]) ~= ServerUtil.integer(right[fields[i]]) then
                return false
            end
        end
        return true
    end

    local managedFields = { "originX", "originY", "width", "height",
        "minZ", "maxZ" }
    local boundaryFields = { "schemaVersion", "rvId", "generation",
        "bitmapVersion", "managed", "bitmap", "shellEdges" }
    local shellFields = { "edgeKey", "rvId", "generation", "bitmapVersion",
        "hostX", "hostY", "z", "axis", "side", "objectX", "objectY",
        "objectZ", "role", "corner", "replacementAllowed",
        "templateIndex", "templateIndices", "sprite", "north" }
    local boundsShellFields = { "edgeKey", "hostX", "hostY", "z", "axis",
        "side", "objectX", "objectY", "objectZ", "role", "corner",
        "replacementAllowed", "templateIndex", "templateIndices", "sprite", "north" }
    local regionFields = { "minX", "minY", "maxX", "maxY", "minZ", "maxZ" }

    if type(record) ~= "table" or type(manifest) ~= "table"
        or record.generated ~= true
        or type(record.boundary) ~= "table"
        or type(manifest.boundary) ~= "table"
        or type(manifest.bounds) ~= "table"
        or type(manifest.anchor) ~= "table"
        or ServerUtil.integer(record.slotIndex) ~= ServerUtil.integer(manifest.slotIndex)
        or ServerUtil.integer(record.anchor and record.anchor.x)
            ~= ServerUtil.integer(manifest.anchor.x)
        or ServerUtil.integer(record.anchor and record.anchor.y)
            ~= ServerUtil.integer(manifest.anchor.y)
        or ServerUtil.integer(record.anchor and record.anchor.z)
            ~= ServerUtil.integer(manifest.anchor.z) then
        return false
    end
    local recordGeneration, manifestGeneration = ServerUtil.integer(record.generation),
        ServerUtil.integer(manifest.generation)
    local recordBitmapVersion, manifestBitmapVersion = ServerUtil.integer(record.bitmapVersion),
        ServerUtil.integer(manifest.bitmapVersion)
    if type(record.rvId) ~= "string" or record.rvId == ""
        or tostring(record.locoId) ~= record.rvId
        or tostring(manifest.rvId) ~= record.rvId
        or recordGeneration == nil or recordGeneration < 1
        or recordGeneration ~= manifestGeneration
        or recordBitmapVersion ~= Constants.BITMAP_VERSION
        or manifestBitmapVersion ~= recordBitmapVersion
        or ServerUtil.integer(record.schemaVersion) ~= Constants.RV_RECORD_SCHEMA_VERSION
        or ServerUtil.integer(record.boundarySchemaVersion) ~= Constants.BOUNDARY_SCHEMA_VERSION
        or ServerUtil.integer(manifest.schemaVersion) ~= Constants.MANIFEST_SCHEMA_VERSION
        or manifest.techVersion ~= Constants.TECH_VERSION
        or ServerUtil.integer(manifest.templateVersion)
            ~= Constants.CAPTURED_TEMPLATE_VERSION
        or ServerUtil.integer(manifest.boundarySchemaVersion)
            ~= Constants.BOUNDARY_SCHEMA_VERSION
        or ServerUtil.integer(record.boundary.schemaVersion)
            ~= Constants.BOUNDARY_SCHEMA_VERSION
        or ServerUtil.integer(manifest.boundary.schemaVersion)
            ~= Constants.BOUNDARY_SCHEMA_VERSION
        or tostring(record.boundary.rvId) ~= record.rvId
        or tostring(manifest.boundary.rvId) ~= record.rvId
        or ServerUtil.integer(record.boundary.generation) ~= recordGeneration
        or ServerUtil.integer(manifest.boundary.generation) ~= recordGeneration
        or ServerUtil.integer(record.boundary.bitmapVersion) ~= recordBitmapVersion
        or ServerUtil.integer(manifest.boundary.bitmapVersion) ~= recordBitmapVersion
        or not exactKeys(record.boundary, boundaryFields)
        or not exactKeys(manifest.boundary, boundaryFields) then
        return false
    end

    local decoded = {}
    local function decodeCurrent(encoded)
        return validateBoundarySchema(encoded)
    end
    decoded.record = decodeCurrent(record.boundary)
    decoded.manifest = decodeCurrent(manifest.boundary)
    if not decoded.record or not decoded.manifest then return false end

    local function bitmapsEqual(left, right)
        if not integerFieldsMatch(left, right, managedFields)
            or ServerUtil.integer(left.bitmapVersion) ~= ServerUtil.integer(right.bitmapVersion) then
            return false
        end
        for z = left.minZ, left.maxZ - 1 do
            local leftLayer, rightLayer = Bitmap.layer(left, z),
                Bitmap.layer(right, z)
            if type(leftLayer) ~= "table" or type(rightLayer) ~= "table"
                or leftLayer.walkBits ~= rightLayer.walkBits
                or leftLayer.buildBits ~= rightLayer.buildBits then
                return false
            end
        end
        return true
    end
    local bitmapCompareOk, bitmapSame = pcall(bitmapsEqual, decoded.record,
        decoded.manifest)
    if not bitmapCompareOk or bitmapSame ~= true
        or not integerFieldsEqual(record.boundary.managed,
            manifest.boundary.managed, managedFields)
        or not integerFieldsEqual(record.managed, record.boundary.managed,
            managedFields) then
        return false
    end
    if not integerFieldsMatch(decoded.record, record.boundary.managed,
            managedFields)
        or not integerFieldsMatch(decoded.manifest, manifest.boundary.managed,
            managedFields) then
        return false
    end

    local function integerArraysEqual(left, right)
        if type(left) ~= "table" or type(right) ~= "table"
            or #left < 1 or #left ~= #right then
            return false
        end
        local leftCount, rightCount = 0, 0
        for key in pairs(left) do
            leftCount = leftCount + 1
            if type(key) ~= "number" or key < 1 or math.floor(key) ~= key
                or key > #left or ServerUtil.integer(left[key]) == nil then
                return false
            end
        end
        for key in pairs(right) do
            rightCount = rightCount + 1
            if type(key) ~= "number" or key < 1 or math.floor(key) ~= key
                or key > #right or ServerUtil.integer(right[key]) == nil then
                return false
            end
        end
        if leftCount ~= #left or rightCount ~= #right then return false end
        for i = 1, #left do
            if ServerUtil.integer(left[i]) ~= ServerUtil.integer(right[i]) then
                return false
            end
        end
        return true
    end

    local function shellSetEqual(left, right)
        if type(left) ~= "table" or type(right) ~= "table" then return false end
        local leftCount, rightCount = 0, 0
        for key, edge in pairs(left) do
            leftCount = leftCount + 1
            local other = right[key]
            if type(key) ~= "string" or type(edge) ~= "table"
                or type(other) ~= "table"
                or not exactKeys(edge, shellFields)
                or not exactKeys(other, shellFields) then
                return false
            end
            for i = 1, #shellFields do
                local field = shellFields[i]
                if field ~= "templateIndices" and edge[field] ~= other[field] then
                    return false
                end
            end
            if not integerArraysEqual(edge.templateIndices, other.templateIndices) then
                return false
            end
        end
        for _ in pairs(right) do rightCount = rightCount + 1 end
        return leftCount == rightCount
    end
    if not shellSetEqual(record.boundary.shellEdges,
            manifest.boundary.shellEdges) then
        return false
    end

    -- The persisted root is already accepted by validateManifestAtStartup.
    -- Synthetic views are checked by the one-time cross-object scan.
    if manifest ~= validatedManifestRoot then
        local manifestValidOk, manifestValid = pcall(currentManifestValid,
            manifest, false)
        if not manifestValidOk or manifestValid ~= true then return false end
    end
    -- currentManifestValid also gates this snapshot for normal callers, but
    -- keep the cross-object contract explicit here: bounds.bitmap is a
    -- decoded current-layout bitmap and must be byte/bit identical to the
    -- encoded boundary bitmap and the record copy before any consumer uses
    -- the center, region, or shell geometry.
    local boundsBitmap = manifest.bounds and manifest.bounds.bitmap
    if type(boundsBitmap) ~= "table"
        or not bitmapsEqual(boundsBitmap, decoded.manifest) then
        return false
    end
    local bounds = manifest.bounds
    local boundsShell = bounds.shellEdges
    for key, edge in pairs(record.boundary.shellEdges) do
        local boundEdge = type(boundsShell) == "table" and boundsShell[key]
            or nil
        if type(boundEdge) ~= "table"
            or not exactKeys(boundEdge, boundsShellFields) then
            return false
        end
        for i = 1, #boundsShellFields do
            local field = boundsShellFields[i]
            if field ~= "templateIndices" and edge[field] ~= boundEdge[field] then
                return false
            end
        end
        if not integerArraysEqual(edge.templateIndices, boundEdge.templateIndices) then
            return false
        end
    end
    local boundaryCount, boundsCount = 0, 0
    for _ in pairs(record.boundary.shellEdges) do boundaryCount = boundaryCount + 1 end
    for _ in pairs(boundsShell or {}) do boundsCount = boundsCount + 1 end
    if boundaryCount ~= boundsCount then return false end

    local anchor = manifest.anchor
    if not exactKeys(anchor, { "x", "y", "z" })
        or ServerUtil.integer(anchor.x) == nil or ServerUtil.integer(anchor.y) == nil
        or ServerUtil.integer(anchor.z) == nil then
        return false
    end
    local anchorX, anchorY, anchorZ = ServerUtil.integer(anchor.x), ServerUtil.integer(anchor.y),
        ServerUtil.integer(anchor.z)
    local boundsManaged = {
        originX = ServerUtil.integer(bounds.managedOriginX),
        originY = ServerUtil.integer(bounds.managedOriginY),
        width = ServerUtil.integer(bounds.managedWidth),
        height = ServerUtil.integer(bounds.managedHeight),
        minZ = ServerUtil.integer(bounds.managedMinZ),
        maxZ = ServerUtil.integer(bounds.managedMaxZ),
    }
    if not integerFieldsEqual(boundsManaged, record.managed, managedFields)
        or anchorX ~= boundsManaged.originX + math.floor(boundsManaged.width / 2)
        or anchorY ~= boundsManaged.originY + math.floor(boundsManaged.height / 2)
        or anchorZ ~= ServerUtil.integer(bounds.z)
        or type(record.rvPosition) ~= "table"
        or not exactKeys(record.rvPosition, { "x", "y", "z" })
        or ServerUtil.toNumber(record.rvPosition.x) ~= anchorX + 0.5
        or ServerUtil.toNumber(record.rvPosition.y) ~= anchorY + 0.5
        or ServerUtil.toNumber(record.rvPosition.z) ~= anchorZ then
        return false
    end

    local regionSize = ServerUtil.integer(Constants.RV_REGION_SIZE)
    local regionMinXOffset = ServerUtil.integer(Constants.RV_REGION_MIN_OFFSET_X)
    local regionMinYOffset = ServerUtil.integer(Constants.RV_REGION_MIN_OFFSET_Y)
    local identityMinZ = ServerUtil.integer(Constants.RV_IDENTITY_MIN_Z)
    local identityMaxZ = ServerUtil.integer(Constants.RV_IDENTITY_MAX_Z)
    if not regionSize or not regionMinXOffset or not regionMinYOffset
        or not identityMinZ or not identityMaxZ or identityMaxZ <= identityMinZ then
        return false
    end
    local expectedRegion = {
        minX = anchorX + regionMinXOffset,
        minY = anchorY + regionMinYOffset,
        maxX = anchorX + regionMinXOffset + regionSize,
        maxY = anchorY + regionMinYOffset + regionSize,
        minZ = identityMinZ,
        maxZ = identityMaxZ,
    }
    if not integerFieldsEqual(record.region, expectedRegion, regionFields) then
        return false
    end

    if not Boundary or type(Boundary.registerGeneration) ~= "function" then
        return false
    end
    local registerOk, registered = pcall(Boundary.registerGeneration,
        record.rvId, recordGeneration, record.boundary, record)
    return registerOk and registered == true
end

validateRecordGeometryAtStartup = function()
    if not ModData or type(ModData.get) ~= "function"
        or type(ServerSchema) ~= "table" then
        return false, "mapping or manifest schema dependencies are unavailable"
    end
    local mapOk, map = pcall(ModData.get, Constants.RV_MAP_KEY)
    local manifestOk, persisted = pcall(ModData.get, Constants.MANIFEST_KEY)
    if not mapOk or not manifestOk then
        return false, "could not read current mapping and manifest roots"
    end
    if map == nil or type(map) == "table" and next(map) == nil then return true end
    if type(map) ~= "table" or type(map.locomotives) ~= "table" then
        return false, "mapping root is not current"
    end
    if persisted ~= nil and type(persisted) ~= "table" then
        return false, "manifest root is not a table"
    end
    for _, record in pairs(map.locomotives) do
        local comparison
        if type(persisted) == "table" and next(persisted) ~= nil
            and tostring(persisted.rvId) == tostring(record.rvId) then
            if ServerUtil.integer(persisted.generation)
                    ~= ServerUtil.integer(record.generation)
                or ServerUtil.integer(persisted.bitmapVersion)
                    ~= ServerUtil.integer(record.bitmapVersion) then
                return false, "persisted manifest identity does not match mapping"
            end
            comparison = persisted
        else
            comparison = manifestViewForRecord(record)
            if not comparison then
                return false, "mapping record has no valid current view"
            end
        end
        local consistent = validateCurrentRVRecordGeometrySchema(record, comparison)
        if consistent ~= true then
            return false, "mapping record and manifest geometry differ"
        end
    end
    return true
end
local function validateAtStartup()
    if ran then return end
    ran = true
    validating = true
    for i = 1, #required do
        local name = required[i]
        local validator = name == "mapping" and validateMappingAtStartup
            or name == "manifest" and validateManifestAtStartup
            or name == "utility" and validateUtilityAtStartup
            or name == "record_geometry" and validateRecordGeometryAtStartup
        if type(validator) ~= "function" then
            fail("startup schema validator missing: " .. name)
            validating = false
            return
        end
        local ok, accepted, detail = pcall(validator)
        if not ok or accepted ~= true then
            fail(name .. " schema rejected" .. (detail and (": " .. tostring(detail)) or ""))
            validating = false
            return
        end
    end
    status = "passed"
    validating = false
    print("[RailroaderRVTest] RV startup save schema gate passed.")
end

if not ran and status == "pending" then
    local events = rawget(_G, "Events")
    local event = events and events.OnInitGlobalModData
    if event and type(event.Add) == "function" then
        local ok, result = pcall(event.Add, validateAtStartup)
        if not ok or result == false then
            fail("could not register OnInitGlobalModData schema validation")
        end
    else
        fail("OnInitGlobalModData is unavailable; saved ModData cannot be checked at startup")
    end
end

return Gate
