-- RV_RailroaderServer: RoofRefresh responsibilities.
return function(ctx)
local Core = require("RailroaderRV/Core/RV_Server_Core")
local processIsServer = ctx.processIsServer
local RV = ctx.RV
local Boundary = ctx.Boundary
local Adapter = ctx.Adapter
local C = ctx.C
local OWNER = C.MOD_ID
local roofRefreshPlayers = ctx.roofRefreshPlayers
local roomMonitorPlayers = ctx.roomMonitorPlayers
local pendingWallRoofRefreshes = ctx.pendingWallRoofRefreshes
local followUpWallRemovalEvents = ctx.followUpWallRemovalEvents
local roomTransitionStates = ctx.roomTransitionStates
local suppressedRoomTransitions = ctx.suppressedRoomTransitions
local seenWallRemovalEvents = ctx.seenWallRemovalEvents
local ROOF_REFRESH_DELAY_TICKS = ctx.ROOF_REFRESH_DELAY_TICKS
local ROOF_REFRESH_ATTEMPTS = ctx.ROOF_REFRESH_ATTEMPTS
local WALL_REMOVAL_EVENT_DEDUPE_TICKS = ctx.WALL_REMOVAL_EVENT_DEDUPE_TICKS
local WALL_REMOVAL_FOLLOWUP_TICKS = ctx.WALL_REMOVAL_FOLLOWUP_TICKS
local WALL_REMOVAL_FOLLOWUP_MAX = ctx.WALL_REMOVAL_FOLLOWUP_MAX
local ROOF_REFRESH_QUEUED_DEADLINE_TICKS = ctx.ROOF_REFRESH_QUEUED_DEADLINE_TICKS
local RELOCATION_SENTINEL_INTERVAL_TICKS = ctx.RELOCATION_SENTINEL_INTERVAL_TICKS
local RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS = ctx.RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS
local RELOCATION_SENTINEL_Z = ctx.RELOCATION_SENTINEL_Z
local relocationSentinelBusy = ctx.relocationSentinelBusy
local relocationSentinelCooldown = ctx.relocationSentinelCooldown
local relocationSentinelWarnings = ctx.relocationSentinelWarnings
local function recordForLoco(...) return ctx.recordForLoco(...) end
local insidePlayersForRecord
local scheduleRoofRefresh
local observeRoomTransitions
local function serverTransactionMutexStatus(...) return ctx.serverTransactionMutexStatus(...) end
local number = ctx.number
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
local roofRefreshRoomKey = ctx.roofRefreshRoomKey
local isWallRemovalSource = ctx.isWallRemovalSource
local wallRemovalEventKey = ctx.wallRemovalEventKey
local refreshRoofForPlayer = ctx.refreshRoofForPlayer
local armRoomOwnershipMonitor = ctx.armRoomOwnershipMonitor
local onlinePlayersSnapshot = ctx.onlinePlayersSnapshot
local sentinelIdentity = ctx.sentinelIdentity
local sentinelClaimState = ctx.sentinelClaimState
local sentinelWarn = ctx.sentinelWarn
local sentinelRecordCandidate = ctx.sentinelRecordCandidate
local sentinelReturnToRV = ctx.sentinelReturnToRV
local warnSentinelPlayersAtTemporaryCell = ctx.warnSentinelPlayersAtTemporaryCell

