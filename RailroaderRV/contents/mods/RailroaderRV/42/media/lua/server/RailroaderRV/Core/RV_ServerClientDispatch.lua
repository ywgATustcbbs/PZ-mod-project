-- Dispatch client instructions through the native network path in multiplayer
-- and the owning client command handlers in singleplayer.
local C = require("RailroaderRV/Common/RV_Constants")
local ServerUtil = require("RailroaderRV/Common/RV_ServerUtil")

local M = {}

local function dispatchLocal(module, command, args)
    if command == "Relocate" or command == C.COMMAND_FINAL_RELOCATE
        or command == C.COMMAND_REFRESH_ROOM_OWNERSHIP then
        RailroaderRV.Client.onServerCommand(module, command, args)
    elseif command == C.COMMAND_RV_TELEPORT
        or command == C.COMMAND_RV_SAFEHOUSE_RESULT
        or command == C.COMMAND_RV_SAFEHOUSE_SYNC then
        RailroaderRV.RailroaderContextMenu.OnServerCommand(
            module, command, args)
    elseif command == C.COMMAND_RV_FLATCAR_SYNC
        or command == C.COMMAND_RV_FLATCAR_NOTICE then
        RailroaderRV.FlatcarVisualClient.onServerCommand(
            module, command, args)
    elseif command == C.COMMAND_RV_BOUNDARY_CORRECTION then
        RailroaderRV.BoundaryClient.onServerCommand(module, command, args)
    elseif command == C.COMMAND_RV_UTILITY_ACK then
        RailroaderRV.UtilityClient.onServerCommand(module, command, args)
    elseif command == C.COMMAND_RV_UTILITY_SNAPSHOT
        or command == C.COMMAND_RV_UTILITY_MAPPING then
        RailroaderRV.UtilityClient.onServerCommand(module, command, args)
        RailroaderRV.RailroaderContextMenu.OnServerCommand(
            module, command, args)
    end
end

function M.sendToPlayer(player, module, command, args)
    if isMultiplayer() then
        return ServerUtil.callGlobalSucceeded("sendServerCommand", player,
            module, command, args)
    end
    dispatchLocal(module, command, args)
    return true
end

function M.broadcast(module, command, args)
    if isMultiplayer() then
        return ServerUtil.callGlobalSucceeded("sendServerCommand", module,
            command, args)
    end
    dispatchLocal(module, command, args)
    return true
end

return M
