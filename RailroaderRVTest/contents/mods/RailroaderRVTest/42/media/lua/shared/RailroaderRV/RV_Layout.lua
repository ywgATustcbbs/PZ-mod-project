-- Pure, shared coordinate planning for the RailroaderRV technical test.
--
-- No function in this file mutates a square or reads a client-supplied
-- coordinate.  Server code supplies the shared fixed target anchor and
-- applies the returned plan only after validating the requesting player.

require "RailroaderRV/RV_Constants"
local Bitmap = require "RailroaderRV/RV_Bitmap"

RailroaderRV = RailroaderRV or {}
RailroaderRV.Layout = RailroaderRV.Layout or {}

local Layout = RailroaderRV.Layout
local C = RailroaderRV.Constants

Layout.SCHEMA_VERSION = C.LAYOUT_SCHEMA_VERSION

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

-- The wall list is intentionally explicit.  It represents a one-cell wall
-- ring around the six-by-forty net interior rather than a generic rectangle
-- perimeter.  PZ's WallNW/WallSE single strips occupy the two diagonal corner
-- coordinates; the other edges use the paired WallW/WallN straight sprites:
--
-- [NW][N][N][N][N][N][W]
-- [W] [ ][ ][ ][ ][ ][W]
-- [W] [ ][ ][ ][ ][ ][W]
-- ... 38 further interior rows ...
-- [W] [ ][ ][ ][ ][ ][W]
-- [N] [N][N][N][N][N][SE]
--
-- The 92 entries are all unique: two single corner strips, 11 north-facing
-- straight walls (5 top + 6 bottom), and 79 west-facing straight walls
-- (39 west edge + 40 east edge).  The NW/SE corner strips add one entry to
-- each orientation, so the complete list contains 12 north-oriented and 80
-- west-oriented entries.
local function wallCoordinatesForAnchor(cx, cy, cz)
    local result = {}
    local northSprite = C.SPRITES.wall.northSprite
    local westSprite = C.SPRITES.wall.sprite
    local nwSprite = C.SPRITES.wallNW.sprite
    local seSprite = C.SPRITES.wallSE.sprite

    local interiorMinX = cx + C.INTERIOR_MIN_OFFSET_X
    local interiorMaxX = cx + C.INTERIOR_MAX_OFFSET_X
    local interiorMinY = cy + C.INTERIOR_MIN_OFFSET_Y
    local interiorMaxY = cy + C.INTERIOR_MAX_OFFSET_Y
    local wallMinX = cx + C.WALL_MIN_OFFSET_X
    local wallMaxX = cx + C.WALL_MAX_OFFSET_X
    local wallMinY = cy + C.WALL_MIN_OFFSET_Y
    local wallMaxY = cy + C.WALL_MAX_OFFSET_Y

    appendWall(result, wallMinX, wallMinY, cz, true, nwSprite, "corner-nw", true)
    for x = interiorMinX + 1, interiorMaxX do
        appendWall(result, x, interiorMinY, cz, true, northSprite, "wall-north")
    end
    for y = interiorMinY + 1, interiorMaxY do
        appendWall(result, wallMinX, y, cz, false, westSprite, "wall-west")
    end
    for y = interiorMinY, interiorMaxY do
        appendWall(result, wallMaxX, y, cz, false, westSprite, "wall-west")
    end
    for x = interiorMinX, interiorMaxX do
        appendWall(result, x, wallMaxY, cz, true, northSprite, "wall-north")
    end
    appendWall(result, wallMaxX, wallMaxY, cz, false, seSprite, "corner-se", true)
    return result
end

