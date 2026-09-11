-- Server-authoritative roof-cache repair for generated RV rooms.
--
-- B42 recomputes the roof/room neighbours when the player-building path adds
-- and removes a floor.  A generated upper floor can otherwise retain the
-- exterior roof cache after a repeat entry.  This module performs that same
-- short-lived world mutation on an empty square immediately west of the RV's
-- NW wall corner, then removes the temporary object through the official
-- networked removal API.  It never replaces an existing floor or object.

require("RailroaderRV/RV_Constants")

RailroaderRV = RailroaderRV or {}
RailroaderRV.RoofRepair = RailroaderRV.RoofRepair or {}

local Repair = RailroaderRV.RoofRepair
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
        error("RailroaderRVTest: roof repair " .. tostring(label)
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

local function collectionHasObject(collection)
    if collection == nil then return false end
    local sizeOk, size = invoke(collection, "size")
    local numericSize = toNumber(size)
    if sizeOk and numericSize ~= nil then return numericSize > 0 end
    if type(collection) == "table" then
        for _, value in pairs(collection) do
            if value ~= nil then return true end
        end
    end
    return false
end

local function squareHasObject(square)
    local collections = {
        "getObjects", "getSpecialObjects", "getStaticMovingObjects",
        "getMovingObjects", "getWorldObjects", "getDeadBodys", "getCorpses",
    }
    for i = 1, #collections do
        local ok, collection = invoke(square, collections[i])
        if ok and collectionHasObject(collection) then return true end
    end
    local vehicleOk, vehicle = invoke(square, "getVehicleContainer")
    return vehicleOk and vehicle ~= nil
end

local function squareIsUsable(square)
    if not square then return false, "square is unavailable" end
    local floorOk, floor = invoke(square, "getFloor")
    if not floorOk then return false, "getFloor is unavailable" end
    if floor ~= nil then return false, "square already has a floor" end
    if squareHasObject(square) then return false, "square already has an object" end
    -- IsoGridSquare:isFree() returns false for an empty square with no floor,
    -- which is exactly the legal target for the player-building addFloor path.
    -- Object collections above are the non-destructive occupancy guard.
    return true
end

local function recalcSquare(square)
    -- These are the B42 names used by the official player-building path.  The
    -- add/remove calls already recalculate locally; this closes the same
    -- neighbour pass explicitly before the player can inspect the roof.
    invoke(square, "RecalcProperties")
    invoke(square, "RecalcAllWithNeighbours", true)
end

local function removeTemporaryFloor(square, floor)
    if not floor then return false, "temporary floor is unavailable" end
    local ok, removeIndex = invoke(square, "transmitRemoveItemFromSquare", floor)
    local index = toNumber(removeIndex)
    if not ok or index == nil or index < 0 then
        return false, "temporary floor removal transmission failed"
    end
    recalcSquare(square)
    local verifyOk, remaining = invoke(square, "getFloor")
    if not verifyOk or remaining ~= nil then
        return false, "temporary floor remains after removal"
    end
    return true
end

local function worldSquareIsValid(x, y, z)
    local worldOk, world = callGlobal("getWorld")
    if not worldOk or not world then return true end
    local validOk, valid = invoke(world, "isValidSquare", x, y, z)
    return not validOk or valid == true
end

local function candidateList(bounds)
    local wallMinX = integer(bounds.wallMinX, "wallMinX")
    local wallMaxX = integer(bounds.wallMaxX, "wallMaxX")
    local wallMinY = integer(bounds.wallMinY, "wallMinY")
    local wallMaxY = integer(bounds.wallMaxY, "wallMaxY")
    local z = integer(bounds.z, "z")
    local result, seen = {}, {}
    local function add(x, y)
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if not seen[key] then
            seen[key] = true
            result[#result + 1] = { x = x, y = y, z = z }
        end
    end

    -- Fixed preferred location: immediately west of the generated NW corner.
    add(wallMinX - 1, wallMinY)
    -- Any west-wall neighbour has the same B42 neighbour invalidation effect.
    for y = wallMinY, wallMaxY do add(wallMinX - 1, y) end
    -- Keep a narrow north-side fallback for a pre-existing object on the west
    -- side.  It is still outside the 7x41 wall footprint and never overwrites.
    for x = wallMinX, wallMaxX do add(x, wallMinY - 1) end
    return result
end

local function repairInternal(player, bounds)
    if type(bounds) ~= "table" then return false, "RV bounds are unavailable" end
    local cell = getCell(player)
    if not cell then return false, "server IsoCell is unavailable" end
    local sprite = C.ROOF_FLOOR_SPRITE or C.WOOD_FLOOR_SPRITE
    if type(sprite) ~= "string" or sprite == "" then
        return false, "wood floor sprite is unavailable"
    end

    local candidates = candidateList(bounds)
    local skipped = {}
    for i = 1, #candidates do
        local point = candidates[i]
        if worldSquareIsValid(point.x, point.y, point.z) then
            local square = getSquare(cell, point.x, point.y, point.z)
            local usable, reason = squareIsUsable(square)
            if usable then
                local addOk, addResult = invoke(square, "addFloor", sprite)
                if addOk and addResult ~= false then
                    local floorOk, floor = invoke(square, "getFloor")
                    if floorOk and floor then
                        local broadcastOk = callSucceeded(floor,
                            "transmitCompleteItemToClients")
                        recalcSquare(square)
                        if broadcastOk then
                            local removed, removeReason = removeTemporaryFloor(
                                square, floor)
                            if removed then
                                return true, "repaired at " .. tostring(point.x)
                                    .. "," .. tostring(point.y) .. ","
                                    .. tostring(point.z)
                            end
                            return false, removeReason
                        end
                        local cleaned, cleanupReason = removeTemporaryFloor(
                            square, floor)
                        if not cleaned then
                            return false, "temporary floor broadcast failed and "
                                .. tostring(cleanupReason)
                        end
                        return false, "temporary floor broadcast failed"
                    end
                    return false, "temporary floor was not created"
                end
                skipped[#skipped + 1] = "addFloor failed at " .. tostring(point.x)
                    .. "," .. tostring(point.y)
            elseif square ~= nil then
                skipped[#skipped + 1] = tostring(point.x) .. "," .. tostring(point.y)
                    .. ":" .. tostring(reason)
            end
        end
    end
    if #skipped > 0 then
        return false, "no empty west/NW repair square (" .. table.concat(skipped, "; ") .. ")"
    end
    return false, "roof repair squares are not loaded"
end

function Repair.run(player, bounds)
    if Repair._busy then return false, "roof repair is already in progress" end
    Repair._busy = true
    local ok, repaired, reason = pcall(repairInternal, player, bounds)
    Repair._busy = false
    if not ok then return false, tostring(repaired) end
    return repaired == true, reason
end

return Repair
