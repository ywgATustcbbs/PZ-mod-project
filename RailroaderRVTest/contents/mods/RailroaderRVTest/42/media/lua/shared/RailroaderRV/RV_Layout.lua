-- Pure, shared coordinate planning for the RailroaderRV technical test.
--
-- No function in this file mutates a square or reads a client-supplied
-- coordinate.  Server code supplies the shared fixed target anchor and
-- applies the returned plan only after validating the requesting player.

require "RailroaderRV/RV_Constants"
local Bitmap = require "RailroaderRV/RV_Bitmap"
local Template = require "RailroaderRV/RV_Template"

RailroaderRV = RailroaderRV or {}
RailroaderRV.Layout = RailroaderRV.Layout or {}

local Layout = RailroaderRV.Layout
local C = RailroaderRV.Constants

if type(Template) ~= "table" or Template.schemaVersion ~= C.CAPTURED_TEMPLATE_VERSION
    or type(Template.objects) ~= "table"
    or Template.objectCount ~= #Template.objects
    or Template.objectCount ~= 357
    or type(Template.buildCells) ~= "table" or #Template.buildCells ~= 24 then
    error("RailroaderRV: captured user template contract is incomplete")
end

local buildCellSet = {}
for i = 1, #Template.buildCells do
    local cell = Template.buildCells[i]
    if type(cell) ~= "table" or type(cell.x) ~= "number"
        or type(cell.y) ~= "number" or math.floor(cell.x) ~= cell.x
        or math.floor(cell.y) ~= cell.y
        or cell.x < C.CAB_MIN_OFFSET_X or cell.x > C.CAB_MAX_OFFSET_X
        or cell.y < C.CAB_MIN_OFFSET_Y or cell.y > C.CAB_MAX_OFFSET_Y then
        error("RailroaderRV: captured cab build cell is outside the 6x4 contract")
    end
    local key = tostring(cell.x) .. ":" .. tostring(cell.y)
    if buildCellSet[key] then
        error("RailroaderRV: captured cab build cell is duplicated")
    end
    buildCellSet[key] = true
end
for x = C.CAB_MIN_OFFSET_X, C.CAB_MAX_OFFSET_X do
    for y = C.CAB_MIN_OFFSET_Y, C.CAB_MAX_OFFSET_Y do
        if not buildCellSet[tostring(x) .. ":" .. tostring(y)] then
            error("RailroaderRV: captured cab build mask is not a complete 6x4 rectangle")
        end
    end
end

Layout.SCHEMA_VERSION = C.LAYOUT_SCHEMA_VERSION

function Layout.eachStructureCoordinate(bounds, callback)
    for x = bounds.wallMinX, bounds.wallMaxX do
        for y = bounds.wallMinY, bounds.wallMaxY do
            callback(x, y, bounds.z)
        end
    end
    local anchorX = bounds.roofMinX - C.INTERIOR_MIN_OFFSET_X
    local anchorY = bounds.roofMinY - C.INTERIOR_MIN_OFFSET_Y
    local seen = {}
    for i = 1, #Template.objects do
        local captured = Template.objects[i]
        if captured.z == C.ROOF_Z_OFFSET then
            local x, y = anchorX + captured.x, anchorY + captured.y
            local key = tostring(x) .. ":" .. tostring(y) .. ":"
                .. tostring(bounds.roofZ)
            if not seen[key] then
                seen[key] = true
                callback(x, y, bounds.roofZ)
            end
        end
    end
end

local function point(x, y, z)
    return { x = x, y = y, z = z }
end

local function rectangle(minX, maxX, minY, maxY, z, minZ, maxZ, halfOpen)
    return {
        minX = minX,
        maxX = maxX,
        minY = minY,
        maxY = maxY,
        z = z,
        minZ = minZ,
        maxZ = maxZ,
        halfOpen = halfOpen == true,
    }
end

