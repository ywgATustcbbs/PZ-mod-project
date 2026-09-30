-- Server-authoritative roof/room visual refresh for generated RV rooms.
--
-- The current template declares the cells whose room/roof neighbours need a
-- refresh.  Every declared point is refreshed in one synchronous cycle: a
-- temporary untagged floor is created on the cell, removed again, and the
-- verified recalculation sequence below rebuilds the cell.  The floor object the
-- template declares for that cell is never replaced by this path, and this
-- module owns no transaction, retry or relocation state.

local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local refreshPoints = RoomTemplate.roofRefreshPoints(Template)
local templateObjects = RoomTemplate.orderedObjects(Template)
local ServerUtil = require("RailroaderRV/Common/RV_ServerUtil")
local ServerWorld = require("RailroaderRV/Common/RV_ServerWorld")

RailroaderRV = RailroaderRV or {}
RailroaderRV.RoofRefresh = RailroaderRV.RoofRefresh or {}

local Refresh = RailroaderRV.RoofRefresh

local function coordinate(x, y, z)
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

local function fail(reason)
    print("[RailroaderRVTest] roof refresh failed: " .. tostring(reason))
    return false, reason
end

-- A declared point is a template offset; its world cell is always derived from
-- the current bounds anchor and never from a stored coordinate.
local function pointCell(bounds, point)
    return bounds.anchor.x + point.x, bounds.anchor.y + point.y,
        bounds.z + point.z
end

local function loadedSquare(cell, x, y, z)
    local square = ServerWorld.getSquare(cell, x, y, z)
    if not square then
        return nil, "roof refresh square is not loaded at " .. coordinate(x, y, z)
    end
    return square
end

-- IsoGridSquare.addFloor removes every object on the square whose sprite is a
-- solid floor, so it would delete the template's own captured floor object and
-- its generation tag.  The temporary floor is therefore attached directly: it
-- carries the template floor sprite, stays untagged, and is removed again before
-- this call returns.
local function createTemporaryFloor(cell, square, sprite)
    local constructed, temporary = ServerUtil.invokeClass(
        rawget(_G, "IsoObject"), { { cell, square, sprite } })
    if not constructed or not temporary then
        error("RailroaderRVTest: temporary refresh floor construction failed")
    end
    if not ServerUtil.callSucceeded(square, "transmitAddObjectToSquare",
        temporary, -1) then
        error("RailroaderRVTest: temporary refresh floor attachment failed")
    end
    return temporary
end

-- Verified recalculation sequence for one refreshed cell.
local function recalcSquare(cell, square)
    local okX, x = ServerUtil.invoke(square, "getX")
    local okY, y = ServerUtil.invoke(square, "getY")
    if not okX or not okY then
        return false, "roof refresh square coordinates are unavailable"
    end
    if not ServerUtil.callSucceeded(square, "EnsureSurroundNotNull")
        or not ServerUtil.callSucceeded(square, "RecalcProperties")
        or not ServerUtil.callSucceeded(cell, "checkHaveRoof", x, y)
        or not ServerUtil.callSucceeded(square, "clearWater")
        or not ServerUtil.callSucceeded(square, "RecalcAllWithNeighbours", true) then
        return false, "roof refresh room synchronization failed"
    end
    local regions = rawget(_G, "IsoRegions")
    if not regions then
        return false, "IsoRegions.squareChanged is unavailable"
    end
    local accessOk, squareChanged = pcall(function()
        return regions.squareChanged
    end)
    if not accessOk or type(squareChanged) ~= "function" then
        return false, "IsoRegions.squareChanged is unavailable"
    end
    local changedOk = pcall(squareChanged, square)
    if not changedOk then return false, "IsoRegions square synchronization failed" end
    local gridSquare = rawget(_G, "IsoGridSquare")
    if type(gridSquare) == "table"
        and type(gridSquare.setRecalcLightTime) == "function" then
        pcall(gridSquare.setRecalcLightTime, -1)
    end
    return true
end

local function refreshPoint(cell, bounds, point)
    local x, y, z = pointCell(bounds, point)
    local square, reason = loadedSquare(cell, x, y, z)
    if not square then return false, reason end
    local sprite = templateObjects[point.templateIndex].sprite
    local temporary = createTemporaryFloor(cell, square, sprite)
    -- Only the temporary floor goes away; the cell keeps the floor object the
    -- template declares for it.
    ServerWorld.removeGenericObject(square, temporary)
    local synchronized, syncReason = recalcSquare(cell, square)
    if not synchronized then return false, syncReason end
    return true, "room synchronized at " .. coordinate(x, y, z)
end

local function refreshAllPoints(player, bounds)
    local cell = ServerWorld.getCellForPlayer(player)
    local reason
    for index = 1, #refreshPoints do
        local refreshed, pointReason = refreshPoint(cell, bounds,
            refreshPoints[index])
        if not refreshed then return false, pointReason end
        reason = pointReason
    end
    return true, reason
end

function Refresh.run(player, bounds)
    local ok, refreshed, reason = pcall(refreshAllPoints, player, bounds)
    if not ok then return fail(refreshed) end
    if refreshed ~= true then return fail(reason) end
    return true, reason
end

return Refresh
