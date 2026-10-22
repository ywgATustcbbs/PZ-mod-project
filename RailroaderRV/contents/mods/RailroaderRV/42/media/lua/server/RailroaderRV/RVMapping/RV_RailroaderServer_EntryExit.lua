-- RV_RailroaderServer: EntryExit responsibilities.
return function(ctx)
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local ServerTeleport = require("RailroaderRV/Common/RV_ServerTeleport")
local WaterConstants = require("RailroaderRV/Water/RV_UtilityWaterConstants")
local ClientDispatch = require("RailroaderRV/Core/RV_ServerClientDispatch")
local RRApi = RR.API
local processIsServer = ctx.processIsServer
local Boundary = ctx.Boundary
local Adapter = ctx.Adapter
local C = ctx.C
local function recordForLoco(...) return ctx.recordForLoco(...) end
local function transactionBlocks(...) return ctx.wallReloadTransactionBlocks(...) end
local sourceWithinRange
local integer = ctx.integer
local playerId = ctx.playerId
local playerName = ctx.playerName
local playerDead = ctx.playerDead
local playerPosition = ctx.playerPosition
local copyPosition = ctx.copyPosition
local newTransitionToken = ctx.newTransitionToken
local trainId = ctx.trainId
local findTrain = ctx.findTrain
local trainPosition = ctx.trainPosition
local trainMoving = ctx.trainMoving
local trainPose = ctx.trainPose
local trainGeometry = ctx.trainGeometry
local singleplayerMode = ctx.singleplayerMode
local seatPosition = ctx.seatPosition
local interactionGeometry = ctx.interactionGeometry
local playerRole = ctx.playerRole
local forgetTrainSeat = ctx.forgetTrainSeat
local assignTrainSeat = ctx.assignTrainSeat
local mapData = ctx.mapData
local markMappingChanged = ctx.markMappingChanged
local rvRegion = ctx.rvRegion
local refreshRoofForPlayer = ctx.refreshRoofForPlayer
local armRoomOwnershipMonitor = ctx.armRoomOwnershipMonitor
local recordAtPlayerCoordinate = ctx.recordAtPlayerCoordinate
local nearestMappedTrain
local pendingExitBoardings = {}
local EXIT_BOARD_TIMEOUT_TICKS = 600
local EXIT_BOARD_POSITION_TOLERANCE = 1.5

local function isFlatcar(map, unitId)
    return map.flatcars[tostring(unitId)] ~= nil
