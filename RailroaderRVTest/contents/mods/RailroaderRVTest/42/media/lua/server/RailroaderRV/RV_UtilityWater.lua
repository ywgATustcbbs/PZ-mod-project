-- Server-authoritative canonical water ledger and native plumbing bridge.
--
-- canonicalTank is the only balance.  The hidden usage tank and one hidden
-- proxy per connected fixture are clean-water FluidContainer projections.
-- Clients submit intent only; every object, amount, identity and range is
-- resolved again on the server.

local C = require("RailroaderRV/RV_Constants")
local U = require("RailroaderRV/RV_UtilityConstants")
local Catalog = require("RailroaderRV/RV_UtilityCatalog")
local Store = require("RailroaderRV/RV_UtilityStore")
local Util = require("RailroaderRV/RV_ServerUtil")
local World = require("RailroaderRV/RV_ServerWorld")
local UtilitySprite = require("RailroaderRV/RV_UtilitySprite")

-- Register the isolated blueprint before any utility object can be constructed.
-- OnGameBoot retries this on manager rebuild; makeObject also gates creation
-- on the same postcondition immediately before the complete add packet.
UtilitySprite.install()

local M = {}
local runtimeObjects = {}
local runtimePlayers = {}
local accountingGuard = {}
local tokenSequence = 0
local pendingDetachedFixtures = {}
local fixtureSourceGone
local retireEntry
local removeObject
local objectAttached

local function key(identity)
    return tostring(identity.rvId) .. ":" .. tostring(identity.generation)
        .. ":" .. tostring(identity.bitmapVersion)
end

local function finite(value)
    return Util.toNumber(value) ~= nil
end

local function sameValue(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do
        if not sameValue(value, right[key]) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function clamp(value, low, high)
    value = Util.toNumber(value) or 0
    return math.max(low, math.min(high, value))
end

local function invoke(target, method, ...)
    return Util.invoke(target, method, ...)
end

local function playerPosition(player)
    if not player then return nil end
    local xOk, x = invoke(player, "getX")
    local yOk, y = invoke(player, "getY")
    local zOk, z = invoke(player, "getZ")
    x, y, z = Util.toNumber(x), Util.toNumber(y), Util.toNumber(z)
    if not xOk or not yOk or not zOk or not finite(x) or not finite(y) or not finite(z) then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function inRegion(position, region)
    if type(position) ~= "table" or type(region) ~= "table" then return false end
    local x, y, z = Util.toNumber(position.x), Util.toNumber(position.y), Util.toNumber(position.z)
    local minX, maxX = Util.toNumber(region.minX), Util.toNumber(region.maxX)
    local minY, maxY = Util.toNumber(region.minY), Util.toNumber(region.maxY)
    local minZ, maxZ = Util.toNumber(region.minZ), Util.toNumber(region.maxZ)
    if not finite(x) or not finite(y) or not finite(z) or not finite(minX)
        or not finite(maxX) or not finite(minY) or not finite(maxY)
        or not finite(minZ) or not finite(maxZ) then return false end
    z = math.floor(z)
    return x >= minX and x < maxX and y >= minY and y < maxY
        and z >= minZ and z < maxZ
end

local function coords(object)
    local squareOk, square = invoke(object, "getSquare")
    if not squareOk or not square then return nil end
    local xOk, x = invoke(square, "getX")
    local yOk, y = invoke(square, "getY")
    local zOk, z = invoke(square, "getZ")
    x, y, z = Util.integer(x), Util.integer(y), Util.integer(z)
    if not xOk or not yOk or not zOk or x == nil or y == nil or z == nil then return nil end
    return x, y, z
end

-- Coordinates are always re-read from the resolved server object.  The
-- client hint is only a lookup request and is never copied into the ledger.
local function objectCoordinates(object)
    local x, y, z = coords(object)
    if x == nil then return nil end
    return { x = x, y = y, z = z }
end

local function objectContainer(object)
    local ok, container = invoke(object, "getFluidContainer")
    return ok and container or nil
end

local function externalWaterMatches(object, role)
    if role ~= C.UTILITY_ROLE_TANK and role ~= C.UTILITY_ROLE_PROXY then
        return true
    end
    local expected = role == C.UTILITY_ROLE_TANK
    local readOk, enabled = invoke(object, "getUsesExternalWaterSource")
    if not readOk or enabled ~= expected then
        -- This is an identity/safety mismatch, not a projection that may be
        -- repaired.  A tank with false or a proxy with true could change the
        -- native source graph, so all current-schema operations stop here.
        return false, C.SAVE_REBUILD_REQUIRED
    end
    return true
end

local function objectSprite(object)
    local spriteOk, sprite = invoke(object, "getSprite")
    if not spriteOk or not sprite then return "" end
    local nameOk, name = invoke(sprite, "getName")
    return nameOk and tostring(name or "") or ""
end

local function hiddenObjectFingerprint(role, sprite)
    return tostring(role) .. ":" .. tostring(C.UTILITY_HIDDEN_OBJECT_CLASS)
        .. ":" .. tostring(sprite) .. ":"
end

local function resolveNamedSprite(spriteName)
    local managerClass = rawget(_G, "IsoSpriteManager")
    local manager = managerClass and managerClass.instance
    local lookupOk, sprite = invoke(manager, "getSprite", spriteName)
    if not lookupOk or not sprite then return false, nil, "manager-lookup" end

    local nameOk, name = invoke(sprite, "getName")
    if not nameOk then return false, nil, "sprite-name-read" end
    if name == nil then
        -- IsoSpriteManager files a sprite in namedMap but does not assign the
        -- lookup key to IsoSprite.name.  setName is a Java void call, so only
        -- the invocation and the read-back below are authoritative.
        local setNameOk = invoke(sprite, "setName", spriteName)
        if not setNameOk then return false, nil, "sprite-name-set" end
        nameOk, name = invoke(sprite, "getName")
    end
    if not nameOk or name == nil or tostring(name) ~= tostring(spriteName) then
        return false, nil, "sprite-name-postcondition"
    end
    return true, sprite
end

local function bindNamedSprite(object, spriteName, expectedSprite)
    -- setSpriteFromName resolves IsoSpriteManager.namedMap and therefore
    -- reuses the named instance prepared above.  Its Java return is void.
    -- This proves only the in-memory identity.  The available B42.20.0 source
    -- shows that setSpriteFromName does not write IsoObject.spriteName; loaded
    -- objects therefore must not be rebound here or treated as persistent just
    -- because this postcondition passes.
    local bindOk = invoke(object, "setSpriteFromName", spriteName)
    if not bindOk then return false, "sprite-bind" end

    local spriteOk, sprite = invoke(object, "getSprite")
    local nameOk, name = invoke(sprite, "getName")
    local objectNameOk, objectName = invoke(object, "getSpriteName")
    if not spriteOk or not sprite or sprite ~= expectedSprite then
        return false, "sprite-instance-postcondition"
    end
    if not nameOk or name == nil or tostring(name) ~= tostring(spriteName) then
        return false, "sprite-name-postcondition"
    end
    if not objectNameOk or objectName == nil
        or tostring(objectName) ~= tostring(spriteName) then
        return false, "object-sprite-name-postcondition"
    end
    return true
end

local function printSpriteDiagnostics(object, role, expected, bindOk, bindResult)
    local spriteOk, sprite = invoke(object, "getSprite")
    local spriteNameOk, spriteName = invoke(sprite, "getName")
    local objectSpriteNameOk, objectSpriteName = invoke(object, "getSpriteName")
    local objectNameOk, objectName = invoke(object, "getName")
    print("[RailroaderRVTest] utility sprite diagnostic role=" .. tostring(role)
        .. " expected=" .. tostring(expected)
        .. " bindOk=" .. tostring(bindOk)
        .. " bindResult=" .. tostring(bindResult)
        .. " getSpriteOk=" .. tostring(spriteOk)
        .. " getSpritePresent=" .. tostring(sprite ~= nil)
        .. " spriteGetNameOk=" .. tostring(spriteNameOk)
        .. " spriteGetName=" .. tostring(spriteName)
        .. " objectGetSpriteNameOk=" .. tostring(objectSpriteNameOk)
        .. " objectGetSpriteName=" .. tostring(objectSpriteName)
        .. " objectGetNameOk=" .. tostring(objectNameOk)
        .. " objectGetName=" .. tostring(objectName))
end

local function objectFingerprint(object, role)
    local typeOk, objectType = invoke(object, "getType")
    local scriptOk, script = invoke(object, "getEntityScript")
    local scriptName = ""
    if scriptOk and script then
        local nameOk, name = invoke(script, "getName")
        scriptName = nameOk and tostring(name or "") or ""
    end
    role = tostring(role or "fixture")
    if role == C.UTILITY_ROLE_TANK or role == C.UTILITY_ROLE_PROXY then
        -- Both hidden utility mirrors are current-schema IsoThumpable objects.
        -- Keep the Java class in the fingerprint so an old ordinary IsoObject
        -- tank can never be adopted after the persistence path changes.
        local className = Util.classInstance(object, C.UTILITY_HIDDEN_OBJECT_CLASS)
            and C.UTILITY_HIDDEN_OBJECT_CLASS or "other"
        return role .. ":" .. className .. ":" .. objectSprite(object) .. ":" .. scriptName
    end
    return role .. ":" .. tostring(typeOk and objectType or "")
        .. ":" .. objectSprite(object) .. ":" .. scriptName
end

local function objectTag(object)
    local data = World.objectModData(object)
    local tag = type(data) == "table" and data.RailroaderRVTestUtility or nil
    return type(tag) == "table" and tag or nil
end

local function genericObjectTag(object)
    local data = World.objectModData(object)
    if type(data) ~= "table" then return nil end
    local nested = data.RailroaderRVTest
    if type(nested) == "table" and nested.owner == "RailroaderRVTest"
        and nested.rvId ~= nil and nested.generation ~= nil
        and nested.bitmapVersion ~= nil then
        return nested
    end
    if data.owner == "RailroaderRVTest" and data.rvId ~= nil
        and data.generation ~= nil and data.bitmapVersion ~= nil then
        return data
    end
    return nil
end

local function retiredObjectTag(object)
    -- Current generic boundary tags (sink/floor/roof/counter/generator) are
    -- not retired evidence; only the historically proven rain_barrel role is.
    local data = World.objectModData(object)
    if type(data) ~= "table" then return nil end
    local nested = data.RailroaderRVTest
    if type(nested) == "table" and nested.owner == "RailroaderRVTest"
        and nested.role == "rain_barrel"
        and nested.rvId ~= nil and nested.generation ~= nil
        and nested.bitmapVersion ~= nil then
        return nested
    end
    if data.owner == "RailroaderRVTest" and data.role == "rain_barrel"
        and data.rvId ~= nil
        and data.generation ~= nil and data.bitmapVersion ~= nil then
        return data
    end
    return nil
end

local function sameIdentity(tag, identity)
    return type(tag) == "table" and tostring(tag.rvId) == tostring(identity.rvId)
        and Util.integer(tag.generation) == Util.integer(identity.generation)
        and Util.integer(tag.bitmapVersion) == Util.integer(identity.bitmapVersion)
        and Util.integer(tag.schemaVersion) == U.WATER_SCHEMA_VERSION
end

local function sameGenerationIdentity(tag, identity)
    return type(tag) == "table" and tostring(tag.rvId) == tostring(identity.rvId)
        and Util.integer(tag.generation) == Util.integer(identity.generation)
        and Util.integer(tag.bitmapVersion) == Util.integer(identity.bitmapVersion)
end

local function exactTagKeys(tag, allowed, required)
    if type(tag) ~= "table" then return false end
    local allowedSet = {}
    for _, field in ipairs(allowed) do allowedSet[field] = true end
    for field in pairs(tag) do
        if not allowedSet[field] then return false end
    end
    for _, field in ipairs(required) do
        if tag[field] == nil then return false end
    end
    return true
end

local function validUtilityTag(tag, identity, role, deviceId)
    if not sameIdentity(tag, identity) or tag.role ~= role then return false end
    if type(tag.schemaVersion) ~= "number"
        or Util.integer(tag.schemaVersion) ~= U.WATER_SCHEMA_VERSION
        or type(tag.rvId) ~= "string" or tag.rvId == ""
        or type(tag.generation) ~= "number" or Util.integer(tag.generation) == nil
        or Util.integer(tag.generation) < 1 or type(tag.bitmapVersion) ~= "number"
        or Util.integer(tag.bitmapVersion) ~= C.BITMAP_VERSION then
        return false
    end
    if type(tag.objectToken) ~= "string" or tag.objectToken == ""
        or type(tag.objectFingerprint) ~= "string" or tag.objectFingerprint == "" then
        return false
    end
    if role == C.UTILITY_ROLE_TANK then
        return tag.deviceId == nil
            and exactTagKeys(tag,
                { "schemaVersion", "role", "rvId", "generation", "bitmapVersion",
                    "objectToken", "objectFingerprint" },
                { "schemaVersion", "role", "rvId", "generation", "bitmapVersion",
                    "objectToken", "objectFingerprint" })
    elseif role == C.UTILITY_ROLE_PROXY then
        return type(tag.deviceId) == "string" and tag.deviceId ~= ""
            and tostring(tag.deviceId) == tostring(deviceId)
            and exactTagKeys(tag,
                { "schemaVersion", "role", "deviceId", "rvId", "generation",
                    "bitmapVersion", "objectToken", "objectFingerprint" },
                { "schemaVersion", "role", "deviceId", "rvId", "generation",
                    "bitmapVersion", "objectToken", "objectFingerprint" })
    elseif role == "fixture" then
        return type(tag.deviceId) == "string" and tag.deviceId ~= ""
            and type(tag.fixtureToken) == "string" and tag.fixtureToken ~= ""
            and type(tag.fixtureFingerprint) == "string" and tag.fixtureFingerprint ~= ""
            and tostring(tag.deviceId) == tostring(deviceId)
            and exactTagKeys(tag,
                { "schemaVersion", "role", "deviceId", "rvId", "generation",
                    "bitmapVersion", "fixtureToken", "fixtureFingerprint",
                    "objectToken", "objectFingerprint" },
                { "schemaVersion", "role", "deviceId", "rvId", "generation",
                    "bitmapVersion", "fixtureToken", "fixtureFingerprint",
                    "objectToken", "objectFingerprint" })
    end
    return false
end

local function nextToken(identity, role, x, y, z)
    tokenSequence = tokenSequence + 1
    return tostring(identity.rvId) .. ":" .. tostring(identity.generation) .. ":"
        .. tostring(identity.bitmapVersion) .. ":" .. tostring(role) .. ":"
        .. tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z) .. ":"
        .. tostring(tokenSequence)
