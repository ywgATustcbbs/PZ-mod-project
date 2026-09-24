-- RV_UtilityWater: Ledger responsibilities.
return function(ctx)
local C = ctx.C
local U = ctx.U
local Catalog = ctx.Catalog
local Store = ctx.Store
local Util = ctx.Util
local M = ctx.M
local accountingGuard = ctx.accountingGuard
local function retireEntry(...) return ctx.retireEntry(...) end
local key = ctx.key
local sameValue = ctx.sameValue
local clamp = ctx.clamp
local invoke = ctx.invoke
local inRegion = ctx.inRegion
local coords = ctx.coords
local objectContainer = ctx.objectContainer
local externalWaterMatches = ctx.externalWaterMatches
local objectFingerprint = ctx.objectFingerprint
local objectTag = ctx.objectTag
local validUtilityTag = ctx.validUtilityTag
local squareObject = ctx.squareObject
local rollbackCreatedObject = ctx.rollbackCreatedObject
local applyAmount = ctx.applyAmount
local makeObject = ctx.makeObject

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
    if amount == nil or capacity == nil or amount < 0 or capacity <= 0
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
    if expectedAmount == nil or expectedCapacity == nil
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


ctx.fixtureInside = fixtureInside
ctx.validCurrentFixture = validCurrentFixture
ctx.usageObject = usageObject
ctx.proxyObject = proxyObject
ctx.collectProxyDelta = collectProxyDelta
ctx.flushBeforeOverwrite = flushBeforeOverwrite
end
