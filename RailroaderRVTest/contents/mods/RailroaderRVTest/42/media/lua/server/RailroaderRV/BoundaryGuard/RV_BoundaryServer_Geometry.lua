-- RV_BoundaryServer: Geometry responsibilities.
return function(ctx)
local processIsServer = ctx.processIsServer
local Bitmap = ctx.Bitmap
local Boundary = ctx.Boundary
local Core = ctx.Core
local C = ctx.C
local Template = require("RailroaderRV/RoomTemplate/RV_Template")
local exactKeys = ctx.exactKeys
-- A registered boundary is immutable. Retain its decoded snapshot by source
-- table so normal tick lookups compare only constant-size metadata.
local sourceBoundaryCache = setmetatable({}, { __mode = "k" })
local generatedBoundaryBitmaps = setmetatable({}, { __mode = "k" })
local sourceCacheHit

local function number(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) end
    if value ~= nil then
        local ok, result = pcall(function() return value + 0 end)
        if ok and type(result) == "number" then return result end
    end
    return nil
end

local function integer(value)
    local result = number(value)
    if result == nil or math.floor(result) ~= result then return nil end
    return result
end

local function finiteNumber(value)
    local result = number(value)
    if result == nil or result ~= result
        or result <= -math.huge or result >= math.huge then
        return nil
    end
    return result
end

Boundary._geometryEpoch = integer(Boundary._geometryEpoch) or 0

local INVALID_RV_DATA_NOTICE_REASONS = {
    ["mapping-relation-rejected"] = true,
    ["mapping-record-rejected"] = true,
    ["record-rider-rejected"] = true,
    ["manifest-rejected"] = true,
    ["geometry-rejected"] = true,
}
local invalidRVDataNoticeAttempted = {}

local function call(target, method, ...)
    if target == nil or type(target[method]) ~= "function" then
        return false, nil
    end
    local ok, a, b, c, d = pcall(target[method], target, ...)
    if not ok then return false, a end
    return true, a, b, c, d
end

local function callGlobal(name, ...)
    local fn = rawget(_G, name)
    if type(fn) ~= "function" then return false, nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then return false, a end
    return true, a, b, c, d
end

local function succeeded(target, method, ...)
    local ok, result = call(target, method, ...)
    return ok and result ~= false
end

local function playerName(player)
    local ok, name = call(player, "getUsername")
    if not ok or name == nil then return nil end
    name = tostring(name)
    return name ~= "" and name or nil
end

local function playerOnlineId(player)
    local ok, value = call(player, "getOnlineID")
    local id = ok and integer(value) or nil
    if id ~= nil and id >= 0 then return id end
    if not processIsServer() then
        local numOk, playerNum = call(player, "getPlayerNum")
        return numOk and integer(playerNum) or 0
    end
    return nil
end

local function identity(player)
    local name = playerName(player)
    local onlineId = playerOnlineId(player)
    if not name or onlineId == nil then return nil end
    return { username = name, onlineId = onlineId,
        key = tostring(onlineId) .. ":" .. name }
end

local function playerPosition(player)
    local okX, x = call(player, "getX")
    local okY, y = call(player, "getY")
    local okZ, z = call(player, "getZ")
    x, y, z = finiteNumber(x), finiteNumber(y), finiteNumber(z)
    if not okX or not okY or not okZ or x == nil or y == nil or z == nil then
        return nil
    end
    local minX = C.TELEPORT_X + C.RV_REGION_MIN_OFFSET_X
    local minY = C.TELEPORT_Y + C.RV_REGION_MIN_OFFSET_Y
    local minZ = C.TELEPORT_Z + C.RV_MANAGED_MIN_Z_OFFSET
    local inRVRegion = x >= minX
        and x < minX + C.RV_REGION_SIZE * C.RV_REGION_SLOT_COLUMNS
        and y >= minY
        and y < minY + C.RV_REGION_SIZE * C.RV_REGION_SLOT_ROWS
        and math.floor(z) >= minZ
        and math.floor(z) < C.TELEPORT_Z + C.RV_MANAGED_MAX_Z_OFFSET
    return { x = x, y = y, z = z }, inRVRegion
