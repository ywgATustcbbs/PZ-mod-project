-- Client-only entry point for the technical test.
--
-- The menu is intentionally ordinary (world right-click).  The client sends
-- only the command name; the server validates the player's current state from
-- its authoritative player object and selects both the fixed generation anchor
-- and a safe staging coordinate outside the old/new structure footprints.

require "RailroaderRV/RV_Constants"
local boundaryClientLoaded, BoundaryClient = pcall(require,
    "RailroaderRV/RV_BoundaryClient")
if not boundaryClientLoaded then
    print("[RailroaderRVTest] RV boundary client unavailable: "
        .. tostring(BoundaryClient))
end

RailroaderRV = RailroaderRV or {}
RailroaderRV.Client = RailroaderRV.Client or {}

local Client = RailroaderRV.Client
local C = RailroaderRV.Constants
local MENU_KEY = "ContextMenu_RailroaderRVTest_Generate"
local COMMAND_RELOCATE = "Relocate"
local COMMAND_RELOCATE_ACK = "RelocateAck"
local COMMAND_FINAL_RELOCATE = C.COMMAND_FINAL_RELOCATE or "FinalRelocate"
local ROOF_REPAIR_HALO_TEXT = "Refreshing room"
local COMMAND_REFRESH_ROOM_OWNERSHIP = C.COMMAND_REFRESH_ROOM_OWNERSHIP
    or "RefreshRoomOwnership"
local pendingRelocation = nil
local pendingFinalRelocation = nil
local roomOwnershipGuards = {}
local RELOCATION_TIMEOUT_TICKS = 600
-- IsoRegions has no public Lua completion event.  The initial generation
-- guard is also the only server-authoritative identity/bounds packet a client
-- receives for this footprint, so it must remain armed after the generation
-- transaction.  A later wall/floor removal can cause another asynchronous
-- region packet to retire the same IsoRoom; releasing the guard after a quiet
-- tail leaves that packet unchecked and exposes ParameterFirearmRoomSize to a
-- RoomDef=nil reference on the next player update.
local ROOM_OWNERSHIP_MIN_TICKS = 1800
local ROOM_OWNERSHIP_STABLE_TICKS = 120

local function roomOwnershipGuardKey(rvId, generation, bitmapVersion)
    return tostring(rvId) .. ":" .. tostring(generation) .. ":"
        .. tostring(bitmapVersion)
end

local function finiteInteger(value)
    local valueType = type(value)
    local number
    if valueType == "number" then
        number = value
    elseif valueType == "string" then
        number = tonumber(value)
    elseif value ~= nil then
        -- Network table numbers may be Java Double values.  Passing those to
        -- Kahlua's tonumber can select its String/radix overload, while the
        -- guarded arithmetic conversion preserves the numeric value.
        local converted, numeric = pcall(function()
            return value + 0
        end)
        if converted and type(numeric) == "number" then
            number = numeric
        end
    end
    if type(number) ~= "number" or number ~= number or number == math.huge
        or number == -math.huge or math.floor(number) ~= number then
        return nil
    end
    return number
end

local function finiteNumber(value)
    local valueType = type(value)
    local number
    if valueType == "number" then
        number = value
    elseif valueType == "string" then
        number = tonumber(value)
    elseif value ~= nil then
        local converted, numeric = pcall(function()
            return value + 0
        end)
        if converted and type(numeric) == "number" then
            number = numeric
        end
    end
    if type(number) ~= "number" or number ~= number
        or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

local function validRailroaderFinalHint(args)
    local generation = type(args) == "table" and finiteInteger(args.generation)
    local bitmapVersion = type(args) == "table"
        and finiteInteger(args.bitmapVersion)
    return type(args) == "table" and args.railroaderTransition == true
        and type(args.token) == "string" and args.token ~= ""
        and args.locoId ~= nil and tostring(args.locoId) ~= ""
        and args.rvId ~= nil and tostring(args.rvId) ~= ""
        and generation ~= nil and generation >= 1
        and bitmapVersion == C.BITMAP_VERSION
end

local function localPlayerByOnlineId(onlineId)
    local count = getNumActivePlayers()
    for playerNum = 0, count - 1 do
        local playerObj = getSpecificPlayer(playerNum)
        if playerObj and finiteInteger(playerObj:getOnlineID()) == onlineId then
            return playerObj
        end
    end
    return nil
end

