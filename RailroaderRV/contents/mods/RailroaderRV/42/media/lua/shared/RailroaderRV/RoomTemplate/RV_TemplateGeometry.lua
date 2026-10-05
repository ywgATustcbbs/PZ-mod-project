-- Shared coordinate transforms for static RV templates.
--
-- Every logical RV owns one 100x100 XY region aligned to the world grid.
-- Template anchors sit at the center tile of that region; Z is supplied by
-- the caller because the XY region does not determine the RV's vertical level.
require "RailroaderRV/Common/RV_Constants"
local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"
local Constants = RailroaderRV.Constants

local G = {}
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local templateObjects = RoomTemplate.orderedObjects(Template)

G.REGION_SIZE = Constants.RV_REGION_SIZE
G.ANCHOR_OFFSET = math.floor(G.REGION_SIZE / 2)

local managedMinZOffset = math.huge
for index = 1, #templateObjects do
    managedMinZOffset = math.min(managedMinZOffset, templateObjects[index].z)
end
for index = 1, #Template.misc.walkAabbs do
    managedMinZOffset = math.min(managedMinZOffset,
        Template.misc.walkAabbs[index].minZ)
end
for index = 1, #Template.misc.buildCells do
    local cell = Template.misc.buildCells[index]
    managedMinZOffset = math.min(managedMinZOffset,
        cell.z == nil and Template.metadata.anchor.z or cell.z)
end

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
    return finiteNumber(value) and math.floor(value) == value
end

local function validPoint(point)
    return type(point) == "table"
        and finiteNumber(point.x) and finiteNumber(point.y)
        and finiteNumber(point.z)
end

local function validAnchor(anchor)
    if type(anchor) ~= "table" or not integer(anchor.x)
        or not integer(anchor.y) or not integer(anchor.z) then
        return false
    end
    local originX = math.floor(anchor.x / G.REGION_SIZE) * G.REGION_SIZE
    local originY = math.floor(anchor.y / G.REGION_SIZE) * G.REGION_SIZE
    return anchor.x == originX + G.ANCHOR_OFFSET
        and anchor.y == originY + G.ANCHOR_OFFSET
end

local function sameRegion(world, anchor)
    return math.floor(world.x / G.REGION_SIZE)
            == math.floor(anchor.x / G.REGION_SIZE)
        and math.floor(world.y / G.REGION_SIZE)
            == math.floor(anchor.y / G.REGION_SIZE)
end

function G.blockOriginForWorld(x, y)
    if not finiteNumber(x) or not finiteNumber(y) then return nil end
    return {
        x = math.floor(x / G.REGION_SIZE) * G.REGION_SIZE,
        y = math.floor(y / G.REGION_SIZE) * G.REGION_SIZE,
    }
end

function G.templateAnchorForWorld(x, y, z)
    if not finiteNumber(z) then return nil end
    local origin = G.blockOriginForWorld(x, y)
    if not origin then return nil end
    return {
        x = origin.x + G.ANCHOR_OFFSET,
        y = origin.y + G.ANCHOR_OFFSET,
        z = z,
    }
end

-- Convert a world position into the template's relative coordinate space.
-- A world point from a neighboring 100x100 region is rejected instead of
-- accidentally being interpreted against this RV's template.
function G.worldToTemplate(world, anchor)
    if not validPoint(world) or not validAnchor(anchor)
        or not sameRegion(world, anchor) then
        return nil
    end
    return {
        x = world.x - anchor.x,
        y = world.y - anchor.y,
        z = world.z - anchor.z,
    }
end

local function inBoxes(boxes, offset)
    if not offset then return false end
    for index = 1, #boxes do
        local box = boxes[index]
        if offset.x >= box.minX and offset.x < box.maxX
            and offset.y >= box.minY and offset.y < box.maxY
            and offset.z >= box.minZ and offset.z < box.maxZExclusive then
            return true
        end
    end
    return false
end

function G.contains(world, anchor, template)
    template = template or Template
    local offset = G.worldToTemplate(world, anchor)
    if not offset then
        return false
    end
    local x, y, z = math.floor(offset.x), math.floor(offset.y),
        math.floor(offset.z)
    if not RoomTemplate.supportsZ(z) then return false end
    return RoomTemplate.hasLayer(template, x, y, z)
