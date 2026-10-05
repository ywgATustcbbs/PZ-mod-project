-- Archived dead forwarding wrapper from
-- RailroaderRV/.../server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua.
-- The original module replaces this local with its implementation before callbacks run.
return function(ctx)
    local function sourceWithinRange(...) return ctx.sourceWithinRange(...) end
end
