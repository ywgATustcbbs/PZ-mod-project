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
local ServerWorld = ctx.ServerWorld
local Boundary = ctx.Boundary
local RV = ctx.RV
local ServerSchema = ctx.ServerSchema
local UtilityServer = ctx.UtilityServer
local GenerationTransaction = ctx.GenerationTransaction
local WallReload = require("RailroaderRV/WallReloadProtection/RV_WallReloadProtection")
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
local TemplateDevelopment = require(
    "RailroaderRV/TemplateDevelopment/RV_Server_TemplateDevelopment")(ctx)
local FlatcarVisual = require(
    "RailroaderRV/CarVisual/RV_FlatcarVisualServer")({
        C = Constants,
        ClientDispatch = ctx.ClientDispatch,
        ServerWorld = ServerWorld,
        validateAuthoritativePlayer = validateAuthoritativePlayer,
    })
local flatcarNoticeReasons = {
    [Constants.RV_FLATCAR_NOTICE_DECK_FULL] = true,
    [Constants.RV_FLATCAR_NOTICE_BOUND_RV_CANNOT_CONVERT] = true,
    [Constants.RV_FLATCAR_NOTICE_SOURCE_NOT_FOUND] = true,
    [Constants.RV_FLATCAR_NOTICE_SOURCE_OUT_OF_RANGE] = true,
    [Constants.RV_FLATCAR_NOTICE_SOURCE_OCCUPIED] = true,
    [Constants.RV_FLATCAR_NOTICE_SOURCE_TOWING] = true,
    [Constants.RV_FLATCAR_NOTICE_CARGO_NOT_FOUND] = true,
    [Constants.RV_FLATCAR_NOTICE_UNLOAD_BLOCKED] = true,
    [Constants.RV_FLATCAR_NOTICE_LOADING_RAMP_REQUIRED] = true,
}

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
local function logStagingAbortDiagnostic(record, reason)
    if record.stage ~= "WAIT_STAGING" then return end

    local resolved, playerOrReason = resolvePendingPlayer(record)
    local player = resolved and playerOrReason or nil
    local actualPosition = player ~= nil
        and (tostring(player:getX()) .. "," .. tostring(player:getY()) .. ","
            .. tostring(player:getZ())) or "unavailable"
    local stagingProof = "skipped"
    local stagingReason = resolved and "not evaluated" or safeErrorText(playerOrReason)
    local targetAreaStatus = "skipped"
    local targetAreaReason = resolved and "not evaluated" or safeErrorText(playerOrReason)
    if player ~= nil then
        local atStaging, stagingProofReason = playerIsAtStagingDestination(
            player, record.stagingDestination, record.bounds)
        stagingProof = atStaging and "passed" or "failed"
        stagingReason = stagingProofReason == nil and "matched"
            or safeErrorText(stagingProofReason)

        local targetLoaded, targetLoadReason = ServerSchema.targetAreaLoadStatus(
            player, record.bounds, safeErrorText)
        targetAreaStatus = targetLoaded == true and "loaded"
            or targetLoaded == false and "not-loaded" or "error"
        targetAreaReason = targetLoadReason == nil and "none"
            or safeErrorText(targetLoadReason)
    end

    local target = record.stagingDestination
    print("[RailroaderRV][Diag] server event=generation_abort"
        .. " token=" .. tostring(record.token)
        .. " generation=" .. tostring(record.generation)
        .. " stage=" .. tostring(record.stage)
        .. " stagingAcked=" .. tostring(record.stagingAcked)
        .. " resolve=" .. (resolved and "ok" or "failed")
        .. " resolveReason=" .. (resolved and "none" or safeErrorText(playerOrReason))
        .. " actual=" .. actualPosition
        .. " target=" .. tostring(target.x) .. "," .. tostring(target.y)
        .. "," .. tostring(target.z)
        .. " stagingProof=" .. stagingProof
        .. " stagingReason=" .. stagingReason
        .. " targetArea=" .. targetAreaStatus
        .. " targetAreaReason=" .. targetAreaReason
        .. " abortReason=" .. safeErrorText(reason))
end

local function runGenerationAbort(record, reason)
    if record == nil then return end
    logStagingAbortDiagnostic(record, reason)
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
    if command == Constants.COMMAND_RV_TEMPLATE_DEVELOPMENT then
        local accepted, reason = TemplateDevelopment.handle(player, args)
        if accepted ~= true then
            print("[RailroaderRV][TemplateDevelopment] rejected operation="
                .. tostring(args.operation)
                .. " reason=" .. safeErrorText(reason))
        end
        return
    end
    if command == Constants.COMMAND_RV_FLATCAR then
        local accepted, reason = FlatcarVisual.handle(player, args)
        if accepted ~= true then
            print("[RailroaderRV][FlatcarVisual] rejected reason="
                .. safeErrorText(reason))
            if flatcarNoticeReasons[reason] then
                ctx.ClientDispatch.sendToPlayer(player, Constants.MOD_ID,
                    Constants.COMMAND_RV_FLATCAR_NOTICE, {
                        reason = reason,
                        onlineId = player:getOnlineID(),
                    })
            end
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
        local accepted, reason = TemplateDevelopment.handle(player, {
            operation = "save", kind = "loco",
        })
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
        local waitingRecord = GenerationTransaction.current()
        local waitingForStaging = waitingRecord ~= nil
            and waitingRecord.stage == "WAIT_STAGING"
        local ackToken = type(args) == "table" and args.token or nil
        local accepted, reason = acknowledgeRelocation(player, args)
        if waitingForStaging then
            print("[RailroaderRV][Diag] server event=staging_ack token="
                .. tostring(ackToken) .. " generation="
                .. tostring(waitingRecord.generation) .. " phase=staging"
                .. " accepted=" .. tostring(accepted == true)
                .. " reason=" .. (accepted == true and "none"
                    or safeErrorText(reason)))
        end
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
railroaderAdapter.installWallReload()
railroaderAdapter.installTransactionGate()
RV.Server.resolveCurrentUtilityRV = railroaderAdapter.resolveCurrentUtilityRV
if not railroaderAdapter.installTransactionHooks() then
    print("[RailroaderRV] Railroader RV transaction hooks unavailable.")
end


end
