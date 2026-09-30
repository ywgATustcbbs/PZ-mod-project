-- RV_ContextMenu: Relocation responsibilities.
return function(ctx)
local Client = ctx.Client
local C = ctx.C
local MENU_KEY = ctx.MENU_KEY
local COMMAND_RELOCATE = ctx.COMMAND_RELOCATE
local COMMAND_RELOCATE_ACK = ctx.COMMAND_RELOCATE_ACK
local COMMAND_FINAL_RELOCATE = ctx.COMMAND_FINAL_RELOCATE
local COMMAND_FINAL_RELOCATE_ACK = ctx.COMMAND_FINAL_RELOCATE_ACK
local ROOF_REFRESH_HALO_TEXT = ctx.ROOF_REFRESH_HALO_TEXT
local GENERATION_HALO_RENDER_TEXT = ctx.GENERATION_HALO_RENDER_TEXT
local COMMAND_REFRESH_ROOM_OWNERSHIP = ctx.COMMAND_REFRESH_ROOM_OWNERSHIP
local RELOCATION_TIMEOUT_TICKS = ctx.RELOCATION_TIMEOUT_TICKS
local GENERATION_HALO_REFRESH_TICKS = ctx.GENERATION_HALO_REFRESH_TICKS
local validRailroaderFinalHint = ctx.validRailroaderFinalHint
local localPlayerByOnlineId = ctx.localPlayerByOnlineId
local requestRoomOwnershipScan = ctx.requestRoomOwnershipScan
local beginRoomOwnershipRefresh = ctx.beginRoomOwnershipRefresh
local updateRoomOwnershipGuards = ctx.updateRoomOwnershipGuards
local finiteNumber = ctx.finiteNumber
local finiteInteger = ctx.finiteInteger
local pendingFinalRelocation = nil

function Client.requestGenerate(playerObj)
    if not playerObj then return end
    -- Do not add x/y/z (or a precomputed layout) to this payload.  The server
    -- command handler validates the authoritative player state, then selects
    -- the shared fixed target/layout and relocates the player to its server-
    -- selected staging coordinate before generation.
    sendClientCommand(playerObj, C.MOD_ID, C.COMMAND_GENERATE, {})
end

function Client.requestTemplateCapture(playerObj)
    if not playerObj then return end
    sendClientCommand(playerObj, C.MOD_ID,
        C.COMMAND_DUMP_TEMPLATE_CAPTURE, {})
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
        context:addOption("输出当前模板捕获", playerObj,
            Client.requestTemplateCapture)
        if ISWorldObjectContextMenu and ISWorldObjectContextMenu.setTest then
            return ISWorldObjectContextMenu.setTest()
        end
        return true
    end

    context:addOption(getText(MENU_KEY), playerObj, Client.requestGenerate)
    context:addOption("输出当前模板捕获", playerObj,
        Client.requestTemplateCapture)
end

-- The server verifies the authoritative position but cannot see this client's
-- chunk state. This single local readiness proof keeps a client that is still
-- streaming from teleporting to and acknowledging a destination square it has
-- not loaded yet; the server's relocation timeout bounds the wait.
local function destinationSquareIsLoaded(x, y, z)
    local targetX = finiteInteger(x)
    local targetY = finiteInteger(y)
    local targetZ = finiteInteger(z)
    if targetX == nil or targetY == nil or targetZ == nil then
        return false
    end
    local cellCallOk, cell = pcall(getCell)
    if not cellCallOk or not cell then
        return false
    end
    local squareCallOk, square = pcall(function()
        return cell:getGridSquare(targetX, targetY, targetZ)
    end)
    return squareCallOk and square ~= nil
end

