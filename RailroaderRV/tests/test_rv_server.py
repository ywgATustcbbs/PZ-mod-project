#!/usr/bin/env python3
"""Run static and contract checks for the Railroader RV test package.

This test intentionally uses only Python's standard library.  It never starts
the server or the game client; the local luaparse command is used only for the
existing Lua syntax check.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path


MOD_ID = "RailroaderRV"


class Checks:
    def __init__(self) -> None:
        self.failures: list[str] = []

    def true(self, condition: bool, message: str) -> None:
        if not condition:
            self.failures.append(message)


def aggregate_lua_sources(paths: list[Path]) -> str:
    return "\n".join(read_utf8(path) for path in paths if path.is_file())


def read_utf8(path: Path) -> str:
    """Read repository text while accepting either UTF-8 or UTF-8 with BOM.

    Undecodable bytes are replaced instead of aborting the run, so a damaged
    source file shows up as failing token contracts rather than as a raw
    UnicodeDecodeError traceback that hides every other result.
    """

    return path.read_text(encoding="utf-8-sig", errors="replace")


def section(text: str, start: str, end: str) -> str | None:
    match = re.search(r"(?s)" + start + r"(.*?)" + end, text)
    return match.group(1) if match else None


def compile_current_room_template(shared_lua_root: Path) -> list[dict[str, object]]:
    """Load the real shared template compiler and return its ordered objects."""

    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().rvSharedLuaRoot = str(shared_lua_root.resolve()).replace("\\", "/")
    lua.execute("package.path = rvSharedLuaRoot .. '/?.lua;' .. package.path")
    objects = lua.execute(
        'local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"; '
        'return RoomTemplate.orderedObjects(RoomTemplate.get(RoomTemplate.TEMPLATE_ID))'
    )
    result = []
    for index in range(1, len(objects) + 1):
        obj = objects[index]
        result.append(
            {
                "index": int(obj["templateIndex"]),
                "x": int(obj["x"]),
                "y": int(obj["y"]),
                "z": int(obj["z"]),
                "class": obj["class"],
                "name": obj["name"],
                "sprite": obj["sprite"],
                "north": obj["north"],
                "direction": obj["direction"],
                "state": dict(obj["state"].items()),
                "protected": bool(obj["protected"]),
            }
        )
    return result


def compile_current_template_metadata(shared_lua_root: Path) -> dict[str, object]:
    """Load the real shared template compiler and return its identity metadata."""

    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().rvSharedLuaRoot = str(shared_lua_root.resolve()).replace("\\", "/")
    lua.execute("package.path = rvSharedLuaRoot .. '/?.lua;' .. package.path")
    metadata = lua.execute(
        'local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"; '
        'local template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID); '
        "return { templateVersion = template.metadata.templateVersion, "
        "objectCount = template.metadata.objectCount, "
        "currentTemplateVersion = RoomTemplate.CURRENT_TEMPLATE_VERSION }"
    )
    return {
        "templateVersion": int(metadata["templateVersion"]),
        "objectCount": int(metadata["objectCount"]),
        "currentTemplateVersion": int(metadata["currentTemplateVersion"]),
    }


def compile_template_variant_contracts(
    shared_lua_root: Path, server_lua_root: Path
) -> dict[str, object]:
    """Exercise both registered layouts through the real Lua modules."""

    from lupa import LuaRuntime

    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().rvSharedLuaRoot = str(shared_lua_root.resolve()).replace("\\", "/")
    lua.globals().rvServerLuaRoot = str(server_lua_root.resolve()).replace("\\", "/")
    lua.globals().rvClientLuaRoot = str(
        (shared_lua_root.parent / "client").resolve()
    ).replace("\\", "/")
    lua.execute(
        "package.path = rvServerLuaRoot .. '/?.lua;' "
        ".. rvSharedLuaRoot .. '/?.lua;' "
        ".. rvClientLuaRoot .. '/?.lua;' .. package.path"
    )
    return lua.execute(
        r'''
local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"
local Layout = require "RailroaderRV/RoomTemplate/RV_Layout"
local Geometry = require "RailroaderRV/RoomTemplate/RV_TemplateGeometry"
local baseId = RoomTemplate.TEMPLATE_ID
local engineId = RoomTemplate.ENGINE_AREA_TEMPLATE_ID
local base = RoomTemplate.get(baseId)
local engine = RoomTemplate.get(engineId)
local baseLayout = Layout.make(20050, 2050, 0, baseId)
local engineLayout = Layout.make(20050, 2050, 0, engineId)
local omittedTemplateIdRejected = not pcall(function()
    Layout.make(20050, 2050, 0, nil)
end)

local objectsSameExceptProtection = #base.objects == #engine.objects
local changedProtectionFlags = 0
for i = 1, #base.objects do
    local a, b = base.objects[i], engine.objects[i]
    if a.protected ~= b.protected then changedProtectionFlags = changedProtectionFlags + 1 end
    if a.templateIndex ~= b.templateIndex or a.x ~= b.x or a.y ~= b.y
        or a.z ~= b.z or a.class ~= b.class or a.name ~= b.name
        or a.sprite ~= b.sprite or a.north ~= b.north
        or a.direction ~= b.direction or a.state ~= b.state then
        objectsSameExceptProtection = false
    end
end

local engineCellsInsideWalk = true
for i = 1, #engine.misc.buildCells do
    local cell = engine.misc.buildCells[i]
    local walkable = false
    for j = 1, #engine.misc.walkAabbs do
        local box = engine.misc.walkAabbs[j]
        local z = cell.z == nil and engine.metadata.anchor.z or cell.z
        if cell.x >= box.minX and cell.x < box.maxX
            and cell.y >= box.minY and cell.y < box.maxY
            and z >= box.minZ and z < box.maxZExclusive then
            walkable = true
        end
    end
    if not walkable then engineCellsInsideWalk = false end
end

local engineCellsMatchBuildRects = true
local engineRectCellCount = 0
local engineRectArea = 0
local engineRectCount = #engine.misc.buildRects
local engineCellSet = {}
for i = 1, #engine.misc.buildCells do
    local cell = engine.misc.buildCells[i]
    engineCellSet[cell.x .. ":" .. cell.y] = true
end
for i = 1, engineRectCount do
    local rectangle = engine.misc.buildRects[i]
    local area = (rectangle.maxXExclusive - rectangle.minX)
        * (rectangle.maxYExclusive - rectangle.minY)
    engineRectArea = engineRectArea + area
    for y = rectangle.minY, rectangle.maxYExclusive - 1 do
        for x = rectangle.minX, rectangle.maxXExclusive - 1 do
            engineRectCellCount = engineRectCellCount + 1
            if not engineCellSet[x .. ":" .. y] then
                engineCellsMatchBuildRects = false
            end
        end
    end
end
if engineRectCellCount ~= #engine.misc.buildCells then
    engineCellsMatchBuildRects = false
end

local engineRoofProjectionSet = {}
local engineRoofProjectionCount = 0
local engineRoofCellCount = 0
for i = 1, #engine.roofCells do
    local roof = engine.roofCells[i]
    if roof.z == 1 then
        engineRoofCellCount = engineRoofCellCount + 1
        local key = roof.x .. ":" .. roof.y
        if not engineRoofProjectionSet[key] then
            engineRoofProjectionSet[key] = true
            engineRoofProjectionCount = engineRoofProjectionCount + 1
        end
    end
end
local engineCellsMatchRoofProjection = true
for key in pairs(engineRoofProjectionSet) do
    if not engineCellSet[key] then engineCellsMatchRoofProjection = false end
end
for key in pairs(engineCellSet) do
    if not engineRoofProjectionSet[key] then
        engineCellsMatchRoofProjection = false
    end
end

local coveredEngineCells = 0
for i = 1, #engine.misc.buildCells do
    local cell = engine.misc.buildCells[i]
    local buildZ = cell.z == nil and engine.metadata.anchor.z or cell.z
    local covered = false
    for j = 1, #engine.waterProxies do
        local proxy = engine.waterProxies[j]
        if proxy.buildZ == buildZ and proxy.z == buildZ + 1
            and math.abs(proxy.x - cell.x) <= 1
            and math.abs(proxy.y - cell.y) <= 1 then
            covered = true
        end
    end
    if covered then coveredEngineCells = coveredEngineCells + 1 end
end

local Boundary = { _states = {}, _tick = 0 }
local installBoundaryGeometry = require "RailroaderRV/BoundaryGuard/RV_BoundaryServer_Geometry"
installBoundaryGeometry({
    processIsServer = function() return true end,
    Boundary = Boundary,
    Core = {},
    C = {},
})
local function boundaryFor(templateId)
    return Boundary.boundaryFor({
        locoId = "offline-variant-contract",
        generation = 1,
        slotIndex = 1,
        templateId = templateId,
    })
end
local baseBoundary = boundaryFor(baseId)
local engineBoundary = boundaryFor(engineId)
local engineAnchor = Geometry.anchorFromManaged(engineBoundary.managed, engine)
local baseAnchor = Geometry.anchorFromManaged(baseBoundary.managed, base)
local engineRoofBuildable = Geometry.isBuildable({
    x = engineAnchor.x - 3, y = engineAnchor.y + 3, z = engineAnchor.z,
}, engineAnchor, engine)
local engineCorridorHeadBuildable = Geometry.isBuildable({
    x = engineAnchor.x - 4, y = engineAnchor.y - 6, z = engineAnchor.z,
}, engineAnchor, engine)
local engineCorridorTailBuildable = Geometry.isBuildable({
    x = engineAnchor.x - 4, y = engineAnchor.y + 16, z = engineAnchor.z,
}, engineAnchor, engine)
local engineCorridorHeadWalkable = Geometry.isWalkable({
    x = engineAnchor.x - 4, y = engineAnchor.y - 6, z = engineAnchor.z,
}, engineAnchor, engine)
local engineCorridorTailWalkable = Geometry.isWalkable({
    x = engineAnchor.x - 4, y = engineAnchor.y + 16, z = engineAnchor.z,
}, engineAnchor, engine)
local engineCorridorHeadObjects = RoomTemplate.cellAt(engine, -4, -6).layers[0]
local engineRoofAdditionObjects = RoomTemplate.cellAt(engine, -3, 3).layers[0]
local engineRoofAdditionRoofObjects = RoomTemplate.cellAt(engine, -3, 3).layers[1]
local corridorHeadTemplateObjectProtected = engineCorridorHeadObjects[1].protected
local roofAdditionTemplateObjectProtected = engineRoofAdditionObjects[1].protected
local roofAdditionRoofTemplateObjectProtected =
    engineRoofAdditionRoofObjects[1].protected
local boundaryWindowObjects = RoomTemplate.cellAt(engine, -4, 2).layers[0]
local boundaryWindowProtected = nil
for i = 1, #boundaryWindowObjects do
    local object = boundaryWindowObjects[i]
    if object.class == "IsoWindow" then
        boundaryWindowProtected = object.protected
        break
    end
end
local boundaryWindowIsSideHost = Geometry.isBuildCellSideHost({
    x = engineAnchor.x - 4, y = engineAnchor.y + 2, z = engineAnchor.z,
}, engineAnchor, engine)

local RepairFactory = require "RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair"
local repairBoundary = engineBoundary
local repairWorldX, repairWorldY = engineAnchor.x - 4,
    engineAnchor.y - 6
local repairSquareLayers = { [0] = true }
local repairSquare = {}
local repairCellWorld = {}
local restoredTemplateEntries = 0
local repairServerWorld = {
    getCellForPlayer = function() return repairCellWorld end,
    getSquare = function(_, x, y, z)
        if x == repairWorldX and y == repairWorldY
            and repairSquareLayers[z] then
            return repairSquare
        end
    end,
    squareSnapshot = function() return {} end,
    objectModData = function() return nil end,
}
local repair = RepairFactory({
    Constants = {
        MOD_ID = "RailroaderRV",
        WORLD_MIN_Z = -32,
        WORLD_MAX_Z = 32,
    },
    RV = {},
    ServerUtil = { toNumber = function(value) return tonumber(value) or value end },
    ServerWorld = repairServerWorld,
    createCapturedTemplateObject = function()
        restoredTemplateEntries = restoredTemplateEntries + 1
    end,
    configureCapturedDoorFrame = function() end,
    Boundary = { boundaryForPlayer = function() return repairBoundary end },
})
local baseCabColumnHasProtectedLayer = repair.isProtectedCell(baseBoundary,
    baseAnchor.x - 4, baseAnchor.y - 2)
local corridorHeadProtectionQueued = repair.isProtectedCell(engineBoundary,
    engineAnchor.x - 4, engineAnchor.y - 6)
local generatorProxyColumnProtected = repair.isProtectedCell(engineBoundary,
    engineAnchor.x + engine.powerProxy.x,
    engineAnchor.y + engine.powerProxy.y)
local addedWaterProxyColumnProtected = repair.isProtectedCell(engineBoundary,
    engineAnchor.x - 3, engineAnchor.y - 5)
local corridorRepairChanged = repair.repairCell({}, engineBoundary,
    repairWorldX, repairWorldY)
local corridorTemplateRestoreCalls = restoredTemplateEntries
local corridorTemplateRestoreRequested = corridorRepairChanged == true
    and restoredTemplateEntries > 0
restoredTemplateEntries = 0
-- Keep both z0 and z1 squares available at this buildable XY. If repair stops
-- exempting the selected build cell, its missing protected z1 roof entry must
-- reach createCapturedTemplateObject and fail the zero-restore contract.
repairWorldX, repairWorldY = engineAnchor.x - 3,
    engineAnchor.y + 3
repairSquareLayers = { [0] = true, [1] = true }
local roofBuildSquaresAvailable = repairServerWorld.getSquare(
    repairCellWorld, repairWorldX, repairWorldY, 0) ~= nil
    and repairServerWorld.getSquare(repairCellWorld, repairWorldX,
        repairWorldY, 1) ~= nil
local roofRepairChanged = repair.repairCell({}, engineBoundary,
    engineAnchor.x - 3, engineAnchor.y + 3)
local roofProjectionRestoreCalls = restoredTemplateEntries
local roofBuildCellSkipsTemplateRestore = roofBuildSquaresAvailable
    and roofRepairChanged == false
    and restoredTemplateEntries == 0

local Devices = require "RailroaderRV/Power/RV_UtilityPowerDevices"
local function scanEngineFloor(templateId, rvId)
    local anchor = require("RailroaderRV/RVMapping/RV_RegionSlots").indexToAnchor(1)
    local targetX, targetY, targetZ = anchor.x - 3, anchor.y + 3, anchor.z
    local corridorX, corridorY = anchor.x - 4, anchor.y - 6
    local fakeSprite = { getName = function() return "offline-test-unmatched-floor" end }
    local fakeFridge = {
        getSprite = function() return fakeSprite end,
        getObjectName = function() return "IsoObject" end,
        getContainerByType = function(_, kind)
            return kind == "fridge" and {} or nil
        end,
        couldBePoweredByGenerator = function() return true end,
        getObjectIndex = function() return 7 end,
    }
    local calls = 0
    local cell = {
        getGridSquare = function(_, x, y, z)
            calls = calls + 1
            local objects = {}
            if x == targetX and y == targetY and z == targetZ then
                objects[1] = fakeFridge
            end
            if x == corridorX and y == corridorY and z == targetZ then
                objects[#objects + 1] = fakeFridge
            end
            return { getObjects = function() return objects end }
        end,
    }
    local player = { getCell = function() return cell end }
    local record = { power = { deviceCache = { template = {}, build = {} } } }
    local scanned = Devices.scan({ rvId = rvId, generation = 1 }, record,
        player, 1, templateId)
    return {
        scanned = scanned,
        buildDeviceCount = #record.power.deviceCache.build,
        squareLookups = calls,
    }
end
local baseScan = scanEngineFloor(baseId, "offline-base-scan")
local engineScan = scanEngineFloor(engineId, "offline-engine-scan")

package.preload["RailroaderRV/GUI/RV_BoundaryClient"] = function()
    return {}
end
for _, actionModule in ipairs({ "ISDestroyStuffAction",
    "ISDismantleAction", "ISTakeGenerator" }) do
    package.preload["TimedActions/" .. actionModule] = function()
        return true
    end
end
ISDestroyStuffAction = { new = function() return "action-allowed" end }
ISDismantleAction = { new = function() return "action-allowed" end }
ISTakeGenerator = { new = function() return "action-allowed" end }
IsoDirections = { N = "N", S = "S", E = "E", W = "W" }
instanceof = function(object, className)
    return object.class == className
end
isClient = function() return true end
package.loaded["RailroaderRV/GUI/RV_ProtectedDemolition"] = nil
require "RailroaderRV/GUI/RV_ProtectedDemolition"

local function demolitionIsBlocked(expected, templateId, anchor)
    local square = {
        getX = function() return anchor.x + expected.x end,
        getY = function() return anchor.y + expected.y end,
        getZ = function() return anchor.z + expected.z end,
    }
    local sprite = { getName = function() return expected.sprite end }
    local object = {
        class = expected.class,
        getSquare = function() return square end,
        getObjectIndex = function() return 0 end,
        getModData = function()
            return { RailroaderRV = {
                owner = "RailroaderRV",
                rvId = "offline-demolition-contract",
                generation = 1,
                templateId = templateId,
                templateIndex = expected.templateIndex,
                role = "captured-template",
            } }
        end,
        getName = function() return expected.name end,
        getSprite = function() return sprite end,
        getDir = function() return IsoDirections[expected.direction] end,
        getNorth = function() return expected.north end,
        isDoor = function() return false end,
        isWindow = function() return false end,
    }
    local result = ISDestroyStuffAction:new({}, object)
    return type(result) == "table" and result.ignoreAction == true
end

local corridorDemolitionBlocked = demolitionIsBlocked(
    engineCorridorHeadObjects[1], engineId, engineAnchor)
local roofDemolitionBlocked = demolitionIsBlocked(
    engineRoofAdditionObjects[1], engineId, engineAnchor)
local boundaryWindowExpected = nil
for i = 1, #boundaryWindowObjects do
    local object = boundaryWindowObjects[i]
    if object.class == "IsoWindow" then
        boundaryWindowExpected = object
        break
    end
end
local boundaryWindowDemolitionBlocked = demolitionIsBlocked(
    boundaryWindowExpected, engineId, engineAnchor)

local sameManaged = baseLayout.managed.originX == engineLayout.managed.originX
    and baseLayout.managed.originY == engineLayout.managed.originY
    and baseLayout.managed.width == engineLayout.managed.width
    and baseLayout.managed.height == engineLayout.managed.height
    and baseLayout.managed.minZ == engineLayout.managed.minZ
    and baseLayout.managed.maxZ == engineLayout.managed.maxZ

return {
    baseId = baseId,
    engineId = engineId,
    disabledSelection = RoomTemplate.templateIdForEngineAreaBuilding(false),
    enabledSelection = RoomTemplate.templateIdForEngineAreaBuilding(true),
    baseCells = base.misc.buildCells,
    engineCells = engine.misc.buildCells,
    baseProxies = base.waterProxies,
    engineProxies = engine.waterProxies,
    baseLayoutProxies = baseLayout.waterProxies,
    engineLayoutProxies = engineLayout.waterProxies,
    engineBuildRects = engine.misc.buildRects,
    engineRoofCells = engine.roofCells,
    engineWalkAabb = engine.misc.walkAabbs[1],
    baseLayoutId = baseLayout.templateId,
    engineLayoutId = engineLayout.templateId,
    sameManaged = sameManaged,
    omittedTemplateIdRejected = omittedTemplateIdRejected,
    separateTemplateObjects = base ~= engine and base.objects ~= engine.objects,
    separateWaterProxyLists = base.waterProxies ~= engine.waterProxies,
    objectsSameExceptProtection = objectsSameExceptProtection,
    changedProtectionFlags = changedProtectionFlags,
    engineCellsInsideWalk = engineCellsInsideWalk,
    engineRectCellCount = engineRectCellCount,
    engineRectArea = engineRectArea,
    engineRectCount = engineRectCount,
    engineCellsMatchBuildRects = engineCellsMatchBuildRects,
    engineRoofProjectionCount = engineRoofProjectionCount,
    engineRoofCellCount = engineRoofCellCount,
    engineCellsMatchRoofProjection = engineCellsMatchRoofProjection,
    coveredEngineCells = coveredEngineCells,
    baseBoundaryId = baseBoundary.templateId,
    engineBoundaryId = engineBoundary.templateId,
    baseCabColumnHasProtectedLayer = baseCabColumnHasProtectedLayer,
    corridorHeadProtectionQueued = corridorHeadProtectionQueued,
    generatorProxyColumnProtected = generatorProxyColumnProtected,
    addedWaterProxyColumnProtected = addedWaterProxyColumnProtected,
    engineRoofBuildable = engineRoofBuildable,
    engineCorridorHeadBuildable = engineCorridorHeadBuildable,
    engineCorridorTailBuildable = engineCorridorTailBuildable,
    engineCorridorHeadWalkable = engineCorridorHeadWalkable,
    engineCorridorTailWalkable = engineCorridorTailWalkable,
    corridorHeadTemplateObjectProtected = corridorHeadTemplateObjectProtected,
    roofAdditionTemplateObjectProtected = roofAdditionTemplateObjectProtected,
    roofAdditionRoofTemplateObjectProtected = roofAdditionRoofTemplateObjectProtected,
    boundaryWindowProtected = boundaryWindowProtected,
    boundaryWindowIsSideHost = boundaryWindowIsSideHost,
    corridorRepairChanged = corridorRepairChanged,
    corridorTemplateRestoreCalls = corridorTemplateRestoreCalls,
    corridorTemplateRestoreRequested = corridorTemplateRestoreRequested,
    roofRepairChanged = roofRepairChanged,
    roofBuildSquaresAvailable = roofBuildSquaresAvailable,
    roofProjectionRestoreCalls = roofProjectionRestoreCalls,
    roofBuildCellSkipsTemplateRestore = roofBuildCellSkipsTemplateRestore,
    corridorDemolitionBlocked = corridorDemolitionBlocked,
    roofDemolitionBlocked = roofDemolitionBlocked,
    boundaryWindowDemolitionBlocked = boundaryWindowDemolitionBlocked,
    baseScan = baseScan,
    engineScan = engineScan,
}
'''
    )


def parse_template_state(value: str) -> dict[str, object]:
    result: dict[str, object] = {}
    if value == "":
        return result
    for field in value.split(","):
        if "=" not in field:
            # A malformed state token must surface as a compared mismatch
            # instead of aborting the run with an unpack ValueError.
            result[field] = None
            continue
        key, raw_value = field.split("=", 1)
        if raw_value == "true":
            parsed: object = True
        elif raw_value == "false":
            parsed = False
        elif re.fullmatch(r"-?\d+", raw_value):
            parsed = int(raw_value)
        elif raw_value.startswith('"') and raw_value.endswith('"'):
            parsed = raw_value[1:-1]
        else:
            parsed = raw_value
        result[key] = parsed
    return result


def run_lua_syntax_checks(root: Path, checks: Checks) -> None:
    parser = root / ".rv-lua-parse" / "node_modules" / ".bin" / "luaparse.cmd"
    checks.true(parser.is_file(), f"local luaparse is missing: {parser}")
    if not parser.is_file():
        return

    lua_root = (
        root
        / "RailroaderRV"
        / "contents"
        / "mods"
        / MOD_ID
        / "42"
        / "media"
        / "lua"
    )
    for lua_file in sorted(lua_root.rglob("*.lua")):
        command = [str(parser), "--quiet", "--file", str(lua_file)]
        if os.name == "nt":
            # Windows cannot execute a .cmd file directly with shell=False.
            command = ["cmd.exe", "/d", "/c", *command]
        result = subprocess.run(
            command,
            cwd=root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        output = " ".join(
            part.strip() for part in (result.stdout, result.stderr) if part.strip()
        )
        checks.true(
            result.returncode == 0,
            f"Lua syntax parse failed: {lua_file} {output}".rstrip(),
        )


def lua_top_level_local_count(root: Path, lua_file: Path) -> int | None:
    """Count the locals active in a Lua chunk's main function.

    Kahlua's 200-local limit applies to the chunk scope, so nested function
    locals are intentionally not included.  Use the same local luaparse
    dependency as the syntax check instead of a regex that would count every
    nested helper variable.
    """

    module_root = root / ".rv-lua-parse" / "node_modules"
    script = (
        "const fs=require('fs'),p=require('luaparse');"
        "const a=p.parse(fs.readFileSync(process.argv[1],'utf8'));"
        "let n=0;for(const s of a.body){"
        "if(s.type==='LocalStatement')n+=s.variables.length;"
        "else if(s.type==='FunctionDeclaration'&&s.isLocal)n++;}"
        "process.stdout.write(String(n));"
    )
    try:
        result = subprocess.run(
            ["node", "-e", script, str(lua_file)],
            cwd=module_root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    try:
        return int(result.stdout.strip())
    except ValueError:
        return None


def main() -> int:
    # The project root is inferred from this file's location, so the script only
    # works from <project>/RailroaderRV/tests/.  A relocated copy used to skip
    # the whole contract block and die later with an UnboundLocalError, which
    # prints no [FAIL] line at all and can be mistaken for a clean run.
    root = Path(__file__).resolve().parents[2]
    package_root = root / "RailroaderRV" / "contents" / "mods" / MOD_ID / "42"
    if not package_root.is_dir():
        print(
            f"[FAIL] cannot locate the project root from {Path(__file__).resolve()}: "
            f"{package_root} is not a directory; run this test from "
            f"<project>/RailroaderRV/tests/",
            file=sys.stderr,
        )
        return 1
    media_lua_root = package_root / "media" / "lua"
    server_root = media_lua_root / "server" / "RailroaderRV"
    client_root = media_lua_root / "client" / "RailroaderRV"
    shared_root = media_lua_root / "shared" / "RailroaderRV"
    server_path = server_root / "Core" / "RV_Server.lua"
    server_util_path = server_root / "Common" / "RV_ServerUtil.lua"
    server_world_path = server_root / "Common" / "RV_ServerWorld.lua"
    server_schema_path = server_root / "Common" / "RV_ServerSchema.lua"
    client_path = client_root / "GUI" / "RV_ContextMenu.lua"
    railroader_server_path = (
        server_root / "Core" / "RV_RailroaderServer.lua"
    )
    railroader_client_path = (
        client_root / "GUI" / "RV_RailroaderContextMenu.lua"
    )
    constants_path = shared_root / "Common" / "RV_Constants.lua"
    region_slots_path = shared_root / "RVMapping" / "RV_RegionSlots.lua"
    bitmap_path = region_slots_path
    constants = read_utf8(constants_path) if constants_path.is_file() else ""
    region_slots = read_utf8(region_slots_path) if region_slots_path.is_file() else ""
    layout_path = shared_root / "RoomTemplate" / "RV_Layout.lua"
    template_path = shared_root / "RoomTemplate" / "RV_Template.lua"
    room_template_path = shared_root / "RoomTemplate" / "RV_RoomTemplate.lua"
    mapping_path = server_root / "RVMapping" / "RV_RailroaderServer_Mapping.lua"
    boundary_geometry_path = server_root / "BoundaryGuard" / "RV_BoundaryServer_Geometry.lua"
    boundary_sweep_path = server_root / "BoundaryGuard" / "RV_BoundaryServer_Sweep.lua"
    boundary_server_path = server_root / "BoundaryGuard" / "RV_BoundaryServer.lua"
    boundary_client_path = client_root / "GUI" / "RV_BoundaryClient.lua"
    boundary_wall_visuals_path = client_root / "GUI" / "RV_BoundaryWallVisuals.lua"
    protected_demolition_path = client_root / "GUI" / "RV_ProtectedDemolition.lua"
    wardrobe_visuals_path = client_root / "GUI" / "RV_WardrobeVisuals.lua"
    utility_catalog_path = shared_root / "Water" / "RV_UtilityCatalog.lua"
    utility_constants_path = shared_root / "Common" / "RV_UtilityConstants.lua"
    utility_context_path = client_root / "GUI" / "RV_UtilityContextMenu.lua"
    utility_client_path = client_root / "GUI" / "RV_UtilityClient.lua"
    utility_server_path = server_root / "Core" / "RV_UtilityServer.lua"
    utility_water_path = server_root / "Water" / "RV_UtilityWater.lua"
    utility_water_commands_path = server_root / "Water" / "RV_UtilityWater_Commands.lua"
    utility_water_ledger_path = server_root / "Water" / "RV_UtilityWater_Ledger.lua"
    utility_objects_path = server_root / "Water" / "RV_UtilityWater_Objects.lua"
    utility_plumbing_path = server_root / "Water" / "RV_UtilityWater_Plumbing.lua"
    utility_store_path = server_root / "Core" / "RV_UtilityStore.lua"
    utility_power_path = server_root / "Power" / "RV_UtilityPower.lua"
    utility_power_devices_path = server_root / "Power" / "RV_UtilityPowerDevices.lua"
    utility_power_config_path = shared_root / "Power" / "RV_UtilityPowerConfig.lua"
    roof_devices_path = shared_root / "Roof" / "RV_RoofDevices.lua"
    roof_server_devices_path = server_root / "Roof" / "RV_Server_RoofDevices.lua"
    inventory_transaction_path = server_root / "Core" / "RV_ServerInventoryTransaction.lua"
    utility_timed_action_path = media_lua_root / "shared" / "TimedActions" / "ISRVUtilityAction.lua"
    generation_build_path = server_root / "Construction" / "RV_Server_GenerationBuild.lua"
    generation_flow_path = server_root / "Construction" / "RV_Server_GenerationFlow.lua"
    generation_ack_path = server_root / "Construction" / "RV_Server_GenerationAck.lua"
    generation_transaction_path = (
        server_root / "Construction" / "RV_Server_GenerationTransaction.lua"
    )
    construction_path = server_root / "Construction" / "RV_Construction.lua"
    core_path = server_root / "Core" / "RV_Server_Core.lua"
    player_validation_path = server_root / "Construction" / "RV_Server_PlayerValidation.lua"
    roof_destinations_path = server_root / "RoofRefresh" / "RV_RoofRefresh.lua"
    roof_relocation_path = server_root / "WallReloadProtection" / "RV_WallReloadProtection.lua"
    roof_api_path = server_root / "Roof" / "RV_Server_RoofDevices.lua"
    server_commands_path = server_root / "Core" / "RV_Server_Commands.lua"
    layout_builder_path = server_root / "RV_Server_LayoutBuilder.lua"
    layout_builder_client_path = client_root / "RV_ContextMenu_LayoutBuilder.lua"
    server_agent_path = server_root / "agent.md"
    room_ownership_path = server_root / "RoomOwnership" / "RV_Server_RoomOwnership.lua"
    record_validation_path = server_root / "RVMapping" / "RV_Server_RecordValidation.lua"
    adapter_roof_refresh_path = server_root / "WallReloadProtection" / "RV_RailroaderServer_WallReload.lua"
    adapter_roof_refresh_flow_path = server_root / "RoofRefresh" / "RV_RoofRefresh.lua"
    adapter_tick_path = server_root / "Core" / "RV_RailroaderServer_Tick.lua"
    adapter_mapping_path = server_root / "RVMapping" / "RV_RailroaderServer_Mapping.lua"
    client_room_ownership_path = client_root / "GUI" / "RV_ContextMenu_RoomOwnership.lua"
    client_relocation_path = client_root / "GUI" / "RV_ContextMenu_Relocation.lua"
    world_objects_path = server_root / "Construction" / "RV_Server_WorldObjects.lua"
    template_protection_repair_path = server_root / "TemplateRecovery" / "RV_Server_TemplateProtectionRepair.lua"
    template_recovery_index_path = server_root / "TemplateRecovery" / "RV_TemplateRecovery.lua"
    entry_exit_path = server_root / "RVMapping" / "RV_RailroaderServer_EntryExit.lua"
    boundary_objects_path = server_root / "DemolitionProtection" / "RV_BoundaryServer_Objects.lua"
    start_bat_path = root / "testserver" / "steamcmd" / "380870" / "StartServer64 - test.bat"
    runner_path = root / "testserver" / "run_test.py"
    testserver_agent_path = root / "testserver" / "agent.md"
    readme_path = root / "RailroaderRV" / "README.md"
    mod_info_path = package_root / "mod.info"

    checks = Checks()
    tests_dir = Path(__file__).resolve().parent
    checks.true(
        not any(tests_dir.glob("*.ps1")),
        "PowerShell test files are disabled; use the Python test instead",
    )
    checks.true(server_path.is_file(), f"server Lua is missing: {server_path}")
    checks.true(server_util_path.is_file(), f"server utility Lua is missing: {server_util_path}")
    checks.true(server_world_path.is_file(), f"server world Lua is missing: {server_world_path}")
    checks.true(server_schema_path.is_file(), f"server schema Lua is missing: {server_schema_path}")
    checks.true(client_path.is_file(), f"client Lua is missing: {client_path}")
    checks.true(
        railroader_server_path.is_file(),
        f"Railroader server adapter is missing: {railroader_server_path}",
    )
    checks.true(
        railroader_client_path.is_file(),
        f"Railroader client adapter is missing: {railroader_client_path}",
    )
    checks.true(constants_path.is_file(), f"shared constants Lua is missing: {constants_path}")
    checks.true(template_path.is_file(), f"captured RV template Lua is missing: {template_path}")
    checks.true(bitmap_path.is_file(), f"shared RV region-slot Lua is missing: {bitmap_path}")
    for current_contract_path in (
        generation_build_path,
        generation_flow_path,
        generation_ack_path,
        construction_path,
        core_path,
        player_validation_path,
        roof_destinations_path,
        server_commands_path,
        room_ownership_path,
        record_validation_path,
        client_room_ownership_path,
        client_relocation_path,
        world_objects_path,
        template_protection_repair_path,
        template_recovery_index_path,
        entry_exit_path,
        boundary_objects_path,
    ):
        checks.true(
            current_contract_path.is_file(),
            f"current RV contract Lua is missing: {current_contract_path}",
        )
    checks.true(
        boundary_server_path.is_file(),
        f"boundary server Lua is missing: {boundary_server_path}",
    )
    checks.true(
        boundary_client_path.is_file(),
        f"boundary client Lua is missing: {boundary_client_path}",
    )
    checks.true(
        boundary_wall_visuals_path.is_file(),
        f"boundary wall visual Lua is missing: {boundary_wall_visuals_path}",
    )
    checks.true(
        protected_demolition_path.is_file(),
        f"protected demolition Lua is missing: {protected_demolition_path}",
    )
    checks.true(
        wardrobe_visuals_path.is_file(),
        f"wardrobe visual Lua is missing: {wardrobe_visuals_path}",
    )
    for utility_path in (
        utility_catalog_path,
        utility_context_path,
        utility_client_path,
        utility_server_path,
        utility_water_path,
        utility_store_path,
        utility_power_path,
        utility_power_devices_path,
        utility_power_config_path,
        roof_devices_path,
        roof_server_devices_path,
        inventory_transaction_path,
        utility_timed_action_path,
    ):
        checks.true(utility_path.is_file(), f"utility Lua is missing: {utility_path}")
    checks.true(start_bat_path.is_file(), f"server launcher batch is missing: {start_bat_path}")

    module_owned_files = (
        (server_path, server_root / "Core"),
        (server_util_path, server_root / "Common"),
        (server_world_path, server_root / "Common"),
        (server_schema_path, server_root / "Common"),
        (client_path, client_root / "GUI"),
        (railroader_server_path, server_root / "Core"),
        (railroader_client_path, client_root / "GUI"),
        (constants_path, shared_root / "Common"),
        (bitmap_path, shared_root / "RVMapping"),
        (layout_path, shared_root / "RoomTemplate"),
        (template_path, shared_root / "RoomTemplate"),
        (room_template_path, shared_root / "RoomTemplate"),
        (mapping_path, server_root / "RVMapping"),
        (boundary_server_path, server_root / "BoundaryGuard"),
        (utility_catalog_path, shared_root / "Water"),
        (utility_power_config_path, shared_root / "Power"),
        (roof_devices_path, shared_root / "Roof"),
        (roof_server_devices_path, server_root / "Roof"),
        (inventory_transaction_path, server_root / "Core"),
        (utility_timed_action_path, media_lua_root / "shared" / "TimedActions"),
        (utility_water_path, server_root / "Water"),
        (utility_power_path, server_root / "Power"),
        (generation_flow_path, server_root / "Construction"),
        (room_ownership_path, server_root / "RoomOwnership"),
        (template_protection_repair_path, server_root / "TemplateRecovery"),
        (boundary_objects_path, server_root / "DemolitionProtection"),
    )
    checks.true(
        all(path.is_file() and path.parent == module_root
            for path, module_root in module_owned_files),
        "RV source implementations are missing from their declared owning modules",
    )

    # Sources that the code after the contract block still reads.  Keep them
    # defined for the incomplete-package case so a missing file produces an
    # explicit failure instead of an UnboundLocalError.
    generation_flow = (
        read_utf8(generation_flow_path) if generation_flow_path.is_file() else ""
    )

    if server_path.is_file() and client_path.is_file():
        server_facade = read_utf8(server_path)
        server_util = read_utf8(server_util_path) if server_util_path.is_file() else ""
        server_world = read_utf8(server_world_path) if server_world_path.is_file() else ""
        server_schema = read_utf8(server_schema_path) if server_schema_path.is_file() else ""
        generation_build = (
            read_utf8(generation_build_path) if generation_build_path.is_file() else ""
        )
        generation_flow = (
            read_utf8(generation_flow_path) if generation_flow_path.is_file() else ""
        )
        generation_ack = (
            read_utf8(generation_ack_path) if generation_ack_path.is_file() else ""
        )
        construction = (
            read_utf8(construction_path) if construction_path.is_file() else ""
        )
        core = read_utf8(core_path) if core_path.is_file() else ""
        player_validation = (
            read_utf8(player_validation_path)
            if player_validation_path.is_file()
            else ""
        )
        roof_destinations = (
            read_utf8(roof_destinations_path) if roof_destinations_path.is_file() else ""
        )
        server_commands = (
            read_utf8(server_commands_path) if server_commands_path.is_file() else ""
        )
        layout_builder = (
            read_utf8(layout_builder_path) if layout_builder_path.is_file() else ""
        )
        layout_builder_client = (
            read_utf8(layout_builder_client_path)
            if layout_builder_client_path.is_file()
            else ""
        )
        room_ownership = (
            read_utf8(room_ownership_path) if room_ownership_path.is_file() else ""
        )
        record_validation = (
            read_utf8(record_validation_path) if record_validation_path.is_file() else ""
        )
        client_room_ownership = (
            read_utf8(client_room_ownership_path)
            if client_room_ownership_path.is_file()
            else ""
        )
        client_relocation_source = (
            read_utf8(client_relocation_path)
            if client_relocation_path.is_file()
            else ""
        )
        world_objects = (
            read_utf8(world_objects_path) if world_objects_path.is_file() else ""
        )
        template_protection_repair = (
            read_utf8(template_protection_repair_path) if template_protection_repair_path.is_file() else ""
        )
        template_recovery_index = (
            read_utf8(template_recovery_index_path)
            if template_recovery_index_path.is_file()
            else ""
        )
        # Existing contract checks intentionally inspect one logical server
        # surface.  Include each require chunk, then normalize only the
        # private module qualifier so assertions continue to cover helpers
        # after the split.  Dedicated checks below still verify the facade's
        # imports and per-chunk local budgets.
        server = "\n".join((server_util, server_world, server_schema, server_facade))
        server = re.sub(r"\bServer(?:Util|World|Schema)\.", "", server)
        client = read_utf8(client_path)
        railroader_server = (
            read_utf8(railroader_server_path)
            if railroader_server_path.is_file()
            else ""
        )
        railroader_client = aggregate_lua_sources(
            [railroader_client_path]
            + sorted(railroader_client_path.parent.glob("RV_RailroaderContextMenu_*.lua"))
        )
        bitmap = read_utf8(bitmap_path) if bitmap_path.is_file() else ""
        mapping = read_utf8(mapping_path) if mapping_path.is_file() else ""
        boundary_geometry = (
            read_utf8(boundary_geometry_path)
            if boundary_geometry_path.is_file()
            else ""
        )
        region_slots = read_utf8(region_slots_path) if region_slots_path.is_file() else ""
        wall_reload_source = (
            read_utf8(roof_relocation_path) if roof_relocation_path.is_file() else ""
        )
        server_world = read_utf8(server_world_path) if server_world_path.is_file() else ""
        player_validation = (
            read_utf8(player_validation_path)
            if player_validation_path.is_file()
            else ""
        )
        generation_transaction = (
            read_utf8(generation_transaction_path)
            if generation_transaction_path.is_file()
            else ""
        )
        utility_water_objects = (
            read_utf8(utility_objects_path) if utility_objects_path.is_file() else ""
        )
        utilities_only = "\n".join((
            constants, region_slots, server_util, server_world,
            generation_transaction,
        ))
        server_agent_doc = (
            read_utf8(server_agent_path) if server_agent_path.is_file() else ""
        )
        boundary_sweep = (
            read_utf8(boundary_sweep_path)
            if boundary_sweep_path.is_file()
            else ""
        )
        captured_template = read_utf8(template_path) if template_path.is_file() else ""
        room_template = read_utf8(room_template_path) if room_template_path.is_file() else ""
        layout = read_utf8(layout_path) if layout_path.is_file() else ""
        captured_template_rows = re.findall(
            r"(?m)^\s*\{x=-?\d+,\s*y=-?\d+,\s*z=-?\d+,\s*class=",
            captured_template,
        )
        template_object_pattern = re.compile(
            r'^\s*\{x=(?P<x>-?\d+), y=(?P<y>-?\d+), z=(?P<z>-?\d+), '
            r'class="(?P<class>[^"]+)", name="(?P<name>[^"]+)", '
            r'sprite="(?P<sprite>[^"]+)"(?:, north=(?P<north>true|false))?, '
            r'direction="(?P<direction>[^"]+)",\s*'
            r'state=\{(?P<state>[^}]*)\}\},?\s*$',
            re.MULTILINE,
        )
        captured_template_objects = [
            match.groupdict()
            for line in captured_template.splitlines()
            if (match := template_object_pattern.match(line)) is not None
        ]
        try:
            compiled_template_objects = compile_current_room_template(shared_root.parent)
            compiled_template_metadata = compile_current_template_metadata(shared_root.parent)
            variant_contracts = compile_template_variant_contracts(
                shared_root.parent, server_root.parent
            )
        except Exception as error:
            # The embedded Lua runtime and the shared template compiler are
            # external dependencies of this harness: a broken template must be
            # reported as a contract failure instead of a raw traceback.  The
            # substitutes keep the same shapes so the contracts below fail
            # explicitly rather than raising a secondary KeyError/TypeError.
            compiled_template_objects = []
            compiled_template_metadata = {
                "templateVersion": None,
                "objectCount": None,
                "currentTemplateVersion": None,
            }
            variant_contracts = None
            checks.true(
                False,
                "shared RoomTemplate/layout and server consumers cannot be loaded "
                "by the local Lua runtime: "
                f"{type(error).__name__}: {error}",
            )
        if variant_contracts is not None:
            def lua_rows(value):
                return [value[index] for index in range(1, len(value) + 1)]

            base_cells = {
                (int(cell["x"]), int(cell["y"]), int(cell["z"] or 0))
                for cell in lua_rows(variant_contracts["baseCells"])
            }
            engine_cells = {
                (int(cell["x"]), int(cell["y"]), int(cell["z"] or 0))
                for cell in lua_rows(variant_contracts["engineCells"])
            }
            base_cell_rows = lua_rows(variant_contracts["baseCells"])
            engine_cell_rows = lua_rows(variant_contracts["engineCells"])
            engine_roof_rows = lua_rows(variant_contracts["engineRoofCells"])
            engine_roof_projection_rows = [
                cell for cell in engine_roof_rows if int(cell["z"]) == 1
            ]
            engine_roof_projection = {
                (int(cell["x"]), int(cell["y"]), 0)
                for cell in engine_roof_projection_rows
            }
            base_proxy_rows = lua_rows(variant_contracts["baseProxies"])
            engine_proxy_rows = lua_rows(variant_contracts["engineProxies"])
            engine_rect_rows = lua_rows(variant_contracts["engineBuildRects"])
            engine_rects = {
                (
                    int(rect["minX"]),
                    int(rect["maxXExclusive"]),
                    int(rect["minY"]),
                    int(rect["maxYExclusive"]),
                )
                for rect in engine_rect_rows
            }
            engine_rect_cells = [
                (x, y, 0)
                for rect in engine_rect_rows
                for y in range(int(rect["minY"]), int(rect["maxYExclusive"]))
                for x in range(int(rect["minX"]), int(rect["maxXExclusive"]))
            ]
            engine_rect_union = set(engine_rect_cells)
            engine_rect_area = sum(
                (int(rect["maxXExclusive"]) - int(rect["minX"]))
                * (int(rect["maxYExclusive"]) - int(rect["minY"]))
                for rect in engine_rect_rows
            )
            base_proxies = {
                (int(proxy["x"]), int(proxy["y"]), int(proxy["z"]), int(proxy["buildZ"]))
                for proxy in lua_rows(variant_contracts["baseProxies"])
            }
            engine_proxies = {
                (int(proxy["x"]), int(proxy["y"]), int(proxy["z"]), int(proxy["buildZ"]))
                for proxy in lua_rows(variant_contracts["engineProxies"])
            }
            engine_layout_proxies = {
                (int(proxy["x"]) - 20050, int(proxy["y"]) - 2050,
                    int(proxy["z"]), int(proxy["buildZ"]))
                for proxy in lua_rows(variant_contracts["engineLayoutProxies"])
            }
            base_layout_proxies = {
                (int(proxy["x"]) - 20050, int(proxy["y"]) - 2050,
                    int(proxy["z"]), int(proxy["buildZ"]))
                for proxy in lua_rows(variant_contracts["baseLayoutProxies"])
            }
            expected_base_cells = {
                (x, y, 0) for x in range(-4, 2) for y in range(-2, 2)
            }
            expected_engine_rects = {
                (-2, 0, -5, -4),
                (-3, 1, -4, -2),
                (-4, 2, -2, 2),
                (-3, 1, 2, 15),
                (-2, 0, 15, 16),
            }
            expected_base_proxies = {
                (x, y, 1, 0)
                for x in (-3, 0)
                for y in (-2, 1)
            }
            expected_engine_proxies = {
                (x, y, 1, 0)
                for x in (-3, 0)
                for y in (-5, -2, 1, 4, 7, 10, 13, 16)
            }
            checks.true(
                variant_contracts["disabledSelection"] == variant_contracts["baseId"]
                and variant_contracts["enabledSelection"] == variant_contracts["engineId"]
                and variant_contracts["baseLayoutId"] == variant_contracts["baseId"]
                and variant_contracts["engineLayoutId"] == variant_contracts["engineId"]
                and bool(variant_contracts["omittedTemplateIdRejected"]),
                "template selection or mandatory layout template ID contract is incorrect",
            )
            checks.true(
                base_cells == expected_base_cells
                and len(base_cell_rows) == 24
                and base_proxies == expected_base_proxies
                and len(base_proxy_rows) == 4
                and base_layout_proxies == expected_base_proxies
                and len(engine_proxy_rows) == 16
                and len(engine_cell_rows) == 88
                and len(engine_cells) == 88
                and len(engine_roof_projection_rows) == 88
                and len(engine_roof_projection) == 88
                and engine_rects == expected_engine_rects
                and len(engine_rect_rows) == 5
                and engine_rect_area == 88
                and len(engine_rect_cells) == len(engine_rect_union) == 88
                and engine_rect_union == engine_roof_projection == engine_cells
                and bool(variant_contracts["engineCellsMatchBuildRects"])
                and bool(variant_contracts["engineCellsMatchRoofProjection"])
                and int(variant_contracts["engineRectCellCount"]) == 88
                and int(variant_contracts["engineRectArea"]) == 88
                and int(variant_contracts["engineRectCount"]) == 5
                and int(variant_contracts["engineRoofCellCount"]) == 88
                and int(variant_contracts["engineRoofProjectionCount"]) == 88
                and engine_proxies == expected_engine_proxies
                and engine_layout_proxies == expected_engine_proxies,
                "real Lua templates do not expose the 24/4 cab mask and the five-rectangle 88/16 roof projection mask",
            )
            checks.true(
                bool(variant_contracts["engineCellsInsideWalk"])
                and int(variant_contracts["coveredEngineCells"]) == 88
                and int(variant_contracts["engineWalkAabb"]["minX"]) == -4
                and int(variant_contracts["engineWalkAabb"]["maxX"]) == 2
                and int(variant_contracts["engineWalkAabb"]["minY"]) == -6
                and int(variant_contracts["engineWalkAabb"]["maxY"]) == 17,
                "engine-area roof-projection cells escape the captured interior or lack water coverage",
            )
            checks.true(
                bool(variant_contracts["separateTemplateObjects"])
                and bool(variant_contracts["separateWaterProxyLists"])
                and bool(variant_contracts["objectsSameExceptProtection"])
                and int(variant_contracts["changedProtectionFlags"]) > 0
                and bool(variant_contracts["sameManaged"]),
                "pre-registered templates are not separate complete contracts with unchanged shell data",
            )
            checks.true(
                variant_contracts["baseBoundaryId"] == variant_contracts["baseId"]
                and variant_contracts["engineBoundaryId"] == variant_contracts["engineId"]
                and bool(variant_contracts["baseCabColumnHasProtectedLayer"])
                and bool(variant_contracts["corridorHeadProtectionQueued"])
                and bool(variant_contracts["generatorProxyColumnProtected"])
                and bool(variant_contracts["addedWaterProxyColumnProtected"]),
                "boundary cache or protection repair does not follow persisted template IDs",
            )
            checks.true(
                bool(variant_contracts["engineRoofBuildable"])
                and bool(variant_contracts["engineCorridorHeadWalkable"])
                and bool(variant_contracts["engineCorridorTailWalkable"])
                and not bool(variant_contracts["engineCorridorHeadBuildable"])
                and not bool(variant_contracts["engineCorridorTailBuildable"])
                and bool(variant_contracts["corridorHeadTemplateObjectProtected"])
                and not bool(variant_contracts["roofAdditionTemplateObjectProtected"])
                and bool(variant_contracts["corridorDemolitionBlocked"])
                and not bool(variant_contracts["roofDemolitionBlocked"])
                and bool(variant_contracts["boundaryWindowIsSideHost"])
                and variant_contracts["boundaryWindowProtected"] is False
                and not bool(variant_contracts["boundaryWindowDemolitionBlocked"]),
                "build/demolition permission does not follow the selected roof projection while retaining only the door/window side-host exception",
            )
            checks.true(
                bool(variant_contracts["corridorRepairChanged"])
                and bool(variant_contracts["corridorTemplateRestoreRequested"])
                and int(variant_contracts["corridorTemplateRestoreCalls"]) > 0
                and bool(variant_contracts["roofAdditionRoofTemplateObjectProtected"])
                and bool(variant_contracts["roofBuildSquaresAvailable"])
                and not bool(variant_contracts["roofRepairChanged"])
                and int(variant_contracts["roofProjectionRestoreCalls"]) == 0
                and bool(variant_contracts["roofBuildCellSkipsTemplateRestore"]),
                "template protection repair does not restore corridor objects and skip selected-template build cells",
            )
            checks.true(
                bool(variant_contracts["baseScan"]["scanned"])
                and bool(variant_contracts["engineScan"]["scanned"])
                and int(variant_contracts["baseScan"]["buildDeviceCount"]) == 0
                and int(variant_contracts["engineScan"]["buildDeviceCount"]) == 1,
                "power-device scan does not sample only the selected template's build mask",
            )
        compiled_protected_by_index = {
            int(obj["index"]): bool(obj["protected"])
            for obj in compiled_template_objects
        }
        # Every per-index lookup below assumes the captured rows and the compiled
        # objects share one index range; a mismatch must fail the related contract
        # instead of raising KeyError and hiding all other results.
        template_index_aligned = (
            len(captured_template_objects) == len(compiled_template_objects)
            and sorted(compiled_protected_by_index)
            == list(range(1, len(captured_template_objects) + 1))
        )
        checks.true(
            template_index_aligned,
            "captured RV template rows are not index-aligned with the compiled "
            "RoomTemplate objects",
        )
        protection_identity_matches_template = (
            len(captured_template_objects) == 412
            and len(compiled_template_objects) == 412
            and all(
                (
                    int(captured[field]) == compiled[field]
                    if field in {"x", "y", "z"}
                    else captured[field] == compiled[field]
                )
                for captured, compiled in zip(captured_template_objects, compiled_template_objects)
                for field in ("x", "y", "z", "class", "name", "sprite", "direction")
            )
            and all(
                (captured["north"] == "true") is compiled["north"]
                if captured["north"] is not None
                else compiled["north"] is None
                for captured, compiled in zip(captured_template_objects, compiled_template_objects)
            )
            and all(
                parse_template_state(captured["state"]) == compiled["state"]
                for captured, compiled in zip(captured_template_objects, compiled_template_objects)
            )
        )
        protected_count = sum(compiled_protected_by_index.values())
        free_count = len(compiled_protected_by_index) - protected_count
        cab_classes_match = len(compiled_template_objects) == 412 and template_index_aligned and all(
            not compiled_protected_by_index[index]
            for index, obj in enumerate(captured_template_objects, 1)
            if int(obj["z"]) == 0
            and -4 <= int(obj["x"]) <= 1
            and -2 <= int(obj["y"]) <= 1
        )
        east_cab_objects = [
            (index, obj)
            for index, obj in enumerate(captured_template_objects, 1)
            if int(obj["z"]) == 0
            and int(obj["x"]) == 2
            and -2 <= int(obj["y"]) <= 1
        ]
        east_cab_classes_match = len(compiled_template_objects) == 412 \
            and template_index_aligned \
            and len(east_cab_objects) == 6 \
            and all(
                compiled_protected_by_index[index]
                    == (obj["name"] == "Wooden Wall")
                and obj["name"] in {"Wooden Wall", "Window"}
                for index, obj in east_cab_objects
            )
        south_shell_floors_stay_protected = len(compiled_template_objects) == 412 and template_index_aligned and all(
            compiled_protected_by_index[index]
            for index, obj in enumerate(captured_template_objects, 1)
            if int(obj["z"]) == 0
            and int(obj["x"]) in {-4, -3, -2, -1, 0, 1}
            and int(obj["y"]) == 2
            and obj["class"] == "IsoObject"
        )
        cab_opening_objects_outside_build_cells = [
            (index, obj)
            for index, obj in enumerate(captured_template_objects, 1)
            if (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["name"])
            in {
                (-4, 2, 0, "Window"),
                (1, 2, 0, "Wooden Door Frame"),
                (1, 2, 0, "Wooden Door"),
            }
        ]
        northwest_support_classes = [
            compiled_protected_by_index[index]
            for index, obj in enumerate(captured_template_objects, 1)
            if template_index_aligned
            and obj["name"] == "Wooden Wall"
            and (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
            in {(-4, -6, 0, "true"), (-4, -6, 0, "false")}
            and obj["sprite"] in {
                "walls_interior_house_02_32", "walls_interior_house_02_33"
            }
        ]
        protected_activity_corner_walls = [
            obj for obj in captured_template_objects
            if obj["name"] == "Wooden Wall"
            and (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
            in {
                (-4, 16, 0, "false"),
                (2, -6, 0, "false"),
                (2, 16, 0, "false"),
                (2, 17, 0, "false"),
            }
            and "doRender=false" in obj["state"]
            and "hoppable=false" in obj["state"]
        ]
        protected_wardrobe_tiles = [
            obj for obj in captured_template_objects
            if obj["name"] == "Dark Fancy Wardrobe"
            and obj["sprite"] in {"furniture_storage_01_24", "furniture_storage_01_25"}
        ]
        west_cab_wall_tiles = [
            obj for obj in captured_template_objects
            if obj["name"] == "Wooden Wall"
            and int(obj["x"]) == -4
            and int(obj["y"]) in {-2, -1, 0, 1}
            and int(obj["z"]) == 0
            and obj["north"] == "false"
        ]
        fence_sprites = {"fixtures_railings_01_36", "fixtures_railings_01_37"}
        fence_rows = [
            obj for obj in captured_template_objects
            if obj["class"] == "IsoThumpable" and obj["sprite"] in fence_sprites
        ]
        fence_keys = {
            (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
            for obj in fence_rows
        }
        wall_rows_by_key: dict[tuple[int, int, int, str | None], list[dict[str, str | None]]] = {}
        for obj in captured_template_objects:
            if obj["class"] != "IsoThumpable" or obj["name"] != "Wooden Wall":
                continue
            key = (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
            wall_rows_by_key.setdefault(key, []).append(obj)
        perimeter_keys = {
            *((x, -6, 0, "true") for x in range(-4, 2)),
            *((-4, y, 0, "false") for y in range(-6, 17)),
            *((2, y, 0, "false") for y in range(-6, 17)),
            *((x, 17, 0, "true") for x in range(-4, 2)),
            (2, 17, 0, "false"),
        }
        paired_keys = fence_keys & set(wall_rows_by_key)
        off_boundary_fence_keys = paired_keys - perimeter_keys
        boundary_fence_keys = paired_keys & perimeter_keys
        hidden_boundary_wall_rows = [
            wall
            for key in boundary_fence_keys
            for wall in wall_rows_by_key[key]
        ]
        expected_off_boundary_fence_keys = {
            (-4, -5, 0, "true"),
            (-4, 16, 0, "true"),
            (1, -5, 0, "true"),
            (1, 16, 0, "true"),
        }
        captured_shell_cells = {
            (int(x), int(y))
            for x, y in re.findall(
                r'(?m)^\s*\{x=(-?\d+), y=(-?\d+), z=0, '
                r'class="(?:IsoThumpable|IsoWindow)", '
                r'name="(?:Wooden Wall|Wooden Door Frame|Wooden Door|Window)",',
                captured_template,
            )
        }
        captured_roof_cells = {
            (int(x), int(y))
            for x, y in re.findall(
                r"(?m)^\s*\{x=(-?\d+), y=(-?\d+), z=1, class=",
                captured_template,
            )
        }
        roof_field_match = re.search(
            r"(?s)local roofCells = \{(.*?)\n\}", captured_template
        )
        declared_roof_cell_rows = re.findall(
            r"\{ x = (-?\d+), y = (-?\d+), z = (-?\d+) \}",
            roof_field_match.group(1) if roof_field_match else "",
        )
        declared_roof_cells = {
            (int(x), int(y), int(z)) for x, y, z in declared_roof_cell_rows
        }
        captured_template_coordinate_rows = re.findall(
            r'(?m)^\s*\{x=(-?\d+), y=(-?\d+), z=(-?\d+), '
            r'class="([^"]+)", name="([^"]*)", sprite="([^"]+)"',
            captured_template,
        )
        checks.true(
            bool(captured_template_coordinate_rows),
            "captured RV template exposes no parseable object coordinate rows",
        )
        captured_top_z = max(
            (int(row[2]) for row in captured_template_coordinate_rows),
            default=None,
        )
        captured_top_roof_rows = [
            row for row in captured_template_coordinate_rows
            if int(row[2]) == captured_top_z
        ]
        northwest_west_wall_rows = [
            obj for obj in captured_template_objects
            if (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
            == (-4, -6, 0, "false")
            and obj["class"] == "IsoThumpable"
            and obj["name"] == "Wooden Wall"
            and obj["sprite"] == "walls_interior_house_02_32"
            and "doRender=false" in obj["state"]
            and "hoppable=false" in obj["state"]
        ]
        northwest_north_wall_rows = [
            obj for obj in captured_template_objects
            if (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
            == (-4, -6, 0, "true")
            and obj["class"] == "IsoThumpable"
            and obj["name"] == "Wooden Wall"
            and obj["sprite"] == "walls_interior_house_02_33"
            and "doRender=false" in obj["state"]
            and "hoppable=false" in obj["state"]
        ]
        boundary_server = (
            read_utf8(boundary_server_path) if boundary_server_path.is_file() else ""
        )
        boundary_objects = (
            read_utf8(boundary_objects_path) if boundary_objects_path.is_file() else ""
        )
        boundary_client = (
            read_utf8(boundary_client_path) if boundary_client_path.is_file() else ""
        )
        boundary_wall_visuals = (
            read_utf8(boundary_wall_visuals_path)
            if boundary_wall_visuals_path.is_file()
            else ""
        )
        protected_demolition = (
            read_utf8(protected_demolition_path)
            if protected_demolition_path.is_file()
            else ""
        )
        wardrobe_visuals = (
            read_utf8(wardrobe_visuals_path)
            if wardrobe_visuals_path.is_file()
            else ""
        )
        entry_exit = read_utf8(entry_exit_path) if entry_exit_path.is_file() else ""
        utility_catalog = (
            read_utf8(utility_catalog_path) if utility_catalog_path.is_file() else ""
        )
        utility_constants = (
            read_utf8(utility_constants_path)
            if utility_constants_path.is_file() else ""
        )
        utility_context = (
            read_utf8(utility_context_path) if utility_context_path.is_file() else ""
        )
        utility_client = (
            read_utf8(utility_client_path) if utility_client_path.is_file() else ""
        )
        utility_server = (
            read_utf8(utility_server_path) if utility_server_path.is_file() else ""
        )
        utility_water = (
            read_utf8(utility_water_path) if utility_water_path.is_file() else ""
        )
        utility_water_commands = (
            read_utf8(utility_water_commands_path)
            if utility_water_commands_path.is_file() else ""
        )
        utility_water_ledger = (
            read_utf8(utility_water_ledger_path)
            if utility_water_ledger_path.is_file() else ""
        )
        utility_objects = (
            read_utf8(utility_objects_path) if utility_objects_path.is_file() else ""
        )
        utility_plumbing = (
            read_utf8(utility_plumbing_path) if utility_plumbing_path.is_file() else ""
        )
        utility_store = (
            read_utf8(utility_store_path) if utility_store_path.is_file() else ""
        )
        utility_power = (
            read_utf8(utility_power_path) if utility_power_path.is_file() else ""
        )
        utility_timed_action = (
            read_utf8(utility_timed_action_path)
            if utility_timed_action_path.is_file() else ""
        )

        lua_server_root = server_root
        lua_client_root = client_root
        railroader_server = aggregate_lua_sources(
            [railroader_server_path]
            + sorted(server_root.rglob("RV_RailroaderServer_*.lua"))
        )
        boundary_server = aggregate_lua_sources(
            sorted(boundary_server_path.parent.glob("RV_BoundaryServer*.lua"))
            + [boundary_objects_path]
        )
        boundary_client = aggregate_lua_sources(
            [boundary_client_path, boundary_wall_visuals_path, wardrobe_visuals_path]
        )
        generation_flow_source = read_utf8(generation_flow_path) if generation_flow_path.is_file() else ""
        generation_ack_source = read_utf8(generation_ack_path) if generation_ack_path.is_file() else ""
        player_validation_source = read_utf8(player_validation_path) if player_validation_path.is_file() else ""
        roof_relocation_source = read_utf8(roof_relocation_path) if roof_relocation_path.is_file() else ""
        roof_api_source = read_utf8(roof_api_path) if roof_api_path.is_file() else ""
        adapter_roof_refresh_source = read_utf8(adapter_roof_refresh_path) if adapter_roof_refresh_path.is_file() else ""
        adapter_roof_refresh_flow_source = read_utf8(adapter_roof_refresh_flow_path) if adapter_roof_refresh_flow_path.is_file() else ""
        adapter_tick_source = read_utf8(adapter_tick_path) if adapter_tick_path.is_file() else ""
        adapter_mapping_source = read_utf8(adapter_mapping_path) if adapter_mapping_path.is_file() else ""
        # Keep the logical server surface complete as the codebase is split
        # into focused modules.  A hand-maintained list silently dropped the
        # roof, mapping, utility, and adapter chunks from older contracts.
        server_contract_paths = sorted(lua_server_root.rglob("*.lua"))
        server = aggregate_lua_sources(server_contract_paths)
        server = re.sub(r"\bServer(?:Util|World|Schema)\.", "", server)
        client = aggregate_lua_sources(
            sorted(lua_client_root.rglob("*.lua"))
        )

        checks.true(
            'require("RailroaderRV/Common/RV_ServerUtil")' in server_facade
            and 'require("RailroaderRV/Common/RV_ServerWorld")' in server_facade
            and 'require("RailroaderRV/Common/RV_ServerSchema")' in server_facade,
            "RV_Server facade does not load the split utility/world/schema modules",
        )
        local_budgets = (
            ("RV_Server.lua", server_path),
            ("RV_ServerUtil.lua", server_util_path),
            ("RV_ServerWorld.lua", server_world_path),
            ("RV_ServerSchema.lua", server_schema_path),
            ("RV_RailroaderServer.lua", railroader_server_path),
        )
        for label, lua_file in local_budgets:
            local_count = lua_top_level_local_count(root, lua_file)
            checks.true(
                local_count is not None and local_count < 200,
                f"{label} exceeds or cannot prove the Kahlua main-chunk local budget: {local_count}",
            )

        checks.true(
            all(token in utility_catalog for token in (
                'M.WATER_TAG_KEY = "RailroaderRVWater"',
                'tag.owner ~= C.MOD_ID or tag.role ~= "sink"',
                'type(tag.rvId) ~= "string"',
                'integer(tag.generation) == nil',
                'integer(tag.slotIndex) == nil',
                "function M.readSinkIdentity", "function M.isCurrentWaterSink",
                "function M.isWaterPipedDevice", "function M.hasFluidContainer",
                "flags.waterPiped", "data.canBeWaterPiped == true",
            ))
            and "UTILITY_ROLE_PROXY" not in utility_catalog
            and "proxyFingerprint" not in utility_catalog,
            "Water catalog does not enforce the new exact RV mapping identity and native sink capability",
        )
        water_options = section(
            utility_context,
            r"local function addWaterOptions",
            r"local function addDashboardOption",
        )
        checks.true(
            water_options is not None
            and "hasPipeWrench(player)" in utility_context
            and "localSlot(player, x, y, z)" in water_options
            and "Catalog.isCurrentWaterSink(object)" in water_options
            and "Catalog.isWaterPipedDevice(object)" in water_options
            and "Client.requestWaterConnection" in utility_context,
            "client water menu does not limit requests to reachable native sinks in an RV matrix slot",
        )
        checks.true(
            "function Client.requestWaterConnection" in utility_client
            and "hint.connected = connected" in utility_client
            and "U.OP_CONNECT_WATER_DEVICE" in utility_client
            and "return { x = x, y = y, z = z, objectIndex = index }" in utility_client
            and all(field not in utility_client for field in (
                "hint.rvId", "hint.generation", "hint.slotIndex", "hint.anchor",
            )),
            "client Water intent includes trusted RV identity or omits the target-only hint",
        )
        water_resolution = section(
            utility_objects,
            r"function M\.resolveSink",
            r"function M\.ensureSinkIdentity",
        )
        checks.true(
            water_resolution is not None
            and 'exactKeys(hint, { "x", "y", "z", "objectIndex", "connected" })' in utility_objects
            and "validContext(context, identity)" in water_resolution
            and "RegionSlots.indexToAnchor(slotIndex)" in utility_objects
            and "RegionSlots.indexToRegion(slotIndex)" in utility_objects
            and "if x < region.minX" in water_resolution
            and "withinReach(context.player, x, y, z)" in water_resolution
            and "World.getSquare(cell, x, y, z)" in water_resolution
            and "findHintedObject(square, objectIndex)" in water_resolution
            and "Catalog.hasFluidContainer(object)" in water_resolution
            and "Catalog.isCurrentWaterSink(object, identity, record)" in water_resolution,
            "server does not re-resolve and validate the sink against current Mapping, range, loaded square, and exact identity",
        )
        checks.true(
            "function M.setConnection" in utility_water_commands
            and "hasPipeWrench(context and context.player)" in utility_water_commands
            and "Objects.resolveSink(identity, context, hint)" in utility_water_commands
            and "Objects.ensureSinkIdentity" in utility_water_commands
            and "Plumbing.apply(sink.object, desired)" in utility_water_commands
            and "Store.commit(record, identity)" in utility_water_commands
            and utility_water_commands.find("Objects.resolveSink(identity, context, hint)")
                < utility_water_commands.find("Plumbing.apply(sink.object, desired)")
            and utility_water_commands.find("Plumbing.apply(sink.object, desired)")
                < utility_water_commands.find("Store.commit(record, identity)"),
            "Water connect/disconnect lacks authoritative tool, identity, commit, and compensation gates",
        )
        checks.true(
            all(token in utility_plumbing for token in (
                '"getUsesExternalWaterSource"', '"setUsesExternalWaterSource"',
                '"sendObjectChange"', '"usesExternalWaterSource"',
                "canBeWaterPiped", '"transmitModData"',
                "function M.apply", "observed.pipableFlag ~= pipableFlag",
            ))
            and "observed.connected ~= connected" in utility_plumbing,
            "native external-water state lacks synchronization, postcondition, or compensation checks",
        )
        water_validator = section(
            utility_store,
            r"local function validWater\(value, identity\)",
            r"local function validGenerator",
        )
        checks.true(
            water_validator is None
            and "local function newWater()" in utility_store
            and "sinks = {}," in utility_store
            and "roofCollectors = {}" in utility_store
            and "schemaVersion" not in utility_store
            and "local function newPower()" in utility_store
            and "deviceCache = { template = {}, build = {} }" in utility_store
            and "if allowCreate ~= true then error(\"RV utility record is missing\") end" in utility_store,
            "Utility storage must initialize current records without nested schema tags",
        )
        checks.true(
            "function M.getEntry" in utility_water_ledger
            and "function M.newEntry" in utility_water_ledger
            and "return Store.waterSinkKey(sink.x, sink.y, sink.z)" in utility_water_ledger
            and "connected = connected == true" in utility_water_ledger
            and "sequence = sequence or 0" in utility_water_ledger
            and all(token not in utility_water + utility_water_commands + utility_water_ledger + utility_objects + utility_plumbing + utility_store for token in (
                "canonicalTank", "usageTank", "proxyLedger", "proxyFingerprint",
                "rv_hidden_proxy", "rv_hidden_usage_tank", "oldTagAlias", "ADD_WATER",
            ))
            and all(token not in constants + utility_constants for token in (
                "UTILITY_TANK_OFFSET", "UTILITY_PROXY_Z_OFFSET", "UTILITY_ROLE_TANK",
                "UTILITY_ROLE_PROXY", "UTILITY_WATER_CAPACITY", "OP_ADD_WATER",
                "AUTO_REFILL_PROVIDER", "WATER_STATE_DEFERRED",
            ))
            and "function M.detachDevice" not in utility_water,
            "new Water ledger retains a deprecated hidden tank/proxy, inventory-transfer, or compatibility path",
        )
        checks.true(
            "OnObjectAdded" not in utility_server + utility_water + utility_water_commands
            and "Objects.ensureSinkIdentity" in utility_water_commands,
            "Water schema failures do not tell players to rebuild, or automatic sink tagging was added",
        )

        checks.true(
            all(token in bitmap for token in (
                "Slots.ROWS = C.RV_REGION_SLOT_ROWS",
                "Slots.COLUMNS = C.RV_REGION_SLOT_COLUMNS",
                "Slots.COUNT = C.RV_REGION_SLOT_COUNT",
                "local SIZE = Slots.REGION_SIZE",
                'error("RailroaderRV: RV region slot size must be 100")',
                "function Slots.indexToAnchor(index)",
                "function Slots.indexToRegion(index)",
                "function Slots.indexForAnchor(anchor)",
                "function Slots.findFirstFree(regions)",
                'return nil, "overlapping-regions"',
                'return nil, "no-free-slot"',
            ))
            and "schemaVersion" not in bitmap
            and all(token not in bitmap for token in (
                "segmentValid", "nearestActive", "local function addTime",
                "local function sortUniqueTimes", "BITMAP_VERSION", "newBitset",
            )),
            "shared RV bitmap contract is incomplete or retains movement-history helpers",
        )
        checks.true(
            "local function makeBoundary(layout, rvId, generation)" in boundary_geometry
            and "local layout = Layout.make(anchor.x, anchor.y, anchor.z,\n        record.templateId)" in boundary_geometry
            and "Boundary.boundaryFor = boundaryFor" in boundary_geometry
            and "schemaVersion" not in boundary_geometry
            and "bitmapVersion" not in boundary_geometry
            and "integer(managed.originX) ~= integer(bitmap.originX)" not in boundary_geometry
            and "not exactKeys(edge, fields)" not in boundary_geometry,
            "bitmap codec retained a persisted schema-version or geometry cross-check",
        )
        checks.true(
            "function M.profileAdd" not in utility_catalog
            and "function M.profileSubtract" not in utility_catalog
            and "function M.entryIsValidated" not in utility_catalog
            and "function Boundary.managedContains" not in boundary_server
            and "function M.isLocked" not in utility_server
            and "function M.setPlayerContext" not in utility_water
            and "function M.emergencyQuarantine" not in utility_water
            and "emergency" not in utility_water
            and "local function fixtureTag" not in utility_water
            and "local function playerForObject" not in utility_client
            and "getLastAck" not in utility_client
            and "_sessionNonce" not in utility_client
            and "lastAck" not in utility_client
            and "playerFloor" not in read_utf8(layout_path)
            and 'local C = require("RailroaderRV/RV_Constants")' not in read_utf8(utility_context_path)
            and 'local C = require("RailroaderRV/Common/RV_Constants")' in read_utf8(
                utility_power_path
            )
            and "local proxy = RoomTemplate.get(mappingRecord.templateId).powerProxy"
                in read_utf8(utility_power_path)
            and "math.floor(position.x) + proxy.x" in read_utf8(utility_power_path)
            and "C.GENERATOR_INITIAL_FUEL" in read_utf8(utility_power_path),
            "retired internal APIs, dead helpers, diagnostic state, or redundant requires remain",
        )
        checks.true(
            all(token in read_utf8(
                shared_root / "RoomTemplate" / "RV_TemplateGeometry.lua"
            ) for token in (
                'elseif side == "east" or side == "E" then',
                'return G.edgeKey("W", x + 1, y, z)',
                'elseif side == "south" or side == "S" then',
                'return G.edgeKey("N", x, y + 1, z)',
            ))
            and "shellEdgeKeysForAction" in boundary_server
            and "direct = TemplateGeometry.edgeForSide(axis, x, y, z)" in boundary_server,
            "east/south shell ownership does not use adjacent PZ W/N hosts",
        )
        checks.true(
            all(token in read_utf8(
                shared_root / "RoomTemplate" / "RV_TemplateGeometry.lua"
            ) for token in (
                'return axis .. ":" .. tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)',
                "if not axis or not integer(x) or not integer(y) or not integer(z) then",
            ))
            and '"^(N|W):' not in server
            and '"^(N|W):' not in boundary_server,
            "shell edge validators use unsupported Lua pattern alternation",
        )
        update_guard = section(
            boundary_geometry,
            r"local function guardContextForPlayer",
            r"\n\nctx\.number",
        )
        fresh_boundary_position = section(
            boundary_geometry,
            r"local function playerPosition",
            r"\n\nlocal function playerCell",
        )
        checks.true(
            update_guard is not None
            and "local boundary, record, relation, id = Boundary.boundaryForPlayer(player,"
                in update_guard
            and "knownIdentity, deferValidationMiss, forceValidationRefresh)" in update_guard
            and "relation.inside ~= true" in update_guard
            and 'or type(rider) ~= "table" or rider.inside ~= true then' in update_guard
            and "currentOnlineId == nil" in update_guard
            and 'if type(position) ~= "table" or not currentSquareMatches(player, position) then'
                in update_guard
            and update_guard.find("relation.inside ~= true")
                < update_guard.find("local state = stateFor(player, id)")
            and update_guard.find("Boundary.boundaryForPlayer(player,")
                < update_guard.find(
                    'if type(position) ~= "table" or not currentSquareMatches(player, position) then'
                )
            and all(token not in update_guard for token in (
                "Bitmap.walkBounds", "Bitmap.walkableFast", "Bitmap.isActive",
                "segmentValid", "nearestActive",
            ))
            and all(token not in boundary_geometry for token in (
                "lastValid", "lastPosition", "invalidSegment",
                "lastObservedBoundaryTick", "nextValidRecordTick",
                "recoveryCooldown", "BOUNDARY_RECOVERY_COOLDOWN_TICKS",
                "copyPosition", "segmentValid", "Bitmap.nearestActive",
            ))
            and "elseif state.lastValid ~= nil then" in boundary_sweep
            and "correctOutside(state, player, boundary, record, onlineId)" in boundary_sweep
            and "TemplateGeometry.isWalkableInManagedRegion(position," in boundary_sweep
            and "boundary.managed, template)" in boundary_sweep
            and "BOUNDARY_RECOVERY_COOLDOWN_TICKS" not in constants,
            "server boundary guard does not validate inside identity and defer safe entry correction",
        )
        checks.true(
            fresh_boundary_position is not None
            and all(token in fresh_boundary_position for token in (
                'call(player, "getX")', 'call(player, "getY")',
                'call(player, "getZ")', "finiteNumber(x)", "finiteNumber(y)",
                "finiteNumber(z)", "return { x = x, y = y, z = z }",
                "local inRVRegion =", "C.RV_REGION_SIZE * C.RV_REGION_SLOT_COLUMNS",
                "C.RV_REGION_SIZE * C.RV_REGION_SLOT_ROWS",
            )),
            "boundary guard does not read finite authoritative server positions",
        )
        checks.true(
            fresh_boundary_position is not None
            and "Boundary._states[id.key] == nil" not in fresh_boundary_position
            and "return { x = x, y = y, z = z }, inRVRegion" in fresh_boundary_position
            and "guardContextForPlayer(player," in boundary_sweep
            and "position, id, true)" in boundary_sweep
            and "local state = stateFor(player, id)" in boundary_geometry
            and "Boundary._states[id.key] = state" in boundary_geometry
            and all(token not in boundary_sweep for token in (
                "UNTRACKED_OUTSIDE_PROBE_RETRY_TICKS", "coldOutsideCandidates",
                "untrackedOutsideProbeCursor",
            )),
            "boundary guard skips cold persisted inside relations for untracked outside players",
        )
        failure_notify = section(
            room_ownership,
            r"local function notifyFailure",
            r"\n\nlocal function clearInvalidRoomOwnershipSquare",
        )
        cancel_pending_ack = section(
            generation_ack,
            r"local function abortGeneration\(record, reason\)",
            r"\n\nctx\.acknowledgeRelocation",
        )
        final_ack = section(
            server_commands,
            r"if module == COMMAND_MODULE and command == COMMAND_FINAL_RELOCATE_ACK then",
            r"if module == COMMAND_MODULE and command == COMMAND_RELOCATE_ACK then",
        )
        request_rejection = section(
            server_commands,
            r"local checkOk, accepted, reason = pcall\(validateRequest",
            r"\n    -- Request validation and ownership",
        )
        invalid_feedback = section(
            railroader_client,
            r"function Menu.OnServerCommand",
            r"\n\s*rememberUtilityMapping\(args\)",
        )
        checks.true(
            failure_notify is not None
            and 'ServerUtil.invoke(player, "getOnlineID")' in failure_notify
            and "onlineId = onlineId" in failure_notify
            and "string.find(reasonText, invalidRVData, 1, true)" in failure_notify
            and "notifyFailure(livePlayer, reason)" in generation_ack
            and cancel_pending_ack is not None
            and "string.find(reason, Constants.INVALID_RV_DATA, 1, true)" in cancel_pending_ack
            and "notifyFailure(livePlayer, reason)" in cancel_pending_ack
            and cancel_pending_ack.find("notifyFailure(livePlayer, reason)")
                < cancel_pending_ack.find("GenerationTransaction.release()")
            and "pcall(Boundary.completeTransition, livePlayer, record.token)"
                in cancel_pending_ack
            and "if isInvalidRVData(reason) then notifyFailure(player, reason) end"
                in (request_rejection or "")
            and final_ack is not None
            and "if isInvalidRVData(reason) then" in final_ack
            and "runGenerationAbort(GenerationTransaction.current(), reason)" in final_ack
            and invalid_feedback is not None
            and "localPlayerByOnlineId(onlineId)" in invalid_feedback
            and "C.INVALID_RV_DATA" in invalid_feedback
            and "UI_RailroaderRV_InvalidRVData" in invalid_feedback
            and "Delete this test save and recreate it." in invalid_feedback
            and all(token not in invalid_feedback for token in (
                "args.x", "args.y", "args.z",
            )),
            "generation schema failures do not reach the affected player with the save-rebuild prompt",
        )
        checks.true(
            "local function currentSquareMatches(player, position)" in boundary_geometry
            and "if not ok or current == nil then return false end" in boundary_geometry
            and 'if type(position) ~= "table" or not currentSquareMatches(player, position) then'
                in boundary_geometry
            and "Missing or stale square state leaves the player untouched."
                in boundary_geometry
            and "local state = boundary and stateFor(player, id) or nil" in boundary_sweep
            and boundary_sweep.find("local state = boundary and stateFor(player, id) or nil")
                < boundary_sweep.find("state.inside = true"),
            "server boundary state advances across unloaded squares",
        )
        checks.true(
            "A live relocation lease owns this player's position." in boundary_sweep
            and "walkability work resumes after the lease expires." in boundary_sweep
            and "local tracked = Boundary._states[id.key]" in boundary_sweep
            and 'if not (type(tracked) == "table" and leaseLive(tracked)) then'
                in boundary_sweep
            and re.search(
                r'if not \(type\(tracked\) == "table" and leaseLive\(tracked\)\) then\s+'
                r"boundary, record, onlineId = guardContextForPlayer",
                boundary_sweep,
            ) is not None
            and "local function leaseLive(state)" in boundary_sweep
            and "state.leaseToken, state.leaseUntil = nil, nil" in boundary_sweep,
            "boundary OnTick still scans RV geometry through a remote roof-relocation cell",
        )
        checks.true(
            all(token in boundary_server for token in (
                "local function rvTag(object)", "tostring(tag.owner) ~= OWNER",
                "tag.rvId ~= nil", "tag.generation ~= nil",
                "tostring(tag.rvId)", "edge.replacementAllowed ~= false",
                "shellEdgeKeysForAction", "actionMatchesObject",
                "overwrite it merely because a build event happened at the same",
                "edgeKeys = action.edgeKeys", "shellAxisMatches(edge, axis)",
                'if axis == "N" then return edge.side == "north" end',
                "integer(edge.objectX) == x",
                "TemplateGeometry.inManagedRegion(", "boundary.managed",
                "actionMatchesObject(action, objectX, objectY, objectZ)",
            ))
            and all(token not in boundary_server for token in (
                "bitmapVersion", "existingNamespace",
                "shell host ownership is uncertain",
            )),
            "shell/build audit does not require full tag identity or host-aware attribution",
        )
        generation_cleanup = section(
            generation_flow,
            r"if priorGeneration ~= nil then",
            r"local generation = 1",
        )
        checks.true(
            generation_cleanup is not None
            and "locomotive already has a completed RV mapping" in generation_cleanup
            and "local function removeOldGeneration" not in room_ownership
            and "removeOldGeneration" not in generation_flow
            and "ServerSchema.walkBounds" not in room_ownership
            and "ServerWorld.clearSquare" not in room_ownership,
            "obsolete old-generation cleanup is reachable without a complete undo snapshot",
        )
        repair_context = section(
            template_protection_repair,
            r"local function repairTemplateProtectionCell",
            r"\n    local anchor = TemplateGeometry\.anchorFromManaged",
        )
        checks.true(
            repair_context is not None
            and "pcall(Boundary.boundaryForPlayer, player)" in repair_context
            and "boundary ~= expectedBoundary" in repair_context
            and "queued RV generation is stale" in repair_context
            and "pcall(requireCurrentManifest" not in repair_context
            and "manifest.state" not in repair_context
            and "manifest.phase" not in repair_context
            and "sameIdentity" not in repair_context
            and "schemaVersion" not in repair_context,
            "template protection repair does not require the current committed manifest before using bounds",
        )
        checks.true(
            all(token in server_schema for token in (
                "local function boundsFor(layout)",
                "managedOriginX = managed.originX, managedOriginY = managed.originY,",
                "managedWidth = managed.width, managedHeight = managed.height,",
                "wallCoordinates = layout.wallCoordinates,",
                "for x = bounds.clearMinX, bounds.clearMaxX - 1 do",
                "if not square and requireLoaded == true then",
                "isValidSquare",
                "RegionSlots.indexForAnchor({ x = targetX, y = targetY, z = targetZ }) == nil",
                "if targetX < bounds.roomMinX or targetX > bounds.roomMaxX",
                "for x = bounds.roofMinX, bounds.roofMaxX do",
            ))
            and "function G.inManagedRegion(world, managed)" in read_utf8(
                shared_root / "RoomTemplate" / "RV_TemplateGeometry.lua"
            ),
            "layout structure rectangles and captured wall hosts are not clipped to the bitmap scope",
        )
        checks.true(
            "function Boundary.beginTransition(player, rvId, generation, token, kind)"
                in boundary_server
            and "local state = stateFor(player)" in boundary_server
            and "state.rvId = tostring(rvId)" in boundary_server
            and "state.generation = integer(generation)" in boundary_server
            and 'state.leaseToken = type(token) == "string" and token or nil'
                in boundary_server
            and "pcall(Boundary.beginTransition," in server
            and 'player, transitionRvId, transitionGeneration, token, "generation")'
                in server
            and "Boundary.beginTransition(player, record.locoId," in server
            and "bitmapVersion" not in boundary_server
            and "record.bitmapVersion" not in railroader_server,
            "transition state does not carry the complete RV bitmap identity",
        )
        checks.true(
            "RV boundary entry service is unavailable" in railroader_server
            and "RV boundary exit service is unavailable" in railroader_server,
            "Railroader entry/exit can bypass the server boundary service",
        )
        checks.true(
            all(token in record_validation for token in (
                "currentRVManifestForBoundary",
                "function RV.Server.currentRVManifestForBoundary(rvId, generation)",
                "local function manifestViewForRecord(record)",
                "local boundary = Boundary.boundaryFor(record)",
                "bounds = ServerSchema.boundsFor(layout),",
                "It deliberately carries no mutation state",
            ))
            and "schemaVersion" not in boundary_geometry
            and "Bitmap.decode(boundary.bitmap)" not in boundary_geometry,
            "current manifest identity or latest-format bitmap decode path is missing",
        )
        checks.true(
            "local function roomOwnershipGuardKey" in room_ownership
            and "guard.key = roomOwnershipGuardKey" in room_ownership
            and "roomOwnershipGuards[guard.key] = guard" in room_ownership,
            "server room-ownership guard is not keyed by the full RV boundary identity",
        )
        checks.true(
            all(token in boundary_client for token in (
                "Events.OnServerCommand.Add", "function Client.onServerCommand",
                "COMMAND_RV_BOUNDARY_CORRECTION",
                "function Client.onCorrection",
            ))
            and all(token not in boundary_client for token in (
                "OnPlayerUpdate", "OnRenderTick", "previous",
                "segmentValid", "nearestActive", "setBlockMovement",
                "Events.OnTick.Add", "Client.onTick",
            )),
            "client boundary code retains independent previous-position prediction",
        )
        checks.true(
            "applyPosition(player, { x = x, y = y, z = z })" in boundary_client
            and '"setNextX"' in boundary_client
            and '"setLastZ"' in boundary_client,
            "client correction does not reset movement history fields",
        )

        # Railroader adapter executable contracts.  These source-level tests
        # intentionally exercise the authority/race decisions without loading
        # the game: the official Lua snapshot is not a runtime test substitute.
        checks.true(
            '== "rr_loco"' in railroader_server
            and '== "rr_loco"' in railroader_client,
            "Railroader adapter does not identify rr_loco on both sides",
        )
        checks.true(
            'serverTrain.active' in railroader_server
            and 'trainEntity.active' in railroader_server
            and 'authority == "singleplayer"' in railroader_server
            and "train.rider" in railroader_server
            and "RR.Ride" in railroader_server,
            "adapter does not distinguish RR_ServerTrain MP and TrainEntity/Ride SP state",
        )
        checks.true(
            ".Body.hullDistance" in railroader_server
            and "sourceWithinRange" in railroader_server
            and "RV_MOUNT_REACH" in railroader_server
            and "or 24" not in railroader_server,
            "server entry range is not the Railroader hull-distance contract",
        )
        checks.true(
            "ride.MOUNT_REACH" in railroader_client
            and "nearestBoardable(reach)" in railroader_client
            and "C.RV_ENTER_RANGE or 24" not in railroader_client,
            "client menu does not use Railroader MOUNT_REACH",
        )
        checks.true(
            "singleplayerDismount" in railroader_server
            and "singleplayerMount" in railroader_server
            and "ride.dismount" in railroader_server
            and "ride.mountRecord" in railroader_server
            and "ride.dismount, true" in railroader_client
            and "ride.mountRecord" in railroader_client,
            "SP Ride cleanup/remount and client transition ordering are missing",
        )
        checks.true(
            'args.action ~= "exit"' in railroader_client
            and 'args.action ~= "generation-failed"' in railroader_client,
            "SP generation-failed transition does not remount through Ride after teleport",
        )
        checks.true(
            all(token in railroader_server for token in (
                "_seatNames", "_claims", "_cmdSeq", "markResync",
                "setBlockMovement", "setCanShout", "setIsResting",
            )),
            "MP seat writes do not cover official claim/name/command/resync and player flags",
        )
        checks.true(
            "action == \"enter\"" in railroader_client
            and "action == \"generation-failed\"" in railroader_client
            and "action == \"exit\"" in railroader_client
            and "prepareGenerationRelocation" in railroader_client
            and "prepareGenerationRelocation" in client
            and "rr.MPClient" in railroader_client
            and "_boardPending" in railroader_client,
            "RVTeleport transition does not cover enter/failure/exit MP snapshot races",
        )

        # The current-square refresh uses the public IsoMovingObject overload;
        # Java userdata is not a Lua table, so writing dirty grid-stack fields
        # would flood the client log with an exception on every retry tick.
        current_square_refresh = section(
            railroader_client,
            r"local function refreshCurrentSquare",
            r"local function currentSquareMatches",
        )
        checks.true(
            current_square_refresh is not None
            and "player:setCurrentSquareFromPosition(x, y, z)" in current_square_refresh
            and "pcall" in current_square_refresh
            and "dirtyRecalcGridStack" not in railroader_client,
            "Railroader client current-square refresh uses an unsafe Java-field write or lacks the official three-argument call",
        )
        checks.true(
            "playerObj:setCurrentSquareFromPosition(x, y, z)" in client
            and "dirtyRecalcGridStack" not in client,
            "generic client relocation still uses an unsafe current-square refresh path",
        )
        checks.true(
            "CURRENT_SQUARE_REFRESH_TICKS" in railroader_client
            and "pending.ticks > CURRENT_SQUARE_REFRESH_TICKS" in railroader_client
            and "Menu._rvCurrentSquareRefresh = nil" in railroader_client,
            "current-square refresh retry is not bounded and cleaned up",
        )

        # The first generation Relocate is a separate race from RVTeleport:
        # the server may have removed the seat while the client is still
        # locally mounted.  Verify the Railroader-only marker, call ordering,
        # and token-scoped duplicate-dismount guard precisely.
        queue_transition = section(
            generation_flow_source,
            r"local function queueGeneration",
            r"ctx\.queueGeneration\s*=\s*queueGeneration",
        )
        relocate_handler = section(
            client_relocation_source,
            r"function Client\.onServerCommand",
            r"function Client\.onTick",
        )
        ride_transition = section(
            railroader_client,
            r"local function prepareRideTransition",
            r"local function finishRideTransition",
        )
        generation_relocation = section(
            railroader_client,
            r"function Menu\.prepareGenerationRelocation",
            r"function Menu\.OnFillWorldObjectContextMenu",
        )
        generation_staging = section(
            railroader_client,
            r"function Menu\.prepareGenerationStaging",
            r"function Menu\.OnFillWorldObjectContextMenu",
        )
        final_handler = section(
            client,
            r"if command == COMMAND_FINAL_RELOCATE then",
            r"if command ~= COMMAND_RELOCATE then return end",
        )
        final_relocation = section(
            server,
            r"local function relocatePlayerIntoHouse",
            r"local function generateForPlayer",
        )
        # The staging Relocate payload now belongs to the relocation service
        # (RV_Server_PlayerValidation.sendStagingRelocation).  queueGeneration
        # only stages the identity onto the adapter's asynchronous payload before
        # handing the record to that sender.
        stage_marker = section(
            server,
            r"local function sendStagingRelocation\(record, phase\)",
            r"if not sendRelocate\(record\.player, payload\)",
        )
        checks.true(
            queue_transition is not None
            and stage_marker is not None
            and re.search(
                r'if phase ~= "return" and type\(record\.railroader\) == "table" then'
                r'[\s\S]*?payload\.railroaderTransition = true',
                stage_marker,
            ) is not None
            and "payload.action = \"enter\"" in stage_marker
            and "payload.locoId = record.railroader.locoId" in stage_marker
            and "payload.role = record.railroader.sourceRole" in stage_marker
            and "payload.seat = record.railroader.sourceSeat" in stage_marker
            and "railroaderData.rvId = tostring(transitionRvId)" in queue_transition
            and "railroaderData.generation = transitionGeneration" in queue_transition
            and "local transitionRvId = rvId" in queue_transition
            and "local transitionGeneration = generation" in queue_transition
            and 'local sentOk, sentReason = sendStagingRelocation(record, "temporary")'
            in queue_transition,
            "Railroader staging marker is not server-only or not sent via Relocate payload",
        )
        if stage_marker is not None:
            marker_guard = stage_marker.find(
                'if phase ~= "return" and type(record.railroader) == "table" then'
            )
            marker_write = stage_marker.find(
                "payload.railroaderTransition = true"
            )
            checks.true(
                marker_guard >= 0 and marker_write > marker_guard,
                "Relocate marker is not guarded by Railroader generation data",
            )
        checks.true(
            relocate_handler is not None
            and "args.railroaderTransition == true" in relocate_handler
            and "local rvId = args.rvId" in relocate_handler
            and "rvId = tostring(rvId)" in relocate_handler
            and "prepareGenerationStaging" in relocate_handler
            and "if not preparedOk or prepared ~= true then return end" in relocate_handler,
            "client Relocate handler does not recognize the strict Railroader staging marker",
        )
        if relocate_handler is not None:
            marker_pos = relocate_handler.find("args.railroaderTransition == true")
            staging_pos = relocate_handler.find(
                "prepareGenerationStaging", marker_pos
            )
            teleport_pos = relocate_handler.find(
                "playerObj:teleportTo", staging_pos
            )
            checks.true(
                marker_pos >= 0 and staging_pos > marker_pos and teleport_pos > staging_pos,
                "staging Ride cleanup is not ordered before the server Relocate teleport",
            )
        checks.true(
            generation_staging is not None
            and "validGenerationFinalHint(args)" in generation_staging
            and "prepareRideTransition(args)" in generation_staging
            and "_rvGenerationTransition" in railroader_client,
            "Railroader staging helper does not use the existing Ride transition and guard",
        )
        checks.true(
            generation_relocation is not None
            and "generationTransitionMatches" in generation_relocation
            and "pending.finalSeen = true" in generation_relocation
            and "prepareRideTransition(args)" in generation_relocation,
            "FinalRelocate does not distinguish the first staging transition from duplicate callbacks",
        )
        checks.true(
            final_relocation is not None,
            "final in-house relocation helper is missing",
        )
        # The FinalRelocate payload was moved out of the in-house helper into the
        # relocation service's own sender (cf190a1).
        final_relocate_payload = section(
            server,
            r"local function sendFinalRelocation\(record, deadline\)",
            r"if not callGlobalSucceeded\(\"sendServerCommand\", record\.player,",
        )
        checks.true(
            final_relocate_payload is not None
            and re.search(
                r'local payload = \{[\s\S]*?'
                r'generation = record\.generation,',
                final_relocate_payload,
            ) is not None
            and re.search(
                r'if type\(record\.railroader\) == "table" then[\s\S]*?'
                r'payload\.railroaderTransition = true',
                final_relocate_payload,
            ) is not None
            and "token = record.token" in final_relocate_payload
            and "rvId = tostring(record.rvId)" in final_relocate_payload
            and "payload.action = \"enter\"" in final_relocate_payload
            and "payload.locoId = record.railroader.locoId" in final_relocate_payload,
            "Railroader FinalRelocate payload does not carry the strict server marker",
        )
        checks.true(
            final_handler is not None
            and "validRailroaderFinalHint(args)" in final_handler
            and "if marked and railroaderMenu" in final_handler
            and "hasGenerationTransition" not in final_handler
            and "if (marked or pending)" not in final_handler
            and "prepareGenerationRelocation" in final_handler,
            "FinalRelocate handler does not gate Ride preparation on the current server marker",
        )
        if final_handler is not None:
            prepare_pos = final_handler.find("prepareGenerationRelocation")
            guard_pos = final_handler.find("if marked and railroaderMenu")
            checks.true(
                guard_pos >= 0 and prepare_pos > guard_pos,
                "ordinary FinalRelocate can call the Railroader transition without its gate",
            )
        checks.true(
            generation_relocation is not None
            and "if not validGenerationFinalHint(args) then return false end" in generation_relocation
            and "return false" in generation_relocation,
            "Railroader FinalRelocate adapter does not no-op ordinary technical payloads",
        )

        # On a quick authoritative exit, the target record must receive the
        # official gate even if Ride.current is already nil; a beside exit may
        # not arm that gate.
        exit_transition = None
        if ride_transition is not None:
            exit_start = ride_transition.find('elseif action == "exit" then')
            return_pos = ride_transition.find("    return record", exit_start)
            if exit_start >= 0 and return_pos > exit_start:
                exit_transition = ride_transition[exit_start:return_pos]
        checks.true(
            exit_transition is not None
            and "if wantsSeat and record then" in exit_transition
            and "record._boardPending = true" in exit_transition
            and "if ride.current then" in exit_transition
            and exit_transition.find("record._boardPending = true")
            < exit_transition.find("if ride.current then")
            and re.search(r"if old then\s*old\._boardPending", exit_transition) is None,
            "exit transition does not arm the target record independently of Ride.current (or arms beside)",
        )
        checks.true(
            "recordAtPlayerCoordinate" in railroader_server
            and "inRegion(position, recordRegion(record))" in railroader_server
            and "RV_REGION_SIZE" in railroader_server
            and "validMappingRecord" in railroader_server
            and "copyPose(record.locoPosition)" in railroader_server
            and "inactive-mapped" in railroader_server
            and "persistedBesidePosition" in railroader_server
            and 'return nil, nil, nil, "outside-rv"' in railroader_server
            and "trainPose(train)" in railroader_server
            and "usableCoordinate" in railroader_server
            and 'isValidSquare' in railroader_server,
            "exit reverse lookup does not use the current 100x100 mapping contract",
        )
        existing_entry = section(
            entry_exit,
            r"local function enterExisting",
            r"local function enterPlayer",
        )
        checks.true(
            existing_entry is not None,
            "existing RV entry path is missing",
        )
        if existing_entry is not None:
            monitor_pos = existing_entry.find("armRoomOwnershipMonitor")
            transition_pos = existing_entry.find("local armed = Boundary.beginTransition")
            move_pos = existing_entry.find("movePlayer")
            checks.true(
                monitor_pos >= 0
                and transition_pos > monitor_pos
                and move_pos > monitor_pos,
                "existing RV entry moves before arming its current room monitor",
            )

        # RoofRefresh only updates template-declared floor visuals. Wall
        # removal separately owns one current WallReloadProtection operation.
        roof_refresh_point = section(
            roof_destinations,
            r"local function refreshPoint",
            r"local function refreshAllPoints",
        )
        roof_refresh_schedule = section(
            roof_destinations,
            r"function Refresh\.schedule",
            r"return Refresh",
        )
        checks.true(
            roof_refresh_point is not None
            and "bounds.anchor.x + point.x" in roof_destinations
            and "bounds.anchor.y + point.y" in roof_destinations
            and "bounds.z + point.z" in roof_destinations
            and "local originalFloor = square:getFloor()" in roof_refresh_point
            and "local originalFloorIndex = originalFloor:getObjectIndex()" in roof_refresh_point
            and "square:addFloor(point.temporaryFloorSprite)" in roof_refresh_point
            and "ServerWorld.removeGenericObject(square, temporary)" in roof_refresh_point
            and "square:transmitAddObjectToSquare(originalFloor, originalFloorIndex)" in roof_refresh_point,
            "RoofRefresh no longer restores each template floor from its authored offset",
        )
        checks.true(
            roof_refresh_schedule is not None
            and "local offsets = { 10, 50, 100, 200 }" in roof_refresh_schedule
            and "Core.scheduleAtTick" in roof_refresh_schedule
            and "RailroaderRV.Server.refreshRoofVisuals" in roof_refresh_schedule
            and "local operations = {}" not in roof_destinations
            and "Boundary.beginTransition" not in roof_destinations
            and "RelocateAck" not in roof_destinations,
            "RoofRefresh must schedule the four visual refreshes without transaction state",
        )

        shell_wall = section(
            boundary_objects,
            r"function Boundary\.isCurrentShellWall",
            r"local function appendShellEdgeKey",
        )
        checks.true(
            shell_wall is not None
            and 'Common.classInstance(object, "IsoThumpable")' in shell_wall
            and 'Common.classInstance(object, "IsoWindow")' in shell_wall
            and '"getObjectIndex")' in shell_wall
            and "tag.rvId" in shell_wall
            and "tag.generation" in shell_wall
            and 'type(tag.edgeKey) ~= "string"' in shell_wall
            and "shellEdgeAllowed(boundary, tag" in shell_wall,
            "current shell-wall identity does not require the tagged live object and mapped edge",
        )
        wall_candidate = section(
            adapter_roof_refresh_source,
            r"local function cheapShellWallCandidate",
            r"local function wallReloadForObject",
        )
        wall_matcher = section(
            adapter_roof_refresh_source,
            r"local function wallReloadForObject",
            r"function Adapter\.onObjectAboutToBeRemoved",
        )
        pending_wall_observer = section(
            adapter_roof_refresh_source,
            r"local function processPendingWallReloads",
            r"-- The generic removal path",
        )
        checks.true(
            wall_candidate is not None
            and wall_matcher is not None
            and "processIsServer()" in wall_matcher
            and "Boundary.isCurrentShellWall" in wall_matcher
            and "validRecord(record)" in wall_matcher
            and "if match then" in wall_matcher
            and "insidePlayersForRecord(map, match)" in wall_matcher
            and "authoritativeRoomObservation(captured[i].player)" in wall_matcher
            and "pendingWallReloads[key]" in wall_matcher
            and pending_wall_observer is not None
            and "recordForLoco(map, pending.rvId)" in pending_wall_observer
            and "operationKeyFor(record) ~= key" in pending_wall_observer
            and "current.x ~= originalSquare.x" in pending_wall_observer
            and "elseif not current.inRoom then" in pending_wall_observer
            and "startWallReload(key, pending, record)" in pending_wall_observer,
            "wall removal does not wait for authoritative room loss on the same current RV member",
        )
        checks.true(
            'Core.on("OnObjectAboutToBeRemoved", Adapter.onObjectAboutToBeRemoved)' in adapter_tick_source
            and 'Core.on("OnDestroyIsoThumpable", Adapter.onDestroyIsoThumpable)' in adapter_tick_source
            and 'wallReloadForObject(object, "object-about-to-be-removed")' in adapter_roof_refresh_source
            and 'wallReloadForObject(object, "destroy-iso-thumpable")' in adapter_roof_refresh_source
            and "Core.onTick(processPendingWallReloads)" in adapter_roof_refresh_source
            and "function Adapter.rearmRoomOwnershipMonitors(tick)" in adapter_roof_refresh_source
            and "MONITOR_REARM_INTERVAL_TICKS = 60" in adapter_roof_refresh_source,
            "wall-removal hooks or the bounded current room-monitor re-arm are not registered",
        )
        checks.true(
            "function Refresh.run(bounds)" in roof_destinations
            and "RoofRefresh.run(manifest.bounds)" in record_validation
            and "RoofRefresh.schedule(rvId)" in record_validation
            and "local offsets = { 10, 50, 100, 200 }" in roof_destinations,
            "the current mapping-to-RoofRefresh path is incomplete",
        )

        wall_service = roof_relocation_source
        wall_wait = section(
            wall_service,
            r"local function advanceWaitReload",
            r"local function advanceReturn",
        )
        wall_ack = section(
            wall_service,
            r"function M\.acknowledge",
            r"-- ALL players authoritatively inside",
        )
        wall_tick = section(
            wall_service,
            r"function M\.onTick",
            r"-- The single client -> server",
        )
        checks.true(
            "local OPERATION_TIMEOUT_TICKS = 600" in wall_service
            and "local operations = {}" in wall_service
            and "function M.begin(request, onComplete)" in wall_service
            and "Boundary.beginTransition" in wall_service
            and "Boundary.completeTransition" in wall_service
            and "ROOF_REFRESH_REMOTE_OFFSET_X" in wall_service
            and "ROOF_REFRESH_REMOTE_OFFSET_Y" in wall_service
            and "ROOF_REFRESH_REMOTE_OFFSET_Z" in wall_service
            and "local originX = ServerUtil.integer(managed.originX)" in wall_service
            and "local originY = ServerUtil.integer(managed.originY)" in wall_service
            and "originX - Constants.ROOF_REFRESH_REMOTE_OFFSET_X" in wall_service
            and "originY - Constants.ROOF_REFRESH_REMOTE_OFFSET_Y" in wall_service
            and "minZ - Constants.ROOF_REFRESH_REMOTE_OFFSET_Z" in wall_service
            and wall_wait is not None
            and "member.applied ~= true" in wall_wait
            and "roomGeometryCleared(member.player)" in wall_wait
            and 'sendRelocate(op, member, target, "return")' in wall_wait
            and wall_ack is not None
            and "if op.token == token then" in wall_ack
            and "if member.player == player then" in wall_ack
            and wall_tick is not None
            and "now > op.deadlineTick" in wall_tick
            and 'finishFailure(op, "wall reload member left the operation:' in wall_tick
            and "wall reload operation timed out in phase" in wall_tick
            and "ModData." not in wall_service,
            "WallReloadProtection lacks its single authoritative operation, async applied ACK, or one deadline",
        )
        checks.true(
            'wallReloadTransition = true' in wall_service
            and "wallReloadPhase = phase" in wall_service
            and "token = op.token" in wall_service
            and "wallReloadTransition == true" in client_relocation_source
            and 'wallReloadPhase ~= "temporary"' in client_relocation_source
            and 'wallReloadPhase ~= "return"' in client_relocation_source
            and "sendClientCommand(playerObj, C.MOD_ID, COMMAND_RELOCATE_ACK" in client_relocation_source
            and "{ token = pending.token }" in client_relocation_source
            and "WallReload.acknowledge(player" in generation_ack_source
            and "wallHandled, wallAccepted" in generation_ack_source,
            "wall-reload relocation does not share the existing Relocate wire command and token ACK route",
        )
        generation_relocation_state = section(
            generation_flow_source,
            r"local function queueGeneration",
            r"ctx\.queueGeneration\s*=",
        )
        checks.true(
            generation_relocation_state is not None
            and "GenerationTransaction.isActive()" in generation_relocation_state
            and "wallServer.isWallReloadTransactionActive" in generation_relocation_state
            and "local record = {" in generation_relocation_state
            and "stagingAcked = false" in generation_relocation_state
            and "GenerationTransaction.begin(player, record)" in generation_relocation_state
            and "ModData." not in generation_relocation_state,
            "generation and wall reload do not use separate process-local state with a shared mutation gate",
        )

        # Relay of the current generation-relocation resend contract: the record
        # is re-resolved from its stable online identity every tick, a missing
        # IsoPlayer only renews the deadline instead of cancelling, the boundary
        # lease is extended on the same token, and the same stage is re-sent on a
        # bounded cadence.
        generation_rebind = section(
            player_validation_source,
            r"local function keepGenerationTransitionAlive\(record\)",
            r"ctx\.keepGenerationTransitionAlive = keepGenerationTransitionAlive",
        )
        checks.true(
            generation_rebind is not None
            and "resolvePendingPlayer(record)" in generation_rebind
            and "record.deadlineTick = ctx.serverTick + RELOCATION_TIMEOUT_TICKS"
            in generation_rebind
            and "pcall(Boundary.extendTransition, playerOrReason, record.token, leaseUntil)"
            in generation_rebind
            and "record.lastSentTick" in generation_rebind
            and "sendStagingRelocation(record, \"temporary\")" in generation_rebind
            and "sendFinalRelocation(record)" in generation_rebind
            and "GENERATION_RESEND_TICKS" in player_validation_source
            and "local GENERATION_RESEND_TICKS = 30" in player_validation_source,
            "generation relocation does not rebind stable identities and renew/retry the same token",
        )
        # The abort return re-asserts the exact server-captured position through
        # the official setters; B42's float teleport overload floors x/y.
        return_reassert = section(
            server,
            r"if phase == \"return\" then",
            r"record\.lastSentTick = ctx\.serverTick\n    return true",
        )
        checks.true(
            return_reassert is not None
            and "record.originalPosition" in server
            and 'callSucceeded(record.player, "setX", target.x)'
            in return_reassert
            and 'callSucceeded(record.player, "setY", target.y)'
            in return_reassert
            and 'callSucceeded(record.player, "setZ", target.z)'
            in return_reassert
            and 'callSucceeded(record.player, "setLastX", target.x)'
            in return_reassert
            and 'callSucceeded(record.player, "setLastY", target.y)'
            in return_reassert,
            "generation rollback does not reassert the server-captured exact position",
        )
        # The per-member wall-reload resend phase was deleted; a member whose
        # stable identity is no longer online is removed from the captured
        # operation and the surviving members still finish on the one token.
        roof_rebind = section(
            roof_relocation_source,
            r"local function rebindMembers\(op, live\)",
            r"local function clearOperation\(op\)",
        )
        roof_disconnect_pause = section(
            roof_relocation_source,
            r"local function finishFailure\(op, reason\)",
            r"local function finishDone\(op\)",
        )
        checks.true(
            roof_rebind is not None
            and "local player = live[member.identityKey]" in roof_rebind
            and "table.remove(op.members, i)" in roof_rebind
            and "member.player = player" in roof_rebind,
            "roof relocation phase resend does not preserve one token across reconnect",
        )
        checks.true(
            roof_rebind is not None
            and roof_disconnect_pause is not None
            and "local function sendRelocate(op, member, target, phase)" in roof_relocation_source
            and "token = op.token" in roof_relocation_source
            and "local returned, unreturned = 0, 0" in roof_disconnect_pause
            and 'sendRelocate(op, member, member.captured, "return")'
            in roof_disconnect_pause
            and "applyTeleport(member.player, member.captured, false)"
            in roof_disconnect_pause
            and "returned = returned + 1" in roof_disconnect_pause
            and "unreturned = unreturned + 1" in roof_disconnect_pause,
            "roof relocation resend is missing its bounded retry cadence",
        )
        checks.true(
            roof_disconnect_pause is not None
            and wall_tick is not None
            and "local returned, unreturned = 0, 0" in roof_disconnect_pause
            and "local player = live[member.identityKey]" in roof_disconnect_pause
            and "member.player = player" in roof_disconnect_pause
            and "if #op.members == 0 then" in wall_tick
            and "reason=no-member-online" in wall_tick
            and "now > op.deadlineTick" in wall_tick
            and "wall reload operation timed out in phase" in wall_tick
            and 'pending.ticks >= 3 then' in client_relocation_source
            and "sendClientCommand(playerObj, C.MOD_ID, COMMAND_RELOCATE_ACK,"
            in client_relocation_source
            and "{ token = pending.token })" in client_relocation_source,
            "roof relocation does not pause its timeout and rebind members after reconnect",
        )
        checks.true(
            "currentRVManifestForRelocation" in record_validation
            and "currentRVManifestForBoundary" in record_validation
            and "currentRVRecordGeometryConsistent" not in record_validation
            and "validateCurrentRVRecord" not in record_validation,
            "current manifest reads still depend on the removed cross-geometry validator",
        )
        # One flat operation table per current RV identity; the wall reload refuses
        # to begin while a generation transaction is live, and the generation
        # queue refuses to begin while a wall reload is live.  Those two checks are
        # the server-side bidirectional mutex.
        generation_mutex = section(
            roof_relocation_source,
            r"function M\.begin\(request, onComplete\)",
            r"local destinationOk, destination = temporaryDestination\(boundary\)",
        )
        checks.true(
            generation_mutex is not None
            and queue_transition is not None
            and "local key = operationKey(request.rvId, request.generation)" in generation_mutex
            and "if operations[key] ~= nil then" in generation_mutex
            and "a wall reload operation is already active for this RV" in generation_mutex
            and "if type(api.isGenerationTransactionActive) ~= \"function\" then"
            in generation_mutex
            and "local generationOk, generationActive = pcall(" in generation_mutex
            and "if not generationOk or generationActive ~= false then" in generation_mutex
            and "return false, \"RV generation transaction is in progress\""
            in generation_mutex
            and "local wallServer = type(RV) == \"table\" and RV.Server or nil"
            in queue_transition
            and "or type(wallServer.isWallReloadTransactionActive) ~= \"function\" then"
            in queue_transition
            and "local wallMutexOk, wallActive, wallReason = pcall(" in queue_transition
            and "if not wallMutexOk or wallActive ~= false then" in queue_transition,
            "roof/generation relocation service does not enforce the server-side bidirectional mutex",
        )
        checks.true(
            "RV.Server.isGenerationTransactionActive = GenerationTransaction.isActive" in server
            and "RV.Server.isGenerationTransactionActiveForRV = GenerationTransaction.isActiveForRV"
            in server
            and "function api.begin(player, recordTable)" in server
            and "function api.isActive()" in server
            and "function api.isActiveForRV(rvId)" in server
            and "function RV.Server.validateCurrentRVRecord" not in server
            and "RV generation transaction is in progress" in server
            and "a wall reload operation is already active for this RV" in server
            and "wall reload transaction state is unavailable" in server,
            "server transaction mutex does not expose active roof/generation state and explicit rejection reasons",
        )
        adapter_mutex = section(
            railroader_server,
            r"local function wallReloadBusy\(rvId\)",
            r"local function onlinePlayersSnapshot\(\)",
        )
        checks.true(
            adapter_mutex is not None
            and "server.isWallReloadTransactionActive" in adapter_mutex
            and "local busy, busyReason = wallReloadBusy(nil)" in adapter_mutex
            and "RV wall reload is in progress" in adapter_mutex
            and "RV transaction gate is unavailable" in adapter_mutex
            and "local ok, result, reason = true, nil, nil" in adapter_mutex
            and "sendResult(player, false, reason or \"request rejected\")" in adapter_mutex
            and "Adapter.serverTransactionMutexStatus = function()" in railroader_server
            and "server.isGenerationTransactionActive" in railroader_server
            and "local wallBusy, wallReason = wallReloadBusy(nil)" in railroader_server
            and "return generationActive, wallBusy == true, wallReason" in railroader_server
            and "Adapter.wallReloadTransactionBlocks = function(rvId)" in railroader_server
            and "RV generation transaction is in progress" in railroader_server
            and "RV wall reload is in progress" in railroader_server
            and "ctx.wallReloadTransactionBlocks = Adapter.wallReloadTransactionBlocks"
            in railroader_server
            and "return ctx.wallReloadTransactionBlocks(...)" in railroader_server
            and "local blocked, blockReason = transactionBlocks(record.locoId)"
            in railroader_server
            and "local blocked, blockReason = transactionBlocks(locoId)" in railroader_server,
            "all-player Enter/Exit paths do not honor the current RV roof transaction mutex",
        )
        roof_owner = section(
            railroader_server,
            r"Adapter\.serverTransactionMutexStatus = function\(\)",
            r"Adapter\._ticks = Core\.getTick\(\)",
        )
        checks.true(
            roof_owner is not None
            and "server.isGenerationTransactionActive" in roof_owner
            and "server.isWallReloadTransactionActive" in railroader_server
            and "local wallBusy, wallReason = wallReloadBusy(nil)" in roof_owner
            and "return generationActive, wallBusy == true, wallReason" in roof_owner
            and "local generationBusy, wallBusy, mutexReason =" in roof_owner
            and "if generationBusy == nil then" in roof_owner
            and "return true, mutexReason" in roof_owner
            and "if generationBusy then" in roof_owner
            and "return true, \"RV generation transaction is in progress\"" in roof_owner,
            "adapter roof-owner gate confuses a generation claim with roof refresh",
        )
        checks.true(
            "currentGeometryGate" not in railroader_server
            and "currentRVRecordGeometryConsistent" not in railroader_server
            and "currentManifestForRecord" not in railroader_server,
            "Entry/Exit still contain removed cross-module geometry or manifest guards",
        )
        existing_entry = section(
            railroader_server,
            r"local function enterExisting",
            r"local function enterPlayer",
        )
        checks.true(
            existing_entry is not None
            and "currentManifestForRecord(record)" not in existing_entry
            and "local armed = Boundary.beginTransition" in existing_entry
            and "armRoomOwnershipMonitor" in existing_entry,
            "existing RV entry retains a removed manifest guard or lost boundary transition checks",
        )
        exit_entry = section(
            entry_exit,
            r"local function exitPlayer",
            r"\r?\nend\r?\n",
        )
        checks.true(
            exit_entry is not None
            and "currentManifestForRecord(record)" not in exit_entry
            and "local armed = Boundary.beginTransition" in exit_entry
            and "markPlayerOutside" in exit_entry,
            "RV exit retains a removed manifest guard or lost boundary transition checks",
        )
        boundary_gate = section(
            boundary_server,
            r"function Boundary.boundaryForPlayer",
            r"local function stateFor",
        )
        checks.true(
            boundary_gate is not None
            and "validateCurrentBoundaryPlayer" in boundary_gate
            and "if type(validator) ~= \"function\" then return nil end" in boundary_gate
            and "local hookOk, boundary, record, relation, validatedIdentity, manifest = pcall("
            in boundary_gate
            and "local current = hookOk and boundary or nil" in boundary_gate
            and "or validatedIdentity.key ~= id.key" in boundary_gate
            and "or tostring(manifest.rvId) ~= tostring(record.locoId)" in boundary_gate
            and "or integer(manifest.generation) ~= integer(record.generation)"
            in boundary_gate,
            "boundary guard does not fail closed through its current identity and player checks",
        )
        # The derived-geometry snapshot cache was deleted with loadedBoundary and
        # sameBoundaryGeometry (d37e012).  What remains is the per-player state's
        # own boundary reference plus one refresh stamp, and the current manifest
        # is rebuilt from the published mapping record on every read.
        checks.true(
            "loadedBoundary" not in boundary_server
            and "sameBoundaryGeometry" not in boundary_server
            and "state.boundaryReference ~= boundary" in boundary_server
            and "or tostring(state.rvId) ~= tostring(boundary.rvId)" in boundary_server
            and "state.boundaryReference = boundary" in boundary_server
            and "if state.validationRefreshTick == nil or forceValidationRefresh then"
            in boundary_server
            and "or not currentSquareMatches(player, position)" in boundary_server
            and "currentRVRecordGeometryConsistent" not in server
            and "function RV.Server.currentRVManifestForBoundary(rvId, generation)"
            in server
            and "function RV.Server.currentRVManifestForRelocation(rvId, generation)"
            in server,
            "boundary cache lost its local snapshot check or retained a cross-record geometry dependency",
        )
        # The stateless process-memory relocation sentinel is the generation
        # staging cell at z=-15 (GENERATION_STAGING_Z).  It is re-proved from the
        # server-owned record and the current manifest every time it is read.
        sentinel_position = section(
            server,
            r"local function selectGenerationStagingDestination\(layout, bounds\)",
            r"local function validateRequest\(module, command, player\)",
        )
        checks.true(
            "function RV.Server.currentRVManifestForRelocation" in server
            and "local GENERATION_STAGING_Z = -15" in server
            and "purpose = \"generation-center\"" in server
            and "if destination.z ~= GENERATION_STAGING_Z" in server
            and "or destination.x ~= expectedX or destination.y ~= expectedY then"
            in server
            and "return false, \"generation staging destination identity is stale\"" in server
            and sentinel_position is not None
            and "local function playerIsAtStagingDestination(player, destination, bounds)"
            in sentinel_position
            and "local playerOk, positionOrReason = validateAuthoritativePlayer(player)"
            in sentinel_position
            and "RELOCATION_TIMEOUT_TICKS" in server,
            "stateless -15 relocation sentinel is missing its identity/current-schema gates",
        )
        sentinel_mutex = section(
            railroader_server,
            r"local function wallReloadBusy\(rvId\)",
            r"function Adapter\.OnClientCommand\(module, command, player, args\)",
        )
        checks.true(
            sentinel_mutex is not None
            and "server.isGenerationTransactionActive"
            in railroader_server
            and "server.isWallReloadTransactionActive" in sentinel_mutex
            and 'return true, "RV transaction gate is unavailable"' in sentinel_mutex
            and "or type(active) ~= \"boolean\" then" in sentinel_mutex
            and "RV wall reload is in progress" in sentinel_mutex,
            "stateless sentinel can race an active generation or roof transaction",
        )
        checks.true(
            "recoverRelocationLedger" not in server
            and "recoveryOnly" not in server
            and "RECOVERY_REQUIRED" not in server
            and "setGenerationRecoveryValidator" not in server
            and "setRoofRefreshRecoveryValidator" not in server
            and "setRoofRefreshRecoveryRepairer" not in server,
            "server still contains the retired restart-recovery state machine",
        )
        # RoofRefresh owns no deadline, no retry ledger and no transaction; the
        # cadence is the four offsets it schedules on the Core tick, and each
        # attempt re-resolves the current manifest before touching the world.
        checks.true(
            "returnRepairDeadline" not in server
            and "ROOF_REFRESH_RETURN_TIMEOUT_TICKS" not in server
            and "refreshRetryAtTick" not in server
            and "function Refresh.schedule(rvId)" in roof_destinations
            and "local offsets = { 10, 50, 100, 200 }" in roof_destinations
            and "Core.scheduleAtTick(Core.tickAdd(now, offsets[index]),"
            in roof_destinations
            and "local callback = RailroaderRV.Server.refreshRoofVisuals"
            in roof_destinations
            and "RoofRefresh.run(manifest.bounds)" in record_validation
            and "return RoofRefresh.schedule(rvId)" in record_validation,
            "roof refresh still exposes a fake return deadline instead of a retry cadence",
        )
        checks.true(
            "GENERATION_HALO_REFRESH_TICKS" in client
            and "pending.generationTransition and pending.generationPhase == \"temporary\""
            in client
            and "GENERATION_HALO_TEXT" in client
            and "server payload contains only the phase marker" in client,
            "generation halo does not stay visible through the complete temporary phase",
        )
        # Wall-removal events are retained in the bounded pendingWallReloads map
        # keyed by the current rvId:generation identity instead of a follow-up
        # queue, and the entry is dropped only when the room loss is observed or
        # the record no longer matches the key.
        wall_events = section(
            adapter_roof_refresh_source,
            r"local function processPendingWallReloads\(\)",
            r"-- The generic removal path",
        )
        checks.true(
            "already accepted follow-up" not in server
            and "expiresAtTick" not in server
            and wall_events is not None
            and "local record = recordForLoco(map, pending.rvId)" in wall_events
            and "or operationKeyFor(record) ~= key" in wall_events
            and "or WallReload.isWallReloadActive(pending.rvId) then" in wall_events
            and "if current.x ~= originalSquare.x" in wall_events
            and "elseif not current.inRoom then" in wall_events
            and "roomLossObserved = true" in wall_events
            and "pendingWallReloads[key] = nil" in wall_events,
            "transient map reads can silently discard accepted bounded follow-up wall events",
        )
        # The authoritative z=-15 sentinel lives in the generation staging
        # destination contract: every read re-proves the current purpose and the
        # managed-centre identity, and the record's captured position is the
        # return target the abort path re-asserts.
        roof_return = section(
            server,
            r"local function playerIsAtStagingDestination\(player, destination, bounds\)",
            r"local function validateRequest\(module, command, player\)",
        )
        checks.true(
            roof_return is not None
            and "local GENERATION_STAGING_Z = -15" in server
            and "if destination.z ~= GENERATION_STAGING_Z" in roof_return
            and "return false, \"generation staging destination identity is stale\""
            in roof_return
            and "if destination.purpose == \"generation-center\" then" in roof_return
            and "local expectedX = bounds.managedOriginX" in roof_return
            and "token = record.token" in server
            and "record.originalPosition" in server,
            "roof return does not reject an authoritative player still at z=-15",
        )
        checks.true(
            "keepRoofRefreshFinalReturnAlive" not in server
            and "roof refresh final return exhausted" not in server
            and "roof refresh group final return exhausted" not in server
            and "local function finishFailure(op, reason)" in wall_service
            and "local live = livePlayersByKey()" in wall_service
            and "local returned, unreturned = 0, 0" in wall_service
            and "if sendRelocate(op, member, member.captured, \"return\")" in wall_service
            and "and applyTeleport(member.player, member.captured, false) then"
            in wall_service
            and "completeLease(op, member)" in wall_service
            and "clearOperation(op)" in wall_service,
            "roof return failure can exhaust and discard its context instead of continuing in-memory return",
        )
        checks.true(
            "beginRoofRefreshRelocationGroup" not in railroader_server
            and "pending.relocationStarted" not in railroader_server
            and "remote-reload-return" not in railroader_server
            and "originalPosition = copyPosition(position)" in railroader_server
            and "local captured = insidePlayersForRecord(map, match)" in railroader_server
            and "pendingWallReloads[key] = {" in railroader_server
            and "runRoofRefresh" in railroader_server
            and "RailroaderRV.Server.scheduleRoofRefreshForRV(identity.rvId)"
            in railroader_server
            and "WallReload.begin({" in railroader_server
            and "WallReload.isWallReloadActive" in railroader_server,
            "Railroader adapter does not implement grouped remote reload, repair and captured-position return",
        )
        group_flow = section(
            roof_relocation_source,
            r"function M\.onTick\(\)",
            r"-- The single client -> server",
        )
        checks.true(
            group_flow is not None
            and "local live = livePlayersByKey()" in group_flow
            and "local removed = rebindMembers(op, live)" in group_flow
            and "elseif #removed > 0 then" in group_flow
            and "finishFailure(op, \"wall reload member left the operation: \"" in group_flow
            and "local member = op.members[i]" in group_flow
            and "if op.phase == PHASE_MOVE_OUT then" in group_flow
            and "advanceMoveOut(op)" in group_flow
            and "elseif op.phase == PHASE_WAIT_RELOAD then" in group_flow
            and "elseif op.phase == PHASE_RETURN then" in group_flow
            and "advanceReturn(op)" in group_flow
            and group_flow.find("advanceWaitReload(op)")
            < group_flow.find("advanceReturn(op)"),
            "group return does not complete per-player return before isolating repair callbacks",
        )
        checks.true(
            "local returned, unreturned = 0, 0" in server
            and "wallRemovalEventKey" not in railroader_server
            and "refresh=waiting-for-room-loss" in railroader_server
            and "roomParticipants=" in railroader_server
            and "pcall(cheapShellWallCandidate, object)" in railroader_server,
            "roof final-return failures are not isolated and wall dedupe retains userdata",
        )
        checks.true(
            'Core.on("OnObjectAboutToBeRemoved", Adapter.onObjectAboutToBeRemoved)'
            in adapter_tick_source
            and "if type(Adapter.onObjectAboutToBeRemoved) == \"function\" then"
            in adapter_tick_source
            and "Adapter.onObjectAboutToBeRemoved" in adapter_tick_source
            and 'function Adapter.onObjectAboutToBeRemoved(object)' in adapter_roof_refresh_source
            and 'wallReloadForObject(object, "object-about-to-be-removed")'
            in adapter_roof_refresh_source
            and "Events.OnObjectAboutToBeRemoved.Add(function(object)" in core
            and 'dispatch("OnObjectAboutToBeRemoved", object)' in core,
            "server shell-wall removal hook is not registered on the authoritative event",
        )
        checks.true(
            'Core.on("OnDestroyIsoThumpable", Adapter.onDestroyIsoThumpable)'
            in adapter_tick_source
            and "if type(Adapter.onDestroyIsoThumpable) == \"function\" then"
            in adapter_tick_source
            and "Adapter.onDestroyIsoThumpable" in adapter_tick_source
            and 'function Adapter.onDestroyIsoThumpable(object)' in adapter_roof_refresh_source
            and 'wallReloadForObject(object, "destroy-iso-thumpable")'
            in adapter_roof_refresh_source
            and "Events.OnDestroyIsoThumpable.Add(function(object)" in core
            and 'dispatch("OnDestroyIsoThumpable", object)' in core,
            "server thumpable-destroy event supplement is not registered",
        )
        exit_player = section(
            entry_exit,
            r"local function exitPlayer",
            r"\r?\nend\r?\n",
        )
        checks.true(
            exit_player is not None
            and "if damaged or not record or not train" not in exit_player
            and re.search(
                r'if lookupState == "outside-rv" then[\s\S]*?'
                r'return false, "player is outside the RV area"[\s\S]*?'
                r'end\s+if not record then',
                exit_player,
            ) is not None
            and re.search(
                r'if not record then[\s\S]*?C\.INVALID_RV_DATA',
                exit_player,
            ) is not None
            and re.search(
                r'if not train then[\s\S]*?persistedBesidePosition\(record\)'
                r'[\s\S]*?lookupState ~= "inactive-mapped"[\s\S]*?'
                r'role = "beside"',
                exit_player,
            ) is not None
            and all(token in exit_player for token in (
                "Boundary.beginTransition", "movePlayer", "markPlayerOutside",
                "Boundary.clearPlayer", "markMappingChanged",
            ))
            and exit_player.find("Boundary.beginTransition")
                < exit_player.find("movePlayer")
                < exit_player.find("markPlayerOutside")
                < exit_player.find("Boundary.clearPlayer")
                < exit_player.find("markMappingChanged")
            and "putPassenger" not in exit_player[exit_player.find("if not train then"):]
            .split("local onlineId", 1)[0],
            "exit does not retain its beside fallback and boundary lease through the outside mapping update",
        )
        checks.true(
            re.search(
                r'if moving then[\s\S]*?freePassengerSeat\(train\)[\s\S]*?all passenger positions',
                railroader_server,
            ) is not None
            and re.search(
                r'freePassengerSeat\(train\)[\s\S]*?elseif train\.driver == nil[\s\S]*?besidePosition',
                railroader_server,
            ) is not None,
            "exit seat order does not enforce moving-passenger and stopped passenger/driver/beside rules",
        )

        if constants_path.is_file():
            checks.true(
                all(token in constants for token in (
                    "SAVE_SCHEMA_VERSION", "INVALID_RV_DATA",
                    "ROOF_REFRESH_REMOTE_OFFSET_X",
                    "ROOF_REFRESH_REMOTE_OFFSET_Y",
                    "ROOF_REFRESH_REMOTE_OFFSET_Z",
                ))
                and 'C.SAVE_SCHEMA_VERSION = 15' in constants
                and 'C.INVALID_RV_DATA = "RailroaderRV: RV data is invalid; delete this development test save and rebuild it"' in constants
                and "BITMAP_VERSION" not in constants
                and "RELOCATION_SENTINEL_Z" not in constants
                and len(constants.splitlines()) >= 120
                and "local function mapData()" in mapping
                and "return ModData.get(C.RV_MAP_KEY)" in mapping
                and "local GENERATION_STAGING_Z = -15" in generation_flow
                and "GENERATION_STAGING_Z = Constants.RELOCATION_SENTINEL_Z" not in server
                and all("schemaVersion" not in source for source in (
                    mapping, generation_flow, server_schema,
                    record_validation, layout, boundary_geometry, utility_store,
                )),
                "current schema constants do not expose the generic invalid-RV-data contract",
            )
            checks.true(
                all(token in railroader_server for token in (
                    "local pendingWallReloads = {}",
                    "local function isEmptyMap(map)",
                    "local function processPendingWallReloads()",
                    "if isEmptyMap(pendingWallReloads) then return end",
                    "elseif isEmptyMap(pending.participants) then",
                    "local function isWallReloadTransactionActive(rvId)",
                    "api.isWallReloadTransactionActive = isWallReloadTransactionActive",
                ))
                and all(token in wall_reload_source for token in (
                    "local operations = {}",
                    "function M.isWallReloadActive(rvId)",
                    "function M.begin(request, onComplete)",
                    "if operations[key] ~= nil then",
                    'return false, "a wall reload operation is already active for this RV"',
                    "local function clearOperation(op)",
                ))
                and "followUpWallRemovalEvents" not in railroader_server
                and "WALL_REMOVAL_FOLLOWUP_TICKS" not in railroader_server,
                "independent wall events are not retained in a bounded stable follow-up queue",
            )
            checks.true(
                "function checkSaveSchemaVersion()" in railroader_server
                and "events.OnInitGlobalModData" in railroader_server
                and "map.schemaVersion = C.SAVE_SCHEMA_VERSION" in railroader_server
                and "map.schemaVersion ~= C.SAVE_SCHEMA_VERSION" in railroader_server
                and "Continuing without migration" in railroader_server
                and "The user promises not to use old saves" in railroader_server
                and railroader_server.count("map.schemaVersion = C.SAVE_SCHEMA_VERSION") == 1
                and railroader_server.count("map.schemaVersion ~= C.SAVE_SCHEMA_VERSION") == 1
                and "pcall(mapData)" not in railroader_server
                and "pcall(ModData.getOrCreate" not in railroader_server
                and "return ModData.get(C.RV_MAP_KEY)" in mapping
                and "pcall(ModData.get, C.RV_MAP_KEY)" not in mapping
                and "map.locomotives = {}" not in mapping
                and "map.players = {}" not in mapping
                and "schemaVersion ~= " not in mapping
                and "schemaVersion = map.schemaVersion" in entry_exit
                and all("schemaVersion" not in source for source in (
                    generation_build, generation_flow, server_schema,
                    record_validation, layout, bitmap,
                    boundary_geometry, utility_store,
                )),
                "the single warning-only startup schema check or unguarded runtime read path is missing",
            )
            checks.true(
                "C.RV_REGION_SLOT_ROWS = 5" in constants
                and "C.RV_REGION_SLOT_COLUMNS = 20" in constants
                and "C.RV_REGION_SLOT_COUNT = C.RV_REGION_SLOT_ROWS * C.RV_REGION_SLOT_COLUMNS" in constants
                and "local FIRST_MIN_X" in region_slots
                and "local FIRST_MIN_Y" in region_slots
                and "indexToAnchor" in region_slots
                and "indexToRegion" in region_slots
                and "findFirstFree" in region_slots
                and "RegionSlots.findFirstFree(occupied)" in mapping,
                "5x20 row-major slot matrix or mapping-only free-slot allocation is incomplete",
            )
            checks.true(
                "local function mapData()" in mapping
                and "return ModData.get(C.RV_MAP_KEY)" in mapping
                and "local map = mapData()" in mapping
                and "ModData.getOrCreate" not in mapping
                and "function Slots.indexToAnchor(index)" in region_slots
                and "function Slots.indexForAnchor(anchor)" in region_slots
                and "local bounds = ServerSchema.boundsFor(layout)" in generation_flow
                and "function Bitmap.decode(encoded)" not in region_slots
                and "Bitmap" not in region_slots
                and "bitmap" not in region_slots
                and "bitmap" not in boundary_geometry
                and all("schemaVersion" not in source for source in (
                    mapping, generation_build, generation_flow, region_slots,
                    boundary_geometry, utility_store,
                )),
                "runtime paths must use current data without nested save-schema gates",
            )
            checks.true(
                re.search(r"C\.TELEPORT_X\s*=\s*20050", constants) is not None
                and re.search(r"C\.TELEPORT_Y\s*=\s*2050", constants) is not None
                and re.search(r"C\.TELEPORT_Z\s*=\s*0", constants) is not None,
                "shared constants do not define the fixed 20050,2050,0 destination",
            )
            checks.true(
                re.search(r"C\.RV_REGION_SIZE\s*=\s*100", constants) is not None
                and re.search(r"C\.RV_REGION_MIN_OFFSET_X\s*=\s*-50", constants) is not None
                and re.search(r"C\.RV_REGION_MIN_OFFSET_Y\s*=\s*-50", constants) is not None
                and re.search(r"C\.RV_MANAGED_MIN_Z_OFFSET\s*=\s*0", constants) is not None
                and re.search(r"C\.RV_MANAGED_MAX_Z_OFFSET\s*=\s*2", constants) is not None
                and re.search(r"C\.RV_REGION_SLOT_ROWS\s*=\s*5", constants) is not None
                and re.search(r"C\.RV_REGION_SLOT_COLUMNS\s*=\s*20", constants) is not None
                and "local FIRST_MIN_X = C.TELEPORT_X + C.RV_REGION_MIN_OFFSET_X" in region_slots
                and "local FIRST_MIN_Y = C.TELEPORT_Y + C.RV_REGION_MIN_OFFSET_Y" in region_slots
                and "Slots.REGION_SIZE = C.RV_REGION_SIZE" in region_slots
                and "maxX = minX + SIZE" in region_slots
                and "maxY = minY + SIZE" in region_slots
                and "halfOpen = halfOpen == true" in layout
                and "CLEAR_MIN_OFFSET_X" not in constants
                and "RV_MANAGED_WIDTH" not in constants
                and "RV_MANAGED_HEIGHT" not in constants,
                "shared constants do not define the half-open 100x100 managed footprint",
            )
            checks.true(
                re.search(r'C\.COMMAND_FINAL_RELOCATE\s*=\s*["\']FinalRelocate["\']', constants)
                is not None,
                "shared constants do not define the final relocation command",
            )
            template_version = re.search(
                r"templateVersion\s*=\s*(\d+)", captured_template
            )
            room_template_version = re.search(
                r"CURRENT_TEMPLATE_VERSION\s*=\s*(\d+)", room_template
            )
            checks.true(
                template_version is not None
                and room_template_version is not None
                and template_version.group(1) == room_template_version.group(1)
                and compiled_template_metadata["templateVersion"]
                == int(room_template_version.group(1))
                and compiled_template_metadata["currentTemplateVersion"]
                == int(template_version.group(1))
                and compiled_template_metadata["objectCount"] == 412
                and re.search(r"objectCount\s*=\s*412", captured_template)
                is not None
                and len(captured_template_rows) == 412
                and len(captured_template_objects) == 412
                and template_index_aligned
                and protection_identity_matches_template
                and "protectFromDemolition" not in captured_template
                and {
                    (int(obj["x"]), int(obj["y"])) for obj in captured_template_objects
                    if int(obj["z"]) == 0
                } >= {(dx, dy) for dx in range(-4, 2) for dy in range(-6, 17)}
                and all(
                    compiled_protected_by_index[index] is True
                    for index, obj in enumerate(captured_template_objects, 1)
                    if int(obj["z"]) == 0
                    and int(obj["x"]) in {-4, -3, -2, -1, 0, 1}
                    and int(obj["y"]) == -6
                    and obj["name"] == "Wooden Wall"
                ),
                "current RoomTemplate/source/schema identity or object count is stale",
            )
            checks.true(
                len(compiled_template_objects) == 412
                and free_count == 49
                and protected_count == 363,
                "compiled RoomTemplate protection count differs from the authored object layout",
            )
            checks.true(
                cab_classes_match,
                "current internal cab cells are not all demolition-allowed",
            )
            checks.true(
                east_cab_classes_match,
                "east cab wall/window protection flags do not match the compiled template",
            )
            checks.true(
                south_shell_floors_stay_protected,
                "south shell floors are not protected by the compiled template",
            )
            checks.true(
                len(cab_opening_objects_outside_build_cells) == 3
                and template_index_aligned
                and all(compiled_protected_by_index[index]
                    == (obj["name"] == "Wooden Door Frame")
                    for index, obj in cab_opening_objects_outside_build_cells),
                "cab-side door/window/door-frame protection does not match the compiled template",
            )
            checks.true(
                northwest_support_classes == [True, True],
                "NW corner support walls are not both protected by the compiled template",
            )
            checks.true(
                template_index_aligned
                and all(
                    compiled_protected_by_index[index]
                    for index, obj in enumerate(captured_template_objects, 1)
                    if obj["name"] == "Dark Fancy Wardrobe"
                )
                and "Hidden RV Corner Block" not in captured_template
                and len(protected_activity_corner_walls) == 4
                and {(int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
                    for obj in protected_activity_corner_walls}
                    == {(-4, 16, 0, "false"), (2, -6, 0, "false"),
                        (2, 16, 0, "false"), (2, 17, 0, "false")}
                and len(protected_wardrobe_tiles) == 4
                and {(int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
                    for obj in protected_wardrobe_tiles}
                    == {(-5, -2, 0, "true"), (-5, -1, 0, "true"),
                        (-5, 0, 0, "true"), (-5, 1, 0, "true")},
                "current protected corner walls or wardrobe identity/count is stale",
            )
            checks.true(
                len(captured_roof_cells) == 88,
                "current captured template roof-host square count is stale",
            )
            checks.true(
                captured_top_z == 1
                and len(declared_roof_cell_rows) == 88
                and len(declared_roof_cells) == 88
                and {(x, y) for x, y, _z in declared_roof_cells}
                == captured_roof_cells
                and all(z == captured_top_z for _x, _y, z in declared_roof_cells)
                and {(int(row[0]), int(row[1])) for row in captured_top_roof_rows}
                == captured_roof_cells
                and {row[3] for row in captured_top_roof_rows}
                == {"IsoObject", "IsoThumpable"}
                and {row[5] for row in captured_top_roof_rows}
                == {"location_shop_fossoil_01_39"}
                and "roofCells = roofCells" in room_template
                and "return value.roofCells" in room_template
                and "RoomTemplate.roofCells(Template)" in layout,
                "authored roof cell coordinates do not match the actual captured roof footprint",
            )
            checks.true(
                len(northwest_north_wall_rows) == 1
                and len(northwest_west_wall_rows) == 1
                and "for y = interiorMinY, interiorMaxY do" in layout
                and 'or (north and "wall-north" or "wall-west")' in layout
                and "local corner = side == \"north\" and x == interiorMinX" in layout
                and "and y == interiorMinY" in layout
                and 'local role = corner and "corner-nw"' in layout
                and "local expectedRole = expectedNorth and \"wall-north\" or \"wall-west\"" in boundary_objects
                and 'if tag.role == "corner-nw" then expectedRole = "corner-nw" end' in boundary_objects
                and "or edge.corner ~= (role == \"corner-nw\")" in boundary_objects
                and "return role == \"wall-north\" or role == \"wall-west\"" in adapter_roof_refresh_source
                and 'or role == "corner-nw"' in adapter_roof_refresh_source
                and '["wall-west"] = true' in boundary_wall_visuals
                and 'if tag.role == "wall-north" or tag.role == "corner-nw" then' in boundary_wall_visuals
                and "if expected.north ~= true then return false end" in boundary_wall_visuals
                and "elseif expected.north ~= false then" in boundary_wall_visuals
                and '["wall-west"] = true' in protected_demolition
                and '["corner-nw"] = true' in protected_demolition
                and "northwestEntries" not in server_schema
                and "templateBoundarySupportWall" not in world_objects,
                "NW corner does not have the exact corner-north/wall-west support pair with current visual tags",
            )
            checks.true(
                re.search(r"C\.SAVE_SCHEMA_VERSION\s*=\s*15", constants) is not None
                and re.search(r"C\.RV_REGION_SLOT_ROWS\s*=\s*5", constants) is not None
                and re.search(r"C\.RV_REGION_SLOT_COLUMNS\s*=\s*20", constants) is not None
                and "C.RV_REGION_SLOT_COUNT = C.RV_REGION_SLOT_ROWS * C.RV_REGION_SLOT_COLUMNS" in constants
                and "Slots.ROWS = C.RV_REGION_SLOT_ROWS" in region_slots
                and "Slots.COLUMNS = C.RV_REGION_SLOT_COLUMNS" in region_slots
                and "Slots.COUNT = C.RV_REGION_SLOT_COUNT" in region_slots
                and "if count ~= highest then return nil end" in region_slots
                and "return (row - 1) * Slots.COLUMNS + column" in region_slots
                and 'return nil, "overlapping-regions"' in region_slots
                and 'return nil, "no-free-slot"' in region_slots
                and "BITMAP_VERSION" not in constants
                and "Bitmap" not in region_slots,
                "the single save schema version or shared RV matrix/bitmap contract is missing",
            )
            checks.true(
                len(captured_template_objects) == 412
                and len(fence_rows) == 50
                and len(paired_keys) == 46
                and len(boundary_fence_keys) == 46
                and len(hidden_boundary_wall_rows) == 47
                and not off_boundary_fence_keys
                and len(expected_off_boundary_fence_keys & fence_keys) == 4
                and all(
                    "doRender=false" in wall["state"]
                    and "hoppable=false" in wall["state"]
                    for wall in hidden_boundary_wall_rows
                )
                and all(
                    not wall_rows_by_key.get(key)
                    for key in expected_off_boundary_fence_keys
                )
                and len(wall_rows_by_key.get((2, 2, 0, "false"), [])) == 2,
                "captured fence backing does not match the 46-edge/47-wall boundary contract",
            )
            checks.true(
                'require "RailroaderRV/GUI/RV_BoundaryWallVisuals"' in client
                and "local function isTaggedBoundarySupportWall(object)" in boundary_wall_visuals
                and "or tag.owner ~= C.MOD_ID" in boundary_wall_visuals
                and "or not boundaryRoles[tag.role] then" in boundary_wall_visuals
                and 'if expected.class ~= "IsoThumpable"' in boundary_wall_visuals
                and 'or expected.name ~= "Wooden Wall"' in boundary_wall_visuals
                and "or not supportWallSprites[expected.sprite]" in boundary_wall_visuals
                and "or expected.state.doRender ~= false then" in boundary_wall_visuals
                and "local function hideBoundarySupportWall(object)" in boundary_wall_visuals
                and 'call(object, "setDoRender", false)' in boundary_wall_visuals
                and 'call(object, "getDoRender")' in boundary_wall_visuals
                and 'call(object, "invalidateRenderChunkLevel", dirtyRedraw)' in boundary_wall_visuals
                and "events.OnObjectAdded.Add(onObjectAdded)" in boundary_wall_visuals
                and "events.LoadGridsquare.Add(onGridSquareLoaded)" in boundary_wall_visuals
                and "events.ReuseGridsquare.Add(onGridSquareLoaded)" in boundary_wall_visuals
                and 'if not ServerUtil.callSucceeded(thumpable, "setIsThumpable", true) then' in world_objects
                and "templateBoundarySupportWall" not in world_objects
                and "templateClass" not in boundary_wall_visuals
                and "bitmap" not in boundary_wall_visuals,
                "client does not hide only generation-tagged boundary support walls across sync/load",
            )
            checks.true(
                'require "RailroaderRV/GUI/RV_WardrobeVisuals"' in client
                and 'local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"' in wardrobe_visuals
                and 'RoomTemplate.get(RoomTemplate.TEMPLATE_ID)' in wardrobe_visuals
                and 'local templateObjects = RoomTemplate.orderedObjects(Template)' in wardrobe_visuals
                and "local function isWardrobeTemplateEntry(entry)" in wardrobe_visuals
                and 'and entry.name == "Dark Fancy Wardrobe"' in wardrobe_visuals
                and "and entry.state.doRender == false" in wardrobe_visuals
                and "local function isTaggedWardrobe(object)" in wardrobe_visuals
                and 'or tag.role ~= "captured-template" then' in wardrobe_visuals
                and "or tag.edgeKey ~= nil then" in wardrobe_visuals
                and "local entry = templateObjects[templateIndex]" in wardrobe_visuals
                and "TemplateGeometry.templateAnchorForWorld(x, y, z)" in wardrobe_visuals
                and "local function hideWardrobe(object)" in wardrobe_visuals
                and 'call(object, "setDoRender", false)' in wardrobe_visuals
                and 'call(object, "getDoRender")' in wardrobe_visuals
                and 'call(object, "invalidateRenderChunkLevel", dirtyRedraw)' in wardrobe_visuals
                and "events.OnObjectAdded.Add(onObjectAdded)" in wardrobe_visuals
                and "events.LoadGridsquare.Add(onGridSquareLoaded)" in wardrobe_visuals
                and "events.ReuseGridsquare.Add(onGridSquareLoaded)" in wardrobe_visuals
                and "bitmapVersion" not in wardrobe_visuals
                and "BITMAP_VERSION" not in wardrobe_visuals,
                "wardrobes are not hidden through the client entry point with current generation identity and render invalidation",
            )
            checks.true(
                "local function objectMatchesStaticIdentity(object, tag, expected," in protected_demolition
                and "templateIndex)" in protected_demolition
                and "or C.finiteInteger(tag.templateIndex) ~= templateIndex then" in protected_demolition
                and "local indexedObject, indexedAt =" in protected_demolition
                and "TemplateGeometry.lookupObjectByIndex(index, template)" in protected_demolition
                and "local offset = TemplateGeometry.worldToTemplate(world, anchor)" in protected_demolition
                and "local matches = TemplateGeometry.lookupObjectsAtWorld(world, anchor," in protected_demolition
                and "or not squareOk or not square then" in protected_demolition
                and 'return fail("object-index-or-square-invalid"' in protected_demolition
                and "return rejectInvalidRVData(character," in protected_demolition
                and "if expected.protected ~= true then" in protected_demolition
                and "return originalNew(self, character, item, cornerCounter)" in protected_demolition
                and "return originalNew(self, character, thumpable)" in protected_demolition
                and "return originalNew(self, character, generator)" in protected_demolition
                and "return { ignoreAction = true }" in protected_demolition
                and "C.TELEPORT_X" not in protected_demolition
                and "ProtectionManifest" not in protected_demolition
                and "bitmapVersion" not in protected_demolition,
                "protected demolition does not block only category 3 after validating the static object identity",
            )
            checks.true(
                "wallLamp" not in captured_template
                and "lighting_indoor_01_16" not in captured_template
                and "createLight" not in generation_build
                and "createCapturedTemplateObject" in generation_build,
                "captured RV generation still depends on the retired synthetic wall-lamp stage",
            )
            checks.true(
                re.search(
                    r'C\.COMMAND_REFRESH_ROOM_OWNERSHIP\s*=\s*["\']RefreshRoomOwnership["\']',
                    constants,
                )
                is not None
                and "C.COMMAND_REFRESH_ROOM_OWNERSHIP" in client
                and 'COMMAND_REFRESH_ROOM_OWNERSHIP = "RefreshRoomOwnership"' in server,
                "shared/server/client room-ownership command contract is inconsistent",
            )
            checks.true(
                re.search(
                    r'C\.COMMAND_FINAL_RELOCATE\s*=\s*["\']FinalRelocate["\']',
                    constants,
                ) is not None
                and "COMMAND_FINAL_RELOCATE" in client
                and "COMMAND_FINAL_RELOCATE" in server,
                "shared/server/client final relocation command contract is inconsistent",
            )

        if layout_path.is_file():
            layout = read_utf8(layout_path)
            checks.true(
                "playerFloor" not in layout
                and "local clear = rectangle(" in layout
                and "clear = clear" in layout,
                "shared layout retains a dead player-floor rectangle or loses its clear bounds",
            )
            checks.true(
                "local walkGeometry = walkAabbs[1]" in layout
                and "local roofZOffset = roofCells[1].z" in layout
                and "local interior = rectangle(" in layout
                and "cx + templateWalkGeometry.minX," in layout
                and "cx + templateWalkGeometry.maxX - 1," in layout
                and "cy + templateWalkGeometry.minY," in layout
                and "cy + templateWalkGeometry.maxY - 1," in layout
                and "for index = 1, #template.misc.buildCells do" in layout
                and '"corner-nw"' in layout
                and '"corner-se"' not in layout
                and "INTERIOR_MIN_OFFSET_X" not in layout
                and "INTERIOR_MIN_OFFSET_X" not in constants
                and "{ minX = -4, maxX = 2, minY = -6, maxY = 17," in captured_template,
                "shared layout does not expose the captured walkable interior and selected-template build mask",
            )
            checks.true(
                "templateObjects" in layout
                and "templateIndex" in layout
                and "wallObjectCount = layout.wallObjectCount" in server_schema
                and "wallCoordinateCount = layout.wallCoordinateCount" in server_schema
                and "wallEdgeCounts = edgeCounts" in server_schema
                and "northEdges = edgeCounts.north, westEdges = edgeCounts.west" in server_schema
                and "wallCornerCount = layout.wallCornerCount" in server_schema
                and "result.wallObjectCount = #wallCoordinates" in layout
                and "result.wallCoordinateCount = #wallCoordinates" in layout
                and "result.wallEdgeCounts = { north = northCount, west = #wallCoordinates - northCount }" in layout
                and "result.wallCornerCount = cornerCount" in layout
                and "local shellEdges = {}" in layout
                and "shellEdges = shellEdges" in layout
                and "shellEdges[edgeKey] = {" in layout
                and "replacementAllowed = true" in layout,
                "captured shell contract is not 59 edges with N12/W47/corner1",
            )
            checks.true(
                "protected = captured.protected," in layout
                and "templateIndex = i," in layout
                and "local templateObjects = layout.templateObjects" in generation_build
                and "createCapturedTemplateObject(cell, square, entry, generation, tagContext," in generation_build
                and "local shellByTemplateIndex = {}" in generation_build
                and "shellByTemplateIndex[index] = edge" in generation_build
                and "tag.role = role" in server_world
                and "data.RailroaderRV = tag" in server_world
                and "local result = { templateIndex = entry.templateIndex }" in world_objects
                and 'entry.class == "IsoObject"' in world_objects
                and "local tag = objectTag(object)" in template_protection_repair
                and "return tag and integer(tag.templateIndex) or nil" in template_protection_repair
                and "local captured = entries[index]" in template_protection_repair
                and "if captured.z == cellZ and captured.protected then" in template_protection_repair
                and "if entry.z == z and entry.protected" in template_protection_repair
                and "local spare, templateIndex = isSpareObject(object," in template_protection_repair
                and "restoreEntry(cell, square, objects, entry, boundary)" in template_protection_repair
                and "expected.protected ~= true" in protected_demolition
                and len(west_cab_wall_tiles) == 4
                and "ProtectionManifest" not in (layout + generation_build + world_objects
                    + protected_demolition + template_protection_repair)
                and "protectFromDemolition" not in (layout + generation_build + world_objects
                    + protected_demolition + template_protection_repair),
                "static protection classes do not flow through layout, generation, tags, client demolition, and repair",
            )

        checks.true(
            "isEmptyCommandArgs" not in server
            and "tableIsEmpty" not in server
            and "local function requiredNumber(value, label)" in server
            and "local function requiredInteger(value, label)" in server
            and "M.requiredNumber = requiredNumber" in server
            and "M.requiredInteger = requiredInteger" in server
            and 'error("RailroaderRV: " .. tostring(label) .. " is not a finite number")' in server
            and 'error("RailroaderRV: " .. tostring(label) .. " must be an integer")' in server
            and 'requiredNumber(value, "authoritative player "' in server
            and 'return type(value) == "table"' in utility_server,
            "isEmptyCommandArgs helper is missing",
        )
        checks.true(
            "local function tableIsEmpty" not in server
            and "local function requiredNumber(value, label)" in server
            and "M.requiredNumber = requiredNumber" in server
            and "requiredNumber(value, \"authoritative player \"" in server
            and "for _ in pairs(value)" not in server
            and "next(" not in server
            and "for key in pairs(value) do" in utility_water_objects
            and "for key, nested in pairs(value) do" in utility_store,
            "server empty-table checks should use the broadly available pairs iterator",
        )
        clear_tag = section(
            server,
            r"local function clearGenerationTag\(object\)",
            r"local function squareContainsObject",
        )
        checks.true(clear_tag is not None, "clearGenerationTag function is missing")
        if clear_tag is not None:
            checks.true(
                "tableIsEmpty(nested)" not in clear_tag
                and "pairs(" not in clear_tag,
                "generation-tag cleanup still scans the Kahlua modData namespace",
            )
            for field_name in (
                "owner",
                "rvId",
                "generation",
                "role",
                "previousSprite",
                "createdByGeneration",
            ):
                checks.true(
                    f"tag.{field_name} = nil" in clear_tag,
                    f"generation-tag cleanup does not clear nested {field_name}",
                )

        tagger = section(
            server,
            r"local function tagObject\(object, generation, role, tagContext, extraData\)",
            r"local function isTaggedForGeneration",
        )
        checks.true(tagger is not None, "tagObject helper is missing")
        if tagger is not None:
            checks.true(
                all(
                    network_call not in tagger
                    for network_call in (
                        "transmitModData",
                        "transmitCompleteItemToClients",
                        "sendObjectChange",
                        '"sync"',
                    )
                )
                and "Do not transmit an object-index" in tagger
                and "the creator sends one complete object packet after" in tagger,
                "tagObject emits a pre-attachment object-index network packet",
            )
            checks.true(
                'error("RailroaderRV: generated object tag is incomplete")' in tagger
                and "local generationNumber = toNumber(generation)" in tagger
                and "or generationNumber < 1 or role == nil then" in tagger
                and "local data = objectModData(object)" in tagger
                and "generated object has no modData for role " in tagger,
                "tagObject no longer verifies its local tag before the creator sends it",
            )
            checks.true(
                "generated object boundary identity is incomplete" in tagger
                and 'local rvId = type(tagContext) == "table" and tagContext.rvId or nil' in tagger
                and "tag.owner = OWNER" in tagger
                and "tag.rvId = tostring(rvId)" in tagger
                and "tag.generation = generationNumber" in tagger
                and "tag.role = role" in tagger
                and "data.RailroaderRV = tag" in tagger
                and "for key, value in pairs(extraData) do" in tagger
                and "bitmapVersion" not in tagger,
                "generated objects do not carry the full rvId/generation/bitmapVersion identity",
            )

        validate = section(
            generation_flow,
            r"local function validateRequest\(module, command, player\)",
            r"local function generateForPlayer",
        )
        checks.true(validate is not None, "validateRequest function is missing")
        if validate is not None:
            checks.true(
                "if module ~= COMMAND_MODULE then" in validate
                and 'return false, "invalid command module"' in validate
                and "if command ~= COMMAND then" in validate
                and 'return false, "invalid command"' in validate
                and "local ok, positionOrReason = validateAuthoritativePlayer(player)" in validate
                and "local permissionOk, permissionReason = validateGenerationPermission(player)" in validate
                and "return true, positionOrReason" in validate,
                "validateRequest does not call strict payload validation",
            )
            checks.true(
                "isEmptyCommandArgs" not in validate
                and "args" not in validate,
                "validateRequest still rejects every non-plain-table payload",
            )

        relocation_safety = section(
            wall_reload_source,
            r"local function temporaryDestination\(boundary\)",
            r"local function sendRelocate\(",
        )
        checks.true(relocation_safety is not None, "relocation square safety helper is missing")
        if relocation_safety is not None:
            for required_check in (
                "local originX = ServerUtil.integer(managed.originX)",
                "local originY = ServerUtil.integer(managed.originY)",
                "local minZ = ServerUtil.integer(managed.minZ)",
                "local x = originX - Constants.ROOF_REFRESH_REMOTE_OFFSET_X",
                "local y = originY - Constants.ROOF_REFRESH_REMOTE_OFFSET_Y",
                "local z = minZ - Constants.ROOF_REFRESH_REMOTE_OFFSET_Z",
                "if z < Constants.WORLD_MIN_Z or z > Constants.WORLD_MAX_Z then",
                'local worldOk, world = ServerUtil.callGlobal("getWorld")',
                'local validOk, valid = ServerUtil.invoke(world, "isValidSquare", x, y, z)',
                "wall reload temporary target is outside the legal world",
            ):
                checks.true(
                    required_check in relocation_safety,
                    f"relocation safety omits {required_check}",
                )
            checks.true(
                "TreatAsSolidFloor" not in (wall_reload_source + server)
                and "getIsoWorldRegion" not in player_validation
                and "squareIsSafeForRelocation" not in (wall_reload_source + server),
                "relocation square safety still inspects live square contents",
            )

        relocation_search = section(
            generation_flow,
            r"local function selectGenerationStagingDestination",
            r"local function playerIsAtStagingDestination",
        )
        checks.true(relocation_search is not None, "center generation staging helper is missing")
        if relocation_search is not None:
            checks.true(
                "local originX, originY = bounds.managedOriginX, bounds.managedOriginY" in relocation_search
                and "local width, height = bounds.managedWidth, bounds.managedHeight" in relocation_search
                and "local GENERATION_STAGING_Z = -15" in generation_flow
                and "local bounds = ServerSchema.boundsFor(layout)" in generation_flow,
                "generation staging is not derived from the current managed center",
            )
            checks.true(
                "local destination = {" in relocation_search
                and "x = originX + math.floor(width / 2)," in relocation_search
                and "y = originY + math.floor(height / 2)," in relocation_search
                and "z = GENERATION_STAGING_Z," in relocation_search
                and 'purpose = "generation-center",' in relocation_search,
                "generation staging does not use the center z=-15 destination",
            )

        generation_staging_server = section(
            generation_flow,
            r"local function selectGenerationStagingDestination",
            r"local function playerIsAtStagingDestination",
        )
        checks.true(
            generation_staging_server is not None
            and all(
                token in generation_staging_server
                for token in (
                    "local originX, originY = bounds.managedOriginX, bounds.managedOriginY",
                    "local width, height = bounds.managedWidth, bounds.managedHeight",
                    "x = originX + math.floor(width / 2),",
                    "y = originY + math.floor(height / 2),",
                    "z = GENERATION_STAGING_Z,",
                    'purpose = "generation-center",',
                    'invoke(world, "isValidSquare", destination.x,',
                    "generation center staging coordinate is illegal",
                )
            )
            and "local GENERATION_STAGING_Z = -15" in generation_flow
            and 'ServerUtil.callGlobal("getWorld")' in generation_staging_server
            and "bitmap" not in generation_staging_server,
            "first generation staging is not the current managed-scope center at z=-15",
        )
        checks.true(
            "local GENERATION_STAGING_Z = -15" in generation_flow
            and "z = GENERATION_STAGING_Z," in generation_flow
            and "generationTransition = true," in player_validation
            and 'generationPhase = phase == "return" and "return" or "temporary",' in player_validation
            and "local function keepGenerationTransitionAlive(record)" in player_validation
            and "local function sendStagingRelocation(record, phase)" in player_validation
            and 'setGenerationPhase(generation, "CLEARING")' in generation_build
            and 'setGenerationPhase(generation, "CAPTURED_TEMPLATE")' in generation_build
            and 'GENERATION_HALO_TEXT = getText("UI_RailroaderRV_GenerationHalo")' in client
            and "RELOCATION_SENTINEL_Z" not in constants
            and "RELOCATION_SENTINEL_Z" not in server,
            "generation staging phase marker or exact local Chinese halo is missing",
        )

        queue = section(
            generation_flow,
            r"local function queueGeneration",
            r"ctx\.queueGeneration\s*=",
        )
        checks.true(queue is not None, "delayed generation queue is missing")
        if queue is not None:
            checks.true(
                "GenerationTransaction.isActive()" in queue
                and 'return false, "generation already queued or in progress"' in queue
                and "if GenerationTransaction.owns(player) ~= true" in generation_flow
                and 'return false, "generation already in progress"' in generation_flow
                and "function api.begin(player, recordTable)" in generation_transaction
                and "function api.owns(player, token)" in generation_transaction
                and "function api.isActive()" in generation_transaction
                and "ctx.pendingGeneration" not in queue
                and "ctx.transactionBusy" not in queue,
                "generation queue does not reject duplicate/pending requests",
            )
            checks.true(
                "local allocated, selectedSlot, anchor, priorGeneration = allocateRVRegion(" in queue
                and "local slotIndex = selectedSlot" in queue
                and "local layout = Layout.make(targetX, targetY, targetZ, templateId)" in queue
                and "local bounds = ServerSchema.boundsFor(layout)" in queue
                and "finalDestination = {" in queue
                and "stagingDestination = {" in queue
                and "GenerationTransaction.begin(player, record)" in queue
                and "local anchor = RegionSlots.indexToAnchor(slotIndex)" in mapping
                and "local slotIndex, anchor = RegionSlots.findFirstFree(occupied)" in mapping
                and "requiredInteger" not in queue
                and "layoutOrError" not in queue
                and "oldBounds" not in queue,
                "Mapping-selected matrix slot cleanup plan is not captured before relocation",
            )
            checks.true(
                "if priorGeneration ~= nil then" in queue
                and 'return false, "RailroaderRV: locomotive already has a completed RV mapping"' in queue
                and "if not validMappingRecord(existing) then" in mapping
                and "return false, C.INVALID_RV_DATA" in mapping
                and "local slotIndex = integer(existing.slotIndex)" in mapping
                and "local anchor = RegionSlots.indexToAnchor(slotIndex)" in mapping
                and "if not anchor then return false, C.INVALID_RV_DATA end" in mapping
                and "function RV.Server.currentRVManifestForBoundary(rvId, generation)" in record_validation
                and "function RV.Server.currentRVManifestForRelocation(rvId, generation)" in record_validation
                and "if not recordOk then return false, record end" in record_validation
                and "removeOldGeneration" not in generation_flow
                and "previous generation has no complete undo snapshot" not in generation_flow
                and "oldBounds" not in generation_flow
                and "manifest" not in queue,
                "same-slot rebuild is not refused when its prior generation lacks a complete undo snapshot",
            )
            checks.true(
                "local function mapData()" in mapping
                and "return ModData.get(C.RV_MAP_KEY)" in mapping
                and "local map = mapData()" in mapping
                and "local existing = recordForLoco(map, tostring(locoId))" in mapping
                and "local ok, manifest = pcall(function()" in record_validation
                and "if not ok or type(manifest) ~= \"table\" then" in record_validation
                and "local recordOk, record = currentMappingRecord(rvId, generation)" in record_validation
                and "if manifestAccepted ~= true or type(manifest) ~= \"table\" then" in record_validation
                and "pcall(manifestTable)" not in queue
                and "manifestSlot" not in queue
                and "manifestRvId" not in queue
                and "persistedBoundsMatchBoundary" not in queue
                and "prior bounds are untrusted" not in queue,
                "generation queue does not check the current manifest root before using its fields",
            )
            validation_pos = queue.find(
                "ServerSchema.validateTargetCoordinates(bounds, anchorPosition)"
            )
            staging_send_pos = queue.find(
                'sendStagingRelocation(record, "temporary")'
            )
            relocate_send_pos = player_validation.find(
                "sendRelocate(record.player, payload)"
            )
            teleport_pos = player_validation.find(
                "RV.Server.teleportToPosition(record.player, {"
            )
            checks.true(
                validation_pos >= 0
                and staging_send_pos > validation_pos
                and relocate_send_pos >= 0
                and teleport_pos > relocate_send_pos,
                "target legality validation is not ordered before relocation and server teleport",
            )
            checks.true(
                'local sentOk, sentReason = sendStagingRelocation(record, "temporary")' in queue
                and 'return ServerUtil.callGlobalSucceeded("sendServerCommand", player,' in player_validation
                and "COMMAND_MODULE, COMMAND_RELOCATE, payload)" in player_validation
                and "or not RV.Server.teleportToPosition(record.player, {" in player_validation
                and 'return false, "server-to-client relocation command failed"' in player_validation
                and "COMMAND_RELOCATE = COMMAND_RELOCATE," in server_facade
                and "RV.Server.teleportToPosition = ServerTeleport.teleportToPosition" in server_facade
                and 'callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE' not in queue,
                "queue does not relocate both targeted client and authoritative server player",
            )
            staging_relocation = section(
                player_validation,
                r"local function sendStagingRelocation",
                r"local function sendFinalRelocation",
            )
            checks.true(
                staging_relocation is not None
                and re.search(
                    r'local target = phase == "return" and record\.originalPosition\s*'
                    r'or record\.stagingDestination',
                    staging_relocation,
                ) is not None
                and re.search(
                    r'local teleportX = phase == "return" and target\.x or target\.x \+ 0\.5',
                    staging_relocation,
                ) is not None
                and re.search(
                    r'local teleportY = phase == "return" and target\.y or target\.y \+ 0\.5',
                    staging_relocation,
                ) is not None
                and "or not RV.Server.teleportToPosition(record.player, {" in staging_relocation
                and re.search(
                    r'sendStagingRelocation\(record, "temporary"\)',
                    queue,
                ) is not None
                and "finalDestination" not in staging_relocation
                and '"teleportTo"' not in staging_relocation,
                "server initial teleport must use staging, never the anchor destination",
            )
            checks.true(
                "local stagingDestination = selectGenerationStagingDestination(layout, bounds)" in queue
                and "x = stagingDestination.x," in queue
                and "y = stagingDestination.y," in queue
                and "z = stagingDestination.z," in queue
                and "purpose = stagingDestination.purpose," in queue
                and "x = target.x," in player_validation
                and "y = target.y," in player_validation
                and "z = target.z," in player_validation
                and "generationTransition = true," in player_validation
                and 'generationPhase = phase == "return" and "return" or "temporary",' in player_validation
                and "plannedBounds" not in queue,
                "queue does not use the server-selected staging destination",
            )
            checks.true(
                "local record = {" in queue
                and "identity = identityOrReason," in queue
                and "originalPosition = {" in queue
                and "token = token," in queue
                and "deadlineTick = ctx.serverTick + RELOCATION_TIMEOUT_TICKS," in queue
                and "GenerationTransaction.begin(player, record)" in queue
                and "No durable mutation record: the in-memory record is the gate." in generation_flow
                and "relocationServices.relocationLedger" not in queue
                and "ctx.pendingGeneration" not in queue
                and "queuedAtTick" not in queue
                and "ModData" not in queue,
                "generation staging does not retain its exact identity/position in process memory",
            )
            checks.true(
                "preflightLoaded" not in queue
                and "targetAreaLoadStatus" not in queue
                and "getSquare(" not in queue
                and "getGridSquare" not in queue,
                "queue still requires the remote target or complete footprint before teleport",
            )
            checks.true(
                "GameServer.sendTeleport" in queue,
                "queue does not document why the custom B42 Lua relocation bridge is required",
            )
            checks.true(
                "removeOldGeneration" not in queue and "buildGeneration" not in queue,
                "queue mutates the world before relocation acknowledgement",
            )

        clear_cleanup = section(
            generation_build,
            r"local function clearGenerationArea",
            r"local function buildGeneration",
        )
        checks.true(
            clear_cleanup is not None
            and "ServerSchema.walkBounds(cell, bounds, function(square)" in clear_cleanup
            and "ServerWorld.clearSquare(square, nil)" in clear_cleanup
            and "Scan the full managed bounds, including remnants from any failed earlier" in clear_cleanup
            and "A new unmapped generation starts with this complete clear pass." in clear_cleanup
            and "A failed generation leaves world changes in place; when no mapping exists, the next attempt clears the managed bounds and starts generation again." in server_agent_doc
            and "if not pending or pending.stage ~= \"BUILD\" then" in construction
            and 'error("RailroaderRV: generation is not in its current clear phase")' in construction
            and "clearing requires an empty scope because no complete undo" not in construction
            and "strictSquareSnapshot" not in construction
            and "preflightClearTarget" not in construction
            and "previous generation has no complete undo snapshot" not in construction,
            "clear preflight must snapshot each existing square and reject objects without a complete undo path",
        )
        checks.true(
            clear_cleanup is not None
            and "ServerSchema.walkBounds(cell, bounds, function(square)" in clear_cleanup
            and "ServerWorld.clearSquare(square, nil)" in clear_cleanup
            and "local function walkBounds(cell, bounds, fn, requireLoaded)" in server_schema
            and "local square = ServerWorld.getSquare(cell, x, y, z)" in server_schema
            and "if not square and requireLoaded == true then" in server_schema
            and "if square then" in server_schema
            and "fn(square, x, y, z)" in server_schema
            and "local function squareSnapshot(square)" in server_world
            and "local function collectionSnapshot(collection)" in server_world
            and "squareSnapshotInternal" not in server_world
            and "strictSquareSnapshot" not in server_world,
            "preflight and clear must share a bounds walker that skips missing squares",
        )
        checks.true(
            "local function collectionSnapshot(collection)" in server_world
            and 'local okSize, size = ServerUtil.invoke(collection, "size")' in server_world
            and "local sizeNumber = ServerUtil.toNumber(size)" in server_world
            and "if okSize and sizeNumber and sizeNumber >= 0" in server_world
            and 'local okItem, item = ServerUtil.invoke(collection, "get", i)' in server_world
            and "if okItem and item then" in server_world
            and 'local okFloor, floor = ServerUtil.invoke(square, "getFloor")' in server_world
            and 'local sizeOk, size = ServerUtil.invoke(objects, "size")' in server_world
            and "if stillPresent ~= false then" in server_world
            and 'error("RailroaderRV: object removal was not observable")' in server_world
            and 'error("RailroaderRV: clear bounds contain an unloaded square")' in server_schema
            and "clear bounds contain an unloaded square" not in utilities_only
            and "squareSnapshotInternal" not in server_world,
            "unknown square occupancy or a partial collection can still be silently accepted",
        )
        checks.true(
            "local function clearGenerationArea(cell, bounds, generation)" in generation_build
            and 'setGenerationPhase(generation, "CLEARING")' in generation_build
            and "ServerSchema.walkBounds(cell, bounds, function(square)" in generation_build
            and "ServerWorld.clearSquare(square, nil)" in generation_build
            and "function service.clearCurrentGeneration(cell, bounds, generation)" in construction
            and "requireCurrentMutation(player)" in construction
            and "operations.clear(cell, bounds, generation)" in construction
            and "previous generation has no complete undo snapshot" not in generation_build
            and "clearing requires an empty scope because no complete undo" not in generation_build
            and "strictSquareSnapshot" not in generation_build,
            "preflight can clear existing objects without a complete inverse snapshot",
        )

        def policy_allows_clear(
            square_exists: bool,
            enumeration_complete: bool,
            occupants: list[bool],
        ) -> bool:
            if not square_exists:
                return True
            if not enumeration_complete:
                return False
            return len(occupants) == 0

        preflight_cases = (
            ("empty existing square", True, True, [], True),
            ("missing square is skipped", False, False, [], True),
            ("incomplete object enumeration", True, False, [], False),
            ("player object", True, True, [True], False),
            ("object without complete undo", True, True, [False], False),
        )
        for name, square_exists, complete, occupants, expected in preflight_cases:
            checks.true(
                policy_allows_clear(square_exists, complete, occupants) is expected,
                f"clear preflight policy matrix failed: {name}",
            )

        # An absent generation-queue section must fail the ordering contract below
        # instead of raising AttributeError on None.
        queue_source = queue if queue is not None else ""
        validation_pos = queue_source.find(
            "ServerSchema.validateTargetCoordinates(bounds, anchorPosition)"
        )
        staging_pos = queue_source.find(
            "local stagingDestination = selectGenerationStagingDestination(layout, bounds)"
        )
        begin_pos = queue_source.find("GenerationTransaction.begin(player, record)")
        relocation_pos = queue_source.find(
            'local sentOk, sentReason = sendStagingRelocation(record, "temporary")'
        )
        checks.true(
            queue is not None
            and validation_pos >= 0
            and staging_pos > validation_pos
            and begin_pos > staging_pos
            and relocation_pos > begin_pos
            and "Check map coordinates before either relocation." in queue
            and "construction.preflightCurrentGeneration" not in generation_flow
            and "manifest.techVersion =" not in generation_flow
            and "preserveManifestOnFailure" not in generation_flow
            and "preserveManifestOnFailure" not in generation_build,
            "read-only target preflight does not precede manifest writes or preserve the prior manifest on rejection",
        )

        target_coordinates = section(
            server_schema,
            r"local function validateTargetCoordinates\(bounds, destination\)",
            r"local function preflightLoaded",
        )
        checks.true(
            target_coordinates is not None,
            "pre-relocation target coordinate validation helper is missing",
        )
        if target_coordinates is not None:
            checks.true(
                "getWorld" in target_coordinates
                and 'invoke(world, "isValidSquare"' in target_coordinates
                and "getSquare(" not in target_coordinates
                and "getGridSquare" not in target_coordinates,
                "target coordinate validation reads squares or omits world legality checks",
            )
            checks.true(
                "local targetX, targetY, targetZ = destination.x, destination.y," in target_coordinates
                and "if RegionSlots.indexForAnchor({ x = targetX, y = targetY, z = targetZ }) == nil then" in target_coordinates
                and "outside the current RV slot matrix" in target_coordinates
                and "if targetX < bounds.roomMinX or targetX > bounds.roomMaxX" in target_coordinates
                and "or targetY < bounds.roomMinY or targetY > bounds.roomMaxY then" in target_coordinates
                and "final relocation center is outside the interior" in target_coordinates
                and "for y = bounds.clearMinY, bounds.clearMaxY - 1 do" in target_coordinates
                and "for x = bounds.clearMinX, bounds.clearMaxX - 1 do" in target_coordinates
                and 'validWorldCoordinate(x, y, bounds.z, "base")' in target_coordinates
                and "for y = bounds.roofMinY, bounds.roofMaxY do" in target_coordinates
                and "for x = bounds.roofMinX, bounds.roofMaxX do" in target_coordinates
                and 'validWorldCoordinate(x, y, bounds.roofZ, "roof")' in target_coordinates
                and "layout z bounds are outside the legal world" in target_coordinates
                and "clearMinX ~= targetX - 50" not in target_coordinates
                and "bounds.roomMaxX - bounds.roomMinX + 1 ~= 6" not in target_coordinates
                and "{ minX = -4, maxX = 2, minY = -6, maxY = 17," in captured_template
                and "Slots.REGION_SIZE = C.RV_REGION_SIZE" in region_slots
                and "maxX = minX + SIZE" in region_slots
                and "maxY = minY + SIZE" in region_slots,
                "target coordinate validation does not enforce the fixed cleanup and 6x23 room contract",
            )

        preflight = section(
            server_schema,
            r"local function preflightLoaded\(cell, bounds(?:, allowIncomplete)?\)",
            r"local function targetAreaLoadStatus",
        )
        checks.true(preflight is not None, "loaded-area preflight is missing")
        if preflight is not None:
            checks.true(
                "The cleanup scope is half-open and every base square must be visible" in preflight
                and "for y = bounds.clearMinY, bounds.clearMaxY - 1 do" in preflight
                and "for x = bounds.clearMinX, bounds.clearMaxX - 1 do" in preflight
                and "local square = ServerWorld.getSquare(cell, x, y, bounds.z)" in preflight
                and "if not square then" in preflight
                and 'return false, "RailroaderRV: required base square is not loaded at "' in preflight
                and "return true" in preflight
                and "requiredLoaded" not in preflight
                and "Missing squares are valid for this sparse template" not in preflight
                and "bounds.roofMinY" not in preflight,
                "loaded-area preflight still requires non-template squares to exist",
            )

        load_wait = section(
            server_schema,
            r"local function targetAreaLoadStatus",
            r"M\.boundsFor\s*=",
        )
        checks.true(load_wait is not None, "post-teleport target loading wait is missing")
        if load_wait is not None:
            checks.true(
                "local cellOk, cellOrError = pcall(ServerWorld.getCellForPlayer, player)" in load_wait
                and 'string.find(message, "no IsoCell available", 1, true)' in load_wait
                and "local preflightOk, loaded, preflightError = pcall(preflightLoaded," in load_wait
                and "cellOrError, bounds)" in load_wait
                and "if loaded == true then" in load_wait
                and "if loaded == false then" in load_wait
                and "return false, safeText(preflightError)" in load_wait
                and "A remote teleport is also the engine's chunk-streaming trigger." in server_schema
                and "Retry only that expected loading failure" in server_schema
                and "return M" not in load_wait,
                "post-teleport wait does not retry an unavailable target cell",
            )
            checks.true(
                "if not cellOk then" in load_wait
                and "return nil, message" in load_wait
                and "if not preflightOk then" in load_wait
                and "return nil, safeText(loaded)" in load_wait
                and 'return nil, "RailroaderRV: loaded-area preflight returned no status"' in load_wait
                and "Unexpected contract/engine errors remain a hard cancellation" in load_wait,
                "post-teleport loading wait does not fail closed on non-loading errors",
            )

        cleanup = section(
            generation_build,
            r"local function clearGenerationArea",
            r"local function buildGeneration",
        )
        checks.true(cleanup is not None, "fixed cleanup helper is missing")
        if cleanup is not None:
            checks.true(
                "ServerWorld.clearSquare(square, nil)" in cleanup
                and "ServerSchema.walkBounds(cell, bounds" in cleanup,
                "fixed cleanup helper does not walk loaded squares authoritatively",
            )

        structure_recalc = section(
            generation_build,
            r"local function recalcAndCheckStructure",
            r"local function clearGenerationArea",
        )
        checks.true(
            structure_recalc is not None
            and "recalcAt(x, y, bounds.z, false)" in structure_recalc
            and "recalcAt(entry.x, entry.y, entry.z, true)" in structure_recalc,
            "structure recalculation requires blank room cells or skips defined template hosts",
        )

        build_generation = section(
            generation_build,
            r"local function buildGeneration",
            r"local rawClearGenerationArea = clearGenerationArea",
        )
        checks.true(build_generation is not None, "buildGeneration helper is missing")
        if build_generation is not None:
            checks.true(
                "METAL_FLOOR" not in build_generation
                and "metalSprite" not in build_generation
                and "metal_floor" not in build_generation,
                "buildGeneration still enables the retired full metal-floor stage",
            )
            checks.true(
                'setGenerationPhase(generation, "CAPTURED_TEMPLATE")' in build_generation
                and "local templateObjects = layout.templateObjects" in build_generation
                and "for i = 1, #templateObjects do" in build_generation
                and "createCapturedTemplateObject(cell, square, entry, generation, tagContext,"
                    in build_generation
                and "square = ensureRoofSquare(cell, entry.x, entry.y, entry.z)" in build_generation
                and 'setGenerationPhase(generation, "STRUCTURE_RECALC")' in build_generation
                and "createGenerator(cell, proxySquare, generation, tagContext)"
                    in build_generation,
                "buildGeneration does not apply only the current template object hosts",
            )

        entry_generator_helper = section(
            mapping,
            r"local function armRoomOwnershipMonitor\(player, record, reason\)",
            r"-- The reverse lookup intentionally starts",
        )
        checks.true(
            entry_generator_helper is not None,
            "existing-entry generator check helper is missing",
        )
        if entry_generator_helper is not None:
            checks.true(
                "server.armCurrentRoomOwnershipMonitor" in entry_generator_helper
                and "pcall(server.armCurrentRoomOwnershipMonitor" in entry_generator_helper
                and 'return false, "room ownership monitor service is unavailable"'
                    in entry_generator_helper
                and "return false, C.INVALID_RV_DATA" in entry_generator_helper
                and 'return false, detail or "room ownership monitor could not be armed"'
                    in entry_generator_helper,
                "entry generator repair does not require the committed current identity or roll back failed creation",
            )
        entry_existing_pos = entry_exit.find("local function enterExisting")
        monitor_entry_pos = entry_exit.find(
            "armRoomOwnershipMonitor(player, record,", entry_existing_pos)
        transition_pos = entry_exit.find("Boundary.beginTransition", monitor_entry_pos)
        teleport_pos = entry_exit.find('movePlayer(player, target, "enter"', transition_pos)
        checks.true(
            entry_existing_pos >= 0
            and monitor_entry_pos > entry_existing_pos
            and transition_pos > monitor_entry_pos
            and teleport_pos > transition_pos
            and "if not monitorOk then return false, monitorReason end" in entry_exit,
            "existing RV entry does not reject a failed generator check before transition/teleport",
        )

        generation = section(
            generation_flow,
            r"local function generateForPlayer",
            r"local function finalizeGenerationAfterRelocate",
        )
        checks.true(generation is not None, "generation transaction is missing")
        if generation is not None:
            checks.true(
                re.search(
                    r"(?m)^\s*buildOk, buildError = pcall\(buildGeneration,"
                    r"\s*player, layout, bounds,\s*generation\)"
                    ,
                    generation,
                )
                is not None,
                "room/object generation call is not enabled",
            )
            clear_call = generation.find(
                "local buildOk, buildError = pcall(clearGenerationArea"
            )
            build_call = generation.find(
                "buildOk, buildError = pcall(buildGeneration", clear_call
            )
            checks.true(
                clear_call >= 0 and build_call > clear_call,
                "buildGeneration is not ordered after clearGenerationArea",
            )
            cleanup_gate = section(
                generation,
                r"local buildOk, buildError = pcall\(clearGenerationArea",
                r"error\(buildError\)",
            )
            checks.true(cleanup_gate is not None, "cleanup/build gate is missing")
            if cleanup_gate is not None:
                checks.true(
                    re.search(
                        r"if buildOk then\s+buildOk, buildError = pcall\(buildGeneration,"
                        r"\s*player, layout, bounds,\s*generation\)\s+end",
                        cleanup_gate,
                    )
                    is not None,
                    "cleanup failure does not short-circuit before buildGeneration",
                )
            failure_call = generation.find("error(buildError)")
            abort_call = generation_ack.find(
                "local function abortGeneration(record, reason)")
            release_call = generation_ack.find(
                "GenerationTransaction.release()", abort_call)
            checks.true(
                failure_call > generation.find("pcall(buildGeneration")
                and "return false, safeErrorText(resultOrError)" in generation
                and "runGenerationAbort(record, buildReason)" in server_commands
                and abort_call >= 0
                and release_call > abort_call,
                "generation failure does not enter the existing rollback path",
            )
            final_relocate = generation.find("relocatePlayerIntoHouse, player, prepared")
            await_final_relocate = generation.find('return "await-final-relocate"')
            checks.true(
                final_relocate > build_call
                and await_final_relocate > final_relocate
                and 'setManifestState(manifest, "READY")' not in generation,
                "post-build final relocation does not hand off to its asynchronous ACK phase",
            )
            checks.true(
                'ctx.setGenerationPhase(generation, "FINAL_RELOCATE")' in generation
                and "local finalRelocationOk, finalRelocationError = pcall(" in generation
                and "error(finalRelocationError)" in generation
                and "GenerationTransaction.release()" not in generation,
                "final relocation failure does not enter the generation rollback path",
            )
            phase_pos = generation_flow.find(
                'ctx.setGenerationPhase(generation, "FINAL_RELOCATE")'
            )
            checks.true(
                phase_pos >= 0
                and phase_pos < generation_flow.find('return "await-final-relocate"')
                and 'prepared.stage = "WAIT_FINAL"' in generation_flow
                and "prepared.finalAcked = false" in generation_flow
                and "record.finalAcked = true" in generation_ack
                and 'record.stage ~= "WAIT_FINAL"' in generation_ack
                and "publishFinalRelocationLedger" not in generation_flow + generation_ack,
                "generation FINAL_RELOCATE does not use its process-local ACK transaction",
            )

        final_relocation = section(
            generation_flow,
            r"local function relocatePlayerIntoHouse",
            r"local function generateForPlayer",
        )
        checks.true(final_relocation is not None, "final in-house relocation helper is missing")
        if final_relocation is not None:
            final_relocation_send = section(
                player_validation,
                r"-- Re-state the final in-house relocation",
                r"-- Keep the token-scoped Boundary lease armed",
            )
            checks.true(
                final_relocation_send is not None
                and "sendFinalRelocation(prepared," in final_relocation
                and 'prepared.stage = "WAIT_FINAL"' in final_relocation
                and "prepared.finalAcked = false" in final_relocation
                and 'COMMAND_FINAL_RELOCATE' in final_relocation_send
                and 'x = target.x,' in final_relocation_send
                and 'y = target.y,' in final_relocation_send
                and 'z = target.z,' in final_relocation_send
                and 'callSucceeded(record.player, "setX", target.x)'
                    in final_relocation_send
                and 'ServerUtil.callSucceeded(record.player, "setY", target.y)'
                    in final_relocation_send
                and "RV.Server.teleportToPosition(record.player, target)"
                    in final_relocation_send,
                "final relocation does not send and synchronize server-selected coordinates",
            )
            checks.true(
                "anchorX + 0.5" in final_relocation
                and "anchorY + 0.5" in final_relocation,
                "final relocation is not fixed to the house interior center",
            )

        final_ack = section(
            generation_ack,
            r"local function acknowledgeFinalRelocation",
            r"-- The one abort path",
        )
        checks.true(
            final_ack is not None
            and 'record.stage ~= "WAIT_FINAL"' in final_ack
            and "resolvePendingPlayer(record)" in final_ack
            and "generationPositionProof(" in final_ack
            and "final relocation target proof mismatch" in final_ack
            and "record.finalAcked = true" in final_ack
            and "sendFinalRelocation(prepared)" in generation_flow
            and "final relocation authoritative target is still synchronizing"
                in generation_flow,
            "final relocation ACK does not perform one bounded server-target reassertion",
        )
        final_generation = section(
            generation_flow,
            r"local function finalizeGenerationAfterRelocate",
            r"local function queueGeneration",
        )
        checks.true(
            final_generation is not None
            and "final relocation authoritative target is still synchronizing" in final_generation
            and "final relocation target pending" in final_generation
            and "generationPositionProof(player, target)" in final_generation
            and "positionMismatch == true" in final_generation
            and final_generation.find("sendFinalRelocation(prepared)")
                < final_generation.find(
                    'return false, "final relocation authoritative target is still synchronizing"'),
            "generation finalization does not wait for a post-update authoritative target proof",
        )
        checks.true(
            final_generation is not None
            and 'refreshGenerationRoomOwnershipGuard(prepared.rvId,' in final_generation
            and '"before-commit"' in final_generation
            and '"pre-mapping-commit"' in final_generation
            and final_generation.find('"before-commit"')
                < final_generation.find("Boundary.completeTransition(player, prepared.token)")
            and final_generation.find("Boundary.completeTransition(player, prepared.token)")
                < final_generation.find('"pre-mapping-commit"')
            and final_generation.find('"pre-mapping-commit"')
                < final_generation.find("local commitOk"),
            "manifest commit is missing its room-ownership scan after READY and before mapping publication",
        )

        tick = section(
            server_commands,
            r"local function processPendingGeneration\(\)",
            r"function RV\.Server\.OnClientCommand",
        )
        checks.true(tick is not None, "pending generation OnTick processor is missing")
        if tick is not None:
            for required_guard in (
                "processServerRoomOwnershipGuards()",
                "GenerationTransaction.current()",
                "if ctx.serverTick > record.deadlineTick then",
                "resolvePendingPlayer(record)",
                "playerIsAtStagingDestination(player,",
                "ServerSchema.targetAreaLoadStatus(",
                "runGenerationAbort(record,",
                "GenerationTransaction.release()",
            ):
                checks.true(
                    required_guard in tick,
                    f"pending generation tick omits {required_guard}",
                )
            checks.true(
                tick.find("playerIsAtStagingDestination") < tick.find("generateForPlayer"),
                "world generation can run before the server verifies relocation",
            )
            checks.true(
                tick.find("targetAreaLoadStatus") < tick.find("generateForPlayer")
                and tick.find("targetAreaLoadStatus") > tick.find("playerIsAtStagingDestination"),
                "cleanup can run before the post-teleport loaded-area wait",
            )
            checks.true(
                "GenerationTransaction.release()" in tick,
                "pending generation is not cleared after completion/failure",
            )
            checks.true(
                "final relocation authoritative target is still synchronizing" in tick
                and 'commitReason == "final relocation authoritative target is still synchronizing"'
                    in tick
                and tick.find(
                    'commitReason == "final relocation authoritative target is still synchronizing"')
                    < tick.find("runGenerationAbort(record, commitReason)")
                and "generation transaction timed out in stage " in tick,
                "generation OnTick treats stale final-relocation coordinates as an immediate hard failure",
            )
            checks.true(
                "ServerSchema.targetAreaLoadStatus(" in tick
                and "local built, buildReason = generateForPlayer(player, record)" in tick
                and tick.find("ServerSchema.targetAreaLoadStatus(")
                < tick.find("local built, buildReason = generateForPlayer(player, record)"),
                "post-teleport target loading wait is not ordered before generation",
            )

            destination_wait = section(
                tick,
                r"if not atStaging then",
                r"local built, buildReason = generateForPlayer",
            )
            checks.true(
                destination_wait is not None,
                "pending generation destination wait branch is missing",
            )
            if destination_wait is not None:
                wait_pos = destination_wait.find(
                    "[RailroaderRV] generation staging not settled: ")
                wait_return_pos = destination_wait.find("return", wait_pos)
                hard_cancel_pos = destination_wait.find(
                    "runGenerationAbort(record,", wait_return_pos)
                checks.true(
                    wait_pos >= 0
                    and wait_return_pos > wait_pos
                    and hard_cancel_pos > wait_return_pos,
                    "first server-position mismatch does not wait before hard cancellation",
                )
                checks.true(
                    "generateForPlayer" not in destination_wait,
                    "relocation wait branch can generate before exact server arrival",
                )

            wait_helper = section(
                server_commands,
                r"local function processPendingGeneration\(\)",
                r"function RV\.Server\.OnTick\(tick\)",
            )
            checks.true(
                wait_helper is not None,
                "relocation position synchronization helper is missing",
            )
            if wait_helper is not None:
                for transient_reason in (
                    "generation staging not settled: ",
                    "generation transaction timed out in stage ",
                    "final relocation authoritative target is still synchronizing",
                ):
                    checks.true(
                        transient_reason in wait_helper,
                        f"relocation wait helper omits transient reason: {transient_reason}",
                    )

            executor_pos = generation_flow.find(
                "local function generateForPlayer(player, prepared)")
            state_pos = generation_flow.find(
                "validateAuthoritativePlayer(player)", executor_pos)
            permission_pos = generation_flow.find(
                "validateGenerationPermission(player)", executor_pos)
            clear_pos = generation_flow.find("pcall(clearGenerationArea", executor_pos)
            ack_gate_pos = tick.find("if record.stagingAcked ~= true then")
            generation_pos = tick.find(
                "local built, buildReason = generateForPlayer(player, record)")
            checks.true(
                permission_pos >= 0
                and state_pos > executor_pos
                and state_pos < permission_pos
                and clear_pos > permission_pos
                and ack_gate_pos >= 0
                and generation_pos > ack_gate_pos,
                "relocation wait does not recheck permission/liveness before the ack gate and generation",
            )
            timeout_pos = tick.find("if ctx.serverTick > record.deadlineTick then")
            timeout_cancel_pos = tick.find("runGenerationAbort(record,", timeout_pos)
            checks.true(
                timeout_pos >= 0
                and timeout_cancel_pos > timeout_pos
                and "runGenerationAbort" in tick
                and generation_pos > timeout_cancel_pos,
                "relocation timeout does not cancel before any generation call",
            )

            for cancellation_reason in (
                "requesting player disconnected or was replaced",
                "requesting player identity changed",
                "sender is dead or has no authoritative death state",
                "sender lacks UseDebugContextMenu capability",
            ):
                checks.true(
                    cancellation_reason in player_validation + generation_flow,
                    f"relocation safety regression omits cancellation reason: {cancellation_reason}",
                )

        prepared_generate = section(
            generation_flow,
            r"local function generateForPlayer\(player, prepared\)",
            r"local function finalizeGenerationAfterRelocate",
        )
        checks.true(prepared_generate is not None, "prepared generation executor is missing")
        if prepared_generate is not None:
            checks.true(
                "makeLayout(" not in prepared_generate
                and "local layout = prepared.layout" in prepared_generate
                and "local bounds = prepared.bounds" in prepared_generate,
                "generation executor recomputes layout from the evacuated position",
            )
            destination_check = prepared_generate.find(
                "playerIsAtStagingDestination"
            )
            transaction_gate = prepared_generate.find(
                "GenerationTransaction.owns(player) ~= true"
            )
            checks.true(
                transaction_gate >= 0
                and destination_check >= 0
                and 'prepared.stage ~= "WAIT_STAGING"' in prepared_generate
                and "requesting player identity changed" in prepared_generate
                and transaction_gate < prepared_generate.find("pcall(clearGenerationArea")
                and "GenerationTransaction.release()" not in prepared_generate,
                "generation can clear an old same-slot room without a complete undo snapshot",
            )
            preflight_pos = server_commands.find("ServerSchema.targetAreaLoadStatus(")
            executor_call_pos = server_commands.find(
                "local built, buildReason = generateForPlayer(player, record)")
            executor_clear_pos = prepared_generate.find("pcall(clearGenerationArea")
            executor_build_pos = prepared_generate.find("pcall(buildGeneration")
            checks.true(
                destination_check >= 0
                and preflight_pos >= 0
                and executor_call_pos > preflight_pos
                and executor_clear_pos > destination_check
                and executor_build_pos > executor_clear_pos,
                "cleanup transaction does not keep the final loaded-area preflight before mutation",
            )
            arm_pos = prepared_generate.find("armClientRoomOwnershipGuard")
            server_guard_pos = prepared_generate.find(
                "registerServerRoomOwnershipGuard"
            )
            generation_build_pos = prepared_generate.find("pcall(buildGeneration")
            checks.true(
                arm_pos >= 0
                and server_guard_pos > arm_pos
                and generation_build_pos > server_guard_pos,
                "client/server stale-room guards are not registered before generation build",
            )
            checks.true(
                '"before-final-relocate"' in prepared_generate,
                "server stale-room refresh is missing immediately before final relocation",
            )

        structure_scan = section(
            room_ownership,
            r"local function clearInvalidRoomOwnershipBounds\(cell, bounds\)",
            r"local function objectCoordinates",
        )
        structure_footprint = section(
            room_ownership,
            r"local function copyRoomRefreshBounds\(target, prefix, bounds\)",
            r"local function armClientRoomOwnershipGuard",
        )
        checks.true(
            structure_scan is not None and structure_footprint is not None,
            "server complete old structure-footprint scanner is missing",
        )
        if structure_scan is not None and structure_footprint is not None:
            for footprint_field in (
                "wallMinX",
                "wallMaxX",
                "wallMinY",
                "wallMaxY",
                "roofMinX",
                "roofMaxX",
                "roofMinY",
                "roofMaxY",
                "roofZ",
            ):
                checks.true(
                    footprint_field in structure_scan,
                    f"server stale-room scan omits old footprint field {footprint_field}",
                )
            checks.true(
                "roomMinX" not in structure_scan
                and "roomMaxX" not in structure_scan
                and "roomMinY" not in structure_scan
                and "roomMaxY" not in structure_scan
                and "local seen" not in structure_scan
                and "seen[key]" not in structure_scan
                and "Layout.eachStructureCoordinate(bounds, function(x, y, z)" in structure_scan
                and "ServerWorld.getSquare(cell, x, y, z)" in structure_scan
                and "ServerUtil.requiredInteger(bounds[field]," in structure_footprint,
                "server stale-room scan does not share the coordinate traversal or retain strict server bounds and square access",
            )
        structure_coordinates = section(
            layout,
            r"function Layout\.eachStructureCoordinate",
            r"local function point",
        )
        checks.true(
            structure_coordinates is not None
            and "for x = bounds.wallMinX, bounds.wallMaxX do" in structure_coordinates
            and "for y = bounds.wallMinY, bounds.wallMaxY do" in structure_coordinates
            and "callback(x, y, bounds.z)" in structure_coordinates
            and "local anchorX = bounds.roomMinX - walkGeometry.minX" in structure_coordinates
            and "local anchorY = bounds.roomMinY - walkGeometry.minY" in structure_coordinates
            and "for i = 1, #roofCells do" in structure_coordinates
            and "local cell = roofCells[i]" in structure_coordinates
            and "if x >= bounds.roofMinX and x <= bounds.roofMaxX" in structure_coordinates
            and "and y >= bounds.roofMinY and y <= bounds.roofMaxY then" in structure_coordinates
            and "callback(x, y, bounds.roofZ)" in structure_coordinates,
            "shared structure traversal does not scan the base walls plus unique captured roof squares",
        )

        server_room_clear = section(
            room_ownership,
            r"local function clearInvalidRoomOwnershipBounds\(cell, bounds\)",
            r"local function coordinatesInRoomOwnershipBounds",
        )
        server_room_square_clear = section(
            room_ownership,
            r"local function clearInvalidRoomOwnershipSquare\(square\)",
            r"local function clearInvalidRoomOwnershipBounds",
        )
        server_room_refresh = section(
            room_ownership,
            r"local function refreshServerRoomOwnershipGuard\(guard, phase\)",
            r"local function refreshGenerationRoomOwnershipGuard",
        )
        checks.true(server_room_clear is not None, "server stale-room correction is missing")
        checks.true(
            server_room_square_clear is not None,
            "server stale-room square inspector is missing",
        )
        if server_room_clear is not None and server_room_square_clear is not None:
            checks.true(
                "clearInvalidRoomOwnershipSquare(square)" in server_room_clear
                and 'invoke(square, "getRoom")' in server_room_square_clear
                and 'invoke(square, "getRoomDef")' in server_room_square_clear
                and "if roomDef ~= nil then return false end" in server_room_square_clear,
                "server stale-room correction does not require room!=nil and RoomDef=nil",
            )
            checks.true(
                server_room_square_clear.count('callSucceeded(square, "setRoomID", -1)') == 1
                and server_room_square_clear.find("if roomDef ~= nil then return false end")
                < server_room_square_clear.find('callSucceeded(square, "setRoomID", -1)'),
                "server stale-room correction is absent, duplicated, or outside the RoomDef=nil branch",
            )
            checks.true(
                '"setRoom"' not in server_room_square_clear
                and "ResetIsoWorldRegion" not in server_room_square_clear
                and "RecalcAllWithNeighbours" not in server_room_square_clear,
                "server stale-room correction mutates valid engine room/region state",
            )
            checks.true(
                server_room_refresh is not None
                and server_room_refresh.count("clearInvalidRoomOwnershipBounds(") == 2
                and "clearInvalidRoomOwnershipBounds(cells[i]," in server_room_refresh
                and "guard.oldBounds)" in server_room_refresh
                and "guard.newBounds)" in server_room_refresh
                and "for i = 1, #cells do" in server_room_refresh,
                "server stale-room correction does not cover complete old and new footprints",
            )

        room_guard_broadcast = section(
            room_ownership,
            r"local function armClientRoomOwnershipGuard",
            r"local function armTargetedClientRoomOwnershipGuard",
        )
        checks.true(room_guard_broadcast is not None, "client room-guard broadcast is missing")
        if room_guard_broadcast is not None:
            checks.true(
                'callGlobalSucceeded("sendServerCommand", COMMAND_MODULE,'
                in room_guard_broadcast
                and 'callGlobal("sendServerCommand", player,'
                not in room_guard_broadcast,
                "stale-room guard is targeted only to the requester instead of all clients",
            )
            checks.true(
                "copyRoomRefreshBounds(payload, \"old\", oldBounds)"
                in room_guard_broadcast
                and "copyRoomRefreshBounds(payload, \"new\", newBounds)"
                in room_guard_broadcast,
                "broadcast room guard does not carry server-authoritative old/new bounds",
            )

        targeted_room_guard = section(
            room_ownership,
            r"local function armTargetedClientRoomOwnershipGuard",
            r"ctx\.armTargetedClientRoomOwnershipGuard\s*=",
        )
        checks.true(
            targeted_room_guard is not None,
            "targeted existing-entry room monitor helper is missing",
        )
        if targeted_room_guard is not None:
            checks.true(
                'callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,'
                in targeted_room_guard
                and "hasOld = false" in targeted_room_guard
                and 'copyRoomRefreshBounds(payload, "new", newBounds)'
                in targeted_room_guard,
                "targeted room monitor does not send only the current server bounds",
            )

        current_room_monitor = section(
            record_validation,
            r"function RV\.Server\.armCurrentRoomOwnershipMonitor",
            r"\nend\s*\n\s*end\s*$",
        )
        checks.true(
            current_room_monitor is not None,
            "current-manifest room monitor API is missing",
        )
        if current_room_monitor is not None:
            checks.true(
                "pcall(transaction.current)" in current_room_monitor
                and "RV.Server.currentRVManifestForBoundary(" in current_room_monitor
                and "manifest.bounds" in current_room_monitor
                and "manifest.rvId" in current_room_monitor
                and "record.locoId" in current_room_monitor
                and "record.generation" in current_room_monitor
                and "manifest.generation" in current_room_monitor
                and "return false, Constants.INVALID_RV_DATA"
                in current_room_monitor,
                "existing-entry monitor does not fail closed on current identity/schema",
            )

        server_guard_tick = section(
            room_ownership,
            r"local function processServerRoomOwnershipGuards",
            r"local function copyRoomRefreshBounds",
        )
        checks.true(server_guard_tick is not None, "server stale-room tick guard is missing")
        if server_guard_tick is not None:
            checks.true(
                "ROOM_OWNERSHIP_3X3_INTERVAL_TICKS" in server_guard_tick
                and "guard.scanDueTick ~= nil and ctx.serverTick >= guard.scanDueTick" in server_guard_tick
                and "guard.nextNeighborhoodProbeTick = ctx.serverTick" in server_guard_tick
                and "-- One guard per RV identity, kept for that identity's lifetime: a later"
                in room_ownership
                and "if existing.rvId == guard.rvId then" in room_ownership
                and "roomOwnershipGuards[key] = nil" in room_ownership
                and "roomOwnershipGuards[guard.key] = guard" in room_ownership
                and "ROOM_OWNERSHIP_MIN_TICKS" not in room_ownership
                and "ROOM_OWNERSHIP_STABLE_TICKS" not in room_ownership
                and "ROOM_OWNERSHIP_MAX_TICKS" not in room_ownership,
                "server stale-room guard lacks bounded and stable lifecycle",
            )
            checks.true(
                "if not hasGuards then return end" in server_guard_tick
                and "guard.scanDueTick = nil" in server_guard_tick
                and "for _, guard in pairs(roomOwnershipGuards) do" in server_guard_tick,
                "server stale-room guard is not cleaned after completion/timeout",
            )
            checks.true(
                "if wallReloadActive() then return end" in server_guard_tick
                and "pause only this" in server_guard_tick
                and "non-transactional cleanup until every member is back"
                in server_guard_tick,
                "server room-ownership guard still scans remote cells during roof relocation",
            )

        client_room_clear = section(
            client_room_ownership,
            r"local function inspectRoomOwnershipSquare",
            r"local function beginRoomOwnershipRefresh",
        )
        checks.true(client_room_clear is not None, "client stale-room correction is missing")
        if client_room_clear is not None:
            checks.true(
                "local roomOk, room = pcall" in client_room_clear
                and "return square:getRoom()" in client_room_clear
                and "local roomDefOk, roomDef = pcall" in client_room_clear
                and "return square:getRoomDef()" in client_room_clear
                and "if roomDef ~= nil then return true, 0 end" in client_room_clear,
                "client stale-room correction does not require room!=nil and RoomDef=nil",
            )
            checks.true(
                client_room_clear.count("square:setRoomID(-1)") == 1
                and client_room_clear.find("if roomDef ~= nil then return true, 0 end")
                < client_room_clear.find("square:setRoomID(-1)"),
                "client stale-room correction is absent, duplicated, or outside the RoomDef=nil branch",
            )
            checks.true(
                "setRoom(nil)" not in client_room_clear
                and "ResetIsoWorldRegion" not in client_room_clear
                and "RecalcAllWithNeighbours" not in client_room_clear,
                "client stale-room correction mutates valid engine room/region state",
            )
            checks.true(
                "eachStructureSquare(cell, guard.oldBounds, inspect)"
                in client_room_clear
                and "eachStructureSquare(cell, guard.newBounds, inspect)"
                in client_room_clear,
                "client stale-room correction does not cover complete old and new footprints",
            )
            client_room_refresh = section(
                client_room_ownership,
                r"local function refreshInvalidRoomOwnership",
                r"local function refreshCurrentPlayerRoomOwnership",
            )
            checks.true(
                client_room_refresh is not None
                and "inspectRoomOwnershipSquare(square)" in client_room_refresh,
                "client complete room scan bypasses the safe room ownership inspector",
            )

        client_room_event = section(
            client_room_ownership,
            r"local function requestRoomOwnershipScan",
            r"local function beginRoomOwnershipRefresh",
        )
        checks.true(
            client_room_event is not None
            and "if x == nil then return end" in client_room_event
            and "x == nil or coordinatesInBounds" not in client_room_event,
            "client room mutation events wake every guard when object coordinates are unavailable",
        )

        client_structure_scan = section(
            client_room_ownership,
            r"local function eachStructureSquare",
            r"local function refreshInvalidRoomOwnership",
        )
        checks.true(
            client_structure_scan is not None,
            "client complete old structure-footprint scanner is missing",
        )
        if client_structure_scan is not None:
            checks.true(
                "Layout.eachStructureCoordinate(bounds" in client_structure_scan
                and "cell:getGridSquare(x, y, z)" in client_structure_scan
                and all(
                    field not in client_structure_scan
                    for field in ("roomMinX", "roomMaxX", "roomMinY", "roomMaxY")
                )
                and "local seen" not in client_structure_scan
                and "for x =" not in client_structure_scan,
                "client stale-room scan does not use the shared traversal and client square API",
            )

        client_room_begin = section(
            client_room_ownership,
            r"local function beginRoomOwnershipRefresh",
            r"local function updateRoomOwnershipGuards",
        )
        checks.true(client_room_begin is not None, "client room-guard registration is missing")
        if client_room_begin is not None:
            checks.true(
                "localPlayerByOnlineId" not in client_room_begin
                and "roomOwnershipGuardKey" in client_room_begin
                and "roomOwnershipGuards[key]" in client_room_begin,
                "client room guard is requester-only or not keyed by full RV identity",
            )
            checks.true(
                "local rvId = args.rvId" in client_room_begin
                and "local generation = finiteInteger(args.generation)" in client_room_begin
                and "rvId = tostring(rvId)" in client_room_begin
                and "generation = generation," in client_room_begin,
                "client room guard does not retain the full RV boundary identity",
            )
            checks.true(
                "for existingKey, existingGuard in pairs(roomOwnershipGuards)" in client_room_begin
                and "roomOwnershipGuards[existingKey] = nil" in client_room_begin,
                "client room monitor retains stale geometry after a same-RV generation swap",
            )

        final_client_room = section(
            client_relocation_source,
            r"local function tryApplyFinalRelocation",
            r"local function applyFinalRelocation",
        )
        checks.true(
            final_client_room is not None
            and "local token = args.token" in final_client_room
            and "local onlineId = finiteInteger(args.onlineId)" in final_client_room
            and 'if type(token) ~= "string" or token == "" or onlineId == nil'
            in final_client_room,
            "final relocation does not reject stale RV generation/bitmap identity",
        )

        client_room_tick = section(
            client_room_ownership,
            r"local function updateRoomOwnershipGuards",
            r"ctx\.updateRoomOwnershipGuards\s*=",
        )
        checks.true(client_room_tick is not None, "client room-guard tick processor is missing")
        if client_room_tick is not None:
            checks.true(
                "guard.currentCheckErrorLatched" in client_room_tick
                and "guard.currentCheckErrorLatched = true" in client_room_tick
                and "guard.currentCheckErrorLatched = false" in client_room_tick,
                "client room monitor does not track its readiness age",
            )
            checks.true(
                "ROOM_OWNERSHIP_MAX_TICKS" not in client_room_ownership
                and "roomOwnershipGuards[finished[i]] = nil" not in client_room_tick
                and "roomOwnershipGuards[" not in client_room_tick
                and "for generation, guard in pairs(roomOwnershipGuards) do"
                in client_room_tick,
                "client room monitor still retires after the initial generation tail",
            )
            checks.true(
                re.search(r"local clientTick\s*=\s*0", client) is not None
                and "ctx.clientTick = ctx.clientTick + 1" in client_relocation_source
                and "refreshCurrentPlayerRoomOwnership(guard)" in client_room_tick
                and "guard.nextScanTick" in client_room_tick,
                "client room monitor lacks an owned tick counter or mutation-safe immediate scan",
            )
            checks.true(
                "if not currentScanOk then" in client_room_tick
                and "scheduleRoomOwnershipScan(guard)" in client_room_tick
                and "if currentScanOk and currentCleared > 0 then" in client_room_tick
                and "guard.nextScanTick = nil" in client_room_tick,
                "client room monitor drops failed full-scan retries",
            )

        utility_mapping_sync = section(
            utility_server,
            r"local function syncUtilityMappings",
            r"function M\.onTick",
        )
        checks.true(
            utility_mapping_sync is not None,
            "utility mapping sync helper is missing",
        )
        if utility_mapping_sync is not None:
            checks.true(
                re.search(
                    r"if syncOk and accepted == true and type\(identity\) == \"table\" then\s+"
                    r"mappingSyncState\[recipientKey\]",
                    utility_mapping_sync,
                ) is not None,
                "utility mapping sync caches a business failure or send failure",
            )

        server_room_event = section(
            room_ownership,
            r"local function requestRoomOwnershipScan",
            r"local function requestRoomOwnershipRemovalScan",
        )
        checks.true(
            server_room_event is not None
            and "if x == nil then" in server_room_event
            and server_room_event.find("if x == nil then")
                < server_room_event.find("for _, guard in pairs(roomOwnershipGuards) do")
            and "x == nil or" not in server_room_event,
            "server room mutation events wake every guard when object coordinates are unavailable",
        )

        checks.true(
            "GameServer.sendTeleport(" not in server,
            "server Lua calls GameServer.sendTeleport even though B42.20 does not expose it",
        )
        shared_number = section(
            constants,
            r"function C\.finiteNumber\(value\)",
            r"function C\.finiteInteger",
        )
        shared_integer = section(
            constants,
            r"function C\.finiteInteger\(value\)",
            r"C\.MOD_ID",
        )
        checks.true(
            shared_number is not None
            and 'valueType == "number"' in shared_number
            and 'valueType == "string"' in shared_number
            and "return value + 0" in shared_number
            and "pcall" in shared_number
            and "number ~= number" in shared_number
            and "math.huge" in shared_number
            and shared_integer is not None
            and "C.finiteNumber(value)" in shared_integer
            and "math.floor(number) ~= number" in shared_integer
            and "local finiteNumber = C.finiteNumber" in client_room_ownership
            and "local finiteInteger = C.finiteInteger" in client_room_ownership
            and "local finiteNumber = C.finiteNumber" in railroader_client
            and "local finiteInteger = C.finiteInteger" in railroader_client,
            "client adapters do not share Java-aware finite and integer conversion with NaN/infinity rejection",
        )
        client_relocation = section(
            client_relocation_source,
            r"function Client\.onServerCommand",
            r"function Client\.onTick",
        )
        checks.true(client_relocation is not None, "client relocation command handler is missing")
        if client_relocation is not None:
            teleport_pos = client_relocation.find("playerObj:teleportTo")
            checks.true(
                teleport_pos >= 0
                and client_relocation.find("pendingRelocation = {") > teleport_pos,
                "client does not queue a delayed acknowledgement after teleportTo",
            )
            checks.true(
                "playerObj:getCurrentSquare()" not in client_relocation,
                "client incorrectly assumes teleportTo refreshes current square immediately",
            )
            checks.true(
                re.search(
                    r"(?m)^\s*(?:local\s+\w+\s*=\s*)?\w+:getGridSquare\s*\(",
                    client_relocation,
                )
                is None,
                "client rejects remote relocation before the target chunk can stream",
            )
            checks.true(
                "localPlayerByOnlineId(onlineId)" in client_relocation,
                "targeted relocation is not restricted to the matching local player",
            )

        final_client_relocation = section(
            client_relocation_source,
            r"local function tryApplyFinalRelocation",
            r"function Client\.onServerCommand",
        )
        checks.true(
            final_client_relocation is not None,
            "client final relocation command helper is missing",
        )
        if final_client_relocation is not None:
            checks.true(
                "playerObj:teleportTo(x, y, z)" in final_client_relocation
                and "sendFinalRelocationAck" in final_client_relocation,
                "client final relocation does not apply the server-selected center",
            )
            cleanup_pos = final_client_relocation.find("destinationSquareIsLoaded(x, y, z)")
            teleport_pos = final_client_relocation.find("playerObj:teleportTo")
            checks.true(
                cleanup_pos >= 0
                and teleport_pos > cleanup_pos
                and "pending.teleported" in final_client_relocation
                and "pendingFinalRelocation" in final_client_relocation,
                "client final relocation does not complete its guarded full scan before teleport",
            )
            checks.true(
                "COMMAND_FINAL_RELOCATE_ACK" in final_client_relocation
                and "sendClientCommand" in final_client_relocation
                and "pendingRelocation = {" not in final_client_relocation,
                "client final relocation does not use its separate strict ACK flow",
            )
        server_command_handler = section(
            client_relocation_source,
            r"function Client\.onServerCommand",
            r"function Client\.onTick",
        )
        checks.true(
            server_command_handler is not None
            and "COMMAND_FINAL_RELOCATE" in (server_command_handler or "")
            and "applyFinalRelocation(args)" in (server_command_handler or ""),
            "client server-command handler does not route FinalRelocate separately",
        )

        client_tick = section(
            client_relocation_source,
            r"function Client\.onTick\(\)",
            r"Events\.OnServerCommand\.Add",
        )
        checks.true(client_tick is not None, "client delayed relocation OnTick is missing")
        if client_tick is not None:
            checks.true(
                "updateRoomOwnershipGuards()" in client_tick,
                "client OnTick does not run the stale-room guard lifecycle",
            )
            current_pos = client_tick.find("playerObj:getCurrentSquare()")
            ack_pos = client_tick.find("COMMAND_RELOCATE_ACK")
            checks.true(
                current_pos >= 0 and ack_pos > current_pos,
                "client acknowledges before its current square reaches the safe destination",
            )
            ack_payload = re.search(
                r"sendClientCommand\([\s\S]*?COMMAND_RELOCATE_ACK,\s*"
                r"\{\s*token\s*=\s*pending\.token\s*\}\)",
                client_tick,
            )
            checks.true(
                ack_payload is not None,
                "relocation acknowledgement must carry only the opaque token",
            )
            checks.true(
                "RELOCATION_TIMEOUT_TICKS" in client_tick
                and "pendingRelocation = nil" in client_tick,
                "client relocation wait has no timeout/cleanup",
            )

        preflight = section(
            server_schema,
            r"local function preflightLoaded\(cell, bounds(?:, allowIncomplete)?\)",
            r"local function targetAreaLoadStatus",
        )
        checks.true(preflight is not None, "preflightLoaded function is missing")
        if preflight is not None:
            checks.true(
                "validateTargetCoordinates(bounds" in server_schema
                and "ServerSchema.validateTargetCoordinates(bounds, anchorPosition)"
                in generation_flow,
                "preflight does not reuse legal world-coordinate validation",
            )
            checks.true(
                'requiredLoaded(x, y, bounds.roofZ, "roof")' not in preflight,
                "preflight still requires every roof square to exist",
            )
            checks.true(
                "required base square is not loaded at" in preflight
                and 'requiredLoaded(x, y, bounds.roofZ, "roof")' not in preflight,
                "preflight does not allow missing roof squares for the build phase",
            )

        roof_helper = section(
            world_objects,
            r"local function ensureRoofSquare\(cell, x, y, z\)",
            r"local function createFloor",
        )
        checks.true(roof_helper is not None, "ensureRoofSquare helper is missing")
        if roof_helper is not None:
            checks.true(
                '"createNewGridSquare", x, y, z, true' in roof_helper,
                "roof helper does not use the official IsoGridSquare constructor",
            )
            checks.true(
                "local connected = ServerWorld.getSquare(cell, x, y, z)" in roof_helper
                and "roof square construction was not observable" in roof_helper,
                "roof helper does not connect constructor-created squares",
            )
            checks.true(
                "createNewGridSquare" in roof_helper,
                "roof helper has no documented alternate square-creation API path",
            )
            checks.true(
                roof_helper.count("getSquare(cell, x, y, z)") >= 2,
                "roof helper does not verify the connected square by reading it back",
            )

        roof_phase = section(
            generation_build,
            r'setGenerationPhase\(generation, "CAPTURED_TEMPLATE"\)',
            r'setGenerationPhase\(generation, "STRUCTURE_RECALC"\)',
        )
        checks.true(roof_phase is not None, "CAPTURED_TEMPLATE phase is missing")
        if roof_phase is not None:
            checks.true(
                "ensureRoofSquare(cell, entry.x, entry.y, entry.z)" in roof_phase,
                "captured roof objects do not create or reuse their upper squares",
            )
            checks.true(
                roof_phase.find("ensureRoofSquare(cell, entry.x")
                < roof_phase.find("createCapturedTemplateObject(cell, square, entry"),
                "captured template objects are added before their square exists",
            )

        captured_factory = section(
            world_objects,
            r"local function createCapturedTemplateObject",
            r"-- Error objects are not required",
        )
        checks.true(
            captured_factory is not None
            and all(
                f'entry.class == "{class_name}"' in captured_factory
                for class_name in ("IsoObject", "IsoThumpable", "IsoWindow", "IsoLightSwitch")
            )
            and "applyCapturedIdentityAndState" in captured_factory
            and "captured object client transmission failed" in captured_factory
            and "createFurniture(" not in generation_build
            and "createLight(" not in generation_build,
            "generation does not construct captured classes from their current template entries",
        )
        checks.true(
            "function Menu.hasUtilityDashboardCandidate(player, insideOnly, locomotiveIdHint)" in railroader_client
            and "local mapping = Menu.getUtilityMapping()" in railroader_client
            and "local showDashboard = Menu.hasUtilityDashboardCandidate(player, false, locoId)" in railroader_client
            and "if mapContainsPlayer(player) then return true end" in railroader_client
            and "if insideOnly then return false end" in railroader_client
            and "local id = locomotiveIdHint" in railroader_client
            and "local locomotive = nearestLocomotive()" in railroader_client
            and "tostring(id) == mapping.locoId" in railroader_client
            and "context:addOption(enterLabel, player, requestEnter, locoId)" in railroader_client
            and "option.iconTexture = getTexture(ICON_ENTER_RV)" in railroader_client
            and "if showDashboard and not hasDashboard then" in railroader_client
            and "option.iconTexture = getTexture(ICON_UTILITY_DASHBOARD)" in railroader_client,
            "client utility menu does not preserve its two RV entry-point intents",
        )
        checks.true(
            "local function patchRailroaderAnimalMenu()" in railroader_client
            and "local boardMenu = RR.BoardMenu" in railroader_client
            and "local originalAddForAnimal = boardMenu.addForAnimal" in railroader_client
            and "boardMenu.addForAnimal = function(playerNum, context, animal, test, ...)" in railroader_client
            and "local result = originalAddForAnimal(playerNum, context, animal, test, ...)" in railroader_client
            and "addNearbyLocomotiveOptions(playerNum, context, test, animal)" in railroader_client
            and "return result" in railroader_client
            and "Events.OnGameStart.Add(patchRailroaderAnimalMenu)" in railroader_client
            and railroader_client.count("addNearbyLocomotiveOptions(playerNum, context, test)") == 2
            and "addSlice" not in railroader_client
            and "showSeatMenu" not in railroader_client
            and "Events.OnFillWorldObjectContextMenu.Add(Menu.OnFillWorldObjectContextMenu)" in railroader_client
            and "Events.OnFillWorldObjectContextMenu.Remove" not in railroader_client,
            "RV right-click options do not wrap Railroader's animal menu while preserving its native world hook",
        )
        checks.true(
            "local function addDashboardOption(player, context)" in utility_context
            and "player, true" in utility_context
            and "Menu.openDashboard" in utility_context
            and "option.iconTexture = getTexture(ICON_UTILITY_DASHBOARD)" in utility_context,
            "interior world right-click menu does not offer mapped utility management with its icon",
        )
        checks.true(
            "local function addSafehouseClaim(playerNum, context, test)" in railroader_client
            and "not Menu.getUtilityMapping()" in railroader_client
            and "or not mapContainsPlayer(player) then return false end" in railroader_client
            and "sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_SAFEHOUSE_CLAIM, {})" in railroader_client,
            "safehouse claim is not limited to an active RV interior context with an empty client intent",
        )
        checks.true(
            "local function readRoot" in utility_store
            and "local function copyTable" in utility_store
            and "record = copyTable(persisted)" in utility_store
            and "value.records[id] = copyTable(record)" in utility_store
            and "local persisted = value.records[id]" in utility_store
            and "function M.copyRecord(record)" in utility_store
            and "return copyTable(record)" in utility_store,
            "utility store does not isolate live ModData records across commit failure",
        )
        initialize_record = section(
            utility_server,
            r"function M\.initializeRecord",
            r"return M",
        )
        checks.true(
            initialize_record is not None
            and "Power.initializeRecord(identity, context)" in initialize_record
            and "Water.ensureUsageTank" not in initialize_record
            and "local committed, reason = Store.commit" not in initialize_record,
            "utility initialization constructs or migrates a Water world object instead of using the fresh current ledger",
        )
        checks.true(
            "RAIN_BARREL" not in server
            and "RainBarrel" not in server
            and "SRainBarrelSystem" not in server
            and "rainCollector" not in server
            and "layout.barrel" not in server,
            "server still contains the retired visible rain-barrel path",
        )
        special_add = section(
            world_objects,
            r"local function addSpecialObject\(square, object\)",
            r"local function createGenerator",
        )
        checks.true(special_add is not None, "addSpecialObject helper is missing")
        if special_add is not None:
            checks.true(
                "transmitCompleteItemToClients" not in special_add,
                "addSpecialObject still sends a premature full-object packet",
            )
            checks.true(
                "recalcSquare(square)" in special_add,
                "addSpecialObject no longer recalculates after attachment",
            )
        generator = section(
            world_objects,
            r"local function createGenerator",
            r"local function createCapturedTemplateObject",
        )
        checks.true(generator is not None, "createGenerator function is missing")
        if generator is not None:
            checks.true(
                generator.count("transmitCompleteItemToClients") == 1,
                "generator does not have exactly one final full-object packet",
            )
            checks.true(
                generator.find("transmitCompleteItemToClients") > generator.find("setActivated"),
                "generator full-object packet is sent before final activation",
            )
            checks.true(
                generator.find("setActivated") >= 0
                and generator.find("tagObject") > generator.find("setActivated")
                and generator.find("addSpecialObject") > generator.find("tagObject"),
                "generator is not initialized and tagged before square attachment",
            )
            checks.true(
                all(
                    network_call not in generator
                    for network_call in (
                        "transmitModData",
                        "sendObjectChange",
                        '"sync"',
                        "transmitUpdatedSpriteToClients",
                        "transmitRemoveItemFromSquare",
                    )
                ),
                "generator emits a pre-complete object-index network packet",
            )

        checks.true(
            "createRainBarrel" not in server
            and "ensureRainBarrelGlobalObject" not in server
            and "getRainBarrelGlobalClass" not in server,
            "retired rain-barrel creator or global bridge remains in the server facade",
        )

        captured_builder = section(
            world_objects,
            r"local function createCapturedTemplateObject",
            r"-- Error objects are not required",
        )
        checks.true(
            captured_builder is not None
            and "IsoThumpable" in captured_builder
            and "IsoWindow" in captured_builder
            and "captured object client transmission failed" in captured_builder,
            "captured-template builder does not transmit the current captured object classes",
        )

        captured_template_phase = section(
            generation_build,
            r'setGenerationPhase\(generation, "CAPTURED_TEMPLATE"\)',
            r'setGenerationPhase\(generation, "STRUCTURE_RECALC"\)',
        )
        checks.true(
            captured_template_phase is not None
            and "for i = 1, #templateObjects do" in captured_template_phase
            and "local entry = templateObjects[i]" in captured_template_phase
            and "createCapturedTemplateObject(cell, square, entry" in captured_template_phase
            and "shellByTemplateIndex[i]" in captured_template_phase
            and re.search(
                r'setGenerationPhase\(generation,\s*"COUNTER_SINK"',
                generation_build,
            ) is None,
            "generation does not apply the current captured template entry by entry",
        )

        template_geometry = read_utf8(
            shared_root / "RoomTemplate" / "RV_TemplateGeometry.lua"
        )
        cab_region = section(
            template_geometry,
            r"function G\.isBuildable\(world, anchor, template\)",
            r"function G\.isBuildCellSideHost",
        )
        cab_editable = section(
            template_geometry,
            r"function G\.isBuildCellSideHost\(world, anchor, template\)",
            r"function G\.inManagedRegion",
        )
        cab_side_host = section(
            template_protection_repair,
            r"local function isCabSideDoorOrWindow",
            r"local function objectMatchesCaptured",
        )
        template_protection_repair_index = section(
            template_protection_repair,
            r"local function isProtectedCell\(boundary, x, y\)",
            r"local function objectTag",
        )
        player_build_policy = section(
            boundary_objects,
            r"local function markTagPlayerBuilt",
            r"local function commandArgument",
        )
        checks.true(
            all(
                cell in captured_shell_cells
                for cell in ((-4, -2), (-4, -1), (-4, 2), (2, -2))
            )
            and cab_region is not None
            and "for index, cell in ipairs(template.misc.buildCells) do"
            in cab_region
            and "if cell.x == tile.x and cell.y == tile.y and cellZ == tile.z then"
            in cab_region
            and "return true, index" in cab_region
            and cab_editable is not None
            and "if z == cellZ and ((x == cell.x + 1 and y == cell.y)" in cab_editable
            and "or (x == cell.x and y == cell.y + 1)) then" in cab_editable
            and "return true, index" in cab_editable
            and cab_side_host is not None
            and "if not isRuntimeDoorOrWindow(object) then return false end"
            in cab_side_host
            and "return TemplateGeometry.isBuildCellSideHost({" in cab_side_host
            and "}, anchor, template)" in cab_side_host
            and template_protection_repair_index is not None
            and "templateProxyAtOffset(cellX, cellY, cellZ, template)" in template_protection_repair_index
            and "entriesByCell[templateCellKey(cellX, cellY)]"
            in template_protection_repair_index
            and "captured.z == cellZ and captured.protected"
            in template_protection_repair_index
            and player_build_policy is not None
            and "local tag = rvTag(object)" in player_build_policy
            and "integer(tag.generation) ~= integer(action.generation)"
            in player_build_policy
            and "if tag and tag.playerBuilt ~= true then" in player_build_policy
            and "owner = OWNER," in player_build_policy
            and "playerBuilt = true," in player_build_policy
            and "rvId = action.rvId," in player_build_policy
            and "generation = action.generation," in player_build_policy,
            "static repair classes, cab edits, and queued dynamic-object cleanup do not follow the current policy",
        )
        repair_candidate = section(
            template_protection_repair,
            r"local function isSpareObject\(object, entries, sideHostDoorOrWindow\)",
            r"local function isBloodOrSplat",
        )
        checks.true(
            repair_candidate is not None
            and "isUtilityProxyObject(object) or sideHostDoorOrWindow" in repair_candidate
            and "local templateIndex = objectTemplateIndex(object)" in repair_candidate
            and "if not templateIndex then return true end" in repair_candidate
            and "entry.protected and entry.templateIndex == templateIndex" in repair_candidate
            and "objectMatchesTemplate(object, entry)" in repair_candidate
            and "objectHasShellIdentity(object, entry.edge)" in repair_candidate,
            "template repair candidate is not tied to the current protected template identity and live class/position",
        )

        def repair_candidate_identity_matches(boundary, index, expected, tag,
            position, player_object=False):
            if player_object or not all(isinstance(value, dict) for value in (
                boundary, index, expected, tag, position
            )):
                return False
            identity = ("rvId", "generation", "bitmapVersion")
            if any(boundary.get(key) != index.get(key)
                or boundary.get(key) != tag.get(key) for key in identity):
                return False
            if tag.get("templateIndex") != expected.get("templateIndex"):
                return False
            if any(expected.get(key) != position.get(key)
                for key in ("x", "y", "z")):
                return False
            if any(tag.get("template" + key.upper()) != expected.get(key)
                for key in ("x", "y", "z")):
                return False
            return tag.get("templateClass") == expected.get("class")

        current_boundary = {
            "rvId": "rv-current", "generation": 8, "bitmapVersion": 6,
        }
        current_index = dict(current_boundary)
        current_expected = {
            "templateIndex": 24, "x": 20004, "y": 2048, "z": 1,
            "class": "IsoThumpable",
        }
        current_tag = {
            **current_boundary, "templateIndex": 24,
            "templateX": 20004, "templateY": 2048, "templateZ": 1,
            "templateClass": "IsoThumpable",
        }
        current_position = {"x": 20004, "y": 2048, "z": 1}
        checks.true(
            repair_candidate_identity_matches(
                current_boundary, current_index, current_expected,
                current_tag, current_position
            )
            and not repair_candidate_identity_matches(
                current_boundary, current_index, current_expected,
                {**current_tag, "role": "player-build", "templateIndex": None},
                current_position, player_object=True
            )
            and not repair_candidate_identity_matches(
                current_boundary, current_index, current_expected,
                {**current_tag, "generation": 7}, current_position
            )
            and not repair_candidate_identity_matches(
                current_boundary, current_index, current_expected,
                {**current_tag, "rvId": "rv-other-slot"}, current_position
            ),
            "repair authorization accepts a player object, old generation, or another RV slot",
        )

        captured_identity = section(
            template_protection_repair,
            r"local function objectMatchesCaptured\(object, expected\)",
            r"local function objectMatchesStoredState",
        )
        checks.true(
            captured_identity is not None
            and "ServerUtil.classInstance(object, expected.class)" in captured_identity
            and 'ServerUtil.invoke(object, "getName")' in captured_identity
            and 'ServerUtil.invoke(object, "getDir")' in captured_identity
            and "expected.sprite" in captured_identity
            and "expected.north" in captured_identity
            and repair_candidate is not None
            and "objectMatchesTemplate(object, entry)" in repair_candidate,
            "repair candidates are not classified by the current template's exact engine class and live object identity",
        )

        floor_helper = section(
            world_objects,
            r"local function createFloor",
            r"local function addSpecialObject",
        )
        checks.true(floor_helper is not None, "createFloor helper is missing")
        if floor_helper is not None:
            checks.true(
                "previousSprite" in floor_helper and "createdByGeneration" in floor_helper,
                "floor helper does not persist its pre-generation snapshot",
            )
            checks.true(
                'transmitUpdatedSpriteToClients' in floor_helper,
                "floor replacement does not use the B42 sprite-update packet",
            )
            checks.true(
                'transmitModData' in floor_helper,
                "existing floor replacement does not send its generation/modData delta",
            )
            checks.true(
                floor_helper.count("transmitCompleteItemToClients") == 1,
                "new floor path does not have exactly one complete packet",
            )
            updated_position = floor_helper.find("transmitUpdatedSpriteToClients")
            mod_data_position = floor_helper.find("transmitModData")
            complete_position = floor_helper.find("transmitCompleteItemToClients")
            checks.true(
                updated_position >= 0
                and mod_data_position > updated_position
                and complete_position > mod_data_position,
                "floor sprite/modData incremental updates and new-floor complete packet are misordered",
            )
            checks.true(
                "new floor client transmission failed" in floor_helper
                and "existing floor sprite transmission failed" in floor_helper
                and "existing floor modData transmission failed" in floor_helper,
                "floor client transmission failures are not hard errors",
            )
        rollback_remove = section(
            server_world,
            r"local function removeGenericObject",
            r"local function removeObject",
        )
        checks.true(rollback_remove is not None, "removeGenericObject helper is missing")
        if rollback_remove is not None:
            checks.true(
                "restoreTaggedFloor" in rollback_remove,
                "rollback does not attempt to restore an existing floor",
            )
            checks.true(
                'transmitRemoveItemFromSquare' in rollback_remove
                and 'removeFromSquare' not in rollback_remove
                and 'removeFromWorld' not in rollback_remove,
                "rollback duplicates the B42 removal path with manual detachment",
            )
            checks.true(
                "squareContainsObject" in rollback_remove,
                "rollback removal has no authoritative postcondition",
            )
            checks.true(
                "server object removal failed" in rollback_remove
                and 'invoke(object, "getObjectName")' in rollback_remove
                and 'invoke(object, "getObjectIndex")' in rollback_remove
                and 'invoke(object, "getSquare")' in rollback_remove
                and 'invoke(square, "getX")' in rollback_remove
                and "safeMultiSquare=" in rollback_remove
                and "callOk=" in rollback_remove
                and "stillPresent=" in rollback_remove,
                "object removal failures do not preserve object and square context",
            )
            checks.true(
                'invoke(square, "setFloor"' not in rollback_remove,
                "rollback still calls the nonexistent IsoGridSquare:setFloor API",
            )
        special_remove = section(
            server_world,
            r"local function deregisterSpecialSystems",
            r"local function removeCorpse",
        )
        checks.true(special_remove is not None, "special-system removal helper is missing")
        if special_remove is not None:
            checks.true(
                "return object" in special_remove
                and "unregisterRainBarrelGlobalObject" not in special_remove
                and "SRainBarrelSystem" not in special_remove
                and 'callGlobal("triggerEvent"' not in special_remove
                and "local systems =" not in special_remove,
                "utility cleanup still assumes a global rain-barrel system",
            )
        rollback = section(
            generation_build,
            r"local function clearGenerationArea\(cell, bounds, generation\)",
            r"local function buildGeneration",
        )
        checks.true(rollback is not None, "removeGeneration function is missing")
        if rollback is not None:
            checks.true(
                "including remnants from any failed earlier" in rollback
                and "A new unmapped generation starts with this complete clear pass"
                in rollback,
                "generation cleanup does not clear the remnants of a failed earlier attempt",
            )
            checks.true(
                "ServerSchema.walkBounds(cell, bounds, function(square)" in rollback
                and "ServerWorld.clearSquare(square, nil)" in rollback
                and "M.clearSquare = clearSquare" in server_world
                and "if not square and requireLoaded == true then" in server_schema
                and re.search(
                    r"if square then\s+fn\(square, x, y, z\)\s+end",
                    server_schema,
                ) is not None,
                "generation cleanup does not use sparse managed bounds with per-square clearing",
            )

        checks.true(
            re.search(
                r"sendClientCommand\([^\n]*\{\s*\}\s*\)", client_relocation_source
            )
            is not None,
            "client request no longer uses an empty payload",
        )

    if start_bat_path.is_file():
        start_bat = read_utf8(start_bat_path)
        checks.true(
            re.search(r"(?im)^@?chcp\s+65001\s+>nul", start_bat) is not None,
            "server launcher batch does not set the UTF-8 console code page",
        )
        checks.true(
            "-Dfile.encoding=UTF-8" in start_bat,
            "server launcher batch does not specify Java UTF-8 file encoding",
        )
        checks.true(
            "%*" in start_bat,
            "server launcher batch does not forward all arguments",
        )
        checks.true(
            "exit /b %EXIT_CODE%" in start_bat,
            "server launcher batch does not return the Java exit code",
        )

    if testserver_agent_path.is_file():
        testserver_agent = read_utf8(testserver_agent_path)
        checks.true(
            "saves, player database and admin permissions" in testserver_agent,
            "testserver docs do not identify the persistent server data reused between runs",
        )
        checks.true(
            "does not automatically reset that data" in testserver_agent,
            "testserver docs do not prohibit automatic server data reset",
        )
        checks.true(
            "UTF-8" in testserver_agent,
            "testserver docs do not record the UTF-8 startup constraint",
        )
        checks.true(
            "Z:\\RailroaderRVCache\\client" in testserver_agent
            and "Z:\\RailroaderRVCache\\server" in testserver_agent,
            "testserver docs do not identify the persistent server/client caches",
        )

    checks.true(mod_info_path.is_file(), f"mod.info is missing: {mod_info_path}")
    if mod_info_path.is_file():
        mod_info = read_utf8(mod_info_path)
        checks.true(
            re.search(r"(?m)^require=\\BuildingCraft,\\Railroader\s*$", mod_info)
            is not None
            and len(re.findall(r"(?m)^require=", mod_info)) == 1,
            "RailroaderRV mod.info must preserve BuildingCraft and require Railroader",
        )

    if readme_path.is_file():
        readme = read_utf8(readme_path)
        checks.true(
            "BuildingCraft_Light_17" in readme
            and "自建房电灯开关1" in readme
            and "3459887404" in readme,
            "README does not identify the required BuildCraft custom-house switch dependency",
        )
        checks.true(
            "x=[20000,20100)" in readme
            and "y=[2000,2100)" in readme
            and "staging" in readme
            and "加载等待期间不做任何世界修改" in readme
            and "等待目标" in readme
            and "不要求预先加载完整" in readme
            and "缺失 square 会跳过" in readme
            and "固定模板对象的宿主 square" in readme
            and "fail closed" in readme
            and "10000 个 base 方格" not in readme,
            "README does not document sparse cleanup, template-host construction, and fail-closed preflight",
        )
        checks.true(
            "不铺整片金属地板" in readme
            and "FinalRelocate" in readme
            and "(20050.5,2050.5,0)" in readme,
            "README does not document the no-metal-floor build and final relocation",
        )
        checks.true(
            "412 个模板对象" in readme
            and "6×23" in readme
            and "驾驶室内部 x=-4..1、y=-2..1" in readme
            and "每 10 tick" in readme
            and "59 条捕获墙边" in readme
            and "四段隐形墙补齐活动区域边界缺口" in readme,
            "README does not document the captured 6x23 RV and 59-edge shell",
        )
        checks.true(
            "位于旧、新边界之外的安全格" not in readme,
            "README still documents the retired safe-square relocation plan",
        )
        checks.true(
            "lighting_indoor_01_16" not in readme
            and "Facing=E" not in readme,
            "README still documents the retired vanilla lamp or Facing=E assumption",
        )
        checks.true(
            "服务端捕获当前在场成员" in readme
            and "协调临时远移、chunk 周期及逐人返回" in readme
            and "客户端异步" in readme
            and "token ACK 推进阶段" in readme,
            "README does not document the grouped remote chunk-cycle roof refresh",
        )
        checks.true(
            "managedOriginX+floor(width/2)" in readme
            and "managedOriginY+floor(height/2)" in readme
            and "正在生成房车" in readme
            and "进程内存" in readme
            and "-15" in readme
            and "无状态" in readme
            and "不恢复原坐标" in readme,
            "README does not document generation-center staging and the stateless -15 sentinel",
        )

    active_commands = read_utf8(server_commands_path) if server_commands_path.is_file() else ""
    generation_validation = section(
        generation_flow,
        r"local function validateRequest\(module, command, player\)",
        r"-- Deliver the final in-house relocation",
    )
    checks.true(
        not layout_builder_path.exists()
        and not layout_builder_client_path.exists()
        and "COMMAND_LAYOUT_BUILD" not in active_commands
        and "COMMAND_LAYOUT_FINISH" not in active_commands
        and "LayoutBuilder" not in active_commands
        and "RemovalTrace" not in active_commands
        and "queueGeneration(player, reason)" in active_commands
        and generation_validation is not None
        and "command ~= COMMAND" in generation_validation,
        "LayoutBuilder is not retired while the authoritative Generate route remains active",
    )

    if server_agent_path.is_file():
        server_agent = read_utf8(server_agent_path)
        checks.true(
            "Generation waits at staging until every base square in the managed clear bounds is visible"
            in server_agent
            and "cleanup starts only after this full-scope check passes" in server_agent
            and "Cleanup walks the managed bounds and clears objects in its scope" in server_agent
            and "creates objects only at current template-object hosts" in server_agent
            and "materializing sparse upper host squares on demand" in server_agent
            and "it does not create empty base-plane squares" in server_agent,
            "server agent docs do not describe sparse cleanup and fail-closed template-host construction",
        )
        checks.true(
            "PerfTrace" not in server_agent
            and "PerfTrace" not in read_utf8(client_root / "agent.md"),
            "agent docs still describe removed performance diagnostics",
        )

    checks.true(runner_path.is_file(), f"one-click test runner is missing: {runner_path}")
    if runner_path.is_file():
        runner = read_utf8(runner_path)
        checks.true(
            'runtime_root = run_bat.parent / "runtime"' in runner
            and "_acquire_instance_lock(runtime_root, settings.run_bat)" in runner,
            "one-click test runner does not isolate lock/instance state under testserver/runtime",
        )
        checks.true(
            'RAMDISK_CACHE_ROOT = Path(r"Z:\\RailroaderRVCache")' in runner
            and 'server_cache = server_cache or (RAMDISK_CACHE_ROOT / "server")' in runner
            and 'client_cache = client_cache or (RAMDISK_CACHE_ROOT / "client")' in runner,
            "one-click test runner does not use the documented persistent Z: cache defaults",
        )
        checks.true(
            "_copy_mod_tree" in runner,
            "one-click test runner does not use overlay mod synchronization",
        )
        checks.true(
            'BUILDCRAFT_MOD_ID = "BuildingCraft"' in runner
            and 'BUILDCRAFT_WORKSHOP_ID = "3459887404"' in runner,
            "one-click test runner does not pin the BuildCraft mod/workshop identifiers",
        )
        checks.true(
            "find_steam_libraries" in runner
            and "workshop" in runner
            and "--buildcraft-source" in runner,
            "one-click test runner lacks Steam discovery or --buildcraft-source override",
        )
        checks.true(
            '"common" / "mod.info"' in runner
            and '"42.0" / "mod.info"' in runner,
            "one-click test runner does not validate BuildCraft common/42.0 metadata",
        )
        checks.true(
            re.search(
                r"stage_mod\(\s*buildcraft_source,\s*settings\.server_cache[\s\S]*?BUILDCRAFT_MOD_ID",
                runner,
            )
            is not None
            and re.search(
                r"stage_mod\(\s*buildcraft_source,\s*settings\.client_cache[\s\S]*?BUILDCRAFT_MOD_ID",
                runner,
            )
            is not None,
            "BuildCraft is not overlaid to both server/client mods/BuildingCraft caches",
        )
        checks.true(
            '"Mods": f"{BUILDCRAFT_MOD_ID};{MOD_ID}"' in runner
            and '"WorkshopItems": ""' in runner,
            "server options do not enforce BuildCraft-first Mods and offline WorkshopItems",
        )
        checks.true(
            re.search(r"(?im)\b(?:rmtree|Remove-Item|shutil\.rmtree)\b", runner)
            is None,
            "one-click test runner contains an automatic runtime data delete/reset operation",
        )

    run_lua_syntax_checks(root, checks)

    if checks.failures:
        for failure in checks.failures:
            print(f"[FAIL] {failure}", file=sys.stderr)
        return 1

    print(
        "RV static tests passed: payload contract, UTF-8 launcher contract, "
        "relocation handshake, stale-room guard, entity/fluid component contract, rollback contract, "
        "Railroader SP/MP adapter, hull-distance/seat transition contracts, transaction/sentinel documentation, "
        "Lua syntax."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
