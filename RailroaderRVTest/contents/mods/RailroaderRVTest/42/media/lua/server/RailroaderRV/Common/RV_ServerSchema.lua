-- RailroaderRVTest current-schema and geometry helpers.
--
-- This module is pure with respect to persistence and events.  It validates
-- the current layout contract and reports loaded-area status; callers
-- remain responsible for transaction state, world mutation and fail-closed
-- save handling.

local Layout = require("RailroaderRV/RoomTemplate/RV_Layout")
local CapturedTemplate = require("RailroaderRV/RoomTemplate/RV_Template")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local templateObjects = RoomTemplate.orderedObjects(Template)
local ProtectionManifest = require("RailroaderRV/RoomTemplate/RV_ProtectionManifest")
local TemplateGeometry = require("RailroaderRV/RoomTemplate/RV_TemplateGeometry")
local ServerUtil = require("RailroaderRV/Common/RV_ServerUtil")
local ServerWorld = require("RailroaderRV/Common/RV_ServerWorld")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")
local WORLD_MIN_Z = -32
local WORLD_MAX_Z = 31
local M = {}

local protectionManifestValid, protectionManifestError =
    ProtectionManifest.validateTemplate(CapturedTemplate)
if not protectionManifestValid then
    error("RailroaderRVTest: captured protection ledger is invalid: "
        .. tostring(protectionManifestError))
end
local roomTemplateValid, roomTemplateError = RoomTemplate.validate(Template)
if not roomTemplateValid or type(templateObjects) ~= "table" then
    error("RailroaderRVTest: current RoomTemplate is invalid: "
        .. tostring(roomTemplateError or "ordered object index is incomplete"))
end

