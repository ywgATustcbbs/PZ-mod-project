-- Client intent transport and read-only utility snapshot cache.
-- The server owns utility values and every world or inventory change.
require("RailroaderRV/Common/RV_Constants")
local UtilitySprite = require("RailroaderRV/Common/RV_UtilitySprite")
local spritesReady, _, spriteReason = UtilitySprite.install()
if not spritesReady then
    error("RailroaderRV: client hidden sprite registration failed: "
        .. tostring(spriteReason))
end
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local W = require("RailroaderRV/Water/RV_UtilityWaterConstants")

RailroaderRV = RailroaderRV or {}
RailroaderRV.UtilityClient = RailroaderRV.UtilityClient or {}
local Client = RailroaderRV.UtilityClient
local C = RailroaderRV.Constants

Client.snapshot = nil

function Client.mappingKey(value)
    if value == nil then return nil end
    return value.rvId .. ":" .. value.generation
end

function Client.hasCurrentUtilityContext(player, expectedMappingKey)
    local menu = RailroaderRV.RailroaderContextMenu
    local mapping = menu.getUtilityMapping()
    return mapping ~= nil
        and Client.mappingKey(mapping) == expectedMappingKey
        and menu.hasUtilityDashboardCandidate(player)
end

function Client.showFeedback(player, message)
    if not player then return false end
    player:setHaloNote(tostring(message), 255, 255, 255, 5000)
    return true
end

local function rejectSend(player)
    Client.showFeedback(player, getText("UI_RailroaderRV_Utility_SendFailed"))
    return false, nil
end

local function localPlayer(playerNum)
    return getSpecificPlayer(playerNum)
end

local function transmit(player, payload)
    if not player then return false end
    return sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_UTILITY,
        payload) ~= false
end

local function hintForObject(object)
    if not object then return nil end
    local square = object:getSquare()
    if not square then return nil end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local index = object:getObjectIndex()
    return { x = x, y = y, z = z, objectIndex = index }
end

Client.hintForObject = hintForObject

local naturalPumpSprites = {
    camping_01_16 = true,
    camping_01_64 = true,
    camping_01_65 = true,
    camping_01_66 = true,
    camping_01_67 = true,
}

local function exactNaturalWaterKind(fluidContainer)
    local sample = fluidContainer:createFluidSample()
    local size = sample:size()
    if size == 0 then
        sample:release()
        return nil
    end

    local sawWater, sawTainted = false, false
    for index = 0, size - 1 do
        local fluid = sample:getFluid(index)
        if fluid == Fluid.Water then
            sawWater = true
        elseif fluid == Fluid.TaintedWater then
            sawTainted = true
        else
            sample:release()
            return nil
        end
    end
    sample:release()
    if sawTainted then return "tainted" end
    if sawWater then return "clean" end
    return nil
end

local function naturalWaterKind(source)
    local sprite = source:getSprite()
    if not sprite then return nil end
    local spriteName = sprite:getName()
    if type(spriteName) ~= "string" then return nil end
    local pumpSource = naturalPumpSprites[spriteName] == true
    if not pumpSource and spriteName:sub(1, 17) ~= "blends_natural_02" then
        return nil
    end
    if source:getUsesExternalWaterSource() == true then return nil end

    local fluidContainer = source:getFluidContainer()
    if fluidContainer ~= nil then
        return exactNaturalWaterKind(fluidContainer)
    end

    local fluid = pumpSource and Fluid.Water or source:getPrimaryFluid()
    if fluid == Fluid.Water then return "clean" end
    if fluid == Fluid.TaintedWater then return "tainted" end
    return nil
end

local function appendNaturalWaterSource(sources, seen, source)
    if source == nil or seen[source] then return end
    seen[source] = true

    local kind = naturalWaterKind(source)
    if not kind then return end
    local volumeL = source:getFluidAmount()
    if volumeL <= 0 then return end

    local displayName = source:getName()
    if displayName == nil or displayName == "" then
        displayName = source:getFluidUiName()
    end
    sources[#sources + 1] = {
        sourceObject = source,
        kind = kind,
        infinite = source:getFluidCapacity() >= 9999,
        volumeL = volumeL,
        displayName = displayName,
    }
end

local function appendSquareCollection(sources, seen, collection)
    for index = 0, collection:size() - 1 do
        appendNaturalWaterSource(sources, seen, collection:get(index))
    end
end

function Client.listNaturalWaterSources(player)
    local centerX, centerY, centerZ = math.floor(player:getX()),
        math.floor(player:getY()), math.floor(player:getZ())
    local cell = player:getCell()
    local radius = W.NATURAL_SOURCE_RADIUS
    local sources, seen = {}, {}
    for dx = -radius, radius do
        for dy = -radius, radius do
            if dx * dx + dy * dy <= radius * radius then
                local square = cell:getGridSquare(centerX + dx,
                    centerY + dy, centerZ)
                if square then
                    appendSquareCollection(sources, seen, square:getObjects())
                    appendSquareCollection(sources, seen,
                        square:getSpecialObjects())
                    appendNaturalWaterSource(sources, seen, square:getFloor())
                end
            end
        end
    end
    return sources
end

