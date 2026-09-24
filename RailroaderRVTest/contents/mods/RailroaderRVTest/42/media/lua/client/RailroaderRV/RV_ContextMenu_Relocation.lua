-- RV_ContextMenu: Relocation responsibilities.
return function(ctx)
local Client = ctx.Client
local C = ctx.C
local MENU_KEY = ctx.MENU_KEY
local COMMAND_RELOCATE = ctx.COMMAND_RELOCATE
local COMMAND_RELOCATE_ACK = ctx.COMMAND_RELOCATE_ACK
local COMMAND_FINAL_RELOCATE = ctx.COMMAND_FINAL_RELOCATE
local COMMAND_FINAL_RELOCATE_ACK = ctx.COMMAND_FINAL_RELOCATE_ACK
local ROOF_REPAIR_HALO_TEXT = ctx.ROOF_REPAIR_HALO_TEXT
local GENERATION_HALO_RENDER_TEXT = ctx.GENERATION_HALO_RENDER_TEXT
local COMMAND_REFRESH_ROOM_OWNERSHIP = ctx.COMMAND_REFRESH_ROOM_OWNERSHIP
local roomOwnershipGuards = ctx.roomOwnershipGuards
local RELOCATION_TIMEOUT_TICKS = ctx.RELOCATION_TIMEOUT_TICKS
local GENERATION_HALO_REFRESH_TICKS = ctx.GENERATION_HALO_REFRESH_TICKS
local roomOwnershipGuardKey = ctx.roomOwnershipGuardKey
local validRailroaderFinalHint = ctx.validRailroaderFinalHint
local localPlayerByOnlineId = ctx.localPlayerByOnlineId
local refreshInvalidRoomOwnership = ctx.refreshInvalidRoomOwnership
local requestRoomOwnershipScan = ctx.requestRoomOwnershipScan
local beginRoomOwnershipRefresh = ctx.beginRoomOwnershipRefresh
local finalTargetSquareIsLoaded = ctx.finalTargetSquareIsLoaded
local finalTargetRoomIsValid = ctx.finalTargetRoomIsValid
local updateRoomOwnershipGuards = ctx.updateRoomOwnershipGuards
local finiteNumber = ctx.finiteNumber
local finiteInteger = ctx.finiteInteger
local FINAL_RELOCATION_SCAN_RETRY_TICKS = 10
local FINAL_RELOCATION_SCAN_MAX_ATTEMPTS = 4

function Client.requestGenerate(playerObj)
    if not playerObj then return end
    -- Do not add x/y/z (or a precomputed layout) to this payload.  The server
    -- command handler validates the authoritative player state, then selects
    -- the shared fixed target/layout and relocates the player to its server-
    -- selected staging coordinate before generation.
    sendClientCommand(playerObj, C.MOD_ID, C.COMMAND_GENERATE, {})
end

function Client.onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or playerObj:isDead() then return end
    if not context then return end

    -- Controller/menu discovery invokes this callback with test=true first.
    -- Mark the menu as having an option, but do not send a command during the
    -- discovery pass.
    if test then
        context:addOption(getText(MENU_KEY), playerObj, Client.requestGenerate)
        if ISWorldObjectContextMenu and ISWorldObjectContextMenu.setTest then
            return ISWorldObjectContextMenu.setTest()
        end
        return true
    end

    context:addOption(getText(MENU_KEY), playerObj, Client.requestGenerate)
end

local function tryFinalRelocationGuardScan(guard, pending, phase)
    local completeKey = phase .. "ScanComplete"
    if pending[completeKey] then return true end
    if pending.failed then return false end

    local attemptsKey = phase .. "ScanAttempts"
    local nextTickKey = phase .. "NextScanTick"
    if ctx.clientTick < (pending[nextTickKey] or 0) then
        return false
    end

    pending[attemptsKey] = (pending[attemptsKey] or 0) + 1
    local scanCallOk, scanOk = pcall(refreshInvalidRoomOwnership, guard)
    if scanCallOk and scanOk == true then
        pending[completeKey] = true
        return true
    end

    if pending[attemptsKey] >= FINAL_RELOCATION_SCAN_MAX_ATTEMPTS then
        -- Never teleport or acknowledge a transaction whose footprint was
        -- only partially loaded. A later matching object/local repair trigger
        -- can open one new bounded window; otherwise the server token deadline
        -- owns rollback.
        pending.failed = true
        pending.failedPhase = phase
        print("[RailroaderRVTest] final relocation " .. phase
            .. " room scan incomplete after " .. tostring(pending[attemptsKey])
            .. " attempts; final ACK blocked until a matching repair trigger")
    else
        pending[nextTickKey] = ctx.clientTick
            + FINAL_RELOCATION_SCAN_RETRY_TICKS
    end
    return false