end

local function writeUtilityTag(object, identity, tag)
    local data = World.objectModData(object)
    if type(data) ~= "table" then return false end
    data.RailroaderRVTestUtility = tag
    local verify = objectTag(object)
    if type(verify) ~= "table" or verify.schemaVersion ~= U.WATER_SCHEMA_VERSION
        or verify.role ~= tag.role
        or verify.deviceId ~= tag.deviceId
        or verify.objectToken ~= tag.objectToken
        or not validUtilityTag(verify, identity, tag.role, tag.deviceId) then return false end
    -- New hidden objects are not attached yet.  Their tag is carried by the
    -- one complete packet emitted after attachObject; existing fixtures call
    -- transmitModData explicitly after this helper returns.
    return true
end

local function allObjects(square)
    return World.squareSnapshot(square)
end

local function objectAtHint(player, hint)
    if type(hint) ~= "table" then return false, U.REASONS.INVALID_REQUEST end
    local x, y, z = Util.integer(hint.x), Util.integer(hint.y), Util.integer(hint.z)
    if x == nil or y == nil or z == nil then return false, U.REASONS.INVALID_REQUEST end
    local position = playerPosition(player)
    if not position or math.abs(position.x - x) > U.DEVICE_REACH
        or math.abs(position.y - y) > U.DEVICE_REACH or math.floor(position.z) ~= z then
        return false, U.REASONS.OUTSIDE_RV
    end
    local cellOk, cell = pcall(World.getCellForPlayer, player)
    if not cellOk or not cell then return false, U.REASONS.TARGET_NOT_LOADED end
    local square = World.getSquare(cell, x, y, z)
    if not square then return false, U.REASONS.TARGET_NOT_LOADED end
    local requestedIndex = Util.integer(hint.objectIndex)
    local objects = allObjects(square)
    local fallback
    for i = 1, #objects do
        local object = objects[i]
        local ox, oy, oz = coords(object)
        if ox == x and oy == y and oz == z then
            fallback = fallback or object
            if requestedIndex ~= nil then
                local indexOk, index = invoke(object, "getObjectIndex")
                if indexOk and Util.integer(index) == requestedIndex then return true, object end
            end
        end
    end
    if fallback then return true, fallback end
    return false, U.REASONS.DEVICE_INVALID
end

local function squareObject(identity, x, y, z, role, deviceId, player)
    local cellOk, cell = pcall(World.getCellForPlayer, player or runtimePlayers[key(identity)])
    if not cellOk or not cell then return nil, "unloaded" end
    local square = World.getSquare(cell, x, y, z)
    if not square then return nil, "unloaded" end
    local objects = allObjects(square)
    local found
    for i = 1, #objects do
        local tag = objectTag(objects[i])
        -- Current utility objects carry both the generic boundary tag and the
        -- exact utility tag.  Only inspect the legacy namespace when that
        -- current utility tag is absent.
        local retired = not tag and retiredObjectTag(objects[i])
        if retired and sameGenerationIdentity(retired, identity) then
            -- The former generation-owned barrel and other retired object
            -- roles use the legacy RailroaderRVTest namespace.  They remain
            -- evidence of an incompatible current square; never hide them
            -- and place a new utility object beside them.
            return nil, "invalid"
        end
        if sameGenerationIdentity(tag, identity) then
            if tag.role ~= role or not sameIdentity(tag, identity)
                or not validUtilityTag(tag, identity, role, deviceId) then
                -- A current RV object with a retired role/schema, including a
                -- former visible barrel, is an incompatible persisted object.
                -- Do not ignore it or create a replacement beside it.
                return nil, "invalid"
            end
        end
        if sameIdentity(tag, identity) and tag.role == role then
            if deviceId ~= nil and tostring(tag.deviceId) ~= tostring(deviceId) then
                return nil, "duplicate"
            end
            if found then return nil, "duplicate" end
            found = objects[i]
        end
    end
    if found and (role == C.UTILITY_ROLE_TANK or role == C.UTILITY_ROLE_PROXY) then
        -- Every loaded current-schema mirror must prove its native-source flag
        -- before any caller can inspect, project, connect, or remove it.  A
        -- bad flag is not a projection mismatch that this process may repair.
        local externalOk = externalWaterMatches(found, role)
        if externalOk ~= true then return nil, "invalid" end
    end
    return found, found and "loaded" or "missing"
