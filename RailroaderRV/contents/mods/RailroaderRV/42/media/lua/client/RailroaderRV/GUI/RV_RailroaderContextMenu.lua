-- Client intent/menu half of the Railroader RV adapter.
--
-- The client uses a clicked animal only to select a stable Railroader unit ID
-- for the enter intent. Safehouse claims carry no target hint; the server
-- resolves the player's current RV.

require("ISUI/ISToolTip")
require("ISUI/ISVehicleMenu")
require("Railroader/RR_API")
require("RailroaderRV/Common/RV_Constants")
require("RailroaderRV/Common/RV_UtilityConstants")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local Units = require("RailroaderRV/RVMapping/RV_RailroaderUnits")

RailroaderRV = RailroaderRV or {}
RailroaderRV.RailroaderContextMenu = RailroaderRV.RailroaderContextMenu or {}

local Menu = RailroaderRV.RailroaderContextMenu
local C = RailroaderRV.Constants
local UtilityClient = require("RailroaderRV/GUI/RV_UtilityClient")
local FlatcarVisualClient = require(
    "RailroaderRV/GUI/RV_FlatcarVisualClient")

local ICON_ENTER_RV = "media/ui/RailroaderRV/enterrv.png"
local ICON_EXIT_RV = "media/ui/RailroaderRV/exitrv.png"
local ICON_UTILITY_DASHBOARD = "media/ui/RailroaderRV/managementpannel.png"

Menu._rvUtilityMapping = Menu._rvUtilityMapping or nil
local pendingExitBoardings = {}

local finiteNumber = C.finiteNumber
local finiteInteger = C.finiteInteger

local function text(key, fallback)
    local result = key
    pcall(function() result = getText(key) end)
    if not result or result == "" or result == key then return fallback end
    return result
end

local function localPlayer(playerNum)
    if type(getSpecificPlayer) ~= "function" then return nil end
    local ok, player = pcall(getSpecificPlayer, playerNum)
    return ok and player or nil
end

local function localPlayerByOnlineId(onlineId)
    local count = 0
    if type(getNumActivePlayers) == "function" then
        local ok, value = pcall(getNumActivePlayers)
        if ok then count = finiteInteger(value) or 0 end
    end
    for playerNum = 0, count - 1 do
        local player = localPlayer(playerNum)
        if player then
            local ok, value = pcall(function() return player:getOnlineID() end)
            if ok and finiteInteger(value) == onlineId then return player end
        end
    end
    -- SP has no network slot and some B42 builds return nil/-1 from
    -- getOnlineID.  The server adapter's local fallback is slot 0, so resolve
    -- that one player without weakening MP online-id matching.
    if onlineId == 0 and count > 0 then return localPlayer(0) end
    return nil
end

local function playerPosition(player)
    if not player then return nil end
    local okX, x = pcall(function() return player:getX() end)
    local okY, y = pcall(function() return player:getY() end)
    local okZ, z = pcall(function() return player:getZ() end)
    x, y, z = finiteNumber(x), finiteNumber(y), finiteNumber(z)
    if not okX or not okY or not okZ or not x or not y or not z then return nil end
    return { x = x, y = y, z = z }
end

local function targetRegion()
    local firstSlot = RegionSlots.indexToRegion(1)
    local lastSlot = RegionSlots.indexToRegion(RegionSlots.COUNT)
    local anchor = RegionSlots.indexToAnchor(1)
    return { minX = firstSlot.minX, minY = firstSlot.minY,
        maxX = lastSlot.maxX, maxY = lastSlot.maxY,
        minZ = anchor.z + C.RV_MANAGED_MIN_Z_OFFSET,
        maxZ = anchor.z + C.RV_MANAGED_MAX_Z_OFFSET }
end

local function inRegion(position, region)
    if not position or not region then return false end
    local minZ = finiteNumber(region.minZ)
    local maxZ = finiteNumber(region.maxZ)
    return position.x >= region.minX and position.x < region.maxX
        and position.y >= region.minY and position.y < region.maxY
        and minZ ~= nil and maxZ ~= nil
        and math.floor(position.z) >= math.floor(minZ)
        and math.floor(position.z) < math.floor(maxZ)
end

local function mapContainsPlayer(player)
    local position = playerPosition(player)
    if not position then return false end
    local target = targetRegion()
    if not inRegion(position, target) then return false end
    -- The server mapping gate is authoritative.  The client only decides
    -- whether to show the local affordance from its fixed coordinate scope.
    return true
end

local function rememberUtilityMapping(args, action)
    if action == nil then action = args.action end
    if action ~= "enter" and action ~= "exit" then return end
    local mapping = {
        rvId = args.rvId,
        locoId = args.locoId,
        generation = args.generation,
    }
    Menu._rvUtilityMapping = mapping