local function readRoomRefreshBounds(args, prefix)
    local fields = {
        "wallMinX", "wallMaxX", "wallMinY", "wallMaxY",
        "roomMinX", "roomMaxX", "roomMinY", "roomMaxY",
        "roofMinX", "roofMaxX", "roofMinY", "roofMaxY", "z", "roofZ",
    }
    local bounds = {}
    for i = 1, #fields do
        local field = fields[i]
        local value = finiteInteger(args[prefix .. field])
        if value == nil then
            return nil
        end
        bounds[field] = value
    end
    if bounds.wallMinX > bounds.wallMaxX or bounds.wallMinY > bounds.wallMaxY
        or bounds.roomMinX > bounds.roomMaxX or bounds.roomMinY > bounds.roomMaxY
        or bounds.roofMinX > bounds.roofMaxX or bounds.roofMinY > bounds.roofMaxY
        or bounds.wallMaxX - bounds.wallMinX + 1 ~= 7
        or bounds.wallMaxY - bounds.wallMinY + 1 ~= 41
        or bounds.roomMaxX - bounds.roomMinX + 1 ~= 6
        or bounds.roomMaxY - bounds.roomMinY + 1 ~= 40
        or bounds.roomMinX < bounds.wallMinX
        or bounds.roomMaxX > bounds.wallMaxX
        or bounds.roomMinY < bounds.wallMinY
        or bounds.roomMaxY > bounds.wallMaxY
        or bounds.roofMaxX - bounds.roofMinX + 1 ~= 6
        or bounds.roofMaxY - bounds.roofMinY + 1 ~= 40
        or bounds.z < -32 or bounds.z > 31
        or bounds.roofZ < -32 or bounds.roofZ > 31
        or bounds.roofZ ~= bounds.z + 1 then
        return nil
    end
    return bounds
end

local function eachStructureSquare(cell, bounds, callback)
    if not cell or not bounds then
        return
    end
    local function visit(x, y, z)
        local square = cell:getGridSquare(x, y, z)
        if square then callback(square, x, y, z) end
    end
    for x = bounds.wallMinX, bounds.wallMaxX do
        for y = bounds.wallMinY, bounds.wallMaxY do
            visit(x, y, bounds.z)
        end
    end
    -- The complete 7x41 wall rectangle already contains the 6x40 interior.
    -- Do not revisit that same base area through a redundant room loop.
    for x = bounds.roofMinX, bounds.roofMaxX do
        for y = bounds.roofMinY, bounds.roofMaxY do
            visit(x, y, bounds.roofZ)
        end
    end
end

local function refreshInvalidRoomOwnership(guard)
    local cell = getCell()
    if not cell then return false, 0 end
    local scanOk = true
    local cleared = 0
    local seen = {}
    local function inspect(square, x, y, z)
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if seen[key] then return end
        seen[key] = true
        local room = square:getRoom()
        if room == nil then return end
        local inspected, roomDef = pcall(function()
            return square:getRoomDef()
        end)
        if not inspected then
            scanOk = false
            return
        end
        -- Correct only the impossible state left by removeIsoRoom. Valid
        -- retired or replacement rooms must retain their engine-owned IDs.
        if roomDef == nil then
            local reset = pcall(function()
                square:setRoomID(-1)
            end)
            if not reset or square:getRoom() ~= nil then
                scanOk = false
            else
                cleared = cleared + 1
            end
        end
    end
    eachStructureSquare(cell, guard.oldBounds, inspect)
    eachStructureSquare(cell, guard.newBounds, inspect)
    return scanOk, cleared
end

local function beginRoomOwnershipRefresh(args)
    local rvId = args.rvId
    local generation = finiteInteger(args.generation)
    local bitmapVersion = finiteInteger(args.bitmapVersion)
    local newBounds = readRoomRefreshBounds(args, "new")
    if rvId == nil or tostring(rvId) == "" or generation == nil
        or generation < 1 or bitmapVersion ~= C.BITMAP_VERSION
        or newBounds == nil
        or args.hasOld ~= true and args.hasOld ~= false then
        return
    end
    local oldBounds = nil
    if args.hasOld == true then
        oldBounds = readRoomRefreshBounds(args, "old")
        if oldBounds == nil then return end
    end
    local key = roomOwnershipGuardKey(rvId, generation, bitmapVersion)
    -- A current generation packet contains the authoritative previous/current
    -- footprints needed for this swap.  Retain monitors for other RV IDs, but
    -- do not keep a prior generation's geometry alive after this identity has
    -- been accepted; that would turn old bounds into a permanent client path.
    for existingKey, existingGuard in pairs(roomOwnershipGuards) do
        if existingKey ~= key
            and tostring(existingGuard.rvId) == tostring(rvId) then
            roomOwnershipGuards[existingKey] = nil
        end
    end
    roomOwnershipGuards[key] = {
        key = key,
        rvId = tostring(rvId),
        generation = generation,
        bitmapVersion = bitmapVersion,
        oldBounds = oldBounds,
        newBounds = newBounds,
        ticks = 0,
        stableTicks = 0,
        totalCleared = 0,
        monitorReady = false,
    }
    -- Arm immediately, before any ordered removal/rebuild packets that follow
    -- this broadcast server command are applied.
    local _, cleared = refreshInvalidRoomOwnership(roomOwnershipGuards[key])
    roomOwnershipGuards[key].totalCleared = cleared
