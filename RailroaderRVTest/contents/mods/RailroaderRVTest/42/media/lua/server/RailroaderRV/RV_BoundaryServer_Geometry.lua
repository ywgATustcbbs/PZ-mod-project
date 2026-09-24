-- RV_BoundaryServer: Geometry responsibilities.
return function(ctx)
local processIsServer = ctx.processIsServer
local Bitmap = ctx.Bitmap
local Boundary = ctx.Boundary
local C = ctx.C
local exactKeys = ctx.exactKeys
-- A registered boundary is immutable. Retain its decoded snapshot by source
-- table so normal tick lookups compare only constant-size metadata.
local sourceBoundaryCache = setmetatable({}, { __mode = "k" })

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

Boundary._geometryEpoch = integer(Boundary._geometryEpoch) or 0

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
    local okZ, z = call(player, "getZ")
    z = number(z)
    if not okZ or z == nil
        or math.floor(z) < C.TELEPORT_Z + C.RV_MANAGED_MIN_Z_OFFSET
        or math.floor(z) >= C.TELEPORT_Z + C.RV_MANAGED_MAX_Z_OFFSET then
        return nil
    end
    local okX, x = call(player, "getX")
    local okY, y = call(player, "getY")
    x, y = number(x), number(y)
    if not okX or not okY or x == nil or y == nil
        or x < C.TELEPORT_X + C.RV_REGION_MIN_OFFSET_X
        or x >= C.TELEPORT_X + C.RV_REGION_MIN_OFFSET_X + C.RV_REGION_SIZE
        or y < C.TELEPORT_Y + C.RV_REGION_MIN_OFFSET_Y
        or y >= C.TELEPORT_Y + C.RV_REGION_MIN_OFFSET_Y + C.RV_REGION_SIZE then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function copyPosition(position)
    if type(position) ~= "table" then return nil end
    local x, y, z = number(position.x), number(position.y), number(position.z)
    if not x or not y or not z then return nil end
    return { x = x, y = y, z = z }
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
            }
        end
    end
    return result
end