local function playerPositionInRegion(player, region)
    if not player or type(region) ~= "table" then return nil end
    local zOk, z = call(player, "getZ")
    z = zOk and number(z) or nil
    local minZ, maxZ = number(region.minZ), number(region.maxZ)
    if z == nil or minZ == nil or maxZ == nil
        or math.floor(z) < math.floor(minZ)
        or math.floor(z) >= math.floor(maxZ) then
        return nil
    end
    local xOk, x = call(player, "getX")
    x = xOk and number(x) or nil
    local minX, maxX = number(region.minX), number(region.maxX)
    if x == nil or minX == nil or maxX == nil or x < minX or x >= maxX then
        return nil
    end
    local yOk, y = call(player, "getY")
    y = yOk and number(y) or nil
    local minY, maxY = number(region.minY), number(region.maxY)
    if y == nil or minY == nil or maxY == nil or y < minY or y >= maxY then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function processStatelessRelocationSentinel()
    local now = Adapter._ticks or Core.getTick()
    if RELOCATION_SENTINEL_INTERVAL_TICKS == nil
        or not Core.tickModulo(RELOCATION_SENTINEL_INTERVAL_TICKS) then
        return
    end
    local players = onlinePlayersSnapshot()
    local present = {}
    local sentinelPlayers = {}
    local pruneAbsent = Core.tickModulo(60)
    for i = 1, #players do
        local player = players[i]
        local zOk, z = call(player, "getZ")
        local atSentinel = zOk and integer(z) == RELOCATION_SENTINEL_Z
        if atSentinel or pruneAbsent then
            local identityKey = sentinelIdentity(player)
            if identityKey then
                if pruneAbsent then present[identityKey] = true end
                if atSentinel then
                    sentinelPlayers[#sentinelPlayers + 1] = player
                end
            end
        end
    end
    if pruneAbsent then
        for identityKey in pairs(relocationSentinelCooldown) do
            if not present[identityKey] then
                relocationSentinelCooldown[identityKey] = nil
                relocationSentinelWarnings[identityKey] = nil
                relocationSentinelBusy[identityKey] = nil
            end
        end
    end
    if #sentinelPlayers == 0 then return end
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.isRelocationIdentityClaimed) ~= "function"
        or type(server.currentRVManifestForRelocation) ~= "function"
        or type(server.isGenerationTransactionActive) ~= "function"
        or type(server.isRoofRefreshTransactionActive) ~= "function" then
        warnSentinelPlayersAtTemporaryCell(C.INVALID_RV_DATA,
            sentinelPlayers)
        return
    end
    local generationCallOk, generationActive = pcall(
        server.isGenerationTransactionActive)
    local roofCallOk, roofActive = pcall(
        server.isRoofRefreshTransactionActive, nil)
    if not generationCallOk or type(generationActive) ~= "boolean"
        or not roofCallOk or type(roofActive) ~= "boolean" then
        warnSentinelPlayersAtTemporaryCell(C.INVALID_RV_DATA,
            sentinelPlayers)
        return
    end
    -- Ordinary transactions own the managed scope while they are moving or
    -- refreshing players. Let their authoritative phase loop finish first;
    -- the sentinel retries on its next fixed interval without competing for a
    -- player or a boundary lease.
    if generationActive or roofActive then return end
    local mapOk, map = pcall(mapData)
    if not mapOk or type(map) ~= "table" then
        warnSentinelPlayersAtTemporaryCell(
            mapOk and map or C.INVALID_RV_DATA, sentinelPlayers)
        return
    end
    for i = 1, #sentinelPlayers do
        local player = sentinelPlayers[i]
        local candidate, identityKey, reason
        local candidateCallOk, candidateResult, candidateIdentity, candidateReason =
            pcall(sentinelRecordCandidate, map, player, server)
        if candidateCallOk then
            candidate, identityKey, reason = candidateResult, candidateIdentity,
                candidateReason
        else
            identityKey = sentinelIdentity(player)
            reason = C.INVALID_RV_DATA
        end
        if identityKey then
            present[identityKey] = true
            if candidate and not relocationSentinelBusy[identityKey] then
                local untilTick = relocationSentinelCooldown[identityKey]
                    or { hi32 = 0, lo32 = 0 }
                if Core.tickReached(now, untilTick) then
                    local claimed = sentinelClaimState(server, identityKey)
                    if claimed == nil then
                        sentinelWarn(identityKey, C.INVALID_RV_DATA)
                    elseif not claimed then
                        -- Recheck immediately before moving, after the full
                        -- current-schema candidate resolution.
                        local claimedAgain = sentinelClaimState(server, identityKey)
                        if claimedAgain == false then
                            relocationSentinelBusy[identityKey] = true
                            local returnCallOk, returned, returnReason = pcall(
                                sentinelReturnToRV, candidate, player, map)
                            if not returnCallOk then
                                returned, returnReason = false,
                                    C.INVALID_RV_DATA
                            end
                            local claimedAfter = sentinelClaimState(server,
                                identityKey)
                            relocationSentinelBusy[identityKey] = nil
                            relocationSentinelCooldown[identityKey] = Core.tickAdd(now,
                                RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS or 10)
                            if claimedAfter == nil then
                                sentinelWarn(identityKey, C.INVALID_RV_DATA)
                            elseif claimedAfter ~= false then
                                sentinelWarn(identityKey,
                                    "relocation sentinel identity became claimed")
                            elseif not returned then
                                sentinelWarn(identityKey, returnReason)
                            else
                                relocationSentinelWarnings[identityKey] = nil
                                print("[RailroaderRVTest] relocation sentinel returned identity="
                                    .. identityKey .. " rvId="
                                    .. tostring(candidate.record.rvId)
                                    .. " kind=" .. candidate.generationKind)
                            end
                        end
                    end
                end
            elseif reason ~= nil then
                sentinelWarn(identityKey, reason)
            end
        end
    end
