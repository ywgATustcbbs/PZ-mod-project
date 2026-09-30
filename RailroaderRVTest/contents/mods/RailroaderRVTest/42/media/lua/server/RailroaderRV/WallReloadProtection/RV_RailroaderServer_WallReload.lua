-- RV_RailroaderServer: WallReloadProtection responsibilities.
--
-- This adapter is the only place that decides WHICH removed object is an
-- exterior wall of a current RV, and the only place that turns that decision
-- into a WallReloadProtection operation.  The operation service owns the state
-- machine; this file owns detection, member capture, and the completion callback
-- that runs RoofRefresh.run once every member is back inside.
return function(ctx)
local Core = require("RailroaderRV/Core/RV_Server_Core")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local WallReload = require("RailroaderRV/WallReloadProtection/RV_WallReloadProtection")
local RoofRefresh = require("RailroaderRV/RoofRefresh/RV_RoofRefresh")

local processIsServer = ctx.processIsServer
local Boundary = ctx.Boundary
local Adapter = ctx.Adapter
local C = ctx.C
local OWNER = C.MOD_ID
local integer = ctx.integer
local call = ctx.call
local callGlobal = ctx.callGlobal
local playerId = ctx.playerId
local playerName = ctx.playerName
local playerDead = ctx.playerDead
local copyPosition = ctx.copyPosition
local mapData = ctx.mapData
local rvRegion = ctx.rvRegion
local inRegion = ctx.inRegion
local validRecord = ctx.validRecord
local playerPositionInRegion = ctx.playerPositionInRegion

local function surfaceError(text)
    local ok, message = pcall(tostring, text)
    return ok and message or "unprintable detail"
end

local function armRoomOwnership(player, record)
    local server = RailroaderRV and RailroaderRV.Server or nil
    if not server or type(server.armCurrentRoomOwnershipMonitor) ~= "function" then
        return false
    end
    local ok, armed = pcall(server.armCurrentRoomOwnershipMonitor, player, record)
    return ok and armed == true
end

-- `record.locoId:generation` is the one current RV identity.  A generation change
-- makes an in-flight operation stale, and the operation service re-reads this
-- identity before every move.
local function operationKeyFor(record)
    if type(record) ~= "table" or type(record.locoId) ~= "string"
        or record.locoId == "" then
        return nil
    end
    local generation = integer(record.generation)
    if generation == nil or generation < 1 then return nil end
    return tostring(record.locoId) .. ":" .. tostring(generation)
end

-- Capture every live, current-schema player whose authoritative mapping says it
-- is inside this RV.  Coordinates and identity are read from the server; the
-- operation service re-validates each member before arming the remote move.
local function insidePlayersForRecord(map, record)
    local result = {}
    if type(map) ~= "table" or type(record) ~= "table"
        or type(record.players) ~= "table" then
        return result
    end
    local wanted = tostring(record.locoId or "")
    local region = RegionSlots.indexToRegion(integer(record.slotIndex))
    local players = Adapter.onlinePlayersSnapshot()
    local area = rvRegion()
    for i = 1, #players do
        local player = players[i]
        local position = playerPositionInRegion(player, area)
        if position and region and inRegion(position, region) then
            local name = playerName(player)
            local relation = name and map.players[name] or nil
            local rider = name and record.players[name] or nil
            local currentOnlineId = playerId(player)
            if not playerDead(player)
                and type(relation) == "table" and relation.inside == true
                and type(rider) == "table" and rider.inside == true
                and tostring(relation.locoId) == wanted
                and integer(relation.onlineId) == integer(rider.onlineId)
                and (currentOnlineId == nil
                    or integer(relation.onlineId) == currentOnlineId)
                and (currentOnlineId == nil
                    or integer(rider.onlineId) == currentOnlineId) then
                result[#result + 1] = {
                    player = player,
                    identityKey = tostring(relation.onlineId) .. ":"
                        .. tostring(name),
                    originalPosition = copyPosition(position),
                }
            end
        end
    end
    return result
end

-- Runs after every member is physically back inside the RV.  The temporary
-- occupant list is deliberately empty: the members are already home, so the
-- refresh must not refuse its own target square.
local function runRoofRefresh(player, bounds, identity)
    if not player then
        print("[RailroaderRVTest] wall reload completion has no representative player")
        return
    end
    local refreshOk, refreshed, detail = pcall(RoofRefresh.run, player, bounds,
        identity)
    if not refreshOk then
        print("[RailroaderRVTest] roof refresh error after wall reload: "
            .. surfaceError(refreshed))
        return
    end
    if refreshed ~= true then
        print("[RailroaderRVTest] roof refresh deferred after wall reload: "
            .. surfaceError(detail))
    end
