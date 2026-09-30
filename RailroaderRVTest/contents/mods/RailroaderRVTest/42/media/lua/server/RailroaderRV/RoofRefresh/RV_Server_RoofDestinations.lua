-- RV_Server: RoofDestinations responsibilities.
return function(ctx)
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND_RELOCATE = ctx.COMMAND_RELOCATE
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local Bitmap = ctx.Bitmap
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local function safeErrorText(...) return ctx.safeErrorText(...) end
local ROOF_REFRESH_REMOTE_OFFSET_X = ctx.ROOF_REFRESH_REMOTE_OFFSET_X
local ROOF_REFRESH_REMOTE_OFFSET_Y = ctx.ROOF_REFRESH_REMOTE_OFFSET_Y
local ROOF_REFRESH_REMOTE_OFFSET_Z = ctx.ROOF_REFRESH_REMOTE_OFFSET_Z
local ROOF_REFRESH_TEMP_Z = ctx.ROOF_REFRESH_TEMP_Z
local WORLD_MIN_Z = ctx.WORLD_MIN_Z
local WORLD_MAX_Z = ctx.WORLD_MAX_Z
local tryAuthoritativePlayerPosition = ctx.tryAuthoritativePlayerPosition
local validateAuthoritativePlayer = ctx.validateAuthoritativePlayer
local authoritativePlayerPosition = ctx.authoritativePlayerPosition
local playerIdentity = ctx.playerIdentity
local resolvePendingPlayer = ctx.resolvePendingPlayer

local function squareIsSafeForRelocation(square, countCharacters)
    if square == nil then
        return false
    end
    local floorOk, floor = ServerUtil.invoke(square, "getFloor")
    local solidOk, solid = ServerUtil.invoke(square, "TreatAsSolidFloor")
    local freeOk, free = ServerUtil.invoke(square, "isFree", countCharacters ~= false)
    if not floorOk or floor == nil or not solidOk or solid ~= true
        or not freeOk or free ~= true then
        return false
    end
    local roomOk, room = ServerUtil.invoke(square, "getRoom")
    local roomIdOk, roomId = ServerUtil.invoke(square, "getRoomID")
    if not roomOk or room ~= nil or not roomIdOk or ServerUtil.toNumber(roomId) ~= -1 then
        return false
    end
    local regionOk, region = ServerUtil.invoke(square, "getIsoWorldRegion")
    if not regionOk then
        return false
    end
    if region ~= nil then
        local playerRoomOk, playerRoom = ServerUtil.invoke(region, "isPlayerRoom")
        if not playerRoomOk or playerRoom == true then
            return false
        end
    end
    local vehicleOk, vehicle = ServerUtil.invoke(square, "getVehicleContainer")
    if not vehicleOk or vehicle ~= nil then
        return false
    end
    return true
end

local function squareHasRoofRefreshOccupant(square, allowedPlayers)
    if not square then return true end
    local collections = {
        "getObjects", "getSpecialObjects", "getStaticMovingObjects",
        "getMovingObjects", "getWorldObjects", "getDeadBodys", "getCorpses",
    }
    for i = 1, #collections do
        local collectionOk, collection = ServerUtil.invoke(square, collections[i])
        if collectionOk and collection ~= nil then
            local sizeOk, size = ServerUtil.invoke(collection, "size")
            local numericSize = ServerUtil.toNumber(size)
            if sizeOk and numericSize ~= nil and numericSize > 0 then
                if collections[i] ~= "getMovingObjects"
                    or type(allowedPlayers) ~= "table" then
                    return true
                end
                local foreign = false
                for index = 0, numericSize - 1 do
                    local itemOk, item = ServerUtil.invoke(collection, "get", index)
                    if not itemOk or item ~= nil and not allowedPlayers[item] then
                        foreign = true
                        break
                    end
                end
                if foreign then return true end
            end
            if type(collection) == "table" then
                for _, value in pairs(collection) do
                    if value ~= nil and (collections[i] ~= "getMovingObjects"
                        or type(allowedPlayers) ~= "table"
                        or not allowedPlayers[value]) then
                        return true
                    end
                end
            end
        end
    end
    local vehicleOk, vehicle = ServerUtil.invoke(square, "getVehicleContainer")
    return vehicleOk and vehicle ~= nil
end

