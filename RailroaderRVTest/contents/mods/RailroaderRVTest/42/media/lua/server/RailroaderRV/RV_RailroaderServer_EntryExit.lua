-- RV_RailroaderServer: EntryExit responsibilities.
return function(ctx)
local RemovalTrace = require("RailroaderRV/RV_Server_ObjectRemovalTrace")
local processIsServer = ctx.processIsServer
local Boundary = ctx.Boundary
local Adapter = ctx.Adapter
local C = ctx.C
local function recordForLoco(...) return ctx.recordForLoco(...) end
local function roofRefreshTransactionBlocks(...) return ctx.roofRefreshTransactionBlocks(...) end
local function currentGeometryGate(...) return ctx.currentGeometryGate(...) end
local function sourceWithinRange(...) return ctx.sourceWithinRange(...) end
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

local function transitionPositionText(position)
    if type(position) ~= "table" then return "unavailable" end
    return tostring(position.x) .. "," .. tostring(position.y) .. ","
        .. tostring(position.z)
end

local function traceTransition(path, player, record, detail)
    local id = playerId(player)
    local name = playerName(player)
    local positionOk, position = pcall(playerPosition, player)
    if not positionOk then position = nil end
    local stateKey = id ~= nil and name
        and (tostring(id) .. ":" .. tostring(name)) or nil
    local state = stateKey and Boundary and Boundary._states
        and Boundary._states[stateKey] or nil
    local validationRefreshAge = state and Boundary and Boundary._tick ~= nil
        and (Boundary._tick - (integer(state.validationRefreshTick) or -math.huge))
        or "unavailable"
    print("[RailroaderRVTest][TransitionTrace] path=" .. tostring(path)
        .. " tick=" .. tostring(Adapter._ticks or "unknown")
        .. " player=" .. tostring(stateKey or name or "unknown")
        .. " pos=" .. transitionPositionText(position)
        .. " rvId=" .. tostring(record and record.rvId or "unknown")
        .. " generation=" .. tostring(record and record.generation or "unknown")
        .. " bitmapVersion=" .. tostring(record and record.bitmapVersion or "unknown")
        .. " boundaryValidationRefreshTick=" .. tostring(state and state.validationRefreshTick or "nil")
        .. " boundaryValidationRefreshAge=" .. tostring(validationRefreshAge)
        .. " boundaryTransition=" .. tostring(state and state.transitionKind or "nil")
        .. " boundaryTransitionToken=" .. tostring(state and state.transitionToken or "nil")
        .. " detail=" .. tostring(detail or "none"))
end

function Adapter.resolveCurrentUtilityRV(player)
    if not player or playerDead(player) then
        return false, "permission-denied"
    end
    local mapOk, mapOrReason = pcall(mapData)
    if not mapOk or type(mapOrReason) ~= "table" then
        return false, C.INVALID_RV_DATA
    end
    local map = mapOrReason
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
    local rv = rawget(_G, "RailroaderRV")
    local server = rv and rv.Server
    if not server or type(server.validateCurrentRVRecord) ~= "function" then
        return false, C.INVALID_RV_DATA
    end
    local gateOk, gateResult = pcall(server.validateCurrentRVRecord, record)
    if not gateOk or gateResult ~= true then return false, C.INVALID_RV_DATA end
    return true, {
        identity = { rvId = tostring(record.rvId), generation = integer(record.generation),
            bitmapVersion = integer(record.bitmapVersion) },
        record = record, relation = relation, train = train, status = status,
        phase = "READY",
        authorized = true, locomotiveSide = locomotiveSide,
    }
end

-- Tick settlement has no client player to use as an identity source.  It
-- still needs the complete current map/manifest/geometry gate before a
-- persisted utility record can be touched, so expose the same read-only
-- validation without accepting coordinates or RV identity from a request.
function Adapter.validateCurrentUtilityIdentity(identity)
    local function reject(stage)
        print("[RailroaderRVTest] utility identity gate rejected stage=" .. stage)
        return false, C.INVALID_RV_DATA
    end
    if type(identity) ~= "table" or type(identity.rvId) ~= "string"
        or identity.rvId == "" or integer(identity.generation) == nil
        or integer(identity.bitmapVersion) ~= C.BITMAP_VERSION then
        return reject("identity")
    end
    local mapOk, map = pcall(mapData)
    if not mapOk or type(map) ~= "table" then
        return reject("map-read")
    end
    local record = recordForLoco(map, identity.rvId)
    if not record then
        return reject("mapping-missing")
    end
    if not validMappingRecord(record)
        or integer(record.generation) ~= integer(identity.generation)
        or integer(record.bitmapVersion) ~= integer(identity.bitmapVersion) then
        return reject("mapping-schema-or-identity")
    end
    local rv = rawget(_G, "RailroaderRV")
    local server = rv and rv.Server
    if not server or type(server.currentRVManifestForBoundary) ~= "function"
        or type(server.currentRVRecordGeometryConsistent) ~= "function" then
        return reject("server-gate-missing")
    end
    local manifestOk, manifestAccepted, manifest = pcall(
        server.currentRVManifestForBoundary, record.rvId, record.generation,
        record.bitmapVersion)
    if not manifestOk or manifestAccepted ~= true or type(manifest) ~= "table" then
        return reject("manifest")
    end
    local geometryOk, consistent = pcall(
        server.currentRVRecordGeometryConsistent, record, manifest)
    if not geometryOk or consistent ~= true then
        return reject("geometry")
    end
    return true, { record = record, train = findTrain(record.locoId) }
