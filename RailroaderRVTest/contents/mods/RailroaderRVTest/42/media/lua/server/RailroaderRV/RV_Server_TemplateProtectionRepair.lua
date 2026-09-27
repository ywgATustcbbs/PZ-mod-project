-- RV_Server: proximity-queued, authoritative template correction.
return function(ctx)
local Boundary = ctx.Boundary
local Constants = ctx.Constants
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local Bitmap = require("RailroaderRV/RV_Bitmap")
local manifestTable = ctx.manifestTable
local requireCurrentManifest = ctx.requireCurrentManifest
local createCapturedTemplateObject = ctx.createCapturedTemplateObject
local configureCapturedDoorFrame = ctx.configureCapturedDoorFrame
local createGenerator = ctx.createGenerator
local Template = require("RailroaderRV/RV_Template")
local ProtectionManifest = require("RailroaderRV/RV_ProtectionManifest")

if not Boundary or type(ServerWorld) ~= "table"
    or type(ServerWorld.objectModData) ~= "function"
    or type(ServerWorld.removeGenericObject) ~= "function"
    or type(ServerWorld.squareContainsObject) ~= "function"
    or type(ServerWorld.isPlayerObject) ~= "function"
    or type(ServerWorld.isVehicleObject) ~= "function"
    or type(manifestTable) ~= "function"
    or type(requireCurrentManifest) ~= "function"
    or type(createCapturedTemplateObject) ~= "function"
    or type(configureCapturedDoorFrame) ~= "function"
    or type(createGenerator) ~= "function"
    or Template.schemaVersion ~= Constants.CAPTURED_TEMPLATE_VERSION
    or Template.objectCount ~= 412 or #Template.objects ~= 412
    or not ProtectionManifest.validateTemplate(Template) then
    error("RailroaderRVTest: current template-protection-repair dependencies are incomplete")
end

local queues = {}
local templateProtectionRepairIndexes = {}
local configuredDoorFrames = setmetatable({}, { __mode = "k" })
local capturedClasses = {}
for i = 1, #Template.objects do
    local captured = Template.objects[i]
    capturedClasses[captured.class] = true
end
local sampleInterval = ServerUtil.toNumber(
    Constants.TEMPLATE_PROTECTION_REPAIR_SAMPLE_INTERVAL_TICKS)
if not sampleInterval or sampleInterval < 1
    or math.floor(sampleInterval) ~= sampleInterval then
    error("RailroaderRVTest: proximity template-guard limits are invalid")
end
-- This is a practical streaming grace window, not a measured engine optimum.
-- Keep it local to the independent template-protection subsystem.
local transitionReturnGraceTicks = 100
local lastServedQueueKey = nil
local recentTemplateProtectionRemovals = setmetatable({}, { __mode = "k" })
local recentTemplateProtectionRemovalsByPosition = {}
local templateProtectionRemovalTraceSerial = 0

local function removeTemplateProtectionRepairObject(square, object)
    local server = RV and RV.Server
    if type(server) ~= "table" then
        return false, "template protection repair removal marker is unavailable"
    end
    templateProtectionRemovalTraceSerial = templateProtectionRemovalTraceSerial + 1
    local traceId = templateProtectionRemovalTraceSerial
    local xOk, x = ServerUtil.invoke(object, "getX")
    local yOk, y = ServerUtil.invoke(object, "getY")
    local zOk, z = ServerUtil.invoke(object, "getZ")
    local position = (xOk and tostring(x) or "?") .. ","
        .. (yOk and tostring(y) or "?") .. ","
        .. (zOk and tostring(z) or "?")
    local globalRV = rawget(_G, "RailroaderRV")
    local globalServer = globalRV and globalRV.Server
    local previousObject = server._templateProtectionRepairRemovalObject
    server._templateProtectionRepairRemovalObject = object
    local removalTrace = {
        traceId = traceId,
        position = position,
        expiresAt = (type(Boundary._tick) == "number"
            and Boundary._tick or 0) + 2,
    }
    recentTemplateProtectionRemovals[object] = removalTrace
    recentTemplateProtectionRemovalsByPosition[position] = removalTrace
    print("[RailroaderRVTest][TemplateProtectionTrace] path=remove.begin"
        .. " traceId=" .. tostring(traceId)
        .. " position=" .. position
        .. " localGlobalServerSame=" .. tostring(server == globalServer)
        .. " markerSameTarget=" .. tostring(
            server._templateProtectionRepairRemovalObject == object))
    local removeOk, removeResult = pcall(ServerWorld.removeGenericObject,
        square, object, false)
    print("[RailroaderRVTest][TemplateProtectionTrace] path=remove.return"
        .. " traceId=" .. tostring(traceId)
        .. " position=" .. position
        .. " removeOk=" .. tostring(removeOk)
        .. " markerStillSameTarget=" .. tostring(
            server._templateProtectionRepairRemovalObject == object)
        .. " globalServerSame=" .. tostring(
            globalServer == (rawget(_G, "RailroaderRV") or {}).Server))
    server._templateProtectionRepairRemovalObject = previousObject
    return removeOk, removeResult
end

local function integer(value)
    local number = ServerUtil.toNumber(value)
    if type(number) ~= "number" or number ~= number
        or number <= -math.huge or number >= math.huge
        or math.floor(number) ~= number then
        return nil
    end
    return number
end

local function isVisualCornerTemplate(entry)
    return type(entry) == "table"
        and entry.class == "IsoObject"
        and entry.name == "Wooden Wall"
        and entry.sprite == "walls_interior_house_02_35"
end

local function isTemplateFloorObject(entry)
    return type(entry) == "table" and entry.class == "IsoObject"
        and not isVisualCornerTemplate(entry)
end

local function sameIdentity(left, right)
    return type(left) == "table" and type(right) == "table"
        and tostring(left.rvId) == tostring(right.rvId)
        and integer(left.generation) == integer(right.generation)
        and integer(left.bitmapVersion) == integer(right.bitmapVersion)
end

local function queueKey(boundary, record)
    if type(boundary) ~= "table" or type(record) ~= "table"
        or not sameIdentity(boundary, record) or boundary.rvId == nil
        or tostring(boundary.rvId) == "" then
        return nil
    end
    local generation = integer(boundary.generation)
    local bitmapVersion = integer(boundary.bitmapVersion)
    if not generation or generation < 1 or not bitmapVersion then return nil end
    return tostring(boundary.rvId) .. ":" .. tostring(generation)
        .. ":" .. tostring(bitmapVersion)
end

local function columnKey(x, y)
    return tostring(x) .. ":" .. tostring(y)
end

local function coordinateKey(x, y, z)
    return tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
end

local function repairIdentityKey(rvId, generation, bitmapVersion)
    local currentGeneration = integer(generation)
    local currentBitmapVersion = integer(bitmapVersion)
    if rvId == nil or tostring(rvId) == "" or not currentGeneration
        or currentGeneration < 1 or not currentBitmapVersion then
        return nil
    end
    return tostring(rvId) .. ":" .. tostring(currentGeneration)
        .. ":" .. tostring(currentBitmapVersion)
end

local function clearQueuedIdentity(identityKey)
    if type(identityKey) ~= "string" then return end
    queues[identityKey] = nil
end

local transitionPauseUntil = Boundary._templateProtectionRepairPauseUntil
if type(transitionPauseUntil) ~= "table" then
    transitionPauseUntil = {}
    Boundary._templateProtectionRepairPauseUntil = transitionPauseUntil
end
local previousActiveTransitions =
    Boundary._templateProtectionRepairActiveTransitions
if type(previousActiveTransitions) ~= "table" then
    previousActiveTransitions = {}
    Boundary._templateProtectionRepairActiveTransitions =
        previousActiveTransitions
end

