-- RV_RailroaderServer: WallReloadProtection responsibilities.
--
-- This adapter is the only place that decides WHICH removed object is an
-- exterior wall of a current RV, and the only place that turns that decision
-- into a WallReloadProtection operation.  The operation service owns the state
-- machine; this file owns detection, member capture, and the completion callback
-- that runs RoofRefresh.run once every member is back inside.
return function(ctx)
local Core = require("RailroaderRV/Core/RV_Server_Core")
local WallReload = require("RailroaderRV/WallReloadProtection/RV_WallReloadProtection")

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
local recordRegion = ctx.recordRegion
local playerPositionInRegion = ctx.playerPositionInRegion
local recordForLoco = ctx.recordForLoco
local pendingWallReloads = {}

local function armRoomOwnership(player, record)
    return RailroaderRV.Server.armCurrentRoomOwnershipMonitor(player, record)
        == true
end

-- `record.locoId:generation` is the one current RV identity.  A generation change
-- makes an in-flight operation stale, and the operation service re-reads this
-- identity before every move.
local function operationKeyFor(record)
    return record.locoId .. ":" .. tostring(record.generation)
end

local function authoritativeRoomObservation(player)
    local square = player:getCurrentSquare()
    if square == nil then return nil end
    return {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
        inRoom = square:isInARoom(),
    }
end

-- Capture every live player whose authoritative mapping says it
-- is inside this RV.  Coordinates and identity are read from the server; the
-- operation service re-validates each member before arming the remote move.
local function insidePlayersForRecord(map, record)
    local result = {}
    local wanted = tostring(record.locoId)
    local region = recordRegion(record)
    local players, snapshotOk = Adapter.onlinePlayersSnapshot()
    if not snapshotOk then return nil, false end
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
                and tostring(relation.locoId) == wanted then
                result[#result + 1] = {
                    player = player,
                    identityKey = tostring(currentOnlineId) .. ":"
                        .. tostring(name),
                    originalPosition = copyPosition(position),
                }
            end
        end
    end
    return result, true
end

-- Runs after every member is physically back inside the RV. The timer stores
-- only its trusted RV id; each attempt re-reads current mapping and geometry.
local function runRoofRefresh(_player, _bounds, identity)
    RailroaderRV.Server.scheduleRoofRefreshForRV(identity.rvId)
end

local function startWallReload(key, record)
    local started, detail = WallReload.begin({
        rvId = tostring(record.locoId),
        generation = integer(record.generation),
    }, runRoofRefresh)
    if started ~= true then
        print("[RailroaderRV] wall reload not started room=" .. key
            .. " detail=" .. surfaceError(detail))
        return false
    end
    return true
end

local function isEmptyMap(map)
    for _ in pairs(map) do
        return false
    end
    return true
end

local function processPendingWallReloads()
    if isEmptyMap(pendingWallReloads) then return end
    local map = mapData()
    for key, pending in pairs(pendingWallReloads) do
        local record = recordForLoco(map, pending.rvId)
        if not record or operationKeyFor(record) ~= key
            or WallReload.isWallReloadActive(pending.rvId) then
            pendingWallReloads[key] = nil
        else
            local live, snapshotOk = insidePlayersForRecord(map, record)
            if snapshotOk then
                local liveByIdentity = {}
                for i = 1, #live do
                    liveByIdentity[live[i].identityKey] = live[i]
                end
                local roomLossObserved = false
                for identityKey, originalSquare in pairs(pending.participants) do
                    local member = liveByIdentity[identityKey]
                    if not member then
                        pending.participants[identityKey] = nil
                    else
                        local current = authoritativeRoomObservation(member.player)
                        if current then
                            if current.x ~= originalSquare.x
                                or current.y ~= originalSquare.y
                                or current.z ~= originalSquare.z then
                                pending.participants[identityKey] = nil
                            elseif not current.inRoom then
                                roomLossObserved = true
                                break
                            end
                        end
                    end
                end
                if roomLossObserved then
                    pendingWallReloads[key] = nil
                    startWallReload(key, record)
                elseif isEmptyMap(pending.participants) then
                    pendingWallReloads[key] = nil
                end
            end
        end
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
    local tag = data.RailroaderRV
    if type(tag) ~= "table" or tag.owner ~= OWNER
        or tag.rvId == nil or tostring(tag.rvId) == ""
        or integer(tag.generation) == nil then
        return false
    end

    local role = tag.role
    return role == "wall-north" or role == "wall-west"
        or role == "corner-nw"
end

local function wallReloadForObject(object)
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
    for _, record in pairs(map.locomotives) do
        if Boundary.isCurrentShellWall(object, Boundary.boundaryFor(record)) then
            if match then
                error("world object matches multiple trusted RV mappings")
            end
            match = record
        end
    end
    if not match then return false end

    local key = operationKeyFor(match)
    if key == nil then return false end
    if pendingWallReloads[key] ~= nil
        or WallReload.isWallReloadActive(tostring(match.locoId)) then return false end
    local captured, snapshotOk = insidePlayersForRecord(map, match)
    if not snapshotOk then return false end
    if #captured == 0 then
        return false
    end
    local participants = {}
    local participantCount = 0
    for i = 1, #captured do
        local observation = authoritativeRoomObservation(captured[i].player)
        if observation and observation.inRoom then
            participants[captured[i].identityKey] = {
                x = observation.x, y = observation.y, z = observation.z,
            }
            participantCount = participantCount + 1
        end
    end
    if participantCount == 0 then
        return false
    end
    pendingWallReloads[key] = {
        rvId = tostring(match.locoId),
        participants = participants,
    }
    return true
end

function Adapter.onObjectAboutToBeRemoved(object)
    wallReloadForObject(object)
end

-- Some direct IsoThumpable destruction paths expose the object through the
-- OnDestroyIsoThumpable event.  The normal 42.20.4 sledgehammer packet is
-- covered above; this second hook is a strict supplement, never a client path.
function Adapter.onDestroyIsoThumpable(object)
    wallReloadForObject(object)
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

local function publishMutexQueries()
    local api = RailroaderRV and RailroaderRV.Server
    if type(api) ~= "table" then return false end
    api.isWallReloadTransactionActive = isWallReloadTransactionActive
    return true
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
-- checks the player's current mapping and relation before sending. The
-- per-player identity cache makes this a reconnect/new-identity synchronization,
-- not a periodic footprint resend.
local MONITOR_REARM_INTERVAL_TICKS = 60
local nextMonitorRearmTick = 0

function Adapter.rearmRoomOwnershipMonitors(tick)
    local now = tick or Core.getTick()
    if now < nextMonitorRearmTick then return end
    nextMonitorRearmTick = now + MONITOR_REARM_INTERVAL_TICKS
    local players, snapshotOk = Adapter.onlinePlayersSnapshot()
    if not snapshotOk then return end
    RailroaderRV.Server.pruneRoomOwnershipMonitorConnections(players)
    for _, player in pairs(players) do
        -- Resolve the player's current RV from authoritative server state.
        local boundary, record = Boundary.boundaryForPlayer(player)
        if boundary ~= nil then
            armRoomOwnership(player, record)
        end
    end
end

Core.onTick(processPendingWallReloads)
end
