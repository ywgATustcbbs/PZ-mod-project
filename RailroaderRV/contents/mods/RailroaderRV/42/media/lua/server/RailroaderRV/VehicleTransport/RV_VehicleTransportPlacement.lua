-- Server-authoritative vehicle placement for flatcar unloading.
--
-- The native addVehicleDebug entry point performs BaseVehicle/physics,
-- VehiclesDB2, chunk and network registration.  Its spawn event runs before
-- createPhysics finishes, so this module fixes the initial transform there and
-- prevents addToWorld from generating a replacement key.
local Placement = {}
local State = require("RailroaderRV/VehicleTransport/RV_VehicleTransportState")

local function vehicleScriptDimensions(vehicleScript)
    local script = getScriptManager():getVehicle(vehicleScript)
    local extents = script:getExtents()
    return extents:x(), extents:z()
end

local function normalizedDirection(geometry)
    local length = math.sqrt(geometry.dirX * geometry.dirX
        + geometry.dirY * geometry.dirY)
    return geometry.dirX / length, geometry.dirY / length
end

local function sign(value)
    return value < 0 and -1 or 1
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function playerFacingFace(along, across, halfLength, halfWidth)
    local alongExcess = math.abs(along) - halfLength
    local acrossExcess = math.abs(across) - halfWidth

    if alongExcess >= 0 and acrossExcess >= 0 then
        if math.abs(along) / halfLength
                >= math.abs(across) / halfWidth then
            return "along", sign(along)
        end
        return "across", sign(across)
    end
    if alongExcess >= 0 then return "along", sign(along) end
    if acrossExcess >= 0 then
        return "across", sign(across)
    end
    if alongExcess > acrossExcess then
        return "along", sign(along)
    end
    return "across", sign(across)
end

local function isFootprintClear(cell, vehicleScript, x, y, z, dirX, dirY)
    local width, length = vehicleScriptDimensions(vehicleScript)
    -- VehicleScript extents give a conservative axis-aligned bounding box.
    -- Scanning this box avoids treating the nearby flatcar or player as part
    -- of the cargo vehicle's footprint just because they are close by.
    local halfX = math.abs(dirX) * length / 2
        + math.abs(dirY) * width / 2
    local halfY = math.abs(dirY) * length / 2
        + math.abs(dirX) * width / 2
    local minX, maxX = math.floor(x - halfX), math.ceil(x + halfX) - 1
    local minY, maxY = math.floor(y - halfY), math.ceil(y + halfY) - 1

    for tileX = minX, maxX do
        for tileY = minY, maxY do
            local square = cell:getGridSquare(tileX, tileY, z)
            if square == nil or not square:hasFloor()
                    or not square:isFree(true)
                    or square:isVehicleIntersecting() then
                return false
            end

            -- Check the footprint perimeter and its interior for wall/door
            -- edges. Missing adjacent squares outside the scanned footprint
            -- do not make an otherwise loaded placement invalid.
            local neighbours = {
                { tileX + 1, tileY }, { tileX - 1, tileY },
                { tileX, tileY + 1 }, { tileX, tileY - 1 },
            }
            for _, coordinates in ipairs(neighbours) do
                local neighbour = cell:getGridSquare(
                    coordinates[1], coordinates[2], z)
                if neighbour ~= nil and square:isBlockedTo(neighbour) then
                    return false
                end
            end
        end
    end
    return true
end

