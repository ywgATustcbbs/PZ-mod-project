-- Server-authoritative canonical water ledger and native plumbing bridge.
--
-- canonicalTank is the only balance.  The hidden usage tank and one hidden
-- proxy per connected fixture are clean-water FluidContainer projections.
-- Clients submit intent only; every object, amount, identity and range is
-- resolved again on the server.

local C = require("RailroaderRV/RV_Constants")
local U = require("RailroaderRV/RV_UtilityConstants")
local Catalog = require("RailroaderRV/RV_UtilityCatalog")
local Store = require("RailroaderRV/RV_UtilityStore")
local Util = require("RailroaderRV/RV_ServerUtil")
local World = require("RailroaderRV/RV_ServerWorld")
local UtilitySprite = require("RailroaderRV/RV_UtilitySprite")

-- Register the isolated blueprint before any utility object can be constructed.
-- OnGameBoot retries this on manager rebuild; makeObject also gates creation
-- on the same postcondition immediately before the complete add packet.
UtilitySprite.install()

local M = {}
local runtimeObjects = {}
local runtimePlayers = {}
local accountingGuard = {}
local tokenSequence = 0
local pendingDetachedFixtures = {}
local fixtureSourceGone
local retireEntry
local removeObject
local objectAttached


local ctx = {
    C = C,
    U = U,
    Catalog = Catalog,
    Store = Store,
    Util = Util,
    World = World,
    UtilitySprite = UtilitySprite,
    M = M,
    runtimeObjects = runtimeObjects,
    runtimePlayers = runtimePlayers,
    accountingGuard = accountingGuard,
    tokenSequence = tokenSequence,
    pendingDetachedFixtures = pendingDetachedFixtures,
    fixtureSourceGone = fixtureSourceGone,
    retireEntry = retireEntry,
    removeObject = removeObject,
    objectAttached = objectAttached,
}

require("RailroaderRV/RV_UtilityWater_Objects")(ctx)
require("RailroaderRV/RV_UtilityWater_Ledger")(ctx)
require("RailroaderRV/RV_UtilityWater_Plumbing")(ctx)
require("RailroaderRV/RV_UtilityWater_Commands")(ctx)

return M
