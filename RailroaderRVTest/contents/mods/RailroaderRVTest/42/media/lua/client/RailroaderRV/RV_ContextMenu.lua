-- Client-only entry point for the technical test.
--
-- The menu is intentionally ordinary (world right-click).  The client sends
-- only the command name; the server validates the player's current state from
-- its authoritative player object and selects both the fixed generation anchor
-- and a safe staging coordinate outside the old/new structure footprints.

require "RailroaderRV/RV_Constants"

RailroaderRV = RailroaderRV or {}
RailroaderRV.Client = RailroaderRV.Client or {}

local Client = RailroaderRV.Client
local C = RailroaderRV.Constants
local MENU_KEY = "ContextMenu_RailroaderRVTest_Generate"
local COMMAND_RELOCATE = "Relocate"
local COMMAND_RELOCATE_ACK = "RelocateAck"
local COMMAND_FINAL_RELOCATE = C.COMMAND_FINAL_RELOCATE or "FinalRelocate"
local COMMAND_REFRESH_ROOM_OWNERSHIP = C.COMMAND_REFRESH_ROOM_OWNERSHIP
    or "RefreshRoomOwnership"
local pendingRelocation = nil
local pendingFinalRelocation = nil
local roomOwnershipGuards = {}
local RELOCATION_TIMEOUT_TICKS = 600
-- IsoRegions has no public Lua completion event. A bounded guard plus a
-- stable tail covers the asynchronous rebuild without keeping permanent state.
local ROOM_OWNERSHIP_MIN_TICKS = 1800
local ROOM_OWNERSHIP_STABLE_TICKS = 120
local ROOM_OWNERSHIP_MAX_TICKS = 7200

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
    local generation = finiteInteger(args.generation)
    local newBounds = readRoomRefreshBounds(args, "new")
    if generation == nil or generation < 1 or newBounds == nil
        or args.hasOld ~= true and args.hasOld ~= false then
        return
    end
    local oldBounds = nil
    if args.hasOld == true then
        oldBounds = readRoomRefreshBounds(args, "old")
        if oldBounds == nil then return end
    end
    roomOwnershipGuards[generation] = {
        generation = generation,
        oldBounds = oldBounds,
        newBounds = newBounds,
        ticks = 0,
        stableTicks = 0,
        totalCleared = 0,
    }
    -- Arm immediately, before any ordered removal/rebuild packets that follow
    -- this broadcast server command are applied.
    local _, cleared = refreshInvalidRoomOwnership(roomOwnershipGuards[generation])
    roomOwnershipGuards[generation].totalCleared = cleared
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
    local finished = {}
    for generation, guard in pairs(roomOwnershipGuards) do
        guard.ticks = guard.ticks + 1
        local scanOk, cleared = refreshInvalidRoomOwnership(guard)
        guard.totalCleared = guard.totalCleared + cleared
        if scanOk and cleared == 0 then
            guard.stableTicks = guard.stableTicks + 1
        else
            guard.stableTicks = 0
        end
        if guard.ticks >= ROOM_OWNERSHIP_MAX_TICKS then
            print("[RailroaderRVTest] client room ownership guard expired generation="
                .. tostring(generation) .. " cleared=" .. tostring(guard.totalCleared))
            finished[#finished + 1] = generation
        elseif guard.ticks >= ROOM_OWNERSHIP_MIN_TICKS
            and guard.stableTicks >= ROOM_OWNERSHIP_STABLE_TICKS then
            print("[RailroaderRVTest] client room ownership guard complete generation="
                .. tostring(generation) .. " cleared=" .. tostring(guard.totalCleared))
            finished[#finished + 1] = generation
        end
    end
    for i = 1, #finished do
        roomOwnershipGuards[finished[i]] = nil
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
    local generation = finiteInteger(args.generation)
    local onlineId = finiteInteger(args.onlineId)
    local x = finiteNumber(args.x)
    local y = finiteNumber(args.y)
    local z = finiteNumber(args.z)
    if type(token) ~= "string" or token == "" or generation == nil
        or generation < 1 or onlineId == nil
        or x == nil or y == nil or z == nil or z < -32 or z > 31 then
        return true
    end
    local guard = roomOwnershipGuards[generation]
    if guard == nil then
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
        applyFinalRelocation(args)
        return
    end
    if command ~= COMMAND_RELOCATE then return end
    local token = args.token
    local onlineId = finiteInteger(args.onlineId)
    local x = finiteInteger(args.x)
    local y = finiteInteger(args.y)
    local z = finiteInteger(args.z)
    if type(token) ~= "string" or token == "" or onlineId == nil
        or x == nil or y == nil or z == nil or z < -32 or z > 31 then
        return
    end
    local playerObj = localPlayerByOnlineId(onlineId)
    if not playerObj or playerObj:isDead() then
        return
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
        x = x,
        y = y,
        z = z,
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
    if not current or current:getX() ~= pending.x or current:getY() ~= pending.y
        or current:getZ() ~= pending.z then
        return
    end
    -- The destination is intentionally cleaned of floors by the server, so a
    -- missing floor is not a client-side reason to discard the relocation ack.
    sendClientCommand(playerObj, C.MOD_ID, COMMAND_RELOCATE_ACK,
        { token = pending.token })
    pendingRelocation = nil
end

Events.OnFillWorldObjectContextMenu.Add(Client.onFillWorldObjectContextMenu)
Events.OnServerCommand.Add(Client.onServerCommand)
Events.OnTick.Add(Client.onTick)

return Client
