from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MEDIA_LUA = ROOT / "contents/mods/RailroaderRV/42/media/lua"


class CabooseTemplateTests(unittest.TestCase):
    def test_captured_layout_fences_openings_and_demolition_contract(self) -> None:
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().mediaLuaRoot = MEDIA_LUA.as_posix()
        lua.execute(
            "package.path = mediaLuaRoot .. '/server/?.lua;' "
            ".. mediaLuaRoot .. '/shared/?.lua;' .. package.path"
        )
        lua.execute(
            r'''
            local RoomTemplate = require(
                "RailroaderRV/RoomTemplate/RV_RoomTemplate")
            local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
            local Geometry = require(
                "RailroaderRV/RoomTemplate/RV_TemplateGeometry")
            local CabooseId = RoomTemplate.CAR_CABOOSE_TEMPLATE_ID
            local caboose = RoomTemplate.get(CabooseId)
            assert(RoomTemplate.templateIdForKind("car_cb", false)
                == CabooseId)
            assert(caboose.metadata.objectCount == 267
                and #caboose.objects == 267)

            local walk = caboose.misc.walkAabbs[1]
            assert(walk.minX == -3 and walk.maxX == 3
                and walk.minY == -7 and walk.maxY == 8
                and walk.minZ == 0 and walk.maxZExclusive == 1)
            local build = {}
            for index = 1, #caboose.misc.buildCells do
                local cell = caboose.misc.buildCells[index]
                build[tostring(cell.x) .. ":" .. tostring(cell.y)] = true
            end
            assert(#caboose.misc.buildCells == 78)
            for y = -6, 6 do
                for x = -3, 2 do
                    assert(build[tostring(x) .. ":" .. tostring(y)])
                end
            end
            for x = -3, 2 do
                assert(not build[tostring(x) .. ":-7"])
                assert(not build[tostring(x) .. ":7"])
            end
            assert(#caboose.roofCells == 90 and #caboose.waterProxies == 10)

            local doors, frames, windows, cabooseFences = {}, {}, {}, {}
            local activityFloors = {}
            local northWalls, eastWalls, westEndPost, southEndWalls =
                {}, {}, nil, {}
            for index = 1, #caboose.objects do
                local entry = caboose.objects[index]
                if entry.name == "Wooden Door" then
                    doors[#doors + 1] = entry
                    assert(entry.class == "IsoThumpable"
                        and entry.openSprite == "location_shop_gas2go_01_63"
                        and entry.state.health == 400
                        and entry.state.maxHealth == 400
                        and not entry.protected)
                elseif entry.name == "Wooden Door Frame" then
                    frames[#frames + 1] = entry
                    assert(entry.class == "IsoThumpable"
                        and entry.state.health == 400
                        and entry.state.maxHealth == 400
                        and not entry.protected)
                elseif entry.class == "IsoWindow" then
                    windows[#windows + 1] = entry
                    assert(entry.state.health == 50
                        and entry.state.maxHealth == nil
                        and not entry.protected)
                end
                if entry.class == "IsoObject" and entry.name == "Floor"
                    and entry.z == 0 then
                    local key = tostring(entry.x) .. ":" .. tostring(entry.y)
                    assert(activityFloors[key] == nil)
                    activityFloors[key] = true
                end
                if entry.sprite == "fixtures_railings_01_49" then
                    cabooseFences[#cabooseFences + 1] = entry
                    assert(entry.class == "IsoThumpable"
                        and entry.state.hoppable == true
                        and entry.state.blockAllTheSquare == nil)
                    for wallIndex = 1, #caboose.objects do
                        local wall = caboose.objects[wallIndex]
                        assert(not (wall.class == "IsoThumpable"
                            and wall.name == "Wooden Wall"
                            and wall.x == entry.x and wall.y == entry.y
                            and wall.z == entry.z
                            and wall.north == entry.north
                            and wall.state.doRender == false))
                    end
                end
                assert(entry.sprite ~= "fixtures_railings_01_36"
                    and entry.sprite ~= "fixtures_railings_01_37")
                if entry.name == "Wooden Wall" and entry.y == -6
                    and entry.north == true then
                    northWalls[#northWalls + 1] = entry
                    assert(not entry.protected)
                end
                if entry.name == "Wooden Wall" and entry.x == 3
                    and entry.north == false then
                    eastWalls[#eastWalls + 1] = entry
                    assert(entry.protected)
                end
                if entry.name == "Wooden Wall" and entry.x == -3
                    and entry.y == -7 and entry.north == false then
                    westEndPost = entry
                    assert(not entry.protected)
                end
                if entry.name == "Wooden Wall" and entry.y == 7
                    and entry.north == true then
                    southEndWalls[#southEndWalls + 1] = entry
                    assert(entry.protected)
                end
            end
            assert(#doors == 2 and #frames == 2 and #windows == 10)
            local activityFloorCount = 0
            for _ in pairs(activityFloors) do
                activityFloorCount = activityFloorCount + 1
            end
            assert(activityFloorCount == 90 and #cabooseFences == 12)
            assert(#northWalls == 5 and #eastWalls > 0
                and westEndPost ~= nil and #southEndWalls > 0)
            for index = 1, #caboose.objects do
                assert(caboose.objects[index].sprite
                    ~= "fixtures_sinks_01_18")
            end

            local function shellIndices(layout)
                local result = {}
                for edgeIndex = 1, #layout.wallCoordinates do
                    local edge = layout.wallCoordinates[edgeIndex]
                    for index = 1, #edge.templateIndices do
                        result[edge.templateIndices[index]] = edge
                    end
                end
                return result
            end
            local cabooseLayout = Layout.make(100, 200, 0, CabooseId)
            local cabooseShell = shellIndices(cabooseLayout)
            for index = 1, #caboose.objects do
                assert(not (caboose.objects[index].sprite
                    == "fixtures_railings_01_49" and cabooseShell[index]))
            end
            assert(cabooseShell[westEndPost.templateIndex]
                and cabooseShell[westEndPost.templateIndex].edgeSide == "west")
            local westEdge = cabooseLayout.shellEdges[
                cabooseShell[westEndPost.templateIndex].edgeKey]
            assert(westEdge.replacementAllowed == true
                and westEdge.role == "wall-west")
            assert(not cabooseShell[northWalls[1].templateIndex])

            -- The north end wall is on y=-6, inside the build mask. The actual
            -- protection-repair path must not put that cell back after removal.
            local anchor = { x = 1050, y = 2050, z = 0 }
            local boundary = {
                rvId = "caboose-test", generation = 1,
                templateId = CabooseId,
                managed = {
                    originX = anchor.x + caboose.metadata.minX,
                    originY = anchor.y + caboose.metadata.minY,
                    width = caboose.metadata.width,
                    height = caboose.metadata.height,
                    minZ = 0, maxZ = 32,
                },
            }
            local repairFactory = require(
                "RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair")
            local repair = repairFactory({
                Constants = {}, RV = { Server = {} }, ServerUtil = {},
                ServerWorld = {},
                Boundary = {
                    boundaryForPlayer = function() return boundary end,
                },
            })
            local player = {}
            local northWallX, northWallY = anchor.x, anchor.y - 6
            assert(Geometry.isBuildable({ x = northWallX, y = northWallY,
                z = 0 }, anchor, caboose))
            assert(repair.repairCell(player, boundary, northWallX, northWallY)
                == false)
            ''')

    def test_both_locomotive_templates_keep_all_fences_out_of_shell_edges(self) -> None:
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().mediaLuaRoot = MEDIA_LUA.as_posix()
        lua.execute(
            "package.path = mediaLuaRoot .. '/shared/?.lua;' .. package.path"
        )
        lua.execute(
            r'''
            local RoomTemplate = require(
                "RailroaderRV/RoomTemplate/RV_RoomTemplate")
            local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
            local ids = {
                RoomTemplate.TEMPLATE_ID,
                RoomTemplate.ENGINE_AREA_TEMPLATE_ID,
            }
            for _, templateId in ipairs(ids) do
                local template = RoomTemplate.get(templateId)
                local layout = Layout.make(100, 200, 0, templateId)
                local shell = {}
                for edgeIndex = 1, #layout.wallCoordinates do
                    local edge = layout.wallCoordinates[edgeIndex]
                    for index = 1, #edge.templateIndices do
                        shell[edge.templateIndices[index]] = true
                    end
                end
                local counts = { ["fixtures_railings_01_48"] = 0,
                    ["fixtures_railings_01_49"] = 0 }
                local fenceEdges = {}
                for index = 1, #template.objects do
                    local entry = template.objects[index]
                    if counts[entry.sprite] ~= nil then
                        counts[entry.sprite] = counts[entry.sprite] + 1
                        assert(entry.class == "IsoThumpable"
                            and entry.name == "Thumpable"
                            and entry.state.hoppable == true
                            and entry.state.blockAllTheSquare == nil
                            and entry.north
                                == (entry.sprite == "fixtures_railings_01_49"))
                        assert(shell[index] == nil,
                            "locomotive fence was classified as shell wall")
                        local key = table.concat({ entry.x, entry.y,
                            entry.z, tostring(entry.north) }, ":")
                        fenceEdges[key] = true
                    end
                end
                for index = 1, #template.objects do
                    local entry = template.objects[index]
                    local key = table.concat({ entry.x, entry.y,
                        entry.z, tostring(entry.north) }, ":")
                    assert(not (entry.class == "IsoThumpable"
                        and entry.name == "Wooden Wall"
                        and entry.state.doRender == false
                        and fenceEdges[key]),
                        "locomotive fence has a same-edge hidden wall blocker")
                end
                assert(counts["fixtures_railings_01_48"] == 34
                    and counts["fixtures_railings_01_49"] == 16)
            end
            ''')

    def test_protection_repair_keeps_existing_west_corner_walls_and_open_door(self) -> None:
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

            local RoomTemplate = require(
                "RailroaderRV/RoomTemplate/RV_RoomTemplate")
            local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
            local CabooseId = RoomTemplate.CAR_CABOOSE_TEMPLATE_ID
            local template = RoomTemplate.get(CabooseId)
            local layout = Layout.make(150, 250, 0, CabooseId)
            local boundary = {
                rvId = "repair-caboose", generation = 1,
                templateId = CabooseId, managed = layout.managed,
                shellEdges = layout.shellEdges,
            }
            local cell = {}
            local squares = {}
            local restoreCount = 0

            local function key(x, y, z)
                return tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
            end
            local function edgeForTemplateIndex(templateIndex)
                for _, edge in ipairs(layout.wallCoordinates) do
                    for _, index in ipairs(edge.templateIndices) do
                        if index == templateIndex then return edge end
                    end
                end
            end
            local function makeObject(entry, square, openDoorIndex,
                damagedTemplateIndex)
                local object = {
                    class = entry.class, name = entry.name,
                    direction = "north", north = entry.north,
                    sprite = entry.templateIndex == openDoorIndex
                        and entry.openSprite or entry.sprite,
                    health = entry.templateIndex == damagedTemplateIndex
                        and 1 or entry.state.health,
                    maxHealth = entry.state.maxHealth,
                    hoppable = entry.state.hoppable,
                    locked = entry.state.locked,
                    canPassThrough = entry.state.canPassThrough,
                    blockAllTheSquare = entry.state.blockAllTheSquare,
                    thumpable = entry.state.thumpable,
                    door = entry.name == "Wooden Door",
                    square = square,
                }
                function object:getName() return self.name end
                function object:getDir() return self.direction end
                function object:getNorth() return self.north end
                function object:getHealth() return self.health end
                function object:getMaxHealth() return self.maxHealth end
                function object:isHoppable() return self.hoppable end
                function object:isLocked() return self.locked end
                function object:isCanPassThrough()
                    return self.canPassThrough
                end
                function object:isBlockAllTheSquare()
                    return self.blockAllTheSquare
                end
                function object:isThumpable() return self.thumpable end
                function object:isDoor() return self.door end
                function object:isWindow() return false end
                function object:getOpenSprite()
                    if not entry.openSprite then return nil end
                    return { getName = function()
                        return entry.openSprite
                    end }
                end
                function object:getContainerCount() return 1 end
                function object:getContainer() return nil end
                local edge = edgeForTemplateIndex(entry.templateIndex)
                local tag = {
                    owner = "RailroaderRV", rvId = boundary.rvId,
                    generation = boundary.generation,
                    templateIndex = entry.templateIndex,
                    role = edge and edge.role or "captured-template",
                }
                if edge then tag.edgeKey = edge.edgeKey end
                object.modData = { RailroaderRV = tag }
                square.objects[#square.objects + 1] = object
                return object
            end
            local function makeSquare(templateX, templateY, omitIndex,
                openDoorIndex, damagedTemplateIndex)
                local square = { objects = {} }
                for index = 1, #template.objects do
                    local entry = template.objects[index]
                    if entry.x == templateX and entry.y == templateY
                        and entry.z == 0
                        and index ~= omitIndex then
                        makeObject(entry, square, openDoorIndex,
                            damagedTemplateIndex)
                    end
                end
                squares[key(150 + templateX, 250 + templateY, 0)] = square
                return square
            end
            local function hasTemplateEntry(square, index)
                for _, object in ipairs(square.objects) do
                    if object.modData.RailroaderRV.templateIndex == index then
                        return true
                    end
                end
                return false
            end
            local function templateEntryObject(square, index)
                for _, object in ipairs(square.objects) do
                    if object.modData.RailroaderRV.templateIndex == index then
                        return object
                    end
                end
            end

            local corners = {}
            for _, xy in ipairs({ { -3, -7 }, { -3, 8 },
                { 3, -7 }, { 3, 8 } }) do
                local x, y = xy[1], xy[2]
                local wall
                for index = 1, #template.objects do
                    local entry = template.objects[index]
                    if entry.x == x and entry.y == y
                        and entry.name == "Wooden Wall"
                        and entry.north == false then
                        wall = entry
                        break
                    end
                end
                assert(wall ~= nil)
                local damageIndex = (x == -3 or x == 3) and y == -7
                    and wall.templateIndex or nil
                local square = makeSquare(x, y, nil, nil, damageIndex)
                corners[#corners + 1] = {
                    x = 150 + x, y = 250 + y,
                    templateIndex = wall.templateIndex,
                    square = square,
                }
            end

            local southDoor
            for index = 1, #template.objects do
                local entry = template.objects[index]
                if entry.name == "Wooden Door" and entry.y == 7 then
                    southDoor = entry
                end
            end
            assert(southDoor and southDoor.openSprite
                == "location_shop_gas2go_01_63")
            local southDoorSquare = makeSquare(-1, 7, nil,
                southDoor.templateIndex)
            assert(hasTemplateEntry(southDoorSquare,
                southDoor.templateIndex))

            local ServerUtil = require("RailroaderRV/Common/RV_ServerUtil")
            local ServerWorld = {
                getCellForPlayer = function() return cell end,
                getSquare = function(_, x, y, z)
                    return squares[key(x, y, z)]
                end,
                squareSnapshot = function(square)
                    local result = {}
                    for index = 1, #square.objects do
                        result[index] = square.objects[index]
                    end
                    return result
                end,
                objectModData = function(object) return object.modData end,
                getSpriteName = function(object) return object.sprite end,
                isPlayerObject = function() return false end,
                isVehicleObject = function() return false end,
                removeGenericObject = function(square, object)
                    for index = #square.objects, 1, -1 do
                        if square.objects[index] == object then
                            table.remove(square.objects, index)
                            return
                        end
                    end
                end,
                squareContainsObject = function(square, object)
                    for _, current in ipairs(square.objects) do
                        if current == object then return true end
                    end
                    return false
                end,
            }
            local repair = require(
                "RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair")({
                Constants = {
                    MOD_ID = "RailroaderRV", WORLD_MIN_Z = 0,
                    WORLD_MAX_Z = 0,
                },
                RV = { Server = {} }, ServerUtil = ServerUtil,
                ServerWorld = ServerWorld,
                Boundary = {
                    boundaryForPlayer = function() return boundary end,
                },
                createCapturedTemplateObject = function(_, square, entry)
                    restoreCount = restoreCount + 1
                    makeObject(entry, square)
                end,
                configureCapturedDoorFrame = function() end,
            })
            local player = {}
            local eastChanged = false
            for _, corner in ipairs(corners) do
                local changed = repair.repairCell(player, boundary,
                    corner.x, corner.y)
                if corner.x == 153 and corner.y == 243 then
                    eastChanged = changed
                end
                assert(hasTemplateEntry(corner.square, corner.templateIndex),
                    "repair removed an existing caboose corner wall")
            end
            assert(templateEntryObject(corners[1].square,
                corners[1].templateIndex).health == 1,
                "repair reset a damaged unprotected west corner wall")
            local eastWall = templateEntryObject(corners[3].square,
                corners[3].templateIndex)
            assert(eastWall and eastWall.health
                == template.objects[corners[3].templateIndex].state.health,
                "repair did not restore the protected east corner wall: health="
                    .. tostring(eastWall and eastWall.health)
                    .. " expected=" .. tostring(template.objects[
                        corners[3].templateIndex].state.health)
                    .. " restores=" .. tostring(restoreCount)
                    .. " changed=" .. tostring(eastChanged)
                    .. " protected=" .. tostring(repair.isProtectedCell(
                        boundary, 153, 243)))
            assert(restoreCount == 1)
            repair.repairCell(player, boundary, 149, 257)
            assert(hasTemplateEntry(southDoorSquare, southDoor.templateIndex),
                "repair removed an opened south caboose door")

            local missingWest = makeSquare(-3, -7,
                corners[1].templateIndex)
            repair.repairCell(player, boundary, 147, 243)
            assert(not hasTemplateEntry(missingWest,
                corners[1].templateIndex),
                "repair restored an intentionally missing unprotected wall")
            assert(restoreCount == 1)
            '''
        )

    def test_production_build_creates_captured_objects_and_service_proxies(self) -> None:
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().mediaLuaRoot = MEDIA_LUA.as_posix()
        lua.execute(
            "package.path = mediaLuaRoot .. '/server/?.lua;' "
            ".. mediaLuaRoot .. '/shared/?.lua;' .. package.path"
        )
        lua.execute(
            r'''
            local RoomTemplate = require(
                "RailroaderRV/RoomTemplate/RV_RoomTemplate")
            local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
            local events = {}
            local player = {}
            local layout = Layout.make(100, 200, 0,
                RoomTemplate.CAR_CABOOSE_TEMPLATE_ID)
            local pending = {
                player = player, rvId = "caboose-test", generation = 1,
                stage = "BUILD", layout = layout,
            }
            local ctx = {
                Constants = {}, Boundary = {}, ServerSchema = {},
                ServerUtil = { invoke = function() return false, nil end },
                ServerWorld = {
                    getCellForPlayer = function() return {} end,
                    getSquare = function(_, x, y, z)
                        return { x = x, y = y, z = z }
                    end,
                    recalcSquare = function() end,
                },
                GenerationTransaction = {
                    owns = function(candidate) return candidate == player end,
                    current = function() return pending end,
                },
                ensureRoofSquare = function() error("unexpected missing square") end,
                createCapturedTemplateObject = function(_, _, entry)
                    events[#events + 1] = {
                        kind = "captured", index = entry.templateIndex,
                        sprite = entry.sprite,
                    }
                end,
                createGenerator = function()
                    events[#events + 1] = { kind = "generator" }
                end,
                createWaterProxy = function()
                    events[#events + 1] = { kind = "water" }
                end,
                RV = { Server = {} },
            }
            require("RailroaderRV/Construction/RV_Server_GenerationBuild")(ctx)
            local bounds = {
                roomMinX = 97, roomMaxX = 102,
                roomMinY = 193, roomMaxY = 207, z = 0,
                wallCoordinates = layout.wallCoordinates,
            }
            ctx.buildGeneration(player, layout, bounds, 1, "production")
            assert(#events == 267 + 1 + 10)
            for index = 1, 267 do
                assert(events[index].kind == "captured"
                    and events[index].index == index)
            end
            assert(events[268].kind == "generator")
            for index = 269, #events do
                assert(events[index].kind == "water")
            end
            ''')

    def test_standalone_car_cb_enters_as_external_cut_and_exits_via_cargo_path(self) -> None:
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().mediaLuaRoot = MEDIA_LUA.as_posix()
        lua.execute(
            "package.path = mediaLuaRoot .. '/server/?.lua;' "
            ".. mediaLuaRoot .. '/shared/?.lua;' .. package.path"
        )
        lua.execute(
            r'''
            local CabooseId = require(
                "RailroaderRV/RoomTemplate/RV_RoomTemplate").CAR_CABOOSE_TEMPLATE_ID
            local requested
            local exitPayload, exitTarget
            package.preload["Railroader/RR_API"] = function() return {} end
            package.loaded["RailroaderRV/Common/RV_ServerTeleport"] = {
                teleportToPosition = function(_, target)
                    exitTarget = target
                    return true
                end,
                teleportToRVSpawn = function() return true end,
            }
            package.loaded["RailroaderRV/Core/RV_ServerClientDispatch"] = {
                sendToPlayer = function(_, _, _, payload)
                    exitPayload = payload
                    return true
                end,
            }
            RR = { API = { lastKnown = function(carId)
                assert(carId == 77)
                return { x = 80, y = 90, z = 0 }
            end } }
            RailroaderRV = { Server = {
                requestRailroaderGeneration = function(_, data)
                    requested = data
                    return true
                end,
            } }

            local player = {}
            local unit = {
                id = 77, kind = "car_cb", isLocomotive = false,
                isCut = true, locomotiveId = nil,
                x = 80, y = 90, z = 0, dirX = 1, dirY = 0, speed = 0,
            }
            local map = { flatcars = {}, players = {}, locomotives = {} }
            local recordInside = nil
            local client = {
                playerId = function() return 14 end,
                playerName = function() return "tester" end,
                playerDead = function() return false end,
                playerPosition = function() return { x = 80, y = 90, z = 0 } end,
                copyPosition = function(position)
                    return { x = position.x, y = position.y, z = position.z }
                end,
                newTransitionToken = function(kind, record)
                    return kind .. ":" .. tostring(record.locoId)
                end,
                processIsServer = function() return true end,
                C = { RV_STOPPED_SPEED = 0, INVALID_RV_DATA = "invalid" },
                unpackFn = table.unpack,
                Adapter = { _ticks = 10 },
                Boundary = {
                    beginTransition = function() return true end,
                    completeTransition = function() return true end,
                    clearPlayer = function() end,
                },
                wallReloadTransactionBlocks = function() return false end,
                mapData = function() return map end,
                recordAtPlayerCoordinate = function()
                    if recordInside then
                        return recordInside, "77", nil, "inside-rv"
                    end
                    return nil, nil, nil, "outside-rv"
                end,
                findTrain = function(id)
                    assert(tostring(id) == "77")
                    return unit
                end,
                trainId = function(train) return train.id end,
                trainPosition = function(train)
                    return { x = train.x, y = train.y, z = train.z }
                end,
                trainPose = function(train)
                    return { x = train.x, y = train.y, z = train.z,
                        dirX = train.dirX, dirY = train.dirY }
                end,
                trainGeometry = function() return {} end,
                trainMoving = function() return false end,
                interactionGeometry = function() return 0, 1 end,
                singleplayerMode = function() return false end,
                seatPosition = function() return nil end,
                mapDataChanged = function() end,
                markMappingChanged = function() end,
                rvRegion = function() return {} end,
                refreshRoofForPlayer = function() end,
                armRoomOwnershipMonitor = function() end,
                recordForLoco = function() return nil end,
                integer = function(value) return value end,
            }
            local trainFactory = require(
                "RailroaderRV/RVMapping/RV_RailroaderServer_Train")
            trainFactory(client)
            client.findTrain = function(id)
                assert(tostring(id) == "77")
                return unit
            end
            client.trainGeometry = function() return {} end
            client.interactionGeometry = function() return 0, 1 end
            client.playerId = function() return 14 end
            client.playerName = function() return "tester" end
            client.playerDead = function() return false end
            client.playerPosition = function()
                return { x = 80, y = 90, z = 0 }
            end
            client.copyPosition = function(position)
                return { x = position.x, y = position.y, z = position.z }
            end
            client.newTransitionToken = function(kind, record)
                return kind .. ":" .. tostring(record.locoId)
            end
            local role = client.playerRole(unit, player)
            assert(role == "external")
            assert(client.forgetTrainSeat(unit, player) == "external")

            require("RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit")(
                client)
            local entered, enterReason = client.enterPlayer(player, 77)
            assert(entered == true, tostring(enterReason))
            assert(requested and requested.locoId == "77"
                and requested.sourceRole == "external"
                and requested.sourceSeat == nil)

            recordInside = {
                templateId = CabooseId, locoId = "77", generation = 1,
                players = {},
            }
            assert(client.exitPlayer(player) == true)
            assert(exitPayload.action == "exit-board"
                and exitPayload.role == "external"
                and exitPayload.locoId == "77"
                and exitPayload.boardCarId == 77
                and exitPayload.boardToken == "exit:77")
            assert(exitTarget.x == 80 and exitTarget.y == 90
                and exitTarget.z == 0)
            ''')


if __name__ == "__main__":
    unittest.main(verbosity=2)
