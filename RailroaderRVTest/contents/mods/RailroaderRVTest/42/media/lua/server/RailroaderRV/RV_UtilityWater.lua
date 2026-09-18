-- Server-authoritative water ledger and FluidContainer mirror.
--
-- The persisted water record is the sole balance.  World objects are
-- projections only; their observed downward deltas are the only usage input.

local C = require("RailroaderRV/RV_Constants")
local U = require("RailroaderRV/RV_UtilityConstants")
local Catalog = require("RailroaderRV/RV_UtilityCatalog")
local Store = require("RailroaderRV/RV_UtilityStore")
local Util = require("RailroaderRV/RV_ServerUtil")
local World = require("RailroaderRV/RV_ServerWorld")
local Layout = require("RailroaderRV/RV_Layout")

local M = {}
local runtimeObjects = {}
local runtimePlayers = {}

local function key(identity)
    return tostring(identity.rvId) .. ":" .. tostring(identity.generation)
        .. ":" .. tostring(identity.bitmapVersion)
end

local function finite(value)
    value = Util.toNumber(value)
    return value ~= nil and value == value and value ~= math.huge and value ~= -math.huge
end

local function clamp(value, low, high)
    value = Util.toNumber(value) or 0
    if value ~= value or value == math.huge or value == -math.huge then value = 0 end
    return math.max(low, math.min(high, value))
end

local function invoke(target, method, ...)
    return Util.invoke(target, method, ...)
end

local function playerPosition(player)
    if not player then return nil end
    local okX, x = invoke(player, "getX")
    local okY, y = invoke(player, "getY")
    local okZ, z = invoke(player, "getZ")
    x, y, z = Util.toNumber(x), Util.toNumber(y), Util.toNumber(z)
    if not okX or not okY or not okZ or not finite(x) or not finite(y) or not finite(z) then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function inRegion(position, region)
    if type(position) ~= "table" or type(region) ~= "table" then return false end
    local x, y, z = Util.toNumber(position.x), Util.toNumber(position.y),
        Util.toNumber(position.z)
    local minX, maxX = Util.toNumber(region.minX), Util.toNumber(region.maxX)
    local minY, maxY = Util.toNumber(region.minY), Util.toNumber(region.maxY)
    local minZ, maxZ = Util.toNumber(region.minZ), Util.toNumber(region.maxZ)
    if not finite(x) or not finite(y) or not finite(z)
        or not finite(minX) or not finite(maxX) or not finite(minY)
        or not finite(maxY) or not finite(minZ) or not finite(maxZ) then
        return false
    end
    z = math.floor(z)
    return x >= minX and x < maxX and y >= minY and y < maxY
        and z >= minZ and z < maxZ
end

local function objectContainer(object)
    local ok, container = invoke(object, "getFluidContainer")
    return ok and container or nil
end

local function objectIndex(object)
    local ok, value = invoke(object, "getObjectIndex")
    return ok and Util.integer(value) or nil
end

local function objectFingerprint(object, entry)
    local sprite = ""
    local spriteOk, spriteObject = invoke(object, "getSprite")
    if spriteOk and spriteObject then
        local nameOk, name = invoke(spriteObject, "getName")
        if nameOk and name then sprite = tostring(name) end
    end
    local typeOk, objectType = invoke(object, "getType")
    return tostring(entry and entry.id or "unknown") .. ":"
        .. tostring(typeOk and objectType or "") .. ":" .. sprite
end

local function objectToken(identity, object)
    local squareOk, square = invoke(object, "getSquare")
    local x, y, z
    if squareOk and square then
        x, y, z = Util.integer(select(2, invoke(square, "getX"))),
            Util.integer(select(2, invoke(square, "getY"))),
            Util.integer(select(2, invoke(square, "getZ")))
    end
    local index = objectIndex(object)
    if x == nil or y == nil or z == nil or index == nil then return nil end
    return tostring(identity.rvId) .. ":" .. tostring(identity.generation) .. ":"
        .. tostring(identity.bitmapVersion) .. ":" .. tostring(x) .. ":" .. tostring(y)
        .. ":" .. tostring(z) .. ":" .. tostring(index)