end

-- The generic removal path passes the authoritative captured shell object
-- before it is detached; direct thumpable destruction is covered separately.
-- 42.20.4's SledgehammerDestroyPacket delegates to RemoveItemFromSquarePacket,
-- which raises OnObjectAboutToBeRemoved immediately before removeFromWorld and
-- removeFromSquare, including captured windows.  OnDestroyIsoThumpable is kept
-- for direct thumpable destruction and uses the same matcher.  Ownership is
-- never inferred from a coordinate, an action name or a client payload.
local function cheapShellWallCandidate(object)
    if not object then return false end
    local squareOk, hostSquare = call(object, "getSquare")
    if not squareOk or not hostSquare then return false end

    local thumpableOk, isThumpable = callGlobal("instanceof", object, "IsoThumpable")
    local windowOk, isWindow = callGlobal("instanceof", object, "IsoWindow")
    if not (thumpableOk and isThumpable == true)
        and not (windowOk and isWindow == true) then
        return false
    end
    local indexOk, objectIndex = call(object, "getObjectIndex")
    objectIndex = indexOk and integer(objectIndex) or nil
    if objectIndex == nil or objectIndex < 0 then return false end

    local dataOk, data = call(object, "getModData")
    if not dataOk or type(data) ~= "table" then return false end
    local tag = data.RailroaderRVTest
    if type(tag) ~= "table" or tag.owner ~= OWNER
        or tag.rvId == nil or tostring(tag.rvId) == ""
        or integer(tag.generation) == nil then
        return false
    end

    local role = tag.role
    return role == "wall-north" or role == "wall-west"
        or role == "corner-nw"
end