local function boundsFor(layout)
    if type(layout) ~= "table" then
        error("RailroaderRVTest: layout plan is not a table")
    end
    local clear = layout.clear
    local managed = layout.managed
    local shellEdges = layout.shellEdges
    local room = layout.room
    local wall = layout.wall
    local roof = layout.roof
    local anchor = layout.anchor
    if type(clear) ~= "table" or type(managed) ~= "table"
        or type(shellEdges) ~= "table"
        or type(room) ~= "table" or type(wall) ~= "table"
        or type(roof) ~= "table" or type(anchor) ~= "table" then
        error("RailroaderRVTest: layout bounds contract is incomplete")
    end
    local function field(source, label, name)
        local value = source[name]
        if value == nil then
            error("RailroaderRVTest: layout contract missing " .. label)
        end
        return ServerUtil.requiredInteger(value, label)
    end
    local ax = ServerUtil.requiredInteger(anchor.x, "layout anchor.x")
    local ay = ServerUtil.requiredInteger(anchor.y, "layout anchor.y")
    local az = ServerUtil.requiredInteger(anchor.z, "layout anchor.z")
    local clearMinZ = field(clear, "layout clear.minZ", "minZ")
    local clearMaxZ = field(clear, "layout clear.maxZ", "maxZ")
    local clearMinX = field(clear, "layout clear.minX", "minX")
    local clearMaxX = field(clear, "layout clear.maxX", "maxX")
    local clearMinY = field(clear, "layout clear.minY", "minY")
    local clearMaxY = field(clear, "layout clear.maxY", "maxY")
    local roomMinX = field(room, "layout room.minX", "minX")
    local roomMaxX = field(room, "layout room.maxX", "maxX")
    local roomMinY = field(room, "layout room.minY", "minY")
    local roomMaxY = field(room, "layout room.maxY", "maxY")
    local roomZ = field(room, "layout room.z", "z")
    local wallMinX = field(wall, "layout wall.minX", "minX")
    local wallMaxX = field(wall, "layout wall.maxX", "maxX")
    local wallMinY = field(wall, "layout wall.minY", "minY")
    local wallMaxY = field(wall, "layout wall.maxY", "maxY")
    local wallZ = field(wall, "layout wall.z", "z")
    local roofMinX = field(roof, "layout roof.minX", "minX")
    local roofMaxX = field(roof, "layout roof.maxX", "maxX")
    local roofMinY = field(roof, "layout roof.minY", "minY")
    local roofMaxY = field(roof, "layout roof.maxY", "maxY")
    local roofZ = ServerUtil.requiredInteger(roof.z, "layout roof.z")
    if type(layout.wallCoordinates) ~= "table" then
        error("RailroaderRVTest: layout wallCoordinates is missing")
    end
    local wallObjectCount = ServerUtil.requiredInteger(layout.wallObjectCount, "layout wallObjectCount")
    local wallCoordinateCount = ServerUtil.requiredInteger(layout.wallCoordinateCount, "layout wallCoordinateCount")
    local wallEdgeCounts = layout.wallEdgeCounts
    if type(wallEdgeCounts) ~= "table" then
        error("RailroaderRVTest: layout wallEdgeCounts is missing")
    end
    local northEdges = ServerUtil.requiredInteger(wallEdgeCounts.north, "layout wallEdgeCounts.north")
    local westEdges = ServerUtil.requiredInteger(wallEdgeCounts.west, "layout wallEdgeCounts.west")
    local wallCornerCount = ServerUtil.requiredInteger(layout.wallCornerCount, "layout wallCornerCount")
    local managedMinZ = field(managed, "layout managed.minZ", "minZ")
    local managedMaxZ = field(managed, "layout managed.maxZ", "maxZ")
    local managedOriginX = field(managed, "layout managed.originX", "originX")
    local managedOriginY = field(managed, "layout managed.originY", "originY")
    local managedWidth = field(managed, "layout managed.width", "width")
    local managedHeight = field(managed, "layout managed.height", "height")
    if managedWidth ~= Template.metadata.width
        or managedHeight ~= Template.metadata.height
        or managedMaxZ <= managedMinZ
        or clear.minX ~= managedOriginX or clear.minY ~= managedOriginY
        or clear.maxX ~= managedOriginX + managedWidth
        or clear.maxY ~= managedOriginY + managedHeight
        or clearMinZ ~= managedMinZ or clearMaxZ ~= managedMaxZ
        or clear.halfOpen ~= true then
        error("RailroaderRVTest: managed scope does not match template bounds")
    end
    local scopeMinX, scopeMinY = managedOriginX, managedOriginY
    local scopeMaxX = managedOriginX + managedWidth
    local scopeMaxY = managedOriginY + managedHeight
    local function rectInside(minX, maxX, minY, maxY, z, label)
        if minX > maxX or minY > maxY
            or minX < scopeMinX or maxX >= scopeMaxX
            or minY < scopeMinY or maxY >= scopeMaxY
            or z < managedMinZ or z >= managedMaxZ then
            error("RailroaderRVTest: " .. tostring(label)
                .. " is outside the managed region")
        end
    end
    if roomZ ~= az or wallZ ~= az or roofZ < managedMinZ
        or roofZ >= managedMaxZ then
        error("RailroaderRVTest: layout structure z is outside the managed region")
    end
    rectInside(roomMinX, roomMaxX, roomMinY, roomMaxY, roomZ, "room")
    rectInside(wallMinX, wallMaxX, wallMinY, wallMaxY, wallZ, "wall")
    rectInside(roofMinX, roofMaxX, roofMinY, roofMaxY, roofZ, "roof")
    for i = 1, #layout.wallCoordinates do
        local entry = layout.wallCoordinates[i]
        if type(entry) ~= "table"
            or not TemplateGeometry.inManagedRegion({
                x = entry.x, y = entry.y, z = entry.z,
            }, managed) then
            error("RailroaderRVTest: wall object host is outside managed region")
        end
    end
    return {
        clearMinX = clearMinX, clearMaxX = clearMaxX,
        clearMinY = clearMinY, clearMaxY = clearMaxY,
        clearMinZ = clearMinZ, clearMaxZ = clearMaxZ,
        managedOriginX = managedOriginX, managedOriginY = managedOriginY,
        managedWidth = managedWidth, managedHeight = managedHeight,
        managedMinZ = managedMinZ, managedMaxZ = managedMaxZ,
        managed = managed, shellEdges = shellEdges,
        roomMinX = roomMinX, roomMaxX = roomMaxX,
        roomMinY = roomMinY, roomMaxY = roomMaxY, roomZ = roomZ,
        wallMinX = wallMinX, wallMaxX = wallMaxX,
        wallMinY = wallMinY, wallMaxY = wallMaxY, wallZ = wallZ,
        wallCoordinates = layout.wallCoordinates,
        wallObjectCount = wallObjectCount,
        wallCoordinateCount = wallCoordinateCount,
        wallEdgeCounts = layout.wallEdgeCounts,
        wallCornerCount = wallCornerCount,
        northEdges = northEdges, westEdges = westEdges,
        roofMinX = roofMinX, roofMaxX = roofMaxX,
        roofMinY = roofMinY, roofMaxY = roofMaxY,
        z = az,
        roofZ = roofZ,
        anchor = { x = ax, y = ay, z = az },
    }
