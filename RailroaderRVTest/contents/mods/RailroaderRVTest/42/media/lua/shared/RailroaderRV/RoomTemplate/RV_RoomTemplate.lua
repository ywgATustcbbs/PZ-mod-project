-- Current, shared, read-only-by-contract template data and pure queries.
--
-- RV_Template remains the ordered capture source. This module compiles it
-- once into the RoomTemplate schema; it never reads or mutates world objects.
require "RailroaderRV/Common/RV_Constants"
local Source = require "RailroaderRV/RoomTemplate/RV_Template"
local Protection = require "RailroaderRV/RoomTemplate/RV_ProtectionManifest"

local C = RailroaderRV.Constants
local RoomTemplate = {}

RoomTemplate.SCHEMA_VERSION = 1
RoomTemplate.TEMPLATE_ID = "railroader-rv"
RoomTemplate.CURRENT_TEMPLATE_VERSION = 11
RoomTemplate.CURRENT_OBJECT_COUNT = 412
RoomTemplate.WIDTH = 100
RoomTemplate.HEIGHT = 100
RoomTemplate.MIN_X = -50
RoomTemplate.MIN_Y = -50
RoomTemplate.MAX_X_EXCLUSIVE = 50
RoomTemplate.MAX_Y_EXCLUSIVE = 50
RoomTemplate.MIN_Z = -32
RoomTemplate.MAX_Z_EXCLUSIVE = 32

local segments = {
    { name = "negative", minZ = -32, maxZExclusive = 0 },
    { name = "z0to3", minZ = 0, maxZExclusive = 4 },
    { name = "z4to31", minZ = 4, maxZExclusive = 32 },
}
local segmentByName = {
    negative = segments[1],
    z0to3 = segments[2],
    z4to31 = segments[3],
}
local sourceKeys = {
    schemaVersion = true, sourceTarget = true, objectCount = true,
    buildCells = true, objects = true,
}
local objectKeys = {
    x = true, y = true, z = true, class = true, name = true,
    sprite = true, direction = true, state = true,
}
local stateKeys = {
    health = true, maxHealth = true, hoppable = true,
    locked = true, doRender = true,
}