end

local function finalTargetRoomIsValid(x, y, z)
    local cell = getCell()
    if not cell then
        return false
    end
    local squareCallOk, square = pcall(function()
        return cell:getGridSquare(math.floor(x), math.floor(y), z)
    end)
    if not squareCallOk or not square then
        -- The server waits for the complete footprint, but the client may
        -- still be streaming its local cell. Keep the player at staging and
        -- retry the synchronous check on a later command/tick.
        return false
    end
    local roomCallOk, room = pcall(function()
        return square:getRoom()
    end)
    if not roomCallOk then
        return false
    end
    if room == nil then
        return true
    end
    local roomDefCallOk, roomDef = pcall(function()
        return square:getRoomDef()
    end)
    if not roomDefCallOk then
        return false
    end
    if roomDef ~= nil then
        return true
    end
    local resetCallOk = pcall(function()
        square:setRoomID(-1)
    end)
    if not resetCallOk then
        return false
    end
    local verifyCallOk, remainingRoom = pcall(function()
        return square:getRoom()
    end)
    return verifyCallOk and remainingRoom == nil
end

local function updateRoomOwnershipGuards()
    for generation, guard in pairs(roomOwnershipGuards) do
        guard.ticks = guard.ticks + 1
        local scanOk, cleared = refreshInvalidRoomOwnership(guard)
        guard.totalCleared = guard.totalCleared + cleared
        if scanOk and cleared == 0 then
            guard.stableTicks = guard.stableTicks + 1
        else
            guard.stableTicks = 0
        end
        -- The warm-up/stable tail is diagnostic only.  This monitor is kept
        -- for the lifetime of the current identity because a later wall or
        -- floor removal may deliver another region rebuild after the initial
        -- generation has been READY for a long time.  OnTick runs after
        -- IsoRegions.update and before the next player update, so clearing the
        -- exact invalid reference here prevents ParameterFirearmRoomSize from
        -- observing IsoRoom.getRoomDef()==nil.
        if not guard.monitorReady
            and guard.ticks >= ROOM_OWNERSHIP_MIN_TICKS
            and guard.stableTicks >= ROOM_OWNERSHIP_STABLE_TICKS then
            guard.monitorReady = true
            print("[RailroaderRVTest] client room ownership monitor active generation="
                .. tostring(generation) .. " cleared=" .. tostring(guard.totalCleared))
        end
    end
end

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

local function tryApplyFinalRelocation(args)
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
        return true
    end
    local guard = roomOwnershipGuards[roomOwnershipGuardKey(
        rvId, generation, bitmapVersion)]
    if guard == nil or tostring(guard.rvId) ~= tostring(rvId)
        or guard.bitmapVersion ~= bitmapVersion then
        return false
    end
    -- The network handler performs this synchronously before teleportTo.  This
    -- is deliberately not an OnTick-only repair: the player stays at the safe
    -- staging square until this exact scan has removed every
    -- room!=nil && RoomDef==nil reference in the old/new footprints.
    local scanCallOk, scanOk = pcall(refreshInvalidRoomOwnership, guard)
    if not scanCallOk or scanOk ~= true then
        return false
    end
    if not finalTargetRoomIsValid(x, y, z) then
        return false
    end
    local playerObj = localPlayerByOnlineId(onlineId)
    if not playerObj or playerObj:isDead() then
        return true
    end
    local teleported = pcall(function()
        playerObj:teleportTo(x, y, z)
    end)
    if teleported and type(playerObj.setCurrentSquareFromPosition) == "function" then
        -- teleportTo updates coordinates only. Use the official three-argument
        -- IsoMovingObject overload to refresh the client cache.  Do not write
        -- Java IsoPlayer fields from Lua; the server's temporary west-neighbour
        -- floor transaction remains the authoritative roof repair.
        pcall(function() playerObj:setCurrentSquareFromPosition(x, y, z) end)
    end
    return teleported
end

