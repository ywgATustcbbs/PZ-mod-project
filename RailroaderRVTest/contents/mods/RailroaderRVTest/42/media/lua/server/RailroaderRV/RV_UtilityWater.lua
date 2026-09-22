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

local M = {}
local runtimeObjects = {}
local runtimePlayers = {}
local accountingGuard = {}
local projectionGuard = {}
local suppressionGuard = {}
local tokenSequence = 0
local pendingWaterEvents = {}
local pendingDetachedFixtures = {}
local fixtureSourceGone
local quarantineLoadedEntry
local quarantinePendingEntries
local removeObject

local function key(identity)
    return tostring(identity.rvId) .. ":" .. tostring(identity.generation)
        .. ":" .. tostring(identity.bitmapVersion)
end

local function finite(value)
    value = Util.toNumber(value)
    return value ~= nil and value == value and value ~= math.huge and value ~= -math.huge
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
    if not finite(value) then value = 0 end
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

local function objectSprite(object)
    local spriteOk, sprite = invoke(object, "getSprite")
    if not spriteOk or not sprite then return "" end
    local nameOk, name = invoke(sprite, "getName")
    return nameOk and tostring(name or "") or ""
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
        -- Hidden utility object classes are fixed by role (IsoObject tank,
        -- IsoThumpable proxy); retain the stable sprite/script identity while
        -- avoiding a Java enum spelling difference across the two constructors.
        return role .. ":" .. objectSprite(object) .. ":" .. scriptName
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
    return found, found and "loaded" or "missing"
end

local function attachObject(square, object, special)
    local indexOk, index = invoke(object, "getObjectIndex")
    local attached = indexOk and Util.integer(index) ~= nil and Util.integer(index) >= 0
    local attachedOk = attached
    if not attached then
        attachedOk = special and Util.callSucceeded(square, "AddSpecialObject", object)
            or Util.callSucceeded(square, "AddTileObject", object)
    end
    if not attachedOk then return false end
    local finalOk, finalIndex = invoke(object, "getObjectIndex")
    if not finalOk or Util.integer(finalIndex) == nil or Util.integer(finalIndex) < 0 then return false end
    World.recalcSquare(square)
    return true
end

local function addFluidComponent(object)
    if objectContainer(object) then return true end
    local componentTypes = rawget(_G, "ComponentType")
    local fluidType = componentTypes and componentTypes.FluidContainer
    local factory = rawget(_G, "GameEntityFactory")
    if not fluidType or type(fluidType.CreateComponent) ~= "function"
        or not factory or type(factory.AddComponent) ~= "function" then
        return false
    end
    local created, component = pcall(function()
        return fluidType:CreateComponent()
    end)
    if not created or not component then return false end
    local added = pcall(factory.AddComponent, object, true, component)
    return added and objectContainer(object) ~= nil
end

local function objectAttached(square, object)
    if not square or not object then return false end
    local snapshotOk, objects = pcall(World.squareSnapshot, square)
    if not snapshotOk or type(objects) ~= "table" then return nil end
    for i = 1, #objects do
        if objects[i] == object then return true end
    end
    local indexOk, index = invoke(object, "getObjectIndex")
    if not indexOk then return nil end
    index = Util.integer(index)
    if index == nil then return nil end
    return index >= 0
end

local function rollbackCreatedObject(square, object)
    -- Constructors normally return an unattached object, but B42 can expose a
    -- valid square/index before AddTileObject/AddSpecialObject reports its
    -- result.  Remove only when the object is observable on that square; an
    -- unattached constructor must not turn a harmless API failure into a
    -- second removal failure.
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
    if object and not rollbackCreatedObject(square, object) then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    return false, reason
end

local function applyAmount(object, amount, capacity, deferSync)
    local container = objectContainer(object)
    if not container then return false, U.REASONS.API_ERROR end
    local profile = { kind = amount <= U.PROFILE_EPSILON and "EMPTY" or "CLEAN",
        cleanAmount = clamp(amount, 0, capacity), taintedAmount = 0 }
    projectionGuard[object] = true
    local applied = Catalog.applyProfile(container, capacity, profile)
    if not applied then
        projectionGuard[object] = nil
        return false, U.REASONS.API_ERROR
    end
    local amountOk, observed = invoke(container, "getAmount")
    observed = amountOk and Util.toNumber(observed) or nil
    if not finite(observed) or math.abs(observed - profile.cleanAmount) > U.PROFILE_EPSILON then
        projectionGuard[object] = nil
        return false, U.REASONS.API_ERROR
    end
    if deferSync ~= true and not Util.callSucceeded(object, "sync") then
        projectionGuard[object] = nil
        -- Catalog.applyProfile has already changed the local object.  Return
        -- that observed amount so callers can advance their baseline and retry
        -- only the network acknowledgement, rather than charging the same
        -- delta again on the next settlement.
        return false, U.REASONS.API_ERROR, observed
    end
    projectionGuard[object] = nil
    return true, observed
end

local function makeObject(identity, context, x, y, z, role, token, fingerprint, initial,
    deviceId)
    local player = context and context.player or runtimePlayers[key(identity)]
    local cellOk, cell = pcall(World.getCellForPlayer, player)
    if not cellOk or not cell then return false, U.REASONS.TARGET_NOT_LOADED end
    local square = World.getSquare(cell, x, y, z)
    if not square then return false, U.REASONS.TARGET_NOT_LOADED end
    local sprite = role == C.UTILITY_ROLE_PROXY and C.SPRITES.utilityProxy.sprite
        or C.SPRITES.utilityHidden.sprite
    local cls = role == C.UTILITY_ROLE_PROXY and rawget(_G, "IsoThumpable") or rawget(_G, "IsoObject")
    local args = role == C.UTILITY_ROLE_PROXY
        and { { cell, square, sprite, false, nil } } or { { cell, square, sprite }, { square, sprite } }
    local made, object = Util.invokeClass(cls, args)
    if not made or not object or not addFluidComponent(object)
        or objectFingerprint(object, role) ~= fingerprint then
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    Util.invoke(object, "setDoRender", false)
    Util.invoke(object, "setUsesExternalWaterSource", false)
    local container = objectContainer(object)
    if not container then return creationFailure(square, object, U.REASONS.API_ERROR) end
    Util.invoke(container, "setRainCatcher", 0)
    Util.invoke(container, "setInputLocked", true)
    if role == C.UTILITY_ROLE_PROXY then
        Util.invoke(object, "setCanPassThrough", true)
        Util.invoke(object, "setIsThumpable", true)
    end
    local tagOk = pcall(World.tagObject, object, identity.generation, role,
        World.withTagIdentity({ objectToken = token, objectFingerprint = fingerprint,
            role = role, deviceId = deviceId }, identity))
    if not tagOk or not writeUtilityTag(object, identity, { schemaVersion = U.WATER_SCHEMA_VERSION,
        role = role, deviceId = deviceId,
        rvId = identity.rvId, generation = identity.generation,
        bitmapVersion = identity.bitmapVersion, objectToken = token,
        objectFingerprint = fingerprint }) then
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    if not attachObject(square, object, role == C.UTILITY_ROLE_PROXY) then
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    -- The component is initialized after the object has a valid world index,
    -- but before its one complete packet.  `deferSync` prevents an
    -- object-index incremental packet from escaping before the client knows
    -- this object.
    local amountOk = applyAmount(object, initial, U.WATER_CAPACITY, true)
    if not amountOk then
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    if not Util.callSucceeded(object, "transmitCompleteItemToClients") then
        return creationFailure(square, object, U.REASONS.API_ERROR)
    end
    runtimeObjects[key(identity) .. ":" .. role .. ":" .. tostring(token)] = object
    return true, object
