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
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local TemplateGeometry = require("RailroaderRV/RoomTemplate/RV_TemplateGeometry")
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local templateObjects = RoomTemplate.orderedObjects(Template)

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
end

local function identityKey(rvId, generation)
    local currentGeneration = integer(generation)
    if rvId == nil or tostring(rvId) == "" or not currentGeneration
        or currentGeneration < 1 then
        return nil
    end
    return tostring(rvId) .. ":" .. tostring(currentGeneration)
end

local function queueKey(boundary, record)
    if type(boundary) ~= "table" or type(record) ~= "table"
        or not sameIdentity(boundary, record) or boundary.rvId == nil
        or tostring(boundary.rvId) == "" then
        return nil
    end
    local generation = integer(boundary.generation)
    if not generation or generation < 1 then return nil end
    return tostring(boundary.rvId) .. ":" .. tostring(generation)
end

local function coordinateKey(x, y, z)
    return tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
end

local function currentProtectedCoordinateTargets(index, boundary, x, y, z)
    if type(index) ~= "table" or type(boundary) ~= "table"
        or tostring(index.rvId) ~= tostring(boundary.rvId)
        or integer(index.generation) ~= integer(boundary.generation) then
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
    if manifest.state ~= "READY" or manifest.phase ~= "COMMITTED"
        or not sameIdentity(manifest, boundary)
        or not sameIdentity(manifest.boundary, boundary)
        or not sameIdentity(record, boundary)
        or manifest.templateVersion ~= Constants.CAPTURED_TEMPLATE_VERSION
        or type(manifest.bounds) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local region, managed = record.region, boundary.managed
    if type(region) ~= "table" or type(managed) ~= "table"
        or type(manifest.anchor) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local regionMinX, regionMinY = integer(region.minX), integer(region.minY)
    local regionMaxX, regionMaxY = integer(region.maxX), integer(region.maxY)
    local regionMinZ, regionMaxZ = integer(region.minZ), integer(region.maxZ)
    local originX, originY = integer(managed.originX), integer(managed.originY)
    local width, height = integer(managed.width), integer(managed.height)
    local managedMinZ, managedMaxZ = integer(managed.minZ), integer(managed.maxZ)
    local anchor = TemplateGeometry.anchorFromManaged(managed, Template)
    if not regionMinX or not regionMinY or not regionMaxX or not regionMaxY
        or not regionMinZ or not regionMaxZ or not originX or not originY
        or not width or not height or not managedMinZ or not managedMaxZ
        or not anchor or anchor.x ~= integer(manifest.anchor.x)
        or anchor.y ~= integer(manifest.anchor.y)
        or anchor.z ~= integer(manifest.anchor.z)
        or originX < regionMinX or originY < regionMinY
        or originX + width > regionMaxX or originY + height > regionMaxY
        or managedMinZ < regionMinZ or managedMaxZ > regionMaxZ then
        return false, Constants.INVALID_RV_DATA
    end
    return true, boundary, record, manifest, identity
end

local function isCabCoordinate(x, y, z, anchor)
    return TemplateGeometry.isBuildable({ x = x, y = y, z = z }, anchor, Template)
end

local function isCabSideHostCoordinate(x, y, z, index)
    if integer(z) ~= integer(index.anchorZ) then return false end
    return TemplateGeometry.isBuildCellSideHost({ x = x, y = y, z = z }, {
        x = index.anchorX, y = index.anchorY, z = index.anchorZ,
    }, Template)
end

local function templateEntry(templateIndex, anchor)
    local captured = templateObjects[templateIndex]
    return {
        templateIndex = templateIndex,
        x = anchor.x + captured.x,
        y = anchor.y + captured.y,
        z = anchor.z + captured.z,
        class = captured.class,
        name = captured.name,
        sprite = captured.sprite,
        north = captured.north,
        direction = captured.direction,
        state = captured.state,
        protected = captured.protected,
    }
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
        anchorX = integer(anchor.x),
        anchorY = integer(anchor.y),
        anchorZ = integer(anchor.z),
        edges = edges,
        byCoordinate = {},
        protectedCoordinates = {},
    }
    for templateIndex = 1, Template.metadata.objectCount do
        local expected = templateEntry(templateIndex, anchor)
        local edge = edges[templateIndex]
        local protected = expected.protected
        local editableCab = isCabCoordinate(expected.x, expected.y,
            expected.z, anchor)
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