end

local function walkBounds(cell, bounds, fn, requireLoaded)
    for z = bounds.clearMinZ, bounds.clearMaxZ - 1 do
        for x = bounds.clearMinX, bounds.clearMaxX - 1 do
            for y = bounds.clearMinY, bounds.clearMaxY - 1 do
                local square = ServerWorld.getSquare(cell, x, y, z)
                if not square and requireLoaded == true then
                    error("RailroaderRVTest: clear bounds contain an unloaded square")
                end
                if square then
                    fn(square, x, y, z)
                end
            end
        end
    end
end

local function validateWallContract(bounds)
    if type(bounds.wallCoordinates) ~= "table" then
        error("RailroaderRVTest: wall layout contract is invalid")
    end
    local orientations, exact, both, templateIndices = {}, {}, {}, {}
    local northEdges, westEdges, corners = 0, 0, 0
    local nwKey = tostring(bounds.wallMinX) .. ":" .. tostring(bounds.wallMinY)
        .. ":" .. tostring(bounds.z)
    local anchorX, anchorY = bounds.anchor.x, bounds.anchor.y
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        if type(entry) ~= "table" or type(entry.x) ~= "number"
            or type(entry.y) ~= "number" or type(entry.z) ~= "number"
            or type(entry.north) ~= "boolean" or type(entry.role) ~= "string"
            or type(entry.sprite) ~= "string" or type(entry.corner) ~= "boolean"
            or type(entry.templateIndex) ~= "number"
            or type(entry.templateIndices) ~= "table"
            or #entry.templateIndices < 1 then
            error("RailroaderRVTest: malformed wall entry at index " .. tostring(i))
        end
        local partCount = 0
        for partKey in pairs(entry.templateIndices) do
            partCount = partCount + 1
            if type(partKey) ~= "number" or partKey < 1
                or math.floor(partKey) ~= partKey or partKey > #entry.templateIndices then
                error("RailroaderRVTest: shell edge parts are not a dense list")
            end
        end
        if partCount ~= #entry.templateIndices
            or entry.templateIndices[1] ~= entry.templateIndex then
            error("RailroaderRVTest: shell edge representative is not its first part")
        end
        local x = ServerUtil.requiredInteger(entry.x, "wall[" .. tostring(i) .. "].x")
        local y = ServerUtil.requiredInteger(entry.y, "wall[" .. tostring(i) .. "].y")
        local z = ServerUtil.requiredInteger(entry.z, "wall[" .. tostring(i) .. "].z")
        local templateIndex = ServerUtil.requiredInteger(entry.templateIndex,
            "wall[" .. tostring(i) .. "].templateIndex")
        local captured = templateIndex and templateObjects[templateIndex]
        if not captured
            or (captured.class ~= "IsoThumpable" and captured.class ~= "IsoWindow")
            or captured.x ~= x - anchorX or captured.y ~= y - anchorY
            or captured.z ~= z - bounds.z or captured.sprite ~= entry.sprite
            or captured.north ~= entry.north or templateIndices[templateIndex] then
            error("RailroaderRVTest: wall entry does not match its captured object")
        end
        for partPosition = 1, #entry.templateIndices do
            local partIndex = ServerUtil.requiredInteger(entry.templateIndices[partPosition],
                "wall[" .. tostring(i) .. "].templateIndices["
                    .. tostring(partPosition) .. "]")
            local part = partIndex and templateObjects[partIndex]
            if not part
                or (part.class ~= "IsoThumpable" and part.class ~= "IsoWindow")
                or part.x ~= x - anchorX or part.y ~= y - anchorY
                or part.z ~= z - bounds.z or part.north ~= entry.north
                or templateIndices[partIndex] then
                error("RailroaderRVTest: shell edge part does not match its captured host")
            end
            templateIndices[partIndex] = true
        end
        if x < bounds.wallMinX or x > bounds.wallMaxX
            or y < bounds.wallMinY or y > bounds.wallMaxY or z ~= bounds.z then
            error("RailroaderRVTest: wall entry is outside the wall bounds")
        end
        local coordinateKey = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        local orientation = entry.north and "north" or "west"
        local orientationKey = coordinateKey .. ":" .. orientation
        local exactKey = orientationKey .. ":" .. entry.role
        if exact[exactKey] or orientations[orientationKey] then
            error("RailroaderRVTest: duplicate wall coordinate/orientation")
        end
        exact[exactKey] = true
        orientations[orientationKey] = true
        both[coordinateKey] = both[coordinateKey] or {}
        both[coordinateKey][orientation] = true
        local expectedCorner = entry.north == true and coordinateKey == nwKey
        local expectedRole = expectedCorner and "corner-nw"
            or "wall-" .. orientation
        if entry.corner ~= expectedCorner or entry.role ~= expectedRole then
            error("RailroaderRVTest: wall role/corner does not match captured geometry")
        end
        if entry.north then northEdges = northEdges + 1 else westEdges = westEdges + 1 end
        if entry.corner == true then corners = corners + 1 end
    end
    for coordinateKey, orientationSet in pairs(both) do
        if orientationSet.north and orientationSet.west and coordinateKey ~= nwKey then
            error("RailroaderRVTest: wall ring cannot duplicate an orientation at " .. coordinateKey)
        end
    end
    if #bounds.wallCoordinates ~= bounds.wallCoordinateCount
        or bounds.wallObjectCount ~= bounds.wallCoordinateCount
        or bounds.northEdges ~= northEdges or bounds.westEdges ~= westEdges
        or bounds.wallCornerCount ~= corners then
        error("RailroaderRVTest: wall layout summary does not match its template edges")
    end