end

local function fixtureTag(object)
    local data = World.objectModData(object)
    return type(data) == "table" and data.RailroaderRVTest or nil
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

local function readAmount(object)
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
local function projectionMatches(object, expectedAmount, expectedCapacity)
    local readOk, state = readAmount(object)
    if not readOk then return false end
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
    if not object then return false, C.SAVE_REBUILD_REQUIRED end
    local tag = objectTag(object)
    if not validUtilityTag(tag, identity, C.UTILITY_ROLE_TANK, nil)
        or tag.objectToken ~= i.objectToken
        or tag.objectFingerprint ~= i.objectFingerprint
        or objectFingerprint(object, C.UTILITY_ROLE_TANK) ~= i.objectFingerprint
        or not objectContainer(object) then
        return false, C.SAVE_REBUILD_REQUIRED
    end
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
    return true, object
end

local function collectProxyDelta(identity, record, entry, proxy)
    local readOk, state = readAmount(proxy)
    if not readOk then return false, state end
    local ledger = record.water.proxyLedger[entry.deviceId]
    local baseline = clamp(ledger.amount, 0, U.WATER_CAPACITY)
    local observed = clamp(state.amount, 0, U.WATER_CAPACITY)
    if observed > baseline + U.PROFILE_EPSILON then
        record.water.canonicalTank.faultPolicy = U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
        record.water.canonicalTank.state = U.WATER_STATE_REBUILD_REQUIRED
        record.water.state = U.WATER_STATE_REBUILD_REQUIRED
        return false, U.REASONS.INPUT_NOT_SUPPORTED
    end
    if not suppressionGuard[key(identity)] and not projectionGuard[proxy]
        and observed < baseline - U.PROFILE_EPSILON then
        local usageOk, usage = usageObject(identity, { player = runtimePlayers[key(identity)] })
        if not usageOk then return false, usage end
        local usageStateOk, usageState = readAmount(usage)
        if not usageStateOk then return false, usageState end
        local nextUsage = clamp(usageState.amount - (baseline - observed), 0, U.WATER_CAPACITY)
        local projected, projectionReason, observedUsage = applyAmount(usage, nextUsage,
            U.WATER_CAPACITY)
        if not projected then
            if observedUsage ~= nil then
                -- The local usage tank is already lower even when its sync
                -- acknowledgement failed.  Advance its usage sequence and
                -- the proxy baseline, but keep snapshot.amount at the last
                -- settled value so the canonical settlement charges this
                -- confirmed local delta exactly once on retry.
                record.water.usageTankSnapshot.usageSequence =
                    record.water.usageTankSnapshot.usageSequence + 1
                record.water.usageTankSnapshot.state = U.CHECKPOINT_UNSETTLED
                record.water.canonicalTank.projectionPending = true
                record.water.canonicalTank.pendingProjectionSequence =
                    record.water.canonicalTank.sequence
                record.water.canonicalTank.pendingProjectionReason = U.REASONS.API_ERROR
                ledger.amount = observed
                ledger.capacity = U.WATER_CAPACITY
                ledger.baselineSequence = record.water.usageTankSnapshot.usageSequence
                ledger.usageSequence = record.water.usageTankSnapshot.usageSequence
                return false, projectionReason, true
            end
            return false, projectionReason, false
        end
        record.water.usageTankSnapshot.usageSequence =
            record.water.usageTankSnapshot.usageSequence + 1
        record.water.usageTankSnapshot.state = U.CHECKPOINT_UNSETTLED
    end
    ledger.amount = observed
    ledger.capacity = U.WATER_CAPACITY
    ledger.baselineSequence = record.water.usageTankSnapshot.usageSequence
    ledger.usageSequence = record.water.usageTankSnapshot.usageSequence
    return true, nil, false
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
                local quarantined, quarantineReason, quarantineChanged = quarantineLoadedEntry(identity,
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
                    local quarantined, quarantineReason, quarantineChanged = quarantineLoadedEntry(
                        identity, record, entry, context, proxyOrReason)
                    if not quarantined then return false, quarantineReason,
                        quarantineChanged == true end
                end
            else
                local deltaOk, deltaReason, deltaChanged = collectProxyDelta(identity, record,
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
                    local quarantined, quarantineReason = quarantineLoadedEntry(identity,
                        record, entry, context, proxyOrReason)
                    if not quarantined then return false, quarantineReason end
                    changed = true
                end
            elseif not fixture then
                local quarantined, quarantineReason = quarantineLoadedEntry(identity, record,
                    entry, context, U.REASONS.DEVICE_NOT_CURRENT,
                    fixtureStatus == "missing")
                if not quarantined then return false, quarantineReason end
                changed = true
            else
                local quarantined, quarantineReason = quarantineLoadedEntry(identity, record,
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

local function settleUsageToCanonical(identity, record, context)
    local usageOk, usageOrReason = usageObject(identity, context)
    if not usageOk then return false, usageOrReason end
    local stateOk, state = readAmount(usageOrReason)
    if not stateOk then return false, state end
    local snapshot = record.water.usageTankSnapshot
    local baseline = clamp(snapshot.amount, 0, U.WATER_CAPACITY)
    local observed = clamp(state.amount, 0, U.WATER_CAPACITY)
    if observed > baseline + U.PROFILE_EPSILON then
        record.water.canonicalTank.faultPolicy = U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
        record.water.canonicalTank.state = U.WATER_STATE_REBUILD_REQUIRED
        record.water.state = U.WATER_STATE_REBUILD_REQUIRED
        return false, U.REASONS.INPUT_NOT_SUPPORTED
    end
    local consumed = math.max(0, baseline - observed)
    if consumed > U.PROFILE_EPSILON then
        local canonical = record.water.canonicalTank
        canonical.amount = clamp(canonical.amount - consumed, 0, canonical.capacity)
        canonical.sequence = canonical.sequence + 1
        snapshot.settledCanonicalSequence = canonical.sequence
        snapshot.state = U.CHECKPOINT_UNSETTLED
    end
    snapshot.amount = observed
    snapshot.baselineSequence = snapshot.usageSequence
    return true, consumed
end

local function projectUsageToProxies(identity, record, context)
    local usageOk, usage = usageObject(identity, context)
    local canonical = record.water.canonicalTank
    if not usageOk then
        canonical.projectionPending = true
        canonical.pendingProjectionSequence = canonical.sequence
        canonical.pendingProjectionReason = tostring(usage)
        if usage == U.REASONS.TARGET_NOT_LOADED then
            canonical.state = U.WATER_STATE_DEFERRED
            record.water.state = U.WATER_STATE_DEFERRED
            record.water.usageTankSnapshot.state = U.CHECKPOINT_DEFERRED
        elseif usage == C.SAVE_REBUILD_REQUIRED then
            canonical.state = U.WATER_STATE_REBUILD_REQUIRED
            record.water.state = U.WATER_STATE_REBUILD_REQUIRED
            canonical.faultPolicy = U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
        else
            canonical.state = U.WATER_STATE_NEEDS_RECONCILE
            record.water.state = U.WATER_STATE_NEEDS_RECONCILE
            record.water.usageTankSnapshot.state = U.CHECKPOINT_UNSETTLED
        end
        return false, usage
    end
    local usageAmount
    local usageNeedsSync = canonical.projectionPending == true
    if not usageNeedsSync and projectionMatches(usage, canonical.amount, canonical.capacity) then
        -- The usage object already mirrors canonical state, including its
        -- clean profile and input lock.  Reading it is enough; avoid the
        -- clear/refill/sync cycle on an idle tick.
        usageAmount = canonical.amount
    else
        local usageWriteOk, observedUsage, localUsageAmount = applyAmount(usage,
            canonical.amount, canonical.capacity)
        usageAmount = observedUsage
        if not usageWriteOk then
            canonical.projectionPending = true
            canonical.pendingProjectionSequence = canonical.sequence
            canonical.pendingProjectionReason = U.REASONS.API_ERROR
            canonical.state = U.WATER_STATE_NEEDS_RECONCILE
            record.water.state = U.WATER_STATE_NEEDS_RECONCILE
            record.water.usageTankSnapshot.state = U.CHECKPOINT_UNSETTLED
            if localUsageAmount ~= nil then
                -- Preserve the locally written amount and retry only sync.
                record.water.usageTankSnapshot.amount = localUsageAmount
                usageAmount = localUsageAmount
            else
                canonical.faultPolicy = U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
                canonical.state = U.WATER_STATE_REBUILD_REQUIRED
                record.water.state = U.WATER_STATE_REBUILD_REQUIRED
            end
            return false, canonical.state == U.WATER_STATE_REBUILD_REQUIRED
                and C.SAVE_REBUILD_REQUIRED or U.REASONS.API_ERROR
        end
    end
    record.water.usageTankSnapshot.amount = usageAmount
    record.water.usageTankSnapshot.projectionSequence = canonical.sequence
    for deviceId, entry in pairs(record.water.registry) do
        if entry.status == U.STATUS_ACTIVE or entry.status == U.STATUS_NEEDS_RECONCILE then
            local proxyOk, proxyOrReason = proxyObject(identity, entry, context and context.player)
            if not proxyOk then
                entry.status = proxyOrReason == U.REASONS.TARGET_NOT_LOADED
                    and U.STATUS_DEFERRED or U.STATUS_NEEDS_RECONCILE
                canonical.projectionPending = true
                canonical.pendingProjectionSequence = canonical.sequence
                canonical.pendingProjectionReason = tostring(proxyOrReason)
            else
                local applied, observed, localProxyAmount
                local retrySync = entry.status == U.STATUS_NEEDS_RECONCILE
                if not retrySync and projectionMatches(proxyOrReason, usageAmount,
                    canonical.capacity) then
                    -- This proxy already has the requested clean, locked
                    -- projection.  Its ledger still gets the current sequence
                    -- below without a redundant world write or network packet.
                    applied, observed = true, usageAmount
                else
                    applied, observed, localProxyAmount = applyAmount(proxyOrReason,
                        usageAmount, canonical.capacity)
                end
                if not applied then
                    entry.status = U.STATUS_NEEDS_RECONCILE
                    record.water.proxyLedger[deviceId].status = U.STATUS_NEEDS_RECONCILE
                    if localProxyAmount ~= nil then
                        -- Catalog.applyProfile succeeded locally but object
                        -- sync failed.  Advance the baseline to the observed
                        -- world amount so retry cannot count this projection
                        -- as fresh consumption.
                        local ledger = record.water.proxyLedger[deviceId]
                        ledger.amount = localProxyAmount
                        ledger.capacity = canonical.capacity
                        ledger.baselineSequence = record.water.usageTankSnapshot.usageSequence
                        ledger.usageSequence = record.water.usageTankSnapshot.usageSequence
                    else
                        canonical.faultPolicy = U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
                        canonical.state = U.WATER_STATE_REBUILD_REQUIRED
                        record.water.state = U.WATER_STATE_REBUILD_REQUIRED
                        record.water.proxyLedger[deviceId].status = U.STATUS_REBUILD_REQUIRED
                        entry.status = U.STATUS_REBUILD_REQUIRED
                        break
                    end
                    canonical.projectionPending = true
                    canonical.pendingProjectionSequence = canonical.sequence
                    canonical.pendingProjectionReason = U.REASONS.API_ERROR
                else
                    entry.status = U.STATUS_ACTIVE
                    local ledger = record.water.proxyLedger[deviceId]
                    ledger.amount = observed
                    ledger.capacity = canonical.capacity
                    ledger.baselineSequence = record.water.usageTankSnapshot.usageSequence
                    ledger.usageSequence = record.water.usageTankSnapshot.usageSequence
                    ledger.projectionSequence = canonical.sequence
                    ledger.status = U.STATUS_ACTIVE
                end
            end
        end
    end
    local pending = false
    for _, entry in pairs(record.water.registry) do
        if entry.status ~= U.STATUS_ACTIVE then pending = true break end
    end
    canonical.projectionPending = pending
    if pending then
        canonical.pendingProjectionSequence = canonical.sequence
        canonical.pendingProjectionReason = canonical.pendingProjectionReason or U.REASONS.PROJECTION_PENDING
        record.water.state = U.WATER_STATE_NEEDS_RECONCILE
        record.water.usageTankSnapshot.state = U.CHECKPOINT_UNSETTLED
    else
        canonical.pendingProjectionSequence = nil
        canonical.pendingProjectionReason = nil
        canonical.state = U.WATER_STATE_ACTIVE
        record.water.state = U.WATER_STATE_ACTIVE
        record.water.usageTankSnapshot.state = U.CHECKPOINT_SETTLED
        record.water.usageTankSnapshot.settledCanonicalSequence = canonical.sequence
        canonical.checkpoint = { canonicalSequence = canonical.sequence,
            usageSequence = record.water.usageTankSnapshot.usageSequence,
            usageAmount = usageAmount, state = U.CHECKPOINT_SETTLED }
    end
    if canonical.state == U.WATER_STATE_REBUILD_REQUIRED then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    return not pending, pending and U.REASONS.PROJECTION_PENDING or usageAmount
end

local function flushBeforeOverwrite(identity, operation, context, executeOperation)
    local identityKey = key(identity)
    if accountingGuard[identityKey] then return false, U.REASONS.BUSY end
    accountingGuard[identityKey] = true
    local ok, accepted, detail, commitFailed = pcall(function()
        local recordOk, recordOrReason = Store.getRecord(identity, false)
        if not recordOk then return false, recordOrReason end
        local record = recordOrReason
        local canonical = record.water.canonicalTank
        local beforeWater = Store.copyWater(record.water)
        local hasPendingQuarantine = canonical.state == U.WATER_STATE_QUARANTINE_PENDING
            or record.water.state == U.WATER_STATE_QUARANTINE_PENDING
        if not hasPendingQuarantine then
            for _, entry in pairs(record.water.registry) do
                if entry.status == U.STATUS_QUARANTINE_PENDING then
                    hasPendingQuarantine = true
                    break
                end
            end
        end
        if hasPendingQuarantine then
            local quarantineOk, quarantineReason = quarantinePendingEntries(identity, record,
                context, U.REASONS.PROJECTION_PENDING, false)
            local quarantineCommitOk, quarantineCommitReason = Store.commit(record, identity)
            if not quarantineCommitOk then return false, quarantineCommitReason, true end
            if not quarantineOk then return false, quarantineReason end
            return false, C.SAVE_REBUILD_REQUIRED
        end
        if canonical.faultPolicy == U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
            or canonical.state == U.WATER_STATE_REBUILD_REQUIRED
            or record.water.state == U.WATER_STATE_REBUILD_REQUIRED then
            return false, C.SAVE_REBUILD_REQUIRED
        end
        local reactivated, reactivateReason = reactivateDeferredEntries(identity, record, context)
        if not reactivated then
            return false, reactivateReason
        end
        local collected, collectReason, collectChanged = collectAllLoadedProxyDeltas(identity,
            record, context)
        if canonical.faultPolicy == U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
            or canonical.state == U.WATER_STATE_REBUILD_REQUIRED
            or record.water.state == U.WATER_STATE_REBUILD_REQUIRED then
            quarantinePendingEntries(identity, record, context, collectReason, true)
            local quarantineCommitOk, quarantineCommitReason = Store.commit(record, identity)
            if not quarantineCommitOk then return false, quarantineCommitReason, true end
            return false, C.SAVE_REBUILD_REQUIRED
        end
        if not collected then
            if collectReason == C.SAVE_REBUILD_REQUIRED then
                local quarantineOk, quarantineReason = quarantinePendingEntries(identity, record,
                    context, collectReason, true)
                local quarantineCommitOk, quarantineCommitReason = Store.commit(record, identity)
                if not quarantineCommitOk then return false, quarantineCommitReason, true end
                if not quarantineOk then return false, quarantineReason end
                return false, C.SAVE_REBUILD_REQUIRED
            elseif collectReason == U.REASONS.TARGET_NOT_LOADED then
                if canonical.state ~= U.WATER_STATE_QUARANTINE_PENDING
                    and record.water.state ~= U.WATER_STATE_QUARANTINE_PENDING then
                    canonical.state = U.WATER_STATE_DEFERRED
                    record.water.state = U.WATER_STATE_DEFERRED
                end
                record.water.usageTankSnapshot.state = U.CHECKPOINT_DEFERRED
                local deferredCommitOk, deferredCommitReason = Store.commit(record, identity)
                if not deferredCommitOk then return false, deferredCommitReason, true end
            elseif collectChanged then
                record.water.state = U.WATER_STATE_NEEDS_RECONCILE
                local pendingCommitOk, pendingCommitReason = Store.commit(record, identity)
                if not pendingCommitOk then return false, pendingCommitReason, true end
            end
            return false, collectReason
        end
        local settled, settledReason = settleUsageToCanonical(identity, record, context)
        if not settled then
            if settledReason == C.SAVE_REBUILD_REQUIRED then
                local quarantineOk, quarantineReason = quarantinePendingEntries(identity, record,
                    context, settledReason, true)
                local quarantineCommitOk, quarantineCommitReason = Store.commit(record, identity)
                if not quarantineCommitOk then return false, quarantineCommitReason, true end
                if not quarantineOk then return false, quarantineReason end
                return false, C.SAVE_REBUILD_REQUIRED
            elseif settledReason == U.REASONS.TARGET_NOT_LOADED then
                canonical.state = U.WATER_STATE_DEFERRED
                record.water.state = U.WATER_STATE_DEFERRED
                record.water.usageTankSnapshot.state = U.CHECKPOINT_DEFERRED
                local deferredCommitOk, deferredCommitReason = Store.commit(record, identity)
                if not deferredCommitOk then return false, deferredCommitReason, true end
            end
            return false, settledReason
        end
        if executeOperation then
            local operationOk, operationReason = executeOperation(record)
            if not operationOk then
                -- Collection/settlement may already have changed U, proxy
                -- baselines, and C before a structural operation rejects.
                -- Persist that confirmed consumption boundary and reconcile
                -- the remaining projections; never replay it on the next
                -- flush merely because CONNECT/DETACH failed.
                projectUsageToProxies(identity, record, context)
                local settledCommitOk, settledCommitReason = Store.commit(record, identity)
                if not settledCommitOk then return false, settledCommitReason, true end
                return false, operationReason
            end
        end
        local projected, projectionReason = projectUsageToProxies(identity, record, context)
        if not projected and projectionReason == C.SAVE_REBUILD_REQUIRED then
            quarantinePendingEntries(identity, record, context, projectionReason, true)
        end
        local changed = not sameValue(beforeWater, record.water)
        if not changed then
            return true, { record = record, operation = operation, consumed = settledReason,
                changed = false }
        end
        local commitOk, commitReason = Store.commit(record, identity)
        if not commitOk then return false, commitReason, true end
        if not projected then
            -- The canonical settlement/operation is already persisted.  Do
            -- not let callers compensate a source transaction after this
            -- boundary; only the remaining world projection is pending.
            return false, { committed = true, record = record,
                reason = projectionReason, changed = true }
        end
        return true, { record = record, operation = operation, consumed = settledReason,
            changed = true }
    end)
    accountingGuard[identityKey] = nil
    if not ok then return false, tostring(accepted) end
    return accepted, detail, commitFailed
end

function M.flushBeforeOverwrite(identity, operation, context, executeOperation)
    return flushBeforeOverwrite(identity, operation, context, executeOperation)
end

function M.setPlayerContext(identity, player)
    if identity and player then runtimePlayers[key(identity)] = player end
end

function M.ensureUsageTank(identity, context, workingRecord, recordMeta)
    local record
    local recordFresh = false
    if workingRecord ~= nil then
        if type(recordMeta) ~= "table" or type(recordMeta.fresh) ~= "boolean" then
            return false, C.SAVE_REBUILD_REQUIRED
        end
        for field in pairs(recordMeta) do
            if field ~= "fresh" then return false, C.SAVE_REBUILD_REQUIRED end
        end
        if not Store.validateRecord(workingRecord, identity) then
            return false, C.SAVE_REBUILD_REQUIRED
        end
        record = workingRecord
        recordFresh = recordMeta.fresh
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
    if recordFresh and object then
        -- A fresh current-schema record may not adopt a pre-existing world
        -- utility object.  The pair is a partial write or an unknown prior
        -- transaction; do not infer ownership, delete it, or repair it.
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if not recordFresh and not object then
        -- A persisted record with no expected usage object needs the full
        -- loaded U/P, baseline and checkpoint recovery proof from the plan.
        -- Until that independent recovery transaction exists, fail closed;
        -- never recreate from canonical and risk duplicating settled water.
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if object then
        local tag = objectTag(object)
        if not validUtilityTag(tag, identity, C.UTILITY_ROLE_TANK, nil)
            or tag.objectToken ~= identityData.objectToken
            or tag.objectFingerprint ~= identityData.objectFingerprint
            or objectFingerprint(object, C.UTILITY_ROLE_TANK) ~= identityData.objectFingerprint
            or not objectContainer(object) then return false, C.SAVE_REBUILD_REQUIRED end
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
    record.water.usageTankSnapshot.projectionSequence = record.water.canonicalTank.sequence
    record.water.usageTankSnapshot.state = U.CHECKPOINT_SETTLED
    local commitOk, commitReason = Store.commit(record, identity)
    if not commitOk then
        if not rollbackCreatedObject(nil, created) then
            return false, C.SAVE_REBUILD_REQUIRED
        end
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

local function markCurrentWaterRebuild(identity, reason)
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false end
    local record = recordOrReason
    local canonical = record.water.canonicalTank
    -- A rebuild lock must also revoke every currently loaded external source;
    -- otherwise native plumbing can keep feeding a proxy after accounting has
    -- stopped.  The helper leaves unloaded entries pending for retry.
    quarantinePendingEntries(identity, record,
        { player = runtimePlayers[key(identity)] }, reason, true)
    canonical.faultPolicy = U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
    canonical.state = U.WATER_STATE_REBUILD_REQUIRED
    canonical.projectionPending = true
    canonical.pendingProjectionSequence = canonical.sequence
    canonical.pendingProjectionReason = tostring(reason or U.REASONS.API_ERROR)
    record.water.state = U.WATER_STATE_REBUILD_REQUIRED
    record.water.usageTankSnapshot.state = U.CHECKPOINT_UNSETTLED
    local committed = Store.commit(record, identity)
    return committed == true
end

fixtureSourceGone = function(object)
    if not object then return true end
    if not Util.callSucceeded(object, "doFindExternalWaterSource") then return false end
    local findOk, found = invoke(object, "FindExternalWaterSource")
    return findOk and found == nil
end

quarantineLoadedEntry = function(identity, record, entry, context, reason, normalDetach)
    local identityKey = key(identity)
    local cleanDetach = normalDetach == true
    if not cleanDetach then
        entry.status = U.STATUS_QUARANTINE_PENDING
        record.water.canonicalTank.state = U.WATER_STATE_QUARANTINE_PENDING
        record.water.state = U.WATER_STATE_QUARANTINE_PENDING
    end
    local fixture, fixtureStatus = squareObject(identity, entry.fixtureX,
        entry.fixtureY, entry.fixtureZ, "fixture", entry.deviceId,
        context and context.player)
    local rawProxy, rawProxyStatus = squareObject(identity, entry.proxyX, entry.proxyY,
        entry.proxyZ, C.UTILITY_ROLE_PROXY, entry.deviceId, context and context.player)
    local proxyOk, proxy = proxyObject(identity, entry, context and context.player)
    if fixtureStatus == "unloaded" or rawProxyStatus == "unloaded"
        or proxy == U.REASONS.TARGET_NOT_LOADED then
        entry.status = U.STATUS_QUARANTINE_PENDING
        record.water.canonicalTank.state = U.WATER_STATE_QUARANTINE_PENDING
        record.water.state = U.WATER_STATE_QUARANTINE_PENDING
        return false, U.REASONS.TARGET_NOT_LOADED, true
    end
    if fixtureStatus == "invalid" or rawProxyStatus == "invalid"
        or proxy == C.SAVE_REBUILD_REQUIRED then
        entry.status = U.STATUS_REBUILD_REQUIRED
        record.water.canonicalTank.faultPolicy = U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
        record.water.canonicalTank.state = U.WATER_STATE_REBUILD_REQUIRED
        record.water.state = U.WATER_STATE_REBUILD_REQUIRED
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if cleanDetach and not fixture then
        -- Collect the proxy's final delta while the hidden object is still
        -- available.  The following usage settlement will charge canonical
        -- once, then this entry can be removed as an ordinary detach.
        if proxyOk and proxy then
            local deltaOk, deltaReason, deltaChanged = collectProxyDelta(identity, record, entry,
                proxy)
            if not deltaOk then return false, deltaReason, deltaChanged == true end
        end
    end
    suppressionGuard[identityKey] = true
    local revoked = not fixture or setFixtureExternal(fixture, nil, false)
    local cleared = true
    if proxyOk and proxy then
        cleared = applyAmount(proxy, 0, U.WATER_CAPACITY)
        if cleared then cleared = removeObject(proxy) end
    end
    suppressionGuard[identityKey] = nil
    local sourceGone = fixture and fixtureSourceGone(fixture) or revoked
    if revoked and cleared and sourceGone then
        if cleanDetach then
            record.water.registry[entry.deviceId] = nil
            record.water.proxyLedger[entry.deviceId] = nil
        else
            entry.status = U.STATUS_SUSPENDED
        end
    else
        -- Keep the cleanup request retryable even after the enclosing water
        -- record enters its rebuild lock.  A status-only lock must not leave a
        -- still-enabled native source behind forever.
        entry.status = U.STATUS_QUARANTINE_PENDING
        record.water.canonicalTank.state = U.WATER_STATE_QUARANTINE_PENDING
        record.water.state = U.WATER_STATE_QUARANTINE_PENDING
        return false, U.REASONS.POSTCONDITION_FAILED, true
    end
    if cleanDetach then
        return true, reason
    end
    record.water.canonicalTank.faultPolicy = U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
    record.water.canonicalTank.state = U.WATER_STATE_REBUILD_REQUIRED
    record.water.state = U.WATER_STATE_REBUILD_REQUIRED
    return true, reason
end

-- Run the physical shutdown for every loaded proxy when a shared usage tank
-- or another structural prerequisite is unavailable.  Persisted rebuild state
-- is a business-operation lock, not a reason to skip this cleanup; unloaded
-- entries remain QUARANTINE_PENDING for the next loaded-square retry.
quarantinePendingEntries = function(identity, record, context, reason, allEntries)
    local pending = false
    local attempted = false
    local pendingReason
    for _, entry in pairs(record.water.registry) do
        if (allEntries == true and entry.status ~= U.STATUS_SUSPENDED)
            or entry.status == U.STATUS_QUARANTINE_PENDING then
            attempted = true
            local quarantineOk, quarantineReason = quarantineLoadedEntry(identity, record,
                entry, context, reason, false)
            if not quarantineOk then
                if entry.status == U.STATUS_QUARANTINE_PENDING
                    or quarantineReason == U.REASONS.TARGET_NOT_LOADED then
                    pending = true
                    pendingReason = quarantineReason
                else
                    entry.status = U.STATUS_REBUILD_REQUIRED
                    record.water.canonicalTank.faultPolicy =
                        U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
                    record.water.canonicalTank.state = U.WATER_STATE_REBUILD_REQUIRED
                    record.water.state = U.WATER_STATE_REBUILD_REQUIRED
                    pendingReason = quarantineReason
                end
            end
        end
    end
    if pending then
        record.water.canonicalTank.state = U.WATER_STATE_QUARANTINE_PENDING
        record.water.state = U.WATER_STATE_QUARANTINE_PENDING
        return false, pendingReason or U.REASONS.TARGET_NOT_LOADED
    end
    if not attempted then
        record.water.canonicalTank.faultPolicy = U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
        record.water.canonicalTank.state = U.WATER_STATE_REBUILD_REQUIRED
        record.water.state = U.WATER_STATE_REBUILD_REQUIRED
        return true
    end
    if attempted then
        record.water.canonicalTank.faultPolicy = U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
        record.water.canonicalTank.state = U.WATER_STATE_REBUILD_REQUIRED
        record.water.state = U.WATER_STATE_REBUILD_REQUIRED
    end
    return true
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
    local water = recordOrReason.water
    if water.canonicalTank.faultPolicy == U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
        or water.canonicalTank.state == U.WATER_STATE_REBUILD_REQUIRED
        or water.state == U.WATER_STATE_REBUILD_REQUIRED then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if water.canonicalTank.state == U.WATER_STATE_QUARANTINE_PENDING
        or water.state == U.WATER_STATE_QUARANTINE_PENDING then
        return false, U.REASONS.PROJECTION_PENDING
    end
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
        proxyFingerprint = C.UTILITY_ROLE_PROXY .. ":" .. C.SPRITES.utilityProxy.sprite .. ":",
        registeredSequence = recordOrReason.water.canonicalTank.sequence + 1,
        status = U.STATUS_NEEDS_RECONCILE }
    local flushOk, result, commitFailed = flushBeforeOverwrite(identity, "CONNECT", context,
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
        local proxyState = proxySquareEvidence(identity, record, proxyX, proxyY, proxyZ, player)
        if proxyState == "unloaded" then return false, U.REASONS.TARGET_NOT_LOADED end
        if proxyState == "orphan" then return false, C.SAVE_REBUILD_REQUIRED end
        if proxyState == "registered" then return false, U.REASONS.DEVICE_CONFLICT end
        if status == "invalid" then return false, C.SAVE_REBUILD_REQUIRED end
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
            baselineSequence = record.water.usageTankSnapshot.usageSequence,
            usageSequence = record.water.usageTankSnapshot.usageSequence,
            projectionSequence = 0, status = U.STATUS_NEEDS_RECONCILE }
        return true
        end)
    if not flushOk then
        if type(result) ~= "table" or result.committed ~= true then
            -- A failed commit/projection boundary must not leave a newly
            -- created current proxy or fixture source behind the rejected
            -- registry transaction.  Consumption already committed before a
            -- partial-projection result is deliberately not compensated.
            local createdProxy = runtimeObjects[key(identity) .. ":"
                .. C.UTILITY_ROLE_PROXY .. ":" .. tostring(entry.proxyToken)]
            if createdProxy then
                local disabled = setFixtureExternal(object, createdProxy, false)
                local removed = removeObject(createdProxy)
                local restored = restoreFixtureTag(object, oldTag)
                if not (disabled and removed and restored) then
                    return false, C.SAVE_REBUILD_REQUIRED
                end
            end
            if commitFailed then
                -- A failed final commit may have observed/settled usage before
                -- the registry transaction.  The root snapshot is restored by
                -- Store; persist a current-only rebuild lock when possible so
                -- a retry cannot consume that same world delta twice.
                markCurrentWaterRebuild(identity, result)
                return false, C.SAVE_REBUILD_REQUIRED
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

-- A source rollback failure means that the source transaction boundary is no
-- longer knowable. Keep the current record fail-closed instead of allowing a
-- later retry to consume the item again or continue with an unaccounted
-- canonical change.
local function markSourceBoundaryRebuild(identity, reason)
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false end
    local record = recordOrReason
    local canonical = record.water.canonicalTank
    canonical.faultPolicy = U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
    canonical.state = U.WATER_STATE_REBUILD_REQUIRED
    canonical.projectionPending = true
    canonical.pendingProjectionSequence = canonical.sequence
    canonical.pendingProjectionReason = tostring(reason or U.REASONS.API_ERROR)
    record.water.state = U.WATER_STATE_REBUILD_REQUIRED
    record.water.usageTankSnapshot.state = U.CHECKPOINT_UNSETTLED
    local committed = Store.commit(record, identity)
    return committed == true
end

local function restoreSourceOrRebuild(identity, item, container, target, reason)
    if restoreSource(item, container, target) then return true end
    markSourceBoundaryRebuild(identity, reason)
    return false
end

local function trimRequestLedger(ledger)
    local count = 0
    for _ in pairs(ledger) do count = count + 1 end
    while count >= 64 do
        local oldestKey, oldestSequence
        for requestKey, request in pairs(ledger) do
            local sequence = Util.integer(request.sequence) or math.huge
            if oldestSequence == nil or sequence < oldestSequence then
                oldestKey, oldestSequence = requestKey, sequence
            end
        end
        if oldestKey == nil then break end
        ledger[oldestKey] = nil
        count = count - 1
    end
end

function M.addWater(identity, context, entryPoint, sourceHint, requestMeta)
    entryPoint = entryPoint or U.ENTRY_INTERNAL
    if entryPoint ~= U.ENTRY_INTERNAL and entryPoint ~= U.ENTRY_LOCOMOTIVE then
        return false, U.REASONS.INVALID_REQUEST
    end
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local record = recordOrReason
    if record.water.canonicalTank.faultPolicy == U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
        or record.water.canonicalTank.state == U.WATER_STATE_REBUILD_REQUIRED
        or record.water.state == U.WATER_STATE_REBUILD_REQUIRED then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if record.water.canonicalTank.state == U.WATER_STATE_QUARANTINE_PENDING
        or record.water.state == U.WATER_STATE_QUARANTINE_PENDING then
        return false, U.REASONS.PROJECTION_PENDING
    end
    if requestMeta and record.water.requestLedger[requestMeta.key] then
        local previous = record.water.requestLedger[requestMeta.key]
        return previous.status == "COMMITTED", { record = record,
            sequence = previous.sequence, plannedTransfer = previous.plannedTransfer,
            confirmedTransfer = previous.confirmedCanonical,
            confirmedCanonical = previous.confirmedCanonical,
            projectionPending = record.water.canonicalTank.projectionPending }
    end
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
            if not restoreSourceOrRebuild(identity, itemOrReason, container, before, executeReason) then
                return false, C.SAVE_REBUILD_REQUIRED
            end
            return false, executeReason
        end
        record.water.canonicalTank.projectionPending = true
        record.water.canonicalTank.pendingProjectionSequence = record.water.canonicalTank.sequence
        record.water.canonicalTank.pendingProjectionReason = "LOCOMOTIVE_ADD_UNLOADED"
        record.water.canonicalTank.state = U.WATER_STATE_DEFERRED
        record.water.state = U.WATER_STATE_DEFERRED
        record.water.usageTankSnapshot.state = U.CHECKPOINT_DEFERRED
        local commitOk, commitReason = Store.commit(record, identity)
        if not commitOk then
            restoreSource(itemOrReason, container, before)
            markSourceBoundaryRebuild(identity, commitReason)
            return false, C.SAVE_REBUILD_REQUIRED
        end
    else
        local flushOk, detail, commitFailed = flushBeforeOverwrite(identity, "ADD_WATER",
            context, executeAdd)
        if not flushOk then
            if type(detail) ~= "table" or detail.committed ~= true then
                local restored = restoreSourceOrRebuild(identity, itemOrReason, container,
                    before, detail)
                -- A successful source transfer can be followed by a failed
                -- canonical commit. The result is not enough to know whether
                -- the world save accepted it, so quarantine even when source
                -- restoration happened to succeed.
                if transferResult then
                    markSourceBoundaryRebuild(identity, detail)
                end
                if commitFailed then markCurrentWaterRebuild(identity, detail) end
                if not restored or transferResult or commitFailed then
                    return false, C.SAVE_REBUILD_REQUIRED
                end
                return false, detail
            end
            record = detail.record
        else
            record = detail.record
        end
    end
    if requestMeta then
        trimRequestLedger(record.water.requestLedger)
        record.water.requestLedger[requestMeta.key] = {
            requestId = requestMeta.requestId, sessionNonce = requestMeta.sessionNonce,
            entryPoint = entryPoint, operation = U.OP_ADD_WATER, status = "COMMITTED",
            plannedTransfer = transferResult.plannedTransfer,
            confirmedSource = transferResult.confirmedSource,
            confirmedCanonical = transferResult.confirmedTransfer,
            sequence = record.water.canonicalTank.sequence }
        local ledgerOk, ledgerReason = Store.commit(record, identity)
        if not ledgerOk then
            -- Canonical/source changes were already committed before the
            -- idempotency ledger write. Never retry an ambiguous source
            -- transaction; lock this current record for manual rebuild.
            markSourceBoundaryRebuild(identity, ledgerReason)
            return false, C.SAVE_REBUILD_REQUIRED
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
    local ok, result, commitFailed = flushBeforeOverwrite(identity, "SETTLEMENT", context, nil)
    if commitFailed then
        markCurrentWaterRebuild(identity, result)
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if not ok then return false, result end
    return true, result
end

-- B42 emits this callback for the common native transfer path.  Collect the
-- proxy delta immediately while the fixed-tick collector remains the fallback
-- for direct FluidContainer mutations or an event whose object is unavailable.
function M.onWaterAmountChange(object)
    local tag = object and objectTag(object)
    if type(tag) ~= "table" or tag.role ~= C.UTILITY_ROLE_PROXY then return end
    local identity = { rvId = tostring(tag.rvId), generation = tag.generation,
        bitmapVersion = tag.bitmapVersion }
    if not validUtilityTag(tag, identity, C.UTILITY_ROLE_PROXY, tag.deviceId) then
        pendingWaterEvents[object] = true
        return
    end
    local identityKey = key(identity)
    if accountingGuard[identityKey] then
        pendingWaterEvents[object] = true
        return
    end
    local recordOk, record = Store.getRecord(identity, false)
    local entry = recordOk and record.water.registry[tag.deviceId] or nil
    if not recordOk or not entry then
        pendingWaterEvents[object] = true
        return
    end
    if record.water.canonicalTank.faultPolicy == U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
        or record.water.canonicalTank.state == U.WATER_STATE_REBUILD_REQUIRED
        or record.water.state == U.WATER_STATE_REBUILD_REQUIRED
        or record.water.canonicalTank.state == U.WATER_STATE_QUARANTINE_PENDING
        or record.water.state == U.WATER_STATE_QUARANTINE_PENDING then
        pendingWaterEvents[object] = true
        return
    end
    local beforeWater = Store.copyWater(record.water)
    local collected, reason, changed = collectProxyDelta(identity, record, entry, object)
    if not collected then
        pendingWaterEvents[object] = true
        entry.status = reason == U.REASONS.TARGET_NOT_LOADED
            and U.STATUS_DEFERRED or U.STATUS_NEEDS_RECONCILE
        record.water.state = U.WATER_STATE_NEEDS_RECONCILE
        if changed then
            local committed, commitReason = Store.commit(record, identity)
            if not committed then markCurrentWaterRebuild(identity, commitReason) end
        end
        return
    end
    if sameValue(beforeWater, record.water) then
        pendingWaterEvents[object] = nil
        return
    end
    pendingWaterEvents[object] = nil
    local committed, commitReason = Store.commit(record, identity)
    if not committed then
        markCurrentWaterRebuild(identity, commitReason)
        pendingWaterEvents[object] = true
    end
end

function M.detachDevice(identity, context, deviceId, emergency)
    if emergency then
        local recordOk, recordOrReason = Store.getRecord(identity, false)
        if not recordOk then return false, recordOrReason end
        local record = recordOrReason
        local entry = record.water.registry[deviceId]
        if not entry then return false, U.REASONS.DEVICE_INVALID end
        local fixture, fixtureStatus = squareObject(identity, entry.fixtureX,
            entry.fixtureY, entry.fixtureZ, "fixture", deviceId,
            context and context.player)
        local proxyOk, proxyOrReason = proxyObject(identity, entry,
            context and context.player)
        if fixtureStatus == "unloaded" or proxyOrReason == U.REASONS.TARGET_NOT_LOADED then
            entry.status = U.STATUS_QUARANTINE_PENDING
            record.water.canonicalTank.state = U.WATER_STATE_QUARANTINE_PENDING
            record.water.state = U.WATER_STATE_QUARANTINE_PENDING
            local deferredOk, deferredReason = Store.commit(record, identity)
            return deferredOk, deferredOk and U.REASONS.TARGET_NOT_LOADED or deferredReason
        end
        entry.status = U.STATUS_QUARANTINE_PENDING
        record.water.canonicalTank.state = U.WATER_STATE_QUARANTINE_PENDING
        record.water.state = U.WATER_STATE_QUARANTINE_PENDING
        suppressionGuard[key(identity)] = true
        local fixtureRevoked = not fixture or setFixtureExternal(fixture, nil, false)
        local proxyCleared = true
        if proxyOk and proxyOrReason then
            proxyCleared = applyAmount(proxyOrReason, 0, U.WATER_CAPACITY)
            if proxyCleared then proxyCleared = removeObject(proxyOrReason) end
        end
        suppressionGuard[key(identity)] = nil
        local sourceGone = fixture and fixtureSourceGone(fixture) or fixtureRevoked
        if fixtureRevoked and proxyCleared and sourceGone then
            entry.status = U.STATUS_SUSPENDED
        else
            entry.status = U.STATUS_REBUILD_REQUIRED
        end
        record.water.canonicalTank.faultPolicy = U.FAULT_UNCONFIRMED_CONSUMPTION_REBUILD
        record.water.canonicalTank.state = U.WATER_STATE_REBUILD_REQUIRED
        record.water.state = U.WATER_STATE_REBUILD_REQUIRED
        local commitOk, commitReason = Store.commit(record, identity)
        return commitOk, commitOk and { record = record,
            reason = U.REASONS.PROJECTION_PENDING } or commitReason
    end
    local execute = function(record)
        local entry = record.water.registry[deviceId]
        if not entry then return false, U.REASONS.DEVICE_INVALID end
        local function detachFailure(reason)
            entry.status = U.STATUS_QUARANTINE_PENDING
            record.water.canonicalTank.state = U.WATER_STATE_QUARANTINE_PENDING
            record.water.state = U.WATER_STATE_QUARANTINE_PENDING
            return false, reason
        end
        local proxyOk, proxy = proxyObject(identity, entry, context and context.player)
        if not proxyOk then return detachFailure(proxy) end
        local fixture, fixtureStatus = squareObject(identity, entry.fixtureX, entry.fixtureY,
            entry.fixtureZ, "fixture", deviceId, context and context.player)
        if fixtureStatus == "unloaded" then
            return detachFailure(U.REASONS.TARGET_NOT_LOADED)
        end
        if fixtureStatus == "invalid" then return detachFailure(C.SAVE_REBUILD_REQUIRED) end
        if not fixture then return detachFailure(U.REASONS.DEVICE_INVALID) end
        if not setFixtureExternal(fixture, proxy, false) then
            return detachFailure(U.REASONS.POSTCONDITION_FAILED)
        end
        if not applyAmount(proxy, 0, U.WATER_CAPACITY) or not removeObject(proxy) then
            return detachFailure(U.REASONS.POSTCONDITION_FAILED)
        end
        if not fixtureSourceGone(fixture) then
            return detachFailure(U.REASONS.POSTCONDITION_FAILED)
        end
        -- A normal detach releases the current utility tag as well as the
        -- proxy/registry row.  Leaving the device id behind would make a
        -- later explicit reconnect look like an orphaned current object.
        if not restoreFixtureTag(fixture, nil) then
            return detachFailure(U.REASONS.POSTCONDITION_FAILED)
        end
        record.water.registry[deviceId] = nil
        record.water.proxyLedger[deviceId] = nil
        return true
    end
    local accepted, result, commitFailed = flushBeforeOverwrite(identity, "DETACH", context, execute)
    if commitFailed then
        markCurrentWaterRebuild(identity, result)
        return false, C.SAVE_REBUILD_REQUIRED
    end
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
        or entry.status == U.STATUS_REBUILD_REQUIRED
        or not validCurrentFixture(entry, object, identity) then
        return false
    end

    local context = { player = runtimePlayers[key(identity)] }
    local accepted, result = M.detachDevice(identity, context, tag.deviceId, false)
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

function M.emergencyQuarantine(identity, context, deviceId)
    return M.detachDevice(identity, context, deviceId, true)
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
