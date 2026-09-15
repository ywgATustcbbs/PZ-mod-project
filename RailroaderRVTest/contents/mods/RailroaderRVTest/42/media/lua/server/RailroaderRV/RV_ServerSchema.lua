-- RailroaderRVTest current-schema and geometry helpers.
--
-- This module is pure with respect to persistence and events.  It validates
-- the current layout/bitmap contract and reports loaded-area status; callers
-- remain responsible for transaction state, world mutation and fail-closed
-- save handling.

local Constants = require("RailroaderRV/RV_Constants")
local Bitmap = require("RailroaderRV/RV_Bitmap")
local ServerUtil = require("RailroaderRV/RV_ServerUtil")
local ServerWorld = require("RailroaderRV/RV_ServerWorld")
local WORLD_MIN_Z = -32
local WORLD_MAX_Z = 31
local M = {}

local function boundsFor(layout)
    if type(layout) ~= "table" then
        error("RailroaderRVTest: layout plan is not a table")
    end
    local clear = layout.clear
    local managed = layout.managed
    local bitmap = layout.bitmap
    local shellEdges = layout.shellEdges
    local room = layout.room
    local wall = layout.wall
    local roof = layout.roof
    local anchor = layout.anchor
    if type(clear) ~= "table" or type(managed) ~= "table"
        or type(bitmap) ~= "table" or type(shellEdges) ~= "table"
        or type(room) ~= "table" or type(wall) ~= "table"
        or type(roof) ~= "table" or type(anchor) ~= "table" then
        error("RailroaderRVTest: layout bounds contract is incomplete")
    end
    local function field(source, label, name)
        local value = source[name]
        if value == nil then
            error("RailroaderRVTest: layout contract missing " .. label)
        end
        return ServerUtil.requiredInteger(value, label)
    end
    local ax = ServerUtil.requiredInteger(anchor.x, "layout anchor.x")
    local ay = ServerUtil.requiredInteger(anchor.y, "layout anchor.y")
    local az = ServerUtil.requiredInteger(anchor.z, "layout anchor.z")
    local clearMinZ = field(clear, "layout clear.minZ", "minZ")
    local clearMaxZ = field(clear, "layout clear.maxZ", "maxZ")
    local clearMinX = field(clear, "layout clear.minX", "minX")
    local clearMaxX = field(clear, "layout clear.maxX", "maxX")
    local clearMinY = field(clear, "layout clear.minY", "minY")
    local clearMaxY = field(clear, "layout clear.maxY", "maxY")
    local roomMinX = field(room, "layout room.minX", "minX")
    local roomMaxX = field(room, "layout room.maxX", "maxX")
    local roomMinY = field(room, "layout room.minY", "minY")
    local roomMaxY = field(room, "layout room.maxY", "maxY")
    local roomZ = field(room, "layout room.z", "z")
    local wallMinX = field(wall, "layout wall.minX", "minX")
    local wallMaxX = field(wall, "layout wall.maxX", "maxX")
    local wallMinY = field(wall, "layout wall.minY", "minY")
    local wallMaxY = field(wall, "layout wall.maxY", "maxY")
    local wallZ = field(wall, "layout wall.z", "z")
    local roofMinX = field(roof, "layout roof.minX", "minX")
    local roofMaxX = field(roof, "layout roof.maxX", "maxX")
    local roofMinY = field(roof, "layout roof.minY", "minY")
    local roofMaxY = field(roof, "layout roof.maxY", "maxY")
    local roofZ = ServerUtil.requiredInteger(roof.z, "layout roof.z")
    if type(layout.wallCoordinates) ~= "table" then
        error("RailroaderRVTest: layout wallCoordinates is missing")
    end
    local wallObjectCount = ServerUtil.requiredInteger(layout.wallObjectCount, "layout wallObjectCount")
    local wallCoordinateCount = ServerUtil.requiredInteger(layout.wallCoordinateCount, "layout wallCoordinateCount")
    local wallEdgeCounts = layout.wallEdgeCounts
    if type(wallEdgeCounts) ~= "table" then
        error("RailroaderRVTest: layout wallEdgeCounts is missing")
    end
    local northEdges = ServerUtil.requiredInteger(wallEdgeCounts.north, "layout wallEdgeCounts.north")
    local westEdges = ServerUtil.requiredInteger(wallEdgeCounts.west, "layout wallEdgeCounts.west")
    local wallCornerCount = ServerUtil.requiredInteger(layout.wallCornerCount, "layout wallCornerCount")
    local managedMinZ = field(managed, "layout managed.minZ", "minZ")
    local managedMaxZ = field(managed, "layout managed.maxZ", "maxZ")
    local managedOriginX = field(managed, "layout managed.originX", "originX")
    local managedOriginY = field(managed, "layout managed.originY", "originY")
    local managedWidth = field(managed, "layout managed.width", "width")
    local managedHeight = field(managed, "layout managed.height", "height")
    if managedWidth ~= 100 or managedHeight ~= 100
        or managedMaxZ <= managedMinZ
        or managedOriginX ~= ServerUtil.requiredInteger(bitmap.originX,
            "layout bitmap.originX")
        or managedOriginY ~= ServerUtil.requiredInteger(bitmap.originY,
            "layout bitmap.originY")
        or managedWidth ~= ServerUtil.requiredInteger(bitmap.width,
            "layout bitmap.width")
        or managedHeight ~= ServerUtil.requiredInteger(bitmap.height,
            "layout bitmap.height")
        or managedMinZ ~= ServerUtil.requiredInteger(bitmap.minZ,
            "layout bitmap.minZ")
        or managedMaxZ ~= ServerUtil.requiredInteger(bitmap.maxZ,
            "layout bitmap.maxZ")
        or clear.minX ~= managedOriginX or clear.minY ~= managedOriginY
        or clear.maxX ~= managedOriginX + managedWidth
        or clear.maxY ~= managedOriginY + managedHeight
        or clearMinZ ~= managedMinZ or clearMaxZ ~= managedMaxZ
        or clear.halfOpen ~= true then
        error("RailroaderRVTest: managed scope must be half-open 100x100xZ")
    end
    if not Bitmap or not Bitmap.validate(bitmap) then
        error("RailroaderRVTest: layout bitmap failed validation")
    end
    local scopeMinX, scopeMinY = managedOriginX, managedOriginY
    local scopeMaxX = managedOriginX + managedWidth
    local scopeMaxY = managedOriginY + managedHeight
    local function rectInside(minX, maxX, minY, maxY, z, label)
        if minX > maxX or minY > maxY
            or minX < scopeMinX or maxX >= scopeMaxX
            or minY < scopeMinY or maxY >= scopeMaxY
            or z < managedMinZ or z >= managedMaxZ then
            error("RailroaderRVTest: " .. tostring(label)
                .. " is outside the bitmap scope")
        end
    end
    if roomZ ~= az or wallZ ~= az or roofZ < managedMinZ
        or roofZ >= managedMaxZ then
        error("RailroaderRVTest: layout structure z is outside the bitmap scope")
    end
    rectInside(roomMinX, roomMaxX, roomMinY, roomMaxY, roomZ, "room")
    rectInside(wallMinX, wallMaxX, wallMinY, wallMaxY, wallZ, "wall")
    rectInside(roofMinX, roofMaxX, roofMinY, roofMaxY, roofZ, "roof")
    for i = 1, #layout.wallCoordinates do
        local entry = layout.wallCoordinates[i]
        if type(entry) ~= "table"
            or not Bitmap.containsScope(bitmap, entry.x, entry.y, entry.z) then
            error("RailroaderRVTest: wall object host is outside bitmap scope")
        end
    end
    return {
        schemaVersion = Constants.LAYOUT_SCHEMA_VERSION,
        clearMinX = clearMinX, clearMaxX = clearMaxX,
        clearMinY = clearMinY, clearMaxY = clearMaxY,
        clearMinZ = clearMinZ, clearMaxZ = clearMaxZ,
        managedOriginX = managedOriginX, managedOriginY = managedOriginY,
        managedWidth = managedWidth, managedHeight = managedHeight,
        managedMinZ = managedMinZ, managedMaxZ = managedMaxZ,
        bitmap = bitmap, shellEdges = shellEdges,
        roomMinX = roomMinX, roomMaxX = roomMaxX,
        roomMinY = roomMinY, roomMaxY = roomMaxY, roomZ = roomZ,
        wallMinX = wallMinX, wallMaxX = wallMaxX,
        wallMinY = wallMinY, wallMaxY = wallMaxY, wallZ = wallZ,
        wallCoordinates = layout.wallCoordinates,
        wallObjectCount = wallObjectCount,
        wallCoordinateCount = wallCoordinateCount,
        wallEdgeCounts = layout.wallEdgeCounts,
        wallCornerCount = wallCornerCount,
        northEdges = northEdges, westEdges = westEdges,
        roofMinX = roofMinX, roofMaxX = roofMaxX,
        roofMinY = roofMinY, roofMaxY = roofMaxY,
        z = az,
        roofZ = roofZ,
    }
