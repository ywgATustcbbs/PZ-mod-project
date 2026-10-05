"""Offline behavior tests for the production RV timed-action install path."""

from __future__ import annotations

from pathlib import Path
import unittest

try:
    from lupa import LuaRuntime
except ImportError as exc:
    raise RuntimeError(
        "Offline Lua checks require Lupa. Install it with "
        "`python -m pip install lupa`."
    ) from exc


ROOT = Path(__file__).resolve().parents[2]
MOD_ROOT = ROOT / "RailroaderRV" / "contents" / "mods" / "RailroaderRV" / "42"


HARNESS = r"""
package.path = [[__MEDIA_LUA__/shared/?.lua;__MEDIA_LUA__/server/?.lua;__MEDIA_LUA__/client/?.lua;]] .. package.path
RailroaderRV = {}
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local C = require("RailroaderRV/Common/RV_Constants")
RVTestConstants = U
local root = { records = {} }
local commitCount, snapshotCount, scanCount = 0, 0, 0
local scanResult, now, requestedLoadW = true, 1, 0
local missingScanSquareReturned = false
local weather = { hour = 12, month = 6, cloud = 0,
    precipitation = 0, fog = 0, wind = 45 }
local activeContext, activePlayer, inventory

ModData = {
    get = function() return root end,
    getOrCreate = function() return root end,
    transmit = function() commitCount = commitCount + 1 end,
}
function sendServerCommand(player, module, command, payload)
    if command == C.COMMAND_RV_UTILITY_SNAPSHOT then
        snapshotCount = snapshotCount + 1
    end
end
function sendRemoveItemFromContainer() end
function sendAddItemToContainer() end
function instanceof() return false end
function instanceItem(fullType)
    local item = { fullType = fullType, modData = {} }
    function item:setCondition(value) self.condition = value end
    function item:setCurrentUsesFloat(value) self.usedDelta = value end
    function item:setItemCapacity(value) self.itemCapacity = value end
    function item:setName(value) self.name = value end
    function item:getModData() return self.modData end
    function item:getFullType() return self.fullType end
    function item:getCondition() return self.condition or 100 end
    function item:getConditionMax() return self.conditionMax or 100 end
    function item:getCurrentUsesFloat() return self.usedDelta or 0 end
    function item:getName() return self.name or self.fullType end
    return item
end
function isClient() return false end
function getGameTime()
    return {
        getWorldAgeHours = function() return now end,
        getTimeOfDay = function() return weather.hour end,
        getMonth = function() return weather.month end,
    }
end
function getClimateManager()
    return {
        getCloudIntensity = function() return weather.cloud end,
        getPrecipitationIntensity = function() return weather.precipitation end,
        getFogIntensity = function() return weather.fog end,
        getWindspeedKph = function() return weather.wind end,
    }
end
RainManager = { isRaining = function() return false end }

ISBaseTimedAction = {}
function ISBaseTimedAction:derive(name)
    local derived = {}
    derived.__index = derived
    return setmetatable(derived, { __index = self })
end
function ISBaseTimedAction:new(character)
    return setmetatable({ character = character }, self)
end
function ISBaseTimedAction:stop() end
function ISBaseTimedAction:perform() end
package.preload["TimedActions/ISBaseTimedAction"] = function()
    return ISBaseTimedAction
end

local requestedLoad
package.preload["RailroaderRV/Power/RV_UtilityPowerDevices"] = function()
    local actual = dofile([[__MEDIA_LUA__/server/RailroaderRV/Power/RV_UtilityPowerDevices.lua]])
    requestedLoad = {
        scan = function(identity, record, player, slotIndex)
            scanCount = scanCount + 1
            missingScanSquareReturned = false
            return actual.scan(identity, record, player, slotIndex)
        end,
        requestedLoadW = function() return requestedLoadW, 0 end,
        potentialLoadW = function() return 0 end,
        count = function() return 0 end,
        ensureInitialized = actual.ensureInitialized,
        initialize = actual.initialize,
    }
    return requestedLoad
end

local proxyGenerator = {
    setCondition = function() end,
    setFuel = function() end,
    setActivated = function() end,
    sync = function() end,
}
local proxySquare = { getGenerator = function() return proxyGenerator end }
package.preload["RailroaderRV/Common/RV_ServerWorld"] = function()
    return {
        getCellForPlayer = function() return {} end,
        getSquare = function()
            if not scanResult and not missingScanSquareReturned then
                missingScanSquareReturned = true
                return nil
            end
            return proxySquare
        end,
        squareSnapshot = function() return {} end,
    }
end
package.preload["RailroaderRV/Water/RV_UtilityWater"] = function()
    return { setConnection = function() return true end }
end
package.preload["RailroaderRV/Core/RV_Server_Core"] = function()
    return { tickModulo = function() return false end }
end

local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
RVTestRoomTemplate = RoomTemplate
local currentTemplate = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local alternateRoofCells = {}
for x = 90, 92 do
    for y = 90, 92 do
        alternateRoofCells[#alternateRoofCells + 1] = { x = x, y = y, z = 3 }
    end
end
RoomTemplate.register({ metadata = { id = "fixture-roof-b" },
    roofCells = alternateRoofCells,
    powerProxy = currentTemplate.powerProxy, waterProxy = currentTemplate.waterProxy })

local items = {}
local function inventoryCollection()
    local collection = {}
    function collection:size() return #items end
    function collection:get(index) return items[index + 1] end
    return collection
end
inventory = {}
function inventory:getItems() return inventoryCollection() end
function inventory:Remove(item)
    for index = 1, #items do
        if items[index] == item then table.remove(items, index); return item end
    end
    return false
end
function inventory:AddItem(item) items[#items + 1] = item; return item end

activePlayer = { getInventory = function() return inventory end,
    removeFromHands = function() end }
function newItem(itemId, fullType, condition, maxCondition, usedDelta)
    local item = { id = itemId, fullType = fullType, condition = condition,
        conditionMax = maxCondition, usedDelta = usedDelta, modData = {} }
    function item:getID() return self.id end
    function item:getFullType() return self.fullType end
    function item:getCondition() return self.condition end
    function item:getConditionMax() return self.conditionMax end
    function item:getCurrentUsesFloat() return self.usedDelta end
    function item:getName() return self.fullType end
    function item:getModData() return self.modData end
    function item:setName(value) self.name = value end
    return item
end

local identity = { rvId = "fixture-rv", generation = 7 }
local mappingRecord = { templateId = RoomTemplate.TEMPLATE_ID,
    rvPosition = { x = 0, y = 0, z = 0 }, slotIndex = 1 }
activeContext = { identity = identity, record = mappingRecord, phase = "READY",
    locomotiveSide = false, player = activePlayer }
RailroaderRV.Server = {
    resolveCurrentUtilityRV = function(player)
        if player ~= activePlayer then return false, "unmapped-rv" end
        activeContext.player = player
        return true, activeContext
    end,
    isGenerationTransactionActiveForRV = function() return false end,
    isWallReloadTransactionActive = function() return false end,
}
RailroaderRV.RailroaderServer = {
    onlinePlayersSnapshot = function() return { activePlayer } end,
}

local Store = require("RailroaderRV/Core/RV_UtilityStore")
local Power = require("RailroaderRV/Power/RV_UtilityPower")
local UtilityServer = require("RailroaderRV/Core/RV_UtilityServer")
local Action = require("TimedActions/ISRVUtilityAction")
local Roof = require("RailroaderRV/Roof/RV_RoofDevices")
local P = require("RailroaderRV/Power/RV_UtilityPowerConfig")
RVTestPowerConfig = P

function reset(operation, itemType, target, alternateTemplate, scanSucceeds)
    root.records = {}
    items = {}
    commitCount, snapshotCount, scanCount = 0, 0, 0
    scanResult, now, requestedLoadW = scanSucceeds ~= false, 1, 0
    weather = { hour = 12, month = 6, cloud = 0,
        precipitation = 0, fog = 0, wind = 45 }
    identity = { rvId = "fixture-rv", generation = 7 }
    mappingRecord = { templateId = alternateTemplate and "fixture-roof-b"
            or RoomTemplate.TEMPLATE_ID,
        rvPosition = { x = 0, y = 0, z = 0 }, slotIndex = 1 }
    activeContext = { identity = identity, record = mappingRecord,
        phase = "READY", locomotiveSide = false, player = activePlayer }
    local record = Store.getRecord(identity, true)
    record.power.lastSettlementTime = 0
    if target == "roof-occupied" then
        local occupiedCell = RoomTemplate.roofCells(
            RoomTemplate.get(RoomTemplate.TEMPLATE_ID))[1]
        record.power.generators[1] = { id = 1, fullType = "Base.Generator",
            name = "fixture generator", condition = 100, usedDelta = 0.5,
            enabled = false, x = occupiedCell.x, y = occupiedCell.y,
            z = occupiedCell.z }
        record.power.nextGeneratorId = 2
    elseif target == "roof-rain-neighbor" then
        record.water.roofCollectors["90:90:3"] = { x = 90, y = 90, z = 3,
            itemType = "Base.Bucket", waterLiters = 0 }
    end
    if operation == U.OP_ADD_BATTERY and target == "full-capacity" then
        for index = 1, P.MAX_BATTERIES do
            record.power.batteries[index] = { id = index,
                fullType = "Base.CarBattery1", condition = 100,
                maxCondition = 100, usedDelta = 1 }
        end
        record.power.nextBatteryId = P.MAX_BATTERIES + 1
    end
    Store.commit(record, identity)
    commitCount = 0
    local cell
    if target == "roof-b" or target == "roof-rain-neighbor" then
        cell = { x = 90, y = 91, z = 3 }
    elseif target == "roof-not-member" then
        cell = { x = 90, y = 91, z = 5 }
    elseif target == "roof-a" or target == "roof-occupied" then
        cell = RoomTemplate.roofCells(
            RoomTemplate.get(RoomTemplate.TEMPLATE_ID))[1]
    end
    local condition = itemType == P.CHARGER_TYPE and 900 or 80
    local conditionMax = itemType == P.CHARGER_TYPE and 1000 or 100
    local usedDelta = itemType == "Base.CarBattery1" and 0.65 or 1
    local item = itemType and newItem("fixture-item", itemType,
        condition, conditionMax, usedDelta) or nil
    if item then inventory:AddItem(item) end
    local timedAction = Action:new(activePlayer, operation, item, cell)
    return timedAction
end

function addBatteryCapacityAfterQueue(action)
    local record = Store.getRecord(identity, false)
    for index = 1, P.MAX_BATTERIES do
        record.power.batteries[index] = { id = index,
            fullType = "Base.CarBattery1", condition = 100,
            maxCondition = 100, usedDelta = 1 }
    end
    record.power.nextBatteryId = P.MAX_BATTERIES + 1
    Store.commit(record, identity)
    commitCount = 0
    return action
end

function state()
    local record = Store.getRecord(identity, false)
    local generator = record.power.generators[1]
    local roofCollector, roofCollectorCount
    roofCollectorCount = 0
    for _, collector in pairs(record.water.roofCollectors) do
        roofCollectorCount = roofCollectorCount + 1
        roofCollector = collector
    end
    local returnedItem = items[1]
    return { itemCount = #items, batteryCount = #record.power.batteries,
        chargerInstalled = record.power.charger ~= nil,
        generatorCount = #record.power.generators,
        generatorFullType = generator and generator.fullType or nil,
        generatorCondition = generator and generator.condition or nil,
        generatorUsedDelta = generator and generator.usedDelta or nil,
        generatorX = generator and generator.x or -999,
        generatorY = generator and generator.y or -999,
        generatorZ = generator and generator.z or -999,
        roofCollectorCount = roofCollectorCount,
        roofCollectorType = roofCollector and roofCollector.itemType or nil,
        roofCollectorWaterLiters = roofCollector and roofCollector.waterLiters or nil,
        returnedItemType = returnedItem and returnedItem:getFullType() or nil,
        returnedItemCondition = returnedItem and returnedItem:getCondition() or nil,
        returnedItemUsedDelta = returnedItem
            and returnedItem:getCurrentUsesFloat() or nil,
        lastSettlementTime = record.power.lastSettlementTime,
        scanCount = scanCount, commitCount = commitCount,
        snapshotCount = snapshotCount }
end

function makeRoofAction(operation, item, cell)
    return Action:new(activePlayer, operation, item, cell)
end

function clearActionCounts()
    scanCount, commitCount, snapshotCount = 0, 0, 0
end

function setRoofWater(cell, liters)
    local record = Store.getRecord(identity, false)
    record.water.roofCollectors[Roof.key(cell)].waterLiters = liters
    Store.commit(record, identity)
    clearActionCounts()
end

function assertTemplateSelection()
    local firstTemplate = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
    local secondTemplate = RoomTemplate.get("fixture-roof-b")
    local roofCellA = RoomTemplate.roofCells(firstTemplate)[1]
    local roofCellB = RoomTemplate.roofCells(secondTemplate)[1]
    assert(Roof.isRoofCell(firstTemplate, roofCellA))
    assert(not Roof.isRoofCell(firstTemplate, roofCellB))
    assert(Roof.isRoofCell(secondTemplate, roofCellB))
    assert(not Roof.isRoofCell(secondTemplate, roofCellA))
    local diagonalCell = { x = 91, y = 91, z = 3 }
    local diagonalRain = { x = 90, y = 90, z = 3, type = Roof.DEVICE_RAIN }
    local canPlaceSolar = Roof.canPlace(secondTemplate, { diagonalRain },
        diagonalCell, Roof.DEVICE_SOLAR)
    local canPlaceWind = Roof.canPlace(secondTemplate, { diagonalRain },
        diagonalCell, Roof.DEVICE_WIND)
    local canPlaceRain = Roof.canPlace(secondTemplate, {
        { x = 91, y = 91, z = 3, type = Roof.DEVICE_WIND },
    }, diagonalRain, Roof.DEVICE_RAIN)
    local canPlaceFuel = Roof.canPlace(secondTemplate, { diagonalRain },
        diagonalCell, Roof.DEVICE_FUEL)
    assert(not canPlaceSolar and not canPlaceWind and not canPlaceRain)
    assert(canPlaceFuel)
    return true
end

function setWeather(hour, month, cloud, precipitation, fog, wind)
    weather = { hour = hour, month = month, cloud = cloud,
        precipitation = precipitation, fog = fog, wind = wind }
end

function evaluateSolarMix(withFuel, fuelEnabled, fuelLiters,
    batteryChargeWh, loadW, chargerInstalled)
    local record = Store.getRecord(identity, false)
    local power = record.power
    power.generators = {
        { id = 1, fullType = "RailroaderRV.SolarPanel", enabled = true },
        { id = 2, fullType = "RailroaderRV.WindTurbine", enabled = true },
    }
    power.fuelTanks = {}
    power.virtualFuelL = 0
    if withFuel then
        power.generators[#power.generators + 1] = { id = 3,
            fullType = "Base.Generator", enabled = fuelEnabled }
        if fuelLiters > 0 then
            power.fuelTanks = { { capacityL = 20 } }
            power.virtualFuelL = fuelLiters
        end
    end
    power.batteries = { { id = 1, fullType = "Base.CarBattery1",
        condition = 100, maxCondition = 100, usedDelta = 1 } }
    power.batteryWh = batteryChargeWh
    power.charger = chargerInstalled
        and { condition = 1000, conditionMax = 1000 } or nil
    power.inverter = { condition = 1000, conditionMax = 1000 }
    requestedLoadW = loadW
    return Power.snapshot(record, identity, activeContext)
end

function settleControllerScenario()
    local record = Store.getRecord(identity, false)
    local power = record.power
    power.generators = {
        { id = 1, fullType = "RailroaderRV.SolarPanel", enabled = true },
        { id = 2, fullType = "RailroaderRV.WindTurbine", enabled = true },
        { id = 3, fullType = "Base.Generator", enabled = true },
    }
    power.fuelTanks = { { capacityL = 20 } }
    power.virtualFuelL = 10
    power.batteries = { { id = 1, fullType = "Base.CarBattery1",
        condition = 100, maxCondition = 100, usedDelta = 1 } }
    power.batteryWh = 360
    power.charger = { condition = 1000, conditionMax = 1000 }
    power.inverter = { condition = 1000, conditionMax = 1000 }
    power.controller = { fullType = P.CONTROLLER_TYPE, condition = 1000,
        conditionMax = 1000 }
    power.lastSettlementTime = 0
    requestedLoadW = 0
    now = 1
    local settled = Power.settleAndRefreshLoad(identity, activePlayer,
        record, mappingRecord)
    local updated = Store.getRecord(identity, false)
    return settled, updated.power.generators[1].enabled,
        updated.power.generators[2].enabled, updated.power.generators[3].enabled,
        updated.power.batteryWh, updated.power.virtualFuelL
end

function settleBatteryScenario(initialChargeWh, loadW, withFuel)
    local record = Store.getRecord(identity, false)
    local power = record.power
    power.generators = {
        { id = 1, fullType = "RailroaderRV.SolarPanel", enabled = true },
        { id = 2, fullType = "RailroaderRV.WindTurbine", enabled = true },
    }
    if withFuel then
        power.generators[3] = { id = 3, fullType = "Base.Generator", enabled = true }
        power.fuelTanks = { { capacityL = 20 } }
        power.virtualFuelL = 10
    else
        power.fuelTanks = {}
        power.virtualFuelL = 0
    end
    power.batteries = { { id = 1, fullType = "Base.CarBattery1",
        condition = 100, maxCondition = 100, usedDelta = 1 } }
    power.batteryWh = initialChargeWh
    power.charger = { condition = 1000, conditionMax = 1000 }
    power.inverter = { condition = 1000, conditionMax = 1000 }
    power.lastSettlementTime = 0
    requestedLoadW = loadW
    now = 1
    local settled = Power.settleAndRefreshLoad(identity, activePlayer,
        record, mappingRecord)
    local updated = Store.getRecord(identity, false)
    return settled, updated.power.batteryWh, updated.power.virtualFuelL
end

function evaluateUnknownRenewable(enabled)
    P.GENERATOR_TYPES["fixture.UnknownRenewable"] = {
        renewableType = "UNSUPPORTED", maxPowerW = 100,
        baseFuelLPerHour = 0, fuelLPerKWh = 0 }
    local record = Store.getRecord(identity, false)
    record.power.generators = { { id = 1,
        fullType = "fixture.UnknownRenewable", enabled = enabled } }
    return Power.snapshot(record, identity, activeContext)
end
"""