end

function Adapter.currentUtilityRecord(identity)
    local ok, validated = Adapter.validateCurrentUtilityIdentity(identity)
    if ok ~= true or type(validated) ~= "table"
        or type(validated.record) ~= "table" then
        return false, C.INVALID_RV_DATA
    end
    return true, validated.record
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
        bitmapVersion = record.bitmapVersion,
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
            and integer(relation.generation) >= 1
            and integer(relation.bitmapVersion) ~= nil
            and integer(relation.bitmapVersion) == C.BITMAP_VERSION then
            payload.rvId = tostring(relation.rvId)
            payload.generation = integer(relation.generation)
            payload.bitmapVersion = integer(relation.bitmapVersion)
            payload.mapSchemaVersion = C.MAP_SCHEMA_VERSION
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
    return safeCall(player, "teleportTo", position.x, position.y, position.z)
end

local function markPlayerOutside(map, record, key, player, position, seat, role)
    local name = playerName(player)
    if not name then return end
    local relation = map.players[name]
    if type(relation) ~= "table" then relation = {} end
    relation.locoId = record and tostring(record.locoId) or relation.locoId
    relation.onlineId = playerId(player)
    relation.schemaVersion = C.RV_RELATION_SCHEMA_VERSION
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
        rider.schemaVersion = C.RV_RELATION_SCHEMA_VERSION
        rider.onlineId = playerId(player)
        rider.inside = false
        rider.role = role
        rider.seat = seat
        rider.exitPosition = copyPosition(position)
        record.players[name] = rider
    end
    RemovalTrace.lifecycle("mapping", "inside", "exited", ctx.serverTick)
end

local function markPlayerInside(map, record, key, player, sourcePosition,
    sourceRole, sourceSeat)
    local name = playerName(player)
    if not name then error("Railroader RV player username is unavailable") end
    local enterPosition = copyPosition(sourcePosition)
    if not enterPosition then error(C.INVALID_RV_DATA) end
    local relation = {
        schemaVersion = C.RV_RELATION_SCHEMA_VERSION,
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
        schemaVersion = C.RV_RELATION_SCHEMA_VERSION,
        locoId = tostring(record.locoId),
        onlineId = relation.onlineId, inside = true,
        role = sourceRole, seat = sourceSeat,
        enterPosition = enterPosition,
    }
    RemovalTrace.lifecycle("mapping", "inside", "entered", ctx.serverTick)
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
        region = rvRegion(), rvPosition = {
            x = integer(C.TELEPORT_X) + 0.5,
            y = integer(C.TELEPORT_Y) + 0.5,
            z = integer(C.TELEPORT_Z),
        },
        locoPosition = locoPosition,
    }
end

local function removeSeatForEntry(train, player, onlineId)
    return forgetTrainSeat(train, player, onlineId)
end

