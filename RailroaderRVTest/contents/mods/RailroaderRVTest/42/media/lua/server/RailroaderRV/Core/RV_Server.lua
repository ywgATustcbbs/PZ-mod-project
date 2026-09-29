-- RailroaderRVTest server-side generation transaction.
--
-- This file deliberately owns no client UI and does not depend on a legacy adapter.
-- The shared RV_Constants/RV_Layout modules are required at request time. A
-- missing or malformed shared contract rejects the request before world I/O.

local OWNER = "RailroaderRVTest"
local COMMAND_MODULE = "RailroaderRVTest"
local COMMAND = "Generate"
local COMMAND_RELOCATE = "Relocate"
local COMMAND_RELOCATE_ACK = "RelocateAck"
local COMMAND_FINAL_RELOCATE = "FinalRelocate"
local COMMAND_FINAL_RELOCATE_ACK = "FinalRelocateAck"
local COMMAND_REFRESH_ROOM_OWNERSHIP = "RefreshRoomOwnership"
local COMMAND_RV_ENTER = "EnterRV"
local COMMAND_RV_EXIT = "ExitRV"
local COMMAND_RV_TELEPORT = "RVTeleport"
local MANIFEST_KEY = "RailroaderRVTest.Manifest"

-- Railroader entry/exit is implemented by RV_RailroaderServer.lua.  These
-- callbacks keep the long-running generation transaction authoritative without
-- making the generic Generate command depend on Railroader being installed.
local railroaderValidationHook = nil
local railroaderCommitHook = nil
local railroaderFailureHook = nil

local function loadModule(name, globalName)
    local ok, result = pcall(require, name)
    if ok and type(result) == "table" then
        return result
    end
    local value = rawget(_G, globalName)
    if type(value) == "table" then
        return value
    end
    local rv = rawget(_G, "RailroaderRV")
    if type(rv) == "table" then
        local nestedName = globalName == "RV_Constants" and "Constants"
            or globalName == "RV_Layout" and "Layout" or nil
        if nestedName and type(rv[nestedName]) == "table" then
            return rv[nestedName]
        end
    end
    return {}
end

-- PZ's Lua loader uses slash-separated media paths (the same contract used by
-- RV_Layout.lua and the utility modules).  Keep the global fallback
-- only for a debugger reload; normal loading must return the actual tables.
local Constants = loadModule("RailroaderRV/Common/RV_Constants", "RV_Constants")
local Core = require("RailroaderRV/Core/RV_Server_Core")
local boundaryLoaded, Boundary = pcall(require, "RailroaderRV/BoundaryGuard/RV_BoundaryServer")
if not boundaryLoaded or type(Boundary) ~= "table" then
    Boundary = nil
    print("[RailroaderRVTest] RV boundary service unavailable; boundary hooks disabled")
end
local bitmapLoaded, Bitmap = pcall(require, "RailroaderRV/Common/RV_Bitmap")
if not bitmapLoaded or type(Bitmap) ~= "table" then
    Bitmap = nil
    print("[RailroaderRVTest] RV bitmap contract unavailable")
end
local roofRefreshOk, RoofRefresh = pcall(require, "RailroaderRV/RoofRefresh/RV_RoofRefresh")
if not roofRefreshOk or type(RoofRefresh) ~= "table"
    or type(RoofRefresh.run) ~= "function" then
    RoofRefresh = nil
end

local RV = rawget(_G, "RailroaderRV") or {}
rawset(_G, "RailroaderRV", RV)
RV.Server = RV.Server or {}

-- Generic invocation, numeric validation, and shared layout checks live in a
-- separate require chunk.  Keeping this facade focused on the transaction and
-- event lifecycle avoids Kahlua's 200-local limit without changing the public
-- RV.Server API.
local ServerUtil = require("RailroaderRV/Common/RV_ServerUtil")
local ServerTeleport = require("RailroaderRV/Common/RV_ServerTeleport")
local ServerWorld = require("RailroaderRV/Common/RV_ServerWorld")
local ServerSchema = require("RailroaderRV/Common/RV_ServerSchema")
local UtilityServer = require("RailroaderRV/Core/RV_UtilityServer")
local Common = require("RailroaderRV/Common/RV_Common")
local playerPositionCache = Common.newPlayerPositionCache(Core)

