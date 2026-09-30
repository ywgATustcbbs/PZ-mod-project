-- TemplateRecoveryIndex owns validated current-template identity and its
-- derived, read-only coordinate index. It never changes world objects.
local instance = nil
return function(ctx)
if instance then return instance end
local Boundary = ctx.Boundary
local Constants = ctx.Constants
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local manifestTable = ctx.manifestTable
local requireCurrentManifest = ctx.requireCurrentManifest
local Bitmap = require("RailroaderRV/Common/RV_Bitmap")
local CapturedTemplate = require("RailroaderRV/RoomTemplate/RV_Template")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local templateObjects = RoomTemplate.orderedObjects(Template)
local ProtectionManifest = require("RailroaderRV/RoomTemplate/RV_ProtectionManifest")

if type(Template) ~= "table" or type(Template.metadata) ~= "table"
    or Template.metadata.templateVersion ~= Constants.CAPTURED_TEMPLATE_VERSION
    or Template.metadata.objectCount ~= 412 or type(templateObjects) ~= "table"
    or #templateObjects ~= 412 or not RoomTemplate.validate(Template)
    or not ProtectionManifest.validateTemplate(CapturedTemplate) then
    error("RailroaderRVTest: current template-recovery index is incomplete")
end

local indexes = {}
local capturedClasses = {}
for i = 1, #templateObjects do
    capturedClasses[templateObjects[i].class] = true
end

local function isCapturedClassName(className)
    return type(className) == "string" and capturedClasses[className] == true
end

local function integer(value)
    local number = ServerUtil.toNumber(value)
    if type(number) ~= "number" or number ~= number
        or number <= -math.huge or number >= math.huge
        or math.floor(number) ~= number then
        return nil
    end
    return number
end

local function sameIdentity(left, right)
    return type(left) == "table" and type(right) == "table"
        and tostring(left.rvId) == tostring(right.rvId)
        and integer(left.generation) == integer(right.generation)
        and integer(left.bitmapVersion) == integer(right.bitmapVersion)
end

local function identityKey(rvId, generation, bitmapVersion)
    local currentGeneration = integer(generation)
    local currentBitmapVersion = integer(bitmapVersion)
    if rvId == nil or tostring(rvId) == "" or not currentGeneration
        or currentGeneration < 1 or not currentBitmapVersion then
        return nil
    end
    return tostring(rvId) .. ":" .. tostring(currentGeneration)
        .. ":" .. tostring(currentBitmapVersion)
end

local function queueKey(boundary, record)
    if type(boundary) ~= "table" or type(record) ~= "table"
        or not sameIdentity(boundary, record) or boundary.rvId == nil
        or tostring(boundary.rvId) == "" then
        return nil
    end
    local generation = integer(boundary.generation)
    local bitmapVersion = integer(boundary.bitmapVersion)
    if not generation or generation < 1 or not bitmapVersion then return nil end
    return tostring(boundary.rvId) .. ":" .. tostring(generation)
        .. ":" .. tostring(bitmapVersion)
end

local function coordinateKey(x, y, z)
    return tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
end

local function currentProtectedCoordinateTargets(index, boundary, x, y, z)
    if type(index) ~= "table" or type(boundary) ~= "table"
        or tostring(index.rvId) ~= tostring(boundary.rvId)
        or integer(index.generation) ~= integer(boundary.generation)
        or integer(index.bitmapVersion) ~= integer(boundary.bitmapVersion) then
        return nil
    end
    local targets = type(index.byCoordinate) == "table"
        and index.byCoordinate[coordinateKey(x, y, z)] or nil
    return type(targets) == "table" and #targets > 0 and targets or nil
end

