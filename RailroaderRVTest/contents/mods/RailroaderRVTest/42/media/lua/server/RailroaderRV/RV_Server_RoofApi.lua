-- RV_Server: RoofApi responsibilities.
return function(ctx)
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local RoofRepair = ctx.RoofRepair
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local function safeErrorText(...) return ctx.safeErrorText(...) end
local function requireCurrentManifest(...) return ctx.requireCurrentManifest(...) end
local ROOF_REPAIR_TEMP_Z = ctx.ROOF_REPAIR_TEMP_Z
local manifestTable = ctx.manifestTable
local resolveRoofRepairGroupPlayer = ctx.resolveRoofRepairGroupPlayer
local authoritativePlayerPosition = ctx.authoritativePlayerPosition
local playerIdentity = ctx.playerIdentity
local relocationPositionsEqual = ctx.relocationPositionsEqual
local currentRoofRepairContext = ctx.currentRoofRepairContext
local playerAtRoofRepairDestination = ctx.playerAtRoofRepairDestination
local applyRoofRepairTeleport = ctx.applyRoofRepairTeleport
local roofRepairGroupMatches = ctx.roofRepairGroupMatches
local roofRepairGroupMember = ctx.roofRepairGroupMember
local roofRepairGroupAll = ctx.roofRepairGroupAll
local failRoofRepairRelocationGroup = ctx.failRoofRepairRelocationGroup

function RV.Server.consumeRoofRepairRelocationArrival(player)
    local member = roofRepairGroupMember(ctx.roofRepairRelocationGroup, player)
    if not member or not member.arrived or member.arrivalConsumed then
        return nil
    end
    local resolved, current = resolveRoofRepairGroupPlayer(
        ctx.roofRepairRelocationGroup, member)
    if not resolved then return nil end
    member.arrivalConsumed = true
    return member
end

function RV.Server.roofRepairRelocationGroupReady(rvId, generation,
    bitmapVersion)
    local group = ctx.roofRepairRelocationGroup
    return roofRepairGroupMatches(group, rvId, generation, bitmapVersion)
        and group.phase == "temporary"
        and roofRepairGroupAll(group, "arrived", true)
end

-- Cross-module mutex queries.  These expose only live process state; no
-- relocation ledger or save field is involved.  A roof group remains busy
-- through temporary, return, repair and its final-return retry object so the
-- adapter cannot mutate the same RV while its captured members are returning.
function RV.Server.isGenerationTransactionActive()
    return ctx.pendingGeneration ~= nil or ctx.transactionBusy
end

function RV.Server.isRoofRepairTransactionActive(_rvId)
    -- This is a service-wide mutex query.  The optional rvId is retained in
    -- the signature for callers that want to keep their diagnostic context,
    -- but an active roof transaction must never be bypassed by naming another
    -- RV in the same managed world scope.
    local function busyGroup(group)
        if group == nil then return false end
        if type(group) ~= "table" then
            return true, "roof repair transaction state is unavailable"
        end
        if type(group.rvId) ~= "string" or group.rvId == "" then
            return true, "roof repair transaction state is unavailable"
        end
        return true, "roof repair refresh is in progress (rvId="
            .. tostring(group.rvId) .. ")"
    end
    local active, reason = busyGroup(ctx.roofRepairRelocationGroup)
    if active then return true, reason end
    if ctx.roofRepairGroupFinalReturn ~= nil
        and type(ctx.roofRepairGroupFinalReturn) ~= "table" then
        return true, "roof repair transaction state is unavailable"
    end
    local finalReturn = ctx.roofRepairGroupFinalReturn
        and ctx.roofRepairGroupFinalReturn.group or nil
    if ctx.roofRepairGroupFinalReturn ~= nil and type(finalReturn) ~= "table" then
        return true, "roof repair transaction state is unavailable"
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
    if ctx.pendingGeneration ~= nil then
        if type(ctx.pendingGeneration) ~= "table"
            or type(ctx.pendingGeneration.identity) ~= "table"
            or type(ctx.pendingGeneration.identity.key) ~= "string"
            or ctx.pendingGeneration.identity.key == "" then
            return nil
        end
        return ctx.pendingGeneration.identity.key == identityKey
    end
    local activeClaims = groupClaims(ctx.roofRepairRelocationGroup)
    if activeClaims ~= false then return activeClaims end
    if ctx.roofRepairGroupFinalReturn ~= nil
        and (type(ctx.roofRepairGroupFinalReturn) ~= "table"
            or type(ctx.roofRepairGroupFinalReturn.group) ~= "table") then
        return nil
    end
    local finalGroup = ctx.roofRepairGroupFinalReturn
        and ctx.roofRepairGroupFinalReturn.group or nil
    local finalClaims = groupClaims(finalGroup)
    if finalClaims ~= false then return finalClaims end
    return false