-- The remote experiment may land on a layer without an ordinary floor. Still
-- reject any room/vehicle/object occupancy; if the engine presents a normal
-- solid floor, retain the stricter shared relocation check above.
local function roofRefreshTemporarySquareSafe(square, allowedPlayers)
    if squareIsSafeForRelocation(square, false) then return true end
    if not square or squareHasRoofRefreshOccupant(square, allowedPlayers) then
        return false
    end
    local roomOk, room = ServerUtil.invoke(square, "getRoom")
    local roomIdOk, roomId = ServerUtil.invoke(square, "getRoomID")
    if not roomOk or room ~= nil or not roomIdOk or ServerUtil.toNumber(roomId) ~= -1 then
        return false
    end
    local regionOk, region = ServerUtil.invoke(square, "getIsoWorldRegion")
    if not regionOk then return false end
    if region ~= nil then
        local playerRoomOk, playerRoom = ServerUtil.invoke(region, "isPlayerRoom")
        if not playerRoomOk or playerRoom == true then return false end
    end
    return true
end

local function relocationPositionStillSyncing(reason)
    -- teleportTo updates the client immediately, but the authoritative server
    -- player can retain its previous square for several server ticks.  These
    -- position-only failures are therefore retryable; death, identity,
    -- permission, room, and vehicle failures remain hard cancellation paths.
    return reason == "server player has not reached the relocation destination"
        or reason == "server player has no current square after relocation"
        or reason == "server player current square does not match relocation destination"
end

local function roofRefreshPosition(position, label)
    if type(position) ~= "table" then
        error("RailroaderRVTest: roof refresh " .. tostring(label)
            .. " position is unavailable")
    end
    local x = ServerUtil.requiredNumber(position.x, "roof refresh " .. tostring(label) .. " x")
    local y = ServerUtil.requiredNumber(position.y, "roof refresh " .. tostring(label) .. " y")
    local z = ServerUtil.requiredNumber(position.z, "roof refresh " .. tostring(label) .. " z")
    if z < WORLD_MIN_Z or z > WORLD_MAX_Z then
        error("RailroaderRVTest: roof refresh " .. tostring(label)
            .. " z is outside the legal world range")
    end
    -- Keep the exact finite server position in the transaction.  Bitmap and
    -- world safety callers floor this snapshot only for square membership;
    -- the return payload and teleportTo use these raw coordinates verbatim.
    return { x = x, y = y, z = z }
end

local function roofRefreshWorldCoordinateValid(destination)
    local worldOk, world = ServerUtil.callGlobal("getWorld")
    if not worldOk or not world then
        return false, "roof refresh world is unavailable"
    end
    local validOk, valid = ServerUtil.invoke(world, "isValidSquare",
        math.floor(destination.x), math.floor(destination.y),
        math.floor(destination.z))
    if not validOk or valid ~= true then
        return false, "roof refresh relocation target is outside the legal world"
    end
    return true
end