end

local function clickedUnit(animal)
    if not animal then return nil end
    local unitId = FlatcarVisualClient.unitIdForDecoration(animal)
    if unitId ~= nil then return Units.find(unitId) end
    local id = animal:getAnimalID()
    return Units.find(id)
end

local function optionAlreadyExists(context, label)
    local options = context and context.options
    if type(options) ~= "table" then return false end
    local count = finiteInteger(context.numOptions) or #options
    for index = 1, count do
        local option = options[index]
        if type(option) == "table" then
            local name = option.name or option.label
            if name == label then return true end
        end
    end
    return false
end

local function markTest()
    if ISWorldObjectContextMenu and type(ISWorldObjectContextMenu.setTest) == "function" then
        pcall(ISWorldObjectContextMenu.setTest)
    end
    return true
end

local function requestEnter(player, unitId)
    if not player or unitId == nil then return end
    sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_ENTER, {
        locoId = unitId,
    })
end

local function requestExit(player)
    if not player then
        return
    end
    sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_EXIT, {})
end

local function requestFlatcarConversion(player, unitId)
    if not player or unitId == nil then return end
    FlatcarVisualClient.requestConversion(player, unitId)
end

local function requestLoadVehicle(player, unitId, vehicleId)
    if not player or unitId == nil or vehicleId == nil then return end
    FlatcarVisualClient.requestLoadVehicle(player, unitId, vehicleId)
end

local function requestUnloadVehicle(player, unitId, cargoId)
    if not player or unitId == nil or cargoId == nil then return end
    FlatcarVisualClient.requestUnloadVehicle(player, unitId, cargoId)
end

local function newMenuOptionToolTip(title, description)
    local toolTip = ISToolTip:new()
    toolTip:initialise()
    toolTip:setVisible(false)
    toolTip:setName(title)
    toolTip.description = description
    return toolTip
end