local function offsetPoint(anchor, offset)
    return point(anchor.x + offset.x, anchor.y + offset.y, anchor.z + offset.z)
end

local function appendWall(result, x, y, z, north, sprite, role, corner)
    local axis = north == true and "N" or "W"
    result[#result + 1] = {
        x = x,
        y = y,
        z = z,
        north = north,
        sprite = sprite,
        role = role,
        corner = corner == true,
        edgeNorth = north == true,
        edgeWest = north == false,
        axis = axis,
        edgeKey = Bitmap.edgeKey(axis, x, y, z),
    }
end

local function isShellSprite(entry)
    local sprite = tostring(entry.sprite or "")
    return sprite:sub(1, 6) == "walls_"
        or sprite:sub(1, 21) == "fixtures_railings_01_"
        or sprite:sub(1, 17) == "fixtures_windows_"
        or sprite:sub(1, 31) == "location_restaurant_pileocrepe_"
end

local function shellPriority(entry)
    if entry.name == "Wooden Wall" then return 1 end
    if entry.sprite:sub(1, 21) == "fixtures_railings_01_" then return 2 end
    if entry.sprite:sub(1, 17) == "fixtures_windows_" then return 3 end
    if entry.name == "Wooden Door Frame" then return 4 end
    if entry.name == "Wooden Door" then return 5 end
    return 6
end

