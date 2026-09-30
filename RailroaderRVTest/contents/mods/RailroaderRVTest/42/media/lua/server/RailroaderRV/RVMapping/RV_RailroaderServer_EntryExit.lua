-- RV_RailroaderServer: EntryExit responsibilities.
return function(ctx)
local Core = require("RailroaderRV/Core/RV_Server_Core")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local ServerTeleport = require("RailroaderRV/Common/RV_ServerTeleport")
local processIsServer = ctx.processIsServer
local Boundary = ctx.Boundary
local Adapter = ctx.Adapter
local C = ctx.C
local function recordForLoco(...) return ctx.recordForLoco(...) end
local function roofRefreshTransactionBlocks(...) return ctx.roofRefreshTransactionBlocks(...) end
local sourceWithinRange
local number = ctx.number
local integer = ctx.integer
local call = ctx.call
local callGlobal = ctx.callGlobal
local safeCall = ctx.safeCall
local playerId = ctx.playerId
local playerName = ctx.playerName
local playerDead = ctx.playerDead
local playerPosition = ctx.playerPosition
local copyPosition = ctx.copyPosition
local newTransitionToken = ctx.newTransitionToken
local copyPose = ctx.copyPose
local trainId = ctx.trainId
local findTrain = ctx.findTrain
local trainPosition = ctx.trainPosition
local trainMoving = ctx.trainMoving
local trainPose = ctx.trainPose
local seatPosition = ctx.seatPosition
local besidePosition = ctx.besidePosition
local persistedBesidePosition = ctx.persistedBesidePosition
local hullDistance = ctx.hullDistance
local seatForPlayer = ctx.seatForPlayer
local freePassengerSeat = ctx.freePassengerSeat
local playerRole = ctx.playerRole
local forgetTrainSeat = ctx.forgetTrainSeat
local putPassenger = ctx.putPassenger
local putDriver = ctx.putDriver
local mapData = ctx.mapData
local markMappingChanged = ctx.markMappingChanged
local rvRegion = ctx.rvRegion
local validRegion = ctx.validRegion
local validMappingRecord = ctx.validMappingRecord
local validRecord = ctx.validRecord
local refreshRoofForPlayer = ctx.refreshRoofForPlayer
local armRoomOwnershipMonitor = ctx.armRoomOwnershipMonitor
local recordAtPlayerCoordinate = ctx.recordAtPlayerCoordinate

function Adapter.resolveCurrentUtilityRV(player)
    if not player or playerDead(player) then
        return false, "permission-denied"
    end
    local map = mapData()
    local name = playerName(player)
    local onlineId = playerId(player)
    local relation = name and map.players and map.players[name] or nil
    local record, _, train, status = recordAtPlayerCoordinate(map, player)
    local locomotiveSide = false
    if not record and status == "outside-rv" and onlineId ~= nil and name
        and type(relation) == "table" and relation.inside == false
        and type(map.locomotives) == "table" then
        local boundRecord = recordForLoco(map, relation.locoId)
        local rider = boundRecord and boundRecord.players
            and boundRecord.players[name] or nil
        if boundRecord and type(rider) == "table" and rider.inside == false
            and tostring(rider.locoId) == tostring(boundRecord.locoId)
            and tostring(relation.locoId) == tostring(boundRecord.locoId)
            and tostring(relation.onlineId) == tostring(onlineId)
            and tostring(rider.onlineId) == tostring(onlineId)
            and validMappingRecord(boundRecord) then
            local liveTrain = findTrain(boundRecord.locoId)
            if liveTrain and trainPosition(liveTrain)
                and sourceWithinRange(player, liveTrain) then
                record, train, status = boundRecord, liveTrain, "locomotive-bound"
                locomotiveSide = true
            end
        end
    end
    if not record then return false, status or "outside-rv" end
    local rider = name and record.players and record.players[name] or nil
    if onlineId == nil or not name or not relation or not rider
        or tostring(relation.locoId) ~= tostring(record.locoId)
        or tostring(rider.locoId) ~= tostring(record.locoId)
        or tostring(rider.onlineId) ~= tostring(onlineId)
        or (locomotiveSide and (relation.inside ~= false or rider.inside ~= false))
        or (not locomotiveSide and (relation.inside ~= true or rider.inside ~= true)) then
        return false, "permission-denied"
    end
    if not locomotiveSide then
        -- Reuse the existing authoritative boundary/player contract as the
        -- utility permission check.  It proves the persisted inside relation,
        -- stable online identity and current geometry; no client role field is
        -- accepted.  A utility context is authorized only for this mapping.
        local boundaryOk, _, boundaryRecord, boundaryRelation = pcall(
            Adapter.validateCurrentBoundaryPlayer, player)
        if not boundaryOk or boundaryRecord ~= record
            or type(boundaryRelation) ~= "table"
            or boundaryRelation.inside ~= true then
            return false, C.INVALID_RV_DATA
        end
    end
    return true, {
        identity = { rvId = tostring(record.rvId), generation = integer(record.generation) },
        record = record, relation = relation, train = train, status = status,
        phase = "READY",
        authorized = true, locomotiveSide = locomotiveSide,
    }
