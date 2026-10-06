-- RV_RailroaderServer: EntryExit responsibilities.
return function(ctx)
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local ServerTeleport = require("RailroaderRV/Common/RV_ServerTeleport")
local WaterConstants = require("RailroaderRV/Water/RV_UtilityWaterConstants")
local processIsServer = ctx.processIsServer
local Boundary = ctx.Boundary
local Adapter = ctx.Adapter
local C = ctx.C
local function recordForLoco(...) return ctx.recordForLoco(...) end
local function transactionBlocks(...) return ctx.wallReloadTransactionBlocks(...) end
local sourceWithinRange
local number = ctx.number
local integer = ctx.integer
local call = ctx.call
local callGlobal = ctx.callGlobal
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
local refreshRoofForPlayer = ctx.refreshRoofForPlayer
local armRoomOwnershipMonitor = ctx.armRoomOwnershipMonitor
local recordAtPlayerCoordinate = ctx.recordAtPlayerCoordinate
local nearestMappedTrain

function Adapter.resolveCurrentUtilityRV(player, diagnosticOperation,
        diagnosticPhase)
    local relation
    local locomotiveSide = false
    local locomotiveRole, locomotiveSeat
    local function reject(reason)
        if diagnosticOperation == WaterConstants.OP_DRAW_WATER_FROM_SOURCE then
            local role, seat
            if relation == nil then
                role, seat = nil, nil
            else
                role, seat = relation.role, relation.seat
            end
            print("[RailroaderRV] water draw rejected operation="
                .. diagnosticOperation .. " entry=utility-resolver phase="
                .. tostring(diagnosticPhase) .. " reason=" .. tostring(reason)
                .. " side=" .. tostring(locomotiveSide)
                .. " mappingRole=" .. tostring(role)
                .. " mappingSeat=" .. tostring(seat))
        end
        return false, reason
    end
    if not player or playerDead(player) then
        return reject("permission-denied")
    end
    local map = mapData()
    local name = playerName(player)
    local onlineId = playerId(player)
    relation = name and map.players and map.players[name] or nil
    local record, _, train, status = recordAtPlayerCoordinate(map, player)
    if not record and status == "outside-rv" and onlineId ~= nil and name
        and type(relation) == "table" and relation.inside == false then
        local boundRecord = recordForLoco(map, relation.locoId)
        local rider = boundRecord and boundRecord.players[name] or nil
        if boundRecord and type(rider) == "table" and rider.inside == false
            and tostring(rider.locoId) == tostring(boundRecord.locoId)
            and tostring(relation.locoId) == tostring(boundRecord.locoId) then
            local liveTrain = findTrain(boundRecord.locoId)
            if liveTrain and trainPosition(liveTrain)
                and sourceWithinRange(player, liveTrain) then
                record, train, status = boundRecord, liveTrain, "locomotive-bound"
                locomotiveSide = true
                locomotiveRole, locomotiveSeat = playerRole(liveTrain,
                    onlineId)
            end
        end
    end
    if not record and status == "outside-rv" and relation == nil then
        local nearbyRecord, nearbyTrain = nearestMappedTrain(map, player)
        if nearbyRecord then
            record, train, status = nearbyRecord, nearbyTrain,
                "locomotive-candidate"
            locomotiveSide = true
            locomotiveRole, locomotiveSeat = playerRole(nearbyTrain,
                onlineId)
        end
    end
    if not record then return reject(status or "outside-rv") end
    local rider = name and record.players and record.players[name] or nil
    local unboundLocomotiveVisitor = locomotiveSide
        and relation == nil and rider == nil
    if onlineId == nil or not name or (not unboundLocomotiveVisitor
        and (not relation or not rider
            or tostring(relation.locoId) ~= tostring(record.locoId)
            or tostring(rider.locoId) ~= tostring(record.locoId)
            or (locomotiveSide and (relation.inside ~= false
                or rider.inside ~= false))
            or (not locomotiveSide and (relation.inside ~= true
                or rider.inside ~= true)))) then
        return reject("permission-denied")
    end
    if not locomotiveSide then
        -- Reuse the existing authoritative boundary/player contract as the
        -- utility permission check.  It proves the persisted inside relation and
        -- current authoritative geometry; no client role field is
        -- accepted.  A utility context is authorized only for this mapping.
        local boundaryIdentity = {
            username = name, onlineId = onlineId,
            key = tostring(onlineId) .. ":" .. name,
        }
        local _, boundaryRecord, boundaryRelation =
            Adapter.validateCurrentBoundaryPlayer(player, boundaryIdentity)
        if boundaryRecord ~= record
            or type(boundaryRelation) ~= "table"
            or boundaryRelation.inside ~= true then
            return reject(C.INVALID_RV_DATA)
        end
    end
    return true, {
        identity = { rvId = tostring(record.locoId), generation = integer(record.generation) },
        record = record, relation = relation, train = train, status = status,
        phase = "READY", locomotiveRole = locomotiveRole,
        locomotiveSeat = locomotiveSeat,
        authorized = true, locomotiveSide = locomotiveSide,
    }
