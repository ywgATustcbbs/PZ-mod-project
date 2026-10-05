"""Offline cache and full-scan behavior tests for production utility modules."""

from __future__ import annotations

from pathlib import Path
import unittest

try:
    from lupa import LuaRuntime
except ImportError as exc:
    raise RuntimeError(
        "Offline Lua checks require Lupa. Install it with "
        "`python -m pip install lupa`."
    ) from exc


ROOT = Path(__file__).resolve().parents[2]
MEDIA_LUA = (
    ROOT
    / "RailroaderRV"
    / "contents"
    / "mods"
    / "RailroaderRV"
    / "42"
    / "media"
    / "lua"
)


HARNESS = r"""
package.path = [[__MEDIA_LUA__/shared/?.lua;__MEDIA_LUA__/server/?.lua;]] .. package.path
RailroaderRV = {}
local U = require("RailroaderRV/Common/RV_UtilityConstants")
require("RailroaderRV/Common/RV_Constants")

local root = { records = {} }
local transmitCount = 0
local squareLookupCount = 0
local worldAge = 1
local player = {}
local identity = { rvId = "cache-fixture", generation = 3 }
local mappingRecord = { slotIndex = 1,
    rvPosition = { x = 0, y = 0, z = 0 } }

ModData = {
    get = function() return root end,
    getOrCreate = function() return root end,
    transmit = function() transmitCount = transmitCount + 1 end,
}

function getGameTime()
    return { getWorldAgeHours = function() return worldAge end }
end

function instanceof(object, className)
    return object and object.testClass == className or false
end
RainManager = { isRaining = function() return false end }

local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local anchor = RegionSlots.indexToAnchor(mappingRecord.slotIndex)
local firstBuildCell = template.misc.buildCells[1]
local fixtureX = anchor.x + firstBuildCell.x
local fixtureY = anchor.y + firstBuildCell.y
local fixtureZ = anchor.z + (firstBuildCell.z or 0)

local poweredSprite = { getName = function() return "fixture.powered_light" end }
local poweredObject = { testClass = "IsoLightSwitch" }
function poweredObject:getContainerByType() return nil end
function poweredObject:getObjectName() return "IsoLightSwitch" end
function poweredObject:getSprite() return poweredSprite end
function poweredObject:couldBePoweredByGenerator() return true end
function poweredObject:getObjectIndex() return 7 end
function poweredObject:isActivated() return true end

local proxyGenerator = {
    setCondition = function() end,
    setFuel = function() end,
    setActivated = function() end,
    sync = function() end,
}
local emptySquare = {
    getGenerator = function() return proxyGenerator end,
}
local fixtureSquare = {
    getGenerator = function() return proxyGenerator end,
}
package.preload["RailroaderRV/Common/RV_ServerWorld"] = function()
    return {
        getCellForPlayer = function() return {} end,
        getSquare = function(_, x, y, z)
            squareLookupCount = squareLookupCount + 1
            if x == fixtureX and y == fixtureY and z == fixtureZ then
                return fixtureSquare
            end
            return emptySquare
        end,
        squareSnapshot = function(square)
            return square == fixtureSquare and { poweredObject } or {}
        end,
    }
end

local Store = require("RailroaderRV/Core/RV_UtilityStore")
local Devices = require("RailroaderRV/Power/RV_UtilityPowerDevices")
local Power = require("RailroaderRV/Power/RV_UtilityPower")

function createAndSettle()
    local record = Store.getRecord(identity, true)
    assert(type(record.power.deviceCache) == "table")
    assert(type(record.power.deviceCache.template) == "table")
    assert(type(record.power.deviceCache.build) == "table")
    assert(#record.power.deviceCache.template == 0)
    assert(#record.power.deviceCache.build == 0)
    record.power.lastSettlementTime = 0
    Store.commit(record, identity)
    transmitCount = 0
    squareLookupCount = 0

    local settled, updated = Power.settleAndRefreshLoad(identity, player,
        Store.getRecord(identity, false), mappingRecord)
    assert(settled == true)
    assert(type(updated.power.deviceCache) == "table")
    assert(#updated.power.deviceCache.build == 1)
    assert(updated.power.deviceCache.build[1].id
        == tostring(fixtureX) .. ":" .. tostring(fixtureY) .. ":"
            .. tostring(fixtureZ) .. ":7")
    assert(updated.power.deviceCache.build[1].demandPowerW == 60)
    assert(updated.power.deviceCache.build[1].active == true)
    local persisted = Store.getRecord(identity, false)
    assert(#persisted.power.deviceCache.build == 1)
    assert(persisted.power.deviceCache.build[1].id
        == updated.power.deviceCache.build[1].id)
    assert(persisted.power.deviceCache.build[1].demandPowerW == 60)
    assert(persisted.power.deviceCache.build[1].active == true)
    return #updated.power.deviceCache.template,
        #updated.power.deviceCache.build,
        updated.power.deviceCache.build[1].id,
        updated.power.deviceCache.build[1].demandPowerW,
        updated.power.deviceCache.build[1].active,
        transmitCount, squareLookupCount
end

function reRequireAndRestore()
    local record = Store.getRecord(identity, false)
    local expectedId = record.power.deviceCache.build[1].id
    local expectedDemand = record.power.deviceCache.build[1].demandPowerW
    transmitCount = 0
    package.loaded["RailroaderRV/Power/RV_UtilityPowerDevices"] = nil
    package.loaded["RailroaderRV/Power/RV_UtilityPower"] = nil
    Devices = require("RailroaderRV/Power/RV_UtilityPowerDevices")
    Power = require("RailroaderRV/Power/RV_UtilityPower")

    local restored = Store.getRecord(identity, false)
    local initialized = Devices.ensureInitialized(identity, restored)
    assert(initialized.build[1].id == expectedId)
    assert(initialized.build[1].demandPowerW == expectedDemand)
    return #initialized.template, #initialized.build,
        initialized.build[1].id, initialized.build[1].demandPowerW,
        initialized.build[1].active, transmitCount
end

function failSettlementWithCacheShape(shape)
    local persisted = root.records[identity.rvId]
    if shape == "nil-cache" then
        persisted.power.deviceCache = nil
    elseif shape == "nil-template" then
        persisted.power.deviceCache = { build = {} }
    elseif shape == "nil-build" then
        persisted.power.deviceCache = { template = {} }
    else
        error("unknown cache shape fixture")
    end
    transmitCount = 0
    local record = Store.getRecord(identity, false)
    local ok, result = pcall(function()
        return Power.settleAndRefreshLoad(identity, player, record,
            mappingRecord)
    end)
    return ok, tostring(result), transmitCount
end
"""