end

-- Shell ownership is a separate persisted ledger, not a deduction from the
-- wall object's inactive host cell.  Validate the generated identity here so
-- a malformed plan cannot enter the destructive generation transaction.
local function validateShellEdgeContract(bounds)
    if type(bounds.shellEdges) ~= "table" then
        error("RailroaderRVTest: shell edge ledger is missing")
    end
    local seen = {}
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        local key = entry.edgeKey
        if type(key) ~= "string" or seen[key] then
            error("RailroaderRVTest: shell edge key is missing or duplicated")
        end
        local axis, edgeX, edgeY, edgeZ = string.match(
            key, "^([NW]):(-?%d+):(-?%d+):(-?%d+)$")
        edgeX, edgeY, edgeZ = tonumber(edgeX), tonumber(edgeY), tonumber(edgeZ)
        if not axis or edgeX == nil or edgeY == nil or edgeZ == nil
            or entry.axis ~= axis then
            error("RailroaderRVTest: shell edge is not canonical N/W")
        end
        local ledger = bounds.shellEdges[key]
        if type(ledger) ~= "table"
            or ledger.edgeKey ~= key
            or ServerUtil.requiredInteger(ledger.hostX, "shell edge hostX") ~= edgeX
            or ServerUtil.requiredInteger(ledger.hostY, "shell edge hostY") ~= edgeY
            or ServerUtil.requiredInteger(ledger.z, "shell edge z") ~= edgeZ
            or ServerUtil.requiredInteger(ledger.objectX, "shell edge objectX") ~= entry.x
            or ServerUtil.requiredInteger(ledger.objectY, "shell edge objectY") ~= entry.y
            or ServerUtil.requiredInteger(ledger.objectZ, "shell edge objectZ") ~= entry.z
            or ServerUtil.requiredInteger(ledger.templateIndex,
                "shell edge templateIndex") ~= entry.templateIndex
            or type(ledger.templateIndices) ~= "table"
            or #ledger.templateIndices ~= #entry.templateIndices
            or ledger.sprite ~= entry.sprite or ledger.north ~= entry.north
            or ledger.replacementAllowed ~= true then
            error("RailroaderRVTest: shell edge ledger identity is inconsistent")
        end
        for partPosition = 1, #entry.templateIndices do
            if ledger.templateIndices[partPosition] ~= entry.templateIndices[partPosition] then
                error("RailroaderRVTest: shell edge part ledger is inconsistent")
            end
        end
        seen[key] = true
    end