local function validShellEdges(edges, rvId, generation, bitmapVersion)
    if type(edges) ~= "table" or rvId == nil or tostring(rvId) == ""
        or integer(generation) == nil or integer(generation) < 1
        or integer(bitmapVersion) ~= C.BITMAP_VERSION then
        return false
    end
    local edgeCount = 0
    local allowedEdgeKeys = {
        edgeKey = true, rvId = true, generation = true,
        bitmapVersion = true, hostX = true, hostY = true, z = true,
        axis = true, side = true, objectX = true, objectY = true,
        objectZ = true, role = true, corner = true,
        replacementAllowed = true,
    }
    for key, edge in pairs(edges) do
        edgeCount = edgeCount + 1
        if type(key) ~= "string" or type(edge) ~= "table"
            or edge.edgeKey ~= key then
            return false
        end
        for field in pairs(edge) do
            if not allowedEdgeKeys[field] then return false end
        end
        local axis, edgeX, edgeY, edgeZ = string.match(
            key, "^([NW]):(-?%d+):(-?%d+):(-?%d+)$")
        edgeX, edgeY, edgeZ = tonumber(edgeX), tonumber(edgeY), tonumber(edgeZ)
        if not axis or edgeX == nil or edgeY == nil or edgeZ == nil
            or edge.axis ~= axis
            or tostring(edge.rvId) ~= tostring(rvId)
            or integer(edge.generation) ~= integer(generation)
            or integer(edge.bitmapVersion) ~= integer(bitmapVersion)
            or integer(edge.hostX) ~= edgeX
            or integer(edge.hostY) ~= edgeY
            or integer(edge.z) ~= edgeZ
            or integer(edge.objectX) == nil
            or integer(edge.objectY) == nil
            or integer(edge.objectZ) == nil
            or (axis == "N" and edge.side ~= "north"
                and edge.side ~= "south")
            or (axis == "W" and edge.side ~= "west"
                and edge.side ~= "east")
            or integer(edge.objectX) ~= edgeX
            or integer(edge.objectY) ~= edgeY
            or integer(edge.objectZ) ~= edgeZ
            or type(edge.role) ~= "string"
            or type(edge.corner) ~= "boolean"
            or type(edge.replacementAllowed) ~= "boolean" then
            return false
        end
    end
    return edgeCount == 92
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
    local managed = layout.managed
    if type(managed) ~= "table"
        or integer(managed.originX) ~= integer(bitmap.originX)
        or integer(managed.originY) ~= integer(bitmap.originY)
        or integer(managed.width) ~= integer(bitmap.width)
        or integer(managed.height) ~= integer(bitmap.height)
        or integer(managed.minZ) ~= integer(bitmap.minZ)
        or integer(managed.maxZ) ~= integer(bitmap.maxZ) then
        return nil, "layout managed scope does not match bitmap"
    end
    local bitmapVersion = integer(bitmap.bitmapVersion)
    if bitmapVersion ~= C.BITMAP_VERSION then
        return nil, "layout bitmap version is invalid"
    end
    local shellEdges = encodeShellEdges(layout.shellEdges, rvId, generation,
        bitmapVersion)
    if not validShellEdges(shellEdges, rvId, generation, bitmapVersion) then
        return nil, "layout shell edge ledger failed validation"
    end
    local boundary = {
        schemaVersion = C.BOUNDARY_SCHEMA_VERSION,
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
    if not boundary.generation or not boundary.managed.originX
        or not boundary.managed.originY or not boundary.managed.width
        or not boundary.managed.height or not boundary.managed.minZ
        or not boundary.managed.maxZ then
        return nil, "layout managed scope is incomplete"
    end
    return boundary
end

local function decodeBoundary(boundary)
    if type(boundary) ~= "table" then return nil end
    if not exactKeys(boundary, { "schemaVersion", "rvId", "generation",
        "bitmapVersion", "managed", "bitmap", "shellEdges" }) then
        return nil
    end
    if boundary.version ~= nil then return nil end
    if integer(boundary.schemaVersion) ~= C.BOUNDARY_SCHEMA_VERSION then return nil end
    local encoded = boundary.bitmap
    if type(encoded) ~= "table" then return nil end
    local bitmap = Bitmap.decode(encoded)
    if not bitmap or not Bitmap.validate(bitmap) then return nil end
    local managed = boundary.managed
    if not exactKeys(managed, { "originX", "originY", "width", "height",
        "minZ", "maxZ" })
        or integer(managed.originX) ~= bitmap.originX
        or integer(managed.originY) ~= bitmap.originY
        or integer(managed.width) ~= bitmap.width
        or integer(managed.height) ~= bitmap.height
        or integer(managed.minZ) ~= bitmap.minZ
        or integer(managed.maxZ) ~= bitmap.maxZ then
        return nil
    end
    local rvId = boundary.rvId
    local generation = integer(boundary.generation)
    local bitmapVersion = integer(boundary.bitmapVersion)
    local encodedVersion = integer(encoded.bitmapVersion)
    if rvId == nil or tostring(rvId) == "" or not generation or generation < 1
        or bitmapVersion ~= C.BITMAP_VERSION
        or encodedVersion ~= bitmapVersion
        or not validShellEdges(boundary.shellEdges, rvId, generation,
            bitmapVersion) then
        return nil
    end
    return bitmap, tostring(rvId), generation, bitmapVersion
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
        "objectZ", "role", "corner", "replacementAllowed" }
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

local function sourceCacheHit(boundary)
    local source = sourceBoundaryCache[boundary]
    if not source then return nil end
    local loaded = source.loaded
    if not loaded or Boundary._registered[boundaryKey(loaded)] ~= loaded then
        return nil
    end
    local bitmap, managed = boundary.bitmap, boundary.managed
    if boundary.schemaVersion ~= source.schemaVersion
        or boundary.rvId ~= source.rvId
        or boundary.generation ~= source.generation
        or boundary.bitmapVersion ~= source.bitmapVersion
        or boundary.bitmap ~= source.bitmap
        or boundary.managed ~= source.managed
        or boundary.shellEdges ~= source.shellEdges
        or type(bitmap) ~= "table"
        or bitmap.schemaVersion ~= source.bitmapSchemaVersion
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
        schemaVersion = boundary.schemaVersion,
        rvId = boundary.rvId,
        generation = boundary.generation,
        bitmapVersion = boundary.bitmapVersion,
        bitmap = bitmap,
        managed = boundary.managed,
        shellEdges = boundary.shellEdges,
        bitmapSchemaVersion = bitmap.schemaVersion,
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
    local bitmap, rvId, generation, bitmapVersion = decodeBoundary(boundary)
    if not bitmap then return nil end
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
        -- cleanup cursor.  The next current-only registration starts a fresh
        -- cursor against the replacement snapshot.
        Boundary._cleanups[key] = nil
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
    return true
end

