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
        "package.path = "
        + repr(f"{shared}/?.lua;{server}/?.lua;")
        + " .. package.path"
    )
    lua.execute(
        r"""
        local constants = require("RailroaderRV/Common/RV_Constants")
        local function integer(value)
            local result = tonumber(value)
            if result == nil or math.floor(result) ~= result then return nil end
            return result
        end
        player = {
            getOnlineID = function() return 42 end,
            getUsername = function() return "Visitor" end,
            getX = function() return 0 end,
            getY = function() return 0 end,
            getZ = function() return 0 end,
        }
        function getNumActivePlayers() return 1 end
        function getSpecificPlayer(index)
            if index == 0 then return player end
            return nil
        end
        local train17 = {}
        local train18 = {}
        local records = {
            ["17"] = { locoId = "17", generation = 3, players = {} },
            ["18"] = { locoId = "18", generation = 5, players = {} },
        }
        map = { players = {}, locomotives = records }
        useInteriorPosition = false
        boundaryIdentity = nil
        local ctx = {
            C = constants,
            Adapter = {
                validateCurrentBoundaryPlayer = function(target, identity)
                    boundaryIdentity = identity
                    return {}, records["17"], map.players.Visitor
                end,
            },
            Boundary = {},
            playerId = function(target) return target:getOnlineID() end,
            playerName = function(target) return target:getUsername() end,
            playerDead = function() return false end,
            number = tonumber,
            integer = integer,
            call = function(target, method, ...)
                if target == nil or type(target[method]) ~= "function" then
                    return false, nil
                end
                return true, target[method](target, ...)
            end,
            mapData = function() return map end,
            recordForLoco = function(currentMap, id)
                return currentMap.locomotives[tostring(id)]
            end,
            recordAtPlayerCoordinate = function(currentMap)
                if useInteriorPosition then
                    return currentMap.locomotives["17"], "17", train17,
                        "active-mapped"
                end
                return nil, nil, nil, "outside-rv"
            end,
            findTrain = function(id)
                if tostring(id) == "17" then return train17 end
                if tostring(id) == "18" then return train18 end
                return nil
            end,
            trainPosition = function(target)
                return target and { x = 1, y = 1, z = 0 } or nil
            end,
            hullDistance = function(target, train)
                if train == train17 then return 1 end
                if train == train18 then return 0.5 end
                return nil
            end,
            playerRole = function() return "external" end,
        }
        local factory = require(
            "RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit")
        factory(ctx)
        resolver = ctx.Adapter.resolveCurrentUtilityRV
        """
    )
    return lua


class RVUtilityResolverTests(unittest.TestCase):
    def test_unassociated_visitor_resolves_nearest_mapped_locomotive(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local accepted, context = resolver(player)
            assert(accepted == true)
            assert(context.record == map.locomotives["18"])
            assert(context.identity.rvId == "18")
            assert(context.identity.generation == 5)
            assert(context.locomotiveSide == true)
            assert(context.locomotiveRole == "external")
            """
        )

    def test_server_mapping_candidate_enables_clicked_locomotive_dashboard(self) -> None:
        lua = make_lua()
        client = (
            MOD / "client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua"
        ).as_posix()
        lua.globals().client_menu_path = client
        lua.execute(
            r"""
            local accepted, context = resolver(player)
            assert(accepted == true)
            package.loaded["RailroaderRV/GUI/RV_UtilityClient"] = {
                getSnapshot = function() return nil end,
                mappingKey = function(value)
                    if value == nil then return nil end
                    return value.rvId .. ":" .. value.generation
                end,
                requestSnapshot = function() return true end,
            }
            ClientMenu = dofile(client_menu_path)
            assert(ClientMenu.acceptUtilityMapping({
                ok = true, onlineId = 42,
                rvId = context.identity.rvId,
                locoId = context.record.locoId,
                generation = context.identity.generation,
            }) == true)
            assert(ClientMenu.hasUtilityDashboardCandidate(
                player, false, "18") == true)
            assert(ClientMenu.hasUtilityDashboardCandidate(
                player, false, "17") == false)
            """
        )

    def test_previous_external_mapping_still_resolves_its_own_locomotive(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            map.players.Visitor = { locoId = "17", inside = false }
            map.locomotives["17"].players.Visitor = {
                locoId = "17", inside = false,
            }
            local accepted, context = resolver(player)
            assert(accepted == true)
            assert(context.record == map.locomotives["17"])
            assert(context.locomotiveSide == true)
            """
        )

    def test_enter_exit_reenter_resolves_and_validates_each_current_context(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local record = map.locomotives["17"]
            record.players.Visitor = { locoId = "17", inside = true }
            map.players.Visitor = { locoId = "17", inside = true }
            useInteriorPosition = true
            local entered, insideContext = resolver(player)
            assert(entered == true and insideContext.record == record)
            assert(boundaryIdentity.username == "Visitor")
            assert(boundaryIdentity.onlineId == 42)
            assert(boundaryIdentity.key == "42:Visitor")

            map.players.Visitor.inside = false
            record.players.Visitor.inside = false
            useInteriorPosition = false
            local exited, outsideContext = resolver(player)
            assert(exited == true and outsideContext.record == record)
            assert(outsideContext.locomotiveSide == true)

            map.players.Visitor.inside = true
            record.players.Visitor.inside = true
            useInteriorPosition = true
            local reentered, reenteredContext = resolver(player)
            assert(reentered == true and reenteredContext.record == record)
            assert(boundaryIdentity.key == "42:Visitor")
            """
        )


if __name__ == "__main__":
    unittest.main()