local function isIdentityPaused(identityKey, tick)
    if type(identityKey) ~= "string" then return false end
    if previousActiveTransitions[identityKey] == true then return true end
    tick = integer(tick)
    if tick == nil then return false end
    local untilTick = integer(transitionPauseUntil[identityKey])
    if untilTick == nil then return false end
    if integer(tick) <= untilTick then return true end
    transitionPauseUntil[identityKey] = nil
    return false
end

-- Observe Boundary's authoritative transition states before Sweep asks
-- transitionActive(), which may retire a timed-out token. A completed token
-- keeps a two-tick state stamp; that stamp starts the final 100-tick grace.
-- This does not alter RoofRefresh transactions or their completion rules.
function Boundary.observeTemplateProtectionRepairTransitions(tick)
    tick = integer(tick)
    if tick == nil or type(Boundary._states) ~= "table" then return false end

    local activeIdentities, recentlyCompleted = {}, {}
    for _, state in pairs(Boundary._states) do
        if type(state) == "table" then
            local key = repairIdentityKey(state.rvId, state.generation,
                state.bitmapVersion)
            local transitionUntil = integer(state.transitionUntil)
            local inWindow = transitionUntil ~= nil and tick <= transitionUntil
            if key and inWindow then
                if state.transitionToken ~= nil
                    or state.transitionKind ~= nil then
                    activeIdentities[key] = true
                else
                    recentlyCompleted[key] = true
                end
            end
        end
    end

    for key in pairs(activeIdentities) do
        -- Any member still in flight keeps every player's repair queue for
        -- this RV identity suspended and discards work sampled before travel.
        transitionPauseUntil[key] = nil
        clearQueuedIdentity(key)
    end

    for key in pairs(previousActiveTransitions) do
        if not activeIdentities[key] then
            previousActiveTransitions[key] = nil
            transitionPauseUntil[key] = tick + transitionReturnGraceTicks
            clearQueuedIdentity(key)
        end
    end

    for key in pairs(recentlyCompleted) do
        if not activeIdentities[key] then
            local requestedUntil = tick + transitionReturnGraceTicks
            if requestedUntil > (transitionPauseUntil[key] or 0) then
                transitionPauseUntil[key] = requestedUntil
            end
            clearQueuedIdentity(key)
        end
    end

    for key in pairs(activeIdentities) do
        previousActiveTransitions[key] = true
    end
    for key in pairs(transitionPauseUntil) do
        if tick > transitionPauseUntil[key] then
            transitionPauseUntil[key] = nil
        end
    end
    for position, removalTrace in pairs(
        recentTemplateProtectionRemovalsByPosition) do
        if tick > (removalTrace.expiresAt or 0) then
            recentTemplateProtectionRemovalsByPosition[position] = nil
        end
    end
    return true
end

local function identityHasActiveTransition(identityKey, tick)
    if type(Boundary._states) ~= "table" then return false end
    for _, state in pairs(Boundary._states) do
        if type(state) == "table"
            and repairIdentityKey(state.rvId, state.generation,
                state.bitmapVersion) == identityKey
            and (state.transitionToken ~= nil or state.transitionKind ~= nil)
            and (integer(state.transitionUntil) or -math.huge) >= tick then
            return true
        end
    end
    return false
end

local function onBoundaryTransitionLifecycle(eventName, player, state, tick)
    if type(state) ~= "table" then return end
    local key = repairIdentityKey(state.rvId, state.generation,
        state.bitmapVersion)
    tick = integer(tick) or integer(Boundary._tick) or 0
    if not key then return end
    if eventName == "begin" then
        previousActiveTransitions[key] = true
        transitionPauseUntil[key] = nil
        clearQueuedIdentity(key)
        return
    end
    if eventName ~= "complete" and eventName ~= "clear"
        and eventName ~= "timeout" then
        return
    end
    if identityHasActiveTransition(key, tick) then
        previousActiveTransitions[key] = true
        transitionPauseUntil[key] = nil
    else
        previousActiveTransitions[key] = nil
        transitionPauseUntil[key] = tick + transitionReturnGraceTicks
    end
    clearQueuedIdentity(key)
end

if type(Boundary.addTransitionLifecycleListener) == "function" then
    Boundary.addTransitionLifecycleListener("TemplateProtectionRepair",
        onBoundaryTransitionLifecycle)
end

local function loadedColumnForCell(cell, boundary, x, y)
    if not cell then return false end
    for z = boundary.bitmap.minZ, boundary.bitmap.maxZ - 1 do
        local chunkOk, chunk = ServerUtil.invoke(cell,
            "getChunkForGridSquare", x, y, z)
        if not chunkOk or not chunk then return false end
        local loadedOk, loaded = pcall(function() return chunk.loaded end)
        if not loadedOk or loaded ~= true then return false end
    end
    return true
end

local function loadedColumnForPlayer(player, boundary, x, y)
    local cellOk, cell = pcall(ServerWorld.getCellForPlayer, player)
    return cellOk and loadedColumnForCell(cell, boundary, x, y)
end

local function objectTag(object)
    local data = ServerWorld.objectModData(object)
    if type(data) ~= "table" then return nil end
    local nested = data.RailroaderRVTest
    if type(nested) ~= "table"
        or data.owner ~= Constants.MOD_ID
        or nested.owner ~= Constants.MOD_ID
        or tostring(data.rvId) ~= tostring(nested.rvId)
        or integer(data.generation) ~= integer(nested.generation)
        or integer(data.bitmapVersion) ~= integer(nested.bitmapVersion)
        or data.role ~= nested.role then
        return nil
    end
    return nested
end

local function registerTemplateProtectionRemovalTrace()
    if Boundary._templateProtectionRemovalTraceRegistered then return end
    local events = rawget(_G, "Events")
    local event = events and events.OnObjectAboutToBeRemoved
    if not event or type(event.Add) ~= "function" then return end
    event.Add(function(object)
        local tracked = recentTemplateProtectionRemovals[object]
        local xOk, x = ServerUtil.invoke(object, "getX")
        local yOk, y = ServerUtil.invoke(object, "getY")
        local zOk, z = ServerUtil.invoke(object, "getZ")
        local eventPosition = (xOk and tostring(x) or "?") .. ","
            .. (yOk and tostring(y) or "?") .. ","
            .. (zOk and tostring(z) or "?")
        local positionMatch = recentTemplateProtectionRemovalsByPosition[
            eventPosition]
        local globalRV = rawget(_G, "RailroaderRV")
        local globalServer = globalRV and globalRV.Server
        local localServer = RV and RV.Server
        local globalMarker = type(globalServer) == "table"
            and globalServer._templateProtectionRepairRemovalObject or nil
        local localMarker = type(localServer) == "table"
            and localServer._templateProtectionRepairRemovalObject or nil
        local tagOk, tag = pcall(objectTag, object)
        if not tagOk then tag = nil end
        if tracked or positionMatch or globalMarker ~= nil
            or localMarker ~= nil or tag ~= nil then
            print("[RailroaderRVTest][TemplateProtectionTrace] path=objectAboutToBeRemoved"
                .. " trackedRemoval=" .. tostring(tracked ~= nil)
                .. " positionMatch=" .. tostring(positionMatch ~= nil)
                .. " traceId=" .. tostring(tracked and tracked.traceId
                    or positionMatch and positionMatch.traceId or "nil")
                .. " eventPosition=" .. eventPosition
                .. " globalMarkerPresent=" .. tostring(globalMarker ~= nil)
                .. " globalMarkerSameEventObject=" .. tostring(
                    globalMarker == object)
                .. " localGlobalServerSame=" .. tostring(
                    localServer == globalServer)
                .. " localMarkerPresent=" .. tostring(localMarker ~= nil)
                .. " localMarkerSameEventObject=" .. tostring(
                    localMarker == object)
                .. " taggedTemplateIndex=" .. tostring(
                    tag and tag.templateIndex or "nil")
                .. " taggedRole=" .. tostring(tag and tag.role or "nil"))
        end
        if tracked then recentTemplateProtectionRemovals[object] = nil end
        if positionMatch then
            recentTemplateProtectionRemovalsByPosition[eventPosition] = nil
        end
    end)
    Boundary._templateProtectionRemovalTraceRegistered = true
