-- Shared coordinate transforms for static RV templates.
--
-- Every logical RV owns one 100x100 XY region aligned to the world grid.
-- Template anchors sit at the center tile of that region; Z is supplied by
-- the caller because the XY region does not determine the RV's vertical level.
require "RailroaderRV/RV_Constants"
local Template = require "RailroaderRV/RV_Template"
local ProtectionManifest = require "RailroaderRV/RV_ProtectionManifest"
local Constants = RailroaderRV.Constants

local G = {}

G.REGION_SIZE = Constants.RV_REGION_SIZE
G.ANCHOR_OFFSET = 50

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

function G.templateToWorld(offset, anchor)
    if not validPoint(offset) or not validAnchor(anchor) then return nil end
    local world = {
        x = anchor.x + offset.x,
        y = anchor.y + offset.y,
        z = anchor.z + offset.z,
    }
    if not sameRegion(world, anchor) then return nil end
    return world
end

local function validTemplate(template)
    return type(template) == "table" and type(template.objects) == "table"
end

function G.lookupObjectByIndex(templateIndex, template, manifest)
    template = template or Template
    if not validTemplate(template) or not integer(templateIndex)
        or templateIndex < 1 then
        return nil
    end
    local object = template.objects[templateIndex]
    if type(object) ~= "table" then return nil end
    if template == Template then manifest = manifest or ProtectionManifest end
    local protection = type(manifest) == "table"
        and type(manifest.get) == "function" and manifest.get(templateIndex) or nil
    -- Return the index alongside the row so callers can distinguish several
    -- template objects which occupy the same tile. The optional third result
    -- reuses the protection manifest's existing index lookup.
    return object, templateIndex, protection
end

function G.lookupObjectsAtTemplate(x, y, z, template, manifest)
    template = template or Template
    if not validTemplate(template) or not integer(x)
        or not integer(y) or not integer(z) then
        return nil
    end
    if template == Template then manifest = manifest or ProtectionManifest end
    local matches = {}
    for index, object in ipairs(template.objects) do
        if object.x == x and object.y == y and object.z == z then
            local protection = type(manifest) == "table"
                and type(manifest.get) == "function" and manifest.get(index) or nil
            matches[#matches + 1] = {
                index = index,
                object = object,
                protection = protection,
            }
        end
    end
    return matches
end

function G.lookupObjectsAtWorld(world, anchor, template, manifest)
    local offset = G.worldToTemplate(world, anchor)
    if not offset or not integer(offset.x)
        or not integer(offset.y) or not integer(offset.z) then
        return nil
    end
    return G.lookupObjectsAtTemplate(offset.x, offset.y, offset.z, template, manifest)
end

function G.cabContainsWorld(world, anchor, template)
    template = template or Template
    if not validTemplate(template) or type(template.buildCells) ~= "table" then
        return false
    end
    local offset = G.worldToTemplate(world, anchor)
    if not offset or offset.z ~= 0 then return false end
    for index, cell in ipairs(template.buildCells) do
        if type(cell) == "table" and cell.x == offset.x and cell.y == offset.y then
            return true, index
        end
    end
    return false
end

return G
