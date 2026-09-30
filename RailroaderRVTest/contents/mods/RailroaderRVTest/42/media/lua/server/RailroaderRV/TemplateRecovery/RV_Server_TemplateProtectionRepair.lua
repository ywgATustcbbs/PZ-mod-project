-- TemplateRecoveryWorldRepair: authoritative object safety and correction.
return function(ctx)
local Core = ctx.Core
local Constants = ctx.Constants
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local ensureRoofSquare = ctx.ensureRoofSquare
local Bitmap = require("RailroaderRV/Common/RV_Bitmap")
local createCapturedTemplateObject = ctx.createCapturedTemplateObject
local configureCapturedDoorFrame = ctx.configureCapturedDoorFrame
local ProtectionManifest = require("RailroaderRV/RoomTemplate/RV_ProtectionManifest")
local Index = require("RailroaderRV/TemplateRecovery/RV_TemplateRecoveryIndex")(ctx)
local integer = Index.integer
local sameIdentity = Index.sameIdentity
local queueKey = Index.queueKey
local coordinateKey = Index.coordinateKey
local currentProtectedCoordinateTargets = Index.currentProtectedCoordinateTargets
local validCurrentContext = Index.validCurrentContext
local isCabSideHostCoordinate = Index.isCabSideHostCoordinate
local templateEntry = Index.templateEntry
local objectMatchesCapturedIdentity = Index.objectMatchesCapturedIdentity
local isCapturedClassName = Index.isCapturedClassName

if type(ctx.Boundary) ~= "table" or type(ServerWorld) ~= "table"
    or type(ServerWorld.objectModData) ~= "function"
    or type(ServerWorld.removeGenericObject) ~= "function"
    or type(ServerWorld.squareContainsObject) ~= "function"
    or type(ensureRoofSquare) ~= "function"
    or type(ServerWorld.isPlayerObject) ~= "function"
    or type(ServerWorld.isVehicleObject) ~= "function"
    or type(Index.validCurrentContext) ~= "function"
    or type(Index.getOrBuildRepairIndex) ~= "function"
    or type(Index.isCapturedClassName) ~= "function"
    or type(createCapturedTemplateObject) ~= "function"
    or type(configureCapturedDoorFrame) ~= "function" then
    error("RailroaderRVTest: current template-protection-repair dependencies are incomplete")
end

local configuredDoorFrames = setmetatable({}, { __mode = "k" })
local repairReportStateByIndex = setmetatable({}, { __mode = "k" })
local function tickAfter(tick, delta)
    local result, reason = Core.tickAdd(tick, delta)
    if result == nil then
        error("invalid template-repair tick deadline: " .. tostring(reason), 0)
    end
    return result
end
local function repairReportState(index)
    local state = repairReportStateByIndex[index]
    if not state then
        state = {
            safety = setmetatable({}, { __mode = "k" }),
            identity = setmetatable({}, { __mode = "k" }),
        }
        repairReportStateByIndex[index] = state
    end
    return state
end
local recentTemplateProtectionRemovals = setmetatable({}, { __mode = "k" })
local recentTemplateProtectionRemovalsByPosition = {}
local currentlyRemovingTemplateProtectionObject = nil
local templateProtectionRemovalTraceRegistered = false

local function removeTemplateProtectionRepairObject(square, object)
    local server = RV and RV.Server
    if type(server) ~= "table" then
        return false, "template protection repair removal marker is unavailable"
    end
    local xOk, x = ServerUtil.invoke(object, "getX")
    local yOk, y = ServerUtil.invoke(object, "getY")
    local zOk, z = ServerUtil.invoke(object, "getZ")
    local position = (xOk and tostring(x) or "?") .. ","
        .. (yOk and tostring(y) or "?") .. ","
        .. (zOk and tostring(z) or "?")
    local previousObject = currentlyRemovingTemplateProtectionObject
    currentlyRemovingTemplateProtectionObject = object
    local removalRecord = {
        position = position,
        expiresAt = tickAfter(Core.getTick(), 2),
    }
    recentTemplateProtectionRemovals[object] = removalRecord
    recentTemplateProtectionRemovalsByPosition[position] = removalRecord
    local removeOk, removeResult = pcall(ServerWorld.removeGenericObject,
        square, object, false)
    currentlyRemovingTemplateProtectionObject = previousObject
    return removeOk, removeResult
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