class InstallationFlowChecks(unittest.TestCase):
    def setUp(self) -> None:
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        media_lua = str(MOD_ROOT / "media/lua").replace("\\", "/")
        self.lua.execute(HARNESS.replace("__MEDIA_LUA__", media_lua))
        self.globals = self.lua.globals()
        self.constants = self.globals.RVTestConstants

    def test_native_battery_and_component_completion_use_shared_transaction(self) -> None:
        battery = self.globals.reset(
            self.constants.OP_ADD_BATTERY, "Base.CarBattery1", None, False, True
        )
        self.assertTrue(battery.complete(battery))
        result = self.globals.state()
        self.assertEqual(result.itemCount, 0)
        self.assertEqual(result.batteryCount, 1)
        self.assertEqual(result.scanCount, 1)
        self.assertEqual(result.commitCount, 1)
        self.assertEqual(result.snapshotCount, 1)

        charger = self.globals.reset(
            self.constants.OP_INSTALL_CHARGER,
            self.globals.RVTestPowerConfig.CHARGER_TYPE,
            None, False, True,
        )
        self.assertTrue(charger.complete(charger))
        result = self.globals.state()
        self.assertEqual(result.itemCount, 0)
        self.assertTrue(result.chargerInstalled)
        self.assertEqual(result.scanCount, 1)
        self.assertEqual(result.commitCount, 1)
        self.assertEqual(result.snapshotCount, 1)

    def test_cancel_and_completion_time_capacity_rejection_consume_nothing(self) -> None:
        cancelled = self.globals.reset(
            self.constants.OP_ADD_BATTERY, "Base.CarBattery1", None, False, True
        )
        cancelled.stop(cancelled)
        result = self.globals.state()
        self.assertEqual(result.itemCount, 1)
        self.assertEqual(result.batteryCount, 0)
        self.assertEqual(result.scanCount, 0)
        self.assertEqual(result.commitCount, 0)
        self.assertEqual(result.snapshotCount, 0)

        changed_capacity = self.globals.reset(
            self.constants.OP_ADD_BATTERY, "Base.CarBattery1", None, False, True
        )
        self.globals.addBatteryCapacityAfterQueue(changed_capacity)
        self.assertFalse(changed_capacity.complete(changed_capacity))
        result = self.globals.state()
        self.assertEqual(result.itemCount, 1)
        self.assertEqual(result.batteryCount, 16)
        self.assertEqual(result.scanCount, 0)
        self.assertEqual(result.commitCount, 1)
        self.assertEqual(result.snapshotCount, 1)

    def test_roof_uses_rv_template_and_rolls_back_scan_failure(self) -> None:
        self.assertTrue(self.globals.assertTemplateSelection())
        cell = self.globals.RVTestRoomTemplate.roofCells(
            self.globals.RVTestRoomTemplate.get("fixture-roof-b")
        )[1]
        # The alternate template owns this cell; its installation uses the same
        # production native action, Roof module, InventoryTransaction and Store.
        action = self.globals.reset(
            self.constants.OP_INSTALL_ROOF_DEVICE,
            "RailroaderRV.SolarPanel", "roof-b", True, False,
        )
        action.targetHint = cell
        self.assertFalse(action.complete(action))
        result = self.globals.state()
        self.assertEqual(result.itemCount, 1)
        self.assertEqual(result.generatorCount, 0)
        self.assertEqual(result.lastSettlementTime, 1)
        self.assertEqual(result.scanCount, 1)
        self.assertEqual(result.commitCount, 1)
        self.assertEqual(result.snapshotCount, 1)

        successful = self.globals.reset(
            self.constants.OP_INSTALL_ROOF_DEVICE,
            "RailroaderRV.SolarPanel", "roof-b", True, True,
        )
        self.assertTrue(successful.complete(successful))
        result = self.globals.state()
        self.assertEqual(result.itemCount, 0)
        self.assertEqual(result.generatorCount, 1)
        self.assertEqual((result.generatorX, result.generatorY,
                          result.generatorZ), (90, 91, 3))
        self.assertEqual(result.scanCount, 1)
        self.assertEqual(result.commitCount, 1)
        self.assertEqual(result.snapshotCount, 1)

    def test_roof_generator_and_rain_collector_install_remove_roundtrip(self) -> None:
        template = self.globals.RVTestRoomTemplate.get("fixture-roof-b")
        cell = self.globals.RVTestRoomTemplate.roofCells(template)[1]
        solar = self.globals.reset(
            self.constants.OP_INSTALL_ROOF_DEVICE,
            "RailroaderRV.SolarPanel", "roof-b", True, True,
        )
        solar.targetHint = cell
        self.assertTrue(solar.complete(solar))
        installed = self.globals.state()
        self.assertEqual(installed.itemCount, 0)
        self.assertEqual(installed.generatorCount, 1)
        self.assertEqual(installed.generatorFullType,
                         "RailroaderRV.SolarPanel")
        self.assertEqual(installed.generatorCondition, 80)
        self.assertAlmostEqual(installed.generatorUsedDelta, 1)
        self.assertEqual(installed.scanCount, 1)
        self.assertEqual(installed.commitCount, 1)
        self.assertEqual(installed.snapshotCount, 1)

        self.globals.clearActionCounts()
        remove_solar = self.globals.makeRoofAction(
            self.constants.OP_REMOVE_ROOF_DEVICE, None, cell
        )
        self.assertTrue(remove_solar.complete(remove_solar))
        returned_solar = self.globals.state()
        self.assertEqual(returned_solar.generatorCount, 0)
        self.assertEqual(returned_solar.itemCount, 1)
        self.assertEqual(returned_solar.returnedItemType,
                         "RailroaderRV.SolarPanel")
        self.assertEqual(returned_solar.returnedItemCondition, 80)
        self.assertAlmostEqual(returned_solar.returnedItemUsedDelta, 1)
        self.assertEqual(returned_solar.scanCount, 1)
        self.assertEqual(returned_solar.commitCount, 1)
        self.assertEqual(returned_solar.snapshotCount, 1)

        rain_cell = self.globals.RVTestRoomTemplate.roofCells(template)[3]
        rain = self.globals.reset(
            self.constants.OP_INSTALL_ROOF_DEVICE,
            self.globals.RVTestPowerConfig.RAIN_COLLECTOR_TYPE,
            "roof-b", True, True,
        )
        rain.targetHint = rain_cell
        self.assertTrue(rain.complete(rain))
        installed_rain = self.globals.state()
        self.assertEqual(installed_rain.itemCount, 0)
        self.assertEqual(installed_rain.roofCollectorCount, 1)
        self.assertEqual(installed_rain.roofCollectorType, "Base.Bucket")
        self.assertEqual(installed_rain.roofCollectorWaterLiters, 0)
        self.assertEqual(installed_rain.scanCount, 1)
        self.assertEqual(installed_rain.commitCount, 1)
        self.assertEqual(installed_rain.snapshotCount, 1)

        self.globals.setRoofWater(rain_cell, 6)
        self.assertEqual(self.globals.state().roofCollectorWaterLiters, 6)
        remove_rain = self.globals.makeRoofAction(
            self.constants.OP_REMOVE_ROOF_DEVICE, None, rain_cell
        )
        self.assertTrue(remove_rain.complete(remove_rain))
        returned_bucket = self.globals.state()
        self.assertEqual(returned_bucket.roofCollectorCount, 0)
        self.assertIsNone(returned_bucket.roofCollectorType)
        self.assertEqual(returned_bucket.itemCount, 1)
        self.assertEqual(returned_bucket.returnedItemType, "Base.Bucket")
        self.assertEqual(returned_bucket.scanCount, 1)
        self.assertEqual(returned_bucket.commitCount, 1)
        self.assertEqual(returned_bucket.snapshotCount, 1)

    def test_roof_business_rejections_leave_inventory_and_broadcast_once(self) -> None:
        cases = (
            ("roof-not-member", False, 0),
            ("roof-occupied", False, 1),
            ("roof-rain-neighbor", True, 0),
        )
        for target, alternate_template, expected_generators in cases:
            with self.subTest(target=target):
                action = self.globals.reset(
                    self.constants.OP_INSTALL_ROOF_DEVICE,
                    "RailroaderRV.SolarPanel", target,
                    alternate_template, True,
                )
                self.assertFalse(action.complete(action))
                result = self.globals.state()
                self.assertEqual(result.itemCount, 1)
                self.assertEqual(result.generatorCount, expected_generators)
                self.assertEqual(result.scanCount, 0)
                self.assertEqual(result.commitCount, 1)
                self.assertEqual(result.snapshotCount, 1)

    def test_renewable_fuel_fallback_controller_and_battery_capacity(self) -> None:
        self.globals.reset(None, None, None, False, True)
        renewable_only = self.globals.evaluateSolarMix(
            False, False, 0, 500, 0, True
        )
        self.assertEqual(renewable_only.renewableAvailablePowerW, 650)
        self.assertEqual(renewable_only.renewableUsedPowerW, 250)
        self.assertEqual(renewable_only.generationPowerW, 250)
        self.assertEqual(renewable_only.fuelConsumptionLPerHour, 0)
        self.assertEqual(renewable_only.batteryChargePowerW, 250)

        mixed = self.globals.evaluateSolarMix(True, True, 10, 720, 2000, True)
        self.assertEqual(mixed.renewableAvailablePowerW, 650)
        self.assertEqual(mixed.renewableUsedPowerW, 650)
        self.assertEqual(mixed.generationPowerW, 1500)
        self.assertAlmostEqual(mixed.fuelConsumptionLPerHour, 1.1625)
        self.assertLessEqual(mixed.batteryChargePowerW, mixed.maxChargePowerW)

        fuel_empty = self.globals.evaluateSolarMix(
            True, True, 0, 720, 2000, True
        )
        self.assertEqual(fuel_empty.renewableAvailablePowerW, 650)
        self.assertEqual(fuel_empty.generationPowerW, 650)
        self.assertEqual(fuel_empty.fuelConsumptionLPerHour, 0)

        no_charger = self.globals.evaluateSolarMix(
            False, False, 0, 720, 2000, False
        )
        self.assertEqual(no_charger.renewableAvailablePowerW, 650)
        self.assertEqual(no_charger.renewableUsedPowerW, 0)
        self.assertEqual(no_charger.generationPowerW, 0)
        self.assertEqual(no_charger.batteryChargePowerW, 0)

        settled, solar_enabled, wind_enabled, fuel_enabled, battery_wh, fuel_l = (
            self.globals.settleControllerScenario()
        )
        self.assertTrue(settled)
        self.assertTrue(solar_enabled)
        self.assertTrue(wind_enabled)
        self.assertFalse(fuel_enabled)
        self.assertEqual(battery_wh, 610)
        self.assertAlmostEqual(fuel_l, 9.9)

        charged, near_full_wh, _ = self.globals.settleBatteryScenario(
            719, 0, False
        )
        self.assertTrue(charged)
        self.assertEqual(near_full_wh, 720)
        discharged, empty_wh, remaining_fuel = self.globals.settleBatteryScenario(
            720, 2000, True
        )
        self.assertTrue(discharged)
        self.assertEqual(empty_wh, 0)
        self.assertAlmostEqual(remaining_fuel, 8.8375)

    def test_unknown_internal_renewable_profile_fails_fast_when_disabled(self) -> None:
        self.globals.reset(None, None, None, False, True)
        with self.assertRaises(Exception):
            self.globals.evaluateUnknownRenewable(False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
