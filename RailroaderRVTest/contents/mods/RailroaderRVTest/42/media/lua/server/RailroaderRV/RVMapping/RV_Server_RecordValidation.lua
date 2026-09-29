-- RV_Server: RecordValidation responsibilities.
return function(ctx)
local DevSaveSchemaGate = require("RailroaderRV/Core/RV_DevSaveSchemaGate")
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local Bitmap = ctx.Bitmap
local RoofRefresh = ctx.RoofRefresh
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local ServerSchema = ctx.ServerSchema
local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
local function safeErrorText(...) return ctx.safeErrorText(...) end
local function requireCurrentManifest(...) return ctx.requireCurrentManifest(...) end
local armTargetedClientRoomOwnershipGuard = ctx.armTargetedClientRoomOwnershipGuard
local manifestTable = ctx.manifestTable
local playerIdentity = ctx.playerIdentity
local currentRoofRefreshContext = ctx.currentRoofRefreshContext
local queueGeneration = ctx.queueGeneration

DevSaveSchemaGate.configureRecordGeometry({ ServerSchema = ServerSchema })
local function currentMappingRecord(rvId, generation, bitmapVersion)
    local adapter = RailroaderRV and RailroaderRV.RailroaderServer
    if type(adapter) ~= "table"
        or type(adapter.currentMappingRecord) ~= "function" then
        return false, Constants.INVALID_RV_DATA
    end
    local ok, accepted, record = pcall(adapter.currentMappingRecord,
        rvId, generation, bitmapVersion)
    if not ok or accepted ~= true or type(record) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    return true, record
end

local function manifestViewForRecord(record)
    if type(record) ~= "table" or type(record.anchor) ~= "table"
        or type(record.boundary) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local ok, manifest = pcall(function()
        local anchor = { x = ServerUtil.integer(record.anchor.x),
            y = ServerUtil.integer(record.anchor.y),
            z = ServerUtil.integer(record.anchor.z) }
        local layout = Layout.make(anchor.x, anchor.y, anchor.z)
        local bounds = ServerSchema.boundsFor(layout)
        local updatedAt = ServerUtil.integer(record.updatedAt)
        local generation = ServerUtil.integer(record.generation)
        local bitmapVersion = ServerUtil.integer(record.bitmapVersion)
        local snapshot = {
            schemaVersion = Constants.MANIFEST_SCHEMA_VERSION,
            techVersion = Constants.TECH_VERSION,
            templateVersion = Constants.CAPTURED_TEMPLATE_VERSION,
            generation = generation,
            owner = ctx.OWNER,
            slotIndex = ServerUtil.integer(record.slotIndex),
            anchor = anchor,
            bounds = bounds,
            rvId = tostring(record.rvId),
            boundarySchemaVersion = Constants.BOUNDARY_SCHEMA_VERSION,
            bitmapVersion = bitmapVersion,
            boundary = record.boundary,
            startedAt = updatedAt,
            state = "READY",
            updatedAt = updatedAt,
            phase = "COMMITTED",
            phaseGeneration = generation,
            phaseUpdatedAt = updatedAt,
            completedAt = updatedAt,
        }
        if updatedAt == nil or generation == nil or bitmapVersion == nil then
            error(Constants.INVALID_RV_DATA)
        end
        requireCurrentManifest(snapshot, false)
        return snapshot
    end)
    if not ok or type(manifest) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    return true, manifest
end

local function manifestForIdentity(rvId, generation, bitmapVersion,
    allowRunning)
    local manifestOk, persisted = pcall(manifestTable)
    if not manifestOk or type(persisted) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local schemaOk = pcall(requireCurrentManifest, persisted, false)
    if not schemaOk then return false, Constants.INVALID_RV_DATA end
    local identityMatches = tostring(persisted.rvId) == tostring(rvId)
        and ServerUtil.integer(persisted.generation) == ServerUtil.integer(generation)
        and ServerUtil.integer(persisted.bitmapVersion) == ServerUtil.integer(bitmapVersion)
    if identityMatches and persisted.state == "RUNNING" then
        local pending = ctx.pendingGeneration
        local activeRunning = allowRunning == true
            and type(pending) == "table"
            and tostring(pending.rvId) == tostring(rvId)
            and ServerUtil.integer(pending.generation) == ServerUtil.integer(generation)
            and ServerUtil.integer(pending.bitmapVersion)
                == ServerUtil.integer(bitmapVersion)
        if activeRunning then return true, persisted end
    end
    -- The ModData manifest is a single transaction record. A READY identity
    -- used for ordinary RV operations must be rebuilt from its current strict
    -- Mapping record. An unrelated transaction state must not hide another
    -- RV; a non-READY state for this same RV remains a hard rejection.
    if tostring(persisted.rvId) == tostring(rvId) then
        if not identityMatches or persisted.state ~= "READY" then
            return false, Constants.INVALID_RV_DATA
        end
    end
    local recordOk, record = currentMappingRecord(rvId, generation, bitmapVersion)
    if not recordOk then return false, record end
    local viewOk, view = manifestViewForRecord(record)
    if not viewOk then return false, view end
    local comparison = identityMatches and persisted or view
    local geometryOk, consistent = pcall(
        RV.Server.currentRVRecordGeometryConsistent, record, comparison)
    if not geometryOk or consistent ~= true then
        return false, Constants.INVALID_RV_DATA
    end
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