end

local function objectTag(object)
    local data = World.objectModData(object)
    local tag = type(data) == "table" and data.RailroaderRVTestUtility or nil
    return type(tag) == "table" and tag or nil
end

local function writeObjectTag(object, identity, entry, token, fingerprint)
    local data = World.objectModData(object)
    if type(data) ~= "table" then return false end
    local tag = data.RailroaderRVTestUtility
    if tag ~= nil and type(tag) ~= "table" then return false end
    tag = tag or {}
    tag.deviceId = entry.deviceId
    tag.deviceType = entry.deviceType
    tag.rvId = tostring(identity.rvId)
    tag.generation = Util.integer(identity.generation)
    tag.bitmapVersion = Util.integer(identity.bitmapVersion)
    tag.objectToken = token
    tag.objectFingerprint = fingerprint
    data.RailroaderRVTestUtility = tag
    local verify = objectTag(object)
    if verify == nil or verify.deviceId ~= entry.deviceId
        or tostring(verify.rvId) ~= tostring(identity.rvId)
        or Util.integer(verify.generation) ~= Util.integer(identity.generation)
        or Util.integer(verify.bitmapVersion) ~= Util.integer(identity.bitmapVersion)
        or verify.objectToken ~= token or verify.objectFingerprint ~= fingerprint then
        return false
    end
    if not Util.callSucceeded(object, "transmitModData") then
        data.RailroaderRVTestUtility = nil
        pcall(function() object:transmitModData() end)
        return false
    end
    return true
end

