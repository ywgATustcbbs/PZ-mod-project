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

RailroaderRV = RailroaderRV or {}
RailroaderRV.RailroaderServer = RailroaderRV.RailroaderServer or {}

local Adapter = RailroaderRV.RailroaderServer
local C = RailroaderRV.Constants
local unpackFn = (table and table.unpack) or unpack

-- The user promises not to use old saves, so no old-schema guard, compatibility,
-- or migration path is needed. A mismatch only warns; modules trust current
-- interfaces, and malformed data follows the normal game error path.
local function checkSaveSchemaVersion()
    if Adapter._saveSchemaVersionChecked then return end
    Adapter._saveSchemaVersionChecked = true

    local map = ModData.getOrCreate(C.RV_MAP_KEY)
    local empty = true
    for _ in pairs(map) do
        empty = false
        break
    end
    if empty then
        map.schemaVersion = C.SAVE_SCHEMA_VERSION
        map.locomotives = {}
        map.players = {}
        return
    end
    if map.schemaVersion ~= C.SAVE_SCHEMA_VERSION then
        print("[RailroaderRV] This save has an old or missing schema version ("
            .. tostring(map.schemaVersion) .. "); current version is "
            .. tostring(C.SAVE_SCHEMA_VERSION)
            .. ". Continuing without migration. If RV data errors occur, delete this save and rebuild it.")
    end
end

if not Adapter._saveSchemaVersionCheckRegistered then
    local events = rawget(_G, "Events")
    local event = events and events.OnInitGlobalModData
    if event and type(event.Add) == "function" then
        local ok = pcall(event.Add, checkSaveSchemaVersion)
        if ok then
            Adapter._saveSchemaVersionCheckRegistered = true
        else
            print("[RailroaderRV] Saved schema version check could not be registered; continuing.")
        end
    else
        print("[RailroaderRV] Saved schema version check could not be registered; continuing.")
    end
end

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
local transitionSequence = 0
local recordForLoco


local ctx = {
    processIsServer = processIsServer,
    Boundary = Boundary,
    Adapter = Adapter,
    C = C,
    unpackFn = unpackFn,
    -- Keep persisted map poses inside the same B42 world-height contract used
    -- by RV_Server's authoritative relocation validator.  X/Y remain finite
    -- server coordinates; the engine's square probe validates their use.
    WORLD_MIN_Z = C.WORLD_MIN_Z,
    WORLD_MAX_Z = C.WORLD_MAX_Z,
    transitionSequence = transitionSequence,
    recordForLoco = recordForLoco,
}

-- The wall reload service is required before the transaction gate so its
-- cross-module mutex query exists when the gate validates its install.
require("RailroaderRV/RVMapping/RV_RailroaderServer_Train")(ctx)
require("RailroaderRV/RVMapping/RV_RailroaderServer_Mapping")(ctx)
require("RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit")(ctx)
require("RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload")(ctx)
require("RailroaderRV/Core/RV_RailroaderServer_Sentinel")(ctx)
require("RailroaderRV/Core/RV_RailroaderServer_Tick")(ctx)

return Adapter