-- Read-only current-schema gate for the stateless -15 sentinel.  It returns
-- the manifest only after the same strict validator used by normal entry has
-- checked the persisted boundary/bitmap contract; it never repairs or writes.
function RV.Server.currentRVManifestForRelocation(rvId, generation,
    bitmapVersion)
    return manifestForIdentity(rvId, generation, bitmapVersion, false)
end

-- BoundaryServer needs the same strict manifest/geometry identity while a
-- generation is still RUNNING (the normal roof/entry guard must not require
-- READY until the final acknowledgement commits it).  This narrow hook keeps
-- that exception explicit and still rejects FAILED/partial/unknown schemas.
function RV.Server.currentRVManifestForBoundary(rvId, generation,
    bitmapVersion)
    return manifestForIdentity(rvId, generation, bitmapVersion, true)
end

local function currentRVRecordGeometryConsistent(record, manifest)

    if not DevSaveSchemaGate.isReady() or type(record) ~= "table"
        or type(manifest) ~= "table" or record.generated ~= true then
        return false
    end
    local generation = ServerUtil.integer(record.generation)
    local bitmapVersion = ServerUtil.integer(record.bitmapVersion)
    local boundary = record.boundary
    local manifestBoundary = manifest.boundary
    if type(record.rvId) ~= "string" or record.rvId == ""
        or tostring(record.locoId) ~= record.rvId
        or tostring(manifest.rvId) ~= record.rvId
        or generation == nil or generation < 1
        or generation ~= ServerUtil.integer(manifest.generation)
        or bitmapVersion ~= Constants.BITMAP_VERSION
        or bitmapVersion ~= ServerUtil.integer(manifest.bitmapVersion)
        or type(boundary) ~= "table" or type(manifestBoundary) ~= "table"
        or tostring(boundary.rvId) ~= record.rvId
        or tostring(manifestBoundary.rvId) ~= record.rvId
        or ServerUtil.integer(boundary.generation) ~= generation
        or ServerUtil.integer(manifestBoundary.generation) ~= generation
        or ServerUtil.integer(boundary.bitmapVersion) ~= bitmapVersion
        or ServerUtil.integer(manifestBoundary.bitmapVersion) ~= bitmapVersion
        or type(record.managed) ~= "table"
        or type(boundary.managed) ~= "table"
        or type(manifestBoundary.managed) ~= "table" then
        return false
    end
    local fields = { "originX", "originY", "width", "height", "minZ", "maxZ" }
    for i = 1, #fields do
        local field = fields[i]
        local value = ServerUtil.integer(record.managed[field])
        if value == nil or value ~= ServerUtil.integer(boundary.managed[field])
            or value ~= ServerUtil.integer(manifestBoundary.managed[field]) then
            return false
        end
    end
    return true
end

RV.Server.currentRVRecordGeometryConsistent = currentRVRecordGeometryConsistent

-- Narrow current-only gate for adapter Enter/Exit mutations. Callers do not
-- supply a manifest snapshot: the service resolves current mapping and
-- manifest identities, then compares their live managed bounds.
function RV.Server.validateCurrentRVRecord(record)
    if type(record) ~= "table" or type(record.rvId) ~= "string"
        or record.rvId == "" then
        return false, Constants.INVALID_RV_DATA
    end
    local manifestCallOk, manifestAccepted, manifestOrReason = pcall(
        RV.Server.currentRVManifestForRelocation, record.rvId,
        record.generation, record.bitmapVersion)
    if not manifestCallOk or manifestAccepted ~= true
        or type(manifestOrReason) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local geometryCallOk, consistent = pcall(
        RV.Server.currentRVRecordGeometryConsistent, record, manifestOrReason)
    if not geometryCallOk or consistent ~= true then
        return false, Constants.INVALID_RV_DATA
    end
    return true, manifestOrReason
