from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MEDIA_LUA = ROOT / "contents/mods/RailroaderRV/42/media/lua"


class CapturedObjectStateTests(unittest.TestCase):
    def test_bx40_garage_panels_build_as_destructible_wall_objects(self) -> None:
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().mediaLuaRoot = MEDIA_LUA.as_posix()
        lua.execute(
            "package.path = mediaLuaRoot .. '/server/?.lua;' "
            ".. mediaLuaRoot .. '/shared/?.lua;' .. package.path"
        )
        lua.execute(
            r'''
            IsoDirections = { N = "north" }
            instanceof = function(object, className)
                return type(object) == "table" and object.class == className
            end

            local function addObjectMethods(object)
                function object:setName(value) self.name = value end
                function object:getName() return self.name end
                function object:setDir(value) self.direction = value end
                function object:getDir() return self.direction end
                function object:getNorth() return self.north end
                function object:setMaxHealth(value) self.maxHealth = value end
                function object:getMaxHealth() return self.maxHealth end
                function object:setHealth(value) self.health = value end
                function object:getHealth() return self.health end
                function object:setIsHoppable(value) self.hoppable = value end
                function object:isHoppable() return self.hoppable end
                function object:setCanPassThrough(value)
                    self.canPassThrough = value
                end
                function object:isCanPassThrough()
                    return self.canPassThrough
                end
                function object:setBlockAllTheSquare(value)
                    self.blockAllTheSquare = value
                end
                function object:isBlockAllTheSquare()
                    return self.blockAllTheSquare
                end
                function object:setIsThumpable(value)
                    self.thumpable = value
                end
                function object:isThumpable() return self.thumpable end
                function object:isDoor() return self.door end
                function object:getObjectIndex() return self.objectIndex end
                function object:transmitCompleteItemToClients()
                    self.transmitted = true
                end
                return object
            end

            IsoThumpable = {}
            function IsoThumpable.new(cell, square, sprite, north)
                return addObjectMethods({
                    class = "IsoThumpable", sprite = sprite, north = north,
                    door = false, thumpable = false, hoppable = true,
                    canPassThrough = true, blockAllTheSquare = false,
                    health = 1, maxHealth = 1, objectIndex = -1,
                })
            end

            IsoDoor = {}
            function IsoDoor.new(cell, square, sprite, north)
                return addObjectMethods({
                    class = "IsoDoor", sprite = sprite, north = north,
                    door = true, objectIndex = -1,
                })
            end

            local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"
            local carBox = RoomTemplate.get(RoomTemplate.CAR_BOX_TEMPLATE_ID)
            local garageSprites = {
                walls_garage_02_0 = true,
                walls_garage_02_1 = true,
                walls_garage_02_2 = true,
            }
            local expectedGarageSlots = {
                ["-3:-2"] = "walls_garage_02_2",
                ["3:-2"] = "walls_garage_02_2",
                ["-3:-1"] = "walls_garage_02_1",
                ["3:-1"] = "walls_garage_02_1",
                ["-3:0"] = "walls_garage_02_1",
                ["3:0"] = "walls_garage_02_1",
                ["-3:1"] = "walls_garage_02_0",
                ["3:1"] = "walls_garage_02_0",
            }
            assert(carBox.metadata.objectCount == 329
                and #carBox.objects == 329)
            assert(#carBox.misc.buildCells == 120
                and #carBox.roofCells == 120
                and #carBox.waterProxies == 14)
            local garageEntries = {}
            for index = 1, #carBox.objects do
                local entry = carBox.objects[index]
                if garageSprites[entry.sprite] then
                    local slot = tostring(entry.x) .. ":" .. tostring(entry.y)
                    assert(expectedGarageSlots[slot] == entry.sprite)
                    assert(entry.class == "IsoThumpable")
                    assert(entry.name == "Thumpable")
                    assert(entry.north == false and entry.direction == "N")
                    assert(entry.state.hoppable == false)
                    assert(entry.state.canPassThrough == false)
                    assert(entry.state.blockAllTheSquare == false)
                    assert(entry.state.health == 500
                        and entry.state.maxHealth == 500)
                    assert(entry.state.open == nil and entry.state.locked == nil)
                    assert(entry.protected == false)
                    garageEntries[#garageEntries + 1] = entry
                end
            end
            assert(#garageEntries == 8)

            local ServerUtil = require "RailroaderRV/Common/RV_ServerUtil"
            local ServerWorld = {
                getSpriteName = function(object) return object.sprite end,
                recalcSquare = function() end,
            }
            local ctx = {
                OWNER = "test-owner",
                Constants = {},
                ServerUtil = ServerUtil,
                ServerWorld = ServerWorld,
            }
            require "RailroaderRV/Construction/RV_Server_WorldObjects"(ctx)

            local builtGaragePanels = {}
            for index = 1, #garageEntries do
                local square = { objects = {} }
                function square:AddSpecialObject(object)
                    self.objects[#self.objects + 1] = object
                    object.objectIndex = #self.objects - 1
                end
                local entry = garageEntries[index]
                local built = ctx.createCapturedTemplateObject({}, square,
                    entry, 1, nil, nil, nil)
                assert(square.objects[1] == built and built.transmitted)
                assert(built.class == "IsoThumpable" and not built:isDoor())
                assert(built:isThumpable())
                assert(not built:isHoppable())
                assert(not built:isCanPassThrough())
                assert(not built:isBlockAllTheSquare())
                assert(built.name == "Thumpable")
                assert(built.sprite == entry.sprite and built.north == false)
                assert(built.health == 500 and built.maxHealth == 500)
                builtGaragePanels[index] = built
            end

            local base = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
            local regularDoorEntry
            for index = 1, #base.objects do
                if base.objects[index].class == "IsoDoor" then
                    regularDoorEntry = base.objects[index]
                    break
                end
            end
            assert(regularDoorEntry and regularDoorEntry.class == "IsoDoor")
            local doorSquare = { objects = {} }
            function doorSquare:AddSpecialObject(object)
                self.objects[#self.objects + 1] = object
                object.objectIndex = #self.objects - 1
            end
            local builtRegularDoor = ctx.createCapturedTemplateObject({},
                doorSquare, regularDoorEntry, 1, nil, nil, nil)
            assert(doorSquare.objects[1] == builtRegularDoor)
            assert(builtRegularDoor.class == "IsoDoor" and builtRegularDoor:isDoor())
            assert(builtRegularDoor.transmitted)

            result = {
                garageCount = #builtGaragePanels,
                regularDoorClass = builtRegularDoor.class,
                regularDoorName = builtRegularDoor.name,
            }
            '''
        )

        result = lua.globals().result
        self.assertEqual(result["garageCount"], 8)
        self.assertEqual(result["regularDoorClass"], "IsoDoor")
        self.assertEqual(result["regularDoorName"], "Wooden Door")


if __name__ == "__main__":
    unittest.main()
