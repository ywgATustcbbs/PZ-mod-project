from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MEDIA_LUA = ROOT / "contents/mods/RailroaderRV/42/media/lua"


class TemplateProtectionRecoveryTests(unittest.TestCase):
    def test_queue_preserves_east_garage_and_cleans_car_box_inactive_cells(self) -> None:
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().mediaLuaRoot = MEDIA_LUA.as_posix()
        lua.execute(
            "package.path = mediaLuaRoot .. '/server/?.lua;' "
            ".. mediaLuaRoot .. '/shared/?.lua;' .. package.path"
        )
        lua.execute(
            r'''
            local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"
            local Geometry = require "RailroaderRV/RoomTemplate/RV_TemplateGeometry"
            local ProductionServerWorld = require "RailroaderRV/Common/RV_ServerWorld"
            local repairFactory = require(
                "RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair")
            local recoveryFactory = require(
                "RailroaderRV/TemplateRecovery/RV_TemplateRecovery")

            RailroaderRV = { Server = {} }
            IsoDirections = { N = "N" }
            instanceof = function(object, className)
                return object ~= nil and object.class == className
            end

            local anchor = { x = 2050, y = 2050, z = 0 }
            local function makeBoundary(templateId, rvId, templateAnchor)
                local template = RoomTemplate.get(templateId)
                local managedMinZOffset = math.huge
                for index = 1, #template.objects do
                    managedMinZOffset = math.min(managedMinZOffset,
                        template.objects[index].z)
                end
                for index = 1, #template.misc.walkAabbs do
                    managedMinZOffset = math.min(managedMinZOffset,
                        template.misc.walkAabbs[index].minZ)
                end
                for index = 1, #template.misc.buildCells do
                    local buildCell = template.misc.buildCells[index]
                    managedMinZOffset = math.min(managedMinZOffset,
                        buildCell.z == nil and template.metadata.anchor.z
                            or buildCell.z)
                end
                return {
                    rvId = rvId,
                    generation = 1,
                    templateId = templateId,
                    shellEdges = {},
                    managed = {
                        originX = templateAnchor.x + template.metadata.minX,
                        originY = templateAnchor.y + template.metadata.minY,
                        width = template.metadata.width,
                        height = template.metadata.height,
                        minZ = templateAnchor.z + managedMinZOffset,
                        maxZ = templateAnchor.z + 32,
                    },
                }
            end

            local carBoxBoundary = makeBoundary(
                RoomTemplate.CAR_BOX_TEMPLATE_ID, "bx40", anchor)
            local activeBoundary = carBoxBoundary
            local squares = {}
            local repairVisits = {}
            local removalTransmissions = {}
            local removalCoordinates = {}
            local additionTransmissions = {}
            local repairCallsByRvId = {}

            local function squareKey(x, y, z)
                return tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
            end
            local function makeObject(class, name, sprite, north, properties,
                label, tag, health)
                local flags = properties or {}
                local spriteProperties = {}
                function spriteProperties:has(property)
                    return flags[property] == true
                end
                local object = {
                    class = class,
                    name = name,
                    sprite = sprite,
                    north = north,
                    label = label,
                    properties = spriteProperties,
                    health = health,
                    modData = tag and { RailroaderRV = tag } or nil,
                }
                local spriteObject = {}
                function spriteObject:getName() return object.sprite end
                function object:getName() return self.name end
                function object:getDir() return IsoDirections.N end
                function object:getNorth() return self.north end
                function object:getProperties() return self.properties end
                function object:getModData() return self.modData end
                function object:getSprite() return spriteObject end
                function object:getContainerCount() return 0 end
                function object:getContainer() return nil end
                function object:isDoor() return self.isDoorValue == true end
                function object:isWindow() return self.isWindowValue == true end
                function object:isFloor()
                    return self.properties:has("solidfloor")
                end
                return object
            end
            local function addSquare(x, y, z, objects)
                local square = { objects = objects, x = x, y = y, z = z }
                function square:getObjects()
                    local squareObjects = self.objects
                    return {
                        size = function() return #squareObjects end,
                        get = function(_, index) return squareObjects[index + 1] end,
                    }
                end
                function square:getFloor() return nil end
                function square:getX() return self.x end
                function square:getY() return self.y end
                function square:getZ() return self.z end
                function square:transmitRemoveItemFromSquare(object)
                    for index = #self.objects, 1, -1 do
                        if self.objects[index] == object then
                            table.remove(self.objects, index)
                            removalTransmissions[#removalTransmissions + 1] = object.label
                            removalCoordinates[#removalCoordinates + 1] =
                                object.label .. "@" .. self.x .. ":" .. self.y
                                .. ":" .. self.z .. "/" .. activeBoundary.templateId
                            return index - 1
                        end
                    end
                    return -1
                end
                squares[squareKey(x, y, z)] = square
                return square
            end
            local function playerBuiltTag()
                return {
                    owner = "RailroaderRV",
                    playerBuilt = true,
                    rvId = carBoxBoundary.rvId,
                    generation = carBoxBoundary.generation,
                }
            end
            local function capturedTag(entry, boundary)
                return {
                    owner = "RailroaderRV",
                    role = "captured-template",
                    templateId = boundary.templateId,
                    rvId = boundary.rvId,
                    generation = boundary.generation,
                    templateIndex = entry.templateIndex,
                }
            end
            local function capturedAt(template, x, y, sprite)
                for index = 1, #template.objects do
                    local entry = template.objects[index]
                    if entry.x == x and entry.y == y
                        and entry.z == 0 and entry.sprite == sprite then
                        return entry
                    end
                end
            end

            local carBox = RoomTemplate.get(RoomTemplate.CAR_BOX_TEMPLATE_ID)
            local originalGarageEntry = capturedAt(carBox, 3, -2,
                "walls_garage_02_2")
            assert(originalGarageEntry and not originalGarageEntry.protected)

            local originalGarage = makeObject("IsoThumpable", "Thumpable",
                originalGarageEntry.sprite, false, {}, "original-garage",
                capturedTag(originalGarageEntry, carBoxBoundary), 37)
            local illegalFloor = makeObject("IsoObject", "Floor",
                "offline-illegal-floor", nil, { solidfloor = true },
                "illegal-floor", playerBuiltTag())
            local illegalNorthWall = makeObject("IsoThumpable", "Thumpable",
                "offline-north-wall", true, { WallN = true },
                "illegal-north-wall", playerBuiltTag())
            local ordinaryFurniture = makeObject("IsoThumpable", "Thumpable",
                "offline-furniture", false, {}, "ordinary-furniture",
                playerBuiltTag())
            local mixedCorner = makeObject("IsoThumpable", "Thumpable",
                "offline-nw-corner", false,
                { WallW = true, WallNW = true }, "mixed-corner",
                playerBuiltTag())

            local bx40EastX = anchor.x + 3
            local eastGarageY = {
                [-2] = anchor.y - 2,
                [-1] = anchor.y - 1,
                [0] = anchor.y,
                [1] = anchor.y + 1,
            }
            addSquare(bx40EastX, eastGarageY[-2], 0, {
                originalGarage, illegalFloor, illegalNorthWall,
                ordinaryFurniture, mixedCorner,
            })
            -- This empty square represents the player having demolished the
            -- captured garage segment; recovery must leave it empty.
            addSquare(bx40EastX, eastGarageY[-1], 0, {})

            local westReplacement = makeObject("IsoThumpable", "Wooden Wall",
                "offline-west-wall", false, { WallW = true },
                "west-replacement", playerBuiltTag())
            local northAtReplacementCell = makeObject("IsoThumpable",
                "Wooden Wall", "offline-north-at-replacement", true,
                { WallN = true }, "north-at-replacement", playerBuiltTag())
            addSquare(bx40EastX, eastGarageY[0], 0, {
                westReplacement, northAtReplacementCell,
            })

            local westWindow = makeObject("IsoWindow", "Window",
                "offline-west-window", false, { WindowW = true },
                "west-window", playerBuiltTag())
            westWindow.isWindowValue = true
            local northWindow = makeObject("IsoWindow", "Window",
                "offline-north-window", true, { WindowN = true },
                "north-window", playerBuiltTag())
            northWindow.isWindowValue = true
            local northWindowOnWestSide = makeObject("IsoWindow", "Window",
                "offline-misoriented-west-window", true,
                { WindowW = true }, "misoriented-west-window", playerBuiltTag())
            northWindowOnWestSide.isWindowValue = true
            local northFacingFurniture = makeObject("IsoThumpable", "Thumpable",
                "offline-north-furniture", false, {}, "north-facing-furniture",
                playerBuiltTag())
            addSquare(bx40EastX, eastGarageY[1], 0, {
                westWindow, northWindow, northWindowOnWestSide,
                northFacingFurniture,
            })

            -- x=3,y=-3 borders the exception and has a protected template wall.
            local adjacentProtectedCell = { x = bx40EastX, y = anchor.y - 3 }
            local adjacentSquare = addSquare(adjacentProtectedCell.x,
                adjacentProtectedCell.y, 0, {})

            -- Empty managed cells beyond the west edge have no captured entry
            -- for the old protection filter to queue. They remain in scope for
            -- the same player-centered 3x3 recovery sample.
            local westNearCell = { x = anchor.x - 4, y = anchor.y - 9 }
            local westFarCell = { x = anchor.x - 5, y = anchor.y + 9 }
            local westNearWall = makeObject("IsoThumpable", "Wooden Wall",
                "offline-west-near-wall", false, { WallW = true },
                "west-near-wall", playerBuiltTag())
            local westFarWall = makeObject("IsoThumpable", "Wooden Wall",
                "offline-west-far-wall", false, { WallW = true },
                "west-far-wall", playerBuiltTag())
            local westFarFurniture = makeObject("IsoThumpable", "Thumpable",
                "offline-west-furniture", false, {}, "west-far-furniture",
                playerBuiltTag())
            local westNearSquare = addSquare(westNearCell.x, westNearCell.y,
                0, { westNearWall })
            local westFarSquare = addSquare(westFarCell.x, westFarCell.y,
                0, { westFarWall, westFarFurniture })

            local activeBuildCell = { x = anchor.x - 3, y = anchor.y - 5 }
            local activeBuildWall = makeObject("IsoThumpable", "Wooden Wall",
                "offline-active-build-wall", false, { WallW = true },
                "active-build-wall", playerBuiltTag())
            local activeBuildSquare = addSquare(activeBuildCell.x,
                activeBuildCell.y, 0, { activeBuildWall })

            local world = {}
            function world:getGridSquare(x, y, z)
                    if z == -32 then
                        local key = tostring(x) .. ":" .. tostring(y)
                        repairVisits[key] = (repairVisits[key] or 0) + 1
                    end
                    return squares[squareKey(x, y, z)]
            end
            local serverWorld = ProductionServerWorld
            local function classInstance(object, className)
                return object.class == className
            end
            local function invoke(object, methodName, ...)
                local method = object and object[methodName]
                if type(method) ~= "function" then return false, nil end
                return true, method(object, ...)
            end

            local ctx = {
                Constants = {
                    MOD_ID = "RailroaderRV",
                    WORLD_MIN_Z = -32,
                    WORLD_MAX_Z = 32,
                    TEMPLATE_PROTECTION_REPAIR_SAMPLE_INTERVAL_TICKS = 1,
                },
                RV = RailroaderRV,
                ServerUtil = {
                    toNumber = function(value) return tonumber(value) or value end,
                    classInstance = classInstance,
                    invoke = invoke,
                },
                ServerWorld = serverWorld,
                Boundary = {
                    boundaryForPlayer = function()
                        repairCallsByRvId[activeBoundary.rvId] =
                            (repairCallsByRvId[activeBoundary.rvId] or 0) + 1
                        return activeBoundary
                    end,
                },
                createCapturedTemplateObject = function(_, square, entry,
                    generation, tagContext, edge, mode)
                    assert(mode == "production")
                    assert(generation == activeBoundary.generation)
                    local restored = makeObject(entry.class, entry.name,
                        entry.sprite, entry.north, {}, "restored-" .. entry.templateIndex,
                        {
                            owner = "RailroaderRV",
                            role = "captured-template",
                            templateId = tagContext.templateId,
                            rvId = tagContext.rvId,
                            generation = generation,
                            templateIndex = entry.templateIndex,
                            edgeKey = edge and edge.edgeKey or nil,
                        })
                    square.objects[#square.objects + 1] = restored
                    additionTransmissions[#additionTransmissions + 1] = {
                        templateIndex = entry.templateIndex,
                        label = restored.label,
                    }
                end,
                configureCapturedDoorFrame = function() end,
            }
            local repair = repairFactory(ctx)
            local sample = false
            local recovery = recoveryFactory({
                Core = {
                    tickModulo = function()
                        if sample then sample = false; return true end
                        return false
                    end,
                },
                Constants = ctx.Constants,
                ServerUtil = ctx.ServerUtil,
            })

            local playerPosition = { x = bx40EastX, y = eastGarageY[-2] }
            local player = {
                getX = function() return playerPosition.x end,
                getY = function() return playerPosition.y end,
                getCell = function() return world end,
            }
            local function sampleAndDrain(boundary, x, y)
                activeBoundary = boundary
                playerPosition.x, playerPosition.y = x, y
                sample = true
                local activePlayers = { { player = player, boundary = boundary } }
                recovery.onPostPlayerTick(0, activePlayers, {})
                for _ = 1, 12 do
                    recovery.onPostPlayerTick(0, activePlayers, {})
                end
            end

            -- Exercise the real queue around both halves of the four-cell span.
            sampleAndDrain(carBoxBoundary, bx40EastX, eastGarageY[-2])
            sampleAndDrain(carBoxBoundary, bx40EastX, eastGarageY[0])
            local eastRemovalCount = #removalTransmissions

            local westNearRelative = { x = -4, y = -9, z = 0 }
            local westFarRelative = { x = -5, y = 9, z = 0 }
            local westTargetsAreInactive = not Geometry.isBuildable({
                    x = westNearCell.x, y = westNearCell.y, z = anchor.z },
                    anchor, carBox)
                and not Geometry.isWalkable({ x = westNearCell.x,
                    y = westNearCell.y, z = anchor.z }, anchor, carBox)
                and not RoomTemplate.cellAt(carBox, westNearRelative.x,
                    westNearRelative.y)
                and not Geometry.isBuildable({ x = westFarCell.x,
                    y = westFarCell.y, z = anchor.z }, anchor, carBox)
                and not Geometry.isWalkable({ x = westFarCell.x,
                    y = westFarCell.y, z = anchor.z }, anchor, carBox)
                and not RoomTemplate.cellAt(carBox, westFarRelative.x,
                    westFarRelative.y)
            local westCandidatesQueued = repair.isProtectedCell(
                    carBoxBoundary, westNearCell.x, westNearCell.y)
                and repair.isProtectedCell(carBoxBoundary, westFarCell.x,
                    westFarCell.y)
            sampleAndDrain(carBoxBoundary, westNearCell.x, westNearCell.y)
            sampleAndDrain(carBoxBoundary, westFarCell.x, westFarCell.y)

            -- Buildable west-edge cells remain player-editable and are not
            -- converted into inactive recovery targets.
            local activeBuildable = Geometry.isBuildable({
                x = activeBuildCell.x, y = activeBuildCell.y, z = anchor.z },
                anchor, carBox)
            local activeBuildCellQueued = repair.isProtectedCell(
                carBoxBoundary, activeBuildCell.x, activeBuildCell.y)
            sampleAndDrain(carBoxBoundary, activeBuildCell.x, activeBuildCell.y)
            local activeBuildCellVisited = repairVisits[
                tostring(activeBuildCell.x) .. ":" .. tostring(activeBuildCell.y)]

            local specialVisits = true
            for y = -2, 1 do
                if not repairVisits[tostring(bx40EastX) .. ":"
                    .. tostring(anchor.y + y)] then
                    specialVisits = false
                end
            end

            local function labelsIn(square)
                local labels = {}
                for index = 1, #square.objects do
                    labels[square.objects[index].label] = true
                end
                return labels
            end
            local originalSquare = squares[squareKey(bx40EastX,
                eastGarageY[-2], 0)]
            local demolishedSquare = squares[squareKey(bx40EastX,
                eastGarageY[-1], 0)]
            local replacementSquare = squares[squareKey(bx40EastX,
                eastGarageY[0], 0)]
            local windowSquare = squares[squareKey(bx40EastX,
                eastGarageY[1], 0)]
            local originalLabels = labelsIn(originalSquare)
            local replacementLabels = labelsIn(replacementSquare)
            local windowLabels = labelsIn(windowSquare)
            local adjacentLabels = labelsIn(adjacentSquare)
            local specialObjectsOk = originalLabels["original-garage"]
                and not originalLabels["illegal-floor"]
                and not originalLabels["illegal-north-wall"]
                and not originalLabels["ordinary-furniture"]
                and not originalLabels["mixed-corner"]
                and #demolishedSquare.objects == 0
                and replacementLabels["west-replacement"]
                and not replacementLabels["north-at-replacement"]
                and windowLabels["west-window"]
                and not windowLabels["north-window"]
                and not windowLabels["misoriented-west-window"]
                and not windowLabels["north-facing-furniture"]
                and originalGarage.health == 37
                and additionTransmissions[1]
                and adjacentLabels[additionTransmissions[1].label]
                and #additionTransmissions == 1
            local specialCellCreatedNoGarage = #additionTransmissions == 1
                and additionTransmissions[1].templateIndex
                    ~= originalGarageEntry.templateIndex
            local removalsWereSynchronized = eastRemovalCount == 8
            local westInactiveObjectsRemoved = #westNearSquare.objects == 0
                and #westFarSquare.objects == 0
            local westInactiveRemovalVisits =
                repairVisits[tostring(westNearCell.x) .. ":"
                    .. tostring(westNearCell.y)] ~= nil
                and repairVisits[tostring(westFarCell.x) .. ":"
                    .. tostring(westFarCell.y)] ~= nil
            local westInactiveRemovalsWereSynchronized = #removalTransmissions
                == eastRemovalCount + 3
                and removalTransmissions[eastRemovalCount + 1] == "west-near-wall"
                and removalTransmissions[eastRemovalCount + 2] == "west-far-wall"
                and removalTransmissions[eastRemovalCount + 3] == "west-far-furniture"
            local activeBuildWallRemains = activeBuildable
                and #activeBuildSquare.objects == 1
                and activeBuildSquare.objects[1] == activeBuildWall

            -- The exception does not apply to either other registered template.
            local otherTemplateCellsRemainBuildable = true
            local otherTemplateDiagnostic = {}
            local otherAnchor = { x = 2150, y = 2150, z = 0 }
            for _, templateId in ipairs({ RoomTemplate.TEMPLATE_ID,
                RoomTemplate.ENGINE_AREA_TEMPLATE_ID }) do
                local boundary = makeBoundary(templateId,
                    "other-" .. templateId, otherAnchor)
                local template = RoomTemplate.get(templateId)
                local buildCell = template.misc.buildCells[1]
                local x, y = otherAnchor.x + buildCell.x,
                    otherAnchor.y + buildCell.y
                assert(Geometry.isBuildable({ x = x, y = y, z = anchor.z },
                    otherAnchor, template))
                local existingCell = addSquare(x, y, 0, {
                    makeObject("IsoThumpable", "Thumpable",
                        "offline-build-area-object", false, {},
                        "other-template-build-object", playerBuiltTag()),
                })
                local beforeVisit = repairVisits[tostring(x) .. ":" .. tostring(y)] or 0
                local beforeRepairCalls = repairCallsByRvId[boundary.rvId] or 0
                local queued = repair.isProtectedCell(boundary, x, y)
                activeBoundary = boundary
                local repairChanged = repair.repairCell(player, boundary, x, y)
                local afterDirectRepairCalls = repairCallsByRvId[boundary.rvId] or 0
                sampleAndDrain(boundary, x, y)
                local afterVisit = repairVisits[tostring(x) .. ":" .. tostring(y)] or 0
                local afterRepairCalls = repairCallsByRvId[boundary.rvId] or 0
                otherTemplateDiagnostic[#otherTemplateDiagnostic + 1] =
                    templateId .. " queued=" .. tostring(queued)
                    .. " changed=" .. tostring(repairChanged)
                    .. " objects=" .. tostring(#existingCell.objects)
                    .. " visits=" .. tostring(beforeVisit) .. "->"
                    .. tostring(afterVisit) .. " calls="
                    .. tostring(beforeRepairCalls) .. "->"
                    .. tostring(afterDirectRepairCalls) .. "->"
                    .. tostring(afterRepairCalls)
                if not queued or repairChanged == true
                    or #existingCell.objects ~= 1
                    or afterVisit ~= beforeVisit
                    or afterRepairCalls == afterDirectRepairCalls then
                    otherTemplateCellsRemainBuildable = false
                end
            end

            result = {
                specialVisits = specialVisits,
                specialObjectsOk = specialObjectsOk == true,
                specialCellCreatedNoGarage = specialCellCreatedNoGarage,
                removalTransmissions = #removalTransmissions,
                removalsWereSynchronized = removalsWereSynchronized,
                westTargetsAreInactive = westTargetsAreInactive,
                westCandidatesQueued = westCandidatesQueued,
                westInactiveObjectsRemoved = westInactiveObjectsRemoved,
                westInactiveRemovalVisits = westInactiveRemovalVisits,
                westInactiveRemovalsWereSynchronized = westInactiveRemovalsWereSynchronized,
                removalLabels = table.concat(removalTransmissions, ","),
                activeBuildWallRemains = activeBuildWallRemains,
                activeBuildable = activeBuildable,
                activeBuildCellQueued = activeBuildCellQueued,
                activeBuildCellVisited = activeBuildCellVisited == true,
                removalCoordinates = table.concat(removalCoordinates, ","),
                additionTransmissions = #additionTransmissions,
                adjacentProtectedWallRestored = adjacentLabels[
                    additionTransmissions[1] and additionTransmissions[1].label],
                otherTemplateCellsRemainBuildable = otherTemplateCellsRemainBuildable,
                otherTemplateDiagnostic = table.concat(otherTemplateDiagnostic, "; "),
            }
            '''
        )

        result = lua.globals().result
        self.assertTrue(result["specialVisits"])
        self.assertTrue(result["specialObjectsOk"])
        self.assertTrue(result["specialCellCreatedNoGarage"])
        self.assertEqual(result["removalTransmissions"], 11,
            str(result["removalLabels"]) + " activeBuildable="
            + str(result["activeBuildable"]) + " activeQueued="
            + str(result["activeBuildCellQueued"]) + " activeVisited="
            + str(result["activeBuildCellVisited"]) + " removedAt="
            + str(result["removalCoordinates"]))
        self.assertTrue(result["removalsWereSynchronized"])
        self.assertTrue(result["westTargetsAreInactive"])
        self.assertTrue(result["westCandidatesQueued"])
        self.assertTrue(result["westInactiveObjectsRemoved"])
        self.assertTrue(result["westInactiveRemovalVisits"])
        self.assertTrue(result["westInactiveRemovalsWereSynchronized"])
        self.assertTrue(result["activeBuildWallRemains"])
        self.assertEqual(result["additionTransmissions"], 1)
        self.assertTrue(result["adjacentProtectedWallRestored"])
        self.assertTrue(result["otherTemplateCellsRemainBuildable"], str(
            {key: result[key] for key in result.keys()})
            + " " + str(result["otherTemplateDiagnostic"]))


if __name__ == "__main__":
    unittest.main()