-- Validate the wall ring as a set of oriented wall placements.  Every
-- coordinate is unique because the NW/SE corner strips are single objects;
-- the exact coordinate+orientation+role key is still kept as a defensive
-- assertion so a role collision cannot be hidden by a reused coordinate.
local function validateWallCoordinates(wallCoordinates, cx, cy, cz)
    local coordinateKeys = {}
    local orientationKeys = {}
    local exactKeys = {}
    local orientationByCoordinate = {}
    local northCount, westCount, cornerCount = 0, 0, 0
    local nwKey = tostring(cx + C.WALL_MIN_OFFSET_X) .. ":"
        .. tostring(cy + C.WALL_MIN_OFFSET_Y) .. ":" .. tostring(cz)
    local seKey = tostring(cx + C.WALL_MAX_OFFSET_X) .. ":"
        .. tostring(cy + C.WALL_MAX_OFFSET_Y) .. ":" .. tostring(cz)
    for i = 1, #wallCoordinates do
        local entry = wallCoordinates[i]
        if type(entry) ~= "table" or type(entry.x) ~= "number"
            or type(entry.y) ~= "number" or type(entry.z) ~= "number"
            or type(entry.north) ~= "boolean" or type(entry.role) ~= "string"
            or type(entry.sprite) ~= "string" or type(entry.corner) ~= "boolean"
            or type(entry.edgeSide) ~= "string"
            or type(entry.edgeKey) ~= "string" then
            error("RailroaderRV: wall entry is malformed at index " .. tostring(i))
        end
        local coordinateKey = tostring(entry.x) .. ":" .. tostring(entry.y)
            .. ":" .. tostring(entry.z)
        local orientationKey = coordinateKey .. ":" .. (entry.north and "north" or "west")
        local exactKey = orientationKey .. ":" .. entry.role
        if exactKeys[exactKey] then
            error("RailroaderRV: duplicate wall coordinate/orientation/role " .. exactKey)
        end
        if orientationKeys[orientationKey] then
            error("RailroaderRV: duplicate wall direction " .. orientationKey)
        end
        exactKeys[exactKey] = true
        orientationKeys[orientationKey] = true
        if not coordinateKeys[coordinateKey] then
            coordinateKeys[coordinateKey] = true
        end
        orientationByCoordinate[coordinateKey] = orientationByCoordinate[coordinateKey] or {}
        orientationByCoordinate[coordinateKey][entry.north and "north" or "west"] = true
        local expectedRole = entry.north and "wall-north" or "wall-west"
        local expectedSprite = entry.north and C.SPRITES.wall.northSprite
            or C.SPRITES.wall.sprite
        if entry.corner then
            if coordinateKey == nwKey then
                expectedRole = "corner-nw"
                expectedSprite = C.SPRITES.wallNW.sprite
            elseif coordinateKey == seKey then
                expectedRole = "corner-se"
                expectedSprite = C.SPRITES.wallSE.sprite
            else
                error("RailroaderRV: corner wall is not at NW or SE")
            end
        end
        if entry.role ~= expectedRole or entry.sprite ~= expectedSprite then
            error("RailroaderRV: wall role/sprite does not match orientation at " .. coordinateKey)
        end
        if entry.north then northCount = northCount + 1 else westCount = westCount + 1 end
        if entry.corner then cornerCount = cornerCount + 1 end
    end

    local uniqueCoordinateCount = 0
    for _ in pairs(coordinateKeys) do uniqueCoordinateCount = uniqueCoordinateCount + 1 end
    if #wallCoordinates ~= 92 or uniqueCoordinateCount ~= 92
        or northCount ~= 12 or westCount ~= 80 or cornerCount ~= 2 then
        error("RailroaderRV: wall contract must contain 92 coordinates/objects, north12/west80/corner2")
    end
    return uniqueCoordinateCount, northCount, westCount, cornerCount
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
    if not managed then
        error("RailroaderRV: managed 100x100xZ scope is malformed")
    end
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
    -- The active/build geometry comes from the layout planner, never from
    -- objects observed in the world.  Both current cabin layers are active
    -- in this test layout; future irregular rooms can set arbitrary cells.
    for z = managed.minZ, managed.maxZ - 1 do
        local layer = Bitmap.newLayer(managed.width, managed.height, false, false)
        if z == cz or z == cz + C.ROOF_Z_OFFSET then
            for y = cy + C.INTERIOR_MIN_OFFSET_Y,
                cy + C.INTERIOR_MAX_OFFSET_Y do
                for x = cx + C.INTERIOR_MIN_OFFSET_X,
                    cx + C.INTERIOR_MAX_OFFSET_X do
                    local ix, iy = x - managed.originX, y - managed.originY
                    Bitmap.setCell(layer, ix, iy, true, managed.width,
                        managed.height, "walk")
                    Bitmap.setCell(layer, ix, iy, true, managed.width,
                        managed.height, "build")
                end
            end
        end
        bitmap.layers[z] = layer
    end

    -- Keep the player-floor planning rectangle tied to the complete clear
    -- footprint.  The room-specific floor remains the separate 6 x 40
    -- interior contract below; do not materialize the large clear area as a
    -- coordinate list.
    local playerFloor = rectangle(
        clear.minX, clear.maxX, clear.minY, clear.maxY, cz,
        clear.minZ, clear.maxZ, true
    )
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
    local wallCoordinateCount, northCount, westCount, cornerCount =
        validateWallCoordinates(wallCoordinates, cx, cy, cz)

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
        }
    end

    local result = {
        schemaVersion = Layout.SCHEMA_VERSION,
        anchor = anchor,
        clear = clear,
        managed = managed,
        bitmap = bitmap,
        shellEdges = shellEdges,
        room = interior,
        wall = wall,
        roof = roof,
        wallCoordinates = wallCoordinates,
        light = offsetPoint(anchor, C.LAMP_OFFSET),
        counter = offsetPoint(anchor, C.COUNTER_OFFSET),
        sink = offsetPoint(anchor, C.SINK_OFFSET),
        barrel = offsetPoint(anchor, C.RAIN_COLLECTOR_OFFSET),
        generator = offsetPoint(anchor, C.GENERATOR_OFFSET),
    }
    result.wallCount = #wallCoordinates
    result.wallObjectCount = #wallCoordinates
    result.wallCoordinateCount = wallCoordinateCount
    result.wallEdgeCounts = { north = northCount, west = westCount }
    result.wallCornerCount = cornerCount
    return result
end

return Layout