-- Read the current mapping/boundary identity from the authoritative server
-- player.  The request object is built by RV_RailroaderServer; it carries no
-- geometry.  Rechecking the current manifest
-- here keeps the generic relocation bridge safe if a generation changes between
-- the wall event and the next server tick.
local function currentRoofRefreshContext(player, request)
    local requestGeneration = type(request) == "table"
        and ServerUtil.integer(request.generation) or nil
    local requestBitmapVersion = type(request) == "table"
        and ServerUtil.integer(request.bitmapVersion) or nil
    if type(request) ~= "table"
        or tostring(request.rvId or "") == ""
        or requestGeneration == nil or requestGeneration < 1
        or requestBitmapVersion ~= Constants.BITMAP_VERSION then
        return false, Constants.INVALID_RV_DATA
   end
    if not Boundary or type(Boundary.boundaryForPlayer) ~= "function" then
        return false, "RV boundary service is unavailable"
    end
    local boundaryOk, boundary, record, relation, boundaryIdentity = pcall(
        Boundary.boundaryForPlayer, player, nil, false, false, true)
    if not boundaryOk or type(boundary) ~= "table"
        or type(record) ~= "table" or type(relation) ~= "table"
        or type(boundaryIdentity) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    if tostring(boundary.rvId) ~= tostring(request.rvId)
        or ServerUtil.integer(boundary.generation) ~= requestGeneration
        or ServerUtil.integer(boundary.bitmapVersion) ~= requestBitmapVersion
        or relation.inside ~= true
        or tostring(boundaryIdentity.key) ~= tostring(request.identityKey) then
        return false, Constants.INVALID_RV_DATA
    end
    local name = boundaryIdentity.username
    local rider = type(record.players) == "table" and record.players[name] or nil
    if type(rider) ~= "table" or rider.inside ~= true
        or ServerUtil.integer(rider.onlineId) ~= ServerUtil.integer(relation.onlineId)
        or ServerUtil.integer(rider.onlineId) ~= ServerUtil.integer(boundaryIdentity.onlineId) then
        return false, Constants.INVALID_RV_DATA
    end

    local server = RV and RV.Server
    if not server or type(server.currentRVManifestForBoundary) ~= "function"
        or type(server.currentRVRecordGeometryConsistent) ~= "function" then
        return false, Constants.INVALID_RV_DATA
    end
    local manifestCallOk, manifestAccepted, manifest = pcall(
        server.currentRVManifestForBoundary, request.rvId,
        requestGeneration, requestBitmapVersion)
    if not manifestCallOk or manifestAccepted ~= true
        or type(manifest) ~= "table"
        or tostring(manifest.rvId) ~= tostring(request.rvId)
        or ServerUtil.integer(manifest.generation) ~= requestGeneration
        or ServerUtil.integer(manifest.bitmapVersion) ~= requestBitmapVersion
        or type(manifest.boundary) ~= "table"
        or tostring(manifest.boundary.rvId) ~= tostring(request.rvId)
        or ServerUtil.integer(manifest.boundary.generation) ~= ServerUtil.integer(request.generation)
        or ServerUtil.integer(manifest.boundary.bitmapVersion) ~= ServerUtil.integer(request.bitmapVersion) then
        return false, Constants.INVALID_RV_DATA
    end
    -- All consumers share one cross-object geometry proof.  Keeping this
    -- check in RV_Server prevents the roof path, boundary guard, and
    -- stateless sentinel from each accepting a different "current" snapshot.
    local geometryService = server.currentRVRecordGeometryConsistent
    if type(geometryService) ~= "function" then
        return false, Constants.INVALID_RV_DATA
    end
    local geometryCallOk, geometryConsistent = pcall(geometryService, record,
        manifest)
    if not geometryCallOk or geometryConsistent ~= true then
        return false, Constants.INVALID_RV_DATA
    end
    -- The startup schema gate decoded and registered every persisted boundary.
    -- Runtime consumers use that validated in-memory bitmap instead of
    -- repeating the persisted bitmap schema walk on each roof request.
    local bitmap = type(Boundary.cachedBitmap) == "function"
        and Boundary.cachedBitmap(record) or nil
    if type(bitmap) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    return true, {
        boundary = boundary,
        record = record,
        relation = relation,
        identity = boundaryIdentity,
        manifest = manifest,
        bitmap = bitmap,
    }
end

local function roofRefreshDestination(context, request)
    local bitmap = context and context.bitmap
    if type(bitmap) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local phase = tostring(request.phase or "")
    if phase == "temporary" then
        local width = ServerUtil.requiredInteger(bitmap.width, "roof refresh bitmap width")
        local height = ServerUtil.requiredInteger(bitmap.height, "roof refresh bitmap height")
        local originX = ServerUtil.requiredInteger(bitmap.originX, "roof refresh bitmap originX")
        local originY = ServerUtil.requiredInteger(bitmap.originY, "roof refresh bitmap originY")
        if width ~= Constants.RV_MANAGED_WIDTH
            or height ~= Constants.RV_MANAGED_HEIGHT then
            return false, Constants.INVALID_RV_DATA
        end
        local centerZ = ServerUtil.requiredInteger(bitmap.minZ,
            "roof refresh bitmap center z")
        if centerZ < WORLD_MIN_Z or centerZ > WORLD_MAX_Z then
            return false, Constants.INVALID_RV_DATA
        end
        -- Force the RV scope to leave the loaded chunk set.  The center comes
        -- from the current validated bitmap (the same layout contract used by
        -- generation), then the current refresh vector is subtracted.  Never
        -- replace this with a fixed absolute world coordinate or a boundary
        -- edge/staging square.
        local destination = {
            x = originX + math.floor(width / 2)
                - ROOF_REFRESH_REMOTE_OFFSET_X,
            y = originY + math.floor(height / 2)
                - ROOF_REFRESH_REMOTE_OFFSET_Y,
            z = centerZ - ROOF_REFRESH_REMOTE_OFFSET_Z,
        }
        if destination.z < WORLD_MIN_Z or destination.z > WORLD_MAX_Z then
            return false, Constants.INVALID_RV_DATA
        end
        return true, destination
    end
    if phase ~= "return" then
        return false, "roof refresh relocation phase is invalid"
    end
    local destinationOk, destination = pcall(roofRefreshPosition,
        request.returnPosition, "return")
    if not destinationOk then return false, Constants.INVALID_RV_DATA end
    local x, y, z = math.floor(destination.x), math.floor(destination.y),
        math.floor(destination.z)
    if not Bitmap.containsScope(bitmap, x, y, z)
        or not Bitmap.isActive(bitmap, x, y, z) then
        return false, "roof refresh return position is not current active RV geometry"
    end
    return true, destination