end

-- Validate only the candidate-slot contract and world coordinates. This helper
-- deliberately never reads an IsoGridSquare: queueGeneration must be able to
-- reject an impossible destination before sending Relocate, while the
-- post-teleport preflight below verifies the current cell and geometry without
-- requiring empty or upper template squares to exist.
local function validateTargetCoordinates(bounds, destination)
    if type(bounds) ~= "table" then
        error("RailroaderRVTest: target bounds are not a table")
    end
    if type(destination) ~= "table" then
        error("RailroaderRVTest: relocation destination is not a table")
    end

    local targetX = ServerUtil.requiredInteger(destination.x, "relocation target x")
    local targetY = ServerUtil.requiredInteger(destination.y, "relocation target y")
    local targetZ = ServerUtil.requiredInteger(destination.z, "relocation target z")
    local slotIndex = RegionSlots.indexForAnchor({
        x = targetX, y = targetY, z = targetZ,
    })
    if slotIndex == nil then
        error("RailroaderRVTest: relocation target is outside the current RV slot matrix")
    end

    if targetZ < WORLD_MIN_Z or targetZ > WORLD_MAX_Z
        or bounds.clearMinZ < WORLD_MIN_Z or bounds.clearMaxZ - 1 > WORLD_MAX_Z
        or bounds.clearMinZ >= bounds.clearMaxZ
        or bounds.z < WORLD_MIN_Z or bounds.z > WORLD_MAX_Z
        or bounds.roofZ < WORLD_MIN_Z or bounds.roofZ > WORLD_MAX_Z then
        error("RailroaderRVTest: layout z bounds are outside the legal world")
    end
    -- The selected matrix cell owns this template's half-open XY region.
    if bounds.clearMinX ~= targetX + Template.metadata.minX
        or bounds.clearMaxX ~= targetX + Template.metadata.maxXExclusive
        or bounds.clearMinY ~= targetY + Template.metadata.minY
        or bounds.clearMaxY ~= targetY + Template.metadata.maxYExclusive
        or bounds.z ~= targetZ or bounds.clearMinZ ~= bounds.managedMinZ
        or bounds.clearMaxZ ~= bounds.managedMaxZ then
        error("RailroaderRVTest: clear footprint does not match the selected RV slot")
    end
    if targetX < bounds.roomMinX or targetX > bounds.roomMaxX
        or targetY < bounds.roomMinY or targetY > bounds.roomMaxY then
        error("RailroaderRVTest: final relocation center is outside the interior")
    end
    validateWallContract(bounds)
    validateShellEdgeContract(bounds)

    local worldOk, world = ServerUtil.callGlobal("getWorld")
    if not worldOk or not world then
        error("RailroaderRVTest: getWorld is unavailable for coordinate validation")
    end
    local function validWorldCoordinate(x, y, z, role)
        if z < WORLD_MIN_Z or z > WORLD_MAX_Z then
            error("RailroaderRVTest: " .. tostring(role) .. " is outside legal z range")
        end
        local validOk, valid = ServerUtil.invoke(world, "isValidSquare", x, y, z)
        if not validOk or valid ~= true then
            error("RailroaderRVTest: " .. tostring(role) .. " is outside the legal world")
        end
    end

    validWorldCoordinate(targetX, targetY, targetZ, "relocation target")
    -- Validate the entire template base footprint without requiring any
    -- of those remote squares to be loaded yet.
    for y = bounds.clearMinY, bounds.clearMaxY - 1 do
        for x = bounds.clearMinX, bounds.clearMaxX - 1 do
            validWorldCoordinate(x, y, bounds.z, "base")
        end
    end
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        local x = ServerUtil.requiredInteger(entry.x, "wall[" .. tostring(i) .. "].x")
        local y = ServerUtil.requiredInteger(entry.y, "wall[" .. tostring(i) .. "].y")
        local z = ServerUtil.requiredInteger(entry.z, "wall[" .. tostring(i) .. "].z")
        if z ~= bounds.z then
            error("RailroaderRVTest: wall entry is not on the base z level")
        end
        validWorldCoordinate(x, y, z, "wall")
    end
    -- The upper footprint must be legal, but its squares may remain nil until
    -- the player-building phase creates them.
    for y = bounds.roofMinY, bounds.roofMaxY do
        for x = bounds.roofMinX, bounds.roofMaxX do
            validWorldCoordinate(x, y, bounds.roofZ, "roof")
        end
    end
