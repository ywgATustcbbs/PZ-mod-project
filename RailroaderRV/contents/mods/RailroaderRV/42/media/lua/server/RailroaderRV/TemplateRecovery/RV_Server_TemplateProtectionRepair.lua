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
local entriesByCellByTemplate = {}

local function integer(value)
    local number = ServerUtil.toNumber(value)
    if type(number) ~= "number" or number ~= number
        or number <= -math.huge or number >= math.huge
        or math.floor(number) ~= number then
        return nil
    end
    return number
end

-- Template-derived protection map: one entry per template object, keyed by its
-- template XY cell. The world transform of an entry is always derived from the
-- current boundary anchor, so nothing here is bound to an RV or generation.
local function templateCellKey(x, y)
    return tostring(x) .. ":" .. tostring(y)
end
for _, templateId in ipairs({ RoomTemplate.TEMPLATE_ID,
    RoomTemplate.ENGINE_AREA_TEMPLATE_ID }) do
    local template = RoomTemplate.get(templateId)
    local templateObjects = RoomTemplate.orderedObjects(template)
    local entriesByCell = {}
    entriesByCellByTemplate[templateId] = entriesByCell
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
end

-- Shell edge ownership of one template entry, indexed by template index. The
-- ledger is per RV generation, so this is rebuilt on every cell check and never
-- cached at module load. An authored ledger that is internally inconsistent is
-- this mod's own data being wrong, so it raises instead of degrading silently.
local function shellEdgeMap(boundary, template)
    local map = {}
    for key, edge in pairs(boundary.shellEdges) do
        if type(key) ~= "string" or type(edge) ~= "table"
            or edge.edgeKey ~= key or type(edge.role) ~= "string" then
            error("RailroaderRV: shell edge ledger entry is inconsistent for key "
                .. tostring(key))
        end
        local parts = edge.templateIndices
        if type(parts) ~= "table" or #parts < 1
            or integer(parts[1]) ~= integer(edge.templateIndex) then
            error("RailroaderRV: shell edge ledger entry has no template index list for key "
                .. tostring(key))
        end
        for index = 1, #parts do
            local templateIndex = integer(parts[index])
            if not templateIndex or templateIndex < 1
                or templateIndex > template.metadata.objectCount
                or map[templateIndex] ~= nil then
                error("RailroaderRV: shell edge ledger entry is inconsistent for key "
                    .. tostring(key))
            end
            map[templateIndex] = edge
        end
    end
    return map
end

local function templateCoordinates(anchor, x, y, z)
    local offset = TemplateGeometry.worldToTemplate({
        x = x, y = y, z = z,
    }, anchor)
    if not offset then return nil end
    local cellX, cellY, cellZ = math.floor(offset.x), math.floor(offset.y),
        math.floor(offset.z)
    if cellX ~= offset.x or cellY ~= offset.y or cellZ ~= offset.z then
        return nil
    end
    return cellX, cellY, cellZ
end

local function entryForCaptured(anchor, edgeMap, captured)
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
        edge = edgeMap[captured.templateIndex],
    }
end

