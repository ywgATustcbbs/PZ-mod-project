"""Execute the production renewable formulas with Lupa; no source mirrors."""

from __future__ import annotations

from pathlib import Path
import unittest

try:
    from lupa import LuaRuntime
except ImportError as exc:  # fail loudly: formula coverage must never skip
    raise RuntimeError(
        "Offline Lua checks require Lupa. Install it with "
        "`python -m pip install lupa`."
    ) from exc


ROOT = Path(__file__).resolve().parents[2]
MOD_ROOT = ROOT / "RailroaderRV" / "contents" / "mods" / "RailroaderRV" / "42"


class RenewableGenerationChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.lua = LuaRuntime(unpack_returned_tuples=True)
        media_lua = str(MOD_ROOT / "media/lua").replace("\\", "/")
        cls.lua.execute(
            f'package.path = "{media_lua}/shared/?.lua;" .. package.path; '
            'RailroaderRV = RailroaderRV or {}; '
            'Generation = require("RailroaderRV/Power/RV_Generation"); '
            'PowerConfig = require("RailroaderRV/Power/RV_UtilityPowerConfig")'
        )
        cls.generation = cls.lua.globals().Generation
        cls.config = cls.lua.globals().PowerConfig

    def test_solar_time_season_weather_and_final_rating_cap(self) -> None:
        solar = self.generation.solarPowerW
        self.assertEqual(solar(0, 7, 0, 0, 0), 0)
        self.assertEqual(solar(6, 7, 0, 0, 0), 0)
        self.assertAlmostEqual(solar(18, 7, 0, 0, 0), 0, places=12)
        self.assertEqual(solar(12, 7, 0, 0, 0), 250)
        self.assertAlmostEqual(solar(12, 1, 0, 0, 0), 120)
        self.assertAlmostEqual(solar(12, 7, 1, 1, 1), 92.4)
        self.assertAlmostEqual(solar(9, 1, 0, 0, 0), solar(15, 1, 0, 0, 0))
        self.assertAlmostEqual(solar(12, 4, 0, 0, 0), 225)
        self.assertAlmostEqual(solar(12, 10, 0, 0, 0), 225)
        # The unsaturated January output keeps each weather coefficient visible.
        self.assertAlmostEqual(solar(12, 1, 0.5, 0, 0), 90)
        self.assertAlmostEqual(solar(12, 1, 1, 0, 0), 60)
        self.assertAlmostEqual(solar(12, 1, 0, 0.5, 0), 102)
        self.assertAlmostEqual(solar(12, 1, 0, 1, 0), 84)
        self.assertAlmostEqual(solar(12, 1, 0, 0, 0.5), 108)
        self.assertAlmostEqual(solar(12, 1, 0, 0, 1), 96)
        # Raw sun intensity is allowed above one; only final output is capped.
        self.assertEqual(solar(12, 7, 0, 0, 0), self.config.GENERATOR_TYPES[
            "RailroaderRV.SolarPanel"].maxPowerW)

    def test_solar_and_wind_outputs_scale_from_power_config_ratings(self) -> None:
        solar_profile = self.config.GENERATOR_TYPES["RailroaderRV.SolarPanel"]
        wind_profile = self.config.GENERATOR_TYPES["RailroaderRV.WindTurbine"]
        original_solar, original_wind = solar_profile.maxPowerW, wind_profile.maxPowerW
        try:
            solar_profile.maxPowerW = 500
            wind_profile.maxPowerW = 500
            self.assertEqual(self.generation.solarPowerW(12, 1, 0, 0, 0), 240)
            self.assertEqual(self.generation.windPowerW(45), 500)
        finally:
            solar_profile.maxPowerW = original_solar
            wind_profile.maxPowerW = original_wind

    def test_wind_cut_in_rated_band_and_cut_out(self) -> None:
        wind = self.generation.windPowerW
        rated = self.config.GENERATOR_TYPES["RailroaderRV.WindTurbine"].maxPowerW
        self.assertEqual(wind(9), 0)
        self.assertEqual(wind(9.999), 0)
        self.assertEqual(wind(10), 0)
        self.assertAlmostEqual(wind(10.001), 400 * (10.001**3 - 10**3) / (45**3 - 10**3))
        self.assertAlmostEqual(wind(20), rated * 7000 / 90125)
        self.assertLess(wind(44.999), rated)
        self.assertEqual(wind(45), rated)
        self.assertEqual(wind(45.001), rated)
        self.assertEqual(wind(89.999), rated)
        self.assertEqual(wind(89), rated)
        self.assertEqual(wind(90), 0)

    def test_current_outputs_read_game_time_and_climate_interfaces(self) -> None:
        self.lua.execute(
            """
            sampled = { hour = 12, month = 6, cloud = 0,
                precipitation = 0, fog = 0, wind = 45 }
            function getGameTime()
                return {
                    getTimeOfDay = function() return sampled.hour end,
                    getMonth = function() return sampled.month end,
                }
            end
            function getClimateManager()
                return {
                    getCloudIntensity = function() return sampled.cloud end,
                    getPrecipitationIntensity = function() return sampled.precipitation end,
                    getFogIntensity = function() return sampled.fog end,
                    getWindspeedKph = function() return sampled.wind end,
                }
            end
            """
        )
        self.assertEqual(self.generation.currentSolarPowerW(), 250)
        self.assertEqual(self.generation.currentWindPowerW(), 400)
        self.lua.execute("sampled.month = 0; sampled.wind = 9")
        self.assertAlmostEqual(self.generation.currentSolarPowerW(), 120)
        self.assertEqual(self.generation.currentWindPowerW(), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
