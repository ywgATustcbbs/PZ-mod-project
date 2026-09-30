-- RV_Server: RoofApi responsibilities.
return function(ctx)
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local RoofRefresh = ctx.RoofRefresh
local RV = ctx.RV
local Core = ctx.Core
local ServerUtil = ctx.ServerUtil
local GenerationTransaction = ctx.GenerationTransaction
local function safeErrorText(...) return ctx.safeErrorText(...) end
local function requireCurrentManifest(...) return ctx.requireCurrentManifest(...) end
local ROOF_REFRESH_TEMP_Z = ctx.ROOF_REFRESH_TEMP_Z
local manifestTable = ctx.manifestTable
local resolveRoofRefreshGroupPlayer = ctx.resolveRoofRefreshGroupPlayer
local authoritativePlayerPosition = ctx.authoritativePlayerPosition
local playerIdentity = ctx.playerIdentity
local currentRoofRefreshContext = ctx.currentRoofRefreshContext
local playerAtRoofRefreshDestination = ctx.playerAtRoofRefreshDestination
local applyRoofRefreshTeleport = ctx.applyRoofRefreshTeleport
local roofRefreshGroupMatches = ctx.roofRefreshGroupMatches
local roofRefreshGroupMember = ctx.roofRefreshGroupMember
local roofRefreshGroupAll = ctx.roofRefreshGroupAll
local failRoofRefreshRelocationGroup = ctx.failRoofRefreshRelocationGroup

function RV.Server.consumeRoofRefreshRelocationArrival(player)
    local member = roofRefreshGroupMember(ctx.roofRefreshRelocationGroup, player)
    if not member or not member.arrived or member.arrivalConsumed then
        return nil
    end
    local resolved, current = resolveRoofRefreshGroupPlayer(
        ctx.roofRefreshRelocationGroup, member)
    if not resolved then return nil end
    member.arrivalConsumed = true
    return member
end

function RV.Server.roofRefreshRelocationGroupReady(rvId, generation,
    bitmapVersion)
    local group = ctx.roofRefreshRelocationGroup
    return roofRefreshGroupMatches(group, rvId, generation, bitmapVersion)
        and group.phase == "temporary"
        and roofRefreshGroupAll(group, "arrived", true)
end

-- Cross-module mutex queries.  These expose only live process state; no
-- relocation ledger or save field is involved.  A roof group remains busy
-- through temporary relocation, return, room refresh, and its final-return retry object so the
-- adapter cannot mutate the same RV while its captured members are returning.
function RV.Server.isGenerationTransactionActive()
    if type(GenerationTransaction) ~= "table"
        or type(GenerationTransaction.isActive) ~= "function" then
        return true, "generation transaction state is unavailable"
    end
    local activeOk, active = pcall(GenerationTransaction.isActive)
    if not activeOk or type(active) ~= "boolean" then
        return true, "generation transaction state is unavailable"
    end
    return active
end

function RV.Server.isRoofRefreshTransactionActive(_rvId)
    -- This is a service-wide mutex query.  The optional rvId is retained in
    -- the signature for callers that want to keep their diagnostic context,
    -- but an active roof transaction must never be bypassed by naming another
    -- RV in the same managed world scope.
    local function busyGroup(group)
        if group == nil then return false end
        if type(group) ~= "table" then
            return true, "roof refresh transaction state is unavailable"
        end
        if type(group.rvId) ~= "string" or group.rvId == "" then
            return true, "roof refresh transaction state is unavailable"
        end
        return true, "roof refresh is in progress (rvId="
            .. tostring(group.rvId) .. ")"
    end
    local active, reason = busyGroup(ctx.roofRefreshRelocationGroup)
    if active then return true, reason end
    if ctx.roofRefreshGroupFinalReturn ~= nil
        and type(ctx.roofRefreshGroupFinalReturn) ~= "table" then
        return true, "roof refresh transaction state is unavailable"
    end
    local finalReturn = ctx.roofRefreshGroupFinalReturn
        and ctx.roofRefreshGroupFinalReturn.group or nil
    if ctx.roofRefreshGroupFinalReturn ~= nil and type(finalReturn) ~= "table" then
        return true, "roof refresh transaction state is unavailable"
    end
    active, reason = busyGroup(finalReturn)
    if active then return true, reason end
    return false
end

