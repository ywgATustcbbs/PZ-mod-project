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
        if player == nil or generationTransaction.owns(player) ~= true then
            error("RailroaderRVTest: Construction requires the active server transaction")
        end
    end

    local function preflightClearTarget(player, cell, bounds)
        requireCurrentBuild(player)
        local world = context.ServerWorld
        local schema = context.ServerSchema

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
        generation, identitySource)
        preflightClearTarget(player, cell, bounds)
        return true
    end

    -- Phase ownership is process-local.  The record's stage is the single stage
    -- authority: the clear pass runs while the record is in BUILD, and the build
    -- pass runs exactly once, after the clear pass has completed.
    local function requireCurrentMutation(player)
        requireCurrentBuild(player)
        local pending = generationTransaction.current()
        if not pending or pending.stage ~= "BUILD" then
            error("RailroaderRVTest: generation is not in its current clear phase")
        end
    end

    function service.clearCurrentGeneration(cell, bounds, generation)
        local pending = generationTransaction.current()
        local player = pending.player
        requireCurrentMutation(player)
        preflightClearTarget(player, cell, bounds)
        operations.setGenerationPhase(generation, "CLEARING")
        return operations.clear(cell, bounds, generation)
    end

    function service.buildCurrentGeneration(player, layout, bounds, generation)
        requireCurrentBuild(player)
        local pending = generationTransaction.current()
        if not pending or tostring(pending.generation) ~= tostring(generation) then
            error("RailroaderRVTest: build requires the current clearing phase")
        end
        return operations.build(player, layout, bounds, generation)
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