-- The edge ledger represents only captured shell objects.  The hand-built
-- model has four open/missing edge slots, so those are kept open instead of
-- filled with a synthetic wall.  Multiple captured objects can share one
-- edge host (for example a wall and railing); choose the wall/railing object
-- deterministically for edge ownership while generation still creates every
-- object from the full captured table.
local function wallCoordinatesForAnchor(cx, cy, cz)
    local result = {}
    local interiorMinX = cx + C.INTERIOR_MIN_OFFSET_X
    local interiorMaxX = cx + C.INTERIOR_MAX_OFFSET_X
    local interiorMinY = cy + C.INTERIOR_MIN_OFFSET_Y
    local interiorMaxY = cy + C.INTERIOR_MAX_OFFSET_Y

    local function addCapturedEdge(side, x, y, north)
        local candidates = {}
        for i = 1, #Template.objects do
            local captured = Template.objects[i]
            if captured.x == x - cx and captured.y == y - cy
                and captured.z == 0
                and (captured.class == "IsoThumpable" or captured.class == "IsoWindow")
                and captured.north == north and isShellSprite(captured) then
                candidates[#candidates + 1] = { index = i, object = captured }
            end
        end
        table.sort(candidates, function(left, right)
            local leftPriority = shellPriority(left.object)
            local rightPriority = shellPriority(right.object)
            if leftPriority == rightPriority then return left.index < right.index end
            return leftPriority < rightPriority
        end)
        if #candidates == 0 then return end
        local selected = candidates[1]
        local corner = side == "north" and x == interiorMinX
            and y == interiorMinY
        local role = corner and "corner-nw"
            or ((side == "north" or side == "south") and "wall-north" or "wall-west")
        appendWall(result, x, y, cz, north, selected.object.sprite, role, corner)
        result[#result].templateIndex = selected.index
        result[#result].templateIndices = {}
        for i = 1, #candidates do
            result[#result].templateIndices[i] = candidates[i].index
        end
    end

    for x = interiorMinX, interiorMaxX do
        addCapturedEdge("north", x, interiorMinY, true)
    end
    for y = interiorMinY + 1, interiorMaxY do
        addCapturedEdge("west", interiorMinX, y, false)
    end
    for y = interiorMinY, interiorMaxY do
        addCapturedEdge("east", interiorMaxX + 1, y, false)
    end
    for x = interiorMinX, interiorMaxX do
        addCapturedEdge("south", x, interiorMaxY + 1, true)
    end
    addCapturedEdge("south", interiorMaxX + 1, interiorMaxY + 1, false)
    return result
end

-- The wall object's square and the owned boundary edge are separate facts.
-- In particular the east wall is hosted by W(x+1,y,z), and the south wall
-- is hosted by N(x,y+1,z), where x/y are the adjacent interior cell. Keep
-- the canonical edge metadata on every generated entry for later tagging and
-- cleanup; never infer it back from an inactive tile at audit time.
local function annotateWallEdges(wallCoordinates, cx, cy)
    local interiorMaxX = cx + C.INTERIOR_MAX_OFFSET_X
    local interiorMaxY = cy + C.INTERIOR_MAX_OFFSET_Y
    for i = 1, #wallCoordinates do
        local entry = wallCoordinates[i]
        local side, cellX, cellY
        if entry.north then
            if entry.y == interiorMaxY + 1 then
                side, cellX, cellY = "south", entry.x, entry.y - 1
            else
                side, cellX, cellY = "north", entry.x, entry.y
            end
        elseif entry.x == interiorMaxX + 1 then
            side, cellX, cellY = "east", entry.x - 1, entry.y
        else
            side, cellX, cellY = "west", entry.x, entry.y
        end
        local edgeKey = Bitmap.edgeForSide(side, cellX, cellY, entry.z)
        if not edgeKey then
            error("RailroaderRV: wall edge metadata is malformed")
        end
        entry.edgeSide = side
        entry.edgeCellX, entry.edgeCellY = cellX, cellY
        entry.edgeHostX = side == "east" and cellX + 1 or cellX
        entry.edgeHostY = side == "south" and cellY + 1 or cellY
        entry.edgeKey = edgeKey
    end
end

-- Build one complete plan from the supplied integer map-cell anchor.  The
-- server passes the shared fixed teleport target as this anchor; callers must
-- not derive the generation anchor from client coordinates.
function Layout.make(cx, cy, cz)
    cx = math.floor(cx)
    cy = math.floor(cy)
    cz = math.floor(cz)

    local clear = rectangle(
        cx + C.CLEAR_MIN_OFFSET_X,
        cx + C.CLEAR_MAX_OFFSET_X,
        cy + C.CLEAR_MIN_OFFSET_Y,
        cy + C.CLEAR_MAX_OFFSET_Y,
        nil,
        cz + C.RV_MANAGED_MIN_Z_OFFSET,
        cz + C.RV_MANAGED_MAX_Z_OFFSET,
        true
    )
    local managed = Bitmap.makeScope(
        cx + C.RV_REGION_MIN_OFFSET_X,
        cy + C.RV_REGION_MIN_OFFSET_Y,
        cz + C.RV_MANAGED_MIN_Z_OFFSET,
        cz + C.RV_MANAGED_MAX_Z_OFFSET,
        C.RV_MANAGED_WIDTH,
        C.RV_MANAGED_HEIGHT
    )
    local bitmap = {
        schemaVersion = Bitmap.SCHEMA_VERSION,
        bitmapVersion = C.BITMAP_VERSION,
        originX = managed.originX,
        originY = managed.originY,
        width = managed.width,
        height = managed.height,
        minZ = managed.minZ,
        maxZ = managed.maxZ,
        layers = {},
        encoding = "bytes",
    }
    -- Activity is the full six-by-twenty-three base footprint. Buildability
    -- is the explicit six-by-four cab; the roof layer is neither walkable nor
    -- buildable.
    for z = managed.minZ, managed.maxZ - 1 do
        local layer = Bitmap.newLayer(managed.width, managed.height, false, false)
        if z == cz then
            for y = cy + C.INTERIOR_MIN_OFFSET_Y,
                cy + C.INTERIOR_MAX_OFFSET_Y do
                for x = cx + C.INTERIOR_MIN_OFFSET_X,
                    cx + C.INTERIOR_MAX_OFFSET_X do
                    local ix, iy = x - managed.originX, y - managed.originY
                    Bitmap.setCell(layer, ix, iy, true, managed.width,
                        managed.height, "walk")
                end
            end
            for i = 1, #Template.buildCells do
                local cell = Template.buildCells[i]
                local x, y = cx + cell.x, cy + cell.y
                Bitmap.setCell(layer, x - managed.originX, y - managed.originY,
                    true, managed.width, managed.height, "build")
            end
        end
        bitmap.layers[z] = layer
    end

    local interior = rectangle(
        cx + C.INTERIOR_MIN_OFFSET_X,
        cx + C.INTERIOR_MAX_OFFSET_X,
        cy + C.INTERIOR_MIN_OFFSET_Y,
        cy + C.INTERIOR_MAX_OFFSET_Y,
        cz
    )
    local wall = rectangle(
        cx + C.WALL_MIN_OFFSET_X,
        cx + C.WALL_MAX_OFFSET_X,
        cy + C.WALL_MIN_OFFSET_Y,
        cy + C.WALL_MAX_OFFSET_Y,
        cz
    )
    local roof = rectangle(
        interior.minX,
        interior.maxX,
        interior.minY,
        interior.maxY,
        cz + C.ROOF_Z_OFFSET
    )
    local wallCoordinates = wallCoordinatesForAnchor(cx, cy, cz)
    annotateWallEdges(wallCoordinates, cx, cy)
    local northCount, cornerCount = 0, 0
    for i = 1, #wallCoordinates do
        if wallCoordinates[i].north then northCount = northCount + 1 end
        if wallCoordinates[i].corner then cornerCount = cornerCount + 1 end
    end

    local anchor = {
        x = cx,
        y = cy,
        z = cz,
    }

    local shellEdges = {}
    for i = 1, #wallCoordinates do
        local entry = wallCoordinates[i]
        local axis = (entry.edgeSide == "north" or entry.edgeSide == "south")
            and "N" or "W"
        local edgeKey = entry.edgeKey
        if not edgeKey or shellEdges[edgeKey] then
            error("RailroaderRV: duplicate or malformed shell edge "
                .. tostring(edgeKey))
        end
        entry.axis = axis
        shellEdges[edgeKey] = {
            edgeKey = edgeKey,
            rvId = nil,
            generation = nil,
            hostX = entry.edgeHostX,
            hostY = entry.edgeHostY,
            z = entry.z,
            axis = axis,
            side = entry.edgeSide,
            objectX = entry.x,
            objectY = entry.y,
            objectZ = entry.z,
            role = entry.role,
            corner = entry.corner == true,
            replacementAllowed = true,
            templateIndex = entry.templateIndex,
            templateIndices = {},
            sprite = entry.sprite,
            north = entry.north,
        }
        for partIndex = 1, #entry.templateIndices do
            shellEdges[edgeKey].templateIndices[partIndex] =
                entry.templateIndices[partIndex]
        end
    end

    local result = {
        schemaVersion = Layout.SCHEMA_VERSION,
        anchor = anchor,
        clear = clear,
        managed = managed,
        bitmap = bitmap,
        shellEdges = shellEdges,
        templateObjects = {},
        room = interior,
        wall = wall,
        roof = roof,
        wallCoordinates = wallCoordinates,
        generator = offsetPoint(anchor, C.GENERATOR_OFFSET),
    }
    result.wallCount = #wallCoordinates
    result.wallObjectCount = #wallCoordinates
    result.wallCoordinateCount = #wallCoordinates
    result.wallEdgeCounts = { north = northCount, west = #wallCoordinates - northCount }
    result.wallCornerCount = cornerCount
    for i = 1, #Template.objects do
        local captured = Template.objects[i]
        local copy = {
            templateIndex = i,
            class = captured.class,
            name = captured.name,
            sprite = captured.sprite,
            direction = captured.direction,
            x = cx + captured.x,
            y = cy + captured.y,
            z = cz + captured.z,
            north = captured.north,
            state = captured.state,
        }
        result.templateObjects[i] = copy
    end
    return result
end

return Layout
