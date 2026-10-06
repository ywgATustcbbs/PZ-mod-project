-- RV_Server: Commands responsibilities.
local ClientDebug = require("RailroaderRV/Core/RV_Server_ClientDebug")

return function(ctx)
local Core = ctx.Core
local COMMAND_MODULE = ctx.COMMAND_MODULE
local COMMAND_RELOCATE_ACK = ctx.COMMAND_RELOCATE_ACK
local COMMAND_FINAL_RELOCATE_ACK = ctx.COMMAND_FINAL_RELOCATE_ACK
local COMMAND_RV_ENTER = ctx.COMMAND_RV_ENTER
local COMMAND_RV_EXIT = ctx.COMMAND_RV_EXIT
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local RV = ctx.RV
local ServerSchema = ctx.ServerSchema
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local UtilityServer = ctx.UtilityServer
local GenerationTransaction = ctx.GenerationTransaction
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local TemplateGeometry = require("RailroaderRV/RoomTemplate/RV_TemplateGeometry")
local WallReload = require("RailroaderRV/WallReloadProtection/RV_WallReloadProtection")
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local templateObjects = RoomTemplate.orderedObjects(Template)
local function safeErrorText(...) return ctx.safeErrorText(...) end
local notifyFailure = ctx.notifyFailure
local requestRoomOwnershipScan = ctx.requestRoomOwnershipScan
local requestRoomOwnershipRemovalScan = ctx.requestRoomOwnershipRemovalScan
local processServerRoomOwnershipGuards = ctx.processServerRoomOwnershipGuards
local keepGenerationTransitionAlive = ctx.keepGenerationTransitionAlive
local validateAuthoritativePlayer = ctx.validateAuthoritativePlayer
local validateGenerationPermission = ctx.validateGenerationPermission
local resolvePendingPlayer = ctx.resolvePendingPlayer
local playerIsAtStagingDestination = ctx.playerIsAtStagingDestination
local validateRequest = ctx.validateRequest
local generateForPlayer = ctx.generateForPlayer
local finalizeGenerationAfterRelocate = ctx.finalizeGenerationAfterRelocate
local queueGeneration = ctx.queueGeneration
local acknowledgeRelocation = ctx.acknowledgeRelocation
local acknowledgeFinalRelocation = ctx.acknowledgeFinalRelocation
local abortGeneration = ctx.abortGeneration

local stateReaders = {
    { "open", "isOpen" }, { "locked", "isLocked" },
    { "hoppable", "isHoppable" }, { "health", "getHealth" },
    { "maxHealth", "getMaxHealth" }, { "fuel", "getFuelAmount" },
    { "water", "getWaterAmount" }, { "uses", "getUses" },
}

local function isTransientObject(object)
    if ServerWorld.isPlayerObject(object) or ServerWorld.isVehicleObject(object) then
        return true
    end
    for _, className in ipairs({ "IsoZombie", "IsoAnimal", "IsoDeadBody",
        "IsoWorldInventoryObject" }) do
        if ServerUtil.classInstance(object, className) then return true end
    end
    return false
end

local function captureObjectClass(object)
    local _, class = ServerUtil.invoke(object, "getClass")
    local name = string.gsub(tostring(class), "^class%s+", "")
    return string.match(name, "([^%.]+)$") or name
end

local function captureObjectName(object)
    for _, method in ipairs({ "getName", "getObjectName", "getCustomName" }) do
        local ok, name = ServerUtil.invoke(object, method)
        if ok and name ~= nil then
            return tostring(name)
        end
    end
    return nil
end

