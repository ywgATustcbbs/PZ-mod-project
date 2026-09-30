-- RV_BoundaryServer: Geometry responsibilities.
return function(ctx)
local processIsServer = ctx.processIsServer
local Boundary = ctx.Boundary
local Core = ctx.Core
local C = ctx.C
local TemplateGeometry = require("RailroaderRV/RoomTemplate/RV_TemplateGeometry")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)

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

local function encodeShellEdges(source, rvId, generation)
    local result = {}
    if type(source) ~= "table" then return result end
    for key, edge in pairs(source) do
        if type(edge) == "table" and type(key) == "string" then
            result[key] = {
                edgeKey = key,
                rvId = tostring(rvId), generation = generation,
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

-- Persist only the managed region bounds and the authored shell edge ledger.
-- Walkability and buildability are queried from the captured template.
function Boundary.makeBoundary(layout, rvId, generation)
    if type(layout) ~= "table" or type(layout.managed) ~= "table"
        or type(layout.shellEdges) ~= "table" then
        return nil, "layout geometry is unavailable"
    end
    if rvId == nil or tostring(rvId) == ""
        or integer(generation) == nil or integer(generation) < 1 then
        return nil, "boundary identity is incomplete"
    end
    local source = layout.managed
    local managed = {
        originX = integer(source.originX), originY = integer(source.originY),
        width = integer(source.width), height = integer(source.height),
        minZ = integer(source.minZ), maxZ = integer(source.maxZ),
    }
    if not TemplateGeometry.anchorFromManaged(managed, Template)
        or managed.maxZ <= managed.minZ then
        return nil, "managed region bounds are invalid"
    end
    return {
        rvId = tostring(rvId), generation = integer(generation),
        managed = managed,
        shellEdges = encodeShellEdges(layout.shellEdges, rvId,
            integer(generation)),
    }
end

local function currentBoundary(boundary)
    if type(boundary) ~= "table" or type(boundary.managed) ~= "table"
        or type(boundary.shellEdges) ~= "table" then
        return nil
    end
    local rvId = type(boundary.rvId) == "string" and boundary.rvId or nil
    local generation = integer(boundary.generation)
    if not rvId or rvId == "" or not generation or generation < 1
        or not TemplateGeometry.anchorFromManaged(boundary.managed, Template) then
        return nil
    end
    return boundary
end

local function boundaryKey(boundary)
    return tostring(boundary.rvId) .. ":" .. tostring(boundary.generation)
end

local function sameBoundary(left, right)
    return type(left) == "table" and type(right) == "table"
        and boundaryKey(left) == boundaryKey(right)
end

local function geometryChanged()
    Boundary._geometryEpoch = (integer(Boundary._geometryEpoch) or 0) + 1
end

local function loadedBoundary(boundary)
    return currentBoundary(boundary)
end

function Boundary.registerGeneration(rvId, generation, boundary, record)
    local loaded = loadedBoundary(boundary)
    if not loaded then return false end
    if rvId == nil or tostring(rvId) ~= loaded.rvId
        or integer(generation) ~= loaded.generation then
        return false
    end
    if record and (tostring(record.rvId) ~= tostring(rvId)
        or integer(record.generation) ~= loaded.generation
        or record.boundary ~= boundary) then
        return false
    end
    geometryChanged()
    if type(Boundary.invalidateBuilderActionsForGeneration) == "function" then
        Boundary.invalidateBuilderActionsForGeneration(loaded.rvId,
            loaded.generation)
    end
    return true
end

function Boundary.boundaryForPlayer(player, knownIdentity, deferValidationMiss,
    forceValidationRefresh, roofRefreshContextRead, roofRefreshGuardRead)
    local id = knownIdentity or identity(player)
    if not id then return nil end
    -- The Railroader adapter checks the player's current mapping and manifest
    -- identity; this module validates only the managed bounds it needs locally.
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
    local current = hookOk and currentBoundary(boundary) or nil
    local anchor = current and TemplateGeometry.anchorFromManaged(current.managed,
        Template) or nil
    if not current or type(record) ~= "table" or type(relation) ~= "table"
        or type(validatedIdentity) ~= "table"
        or validatedIdentity.key ~= id.key
        or type(manifest) ~= "table" or type(manifest.anchor) ~= "table"
        or tostring(manifest.rvId) ~= tostring(record.rvId)
        or integer(manifest.generation) ~= integer(record.generation)
        or tostring(current.rvId) ~= tostring(record.rvId)
        or current.generation ~= integer(record.generation)
        or integer(manifest.anchor.x) ~= anchor.x
        or integer(manifest.anchor.y) ~= anchor.y
        or integer(manifest.anchor.z) ~= anchor.z then
        return nil
    end
    return current, record, relation, validatedIdentity, manifest
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

local function transitionIdentityKey(rvId, generation)
    local normalizedGeneration = integer(generation)
    if rvId == nil or tostring(rvId) == "" or normalizedGeneration == nil
        or normalizedGeneration < 1 then
        return nil
    end
    return tostring(rvId) .. ":" .. tostring(normalizedGeneration)
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
            local key = transitionIdentityKey(state.rvId, state.generation)
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

function Boundary.hasActiveTransitionForIdentity(rvId, generation, tick)
    local key = transitionIdentityKey(rvId, generation)
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

function Boundary.beginTransition(player, rvId, generation, token, kind)
    if rvId == nil or tostring(rvId) == "" or integer(generation) == nil
        or integer(generation) < 1 then
        return false
    end
    local state = stateFor(player)
    if not state then return false end
    state.rvId = rvId and tostring(rvId) or nil
    state.generation = integer(generation)
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
-- extension instead.  This changes no mapping state and fails closed
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
    local anchor = TemplateGeometry.anchorFromManaged(boundary.managed, Template)
    if not target or not anchor
        or not TemplateGeometry.isWalkable(target, anchor, Template) then
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
        sequence = state.correctionSequence,
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
        or state.generation ~= boundary.generation then
        state.rvId, state.generation = boundary.rvId, boundary.generation
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
    local anchor = TemplateGeometry.anchorFromManaged(boundary.managed, Template)
    return {
        position = position,
        managed = boundary.managed,
        anchor = anchor,
        boundary = boundary,
        spawnIdentity = { rvId = boundary.rvId, generation = boundary.generation },
        expectedSpawn = record.rvPosition,
        preparePullback = function()
            return prepareCorrection(player, boundary, state, record.rvPosition)
        end,
        notifyPullback = function(payload)
            notifyCorrection(player, payload)
        end,
    }
end

ctx.number = number
ctx.integer = integer
ctx.call = call
ctx.callGlobal = callGlobal
ctx.identity = identity
ctx.playerPosition = playerPosition
ctx.playerCell = playerCell
ctx.square = square
ctx.currentBoundary = currentBoundary
ctx.boundaryKey = boundaryKey
ctx.sameBoundary = sameBoundary
ctx.stateFor = stateFor
ctx.transitionActive = transitionActive
ctx.guardContextForPlayer = guardContextForPlayer
end