end

local function preflightLoaded(cell, bounds)
    if not cell then
        error("RailroaderRVTest: preflight has no IsoCell")
    end
    validateTargetCoordinates(bounds, bounds.anchor)
    -- Missing squares are valid for this sparse template. The clear pass
    -- walks every managed coordinate but inspects only squares that exist;
    -- the build pass creates and reads back each current template-object host.
    -- Do not require the template base plane or any upper Z layer to pre-exist.
    return true
end

-- A remote teleport is also the engine's chunk-streaming trigger. The target
-- cell may therefore be unavailable when queueGeneration sends the relocation
-- command. Retry only that expected loading failure; malformed contracts or
-- other engine failures cancel the request before any world mutation.
local function targetAreaLoadStatus(player, bounds, safeErrorText)
    local safeText = safeErrorText or function(err)
        local ok, text = pcall(tostring, err)
        return ok and type(text) == "string" and text or "<error formatting failed>"
    end
    local cellOk, cellOrError = pcall(ServerWorld.getCellForPlayer, player)
    if not cellOk then
        local message = safeText(cellOrError)
        if string.find(message, "no IsoCell available", 1, true) then
            return false, message
        end
        return nil, message
    end
    local preflightOk, loaded, preflightError = pcall(preflightLoaded,
        cellOrError, bounds)
    if not preflightOk then
        -- Unexpected contract/engine errors remain a hard cancellation; only
        -- the explicit incomplete-footprint status is retryable.
        return nil, safeText(loaded)
    end
    if loaded == true then
        return true
    end
    if loaded == false then
        return false, safeText(preflightError)
    end
    return nil, "RailroaderRVTest: loaded-area preflight returned no status"
end

local function eachStructureSquare(cell, bounds, callback)
    if type(bounds) ~= "table" then
        return
    end

    local scanBounds = {
        wallMinX = ServerUtil.requiredInteger(bounds.wallMinX, "saved bounds wallMinX"),
        wallMaxX = ServerUtil.requiredInteger(bounds.wallMaxX, "saved bounds wallMaxX"),
        wallMinY = ServerUtil.requiredInteger(bounds.wallMinY, "saved bounds wallMinY"),
        wallMaxY = ServerUtil.requiredInteger(bounds.wallMaxY, "saved bounds wallMaxY"),
        z = ServerUtil.requiredInteger(bounds.z, "saved bounds z"),
        roofMinX = ServerUtil.requiredInteger(bounds.roofMinX, "saved bounds roofMinX"),
        roofMaxX = ServerUtil.requiredInteger(bounds.roofMaxX, "saved bounds roofMaxX"),
        roofMinY = ServerUtil.requiredInteger(bounds.roofMinY, "saved bounds roofMinY"),
        roofMaxY = ServerUtil.requiredInteger(bounds.roofMaxY, "saved bounds roofMaxY"),
        roofZ = ServerUtil.requiredInteger(bounds.roofZ, "saved bounds roofZ"),
        anchor = {
            x = ServerUtil.requiredInteger(bounds.anchor.x, "saved bounds anchor.x"),
            y = ServerUtil.requiredInteger(bounds.anchor.y, "saved bounds anchor.y"),
        },
    }
    Layout.eachStructureCoordinate(scanBounds, function(x, y, z)
        local square = ServerWorld.getSquare(cell, x, y, z)
        if square then
            callback(square, x, y, z)
        end
    end)
end

M.boundsFor = boundsFor
M.walkBounds = walkBounds
M.validateWallContract = validateWallContract
M.validateShellEdgeContract = validateShellEdgeContract
M.validateTargetCoordinates = validateTargetCoordinates
M.preflightLoaded = preflightLoaded
M.targetAreaLoadStatus = targetAreaLoadStatus
M.eachStructureSquare = eachStructureSquare

return M
