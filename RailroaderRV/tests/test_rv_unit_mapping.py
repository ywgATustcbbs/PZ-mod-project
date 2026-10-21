from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "contents/mods/RailroaderRV/42/media/lua"


def make_lua() -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    shared = (MOD / "shared").as_posix()
    server = (MOD / "server").as_posix()
    lua.execute(
        "package.path = " + repr(f"{shared}/?.lua;{server}/?.lua;")
        + " .. package.path"
    )
    lua.execute(
        r"""
        C = require("RailroaderRV/Common/RV_Constants")
        currentOwner = 101
        currentCut = false
        currentSpeed = 3
        currentRole = "passenger"
        unitId = 201
        currentKind = "car_box"
        currentLocomotive = false
        currentPoseAvailable = true
        currentAssignReasons = nil
        currentTrainLoaded = true
        currentLastKnownReason = nil
        currentLastKnownOverride = nil
        currentBoardPointReason = nil
        currentBoardPoint = { x = 11.25, y = 20.25, z = 0.46 }
        playerX, playerY, playerZ = 10, 20, 0
        playerConnected = true
        currentUnit = function()
            local id = currentLocomotive and 301 or unitId
            local pose = currentPoseAvailable and {
                x = 10.25, y = 20.25, z = 0, dirX = 1, dirY = 0,
            } or {}
            return {
                id = id, kind = currentLocomotive and "loco" or currentKind,
                isLocomotive = currentLocomotive,
                locomotiveId = currentLocomotive and id or currentOwner,
                isCut = currentCut, speed = currentSpeed,
                x = pose.x, y = pose.y, z = pose.z,
                dirX = pose.dirX, dirY = pose.dirY,
            }
        end
        adapterTrace = { riderIds = {}, releaseIds = {}, assignIds = {},
            assignments = {},
            geometryIds = {}, worldSquares = {}, lastKnownIds = {},
            lastKnownOuts = {}, boardPointIds = {}, extensions = 0,
            transitions = 0,
            completions = 0, clears = 0, utilitySettles = 0,
            generationRequests = 0, teleports = 0 }
        local api = {
            mode = function() return "multiplayer" end,
            trains = function() return {} end,
            riderState = function(id, player)
                adapterTrace.riderIds[#adapterTrace.riderIds + 1] = id
                return { role = currentRole, seatIndex = 2 }
            end,
            releaseRider = function(id, player)
                adapterTrace.releaseIds[#adapterTrace.releaseIds + 1] = id
                return { role = currentRole, seatIndex = 2 }
            end,
            assignRider = function(id, player, role, seat)
                adapterTrace.assignIds[#adapterTrace.assignIds + 1] = id
                adapterTrace.assignments[#adapterTrace.assignments + 1] = {
                    id = id, player = player, role = role, seat = seat,
                }
                if currentAssignReasons and #currentAssignReasons > 0 then
                    local reason = table.remove(currentAssignReasons, 1)
                    if reason then return nil, reason end
                end
                return { role = role, seatIndex = seat,
                    position = { x = 1, y = 2, z = 0 } }
            end,
            locomotiveGeometry = function(id)
                adapterTrace.geometryIds[#adapterTrace.geometryIds + 1] = id
                return { seatPositions = {
                    [2] = { x = 3.5, y = 4.5, z = 0 },
                } }
            end,
            lastKnown = function(id, out)
                assert(type(id) == "number")
                adapterTrace.lastKnownIds[#adapterTrace.lastKnownIds + 1] = id
                if currentLastKnownReason then
                    return nil, currentLastKnownReason
                end
                out = out or {}
                adapterTrace.lastKnownOuts[#adapterTrace.lastKnownOuts + 1] = out
                local pose = currentLastKnownOverride or currentUnit()
                out.x, out.y, out.z = pose.x, pose.y, pose.z
                out.dirX, out.dirY = pose.dirX, pose.dirY
                out.kind = pose.kind
                out.loaded = currentTrainLoaded ~= false
                return out
            end,
            carBoardPoint = function(id, out)
                assert(type(id) == "number")
                adapterTrace.boardPointIds[#adapterTrace.boardPointIds + 1] = id
                if currentBoardPointReason then
                    return nil, currentBoardPointReason
                end
                out = out or {}
                out.x, out.y, out.z = currentBoardPoint.x,
                    currentBoardPoint.y, currentBoardPoint.z
                return out
            end,
        }
        RR = { API = api }
        package.loaded["Railroader/RR_API"] = api
        package.loaded["RailroaderRV/RVMapping/RV_RailroaderUnits"] = {
            find = function(id)
                if tostring(id) == tostring(currentUnit().id) then
                    return currentUnit()
                end
                return nil, "unknown"
            end,
            geometry = function(unit, x, y)
                if not currentPoseAvailable then return nil, "nopose" end
                local geometry = {
                    hullDistanceTiles = 0.5,
                    halfWidthTiles = 1.25,
                    x = unit.x, y = unit.y, z = unit.z,
                    dirX = unit.dirX, dirY = unit.dirY,
                }
                if unit.isLocomotive then geometry.mountReachTiles = 2.25 end
                return geometry
            end,
            list = function() return { currentUnit() } end,
        }
        package.loaded["RailroaderRV/RVMapping/RV_RegionSlots"] = nil
        package.loaded["RailroaderRV/RoomTemplate/RV_RoomTemplate"] = {
            TEMPLATE_ID = "railroader-rv",
            CAR_BOX_TEMPLATE_ID = "railroader-rv-car-box",
        }
        package.loaded["RailroaderRV/Common/RV_ServerTeleport"] = {
            teleportToPosition = function(player, position)
                adapterTrace.teleports = adapterTrace.teleports + 1
                teleportedPosition = position
                return true
            end,
            teleportToRVSpawn = function(player, relation, position)
                adapterTrace.teleports = adapterTrace.teleports + 1
                teleportedPosition = position
                teleportRelation = relation
                return true
            end,
        }
        package.loaded["RailroaderRV/Water/RV_UtilityWaterConstants"] = {
            OP_DRAW_WATER_FROM_SOURCE = "draw-water",
        }
        package.loaded["RailroaderRV/Core/RV_ServerClientDispatch"] = {
            sendToPlayer = function(player, module, command, args)
                sentServerPayload = args
                return true
            end,
        }
        player = {
            getOnlineID = function() return 41 end,
            getUsername = function() return "Alice" end,
            isDead = function() return false end,
            getX = function() return playerX end,
            getY = function() return playerY end,
            getZ = function() return playerZ end,
        }
        map = { schemaVersion = 1, locomotives = {}, players = {} }
        ModData = { get = function() return map end }
        mappingRecord = {
            generated = true, locoId = "201", generation = 1,
            templateId = "railroader-rv",
            slotIndex = 1, players = {},
            rvPosition = { x = 100, y = 100, z = 0 },
        }
        map.locomotives["201"] = mappingRecord
        map.players.Alice = {
            locoId = "201", onlineId = 41, inside = true,
            role = "external",
        }
        mappingRecord.players.Alice = {
            locoId = "201", onlineId = 41, inside = true,
            role = "external",
        }
        RailroaderRV = RailroaderRV or {}
        RailroaderRV.Constants = C
        RailroaderRV.Server = {
                settleRVUtilityLoad = function()
                    adapterTrace.utilitySettles = adapterTrace.utilitySettles + 1
                    return true
                end,
                requestRailroaderGeneration = function(targetPlayer, data)
                    adapterTrace.generationRequests =
                        adapterTrace.generationRequests + 1
                    generationData = data
                    return true
                end,
        }
        boundary = {
            beginTransition = function()
                adapterTrace.transitions = adapterTrace.transitions + 1
                return true
            end,
            completeTransition = function()
                adapterTrace.completions = adapterTrace.completions + 1
                return true
            end,
            extendTransition = function()
                adapterTrace.extensions = adapterTrace.extensions + 1
                return true
            end,
            clearPlayer = function()
                adapterTrace.clears = adapterTrace.clears + 1
            end,
        }
        world = {
            isValidSquare = function(self, x, y, z)
                adapterTrace.worldSquares[#adapterTrace.worldSquares + 1] =
                    { x = x, y = y, z = z }
                if allowedWorldY == nil then return true end
                return allowedWorldY[y] == true
            end,
        }
        function getWorld() return world end
        function makeServerContext()
            local ctx = {
                C = C,
                processIsServer = function() return true end,
                unpackFn = table.unpack,
                transitionSequence = 0,
                Adapter = {},
            }
            ctx.Adapter.onlinePlayersSnapshot = function()
                return playerConnected and { player } or {}, true
            end
            ctx.Adapter._ticks = 0
            require("RailroaderRV/RVMapping/RV_RailroaderServer_Train")(ctx)
            ctx.Boundary = boundary
            ctx.wallReloadTransactionBlocks = function() return false end
            ctx.mapData = function() return map end
            ctx.recordForLoco = function(value, id)
                local key = tostring(id)
                local record = value.locomotives[key]
                return record, record and key or nil
            end
            ctx.recordAtPlayerCoordinate = function()
                return mappingRecord, "201", currentUnit(), "active-mapped"
            end
            ctx.markMappingChanged = function() mappingChanged = true end
            ctx.rvRegion = function() return {} end
            ctx.refreshRoofForPlayer = function() return true end
            ctx.armRoomOwnershipMonitor = function() return true end
            ctx.singleplayerMode = function() return false end
            ctx.transactionBlocks = function() return false end
            ctx.callGlobal = function(name)
                assert(name == "getWorld")
                return true, world
            end
            ctx.call = function(target, method, ...)
                local args = { ... }
                return pcall(function()
                    return target[method](target, table.unpack(args))
                end)
            end
            ctx.recordAtPlayerCoordinate = function()
                if entryLookup then return nil, nil, nil, "outside-rv" end
                if currentTrainLoaded == false then
                    return mappingRecord, "201", nil, "inactive-mapped"
                end
                return mappingRecord, "201", currentUnit(), "active-mapped"
            end
            ctx.forgetTrainSeat = ctx.forgetTrainSeat
            ctx.assignTrainSeat = ctx.assignTrainSeat
            require("RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit")(ctx)
            return ctx
        end
        """
    )
    return lua