-- The stateless z=-15 sentinel must never race a transaction that this live
-- process still owns.  Claims are keyed only by the stable onlineID+username
-- identity and exist in memory for the lifetime of the transaction.
function RV.Server.isRelocationIdentityClaimed(identityKey)
    if type(identityKey) ~= "string" or identityKey == "" then
        return false
    end
    local function groupClaims(group)
        if group == nil then return false end
        if type(group) ~= "table" or type(group.members) ~= "table"
            or #group.members < 1 then
            return nil
        end
        for i = 1, #(group and group.members or {}) do
            local member = group.members[i]
            if type(member) ~= "table" or type(member.identityKey) ~= "string"
                or member.identityKey == "" then
                return nil
            end
            if member.identityKey == identityKey
                or type(member.identity) == "table"
                and member.identity.key == identityKey then
                return true
            end
        end
        return false
    end
    if type(GenerationTransaction) ~= "table"
        or type(GenerationTransaction.current) ~= "function" then
        return nil
    end
    local transactionOk, pending = pcall(GenerationTransaction.current)
    if not transactionOk then
        return nil
    end
    if pending ~= nil then
        if type(pending) ~= "table"
            or type(pending.identity) ~= "table"
            or type(pending.identity.key) ~= "string"
            or pending.identity.key == "" then
            return nil
        end
        return pending.identity.key == identityKey
    end
    local activeClaims = groupClaims(ctx.roofRefreshRelocationGroup)
    if activeClaims ~= false then return activeClaims end
    if ctx.roofRefreshGroupFinalReturn ~= nil
        and (type(ctx.roofRefreshGroupFinalReturn) ~= "table"
            or type(ctx.roofRefreshGroupFinalReturn.group) ~= "table") then
        return nil
    end
    local finalGroup = ctx.roofRefreshGroupFinalReturn
        and ctx.roofRefreshGroupFinalReturn.group or nil
    local finalClaims = groupClaims(finalGroup)
    if finalClaims ~= false then return finalClaims end
    return false
end

function RV.Server.getRoofRefreshRelocationState(rvId, generation,
    bitmapVersion, token)
    if roofRefreshGroupMatches(ctx.roofRefreshRelocationGroup, rvId, generation,
        bitmapVersion) then
        return "active", ctx.roofRefreshRelocationGroup.phase
    end
    if ctx.roofRefreshGroupFailure
        and roofRefreshGroupMatches(ctx.roofRefreshGroupFailure, rvId, generation,
            bitmapVersion)
        and type(token) == "string"
        and token ~= ""
        and ctx.roofRefreshGroupFailure.token == token then
        return "failed", ctx.roofRefreshGroupFailure.reason
    end
    return "idle"
end

function RV.Server.isRoofRefreshBoundaryReadAllowed(rvId, generation,
    bitmapVersion, identityKey)
    local group = ctx.roofRefreshRelocationGroup
    if not roofRefreshGroupMatches(group, rvId, generation, bitmapVersion)
        or group.phase ~= "return"
        or type(identityKey) ~= "string" or identityKey == ""
        or type(group.members) ~= "table" then
        return false
    end
    for i = 1, #group.members do
        local member = group.members[i]
        local proof = type(member) == "table"
            and member.returnPositionProof or nil
        local target = type(member) == "table"
            and member.target or nil
        if type(member) == "table"
            and member.identityKey == identityKey then
            return member.completed == true
                and type(proof) == "table"
                and proof.source == "server-authoritative-return-ack"
                and proof.identityKey == identityKey
                and proof.rvId == member.rvId
                and proof.generation == member.generation
                and proof.bitmapVersion == member.bitmapVersion
                and proof.token == member.token
                and type(target) == "table"
                and proof.x == target.x and proof.y == target.y
                and proof.z == target.z
        end
    end
    return false
end

function RV.Server.isRoofRefreshBoundaryContextReadAllowed(rvId, generation,
    bitmapVersion, identityKey)
    local group = ctx.roofRefreshRelocationGroup
    if not roofRefreshGroupMatches(group, rvId, generation, bitmapVersion)
        or (group.phase ~= "temporary" and group.phase ~= "return")
        or type(identityKey) ~= "string" or identityKey == ""
        or type(group.members) ~= "table" then
        return false
    end
    for i = 1, #group.members do
        local member = group.members[i]
        if type(member) == "table"
            and member.identityKey == identityKey
            and member.rvId == group.rvId
            and member.generation == group.generation
            and member.bitmapVersion == group.bitmapVersion then
            return true
        end
    end
    return false
end

