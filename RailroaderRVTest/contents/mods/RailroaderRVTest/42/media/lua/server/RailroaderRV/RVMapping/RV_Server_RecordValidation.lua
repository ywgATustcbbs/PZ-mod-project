-- RV_Server: RecordValidation responsibilities.
return function(ctx)
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
local currentManifestValid = ctx.currentManifestValid
local currentRoofRefreshContext = ctx.currentRoofRefreshContext
local queueGeneration = ctx.queueGeneration

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

-- Cross-object current-geometry gate shared by boundary/roof/sentinel paths.
-- The map record and manifest are independently persisted snapshots, so an
-- identity tuple alone is insufficient: a stale bitmap, bounds, wall ledger,
-- shell edge set, or region must fail closed even when rvId/generation still
-- match.  This helper is read-only apart from registering the validated
-- current boundary snapshot in Boundary's process-local cache.
function RV.Server.currentRVRecordGeometryConsistent(record, manifest)
    local function exactKeys(value, fields)
        if type(value) ~= "table" then return false end
        local allowed = {}
        for i = 1, #fields do allowed[fields[i]] = true end
        for key in pairs(value) do
            if not allowed[key] then return false end
        end
        for i = 1, #fields do
            if value[fields[i]] == nil then return false end
        end
        return true
    end

    local function integerFieldsEqual(left, right, fields)
        if not exactKeys(left, fields) or not exactKeys(right, fields) then
            return false
        end
        for i = 1, #fields do
            if ServerUtil.integer(left[fields[i]]) ~= ServerUtil.integer(right[fields[i]]) then
                return false
            end
        end
        return true
    end

    local function integerFieldsMatch(left, right, fields)
        if type(left) ~= "table" or type(right) ~= "table" then return false end
        for i = 1, #fields do
            if ServerUtil.integer(left[fields[i]]) ~= ServerUtil.integer(right[fields[i]]) then
                return false
            end
        end
        return true
    end

    local managedFields = { "originX", "originY", "width", "height",
        "minZ", "maxZ" }
    local boundaryFields = { "schemaVersion", "rvId", "generation",
        "bitmapVersion", "managed", "bitmap", "shellEdges" }
    local shellFields = { "edgeKey", "rvId", "generation", "bitmapVersion",
        "hostX", "hostY", "z", "axis", "side", "objectX", "objectY",
        "objectZ", "role", "corner", "replacementAllowed",
        "templateIndex", "templateIndices", "sprite", "north" }
    local boundsShellFields = { "edgeKey", "hostX", "hostY", "z", "axis",
        "side", "objectX", "objectY", "objectZ", "role", "corner",
        "replacementAllowed", "templateIndex", "templateIndices", "sprite", "north" }
    local regionFields = { "minX", "minY", "maxX", "maxY", "minZ", "maxZ" }

    if type(record) ~= "table" or type(manifest) ~= "table"
        or record.generated ~= true
        or type(record.boundary) ~= "table"
        or type(manifest.boundary) ~= "table"
        or type(manifest.bounds) ~= "table"
        or type(manifest.anchor) ~= "table"
        or ServerUtil.integer(record.slotIndex) ~= ServerUtil.integer(manifest.slotIndex)
        or ServerUtil.integer(record.anchor and record.anchor.x)
            ~= ServerUtil.integer(manifest.anchor.x)
        or ServerUtil.integer(record.anchor and record.anchor.y)
            ~= ServerUtil.integer(manifest.anchor.y)
        or ServerUtil.integer(record.anchor and record.anchor.z)
            ~= ServerUtil.integer(manifest.anchor.z) then
        return false
    end
    local recordGeneration, manifestGeneration = ServerUtil.integer(record.generation),
        ServerUtil.integer(manifest.generation)
    local recordBitmapVersion, manifestBitmapVersion = ServerUtil.integer(record.bitmapVersion),
        ServerUtil.integer(manifest.bitmapVersion)
    if type(record.rvId) ~= "string" or record.rvId == ""
        or tostring(record.locoId) ~= record.rvId
        or tostring(manifest.rvId) ~= record.rvId
        or recordGeneration == nil or recordGeneration < 1
        or recordGeneration ~= manifestGeneration
        or recordBitmapVersion ~= Constants.BITMAP_VERSION
        or manifestBitmapVersion ~= recordBitmapVersion
        or ServerUtil.integer(record.schemaVersion) ~= Constants.RV_RECORD_SCHEMA_VERSION
        or ServerUtil.integer(record.boundarySchemaVersion) ~= Constants.BOUNDARY_SCHEMA_VERSION
        or ServerUtil.integer(manifest.schemaVersion) ~= Constants.MANIFEST_SCHEMA_VERSION
        or manifest.techVersion ~= Constants.TECH_VERSION
        or ServerUtil.integer(manifest.templateVersion)
            ~= Constants.CAPTURED_TEMPLATE_VERSION
        or ServerUtil.integer(manifest.boundarySchemaVersion)
            ~= Constants.BOUNDARY_SCHEMA_VERSION
        or ServerUtil.integer(record.boundary.schemaVersion)
            ~= Constants.BOUNDARY_SCHEMA_VERSION
        or ServerUtil.integer(manifest.boundary.schemaVersion)
            ~= Constants.BOUNDARY_SCHEMA_VERSION
        or tostring(record.boundary.rvId) ~= record.rvId
        or tostring(manifest.boundary.rvId) ~= record.rvId
        or ServerUtil.integer(record.boundary.generation) ~= recordGeneration
        or ServerUtil.integer(manifest.boundary.generation) ~= recordGeneration
        or ServerUtil.integer(record.boundary.bitmapVersion) ~= recordBitmapVersion
        or ServerUtil.integer(manifest.boundary.bitmapVersion) ~= recordBitmapVersion
        or not exactKeys(record.boundary, boundaryFields)
        or not exactKeys(manifest.boundary, boundaryFields) then
        return false
    end

    local decoded = {}
    local function decodeCurrent(encoded)
        if not Bitmap or type(Bitmap.decode) ~= "function"
            or type(Bitmap.validate) ~= "function" then
            return nil
        end
        local decodeOk, bitmap = pcall(Bitmap.decode, encoded)
        if not decodeOk or type(bitmap) ~= "table" then return nil end
        local validOk, valid = pcall(Bitmap.validate, bitmap)
        if not validOk or valid ~= true then return nil end
        return bitmap
    end
    decoded.record = decodeCurrent(record.boundary.bitmap)
    decoded.manifest = decodeCurrent(manifest.boundary.bitmap)
    if not decoded.record or not decoded.manifest then return false end

    local function bitmapsEqual(left, right)
        if not integerFieldsMatch(left, right, managedFields)
            or ServerUtil.integer(left.bitmapVersion) ~= ServerUtil.integer(right.bitmapVersion) then
            return false
        end
        for z = left.minZ, left.maxZ - 1 do
            local leftLayer, rightLayer = Bitmap.layer(left, z),
                Bitmap.layer(right, z)
            if type(leftLayer) ~= "table" or type(rightLayer) ~= "table"
                or leftLayer.walkBits ~= rightLayer.walkBits
                or leftLayer.buildBits ~= rightLayer.buildBits then
                return false
            end
        end
        return true
    end
    local bitmapCompareOk, bitmapSame = pcall(bitmapsEqual, decoded.record,
        decoded.manifest)
    if not bitmapCompareOk or bitmapSame ~= true
        or not integerFieldsEqual(record.boundary.managed,
            manifest.boundary.managed, managedFields)
        or not integerFieldsEqual(record.managed, record.boundary.managed,
            managedFields) then
        return false
    end
    if not integerFieldsMatch(decoded.record, record.boundary.managed,
            managedFields)
        or not integerFieldsMatch(decoded.manifest, manifest.boundary.managed,
            managedFields) then
        return false
    end

    local function integerArraysEqual(left, right)
        if type(left) ~= "table" or type(right) ~= "table"
            or #left < 1 or #left ~= #right then
            return false
        end
        local leftCount, rightCount = 0, 0
        for key in pairs(left) do
            leftCount = leftCount + 1
            if type(key) ~= "number" or key < 1 or math.floor(key) ~= key
                or key > #left or ServerUtil.integer(left[key]) == nil then
                return false
            end
        end
        for key in pairs(right) do
            rightCount = rightCount + 1
            if type(key) ~= "number" or key < 1 or math.floor(key) ~= key
                or key > #right or ServerUtil.integer(right[key]) == nil then
                return false
            end
        end
        if leftCount ~= #left or rightCount ~= #right then return false end
        for i = 1, #left do
            if ServerUtil.integer(left[i]) ~= ServerUtil.integer(right[i]) then
                return false
            end
        end
        return true
    end

    local function shellSetEqual(left, right)
        if type(left) ~= "table" or type(right) ~= "table" then return false end
        local leftCount, rightCount = 0, 0
        for key, edge in pairs(left) do
            leftCount = leftCount + 1
            local other = right[key]
            if type(key) ~= "string" or type(edge) ~= "table"
                or type(other) ~= "table"
                or not exactKeys(edge, shellFields)
                or not exactKeys(other, shellFields) then
                return false
            end
            for i = 1, #shellFields do
                local field = shellFields[i]
                if field ~= "templateIndices" and edge[field] ~= other[field] then
                    return false
                end
            end
            if not integerArraysEqual(edge.templateIndices, other.templateIndices) then
                return false
            end
        end
        for _ in pairs(right) do rightCount = rightCount + 1 end
        return leftCount == rightCount
    end
    if not shellSetEqual(record.boundary.shellEdges,
            manifest.boundary.shellEdges) then
        return false
    end

    -- The manifest wall/shell contract is already validated by the strict
    -- current-only validator.  Re-run it here so this public cross-object
    -- hook remains safe when a caller reaches it without first calling the
    -- manifest helper.
    local manifestValidOk, manifestValid = pcall(currentManifestValid,
        manifest, false)
    if not manifestValidOk or manifestValid ~= true then return false end
    -- currentManifestValid also gates this snapshot for normal callers, but
    -- keep the cross-object contract explicit here: bounds.bitmap is a
    -- decoded current-layout bitmap and must be byte/bit identical to the
    -- encoded boundary bitmap and the record copy before any consumer uses
    -- the center, region, or shell geometry.
    local boundsBitmap = manifest.bounds and manifest.bounds.bitmap
    local boundsBitmapOk, boundsBitmapValid = false, false
    if Bitmap and type(Bitmap.validate) == "function" then
        boundsBitmapOk, boundsBitmapValid = pcall(Bitmap.validate, boundsBitmap)
    end
    if not boundsBitmapOk or boundsBitmapValid ~= true
        or not bitmapsEqual(boundsBitmap, decoded.manifest) then
        return false
    end
    local bounds = manifest.bounds
    local boundsShell = bounds.shellEdges
    for key, edge in pairs(record.boundary.shellEdges) do
        local boundEdge = type(boundsShell) == "table" and boundsShell[key]
            or nil
        if type(boundEdge) ~= "table"
            or not exactKeys(boundEdge, boundsShellFields) then
            return false
        end
        for i = 1, #boundsShellFields do
            local field = boundsShellFields[i]
            if field ~= "templateIndices" and edge[field] ~= boundEdge[field] then
                return false
            end
        end
        if not integerArraysEqual(edge.templateIndices, boundEdge.templateIndices) then
            return false
        end
    end
    local boundaryCount, boundsCount = 0, 0
    for _ in pairs(record.boundary.shellEdges) do boundaryCount = boundaryCount + 1 end
    for _ in pairs(boundsShell or {}) do boundsCount = boundsCount + 1 end
    if boundaryCount ~= boundsCount then return false end

    local anchor = manifest.anchor
    if not exactKeys(anchor, { "x", "y", "z" })
        or ServerUtil.integer(anchor.x) == nil or ServerUtil.integer(anchor.y) == nil
        or ServerUtil.integer(anchor.z) == nil then
        return false
    end
    local anchorX, anchorY, anchorZ = ServerUtil.integer(anchor.x), ServerUtil.integer(anchor.y),
        ServerUtil.integer(anchor.z)
    local boundsManaged = {
        originX = ServerUtil.integer(bounds.managedOriginX),
        originY = ServerUtil.integer(bounds.managedOriginY),
        width = ServerUtil.integer(bounds.managedWidth),
        height = ServerUtil.integer(bounds.managedHeight),
        minZ = ServerUtil.integer(bounds.managedMinZ),
        maxZ = ServerUtil.integer(bounds.managedMaxZ),
    }
    if not integerFieldsEqual(boundsManaged, record.managed, managedFields)
        or anchorX ~= boundsManaged.originX + math.floor(boundsManaged.width / 2)
        or anchorY ~= boundsManaged.originY + math.floor(boundsManaged.height / 2)
        or anchorZ ~= ServerUtil.integer(bounds.z)
        or type(record.rvPosition) ~= "table"
        or not exactKeys(record.rvPosition, { "x", "y", "z" })
        or ServerUtil.toNumber(record.rvPosition.x) ~= anchorX + 0.5
        or ServerUtil.toNumber(record.rvPosition.y) ~= anchorY + 0.5
        or ServerUtil.toNumber(record.rvPosition.z) ~= anchorZ then
        return false
    end

    local regionSize = ServerUtil.integer(Constants.RV_REGION_SIZE)
    local regionMinXOffset = ServerUtil.integer(Constants.RV_REGION_MIN_OFFSET_X)
    local regionMinYOffset = ServerUtil.integer(Constants.RV_REGION_MIN_OFFSET_Y)
    local identityMinZ = ServerUtil.integer(Constants.RV_IDENTITY_MIN_Z)
    local identityMaxZ = ServerUtil.integer(Constants.RV_IDENTITY_MAX_Z)
    if not regionSize or not regionMinXOffset or not regionMinYOffset
        or not identityMinZ or not identityMaxZ or identityMaxZ <= identityMinZ then
        return false
    end
    local expectedRegion = {
        minX = anchorX + regionMinXOffset,
        minY = anchorY + regionMinYOffset,
        maxX = anchorX + regionMinXOffset + regionSize,
        maxY = anchorY + regionMinYOffset + regionSize,
        minZ = identityMinZ,
        maxZ = identityMaxZ,
    }
    if not integerFieldsEqual(record.region, expectedRegion, regionFields) then
        return false
    end

    if not Boundary or type(Boundary.registerGeneration) ~= "function" then
        return false
    end
    local registerOk, registered = pcall(Boundary.registerGeneration,
        record.rvId, recordGeneration, record.boundary, record)
    return registerOk and registered == true
end

-- Narrow current-only gate for adapter Enter/Exit mutations.  Callers do not
-- supply a manifest snapshot: the service reads the current persisted
-- manifest, requires the READY/COMMITTED contract, and then reuses the full
-- cross-object geometry validator above.  A failed gate has one stable public
-- result so an adapter cannot accidentally continue with a partial snapshot.
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
    local recordSchemaVersion = ServerUtil.toNumber(record.schemaVersion)
    local recordBoundarySchemaVersion = ServerUtil.toNumber(record.boundarySchemaVersion)
    local boundarySchemaVersion = ServerUtil.toNumber(record.boundary.schemaVersion)
    if recordSchemaVersion ~= Constants.RV_RECORD_SCHEMA_VERSION
        or recordBoundarySchemaVersion ~= Constants.BOUNDARY_SCHEMA_VERSION
        or boundarySchemaVersion ~= Constants.BOUNDARY_SCHEMA_VERSION then
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
