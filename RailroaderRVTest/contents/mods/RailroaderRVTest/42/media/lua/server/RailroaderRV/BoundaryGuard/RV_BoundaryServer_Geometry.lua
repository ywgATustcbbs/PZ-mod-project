-- RV_BoundaryServer: Geometry responsibilities.
return function(ctx)
local processIsServer = ctx.processIsServer
local Boundary = ctx.Boundary
local Core = ctx.Core
local C = ctx.C
local TemplateGeometry = require("RailroaderRV/RoomTemplate/RV_TemplateGeometry")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
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

-- One-shot server-side notice for rejected RV data. The GUI already consumes
-- this stable failure code and shows the delete-and-rebuild instruction, so the
-- diagnostic reason stays server-side.
function Boundary.diagnoseGuardState(player, knownIdentity, position, relation,
    record, reason)
    if not processIsServer() or type(position) ~= "table" then
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

-- Derive only the managed region bounds and the authored shell edge ledger.
-- Walkability and buildability are queried from the captured template.
local function makeBoundary(layout, rvId, generation)
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

-- Managed bounds and shell edges are pure functions of the compiled template
-- and the record's slot index.  Nothing in this file persists them; readers
-- query the current template here instead of trusting a stored copy.  One
-- memoized boundary per slot keeps record validation, construction, the
-- sentinel and roof refresh from rebuilding the layout on every call.
local boundariesBySlot = {}
local function boundaryFor(record)
    if type(record) ~= "table" then return nil end
    local rvId = type(record.locoId) == "string" and record.locoId or nil
    local generation = integer(record.generation)
    local slotIndex = integer(record.slotIndex)
    if not rvId or rvId == "" or not generation or generation < 1
        or not slotIndex then
        return nil
    end
    local anchor = RegionSlots.indexToAnchor(slotIndex)
    if not anchor then return nil end
    -- One template layout per anchor; the compiled template never changes at
    -- runtime, so the derived boundary may be reused for this identity.
    local cached = boundariesBySlot[slotIndex]
    if cached and cached.rvId == rvId and cached.generation == generation then
        return cached
    end
    local layout = Layout.make(anchor.x, anchor.y, anchor.z)
    local derived = makeBoundary(layout, rvId, generation)
    if type(derived) ~= "table" then return nil end
    boundariesBySlot[slotIndex] = derived
    return derived
end
Boundary.boundaryFor = boundaryFor

function Boundary.boundaryForPlayer(player, knownIdentity, deferValidationMiss,
    forceValidationRefresh)
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
        forceValidationRefresh == true)
    if hookOk and boundary == nil and record == "validation-deferred" then
        return nil, record
    end
    local current = hookOk and boundary or nil
    local anchor = current and TemplateGeometry.anchorFromManaged(current.managed,
        Template) or nil
    -- The manifest only carries the current identity; its geometry comes from
    -- the template, so compare the derived anchor rather than a stored copy.
    if not current or type(record) ~= "table" or type(relation) ~= "table"
        or type(validatedIdentity) ~= "table"
        or validatedIdentity.key ~= id.key
        or type(manifest) ~= "table"
        or tostring(manifest.rvId) ~= tostring(record.locoId)
        or integer(manifest.generation) ~= integer(record.generation)
        or tostring(current.rvId) ~= tostring(record.locoId)
        or current.generation ~= integer(record.generation)
        or not anchor then
        return nil
    end
    return current, record, relation, validatedIdentity, manifest
end

local function stateFor(player, knownIdentity)
    local id = knownIdentity or identity(player)
    if not id then return nil end
    local state = Boundary._states[id.key]
    if not state then
        state = { identity = id, inside = false, corrections = 0 }
        Boundary._states[id.key] = state
    else
        state.identity = id
    end
    return state
end