local function applyFinalRelocation(args)
    -- This is a distinct server-selected entry command.  It intentionally has
    -- no acknowledgement and never populates the initial relocation pending
    -- state, so the initial token-only ack cannot be mixed into this move.
    pendingRelocation = nil
    pendingFinalRelocation = {
        args = args,
        ticks = 0,
    }
    -- Try in the command callback itself, before the player can enter the
    -- engine update/audio path. If the guard packet has not been installed yet,
    -- OnTick retries while the player remains at staging.
    if tryApplyFinalRelocation(args) then
        pendingFinalRelocation = nil
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
    local token = args.token
    local onlineId = finiteInteger(args.onlineId)
    local x = finiteInteger(args.x)
    local y = finiteInteger(args.y)
    local z = finiteInteger(args.z)
    local rvId = args.rvId
    local generation = finiteInteger(args.generation)
    local bitmapVersion = finiteInteger(args.bitmapVersion)
    local roofRepairTransition = args.roofRepairTransition == true
    local roofRepairPhase = args.roofRepairPhase
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
    if roofRepairTransition and roofRepairPhase == "temporary"
        and args.haloText ~= "正在刷新房间" then
        return
    end
    local playerObj = localPlayerByOnlineId(onlineId)
    if not playerObj or playerObj:isDead() then
        return
    end
    if roofRepairTransition and roofRepairPhase == "temporary"
        and type(playerObj.setHaloNote) == "function" then
        -- The server haloText is a strict current-schema marker only.  Do not
        -- pass a network-serialized non-ASCII value into the game renderer;
        -- the local ASCII label avoids control-string/encoding leakage while
        -- retaining server authority over the relocation itself.
        pcall(function()
            playerObj:setHaloNote(ROOF_REPAIR_HALO_TEXT, 255, 255, 255, 1500)
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
    local relocated = pcall(function()
        playerObj:teleportTo(x + 0.5, y + 0.5, z)
    end)
    if not relocated then
        return
    end
    -- teleportTo updates coordinates immediately, while IsoMovingObject's
    -- current square is refreshed by a later game update.  Delay the ack
    -- until OnTick observes that refresh; an immediate getCurrentSquare()
    -- check would still see the room that is about to be rebuilt.
    pendingRelocation = {
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
        ticks = 0,
    }
end

function Client.onTick()
    updateRoomOwnershipGuards()
    local finalPending = pendingFinalRelocation
    if finalPending ~= nil then
        finalPending.ticks = finalPending.ticks + 1
        if finalPending.ticks > RELOCATION_TIMEOUT_TICKS
            or tryApplyFinalRelocation(finalPending.args) then
            pendingFinalRelocation = nil
        end
    end
    local pending = pendingRelocation
    if pending == nil then
        return
    end
    pending.ticks = pending.ticks + 1
    if pending.ticks > RELOCATION_TIMEOUT_TICKS then
        pendingRelocation = nil
        return
    end
    local playerObj = localPlayerByOnlineId(pending.onlineId)
    if not playerObj or playerObj:isDead() then
        pendingRelocation = nil
        return
    end
    local current = playerObj:getCurrentSquare()
    local currentMatches = current
        and current:getX() == pending.x and current:getY() == pending.y
        and current:getZ() == pending.z
    if not currentMatches and pending.roofRepairTransition
        and pending.roofRepairPhase == "temporary"
        and pending.ticks >= 3 then
        -- The deliberate remote target can be a valid server coordinate with
        -- no client GridSquare (for example the unloaded/empty -15 layer).
        -- This acknowledgement only reports that the server command was
        -- applied; the server still re-reads its authoritative player x/y/z
        -- and schema context before marking the phase arrived.
        local xOk, currentX = pcall(function() return playerObj:getX() end)
        local yOk, currentY = pcall(function() return playerObj:getY() end)
        local zOk, currentZ = pcall(function() return playerObj:getZ() end)
        local numericX = finiteNumber(currentX)
        local numericY = finiteNumber(currentY)
        local numericZ = finiteNumber(currentZ)
        currentMatches = xOk and yOk and zOk
            and numericX ~= nil and numericY ~= nil and numericZ ~= nil
            and math.floor(numericX) == pending.x
            and math.floor(numericY) == pending.y
            and math.floor(numericZ) == pending.z
    end
    if not currentMatches then
        return
    end
    -- The destination is intentionally cleaned of floors by the server, so a
    -- missing floor is not a client-side reason to discard the relocation ack.
    sendClientCommand(playerObj, C.MOD_ID, COMMAND_RELOCATE_ACK,
        { token = pending.token })
    pendingRelocation = nil
end

Events.OnServerCommand.Add(Client.onServerCommand)
Events.OnTick.Add(Client.onTick)
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

return Client
