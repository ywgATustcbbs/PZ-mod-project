-- RV_ContextMenu: RoomOwnership responsibilities.
return function(ctx)
local C = ctx.C
local Layout = ctx.Layout
local roomOwnershipGuards = {}

local function roomOwnershipGuardKey(rvId, generation)
    return tostring(rvId) .. ":" .. tostring(generation)
end

local finiteNumber = C.finiteNumber
local finiteInteger = C.finiteInteger

local function validRailroaderFinalHint(args)
    local generation = type(args) == "table" and finiteInteger(args.generation)
    return type(args) == "table" and args.railroaderTransition == true
        and type(args.token) == "string" and args.token ~= ""
        and args.locoId ~= nil and tostring(args.locoId) ~= ""
        and args.rvId ~= nil and tostring(args.rvId) ~= ""
        and generation ~= nil and generation >= 1
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
        or bounds.roomMinX < bounds.wallMinX
        or bounds.roomMaxX > bounds.wallMaxX
        or bounds.roomMinY < bounds.wallMinY
        or bounds.roomMaxY > bounds.wallMaxY then
        return nil
    end
    return bounds
end

local function eachStructureSquare(cell, bounds, callback)
    if not cell or not bounds then
        return
    end
    Layout.eachStructureCoordinate(bounds, function(x, y, z)
        local squareOk, square = pcall(function()
            return cell:getGridSquare(x, y, z)
        end)
        callback(squareOk and square or nil, x, y, z)
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
    if not cell then
        return 0
    end
    local cleared = 0
    local seen = {}
    local function inspect(square, x, y, z)
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if seen[key] or not square then return end
        seen[key] = true
        local inspected, reset = inspectRoomOwnershipSquare(square)
        if not inspected then
            -- The repair helper reports that it could not inspect or reset this
            -- square instead of raising: the caller must stay able to schedule
            -- the one-tick follow-up scan that retries a stale room which could
            -- not be reset on this attempt.
            return
        end
        cleared = cleared + reset
    end
    eachStructureSquare(cell, guard.oldBounds, inspect)
    eachStructureSquare(cell, guard.newBounds, inspect)
    return cleared
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

-- Object callbacks can fire before the local cell and IsoRegions are ready, so
-- a trigger only schedules one structure scan on the next tick; every trigger
-- of that tick merges into the same scan.
local function scheduleRoomOwnershipScan(guard)
    if guard.nextScanTick == nil then
        guard.nextScanTick = ctx.clientTick + 1
    end
end

local function requestRoomOwnershipScan(object)
    local x, y, z = objectCoordinates(object)
    if x == nil then return end
    for _, guard in pairs(roomOwnershipGuards) do
        if coordinatesInBounds(x, y, z, guard.oldBounds)
            or coordinatesInBounds(x, y, z, guard.newBounds) then
            scheduleRoomOwnershipScan(guard)
        end
    end
end

local function beginRoomOwnershipRefresh(args)
    local rvId = args.rvId
    local generation = finiteInteger(args.generation)
    local newBounds = readRoomRefreshBounds(args, "new")
    if rvId == nil or tostring(rvId) == "" or generation == nil
        or generation < 1 or newBounds == nil
        or args.hasOld ~= true and args.hasOld ~= false then
        return
    end
    local oldBounds = nil
    if args.hasOld == true then
        oldBounds = readRoomRefreshBounds(args, "old")
        if oldBounds == nil then return end
    end
    local key = roomOwnershipGuardKey(rvId, generation)
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
        oldBounds = oldBounds,
        newBounds = newBounds,
        currentCheckErrorLatched = false,
        nextScanTick = nil,
    }
    -- Arm immediately, before any ordered removal/rebuild packets that follow
    -- this broadcast server command are applied, and repeat once on the next
    -- tick in case this packet arrived before the local chunks or IsoRegions
    -- were ready.
    local guard = roomOwnershipGuards[key]
    refreshInvalidRoomOwnership(guard)
    scheduleRoomOwnershipScan(guard)
end

local function updateRoomOwnershipGuards()
    for generation, guard in pairs(roomOwnershipGuards) do
        local currentScanOk, currentCleared = refreshCurrentPlayerRoomOwnership(guard)
        if not currentScanOk then
            if not guard.currentCheckErrorLatched then
                guard.currentCheckErrorLatched = true
                scheduleRoomOwnershipScan(guard)
                print("[RailroaderRV] client current-square room check failed; "
                    .. "queued one full scan generation="
                    .. tostring(generation))
            end
        else
            -- A successful local check rearms edge detection for a future,
            -- separate API failure. A persistent failure cannot queue a sweep
            -- on every tick.
            guard.currentCheckErrorLatched = false
        end
        if currentScanOk and currentCleared > 0 then
            scheduleRoomOwnershipScan(guard)
        end
        -- Keep the guard for the lifetime of this identity: a later wall or
        -- floor change can invalidate a room after generation has been READY.
        -- The current-square check runs each tick; a structure scan is
        -- scheduled only by a repair, an API failure, an object event or the
        -- arming packet.
        local dueTick = guard.nextScanTick
        if dueTick ~= nil and ctx.clientTick >= dueTick then
            guard.nextScanTick = nil
            local cleared = refreshInvalidRoomOwnership(guard)
            if cleared > 0 then
                print("[RailroaderRV] client room ownership refresh generation="
                    .. tostring(generation) .. " cleared=" .. tostring(cleared))
            end
        end
    end
end


ctx.validRailroaderFinalHint = validRailroaderFinalHint
ctx.localPlayerByOnlineId = localPlayerByOnlineId
ctx.requestRoomOwnershipScan = requestRoomOwnershipScan
ctx.beginRoomOwnershipRefresh = beginRoomOwnershipRefresh
ctx.updateRoomOwnershipGuards = updateRoomOwnershipGuards
ctx.finiteNumber = finiteNumber
ctx.finiteInteger = finiteInteger
end