end

function G.isWalkable(world, anchor, template)
    template = template or Template
    local offset = G.worldToTemplate(world, anchor)
    if not offset then return false end
    local tile = { x = math.floor(offset.x), y = math.floor(offset.y),
        z = math.floor(offset.z) }
    return inBoxes(template.misc.walkAabbs, tile)
        and RoomTemplate.hasLayer(template, tile.x, tile.y, tile.z)
end

function G.isBuildable(world, anchor, template)
    template = template or Template
    local offset = G.worldToTemplate(world, anchor)
    if not offset then return false end
    local tile = { x = math.floor(offset.x), y = math.floor(offset.y),
        z = math.floor(offset.z) }
    for index, cell in ipairs(template.misc.buildCells) do
        local cellZ = cell.z == nil and template.metadata.anchor.z or cell.z
        if cell.x == tile.x and cell.y == tile.y and cellZ == tile.z then
            return true, index
        end
    end
    return false
end

function G.isBuildCellSideHost(world, anchor, template)
    template = template or Template
    local offset = G.worldToTemplate(world, anchor)
    if not offset then return false end
    local x, y, z = math.floor(offset.x), math.floor(offset.y),
        math.floor(offset.z)
    for index, cell in ipairs(template.misc.buildCells) do
        local cellZ = cell.z == nil and template.metadata.anchor.z or cell.z
        if z == cellZ and ((x == cell.x + 1 and y == cell.y)
            or (x == cell.x and y == cell.y + 1)) then
            return true, index
        end
    end
    return false
end

function G.inManagedRegion(world, managed)
    return validPoint(world)
        and world.x >= managed.originX
        and world.x < managed.originX + managed.width
        and world.y >= managed.originY
        and world.y < managed.originY + managed.height
        and math.floor(world.z) >= managed.minZ
        and math.floor(world.z) < managed.maxZ
end

function G.anchorFromManaged(managed, template)
    template = template or Template
    return {
        x = managed.originX - template.metadata.minX,
        y = managed.originY - template.metadata.minY,
        z = managed.minZ - managedMinZOffset,
    }
end

function G.isWalkableInManagedRegion(world, managed, template)
    template = template or Template
    local anchor = G.anchorFromManaged(managed, template)
    return G.isWalkable(world, anchor, template)
end

function G.edgeKey(axis, x, y, z)
    axis = axis == "N" and "N" or axis == "W" and "W" or nil
    if not axis or not integer(x) or not integer(y) or not integer(z) then
        return nil
    end
    return axis .. ":" .. tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
end

function G.edgeForSide(side, x, y, z)
    if not integer(x) or not integer(y) or not integer(z) then return nil end
    if side == "north" or side == "N" then
        return G.edgeKey("N", x, y, z)
    elseif side == "west" or side == "W" then
        return G.edgeKey("W", x, y, z)
    elseif side == "east" or side == "E" then
        return G.edgeKey("W", x + 1, y, z)
    elseif side == "south" or side == "S" then
        return G.edgeKey("N", x, y + 1, z)
    end
    return nil
end

function G.lookupObjectByIndex(templateIndex, template)
    template = template or Template
    if not integer(templateIndex) or templateIndex < 1 then
        return nil
    end
    local templateObjects = RoomTemplate.orderedObjects(template)
    local object = templateObjects[templateIndex]
    return object, templateIndex
end

function G.lookupObjectsAtTemplate(x, y, z, template)
    template = template or Template
    if not integer(x) or not integer(y) or not integer(z) then
        return nil
    end
    local cell = RoomTemplate.cellAt(template, x, y)
    local layer = cell and cell.layers[z]
    local matches = {}
    for index = 1, #(layer or {}) do
        local object = layer[index]
        matches[#matches + 1] = {
            index = object.templateIndex,
            object = object,
        }
    end
    return matches
end

function G.lookupObjectsAtWorld(world, anchor, template)
    local offset = G.worldToTemplate(world, anchor)
    if not offset or not integer(offset.x)
        or not integer(offset.y) or not integer(offset.z) then
        return nil
    end
    return G.lookupObjectsAtTemplate(offset.x, offset.y, offset.z, template)
end

return G