end

-- On the server, the player square is authoritative.  Generated RV rooms are
-- represented by IsoRegions and may not have a static IsoRoom/RoomDef, so the
-- transition signal is the square's isInARoom() result; getRoom()/getRoomDef()
-- are sampled as supporting state and diagnostics only.
local function authoritativeRoomState(player)
    local squareOk, square = call(player, "getCurrentSquare")
    if not squareOk or not square then return nil end
    local roomOk, room = call(square, "getRoom")
    if not roomOk then return nil end
    local roomDefOk, roomDef = call(square, "getRoomDef")
    if not roomDefOk then return nil end
    local insideOk, inside = call(square, "isInARoom")
    if not insideOk or type(inside) ~= "boolean" then return nil end
    return {
        inRoom = inside == true,
        hasRoom = room ~= nil,
        hasRoomDef = roomDef ~= nil,
    }
end

local function sampleRoofRefreshPlayers(map)
    local present = {}
    local observedRooms = {}
    local boundaryPlayers = {}
    local players = onlinePlayersSnapshot()
    local area = rvRegion()
    for i = 1, #players do
        local player = players[i]
        local position = playerPositionInRegion(player, area)
        if position then
            boundaryPlayers[#boundaryPlayers + 1] = player
            local name = playerName(player)
            local relation = name and map.players[name] or nil
            if type(relation) == "table" and relation.inside == true then
                local record = recordForLoco(map, relation.locoId)
                if record and validRecord(record)
                    and inRegion(position, record.region) then
                    local roomKey = roofRefreshRoomKey(record)
                    local presenceKey = roomKey and name
                        and (name .. ":" .. roomKey) or nil
                    if presenceKey then present[presenceKey] = true end
                    if roomKey then
                        local observed = observedRooms[roomKey]
                        if not observed then
                            observed = {
                                record = record,
                                inRoom = nil,
                                hasRoom = false,
                                hasRoomDef = false,
                                roomStateAvailable = false,
                            }
                            observedRooms[roomKey] = observed
                        end
                        local roomState = authoritativeRoomState(player)
                        if roomState then
                            if observed.inRoom == nil then
                                observed.inRoom = roomState.inRoom
                            else
                                observed.inRoom = observed.inRoom or roomState.inRoom
                            end
                            observed.hasRoom = observed.hasRoom or roomState.hasRoom
                            observed.hasRoomDef = observed.hasRoomDef
                                or roomState.hasRoomDef
                            observed.roomStateAvailable = true
                        end
                    end
                    local currentOnlineId = playerId(player)
                    local reconnect = currentOnlineId ~= nil
                        and relation.onlineId ~= nil
                        and tostring(currentOnlineId) ~= tostring(relation.onlineId)
                    local firstPresence = presenceKey == nil
                        or roofRefreshPlayers[presenceKey] ~= true
                    local monitorReady = false
                    if presenceKey then
                        monitorReady = roomMonitorPlayers[presenceKey] == player
                        if not monitorReady then
                            monitorReady = armRoomOwnershipMonitor(player, record,
                                reconnect and "reconnect" or "presence")
                            if monitorReady then
                                roomMonitorPlayers[presenceKey] = player
                            end
                        end
                    end
                    -- A wall-removal transaction owns the player until its return
                    -- ACK. Do not run a roof refresh while the player is relocated.
                    if monitorReady and not (roomKey
                        and pendingWallRoofRefreshes[roomKey] ~= nil) then
                        refreshRoofForPlayer(player, record,
                            firstPresence or reconnect,
                            reconnect and "reconnect" or "presence")
                    end
                end
            end
        end
    end
    observeRoomTransitions(map, observedRooms)
    -- A later appearance of the same username is treated as a new connection,
    -- so the roof refresh is retriggered even when the map generation is unchanged.
    for presenceKey in pairs(roofRefreshPlayers) do
        if not present[presenceKey] then roofRefreshPlayers[presenceKey] = nil end
    end
    for presenceKey in pairs(roomMonitorPlayers) do
        if not present[presenceKey] then roomMonitorPlayers[presenceKey] = nil end
    end
    if type(Adapter.prewarmCurrentBoundaryPlayers) == "function" then
        Adapter.prewarmCurrentBoundaryPlayers(map, boundaryPlayers)
    end
end

-- One matched event or authoritative room transition owns one schedule for
-- the complete current RV identity.  The schedule intentionally starts after
-- the event/transition so the asynchronous object, neighbour and IsoRegions
-- work has time to settle; it never persists or infers geometry.
scheduleRoofRefresh = function(map, record, source, eventKey, coordinateKey)
    if type(map) ~= "table" or not validRecord(record) then return false end
    local roomKey = roofRefreshRoomKey(record)
    if not roomKey then return false end
    local generationBusy, roofBusy = serverTransactionMutexStatus()
    if generationBusy == nil or generationBusy or roofBusy then
        -- The caller keeps an object event as a bounded follow-up when this
        -- is a transient global transaction conflict.  A room observation has
        -- no accepted event to mutate, so it simply retries on the next pass.
        return false
    end
    -- There is one shared managed world scope.  Do not queue a second roof
    -- transaction under another room key while the first one is still live.
    for activeRoomKey, pending in pairs(pendingWallRoofRefreshes) do
        if type(pending) ~= "table" then return false end
        if pending.relocationPhase ~= "complete"
            and tostring(activeRoomKey) ~= tostring(roomKey) then
            return false
        end
    end
    if isWallRemovalSource(source) then
        -- An object event is authoritative evidence of a new wall operation.
        -- It also clears the one-shot suppression left by the prior cycle so
        -- a later independent removal can schedule normally.
        suppressedRoomTransitions[roomKey] = nil
    elseif source == "room-transition"
        and suppressedRoomTransitions[roomKey] ~= nil then
        return false
    end
    -- The room identity is the active-cycle owner.  A duplicate callback may
    -- observe the same pending table, but it never gets a second success
    -- result/token; once this table is retired, a later event is independent.
    if pendingWallRoofRefreshes[roomKey] then return false end
    local players = insidePlayersForRecord
        and insidePlayersForRecord(map, record) or {}
    if #players == 0 then return false end

    local now = Adapter._ticks or Core.getTick()
    pendingWallRoofRefreshes[roomKey] = {
        roomKey = roomKey,
        player = players[1].player,
        players = players,
        rvId = tostring(record.rvId),
        generation = integer(record.generation),
        bitmapVersion = integer(record.bitmapVersion),
        identityKey = players[1].identityKey,
        returnPosition = players[1].originalPosition,
        startTick = Core.tickAdd(now, 1),
        queuedDeadlineTick = Core.tickAdd(now,
            ROOF_REFRESH_QUEUED_DEADLINE_TICKS),
        dueTicks = nil,
        nextAttempt = 1,
        relocationStarted = false,
        relocationPhase = "queued",
        source = tostring(source or "room-transition"),
        scheduledAtTick = now,
        wallEventKeys = {},
        wallEventKey = type(eventKey) == "string" and eventKey ~= ""
            and eventKey or nil,
        wallCoordinateKey = type(coordinateKey) == "string"
            and coordinateKey ~= "" and coordinateKey or nil,
    }
    if type(eventKey) == "string" and eventKey ~= "" then
        pendingWallRoofRefreshes[roomKey].wallEventKeys[eventKey] = true
    end
    if type(coordinateKey) == "string" and coordinateKey ~= "" then
        pendingWallRoofRefreshes[roomKey].wallEventKeys[coordinateKey] = true
    end
    print("[RailroaderRVTest] roof refresh scheduled room=" .. roomKey
        .. " source=" .. tostring(source or "room-transition")
        .. " relocationStartTick=" .. Core.formatTick(Core.tickAdd(now, 1))
        .. " attempts=" .. tostring(ROOF_REFRESH_ATTEMPTS)
        .. " delayTicks=" .. tostring(ROOF_REFRESH_DELAY_TICKS))
    return true
end

local function rememberFollowUpWallRemoval(record, roomKey, eventKey,
    coordinateKey, now, waitingForGeneration)
    if type(record) ~= "table" or type(roomKey) ~= "string"
        or type(eventKey) ~= "string" or eventKey == "" then
        return false
    end
    local events = followUpWallRemovalEvents[roomKey]
    if type(events) ~= "table" then
        events = {}
        followUpWallRemovalEvents[roomKey] = events
    end
    if events[eventKey] ~= nil then return false end
    local count = 0
    for _ in pairs(events) do count = count + 1 end
    if count >= WALL_REMOVAL_FOLLOWUP_MAX then
        print("[RailroaderRVTest] wall removal follow-up rejected room="
            .. roomKey .. " reason=bounded-queue")
        return false
    end
    events[eventKey] = {
        roomKey = roomKey,
        rvId = tostring(record.rvId),
        eventKey = eventKey,
        coordinateKey = coordinateKey,
        waitingForGeneration = waitingForGeneration == true,
        expiresAtTick = Core.tickAdd(now or Adapter._ticks or Core.getTick(),
            WALL_REMOVAL_FOLLOWUP_TICKS),
    }
    print("[RailroaderRVTest] wall removal follow-up queued room=" .. roomKey
        .. " event=" .. eventKey)
    return true
end

local function pauseFollowUpWallRemovalDeadlines(now)
    local hasFollowUpEvents = false
    for _ in pairs(followUpWallRemovalEvents) do
        hasFollowUpEvents = true
        break
    end
    if not hasFollowUpEvents then return end
    now = Core.isTick(now) and now or Adapter._ticks or Core.getTick()
    for _, events in pairs(followUpWallRemovalEvents) do
        if type(events) == "table" then
            for _, event in pairs(events) do
                local expiresAt = type(event) == "table"
                    and event.expiresAtTick or nil
                if Core.isTick(expiresAt)
                    and Core.tickReached(expiresAt, now) then
                    event.waitingForGeneration = true
                end
            end
        end
    end
end

-- The generic removal path passes the authoritative captured shell object
-- before it is detached; direct thumpable destruction is covered separately.
-- In particular, 42.20.4's
-- SledgehammerDestroyPacket delegates to RemoveItemFromSquarePacket, which
-- raises OnObjectAboutToBeRemoved immediately before removeFromWorld and
-- removeFromSquare, including captured windows. OnDestroyIsoThumpable is
-- retained for direct thumpable destruction paths and uses the same matcher. Never infer ownership
-- from a coordinate, action name, or client payload.
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
    local nested = data.RailroaderRVTest
    local rvId = data.rvId ~= nil and tostring(data.rvId) or nil
    if type(nested) ~= "table"
        or tostring(data.owner) ~= OWNER
        or tostring(nested.owner) ~= OWNER
        or rvId == nil or rvId == ""
        or rvId ~= tostring(nested.rvId) then
        return false
    end
    local generation = integer(data.generation)
    local bitmapVersion = integer(data.bitmapVersion)
    if generation == nil or generation ~= integer(nested.generation)
        or bitmapVersion == nil
        or bitmapVersion ~= integer(nested.bitmapVersion) then
        return false
    end

    local role = nested.role
    return role == "wall-north" or role == "wall-west"
        or role == "corner-nw"
end

local function queueWallRoofRefreshForObject(object, source)
    local server = RV and RV.Server
    if object ~= nil and type(server) == "table"
        and server._templateProtectionRepairRemovalObject == object then
        return false
    end
    if not processIsServer() or not Boundary
        or type(Boundary.isCurrentShellWall) ~= "function" then
        return false
    end
    local cheapCheckOk, isCandidate = pcall(cheapShellWallCandidate, object)
    if not cheapCheckOk or not isCandidate then
        return false
    end

    local mapOk, map = pcall(mapData)
    if not mapOk or type(map) ~= "table" then return false end
    local match
    for _, record in pairs(map.locomotives or {}) do
        local wallOk, isCurrentWall = false, false
        if type(record) == "table" and record.rvId ~= nil
            and validRecord(record) then
            wallOk, isCurrentWall = pcall(Boundary.isCurrentShellWall,
                object, record.boundary)
        end
        if wallOk and isCurrentWall == true then
            if match then
                -- A duplicate current identity is not a reason to guess which
                -- mapping owns the object.  Leave the removal untouched and
                -- do not enqueue a cross-RV roof refresh.
                return false
            end
            match = record
        end
    end
    if not match then return false end
    local roomKey = roofRefreshRoomKey(match)
    if not roomKey then return false end

    local now = Adapter._ticks or Core.getTick()
    local eventKey, coordinateKey = wallRemovalEventKey(object, roomKey)
    if eventKey == nil then
        print("[RailroaderRVTest] wall removal rejected room=" .. roomKey
            .. " reason=stable-event-key-unavailable")
        return false
    end
    local seen = eventKey and seenWallRemovalEvents[eventKey] or nil
    if not seen and coordinateKey then
        seen = seenWallRemovalEvents[coordinateKey]
    end
    if type(seen) == "table" and seen.roomKey == roomKey
        and Core.isTick(seen.expiresAtTick)
        and Core.tickReached(seen.expiresAtTick, now) then
        print("[RailroaderRVTest] wall removal event suppressed room="
            .. roomKey .. " source=" .. tostring(source))
        return false
    end
    if eventKey ~= nil then
        local seenEvent = {
            roomKey = roomKey,
            expiresAtTick = Core.tickAdd(now, WALL_REMOVAL_EVENT_DEDUPE_TICKS),
        }
        seenWallRemovalEvents[eventKey] = seenEvent
        if coordinateKey then seenWallRemovalEvents[coordinateKey] = seenEvent end
    end

    -- The two events may be raised for one removal.  The room key is the
    -- current rvId:generation:bitmapVersion identity, so one delayed schedule
    -- collapses duplicates. A distinct stable event key during an active cycle
    -- is retained as a bounded follow-up instead of being swallowed.
    local pending = pendingWallRoofRefreshes[roomKey]
    if pending then
        local duplicate = type(pending.wallEventKeys) == "table"
            and (pending.wallEventKeys[eventKey] == true
                or coordinateKey ~= nil
                    and pending.wallEventKeys[coordinateKey] == true)
        if not duplicate then
            local retained = rememberFollowUpWallRemoval(match, roomKey,
                eventKey, coordinateKey, now)
            duplicate = retained == false
        end
        print("[RailroaderRVTest] wall removal event "
            .. (duplicate and "suppressed" or "follow-up-retained")
            .. " room=" .. roomKey .. " source=" .. tostring(source))
        return false
    end
    local generationBusy, roofBusy, mutexReason =
        serverTransactionMutexStatus()
    if generationBusy == nil or generationBusy or roofBusy then
        -- Keep the accepted wall event in the bounded in-memory follow-up
        -- queue until the service-wide transaction releases its mutex.  This
        -- prevents a generation/roof race from turning a real removal into a
        -- silently lost refresh.
        local retained = rememberFollowUpWallRemoval(match, roomKey,
            eventKey, coordinateKey, now, generationBusy == true)
        print("[RailroaderRVTest] wall removal deferred room=" .. roomKey
            .. " reason=" .. tostring(mutexReason or "transaction-busy")
            .. " retained=" .. tostring(retained))
        return retained
    end
    local scheduled = scheduleRoofRefresh(map, match, source, eventKey,
        coordinateKey)
    if scheduled then
        local tagRole, templateIndex
        local dataOk, data = call(object, "getModData")
        local tag = dataOk and type(data) == "table"
            and data.RailroaderRVTest or nil
        if type(tag) == "table" then
            tagRole = tag.role
            templateIndex = integer(tag.templateIndex)
        end
        print("[RailroaderRVTest] wall removal matched room=" .. roomKey
            .. " event=" .. tostring(eventKey)
            .. " coordinate=" .. tostring(coordinateKey)
            .. " role=" .. tostring(tagRole)
            .. " templateIndex=" .. tostring(templateIndex)
            .. " source=" .. tostring(source or "object-about-to-be-removed"))
        print("[RailroaderRVTest] wall roof refresh queued room=" .. roomKey
            .. " delayTicks=" .. tostring(ROOF_REFRESH_DELAY_TICKS)
            .. " attempts=" .. tostring(ROOF_REFRESH_ATTEMPTS)
            .. " source=" .. tostring(source or "object-about-to-be-removed"))
    end
    return scheduled
end

function Adapter.onObjectAboutToBeRemoved(object)
    queueWallRoofRefreshForObject(object, "object-about-to-be-removed")
end

-- Some direct IsoThumpable destruction paths expose the object through the
-- OnDestroyIsoThumpable event.  The normal 42.20.4 sledgehammer packet is
-- covered by OnObjectAboutToBeRemoved above; this second hook is intentionally
-- a strict, de-duplicated supplement rather than a client-command path.
function Adapter.onDestroyIsoThumpable(object)
    queueWallRoofRefreshForObject(object, "destroy-iso-thumpable")
end

-- Capture every live, current-schema player in the RV managed region before a
-- wall-removal refresh.  Coordinates and identity are read from the server;
-- the adapter passes only object references to RV_Server, which revalidates
-- each member before arming the remote relocation.
insidePlayersForRecord = function(map, record)
    local result = {}
    if type(map) ~= "table" or type(record) ~= "table"
        or type(record.players) ~= "table" then return result end
    local wanted = tostring(record.rvId or record.locoId)
    local players = onlinePlayersSnapshot()
    local area = rvRegion()
    for i = 1, #players do
        local player = players[i]
        local position = playerPositionInRegion(player, area)
        if position and inRegion(position, record.region) then
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
                    identityKey = tostring(relation.onlineId) .. ":" .. tostring(name),
                    originalPosition = copyPosition(position),
                }
            end
        end
    end
    return result
