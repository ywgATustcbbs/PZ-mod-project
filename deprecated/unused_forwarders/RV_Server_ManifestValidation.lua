-- Archived dead forwarding wrapper from
-- RailroaderRVTest/.../server/RailroaderRV/Core/RV_Server_ManifestValidation.lua.
-- The original module replaces this local with its implementation before callbacks run.
return function(ctx)
    local function requireCurrentManifest(...) return ctx.requireCurrentManifest(...) end
end
