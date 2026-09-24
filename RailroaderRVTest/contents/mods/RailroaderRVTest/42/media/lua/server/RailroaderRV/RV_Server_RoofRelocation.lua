-- RV_Server: RoofRelocation responsibilities.
return function(ctx)
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND_RELOCATE = ctx.COMMAND_RELOCATE
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local Bitmap = ctx.Bitmap
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local function safeErrorText(...) return ctx.safeErrorText(...) end
local RELOCATION_POST_ACK_TICKS = ctx.RELOCATION_POST_ACK_TICKS
local RELOCATION_TIMEOUT_TICKS = ctx.RELOCATION_TIMEOUT_TICKS
local ROOF_REPAIR_RETURN_RETRY_TICKS = ctx.ROOF_REPAIR_RETURN_RETRY_TICKS
local ROOF_RELOCATION_RETRY_TICKS = ctx.ROOF_RELOCATION_RETRY_TICKS
local ROOF_REPAIR_TEMP_Z = ctx.ROOF_REPAIR_TEMP_Z
local notifyFailure = ctx.notifyFailure
local tryAuthoritativePlayerPosition = ctx.tryAuthoritativePlayerPosition
local resolveRoofRepairGroupPlayer = ctx.resolveRoofRepairGroupPlayer
local authoritativePlayerPosition = ctx.authoritativePlayerPosition
local playerIdentity = ctx.playerIdentity
local resolvePendingPlayer = ctx.resolvePendingPlayer
local roofRepairPosition = ctx.roofRepairPosition
local roofRepairWorldCoordinateValid = ctx.roofRepairWorldCoordinateValid
local currentRoofRepairContext = ctx.currentRoofRepairContext
local roofRepairDestination = ctx.roofRepairDestination
local applyRoofRepairTeleport = ctx.applyRoofRepairTeleport
local copyRoofRepairPosition = ctx.copyRoofRepairPosition
local rollbackRoofRepairRelocation = ctx.rollbackRoofRepairRelocation
local function processRoofRepairRelocationGroup(...) return ctx.processRoofRepairRelocationGroup(...) end

local function roofRepairGroupMatches(group, rvId, generation, bitmapVersion)
    return type(group) == "table"
        and tostring(group.rvId) == tostring(rvId)
        and ServerUtil.integer(group.generation) == ServerUtil.integer(generation)
        and ServerUtil.integer(group.bitmapVersion) == ServerUtil.integer(bitmapVersion)
end

local function roofRepairGroupMember(group, player, token)
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

local function roofRepairGroupAll(group, field, value)
    if type(group) ~= "table" or type(group.members) ~= "table"
        or #group.members == 0 then
        return false
    end
    for i = 1, #group.members do
        if group.members[i][field] ~= value then return false end
    end
    return true
end

local function roofRepairExactPosition(player)
    return authoritativePlayerPosition(player)
end