end

local function attachObject(square, object)
    -- LGExtendedPlumbing's durable mirror path uses this API: it attaches the
    -- IsoThumpable to the square and emits the one complete add packet in the
    -- same operation.  Do not call AddSpecialObject/AddTileObject first and
    -- then transmitCompleteItemToClients; that split path left the tank's
    -- later object-change packet pointing at a client index that did not exist.
    local before = objectAttached(square, object)
    if before ~= false then return false end
    if not Util.callSucceeded(square, "transmitAddObjectToSquare", object, -1) then
        return false
    end
    local after = objectAttached(square, object)
    if after ~= true then return false end
    local finalOk, finalIndex = invoke(object, "getObjectIndex")
    if not finalOk or Util.integer(finalIndex) == nil or Util.integer(finalIndex) < 0 then return false end
    World.recalcSquare(square)
    return true
end

local function addFluidComponent(object, capacity)
    if objectContainer(object) then return true end
    local componentTypes = rawget(_G, "ComponentType")
    local fluidType = componentTypes and componentTypes.FluidContainer
    local factory = rawget(_G, "GameEntityFactory")
    if not fluidType or type(fluidType.CreateComponent) ~= "function"
        or not factory or type(factory.AddComponent) ~= "function" then
        return false, "component-api-missing"
    end
    local created, component = pcall(function()
        return fluidType:CreateComponent()
    end)
    if not created or not component then return false, "component-create" end
    local capacityOk, capacityResult = invoke(component, "setCapacity", capacity)
    if not capacityOk or capacityResult == false then return false, "component-capacity" end
    local added, addError = pcall(factory.AddComponent, object, true, component)
    if not added then return false, "component-add:" .. tostring(addError) end
    if not objectContainer(object) then return false, "component-not-mounted" end
    return true
end

objectAttached = function(square, object)
    if not square or not object then return false end
    local snapshotOk, objects = pcall(World.squareSnapshot, square)
    if not snapshotOk or type(objects) ~= "table" then return nil end
    for i = 1, #objects do
        if objects[i] == object then
            local indexOk, index = invoke(object, "getObjectIndex")
            index = indexOk and Util.integer(index) or nil
            return index ~= nil and index >= 0
        end
    end
    -- The square snapshot is authoritative for actual attachment.  A
    -- non-negative object index on an object that is absent from this square
    -- is exactly the stale-index shape that caused the client warning.
    return false
end

local function rollbackCreatedObject(square, object)
    -- Constructors normally return an unattached object, but B42 can expose a
    -- valid square/index before transmitAddObjectToSquare reports its result.
    -- Remove only when the object is observable on that square; an unattached
    -- constructor must not turn a harmless API failure into a second removal
    -- failure.
    if not square then
        local squareOk, objectSquare = invoke(object, "getSquare")
        square = squareOk and objectSquare or nil
    end
    local attached = objectAttached(square, object)
    if attached == false then return true end
    if attached ~= true then return false end
    return removeObject and removeObject(object) == true
end

local function creationFailure(square, object, reason)
    if object then rollbackCreatedObject(square, object) end
    return false, reason
end

local function configureHiddenObject(object, role)
    -- Mirror objects are deliberately invisible, non-interactive and
    -- non-destructible.  `IsoThumpable` is still required for the native
    -- external-water search on fixture proxies, but it must not become a
    -- zombie target, a wall, a door, or a player-placeable container.
    if not Util.callSucceeded(object, "setDoRender", false)
        or not Util.callSucceeded(object, "setOutlineOnMouseover", false)
        or not Util.callSucceeded(object, "setSpecialTooltip", false)
        or not Util.callSucceeded(object, "setName", "")
        or not Util.callSucceeded(object, "setCanPassThrough", true)
        or not Util.callSucceeded(object, "setBlockAllTheSquare", false)
        or not Util.callSucceeded(object, "setCrossSpeed", 1.0)
        or not Util.callSucceeded(object, "setIsThumpable", false)
        or not Util.callSucceeded(object, "setCanBarricade", false)
        or not Util.callSucceeded(object, "setCanBePlastered", false)
        or not Util.callSucceeded(object, "setIsDismantable", false)
        or not Util.callSucceeded(object, "setIsHoppable", false)
        or not Util.callSucceeded(object, "setIsContainer", false)
        or not Util.callSucceeded(object, "setIsDoor", false)
        or not Util.callSucceeded(object, "setIsDoorFrame", false)
        or not Util.callSucceeded(object, "setMaxHealth", 10000)
        or not Util.callSucceeded(object, "setHealth", 10000)
        -- Keep the usage tank out of native source selection even if a future
        -- layout brings a fixture close to its deterministic offset.  Proxies
        -- must remain discoverable by the fixture's 3x3 search.
        or not Util.callSucceeded(object, "setUsesExternalWaterSource",
            role ~= C.UTILITY_ROLE_PROXY) then
        return false
    end
    return true
end

local function applyAmount(object, amount, capacity, deferSync)
    local container = objectContainer(object)
    if not container then return false, U.REASONS.API_ERROR end
    local profile = { kind = amount <= U.PROFILE_EPSILON and "EMPTY" or "CLEAN",
        cleanAmount = clamp(amount, 0, capacity), taintedAmount = 0 }
    local applied, applyReason = Catalog.applyProfile(container, capacity, profile)
    if not applied then
        return false, U.REASONS.API_ERROR, nil, "profile:" .. tostring(applyReason)
    end
    local amountOk, observed = invoke(container, "getAmount")
    observed = amountOk and Util.toNumber(observed) or nil
    if not finite(observed) or math.abs(observed - profile.cleanAmount) > U.PROFILE_EPSILON then
        return false, U.REASONS.API_ERROR, observed, "profile-postcondition"
    end
    if deferSync ~= true and not Util.callSucceeded(object, "sync") then
        -- Catalog.applyProfile has already changed the local object.  Return
        -- that observed amount so callers can advance their baseline and retry
        -- only the network acknowledgement, rather than charging the same
        -- delta again on the next settlement.
        return false, U.REASONS.API_ERROR, observed, "object-sync"
    end
    return true, observed
end

local function makeObject(identity, context, x, y, z, role, token, fingerprint, initial,
    deviceId)
    local player = context and context.player or runtimePlayers[key(identity)]
    local cellOk, cell = pcall(World.getCellForPlayer, player)
    if not cellOk or not cell then return false, U.REASONS.TARGET_NOT_LOADED end
    local square = World.getSquare(cell, x, y, z)
    if not square then return false, U.REASONS.TARGET_NOT_LOADED end
    local spriteReady, _, spriteReason = UtilitySprite.ensureHiddenSprites()
    if not spriteReady then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=isolated-sprite reason=" .. tostring(spriteReason))
        return creationFailure(square, nil, U.REASONS.API_ERROR)
    end
    local sprite = role == C.UTILITY_ROLE_PROXY and C.SPRITES.utilityProxy.sprite
        or C.SPRITES.utilityHidden.sprite
    local cls = rawget(_G, C.UTILITY_HIDDEN_OBJECT_CLASS)
    local spriteOk, spriteObject, spriteReason = resolveNamedSprite(sprite)
    if not spriteOk then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=sprite-lookup reason=" .. tostring(spriteReason))
        return creationFailure(square, nil, U.REASONS.API_ERROR)
    end
    -- Usage tank and fixture proxy deliberately share LG's durable
    -- IsoThumpable constructor path.  The ordinary IsoObject/getNew path
    -- produced a server-side object whose later SyncIsoObject index was not
    -- present on the client.
    local made, object = Util.invokeClass(cls, { { cell, square, sprite, false, nil } })
    if not made or not object then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=constructor")
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    local spriteBindOk, spriteBindReason = bindNamedSprite(object, sprite, spriteObject)
    if not spriteBindOk then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=sprite-bind reason=" .. tostring(spriteBindReason))
        printSpriteDiagnostics(object, role, fingerprint, spriteBindOk, spriteBindReason)
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    local actualFingerprint = objectFingerprint(object, role)
    if actualFingerprint ~= fingerprint then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=fingerprint expected=" .. tostring(fingerprint)
            .. " actual=" .. tostring(actualFingerprint))
        printSpriteDiagnostics(object, role, fingerprint, spriteBindOk, spriteBindReason)
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    local componentOk, componentReason = addFluidComponent(object, U.WATER_CAPACITY)
    if not componentOk then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=fluid-component reason=" .. tostring(componentReason))
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    if not configureHiddenObject(object, role) then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=safety")
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    local externalOk, externalReason = externalWaterMatches(object, role)
    if externalOk ~= true then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=external-water-flag")
        return creationFailure(square, object, externalReason or C.SAVE_REBUILD_REQUIRED)
    end
    local container = objectContainer(object)
    if not container then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=container")
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    if not Util.callSucceeded(container, "setRainCatcher", 0)
        or not Util.callSucceeded(container, "setInputLocked", true) then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=container-safety")
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    local tagOk = pcall(World.tagObject, object, identity.generation, role,
        World.withTagIdentity({ objectToken = token, objectFingerprint = fingerprint,
            role = role, deviceId = deviceId }, identity))
    if not tagOk or not writeUtilityTag(object, identity, { schemaVersion = U.WATER_SCHEMA_VERSION,
        role = role, deviceId = deviceId,
        rvId = identity.rvId, generation = identity.generation,
        bitmapVersion = identity.bitmapVersion, objectToken = token,
        objectFingerprint = fingerprint }) then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=tag")
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    -- The component and clean-water projection are complete before the single
    -- full add packet.  No object-index sync can escape for an object that the
    -- client has not received yet.
    local amountOk, amountReason, observedAmount, amountDetail = applyAmount(object, initial,
        U.WATER_CAPACITY, true)
    if not amountOk then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=amount reason=" .. tostring(amountDetail or amountReason)
            .. " observed=" .. tostring(observedAmount))
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    if not attachObject(square, object) then
        print("[RailroaderRVTest] utility object create failed role=" .. tostring(role)
            .. " stage=attach")
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    runtimeObjects[key(identity) .. ":" .. role .. ":" .. tostring(token)] = object
    return true, object
