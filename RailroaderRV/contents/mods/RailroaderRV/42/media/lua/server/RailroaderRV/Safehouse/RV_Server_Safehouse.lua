-- Server authority for the RV cab's native rectangular safehouse.
-- Clients submit only the intent to claim; the server resolves the current RV.

local C = require("RailroaderRV/Common/RV_Constants")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local Store = require("RailroaderRV/Core/RV_UtilityStore")

local M = {}

local function playerOnlineId(player)
    return player and player:getOnlineID() or nil
end

local function sendRejection(player, reason)
    if player then
        sendServerCommand(player, C.MOD_ID, C.COMMAND_RV_SAFEHOUSE_RESULT, {
            onlineId = playerOnlineId(player), ok = false, reason = reason,
        })
    end
    return false, reason
end

local function validRequest(args)
    -- Project Zomboid omits empty argument tables from client-command packets,
    -- so a payload-free claim arrives here as nil.
    if args == nil then return true end
    if type(args) ~= "table" then return false end
    for _ in pairs(args) do return false end
    return true
end

local function waterUnavailableReason(water)
    if water.tankCount <= 0 then return "water-tanks-missing" end
    if not water.supplyPumpInstalled then return "water-pump-missing" end
    if not water.filter then return "water-filter-missing" end
    if not water.supplyPumpPowered then return "water-unpowered" end
    if water.filterRemainingL <= 0 then return "water-filter-exhausted" end
    return nil
end

local function claimCabSafehouse(player, record)
    local anchor = RegionSlots.indexToAnchor(record.slotIndex)
    local x, y, width, height = anchor.x - 4, anchor.y - 2, 6, 4
    if SafeHouse.getSafehouseOverlapping(x, y, x + width, y + height) ~= nil then
        return sendRejection(player, "safehouse-overlap")
    end

    local identity = {
        rvId = tostring(record.locoId), generation = record.generation,
    }
    local settled, recordOrReason = RailroaderRV.Server.settleRVUtilityLoad(
        identity, player, record)
    assert(settled == true,
        "RailroaderRV: utility load settlement did not return a record")
    local water = Store.snapshot(recordOrReason).water
    local unavailableReason = waterUnavailableReason(water)
    if unavailableReason then return sendRejection(player, unavailableReason) end

    local username = player:getUsername()
    SafeHouse.addSafeHouse(x, y, width, height, username)
    -- The native constructor derives onlineID from x/y on each peer; the
    -- geometry is the synchronization identity, never SafeHouse.getId().
    sendServerCommand(C.MOD_ID, C.COMMAND_RV_SAFEHOUSE_SYNC, {
        x = x, y = y, w = width, h = height, owner = username,
        onlineId = playerOnlineId(player),
    })
    return true
end

function M.handleClaim(player, args)
    if not validRequest(args) then
        return sendRejection(player, "invalid-request")
    end
    local adapter = RailroaderRV.RailroaderServer
    local accepted, recordOrReason = adapter.resolveSafehouseClaimTarget(player)
    if accepted ~= true then return sendRejection(player, recordOrReason) end
    return claimCabSafehouse(player, recordOrReason)
end

return M
