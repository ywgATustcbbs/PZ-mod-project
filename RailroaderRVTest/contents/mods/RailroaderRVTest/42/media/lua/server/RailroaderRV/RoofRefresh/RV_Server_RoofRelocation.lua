-- RV_Server: RoofRelocation responsibilities.
-- Relocation packets retain the existing roofRepairTransition/roofRepairPhase
-- wire keys; those markers now exclusively describe the RoofRefresh flow.
return function(ctx)
local Core = ctx.Core
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND_RELOCATE = ctx.COMMAND_RELOCATE
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local TemplateGeometry = require("RailroaderRV/RoomTemplate/RV_TemplateGeometry")
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local function safeErrorText(...) return ctx.safeErrorText(...) end
local RELOCATION_POST_ACK_TICKS = ctx.RELOCATION_POST_ACK_TICKS
local RELOCATION_TIMEOUT_TICKS = ctx.RELOCATION_TIMEOUT_TICKS
local ROOF_REFRESH_RETURN_RETRY_TICKS = ctx.ROOF_REFRESH_RETURN_RETRY_TICKS
local ROOF_RELOCATION_RETRY_TICKS = ctx.ROOF_RELOCATION_RETRY_TICKS
local ROOF_REFRESH_TEMP_Z = ctx.ROOF_REFRESH_TEMP_Z
local RELOCATION_MIN_TICKS = ctx.RELOCATION_MIN_TICKS
local RELOCATION_POST_ACK_TICKS = ctx.RELOCATION_POST_ACK_TICKS
local notifyFailure = ctx.notifyFailure
local tryAuthoritativePlayerPosition = ctx.tryAuthoritativePlayerPosition
local authoritativePlayerPosition = ctx.authoritativePlayerPosition
local validateAuthoritativePlayer = ctx.validateAuthoritativePlayer
local playerIdentity = ctx.playerIdentity
local resolvePendingPlayer = ctx.resolvePendingPlayer
local roofRefreshPosition = ctx.roofRefreshPosition
local roofRefreshWorldCoordinateValid = ctx.roofRefreshWorldCoordinateValid
local currentRoofRefreshContext = ctx.currentRoofRefreshContext
local roofRefreshDestination = ctx.roofRefreshDestination
local applyRoofRefreshTeleport = ctx.applyRoofRefreshTeleport
local copyRoofRefreshPosition = ctx.copyRoofRefreshPosition
local rollbackRoofRefreshRelocation = ctx.rollbackRoofRefreshRelocation
local roofRefreshTargetReady = ctx.roofRefreshTargetReady

local function earlierTick(left, right)
    return left <= right and left or right
end

local function roofRefreshGroupMatches(group, rvId, generation)
    return type(group) == "table"
        and tostring(group.rvId) == tostring(rvId)
        and ServerUtil.integer(group.generation) == ServerUtil.integer(generation)
end

local function roofRefreshGroupMember(group, player, token)
    if type(group) ~= "table" or type(group.members) ~= "table" then
        return nil
    end
    local identityKey = nil
    if player ~= nil then
        local identityOk, identity = playerIdentity(player)
        if identityOk then identityKey = identity.key end
    end
    for i = 1, #group.members do
        local member = group.members[i]
        if (member.player == player
                or identityKey ~= nil and member.identityKey == identityKey)
            and (token == nil or member.token == token) then
            return member
        end
    end
    return nil
end

local function resolveRoofRefreshGroupPlayer(group, member)
    local resolved, current, previous = resolvePendingPlayer(member)
    if not resolved then return false, current end
    previous = previous or member.player
    member.player = current
    if previous ~= nil and previous ~= current then
        if type(group) == "table" and type(group.allowedPlayers) == "table" then
            group.allowedPlayers[previous] = nil
            group.allowedPlayers[current] = true
        end
        member.playerReboundAtTick = ctx.serverTick
        member.relocationNeedsResend = true
    end
    return true, current
end

local function roofRefreshGroupAll(group, field, value)
    if type(group) ~= "table" or type(group.members) ~= "table"
        or #group.members == 0 then
        return false
    end
    for i = 1, #group.members do
        if group.members[i][field] ~= value then return false end
    end
    return true
end

local function roofRefreshExactPosition(player)
    return authoritativePlayerPosition(player)
end

