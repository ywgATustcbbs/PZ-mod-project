-- Client presentation for server-marked BX40 flatcars.
--
-- The server saves stable Railroader IDs and cargo layout.  The floor and the
-- individual cargo models below are tagged client decorations; they are never
-- sent to or created by the server.
local C = require("RailroaderRV/Common/RV_Constants")
local Cargo = require("RailroaderRV/Cargo/RV_FlatcarCargoCatalog")
local Units = require("RailroaderRV/RVMapping/RV_RailroaderUnits")
local CargoNotice = require(
    "RailroaderRV/GUI/RV_FlatcarCargoNoticeClient")

RailroaderRV = RailroaderRV or {}
local Client = RailroaderRV.FlatcarVisualClient or {}
RailroaderRV.FlatcarVisualClient = Client

Client.flatcars = Client.flatcars or {}
Client.floors = Client.floors or {}
Client.vehicles = Client.vehicles or {}
Client.endpointMarkers = Client.endpointMarkers or {}
local unloadPreviewHover = nil
Client.dynamicModelScripts = Client.dynamicModelScripts or {}
Client.visualGeneration = Client.visualGeneration or 0
-- Endpoint markers are opt-in visual diagnostics.
Client.debugEndpointMarkersEnabled =
    Client.debugEndpointMarkersEnabled == true

local RR = RR
local Cars = RR.Cars
local BODY_FLOOR_TYPE = "rr_bx40s_floor"
local FLOOR_MARKER = "railroaderRVFlatcarFloor"
local CARGO_MARKER = "railroaderRVFlatcarCargoVehicle"
local ENDPOINT_MARKER_TYPE = "rr_rv_flatcar_endpoint_marker"
local ENDPOINT_MARKER_ITEM = "RailroaderRV.RVFlatcarEndpointMarker"
local ENDPOINT_MARKER_LOCATIONS = {
    "RVFlatcarEndpointStart",
    "RVFlatcarEndpointEnd",
}
-- User-verified visual adjustment after the prior -0.65m value. cargoPose
-- applies the resulting -0.85m after the flipped-car turn.
local CARGO_LATERAL_OFFSET = -0.85
local ANIMAL_MODEL_SCALE = 1.5
local localPlayer
local gameStarted = false
local snapshotRequested = false
local records = {}
local ticks = 0
local cargoPose
local layoutSignatures = {}
local traceUnits = {}
local duplicateRecords = {}
local debugRecordIds = setmetatable({}, { __mode = "k" })
local decorationOwners = setmetatable({}, { __mode = "k" })
local cargoEntries = setmetatable({}, { __mode = "k" })
local floorAnimals = {}
local floorSources = {}
local nextDebugRecordId = 0
local nextDebugRootId = 0

local function idKey(unitId)
    if unitId == nil then return nil end
    return tostring(unitId)
end

local function recordIdentity(record)
    local identity = debugRecordIds[record]
    if not identity then
        nextDebugRecordId = nextDebugRecordId + 1
        identity = "record#" .. tostring(nextDebugRecordId)
        debugRecordIds[record] = identity
    end
    return identity
end

local function cargoLayoutSignature(cars)
    local parts = {}
    for _, car in ipairs(cars) do
        parts[#parts + 1] = string.format("%s:%s@%.3f",
            car.cargoId, car.vehicleScript, car.center)
    end
    return table.concat(parts, ";")
end

local function describeCargoLayout(cars)
    if #cars == 0 then return "empty" end
    local parts = {}
    for _, car in ipairs(cars) do
        local length = Cargo.length(car.vehicleScript)
        parts[#parts + 1] = string.format(
            "cargoId=%s:%s length=%.3f center=%.3f ends=[%.3f,%.3f]",
            car.cargoId, car.vehicleScript, length, car.center,
            car.center - length / 2, car.center + length / 2)
    end
    return table.concat(parts, "; ")
end

local function rootSummary(key)
    local vehicles = Client.vehicles[key]
    if not vehicles then return "none" end
    local parts = {}
    for cargoId, entry in pairs(vehicles) do
        parts[#parts + 1] = string.format("cargoId=%s=root#%s:%s",
            tostring(cargoId), tostring(entry.debugRootId),
            tostring(entry.vehicleScript))
    end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ",") or "none"
end