end

local function playerAtRoofRefreshDestination(player, destination,
    allowMissingSquare)
    local playerOk, positionOrReason = validateAuthoritativePlayer(player)
    if not playerOk then return false, positionOrReason end
    if math.floor(positionOrReason.x) ~= math.floor(destination.x)
        or math.floor(positionOrReason.y) ~= math.floor(destination.y)
        or math.floor(positionOrReason.z) ~= math.floor(destination.z) then
        return false, "server player has not reached the roof refresh destination"
    end
    local squareOk, current = ServerUtil.invoke(player, "getCurrentSquare")
    if not squareOk or current == nil then
        if allowMissingSquare then return true end
        return false, "server player has no current square after roof refresh relocation"
    end
    local xOk, x = ServerUtil.invoke(current, "getX")
    local yOk, y = ServerUtil.invoke(current, "getY")
    local zOk, z = ServerUtil.invoke(current, "getZ")
    if not xOk or not yOk or not zOk
        or ServerUtil.toNumber(x) ~= math.floor(destination.x)
        or ServerUtil.toNumber(y) ~= math.floor(destination.y)
        or ServerUtil.toNumber(z) ~= math.floor(destination.z) then
        return false,
            "server player current square does not match roof refresh destination"
    end
    return true, current
end

-- B42.20's server-side IsoPlayer network update can floor a float teleport
-- back to the containing square on the next packet.  Roof members retain the
-- exact server-captured return coordinate, so reassert the same authoritative
-- values through the official setters after every grouped move.  The client
-- ACK remains token-only; these setters are server-owned and are followed by
-- the normal position/current-square proof.
local function applyRoofRefreshTeleport(player, target, temporary)
    if type(target) ~= "table"
        or type(target.x) ~= "number" or type(target.y) ~= "number"
        or type(target.z) ~= "number" then
        return false
    end
    local x = temporary and target.x + 0.5 or target.x
    local y = temporary and target.y + 0.5 or target.y
    return RV and RV.Server
        and RV.Server.teleportToPosition(player, { x = x, y = y, z = target.z }) == true
        and ServerUtil.callSucceeded(player, "setX", x)
        and ServerUtil.callSucceeded(player, "setY", y)
        and ServerUtil.callSucceeded(player, "setZ", target.z)
        and ServerUtil.callSucceeded(player, "setLastX", x)
        and ServerUtil.callSucceeded(player, "setLastY", y)
end

local function roofRefreshTargetReady(player, destination, phase, allowedPlayers)
    -- Both grouped phases can cross a chunk boundary.  On the return hop the
    -- original RV chunk may still be streaming, so the server may have the
    -- exact authoritative x/y/z and a valid token ACK before its current
    -- square is rebound.  Keep the group lease in force; the later
    -- completeRoofRefreshRelocation/roofRefreshSquaresLoaded gates still require
    -- the normal loaded-square proof before the roof refresh is released.
    local allowMissingSquare = type(allowedPlayers) == "table"
    local atDestination, destinationReason = playerAtRoofRefreshDestination(
        player, destination, allowMissingSquare)
    if not atDestination then return false, destinationReason end
    if phase ~= "temporary" then return true end
    -- A grouped roof refresh intentionally targets the current-schema center
    -- minus the remote vector.  That legal server coordinate can be in an
    -- unloaded/empty layer, so a missing GridSquare is not evidence that the
    -- authoritative teleport failed.  The bounded adapter wait still keeps
    -- this phase across multiple ticks before return is armed.
    if allowMissingSquare then
        local cellOk, cell = pcall(ServerWorld.getCellForPlayer, player)
        if not cellOk or not cell then return true end
        local square = ServerWorld.getSquare(cell, math.floor(destination.x),
            math.floor(destination.y), math.floor(destination.z))
        if not square then return true end
        if not roofRefreshTemporarySquareSafe(square, allowedPlayers) then
            return false, "roof refresh temporary destination is still room geometry"
        end
        return true
    end
    local cellOk, cell = pcall(ServerWorld.getCellForPlayer, player)
    if not cellOk or not cell then
        return false, "roof refresh temporary destination cell is not loaded"
    end
    local square = ServerWorld.getSquare(cell, math.floor(destination.x),
        math.floor(destination.y), math.floor(destination.z))
    if not square then
        return false, "roof refresh temporary destination square is not loaded"
    end
    -- The temporary move is only considered complete after the player has left
    -- the dynamic room geometry.  A wall-removal callback can arrive before
    -- IsoRegions has retired the old room, so this remains a retryable status
    -- until the bounded relocation timeout expires.
    if not roofRefreshTemporarySquareSafe(square, allowedPlayers) then
        return false, "roof refresh temporary destination is still room geometry"
    end
    return true