local function profileEqual(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    return left.kind == right.kind
        and math.abs((left.cleanAmount or 0) - (right.cleanAmount or 0)) <= U.PROFILE_EPSILON
        and math.abs((left.taintedAmount or 0) - (right.taintedAmount or 0)) <= U.PROFILE_EPSILON
end

local function readState(object)
    local container = objectContainer(object)
    if not container then return false, U.REASONS.DEVICE_INVALID end
    local amountOk, amount = invoke(container, "getAmount")
    local capacityOk, capacity = invoke(container, "getCapacity")
    amount, capacity = Util.toNumber(amount), Util.toNumber(capacity)
    if not amountOk or not capacityOk or not finite(amount) or not finite(capacity)
        or amount < 0 or capacity < 0
        or amount > capacity + U.PROFILE_EPSILON then
        return false, U.REASONS.API_ERROR
    end
    local profile = Catalog.readProfile(container)
    if not profile then return false, U.REASONS.DEVICE_INVALID end
    return true, { amount = amount, capacity = capacity, fluidProfile = profile }
end

local function mirrorObject(object, water)
    local container = objectContainer(object)
    if not container then return false, U.REASONS.DEVICE_INVALID end
    local amount = Catalog.profileAmount(water.fluidProfile)
    if amount == nil then return false, U.REASONS.API_ERROR end
    if not Catalog.applyProfile(container, water.capacity, water.fluidProfile) then
        return false, U.REASONS.API_ERROR
    end
    local externalCallOk, externalResult = invoke(object,
        "setUsesExternalWaterSource", false)
    local externalOk = externalCallOk and externalResult ~= false
    if not externalOk then return false, U.REASONS.API_ERROR end
    local stateOk, stateOrReason = readState(object)
    if not stateOk then return false, stateOrReason end
    if math.abs(stateOrReason.amount - amount) > U.PROFILE_EPSILON
        or math.abs(stateOrReason.capacity - water.capacity) > U.PROFILE_EPSILON
        or not profileEqual(stateOrReason.fluidProfile, water.fluidProfile) then
        return false, U.REASONS.API_ERROR
    end
    return true, stateOrReason
end

local function squareObjectAt(square, index)
    local objects = World.squareSnapshot(square)
    for i = 1, #objects do
        if objectIndex(objects[i]) == index then return objects[i] end
    end
    return nil
end

local function tokenIndex(token)
    if type(token) ~= "string" then return nil end
    local value = string.match(token, ":(%-?%d+)$")
    return value and tonumber(value) or nil
end

local function findDeviceObject(identity, entry, player)
    local cacheKey = key(identity) .. ":" .. entry.deviceId
    local cached = runtimeObjects[cacheKey]
    if cached then
        local stateOk = pcall(function() return cached:getFluidContainer() end)
        if stateOk then return cached end
        runtimeObjects[cacheKey] = nil
    end
    local cellOk, cell = pcall(World.getCellForPlayer, player)
    if not cellOk or not cell then return nil, "unloaded" end
    local index = tokenIndex(entry.objectToken)
    if index == nil then return nil, "missing" end
    local squareOk, square = pcall(World.getSquare, cell, entry.x, entry.y, entry.z)
    if not squareOk or not square then return nil, "unloaded" end
    local object = squareObjectAt(square, index)
    if not object then return nil, "missing" end
    runtimeObjects[cacheKey] = object
    return object
end

local function centralObject(identity, player)
    local server = rawget(_G, "RailroaderRV") and RailroaderRV.Server
    local manifest
    if server and type(server.currentRVManifestForBoundary) == "function" then
        local ok, accepted, value = pcall(server.currentRVManifestForBoundary,
            identity.rvId, identity.generation, identity.bitmapVersion)
        if ok and accepted == true then manifest = value end
    end
    local anchor = manifest and manifest.anchor
    if type(anchor) ~= "table" then return nil end
    local layoutOk, layout = pcall(Layout.make, anchor.x, anchor.y, anchor.z)
    if not layoutOk or type(layout) ~= "table" or type(layout.barrel) ~= "table" then return nil end
    local cellOk, cell = pcall(World.getCellForPlayer, player)
    if not cellOk or not cell then return nil end
    local squareOk, square = pcall(World.getSquare, cell, layout.barrel.x, layout.barrel.y, layout.barrel.z)
    if not squareOk or not square then return nil end
    local objects = World.squareSnapshot(square)
    for i = 1, #objects do
        local data = World.objectModData(objects[i])
        local tag = type(data) == "table" and data.RailroaderRVTest or nil
        if type(tag) == "table" and tag.role == "barrel"
            and tostring(tag.rvId) == tostring(identity.rvId)
            and Util.integer(tag.generation) == Util.integer(identity.generation)
            and Util.integer(tag.bitmapVersion) == Util.integer(identity.bitmapVersion) then
            return objects[i]
        end
    end
    return nil
end

local function objectFromHint(player, hint)
    if type(hint) ~= "table" then return false, U.REASONS.INVALID_REQUEST end
    local x, y, z, index = Util.integer(hint.x), Util.integer(hint.y),
        Util.integer(hint.z), Util.integer(hint.objectIndex)
    if x == nil or y == nil or z == nil or index == nil then
        return false, U.REASONS.INVALID_REQUEST
    end
    local position = playerPosition(player)
    if not position or math.abs(position.x - x) > U.DEVICE_REACH
        or math.abs(position.y - y) > U.DEVICE_REACH
        or math.floor(position.z) ~= z then return false, U.REASONS.OUTSIDE_RV end
    local cellOk, cell = pcall(World.getCellForPlayer, player)
    if not cellOk or not cell then return false, U.REASONS.TARGET_NOT_LOADED end
    local squareOk, square = pcall(World.getSquare, cell, x, y, z)
    if not squareOk or not square then return false, U.REASONS.TARGET_NOT_LOADED end
    local object = squareObjectAt(square, index)
    if not object then return false, U.REASONS.DEVICE_INVALID end
    return true, object
end

local function insideRecord(object, context)
    local positionOk, square = invoke(object, "getSquare")
    if not positionOk or not square then return false end
    local xOk, x = invoke(square, "getX")
    local yOk, y = invoke(square, "getY")
    local zOk, z = invoke(square, "getZ")
    if not xOk or not yOk or not zOk then return false end
    return inRegion({ x = Util.toNumber(x), y = Util.toNumber(y), z = Util.toNumber(z) },
        context and context.record and context.record.region)
end

local function hasPipeWrench(player)
    local inventoryOk, inventory = invoke(player, "getInventory")
    if not inventoryOk or not inventory then return false end
    local containsOk, contains = invoke(inventory, "contains", "Base.PipeWrench")
    if containsOk and contains == true then return true end
    local items = World.collectionSnapshot(select(2, invoke(inventory, "getItems")))
    for i = 1, #items do
        local typeOk, fullType = invoke(items[i], "getFullType")
        if typeOk and string.find(string.lower(tostring(fullType)), "pipewrench", 1, true) then
            return true
        end
    end
    return false
end

local function identityConflict(tag, identity)
    return tag and (tostring(tag.rvId) ~= tostring(identity.rvId)
        or Util.integer(tag.generation) ~= Util.integer(identity.generation)
        or Util.integer(tag.bitmapVersion) ~= Util.integer(identity.bitmapVersion))
end

local function inspectRegistry(record, identity, context)
    local active, initializing = {}, {}
    local seenTokens, seenObjects = {}, {}
    local remove = {}
    for deviceId, entry in pairs(record.water.registry) do
        local object, status = findDeviceObject(identity, entry, context and context.player)
        if status == "unloaded" then
            entry.status = U.STATUS_NEEDS_INIT
            if record.water.previousSnapshot[deviceId] then
                record.water.previousSnapshot[deviceId].status = U.STATUS_NEEDS_INIT
            end
        elseif not object then
            remove[#remove + 1] = deviceId
        else
            local token = objectToken(identity, object)
            local fingerprint = objectFingerprint(object, Catalog.DEVICE_CATALOG[entry.deviceType])
            local tag = objectTag(object)
            if not insideRecord(object, context) then
                remove[#remove + 1] = deviceId
            elseif identityConflict(tag, identity) then
                return false, U.REASONS.DEVICE_CONFLICT
            elseif tag == nil then
                remove[#remove + 1] = deviceId
            elseif token == nil or token ~= entry.objectToken or fingerprint ~= entry.objectFingerprint then
                remove[#remove + 1] = deviceId
            elseif tag and (tag.deviceId ~= entry.deviceId
                or tag.objectToken ~= entry.objectToken
                or tag.objectFingerprint ~= entry.objectFingerprint) then
                return false, U.REASONS.DEVICE_CONFLICT
            elseif seenTokens[token] or seenObjects[object] then
                return false, U.REASONS.DEVICE_CONFLICT
            else
                seenTokens[token], seenObjects[object] = true, true
                local snapshot = record.water.previousSnapshot[deviceId]
                if entry.status == U.STATUS_NEEDS_INIT or not snapshot
                    or snapshot.status ~= U.STATUS_ACTIVE then
                    -- Defer the single canonical->mirror write to mirrorAll;
                    -- this inspection pass only builds the current set and
                    -- must not perform a duplicate projection before usage
                    -- is calculated.
                    initializing[#initializing + 1] = { id = deviceId, object = object }
                else
                    local stateOk, state = readState(object)
                    if stateOk then
                        active[#active + 1] = { id = deviceId, object = object,
                            previous = snapshot, observed = state.amount }
                    else
                        entry.status = U.STATUS_NEEDS_INIT
                        snapshot.status = U.STATUS_NEEDS_INIT
                    end
                end
            end
        end
    end
    for i = 1, #remove do
        local deviceId = remove[i]
        record.water.registry[deviceId] = nil
        record.water.previousSnapshot[deviceId] = nil
        runtimeObjects[key(identity) .. ":" .. deviceId] = nil
    end
    return true, { active = active, initializing = initializing }
end

local function snapshotFor(water, deviceId, amount, status)
    return { deviceId = deviceId, amount = amount, capacity = water.capacity,
        fluidProfile = Catalog.copyProfile(water.fluidProfile), status = status }
end

local function mirrorSafely(object, water)
    local ok, result = pcall(mirrorObject, object, water)
    return ok and result == true
end

local function mirrorAll(record, identity, context, active, initializing)
    local central = centralObject(identity, context and context.player)
    local centralOk = central ~= nil and mirrorSafely(central, record.water)
    local success = 0
    for i = 1, #active do
        local item = active[i]
        local mirrored = mirrorSafely(item.object, record.water)
        if mirrored then
            record.water.registry[item.id].status = U.STATUS_ACTIVE
            record.water.previousSnapshot[item.id] = snapshotFor(record.water, item.id,
                record.water.sharedAmount, U.STATUS_ACTIVE)
            success = success + 1
        else
            record.water.registry[item.id].status = U.STATUS_NEEDS_INIT
            record.water.previousSnapshot[item.id].status = U.STATUS_NEEDS_INIT
        end
    end
    for i = 1, #initializing do
        local item = initializing[i]
        local mirrored = mirrorSafely(item.object, record.water)
        if mirrored then
            record.water.registry[item.id].status = U.STATUS_ACTIVE
            record.water.previousSnapshot[item.id] = snapshotFor(record.water, item.id,
                record.water.sharedAmount, U.STATUS_ACTIVE)
            success = success + 1
        else
            record.water.registry[item.id].status = U.STATUS_NEEDS_INIT
            record.water.previousSnapshot[item.id] = snapshotFor(record.water, item.id,
                record.water.sharedAmount, U.STATUS_NEEDS_INIT)
        end
    end
    return success, centralOk
end

function M.setPlayerContext(identity, player)
    if identity and player then runtimePlayers[key(identity)] = player end
end

function M.settleUnderGuard(identity, context)
    -- A caller without the current authoritative mapping must not turn every
    -- registry object into an apparent out-of-region removal.  Tick and
    -- command facades both supply this record after their identity gate.
    if type(context) ~= "table" or type(context.record) ~= "table"
        or type(context.record.region) ~= "table" then
        return false, U.REASONS.RV_NOT_FOUND
    end
    if tostring(context.record.rvId) ~= tostring(identity and identity.rvId)
        or Util.integer(context.record.generation) ~= Util.integer(identity and identity.generation)
        or Util.integer(context.record.bitmapVersion) ~= Util.integer(identity and identity.bitmapVersion) then
        return false, U.REASON_SAVE_REBUILD_REQUIRED
    end
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local record = recordOrReason
    if context and context.player then runtimePlayers[key(identity)] = context.player end
    local player = context and context.player or runtimePlayers[key(identity)]
    local inspectOk, inspected = inspectRegistry(record, identity, { player = player,
        record = context and context.record })
    if not inspectOk then return false, inspected end
    local usage = 0
    for i = 1, #inspected.active do
        local item = inspected.active[i]
        local previous = Util.toNumber(item.previous.amount) or 0
        local observed = clamp(item.observed, 0, record.water.capacity)
        if previous > observed then usage = usage + previous - observed end
    end
    local oldShared = clamp(record.water.sharedAmount, 0, record.water.capacity)
    local newShared = clamp(oldShared - usage, 0, record.water.capacity)
    local consumed = oldShared - newShared
    local newProfile = Catalog.profileSubtract(record.water.fluidProfile, consumed)
    if not newProfile then return false, U.REASONS.API_ERROR end
    record.water.sharedAmount = newShared
    record.water.fluidProfile = newProfile
    record.water.sequence = record.water.sequence + 1
    local success, centralOk = mirrorAll(record, identity, { player = player },
        inspected.active, inspected.initializing)
    if not centralOk then
        record.water.state = U.WATER_STATE_DEGRADED
    else
        record.water.state = success > 0 and U.WATER_STATE_READY or U.WATER_STATE_WAITING
    end
    local commitOk, commitReason = Store.commit(record, identity)
    if not commitOk then return false, commitReason end
    return true, { record = record, usage = usage, sharedAmount = newShared,
        sequence = record.water.sequence, devices = success }
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
    local items = {}
    inventoryItems(inventory, items, {})
    local wanted = hint.itemId or hint.id
    for i = 1, #items do
        local idOk, itemId = invoke(items[i], "getID")
        local matches = wanted ~= nil and idOk and tostring(itemId) == tostring(wanted)
        if matches then
            local container = objectContainer(items[i])
            local data = World.objectModData(items[i])
            local utilityTag = type(data) == "table"
                and data.RailroaderRVTestUtility or nil
            if container and type(utilityTag) ~= "table" then
                return true, items[i], container
            end
        end
    end
    return false, U.REASONS.SOURCE_NOT_INVENTORY
end

local function readSourceState(container)
    local amountOk, amount = invoke(container, "getAmount")
    local capacityOk, capacity = invoke(container, "getCapacity")
    amount = amountOk and Util.toNumber(amount) or nil
    capacity = capacityOk and Util.toNumber(capacity) or nil
    local profile = Catalog.readProfile(container)
    if not finite(amount) or not finite(capacity) or amount < 0 or capacity < 0
        or amount > capacity + U.PROFILE_EPSILON or not profile then
        return false, U.REASONS.SOURCE_INVALID
    end
    return true, { amount = clamp(amount, 0, capacity), capacity = capacity,
        fluidProfile = profile }
end

local function syncAfterAdd(record, identity, player)
    local active, init = {}, {}
    for deviceId, entry in pairs(record.water.registry) do
        if entry.status == U.STATUS_ACTIVE then
            local object = findDeviceObject(identity, entry, player)
            if object then active[#active + 1] = { id = deviceId, object = object }
            else
                entry.status = U.STATUS_NEEDS_INIT
                local snapshot = record.water.previousSnapshot[deviceId]
                if snapshot then snapshot.status = U.STATUS_NEEDS_INIT end
            end
        elseif entry.status == U.STATUS_NEEDS_INIT then
            local object = findDeviceObject(identity, entry, player)
            if object then init[#init + 1] = { id = deviceId, object = object } end
        end
    end
    return mirrorAll(record, identity, { player = player }, active, init)
end

function M.connectDevice(identity, context, hint)
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local record = recordOrReason
    local player = context and context.player
    if not player or not hasPipeWrench(player) then return false, U.REASONS.MISSING_TOOL end
    local objectOk, objectOrReason = objectFromHint(player, hint)
    if not objectOk then return false, objectOrReason end
    local object = objectOrReason
    if not insideRecord(object, context) then return false, U.REASONS.OUTSIDE_RV end
    local entry = Catalog.findEntry(object)
    if not entry then return false, U.REASONS.DEVICE_NOT_SUPPORTED end
    if not Catalog.entryIsValidated(entry) then return false, U.REASONS.DEVICE_NOT_VALIDATED end
    local token = objectToken(identity, object)
    local fingerprint = objectFingerprint(object, entry)
    if not token or not fingerprint then return false, U.REASONS.DEVICE_INVALID end
    local tag = objectTag(object)
    if identityConflict(tag, identity) then return false, U.REASONS.DEVICE_CONFLICT end
    if tag and tag.deviceId ~= nil then return false, U.REASONS.DEVICE_CONFLICT end
    for _, registered in pairs(record.water.registry) do
        if registered.objectToken == token then return false, U.REASONS.DEVICE_CONFLICT end
    end
    local registeredSequence = record.water.sequence + 1
    local deviceId = tostring(identity.rvId) .. ":device:" .. tostring(registeredSequence)
    while record.water.registry[deviceId] do
        registeredSequence = registeredSequence + 1
        deviceId = tostring(identity.rvId) .. ":device:" .. tostring(registeredSequence)
    end
    local registered = { deviceId = deviceId, deviceType = entry.id,
        rvId = tostring(identity.rvId), generation = identity.generation,
        bitmapVersion = identity.bitmapVersion, x = hint.x, y = hint.y, z = hint.z,
        objectToken = token, objectFingerprint = fingerprint,
        registeredSequence = registeredSequence, status = U.STATUS_NEEDS_INIT }
    if not writeObjectTag(object, identity, registered, token, fingerprint) then
        return false, U.REASONS.API_ERROR
    end
    record.water.registry[deviceId] = registered
    record.water.previousSnapshot[deviceId] = snapshotFor(record.water, deviceId,
        record.water.sharedAmount, U.STATUS_NEEDS_INIT)
    record.water.sequence = registeredSequence
    local mirrored = mirrorSafely(object, record.water)
    if mirrored then
        registered.status = U.STATUS_ACTIVE
        record.water.previousSnapshot[deviceId].status = U.STATUS_ACTIVE
    end
    record.water.state = mirrored and U.WATER_STATE_READY or U.WATER_STATE_WAITING
    local commitOk, commitReason = Store.commit(record, identity)
    if not commitOk then return false, commitReason end
    runtimeObjects[key(identity) .. ":" .. deviceId] = object
    return true, { record = record, deviceId = deviceId, sequence = record.water.sequence }
end

function M.addWater(identity, context, hint)
    local player = context and context.player
    -- Validate the independent player-held source before entering settlement;
    -- no existing device consumption should be committed for an invalid source.
    local sourceOk, sourceOrReason, container = resolveSource(player, hint)
    if not sourceOk then return false, sourceOrReason end
    local sourceStateOk, sourceStateOrReason = readSourceState(container)
    if not sourceStateOk then return false, sourceStateOrReason end
    if sourceStateOrReason.amount <= U.PROFILE_EPSILON then
        return false, U.REASONS.SOURCE_INVALID
    end
    local settledOk, settled = M.settleUnderGuard(identity, context)
    if not settledOk then return false, settled end
    local record = settled.record
    -- Re-resolve after settlement so the amount/profile used for planned and
    -- confirmed transfer still describe the server-owned inventory item.
    local sourceAfterOk, sourceAfterOrReason, sourceAfter = resolveSource(player, hint)
    if not sourceAfterOk then return false, sourceAfterOrReason end
    if sourceAfter ~= container then return false, U.REASONS.SOURCE_INVALID end
    container = sourceAfter
    local afterStateOk, afterStateOrReason = readSourceState(container)
    if not afterStateOk then return false, afterStateOrReason end
    if afterStateOrReason.amount <= U.PROFILE_EPSILON then
        return false, U.REASONS.SOURCE_INVALID
    end
    local sourceAmount = afterStateOrReason.amount
    local sourceProfile = afterStateOrReason.fluidProfile
    local remaining = math.max(0, record.water.capacity - record.water.sharedAmount)
    if remaining <= U.PROFILE_EPSILON then return false, U.REASONS.CAPACITY_FULL end
    local plannedTransfer = math.min(remaining,
        math.min(sourceAmount, afterStateOrReason.capacity))
    local before = sourceAmount
    local removeCallOk, removeResult = invoke(container, "removeFluid", plannedTransfer, false)
    local removed = removeCallOk and removeResult ~= false
    if not removed then
        local adjustCallOk, adjustResult = invoke(container, "adjustAmount",
            before - plannedTransfer)
        removed = adjustCallOk and adjustResult ~= false
    end
    if not removed then return false, U.REASONS.API_ERROR end
    local afterOk, after = invoke(container, "getAmount")
    after = afterOk and Util.toNumber(after) or nil
    if not finite(after) then return false, U.REASONS.API_ERROR end
    local confirmedTransfer = clamp(before - after, 0, plannedTransfer)
    if confirmedTransfer <= U.PROFILE_EPSILON then return false, U.REASONS.SOURCE_INVALID end
    local mixed = Catalog.profileAdd(record.water.fluidProfile, sourceProfile,
        confirmedTransfer, before)
    if not mixed then return false, U.REASONS.SOURCE_INVALID end
    record.water.sharedAmount = clamp(record.water.sharedAmount + confirmedTransfer,
        0, record.water.capacity)
    record.water.fluidProfile = mixed
    record.water.sequence = record.water.sequence + 1
    local synced, centralOk = syncAfterAdd(record, identity, player)
    if not centralOk then
        record.water.state = U.WATER_STATE_DEGRADED
    else
        record.water.state = synced > 0 and U.WATER_STATE_READY or U.WATER_STATE_WAITING
    end
    local commitOk, commitReason = Store.commit(record, identity)
    if not commitOk then return false, commitReason end
    return true, { record = record, plannedTransfer = plannedTransfer,
        confirmedTransfer = confirmedTransfer, sharedAmount = record.water.sharedAmount,
        sequence = record.water.sequence }
end

function M.resolveObjectForPower(player, hint)
    return objectFromHint(player, hint)
end

function M.snapshot(record)
    return Store.copyWater(record.water)
end

return M
