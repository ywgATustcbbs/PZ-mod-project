from __future__ import annotations

import json
import re
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
        "package.path = "
        + repr(f"{shared}/?.lua;{server}/?.lua;")
        + " .. package.path"
    )
    lua.execute(
        r"""
        SafeHouse = { entries = {} }
        function SafeHouse.getSafehouseOverlapping(x1, y1, x2, y2)
            for i = 1, #SafeHouse.entries do
                local entry = SafeHouse.entries[i]
                if x1 < entry.x + entry.w and x2 > entry.x
                    and y1 < entry.y + entry.h and y2 > entry.y then
                    return entry
                end
            end
            return nil
        end
        function SafeHouse.addSafeHouse(x, y, w, h, owner)
            local entry = { x = x, y = y, w = w, h = h, owner = owner }
            SafeHouse.entries[#SafeHouse.entries + 1] = entry
            return entry
        end
        C = require("RailroaderRV/Common/RV_Constants")
        RailroaderRV.Server = {
            settleRVUtilityLoad = function(identity, player, mappingRecord)
                settledIdentity = identity
                return true, fixtureRecord
            end,
        }
        RailroaderRV.RailroaderServer = {
            resolveSafehouseClaimTarget = function(targetPlayer)
                resolvedPlayer = targetPlayer
                if resolverReason then return false, resolverReason end
                return true, fixtureMappingRecord
            end,
        }
        serverCommands = {}
        function sendServerCommand(...)
            serverCommands[#serverCommands + 1] = { ... }
            return true
        end
        local water = {
            tankCount = 2,
            supplyPumpInstalled = true,
            filter = { condition = 1 },
            centralL = 0,
            roofCollectors = {},
            sinks = {},
        }
        fixtureRecord = {
            rvId = "loco-17",
            generation = 3,
            power = { circuitState = "ON", deviceCache = { build = {}, template = {} } },
            water = water,
        }
        fixtureMappingRecord = {
            locoId = "loco-17",
            generation = 3,
            slotIndex = 1,
            templateId = "railroader-rv",
        }
        player = {
            getOnlineID = function() return 41 end,
            getUsername = function() return "Alice" end,
        }
        generationBusy = false
        wallReloadBusy = false
        generationGateThrows = false
        wallGateThrows = false
        wallGateCalled = false
        RailroaderRV.Server.isGenerationTransactionActive = function()
            if generationGateThrows then error("generation gate failure") end
            return generationBusy
        end
        RailroaderRV.Server.isWallReloadTransactionActive = function(rvId)
            if wallGateThrows then error("wall gate failure") end
            wallGateCalled = true
            wallGateRVId = rvId
            return wallReloadBusy
        end
        SafehouseClaimModule = require(
            "RailroaderRV/Safehouse/RV_Server_Safehouse")
        """
    )
    return lua


def install_current_rv_resolver(lua: LuaRuntime) -> None:
    lua.execute(
        r"""
        local function engineEvent() return { Add = function() end } end
        Events = {
            OnTick = engineEvent(),
            OnClientCommand = engineEvent(),
            OnProcessAction = engineEvent(),
            OnObjectAdded = engineEvent(),
            OnObjectAboutToBeRemoved = engineEvent(),
            OnDestroyIsoThumpable = engineEvent(),
        }
        resolverRecordExists = true
        resolverLocomotiveSide = false
        resolverReason = nil
        local ctx = {
            C = C,
            Adapter = {},
            playerDead = function() return false end,
            playerId = function(value) return value:getOnlineID() end,
            playerName = function(value) return value:getUsername() end,
        }
        local factory = require(
            "RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit")
        factory(ctx)
        ctx.Adapter.resolveCurrentUtilityRV = function()
            if resolverReason then return false, resolverReason end
            if not resolverRecordExists then return false, "outside-rv" end
            return true, {
                record = fixtureMappingRecord,
                locomotiveSide = resolverLocomotiveSide,
            }
        end
        RailroaderRV.RailroaderServer = ctx.Adapter
        """
    )


def load_client_menu(lua: LuaRuntime) -> None:
    path = MOD / "client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua"
    lua.globals().client_menu_path = path.as_posix()
    lua.execute("ClientMenu = dofile(client_menu_path)")