end

function Boundary.diagnoseGuardState(player, knownIdentity, position,
    relation, record, reason)
    if not processIsServer() or type(position) ~= "table"
        or INVALID_RV_DATA_NOTICE_REASONS[reason] ~= true then
        return false
    end
    local id = knownIdentity or identity(player)
    local currentIdentity = identity(player)
    local onlineId = type(id) == "table" and integer(id.onlineId) or nil
    if type(id) ~= "table" or type(currentIdentity) ~= "table"
        or type(id.key) ~= "string" or id.key == ""
        or currentIdentity.key ~= id.key
        or onlineId == nil or onlineId < 0 then
        return false
    end
    if invalidRVDataNoticeAttempted[id.key] then return false end
    invalidRVDataNoticeAttempted[id.key] = true

    -- The GUI already consumes this stable failure code and shows the
    -- delete-and-rebuild instruction. Keep diagnostic detail server-side.
    local sentCallOk, sentResult = callGlobal("sendServerCommand", player,
        C.MOD_ID, C.COMMAND_RV_TELEPORT, {
            ok = false, onlineId = onlineId,
            reason = C.INVALID_RV_DATA,
        })
    if not sentCallOk or sentResult == false then
        print("[RailroaderRVTest][BoundaryDiag] invalid RV data notice failed"
            .. " player=" .. tostring(id.key)
            .. " reason=" .. tostring(reason))
        return false
    end
    print("[RailroaderRVTest][BoundaryDiag] invalid RV data notice sent"
        .. " player=" .. tostring(id.key)
        .. " reason=" .. tostring(reason))
    return true
end

local function playerCell(player)
    local ok, cell = call(player, "getCell")
    if ok and cell then return cell end
    local globalOk, globalCell = callGlobal("getCell")
    return globalOk and globalCell or nil
end

local function square(cell, x, y, z)
    if not cell then return nil end
    local ok, result = call(cell, "getGridSquare", x, y, z)
    return ok and result or nil
end

local function encodeShellEdges(source, rvId, generation, bitmapVersion)
    local result = {}
    if type(source) ~= "table" then return result end
    for key, edge in pairs(source) do
        if type(edge) == "table" and type(key) == "string" then
            result[key] = {
                edgeKey = key,
                rvId = tostring(rvId), generation = generation,
                bitmapVersion = bitmapVersion,
                hostX = integer(edge.hostX), hostY = integer(edge.hostY),
                z = integer(edge.z), axis = edge.axis, side = edge.side,
                objectX = integer(edge.objectX), objectY = integer(edge.objectY),
                objectZ = integer(edge.objectZ),
                role = edge.role, corner = edge.corner == true,
                replacementAllowed = edge.replacementAllowed ~= false,
                templateIndex = integer(edge.templateIndex),
                templateIndices = {},
                sprite = edge.sprite, north = edge.north,
            }
            if type(edge.templateIndices) == "table" then
                for i = 1, #edge.templateIndices do
                    result[key].templateIndices[i] = integer(edge.templateIndices[i])
                end
            end
        end
    end
    return result
end