-- The group fail-safe never trusts a position supplied by the adapter.  Each
-- member's exact original position is captured from the authoritative server
-- object before the first remote command; returnPosition is only the ServerUtil.integer
-- square required by the token-only client bridge.
local function failRoofRepairRelocationGroup(reason)
    local group = ctx.roofRepairRelocationGroup
    if not group then return end
    ctx.roofRepairRelocationGroup = nil
    ctx.roofRepairGroupFailure = {
        roomKey = group.roomKey,
        rvId = group.rvId,
        generation = group.generation,
        bitmapVersion = group.bitmapVersion,
        token = group.token,
        reason = safeErrorText(reason),
    }
    local allReturned = true
    for i = 1, #group.members do
        local member = group.members[i]
        member.finalReturnReason = reason
        local rollbackCallOk, returned, returnReason = pcall(
            rollbackRoofRepairRelocation, member)
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
        ctx.roofRepairGroupFinalReturn = {
            group = group,
            attempts = 0,
            nextTick = ctx.serverTick + 1,
        }
    else
    end
    print("[RailroaderRVTest] roof repair group cancelled room="
        .. tostring(group.roomKey or "unknown") .. " members="
        .. tostring(#group.members) .. " reason=" .. safeErrorText(reason)
        .. " finalReturn=" .. (allReturned and "complete" or "pending"))
end

local function processRoofRepairGroupFinalReturn()
    local retry = ctx.roofRepairGroupFinalReturn
    if not retry or ctx.serverTick < (retry.nextTick or ctx.serverTick) then return end
    local group = retry.group
    retry.attempts = (retry.attempts or 0) + 1
    local allReturned = true
    for i = 1, #(group.members or {}) do
        local member = group.members[i]
        if member.finalReturned then
            -- A member marked returned on the previous tick is still polled
            -- authoritatively.  Do not retire the in-memory return owner if it
            -- drifted back to z=-15 or anywhere other than its captured RV coordinate.
            local resolved, playerOrReason = resolveRoofRepairGroupPlayer(
                group, member)
            local positionOk, position = false, nil
            if resolved then
                positionOk, position = tryAuthoritativePlayerPosition(
                    playerOrReason)
            end
            local original = member.originalPosition or member.returnPosition
            if not positionOk or type(position) ~= "table"
                or type(original) ~= "table"
                or position.z == ROOF_REPAIR_TEMP_Z
                or position.x ~= original.x or position.y ~= original.y
                or position.z ~= original.z then
                member.finalReturned = false
            end
        end
        if not member.finalReturned then
            local rollbackCallOk, returned, returnReason = pcall(
                rollbackRoofRepairRelocation, member)
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
        print("[RailroaderRVTest] roof repair group final return complete room="
            .. tostring(group.roomKey or "unknown") .. " attempts="
            .. tostring(retry.attempts))
        ctx.roofRepairGroupFinalReturn = nil
        return
    end
    -- A member at the remote z=-15 target is not a recoverable completion.
    -- Keep the current-schema identity/context alive and continue bounded-rate
    -- retries until the authoritative object is actually back.  In particular,
    -- do not clear the Boundary lease or drop the group after a finite count.
    retry.nextTick = ctx.serverTick + ROOF_REPAIR_RETURN_RETRY_TICKS
    print("[RailroaderRVTest] roof repair group final return pending room="
        .. tostring(group.roomKey or "unknown") .. " attempt="
        .. tostring(retry.attempts + 1) .. " reason=authoritative-return-required")
end

-- Begin or advance the multi-player refresh transaction. The adapter supplies
-- only authoritative player object references; this function re-reads every
-- identity, schema relation and x/y/z before arming any transition. The
-- temporary move is sent to all members before the adapter may run repair, so
-- the complete RV scope can unload and stream back in as one operation.
function RV.Server.beginRoofRepairRelocationGroup(request)
    local callOk, result, reason = pcall(function()
        if (type(request) ~= "table" or request.phase == "temporary")
            and (ctx.roofRepairRelocationGroup ~= nil
                or ctx.roofRepairGroupFinalReturn ~= nil)
            or ctx.transactionBusy
            or ctx.pendingGeneration ~= nil then
            return false, "another RV relocation or generation is in progress"
        end
        if type(request) ~= "table"
            or (request.phase ~= "temporary" and request.phase ~= "return") then
            return false, "roof repair group relocation request is malformed"
        end
        local rvId = tostring(request.rvId or "")
        local generation = ServerUtil.integer(request.generation)
        local bitmapVersion = ServerUtil.integer(request.bitmapVersion)
        local roomKey = tostring(request.roomKey or "")
        if rvId == "" or generation == nil or generation < 1
            or bitmapVersion ~= Constants.BITMAP_VERSION
            or roomKey ~= rvId .. ":" .. tostring(generation) .. ":"
                .. tostring(bitmapVersion) then
            return false, Constants.SAVE_REBUILD_REQUIRED
        end

        if request.phase == "return" then
            local group = ctx.roofRepairRelocationGroup
            if not roofRepairGroupMatches(group, rvId, generation,
                bitmapVersion) or group.roomKey ~= roomKey
                or group.phase ~= "temporary"
                or not roofRepairGroupAll(group, "arrived", true) then
                return false, "roof repair group temporary phase is not complete"
            end
            local returnToken = group.token
            for i = 1, #group.members do
                local member = group.members[i]
                local resolved, playerOrReason = resolveRoofRepairGroupPlayer(
                    group, member)
                if not resolved then
                    -- A live-process disconnect is retryable; the stable
                    -- identity remains owned by this in-memory group.
                    if playerOrReason == "requesting player disconnected or was replaced" then
                        return false, playerOrReason
                    end
                    failRoofRepairRelocationGroup(playerOrReason)
                    return false, playerOrReason
                end
                local livePlayer = playerOrReason
                local contextOk, contextOrReason = currentRoofRepairContext(
                    livePlayer, {
                        rvId = rvId, generation = generation,
                        bitmapVersion = bitmapVersion,
                        identityKey = member.identity.key,
                    })
                if not contextOk then
                    failRoofRepairRelocationGroup(contextOrReason)
                    return false, contextOrReason
                end
                local returnPosition = member.returnPosition
                local returnX, returnY, returnZ = math.floor(returnPosition.x),
                    math.floor(returnPosition.y), math.floor(returnPosition.z)
                if not Bitmap.containsScope(contextOrReason.bitmap, returnX,
                    returnY, returnZ)
                    or not Bitmap.isActive(contextOrReason.bitmap, returnX,
                        returnY, returnZ) then
                    local failure = "roof repair group return position is not current active RV geometry"
                    failRoofRepairRelocationGroup(failure)
                    return false, failure
                end
                local worldOk, worldReason = roofRepairWorldCoordinateValid(
                    returnPosition)
                if not worldOk then
                    failRoofRepairRelocationGroup(worldReason)
                    return false, worldReason
                end
                member.phase = "return"
                member.target = copyRoofRepairPosition(returnPosition)
                member.acknowledged = false
                member.arrived = false
                member.arrivalConsumed = false
                member.returnPayload = {
                    token = returnToken,
                    onlineId = member.identity.onlineId,
                    rvId = rvId, generation = generation,
                    bitmapVersion = bitmapVersion,
                    x = member.target.x, y = member.target.y, z = member.target.z,
                    roofRepairTransition = true,
                    roofRepairPhase = "return",
                }
            end
            group.phase = "return"
            group.returnStartedAtTick = ctx.serverTick
            for i = 1, #group.members do
                local member = group.members[i]
                local resolved, playerOrReason = resolveRoofRepairGroupPlayer(
                    group, member)
                if not resolved then
                    if playerOrReason == "requesting player disconnected or was replaced" then
                        return false, playerOrReason
                    end
                    failRoofRepairRelocationGroup(playerOrReason)
                    return false, playerOrReason
                end
                local sentOk = ServerUtil.callGlobalSucceeded("sendServerCommand", playerOrReason,
                    COMMAND_MODULE, COMMAND_RELOCATE, member.returnPayload)
                if not sentOk or not applyRoofRepairTeleport(playerOrReason,
                    member.target, false) then
                    local failure = "roof repair group return relocation failed"
                    failRoofRepairRelocationGroup(failure)
                    return false, failure
                end
                member.relocationLastSentTick = ctx.serverTick
                member.relocationRetryAtTick = ctx.serverTick
                    + ROOF_RELOCATION_RETRY_TICKS
                member.relocationNeedsResend = false
            end
            print("[RailroaderRVTest] roof repair group return queued room="
                .. roomKey .. " members=" .. tostring(#group.members)
                .. " target=server-captured-squares")
            return true, returnToken
        end

        if type(request.players) ~= "table" or #request.players < 1 then
            return false, "roof repair group has no authoritative inside players"
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
                return false, "roof repair group player identity changed"
            end
            if seen[identityOrReason.key] then
                return false, "roof repair group contains duplicate player identity"
            end
            seen[identityOrReason.key] = true
            local contextOk, contextOrReason = currentRoofRepairContext(player,
                { rvId = rvId, generation = generation,
                    bitmapVersion = bitmapVersion,
                    identityKey = identityOrReason.key })
            if not contextOk then return false, contextOrReason end
            sharedContext = sharedContext or contextOrReason
            local exactOk, exactOrReason = roofRepairExactPosition(player)
            if not exactOk then return false, exactOrReason end
            local returnOk, returnPosition = pcall(roofRepairPosition,
                exactOrReason, "group return")
            if not returnOk then return false, Constants.SAVE_REBUILD_REQUIRED end
            if not Bitmap.containsScope(contextOrReason.bitmap,
                returnPosition.x, returnPosition.y, returnPosition.z)
                or not Bitmap.isActive(contextOrReason.bitmap,
                    returnPosition.x, returnPosition.y, returnPosition.z) then
                return false, "roof repair group return position is not current active RV geometry"
            end
            members[#members + 1] = {
                player = player,
                identity = identityOrReason,
                identityKey = identityOrReason.key,
                roomKey = roomKey,
                rvId = rvId,
                generation = generation,
                bitmapVersion = bitmapVersion,
                originalPosition = exactOrReason,
                returnPosition = returnPosition,
                acknowledged = false,
                arrived = false,
                arrivalConsumed = false,
                finalReturned = false,
                relocationNeedsResend = false,
                relocationRetryAtTick = ctx.serverTick,
                relocationLastSentTick = nil,
                -- Keep the repair bit present from the first in-memory member
                -- record so completion is explicit and idempotent.
                repairCompleted = false,
            }
            print("[RailroaderRVTest] roof repair group member captured room="
                .. roomKey .. " player=" .. tostring(identityOrReason.key)
                .. " original=" .. tostring(exactOrReason.x) .. ","
                .. tostring(exactOrReason.y) .. ","
                .. tostring(exactOrReason.z))
        end
        if not sharedContext then
            return false, Constants.SAVE_REBUILD_REQUIRED
        end
        local destinationOk, destinationOrReason = roofRepairDestination(
            sharedContext, { phase = "temporary" })
        if not destinationOk then return false, destinationOrReason end
        local destination = destinationOrReason
        local worldOk, worldReason = roofRepairWorldCoordinateValid(destination)
        if not worldOk then return false, worldReason end

        ctx.roofRepairGroupSerial = ctx.roofRepairGroupSerial + 1
        local token = "roof-repair-group:" .. rvId .. ":"
            .. tostring(generation) .. ":" .. tostring(ctx.serverTick) .. ":"
            .. tostring(ctx.roofRepairGroupSerial)
        local group = {
            roomKey = roomKey, rvId = rvId, generation = generation,
            bitmapVersion = bitmapVersion, phase = "temporary", token = token,
            target = copyRoofRepairPosition(destination), members = members,
            allowedPlayers = {},
            startedAt = math.floor(os.time()),
            queuedAtTick = ctx.serverTick,
            deadlineTick = ctx.serverTick + RELOCATION_TIMEOUT_TICKS,
            disconnectStartedTick = nil,
        }
        ctx.roofRepairRelocationGroup = group
        ctx.roofRepairGroupFailure = nil
        for i = 1, #members do
            local member = members[i]
            member.token = token
            group.allowedPlayers[member.player] = true
            local beginCallOk, armed = false, false
            if Boundary and type(Boundary.beginTransition) == "function" then
                beginCallOk, armed = pcall(Boundary.beginTransition,
                    member.player, rvId, generation, token,
                    "roof-repair-group", bitmapVersion)
            end
            if not beginCallOk or armed ~= true then
                local failure = "roof repair group boundary transition could not be armed"
                failRoofRepairRelocationGroup(failure)
                return false, failure
            end
        end
        for i = 1, #members do
            local member = members[i]
            local payload = {
                token = token, onlineId = member.identity.onlineId,
                rvId = rvId, generation = generation,
                bitmapVersion = bitmapVersion,
                x = group.target.x, y = group.target.y, z = group.target.z,
                roofRepairTransition = true, roofRepairPhase = "temporary",
            }
            -- applyRoofRepairTeleport wraps teleportTo and the authoritative
            -- setter sequence so a stale client packet cannot floor this move.
            local sentOk = ServerUtil.callGlobalSucceeded("sendServerCommand", member.player,
                COMMAND_MODULE, COMMAND_RELOCATE, payload)
            if not sentOk or not applyRoofRepairTeleport(member.player,
                group.target, true) then
                local failure = "roof repair group temporary relocation failed"
                failRoofRepairRelocationGroup(failure)
                return false, failure
            end
            member.relocationLastSentTick = ctx.serverTick
            member.relocationRetryAtTick = ctx.serverTick
                + ROOF_RELOCATION_RETRY_TICKS
            member.relocationNeedsResend = false
        end
        print("[RailroaderRVTest] roof repair group relocation queued room="
            .. roomKey .. " members=" .. tostring(#members) .. " target="
            .. tostring(group.target.x) .. "," .. tostring(group.target.y)
            .. "," .. tostring(group.target.z)
            .. " targetKind=rv-center-minus-offset")
        return true, token
    end)
    if not callOk then return false, safeErrorText(result) end
    return result, reason
end

local function keepRoofRepairFinalReturnAlive(member)
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
            member.rvId, member.generation, member.token, "roof-repair-return",
            member.bitmapVersion)
        if armed == true and type(Boundary.extendTransition) == "function" then
            pcall(Boundary.extendTransition, livePlayer, member.token, keepUntil)
            print("[RailroaderRVTest] roof repair return lease re-armed identity="
                .. tostring(member.identityKey))
        end
    end
end

-- A reconnect drops the client's in-flight relocation state.  Re-send only
-- the current grouped phase for the same member/token, at a bounded cadence;
-- this is process-local and never creates a second roof transaction.
local function resendRoofRepairMemberPhase(group, member)
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
            bitmapVersion = member.bitmapVersion,
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
    local moved = applyRoofRepairTeleport(member.player, target, not exactReturn)
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

local function keepRoofRepairTransitionAlive()
    if ctx.roofRepairGroupFinalReturn and ctx.roofRepairGroupFinalReturn.group then
        local group = ctx.roofRepairGroupFinalReturn.group
        for i = 1, #(group.members or {}) do
            local member = group.members[i]
            if not member.finalReturned then
                keepRoofRepairFinalReturnAlive(member)
            end
        end
    end
    local group = ctx.roofRepairRelocationGroup
    if group then
        local disconnected = false
        for i = 1, #(group.members or {}) do
            local resolved, reason = resolveRoofRepairGroupPlayer(group,
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
                group.queuedAtTick = (group.queuedAtTick or ctx.serverTick) + paused
                group.deadlineTick = (group.deadlineTick or ctx.serverTick) + paused
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
            failRoofRepairRelocationGroup("roof repair group relocation transaction timed out")
            return false
        end
        if not Boundary or type(Boundary.extendTransition) ~= "function" then
            failRoofRepairRelocationGroup("roof repair group boundary lease service is unavailable")
            return false
        end
        for i = 1, #(group.members or {}) do
            local member = group.members[i]
            if not member.completed then
                local resolved, livePlayer = resolveRoofRepairGroupPlayer(
                    group, member)
                if not resolved then return true end
                member.player = livePlayer
                local extendCallOk, extended = pcall(
                    Boundary.extendTransition, member.player, member.token,
                    math.min(group.deadlineTick,
                        ctx.serverTick + RELOCATION_POST_ACK_TICKS + 2))
                if not extendCallOk or extended ~= true then
                    keepRoofRepairFinalReturnAlive(member)
                    local retryOk, retryLive = resolveRoofRepairGroupPlayer(
                        group, member)
                    if not retryOk or not retryLive then return true end
                    local recheckOk, rechecked = pcall(Boundary.extendTransition,
                        retryLive, member.token,
                        math.min(group.deadlineTick,
                            ctx.serverTick + RELOCATION_POST_ACK_TICKS + 2))
                    if not recheckOk or rechecked ~= true then
                        failRoofRepairRelocationGroup(
                            "roof repair group boundary transition expired")
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
                and ctx.serverTick >= (member.relocationRetryAtTick or 0) then
                local resent = resendRoofRepairMemberPhase(group, member)
                member.relocationRetryAtTick = ctx.serverTick
                    + ROOF_RELOCATION_RETRY_TICKS
                if not resent then
                    -- Keep the same transaction alive and retry at the bounded
                    -- cadence; processRoofRepairRelocationGroup remains the
                    -- authoritative failure/timeout path.
                    member.relocationNeedsResend = true
                end
            end
        end
    end
    return true
end


ctx.roofRepairGroupMatches = roofRepairGroupMatches
ctx.roofRepairGroupMember = roofRepairGroupMember
ctx.roofRepairGroupAll = roofRepairGroupAll
ctx.failRoofRepairRelocationGroup = failRoofRepairRelocationGroup
ctx.processRoofRepairGroupFinalReturn = processRoofRepairGroupFinalReturn
ctx.keepRoofRepairTransitionAlive = keepRoofRepairTransitionAlive
end