end

local function fixtureInside(object, context)
    local x, y, z = coords(object)
    return x ~= nil and context and inRegion({ x = x, y = y, z = z }, context.record and context.record.region)
end

local function validCurrentFixture(entry, object, identity)
    local x, y, z = coords(object)
    local tag = objectTag(object)
    local token = tag and tag.fixtureToken
    return x == entry.fixtureX and y == entry.fixtureY and z == entry.fixtureZ
        and token == entry.fixtureToken
        and tag.fixtureFingerprint == entry.fixtureFingerprint
        and tag.objectToken == entry.fixtureToken
        and tag.objectFingerprint == entry.fixtureFingerprint
        and validUtilityTag(tag, identity, "fixture", entry.deviceId)
        and tag.deviceId == entry.deviceId
        and objectFingerprint(object, "fixture") == entry.fixtureFingerprint
end

local function readAmount(object, role)
    local externalOk, externalReason = externalWaterMatches(object, role)
    if externalOk ~= true then return false, externalReason end
    local container = objectContainer(object)
    if not container then return false, U.REASONS.DEVICE_INVALID end
    local amountOk, amount = invoke(container, "getAmount")
    local capacityOk, capacity = invoke(container, "getCapacity")
    amount, capacity = amountOk and Util.toNumber(amount) or nil,
        capacityOk and Util.toNumber(capacity) or nil
    if not finite(amount) or not finite(capacity) or amount < 0 or capacity <= 0
        or amount > capacity + U.PROFILE_EPSILON then return false, U.REASONS.API_ERROR end
    return true, { amount = amount, capacity = capacity }
end

-- Amount/capacity alone do not prove that a projection is still authoritative:
-- a native fluid mutation can replace clean Water with tainted/mixed fluid at
-- the same total amount, or unlock the container for an untracked refill.  A
-- no-op projection is therefore allowed only when the public B42 profile and
-- input-lock postconditions both match the requested clean-water mirror.
local function projectionMatches(object, expectedAmount, expectedCapacity, role)
    local readOk, state = readAmount(object, role)
    if not readOk then return false, state end
    expectedAmount = Util.toNumber(expectedAmount)
    expectedCapacity = Util.toNumber(expectedCapacity)
    if not finite(expectedAmount) or not finite(expectedCapacity)
        or math.abs(state.amount - expectedAmount) > U.PROFILE_EPSILON
        or math.abs(state.capacity - expectedCapacity) > U.PROFILE_EPSILON then
        return false
    end
    local container = objectContainer(object)
    if not container then return false end
    local profile = Catalog.readProfile(container)
    if type(profile) ~= "table" then return false end
    if expectedAmount <= U.PROFILE_EPSILON then
        if profile.kind ~= "EMPTY"
            or math.abs(profile.cleanAmount or -1) > U.PROFILE_EPSILON
            or math.abs(profile.taintedAmount or -1) > U.PROFILE_EPSILON then
            return false
        end
    elseif profile.kind ~= "CLEAN"
        or math.abs((profile.cleanAmount or -1) - expectedAmount) > U.PROFILE_EPSILON
        or math.abs(profile.taintedAmount or -1) > U.PROFILE_EPSILON then
        return false
    end
    local lockOk, locked = invoke(container, "isInputLocked")
    return lockOk and locked == true
end

local function usageObject(identity, context)
    local waterOk, record = Store.getRecord(identity, false)
    if not waterOk then return false, record end
    local i = record.water.usageTankIdentity
    local object, status = squareObject(identity, i.x, i.y, i.z,
        C.UTILITY_ROLE_TANK, nil, context and context.player)
    if status == "unloaded" then return false, U.REASONS.TARGET_NOT_LOADED end
    if status == "duplicate" or status == "invalid" then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if not object then
        local created, result = M.ensureUsageTank(identity, context)
        if not created then return false, result end
        return true, result, record
    end
    local tag = objectTag(object)
    if not validUtilityTag(tag, identity, C.UTILITY_ROLE_TANK, nil)
        or tag.objectToken ~= i.objectToken
        or tag.objectFingerprint ~= i.objectFingerprint
        or objectFingerprint(object, C.UTILITY_ROLE_TANK) ~= i.objectFingerprint
        or not objectContainer(object) then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local externalOk = externalWaterMatches(object, C.UTILITY_ROLE_TANK)
    if externalOk ~= true then return false, C.SAVE_REBUILD_REQUIRED end
    return true, object, record
end

local function proxyObject(identity, entry, player)
    local object, status = squareObject(identity, entry.proxyX, entry.proxyY, entry.proxyZ,
        C.UTILITY_ROLE_PROXY, entry.deviceId, player)
    if status == "duplicate" or status == "invalid" then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if status == "unloaded" then return false, U.REASONS.TARGET_NOT_LOADED end
    if not object then return false, U.REASONS.DEVICE_INVALID end
    local tag = objectTag(object)
    if not validUtilityTag(tag, identity, C.UTILITY_ROLE_PROXY, entry.deviceId)
        or tag.objectToken ~= entry.proxyToken
        or tag.objectFingerprint ~= entry.proxyFingerprint
        or objectFingerprint(object, C.UTILITY_ROLE_PROXY) ~= entry.proxyFingerprint
        or not objectContainer(object) then return false, C.SAVE_REBUILD_REQUIRED end
    local externalOk = externalWaterMatches(object, C.UTILITY_ROLE_PROXY)
    if externalOk ~= true then return false, C.SAVE_REBUILD_REQUIRED end
    return true, object
end

local function collectProxyDelta(record, entry, proxy)
    local readOk, state = readAmount(proxy, C.UTILITY_ROLE_PROXY)
    if not readOk then return false, state end
    local ledger = record.water.proxyLedger[entry.deviceId]
    local baseline = clamp(ledger.amount, 0, U.WATER_CAPACITY)
    local observed = clamp(state.amount, 0, U.WATER_CAPACITY)
    local consumed = math.max(0, baseline - observed)
    if consumed > U.PROFILE_EPSILON then
        local canonical = record.water.canonicalTank
        canonical.amount = clamp(canonical.amount - consumed, 0, canonical.capacity)
        canonical.sequence = canonical.sequence + 1
    end
    -- A proxy above its saved baseline is simply rebased. This can happen
    -- after a server interruption between projection and persistence.
    ledger.amount = observed
    ledger.capacity = U.WATER_CAPACITY
    return true, consumed, consumed > U.PROFILE_EPSILON
end

local function collectAllLoadedProxyDeltas(identity, record, context)
    local count = 0
    for _, entry in pairs(record.water.registry) do
        if entry.status == U.STATUS_ACTIVE or entry.status == U.STATUS_NEEDS_RECONCILE then
            local fixture, fixtureStatus = squareObject(identity, entry.fixtureX,
                entry.fixtureY, entry.fixtureZ, "fixture", entry.deviceId,
                context and context.player)
            if fixtureStatus == "unloaded" then
                entry.status = U.STATUS_DEFERRED
                record.water.state = U.WATER_STATE_DEFERRED
            elseif not fixture or not validCurrentFixture(entry, fixture, identity) then
                local normalDetach = fixture == nil and fixtureStatus == "missing"
                local quarantined, quarantineReason, quarantineChanged = retireEntry(identity,
                    record, entry, context,
                    U.REASONS.DEVICE_NOT_CURRENT, normalDetach)
                if not quarantined then return false, quarantineReason, quarantineChanged == true end
            else
            local ok, proxyOrReason = proxyObject(identity, entry, context and context.player)
            if not ok then
                if proxyOrReason == U.REASONS.TARGET_NOT_LOADED then
                    entry.status = U.STATUS_DEFERRED
                    record.water.state = U.WATER_STATE_DEFERRED
                else
                    local quarantined, quarantineReason, quarantineChanged = retireEntry(
                        identity, record, entry, context, proxyOrReason)
                    if not quarantined then return false, quarantineReason,
                        quarantineChanged == true end
                end
            else
                local deltaOk, deltaReason, deltaChanged = collectProxyDelta(record,
                    entry, proxyOrReason)
                if not deltaOk then return false, deltaReason, deltaChanged == true end
                count = count + 1
            end
            end
        end
    end
    return true, count
end