function Boundary.boundaryForPlayer(player, knownIdentity, deferValidationMiss)
    local id = knownIdentity or identity(player)
    if not id then return nil end
    -- The complete current-only map/record validator lives in the Railroader
    -- adapter.  Boundary must not maintain a second shallow ModData parser:
    -- if the hook is missing, or rejects a missing/unknown/partial schema,
    -- no boundary guard is allowed to run.
    local rv = rawget(_G, "RailroaderRV")
    local adapter = rv and rv.RailroaderServer
    local validator = adapter and adapter.validateCurrentBoundaryPlayer
    if type(validator) ~= "function" then return nil end
    local hookOk, boundary, record, relation, validatedIdentity = pcall(
        validator, player, id, deferValidationMiss == true)
    if hookOk and boundary == nil and record == "validation-deferred" then
        return nil, record
    end
    if not hookOk or type(boundary) ~= "table"
        or type(record) ~= "table" or type(relation) ~= "table"
        or type(validatedIdentity) ~= "table"
        or validatedIdentity.key ~= id.key then
        return nil
    end
    local loaded = loadedBoundary(boundary)
    if not loaded then return nil end
    if loaded.rvId ~= tostring(record.rvId)
        or loaded.generation ~= integer(record.generation)
        or loaded.bitmapVersion ~= integer(record.bitmapVersion) then
        return nil
    end
    return loaded, record, relation, validatedIdentity
end

local function stateFor(player, knownIdentity)
    local id = knownIdentity or identity(player)
    if not id then return nil end
    local state = Boundary._states[id.key]
    if not state then
        state = { identity = id, correctionSequence = 0,
            recoveryCooldown = 0, snapshotKey = nil }
        Boundary._states[id.key] = state
    else
        state.identity = id
    end
    return state
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
    -- A transition invalidates any prior client prediction snapshot before
    -- the player is moved or the new generation is committed.  This is only
    -- a client-feedback reset; it never changes the server mapping or world.
    if state.snapshotKey then
        callGlobal("sendServerCommand", player, C.MOD_ID,
            C.COMMAND_RV_BITMAP_CLEAR, {
                onlineId = state.identity and state.identity.onlineId,
                key = state.snapshotKey,
            })
    end
    state.rvId = rvId and tostring(rvId) or nil
    state.generation = integer(generation)
    state.bitmapVersion = version
    state.transitionToken = type(token) == "string" and token or nil
    state.transitionKind = kind or "relocation"
    state.transitionUntil = Boundary._tick
        + (integer(C.BOUNDARY_TRANSITION_TIMEOUT_TICKS) or 120)
    state.snapshotKey = nil
    state.snapshotSentTick = nil
    state.lastValid = nil
    state.lastPosition = nil
    state.invalidSegment = nil
    state.recoveryCooldown = 0
    return true
end

function Boundary.completeTransition(player, token)
    local state = stateFor(player)
    if not state then return false end
    if token ~= nil and state.transitionToken ~= token then return false end
    state.transitionToken = nil
    state.transitionKind = nil
    state.transitionUntil = Boundary._tick + 2
    state.lastValid = nil
    state.lastPosition = nil
    state.invalidSegment = nil
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
    local requested = integer(untilTick)
    if requested == nil then return false end
    if requested > (state.transitionUntil or 0) then
        state.transitionUntil = requested
    end
    return true
end

function Boundary.clearPlayer(player)
    local id = identity(player)
    if id then
        local state = Boundary._states[id.key]
        callGlobal("sendServerCommand", player, C.MOD_ID,
            C.COMMAND_RV_BITMAP_CLEAR, {
                onlineId = id.onlineId, key = state and state.snapshotKey,
            })
        Boundary._states[id.key] = nil
    end
    return true
end

local function transitionActive(state)
    if not state or not state.transitionToken then return false end
    if Boundary._tick <= (state.transitionUntil or 0) then return true end
    state.transitionToken, state.transitionKind, state.transitionUntil = nil, nil, nil
    return false
end

local function snapshotPayload(boundary, onlineId)
    local encoded = boundary.encoded
    if type(encoded) ~= "table" or type(encoded.bitmap) ~= "table" then
        return nil
    end
    local bitmap = encoded.bitmap
    return {
        rvId = boundary.rvId, generation = boundary.generation,
        bitmapVersion = boundary.bitmapVersion, onlineId = onlineId,
        schemaVersion = bitmap.schemaVersion,
        originX = bitmap.originX, originY = bitmap.originY,
        width = bitmap.width, height = bitmap.height,
        minZ = bitmap.minZ, maxZ = bitmap.maxZ,
        layers = bitmap.layers, encoding = "hex",
    }
end

function Boundary.sendSnapshot(player, boundary, state)
    if not boundary or not player then return false end
    local onlineId = playerOnlineId(player)
    local payload = snapshotPayload(boundary, onlineId)
    if not payload then return false end
    local sent = callGlobal("sendServerCommand", player, C.MOD_ID,
        C.COMMAND_RV_BITMAP, payload)
    if not sent and processIsServer() then return false end
    if state then
        state.snapshotKey = boundaryKey(boundary)
        state.snapshotSentTick = Boundary._tick
    end
    return true
