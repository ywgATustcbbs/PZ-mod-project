-- Pure, shared coordinate planning for the RailroaderRV technical test.
--
-- No function in this file mutates a square or reads a client-supplied
-- coordinate. Server code supplies the anchor of an allocated matrix slot and
-- applies the returned plan only after validating the requesting player.

require "RailroaderRV/Common/RV_Constants"
local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"
local TemplateGeometry = require "RailroaderRV/RoomTemplate/RV_TemplateGeometry"

RailroaderRV = RailroaderRV or {}
RailroaderRV.Layout = RailroaderRV.Layout or {}

local Layout = RailroaderRV.Layout
local C = RailroaderRV.Constants
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local templateObjects = RoomTemplate.orderedObjects(Template)
local walkAabbs = Template.misc.walkAabbs

-- The physical room/wall plan currently describes the primary rectangular
-- shell. Queries use all walk regions and generation still emits every object.
local walkGeometry = walkAabbs[1]
local roofZOffset = -math.huge
for i = 1, #templateObjects do
    roofZOffset = math.max(roofZOffset, templateObjects[i].z)
end
function Layout.eachStructureCoordinate(bounds, callback)
    for x = bounds.wallMinX, bounds.wallMaxX do
        for y = bounds.wallMinY, bounds.wallMaxY do
            callback(x, y, bounds.z)
        end
    end
    local anchorX = bounds.roomMinX - walkGeometry.minX
    local anchorY = bounds.roomMinY - walkGeometry.minY
    local seen = {}
    for i = 1, #templateObjects do
        local captured = templateObjects[i]
        if captured.z == roofZOffset then
            local x, y = anchorX + captured.x, anchorY + captured.y
            if x >= bounds.roofMinX and x <= bounds.roofMaxX
                and y >= bounds.roofMinY and y <= bounds.roofMaxY then
                local key = tostring(x) .. ":" .. tostring(y) .. ":"
                    .. tostring(bounds.roofZ)
                if not seen[key] then
                    seen[key] = true
                    callback(x, y, bounds.roofZ)
                end
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
        edgeKey = TemplateGeometry.edgeKey(axis, x, y, z),
    }
end

local function isShellSprite(entry)
    return entry.sprite:sub(1, 6) == "walls_"
        or entry.sprite:sub(1, 21) == "fixtures_railings_01_"
        or entry.sprite:sub(1, 17) == "fixtures_windows_"
        or entry.sprite:sub(1, 31) == "location_restaurant_pileocrepe_"
end

local function shellPriority(entry)
    if entry.name == "Wooden Wall" then return 1 end
    if entry.sprite:sub(1, 21) == "fixtures_railings_01_" then return 2 end
    if entry.sprite:sub(1, 17) == "fixtures_windows_" then return 3 end
    if entry.name == "Wooden Door Frame" then return 4 end
    if entry.name == "Wooden Door" then return 5 end
    return 6
end