function Boundary.beginTransition(player, rvId, generation, token, kind)
    if rvId == nil or tostring(rvId) == "" or integer(generation) == nil
        or integer(generation) < 1 then
        return false
    end
    local state = stateFor(player)
    if not state then return false end
    state.rvId = tostring(rvId)
    state.generation = integer(generation)
    state.leaseToken = type(token) == "string" and token or nil
    state.leaseUntil = Boundary._tick
        + (integer(C.BOUNDARY_TRANSITION_TIMEOUT_TICKS) or 120)
    return true
end

function Boundary.completeTransition(player, token)
    local state = stateFor(player)
    if not state then return false end
    if token ~= nil and state.leaseToken ~= token then return false end
    state.leaseToken = nil
    state.leaseUntil = Boundary._tick + 2
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
    if not state or type(state.leaseToken) ~= "string"
        or state.leaseToken ~= token then
        return false
    end
    if type(untilTick) ~= "number" then return false end
    if type(state.leaseUntil) ~= "number"
        or untilTick > state.leaseUntil then
        state.leaseUntil = untilTick
    end
    return true
end

function Boundary.clearPlayer(player)
    local id = identity(player)
    if id then
        Boundary._states[id.key] = nil
    end
    return true
end

-- Single read-only transition query. TemplateRecovery asks it per queue
-- identity; the state table stays private and no listener is notified.
function Boundary.transitionActive(identityKey)
    if type(identityKey) ~= "string" then return false end
    local separator = string.find(identityKey, ":", 1, true)
    if not separator then return false end
    local rvId = string.sub(identityKey, 1, separator - 1)
    local generation = integer(string.sub(identityKey, separator + 1))
    if rvId == "" or not generation or generation < 1 then return false end
    for _, state in pairs(Boundary._states) do
        if type(state) == "table" and tostring(state.rvId) == rvId
            and integer(state.generation) == generation then
            if type(state.leaseToken) ~= "string" then return false end
            if type(state.leaseUntil) == "number"
                and state.leaseUntil >= Boundary._tick then
                return true
            end
            state.leaseToken, state.leaseUntil = nil, nil
            return false
        end
    end
    return false
end

-- A correction must use a fresh position that agrees with the server's loaded
-- current square. Missing or stale square state leaves the player untouched.
local function currentSquareMatches(player, position)
    local ok, current = call(player, "getCurrentSquare")
    if not ok or current == nil then return false end
    local okX, x = call(current, "getX")
    local okY, y = call(current, "getY")
    local okZ, z = call(current, "getZ")
    if not okX or not okY or not okZ then return false end
    return integer(x) == math.floor(position.x)
        and integer(y) == math.floor(position.y)
        and integer(z) == math.floor(position.z)
end

-- Return the validated current boundary and mapping record for a player who is
-- authoritatively inside this RV, or nil.
local function guardContextForPlayer(player, position, knownIdentity,
    deferValidationMiss)
    local boundary, record, relation, id = Boundary.boundaryForPlayer(player,
        knownIdentity, deferValidationMiss, false)
    if not boundary or type(record) ~= "table" or type(id) ~= "table" then
        return nil
    end
    local currentOnlineId = integer(id.onlineId)
    local relationOnlineId = type(relation) == "table"
        and integer(relation.onlineId) or nil
    local rider = type(record.players) == "table"
        and record.players[id.username] or nil
    if currentOnlineId == nil
        or type(relation) ~= "table" or relation.inside ~= true
        or tostring(relation.locoId) ~= tostring(record.locoId)
        or relationOnlineId ~= currentOnlineId
        or type(rider) ~= "table" or rider.inside ~= true
        or integer(rider.onlineId) ~= currentOnlineId then
        return nil
    end
    if type(position) ~= "table" or not currentSquareMatches(player, position) then
        return nil
    end
    return boundary, record, relationOnlineId
end

ctx.number = number
ctx.integer = integer
ctx.call = call
ctx.callGlobal = callGlobal
ctx.identity = identity
ctx.playerPosition = playerPosition
ctx.playerCell = playerCell
ctx.square = square
ctx.stateFor = stateFor
ctx.guardContextForPlayer = guardContextForPlayer
end