end

registerTemplateProtectionRemovalTrace()

local function validCurrentContext(player, expectedBoundary)
    if not player or type(Boundary.boundaryForPlayer) ~= "function" then
        return false, "current RV boundary validation is unavailable"
    end
    local boundaryOk, boundary, record, relation, identity = pcall(
        Boundary.boundaryForPlayer, player)
    if not boundaryOk or type(boundary) ~= "table"
        or type(record) ~= "table" or type(relation) ~= "table"
        or type(identity) ~= "table" or type(identity.key) ~= "string"
        or (expectedBoundary and boundary ~= expectedBoundary) then
        return false, "player is not mapped to the current RV generation"
    end
    local manifestOk, manifest = pcall(manifestTable)
    if not manifestOk or type(manifest) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local schemaOk = pcall(requireCurrentManifest, manifest, false)
    if not schemaOk or manifest.state ~= "READY" or manifest.phase ~= "COMMITTED"
        or not sameIdentity(manifest, boundary)
        or not sameIdentity(manifest.boundary, boundary)
        or not sameIdentity(record, boundary)
        or manifest.templateVersion ~= Constants.CAPTURED_TEMPLATE_VERSION
        or type(manifest.bounds) ~= "table"
        or manifest.bounds.schemaVersion ~= Constants.LAYOUT_SCHEMA_VERSION then
        return false, Constants.INVALID_RV_DATA
    end
    local region, bitmap = record.region, boundary.bitmap
    if type(region) ~= "table" or type(bitmap) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local regionMinX, regionMinY = integer(region.minX), integer(region.minY)
    local regionMaxX, regionMaxY = integer(region.maxX), integer(region.maxY)
    local regionMinZ, regionMaxZ = integer(region.minZ), integer(region.maxZ)
    local originX, originY = integer(bitmap.originX), integer(bitmap.originY)
    local width, height = integer(bitmap.width), integer(bitmap.height)
    local bitmapMinZ, bitmapMaxZ = integer(bitmap.minZ), integer(bitmap.maxZ)
    if not regionMinX or not regionMinY or not regionMaxX or not regionMaxY
        or not regionMinZ or not regionMaxZ or not originX or not originY
        or not width or not height or not bitmapMinZ or not bitmapMaxZ
        or regionMinX ~= originX or regionMinY ~= originY
        or regionMaxX ~= originX + width or regionMaxY ~= originY + height
        or regionMinZ ~= bitmapMinZ or regionMaxZ ~= bitmapMaxZ then
        return false, Constants.INVALID_RV_DATA
    end
    return true, boundary, record, manifest, identity
end

local function isCabCoordinate(x, y, anchor)
    if type(anchor) ~= "table" then return false end
    local anchorX, anchorY = integer(anchor.x), integer(anchor.y)
    if not anchorX or not anchorY then return false end
    local offsetX, offsetY = x - anchorX, y - anchorY
    return offsetX >= Constants.CAB_MIN_OFFSET_X
        and offsetX <= Constants.CAB_MAX_OFFSET_X
        and offsetY >= Constants.CAB_MIN_OFFSET_Y
        and offsetY <= Constants.CAB_MAX_OFFSET_Y
end

local function isCabSideHostCoordinate(x, y, z, index)
    if integer(z) ~= integer(index.anchorZ) then return false end
    local offsetX, offsetY = x - index.anchorX, y - index.anchorY
    local eastHost = offsetX == Constants.CAB_MAX_OFFSET_X + 1
        and offsetY >= Constants.CAB_MIN_OFFSET_Y
        and offsetY <= Constants.CAB_MAX_OFFSET_Y
    local southHost = offsetY == Constants.CAB_MAX_OFFSET_Y + 1
        and offsetX >= Constants.CAB_MIN_OFFSET_X
        and offsetX <= Constants.CAB_MAX_OFFSET_X
    return eastHost or southHost
end

local function isRuntimeDoorOrWindow(object)
    if ServerUtil.classInstance(object, "IsoDoor")
        or ServerUtil.classInstance(object, "IsoWindow") then
        return true
    end
    if not ServerUtil.classInstance(object, "IsoThumpable") then return false end
    local doorOk, door = ServerUtil.invoke(object, "isDoor")
    local windowOk, window = ServerUtil.invoke(object, "isWindow")
    return doorOk and door == true or windowOk and window == true
end

local function isCabSideDoorOrWindow(object, x, y, z, index)
    return isCabSideHostCoordinate(x, y, z, index)
        and isRuntimeDoorOrWindow(object)
end

local function templateEntry(templateIndex, anchor)
    local expected = ProtectionManifest.worldEntry(templateIndex, anchor)
    if not expected or not ProtectionManifest.matchesLayoutEntry(templateIndex,
        expected, anchor) then
        error("RailroaderRVTest: static protection class is missing at index "
            .. tostring(templateIndex))
    end
    return expected
end

local function expectedEdgeMap(manifest)
    local result = {}
    local edges = manifest.boundary and manifest.boundary.shellEdges
    if type(edges) ~= "table" then return nil end
    for key, edge in pairs(edges) do
        if type(key) ~= "string" or type(edge) ~= "table"
            or edge.edgeKey ~= key or not sameIdentity(edge, manifest) then
            return nil
        end
        if edge.side ~= "north" and edge.side ~= "south"
            and edge.side ~= "east" and edge.side ~= "west" then
            return nil
        end
        local parts = edge.templateIndices
        if type(parts) ~= "table" or #parts < 1
            or integer(parts[1]) ~= integer(edge.templateIndex) then
            return nil
        end
        local seen = {}
        for i = 1, #parts do
            local index = integer(parts[i])
            if not index or index < 1 or index > Template.objectCount
                or seen[index] or result[index] ~= nil then
                return nil
            end
            seen[index] = true
            result[index] = edge
        end
    end
    return result
end

