-- Server-authoritative room/roof metadata refresh for generated RV rooms.
--
-- Recalculate room and roof-neighbour state around the existing captured floor
-- outside the cab's south window. The same floor is identity-checked before
-- and after synchronization; this path does not add or remove floor objects.

require("RailroaderRV/RV_Constants")
local Template = require("RailroaderRV/RV_Template")
local ServerWorld = require("RailroaderRV/RV_ServerWorld")

RailroaderRV = RailroaderRV or {}
RailroaderRV.RoofRefresh = RailroaderRV.RoofRefresh or {}

local Refresh = RailroaderRV.RoofRefresh
local C = RailroaderRV.Constants
local unpackFn = (table and table.unpack) or unpack

local function toNumber(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) end
    if value == nil then return nil end
    local ok, numeric = pcall(function() return value + 0 end)
    return ok and type(numeric) == "number" and numeric or nil
end

local function invoke(target, method, ...)
    if target == nil or type(target[method]) ~= "function" then
        return false, nil
    end
    local args = { ... }
    local ok, a, b = pcall(function()
        return target[method](target, unpackFn(args))
    end)
    if not ok then return false, a end
    return true, a, b
end

local function callGlobal(name, ...)
    local fn = rawget(_G, name)
    if type(fn) ~= "function" then return false, nil end
    local args = { ... }
    local ok, a = pcall(function() return fn(unpackFn(args)) end)
    if not ok then return false, a end
    return true, a
end

local function callSucceeded(target, method, ...)
    local ok, result = invoke(target, method, ...)
    return ok and result ~= false
end

local function integer(value, label)
    local numeric = toNumber(value)
    if numeric == nil or math.floor(numeric) ~= numeric then
        error("RailroaderRVTest: roof refresh " .. tostring(label)
            .. " is not an integer")
    end
    return numeric
end

local function getCell(player)
    local ok, cell = invoke(player, "getCell")
    if ok and cell then return cell end
    local globalOk, globalCell = callGlobal("getCell")
    if globalOk and globalCell then return globalCell end
    return nil
end

local function getSquare(cell, x, y, z)
    local ok, square = invoke(cell, "getGridSquare", x, y, z)
    return ok and square or nil
end

local function worldSquareIsValid(x, y, z)
    local worldOk, world = callGlobal("getWorld")
    if not worldOk or not world then return true end
    local validOk, valid = invoke(world, "isValidSquare", x, y, z)
    return not validOk or valid == true
end