end

function Adapter.currentUtilityRecord(identity)
    local map = mapData()
    local record = recordForLoco(map, identity.rvId)
    if not record or not validMappingRecord(record)
        or integer(record.generation) ~= integer(identity.generation) then
        return false, C.INVALID_RV_DATA
    end
    return true, record
end

local function settleUtilityTransition(record, player, phase)
    local server = rawget(_G, "RailroaderRV")
        and RailroaderRV.Server or nil
    if not server or type(server.settleRVUtilityLoad) ~= "function" then
        print("[RailroaderRVTest] utility transition settlement unavailable phase="
            .. tostring(phase))
        return false
    end
    local ok, accepted, reason = pcall(server.settleRVUtilityLoad, {
        rvId = tostring(record.rvId), generation = record.generation,
    }, player)
    if not ok or accepted ~= true then
        print("[RailroaderRVTest] utility transition settlement failed phase="
            .. tostring(phase) .. " reason=" .. tostring(ok and reason or accepted))
        return false
    end
    return true
end

local function sendResult(player, ok, reason)
    local onlineId = playerId(player)
    if onlineId == nil then return end
    callGlobal("sendServerCommand", player, C.MOD_ID, C.COMMAND_RV_TELEPORT, {
        ok = ok == true, onlineId = onlineId, reason = reason,
    })
end

local function movePlayer(player, position, action, relation)
    if not player or not position then return false end
    local onlineId = playerId(player)
    if onlineId == nil then return false end
    local payload = {
            ok = true, action = action, onlineId = onlineId,
            x = position.x, y = position.y, z = position.z,
    }
    -- This is only a transition hint for the local Railroader adapter.  The
    -- server seat snapshot remains authoritative; no client coordinate/seat is
    -- accepted from this payload.
    if type(relation) == "table" then
        payload.locoId = relation.locoId
        payload.role = relation.role
        payload.seat = relation.seat
        if relation.rvId ~= nil and tostring(relation.rvId) ~= ""
            and integer(relation.generation) ~= nil
            and integer(relation.generation) >= 1 then
            payload.rvId = tostring(relation.rvId)
            payload.generation = integer(relation.generation)
        end
    end
    local sentCallOk, sentResult = callGlobal("sendServerCommand", player,
        C.MOD_ID, C.COMMAND_RV_TELEPORT, payload)
    local sent = sentCallOk and sentResult ~= false
    -- A single-player world has no network command channel.  Its official
    -- TrainEntity/Ride state is updated locally; the same call still sends the
    -- RVTeleport hint when the channel exists.  MP/co-op must have the command
    -- path or the transaction fails closed.
    if not sent and processIsServer() then return false end
    if action == "enter" and type(relation) == "table" then
        return ServerTeleport.teleportToRVSpawn(player, relation, position)
    end
    return ServerTeleport.teleportToPosition(player, position)
end

local function markPlayerOutside(map, record, key, player, position, seat, role)
    local name = playerName(player)
    if not name then return end
    local relation = map.players[name]
    if type(relation) ~= "table" then relation = {} end
    relation.locoId = record and tostring(record.locoId) or relation.locoId
    relation.onlineId = playerId(player)
    relation.inside = false
    relation.role = role
    relation.seat = seat
    relation.exitPosition = copyPosition(position)
    map.players[name] = relation
    if record then
        if type(record.players) ~= "table" then
            error(C.INVALID_RV_DATA)
        end
        local rider = record.players[name]
        if type(rider) ~= "table" then rider = {} end
        rider.onlineId = playerId(player)
        rider.inside = false
        rider.role = role
        rider.seat = seat
        rider.exitPosition = copyPosition(position)
        record.players[name] = rider
    end
