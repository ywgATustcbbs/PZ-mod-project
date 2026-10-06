-- RV_Server: GenerationAck responsibilities: the two client acknowledgements
-- the generation transaction genuinely waits for, and the single abort path.
return function(ctx)
local Constants = ctx.Constants
local Boundary = ctx.Boundary
local GenerationTransaction = ctx.GenerationTransaction
local WallReload = require("RailroaderRV/WallReloadProtection/RV_WallReloadProtection")
local function safeErrorText(...) return ctx.safeErrorText(...) end
local notifyFailure = ctx.notifyFailure
local playerIdentity = ctx.playerIdentity
local resolvePendingPlayer = ctx.resolvePendingPlayer

local function acknowledgeRelocation(player, args)
    -- A wall reload relocation shares this command name; its own acknowledgement
    -- runs first so it is never mistaken for a generation one.
    local token = type(args) == "table" and args.token or nil
    local wallHandled, wallAccepted, wallReason = WallReload.acknowledge(player,
        token)
    if wallHandled then
        return wallAccepted, wallReason
    end
    local record = GenerationTransaction.current()
    if record == nil then
        return false, "no generation relocation is waiting for an acknowledgement"
    end
    if record.stage ~= "WAIT_STAGING" then
        return false, Constants.INVALID_RV_DATA
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk or identityOrReason.key ~= record.identity.key then
        return false, identityOk and "acknowledgement sender does not own the request"
            or identityOrReason
    end
    record.player = player
    record.stagingAcked = true
    -- The client only acknowledges after it has settled its current square, so
    -- this grant replaces the staging wait budget with the build wait budget.
    record.deadlineTick = ctx.serverTick
        + ctx.RELOCATION_TIMEOUT_TICKS
    return true
end

-- FinalRelocate has its own acknowledgement namespace.  The payload is
-- deliberately only the opaque token; every RV identity, destination and
-- room/guard fact is re-read from the server-owned in-memory record.
local function acknowledgeFinalRelocation(player, args)
    local record = GenerationTransaction.current()
    if record == nil or record.stage ~= "WAIT_FINAL" then
        return false, "no final relocation is waiting for an acknowledgement"
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk or identityOrReason.key ~= record.identity.key then
        return false, identityOk and "final acknowledgement sender does not own the request"
            or identityOrReason
    end
    local resolved, livePlayerOrReason = resolvePendingPlayer(record)
    if not resolved then return false, livePlayerOrReason end
    -- The client ACK only closes its asynchronous teleport action. Its Player
    -- packet can arrive before the server's player object reflects the new
    -- position, so the ACK must not be rejected on that transient position.
    -- finalizeGenerationAfterRelocate performs the authoritative position
    -- proof on OnTick and reasserts this server-selected target if needed.
    record.player = livePlayerOrReason
    record.finalAcked = true
    return true
end

-- The one abort path. A failed build leaves its world changes in place; the
-- next request has no published mapping and starts with a full clear pass.
-- Return the owner if it is still online, close the boundary lease and let the
-- player press the button again. Nothing here retries or defers.
local function abortGeneration(record, reason)
    local reasonText = safeErrorText(reason)
    print("[RailroaderRV] generation aborted identity="
        .. tostring(record.identity.key)
        .. " stage=" .. tostring(record.stage) .. " generation="
        .. tostring(record.generation) .. " reason=" .. reasonText)
    local resolved, livePlayerOrReason = resolvePendingPlayer(record)
    local livePlayer = resolved and livePlayerOrReason or record.player
    record.player = livePlayer
    if livePlayer ~= nil then
        local returned, returnReason = ctx.sendStagingRelocation(record, "return")
        if not returned then
            print("[RailroaderRV] generation return relocation failed: "
                .. safeErrorText(returnReason))
        end
    end
    if livePlayer ~= nil then
        Boundary.completeTransition(livePlayer, record.token)
    end
    if livePlayer ~= nil and record.railroader ~= nil then
        ctx.railroaderFailureHook(livePlayer, record.railroader, reason, record)
    end
    if type(reason) == "string"
        and string.find(reason, Constants.INVALID_RV_DATA, 1, true) then
        notifyFailure(livePlayer, reason)
    end
    GenerationTransaction.release()
end

ctx.acknowledgeRelocation = acknowledgeRelocation
ctx.acknowledgeFinalRelocation = acknowledgeFinalRelocation
ctx.abortGeneration = abortGeneration
end