local function transportTooltipDescription(isFlatcar, hasLoadingRamp)
    local lines = {}
    if not isFlatcar then
        lines[#lines + 1] = text(
            "ContextMenu_RailroaderRV_Transport_RequiresFlatcar",
            "Convert to a flatcar first")
    end
    local rampColor = hasLoadingRamp and "<RGB:1,1,1>" or "<RGB:1,0,0>"
    local rampCount = hasLoadingRamp and "1/1" or "0/1"
    lines[#lines + 1] = text("Tooltip_craft_Needs", "Needs")
        .. ": <LINE> " .. rampColor
        .. getItemNameFromFullType(C.RV_LOADING_RAMP_ITEM)
        .. " " .. rampCount .. " <RGB:1,1,1>"
    lines[#lines + 1] = text(
        "ContextMenu_RailroaderRV_Transport_LoadingRampNotConsumed",
        "The loading ramp is not consumed.")
    lines[#lines + 1] = text(
        "ContextMenu_RailroaderRV_Transport_VisualOnly",
        "Vehicles on the flatcar are visual models only. <LINE> "
            .. "Visual errors may occur. <LINE> The model may differ from "
            .. "the real vehicle. <LINE> It does not show the vehicle's "
            .. "actual state.")
    lines[#lines + 1] = text(
        "ContextMenu_RailroaderRV_Transport_VehicleIDChanges",
        "Transport deletes the original vehicle. <LINE> A new vehicle is "
            .. "created at the destination. <LINE> It has the same saved "
            .. "state. <LINE> The game engine prevents Lua from preserving "
            .. "the vehicle ID. <LINE> Mods that depend on vehicle IDs may "
            .. "break. <LINE> This includes some RV mods. <LINE> Loading "
            .. "drops the vehicle's key and container contents. <LINE> They "
            .. "fall to the ground. <LINE> This includes trunk and glove box "
            .. "items. <LINE> Unloading does not recreate those items.")
    return table.concat(lines, " <LINE> ")
end

local function nearbyVehicles(player)
    local result = {}
    local position = playerPosition(player)
    if not position then return result end

    local cell = getCell()
    local centerX = math.floor(position.x)
    local centerY = math.floor(position.y)
    local centerZ = math.floor(position.z)
    local seen = {}
    for x = centerX - 6, centerX + 6 do
        for y = centerY - 6, centerY + 6 do
            local square = cell:getGridSquare(x, y, centerZ)
            if square then
                local objects = square:getMovingObjects()
                for index = 0, objects:size() - 1 do
                    local vehicle = objects:get(index)
                    if instanceof(vehicle, "BaseVehicle") then
                        local dx = vehicle:getX() - position.x
                        local dy = vehicle:getY() - position.y
                        local vehicleId = vehicle:getId()
                        local key = tostring(vehicleId)
                        if dx * dx + dy * dy <= 36 and not seen[key] then
                            seen[key] = true
                            local name = ISVehicleMenu.getVehicleDisplayName(vehicle)
                            result[#result + 1] = {
                                id = vehicleId,
                                label = name .. " [" .. key .. "]",
                            }
                        end
                    end
                end
            end
        end
    end
    table.sort(result, function(left, right)
        return left.label < right.label
    end)
    return result
end

local function cargoDisplayName(cargo)
    local script = getScriptManager():getVehicle(cargo.vehicleScript)
    local carName = script:getCarModelName() or script:getName()
    return text("IGUI_VehicleName" .. carName, carName)
end

local function addLoadVehicleSubmenu(context, option, player, unitId,
        hasLoadingRamp)
    local submenu = ISContextMenu:getNew(context)
    context:addSubMenu(option, submenu)
    local vehicles = nearbyVehicles(player)
    if #vehicles == 0 then
        local empty = submenu:addOption(text(
            "ContextMenu_RailroaderRV_LoadVehicle_NoNearby",
            "No nearby vehicles"))
        empty.notAvailable = true
        return
    end
    for _, vehicle in ipairs(vehicles) do
        local vehicleOption = submenu:addOption(vehicle.label, player,
            requestLoadVehicle,
            unitId, vehicle.id)
        vehicleOption.notAvailable = not hasLoadingRamp
        vehicleOption.toolTip = newMenuOptionToolTip(vehicle.label,
            transportTooltipDescription(true, hasLoadingRamp))
    end
end

local function addUnloadVehicleSubmenu(context, option, player, unitId,
        hasLoadingRamp)
    local submenu = ISContextMenu:getNew(context)
    context:addSubMenu(option, submenu)
    local cars = FlatcarVisualClient.cargoForUnit(unitId)
    if #cars == 0 then
        local empty = submenu:addOption(text(
            "ContextMenu_RailroaderRV_UnloadVehicle_Empty",
            "No vehicles on this flatcar"))
        empty.notAvailable = true
        return
    end
    for _, cargo in ipairs(cars) do
        local label = cargoDisplayName(cargo) .. " ["
            .. tostring(cargo.cargoId) .. "]"
        local cargoOption = submenu:addOption(label, player,
            requestUnloadVehicle,
            unitId, cargo.cargoId)
        cargoOption.notAvailable = not hasLoadingRamp
        cargoOption.toolTip = newMenuOptionToolTip(label,
            transportTooltipDescription(true, hasLoadingRamp))
        cargoOption.onHighlightParams = { player, unitId, cargo.cargoId,
            hasLoadingRamp, cargo.vehicleScript }
        cargoOption.onHighlight = function(_option, _menu, isHighlighted,
                optionPlayer, optionUnitId, optionCargoId, canUnload,
                optionVehicleScript)
            if isHighlighted and canUnload then
                FlatcarVisualClient.showUnloadPreview(optionPlayer,
                    optionUnitId, optionCargoId, optionVehicleScript,
                    _menu, _option)
            else
                FlatcarVisualClient.clearUnloadPreview(optionUnitId,
                    optionCargoId)
            end
        end
    end
end

local function safehouseWaterUnavailable(water)
    return water.tankCount <= 0
        or not water.supplyPumpInstalled
        or not water.filter
        or not water.supplyPumpPowered
        or water.filterRemainingL <= 0
end

local function safehouseClaimState(snapshot)
    local mapping = Menu.getUtilityMapping()
    if not snapshot
            or UtilityClient.mappingKey(snapshot)
                ~= UtilityClient.mappingKey(mapping) then
        return "waiting"
    end
    if safehouseWaterUnavailable(snapshot.water) then return "water" end
    return nil
end

local function updateSafehouseClaimOption(option, snapshot)
    local state = safehouseClaimState(snapshot)
    option.notAvailable = state ~= nil
    if state == "water" then
        option.toolTip = ISWorldObjectContextMenu.addToolTip()
        option.toolTip.description = text(
            "ContextMenu_RailroaderRV_ClaimSafehouse_WaterUnavailable",
            "认领安全屋需要房车供水系统正常运转")
    elseif state == "waiting" then
        option.toolTip = ISWorldObjectContextMenu.addToolTip()
        option.toolTip.description = text(
            "UI_RailroaderRV_Utility_Waiting", "等待服务器快照")
    else
        option.toolTip = nil
    end
    return state
end

local function requestSafehouseClaim(player)
    if not player or safehouseClaimState(UtilityClient.getSnapshot()) then
        return false
    end
    sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_SAFEHOUSE_CLAIM, {})
    return true