-- A deferred entry is only a load-state condition.  Once both the fixture and
-- its proxy are visible again, restore it to the normal reconcile path so its
-- persisted baseline is consumed before the next projection.  Identity and
-- fingerprints are rechecked; a replacement object never revives an old
-- entry.
local function reactivateDeferredEntries(identity, record, context)
    local changed = false
    for _, entry in pairs(record.water.registry) do
        if entry.status == U.STATUS_DEFERRED then
            local fixture, fixtureStatus = squareObject(identity, entry.fixtureX,
                entry.fixtureY, entry.fixtureZ, "fixture", entry.deviceId,
                context and context.player)
            if fixtureStatus == "unloaded" then
                -- Keep DEFERRED until the fixture square can be inspected.
            elseif fixture and validCurrentFixture(entry, fixture, identity) then
                local proxyOk, proxyOrReason = proxyObject(identity, entry,
                    context and context.player)
                if proxyOk then
                    entry.status = U.STATUS_NEEDS_RECONCILE
                    record.water.proxyLedger[entry.deviceId].status = U.STATUS_NEEDS_RECONCILE
                    changed = true
                elseif proxyOrReason ~= U.REASONS.TARGET_NOT_LOADED then
                    local quarantined, quarantineReason = retireEntry(identity,
                        record, entry, context, proxyOrReason)
                    if not quarantined then return false, quarantineReason end
                    changed = true
                end
            elseif not fixture then
                local quarantined, quarantineReason = retireEntry(identity, record,
                    entry, context, U.REASONS.DEVICE_NOT_CURRENT,
                    fixtureStatus == "missing")
                if not quarantined then return false, quarantineReason end
                changed = true
            else
                local quarantined, quarantineReason = retireEntry(identity, record,
                    entry, context, U.REASONS.DEVICE_NOT_CURRENT)
                if not quarantined then return false, quarantineReason end
                changed = true
            end
        end
    end
    if changed and record.water.state == U.WATER_STATE_DEFERRED then
        record.water.state = U.WATER_STATE_NEEDS_RECONCILE
    end
    return true, changed
end

local function projectUsageToProxies(identity, record, context)
    local canonical = record.water.canonicalTank
    local usageOk, usage = usageObject(identity, context)
    if not usageOk then
        canonical.projectionPending = true
        canonical.pendingProjectionSequence = canonical.sequence
        canonical.pendingProjectionReason = tostring(usage)
        canonical.state = usage == U.REASONS.TARGET_NOT_LOADED
            and U.WATER_STATE_DEFERRED or U.WATER_STATE_NEEDS_RECONCILE
        record.water.state = canonical.state
        return false, usage
    end
    if canonical.projectionPending
        or not projectionMatches(usage, canonical.amount, canonical.capacity,
            C.UTILITY_ROLE_TANK) then
        local applied, _, localAmount = applyAmount(usage, canonical.amount,
            canonical.capacity)
        if not applied then
            if localAmount ~= nil then record.water.usageTankSnapshot.amount = localAmount end
            canonical.projectionPending = true
            canonical.pendingProjectionSequence = canonical.sequence
            canonical.pendingProjectionReason = U.REASONS.API_ERROR
            canonical.state = U.WATER_STATE_NEEDS_RECONCILE
            record.water.state = canonical.state
            return false, U.REASONS.API_ERROR
        end
    end
    record.water.usageTankSnapshot.amount = canonical.amount

    local pending = false
    for deviceId, entry in pairs(record.water.registry) do
        if entry.status == U.STATUS_ACTIVE or entry.status == U.STATUS_NEEDS_RECONCILE then
            local proxyOk, proxy = proxyObject(identity, entry, context and context.player)
            if not proxyOk then
                entry.status = proxy == U.REASONS.TARGET_NOT_LOADED
                    and U.STATUS_DEFERRED or U.STATUS_NEEDS_RECONCILE
                record.water.proxyLedger[deviceId].status = entry.status
                pending = true
            else
                local applied, amount, localAmount = true, canonical.amount, nil
                if entry.status ~= U.STATUS_ACTIVE
                    or not projectionMatches(proxy, canonical.amount, canonical.capacity,
                        C.UTILITY_ROLE_PROXY) then
                    applied, amount, localAmount = applyAmount(proxy, canonical.amount,
                        canonical.capacity)
                end
                if applied then
                    local ledger = record.water.proxyLedger[deviceId]
                    ledger.amount = amount
                    ledger.capacity = canonical.capacity
                    ledger.status = U.STATUS_ACTIVE
                    entry.status = U.STATUS_ACTIVE
                else
                    entry.status = U.STATUS_NEEDS_RECONCILE
                    local ledger = record.water.proxyLedger[deviceId]
                    ledger.status = entry.status
                    if localAmount ~= nil then ledger.amount = localAmount end
                    pending = true
                end
            end
        elseif entry.status == U.STATUS_DEFERRED then
            pending = true
        end
    end
    canonical.projectionPending = pending
    canonical.pendingProjectionSequence = pending and canonical.sequence or nil
    canonical.pendingProjectionReason = pending and U.REASONS.PROJECTION_PENDING or nil
    canonical.state = pending and U.WATER_STATE_NEEDS_RECONCILE or U.WATER_STATE_ACTIVE
    record.water.state = canonical.state
    return not pending, pending and U.REASONS.PROJECTION_PENDING or canonical.amount
end

local function flushBeforeOverwrite(identity, operation, context, executeOperation)
    local identityKey = key(identity)
    if accountingGuard[identityKey] then return false, U.REASONS.BUSY end
    accountingGuard[identityKey] = true
    local ok, accepted, detail, commitFailed = pcall(function()
        local recordOk, recordOrReason = Store.getRecord(identity, false)
        if not recordOk then return false, recordOrReason end
        local record = recordOrReason
        local beforeWater = Store.copyWater(record.water)

        local reactivated, reactivateReason = reactivateDeferredEntries(identity, record, context)
        if not reactivated then return false, reactivateReason end
        local collected, collectReason = collectAllLoadedProxyDeltas(identity, record, context)
        if not collected then return false, collectReason end

        local operationCommitted = false
        if executeOperation then
            local operationOk, operationReason = executeOperation(record)
            if not operationOk then
                if not sameValue(beforeWater, record.water) then
                    local saved, saveReason = Store.commit(record, identity)
                    if not saved then return false, saveReason, true end
                end
                return false, operationReason
            end
            operationCommitted = true
        end

        local projected, projectionReason = projectUsageToProxies(identity, record, context)
        local changed = not sameValue(beforeWater, record.water)
        if changed then
            local saved, saveReason = Store.commit(record, identity)
            if not saved then return false, saveReason, true end
        end
        if not projected then
            if operationCommitted then
                return false, { committed = true, operationCommitted = true,
                    record = record, reason = projectionReason, changed = changed }
            end
            return false, projectionReason
        end
        return true, { record = record, operation = operation,
            changed = changed }
    end)
    accountingGuard[identityKey] = nil
    if not ok then return false, tostring(accepted) end
    return accepted, detail, commitFailed
end

function M.ensureUsageTank(identity, context, workingRecord)
    local record
    if workingRecord ~= nil then
        record = workingRecord
    else
        local recordOk, recordOrReason = Store.getRecord(identity, false)
        if not recordOk then return false, recordOrReason end
        record = recordOrReason
    end
    local identityData = record.water.usageTankIdentity
    local object, status = squareObject(identity, identityData.x, identityData.y, identityData.z,
        C.UTILITY_ROLE_TANK, nil, context and context.player)
    if status == "unloaded" then return false, U.REASONS.TARGET_NOT_LOADED end
    if status == "duplicate" or status == "invalid" then
        -- A current-generation object with the retired role/schema (including
        -- the old visible barrel tag) is a save-shape conflict.  Never place
        -- a replacement beside it.
        return false, C.SAVE_REBUILD_REQUIRED
    end
    -- Recreate a missing projected tank from the saved balance after an
    -- interrupted save. Some consumption may be lost.
    if object then
        local tag = objectTag(object)
        if not validUtilityTag(tag, identity, C.UTILITY_ROLE_TANK, nil)
            or tag.objectToken ~= identityData.objectToken
            or tag.objectFingerprint ~= identityData.objectFingerprint
            or objectFingerprint(object, C.UTILITY_ROLE_TANK) ~= identityData.objectFingerprint
            or not objectContainer(object) then return false, C.SAVE_REBUILD_REQUIRED end
        if externalWaterMatches(object, C.UTILITY_ROLE_TANK) ~= true then
            return false, C.SAVE_REBUILD_REQUIRED
        end
        if workingRecord ~= nil then
            local commitOk, commitReason = Store.commit(record, identity)
            if not commitOk then return false, commitReason end
        end
        return true, object
    end
    local made, created = makeObject(identity, context, identityData.x, identityData.y,
        identityData.z, C.UTILITY_ROLE_TANK, identityData.objectToken,
        identityData.objectFingerprint, record.water.canonicalTank.amount)
    if not made then return false, created end
    record.water.usageTankSnapshot.amount = record.water.canonicalTank.amount
    local commitOk, commitReason = Store.commit(record, identity)
    if not commitOk then
        rollbackCreatedObject(nil, created)
        return false, commitReason
    end
    return true, created
end

local function hasPipeWrench(player)
    local inventoryOk, inventory = invoke(player, "getInventory")
    if not inventoryOk or not inventory then return false end
    local containsOk, contains = invoke(inventory, "contains", "Base.PipeWrench")
    return containsOk and contains == true
end

local function writeFixtureTag(object, identity, entry, token, fingerprint)
    local old = objectTag(object)
    if old and (not sameIdentity(old, identity) or old.deviceId ~= nil) then return false end
    local written = writeUtilityTag(object, identity, { schemaVersion = U.WATER_SCHEMA_VERSION,
        role = "fixture", deviceId = entry.deviceId,
        rvId = identity.rvId, generation = identity.generation,
        bitmapVersion = identity.bitmapVersion, fixtureToken = token,
        fixtureFingerprint = fingerprint, objectToken = token,
        objectFingerprint = fingerprint })
    return written and Util.callSucceeded(object, "transmitModData")