class RVSafehouseClaimTests(unittest.TestCase):
    def test_native_rectangle_is_created_and_broadcast_with_owner(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local accepted = SafehouseClaimModule.handleClaim(player, {})
            assert(accepted == true)
            assert(#SafeHouse.entries == 1)
            local anchor = require("RailroaderRV/RVMapping/RV_RegionSlots").indexToAnchor(1)
            local house = SafeHouse.entries[1]
            assert(house.x == anchor.x - 4 and house.y == anchor.y - 2)
            assert(house.w == 6 and house.h == 4 and house.owner == "Alice")
            assert(house.x + house.w == anchor.x + 2)
            assert(house.y + house.h == anchor.y + 2)
            assert(resolvedPlayer == player)
            assert(settledIdentity.rvId == "loco-17" and settledIdentity.generation == 3)
            assert(#serverCommands == 1)
            local command = serverCommands[1]
            assert(command[1] == "RailroaderRV")
            assert(command[2] == C.COMMAND_RV_SAFEHOUSE_SYNC)
            assert(command[3].owner == "Alice" and command[3].onlineId == 41)
            assert(command[3].x == house.x and command[3].y == house.y)
            assert(command[3].w == 6 and command[3].h == 4)
            """
        )

    def test_zero_stored_water_does_not_block_an_available_system(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local accepted = SafehouseClaimModule.handleClaim(player, {})
            assert(accepted == true)
            assert(fixtureRecord.water.centralL == 0)
            assert(#SafeHouse.entries == 1)
            """
        )

    def test_each_unavailable_water_condition_has_a_specific_refusal(self) -> None:
        cases = [
            ("tankCount", 0, "water-tanks-missing"),
            ("supplyPumpInstalled", False, "water-pump-missing"),
            ("filter", None, "water-filter-missing"),
            ("filter", {"condition": 0}, "water-filter-exhausted"),
        ]
        for field, value, expected in cases:
            with self.subTest(reason=expected):
                lua = make_lua()
                lua.globals().failure_field = field
                lua.globals().failure_value = value
                lua.globals().expected_reason = expected
                lua.execute(
                    r"""
                    fixtureRecord.water[failure_field] = failure_value
                    if expected_reason == "water-filter-exhausted" then
                        fixtureRecord.water.filter.condition = 0
                    end
                    local accepted = SafehouseClaimModule.handleClaim(player, {})
                    assert(accepted == false)
                    assert(#SafeHouse.entries == 0)
                    assert(#serverCommands == 1)
                    assert(serverCommands[1][1] == player)
                    assert(serverCommands[1][4].reason == expected_reason)
                    """
                )

        lua = make_lua()
        lua.execute(
            r"""
            fixtureRecord.power.circuitState = "OFF"
            local accepted = SafehouseClaimModule.handleClaim(player, {})
            assert(accepted == false)
            assert(#SafeHouse.entries == 0)
            assert(serverCommands[1][4].reason == "water-unpowered")
            """
        )

    def test_overlapping_safehouse_and_bad_intent_do_not_create(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local anchor = require("RailroaderRV/RVMapping/RV_RegionSlots").indexToAnchor(1)
            SafeHouse.entries[1] = {
                x = anchor.x - 4, y = anchor.y - 2, w = 6, h = 4,
                owner = "SomeoneElse",
            }
            local accepted = SafehouseClaimModule.handleClaim(player, {})
            assert(accepted == false and #SafeHouse.entries == 1)
            assert(serverCommands[1][4].reason == "safehouse-overlap")
            """
        )

        lua = make_lua()
        lua.execute(
            r"""
            local accepted = SafehouseClaimModule.handleClaim(player, {
                locoId = "loco-17", x = 1, y = 2,
            })
            assert(accepted == false and #SafeHouse.entries == 0)
            assert(resolvedPlayer == nil)
            assert(serverCommands[1][4].reason == "invalid-request")
            """
        )

    def test_partial_overlap_is_rejected_but_edge_touch_is_allowed(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local anchor = require("RailroaderRV/RVMapping/RV_RegionSlots").indexToAnchor(1)
            SafeHouse.entries[1] = {
                x = anchor.x + 1, y = anchor.y - 1, w = 2, h = 1,
                owner = "SomeoneElse",
            }
            local accepted = SafehouseClaimModule.handleClaim(player, {})
            assert(accepted == false and #SafeHouse.entries == 1)
            assert(serverCommands[1][4].reason == "safehouse-overlap")
            assert(settledIdentity == nil)
            """
        )

        lua = make_lua()
        lua.execute(
            r"""
            local anchor = require("RailroaderRV/RVMapping/RV_RegionSlots").indexToAnchor(1)
            SafeHouse.entries[1] = {
                x = anchor.x + 2, y = anchor.y - 2, w = 2, h = 4,
                owner = "SomeoneElse",
            }
            local accepted = SafehouseClaimModule.handleClaim(player, {})
            assert(accepted == true and #SafeHouse.entries == 2)
            assert(serverCommands[1][2] == C.COMMAND_RV_SAFEHOUSE_SYNC)
            """
        )

    def test_authoritative_resolver_rejections_do_not_settle_or_create(self) -> None:
        cases = [
            ("outside-rv", 'resolverRecordExists = false', "outside-rv"),
            ("locomotive-side", 'resolverLocomotiveSide = true', "outside-rv"),
            ("permission-denied", 'resolverReason = "permission-denied"', "permission-denied"),
        ]
        for label, setup, expected in cases:
            with self.subTest(reason=label):
                lua = make_lua()
                install_current_rv_resolver(lua)
                lua.execute(
                    f"{setup}\n"
                    + r"""
                    local accepted = SafehouseClaimModule.handleClaim(player, {})
                    assert(accepted == false)
                    assert(#SafeHouse.entries == 0)
                    assert(settledIdentity == nil)
                    assert(#serverCommands == 1)
                    assert(serverCommands[1][4].reason == """
                    + repr(expected)
                    + r""")
                    """
                )

    def test_public_transaction_gates_reject_busy_and_expose_gate_errors(self) -> None:
        for label, setup in (
            ("generation-busy", "generationBusy = true"),
            ("wall-reload-busy", "wallReloadBusy = true"),
        ):
            with self.subTest(gate=label):
                lua = make_lua()
                install_current_rv_resolver(lua)
                lua.execute(
                    f"{setup}\n"
                    + r"""
                    local accepted, reason = SafehouseClaimModule.handleClaim(player, {})
                    assert(accepted == false and reason == "busy")
                    assert(#SafeHouse.entries == 0 and settledIdentity == nil)
                    assert(serverCommands[1][4].reason == "busy")
                    """
                )
                if label == "wall-reload-busy":
                    self.assertTrue(lua.globals().wallGateCalled)
                    self.assertEqual(lua.globals().wallGateRVId, None)

        for label, setup in (
            ("generation-gate-missing", "RailroaderRV.Server.isGenerationTransactionActive = nil"),
            ("wall-gate-missing", "RailroaderRV.Server.isWallReloadTransactionActive = nil"),
            ("generation-gate-throws", "generationGateThrows = true"),
            ("wall-gate-throws", "wallGateThrows = true"),
        ):
            with self.subTest(gate=label):
                lua = make_lua()
                install_current_rv_resolver(lua)
                lua.execute(
                    f"{setup}\n"
                    + r"""
                    local callOk, acceptedOrError = pcall(
                        SafehouseClaimModule.handleClaim, player, {})
                    assert(callOk == false)
                    assert(acceptedOrError ~= "busy")
                    assert(#SafeHouse.entries == 0 and settledIdentity == nil)
                    assert(#serverCommands == 0)
                    """
                )

    def test_client_menu_sends_intent_and_receives_native_rectangle(self) -> None:
        client = (MOD / "client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua").read_text(
            encoding="utf-8"
        )
        self.assertIn("C.COMMAND_RV_SAFEHOUSE_CLAIM", client)
        self.assertIn("C.COMMAND_RV_SAFEHOUSE_CLAIM, {})", client)
        self.assertIn("SafeHouse.addSafeHouse(args.x, args.y, args.w, args.h, args.owner)", client)
        self.assertIn("C.COMMAND_RV_SAFEHOUSE_SYNC", client)
        self.assertIn('["outside-rv"] = "UI_RailroaderRV_Safehouse_Reject_Inside"', client)
        self.assertIn('["permission-denied"] = "UI_RailroaderRV_Safehouse_Reject_Permission"', client)
        self.assertNotIn('["out-of-range"] =', client)

        adapter = (MOD / "server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua").read_text(
            encoding="utf-8"
        )
        resolver = re.search(
            r"function Adapter\.resolveSafehouseClaimTarget\(.*?\nend",
            adapter,
            flags=re.S,
        )
        self.assertIsNotNone(resolver)
        self.assertIn("server.isGenerationTransactionActive()", resolver.group(0))
        self.assertIn("server.isWallReloadTransactionActive(nil)", resolver.group(0))
        self.assertIn("Adapter.resolveCurrentUtilityRV(player)", resolver.group(0))
        self.assertIn("context.locomotiveSide == true", resolver.group(0))

        for path in (
            MOD / "shared/Translate/CN/ContextMenu.json",
            MOD / "shared/Translate/EN/ContextMenu.json",
            MOD / "shared/Translate/CN/UI.json",
            MOD / "shared/Translate/EN/UI.json",
        ):
            with self.subTest(path=path.name):
                json.loads(path.read_text(encoding="utf-8"))

        lua = make_lua()
        lua.execute(
            r"""
            Events = nil
            translations = {
                UI_RailroaderRV_Safehouse_Claimed = "localized claim success",
                UI_RailroaderRV_Safehouse_Reject_Power = "localized power refusal",
                UI_RailroaderRV_Safehouse_Reject_Inside = "must be inside",
                UI_RailroaderRV_Safehouse_Reject_Permission = "not permitted",
            }
            function getText(key) return translations[key] or key end
            function getTexture(path) return "texture:" .. path end
            activePlayer = {
                halo = nil,
                getOnlineID = function() return 41 end,
                getX = function() return 0 end,
                getY = function() return 0 end,
                getZ = function() return 0 end,
                isDead = function() return false end,
                setHaloNote = function(self, message, r, g, b, duration)
                    self.halo = { message = message, r = r, g = g, b = b,
                        duration = duration }
                end,
            }
            function getNumActivePlayers() return 1 end
            function getSpecificPlayer(playerNum)
                if playerNum == 0 then return activePlayer end
                return nil
            end
            function instanceof(_, className) return className == "IsoAnimal" end
            sentClientCommands = {}
            function sendClientCommand(...)
                sentClientCommands[#sentClientCommands + 1] = { ... }
            end
            """
        )
        load_client_menu(lua)
        lua.execute(
            r"""
            ClientMenu.OnServerCommand(C.MOD_ID, C.COMMAND_RV_SAFEHOUSE_SYNC, {
                x = 20046, y = 2048, w = 6, h = 4,
                owner = "Alice", onlineId = 41,
            })
            assert(#SafeHouse.entries == 1)
            assert(SafeHouse.entries[1].x == 20046
                and SafeHouse.entries[1].y == 2048)
            assert(SafeHouse.entries[1].w == 6 and SafeHouse.entries[1].h == 4)
            assert(SafeHouse.entries[1].owner == "Alice")
            assert(activePlayer.halo.message == "localized claim success")
            assert(activePlayer.halo.r == 100 and activePlayer.halo.g == 255)

            ClientMenu.OnServerCommand(C.MOD_ID, C.COMMAND_RV_SAFEHOUSE_RESULT, {
                ok = false, onlineId = 41, reason = "water-unpowered",
            })
            assert(activePlayer.halo.message == "localized power refusal")
            assert(activePlayer.halo.r == 255 and activePlayer.halo.g == 80)

            ClientMenu.OnServerCommand(C.MOD_ID, C.COMMAND_RV_SAFEHOUSE_RESULT, {
                ok = false, onlineId = 41, reason = "outside-rv",
            })
            assert(activePlayer.halo.message == "must be inside")

            ClientMenu.OnServerCommand(C.MOD_ID, C.COMMAND_RV_SAFEHOUSE_RESULT, {
                ok = false, onlineId = 41, reason = "permission-denied",
            })
            assert(activePlayer.halo.message == "not permitted")
            """
        )

    def test_locomotive_context_options_and_interior_claim(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local function makeEvent()
                local event = { handlers = {} }
                event.Add = function(callback)
                    event.handlers[#event.handlers + 1] = callback
                end
                event.Remove = function(callback)
                    for i = #event.handlers, 1, -1 do
                        if event.handlers[i] == callback then
                            table.remove(event.handlers, i)
                        end
                    end
                end
                return event
            end
            Events = {
                OnGameStart = makeEvent(),
                OnFillWorldObjectContextMenu = makeEvent(),
                OnPreFillWorldObjectContextMenu = makeEvent(),
                OnFillInventoryObjectContextMenu = makeEvent(),
                OnServerCommand = makeEvent(),
                OnConnected = makeEvent(),
                OnDisconnect = makeEvent(),
                OnTick = makeEvent(),
            }
            translations = {
                ContextMenu_RailroaderRV_Enter = "Enter RV",
                ContextMenu_RailroaderRV_Exit = "Exit RV",
                ContextMenu_RailroaderRV_ClaimSafehouse = "Claim RV Safehouse",
                ContextMenu_RailroaderRV_UtilityDashboard = "RV utility panel",
            }
            function getText(key) return translations[key] or key end
            function getTexture(path) return { path = path } end
            activePlayer = {
                playerNum = 0, x = 0, y = 0, z = 0,
                getPlayerNum = function(self) return self.playerNum end,
                getOnlineID = function() return 41 end,
                getX = function(self) return self.x end,
                getY = function(self) return self.y end,
                getZ = function(self) return self.z end,
                isDead = function() return false end,
            }
            function getPlayer() return activePlayer end
            function getSpecificPlayer(playerNum)
                if playerNum == activePlayer.playerNum then return activePlayer end
                return nil
            end
            function getNumActivePlayers() return 1 end
            function instanceof(_, className) return className == "IsoAnimal" end
            sentClientCommands = {}
            function sendClientCommand(...)
                sentClientCommands[#sentClientCommands + 1] = { ... }
            end
            testMarks = 0
            ISWorldObjectContextMenu = {
                setTest = function() testMarks = testMarks + 1 end,
            }

            menuPaused = false
            singleOffer = false
            nativeShowCount = 0
            nativeAnimalMenuCount = 0
            nativeWorldMenuCount = 0
            locomotive = {
                getAnimalType = function() return "rr_loco" end,
                getAnimalID = function() return "loco-17" end,
            }
            trainRecord = { animal = locomotive }
            nearestRecord = trainRecord
            nearestDistance = 1
            local nativeShowSeatMenu = function()
                nativeShowCount = nativeShowCount + 1
                if singleOffer or menuPaused then return false end
                return true
            end
            boardMenu = {
                addForAnimal = function(playerNum, context, animal, test)
                    if not nearestRecord or nearestDistance > 2 then return end
                    nativeAnimalMenuCount = nativeAnimalMenuCount + 1
                    if not test then
                        context:addOption("Native animal entry", nil, function() end)
                    end
                end,
                OnFill = function(_, context)
                    if not nearestRecord or nearestDistance > 2 then return end
                    nativeWorldMenuCount = nativeWorldMenuCount + 1
                    context:addOption("Native world entry", nil, function() end)
                end,
                showSeatMenu = nativeShowSeatMenu,
            }
            Events.OnFillWorldObjectContextMenu.Add(boardMenu.OnFill)
            originalAnimalMenu = boardMenu.addForAnimal
            originalShowSeatMenu = boardMenu.showSeatMenu
            RR = {
                Ride = {
                    current = nil,
                    MOUNT_REACH = 2,
                    nearestBoardable = function(reach)
                        assert(reach == 2)
                        if nearestRecord and nearestDistance <= reach then
                            return nearestRecord, nearestDistance
                        end
                        return nil
                    end,
                },
                BoardMenu = boardMenu,
            }

            package.loaded["RailroaderRV/GUI/RV_UtilityClient"] = {
                requestAddFuel = function() end,
                requestWaterConnection = function() end,
            }
            package.loaded["RailroaderRV/GUI/RV_UtilityDashboard"] = {
                show = function(player) dashboardPlayer = player end,
            }
            package.loaded["RailroaderRV/Water/RV_UtilityCatalog"] = {
                hasFluidContainer = function() return false end,
                hasSinkIdentity = function() return false end,
                isCurrentWaterSink = function() return false end,
                readSinkIdentity = function() return nil end,
                isWaterPipedDevice = function() return false end,
            }
            """
        )
        load_client_menu(lua)
        utility_menu_path = (
            MOD / "client/RailroaderRV/GUI/RV_UtilityContextMenu.lua"
        ).as_posix()
        lua.globals().utility_menu_path = utility_menu_path
        lua.execute("UtilityMenu = dofile(utility_menu_path)")
        lua.execute(
            r"""
            assert(RR.BoardMenu.showSeatMenu == originalShowSeatMenu)
            for _, callback in ipairs(Events.OnGameStart.handlers) do
                callback()
            end
            assert(RR.BoardMenu.addForAnimal ~= originalAnimalMenu)
            assert(RR.BoardMenu.rrRVRailroaderAnimalMenuWrapped)
            assert(RR.BoardMenu.showSeatMenu == originalShowSeatMenu)
            local function context()
                local value = { options = {} }
                function value:addOption(name, target, callback, ...)
                    local option = {
                        name = name, target = target, callback = callback,
                        args = { ... },
                    }
                    self.options[#self.options + 1] = option
                    return option
                end
                return value
            end
            local function countNamed(value, name)
                local count = 0
                for _, option in ipairs(value.options) do
                    if option.name == name then count = count + 1 end
                end
                return count
            end
            local function findNamed(value, name)
                for _, option in ipairs(value.options) do
                    if option.name == name then return option end
                end
                return nil
            end

            local officialWorldHookPreserved = false
            for _, callback in ipairs(Events.OnFillWorldObjectContextMenu.handlers) do
                if callback == RR.BoardMenu.OnFill then
                    officialWorldHookPreserved = true
                end
            end
            assert(officialWorldHookPreserved)

            local outsideTestContext = context()
            ClientMenu.OnPreFillWorldObjectContextMenu(0,
                outsideTestContext, { locomotive }, true)
            assert(#outsideTestContext.options == 0 and testMarks > 0)

            local outsideContext = context()
            for _, callback in ipairs(Events.OnPreFillWorldObjectContextMenu.handlers) do
                callback(0, outsideContext, { locomotive }, false)
            end
            for _, callback in ipairs(Events.OnFillWorldObjectContextMenu.handlers) do
                callback(0, outsideContext, { locomotive }, false)
            end
            RR.BoardMenu.addForAnimal(0, outsideContext, locomotive, false)
            assert(countNamed(outsideContext, "Enter RV") == 1)
            assert(countNamed(outsideContext, "RV utility panel") == 0)
            assert(countNamed(outsideContext, "Claim RV Safehouse") == 0)
            assert(countNamed(outsideContext, "Native world entry") == 1)
            assert(countNamed(outsideContext, "Native animal entry") == 1)
            local enter = findNamed(outsideContext, "Enter RV")
            assert(enter.iconTexture.path == "media/ui/RailroaderRV/enterrv.png")
            enter.callback(enter.target, enter.args[1])
            assert(sentClientCommands[1][1] == activePlayer)
            assert(sentClientCommands[1][2] == C.MOD_ID)
            assert(sentClientCommands[1][3] == C.COMMAND_RV_ENTER)
            assert(sentClientCommands[1][4].locoId == "loco-17")
            assert(nativeWorldMenuCount == 1 and nativeAnimalMenuCount == 1)

            singleOffer = true
            assert(RR.BoardMenu.showSeatMenu(trainRecord) == false)
            assert(nativeShowCount == 1)
            assert(RR.BoardMenu.showSeatMenu == originalShowSeatMenu)
            singleOffer = false
            menuPaused = true
            assert(RR.BoardMenu.showSeatMenu(trainRecord) == false)
            menuPaused = false

            assert(ClientMenu.acceptUtilityMapping({ ok = true, onlineId = 41,
                rvId = "rv-17", locoId = "loco-17", generation = 1 }))
            local generatedContext = context()
            for _, callback in ipairs(Events.OnPreFillWorldObjectContextMenu.handlers) do
                callback(0, generatedContext, { locomotive }, false)
            end
            for _, callback in ipairs(Events.OnFillWorldObjectContextMenu.handlers) do
                callback(0, generatedContext, { locomotive }, false)
            end
            RR.BoardMenu.addForAnimal(0, generatedContext, locomotive, false)
            assert(countNamed(generatedContext, "Enter RV") == 1)
            assert(countNamed(generatedContext, "RV utility panel") == 1)
            assert(countNamed(generatedContext, "Claim RV Safehouse") == 0)
            local dashboard = findNamed(generatedContext, "RV utility panel")
            assert(dashboard.iconTexture.path
                == "media/ui/RailroaderRV/managementpannel.png")
            dashboard.callback(dashboard.target)
            assert(dashboardPlayer == activePlayer)

            local otherLocomotive = {
                getAnimalType = function() return "rr_loco" end,
                getAnimalID = function() return "loco-18" end,
            }
            nearestRecord = { animal = otherLocomotive }
            nearestDistance = 1
            local otherTrainContext = context()
            ClientMenu.OnPreFillWorldObjectContextMenu(0,
                otherTrainContext, { otherLocomotive }, false)
            assert(countNamed(otherTrainContext, "Enter RV") == 1)
            assert(countNamed(otherTrainContext, "RV utility panel") == 0)
            assert(countNamed(otherTrainContext, "Claim RV Safehouse") == 0)

            nearestRecord = { animal = locomotive }
            nearestDistance = 3
            local farContext = context()
            ClientMenu.OnPreFillWorldObjectContextMenu(0,
                farContext, { locomotive }, false)
            ClientMenu.OnFillWorldObjectContextMenu(0,
                farContext, { locomotive }, false)
            RR.BoardMenu.addForAnimal(0, farContext, otherLocomotive, false)
            assert(countNamed(farContext, "Enter RV") == 0)
            assert(countNamed(farContext, "RV utility panel") == 0)

            local slots = require("RailroaderRV/RVMapping/RV_RegionSlots")
            local region = slots.indexToRegion(1)
            local anchor = slots.indexToAnchor(1)
            activePlayer.x = region.minX + 1
            activePlayer.y = region.minY + 1
            activePlayer.z = anchor.z + C.RV_MANAGED_MIN_Z_OFFSET
            nearestRecord = nil

            ClientMenu.clearUtilityMapping()
            local beforeGenerationContext = context()
            ClientMenu.OnPreFillWorldObjectContextMenu(0,
                beforeGenerationContext, {}, false)
            assert(#beforeGenerationContext.options == 1)
            assert(beforeGenerationContext.options[1].name == "Exit RV")
            UtilityMenu.onPreFillWorldObjectContextMenu(0,
                beforeGenerationContext, {}, false)
            assert(#beforeGenerationContext.options == 1)

            assert(ClientMenu.acceptUtilityMapping({ ok = true, onlineId = 41,
                rvId = "rv-17", locoId = "loco-17", generation = 1 }))
            local exitContext = context()
            ClientMenu.OnPreFillWorldObjectContextMenu(0, exitContext, {}, false)
            UtilityMenu.onPreFillWorldObjectContextMenu(0,
                exitContext, {}, false)
            assert(#exitContext.options == 3)
            local exit = findNamed(exitContext, "Exit RV")
            assert(exit.iconTexture.path == "media/ui/RailroaderRV/exitrv.png")
            exit.callback(exit.target)
            assert(sentClientCommands[#sentClientCommands][3] == C.COMMAND_RV_EXIT)
            local claim = findNamed(exitContext, "Claim RV Safehouse")
            claim.callback(claim.target)
            assert(sentClientCommands[#sentClientCommands][3]
                == C.COMMAND_RV_SAFEHOUSE_CLAIM)
            assert(next(sentClientCommands[#sentClientCommands][4]) == nil)

            local insideDashboardContext = context()
            UtilityMenu.onPreFillWorldObjectContextMenu(0,
                insideDashboardContext, {}, false)
            assert(#insideDashboardContext.options == 1)
            local insideDashboard = insideDashboardContext.options[1]
            assert(insideDashboard.name == "RV utility panel")
            assert(insideDashboard.iconTexture.path
                == "media/ui/RailroaderRV/managementpannel.png")
            insideDashboard.callback(insideDashboard.target)
            assert(dashboardPlayer == activePlayer)

            local filledContext = context()
            ClientMenu.OnFillWorldObjectContextMenu(0, filledContext, {}, false)
            assert(#filledContext.options == 2)

            local internalContext = context()
            for _, callback in ipairs(Events.OnPreFillWorldObjectContextMenu.handlers) do
                callback(0, internalContext, {}, false)
            end
            for _, callback in ipairs(Events.OnFillWorldObjectContextMenu.handlers) do
                callback(0, internalContext, {}, false)
            end
            assert(countNamed(internalContext, "Enter RV") == 0)
            assert(countNamed(internalContext, "RV utility panel") == 1)
            assert(countNamed(internalContext, "Claim RV Safehouse") == 1)
            """
        )


if __name__ == "__main__":
    unittest.main()