local function captureObjectState(object)
    local values = {}
    for index = 1, #stateReaders do
        local reader = stateReaders[index]
        local ok, value = ServerUtil.invoke(object, reader[2])
        if ok and value ~= nil then
            values[#values + 1] = reader[1] .. "=" .. tostring(value)
        end
    end
    return table.concat(values, ",")
end

local function dumpTemplateCapture(player)
    local valid, positionOrReason = validateAuthoritativePlayer(player)
    if not valid then return false, positionOrReason end
    local allowed, permissionReason = validateGenerationPermission(player)
    if not allowed then return false, permissionReason end

    local position = positionOrReason
    local anchor = TemplateGeometry.templateAnchorForWorld(
        position.x, position.y, position.z)
    if not anchor or not TemplateGeometry.isWalkable(position, anchor, Template) then
        return false, "player is outside the current template editing geometry"
    end

    local cell = ServerWorld.getCellForPlayer(player)
    local seenHosts = {}
    local objectCount = 0
    local function captureHost(x, y, z)
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if seenHosts[key] then return end
        seenHosts[key] = true
        local square = ServerWorld.getSquare(cell,
            anchor.x + x, anchor.y + y, anchor.z + z)
        if not square then return end
        local objects = ServerWorld.squareSnapshot(square)
        for index = 1, #objects do
            local object = objects[index]
            if not isTransientObject(object) then
                local northOk, north = ServerUtil.invoke(object, "getNorth")
                local directionOk, direction = ServerUtil.invoke(object, "getDir")
                local northValue, directionValue
                if northOk then northValue = north end
                if directionOk then directionValue = direction end
                objectCount = objectCount + 1
                print("[RailroaderRV][TemplateCapture] object rel="
                    .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
                    .. " class=" .. captureObjectClass(object)
                    .. " name=" .. tostring(captureObjectName(object))
                    .. " sprite=" .. tostring(ServerWorld.getSpriteName(object))
                    .. " north=" .. tostring(northValue)
                    .. " direction=" .. tostring(directionValue)
                    .. " state=" .. captureObjectState(object))
            end
        end
    end

    for index = 1, #Template.misc.walkAabbs do
        local box = Template.misc.walkAabbs[index]
        for z = box.minZ, box.maxZExclusive - 1 do
            for y = box.minY, box.maxY - 1 do
                for x = box.minX, box.maxX - 1 do
                    captureHost(x, y, z)
                end
            end
        end
    end
    for index = 1, #Template.misc.buildCells do
        local buildCell = Template.misc.buildCells[index]
        local z = buildCell.z == nil and Template.metadata.anchor.z or buildCell.z
        captureHost(buildCell.x, buildCell.y, z)
        captureHost(buildCell.x + 1, buildCell.y, z)
        captureHost(buildCell.x, buildCell.y + 1, z)
    end
    for index = 1, #templateObjects do
        local object = templateObjects[index]
        captureHost(object.x, object.y, object.z)
    end

    print("[RailroaderRV][TemplateCapture] origin="
        .. tostring(anchor.x) .. "," .. tostring(anchor.y) .. "," .. tostring(anchor.z)
        .. " bounds=100x100 objects=" .. tostring(objectCount))
    return true
end

local function isInvalidRVData(reason)
    local marker = Constants and Constants.INVALID_RV_DATA
    return type(marker) == "string" and marker ~= ""
        and string.find(tostring(reason), marker, 1, true) ~= nil
end

-- One abort path for every generation stage.  The acknowledgement module owns
-- the cleanup; this handler owns the one decision to run it, so a failed
-- operation is marked cancelled once, logged once, and the player can press the
-- button again.  `GenerationTransaction.cancel` is the request signal;
-- `abortGeneration` is the only observer.
local function runGenerationAbort(record, reason)
    if record == nil then return end
    GenerationTransaction.cancel(reason)
    local abortOk, abortError = pcall(abortGeneration, record, reason)
    if not abortOk then
        GenerationTransaction.release()
        error(abortError, 0)
    end
end

-- The generation stage machine: WAIT_STAGING -> BUILD -> WAIT_FINAL -> DONE.
-- `record.stage` is the single stage authority; there is no rollback stage and
-- no retry ledger.  Every branch either advances, returns, or aborts once.
local function processPendingGeneration()
    local record = GenerationTransaction.current()
    if record == nil then
        return
    end
    if ctx.serverTick > record.deadlineTick then
        runGenerationAbort(record, "generation transaction timed out in stage "
            .. tostring(record.stage))
        return
    end
    -- A missing player can no longer prevent the fixed acknowledgement timeout
    -- from closing this transaction.
    local resolved, playerOrReason = resolvePendingPlayer(record)
    if not resolved then
        return
    end
    local player = playerOrReason

    if record.stage == "WAIT_STAGING" then
        if record.stagingAcked ~= true then
            return
        end
        local atStaging = playerIsAtStagingDestination(player,
            record.stagingDestination, record.bounds)
        if not atStaging then
            return
        end
        -- The relocation streams the remote target asynchronously. Wait until
        -- every base square in the cleanup scope is visible before beginning
        -- world mutation.
        local targetLoaded, targetLoadReason = ServerSchema.targetAreaLoadStatus(
            player, record.bounds, safeErrorText)
        if targetLoaded == nil then
            runGenerationAbort(record, targetLoadReason)
            return
        end
        if not targetLoaded then
            return
        end
        local built, buildReason = generateForPlayer(player, record)
        if not built then
            runGenerationAbort(record, buildReason)
        end
        -- On success the build step has already sent the final relocation and
        -- moved the record to WAIT_FINAL.
        return
    end

    if record.stage == "BUILD" then
        -- `generateForPlayer` claims BUILD before it can fail; reaching this
        -- branch means the previous build step returned without reaching
        -- WAIT_FINAL, so surface it and abort once.  The record never stays in
        -- BUILD across ticks.
        runGenerationAbort(record, "generation build did not complete")
        return
    end

    if record.stage == "WAIT_FINAL" then
        if record.finalAcked ~= true then
            return
        end
        local committed, commitReason = finalizeGenerationAfterRelocate(
            player, record)
        if committed then
            GenerationTransaction.release()
        elseif commitReason == "final relocation authoritative target is still synchronizing" then
            -- The commit step re-asserted the server-selected target and will
            -- require a fresh post-update proof on the next tick, until the
            -- deadline or a proved position.
            return
        else
            print("[RailroaderRV] generation finalization failed: "
                .. safeErrorText(commitReason))
            runGenerationAbort(record, commitReason)
        end
        return
    end

    error("RailroaderRV: unknown generation transaction stage "
        .. tostring(record.stage), 0)
end

function RV.Server.OnTick(tick)
    ctx.serverTick = tick
    WallReload.onTick()
    local generationRecord = GenerationTransaction.current()
    if generationRecord ~= nil then
        keepGenerationTransitionAlive(generationRecord)
    end
    Boundary.onTick()
    processServerRoomOwnershipGuards()
    UtilityServer.onTick(ctx.serverTick)
    local pendingOk, pendingError = pcall(processPendingGeneration)
    if not pendingOk then
        local failedRecord = GenerationTransaction.current()
        if failedRecord ~= nil then
            runGenerationAbort(failedRecord, pendingError)
        end
        error(pendingError, 0)
    end
end

function RV.Server.OnClientCommand(module, command, player, args)
    -- OnClientCommand is shared by every mod.  Foreign Railroader/vanilla
    -- commands are not RV requests and must not be reported as malformed RV
    -- traffic.
    if module ~= COMMAND_MODULE then
        return
    end
    if command == Constants.COMMAND_RV_CLIENT_DEBUG then
        ClientDebug.handle(player, args)
        return
    end
    if command == Constants.COMMAND_RV_UTILITY then
        local operation = type(args) == "table" and args.operation or nil
        local utilityAccepted, utilityReason = UtilityServer.handleCommand(
            player, args)
        if utilityAccepted ~= true then
            print("[RailroaderRV] utility command rejected operation="
                .. tostring(operation) .. " entry=command phase=handle reason="
                .. safeErrorText(utilityReason))
        end
        return
    end
    if command == Constants.COMMAND_RV_SAFEHOUSE_CLAIM then
        local accepted, reason = RV.Server.handleSafehouseClaim(player, args)
        if accepted ~= true then
            print("[RailroaderRV] safehouse claim rejected reason="
                .. safeErrorText(reason))
        end
        return
    end
    -- The Railroader adapter owns these two commands.  This handler is also
    -- registered on the same event, so do not let the generic empty-payload
    -- validator log them as malformed Generate requests.
    if module == COMMAND_MODULE
        and (command == COMMAND_RV_ENTER or command == COMMAND_RV_EXIT) then
        return
    end
    if module == Constants.MOD_ID
        and command == Constants.COMMAND_DUMP_TEMPLATE_CAPTURE then
        local accepted, reason = dumpTemplateCapture(player)
        if accepted ~= true then
            print("[RailroaderRV][TemplateCapture] rejected reason="
                .. tostring(reason or "unspecified reason"))
        end
        return
    end
    if module == COMMAND_MODULE and command == COMMAND_FINAL_RELOCATE_ACK then
        local accepted, reason = acknowledgeFinalRelocation(player, args)
        if not accepted then
            if isInvalidRVData(reason) then
                -- A final ACK that cannot belong to the record's current stage
                -- means the client is out of contract with the server-owned
                -- transaction; run the single abort path instead of leaving the
                -- generation waiting for an acknowledgement it cannot accept.
                runGenerationAbort(GenerationTransaction.current(), reason)
                return
            end
            print("[RailroaderRV] final relocation acknowledgement rejected: "
                .. safeErrorText(reason))
        end
        return
    end
    if module == COMMAND_MODULE and command == COMMAND_RELOCATE_ACK then
        local accepted, reason = acknowledgeRelocation(player, args)
        if not accepted then
            print("[RailroaderRV] relocation acknowledgement rejected: "
                .. safeErrorText(reason))
        end
        return
    end
    local accepted, reason = validateRequest(module, command, player)
    if not accepted then
        if isInvalidRVData(reason) then notifyFailure(player, reason) end
        print("[RailroaderRV] command rejected: " .. safeErrorText(reason))
        return
    end
    -- Request validation and ownership come from the server-side player object;
    -- generation coordinates come from the mapping slot allocator. Args are
    -- intentionally ignored to prevent client-side placement spoofing.
    local ok, reason = queueGeneration(player, reason)
    if not ok then
        notifyFailure(player, reason)
        print("[RailroaderRV] generation request failed: " .. tostring(reason))
    end
end

Core.onCommand("*", RV.Server.OnClientCommand)
Core.onTick(RV.Server.OnTick)
Core.on("OnProcessAction", Boundary.onProcessAction)
Core.on("OnObjectAdded", Boundary.onObjectAdded)
Core.on("OnObjectAboutToBeRemoved", requestRoomOwnershipRemovalScan)
Core.on("OnObjectAdded", requestRoomOwnershipScan)

-- Load after RV.Server has been fully constructed.  The Railroader adapter is
-- intentionally a separate module so the generic generation transaction remains
-- readable and Railroader-specific entry/exit behavior stays isolated from the
-- generation transaction.  It was already evaluated before RV.Server existed, so its event and
-- command registrations are installed now, once the public facade and its
-- transaction queries are available.
local railroaderAdapter = RV.RailroaderServer
if not railroaderAdapter.installWallReload() then
    error("RailroaderRV: wall reload service was not installed")
end
if not railroaderAdapter.installTransactionGate() then
    error("RailroaderRV: Railroader transaction gate was not installed")
end
RV.Server.resolveCurrentUtilityRV = railroaderAdapter.resolveCurrentUtilityRV
if not railroaderAdapter.installTransactionHooks() then
    print("[RailroaderRV] Railroader RV transaction hooks unavailable.")
end


end