local function tryApplyFinalRelocation(args, pending)
    if type(args) ~= "table" then return false end
    if type(pending) ~= "table" or pending.failed then return false end
    local token = args.token
    local onlineId = finiteInteger(args.onlineId)
    local x = finiteNumber(args.x)
    local y = finiteNumber(args.y)
    local z = finiteNumber(args.z)
    if type(token) ~= "string" or token == "" or onlineId == nil
        or x == nil or y == nil or z == nil or z < -32 or z > 31 then
        return false
    end
    local playerObj = localPlayerByOnlineId(onlineId)
    if not playerObj or playerObj:isDead() then
        return false
    end

    if not pending.teleported then
        if not destinationSquareIsLoaded(x, y, z) then
            -- Do not teleport and do not acknowledge while the destination is
            -- still streaming. The request stays pending so the next client
            -- tick re-checks it; no attempt counter or deadline is needed here
            -- because the server owns the relocation timeout.
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
    pendingFinalRelocation = {
        args = args,
        ticks = 0,
        applied = false,
    }
    -- Try in the command callback itself, before the player can enter the
    -- engine update/audio path. If the local player is not available yet,
    -- OnTick retries while the player remains at staging.
    if tryApplyFinalRelocation(args, pendingFinalRelocation) then
        pendingFinalRelocation.applied = true
        if sendFinalRelocationAck(localPlayerByOnlineId(
                finiteInteger(args.onlineId)), args.token) then
            pendingFinalRelocation = nil
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
        .. tostring(args.wallReloadPhase or args.generationPhase or "none")
        .. " onlineId=" .. tostring(args.onlineId)
        .. " target=" .. tostring(args.x) .. "," .. tostring(args.y)
        .. "," .. tostring(args.z))
    local token = args.token
    local onlineId = finiteInteger(args.onlineId)
    -- Staging targets are integer contract points, but a wall reload return must
    -- preserve the server-captured fractional x/y/z exactly.  Validate all
    -- coordinates as finite numbers and use the phase to choose the engine
    -- call below; never round a return coordinate on the client.
    local x = finiteNumber(args.x)
    local y = finiteNumber(args.y)
    local z = finiteNumber(args.z)
    local rvId = args.rvId
    local generation = finiteInteger(args.generation)
    local wallReloadTransition = args.wallReloadTransition == true
    local wallReloadPhase = args.wallReloadPhase
    local generationTransition = args.generationTransition == true
    local generationPhase = args.generationPhase
    if type(token) ~= "string" or token == "" or onlineId == nil
        or rvId == nil or tostring(rvId) == "" or generation == nil
        or generation < 1
        or x == nil or y == nil or z == nil or z < -32 or z > 31 then
        return
    end
    if wallReloadTransition
        and wallReloadPhase ~= "temporary" and wallReloadPhase ~= "return" then
        return
    end
    if not wallReloadTransition and wallReloadPhase ~= nil then
        return
    end
    if generationTransition
        and (generationPhase ~= "temporary" and generationPhase ~= "return"
            or wallReloadTransition) then
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
    if wallReloadTransition and wallReloadPhase == "temporary"
        and type(playerObj.setHaloNote) == "function" then
        pcall(function()
            playerObj:setHaloNote(ROOF_REFRESH_HALO_TEXT, 255, 255, 255, 1500)
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
    -- The wallReload* names below are the existing Relocate wire fields for the
    -- wall reload operation; keep their wire spelling synchronized with the
    -- server.  This is a targeted server instruction, not a client-selected
    -- build coordinate.  Do not inspect the target square here: teleportTo is
    -- the streaming trigger for a remote destination, and the server waits for
    -- its complete footprint before mutating the world.
    local exactReturn = (wallReloadTransition and wallReloadPhase == "return")
        or (generationTransition and generationPhase == "return")
    local teleportX = exactReturn and x or x + 0.5
    local teleportY = exactReturn and y or y + 0.5
    local relocated = pcall(function()
        playerObj:teleportTo(teleportX, teleportY, z)
    end)
    if not relocated then
        print("[RailroaderRVTest] client relocation teleport failed phase="
            .. tostring(wallReloadPhase or generationPhase or "none"))
        return
    end
    -- teleportTo updates coordinates immediately, while IsoMovingObject's
    -- current square is refreshed by a later game update.  Delay the single
    -- applied acknowledgement until OnTick observes that refresh; an immediate
    -- getCurrentSquare() check would still see stale room metadata.
    ctx.pendingRelocation = {
        token = token,
        onlineId = onlineId,
        rvId = tostring(rvId),
        generation = generation,
        x = x,
        y = y,
        z = z,
        wallReloadTransition = wallReloadTransition,
        wallReloadPhase = wallReloadPhase,
        generationTransition = generationTransition,
        generationPhase = generationPhase,
        ticks = 0,
    }
    print("[RailroaderRVTest] client relocation staged phase="
        .. tostring(wallReloadPhase or generationPhase or "none")
        .. " target=" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
end

function Client.onTick()
    ctx.clientTick = ctx.clientTick + 1
    updateRoomOwnershipGuards()
    local finalPending = pendingFinalRelocation
    if finalPending ~= nil then
        finalPending.ticks = finalPending.ticks + 1
        if finalPending.ticks > RELOCATION_TIMEOUT_TICKS then
            -- No failure payload is sent.  The server's current-schema token
            -- deadline owns rollback, so a stale client cannot invent a
            -- failure coordinate or mutate the server-owned transaction.
            pendingFinalRelocation = nil
        else
            if not finalPending.applied then
                finalPending.applied = tryApplyFinalRelocation(
                    finalPending.args, finalPending)
            end
            if finalPending.applied then
                local args = finalPending.args
                local playerObj = localPlayerByOnlineId(finiteInteger(args.onlineId))
                if sendFinalRelocationAck(playerObj, args.token) then
                    pendingFinalRelocation = nil
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
        and (pending.wallReloadTransition or pending.generationTransition)
        and (pending.wallReloadPhase == "temporary"
            or pending.wallReloadPhase == "return"
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
    -- This is the one applied signal the server waits for; the operation has a
    -- single deadline and no client-side retry.
    local ackOk = pcall(function()
        sendClientCommand(playerObj, C.MOD_ID, COMMAND_RELOCATE_ACK,
            { token = pending.token })
    end)
    if ackOk then
        print("[RailroaderRVTest] client relocation ACK sent phase="
            .. tostring(pending.wallReloadPhase or pending.generationPhase or "none"))
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
local railroaderMenuOk, railroaderMenuError = pcall(require, "RailroaderRV/GUI/RV_RailroaderContextMenu")
if not railroaderMenuOk then
    print("[RailroaderRVTest] Railroader RV context menu unavailable: "
        .. tostring(railroaderMenuError))
end

local utilityMenuOk, utilityMenuError = pcall(require,
    "RailroaderRV/GUI/RV_UtilityContextMenu")
if not utilityMenuOk then
    print("[RailroaderRVTest] utility context menu unavailable: "
        .. tostring(utilityMenuError))
end


end
