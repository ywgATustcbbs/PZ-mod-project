-- Client-only entry point for the technical test.
--
-- The menu is intentionally ordinary (world right-click).  The client sends
-- only the command name; the server validates the player's current state from
-- its authoritative player object and selects both the fixed generation anchor
-- and the current-schema generation-center staging coordinate.

require "RailroaderRV/Common/RV_Constants"
require "RailroaderRV/GUI/RV_BoundaryWallVisuals"
require "RailroaderRV/GUI/RV_WardrobeVisuals"
require "RailroaderRV/GUI/RV_ProtectedDemolition"
local boundaryClientLoaded, BoundaryClient = pcall(require,
    "RailroaderRV/GUI/RV_BoundaryClient")
if not boundaryClientLoaded then
    print("[RailroaderRVTest] RV boundary client unavailable: "
        .. tostring(BoundaryClient))
end

RailroaderRV = RailroaderRV or {}
RailroaderRV.Client = RailroaderRV.Client or {}

local Client = RailroaderRV.Client
local C = RailroaderRV.Constants
local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
local MENU_KEY = "ContextMenu_RailroaderRVTest_Generate"
local COMMAND_RELOCATE = "Relocate"
local COMMAND_RELOCATE_ACK = "RelocateAck"
local COMMAND_FINAL_RELOCATE = C.COMMAND_FINAL_RELOCATE or "FinalRelocate"
local COMMAND_FINAL_RELOCATE_ACK = C.COMMAND_FINAL_RELOCATE_ACK
    or "FinalRelocateAck"
local ROOF_REFRESH_HALO_TEXT = "Refreshing room"
local GENERATION_HALO_TEXT = "正在生成房车"
-- The current B42 renderer displays non-ASCII halo text as replacement
-- characters. Keep the local Chinese semantic label above for the client
-- contract, but render the equivalent ASCII label that the engine can show.
local GENERATION_HALO_RENDER_TEXT = "Generating RV"
local COMMAND_REFRESH_ROOM_OWNERSHIP = C.COMMAND_REFRESH_ROOM_OWNERSHIP
    or "RefreshRoomOwnership"
local pendingRelocation = nil
local RELOCATION_TIMEOUT_TICKS = 600
local GENERATION_HALO_REFRESH_TICKS = 10
-- IsoRegions has no public Lua completion event.  The initial generation
-- guard is also the only server-authoritative identity/bounds packet a client
-- receives for this footprint, so it must remain armed after the generation
-- transaction.  A later wall/floor removal can cause another asynchronous
-- region packet to retire the same IsoRoom; releasing the guard after a quiet
-- tail leaves that packet unchecked and exposes ParameterFirearmRoomSize to a
-- RoomDef=nil reference on the next player update.
local ROOM_OWNERSHIP_MIN_TICKS = 1800
local clientTick = 0


local ctx = {
    Client = Client,
    C = C,
    Layout = Layout,
    MENU_KEY = MENU_KEY,
    COMMAND_RELOCATE = COMMAND_RELOCATE,
    COMMAND_RELOCATE_ACK = COMMAND_RELOCATE_ACK,
    COMMAND_FINAL_RELOCATE = COMMAND_FINAL_RELOCATE,
    COMMAND_FINAL_RELOCATE_ACK = COMMAND_FINAL_RELOCATE_ACK,
    ROOF_REFRESH_HALO_TEXT = ROOF_REFRESH_HALO_TEXT,
    GENERATION_HALO_RENDER_TEXT = GENERATION_HALO_RENDER_TEXT,
    COMMAND_REFRESH_ROOM_OWNERSHIP = COMMAND_REFRESH_ROOM_OWNERSHIP,
    pendingRelocation = pendingRelocation,
    RELOCATION_TIMEOUT_TICKS = RELOCATION_TIMEOUT_TICKS,
    GENERATION_HALO_REFRESH_TICKS = GENERATION_HALO_REFRESH_TICKS,
    ROOM_OWNERSHIP_MIN_TICKS = ROOM_OWNERSHIP_MIN_TICKS,
    clientTick = clientTick,
}

require("RailroaderRV/GUI/RV_ContextMenu_RoomOwnership")(ctx)
require("RailroaderRV/GUI/RV_ContextMenu_Relocation")(ctx)

return Client