end

local function addExit(playerNum, context, test)
    local label = text("ContextMenu_RailroaderRV_Exit", "Exit RV")
    if optionAlreadyExists(context, label) then
        return true
    end
    local optionPlayer = localPlayer(playerNum)
    if test then
        context:addOption(label, optionPlayer, requestExit)
        return markTest()
    end
    local option = context:addOption(label, optionPlayer, requestExit)
    option.iconTexture = getTexture(ICON_EXIT_RV)
    return true
end

local function addSafehouseClaim(playerNum, context, test)
    local player = localPlayer(playerNum)
    if not player or not Menu.getUtilityMapping()
        or not mapContainsPlayer(player) then return false end
    local claimLabel = text("ContextMenu_RailroaderRV_ClaimSafehouse",
        "Claim RV Safehouse")
    if optionAlreadyExists(context, claimLabel) then return true end
    local option = context:addOption(claimLabel, player, requestSafehouseClaim)
    if test then return markTest() end
    Menu._safehouseClaimOption = option
    Menu._safehouseClaimPlayer = player
    local state = updateSafehouseClaimOption(option,
        UtilityClient.getSnapshot())
    if state == "waiting" then UtilityClient.requestSnapshot(player) end
    return true
end

local function unitInReach(player, unit)
    local position = playerPosition(player)
    if not position or not unit then return false end
    local geometry = Units.geometry(unit, position.x, position.y)
    if not geometry then return false end
    local reach
    if unit.isLocomotive then
        reach = geometry.mountReachTiles
    else
        reach = C.RV_MOUNT_REACH
    end
    return geometry.hullDistanceTiles ~= nil and reach ~= nil
        and geometry.hullDistanceTiles <= reach
end

local function nearestUnitInReach(player)
    local position = playerPosition(player)
    if not position then return nil end
    local units = Units.list()
    if not units then return nil end
    local best, bestDistance
    for _, unit in ipairs(units) do
        local geometry = Units.geometry(unit, position.x, position.y)
        -- A unit without its current pose cannot be considered a nearby target.
        if geometry and geometry.hullDistanceTiles ~= nil then
            local reach
            if unit.isLocomotive then
                reach = geometry.mountReachTiles
            else
                reach = C.RV_MOUNT_REACH
            end
            local distance = geometry.hullDistanceTiles
            if reach ~= nil and distance <= reach
                    and (bestDistance == nil or distance < bestDistance) then
                best, bestDistance = unit, distance
            end
        end
    end
    return best
end

function Menu.getUtilityMapping()
    local mapping = Menu._rvUtilityMapping
    if mapping == nil then return nil end
    return {
        rvId = mapping.rvId, locoId = mapping.locoId,
        generation = mapping.generation,
    }
end

-- Reconnect recovery is a server-created candidate only. The payload does
-- not grant permission or carry coordinates. Every utility command still
-- performs the complete server-side mapping/range gate.
function Menu.acceptUtilityMapping(args)
    if args.ok ~= true then return false end
    if not localPlayerByOnlineId(args.onlineId) then return false end
    local mapping = {
        rvId = args.rvId,
        locoId = args.locoId,
        generation = args.generation,
    }
    Menu._rvUtilityMapping = mapping
    return true
end

function Menu.clearUtilityMapping()
    Menu._rvUtilityMapping = nil
end

local function clearPendingExitBoardings()
    for onlineId in pairs(pendingExitBoardings) do
        pendingExitBoardings[onlineId] = nil
    end
end

function Menu.hasUtilityDashboardCandidate(player, insideOnly, unitIdHint)
    local mapping = Menu.getUtilityMapping()
    if not mapping or not player then return false end
    if mapContainsPlayer(player) then return true end
    if insideOnly then return false end
    local id = unitIdHint
    if id == nil then
        local nearest = nearestUnitInReach(player)
        id = nearest and nearest.id or nil
    end
    return id ~= nil and tostring(id) == mapping.locoId
end

local function visibleTrain(trainId)
    for _, train in ipairs(RR.API.trains({})) do
        if train.id == trainId then return train end
    end
    return nil
end

local function canEnterRV(train, player)
    if not player then return false end
    local rider = RR.API.riderState(train.id, player)
    if not rider then return false end
    return rider.role == "passenger"
        or ((rider.role == "driver" or rider.role == "outside")
            and math.abs(train.speed) <= C.RV_STOPPED_SPEED)
end

local function enterRVFromRadial(trainId, player)
    local train = visibleTrain(trainId)
    if train and canEnterRV(train, player) then
        requestEnter(player, train.id)
    end
