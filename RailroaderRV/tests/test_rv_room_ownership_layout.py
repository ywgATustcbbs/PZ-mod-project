from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MEDIA_LUA = ROOT / "contents/mods/RailroaderRV/42/media/lua"


class RoomOwnershipLayoutTests(unittest.TestCase):
    def test_template_identity_and_roofs_survive_server_client_refresh(self) -> None:
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().mediaLuaRoot = MEDIA_LUA.as_posix()
        lua.execute(
            "package.path = mediaLuaRoot .. '/shared/?.lua;' "
            ".. mediaLuaRoot .. '/server/?.lua;' "
            ".. mediaLuaRoot .. '/client/?.lua;' .. package.path"
        )
        lua.execute(
            r"""
            local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
            local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
            local ServerSchema = require("RailroaderRV/Common/RV_ServerSchema")
            local baseId = RoomTemplate.TEMPLATE_ID
            local carBoxId = RoomTemplate.CAR_BOX_TEMPLATE_ID
            local baseLayout = Layout.make(100, 200, 0, baseId)
            local carBoxLayout = Layout.make(100, 200, 0, carBoxId)
            assert(baseLayout.anchor.x == 100 and baseLayout.anchor.y == 200
                and baseLayout.anchor.z == 0)
            assert(carBoxLayout.anchor.x == 100 and carBoxLayout.anchor.y == 200
                and carBoxLayout.anchor.z == 0)

            local baseBounds = ServerSchema.boundsFor(baseLayout)
            local carBoxBounds = ServerSchema.boundsFor(carBoxLayout)
            assert(baseBounds.templateId == baseId)
            assert(carBoxBounds.templateId == carBoxId)

            local baseRoofCells = RoomTemplate.roofCells(
                RoomTemplate.get(baseId))
            local carBoxRoofCells = RoomTemplate.roofCells(
                RoomTemplate.get(carBoxId))
            local baseRoofArea = (baseBounds.roofMaxX - baseBounds.roofMinX + 1)
                * (baseBounds.roofMaxY - baseBounds.roofMinY + 1)
            local carBoxRoofArea =
                (carBoxBounds.roofMaxX - carBoxBounds.roofMinX + 1)
                * (carBoxBounds.roofMaxY - carBoxBounds.roofMinY + 1)
            assert(#baseRoofCells == 88 and #baseRoofCells < baseRoofArea)
            assert(#carBoxRoofCells == 120 and #carBoxRoofCells == carBoxRoofArea)

            local function coordinateKey(x, y, z)
                return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
            end
            local function authoredRoofCoordinates(cells)
                local expected = {}
                for index = 1, #cells do
                    local cell = cells[index]
                    local key = coordinateKey(100 + cell.x, 200 + cell.y,
                        cell.z)
                    assert(expected[key] == nil,
                        "duplicate authored roof coordinate " .. key)
                    expected[key] = true
                end
                return expected
            end
            local baseExpected = authoredRoofCoordinates(baseRoofCells)
            local carBoxExpected = authoredRoofCoordinates(carBoxRoofCells)
            local function assertSameCoordinates(actual, expected)
                for key in pairs(expected) do
                    assert(actual[key] == true,
                        "missing roof coordinate " .. key)
                end
                for key in pairs(actual) do
                    assert(expected[key] == true,
                        "unexpected roof coordinate " .. key)
                end
            end

            local payload
            local serverContext = {
                COMMAND_MODULE = "RailroaderRV",
                COMMAND_REFRESH_ROOM_OWNERSHIP = "RefreshRoomOwnership",
                COMMAND_RV_TELEPORT = "RVTeleport",
                Constants = {},
                RV = { Server = {} },
                ServerUtil = {
                    requiredInteger = function(value) return value end,
                    callGlobal = function() return false, nil end,
                },
                ClientDispatch = {
                    broadcast = function(_, _, args)
                        payload = args
                        return true
                    end,
                },
                ServerWorld = {},
                roomOwnershipGuards = {},
                serverTick = 0,
            }
            require("RailroaderRV/RoomOwnership/RV_Server_RoomOwnership")(
                serverContext)
            serverContext.armClientRoomOwnershipGuard(7, baseBounds,
                carBoxBounds, "rv-7")
            assert(payload.oldtemplateId == baseId)
            assert(payload.newtemplateId == carBoxId)

            local scans = {}
            local clientLayout = {}
            for key, value in pairs(Layout) do clientLayout[key] = value end
            clientLayout.eachStructureCoordinate = function(bounds, callback)
                local scan = { templateId = bounds.templateId, roofCount = 0,
                    roofCoordinates = {} }
                scans[#scans + 1] = scan
                Layout.eachStructureCoordinate(bounds, function(x, y, z)
                    if z == bounds.roofZ then
                        local key = coordinateKey(x, y, z)
                        assert(scan.roofCoordinates[key] == nil,
                            "duplicate scanned roof coordinate " .. key)
                        scan.roofCount = scan.roofCount + 1
                        scan.roofCoordinates[key] = true
                    end
                    callback(x, y, z)
                end)
            end
            function getCell()
                return { getGridSquare = function() return nil end }
            end
            local clientContext = {
                C = require("RailroaderRV/Common/RV_Constants"),
                Layout = clientLayout,
                clientTick = 0,
            }
            require("RailroaderRV/GUI/RV_ContextMenu_RoomOwnership")(
                clientContext)
            clientContext.beginRoomOwnershipRefresh(payload)
            assert(#scans == 2)
            assert(scans[1].templateId == baseId
                and scans[1].roofCount == #baseRoofCells)
            assert(scans[2].templateId == carBoxId
                and scans[2].roofCount == #carBoxRoofCells)
            assertSameCoordinates(scans[1].roofCoordinates, baseExpected)
            assertSameCoordinates(scans[2].roofCoordinates, carBoxExpected)
            assert(baseExpected[coordinateKey(100, 195, 1)] == nil
                and scans[1].roofCoordinates[coordinateKey(100, 195, 1)] == nil)
            assert(scans[1].roofCoordinates[coordinateKey(98, 195, 1)]
                and scans[1].roofCoordinates[coordinateKey(99, 195, 1)])
            assert(carBoxExpected[coordinateKey(102, 190, 1)]
                and scans[2].roofCoordinates[coordinateKey(102, 190, 1)])
            """
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
