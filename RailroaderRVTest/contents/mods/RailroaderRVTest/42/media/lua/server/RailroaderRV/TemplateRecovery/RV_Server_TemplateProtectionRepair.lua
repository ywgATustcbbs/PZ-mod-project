-- TemplateProtectionRepair owns cell inspection and world correction for the
-- current RV template. The live world is compared against one module-level map
-- derived from the template, so world coordinates always come from the current
-- boundary anchor and a rebuilt or relocated RV needs no per-RV cache.
local instance = nil
return function(ctx)
if instance then return instance end
local Constants = ctx.Constants
local RV = ctx.RV
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local createCapturedTemplateObject = ctx.createCapturedTemplateObject
local configureCapturedDoorFrame = ctx.configureCapturedDoorFrame
local Boundary = ctx.Boundary
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local TemplateGeometry = require("RailroaderRV/RoomTemplate/RV_TemplateGeometry")
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local templateObjects = RoomTemplate.orderedObjects(Template)

local function integer(value)
    local number = ServerUtil.toNumber(value)
    if type(number) ~= "number" or number ~= number
        or number <= -math.huge or number >= math.huge
        or math.floor(number) ~= number then
        return nil
    end
    return number
end

local function coordinateKey(x, y, z)
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

-- Template-derived protection map: one entry per template object, keyed by its
-- template XY cell. The world transform of an entry is always derived from the
-- current boundary anchor, so nothing here is bound to an RV or generation.
local entriesByCell = {}
local function templateCellKey(x, y)
    return tostring(x) .. ":" .. tostring(y)
