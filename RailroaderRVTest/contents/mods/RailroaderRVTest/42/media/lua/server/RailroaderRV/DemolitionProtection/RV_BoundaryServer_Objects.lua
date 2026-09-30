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
local currentBoundary = ctx.currentBoundary
local boundaryKey = ctx.boundaryKey
local sameBoundary = ctx.sameBoundary
local Common = require("RailroaderRV/Common/RV_Common")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local TemplateGeometry = require("RailroaderRV/RoomTemplate/RV_TemplateGeometry")
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local templateObjects = RoomTemplate.orderedObjects(Template)
local templateValid, templateError = RoomTemplate.validate(Template)
if not templateValid or type(templateObjects) ~= "table" then
    error("RailroaderRVTest: current boundary RoomTemplate is invalid: "
        .. tostring(templateError or "ordered object index is incomplete"))
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
    local keys = {}
    if type(tag.edgeKey) == "string" then keys[#keys + 1] = tag.edgeKey end
    if type(tag.edgeKeys) == "table" then
        for _, key in pairs(tag.edgeKeys) do
            if type(key) == "string" then keys[#keys + 1] = key end
        end
    end
    for i = 1, #keys do
        local edge = boundary.shellEdges and boundary.shellEdges[keys[i]]
        local captured = type(tag) == "table" and templateObjects[
            integer(tag.templateIndex)] or nil
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
            and captured ~= nil and captured.class == tag.templateClass
            and captured.name == tag.templateName
            and captured.sprite == tag.templateSprite
            and captured.north == tag.templateNorth
            and captured.direction == tag.templateDirection
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
-- separate from that packet contract: only a currently attached captured
-- shell member (wall, railing, door, or window) with the complete generated
-- identity and an exact current shell-ledger entry may trigger RV follow-up work. This is
-- deliberately fail-closed for missing/ambiguous metadata.
function Boundary.isCurrentShellWall(object, boundary)
    if not object or type(boundary) ~= "table" then return false end
    local current = currentBoundary(boundary)
    if not current then return false end
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

    local data = objectModData(object)
    local tag = rvTag(object)
    local nested = data and data.RailroaderRVTest
    if type(data) ~= "table" or type(nested) ~= "table"
        or tag ~= nested
        or tostring(data.owner) ~= OWNER
        or tostring(nested.owner) ~= OWNER
        or tostring(data.rvId) ~= current.rvId
        or tostring(nested.rvId) ~= current.rvId
        or integer(data.generation) ~= current.generation
        or integer(nested.generation) ~= current.generation then
        return false
    end

    local role = nested.role
    if role ~= "wall-north" and role ~= "wall-west"
        and role ~= "corner-nw" then
        return false
    end
    if type(nested.edgeKey) ~= "string" or type(nested.axis) ~= "string"
        or integer(nested.templateIndex) == nil then
        return false
    end
    local captured = templateObjects[integer(nested.templateIndex)]
    local expectedNorth = captured and captured.north
    local expectedSprite = captured and captured.sprite
    local expectedRole = expectedNorth and "wall-north" or "wall-west"
    if nested.role == "corner-nw" then expectedRole = "corner-nw" end
    if not captured
        or (captured.class ~= "IsoThumpable" and captured.class ~= "IsoWindow")
        or captured.name ~= nested.templateName
        or captured.sprite ~= nested.templateSprite
        or captured.north ~= nested.templateNorth
        or captured.direction ~= nested.templateDirection
        or role ~= expectedRole
        or nested.templateClass ~= captured.class then
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
    local edge = boundary.shellEdges and boundary.shellEdges[nested.edgeKey]
    if type(edge) ~= "table"
        or edge.edgeKey ~= nested.edgeKey
        or edge.role ~= role
        or edge.axis ~= nested.axis
        or edge.corner ~= (role == "corner-nw")
        or not shellEdgeHasTemplateIndex(edge, nested.templateIndex)
        or edge.north ~= nested.templateNorth
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

local function sameOwner(tag, boundary)
    if type(tag) ~= "table" then return false end
    -- A boundary tag without the full identity is ambiguous.  Treat it as
    -- unowned so build audit/cleanup fail open rather than allowing an object
    -- from another RV or generation to be accepted by omitted fields.
    if tostring(tag.owner) ~= OWNER or tag.rvId == nil
        or tag.generation == nil then
        return false
    end
    if tostring(tag.rvId) ~= tostring(boundary.rvId) then return false end
    if integer(tag.generation) ~= boundary.generation then
        return false
    end
    return true
end

local function removeObject(object, square)
    if not object or not square then return false end
    local ok, result = call(square, "transmitRemoveItemFromSquare", object)
    return ok and result ~= false
end

local function protectedWorldObject(object)
    local classes = { "IsoWorldInventoryObject", "IsoPlayer", "IsoZombie",
        "IsoAnimal", "IsoDeadBody", "BaseVehicle" }
    for i = 1, #classes do
        if Common.classInstance(object, classes[i]) then return true end
    end
    return false
end

local function disallowedPlayerBuild(object, boundary)
    if not object or type(boundary) ~= "table" or protectedWorldObject(object) then
        return false
    end
    local current = currentBoundary(boundary)
    if not current then return false end
    local x, y, z, sq = objectCell(object)
    if not x or not y or not z or not sq
        or not TemplateGeometry.inManagedRegion({ x = x, y = y, z = z },
            current.managed) then
        return false
    end
    local tag = rvTag(object)
    if type(tag) ~= "table" or tag.owner ~= OWNER or tag.playerBuilt ~= true
        or tostring(tag.rvId) ~= current.rvId
        or integer(tag.generation) ~= current.generation
        or shellEdgeAllowed(boundary, tag, x, y, z) then
        return false
    end
    local cells = footprint(tag, x, y, z)
    if not cells then return false end
    local anchor = TemplateGeometry.anchorFromManaged(current.managed, Template)
    if not anchor then return false end
    local buildableOnly = true
    for i = 1, #cells do
        local cell = cells[i]
        if not TemplateGeometry.inManagedRegion(cell, current.managed) then
            return false
        end
        if not TemplateGeometry.isBuildable(cell, anchor, Template) then
            buildableOnly = false
        end
    end
    if buildableOnly then return false end
    return true, sq
end

function Boundary.isDisallowedPlayerBuild(object, boundary)
    local remove = disallowedPlayerBuild(object, boundary)
    return remove == true
end

-- Audit only objects proven to be player-created by our low-intrusion build
-- marker.  Untagged or ambiguous objects are fail-open, preserving map and
-- other-mod content even when an RV scope overlaps another ownership record.
function Boundary.auditObject(object, player, forcedBoundary)
    local boundary = forcedBoundary
    if not boundary and player then boundary = Boundary.boundaryForPlayer(player) end
    if type(boundary) ~= "table" then return false, "no owning RV" end
    local remove, removalSquare = disallowedPlayerBuild(object, boundary)
    if remove then
        if removeObject(object, removalSquare) then
            return true, "removed player build outside cab protection"
        end
        return false, "authoritative object removal failed"
    end
    local x, y, z, sq = objectCell(object)
    if not x or not y or not z then return false, "object coordinate unavailable" end
    if not TemplateGeometry.inManagedRegion({ x = x, y = y, z = z },
        boundary.managed) then
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
        if not TemplateGeometry.inManagedRegion(cell, boundary.managed) then
            return false, "footprint crosses managed scope"
        end
        local anchor = TemplateGeometry.anchorFromManaged(boundary.managed,
            Template)
        if not anchor or not TemplateGeometry.isBuildable(cell, anchor, Template) then
            return false, "inactive object ownership is uncertain"
        end
    end
    return false, "object is in a template build cell"
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
    if type(data.RailroaderRVTest) ~= "table" then
        data.RailroaderRVTest = {}
    end
    tag = data.RailroaderRVTest
    tag.owner = OWNER
    tag.playerBuilt = true
    tag.role = nil
    tag.templateIndex = nil
    tag.templateClass = nil
    tag.templateName = nil
    tag.templateSprite = nil
    tag.templateNorth = nil
    tag.templateDirection = nil
    tag.edgeKey = nil
    tag.axis = nil
    data.role = nil
    tag.builder = builder and builder.key or nil
    tag.rvId = action and action.rvId or tag.rvId
    tag.generation = action and action.generation or tag.generation
    -- Replace optional attribution fields exactly.  Retaining an old edge or
    -- footprint after a generation swap could make unrelated metadata appear
    -- authoritative for the current generation.
    tag.edgeKey = action.edgeKey
    tag.edgeKeys = action.edgeKeys
    tag.footprint = action.footprint
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

-- The short-lived async action ledger belongs to DemolitionProtection. The
-- Boundary facade exposes only the tick-prune and generation-invalidation
-- operations needed by its sibling components.
local BuilderActionLedger = { actions = {} }

function BuilderActionLedger.prune(tick)
    if not Core.isTick(tick) then return false end
    for key, action in pairs(BuilderActionLedger.actions) do
        local expires = type(action) == "table" and action.expires or nil
        if not Core.isTick(expires) or Core.tickCompare(tick, expires) == 1 then
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
        or not Core.isTick(action.expires) then
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
            if sameBoundary(current, boundary)
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

function Boundary.pruneBuilderActionLedger(tick)
    return BuilderActionLedger.prune(tick)
end

function Boundary.invalidateBuilderActionsForGeneration(rvId, generation)
    return BuilderActionLedger.invalidateForGeneration(rvId, generation)
end

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
        expires = Core.tickAdd(Boundary._tick, 2) }
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
    BuilderActionLedger.submit(id.key .. ":" .. boundaryKey(boundary), action)

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
