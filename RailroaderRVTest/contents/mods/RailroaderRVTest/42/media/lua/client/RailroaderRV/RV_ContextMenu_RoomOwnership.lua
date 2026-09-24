-- RV_ContextMenu: RoomOwnership responsibilities.
return function(ctx)
local C = ctx.C
local Layout = ctx.Layout
local roomOwnershipGuards = ctx.roomOwnershipGuards
local ROOM_OWNERSHIP_MIN_TICKS = ctx.ROOM_OWNERSHIP_MIN_TICKS
local ROOM_OWNERSHIP_STABLE_TICKS = ctx.ROOM_OWNERSHIP_STABLE_TICKS
local ROOM_OWNERSHIP_SCAN_INTERVAL_TICKS = ctx.ROOM_OWNERSHIP_SCAN_INTERVAL_TICKS

local function roomOwnershipGuardKey(rvId, generation, bitmapVersion)
    return tostring(rvId) .. ":" .. tostring(generation) .. ":"
        .. tostring(bitmapVersion)
end

local finiteNumber = C.finiteNumber
local finiteInteger = C.finiteInteger

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
    Layout.eachStructureCoordinate(bounds, function(x, y, z)
        local square = cell:getGridSquare(x, y, z)
        if square then callback(square, x, y, z) end
    end)
end

local function squareCoordinates(square)
    if not square then return nil end
    local xOk, x = pcall(function() return square:getX() end)
    local yOk, y = pcall(function() return square:getY() end)
    local zOk, z = pcall(function() return square:getZ() end)
    x, y, z = finiteInteger(x), finiteInteger(y), finiteInteger(z)
    if not xOk or not yOk or not zOk or x == nil or y == nil or z == nil then
        return nil
    end
    return x, y, z
end

local function coordinatesInBounds(x, y, z, bounds)
    return type(bounds) == "table"
        and x >= bounds.wallMinX and x <= bounds.wallMaxX
        and y >= bounds.wallMinY and y <= bounds.wallMaxY
        and z == bounds.z
        or type(bounds) == "table"
        and x >= bounds.roofMinX and x <= bounds.roofMaxX
        and y >= bounds.roofMinY and y <= bounds.roofMaxY
        and z == bounds.roofZ
end

local function inspectRoomOwnershipSquare(square)
    local roomOk, room = pcall(function() return square:getRoom() end)
    if not roomOk then return false, 0 end
    if room == nil then return true, 0 end
    local roomDefOk, roomDef = pcall(function() return square:getRoomDef() end)
    if not roomDefOk then return false, 0 end
    if roomDef ~= nil then return true, 0 end
    local resetOk = pcall(function() square:setRoomID(-1) end)
    if not resetOk then return false, 0 end
    local verifyOk, remainingRoom = pcall(function() return square:getRoom() end)
    if not verifyOk or remainingRoom ~= nil then return false, 0 end
    return true, 1
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
        local inspected, reset = inspectRoomOwnershipSquare(square)
        if not inspected then
            scanOk = false
            return
        end
        cleared = cleared + reset
    end
    eachStructureSquare(cell, guard.oldBounds, inspect)
    eachStructureSquare(cell, guard.newBounds, inspect)
    return scanOk, cleared
end

local function refreshCurrentPlayerRoomOwnership(guard)
    if type(getNumActivePlayers) ~= "function"
        or type(getSpecificPlayer) ~= "function" then
        return true, 0
    end
    local countOk, count = pcall(getNumActivePlayers)
    if not countOk or type(count) ~= "number" then return false, 0 end
    local seen = {}
    local scanOk, cleared = true, 0
    for playerNum = 0, count - 1 do
        local playerOk, player = pcall(getSpecificPlayer, playerNum)
        if playerOk and player and type(player.getCurrentSquare) == "function" then
            local squareOk, square = pcall(function()
                return player:getCurrentSquare()
            end)
            if not squareOk then
                scanOk = false
            elseif square then
                local x, y, z = squareCoordinates(square)
                if x and (coordinatesInBounds(x, y, z, guard.oldBounds)
                    or coordinatesInBounds(x, y, z, guard.newBounds)) then
                    local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
                    if not seen[key] then
                        seen[key] = true
                        local inspected, reset = inspectRoomOwnershipSquare(square)
                        if not inspected then
                            scanOk = false
                        else
                            cleared = cleared + reset
                        end
                    end
                end
            end
        end
    end
    return scanOk, cleared
end

local function objectCoordinates(object)
    if not object then return nil end
    local target = object
    if type(object.getSquare) == "function" then
        local squareOk, square = pcall(function() return object:getSquare() end)
        if squareOk and square then target = square end
    end
    return squareCoordinates(target)
end

local function requestRoomOwnershipScan(object)
    local x, y, z = objectCoordinates(object)
    if x == nil then return end
    for _, guard in pairs(roomOwnershipGuards) do
        if coordinatesInBounds(x, y, z, guard.oldBounds)
            or coordinatesInBounds(x, y, z, guard.newBounds) then
            guard.scanRequested = true
            guard.nextScanTick = ctx.clientTick
        end
    end
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
        scanRequested = false,
    }
    -- Arm immediately, before any ordered removal/rebuild packets that follow
    -- this broadcast server command are applied.
    local guard = roomOwnershipGuards[key]
    local scanOk, cleared = refreshInvalidRoomOwnership(guard)
    guard.totalCleared = cleared
    guard.lastScanStable = scanOk and cleared == 0
    guard.stableTicks = guard.lastScanStable
        and ROOM_OWNERSHIP_SCAN_INTERVAL_TICKS or 0
    guard.nextScanTick = ctx.clientTick + ROOM_OWNERSHIP_SCAN_INTERVAL_TICKS
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
        local currentScanOk, currentCleared = refreshCurrentPlayerRoomOwnership(guard)
        if not currentScanOk or currentCleared > 0 then
            guard.lastScanStable = false
            guard.stableTicks = 0
            guard.scanRequested = true
        end
        if guard.scanRequested or ctx.clientTick >= (guard.nextScanTick or 0) then
            local scanOk, cleared = refreshInvalidRoomOwnership(guard)
            guard.totalCleared = guard.totalCleared + cleared
            guard.lastScanStable = scanOk and cleared == 0
            guard.scanRequested = not scanOk or cleared > 0
            guard.nextScanTick = ctx.clientTick + ROOM_OWNERSHIP_SCAN_INTERVAL_TICKS
            if guard.lastScanStable then
                -- stableTicks represents successful full scans, expressed in
                -- the configured fallback interval, not elapsed ticks since
                -- the last scan.
                guard.stableTicks = guard.stableTicks
                    + ROOM_OWNERSHIP_SCAN_INTERVAL_TICKS
            else
                guard.stableTicks = 0
            end
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


ctx.roomOwnershipGuardKey = roomOwnershipGuardKey
ctx.validRailroaderFinalHint = validRailroaderFinalHint
ctx.localPlayerByOnlineId = localPlayerByOnlineId
ctx.refreshInvalidRoomOwnership = refreshInvalidRoomOwnership
ctx.requestRoomOwnershipScan = requestRoomOwnershipScan
ctx.beginRoomOwnershipRefresh = beginRoomOwnershipRefresh
ctx.finalTargetRoomIsValid = finalTargetRoomIsValid
ctx.updateRoomOwnershipGuards = updateRoomOwnershipGuards
ctx.finiteNumber = finiteNumber
ctx.finiteInteger = finiteInteger
end