end

local function markPlayerInside(map, record, key, player, sourcePosition,
    sourceRole, sourceSeat)
    local name = playerName(player)
    if not name then error("Railroader RV player username is unavailable") end
    local enterPosition = copyPosition(sourcePosition)
    if not enterPosition then error(C.INVALID_RV_DATA) end
    local relation = {
        locoId = tostring(record.locoId),
        onlineId = playerId(player), inside = true,
        role = sourceRole, seat = sourceSeat,
        enterPosition = enterPosition,
    }
    map.players[name] = relation
    if type(record.players) ~= "table" then
        error(C.INVALID_RV_DATA)
    end
    record.players[name] = {
        locoId = tostring(record.locoId),
        onlineId = relation.onlineId, inside = true,
        role = sourceRole, seat = sourceSeat,
        enterPosition = enterPosition,
    }
end

local function otherGeneratedRecord(map, locoId)
    local wanted = tostring(locoId)
    for _, record in pairs(map.locomotives or {}) do
        if validRecord(record) and tostring(record.locoId) ~= wanted then
            return record
        end
    end
    return nil
end

sourceWithinRange = function(player, train)
    local distance = hullDistance(player, train)
    local rr = rawget(_G, "RR")
    local officialReach = rr and rr.Ride and rr.Ride.MOUNT_REACH
    local reach = number(officialReach) or number(C.RV_MOUNT_REACH)
    return distance ~= nil and distance <= reach
end

local function requestData(train, player, role, seat, sourcePosition)
    local entryPosition = copyPosition(sourcePosition)
    local locoPosition = trainPose(train)
    if not entryPosition or not locoPosition then
        error(C.INVALID_RV_DATA)
    end
    return {
        locoId = tostring(trainId(train)), sourceRole = role, sourceSeat = seat,
        playerUsername = playerName(player), playerOnlineId = playerId(player),
        entryPosition = entryPosition,
        -- The server's generation transaction allocates this locomotive a
        -- current-schema matrix slot before relocation; no fixed destination
        -- is captured from the entry event.
        locoPosition = locoPosition,
    }
end

local function removeSeatForEntry(train, player, onlineId)
    return forgetTrainSeat(train, player, onlineId)
end

local function enterExisting(player, train, record, key, sourceRole,
    sourceSeat, sourcePosition, map)
    local roofBlocked, roofReason = roofRefreshTransactionBlocks(record.rvId)
    if roofBlocked then
        return false, roofReason
    end
    if not Boundary or type(Boundary.beginTransition) ~= "function"
        or type(Boundary.completeTransition) ~= "function" then
        return false, "RV boundary entry service is unavailable"
    end
    local rv = rawget(_G, "RailroaderRV")
    local server = type(rv) == "table" and rv.Server or nil
    local construction = type(server) == "table"
        and server.Construction or nil
    if type(construction) ~= "table"
        or type(construction.ensureGeneratorForEntry) ~= "function" then
        return false, "RV generator entry check is unavailable"
    end
    local generatorCallOk, generatorReady, generatorReason = pcall(
        construction.ensureGeneratorForEntry, player, record)
    if not generatorCallOk then generatorReason = generatorReady end
    if generatorReady ~= true then
        return false, generatorReason or C.INVALID_RV_DATA
    end
    local onlineId = playerId(player)
    local target = copyPosition(record.rvPosition)
    if not target then return false, C.INVALID_RV_DATA end
    -- Re-arm the persistent client stale-room monitor before changing seats or
    -- moving the player.
    local monitorOk, monitorReason = armRoomOwnershipMonitor(player, record,
        "existing-entry")
    if not monitorOk then return false, monitorReason end
    local transitionToken = newTransitionToken("entry", record)
    if Boundary and type(Boundary.beginTransition) == "function" then
        local armed = Boundary.beginTransition(player, record.locoId,
            record.generation, transitionToken, "entry")
        if armed ~= true then
            return false, "RV boundary entry transition could not be armed"
        end
    end
    local removedRole, removedSeat = removeSeatForEntry(train, player, onlineId)
    if removedRole == "external" then removedSeat = nil end
    local oldRelation = map.players[playerName(player)]
    local oldRiders = {}
    for riderName, rider in pairs(record.players or {}) do
        oldRiders[riderName] = rider
    end
    markPlayerInside(map, record, key, player, sourcePosition, sourceRole,
        sourceSeat)
    local moved = movePlayer(player, target, "enter", {
        locoId = trainId(train), role = sourceRole, seat = sourceSeat,
        rvId = record.locoId, generation = record.generation,
    })
    if not moved then
        map.players[playerName(player)] = oldRelation
        record.players = oldRiders
        if removedRole == "driver" then
            putDriver(train, player, onlineId)
        elseif removedRole == "passenger" and removedSeat ~= nil then
            putPassenger(train, player, onlineId, removedSeat)
        end
        if Boundary and type(Boundary.clearPlayer) == "function" then
            Boundary.clearPlayer(player)
        end
        return false, "RV entry teleport failed"
    end
    if Boundary and type(Boundary.completeTransition) == "function" then
        Boundary.completeTransition(player, transitionToken)
    end
    settleUtilityTransition(record, player, "entry")
    record.locoPosition = trainPose(train) or record.locoPosition
    -- The server has just moved the player into the persisted RV footprint;
    -- synchronize room and roof metadata around the existing captured floor
    -- before the first repeat-entry frame is rendered. A failed or deferred
    -- refresh is retried by OnTick without rejecting the successful teleport.
    refreshRoofForPlayer(player, record, true, "existing-entry")
    markMappingChanged()
    return true