local function validCurrentContext(player, expectedBoundary)
    if not player or type(Boundary.boundaryForPlayer) ~= "function" then
        return false, "current RV boundary validation is unavailable"
    end
    local boundaryOk, boundary, record, relation, identity = pcall(
        Boundary.boundaryForPlayer, player)
    if not boundaryOk or type(boundary) ~= "table"
        or type(record) ~= "table" or type(relation) ~= "table"
        or type(identity) ~= "table" or type(identity.key) ~= "string"
        or (expectedBoundary and boundary ~= expectedBoundary) then
        return false, "player is not mapped to the current RV generation"
    end
    local manifestOk, manifest = pcall(manifestTable)
    if not manifestOk or type(manifest) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local schemaOk = pcall(requireCurrentManifest, manifest, false)
    if not schemaOk or manifest.state ~= "READY" or manifest.phase ~= "COMMITTED"
        or not sameIdentity(manifest, boundary)
        or not sameIdentity(manifest.boundary, boundary)
        or not sameIdentity(record, boundary)
        or manifest.templateVersion ~= Constants.CAPTURED_TEMPLATE_VERSION
        or type(manifest.bounds) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local region, bitmap = record.region, boundary.bitmap
    if type(region) ~= "table" or type(bitmap) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local regionMinX, regionMinY = integer(region.minX), integer(region.minY)
    local regionMaxX, regionMaxY = integer(region.maxX), integer(region.maxY)
    local regionMinZ, regionMaxZ = integer(region.minZ), integer(region.maxZ)
    local originX, originY = integer(bitmap.originX), integer(bitmap.originY)
    local width, height = integer(bitmap.width), integer(bitmap.height)
    local bitmapMinZ, bitmapMaxZ = integer(bitmap.minZ), integer(bitmap.maxZ)
    if not regionMinX or not regionMinY or not regionMaxX or not regionMaxY
        or not regionMinZ or not regionMaxZ or not originX or not originY
        or not width or not height or not bitmapMinZ or not bitmapMaxZ
        or regionMinX ~= originX or regionMinY ~= originY
        or regionMaxX ~= originX + width or regionMaxY ~= originY + height
        or regionMinZ ~= bitmapMinZ or regionMaxZ ~= bitmapMaxZ then
        return false, Constants.INVALID_RV_DATA
    end
    return true, boundary, record, manifest, identity
end

local function isCabCoordinate(x, y, anchor)
    if type(anchor) ~= "table" then return false end
    local anchorX, anchorY = integer(anchor.x), integer(anchor.y)
    if not anchorX or not anchorY then return false end
    local offsetX, offsetY = x - anchorX, y - anchorY
    return offsetX >= Constants.CAB_MIN_OFFSET_X
        and offsetX <= Constants.CAB_MAX_OFFSET_X
        and offsetY >= Constants.CAB_MIN_OFFSET_Y
        and offsetY <= Constants.CAB_MAX_OFFSET_Y
end

local function isCabSideHostCoordinate(x, y, z, index)
    if integer(z) ~= integer(index.anchorZ) then return false end
    local offsetX, offsetY = x - index.anchorX, y - index.anchorY
    local eastHost = offsetX == Constants.CAB_MAX_OFFSET_X + 1
        and offsetY >= Constants.CAB_MIN_OFFSET_Y
        and offsetY <= Constants.CAB_MAX_OFFSET_Y
    local southHost = offsetY == Constants.CAB_MAX_OFFSET_Y + 1
        and offsetX >= Constants.CAB_MIN_OFFSET_X
        and offsetX <= Constants.CAB_MAX_OFFSET_X
    return eastHost or southHost
end

local function templateEntry(templateIndex, anchor)
    local expected = ProtectionManifest.worldEntry(templateIndex, anchor)
    if not expected or not ProtectionManifest.matchesLayoutEntry(templateIndex,
        expected, anchor) then
        error("RailroaderRVTest: static protection class is missing at index "
            .. tostring(templateIndex))
    end
    return expected
end

local function expectedEdgeMap(manifest)
    local result = {}
    local edges = manifest.boundary and manifest.boundary.shellEdges
    if type(edges) ~= "table" then return nil end
    for key, edge in pairs(edges) do
        if type(key) ~= "string" or type(edge) ~= "table"
            or edge.edgeKey ~= key or not sameIdentity(edge, manifest) then
            return nil
        end
        if edge.side ~= "north" and edge.side ~= "south"
            and edge.side ~= "east" and edge.side ~= "west" then
            return nil
        end
        local parts = edge.templateIndices
        if type(parts) ~= "table" or #parts < 1
            or integer(parts[1]) ~= integer(edge.templateIndex) then
            return nil
        end
        local seen = {}
        for i = 1, #parts do
            local index = integer(parts[i])
            if not index or index < 1 or index > Template.metadata.objectCount
                or seen[index] or result[index] ~= nil then
                return nil
            end
            seen[index] = true
            result[index] = edge
        end
    end
    return result
end