end

-- Rebuild the captured south-window floor's room/roof neighbours after an
-- existing RV entry or reconnect. The current manifest gate must pass before
-- persisted geometry or generation identity reaches the roof refresh helper.
function RV.Server.refreshRoofVisuals(player, record)
    if not RoofRefresh then
        return false, "roof refresh module is unavailable"
    end
    if type(record) ~= "table" then return false, Constants.INVALID_RV_DATA end
    local manifestOk, manifest = RV.Server.currentRVManifestForRelocation(
        record.rvId, record.generation, record.bitmapVersion)
    if not manifestOk or type(manifest) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then return false, identityOrReason end
    local contextOk, contextOrReason = currentRoofRefreshContext(player, {
        rvId = manifest.rvId,
        generation = manifest.generation,
        bitmapVersion = manifest.bitmapVersion,
        identityKey = identityOrReason.key,
    })
    if not contextOk then return false, contextOrReason end
    local bounds = manifest.bounds
    local ok, result, reason = pcall(RoofRefresh.run, player, bounds, {
        rvId = manifest.rvId,
        generation = manifest.generation,
        bitmapVersion = manifest.bitmapVersion,
    })
    if not ok then return false, safeErrorText(result) end
    return result == true, reason
end

-- Re-arm a client's persistent stale-room monitor when it enters an already
-- generated RV or appears after reconnect. The mapping record is checked for
-- the current schema/identity, then its anchor and boundary rebuild a strict
-- current manifest view for this RV. No client state or caller-supplied bounds
-- participate in this command.
function RV.Server.armCurrentRoomOwnershipMonitor(player, record)
    if type(record) ~= "table"
        or record.generated ~= true
        or record.locoId == nil or tostring(record.locoId) == ""
        or record.rvId == nil or tostring(record.rvId) ~= tostring(record.locoId)
        or type(record.boundary) ~= "table"
        or type(record.boundary.managed) ~= "table"
        or type(record.boundary.bitmap) ~= "table"
        or type(record.boundary.shellEdges) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local recordGeneration = ServerUtil.toNumber(record.generation)
    if not ServerUtil.isFiniteNumber(recordGeneration) or math.floor(recordGeneration)
        ~= recordGeneration or recordGeneration < 1 then
        return false, Constants.INVALID_RV_DATA
    end
    local recordBitmapVersion = ServerUtil.toNumber(record.bitmapVersion)
    local boundaryGeneration = ServerUtil.toNumber(record.boundary.generation)
    local boundaryBitmapVersion = ServerUtil.toNumber(record.boundary.bitmapVersion)
    if recordBitmapVersion ~= Constants.BITMAP_VERSION
        or tostring(record.boundary.rvId) ~= tostring(record.rvId)
        or boundaryGeneration ~= recordGeneration
        or boundaryBitmapVersion ~= recordBitmapVersion then
        return false, Constants.INVALID_RV_DATA
    end

    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then return false, identityOrReason end
    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local manifestAccepted, manifest = RV.Server.currentRVManifestForBoundary(
        record.rvId, recordGeneration, recordBitmapVersion)
    if manifestAccepted ~= true or type(manifest) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    if manifest.state ~= "READY" then
        return false, "RV manifest is not READY"
    end
    local manifestGeneration = ServerUtil.toNumber(manifest.generation)
    local manifestBitmapVersion = ServerUtil.toNumber(manifest.bitmapVersion)
    if tostring(manifest.rvId) ~= tostring(record.rvId)
        or manifestGeneration ~= recordGeneration
        or manifestBitmapVersion ~= recordBitmapVersion
        or tostring(manifest.boundary.rvId) ~= tostring(record.rvId)
        or ServerUtil.toNumber(manifest.boundary.generation) ~= recordGeneration
        or ServerUtil.toNumber(manifest.boundary.bitmapVersion) ~= recordBitmapVersion then
        return false, Constants.INVALID_RV_DATA
    end

    local armedOk, armedError = pcall(armTargetedClientRoomOwnershipGuard,
        player, recordGeneration, manifest.bounds, record.rvId,
        recordBitmapVersion)
    if not armedOk then
        return false, safeErrorText(armedError)
    end
    print("[RailroaderRVTest] targeted room ownership monitor armed player="
        .. tostring(identityOrReason.key) .. " rvId=" .. tostring(record.rvId)
        .. " generation=" .. tostring(recordGeneration)
        .. " bitmapVersion=" .. tostring(recordBitmapVersion))
    return true
end


end