end

observeRoomTransitions = function(map, observedRooms)
    for roomKey, observed in pairs(observedRooms) do
        local previous = roomTransitionStates[roomKey]
        if observed.roomStateAvailable
            and previous and previous.inRoom == true
            and observed.inRoom ~= true then
            print("[RailroaderRVTest] room transition detected room=" .. roomKey
                .. " previous=inside current=outside refresh=not-scheduled-without-wall-removal")
        end
        if observed.roomStateAvailable then
            roomTransitionStates[roomKey] = {
                inRoom = observed.inRoom == true,
                hasRoom = observed.hasRoom == true,
                hasRoomDef = observed.hasRoomDef == true,
                observedAtTick = Adapter._ticks or Core.getTick(),
            }
        end
    end
    -- Do not carry a player's previous room state across a missing presence,
    -- disconnect, scope exit, or identity change.
    for roomKey in pairs(roomTransitionStates) do
        if not observedRooms[roomKey] then
            local pending = pendingWallRoofRefreshes[roomKey]
            local relocationActive = pending
                and pending.relocationPhase ~= "complete"
            if not relocationActive then
                roomTransitionStates[roomKey] = nil
                if pending then
                    pendingWallRoofRefreshes[roomKey] = nil
                    print("[RailroaderRVTest] roof refresh schedule cancelled room="
                        .. roomKey .. " reason=presence-lost")
                end
            end
        end
    end
    -- An object event can schedule after the previous 30-tick observation,
    -- so also cancel a schedule that has no prior transition-state entry.
    for roomKey in pairs(pendingWallRoofRefreshes) do
        if not observedRooms[roomKey] then
            local pending = pendingWallRoofRefreshes[roomKey]
            local relocationActive = pending
                and pending.relocationPhase ~= "complete"
            if not relocationActive then
                pendingWallRoofRefreshes[roomKey] = nil
                print("[RailroaderRVTest] roof refresh schedule cancelled room="
                    .. roomKey .. " reason=presence-lost")
            end
        end
    end
end


ctx.processStatelessRelocationSentinel = processStatelessRelocationSentinel
ctx.sampleRoofRefreshPlayers = sampleRoofRefreshPlayers
ctx.rememberFollowUpWallRemoval = rememberFollowUpWallRemoval
ctx.scheduleRoofRefresh = scheduleRoofRefresh
ctx.insidePlayersForRecord = insidePlayersForRecord
ctx.pauseFollowUpWallRemovalDeadlines = pauseFollowUpWallRemovalDeadlines
end
