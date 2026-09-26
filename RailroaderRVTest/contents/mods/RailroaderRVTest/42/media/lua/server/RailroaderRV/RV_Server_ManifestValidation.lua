-- RV_Server: ManifestValidation responsibilities.
return function(ctx)
local OWNER = ctx.OWNER
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local Bitmap = ctx.Bitmap
local Layout = require("RailroaderRV/RV_Layout")
local ServerUtil = ctx.ServerUtil
local function requireCurrentManifest(...) return ctx.requireCurrentManifest(...) end

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
        or ServerUtil.requiredInteger(anchor.x, "manifest anchor.x") ~= Constants.TELEPORT_X
        or ServerUtil.requiredInteger(anchor.y, "manifest anchor.y") ~= Constants.TELEPORT_Y
        or ServerUtil.requiredInteger(anchor.z, "manifest anchor.z") ~= Constants.TELEPORT_Z then
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
    local boundaryBitmapOk, boundaryBitmapValid = pcall(Bitmap.validate,
        bitmap)
    if not boundsBitmapOk or boundsBitmapValid ~= true
        or not boundaryBitmapOk or boundaryBitmapValid ~= true then
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
        owner = true, anchor = true, bounds = true, rvId = true,
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
    local boundaryBitmapOk, boundaryBitmap = false, nil
    if Bitmap and type(Bitmap.decode) == "function" then
        boundaryBitmapOk, boundaryBitmap = pcall(Bitmap.decode,
            manifest.boundary.bitmap)
    end
    if not boundaryBitmapOk or type(boundaryBitmap) ~= "table"
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
    local bitmapValidOk, bitmapValid = false, false
    if Bitmap and type(Bitmap.validate) == "function" then
        bitmapValidOk, bitmapValid = pcall(Bitmap.validate, bitmap)
    end
    if not bitmapValidOk or bitmapValid ~= true
        or bitmap.bitmapVersion ~= Constants.BITMAP_VERSION
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

requireCurrentManifest = function(manifest, allowEmpty)
    local ok, valid = pcall(currentManifestValid, manifest, allowEmpty)
    if not ok or valid ~= true then
        error(Constants.INVALID_RV_DATA)
    end
    return manifest
end


ctx.currentManifestValid = currentManifestValid
ctx.requireCurrentManifest = requireCurrentManifest
end
