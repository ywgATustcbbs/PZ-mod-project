from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "contents/mods/RailroaderRV/42/media/lua"


def make_lua() -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().lua_shared = (MOD / "shared").as_posix()
    lua.globals().lua_server = (MOD / "server").as_posix()
    lua.execute(
        "package.path = lua_shared .. '/?.lua;' .. lua_server .. '/?.lua;' "
        ".. package.path"
    )
    lua.execute(
        r"""
        local C = require("RailroaderRV/Common/RV_Constants")
        local function engineEvent() return { Add = function() end } end
        Events = {
            OnTick = engineEvent(),
            OnClientCommand = engineEvent(),
            OnProcessAction = engineEvent(),
            OnObjectAdded = engineEvent(),
            OnObjectAboutToBeRemoved = engineEvent(),
            OnDestroyIsoThumpable = engineEvent(),
        }
        RailroaderRV.Server = {
            generationBusy = false,
            wallReloadBusy = false,
            wallReloadChecks = 0,
            isGenerationTransactionActive = function()
                return RailroaderRV.Server.generationBusy
            end,
            isWallReloadTransactionActive = function(rvId)
                RailroaderRV.Server.wallReloadChecks =
                    RailroaderRV.Server.wallReloadChecks + 1
                checkedWallReloadRV = rvId
                return RailroaderRV.Server.wallReloadBusy
            end,
            settleRVUtilityLoad = function(identity, player, mappingRecord)
                settledIdentity = identity
                return true, fixtureUtilityRecord
            end,
        }
        fixtureRecord = {
            locoId = "loco-17",
            generation = 3,
            slotIndex = 1,
            players = {},
        }
        fixtureUtilityRecord = {
            rvId = "loco-17",
            generation = 3,
            power = { circuitState = "ON", deviceCache = { build = {}, template = {} } },
            water = {
                tankCount = 1,
                supplyPumpInstalled = true,
                filter = { condition = 1 },
                centralL = 0,
                sinks = {},
                roofCollectors = {},
            },
        }
        fixtureMap = {
            locomotives = { ["loco-17"] = fixtureRecord },
            players = {},
        }
        playerPositionMode = "inside"
        playerCoordinateChecks = 0
        trainNear = true
        resolverTrain = { position = { x = 10, y = 10, z = 0 } }
        player = {
            getOnlineID = function() return playerOnlineId end,
            getUsername = function() return playerUsername end,
        }
        playerOnlineId = 41
        playerUsername = "Alice"
        function setInside()
            playerPositionMode = "inside"
            local relation = { locoId = "loco-17", onlineId = 41, inside = true }
            fixtureMap.players.Alice = relation
            fixtureRecord.players.Alice = {
                locoId = "loco-17", onlineId = 41, inside = true,
            }
        end
        function setOutside()
            playerPositionMode = "outside"
            fixtureMap.players.Alice = nil
            fixtureRecord.players.Alice = nil
        end
        function setLocomotiveSide(role)
            playerPositionMode = "outside"
            local relation = {
                locoId = "loco-17", onlineId = 41, inside = false,
                role = role,
            }
            fixtureMap.players.Alice = relation
            fixtureRecord.players.Alice = {
                locoId = "loco-17", onlineId = 41, inside = false,
                role = role,
            }
        end
        setInside()

        SafeHouse = { entries = {} }
        function SafeHouse.getSafehouseOverlapping(x1, y1, x2, y2)
            for i = 1, #SafeHouse.entries do
                local house = SafeHouse.entries[i]
                if x1 < house.x + house.w and x2 > house.x
                    and y1 < house.y + house.h and y2 > house.y then
                    return house
                end
            end
            return nil
        end
        function SafeHouse.addSafeHouse(x, y, w, h, owner)
            local house = { x = x, y = y, w = w, h = h, owner = owner }
            SafeHouse.entries[#SafeHouse.entries + 1] = house
            return house
        end
        serverCommands = {}
        function sendServerCommand(...)
            serverCommands[#serverCommands + 1] = { ... }
            return true
        end

        local adapter = {}
        local ctx = {
            C = C,
            Adapter = adapter,
            playerDead = function() return false end,
            playerId = function(value) return value:getOnlineID() end,
            playerName = function(value) return value:getUsername() end,
            mapData = function() return fixtureMap end,
            recordForLoco = function(map, locoId)
                return map.locomotives[tostring(locoId)]
            end,
            recordAtPlayerCoordinate = function()
                playerCoordinateChecks = playerCoordinateChecks + 1
                if playerPositionMode == "inside" then
                    return fixtureRecord, "loco-17", resolverTrain, "active-mapped"
                end
                return nil, nil, nil, "outside-rv"
            end,
            validMappingRecord = function(record)
                return record == fixtureRecord
            end,
            findTrain = function() return resolverTrain end,
            trainPosition = function(train) return train and train.position end,
            hullDistance = function() return trainNear and 1 or 100 end,
            playerRole = function(_, onlineId)
                return "driver", 0
            end,
            number = function(value) return tonumber(value) end,
            integer = function(value) return tonumber(value) end,
        }
        function adapter.validateCurrentBoundaryPlayer(value)
            if playerPositionMode ~= "inside"
                or value:getOnlineID() ~= playerOnlineId
                or value:getUsername() ~= "Alice" then
                return nil
            end
            return nil, fixtureRecord, fixtureMap.players.Alice
        end
        local factory = require(
            "RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit")
        factory(ctx)
        RailroaderRV.RailroaderServer = adapter
        SafehouseClaimModule = require(
            "RailroaderRV/Safehouse/RV_Server_Safehouse")
        """
    )
    return lua