end

local function restoreFixtureTag(object, previous)
    local data = World.objectModData(object)
    if type(data) ~= "table" then return false end
    data.RailroaderRVTestUtility = previous
    return Util.callSucceeded(object, "transmitModData")
end

local function pendingDetachedFixtureKey(identity, deviceId)
    return key(identity) .. ":detached:" .. tostring(deviceId)
end

-- IsoThumpable moveables preserve their complete object modData in the
-- inventory item.  The removal callback has already proved the old fixture's
-- current identity and completed its detach; this process-local witness stays
-- available until an exact paired placement/reconnect consumes it.  It is not
-- persisted and cannot repair an orphan after restart.
local function clearPendingDetachedFixture(identity, object, tag)
    if type(tag) ~= "table" or tag.role ~= "fixture" then return nil end
    local pendingKey = pendingDetachedFixtureKey(identity, tag.deviceId)
    local pending = pendingDetachedFixtures[pendingKey]
    if type(pending) ~= "table" then return nil end
    if pending.oldObject == object
        or tag.objectToken ~= pending.objectToken
        or tag.fixtureToken ~= pending.fixtureToken
        or tag.objectFingerprint ~= pending.objectFingerprint
        or tag.fixtureFingerprint ~= pending.fixtureFingerprint
        or objectFingerprint(object, "fixture") ~= pending.objectFingerprint then
        return false
    end
    if not restoreFixtureTag(object, nil) then
        return false, U.REASONS.POSTCONDITION_FAILED
    end
    pendingDetachedFixtures[pendingKey] = nil
    return true
end

local function proxyPostcondition(found, proxy)
    if not found or not proxy then return false end
    local foundTag, proxyTag = objectTag(found), objectTag(proxy)
    if type(proxyTag) ~= "table" then return false end
    local identity = { rvId = tostring(proxyTag.rvId), generation = proxyTag.generation,
        bitmapVersion = proxyTag.bitmapVersion }
    if not validUtilityTag(foundTag, identity, C.UTILITY_ROLE_PROXY, proxyTag.deviceId)
        or foundTag.objectToken ~= proxyTag.objectToken
        or foundTag.objectFingerprint ~= proxyTag.objectFingerprint
        or objectFingerprint(found, C.UTILITY_ROLE_PROXY) ~= proxyTag.objectFingerprint then
        return false
    end
    if externalWaterMatches(found, C.UTILITY_ROLE_PROXY) ~= true then
        return false
    end
    local foundX, foundY, foundZ = coords(found)
    local proxyX, proxyY, proxyZ = coords(proxy)
    return foundX == proxyX and foundY == proxyY and foundZ == proxyZ
end

local function setFixtureExternal(object, proxy, enabled)
    if not Util.callSucceeded(object, "setUsesExternalWaterSource", enabled) then return false end
    if not Util.callSucceeded(object, "transmitModData") then return false end
    local changes = rawget(_G, "IsoObjectChange")
    local changeType = changes and changes.USES_EXTERNAL_WATER_SOURCE
    if changeType == nil
        or not Util.callSucceeded(object, "sendObjectChange", changeType, { value = enabled }) then
        return false
    end
    if not enabled then
        return true
    end
    if not Util.callSucceeded(object, "doFindExternalWaterSource") then return false end
    local findOk, found = invoke(object, "FindExternalWaterSource")
    return findOk and proxyPostcondition(found, proxy)
end

local function forgetRuntimeObject(object)
    for objectKey, runtimeObject in pairs(runtimeObjects) do
        if runtimeObject == object then runtimeObjects[objectKey] = nil end
    end
end

removeObject = function(object)
    local squareOk, square = invoke(object, "getSquare")
    if not squareOk or not square then return false end
    local removed, index = invoke(square, "transmitRemoveItemFromSquare", object)
    local indexNumber = removed and Util.integer(index) or nil
    local accepted = removed and indexNumber ~= nil and indexNumber >= 0
    if accepted then
        -- Removal acknowledgement alone is not enough for the structure
        -- transaction: verify the object is no longer discoverable before
        -- releasing its runtime handle.
        if objectAttached(square, object) ~= false then return false end
        forgetRuntimeObject(object)
    end
    return accepted
end

fixtureSourceGone = function(object)
    if not object then return true end
    if not Util.callSucceeded(object, "doFindExternalWaterSource") then return false end
    local findOk, found = invoke(object, "FindExternalWaterSource")
    return findOk and found == nil
end

-- Remove a disconnected or replaced fixture without locking the whole RV's
-- water balance. A loaded source is disconnected before its proxy is removed.
retireEntry = function(identity, record, entry, context, reason, normalDetach)
    local fixture, fixtureStatus = squareObject(identity, entry.fixtureX,
        entry.fixtureY, entry.fixtureZ, "fixture", entry.deviceId,
        context and context.player)
    local proxy, proxyStatus = squareObject(identity, entry.proxyX, entry.proxyY,
        entry.proxyZ, C.UTILITY_ROLE_PROXY, entry.deviceId,
        context and context.player)
    if fixtureStatus == "unloaded" or proxyStatus == "unloaded" then
        entry.status = U.STATUS_DEFERRED
        return true, U.REASONS.TARGET_NOT_LOADED, true
    end
    if fixtureStatus == "invalid" or fixtureStatus == "duplicate"
        or proxyStatus == "invalid" or proxyStatus == "duplicate" then
        entry.status = U.STATUS_NEEDS_RECONCILE
        return true, reason, true
    end
    if normalDetach and not fixture and proxy then
        collectProxyDelta(record, entry, proxy)
    end
    local revoked = not fixture or setFixtureExternal(fixture, nil, false)
    local cleared = not proxy or (applyAmount(proxy, 0, U.WATER_CAPACITY)
        and removeObject(proxy))
    if revoked and cleared and (not fixture or fixtureSourceGone(fixture)) then
        record.water.registry[entry.deviceId] = nil
        record.water.proxyLedger[entry.deviceId] = nil
    else
        entry.status = U.STATUS_NEEDS_RECONCILE
    end
    return true, reason, true
end

local function objectDeviceId(record, object)
    local tag = objectTag(object)
    if tag and tag.deviceId and record.water.registry[tag.deviceId] then return tag.deviceId end
    return nil
end

local function completeProxyRegistration(record, identity, tag, x, y, z)
    if not validUtilityTag(tag, identity, C.UTILITY_ROLE_PROXY, tag.deviceId) then
        return false
    end
    local entry = record.water.registry[tag.deviceId]
    local ledger = record.water.proxyLedger[tag.deviceId]
    if type(entry) ~= "table" or type(ledger) ~= "table" then return false end
    return tostring(entry.deviceId) == tostring(tag.deviceId)
        and entry.proxyX == x and entry.proxyY == y and entry.proxyZ == z
        and tostring(entry.proxyToken) == tostring(tag.objectToken)
        and tostring(entry.proxyFingerprint) == tostring(tag.objectFingerprint)
        and tostring(ledger.deviceId) == tostring(tag.deviceId)
end

local function proxySquareEvidence(identity, record, x, y, z, player)
    local cellOk, cell = pcall(World.getCellForPlayer, player or runtimePlayers[key(identity)])
    if not cellOk or not cell then return "unloaded" end
    local square = World.getSquare(cell, x, y, z)
    if not square then return "unloaded" end
    local count = 0
    local complete = 0
    local orphan = false
    local objects = allObjects(square)
    for i = 1, #objects do
        local tag = objectTag(objects[i])
        if sameGenerationIdentity(tag, identity) and tag.role == C.UTILITY_ROLE_PROXY then
            count = count + 1
            local externalOk = externalWaterMatches(objects[i], C.UTILITY_ROLE_PROXY)
            if externalOk ~= true then
                return "invalid"
            end
            if completeProxyRegistration(record, identity, tag, x, y, z) then
                complete = complete + 1
            else
                orphan = true
            end
        elseif not tag then
            -- A current generic proxy tag without its exact utility tag is a
            -- partial structure.  Generic sink/floor/roof/counter/generator
            -- tags are intentionally ignored; only role=proxy is evidence.
            local generic = genericObjectTag(objects[i])
            if sameGenerationIdentity(generic, identity)
                and generic.role == C.UTILITY_ROLE_PROXY then
                count = count + 1
                orphan = true
            end
        end
    end
    if count == 0 then return "missing" end
    if orphan or count ~= 1 or complete ~= 1 then return "orphan" end
    return "registered"
end

