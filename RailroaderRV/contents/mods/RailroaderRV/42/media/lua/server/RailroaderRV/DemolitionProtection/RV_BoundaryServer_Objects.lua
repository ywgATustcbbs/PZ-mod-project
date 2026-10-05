-- RV_BoundaryServer: Objects responsibilities.
return function(ctx)
local Boundary = ctx.Boundary
local Core = ctx.Core
local C = ctx.C
local OWNER = ctx.OWNER
local number = ctx.number
local integer = ctx.integer
local call = ctx.call
local identity = ctx.identity
local square = ctx.square
local Common = require("RailroaderRV/Common/RV_Common")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local TemplateGeometry = require("RailroaderRV/RoomTemplate/RV_TemplateGeometry")
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local templateObjects = RoomTemplate.orderedObjects(Template)

local function objectModData(object)
    local ok, data = call(object, "getModData")
    return ok and type(data) == "table" and data or nil
end

-- The one canonical tag namespace owns the identity.  An object without it is
-- ordinary world content; a foreign owner is not ours to act on.
local function rvTag(object)
    local data = objectModData(object)
    local tag = data and data.RailroaderRV or nil
    if type(tag) ~= "table" or tostring(tag.owner) ~= OWNER then
        return nil
    end
    return tag
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

local function shellEdgeHasTemplateIndex(edge, templateIndex)
    if type(edge) ~= "table" or type(edge.templateIndices) ~= "table" then
        return false
    end
    local count = 0
    for key in pairs(edge.templateIndices) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key
            or key > #edge.templateIndices then
            return false
        end
    end
    if count ~= #edge.templateIndices or #edge.templateIndices < 1
        or integer(edge.templateIndices[1]) ~= integer(edge.templateIndex) then
        return false
    end
    for i = 1, #edge.templateIndices do
        if integer(edge.templateIndices[i]) == integer(templateIndex) then return true end
    end
    return false
end

local function shellEdgeAllowed(boundary, tag, objectX, objectY, objectZ)
    if type(tag) ~= "table" then return false end
    local managed = type(boundary) == "table" and boundary.managed or nil
    local originX = type(managed) == "table" and integer(managed.originX) or nil
    local originY = type(managed) == "table" and integer(managed.originY) or nil
    local anchor = TemplateGeometry.anchorFromManaged(managed, Template)
    if not originX or not originY or not anchor then return false end
    -- The canonical tag names exactly one shell edge, and `captured` is the
    -- compiled template entry named by `templateIndex`; the tag stores no copy
    -- of the entry's attributes.
    local edge = type(tag.edgeKey) == "string" and boundary.shellEdges
        and boundary.shellEdges[tag.edgeKey] or nil
    local captured = templateObjects[integer(tag.templateIndex)]
    if type(edge) == "table"
        and tag.owner == OWNER
        and tag.rvId ~= nil
        and tag.generation ~= nil
        and tostring(edge.rvId) == tostring(boundary.rvId)
        and integer(edge.generation) == boundary.generation
        and tostring(tag.rvId) == tostring(boundary.rvId)
        and integer(tag.generation) == boundary.generation
        and edge.replacementAllowed ~= false
        and shellEdgeHasTemplateIndex(edge, tag.templateIndex)
        and captured ~= nil
        and captured.north == edge.north
        and edge.role == tag.role
        and captured.x == objectX - anchor.x
        and captured.y == objectY - anchor.y
        and captured.z == objectZ - anchor.z
        and integer(edge.objectX) == objectX
        and integer(edge.objectY) == objectY
        and integer(edge.objectZ or edge.z) == objectZ then
        return true
    end
    return false
end