local function enterExisting(player, train, record, key, sourceRole,
    sourceSeat, sourcePosition, map)
    traceTransition("EntryExit.enterExisting.begin", player, record,
        "sourceRole=" .. tostring(sourceRole) .. " sourceSeat=" .. tostring(sourceSeat)
            .. " sourcePos=" .. transitionPositionText(sourcePosition))
    local roofBlocked, roofReason = roofRefreshTransactionBlocks(record.rvId)
    if roofBlocked then
        traceTransition("EntryExit.enterExisting.roofRefreshBlocked", player,
            record, roofReason)
        return false, roofReason
    end
    local geometryOk, geometryReason = currentGeometryGate(record)
    if not geometryOk then
        traceTransition("EntryExit.enterExisting.geometryRejected", player,
            record, geometryReason)
        return false, geometryReason
    end
    if not Boundary or type(Boundary.beginTransition) ~= "function"
        or type(Boundary.completeTransition) ~= "function" then
        return false, "RV boundary entry service is unavailable"
    end
    if type(Boundary.ensureGeneratorForEntry) ~= "function" then
        return false, "RV generator entry check is unavailable"
    end
    local generatorCallOk, generatorReady, generatorReason = pcall(
        Boundary.ensureGeneratorForEntry, player, record)
    if not generatorCallOk then generatorReason = generatorReady end
    if generatorReady ~= true then
        return false, generatorReason or C.INVALID_RV_DATA
    end
    local onlineId = playerId(player)
    local target = copyPosition(record.rvPosition)
    if not target then return false, C.INVALID_RV_DATA end
    -- Re-arm the persistent client stale-room monitor before changing seats or
    -- moving the player.  A missing/incompatible current manifest therefore
    -- fails closed without performing the RV teleport.
    local monitorOk, monitorReason = armRoomOwnershipMonitor(player, record,
        "existing-entry")
    if not monitorOk then return false, monitorReason end
    local transitionToken = newTransitionToken("entry", record)
    if Boundary and type(Boundary.beginTransition) == "function" then
        local armed = Boundary.beginTransition(player, record.locoId,
            record.generation, transitionToken, "entry", record.bitmapVersion)
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
        bitmapVersion = record.bitmapVersion,
    })
    traceTransition("EntryExit.enterExisting.teleportResult", player, record,
        "moved=" .. tostring(moved) .. " target=" .. transitionPositionText(target)
            .. " phase=entry")
    if not moved then
        map.players[playerName(player)] = oldRelation
        record.players = oldRiders
        RemovalTrace.lifecycle("mapping", "inside", "restored", ctx.serverTick)
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
    traceTransition("EntryExit.enterExisting.mappingCommitted", player, record,
        "transitionToken=" .. tostring(transitionToken) .. " inside=true")
    settleUtilityTransition(record, player, "entry")
    record.locoPosition = trainPose(train) or record.locoPosition
    -- The server has just moved the player into the persisted RV footprint;
    -- synchronize room and roof metadata around the existing captured floor
    -- before the first repeat-entry frame is rendered. A failed or deferred
    -- refresh is retried by OnTick without rejecting the successful teleport.
    refreshRoofForPlayer(player, record, true, "existing-entry")
    markMappingChanged()
    RemovalTrace.lifecycle("mapping", "server-state", "updated", ctx.serverTick)
    RemovalTrace.lifecycle("entry", "RV", "complete", ctx.serverTick)
    return true
end

