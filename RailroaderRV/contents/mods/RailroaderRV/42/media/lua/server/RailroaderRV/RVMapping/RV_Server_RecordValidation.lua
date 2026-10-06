-- RV_Server: RecordValidation responsibilities.
return function(ctx)
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local ServerSchema = ctx.ServerSchema
local RV = ctx.RV
local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local RoofRefresh = require("RailroaderRV/RoofRefresh/RV_RoofRefresh")
local armTargetedClientRoomOwnershipGuard = ctx.armTargetedClientRoomOwnershipGuard
local playerIdentity = ctx.playerIdentity
local queueGeneration = ctx.queueGeneration
local guardedRoomOwnershipIdentities = setmetatable({}, { __mode = "k" })

function RV.Server.markRoomOwnershipMonitorGuarded(player, rvId, generation)
    local generations = guardedRoomOwnershipIdentities[player]
    if generations == nil then
        generations = {}
        guardedRoomOwnershipIdentities[player] = generations
    end
    generations[tostring(rvId)] = generation
    return true
end

function RV.Server.pruneRoomOwnershipMonitorConnections(onlinePlayers)
    local online = {}
    for _, player in pairs(onlinePlayers) do
        online[player] = true
    end
    for player in pairs(guardedRoomOwnershipIdentities) do
        if online[player] ~= true then
            guardedRoomOwnershipIdentities[player] = nil
        end
    end
end

local function currentMappingRecord(rvId, generation)
    return RailroaderRV.RailroaderServer.currentMappingRecord(rvId, generation)
end

-- A mapping record is the published authority.  Its anchor, managed region,
-- shell edges and bounds are pure functions of the compiled template and the
-- record's slot index, so this view rebuilds them instead of reading a
-- persisted geometry copy.  It deliberately carries no mutation state: a
-- published record is by construction committed, so readers must not be able
-- to mistake a fabricated `state` for real generation state.
local function manifestViewForRecord(record)
    local slotIndex = record.slotIndex
    local generation = record.generation
    local anchor = RegionSlots.indexToAnchor(slotIndex)
    local boundary = Boundary.boundaryFor(record)
    local layout = Layout.make(anchor.x, anchor.y, anchor.z,
        record.templateId)
    return {
        generation = generation,
        slotIndex = slotIndex,
        anchor = anchor,
        bounds = ServerSchema.boundsFor(layout),
        rvId = tostring(record.locoId),
        boundary = boundary,
    }
end

local function manifestForIdentity(rvId, generation)
    local recordOk, record = currentMappingRecord(rvId, generation)
    if recordOk == false then return false, record end
    -- The published mapping record is the whole authority: it carries the slot
    -- index and identity, and every geometric fact is derived from the template
    -- for that slot.  Nothing is persisted outside this map.
    return true, manifestViewForRecord(record)
end

function RV.Server.setRailroaderValidationHook(callback)
    ctx.railroaderValidationHook = type(callback) == "function" and callback or nil
end

function RV.Server.setRailroaderCommitHook(callback)
    ctx.railroaderCommitHook = type(callback) == "function" and callback or nil
end

function RV.Server.setRailroaderFailureHook(callback)
    ctx.railroaderFailureHook = type(callback) == "function" and callback or nil
end

function RV.Server.requestRailroaderGeneration(player, railroaderData)
    if type(railroaderData) ~= "table" then
        return false, "Railroader generation data is missing"
    end
    if not ctx.railroaderValidationHook or not ctx.railroaderCommitHook
        or not ctx.railroaderFailureHook then
        return false, "Railroader RV transaction hooks are unavailable"
    end
    return queueGeneration(player, nil, railroaderData)
end

-- Read-only current identity for the relocation destination service.
function RV.Server.currentRVManifestForRelocation(rvId, generation)
    return manifestForIdentity(rvId, generation)
end

function RV.Server.currentRVManifestForBoundary(rvId, generation)
    return manifestForIdentity(rvId, generation)
end

-- Each scheduled attempt resolves the current authoritative mapping and
-- rebuilds its geometry from the current template at execution time.
function RV.Server.refreshRoofVisuals(rvId)
    local adapter = RailroaderRV.RailroaderServer
    local record = adapter.currentMappingRecordById(rvId)
    local manifest = manifestViewForRecord(record)
    return RoofRefresh.run(manifest.bounds)
end

function RV.Server.scheduleRoofRefreshForRV(rvId)
    return RoofRefresh.schedule(rvId)
end

-- Re-arm a client's persistent stale-room monitor when it enters an already
-- generated RV or appears after reconnect. The mapping identity, anchor and
-- boundary rebuild a strict
-- current manifest view for this RV. No client state or caller-supplied bounds
-- participate in this command.
function RV.Server.armCurrentRoomOwnershipMonitor(player, record)
    local recordGeneration = record.generation
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then return false, identityOrReason end
    -- The mapping record comparison already proves the published identity.
    -- An in-flight generation is the only other owner of this scope; its
    -- process-local transaction is the gate, not a durable record.
    local transaction = ctx.GenerationTransaction
    local pending = transaction.current()
    if pending ~= nil and tostring(pending.rvId) == tostring(record.locoId)
        and pending.generation == recordGeneration then
        return false, "RV generation is still in progress"
    end
    local manifestAccepted, manifest = RV.Server.currentRVManifestForBoundary(
        record.locoId, recordGeneration)
    if manifestAccepted == false then
        return false, manifest
    end

    local rvId = tostring(record.locoId)
    local armedGenerations = guardedRoomOwnershipIdentities[player]
    if armedGenerations == nil
        or armedGenerations[rvId] ~= recordGeneration then
        armTargetedClientRoomOwnershipGuard(player, recordGeneration,
            manifest.bounds, record.locoId)
        RV.Server.markRoomOwnershipMonitorGuarded(player, record.locoId,
            recordGeneration)
    end
    return true
end


end