-- The sledgehammer packet identifies an object only by its authoritative
-- square coordinates and object-list index.  Keep RV wall attribution
-- separate from that packet contract: only a currently attached captured
-- shell member (wall, railing, door, or window) with the complete generated
-- identity and an exact current shell-ledger entry may trigger RV follow-up work. This is
-- deliberately fail-closed for missing/ambiguous metadata.
function Boundary.isCurrentShellWall(object, boundary)
    if not object or type(boundary) ~= "table" then return false end
    -- The reader supplies the boundary for the current identity; only the
    -- identity fields and the authored managed/edge ledger are consumed here.
    local current = boundary
    if type(current.rvId) ~= "string" or current.rvId == ""
        or integer(current.generation) == nil or integer(current.generation) < 1
        or type(current.managed) ~= "table"
        or type(current.shellEdges) ~= "table" then
        return false
    end
    local isThumpable = Common.classInstance(object, "IsoThumpable")
    local isWindow = Common.classInstance(object, "IsoWindow")
    if not isThumpable and not isWindow then
        return false
    end
    local indexOk, index = call(object, "getObjectIndex")
    if not indexOk or integer(index) == nil or integer(index) < 0 then return false end
    local x, y, z, square = objectCell(object)
    if not x or not y or not z or not square
        or not TemplateGeometry.inManagedRegion({ x = x, y = y, z = z },
            current.managed) then
        return false
    end

    local tag = rvTag(object)
    if tag == nil or tostring(tag.rvId) ~= current.rvId
        or integer(tag.generation) ~= current.generation then
        return false
    end

    local role = tag.role
    if role ~= "wall-north" and role ~= "wall-west"
        and role ~= "corner-nw" then
        return false
    end
    if type(tag.edgeKey) ~= "string" or integer(tag.templateIndex) == nil then
        return false
    end
    -- The compiled template entry named by `templateIndex` is the only source of
    -- the authored attributes; the tag stores no copy of them.
    local captured = templateObjects[integer(tag.templateIndex)]
    local expectedNorth = captured and captured.north
    local expectedSprite = captured and captured.sprite
    local expectedRole = expectedNorth and "wall-north" or "wall-west"
    if tag.role == "corner-nw" then expectedRole = "corner-nw" end
    if not captured
        or (captured.class ~= "IsoThumpable" and captured.class ~= "IsoWindow")
        or role ~= expectedRole then
        return false
    end
    local northOk, north = call(object, "getNorth")
    local spriteOk, sprite = call(object, "getSprite")
    local spriteNameOk, spriteName = call(sprite, "getName")
    local directions = rawget(_G, "IsoDirections")
    local expectedDirection = directions and directions[captured.direction]
    local directionOk, direction = call(object, "getDir")
    local nameOk, name = call(object, "getName")
    if not northOk or north ~= expectedNorth
        or not spriteOk or not spriteNameOk
        or tostring(spriteName) ~= tostring(expectedSprite)
        or not nameOk or tostring(name) ~= tostring(captured.name)
        or not expectedDirection or not directionOk or direction ~= expectedDirection then
        return false
    end
    local edge = boundary.shellEdges and boundary.shellEdges[tag.edgeKey]
    if type(edge) ~= "table"
        or edge.edgeKey ~= tag.edgeKey
        or edge.role ~= role
        or edge.corner ~= (role == "corner-nw")
        or not shellEdgeHasTemplateIndex(edge, tag.templateIndex)
        or edge.north ~= expectedNorth
        or edge.replacementAllowed ~= true then
        return false
    end
    return shellEdgeAllowed(boundary, tag, x, y, z)
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
        direct = TemplateGeometry.edgeKey(axis, x, y, z)
    elseif axis == "E" or axis == "S" then
        direct = TemplateGeometry.edgeForSide(axis, x, y, z)
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
            TemplateGeometry.edgeKey("N", x, y, z),
            TemplateGeometry.edgeKey("W", x, y, z),
            TemplateGeometry.edgeForSide("E", x, y, z),
            TemplateGeometry.edgeForSide("S", x, y, z),
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

-- A player build needs one fact only: whether it belongs to the current RV
-- generation.  It carries no template entry, so its tag is written as one
-- canonical namespace holding exactly that membership.
local function markTagPlayerBuilt(object, builder, action)
    local data = objectModData(object)
    if not data then return false end
    if type(action) ~= "table" or action.rvId == nil
        or tostring(action.rvId) == "" or integer(action.generation) == nil
        or integer(action.generation) < 1 then
        return false
    end
    local tag = rvTag(object)
    if tag and (tostring(tag.rvId) ~= tostring(action.rvId)
        or integer(tag.generation) ~= integer(action.generation)) then
        -- An existing tag from another RV/generation is ambiguous.  Do not
        -- overwrite it merely because a build event happened at the same
        -- coordinate; the required fail-open policy preserves the object.
        return false
    end
    if tag and tag.playerBuilt ~= true then
        -- Never convert a generated template member or the native generator
        -- into an attributed player build just because an add callback shares
        -- its square.
        return false
    end
    data.RailroaderRV = {
        owner = OWNER,
        playerBuilt = true,
        builder = builder and builder.key or nil,
        rvId = action.rvId,
        generation = action.generation,
        -- Optional attribution of the accepted action, replaced exactly: a
        -- stale edge or footprint must never appear authoritative.
        edgeKey = action.edgeKey,
        edgeKeys = action.edgeKeys,
        footprint = action.footprint,
    }
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

-- The short-lived async action ledger belongs to DemolitionProtection.
local BuilderActionLedger = { actions = {} }

function BuilderActionLedger.prune(tick)
    if type(tick) ~= "number" then return false end
    for key, action in pairs(BuilderActionLedger.actions) do
        local expires = type(action) == "table" and action.expires or nil
        if type(expires) ~= "number" or tick > expires then
            BuilderActionLedger.actions[key] = nil
        end
    end
    return true
end

function BuilderActionLedger.invalidateForGeneration(rvId, generation)
    local expectedRvId = rvId ~= nil and tostring(rvId) or nil
    local expectedGeneration = integer(generation)
    if not expectedRvId or expectedRvId == "" or not expectedGeneration
        or expectedGeneration < 1 then
        return false
    end
    for key, action in pairs(BuilderActionLedger.actions) do
        if type(action) ~= "table"
            or tostring(action.rvId) == expectedRvId
                and integer(action.generation) ~= expectedGeneration then
            BuilderActionLedger.actions[key] = nil
        end
    end
    return true