end

local function walkBounds(cell, bounds, fn)
    for z = bounds.clearMinZ, bounds.clearMaxZ - 1 do
        for x = bounds.clearMinX, bounds.clearMaxX - 1 do
            for y = bounds.clearMinY, bounds.clearMaxY - 1 do
                local square = ServerWorld.getSquare(cell, x, y, z)
                if square then
                    fn(square, x, y, z)
                end
            end
        end
    end
end

local function validateWallContract(bounds)
    if type(bounds.wallCoordinates) ~= "table" or #bounds.wallCoordinates ~= 92
        or bounds.wallObjectCount ~= 92 or bounds.wallCoordinateCount ~= 92
        or bounds.northEdges ~= 12 or bounds.westEdges ~= 80
        or bounds.wallCornerCount ~= 2 then
        error("RailroaderRVTest: wall layout contract is invalid")
    end
    local coordinates, orientations, exact, both = {}, {}, {}, {}
    local uniqueCoordinates, northEdges, westEdges, corners = 0, 0, 0, 0
    local nwKey = tostring(bounds.wallMinX) .. ":" .. tostring(bounds.wallMinY)
        .. ":" .. tostring(bounds.z)
    local seKey = tostring(bounds.wallMaxX) .. ":" .. tostring(bounds.wallMaxY)
        .. ":" .. tostring(bounds.z)
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        if type(entry) ~= "table" or type(entry.x) ~= "number"
            or type(entry.y) ~= "number" or type(entry.z) ~= "number"
            or type(entry.north) ~= "boolean" or type(entry.role) ~= "string"
            or type(entry.sprite) ~= "string" or type(entry.corner) ~= "boolean" then
            error("RailroaderRVTest: malformed wall entry at index " .. tostring(i))
        end
        local x = ServerUtil.requiredInteger(entry.x, "wall[" .. tostring(i) .. "].x")
        local y = ServerUtil.requiredInteger(entry.y, "wall[" .. tostring(i) .. "].y")
        local z = ServerUtil.requiredInteger(entry.z, "wall[" .. tostring(i) .. "].z")
        if x < bounds.wallMinX or x > bounds.wallMaxX
            or y < bounds.wallMinY or y > bounds.wallMaxY or z ~= bounds.z then
            error("RailroaderRVTest: wall entry is outside the wall bounds")
        end
        local coordinateKey = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        local orientation = entry.north and "north" or "west"
        local orientationKey = coordinateKey .. ":" .. orientation
        local exactKey = orientationKey .. ":" .. entry.role
        if exact[exactKey] or orientations[orientationKey] then
            error("RailroaderRVTest: duplicate wall coordinate/orientation")
        end
        exact[exactKey] = true
        orientations[orientationKey] = true
        if not coordinates[coordinateKey] then
            coordinates[coordinateKey] = true
            uniqueCoordinates = uniqueCoordinates + 1
        end
        both[coordinateKey] = both[coordinateKey] or {}
        both[coordinateKey][orientation] = true
        local expectedRole = "wall-" .. orientation
        local expectedSprite = entry.north
            and Constants.SPRITES.wall.northSprite
            or Constants.SPRITES.wall.sprite
        if entry.corner then
            if coordinateKey == nwKey then
                expectedRole = "corner-nw"
                expectedSprite = Constants.SPRITES.wallNW.sprite
            elseif coordinateKey == seKey then
                expectedRole = "corner-se"
                expectedSprite = Constants.SPRITES.wallSE.sprite
            else
                error("RailroaderRVTest: corner wall is not at NW or SE")
            end
        end
        if entry.role ~= expectedRole or entry.sprite ~= expectedSprite then
            error("RailroaderRVTest: wall role/sprite does not match orientation")
        end
        if entry.north then northEdges = northEdges + 1 else westEdges = westEdges + 1 end
        if entry.corner == true then corners = corners + 1 end
    end
    for coordinateKey, orientationSet in pairs(both) do
        if orientationSet.north and orientationSet.west then
            error("RailroaderRVTest: wall ring cannot duplicate an orientation at " .. coordinateKey)
        end
    end
    if uniqueCoordinates ~= 92 or northEdges ~= 12 or westEdges ~= 80 or corners ~= 2 then
        error("RailroaderRVTest: wall contract must contain 92 coordinates/objects, north12/west80/corner2")
    end