function M.connectDevice(identity, context, hint)
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local player = context and context.player
    if not player or not hasPipeWrench(player) then return false, U.REASONS.MISSING_TOOL end
    local objectOk, objectOrReason = objectAtHint(player, hint)
    if not objectOk then return false, objectOrReason end
    local object = objectOrReason
    if not fixtureInside(object, context) then return false, U.REASONS.OUTSIDE_RV end
    local taggedSink = Catalog.isGeneratedSink(object)
    if taggedSink and not Catalog.hasFluidContainer(object) then
        return false, U.REASON_SAVE_REBUILD_REQUIRED
    end
    local currentGenerated = Catalog.isGeneratedSink(object, identity)
    local nativeSink = Catalog.isNativeSink(object)
    if taggedSink and not currentGenerated then
        return false, U.REASON_SAVE_REBUILD_REQUIRED
    end
    if not taggedSink and not nativeSink then
        return false, U.REASONS.DEVICE_NOT_SUPPORTED
    end
    local entry = Catalog.findEntry(object)
    if not entry or entry.id ~= "sink" then return false, U.REASONS.DEVICE_NOT_SUPPORTED end
    if not Catalog.entryIsRuntimeTestEnabled(entry) then
        return false, U.REASONS.DEVICE_NOT_SUPPORTED
    end
    if not Catalog.isWaterPipedDevice(object) then return false, U.REASONS.DEVICE_NOT_SUPPORTED end
    local point = objectCoordinates(object)
    if not point then return false, U.REASONS.DEVICE_INVALID end
    local x, y, z = point.x, point.y, point.z
    local fingerprint = objectFingerprint(object, "fixture")
    local oldTag = objectTag(object)
    local retiredTag = not oldTag and retiredObjectTag(object)
    if retiredTag and sameGenerationIdentity(retiredTag, identity) then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if oldTag and not validUtilityTag(oldTag, identity, "fixture", oldTag.deviceId) then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local carriedTagCleared, carriedTagReason = clearPendingDetachedFixture(identity,
        object, oldTag)
    if carriedTagReason then return false, carriedTagReason end
    if carriedTagCleared then oldTag = nil end
    if oldTag and oldTag.deviceId ~= nil
        and recordOrReason.water.registry[oldTag.deviceId] == nil then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local token = oldTag and oldTag.fixtureToken or nextToken(identity, "fixture", x, y, z)
    for deviceId, entry in pairs(recordOrReason.water.registry) do
        if (entry.fixtureX == x and entry.fixtureY == y and entry.fixtureZ == z)
            or entry.fixtureToken == token or objectDeviceId(recordOrReason, object) == deviceId then
            return false, U.REASONS.DEVICE_CONFLICT
        end
    end
    local deviceId = tostring(identity.rvId) .. ":device:" .. tostring(recordOrReason.water.canonicalTank.sequence + 1)
    while recordOrReason.water.registry[deviceId] do deviceId = deviceId .. "-retry" end
    local proxyX, proxyY, proxyZ = x, y, z + C.UTILITY_PROXY_Z_OFFSET
    local entry = { deviceId = deviceId, deviceType = "sink", rvId = identity.rvId,
        generation = identity.generation, bitmapVersion = identity.bitmapVersion,
        fixtureX = x, fixtureY = y, fixtureZ = z, fixtureToken = token,
        fixtureFingerprint = fingerprint, proxyX = proxyX, proxyY = proxyY,
        proxyZ = proxyZ, proxyToken = tostring(identity.rvId) .. ":proxy:" .. deviceId,
        proxyFingerprint = hiddenObjectFingerprint(C.UTILITY_ROLE_PROXY,
            C.SPRITES.utilityProxy.sprite),
        registeredSequence = recordOrReason.water.canonicalTank.sequence + 1,
        status = U.STATUS_NEEDS_RECONCILE }
    local flushOk, result = flushBeforeOverwrite(identity, "CONNECT", context,
        function(record)
        local function rollbackCreatedProxy(proxy)
            local disabled = not proxy or setFixtureExternal(object, proxy, false)
            local removed = not proxy or removeObject(proxy)
            local restored = restoreFixtureTag(object, oldTag)
            return disabled and removed and restored
        end
        local existing, status = squareObject(identity, proxyX, proxyY, proxyZ,
            C.UTILITY_ROLE_PROXY, deviceId, player)
        if status == "unloaded" then return false, U.REASONS.TARGET_NOT_LOADED end
        if status == "invalid" then return false, C.SAVE_REBUILD_REQUIRED end
        local proxyState = proxySquareEvidence(identity, record, proxyX, proxyY, proxyZ, player)
        if proxyState == "unloaded" then return false, U.REASONS.TARGET_NOT_LOADED end
        if proxyState == "invalid" then return false, C.SAVE_REBUILD_REQUIRED end
        if proxyState == "orphan" then return false, C.SAVE_REBUILD_REQUIRED end
        if proxyState == "registered" then return false, U.REASONS.DEVICE_CONFLICT end
        if existing or status == "duplicate" then return false, C.SAVE_REBUILD_REQUIRED end
        local made, proxyOrReason = makeObject(identity, context, proxyX, proxyY, proxyZ,
            C.UTILITY_ROLE_PROXY, entry.proxyToken, entry.proxyFingerprint,
            record.water.usageTankSnapshot.amount, deviceId)
        if not made then return false, proxyOrReason end
        if not writeFixtureTag(object, identity, entry, token, fingerprint)
            or not setFixtureExternal(object, proxyOrReason, true) then
            rollbackCreatedProxy(proxyOrReason)
            return false, U.REASONS.POSTCONDITION_FAILED
        end
        record.water.registry[deviceId] = entry
        record.water.proxyLedger[deviceId] = { deviceId = deviceId,
            amount = record.water.usageTankSnapshot.amount, capacity = U.WATER_CAPACITY,
            status = U.STATUS_NEEDS_RECONCILE }
        return true
        end)
    if not flushOk then
        if type(result) ~= "table" or result.committed ~= true then
            -- A rejected connection must release a proxy created by this call.
            local createdProxy = runtimeObjects[key(identity) .. ":"
                .. C.UTILITY_ROLE_PROXY .. ":" .. tostring(entry.proxyToken)]
            if createdProxy then
                local disabled = setFixtureExternal(object, createdProxy, false)
                local removed = removeObject(createdProxy)
                local restored = restoreFixtureTag(object, oldTag)
                if not (disabled and removed and restored) then
                    return false, U.REASONS.POSTCONDITION_FAILED
                end
            end
            return false, result
        end
        result = result.record
    else
        result = result.record
    end
    runtimePlayers[key(identity)] = player
    return true, { record = result, deviceId = deviceId,
        sequence = result.water.canonicalTank.sequence,
        projectionPending = result.water.canonicalTank.projectionPending }
end

