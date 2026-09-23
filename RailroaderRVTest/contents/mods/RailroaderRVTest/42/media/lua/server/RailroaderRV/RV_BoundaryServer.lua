-- Server-authoritative RV boundary service.
--
-- This module deliberately does not import or instantiate any Railroader
-- collider/body object.  It borrows only the useful shape of that solution:
-- keep a short-lived previous position, reject a swept transition at the
-- boundary, and correct current/next state together when recovery is needed.
-- The RV bitmap is the canonical geometry and every world operation is
-- clipped to the owning RV's half-open 100x100xZ scope.

local function processIsClient()
    if type(isClient) ~= "function" then return false end
    local ok, value = pcall(isClient)
    return ok and value == true
end

local function processIsServer()
    if type(isServer) ~= "function" then return true end
    local ok, value = pcall(isServer)
    return ok and value == true
end

if processIsClient() and not processIsServer() then
    return {}
end

require "RailroaderRV/RV_Constants"
local Bitmap = require "RailroaderRV/RV_Bitmap"

RailroaderRV = RailroaderRV or {}
RailroaderRV.BoundaryServer = RailroaderRV.BoundaryServer or {}

local Boundary = RailroaderRV.BoundaryServer
local C = RailroaderRV.Constants
local OWNER = C.MOD_ID

Boundary._states = Boundary._states or {}
Boundary._registered = Boundary._registered or {}
Boundary._cleanups = Boundary._cleanups or {}
Boundary._dirty = Boundary._dirty or {}
Boundary._builders = Boundary._builders or {}
Boundary._tick = Boundary._tick or 0

local function number(value)
    if type(value) == "number" then
        if value == value and value ~= math.huge and value ~= -math.huge then
            return value
        end
        return nil
    end
    if type(value) == "string" then return tonumber(value) end
    if value ~= nil then
        local ok, result = pcall(function() return value + 0 end)
        if ok and type(result) == "number" and result == result
            and result ~= math.huge and result ~= -math.huge then
            return result
        end
    end
    return nil
end

local function integer(value)
    local result = number(value)
    if result == nil or math.floor(result) ~= result then return nil end
    return result
end

local function exactKeys(value, expected)
    if type(value) ~= "table" then return false end
    local allowed, count = {}, 0
    for i = 1, #expected do allowed[expected[i]] = true end
    for key in pairs(value) do
        if not allowed[key] then return false end
        count = count + 1
    end
    return count == #expected
end

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
    x, y, z = number(x), number(y), number(z)
    if not okX or not okY or not okZ or not x or not y or not z then
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

local function loadedBoundary(boundary)
    local bitmap, rvId, generation, bitmapVersion = decodeBoundary(boundary)
    if not bitmap then return nil end
    local key = boundaryKey({ rvId = rvId, generation = generation,
        bitmapVersion = bitmapVersion })
    local cached = Boundary._registered[key]
    if cached and sameBoundaryGeometry(cached, boundary, bitmap) then
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

function Boundary.boundaryForPlayer(player)
    local id = identity(player)
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
        validator, player)
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

function Boundary.managedContains(boundary, x, y, z)
    return boundary ~= nil and Bitmap.containsScope(boundary.bitmap, x, y, z)
end

local function stateFor(player)
    local id = identity(player)
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

local function updatePlayer(player)
    local boundary, _, _, id = Boundary.boundaryForPlayer(player)
    if not boundary then return nil end
    local state = stateFor(player)
    if not state then return nil end
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
    local position = playerPosition(player)
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
    local active = Bitmap.isActive(boundary.bitmap, position.x, position.y, position.z)
    if active and state.lastPosition then
        local segmentOk = Bitmap.segmentValid(boundary.bitmap,
            state.lastPosition, position)
        if not segmentOk then state.invalidSegment = true end
    end
    if active and not state.invalidSegment then
        state.lastValid = copyPosition(position)
        state.lastPosition = copyPosition(position)
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

local function objectModData(object)
    local ok, data = call(object, "getModData")
    return ok and type(data) == "table" and data or nil
end