end

local function enterPlayer(player, locoId)
    if not player or playerDead(player) then
        return false, "player is unavailable"
    end
    local onlineId, name = playerId(player), playerName(player)
    if onlineId == nil or not name then return false, "player identity is unavailable" end
    -- Check before removing a Railroader seat or changing mapping state.  The
    -- generation service repeats the global check authoritatively, but this
    -- early RV-specific gate avoids a temporary seat mutation on rejection.
    local roofBlocked, roofReason = roofRefreshTransactionBlocks(locoId)
    if roofBlocked then
        return false, roofReason
    end
    local map = mapData()
    local existingRecord, existingKey, _, lookupState =
        recordAtPlayerCoordinate(map, player)
    if lookupState == "unmapped-rv" then
        return false, C.INVALID_RV_DATA
    end
    if existingRecord then return false, "player is already inside an RV" end
    local train = findTrain(locoId)
    if not train then return false, "target is not an active Railroader locomotive" end
    local role, seat = playerRole(train, onlineId)
    local moving = trainMoving(train)
    if moving and role ~= "passenger" then
        return false, role == "driver" and "driver cannot enter while moving"
            or "outside player cannot enter a moving locomotive"
    end
    if role == "external" and not sourceWithinRange(player, train) then
        return false, "player is outside locomotive interaction range"
    end
    local sourcePosition = role == "external" and playerPosition(player)
        or seatPosition(train, seat or 0) or playerPosition(player)
    if not sourcePosition then return false, "entry position is unavailable" end

    local record, key = recordForLoco(map, trainId(train))
    if record and validRecord(record) then
        return enterExisting(player, train, record, key, role, seat,
            sourcePosition, map)
    end
    if otherGeneratedRecord(map, trainId(train)) then
        return false, "the RV is already assigned to another locomotive"
    end

    -- A passenger is removed before the staging relocation.  Otherwise the
    -- official seat pin would immediately drag the player back to the moving
    -- locomotive while the generation stream is loading.
    local removedRole, removedSeat = removeSeatForEntry(train, player, onlineId)
    local data = requestData(train, player, role, seat, sourcePosition)
    data.removedRole, data.removedSeat = removedRole, removedSeat
    data.sourcePosition = copyPosition(sourcePosition)
    local rv = RailroaderRV.Server
    if not rv or type(rv.requestRailroaderGeneration) ~= "function" then
        if removedRole == "driver" then putDriver(train, player, onlineId) end
        if removedRole == "passenger" and removedSeat then
            putPassenger(train, player, onlineId, removedSeat)
        end
        return false, "RV generation transaction is unavailable"
    end
    local queued, reason = rv.requestRailroaderGeneration(player, data)
    if not queued then
        if removedRole == "driver" then putDriver(train, player, onlineId) end
        if removedRole == "passenger" and removedSeat then
            putPassenger(train, player, onlineId, removedSeat)
        end
        return false, reason or "RV generation request was refused"
    end
    return true