class RVUnitMappingTests(unittest.TestCase):
    def test_mapping_allocates_a_distinct_slot_for_each_unit_identity(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local slots = require("RailroaderRV/RVMapping/RV_RegionSlots")
            map.locomotives = {
                ["101"] = { locoId = "101", slotIndex = 1 },
            }
            local ctx = {
                Boundary = {},
                Adapter = { advanceMappingEpoch = function() end },
                C = C,
                WORLD_MIN_Z = C.WORLD_MIN_Z,
                WORLD_MAX_Z = C.WORLD_MAX_Z,
                number = function(value) return tonumber(value) end,
                integer = function(value) return math.floor(tonumber(value)) end,
                call = function(target, method, ...)
                    local args = { ... }
                    return pcall(function()
                        return target[method](target, table.unpack(args))
                    end)
                end,
                playerId = function() end,
                playerName = function() end,
                serverTransactionMutexStatus = function() return false end,
                onlinePlayersSnapshot = function() return {} end,
                findTrain = function() end,
                trainPosition = function() end,
                mapData = function() return map end,
            }
            package.loaded[
                "RailroaderRV/BoundaryGuard/RV_RailroaderServer_BoundaryValidation"] =
                function() return { invalidate = function() end } end
            require("RailroaderRV/RVMapping/RV_RailroaderServer_Mapping")(ctx)
            local firstOk, firstSlot = ctx.Adapter.allocateRVRegion("101")
            local secondOk, secondSlot = ctx.Adapter.allocateRVRegion("201")
            assert(firstOk and secondOk and firstSlot == 1 and secondSlot ~= 1)
            assert(slots.COUNT >= 2)
            """
        )

    def test_unit_seat_operations_resolve_the_current_owner(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local ctx = {
                C = C, processIsServer = function() return true end,
                unpackFn = table.unpack, Adapter = {},
            }
            require("RailroaderRV/RVMapping/RV_RailroaderServer_Train")(ctx)
            local car = ctx.findTrain(201)
            assert(ctx.trainId(car) == 201)
            local role, seat = ctx.playerRole(car, player)
            assert(role == "passenger" and seat == 2)
            assert(adapterTrace.riderIds[#adapterTrace.riderIds] == 101)
            assert(ctx.seatPosition(car, 2).x == 3.5)
            assert(adapterTrace.geometryIds[#adapterTrace.geometryIds] == 101)
            assert(ctx.assignTrainSeat(car, player, "passenger", 2))
            assert(adapterTrace.assignIds[#adapterTrace.assignIds] == 101)
            assert(ctx.forgetTrainSeat(car, player))
            assert(adapterTrace.releaseIds[#adapterTrace.releaseIds] == 101)

            currentOwner = 102
            local reattached = ctx.findTrain(201)
            ctx.playerRole(reattached, player)
            assert(adapterTrace.riderIds[#adapterTrace.riderIds] == 102)
            assert(ctx.assignTrainSeat(reattached, player, "passenger", 2))
            assert(adapterTrace.assignIds[#adapterTrace.assignIds] == 102)

            currentOwner = nil
            currentCut = true
            currentSpeed = 0
            local cut = ctx.findTrain(201)
            local cutRole = ctx.playerRole(cut, player)
            assert(cutRole == "external")
            local riderCalls = #adapterTrace.riderIds
            local releasedRole = ctx.forgetTrainSeat(cut, player)
            assert(releasedRole == "external")
            assert(#adapterTrace.riderIds == riderCalls)
            local assigned, reason = ctx.assignTrainSeat(cut, player,
                "passenger", 2)
            assert(assigned == nil
                and reason == "current owner locomotive is not available")
            assert(adapterTrace.assignIds[#adapterTrace.assignIds] == 102)
            """
        )

    def test_moving_owner_passenger_can_enter_each_unmapped_car_rv(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            -- An existing locomotive mapping must not block a distinct car.
            map.locomotives["201"] = nil
            map.locomotives["101"] = { locoId = "101", slotIndex = 1 }
            entryLookup = true
            local ctx = makeServerContext()
            local accepted, reason = ctx.enterPlayer(player, 201)
            assert(accepted == true and reason == nil)
            assert(adapterTrace.generationRequests == 1)
            assert(generationData.locoId == "201")
            assert(generationData.sourceRole == "passenger")
            assert(generationData.entryPosition.x == 3.5)
            assert(adapterTrace.riderIds[#adapterTrace.riderIds] == 101)
            assert(adapterTrace.releaseIds[#adapterTrace.releaseIds] == 101)

            currentRole = "driver"
            local driverAccepted = ctx.enterPlayer(player, 201)
            assert(driverAccepted == false)
            assert(adapterTrace.generationRequests == 1)

            currentRole = "outside"
            local outsideAccepted = ctx.enterPlayer(player, 201)
            assert(outsideAccepted == false)
            assert(adapterTrace.generationRequests == 1)

            currentRole = "passenger"
            currentPoseAvailable = false
            local noPoseAccepted = ctx.enterPlayer(player, 201)
            assert(noPoseAccepted == false)
            assert(adapterTrace.generationRequests == 1)
            assert(#adapterTrace.releaseIds == 1)
            """
        )

    def test_rejected_generation_request_restores_removed_passenger_seat(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            map.locomotives["201"] = nil
            map.locomotives["101"] = { locoId = "101", slotIndex = 1 }
            entryLookup = true
            local ctx = makeServerContext()
            local requestCalls = 0
            RailroaderRV.Server.requestRailroaderGeneration = function()
                requestCalls = requestCalls + 1
                return false, "generation queue rejected"
            end

            local entered, reason = ctx.enterPlayer(player, 201)
            assert(entered == false and reason == "generation queue rejected")
            assert(requestCalls == 1)
            assert(#adapterTrace.releaseIds == 1
                and adapterTrace.releaseIds[1] == 101)
            local restored = adapterTrace.assignments[1]
            assert(#adapterTrace.assignments == 1 and restored.id == 101
                and restored.player == player
                and restored.role == "passenger" and restored.seat == 2)
            """
        )

    def test_throwing_generation_request_restores_removed_passenger_seat(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            map.locomotives["201"] = nil
            map.locomotives["101"] = { locoId = "101", slotIndex = 1 }
            entryLookup = true
            local ctx = makeServerContext()
            local requestCalls = 0
            RailroaderRV.Server.requestRailroaderGeneration = function()
                requestCalls = requestCalls + 1
                error("generation queue exploded")
            end

            local ok, failure = pcall(ctx.enterPlayer, player, 201)
            assert(not ok and string.find(tostring(failure),
                "generation queue exploded", 1, true))
            assert(requestCalls == 1)
            assert(#adapterTrace.releaseIds == 1
                and adapterTrace.releaseIds[1] == 101)
            local restored = adapterTrace.assignments[1]
            assert(#adapterTrace.assignments == 1 and restored.id == 101
                and restored.player == player
                and restored.role == "passenger" and restored.seat == 2)
            """
        )

    def test_async_generation_failure_restores_seat_source_and_boundary(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local ctx = makeServerContext()
            ctx.restoreAfterGenerationFailure(player, {
                locoId = "201",
                removedRole = "passenger",
                removedSeat = 2,
                sourcePosition = { x = 3.5, y = 4.5, z = 0 },
                sourceRole = "passenger",
                sourceSeat = 2,
                rvId = "201",
                generation = 1,
            })

            local restored = adapterTrace.assignments[1]
            assert(#adapterTrace.assignments == 1 and restored.id == 101
                and restored.player == player
                and restored.role == "passenger" and restored.seat == 2)
            assert(adapterTrace.teleports == 1)
            assert(teleportedPosition.x == 3.5
                and teleportedPosition.y == 4.5
                and teleportedPosition.z == 0)
            assert(adapterTrace.clears == 1)
            """
        )

    def test_full_locomotive_seats_never_use_cargo_side_exit(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            currentLocomotive = true
            unitId = 301
            mappingRecord.locoId = "301"
            map.locomotives["201"] = nil
            map.locomotives["301"] = mappingRecord
            map.players.Alice.locoId = "301"
            mappingRecord.players.Alice.locoId = "301"
            local ctx = makeServerContext()

            currentAssignReasons = { "seatsfull", "seatsfull" }
            local firstExit, firstReason = ctx.exitPlayer(player)
            assert(firstExit == false and firstReason == "seatsfull")
            assert(#adapterTrace.assignIds == 2)
            assert(adapterTrace.assignIds[1] == 301
                and adapterTrace.assignIds[2] == 301)
            assert(#adapterTrace.lastKnownIds == 0)
            assert(#adapterTrace.worldSquares == 0 and adapterTrace.teleports == 0)
            assert(adapterTrace.completions == 1)

            currentAssignReasons = { "noseat", "seatsfull" }
            local noSeatExit, noSeatReason = ctx.exitPlayer(player)
            assert(noSeatExit == false and noSeatReason == "seatsfull")
            assert(#adapterTrace.assignIds == 4)
            assert(#adapterTrace.worldSquares == 0 and adapterTrace.teleports == 0)
            assert(adapterTrace.completions == 2)
            """
        )

    def test_cargo_exit_uses_server_last_known_then_acknowledges_floor_boarding(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            currentOwner = nil
            currentCut = true
            currentSpeed = 12
            currentKind = "car_bx40"
            mappingRecord.templateId = "railroader-rv-car-box"
            currentTrainLoaded = false
            currentLastKnownOverride = {
                x = 10.5, y = 20.5, z = 0, dirX = 1, dirY = 0,
                kind = "car_bx40", loaded = false,
            }
            local ctx = makeServerContext()
            assert(ctx.exitPlayer(player) == true)
            assert(#adapterTrace.lastKnownIds == 1
                and adapterTrace.lastKnownIds[1] == 201)
            assert(adapterTrace.lastKnownOuts[1] ~= nil)
            assert(adapterTrace.worldSquares[1] == nil)
            assert(teleportedPosition.x == 10.5 and teleportedPosition.y == 20.5)
            assert(adapterTrace.transitions == 1)
            assert(type(sentServerPayload.boardCarId) == "number"
                and sentServerPayload.boardCarId == 201)
            assert(#adapterTrace.assignIds == 0 and #adapterTrace.releaseIds == 0)
            assert(sentServerPayload.action == "exit-board")
            local token = sentServerPayload.boardToken
            assert(type(token) == "string" and token ~= "")
            assert(map.players.Alice.inside == true
                and mappingRecord.players.Alice.inside == true)
            assert(adapterTrace.utilitySettles == 0 and adapterTrace.clears == 0)

            local duplicate, duplicateReason = ctx.exitPlayer(player)
            assert(duplicate == false and duplicateReason ~= nil)
            assert(adapterTrace.transitions == 1)
            local reentry, reentryReason = ctx.enterPlayer(player, 101)
            assert(reentry == false
                and reentryReason == "RV cargo car boarding is already in progress")
            assert(adapterTrace.generationRequests == 0
                and #adapterTrace.assignIds == 0)

            -- The car streams and moves after the initial lastKnown teleport.
            -- The ACK is accepted against the current server RR floor point.
            currentTrainLoaded = true
            currentLastKnownOverride = {
                x = 35, y = 50, z = 0, dirX = 0, dirY = 1,
                kind = "car_bx40", loaded = true,
            }
            currentBoardPoint = { x = 35.25, y = 50.25, z = 0.46 }
            currentBoardPointReason = "notloaded"
            assert(ctx.acknowledgeExitBoarding(player, {
                boardToken = token, boarded = true,
            }) == true)
            assert(map.players.Alice.inside == true
                and adapterTrace.utilitySettles == 0)
            currentBoardPointReason = nil
            -- A positive client ACK alone is insufficient while the server
            -- still sees the pre-boarding player position.
            ctx.Adapter.processPendingExitBoardings(10)
            assert(map.players.Alice.inside == true
                and adapterTrace.utilitySettles == 0)
            playerX, playerY, playerZ = 35.25, 50.25, 0.46
            ctx.Adapter.processPendingExitBoardings(11)
            assert(adapterTrace.boardPointIds[1] == 201)
            assert(adapterTrace.lastKnownOuts[2] ~= adapterTrace.lastKnownOuts[1])
            assert(mappingRecord.locoPosition.x == 35
                and mappingRecord.locoPosition.y == 50)
            assert(map.players.Alice.inside == false
                and map.players.Alice.role == "external")
            assert(map.players.Alice.exitPosition.x == 35.25
                and map.players.Alice.exitPosition.y == 50.25
                and map.players.Alice.exitPosition.z == 0.46)
            assert(adapterTrace.utilitySettles == 1)
            assert(adapterTrace.clears == 1 and adapterTrace.completions == 0)
            assert(sentServerPayload.action == "exit-board-complete")
            """
        )

    def test_cargo_exit_timeout_and_disconnect_restore_server_origin(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            mappingRecord.templateId = "railroader-rv-car-box"
            currentTrainLoaded = false
            currentLastKnownOverride = {
                x = 10.5, y = 20.5, z = 0, dirX = 1, dirY = 0,
                kind = "car_box", loaded = false,
            }
            local ctx = makeServerContext()
            assert(ctx.exitPlayer(player) == true)
            local token = sentServerPayload.boardToken
            ctx.Adapter.processPendingExitBoardings(10)
            assert(adapterTrace.extensions == 1)
            assert(map.players.Alice.inside == true)
            ctx.Adapter.processPendingExitBoardings(600)
            assert(adapterTrace.completions == 1 and adapterTrace.clears == 0)
            assert(map.players.Alice.inside == true
                and mappingRecord.players.Alice.inside == true)
            assert(teleportedPosition.x == 10 and teleportedPosition.y == 20)
            assert(sentServerPayload.action == "exit-board-cancel")
            assert(sentServerPayload.boardToken == token)

            -- A disconnect before client boarding cancels the lease and restores
            -- the server-owned original RV position without a client ACK.
            currentTrainLoaded = false
            playerX, playerY, playerZ = 10, 20, 0
            assert(ctx.exitPlayer(player) == true)
            playerConnected = false
            ctx.Adapter.processPendingExitBoardings(601)
            assert(adapterTrace.completions == 2 and adapterTrace.clears == 0)
            assert(map.players.Alice.inside == true)
            assert(teleportedPosition.x == 10 and teleportedPosition.y == 20)
            """
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
