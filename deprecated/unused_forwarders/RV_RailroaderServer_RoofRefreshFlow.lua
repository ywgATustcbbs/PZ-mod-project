-- Archived dead forwarding wrapper from
-- RailroaderRVTest/.../server/RailroaderRV/RoofRefresh/RV_RailroaderServer_RoofRefreshFlow.lua.
-- The original module replaces this local with its implementation before callbacks run.
return function(ctx)
    local function beginRoofRefreshPhase(...) return ctx.beginRoofRefreshPhase(...) end
end