end

local function tryApplyFinalRelocation(args, pending)
    if type(args) ~= "table" then return false end
    if type(pending) ~= "table" or pending.failed then return false end
    local token = args.token
    local rvId = args.rvId
    local generation = finiteInteger(args.generation)
    local bitmapVersion = finiteInteger(args.bitmapVersion)
    local onlineId = finiteInteger(args.onlineId)
    local x = finiteNumber(args.x)
    local y = finiteNumber(args.y)
    local z = finiteNumber(args.z)
    if type(token) ~= "string" or token == "" or rvId == nil
        or tostring(rvId) == "" or generation == nil or generation < 1
        or bitmapVersion ~= C.BITMAP_VERSION or onlineId == nil
        or x == nil or y == nil or z == nil or z < -32 or z > 31 then
        return false
    end
    local guard = roomOwnershipGuards[roomOwnershipGuardKey(
        rvId, generation, bitmapVersion)]
    if guard == nil or tostring(guard.rvId) ~= tostring(rvId)
        or guard.bitmapVersion ~= bitmapVersion then
        return false
    end
    -- A persistent current-square API failure is latched by the guard monitor.
    -- Do not complete a final relocation transaction until a later local check
    -- succeeds and clears that uncertainty.
    if guard.currentCheckErrorLatched == true then
        return false
    end
    local playerObj = localPlayerByOnlineId(onlineId)
    if not playerObj or playerObj:isDead() then
        return false
    end

    -- Wait for the selected destination square before the transaction scan.
    -- While streaming is incomplete, OnTick performs only this O(1) lookup.
    if not pending.teleported then
        if not finalTargetSquareIsLoaded(x, y, z) then
            return false
        end
        -- Full pre-scan happens only after the destination is ready. If any
        -- footprint square is still unloaded, retry at a bounded interval.
        if not tryFinalRelocationGuardScan(guard, pending, "pre") then
            return false
        end
        if not finalTargetRoomIsValid(x, y, z) then
            return false
        end
        local teleported, teleportResult = pcall(function()
            return playerObj:teleportTo(x, y, z)
        end)
        if not teleported or teleportResult == false then
            pending.failed = true
            return false
        end
        pending.teleported = true
        -- IsoGameCharacter:teleportTo(float,float,int) floors x/y in B42.20.
        -- Restore the server-selected half-cell center with the official
        -- setters before checking the transaction's post-move proof.
        local exactCallOk = pcall(function()
            playerObj:setX(x)
            playerObj:setY(y)
            playerObj:setZ(z)
            playerObj:setLastX(x)
            playerObj:setLastY(y)
        end)
        if not exactCallOk then
            pending.failed = true
            return false
        end
        if type(playerObj.setCurrentSquareFromPosition) == "function" then
            -- teleportTo updates coordinates only. Use the official three-
            -- argument IsoMovingObject overload to refresh the client cache.
            pcall(function() playerObj:setCurrentSquareFromPosition(x, y, z) end)
        end
    end

    local xOk, currentX = pcall(function() return playerObj:getX() end)
    local yOk, currentY = pcall(function() return playerObj:getY() end)
    local zOk, currentZ = pcall(function() return playerObj:getZ() end)
    if not xOk or not yOk or not zOk
        or finiteNumber(currentX) ~= x
        or finiteNumber(currentY) ~= y
        or finiteNumber(currentZ) ~= z then
        return false
    end

    -- The post-scan is a separate transaction stage and is never repeated on
    -- every wait tick. Incomplete coverage retries at a bounded interval; no
    -- final ACK is sent until the full footprint and target room both verify.
    if not pending.postScanComplete then
        if not finalTargetSquareIsLoaded(x, y, z)
            or not tryFinalRelocationGuardScan(guard, pending, "post") then
            return false
        end
    end
    if not finalTargetRoomIsValid(x, y, z) then
        return false
    end
    return true
end