local function wallReloadForObject(object, source)
    local server = RailroaderRV and RailroaderRV.Server or nil
    if object ~= nil and type(server) == "table"
        and type(server.isTemplateProtectionRepairRemoval) == "function" then
        local markerOk, isOwnRepairRemoval = pcall(
            server.isTemplateProtectionRepairRemoval, object)
        if markerOk and isOwnRepairRemoval == true then
            return false
        end
    end
    if not processIsServer() or not Boundary
        or type(Boundary.isCurrentShellWall) ~= "function" then
        return false
    end
    local cheapCheckOk, isCandidate = pcall(cheapShellWallCandidate, object)
    if not cheapCheckOk or not isCandidate then
        return false
    end

    local map = mapData()
    local match
    for _, record in pairs(map.locomotives or {}) do
        local wallOk, isCurrentWall = false, false
        if type(record) == "table" and type(record.locoId) == "string"
            and validRecord(record) then
            wallOk, isCurrentWall = pcall(Boundary.isCurrentShellWall,
                object, Boundary.boundaryFor(record))
        end
        if wallOk and isCurrentWall == true then
            if match then
                -- A duplicate current identity is not a reason to guess which
                -- mapping owns the object.  Leave the removal untouched.
                return false
            end
            match = record
        end
    end
    if not match then return false end

    local key = operationKeyFor(match)
    if key == nil then return false end
    local captured = insidePlayersForRecord(map, match)
    if #captured == 0 then
        print("[RailroaderRVTest] wall removal matched room=" .. key
            .. " source=" .. tostring(source)
            .. " refresh=not-scheduled reason=no-authoritative-player-inside")
        return false
    end
    local tagRole, templateIndex
    local dataOk, data = call(object, "getModData")
    local tag = dataOk and type(data) == "table" and data.RailroaderRVTest or nil
    if type(tag) == "table" then
        tagRole = tag.role
        templateIndex = integer(tag.templateIndex)
    end
    print("[RailroaderRVTest] wall removal matched room=" .. key
        .. " role=" .. tostring(tagRole)
        .. " templateIndex=" .. tostring(templateIndex)
        .. " source=" .. tostring(source)
        .. " members=" .. tostring(#captured))
    local started, detail = WallReload.begin({
        rvId = tostring(match.locoId),
        generation = integer(match.generation),
    }, runRoofRefresh)
    if started ~= true then
        print("[RailroaderRVTest] wall reload not started room=" .. key
            .. " detail=" .. surfaceError(detail))
        return false
    end
    print("[RailroaderRVTest] wall reload started room=" .. key
        .. " token=" .. tostring(detail))
    return true
end

function Adapter.onObjectAboutToBeRemoved(object)
    wallReloadForObject(object, "object-about-to-be-removed")
end

-- Some direct IsoThumpable destruction paths expose the object through the
-- OnDestroyIsoThumpable event.  The normal 42.20.4 sledgehammer packet is
-- covered above; this second hook is a strict supplement, never a client path.
function Adapter.onDestroyIsoThumpable(object)
    wallReloadForObject(object, "destroy-iso-thumpable")
end

-- Cross-module mutex query.  It exposes only live process state: the operation
-- stays busy through the temporary move, the reload wait, the return and the
-- post-return refresh, so no other module can mutate the same RV while its
-- captured members are outside it.
local function isWallReloadTransactionActive(rvId)
    if WallReload.isWallReloadActive(rvId) then
        return true, "RV wall reload is in progress"
    end
    return false
end

Adapter.isWallReloadTransactionActive = isWallReloadTransactionActive
-- One name for the cross-module mutex, shared by BoundaryGuard, RoomOwnership and
-- the utility service so they never disagree about which query to ask.
Adapter.isRoofRefreshTransactionActive = isWallReloadTransactionActive

local function publishMutexQueries()
    local api = RailroaderRV and RailroaderRV.Server
    if type(api) ~= "table" then return false end
    api.isWallReloadTransactionActive = isWallReloadTransactionActive
    api.isRoofRefreshTransactionActive = isWallReloadTransactionActive
    return true
end

-- Compatibility entry point for the RelocateAck dispatcher in Construction,
-- which is outside this refactor's ownership.  The body is the wall-reload
-- acknowledgement; the name is the only legacy part.
function Adapter.acknowledgeRoofRefreshRelocation(player, token)
    return WallReload.acknowledge(player, token)
end

-- Compatibility entry point for the old adapter tick loop in Core, which is
-- outside this refactor's ownership.  It reports the live operation phase.
function Adapter.getRoofRefreshRelocationState(rvId, generation, _token)
    local op = WallReload.activeOperation()
    if op == nil or tostring(op.rvId) ~= tostring(rvId)
        or integer(op.generation) ~= integer(generation) then
        return "idle"
    end
    return "active", op.phase
end

-- PZ loads files in this directory alphabetically, so this adapter is evaluated
-- before RV_Server.lua has created RailroaderRV.Server.  The two wall-removal
-- event hooks are registered by the adapter tick module, which owns the install
-- guard for all of this adapter's engine hooks; this installer publishes only the
-- cross-module mutex query once the public facade exists.
function Adapter.installWallReload()
    if type(RailroaderRV) ~= "table" or type(RailroaderRV.Server) ~= "table" then
        return false
    end
    publishMutexQueries()
    return true
end

Adapter.installWallReload()

-- The retired roof-refresh presence sampler also owned one load-bearing side
-- effect: it (re-)armed the persistent client stale-room monitor for every
-- player standing inside an RV, which is what repairs a client whose IsoRoom
-- reference was retired while it was away.  That repair is a different bug class
-- from the wall reload and does not need a queue, a cache or a state machine, so
-- it stays here as one bounded per-RV re-arm.  armRoomOwnershipMonitor already
-- refuses a rvId:generation whose validation cache is cold, and
-- prewarmCurrentBoundaryPlayers warms at most one rvId:generation per tick, so
-- this converges instead of re-sending a footprint every tick.
local MONITOR_REARM_INTERVAL_TICKS = 60
local nextMonitorRearmTick = 0

function Adapter.rearmRoomOwnershipMonitors(tick)
    local now = tick or Core.getTick()
    if now < nextMonitorRearmTick then return end
    nextMonitorRearmTick = now + MONITOR_REARM_INTERVAL_TICKS
    if not Boundary or type(Boundary.boundaryForPlayer) ~= "function" then return end
    local seen = {}
    for _, player in pairs(Adapter.onlinePlayersSnapshot()) do
        -- boundaryForPlayer is the current-schema gate: it returns only a
        -- validated mapping, relation and manifest for this player right now.
        local boundary, record = Boundary.boundaryForPlayer(player)
        if type(boundary) == "table" and validRecord(record) then
            local key = tostring(record.locoId) .. ":"
                .. tostring(integer(record.generation))
            if not seen[key] then
                seen[key] = true
                if not armRoomOwnership(player, record) then
                    print("[RailroaderRVTest] room ownership monitor deferred rvId="
                        .. key)
                end
            end
        end
    end
end

ctx.insidePlayersForRecord = insidePlayersForRecord
ctx.wallReloadForObject = wallReloadForObject
ctx.isWallReloadTransactionActive = isWallReloadTransactionActive
ctx.acknowledgeRoofRefreshRelocation = Adapter.acknowledgeRoofRefreshRelocation
end