local function notifyActionEnded(action)
    local utilityCallback = action.onUtilityActionEnded
    action.onUtilityActionEnded = nil
    if utilityCallback then utilityCallback(action) end
    local roofCallback = action.onRoofActionEnded
    action.onRoofActionEnded = nil
    if roofCallback then roofCallback(action) end
end

function Client.send(player, operation, targetHint, sourceHint)
    local payload = { operation = operation }
    if targetHint ~= nil then payload.targetHint = targetHint end
    if sourceHint ~= nil then payload.sourceHint = sourceHint end
    if not transmit(player, payload) then return rejectSend(player) end
    return true
end

function Client.requestAddFuel(player, item)
    return Client.queueTimedAction(player, U.OP_ADD_FUEL, item)
end

function Client.requestAddBattery(player, item)
    return Client.queueTimedAction(player, U.OP_ADD_BATTERY, item)
end

function Client.requestInstallComponent(player, operation, item)
    return Client.queueTimedAction(player, operation, item)
end

function Client.requestRemoveBattery(player, batteryId)
    return Client.queueTimedAction(player, U.OP_REMOVE_BATTERY, nil,
        { batteryId = batteryId })
end

function Client.requestAddFuelTank(player, item)
    return Client.queueTimedAction(player, U.OP_ADD_FUEL_TANK, item)
end

function Client.requestRemoveFuelTank(player, fuelTankId)
    return Client.queueTimedAction(player, U.OP_REMOVE_FUEL_TANK, nil,
        { fuelTankId = fuelTankId })
end

function Client.requestPowerOperation(player, operation, targetHint)
    if operation == U.OP_REMOVE_CHARGER or operation == U.OP_REMOVE_INVERTER
        or operation == U.OP_INSTALL_CONTROLLER
        or operation == U.OP_REMOVE_CONTROLLER then
        return Client.queueTimedAction(player, operation, nil, targetHint)
    end
    return Client.send(player, operation, targetHint, nil)
end

function Client.queueTimedAction(player, operation, item, targetHint,
        utilityMappingKey, clearQueue, beforeQueue, targetObject)
    if clearQueue then
        ISTimedActionQueue.clear(player)
    end
    local actionClass = require("TimedActions/ISRVUtilityAction")
    local action = actionClass:new(player, operation, item, targetHint,
        targetObject)
    action.rvUtilityMappingKey = utilityMappingKey
    if beforeQueue then beforeQueue(action) end
    local queued = ISTimedActionQueue.add(action)
    if queued == nil then
        notifyActionEnded(action)
        return false, nil
    end
    return true, action
end

function Client.cancelTimedAction(player, action)
    if action:isStarted() then
        action:forceStop()
    else
        ISTimedActionQueue.getTimedActionQueue(player):removeFromQueue(action)
        notifyActionEnded(action)
    end
    return true
end

-- The server settles utility state before returning its authoritative snapshot.
function Client.requestSnapshot(player)
    local payload = { operation = U.OP_REQUEST_SNAPSHOT }
    if not transmit(player, payload) then return rejectSend(player) end
    return true
end

function Client.requestWaterConnection(player, object, connected)
    if type(connected) ~= "boolean" then return rejectSend(player) end
    local hint = hintForObject(object)
    if not hint then return rejectSend(player) end
    hint.connected = connected
    return Client.send(player, U.OP_CONNECT_WATER_DEVICE, hint, nil)
end

function Client.requestDrawWaterFromSource(player, object, utilityMappingKey,
        beforeQueue)
    local hint = hintForObject(object)
    if not hint then return rejectSend(player) end
    return Client.queueTimedAction(player, W.OP_DRAW_WATER_FROM_SOURCE, nil,
        hint, utilityMappingKey, false, beforeQueue, object)
end

function Client.clearConnectionState()
    Client.snapshot = nil
    RailroaderRV.RailroaderContextMenu.clearUtilityMapping()
    RailroaderRV.UtilityDashboard.onConnectionReset()
end

function Client.onServerCommand(module, command, args)
    if module ~= C.MOD_ID then return end
    if command == C.COMMAND_RV_UTILITY_MAPPING then
        local previousKey = Client.mappingKey(
            RailroaderRV.RailroaderContextMenu.getUtilityMapping())
        RailroaderRV.RailroaderContextMenu.acceptUtilityMapping(args)
        local mapping = RailroaderRV.RailroaderContextMenu.getUtilityMapping()
        if Client.mappingKey(mapping) ~= previousKey then
            Client.snapshot = nil
            RailroaderRV.UtilityDashboard.onMappingChanged(
                localPlayer(0), mapping)
        end
        return
    end
    if command == C.COMMAND_RV_UTILITY_SNAPSHOT then
        Client.snapshot = args
        RailroaderRV.UtilityDashboard.onSnapshot(localPlayer(0), args)
        return
    end
    if command == C.COMMAND_RV_UTILITY_ACK then
        if args.ok ~= true then
            Client.showFeedback(localPlayer(0),
                getText("UI_RailroaderRV_Utility_Rejected")
                .. ": " .. tostring(args.reason))
        end
    end
end

function Client.getSnapshot()
    return Client.snapshot
end

Events.OnServerCommand.Add(Client.onServerCommand)
Events.OnConnected.Add(Client.clearConnectionState)
Events.OnDisconnect.Add(Client.clearConnectionState)
return Client