local function sendFinalRelocationAck(playerObj, token)
    if not playerObj or type(token) ~= "string" or token == "" then
        return false
    end
    local ok = pcall(sendClientCommand, playerObj, C.MOD_ID,
        COMMAND_FINAL_RELOCATE_ACK, { token = token })
    return ok
end

local function applyFinalRelocation(args)
    -- This is a distinct server-selected entry command.  Its completion uses a
    -- separate strict token-only ACK, so the initial relocation ACK cannot be
    -- mixed into this move.
    ctx.pendingRelocation = nil
    ctx.pendingFinalRelocation = {
        args = args,
        ticks = 0,
        applied = false,
    }
    -- Try in the command callback itself, before the player can enter the
    -- engine update/audio path. If the guard packet has not been installed yet,
    -- OnTick retries while the player remains at staging.
    if tryApplyFinalRelocation(args, ctx.pendingFinalRelocation) then
        ctx.pendingFinalRelocation.applied = true
        if sendFinalRelocationAck(localPlayerByOnlineId(
                finiteInteger(args.onlineId)), args.token) then
            ctx.pendingFinalRelocation = nil
        end
    end
end

function Client.onServerCommand(module, command, args)
    if module ~= C.MOD_ID or args == nil then
        return
    end
    if command == COMMAND_REFRESH_ROOM_OWNERSHIP then
        beginRoomOwnershipRefresh(args)
        return
    end
    if command == COMMAND_FINAL_RELOCATE then
        -- Only a server-marked Railroader generation may touch Ride state.
        -- Ordinary technical Generate still uses this generic final teleport,
        -- but must not dismount a locomotive the player happens to occupy.
        local rv = rawget(_G, "RailroaderRV")
        local railroaderMenu = rv and rv.RailroaderContextMenu
        local marked = validRailroaderFinalHint(args)
        if marked and railroaderMenu
            and type(railroaderMenu.prepareGenerationRelocation) == "function" then
            local preparedOk, prepared = pcall(
                railroaderMenu.prepareGenerationRelocation, args)
            if not preparedOk or prepared ~= true then return end
        end
        applyFinalRelocation(args)
        return
    end
    if command ~= COMMAND_RELOCATE then return end
    print("[RailroaderRVTest] client relocation command received phase="
        .. tostring(args.roofRepairPhase or args.generationPhase or "none")
        .. " onlineId=" .. tostring(args.onlineId)
        .. " target=" .. tostring(args.x) .. "," .. tostring(args.y)
        .. "," .. tostring(args.z))
    local token = args.token
    local onlineId = finiteInteger(args.onlineId)
    -- Staging targets are integer contract points, but a grouped return must
    -- preserve the server-captured fractional x/y/z exactly.  Validate all
    -- coordinates as finite numbers and use the phase to choose the engine
    -- call below; never round a return coordinate on the client.
    local x = finiteNumber(args.x)
    local y = finiteNumber(args.y)
    local z = finiteNumber(args.z)
    local rvId = args.rvId
    local generation = finiteInteger(args.generation)
    local bitmapVersion = finiteInteger(args.bitmapVersion)
    local roofRepairTransition = args.roofRepairTransition == true
    local roofRepairPhase = args.roofRepairPhase
    local generationTransition = args.generationTransition == true
    local generationPhase = args.generationPhase
    if type(token) ~= "string" or token == "" or onlineId == nil
        or rvId == nil or tostring(rvId) == "" or generation == nil
        or generation < 1 or bitmapVersion ~= C.BITMAP_VERSION
        or x == nil or y == nil or z == nil or z < -32 or z > 31 then
        return
    end
    if roofRepairTransition
        and roofRepairPhase ~= "temporary" and roofRepairPhase ~= "return" then
        return
    end
    if not roofRepairTransition and roofRepairPhase ~= nil then
        return
    end
    if generationTransition
        and (generationPhase ~= "temporary" and generationPhase ~= "return"
            or roofRepairTransition) then
        return
    end
    if not generationTransition and generationPhase ~= nil then
        return
    end
    local playerObj = localPlayerByOnlineId(onlineId)
    if not playerObj or playerObj:isDead() then
        print("[RailroaderRVTest] client relocation command ignored: local player unavailable")
        return
    end
    if roofRepairTransition and roofRepairPhase == "temporary"
        and type(playerObj.setHaloNote) == "function" then
        pcall(function()
            playerObj:setHaloNote(ROOF_REPAIR_HALO_TEXT, 255, 255, 255, 1500)
        end)
    end
    if generationTransition and generationPhase == "temporary"
        and type(playerObj.setHaloNote) == "function" then
        -- The Chinese text is a client-local constant.  The server sends only
        -- the strict phase marker, so network encoding cannot become rendered
        -- UI text and cannot be spoofed by an arbitrary payload.
        pcall(function()
            playerObj:setHaloNote(GENERATION_HALO_RENDER_TEXT,
                255, 255, 255, 1500)
        end)
    end
    -- Railroader generation removes the official seat before this staging
    -- teleport.  Clear the local Ride state first, but only for the strict
    -- server-created marker; ordinary technical Generate must keep this
    -- bridge completely Railroader-agnostic.
    if args.railroaderTransition == true then
        local rv = rawget(_G, "RailroaderRV")
        local railroaderMenu = rv and rv.RailroaderContextMenu
        if railroaderMenu
            and type(railroaderMenu.prepareGenerationStaging) == "function" then
            local preparedOk, prepared = pcall(
                railroaderMenu.prepareGenerationStaging, args)
            if not preparedOk or prepared ~= true then return end
        else
            -- Do not acknowledge a Railroader staging move if its Ride
            -- transition hook was not loaded; the server will cancel safely.
            return
        end
    end
    -- This is a targeted server instruction, not a client-selected build
    -- coordinate.  Do not inspect the target square here: teleportTo is the
    -- streaming trigger for a remote destination, and the server waits for
    -- its complete footprint before mutating the world.
    local exactReturn = (roofRepairTransition and roofRepairPhase == "return")
        or (generationTransition and generationPhase == "return")
    local teleportX = exactReturn and x or x + 0.5
    local teleportY = exactReturn and y or y + 0.5
    local relocated = pcall(function()
        playerObj:teleportTo(teleportX, teleportY, z)
    end)
    if not relocated then
        print("[RailroaderRVTest] client relocation teleport failed phase="
            .. tostring(roofRepairPhase or generationPhase or "none"))
        return
    end
    -- teleportTo updates coordinates immediately, while IsoMovingObject's
    -- current square is refreshed by a later game update.  Delay the ack
    -- until OnTick observes that refresh; an immediate getCurrentSquare()
    -- check would still see the room that is about to be rebuilt.
    ctx.pendingRelocation = {
        token = token,
        onlineId = onlineId,
        rvId = tostring(rvId),
        generation = generation,
        bitmapVersion = bitmapVersion,
        x = x,
        y = y,
        z = z,
        roofRepairTransition = roofRepairTransition,
        roofRepairPhase = roofRepairPhase,
        generationTransition = generationTransition,
        generationPhase = generationPhase,
        ticks = 0,
        ackAttemptLogged = false,
    }
    print("[RailroaderRVTest] client relocation staged phase="
        .. tostring(roofRepairPhase or generationPhase or "none")
        .. " target=" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
end

function Client.onTick()
    ctx.clientTick = ctx.clientTick + 1
    updateRoomOwnershipGuards()
    local finalPending = ctx.pendingFinalRelocation
    if finalPending ~= nil then
        finalPending.ticks = finalPending.ticks + 1
        if finalPending.ticks > RELOCATION_TIMEOUT_TICKS then
            -- No failure payload is sent.  The server's current-schema token
            -- deadline owns rollback, so a stale client cannot invent a
            -- failure coordinate or mutate the server-owned transaction.
            ctx.pendingFinalRelocation = nil
        else
            if not finalPending.applied then
                finalPending.applied = tryApplyFinalRelocation(
                    finalPending.args, finalPending)
            end
            if finalPending.applied then
                local args = finalPending.args
                local playerObj = localPlayerByOnlineId(finiteInteger(args.onlineId))
                if sendFinalRelocationAck(playerObj, args.token) then
                    ctx.pendingFinalRelocation = nil
                end
            end
        end
    end
    local pending = ctx.pendingRelocation
    if pending == nil then
        return
    end
    pending.ticks = pending.ticks + 1
    if pending.ticks > RELOCATION_TIMEOUT_TICKS then
        ctx.pendingRelocation = nil
        return
    end
    local playerObj = localPlayerByOnlineId(pending.onlineId)
    if not playerObj or playerObj:isDead() then
        ctx.pendingRelocation = nil
        return
    end
    if pending.generationTransition and pending.generationPhase == "temporary"
        and type(playerObj.setHaloNote) == "function"
        and pending.ticks % GENERATION_HALO_REFRESH_TICKS == 0 then
        -- Keep the local-only generation status visible for the whole
        -- temporary phase, including a reconnect/rebound command.  The
        -- server payload contains only the phase marker, never UI text.
        pcall(function()
            playerObj:setHaloNote(GENERATION_HALO_RENDER_TEXT,
                255, 255, 255, 1500)
        end)
    end
    local current = playerObj:getCurrentSquare()
    local currentMatches = current
        and current:getX() == math.floor(pending.x)
        and current:getY() == math.floor(pending.y)
        and current:getZ() == math.floor(pending.z)
    if not currentMatches
        and (pending.roofRepairTransition or pending.generationTransition)
        and (pending.roofRepairPhase == "temporary"
            or pending.roofRepairPhase == "return"
            or pending.generationPhase == "temporary"
            or pending.generationPhase == "return")
        and pending.ticks >= 3 then
        -- A cross-chunk return can be visible at the exact server-selected
        -- coordinate before the original chunk's client GridSquare is
        -- rebound.  This acknowledgement only reports that the server
        -- command was applied; the server still re-reads authoritative
        -- x/y/z, identity and schema context before advancing the phase.
        local xOk, currentX = pcall(function() return playerObj:getX() end)
        local yOk, currentY = pcall(function() return playerObj:getY() end)
        local zOk, currentZ = pcall(function() return playerObj:getZ() end)
        local numericX = finiteNumber(currentX)
        local numericY = finiteNumber(currentY)
        local numericZ = finiteNumber(currentZ)
        currentMatches = xOk and yOk and zOk
            and numericX ~= nil and numericY ~= nil and numericZ ~= nil
            and math.floor(numericX) == math.floor(pending.x)
            and math.floor(numericY) == math.floor(pending.y)
            and math.floor(numericZ) == math.floor(pending.z)
    end
    if not currentMatches then
        return
    end
    -- The destination is intentionally cleaned of floors by the server, so a
    -- missing floor is not a client-side reason to discard the relocation ack.
    if pending.ackAttemptLogged ~= true then
        print("[RailroaderRVTest] client relocation ACK sending phase="
            .. tostring(pending.roofRepairPhase or pending.generationPhase or "none")
            .. " target=" .. tostring(pending.x) .. "," .. tostring(pending.y)
            .. "," .. tostring(pending.z) .. " coordinateProof="
            .. tostring(currentMatches))
        pending.ackAttemptLogged = true
    end
    local ackOk = pcall(function()
        sendClientCommand(playerObj, C.MOD_ID, COMMAND_RELOCATE_ACK,
            { token = pending.token })
    end)
    if ackOk then
        print("[RailroaderRVTest] client relocation ACK sent phase="
            .. tostring(pending.roofRepairPhase or pending.generationPhase or "none"))
        ctx.pendingRelocation = nil
    end
end

Events.OnServerCommand.Add(Client.onServerCommand)
Events.OnTick.Add(Client.onTick)
if Events.OnObjectAdded and type(Events.OnObjectAdded.Add) == "function" then
    Events.OnObjectAdded.Add(requestRoomOwnershipScan)
end
if Events.OnObjectAboutToBeRemoved
    and type(Events.OnObjectAboutToBeRemoved.Add) == "function" then
    Events.OnObjectAboutToBeRemoved.Add(requestRoomOwnershipScan)
end
-- Events.OnFillWorldObjectContextMenu is registered by
-- RV_RailroaderContextMenu after this relocation bridge loads.

-- The technical Generate button remains a separate helper,
-- but the live world/animal menu is owned by the Railroader adapter.  Loading it
-- here guarantees RV_Server/RV_ContextMenu can keep their existing relocation
-- handshake while the new menu remains a separate, bounded module.
local railroaderMenuOk, railroaderMenuError = pcall(require, "RailroaderRV/RV_RailroaderContextMenu")
if not railroaderMenuOk then
    print("[RailroaderRVTest] Railroader RV context menu unavailable: "
        .. tostring(railroaderMenuError))
end

local utilityMenuOk, utilityMenuError = pcall(require,
    "RailroaderRV/RV_UtilityContextMenu")
if not utilityMenuOk then
    print("[RailroaderRVTest] utility context menu unavailable: "
        .. tostring(utilityMenuError))
end


end