end

function BuilderActionLedger.submit(key, action)
    if type(key) ~= "string" or key == "" or type(action) ~= "table"
        or type(action.expires) ~= "number" then
        return false
    end
    BuilderActionLedger.actions[key] = action
    return true
end

function BuilderActionLedger.uniqueCandidate(object, x, y, z, tick)
    if not BuilderActionLedger.prune(tick) then return nil end
    local candidate = nil
    for _, action in pairs(BuilderActionLedger.actions) do
        if type(action) == "table" and actionMatchesObject(action, x, y, z) then
            local boundary = action.boundary
            local current = Boundary.boundaryForPlayer(action.player)
            if type(current) == "table"
                and tostring(current.rvId) == tostring(boundary.rvId)
                and integer(current.generation) == integer(boundary.generation)
                and TemplateGeometry.inManagedRegion({ x = x, y = y, z = z },
                    boundary.managed) then
                if candidate ~= nil then return nil end
                candidate = action
            end
        end
    end
    return candidate
end

function BuilderActionLedger.objectMatchConsumed(action, object)
    return type(action) == "table" and type(action.matchedObjects) == "table"
        and action.matchedObjects[object] == true
end

function BuilderActionLedger.consumeObjectMatch(action, object)
    if type(action) ~= "table" or object == nil then return false end
    local matchedObjects = action.matchedObjects
    if type(matchedObjects) ~= "table" then
        matchedObjects = {}
        action.matchedObjects = matchedObjects
    end
    if matchedObjects[object] then return false end
    matchedObjects[object] = true
    return true
end

Boundary.builderActionLedger = BuilderActionLedger

function Boundary.onProcessAction(actionName, player, args)
    BuilderActionLedger.prune(Boundary._tick)
    local actionText = tostring(actionName or ""):lower()
    local placementAction = actionText == "build"
        or string.find(actionText, "build", 1, true)
        or string.find(actionText, "place", 1, true)
        or string.find(actionText, "moveable", 1, true)
    if not placementAction or not player then return end
    local x = commandCoordinate(args, "x")
    local y = commandCoordinate(args, "y")
    local z = commandCoordinate(args, "z")
    if not x or not y or not z then return end
    local boundary = Boundary.boundaryForPlayer(player)
    if not boundary or not TemplateGeometry.inManagedRegion({
        x = x, y = y, z = z,
    }, boundary.managed) then return end
    local id = identity(player)
    if not id then return end
    local item = commandArgument(args, "item")
    local action = { player = player, identity = id, rvId = boundary.rvId,
        generation = boundary.generation,
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
    -- Only a server-validated build intent can authorize attribution. If the
    -- later object-added callback cannot match this intent uniquely, the
    -- object stays untagged and the repair queue deliberately preserves it.
    -- Keep the async attribution key generation-scoped as well as
    -- player-scoped. A replacement build cannot reuse a stale action.
    BuilderActionLedger.invalidateForGeneration(boundary.rvId,
        boundary.generation)
    BuilderActionLedger.submit(id.key .. ":"
        .. tostring(boundary.rvId) .. ":" .. tostring(boundary.generation), action)

    -- The standard build callback may run before or after this listener. If
    -- the builder already exposes its Java object, tag it for the bounded
    -- proximity queue; do not start another world scan from this callback.
    local object = type(item) == "table" and item.javaObject or nil
    if not object then
        local objectOk, objectValue = call(item, "getJavaObject")
        object = objectOk and objectValue or nil
    end
    if object then
        local objectX, objectY, objectZ = objectCell(object)
        if objectX and objectY and objectZ
            and TemplateGeometry.inManagedRegion({
                x = objectX, y = objectY, z = objectZ,
            }, boundary.managed)
            and actionMatchesObject(action, objectX, objectY, objectZ) then
            markTagPlayerBuilt(object, id, action)
        end
    end
end

function Boundary.onObjectAdded(object)
    if not object then return end
    BuilderActionLedger.prune(Boundary._tick)
    local x, y, z = objectCell(object)
    if not x or not y or not z then return end
    -- Automatic deletion later requires both this unique action correlation
    -- and the resulting current-generation playerBuilt tag. Ambiguous or
    -- untagged additions are intentionally preserved to protect map objects.
    -- Two players can complete a placement at the same host cell in one
    -- server window.  Without a standard owner event, attribution is
    -- ambiguous, so leave the object untagged/fail-open instead of deleting
    -- another player's or another RV's object.
    local action = BuilderActionLedger.uniqueCandidate(object, x, y, z,
        Boundary._tick)
    if not action then return end
    if BuilderActionLedger.objectMatchConsumed(action, object) then return end
    if markTagPlayerBuilt(object, action.identity, action) then
        BuilderActionLedger.consumeObjectMatch(action, object)
    end
    -- The 3x3 proximity queue classifies this tagged object within its
    -- one-cell-per-tick budget.
end


end
