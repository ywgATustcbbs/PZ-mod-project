-- RailroaderRVTest server-side world/object primitives.
--
-- The facade owns all events and transaction state.  This require chunk only
-- exposes deterministic helpers for snapshots, tagging, cleanup and engine
-- calls; it never registers an event or accepts client coordinates.

local Constants = require("RailroaderRV/RV_Constants")
local ServerUtil = require("RailroaderRV/RV_ServerUtil")
local OWNER = "RailroaderRVTest"
local M = {}

local function getCellForPlayer(player)
    local ok, cell = ServerUtil.invoke(player, "getCell")
    if ok and cell then
        return cell
    end
    local okGlobal, globalCell = ServerUtil.callGlobal("getCell")
    if okGlobal and globalCell then
        return globalCell
    end
    error("RailroaderRVTest: no IsoCell available")
end

local function getSquare(cell, x, y, z)
    local ok, square = ServerUtil.invoke(cell, "getGridSquare", x, y, z)
    if ok and square then
        return square
    end
    return nil
end

local function collectionSnapshot(collection)
    local result = {}
    if collection == nil then
        return result
    end
    local okSize, size = ServerUtil.invoke(collection, "size")
    local sizeNumber = ServerUtil.toNumber(size)
    if okSize and sizeNumber then
        for i = 0, sizeNumber - 1 do
            local okItem, item = ServerUtil.invoke(collection, "get", i)
            if okItem and item then
                result[#result + 1] = item
            end
        end
        return result
    end
    if type(collection) == "table" then
        for _, item in pairs(collection) do
            if item then
                result[#result + 1] = item
            end
        end
    end
    return result
end

local function appendUnique(result, seen, object)
    if object ~= nil and not seen[object] then
        seen[object] = true
        result[#result + 1] = object
    end
end

local function squareSnapshot(square)
    local result, seen = {}, {}
    local listNames = {
        "getObjects", "getSpecialObjects", "getStaticMovingObjects",
        "getMovingObjects", "getWorldObjects", "getDeadBodys", "getCorpses",
    }
    for i = 1, #listNames do
        local ok, collection = ServerUtil.invoke(square, listNames[i])
        if ok then
            local snapshot = collectionSnapshot(collection)
            for j = 1, #snapshot do
                appendUnique(result, seen, snapshot[j])
            end
        end
    end
    local okFloor, floor = ServerUtil.invoke(square, "getFloor")
    if okFloor and floor then
        appendUnique(result, seen, floor)
    end
    local corpseMethods = { "getCorpse", "getDeadBody" }
    for i = 1, #corpseMethods do
        local ok, corpse = ServerUtil.invoke(square, corpseMethods[i])
        if ok and corpse then
            appendUnique(result, seen, corpse)
        end
    end
    -- Vehicles live in the chunk vehicle list rather than square:getObjects();
    -- getVehicleContainer() is the B42.20 bridge needed for permanent removal.
    local okVehicle, vehicle = ServerUtil.invoke(square, "getVehicleContainer")
    if okVehicle and vehicle then
        appendUnique(result, seen, vehicle)
    end
    return result
end

local function objectModData(object)
    local ok, data = ServerUtil.invoke(object, "getModData")
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

local function tagObject(object, generation, role, extraData)
    local data = objectModData(object)
    if not data then
        error("RailroaderRVTest: generated object has no modData for role " .. tostring(role))
    end
    local generationNumber = ServerUtil.toNumber(generation)
    if generationNumber == nil or math.floor(generationNumber) ~= generationNumber
        or generationNumber < 1 or role == nil then
        error("RailroaderRVTest: generated object tag is incomplete")
    end
    generation = generationNumber
    local rvId = extraData and extraData.rvId
    local bitmapVersion = extraData and ServerUtil.toNumber(extraData.bitmapVersion)
    if rvId == nil or tostring(rvId) == ""
        or bitmapVersion ~= Constants.BITMAP_VERSION then
        error("RailroaderRVTest: generated object boundary identity is incomplete")
    end
    data.owner = OWNER
    data.rvId = tostring(rvId)
    data.generation = generation
    data.bitmapVersion = bitmapVersion
    data.role = role
    if data.RailroaderRVTest ~= nil and type(data.RailroaderRVTest) ~= "table" then
        error("RailroaderRVTest: generated object tag namespace is not a table")
    end
    data.RailroaderRVTest = data.RailroaderRVTest or {}
    data.RailroaderRVTest.owner = OWNER
    data.RailroaderRVTest.rvId = tostring(rvId)
    data.RailroaderRVTest.generation = generation
    data.RailroaderRVTest.bitmapVersion = bitmapVersion
    data.RailroaderRVTest.role = role
    if type(extraData) == "table" then
        for key, value in pairs(extraData) do
            data.RailroaderRVTest[key] = value
        end
    end
    -- Re-assert all ownership identity after copying optional metadata.
    -- `extraData` is only descriptive (edge/sprite state), never authority.
    data.RailroaderRVTest.owner = OWNER
    data.RailroaderRVTest.rvId = tostring(rvId)
    data.RailroaderRVTest.generation = generation
    data.RailroaderRVTest.bitmapVersion = bitmapVersion
    data.RailroaderRVTest.role = role
    -- New objects are not on the client yet.  Do not transmit an object-index
    -- modData delta here: the creator sends one complete object packet after
    -- attachment and all object-specific state is final.  Existing objects
    -- (notably replaced floors) explicitly send their deltas in createFloor.
    local verify = objectModData(object)
    if not verify or verify.owner ~= OWNER
        or tostring(verify.rvId) ~= tostring(rvId)
        or verify.role ~= role
        or ServerUtil.toNumber(verify.generation) ~= ServerUtil.toNumber(generation)
        or ServerUtil.toNumber(verify.bitmapVersion) ~= bitmapVersion then
        error("RailroaderRVTest: generated object tag verification failed for role " .. tostring(role))
    end
end

local function withTagIdentity(extraData, tagContext)
    local bitmapVersion = type(tagContext) == "table"
        and ServerUtil.toNumber(tagContext.bitmapVersion) or nil
    if type(tagContext) ~= "table" or tagContext.rvId == nil
        or tostring(tagContext.rvId) == ""
        or bitmapVersion ~= Constants.BITMAP_VERSION then
        error("RailroaderRVTest: boundary tag identity is incomplete")
    end
    local result = {}
    if type(extraData) == "table" then
        for key, value in pairs(extraData) do result[key] = value end
    end
    -- Context identity is authoritative; per-object metadata must not be
    -- able to overwrite the RV/generation snapshot tokens.
    result.rvId = tostring(tagContext.rvId)
    result.bitmapVersion = bitmapVersion
    return result
end

local function isTaggedForGeneration(object, generation, rvId, bitmapVersion)
    if generation == nil or rvId == nil or bitmapVersion == nil then
        return false
    end
    local data = objectModData(object)
    if not data then
        return false
    end
    local function matches(tag)
        if type(tag) ~= "table" or tag.owner ~= OWNER
            or ServerUtil.toNumber(tag.generation) ~= ServerUtil.toNumber(generation) then
            return false
        end
        return tostring(tag.rvId) == tostring(rvId)
            and ServerUtil.toNumber(tag.bitmapVersion) == ServerUtil.toNumber(bitmapVersion)
    end
    if matches(data) then
        return true
    end
    local nested = data.RailroaderRVTest
    return matches(nested)
end

local function isPlayerObject(object)
    if ServerUtil.classInstance(object, "IsoPlayer") then
        return true
    end
    local ok, result = ServerUtil.invoke(object, "isPlayer")
    return ok and result == true
end

local function isVehicleObject(object)
    if ServerUtil.classInstance(object, "BaseVehicle") or ServerUtil.classInstance(object, "IsoVehicle") then
        return true
    end
    local ok, result = ServerUtil.invoke(object, "isVehicle")
    return ok and result == true
end

local function deregisterSpecialSystems(object)
    -- Utility objects are ordinary IsoObject/IsoThumpable instances and do
    -- not participate in any global collection system.  Object removal is
    -- owned by transmitRemoveItemFromSquare below.
    return object
end

local function removeCorpse(square, corpse)
    -- B42.20's signature is removeCorpse(IsoDeadBody, boolean).  Passing
    -- false lets the server emit RemoveCorpseFromMap; the old one-argument
    -- probe failed and the true (remote) fallback suppressed that packet.
    local ok = ServerUtil.invoke(square, "removeCorpse", corpse, false)
    if not ok then
        error("RailroaderRVTest: B42.20 removeCorpse API is unavailable")
    end
end

local function removeZombie(square, zombie)
    -- IsoGameCharacter.dieNetwork(killer, weapon, gory, listener) is the
    -- dedicated-server death API.  Calling it with no arguments (the old
    -- implementation) never matched the B42.20 method and left clients with
    -- live zombies.
    local networkDied, body = ServerUtil.invoke(zombie, "dieNetwork", nil, nil, true, nil)
    if not networkDied then
        ServerUtil.invoke(zombie, "setHealth", 0)
        networkDied, body = ServerUtil.invoke(zombie, "dieNetwork", nil, nil, true, nil)
    end
    if networkDied then
        if body then
            removeCorpse(square, body)
        end
        return
    end
    -- Single-player/debug fallback.  die() creates the corpse locally; the
    -- next square rebuild will include it in getDeadBodys if the engine keeps
    -- one, while these calls ensure the zombie itself is gone.
    ServerUtil.invoke(zombie, "die")
    ServerUtil.invoke(zombie, "removeFromWorld")
    ServerUtil.invoke(zombie, "removeFromSquare")
end

local function removeAnimal(animal)
    -- IsoAnimal:delete() is the B42 removal entry point; no list mutation is
    -- performed directly, so the moving-object systems retain their invariants.
    ServerUtil.invoke(animal, "delete")
    ServerUtil.invoke(animal, "removeFromWorld")
    ServerUtil.invoke(animal, "removeFromSquare")
end

local function removeVehicleSafely(vehicle)
    -- Do not guess at a vehicle removal path.  B42.20's permanent removal
    -- method performs the server-side persistence and network deletion.
    local ok = ServerUtil.callSucceeded(vehicle, "permanentlyRemove")
    if not ok then
        error("RailroaderRVTest: vehicle present but B42.20 permanentlyRemove is unavailable")
    end
end

local function validateVehiclePath(vehicle)
    if type(vehicle.permanentlyRemove) ~= "function" then
        error("RailroaderRVTest: vehicle present but B42.20 permanentlyRemove is unavailable")
    end
end

local function getSpriteName(object)
    local spriteOk, sprite = ServerUtil.invoke(object, "getSprite")
    if not spriteOk or not sprite then
        return nil
    end
    local nameOk, name = ServerUtil.invoke(sprite, "getName")
    if not nameOk or name == nil then
        return nil
    end
    return tostring(name)
end

local function clearGenerationTag(object)
    local data = objectModData(object)
    if not data then
        error("RailroaderRVTest: generated object has no modData while clearing tag")
    end
    if data.owner == OWNER then
        data.owner = nil
        data.rvId = nil
        data.generation = nil
        data.bitmapVersion = nil
        data.role = nil
    end
    local nested = data.RailroaderRVTest
    if type(nested) == "table" and nested.owner == OWNER then
        nested.owner = nil
        nested.rvId = nil
        nested.generation = nil
        nested.bitmapVersion = nil
        nested.role = nil
        nested.previousSprite = nil
        nested.createdByGeneration = nil
        -- Keep the namespace itself.  The dedicated-server Kahlua runtime does
        -- not provide Lua's `next` primitive, and an empty namespace is safe;
        -- retaining it also avoids touching unrelated modData keys.
    end
    if not ServerUtil.callSucceeded(object, "transmitModData") then
        error("RailroaderRVTest: generated object tag removal transmission failed")
    end
end

local function squareContainsObject(square, object)
    local objectsOk, objects = ServerUtil.invoke(square, "getObjects")
    if not objectsOk or not objects then
        return nil
    end
    local sizeOk, size = ServerUtil.invoke(objects, "size")
    local sizeNumber = ServerUtil.toNumber(size)
    if not sizeOk or not sizeNumber then
        return nil
    end
    for i = 0, sizeNumber - 1 do
        local itemOk, item = ServerUtil.invoke(objects, "get", i)
        if not itemOk then
            return nil
        end
        if item == object then
            return true
        end
    end
    return false
end

local function restoreTaggedFloor(square, object)
    local data = objectModData(object)
    local nested = data and data.RailroaderRVTest or nil
    if type(nested) ~= "table" or nested.owner ~= OWNER
        or nested.createdByGeneration ~= false or not nested.previousSprite then
        return false
    end

    local previousSprite = tostring(nested.previousSprite)
    local currentSprite = getSpriteName(object)
    if not currentSprite then
        error("RailroaderRVTest: tagged floor has no current sprite during rollback")
    end
    if currentSprite ~= previousSprite then
        local spriteOk, spriteObject = ServerUtil.callGlobal("getSprite", previousSprite)
        if not spriteOk or not spriteObject then
            error("RailroaderRVTest: previous floor sprite is unavailable: " .. previousSprite)
        end
        if not ServerUtil.callSucceeded(object, "setSprite", spriteObject)
            or not ServerUtil.callSucceeded(object, "transmitUpdatedSpriteToClients") then
            error("RailroaderRVTest: previous floor sprite restoration failed")
        end
    end
    clearGenerationTag(object)
    return true
end

local function removeGenericObject(square, object, restoreTaggedFloors)
    local floor = select(2, ServerUtil.invoke(square, "getFloor"))
    if restoreTaggedFloors and floor == object and restoreTaggedFloor(square, object) then
        return
    end
    deregisterSpecialSystems(object)
    local removeOk, removeIndex = ServerUtil.invoke(square, "transmitRemoveItemFromSquare", object)
    local indexNumber = ServerUtil.toNumber(removeIndex)
    if not removeOk or not indexNumber or indexNumber < 0 then
        error("RailroaderRVTest: object removal transmission failed")
    end
    -- On the B42 server this call delegates to GameServer.RemoveItemFromMap,
    -- which emits the packet, fires OnObjectAboutToBeRemoved, detaches the
    -- object from world/square, and recalculates neighbours.  Calling any of
    -- those steps again risks a double event or a second list mutation.
    local stillPresent = squareContainsObject(square, object)
    if stillPresent ~= false then
        error("RailroaderRVTest: object removal was not observable")
    end
end

local function removeObject(square, object, restoreTaggedFloors)
    if isPlayerObject(object) then
        return
    end
    if isVehicleObject(object) then
        removeVehicleSafely(object)
        return
    end
    if ServerUtil.classInstance(object, "IsoZombie") then
        removeZombie(square, object)
        return
    end
    if ServerUtil.classInstance(object, "IsoAnimal") then
        removeAnimal(object)
        return
    end
    if ServerUtil.classInstance(object, "IsoDeadBody") then
        removeCorpse(square, object)
        return
    end
    removeGenericObject(square, object, restoreTaggedFloors)
end

local function recalcSquare(square)
    ServerUtil.invoke(square, "RecalcProperties")
    -- B42.20 exposes the Java method as RecalcAllWithNeighbours(boolean).
    -- The lower-case spellings are not engine methods and silently made the
    -- old implementation leave collision/room caches stale.
    ServerUtil.invoke(square, "RecalcAllWithNeighbours", true)
end

local function clearSquare(square, onlyGeneration, rvId, bitmapVersion)
    local objects = squareSnapshot(square)
    -- Validate all vehicles before removing any object on this square.  This
    -- makes an unknown vehicle API a clean transaction failure, not data loss.
    for i = 1, #objects do
        if isVehicleObject(objects[i]) and (not onlyGeneration
            or isTaggedForGeneration(objects[i], onlyGeneration, rvId,
                bitmapVersion)) then
            validateVehiclePath(objects[i])
        end
    end
    for i = 1, #objects do
        local object = objects[i]
        if not onlyGeneration or isTaggedForGeneration(object, onlyGeneration,
            rvId, bitmapVersion) then
            -- Generation rollback restores a tagged pre-existing floor, while
            -- the cleanup-only pass must remove every floor, including one
            -- left tagged by an earlier generation.
            removeObject(square, object, onlyGeneration ~= nil)
        end
    end
    recalcSquare(square)
end

M.getCellForPlayer = getCellForPlayer
M.getSquare = getSquare
M.collectionSnapshot = collectionSnapshot
M.squareSnapshot = squareSnapshot
M.objectModData = objectModData
M.tagObject = tagObject
M.withTagIdentity = withTagIdentity
M.isTaggedForGeneration = isTaggedForGeneration
M.isPlayerObject = isPlayerObject
M.isVehicleObject = isVehicleObject
M.deregisterSpecialSystems = deregisterSpecialSystems
M.removeCorpse = removeCorpse
M.removeZombie = removeZombie
M.removeAnimal = removeAnimal
M.removeVehicleSafely = removeVehicleSafely
M.validateVehiclePath = validateVehiclePath
M.getSpriteName = getSpriteName
M.clearGenerationTag = clearGenerationTag
M.squareContainsObject = squareContainsObject
M.restoreTaggedFloor = restoreTaggedFloor
M.removeGenericObject = removeGenericObject
M.removeObject = removeObject
M.recalcSquare = recalcSquare
M.clearSquare = clearSquare

return M