function Placement.findUnloadPose(cell, player, geometry, vehicleScript)
    local dirX, dirY = normalizedDirection(geometry)
    local sideX, sideY = -dirY, dirX
    local playerDeltaX, playerDeltaY = player:getX() - geometry.x,
        player:getY() - geometry.y
    local playerAlong = playerDeltaX * dirX + playerDeltaY * dirY
    local playerAcross = playerDeltaX * sideX + playerDeltaY * sideY
    local face, faceSign = playerFacingFace(playerAlong, playerAcross,
        geometry.halfLengthTiles, geometry.halfWidthTiles)
    local width, length = vehicleScriptDimensions(vehicleScript)
    -- Project the rotated axis-aligned footprint onto both flatcar axes.
    local diagonalExtent = math.abs(dirX * dirY)
    local vehicleHalfAlong = length / 2 + width * diagonalExtent
    local vehicleHalfAcross = width / 2 + length * diagonalExtent
    local faceHalfExtent = face == "along"
        and geometry.halfLengthTiles or geometry.halfWidthTiles
    local vehicleHalfFace = face == "along"
        and vehicleHalfAlong or vehicleHalfAcross
    local normalX, normalY
    if face == "along" then
        normalX, normalY = dirX * faceSign, dirY * faceSign
    else
        normalX, normalY = sideX * faceSign, sideY * faceSign
    end
    local carClearance = faceHalfExtent + vehicleHalfFace + 0.75

    local playerTileX = math.floor(player:getX()) + 0.5
    local playerTileY = math.floor(player:getY()) + 0.5
    local playerTileFace = ((playerTileX - geometry.x) * normalX
        + (playerTileY - geometry.y) * normalY)
    local playerTileHalfFace = (math.abs(normalX) + math.abs(normalY)) / 2
    local playerClearance = playerTileFace + playerTileHalfFace
        + vehicleHalfFace + 0.01
    local firstFaceDistance = math.max(carClearance, playerClearance)
    -- Separate additional lanes by a full projected AABB plus one tile.
    local faceLaneStep = vehicleHalfFace * 2 + 1
    local tangentPlayer = face == "along" and playerAcross or playerAlong
    local tangentHalfExtent = face == "along"
        and geometry.halfWidthTiles or geometry.halfLengthTiles
    local maxTangent = math.max(tangentHalfExtent - 1, 0)
    local offsets = { 0, 1, -1, 2, -2, 3, -3, 4, -4 }
    local direction = IsoDirections.fromAngle(dirX, dirY)

    for lane = 0, 2 do
        local faceDistance = firstFaceDistance + lane * faceLaneStep
        for _, offset in ipairs(offsets) do
            local tangent = clamp(tangentPlayer + offset,
                -maxTangent, maxTangent)
            local along, across
            if face == "along" then
                along, across = faceSign * faceDistance, tangent
            else
                along, across = tangent, faceSign * faceDistance
            end
            local x = geometry.x + dirX * along + sideX * across
            local y = geometry.y + dirY * along + sideY * across
            local z = math.floor(geometry.z)
            if isFootprintClear(cell, vehicleScript, x, y, z, dirX, dirY) then
                return {
                    x = x,
                    y = y,
                    z = z,
                    direction = direction,
                    yawDegrees = math.deg(direction:toAngle() + math.pi),
                }
            end
        end
    end
    return nil
end

local function markVehicleStateForClients(vehicle)
    for index = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(index)
        vehicle:transmitPartCondition(part)
        vehicle:transmitPartItem(part)
        vehicle:transmitPartModData(part)
        vehicle:transmitPartUsedDelta(part)
        vehicle:transmitPartDoor(part)
        vehicle:transmitPartWindow(part)
        vehicle:transmitPartLight(part)
    end
    vehicle:flagForHotSave()
end

local function removeSpawnedVehicle(vehicle)
    if vehicle ~= nil and vehicle:getSquare() ~= nil then
        vehicle:permanentlyRemove()
    end
end

function Placement.spawn(cell, vehicleScript, pose, snapshot)
    local square = cell:getGridSquare(
        math.floor(pose.x), math.floor(pose.y), pose.z)
    if square == nil then return false, "unload-blocked" end

    local spawnEvent = Events.OnSpawnVehicleStart
    local corrected = false
    local handler = function(vehicle)
        if corrected or vehicle:getScriptName() ~= vehicleScript
                or vehicle:getSquare() ~= square then
            return
        end
        vehicle:setPreviouslyMoved(true)
        vehicle:setX(pose.x)
        vehicle:setY(pose.y)
        vehicle:setZ(pose.z)
        vehicle:setAngles(0, pose.yawDegrees, 0)
        corrected = true
    end

    local callOk, result = pcall(function()
        spawnEvent.Add(handler)
        return addVehicleDebug(vehicleScript, pose.direction, nil, square)
    end)
    spawnEvent.Remove(handler)
    if not callOk then
        error(result, 0)
    end
    local vehicle = result
    if vehicle == nil then
        return false, "unload-blocked"
    end
    if vehicle:getSquare() == nil then
        removeSpawnedVehicle(vehicle)
        return false, "unload-blocked"
    end
    if not corrected then
        removeSpawnedVehicle(vehicle)
        error("OnSpawnVehicleStart handler did not correct spawned vehicle", 0)
    end

    local restoreOk, restoreFailure = pcall(State.restore, vehicle, snapshot)
    if not restoreOk then
        removeSpawnedVehicle(vehicle)
        error(restoreFailure, 0)
    end
    markVehicleStateForClients(vehicle)
    return true, vehicle
end

return Placement