class RVSafehouseInteriorAuthorityTests(unittest.TestCase):
    def test_inside_player_resolves_current_rv_and_empty_intent_claims_cab(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local accepted, context = RailroaderRV.RailroaderServer
                .resolveCurrentUtilityRV(player)
            assert(accepted == true and context.phase == "READY")
            assert(context.authorized == true and context.locomotiveSide == false)
            assert(context.record == fixtureRecord)

            local claimed = SafehouseClaimModule.handleClaim(player, {})
            assert(claimed == true)
            assert(#SafeHouse.entries == 1)
            assert(SafeHouse.entries[1].owner == "Alice")
            assert(SafeHouse.entries[1].w == 6 and SafeHouse.entries[1].h == 4)
            assert(settledIdentity.rvId == "loco-17")
            assert(settledIdentity.generation == 3)
            assert(fixtureUtilityRecord.water.centralL == 0)
            """
        )

    def test_outside_player_is_rejected_by_authoritative_region_lookup(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            setOutside()
            local accepted, reason = RailroaderRV.RailroaderServer
                .resolveSafehouseClaimTarget(player)
            assert(accepted == false and reason == "outside-rv")
            local claimed, claimReason = SafehouseClaimModule.handleClaim(player, {})
            assert(claimed == false and claimReason == "outside-rv")
            assert(#SafeHouse.entries == 0)
            """
        )

    def test_locomotive_side_mapping_and_riding_are_not_claim_authority(self) -> None:
        for role in ("beside", "driver", "passenger"):
            with self.subTest(role=role):
                lua = make_lua()
                lua.globals().claim_role = role
                lua.execute(
                    r"""
                    setLocomotiveSide(claim_role)
                    local utilityAccepted, utilityContext = RailroaderRV.RailroaderServer
                        .resolveCurrentUtilityRV(player)
                    assert(utilityAccepted == true)
                    assert(utilityContext.locomotiveSide == true)
                    local accepted, reason = RailroaderRV.RailroaderServer
                        .resolveSafehouseClaimTarget(player)
                    assert(accepted == false and reason == "outside-rv")
                    assert(#SafeHouse.entries == 0)
                    """
                )

    def test_inside_relationship_mismatch_is_rejected(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            fixtureMap.players.Alice.inside = false
            local accepted, reason = RailroaderRV.RailroaderServer
                .resolveSafehouseClaimTarget(player)
            assert(accepted == false and reason == "permission-denied")
            assert(#SafeHouse.entries == 0)
            """
        )

    def test_generation_and_wall_reload_transactions_reject_before_resolution(self) -> None:
        for gate in ("generation", "wall"):
            with self.subTest(gate=gate):
                lua = make_lua()
                if gate == "generation":
                    lua.execute("RailroaderRV.Server.generationBusy = true")
                else:
                    lua.execute("RailroaderRV.Server.wallReloadBusy = true")
                lua.execute(
                    r"""
                    local accepted, reason = RailroaderRV.RailroaderServer
                        .resolveSafehouseClaimTarget(player)
                    assert(accepted == false and reason == "busy")
                    assert(RailroaderRV.Server.wallReloadChecks
                        == (RailroaderRV.Server.generationBusy and 0 or 1))
                    assert(playerCoordinateChecks == 0)
                    assert(#SafeHouse.entries == 0)
                    """
                )

    def test_nonempty_or_missing_intent_is_rejected(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            local accepted, reason = SafehouseClaimModule.handleClaim(player, {
                locoId = "client-selected-rv",
            })
            assert(accepted == false and reason == "invalid-request")
            assert(#SafeHouse.entries == 0)
            local missingAccepted, missingReason = SafehouseClaimModule
                .handleClaim(player, nil)
            assert(missingAccepted == false and missingReason == "invalid-request")
            """
        )

    def test_missing_player_identity_is_rejected(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            playerOnlineId = nil
            local identityAccepted, identityReason = RailroaderRV.RailroaderServer
                .resolveSafehouseClaimTarget(player)
            assert(identityAccepted == false and identityReason == "player-unavailable")
            assert(#SafeHouse.entries == 0)
            """
        )

    def test_water_and_safehouse_overlap_refusals_remain_authoritative(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            fixtureUtilityRecord.water.filter.condition = 0
            local waterAccepted, waterReason = SafehouseClaimModule
                .handleClaim(player, {})
            assert(waterAccepted == false and waterReason == "water-filter-exhausted")
            assert(#SafeHouse.entries == 0)

            fixtureUtilityRecord.water.filter.condition = 1
            local anchor = require("RailroaderRV/RVMapping/RV_RegionSlots")
                .indexToAnchor(1)
            SafeHouse.entries[1] = {
                x = anchor.x - 4, y = anchor.y - 2,
                w = 1, h = 1, owner = "SomeoneElse",
            }
            local overlapAccepted, overlapReason = SafehouseClaimModule
                .handleClaim(player, {})
            assert(overlapAccepted == false and overlapReason == "safehouse-overlap")
            assert(#SafeHouse.entries == 1)
            """
        )


if __name__ == "__main__":
    unittest.main()
