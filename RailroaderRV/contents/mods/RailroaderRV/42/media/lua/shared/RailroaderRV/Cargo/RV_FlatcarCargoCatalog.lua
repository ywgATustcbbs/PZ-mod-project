local Catalog = {}

-- TEMPORARY cargo visual diagnostics. Set false or remove after the client-side
-- layout and model roots have been observed in game.
Catalog.DEBUG_ENABLED = true

function Catalog.debug(formatString, ...)
    if not Catalog.DEBUG_ENABLED then return end
    print(('[RailroaderRV][CargoDebug] ' .. formatString):format(...))
end

Catalog.DECK_LENGTH = 14.0
Catalog.SEGMENT_LENGTH = 0.5
Catalog.SEGMENT_COUNT = 28
Catalog.animalType = "rr_rv_flatcar_cargo"
Catalog.anchorModel = "RailroaderRV.RV_FlatcarCargoAnchor"
Catalog.bodyLocation = "RVFlatcarCargoBody"
Catalog.anchorAttachmentScale = 0.01
Catalog.bodyItem = "RailroaderRV.RVFlatcarCargoModel"
Catalog.bodyShader = "RV_FlatcarVehicleBody"
Catalog.wheelShader = "RV_FlatcarVehicleWheel"

function Catalog.length(vehicleScript)
    local script = getScriptManager():getVehicle(vehicleScript)
    return script:getExtents():z()
end

function Catalog.segmentCost(length)
    return math.ceil(length / Catalog.SEGMENT_LENGTH)
end

function Catalog.fits(cars, newVehicleScript)
    local count = #cars + 1
    local totalLength = Catalog.length(newVehicleScript)
    local totalSegments = Catalog.segmentCost(totalLength)
    for _, car in ipairs(cars) do
        local length = Catalog.length(car.vehicleScript)
        totalLength = totalLength + length
        totalSegments = totalSegments + Catalog.segmentCost(length)
    end
    totalSegments = totalSegments + count - 1

    if totalSegments > Catalog.SEGMENT_COUNT then return false end
    if count > 1
            and (Catalog.DECK_LENGTH - totalLength) / count
                < Catalog.SEGMENT_LENGTH then
        return false
    end
    return true
end

local function vectorData(vector)
    return { x = vector:x(), y = vector:y(), z = vector:z() }
end

local function captureModel(model)
    return {
        model = model:getFile(),
        scale = model:getScale(),
        offset = vectorData(model:getOffset()),
        rotate = vectorData(model:getRotate()),
        attachmentNameParent = model:getAttachmentNameParent(),
        attachmentNameSelf = model:getAttachmentNameSelf(),
    }
end

local function capturePartModel(part, model, vehicleScript)
    local modelData = captureModel(model)
    modelData.partId = part:getId()
    modelData.wheelIndex = part:getWheelIndex()
    if modelData.wheelIndex >= 0 then
        modelData.wheelOffset = vectorData(
            vehicleScript:getWheel(modelData.wheelIndex):getOffset())
    end
    if modelData.attachmentNameParent then
        local parent = part:getParent()
        if parent then
            local parentScriptPart = parent:getScriptPart()
            assert(parentScriptPart:getModelCount() > 0,
                "parented vehicle part has no model "
                    .. tostring(part:getId()))
            modelData.parentModel = capturePartModel(parent,
                parentScriptPart:getModel(0), vehicleScript)
        end
    end
    return modelData
end

local function rootLiftOffset(vehicle)
    local physicalOrigin = vehicle:getWorldPos(Vector3f.new(),
        Vector3f.new())
    local sourceLift = (physicalOrigin:z() - math.floor(vehicle:getZ()))
        * 2.44949
    local anchorLift = 1.5 * (1.028669333 - 0.48)
    return (sourceLift - anchorLift) / 1.5
end

function Catalog.captureVisual(vehicle)
    local vehicleScript = vehicle:getScript()
    local skin = vehicle:getSkin()
    local visual = {
        modelScale = vehicleScript:getModelScale(),
        rootLiftOffset = rootLiftOffset(vehicle),
        skin = skin ~= "BOGUS" and skin or nil,
        body = captureModel(vehicleScript:getModel()),
        parts = {},
    }

    for partIndex = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(partIndex)
        -- Lua exposes the part's declared models and item state, but not the
        -- current visibility of each BaseVehicle model. The all-models-visible
        -- flag is a script setting, not that runtime state. Keep the
        -- item-backed capture instead of adding every declaration, which can
        -- include hidden alternatives. A modded vehicle that shows models on
        -- an itemless part needs mod-specific handling; there are too many mod
        -- vehicle definitions to adapt one by one, so we accept that visual
        -- difference.
        local installedItem = part:getInventoryItem()
        if installedItem then
            local scriptPart = part:getScriptPart()
            if scriptPart then
                for modelIndex = 0, scriptPart:getModelCount() - 1 do
                    local model = scriptPart:getModel(modelIndex)
                    local modelName = model:getFile()
                    if modelName then
                        local modelData = capturePartModel(part, model,
                            vehicleScript)
                        modelData.partIndex = partIndex
                        modelData.modelId = model:getId()
                        modelData.modelIndex = modelIndex
                        modelData.wheelIndex = part:getWheelIndex()
                        local wheelIndex = modelData.wheelIndex
                        if wheelIndex >= 0 then
                            modelData.wheelOffset = vectorData(
                                vehicleScript:getWheel(wheelIndex):getOffset())
                        end
                        visual.parts[#visual.parts + 1] = modelData
                    end
                end
            end
        end
    end

    return visual
end

function Catalog.layout(cars)
    local totalLength = 0
    for _, car in ipairs(cars) do
        totalLength = totalLength + Catalog.length(car.vehicleScript)
    end
    local count = #cars
    local averageGap = (Catalog.DECK_LENGTH - totalLength) / count
    local cursor = -Catalog.DECK_LENGTH / 2 + averageGap / 2
    for _, car in ipairs(cars) do
        local length = Catalog.length(car.vehicleScript)
        car.center = cursor + length / 2
        cursor = cursor + length + averageGap
    end
    return cars
end

local function registerBodyLocation()
    local group = AttachedLocations.getGroup("Animal")
    group:getOrCreateLocation(Catalog.bodyLocation):setAttachmentName(
        Catalog.bodyLocation)
end

registerBodyLocation()

return Catalog