local function traceCargoPose(record, unit, key, pose, cars, hasDuplicateRecord)
    local identity = recordIdentity(record)
    local layout = layoutSignatures[key]
    local roots = rootSummary(key)
    local cell = string.format("%d,%d,%d",
        math.floor(pose.x), math.floor(pose.y), math.floor(pose.z))
    local state = traceUnits[key] or {}
    local reasons = {}
    if not hasDuplicateRecord then
        if not state.recordIdentity then reasons[#reasons + 1] = "first-seen"
        elseif state.recordIdentity ~= identity then
            reasons[#reasons + 1] = "record-change"
        end
    end
    if state.layout ~= layout then reasons[#reasons + 1] = "layout-change" end
    if state.roots ~= roots then reasons[#reasons + 1] = "root-owner-change" end
    if not hasDuplicateRecord and state.poseCell ~= cell then
        reasons[#reasons + 1] = "pose-cell-change"
    end
    local sampleWindow = math.floor(ticks / 60)
    if state.sampleWindow ~= sampleWindow then
        reasons[#reasons + 1] = "pose-sample"
    end

    if #reasons > 0 then
        local recordOwner = record and (record.id or record.trainId)
        local floorAnimal = floorAnimals[key]
        -- IsoAnimal getters expose its logical root pose, not the skinned mesh origin.
        local floorX, floorY, floorZ = floorAnimal:getX(), floorAnimal:getY(),
            floorAnimal:getZ()
        local floorDirAngle = floorAnimal:getForwardDirection():getDirection()
        local floorDirX, floorDirY = pose.dirX, pose.dirY
        if unit.f == true then floorDirX, floorDirY = -floorDirX, -floorDirY end
        local floorSideX, floorSideY = floorDirY, -floorDirX
        local floorDeltaX, floorDeltaY = floorX - pose.x, floorY - pose.y
        local floorPerp = floorDeltaX * floorSideX
            + floorDeltaY * floorSideY
        Cargo.debug(
            "client visual reasons=%s flatcarId=%s unitId=%s record=%s recordId=%s owner=%s pose=(%.3f,%.3f,%.3f) dir=(%.3f,%.3f) flipped=%s deckZ=%.3f cargoCount=%d roots={%s}",
            table.concat(reasons, ","), key, tostring(unit.id), identity,
            tostring(recordOwner), tostring(unit.locomotiveId or "cut"),
            pose.x, pose.y, pose.z, pose.dirX, pose.dirY,
            tostring(unit.f == true),
            RR.Consist.KINDS[unit.kind].interior.deckZ, #cars, roots)
        Cargo.debug(
            "client floor flatcarId=%s source=%s entityRef=%s targetRoot=(%.3f,%.3f,%.3f) targetDir=(%.3f,%.3f) actualRoot=(%.3f,%.3f,%.3f) currentDirRad=%.3f logicalRootDelta=(%.3f,%.3f,%.3f) logicalRootPerpDelta=%.3f",
            key, floorSources[key], tostring(floorAnimal),
            pose.x, pose.y, pose.z, floorDirX, floorDirY,
            floorX, floorY, floorZ, floorDirAngle,
            floorDeltaX, floorDeltaY, floorZ - pose.z, floorPerp)
        for _, car in ipairs(cars) do
            local entry = Client.vehicles[key][car.cargoId]
            local position = cargoPose(unit, pose, car.center)
            local cargoAnimal = entry.animal
            local cargoX, cargoY, cargoZ = cargoAnimal:getX(),
                cargoAnimal:getY(), cargoAnimal:getZ()
            local cargoDirAngle = cargoAnimal:getForwardDirection():getDirection()
            local cargoDeltaX, cargoDeltaY = cargoX - position.x,
                cargoY - position.y
            local cargoPerp = cargoDeltaX * position.dirY
                - cargoDeltaY * position.dirX
            local relativeDeltaX = cargoX - floorX
                - car.center * floorDirX
            local relativeDeltaY = cargoY - floorY
                - car.center * floorDirY
            local cargoVsFloorPerp = relativeDeltaX * floorSideX
                + relativeDeltaY * floorSideY
            local length = Cargo.length(car.vehicleScript)
            Cargo.debug(
                "client cargo flatcarId=%s cargoId=%s vehicleScript=%s center=%.3f length=%.3f deckEnds=[%.3f,%.3f] boundsBasis=VehicleScript:getExtents().z targetRoot=(%.3f,%.3f,%.3f) targetDir=(%.3f,%.3f) actualRoot=(%.3f,%.3f,%.3f) currentDirRad=%.3f logicalRootDelta=(%.3f,%.3f,%.3f) logicalRootPerpDelta=%.3f configuredLateralOffset=%.3f expectedCargoVsFloorLogicalRootPerpDelta=%.3f cargoVsFloorLogicalRootPerpDelta=%.3f root=root#%s entityRef=%s attachments=%s anchor=%s bodyItem=%s",
                key, tostring(car.cargoId), car.vehicleScript,
                car.center, length, car.center - length / 2,
                car.center + length / 2, position.x, position.y,
                position.z, position.dirX, position.dirY,
                cargoX, cargoY, cargoZ, cargoDirAngle,
                cargoDeltaX, cargoDeltaY, cargoZ - position.z,
                cargoPerp, CARGO_LATERAL_OFFSET,
                CARGO_LATERAL_OFFSET, cargoVsFloorPerp,
                tostring(entry.debugRootId), tostring(cargoAnimal),
                tostring(entry.attachmentsApplied == true),
                Cargo.anchorModel, Cargo.bodyItem)
        end
        state.recordIdentity = identity
        state.layout = layout
        state.roots = roots
        state.poseCell = cell
        state.sampleWindow = sampleWindow
        traceUnits[key] = state
    end
end

function Client.isFlatcar(unitId)
    local key = idKey(unitId)
    return key ~= nil and Client.flatcars[key] ~= nil
end

function Client.cargoForUnit(unitId)
    return Client.flatcars[idKey(unitId)].cars
end

function Client.unitIdForDecoration(animal)
    local unitId = decorationOwners[animal]
    if unitId ~= nil then
        Cargo.debug("client decoration-owner animal=%s unitId=%s",
            tostring(animal), tostring(unitId))
    end
    return unitId
end

local function rememberFloor(key, animal, unitId)
    local previous = floorAnimals[key]
    if previous and previous ~= animal then
        decorationOwners[previous] = nil
    end
    local previousUnitId = decorationOwners[animal]
    if previousUnitId ~= nil and previousUnitId ~= unitId then
        Cargo.debug(
            "client decoration-owner-change animal=%s oldUnitId=%s newUnitId=%s kind=floor",
            tostring(animal), tostring(previousUnitId), tostring(unitId))
    end
    floorAnimals[key] = animal
    decorationOwners[animal] = unitId
end

function Client.requestConversion(player, unitId)
    if not player or unitId == nil then return false end
    sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_FLATCAR, {
        operation = "convert", unitId = unitId,
    })
    return true
end

function Client.requestLoadVehicle(player, unitId, vehicleId)
    if not player or unitId == nil or vehicleId == nil then return false end
    Cargo.debug("client request operation=load unitId=%s vehicleId=%s",
        tostring(unitId), tostring(vehicleId))
    sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_FLATCAR, {
        operation = "load", unitId = unitId, vehicleId = vehicleId,
    })
    return true
end

function Client.requestUnloadVehicle(player, unitId, cargoId)
    if not player or unitId == nil or cargoId == nil then return false end
    Client.clearUnloadPreview(unitId, cargoId)
    Cargo.debug("client request operation=unload unitId=%s cargoId=%s",
        tostring(unitId), tostring(cargoId))
    sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_FLATCAR, {
        operation = "unload", unitId = unitId, cargoId = cargoId,
    })
    return true
end

function Client.clearUnloadPreview(unitId, cargoId)
    local hovered = unloadPreviewHover
    if hovered == nil then return false end
    if unitId ~= nil and (hovered.unitId ~= unitId
            or hovered.cargoId ~= cargoId) then
        return false
    end
    unloadPreviewHover = nil
    Client.unloadPreview = nil
    return true
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
    if acrossExcess >= 0 then return "across", sign(across) end
    if alongExcess > acrossExcess then
        return "along", sign(along)
    end
    return "across", sign(across)
end

local function firstGeometricUnloadCandidate(player, unitId, vehicleScript)
    local unit = Units.find(unitId)
    if unit == nil or unit.kind ~= "car_bx40" then return nil end

    local playerX, playerY, playerZ = player:getX(), player:getY(),
        player:getZ()
    local geometry = Units.geometry(unit, playerX, playerY)
    if geometry == nil or geometry.z == nil
            or math.floor(geometry.z) ~= math.floor(playerZ) then
        return nil
    end

    local directionLength = math.sqrt(geometry.dirX * geometry.dirX
        + geometry.dirY * geometry.dirY)
    local dirX, dirY = geometry.dirX / directionLength,
        geometry.dirY / directionLength
    local sideX, sideY = -dirY, dirX
    local playerDeltaX, playerDeltaY = playerX - geometry.x,
        playerY - geometry.y
    local playerAlong = playerDeltaX * dirX + playerDeltaY * dirY
    local playerAcross = playerDeltaX * sideX + playerDeltaY * sideY
    local face, faceSign = playerFacingFace(playerAlong, playerAcross,
        geometry.halfLengthTiles, geometry.halfWidthTiles)

    local extents = getScriptManager():getVehicle(vehicleScript):getExtents()
    local width, length = extents:x(), extents:z()
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

    local playerTileX = math.floor(playerX) + 0.5
    local playerTileY = math.floor(playerY) + 0.5
    local playerTileFace = (playerTileX - geometry.x) * normalX
        + (playerTileY - geometry.y) * normalY
    local playerTileHalfFace =
        (math.abs(normalX) + math.abs(normalY)) / 2
    local playerClearance = playerTileFace + playerTileHalfFace
        + vehicleHalfFace + 0.01
    local faceDistance = math.max(carClearance, playerClearance)

    local tangentPlayer = face == "along" and playerAcross or playerAlong
    local tangentHalfExtent = face == "along"
        and geometry.halfWidthTiles or geometry.halfLengthTiles
    local maxTangent = math.max(tangentHalfExtent - 1, 0)
    local tangent = clamp(tangentPlayer, -maxTangent, maxTangent)
    local along, across
    if face == "along" then
        along, across = faceSign * faceDistance, tangent
    else
        along, across = tangent, faceSign * faceDistance
    end
    local x = geometry.x + dirX * along + sideX * across
    local y = geometry.y + dirY * along + sideY * across
    local direction = IsoDirections.fromAngle(dirX, dirY)
    local facingX, facingY = direction:dx(), direction:dy()
    local facingLength = math.sqrt(facingX * facingX + facingY * facingY)

    return {
        x = x,
        y = y,
        z = math.floor(geometry.z),
        directionX = facingX / facingLength,
        directionY = facingY / facingLength,
        width = width,
        length = length,
    }
end

function Client.showUnloadPreview(player, unitId, cargoId, vehicleScript,
        menu, option)
    Client.clearUnloadPreview()
    if not player or unitId == nil or cargoId == nil then return false end
    local preview = firstGeometricUnloadCandidate(player, unitId,
        vehicleScript)
    if preview == nil then return false end

    -- This is the first geometry-only candidate. The server checks the live
    -- footprint and may use another lane/offset or reject the unload.
    unloadPreviewHover = {
        unitId = unitId,
        cargoId = cargoId,
        menu = menu,
        option = option,
    }
    Client.unloadPreview = preview
    return true
end

local function renderUnloadPreview()
    local hovered = unloadPreviewHover
    if hovered and (not hovered.menu:getIsVisible()
            or hovered.menu.highlightedOption ~= hovered.option) then
        Client.clearUnloadPreview(hovered.unitId, hovered.cargoId)
        return
    end
    local preview = Client.unloadPreview
    if preview == nil then return end
    local halfWidth = preview.width / 2
    local halfLength = preview.length / 2
    local sideX, sideY = -preview.directionY, preview.directionX
    local corners = {
        {
            x = preview.x + preview.directionX * halfLength
                + sideX * halfWidth,
            y = preview.y + preview.directionY * halfLength
                + sideY * halfWidth,
        },
        {
            x = preview.x - preview.directionX * halfLength
                + sideX * halfWidth,
            y = preview.y - preview.directionY * halfLength
                + sideY * halfWidth,
        },
        {
            x = preview.x - preview.directionX * halfLength
                - sideX * halfWidth,
            y = preview.y - preview.directionY * halfLength
                - sideY * halfWidth,
        },
        {
            x = preview.x + preview.directionX * halfLength
                - sideX * halfWidth,
            y = preview.y + preview.directionY * halfLength
                - sideY * halfWidth,
        },
    }
    for index = 1, #corners do
        local first = corners[index]
        local second = corners[index % #corners + 1]
        renderIsoLine(first.x, first.y, preview.z,
            second.x, second.y, preview.z, 2, 0.25, 1.0, 0.35, 0.65)
    end
end

local function alphaSet(animal, alpha)
    animal:setAlphaAndTarget(0, alpha)
    animal:setAlphaAndTarget(1, alpha)
    animal:setAlphaAndTarget(2, alpha)
    animal:setAlphaAndTarget(3, alpha)
end

local function hideParts(unit)
    local parts = unit.parts
    if not parts then return end
    for _, door in pairs(parts.doors or {}) do
        door.alpha = 0
        if door.animal then alphaSet(door.animal, 0) end
    end
    for _, wall in pairs(parts.walls or {}) do
        wall.alpha = 0
        if wall.animal then alphaSet(wall.animal, 0) end
    end
    if parts.plate then
        parts.plate.alpha = 0
        if parts.plate.animal then alphaSet(parts.plate.animal, 0) end
    end
    if parts.moniker then
        parts.moniker.alpha = 0
        if parts.moniker.animal then alphaSet(parts.moniker.animal, 0) end
    end
end

local function markCutawayAndInteriorParts(unit)
    local cutaway = RR.CutawayClient
    local cutView = cutaway and cutaway.views and cutaway.views[unit.id]
    if cutView and cutView.animal then alphaSet(cutView.animal, 0) end

    local interior = RR.CarInteriorClient
    local view = interior and interior.view
    if view and view.id == unit.id then
        for name, part in pairs(view.parts or {}) do
            if name == "Floor" then
                if part.animal then alphaSet(part.animal, 1) end
            elseif part.animal then
                alphaSet(part.animal, 0)
            end
        end
    end
end

local function forceFlatcar(unit)
    if Client.isFlatcar(unit.id) then
        -- RR_CutawayClient and RR_CarInteriorClient both write this during
        -- their regular and paused ticks.  Reassert it after those callbacks.
        unit._cutAlpha = 0
        hideParts(unit)
        markCutawayAndInteriorParts(unit)
        return true
    end
    return false
end

local function setDirection(animal, pose, flipped)
    local dx, dy = pose.dirX, pose.dirY
    if flipped then dx, dy = -dx, -dy end
    animal:setTargetAndCurrentDirection(dx, dy)
end

local function writePose(animal, pose, flipped)
    animal:setX(pose.x)
    animal:setY(pose.y)
    animal:setZ(pose.z)
    setDirection(animal, pose, flipped)
end

local function despawn(animal)
    if not animal then return end
    pcall(function() animal:setDoRender(false) end)
    pcall(function() animal:setSceneCulled(true) end)
    pcall(function() animal:removeFromWorld() end)
    pcall(function() animal:removeFromSquare() end)
end

local function forgetFloor(key)
    local entry = Client.floors[key]
    if entry and entry.animal then despawn(entry.animal) end
    Client.floors[key] = nil
    floorSources[key] = nil
    local animal = floorAnimals[key]
    if animal then
        decorationOwners[animal] = nil
        floorAnimals[key] = nil
    end
end

local function detachCargoModels(entry)
    if not (entry and entry.animal) then return end
    for _, location in ipairs(entry.attachedLocations) do
        entry.animal:setAttachedItem(location, nil)
    end
    entry.attachedLocations = {}
    entry.attachmentsApplied = false
end

local function forgetVehicle(key, cargoId, reason)
    local vehicles = Client.vehicles[key]
    local entry = vehicles and vehicles[cargoId]
    if entry and entry.animal then
        Cargo.debug(
            "client despawn flatcarId=%s cargoId=%s root=root#%s animal=%s vehicleScript=%s reason=%s",
            key, tostring(cargoId), tostring(entry.debugRootId),
            tostring(entry.animal),
            tostring(entry.vehicleScript), tostring(reason))
        detachCargoModels(entry)
        decorationOwners[entry.animal] = nil
        cargoEntries[entry.animal] = nil
        despawn(entry.animal)
    end
    if vehicles then
        vehicles[cargoId] = nil
        local hasVehicles = false
        for _ in pairs(vehicles) do
            hasVehicles = true
            break
        end
        if not hasVehicles then Client.vehicles[key] = nil end
    end
end

local function forgetVehicles(key, reason)
    local vehicles = Client.vehicles[key]
    if not vehicles then return end
    for cargoId in pairs(vehicles) do
        forgetVehicle(key, cargoId, reason or "all-cargo-removed")
    end
end

local function forgetEndpointMarkers(key)
    local entry = Client.endpointMarkers[key]
    if not entry then return end
    if entry.animal then
        decorationOwners[entry.animal] = nil
        despawn(entry.animal)
    end
    Client.endpointMarkers[key] = nil
end

local function spawnFloor(pose, flipped)
    local definition = AnimalDefinitions.getDef(BODY_FLOOR_TYPE)
    local breed = definition:getRandomBreed()
    local animal = addAnimal(getCell(), math.floor(pose.x), math.floor(pose.y),
        math.floor(pose.z), BODY_FLOOR_TYPE, breed)
    animal:addToWorld()
    animal:getModData()[FLOOR_MARKER] = true
    animal:setGodMod(true, true)
    animal:setShootable(false)
    animal:setIsInvincible(true)
    local behavior = animal:getBehavior()
    if behavior then behavior:setBlockMovement(true) end
    writePose(animal, pose, flipped)
    alphaSet(animal, 1)
    return animal
end

local function adoptedFloor(unitId)
    local cutaway = RR.CutawayClient
    local cutView = cutaway and cutaway.views and cutaway.views[unitId]
    if cutView and cutView.type == BODY_FLOOR_TYPE then
        return cutView.animal, "RR.CutawayClient"
    end

    local interior = RR.CarInteriorClient
    local view = interior and interior.view
    local floor = view and view.id == unitId and view.parts
        and view.parts.Floor
    return floor and floor.animal or nil,
        floor and floor.animal and "RR.CarInteriorClient" or nil
end

local function pinFloor(unit, pose)
    if not (pose and pose.x and pose.y) then return false end
    local key = idKey(unit.id)
    local flipped = unit.f == true
    local adopted, adoptedSource = adoptedFloor(unit.id)
    local entry = Client.floors[key]
    if adopted then
        if entry then forgetFloor(key) end
        rememberFloor(key, adopted, unit.id)
        floorSources[key] = adoptedSource
        writePose(adopted, pose, flipped)
        alphaSet(adopted, 1)
        return true
    end
    if not entry then
        local animal = spawnFloor(pose, flipped)
        entry = { animal = animal }
        Client.floors[key] = entry
    end
    writePose(entry.animal, pose, flipped)
    rememberFloor(key, entry.animal, unit.id)
    floorSources[key] = "RailroaderRV.spawnFloor"
    alphaSet(entry.animal, 1)
    return true
end

cargoPose = function(unit, pose, center)
    local dx, dy = pose.dirX, pose.dirY
    if unit.f == true then dx, dy = -dx, -dy end
    local deckZ = RR.Consist.KINDS[unit.kind].interior.deckZ
    return {
        x = pose.x + center * dx + CARGO_LATERAL_OFFSET * dy,
        y = pose.y + center * dy - CARGO_LATERAL_OFFSET * dx,
        z = pose.z + deckZ,
        dirX = dx,
        dirY = dy,
    }
end

local function endpointMarkerPose(unit, pose)
    local dx, dy = pose.dirX, pose.dirY
    if unit.f == true then dx, dy = -dx, -dy end
    local deckZ = RR.Consist.KINDS[unit.kind].interior.deckZ
    return {
        x = pose.x,
        y = pose.y,
        z = pose.z + deckZ,
        dirX = dx,
        dirY = dy,
    }
end

local function spawnEndpointMarker(unit, pose)
    local definition = AnimalDefinitions.getDef(ENDPOINT_MARKER_TYPE)
    local animal = addAnimal(getCell(), math.floor(pose.x), math.floor(pose.y),
        math.floor(pose.z), ENDPOINT_MARKER_TYPE, definition:getRandomBreed())
    animal:addToWorld()
    animal:setGodMod(true, true)
    animal:setShootable(false)
    animal:setIsInvincible(true)
    local behavior = animal:getBehavior()
    if behavior then behavior:setBlockMovement(true) end
    writePose(animal, pose, false)
    alphaSet(animal, 1)
    decorationOwners[animal] = unit.id

    local halfDeck = Cargo.DECK_LENGTH / 2
    local dx, dy = pose.dirX, pose.dirY
    Cargo.debug(
        "client endpoint-marker spawn unitId=%s root=(%.3f,%.3f,%.3f) heading=(%.3f,%.3f) flipped=%s deckZ=%.3f predictedStart=(%.3f,%.3f) predictedEnd=(%.3f,%.3f)",
        tostring(unit.id), pose.x, pose.y, pose.z, dx, dy,
        tostring(unit.f == true),
        RR.Consist.KINDS[unit.kind].interior.deckZ,
        pose.x - halfDeck * dx, pose.y - halfDeck * dy,
        pose.x + halfDeck * dx, pose.y + halfDeck * dy)
    return animal
end

local function attachEndpointMarkerItems(entry)
    local animal = entry.animal
    if not animal:hasActiveModel() then
        if not entry.activeModelWaitLogged then
            Cargo.debug(
                "client endpoint-marker waiting unitId=%s animal=%s activeModel=false",
                tostring(entry.unitId), tostring(animal))
            entry.activeModelWaitLogged = true
        end
        entry.attachmentsApplied = false
        return
    end
    entry.activeModelWaitLogged = false
    if entry.attachmentsApplied then return end
    for _, location in ipairs(ENDPOINT_MARKER_LOCATIONS) do
        local item = instanceItem(ENDPOINT_MARKER_ITEM)
        animal:setAttachedItem(location, item)
        Cargo.debug(
            "client endpoint-marker attached unitId=%s animal=%s location=%s itemType=%s",
            tostring(entry.unitId), tostring(animal), location,
            ENDPOINT_MARKER_ITEM)
    end
    entry.attachmentsApplied = true
end

local function pinEndpointMarkers(unit, pose)
    local key = idKey(unit.id)
    if not Client.debugEndpointMarkersEnabled then
        forgetEndpointMarkers(key)
        return
    end

    local position = endpointMarkerPose(unit, pose)
    local entry = Client.endpointMarkers[key]
    if not entry then
        entry = {
            animal = spawnEndpointMarker(unit, position),
            unitId = unit.id,
        }
        Client.endpointMarkers[key] = entry
    end
    writePose(entry.animal, position, false)
    alphaSet(entry.animal, 1)
    attachEndpointMarkerItems(entry)
end

local function spawnCargoVehicle(car, pose, key, cargoId, unitId)
    local definition = AnimalDefinitions.getDef(Cargo.animalType)
    local animal = addAnimal(getCell(), math.floor(pose.x), math.floor(pose.y),
        math.floor(pose.z), Cargo.animalType, definition:getRandomBreed())
    animal:addToWorld()
    animal:getModData()[CARGO_MARKER] = true
    animal:setGodMod(true, true)
    animal:setShootable(false)
    animal:setIsInvincible(true)
    local behavior = animal:getBehavior()
    if behavior then behavior:setBlockMovement(true) end
    alphaSet(animal, 1)
    writePose(animal, pose, false)
    nextDebugRootId = nextDebugRootId + 1
    local entry = {
        animal = animal,
        cargoId = cargoId,
        vehicleScript = car.vehicleScript,
        visual = car.visual,
        attachedLocations = {},
        debugRootId = nextDebugRootId,
    }
    cargoEntries[animal] = entry
    decorationOwners[animal] = unitId
    Cargo.debug(
        "client spawn flatcarId=%s cargoId=%s vehicleScript=%s animalType=%s root=root#%d animal=%s targetWorld=(%.3f,%.3f,%.3f)",
        key, tostring(cargoId), car.vehicleScript, Cargo.animalType,
        entry.debugRootId, tostring(animal), pose.x, pose.y, pose.z)
    return entry
end

local function encodedIdentifier(value)
    return (tostring(value):gsub(".", function(character)
        return string.format("%02X", string.byte(character))
    end))
end

local function dynamicModelName(unitId, cargoId, slot)
    local name = "RVCargo_" .. tostring(Client.visualGeneration) .. "_"
        .. encodedIdentifier(unitId) .. "_"
        .. encodedIdentifier(cargoId) .. "_" .. encodedIdentifier(slot)
    return "RailroaderRV." .. name, name
end

local function loadedModelScale(modelScript)
    -- Loaded bodies are comment-stripped; only root fields contribute here.
    local scale = 1.0
    local bodies = modelScript:getLoadedScriptBodies()
    local bodyCount = modelScript:getLoadedScriptBodyCount()
    assert(bodyCount > 0 and bodyCount % 2 == 0,
        "ModelScript has no complete loaded bodies")
    for index = 0, bodyCount - 1, 2 do
        local body = bodies:get(index + 1)
        local cursor, depth = 1, 0
        local undoCoreScale = false
        while cursor <= #body do
            local character = body:sub(cursor, cursor)
            local pair = body:sub(cursor, cursor + 1)
            if pair == "/*" then
                cursor = body:find("*/", cursor + 2, true) + 2
            elseif pair == "//" then
                cursor = (body:find("\n", cursor + 2, true) or #body) + 1
            elseif character == "\"" or character == "'" then
                local quote = character
                cursor = cursor + 1
                while cursor <= #body and body:sub(cursor, cursor) ~= quote do
                    if body:sub(cursor, cursor) == "\\" then
                        cursor = cursor + 1
                    end
                    cursor = cursor + 1
                end
                cursor = cursor + 1
            elseif character == "{" then
                depth = depth + 1
                cursor = cursor + 1
            elseif character == "}" then
                depth = depth - 1
                cursor = cursor + 1
            elseif depth == 1 and character:match("[%a_]") then
                local key = body:sub(cursor):match("^([%a_][%w_]*)")
                local valueStart = cursor + #key
                while body:sub(valueStart, valueStart):match("%s") do
                    valueStart = valueStart + 1
                end
                if body:sub(valueStart, valueStart) == "=" then
                    local value = body:sub(valueStart + 1)
                        :match("^%s*([^,%s}]+)")
                    if key:lower() == "scale" then
                        scale = assert(tonumber((
                            value:gsub("[fFdD]$", ""))))
                    elseif key:lower() == "undocorescale" then
                        undoCoreScale = value:lower() == "true"
                    end
                end
                cursor = cursor + #key
            else
                cursor = cursor + 1
            end
        end
        if undoCoreScale then scale = scale * 0.6666667 end
    end
    return scale
end

local function dynamicModelBlock(shortName, meshName, attachment, shader,
        texture)
    local lines = { "model " .. shortName .. " {" }
    lines[#lines + 1] = "    mesh = " .. meshName .. ","
    if texture then
        lines[#lines + 1] = "    texture = " .. texture .. ","
    end
    if shader then
        lines[#lines + 1] = "    shader = " .. shader .. ","
    end
    lines[#lines + 1] = "    static = true,"
    lines[#lines + 1] = "    scale = 1.0,"
    lines[#lines + 1] = "    attachment " .. attachment.name .. " {"
    lines[#lines + 1] = string.format("        offset = %.9g %.9g %.9g,",
        attachment.offset.x, attachment.offset.y, attachment.offset.z)
    lines[#lines + 1] = string.format("        rotate = %.9g %.9g %.9g,",
        attachment.rotate.x, attachment.rotate.y, attachment.rotate.z)
    lines[#lines + 1] = string.format("        scale = %.9g,", attachment.scale)
    lines[#lines + 1] = "    }"
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

local function ensureDynamicModelScript(unitId, cargoId, slot, modelData,
        attachment, shader, texture)
    local fullName, shortName = dynamicModelName(unitId, cargoId, slot)
    local cached = Client.dynamicModelScripts[fullName]
    if cached then return fullName end

    local manager = getScriptManager()
    local existing = manager:getModelScript(fullName)
    if existing then
        Client.dynamicModelScripts[fullName] = existing
        return fullName
    end

    local source = manager:getModelScript(modelData.model)
    local meshName = modelData.model
    if source then
        meshName = source:getMeshName()
    end

    local clone = ModelScript.new()
    clone:setModule(manager:getModule("RailroaderRV"))
    clone:InitLoadPP(shortName)
    if source then
        local bodies = source:getLoadedScriptBodies()
        local bodyCount = source:getLoadedScriptBodyCount()
        assert(bodyCount > 0 and bodyCount % 2 == 0,
            "source ModelScript has no complete loaded bodies "
                .. tostring(modelData.model))
        for index = 0, bodyCount - 1, 2 do
            clone:Load(shortName, bodies:get(index + 1))
        end
    end

    -- The final block resets the late ModelInstance scale after its effective
    -- source value has moved into the pre-mesh cargo attachment transform.
    local scriptText = dynamicModelBlock(shortName, meshName, attachment,
        shader, texture)
    clone:Load(shortName, scriptText)
    getScriptManager():addModelScript(clone)
    Client.dynamicModelScripts[fullName] = clone
    return fullName
end

local function addVectors(a, b)
    return {
        x = a.x + (b and b.x or 0),
        y = a.y + (b and b.y or 0),
        z = a.z + (b and b.z or 0),
    }
end

local function quaternionFromEuler(rotate)
    local halfX, halfY, halfZ = math.rad(rotate.x) / 2,
        math.rad(rotate.y) / 2, math.rad(rotate.z) / 2
    local cx, sx = math.cos(halfX), math.sin(halfX)
    local cy, sy = math.cos(halfY), math.sin(halfY)
    local cz, sz = math.cos(halfZ), math.sin(halfZ)
    return {
        w = cx * cy * cz - sx * sy * sz,
        x = sx * cy * cz + cx * sy * sz,
        y = cx * sy * cz - sx * cy * sz,
        z = cx * cy * sz + sx * sy * cz,
    }
end

local function multiplyQuaternions(a, b)
    return {
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    }
end

local function eulerFromQuaternion(q)
    local sinPitch = 2 * (q.w * q.y + q.x * q.z)
    local pitch
    if math.abs(sinPitch) >= 1 then
        pitch = sinPitch > 0 and math.pi / 2 or -math.pi / 2
    else
        pitch = math.asin(sinPitch)
    end
    local roll
    local yaw
    if math.abs(sinPitch) >= 1 then
        local sinRollYaw = 2 * (q.x * q.y + q.z * q.w)
        local cosRollYaw = 1 - 2 * (q.x * q.x + q.z * q.z)
        roll = math.atan2(sinPitch > 0 and sinRollYaw or -sinRollYaw,
            cosRollYaw)
        yaw = 0
    else
        roll = math.atan2(2 * (q.w * q.x - q.y * q.z),
            1 - 2 * (q.x * q.x + q.y * q.y))
        yaw = math.atan2(2 * (q.w * q.z - q.x * q.y),
            1 - 2 * (q.y * q.y + q.z * q.z))
    end
    return {
        x = math.deg(roll),
        y = math.deg(pitch),
        z = math.deg(yaw),
    }
end

local function rotateVector(vector, rotate)
    local q = quaternionFromEuler(rotate)
    local xx, yy, zz = q.x * q.x, q.y * q.y, q.z * q.z
    local xy, xz, yz = q.x * q.y, q.x * q.z, q.y * q.z
    local wx, wy, wz = q.w * q.x, q.w * q.y, q.w * q.z
    return {
        x = (1 - 2 * (yy + zz)) * vector.x
            + 2 * (xy - wz) * vector.y + 2 * (xz + wy) * vector.z,
        y = 2 * (xy + wz) * vector.x
            + (1 - 2 * (xx + zz)) * vector.y + 2 * (yz - wx) * vector.z,
        z = 2 * (xz - wy) * vector.x + 2 * (yz + wx) * vector.y
            + (1 - 2 * (xx + yy)) * vector.z,
    }
end

local function composeTransforms(parent, child)
    local childOffset = {
        x = child.offset.x * parent.scale,
        y = child.offset.y * parent.scale,
        z = child.offset.z * parent.scale,
    }
    local rotatedOffset = rotateVector(childOffset, parent.rotate)
    return {
        offset = addVectors(parent.offset, rotatedOffset),
        rotate = eulerFromQuaternion(multiplyQuaternions(
            quaternionFromEuler(parent.rotate),
            quaternionFromEuler(child.rotate))),
        scale = parent.scale * child.scale,
    }
end

local function sourceModelTransform(modelData)
    local reverseVehicleModelAxes = modelData.partId ~= nil
        and (modelData.wheelIndex == nil or modelData.wheelIndex < 0)
    return {
        offset = {
            x = -modelData.offset.x,
            y = modelData.offset.y,
            z = modelData.offset.z,
        },
        rotate = {
            x = modelData.rotate.x,
            y = reverseVehicleModelAxes and -modelData.rotate.y
                or modelData.rotate.y,
            z = reverseVehicleModelAxes and -modelData.rotate.z
                or modelData.rotate.z,
        },
        scale = modelData.scale,
    }
end

local function attachmentTransform(modelScript, name)
    if not modelScript or not name then return nil end
    local sourceAttachment = modelScript:getAttachmentById(name)
    if not sourceAttachment then return nil end
    return {
        offset = {
            x = sourceAttachment:getOffset():x(),
            y = sourceAttachment:getOffset():y(),
            z = sourceAttachment:getOffset():z(),
        },
        rotate = {
            x = sourceAttachment:getRotate():x(),
            y = sourceAttachment:getRotate():y(),
            z = sourceAttachment:getRotate():z(),
        },
        scale = sourceAttachment:getScale(),
    }
end

local function vehicleRootTransform(visual)
    local offset = visual.body.offset
    return {
        offset = {
            x = -offset.x / ANIMAL_MODEL_SCALE,
            y = offset.y / ANIMAL_MODEL_SCALE,
            z = offset.z / ANIMAL_MODEL_SCALE,
        },
        rotate = { x = 0, y = 0, z = 0 },
        scale = visual.modelScale / ANIMAL_MODEL_SCALE,
    }
end

local function transformForModel(modelData, visual, vehicleScript, manager)
    if modelData == visual.body then
        local transform = sourceModelTransform(modelData)
        transform.offset.x = transform.offset.x / ANIMAL_MODEL_SCALE
        transform.offset.y = transform.offset.y / ANIMAL_MODEL_SCALE
        transform.offset.z = transform.offset.z / ANIMAL_MODEL_SCALE
        local ratio = visual.modelScale / ANIMAL_MODEL_SCALE
        transform.scale = ratio
        return transform
    end

    if modelData.wheelIndex == nil or modelData.wheelIndex < 0 then
        if modelData.attachmentNameParent then
            local parentData = modelData.parentModel or visual.body
            local transform = transformForModel(parentData, visual,
                vehicleScript, manager)
            local parentModelScript = manager:getModelScript(parentData.model)
            local parentAttachment = attachmentTransform(parentModelScript,
                modelData.attachmentNameParent)
            if not parentAttachment then
                parentAttachment = attachmentTransform(vehicleScript,
                    modelData.attachmentNameParent)
            end
            if parentAttachment then
                transform = composeTransforms(transform, parentAttachment)
            end
            local childModelScript = manager:getModelScript(modelData.model)
            local selfAttachment = attachmentTransform(childModelScript,
                modelData.attachmentNameSelf)
            if selfAttachment then
                transform = composeTransforms(transform, selfAttachment)
            end
            transform.scale = transform.scale * modelData.scale
            return transform
        end
    end

    local transform = composeTransforms(vehicleRootTransform(visual),
        sourceModelTransform(modelData))
    if modelData.wheelIndex ~= nil and modelData.wheelIndex >= 0 then
        local wheelOffset = modelData.wheelOffset
        transform.offset.x = transform.offset.x
            - wheelOffset.x / ANIMAL_MODEL_SCALE
        transform.offset.y = transform.offset.y
            + wheelOffset.y / ANIMAL_MODEL_SCALE
        transform.offset.z = transform.offset.z
            + wheelOffset.z / ANIMAL_MODEL_SCALE
    end
    return transform
end

local function attachmentFor(modelData, visual, vehicleScript,
        rootLiftOffset)
    local manager = getScriptManager()
    local source = manager:getModelScript(modelData.model)
    local transform = transformForModel(modelData, visual, vehicleScript,
        manager)
    -- Match native scale-before-mesh order. The fixed parent scale avoids the
    -- .01 ModelAttachment clamp for common source scales below .01; inverse
    -- conversion preserves the existing pose and total scale. Keep source mesh
    -- origins and VehicleScript offsets as authored; do not tune each vehicle.
    transform.offset.x = transform.offset.x / Cargo.anchorAttachmentScale
    transform.offset.y = (transform.offset.y + rootLiftOffset)
        / Cargo.anchorAttachmentScale
    transform.offset.z = transform.offset.z / Cargo.anchorAttachmentScale
    -- A VehicleScript part file may be a raw model key without a ModelScript.
    -- Native vehicle rendering uses scale 1 and no model attachments in that
    -- case; ModelScript-backed models retain their loaded script scale.
    local modelScale = source and loadedModelScale(source) or 1.0
    transform.scale = transform.scale * modelScale / Cargo.anchorAttachmentScale
    transform.name = Cargo.bodyLocation
    return transform
end

local function appendCargoModel(entry, unitId, cargoId, slot, location,
        modelData, visual, vehicleScript, rootLiftOffset, texture)
    local attachment = attachmentFor(modelData, visual, vehicleScript,
        rootLiftOffset)
    local shader = Cargo.bodyShader
    if modelData ~= visual.body and modelData.wheelIndex >= 0 then
        shader = Cargo.wheelShader
    elseif modelData ~= visual.body then
        shader = nil
    end
    local fullName = ensureDynamicModelScript(unitId, cargoId, slot,
        modelData, attachment, shader, texture)
    local item = instanceItem(Cargo.bodyItem)
    item:setStaticModel(fullName)
    local group = AttachedLocations.getGroup("Animal")
    group:getOrCreateLocation(location):setAttachmentName(Cargo.bodyLocation)
    entry.animal:setAttachedItem(location, item)
    entry.attachedLocations[#entry.attachedLocations + 1] = location
end

local function attachCargoModels(entry, car, key, cargoId, unitId)
    local animal = entry.animal
    if not animal:hasActiveModel() then
        if not entry.attachmentWaitLogged or entry.attachmentsApplied then
            Cargo.debug(
                "client attachment-wait flatcarId=%s cargoId=%s root=root#%s vehicleScript=%s activeModel=false applied=%s",
                key, tostring(cargoId), tostring(entry.debugRootId),
                car.vehicleScript, tostring(entry.attachmentsApplied == true))
        end
        if entry.attachmentsApplied then detachCargoModels(entry) end
        entry.attachmentWaitLogged = true
        return
    end
    -- cargoId owns one captured visual for its lifetime. Each network decode
    -- creates fresh Lua tables, so visual table identity is not stable.
    if entry.attachmentsApplied then return end

    local visual = car.visual
    local vehicleScript = car.vehicleScript
    local rootLiftOffset = visual.rootLiftOffset
    local body = visual.body
    appendCargoModel(entry, unitId, cargoId, "body", Cargo.bodyLocation,
        body, visual, vehicleScript, rootLiftOffset, visual.skin)
    for _, partModel in ipairs(visual.parts) do
        local slot = string.format("part_%d_%d", partModel.partIndex,
            partModel.modelIndex)
        local _, location = dynamicModelName(unitId, cargoId, slot)
        appendCargoModel(entry, unitId, cargoId, slot, location, partModel,
            visual, vehicleScript, rootLiftOffset)
    end
    entry.attachmentsApplied = true
    entry.attachmentWaitLogged = false
    Cargo.debug(
        "client attachments-applied flatcarId=%s cargoId=%s root=root#%s vehicleScript=%s modelCount=%d",
        key, tostring(cargoId), tostring(entry.debugRootId),
        car.vehicleScript, #visual.parts + 1)
end

local function pinCargoVehicles(unit, pose, cars)
    local key = idKey(unit.id)
    local vehicles = Client.vehicles[key] or {}
    Client.vehicles[key] = vehicles
    local cargoIds = {}
    for _, car in ipairs(cars) do
        local cargoId = car.cargoId
        cargoIds[cargoId] = true
        local entry = vehicles[cargoId]
        if entry and entry.vehicleScript ~= car.vehicleScript then
            forgetVehicle(key, cargoId, "vehicleScript-replaced")
            -- forgetVehicle drops the owner table when its last slot is removed;
            -- this local table is still the one being populated below.
            Client.vehicles[key] = vehicles
            entry = nil
        end
        local position = cargoPose(unit, pose, car.center)
        if not entry then
            entry = spawnCargoVehicle(car, position, key, cargoId, unit.id)
            vehicles[cargoId] = entry
        end
        writePose(entry.animal, position, false)
        attachCargoModels(entry, car, key, cargoId, unit.id)
    end
    for cargoId in pairs(vehicles) do
        if not cargoIds[cargoId] then
            forgetVehicle(key, cargoId, "cargo-id-removed")
        end
    end
end

local function duplicateRecordLocations()
    local locations = {}
    for _, record in ipairs(records) do
        local identity = recordIdentity(record)
        local recordId = record.id or record.trainId
        for _, unit in ipairs(record.units) do
            if Client.isFlatcar(unit.id) then
                local key = idKey(unit.id)
                local rows = locations[key] or {}
                rows[#rows + 1] = string.format(
                    "%s(recordId=%s,owner=%s,pose=%s)", identity,
                    tostring(recordId), tostring(unit.locomotiveId or "cut"),
                    unit.pose and string.format("%.3f,%.3f,%.3f",
                        unit.pose.x, unit.pose.y, unit.pose.z)
                        or "none")
                locations[key] = rows
            end
        end
    end

    local detected = {}
    for key, rows in pairs(locations) do
        if #rows > 1 then
            local identities = {}
            for _, row in ipairs(rows) do
                identities[#identities + 1] = row:match("^([^%(]+)")
            end
            local signature = table.concat(identities, ",")
            detected[key] = signature
            if duplicateRecords[key] ~= signature then
                Cargo.debug("client duplicate-record unitId=%s records={%s}",
                    key, table.concat(rows, "; "))
            end
        end
    end
    duplicateRecords = detected
    return detected
end

local function visitRecord(record, seen, duplicates)
    for _, unit in ipairs(record.units) do
        if forceFlatcar(unit) then
            local key = idKey(unit.id)
            local pose = unit.pose
            if unit.animal and pose and pinFloor(unit, pose) then
                pinEndpointMarkers(unit, pose)
                local cars = Client.flatcars[key].cars
                pinCargoVehicles(unit, pose, cars)
                traceCargoPose(record, unit, key, pose, cars,
                    duplicates[key] ~= nil)
                seen[key] = true
            end
        end
    end
end

local function syncRecords()
    local seen = {}
    RR.Body.records(records)
    local duplicates = duplicateRecordLocations()
    for _, record in ipairs(records) do
        visitRecord(record, seen, duplicates)
    end
    for key in pairs(floorAnimals) do
        if not seen[key] then forgetFloor(key) end
    end
    for key in pairs(Client.vehicles) do
        if not seen[key] then
            forgetVehicles(key, "rr-record-not-visible")
        end
    end
    for key in pairs(Client.endpointMarkers) do
        if not seen[key] then forgetEndpointMarkers(key) end
    end
    for key in pairs(traceUnits) do
        if not seen[key] then
            Cargo.debug("client visual flatcarId=%s record-not-visible roots={%s}",
                key, rootSummary(key))
            traceUnits[key] = nil
        end
    end
end

local function cleanupFloors()
    for key in pairs(floorAnimals) do forgetFloor(key) end
end

local function cleanupVehicles()
    for key in pairs(Client.vehicles) do forgetVehicles(key) end
end

local function cleanupEndpointMarkers()
    for key in pairs(Client.endpointMarkers) do forgetEndpointMarkers(key) end
end

function Client.sweep()
    local keep = {}
    for _, entry in pairs(Client.floors) do
        if entry.animal then keep[entry.animal] = true end
    end
    for _, vehicles in pairs(Client.vehicles) do
        for _, entry in pairs(vehicles) do
            if entry.animal then keep[entry.animal] = true end
        end
    end
    local animals = getCell():getAnimals()
    local doomed = {}
    for index = 0, animals:size() - 1 do
        local animal = animals:get(index)
        local data = animal:getModData()
        if (data[FLOOR_MARKER] == true or data[CARGO_MARKER] == true)
                and not keep[animal] then
            Cargo.debug("client sweep despawn animal=%s floor=%s cargo=%s",
                tostring(animal), tostring(data[FLOOR_MARKER] == true),
                tostring(data[CARGO_MARKER] == true))
            decorationOwners[animal] = nil
            if data[CARGO_MARKER] == true then
                detachCargoModels(cargoEntries[animal])
                cargoEntries[animal] = nil
            end
            for key, floor in pairs(floorAnimals) do
                if floor == animal then
                    floorAnimals[key] = nil
                    floorSources[key] = nil
                end
            end
            doomed[#doomed + 1] = animal
        end
    end
    for _, animal in ipairs(doomed) do despawn(animal) end
    return #doomed
end

function Client.onServerCommand(module, command, args)
    CargoNotice.onServerCommand(module, command, args)
    if module ~= C.MOD_ID then return end
    if command ~= C.COMMAND_RV_FLATCAR_SYNC then return end
    if args.units then
        Client.flatcars = {}
        layoutSignatures = {}
        for _, unit in ipairs(args.units) do
            local key = idKey(unit.unitId)
            Client.flatcars[key] = { cars = unit.cars }
            layoutSignatures[key] = cargoLayoutSignature(unit.cars)
            Cargo.debug(
                "client snapshot flatcarId=%s cargoCount=%d layout={%s}",
                key, #unit.cars, describeCargoLayout(unit.cars))
        end
        print(("[RailroaderRV][FlatcarVisual] snapshot received flatcars=%d")
            :format(#args.units))
    else
        local key = idKey(args.unitId)
        Client.flatcars[key] = { cars = args.cars }
        layoutSignatures[key] = cargoLayoutSignature(args.cars)
        Cargo.debug(
            "client delta flatcarId=%s cargoCount=%d layout={%s}",
            key, #args.cars, describeCargoLayout(args.cars))
    end
    local hovered = unloadPreviewHover
    if hovered then
        local unitKey = idKey(hovered.unitId)
        local cars = Client.flatcars[unitKey]
            and Client.flatcars[unitKey].cars or {}
        local cargoExists = false
        for _, car in ipairs(cars) do
            if car.cargoId == hovered.cargoId then
                cargoExists = true
                break
            end
        end
        if not cargoExists then
            Client.clearUnloadPreview(hovered.unitId, hovered.cargoId)
        end
    end
    syncRecords()
end

local function onCreatePlayer(playerIndex, player)
    if playerIndex == 0 then localPlayer = player end
end

local function requestSnapshot(player)
    sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_FLATCAR, {
        operation = "snapshot",
    })
    snapshotRequested = true
    print("[RailroaderRV][FlatcarVisual] startup snapshot requested after player connect")
end

local function resetVisualState()
    Client.visualGeneration = Client.visualGeneration + 1
    Client.clearUnloadPreview()
    Client.flatcars = {}
    layoutSignatures = {}
    traceUnits = {}
    duplicateRecords = {}
    cleanupFloors()
    cleanupVehicles()
    cleanupEndpointMarkers()
end

local function onGameStart()
    resetVisualState()
    Client.sweep()
    gameStarted = true
    snapshotRequested = false
end

local function onConnected()
    resetVisualState()
    localPlayer = nil
    gameStarted = false
    snapshotRequested = false
end

local function onTick()
    if gameStarted and localPlayer and not snapshotRequested
            and (not isClient() or localPlayer:getOnlineID() >= 0) then
        requestSnapshot(localPlayer)
    end
    syncRecords()
    ticks = ticks + 1
    if ticks % 300 == 0 then Client.sweep() end
end

function Client.clearConnectionState()
    resetVisualState()
    localPlayer = nil
    gameStarted = false
    snapshotRequested = false
end

local originalBodyAlpha = Cars.bodyAlpha
Cars.bodyAlpha = function(unit)
    if Client.isFlatcar(unit.id) then return 0 end
    return originalBodyAlpha(unit)
end

local function wrapCars(name)
    local original = Cars[name]
    Cars[name] = function(record, ...)
        if record and record.units then
            for _, unit in ipairs(record.units) do forceFlatcar(unit) end
        end
        local result = original(record, ...)
        syncRecords()
        return result
    end
end

wrapCars("draw")
wrapCars("update")
local originalPinAlpha = Cars.pinAlpha
Cars.pinAlpha = function(record, ...)
    if record and record.units then
        for _, unit in ipairs(record.units) do forceFlatcar(unit) end
    end
    local result = originalPinAlpha(record, ...)
    syncRecords()
    return result
end

if Events and Events.OnServerCommand then
    Events.OnServerCommand.Add(Client.onServerCommand)
end
if Events and Events.OnGameStart then
    Events.OnGameStart.Add(onGameStart)
end
if Events and Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(onCreatePlayer)
end
if Events and Events.OnConnected then
    Events.OnConnected.Add(onConnected)
end
if Events and Events.OnDisconnect then
    Events.OnDisconnect.Add(Client.clearConnectionState)
end
if Events and Events.OnTick then
    Events.OnTick.Add(onTick)
end
if Events and Events.OnTickEvenPaused then
    Events.OnTickEvenPaused.Add(syncRecords)
end
if Events and Events.OnPostRender
    and type(Events.OnPostRender.Add) == "function" then
    Events.OnPostRender.Add(renderUnloadPreview)
end

return Client
