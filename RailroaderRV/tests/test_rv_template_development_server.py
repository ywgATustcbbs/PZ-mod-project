from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "contents/mods/RailroaderRV/42/media/lua"


class TemplateDevelopmentServerTests(unittest.TestCase):
    def test_real_command_flow_builder_and_save_log(self) -> None:
        lua = LuaRuntime(unpack_returned_tuples=True)
        shared = (MOD / "shared").as_posix()
        server = (MOD / "server").as_posix()
        lua.execute(
            "package.path = "
            + repr(f"{server}/?.lua;{shared}/?.lua;")
            + " .. package.path"
        )
        lua.execute(
            r'''
            local logs = {}
            print = function(...) logs[#logs + 1] = table.concat({...}, " ") end
            SandboxVars = { RailroaderRV = { AllowEngineAreaBuilding = false } }
            IsoDirections = { N = {}, W = {} }
            instanceof = function(object, className)
                return object ~= nil and object.class == className
            end

            local function collection(items)
                return {
                    size = function() return #items end,
                    get = function(_, index) return items[index + 1] end,
                }
            end

            local square = { objects = {}, floor = nil }
            local activeSquare = square
            function square:getObjects() return collection(self.objects) end
            function square:getSpecialObjects() return collection({}) end
            function square:getStaticMovingObjects() return collection({}) end
            function square:getMovingObjects() return collection({}) end
            function square:getWorldObjects() return collection({}) end
            function square:getDeadBodys() return collection({}) end
            function square:getCorpses() return collection({}) end
            function square:getFloor() return self.floor end
            function square:getCorpse() return nil end
            function square:getDeadBody() return nil end
            function square:getVehicleContainer() return nil end
            function square:addFloor(spriteName)
                local sprite = { name = spriteName }
                function sprite:getName() return self.name end
                local floor = { class = "IsoObject", data = {}, sprite = sprite }
                function floor:getClass() return "class zombie.iso.objects.IsoObject" end
                function floor:getModData() return self.data end
                function floor:getSprite() return self.sprite end
                function floor:getName() return self.name end
                function floor:setName(value) self.name = value; return true end
                function floor:getDir() return self.direction end
                function floor:setDir(value) self.direction = value; return true end
                function floor:setSprite(value)
                    if type(value) == "table" then self.sprite = value
                    else self.sprite = { name = value, getName = function(o) return o.name end } end
                    return true
                end
                function floor:transmitCompleteItemToClients() return true end
                function floor:getNorth() return nil end
                function floor:isHoppable() return self.hoppable == true end
                self.floor = floor
                return true
            end
            function square:RecalcProperties() end
            function square:RecalcAllWithNeighbours(_) end

            local cell = {}
            local targetX, targetY, targetZ
            function cell:getGridSquare(x, y, z)
                if x == targetX and y == targetY and z == targetZ then
                    return activeSquare
                end
                return nil
            end
            local player = { x = 123.5, y = 456.5, z = 0 }
            function player:getCell() return cell end
            function player:getX() return self.x end
            function player:getY() return self.y end
            function player:getZ() return self.z end
            function player:getOnlineID() return 12 end
            function player:getUsername() return "template-author" end
            function player:isDead() return false end

            getWorld = function()
                return { isValidSquare = function() return true end }
            end

            local Constants = require("RailroaderRV/Common/RV_Constants")
            local ServerUtil = require("RailroaderRV/Common/RV_ServerUtil")
            local ServerWorld = require("RailroaderRV/Common/RV_ServerWorld")
            local ServerSchema = require("RailroaderRV/Common/RV_ServerSchema")
            ServerSchema.targetAreaLoadStatus = function() return true end
            local GenerationTransaction = require(
                "RailroaderRV/Construction/RV_Server_GenerationTransaction")()
            local boundaryTrace = { began = 0, completed = 0 }
            local registeredTick
            local Boundary = {
                beginTransition = function()
                    boundaryTrace.began = boundaryTrace.began + 1
                    return true
                end,
                completeTransition = function(_, _)
                    boundaryTrace.completed = boundaryTrace.completed + 1
                    return true
                end,
                clearPlayer = function() return true end,
                onTick = function() end,
                onProcessAction = function() end,
                onObjectAdded = function() end,
            }
            local guardCalls, mappingCalls, proxyCalls, tagCalls = 0, 0, 0, 0
            local RV = {
                Server = {
                    isWallReloadTransactionActive = function() return false end,
                },
                RailroaderServer = {
                    installWallReload = function() return true end,
                    installTransactionGate = function() return true end,
                    installTransactionHooks = function() return true end,
                },
            }
            local ctx = {
                OWNER = Constants.MOD_ID,
                COMMAND_MODULE = Constants.MOD_ID,
                COMMAND = Constants.COMMAND_GENERATE,
                COMMAND_RELOCATE_ACK = "RelocateAck",
                COMMAND_FINAL_RELOCATE_ACK = Constants.COMMAND_FINAL_RELOCATE_ACK,
                COMMAND_RV_ENTER = Constants.COMMAND_RV_ENTER,
                COMMAND_RV_EXIT = Constants.COMMAND_RV_EXIT,
                Constants = Constants,
                Core = {
                    onCommand = function(name, callback)
                        registeredCommandName = name
                        registeredCommand = callback
                    end,
                    onTick = function(callback) registeredTick = callback end,
                    on = function() end,
                },
                GenerationTransaction = GenerationTransaction,
                Boundary = Boundary,
                RV = RV,
                ServerUtil = ServerUtil,
                ServerWorld = ServerWorld,
                ServerSchema = ServerSchema,
                UtilityServer = { onTick = function() end },
                pendingSerial = 0,
                serverTick = 10,
                roomOwnershipGuards = {},
                RELOCATION_TIMEOUT_TICKS = 600,
                safeErrorText = tostring,
                notifyFailure = function() error("unexpected user notification") end,
                requestRoomOwnershipScan = function() end,
                requestRoomOwnershipRemovalScan = function() end,
                processServerRoomOwnershipGuards = function() end,
                keepGenerationTransitionAlive = function() end,
                playerIsAtStagingDestination = nil,
                validateAuthoritativePlayer = function(value)
                    return true, { x = value.x, y = value.y, z = value.z }
                end,
                authoritativePlayerPosition = function(value)
                    return true, { x = value.x, y = value.y, z = value.z }
                end,
                validateGenerationPermission = function() return true end,
                playerIdentity = function()
                    return true, { key = "player:12", onlineId = 12 }
                end,
                generationPositionProof = function(value, target)
                    return value.x == target.x and value.y == target.y
                        and value.z == target.z, "position"
                end,
                sendStagingRelocation = function(record)
                    stagedRecord = record
                    return true
                end,
                sendFinalRelocation = function(record)
                    finalRecord = record
                    return true
                end,
                resolvePendingPlayer = function(record)
                    return true, record.player
                end,
                refreshServerRoomOwnershipGuard = function()
                    guardCalls = guardCalls + 1
                    error("development mode must not install production room guards")
                end,
                registerServerRoomOwnershipGuard = function()
                    guardCalls = guardCalls + 1
                    error("development mode must not install production room guards")
                end,
                refreshGenerationRoomOwnershipGuard = function()
                    guardCalls = guardCalls + 1
                    error("development mode must not refresh production room guards")
                end,
                armClientRoomOwnershipGuard = function()
                    guardCalls = guardCalls + 1
                    error("development mode must not arm production room guards")
                end,
                railroaderCommitHook = function()
                    mappingCalls = mappingCalls + 1
                    error("development mode must not commit a production mapping")
                end,
                railroaderFailureHook = function() end,
                transitionSequence = 0,
                serverTick = 10,
            }
            local ServerWorldTagObject = ServerWorld.tagObject
            ServerWorld.tagObject = function(...)
                tagCalls = tagCalls + 1
                return ServerWorldTagObject(...)
            end

            package.preload["RailroaderRV/Core/RV_Server_ClientDebug"] =
                function() return { handle = function() return true end } end
            package.preload["RailroaderRV/WallReloadProtection/RV_WallReloadProtection"] =
                function()
                    return {
                        acknowledge = function() return false end,
                        onTick = function() end,
                    }
                end
            package.preload["RailroaderRV/CarVisual/RV_FlatcarVisualServer"] =
                function()
                    return function()
                        return { handle = function() return true end }
                    end
                end

            require("RailroaderRV/Construction/RV_Server_WorldObjects")(ctx)
            ctx.createGenerator = function(...)
                proxyCalls = proxyCalls + 1
                return true
            end
            ctx.createWaterProxy = function(...)
                proxyCalls = proxyCalls + 1
                return true
            end
            require("RailroaderRV/Construction/RV_Server_GenerationBuild")(ctx)
            require("RailroaderRV/Construction/RV_Server_GenerationFlow")(ctx)
            require("RailroaderRV/Construction/RV_Server_GenerationAck")(ctx)
            require("RailroaderRV/Core/RV_Server_Commands")(ctx)

            assert(registeredCommandName == "*")
            assert(Constants.ENABLE_TEMPLATE_DEVELOPMENT == false)
            RV.Server.OnClientCommand(Constants.MOD_ID,
                Constants.COMMAND_RV_TEMPLATE_DEVELOPMENT, player, {
                    operation = "new", kind = "car_cb",
                    northSouthLength = 23, eastWestWidth = 6,
                })
            RV.Server.OnClientCommand(Constants.MOD_ID,
                Constants.COMMAND_DUMP_TEMPLATE_CAPTURE, player, {})
            assert(GenerationTransaction.current() == nil)
            local disabledLog = table.concat(logs, "\n")
            assert(string.find(disabledLog,
                "template-development-disabled", 1, true))

            Constants.ENABLE_TEMPLATE_DEVELOPMENT = true
            RV.Server.OnClientCommand(Constants.MOD_ID,
                Constants.COMMAND_RV_TEMPLATE_DEVELOPMENT, player, {
                    operation = "new", kind = "car_cb",
                    northSouthLength = 23, eastWestWidth = 6,
                })
            local customRecord = GenerationTransaction.current()
            assert(customRecord ~= nil
                and customRecord.layout.templateId == "railroader-rv-caboose"
                and #customRecord.layout.templateObjects == 23 * 6)
            assert(customRecord.layout.room.maxY
                - customRecord.layout.room.minY + 1 == 23)
            assert(customRecord.layout.room.maxX
                - customRecord.layout.room.minX + 1 == 6)
            GenerationTransaction.release()

            RV.Server.OnClientCommand(Constants.MOD_ID,
                Constants.COMMAND_RV_TEMPLATE_DEVELOPMENT, player, {
                    operation = "new", kind = "car_box",
                    northSouthLength = 1, eastWestWidth = 1,
                    x = 999999, y = 999999, z = 30,
                })
            local record = GenerationTransaction.current()
            assert(record ~= nil and record.mode == "template-development")
            assert(record.slotIndex == nil and record.railroader == nil)
            assert(record.layout.templateId == "railroader-rv-car-box")
            assert(record.anchor.x == 150 and record.anchor.y == 450)
            assert(record.bounds.managedWidth == 100
                and record.bounds.managedHeight == 100)
            assert(boundaryTrace.began >= 1)
            assert(stagedRecord == record and record.stage == "WAIT_STAGING")

            targetX, targetY, targetZ = record.anchor.x, record.anchor.y,
                record.anchor.z
            player.x, player.y, player.z = record.stagingDestination.x,
                record.stagingDestination.y, record.stagingDestination.z
            RV.Server.OnClientCommand(Constants.MOD_ID, "RelocateAck", player,
                { token = record.token })
            assert(record.stagingAcked == true)
            registeredTick(11)
            assert(record.stage == "WAIT_FINAL" and finalRecord == record)
            assert(square.floor ~= nil and square.floor.data.RailroaderRV == nil)
            assert(tagCalls == 0 and proxyCalls == 0 and guardCalls == 0)

            player.x, player.y, player.z = record.finalDestination.x,
                record.finalDestination.y, record.finalDestination.z
            RV.Server.OnClientCommand(Constants.MOD_ID,
                Constants.COMMAND_FINAL_RELOCATE_ACK, player,
                { token = record.token })
            assert(record.finalAcked == true)
            registeredTick(12)
            assert(record.stage == "DONE" and boundaryTrace.completed == 1)
            assert(mappingCalls == 0 and GenerationTransaction.current() == nil)

            player.x, player.y, player.z = 123.5, 456.5, 0
            targetX, targetY, targetZ = 150, 450, 0
            local object = { class = "IsoThumpable", name = "Editor Wall" }
            function object:getClass() return "class zombie.iso.objects.IsoThumpable" end
            function object:getName() return self.name end
            function object:getNorth() return false end
            function object:getDir() return IsoDirections.W end
            function object:getSprite()
                return { getName = function() return "walls_interior_house_02_35" end }
            end
            function object:getObjectName() return self.name end
            table.insert(square.objects, object)

            RV.Server.OnClientCommand(Constants.MOD_ID,
                Constants.COMMAND_RV_TEMPLATE_DEVELOPMENT, player, {
                    operation = "save", kind = "car_cb",
                    walkAabbs = { "should not be logged" },
                    buildCells = { "should not be logged" },
                })
            local logText = table.concat(logs, "\n")
            assert(string.find(logText, "save kind=car_cb templateId=railroader-rv-caboose", 1, true))
            assert(string.find(logText, "origin=150,450,0", 1, true))
            assert(string.find(logText, "rel=0,0,0", 1, true))
            assert(string.find(logText, "north=false", 1, true))
            assert(string.find(logText, "Editor Wall", 1, true))
            assert(not string.find(logText, "walkAabbs", 1, true))
            assert(not string.find(logText, "buildCells", 1, true))
            assert(not string.find(logText, "walkable", 1, true))
            assert(not string.find(logText, "buildable", 1, true))
            assert(GenerationTransaction.current() == nil)

            local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
            player.x, player.y, player.z = 123.5, 456.5, 0
            RV.Server.OnClientCommand(Constants.MOD_ID,
                Constants.COMMAND_RV_TEMPLATE_DEVELOPMENT, player, {
                    operation = "edit", kind = "car_bx40",
                })
            local editRecord = GenerationTransaction.current()
            assert(editRecord ~= nil
                and editRecord.mode == "template-development")
            assert(editRecord.layout.templateId
                == RoomTemplate.CAR_BOX_TEMPLATE_ID)
            local carBoxTemplate = RoomTemplate.get(
                RoomTemplate.CAR_BOX_TEMPLATE_ID)
            local locomotiveTemplate = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
            assert(#carBoxTemplate.objects == 329
                and #locomotiveTemplate.objects == 365)
            assert(carBoxTemplate.objects[1].sprite == "industry_railroad_05_38")
            assert(locomotiveTemplate.objects[1].sprite
                ~= carBoxTemplate.objects[1].sprite)
            assert(#editRecord.layout.templateObjects == 329)
            local editedSourceEntry = editRecord.layout.templateObjects[1]
            assert(editedSourceEntry.class == "IsoObject"
                and editedSourceEntry.name == "Floor"
                and editedSourceEntry.sprite == "industry_railroad_05_38")

            -- Keep the registry selection assertion above over the complete
            -- existing template. Restrict this harness build to its first real
            -- compiled object so the test exercises the edit transaction and
            -- object factory without emulating every native PZ object class.
            editRecord.layout.templateObjects = { editedSourceEntry }
            editRecord.bounds.wallCoordinates = {}
            square.floor = nil
            square.objects = {}
            targetX, targetY, targetZ = editedSourceEntry.x,
                editedSourceEntry.y, editedSourceEntry.z
            player.x, player.y, player.z = editRecord.stagingDestination.x,
                editRecord.stagingDestination.y, editRecord.stagingDestination.z
            RV.Server.OnClientCommand(Constants.MOD_ID, "RelocateAck", player,
                { token = editRecord.token })
            registeredTick(13)
            assert(editRecord.stage == "WAIT_FINAL")
            assert(square.floor ~= nil and square.floor.name == "Floor")
            assert(square.floor.sprite.name == "industry_railroad_05_38")
            assert(square.floor:isHoppable() == false)
            assert(square.floor.data.RailroaderRV == nil)
            assert(tagCalls == 0 and proxyCalls == 0 and guardCalls == 0)
            player.x, player.y, player.z = editRecord.finalDestination.x,
                editRecord.finalDestination.y, editRecord.finalDestination.z
            RV.Server.OnClientCommand(Constants.MOD_ID,
                Constants.COMMAND_FINAL_RELOCATE_ACK, player,
                { token = editRecord.token })
            registeredTick(14)
            assert(editRecord.stage == "DONE"
                and GenerationTransaction.current() == nil)

            -- Exercise the production builder with the same registered object
            -- entry. Its explicit mode must reach the real object factory and
            -- preserve the production identity tag.
            local productionSquare = {}
            for key, value in pairs(square) do productionSquare[key] = value end
            productionSquare.objects = {}
            productionSquare.floor = nil
            activeSquare = productionSquare
            targetX, targetY, targetZ = editedSourceEntry.x,
                editedSourceEntry.y, editedSourceEntry.z
            local productionLayout = {
                templateId = RoomTemplate.CAR_BOX_TEMPLATE_ID,
                templateObjects = { editedSourceEntry },
                powerProxy = { x = targetX, y = targetY, z = targetZ },
                waterProxies = {},
            }
            local productionRecord = {
                player = player, generation = 9001, rvId = "production-test-rv",
                layout = productionLayout,
            }
            GenerationTransaction.begin(player, productionRecord)
            ctx.buildGeneration(player, productionLayout, {
                roomMinX = targetX + 1, roomMaxX = targetX,
                roomMinY = targetY + 1, roomMaxY = targetY,
                z = targetZ, wallCoordinates = {},
            }, 9001, "production")
            local productionTag = productionSquare.floor.data.RailroaderRV
            assert(productionTag.owner == Constants.MOD_ID)
            assert(productionTag.rvId == "production-test-rv")
            assert(productionTag.templateId == RoomTemplate.CAR_BOX_TEMPLATE_ID)
            assert(productionTag.role == "captured-template")
            assert(productionTag.templateIndex == editedSourceEntry.templateIndex)
            assert(tagCalls == 1 and proxyCalls > 0)
            GenerationTransaction.release()
            assert(GenerationTransaction.current() == nil)

            assert(RoomTemplate.templateIdForKind("loco", false)
                == RoomTemplate.TEMPLATE_ID)
            assert(RoomTemplate.templateIdForKind("loco", true)
                == RoomTemplate.ENGINE_AREA_TEMPLATE_ID)
            assert(RoomTemplate.templateIdForKind("car_box", false)
                == RoomTemplate.CAR_BOX_TEMPLATE_ID)
            assert(RoomTemplate.templateIdForKind("car_bx40", false)
                == RoomTemplate.CAR_BOX_TEMPLATE_ID)
            assert(RoomTemplate.templateIdForKind("car_cb", false)
                == RoomTemplate.CAR_CABOOSE_TEMPLATE_ID)
            assert(RoomTemplate.templateIdForDevelopmentKind("car_cb", false)
                == RoomTemplate.CAR_CABOOSE_TEMPLATE_ID)
            '''
        )


if __name__ == "__main__":
    unittest.main()
