-- Server-authoritative sink connection commands.

local C = require("RailroaderRV/Common/RV_Constants")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local Store = require("RailroaderRV/Core/RV_UtilityStore")
local Util = require("RailroaderRV/Common/RV_ServerUtil")
local Objects = require("RailroaderRV/Water/RV_UtilityWater_Objects")
local Ledger = require("RailroaderRV/Water/RV_UtilityWater_Ledger")
local Plumbing = require("RailroaderRV/Water/RV_UtilityWater_Plumbing")
local Catalog = require("RailroaderRV/Water/RV_UtilityCatalog")
local World = require("RailroaderRV/Common/RV_ServerWorld")

local M = {}
local runtimeFaults = {}
local pendingRemovals = {}
local REMOVAL_CONFIRM_TICKS = 20

local function markNeedsReconcile(identity, record)
    local key = Util.identityKey(identity.rvId, identity.generation)
    record.water.state = U.WATER_STATE_NEEDS_RECONCILE
    local committed = Store.commit(record, identity)
    if committed ~= true then runtimeFaults[key] = true end
    return committed == true
end

local function currentMappingRecord(identity)
    local rv = rawget(_G, "RailroaderRV")
    local adapter = rv and rv.RailroaderServer
    local accepted, record = adapter.currentUtilityRecord(identity)
    if accepted ~= true then
        return false, C.INVALID_RV_DATA
    end
    return true, record
end

local function copyIdentity(identity)
    return { rvId = identity.rvId, generation = identity.generation }
end

local function copyMappingRecord(record)
    if type(record) ~= "table" or type(record.anchor) ~= "table" then return nil end
    return { slotIndex = record.slotIndex,
        anchor = { x = record.anchor.x, y = record.anchor.y, z = record.anchor.z } }
end

local function sinkCoordinates(object)
    local squareOk, square = Util.invoke(object, "getSquare")
    if not squareOk or not square then return nil end
    local xOk, x = Util.invoke(square, "getX")
    local yOk, y = Util.invoke(square, "getY")
    local zOk, z = Util.invoke(square, "getZ")
    x, y, z = xOk and Util.integer(x) or nil, yOk and Util.integer(y) or nil,
        zOk and Util.integer(z) or nil
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

local function pendingKey(identity, x, y, z)
    return Util.identityKey(identity.rvId, identity.generation)
        .. ":" .. tostring(x) .. ":" .. tostring(y)
        .. ":" .. tostring(z)
end

local function pendingCount(identity)
    local key = Util.identityKey(identity.rvId, identity.generation)
    local count = 0
    for _, pending in pairs(pendingRemovals) do
        if pending.identityKey == key then count = count + 1 end
    end
    return count
end

local function markRemovalFault(pending, record)
    if record then markNeedsReconcile(pending.identity, record) end
    runtimeFaults[pending.identityKey] = true
end

