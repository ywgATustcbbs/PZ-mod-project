-- RV_UtilityWater: Commands responsibilities.
return function(ctx)
local C = ctx.C
local U = ctx.U
local Catalog = ctx.Catalog
local Store = ctx.Store
local Util = ctx.Util
local World = ctx.World
local M = ctx.M
local runtimePlayers = ctx.runtimePlayers
local accountingGuard = ctx.accountingGuard
local pendingDetachedFixtures = ctx.pendingDetachedFixtures
local function fixtureSourceGone(...) return ctx.fixtureSourceGone(...) end
local function removeObject(...) return ctx.removeObject(...) end
local key = ctx.key
local sameValue = ctx.sameValue
local clamp = ctx.clamp
local invoke = ctx.invoke
local coords = ctx.coords
local objectContainer = ctx.objectContainer
local externalWaterMatches = ctx.externalWaterMatches
local objectFingerprint = ctx.objectFingerprint
local objectTag = ctx.objectTag
local validUtilityTag = ctx.validUtilityTag
local allObjects = ctx.allObjects
local objectAtHint = ctx.objectAtHint
local squareObject = ctx.squareObject
local applyAmount = ctx.applyAmount
local validCurrentFixture = ctx.validCurrentFixture
local usageObject = ctx.usageObject
local proxyObject = ctx.proxyObject
local collectProxyDelta = ctx.collectProxyDelta
local flushBeforeOverwrite = ctx.flushBeforeOverwrite
local restoreFixtureTag = ctx.restoreFixtureTag
local pendingDetachedFixtureKey = ctx.pendingDetachedFixtureKey
local clearPendingDetachedFixture = ctx.clearPendingDetachedFixture
local setFixtureExternal = ctx.setFixtureExternal

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
    return amount
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
            and (removeDelta == nil or removeDelta <= U.PROFILE_EPSILON) then
            removed, result = invoke(container, "adjustAmount", before - plannedTransfer)
        elseif not removed or result == false then
            -- Some builds report a failed remove call after applying a
            -- partial amount. Preserve that observable delta and validate it
            -- below instead of issuing a second removal against the source.
            removed, result = true, true
        end
        local after = readItemAmount(container)
        local observedDelta = after and before - after or nil
        if not removed or not after or observedDelta == nil
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


end
