"""Offline behavior checks for RV power-component recipes."""

from __future__ import annotations

from pathlib import Path
import unittest

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[2]
MOD_ROOT = ROOT / "RailroaderRV" / "contents" / "mods" / "RailroaderRV" / "42"
LUA_ROOT = MOD_ROOT / "media/lua"


RECIPE_HARNESS = r"""
package.path = [[__SHARED__/?.lua;]] .. package.path
Perks = { Electricity = {} }
Recipe = { OnTest = {}, OnCreate = {} }
ZombRandFloat = function(minimum, maximum) return maximum end

local P = require("RailroaderRV/Power/RV_UtilityPowerConfig")
require("RailroaderRV/Power/RV_UtilityItems")

local function moveable(sprite)
    return {
        getScriptItem = function()
            return { getFullName = function() return "Base.Moveable" end }
        end,
        getType = function() return sprite end,
    }
end

local writtenConditions = {}
local currentComponent
local created = {
    setCondition = function(_, condition)
        writtenConditions[currentComponent] = condition
    end,
}
local craftRecipeData = {
    getAllCreatedItems = function()
        return { get = function(_, index)
            assert(index == 0)
            return created
        end }
    end,
}
local player = { level = 10 }
function player:getPerkLevel(perk)
    assert(perk == Perks.Electricity)
    return self.level
end
currentComponent = "charger"
Recipe.OnCreate.RVUtilityCharger(craftRecipeData, player)
currentComponent = "inverterLevel3"
player.level = 3
Recipe.OnCreate.RVUtilityInverter(craftRecipeData, player)
currentComponent = "inverterLevel5"
player.level = 5
Recipe.OnCreate.RVUtilityInverter(craftRecipeData, player)
currentComponent = "inverterLevel10"
player.level = 10
Recipe.OnCreate.RVUtilityInverter(craftRecipeData, player)
local computerSpritesAccepted = {}
for index, sprite in ipairs({
    "appliances_com_01_72", "appliances_com_01_73",
    "appliances_com_01_74", "appliances_com_01_75",
}) do
    computerSpritesAccepted[index] = Recipe.OnTest.AssembleRVSmartPowerController(
        moveable(sprite))
end

return {
    craftEfficiency = P.craftEfficiency(10, 0.05),
    lightPowerW = P.DEVICE_POWER_W.Light,
    chargerCondition = writtenConditions.charger,
    inverterConditionAtElectrical3 = writtenConditions.inverterLevel3,
    inverterConditionAtElectrical5 = writtenConditions.inverterLevel5,
    inverterConditionAtElectrical10 = writtenConditions.inverterLevel10,
    chargerEfficiencyAtConditionMax = P.chargerEfficiency(100, 100),
    chargerEfficiencyBelowCap = P.chargerEfficiency(97, 100),
    computerSpritesAccepted = computerSpritesAccepted,
    otherMoveableRejected = not Recipe.OnTest.AssembleRVSmartPowerController(
        moveable("appliances_com_01_76")),
}
"""


class PowerRecipeChecks(unittest.TestCase):
    def setUp(self) -> None:
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        shared_root = str(LUA_ROOT / "shared").replace("\\", "/")
        self.result = self.lua.execute(
            RECIPE_HARNESS.replace("__SHARED__", shared_root)
        )

    def test_light_power_is_30_watts(self) -> None:
        self.assertEqual(self.result.lightPowerW, 30)

    def test_component_recipe_generation_uses_creator_skill_and_98_percent_cap(self) -> None:
        self.assertEqual(self.result.craftEfficiency, 0.98)
        self.assertEqual(self.result.chargerCondition, 98)
        self.assertEqual(self.result.inverterConditionAtElectrical3, 86)
        self.assertEqual(self.result.inverterConditionAtElectrical5, 90)
        self.assertEqual(self.result.inverterConditionAtElectrical10, 98)
        self.assertEqual(self.result.chargerEfficiencyAtConditionMax, 0.98)
        self.assertEqual(self.result.chargerEfficiencyBelowCap, 0.97)

    def test_smart_controller_accepts_all_desktop_computer_orientations(self) -> None:
        orientations = self.result.computerSpritesAccepted
        self.assertEqual([orientations[index] for index in range(1, 5)], [True] * 4)
        self.assertTrue(self.result.otherMoveableRejected)

    def test_server_and_inventory_display_use_shared_charger_efficiency(self) -> None:
        server = (
            LUA_ROOT / "server/RailroaderRV/Power/RV_UtilityPower.lua"
        ).read_text(encoding="utf-8")
        dashboard = (
            LUA_ROOT / "client/RailroaderRV/GUI/RV_UtilityDashboard.lua"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "P.chargerEfficiency(power.charger.condition,",
            server,
        )
        self.assertIn(
            "P.chargerEfficiency(item:getCondition(), item:getConditionMax())",
            dashboard,
        )


if __name__ == "__main__":
    unittest.main()
