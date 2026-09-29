-- Internal server-only RV construction gates.
--
-- GenerationFlow remains the only player-command path. This module verifies
-- its server-prepared manifest/layout identity before calling the existing
-- clear and build operations; restore is limited to a current managed cell.
local Constants = require("RailroaderRV/Common/RV_Constants")
local Bitmap = require("RailroaderRV/Common/RV_Bitmap")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")

local Construction = {}

local function validPoint(point)
    return type(point) == "table"
        and Constants.finiteInteger(point.x) ~= nil
        and Constants.finiteInteger(point.y) ~= nil
        and Constants.finiteInteger(point.z) ~= nil
end

local function samePoint(left, right)
    return validPoint(left) and validPoint(right)
        and left.x == right.x and left.y == right.y and left.z == right.z
end

local function currentIdentity(manifest, generation)
    if type(manifest) ~= "table" then return nil end
    local rvId = manifest.rvId
    local manifestGeneration = Constants.finiteInteger(manifest.generation)
    local bitmapVersion = Constants.finiteInteger(manifest.bitmapVersion)
    local slotIndex = Constants.finiteInteger(manifest.slotIndex)
    local anchor = manifest.anchor
    if type(rvId) ~= "string" or rvId == ""
        or manifestGeneration == nil or manifestGeneration < 1
        or manifestGeneration ~= generation
        or bitmapVersion ~= Constants.BITMAP_VERSION
        or slotIndex == nil or slotIndex < 1
        or slotIndex > RegionSlots.COUNT
        or not validPoint(anchor)
        or RegionSlots.indexForAnchor(anchor) ~= slotIndex then
        return nil
    end
    return {
        rvId = rvId,
        generation = manifestGeneration,
        bitmapVersion = bitmapVersion,
        slotIndex = slotIndex,
        anchor = { x = anchor.x, y = anchor.y, z = anchor.z },
    }
end

local function sameIdentity(left, right)
    return type(left) == "table" and type(right) == "table"
        and left.rvId == right.rvId
        and left.generation == right.generation
        and left.bitmapVersion == right.bitmapVersion
        and left.slotIndex == right.slotIndex
        and samePoint(left.anchor, right.anchor)
end

local function currentTemplate()
    local template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
    local valid, reason = RoomTemplate.validate(template)
    if not valid or type(RoomTemplate.orderedObjects(template)) ~= "table"
        or template.metadata.templateVersion ~= Constants.CAPTURED_TEMPLATE_VERSION then
        return nil, reason or "current RoomTemplate object index is incomplete"
    end
    return template
end