class PowerDeviceCacheChecks(unittest.TestCase):
    def setUp(self) -> None:
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        media_lua = str(MEDIA_LUA).replace("\\", "/")
        self.lua.execute(HARNESS.replace("__MEDIA_LUA__", media_lua))
        self.globals = self.lua.globals()

    def test_full_production_scan_commits_device_cache_once(self) -> None:
        (
            _template_count, build_count, device_id, demand_w, active,
            transmit_count, square_lookups,
        ) = (
            self.globals.createAndSettle()
        )

        self.assertEqual(build_count, 1)
        self.assertIsNotNone(device_id)
        self.assertEqual(demand_w, 60)
        self.assertTrue(active)
        self.assertEqual(transmit_count, 1)
        self.assertGreater(square_lookups, 1)

    def test_store_record_restores_scan_cache_after_module_rerequire(self) -> None:
        self.globals.createAndSettle()
        (
            _template_count, build_count, restored_id, restored_demand,
            restored_active, transmit_count,
        ) = (
            self.globals.reRequireAndRestore()
        )

        self.assertEqual(build_count, 1)
        self.assertIsNotNone(restored_id)
        self.assertEqual(restored_demand, 60)
        self.assertTrue(restored_active)
        self.assertEqual(transmit_count, 0)

    def test_missing_internal_cache_lists_fail_without_reconciliation(self) -> None:
        self.globals.createAndSettle()

        for shape in ("nil-cache", "nil-template", "nil-build"):
            with self.subTest(shape=shape):
                ok, error, transmit_count = (
                    self.globals.failSettlementWithCacheShape(shape)
                )
                self.assertFalse(ok)
                self.assertTrue(error)
                self.assertEqual(transmit_count, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