local function buildRepairIndex(boundary, manifest)
    local edges = expectedEdgeMap(manifest)
    local anchor = manifest and manifest.anchor
    if not edges or type(anchor) ~= "table"
        or not integer(anchor.x) or not integer(anchor.y)
        or not integer(anchor.z) then
        return nil
    end
    local index = {
        rvId = tostring(boundary.rvId),
        generation = integer(boundary.generation),
        bitmapVersion = integer(boundary.bitmapVersion),
        anchorX = integer(anchor.x),
        anchorY = integer(anchor.y),
        anchorZ = integer(anchor.z),
        edges = edges,
        byCoordinate = {},
        protectedCoordinates = {},
        cabEditableCoordinates = {},
    }
    for offsetX = Constants.CAB_MIN_OFFSET_X, Constants.CAB_MAX_OFFSET_X do
        for offsetY = Constants.CAB_MIN_OFFSET_Y, Constants.CAB_MAX_OFFSET_Y do
            local x, y, z = index.anchorX + offsetX,
                index.anchorY + offsetY, index.anchorZ
            if not Bitmap.isBuildable(boundary.bitmap, x, y, z) then
                return nil
            end
            index.cabEditableCoordinates[coordinateKey(x, y, z)] = true
        end
    end
    for templateIndex = 1, ProtectionManifest.OBJECT_COUNT do
        local protection = ProtectionManifest.get(templateIndex)
        if not protection then return nil end
        local expected = templateEntry(templateIndex, anchor)
        local edge = edges[templateIndex]
        local protectionClass = expected.protectionClass
        if protectionClass == ProtectionManifest.SPECIAL then
            return nil
        end
        local protected = protectionClass == ProtectionManifest.RESTORE_ONLY
            or protectionClass == ProtectionManifest.PROHIBITED
        local editableCab = expected.z == anchor.z
            and isCabCoordinate(expected.x, expected.y, anchor)
        local sideDoorOrWindow = isCabSideHostCoordinate(expected.x,
            expected.y, expected.z, index)
            and (expected.class == "IsoDoor" or expected.class == "IsoWindow")
        if protected and not editableCab and not sideDoorOrWindow then
            local coordinate = coordinateKey(expected.x, expected.y, expected.z)
            local target = { expected = expected, edge = edge }
            local coordinateTargets = index.byCoordinate[coordinate]
            if not coordinateTargets then
                coordinateTargets = {}
                index.byCoordinate[coordinate] = coordinateTargets
            end
            coordinateTargets[#coordinateTargets + 1] = target
            index.protectedCoordinates[coordinate] = true
        end
    end
    return index
end

local function getOrBuildRepairIndex(boundary, manifest)
    local key = queueKey(boundary, manifest)
    if not key then return nil end
    local index = indexes[key]
    if index then return index end
    index = buildRepairIndex(boundary, manifest)
    if not index then return nil end
    index.key = key
    indexes[key] = index
    return index
end

local function clear(identityKey)
    if type(identityKey) == "string" then indexes[identityKey] = nil end
end

local function purgeOtherGenerations(rvId, currentKey)
    local id = tostring(rvId)
    local prefix = id .. ":"
    for key, index in pairs(indexes) do
        if string.sub(key, 1, #prefix) == prefix and key ~= currentKey then
            indexes[key] = nil
        elseif type(index) == "table" and index.rvId == id
            and key ~= currentKey then
            indexes[key] = nil
        end
    end
end

local function objectMatchesCapturedIdentity(object, entry)
    if not ServerUtil.classInstance(object, entry.class) then return false end
    local nameOk, name = ServerUtil.invoke(object, "getName")
    local directionOk, direction = ServerUtil.invoke(object, "getDir")
    local directionTable = rawget(_G, "IsoDirections")
    local expectedDirection = directionTable and directionTable[entry.direction]
    if not nameOk or tostring(name) ~= tostring(entry.name)
        or not directionOk or not expectedDirection or direction ~= expectedDirection
        or tostring(ServerWorld.getSpriteName(object)) ~= tostring(entry.sprite) then
        return false
    end
    if entry.north ~= nil then
        local northOk, north = ServerUtil.invoke(object, "getNorth")
        if not northOk or north ~= entry.north then return false end
    end
    return true
end

instance = {
    integer = integer,
    sameIdentity = sameIdentity,
    identityKey = identityKey,
    queueKey = queueKey,
    coordinateKey = coordinateKey,
    currentProtectedCoordinateTargets = currentProtectedCoordinateTargets,
    validCurrentContext = validCurrentContext,
    isCabCoordinate = isCabCoordinate,
    isCabSideHostCoordinate = isCabSideHostCoordinate,
    templateEntry = templateEntry,
    isCapturedClassName = isCapturedClassName,
    getOrBuildRepairIndex = getOrBuildRepairIndex,
    clear = clear,
    purgeOtherGenerations = purgeOtherGenerations,
    objectMatchesCapturedIdentity = objectMatchesCapturedIdentity,
}
return instance
end