local function processRemoval(pending, pendingId)
    local cellOk, cell = pcall(World.getCellForPlayer, nil)
    if not cellOk or not cell then
        pending.attempts = pending.attempts + 1
        if pending.attempts >= REMOVAL_CONFIRM_TICKS then
            local recordOk, record = Store.getRecord(pending.identity, false)
            markRemovalFault(pending, recordOk and record or nil)
            pendingRemovals[pendingId] = nil
        end
        return
    end
    local squareOk, square = pcall(World.getSquare, cell,
        pending.x, pending.y, pending.z)
    if not squareOk or not square then
        pending.attempts = pending.attempts + 1
        if pending.attempts >= REMOVAL_CONFIRM_TICKS then
            local recordOk, record = Store.getRecord(pending.identity, false)
            markRemovalFault(pending, recordOk and record or nil)
            pendingRemovals[pendingId] = nil
        end
        return
    end
    local snapshotOk, objects, complete = pcall(World.strictSquareSnapshot, square)
    if not snapshotOk or complete ~= true or type(objects) ~= "table" then
        local recordOk, record = Store.getRecord(pending.identity, false)
        markRemovalFault(pending, recordOk and record or nil)
        pendingRemovals[pendingId] = nil
        return
    end
    local sameObject, matchingIdentity = false, false
    for i = 1, #objects do
        local object = objects[i]
        if object == pending.object then
            sameObject = true
        elseif Catalog.isCurrentWaterSink(object, pending.identity,
            pending.mappingRecord) then
            local coords = sinkCoordinates(object)
            if coords and coords.x == pending.x and coords.y == pending.y
                and coords.z == pending.z then
                matchingIdentity = true
            end
        end
    end
    if sameObject then
        pending.attempts = pending.attempts + 1
        if pending.attempts >= REMOVAL_CONFIRM_TICKS then
            local recordOk, record = Store.getRecord(pending.identity, false)
            markRemovalFault(pending, recordOk and record or nil)
            pendingRemovals[pendingId] = nil
        end
        return
    end
    local recordOk, record = Store.getRecord(pending.identity, false)
    local mappingOk, mappingRecord = currentMappingRecord(pending.identity)
    if not recordOk or not mappingOk then
        markRemovalFault(pending, recordOk and record or nil)
        pendingRemovals[pendingId] = nil
        return
    end
    local currentMapping = copyMappingRecord(mappingRecord)
    if not currentMapping or currentMapping.slotIndex ~= pending.mappingRecord.slotIndex
        or currentMapping.anchor.x ~= pending.mappingRecord.anchor.x
        or currentMapping.anchor.y ~= pending.mappingRecord.anchor.y
        or currentMapping.anchor.z ~= pending.mappingRecord.anchor.z then
        markRemovalFault(pending, record)
        pendingRemovals[pendingId] = nil
        return
    end
    if matchingIdentity then
        markRemovalFault(pending, record)
        pendingRemovals[pendingId] = nil
        return
    end
    local entryOk, entry, ledgerKey = Ledger.getEntry(record.water,
        pending.identity, mappingRecord, { x = pending.x, y = pending.y, z = pending.z })
    if not entryOk then
        markRemovalFault(pending, record)
        pendingRemovals[pendingId] = nil
        return
    end
    if entry ~= nil then record.water.sinks[ledgerKey] = nil end
    pendingRemovals[pendingId] = nil
    record.water.state = pendingCount(pending.identity) > 0
        and U.WATER_STATE_NEEDS_RECONCILE or U.WATER_STATE_ACTIVE
    local committed = Store.commit(record, pending.identity)
    if committed ~= true then
        markRemovalFault(pending, nil)
    end
end

function M.onObjectRemoved(object)
    if not Catalog.hasSinkIdentity(object) then return true end
    local identity = Catalog.readSinkIdentity(object)
    local coordinates = sinkCoordinates(object)
    if type(identity) ~= "table" or not coordinates then
        return false, C.INVALID_RV_DATA
    end
    local mappingOk, mappingRecord = currentMappingRecord(identity)
    local copiedMapping = mappingOk and copyMappingRecord(mappingRecord) or nil
    if not mappingOk or not copiedMapping or not Catalog.isCurrentWaterSink(object, identity,
        mappingRecord) then
        return false, C.INVALID_RV_DATA
    end
    local recordOk, recordOrReason = Store.getRecord(identity, false)
    if not recordOk then return false, recordOrReason end
    local key = Util.identityKey(identity.rvId, identity.generation)
    if recordOrReason.water.state ~= U.WATER_STATE_ACTIVE
        and not (recordOrReason.water.state == U.WATER_STATE_NEEDS_RECONCILE
            and pendingCount(identity) > 0 and not runtimeFaults[key]) then
        runtimeFaults[key] = true
        return false, C.INVALID_RV_DATA
    end
    local entryOk, entry, ledgerKey = Ledger.getEntry(recordOrReason.water,
        identity, mappingRecord, coordinates)
    if not entryOk or entry == nil then
        markNeedsReconcile(identity, recordOrReason)
        return false, C.INVALID_RV_DATA
    end
    local connectedOk, connected = Util.invoke(object, "getUsesExternalWaterSource")
    if not connectedOk or type(connected) ~= "boolean"
        or connected ~= entry.connected then
        markNeedsReconcile(identity, recordOrReason)
        return false, C.INVALID_RV_DATA
    end
    local id = pendingKey(identity, coordinates.x, coordinates.y, coordinates.z)
    local existing = pendingRemovals[id]
    if existing and existing.object ~= object then
        markRemovalFault(existing, recordOrReason)
        return false, C.INVALID_RV_DATA
    end
    if existing then return true end
    recordOrReason.water.state = U.WATER_STATE_NEEDS_RECONCILE
    local stateCommitted = Store.commit(recordOrReason, identity)
    if stateCommitted ~= true then
        runtimeFaults[key] = true
    end
    pendingRemovals[id] = {
        identity = copyIdentity(identity), identityKey = key,
        mappingRecord = copiedMapping,
        x = coordinates.x, y = coordinates.y, z = coordinates.z,
        object = object, ledgerKey = ledgerKey, attempts = 0,
    }
    if stateCommitted ~= true then
        return false, U.REASONS.CANONICAL_COMMIT_FAILED
    end
    return true
