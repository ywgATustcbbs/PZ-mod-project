-- Archived dead forwarding wrappers from
-- RailroaderRV/.../server/RailroaderRV/RVMapping/RV_RailroaderServer_Mapping.lua.
-- The original module replaces these locals with their implementations before callbacks run.
return function(ctx)
    local function validateMapSchema(...) return ctx.validateMapSchema(...) end
    local function recordForLoco(...) return ctx.recordForLoco(...) end
end
