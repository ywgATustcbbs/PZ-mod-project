"""Offline checks for SP and MP utility timed-action lifecycles."""

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
ACTION_PATH = (
    ROOT
    / "RailroaderRV"
    / "contents"
    / "mods"
    / "RailroaderRV"
    / "42"
    / "media"
    / "lua"
    / "shared"
    / "TimedActions"
    / "ISRVUtilityAction.lua"
)
POWER_PATH = (
    ROOT
    / "RailroaderRV"
    / "contents"
    / "mods"
    / "RailroaderRV"
    / "42"
    / "media"
    / "lua"
    / "server"
    / "RailroaderRV"
    / "Power"
    / "RV_UtilityPower.lua"
)


HARNESS = r"""
local nowMs, serverMode, clientMode = 0, false, false
local fuelAmounts, beginFuelCount, finishFuelCount = {}, 0, 0
local beginWaterCount, waterProgressCount, finishWaterCount = 0, 0, 0
local emulateCount, performCount = 0, 0

function getTimestampMs() return nowMs end
function isServer() return serverMode end
function isClient() return clientMode end
function getText(key) return key end
function emulateAnimEvent(action, interval, event)
    emulateCount = emulateCount + 1
end
Metabolics = { HeavyDomestic = "heavy", MediumWork = "medium" }

local Base = {}
Base.__index = Base
function Base:derive(name)
    local class = {}
    class.__index = class
    return setmetatable(class, { __index = self })
end
function Base:new(character)
    return setmetatable({ character = character, jobDelta = 0 }, self)
end
function Base:getJobDelta() return self.jobDelta end
function Base:forceStop()
    self.forceStopCount = (self.forceStopCount or 0) + 1
    -- Native BaseAction:forceStop sets a flag; the game calls stop later.
    self.forceStopRequested = true
end
function Base:setActionAnim() end
function Base:setOverrideHandModels() end
function Base:adjustMaxTime(value) return value end
function Base:stop() end
function Base:perform() end
package.preload["TimedActions/ISBaseTimedAction"] = function()
    ISBaseTimedAction = Base
    return Base
end
package.preload["RailroaderRV/Common/RV_UtilityConstants"] = function()
    return {
        OP_ADD_FUEL = "fuel",
        OP_INSTALL_ROOF_DEVICE = "roof-install",
        OP_REMOVE_ROOF_DEVICE = "roof-remove",
        COMPONENT_INSTALL_TIME = 100,
        GENERATOR_INSTALL_TIME = 100,
    }
end
package.preload["RailroaderRV/Power/RV_UtilityPowerConfig"] = function()
    return { FUEL_ACTION_TICKS_PER_LITER = 25, GENERATOR_INSTALL_TIME = 100,
        COMPONENT_INSTALL_TIME = 100 }
end
package.preload["RailroaderRV/Water/RV_UtilityWaterConstants"] = function()
    return {
        OP_ADD_WATER_FROM_CONTAINER = "water-add",
        OP_DRAW_WATER_FROM_SOURCE = "water-draw",
    }
end

local utility = {}
function utility.beginFuelTimedAction(character, item)
    beginFuelCount = beginFuelCount + 1
    return true, item:getFluidContainer():getAmount()
end
function utility.progressFuelTimedAction(character, item, amount)
    fuelAmounts[#fuelAmounts + 1] = amount
    return true
end
function utility.finishFuelTimedAction()
    finishFuelCount = finishFuelCount + 1
    return true
end
function utility.beginWaterTimedAction(action)
    beginWaterCount = beginWaterCount + 1
    action.serverWaterLastMs = nowMs
    action.serverWaterStarted = true
    return true
end
function utility.progressWaterTimedAction(action)
    waterProgressCount = waterProgressCount + 1
    action.serverWaterLastMs = nowMs
    return true
end
function utility.finishWaterTimedAction(action)
    finishWaterCount = finishWaterCount + 1
    utility.progressWaterTimedAction(action)
    action.serverWaterEnded = true
    return true
end
function utility.performTimedAction()
    performCount = performCount + 1
    return true
end
package.preload["RailroaderRV/Core/RV_UtilityServer"] = function()
    return utility
end

local actionPath = [[__ACTION_PATH__]]
local Action = dofile(actionPath)
local character = {
    playSound = function() return "sound" end,
    stopOrTriggerSound = function() end,
    setMetabolicTarget = function() end,
}

local function fuelItem(amount)
    local container = { amount = amount }
    function container:getAmount() return self.amount end
    local item = { container = container }
    function item:getFluidContainer() return self.container end
    function item:getStaticModel() return "fuel-container" end
    function item:setJobDelta(value) self.jobDelta = value end
    function item:setJobType(value) self.jobType = value end
    return item
end

local function reset(mode)
    nowMs, serverMode, clientMode = 0, mode == "mp", false
    fuelAmounts, beginFuelCount, finishFuelCount = {}, 0, 0
    beginWaterCount, waterProgressCount, finishWaterCount = 0, 0, 0
    emulateCount, performCount = 0, 0
end

local function fuelRun(mode, amount, progress, cancel)
    reset(mode)
    local action = Action:new(character, "fuel", fuelItem(amount))
    local netProgress = progress
    action.netAction = {
        getProgress = function() return netProgress end,
        forceComplete = function() end,
    }
    action:start()
    if mode == "mp" then action:serverStart() end
    if mode == "sp" then
        nowMs = 1000
        action.jobDelta = progress
        action:update()
    else
        action:animEvent("FuelProgress")
    end
    if cancel then
        nowMs = 1200
        action.jobDelta = cancel
        action:stop()
    else
        action.jobDelta = 1
        action:complete()
    end
    local transferred = 0
    for _, value in ipairs(fuelAmounts) do transferred = transferred + value end
    return transferred, #fuelAmounts, beginFuelCount, finishFuelCount, emulateCount
end

function fuelCompleteSp(amount)
    return fuelRun("sp", amount, 0.4, false)
end
function fuelCancelSp(amount)
    return fuelRun("sp", amount, 0.3, 0.45)
end
function fuelCompleteMp(amount)
    return fuelRun("mp", amount, 0.5, false)
end

function waterCancelSp()
    reset("sp")
    local action = Action:new(character, "water-add", nil)
    action:start()
    nowMs = 999
    action:update()
    nowMs = 1000
    action:update()
    nowMs = 1250
    action:stop()
    return beginWaterCount, waterProgressCount, finishWaterCount,
        emulateCount, action.serverWaterEnded
end

function waterCompleteSp()
    reset("sp")
    local action = Action:new(character, "water-draw", nil)
    action:start()
    nowMs = 500
    action:complete()
    return beginWaterCount, waterProgressCount, finishWaterCount, emulateCount
end

function waterContainerCompleteSp()
    reset("sp")
    local action = Action:new(character, "water-add", nil)
    action:start()
    nowMs = 500
    action:complete()
    return beginWaterCount, waterProgressCount, finishWaterCount, emulateCount
end

function waterCompleteMp()
    reset("mp")
    local action = Action:new(character, "water-draw", nil)
    action.netAction = { forceComplete = function() end }
    action:start()
    action:serverStart()
    action:animEvent("WaterProgress")
    action:complete()
    return beginWaterCount, waterProgressCount, finishWaterCount, emulateCount
end

function componentComplete(mode, operation)
    reset(mode)
    local action = Action:new(character, operation, nil)
    action:start()
    if mode == "mp" then action:serverStart() end
    action:complete()
    action:stop()
    return beginFuelCount, beginWaterCount, performCount, emulateCount,
        finishFuelCount, finishWaterCount
end

function componentCancel(mode, operation)
    reset(mode)
    local action = Action:new(character, operation, nil)
    action:start()
    if mode == "mp" then action:serverStart() end
    action:stop()
    return beginFuelCount, beginWaterCount, performCount, emulateCount,
        finishFuelCount, finishWaterCount
end
"""


