-- Current shared template data and pure queries.
local Source = require "RailroaderRV/RoomTemplate/RV_Template"

local RoomTemplate = {}

RoomTemplate.TEMPLATE_ID = "railroader-rv"
RoomTemplate.CURRENT_TEMPLATE_VERSION = 11
RoomTemplate.WIDTH = 100
RoomTemplate.HEIGHT = 100
RoomTemplate.MIN_X = -50
RoomTemplate.MIN_Y = -50
RoomTemplate.MAX_X_EXCLUSIVE = 50
RoomTemplate.MAX_Y_EXCLUSIVE = 50
RoomTemplate.MIN_Z = -32
RoomTemplate.MAX_Z_EXCLUSIVE = 32

local function integer(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and math.floor(value) == value
end

local function cellKey(x, y, z)
    return tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
end

local function compileRoofTargets(objects, buildCells)
    local minX, maxX, maxY
    for index = 1, #buildCells do
        local cell = buildCells[index]
        minX = minX == nil and cell.x or math.min(minX, cell.x)
        maxX = maxX == nil and cell.x or math.max(maxX, cell.x)
        maxY = maxY == nil and cell.y or math.max(maxY, cell.y)
    end

    local window
    for index = 1, #objects do
        local object = objects[index]
        if object.class == "IsoWindow" and object.z == 0
            and object.x >= minX and object.x <= maxX
            and object.y == maxY + 1 then
            window = object
        end
    end

    local floor
    for index = 1, #objects do
        local object = objects[index]
        if object.class == "IsoObject" and object.x == window.x
            and object.y == window.y + 1 and object.z == 0 then
            floor = object
        end
    end
    return { {
        kind = "room-refresh-floor",
        x = floor.x,
        y = floor.y,
        z = floor.z,
        templateIndex = floor.templateIndex,
        identity = floor,
    } }
end

local buildCellSet = {}
for index = 1, #Source.buildCells do
    local cell = Source.buildCells[index]
    buildCellSet[cellKey(cell.x, cell.y,
        cell.z == nil and 0 or cell.z)] = true
end

local template = {
    metadata = {
        id = RoomTemplate.TEMPLATE_ID,
        displayName = "Railroader RV",
        templateVersion = RoomTemplate.CURRENT_TEMPLATE_VERSION,
        anchor = { x = 0, y = 0, z = 0 },
        sourceTarget = Source.sourceTarget,
        width = RoomTemplate.WIDTH,
        height = RoomTemplate.HEIGHT,
        minX = RoomTemplate.MIN_X,
        maxXExclusive = RoomTemplate.MAX_X_EXCLUSIVE,
        minY = RoomTemplate.MIN_Y,
        maxYExclusive = RoomTemplate.MAX_Y_EXCLUSIVE,
        objectCount = Source.objectCount,
    },
    celldef = {},
    misc = {
        walkAabbs = Source.walkAabbs,
        buildCells = Source.buildCells,
    },
}

local objectsByIndex = {}
for index = 1, Source.objectCount do
    local source = Source.objects[index]
    local x, y, z = source.x, source.y, source.z
    local demolitionAllowed = buildCellSet[cellKey(x, y, z)]
    if not demolitionAllowed and (source.class == "IsoDoor"
        or source.class == "IsoWindow") then
        demolitionAllowed = buildCellSet[cellKey(x - 1, y, z)]
            or buildCellSet[cellKey(x, y - 1, z)]
    end

    local object = {
        templateIndex = index,
        x = x,
        y = y,
        z = z,
        class = source.class,
        name = source.name,
        sprite = source.sprite,
        north = source.north,
        direction = source.direction,
        state = source.state,
        protected = not demolitionAllowed,
    }
    objectsByIndex[index] = object

    local row = template.celldef[y]
    if not row then row = {}; template.celldef[y] = row end
    local cell = row[x]
    if not cell then cell = { layers = {} }; row[x] = cell end
    local layer = cell.layers[z]
    if not layer then layer = {}; cell.layers[z] = layer end
    layer[#layer + 1] = object
end

template.misc.roofTargets = compileRoofTargets(objectsByIndex,
    Source.buildCells)

local function cellCoordinates(x, y)
    return integer(x) and integer(y)
        and x >= RoomTemplate.MIN_X and x < RoomTemplate.MAX_X_EXCLUSIVE
        and y >= RoomTemplate.MIN_Y and y < RoomTemplate.MAX_Y_EXCLUSIVE
end

function RoomTemplate.supportsZ(z)
    return integer(z) and z >= RoomTemplate.MIN_Z
        and z < RoomTemplate.MAX_Z_EXCLUSIVE
end

function RoomTemplate.get(templateId)
    if templateId == RoomTemplate.TEMPLATE_ID then return template end
    return nil
end

function RoomTemplate.cellAt(value, x, y)
    if not cellCoordinates(x, y) then return nil end
    local row = value.celldef[y]
    return row and row[x] or nil
end

function RoomTemplate.hasLayer(value, x, y, z)
    if not RoomTemplate.supportsZ(z) then return false end
    local cell = RoomTemplate.cellAt(value, x, y)
    return cell ~= nil and cell.layers[z] ~= nil
end

function RoomTemplate.roofTargets(value)
    return value.misc.roofTargets
end

function RoomTemplate.orderedObjects(value)
    return objectsByIndex
end

return RoomTemplate