end

local function restoreAfterGenerationFailure(player, data)
    if type(data) ~= "table" or not player then return end
    local train = findTrain(data.locoId)
    local onlineId = playerId(player)
    if train and onlineId ~= nil then
        local role = data.removedRole
        if role == "driver" and train.driver == nil then
            putDriver(train, player, onlineId)
        elseif role == "passenger" and data.removedSeat ~= nil
            and seatForPlayer(train, onlineId) == nil then
            local occupied = false
            for _, assigned in pairs(train.passengers or {}) do
                if number(assigned) == number(data.removedSeat) then occupied = true end
            end
            if not occupied then putPassenger(train, player, onlineId, data.removedSeat) end
        end
    end
    local source = copyPosition(data.sourcePosition)
    if source then
        movePlayer(player, source, "generation-failed", {
            locoId = data.locoId, role = data.sourceRole, seat = data.sourceSeat,
            rvId = data.rvId, generation = data.generation,
        })
    end
    if Boundary and type(Boundary.clearPlayer) == "function" then
        Boundary.clearPlayer(player)
    end
end

local function commitGeneration(player, data, prepared)
    local map = mapData()
    local locoId = tostring(data.locoId)
    local generation = integer(prepared and prepared.generation)
    local slotIndex = integer(prepared and prepared.slotIndex)
    local anchor = copyPosition(data and data.anchor)
    if not generation or not slotIndex
        or slotIndex ~= integer(data and data.slotIndex)
        or type(prepared.anchor) ~= "table" or not anchor
        or anchor.x ~= integer(prepared.anchor.x)
        or anchor.y ~= integer(prepared.anchor.y)
        or anchor.z ~= integer(prepared.anchor.z)
        or RegionSlots.indexForAnchor(anchor) ~= slotIndex
        or RegionSlots.indexForRegion({ minX = data.region.minX,
            minY = data.region.minY, maxX = data.region.maxX,
            maxY = data.region.maxY }) ~= slotIndex
        or not validRegion(data.region) then
        return false, C.INVALID_RV_DATA
    end
    for otherKey, other in pairs(map.locomotives or {}) do
        if tostring(otherKey) ~= locoId
            and integer(other and other.slotIndex) == slotIndex then
            return false, "RV candidate slot became occupied before mapping commit"
        end
    end
    if type(prepared.boundary) ~= "table" then
        return false, "RV boundary manifest registration failed"
    end
    local record, key = recordForLoco(map, locoId)
    key = key or locoId
    local candidateRecord = {}
    if record then
        for field, value in pairs(record) do candidateRecord[field] = value end
    end
    candidateRecord.players = {}
    if record and type(record.players) == "table" then
        for name, rider in pairs(record.players) do
            candidateRecord.players[name] = rider
        end
    end
    local candidateMap = {
        schemaVersion = map.schemaVersion,
        locomotives = {},
        players = {},
    }
    for entryKey, entry in pairs(map.locomotives or {}) do
        candidateMap.locomotives[entryKey] = entry
    end
    for name, relation in pairs(map.players or {}) do
        candidateMap.players[name] = relation
    end
    candidateMap.locomotives[key] = candidateRecord
    local train = findTrain(locoId)
    candidateRecord.generated = true
    candidateRecord.locoId = locoId
    candidateRecord.rvId = locoId
    candidateRecord.generation = generation
    candidateRecord.slotIndex = slotIndex
    candidateRecord.anchor = anchor
    if not candidateRecord.slotIndex or not candidateRecord.anchor
        or not validRegion(data.region) then return false, C.INVALID_RV_DATA end
    candidateRecord.region = {
        minX = integer(data.region.minX), minY = integer(data.region.minY),
        maxX = integer(data.region.maxX), maxY = integer(data.region.maxY),
        minZ = integer(data.region.minZ), maxZ = integer(data.region.maxZ),
    }
    candidateRecord.rvPosition = copyPosition(data.rvPosition)
    candidateRecord.enterPosition = copyPosition(data.entryPosition)
    candidateRecord.locoPosition = train and trainPose(train)
        or copyPose(data.locoPosition)
    candidateRecord.boundary = prepared.boundary
    if not candidateRecord.rvPosition or not candidateRecord.enterPosition
        or not candidateRecord.locoPosition
        or number(candidateRecord.locoPosition.dirX) == nil
        or number(candidateRecord.locoPosition.dirY) == nil then
        return false, C.INVALID_RV_DATA
    end
    candidateRecord.updatedAt = math.floor(os.time())
    local validatedOk, validated = pcall(validMappingRecord, candidateRecord)
    if not validatedOk or validated ~= true then
        return false, C.INVALID_RV_DATA
    end
    local relationOk = pcall(markPlayerInside, candidateMap, candidateRecord,
        key, player, data.entryPosition, data.sourceRole, data.sourceSeat)
    if not relationOk then return false, C.INVALID_RV_DATA end
    if not Boundary or type(Boundary.registerGeneration) ~= "function"
        or Boundary.registerGeneration(candidateRecord.rvId,
            candidateRecord.generation, candidateRecord.boundary,
            candidateRecord) ~= true then
        return false, C.INVALID_RV_DATA
    end
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.initializeUtilityRecord) ~= "function" then
        return false, C.INVALID_RV_DATA
    end
    -- Publish this server-constructed current-schema candidate in one
    -- synchronous table swap. Generation finalization performs no fallible
    -- work after utility initialization.
    local oldLocomotives, oldPlayers = map.locomotives, map.players
    map.locomotives, map.players = candidateMap.locomotives,
        candidateMap.players
    local changedOk, changedError = pcall(markMappingChanged)
    if not changedOk then
        map.locomotives, map.players = oldLocomotives, oldPlayers
        pcall(markMappingChanged)
        return false, tostring(changedError)
    end
    -- Utility initialization commits a separate ModData record and applies
    -- generator state. Keep Mapping first so a failed map publication cannot
    -- leave an orphan utility record. A failed Utility init restores the exact
    -- prior Mapping tables; GenerationFlow then rolls back this world generation.
    -- Omitting player suppresses the pre-finalization client snapshot; the
    -- server-cell fallback still resolves the just-built generator, while the
    -- settled post-commit refresh below broadcasts only after Mapping is current.
    local utilityOk, utilityAccepted, utilityReason = pcall(
        server.initializeUtilityRecord,
        { rvId = candidateRecord.rvId, generation = candidateRecord.generation },
        { identity = {
            rvId = candidateRecord.rvId, generation = candidateRecord.generation,
        }, record = candidateRecord })
    if not utilityOk or utilityAccepted ~= true then
        map.locomotives, map.players = oldLocomotives, oldPlayers
        pcall(markMappingChanged)
        return false, utilityOk and (utilityReason or C.INVALID_RV_DATA)
            or tostring(utilityAccepted)
    end
    if type(server.settleRVUtilityLoad) == "function" then
        local settleOk, settled, settleReason = pcall(server.settleRVUtilityLoad,
            { rvId = tostring(candidateRecord.rvId),
                generation = candidateRecord.generation }, player)
        if not settleOk or settled ~= true then
            print("[RailroaderRVTest] new RV entry load refresh failed reason="
                .. tostring(settleOk and settleReason or settled))
        end
    end
    -- RV_Server owns the transition close after FinalRelocateAck and the
    -- current-manifest readiness proof. Do not release the lease from this
    -- mapping commit hook before that final client proof.
    pcall(refreshRoofForPlayer, player, candidateRecord, true, "generation-entry")
    return true
