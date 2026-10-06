-- Internal server-only RV construction gates.
--
-- Transaction ownership and phase remain server checks. Template layouts,
-- manifests and persisted fields are consumed according to their current contract.
local Construction = {}

function Construction.new(context, operations)
    local service = {}
    local generationTransaction = context.GenerationTransaction

    local function requireCurrentBuild(player)
        if player == nil or generationTransaction.owns(player) ~= true then
            error("RailroaderRV: Construction requires the active server transaction")
        end
    end

    -- Phase ownership is process-local.  The record's stage is the single stage
    -- authority: the clear pass runs while the record is in BUILD, and the build
    -- pass runs exactly once, after the clear pass has completed.
    local function requireCurrentMutation(player)
        requireCurrentBuild(player)
        local pending = generationTransaction.current()
        if not pending or pending.stage ~= "BUILD" then
            error("RailroaderRV: generation is not in its current clear phase")
        end
    end

    function service.clearCurrentGeneration(cell, bounds)
        local pending = generationTransaction.current()
        local player = pending.player
        requireCurrentMutation(player)
        return operations.clear(cell, bounds)
    end

    function service.buildCurrentGeneration(player, layout, bounds, generation)
        requireCurrentBuild(player)
        local pending = generationTransaction.current()
        if not pending or tostring(pending.generation) ~= tostring(generation) then
            error("RailroaderRV: build requires the current clearing phase")
        end
        return operations.build(player, layout, bounds, generation)
    end

    return service
end

return Construction