end

function Adapter.currentUtilityRecord(identity)
    local map = mapData()
    local record = recordForLoco(map, identity.rvId)
    if not record then
        return false, C.INVALID_RV_DATA
    end
    if record.generation == nil then
        error("current RV mapping has no generation")
    end
    if record.generation ~= integer(identity.generation) then
        return false, C.INVALID_RV_DATA
    end
    return true, record
end

function Adapter.resolveSafehouseClaimTarget(player)
    if not player or playerDead(player) then
        return false, "player-unavailable"
    end
    local onlineId, username = playerId(player), playerName(player)
    if onlineId == nil or not username then
        return false, "player-unavailable"
    end

    local server = RailroaderRV.Server
    if server.isGenerationTransactionActive() then
        return false, "busy"
    end
    if server.isWallReloadTransactionActive(nil) then
        return false, "busy"
    end

    local accepted, context = Adapter.resolveCurrentUtilityRV(player)
    if accepted ~= true then return false, context end
    if context.locomotiveSide == true then return false, "outside-rv" end
    return true, context.record
end

local function settleUtilityTransition(record, player)
    local server = RailroaderRV.Server
    local accepted, reason = server.settleRVUtilityLoad({
        rvId = tostring(record.locoId), generation = record.generation,
    }, player, record)
    if accepted ~= true then
        print("[RailroaderRV] utility transition settlement failed reason=" .. tostring(reason))
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

local function markPlayerOutside(map, record, player, position, seat, role)
    local name = playerName(player)
    if not name then return end
    local relation = map.players[name]
    relation.locoId = tostring(record.locoId)
    relation.onlineId = playerId(player)
    relation.inside = false
    relation.role = role
    relation.seat = seat
    relation.exitPosition = copyPosition(position)
    map.players[name] = relation
    local rider = record.players[name]
    rider.onlineId = playerId(player)
    rider.inside = false
    rider.role = role
    rider.seat = seat
    rider.exitPosition = copyPosition(position)
end

