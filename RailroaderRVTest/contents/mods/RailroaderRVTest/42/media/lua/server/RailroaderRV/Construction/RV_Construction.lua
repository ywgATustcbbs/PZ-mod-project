-- Internal server-only RV construction gates.
--
-- Transaction ownership and phase remain server checks. Template layouts,
-- manifests and persisted fields are consumed according to their current contract.
local Constants = require("RailroaderRV/Common/RV_Constants")

local Construction = {}

local function samePoint(left, right)
    return left.x == right.x and left.y == right.y and left.z == right.z
end

function Construction.new(context, operations)
    local service = {}
    local generationTransaction = context.GenerationTransaction

    local function requireCurrentBuild(player)
        if player == nil or generationTransaction.owns(player, nil,
            "building") ~= true then
            error("RailroaderRVTest: Construction requires the active server transaction")
        end
    end

    local function preflightClearTarget(player, cell, bounds, identity,
        existingManifest)
        requireCurrentBuild(player)
        local world = context.ServerWorld
        local schema = context.ServerSchema

        -- A prior generation has no complete inverse snapshot, so the same RV
        -- cannot be rebuilt in place.  The durable manifest records only the
        -- claimed slot and identity; the anchor is that slot's template anchor.
        if existingManifest
            and existingManifest.rvId == identity.rvId
            and existingManifest.slotIndex == identity.slotIndex then
            error("RailroaderRVTest: same-slot rebuild is refused because "
                .. "the previous generation has no complete undo snapshot")
        end

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
    end

    function service.preflightCurrentGeneration(player, cell, layout, bounds,
        generation, identitySource, existingManifest)
        preflightClearTarget(player, cell, bounds, identitySource,
            existingManifest)
        return true
    end

    local function requireCurrentMutation(player, manifest)
        requireCurrentBuild(player)
        if manifest.state ~= "RUNNING" then
            error("RailroaderRVTest: generation is not in its current build phase")
        end
    end

    function service.clearCurrentGeneration(cell, bounds, generation, manifest)
        local pending = generationTransaction.current()
        local player = pending.player
        requireCurrentMutation(player, manifest)
        preflightClearTarget(player, cell, bounds, manifest, nil)
        operations.setGenerationPhase(manifest, generation, "CLEARING")
        return operations.clear(cell, bounds, generation, manifest)
    end

    function service.buildCurrentGeneration(player, layout, bounds, generation, manifest)
        requireCurrentMutation(player, manifest)
        -- The clear->build ordering is a process-local transaction invariant;
        -- it is not part of the durable record.
        local pending = generationTransaction.current()
        if not pending or pending.buildStage == "building"
            or tostring(pending.generation) ~= tostring(generation) then
            error("RailroaderRVTest: build requires the current clearing phase")
        end
        pending.buildStage = "building"
        return operations.build(player, layout, bounds, generation, manifest)
    end

    function service.restoreCurrentCell(player, boundary, x, y)
        local ix, iy = Constants.finiteInteger(x), Constants.finiteInteger(y)
        local managed = boundary.managed
        local generation = boundary.generation
        if player == nil or generation < 1 or boundary.rvId == ""
            or ix == nil or iy == nil
            or ix < managed.originX or ix >= managed.originX + managed.width
            or iy < managed.originY or iy >= managed.originY + managed.height then
            return false, "outside current managed region"
        end
        local restored, reason = context.reconcileCurrentTemplateCell(
            player, boundary, ix, iy)
        return restored == true, reason
    end

    return service
end

return Construction
