-- RV_Server: RecordValidation responsibilities.
return function(ctx)
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local ServerSchema = ctx.ServerSchema
local RoofRefresh = ctx.RoofRefresh
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local function safeErrorText(...) return ctx.safeErrorText(...) end
local armTargetedClientRoomOwnershipGuard = ctx.armTargetedClientRoomOwnershipGuard
local playerIdentity = ctx.playerIdentity
local currentRoofRefreshContext = ctx.currentRoofRefreshContext
local queueGeneration = ctx.queueGeneration

local function currentMappingRecord(rvId, generation)
    local adapter = RailroaderRV and RailroaderRV.RailroaderServer
    if type(adapter) ~= "table"
        or type(adapter.currentMappingRecord) ~= "function" then
        return false, Constants.INVALID_RV_DATA
    end
    local ok, accepted, record = pcall(adapter.currentMappingRecord,
        rvId, generation)
    if not ok or accepted ~= true or type(record) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    return true, record
end

-- A mapping record is the published authority.  Its anchor, managed region,
-- shell edges and bounds are pure functions of the compiled template and the
-- record's slot index, so this view rebuilds them instead of reading a
-- persisted geometry copy.  It deliberately carries no mutation state: a
-- published record is by construction committed, so readers must not be able
-- to mistake a fabricated `state` for real generation state.
local function manifestViewForRecord(record)
    if type(record) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local slotIndex = ServerUtil.integer(record.slotIndex)
    local generation = ServerUtil.integer(record.generation)
    local anchor = slotIndex and RegionSlots.indexToAnchor(slotIndex) or nil
    local boundary = Boundary.boundaryFor(record)
    if not anchor or not boundary or generation == nil then
        return false, Constants.INVALID_RV_DATA
    end
    local ok, manifest = pcall(function()
        local layout = Layout.make(anchor.x, anchor.y, anchor.z)
        return {
            generation = generation,
            slotIndex = slotIndex,
            anchor = anchor,
            bounds = ServerSchema.boundsFor(layout),
            rvId = tostring(record.locoId),
            boundary = boundary,
        }
    end)
    if not ok or type(manifest) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    return true, manifest
end

local function manifestForIdentity(rvId, generation)
    local recordOk, record = currentMappingRecord(rvId, generation)
    if not recordOk then return false, record end
    -- The published mapping record is the whole authority: it carries the slot
    -- index and identity, and every geometric fact is derived from the template
    -- for that slot.  Nothing is persisted outside this map.
    local viewOk, view = manifestViewForRecord(record)
    if not viewOk then return false, view end
    return true, view
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

-- Read-only current identity for the stateless -15 sentinel.
function RV.Server.currentRVManifestForRelocation(rvId, generation)
    return manifestForIdentity(rvId, generation)
end

function RV.Server.currentRVManifestForBoundary(rvId, generation)
    return manifestForIdentity(rvId, generation)
end

-- Rebuild the captured south-window floor's room/roof neighbours after an
-- existing RV entry or reconnect.
function RV.Server.refreshRoofVisuals(player, record)
    if not RoofRefresh then
        return false, "roof refresh module is unavailable"
    end
    if type(record) ~= "table" then return false, Constants.INVALID_RV_DATA end
    local manifestOk, manifest = RV.Server.currentRVManifestForRelocation(
        record.locoId, record.generation)
    if not manifestOk or type(manifest) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then return false, identityOrReason end
    local contextOk, contextOrReason = currentRoofRefreshContext(player, {
        rvId = manifest.rvId,
        generation = manifest.generation,
        identityKey = identityOrReason.key,
    })
    if not contextOk then return false, contextOrReason end
    local bounds = manifest.bounds
    local ok, result, reason = pcall(RoofRefresh.run, player, bounds, {
        rvId = manifest.rvId,
        generation = manifest.generation,
    })
    if not ok then return false, safeErrorText(result) end
    return result == true, reason
end

-- Re-arm a client's persistent stale-room monitor when it enters an already
-- generated RV or appears after reconnect. The mapping identity, anchor and
-- boundary rebuild a strict
-- current manifest view for this RV. No client state or caller-supplied bounds
-- participate in this command.
function RV.Server.armCurrentRoomOwnershipMonitor(player, record)
    if type(record) ~= "table"
        or record.generated ~= true
        or type(record.locoId) ~= "string" or record.locoId == ""
        or type(record.players) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local recordGeneration = ServerUtil.toNumber(record.generation)
    if not ServerUtil.isFiniteNumber(recordGeneration) or math.floor(recordGeneration)
        ~= recordGeneration or recordGeneration < 1 then
        return false, Constants.INVALID_RV_DATA
    end
    -- Managed bounds come from the compiled template, never from the record.
    local boundary = Boundary.boundaryFor(record)
    if type(boundary) ~= "table" or type(boundary.managed) ~= "table"
        or type(boundary.shellEdges) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end

    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then return false, identityOrReason end
    -- The mapping record comparison already proves the published identity.
    -- An in-flight generation is the only other owner of this scope; its
    -- process-local transaction is the gate, not a durable record.
    local transaction = ctx.GenerationTransaction
    if type(transaction) == "table"
        and type(transaction.current) == "function" then
        local pendingOk, pending = pcall(transaction.current)
        if pendingOk and type(pending) == "table"
            and tostring(pending.rvId) == tostring(record.locoId)
            and ServerUtil.integer(pending.generation) == recordGeneration then
            return false, "RV generation is still in progress"
        end
    end
    local manifestAccepted, manifest = RV.Server.currentRVManifestForBoundary(
        record.locoId, recordGeneration)
    if manifestAccepted ~= true or type(manifest) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local manifestGeneration = ServerUtil.toNumber(manifest.generation)
    if tostring(manifest.rvId) ~= tostring(record.locoId)
        or manifestGeneration ~= recordGeneration then
        return false, Constants.INVALID_RV_DATA
    end

    local armedOk, armedError = pcall(armTargetedClientRoomOwnershipGuard,
        player, recordGeneration, manifest.bounds, record.locoId)
    if not armedOk then
        return false, safeErrorText(armedError)
    end
    print("[RailroaderRVTest] targeted room ownership monitor armed player="
        .. tostring(identityOrReason.key) .. " rvId=" .. tostring(record.locoId)
        .. " generation=" .. tostring(recordGeneration))
    return true
end


end
