-- RailroaderRV server-side generation transaction.
--
-- This file deliberately owns no client UI and does not depend on a legacy adapter.
-- The shared RV_Constants/RV_Layout modules are required at request time. A
-- missing or malformed shared contract rejects the request before world I/O.

-- Server-side Lua files can also be evaluated by a client-only process. Keep
-- the server facade and its event subscriptions out of that process while
-- preserving the single-player and server-side initialization paths.
if isClient() and not isServer() then
    return {}
end

local OWNER = "RailroaderRV"
local COMMAND_MODULE = "RailroaderRV"
local COMMAND = "Generate"
local COMMAND_RELOCATE = "Relocate"
local COMMAND_RELOCATE_ACK = "RelocateAck"
local COMMAND_FINAL_RELOCATE = "FinalRelocate"
local COMMAND_FINAL_RELOCATE_ACK = "FinalRelocateAck"
local COMMAND_REFRESH_ROOM_OWNERSHIP = "RefreshRoomOwnership"
local COMMAND_RV_ENTER = "EnterRV"
local COMMAND_RV_EXIT = "ExitRV"
local COMMAND_RV_TELEPORT = "RVTeleport"

-- Railroader entry/exit is implemented by RV_RailroaderServer.lua.  These
-- callbacks keep the long-running generation transaction authoritative without
-- making the generic Generate command depend on Railroader being installed.
local railroaderValidationHook = nil
local railroaderCommitHook = nil
local railroaderFailureHook = nil

local Constants = require("RailroaderRV/Common/RV_Constants")
local Core = require("RailroaderRV/Core/RV_Server_Core")
local GenerationTransaction = require(
    "RailroaderRV/Construction/RV_Server_GenerationTransaction")()
local Boundary = require("RailroaderRV/BoundaryGuard/RV_BoundaryServer")

-- The Railroader adapter owns the mapping, the entry/exit gate and the wall
-- reload operation service.  It is loaded here, before the internal modules are
-- assembled, because RoomOwnership asks it whether a wall reload is holding the
-- RV's players outside their room geometry.
require("RailroaderRV/Core/RV_RailroaderServer")

local RV = rawget(_G, "RailroaderRV") or {}
rawset(_G, "RailroaderRV", RV)
RV.Server = RV.Server or {}
RV.Server.isGenerationTransactionActive = GenerationTransaction.isActive
RV.Server.isGenerationTransactionActiveForRV = GenerationTransaction.isActiveForRV

-- Generic invocation, numeric validation, and shared layout checks live in a
-- separate require chunk.  Keeping this facade focused on the transaction and
-- event lifecycle avoids Kahlua's 200-local limit without changing the public
-- RV.Server API.
local ServerUtil = require("RailroaderRV/Common/RV_ServerUtil")
local ServerTeleport = require("RailroaderRV/Common/RV_ServerTeleport")
local ServerWorld = require("RailroaderRV/Common/RV_ServerWorld")
local ServerSchema = require("RailroaderRV/Common/RV_ServerSchema")
local UtilityServer = require("RailroaderRV/Core/RV_UtilityServer")

local pendingSerial = 0
local serverTick = Core.getTick()
local roomOwnershipGuards = {}
local safeErrorText

-- The one budget the generation transaction uses for a staging wait, a final
-- wait and its single abort path.
local RELOCATION_TIMEOUT_TICKS = 600

RV.Server.initializeUtilityRecord = UtilityServer.initializeRecord
RV.Server.settleRVUtilityLoad = UtilityServer.settleAndRefreshLoad

-- IsoRegions does not expose a Lua callback for completion of its asynchronous
-- dynamic-room rebuild. Room ownership guards use nearby-player probes and
-- bounded, event-triggered rechecks instead of periodic full-footprint scans.
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
    railroaderValidationHook = railroaderValidationHook,
    railroaderCommitHook = railroaderCommitHook,
    railroaderFailureHook = railroaderFailureHook,
    Constants = Constants,
    Core = Core,
    GenerationTransaction = GenerationTransaction,
    Boundary = Boundary,
    RV = RV,
    ServerUtil = ServerUtil,
    ServerWorld = ServerWorld,
    ServerSchema = ServerSchema,
    UtilityServer = UtilityServer,
    pendingSerial = pendingSerial,
    serverTick = serverTick,
    roomOwnershipGuards = roomOwnershipGuards,
    safeErrorText = safeErrorText,
    RELOCATION_TIMEOUT_TICKS = RELOCATION_TIMEOUT_TICKS,
    WORLD_MIN_Z = Constants.WORLD_MIN_Z,
    WORLD_MAX_Z = Constants.WORLD_MAX_Z,
}

RV.Server.teleportToPosition = ServerTeleport.teleportToPosition
RV.Server.teleportToRVSpawn = ServerTeleport.teleportToRVSpawn

require("RailroaderRV/RoomOwnership/RV_Server_RoomOwnership")(ctx)
require("RailroaderRV/Construction/RV_Server_WorldObjects")(ctx)
require("RailroaderRV/Construction/RV_Server_GenerationBuild")(ctx)
require("RailroaderRV/Construction/RV_Server_PlayerValidation")(ctx)
require("RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair")(ctx)
require("RailroaderRV/TemplateRecovery/RV_TemplateRecovery")(ctx)
require("RailroaderRV/Construction/RV_Server_GenerationFlow")(ctx)
require("RailroaderRV/RVMapping/RV_Server_RecordValidation")(ctx)
require("RailroaderRV/Construction/RV_Server_GenerationAck")(ctx)
local SafehouseServer = require("RailroaderRV/Safehouse/RV_Server_Safehouse")
RV.Server.handleSafehouseClaim = SafehouseServer.handleClaim
require("RailroaderRV/Core/RV_Server_Commands")(ctx)

return RV.Server