-- Build the persistent record from a layout plan.  Only the encoded bitmap is
-- stored in ModData; no 10,000-entry Lua boolean table is ever persisted.
function Boundary.makeBoundary(layout, rvId, generation)
    if type(layout) ~= "table" or type(layout.bitmap) ~= "table" then
        return nil, "layout bitmap is unavailable"
    end
    if rvId == nil or tostring(rvId) == ""
        or integer(generation) == nil or integer(generation) < 1 then
        return nil, "boundary identity is incomplete"
    end
    local encoded = Bitmap.encode(layout.bitmap)
    if not encoded then return nil, "layout bitmap failed validation" end
    local bitmap = layout.bitmap
    local bitmapVersion = integer(bitmap.bitmapVersion)
    if bitmapVersion ~= C.BITMAP_VERSION then
        return nil, "layout bitmap version is invalid"
    end
    local shellEdges = encodeShellEdges(layout.shellEdges, rvId, generation,
        bitmapVersion)
    local boundary = {
        rvId = tostring(rvId), generation = integer(generation),
        bitmapVersion = bitmapVersion,
        managed = {
            originX = integer(bitmap.originX), originY = integer(bitmap.originY),
            width = integer(bitmap.width), height = integer(bitmap.height),
            minZ = integer(bitmap.minZ), maxZ = integer(bitmap.maxZ),
        },
        bitmap = encoded,
        shellEdges = shellEdges,
    }
    -- New records are built from a current in-memory bitmap. Keep that decoded
    -- value beside the encoded record so later runtime registration does not
    -- re-run persisted-schema decoding.
    generatedBoundaryBitmaps[boundary] = bitmap
    return boundary
end

local function decodeBoundary(boundary)
    if type(boundary) ~= "table" then return nil end
    local source = sourceCacheHit and sourceCacheHit(boundary) or nil
    if source then
        return source.bitmap, source.rvId, source.generation,
            source.bitmapVersion
    end
    local generated = generatedBoundaryBitmaps[boundary]
    if generated then
        return generated, tostring(boundary.rvId), integer(boundary.generation),
            integer(boundary.bitmapVersion)
    end
    local bitmap = Bitmap.decode(boundary.bitmap)
    local rvId = tostring(boundary.rvId or "")
    local generation = integer(boundary.generation)
    local bitmapVersion = integer(boundary.bitmapVersion)
    return bitmap, rvId, generation, bitmapVersion
end
local function boundaryKey(boundary)
    return tostring(boundary.rvId) .. ":" .. tostring(boundary.generation)
        .. ":" .. tostring(boundary.bitmapVersion)
end

