-- Archived dead forwarding wrappers from
-- RailroaderRV/.../server/RailroaderRV/Core/RV_RailroaderServer_Sentinel.lua.
-- The original module replaces these locals with their implementations before callbacks run.
return function(ctx)
    local function roofRefreshOwnsPlayer(...) return ctx.roofRefreshOwnsPlayer(...) end
    local function roofRefreshTransactionBlocks(...) return ctx.roofRefreshTransactionBlocks(...) end
    local function currentGeometryGate(...) return ctx.currentGeometryGate(...) end
    local function serverTransactionMutexStatus(...) return ctx.serverTransactionMutexStatus(...) end
end