local function markPlayerInside(map, record, player, sourcePosition,
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
    record.players[name] = {
        locoId = tostring(record.locoId),
        onlineId = relation.onlineId, inside = true,
        role = sourceRole, seat = sourceSeat,
        enterPosition = enterPosition,
    }
end

local function otherGeneratedRecord(map, locoId)
    local wanted = tostring(locoId)
    for key, record in pairs(map.locomotives) do
        if tostring(key) ~= wanted then
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

nearestMappedTrain = function(map, player)
    local rr = rawget(_G, "RR")
    local officialReach = rr and rr.Ride and rr.Ride.MOUNT_REACH
    local reach = number(officialReach) or number(C.RV_MOUNT_REACH)
    local nearestDistance, nearestKey, nearestRecord, nearestTrain
    for key, record in pairs(map.locomotives) do
        local train = findTrain(record.locoId)
        if train and trainPosition(train) then
            local distance = hullDistance(player, train)
            local recordKey = tostring(key)
            if distance ~= nil and distance <= reach
                and (nearestDistance == nil or distance < nearestDistance
                    or (distance == nearestDistance
                        and recordKey < nearestKey)) then
                nearestDistance, nearestKey = distance, recordKey
                nearestRecord, nearestTrain = record, train
            end
        end
    end
    return nearestRecord, nearestTrain
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

local function restoreEntrySeat(train, player, onlineId, role, seat)
    if role == "driver" then
        putDriver(train, player, onlineId)
    elseif role == "passenger" and seat ~= nil then
        putPassenger(train, player, onlineId, seat)
    end
end

local function enterExisting(player, train, record, sourceRole,
    sourceSeat, sourcePosition, map)
    local blocked, blockReason = transactionBlocks(record.locoId)
    if blocked then
        return false, blockReason
    end
    local onlineId = playerId(player)
    local target = copyPosition(record.rvPosition)
    if not target then return false, C.INVALID_RV_DATA end
    -- Re-arm the persistent client stale-room monitor before changing seats or
    -- moving the player.
    local monitorOk, monitorReason = armRoomOwnershipMonitor(player, record)
    if not monitorOk then return false, monitorReason end
    local transitionToken = newTransitionToken("entry", record)
    local armed = Boundary.beginTransition(player, record.locoId,
        record.generation, transitionToken, "entry")
    if armed ~= true then
        return false, "RV boundary entry transition could not be armed"
    end
    local removedRole, removedSeat = removeSeatForEntry(train, player, onlineId)
    if removedRole == "external" then removedSeat = nil end
    local oldRelation = map.players[playerName(player)]
    local oldRiders = {}
    for riderName, rider in pairs(record.players) do
        oldRiders[riderName] = rider
    end
    markPlayerInside(map, record, player, sourcePosition, sourceRole,
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
        Boundary.clearPlayer(player)
        return false, "RV entry teleport failed"
    end
    if Boundary.completeTransition(player, transitionToken) ~= true then
        error("RV boundary entry transition could not be completed")
    end
    settleUtilityTransition(record, player)
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
    local blocked, blockReason = transactionBlocks(locoId)
    if blocked then
        return false, blockReason
    end
    local map = mapData()
    local existingRecord, _, _, lookupState =
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

    local record = recordForLoco(map, trainId(train))
    if record then
        return enterExisting(player, train, record, role, seat,
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
    local requestOk, queued, reason = pcall(
        RailroaderRV.Server.requestRailroaderGeneration, player, data)
    if not requestOk then
        restoreEntrySeat(train, player, onlineId, removedRole, removedSeat)
        error(queued, 0)
    end
    if not queued then
        restoreEntrySeat(train, player, onlineId, removedRole, removedSeat)
        return false, reason
    end
    return true
end

local function restoreAfterGenerationFailure(player, data)
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
    movePlayer(player, data.sourcePosition, "generation-failed", {
        locoId = data.locoId, role = data.sourceRole, seat = data.sourceSeat,
        rvId = data.rvId, generation = data.generation,
    })
    Boundary.clearPlayer(player)
end

local function commitGeneration(player, data, prepared)
    local map = mapData()
    local locoId = tostring(data.locoId)
    local generation = prepared.generation
    local slotIndex = prepared.slotIndex
    local anchor = RegionSlots.indexToAnchor(slotIndex)
    assert(slotIndex == data.slotIndex
        and anchor.x == prepared.anchor.x
        and anchor.y == prepared.anchor.y
        and anchor.z == prepared.anchor.z,
        C.INVALID_RV_DATA)
    Boundary.boundaryFor({
        locoId = locoId, generation = generation, slotIndex = slotIndex,
        templateId = prepared.layout.templateId,
    })
    local record = recordForLoco(map, locoId)
    assert(record == nil)
    local candidateRecord = { players = {} }
    local candidateMap = {
        schemaVersion = map.schemaVersion,
        locomotives = {},
        players = {},
    }
    for entryKey, entry in pairs(map.locomotives) do
        candidateMap.locomotives[entryKey] = entry
    end
    for name, relation in pairs(map.players) do
        candidateMap.players[name] = relation
    end
    candidateMap.locomotives[locoId] = candidateRecord
    local train = findTrain(locoId)
    -- Durable record state only: identity, slot allocation and the two
    -- cross-restart poses.  Anchor, region, bounds and shell edges are
    -- derived from slotIndex and the compiled template when they are read.
    candidateRecord.generated = true
    candidateRecord.locoId = locoId
    candidateRecord.generation = generation
    candidateRecord.slotIndex = slotIndex
    candidateRecord.templateId = prepared.layout.templateId
    candidateRecord.rvPosition = copyPosition(prepared.finalDestination)
    candidateRecord.locoPosition = train and trainPose(train)
        or copyPose(data.locoPosition)
    markPlayerInside(candidateMap, candidateRecord, player,
        data.entryPosition, data.sourceRole, data.sourceSeat)
    local actionLedger = Boundary.builderActionLedger
    if actionLedger.invalidateForGeneration(candidateRecord.locoId,
        candidateRecord.generation) ~= true then
        return false, C.INVALID_RV_DATA
    end
    local server = RailroaderRV.Server
    -- Initialize the utility record against the server-constructed candidate
    -- before making the RV available through Mapping. The candidate record and
    -- its built generator are sufficient; utility initialization does not need
    -- a published mapping. Omitting player suppresses the pre-finalization
    -- client snapshot; the server-cell lookup resolves the just-built generator.
    local utilityAccepted, utilityReason = server.initializeUtilityRecord(
        { rvId = candidateRecord.locoId,
            generation = candidateRecord.generation },
        { identity = {
            rvId = candidateRecord.locoId,
            generation = candidateRecord.generation,
        }, record = candidateRecord })
    if utilityAccepted ~= true then
        return false, utilityReason
    end
    -- Mapping is the final generation commit. Nothing that can reject creation
    -- runs after this single table swap.
    markMappingChanged()
    map.locomotives, map.players = candidateMap.locomotives,
        candidateMap.players
    local settled, settleReason = server.settleRVUtilityLoad({
        rvId = tostring(candidateRecord.locoId),
        generation = candidateRecord.generation,
    }, player, candidateRecord)
    if settled ~= true then
        print("[RailroaderRV] new RV entry load refresh failed reason="
            .. tostring(settleReason))
    end
    -- RV_Server owns the transition close after FinalRelocateAck and the
    -- current-manifest readiness proof. Do not release the lease from this
    -- mapping commit hook before that final client proof.
    refreshRoofForPlayer(player, candidateRecord, true, "generation-entry")
    return true
end

local function validateGeneration(player, data)
    if not player or playerDead(player) then return false, "player is dead" end
    local train = findTrain(data.locoId)
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
    local map = mapData()
    local record, key, train, lookupState =
        recordAtPlayerCoordinate(map, player)
    if lookupState == "outside-rv" then
        return false, "player is outside the RV area"
    end
    if not record then
        return false, C.INVALID_RV_DATA
    end
    local blocked, blockReason = transactionBlocks(record.locoId)
    if blocked then
        return false, blockReason
    end
    if not train then
        local target = persistedBesidePosition(record)
        if not target then return false, C.INVALID_RV_DATA end
        -- The mapping is valid but the locomotive is inactive/unloaded.  Do
        -- not invent a driver/passenger seat; use only a persisted beside
        -- target and retain the explicit state for diagnostics and tests.
        if lookupState ~= "inactive-mapped" then return false, C.INVALID_RV_DATA end
        local transitionToken = newTransitionToken("exit", record)
        local armed = Boundary.beginTransition(player, record.locoId,
            record.generation, transitionToken, "exit")
        if armed ~= true then
            return false, "RV boundary exit transition could not be armed"
        end
        settleUtilityTransition(record, player)
        local moved = movePlayer(player, target, "exit", {
            locoId = record.locoId, role = "beside", seat = nil,
            rvId = record.locoId, generation = record.generation,
        })
        if not moved then
            if Boundary.completeTransition(player, transitionToken) ~= true then
                error("RV boundary exit transition could not be completed")
            end
            return false, "inactive locomotive exit teleport failed"
        end
        markPlayerOutside(map, record, player, target, nil, "beside")
        Boundary.clearPlayer(player)
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
    local armed = Boundary.beginTransition(player, record.locoId,
        record.generation, transitionToken, "exit")
    if armed ~= true then
        return false, "RV boundary exit transition could not be armed"
    end

    local assigned = false
    if role == "passenger" then assigned = putPassenger(train, player, onlineId, seat)
    elseif role == "driver" then assigned = putDriver(train, player, onlineId) end
    if role ~= "beside" and not assigned then
        if Boundary.completeTransition(player, transitionToken) ~= true then
            error("RV boundary exit transition could not be completed")
        end
        return false, "locomotive seat became occupied"
    end
    settleUtilityTransition(record, player)
    local moved = movePlayer(player, target, "exit", {
        locoId = trainId(train), role = role, seat = seat,
        rvId = record.locoId, generation = record.generation,
    })
    if not moved then
        if role ~= "beside" then forgetTrainSeat(train, player, onlineId) end
        if Boundary.completeTransition(player, transitionToken) ~= true then
            error("RV boundary exit transition could not be completed")
        end
        return false, "RV exit teleport failed"
    end
    record.locoPosition = trainPose(train) or record.locoPosition
    markPlayerOutside(map, record, player, target, seat, role)
    Boundary.clearPlayer(player)
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