-- The group fail-safe never trusts a position supplied by the adapter.  Each
-- member's exact original position is captured from the authoritative server
-- object before the first remote command; returnPosition is only the ServerUtil.integer
-- square required by the token-only client bridge.
local function failRoofRefreshRelocationGroup(reason)
    local group = ctx.roofRefreshRelocationGroup
    if not group then return end
    ctx.roofRefreshRelocationGroup = nil
    ctx.roofRefreshGroupFailure = {
        roomKey = group.roomKey,
        rvId = group.rvId,
        generation = group.generation,
        token = group.token,
        reason = safeErrorText(reason),
    }
    local allReturned = true
    for i = 1, #group.members do
        local member = group.members[i]
        member.finalReturnReason = reason
        local rollbackCallOk, returned, returnReason = pcall(
            rollbackRoofRefreshRelocation, member)
        if not rollbackCallOk then
            returnReason = safeErrorText(returned)
            returned = false
        end
        member.finalReturned = returned == true
        member.finalReturnReason = returnReason or reason
        if not member.finalReturned then allReturned = false end
        notifyFailure(member.player, reason)
    end
    if not allReturned then
        ctx.roofRefreshGroupFinalReturn = {
            group = group,
            attempts = 0,
            nextTick = ctx.serverTick + 1,
        }
    else
    end
    print("[RailroaderRVTest] roof refresh group cancelled room="
        .. tostring(group.roomKey or "unknown") .. " members="
        .. tostring(#group.members) .. " reason=" .. safeErrorText(reason)
        .. " finalReturn=" .. (allReturned and "complete" or "pending"))
end

local function processRoofRefreshGroupFinalReturn()
    local retry = ctx.roofRefreshGroupFinalReturn
    if not retry or ctx.serverTick < (retry.nextTick or ctx.serverTick) then
        return
    end
    local group = retry.group
    retry.attempts = (retry.attempts or 0) + 1
    local allReturned = true
    for i = 1, #(group.members or {}) do
        local member = group.members[i]
        if member.finalReturned then
            -- A member marked returned on the previous tick is still polled
            -- authoritatively.  Do not retire the in-memory return owner if it
            -- drifted back to z=-15 or anywhere other than its captured RV coordinate.
            local resolved, playerOrReason = resolveRoofRefreshGroupPlayer(
                group, member)
            local positionOk, position = false, nil
            if resolved then
                positionOk, position = tryAuthoritativePlayerPosition(
                    playerOrReason)
            end
            local original = member.originalPosition or member.returnPosition
            if not positionOk or type(position) ~= "table"
                or type(original) ~= "table"
                or position.z == ROOF_REFRESH_TEMP_Z
                or position.x ~= original.x or position.y ~= original.y
                or position.z ~= original.z then
                member.finalReturned = false
            end
        end
        if not member.finalReturned then
            local rollbackCallOk, returned, returnReason = pcall(
                rollbackRoofRefreshRelocation, member)
            if not rollbackCallOk then
                returnReason = safeErrorText(returned)
                returned = false
            end
            member.finalReturned = returned == true
            member.finalReturnReason = returnReason
        end
        if not member.finalReturned then allReturned = false end
    end
    if allReturned then
        print("[RailroaderRVTest] roof refresh group final return complete room="
            .. tostring(group.roomKey or "unknown") .. " attempts="
            .. tostring(retry.attempts))
        ctx.roofRefreshGroupFinalReturn = nil
        return
    end
    -- A member at the remote z=-15 target is not a recoverable completion.
    -- Keep the current-schema identity/context alive and continue bounded-rate
    -- retries until the authoritative object is actually back.  In particular,
    -- do not clear the Boundary lease or drop the group after a finite count.
    retry.nextTick = ctx.serverTick + ROOF_REFRESH_RETURN_RETRY_TICKS
    print("[RailroaderRVTest] roof refresh group final return pending room="
        .. tostring(group.roomKey or "unknown") .. " attempt="
        .. tostring(retry.attempts + 1) .. " reason=authoritative-return-required")
end

-- Begin or advance the multi-player refresh transaction. The adapter supplies
-- only authoritative player object references; this function re-reads every
-- identity, schema relation and x/y/z before arming any transition. The
-- temporary move is sent to all members before the adapter may run the room
-- refresh, so
-- the complete RV scope can unload and stream back in as one operation.
function RV.Server.beginRoofRefreshRelocationGroup(request)
    local callOk, result, reason = pcall(function()
        local server = type(RV) == "table" and RV.Server or nil
        if type(server) ~= "table"
            or type(server.isGenerationTransactionActive) ~= "function" then
            return false, "generation transaction state is unavailable"
        end
        local generationStateOk, generationActive = pcall(
            server.isGenerationTransactionActive)
        if not generationStateOk or type(generationActive) ~= "boolean" then
            return false, "generation transaction state is unavailable"
        end
        if (type(request) ~= "table" or request.phase == "temporary")
            and (ctx.roofRefreshRelocationGroup ~= nil
                or ctx.roofRefreshGroupFinalReturn ~= nil)
            or generationActive then
            return false, "another RV relocation or generation is in progress"
        end
        if type(request) ~= "table"
            or (request.phase ~= "temporary" and request.phase ~= "return") then
            return false, "roof refresh group relocation request is malformed"
        end
        local rvId = tostring(request.rvId or "")
        local generation = ServerUtil.integer(request.generation)
        local roomKey = tostring(request.roomKey or "")
        if rvId == "" or generation == nil or generation < 1
            or roomKey ~= rvId .. ":" .. tostring(generation) then
            return false, Constants.INVALID_RV_DATA
        end

        if request.phase == "return" then
            local group = ctx.roofRefreshRelocationGroup
            if not roofRefreshGroupMatches(group, rvId, generation)
                or group.roomKey ~= roomKey
                or group.phase ~= "temporary"
                or not roofRefreshGroupAll(group, "arrived", true) then
                return false, "roof refresh group temporary phase is not complete"
            end
            local returnToken = group.token
            for i = 1, #group.members do
                local member = group.members[i]
                local resolved, playerOrReason = resolveRoofRefreshGroupPlayer(
                    group, member)
                if not resolved then
                    -- A live-process disconnect is retryable; the stable
                    -- identity remains owned by this in-memory group.
                    if playerOrReason == "requesting player disconnected or was replaced" then
                        return false, playerOrReason
                    end
                    failRoofRefreshRelocationGroup(playerOrReason)
                    return false, playerOrReason
                end
                local livePlayer = playerOrReason
                local contextOk, contextOrReason = currentRoofRefreshContext(
                    livePlayer, {
                        rvId = rvId, generation = generation,
                        identityKey = member.identity.key,
                    })
                if not contextOk then
                    failRoofRefreshRelocationGroup(contextOrReason)
                    return false, contextOrReason
                end
                local returnPosition = member.returnPosition
                local returnX, returnY, returnZ = math.floor(returnPosition.x),
                    math.floor(returnPosition.y), math.floor(returnPosition.z)
                if not TemplateGeometry.isWalkableInManagedRegion(
                    { x = returnX, y = returnY, z = returnZ },
                    contextOrReason.boundary.managed) then
                    local failure = "roof refresh group return position is not current active RV geometry"
                    failRoofRefreshRelocationGroup(failure)
                    return false, failure
                end
                local worldOk, worldReason = roofRefreshWorldCoordinateValid(
                    returnPosition)
                if not worldOk then
                    failRoofRefreshRelocationGroup(worldReason)
                    return false, worldReason
                end
                member.phase = "return"
                member.target = copyRoofRefreshPosition(returnPosition)
                member.acknowledged = false
                member.arrived = false
                member.arrivalConsumed = false
                member.returnPayload = {
                    token = returnToken,
                    onlineId = member.identity.onlineId,
                    rvId = rvId, generation = generation,
                    x = member.target.x, y = member.target.y, z = member.target.z,
                    roofRepairTransition = true,
                    roofRepairPhase = "return",
                }
            end
            group.phase = "return"
            group.returnStartedAtTick = ctx.serverTick
            for i = 1, #group.members do
                local member = group.members[i]
                local resolved, playerOrReason = resolveRoofRefreshGroupPlayer(
                    group, member)
                if not resolved then
                    if playerOrReason == "requesting player disconnected or was replaced" then
                        return false, playerOrReason
                    end
                    failRoofRefreshRelocationGroup(playerOrReason)
                    return false, playerOrReason
                end
                local sentOk = ServerUtil.callGlobalSucceeded("sendServerCommand", playerOrReason,
                    COMMAND_MODULE, COMMAND_RELOCATE, member.returnPayload)
                if not sentOk or not applyRoofRefreshTeleport(playerOrReason,
                    member.target, false) then
                    local failure = "roof refresh group return relocation failed"
                    failRoofRefreshRelocationGroup(failure)
                    return false, failure
                end
                member.relocationLastSentTick = ctx.serverTick
                member.relocationRetryAtTick = ctx.serverTick
                    + ROOF_RELOCATION_RETRY_TICKS
                member.relocationNeedsResend = false
            end
            print("[RailroaderRVTest] roof refresh group return queued room="
                .. roomKey .. " members=" .. tostring(#group.members)
                .. " target=server-captured-squares")
            return true, returnToken
        end

        if type(request.players) ~= "table" or #request.players < 1 then
            return false, "roof refresh group has no authoritative inside players"
        end
        local members = {}
        local seen = {}
        local sharedContext = nil
        for i = 1, #request.players do
            local descriptor = request.players[i]
            local player = type(descriptor) == "table" and descriptor.player or nil
            local identityOk, identityOrReason = playerIdentity(player)
            if not identityOk then return false, identityOrReason end
            if type(descriptor.identityKey) == "string"
                and descriptor.identityKey ~= identityOrReason.key then
                return false, "roof refresh group player identity changed"
            end
            if seen[identityOrReason.key] then
                return false, "roof refresh group contains duplicate player identity"
            end
            seen[identityOrReason.key] = true
            local contextOk, contextOrReason = currentRoofRefreshContext(player,
                { rvId = rvId, generation = generation,
                    identityKey = identityOrReason.key })
            if not contextOk then return false, contextOrReason end
            sharedContext = sharedContext or contextOrReason
            local exactOk, exactOrReason = roofRefreshExactPosition(player)
            if not exactOk then return false, exactOrReason end
            local returnOk, returnPosition = pcall(roofRefreshPosition,
                exactOrReason, "group return")
            if not returnOk then return false, Constants.INVALID_RV_DATA end
            if not TemplateGeometry.isWalkableInManagedRegion(returnPosition,
                contextOrReason.boundary.managed) then
                return false, "roof refresh group return position is not current active RV geometry"
            end
            members[#members + 1] = {
                player = player,
                identity = identityOrReason,
                identityKey = identityOrReason.key,
                roomKey = roomKey,
                rvId = rvId,
                generation = generation,
                originalPosition = exactOrReason,
                returnPosition = returnPosition,
                acknowledged = false,
                arrived = false,
                arrivalConsumed = false,
                finalReturned = false,
                relocationNeedsResend = false,
                relocationRetryAtTick = ctx.serverTick,
                relocationLastSentTick = nil,
                -- Keep the refresh completion bit present from the first in-memory member
                -- record so completion is explicit and idempotent.
                refreshCompleted = false,
            }
            print("[RailroaderRVTest] roof refresh group member captured room="
                .. roomKey .. " player=" .. tostring(identityOrReason.key)
                .. " original=" .. tostring(exactOrReason.x) .. ","
                .. tostring(exactOrReason.y) .. ","
                .. tostring(exactOrReason.z))
        end
        if not sharedContext then
            return false, Constants.INVALID_RV_DATA
        end
        local destinationOk, destinationOrReason = roofRefreshDestination(
            sharedContext, { phase = "temporary" })
        if not destinationOk then return false, destinationOrReason end
        local destination = destinationOrReason
        local worldOk, worldReason = roofRefreshWorldCoordinateValid(destination)
        if not worldOk then return false, worldReason end

        ctx.roofRefreshGroupSerial = ctx.roofRefreshGroupSerial + 1
        local token = "roof-refresh-group:" .. rvId .. ":"
            .. tostring(generation) .. ":" .. tostring(ctx.serverTick) .. ":"
            .. tostring(ctx.roofRefreshGroupSerial)
        local group = {
            roomKey = roomKey, rvId = rvId, generation = generation,
            phase = "temporary", token = token,
            target = copyRoofRefreshPosition(destination), members = members,
            allowedPlayers = {},
            startedAt = math.floor(os.time()),
            queuedAtTick = ctx.serverTick,
            deadlineTick = ctx.serverTick + RELOCATION_TIMEOUT_TICKS,
            disconnectStartedTick = nil,
        }
        ctx.roofRefreshRelocationGroup = group
        ctx.roofRefreshGroupFailure = nil
        for i = 1, #members do
            local member = members[i]
            member.token = token
            group.allowedPlayers[member.player] = true
            local beginCallOk, armed = false, false
            if Boundary and type(Boundary.beginTransition) == "function" then
                beginCallOk, armed = pcall(Boundary.beginTransition,
                    member.player, rvId, generation, token,
                    "roof-refresh-group")
            end
            if not beginCallOk or armed ~= true then
                local failure = "roof refresh group boundary transition could not be armed"
                failRoofRefreshRelocationGroup(failure)
                return false, failure
            end
        end
        for i = 1, #members do
            local member = members[i]
            local payload = {
                token = token, onlineId = member.identity.onlineId,
                rvId = rvId, generation = generation,
                x = group.target.x, y = group.target.y, z = group.target.z,
                roofRepairTransition = true, roofRepairPhase = "temporary",
            }
            -- applyRoofRefreshTeleport wraps teleportTo and the authoritative
            -- setter sequence so a stale client packet cannot floor this move.
            local sentOk = ServerUtil.callGlobalSucceeded("sendServerCommand", member.player,
                COMMAND_MODULE, COMMAND_RELOCATE, payload)
            if not sentOk or not applyRoofRefreshTeleport(member.player,
                group.target, true) then
                local failure = "roof refresh group temporary relocation failed"
                failRoofRefreshRelocationGroup(failure)
                return false, failure
            end
            member.relocationLastSentTick = ctx.serverTick
            member.relocationRetryAtTick = ctx.serverTick
                + ROOF_RELOCATION_RETRY_TICKS
            member.relocationNeedsResend = false
        end
        print("[RailroaderRVTest] roof refresh group relocation queued room="
            .. roomKey .. " members=" .. tostring(#members) .. " target="
            .. tostring(group.target.x) .. "," .. tostring(group.target.y)
            .. "," .. tostring(group.target.z)
            .. " targetKind=rv-center-minus-offset")
        return true, token
    end)
    if not callOk then return false, safeErrorText(result) end
    return result, reason
end

local function keepRoofRefreshFinalReturnAlive(member)
    if type(member) ~= "table" or type(member.token) ~= "string"
        or not Boundary then return end
    local resolved, playerOrReason = resolvePendingPlayer(member)
    if not resolved then return end
    member.player = playerOrReason
    local livePlayer = playerOrReason
    local keepUntil = ctx.serverTick + RELOCATION_POST_ACK_TICKS + 2
    if type(Boundary.extendTransition) == "function" then
        local extendCallOk, extended = pcall(Boundary.extendTransition,
            livePlayer, member.token, keepUntil)
        if extendCallOk and extended == true then return end
    end
    -- If the live lease expired while the same process was waiting, re-arm only
    -- this exact in-memory token and stable identity; no guessed player is used.
    if type(Boundary.beginTransition) == "function" then
        local beginCallOk, armed = pcall(Boundary.beginTransition, livePlayer,
            member.rvId, member.generation, member.token, "roof-refresh-return")
        if armed == true and type(Boundary.extendTransition) == "function" then
            pcall(Boundary.extendTransition, livePlayer, member.token, keepUntil)
            print("[RailroaderRVTest] roof refresh return lease re-armed identity="
                .. tostring(member.identityKey))
        end
    end
end

-- A reconnect drops the client's in-flight relocation state.  Re-send only
-- the current grouped phase for the same member/token, at a bounded cadence;
-- this is process-local and never creates a second roof transaction.
local function resendRoofRefreshMemberPhase(group, member)
    if type(group) ~= "table" or type(member) ~= "table"
        or not member.player or type(member.token) ~= "string"
        or member.token == "" then
        return false
    end
    -- An already observed arrival is still owned by the grouped transaction,
    -- but it no longer needs a relocation packet.  In particular, a reconnect
    -- between the arrival ACK and the adapter's consume call must not reset
    -- that barrier and make the group wait for a packet the client no longer
    -- owns.
    if member.arrived == true or member.completed == true then
        member.relocationNeedsResend = false
        return false
    end
    local payload, target, exactReturn
    if group.phase == "temporary" then
        target = group.target
        payload = {
            token = member.token,
            onlineId = member.identity and member.identity.onlineId,
            rvId = member.rvId, generation = member.generation,
            x = target and target.x, y = target and target.y,
            z = target and target.z,
            roofRepairTransition = true, roofRepairPhase = "temporary",
        }
        exactReturn = false
    elseif group.phase == "return" then
        payload = member.returnPayload
        target = member.target
        exactReturn = true
    else
        return false
    end
    if type(payload) ~= "table" or type(target) ~= "table"
        or type(target.x) ~= "number" or type(target.y) ~= "number"
        or type(target.z) ~= "number" then
        return false
    end
    local sentOk = ServerUtil.callGlobalSucceeded("sendServerCommand", member.player,
        COMMAND_MODULE, COMMAND_RELOCATE, payload)
    local moved = applyRoofRefreshTeleport(member.player, target, not exactReturn)
    if not sentOk or not moved then return false end
    member.relocationNeedsResend = false
    member.relocationRetryAtTick = ctx.serverTick
    member.relocationLastSentTick = ctx.serverTick
    member.acknowledged = false
    member.acknowledgedAtTick = nil
    member.arrived = false
    member.arrivalConsumed = false
    member.completed = false
    return true
end

local function keepRoofRefreshTransitionAlive()
    if ctx.roofRefreshGroupFinalReturn and ctx.roofRefreshGroupFinalReturn.group then
        local group = ctx.roofRefreshGroupFinalReturn.group
        for i = 1, #(group.members or {}) do
            local member = group.members[i]
            if not member.finalReturned then
                keepRoofRefreshFinalReturnAlive(member)
            end
        end
    end
    local group = ctx.roofRefreshRelocationGroup
    if group then
        local disconnected = false
        for i = 1, #(group.members or {}) do
            local resolved, reason = resolveRoofRefreshGroupPlayer(group,
                group.members[i])
            if not resolved then
                if reason == "requesting player disconnected or was replaced" then
                    disconnected = true
                end
            end
        end
        if disconnected then
            -- Do not spend the timeout while an authoritative player object is
            -- absent; the group remains owned until reconnect.  The deadline
            -- is shifted only when all identities have rebound, preserving the
            -- same token and one transaction.
            if group.disconnectStartedTick == nil then
                group.disconnectStartedTick = ctx.serverTick
            end
            return true
        end
        if group.disconnectStartedTick ~= nil then
            local paused = ctx.serverTick - group.disconnectStartedTick
            if paused > 0 then
                group.queuedAtTick = (group.queuedAtTick or ctx.serverTick)
                    + paused
                group.deadlineTick = (group.deadlineTick or ctx.serverTick)
                    + paused
            end
            group.disconnectStartedTick = nil
            for i = 1, #(group.members or {}) do
                local member = group.members[i]
                if not member.arrived and not member.completed then
                    member.relocationNeedsResend = true
                    member.relocationRetryAtTick = ctx.serverTick
                end
            end
        end
        if ctx.serverTick > (group.deadlineTick or ctx.serverTick) then
            failRoofRefreshRelocationGroup("roof refresh group relocation transaction timed out")
            return false
        end
        if not Boundary or type(Boundary.extendTransition) ~= "function" then
            failRoofRefreshRelocationGroup("roof refresh group boundary lease service is unavailable")
            return false
        end
        for i = 1, #(group.members or {}) do
            local member = group.members[i]
            if not member.completed then
                local resolved, livePlayer = resolveRoofRefreshGroupPlayer(
                    group, member)
                if not resolved then return true end
                member.player = livePlayer
                local leaseUntil = ctx.serverTick
                    + RELOCATION_POST_ACK_TICKS + 2
                local boundedUntil = earlierTick(group.deadlineTick, leaseUntil)
                local extendCallOk, extended = pcall(
                    Boundary.extendTransition, member.player, member.token,
                    boundedUntil)
                if not extendCallOk or extended ~= true then
                    keepRoofRefreshFinalReturnAlive(member)
                    local retryOk, retryLive = resolveRoofRefreshGroupPlayer(
                        group, member)
                    if not retryOk or not retryLive then return true end
                    local recheckOk, rechecked = pcall(Boundary.extendTransition,
                        retryLive, member.token, boundedUntil)
                    if not recheckOk or rechecked ~= true then
                        failRoofRefreshRelocationGroup(
                            "roof refresh group boundary transition expired")
                        return false
                    end
                end
            end
        end
        for i = 1, #(group.members or {}) do
            local member = group.members[i]
            if member.arrived or member.completed then
                member.relocationNeedsResend = false
            elseif member.relocationNeedsResend
                and ctx.serverTick
                    >= (member.relocationRetryAtTick or 0) then
                local resent = resendRoofRefreshMemberPhase(group, member)
                member.relocationRetryAtTick = ctx.serverTick
                    + ROOF_RELOCATION_RETRY_TICKS
                if not resent then
                    -- Keep the same transaction alive and retry at the bounded
                    -- cadence; processRoofRefreshRelocationGroup remains the
                    -- authoritative failure/timeout path.
                    member.relocationNeedsResend = true
                end
            end
        end
    end
    return true
end

local function roofRefreshRelocationPositionStillSyncing(reason)
    return reason == "server player has not reached the roof refresh destination"
        or reason == "server player has no current square after roof refresh relocation"
        or reason == "server player current square does not match roof refresh destination"
        or reason == "roof refresh temporary destination cell is not loaded"
        or reason == "roof refresh temporary destination square is not loaded"
        or reason == "roof refresh temporary destination is still room geometry"
end

local function acknowledgeRoofRefreshRelocation(player, token)
    local group = ctx.roofRefreshRelocationGroup
    if not group then return false end
    if type(token) ~= "string" or token == "" then
        return true, false,
            "unexpected or malformed roof refresh group acknowledgement"
    end
    local member = roofRefreshGroupMember(group, player, token)
    if not member then
        return true, false,
            "unexpected or malformed roof refresh group acknowledgement"
    end
    local resolved, playerOrReason = resolveRoofRefreshGroupPlayer(group, member)
    if not resolved then return true, false, playerOrReason end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk or identityOrReason.key ~= member.identityKey then
        return true, false, identityOk
            and "acknowledgement sender does not own the group request"
            or identityOrReason
    end
    member.acknowledged = true
    member.acknowledgedAtTick = ctx.serverTick
    return true, true
end

local function processRoofRefreshRelocationGroup()
    local group = ctx.roofRefreshRelocationGroup
    if not group then return end
    -- A live process owns the exact-tick group across a player disconnect.
    -- Defer all phase work until every stable identity has a live IsoPlayer;
    -- this avoids converting a reconnect into a failed/cancelled transaction.
    for i = 1, #(group.members or {}) do
        local resolved = resolveRoofRefreshGroupPlayer(group,
            group.members[i])
        if not resolved then return end
    end
    if ctx.serverTick > (group.deadlineTick or ctx.serverTick) then
        failRoofRefreshRelocationGroup("roof refresh group relocation transaction timed out")
        return
    end
    for i = 1, #(group.members or {}) do
        local member = group.members[i]
        if not member.arrived then
            local resolved, playerOrReason = resolveRoofRefreshGroupPlayer(
                group, member)
            if not resolved then
                return
            end
            local stateCallOk, stateOk, stateOrReason = pcall(
                validateAuthoritativePlayer, playerOrReason)
            if not stateCallOk then
                failRoofRefreshRelocationGroup(safeErrorText(stateOk))
                return
            end
            if not stateOk then
                failRoofRefreshRelocationGroup(stateOrReason)
                return
            end
            local contextCallOk, contextOk, contextOrReason = pcall(
                currentRoofRefreshContext, playerOrReason, {
                    rvId = member.rvId, generation = member.generation,
                    identityKey = member.identityKey,
                })
            if not contextCallOk then
                contextOrReason = safeErrorText(contextOk)
                contextOk = false
            end
            if not contextOk then
                failRoofRefreshRelocationGroup(contextOrReason)
                return
            end
            local target = group.phase == "temporary"
                and group.target or member.target
            if group.phase == "return" then
                local exactCallOk, exactPosition =
                    tryAuthoritativePlayerPosition(playerOrReason)
                -- The client ACK plus floor/z proof is enough to stop a
                -- duplicate return packet. If the engine normalized a
                -- fractional x/y, completeRoofRefreshRelocation reasserts the
                -- captured float before it releases the lease.
                local atTarget = exactCallOk and type(exactPosition) == "table"
                    and math.floor(exactPosition.x) == math.floor(target.x)
                    and math.floor(exactPosition.y) == math.floor(target.y)
                    and math.floor(exactPosition.z) == math.floor(target.z)
                    and exactPosition.z ~= ROOF_REFRESH_TEMP_Z
                if not atTarget then
                    local waitLogTick = member.returnTargetLogTick
                    if type(waitLogTick) ~= "number"
                        or (ctx.serverTick - waitLogTick) >= 30 then
                        local positionText = exactCallOk
                            and type(exactPosition) == "table"
                            and (tostring(exactPosition.x) .. ","
                                .. tostring(exactPosition.y) .. ","
                                .. tostring(exactPosition.z))
                            or safeErrorText(exactPosition)
                        print("[RailroaderRVTest] roof refresh group return target wait room="
                            .. tostring(group.roomKey or "unknown") .. " player="
                            .. tostring(member.identityKey) .. " position="
                            .. positionText .. " target=" .. tostring(target.x) .. ","
                            .. tostring(target.y) .. "," .. tostring(target.z))
                        member.returnTargetLogTick = Core.getTick()
                    end
                    if member.acknowledged == true then
                        -- A consumed ACK does not authorize a duplicate packet
                        -- just because a stale PlayerPacket briefly moved the
                        -- server object back to the remote point.
                        local moved = applyRoofRefreshTeleport(playerOrReason,
                            target, false)
                        member.relocationNeedsResend = not moved
                        if moved then
                            exactCallOk, exactPosition =
                                tryAuthoritativePlayerPosition(playerOrReason)
                            atTarget = exactCallOk
                                and type(exactPosition) == "table"
                                and math.floor(exactPosition.x) == math.floor(target.x)
                                and math.floor(exactPosition.y) == math.floor(target.y)
                                and math.floor(exactPosition.z) == math.floor(target.z)
                                and exactPosition.z ~= ROOF_REFRESH_TEMP_Z
                        end
                    else
                        -- A stale/fallen member without an ACK needs the same
                        -- return command again, but never once per tick.
                        member.arrivalConsumed = false
                        member.completed = false
                        member.arrived = false
                        member.relocationNeedsResend = true
                        if ctx.serverTick
                            < (member.relocationRetryAtTick or 0) then
                            -- Wait for the bounded retry cadence below.
                        elseif type(member.returnPayload) ~= "table" then
                            failRoofRefreshRelocationGroup(
                                "roof refresh group return payload is unavailable")
                            return
                        else
                            local sentOk = ServerUtil.callGlobalSucceeded("sendServerCommand",
                                playerOrReason, COMMAND_MODULE, COMMAND_RELOCATE,
                                member.returnPayload)
                            local moved = applyRoofRefreshTeleport(playerOrReason,
                                target, false)
                            member.relocationLastSentTick = ctx.serverTick
                            member.relocationRetryAtTick = ctx.serverTick
                                + ROOF_RELOCATION_RETRY_TICKS
                            if not sentOk or not moved then
                                member.relocationNeedsResend = true
                            else
                                member.relocationNeedsResend = false
                            end
                        end
                    end
                end
            end
            if not member.acknowledged
                or (ctx.serverTick - group.queuedAtTick)
                    < RELOCATION_MIN_TICKS
                or (ctx.serverTick
                    - (member.acknowledgedAtTick or ctx.serverTick))
                    < RELOCATION_POST_ACK_TICKS then
                -- Keep waiting for the server's authoritative position proof.
            else
                local readyCallOk, ready, readyReason = pcall(
                    roofRefreshTargetReady, playerOrReason, target,
                    group.phase, group.allowedPlayers)
                if not readyCallOk then
                    readyReason = safeErrorText(ready)
                    ready = false
                end
                if not ready then
                    if not roofRefreshRelocationPositionStillSyncing(readyReason) then
                        failRoofRefreshRelocationGroup(readyReason)
                        return
                    end
                else
                    member.arrived = true
                    member.arrivedAtTick = ctx.serverTick
                    print("[RailroaderRVTest] roof refresh group member arrived room="
                        .. tostring(group.roomKey or "unknown") .. " player="
                        .. tostring(member.identityKey) .. " phase="
                        .. tostring(group.phase) .. " target="
                        .. tostring(target.x) .. "," .. tostring(target.y)
                        .. "," .. tostring(target.z))
                end
            end
        end
    end
end


ctx.roofRefreshGroupMatches = roofRefreshGroupMatches
ctx.roofRefreshGroupMember = roofRefreshGroupMember
ctx.resolveRoofRefreshGroupPlayer = resolveRoofRefreshGroupPlayer
ctx.roofRefreshGroupAll = roofRefreshGroupAll
ctx.failRoofRefreshRelocationGroup = failRoofRefreshRelocationGroup
ctx.acknowledgeRoofRefreshRelocation = acknowledgeRoofRefreshRelocation
ctx.processRoofRefreshRelocationGroup = processRoofRefreshRelocationGroup
ctx.processRoofRefreshGroupFinalReturn = processRoofRefreshGroupFinalReturn
ctx.keepRoofRefreshTransitionAlive = keepRoofRefreshTransitionAlive
end
