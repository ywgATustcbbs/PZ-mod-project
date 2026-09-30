-- Railroader-specific RV entry/exit authority.
--
-- This file deliberately sits beside RV_Server.lua instead of modifying the
-- Railroader source.  The official server record remains the source of truth
-- for train position, speed and seats; this adapter only changes those fields
-- through the same small runtime records that the official command handler
-- uses.  The RV relationship itself is persisted in save-map ModData, never in
-- a survivor's modData, so a replacement character can still use the mapping.

local function processIsClient()
    if type(isClient) ~= "function" then return false end
    local ok, value = pcall(isClient)
    return ok and value == true
end

local function processIsServer()
    if type(isServer) ~= "function" then return true end
    local ok, value = pcall(isServer)
    return ok and value == true
end

-- A client-only process must not register server command handlers.  Dedicated
-- servers, co-op hosts, and the B42 single-player server-side Lua pass through.
if processIsClient() and not processIsServer() then
    return {}
end

require("RailroaderRV/Common/RV_Constants")
local boundaryLoaded, Boundary = pcall(require, "RailroaderRV/BoundaryGuard/RV_BoundaryServer")
if not boundaryLoaded or type(Boundary) ~= "table" then Boundary = nil end
local bitmapLoaded, Bitmap = pcall(require, "RailroaderRV/Common/RV_Bitmap")
if not bitmapLoaded or type(Bitmap) ~= "table" then Bitmap = nil end

RailroaderRV = RailroaderRV or {}
RailroaderRV.RailroaderServer = RailroaderRV.RailroaderServer or {}

local Adapter = RailroaderRV.RailroaderServer
local C = RailroaderRV.Constants
local unpackFn = (table and table.unpack) or unpack
-- Keep persisted map poses inside the same B42 world-height contract used by
-- RV_Server's authoritative relocation validator.  X/Y remain finite server
-- coordinates; the engine's square probe validates their loaded-world use.
local WORLD_MIN_Z = -32
local WORLD_MAX_Z = 31
local roofRefreshRooms = {}
local ROOF_REFRESH_CACHE_TTL_TICKS = 1800
Adapter._mappingEpoch = Adapter._mappingEpoch or 0
local mappingEpoch = Adapter._mappingEpoch
function Adapter.currentMappingEpoch()
    return mappingEpoch
end
function Adapter.advanceMappingEpoch()
    mappingEpoch = mappingEpoch + 1
    Adapter._mappingEpoch = mappingEpoch
    return mappingEpoch
end
local roofRefreshPlayers = {}
local roomMonitorPlayers = {}
local pendingWallRoofRefreshes = {}
local followUpWallRemovalEvents = {}
local roomTransitionStates = {}
-- A wall-removal event is followed by one authoritative inside->outside
-- observation after the grouped remote relocation returns.  Keep a
-- one-shot, identity-scoped suppression for that self-generated observation;
-- object-removal events clear it so a later independent wall action is never
-- swallowed.
local suppressedRoomTransitions = {}
-- Both removal callbacks can receive the same IsoThumpable instance. Keep a
-- short current-coordinate/object-index window in addition to the room
-- identity so a late duplicate callback cannot clear the transition
-- suppression belonging to its already-completed cycle. The key is a string,
-- not userdata, and is reclaimed after the bounded event window.
local seenWallRemovalEvents = {}
-- The dedicated server tick is 10 Hz in the runtime evidence.  Keep the
-- requested 0.5/1.0/1.5 second retries as 5/10/15 ticks after the temporary
-- relocation has arrived; this is deliberately not the old 30/60/90 contract.
local ROOF_REFRESH_DELAY_TICKS = 5
local ROOF_REFRESH_ATTEMPTS = 3
local ROOF_REFRESH_TRANSITION_SUPPRESSION_TICKS = 120
-- Removal callbacks are raised in the same packet/tick; keep this key window
-- short so a later wall operation that reuses the same object index is not
-- mistaken for the earlier event.
local WALL_REMOVAL_EVENT_DEDUPE_TICKS = 10
local WALL_REMOVAL_FOLLOWUP_TICKS = 600
local WALL_REMOVAL_FOLLOWUP_MAX = 8
-- A queued grouped refresh owns the shared mutex before its first relocation,
-- so do not leave it permanently locked when every required identity stays
-- offline.  Once temporary relocation begins, this deadline is never used.
local ROOF_REFRESH_QUEUED_DEADLINE_TICKS = 600
local RELOCATION_SENTINEL_INTERVAL_TICKS = C.RELOCATION_SENTINEL_INTERVAL_TICKS
local RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS =
    C.RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS
local RELOCATION_SENTINEL_Z = C.RELOCATION_SENTINEL_Z
local ROOF_REFRESH_REMOTE_OFFSET_X = C.ROOF_REFRESH_REMOTE_OFFSET_X
local ROOF_REFRESH_REMOTE_OFFSET_Y = C.ROOF_REFRESH_REMOTE_OFFSET_Y
local ROOF_REFRESH_REMOTE_OFFSET_Z = C.ROOF_REFRESH_REMOTE_OFFSET_Z
local relocationSentinelBusy = {}
local relocationSentinelCooldown = {}
local relocationSentinelWarnings = {}
local transitionSequence = 0
local recordForLoco
local roofRefreshTransactionBlocks
local currentGeometryGate
local serverTransactionMutexStatus


local ctx = {
    processIsServer = processIsServer,
    Boundary = Boundary,
    Bitmap = Bitmap,
    Adapter = Adapter,
    C = C,
    unpackFn = unpackFn,
    WORLD_MIN_Z = WORLD_MIN_Z,
    WORLD_MAX_Z = WORLD_MAX_Z,
    roofRefreshRooms = roofRefreshRooms,
    ROOF_REFRESH_CACHE_TTL_TICKS = ROOF_REFRESH_CACHE_TTL_TICKS,
    roofRefreshPlayers = roofRefreshPlayers,
    roomMonitorPlayers = roomMonitorPlayers,
    pendingWallRoofRefreshes = pendingWallRoofRefreshes,
    followUpWallRemovalEvents = followUpWallRemovalEvents,
    roomTransitionStates = roomTransitionStates,
    suppressedRoomTransitions = suppressedRoomTransitions,
    seenWallRemovalEvents = seenWallRemovalEvents,
    ROOF_REFRESH_DELAY_TICKS = ROOF_REFRESH_DELAY_TICKS,
    ROOF_REFRESH_ATTEMPTS = ROOF_REFRESH_ATTEMPTS,
    ROOF_REFRESH_TRANSITION_SUPPRESSION_TICKS = ROOF_REFRESH_TRANSITION_SUPPRESSION_TICKS,
    WALL_REMOVAL_EVENT_DEDUPE_TICKS = WALL_REMOVAL_EVENT_DEDUPE_TICKS,
    WALL_REMOVAL_FOLLOWUP_TICKS = WALL_REMOVAL_FOLLOWUP_TICKS,
    WALL_REMOVAL_FOLLOWUP_MAX = WALL_REMOVAL_FOLLOWUP_MAX,
    ROOF_REFRESH_QUEUED_DEADLINE_TICKS = ROOF_REFRESH_QUEUED_DEADLINE_TICKS,
    RELOCATION_SENTINEL_INTERVAL_TICKS = RELOCATION_SENTINEL_INTERVAL_TICKS,
    RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS = RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS,
    RELOCATION_SENTINEL_Z = RELOCATION_SENTINEL_Z,
    ROOF_REFRESH_REMOTE_OFFSET_X = ROOF_REFRESH_REMOTE_OFFSET_X,
    ROOF_REFRESH_REMOTE_OFFSET_Y = ROOF_REFRESH_REMOTE_OFFSET_Y,
    ROOF_REFRESH_REMOTE_OFFSET_Z = ROOF_REFRESH_REMOTE_OFFSET_Z,
    relocationSentinelBusy = relocationSentinelBusy,
    relocationSentinelCooldown = relocationSentinelCooldown,
    relocationSentinelWarnings = relocationSentinelWarnings,
    transitionSequence = transitionSequence,
    recordForLoco = recordForLoco,
    roofRefreshTransactionBlocks = roofRefreshTransactionBlocks,
    currentGeometryGate = currentGeometryGate,
    serverTransactionMutexStatus = serverTransactionMutexStatus,
}

require("RailroaderRV/RVMapping/RV_RailroaderServer_Train")(ctx)
require("RailroaderRV/RVMapping/RV_RailroaderServer_Mapping")(ctx)
require("RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit")(ctx)
require("RailroaderRV/Core/RV_RailroaderServer_Sentinel")(ctx)
require("RailroaderRV/RoofRefresh/RV_RailroaderServer_RoofRefresh")(ctx)
require("RailroaderRV/RoofRefresh/RV_RailroaderServer_RoofRefreshFlow")(ctx)
require("RailroaderRV/Core/RV_RailroaderServer_Tick")(ctx)

return Adapter