end

local function validateGeneration(player, data)
    if not player or playerDead(player) then return false, "player is dead" end
    local train = data and findTrain(data.locoId)
    if not train then return false, "locomotive disappeared during generation" end
    if data.sourceRole ~= "passenger" and trainMoving(train) then
        return false, "locomotive started moving before RV generation completed"
    end
    return true
end

local function exitPlayer(player)
    if not player or playerDead(player) then
        return false, "player is unavailable"
    end
    if not Boundary or type(Boundary.beginTransition) ~= "function"
        or type(Boundary.completeTransition) ~= "function" then
        return false, "RV boundary exit service is unavailable"
    end
    local map = mapData()
    local record, key, train, lookupState =
        recordAtPlayerCoordinate(map, player)
    if lookupState == "outside-rv" then
        return false, "player is outside the RV area"
    end
    if not record then
        return false, C.INVALID_RV_DATA
    end
    local roofBlocked, roofReason = roofRefreshTransactionBlocks(record.rvId)
    if roofBlocked then
        return false, roofReason
    end
    if not train then
        local target = persistedBesidePosition(record)
        if not target then return false, C.INVALID_RV_DATA end
        -- The mapping is valid but the locomotive is inactive/unloaded.  Do
        -- not invent a driver/passenger seat; use only a persisted beside
        -- target and retain the explicit state for diagnostics and tests.
        if lookupState ~= "inactive-mapped" then return false, C.INVALID_RV_DATA end
        local transitionToken = newTransitionToken("exit", record)
        if Boundary and type(Boundary.beginTransition) == "function" then
            local armed = Boundary.beginTransition(player, record.locoId,
                record.generation, transitionToken, "exit")
            if armed ~= true then
                return false, "RV boundary exit transition could not be armed"
            end
        end
        settleUtilityTransition(record, player, "exit-before-teleport")
        local moved = movePlayer(player, target, "exit", {
            locoId = record.locoId, role = "beside", seat = nil,
            rvId = record.locoId, generation = record.generation,
        })
        if not moved then
            if Boundary and type(Boundary.completeTransition) == "function" then
                Boundary.completeTransition(player, transitionToken)
            end
            return false, "inactive locomotive exit teleport failed"
        end
        markPlayerOutside(map, record, key, player, target, nil, "beside")
        if Boundary and type(Boundary.clearPlayer) == "function" then
            Boundary.clearPlayer(player)
        end
        markMappingChanged()
        return true
    end
    local onlineId = playerId(player)
    if onlineId == nil then return false, "player identity is unavailable" end
    local moving = trainMoving(train)
    local seat, role, target
    if moving then
        seat = freePassengerSeat(train)
        if not seat then return false, "all passenger positions are occupied" end
        target = seatPosition(train, seat)
        role = "passenger"
    else
        seat = freePassengerSeat(train)
        if seat then
            target, role = seatPosition(train, seat), "passenger"
        elseif train.driver == nil then
            target, role, seat = seatPosition(train, 0), "driver", 0
        else
            target, role = besidePosition(train), "beside"
            seat = nil
        end
    end
    if not target then return false, "locomotive exit position is unavailable" end

    local transitionToken = newTransitionToken("exit", record)
    if Boundary and type(Boundary.beginTransition) == "function" then
        local armed = Boundary.beginTransition(player, record.locoId,
            record.generation, transitionToken, "exit")
        if armed ~= true then
            return false, "RV boundary exit transition could not be armed"
        end
    end

    local assigned = false
    if role == "passenger" then assigned = putPassenger(train, player, onlineId, seat)
    elseif role == "driver" then assigned = putDriver(train, player, onlineId) end
    if role ~= "beside" and not assigned then
        if Boundary and type(Boundary.completeTransition) == "function" then
            Boundary.completeTransition(player, transitionToken)
        end
        return false, "locomotive seat became occupied"
    end
    settleUtilityTransition(record, player, "exit-before-teleport")
    local moved = movePlayer(player, target, "exit", {
        locoId = trainId(train), role = role, seat = seat,
        rvId = record.locoId, generation = record.generation,
    })
    if not moved then
        if role ~= "beside" then forgetTrainSeat(train, player, onlineId) end
        if Boundary and type(Boundary.completeTransition) == "function" then
            Boundary.completeTransition(player, transitionToken)
        end
        return false, "RV exit teleport failed"
    end
    record.locoPosition = trainPose(train) or record.locoPosition
    markPlayerOutside(map, record, key, player, target, seat, role)
    if Boundary and type(Boundary.clearPlayer) == "function" then
        Boundary.clearPlayer(player)
    end
    markMappingChanged()
    return true
end


ctx.sendResult = sendResult
ctx.movePlayer = movePlayer
ctx.enterPlayer = enterPlayer
ctx.restoreAfterGenerationFailure = restoreAfterGenerationFailure
ctx.commitGeneration = commitGeneration
ctx.validateGeneration = validateGeneration
ctx.exitPlayer = exitPlayer
end
