-- RV_RailroaderServer: Sentinel responsibilities.
return function(ctx)
local RemovalTrace = require("RailroaderRV/RV_Server_ObjectRemovalTrace")
local Boundary = ctx.Boundary
local Bitmap = ctx.Bitmap
local Adapter = ctx.Adapter
local C = ctx.C
local pendingWallRoofRepairs = ctx.pendingWallRoofRepairs
local followUpWallRemovalEvents = ctx.followUpWallRemovalEvents
local RELOCATION_SENTINEL_Z = ctx.RELOCATION_SENTINEL_Z
local ROOF_REPAIR_REMOTE_OFFSET_X = ctx.ROOF_REPAIR_REMOTE_OFFSET_X
local ROOF_REPAIR_REMOTE_OFFSET_Y = ctx.ROOF_REPAIR_REMOTE_OFFSET_Y
local ROOF_REPAIR_REMOTE_OFFSET_Z = ctx.ROOF_REPAIR_REMOTE_OFFSET_Z
local relocationSentinelWarnings = ctx.relocationSentinelWarnings
local function roofRepairOwnsPlayer(...) return ctx.roofRepairOwnsPlayer(...) end
local function roofRepairTransactionBlocks(...) return ctx.roofRepairTransactionBlocks(...) end
local function currentGeometryGate(...) return ctx.currentGeometryGate(...) end
local function serverTransactionMutexStatus(...) return ctx.serverTransactionMutexStatus(...) end
local integer = ctx.integer
local call = ctx.call
local callGlobal = ctx.callGlobal
local playerId = ctx.playerId
local playerName = ctx.playerName
local playerPosition = ctx.playerPosition
local copyPosition = ctx.copyPosition
local newTransitionToken = ctx.newTransitionToken
local usableCoordinate = ctx.usableCoordinate
local validMapRelation = ctx.validMapRelation
local validRecord = ctx.validRecord
local armRoomOwnershipMonitor = ctx.armRoomOwnershipMonitor
local sendResult = ctx.sendResult
local movePlayer = ctx.movePlayer
local enterPlayer = ctx.enterPlayer
local exitPlayer = ctx.exitPlayer

local function commandArgument(args, key)
    if args == nil then return nil end
    if type(args) == "table" then return args[key] end
    local ok, value = call(args, "get", key)
    return ok and value or nil
end

function Adapter.OnClientCommand(module, command, player, args)
    if module ~= C.MOD_ID then return end
    if command ~= C.COMMAND_RV_ENTER and command ~= C.COMMAND_RV_EXIT then return end
    -- The roof/generation identity gate may reject before pcall is entered.
    -- Treat that branch as an intentional handled result; otherwise the
    -- uninitialised `ok` below overwrites its real reason with `false`, which
    -- renders as the misleading "unknown reason" to the client.
    local ok, result, reason = true, nil, nil
    if roofRepairOwnsPlayer(player) then
        result, reason = false, "roof repair refresh is in progress"
    elseif command == C.COMMAND_RV_ENTER then
        local locoId = commandArgument(args, "locoId")
        if locoId == nil then
            result, reason = false, "locomotive id is missing"
        else
            ok, result, reason = pcall(enterPlayer, player, locoId)
        end
    else
        ok, result, reason = pcall(exitPlayer, player)
    end
    if not ok then result, reason = false, result end
    RemovalTrace.lifecycle("request",
        command == C.COMMAND_RV_ENTER and "EnterRV" or "ExitRV",
        result == true and "accepted" or "rejected", ctx.serverTick)
    if result ~= true then
        print("[RailroaderRVTest] Railroader RV command rejected: "
            .. tostring(reason or "unknown reason"))
        sendResult(player, false, reason or "request rejected")
    end
end