local function sameBoundaryManaged(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    local fields = { "originX", "originY", "width", "height", "minZ", "maxZ" }
    if not exactKeys(left, fields) or not exactKeys(right, fields) then
        return false
    end
    for i = 1, #fields do
        if integer(left[fields[i]]) ~= integer(right[fields[i]]) then
            return false
        end
    end
    return true
end

local function sameBoundaryBitmap(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end
    for _, field in ipairs({ "originX", "originY", "width", "height", "minZ", "maxZ" }) do
        if integer(left[field]) ~= integer(right[field]) then return false end
    end
    for z = left.minZ, left.maxZ - 1 do
        local leftLayer, rightLayer = Bitmap.layer(left, z), Bitmap.layer(right, z)
        if type(leftLayer) ~= "table" or type(rightLayer) ~= "table"
            or leftLayer.walkBits ~= rightLayer.walkBits
            or leftLayer.buildBits ~= rightLayer.buildBits then
            return false
        end
    end
    return true
end

local function sameBoundaryShellEdges(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    local fields = { "edgeKey", "rvId", "generation", "bitmapVersion",
        "hostX", "hostY", "z", "axis", "side", "objectX", "objectY",
        "objectZ", "role", "corner", "replacementAllowed",
        "templateIndex", "templateIndices", "sprite", "north" }
    local leftCount, rightCount = 0, 0
    for key, edge in pairs(left) do
        leftCount = leftCount + 1
        local other = right[key]
        if type(edge) ~= "table" or type(other) ~= "table"
            or not exactKeys(edge, fields) or not exactKeys(other, fields) then
            return false
        end
        for i = 1, #fields do
            local field = fields[i]
            if edge[field] ~= other[field] then return false end
        end
        local edgeParts, otherParts = edge.templateIndices, other.templateIndices
        if type(edgeParts) ~= "table" or type(otherParts) ~= "table"
            or #edgeParts ~= #otherParts then
            return false
        end
        for i = 1, #edgeParts do
            if integer(edgeParts[i]) ~= integer(otherParts[i]) then return false end
        end
    end
    for _ in pairs(right) do rightCount = rightCount + 1 end
    return leftCount == rightCount
end

-- The cache key is an identity tuple, not a geometry checksum.  A malformed
-- or partially replaced current save can therefore reuse the same tuple with
-- different bitmap/shell geometry.  Reject that reuse and replace the cached
-- snapshot before any guard or cleanup consumes it.
local function sameBoundaryGeometry(cached, boundary, bitmap)
    return type(cached) == "table"
        and sameBoundaryBitmap(cached.bitmap, bitmap)
        and sameBoundaryManaged(cached.encoded and cached.encoded.managed,
            boundary.managed)
        and sameBoundaryShellEdges(cached.shellEdges, boundary.shellEdges)
end

local function sameBoundary(left, right)
    return type(left) == "table" and type(right) == "table"
        and boundaryKey(left) == boundaryKey(right)
end

sourceCacheHit = function(boundary)
    local source = sourceBoundaryCache[boundary]
    if not source then return nil end
    local loaded = source.loaded
    if not loaded or Boundary._registered[boundaryKey(loaded)] ~= loaded then
        return nil
    end
    local bitmap, managed = boundary.bitmap, boundary.managed
    if boundary.rvId ~= source.rvId
        or boundary.generation ~= source.generation
        or boundary.bitmapVersion ~= source.bitmapVersion
        or boundary.bitmap ~= source.bitmap
        or boundary.managed ~= source.managed
        or boundary.shellEdges ~= source.shellEdges
        or type(bitmap) ~= "table"
        or bitmap.bitmapVersion ~= source.encodedBitmapVersion
        or bitmap.originX ~= source.originX
        or bitmap.originY ~= source.originY
        or bitmap.width ~= source.width
        or bitmap.height ~= source.height
        or bitmap.minZ ~= source.minZ
        or bitmap.maxZ ~= source.maxZ
        or bitmap.encoding ~= source.encoding
        or bitmap.layers ~= source.layers
        or type(managed) ~= "table"
        or managed.originX ~= source.originX
        or managed.originY ~= source.originY
        or managed.width ~= source.width
        or managed.height ~= source.height
        or managed.minZ ~= source.minZ
        or managed.maxZ ~= source.maxZ then
        return nil
    end
    return source.loaded
end

local function rememberSourceBoundary(boundary, loaded)
    local bitmap = boundary.bitmap
    sourceBoundaryCache[boundary] = {
        loaded = loaded,
        rvId = boundary.rvId,
        generation = boundary.generation,
        bitmapVersion = boundary.bitmapVersion,
        bitmap = bitmap,
        managed = boundary.managed,
        shellEdges = boundary.shellEdges,
        encodedBitmapVersion = bitmap.bitmapVersion,
        originX = bitmap.originX,
        originY = bitmap.originY,
        width = bitmap.width,
        height = bitmap.height,
        minZ = bitmap.minZ,
        maxZ = bitmap.maxZ,
        encoding = bitmap.encoding,
        layers = bitmap.layers,
    }
end

local function geometryChanged()
    Boundary._geometryEpoch = (integer(Boundary._geometryEpoch) or 0) + 1
end

local function loadedBoundary(boundary)
    local source = sourceCacheHit(boundary)
    if source then return source end
    local bitmap = generatedBoundaryBitmaps[boundary]
    local rvId, generation, bitmapVersion
    if bitmap then
        rvId = type(boundary) == "table" and tostring(boundary.rvId) or nil
        generation = integer(type(boundary) == "table" and boundary.generation)
        bitmapVersion = integer(type(boundary) == "table" and boundary.bitmapVersion)
        if not rvId or rvId == "" or not generation or not bitmapVersion
            or bitmapVersion ~= C.BITMAP_VERSION then
            return nil
        end
    else
        bitmap, rvId, generation, bitmapVersion = decodeBoundary(boundary)
        if not bitmap then return nil end
    end
    local key = boundaryKey({ rvId = rvId, generation = generation,
        bitmapVersion = bitmapVersion })
    local cached = Boundary._registered[key]
    if cached and sameBoundaryGeometry(cached, boundary, bitmap) then
        rememberSourceBoundary(boundary, cached)
        return cached
    end
    if cached then
        Boundary._registered[key] = nil
        -- A new geometry with the same identity must not inherit an old
        -- source snapshot. The current mapping remains the only authority.
    end
    local result = {
        rvId = rvId, generation = generation, bitmapVersion = bitmapVersion,
        bitmap = bitmap, encoded = boundary, shellEdges = boundary.shellEdges or {},
    }
    Boundary._registered[key] = result
    rememberSourceBoundary(boundary, result)
    geometryChanged()
    return result
end

function Boundary.registerGeneration(rvId, generation, boundary, record)
    if type(boundary) ~= "table" then return false end
    local loaded = loadedBoundary(boundary)
    if not loaded then return false end
    if rvId == nil or tostring(rvId) ~= loaded.rvId
        or integer(generation) ~= loaded.generation then
        return false
    end
    if record then
        if tostring(record.rvId) ~= tostring(rvId)
            or integer(record.generation) ~= loaded.generation
            or integer(record.bitmapVersion) ~= loaded.bitmapVersion
            or record.boundary ~= boundary then
            return false
        end
    end
    Boundary._registered[boundaryKey(loaded)] = loaded
    if type(Boundary.invalidateBuilderActionsForGeneration) == "function" then
        Boundary.invalidateBuilderActionsForGeneration(loaded.rvId,
            loaded.generation, loaded.bitmapVersion)
    end
    return true
end

function Boundary.boundaryForPlayer(player, knownIdentity, deferValidationMiss,
    forceValidationRefresh, roofRefreshContextRead, roofRefreshGuardRead)
    local id = knownIdentity or identity(player)
    if not id then return nil end
    -- The Railroader adapter checks the player's current mapping and manifest
    -- identity; this module validates the boundary it needs locally.
    local rv = rawget(_G, "RailroaderRV")
    local adapter = rv and rv.RailroaderServer
    local validator = adapter and adapter.validateCurrentBoundaryPlayer
    if type(validator) ~= "function" then return nil end
    local hookOk, boundary, record, relation, validatedIdentity, manifest = pcall(
        validator, player, id, deferValidationMiss == true,
        forceValidationRefresh == true, roofRefreshContextRead == true,
        roofRefreshGuardRead == true)
    if hookOk and boundary == nil and record == "validation-deferred" then
        return nil, record
    end
    if not hookOk or type(boundary) ~= "table"
        or type(record) ~= "table" or type(relation) ~= "table"
        or type(validatedIdentity) ~= "table"
        or validatedIdentity.key ~= id.key
        or type(manifest) ~= "table" or type(manifest.anchor) ~= "table"
        or tostring(manifest.rvId) ~= tostring(record.rvId)
        or integer(manifest.generation) ~= integer(record.generation)
        or integer(manifest.bitmapVersion) ~= integer(record.bitmapVersion) then
        return nil
    end
    local loaded = loadedBoundary(boundary)
    if not loaded then return nil end
    if loaded.rvId ~= tostring(record.rvId)
        or loaded.generation ~= integer(record.generation)
        or loaded.bitmapVersion ~= integer(record.bitmapVersion) then
        return nil
    end
    return loaded, record, relation, validatedIdentity, manifest
end

local function stateFor(player, knownIdentity)
    local id = knownIdentity or identity(player)
    if not id then return nil end
    local state = Boundary._states[id.key]
    if not state then
        state = { identity = id, correctionSequence = 0 }
        Boundary._states[id.key] = state
    else
        state.identity = id
    end
    return state
end

local function transitionIdentityKey(rvId, generation, bitmapVersion)
    local normalizedGeneration = integer(generation)
    local normalizedBitmapVersion = integer(bitmapVersion)
    if rvId == nil or tostring(rvId) == "" or normalizedGeneration == nil
        or normalizedBitmapVersion == nil then
        return nil
    end
    return tostring(rvId) .. ":" .. tostring(normalizedGeneration)
        .. ":" .. tostring(normalizedBitmapVersion)
end

-- Return only the activity facts needed by TemplateRecovery. Callers do not
-- receive Boundary's mutable player-state tables or lease field layout.
function Boundary.transitionActivitySnapshot(tick)
    if not Core.isTick(tick) or type(Boundary._states) ~= "table" then
        return false, "boundary transition state unavailable"
    end
    local activity = {}
    for _, state in pairs(Boundary._states) do
        if type(state) == "table" then
            local key = transitionIdentityKey(state.rvId, state.generation,
                state.bitmapVersion)
            local transitionUntil = state.transitionUntil
            local inWindow = Core.isTick(transitionUntil)
                and Core.tickReached(transitionUntil, tick)
            if key and inWindow then
                local snapshot = activity[key]
                if not snapshot then
                    snapshot = { active = false, recentlyCompleted = false }
                    activity[key] = snapshot
                end
                if state.transitionToken ~= nil or state.transitionKind ~= nil then
                    snapshot.active = true
                else
                    snapshot.recentlyCompleted = true
                end
            end
        end
    end
    return true, activity
end

function Boundary.hasActiveTransitionForIdentity(rvId, generation,
    bitmapVersion, tick)
    local key = transitionIdentityKey(rvId, generation, bitmapVersion)
    if not key or not Core.isTick(tick) then return false end
    local snapshotOk, activity = Boundary.transitionActivitySnapshot(tick)
    if not snapshotOk then return false end
    local state = activity[key]
    return state ~= nil and state.active == true
end

-- Small lifecycle interface for independent services that must yield while
-- an authoritative player relocation is in flight. Listeners do not own or
-- alter transition state; failures are contained so they cannot block travel.
local transitionLifecycleListeners =
    Boundary._transitionLifecycleListeners
if type(transitionLifecycleListeners) ~= "table" then
    transitionLifecycleListeners = {}
    Boundary._transitionLifecycleListeners = transitionLifecycleListeners
end

function Boundary.addTransitionLifecycleListener(name, listener)
    if type(name) ~= "string" or name == ""
        or type(listener) ~= "function" then
        return false
    end
    transitionLifecycleListeners[name] = listener
    return true
end

local function notifyTransitionLifecycle(eventName, player, state)
    local transitionIdentity = type(state) == "table" and {
        rvId = state.rvId,
        generation = state.generation,
        bitmapVersion = state.bitmapVersion,
    } or nil
    for name, listener in pairs(transitionLifecycleListeners) do
        if type(listener) == "function" then
            local ok, reason = pcall(listener, eventName, player,
                transitionIdentity,
                Boundary._tick)
            if not ok then
                print("[RailroaderRVTest] boundary transition listener failed name="
                    .. tostring(name) .. " event=" .. tostring(eventName)
                    .. " reason=" .. tostring(reason))
            end
        end
    end
end

function Boundary.beginTransition(player, rvId, generation, token, kind,
    bitmapVersion)
    local version = integer(bitmapVersion)
    if rvId == nil or tostring(rvId) == "" or integer(generation) == nil
        or integer(generation) < 1 or version ~= C.BITMAP_VERSION then
        return false
    end
    local state = stateFor(player)
    if not state then return false end
    state.rvId = rvId and tostring(rvId) or nil
    state.generation = integer(generation)
    state.bitmapVersion = version
    state.transitionToken = type(token) == "string" and token or nil
    state.transitionKind = kind or "relocation"
    state.transitionUntil = Core.tickAdd(Boundary._tick,
        integer(C.BOUNDARY_TRANSITION_TIMEOUT_TICKS) or 120)
    state.validationRefreshTick = nil
    notifyTransitionLifecycle("begin", player, state)
    return true
end

function Boundary.completeTransition(player, token)
    local state = stateFor(player)
    if not state then return false end
    if token ~= nil and state.transitionToken ~= token then return false end
    state.transitionToken = nil
    state.transitionKind = nil
    state.transitionUntil = Core.tickAdd(Boundary._tick, 2)
    notifyTransitionLifecycle("complete", player, state)
    return true
end

-- Long-running server-owned operations (such as the bounded roof refresh
-- relocation) must keep the normal boundary correction path paused while the
-- client streams/refreshes a room.  Re-arming beginTransition would clear and
-- resend the prediction snapshot on every tick, so expose a token-scoped lease
-- extension instead.  This changes no mapping or bitmap state and fails closed
-- when a stale token tries to extend a different transition.
function Boundary.extendTransition(player, token, untilTick)
    local state = stateFor(player)
    if not state or type(state.transitionToken) ~= "string"
        or state.transitionToken ~= token then
        return false
    end
    if not Core.isTick(untilTick) then return false end
    local order = Core.isTick(state.transitionUntil)
        and Core.tickCompare(untilTick, state.transitionUntil) or 1
    if order == nil or order > 0 then
        state.transitionUntil = { hi32 = untilTick.hi32, lo32 = untilTick.lo32 }
    end
    return true
end

function Boundary.clearPlayer(player)
    local id = identity(player)
    if id then
        local state = Boundary._states[id.key]
        Boundary._states[id.key] = nil
        notifyTransitionLifecycle("clear", player, state)
    end
    return true
end

local function transitionActive(state)
    if not state or not state.transitionToken then return false end
    if Core.isTick(state.transitionUntil)
        and Core.tickReached(state.transitionUntil, Boundary._tick) then
        return true
    end
    state.transitionToken, state.transitionKind, state.transitionUntil = nil, nil, nil
    notifyTransitionLifecycle("timeout", nil, state)
    return false
end

local function prepareCorrection(player, boundary, state, target)
    if not target or not Bitmap.isActive(boundary.bitmap, target.x, target.y, target.z) then
        return false
    end
    -- Recovery must not fabricate a teleport into an unloaded target square.
    -- A last-valid point was loaded when recorded, but a reconnect/streaming
    -- race can make a nearest active fallback unavailable; defer until the
    -- authoritative cell exposes that exact square.
    local cell = playerCell(player)
    if not square(cell, math.floor(target.x), math.floor(target.y),
        math.floor(target.z)) then
        return false
    end
    local id = state and state.identity or identity(player)
    if not id then return false end
    state.correctionSequence = (integer(state.correctionSequence) or 0) + 1
    local payload = {
        rvId = boundary.rvId, generation = boundary.generation,
        bitmapVersion = boundary.bitmapVersion, sequence = state.correctionSequence,
        onlineId = id.onlineId, x = target.x, y = target.y, z = target.z,
    }
    return payload
end

local function notifyCorrection(player, payload)
    callGlobal("sendServerCommand", player, C.MOD_ID,
        C.COMMAND_RV_BOUNDARY_CORRECTION, payload)
end

local function currentSquareMatches(player, position)
    local ok, current = call(player, "getCurrentSquare")
    -- A nil current square means the current square has not been loaded (the
    -- authoritative cell is unavailable)
    -- (or the player cache is between cells).  It is not evidence that the
    -- position is valid: last-valid may only advance after a loaded-square
    -- check, and recovery must wait for the same proof.
    if not ok or current == nil then return false end
    local okX, x = call(current, "getX")
    local okY, y = call(current, "getY")
    local okZ, z = call(current, "getZ")
    if not okX or not okY or not okZ then return false end
    return integer(x) == math.floor(position.x)
        and integer(y) == math.floor(position.y)
        and integer(z) == math.floor(position.z)
end

local function guardContextForPlayer(player, position, knownIdentity,
    deferValidationMiss)
    local stateIdentity = knownIdentity or identity(player)
    local priorState = stateIdentity and Boundary._states[stateIdentity.key] or nil
    local refreshTicks = integer(C.BOUNDARY_SNAPSHOT_REFRESH_TICKS) or 60
    local previousRefreshTick = priorState and priorState.validationRefreshTick
    local forceValidationRefresh = priorState ~= nil
        and (not Core.isTick(previousRefreshTick)
            or Core.tickElapsedAtLeast(Boundary._tick, previousRefreshTick,
                refreshTicks))
    local boundary, record, relation, id = Boundary.boundaryForPlayer(player,
        knownIdentity, deferValidationMiss, forceValidationRefresh, false, true)
    if not boundary then
        return nil
    end
    local currentOnlineId = type(id) == "table"
        and integer(id.onlineId) or nil
    local relationOnlineId = type(relation) == "table"
        and integer(relation.onlineId) or nil
    local rider = type(id) == "table" and type(record) == "table"
        and type(record.players) == "table" and record.players[id.username] or nil
    if type(id) ~= "table" or currentOnlineId == nil
        or type(record) ~= "table"
        or type(relation) ~= "table" or relation.inside ~= true
        or tostring(relation.locoId) ~= tostring(record.locoId)
        or relationOnlineId ~= currentOnlineId
        or type(rider) ~= "table" or rider.inside ~= true
        or integer(rider.onlineId) ~= currentOnlineId then
        return nil
    end
    local state = stateFor(player, id or knownIdentity)
    if not state then
        return nil
    end
    if state.boundaryReference ~= boundary
        or state.rvId ~= boundary.rvId
        or state.generation ~= boundary.generation
        or state.bitmapVersion ~= boundary.bitmapVersion then
        state.rvId, state.generation, state.bitmapVersion = boundary.rvId,
            boundary.generation, boundary.bitmapVersion
        state.boundaryReference = boundary
        state.validationRefreshTick = nil
    end
    if state.validationRefreshTick == nil or forceValidationRefresh then
        state.validationRefreshTick = Boundary._tick
    end
    if transitionActive(state) then return nil end
    if not position then return nil end
    -- A correction must use a fresh position that agrees with the server's
    -- loaded current square. Missing or stale square state leaves the player
    -- untouched and keeps repair work paused for this tick.
    if not currentSquareMatches(player, position) then
        return nil
    end
    local bounds
    if type(position.z) == "number" and position.z == position.z
        and position.z > -math.huge and position.z < math.huge then
        bounds = Bitmap.walkBounds(boundary.bitmap, math.floor(position.z))
    end
    return {
        position = position,
        bitmap = boundary.bitmap,
        aabb = bounds and bounds.outer or nil,
        boundary = boundary,
        spawnIdentity = { rvId = boundary.rvId,
            generation = boundary.generation,
            bitmapVersion = boundary.bitmapVersion },
        expectedSpawn = record.rvPosition,
        preparePullback = function()
            return prepareCorrection(player, boundary, state, record.rvPosition)
        end,
        notifyPullback = function(payload)
            notifyCorrection(player, payload)
        end,
    }
end

function Boundary.cachedBitmap(record)
    if type(record) ~= "table" or type(record.boundary) ~= "table" then return nil end
    local key = boundaryKey({ rvId = record.rvId, generation = record.generation,
        bitmapVersion = record.bitmapVersion })
    local cached = Boundary._registered[key]
    if cached and cached.encoded == record.boundary then return cached.bitmap end
    return nil
end


ctx.number = number
ctx.integer = integer
ctx.call = call
ctx.callGlobal = callGlobal
ctx.identity = identity
ctx.playerPosition = playerPosition
ctx.playerCell = playerCell
ctx.square = square
ctx.decodeBoundary = decodeBoundary
ctx.boundaryKey = boundaryKey
ctx.sameBoundary = sameBoundary
ctx.stateFor = stateFor
ctx.transitionActive = transitionActive
ctx.guardContextForPlayer = guardContextForPlayer
end