local function loadedLayerForCell(cell, x, y, z)
    if not cell then return false, "cell unavailable" end
    local chunkOk, chunk = ServerUtil.invoke(cell,
        "getChunkForGridSquare", x, y, z)
    if not chunkOk then return false, "chunk lookup failed" end
    if not chunk then return false, "chunk missing" end
    local loadedOk, loaded = pcall(function() return chunk.loaded end)
    if not loadedOk then return false, "loaded flag lookup failed" end
    if loaded ~= true then return false, "chunk not loaded" end
    return true
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

local function onTemplateProtectionObjectAboutToBeRemoved(object)
    local tracked = recentTemplateProtectionRemovals[object]
    local xOk, x = ServerUtil.invoke(object, "getX")
    local yOk, y = ServerUtil.invoke(object, "getY")
    local zOk, z = ServerUtil.invoke(object, "getZ")
    local eventPosition = (xOk and tostring(x) or "?") .. ","
        .. (yOk and tostring(y) or "?") .. ","
        .. (zOk and tostring(z) or "?")
    local positionMatch = recentTemplateProtectionRemovalsByPosition[
        eventPosition]
    if tracked then recentTemplateProtectionRemovals[object] = nil end
    if positionMatch then
        recentTemplateProtectionRemovalsByPosition[eventPosition] = nil
    end
end

local function registerTemplateProtectionRemovalTrace()
    if templateProtectionRemovalTraceRegistered then return end
    local registered, reason = Core.registerEvent(
        "OnObjectAboutToBeRemoved",
        "RV.Server.TemplateProtectionRepairRemovalTrace",
        onTemplateProtectionObjectAboutToBeRemoved)
    if not registered then
        error("RV Core registration failed: " .. tostring(reason), 0)
    end
    templateProtectionRemovalTraceRegistered = true
end

registerTemplateProtectionRemovalTrace()

local function pruneTemplateProtectionRemovalTrace(tick)
    if not Core.isTick(tick) then return false end
    for position, removalTrace in pairs(
        recentTemplateProtectionRemovalsByPosition) do
        if not Core.isTick(removalTrace.expiresAt)
            or Core.tickCompare(tick, removalTrace.expiresAt) == 1 then
            recentTemplateProtectionRemovalsByPosition[position] = nil
        end
    end
    return true
end

ctx.pruneTemplateProtectionRemovalTrace = pruneTemplateProtectionRemovalTrace

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

local function footprintAllowsRemoval(tag, boundary, index, x, y, z, cell)
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
        if not loadedLayerForCell(cell, fx, fy, fz) then return false end
        local coordinate = coordinateKey(fx, fy, fz)
        if seen[coordinate] then return false end
        seen[coordinate] = true
        if fx == x and fy == y and fz == z then hostSeen = true end
        count = count + 1
    end
    return count == #footprint and count > 0 and hostSeen
end

local function objectFootprintAllowsRemoval(object, boundary, index, x, y, z,
    cell)
    local data = ServerWorld.objectModData(object)
    if type(data) ~= "table" then return true end
    local nested = data.RailroaderRVTest
    if not footprintAllowsRemoval(data, boundary, index, x, y, z, cell) then
        return false
    end
    return type(nested) ~= "table"
        or footprintAllowsRemoval(nested, boundary, index, x, y, z, cell)
end

local function reportUnsafeRemoval(index, object, boundary, x, y, z, cell)
    local className = objectClassName(object)
    local reason
    if hasStoredContainerItems(object, className) then
        reason = "container contents are present or could not be verified"
    elseif not objectFootprintAllowsRemoval(object, boundary, index, x, y, z,
        cell) then
        reason = "object footprint is invalid, unloaded, or leaves the RV removal scope"
    else
        return
    end
    local reportState = repairReportState(index)
    if reportState.safety[object] then return end
    reportState.safety[object] = true
    print("[RailroaderRVTest] template-protection-repair retained object at "
        .. coordinateKey(x, y, z) .. ": " .. reason)
end