end

function M.onTick()
    for id, pending in pairs(pendingRemovals) do
        processRemoval(pending, id)
    end
end

local function hasPipeWrench(player)
    local inventoryOk, inventory = Util.invoke(player, "getInventory")
    if not inventoryOk or not inventory then return false end
    local containsOk, contains = Util.invoke(inventory, "contains", "Base.PipeWrench")
    return containsOk and contains == true
end

function M.setConnection(identity, context, hint, record)
    if type(record) ~= "table" or type(record.water) ~= "table" then
        return false, C.INVALID_RV_DATA
    end
    local key = Util.identityKey(identity.rvId, identity.generation)
    if runtimeFaults[key] then return false, C.INVALID_RV_DATA end
    if record.water.state ~= U.WATER_STATE_ACTIVE then
        return false, C.INVALID_RV_DATA
    end
    if not hasPipeWrench(context and context.player) then
        return false, U.REASONS.MISSING_TOOL
    end
    local mappingOk, mappingReason = Ledger.validateMapping(record.water,
        identity, context and context.record)
    if not mappingOk then
        markNeedsReconcile(identity, record)
        return false, mappingReason
    end
    local resolved, sinkOrReason = Objects.resolveSink(identity, context, hint)
    if not resolved then return false, sinkOrReason end
    local sink = sinkOrReason
    local entryOk, oldEntry, deviceKey = Ledger.getEntry(record.water, identity,
        context.record, sink)
    if not entryOk then
        markNeedsReconcile(identity, record)
        return false, C.INVALID_RV_DATA
    end
    if oldEntry and oldEntry.connected ~= sink.currentConnected then
        markNeedsReconcile(identity, record)
        return false, C.INVALID_RV_DATA
    end
    if (oldEntry ~= nil) ~= (sink.hasIdentity == true) then
        markNeedsReconcile(identity, record)
        return false, C.INVALID_RV_DATA
    end

    local tagOk, identityToken, tagCompensated = Objects.ensureSinkIdentity(
        sink.object, identity, context.record)
    if not tagOk then
        if tagCompensated ~= true then markNeedsReconcile(identity, record) end
        return false, identityToken
    end

    local desired = sink.connected
    local oldEntryCopy = Ledger.copyEntry(oldEntry)
    local applied, detail, compensationCertain = Plumbing.apply(sink.object, desired)
    if not applied then
        local tagRestored = Objects.rollbackSinkIdentity(sink.object, identityToken)
        if compensationCertain ~= true or not tagRestored then
            markNeedsReconcile(identity, record)
        end
        return false, detail
    end

    local sequence = oldEntry and oldEntry.sequence + 1 or 1
    record.water.sinks[deviceKey] = Ledger.newEntry(identity, context.record,
        sink, desired, sequence)
    local committed, commitReason = Store.commit(record, identity)
    if not committed then
        record.water.sinks[deviceKey] = oldEntryCopy
        local pipeRestored = Plumbing.rollback(sink.object, detail.previous)
        local tagRestored = Objects.rollbackSinkIdentity(sink.object, identityToken)
        if not pipeRestored or not tagRestored then
            markNeedsReconcile(identity, record)
        end
        return false, commitReason
    end
    return true, { record = record, connected = desired, sequence = sequence }
end

return M