local function finiteInteger(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and math.floor(value) == value
end

local function exactKeys(value, expected, optional)
    if type(value) ~= "table" then return false end
    local count = 0
    for key in pairs(value) do
        if not expected[key] and not (optional and optional[key]) then
            return false
        end
        count = count + 1
    end
    local required = 0
    for key in pairs(expected) do
        if not (optional and optional[key]) then
            if value[key] == nil then return false end
            required = required + 1
        end
    end
    return count >= required
end

local function denseList(value)
    if type(value) ~= "table" then return nil end
    local count, maxIndex = 0, 0
    for key in pairs(value) do
        if not finiteInteger(key) or key < 1 then return nil end
        count = count + 1
        if key > maxIndex then maxIndex = key end
    end
    if count ~= maxIndex then return nil end
    for index = 1, count do
        if value[index] == nil then return nil end
    end
    return count
end

local function sameScalarTable(left, right, allowedKeys)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    local leftCount, rightCount = 0, 0
    for key, value in pairs(left) do
        if not allowedKeys[key] or right[key] ~= value then return false end
        leftCount = leftCount + 1
    end
    for key in pairs(right) do rightCount = rightCount + 1 end
    return leftCount == rightCount
end

local function sameCaptureIdentity(source, record, index)
    if type(record) ~= "table" then return false end
    local north = record.north
    if north == "none" then north = nil end
    return record.templateIndex == index
        and record.x == source.x and record.y == source.y and record.z == source.z
        and record.class == source.class and record.name == source.name
        and record.sprite == source.sprite and record.direction == source.direction
        and north == source.north
        and sameScalarTable(record.state, source.state, stateKeys)
end

local function assertSource()
    if not exactKeys(Source, sourceKeys)
        or Source.schemaVersion ~= RoomTemplate.CURRENT_TEMPLATE_VERSION
        or Source.objectCount ~= RoomTemplate.CURRENT_OBJECT_COUNT
        or not finiteInteger(Source.objectCount)
        or denseList(Source.objects) ~= Source.objectCount
        or denseList(Source.buildCells) ~= 24
        or type(Source.sourceTarget) ~= "table"
        or not finiteInteger(Source.sourceTarget.x)
        or not finiteInteger(Source.sourceTarget.y)
        or not finiteInteger(Source.sourceTarget.z) then
        error("RailroaderRV: captured template source has the wrong current schema")
    end

    for index = 1, Source.objectCount do
        local object = Source.objects[index]
        if type(object) ~= "table" or not exactKeys(object, objectKeys, { north = true })
            or not finiteInteger(object.x) or not finiteInteger(object.y)
            or not finiteInteger(object.z) or object.z < RoomTemplate.MIN_Z
            or object.z >= RoomTemplate.MAX_Z_EXCLUSIVE
            or type(object.class) ~= "string" or type(object.name) ~= "string"
            or type(object.sprite) ~= "string" or type(object.direction) ~= "string"
            or (object.north ~= nil and type(object.north) ~= "boolean")
            or type(object.state) ~= "table" then
            error("RailroaderRV: captured template object schema is invalid at "
                .. tostring(index))
        end
        for key, value in pairs(object.state) do
            if not stateKeys[key]
                or (type(value) ~= "boolean" and not finiteInteger(value)) then
                error("RailroaderRV: captured template state is invalid at "
                    .. tostring(index))
            end
        end
        local policy = type(Protection) == "table"
            and type(Protection.get) == "function" and Protection.get(index) or nil
        if not sameCaptureIdentity(object, policy, index)
            or not finiteInteger(policy.protectionClass)
            or policy.protectionClass < 1 or policy.protectionClass > 4 then
            error("RailroaderRV: current template protection identity is invalid at "
                .. tostring(index))
        end
    end

    local buildCellKeys = {}
    for index = 1, #Source.buildCells do
        local cell = Source.buildCells[index]
        if type(cell) ~= "table" or not exactKeys(cell, { x = true, y = true })
            or not finiteInteger(cell.x) or not finiteInteger(cell.y)
            or cell.x < RoomTemplate.MIN_X or cell.x >= RoomTemplate.MAX_X_EXCLUSIVE
            or cell.y < RoomTemplate.MIN_Y or cell.y >= RoomTemplate.MAX_Y_EXCLUSIVE then
            error("RailroaderRV: captured build-cell schema is invalid")
        end
        local key = tostring(cell.x) .. ":" .. tostring(cell.y)
        if buildCellKeys[key] then
            error("RailroaderRV: captured build-cell identity is duplicated")
        end
        buildCellKeys[key] = true
    end
    for x = C.CAB_MIN_OFFSET_X, C.CAB_MAX_OFFSET_X do
        for y = C.CAB_MIN_OFFSET_Y, C.CAB_MAX_OFFSET_Y do
            if not buildCellKeys[tostring(x) .. ":" .. tostring(y)] then
                error("RailroaderRV: captured cab build mask is incomplete")
            end
        end
    end
end

local function newRowWithEmptyFlags()
    local row = {}
    for x = RoomTemplate.MIN_X, RoomTemplate.MAX_X_EXCLUSIVE - 1 do
        row[x] = { negative = false, z0to3 = false, z4to31 = false }
    end
    return row
end

local function copyState(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

local function copySegments()
    local result = {}
    for index = 1, #segments do
        result[index] = {
            name = segments[index].name,
            minZ = segments[index].minZ,
            maxZExclusive = segments[index].maxZExclusive,
        }
    end
    return result
end

local function copyObject(source, index, protectionClass)
    return {
        templateIndex = index,
        x = source.x,
        y = source.y,
        z = source.z,
        class = source.class,
        name = source.name,
        sprite = source.sprite,
        north = source.north,
        direction = source.direction,
        state = copyState(source.state),
        protectionClass = protectionClass,
    }
end

local function compileAabbs()
    local walk = {
        minX = C.INTERIOR_MIN_OFFSET_X,
        maxX = C.INTERIOR_MAX_OFFSET_X + 1,
        minY = C.INTERIOR_MIN_OFFSET_Y,
        maxY = C.INTERIOR_MAX_OFFSET_Y + 1,
        minZ = 0,
        maxZExclusive = 1,
    }
    local buildMinX, buildMaxX = nil, nil
    local buildMinY, buildMaxY = nil, nil
    for index = 1, #Source.buildCells do
        local cell = Source.buildCells[index]
        buildMinX = buildMinX == nil and cell.x or math.min(buildMinX, cell.x)
        buildMaxX = buildMaxX == nil and cell.x or math.max(buildMaxX, cell.x)
        buildMinY = buildMinY == nil and cell.y or math.min(buildMinY, cell.y)
        buildMaxY = buildMaxY == nil and cell.y or math.max(buildMaxY, cell.y)
    end
    return { walk }, {
        {
            minX = buildMinX, maxX = buildMaxX + 1,
            minY = buildMinY, maxY = buildMaxY + 1,
            minZ = 0, maxZExclusive = 1,
        },
    }
end

local function compileRoofTargets(objects)
    local minX, maxX, maxY = nil, nil, nil
    for index = 1, #Source.buildCells do
        local cell = Source.buildCells[index]
        minX = minX == nil and cell.x or math.min(minX, cell.x)
        maxX = maxX == nil and cell.x or math.max(maxX, cell.x)
        maxY = maxY == nil and cell.y or math.max(maxY, cell.y)
    end

    local windows = {}
    for index = 1, #objects do
        local object = objects[index]
        if object.class == "IsoWindow" and object.z == 0
            and object.x >= minX and object.x <= maxX
            and object.y == maxY + 1 then
            windows[#windows + 1] = object
        end
    end
    if #windows ~= 1 then
        error("RailroaderRV: captured cab south-window target is not unique")
    end

    local window = windows[1]
    local floors = {}
    for index = 1, #objects do
        local object = objects[index]
        if object.class == "IsoObject" and object.x == window.x
            and object.y == window.y + 1 and object.z == 0 then
            floors[#floors + 1] = object
        end
    end
    if #floors ~= 1 then
        error("RailroaderRV: captured south-window refresh floor is not unique")
    end
    local floor = floors[1]
    return {
        {
            kind = "room-refresh-floor",
            x = floor.x,
            y = floor.y,
            z = floor.z,
            templateIndex = floor.templateIndex,
            identity = {
                templateIndex = floor.templateIndex,
                x = floor.x,
                y = floor.y,
                z = floor.z,
                class = floor.class,
                name = floor.name,
                sprite = floor.sprite,
                north = floor.north,
                direction = floor.direction,
                state = copyState(floor.state),
                protectionClass = floor.protectionClass,
            },
        },
    }
end

assertSource()

local bitmap = {}
for y = RoomTemplate.MIN_Y, RoomTemplate.MAX_Y_EXCLUSIVE - 1 do
    bitmap[y] = newRowWithEmptyFlags()
end

local celldef = {}
local compiledObjects = {}
for index = 1, Source.objectCount do
    local source = Source.objects[index]
    local policy = Protection.get(index)
    local object = copyObject(source, index, policy.protectionClass)
    compiledObjects[index] = object

    if source.x < RoomTemplate.MIN_X or source.x >= RoomTemplate.MAX_X_EXCLUSIVE
        or source.y < RoomTemplate.MIN_Y or source.y >= RoomTemplate.MAX_Y_EXCLUSIVE then
        error("RailroaderRV: captured template object is outside the 100x100 region at "
            .. tostring(index))
    end

    local row = celldef[source.y]
    if not row then row = {}; celldef[source.y] = row end
    local cell = row[source.x]
    if not cell then cell = { layers = {} }; row[source.x] = cell end
    local layer = cell.layers[source.z]
    if not layer then layer = {}; cell.layers[source.z] = layer end
    layer[#layer + 1] = object

    local flag
    if source.z < 0 then flag = "negative"
    elseif source.z <= 3 then flag = "z0to3"
    else flag = "z4to31" end
    bitmap[source.y][source.x][flag] = true
end

local walkAabbs, buildAabbs = compileAabbs()
local template = {
    metadata = {
        id = RoomTemplate.TEMPLATE_ID,
        displayName = "Railroader RV",
        templateVersion = RoomTemplate.CURRENT_TEMPLATE_VERSION,
        schemaVersion = RoomTemplate.SCHEMA_VERSION,
        -- Object coordinates use (0,0,0) as the local anchor. sourceTarget
        -- below records the original capture cell only, not a world target.
        anchor = { x = 0, y = 0, z = 0 },
        sourceTarget = {
            x = Source.sourceTarget.x,
            y = Source.sourceTarget.y,
            z = Source.sourceTarget.z,
        },
        width = RoomTemplate.WIDTH,
        height = RoomTemplate.HEIGHT,
        minX = RoomTemplate.MIN_X,
        maxXExclusive = RoomTemplate.MAX_X_EXCLUSIVE,
        minY = RoomTemplate.MIN_Y,
        maxYExclusive = RoomTemplate.MAX_Y_EXCLUSIVE,
        objectCount = Source.objectCount,
        segmentSchema = copySegments(),
    },
    bitmap = bitmap,
    celldef = celldef,
    misc = {
        walkAabbs = walkAabbs,
        buildAabbs = buildAabbs,
        buildCells = {},
        roofTargets = compileRoofTargets(compiledObjects),
    },
}
for index = 1, #Source.buildCells do
    template.misc.buildCells[index] = {
        x = Source.buildCells[index].x,
        y = Source.buildCells[index].y,
    }
end

local templateRootKeys = {
    metadata = true, bitmap = true, celldef = true, misc = true,
}
local metadataKeys = {
    id = true, displayName = true, templateVersion = true,
    schemaVersion = true, anchor = true, sourceTarget = true,
    width = true, height = true, minX = true, maxXExclusive = true,
    minY = true, maxYExclusive = true, objectCount = true,
    segmentSchema = true,
}
local pointKeys = { x = true, y = true, z = true }
local cellKeys = { layers = true }
local flagKeys = { negative = true, z0to3 = true, z4to31 = true }
local aabbKeys = {
    minX = true, maxX = true, minY = true, maxY = true,
    minZ = true, maxZExclusive = true,
}
local miscKeys = {
    walkAabbs = true, buildAabbs = true,
    buildCells = true, roofTargets = true,
}
local roofTargetKeys = {
    kind = true, x = true, y = true, z = true,
    templateIndex = true, identity = true,
}
local identityKeys = {
    templateIndex = true, x = true, y = true, z = true,
    class = true, name = true, sprite = true,
    direction = true, state = true, protectionClass = true,
}

local function validPoint(point)
    return exactKeys(point, pointKeys)
        and finiteInteger(point.x) and finiteInteger(point.y)
        and finiteInteger(point.z)
end

local function validObject(object, x, y, z)
    if type(object) ~= "table" or not exactKeys(object,
        {
            templateIndex = true, x = true, y = true, z = true,
            class = true, name = true, sprite = true, direction = true,
            state = true, protectionClass = true,
        }, { north = true }) then
        return false
    end
    if object.x ~= x or object.y ~= y or object.z ~= z
        or not finiteInteger(object.templateIndex) or object.templateIndex < 1
        or not finiteInteger(object.protectionClass)
        or object.protectionClass < 1 or object.protectionClass > 4
        or type(object.class) ~= "string" or type(object.name) ~= "string"
        or type(object.sprite) ~= "string" or type(object.direction) ~= "string"
        or (object.north ~= nil and type(object.north) ~= "boolean")
        or type(object.state) ~= "table" then
        return false
    end
    for key, value in pairs(object.state) do
        if not stateKeys[key]
            or (type(value) ~= "boolean" and not finiteInteger(value)) then
            return false
        end
    end
    return true
end

local function validAabbList(list)
    local count = denseList(list)
    if count == nil or count == 0 then return false end
    for index = 1, count do
        local box = list[index]
        if not exactKeys(box, aabbKeys)
            or not finiteInteger(box.minX) or not finiteInteger(box.maxX)
            or not finiteInteger(box.minY) or not finiteInteger(box.maxY)
            or not finiteInteger(box.minZ) or not finiteInteger(box.maxZExclusive)
            or box.minX < RoomTemplate.MIN_X
            or box.maxX > RoomTemplate.MAX_X_EXCLUSIVE
            or box.minY < RoomTemplate.MIN_Y
            or box.maxY > RoomTemplate.MAX_Y_EXCLUSIVE
            or box.minZ < RoomTemplate.MIN_Z
            or box.maxZExclusive > RoomTemplate.MAX_Z_EXCLUSIVE
            or box.minX >= box.maxX or box.minY >= box.maxY
            or box.minZ >= box.maxZExclusive then
            return false
        end
    end
    return true
end

function RoomTemplate.validate(value)
    if type(value) ~= "table" or not exactKeys(value, templateRootKeys) then
        return false, "template root has missing or unknown fields"
    end
    local metadata = value.metadata
    if not exactKeys(metadata, metadataKeys)
        or metadata.id ~= RoomTemplate.TEMPLATE_ID
        or metadata.displayName ~= "Railroader RV"
        or metadata.templateVersion ~= RoomTemplate.CURRENT_TEMPLATE_VERSION
        or metadata.schemaVersion ~= RoomTemplate.SCHEMA_VERSION
        or not validPoint(metadata.anchor) or metadata.anchor.x ~= 0
        or metadata.anchor.y ~= 0 or metadata.anchor.z ~= 0
        or not validPoint(metadata.sourceTarget)
        or metadata.sourceTarget.x ~= 51 or metadata.sourceTarget.y ~= 44
        or metadata.sourceTarget.z ~= 0
        or metadata.width ~= RoomTemplate.WIDTH or metadata.height ~= RoomTemplate.HEIGHT
        or metadata.minX ~= RoomTemplate.MIN_X
        or metadata.maxXExclusive ~= RoomTemplate.MAX_X_EXCLUSIVE
        or metadata.minY ~= RoomTemplate.MIN_Y
        or metadata.maxYExclusive ~= RoomTemplate.MAX_Y_EXCLUSIVE
        or metadata.objectCount ~= RoomTemplate.CURRENT_OBJECT_COUNT then
        return false, "template metadata does not use the current identity/schema"
    end

    local segmentCount = denseList(metadata.segmentSchema)
    if segmentCount ~= 3 then
        return false, "template segment schema is incomplete"
    end
    for index = 1, 3 do
        local actual, expected = metadata.segmentSchema[index], segments[index]
        if not exactKeys(actual, { name = true, minZ = true, maxZExclusive = true })
            or actual.name ~= expected.name or actual.minZ ~= expected.minZ
            or actual.maxZExclusive ~= expected.maxZExclusive then
            return false, "template segment schema is not current"
        end
    end

    if type(value.bitmap) ~= "table" or type(value.celldef) ~= "table"
        or not exactKeys(value.misc, miscKeys) then
        return false, "template data tables are incomplete"
    end
    for y = RoomTemplate.MIN_Y, RoomTemplate.MAX_Y_EXCLUSIVE - 1 do
        local bitmapRow = value.bitmap[y]
        -- A dense coordinate-keyed row contains exactly one key per X.
        local rowCount = 0
        if type(bitmapRow) ~= "table" then
            return false, "template bitmap row is missing"
        end
        for x, flags in pairs(bitmapRow) do
            if not finiteInteger(x) or x < RoomTemplate.MIN_X
                or x >= RoomTemplate.MAX_X_EXCLUSIVE
                or not exactKeys(flags, flagKeys)
                or type(flags.negative) ~= "boolean"
                or type(flags.z0to3) ~= "boolean"
                or type(flags.z4to31) ~= "boolean" then
                return false, "template bitmap contains an invalid cell or flag"
            end
            rowCount = rowCount + 1
        end
        if rowCount ~= RoomTemplate.WIDTH then
            return false, "template bitmap row is not dense"
        end
    end
    local bitmapRows = 0
    for y in pairs(value.bitmap) do
        if not finiteInteger(y) or y < RoomTemplate.MIN_Y
            or y >= RoomTemplate.MAX_Y_EXCLUSIVE then
            return false, "template bitmap has an extra row"
        end
        bitmapRows = bitmapRows + 1
    end
    if bitmapRows ~= RoomTemplate.HEIGHT then
        return false, "template bitmap is not 100 rows"
    end

    local objectCount, objectIndices = 0, {}
    for y, row in pairs(value.celldef) do
        if not finiteInteger(y) or y < RoomTemplate.MIN_Y
            or y >= RoomTemplate.MAX_Y_EXCLUSIVE or type(row) ~= "table" then
            return false, "template cell definition has an invalid row"
        end
        local cellCount = 0
        for x, cell in pairs(row) do
            cellCount = cellCount + 1
            if not finiteInteger(x) or x < RoomTemplate.MIN_X
                or x >= RoomTemplate.MAX_X_EXCLUSIVE
                or not exactKeys(cell, cellKeys) or type(cell.layers) ~= "table" then
                return false, "template cell definition has an invalid cell"
            end
            local layerCount = 0
            for z, objects in pairs(cell.layers) do
                if not RoomTemplate.supportsZ(z) then
                    return false, "template layer has an invalid Z key"
                end
                local count = denseList(objects)
                if count == nil or count == 0 then
                    return false, "template layer object list is empty or sparse"
                end
                layerCount = layerCount + 1
                local previous = 0
                local groupKey = tostring(y) .. ":" .. tostring(x) .. ":" .. tostring(z)
                for index = 1, count do
                    local object = objects[index]
                    if not validObject(object, x, y, z)
                        or object.templateIndex <= previous
                        or object.templateIndex > metadata.objectCount
                        or objectIndices[object.templateIndex] then
                        return false, "template layer object identity/order is invalid"
                    end
                    previous = object.templateIndex
                    objectIndices[object.templateIndex] = groupKey
                    objectCount = objectCount + 1
                end
            end
            if layerCount == 0 then
                return false, "template cell has no layers"
            end
        end
        if cellCount == 0 then
            return false, "template cell definition contains an empty row"
        end
    end
    if objectCount ~= metadata.objectCount then
        return false, "template object count does not match celldef"
    end
    for index = 1, metadata.objectCount do
        if objectIndices[index] == nil then
            return false, "template object identity sequence has a gap"
        end
    end

    for y = RoomTemplate.MIN_Y, RoomTemplate.MAX_Y_EXCLUSIVE - 1 do
        for x = RoomTemplate.MIN_X, RoomTemplate.MAX_X_EXCLUSIVE - 1 do
            local row = value.celldef[y]
            local cell = row and row[x]
            for segmentIndex = 1, #segments do
                local segment = segments[segmentIndex]
                local exists = false
                if cell then
                    for z = segment.minZ, segment.maxZExclusive - 1 do
                        local objects = cell.layers[z]
                        if objects ~= nil then
                            exists = true
                            break
                        end
                    end
                end
                if value.bitmap[y][x][segment.name] ~= exists then
                    return false, "template bitmap summary does not match celldef"
                end
            end
        end
    end

    local misc = value.misc
    if not validAabbList(misc.walkAabbs) or not validAabbList(misc.buildAabbs) then
        return false, "template walk/build AABB data is invalid"
    end
    if #misc.walkAabbs ~= 1 or #misc.buildAabbs ~= 1 then
        return false, "template walk/build AABB identity is not current"
    end
    local walk, build = misc.walkAabbs[1], misc.buildAabbs[1]
    if walk.minX ~= C.INTERIOR_MIN_OFFSET_X
        or walk.maxX ~= C.INTERIOR_MAX_OFFSET_X + 1
        or walk.minY ~= C.INTERIOR_MIN_OFFSET_Y
        or walk.maxY ~= C.INTERIOR_MAX_OFFSET_Y + 1
        or walk.minZ ~= 0 or walk.maxZExclusive ~= 1
        or build.minX ~= C.CAB_MIN_OFFSET_X
        or build.maxX ~= C.CAB_MAX_OFFSET_X + 1
        or build.minY ~= C.CAB_MIN_OFFSET_Y
        or build.maxY ~= C.CAB_MAX_OFFSET_Y + 1
        or build.minZ ~= 0 or build.maxZExclusive ~= 1 then
        return false, "template walk/build AABB identity is not current"
    end
    local buildCellCount = denseList(misc.buildCells)
    if buildCellCount ~= 24 then return false, "template build-cell list is invalid" end
    local buildCells = {}
    for index = 1, buildCellCount do
        local cell = misc.buildCells[index]
        if not exactKeys(cell, { x = true, y = true })
            or not finiteInteger(cell.x) or not finiteInteger(cell.y)
            or cell.x < RoomTemplate.MIN_X or cell.x >= RoomTemplate.MAX_X_EXCLUSIVE
            or cell.y < RoomTemplate.MIN_Y or cell.y >= RoomTemplate.MAX_Y_EXCLUSIVE then
            return false, "template build-cell entry is invalid"
        end
        local key = tostring(cell.x) .. ":" .. tostring(cell.y)
        if buildCells[key] then return false, "template build-cell entry is duplicated" end
        buildCells[key] = true
    end
    for x = C.CAB_MIN_OFFSET_X, C.CAB_MAX_OFFSET_X do
        for y = C.CAB_MIN_OFFSET_Y, C.CAB_MAX_OFFSET_Y do
            if not buildCells[tostring(x) .. ":" .. tostring(y)] then
                return false, "template build-cell mask is incomplete"
            end
        end
    end

    local roofCount = denseList(misc.roofTargets)
    if roofCount ~= 1 then return false, "template roof target list is invalid" end
    for index = 1, roofCount do
        local target = misc.roofTargets[index]
        if not exactKeys(target, roofTargetKeys)
            or target.kind ~= "room-refresh-floor"
            or not finiteInteger(target.x) or not finiteInteger(target.y)
            or not finiteInteger(target.z) or not RoomTemplate.supportsZ(target.z)
            or not finiteInteger(target.templateIndex)
            or target.templateIndex < 1 or target.templateIndex > metadata.objectCount
            or not exactKeys(target.identity, identityKeys, { north = true })
            or target.identity.templateIndex ~= target.templateIndex
            or target.identity.x ~= target.x or target.identity.y ~= target.y
            or target.identity.z ~= target.z then
            return false, "template roof target identity is invalid"
        end
        local row = value.celldef[target.y]
        local cell = row and row[target.x]
        local layer = cell and cell.layers[target.z]
        local found = false
        if layer then
            for objectIndex = 1, #layer do
                local object = layer[objectIndex]
                if object.templateIndex == target.templateIndex
                    and object.class == target.identity.class
                    and object.name == target.identity.name
                    and object.sprite == target.identity.sprite
                    and object.direction == target.identity.direction
                    and object.north == target.identity.north
                    and object.protectionClass == target.identity.protectionClass
                    and sameScalarTable(object.state, target.identity.state, stateKeys) then
                    found = true
                    break
                end
            end
        end
        if not found then return false, "template roof target does not match an object" end
    end
    return true
end

local function cellCoordinates(x, y)
    return finiteInteger(x) and finiteInteger(y)
        and x >= RoomTemplate.MIN_X and x < RoomTemplate.MAX_X_EXCLUSIVE
        and y >= RoomTemplate.MIN_Y and y < RoomTemplate.MAX_Y_EXCLUSIVE
end

function RoomTemplate.supportsZ(z)
    return finiteInteger(z) and z >= RoomTemplate.MIN_Z
        and z < RoomTemplate.MAX_Z_EXCLUSIVE
end

function RoomTemplate.get(templateId)
    if templateId == RoomTemplate.TEMPLATE_ID then return template end
    return nil
end

function RoomTemplate.cellAt(value, x, y)
    if value ~= template or not cellCoordinates(x, y) then return nil end
    local row = value.celldef[y]
    return row and row[x] or nil
end

function RoomTemplate.segmentMayHaveLayer(value, x, y, segment)
    if value ~= template or not cellCoordinates(x, y)
        or not segmentByName[segment] then
        return false
    end
    return value.bitmap[y][x][segment] == true
end

function RoomTemplate.hasLayer(value, x, y, z)
    if value ~= template or not cellCoordinates(x, y)
        or not RoomTemplate.supportsZ(z) then
        return false
    end
    local segment = z < 0 and "negative"
        or (z <= 3 and "z0to3" or "z4to31")
    if value.bitmap[y][x][segment] ~= true then return false end
    local cell = RoomTemplate.cellAt(value, x, y)
    return cell ~= nil and type(cell.layers[z]) == "table"
        and #cell.layers[z] > 0
end

function RoomTemplate.hasAnyLayer(value, x, y, zMin, zMax)
    if value ~= template or not cellCoordinates(x, y)
        or not finiteInteger(zMin) or not finiteInteger(zMax)
        or zMin < RoomTemplate.MIN_Z or zMax > RoomTemplate.MAX_Z_EXCLUSIVE
        or zMin >= zMax then
        return false
    end
    for segmentIndex = 1, #segments do
        local segment = segments[segmentIndex]
        local firstZ = math.max(zMin, segment.minZ)
        local lastZ = math.min(zMax, segment.maxZExclusive)
        if firstZ < lastZ and value.bitmap[y][x][segment.name] then
            for z = firstZ, lastZ - 1 do
                local cell = RoomTemplate.cellAt(value, x, y)
                if cell and type(cell.layers[z]) == "table"
                    and #cell.layers[z] > 0 then
                    return true
                end
            end
        end
    end
    return false
end

function RoomTemplate.roofTargets(value)
    if value ~= template then return nil end
    return value.misc.roofTargets
end

-- Return the captured rows in original template order. celldef is sparse and
-- its table traversal order is unspecified, so templateIndex is the ordering
-- identity; duplicate objects at one cell/layer still occupy distinct slots.
function RoomTemplate.orderedObjects(value)
    if value ~= template then return nil end
    local byIndex = {}
    local found = 0
    for _, row in pairs(value.celldef) do
        for _, cell in pairs(row) do
            for _, layer in pairs(cell.layers) do
                for objectIndex = 1, #layer do
                    local object = layer[objectIndex]
                    local index = object.templateIndex
                    if not finiteInteger(index) or index < 1
                        or index > value.metadata.objectCount or byIndex[index] then
                        return nil
                    end
                    byIndex[index] = object
                    found = found + 1
                end
            end
        end
    end
    if found ~= value.metadata.objectCount then return nil end
    local ordered = {}
    for index = 1, value.metadata.objectCount do
        if byIndex[index] == nil then return nil end
        ordered[index] = byIndex[index]
    end
    return ordered
end

local valid, validationError = RoomTemplate.validate(template)
if not valid then
    error("RailroaderRV: compiled room template failed validation: "
        .. tostring(validationError))
end

return RoomTemplate