local function rvTag(object)
    local data = objectModData(object)
    if not data then return nil end
    local nested = data.RailroaderRVTest
    -- A conflicting top-level/nested owner is ambiguous.  Do not let one
    -- namespace override the other and accidentally authorize deletion of an
    -- object another mod has claimed; the build/cleanup policy is fail-open
    -- for this case.
    if data.owner ~= nil and tostring(data.owner) ~= OWNER then return nil end
    if type(nested) == "table" and nested.owner ~= nil
        and tostring(nested.owner) ~= OWNER then
        return nil
    end
    if type(nested) == "table" and tostring(nested.owner) == OWNER then
        return nested
    end
    return data.owner ~= nil and tostring(data.owner) == OWNER and data or nil
end

local function objectSquare(object)
    local ok, result = call(object, "getSquare")
    if ok and result then return result end
    return nil
end

local function objectCell(object)
    local sq = objectSquare(object)
    if sq then
        local okX, x = call(sq, "getX")
        local okY, y = call(sq, "getY")
        local okZ, z = call(sq, "getZ")
        if okX and okY and okZ then
            return integer(x), integer(y), integer(z), sq
        end
    end
    local okX, x = call(object, "getX")
    local okY, y = call(object, "getY")
    local okZ, z = call(object, "getZ")
    x, y, z = number(x), number(y), number(z)
    if x and y and z then return math.floor(x), math.floor(y), math.floor(z), sq end
    return nil
end

