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
                function object:setIsDoorFrame(value)
                    self.doorFrame = value
                end
                function object:isDoorFrame() return self.doorFrame end
                function object:setIsLocked(value) self.locked = value end
                function object:isLocked() return self.locked == true end
                function object:isDoor() return self.door end
                function object:setIsDoor(value) self.door = value end
                function object:getOpenSprite() return self.openSprite end
                function object:getObjectIndex() return self.objectIndex end
                function object:transmitCompleteItemToClients()
                    self.transmitted = true
                end
                return object
            end

            IsoThumpable = {}
            function IsoThumpable.new(...)
                local argumentCount = select("#", ...)
                local cell, square, sprite, orientationOrOpen, north, tableArg = ...
                local openSprite
                if type(orientationOrOpen) == "string" then
                    openSprite = { name = orientationOrOpen }
                else
                    north = orientationOrOpen
                end
                return addObjectMethods({
                    class = "IsoThumpable", sprite = sprite, north = north,
                    openSprite = openSprite,
                    constructorArgCount = argumentCount,
                    constructorOpenSprite = openSprite and openSprite.name,
                    constructorNorth = north, constructorTable = tableArg,
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

            getSprite = function(name) return { name = name } end
            IsoWindow = {}
            function IsoWindow.new(cell, square, sprite, north)
                local object = addObjectMethods({
                    class = "IsoWindow", sprite = sprite.name, north = north,
                    door = false, thumpable = false, hoppable = false,
                    canPassThrough = true, blockAllTheSquare = false,
                    health = 50, maxHealth = 50, locked = false,
                    objectIndex = -1,
                })
                return object
            end

            local fireplaceConstructed
            IsoFireplace = {}
            function IsoFireplace.new(cell, square, sprite)
                fireplaceConstructed = { cell = cell, square = square,
                    sprite = sprite }
                local object = addObjectMethods({
                    class = "IsoFireplace", sprite = sprite.name,
                    direction = "north", hoppable = false, fuel = 0,
                    fuelWrites = 0, objectIndex = -1,
                })
                -- B42.21 derives this value from the sprite and has no setter.
                object.setIsHoppable = nil
                function object:isHoppable() return false end
                function object:setFuelAmount(value)
                    self.fuelWrites = self.fuelWrites + 1
                    self.fuel = value
                end
                function object:getFuelAmount() return self.fuel end
                return object
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

            local caboose = RoomTemplate.get(
                RoomTemplate.CAR_CABOOSE_TEMPLATE_ID)
            local doorCount, frameCount, windowCount, fenceCount = 0, 0, 0, 0
            for index = 1, #caboose.objects do
                local entry = caboose.objects[index]
                if entry.name == "Wooden Door" then
                    assert(entry.class == "IsoThumpable" and not entry.protected)
                    assert(entry.openSprite == "location_shop_gas2go_01_63")
                    assert(entry.state.health == 400
                        and entry.state.maxHealth == 400)
                    local square = { objects = {} }
                    function square:AddSpecialObject(object)
                        self.objects[#self.objects + 1] = object
                        object.objectIndex = #self.objects - 1
                    end
                    local built = ctx.createCapturedTemplateObject({}, square,
                        entry, 1, nil, nil, nil)
                    assert(built.class == "IsoThumpable" and built:isThumpable())
                    assert(built:isDoor()
                        and built.openSprite.name == entry.openSprite
                        and built.constructorArgCount == 6
                        and built.constructorOpenSprite == entry.openSprite
                        and built.constructorNorth == true
                        and type(built.constructorTable) == "table")
                    assert(built.health == 400 and built.maxHealth == 400)
                    assert(square.objects[1] == built and built.transmitted)
                    doorCount = doorCount + 1
                elseif entry.name == "Wooden Door Frame" then
                    assert(entry.class == "IsoThumpable" and not entry.protected)
                    local square = { objects = {} }
                    function square:AddSpecialObject(object)
                        self.objects[#self.objects + 1] = object
                        object.objectIndex = #self.objects - 1
                    end
                    local built = ctx.createCapturedTemplateObject({}, square,
                        entry, 1, nil, nil, nil)
                    assert(built:isDoorFrame() and built:isCanPassThrough())
                    assert(not built:isThumpable())
                    assert(built.health == 400 and built.maxHealth == 400)
                    assert(square.objects[1] == built and built.transmitted)
                    frameCount = frameCount + 1
                elseif entry.class == "IsoWindow" then
                    assert(not entry.protected and entry.state.health == 50
                        and entry.state.maxHealth == nil)
                    local square = { objects = {} }
                    function square:AddSpecialObject(object)
                        self.objects[#self.objects + 1] = object
                        object.objectIndex = #self.objects - 1
                    end
                    local built = ctx.createCapturedTemplateObject({}, square,
                        entry, 1, nil, nil, nil)
                    assert(built.class == "IsoWindow" and built.health == 50)
                    assert(square.objects[1] == built and built.transmitted)
                    windowCount = windowCount + 1
                elseif entry.sprite == "fixtures_railings_01_49" then
                    local square = { objects = {} }
                    function square:AddSpecialObject(object)
                        self.objects[#self.objects + 1] = object
                        object.objectIndex = #self.objects - 1
                    end
                    local built = ctx.createCapturedTemplateObject({}, square,
                        entry, 1, nil, nil, nil)
                    assert(built:isHoppable() and not built:isDoor())
                    assert(not built:isBlockAllTheSquare()
                        and built:getNorth() == entry.north)
                    assert(square.objects[1] == built and built.transmitted)
                    fenceCount = fenceCount + 1
                end
            end
            assert(doorCount == 2 and frameCount == 2 and windowCount == 10
                and fenceCount == 12)

            local fireplaceEntry
            for index = 1, #caboose.objects do
                if caboose.objects[index].class == "IsoFireplace" then
                    fireplaceEntry = caboose.objects[index]
                    break
                end
            end
            assert(fireplaceEntry and fireplaceEntry.sprite
                == "appliances_cooking_01_19")
            local fireplaceSquare = { tiles = {} }
            function fireplaceSquare:AddTileObject(object)
                self.tiles[#self.tiles + 1] = object
                object.objectIndex = #self.tiles - 1
            end
            local fireplaceCell = {}
            local builtFireplace = ctx.createCapturedTemplateObject(
                fireplaceCell, fireplaceSquare, fireplaceEntry, 1, nil,
                nil, "template-development")
            assert(fireplaceConstructed.cell == fireplaceCell
                and fireplaceConstructed.square == fireplaceSquare
                and fireplaceConstructed.sprite.name == fireplaceEntry.sprite)
            assert(builtFireplace.class == "IsoFireplace"
                and fireplaceSquare.tiles[1] == builtFireplace
                and builtFireplace:getFuelAmount() == 0
                and builtFireplace.fuelWrites == 1
                and not builtFireplace:isHoppable()
                and builtFireplace.transmitted)

            result = {
                garageCount = #builtGaragePanels,
                regularDoorClass = builtRegularDoor.class,
                regularDoorName = builtRegularDoor.name,
                cabooseDoors = doorCount,
                cabooseDoorFrames = frameCount,
                cabooseWindows = windowCount,
                cabooseFences = fenceCount,
                cabooseFireplace = builtFireplace.class,
            }
            '''
        )

        result = lua.globals().result
        self.assertEqual(result["garageCount"], 8)
        self.assertEqual(result["regularDoorClass"], "IsoDoor")
        self.assertEqual(result["regularDoorName"], "Wooden Door")
        self.assertEqual(result["cabooseDoors"], 2)
        self.assertEqual(result["cabooseDoorFrames"], 2)
        self.assertEqual(result["cabooseWindows"], 10)
        self.assertEqual(result["cabooseFences"], 12)
        self.assertEqual(result["cabooseFireplace"], "IsoFireplace")


if __name__ == "__main__":
    unittest.main()
