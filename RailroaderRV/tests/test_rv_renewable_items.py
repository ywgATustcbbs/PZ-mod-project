"""Offline behavior checks for renewable item container loot."""

from __future__ import annotations

from pathlib import Path
import unittest

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[2]
MOD_ROOT = ROOT / "RailroaderRV" / "contents" / "mods" / "RailroaderRV" / "42"
SOLAR_LOOT = (
    MOD_ROOT
    / "media/lua/server/RailroaderRV/Power/RV_SolarPanelLoot.lua"
)


class SolarPanelLootChecks(unittest.TestCase):
    def setUp(self) -> None:
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(
            """
            local listeners = {}
            Events = {
                OnFillContainer = {
                    Add = function(callback)
                        table.insert(listeners, callback)
                    end,
                    Trigger = function(roomName, containerType, itemContainer)
                        for _, callback in ipairs(listeners) do
                            callback(roomName, containerType, itemContainer)
                        end
                    end,
                },
            }
            CLIENT = false
            function isClient() return CLIENT end
            SandboxVars = { RailroaderRV = { SolarPanelLootChance = 0 } }
            RANDOM_CALLS = 0
            function setRandomValues(...)
                RANDOM_VALUES = { ... }
                RANDOM_CALLS = 0
            end
            function ZombRand(limit)
                assert(limit == 100)
                RANDOM_CALLS = RANDOM_CALLS + 1
                return RANDOM_VALUES[RANDOM_CALLS]
            end
            function newContainer()
                local container = { added = {} }
                function container:AddItem(itemType)
                    table.insert(self.added, itemType)
                end
                return container
            end
            function addedCount(container) return #container.added end
            function addedItem(container, index) return container.added[index] end
            """
        )
        self.lua.execute(SOLAR_LOOT.read_text(encoding="utf-8"))

    def set_chance(self, value: int) -> None:
        self.lua.globals().SandboxVars.RailroaderRV.SolarPanelLootChance = value

    def set_random_values(self, *values: int) -> None:
        self.lua.globals().setRandomValues(*values)

    def fill(self, room: str, container_type: str, container: object) -> None:
        self.lua.globals().Events.OnFillContainer.Trigger(
            room, container_type, container
        )

    def test_zero_chance_rolls_every_fill_without_adding_panels(self) -> None:
        self.set_chance(0)
        self.set_random_values(0, 50, 99)
        container = self.lua.globals().newContainer()

        for _ in range(3):
            self.fill("garagestorage", "counter", container)

        self.assertEqual(self.lua.globals().RANDOM_CALLS, 3)
        self.assertEqual(self.lua.globals().addedCount(container), 0)

    def test_full_chance_adds_a_panel_on_each_repeated_fill(self) -> None:
        self.set_chance(100)
        self.set_random_values(0, 50, 99)
        container = self.lua.globals().newContainer()

        for _ in range(3):
            self.fill("warehouse", "crate", container)

        self.assertEqual(self.lua.globals().RANDOM_CALLS, 3)
        self.assertEqual(self.lua.globals().addedCount(container), 3)
        for index in range(1, 4):
            self.assertEqual(
                self.lua.globals().addedItem(container, index),
                "RailroaderRV.SolarPanel",
            )

    def test_targets_and_container_exclusions_are_preserved(self) -> None:
        self.set_chance(100)
        self.set_random_values(99, 99, 99, 99, 99, 99, 99, 99, 99)
        container = self.lua.globals().newContainer()

        for room in (
            "garagestorage",
            "storageunit",
            "armystorage",
            "oldarmy",
            "armytent",
            "warehouse",
        ):
            self.fill(room, "counter", container)
        self.fill("livingroom", "counter", container)
        for container_type in ("fridge", "freezer", "bin"):
            self.fill("warehouse", container_type, container)

        self.assertEqual(self.lua.globals().RANDOM_CALLS, 6)
        self.assertEqual(self.lua.globals().addedCount(container), 6)

    def test_client_event_does_not_roll_or_add_items(self) -> None:
        self.set_chance(100)
        self.set_random_values(99)
        self.lua.globals().CLIENT = True
        container = self.lua.globals().newContainer()

        self.fill("garagestorage", "counter", container)

        self.assertEqual(self.lua.globals().RANDOM_CALLS, 0)
        self.assertEqual(self.lua.globals().addedCount(container), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
