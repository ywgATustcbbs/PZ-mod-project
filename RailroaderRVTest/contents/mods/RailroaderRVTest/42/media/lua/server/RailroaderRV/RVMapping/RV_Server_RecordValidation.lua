-- RV_Server: RecordValidation responsibilities.
return function(ctx)
local Constants = ctx.Constants
local ServerSchema = ctx.ServerSchema
local RoofRefresh = ctx.RoofRefresh
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
local function safeErrorText(...) return ctx.safeErrorText(...) end
local armTargetedClientRoomOwnershipGuard = ctx.armTargetedClientRoomOwnershipGuard
local manifestTable = ctx.manifestTable
local playerIdentity = ctx.playerIdentity
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
            techVersion = Constants.TECH_VERSION,
            templateVersion = Constants.CAPTURED_TEMPLATE_VERSION,
            generation = generation,
            owner = ctx.OWNER,
            slotIndex = ServerUtil.integer(record.slotIndex),
            anchor = anchor,
            bounds = bounds,
            rvId = tostring(record.rvId),
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
        return snapshot
    end)
    if not ok or type(manifest) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    return true, manifest
end

local function manifestForIdentity(rvId, generation, bitmapVersion,
    allowRunning)
    local recordOk, record = currentMappingRecord(rvId, generation, bitmapVersion)
    if not recordOk then return false, record end
    local manifestOk, persisted = pcall(manifestTable)
    if not manifestOk or type(persisted) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local identityMatches = tostring(persisted.rvId) == tostring(rvId)
        and ServerUtil.integer(persisted.generation) == ServerUtil.integer(generation)
        and ServerUtil.integer(persisted.bitmapVersion) == ServerUtil.integer(bitmapVersion)
    if tostring(persisted.rvId) == tostring(rvId) then
        if not identityMatches then return false, Constants.INVALID_RV_DATA end
        if persisted.state == "RUNNING" then
            local transaction = ctx.GenerationTransaction
            local transactionOk, pending = false, nil
            if type(transaction) == "table"
                and type(transaction.current) == "function" then
                transactionOk, pending = pcall(transaction.current)
            end
            local activeRunning = allowRunning == true
                and transactionOk == true
                and type(pending) == "table"
                and tostring(pending.rvId) == tostring(rvId)
                and ServerUtil.integer(pending.generation)
                    == ServerUtil.integer(generation)
                and ServerUtil.integer(pending.bitmapVersion)
                    == ServerUtil.integer(bitmapVersion)
            if activeRunning then return true, persisted end
            return false, Constants.INVALID_RV_DATA
        end
        if persisted.state == "READY" then return true, persisted end
        return false, Constants.INVALID_RV_DATA
    end
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
function RV.Server.currentRVManifestForRelocation(rvId, generation,
    bitmapVersion)
    return manifestForIdentity(rvId, generation, bitmapVersion, false)
end

-- BoundaryServer may inspect the current identity while generation is still
-- RUNNING; ordinary relocation reads require READY.
function RV.Server.currentRVManifestForBoundary(rvId, generation,
    bitmapVersion)
    return manifestForIdentity(rvId, generation, bitmapVersion, true)
end

-- Rebuild the captured south-window floor's room/roof neighbours after an
-- existing RV entry or reconnect.
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
-- generated RV or appears after reconnect. The mapping identity, anchor and
-- boundary rebuild a strict
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
