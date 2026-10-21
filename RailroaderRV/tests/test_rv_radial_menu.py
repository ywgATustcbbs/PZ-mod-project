from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime

from test_rv_safehouse_claim import make_lua, load_client_menu


ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "contents/mods/RailroaderRV/42/media/lua"
CLIENT_MENU = (
    MOD / "client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua"
)


def make_radial_lua() -> LuaRuntime:
    lua = make_lua()
    lua.execute(
        r"""
        local function makeEvent()
            local event = { handlers = {} }
            event.Add = function(callback)
                event.handlers[#event.handlers + 1] = callback
            end
            return event
        end
        Events = {
            OnClickedAnimalForContext = makeEvent(),
            OnFillWorldObjectContextMenu = makeEvent(),
            OnPreFillWorldObjectContextMenu = makeEvent(),
            OnFillInventoryObjectContextMenu = makeEvent(),
            OnServerCommand = makeEvent(),
            OnConnected = makeEvent(),
            OnDisconnect = makeEvent(),
            OnTick = makeEvent(),
        }
        radialCallbacks = { board = {}, cab = {} }
        clientPosition = { x = 0, y = 0, z = 0 }
        boardCarReason = "unknown"
        boardCarResult = nil
        boardCarCalls = {}
        currentRole = "outside"
        currentMode = "singleplayer"
        publicTrains = { { id = "loco-17", speed = 0 } }
        unitViews = {
            { id = "loco-17", kind = "loco", isLocomotive = true,
                distance = 3, mountReachTiles = 2.25 },
        }
        package.loaded["RailroaderRV/RVMapping/RV_RailroaderUnits"] = {
            find = function(id)
                for _, unit in ipairs(unitViews) do
                    if tostring(unit.id) == tostring(id) then return unit end
                end
                return nil
            end,
            list = function() return unitViews end,
            geometry = function(unit)
                if unit.noPose then return nil, "nopose" end
                return {
                    hullDistanceTiles = unit.distance,
                    mountReachTiles = unit.mountReachTiles,
                }
            end,
        }
        RR = {
            API = {
                onBoardMenu = function(callback)
                    radialCallbacks.board[#radialCallbacks.board + 1] = callback
                end,
                onCabMenu = function(callback)
                    radialCallbacks.cab[#radialCallbacks.cab + 1] = callback
                end,
                trains = function() return publicTrains end,
                riderState = function(id, player)
                    riderLookup = { id = id, player = player }
                    if currentRole == nil then return nil end
                    return { role = currentRole }
                end,
                mode = function() return currentMode end,
                boardCar = function(id, player)
                    assert(type(id) == "number")
                    boardCarCalls[#boardCarCalls + 1] = {
                        id = id, player = player,
                        x = clientPosition.x, y = clientPosition.y,
                        z = clientPosition.z,
                    }
                    if boardCarReason then return nil, boardCarReason end
                    clientPosition = {
                        x = boardCarResult.x, y = boardCarResult.y,
                        z = boardCarResult.z,
                    }
                    return boardCarResult
                end,
            },
        }
        package.preload["Railroader/RR_API"] = function() return RR.API end
        package.loaded["RailroaderRV/Common/RV_UtilityConstants"] = {}
        package.loaded["RailroaderRV/RVMapping/RV_RegionSlots"] = {
            COUNT = 2,
            indexToRegion = function(index)
                if index == 1 then
                    return { minX = 20000, minY = 2000,
                        maxX = 20100, maxY = 2100 }
                end
                return { minX = 21900, minY = 2400,
                    maxX = 22000, maxY = 2500 }
            end,
            indexToAnchor = function() return { x = 20050, y = 2050, z = 0 } end,
        }
        activePlayer = {
            getOnlineID = function() return 41 end,
            getX = function() return clientPosition.x end,
            getY = function() return clientPosition.y end,
            getZ = function() return clientPosition.z end,
            isDead = function() return false end,
            teleportTo = function(self, x, y, z)
                clientPosition = { x = x, y = y, z = z }
            end,
        }
        function getSpecificPlayer(playerNum)
            if playerNum == 0 then return activePlayer end
            return nil
        end
        function getNumActivePlayers() return 1 end
        function getText(key)
            if key == "ContextMenu_RailroaderRV_Enter" then return "Enter RV" end
            if key == "ContextMenu_RailroaderRV_UtilityDashboard" then
                return "RV utility panel"
            end
            return key
        end
        function getTexture(path) return { path = path } end
        sentClientCommands = {}
        function sendClientCommand(...)
            sentClientCommands[#sentClientCommands + 1] = { ... }
        end
        dashboardCalls = {}
        RailroaderRV.UtilityContextMenu = {
            openDashboard = function(player)
                dashboardCalls[#dashboardCalls + 1] = player
            end,
        }
        package.loaded["RailroaderRV/GUI/RV_UtilityClient"] = {
            requestAddFuel = function() end,
            requestWaterConnection = function() end,
            getSnapshot = function() return nil end,
            mappingKey = function(value)
                if value == nil then return nil end
                return value.rvId .. ":" .. value.generation
            end,
            requestSnapshot = function() end,
        }
        function buildRadial(kind, train, player)
            local options = {}
            local hooks = radialCallbacks[kind]
            assert(#hooks == 1)
            hooks[1](train, player, function(label, icon, onSelect, arg)
                options[#options + 1] = {
                    name = label, icon = icon, onSelect = onSelect, arg = arg,
                }
            end)
            return options
        end
        function radialOption(options, name)
            for _, option in ipairs(options) do
                if option.name == name then return option end
            end
            return nil
        end
        function eventHas(event, callback)
            for _, registered in ipairs(event.handlers) do
                if registered == callback then return true end
            end
            return false
        end
        """
    )
    load_client_menu(lua)
    return lua