end

local function openUtilityFromRadial(trainId, player)
    if Menu.hasUtilityDashboardCandidate(player, false, trainId) then
        RailroaderRV.UtilityContextMenu.openDashboard(player)
    end
end

local function addRailroaderRadialOptions(train, player, add)
    if canEnterRV(train, player) then
        add(text("ContextMenu_RailroaderRV_Enter", "Enter RV"),
            ICON_ENTER_RV, enterRVFromRadial)
    end
    if Menu.hasUtilityDashboardCandidate(player, false, train.id) then
        add(text("ContextMenu_RailroaderRV_UtilityDashboard",
            "RV utility panel"), ICON_UTILITY_DASHBOARD,
            openUtilityFromRadial)
    end
end

local function addUnitOptions(playerNum, context, unit, test)
    if not context or not unit or unit.id == nil then return false end
    local player = localPlayer(playerNum)
    if not player then return false end

    local enterLabel
    if unit.isLocomotive then
        enterLabel = text("ContextMenu_RailroaderRV_Enter", "Enter RV")
    else
        enterLabel = text("ContextMenu_RailroaderRV_EnterCargo",
            "Enter cargo car RV")
    end
    local dashboardLabel = text("ContextMenu_RailroaderRV_UtilityDashboard",
        "RV utility panel")
    local flatcarLabel = text("ContextMenu_RailroaderRV_ConvertToFlatcar",
        "Convert to flatcar")
    local loadVehicleLabel = text(
        "ContextMenu_RailroaderRV_LoadVehicle", "Load vehicle")
    local unloadVehicleLabel = text(
        "ContextMenu_RailroaderRV_UnloadVehicle", "Unload vehicle")
    local hasEnter = optionAlreadyExists(context, enterLabel)
    local hasDashboard = optionAlreadyExists(context, dashboardLabel)
    local hasFlatcar = optionAlreadyExists(context, flatcarLabel)
    local hasLoadVehicle = optionAlreadyExists(context, loadVehicleLabel)
    local hasUnloadVehicle = optionAlreadyExists(context, unloadVehicleLabel)
    local showDashboard = Menu.hasUtilityDashboardCandidate(player, false,
        unit.id)
    local isBX40 = unit.kind == "car_bx40"
    local isFlatcar = isBX40 and FlatcarVisualClient.isFlatcar(unit.id)
    local hasLoadingRamp = isBX40
        and player:getInventory():containsTypeRecurse(C.RV_LOADING_RAMP_ITEM)
    local showEnter = not isFlatcar
    local showFlatcar = isBX40 and not isFlatcar

    if test then
        if (showEnter and not hasEnter)
                or (showDashboard and not hasDashboard)
                or (showFlatcar and not hasFlatcar)
                or (isBX40 and not hasLoadVehicle)
                or (isBX40 and not hasUnloadVehicle) then
            return markTest()
        end
        return false
    end

    if showEnter and not hasEnter then
        local option = context:addOption(enterLabel, player, requestEnter,
            unit.id)
        option.iconTexture = getTexture(ICON_ENTER_RV)
    end
    if showDashboard and not hasDashboard then
        local option = context:addOption(dashboardLabel, player,
            RailroaderRV.UtilityContextMenu.openDashboard)
        option.iconTexture = getTexture(ICON_UTILITY_DASHBOARD)
    end
    if showFlatcar and not hasFlatcar then
        local option = context:addOption(flatcarLabel, player,
            requestFlatcarConversion, unit.id)
        -- OnPreFill runs before vanilla returns used tooltips to its pool.
        option.toolTip = newMenuOptionToolTip(text(
            "ContextMenu_RailroaderRV_ConvertToFlatcar_TooltipTitle",
            "Conversion warning"), text(
            "ContextMenu_RailroaderRV_ConvertToFlatcar_Notice",
            "Cannot be restored to an ordinary coach or bound as an RV after conversion")
            .. " <LINE> " .. text(
                "ContextMenu_RailroaderRV_ConvertToFlatcar_Bound",
                "A car already bound to an RV cannot be converted to a flatcar"))
    end
    if isBX40 and not hasLoadVehicle then
        local option = context:addOption(loadVehicleLabel)
        if isFlatcar then
            addLoadVehicleSubmenu(context, option, player, unit.id,
                hasLoadingRamp)
        end
        option.notAvailable = not isFlatcar or not hasLoadingRamp
        option.toolTip = newMenuOptionToolTip(loadVehicleLabel,
            transportTooltipDescription(isFlatcar, hasLoadingRamp))
    end
    if isBX40 and not hasUnloadVehicle then
        local option = context:addOption(unloadVehicleLabel)
        if isFlatcar then
            addUnloadVehicleSubmenu(context, option, player, unit.id,
                hasLoadingRamp)
        end
        option.notAvailable = not isFlatcar or not hasLoadingRamp
        option.toolTip = newMenuOptionToolTip(unloadVehicleLabel,
            transportTooltipDescription(isFlatcar, hasLoadingRamp))
    end
    return true