end

-- Shell ownership is a separate persisted ledger, not a deduction from the
-- wall object's inactive host cell.  Validate the generated identity here so
-- a malformed plan cannot enter the destructive generation transaction.
local function validateShellEdgeContract(bounds)
    if type(bounds.shellEdges) ~= "table" then
        error("RailroaderRVTest: shell edge ledger is missing")
    end
    local seen = {}
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        local key = entry.edgeKey
        if type(key) ~= "string" or seen[key] then
            error("RailroaderRVTest: shell edge key is missing or duplicated")
        end
        local axis, edgeX, edgeY, edgeZ = string.match(
            key, "^([NW]):(-?%d+):(-?%d+):(-?%d+)$")
        edgeX, edgeY, edgeZ = tonumber(edgeX), tonumber(edgeY), tonumber(edgeZ)
        if not axis or edgeX == nil or edgeY == nil or edgeZ == nil
            or entry.axis ~= axis then
            error("RailroaderRVTest: shell edge is not canonical N/W")
        end
        local ledger = bounds.shellEdges[key]
        if type(ledger) ~= "table"
            or ledger.edgeKey ~= key
            or ServerUtil.requiredInteger(ledger.hostX, "shell edge hostX") ~= edgeX
            or ServerUtil.requiredInteger(ledger.hostY, "shell edge hostY") ~= edgeY
            or ServerUtil.requiredInteger(ledger.z, "shell edge z") ~= edgeZ
            or ServerUtil.requiredInteger(ledger.objectX, "shell edge objectX") ~= entry.x
            or ServerUtil.requiredInteger(ledger.objectY, "shell edge objectY") ~= entry.y
            or ServerUtil.requiredInteger(ledger.objectZ, "shell edge objectZ") ~= entry.z
            or ledger.replacementAllowed ~= true then
            error("RailroaderRVTest: shell edge ledger identity is inconsistent")
        end
        seen[key] = true
    end