local transactionBusy = false
local transactionPlayer = nil
local pendingGeneration = nil
-- A wall-removal refresh relocates every authoritative player in the current
-- RV scope as one transaction.  The target is derived from the current
-- bitmap/layout center and offset by the current contract vector; it is not a
-- persisted coordinate or a client-provided destination.
local roofRefreshRelocationGroup = nil
local roofRefreshGroupFailure = nil
local roofRefreshGroupFinalReturn = nil
local roofRefreshGroupSerial = 0
local pendingSerial = 0
local serverTick = Core.getTick()
local roomOwnershipGuards = {}
local safeErrorText
local requireCurrentManifest

if UtilityServer and type(UtilityServer.initializeRecord) == "function" then
    RV.Server.initializeUtilityRecord = UtilityServer.initializeRecord
end
if UtilityServer and type(UtilityServer.settleAndRefreshLoad) == "function" then
    RV.Server.settleRVUtilityLoad = UtilityServer.settleAndRefreshLoad
end

-- The client acknowledgement requires a full server -> client -> server
-- round trip.  Keep an additional cross-tick guard before touching the old
-- player-built room so the client cannot still be evaluating its stale
-- IsoRoom while WorldRegionToMetaGrid rebuilds the room definitions.
local RELOCATION_MIN_TICKS = 3
local RELOCATION_POST_ACK_TICKS = 2
local RELOCATION_TIMEOUT_TICKS = 600
local ROOF_REFRESH_RETURN_RETRY_TICKS = 5
local ROOF_RELOCATION_RETRY_TICKS = 5
local GENERATION_RELOCATION_RETRY_TICKS = 5
local ROOF_REFRESH_REMOTE_OFFSET_X = Constants.ROOF_REFRESH_REMOTE_OFFSET_X
local ROOF_REFRESH_REMOTE_OFFSET_Y = Constants.ROOF_REFRESH_REMOTE_OFFSET_Y
local ROOF_REFRESH_REMOTE_OFFSET_Z = Constants.ROOF_REFRESH_REMOTE_OFFSET_Z
local ROOF_REFRESH_TEMP_Z = Constants.RELOCATION_SENTINEL_Z
local GENERATION_STAGING_Z = Constants.RELOCATION_SENTINEL_Z

-- IsoRegions does not expose a Lua callback for completion of its asynchronous
-- dynamic-room rebuild. Room ownership guards use nearby-player probes and
-- bounded, event-triggered rechecks instead of periodic full-footprint scans.
local ROOM_OWNERSHIP_MIN_TICKS = 1800
local ROOM_OWNERSHIP_STABLE_TICKS = 120
local ROOM_OWNERSHIP_MAX_TICKS = 7200

local WORLD_MIN_Z = -32
local WORLD_MAX_Z = 31