-- The edge ledger represents captured shell objects and captured invisible
-- wall supports that close gaps.
-- Multiple captured objects can share one edge host (for example a wall and
-- railing); choose the wall/railing object deterministically for edge
-- ownership while generation still creates every object from the full
-- captured table.
local function wallCoordinatesForAnchor(cx, cy, cz, interior)
    local result = {}
    local interiorMinX = interior.minX
    local interiorMaxX = interior.maxX
    local interiorMinY = interior.minY
    local interiorMaxY = interior.maxY

    local function addCapturedEdge(side, x, y, north)
        local candidates = {}
        for i = 1, #templateObjects do
            local captured = templateObjects[i]
            if captured.x == x - cx and captured.y == y - cy
                and captured.z == interior.z - cz
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
            or (north and "wall-north" or "wall-west")
        appendWall(result, x, y, interior.z, north, selected.object.sprite, role, corner)
        result[#result].templateIndex = selected.index
        result[#result].templateIndices = {}
        for i = 1, #candidates do
            result[#result].templateIndices[i] = candidates[i].index
        end
    end

    for x = interiorMinX, interiorMaxX do
        addCapturedEdge("north", x, interiorMinY, true)
    end
    for y = interiorMinY, interiorMaxY do
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
local function annotateWallEdges(wallCoordinates, interior)
    local interiorMaxX = interior.maxX
    local interiorMaxY = interior.maxY
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
        local edgeKey = TemplateGeometry.edgeForSide(side, cellX, cellY, entry.z)
        entry.edgeSide = side
        entry.edgeCellX, entry.edgeCellY = cellX, cellY
        entry.edgeHostX = side == "east" and cellX + 1 or cellX
        entry.edgeHostY = side == "south" and cellY + 1 or cellY
        entry.edgeKey = edgeKey
    end
end

-- Build one complete plan from the supplied integer map-cell anchor.  The
-- server passes the selected slot anchor as this coordinate; callers must
-- not derive the generation anchor from client coordinates.
function Layout.make(cx, cy, cz)
    cx = math.floor(cx)
    cy = math.floor(cy)
    cz = math.floor(cz)

    local managedMinZ, managedMaxZ = nil, nil
    local function includeZ(minZ, maxZ)
        managedMinZ = managedMinZ == nil and minZ or math.min(managedMinZ, minZ)
        managedMaxZ = managedMaxZ == nil and maxZ or math.max(managedMaxZ, maxZ)
    end
    for index = 1, #templateObjects do
        local object = templateObjects[index]
        includeZ(object.z, object.z + 1)
    end
    for index = 1, #Template.misc.walkAabbs do
        local box = Template.misc.walkAabbs[index]
        includeZ(box.minZ, box.maxZExclusive)
    end
    for index = 1, #Template.misc.buildCells do
        local cell = Template.misc.buildCells[index]
        local z = cell.z == nil and Template.metadata.anchor.z or cell.z
        includeZ(z, z + 1)
    end

    local managed = {
        originX = cx + Template.metadata.minX,
        originY = cy + Template.metadata.minY,
        width = Template.metadata.width,
        height = Template.metadata.height,
        minZ = cz + managedMinZ,
        maxZ = cz + managedMaxZ,
    }
    local clear = rectangle(
        managed.originX,
        managed.originX + managed.width,
        managed.originY,
        managed.originY + managed.height,
        nil,
        managed.minZ,
        managed.maxZ,
        true
    )
    local interior = rectangle(
        cx + walkGeometry.minX,
        cx + walkGeometry.maxX - 1,
        cy + walkGeometry.minY,
        cy + walkGeometry.maxY - 1,
        cz + walkGeometry.minZ
    )
    local wall = rectangle(
        interior.minX,
        interior.maxX + 1,
        interior.minY,
        interior.maxY + 1,
        interior.z
    )
    local roof = rectangle(
        interior.minX,
        interior.maxX,
        interior.minY,
        interior.maxY,
        cz + roofZOffset
    )
    local wallCoordinates = wallCoordinatesForAnchor(cx, cy, cz, interior)
    annotateWallEdges(wallCoordinates, interior)
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
        anchor = anchor,
        clear = clear,
        managed = managed,
        shellEdges = shellEdges,
        templateObjects = {},
        room = interior,
        wall = wall,
        roof = roof,
        wallCoordinates = wallCoordinates,
        generator = offsetPoint(anchor, C.GENERATOR_OFFSET),
    }
    result.wallObjectCount = #wallCoordinates
    result.wallCoordinateCount = #wallCoordinates
    result.wallEdgeCounts = { north = northCount, west = #wallCoordinates - northCount }
    result.wallCornerCount = cornerCount
    for i = 1, #templateObjects do
        local captured = templateObjects[i]
        local copy = {
            templateIndex = i,
            class = captured.class,
            name = captured.name,
            sprite = captured.sprite,
            direction = captured.direction,
            protected = captured.protected,
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