end

local function copyRoofRefreshPosition(position)
    if type(position) ~= "table" then return nil end
    local x, y, z = ServerUtil.toNumber(position.x), ServerUtil.toNumber(position.y),
        ServerUtil.toNumber(position.z)
    if not ServerUtil.isFiniteNumber(x) or not ServerUtil.isFiniteNumber(y)
        or not ServerUtil.isFiniteNumber(z) then return nil end
    if z < WORLD_MIN_Z or z > WORLD_MAX_Z then return nil end
    return { x = x, y = y, z = z }
end

-- Validate the server-captured return square immediately before every final
-- return attempt.  No client coordinate is accepted and no old mapping or
-- geometry can be used as a fallback.  This gate deliberately re-reads the
-- current boundary/manifest identity so a stale transaction fails closed.
local function validatedRoofRefreshReturn(pending)
    if type(pending) ~= "table" or not pending.player
        or not pending.identity then
        return false, Constants.INVALID_RV_DATA
    end
    local resolved, livePlayerOrReason = resolvePendingPlayer(pending)
    if not resolved then return false, livePlayerOrReason end
    local livePlayer = livePlayerOrReason
    local identityOk, identityOrReason = playerIdentity(livePlayer)
    if not identityOk or identityOrReason.key ~= pending.identity.key then
        return false, identityOk and "roof refresh return identity changed"
            or identityOrReason
    end
    local contextOk, contextOrReason = currentRoofRefreshContext(livePlayer,
        { rvId = pending.rvId, generation = pending.generation,
            bitmapVersion = pending.bitmapVersion,
            identityKey = identityOrReason.key })
    if not contextOk then return false, contextOrReason end
    local returnPosition = copyRoofRefreshPosition(pending.returnPosition)
    if not returnPosition then return false, Constants.INVALID_RV_DATA end
    local returnX, returnY, returnZ = math.floor(returnPosition.x),
        math.floor(returnPosition.y), math.floor(returnPosition.z)
    if not Bitmap.containsScope(contextOrReason.bitmap, returnX, returnY,
        returnZ)
        or not Bitmap.isActive(contextOrReason.bitmap, returnX, returnY,
            returnZ) then
        return false, "roof refresh return position is not current active RV geometry"
    end
    return true, {
        identity = identityOrReason,
        context = contextOrReason,
        position = returnPosition,
    }
end

