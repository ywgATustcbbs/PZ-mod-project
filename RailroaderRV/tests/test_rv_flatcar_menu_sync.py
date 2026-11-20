from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "contents/mods/RailroaderRV/42/media/lua"


def lua_function(source: str, signature: str, following: str) -> str:
    start = source.index(signature)
    end = source.index(following, start)
    return source[start:end]


class RVFlatcarMenuSyncTests(unittest.TestCase):
    def test_flatcar_sync_snapshot_bound_only_delta_and_clear(self) -> None:
        source = (MOD / "client/RailroaderRV/GUI/RV_FlatcarVisualClient.lua").read_text(
            encoding="utf-8"
        )
        sync_handler = lua_function(
            source,
            "function Client.onServerCommand(module, command, args)",
            "local function onCreatePlayer",
        )
        flatcar_methods = lua_function(
            source,
            "function Client.isFlatcar(unitId)",
            "function Client.cargoForUnit",
        )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            r"""
            Client = { flatcars = {}, boundRVs = {},
                clearUnloadPreview = function() end }
            CargoNotice = { onServerCommand = function() end }
            Cargo = { debug = function() end }
            C = { MOD_ID = "RailroaderRV", COMMAND_RV_FLATCAR_SYNC = "sync" }
            unloadPreviewHover = nil
            layoutSignatures = {}
            function idKey(id) return id == nil and nil or tostring(id) end
            function cargoLayoutSignature(cars) return #cars end
            function describeCargoLayout() return "test" end
            function syncRecords() end
            """
            + flatcar_methods
            + sync_handler
            + r"""
            Client.onServerCommand("RailroaderRV", "sync", {
                units = { { unitId = "flat-a", cars = {} } },
                boundRVUnitIds = { "bx40-a", "caboose-a" },
            })
            assert(Client.isFlatcar("flat-a"))
            assert(Client.isBoundRV("bx40-a"))
            assert(Client.isBoundRV("caboose-a"))

            -- A bound-only update clears stale bindings and preserves flatcars.
            Client.onServerCommand("RailroaderRV", "sync", {
                boundRVUnitIds = { "bx40-a" },
            })
            assert(Client.isBoundRV("bx40-a"))
            assert(not Client.isBoundRV("caboose-a"))
            assert(Client.isFlatcar("flat-a"))

            -- A flatcar delta preserves the binding snapshot.
            Client.onServerCommand("RailroaderRV", "sync", {
                unitId = "flat-b", cars = {},
            })
            assert(Client.isFlatcar("flat-b"))
            assert(Client.isBoundRV("bx40-a"))

            -- Empty authoritative binding state clears all bound IDs.
            Client.onServerCommand("RailroaderRV", "sync", {
                boundRVUnitIds = {},
            })
            assert(not Client.isBoundRV("bx40-a"))
            assert(Client.isFlatcar("flat-a"))
            """
        )

    def test_mapping_changes_broadcast_authoritative_bound_ids(self) -> None:
        source = (MOD / "server/RailroaderRV/RVMapping/RV_RailroaderServer_Mapping.lua").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'local ClientDispatch = require("RailroaderRV/Core/RV_ServerClientDispatch")',
            source,
        )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().mappingLuaRoot = (MOD / "server").as_posix()
        lua.globals().sharedLuaRoot = (MOD / "shared").as_posix()
        lua.execute(
            r"""
            package.path = mappingLuaRoot .. "/?.lua;" .. sharedLuaRoot
                .. "/?.lua;" .. package.path
            local broadcasts = {}
            package.preload["RailroaderRV/Core/RV_ServerClientDispatch"] =
                function()
                    return { broadcast = function(module, command, args)
                        broadcasts[#broadcasts + 1] = {
                            module = module, command = command, args = args,
                        }
                    end }
                end
            package.preload["RailroaderRV/RVMapping/RV_RegionSlots"] =
                function() return {} end
            package.preload["RailroaderRV/BoundaryGuard/RV_RailroaderServer_BoundaryValidation"] =
                function() return function() return {
                    invalidate = function() end,
                } end end
            local map = { locomotives = {
                ["caboose-2"] = {}, ["boxcar-1"] = {},
            } }
            ModData = { get = function() return map end }
            local epoch = 0
            local adapter = { advanceMappingEpoch = function()
                epoch = epoch + 1
            end }
            local ctx = {
                Boundary = {}, Adapter = adapter,
                C = { MOD_ID = "RailroaderRV",
                    COMMAND_RV_FLATCAR_SYNC = "SyncBX40Flatcar" },
                WORLD_MIN_Z = -32, WORLD_MAX_Z = 32,
                number = function(v) return tonumber(v) end,
                integer = function(v) return math.floor(tonumber(v)) end,
                call = function() return false end,
                playerId = function() end, playerName = function() end,
                findTrain = function() end, trainPosition = function() end,
            }
            local factory = require("RailroaderRV/RVMapping/RV_RailroaderServer_Mapping")
            factory(ctx)
            ctx.markMappingChanged(true)
            assert(epoch == 1)
            assert(#broadcasts == 1)
            local first = broadcasts[1]
            assert(first.module == "RailroaderRV")
            assert(first.command == "SyncBX40Flatcar")
            assert(first.args.boundRVUnitIds[1] == "boxcar-1")
            assert(first.args.boundRVUnitIds[2] == "caboose-2")

            map.locomotives["boxcar-1"] = nil
            ctx.markMappingChanged(false)
            assert(epoch == 2)
            assert(#broadcasts == 2)
            assert(#broadcasts[2].args.boundRVUnitIds == 1)
            assert(broadcasts[2].args.boundRVUnitIds[1] == "caboose-2")
            """
        )

    def test_dashboard_candidate_for_inside_and_nearby_rail_cars(self) -> None:
        source = (MOD / "client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua").read_text(
            encoding="utf-8"
        )
        candidate = lua_function(
            source,
            "function Menu.hasUtilityDashboardCandidate(player, insideOnly, unitIdHint)",
            "local function visibleTrain",
        )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            r"""
            Menu = {
                getUtilityMapping = function()
                    return { locoId = "boxcar-1" }
                end,
            }
            FlatcarVisualClient = {
                isFlatcar = function(id) return tostring(id) == "flatcar-1" end,
                boundRVs = { ["boxcar-1"] = true, ["caboose-2"] = true },
                isBoundRV = function(id)
                    return FlatcarVisualClient.boundRVs[tostring(id)] == true
                end,
            }
            Units = { find = function(id) return { id = id } end }
            function unitInReach() return true end
            insideRV = false
            nearbyUnit = nil
            function mapContainsPlayer() return insideRV end
            function nearestUnitInReach() return nearbyUnit end
            """
            + candidate
            + r"""
            local player = {}
            -- The generated RV interior permits its mapped utility context.
            insideRV = true
            assert(Menu.hasUtilityDashboardCandidate(player, false, "boxcar-1"))
            assert(not Menu.hasUtilityDashboardCandidate(player, false, "flatcar-1"))

            -- Exterior interaction uses the nearby Railroader vehicle ID.
            insideRV = false
            assert(Menu.hasUtilityDashboardCandidate(player, false, "boxcar-1"))
            Menu.getUtilityMapping = function() return { locoId = "caboose-2" } end
            assert(Menu.hasUtilityDashboardCandidate(player, false, "caboose-2"))
            assert(not Menu.hasUtilityDashboardCandidate(player, false, "other-car"))
            assert(not Menu.hasUtilityDashboardCandidate(player, false, "flatcar-1"))

            -- No-hint world interaction resolves the nearest unit, as the
            -- world context menu does for nearby caboose/boxcar access.
            nearbyUnit = { id = "caboose-2" }
            assert(Menu.hasUtilityDashboardCandidate(player, false))
            """
        )

    def test_unit_menu_bound_unbound_and_flatcar_options(self) -> None:
        source = (MOD / "client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua").read_text(
            encoding="utf-8"
        )
        unit_menu = lua_function(
            source,
            "local function addUnitOptions(playerNum, context, unit, test)",
            "local function addNearbyUnitOptions",
        )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            r"""
            C = { RV_LOADING_RAMP_ITEM = "Base.LoadingRamp" }
            FlatcarVisualClient = {
                flatcars = {}, boundRVs = {},
                isFlatcar = function(id)
                    return FlatcarVisualClient.flatcars[tostring(id)] == true
                end,
                isBoundRV = function(id)
                    return FlatcarVisualClient.boundRVs[tostring(id)] == true
                end,
            }
            Menu = {
                hasUtilityDashboardCandidate = function() return true end,
                openDashboard = function() end,
            }
            RailroaderRV = {
                UtilityContextMenu = { openDashboard = function() end },
            }
            function text(key, fallback) return key end
            function requestEnter() end
            function requestFlatcarConversion() end
            function addLoadVehicleSubmenu() end
            function addUnloadVehicleSubmenu() end
            function transportTooltipDescription() return "tooltip" end
            function newMenuOptionToolTip() return {} end
            function getTexture() return {} end
            function optionAlreadyExists() return false end
            function localPlayer()
                return { getInventory = function()
                    return { containsTypeRecurse = function() return false end }
                end }
            end
            function menuContext()
                local context = { options = {}, numOptions = 0 }
                context.addOption = function(self, label, ...)
                    local option = { name = label }
                    self.options[#self.options + 1] = option
                    self.numOptions = #self.options
                    return option
                end
                return context
            end
            function optionNamed(context, name)
                for _, option in ipairs(context.options) do
                    if option.name == name then return option end
                end
                return nil
            end
            """
            + unit_menu
            + r"""
            local playerNum = 0
            local unit = { id = "bx40", kind = "car_bx40",
                isLocomotive = false }
            local context = menuContext()

            -- Bound BX40 retains its RV controls and hides conversion.
            FlatcarVisualClient.boundRVs.bx40 = true
            assert(addUnitOptions(playerNum, context, unit, false))
            assert(optionNamed(context, "ContextMenu_RailroaderRV_EnterCargo"))
            assert(optionNamed(context, "ContextMenu_RailroaderRV_UtilityDashboard"))
            assert(not optionNamed(context, "ContextMenu_RailroaderRV_ConvertToFlatcar"))

            -- Unbound BX40 keeps the conversion option.
            FlatcarVisualClient.boundRVs = {}
            context = menuContext()
            assert(addUnitOptions(playerNum, context, unit, false))
            assert(optionNamed(context, "ContextMenu_RailroaderRV_ConvertToFlatcar"))

            -- A converted flatcar has no enter, dashboard or conversion item.
            FlatcarVisualClient.flatcars.bx40 = true
            context = menuContext()
            assert(addUnitOptions(playerNum, context, unit, false))
            assert(not optionNamed(context, "ContextMenu_RailroaderRV_EnterCargo"))
            assert(not optionNamed(context, "ContextMenu_RailroaderRV_UtilityDashboard"))
            assert(not optionNamed(context, "ContextMenu_RailroaderRV_ConvertToFlatcar"))
            """
        )

    def test_world_menu_uses_exterior_candidate_and_radial_hides_flatcar(self) -> None:
        utility_source = (MOD / "client/RailroaderRV/GUI/RV_UtilityContextMenu.lua").read_text(
            encoding="utf-8"
        )
        dashboard_option = lua_function(
            utility_source,
            "local function addDashboardOption(player, context)",
            "function Menu.onPreFillWorldObjectContextMenu",
        )
        menu_source = (MOD / "client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua").read_text(
            encoding="utf-8"
        )
        radial = lua_function(
            menu_source,
            "local function addRailroaderRadialOptions(train, player, add)",
            "local function addUnitOptions",
        )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            r"""
            local candidateInsideOnly
            RailroaderRV = {
                RailroaderContextMenu = {
                    hasUtilityDashboardCandidate = function(player, insideOnly)
                        candidateInsideOnly = insideOnly
                        return true
                    end,
                },
            }
            Menu = RailroaderRV.RailroaderContextMenu
            function text(key, fallback) return fallback end
            function getTexture(path) return path end
            function already() return false end
            local context = { options = {}, numOptions = 0 }
            context.addOption = function(self, label, ...)
                local option = { name = label }
                self.options[#self.options + 1] = option
                return option
            end
            """
            + dashboard_option
            + r"""
            addDashboardOption({}, context)
            assert(candidateInsideOnly == false)
            assert(#context.options == 1)
            """
        )
        lua.execute(
            r"""
            local options = {}
            FlatcarVisualClient = {
                isFlatcar = function(id) return id == "flat" end,
            }
            function canEnterRV() return true end
            function text(key, fallback) return fallback end
            function MenuHasCandidate() return true end
            Menu = { hasUtilityDashboardCandidate = function() return true end }
            """
            + radial
            + r"""
            addRailroaderRadialOptions({ id = "flat" }, {}, function(...)
                options[#options + 1] = { ... }
            end)
            assert(#options == 0)
            """
        )


if __name__ == "__main__":
    unittest.main()