end

local function addNearbyUnitOptions(playerNum, context, test, clickedAnimal)
    local player = localPlayer(playerNum)
    if not player then return false end
    local unit
    if clickedAnimal then
        unit = clickedUnit(clickedAnimal)
        if not unit or not unitInReach(player, unit) then
            return false
        end
    else
        unit = nearestUnitInReach(player)
    end
    return addUnitOptions(playerNum, context, unit, test)
end

local CURRENT_SQUARE_REFRESH_TICKS = 120

-- IsoGameCharacter:teleportTo writes the coordinates but deliberately leaves
-- IsoMovingObject.current untouched until a normal movement/collision update.
-- Refresh that client cache only after the server-selected teleport.  The
-- official three-argument overload performs a read-only grid lookup and then
-- assigns current; it does not replace the server-authoritative roof refresh
-- (the server's temporary west-neighbour floor transaction does that).
-- Never assign Java IsoPlayer fields from Lua here: Kahlua userdata is not a
-- table, so a field write raises "attempted index of non-table" every tick.
local function refreshCurrentSquare(player, x, y, z)
    if not player or type(player.setCurrentSquareFromPosition) ~= "function" then
        return false
    end
    local ok = pcall(function()
        player:setCurrentSquareFromPosition(x, y, z)
    end)
    return ok
end

local function currentSquareMatches(player, x, y, z)
    if not player or type(player.getCurrentSquare) ~= "function" then
        return false
    end
    local ok, square = pcall(function() return player:getCurrentSquare() end)
    if not ok or not square then return false end
    local okX, squareX = pcall(function() return square:getX() end)
    local okY, squareY = pcall(function() return square:getY() end)
    local okZ, squareZ = pcall(function() return square:getZ() end)
    return okX and okY and okZ
        and finiteInteger(squareX) == math.floor(x)
        and finiteInteger(squareY) == math.floor(y)
        and finiteInteger(squareZ) == math.floor(z)
end

local function playerStillAtTargetSquare(player, x, y, z)
    if not player then return nil end
    local okX, currentX = pcall(function() return player:getX() end)
    local okY, currentY = pcall(function() return player:getY() end)
    local okZ, currentZ = pcall(function() return player:getZ() end)
    currentX, currentY, currentZ = finiteNumber(currentX),
        finiteNumber(currentY), finiteNumber(currentZ)
    if not okX or not okY or not okZ
        or currentX == nil or currentY == nil or currentZ == nil then
        return nil
    end
    return math.floor(currentX) == math.floor(x)
        and math.floor(currentY) == math.floor(y)
        and math.floor(currentZ) == math.floor(z)
end

local function scheduleCurrentSquareRefresh(player, x, y, z)
    if not player then return end
    Menu._rvCurrentSquareRefresh = {
        player = player,
        x = x,
        y = y,
        z = z,
        ticks = 0,
    }
    refreshCurrentSquare(player, x, y, z)
    if currentSquareMatches(player, x, y, z) then
        Menu._rvCurrentSquareRefresh = nil
    end
end

local function processPendingExitBoardings()
    for onlineId, pending in pairs(pendingExitBoardings) do
        if pending.awaitingServer ~= true then
            local dead = pending.player:isDead()
            local boarded, reason
            if dead then
                reason = "noplayer"
            else
                boarded, reason = RR.API.boardCar(pending.locoId,
                    pending.player)
            end
            if boarded then
                pending.awaitingServer = true
                scheduleCurrentSquareRefresh(pending.player,
                    boarded.x, boarded.y, boarded.z)
                sendClientCommand(pending.player, C.MOD_ID,
                    C.COMMAND_RV_EXIT, {
                        boardToken = pending.token, boarded = true,
                    })
            elseif reason ~= "unknown" and reason ~= "notloaded" then
                pending.awaitingServer = true
                sendClientCommand(pending.player, C.MOD_ID,
                    C.COMMAND_RV_EXIT, {
                        boardToken = pending.token, boarded = false,
                    })
            end
        end
    end
end

function Menu.onTick()
    processPendingExitBoardings()
    local pending = Menu._rvCurrentSquareRefresh
    if type(pending) ~= "table" then return end
    pending.ticks = pending.ticks + 1
    local player = pending.player
    if not player or pending.ticks > CURRENT_SQUARE_REFRESH_TICKS then
        Menu._rvCurrentSquareRefresh = nil
        return
    end
    local dead = false
    pcall(function() dead = player:isDead() end)
    if dead then
        Menu._rvCurrentSquareRefresh = nil
        return
    end
    -- This bounded refresh belongs only to its server-selected RV teleport.
    -- If another system has since moved the player, leave that system's
    -- current-square state alone instead of restoring this stale target.
    if playerStillAtTargetSquare(player, pending.x, pending.y, pending.z) == false then
        Menu._rvCurrentSquareRefresh = nil
        return
    end
    if currentSquareMatches(player, pending.x, pending.y, pending.z) then
        Menu._rvCurrentSquareRefresh = nil
        return
    end
    refreshCurrentSquare(player, pending.x, pending.y, pending.z)
    if currentSquareMatches(player, pending.x, pending.y, pending.z) then
        Menu._rvCurrentSquareRefresh = nil
    end
end

function Menu.OnFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if not context then return end
    local player = localPlayer(playerNum)
    if not player then
        return
    end
    local dead = false
    pcall(function() dead = player:isDead() end)
    if dead then
        return
    end
    if not mapContainsPlayer(player) then
        addNearbyUnitOptions(playerNum, context, test)
        return
    end
    addExit(playerNum, context, test)
    addSafehouseClaim(playerNum, context, test)
end

function Menu.OnClickedAnimalForContext(playerNum, context, animals, test)
    for _, animal in ipairs(animals) do
        if addNearbyUnitOptions(playerNum, context, test, animal) then
            return true
        end
    end
    return false
end

-- The vanilla world-menu pipeline fires OnPreFillWorldObjectContextMenu before
-- it decides whether the clicked square has a fetchable world object.  Inside
-- a generated RV the player will often right-click an ordinary floor square,
-- so the later OnFillWorldObjectContextMenu event is skipped when fetch.c == 0.
-- Exit is a player-state action and must remain available on those empty
-- squares, including after reconnect when the live locomotive may be absent.
function Menu.OnPreFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if not context then return end
    local player = localPlayer(playerNum)
    if not player then
        return
    end
    local dead = false
    pcall(function() dead = player:isDead() end)
    if dead then
        return
    end
    local inside = mapContainsPlayer(player)
    if not inside then
        addNearbyUnitOptions(playerNum, context, test)
        return
    end
    addExit(playerNum, context, test)
    addSafehouseClaim(playerNum, context, test)
end

function Menu.OnServerCommand(module, command, args)
    if module ~= C.MOD_ID then return end
    if command == C.COMMAND_RV_UTILITY_MAPPING then
        if Menu._safehouseClaimOption then
            local state = updateSafehouseClaimOption(
                Menu._safehouseClaimOption, UtilityClient.getSnapshot())
            if state == "waiting" and Menu._safehouseClaimPlayer then
                UtilityClient.requestSnapshot(Menu._safehouseClaimPlayer)
            end
        end
        return
    elseif command == C.COMMAND_RV_UTILITY_SNAPSHOT then
        if Menu._safehouseClaimOption then
            updateSafehouseClaimOption(Menu._safehouseClaimOption, args)
        end
        return
    elseif command == C.COMMAND_FINAL_RELOCATE then
        if args.locoId ~= nil then rememberUtilityMapping(args, "enter") end
        return
    end
    if command == C.COMMAND_RV_SAFEHOUSE_SYNC then
        if isMultiplayer() then
            SafeHouse.addSafeHouse(args.x, args.y, args.w, args.h, args.owner)
        end
        local player = localPlayerByOnlineId(args.onlineId)
        if player then
            local message = text("UI_RailroaderRV_Safehouse_Claimed",
                "The RV driver's cab is now your safehouse.")
            player:setHaloNote(message, 100, 255, 100, 5000)
        end
        return
    elseif command == C.COMMAND_RV_SAFEHOUSE_RESULT then
        local reasonKeys = {
            ["invalid-request"] = "UI_RailroaderRV_Safehouse_Reject_InvalidRequest",
            ["player-unavailable"] = "UI_RailroaderRV_Safehouse_Reject_PlayerUnavailable",
            ["rv-not-found"] = "UI_RailroaderRV_Safehouse_Reject_NotGenerated",
            ["rv-not-active"] = "UI_RailroaderRV_Safehouse_Reject_NotActive",
            ["busy"] = "UI_RailroaderRV_Safehouse_Reject_Busy",
            ["outside-rv"] = "UI_RailroaderRV_Safehouse_Reject_Inside",
            ["permission-denied"] = "UI_RailroaderRV_Safehouse_Reject_Permission",
            ["water-tanks-missing"] = "UI_RailroaderRV_Safehouse_Reject_Tanks",
            ["water-pump-missing"] = "UI_RailroaderRV_Safehouse_Reject_Pump",
            ["water-filter-missing"] = "UI_RailroaderRV_Safehouse_Reject_Filter",
            ["water-unpowered"] = "UI_RailroaderRV_Safehouse_Reject_Power",
            ["water-filter-exhausted"] = "UI_RailroaderRV_Safehouse_Reject_FilterExhausted",
            ["safehouse-overlap"] = "UI_RailroaderRV_Safehouse_Reject_Overlap",
        }
        local player = localPlayerByOnlineId(args.onlineId)
        if player then
            local key = assert(reasonKeys[args.reason],
                "RailroaderRV: unknown safehouse claim result")
            local message = text(key, "The RV safehouse claim was rejected.")
            player:setHaloNote(message, 255, 80, 80, 5000)
        end
        return
    end
    if command ~= C.COMMAND_RV_TELEPORT then return end
    local onlineId = args.onlineId
    if args.ok == false then
        if args.reason == C.INVALID_RV_DATA then
            local player = localPlayerByOnlineId(onlineId)
            if player and type(player.setHaloNote) == "function" then
                local message = text("UI_RailroaderRV_InvalidRVData",
                    "RV data is invalid. Delete this save and recreate it.")
                pcall(function()
                    player:setHaloNote(message, 255, 255, 255, 5000)
                end)
            end
        end
        if args.reason then print("[RailroaderRV] " .. tostring(args.reason)) end
        return
    end
    local player = localPlayerByOnlineId(onlineId)
    if not player then return end
    if args.action == "exit-board" then
        pendingExitBoardings[onlineId] = {
            player = player, token = args.boardToken,
            locoId = args.boardCarId, awaitingServer = false,
        }
        player:teleportTo(args.x, args.y, args.z)
        return
    elseif args.action == "exit-board-complete" then
        local pendingBoarding = pendingExitBoardings[onlineId]
        if pendingBoarding
            and pendingBoarding.token == args.boardToken then
            pendingExitBoardings[onlineId] = nil
        end
        rememberUtilityMapping(args, "exit")
        return
    elseif args.action == "exit-board-cancel" then
        local pendingBoarding = pendingExitBoardings[onlineId]
        if not pendingBoarding
            or pendingBoarding.token ~= args.boardToken then
            return
        end
        pendingExitBoardings[onlineId] = nil
        player:teleportTo(args.x, args.y, args.z)
        scheduleCurrentSquareRefresh(player, args.x, args.y, args.z)
        return
    end
    rememberUtilityMapping(args)
    local x, y, z = args.x, args.y, args.z
    player:teleportTo(x, y, z)
    scheduleCurrentSquareRefresh(player, x, y, z)
end

if Events and Events.OnClickedAnimalForContext
    and type(Events.OnClickedAnimalForContext.Add) == "function" then
    Events.OnClickedAnimalForContext.Add(Menu.OnClickedAnimalForContext)
end
if Events and Events.OnFillWorldObjectContextMenu
    and type(Events.OnFillWorldObjectContextMenu.Add) == "function" then
    Events.OnFillWorldObjectContextMenu.Add(Menu.OnFillWorldObjectContextMenu)
end
if Events and Events.OnPreFillWorldObjectContextMenu
    and type(Events.OnPreFillWorldObjectContextMenu.Add) == "function" then
    Events.OnPreFillWorldObjectContextMenu.Add(Menu.OnPreFillWorldObjectContextMenu)
end
if Events and Events.OnServerCommand and type(Events.OnServerCommand.Add) == "function" then
    Events.OnServerCommand.Add(Menu.OnServerCommand)
end
local function clearContextConnectionState()
    Menu.clearUtilityMapping()
    clearPendingExitBoardings()
end

if Events and Events.OnConnected and type(Events.OnConnected.Add) == "function" then
    Events.OnConnected.Add(clearContextConnectionState)
end
if Events and Events.OnDisconnect and type(Events.OnDisconnect.Add) == "function" then
    Events.OnDisconnect.Add(clearContextConnectionState)
end
if Events and Events.OnTick and type(Events.OnTick.Add) == "function"
    and not Menu._rvCurrentSquareRefreshHook then
    Events.OnTick.Add(Menu.onTick)
    Menu._rvCurrentSquareRefreshHook = true
end

RR.API.onBoardMenu(addRailroaderRadialOptions)
RR.API.onCabMenu(addRailroaderRadialOptions)

return Menu
