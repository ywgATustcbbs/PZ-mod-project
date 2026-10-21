from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MEDIA_LUA = ROOT / "contents/mods/RailroaderRV/42/media/lua"


class RoofRefreshTests(unittest.TestCase):
    def test_scheduled_refresh_uses_each_mapping_templates_captured_floor(self) -> None:
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().mediaLuaRoot = MEDIA_LUA.as_posix()
        lua.execute(
            "package.path = mediaLuaRoot .. '/server/?.lua;' "
            ".. mediaLuaRoot .. '/shared/?.lua;' .. package.path"
        )
        lua.execute(
            r'''
            RailroaderRV = { Server = {} }
            function getCell() return {} end

            local scheduled = {}
            local squareRequests = {}
            local activeSquare
            local restoredFloor
            local restoredIndex
            local removedTemporary
            local temporaryFloor

            package.preload["RailroaderRV/Core/RV_Server_Core"] = function()
                return {
                    getTick = function() return 20 end,
                    tickAdd = function(tick, offset) return tick + offset end,
                    scheduleAtTick = function(tick, callback, rvId)
                        scheduled[#scheduled + 1] = {
                            tick = tick, callback = callback, rvId = rvId,
                        }
                    end,
                }
            end
            package.preload["RailroaderRV/Common/RV_ServerWorld"] = function()
                return {
                    getSquare = function(_, x, y, z)
                        squareRequests[#squareRequests + 1] = {
                            x = x, y = y, z = z,
                        }
                        if activeSquare.x == x and activeSquare.y == y
                            and activeSquare.z == z then
                            return activeSquare.square
                        end
                        return { getFloor = function() return nil end }
                    end,
                    removeGenericObject = function(square, object)
                        assert(square == activeSquare.square)
                        assert(object == temporaryFloor)
                        removedTemporary = object
                    end,
                }
            end

            local RoomTemplate = require(
                "RailroaderRV/RoomTemplate/RV_RoomTemplate")
            local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
            local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
            local templates = {
                {
                    rvId = "base-loco",
                    templateId = RoomTemplate.TEMPLATE_ID,
                },
                {
                    rvId = "engine-area-loco",
                    templateId = RoomTemplate.ENGINE_AREA_TEMPLATE_ID,
                },
                {
                    rvId = "bx40-car-box",
                    templateId = RoomTemplate.CAR_BOX_TEMPLATE_ID,
                },
            }
            local mappingRecords = {}
            for index = 1, #templates do
                local fixture = templates[index]
                local record = {
                    locoId = fixture.rvId,
                    generation = index,
                    slotIndex = index,
                    templateId = fixture.templateId,
                }
                mappingRecords[fixture.rvId] = record
                fixture.record = record
            end
            local mappingAdapter = {
                currentMappingRecordById = function(rvId)
                    return mappingRecords[rvId]
                end,
            }
            RailroaderRV.RailroaderServer = mappingAdapter

            local floor = { objectIndex = 6 }
            function floor:getObjectIndex() return self.objectIndex end
            local square = {}
            function square:getFloor() return floor end
            function square:addFloor(sprite)
                temporaryFloor = { sprite = sprite }
                return temporaryFloor
            end
            function square:transmitAddObjectToSquare(object, objectIndex)
                restoredFloor = object
                restoredIndex = objectIndex
            end

            local ctx = {
                Constants = {},
                Boundary = { boundaryFor = function() return {} end },
                ServerSchema = {
                    boundsFor = function(layout)
                        return { anchor = layout.anchor, z = layout.anchor.z }
                    end,
                },
                RV = RailroaderRV,
                playerIdentity = function() end,
                queueGeneration = function() end,
            }
            require("RailroaderRV/RVMapping/RV_Server_RecordValidation")(ctx)

            local function runTemplateFixture(fixture)
                local anchor = RegionSlots.indexToAnchor(
                    fixture.record.slotIndex)
                local layout = Layout.make(anchor.x, anchor.y, anchor.z,
                    fixture.templateId)
                local point = RoomTemplate.roofRefreshPoints(
                    RoomTemplate.get(fixture.templateId))[1]
                activeSquare = {
                    x = layout.anchor.x + point.x,
                    y = layout.anchor.y + point.y,
                    z = layout.anchor.z + point.z,
                    square = square,
                }
                local requestCount = #squareRequests
                local scheduledCount = #scheduled
                restoredFloor = nil
                restoredIndex = nil
                removedTemporary = nil
                temporaryFloor = nil

                RailroaderRV.Server.scheduleRoofRefreshForRV(fixture.rvId)
                assert(#scheduled == scheduledCount + 4)
                assert(scheduled[#scheduled - 3].rvId == fixture.rvId)
                for attempt = scheduledCount + 1, #scheduled do
                    local refresh = scheduled[attempt]
                    assert(refresh.rvId == fixture.rvId)
                    refresh.callback(refresh.rvId)
                end

                assert(#squareRequests == requestCount + 4)
                local requested = squareRequests[#squareRequests]
                assert(requested.x == activeSquare.x
                    and requested.y == activeSquare.y
                    and requested.z == activeSquare.z)
                assert(restoredFloor == floor and restoredIndex == 6)
                assert(removedTemporary == temporaryFloor)
            end

            for index = 1, #templates do
                runTemplateFixture(templates[index])
            end

            local carBox = RoomTemplate.get(RoomTemplate.CAR_BOX_TEMPLATE_ID)
            local carBoxPoint = carBox.roofRefreshPoints[1]
            assert(carBoxPoint.x == 0 and carBoxPoint.y == 0
                and carBoxPoint.z == 0 and carBoxPoint.templateIndex == 109)
            assert(carBox.objects[carBoxPoint.templateIndex].name == "Floor")

            result = {
                scheduledCount = #scheduled,
                squareRequestCount = #squareRequests,
                carBoxPointIndex = carBoxPoint.templateIndex,
            }
            '''
        )

        result = lua.globals().result
        self.assertEqual(result["scheduledCount"], 12)
        self.assertEqual(result["squareRequestCount"], 12)
        self.assertEqual(result["carBoxPointIndex"], 109)


if __name__ == "__main__":
    unittest.main()