local function enterPlayer(player, locoId)
    traceTransition("EntryExit.enterPlayer.begin", player, nil,
        "requestedLocoId=" .. tostring(locoId))
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
        traceTransition("EntryExit.enterPlayer.roofRefreshBlocked", player, nil,
            "requestedLocoId=" .. tostring(locoId) .. " reason=" .. tostring(roofReason))
        return false, roofReason
    end
    local map = mapData()
    local existingRecord, existingKey, _, lookupState =
        recordAtPlayerCoordinate(map, player)
    traceTransition("EntryExit.enterPlayer.coordinateLookup", player,
        existingRecord, "requestedLocoId=" .. tostring(locoId)
            .. " lookupState=" .. tostring(lookupState)
            .. " existingKey=" .. tostring(existingKey))
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
            bitmapVersion = data.bitmapVersion,
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
    if not generation or not Boundary
        or type(prepared and prepared.boundary) ~= "table"
        or type(Boundary.registerGeneration) ~= "function"
        or not Boundary.registerGeneration(locoId, generation,
            prepared.boundary, nil) then
        return false, "RV boundary manifest registration failed"
    end
    local record, key = recordForLoco(map, locoId)
    if not record then
        key, record = locoId, {}
        map.locomotives[key] = record
    end
    local train = findTrain(locoId)
    record.schemaVersion = C.RV_RECORD_SCHEMA_VERSION
    record.generated = true
    record.locoId = locoId
    record.rvId = locoId
    record.generation = generation
    if not validRegion(data.region) then return false, C.INVALID_RV_DATA end
    record.region = {
        minX = integer(data.region.minX), minY = integer(data.region.minY),
        maxX = integer(data.region.maxX), maxY = integer(data.region.maxY),
        minZ = integer(data.region.minZ), maxZ = integer(data.region.maxZ),
    }
    record.rvPosition = copyPosition(data.rvPosition)
    record.enterPosition = copyPosition(data.entryPosition)
    record.locoPosition = train and trainPose(train) or copyPose(data.locoPosition)
    record.boundarySchemaVersion = C.BOUNDARY_SCHEMA_VERSION
    record.bitmapVersion = C.BITMAP_VERSION
    record.boundary = prepared.boundary
    record.managed = prepared.boundary.managed
    if not record.rvPosition or not record.enterPosition
        or not record.locoPosition
        or number(record.locoPosition.dirX) == nil
        or number(record.locoPosition.dirY) == nil then
        return false, C.INVALID_RV_DATA
    end
    if type(record.players) ~= "table" then record.players = {} end
    if not Boundary.registerGeneration(locoId, record.generation,
        prepared.boundary, record) then
        return false, "RV boundary manifest registration failed"
    end
    record.updatedAt = math.floor(os.time())
    markPlayerInside(map, record, key, player,
        data.entryPosition, data.sourceRole, data.sourceSeat)
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.initializeUtilityRecord) ~= "function" then
        return false, C.INVALID_RV_DATA
    end
    local utilityOk, utilityAccepted, utilityReason = pcall(
        server.initializeUtilityRecord,
        { rvId = record.rvId, generation = record.generation,
            bitmapVersion = record.bitmapVersion },
        { player = player, identity = {
            rvId = record.rvId, generation = record.generation,
            bitmapVersion = record.bitmapVersion,
        }, record = record })
    if not utilityOk or utilityAccepted ~= true then
        return false, utilityOk and (utilityReason or C.INVALID_RV_DATA)
            or tostring(utilityAccepted)
    end
    if type(server.settleRVUtilityLoad) == "function" then
        local settleOk, settled, settleReason = pcall(server.settleRVUtilityLoad,
            { rvId = tostring(record.rvId), generation = record.generation,
                bitmapVersion = record.bitmapVersion }, player)
        if not settleOk or settled ~= true then
            print("[RailroaderRVTest] new RV entry load refresh failed reason="
                .. tostring(settleOk and settleReason or settled))
        end
    end
    -- RV_Server owns the transition close after FinalRelocateAck and the
    -- current-manifest readiness proof. Do not release the lease from this
    -- mapping commit hook before that final client proof.
    refreshRoofForPlayer(player, record, true, "generation-entry")
    markMappingChanged()
    RemovalTrace.lifecycle("mapping", "server-state", "updated", ctx.serverTick)
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
    traceTransition("EntryExit.exitPlayer.begin", player, nil, "request=ExitRV")
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
    traceTransition("EntryExit.exitPlayer.coordinateLookup", player, record,
        "lookupState=" .. tostring(lookupState) .. " key=" .. tostring(key)
            .. " trainPresent=" .. tostring(train ~= nil))
    if lookupState == "outside-rv" then
        return false, "player is outside the RV area"
    end
    if not record then
        return false, C.INVALID_RV_DATA
    end
    local roofBlocked, roofReason = roofRefreshTransactionBlocks(record.rvId)
    if roofBlocked then
        traceTransition("EntryExit.exitPlayer.roofRefreshBlocked", player,
            record, roofReason)
        return false, roofReason
    end
    local geometryOk, geometryReason = currentGeometryGate(record)
    if not geometryOk then
        traceTransition("EntryExit.exitPlayer.geometryRejected", player,
            record, geometryReason)
        return false, geometryReason
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
                record.generation, transitionToken, "exit", record.bitmapVersion)
            if armed ~= true then
                return false, "RV boundary exit transition could not be armed"
            end
        end
        settleUtilityTransition(record, player, "exit-before-teleport")
        local moved = movePlayer(player, target, "exit", {
            locoId = record.locoId, role = "beside", seat = nil,
            rvId = record.locoId, generation = record.generation,
            bitmapVersion = record.bitmapVersion,
        })
        traceTransition("EntryExit.exitPlayer.inactiveTeleportResult", player,
            record, "moved=" .. tostring(moved) .. " target="
                .. transitionPositionText(target))
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
        RemovalTrace.lifecycle("mapping", "server-state", "updated", ctx.serverTick)
        RemovalTrace.lifecycle("exit", "RV", "complete", ctx.serverTick)
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
            record.generation, transitionToken, "exit", record.bitmapVersion)
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
        bitmapVersion = record.bitmapVersion,
    })
    traceTransition("EntryExit.exitPlayer.teleportResult", player, record,
        "moved=" .. tostring(moved) .. " role=" .. tostring(role)
            .. " seat=" .. tostring(seat) .. " target="
            .. transitionPositionText(target))
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
    RemovalTrace.lifecycle("mapping", "server-state", "updated", ctx.serverTick)
    RemovalTrace.lifecycle("exit", "RV", "complete", ctx.serverTick)
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
