-- Current shared template data and pure queries.
local Source = require "RailroaderRV/RoomTemplate/RV_Template"

local RoomTemplate = {}

RoomTemplate.TEMPLATE_ID = "railroader-rv"
RoomTemplate.ENGINE_AREA_TEMPLATE_ID = "railroader-rv-engine-area"
RoomTemplate.CURRENT_TEMPLATE_VERSION = 11
RoomTemplate.WIDTH = 100
RoomTemplate.HEIGHT = 100
RoomTemplate.MIN_X = -50
RoomTemplate.MIN_Y = -50
RoomTemplate.MAX_X_EXCLUSIVE = 50
RoomTemplate.MAX_Y_EXCLUSIVE = 50
RoomTemplate.MIN_Z = -32
RoomTemplate.MAX_Z_EXCLUSIVE = 32
RoomTemplate.PROXY_ROLES = { power = "generator", water = "water-proxy" }

local templates = {}

function RoomTemplate.register(value)
    local id = value.metadata.id
    if templates[id] then
        error("RailroaderRV: duplicate RV template id " .. tostring(id))
    end
    templates[id] = value
    return value
end

local function integer(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
        and math.floor(value) == value
end

local function cellKey(x, y, z)
    return tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
end

local roofCells = Source.roofCells

local function compileBuildCells(rectangles)
    local buildCells = {}
    for index = 1, #rectangles do
        local rectangle = rectangles[index]
        for y = rectangle.minY, rectangle.maxYExclusive - 1 do
            for x = rectangle.minX, rectangle.maxXExclusive - 1 do
                buildCells[#buildCells + 1] = { x = x, y = y }
            end
        end
    end
    return buildCells
end

local function compileTemplate(templateId, buildCells, waterProxies,
    buildRects)
    local buildCellSet = {}
    for index = 1, #buildCells do
        local cell = buildCells[index]
        buildCellSet[cellKey(cell.x, cell.y,
            cell.z == nil and 0 or cell.z)] = true
    end

    local value = {
        metadata = {
            id = templateId,
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
        powerProxy = Source.powerProxy,
        waterProxies = waterProxies,
        roofCells = roofCells,
        roofRefreshPoints = Source.roofRefreshPoints,
        celldef = {},
        objects = {},
        misc = {
            walkAabbs = Source.walkAabbs,
            buildCells = buildCells,
            buildRects = buildRects,
        },
    }

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
        value.objects[index] = object

        local row = value.celldef[y]
        if not row then row = {}; value.celldef[y] = row end
        local cell = row[x]
        if not cell then cell = { layers = {} }; row[x] = cell end
        local layer = cell.layers[z]
        if not layer then layer = {}; cell.layers[z] = layer end
        layer[#layer + 1] = object
    end

    RoomTemplate.register(value)
    return value
end

compileTemplate(RoomTemplate.TEMPLATE_ID, Source.buildCells,
    Source.waterProxies)
local engineAreaBuildCells = compileBuildCells(Source.engineAreaBuildRects)
compileTemplate(RoomTemplate.ENGINE_AREA_TEMPLATE_ID,
    engineAreaBuildCells, Source.engineAreaWaterProxies,
    Source.engineAreaBuildRects)

-- Every declared refresh point must name a real captured entry that sits on the
-- exact template coordinates the point declares.  Both sides are this mod's own
-- authored data, so a mismatch is a hard load failure.
local function validateRoofRefreshPoints(points, orderedObjects)
    if type(points) ~= "table" then
        error("RailroaderRV: template roof refresh points are missing")
    end
    for index = 1, #points do
        local point = points[index]
        local templateIndex = type(point) == "table"
            and point.templateIndex or nil
        local entry = templateIndex ~= nil
            and orderedObjects[templateIndex] or nil
        if not entry or entry.x ~= point.x or entry.y ~= point.y
            or entry.z ~= point.z then
            error("RailroaderRV: template roof refresh point "
                .. tostring(index) .. " does not match captured entry "
                .. "templateIndex=" .. tostring(templateIndex))
        end
    end
    return points
end

for _, templateId in ipairs({ RoomTemplate.TEMPLATE_ID,
    RoomTemplate.ENGINE_AREA_TEMPLATE_ID }) do
    local value = templates[templateId]
    validateRoofRefreshPoints(value.roofRefreshPoints, value.objects)
end

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
    local value = templates[templateId]
    if not value then
        error("RailroaderRV: unknown RV template id "
            .. tostring(templateId))
    end
    return value
end

function RoomTemplate.templateIdForEngineAreaBuilding(enabled)
    return enabled and RoomTemplate.ENGINE_AREA_TEMPLATE_ID
        or RoomTemplate.TEMPLATE_ID
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

function RoomTemplate.roofRefreshPoints(value)
    return value.roofRefreshPoints
end

function RoomTemplate.roofCells(value)
    return value.roofCells
end

function RoomTemplate.waterProxies(value)
    return value.waterProxies
end

function RoomTemplate.orderedObjects(value)
    return value.objects
end

return RoomTemplate
