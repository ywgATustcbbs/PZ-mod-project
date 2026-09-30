-- RV_RailroaderServer: Tick responsibilities.
return function(ctx)
local Adapter = ctx.Adapter
local Core = require("RailroaderRV/Core/RV_Server_Core")
local WallReload = require("RailroaderRV/WallReloadProtection/RV_WallReloadProtection")
local call = ctx.call
local findTrain = ctx.findTrain
local trainPose = ctx.trainPose
local mapData = ctx.mapData
local markMappingChanged = ctx.markMappingChanged
local rvRegion = ctx.rvRegion
local playerPositionInRegion = ctx.playerPositionInRegion
local restoreAfterGenerationFailure = ctx.restoreAfterGenerationFailure
local commitGeneration = ctx.commitGeneration
local validateGeneration = ctx.validateGeneration
Adapter._ticks = Core.getTick()

-- The only periodic adapter work left after the roof-refresh queue was retired:
-- keep the boundary validation cache warm for the players standing in the RV
-- scope, so the guard never pays a cold validation on the tick it must correct.
local function prewarmBoundaryPlayersInScope(map)
    local adapter = RailroaderRV and RailroaderRV.RailroaderServer or nil
    if not adapter or type(adapter.onlinePlayersSnapshot) ~= "function"
        or type(adapter.prewarmCurrentBoundaryPlayers) ~= "function" then
        return
    end
    local ok, players = pcall(adapter.onlinePlayersSnapshot)
    if not ok or type(players) ~= "table" then return end
    local area = rvRegion()
    local candidates = {}
    for i = 1, #players do
        local player = players[i]
        if player ~= nil and playerPositionInRegion(player, area) then
            candidates[#candidates + 1] = player
        end
    end
    if #candidates > 0 then adapter.prewarmCurrentBoundaryPlayers(map, candidates) end
end

function Adapter.OnTick(tick)
    Adapter._ticks = tick
    -- The wall reload operation owns the RV's players until every one of them is
    -- back inside, so it advances before any other per-tick RV work.
    WallReload.onTick()
    if not Core.tickModulo(30) then return end
    local map = mapData()
    local changed = false
    if Core.tickModulo(120) then
        for _, record in pairs(map.locomotives or {}) do
            if type(record) == "table" and record.locoId ~= nil then
                local train = findTrain(record.locoId)
                local position = train and trainPose(train)
                if position then
                    local old = record.locoPosition
                    if not old or old.x ~= position.x or old.y ~= position.y
                        or old.z ~= position.z then
                        record.locoPosition = position
                        changed = true
                    end
                end
            end
        end
    end
    prewarmBoundaryPlayersInScope(map)
    if type(Adapter.rearmRoomOwnershipMonitors) == "function" then
        Adapter.rearmRoomOwnershipMonitors(tick)
    end
    if changed then markMappingChanged(false) end
end

-- PZ loads files in this directory alphabetically, so this adapter can be
-- evaluated before RV_Server.lua has created RailroaderRV.Server.  Expose a
-- one-shot installer and let RV_Server.lua call it again after its public
-- setters exist; require() then returns the cached adapter without rerunning
-- this file.
function Adapter.installTransactionHooks()
    local server = RailroaderRV and RailroaderRV.Server
    if not server
        or type(server.setRailroaderValidationHook) ~= "function"
        or type(server.setRailroaderCommitHook) ~= "function"
        or type(server.setRailroaderFailureHook) ~= "function" then
        return false
    end
    server.setRailroaderValidationHook(validateGeneration)
    server.setRailroaderCommitHook(commitGeneration)
    server.setRailroaderFailureHook(function(...)
        if type(Adapter.invalidateBoundaryValidationCache) == "function" then
            Adapter.invalidateBoundaryValidationCache()
        end
        return restoreAfterGenerationFailure(...)
    end)
    if not Adapter._tickRegistered then
        Adapter._tickRegistered = true
        Core.onTick(Adapter.OnTick)
    end
    return true
end

Adapter.installTransactionHooks()

if type(Adapter.onObjectAboutToBeRemoved) == "function" then
    Core.on("OnObjectAboutToBeRemoved", Adapter.onObjectAboutToBeRemoved)
end
if type(Adapter.onDestroyIsoThumpable) == "function" then
    Core.on("OnDestroyIsoThumpable", Adapter.onDestroyIsoThumpable)
end


end
