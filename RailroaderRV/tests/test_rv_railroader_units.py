from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "contents/mods/RailroaderRV/42/media/lua"


def make_lua(mode: str = "client") -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    shared = (MOD / "shared").as_posix()
    lua.execute(
        "package.path = "
        + repr(f"{shared}/?.lua;")
        + " .. package.path"
    )
    lua.execute(
        r"""
        currentMode = "__MODE__"
        apiViews = {}
        consists = {}
        cutViews = {}
        unitLocations = {}
        trace = { unitsIds = {}, unitOfIds = {}, apiGeometry = 0 }

        local function key(id) return tostring(id) end
        function setConsist(id, units, isCut)
            consists[key(id)] = units
            if isCut then cutViews[#cutViews + 1] = { id = id, isCut = true } end
            for index, unit in ipairs(units) do
                unit.index = index
                unit.trainId = id
                unit.isCut = isCut == true
                unitLocations[key(unit.id)] = {
                    trainId = id, index = index, isCut = isCut == true,
                }
            end
        end
        function resetConsists()
            consists, cutViews, unitLocations = {}, {}, {}
        end

        RR = { API = nil }
        setmetatable(RR, { __index = function(_, name)
            error("unexpected RR internal access: " .. tostring(name))
        end })
        local apiGeometryScratch = { seatPositions = {} }
        local api = {
            mode = function() return currentMode end,
            trains = function(out)
                out = out or {}
                for index = #out, 1, -1 do out[index] = nil end
                for index, view in ipairs(apiViews) do out[index] = view end
                return out
            end,
            units = function(id, out)
                trace.unitsIds[#trace.unitsIds + 1] = id
                local units = consists[key(id)]
                if not units then return nil, "unknown" end
                out = out or {}
                for index = #out, 1, -1 do out[index] = nil end
                for index, unit in ipairs(units) do
                    local copy = {}
                    for field, value in pairs(unit) do copy[field] = value end
                    out[index] = copy
                end
                return out
            end,
            unitOf = function(animalId)
                trace.unitOfIds[#trace.unitOfIds + 1] = animalId
                local location = unitLocations[key(animalId)]
                if not location then return nil, "unknown" end
                return location.trainId, location.index, location.isCut
            end,
            cuts = function(out)
                out = out or {}
                for index = #out, 1, -1 do out[index] = nil end
                for index, cut in ipairs(cutViews) do out[index] = cut end
                return out
            end,
            locomotiveGeometry = function(id, x, y, out)
                trace.apiGeometry = trace.apiGeometry + 1
                trace.apiGeometryUsedPrivateOut = out ~= apiGeometryScratch
                out = out or apiGeometryScratch
                out.hullDistanceTiles = x ~= nil and y ~= nil and 0.75 or nil
                out.mountReachTiles = 2.25
                out.seatPositions = out.seatPositions or {}
                out.passengerSeatCount = 5
                return out
            end,
        }
        RR.API = api
        package.preload["Railroader/RR_API"] = function() return api end

        local module = require("RailroaderRV/RVMapping/RV_RailroaderUnits")
        UnitAdapter = module

        function unit(id, kind, x, y, z, halfLength, halfWidth, dirX, dirY)
            return {
                id = id, kind = kind, isLoco = kind == "loco",
                x = x, y = y, z = z, dirX = dirX or 1, dirY = dirY or 0,
                halfLength = halfLength or 4, halfWidth = halfWidth or 1,
            }
        end
        """.replace("__MODE__", mode)
    )
    return lua