end

-- Validate only the fixed target contract and world coordinates.  This helper
-- deliberately never reads an IsoGridSquare: queueGeneration must be able to
-- reject an impossible destination before sending Relocate, while the
-- post-teleport preflight below remains responsible for waiting on loaded
-- squares.
local function validateTargetCoordinates(bounds, destination)
    if type(bounds) ~= "table" then
        error("RailroaderRVTest: target bounds are not a table")
    end
    if type(destination) ~= "table" then
        error("RailroaderRVTest: relocation destination is not a table")
    end

    local targetX = ServerUtil.requiredInteger(destination.x, "relocation target x")
    local targetY = ServerUtil.requiredInteger(destination.y, "relocation target y")
    local targetZ = ServerUtil.requiredInteger(destination.z, "relocation target z")
    local expectedX = ServerUtil.requiredInteger(Constants.TELEPORT_X,
        "shared teleport target x")
    local expectedY = ServerUtil.requiredInteger(Constants.TELEPORT_Y,
        "shared teleport target y")
    local expectedZ = ServerUtil.requiredInteger(Constants.TELEPORT_Z,
        "shared teleport target z")
    if targetX ~= expectedX or targetY ~= expectedY or targetZ ~= expectedZ then
        error("RailroaderRVTest: relocation target is not the fixed shared destination")
    end

    if targetZ < WORLD_MIN_Z or targetZ > WORLD_MAX_Z
        or bounds.clearMinZ < WORLD_MIN_Z or bounds.clearMaxZ - 1 > WORLD_MAX_Z
        or bounds.clearMinZ >= bounds.clearMaxZ
        or bounds.z < WORLD_MIN_Z or bounds.z > WORLD_MAX_Z
        or bounds.roofZ < WORLD_MIN_Z or bounds.roofZ > WORLD_MAX_Z then
        error("RailroaderRVTest: layout z bounds are outside the legal world")
    end
    -- The managed footprint is strictly half-open x=[20000,20100),
    -- y=[2000,2100) for the fixed (20050,2050) destination.
    if bounds.clearMinX ~= targetX - 50 or bounds.clearMaxX ~= targetX - 50 + 100
        or bounds.clearMinY ~= targetY - 50 or bounds.clearMaxY ~= targetY - 50 + 100
        or bounds.z ~= targetZ or bounds.clearMinZ ~= bounds.managedMinZ
        or bounds.clearMaxZ ~= bounds.managedMaxZ then
        error("RailroaderRVTest: clear footprint does not match the fixed target")
    end
    if bounds.clearMaxX - bounds.clearMinX ~= 100
        or bounds.clearMaxY - bounds.clearMinY ~= 100 then
        error("RailroaderRVTest: managed footprint must be exactly half-open 100x100")
    end
    if bounds.roomMaxX - bounds.roomMinX + 1 ~= 6
        or bounds.roomMaxY - bounds.roomMinY + 1 ~= 40 then
        error("RailroaderRVTest: room footprint must be exactly 6x40")
    end
    if bounds.wallMaxX - bounds.wallMinX + 1 ~= 7
        or bounds.wallMaxY - bounds.wallMinY + 1 ~= 41 then
        error("RailroaderRVTest: wall footprint must be exactly 7x41")
    end
    if bounds.roofMaxX - bounds.roofMinX + 1 ~= 6
        or bounds.roofMaxY - bounds.roofMinY + 1 ~= 40 then
        error("RailroaderRVTest: roof footprint must be exactly 6x40")
    end
    if targetX < bounds.roomMinX or targetX > bounds.roomMaxX
        or targetY < bounds.roomMinY or targetY > bounds.roomMaxY then
        error("RailroaderRVTest: final relocation center is outside the interior")
    end
    if bounds.roofZ ~= bounds.z + 1 then
        error("RailroaderRVTest: roof must be exactly one level above the base")
    end
    validateWallContract(bounds)
    validateShellEdgeContract(bounds)

    local worldOk, world = ServerUtil.callGlobal("getWorld")
    if not worldOk or not world then
        error("RailroaderRVTest: getWorld is unavailable for coordinate validation")
    end
    local function validWorldCoordinate(x, y, z, role)
        if z < WORLD_MIN_Z or z > WORLD_MAX_Z then
            error("RailroaderRVTest: " .. tostring(role) .. " is outside legal z range")
        end
        local validOk, valid = ServerUtil.invoke(world, "isValidSquare", x, y, z)
        if not validOk or valid ~= true then
            error("RailroaderRVTest: " .. tostring(role) .. " is outside the legal world")
        end
    end

    validWorldCoordinate(targetX, targetY, targetZ, "relocation target")
    -- Validate the entire required 100x100 base footprint without requiring any
    -- of those remote squares to be loaded yet.
    for y = bounds.clearMinY, bounds.clearMaxY - 1 do
        for x = bounds.clearMinX, bounds.clearMaxX - 1 do
            validWorldCoordinate(x, y, bounds.z, "base")
        end
    end
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        local x = ServerUtil.requiredInteger(entry.x, "wall[" .. tostring(i) .. "].x")
        local y = ServerUtil.requiredInteger(entry.y, "wall[" .. tostring(i) .. "].y")
        local z = ServerUtil.requiredInteger(entry.z, "wall[" .. tostring(i) .. "].z")
        if z ~= bounds.z then
            error("RailroaderRVTest: wall entry is not on the base z level")
        end
        validWorldCoordinate(x, y, z, "wall")
    end
    -- The upper footprint must be legal, but its squares may remain nil until
    -- the player-building phase creates them.
    for y = bounds.roofMinY, bounds.roofMaxY do
        for x = bounds.roofMinX, bounds.roofMaxX do
            validWorldCoordinate(x, y, bounds.roofZ, "roof")
        end
    end