-- Roll a temporary roof relocation back to the server-captured inside
-- position.  This path is used for timeout, disconnect/death and identity or
-- schema changes.  It never edits ModData or world objects.  The client gets
-- the same server-authored RVTeleport bridge used by normal entry/exit, while
-- the authoritative server object is moved first/alongside it.
local function rollbackRoofRefreshRelocation(pending)
    if type(pending) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local targetOk, targetOrReason = validatedRoofRefreshReturn(pending)
    if not targetOk then
        print("[RailroaderRVTest] roof refresh rollback refused room="
            .. tostring(pending.roomKey or "unknown") .. " reason="
            .. safeErrorText(targetOrReason))
        return false, targetOrReason
    end
    local player = pending.player
    if not player then return false, Constants.INVALID_RV_DATA end
    local returnPosition = targetOrReason.position
    local identity = targetOrReason.identity
    local liveCallOk, livePositionOrReason =
        tryAuthoritativePlayerPosition(player)
    if not liveCallOk or type(livePositionOrReason) ~= "table" then
        local reason = livePositionOrReason
        print("[RailroaderRVTest] roof refresh rollback refused room="
            .. tostring(pending.roomKey or "unknown") .. " reason="
            .. safeErrorText(reason) .. " return="
            .. tostring(returnPosition.x) .. "," .. tostring(returnPosition.y)
            .. "," .. tostring(returnPosition.z))
        return false, reason
    end
    local worldOk, worldReason = roofRefreshWorldCoordinateValid(returnPosition)
    if not worldOk then
        print("[RailroaderRVTest] roof refresh rollback refused room="
            .. tostring(pending.roomKey or "unknown") .. " reason="
            .. safeErrorText(worldReason) .. " return=" .. tostring(returnPosition.x)
            .. "," .. tostring(returnPosition.y) .. ","
            .. tostring(returnPosition.z))
        return false, worldReason
    end

    local payload = {
        ok = true,
        action = "roof-refresh-cancel",
        token = pending.token,
        onlineId = identity.onlineId,
        rvId = tostring(pending.rvId),
        generation = ServerUtil.integer(pending.generation),
        bitmapVersion = ServerUtil.integer(pending.bitmapVersion),
        x = returnPosition.x, y = returnPosition.y, z = returnPosition.z,
        roofRepairTransition = true,
        roofRepairPhase = "return",
    }
    local sentOk = ServerUtil.callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_RELOCATE, payload)
    local moved = applyRoofRefreshTeleport(player, returnPosition, false)
    -- A successful teleport call is not enough: the authoritative object must
    -- have actually left the remote z=-15 target and be back on the exact
    -- server-captured active square before the lease/context may be retired.
    local positionOk, currentPosition = authoritativePlayerPosition(player)
    local atCapturedReturn = positionOk
        and currentPosition.z ~= ROOF_REFRESH_TEMP_Z
        and currentPosition.x == returnPosition.x
        and currentPosition.y == returnPosition.y
        and currentPosition.z == returnPosition.z
    local leaseComplete = false
    if sentOk and moved and atCapturedReturn
        and Boundary and type(Boundary.completeTransition) == "function"
        and type(pending.token) == "string" then
        local completeOk, completeResult = pcall(
            Boundary.completeTransition, player, pending.token)
        leaseComplete = completeOk and completeResult == true
    end
    -- Never clear a live correction lease while the authoritative player is
    -- still underground or the client/server return handshake is incomplete.
    -- The bounded/async final-return owner retries this same current-schema
    -- context instead of stranding the player after a finite retry budget.
    local rolledBack = sentOk and moved and atCapturedReturn and leaseComplete
    print("[RailroaderRVTest] roof refresh rollback room="
        .. tostring(pending.roomKey or "unknown") .. " result="
        .. (rolledBack and "complete" or "failed") .. " current="
        .. tostring(livePositionOrReason.x) .. "," .. tostring(livePositionOrReason.y) .. ","
        .. tostring(livePositionOrReason.z) .. " return=" .. tostring(returnPosition.x)
        .. "," .. tostring(returnPosition.y) .. ","
        .. tostring(returnPosition.z))
    if rolledBack then return true end
    if currentPosition and currentPosition.z == ROOF_REFRESH_TEMP_Z then
        return false, "roof refresh player remains at temporary z=-15"
    end
    if not atCapturedReturn then
        return false, "roof refresh player has not reached the captured return square"
    end
    if not leaseComplete then
        return false, "roof refresh boundary transition could not be completed"
    end
    return false, "roof refresh return command or authoritative teleport failed"
end


ctx.relocationPositionStillSyncing = relocationPositionStillSyncing
ctx.roofRefreshPosition = roofRefreshPosition
ctx.roofRefreshWorldCoordinateValid = roofRefreshWorldCoordinateValid
ctx.currentRoofRefreshContext = currentRoofRefreshContext
ctx.roofRefreshDestination = roofRefreshDestination
ctx.playerAtRoofRefreshDestination = playerAtRoofRefreshDestination
ctx.applyRoofRefreshTeleport = applyRoofRefreshTeleport
ctx.roofRefreshTargetReady = roofRefreshTargetReady
ctx.copyRoofRefreshPosition = copyRoofRefreshPosition
ctx.rollbackRoofRefreshRelocation = rollbackRoofRefreshRelocation
end