class RVRadialMenuTests(unittest.TestCase):
    def test_both_public_menus_follow_role_and_signed_speed(self) -> None:
        lua = make_radial_lua()
        lua.execute(
            r"""
            assert(#radialCallbacks.board == 1)
            assert(#radialCallbacks.cab == 1)
            local train = publicTrains[1]
            for _, kind in ipairs({ "board", "cab" }) do
                for _, role in ipairs({ "driver", "outside", "passenger" }) do
                    currentRole = role
                    for _, speed in ipairs({ 0.04, -0.04 }) do
                        train.speed = speed
                        local options = buildRadial(kind, train, activePlayer)
                        assert(radialOption(options, "Enter RV") ~= nil,
                            kind .. " hides entry for stopped " .. role)
                    end
                end

                currentRole = "driver"
                train.speed = 0.2
                assert(radialOption(buildRadial(kind, train, activePlayer),
                    "Enter RV") == nil)
                train.speed = -0.2
                assert(radialOption(buildRadial(kind, train, activePlayer),
                    "Enter RV") == nil)

                currentRole = "outside"
                train.speed = 0.2
                assert(radialOption(buildRadial(kind, train, activePlayer),
                    "Enter RV") == nil)
                train.speed = -0.2
                assert(radialOption(buildRadial(kind, train, activePlayer),
                    "Enter RV") == nil)

                currentRole = "passenger"
                train.speed = 0.2
                assert(radialOption(buildRadial(kind, train, activePlayer),
                    "Enter RV") ~= nil)
                train.speed = -0.2
                assert(radialOption(buildRadial(kind, train, activePlayer),
                    "Enter RV") ~= nil)
            end

            -- SP's driver-only exit seat rule does not hide a stopped entry
            -- option from an outside player.
            currentMode = "singleplayer"
            currentRole = "outside"
            train.speed = 0
            assert(radialOption(buildRadial("board", train, activePlayer),
                "Enter RV") ~= nil)
            """
        )

    def test_entry_selection_uses_current_api_train_and_callback_player(self) -> None:
        lua = make_radial_lua()
        lua.execute(
            r"""
            currentRole = "outside"
            publicTrains[1].speed = 0
            local train = publicTrains[1]
            local enter = radialOption(
                buildRadial("board", train, activePlayer), "Enter RV")
            assert(enter ~= nil)

            enter.onSelect("missing-train", activePlayer, enter.arg)
            assert(#sentClientCommands == 0)

            publicTrains = { { id = "loco-17", speed = -0.2 } }
            enter.onSelect("loco-17", activePlayer, enter.arg)
            assert(#sentClientCommands == 0)

            publicTrains = { { id = "loco-17", speed = -0.04 } }
            local callbackPlayer = { marker = "callback-player" }
            currentRole = "passenger"
            enter.onSelect("loco-17", callbackPlayer, enter.arg)
            assert(#sentClientCommands == 1)
            assert(sentClientCommands[1][1] == callbackPlayer)
            assert(sentClientCommands[1][2] == C.MOD_ID)
            assert(sentClientCommands[1][3] == C.COMMAND_RV_ENTER)
            assert(sentClientCommands[1][4].locoId == "loco-17")
            assert(riderLookup.id == "loco-17")
            assert(riderLookup.player == callbackPlayer)
            """
        )

    def test_dashboard_visibility_and_selection_recheck_mapping_for_both_menus(self) -> None:
        lua = make_radial_lua()
        lua.execute(
            r"""
            currentRole = "passenger"
            local train = publicTrains[1]
            train.speed = -0.2
            assert(ClientMenu.acceptUtilityMapping({ ok = true,
                onlineId = 41, rvId = "rv-1", locoId = "other-loco",
                generation = 1 }))
            for _, kind in ipairs({ "board", "cab" }) do
                local options = buildRadial(kind, train, activePlayer)
                assert(radialOption(options, "Enter RV") ~= nil)
                assert(radialOption(options, "RV utility panel") == nil)
            end

            assert(ClientMenu.acceptUtilityMapping({ ok = true,
                onlineId = 41, rvId = "rv-1", locoId = "loco-17",
                generation = 1 }))
            for _, kind in ipairs({ "board", "cab" }) do
                local options = buildRadial(kind, train, activePlayer)
                local dashboard = radialOption(options, "RV utility panel")
                assert(dashboard ~= nil)
                local callbackPlayer = { marker = kind }
                dashboard.onSelect("loco-17", callbackPlayer, dashboard.arg)
                assert(dashboardCalls[#dashboardCalls] == callbackPlayer)
            end
            assert(#dashboardCalls == 2)

            local options = buildRadial("cab", train, activePlayer)
            local dashboard = radialOption(options, "RV utility panel")
            assert(dashboard ~= nil)
            dashboard.onSelect("other-loco", activePlayer, dashboard.arg)
            assert(#dashboardCalls == 2)

            assert(ClientMenu.acceptUtilityMapping({ ok = true,
                onlineId = 41, rvId = "rv-1", locoId = "other-loco",
                generation = 2 }))
            dashboard.onSelect("loco-17", activePlayer, dashboard.arg)
            assert(#dashboardCalls == 2)
            """
        )

    def test_world_right_click_events_remain_and_radials_use_public_hooks(self) -> None:
        lua = make_radial_lua()
        lua.execute(
            r"""
            assert(eventHas(Events.OnClickedAnimalForContext,
                ClientMenu.OnClickedAnimalForContext))
            assert(eventHas(Events.OnFillWorldObjectContextMenu,
                ClientMenu.OnFillWorldObjectContextMenu))
            assert(eventHas(Events.OnPreFillWorldObjectContextMenu,
                ClientMenu.OnPreFillWorldObjectContextMenu))
            """
        )
        source = CLIENT_MENU.read_text(encoding="utf-8")
        self.assertIn('require("Railroader/RR_API")', source)
        self.assertIn("RR.API.onBoardMenu(addRailroaderRadialOptions)", source)
        self.assertIn("RR.API.onCabMenu(addRailroaderRadialOptions)", source)
        self.assertNotIn("RR.BoardMenu", source)
        self.assertNotIn("patchRailroaderAnimalMenu", source)

    def test_cargo_exit_waits_for_rr_load_boards_then_acknowledges(self) -> None:
        lua = make_radial_lua()
        lua.execute(
            r"""
            local token = "exit:rv-1:1:77:1"
            ClientMenu.OnServerCommand(C.MOD_ID, C.COMMAND_RV_TELEPORT, {
                ok = true, action = "exit-board", onlineId = 41,
                x = 50.5, y = 60.5, z = 0,
                boardCarId = 201, boardToken = token,
                rvId = "rv-1", locoId = "rv-1", generation = 1,
            })
            assert(clientPosition.x == 50.5 and clientPosition.y == 60.5)
            assert(ClientMenu.getUtilityMapping() == nil)

            -- RR reports both states while this restarted car streams in.
            boardCarReason = "unknown"
            ClientMenu.onTick()
            boardCarReason = "notloaded"
            ClientMenu.onTick()
            assert(#boardCarCalls == 2 and #sentClientCommands == 0)

            boardCarReason = nil
            boardCarResult = { x = 51.25, y = 61.25, z = 0.46 }
            ClientMenu.onTick()
            assert(#boardCarCalls == 3)
            assert(boardCarCalls[3].id == 201
                and boardCarCalls[3].player == activePlayer)
            assert(boardCarCalls[3].x == 50.5
                and boardCarCalls[3].y == 60.5)
            assert(clientPosition.x == 51.25 and clientPosition.z == 0.46)
            assert(#sentClientCommands == 1)
            local ack = sentClientCommands[1]
            assert(ack[3] == C.COMMAND_RV_EXIT)
            assert(ack[4].boardToken == token and ack[4].boarded == true)
            assert(ack[4].x == nil and ack[4].y == nil and ack[4].z == nil)

            ClientMenu.onTick()
            assert(#boardCarCalls == 3 and #sentClientCommands == 1)
            ClientMenu.OnServerCommand(C.MOD_ID, C.COMMAND_RV_TELEPORT, {
                ok = true, action = "exit-board-complete", onlineId = 41,
                boardToken = token, rvId = "rv-1", locoId = "rv-1",
                generation = 1,
            })
            assert(ClientMenu.getUtilityMapping().locoId == "rv-1")
            ClientMenu.onTick()
            assert(#boardCarCalls == 3 and #sentClientCommands == 1)

            -- A terminal API failure returns only after the server cancellation
            -- sends its trusted original RV position.
            ClientMenu.OnServerCommand(C.MOD_ID, C.COMMAND_RV_TELEPORT, {
                ok = true, action = "exit-board", onlineId = 41,
                x = 80, y = 90, z = 0,
                boardCarId = 202, boardToken = "exit:rv-2:1:77:2",
                rvId = "rv-2", locoId = "rv-2", generation = 1,
            })
            boardCarReason = "nointerior"
            ClientMenu.onTick()
            assert(#sentClientCommands == 2)
            assert(sentClientCommands[2][4].boardToken == "exit:rv-2:1:77:2")
            assert(sentClientCommands[2][4].boarded == false)
            ClientMenu.OnServerCommand(C.MOD_ID, C.COMMAND_RV_TELEPORT, {
                ok = true, action = "exit-board-cancel", onlineId = 41,
                x = 20050.5, y = 2050.5, z = 0,
                boardToken = "exit:rv-2:1:77:2",
            })
            assert(clientPosition.x == 20050.5 and clientPosition.y == 2050.5)
            assert(ClientMenu.getUtilityMapping().locoId == "rv-1")
            """
        )

    def test_disconnect_clears_pending_car_board_retry(self) -> None:
        lua = make_radial_lua()
        lua.execute(
            r"""
            ClientMenu.OnServerCommand(C.MOD_ID, C.COMMAND_RV_TELEPORT, {
                ok = true, action = "exit-board", onlineId = 41,
                x = 50, y = 60, z = 0, boardCarId = 201,
                boardToken = "exit:rv-1:1:77:1",
            })
            boardCarReason = "unknown"
            ClientMenu.onTick()
            assert(#boardCarCalls == 1 and #sentClientCommands == 0)

            for _, callback in ipairs(Events.OnDisconnect.handlers) do
                callback()
            end
            boardCarReason = nil
            boardCarResult = { x = 51, y = 61, z = 0.46 }
            ClientMenu.onTick()
            assert(#boardCarCalls == 1 and #sentClientCommands == 0)
            """
        )

    def test_cargo_context_targets_clicked_unit_and_nearest_unit_without_id_mismatch(self) -> None:
        lua = make_radial_lua()
        lua.execute(
            r"""
            publicTrains = { { id = "loco-17", speed = 0 } }
            unitViews = {
                { id = "loco-17", kind = "loco", isLocomotive = true,
                    distance = 1.75, mountReachTiles = 2.25 },
                { id = 201, kind = "car_box", isLocomotive = false,
                    locomotiveId = "loco-17", distance = 1.25 },
            }
            local clickedCar = {
                getAnimalID = function() return 201 end,
            }
            local function context()
                local value = { options = {} }
                function value:addOption(name, target, callback, ...)
                    local option = { name = name, target = target,
                        callback = callback, args = { ... } }
                    self.options[#self.options + 1] = option
                    return option
                end
                return value
            end
            local function find(value, name)
                for _, option in ipairs(value.options) do
                    if option.name == name then return option end
                end
                return nil
            end

            local clickedContext = context()
            assert(ClientMenu.OnClickedAnimalForContext(0, clickedContext,
                { clickedCar }, false))
            local clickedEnter = find(clickedContext, "Enter cargo car RV")
            assert(clickedEnter ~= nil and clickedEnter.args[1] == 201)
            clickedEnter.callback(clickedEnter.target, clickedEnter.args[1])
            assert(sentClientCommands[#sentClientCommands][4].locoId == 201)
            assert(next(sentClientCommands[#sentClientCommands][4]) == "locoId")

            local nearbyContext = context()
            ClientMenu.OnFillWorldObjectContextMenu(0, nearbyContext, {}, false)
            local nearestEnter = find(nearbyContext, "Enter cargo car RV")
            assert(nearestEnter ~= nil and nearestEnter.args[1] == 201)

            -- Cargo cars use the RV's explicit 2-tile mount reach.
            unitViews[2].distance = 2.01
            local outsideReach = context()
            assert(not ClientMenu.OnClickedAnimalForContext(0, outsideReach,
                { clickedCar }, false))
            assert(find(outsideReach, "Enter cargo car RV") == nil)

            -- Locomotive reach comes only from the public API result.
            unitViews = {
                { id = "loco-17", kind = "loco", isLocomotive = true,
                    distance = 0.25, mountReachTiles = nil },
            }
            local headWithoutReach = context()
            local clickedHead = {
                getAnimalID = function() return "loco-17" end,
            }
            assert(not ClientMenu.OnClickedAnimalForContext(0,
                headWithoutReach, { clickedHead }, false))
            assert(find(headWithoutReach, "Enter RV") == nil)
            """
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