end

local function preflightLoaded(cell, bounds, allowIncomplete)
    if not cell then
        error("RailroaderRVTest: preflight has no IsoCell")
    end
    validateTargetCoordinates(bounds, {
        x = Constants.TELEPORT_X,
        y = Constants.TELEPORT_Y,
        z = Constants.TELEPORT_Z,
    })
    local function requiredLoaded(x, y, z, role)
        local square = ServerWorld.getSquare(cell, x, y, z)
        if not square then
            local message = "RailroaderRVTest: required " .. tostring(role)
                .. " square is not loaded at " .. tostring(x) .. ","
                .. tostring(y) .. "," .. tostring(z)
            -- A missing square is the normal result while the remote
            -- teleport is still streaming its target cells.  The polling
            -- caller must receive a status instead of raising a Kahlua
            -- exception on every OnTick; strict callers still fail closed.
            if allowIncomplete then
                return nil, message
            end
            error(message)
        end
        return square
    end

    -- All 10000 base squares in the half-open 100x100 scope must already
    -- exist before any clear/remove pass.
    for y = bounds.clearMinY, bounds.clearMaxY - 1 do
        for x = bounds.clearMinX, bounds.clearMaxX - 1 do
            local square, reason = requiredLoaded(x, y, bounds.z, "base")
            if not square then
                return false, reason
            end
        end
    end
    -- The explicit oriented wall list is part of the same loaded base layer.
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        local x = ServerUtil.requiredInteger(entry.x, "wall[" .. tostring(i) .. "].x")
        local y = ServerUtil.requiredInteger(entry.y, "wall[" .. tostring(i) .. "].y")
        local z = ServerUtil.requiredInteger(entry.z, "wall[" .. tostring(i) .. "].z")
        if z ~= bounds.z then
            error("RailroaderRVTest: wall entry is not on the base z level")
        end
        local square, reason = requiredLoaded(x, y, z, "wall")
        if not square then
            return false, reason
        end
    end
    return true
