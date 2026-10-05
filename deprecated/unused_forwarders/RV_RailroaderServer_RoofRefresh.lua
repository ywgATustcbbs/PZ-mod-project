-- Archived dead forwarding wrappers from
-- RailroaderRV/.../server/RailroaderRV/RoofRefresh/RV_RailroaderServer_RoofRefresh.lua.
-- The original module replaces each local with its implementation before callbacks run.
return function(ctx)
    local function insidePlayersForRecord(...) return ctx.insidePlayersForRecord(...) end
    local function scheduleRoofRefresh(...) return ctx.scheduleRoofRefresh(...) end
    local function observeRoomTransitions(...) return ctx.observeRoomTransitions(...) end
end