local function southWindowFloorTarget(bounds)
    if type(bounds) ~= "table" then
        error("RailroaderRVTest: roof refresh bounds are unavailable")
    end
    local roomMinX = integer(bounds.roomMinX, "roomMinX")
    local roomMinY = integer(bounds.roomMinY, "roomMinY")
    local z = integer(bounds.z, "z")
    local anchorX = roomMinX - C.INTERIOR_MIN_OFFSET_X
    local anchorY = roomMinY - C.INTERIOR_MIN_OFFSET_Y
    local windows = {}
    for i = 1, #Template.objects do
        local entry = Template.objects[i]
        if entry.class == "IsoWindow" and entry.z == 0
            and entry.x >= C.CAB_MIN_OFFSET_X and entry.x <= C.CAB_MAX_OFFSET_X
            and entry.y == C.CAB_MAX_OFFSET_Y + 1 then
            windows[#windows + 1] = entry
        end
    end
    if #windows ~= 1 then
        error("RailroaderRVTest: captured cab south window is not unique")
    end
    local window = windows[1]
    local targetX, targetY = window.x, window.y + 1
    local floors = {}
    for i = 1, #Template.objects do
        local entry = Template.objects[i]
        if entry.class == "IsoObject" and entry.x == targetX
            and entry.y == targetY and entry.z == 0 then
            floors[#floors + 1] = { entry = entry, templateIndex = i }
        end
    end
    if #floors ~= 1 then
        error("RailroaderRVTest: captured floor outside cab south window is not unique")
    end
    local captured = floors[1]
    return {
        x = anchorX + targetX,
        y = anchorY + targetY,
        z = z,
        entry = captured.entry,
        templateIndex = captured.templateIndex,
    }
end

local function recalcSquare(cell, square)
    local okX, x = invoke(square, "getX")
    local okY, y = invoke(square, "getY")
    if not okX or not okY then
        return false, "captured floor square coordinates are unavailable"
    end
    if not callSucceeded(square, "EnsureSurroundNotNull")
        or not callSucceeded(square, "RecalcProperties")
        or not callSucceeded(cell, "checkHaveRoof", x, y)
        or not callSucceeded(square, "clearWater")
        or not callSucceeded(square, "RecalcAllWithNeighbours", true) then
        return false, "captured floor room synchronization failed"
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

-- B42 may expose the player square before all neighbouring wall/roof squares
-- have streamed into the same IsoCell. Keep readiness bounded to the current
-- manifest's wall/roof geometry and the exact template-derived refresh square.
local function loadedRefreshSquares(player, bounds)
    if type(bounds) ~= "table" then
        return false, "RV bounds are unavailable"
    end
    local cell = getCell(player)
    if not cell then return false, "server IsoCell is unavailable" end
    local seen = {}
    local function requireSquare(x, y, z, role)
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if seen[key] then return true end
        seen[key] = true
        if not worldSquareIsValid(x, y, z) then
            return false, "roof refresh " .. tostring(role)
                .. " is outside the legal world"
        end
        if not getSquare(cell, x, y, z) then
            return false, "roof refresh squares are not loaded"
        end
        return true
    end

    local wallMinX = integer(bounds.wallMinX, "wallMinX")
    local wallMaxX = integer(bounds.wallMaxX, "wallMaxX")
    local wallMinY = integer(bounds.wallMinY, "wallMinY")
    local wallMaxY = integer(bounds.wallMaxY, "wallMaxY")
    local wallZ = integer(bounds.z, "z")
    for y = wallMinY, wallMaxY do
        for x = wallMinX, wallMaxX do
            local ready, reason = requireSquare(x, y, wallZ, "wall")
            if not ready then return false, reason end
        end
    end

    local roofZ = integer(bounds.roofZ, "roofZ")
    local anchorX = integer(bounds.roomMinX, "roomMinX") - C.INTERIOR_MIN_OFFSET_X
    local anchorY = integer(bounds.roomMinY, "roomMinY") - C.INTERIOR_MIN_OFFSET_Y
    for i = 1, #Template.objects do
        local captured = Template.objects[i]
        if captured.z == C.ROOF_Z_OFFSET then
            local x, y = anchorX + captured.x, anchorY + captured.y
            local ready, reason = requireSquare(x, y, roofZ, "captured roof object")
            if not ready then return false, reason end
        end
    end

    local target = southWindowFloorTarget(bounds)
    local ready, reason = requireSquare(target.x, target.y, target.z,
        "captured south-window floor")
    if not ready then return false, reason end
    return true
end

function Refresh.isLoaded(player, bounds)
    local ok, loaded, reason = pcall(loadedRefreshSquares, player, bounds)
    if not ok then return false, tostring(loaded) end
    return loaded == true, reason
end

local function diagnosticValue(value)
    if value == nil then return "<nil>" end
    local ok, result = pcall(tostring, value)
    if not ok then return "<unprintable>" end
    return string.gsub(result, "[\r\n]", " ")
end

local function identityTagSummary(tag)
    if type(tag) ~= "table" then return "<missing>" end
    return "owner=" .. diagnosticValue(tag.owner)
        .. ",rvId=" .. diagnosticValue(tag.rvId)
        .. ",generation=" .. diagnosticValue(tag.generation)
        .. ",bitmapVersion=" .. diagnosticValue(tag.bitmapVersion)
end

local function capturedFloorMismatch(floor, target, identity)
    if not floor then return "floor expected=present observed=missing" end
    if type(target) ~= "table" or type(target.entry) ~= "table" then
        return "target expected=current south-window floor observed=invalid"
    end
    if type(identity) ~= "table" then
        return "identity expected=table observed=" .. diagnosticValue(identity)
    end
    local generation = toNumber(identity.generation)
    local bitmapVersion = toNumber(identity.bitmapVersion)
    if identity.rvId == nil or tostring(identity.rvId) == ""
        or generation == nil or math.floor(generation) ~= generation or generation < 1
        or bitmapVersion == nil or math.floor(bitmapVersion) ~= bitmapVersion
        or bitmapVersion ~= C.BITMAP_VERSION then
        return "identity expected={rvId=nonempty,generation=positive integer,bitmapVersion="
            .. diagnosticValue(C.BITMAP_VERSION) .. "} observed={rvId="
            .. diagnosticValue(identity.rvId) .. ",generation="
            .. diagnosticValue(identity.generation) .. ",bitmapVersion="
            .. diagnosticValue(identity.bitmapVersion) .. "}"
    end

    local entry = target.entry
    local sprite = ServerWorld.getSpriteName(floor)
    if sprite ~= entry.sprite then
        return "sprite expected=" .. diagnosticValue(entry.sprite)
            .. " observed=" .. diagnosticValue(sprite)
    end
    local data = ServerWorld.objectModData(floor)
    local tag = type(data) == "table" and data.RailroaderRVTest or nil
    if not ServerWorld.isTaggedForGeneration(floor, generation,
        identity.rvId, bitmapVersion) then
        local rootTag = type(data) == "table" and data or nil
        return "generation identity expected={owner=" .. diagnosticValue(C.MOD_ID)
            .. ",rvId=" .. diagnosticValue(identity.rvId)
            .. ",generation=" .. diagnosticValue(generation)
            .. ",bitmapVersion=" .. diagnosticValue(bitmapVersion)
            .. "} observed.root={" .. identityTagSummary(rootTag)
            .. "} observed.nested={" .. identityTagSummary(tag) .. "}"
    end
    if type(tag) ~= "table" then
        return "template tag expected=table observed=" .. diagnosticValue(tag)
    end
    local checks = {
        { "owner", C.MOD_ID, tag.owner },
        { "role", "captured-template", tag.role },
        { "templateIndex", target.templateIndex, toNumber(tag.templateIndex) },
        { "templateClass", entry.class, tag.templateClass },
        { "templateName", entry.name, tag.templateName },
        { "templateSprite", entry.sprite, tag.templateSprite },
        { "templateNorth", entry.north, tag.templateNorth },
        { "templateDirection", entry.direction, tag.templateDirection },
    }
    for i = 1, #checks do
        local check = checks[i]
        if check[2] ~= check[3] then
            return "tag." .. check[1] .. " expected="
                .. diagnosticValue(check[2]) .. " observed="
                .. diagnosticValue(check[3])
        end
    end
    return nil
end

local function capturedFloorMatches(floor, target, identity)
    return capturedFloorMismatch(floor, target, identity) == nil
end

local lastFloorIdentityDiagnostic = {}
local function reportFloorIdentityMismatch(target, identity, detail)
    local rvId = type(identity) == "table" and identity.rvId or nil
    local generation = type(identity) == "table" and identity.generation or nil
    local bitmapVersion = type(identity) == "table" and identity.bitmapVersion or nil
    local key = diagnosticValue(rvId) .. ":" .. diagnosticValue(generation)
        .. ":" .. diagnosticValue(bitmapVersion)
    if lastFloorIdentityDiagnostic[key] == detail then return end
    lastFloorIdentityDiagnostic[key] = detail
    print("[RailroaderRVTest] captured south-window floor identity mismatch rvId="
        .. diagnosticValue(rvId) .. " generation=" .. diagnosticValue(generation)
        .. " bitmapVersion=" .. diagnosticValue(bitmapVersion)
        .. " target=" .. diagnosticValue(target.x) .. ","
        .. diagnosticValue(target.y) .. "," .. diagnosticValue(target.z)
        .. " failed=" .. detail)
end

local function refreshRoomMetadata(player, bounds, identity)
    if type(bounds) ~= "table" then return false, "RV bounds are unavailable" end
    local cell = getCell(player)
    if not cell then return false, "server IsoCell is unavailable" end
    local target = southWindowFloorTarget(bounds)
    if not worldSquareIsValid(target.x, target.y, target.z) then
        return false, "captured south-window floor is outside the legal world"
    end
    local square = getSquare(cell, target.x, target.y, target.z)
    if not square then return false, "captured south-window floor square is not loaded" end
    local floorOk, floor = invoke(square, "getFloor")
    local floorMismatch = not floorOk
        and "getFloor expected=available observed=invoke-failed"
        or capturedFloorMismatch(floor, target, identity)
    if floorMismatch then
        reportFloorIdentityMismatch(target, identity, floorMismatch)
        return false, "captured south-window floor identity rejected"
    end
    local synchronized, syncReason = recalcSquare(cell, square)
    if not synchronized then return false, syncReason end
    local verifyOk, remaining = invoke(square, "getFloor")
    if not verifyOk or remaining ~= floor
        or not capturedFloorMatches(remaining, target, identity) then
        local mismatch = not verifyOk
            and "post-sync getFloor expected=available observed=invoke-failed"
            or remaining ~= floor
                and "post-sync floor expected=same object observed=changed"
            or capturedFloorMismatch(remaining, target, identity)
        if mismatch then reportFloorIdentityMismatch(target, identity, mismatch) end
        return false, "captured south-window floor changed during room synchronization"
    end
    return true, "room synchronized at " .. tostring(target.x) .. ","
        .. tostring(target.y) .. "," .. tostring(target.z)
end

function Refresh.run(player, bounds, identity)
    if Refresh._busy then return false, "roof refresh is already in progress" end
    Refresh._busy = true
    local ok, refreshed, reason = pcall(refreshRoomMetadata, player, bounds, identity)
    Refresh._busy = false
    if not ok then return false, tostring(refreshed) end
    return refreshed == true, reason
end

return Refresh