end

function RV.Server.getRoofRepairRelocationState(rvId, generation,
    bitmapVersion, token)
    if roofRepairGroupMatches(ctx.roofRepairRelocationGroup, rvId, generation,
        bitmapVersion) then
        return "active", ctx.roofRepairRelocationGroup.phase
    end
    if ctx.roofRepairGroupFailure
        and roofRepairGroupMatches(ctx.roofRepairGroupFailure, rvId, generation,
            bitmapVersion)
        and type(token) == "string"
        and token ~= ""
        and ctx.roofRepairGroupFailure.token == token then
        return "failed", ctx.roofRepairGroupFailure.reason
    end
    return "idle"
end

function RV.Server.consumeRoofRepairRelocationFailure(rvId, generation,
    bitmapVersion, token)
    if ctx.roofRepairGroupFailure
        and roofRepairGroupMatches(ctx.roofRepairGroupFailure, rvId, generation,
            bitmapVersion)
        and type(token) == "string"
        and token ~= ""
        and ctx.roofRepairGroupFailure.token == token then
        local failure = ctx.roofRepairGroupFailure
        ctx.roofRepairGroupFailure = nil
        return failure.reason
    end
    return nil
end

function RV.Server.completeRoofRepairRelocation(player, token)
    if ctx.roofRepairRelocationGroup then
        local group = ctx.roofRepairRelocationGroup
        local member = roofRepairGroupMember(group, player, token)
        if not member or group.phase ~= "return" then
            return false, "roof repair group return acknowledgement is stale"
        end
        local resolved, livePlayerOrReason = resolveRoofRepairGroupPlayer(
            group, member)
        if not resolved then
            return false, livePlayerOrReason
        end
        local livePlayer = livePlayerOrReason
        local identityOk, identityOrReason = playerIdentity(livePlayer)
        if not identityOk or identityOrReason.key ~= member.identityKey then
            return false, identityOk and "roof repair group return identity changed"
                or identityOrReason
        end
        local contextOk, contextOrReason = currentRoofRepairContext(livePlayer,
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
        if authoritativePosition.z == ROOF_REPAIR_TEMP_Z
            or math.floor(authoritativePosition.x) ~= math.floor(member.target.x)
            or math.floor(authoritativePosition.y) ~= math.floor(member.target.y)
            or math.floor(authoritativePosition.z) ~= math.floor(member.target.z) then
            member.completed = false
            member.arrived = false
            member.arrivalConsumed = false
            return false, "roof repair group player has not reached captured return position"
        end
        if authoritativePosition.x ~= member.target.x
            or authoritativePosition.y ~= member.target.y
            or authoritativePosition.z ~= member.target.z then
            if not applyRoofRepairTeleport(livePlayer, member.target, false) then
                return false, "roof repair group authoritative return reassertion failed"
            end
        end
        local atTarget, targetReason = playerAtRoofRepairDestination(livePlayer,
            member.target)
        if not atTarget then return false, targetReason end
        authoritativeOk, authoritativePosition = authoritativePlayerPosition(livePlayer)
        if not authoritativeOk then return false, authoritativePosition end
        if authoritativePosition.z == ROOF_REPAIR_TEMP_Z
            or authoritativePosition.x ~= member.target.x
            or authoritativePosition.y ~= member.target.y
            or authoritativePosition.z ~= member.target.z then
            member.completed = false
            member.arrived = false
            member.arrivalConsumed = false
            return false, "roof repair group player has not reached captured return position"
        end
        if not member.completed then
            if Boundary and type(Boundary.completeTransition) == "function"
                and Boundary.completeTransition(livePlayer, token) ~= true then
                return false, "roof repair group boundary transition could not be completed"
            end
            member.completed = true
        end
        if roofRepairGroupAll(group, "completed", true)
            and not group.returnLogged then
            group.returnLogged = true
            print("[RailroaderRVTest] roof repair group relocation returned room="
                .. tostring(group.roomKey or "unknown") .. " members="
                .. tostring(#group.members) .. " repair=pending")
        end
        return true, contextOrReason
    end
    return false, "roof repair return acknowledgement is stale"
end

-- Mark one existing-entry roof repair complete after every grouped member has
-- already returned to its captured coordinate. The per-member repair bit stays
-- in the in-memory group until this idempotent completion call.
function RV.Server.completeRoofRepairRepair(player, token)
    local group = ctx.roofRepairRelocationGroup
    if not group or group.phase ~= "return" then
        return false, "roof repair group repair acknowledgement is stale"
    end
    local member = roofRepairGroupMember(group, player, token)
    if not member or member.completed ~= true then
        return false, "roof repair group member has not completed return"
    end
    if not roofRepairGroupAll(group, "completed", true) then
        return false, "roof repair group return is not complete for every member"
    end
    local resolved, livePlayerOrReason = resolveRoofRepairGroupPlayer(
        group, member)
    if not resolved then return false, livePlayerOrReason end
    local representativeReason
    for i = 1, #group.members do
        local groupMember = group.members[i]
        local memberResolved, livePlayer = resolveRoofRepairGroupPlayer(
            group, groupMember)
        if not memberResolved then return false, livePlayer end
        local contextOk, contextOrReason = currentRoofRepairContext(livePlayer, {
            rvId = groupMember.rvId, generation = groupMember.generation,
            bitmapVersion = groupMember.bitmapVersion,
            identityKey = groupMember.identityKey,
        })
        if not contextOk then return false, contextOrReason end
        local positionOk, position = authoritativePlayerPosition(livePlayer)
        if not positionOk or not relocationPositionsEqual(position,
            groupMember.originalPosition) then
            return false, "roof repair member return coordinate is not authoritative"
        end
        representativeReason = representativeReason or contextOrReason
    end
    if not roofRepairGroupAll(group, "repairCompleted", true) then
        for i = 1, #group.members do
            group.members[i].repairCompleted = true
        end
    end
    ctx.roofRepairRelocationGroup = nil
    print("[RailroaderRVTest] roof repair group transaction complete room="
        .. tostring(group.roomKey or "unknown") .. " members="
        .. tostring(#group.members) .. " repair=applied return=acknowledged")
    return true, representativeReason
end

function RV.Server.cancelRoofRepairRelocation(reason)
    if ctx.roofRepairRelocationGroup then
        failRoofRepairRelocationGroup(reason or "roof repair group relocation cancelled")
        return true
    end
    return false, "no roof repair group relocation is active"
end

-- Public read-only readiness gate used by the Railroader adapter immediately
-- before each RoofRepair.run call.  It validates current mapping identity again
-- and then checks every wall/roof/candidate square without mutating the world.
function RV.Server.roofRepairSquaresLoaded(player, record)
    if not RoofRepair or type(RoofRepair.isLoaded) ~= "function" then
        return false, "roof repair readiness service is unavailable"
    end
    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local manifest = manifestOrError
    local schemaOk = pcall(requireCurrentManifest, manifest, false)
    if not schemaOk then return false, Constants.SAVE_REBUILD_REQUIRED end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then return false, identityOrReason end
    local contextOk, contextOrReason = currentRoofRepairContext(player,
        { rvId = manifest.rvId, generation = manifest.generation,
            bitmapVersion = manifest.bitmapVersion,
            identityKey = identityOrReason.key })
    if not contextOk then return false, contextOrReason end
    if type(record) == "table"
        and (tostring(record.rvId) ~= tostring(contextOrReason.boundary.rvId)
            or ServerUtil.integer(record.generation) ~= contextOrReason.boundary.generation
            or ServerUtil.integer(record.bitmapVersion)
                ~= contextOrReason.boundary.bitmapVersion) then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local loadedOk, loaded, reason = pcall(RoofRepair.isLoaded, player,
        manifest.bounds)
    if not loadedOk then return false, safeErrorText(loaded) end
    return loaded == true, reason
end


end