end

-- A remote teleport is also the engine's chunk-streaming trigger.  The target
-- may therefore be unloaded when queueGeneration sends the relocation command.
-- Retry only the two expected loading failures here; malformed contracts or
-- other engine failures cancel the request before any world mutation.
local function targetAreaLoadStatus(player, bounds, safeErrorText)
    local safeText = safeErrorText or function(err)
        local ok, text = pcall(tostring, err)
        return ok and type(text) == "string" and text or "<error formatting failed>"
    end
    local cellOk, cellOrError = pcall(ServerWorld.getCellForPlayer, player)
    if not cellOk then
        local message = safeText(cellOrError)
        if string.find(message, "no IsoCell available", 1, true) then
            return false, message
        end
        return nil, message
    end
    local preflightOk, loaded, preflightError = pcall(preflightLoaded,
        cellOrError, bounds, true)
    if not preflightOk then
        -- Unexpected contract/engine errors remain a hard cancellation; only
        -- the explicit incomplete-footprint status is retryable.
        return nil, safeText(loaded)
    end
    if loaded == true then
        return true
    end
    if loaded == false then
        return false, safeText(preflightError)
    end
    return nil, "RailroaderRVTest: loaded-area preflight returned no status"
end

local function eachStructureSquare(cell, bounds, callback)
    if type(bounds) ~= "table" then
        return
    end
    local function visit(x, y, z)
        local square = ServerWorld.getSquare(cell, x, y, z)
        if square then
            callback(square, x, y, z)
        end
    end
    local baseZ = ServerUtil.requiredInteger(bounds.z, "saved bounds z")
    for x = ServerUtil.requiredInteger(bounds.wallMinX, "saved bounds wallMinX"),
        ServerUtil.requiredInteger(bounds.wallMaxX, "saved bounds wallMaxX") do
        for y = ServerUtil.requiredInteger(bounds.wallMinY, "saved bounds wallMinY"),
            ServerUtil.requiredInteger(bounds.wallMaxY, "saved bounds wallMaxY") do
            visit(x, y, baseZ)
        end
    end
    -- The complete 7x41 wall rectangle already contains the 6x40 interior.
    -- Do not add a second room loop: it only revisits the same base squares and
    -- can hide an incomplete wall scan behind a de-duplication table.
    local roofZ = ServerUtil.requiredInteger(bounds.roofZ, "saved bounds roofZ")
    for x = ServerUtil.requiredInteger(bounds.roofMinX, "saved bounds roofMinX"),
        ServerUtil.requiredInteger(bounds.roofMaxX, "saved bounds roofMaxX") do
        for y = ServerUtil.requiredInteger(bounds.roofMinY, "saved bounds roofMinY"),
            ServerUtil.requiredInteger(bounds.roofMaxY, "saved bounds roofMaxY") do
            visit(x, y, roofZ)
        end
    end
end

M.boundsFor = boundsFor
M.walkBounds = walkBounds
M.validateWallContract = validateWallContract
M.validateShellEdgeContract = validateShellEdgeContract
M.validateTargetCoordinates = validateTargetCoordinates
M.preflightLoaded = preflightLoaded
M.targetAreaLoadStatus = targetAreaLoadStatus
M.eachStructureSquare = eachStructureSquare

return M