local function isProtectedBuildingCandidate(object, x, y, z, boundary,
    index, claimedTarget, cell)
    if type(claimedTarget) ~= "table"
        or type(claimedTarget.expected) ~= "table"
        or type(boundary) ~= "table" or type(index) ~= "table"
        or not sameIdentity(index, boundary) then
        return false, "current-template-claim-unavailable"
    end
    local expected = claimedTarget.expected
    local templateIndex = integer(expected.templateIndex)
    local protection = templateIndex
        and ProtectionManifest.get(templateIndex) or nil
    if not protection
        or protection.protectionClass ~= expected.protectionClass
        or (protection.protectionClass ~= ProtectionManifest.RESTORE_ONLY
            and protection.protectionClass ~= ProtectionManifest.PROHIBITED)
        or expected.x ~= x or expected.y ~= y or expected.z ~= z then
        return false, "target-is-not-a-current-protected-template-entry"
    end
    local targets = currentProtectedCoordinateTargets(index, boundary,
        x, y, z)
    local targetIsCurrent = false
    for i = 1, #(targets or {}) do
        if targets[i] == claimedTarget then
            targetIsCurrent = true
            break
        end
    end
    if not targetIsCurrent then
        return false, "target-does-not-belong-to-current-coordinate-index"
    end
    local tag = objectTag(object)
    if not tag or not sameIdentity(tag, boundary)
        or currentTemplateTagMismatch(object, expected, claimedTarget.edge,
            boundary) ~= nil
        or not objectMatchesCapturedIdentity(object, expected) then
        return false, "object-current-generation-template-identity-unproven"
    end
    if isCabSideDoorOrWindow(object, x, y, z, index) then
        return false, "cab-side-opening"
    end
    if not isRemovalScopeCoordinate(boundary, index, x, y, z) then
        return false, "outside-removal-scope"
    end
    if not objectAtCoordinate(object, x, y, z) then
        return false, "object-coordinate-mismatch"
    end
    if protectedWorldObject(object) then
        return false, "protected-world-object"
    end
    local className = objectClassName(object)
    if className ~= expected.class then
        return false, "object-class-does-not-match-current-template"
    end
    if not className then return false, "object-class-unavailable" end
    if hasStoredContainerItems(object, className) then
        return false, "container-not-empty-or-unverified"
    end
    if not objectFootprintAllowsRemoval(object, boundary, index, x, y, z,
        cell) then
        return false, "object-footprint-unsafe"
    end
    -- The current template tag and its live object identity jointly prove
    -- ownership. A coordinate match alone never authorizes removal.
    if not ServerUtil.classInstance(object, "IsoObject") then
        return false, "object-class-not-IsoObject"
    end
    if isBloodOrSplat(object) then return false, "blood-or-splat" end
    return true, "candidate"
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
    local reportState = repairReportState(index)
    if reportState.identity[object] then return end
    reportState.identity[object] = true
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
    x, y, z, objectIsFloor, cell)
    if not target then return false end
    local expected = target.expected
    local className = objectClassName(object)
    if not objectAtCoordinate(object, expected.x, expected.y, expected.z)
        or className ~= expected.class or protectedWorldObject(object)
        or isBloodOrSplat(object)
        or hasStoredContainerItems(object, className)
        or not objectFootprintAllowsRemoval(object, boundary, index, x, y, z,
            cell) then
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

local function collectCoordinate(cell, x, y, z, boundary, manifest, index)
    local removals, removalSeen, blocked = {}, {}, {}
    local targets = index.byCoordinate[coordinateKey(x, y, z)] or {}
    local squareOk, square = pcall(ServerWorld.getSquare, cell, x, y, z)
    if not squareOk then
        return false, "template-protection-repair square lookup failed"
    end
    local squareInfo
    if square then
        local snapshotOk, objects = pcall(ServerWorld.squareSnapshot, square)
        if not snapshotOk or type(objects) ~= "table" then
            return false, "template-protection-repair object snapshot failed"
        end
        local floorOk, floor = ServerUtil.invoke(square, "getFloor")
        if hasTemplateIsoObjectTarget(targets) and not floorOk then
            return false, "captured floor slot could not be verified"
        end
        squareInfo = { square = square, objects = objects, floor = floor }
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
                    objectIsFloor, cell)
                local buildingCandidate, candidateReason =
                    isProtectedBuildingCandidate(object, x, y, z, boundary,
                        index, claimedTarget, cell)
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
                        reportUnsafeRemoval(index, object, boundary, x, y, z,
                            cell)
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
                            x, y, z, cell)
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
    return true, squareInfo, removals, blocked
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
        or not className or not isCapturedClassName(className)
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