end

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
                locomotiveRole, locomotiveSeat = playerRole(liveTrain, player)
                if locomotiveRole == nil then return reject(locomotiveSeat) end
            end
        end
    end
    if not record and status == "outside-rv" and relation == nil then
        local nearbyRecord, nearbyTrain = nearestMappedTrain(map, player)
        if nearbyRecord then
            record, train, status = nearbyRecord, nearbyTrain,
                "locomotive-candidate"
            locomotiveSide = true
            locomotiveRole, locomotiveSeat = playerRole(nearbyTrain, player)
            if locomotiveRole == nil then return reject(locomotiveSeat) end
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
    ClientDispatch.sendToPlayer(player, C.MOD_ID, C.COMMAND_RV_TELEPORT, {
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
        payload.boardCarId = relation.boardCarId
        payload.boardToken = relation.boardToken
    end
    local sent = ClientDispatch.sendToPlayer(player,
        C.MOD_ID, C.COMMAND_RV_TELEPORT, payload)
    -- Public assignRider/releaseRider calls own cab binding; RVTeleport only
    -- handles the RV teleport and mapping update.
    if not sent and processIsServer() and action ~= "exit-board-cancel" then
        return false
    end
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

sourceWithinRange = function(player, train)
    local distance, reach = interactionGeometry(player, train)
    return distance ~= nil and reach ~= nil and distance <= reach
end

nearestMappedTrain = function(map, player)
    local nearestDistance, nearestKey, nearestRecord, nearestTrain
    for key, record in pairs(map.locomotives) do
        local train = findTrain(record.locoId)
        if train and trainPosition(train) then
            local distance, reach = interactionGeometry(player, train)
            local recordKey = tostring(key)
            if distance ~= nil and reach ~= nil and distance <= reach
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
    if not entryPosition or not trainPose(train) then
        return nil
    end
    return {
        locoId = tostring(trainId(train)), sourceRole = role, sourceSeat = seat,
        playerUsername = playerName(player), playerOnlineId = playerId(player),
        entryPosition = entryPosition,
    }
end

local function removeSeatForEntry(train, player)
    return forgetTrainSeat(train, player)
end

local function restoreEntrySeat(train, player, role, seat)
    if role == "driver" then
        return assignTrainSeat(train, player, "driver", 0)
    elseif role == "passenger" and seat ~= nil then
        return assignTrainSeat(train, player,
            "passenger", seat)
    end
    return true
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
    local removedRole, removedSeat = removeSeatForEntry(train, player)
    if not removedRole then
        Boundary.clearPlayer(player)
        return false, removedSeat
    end
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
        local restored, restoreReason = restoreEntrySeat(train, player,
            removedRole, removedSeat)
        Boundary.clearPlayer(player)
        if not restored and restoreReason ~= "seattaken"
            and restoreReason ~= "aboard" then
            error("RailroaderRV: failed to restore the Railroader seat: "
                .. tostring(restoreReason))
        end
        return false, "RV entry teleport failed"
    end
    if Boundary.completeTransition(player, transitionToken) ~= true then
        error("RV boundary entry transition could not be completed")
    end
    settleUtilityTransition(record, player)
    record.locoPosition = trainPose(train)
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
    if pendingExitBoardings[onlineId] then
        return false, "RV cargo car boarding is already in progress"
    end
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
    if not train then return false, "target is not an active Railroader unit" end
    if isFlatcar(map, trainId(train)) then
        return false, "flatcars cannot be bound as RVs"
    end
    if train.isLocomotive ~= true
        and (not trainPose(train) or not trainGeometry(train)) then
        return false, "cargo car pose is unavailable"
    end
    local role, seat = playerRole(train, player)
    if role == nil then return false, seat end
    local moving = trainMoving(train)
    if moving and role ~= "passenger" then
        return false, role == "driver" and "driver cannot enter while moving"
            or "outside player cannot enter a moving Railroader unit"
    end
    if role == "external" and not sourceWithinRange(player, train) then
        return false, "player is outside Railroader unit interaction range"
    end
    local sourcePosition
    if role == "external" then
        sourcePosition = playerPosition(player)
    else
        sourcePosition = seatPosition(train, seat or 0)
    end
    if not sourcePosition then return false, "entry position is unavailable" end

    local record = recordForLoco(map, trainId(train))
    if record then
        return enterExisting(player, train, record, role, seat,
            sourcePosition, map)
    end
    local data = requestData(train, player, role, seat, sourcePosition)
    if not data then return false, "entry position is unavailable" end
    -- A passenger is removed before the staging relocation.  Otherwise the
    -- official seat pin would immediately drag the player back to the moving
    -- locomotive while the generation stream is loading.
    local removedRole, removedSeat = removeSeatForEntry(train, player)
    if not removedRole then return false, removedSeat end
    data.removedRole, data.removedSeat = removedRole, removedSeat
    data.sourcePosition = copyPosition(sourcePosition)
    local requestOk, queued, reason = pcall(
        RailroaderRV.Server.requestRailroaderGeneration, player, data)
    if not requestOk then
        local restored, restoreReason = restoreEntrySeat(train, player,
            removedRole, removedSeat)
        if not restored and restoreReason ~= "seattaken"
            and restoreReason ~= "aboard" then
            error("RailroaderRV: failed to restore the Railroader seat: "
                .. tostring(restoreReason))
        end
        error(queued, 0)
    end
    if not queued then
        local restored, restoreReason = restoreEntrySeat(train, player,
            removedRole, removedSeat)
        if not restored and restoreReason ~= "seattaken"
            and restoreReason ~= "aboard" then
            return false, restoreReason
        end
        return false, reason
    end
    return true
end

local function restoreAfterGenerationFailure(player, data)
    local train = findTrain(data.locoId)
    if train and playerId(player) ~= nil then
        local restored, reason = restoreEntrySeat(train, player,
            data.removedRole, data.removedSeat)
        if not restored and reason ~= "seattaken" and reason ~= "aboard" then
            error("RailroaderRV: failed to restore the Railroader seat: "
                .. tostring(reason))
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
    if isFlatcar(map, locoId) then
        return false, "flatcars cannot be bound as RVs"
    end
    local generation = prepared.generation
    local slotIndex = prepared.slotIndex
    local train = findTrain(locoId)
    local geometry = train and trainGeometry(train)
    local locoPosition = train and trainPose(train)
    if not geometry or not locoPosition then
        return false, "locomotive pose is unavailable"
    end
    Boundary.boundaryFor({
        locoId = locoId, generation = generation, slotIndex = slotIndex,
        templateId = prepared.layout.templateId,
    })
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
    -- Durable record state only: identity, slot allocation and the two
    -- cross-restart poses.  Anchor, region, bounds and shell edges are
    -- derived from slotIndex and the compiled template when they are read.
    candidateRecord.generated = true
    candidateRecord.locoId = locoId
    candidateRecord.generation = generation
    candidateRecord.slotIndex = slotIndex
    candidateRecord.templateId = prepared.layout.templateId
    candidateRecord.rvPosition = copyPosition(prepared.finalDestination)
    candidateRecord.locoPosition = locoPosition
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
    if not train then return false, "Railroader unit disappeared during generation" end
    if isFlatcar(mapData(), trainId(train)) then
        return false, "flatcars cannot be bound as RVs"
    end
    local geometry = trainGeometry(train)
    if not geometry or not trainPose(train) then
        return false, "Railroader unit pose is unavailable during generation"
    end
    if data.sourceRole ~= "passenger" and trainMoving(train) then
        return false, "Railroader unit started moving before RV generation completed"
    end
    return true
end

local function copyPose(pose)
    local result = copyPosition(pose)
    if not result then return nil end
    result.dirX, result.dirY = pose.dirX, pose.dirY
    return result
end

local function sendExitBoardResult(pending, action)
    local onlineId = pending.onlineId
    local payload = {
        ok = true, action = action, onlineId = onlineId,
        boardToken = pending.token, rvId = pending.locoId,
        locoId = pending.locoId, generation = pending.generation,
    }
    return ClientDispatch.sendToPlayer(pending.player, C.MOD_ID,
        C.COMMAND_RV_TELEPORT, payload)
end

local function completeExitBoarding(pending, boardPoint)
    local map = mapData()
    local latestPose, reason = RRApi.lastKnown(pending.carId, {})
    if not latestPose then
        return false, reason
    end
    local position = copyPosition(boardPoint)
    local pose = copyPose(latestPose)
    pendingExitBoardings[pending.onlineId] = nil
    settleUtilityTransition(pending.record, pending.player)
    pending.record.locoPosition = pose
    markPlayerOutside(map, pending.record, pending.player, position, nil,
        "external")
    Boundary.clearPlayer(pending.player)
    markMappingChanged()
    sendExitBoardResult(pending, "exit-board-complete")
    return true
end

local function boardPointForPending(pending)
    local point, reason = RRApi.carBoardPoint(pending.carId, {})
    if point then return point end
    if reason == "unknown" or reason == "notloaded" then
        return nil, reason, true
    end
    return nil, reason, false
end

local function serverPlayerAtBoardPoint(player, point)
    local position = playerPosition(player)
    if not position then return nil end
    local dx, dy = position.x - point.x, position.y - point.y
    return dx * dx + dy * dy
            <= EXIT_BOARD_POSITION_TOLERANCE * EXIT_BOARD_POSITION_TOLERANCE
        and math.abs(position.z - point.z) <= 0.75
end

local function tryCompleteExitBoarding(pending)
    if pending.clientBoarded ~= true then return nil end
    local point, reason, retry = boardPointForPending(pending)
    if not point then
        if retry then return nil end
        return false, reason or "Railroader car floor is unavailable"
    end
    local atBoardPoint = serverPlayerAtBoardPoint(pending.player, point)
    if atBoardPoint == nil or atBoardPoint == false then return nil end
    local completed, completionReason = completeExitBoarding(pending, point)
    if not completed then
        return false, completionReason
            or "Railroader unit position is unavailable"
    end
    return true
end

local function finishPendingExitBoarding(pending, reason, disconnected)
    pendingExitBoardings[pending.onlineId] = nil
    local moved
    if disconnected then
        moved = ServerTeleport.teleportToPosition(pending.player,
            pending.origin)
    else
        moved = movePlayer(pending.player, pending.origin,
            "exit-board-cancel", {
                locoId = pending.locoId, rvId = pending.locoId,
                generation = pending.generation, boardToken = pending.token,
            })
    end
    if Boundary.completeTransition(pending.player, pending.token) ~= true then
        error("RV boundary exit transition could not be completed")
    end
    if moved ~= true then
        error("RailroaderRV: failed to return player after car boarding "
            .. tostring(reason))
    end
    return true
end

local function playerIsOnline(pending)
    local players, ok = Adapter.onlinePlayersSnapshot()
    if ok ~= true then return nil end
    for index = 1, #players do
        local current = players[index]
        if playerId(current) == pending.onlineId
            and playerName(current) == pending.playerName then
            return true
        end
    end
    return false
end

local function acknowledgeExitBoarding(player, args)
    local onlineId = playerId(player)
    local token = args and args.boardToken
    local pending = onlineId ~= nil and pendingExitBoardings[onlineId] or nil
    if not pending or pending.player ~= player or pending.token ~= token
        or playerDead(player) or type(args.boarded) ~= "boolean" then
        return false, "stale or invalid RV boarding acknowledgement"
    end
    local blocked, reason = transactionBlocks(pending.locoId)
    if blocked then
        finishPendingExitBoarding(pending, reason, false)
        return true
    end
    if args.boarded ~= true then
        finishPendingExitBoarding(pending,
            "Railroader car boarding failed", false)
        return true
    end
    pending.clientBoarded = true
    local completed, completionReason = tryCompleteExitBoarding(pending)
    if completed == false then
        finishPendingExitBoarding(pending, completionReason, false)
    end
    return true
end

local function processPendingExitBoardings(tick)
    local now = integer(tick)
    for _, pending in pairs(pendingExitBoardings) do
        if playerIsOnline(pending) == false then
            finishPendingExitBoarding(pending,
                "player disconnected while boarding the Railroader car", true)
        elseif now >= pending.deadline then
            finishPendingExitBoarding(pending,
                "Railroader car boarding timed out", false)
        else
            local extended = Boundary.extendTransition(pending.player,
                pending.token, now + C.BOUNDARY_TRANSITION_TIMEOUT_TICKS)
            if extended ~= true then
                finishPendingExitBoarding(pending,
                    "RV boundary exit transition expired", false)
            else
                local blocked, reason = transactionBlocks(pending.locoId)
                if blocked then
                    finishPendingExitBoarding(pending, reason, false)
                else
                    local completed, completionReason =
                        tryCompleteExitBoarding(pending)
                    if completed == false then
                        finishPendingExitBoarding(pending,
                            completionReason, false)
                    end
                end
            end
        end
    end
end

local function exitCargoPlayer(player, record)
    local onlineId, username = playerId(player), playerName(player)
    if onlineId == nil or not username then
        return false, "player identity is unavailable"
    end
    if pendingExitBoardings[onlineId] then
        return false, "RV cargo car boarding is already in progress"
    end
    local blocked, blockReason = transactionBlocks(record.locoId)
    if blocked then
        return false, blockReason
    end
    local carId = tonumber(record.locoId)
    local lastKnown, lastKnownReason = RRApi.lastKnown(carId, {})
    if not lastKnown then
        return false, lastKnownReason
            or "Railroader unit position is unavailable"
    end
    local target = copyPosition(lastKnown)
    if not target then
        return false, "Railroader unit exit position is unavailable"
    end
    local transitionToken = newTransitionToken("exit", record)
    local armed = Boundary.beginTransition(player, record.locoId,
        record.generation, transitionToken, "exit")
    if armed ~= true then
        return false, "RV boundary exit transition could not be armed"
    end
    local origin = playerPosition(player)
    if not origin then
        if Boundary.completeTransition(player, transitionToken) ~= true then
            error("RV boundary exit transition could not be completed")
        end
        return false, "RV interior position is unavailable"
    end
    local pending = {
        player = player, onlineId = onlineId, playerName = username,
        record = record, locoId = tostring(record.locoId), carId = carId,
        generation = record.generation, token = transitionToken,
        origin = origin, deadline = Adapter._ticks + EXIT_BOARD_TIMEOUT_TICKS,
    }
    pendingExitBoardings[onlineId] = pending
    local moved = movePlayer(player, target, "exit-board", {
        locoId = tostring(record.locoId), role = "external",
        rvId = record.locoId, generation = record.generation,
        boardCarId = carId, boardToken = transitionToken,
    })
    if not moved then
        finishPendingExitBoarding(pending, "RV exit teleport failed", false)
        return false, "RV exit teleport failed"
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
    if record.templateId == RoomTemplate.CAR_BOX_TEMPLATE_ID then
        return exitCargoPlayer(player, record)
    end
    local blocked, blockReason = transactionBlocks(record.locoId)
    if blocked then
        return false, blockReason
    end
    if not train then return false, "locomotive is not available" end
    local onlineId = playerId(player)
    if onlineId == nil then return false, "player identity is unavailable" end
    local geometry = trainGeometry(train)
    local locoPosition = trainPose(train)
    if not geometry or not locoPosition then
        return false, "Railroader unit exit position is unavailable"
    end
    local singleplayer = singleplayerMode()
    local transitionToken = newTransitionToken("exit", record)
    local armed = Boundary.beginTransition(player, record.locoId,
        record.generation, transitionToken, "exit")
    if armed ~= true then
        return false, "RV boundary exit transition could not be armed"
    end

    local assignment, assignReason
    local role, seat, target
    if singleplayer then
        assignment, assignReason = assignTrainSeat(train, player, "driver", 0)
    else
        assignment, assignReason = assignTrainSeat(train, player, "passenger")
    end
    if assignment then
        role, seat = assignment.role, assignment.seatIndex
        target = copyPosition(assignment.position)
    elseif not singleplayer and (assignReason == "seatsfull"
        or assignReason == "noseat") then
        assignment, assignReason = assignTrainSeat(train, player, "driver", 0)
        if assignment then
            role, seat = assignment.role, assignment.seatIndex
            target = copyPosition(assignment.position)
        else
            if Boundary.completeTransition(player, transitionToken) ~= true then
                error("RV boundary exit transition could not be completed")
            end
            return false, assignReason
        end
    else
        if Boundary.completeTransition(player, transitionToken) ~= true then
            error("RV boundary exit transition could not be completed")
        end
        return false, assignReason
    end
    if not target then
        if assignment then
            local released, releaseReason = forgetTrainSeat(train, player)
            if not released then
                error("RailroaderRV: failed to release a seat without an exit position: "
                    .. tostring(releaseReason))
            end
        end
        if Boundary.completeTransition(player, transitionToken) ~= true then
            error("RV boundary exit transition could not be completed")
        end
        return false, "Railroader unit exit position is unavailable"
    end
    settleUtilityTransition(record, player)
    local moved = movePlayer(player, target, "exit", {
        locoId = trainId(train), role = role, seat = seat,
        rvId = record.locoId, generation = record.generation,
    })
    if not moved then
        local released, releaseReason = forgetTrainSeat(train, player)
        if not released then
            error("RailroaderRV: failed to release a seat after exit teleport failure: "
                .. tostring(releaseReason))
        end
        if Boundary.completeTransition(player, transitionToken) ~= true then
            error("RV boundary exit transition could not be completed")
        end
        return false, "RV exit teleport failed"
    end
    record.locoPosition = locoPosition
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
ctx.acknowledgeExitBoarding = acknowledgeExitBoarding
Adapter.processPendingExitBoardings = processPendingExitBoardings
end
