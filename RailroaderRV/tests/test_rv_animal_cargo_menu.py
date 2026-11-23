from pathlib import Path
import unittest

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MEDIA_LUA = ROOT / "contents/mods/RailroaderRV/42/media/lua"


class RVAnimalCargoMenuTests(unittest.TestCase):
    def test_world_menu_ignores_objects_without_animal_methods(self) -> None:
        source = (
            MEDIA_LUA
            / "client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua"
        ).read_text(encoding="utf-8")

        def section(start: str, end: str) -> str:
            first = source.index(start)
            return source[first : source.index(end, first)]

        snippets = "\n".join(
            [
                section("local function clickedUnit(", "local function optionAlreadyExists"),
                section("local function optionAlreadyExists(", "local function markTest"),
                section("local function addUnitOptions(", "local function addNearbyUnitOptions"),
                section("local function addNearbyUnitOptions(", "local function recordContainsAnimalPosition"),
                section("local function clickedTrainAnimal(", "local function requestAnimalCargo"),
            ]
        )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            r"""
            local decorationOwners = {}
            FlatcarVisualClient = {
                unitIdForDecoration = function(animal)
                    return decorationOwners[animal]
                end,
                isFlatcar = function() return false end,
                isBoundRV = function() return false end,
            }
            local units = {
                [7] = { id = 7, z = 0, kind = "loco",
                    isLocomotive = true },
            }
            Units = { find = function(id) return units[tonumber(id)] end }
            ISWorldObjectContextMenu = { fetchVars = { clickedAnimals = {} } }
            local player = {}
            local function localPlayer() return player end
            local function text(_, fallback) return fallback end
            local function finiteInteger(value)
                if type(value) == "number" and value % 1 == 0 then return value end
            end
            local function getTexture(path) return path end
            requestEnter = function() end
            Menu = { hasUtilityDashboardCandidate = function() return false end }
            function nearestUnitInReach() return units[7] end
            function unitInReach() return true end
            local function makeContext()
                local context = { options = {} }
                function context:addOption(name)
                    local option = { name = name }
                    table.insert(self.options, option)
                    return option
                end
                return context
            end
            """
            + snippets
            + r"""
            function player.getZ() return 0 end
            local plainObject = {}
            local found, isRailroaderTarget = clickedTrainAnimal(
                player, { plainObject })
            assert(found == nil and isRailroaderTarget == false,
                "ordinary world object was treated as a train animal")
            local ordinaryContext = makeContext()
            addNearbyUnitOptions(0, ordinaryContext, false, found,
                isRailroaderTarget)
            assert(ordinaryContext.options[1].name == "Enter RV",
                "ordinary world object did not retain nearby RV entry")

            local rrAnimal = {
                getAnimalID = function() return 7 end,
                getAnimalType = function() return "rr_loco" end,
                getModData = function() return {} end,
            }
            found, isRailroaderTarget = clickedTrainAnimal(
                player, { plainObject, rrAnimal })
            assert(found == rrAnimal and isRailroaderTarget == true,
                "ordinary world object hid a later clicked RR unit")
            local rrContext = makeContext()
            addNearbyUnitOptions(0, rrContext, false, found,
                isRailroaderTarget)
            assert(rrContext.options[1].name == "Enter RV",
                "resolved clicked RR unit did not receive RV entry")

            local decoration = {}
            decorationOwners[decoration] = 7
            found, isRailroaderTarget = clickedTrainAnimal(
                player, { decoration })
            assert(found == decoration and isRailroaderTarget == true,
                "decoration lookup required animal methods")
            local decorationContext = makeContext()
            addNearbyUnitOptions(0, decorationContext, false, found,
                isRailroaderTarget)
            assert(decorationContext.options[1].name == "Enter RV",
                "mapped decoration did not receive RV entry")

            local unresolvedRRAnimal = {
                getAnimalID = function() return 99 end,
                getAnimalType = function() return "rr_loco" end,
                getModData = function() return {} end,
            }
            found, isRailroaderTarget = clickedTrainAnimal(
                player, { unresolvedRRAnimal })
            assert(found == nil and isRailroaderTarget == true,
                "unresolved RR target fell through to another unit")
            local unresolvedContext = makeContext()
            addNearbyUnitOptions(0, unresolvedContext, false, found,
                isRailroaderTarget)
            assert(#unresolvedContext.options == 0,
                "unresolved RR target used a nearby different vehicle")

            found, isRailroaderTarget = clickedTrainAnimal(
                player, { unresolvedRRAnimal, rrAnimal })
            assert(found == rrAnimal and isRailroaderTarget == true,
                "unresolved RR target hid a later valid RR target")
            local laterValidContext = makeContext()
            addNearbyUnitOptions(0, laterValidContext, false, found,
                isRailroaderTarget)
            assert(laterValidContext.options[1].name == "Enter RV",
                "later valid RR target did not receive RV entry")

            ISWorldObjectContextMenu.fetchVars.clickedAnimals = {
                unresolvedRRAnimal,
            }
            found, isRailroaderTarget = clickedTrainAnimal(player, { rrAnimal })
            assert(found == rrAnimal and isRailroaderTarget == true,
                "unresolved clicked animal hid a valid world object target")
            ISWorldObjectContextMenu.fetchVars.clickedAnimals = {}
            """
        )

    def test_inside_menu_resolves_vehicle_from_player_region(self) -> None:
        source = (
            MEDIA_LUA
            / "client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua"
        ).read_text(encoding="utf-8")
        start = source.index("local function recordContainsAnimalPosition(")
        end = source.index("local function nearbyAnimals", start)
        function_source = source[start:end]
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            r"""
            C = { RV_IDENTITY_MIN_Z = -32, RV_IDENTITY_MAX_Z = 32 }
            ModData = { get = function()
                return { locomotives = {
                    ["101"] = { locoId = "101", slotIndex = 1 },
                    ["202"] = { locoId = "202", slotIndex = 2 },
                } }
            end }
            RegionSlots = { indexToRegion = function(index)
                if index == 1 then
                    return { minX = 0, maxX = 100, minY = 0, maxY = 100 }
                end
                return { minX = 100, maxX = 200, minY = 0, maxY = 100 }
            end }
            Units = { find = function(id) return { id = tostring(id),
                kind = "loco", isLocomotive = true } end }
            FlatcarVisualClient = { isFlatcar = function() return false end }
            Menu = { getUtilityMapping = function()
                return { locoId = "wrong-player-vehicle" }
            end }
            function playerPosition() return { x = 0, y = 0, z = 0 } end
            function unitInReach() return true end
            function clickedRailroaderUnit() return nil end
            """
            + function_source
            + r"""
            local firstPlayer = { getX = function() return 20 end,
                getY = function() return 20 end, getZ = function() return 0 end }
            local secondPlayer = { getX = function() return 120 end,
                getY = function() return 20 end, getZ = function() return 0 end }
            assert(animalCargoUnit(firstPlayer, true, nil).id == "101")
            assert(animalCargoUnit(secondPlayer, true, nil).id == "202")
            """
        )

    def test_world_menu_entry_is_independent_from_cargo_target(self) -> None:
        source = (
            MEDIA_LUA
            / "client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua"
        ).read_text(encoding="utf-8")
        animal_cargo_source = (
            MEDIA_LUA
            / "shared/RailroaderRV/Animals/RV_AnimalCargo.lua"
        ).read_text(encoding="utf-8")

        def section(start: str, end: str) -> str:
            first = source.index(start)
            return source[first : source.index(end, first)]

        snippets = "\n".join(
            [
                section("local function clickedUnit(", "local function optionAlreadyExists"),
                section("local function addNearbyUnitOptions(", "local function recordContainsAnimalPosition"),
                section("local function recordContainsAnimalPosition(", "local function requestAnimalCargo"),
                section("local function addAnimalCargoOptions(", "local CURRENT_SQUARE_REFRESH_TICKS"),
                section("function Menu.OnFillWorldObjectContextMenu(", "function Menu.OnClickedAnimalForContext("),
                section("function Menu.OnClickedAnimalForContext(", "-- The vanilla world-menu pipeline"),
                section("function Menu.OnPreFillWorldObjectContextMenu(", "function Menu.OnFillInventoryObjectContextMenu"),
            ]
        )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            r"""
            C = { RV_MAP_KEY = "map", RV_IDENTITY_MIN_Z = -32,
                RV_IDENTITY_MAX_Z = 32, RV_MOUNT_REACH = 5,
                MOD_ID = "RailroaderRV", COMMAND_RV_ANIMAL_CARGO = "animal" }
            local players = {}
            local positions = { [0] = { x = 10, y = 10, z = 0 },
                [1] = { x = 30, y = 10, z = 0 } }
            local map = { locomotives = {}, animalsByUnit = {
                ["101"] = { { id = 1, data = { customName = "cargo-101" } } },
                ["202"] = { { id = 2, data = { customName = "cargo-202" } } },
            } }
            local units = {
                [101] = { id = 101, kind = "loco", z = 0,
                    isLocomotive = true },
                [202] = { id = 202, kind = "car_bx40", z = 0,
                    isLocomotive = false, locomotiveId = 101 },
            }
            local function localPlayer(playerNum) return players[playerNum] end
            local function mapContainsPlayer() return false end
            local function playerPosition(player)
                return { x = player:getX(), y = player:getY(), z = player:getZ() }
            end
            local function unitInReach() return true end
            function nearestUnitInReach() return units[101] end
            local selectedUnitIds = {}
            local function markTest() return true end
            local function text(_, fallback) return fallback end
            local function optionAlreadyExists(context, label)
                for _, option in ipairs(context.options) do
                    if option.name == label then return true end
                end
                return false
            end
            local function addUnitOptions(_, context, unit)
                if not unit then return false end
                selectedUnitIds[#selectedUnitIds + 1] = unit.id
                context:addOption("Enter RV")
                return true
            end
            ModData = { get = function() return map end }
            RegionSlots = { indexToRegion = function()
                return { minX = -100, maxX = 100, minY = -100, maxY = 100 }
            end }
            Units = { find = function(id) return units[tonumber(id)] end,
                list = function() return { units[101], units[202] } end,
                geometry = function() return { hullDistanceTiles = 1,
                    mountReachTiles = 5 } end }
            FlatcarVisualClient = {
                unitIdForDecoration = function() return nil end,
                isFlatcar = function() return false end,
            }
            isMultiplayer = function() return false end
            RR = { API = { seatOf = function() return nil end,
                riderState = function() return { role = "outside" } end } }
            ISWorldObjectContextMenu = { fetchVars = { clickedAnimals = {} } }
            ISContextMenu = { getNew = function()
                return { options = {}, addOption = function(self, name)
                    local option = { name = name }
                    table.insert(self.options, option)
                    return option
                end }
            end }
            sendClientCommand = function() end
            function makeAnimal(id, name, typeName, flags)
                return { id = id, name = name,
                    getAnimalType = function() return typeName end,
                    getAnimalID = function(self) return self.id end,
                    getModData = function() return flags or {} end,
                    isDead = function() return false end,
                    getHealth = function() return 100 end,
                    getData = function() return {
                        getAttachedPlayer = function() return nil end,
                        getAttachedTree = function() return nil end,
                    } end,
                    isOnHook = function() return false end,
                    getVehicle = function() return nil end,
                    getHutch = function() return nil end,
                    getSquare = function() return {} end,
                    isExistInTheWorld = function() return true end,
                    getFullName = function() return name end }
            end
            local function makePlayer(x)
                local nearby = {
                    makeAnimal("near-" .. x, "near " .. x, "cow"),
                    makeAnimal(400 + x, "RR bogie", "rr_truck"),
                    makeAnimal(500 + x, "RR coupler", "rr_lcoupler"),
                    makeAnimal(450 + x, "RR collider", "rr_collider"),
                    makeAnimal(600 + x, "RR car body", "rr_car_bx40"),
                    makeAnimal(610 + x, "RR car bogie", "rr_car_bx40_truck"),
                    makeAnimal(620 + x, "RR car coupler", "rr_car_bx40_coupler"),
                    makeAnimal(630 + x, "RR locomotive frame", "rr_lframe"),
                    makeAnimal(700 + x, "RR locomotive fallback", "cow",
                        { rrLoco = true }),
                    makeAnimal(800 + x, "RR wall", "cow", { rrWall = true }),
                }
                local square = { getX = function() return x end,
                    getY = function() return 10 end,
                    getZ = function() return 0 end,
                    getAnimals = function()
                    return { size = function() return #nearby end,
                        get = function(_, index) return nearby[index + 1] end }
                end }
                return { getX = function() return x end,
                    getY = function() return 10 end,
                    getZ = function() return 0 end,
                    isDead = function() return false end,
                    isSeatedInVehicle = function() return false end,
                    getCell = function() return { getGridSquare = function(_, sx, sy, sz)
                        if sx == x and sy == 10 and sz == 0 then return square end
                    end } end }
            end
            players[0], players[1] = makePlayer(10), makePlayer(30)
            local function makeContext()
                local context = { options = {} }
                function context:addOption(name)
                    local option = { name = name }
                    table.insert(self.options, option)
                    return option
                end
                function context:addSubMenu(option, submenu)
                    option.submenu = submenu
                end
                return context
            end
            Menu = { _rvCarMenuStates = {} }
            """
            + "AnimalCargo = (function()\n"
            + animal_cargo_source
            + "\nend)()\n"
            + snippets
            + r"""
            local clicked101 = makeAnimal(101, "RR 101", "rr_loco")
            local clicked202 = makeAnimal(202, "RR 202", "rr_car_bx40")
            local menu101 = makeContext()
            ISWorldObjectContextMenu.fetchVars.clickedAnimals = { clicked101 }
            Menu.OnPreFillWorldObjectContextMenu(0, menu101, { clicked101 }, false)
            local menu202 = makeContext()
            ISWorldObjectContextMenu.fetchVars.clickedAnimals = { clicked202 }
            Menu.OnFillWorldObjectContextMenu(1, menu202, { clicked202 }, false)

            assert(menu101.options[1].name == "Enter RV",
                "pre-fill did not add the nearest RV entry first")
            assert(menu202.options[1].name == "Enter RV",
                "fill did not add the nearest RV entry before cargo parsing")
            assert(selectedUnitIds[1] == 101 and selectedUnitIds[2] == 101,
                "world-menu entry depended on the clicked animal target")
            assert(menu101.options[2].name == "Load animal",
                "menu101 load entry missing")
            assert(menu101.options[3].name == "Unload animal",
                "menu101 unload entry missing")
            assert(menu101.options[3].submenu.options[1].name == "cargo-101",
                "menu101 used another vehicle's cargo rows")
            assert(menu202.options[3].submenu.options[1].name == "cargo-202",
                "menu202 used another vehicle's cargo rows")
            assert(menu101.options[2].submenu.options[1].name == "near 10"
                and menu101.options[2].submenu.options[2] == nil,
                "RR bogies, couplers, or car bodies appeared as cargo animals")
            assert(menu202.options[2].submenu.options[1].name == "near 30"
                and menu202.options[2].submenu.options[2] == nil,
                "car-body cargo destination did not retain ordinary livestock")

            local eventMenu = makeContext()
            Menu.OnClickedAnimalForContext(0, eventMenu, { clicked101 }, false)
            assert(eventMenu.options[1].name == "Enter RV"
                and eventMenu.options[3].submenu.options[1].name == "cargo-101",
                "direct animal click omitted the clicked vehicle cargo menu")

            local invalidTarget = makeAnimal(303, "RR coupler", "rr_lcoupler")
            local invalidMenu = makeContext()
            ISWorldObjectContextMenu.fetchVars.clickedAnimals = { invalidTarget }
            Menu.OnPreFillWorldObjectContextMenu(0, invalidMenu,
                { invalidTarget }, false)
            assert(invalidMenu.options[1].name == "Enter RV"
                and #invalidMenu.options == 1,
                "unbound RR decoration hid or replaced the nearest RV entry")
            local invalidEventMenu = makeContext()
            Menu.OnClickedAnimalForContext(0, invalidEventMenu,
                { invalidTarget }, false)
            assert(#invalidEventMenu.options == 0,
                "unknown RR animal click fell through to a nearby vehicle")

            ISWorldObjectContextMenu.fetchVars.clickedAnimals = {}
            local nearbyMenu = makeContext()
            Menu.OnPreFillWorldObjectContextMenu(0, nearbyMenu, {}, false)
            assert(nearbyMenu.options[1].name == "Enter RV"
                and nearbyMenu.options[2].name == "Load animal",
                "nearby menu disappeared when no RR vehicle was clicked")

            ISWorldObjectContextMenu.fetchVars.clickedAnimals = {}
            local malformedObject = { getAnimalType = function()
                error("animal classification failed")
            end }
            local exceptionMenu = makeContext()
            local ok = pcall(Menu.OnFillWorldObjectContextMenu, 0,
                exceptionMenu, { malformedObject }, false)
            assert(not ok and exceptionMenu.options[1].name == "Enter RV",
                "cargo target parsing failure ran before the nearest RV entry")
            """
        )

    def test_empty_cargo_rows_are_retained(self) -> None:
        entry_exit = (
            MEDIA_LUA
            / "server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua"
        ).read_text(encoding="utf-8")
        animal_cargo = (
            MEDIA_LUA
            / "server/RailroaderRV/RVMapping/RV_AnimalCargoServer.lua"
        ).read_text(encoding="utf-8")
        self.assertIn("map.animalsByUnit[locoId] = map.animalsByUnit[locoId] or {}", entry_exit)
        self.assertNotIn("map.animalsByUnit[unitKey] = nil", animal_cargo)
        self.assertNotIn("map.animalsByUnit[tostring(unitId)] = nil", animal_cargo)

        commit_start = entry_exit.index("local function commitGeneration(")
        commit_end = entry_exit.index("local function validateGeneration(", commit_start)
        commit = entry_exit[commit_start:commit_end]
        published = commit.index("map.locomotives, map.players = candidateMap.locomotives")
        empty_rows = commit.index("map.animalsByUnit[locoId] = map.animalsByUnit[locoId] or {}")
        transmitted = commit.index("ModData.transmit(C.RV_MAP_KEY)")
        self.assertLess(published, empty_rows)
        self.assertLess(empty_rows, transmitted)
        self.assertLess(commit.index("if utilityAccepted ~= true then"), published)


if __name__ == "__main__":
    unittest.main()
