-- Pure, shared coordinate planning for the RailroaderRV technical test.
--
-- No function in this file mutates a square or reads a client-supplied
-- coordinate.  Server code supplies the shared fixed target anchor and
-- applies the returned plan only after validating the requesting player.

require "RailroaderRV/RV_Constants"

RailroaderRV = RailroaderRV or {}
RailroaderRV.Layout = RailroaderRV.Layout or {}

local Layout = RailroaderRV.Layout
local C = RailroaderRV.Constants

Layout.VERSION = 3

local function point(x, y, z)
    return { x = x, y = y, z = z }
end

local function rectangle(minX, maxX, minY, maxY, z)
    return {
        minX = minX,
        maxX = maxX,
        minY = minY,
        maxY = maxY,
        z = z,
    }
end

local function offsetPoint(anchor, offset)
    return point(anchor.cx + offset.x, anchor.cy + offset.y, anchor.cz + offset.z)
end

local function appendWall(result, x, y, z, north, sprite, role, corner)
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
-- (39 west edge + 40 east edge).  The NW/SE corner strips contribute one
-- north-facing and one west-facing constructor orientation respectively.
local function wallCoordinatesForAnchor(cx, cy, cz)
    local result = {}
    local northSprite = C.WALL_NORTH_SPRITE
    local westSprite = C.WALL_WEST_SPRITE
    local nwSprite = C.WALL_NW_SPRITE
    local seSprite = C.WALL_SE_SPRITE

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
            or type(entry.sprite) ~= "string" or type(entry.corner) ~= "boolean" then
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
        local expectedSprite = entry.north and C.WALL_NORTH_SPRITE or C.WALL_WEST_SPRITE
        if entry.corner then
            if coordinateKey == nwKey then
                expectedRole = "corner-nw"
                expectedSprite = C.WALL_NW_SPRITE
            elseif coordinateKey == seKey then
                expectedRole = "corner-se"
                expectedSprite = C.WALL_SE_SPRITE
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
        nil
    )
    clear.allZ = C.CLEAR_ALL_Z

    -- Keep the player-floor alias tied to the complete clear footprint.  The
    -- room-specific floor remains the separate 6 x 40 interior contract below;
    -- do not materialize the large clear area as a coordinate list.
    local playerFloor = rectangle(
        clear.minX, clear.maxX, clear.minY, clear.maxY, cz
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
    local wallCoordinateCount, northCount, westCount, cornerCount =
        validateWallCoordinates(wallCoordinates, cx, cy, cz)

    local anchor = {
        cx = cx,
        cy = cy,
        cz = cz,
        -- The x/y/z spelling is the serialized/server-facing contract.  Keep
        -- cx/cy/cz for callers that use the planner's original terminology.
        x = cx,
        y = cy,
        z = cz,
    }

    local result = {
        version = Layout.VERSION,
        anchor = anchor,
        center = point(cx, cy, cz),
        clear = clear,
        clearBounds = clear,
        playerFloor = playerFloor,
        interior = interior,
        interiorFloor = interior,
        woodFloor = interior,
        wall = wall,
        walls = wall,
        roof = roof,
        features = {
            lamp = offsetPoint(anchor, C.LAMP_OFFSET),
            counter = offsetPoint(anchor, C.COUNTER_OFFSET),
            sink = offsetPoint(anchor, C.SINK_OFFSET),
            rainCollector = offsetPoint(anchor, C.RAIN_COLLECTOR_OFFSET),
            generator = offsetPoint(anchor, C.GENERATOR_OFFSET),
        },
    }

    -- Named aliases make the contract easy to consume from server code while
    -- keeping all coordinates derived from one anchor.
    result.lamp = result.features.lamp
    result.counter = result.features.counter
    result.sink = result.features.sink
    result.rainCollector = result.features.rainCollector
    result.generator = result.features.generator

    result.wallCoordinates = wallCoordinates
    result.wallCount = #wallCoordinates
    result.wallObjectCount = #wallCoordinates
    result.wallCoordinateCount = wallCoordinateCount
    result.wallEdgeCounts = { north = northCount, west = westCount }
    result.wallCornerCount = cornerCount
    return result
end

function Layout.fromPlayer(player)
    if not player or not player.getX or not player.getY or not player.getZ then
        return nil
    end
    return Layout.make(player:getX(), player:getY(), player:getZ())
end

-- Common aliases retained as a small compatibility surface for the server
-- worker.  All aliases return the same pure plan shape.
Layout.new = Layout.make
Layout.forPlayer = Layout.fromPlayer
Layout.planForPlayer = Layout.fromPlayer

function Layout.eachRect(rect, callback, z)
    if not rect or not callback then return end
    local resolvedZ = z or rect.z
    for y = rect.minY, rect.maxY do
        for x = rect.minX, rect.maxX do
            callback(x, y, resolvedZ)
        end
    end
end

function Layout.eachPerimeter(rect, callback, z)
    if not rect or not callback then return end
    local resolvedZ = z or rect.z
    for x = rect.minX, rect.maxX do
        callback(x, rect.minY, resolvedZ)
        if rect.maxY ~= rect.minY then
            callback(x, rect.maxY, resolvedZ)
        end
    end
    for y = rect.minY + 1, rect.maxY - 1 do
        callback(rect.minX, y, resolvedZ)
        if rect.maxX ~= rect.minX then
            callback(rect.maxX, y, resolvedZ)
        end
    end
end

-- The map's valid vertical range is world-dependent.  This iterator exposes
-- the required XY footprint and lets the server supply the valid z range.
function Layout.eachClearXY(plan, callback)
    if not plan or not plan.clear or not callback then return end
    for y = plan.clear.minY, plan.clear.maxY do
        for x = plan.clear.minX, plan.clear.maxX do
            callback(x, y)
        end
    end
end

-- Apply the same XY footprint to an explicitly resolved inclusive z range.
-- The caller supplies minZ/maxZ from the loaded cell because map heights are
-- not fixed by this mod.  This is the intended all-valid-z server API.
function Layout.eachClear(plan, minZ, maxZ, callback)
    if not plan or not plan.clear or not callback then return end
    for z = minZ, maxZ do
        Layout.eachClearXY(plan, function(x, y)
            callback(x, y, z)
        end)
    end
end

return Layout