POWER_HARNESS = r"""
package.preload["RailroaderRV/Common/RV_Constants"] = function()
    return { GENERATOR_INITIAL_FUEL = 5 }
end
package.preload["RailroaderRV/Common/RV_UtilityConstants"] = function()
    return { CIRCUIT_ON = "on", CIRCUIT_OFF = "off" }
end
package.preload["RailroaderRV/Power/RV_UtilityPowerConfig"] = function()
    return { GENERATOR_TYPES = {} }
end
package.preload["RailroaderRV/Water/RV_UtilityWaterConstants"] = function()
    return { SUPPLY_PUMP_WATTS = 10 }
end
package.preload["RailroaderRV/Power/RV_Generation"] = function()
    return {}
end
package.preload["RailroaderRV/Core/RV_UtilityStore"] = function()
    return { commit = function() end }
end
package.preload["RailroaderRV/Core/RV_ServerInventoryTransaction"] = function()
    return {}
end
package.preload["RailroaderRV/Power/RV_UtilityPowerDevices"] = function()
    return { scan = function() end, requestedLoadW = function() return 0 end }
end
package.preload["RailroaderRV/Common/RV_ServerWorld"] = function()
    return { getCellForPlayer = function() return {} end,
        getSquare = function() return nil end }
end
package.preload["RailroaderRV/RoomTemplate/RV_RoomTemplate"] = function()
    return { get = function()
        return { powerProxy = { x = 0, y = 0, z = 0 } }
    end }
end
package.preload["RailroaderRV/Common/RV_ServerUtil"] = function()
    return { toNumber = function(value) return value end }
end
function getGameTime()
    return { getWorldAgeHours = function() return 1 end }
end

local Power = dofile([[__POWER_PATH__]])
local identity = { rvId = "test", generation = 1 }
local mapping = { templateId = "test", rvPosition = { x = 0, y = 0, z = 0 },
    slotIndex = 1 }
local record = {
    power = { lastSettlementTime = 0, generators = {}, batteries = {},
        fuelTanks = {}, virtualFuelL = 0, batteryWh = 0,
        circuitBreakerInstalled = false },
    water = { supplyPumpInstalled = false },
}
function settleWithoutTimedAction()
    local state = Power.settlePower(identity, mapping, {}, record)
    return state.extractionPumpRunning == false,
        record.power.lastSettlementTime
end
"""


class UtilityActionLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        action_path = ACTION_PATH.as_posix()
        self.lua.execute(HARNESS.replace("__ACTION_PATH__", action_path))

    def test_power_settlement_accepts_no_active_water_action_for_install_remove(self) -> None:
        lua = LuaRuntime(unpack_returned_tuples=True)
        power_path = POWER_PATH.as_posix()
        lua.execute(POWER_HARNESS.replace("__POWER_PATH__", power_path))
        extraction_pump_running, last_settlement_time = (
            lua.globals().settleWithoutTimedAction()
        )
        self.assertTrue(extraction_pump_running)
        self.assertEqual(last_settlement_time, 1)

    def test_single_player_refueling_consumes_fraction_of_fluid_container_amount(
        self,
    ) -> None:
        for amount in (3.0, 9.25):
            with self.subTest(amount=amount):
                transferred, _, begins, finishes, events = self.lua.globals().fuelCompleteSp(
                    amount
                )
                self.assertAlmostEqual(transferred, amount)
                self.assertEqual(begins, 1)
                self.assertEqual(finishes, 1)
                self.assertEqual(events, 0)

    def test_single_player_refueling_cancel_settles_only_completed_fraction(self) -> None:
        transferred, _, begins, finishes, events = self.lua.globals().fuelCancelSp(
            8.0
        )
        self.assertAlmostEqual(transferred, 8.0 * 0.45)
        self.assertEqual(begins, 1)
        self.assertEqual(finishes, 1)
        self.assertEqual(events, 0)

    def test_multiplayer_refueling_keeps_server_event_progression(self) -> None:
        transferred, _, begins, finishes, events = self.lua.globals().fuelCompleteMp(
            6.0
        )
        self.assertAlmostEqual(transferred, 6.0)
        self.assertEqual(begins, 1)
        self.assertEqual(finishes, 1)
        self.assertEqual(events, 1)

    def test_single_player_water_transfer_ticks_and_finishes_when_cancelled(self) -> None:
        begins, progress_calls, finishes, events, ended = (
            self.lua.globals().waterCancelSp()
        )
        self.assertEqual(begins, 1)
        self.assertEqual(progress_calls, 2)
        self.assertEqual(finishes, 1)
        self.assertEqual(events, 0)
        self.assertTrue(ended)

    def test_single_player_water_transfer_finishes_on_completion(self) -> None:
        begins, progress_calls, finishes, events = self.lua.globals().waterCompleteSp()
        self.assertEqual(begins, 1)
        self.assertEqual(progress_calls, 1)
        self.assertEqual(finishes, 1)
        self.assertEqual(events, 0)

    def test_single_player_container_water_transfer_finishes_on_completion(
        self,
    ) -> None:
        begins, progress_calls, finishes, events = (
            self.lua.globals().waterContainerCompleteSp()
        )
        self.assertEqual(begins, 1)
        self.assertEqual(progress_calls, 1)
        self.assertEqual(finishes, 1)
        self.assertEqual(events, 0)

    def test_multiplayer_water_transfer_keeps_server_event_progression(self) -> None:
        begins, progress_calls, finishes, events = self.lua.globals().waterCompleteMp()
        self.assertEqual(begins, 1)
        self.assertEqual(progress_calls, 2)
        self.assertEqual(finishes, 1)
        self.assertEqual(events, 1)

    def test_install_remove_actions_commit_only_on_completion_in_sp_and_mp(self) -> None:
        for mode in ("sp", "mp"):
            for operation in ("roof-install", "roof-remove"):
                with self.subTest(mode=mode, operation=operation):
                    fuel_begins, water_begins, performs, events, fuel_finishes, water_finishes = (
                        self.lua.globals().componentComplete(mode, operation)
                    )
                    self.assertEqual(fuel_begins, 0)
                    self.assertEqual(water_begins, 0)
                    self.assertEqual(performs, 1)
                    self.assertEqual(events, 0)
                    self.assertEqual(fuel_finishes, 0)
                    self.assertEqual(water_finishes, 0)

    def test_install_remove_actions_do_not_commit_when_cancelled_in_sp_or_mp(
        self,
    ) -> None:
        for mode in ("sp", "mp"):
            for operation in ("roof-install", "roof-remove"):
                with self.subTest(mode=mode, operation=operation):
                    fuel_begins, water_begins, performs, events, fuel_finishes, water_finishes = (
                        self.lua.globals().componentCancel(mode, operation)
                    )
                    self.assertEqual(fuel_begins, 0)
                    self.assertEqual(water_begins, 0)
                    self.assertEqual(performs, 0)
                    self.assertEqual(events, 0)
                    self.assertEqual(fuel_finishes, 0)
                    self.assertEqual(water_finishes, 0)


if __name__ == "__main__":
    unittest.main()