local function onlinePlayersSnapshot()
    local result, seen = {}, {}
    local ok, players = callGlobal("getOnlinePlayers")
    if ok and players then
        local sizeOk, size = call(players, "size")
        local count = integer(size)
        if sizeOk and count and count >= 0 then
            for index = 0, count - 1 do
                local playerOk, player = call(players, "get", index)
                if playerOk and player and not seen[player] then
                    seen[player] = true
                    result[#result + 1] = player
                end
            end
        elseif type(players) == "table" then
            for _, player in pairs(players) do
                if player and not seen[player] then
                    seen[player] = true
                    result[#result + 1] = player
                end
            end
        end
    end
    -- Single-player/co-op fallback when getOnlinePlayers is not exposed in the
    -- active Lua pass.  The server-side command path remains authoritative.
    if #result == 0 then
        local playerOk, player = callGlobal("getPlayer")
        if player then result[1] = player end
    end
    return result
end

-- Rebuild the client-side utility affordance after a reconnect from the
-- authoritative player identity and current persisted mapping.  This is only
-- a candidate hint: the utility command path calls resolveCurrentUtilityRV
-- again, so a stale client hint cannot grant access or select an RV.
function Adapter.onlinePlayersSnapshot()
    return onlinePlayersSnapshot()
end

function Adapter.syncUtilityMapping(player)
    local accepted, context = Adapter.resolveCurrentUtilityRV(player)
    if accepted ~= true or type(context) ~= "table"
        or type(context.identity) ~= "table"
        or type(context.record) ~= "table" then
        return false
    end
    local onlineId = playerId(player)
    local identity = context.identity
    local record = context.record
    if onlineId == nil or type(identity.rvId) ~= "string"
        or identity.rvId == "" or integer(identity.generation) == nil
        or integer(identity.bitmapVersion) ~= C.BITMAP_VERSION
        or record.locoId == nil then
        return false
    end
    local payload = {
        ok = true,
        onlineId = onlineId,
        rvId = tostring(identity.rvId),
        locoId = tostring(record.locoId),
        generation = integer(identity.generation),
        bitmapVersion = integer(identity.bitmapVersion),
        mapSchemaVersion = C.MAP_SCHEMA_VERSION,
    }
    local sentOk, sent = callGlobal("sendServerCommand", player, C.MOD_ID,
        C.COMMAND_RV_UTILITY_MAPPING, payload)
    return sentOk and sent ~= false, identity
end

local function resolveSavedPlayer(saved)
    if type(saved) ~= "table" or type(saved.identityKey) ~= "string"
        or saved.identityKey == "" then
        return false
    end
    local players = onlinePlayersSnapshot()
    for i = 1, #players do
        local player = players[i]
        local id, name = playerId(player), playerName(player)
        if id ~= nil and name ~= nil
            and tostring(id) .. ":" .. tostring(name) == saved.identityKey then
            saved.player = player
            return true
        end
    end
    return false
end

local function sentinelIdentity(player)
    local id, name = playerId(player), playerName(player)
    if id == nil or name == nil then return nil, nil, nil end
    return tostring(id) .. ":" .. tostring(name), id, name
end

local function queuedRoofRepairClaims(identityKey)
    if type(identityKey) ~= "string" or identityKey == "" then return false end
    for _, pending in pairs(pendingWallRoofRepairs) do
        if type(pending) == "table"
            and pending.relocationPhase ~= "complete" then
            if pending.identityKey == identityKey then return true end
            for _, saved in pairs(pending.players or {}) do
                if type(saved) == "table"
                    and saved.identityKey == identityKey then
                    return true
                end
            end
        end
    end
    return false
end

local function sentinelClaimState(server, identityKey)
    if queuedRoofRepairClaims(identityKey) then return true end
    if not server or type(server.isRelocationIdentityClaimed) ~= "function" then
        return nil
    end
    local ok, claimed = pcall(server.isRelocationIdentityClaimed, identityKey)
    if not ok or type(claimed) ~= "boolean" then return nil end
    return claimed
end

-- Enter/Exit and the sentinel use the same narrow stable-identity claim
-- query.  A queued grouped wall refresh owns every member identity in its
-- saved descriptor list, even when the original userdata has been replaced.
roofRepairOwnsPlayer = function(player)
    local identityKey = sentinelIdentity(player)
    if not identityKey then return false end
    -- isRelocationIdentityClaimed also reports the generation owner.  That
    -- shared claim must not be labelled as a roof repair: the actual mutex
    -- check below will return the generation-specific rejection reason.
    if not queuedRoofRepairClaims(identityKey) then
        local server = RailroaderRV and RailroaderRV.Server
        if not server or type(server.isRoofRepairTransactionActive) ~= "function" then
            return false
        end
        local roofCallOk, roofActive = pcall(
            server.isRoofRepairTransactionActive, nil)
        if not roofCallOk or roofActive ~= true then
            return false
        end
    end
    local server = RailroaderRV and RailroaderRV.Server
    return sentinelClaimState(server, identityKey) == true
end

-- Read both halves of the service-wide transaction mutex before any adapter
-- path changes a seat, mapping, boundary lease or player position.  The roof
-- query deliberately receives no RV filter: one managed world scope cannot
-- safely run a second Enter/Exit or generation for another rvId.
serverTransactionMutexStatus = function()
    local server = RailroaderRV and RailroaderRV.Server
    if not server
        or type(server.isGenerationTransactionActive) ~= "function"
        or type(server.isRoofRepairTransactionActive) ~= "function" then
        return nil, nil, "transaction gate is unavailable"
    end
    local generationCallOk, generationActive = pcall(
        server.isGenerationTransactionActive)
    local roofCallOk, roofActive, roofReason = pcall(
        server.isRoofRepairTransactionActive, nil)
    if not generationCallOk or type(generationActive) ~= "boolean"
        or not roofCallOk or type(roofActive) ~= "boolean" then
        return nil, nil, C.INVALID_RV_DATA
    end
    return generationActive, roofActive, roofReason
end

-- Enter/Exit must honor the same server-owned roof mutex for every player in
-- the affected RV, not only the members captured by the grouped relocation.
-- A queued wall event is also held here: its member snapshot is already an
-- accepted operation and must not race a new mapping/geometry mutation.
roofRepairTransactionBlocks = function(rvId)
    local generationBusy, roofBusy, mutexReason =
        serverTransactionMutexStatus()
    if generationBusy == nil then
        return true, mutexReason
    end
    if generationBusy then
        return true, "RV generation transaction is in progress"
    end
    if roofBusy then
        return true, type(mutexReason) == "string" and mutexReason ~= ""
            and mutexReason or "roof repair refresh is in progress"
    end
    for _, pending in pairs(pendingWallRoofRepairs) do
        if type(pending) ~= "table" then
            return true, C.INVALID_RV_DATA
        end
        if pending.relocationPhase ~= "complete" then
            return true, "roof repair refresh is in progress (rvId="
                .. tostring(pending.rvId or "unknown") .. ")"
        end
    end
    for _, events in pairs(followUpWallRemovalEvents) do
        if type(events) ~= "table" then
            return true, C.INVALID_RV_DATA
        end
        for _, event in pairs(events) do
            if type(event) ~= "table" then
                return true, C.INVALID_RV_DATA
            end
            local expiresAt = integer(event.expiresAtTick)
            if expiresAt == nil then return true, C.INVALID_RV_DATA end
            if expiresAt >= (Adapter._ticks or 0) then
                return true, "roof repair refresh is in progress (rvId="
                    .. tostring(event.rvId or "unknown") .. ")"
            end
        end
    end
    return false
end

-- Enter/Exit must prove that the mapping record and the current persisted
-- manifest still describe one complete geometry before arming a boundary,
-- changing map.players/record.players, or sending a teleport.  The server
-- hook is intentionally mandatory; no shallow adapter fallback is safe.
currentGeometryGate = function(record)
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.validateCurrentRVRecord) ~= "function" then
        return false, C.INVALID_RV_DATA
    end
    local callOk, accepted = pcall(server.validateCurrentRVRecord, record)
    if not callOk or accepted ~= true then
        return false, C.INVALID_RV_DATA
    end
    return true
end

local function sentinelWarn(identityKey, reason)
    if type(reason) ~= "string" or reason == "" then
        reason = C.INVALID_RV_DATA
    end
    if relocationSentinelWarnings[identityKey] == reason then return end
    relocationSentinelWarnings[identityKey] = reason
    print("[RailroaderRVTest] relocation sentinel refused identity="
        .. tostring(identityKey) .. " reason=" .. reason)
end

local function sentinelRelationsConsistent(map, record)
    if type(map) ~= "table" or type(record) ~= "table"
        or type(map.players) ~= "table" or type(record.players) ~= "table" then
        return false
    end
    local wanted = tostring(record.rvId or record.locoId or "")
    if wanted == "" then return false end
    for name, rider in pairs(record.players) do
        if type(name) ~= "string" or not validMapRelation(rider, false) then
            return false
        end
        local relation = map.players[name]
        if rider.inside == true then
            if type(relation) ~= "table" or relation.inside ~= true
                or tostring(relation.locoId) ~= wanted
                or integer(relation.onlineId) ~= integer(rider.onlineId) then
                return false
            end
        elseif type(relation) == "table" and relation.inside == true
            and tostring(relation.locoId) == wanted then
            return false
        end
    end
    for name, relation in pairs(map.players) do
        if type(relation) ~= "table" or not validMapRelation(relation, true) then
            return false
        end
        if relation.inside == true and tostring(relation.locoId) == wanted then
            local rider = record.players[name]
            if type(rider) ~= "table" or rider.inside ~= true
                or integer(rider.onlineId) ~= integer(relation.onlineId) then
                return false
            end
        end
    end
    return true
end

local function sentinelBitmapAndCenter(record)
    if type(record) ~= "table" or type(record.managed) ~= "table"
        or type(record.boundary) ~= "table"
        or type(record.boundary.bitmap) ~= "table" or not Bitmap then
        return false, C.INVALID_RV_DATA
    end
    local managed = record.managed
    local originX, originY = integer(managed.originX), integer(managed.originY)
    local width, height = integer(managed.width), integer(managed.height)
    local minZ, maxZ = integer(managed.minZ), integer(managed.maxZ)
    if originX == nil or originY == nil or width ~= integer(C.RV_MANAGED_WIDTH)
        or height ~= integer(C.RV_MANAGED_HEIGHT) or minZ == nil or maxZ == nil
        or maxZ <= minZ then
        return false, C.INVALID_RV_DATA
    end
    local decodeOk, bitmap = pcall(Bitmap.decode, record.boundary.bitmap)
    local bitmapValidOk, bitmapValid = false, false
    if decodeOk and type(bitmap) == "table"
        and type(Bitmap.validate) == "function" then
        bitmapValidOk, bitmapValid = pcall(Bitmap.validate, bitmap)
    end
    if not decodeOk or type(bitmap) ~= "table" or not bitmapValidOk
        or bitmapValid ~= true
        or integer(bitmap.bitmapVersion) ~= C.BITMAP_VERSION
        or integer(bitmap.originX) ~= originX or integer(bitmap.originY) ~= originY
        or integer(bitmap.width) ~= width or integer(bitmap.height) ~= height
        or integer(bitmap.minZ) ~= minZ or integer(bitmap.maxZ) ~= maxZ then
        return false, C.INVALID_RV_DATA
    end
    local centerX = originX + math.floor(width / 2)
    local centerY = originY + math.floor(height / 2)
    local rvPosition = copyPosition(record.rvPosition)
    if not rvPosition or math.floor(rvPosition.x) ~= centerX
        or math.floor(rvPosition.y) ~= centerY
        or math.floor(rvPosition.z) ~= integer(C.TELEPORT_Z) then
        return false, C.INVALID_RV_DATA
    end
    local activeX, activeY, activeZ = math.floor(rvPosition.x),
        math.floor(rvPosition.y), math.floor(rvPosition.z)
    if not Bitmap.containsScope(bitmap, activeX, activeY, activeZ)
        or not Bitmap.isActive(bitmap, activeX, activeY, activeZ) then
        return false, C.INVALID_RV_DATA
    end
    return true, {
        bitmap = bitmap, centerX = centerX, centerY = centerY,
        centerZ = integer(C.TELEPORT_Z),
    }
end

-- A mapping record and the current manifest may share an identity while still
-- carrying different bitmap snapshots.  The sentinel must not choose a target
-- from one snapshot and arm a boundary from the other, so compare the complete
-- current bitmap contract before accepting a candidate.
local function sentinelRecordManifestConsistent(record, manifest)
    local server = RailroaderRV and RailroaderRV.Server
    local checker = server and server.currentRVRecordGeometryConsistent
    if type(checker) ~= "function" then return false end
    local ok, consistent = pcall(checker, record, manifest)
    return ok and consistent == true
end

local function sentinelRecordCandidate(map, player, server)
    local identityKey, onlineId, username = sentinelIdentity(player)
    if not identityKey then return nil, nil, "player identity is unavailable" end
    local position = playerPosition(player)
    if not position or math.floor(position.z) ~= RELOCATION_SENTINEL_Z then
        return nil, identityKey, nil
    end
    local candidates = {}
    local invalidReason = nil
    for _, record in pairs(map.locomotives or {}) do
        if type(record) == "table" then
            local centerOk, centerOrReason = sentinelBitmapAndCenter(record)
            local center = centerOk and centerOrReason or nil
            local generationMatch = center ~= nil
                and math.floor(position.x) == center.centerX
                and math.floor(position.y) == center.centerY
                and math.floor(position.z) == RELOCATION_SENTINEL_Z
            local roofMatch = center ~= nil
                and math.floor(position.x)
                    == center.centerX - ROOF_REPAIR_REMOTE_OFFSET_X
                and math.floor(position.y)
                    == center.centerY - ROOF_REPAIR_REMOTE_OFFSET_Y
                and math.floor(position.z)
                    == center.centerZ - ROOF_REPAIR_REMOTE_OFFSET_Z
            if generationMatch or roofMatch then
                if not validRecord(record) or not centerOk
                    or not sentinelRelationsConsistent(map, record) then
                    invalidReason = centerOrReason or C.INVALID_RV_DATA
                else
                    local manifestOk, manifestOrReason = false, nil
                    if server and type(server.currentRVManifestForRelocation)
                        == "function" then
                        local callOk, current, detail = pcall(
                            server.currentRVManifestForRelocation,
                            record.rvId, record.generation, record.bitmapVersion)
                        if callOk and current == true and type(detail) == "table" then
                            manifestOk, manifestOrReason = true, detail
                        else
                            manifestOk = false
                            manifestOrReason = type(detail) == "string" and detail
                                or type(current) == "string" and current
                                or C.INVALID_RV_DATA
                        end
                    end
                    if not manifestOk or type(manifestOrReason) ~= "table" then
                        invalidReason = type(manifestOrReason) == "string"
                            and manifestOrReason or C.INVALID_RV_DATA
                    elseif not sentinelRecordManifestConsistent(record,
                            manifestOrReason) then
                        invalidReason = C.INVALID_RV_DATA
                    else
                        candidates[#candidates + 1] = {
                            record = record, center = center,
                            generationKind = generationMatch and "generation"
                                or "roof",
                            onlineId = onlineId, username = username,
                            identityKey = identityKey,
                            sentinelPosition = {
                                x = position.x, y = position.y, z = position.z,
                            },
                        }
                    end
                end
            end
        end
    end
    if invalidReason ~= nil then
        return nil, identityKey, invalidReason
    end
    if #candidates == 0 then
        return nil, identityKey, "relocation sentinel matched no current RV records"
    end
    if #candidates ~= 1 then
        if #candidates > 1 then
            return nil, identityKey, "relocation sentinel matched multiple RV records"
        end
        return nil, identityKey, nil
    end
    local candidate = candidates[1]
    local relation = map.players[candidate.username]
    local rider = candidate.record.players[candidate.username]
    if type(relation) ~= "table" or type(rider) ~= "table"
        or relation.inside ~= true or rider.inside ~= true
        or tostring(relation.locoId) ~= tostring(candidate.record.rvId)
        or integer(relation.onlineId) ~= candidate.onlineId
        or integer(rider.onlineId) ~= candidate.onlineId then
        return nil, identityKey, C.INVALID_RV_DATA
    end
    return candidate, identityKey, nil
end

local function sentinelReturnToRV(candidate, player, map)
    local server = RailroaderRV and RailroaderRV.Server
    local record = candidate and candidate.record
    local relation = record and map.players[candidate.username]
    if not server or not record or type(relation) ~= "table" then
        return false, C.INVALID_RV_DATA
    end
    local identityKey = sentinelIdentity(player)
    if identityKey ~= candidate.identityKey then
        return false, "relocation sentinel player identity changed"
    end
    local expectedPosition = candidate.sentinelPosition
    local currentPosition = playerPosition(player)
    if type(expectedPosition) ~= "table" or not currentPosition
        or math.floor(currentPosition.x) ~= math.floor(expectedPosition.x)
        or math.floor(currentPosition.y) ~= math.floor(expectedPosition.y)
        or math.floor(currentPosition.z) ~= math.floor(expectedPosition.z) then
        return false, "relocation sentinel player left the temporary cell"
    end
    local claimedOk, claimed = pcall(server.isRelocationIdentityClaimed,
        identityKey)
    if not claimedOk or claimed ~= false then
        return false, claimedOk and "relocation sentinel identity is claimed"
            or C.INVALID_RV_DATA
    end
    local manifestOk, manifestOrReason = false, nil
    if type(server.currentRVManifestForRelocation) == "function" then
        local callOk, current, detail = pcall(
            server.currentRVManifestForRelocation,
            record.rvId, record.generation, record.bitmapVersion)
        if callOk and current == true and type(detail) == "table" then
            manifestOk, manifestOrReason = true, detail
        else
            manifestOk = false
            manifestOrReason = type(detail) == "string" and detail
                or type(current) == "string" and current
                or C.INVALID_RV_DATA
        end
    end
    if not manifestOk or type(manifestOrReason) ~= "table"
        or not sentinelRecordManifestConsistent(record, manifestOrReason)
        or not sentinelRelationsConsistent(map, record) then
        return false, C.INVALID_RV_DATA
    end
    local centerOk, centerOrReason = sentinelBitmapAndCenter(record)
    if not centerOk then return false, centerOrReason end
    local target = copyPosition(record.rvPosition)
    local activeOk, active = false, false
    if target and type(Bitmap.isActive) == "function" then
        activeOk, active = pcall(Bitmap.isActive, centerOrReason.bitmap,
            math.floor(target.x), math.floor(target.y), math.floor(target.z))
    end
    if not target
        or target.x ~= centerOrReason.centerX + 0.5
        or target.y ~= centerOrReason.centerY + 0.5
        or target.z ~= centerOrReason.centerZ
        or not activeOk or active ~= true
        or not usableCoordinate(target) then
        return false, C.INVALID_RV_DATA
    end
    local monitorOk, monitorReason = armRoomOwnershipMonitor(player, record,
        "relocation-sentinel")
    if not monitorOk then return false, monitorReason end
    local token = newTransitionToken("sentinel", record)
    local beginOk, armed = false, false
    if Boundary and type(Boundary.beginTransition) == "function"
        and type(Boundary.completeTransition) == "function" then
        beginOk, armed = pcall(Boundary.beginTransition, player, record.rvId,
            record.generation, token, "sentinel", record.bitmapVersion)
    end
    if not beginOk or armed ~= true then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            pcall(Boundary.clearPlayer, player)
        end
        return false, "relocation sentinel boundary transition could not be armed"
    end
    local beforeMoveIdentity = sentinelIdentity(player)
    local beforeMovePosition = playerPosition(player)
    local beforeMoveClaimOk, beforeMoveClaim = pcall(
        server.isRelocationIdentityClaimed, beforeMoveIdentity)
    if beforeMoveIdentity ~= candidate.identityKey
        or not beforeMovePosition
        or math.floor(beforeMovePosition.x) ~= math.floor(expectedPosition.x)
        or math.floor(beforeMovePosition.y) ~= math.floor(expectedPosition.y)
        or math.floor(beforeMovePosition.z) ~= math.floor(expectedPosition.z)
        or not beforeMoveClaimOk or beforeMoveClaim ~= false then
        if type(Boundary.clearPlayer) == "function" then
            pcall(Boundary.clearPlayer, player)
        end
        return false, beforeMoveClaimOk
            and "relocation sentinel identity became claimed"
            or C.INVALID_RV_DATA
    end
    local moved = movePlayer(player, target, "enter", {
        locoId = record.locoId, role = relation.role, seat = relation.seat,
        rvId = record.rvId, generation = record.generation,
        bitmapVersion = record.bitmapVersion,
    })
    if not moved then
        if type(Boundary.clearPlayer) == "function" then
            pcall(Boundary.clearPlayer, player)
        end
        return false, "relocation sentinel RV return teleport failed"
    end
    if type(Boundary.completeTransition) == "function" then
        local completeOk, completed = pcall(Boundary.completeTransition,
            player, token)
        if not completeOk or completed ~= true then
            if type(Boundary.clearPlayer) == "function" then
                pcall(Boundary.clearPlayer, player)
            end
            return false, "relocation sentinel boundary transition could not be completed"
        end
    end
    -- Do not repair, mutate mapping/player records, or alter manifest phase here.
    return true
end

local function warnSentinelPlayersAtTemporaryCell(reason, knownSentinelPlayers)
    local safeReason = type(reason) == "string" and reason ~= "" and reason
        or C.INVALID_RV_DATA
    local players = knownSentinelPlayers or onlinePlayersSnapshot()
    for i = 1, #players do
        local player = players[i]
        local isSentinel = knownSentinelPlayers ~= nil
        if not isSentinel then
            local zOk, z = call(player, "getZ")
            isSentinel = zOk and integer(z) == RELOCATION_SENTINEL_Z
        end
        if isSentinel then
            local identityKey = sentinelIdentity(player)
            if identityKey then sentinelWarn(identityKey, safeReason) end
        end
    end
end


ctx.onlinePlayersSnapshot = onlinePlayersSnapshot
ctx.resolveSavedPlayer = resolveSavedPlayer
ctx.sentinelIdentity = sentinelIdentity
ctx.sentinelClaimState = sentinelClaimState
ctx.sentinelWarn = sentinelWarn
ctx.sentinelRecordCandidate = sentinelRecordCandidate
ctx.sentinelReturnToRV = sentinelReturnToRV
ctx.warnSentinelPlayersAtTemporaryCell = warnSentinelPlayersAtTemporaryCell
ctx.serverTransactionMutexStatus = serverTransactionMutexStatus
ctx.roofRepairTransactionBlocks = roofRepairTransactionBlocks
ctx.currentGeometryGate = currentGeometryGate
end