local function buildRepairIndex(boundary, manifest)
    local edges = expectedEdgeMap(manifest)
    local anchor = manifest and manifest.anchor
    if not edges or type(anchor) ~= "table"
        or not integer(anchor.x) or not integer(anchor.y)
        or not integer(anchor.z) then
        return nil
    end
    local index = {
        rvId = tostring(boundary.rvId),
        generation = integer(boundary.generation),
        bitmapVersion = integer(boundary.bitmapVersion),
        anchorX = integer(anchor.x),
        anchorY = integer(anchor.y),
        anchorZ = integer(anchor.z),
        edges = edges,
        byColumn = {},
        byCoordinate = {},
        protectedCoordinates = {},
        cabEditableCoordinates = {},
        reportedSafetyBlocks = {},
        reportedIdentityBlocks = {},
    }
    for offsetX = Constants.CAB_MIN_OFFSET_X, Constants.CAB_MAX_OFFSET_X do
        for offsetY = Constants.CAB_MIN_OFFSET_Y, Constants.CAB_MAX_OFFSET_Y do
            local x, y, z = index.anchorX + offsetX,
                index.anchorY + offsetY, index.anchorZ
            if not Bitmap.isBuildable(boundary.bitmap, x, y, z) then
                return nil
            end
            index.cabEditableCoordinates[coordinateKey(x, y, z)] = true
        end
    end
    for templateIndex = 1, ProtectionManifest.OBJECT_COUNT do
        local protection = ProtectionManifest.get(templateIndex)
        if not protection then return nil end
        local expected = templateEntry(templateIndex, anchor)
        local edge = edges[templateIndex]
        local protectionClass = expected.protectionClass
        if protectionClass == ProtectionManifest.SPECIAL then
            return nil
        end
        local protected = protectionClass == ProtectionManifest.RESTORE_ONLY
            or protectionClass == ProtectionManifest.PROHIBITED
        local editableCab = expected.z == anchor.z
            and isCabCoordinate(expected.x, expected.y, anchor)
        local sideDoorOrWindow = isCabSideHostCoordinate(expected.x,
            expected.y, expected.z, index)
            and (expected.class == "IsoDoor" or expected.class == "IsoWindow")
        if protected and not editableCab and not sideDoorOrWindow then
            local column = columnKey(expected.x, expected.y)
            local coordinate = coordinateKey(expected.x, expected.y, expected.z)
            local target = { expected = expected, edge = edge }
            local columnTargets = index.byColumn[column]
            if not columnTargets then
                columnTargets = {}
                index.byColumn[column] = columnTargets
            end
            columnTargets[#columnTargets + 1] = target
            local coordinateTargets = index.byCoordinate[coordinate]
            if not coordinateTargets then
                coordinateTargets = {}
                index.byCoordinate[coordinate] = coordinateTargets
            end
            coordinateTargets[#coordinateTargets + 1] = target
            index.protectedCoordinates[coordinate] = true
        end
    end
    return index
end

local function objectMatchesCapturedIdentity(object, entry)
    if not ServerUtil.classInstance(object, entry.class) then return false end
    local nameOk, name = ServerUtil.invoke(object, "getName")
    local directionOk, direction = ServerUtil.invoke(object, "getDir")
    local directionTable = rawget(_G, "IsoDirections")
    local expectedDirection = directionTable and directionTable[entry.direction]
    if not nameOk or tostring(name) ~= tostring(entry.name)
        or not directionOk or not expectedDirection or direction ~= expectedDirection
        or tostring(ServerWorld.getSpriteName(object)) ~= tostring(entry.sprite) then
        return false
    end
    if entry.north ~= nil then
        local northOk, north = ServerUtil.invoke(object, "getNorth")
        if not northOk or north ~= entry.north then return false end
    end
    return true
end

local function objectMatchesCaptured(object, entry)
    if not objectMatchesCapturedIdentity(object, entry) then return false end
    local stateGetters = {
        health = "getHealth", maxHealth = "getMaxHealth",
        hoppable = "isHoppable", locked = "isLocked",
        canPassThrough = "isCanPassThrough",
        blockAllTheSquare = "isBlockAllTheSquare",
        doRender = "getDoRender", thumpable = "isThumpable",
    }
    for key, expected in pairs(entry.state or {}) do
        local getter = stateGetters[key]
        if not getter then return false end
        local stateOk, state = ServerUtil.invoke(object, getter)
        if not stateOk or state ~= expected then return false end
    end
    return true
end

local function objectClassName(object)
    local classOk, class = ServerUtil.invoke(object, "getClass")
    if not classOk or not class then return nil end
    local textOk, text = pcall(tostring, class)
    if not textOk or type(text) ~= "string" or text == "" then return nil end
    text = string.gsub(text, "^class%s+", "")
    return string.match(text, "([^%.]+)$") or text
end

local function isBloodOrSplat(object)
    local className = objectClassName(object)
    if type(className) == "string" then
        local lowered = string.lower(className)
        if string.find(lowered, "blood", 1, true)
            or string.find(lowered, "splat", 1, true) then
            return true
        end
    end
    local sprite = ServerWorld.getSpriteName(object)
    if type(sprite) == "string"
        and string.find(string.lower(sprite), "blood", 1, true) then
        return true
    end
    local nameOk, name = ServerUtil.invoke(object, "getName")
    return nameOk and type(name) == "string"
        and (string.find(string.lower(name), "blood", 1, true) ~= nil
            or string.find(string.lower(name), "splat", 1, true) ~= nil)
end

local function protectedWorldObject(object)
    if ServerWorld.isPlayerObject(object) or ServerWorld.isVehicleObject(object) then
        return true
    end
    local classes = { "IsoWorldInventoryObject", "IsoZombie", "IsoAnimal",
        "IsoDeadBody" }
    for i = 1, #classes do
        if ServerUtil.classInstance(object, classes[i]) then return true end
    end
    return isBloodOrSplat(object)
end

local function hasStoredContainerItems(object, className)
    local knownContainer = className == "IsoThumpable"
        or ServerUtil.classInstance(object, "IsoThumpable")
    local countOk, rawCount = ServerUtil.invoke(object, "getContainerCount")
    if countOk then
        local count = integer(rawCount)
        if not count then return true end
        if count > 1 then return true end
    elseif knownContainer then
        return true
    end
    local containerOk, container = ServerUtil.invoke(object, "getContainer")
    if not containerOk then return knownContainer end
    if not container then return false end
    local itemsOk, items = ServerUtil.invoke(container, "getItems")
    if not itemsOk or not items then return true end
    local sizeOk, rawSize = ServerUtil.invoke(items, "size")
    local size = sizeOk and integer(rawSize) or nil
    return not size or size > 0
end

local function hasTemplateFloorTarget(targets)
    for i = 1, #targets do
        if isTemplateFloorObject(targets[i].expected) then return true end
    end
    return false
end

local function hasTemplateIsoObjectTarget(targets)
    for i = 1, #targets do
        if targets[i].expected.class == "IsoObject" then return true end
    end
    return false
end

local function objectAtCoordinate(object, x, y, z)
    local xOk, objectX = ServerUtil.invoke(object, "getX")
    local yOk, objectY = ServerUtil.invoke(object, "getY")
    local zOk, objectZ = ServerUtil.invoke(object, "getZ")
    return xOk and yOk and zOk and integer(objectX) == x
        and integer(objectY) == y and integer(objectZ) == z
end

local function isCabEditableCoordinate(x, y, z, index)
    return z == integer(index.anchorZ)
        and index.cabEditableCoordinates[coordinateKey(x, y, z)] == true
end

local function isRemovalScopeCoordinate(boundary, index, x, y, z)
    return Bitmap.containsScope(boundary.bitmap, x, y, z)
        and not isCabEditableCoordinate(x, y, z, index)
end

local function footprintAllowsRemoval(tag, boundary, index, x, y, z)
    if type(tag) ~= "table" then return true end
    local footprint = tag.footprint
    if tag.multiTile == true and type(footprint) ~= "table" then return false end
    if type(footprint) ~= "table" then return true end
    local count, hostSeen, seen = 0, false, {}
    for key, item in pairs(footprint) do
        if type(key) ~= "number" or key < 1 or math.floor(key) ~= key
            or key > #footprint or type(item) ~= "table" then
            return false
        end
        local fx, fy = integer(item.x), integer(item.y)
        local fz = integer(item.z == nil and z or item.z)
        if not fx or not fy or not fz
            or not isRemovalScopeCoordinate(boundary, index, fx, fy, fz) then
            return false
        end
        local coordinate = coordinateKey(fx, fy, fz)
        if seen[coordinate] then return false end
        seen[coordinate] = true
        if fx == x and fy == y and fz == z then hostSeen = true end
        count = count + 1
    end
    return count == #footprint and count > 0 and hostSeen
end

local function objectFootprintAllowsRemoval(object, boundary, index, x, y, z)
    local data = ServerWorld.objectModData(object)
    if type(data) ~= "table" then return true end
    local nested = data.RailroaderRVTest
    if not footprintAllowsRemoval(data, boundary, index, x, y, z) then
        return false
    end
    return type(nested) ~= "table"
        or footprintAllowsRemoval(nested, boundary, index, x, y, z)
end

local function reportUnsafeRemoval(index, object, boundary, x, y, z)
    local className = objectClassName(object)
    local reason
    if hasStoredContainerItems(object, className) then
        reason = "container contents are present or could not be verified"
    elseif not objectFootprintAllowsRemoval(object, boundary, index, x, y, z) then
        reason = "object footprint is invalid or leaves the RV removal scope"
    else
        return
    end
    if index.reportedSafetyBlocks[object] then return end
    index.reportedSafetyBlocks[object] = true
    print("[RailroaderRVTest] template-protection-repair retained object at "
        .. coordinateKey(x, y, z) .. ": " .. reason)
end

local function isProtectedBuildingCandidate(object, x, y, z, boundary,
    index, claimedTarget)
    if isCabSideDoorOrWindow(object, x, y, z, index) then return false end
    if not isRemovalScopeCoordinate(boundary, index, x, y, z)
        or not objectAtCoordinate(object, x, y, z)
        or protectedWorldObject(object) then
        return false
    end
    local className = objectClassName(object)
    if claimedTarget and (claimedTarget.expected.class ~= className
        or claimedTarget.expected.x ~= x or claimedTarget.expected.y ~= y
        or claimedTarget.expected.z ~= z) then
        claimedTarget = nil
    end
    if not className
        or hasStoredContainerItems(object, className)
        or not objectFootprintAllowsRemoval(object, boundary, index, x, y, z) then
        return false
    end
    -- RV-managed coordinates are exclusive, regardless of foreign mod-data
    -- claims or structural sprite metadata.
    if not ServerUtil.classInstance(object, "IsoObject") then
        return false
    end
    if isBloodOrSplat(object) then return false end
    return true
end

local function isWhitelistedTemplateObject(object, boundary, manifest, edges,
    objectIsFloor)
    local tag = objectTag(object)
    if not tag or not sameIdentity(tag, boundary) then return false end
    local index = integer(tag.templateIndex)
    local protection = index and ProtectionManifest.get(index) or nil
    local expectedNorth
    if protection then expectedNorth = protection.north end
    if expectedNorth == "none" then expectedNorth = nil end
    if not protection or tag.templateClass ~= protection.class
        or tag.templateName ~= protection.name
        or tag.templateSprite ~= protection.sprite
        or tag.templateDirection ~= protection.direction
        or tag.templateNorth ~= expectedNorth
        or integer(tag.protectionClass) ~= protection.protectionClass
        or integer(tag.templateX) ~= protection.x
        or integer(tag.templateY) ~= protection.y
        or integer(tag.templateZ) ~= protection.z then
        return false
    end
    local anchor = manifest and manifest.anchor
    if type(anchor) ~= "table" then return false end
    local expected = templateEntry(index, anchor)
    if not ProtectionManifest.matchesLayoutEntry(index, expected, anchor)
        or integer(tag.templateAnchorX) ~= integer(anchor.x)
        or integer(tag.templateAnchorY) ~= integer(anchor.y)
        or integer(tag.templateAnchorZ) ~= integer(anchor.z)
        or integer(tag.templateWorldX) ~= expected.x
        or integer(tag.templateWorldY) ~= expected.y
        or integer(tag.templateWorldZ) ~= expected.z then
        return false
    end
    if expected.class == "IsoObject"
        and isTemplateFloorObject(expected) ~= (objectIsFloor == true) then
        return false
    end
    local xOk, x = ServerUtil.invoke(object, "getX")
    local yOk, y = ServerUtil.invoke(object, "getY")
    local zOk, z = ServerUtil.invoke(object, "getZ")
    x, y, z = xOk and integer(x), yOk and integer(y), zOk and integer(z)
    if not x or not y or not z
        or x ~= expected.x or y ~= expected.y or z ~= expected.z then
        return false
    end
    local openable = expected.class == "IsoDoor"
        or expected.class == "IsoWindow"
    local requiresCapturedState = expected.protectionClass
        ~= ProtectionManifest.FREE_DEMOLITION
    if not openable and requiresCapturedState
        and not objectMatchesCaptured(object, expected) then
        return false
    end
    local edge = edges and edges[index] or nil
    if edge then
        if tag.edgeKey ~= edge.edgeKey or tag.axis ~= edge.axis
            or tag.role ~= edge.role
            or integer(edge.objectX) ~= expected.x
            or integer(edge.objectY) ~= expected.y
            or integer(edge.objectZ) ~= expected.z then
            return false
        end
    elseif tag.edgeKey ~= nil or tag.axis ~= nil
        or tag.role ~= "captured-template" then
        return false
    end
    return Bitmap.containsScope(boundary.bitmap, x, y, z) == true
end

local function isWhitelistedGenerator(object, boundary, manifest)
    local tag = objectTag(object)
    if not tag or not sameIdentity(tag, boundary) or tag.role ~= "generator"
        or not ServerUtil.classInstance(object, "IsoGenerator") then
        return false
    end
    local anchor = manifest.anchor
    local xOk, x = ServerUtil.invoke(object, "getX")
    local yOk, y = ServerUtil.invoke(object, "getY")
    local zOk, z = ServerUtil.invoke(object, "getZ")
    return type(anchor) == "table" and xOk and yOk and zOk
        and integer(x) == integer(anchor.x) + Constants.GENERATOR_OFFSET.x
        and integer(y) == integer(anchor.y) + Constants.GENERATOR_OFFSET.y
        and integer(z) == integer(anchor.z) + Constants.GENERATOR_OFFSET.z
end

local function currentTemplateTagMismatch(object, expected, edge, boundary)
    local protection = expected
        and ProtectionManifest.get(expected.templateIndex) or nil
    if not protection then return "static protection record is missing" end
    local tag = objectTag(object)
    if not tag then return "tag expected=current identity observed=missing" end
    if not sameIdentity(tag, boundary) then
        return "boundary identity expected=current observed=stale or incomplete"
    end
    local checks = {
        { "templateIndex", expected.templateIndex, integer(tag.templateIndex) },
        { "templateX", protection.x, integer(tag.templateX) },
        { "templateY", protection.y, integer(tag.templateY) },
        { "templateZ", protection.z, integer(tag.templateZ) },
        { "templateClass", expected.class, tag.templateClass },
        { "templateName", expected.name, tag.templateName },
        { "templateSprite", expected.sprite, tag.templateSprite },
        { "templateDirection", expected.direction, tag.templateDirection },
        { "templateNorth", expected.north, tag.templateNorth },
        { "templateWorldX", expected.x, integer(tag.templateWorldX) },
        { "templateWorldY", expected.y, integer(tag.templateWorldY) },
        { "templateWorldZ", expected.z, integer(tag.templateWorldZ) },
        { "templateAnchorX", expected.x - protection.x,
            integer(tag.templateAnchorX) },
        { "templateAnchorY", expected.y - protection.y,
            integer(tag.templateAnchorY) },
        { "templateAnchorZ", expected.z - protection.z,
            integer(tag.templateAnchorZ) },
        { "protectionClass", expected.protectionClass,
            integer(tag.protectionClass) },
    }
    for i = 1, #checks do
        local check = checks[i]
        if check[2] ~= check[3] then
            return "tag." .. check[1] .. " expected=" .. tostring(check[2])
                .. " observed=" .. tostring(check[3])
        end
    end
    local expectedEdgeKey = edge and edge.edgeKey or nil
    local expectedAxis = edge and edge.axis or nil
    local expectedRole = edge and edge.role or "captured-template"
    if tag.edgeKey ~= expectedEdgeKey then
        return "tag.edgeKey expected=" .. tostring(expectedEdgeKey)
            .. " observed=" .. tostring(tag.edgeKey)
    end
    if tag.axis ~= expectedAxis then
        return "tag.axis expected=" .. tostring(expectedAxis)
            .. " observed=" .. tostring(tag.axis)
    end
    if tag.role ~= expectedRole then
        return "tag.role expected=" .. tostring(expectedRole)
            .. " observed=" .. tostring(tag.role)
    end
    return nil
end

local function exactExpectedTag(object, expected, edge, boundary)
    if currentTemplateTagMismatch(object, expected, edge, boundary)
        or not objectMatchesCaptured(object, expected) then
        return false
    end
    return true
end

local function reportIncompleteClaimedFloorTag(index, object, boundary,
    expected, edge)
    if index.reportedIdentityBlocks[object] then return end
    index.reportedIdentityBlocks[object] = true
    local mismatch = currentTemplateTagMismatch(object, expected, edge,
        boundary) or "captured object state does not match the current template"
    print("[RailroaderRVTest] captured floor identity blocked rvId="
        .. tostring(boundary.rvId) .. " generation="
        .. tostring(boundary.generation) .. " templateIndex="
        .. tostring(expected.templateIndex) .. " failed=" .. mismatch)
end

local function currentTemplateTarget(object, boundary, targets)
    local tag = objectTag(object)
    if not tag or not sameIdentity(tag, boundary) then return nil end
    local templateIndex = integer(tag.templateIndex)
    if not templateIndex then return nil end
    for i = 1, #targets do
        if targets[i].expected.templateIndex == templateIndex then
            return targets[i]
        end
    end
    return nil
end

local function currentTemplateClaimIsSafe(object, target, boundary, index,
    x, y, z, objectIsFloor)
    if not target then return false end
    local expected = target.expected
    local className = objectClassName(object)
    if not objectAtCoordinate(object, expected.x, expected.y, expected.z)
        or className ~= expected.class or protectedWorldObject(object)
        or isBloodOrSplat(object)
        or hasStoredContainerItems(object, className)
        or not objectFootprintAllowsRemoval(object, boundary, index, x, y, z) then
        return false
    end
    if expected.class == "IsoObject"
        and isTemplateFloorObject(expected) ~= (objectIsFloor == true) then
        return false
    end
    return true
end

local function markMatchingTargetsBlocked(object, targets, blocked, objectIsFloor)
    if protectedWorldObject(object) then return end
    local className = objectClassName(object)
    for i = 1, #targets do
        local expected = targets[i].expected
        local slotMatches = expected.class ~= "IsoObject"
            or isTemplateFloorObject(expected) == (objectIsFloor == true)
        local classMatches = objectMatchesCapturedIdentity(object, expected)
            or className == expected.class
            or (expected.class ~= "IsoObject"
                and ServerUtil.classInstance(object, expected.class))
            or (expected.class == "IsoObject"
                and ServerUtil.classInstance(object, "IsoObject"))
        if slotMatches and classMatches then
            blocked[expected.templateIndex] = true
        end
    end
end

local function collectColumn(cell, x, y, boundary, manifest, index)
    local squares, removals, removalSeen, blocked = {}, {}, {}, {}
    local bitmap = boundary.bitmap
    for z = bitmap.minZ, bitmap.maxZ - 1 do
        local squareOk, square = pcall(ServerWorld.getSquare, cell, x, y, z)
        if not squareOk then return false, "template-protection-repair square lookup failed" end
        if square then
            local snapshotOk, objects = pcall(ServerWorld.squareSnapshot, square)
            if not snapshotOk or type(objects) ~= "table" then
                return false, "template-protection-repair object snapshot failed"
            end
            local targets = index.byCoordinate[coordinateKey(x, y, z)] or {}
            local floorOk, floor = ServerUtil.invoke(square, "getFloor")
            if hasTemplateIsoObjectTarget(targets) and not floorOk then
                return false, "captured floor slot could not be verified"
            end
            squares[z] = { square = square, objects = objects, floor = floor }
            for i = 1, #objects do
                local object = objects[i]
                if not isCabSideDoorOrWindow(object, x, y, z, index)
                    and not isWhitelistedGenerator(object, boundary, manifest)
                    and not isWhitelistedTemplateObject(object, boundary,
                        manifest, index.edges, floor == object) then
                    local objectIsFloor = floor == object
                    local floorTarget = objectIsFloor
                        and hasTemplateFloorTarget(targets)
                    local claimedTarget = currentTemplateTarget(object,
                        boundary, targets)
                    local safeClaimedTarget = currentTemplateClaimIsSafe(
                        object, claimedTarget, boundary, index, x, y, z,
                        objectIsFloor)
                    local buildingCandidate = isProtectedBuildingCandidate(
                        object, x, y, z, boundary, index, claimedTarget)
                    local misplacedVisualCorner = objectIsFloor and claimedTarget
                        and isVisualCornerTemplate(claimedTarget.expected)
                    local incompleteClaimedFloor = floorTarget and claimedTarget
                        and currentTemplateTagMismatch(object,
                            claimedTarget.expected, claimedTarget.edge,
                            boundary) ~= nil
                    if misplacedVisualCorner then
                        blocked[claimedTarget.expected.templateIndex] = true
                    elseif incompleteClaimedFloor then
                        blocked[claimedTarget.expected.templateIndex] = true
                        reportIncompleteClaimedFloorTag(index, object,
                            boundary, claimedTarget.expected,
                            claimedTarget.edge)
                    elseif (safeClaimedTarget or buildingCandidate) and floorTarget then
                        if not protectedWorldObject(object)
                            and not hasStoredContainerItems(object,
                                objectClassName(object)) then
                            removals[#removals + 1] = {
                                object = object, square = square, inPlace = true,
                            }
                            removalSeen[object] = true
                        else
                            reportUnsafeRemoval(index, object, boundary, x, y, z)
                            if claimedTarget then
                                blocked[claimedTarget.expected.templateIndex] = true
                            end
                            markMatchingTargetsBlocked(object, targets, blocked,
                                objectIsFloor)
                        end
                    elseif safeClaimedTarget or buildingCandidate then
                        if not removalSeen[object] then
                            removalSeen[object] = true
                            removals[#removals + 1] = {
                                object = object, square = square,
                            }
                        end
                    else
                        if #targets > 0 then
                            reportUnsafeRemoval(index, object, boundary,
                                x, y, z)
                        end
                        if claimedTarget then
                            blocked[claimedTarget.expected.templateIndex] = true
                        end
                        markMatchingTargetsBlocked(object, targets, blocked,
                            objectIsFloor)
                    end
                end
            end
        end
    end
    return true, squares, removals, blocked
end

local function removeCandidates(removals)
    local removed, inPlace = {}, {}
    for i = 1, #removals do
        local item = removals[i]
        local object = item.object
        if item.inPlace then
            inPlace[object] = true
        else
            local removeOk, removeError = removeTemplateProtectionRepairObject(
                item.square, object)
            if not removeOk then
                return false, "template-protection-repair structure removal failed: "
                    .. tostring(removeError)
            end
            local checkOk, stillPresent = pcall(ServerWorld.squareContainsObject,
                item.square, object)
            if not checkOk or stillPresent ~= false then
                return false, "template-protection-repair structure removal was not observable"
            end
            removed[object] = true
        end
    end
    return true, removed, inPlace
end

local function removeDuplicateTemplate(square, object)
    local className = objectClassName(object)
    if protectedWorldObject(object)
        or not className or not capturedClasses[className]
        or hasStoredContainerItems(object, className) then
        return false
    end
    local removeOk, removeError = removeTemplateProtectionRepairObject(square, object)
    if not removeOk then return false, removeError end
    local checkOk, stillPresent = pcall(ServerWorld.squareContainsObject,
        square, object)
    if not checkOk or stillPresent ~= false then
        return false, "duplicate template object removal was not observable"
    end
    return true
end

local function repairTemplateProtectionColumn(cell, x, y, squares, removed,
    inPlace, blocked, index, boundary, manifest)
    local targets = index.byColumn[columnKey(x, y)] or {}
    local updatedFloors = {}
    local anchor = manifest.anchor
    local tagContext = {
        rvId = boundary.rvId,
        bitmapVersion = boundary.bitmapVersion,
        anchorX = anchor.x,
        anchorY = anchor.y,
        anchorZ = anchor.z,
    }
    for i = 1, #targets do
        local target = targets[i]
        local expected, edge = target.expected, target.edge
        local squareInfo = squares[expected.z]
        if squareInfo then
            local templateIndex = expected.templateIndex
            local present, ambiguous = false, blocked[templateIndex] == true
            for j = 1, #squareInfo.objects do
                local object = squareInfo.objects[j]
                if not removed[object] then
                    if inPlace[object] and isTemplateFloorObject(expected) then
                        if not updatedFloors[object] then
                            local updateOk, updateError = pcall(
                                createCapturedTemplateObject, cell,
                                squareInfo.square, expected, boundary.generation,
                                tagContext, edge)
                            if not updateOk then
                                return false, "captured floor repair failed: "
                                    .. tostring(updateError)
                            end
                            updatedFloors[object] = templateIndex
                        end
                        if updatedFloors[object] == templateIndex then
                            present = true
                        end
                    elseif updatedFloors[object] == templateIndex then
                        present = true
                    elseif isWhitelistedGenerator(object, boundary, manifest) then
                        -- The retained generator can share a floor tile with
                        -- a captured template object.
                    elseif isWhitelistedTemplateObject(object, boundary,
                            manifest, index.edges,
                            squareInfo.floor == object) then
                        local tag = objectTag(object)
                        if integer(tag.templateIndex) == templateIndex then
                            if present then
                                local duplicateOk, duplicateError =
                                    removeDuplicateTemplate(squareInfo.square, object)
                                if not duplicateOk then
                                    ambiguous = true
                                    if duplicateError then
                                        print("[RailroaderRVTest] duplicate template retained: "
                                            .. tostring(duplicateError))
                                    end
                                else
                                    removed[object] = true
                                end
                            else
                                present = exactExpectedTag(object, expected,
                                    edge, boundary)
                                if present
                                    and expected.name == "Wooden Door Frame"
                                    and not configuredDoorFrames[object] then
                                    local configureOk, configureError = pcall(
                                        configureCapturedDoorFrame, object, expected)
                                    if not configureOk then
                                        return false, "captured door frame repair failed: "
                                            .. tostring(configureError)
                                    end
                                    if not ServerUtil.callSucceeded(object,
                                        "transmitCompleteItemToClients") then
                                        return false, "captured door frame update transmission failed"
                                    end
                                    configuredDoorFrames[object] = true
                                end
                            end
                        end
                    elseif objectMatchesCapturedIdentity(object, expected) then
                        ambiguous = true
                    end
                end
            end
            if not present and not ambiguous then
                local createOk, createError = pcall(createCapturedTemplateObject,
                    cell, squareInfo.square, expected, boundary.generation,
                    tagContext, edge)
                if not createOk then
                    return false, "captured template protection repair failed: "
                        .. tostring(createError)
                end
            end
        end
    end
    return true
end

local function repairQueuedTemplateProtectionColumn(player, boundary, expectedKey, x, y,
    repairIndex)
    local contextOk, currentBoundary, record, manifest =
        validCurrentContext(player, boundary)
    local currentKey = contextOk and queueKey(currentBoundary, record) or nil
    if not contextOk or currentKey ~= expectedKey
        or type(repairIndex) ~= "table" or repairIndex.key ~= expectedKey then
        return false, contextOk and "queued RV generation is stale" or currentBoundary
    end
    if not Bitmap.containsScope(boundary.bitmap, x, y, boundary.bitmap.minZ) then
        return true
    end
    local cellOk, cell = pcall(ServerWorld.getCellForPlayer, player)
    if not cellOk or not cell then return false, "current player cell is unavailable" end
    local scanOk, squares, removals, blocked = collectColumn(cell, x, y,
        boundary, manifest, repairIndex)
    if not scanOk then return false, squares end
    local removeOk, removed, inPlace = removeCandidates(removals)
    if not removeOk then return false, removed end
    local repairOk, repairReason = repairTemplateProtectionColumn(cell, x, y,
        squares, removed, inPlace, blocked, repairIndex, boundary, manifest)
    if not repairOk then return false, repairReason end
    return true
end

local function rollbackEntryGenerator(square, before, boundary, created)
    local snapshotOk, objects = pcall(ServerWorld.squareSnapshot, square)
    if not snapshotOk or type(objects) ~= "table" then
        return false, "generator rollback snapshot failed"
    end
    for i = 1, #objects do
        local object = objects[i]
        local candidate = object == created
        if not candidate and not before[object] then
            local tagOk, tag = pcall(objectTag, object)
            local classOk, isGenerator = pcall(ServerUtil.classInstance,
                object, "IsoGenerator")
            candidate = tagOk and classOk and tag
                and sameIdentity(tag, boundary) and tag.role == "generator"
                and isGenerator == true
        end
        if not before[object] and candidate then
            local removeOk, removeError = pcall(ServerWorld.removeGenericObject,
                square, object, false)
            if not removeOk then
                return false, "generator rollback removal failed: "
                    .. tostring(removeError)
            end
            local containsOk, remains = pcall(ServerWorld.squareContainsObject,
                square, object)
            if not containsOk or remains ~= false then
                return false, "generator rollback removal was not observable"
            end
        end
    end
    return true
end

function Boundary.ensureGeneratorForEntry(player, record)
    if not player or type(record) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    local rv = rawget(_G, "RailroaderRV")
    local server = rv and rv.Server
    if not server or type(server.validateCurrentRVRecord) ~= "function" then
        return false, Constants.INVALID_RV_DATA
    end
    local gateOk, accepted, manifest = pcall(
        server.validateCurrentRVRecord, record)
    if not gateOk or accepted ~= true or type(manifest) ~= "table"
        or manifest.state ~= "READY" or manifest.phase ~= "COMMITTED"
        or not sameIdentity(record, manifest)
        or not sameIdentity(record, record.boundary)
        or not sameIdentity(record, manifest.boundary)
        or manifest.templateVersion ~= Constants.CAPTURED_TEMPLATE_VERSION
        or type(manifest.anchor) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end

    local anchorX, anchorY, anchorZ = integer(manifest.anchor.x),
        integer(manifest.anchor.y), integer(manifest.anchor.z)
    if not anchorX or not anchorY or not anchorZ then
        return false, Constants.INVALID_RV_DATA
    end
    local x = anchorX + Constants.GENERATOR_OFFSET.x
    local y = anchorY + Constants.GENERATOR_OFFSET.y
    local z = anchorZ + Constants.GENERATOR_OFFSET.z
    if not Bitmap.containsScope(record.boundary.bitmap, x, y, z) then
        return false, Constants.INVALID_RV_DATA
    end

    local cellOk, cell = pcall(ServerWorld.getCellForPlayer, player)
    if not cellOk or not cell then
        return false, "current player cell is unavailable for generator entry check"
    end
    local chunkOk, chunk = ServerUtil.invoke(cell, "getChunkForGridSquare",
        x, y, z)
    if not chunkOk then
        return false, Constants.INVALID_RV_DATA
    end
    if not chunk then
        -- A nil server chunk is the normal unloaded state after everyone leaves
        -- the RV. Entry itself causes the RV area to stream back in; do not
        -- manufacture or inspect squares outside a loaded chunk.
        return true
    end
    local loadedOk, chunkLoaded = pcall(function() return chunk.loaded end)
    if not loadedOk or type(chunkLoaded) ~= "boolean" then
        return false, Constants.INVALID_RV_DATA
    end
    if not chunkLoaded then return true end

    local squareOk, square = pcall(ServerWorld.getSquare, cell, x, y, z)
    if not squareOk or not square then
        return false, "current RV generator square is unavailable"
    end
    local snapshotOk, objects = pcall(ServerWorld.squareSnapshot, square)
    if not snapshotOk or type(objects) ~= "table" then
        return false, "current RV generator square could not be inspected"
    end

    local before, present, ambiguous = {}, false, false
    for i = 1, #objects do
        local object = objects[i]
        before[object] = true
        if isWhitelistedGenerator(object, record.boundary, manifest) then
            present = true
        elseif ServerUtil.classInstance(object, "IsoGenerator") then
            ambiguous = true
        end
    end
    if ambiguous then return false, Constants.INVALID_RV_DATA end
    if present then return true end

    local createOk, created = pcall(createGenerator, cell, square,
        Constants.SPRITES.generator.sprite, record.generation,
        { rvId = record.rvId, bitmapVersion = record.bitmapVersion })
    if not createOk or not created then
        local rollbackCallOk, rollbackOk, rollbackReason = pcall(
            rollbackEntryGenerator, square, before, record.boundary)
        local failure = "entry generator creation failed: " .. tostring(created)
        if not rollbackCallOk or not rollbackOk then
            failure = failure .. "; " .. tostring(rollbackCallOk
                and rollbackReason or rollbackOk)
        end
        return false, failure
    end

    local verifyOk, attachedAndCurrent = pcall(function()
        local containsOk, attached = ServerWorld.squareContainsObject(square,
            created)
        return containsOk and attached == true
            and isWhitelistedGenerator(created, record.boundary, manifest)
    end)
    if not verifyOk or attachedAndCurrent ~= true then
        local rollbackCallOk, rollbackOk, rollbackReason = pcall(
            rollbackEntryGenerator, square, before, record.boundary, created)
        local failure = "entry generator creation did not persist"
        if not rollbackCallOk or not rollbackOk then
            failure = failure .. "; " .. tostring(rollbackCallOk
                and rollbackReason or rollbackOk)
        end
        return false, failure
    end
    return true
end

local function compactQueue(queue)
    if queue.head <= 64 or queue.head <= queue.tail / 2 then return end
    local compacted = {}
    local count = 0
    for i = queue.head, queue.tail do
        local entry = queue.entries[i]
        if entry then
            count = count + 1
            compacted[count] = entry
        end
    end
    queue.entries, queue.head, queue.tail = compacted, 1, count
end

local function enqueueTile(queue, x, y)
    local tileKey = columnKey(x, y)
    if queue.pending[tileKey] then return end
    queue.tail = queue.tail + 1
    queue.entries[queue.tail] = { x = x, y = y, key = tileKey }
    queue.pending[tileKey] = true
    queue.count = queue.count + 1
end

local function purgePreviousGenerations(rvId, currentKey)
    for key, queue in pairs(queues) do
        if queue.rvId == tostring(rvId) and key ~= currentKey then
            queues[key] = nil
            templateProtectionRepairIndexes[key] = nil
        end
    end
    for key, index in pairs(templateProtectionRepairIndexes) do
        if index.rvId == tostring(rvId) and key ~= currentKey then
            templateProtectionRepairIndexes[key] = nil
        end
    end
end

function Boundary.sampleTemplateProtectionRepairPlayer(expectedBoundary, player)
    local contextOk, boundary, record, manifest, identity =
        validCurrentContext(player, expectedBoundary)
    if not contextOk then return false, boundary end
    local xOk, playerX = ServerUtil.invoke(player, "getX")
    local yOk, playerY = ServerUtil.invoke(player, "getY")
    playerX, playerY = xOk and ServerUtil.toNumber(playerX),
        yOk and ServerUtil.toNumber(playerY)
    if not playerX or not playerY then return false, "player position is unavailable" end
    local centerX, centerY = math.floor(playerX), math.floor(playerY)
    local key = queueKey(boundary, record)
    if not key then return false, Constants.INVALID_RV_DATA end
    if isIdentityPaused(key, Boundary._tick) then
        clearQueuedIdentity(key)
        return true
    end
    local cellOk, cell = pcall(ServerWorld.getCellForPlayer, player)
    if not cellOk or not cell then
        clearQueuedIdentity(key)
        return true
    end
    purgePreviousGenerations(boundary.rvId, key)
    local index = templateProtectionRepairIndexes[key]
    if not index then
        local indexOk, builtIndex = pcall(buildRepairIndex, boundary, manifest)
        if not indexOk or type(builtIndex) ~= "table" then
            return false, Constants.INVALID_RV_DATA
        end
        builtIndex.key = key
        templateProtectionRepairIndexes[key] = builtIndex
        index = builtIndex
    end
    local queue = queues[key]
    if not queue then
        queue = { rvId = tostring(boundary.rvId), entries = {}, head = 1,
            tail = 0, pending = {}, count = 0, index = index }
        queues[key] = queue
    elseif queue.index ~= index then
        return false, Constants.INVALID_RV_DATA
    end
    for offsetY = -1, 1 do
        for offsetX = -1, 1 do
            local x, y = centerX + offsetX, centerY + offsetY
            if Bitmap.containsScope(boundary.bitmap, x, y,
                    boundary.bitmap.minZ)
                and loadedColumnForCell(cell, boundary, x, y) then
                enqueueTile(queue, x, y)
            end
        end
    end
    return true
end

local function popTile(queue)
    local entry = queue.entries[queue.head]
    if not entry then return nil end
    queue.entries[queue.head] = nil
    queue.head = queue.head + 1
    queue.pending[entry.key] = nil
    queue.count = queue.count - 1
    compactQueue(queue)
    return entry
end

function Boundary.processTemplateProtectionRepairQueue(activeBoundaries)
    if type(activeBoundaries) ~= "table" then return false end
    local ready = {}
    for _, item in pairs(activeBoundaries) do
        if type(item) == "table" and item.boundary and item.player then
            local contextOk, boundary, record, manifest, identity =
                validCurrentContext(item.player, item.boundary)
            if contextOk then
                local key = queueKey(boundary, record)
                if key then
                    purgePreviousGenerations(boundary.rvId, key)
                    local queue = queues[key]
                    if isIdentityPaused(key, Boundary._tick) then
                        clearQueuedIdentity(key)
                    elseif queue and queue.count > 0 then
                        ready[#ready + 1] = { key = key, queue = queue,
                            boundary = boundary, player = item.player }
                    end
                end
            end
        end
    end
    if #ready == 0 then return false end
    table.sort(ready, function(left, right) return left.key < right.key end)
    local selected = ready[1]
    if lastServedQueueKey then
        for i = 1, #ready do
            if ready[i].key > lastServedQueueKey then
                selected = ready[i]
                break
            end
        end
    end
    lastServedQueueKey = selected.key
    local nextEntry = selected.queue.entries[selected.queue.head]
    if nextEntry and not loadedColumnForPlayer(selected.player,
        selected.boundary, nextEntry.x, nextEntry.y) then
        -- Chunk streaming can unload a column after sampling. Drop the entire
        -- identity queue; the next loaded sample will rebuild it from current
        -- player proximity instead of carrying stale work across the unload.
        clearQueuedIdentity(selected.key)
        return false
    end
    local entry = popTile(selected.queue)
    if selected.queue.count == 0 then queues[selected.key] = nil end
    if not entry then return false end
    local callOk, repaired, reason = pcall(repairQueuedTemplateProtectionColumn, selected.player,
        selected.boundary, selected.key, entry.x, entry.y,
        selected.queue.index)
    if not callOk or repaired ~= true then
        -- Dequeue failures safely. A nearby player will enqueue the tile again
        -- at the next ten-tick sampling interval; no unbounded retry is kept.
        print("[RailroaderRVTest] template-protection-repair tile deferred: "
            .. tostring(callOk and reason or repaired))
        return false
    end
    return true
end

function Boundary.shouldSampleTemplateProtectionRepair(tick)
    return integer(tick) ~= nil and integer(tick) % sampleInterval == 0
end
end