local function repairTemplateProtectionCoordinate(cell, x, y, z, squareInfo,
    removed, inPlace, blocked, index, boundary, manifest)
    local targets = index.byCoordinate[coordinateKey(x, y, z)] or {}
    if #targets == 0 then return true end
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
        if expected.x ~= x or expected.y ~= y or expected.z ~= z then
            return false, Constants.INVALID_RV_DATA
        end
        if not squareInfo then
            if not Bitmap.containsScope(boundary.bitmap, expected.x,
                expected.y, expected.z) then
                return false, Constants.INVALID_RV_DATA
            end
            if not loadedLayerForCell(cell, expected.x, expected.y,
                expected.z) then
                return false, "protected template layer became unloaded before square creation"
            end
            local squareOk, square = pcall(ensureRoofSquare, cell,
                expected.x, expected.y, expected.z)
            if not squareOk or not square then
                return false, "protected template grid square creation failed: "
                    .. tostring(square)
            end
            local snapshotOk, objects = pcall(ServerWorld.squareSnapshot, square)
            if not snapshotOk or type(objects) ~= "table" then
                return false, "protected template grid square snapshot failed"
            end
            local floorOk, floor = ServerUtil.invoke(square, "getFloor")
            local coordinateTargets = index.byCoordinate[
                coordinateKey(expected.x, expected.y, expected.z)] or {}
            if hasTemplateIsoObjectTarget(coordinateTargets) and not floorOk then
                return false, "captured floor slot could not be verified"
            end
            squareInfo = { square = square, objects = objects, floor = floor }
        end
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

local function repairTemplateProtectionLayer(cell, x, y, z, boundary, manifest,
    repairIndex)
    if not Bitmap.containsScope(boundary.bitmap, x, y, z)
        or isCabEditableCoordinate(x, y, z, repairIndex) then
        return true
    end
    local loaded = loadedLayerForCell(cell, x, y, z)
    if not loaded then
        return true
    end
    local scanOk, squareInfo, removals, blocked = collectCoordinate(cell,
        x, y, z, boundary, manifest, repairIndex)
    if not scanOk then return false, squareInfo end
    local removeOk, removed, inPlace = removeCandidates(removals)
    if not removeOk then return false, removed end
    local repairOk, repairReason = repairTemplateProtectionCoordinate(cell,
        x, y, z, squareInfo, removed, inPlace, blocked, repairIndex,
        boundary, manifest)
    if not repairOk then return false, repairReason end
    if (squareInfo and #squareInfo.objects > 0)
        or #removals > 0
        or repairIndex.byCoordinate[coordinateKey(x, y, z)] then
        local targets = repairIndex.byCoordinate[coordinateKey(x, y, z)] or {}
    end
    return true
end

local function repairQueuedTemplateProtectionXY(player, boundary, expectedKey,
    x, y)
    local contextOk, currentBoundary, record, manifest =
        validCurrentContext(player, boundary)
    local currentKey = contextOk and queueKey(currentBoundary, record) or nil
    if not contextOk or currentKey ~= expectedKey then
        return false, contextOk and "queued RV generation is stale"
            or currentBoundary
    end
    local indexCallOk, repairIndex = pcall(Index.getOrBuildRepairIndex,
        currentBoundary, manifest)
    if not indexCallOk or type(repairIndex) ~= "table" then
        return false, Constants.INVALID_RV_DATA
    end
    if repairIndex.key ~= expectedKey then
        return false, "queued template-protection index is stale"
    end
    local cellOk, cell = pcall(ServerWorld.getCellForPlayer, player)
    if not cellOk or not cell then
        return true
    end
    for z = boundary.bitmap.minZ, boundary.bitmap.maxZ - 1 do
        pcall(repairTemplateProtectionLayer, cell, x, y, z, boundary,
            manifest, repairIndex)
    end
    return true
end

local function reconcileCurrentTemplateCell(player, expectedBoundary, x, y)
    local contextOk, boundary, record = validCurrentContext(player,
        expectedBoundary)
    local ix, iy = integer(x), integer(y)
    if not contextOk then return false, boundary end
    if ix == nil or iy == nil
        or not Bitmap.containsScope(boundary.bitmap, ix, iy,
            boundary.bitmap.minZ) then
        return false, Constants.INVALID_RV_DATA
    end
    local expectedKey = queueKey(boundary, record)
    if type(expectedKey) ~= "string" then
        return false, Constants.INVALID_RV_DATA
    end
    return repairQueuedTemplateProtectionXY(player, boundary, expectedKey,
        ix, iy)
end

ctx.reconcileCurrentTemplateCell = reconcileCurrentTemplateCell

local server = type(RV) == "table" and RV.Server or nil
if type(server) == "table" then
    server.isTemplateProtectionRepairRemoval = function(object)
        return object ~= nil and currentlyRemovingTemplateProtectionObject == object
    end
end

end