local function footprint(tag, x, y, z)
    if type(tag) ~= "table" or type(tag.footprint) ~= "table" then
        if tag and tag.multiTile == true then return nil end
        return { { x = x, y = y, z = z } }
    end
    local result, includesHost = {}, false
    for _, item in pairs(tag.footprint) do
        if type(item) ~= "table" then return nil end
        local fx, fy, fz = integer(item.x), integer(item.y), integer(item.z or z)
        if not fx or not fy or not fz then return nil end
        if fx == x and fy == y and fz == z then includesHost = true end
        result[#result + 1] = { x = fx, y = fy, z = fz }
    end
    -- A footprint that does not contain the object's own host cell is not
    -- proven to be an absolute world-coordinate footprint.  Treat relative,
    -- truncated, or otherwise ambiguous multi-tile metadata as fail-open.
    return #result > 0 and includesHost and result or nil
end

local function shellEdgeAllowed(boundary, tag, objectX, objectY, objectZ)
    if type(tag) ~= "table" then return false end
    local keys = {}
    if type(tag.edgeKey) == "string" then keys[#keys + 1] = tag.edgeKey end
    if type(tag.edgeKeys) == "table" then
        for _, key in pairs(tag.edgeKeys) do
            if type(key) == "string" then keys[#keys + 1] = key end
        end
    end
    for i = 1, #keys do
        local edge = boundary.shellEdges and boundary.shellEdges[keys[i]]
        if type(edge) == "table"
            and tag.owner == OWNER
            and tag.rvId ~= nil
            and tag.generation ~= nil
            and tag.bitmapVersion ~= nil
            and tostring(edge.rvId) == tostring(boundary.rvId)
            and integer(edge.generation) == boundary.generation
            and integer(edge.bitmapVersion) == boundary.bitmapVersion
            and tostring(tag.rvId) == tostring(boundary.rvId)
            and integer(tag.generation) == boundary.generation
            and integer(tag.bitmapVersion) == boundary.bitmapVersion
            and edge.replacementAllowed ~= false
            and integer(edge.objectX) == objectX
            and integer(edge.objectY) == objectY
            and integer(edge.objectZ or edge.z) == objectZ then
            return true
        end
    end
    return false
end

-- A shell object may be hosted by an inactive cell (notably the east/south
-- edges, whose PZ object tile is the adjacent cell).  If the object is at a
-- recorded shell host but its replacement edge cannot be proven from the
-- ledger, preserve it.  The build/cleanup policy is deliberately fail-open
-- for this ownership ambiguity; it must never turn an inactive host tile
-- into an unconditional object deletion rule.
local function shellHostOwnershipUnknown(boundary, objectX, objectY, objectZ)
    if type(boundary.shellEdges) ~= "table" then return false end
    for _, edge in pairs(boundary.shellEdges) do
        if type(edge) == "table"
            and integer(edge.objectX) == objectX
            and integer(edge.objectY) == objectY
            and integer(edge.objectZ or edge.z) == objectZ then
            return true
        end
    end
    return false
end

-- The sledgehammer packet identifies an object only by its authoritative
-- square coordinates and object-list index.  Keep RV wall attribution
-- separate from that packet contract: only a currently attached
-- IsoThumpable carrying the complete generated-wall identity and an exact
-- current shell-ledger entry may trigger RV-specific follow-up work.  This is
-- deliberately fail-closed for missing/ambiguous metadata.
function Boundary.isCurrentShellWall(object, boundary)
    if not object or type(boundary) ~= "table" then return false end
    local bitmap, rvId, generation, bitmapVersion = decodeBoundary(boundary)
    if not bitmap then return false end
    local typeOk, isThumpable = callGlobal("instanceof", object, "IsoThumpable")
    if not typeOk or isThumpable ~= true then return false end
    local indexOk, index = call(object, "getObjectIndex")
    if not indexOk or integer(index) == nil or integer(index) < 0 then return false end
    local x, y, z, square = objectCell(object)
    if not x or not y or not z or not square
        or not Bitmap.containsScope(bitmap, x, y, z) then
        return false
    end

    local data = objectModData(object)
    local tag = rvTag(object)
    local nested = data and data.RailroaderRVTest
    if type(data) ~= "table" or type(nested) ~= "table"
        or tag ~= nested
        or tostring(data.owner) ~= OWNER
        or tostring(nested.owner) ~= OWNER
        or tostring(data.rvId) ~= rvId
        or tostring(nested.rvId) ~= rvId
        or integer(data.generation) ~= generation
        or integer(nested.generation) ~= generation
        or integer(data.bitmapVersion) ~= bitmapVersion
        or integer(nested.bitmapVersion) ~= bitmapVersion then
        return false
    end

    local role = nested.role
    if role ~= "wall-north" and role ~= "wall-west"
        and role ~= "corner-nw" and role ~= "corner-se" then
        return false
    end
    if type(nested.edgeKey) ~= "string"
        or type(nested.axis) ~= "string" then
        return false
    end
    local expectedNorth
    local expectedSprite
    if role == "wall-north" then
        expectedNorth = true
        expectedSprite = C.SPRITES.wall.northSprite
    elseif role == "wall-west" then
        expectedNorth = false
        expectedSprite = C.SPRITES.wall.sprite
    elseif role == "corner-nw" then
        expectedNorth = true
        expectedSprite = C.SPRITES.wallNW.sprite
    else
        expectedNorth = false
        expectedSprite = C.SPRITES.wallSE.sprite
    end
    local northOk, north = call(object, "getNorth")
    local spriteOk, sprite = call(object, "getSprite")
    local spriteNameOk, spriteName = call(sprite, "getName")
    if not northOk or north ~= expectedNorth
        or not spriteOk or not spriteNameOk
        or tostring(spriteName) ~= tostring(expectedSprite) then
        return false
    end
    local edge = boundary.shellEdges and boundary.shellEdges[nested.edgeKey]
    if type(edge) ~= "table"
        or edge.edgeKey ~= nested.edgeKey
        or edge.role ~= role
        or edge.axis ~= nested.axis
        or edge.corner ~= (role == "corner-nw" or role == "corner-se")
        or edge.replacementAllowed ~= true then
        return false
    end
    return shellEdgeAllowed(boundary, nested, x, y, z)
end

local function appendShellEdgeKey(result, seen, key)
    if type(key) ~= "string" or seen[key] then return end
    seen[key] = true
    result[#result + 1] = key
end

local function shellAxisMatches(edge, axis)
    if axis == nil then return true end
    if axis == "N" then return edge.side == "north" end
    if axis == "W" then return edge.side == "west" end
    if axis == "E" then return edge.side == "east" end
    if axis == "S" then return edge.side == "south" end
    return false
end

-- Build callbacks in different PZ paths expose either the active cell that
-- owns an edge or the adjacent tile that hosts the object.  Resolve both
-- forms from the persisted ledger.  This is especially important for east
-- (W(x+1,y,z)) and south (N(x,y+1,z)) replacements; trusting one callback
-- coordinate convention would turn a legal shell replacement into an
-- unowned inactive-cell build.
local function shellEdgeKeysForAction(boundary, x, y, z, axis)
    local result, seen = {}, {}
    if type(boundary) ~= "table" or type(boundary.shellEdges) ~= "table" then
        return result
    end
    local direct
    if axis == "N" or axis == "W" then
        direct = Bitmap.edgeKey(axis, x, y, z)
    elseif axis == "E" or axis == "S" then
        direct = Bitmap.edgeForSide(axis, x, y, z)
    end
    if direct and boundary.shellEdges[direct] then
        appendShellEdgeKey(result, seen, direct)
    end
    if axis == nil then
        -- Some generic placement callbacks omit orientation.  Probe all four
        -- canonical edge keys around the supplied cell; actionMatchesObject
        -- still requires the resulting ledger edge to own the actual object
        -- host, so this cannot attribute an ordinary neighbouring build.
        local candidates = {
            Bitmap.edgeKey("N", x, y, z),
            Bitmap.edgeKey("W", x, y, z),
            Bitmap.edgeForSide("E", x, y, z),
            Bitmap.edgeForSide("S", x, y, z),
        }
        for i = 1, #candidates do
            if boundary.shellEdges[candidates[i]] then
                appendShellEdgeKey(result, seen, candidates[i])
            end
        end
    end
    for key, edge in pairs(boundary.shellEdges) do
        if type(edge) == "table" and shellAxisMatches(edge, axis)
            and integer(edge.objectX) == x
            and integer(edge.objectY) == y
            and integer(edge.objectZ or edge.z) == z then
            appendShellEdgeKey(result, seen, key)
        end
    end
    return result
end

local function actionMatchesObject(action, x, y, z)
    if type(action) ~= "table" or action.x == nil or action.y == nil
        or action.z == nil then
        return false
    end
    if action.x == x and action.y == y and action.z == z then return true end
    local keys = shellEdgeKeysForAction(action.boundary, action.x, action.y,
        action.z, action.axis)
    for i = 1, #keys do
        local edge = action.boundary.shellEdges[keys[i]]
        if type(edge) == "table"
            and integer(edge.objectX) == x
            and integer(edge.objectY) == y
            and integer(edge.objectZ or edge.z) == z then
            return true
        end
    end
    return false
end

local function sameOwner(tag, boundary)
    if type(tag) ~= "table" then return false end
    -- A boundary tag without the full identity is ambiguous.  Treat it as
    -- unowned so build audit/cleanup fail open rather than allowing an object
    -- from another RV or generation to be accepted by omitted fields.
    if tostring(tag.owner) ~= OWNER or tag.rvId == nil
        or tag.generation == nil or tag.bitmapVersion == nil then
        return false
    end
    if tostring(tag.rvId) ~= tostring(boundary.rvId) then return false end
    if integer(tag.generation) ~= boundary.generation then
        return false
    end
    if integer(tag.bitmapVersion) ~= boundary.bitmapVersion then
        return false
    end
    return true
end

local function removeObject(object, square)
    if not object or not square then return false end
    local ok, result = call(square, "transmitRemoveItemFromSquare", object)
    return ok and result ~= false
end

-- Audit only objects proven to be player-created by our low-intrusion build
-- marker.  Untagged or ambiguous objects are fail-open, preserving map and
-- other-mod content even when an RV scope overlaps another ownership record.
function Boundary.auditObject(object, player, forcedBoundary)
    local boundary = forcedBoundary
    if not boundary and player then boundary = Boundary.boundaryForPlayer(player) end
    if type(boundary) ~= "table" then return false, "no owning RV" end
    local x, y, z, sq = objectCell(object)
    if not x or not y or not z then return false, "object coordinate unavailable" end
    if not Bitmap.containsScope(boundary.bitmap, x, y, z) then
        return false, "object is outside managed scope"
    end
    local tag = rvTag(object)
    if tag and tag.owner == OWNER and not sameOwner(tag, boundary) then
        return false, "object belongs to another RV generation"
    end
    if shellEdgeAllowed(boundary, tag, x, y, z) then
        return false, "shell edge is protected by ledger"
    end
    if shellHostOwnershipUnknown(boundary, x, y, z) then
        return false, "shell host ownership is uncertain"
    end
    local cells = footprint(tag, x, y, z)
    if not cells then return false, "multi-tile footprint is unproven" end
    for i = 1, #cells do
        local cell = cells[i]
        -- Full/composite footprints must remain entirely in this one RV
        -- scope.  This check is before any removal call.
        if not Bitmap.containsScope(boundary.bitmap, cell.x, cell.y, cell.z) then
            return false, "footprint crosses managed scope"
        end
        if not Bitmap.isBuildable(boundary.bitmap, cell.x, cell.y, cell.z) then
            if not tag or tag.playerBuilt ~= true then
                return false, "inactive object ownership is uncertain"
            end
            if removeObject(object, sq) then
                return true, "removed player build outside build bitmap"
            end
            return false, "authoritative object removal failed"
        end
    end
    return false, "object is in build bitmap"
end

local function markTagPlayerBuilt(object, builder, action)
    local data = objectModData(object)
    if not data then return false end
    if data.owner ~= nil and tostring(data.owner) ~= OWNER then
        return false
    end
    local existingNamespace = data.RailroaderRVTest
    if type(existingNamespace) == "table"
        and existingNamespace.owner ~= nil
        and tostring(existingNamespace.owner) ~= OWNER then
        return false
    end
    if type(action) ~= "table" or action.rvId == nil
        or tostring(action.rvId) == "" or integer(action.generation) == nil
        or integer(action.generation) < 1
        or integer(action.bitmapVersion) ~= C.BITMAP_VERSION then
        return false
    end
    local tag = rvTag(object)
    if tag and (tostring(tag.rvId) ~= tostring(action.rvId)
        or integer(tag.generation) ~= integer(action.generation)
        or integer(tag.bitmapVersion) ~= integer(action.bitmapVersion)) then
        -- An existing tag from another RV/generation is ambiguous.  Do not
        -- overwrite it merely because a build event happened at the same
        -- coordinate; the required fail-open policy preserves the object.
        return false
    end
    if type(data.RailroaderRVTest) ~= "table" then
        data.RailroaderRVTest = {}
    end
    tag = data.RailroaderRVTest
    tag.owner = OWNER
    tag.playerBuilt = true
    tag.builder = builder and builder.key or nil
    tag.rvId = action and action.rvId or tag.rvId
    tag.generation = action and action.generation or tag.generation
    tag.bitmapVersion = action and action.bitmapVersion or tag.bitmapVersion
    -- Replace optional attribution fields exactly.  Retaining an old edge or
    -- footprint after a generation swap could make unrelated metadata appear
    -- authoritative for the current bitmap identity.
    tag.edgeKey = action.edgeKey
    tag.edgeKeys = action.edgeKeys
    tag.footprint = action.footprint
    return true
end

local function dirtyKey(action, x, y, z)
    return tostring(action.rvId) .. ":" .. tostring(action.generation) .. ":"
        .. tostring(action.bitmapVersion) .. ":" .. tostring(x) .. ":"
        .. tostring(y) .. ":" .. tostring(z)
end

function Boundary.markDirty(player, x, y, z, boundary)
    local id = identity(player)
    if not id then return false end
    boundary = boundary or Boundary.boundaryForPlayer(player)
    if not boundary or not Bitmap.containsScope(boundary.bitmap, x, y, z) then
        return false
    end
    local action = { player = player, identity = id, rvId = boundary.rvId,
        generation = boundary.generation, bitmapVersion = boundary.bitmapVersion,
        x = math.floor(x), y = math.floor(y),
        z = math.floor(z), boundary = boundary }
    local key = dirtyKey(action, action.x, action.y, action.z)
    Boundary._dirty[key] = action
    return true
end

local function commandArgument(args, key)
    if type(args) == "table" then return args[key] end
    local ok, value = call(args, "get", key)
    return ok and value or nil
end

local function commandCoordinate(args, key)
    return integer(commandArgument(args, key))
end

function Boundary.onProcessAction(actionName, player, args)
    local actionText = tostring(actionName or ""):lower()
    local placementAction = actionText == "build"
        or string.find(actionText, "build", 1, true)
        or string.find(actionText, "place", 1, true)
        or string.find(actionText, "drop", 1, true)
        or string.find(actionText, "moveable", 1, true)
    if not placementAction or not player then return end
    local x = commandCoordinate(args, "x")
    local y = commandCoordinate(args, "y")
    local z = commandCoordinate(args, "z")
    if not x or not y or not z then return end
    local boundary = Boundary.boundaryForPlayer(player)
    if not boundary or not Bitmap.containsScope(boundary.bitmap, x, y, z) then return end
    local id = identity(player)
    if not id then return end
    local item = commandArgument(args, "item")
    local action = { player = player, identity = id, rvId = boundary.rvId,
        generation = boundary.generation, bitmapVersion = boundary.bitmapVersion,
        x = x, y = y, z = z,
        boundary = boundary, footprint = commandArgument(args, "footprint"),
        expires = Boundary._tick + 2 }
    local axis = commandArgument(args, "axis")
        or commandArgument(args, "edgeAxis")
    if axis ~= "N" and axis ~= "W" and axis ~= "E" and axis ~= "S"
        and commandArgument(args, "north") ~= nil then
        axis = commandArgument(args, "north") == true and "N" or "W"
    end
    action.axis = axis
    local shellKeys = shellEdgeKeysForAction(boundary, x, y, z, axis)
    if #shellKeys == 1 then
        action.edgeKey = shellKeys[1]
    elseif #shellKeys > 1 then
        action.edgeKeys = shellKeys
    end
    -- Keep the async attribution key generation-scoped as well as
    -- player-scoped.  A replacement/generation swap must not overwrite a
    -- still-expiring build action from an older bitmap identity.
    Boundary._builders[id.key .. ":" .. boundaryKey(boundary)] = action
    Boundary.markDirty(player, x, y, z, boundary)

    -- The standard build callback may run before or after this listener.  If
    -- the builder already exposes its Java object, audit it immediately; the
    -- OnObjectAdded/dirty-cell paths remain the conservative fallback.
    local object = type(item) == "table" and item.javaObject or nil
    if not object then
        local objectOk, objectValue = call(item, "getJavaObject")
        object = objectOk and objectValue or nil
    end
    if object then
        local objectX, objectY, objectZ = objectCell(object)
        if objectX and objectY and objectZ
            and Bitmap.containsScope(boundary.bitmap, objectX, objectY, objectZ)
            and actionMatchesObject(action, objectX, objectY, objectZ)
            and markTagPlayerBuilt(object, id, action) then
            Boundary.auditObject(object, player, boundary)
        end
    end
end

function Boundary.onObjectAdded(object)
    if not object then return end
    local x, y, z = objectCell(object)
    if not x or not y or not z then return end
    local matches = {}
    for key, action in pairs(Boundary._builders) do
        if action and Boundary._tick <= (action.expires or Boundary._tick + 2)
            and actionMatchesObject(action, x, y, z) then
            local boundary = action.boundary
            local current = Boundary.boundaryForPlayer(action.player)
            if sameBoundary(current, boundary)
                and Bitmap.containsScope(boundary.bitmap, x, y, z) then
                matches[#matches + 1] = action
            end
        end
    end
    -- Two players can complete a placement at the same host cell in one
    -- server window.  Without a standard owner event, attribution is
    -- ambiguous, so leave the object untagged/fail-open instead of deleting
    -- another player's or another RV's object.
    if #matches ~= 1 then return end
    local action = matches[1]
    local boundary = action.boundary
    if markTagPlayerBuilt(object, action.identity, action) then
        Boundary.auditObject(object, action.player, boundary)
        Boundary.markDirty(action.player, x, y, z, boundary)
    end
end

local function collectionSnapshot(collection)
    local result = {}
    if collection == nil then return result end
    local sizeOk, size = call(collection, "size")
    size = sizeOk and integer(size) or nil
    if size ~= nil then
        for i = 0, size - 1 do
            local ok, object = call(collection, "get", i)
            if ok and object then result[#result + 1] = object end
        end
    elseif type(collection) == "table" then
        for _, object in pairs(collection) do
            if object then result[#result + 1] = object end
        end
    end
    return result
end

local function squareObjects(square)
    local result, seen = {}, {}
    local names = { "getObjects", "getSpecialObjects", "getWorldObjects",
        "getStaticMovingObjects", "getMovingObjects", "getDeadBodys" }
    for i = 1, #names do
        local ok, collection = call(square, names[i])
        if ok then
            for _, object in ipairs(collectionSnapshot(collection)) do
                if not seen[object] then seen[object] = true; result[#result + 1] = object end
            end
        end
    end
    local floorOk, floor = call(square, "getFloor")
    if floorOk and floor and not seen[floor] then result[#result + 1] = floor end
    return result
end

local function flushDirty()
    for key, action in pairs(Boundary._dirty) do
        Boundary._dirty[key] = nil
        local cell = playerCell(action.player)
        local current = Boundary.boundaryForPlayer(action.player)
        if cell and action.boundary and action.identity
            and sameBoundary(current, action.boundary) then
            local sq = square(cell, action.x, action.y, action.z)
            if sq then
                for _, object in ipairs(squareObjects(sq)) do
                    Boundary.auditObject(object, action.player, action.boundary)
                end
            end
        end
    end
end

local function onlinePlayersSnapshot()
    local result = {}
    local ok, players = callGlobal("getOnlinePlayers")
    if ok and players then
        local sizeOk, size = call(players, "size")
        size = sizeOk and integer(size) or nil
        if size ~= nil then
            for i = 0, size - 1 do
                local playerOk, player = call(players, "get", i)
                if playerOk and player then result[#result + 1] = player end
            end
        elseif type(players) == "table" then
            for _, player in pairs(players) do if player then result[#result + 1] = player end end
        end
    end
    if #result == 0 then
        local playerOk, player = callGlobal("getPlayer")
        if player then result[1] = player end
    end
    return result
end

local function cleanupForBoundary(boundary, player)
    local key = boundaryKey(boundary)
    local cursor = Boundary._cleanups[key]
    if not cursor then
        cursor = { player = player, boundary = boundary,
            x = boundary.bitmap.originX, y = boundary.bitmap.originY,
            z = boundary.bitmap.minZ }
        Boundary._cleanups[key] = cursor
    else
        -- Any online member of this RV can provide the authoritative cell;
        -- do not restart a shared cursor when player iteration order changes.
        cursor.player = player
        cursor.boundary = boundary
    end
    local cell = playerCell(player)
    if not cell then return end
    local budget = 128
    local bitmap = boundary.bitmap
    while budget > 0 and cursor.z < bitmap.maxZ do
        if cursor.y >= bitmap.originY + bitmap.height then
            cursor.x, cursor.y = bitmap.originX, bitmap.originY
            cursor.z = cursor.z + 1
        elseif cursor.x >= bitmap.originX + bitmap.width then
            cursor.x, cursor.y = bitmap.originX, cursor.y + 1
        else
            local sq = square(cell, cursor.x, cursor.y, cursor.z)
            -- Leave the cursor on an unloaded square.  Advancing past it would
            -- make the bounded cleanup silently skip that cell forever, while
            -- forcing a load would violate the RV-local, already-loaded-only
            -- cleanup contract.
            if not sq then return end
            for _, object in ipairs(squareObjects(sq)) do
                Boundary.auditObject(object, nil, boundary)
            end
            cursor.x = cursor.x + 1
            budget = budget - 1
        end
    end
    if cursor.z >= bitmap.maxZ then Boundary._cleanups[key] = nil end
end

function Boundary.onTick()
    Boundary._tick = Boundary._tick + 1
    local players = onlinePlayersSnapshot()
    local activeBoundaries = {}
    for i = 1, #players do
        local player = players[i]
        local id = identity(player)
        if id then
            local state = stateFor(player)
            -- Roof relocation owns the player's boundary lease while the
            -- authoritative object is intentionally in a different chunk.
            -- Do not revalidate RV geometry or run cleanup through the remote
            -- player's cell; those scans can stall the server tick before the
            -- grouped roof state machine reaches its due ticks.  The lease is
            -- extended by RV_Server before this callback and normal boundary
            -- processing resumes after completeTransition.
            if not state or not transitionActive(state) then
                local boundary = updatePlayer(player)
                if boundary then
                    activeBoundaries[boundaryKey(boundary)] = {
                        boundary = boundary, player = player,
                    }
                end
            end
        end
    end
    flushDirty()
    if Boundary._tick % (integer(C.BOUNDARY_TICK_INTERVAL) or 1) == 0 then
        for _, item in pairs(activeBoundaries) do cleanupForBoundary(item.boundary, item.player) end
    end
    for key, builder in pairs(Boundary._builders) do
        if not builder or Boundary._tick > (builder.expires or 0) then
            Boundary._builders[key] = nil
        end
    end
end

return Boundary