class RailroaderUnitAdapterTests(unittest.TestCase):
    def test_locomotive_view_is_copied_from_public_trains(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            apiViews = {{
                id = 101, x = 4, y = 5, z = 0, dirX = 1, dirY = 0, speed = 3,
                privateRecord = {},
            }}
            local loco = UnitAdapter.find(101)
            assert(loco.id == 101 and loco.kind == "loco")
            assert(loco.isLocomotive == true and loco.locomotiveId == 101)
            assert(loco.x == 4 and loco.y == 5 and loco.speed == 3)
            assert(loco.privateRecord == nil and loco ~= apiViews[1])
            apiViews[1].x = 99
            assert(loco.x == 4)
            """
        )

    def test_car_id_resolves_current_owner_and_transient_cut_parent(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local car = unit(201, "car_box", 10, 20, 0)
            local otherCar = unit(202, "car_box", 30, 40, 0)
            local loco = unit(101, "loco", 0, 0, 0)
            setConsist(101, { car, loco, otherCar }, false)
            apiViews = {{ id = 101, x = 0, y = 0, z = 0,
                dirX = 1, dirY = 0, speed = 4 }}

            local first = UnitAdapter.find(201)
            assert(first.id == 201 and first.kind == "car_box")
            assert(first.isLocomotive == false and first.locomotiveId == 101)
            assert(first.speed == 4 and first.x == 10)
            assert(first.index == nil and first.unit == nil and first.record == nil)

            resetConsists()
            local movedCar = unit(201, "car_box", 110, 120, 0)
            setConsist(102, { unit(102, "loco", 100, 100, 0), movedCar }, false)
            apiViews = {{ id = 102, x = 100, y = 100, z = 0,
                dirX = 0, dirY = 1, speed = 7 }}
            local reattached = UnitAdapter.find(201)
            assert(reattached.id == 201 and reattached.locomotiveId == 102)
            assert(reattached.speed == 7 and reattached.x == 110)

            resetConsists()
            setConsist("cut:alpha", {
                unit(201, "car_bx40", 110, 120, 0),
                unit(202, "car_box", 130, 140, 0),
            }, true)
            apiViews = {}
            local cutUnit = UnitAdapter.find(201)
            assert(cutUnit.id == 201 and cutUnit.kind == "car_bx40")
            assert(cutUnit.isCut == true)
            assert(cutUnit.locomotiveId == nil and cutUnit.speed == 0)
            assert(trace.unitsIds[#trace.unitsIds] == "cut:alpha")
            local list = UnitAdapter.list()
            assert(#list == 2 and list[1].id == 201 and list[2].id == 202)
            assert(list[1].kind == "car_bx40" and list[2].kind == "car_box")
            assert(trace.unitsIds[#trace.unitsIds] == "cut:alpha")
            """
        )

    def test_list_uses_train_and_cut_public_unit_views(self) -> None:
        lua = make_lua(mode="server")
        lua.execute(
            r"""
            setConsist(101, {
                unit(201, "car_box", 10, 20, 0),
                unit(101, "loco", 0, 0, 0),
                unit(202, "car_box", 30, 40, 0),
            }, false)
            setConsist("cut:7b", {
                unit(301, "car_box", 50, 60, 0),
                unit(302, "car_box", 70, 80, 0),
            }, true)
            apiViews = {{ id = 101, x = 0, y = 0, z = 0,
                dirX = 1, dirY = 0, speed = 2 }}

            local list = UnitAdapter.list()
            assert(#list == 5)
            assert(list[1].id == 101 and list[1].kind == "loco")
            assert(list[2].id == 201 and list[3].id == 202)
            assert(list[4].id == 301 and list[5].id == 302)
            assert(list[2].locomotiveId == 101 and list[2].speed == 2)
            assert(list[4].isCut == true and list[4].speed == 0)
            assert(trace.unitsIds[1] == 101 and trace.unitsIds[2] == "cut:7b")
            """
        )

    def test_attached_car_without_public_owner_is_unavailable_not_a_cut(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            setConsist(101, {
                unit(101, "loco", 0, 0, 0), unit(201, "car_box", 10, 20, 0),
            }, false)
            apiViews = {}
            local view, reason = UnitAdapter.find(201)
            assert(view == nil and reason == "unavailable-locomotive")
            """
        )

    def test_car_geometry_uses_public_pose_and_dimensions_and_rejects_nopose(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            setConsist(101, {
                unit(101, "loco", 0, 0, 0),
                unit(201, "car_box", 10, 20, 0, 5, 2, 0, 1),
            }, false)
            apiViews = {{ id = 101, x = 0, y = 0, z = 0,
                dirX = 1, dirY = 0, speed = 0 }}

            local view = UnitAdapter.find(201)
            local geometry = UnitAdapter.geometry(view, 13, 26)
            assert(math.abs(geometry.hullDistanceTiles - math.sqrt(2)) < 0.0001)
            assert(geometry.halfLengthTiles == 5 and geometry.halfWidthTiles == 2)
            assert(geometry.x == 10 and geometry.y == 20)
            assert(geometry.dirX == 0 and geometry.dirY == 1)

            consists["101"][2].x = nil
            local noGeometry, reason = UnitAdapter.geometry(view, 13, 26)
            assert(noGeometry == nil and reason == "nopose")
            """
        )

    def test_locomotive_geometry_stays_on_public_api(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            apiViews = {{ id = 101, x = 4, y = 5, z = 0,
                dirX = 1, dirY = 0, speed = 3 }}
            local view = UnitAdapter.find(101)
            local geometry = UnitAdapter.geometry(view, 8, 9)
            assert(geometry.hullDistanceTiles == 0.75)
            assert(geometry.mountReachTiles == 2.25)
            assert(geometry.x == 4 and geometry.dirX == 1)
            assert(trace.apiGeometry == 1 and trace.apiGeometryUsedPrivateOut)
        """
        )

    def test_public_unit_api_resolves_units_through_shared_path(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            setConsist(101, {
                unit(101, "loco", 0, 0, 0),
                unit(201, "car_box", 10, 20, 0),
            }, false)
            apiViews = {{ id = 101, x = 0, y = 0, z = 0,
                dirX = 1, dirY = 0, speed = 0 }}
            local car = UnitAdapter.find(201)
            assert(car.id == 201 and car.locomotiveId == 101)
            """
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
