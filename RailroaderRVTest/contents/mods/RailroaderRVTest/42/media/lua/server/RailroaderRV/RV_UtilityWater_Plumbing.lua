-- RV_UtilityWater: Plumbing responsibilities.
return function(ctx)
local C = ctx.C
local U = ctx.U
local Catalog = ctx.Catalog
local Store = ctx.Store
local Util = ctx.Util
local World = ctx.World
local M = ctx.M
local runtimeObjects = ctx.runtimeObjects
local runtimePlayers = ctx.runtimePlayers
local pendingDetachedFixtures = ctx.pendingDetachedFixtures
local function fixtureSourceGone(...) return ctx.fixtureSourceGone(...) end
local function retireEntry(...) return ctx.retireEntry(...) end
local function removeObject(...) return ctx.removeObject(...) end
local function objectAttached(...) return ctx.objectAttached(...) end
local key = ctx.key
local invoke = ctx.invoke
local coords = ctx.coords
local objectCoordinates = ctx.objectCoordinates
local externalWaterMatches = ctx.externalWaterMatches
local hiddenObjectFingerprint = ctx.hiddenObjectFingerprint
local objectFingerprint = ctx.objectFingerprint
local objectTag = ctx.objectTag
local genericObjectTag = ctx.genericObjectTag
local retiredObjectTag = ctx.retiredObjectTag
local sameIdentity = ctx.sameIdentity
local sameGenerationIdentity = ctx.sameGenerationIdentity
local validUtilityTag = ctx.validUtilityTag
local nextToken = ctx.nextToken
local writeUtilityTag = ctx.writeUtilityTag
local allObjects = ctx.allObjects
local objectAtHint = ctx.objectAtHint
local squareObject = ctx.squareObject
local applyAmount = ctx.applyAmount
local makeObject = ctx.makeObject
local fixtureInside = ctx.fixtureInside
local collectProxyDelta = ctx.collectProxyDelta
local flushBeforeOverwrite = ctx.flushBeforeOverwrite

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


ctx.restoreFixtureTag = restoreFixtureTag
ctx.pendingDetachedFixtureKey = pendingDetachedFixtureKey
ctx.clearPendingDetachedFixture = clearPendingDetachedFixture
ctx.setFixtureExternal = setFixtureExternal
ctx.removeObject = removeObject
ctx.fixtureSourceGone = fixtureSourceGone
ctx.retireEntry = retireEntry
end