local function inventoryItems(inventory, result, seen)
    if not inventory or seen[inventory] then return end
    seen[inventory] = true
    local items = World.collectionSnapshot(select(2, invoke(inventory, "getItems")))
    for i = 1, #items do
        result[#result + 1] = items[i]
        local nestedOk, nested = invoke(items[i], "getInventory")
        if nestedOk and nested then inventoryItems(nested, result, seen) end
    end
end

local function resolveSource(player, hint)
    if type(hint) ~= "table" then return false, U.REASONS.SOURCE_INVALID end
    local inventoryOk, inventory = invoke(player, "getInventory")
    if not inventoryOk or not inventory then return false, U.REASONS.SOURCE_NOT_INVENTORY end
    local wanted = hint.itemId or hint.id
    local items = {}
    inventoryItems(inventory, items, {})
    for i = 1, #items do
        local idOk, itemId = invoke(items[i], "getID")
        if wanted ~= nil and idOk and tostring(itemId) == tostring(wanted) then
            local container = objectContainer(items[i])
            if container then
                local profile = Catalog.readProfile(container)
                if profile and Catalog.profileAmount(profile) > U.PROFILE_EPSILON then
                    return true, items[i], container, Catalog.profileAmount(profile)
                end
            end
        end
    end
    return false, U.REASONS.SOURCE_NOT_INVENTORY
end

local function syncItem(item)
    return item and Util.callSucceeded(item, "syncItemFields")
end

local function readItemAmount(container)
    local amountOk, amount = invoke(container, "getAmount")
    amount = amountOk and Util.toNumber(amount) or nil
    return finite(amount) and amount or nil
end

local function restoreSource(item, container, target)
    local restored = Util.callSucceeded(container, "adjustAmount", target)
    local observed = restored and readItemAmount(container) or nil
    return restored and observed ~= nil
        and math.abs(observed - target) <= U.PROFILE_EPSILON
        and syncItem(item)
end


function M.addWater(identity, context, entryPoint, sourceHint)
    entryPoint = entryPoint or U.ENTRY_INTERNAL
    if entryPoint ~= U.ENTRY_INTERNAL and entryPoint ~= U.ENTRY_LOCOMOTIVE then
        return false, U.REASONS.INVALID_REQUEST
    end
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local record = recordOrReason
    local sourceOk, itemOrReason, container, sourceAmount = resolveSource(
        context and context.player, sourceHint)
    if not sourceOk then return false, itemOrReason end
    local before = sourceAmount
    local loadedOk, loadedReason = usageObject(identity, context)
    if entryPoint == U.ENTRY_INTERNAL and not loadedOk then
        return false, loadedReason
    end
    local transferResult
    local function executeAdd(current)
        local remaining = math.max(0, current.water.canonicalTank.capacity
            - current.water.canonicalTank.amount)
        local plannedTransfer = math.min(remaining, before)
        if plannedTransfer <= U.PROFILE_EPSILON then return false, U.REASONS.CAPACITY_FULL end
        local removed, result = invoke(container, "removeFluid", plannedTransfer, false)
        local afterRemove = readItemAmount(container)
        local removeDelta = afterRemove and before - afterRemove or nil
        if (not removed or result == false)
            and (not finite(removeDelta) or removeDelta <= U.PROFILE_EPSILON) then
            removed, result = invoke(container, "adjustAmount", before - plannedTransfer)
        elseif not removed or result == false then
            -- Some builds report a failed remove call after applying a
            -- partial amount. Preserve that observable delta and validate it
            -- below instead of issuing a second removal against the source.
            removed, result = true, true
        end
        local after = readItemAmount(container)
        local observedDelta = after and before - after or nil
        if not removed or not after or not finite(observedDelta)
            or observedDelta <= U.PROFILE_EPSILON
            or observedDelta > plannedTransfer + U.PROFILE_EPSILON then
            return false, U.REASONS.SOURCE_INVALID
        end
        local confirmed = clamp(observedDelta, 0, plannedTransfer)
        if not syncItem(itemOrReason) then return false, U.REASONS.API_ERROR end
        local canonical = current.water.canonicalTank
        canonical.amount = clamp(canonical.amount + confirmed, 0, canonical.capacity)
        canonical.sequence = canonical.sequence + 1
        transferResult = { plannedTransfer = plannedTransfer, confirmedTransfer = confirmed,
            confirmedSource = confirmed }
        return true
    end
    if entryPoint == U.ENTRY_LOCOMOTIVE and not loadedOk
        and loadedReason ~= U.REASONS.TARGET_NOT_LOADED then
        return false, loadedReason
    elseif entryPoint == U.ENTRY_LOCOMOTIVE and not loadedOk then
        local executeOk, executeReason = executeAdd(record)
        if not executeOk then
            restoreSource(itemOrReason, container, before)
            return false, executeReason
        end
        record.water.canonicalTank.projectionPending = true
        record.water.canonicalTank.pendingProjectionSequence = record.water.canonicalTank.sequence
        record.water.canonicalTank.pendingProjectionReason = "LOCOMOTIVE_ADD_UNLOADED"
        record.water.canonicalTank.state = U.WATER_STATE_DEFERRED
        record.water.state = U.WATER_STATE_DEFERRED
        local commitOk, commitReason = Store.commit(record, identity)
        if not commitOk then
            restoreSource(itemOrReason, container, before)
            return false, commitReason
        end
    else
        local flushOk, detail = flushBeforeOverwrite(identity, "ADD_WATER",
            context, executeAdd)
        if not flushOk then
            if type(detail) == "table" and detail.operationCommitted == true then
                record = detail.record
            else
                restoreSource(itemOrReason, container, before)
                return false, detail
            end
        else
            record = detail.record
        end
    end
    return true, { record = record, sequence = record.water.canonicalTank.sequence,
        plannedTransfer = transferResult.plannedTransfer,
        confirmedTransfer = transferResult.confirmedTransfer,
        confirmedCanonical = transferResult.confirmedTransfer,
        projectionPending = record.water.canonicalTank.projectionPending }
end

function M.settleUnderGuard(identity, context)
    if type(context) ~= "table" or type(context.record) ~= "table" then
        return false, U.REASONS.RV_NOT_FOUND
    end
    runtimePlayers[key(identity)] = context.player or runtimePlayers[key(identity)]
    return flushBeforeOverwrite(identity, "SETTLEMENT", context, nil)
end

-- Native callbacks collect consumption promptly; the periodic pass catches
-- changes made without a callback.
function M.onWaterAmountChange(object)
    local tag = object and objectTag(object)
    if type(tag) ~= "table" or tag.role ~= C.UTILITY_ROLE_PROXY then return end
    local identity = { rvId = tostring(tag.rvId), generation = tag.generation,
        bitmapVersion = tag.bitmapVersion }
    if not validUtilityTag(tag, identity, C.UTILITY_ROLE_PROXY, tag.deviceId)
        or accountingGuard[key(identity)] then return end
    local recordOk, record = Store.getRecord(identity, false)
    local entry = recordOk and record.water.registry[tag.deviceId] or nil
    if not entry or externalWaterMatches(object, C.UTILITY_ROLE_PROXY) ~= true then return end
    local beforeWater = Store.copyWater(record.water)
    local collected = collectProxyDelta(record, entry, object)
    if collected and not sameValue(beforeWater, record.water) then
        Store.commit(record, identity)
    end
end

local function detachDevice(identity, context, deviceId)
    local execute = function(record)
        local entry = record.water.registry[deviceId]
        if not entry then return false, U.REASONS.DEVICE_INVALID end
        local proxyOk, proxy = proxyObject(identity, entry, context and context.player)
        if not proxyOk then return false, proxy end
        local fixture, fixtureStatus = squareObject(identity, entry.fixtureX, entry.fixtureY,
            entry.fixtureZ, "fixture", deviceId, context and context.player)
        if fixtureStatus == "unloaded" then
            return false, U.REASONS.TARGET_NOT_LOADED
        end
        if fixtureStatus == "invalid" then return false, U.REASONS.DEVICE_INVALID end
        if not fixture then return false, U.REASONS.DEVICE_INVALID end
        if not setFixtureExternal(fixture, proxy, false) then
            return false, U.REASONS.POSTCONDITION_FAILED
        end
        if not applyAmount(proxy, 0, U.WATER_CAPACITY) or not removeObject(proxy) then
            return false, U.REASONS.POSTCONDITION_FAILED
        end
        if not fixtureSourceGone(fixture) then
            return false, U.REASONS.POSTCONDITION_FAILED
        end
        -- A normal detach releases the current utility tag as well as the
        -- proxy/registry row.  Leaving the device id behind would make a
        -- later explicit reconnect look like an orphaned current object.
        if not restoreFixtureTag(fixture, nil) then
            return false, U.REASONS.POSTCONDITION_FAILED
        end
        record.water.registry[deviceId] = nil
        record.water.proxyLedger[deviceId] = nil
        return true
    end
    local accepted, result = flushBeforeOverwrite(identity, "DETACH", context, execute)
    return accepted, result
end

-- B42 raises this event before an IsoObject is detached from its square.  A
-- current utility fixture carries a complete identity and registry token, so
-- that evidence is sufficient to run the ordinary detach transaction before
-- the object disappears.  This is deliberately not an orphan-repair path:
-- missing/invalid tags, records, entries, or transaction gates are ignored
-- and remain subject to the normal loaded-square audit/rebuild rules.
function M.onObjectAboutToBeRemoved(object)
    local tag = object and objectTag(object)
    if type(tag) ~= "table" or tag.role ~= "fixture" then return false end
    local identity = { rvId = tag.rvId, generation = tag.generation,
        bitmapVersion = tag.bitmapVersion }
    if not validUtilityTag(tag, identity, "fixture", tag.deviceId) then return false end

    local rv = rawget(_G, "RailroaderRV")
    local server = rv and rv.Server
    if server and type(server.isGenerationTransactionActive) == "function" then
        local gateOk, busy = pcall(server.isGenerationTransactionActive)
        if not gateOk or busy == true then return false end
    end

    local recordOk, record = Store.getRecord(identity, false)
    if not recordOk or type(record) ~= "table" then return false end
    local entry = record.water and record.water.registry
        and record.water.registry[tag.deviceId]
    if type(entry) ~= "table"
        or entry.status == U.STATUS_SUSPENDED
        or not validCurrentFixture(entry, object, identity) then
        return false
    end

    local context = { player = runtimePlayers[key(identity)] }
    local accepted, result = detachDevice(identity, context, tag.deviceId)
    if accepted then
        pendingDetachedFixtures[pendingDetachedFixtureKey(identity, tag.deviceId)] = {
            oldObject = object, objectToken = tag.objectToken,
            fixtureToken = tag.fixtureToken, objectFingerprint = tag.objectFingerprint,
            fixtureFingerprint = tag.fixtureFingerprint,
        }
    end
    if not accepted and result ~= U.REASONS.TARGET_NOT_LOADED then
        print("[RailroaderRVTest] utility fixture removal reconciliation deferred rv="
            .. tostring(identity.rvId) .. " device=" .. tostring(tag.deviceId)
            .. " reason=" .. tostring(result))
    end
    return accepted, result
end

-- Placement emits OnObjectAdded after the new object has received any
-- moveable-item modData.  Normal IsoObject moveables do not copy the utility
-- namespace, while IsoThumpable moveables can; consume only the paired
-- process-local removal witness in the latter case.  A tag without that
-- witness remains an incompatible orphan under the current-schema gate.
function M.onObjectAdded(object)
    local tag = object and objectTag(object)
    if type(tag) ~= "table" or tag.role ~= "fixture" then return false end
    local identity = { rvId = tag.rvId, generation = tag.generation,
        bitmapVersion = tag.bitmapVersion }
    if not validUtilityTag(tag, identity, "fixture", tag.deviceId) then return false end
    if Store.validateIdentity(identity) ~= true then return false end
    local cleared, reason = clearPendingDetachedFixture(identity, object, tag)
    if reason then return false, reason end
    return cleared == true
end

function M.resolveObjectForPower(player, hint, allowRemote)
    if allowRemote == true and type(hint) == "table" then
        local x, y, z = Util.integer(hint.x), Util.integer(hint.y), Util.integer(hint.z)
        if x and y and z then
            local cellOk, cell = pcall(World.getCellForPlayer, player)
            local square = cellOk and cell and World.getSquare(cell, x, y, z)
            if square then
                local requestedIndex = Util.integer(hint.objectIndex)
                for _, object in ipairs(allObjects(square)) do
                    local ox, oy, oz = coords(object)
                    if ox == x and oy == y and oz == z then
                        if requestedIndex == nil then return true, object end
                        local indexOk, index = invoke(object, "getObjectIndex")
                        if indexOk and Util.integer(index) == requestedIndex then
                            return true, object
                        end
                    end
                end
                if requestedIndex ~= nil then return false, U.REASONS.DEVICE_INVALID end
            end
        end
    end
    return objectAtHint(player, hint)
end

function M.snapshot(record)
    return Store.copyWater(record.water)
end

return M
