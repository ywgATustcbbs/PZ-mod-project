-- RailroaderRVTest current-schema and geometry helpers.
--
-- This module builds runtime bounds and reports world-coordinate/loading state.

local Constants = require("RailroaderRV/Common/RV_Constants")
local ServerUtil = require("RailroaderRV/Common/RV_ServerUtil")
local ServerWorld = require("RailroaderRV/Common/RV_ServerWorld")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local WORLD_MIN_Z = Constants.WORLD_MIN_Z
local WORLD_MAX_Z = Constants.WORLD_MAX_Z
local M = {}

local function boundsFor(layout)
    local clear = layout.clear
    local managed = layout.managed
    local room = layout.room
    local wall = layout.wall
    local roof = layout.roof
    local edgeCounts = layout.wallEdgeCounts
    return {
        clearMinX = clear.minX, clearMaxX = clear.maxX,
        clearMinY = clear.minY, clearMaxY = clear.maxY,
        clearMinZ = clear.minZ, clearMaxZ = clear.maxZ,
        managedOriginX = managed.originX, managedOriginY = managed.originY,
        managedWidth = managed.width, managedHeight = managed.height,
        managedMinZ = managed.minZ, managedMaxZ = managed.maxZ,
        managed = managed, shellEdges = layout.shellEdges,
        roomMinX = room.minX, roomMaxX = room.maxX,
        roomMinY = room.minY, roomMaxY = room.maxY, roomZ = room.z,
        wallMinX = wall.minX, wallMaxX = wall.maxX,
        wallMinY = wall.minY, wallMaxY = wall.maxY, wallZ = wall.z,
        wallCoordinates = layout.wallCoordinates,
        wallObjectCount = layout.wallObjectCount,
        wallCoordinateCount = layout.wallCoordinateCount,
        wallEdgeCounts = edgeCounts,
        wallCornerCount = layout.wallCornerCount,
        northEdges = edgeCounts.north, westEdges = edgeCounts.west,
        roofMinX = roof.minX, roofMaxX = roof.maxX,
        roofMinY = roof.minY, roofMaxY = roof.maxY,
        z = layout.anchor.z, roofZ = roof.z, anchor = layout.anchor,
    }
end
local function walkBounds(cell, bounds, fn, requireLoaded)
    for z = bounds.clearMinZ, bounds.clearMaxZ - 1 do
        for x = bounds.clearMinX, bounds.clearMaxX - 1 do
            for y = bounds.clearMinY, bounds.clearMaxY - 1 do
                local square = ServerWorld.getSquare(cell, x, y, z)
                if not square and requireLoaded == true then
                    error("RailroaderRVTest: clear bounds contain an unloaded square")
                end
                if square then
                    fn(square, x, y, z)
                end
            end
        end
    end
end

local function validateTargetCoordinates(bounds, destination)
    local targetX, targetY, targetZ = destination.x, destination.y,
        destination.z
    if RegionSlots.indexForAnchor({ x = targetX, y = targetY, z = targetZ }) == nil then
        error("RailroaderRVTest: relocation target is outside the current RV slot matrix")
    end

    if targetZ < WORLD_MIN_Z or targetZ > WORLD_MAX_Z
        or bounds.clearMinZ < WORLD_MIN_Z or bounds.clearMaxZ - 1 > WORLD_MAX_Z
        or bounds.z < WORLD_MIN_Z or bounds.z > WORLD_MAX_Z
        or bounds.roofZ < WORLD_MIN_Z or bounds.roofZ > WORLD_MAX_Z then
        error("RailroaderRVTest: layout z bounds are outside the legal world")
    end
    if targetX < bounds.roomMinX or targetX > bounds.roomMaxX
        or targetY < bounds.roomMinY or targetY > bounds.roomMaxY then
        error("RailroaderRVTest: final relocation center is outside the interior")
    end

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
    for y = bounds.clearMinY, bounds.clearMaxY - 1 do
        for x = bounds.clearMinX, bounds.clearMaxX - 1 do
            validWorldCoordinate(x, y, bounds.z, "base")
        end
    end
    for y = bounds.roofMinY, bounds.roofMaxY do
        for x = bounds.roofMinX, bounds.roofMaxX do
            validWorldCoordinate(x, y, bounds.roofZ, "roof")
        end
    end
end
local function preflightLoaded(cell, bounds)
    if not cell then
        error("RailroaderRVTest: preflight has no IsoCell")
    end
    -- The cleanup scope is half-open and every base square must be visible
    -- before any world mutation starts.
    for y = bounds.clearMinY, bounds.clearMaxY - 1 do
        for x = bounds.clearMinX, bounds.clearMaxX - 1 do
            local square = ServerWorld.getSquare(cell, x, y, bounds.z)
            if not square then
                return false, "RailroaderRVTest: required base square is not loaded at "
                    .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(bounds.z)
            end
        end
    end
    return true
end

-- A remote teleport is also the engine's chunk-streaming trigger. The target
-- cell may therefore be unavailable when queueGeneration sends the relocation
-- command. Retry only that expected loading failure; malformed contracts or
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
        cellOrError, bounds)
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

M.boundsFor = boundsFor
M.walkBounds = walkBounds
M.validateTargetCoordinates = validateTargetCoordinates
M.targetAreaLoadStatus = targetAreaLoadStatus

return M
