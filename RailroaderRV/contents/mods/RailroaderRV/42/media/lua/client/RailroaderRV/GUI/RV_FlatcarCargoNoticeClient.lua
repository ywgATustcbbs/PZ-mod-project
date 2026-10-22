-- Client-side feedback for a server-rejected flatcar cargo addition.
require "RailroaderRV/Common/RV_Constants"

RailroaderRV = RailroaderRV or {}
RailroaderRV.FlatcarCargoNoticeClient =
    RailroaderRV.FlatcarCargoNoticeClient or {}

local Client = RailroaderRV.FlatcarCargoNoticeClient
local C = RailroaderRV.Constants
local REASON_TEXT = {
    ["bound-rv-cannot-convert"] = "IGUI_RailroaderRV_Flatcar_BoundRVCannotConvert",
    ["deck-full"] = "IGUI_RailroaderRV_Flatcar_DeckFull",
    ["source-not-found"] = "IGUI_RailroaderRV_Flatcar_SourceNotFound",
    ["source-out-of-range"] = "IGUI_RailroaderRV_Flatcar_SourceOutOfRange",
    ["source-occupied"] = "IGUI_RailroaderRV_Flatcar_SourceOccupied",
    ["source-towing"] = "IGUI_RailroaderRV_Flatcar_SourceTowing",
    ["cargo-not-found"] = "IGUI_RailroaderRV_Flatcar_CargoNotFound",
    ["unload-blocked"] = "IGUI_RailroaderRV_Flatcar_UnloadBlocked",
    ["loading-ramp-required"] = "IGUI_RailroaderRV_Flatcar_LoadingRampRequired",
}

local function localPlayerByOnlineId(onlineId)
    local count = getNumActivePlayers()
    for playerNum = 0, count - 1 do
        local player = getSpecificPlayer(playerNum)
        if player and C.finiteInteger(player:getOnlineID()) == onlineId then
            return player
        end
    end
    if not isClient() and onlineId == 0 and count > 0 then
        return getSpecificPlayer(0)
    end
    return nil
end

function Client.onServerCommand(module, command, args)
    if module ~= C.MOD_ID or command ~= C.COMMAND_RV_FLATCAR_NOTICE then
        return
    end
    local textKey = REASON_TEXT[args.reason]
    if not textKey then return end
    local player = localPlayerByOnlineId(args.onlineId)
    if player then
        -- PZ advances this clock by about one unit per real frame at 60 FPS
        -- under normal time settings, so 120 units displays for two seconds.
        player:setHaloNote(getText(textKey), 255, 80, 80, 120)
    end
end

return Client
