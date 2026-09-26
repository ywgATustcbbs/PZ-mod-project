-- RV_UtilityWater: Objects responsibilities.
return function(ctx)
local C = ctx.C
local U = ctx.U
local Catalog = ctx.Catalog
local Util = ctx.Util
local World = ctx.World
local UtilitySprite = ctx.UtilitySprite
local runtimeObjects = ctx.runtimeObjects
local runtimePlayers = ctx.runtimePlayers
local function removeObject(...) return ctx.removeObject(...) end
local function objectAttached(...) return ctx.objectAttached(...) end

local function key(identity)
    return tostring(identity.rvId) .. ":" .. tostring(identity.generation)
        .. ":" .. tostring(identity.bitmapVersion)
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
    if not xOk or not yOk or not zOk or x == nil or y == nil or z == nil then
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
    if x == nil or y == nil or z == nil or minX == nil
        or maxX == nil or minY == nil or maxY == nil
        or minZ == nil or maxZ == nil then return false end
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
        return false, C.INVALID_RV_DATA
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
    ctx.tokenSequence = ctx.tokenSequence + 1
    return tostring(identity.rvId) .. ":" .. tostring(identity.generation) .. ":"
        .. tostring(identity.bitmapVersion) .. ":" .. tostring(role) .. ":"
        .. tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z) .. ":"
        .. tostring(ctx.tokenSequence)
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
        -- exact utility tag. Validate current generation-owned tags before use.
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
    if observed == nil or math.abs(observed - profile.cleanAmount) > U.PROFILE_EPSILON then
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
        return creationFailure(square, object, externalReason or C.INVALID_RV_DATA)
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


ctx.key = key
ctx.sameValue = sameValue
ctx.clamp = clamp
ctx.invoke = invoke
ctx.inRegion = inRegion
ctx.coords = coords
ctx.objectCoordinates = objectCoordinates
ctx.objectContainer = objectContainer
ctx.externalWaterMatches = externalWaterMatches
ctx.hiddenObjectFingerprint = hiddenObjectFingerprint
ctx.objectFingerprint = objectFingerprint
ctx.objectTag = objectTag
ctx.genericObjectTag = genericObjectTag
ctx.sameIdentity = sameIdentity
ctx.sameGenerationIdentity = sameGenerationIdentity
ctx.validUtilityTag = validUtilityTag
ctx.nextToken = nextToken
ctx.writeUtilityTag = writeUtilityTag
ctx.allObjects = allObjects
ctx.objectAtHint = objectAtHint
ctx.squareObject = squareObject
ctx.rollbackCreatedObject = rollbackCreatedObject
ctx.applyAmount = applyAmount
ctx.makeObject = makeObject
ctx.objectAttached = objectAttached
end