-- Return every captured entry at this XY in template-index order. Callers use
-- only protected entries for correction, while retaining all authored entries
-- here makes same-cell, multi-layer template data complete.
local function templateEntriesAt(boundary, anchor, edgeMap, x, y, template)
    local templateX, templateY = templateCoordinates(anchor, x, y, anchor.z)
    if templateX == nil then return {} end
    local entriesByCell = entriesByCellByTemplate[template.metadata.id]
    local capturedEntries = entriesByCell[templateCellKey(templateX, templateY)]
    local entries = {}
    if capturedEntries == nil then return entries end
    for index = 1, #capturedEntries do
        local captured = capturedEntries[index]
        local worldZ = anchor.z + captured.z
        if worldZ >= boundary.managed.minZ
            and worldZ < boundary.managed.maxZ then
            entries[#entries + 1] = entryForCaptured(anchor, edgeMap, captured)
        end
    end
    return entries
end

local function templateProxyAtOffset(x, y, z, template)
    local powerProxy = template.powerProxy
    if x == powerProxy.x and y == powerProxy.y and z == powerProxy.z then
        return true
    end
    local templateWaterProxies = RoomTemplate.waterProxies(template)
    for index = 1, #templateWaterProxies do
        local proxy = templateWaterProxies[index]
        if x == proxy.x and y == proxy.y and z == proxy.z then
            return true
        end
    end
    return false
end

local function templateProxyAtColumn(anchor, x, y, template)
    local templateX, templateY = templateCoordinates(anchor, x, y, anchor.z)
    if templateX == nil then return false end
    local powerProxy = template.powerProxy
    if templateX == powerProxy.x and templateY == powerProxy.y then
        return true
    end
    local templateWaterProxies = RoomTemplate.waterProxies(template)
    for index = 1, #templateWaterProxies do
        local proxy = templateWaterProxies[index]
        if templateX == proxy.x and templateY == proxy.y then return true end
    end
    return false
end

-- Candidate filtering includes captured protection flags and both template-declared proxies.
local function isProtectedCell(boundary, x, y)
    local template = RoomTemplate.get(boundary.templateId)
    local entriesByCell = entriesByCellByTemplate[template.metadata.id]
    local anchor = TemplateGeometry.anchorFromManaged(boundary.managed, template)
    for z = boundary.managed.minZ, boundary.managed.maxZ - 1 do
        local cellX, cellY, cellZ = templateCoordinates(anchor, x, y, z)
        if cellX ~= nil then
            if templateProxyAtOffset(cellX, cellY, cellZ, template) then
                return true
            end
            local entries = entriesByCell[templateCellKey(cellX, cellY)]
            if entries ~= nil then
                for index = 1, #entries do
                    local captured = entries[index]
                    if captured.z == cellZ and captured.protected then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- The trusted identity written by this mod when a captured object is created.
-- A player build carries no template entry index, which is what distinguishes it
-- from the template object it replaces.
local function objectTag(object)
    local data = ServerWorld.objectModData(object)
    if data == nil then return nil end
    local tag = data.RailroaderRV
    if tag == nil then return nil end
    if type(tag) ~= "table" then
        error("RailroaderRV: generated object tag is not a table")
    end
    if tag.owner ~= Constants.MOD_ID then return nil end
    return tag
end

local function objectTemplateIndex(object)
    local tag = objectTag(object)
    if tag == nil or tag.playerBuilt == true
        or tag.role == RoomTemplate.PROXY_ROLES.power
        or tag.role == RoomTemplate.PROXY_ROLES.water then
        return nil
    end
    local templateIndex = tag.templateIndex
    if type(templateIndex) ~= "number" or templateIndex < 1
        or math.floor(templateIndex) ~= templateIndex then
        error("RailroaderRV: generated template object has no template index")
    end
    return templateIndex
end

local function isUtilityProxyObject(object)
    local tag = objectTag(object)
    return tag and (tag.role == RoomTemplate.PROXY_ROLES.power
        or tag.role == RoomTemplate.PROXY_ROLES.water)
end

local function isOpenableClass(className)
    return className == "IsoDoor" or className == "IsoWindow"
end

local function isRuntimeDoorOrWindow(object)
    if ServerUtil.classInstance(object, "IsoDoor")
        or ServerUtil.classInstance(object, "IsoWindow") then
        return true
    end
    if ServerUtil.classInstance(object, "IsoThumpable") then
        local doorOk, isDoor = ServerUtil.invoke(object, "isDoor")
        local windowOk, isWindow = ServerUtil.invoke(object, "isWindow")
        return doorOk and isDoor == true or windowOk and isWindow == true
    end
    return false
end

-- Side-host cells beside authored build cells permit ordinary door/window
-- replacement even when the current object has no captured-template identity.
local function isCabSideDoorOrWindow(object, x, y, z, anchor, template)
    if not isRuntimeDoorOrWindow(object) then return false end
    return TemplateGeometry.isBuildCellSideHost({
        x = x, y = y, z = z,
    }, anchor, template)
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
    for key, value in pairs(expected.state) do
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

-- A shell member is only the template object if its tag also carries the shell
-- edge role and key; the shell ledger reads that role and key to recognise the
-- wall as protected, so a shell member rebuilt without them is not the entry.
local function objectHasShellIdentity(object, edge)
    if not edge then return true end
    local tag = objectTag(object)
    if not tag then return false end
    return tag.role == edge.role and tag.edgeKey == edge.edgeKey
end

-- True when one of these objects is the tagged template object of the entry.
local function objectIsTemplateEntry(objects, entry)
    for index = 1, #objects do
        local object = objects[index]
        if objectTemplateIndex(object) == entry.templateIndex
            and objectMatchesTemplate(object, entry)
            and objectHasShellIdentity(object, entry.edge) then
            return true
        end
    end
    return false
end

-- Every ordinary object on a protected template layer is a correction
-- candidate, regardless of its Java class. Captured template identity, shell
-- identity, and the documented side-host door/window rule decide what remains.
local function isSpareObject(object, entries, sideHostDoorOrWindow)
    if isUtilityProxyObject(object) or sideHostDoorOrWindow then return false end
    local templateIndex = objectTemplateIndex(object)
    if not templateIndex then return true end
    for index = 1, #entries do
        local entry = entries[index]
        if entry.protected and entry.templateIndex == templateIndex
            and objectMatchesTemplate(object, entry)
            and objectHasShellIdentity(object, entry.edge) then
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
    -- Zombie giblets are transient IsoPhysicsObjects, not removable tile objects.
    local classes = { "IsoWorldInventoryObject", "IsoZombie", "IsoAnimal",
        "IsoDeadBody", "IsoZombieGiblets" }
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
    return ServerWorld.squareContainsObject(square, object) == true
end

-- The removal marker is read by the RoofRefresh removal filter; it stays set
-- only for the synchronous removal call performed here.
local function removeObject(square, object)
    local server = RV.Server
    local previous = server._templateProtectionRepairRemovalObject
    server._templateProtectionRepairRemovalObject = object
    -- This repair walks a per-square object snapshot. Remove only this entry:
    -- the engine's safe multi-square path fails when another tile square or
    -- sprite-grid part is unavailable, even though this target square is loaded.
    local removeOk, removeError = pcall(ServerWorld.removeGenericObject, square,
        object, false, false)
    server._templateProtectionRepairRemovalObject = previous
    if not removeOk then
        error(removeError, 0)
    end
    if squareContainsObject(square, object) then
        error("RailroaderRV: template-protection repair removal was not observable")
    end
end

-- Remove non-template objects from protected layers; the restore pass then
-- recreates any missing protected template entries on this cell.
local function removeRepairSpareObject(square, object)
    if hasStoredContainerItems(object) then
        return false
    end
    removeObject(square, object)
    return true
end

-- The template decides how many objects share a cell; an object tagged with the
-- expected template index, still carrying the captured identity and (for a shell
-- member) the shell edge identity is that entry. The shell edge is passed to the
-- creator so a restored shell member keeps the role and edge key the shell
-- ledger recognises. A captured door frame whose pass-through state was lost is
-- rebuilt.
local function restoreEntry(cell, square, objects, entry, boundary)
    local tagContext = { rvId = boundary.rvId,
        templateId = boundary.templateId }
    for index = 1, #objects do
        local object = objects[index]
        if objectTemplateIndex(object) == entry.templateIndex
            and objectMatchesCaptured(object, entry)
            and objectHasShellIdentity(object, entry.edge) then
            if entry.name == "Wooden Door Frame" then
                -- Re-applying the frame state keeps pass-through set on a frame
                -- that survived, and reactivates a replaced one.
                configureCapturedDoorFrame(object, entry)
            end
            return
        end
    end
    createCapturedTemplateObject(cell, square, entry, boundary.generation,
        tagContext, entry.edge)
end

local function repairTemplateProtectionCell(player, expectedBoundary, x, y)
    local boundary = Boundary.boundaryForPlayer(player)
    if boundary ~= expectedBoundary then
        return false, "queued RV generation is stale"
    end
    local template = RoomTemplate.get(boundary.templateId)
    local anchor = TemplateGeometry.anchorFromManaged(boundary.managed, template)
    local proxyColumn = templateProxyAtColumn(anchor, x, y, template)
    local buildable = TemplateGeometry.isBuildable({ x = x, y = y,
        z = anchor.z }, anchor, template)
    if buildable and not proxyColumn then return false end
    local entries = templateEntriesAt(boundary, anchor,
        shellEdgeMap(boundary, template), x, y, template)
    if #entries == 0 and not proxyColumn then return false end

    local cell = ServerWorld.getCellForPlayer(player)

    local repaired = false
    for z = Constants.WORLD_MIN_Z, Constants.WORLD_MAX_Z do
        local square = ServerWorld.getSquare(cell, x, y, z)
        if square then
            local objects = ServerWorld.squareSnapshot(square)
            local layerBuildable = TemplateGeometry.isBuildable({ x = x,
                y = y, z = z }, anchor, template)
            local preserveOrdinaryObjects = buildable or layerBuildable
            local removedOnLayer = false
            for index = 1, #objects do
                local object = objects[index]
                if isUtilityProxyObject(object) then
                    -- Template utility proxies are retained on their scan path.
                elseif not preserveOrdinaryObjects
                    and not protectedWorldObject(object) then
                    local sideHostDoorOrWindow = isCabSideDoorOrWindow(object,
                        x, y, z, anchor, template)
                    local spare = isSpareObject(object, entries,
                        sideHostDoorOrWindow)
                    if spare and removeRepairSpareObject(square, object) then
                        repaired = true
                        removedOnLayer = true
                    end
                end
            end
            if removedOnLayer then
                objects = ServerWorld.squareSnapshot(square)
            end
            if not preserveOrdinaryObjects then
                for entryIndex = 1, #entries do
                    local entry = entries[entryIndex]
                    if entry.z == z and entry.protected
                        and not objectIsTemplateEntry(objects, entry) then
                        restoreEntry(cell, square, objects, entry, boundary)
                        repaired = true
                        -- Read the square again so an entry restored earlier on
                        -- this layer is no longer seen as missing.
                        objects = ServerWorld.squareSnapshot(square)
                    end
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
    isProtectedCell = isProtectedCell,
    repairCell = repairTemplateProtectionCell,
}
return instance
end