end
for index = 1, #templateObjects do
    local captured = templateObjects[index]
    local key = templateCellKey(captured.x, captured.y)
    local entries = entriesByCell[key]
    if not entries then
        entries = {}
        entriesByCell[key] = entries
    end
    entries[#entries + 1] = captured
end

local function entryAt(anchor, x, y, z)
    local offset = TemplateGeometry.worldToTemplate({
        x = x, y = y, z = z,
    }, anchor)
    if not offset then return nil end
    local cellX, cellY, cellZ = math.floor(offset.x), math.floor(offset.y),
        math.floor(offset.z)
    if cellX ~= offset.x or cellY ~= offset.y or cellZ ~= offset.z then
        return nil
    end
    local entries = entriesByCell[templateCellKey(cellX, cellY)]
    for index = 1, #(entries or {}) do
        local captured = entries[index]
        if captured.z == cellZ then
            return {
                templateIndex = captured.templateIndex,
                x = anchor.x + captured.x,
                y = anchor.y + captured.y,
                z = anchor.z + captured.z,
                class = captured.class,
                name = captured.name,
                sprite = captured.sprite,
                north = captured.north,
                direction = captured.direction,
                state = captured.state,
                protected = captured.protected,
            }
        end
    end
    return nil
end

-- Every template object expected on the layers of one cell. An empty result
-- means the template protects nothing there.
local function templateEntriesAt(boundary, anchor, x, y)
    local entries = {}
    for z = boundary.managed.minZ, boundary.managed.maxZ - 1 do
        local entry = entryAt(anchor, x, y, z)
        if entry then entries[#entries + 1] = entry end
    end
    return entries
end

local function loadedLayerForCell(cell, x, y, z)
    local chunkOk, chunk = ServerUtil.invoke(cell, "getChunkForGridSquare",
        x, y, z)
    if not chunkOk or not chunk then return false end
    local loadedOk, loaded = pcall(function() return chunk.loaded end)
    return loadedOk and loaded == true
end

-- The trusted identity written by this mod when a captured object is created.
-- A player build carries none of these fields, which is what distinguishes it
-- from the template object it replaces.
local function objectTag(object)
    local data = ServerWorld.objectModData(object)
    if type(data) ~= "table" or data.owner ~= Constants.MOD_ID then
        return nil
    end
    local nested = data.RailroaderRVTest
    if type(nested) ~= "table" or nested.owner ~= Constants.MOD_ID
        or tostring(data.rvId) ~= tostring(nested.rvId)
        or integer(data.generation) ~= integer(nested.generation)
        or data.role ~= nested.role then
        return nil
    end
    return nested
end

local function objectTemplateIndex(object)
    local tag = objectTag(object)
    return tag and integer(tag.templateIndex) or nil
end

local function objectCell(object)
    local xOk, x = ServerUtil.invoke(object, "getX")
    local yOk, y = ServerUtil.invoke(object, "getY")
    local zOk, z = ServerUtil.invoke(object, "getZ")
    return xOk and yOk and zOk and integer(x), integer(y), integer(z)
end

local function isOpenableClass(className)
    return className == "IsoDoor" or className == "IsoWindow"
end

local function isVisualCorner(entry)
    return entry.class == "IsoObject" and entry.name == "Wooden Wall"
        and entry.sprite == "walls_interior_house_02_35"
end

local function isFloorEntry(entry)
    return entry.class == "IsoObject" and not isVisualCorner(entry)
end

local function objectMatchesCaptured(object, expected)
    if not ServerUtil.classInstance(object, expected.class) then return false end
    local nameOk, name = ServerUtil.invoke(object, "getName")
    local directionOk, direction = ServerUtil.invoke(object, "getDir")
    local directionTable = rawget(_G, "IsoDirections")
    local expectedDirection = directionTable and directionTable[expected.direction]
    if not nameOk or tostring(name) ~= tostring(expected.name)
        or not directionOk or not expectedDirection
        or direction ~= expectedDirection
        or tostring(ServerWorld.getSpriteName(object))
            ~= tostring(expected.sprite) then
        return false
    end
    if expected.north ~= nil then
        local northOk, north = ServerUtil.invoke(object, "getNorth")
        if not northOk or north ~= expected.north then return false end
    end
    return true
end

local function objectMatchesStoredState(object, expected)
    local stateGetters = {
        health = "getHealth", maxHealth = "getMaxHealth",
        hoppable = "isHoppable", locked = "isLocked",
        canPassThrough = "isCanPassThrough",
        blockAllTheSquare = "isBlockAllTheSquare",
        doRender = "getDoRender", thumpable = "isThumpable",
    }
    for key, value in pairs(expected.state or {}) do
        local getter = stateGetters[key]
        if not getter then return false end
        local stateOk, state = ServerUtil.invoke(object, getter)
        if not stateOk or state ~= value then return false end
    end
    return true
end

-- A door or window is opened, closed and locked by ordinary play, so only its
-- identity is compared; every other template object must also still carry the
-- state the template recorded.
local function objectMatchesTemplate(object, expected)
    if not objectMatchesCaptured(object, expected) then return false end
    if isOpenableClass(expected.class) then return true end
    return objectMatchesStoredState(object, expected)
end

-- True when one of these objects is the tagged template object of the entry.
local function objectIsTemplateEntry(objects, entry)
    for index = 1, #objects do
        local object = objects[index]
        if objectTemplateIndex(object) == entry.templateIndex
            and objectMatchesTemplate(object, entry) then
            return true
        end
    end
    return false
end

-- Objects a protected template entry on this cell can legitimately replace: the
-- captured object itself, a duplicate of it, or the build that took its place.
-- An unrelated object on a protected tile is left untouched.
local function isRepairTarget(object, entries, objectIsFloor)
    for index = 1, #entries do
        local expected = entries[index]
        if expected.protected and (ServerUtil.classInstance(object, expected.class)
            or objectIsFloor and isFloorEntry(expected)) then
            return true
        end
    end
    return false
end

-- Only an object that still carries its entry identity is the template object;
-- anything else left on a protected tile is the extra object this pass removes.
local function isSpareObject(object, entries, objectIsFloor)
    if not isRepairTarget(object, entries, objectIsFloor) then return false end
    local templateIndex = objectTemplateIndex(object)
    if not templateIndex then return true end
    for index = 1, #entries do
        local entry = entries[index]
        if entry.templateIndex == templateIndex
            and objectMatchesTemplate(object, entry) then
            return false
        end
    end
    return true
end

local function isBloodOrSplat(object)
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

-- Non-template world content is never a repair target.
local function protectedWorldObject(object)
    if ServerWorld.isPlayerObject(object)
        or ServerWorld.isVehicleObject(object) then
        return true
    end
    local classes = { "IsoWorldInventoryObject", "IsoZombie", "IsoAnimal",
        "IsoDeadBody" }
    for i = 1, #classes do
        if ServerUtil.classInstance(object, classes[i]) then return true end
    end
    return isBloodOrSplat(object)
end

-- A container that holds items is never removed, and removal is skipped when
-- the contents cannot be proven empty.
local function hasStoredContainerItems(object)
    local knownContainer = ServerUtil.classInstance(object, "IsoThumpable")
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

local function squareContainsObject(square, object)
    local containsOk, present = pcall(ServerWorld.squareContainsObject, square,
        object)
    if not containsOk then
        error("RailroaderRVTest: template-protection repair square membership lookup failed")
    end
    return present == true
end

-- The removal marker is read by the RoofRefresh removal filter; it stays set
-- only for the synchronous removal call performed here.
local function removeObject(square, object)
    local server = RV.Server
    local previous = server._templateProtectionRepairRemovalObject
    server._templateProtectionRepairRemovalObject = object
    local removeOk, removeError = pcall(ServerWorld.removeGenericObject, square,
        object, false)
    server._templateProtectionRepairRemovalObject = previous
    if not removeOk then
        error("RailroaderRVTest: template-protection repair removal failed: "
            .. tostring(removeError))
    end
    if squareContainsObject(square, object) then
        error("RailroaderRVTest: template-protection repair removal was not observable")
    end
end

-- The object is removed instead of being rebuilt in place; the current template
-- entry recreates it on the same cell during the restore pass.
local function deleteCapturedObject(square, object, templateIndex)
    local x, y, z = objectCell(object)
    if not x or not y or not z then
        error("RailroaderRVTest: template-protection repair target has no coordinate")
    end
    if hasStoredContainerItems(object) then
        print("[RailroaderRVTest] template-protection repair retained "
            .. coordinateKey(x, y, z)
            .. ": container contents are present")
        return false
    end
    removeObject(square, object)
    print("[RailroaderRVTest] template-protection repair rebuilt templateIndex="
        .. tostring(templateIndex) .. " at " .. coordinateKey(x, y, z))
    return true
end

-- The template decides how many objects share a cell; an object tagged with the
-- expected template index and still carrying the captured identity is that
-- entry. A captured door frame whose pass-through state was lost is rebuilt.
local function restoreEntry(cell, square, objects, entry, boundary)
    local tagContext = { rvId = boundary.rvId }
    for index = 1, #objects do
        local object = objects[index]
        if objectTemplateIndex(object) == entry.templateIndex
            and objectMatchesCaptured(object, entry) then
            if entry.name == "Wooden Door Frame" then
                -- Re-applying the frame state keeps pass-through set on a frame
                -- that survived, and reactivates a replaced one.
                pcall(configureCapturedDoorFrame, object, entry)
            end
            return
        end
    end
    createCapturedTemplateObject(cell, square, entry, boundary.generation,
        tagContext)
end

local function repairTemplateProtectionCell(player, expectedBoundary, x, y)
    local contextOk, boundary = pcall(Boundary.boundaryForPlayer, player)
    if not contextOk or boundary ~= expectedBoundary then
        return false, "queued RV generation is stale"
    end
    local anchor = TemplateGeometry.anchorFromManaged(boundary.managed, Template)
    -- A build cell belongs to the player: normal building and removing there is
    -- never corrected, and that is an ordinary outcome rather than a failure.
    if TemplateGeometry.isBuildable({ x = x, y = y, z = anchor.z }, anchor,
        Template) then
        return false
    end
    local entries = templateEntriesAt(boundary, anchor, x, y)
    if #entries == 0 then return false end

    local repairLayers = {}
    for index = 1, #entries do
        repairLayers[entries[index].z] = true
    end
    local cellOk, cell = pcall(ServerWorld.getCellForPlayer, player)
    if not cellOk or not cell then
        return false, "current player cell is unavailable"
    end

    local repaired = false
    for z = boundary.managed.minZ, boundary.managed.maxZ - 1 do
        local squareOk, square = pcall(ServerWorld.getSquare, cell, x, y, z)
        if not squareOk then
            return false, "template-protection-repair square lookup failed"
        end
        if square and repairLayers[z] and loadedLayerForCell(cell, x, y, z) then
            local objectsOk, objects = pcall(ServerWorld.squareSnapshot, square)
            if not objectsOk or type(objects) ~= "table" then
                return false, "template-protection-repair object snapshot failed"
            end
            local floorOk, floor = ServerUtil.invoke(square, "getFloor")
            if not floorOk then
                return false, "template-protection-repair floor lookup failed"
            end
            for index = 1, #objects do
                local object = objects[index]
                local objectIsFloor = floor == object
                if not protectedWorldObject(object)
                    and isSpareObject(object, entries, objectIsFloor) then
                    repaired = deleteCapturedObject(square, object,
                        objectTemplateIndex(object)) or repaired
                end
            end
            for entryIndex = 1, #entries do
                local entry = entries[entryIndex]
                if entry.z == z
                    and not objectIsTemplateEntry(objects, entry) then
                    restoreEntry(cell, square, objects, entry, boundary)
                    repaired = true
                    -- Read the square again so an entry restored earlier on
                    -- this layer is no longer seen as missing.
                    local liveOk, live = pcall(ServerWorld.squareSnapshot, square)
                    if not liveOk or type(live) ~= "table" then
                        return false, "template-protection-repair object snapshot failed"
                    end
                    objects = live
                end
            end
        end
    end
    return repaired
end

local server = type(RV) == "table" and RV.Server or nil
if type(server) == "table" then
    server.isTemplateProtectionRepairRemoval = function(object)
        return object ~= nil
            and server._templateProtectionRepairRemovalObject == object
    end
end

instance = {
    repairCell = repairTemplateProtectionCell,
}
return instance
end