function RV.Server.consumeRoofRefreshRelocationFailure(rvId, generation,
    bitmapVersion, token)
    if ctx.roofRefreshGroupFailure
        and roofRefreshGroupMatches(ctx.roofRefreshGroupFailure, rvId, generation,
            bitmapVersion)
        and type(token) == "string"
        and token ~= ""
        and ctx.roofRefreshGroupFailure.token == token then
        local failure = ctx.roofRefreshGroupFailure
        ctx.roofRefreshGroupFailure = nil
        return failure.reason
    end
    return nil
end

function RV.Server.completeRoofRefreshRelocation(player, token)
    if ctx.roofRefreshRelocationGroup then
        local group = ctx.roofRefreshRelocationGroup
        local member = roofRefreshGroupMember(group, player, token)
        if not member or group.phase ~= "return" then
            return false, "roof refresh group return acknowledgement is stale"
        end
        local resolved, livePlayerOrReason = resolveRoofRefreshGroupPlayer(
            group, member)
        if not resolved then
            return false, livePlayerOrReason
        end
        local livePlayer = livePlayerOrReason
        local identityOk, identityOrReason = playerIdentity(livePlayer)
        if not identityOk or identityOrReason.key ~= member.identityKey then
            return false, identityOk and "roof refresh group return identity changed"
                or identityOrReason
        end
        local contextOk, contextOrReason = currentRoofRefreshContext(livePlayer,
            { rvId = member.rvId, generation = member.generation,
                bitmapVersion = member.bitmapVersion,
                identityKey = member.identityKey })
        if not contextOk then return false, contextOrReason end
        -- The client ACK is deliberately coordinate-free.  B42.20 may have
        -- normalized the server object to the containing square after the
        -- return command, even though the floor/z destination is correct;
        -- restore the captured float before requiring the normal GridSquare
        -- proof and releasing this member's lease.
        local authoritativeOk, authoritativePosition =
            authoritativePlayerPosition(livePlayer)
        if not authoritativeOk then return false, authoritativePosition end
        if authoritativePosition.z == ROOF_REFRESH_TEMP_Z
            or math.floor(authoritativePosition.x) ~= math.floor(member.target.x)
            or math.floor(authoritativePosition.y) ~= math.floor(member.target.y)
            or math.floor(authoritativePosition.z) ~= math.floor(member.target.z) then
            member.completed = false
            member.arrived = false
            member.arrivalConsumed = false
            return false, "roof refresh group player has not reached captured return position"
        end
        if authoritativePosition.x ~= member.target.x
            or authoritativePosition.y ~= member.target.y
            or authoritativePosition.z ~= member.target.z then
            if not applyRoofRefreshTeleport(livePlayer, member.target, false) then
                return false, "roof refresh group authoritative return reassertion failed"
            end
        end
        local atTarget, targetReason = playerAtRoofRefreshDestination(livePlayer,
            member.target)
        if not atTarget then return false, targetReason end
        authoritativeOk, authoritativePosition = authoritativePlayerPosition(livePlayer)
        if not authoritativeOk then return false, authoritativePosition end
        if authoritativePosition.z == ROOF_REFRESH_TEMP_Z
            or authoritativePosition.x ~= member.target.x
            or authoritativePosition.y ~= member.target.y
            or authoritativePosition.z ~= member.target.z then
            member.completed = false
            member.arrived = false
            member.arrivalConsumed = false
            return false, "roof refresh group player has not reached captured return position"
        end
        if not member.completed then
            if Boundary and type(Boundary.completeTransition) == "function"
                and Boundary.completeTransition(livePlayer, token) ~= true then
                return false, "roof refresh group boundary transition could not be completed"
            end
            member.returnPositionProof = {
                source = "server-authoritative-return-ack",
                identityKey = member.identityKey,
                rvId = member.rvId,
                generation = member.generation,
                bitmapVersion = member.bitmapVersion,
                token = token,
                x = authoritativePosition.x,
                y = authoritativePosition.y,
                z = authoritativePosition.z,
                acknowledgedAtTick = ctx.serverTick,
            }
            member.completed = true
        end
        if roofRefreshGroupAll(group, "completed", true)
            and not group.returnLogged then
            group.returnLogged = true
            print("[RailroaderRVTest] roof refresh group relocation returned room="
                .. tostring(group.roomKey or "unknown") .. " members="
                .. tostring(#group.members) .. " refresh=pending")
        end
        return true, contextOrReason
    end
    return false, "roof refresh return acknowledgement is stale"
end

-- Mark one existing-entry roof refresh complete after every grouped member has
-- already returned to its captured coordinate. The per-member completion bit stays
-- in the in-memory group until this idempotent completion call.
function RV.Server.completeRoofRefresh(player, token)
    local group = ctx.roofRefreshRelocationGroup
    if not group or group.phase ~= "return" then
        return false, "roof refresh group completion acknowledgement is stale"
    end
    local member = roofRefreshGroupMember(group, player, token)
    if not member or member.completed ~= true then
        return false, "roof refresh group member has not completed return"
    end
    if not roofRefreshGroupAll(group, "completed", true) then
        return false, "roof refresh group return is not complete for every member"
    end
    local resolved, livePlayerOrReason = resolveRoofRefreshGroupPlayer(
        group, member)
    if not resolved then return false, livePlayerOrReason end
    local representativeReason
    for i = 1, #group.members do
        local groupMember = group.members[i]
        local memberResolved, livePlayer = resolveRoofRefreshGroupPlayer(
            group, groupMember)
        if not memberResolved then return false, livePlayer end
        local contextOk, contextOrReason = currentRoofRefreshContext(livePlayer, {
            rvId = groupMember.rvId, generation = groupMember.generation,
            bitmapVersion = groupMember.bitmapVersion,
            identityKey = groupMember.identityKey,
        })
        if not contextOk then return false, contextOrReason end
        local proof = groupMember.returnPositionProof
        local target = groupMember.target
        local proofValid = type(proof) == "table"
            and proof.source == "server-authoritative-return-ack"
            and proof.identityKey == groupMember.identityKey
            and proof.rvId == groupMember.rvId
            and proof.generation == groupMember.generation
            and proof.bitmapVersion == groupMember.bitmapVersion
            and proof.token == groupMember.token
            and type(target) == "table"
            and proof.x == target.x and proof.y == target.y
            and proof.z == target.z
        if not proofValid then
            return false, "roof refresh member lacks authoritative return acknowledgement proof"
        end
        representativeReason = representativeReason or contextOrReason
    end
    if not roofRefreshGroupAll(group, "refreshCompleted", true) then
        for i = 1, #group.members do
            group.members[i].refreshCompleted = true
        end
    end
    ctx.roofRefreshRelocationGroup = nil
    print("[RailroaderRVTest] roof refresh group transaction complete room="
        .. tostring(group.roomKey or "unknown") .. " members="
        .. tostring(#group.members) .. " refresh=applied return=acknowledged")
    return true, representativeReason
end

function RV.Server.cancelRoofRefreshRelocation(reason)
    if ctx.roofRefreshRelocationGroup then
        failRoofRefreshRelocationGroup(reason or "roof refresh group relocation cancelled")
        return true
    end
    return false, "no roof refresh group relocation is active"
end

-- Public read-only readiness gate used by the Railroader adapter immediately
-- before each RoofRefresh.run call.  It validates current mapping identity again
-- and then checks every wall/roof/candidate square without mutating the world.
function RV.Server.roofRefreshSquaresLoaded(player, record)
    if not RoofRefresh or type(RoofRefresh.isLoaded) ~= "function" then
        return false, "roof refresh readiness service is unavailable"
    end
    if type(record) ~= "table" then return false, Constants.INVALID_RV_DATA end
    local manifestCallOk, manifestAccepted, manifest = pcall(
        RV.Server.currentRVManifestForRelocation, record.rvId,
        record.generation, record.bitmapVersion)
    if not manifestCallOk or manifestAccepted ~= true
        or type(manifest) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then return false, identityOrReason end
    local contextOk, contextOrReason = currentRoofRefreshContext(player,
        { rvId = record.rvId, generation = record.generation,
            bitmapVersion = record.bitmapVersion,
            identityKey = identityOrReason.key })
    if not contextOk then return false, contextOrReason end
    if type(record) == "table"
        and (tostring(record.rvId) ~= tostring(contextOrReason.boundary.rvId)
            or ServerUtil.integer(record.generation) ~= contextOrReason.boundary.generation
            or ServerUtil.integer(record.bitmapVersion)
                ~= contextOrReason.boundary.bitmapVersion) then
        return false, Constants.INVALID_RV_DATA
    end
    local loadedOk, loaded, reason = pcall(RoofRefresh.isLoaded, player,
        manifest.bounds)
    if not loadedOk then return false, safeErrorText(loaded) end
    return loaded == true, reason
end


end