end

local function correction(player, boundary, state, target)
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
    -- Apply the authoritative server position first.  The client receives an
    -- opaque correction only after that succeeds; a failed server teleport
    -- must never leave the client believing a correction that did not happen.
    if not succeeded(player, "teleportTo", target.x, target.y, target.z) then
        return false
    end
    callGlobal("sendServerCommand", player, C.MOD_ID,
        C.COMMAND_RV_BOUNDARY_CORRECTION, payload)
    state.lastValid = copyPosition(target)
    state.lastPosition = copyPosition(target)
    state.invalidSegment = nil
    state.recoveryCooldown = Boundary._tick
        + (integer(C.BOUNDARY_RECOVERY_COOLDOWN_TICKS) or 8)
    return true
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

local function updatePlayer(player, position, knownIdentity, deferValidationMiss)
    local boundary, _, _, id = Boundary.boundaryForPlayer(player,
        knownIdentity, deferValidationMiss)
    if not boundary then return nil end
    local state = stateFor(player, id or knownIdentity)
    if not state then return nil end
    local lastObserved = integer(state.lastObservedBoundaryTick)
    if lastObserved == nil or Boundary._tick > lastObserved + 1 then
        state.lastValid, state.lastPosition, state.invalidSegment = nil, nil, nil
        state.nextValidRecordTick = nil
        state.recoveryCooldown = 0
    end
    state.lastObservedBoundaryTick = Boundary._tick
    if state.boundaryReference ~= boundary
        or state.rvId ~= boundary.rvId
        or state.generation ~= boundary.generation
        or state.bitmapVersion ~= boundary.bitmapVersion then
        state.rvId, state.generation, state.bitmapVersion = boundary.rvId,
            boundary.generation, boundary.bitmapVersion
        state.boundaryReference = boundary
        state.lastValid, state.lastPosition, state.invalidSegment = nil, nil, nil
        state.recoveryCooldown = 0
        state.snapshotKey = nil
    end
    local snapshotAge = Boundary._tick
        - (integer(state.snapshotSentTick) or -math.huge)
    local refreshTicks = integer(C.BOUNDARY_SNAPSHOT_REFRESH_TICKS) or 60
    if state.snapshotKey ~= boundaryKey(boundary) or snapshotAge >= refreshTicks then
        Boundary.sendSnapshot(player, boundary, state)
    end
    if transitionActive(state) then return boundary end
    if not position then return boundary end
    -- Scope guard is intentionally before every correction path.  An inside
    -- relation alone never grants permission to touch a player outside this
    -- RV's exact managed region.
    if not Bitmap.containsScope(boundary.bitmap, position.x, position.y, position.z) then
        state.lastValid, state.lastPosition, state.invalidSegment = nil, nil, nil
        return boundary
    end
    if not currentSquareMatches(player, position) then return boundary end
    if Boundary._tick < (state.recoveryCooldown or 0) then return boundary end
    local active, inInner = Bitmap.walkableFast(boundary.bitmap,
        position.x, position.y, position.z)
    local previous = state.lastPosition
    local sameCell = previous
        and math.floor(previous.x) == math.floor(position.x)
        and math.floor(previous.y) == math.floor(position.y)
        and math.floor(previous.z) == math.floor(position.z)
    if active and previous and not sameCell then
        local bounds = inInner and Bitmap.walkBounds(boundary.bitmap,
            math.floor(position.z))
        local staysInside = bounds and math.floor(previous.z) == math.floor(position.z)
            and Bitmap.inAABB(bounds.inner, previous.x, previous.y)
        if not staysInside then
            local segmentOk = Bitmap.segmentValid(boundary.bitmap,
                previous, position)
            if not segmentOk then state.invalidSegment = true end
        end
    end
    if active and not state.invalidSegment then
        if not sameCell or Boundary._tick >= (state.nextValidRecordTick or 0) then
            state.lastValid = copyPosition(position)
            state.nextValidRecordTick = Boundary._tick + 10
        end
        if not previous or previous.x ~= position.x or previous.y ~= position.y
            or previous.z ~= position.z then
            state.lastPosition = copyPosition(position)
        end
        return boundary
    end
    if not active or state.invalidSegment then
        local target = state.lastValid
        if not target or not Bitmap.isActive(boundary.bitmap,
            target.x, target.y, target.z) then
            target = Bitmap.nearestActive(boundary.bitmap, position.x,
                position.y, math.floor(position.z))
        end
        if target then correction(player, boundary, state, target) end
    end
    return boundary
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
ctx.updatePlayer = updatePlayer
end