local function sameBounds(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    local keys = {
        "clearMinX", "clearMaxX", "clearMinY", "clearMaxY",
        "clearMinZ", "clearMaxZ", "managedOriginX", "managedOriginY",
        "managedWidth", "managedHeight", "managedMinZ", "managedMaxZ",
        "roomMinX", "roomMaxX", "roomMinY", "roomMaxY", "roomZ",
        "wallMinX", "wallMaxX", "wallMinY", "wallMaxY", "wallZ",
        "roofMinX", "roofMaxX", "roofMinY", "roofMaxY", "roofZ",
        "wallObjectCount", "wallCoordinateCount", "northEdges", "westEdges",
        "wallCornerCount", "z",
    }
    for index = 1, #keys do
        local key = keys[index]
        if Constants.finiteInteger(left[key]) == nil
            or Constants.finiteInteger(right[key]) == nil
            or left[key] ~= right[key] then
            return false
        end
    end
    local function samePlainTree(leftValue, rightValue)
        if type(leftValue) ~= type(rightValue) then return false end
        if type(leftValue) ~= "table" then return leftValue == rightValue end
        local count = 0
        for key, nested in pairs(leftValue) do
            count = count + 1
            if rightValue[key] == nil
                or not samePlainTree(nested, rightValue[key]) then
                return false
            end
        end
        local rightCount = 0
        for _ in pairs(rightValue) do rightCount = rightCount + 1 end
        return count == rightCount
    end
    if type(left.bitmap) ~= "table" or type(right.bitmap) ~= "table"
        or type(Bitmap.encode) ~= "function" then
        return false
    end
    local leftBitmap, rightBitmap = Bitmap.encode(left.bitmap),
        Bitmap.encode(right.bitmap)
    return type(leftBitmap) == "table" and type(rightBitmap) == "table"
        and samePlainTree(leftBitmap, rightBitmap)
        and samePlainTree(left.shellEdges, right.shellEdges)
        and samePlainTree(left.wallCoordinates, right.wallCoordinates)
end

function Construction.new(context, operations)
    if type(context) ~= "table" or type(operations) ~= "table"
        or type(operations.clear) ~= "function"
        or type(operations.build) ~= "function"
        or type(operations.setGenerationPhase) ~= "function" then
        error("RailroaderRVTest: Construction dependencies are incomplete")
    end

    local service = {}

    local function validatePlannedGeometry(player, layout, bounds, generation,
        identitySource)
        if context.transactionBusy ~= true or context.transactionPlayer ~= player
            or player == nil then
            error("RailroaderRVTest: Construction requires the active server transaction")
        end
        local template, templateError = currentTemplate()
        if not template then
            error("RailroaderRVTest: current RoomTemplate is invalid: "
                .. tostring(templateError))
        end
        local identity = currentIdentity(identitySource, generation)
        if not identity then
            error("RailroaderRVTest: current generation identity is invalid")
        end
        if type(layout) ~= "table" or not samePoint(layout.anchor, identity.anchor)
            or type(bounds) ~= "table" then
            error("RailroaderRVTest: Construction layout and identity do not match")
        end
        local recomputedOk, recomputed = pcall(context.ServerSchema.boundsFor, layout)
        if not recomputedOk or not sameBounds(bounds, recomputed)
            or bounds.clearMaxX - bounds.clearMinX ~= Constants.RV_MANAGED_WIDTH
            or bounds.clearMaxY - bounds.clearMinY ~= Constants.RV_MANAGED_HEIGHT
            or bounds.clearMinZ ~= bounds.managedMinZ
            or bounds.clearMaxZ ~= bounds.managedMaxZ
            or bounds.clearMinZ >= bounds.clearMaxZ then
            error("RailroaderRVTest: Construction bounds are not the current managed layout")
        end
        return identity, template
    end

    local function preflightClearTarget(player, cell, layout, bounds,
        generation, identitySource, existingManifest)
        local identity = validatePlannedGeometry(player, layout, bounds,
            generation, identitySource)
        local world = context.ServerWorld
        local schema = context.ServerSchema
        if type(world) ~= "table"
            or type(world.strictSquareSnapshot) ~= "function"
            or type(world.isPlayerObject) ~= "function"
            or type(schema) ~= "table" or type(schema.walkBounds) ~= "function" then
            error("RailroaderRVTest: Construction clear preflight APIs are unavailable")
        end

        -- There is no complete inverse snapshot for deleting an old
        -- generation. Existing objects therefore cannot authorize a clear,
        -- even when their tags match a former current identity.
        if type(existingManifest) == "table" then
            local oldGeneration = Constants.finiteInteger(existingManifest.generation)
            local oldIdentity = oldGeneration and currentIdentity(existingManifest,
                oldGeneration) or nil
            if oldIdentity and oldIdentity.rvId == identity.rvId
                and oldIdentity.slotIndex == identity.slotIndex
                and samePoint(oldIdentity.anchor, identity.anchor)
                and sameBounds(existingManifest.bounds, bounds) then
                error("RailroaderRVTest: same-slot rebuild is refused because "
                    .. "the previous generation has no complete undo snapshot")
            end
        end

        -- The clear bounds can contain absent squares. walkBounds visits only
        -- squares the cell actually has; a nil result is not a reason to
        -- reject construction or to materialize an empty square.
        schema.walkBounds(cell, bounds, function(square)
            local snapshotOk, objects, complete = pcall(
                world.strictSquareSnapshot, square)
            if not snapshotOk or type(objects) ~= "table" or complete ~= true then
                error("RailroaderRVTest: Construction clear occupancy cannot be verified")
            end
            for index = 1, #objects do
                local object = objects[index]
                local playerOk, isPlayer = pcall(world.isPlayerObject, object)
                if not playerOk or isPlayer == true then
                    error("RailroaderRVTest: Construction clear scope contains a player")
                end
                error("RailroaderRVTest: Construction clear scope contains an object; "
                    .. "clearing requires an empty scope because no complete undo "
                    .. "snapshot is available")
            end
        end)
        return true
    end

    function service.preflightCurrentGeneration(player, cell, layout, bounds,
        generation, identitySource, existingManifest)
        return preflightClearTarget(player, cell, layout, bounds, generation,
            identitySource, existingManifest)
    end

    local function validateCurrentPlan(player, layout, bounds, generation, manifest)
        local identity = currentIdentity(manifest, generation)
        if not identity or manifest.owner ~= Constants.MOD_ID
            or manifest.schemaVersion ~= Constants.MANIFEST_SCHEMA_VERSION
            or manifest.templateVersion ~= Constants.CAPTURED_TEMPLATE_VERSION
            or manifest.state ~= "RUNNING" then
            error("RailroaderRVTest: current generation identity is invalid")
        end
        if type(manifest.bounds) ~= "table"
            or not sameBounds(bounds, manifest.bounds) then
            error("RailroaderRVTest: Construction layout and manifest do not match")
        end
        local checkedIdentity, template = validatePlannedGeometry(player,
            layout, bounds, generation, manifest)
        if not sameIdentity(identity, checkedIdentity) then
            error("RailroaderRVTest: Construction identity changed during validation")
        end
        return identity, template
    end

    local function validateManifestGate(manifest, generation, phase)
        local manifestGate = context.requireCurrentManifest
        if type(manifestGate) ~= "function" then
            error("RailroaderRVTest: current manifest gate is unavailable")
        end
        local copyOk, snapshot = pcall(context.ServerUtil.copyPlain, manifest)
        if not copyOk or type(snapshot) ~= "table" then
            error("RailroaderRVTest: current manifest cannot be validated safely")
        end
        operations.setGenerationPhase(snapshot, generation, phase)
        local gateOk, accepted = pcall(manifestGate, snapshot, true)
        if not gateOk or accepted ~= snapshot then
            error("RailroaderRVTest: current manifest schema or identity is invalid")
        end
    end

    function service.clearCurrentGeneration(cell, bounds, generation, manifest)
        local player = context.transactionPlayer
        local layout = context.pendingGeneration
            and context.pendingGeneration.layout or nil
        local identity = validateCurrentPlan(player, layout, bounds,
            generation, manifest)
        validateManifestGate(manifest, generation, "CLEARING")
        preflightClearTarget(player, cell, layout, bounds, generation,
            manifest, nil)
        operations.setGenerationPhase(manifest, generation, "CLEARING")
        local stillCurrent = currentIdentity(manifest, generation)
        if not sameIdentity(identity, stillCurrent) then
            error("RailroaderRVTest: generation identity changed before clear")
        end
        return operations.clear(cell, bounds, generation, manifest)
    end

    function service.buildCurrentGeneration(player, layout, bounds, generation, manifest)
        local identity = validateCurrentPlan(player, layout, bounds,
            generation, manifest)
        if manifest.phase ~= "CLEARING"
            or manifest.phaseGeneration ~= generation then
            error("RailroaderRVTest: build requires the current clearing phase")
        end
        validateManifestGate(manifest, generation, "CLEARING")
        if not sameIdentity(identity, currentIdentity(manifest, generation)) then
            error("RailroaderRVTest: generation identity changed before build")
        end
        return operations.build(player, layout, bounds, generation, manifest)
    end

    function service.restoreCurrentCell(player, boundary, x, y)
        local reconcile = context.reconcileCurrentTemplateCell
        local ix, iy = Constants.finiteInteger(x), Constants.finiteInteger(y)
        if player == nil or type(boundary) ~= "table"
            or type(reconcile) ~= "function"
            or ix == nil or iy == nil then
            return false, Constants.INVALID_RV_DATA
        end
        local managed = boundary.managed
        local generation = Constants.finiteInteger(boundary.generation)
        local bitmapVersion = Constants.finiteInteger(boundary.bitmapVersion)
        local originX = type(managed) == "table"
            and Constants.finiteInteger(managed.originX) or nil
        local originY = type(managed) == "table"
            and Constants.finiteInteger(managed.originY) or nil
        local width = type(managed) == "table"
            and Constants.finiteInteger(managed.width) or nil
        local height = type(managed) == "table"
            and Constants.finiteInteger(managed.height) or nil
        if type(managed) ~= "table"
            or boundary.schemaVersion ~= Constants.BOUNDARY_SCHEMA_VERSION
            or type(boundary.rvId) ~= "string" or boundary.rvId == ""
            or generation == nil or generation < 1
            or bitmapVersion ~= Constants.BITMAP_VERSION
            or originX == nil or originY == nil or width ~= Constants.RV_MANAGED_WIDTH
            or height ~= Constants.RV_MANAGED_HEIGHT
            or ix < originX or ix >= originX + width
            or iy < originY or iy >= originY + height then
            return false, Constants.INVALID_RV_DATA
        end
        local ok, restored, reason = pcall(reconcile, player, boundary, ix, iy)
        if not ok then return false, tostring(restored) end
        return restored == true, reason
    end

    return service
end

return Construction