local ctx = {
    OWNER = OWNER,
    COMMAND_MODULE = COMMAND_MODULE,
    COMMAND = COMMAND,
    COMMAND_RELOCATE = COMMAND_RELOCATE,
    COMMAND_RELOCATE_ACK = COMMAND_RELOCATE_ACK,
    COMMAND_FINAL_RELOCATE = COMMAND_FINAL_RELOCATE,
    COMMAND_FINAL_RELOCATE_ACK = COMMAND_FINAL_RELOCATE_ACK,
    COMMAND_REFRESH_ROOM_OWNERSHIP = COMMAND_REFRESH_ROOM_OWNERSHIP,
    COMMAND_RV_ENTER = COMMAND_RV_ENTER,
    COMMAND_RV_EXIT = COMMAND_RV_EXIT,
    COMMAND_RV_TELEPORT = COMMAND_RV_TELEPORT,
    MANIFEST_KEY = MANIFEST_KEY,
    railroaderValidationHook = railroaderValidationHook,
    railroaderCommitHook = railroaderCommitHook,
    railroaderFailureHook = railroaderFailureHook,
    Constants = Constants,
    Core = Core,
    Boundary = Boundary,
    Bitmap = Bitmap,
    RoofRefresh = RoofRefresh,
    RV = RV,
    ServerUtil = ServerUtil,
    ServerWorld = ServerWorld,
    ServerSchema = ServerSchema,
    UtilityServer = UtilityServer,
    samplePlayerPosition = function(player, tick, interval)
        return playerPositionCache:samplePlayerPosition(player, tick, interval)
    end,
    getPlayerPosition = function(player, options)
        return playerPositionCache:getPlayerPosition(player, options)
    end,
    invalidatePlayerPosition = function(player)
        return playerPositionCache:invalidatePlayer(player)
    end,
    transactionBusy = transactionBusy,
    transactionPlayer = transactionPlayer,
    pendingGeneration = pendingGeneration,
    roofRefreshRelocationGroup = roofRefreshRelocationGroup,
    roofRefreshGroupFailure = roofRefreshGroupFailure,
    roofRefreshGroupFinalReturn = roofRefreshGroupFinalReturn,
    roofRefreshGroupSerial = roofRefreshGroupSerial,
    pendingSerial = pendingSerial,
    serverTick = serverTick,
    roomOwnershipGuards = roomOwnershipGuards,
    safeErrorText = safeErrorText,
    requireCurrentManifest = requireCurrentManifest,
    RELOCATION_MIN_TICKS = RELOCATION_MIN_TICKS,
    RELOCATION_POST_ACK_TICKS = RELOCATION_POST_ACK_TICKS,
    RELOCATION_TIMEOUT_TICKS = RELOCATION_TIMEOUT_TICKS,
    ROOF_REFRESH_RETURN_RETRY_TICKS = ROOF_REFRESH_RETURN_RETRY_TICKS,
    ROOF_RELOCATION_RETRY_TICKS = ROOF_RELOCATION_RETRY_TICKS,
    GENERATION_RELOCATION_RETRY_TICKS = GENERATION_RELOCATION_RETRY_TICKS,
    ROOF_REFRESH_REMOTE_OFFSET_X = ROOF_REFRESH_REMOTE_OFFSET_X,
    ROOF_REFRESH_REMOTE_OFFSET_Y = ROOF_REFRESH_REMOTE_OFFSET_Y,
    ROOF_REFRESH_REMOTE_OFFSET_Z = ROOF_REFRESH_REMOTE_OFFSET_Z,
    ROOF_REFRESH_TEMP_Z = ROOF_REFRESH_TEMP_Z,
    GENERATION_STAGING_Z = GENERATION_STAGING_Z,
    ROOM_OWNERSHIP_MIN_TICKS = ROOM_OWNERSHIP_MIN_TICKS,
    ROOM_OWNERSHIP_STABLE_TICKS = ROOM_OWNERSHIP_STABLE_TICKS,
    ROOM_OWNERSHIP_MAX_TICKS = ROOM_OWNERSHIP_MAX_TICKS,
    WORLD_MIN_Z = WORLD_MIN_Z,
    WORLD_MAX_Z = WORLD_MAX_Z,
}

RV.Server.samplePlayerPosition = ctx.samplePlayerPosition
RV.Server.getPlayerPosition = ctx.getPlayerPosition
RV.Server.invalidatePlayerPosition = ctx.invalidatePlayerPosition
RV.Server.teleportToPosition = ServerTeleport.teleportToPosition
RV.Server.teleportToRVSpawn = ServerTeleport.teleportToRVSpawn

require("RailroaderRV/RoofRefresh/RV_Server_RoomOwnership")(ctx)
require("RailroaderRV/Construction/RV_Server_WorldObjects")(ctx)
require("RailroaderRV/Construction/RV_Server_GenerationBuild")(ctx)
require("RailroaderRV/Construction/RV_Server_PlayerValidation")(ctx)
require("RailroaderRV/Core/RV_Server_ManifestValidation")(ctx)
require("RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair")(ctx)
require("RailroaderRV/RoofRefresh/RV_Server_RoofDestinations")(ctx)
require("RailroaderRV/RoofRefresh/RV_Server_RoofRelocation")(ctx)
require("RailroaderRV/RoofRefresh/RV_Server_RoofApi")(ctx)
require("RailroaderRV/Construction/RV_Server_GenerationFlow")(ctx)
require("RailroaderRV/RVMapping/RV_Server_RecordValidation")(ctx)
require("RailroaderRV/Construction/RV_Server_GenerationAck")(ctx)
require("RailroaderRV/Core/RV_Server_Commands")(ctx)

return RV.Server
