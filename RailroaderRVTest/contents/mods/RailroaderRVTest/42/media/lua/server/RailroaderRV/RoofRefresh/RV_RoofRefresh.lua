-- Server-authoritative roof/room visual refresh for generated RV rooms.
--
-- Each template-declared captured floor cell is refreshed through addFloor,
-- then the same captured object is restored with its identity and state intact.
-- This module owns no transaction, retry or relocation state.

local Core = require("RailroaderRV/Core/RV_Server_Core")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local refreshPoints = RoomTemplate.roofRefreshPoints(Template)
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

local function refreshPoint(cell, bounds, point)
    local x, y, z = pointCell(bounds, point)
    local square, reason = loadedSquare(cell, x, y, z)
    if not square then return false, reason end
    local originalFloor = square:getFloor()
    local originalFloorIndex = originalFloor:getObjectIndex()
    local temporary = square:addFloor(point.temporaryFloorSprite)
    ServerWorld.removeGenericObject(square, temporary)
    square:transmitAddObjectToSquare(originalFloor, originalFloorIndex)
    return true, "room synchronized at " .. coordinate(x, y, z)
end

local function refreshAllPoints(bounds)
    local cell = getCell()
    local reason
    for index = 1, #refreshPoints do
        local refreshed, pointReason = refreshPoint(cell, bounds,
            refreshPoints[index])
        if not refreshed then return false, pointReason end
        reason = pointReason
    end
    return true, reason
end

function Refresh.run(bounds)
    local refreshed, reason = refreshAllPoints(bounds)
    if refreshed ~= true then return fail(reason) end
    return true, reason
end

function Refresh.schedule(rvId)
    local callback = RailroaderRV.Server.refreshRoofVisuals
    local now = Core.getTick()
    local offsets = { 10, 50, 100, 200 }
    for index = 1, #offsets do
        Core.scheduleAtTick(Core.tickAdd(now, offsets[index]),
            callback, rvId)
    end
    return true
end

return Refresh
