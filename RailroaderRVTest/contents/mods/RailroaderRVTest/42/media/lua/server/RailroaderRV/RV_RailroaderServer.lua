-- Railroader-specific RV entry/exit authority.
--
-- This file deliberately sits beside RV_Server.lua instead of modifying the
-- Railroader source.  The official server record remains the source of truth
-- for train position, speed and seats; this adapter only changes those fields
-- through the same small runtime records that the official command handler
-- uses.  The RV relationship itself is persisted in save-map ModData, never in
-- a survivor's modData, so a replacement character can still use the mapping.

local function processIsClient()
    if type(isClient) ~= "function" then return false end
    local ok, value = pcall(isClient)
    return ok and value == true
end

local function processIsServer()
    if type(isServer) ~= "function" then return true end
    local ok, value = pcall(isServer)
    return ok and value == true
end

-- A client-only process must not register server command handlers.  Dedicated
-- servers, co-op hosts, and the B42 single-player server-side Lua pass through.
if processIsClient() and not processIsServer() then
    return {}
end

require("RailroaderRV/RV_Constants")
local boundaryLoaded, Boundary = pcall(require, "RailroaderRV/RV_BoundaryServer")
if not boundaryLoaded or type(Boundary) ~= "table" then Boundary = nil end
local bitmapLoaded, Bitmap = pcall(require, "RailroaderRV/RV_Bitmap")
if not bitmapLoaded or type(Bitmap) ~= "table" then Bitmap = nil end

RailroaderRV = RailroaderRV or {}
RailroaderRV.RailroaderServer = RailroaderRV.RailroaderServer or {}

local Adapter = RailroaderRV.RailroaderServer
local C = RailroaderRV.Constants
local unpackFn = (table and table.unpack) or unpack
-- Keep persisted map poses inside the same B42 world-height contract used by
-- RV_Server's authoritative relocation validator.  X/Y remain finite server
-- coordinates; the engine's square probe validates their loaded-world use.
local WORLD_MIN_Z = -32
local WORLD_MAX_Z = 31
local roofRepairRooms = {}
local ROOF_REPAIR_CACHE_TTL_TICKS = 1800
local roofRepairPlayers = {}
local roomMonitorPlayers = {}
local pendingWallRoofRepairs = {}
local followUpWallRemovalEvents = {}
local roomTransitionStates = {}
-- A wall-removal event is followed by one authoritative inside->outside
-- observation after the grouped remote relocation returns.  Keep a
-- one-shot, identity-scoped suppression for that self-generated observation;
-- object-removal events clear it so a later independent wall action is never
-- swallowed.
local suppressedRoomTransitions = {}
-- Both removal callbacks can receive the same IsoThumpable instance. Keep a
-- short current-coordinate/object-index window in addition to the room
-- identity so a late duplicate callback cannot clear the transition
-- suppression belonging to its already-completed cycle. The key is a string,
-- not userdata, and is reclaimed after the bounded event window.
local seenWallRemovalEvents = {}
-- The dedicated server tick is 10 Hz in the runtime evidence.  Keep the
-- requested 0.5/1.0/1.5 second retries as 5/10/15 ticks after the temporary
-- relocation has arrived; this is deliberately not the old 30/60/90 contract.
local ROOF_REPAIR_DELAY_TICKS = 5
local ROOF_REPAIR_ATTEMPTS = 3
local ROOF_REPAIR_TRANSITION_SUPPRESSION_TICKS = 120
-- Removal callbacks are raised in the same packet/tick; keep this key window
-- short so a later wall operation that reuses the same object index is not
-- mistaken for the earlier event.
local WALL_REMOVAL_EVENT_DEDUPE_TICKS = 10
local WALL_REMOVAL_FOLLOWUP_TICKS = 600
local WALL_REMOVAL_FOLLOWUP_MAX = 8
-- A queued grouped refresh owns the shared mutex before its first relocation,
-- so do not leave it permanently locked when every required identity stays
-- offline.  Once temporary relocation begins, this deadline is never used.
local ROOF_REPAIR_QUEUED_DEADLINE_TICKS = 600
local RELOCATION_SENTINEL_INTERVAL_TICKS = C.RELOCATION_SENTINEL_INTERVAL_TICKS
local RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS =
    C.RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS
local RELOCATION_SENTINEL_Z = C.RELOCATION_SENTINEL_Z
local ROOF_REPAIR_REMOTE_OFFSET_X = C.ROOF_REPAIR_REMOTE_OFFSET_X
local ROOF_REPAIR_REMOTE_OFFSET_Y = C.ROOF_REPAIR_REMOTE_OFFSET_Y
local ROOF_REPAIR_REMOTE_OFFSET_Z = C.ROOF_REPAIR_REMOTE_OFFSET_Z
local relocationSentinelBusy = {}
local relocationSentinelCooldown = {}
local relocationSentinelWarnings = {}
local transitionSequence = 0
local validateMapSchema
local recordForLoco
local insidePlayersForRecord
local scheduleRoofRepair
local beginRoofRepairPhase
local observeRoomTransitions
local roofRepairOwnsPlayer
local roofRepairTransactionBlocks
local currentGeometryGate
local serverTransactionMutexStatus

local function number(value)
    local valueType = type(value)
    local result
    if valueType == "number" then
        result = value
    elseif valueType == "string" then
        result = tonumber(value)
    elseif value ~= nil then
        local converted, numeric = pcall(function() return value + 0 end)
        if converted and type(numeric) == "number" then result = numeric end
    end
    if type(result) ~= "number" or result ~= result
        or result == math.huge or result == -math.huge then
        return nil
    end
    return result
end

local function integer(value)
    local result = number(value)
    if result == nil or math.floor(result) ~= result then return nil end
    return result
end

local function call(target, method, ...)
    if target == nil or type(method) ~= "string" then return false, nil end
    local args = { ... }
    return pcall(function()
        return target[method](target, unpackFn(args))
    end)
end

local function callGlobal(name, ...)
    local fn = rawget(_G, name)
    if type(fn) ~= "function" then return false, nil end
    local args = { ... }
    return pcall(function() return fn(unpackFn(args)) end)
end

local function safeCall(target, method, ...)
    local ok = call(target, method, ...)
    return ok == true
end

local function playerId(player)
    local ok, value = call(player, "getOnlineID")
    local id = ok and integer(value) or nil
    if id ~= nil then return id end
    -- SP has no network slot.  The B42 local player is still the sole
    -- authority; use its stable local slot only when this file is running in
    -- the non-server SP pass.  Dedicated/co-op server requests remain fail
    -- closed if the online id is unavailable.
    if not processIsServer() then
        local okNum, playerNum = call(player, "getPlayerNum")
        return (okNum and integer(playerNum)) or 0
    end
    return nil
end

local function playerName(player)
    local ok, value = call(player, "getUsername")
    if not ok or value == nil then return nil end
    local text = tostring(value)
    return text ~= "" and text or nil
end

local function playerDead(player)
    local ok, value = call(player, "isDead")
    return ok and value == true
end

local function playerPosition(player)
    if not player then return nil end
    local okX, x = call(player, "getX")
    local okY, y = call(player, "getY")
    local okZ, z = call(player, "getZ")
    x, y, z = number(x), number(y), number(z)
    if not okX or not okY or not okZ or x == nil or y == nil or z == nil then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function copyPosition(position)
    if type(position) ~= "table" then return nil end
    local x, y, z = number(position.x), number(position.y), number(position.z)
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

local function newTransitionToken(kind, record)
    transitionSequence = transitionSequence + 1
    return tostring(kind) .. ":" .. tostring(record and record.locoId or "rv")
        .. ":" .. tostring(record and record.generation or 0) .. ":"
        .. tostring(os.time()) .. ":" .. tostring(transitionSequence)
end

-- Persisted locomotive poses may include a forward vector.  Keep that vector
-- only for locomotive-position records; player/RV coordinates continue to be
-- plain positions and never accept client-provided orientation.
local function copyPose(position)
    local copied = copyPosition(position)
    if not copied then return nil end
    local dx, dy = number(position.dirX), number(position.dirY)
    if dx ~= nil and dy ~= nil then
        local length = math.sqrt(dx * dx + dy * dy)
        if length > 0.0001 then
            copied.dirX, copied.dirY = dx / length, dy / length
        end
    end
    return copied
end

local function animalType(animal)
    local ok, value = call(animal, "getAnimalType")
    return ok and tostring(value) or nil
end

local function isRailroaderLocomotive(animal)
    return animal ~= nil and animalType(animal) == "rr_loco"
end

local function animalId(animal)
    local ok, value = call(animal, "getAnimalID")
    return ok and value or nil
end

local function trainId(train)
    if type(train) ~= "table" then return nil end
    if train.id ~= nil then return train.id end
    return train.animal and animalId(train.animal) or nil
end

-- RR_ServerTrain.lua is deliberately server-only in Railroader 2.1.  In a
-- single-player session the authoritative record is instead
-- RR.TrainEntity.active and its `rider`/`seat`/`passenger` fields, with
-- RR.Ride.current being the local Ride authority.  Keep the source alongside
-- the list so seat operations never treat an SP record as an MP record.
local function trainList()
    local rr = rawget(_G, "RR")
    local serverTrain = rr and rr.ServerTrain
    -- In SP prefer the client-authoritative TrainEntity even if a harmless
    -- empty RR.ServerTrain placeholder was left by a loader.
    if not processIsServer() then
        local trainEntity = rr and rr.TrainEntity
        if trainEntity and type(trainEntity.active) == "table" then
            return trainEntity.active, "singleplayer"
        end
    end
    if serverTrain and type(serverTrain.active) == "table" then
        return serverTrain.active, "server"
    end
    -- A co-op host is both client and server.  Never fall back to its local
    -- TrainEntity mirror when the authoritative server table is merely empty
    -- or has not spawned yet.
    if processIsServer() then return nil, "server" end
    -- B42 single-player runs the client train mirror in a non-client Lua pass.
    -- It is still used only as a fallback when the official server record is
    -- absent; multiplayer always resolves RR.ServerTrain.active above.
    local trainEntity = rr and rr.TrainEntity
    if trainEntity and type(trainEntity.active) == "table" then
        return trainEntity.active, "singleplayer"
    end
    return nil, nil
end

local function findTrain(locoId)
    if locoId == nil then return nil end
    local wanted = tostring(locoId)
    local list, authority = trainList()
    if type(list) ~= "table" then return nil end
    for _, train in pairs(list) do
        if type(train) == "table" then
            local id = trainId(train)
            if id ~= nil and tostring(id) == wanted
                and isRailroaderLocomotive(train.animal) then
                return train, authority
            end
        end
    end
    return nil
end

local function authorityForTrain(train)
    if not train then return nil end
    local list, authority = trainList()
    if type(list) == "table" then
        for _, candidate in pairs(list) do
            if candidate == train then return authority end
        end
    end
    return nil
end

local function trainPosition(train)
    local animal = train and train.animal
    if animal then
        local okX, x = call(animal, "getX")
        local okY, y = call(animal, "getY")
        local okZ, z = call(animal, "getZ")
        x, y, z = number(x), number(y), number(z)
        if okX and okY and okZ and x ~= nil and y ~= nil and z ~= nil then
            return { x = x, y = y, z = z }
        end
    end
    local pose = train and train.pose
    if type(pose) == "table" then
        return copyPosition(pose)
    end
    return nil
end

local function trainSpeed(train)
    if not train then return 0 end
    local drive = train.drive
    local value = drive and drive.v
    if value == nil then value = train.v end
    if value == nil then value = train.speed end
    return number(value) or 0
end

local function trainMoving(train)
    return math.abs(trainSpeed(train)) > (number(C.RV_STOPPED_SPEED) or 0.05)
end

local function trainDirection(train)
    local dx = train and number(train.dirX)
    local dy = train and number(train.dirY)
    local pose = train and train.pose
    if (dx == nil or dy == nil) and type(pose) == "table" then
        dx, dy = number(pose.dirX), number(pose.dirY)
    end
    if (dx == nil or dy == nil) and train and train.animal then
        local ok, direction = call(train.animal, "getForwardDirection")
        if ok and direction then
            local okX, valueX = call(direction, "getX")
            local okY, valueY = call(direction, "getY")
            if okX and okY then dx, dy = number(valueX), number(valueY) end
        end
    end
    dx, dy = dx or 0, dy or -1
    local length = math.sqrt(dx * dx + dy * dy)
    if length > 0.0001 then return dx / length, dy / length end
    return 0, -1
end

local function trainPose(train)
    local position = trainPosition(train)
    if not position then return nil end
    local dx, dy = trainDirection(train)
    position.dirX, position.dirY = dx, dy
    return position
end

local function trainSize(train)
    if train and train.animal then
        local ok, value = call(train.animal, "getAnimalSize")
        if ok and number(value) then return number(value) end
    end
    return 0.7
end

-- RR.Body.seatWorld is the official seat formula.  The local fallback exists
-- only for a reloaded record whose shared body module has not been attached yet.
local function seatPosition(train, seat)
    local position = trainPosition(train)
    if not position then return nil end
    local dx, dy = trainDirection(train)
    local pose = train and train.pose
    if type(pose) ~= "table" then
        pose = { x = position.x, y = position.y, z = position.z,
            dirX = dx, dirY = dy }
    end
    pose.x, pose.y, pose.z = position.x, position.y, position.z
    pose.dirX, pose.dirY = dx, dy
    local rr = rawget(_G, "RR")
    if rr and rr.Body and type(rr.Body.seatWorld) == "function" then
        local ok, x, y, z = pcall(rr.Body.seatWorld, pose, trainSize(train), seat)
        if ok and number(x) and number(y) and number(z) then
            return { x = number(x), y = number(y), z = number(z) }
        end
    end
    local u, w = 0, 0
    if seat and seat > 0 then
        local offsets = {
            { u = -1.2, w = -0.55 }, { u = -1.2, w = 0.55 },
            { u = -2.3, w = -0.55 }, { u = -2.3, w = 0.55 },
            { u = -3.4, w = 0 },
        }
        local offset = offsets[seat]
        if offset then u, w = offset.u, offset.w end
    end
    return {
        x = position.x + u * dx - w * dy,
        y = position.y + u * dy + w * dx,
        z = position.z,
    }
end

local function besidePosition(train)
    local position = trainPosition(train)
    if not position then return nil end
    local dx, dy = trainDirection(train)
    return { x = position.x - dy * 2.0, y = position.y + dx * 2.0,
        z = position.z }
end

local function usableCoordinate(position)
    local x, y, z = number(position and position.x), number(position and position.y),
        number(position and position.z)
    if x == nil or y == nil or z == nil or z < -32 or z > 31 then
        return false
    end
    local worldOk, world = callGlobal("getWorld")
    if not worldOk or not world then return false end
    local squareOk, valid = call(world, "isValidSquare", math.floor(x),
        math.floor(y), math.floor(z))
    return squareOk and valid == true
end

-- An unloaded locomotive cannot receive a fabricated seat assignment.  Use
-- only the complete current-schema locomotive pose, then choose a conservative
-- side neighbour and validate its legal world square.
local function persistedBesidePosition(record)
    if type(record) ~= "table" then return nil end
    local base = copyPose(record.locoPosition)
    if not base then return nil end

    local dx, dy = number(base.dirX), number(base.dirY)
    if dx == nil or dy == nil then return nil end
    local length = math.sqrt(dx * dx + dy * dy)
    if length <= 0.0001 then return nil end
    dx, dy = dx / length, dy / length

    local candidates = {
        { x = base.x - dy * 2.0, y = base.y + dx * 2.0, z = base.z },
        { x = base.x + dy * 2.0, y = base.y - dx * 2.0, z = base.z },
        { x = base.x + 1.0, y = base.y, z = base.z },
        { x = base.x - 1.0, y = base.y, z = base.z },
        { x = base.x, y = base.y + 1.0, z = base.z },
        { x = base.x, y = base.y - 1.0, z = base.z },
    }
    for i = 1, #candidates do
        if usableCoordinate(candidates[i]) then
            return candidates[i]
        end
    end
    return nil
end

-- Railroader 2.1's E/menu contract is RR_Ride.MOUNT_REACH measured from
-- RR.Body.hullDistance, not a radius around the animal centre.  Rebuild the
-- live pose from the authoritative animal when the server record has no cached
-- pose; the fallback is the same 2-tile reach and therefore never widens it.
local function hullDistance(player, train)
    local playerPos, locoPos = playerPosition(player), trainPosition(train)
    if not playerPos or not locoPos then return nil end
    local dx, dy = trainDirection(train)
    local pose = train and (train.pose or train.lastPose)
    if type(pose) ~= "table" then
        pose = { x = locoPos.x, y = locoPos.y, z = locoPos.z,
            dirX = dx, dirY = dy }
    else
        pose = { x = number(pose.x) or locoPos.x, y = number(pose.y) or locoPos.y,
            z = number(pose.z) or locoPos.z, dirX = dx, dirY = dy }
    end
    local rr = rawget(_G, "RR")
    if rr and rr.Body and type(rr.Body.hullDistance) == "function" then
        local ok, distance = pcall(rr.Body.hullDistance, pose, trainSize(train),
            playerPos.x, playerPos.y)
        if ok and number(distance) then return number(distance) end
    end
    local centerDx = playerPos.x - locoPos.x
    local centerDy = playerPos.y - locoPos.y
    return math.sqrt(centerDx * centerDx + centerDy * centerDy)
end

local function seatForPlayer(train, onlineId)
    if not train or onlineId == nil then return nil end
    local passengers = train.passengers
    if type(passengers) ~= "table" then return nil end
    local direct = passengers[onlineId]
    if direct ~= nil then return number(direct) or direct end
    for id, seat in pairs(passengers) do
        if tostring(id) == tostring(onlineId) then
            return number(seat) or seat
        end
    end
    return nil
end

local function isDriver(train, onlineId)
    return train and train.driver ~= nil and tostring(train.driver) == tostring(onlineId)
end

local function freePassengerSeat(train)
    if not train then return nil end
    local passengers = train.passengers or {}
    local maxPassengers = integer(C.RV_MAX_PASSENGERS) or 5
    for seat = 1, maxPassengers do
        local occupied = false
        for _, assigned in pairs(passengers) do
            if number(assigned) == seat then occupied = true; break end
        end
        if not occupied then return seat end
    end
    return nil
end

local function playerRole(train, onlineId)
    local authority = authorityForTrain(train)
    -- TrainEntity is the actual SP authority.  Its rider flag is boolean (not
    -- an online id), while Ride.current identifies the local player.  Never
    -- interpret an SP record through the MP driver/passengers tables.
    if authority == "singleplayer" then
        local rr = rawget(_G, "RR")
        local ride = rr and rr.Ride
        if (ride and ride.current == train) or train.rider == true then
            local currentSeat = number(train.seat) or 0
            if currentSeat > 0 or train.passenger == true then
                return "passenger", currentSeat > 0 and currentSeat or 1
            end
            return "driver", 0
        end
        return "external", nil
    end
    if isDriver(train, onlineId) then return "driver", 0 end
    local seat = seatForPlayer(train, onlineId)
    if seat ~= nil then return "passenger", seat end
    return "external", nil
end

local function singleplayerMount(train, seat)
    local rr = rawget(_G, "RR")
    local ride = rr and rr.Ride
    if ride and type(ride.mountRecord) == "function" then
        local ok = pcall(ride.mountRecord, train, true, seat or 0)
        if ok and ride.current == train then return true end
    end
    -- This fallback is only for the SP TrainEntity record when the client Ride
    -- module has not been loaded in this Lua pass; it is not an MP client claim.
    train.rider = true
    train.seat = seat or 0
    train.passenger = (train.seat or 0) > 0
    return true
end

local function singleplayerDismount(train)
    local rr = rawget(_G, "RR")
    local ride = rr and rr.Ride
    if ride and ride.current == train and type(ride.dismount) == "function" then
        pcall(ride.dismount, true)
    end
    -- Keep the official TrainEntity persistence state coherent even when the
    -- server-side Lua pass cannot see the client Ride table.
    train.rider = false
    train.seat = nil
    train.passenger = nil
    return true
end

-- The official MP board path remembers the username, drops any seat claim,
-- clears the driver's command sequence and broadcasts a resync.  Those helpers
-- are private in 2.1, so this adapter mirrors only those observed writes.
local function syncSeatAfterPut(train, player, onlineId, seat, role, authority)
    if authority == "singleplayer" then return end
    train._seatNames = train._seatNames or {}
    local name = playerName(player)
    if name then train._seatNames[onlineId] = name end
    if train._claims then
        if name then train._claims[name] = nil end
        for claimedName, claim in pairs(train._claims) do
            if type(claim) == "table" and number(claim.seat) == number(seat) then
                train._claims[claimedName] = nil
            end
        end
    end
    if role == "driver" and train._cmdSeq then
        train._cmdSeq[onlineId] = nil
    end
    safeCall(player, "setBlockMovement", true)
    safeCall(player, "setCanShout", false)
    safeCall(player, "setIsResting", true)
    local rr = rawget(_G, "RR")
    if rr and rr.ServerTrain and type(rr.ServerTrain.markResync) == "function" then
        pcall(rr.ServerTrain.markResync, train)
    end
end

local function forgetTrainSeat(train, player, onlineId, authority)
    authority = authority or authorityForTrain(train)
    local role, seat = playerRole(train, onlineId)
    if authority == "singleplayer" then
        if role == "external" then return role, seat end
        singleplayerDismount(train)
        safeCall(player, "setBlockMovement", false)
        safeCall(player, "setCanShout", true)
        safeCall(player, "setIsResting", false)
        return role, seat
    end
    if role == "driver" then
        train.driver = nil
        train.throttle = 0
        train.brakeInput = 1
        -- Match the official release cleanup for a driver being moved into
        -- the RV: an in-flight starter/shutdown latch must not continue after
        -- the cab is empty, and a horn cannot remain latched by a vanished
        -- driver.  The private fields are the same fields RR_ServerTrain's
        -- release branch clears on 2.1.
        train._stopping, train._stopHold = nil, nil
        train._starting, train._startEnv, train._startPlayer = nil, nil, nil
        if train.engine and not train.engine.running
            and (train.engine.phase == "priming"
                or train.engine.phase == "cranking") then
            train.engine.phase = "off"
        end
        train.hornOn = false
        if train._cmdSeq then train._cmdSeq[onlineId] = nil end
    elseif role == "passenger" and train.passengers then
        train.passengers[onlineId] = nil
        for id in pairs(train.passengers) do
            if tostring(id) == tostring(onlineId) then train.passengers[id] = nil end
        end
    else
        return role, seat
    end
    if train._seatNames then
        train._seatNames[onlineId] = nil
        for id in pairs(train._seatNames) do
            if tostring(id) == tostring(onlineId) then train._seatNames[id] = nil end
        end
    end
    local name = player and playerName(player)
    if name and train._claims then train._claims[name] = nil end
    safeCall(player, "setBlockMovement", false)
    safeCall(player, "setCanShout", true)
    -- RR_ServerTrain.release also removes its transient cab shelter marker;
    -- clear the same server-side flags when the RV transaction removes a seat
    -- without sending Railroader's normal release command.
    safeCall(player, "setIsResting", false)
    if player then pcall(function() player:setBed(nil) end) end
    local rr = rawget(_G, "RR")
    if rr and rr.ServerTrain and type(rr.ServerTrain.markResync) == "function" then
        pcall(rr.ServerTrain.markResync, train)
    end
    return role, seat
end

local function putPassenger(train, player, onlineId, seat)
    if not train or seat == nil then return false end
    local authority = authorityForTrain(train)
    seat = integer(seat)
    if not seat or seat < 1 then return false end
    if authority == "singleplayer" then
        local mounted = singleplayerMount(train, seat)
        safeCall(player, "setBlockMovement", true)
        safeCall(player, "setCanShout", false)
        safeCall(player, "setIsResting", true)
        return mounted
    end
    train.passengers = train.passengers or {}
    for otherId, assigned in pairs(train.passengers) do
        if tostring(otherId) ~= tostring(onlineId) and number(assigned) == seat then
            return false
        end
    end
    train.passengers[onlineId] = seat
    syncSeatAfterPut(train, player, onlineId, seat, "passenger", authority)
    return true
end

local function putDriver(train, player, onlineId)
    if not train then return false end
    local authority = authorityForTrain(train)
    if authority == "singleplayer" then
        local mounted = singleplayerMount(train, 0)
        safeCall(player, "setBlockMovement", true)
        safeCall(player, "setCanShout", false)
        safeCall(player, "setIsResting", true)
        return mounted
    end
    if train.driver ~= nil then return false end
    train.driver = onlineId
    -- Match RR_ServerTrain's official board branch: taking the controls ends
    -- any debug cruise latch before the next simulation tick can re-open it.
    train._cruise, train._cruiseNotch = nil, nil
    syncSeatAfterPut(train, player, onlineId, 0, "driver", authority)
    return true
end

local function mapData()
    if not ModData then
        error(C.SAVE_REBUILD_REQUIRED)
    end
    local map
    if type(ModData.get) == "function" then
        local ok, value = pcall(ModData.get, C.RV_MAP_KEY)
        if not ok then error(C.SAVE_REBUILD_REQUIRED) end
        map = value
    elseif type(ModData.getOrCreate) == "function" then
        local ok, value = pcall(ModData.getOrCreate, C.RV_MAP_KEY)
        if not ok then error("Railroader RV map ModData is unavailable") end
        map = value
    else
        error("Railroader RV map ModData is unavailable")
    end
    if map == nil then
        if type(ModData.getOrCreate) ~= "function" then
            error("Railroader RV map ModData is unavailable")
        end
        local ok, value = pcall(ModData.getOrCreate, C.RV_MAP_KEY)
        if not ok or type(value) ~= "table" then
            error("Railroader RV map ModData is unavailable")
        end
        map = value
        map.schemaVersion = C.MAP_SCHEMA_VERSION
        map.locomotives = {}
        map.players = {}
    elseif type(map) ~= "table" then
        error(C.SAVE_REBUILD_REQUIRED)
    else
        local empty = true
        for _ in pairs(map) do
            empty = false
            break
        end
        if empty then
            -- An empty key is a new save's uninitialised map, not a persisted
            -- This is an empty new container.  Initialise only the current
            -- schema; a non-empty incompatible container is rejected above.
            map.schemaVersion = C.MAP_SCHEMA_VERSION
            map.locomotives = {}
            map.players = {}
        elseif integer(map.schemaVersion) ~= C.MAP_SCHEMA_VERSION
            or map.version ~= nil
            or type(map.locomotives) ~= "table"
            or type(map.players) ~= "table" then
            error(C.SAVE_REBUILD_REQUIRED)
        end
    end
    if validateMapSchema and not validateMapSchema(map) then
        error(C.SAVE_REBUILD_REQUIRED)
    end
    return map
end

local function transmitMap()
    if ModData and type(ModData.transmit) == "function" then
        pcall(ModData.transmit, C.RV_MAP_KEY)
    end
end

local function rvRegion()
    local minX = integer(C.TELEPORT_X) + integer(C.RV_REGION_MIN_OFFSET_X)
    local minY = integer(C.TELEPORT_Y) + integer(C.RV_REGION_MIN_OFFSET_Y)
    local size = integer(C.RV_REGION_SIZE)
    local minZ = integer(C.TELEPORT_Z) + integer(C.RV_MANAGED_MIN_Z_OFFSET)
    local maxZ = integer(C.TELEPORT_Z) + integer(C.RV_MANAGED_MAX_Z_OFFSET)
    return { minX = minX, minY = minY, maxX = minX + size,
        maxY = minY + size, minZ = minZ, maxZ = maxZ }
end

local function inRegion(position, region)
    if type(position) ~= "table" or type(region) ~= "table" then return false end
    local x, y, z = number(position.x), number(position.y), number(position.z)
    local minX, minY = number(region.minX), number(region.minY)
    local maxX, maxY = number(region.maxX), number(region.maxY)
    local minZ, maxZ = number(region.minZ), number(region.maxZ)
    if not x or not y or not z or not minX or not minY or not maxX or not maxY
        or not minZ or not maxZ then return false end
    return x >= minX and x < maxX and y >= minY and y < maxY
        and math.floor(z) >= math.floor(minZ)
        and math.floor(z) < math.floor(maxZ)
end

local function validRegion(region)
    if type(region) ~= "table" then return false end
    local allowed = { minX = true, minY = true, maxX = true, maxY = true,
        minZ = true, maxZ = true }
    for key in pairs(region) do if not allowed[key] then return false end end
    local size = integer(C.RV_REGION_SIZE)
    local minX, minY = integer(region.minX), integer(region.minY)
    local minZ, maxZ = integer(region.minZ), integer(region.maxZ)
    return minX ~= nil and minY ~= nil and integer(region.maxX) == minX + size
        and integer(region.maxY) == minY + size
        and minZ ~= nil and maxZ ~= nil and maxZ > minZ
        and minZ >= WORLD_MIN_Z and maxZ <= WORLD_MAX_Z + 1
end

local function mapOnlyKeys(value, expected)
    if type(value) ~= "table" then return false end
    local allowed = {}
    for i = 1, #expected do allowed[expected[i]] = true end
    for key in pairs(value) do if not allowed[key] then return false end end
    return true
end

local function validMapPosition(value, pose)
    local keys = pose and { "x", "y", "z", "dirX", "dirY" }
        or { "x", "y", "z" }
    local x, y, z = value and number(value.x), value and number(value.y),
        value and number(value.z)
    if not mapOnlyKeys(value, keys) or copyPosition(value) == nil
        or x == nil or y == nil or z == nil
        or z < WORLD_MIN_Z or z > WORLD_MAX_Z then
        return false
    end
    return not pose or number(value.dirX) ~= nil and number(value.dirY) ~= nil
end

local function validMapRelation(relation, requireLocoId)
    if type(relation) ~= "table"
        or not mapOnlyKeys(relation, { "schemaVersion", "locoId", "onlineId",
            "inside", "role", "seat", "enterPosition", "exitPosition" })
        or relation.locomotive ~= nil
        or relation.locoId ~= nil and type(relation.locoId) ~= "string"
        or requireLocoId == true and relation.locoId == nil
        or integer(relation.schemaVersion) ~= C.RV_RELATION_SCHEMA_VERSION
        or integer(relation.onlineId) == nil or integer(relation.onlineId) < 0
        or relation.role ~= nil and type(relation.role) ~= "string"
        or relation.seat ~= nil and integer(relation.seat) == nil
        or type(relation.inside) ~= "boolean" then
        return false
    end
    if relation.inside then
        return validMapPosition(relation.enterPosition, false)
    end
    return validMapPosition(relation.exitPosition, false)
end

local function validMappingRecord(record)
    if type(record) ~= "table" or record.generated ~= true
        or not mapOnlyKeys(record, { "schemaVersion", "generated", "locoId",
            "rvId", "generation", "region", "rvPosition", "enterPosition",
            "locoPosition", "boundarySchemaVersion", "bitmapVersion",
            "boundary", "managed", "players", "updatedAt" })
        or record.version ~= nil
        or integer(record.schemaVersion) ~= C.RV_RECORD_SCHEMA_VERSION
        or type(record.locoId) ~= "string" or record.locoId == ""
        or type(record.rvId) ~= "string" or record.rvId ~= record.locoId
        or integer(record.boundarySchemaVersion) ~= C.BOUNDARY_SCHEMA_VERSION
        or integer(record.bitmapVersion) ~= C.BITMAP_VERSION
        or integer(record.generation) == nil or integer(record.generation) < 1
        or integer(record.updatedAt) == nil or integer(record.updatedAt) < 1
        or not validRegion(record.region) then
        return false
    end
    if type(record.boundary) ~= "table"
        or type(record.players) ~= "table"
        or not validMapPosition(record.rvPosition, false)
        or not validMapPosition(record.enterPosition, false)
        or not validMapPosition(record.locoPosition, true)
        or not mapOnlyKeys(record.managed, { "originX", "originY", "width",
            "height", "minZ", "maxZ" })
        or type(record.boundary.managed) ~= "table"
        or integer(record.managed.originX) ~= integer(record.boundary.managed.originX)
        or integer(record.managed.originY) ~= integer(record.boundary.managed.originY)
        or integer(record.managed.width) ~= integer(record.boundary.managed.width)
        or integer(record.managed.height) ~= integer(record.boundary.managed.height)
        or integer(record.managed.minZ) ~= integer(record.boundary.managed.minZ)
        or integer(record.managed.maxZ) ~= integer(record.boundary.managed.maxZ) then
        return false
    end
    if Boundary and type(Boundary.registerGeneration) == "function" then
        local ok, valid = pcall(Boundary.registerGeneration,
            record.locoId, record.generation, record.boundary, nil)
        if not ok or valid ~= true then return false end
    else
        return false
    end
    for name, rider in pairs(record.players) do
        if type(name) ~= "string" or not validMapRelation(rider, false) then
            return false
        end
    end
    return true
end

local function validRecord(record)
    return validMappingRecord(record)
end

validateMapSchema = function(map)
    if type(map) ~= "table"
        or not mapOnlyKeys(map, { "schemaVersion", "locomotives", "players" })
        or integer(map.schemaVersion) ~= C.MAP_SCHEMA_VERSION
        or type(map.locomotives) ~= "table"
        or type(map.players) ~= "table" then
        return false
    end
    for key, record in pairs(map.locomotives) do
        if type(key) ~= "string" or not validMappingRecord(record)
            or tostring(record.locoId) ~= key then
            return false
        end
    end
    for name, relation in pairs(map.players) do
        if type(name) ~= "string" or not validMapRelation(relation, true) then
            return false
        end
        if relation.inside == true then
            local record = relation.locoId and recordForLoco(map, relation.locoId)
            if not record or type(record.players) ~= "table"
                or type(record.players[name]) ~= "table"
                or record.players[name].inside ~= true then
                return false
            end
        end
    end
    return true
end

recordForLoco = function(map, locoId)
    if not map or not map.locomotives or locoId == nil then return nil, nil end
    local wanted = tostring(locoId)
    for key, record in pairs(map.locomotives) do
        if type(record) == "table" and record.locoId ~= nil
            and tostring(record.locoId) == wanted then
            return record, key
        end
    end
    return nil, nil
end

-- BoundaryServer delegates its player lookup to this one narrow hook so it
-- cannot accidentally run a shallow/legacy map parser.  mapData() performs
-- the complete current-schema validation (including every mapping record and
-- both sides of every player relation) before this hook returns any geometry.
function Adapter.validateCurrentBoundaryPlayer(player)
    local identityId, name = playerId(player), playerName(player)
    if identityId == nil or not name then return nil end
    local mapOk, map = pcall(mapData)
    if not mapOk or type(map) ~= "table" then return nil end
    local relation = map.players[name]
    if type(relation) ~= "table" or relation.inside ~= true
        or integer(relation.onlineId) ~= identityId then
        return nil
    end
    local record = recordForLoco(map, relation.locoId)
    if not record or not validRecord(record) then return nil end
    local rider = type(record.players) == "table" and record.players[name] or nil
    if type(rider) ~= "table" or rider.inside ~= true
        or integer(rider.onlineId) ~= identityId then
        return nil
    end
    local server = RailroaderRV and RailroaderRV.Server
    if not server
        or type(server.currentRVManifestForBoundary) ~= "function"
        or type(server.currentRVRecordGeometryConsistent) ~= "function" then
        return nil
    end
    local manifestCallOk, manifestAccepted, manifest = pcall(
        server.currentRVManifestForBoundary, record.rvId, record.generation,
        record.bitmapVersion)
    if not manifestCallOk or manifestAccepted ~= true
        or type(manifest) ~= "table" then
        return nil
    end
    local geometryCallOk, geometryConsistent = pcall(
        server.currentRVRecordGeometryConsistent, record, manifest)
    if not geometryCallOk or geometryConsistent ~= true then return nil end
    return record.boundary, record, relation, {
        username = name, onlineId = identityId,
        key = tostring(identityId) .. ":" .. name,
    }
end

local function roofRepairRoomKey(record)
    if type(record) ~= "table" or record.locoId == nil
        or record.rvId == nil or tostring(record.rvId) == ""
        or tostring(record.rvId) ~= tostring(record.locoId)
        or integer(record.generation) == nil or integer(record.generation) < 1
        or integer(record.bitmapVersion) ~= C.BITMAP_VERSION then
        return nil
    end
    return tostring(record.rvId) .. ":" .. tostring(record.generation)
        .. ":" .. tostring(record.bitmapVersion)
end

local function isWallRemovalSource(source)
    return source == "object-about-to-be-removed"
        or source == "destroy-iso-thumpable"
        or source == "follow-up-wall-removal"
end

local function markSuppressedRoomTransition(pending)
    if type(pending) ~= "table" or not isWallRemovalSource(pending.source)
        or type(pending.roomKey) ~= "string" then
        return
    end
    suppressedRoomTransitions[pending.roomKey] = {
        roomKey = pending.roomKey,
        token = pending.relocationToken or pending.returnToken,
        expiresAtTick = (Adapter._ticks or 0)
            + ROOF_REPAIR_TRANSITION_SUPPRESSION_TICKS,
    }
end

local function consumeSuppressedRoomTransition(roomKey)
    local suppression = suppressedRoomTransitions[roomKey]
    if type(suppression) ~= "table" then return false end
    if (Adapter._ticks or 0) > (suppression.expiresAtTick or 0) then
        suppressedRoomTransitions[roomKey] = nil
        return false
    end
    suppressedRoomTransitions[roomKey] = nil
    print("[RailroaderRVTest] room transition suppressed room="
        .. tostring(roomKey) .. " token=" .. tostring(suppression.token)
        .. " reason=wall-removal-relocation")
    return true
end

-- The two removal hooks use only the stable coordinate/object-index event key
-- for the short duplicate-callback window.  Never retain userdata; the current
-- RV identity/room key owns the actual transaction below.
local function pruneRoofRepairDedupeState(now)
    now = integer(now) or (Adapter._ticks or 0)
    -- Follow-up expiry is paused while generation owns the shared scope.  If
    -- the mutex query is temporarily unavailable, fail closed by preserving
    -- the bounded queue until a later tick can classify it.
    local generationBusy = true
    if serverTransactionMutexStatus then
        local mutexCallOk, active = pcall(function()
            return select(1, serverTransactionMutexStatus())
        end)
        if mutexCallOk and type(active) == "boolean" then
            generationBusy = active
        end
    end
    for eventKey, seen in pairs(seenWallRemovalEvents) do
        if type(seen) ~= "table"
            or now > (integer(seen.expiresAtTick) or 0) then
            seenWallRemovalEvents[eventKey] = nil
        end
    end
    for roomKey, suppression in pairs(suppressedRoomTransitions) do
        if type(suppression) ~= "table"
            or now > (integer(suppression.expiresAtTick) or 0) then
            suppressedRoomTransitions[roomKey] = nil
        end
    end
    for roomKey, events in pairs(followUpWallRemovalEvents) do
        if type(events) ~= "table" then
            followUpWallRemovalEvents[roomKey] = nil
        else
            for eventKey, event in pairs(events) do
                local expiresAt = type(event) == "table"
                    and integer(event.expiresAtTick) or nil
                if type(event) ~= "table" or expiresAt == nil then
                    print("[RailroaderRVTest] wall removal follow-up cancelled room="
                        .. tostring(roomKey) .. " event=" .. tostring(eventKey)
                        .. " reason=malformed-follow-up")
                    events[eventKey] = nil
                elseif event.waitingForGeneration == true then
                    -- This event already entered the generation wait.  Its
                    -- old absolute expiry is deliberately inert until the
                    -- post-generation current-identity revalidation.
                elseif now > expiresAt then
                    -- Do not resurrect an event whose ordinary lease expired
                    -- before generation became active on this tick.
                    events[eventKey] = nil
                elseif generationBusy and type(event) == "table" then
                    event.waitingForGeneration = true
                end
            end
            local empty = true
            for _ in pairs(events) do empty = false; break end
            if empty then followUpWallRemovalEvents[roomKey] = nil end
        end
    end
end

local function wallRemovalEventKey(object, roomKey)
    if object == nil or type(roomKey) ~= "string" then return nil end
    local indexOk, index = call(object, "getObjectIndex")
    index = indexOk and integer(index) or nil
    if index ~= nil and index < 0 then index = nil end
    local squareOk, square = call(object, "getSquare")
    local x, y, z
    if squareOk and square then
        local xOk, squareX = call(square, "getX")
        local yOk, squareY = call(square, "getY")
        local zOk, squareZ = call(square, "getZ")
        if xOk and yOk and zOk then
            x, y, z = integer(squareX), integer(squareY), integer(squareZ)
        end
    end
    if x == nil or y == nil or z == nil then
        local xOk, objectX = call(object, "getX")
        local yOk, objectY = call(object, "getY")
        local zOk, objectZ = call(object, "getZ")
        if xOk and yOk and zOk then
            x, y, z = integer(objectX), integer(objectY), integer(objectZ)
        end
    end
    if x == nil or y == nil or z == nil then return nil end
    local coordinateKey = roomKey .. ":" .. tostring(x) .. ":" .. tostring(y)
        .. ":" .. tostring(z)
    if index ~= nil then
        -- Return both the object-index key and its coordinate alias.  The
        -- alias closes the common callback gap where the object index exists
        -- before removal but is unavailable in the later destroy callback.
        return coordinateKey .. ":" .. tostring(index), coordinateKey
    end
    -- Some direct destruction paths do not expose an object index.  A stable
    -- coordinate fallback keeps the same callback pair deduped while retaining
    -- distinct wall cells as independent follow-up events.  If even the
    -- authoritative coordinate is unavailable, the caller fails closed.
    return coordinateKey .. ":fallback-wall", coordinateKey
end

-- The repair is deliberately best-effort: a missing target chunk must not
-- reject an otherwise valid RV entry.  OnTick retries it after the player has
-- streamed the persisted room into the authoritative server cell.
local function repairRoofForPlayer(player, record, force, reason)
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.repairRoofVisuals) ~= "function" then
        return false, "roof repair service is unavailable"
    end
    local roomKey = roofRepairRoomKey(record)
    if not roomKey then return false, "RV generation key is unavailable" end
    local cached = roofRepairRooms[roomKey]
    local cacheMatches = type(cached) == "table"
        and tostring(cached.rvId) == tostring(record.rvId)
        and integer(cached.generation) == integer(record.generation)
        and integer(cached.bitmapVersion) == integer(record.bitmapVersion)
    if not force and cacheMatches then return true, "already repaired" end
    local ok, repaired, detail = pcall(server.repairRoofVisuals, player)
    if not ok then
        print("[RailroaderRVTest] roof visual repair error: " .. tostring(repaired))
        return false, tostring(repaired)
    end
    if repaired == true then
        roofRepairRooms[roomKey] = {
            roomKey = roomKey,
            rvId = tostring(record.rvId),
            generation = integer(record.generation),
            bitmapVersion = integer(record.bitmapVersion),
            updatedAtTick = Adapter._ticks or 0,
        }
        local name = playerName(player)
        if name then roofRepairPlayers[name .. ":" .. roomKey] = true end
        -- This is an authoritative add/remove application only.  The server
        -- cannot prove the client's rendered roof cache, so never label this
        -- line as visual success.
        print("[RailroaderRVTest] roof repair applied room=" .. roomKey
            .. " reason=" .. tostring(reason or "entry")
            .. " detail=" .. tostring(detail or "ok"))
        return true, detail
    end
    print("[RailroaderRVTest] roof visual repair deferred room=" .. roomKey
        .. " reason=" .. tostring(reason or "entry")
        .. ": " .. tostring(detail or "unknown"))
    return false, detail
end

local function pruneRoofRepairRooms(now)
    now = integer(now) or (Adapter._ticks or 0)
    for roomKey, cached in pairs(roofRepairRooms) do
        if type(cached) ~= "table"
            or type(cached.roomKey) ~= "string"
            or cached.roomKey ~= roomKey
            or now - (integer(cached.updatedAtTick) or 0)
                > ROOF_REPAIR_CACHE_TTL_TICKS then
            roofRepairRooms[roomKey] = nil
        end
    end
end

-- The generation transaction broadcasts a room guard, but an existing RV entry
-- or a newly connected player does not pass through that transaction.  Ask the
-- generic server layer to validate the current manifest/mapping identity and
-- send the current footprint only to this player.
local function armRoomOwnershipMonitor(player, record, reason)
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.armCurrentRoomOwnershipMonitor) ~= "function" then
        return false, "room ownership monitor service is unavailable"
    end
    local ok, armed, detail = pcall(server.armCurrentRoomOwnershipMonitor,
        player, record)
    if not ok then
        print("[RailroaderRVTest] room ownership monitor error: " .. tostring(armed))
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if armed ~= true then
        print("[RailroaderRVTest] room ownership monitor deferred reason="
            .. tostring(reason or "entry") .. ": " .. tostring(detail or "unknown"))
        return false, detail or "room ownership monitor could not be armed"
    end
    print("[RailroaderRVTest] room ownership monitor ready reason="
        .. tostring(reason or "entry"))
    return true
end

-- The reverse lookup intentionally starts with the passenger coordinate.  It
-- never asks a world-room API, a room identifier, or a generated object which
-- RV the player belongs to.  A current-schema mapping whose live locomotive
-- is temporarily absent is retained for the persisted
-- vehicle-pose exit.  Coordinates outside the target 100x100 region are a
-- separate outside-rv rejection and are never corrected by this adapter.
local function recordAtPlayerCoordinate(map, player)
    local position = playerPosition(player)
    if not position then return nil, nil, nil, "outside-rv" end
    local target = rvRegion()
    if not inRegion(position, target) then
        return nil, nil, nil, "outside-rv"
    end
    for key, record in pairs(map.locomotives or {}) do
        if type(record) == "table" and inRegion(position, record.region) then
            if not validMappingRecord(record) then
                error(C.SAVE_REBUILD_REQUIRED)
            end
            local train = findTrain(record.locoId)
            if train and trainPosition(train) then
                return record, key, train, "active-mapped"
            end
            return record, key, nil, "inactive-mapped"
        end
    end
    return nil, nil, nil, "unmapped-rv"
end

local function sendResult(player, ok, reason)
    local onlineId = playerId(player)
    if onlineId == nil then return end
    callGlobal("sendServerCommand", player, C.MOD_ID, C.COMMAND_RV_TELEPORT, {
        ok = ok == true, onlineId = onlineId, reason = reason,
    })
end

local function movePlayer(player, position, action, relation)
    if not player or not position then return false end
    local onlineId = playerId(player)
    if onlineId == nil then return false end
    local payload = {
            ok = true, action = action, onlineId = onlineId,
            x = position.x, y = position.y, z = position.z,
    }
    -- This is only a transition hint for the local Railroader adapter.  The
    -- server seat snapshot remains authoritative; no client coordinate/seat is
    -- accepted from this payload.
    if type(relation) == "table" then
        payload.locoId = relation.locoId
        payload.role = relation.role
        payload.seat = relation.seat
        if relation.rvId ~= nil and tostring(relation.rvId) ~= ""
            and integer(relation.generation) ~= nil
            and integer(relation.generation) >= 1
            and integer(relation.bitmapVersion) ~= nil
            and integer(relation.bitmapVersion) == C.BITMAP_VERSION then
            payload.rvId = tostring(relation.rvId)
            payload.generation = integer(relation.generation)
            payload.bitmapVersion = integer(relation.bitmapVersion)
        end
    end
    local sentCallOk, sentResult = callGlobal("sendServerCommand", player,
        C.MOD_ID, C.COMMAND_RV_TELEPORT, payload)
    local sent = sentCallOk and sentResult ~= false
    -- A single-player world has no network command channel.  Its official
    -- TrainEntity/Ride state is updated locally; the same call still sends the
    -- RVTeleport hint when the channel exists.  MP/co-op must have the command
    -- path or the transaction fails closed.
    if not sent and processIsServer() then return false end
    return safeCall(player, "teleportTo", position.x, position.y, position.z)
end

local function markPlayerOutside(map, record, key, player, position, seat, role)
    local name = playerName(player)
    if not name then return end
    local relation = map.players[name]
    if type(relation) ~= "table" then relation = {} end
    relation.locoId = record and tostring(record.locoId) or relation.locoId
    relation.onlineId = playerId(player)
    relation.schemaVersion = C.RV_RELATION_SCHEMA_VERSION
    relation.inside = false
    relation.role = role
    relation.seat = seat
    relation.exitPosition = copyPosition(position)
    map.players[name] = relation
    if record then
        if type(record.players) ~= "table" then
            error(C.SAVE_REBUILD_REQUIRED)
        end
        local rider = record.players[name]
        if type(rider) ~= "table" then rider = {} end
        rider.schemaVersion = C.RV_RELATION_SCHEMA_VERSION
        rider.onlineId = playerId(player)
        rider.inside = false
        rider.role = role
        rider.seat = seat
        rider.exitPosition = copyPosition(position)
        record.players[name] = rider
    end
end

local function markPlayerInside(map, record, key, player, sourcePosition,
    sourceRole, sourceSeat)
    local name = playerName(player)
    if not name then error("Railroader RV player username is unavailable") end
    local enterPosition = copyPosition(sourcePosition)
    if not enterPosition then error(C.SAVE_REBUILD_REQUIRED) end
    local relation = {
        schemaVersion = C.RV_RELATION_SCHEMA_VERSION,
        locoId = tostring(record.locoId),
        onlineId = playerId(player), inside = true,
        role = sourceRole, seat = sourceSeat,
        enterPosition = enterPosition,
    }
    map.players[name] = relation
    if type(record.players) ~= "table" then
        error(C.SAVE_REBUILD_REQUIRED)
    end
    record.players[name] = {
        schemaVersion = C.RV_RELATION_SCHEMA_VERSION,
        onlineId = relation.onlineId, inside = true,
        role = sourceRole, seat = sourceSeat,
        enterPosition = enterPosition,
    }
end

local function otherGeneratedRecord(map, locoId)
    local wanted = tostring(locoId)
    for _, record in pairs(map.locomotives or {}) do
        if validRecord(record) and tostring(record.locoId) ~= wanted then
            return record
        end
    end
    return nil
end

local function sourceWithinRange(player, train)
    local distance = hullDistance(player, train)
    local rr = rawget(_G, "RR")
    local officialReach = rr and rr.Ride and rr.Ride.MOUNT_REACH
    local reach = number(officialReach) or number(C.RV_MOUNT_REACH)
    return distance ~= nil and distance <= reach
end

local function requestData(train, player, role, seat, sourcePosition)
    local entryPosition = copyPosition(sourcePosition)
    local locoPosition = trainPose(train)
    if not entryPosition or not locoPosition then
        error(C.SAVE_REBUILD_REQUIRED)
    end
    return {
        locoId = tostring(trainId(train)), sourceRole = role, sourceSeat = seat,
        playerUsername = playerName(player), playerOnlineId = playerId(player),
        entryPosition = entryPosition,
        region = rvRegion(), rvPosition = {
            x = integer(C.TELEPORT_X) + 0.5,
            y = integer(C.TELEPORT_Y) + 0.5,
            z = integer(C.TELEPORT_Z),
        },
        locoPosition = locoPosition,
    }
end

local function removeSeatForEntry(train, player, onlineId)
    return forgetTrainSeat(train, player, onlineId)
end

local function enterExisting(player, train, record, key, sourceRole,
    sourceSeat, sourcePosition, map)
    local roofBlocked, roofReason = roofRepairTransactionBlocks(record.rvId)
    if roofBlocked then return false, roofReason end
    local geometryOk, geometryReason = currentGeometryGate(record)
    if not geometryOk then return false, geometryReason end
    if not Boundary or type(Boundary.beginTransition) ~= "function"
        or type(Boundary.completeTransition) ~= "function" then
        return false, "RV boundary entry service is unavailable"
    end
    local onlineId = playerId(player)
    local target = copyPosition(record.rvPosition)
    if not target then return false, C.SAVE_REBUILD_REQUIRED end
    -- Re-arm the persistent client stale-room monitor before changing seats or
    -- moving the player.  A missing/incompatible current manifest therefore
    -- fails closed without performing the RV teleport.
    local monitorOk, monitorReason = armRoomOwnershipMonitor(player, record,
        "existing-entry")
    if not monitorOk then return false, monitorReason end
    local transitionToken = newTransitionToken("entry", record)
    if Boundary and type(Boundary.beginTransition) == "function" then
        local armed = Boundary.beginTransition(player, record.locoId,
            record.generation, transitionToken, "entry", record.bitmapVersion)
        if armed ~= true then
            return false, "RV boundary entry transition could not be armed"
        end
    end
    local removedRole, removedSeat = removeSeatForEntry(train, player, onlineId)
    if removedRole == "external" then removedSeat = nil end
    local oldRelation = map.players[playerName(player)]
    local oldRiders = {}
    for riderName, rider in pairs(record.players or {}) do
        oldRiders[riderName] = rider
    end
    markPlayerInside(map, record, key, player, sourcePosition, sourceRole,
        sourceSeat)
    local moved = movePlayer(player, target, "enter", {
        locoId = trainId(train), role = sourceRole, seat = sourceSeat,
        rvId = record.locoId, generation = record.generation,
        bitmapVersion = record.bitmapVersion,
    })
    if not moved then
        map.players[playerName(player)] = oldRelation
        record.players = oldRiders
        if removedRole == "driver" then
            putDriver(train, player, onlineId)
        elseif removedRole == "passenger" and removedSeat ~= nil then
            putPassenger(train, player, onlineId, removedSeat)
        end
        if Boundary and type(Boundary.clearPlayer) == "function" then
            Boundary.clearPlayer(player)
        end
        return false, "RV entry teleport failed"
    end
    if Boundary and type(Boundary.completeTransition) == "function" then
        Boundary.completeTransition(player, transitionToken)
    end
    record.locoPosition = trainPose(train) or record.locoPosition
    -- The server has just moved the player into the persisted RV footprint;
    -- perform the official add/remove-floor neighbour invalidation before the
    -- first repeat-entry frame is rendered.  A failed/deferred repair is
    -- retried by OnTick without rejecting the successful teleport.
    repairRoofForPlayer(player, record, true, "existing-entry")
    transmitMap()
    return true
end

local function enterPlayer(player, locoId)
    if not player or playerDead(player) then
        return false, "player is unavailable"
    end
    local onlineId, name = playerId(player), playerName(player)
    if onlineId == nil or not name then return false, "player identity is unavailable" end
    -- Check before removing a Railroader seat or changing mapping state.  The
    -- generation service repeats the global check authoritatively, but this
    -- early RV-specific gate avoids a temporary seat mutation on rejection.
    local roofBlocked, roofReason = roofRepairTransactionBlocks(locoId)
    if roofBlocked then return false, roofReason end
    local map = mapData()
    local existingRecord, existingKey, _, lookupState =
        recordAtPlayerCoordinate(map, player)
    if lookupState == "unmapped-rv" then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if existingRecord then return false, "player is already inside an RV" end
    local train = findTrain(locoId)
    if not train then return false, "target is not an active Railroader locomotive" end
    local role, seat = playerRole(train, onlineId)
    local moving = trainMoving(train)
    if moving and role ~= "passenger" then
        return false, role == "driver" and "driver cannot enter while moving"
            or "outside player cannot enter a moving locomotive"
    end
    if role == "external" and not sourceWithinRange(player, train) then
        return false, "player is outside locomotive interaction range"
    end
    local sourcePosition = role == "external" and playerPosition(player)
        or seatPosition(train, seat or 0) or playerPosition(player)
    if not sourcePosition then return false, "entry position is unavailable" end

    local record, key = recordForLoco(map, trainId(train))
    if record and validRecord(record) then
        return enterExisting(player, train, record, key, role, seat,
            sourcePosition, map)
    end
    if otherGeneratedRecord(map, trainId(train)) then
        return false, "the RV is already assigned to another locomotive"
    end

    -- A passenger is removed before the staging relocation.  Otherwise the
    -- official seat pin would immediately drag the player back to the moving
    -- locomotive while the generation stream is loading.
    local removedRole, removedSeat = removeSeatForEntry(train, player, onlineId)
    local data = requestData(train, player, role, seat, sourcePosition)
    data.removedRole, data.removedSeat = removedRole, removedSeat
    data.sourcePosition = copyPosition(sourcePosition)
    local rv = RailroaderRV.Server
    if not rv or type(rv.requestRailroaderGeneration) ~= "function" then
        if removedRole == "driver" then putDriver(train, player, onlineId) end
        if removedRole == "passenger" and removedSeat then
            putPassenger(train, player, onlineId, removedSeat)
        end
        return false, "RV generation transaction is unavailable"
    end
    local queued, reason = rv.requestRailroaderGeneration(player, data)
    if not queued then
        if removedRole == "driver" then putDriver(train, player, onlineId) end
        if removedRole == "passenger" and removedSeat then
            putPassenger(train, player, onlineId, removedSeat)
        end
        return false, reason or "RV generation request was refused"
    end
    return true
end

local function restoreAfterGenerationFailure(player, data)
    if type(data) ~= "table" or not player then return end
    local train = findTrain(data.locoId)
    local onlineId = playerId(player)
    if train and onlineId ~= nil then
        local role = data.removedRole
        if role == "driver" and train.driver == nil then
            putDriver(train, player, onlineId)
        elseif role == "passenger" and data.removedSeat ~= nil
            and seatForPlayer(train, onlineId) == nil then
            local occupied = false
            for _, assigned in pairs(train.passengers or {}) do
                if number(assigned) == number(data.removedSeat) then occupied = true end
            end
            if not occupied then putPassenger(train, player, onlineId, data.removedSeat) end
        end
    end
    local source = copyPosition(data.sourcePosition)
    if source then
        movePlayer(player, source, "generation-failed", {
            locoId = data.locoId, role = data.sourceRole, seat = data.sourceSeat,
            rvId = data.rvId, generation = data.generation,
            bitmapVersion = data.bitmapVersion,
        })
    end
    if Boundary and type(Boundary.clearPlayer) == "function" then
        Boundary.clearPlayer(player)
    end
end

local function commitGeneration(player, data, prepared)
    local map = mapData()
    local locoId = tostring(data.locoId)
    local generation = integer(prepared and prepared.generation)
    if not generation or not Boundary
        or type(prepared and prepared.boundary) ~= "table"
        or type(Boundary.registerGeneration) ~= "function"
        or not Boundary.registerGeneration(locoId, generation,
            prepared.boundary, nil) then
        return false, "RV boundary manifest registration failed"
    end
    local record, key = recordForLoco(map, locoId)
    if not record then
        key, record = locoId, {}
        map.locomotives[key] = record
    end
    local train = findTrain(locoId)
    record.schemaVersion = C.RV_RECORD_SCHEMA_VERSION
    record.generated = true
    record.locoId = locoId
    record.rvId = locoId
    record.generation = generation
    if not validRegion(data.region) then return false, C.SAVE_REBUILD_REQUIRED end
    record.region = {
        minX = integer(data.region.minX), minY = integer(data.region.minY),
        maxX = integer(data.region.maxX), maxY = integer(data.region.maxY),
        minZ = integer(data.region.minZ), maxZ = integer(data.region.maxZ),
    }
    record.rvPosition = copyPosition(data.rvPosition)
    record.enterPosition = copyPosition(data.entryPosition)
    record.locoPosition = train and trainPose(train) or copyPose(data.locoPosition)
    record.boundarySchemaVersion = C.BOUNDARY_SCHEMA_VERSION
    record.bitmapVersion = C.BITMAP_VERSION
    record.boundary = prepared.boundary
    record.managed = prepared.boundary.managed
    if not record.rvPosition or not record.enterPosition
        or not record.locoPosition
        or number(record.locoPosition.dirX) == nil
        or number(record.locoPosition.dirY) == nil then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    if type(record.players) ~= "table" then record.players = {} end
    if not Boundary.registerGeneration(locoId, record.generation,
        prepared.boundary, record) then
        return false, "RV boundary manifest registration failed"
    end
    record.updatedAt = os.time()
    markPlayerInside(map, record, key, player,
        data.entryPosition, data.sourceRole, data.sourceSeat)
    -- RV_Server owns the transition close after FinalRelocateAck and the
    -- current-manifest readiness proof. Do not release the lease from this
    -- mapping commit hook before that final client proof.
    repairRoofForPlayer(player, record, true, "generation-entry")
    transmitMap()
    return true
end

local function validateGeneration(player, data)
    if not player or playerDead(player) then return false, "player is dead" end
    local train = data and findTrain(data.locoId)
    if not train then return false, "locomotive disappeared during generation" end
    if data.sourceRole ~= "passenger" and trainMoving(train) then
        return false, "locomotive started moving before RV generation completed"
    end
    return true
end

local function exitPlayer(player)
    if not player or playerDead(player) then
        return false, "player is unavailable"
    end
    if not Boundary or type(Boundary.beginTransition) ~= "function"
        or type(Boundary.completeTransition) ~= "function" then
        return false, "RV boundary exit service is unavailable"
    end
    local map = mapData()
    local record, key, train, lookupState =
        recordAtPlayerCoordinate(map, player)
    if lookupState == "outside-rv" then
        return false, "player is outside the RV area"
    end
    if not record then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local roofBlocked, roofReason = roofRepairTransactionBlocks(record.rvId)
    if roofBlocked then return false, roofReason end
    local geometryOk, geometryReason = currentGeometryGate(record)
    if not geometryOk then return false, geometryReason end
    if not train then
        local target = persistedBesidePosition(record)
        if not target then return false, C.SAVE_REBUILD_REQUIRED end
        -- The mapping is valid but the locomotive is inactive/unloaded.  Do
        -- not invent a driver/passenger seat; use only a persisted beside
        -- target and retain the explicit state for diagnostics and tests.
        if lookupState ~= "inactive-mapped" then return false, C.SAVE_REBUILD_REQUIRED end
        local transitionToken = newTransitionToken("exit", record)
        if Boundary and type(Boundary.beginTransition) == "function" then
            local armed = Boundary.beginTransition(player, record.locoId,
                record.generation, transitionToken, "exit", record.bitmapVersion)
            if armed ~= true then
                return false, "RV boundary exit transition could not be armed"
            end
        end
        local moved = movePlayer(player, target, "exit", {
            locoId = record.locoId, role = "beside", seat = nil,
            rvId = record.locoId, generation = record.generation,
            bitmapVersion = record.bitmapVersion,
        })
        if not moved then
            if Boundary and type(Boundary.completeTransition) == "function" then
                Boundary.completeTransition(player, transitionToken)
            end
            return false, "inactive locomotive exit teleport failed"
        end
        markPlayerOutside(map, record, key, player, target, nil, "beside")
        if Boundary and type(Boundary.clearPlayer) == "function" then
            Boundary.clearPlayer(player)
        end
        transmitMap()
        return true
    end
    local onlineId = playerId(player)
    if onlineId == nil then return false, "player identity is unavailable" end
    local moving = trainMoving(train)
    local seat, role, target
    if moving then
        seat = freePassengerSeat(train)
        if not seat then return false, "all passenger positions are occupied" end
        target = seatPosition(train, seat)
        role = "passenger"
    else
        seat = freePassengerSeat(train)
        if seat then
            target, role = seatPosition(train, seat), "passenger"
        elseif train.driver == nil then
            target, role, seat = seatPosition(train, 0), "driver", 0
        else
            target, role = besidePosition(train), "beside"
            seat = nil
        end
    end
    if not target then return false, "locomotive exit position is unavailable" end

    local transitionToken = newTransitionToken("exit", record)
    if Boundary and type(Boundary.beginTransition) == "function" then
        local armed = Boundary.beginTransition(player, record.locoId,
            record.generation, transitionToken, "exit", record.bitmapVersion)
        if armed ~= true then
            return false, "RV boundary exit transition could not be armed"
        end
    end

    local assigned = false
    if role == "passenger" then assigned = putPassenger(train, player, onlineId, seat)
    elseif role == "driver" then assigned = putDriver(train, player, onlineId) end
    if role ~= "beside" and not assigned then
        if Boundary and type(Boundary.completeTransition) == "function" then
            Boundary.completeTransition(player, transitionToken)
        end
        return false, "locomotive seat became occupied"
    end
    local moved = movePlayer(player, target, "exit", {
        locoId = trainId(train), role = role, seat = seat,
        rvId = record.locoId, generation = record.generation,
        bitmapVersion = record.bitmapVersion,
    })
    if not moved then
        if role ~= "beside" then forgetTrainSeat(train, player, onlineId) end
        if Boundary and type(Boundary.completeTransition) == "function" then
            Boundary.completeTransition(player, transitionToken)
        end
        return false, "RV exit teleport failed"
    end
    record.locoPosition = trainPose(train) or record.locoPosition
    markPlayerOutside(map, record, key, player, target, seat, role)
    if Boundary and type(Boundary.clearPlayer) == "function" then
        Boundary.clearPlayer(player)
    end
    transmitMap()
    return true
end

local function commandArgument(args, key)
    if args == nil then return nil end
    if type(args) == "table" then return args[key] end
    local ok, value = call(args, "get", key)
    return ok and value or nil
end

function Adapter.OnClientCommand(module, command, player, args)
    if module ~= C.MOD_ID then return end
    if command ~= C.COMMAND_RV_ENTER and command ~= C.COMMAND_RV_EXIT then return end
    local ok, result, reason
    if roofRepairOwnsPlayer(player) then
        result, reason = false, "roof repair refresh is in progress"
    elseif command == C.COMMAND_RV_ENTER then
        local locoId = commandArgument(args, "locoId")
        if locoId == nil then
            result, reason = false, "locomotive id is missing"
        else
            ok, result, reason = pcall(enterPlayer, player, locoId)
        end
    else
        ok, result, reason = pcall(exitPlayer, player)
    end
    if not ok then result, reason = false, result end
    if result ~= true then
        print("[RailroaderRVTest] Railroader RV command rejected: "
            .. tostring(reason or "unknown reason"))
        sendResult(player, false, reason or "request rejected")
    end
end

local function onlinePlayersSnapshot()
    local result, seen = {}, {}
    local ok, players = callGlobal("getOnlinePlayers")
    if ok and players then
        local sizeOk, size = call(players, "size")
        local count = integer(size)
        if sizeOk and count and count >= 0 then
            for index = 0, count - 1 do
                local playerOk, player = call(players, "get", index)
                if playerOk and player and not seen[player] then
                    seen[player] = true
                    result[#result + 1] = player
                end
            end
        elseif type(players) == "table" then
            for _, player in pairs(players) do
                if player and not seen[player] then
                    seen[player] = true
                    result[#result + 1] = player
                end
            end
        end
    end
    -- Single-player/co-op fallback when getOnlinePlayers is not exposed in the
    -- active Lua pass.  The server-side command path remains authoritative.
    if #result == 0 then
        local playerOk, player = callGlobal("getPlayer")
        if player then result[1] = player end
    end
    return result
end

local function resolveSavedPlayer(saved)
    if type(saved) ~= "table" or type(saved.identityKey) ~= "string"
        or saved.identityKey == "" then
        return false
    end
    local players = onlinePlayersSnapshot()
    for i = 1, #players do
        local player = players[i]
        local id, name = playerId(player), playerName(player)
        if id ~= nil and name ~= nil
            and tostring(id) .. ":" .. tostring(name) == saved.identityKey then
            saved.player = player
            return true
        end
    end
    return false
end

local function sentinelIdentity(player)
    local id, name = playerId(player), playerName(player)
    if id == nil or name == nil then return nil, nil, nil end
    return tostring(id) .. ":" .. tostring(name), id, name
end

local function queuedRoofRepairClaims(identityKey)
    if type(identityKey) ~= "string" or identityKey == "" then return false end
    for _, pending in pairs(pendingWallRoofRepairs) do
        if type(pending) == "table"
            and pending.relocationPhase ~= "complete" then
            if pending.identityKey == identityKey then return true end
            for _, saved in pairs(pending.players or {}) do
                if type(saved) == "table"
                    and saved.identityKey == identityKey then
                    return true
                end
            end
        end
    end
    return false
end

local function sentinelClaimState(server, identityKey)
    if queuedRoofRepairClaims(identityKey) then return true end
    if not server or type(server.isRelocationIdentityClaimed) ~= "function" then
        return nil
    end
    local ok, claimed = pcall(server.isRelocationIdentityClaimed, identityKey)
    if not ok or type(claimed) ~= "boolean" then return nil end
    return claimed
end

-- Enter/Exit and the sentinel use the same narrow stable-identity claim
-- query.  A queued grouped wall refresh owns every member identity in its
-- saved descriptor list, even when the original userdata has been replaced.
roofRepairOwnsPlayer = function(player)
    local identityKey = sentinelIdentity(player)
    if not identityKey then return false end
    local server = RailroaderRV and RailroaderRV.Server
    return sentinelClaimState(server, identityKey) == true
end

-- Read both halves of the service-wide transaction mutex before any adapter
-- path changes a seat, mapping, boundary lease or player position.  The roof
-- query deliberately receives no RV filter: one managed world scope cannot
-- safely run a second Enter/Exit or generation for another rvId.
serverTransactionMutexStatus = function()
    local server = RailroaderRV and RailroaderRV.Server
    if not server
        or type(server.isGenerationTransactionActive) ~= "function"
        or type(server.isRoofRepairTransactionActive) ~= "function" then
        return nil, nil, "transaction gate is unavailable"
    end
    local generationCallOk, generationActive = pcall(
        server.isGenerationTransactionActive)
    local roofCallOk, roofActive, roofReason = pcall(
        server.isRoofRepairTransactionActive, nil)
    if not generationCallOk or type(generationActive) ~= "boolean"
        or not roofCallOk or type(roofActive) ~= "boolean" then
        return nil, nil, C.SAVE_REBUILD_REQUIRED
    end
    return generationActive, roofActive, roofReason
end

-- Enter/Exit must honor the same server-owned roof mutex for every player in
-- the affected RV, not only the members captured by the grouped relocation.
-- A queued wall event is also held here: its member snapshot is already an
-- accepted operation and must not race a new mapping/geometry mutation.
roofRepairTransactionBlocks = function(rvId)
    local generationBusy, roofBusy, mutexReason =
        serverTransactionMutexStatus()
    if generationBusy == nil then
        return true, mutexReason
    end
    if generationBusy then
        return true, "RV generation transaction is in progress"
    end
    if roofBusy then
        return true, type(mutexReason) == "string" and mutexReason ~= ""
            and mutexReason or "roof repair refresh is in progress"
    end
    for _, pending in pairs(pendingWallRoofRepairs) do
        if type(pending) ~= "table" then
            return true, C.SAVE_REBUILD_REQUIRED
        end
        if pending.relocationPhase ~= "complete" then
            return true, "roof repair refresh is in progress (rvId="
                .. tostring(pending.rvId or "unknown") .. ")"
        end
    end
    for _, events in pairs(followUpWallRemovalEvents) do
        if type(events) ~= "table" then
            return true, C.SAVE_REBUILD_REQUIRED
        end
        for _, event in pairs(events) do
            if type(event) ~= "table" then
                return true, C.SAVE_REBUILD_REQUIRED
            end
            local expiresAt = integer(event.expiresAtTick)
            if expiresAt == nil then return true, C.SAVE_REBUILD_REQUIRED end
            if expiresAt >= (Adapter._ticks or 0) then
                return true, "roof repair refresh is in progress (rvId="
                    .. tostring(event.rvId or "unknown") .. ")"
            end
        end
    end
    return false
end

-- Enter/Exit must prove that the mapping record and the current persisted
-- manifest still describe one complete geometry before arming a boundary,
-- changing map.players/record.players, or sending a teleport.  The server
-- hook is intentionally mandatory; no shallow adapter fallback is safe.
currentGeometryGate = function(record)
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.validateCurrentRVRecord) ~= "function" then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local callOk, accepted = pcall(server.validateCurrentRVRecord, record)
    if not callOk or accepted ~= true then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    return true
end

local function sentinelWarn(identityKey, reason)
    if type(reason) ~= "string" or reason == "" then
        reason = C.SAVE_REBUILD_REQUIRED
    end
    if relocationSentinelWarnings[identityKey] == reason then return end
    relocationSentinelWarnings[identityKey] = reason
    print("[RailroaderRVTest] relocation sentinel refused identity="
        .. tostring(identityKey) .. " reason=" .. reason)
end

local function sentinelRelationsConsistent(map, record)
    if type(map) ~= "table" or type(record) ~= "table"
        or type(map.players) ~= "table" or type(record.players) ~= "table" then
        return false
    end
    local wanted = tostring(record.rvId or record.locoId or "")
    if wanted == "" then return false end
    for name, rider in pairs(record.players) do
        if type(name) ~= "string" or not validMapRelation(rider, false) then
            return false
        end
        local relation = map.players[name]
        if rider.inside == true then
            if type(relation) ~= "table" or relation.inside ~= true
                or tostring(relation.locoId) ~= wanted
                or integer(relation.onlineId) ~= integer(rider.onlineId) then
                return false
            end
        elseif type(relation) == "table" and relation.inside == true
            and tostring(relation.locoId) == wanted then
            return false
        end
    end
    for name, relation in pairs(map.players) do
        if type(relation) ~= "table" or not validMapRelation(relation, true) then
            return false
        end
        if relation.inside == true and tostring(relation.locoId) == wanted then
            local rider = record.players[name]
            if type(rider) ~= "table" or rider.inside ~= true
                or integer(rider.onlineId) ~= integer(relation.onlineId) then
                return false
            end
        end
    end
    return true
end

local function sentinelBitmapAndCenter(record)
    if type(record) ~= "table" or type(record.managed) ~= "table"
        or type(record.boundary) ~= "table"
        or type(record.boundary.bitmap) ~= "table" or not Bitmap then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local managed = record.managed
    local originX, originY = integer(managed.originX), integer(managed.originY)
    local width, height = integer(managed.width), integer(managed.height)
    local minZ, maxZ = integer(managed.minZ), integer(managed.maxZ)
    if originX == nil or originY == nil or width ~= integer(C.RV_MANAGED_WIDTH)
        or height ~= integer(C.RV_MANAGED_HEIGHT) or minZ == nil or maxZ == nil
        or maxZ <= minZ then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local decodeOk, bitmap = pcall(Bitmap.decode, record.boundary.bitmap)
    local bitmapValidOk, bitmapValid = false, false
    if decodeOk and type(bitmap) == "table"
        and type(Bitmap.validate) == "function" then
        bitmapValidOk, bitmapValid = pcall(Bitmap.validate, bitmap)
    end
    if not decodeOk or type(bitmap) ~= "table" or not bitmapValidOk
        or bitmapValid ~= true
        or integer(bitmap.bitmapVersion) ~= C.BITMAP_VERSION
        or integer(bitmap.originX) ~= originX or integer(bitmap.originY) ~= originY
        or integer(bitmap.width) ~= width or integer(bitmap.height) ~= height
        or integer(bitmap.minZ) ~= minZ or integer(bitmap.maxZ) ~= maxZ then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local centerX = originX + math.floor(width / 2)
    local centerY = originY + math.floor(height / 2)
    local rvPosition = copyPosition(record.rvPosition)
    if not rvPosition or math.floor(rvPosition.x) ~= centerX
        or math.floor(rvPosition.y) ~= centerY
        or math.floor(rvPosition.z) ~= integer(C.TELEPORT_Z) then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local activeX, activeY, activeZ = math.floor(rvPosition.x),
        math.floor(rvPosition.y), math.floor(rvPosition.z)
    if not Bitmap.containsScope(bitmap, activeX, activeY, activeZ)
        or not Bitmap.isActive(bitmap, activeX, activeY, activeZ) then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    return true, {
        bitmap = bitmap, centerX = centerX, centerY = centerY,
        centerZ = integer(C.TELEPORT_Z),
    }
end

-- A mapping record and the current manifest may share an identity while still
-- carrying different bitmap snapshots.  The sentinel must not choose a target
-- from one snapshot and arm a boundary from the other, so compare the complete
-- current bitmap contract before accepting a candidate.
local function sentinelRecordManifestConsistent(record, manifest)
    local server = RailroaderRV and RailroaderRV.Server
    local checker = server and server.currentRVRecordGeometryConsistent
    if type(checker) ~= "function" then return false end
    local ok, consistent = pcall(checker, record, manifest)
    return ok and consistent == true
end

local function sentinelRecordCandidate(map, player, server)
    local identityKey, onlineId, username = sentinelIdentity(player)
    if not identityKey then return nil, nil, "player identity is unavailable" end
    local position = playerPosition(player)
    if not position or math.floor(position.z) ~= RELOCATION_SENTINEL_Z then
        return nil, identityKey, nil
    end
    local candidates = {}
    local invalidReason = nil
    for _, record in pairs(map.locomotives or {}) do
        if type(record) == "table" then
            local centerOk, centerOrReason = sentinelBitmapAndCenter(record)
            local center = centerOk and centerOrReason or nil
            local generationMatch = center ~= nil
                and math.floor(position.x) == center.centerX
                and math.floor(position.y) == center.centerY
                and math.floor(position.z) == RELOCATION_SENTINEL_Z
            local roofMatch = center ~= nil
                and math.floor(position.x)
                    == center.centerX - ROOF_REPAIR_REMOTE_OFFSET_X
                and math.floor(position.y)
                    == center.centerY - ROOF_REPAIR_REMOTE_OFFSET_Y
                and math.floor(position.z)
                    == center.centerZ - ROOF_REPAIR_REMOTE_OFFSET_Z
            if generationMatch or roofMatch then
                if not validRecord(record) or not centerOk
                    or not sentinelRelationsConsistent(map, record) then
                    invalidReason = centerOrReason or C.SAVE_REBUILD_REQUIRED
                else
                    local manifestOk, manifestOrReason = false, nil
                    if server and type(server.currentRVManifestForRelocation)
                        == "function" then
                        local callOk, current, detail = pcall(
                            server.currentRVManifestForRelocation,
                            record.rvId, record.generation, record.bitmapVersion)
                        if callOk and current == true and type(detail) == "table" then
                            manifestOk, manifestOrReason = true, detail
                        else
                            manifestOk = false
                            manifestOrReason = type(detail) == "string" and detail
                                or type(current) == "string" and current
                                or C.SAVE_REBUILD_REQUIRED
                        end
                    end
                    if not manifestOk or type(manifestOrReason) ~= "table" then
                        invalidReason = type(manifestOrReason) == "string"
                            and manifestOrReason or C.SAVE_REBUILD_REQUIRED
                    elseif not sentinelRecordManifestConsistent(record,
                            manifestOrReason) then
                        invalidReason = C.SAVE_REBUILD_REQUIRED
                    else
                        candidates[#candidates + 1] = {
                            record = record, center = center,
                            generationKind = generationMatch and "generation"
                                or "roof",
                            onlineId = onlineId, username = username,
                            identityKey = identityKey,
                            sentinelPosition = {
                                x = position.x, y = position.y, z = position.z,
                            },
                        }
                    end
                end
            end
        end
    end
    if invalidReason ~= nil then
        return nil, identityKey, invalidReason
    end
    if #candidates == 0 then
        return nil, identityKey, "relocation sentinel matched no current RV records"
    end
    if #candidates ~= 1 then
        if #candidates > 1 then
            return nil, identityKey, "relocation sentinel matched multiple RV records"
        end
        return nil, identityKey, nil
    end
    local candidate = candidates[1]
    local relation = map.players[candidate.username]
    local rider = candidate.record.players[candidate.username]
    if type(relation) ~= "table" or type(rider) ~= "table"
        or relation.inside ~= true or rider.inside ~= true
        or tostring(relation.locoId) ~= tostring(candidate.record.rvId)
        or integer(relation.onlineId) ~= candidate.onlineId
        or integer(rider.onlineId) ~= candidate.onlineId then
        return nil, identityKey, C.SAVE_REBUILD_REQUIRED
    end
    return candidate, identityKey, nil
end

local function sentinelReturnToRV(candidate, player, map)
    local server = RailroaderRV and RailroaderRV.Server
    local record = candidate and candidate.record
    local relation = record and map.players[candidate.username]
    if not server or not record or type(relation) ~= "table" then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local identityKey = sentinelIdentity(player)
    if identityKey ~= candidate.identityKey then
        return false, "relocation sentinel player identity changed"
    end
    local expectedPosition = candidate.sentinelPosition
    local currentPosition = playerPosition(player)
    if type(expectedPosition) ~= "table" or not currentPosition
        or math.floor(currentPosition.x) ~= math.floor(expectedPosition.x)
        or math.floor(currentPosition.y) ~= math.floor(expectedPosition.y)
        or math.floor(currentPosition.z) ~= math.floor(expectedPosition.z) then
        return false, "relocation sentinel player left the temporary cell"
    end
    local claimedOk, claimed = pcall(server.isRelocationIdentityClaimed,
        identityKey)
    if not claimedOk or claimed ~= false then
        return false, claimedOk and "relocation sentinel identity is claimed"
            or C.SAVE_REBUILD_REQUIRED
    end
    local manifestOk, manifestOrReason = false, nil
    if type(server.currentRVManifestForRelocation) == "function" then
        local callOk, current, detail = pcall(
            server.currentRVManifestForRelocation,
            record.rvId, record.generation, record.bitmapVersion)
        if callOk and current == true and type(detail) == "table" then
            manifestOk, manifestOrReason = true, detail
        else
            manifestOk = false
            manifestOrReason = type(detail) == "string" and detail
                or type(current) == "string" and current
                or C.SAVE_REBUILD_REQUIRED
        end
    end
    if not manifestOk or type(manifestOrReason) ~= "table"
        or not sentinelRecordManifestConsistent(record, manifestOrReason)
        or not sentinelRelationsConsistent(map, record) then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local centerOk, centerOrReason = sentinelBitmapAndCenter(record)
    if not centerOk then return false, centerOrReason end
    local target = copyPosition(record.rvPosition)
    local activeOk, active = false, false
    if target and type(Bitmap.isActive) == "function" then
        activeOk, active = pcall(Bitmap.isActive, centerOrReason.bitmap,
            math.floor(target.x), math.floor(target.y), math.floor(target.z))
    end
    if not target
        or target.x ~= centerOrReason.centerX + 0.5
        or target.y ~= centerOrReason.centerY + 0.5
        or target.z ~= centerOrReason.centerZ
        or not activeOk or active ~= true
        or not usableCoordinate(target) then
        return false, C.SAVE_REBUILD_REQUIRED
    end
    local monitorOk, monitorReason = armRoomOwnershipMonitor(player, record,
        "relocation-sentinel")
    if not monitorOk then return false, monitorReason end
    local token = newTransitionToken("sentinel", record)
    local beginOk, armed = false, false
    if Boundary and type(Boundary.beginTransition) == "function"
        and type(Boundary.completeTransition) == "function" then
        beginOk, armed = pcall(Boundary.beginTransition, player, record.rvId,
            record.generation, token, "sentinel", record.bitmapVersion)
    end
    if not beginOk or armed ~= true then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            pcall(Boundary.clearPlayer, player)
        end
        return false, "relocation sentinel boundary transition could not be armed"
    end
    local beforeMoveIdentity = sentinelIdentity(player)
    local beforeMovePosition = playerPosition(player)
    local beforeMoveClaimOk, beforeMoveClaim = pcall(
        server.isRelocationIdentityClaimed, beforeMoveIdentity)
    if beforeMoveIdentity ~= candidate.identityKey
        or not beforeMovePosition
        or math.floor(beforeMovePosition.x) ~= math.floor(expectedPosition.x)
        or math.floor(beforeMovePosition.y) ~= math.floor(expectedPosition.y)
        or math.floor(beforeMovePosition.z) ~= math.floor(expectedPosition.z)
        or not beforeMoveClaimOk or beforeMoveClaim ~= false then
        if type(Boundary.clearPlayer) == "function" then
            pcall(Boundary.clearPlayer, player)
        end
        return false, beforeMoveClaimOk
            and "relocation sentinel identity became claimed"
            or C.SAVE_REBUILD_REQUIRED
    end
    local moved = movePlayer(player, target, "enter", {
        locoId = record.locoId, role = relation.role, seat = relation.seat,
        rvId = record.rvId, generation = record.generation,
        bitmapVersion = record.bitmapVersion,
    })
    if not moved then
        if type(Boundary.clearPlayer) == "function" then
            pcall(Boundary.clearPlayer, player)
        end
        return false, "relocation sentinel RV return teleport failed"
    end
    if type(Boundary.completeTransition) == "function" then
        local completeOk, completed = pcall(Boundary.completeTransition,
            player, token)
        if not completeOk or completed ~= true then
            if type(Boundary.clearPlayer) == "function" then
                pcall(Boundary.clearPlayer, player)
            end
            return false, "relocation sentinel boundary transition could not be completed"
        end
    end
    -- Do not repair, mutate mapping/player records, or alter manifest phase here.
    return true
end

local function warnSentinelPlayersAtTemporaryCell(reason)
    local safeReason = type(reason) == "string" and reason ~= "" and reason
        or C.SAVE_REBUILD_REQUIRED
    local players = onlinePlayersSnapshot()
    for i = 1, #players do
        local player = players[i]
        local identityKey = sentinelIdentity(player)
        local position = playerPosition(player)
        if identityKey and position
            and math.floor(position.z) == RELOCATION_SENTINEL_Z then
            sentinelWarn(identityKey, safeReason)
        end
    end
end

local function processStatelessRelocationSentinel()
    local now = Adapter._ticks or 0
    if RELOCATION_SENTINEL_INTERVAL_TICKS == nil
        or now % RELOCATION_SENTINEL_INTERVAL_TICKS ~= 0 then
        return
    end
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.isRelocationIdentityClaimed) ~= "function"
        or type(server.currentRVManifestForRelocation) ~= "function"
        or type(server.isGenerationTransactionActive) ~= "function"
        or type(server.isRoofRepairTransactionActive) ~= "function" then
        warnSentinelPlayersAtTemporaryCell(C.SAVE_REBUILD_REQUIRED)
        return
    end
    local generationCallOk, generationActive = pcall(
        server.isGenerationTransactionActive)
    local roofCallOk, roofActive = pcall(
        server.isRoofRepairTransactionActive, nil)
    if not generationCallOk or type(generationActive) ~= "boolean"
        or not roofCallOk or type(roofActive) ~= "boolean" then
        warnSentinelPlayersAtTemporaryCell(C.SAVE_REBUILD_REQUIRED)
        return
    end
    -- Ordinary transactions own the managed scope while they are moving or
    -- repairing players.  Let their authoritative phase loop finish first;
    -- the sentinel retries on its next fixed interval without competing for a
    -- player or a boundary lease.
    if generationActive or roofActive then return end
    local mapOk, map = pcall(mapData)
    if not mapOk or type(map) ~= "table" then
        warnSentinelPlayersAtTemporaryCell(mapOk and map or C.SAVE_REBUILD_REQUIRED)
        return
    end
    local players = onlinePlayersSnapshot()
    local present = {}
    for i = 1, #players do
        local player = players[i]
        local candidate, identityKey, reason
        local candidateCallOk, candidateResult, candidateIdentity, candidateReason =
            pcall(sentinelRecordCandidate, map, player, server)
        if candidateCallOk then
            candidate, identityKey, reason = candidateResult, candidateIdentity,
                candidateReason
        else
            identityKey = sentinelIdentity(player)
            reason = C.SAVE_REBUILD_REQUIRED
        end
        if identityKey then
            present[identityKey] = true
            if candidate and not relocationSentinelBusy[identityKey] then
                local untilTick = relocationSentinelCooldown[identityKey] or 0
                if now >= untilTick then
                    local claimed = sentinelClaimState(server, identityKey)
                    if claimed == nil then
                        sentinelWarn(identityKey, C.SAVE_REBUILD_REQUIRED)
                    elseif not claimed then
                        -- Recheck immediately before moving, after the full
                        -- current-schema candidate resolution.
                        local claimedAgain = sentinelClaimState(server, identityKey)
                        if claimedAgain == false then
                            relocationSentinelBusy[identityKey] = true
                            local returnCallOk, returned, returnReason = pcall(
                                sentinelReturnToRV, candidate, player, map)
                            if not returnCallOk then
                                returned, returnReason = false,
                                    C.SAVE_REBUILD_REQUIRED
                            end
                            local claimedAfter = sentinelClaimState(server,
                                identityKey)
                            relocationSentinelBusy[identityKey] = nil
                            relocationSentinelCooldown[identityKey] = now
                                + (RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS or 10)
                            if claimedAfter == nil then
                                sentinelWarn(identityKey, C.SAVE_REBUILD_REQUIRED)
                            elseif claimedAfter ~= false then
                                sentinelWarn(identityKey,
                                    "relocation sentinel identity became claimed")
                            elseif not returned then
                                sentinelWarn(identityKey, returnReason)
                            else
                                relocationSentinelWarnings[identityKey] = nil
                                print("[RailroaderRVTest] relocation sentinel returned identity="
                                    .. identityKey .. " rvId="
                                    .. tostring(candidate.record.rvId)
                                    .. " kind=" .. candidate.generationKind)
                            end
                        end
                    end
                end
            elseif reason ~= nil then
                sentinelWarn(identityKey, reason)
            end
        end
    end
    for identityKey in pairs(relocationSentinelCooldown) do
        if not present[identityKey] then
            relocationSentinelCooldown[identityKey] = nil
            relocationSentinelWarnings[identityKey] = nil
            relocationSentinelBusy[identityKey] = nil
        end
    end
end

-- On the server, the player square is authoritative.  Generated RV rooms are
-- represented by IsoRegions and may not have a static IsoRoom/RoomDef, so the
-- transition signal is the square's isInARoom() result; getRoom()/getRoomDef()
-- are sampled as supporting state and diagnostics only.
local function authoritativeRoomState(player)
    local squareOk, square = call(player, "getCurrentSquare")
    if not squareOk or not square then return nil end
    local roomOk, room = call(square, "getRoom")
    if not roomOk then return nil end
    local roomDefOk, roomDef = call(square, "getRoomDef")
    if not roomDefOk then return nil end
    local insideOk, inside = call(square, "isInARoom")
    if not insideOk or type(inside) ~= "boolean" then return nil end
    return {
        inRoom = inside == true,
        hasRoom = room ~= nil,
        hasRoomDef = roomDef ~= nil,
    }
end

local function repairInsidePlayers(map)
    local present = {}
    local observedRooms = {}
    local players = onlinePlayersSnapshot()
    for i = 1, #players do
        local player = players[i]
        local name = playerName(player)
        local relation = name and map.players[name] or nil
        if type(relation) == "table" and relation.inside == true then
            local record = recordForLoco(map, relation.locoId)
            local position = playerPosition(player)
            if record and validRecord(record) and position
                and inRegion(position, record.region) then
                local roomKey = roofRepairRoomKey(record)
                local presenceKey = roomKey and name
                    and (name .. ":" .. roomKey) or nil
                if presenceKey then present[presenceKey] = true end
                if roomKey then
                    local observed = observedRooms[roomKey]
                    if not observed then
                        observed = {
                            record = record,
                            inRoom = nil,
                            hasRoom = false,
                            hasRoomDef = false,
                            roomStateAvailable = false,
                        }
                        observedRooms[roomKey] = observed
                    end
                    local roomState = authoritativeRoomState(player)
                    if roomState then
                        if observed.inRoom == nil then
                            observed.inRoom = roomState.inRoom
                        else
                            observed.inRoom = observed.inRoom or roomState.inRoom
                        end
                        observed.hasRoom = observed.hasRoom or roomState.hasRoom
                        observed.hasRoomDef = observed.hasRoomDef
                            or roomState.hasRoomDef
                        observed.roomStateAvailable = true
                    end
                end
                local currentOnlineId = playerId(player)
                local reconnect = currentOnlineId ~= nil
                    and relation.onlineId ~= nil
                    and tostring(currentOnlineId) ~= tostring(relation.onlineId)
                local firstPresence = presenceKey == nil
                    or roofRepairPlayers[presenceKey] ~= true
                local monitorReady = false
                if presenceKey then
                    monitorReady = roomMonitorPlayers[presenceKey] == player
                    if not monitorReady then
                        monitorReady = armRoomOwnershipMonitor(player, record,
                            reconnect and "reconnect" or "presence")
                        if monitorReady then
                            roomMonitorPlayers[presenceKey] = player
                        end
                    end
                end
                -- A wall-removal transaction owns the player until its return
                -- ACK.  Do not run the ordinary presence repair concurrently
                -- while that player is temporarily relocated; the transaction
                -- itself performs the delayed 5/10/15-tick attempts.
                if monitorReady and not (roomKey
                    and pendingWallRoofRepairs[roomKey] ~= nil) then
                    repairRoofForPlayer(player, record, firstPresence or reconnect,
                        reconnect and "reconnect" or "presence")
                end
            end
        end
    end
    observeRoomTransitions(map, observedRooms)
    -- A later appearance of the same username is treated as a new connection,
    -- so the repair is retriggered even when the map generation is unchanged.
    for presenceKey in pairs(roofRepairPlayers) do
        if not present[presenceKey] then roofRepairPlayers[presenceKey] = nil end
    end
    for presenceKey in pairs(roomMonitorPlayers) do
        if not present[presenceKey] then roomMonitorPlayers[presenceKey] = nil end
    end
end

-- One matched event or authoritative room transition owns one schedule for
-- the complete current RV identity.  The schedule intentionally starts after
-- the event/transition so the asynchronous object, neighbour and IsoRegions
-- work has time to settle; it never persists or infers geometry.
scheduleRoofRepair = function(map, record, source, eventKey, coordinateKey)
    if type(map) ~= "table" or not validRecord(record) then return false end
    local roomKey = roofRepairRoomKey(record)
    if not roomKey then return false end
    local generationBusy, roofBusy = serverTransactionMutexStatus()
    if generationBusy == nil or generationBusy or roofBusy then
        -- The caller keeps an object event as a bounded follow-up when this
        -- is a transient global transaction conflict.  A room observation has
        -- no accepted event to mutate, so it simply retries on the next pass.
        return false
    end
    -- There is one shared managed world scope.  Do not queue a second roof
    -- transaction under another room key while the first one is still live.
    for activeRoomKey, pending in pairs(pendingWallRoofRepairs) do
        if type(pending) ~= "table" then return false end
        if pending.relocationPhase ~= "complete"
            and tostring(activeRoomKey) ~= tostring(roomKey) then
            return false
        end
    end
    if isWallRemovalSource(source) then
        -- An object event is authoritative evidence of a new wall operation.
        -- It also clears the one-shot suppression left by the prior cycle so
        -- a later independent removal can schedule normally.
        suppressedRoomTransitions[roomKey] = nil
    elseif source == "room-transition"
        and suppressedRoomTransitions[roomKey] ~= nil then
        return false
    end
    -- The room identity is the active-cycle owner.  A duplicate callback may
    -- observe the same pending table, but it never gets a second success
    -- result/token; once this table is retired, a later event is independent.
    if pendingWallRoofRepairs[roomKey] then return false end
    local players = insidePlayersForRecord
        and insidePlayersForRecord(map, record) or {}
    if #players == 0 then return false end

    local now = Adapter._ticks or 0
    pendingWallRoofRepairs[roomKey] = {
        roomKey = roomKey,
        player = players[1].player,
        players = players,
        rvId = tostring(record.rvId),
        generation = integer(record.generation),
        bitmapVersion = integer(record.bitmapVersion),
        identityKey = players[1].identityKey,
        returnPosition = players[1].originalPosition,
        startTick = now + 1,
        queuedDeadlineTick = now + ROOF_REPAIR_QUEUED_DEADLINE_TICKS,
        dueTicks = nil,
        nextAttempt = 1,
        relocationStarted = false,
        relocationPhase = "queued",
        source = tostring(source or "room-transition"),
        scheduledAtTick = now,
        wallEventKeys = {},
        wallEventKey = type(eventKey) == "string" and eventKey ~= ""
            and eventKey or nil,
        wallCoordinateKey = type(coordinateKey) == "string"
            and coordinateKey ~= "" and coordinateKey or nil,
    }
    if type(eventKey) == "string" and eventKey ~= "" then
        pendingWallRoofRepairs[roomKey].wallEventKeys[eventKey] = true
    end
    if type(coordinateKey) == "string" and coordinateKey ~= "" then
        pendingWallRoofRepairs[roomKey].wallEventKeys[coordinateKey] = true
    end
    print("[RailroaderRVTest] roof repair scheduled room=" .. roomKey
        .. " source=" .. tostring(source or "room-transition")
        .. " relocationStartTick=" .. tostring(now + 1)
        .. " attempts=" .. tostring(ROOF_REPAIR_ATTEMPTS)
        .. " delayTicks=" .. tostring(ROOF_REPAIR_DELAY_TICKS))
    return true
end

local function rememberFollowUpWallRemoval(record, roomKey, eventKey,
    coordinateKey, now, waitingForGeneration)
    if type(record) ~= "table" or type(roomKey) ~= "string"
        or type(eventKey) ~= "string" or eventKey == "" then
        return false
    end
    local events = followUpWallRemovalEvents[roomKey]
    if type(events) ~= "table" then
        events = {}
        followUpWallRemovalEvents[roomKey] = events
    end
    if events[eventKey] ~= nil then return false end
    local count = 0
    for _ in pairs(events) do count = count + 1 end
    if count >= WALL_REMOVAL_FOLLOWUP_MAX then
        print("[RailroaderRVTest] wall removal follow-up rejected room="
            .. roomKey .. " reason=bounded-queue")
        return false
    end
    events[eventKey] = {
        roomKey = roomKey,
        rvId = tostring(record.rvId),
        eventKey = eventKey,
        coordinateKey = coordinateKey,
        waitingForGeneration = waitingForGeneration == true,
        expiresAtTick = (now or Adapter._ticks or 0)
            + WALL_REMOVAL_FOLLOWUP_TICKS,
    }
    print("[RailroaderRVTest] wall removal follow-up queued room=" .. roomKey
        .. " event=" .. eventKey)
    return true
end

-- Both legal server-side removal paths pass the authoritative IsoThumpable
-- before it is detached.  In particular, 42.20.4's
-- SledgehammerDestroyPacket delegates to RemoveItemFromSquarePacket, which
-- raises OnObjectAboutToBeRemoved immediately before removeFromWorld and
-- removeFromSquare.  OnDestroyIsoThumpable is retained for direct thumpable
-- destruction paths and uses the same strict matcher.  Never infer ownership
-- from a coordinate, action name, or client payload.
local function queueWallRoofRepairForObject(object, source)
    if not processIsServer() or not Boundary
        or type(Boundary.isCurrentShellWall) ~= "function" then
        return false
    end
    local mapOk, map = pcall(mapData)
    if not mapOk or type(map) ~= "table" then return false end
    local match
    for _, record in pairs(map.locomotives or {}) do
        local wallOk, isCurrentWall = false, false
        if type(record) == "table" and record.rvId ~= nil
            and validRecord(record) then
            wallOk, isCurrentWall = pcall(Boundary.isCurrentShellWall,
                object, record.boundary)
        end
        if wallOk and isCurrentWall == true then
            if match then
                -- A duplicate current identity is not a reason to guess which
                -- mapping owns the object.  Leave the removal untouched and
                -- do not enqueue a cross-RV repair.
                return false
            end
            match = record
        end
    end
    if not match then return false end
    local roomKey = roofRepairRoomKey(match)
    if not roomKey then return false end

    local now = Adapter._ticks or 0
    local eventKey, coordinateKey = wallRemovalEventKey(object, roomKey)
    if eventKey == nil then
        print("[RailroaderRVTest] wall removal rejected room=" .. roomKey
            .. " reason=stable-event-key-unavailable")
        return false
    end
    local seen = eventKey and seenWallRemovalEvents[eventKey] or nil
    if not seen and coordinateKey then
        seen = seenWallRemovalEvents[coordinateKey]
    end
    if type(seen) == "table" and seen.roomKey == roomKey
        and now <= (seen.expiresAtTick or 0) then
        print("[RailroaderRVTest] wall removal event suppressed room="
            .. roomKey .. " source=" .. tostring(source))
        return false
    end
    if eventKey ~= nil then
        local seenEvent = {
            roomKey = roomKey,
            expiresAtTick = now + WALL_REMOVAL_EVENT_DEDUPE_TICKS,
        }
        seenWallRemovalEvents[eventKey] = seenEvent
        if coordinateKey then seenWallRemovalEvents[coordinateKey] = seenEvent end
    end

    -- The two events may be raised for one removal.  The room key is the
    -- current rvId:generation:bitmapVersion identity, so one delayed schedule
    -- collapses duplicates. A distinct stable event key during an active cycle
    -- is retained as a bounded follow-up instead of being swallowed.
    local pending = pendingWallRoofRepairs[roomKey]
    if pending then
        local duplicate = type(pending.wallEventKeys) == "table"
            and (pending.wallEventKeys[eventKey] == true
                or coordinateKey ~= nil
                    and pending.wallEventKeys[coordinateKey] == true)
        if not duplicate then
            local retained = rememberFollowUpWallRemoval(match, roomKey,
                eventKey, coordinateKey, now)
            duplicate = retained == false
        end
        print("[RailroaderRVTest] wall removal event "
            .. (duplicate and "suppressed" or "follow-up-retained")
            .. " room=" .. roomKey .. " source=" .. tostring(source))
        return false
    end
    local generationBusy, roofBusy, mutexReason =
        serverTransactionMutexStatus()
    if generationBusy == nil or generationBusy or roofBusy then
        -- Keep the accepted wall event in the bounded in-memory follow-up
        -- queue until the service-wide transaction releases its mutex.  This
        -- prevents a generation/roof race from turning a real removal into a
        -- silently lost refresh.
        local retained = rememberFollowUpWallRemoval(match, roomKey,
            eventKey, coordinateKey, now, generationBusy == true)
        print("[RailroaderRVTest] wall removal deferred room=" .. roomKey
            .. " reason=" .. tostring(mutexReason or "transaction-busy")
            .. " retained=" .. tostring(retained))
        return retained
    end
    local scheduled = scheduleRoofRepair(map, match, source, eventKey,
        coordinateKey)
    if scheduled then
        print("[RailroaderRVTest] wall removal matched room=" .. roomKey
            .. " source=" .. tostring(source or "object-about-to-be-removed"))
        print("[RailroaderRVTest] wall roof repair queued room=" .. roomKey
            .. " delayTicks=" .. tostring(ROOF_REPAIR_DELAY_TICKS)
            .. " attempts=" .. tostring(ROOF_REPAIR_ATTEMPTS)
            .. " source=" .. tostring(source or "object-about-to-be-removed"))
    end
    return scheduled
end

function Adapter.onObjectAboutToBeRemoved(object)
    queueWallRoofRepairForObject(object, "object-about-to-be-removed")
end

-- Some direct IsoThumpable destruction paths expose the object through the
-- OnDestroyIsoThumpable event.  The normal 42.20.4 sledgehammer packet is
-- covered by OnObjectAboutToBeRemoved above; this second hook is intentionally
-- a strict, de-duplicated supplement rather than a client-command path.
function Adapter.onDestroyIsoThumpable(object, _playerObj)
    queueWallRoofRepairForObject(object, "destroy-iso-thumpable")
end

-- Capture every live, current-schema player in the RV managed region before a
-- wall-removal refresh.  Coordinates and identity are read from the server;
-- the adapter passes only object references to RV_Server, which revalidates
-- each member before arming the remote relocation.
insidePlayersForRecord = function(map, record)
    local result = {}
    if type(map) ~= "table" or type(record) ~= "table"
        or type(record.players) ~= "table" then return result end
    local wanted = tostring(record.rvId or record.locoId)
    local players = onlinePlayersSnapshot()
    for i = 1, #players do
        local player = players[i]
        local name = playerName(player)
        local relation = name and map.players[name] or nil
        local rider = name and record.players[name] or nil
        local position = playerPosition(player)
        local currentOnlineId = playerId(player)
        if not playerDead(player)
            and type(relation) == "table" and relation.inside == true
            and type(rider) == "table" and rider.inside == true
            and tostring(relation.locoId) == wanted
            and integer(relation.onlineId) == integer(rider.onlineId)
            and position and inRegion(position, record.region)
            and (currentOnlineId == nil
                or integer(relation.onlineId) == currentOnlineId)
            and (currentOnlineId == nil
                or integer(rider.onlineId) == currentOnlineId) then
            result[#result + 1] = {
                player = player,
                identityKey = tostring(relation.onlineId) .. ":" .. tostring(name),
                originalPosition = copyPosition(position),
            }
        end
    end
    return result
end

observeRoomTransitions = function(map, observedRooms)
    for roomKey, observed in pairs(observedRooms) do
        local previous = roomTransitionStates[roomKey]
        if observed.roomStateAvailable
            and previous and previous.inRoom == true
            and observed.inRoom ~= true then
            local suppressed = consumeSuppressedRoomTransition(roomKey)
            local scheduled = false
            if not suppressed then
                scheduled = scheduleRoofRepair(map, observed.record, "room-transition")
            end
            print("[RailroaderRVTest] room transition detected room=" .. roomKey
                .. " previous=inside current=outside suppressed="
                .. tostring(suppressed) .. " scheduled=" .. tostring(scheduled))
        end
        if observed.roomStateAvailable then
            roomTransitionStates[roomKey] = {
                inRoom = observed.inRoom == true,
                hasRoom = observed.hasRoom == true,
                hasRoomDef = observed.hasRoomDef == true,
                observedAtTick = Adapter._ticks or 0,
            }
        end
    end
    -- Do not carry a player's previous room state across a missing presence,
    -- disconnect, scope exit, or identity change.
    for roomKey in pairs(roomTransitionStates) do
        if not observedRooms[roomKey] then
            local pending = pendingWallRoofRepairs[roomKey]
            local relocationActive = pending
                and pending.relocationPhase ~= "complete"
            if not relocationActive then
                roomTransitionStates[roomKey] = nil
                if pending then
                    pendingWallRoofRepairs[roomKey] = nil
                    print("[RailroaderRVTest] roof repair schedule cancelled room="
                        .. roomKey .. " reason=presence-lost")
                end
            end
        end
    end
    -- An object event can schedule after the previous 30-tick observation,
    -- so also cancel a schedule that has no prior transition-state entry.
    for roomKey in pairs(pendingWallRoofRepairs) do
        if not observedRooms[roomKey] then
            local pending = pendingWallRoofRepairs[roomKey]
            local relocationActive = pending
                and pending.relocationPhase ~= "complete"
            if not relocationActive then
                pendingWallRoofRepairs[roomKey] = nil
                print("[RailroaderRVTest] roof repair schedule cancelled room="
                    .. roomKey .. " reason=presence-lost")
            end
        end
    end
end

local function clearRoofRepairRuntimeState(rejectQueued)
    -- These are transient requests and observations only; no persisted map
    -- field is changed. Keep an active grouped relocation alive when map
    -- validation is unavailable: its in-memory return loop still owns members.
    roomTransitionStates = {}
    suppressedRoomTransitions = {}
    seenWallRemovalEvents = {}
    if rejectQueued == true then
        -- A confirmed current-schema failure is fail-closed: accepted
        -- follow-ups must not be replayed against an incompatible save.
        local followUpCount = 0
        for _, events in pairs(followUpWallRemovalEvents) do
            if type(events) == "table" then
                for _ in pairs(events) do followUpCount = followUpCount + 1 end
            end
        end
        if followUpCount > 0 then
            print("[RailroaderRVTest] wall removal follow-up queue cancelled count="
                .. tostring(followUpCount) .. " reason="
                .. C.SAVE_REBUILD_REQUIRED)
        end
        followUpWallRemovalEvents = {}
    end
    for roomKey in pairs(pendingWallRoofRepairs) do
        local pending = pendingWallRoofRepairs[roomKey]
        local relocationActive = pending
            and pending.relocationPhase ~= "complete"
        if not relocationActive then
            print("[RailroaderRVTest] roof repair schedule cancelled room="
                .. tostring(roomKey) .. " reason=" .. C.SAVE_REBUILD_REQUIRED)
            pendingWallRoofRepairs[roomKey] = nil
        end
    end
end

local function cancelPendingWallRoofRepair(roomKey, pending, reason)
    local server = RailroaderRV and RailroaderRV.Server
    if pending and pending.relocationStarted and server
        and type(server.cancelRoofRepairRelocation) == "function" then
        pcall(server.cancelRoofRepairRelocation, reason)
    end
    if pendingWallRoofRepairs[roomKey] == pending then
        pendingWallRoofRepairs[roomKey] = nil
    end
    print("[RailroaderRVTest] roof repair schedule cancelled room="
        .. tostring(roomKey) .. " reason=" .. tostring(reason))
end

-- Expire unstarted queued ownership before reading map data.  This keeps the
-- finite pre-relocation lease effective even during a transient ModData read
-- failure; no Boundary lease, Relocate or return action exists to unwind.
local function expireQueuedWallRoofRepairs(now)
    for roomKey, pending in pairs(pendingWallRoofRepairs) do
        if type(pending) == "table"
            and pending.relocationPhase == "queued"
            and pending.waitingForGeneration ~= true
            and pending.relocationStarted ~= true
            and pending.relocationToken == nil
            and pending.returnToken == nil then
            local deadline = integer(pending.queuedDeadlineTick)
            if deadline == nil then
                cancelPendingWallRoofRepair(roomKey, pending,
                    "malformed queued roof repair deadline")
            elseif now >= deadline then
                cancelPendingWallRoofRepair(roomKey, pending,
                    "queued roof repair member rebind deadline expired")
            end
        end
    end
end

local function processPendingWallRoofRepairGroup(map, pending, record, server,
    now)
    if type(pending.players) ~= "table" or #pending.players < 1 then
        cancelPendingWallRoofRepair(pending.roomKey, pending,
            "roof repair group has no saved authoritative players")
        return
    end
    -- No Relocate or Boundary lease exists while the phase is queued.  A
    -- disconnected member can therefore be safely abandoned after this
    -- bounded rebind window; temporary/repair/return phases never use this
    -- deadline and retain their existing in-memory retry context.
    if pending.relocationPhase == "queued"
        and pending.relocationStarted ~= true
        and pending.relocationToken == nil
        and pending.returnToken == nil then
        local queuedDeadline = integer(pending.queuedDeadlineTick)
        if queuedDeadline == nil then
            cancelPendingWallRoofRepair(pending.roomKey, pending,
                "malformed queued roof repair deadline")
            return
        end
        if now >= queuedDeadline then
            cancelPendingWallRoofRepair(pending.roomKey, pending,
                "queued roof repair member rebind deadline expired")
            return
        end
    end
    for i = 1, #pending.players do
        if not resolveSavedPlayer(pending.players[i]) then
            -- Keep the grouped transaction in memory until every stable
            -- identity has a live player object again.
            return
        end
    end
    if pending.relocationPhase == "queued" then
        if now >= (pending.startTick or now + 1) then
            local started, detail = beginRoofRepairPhase(nil, pending,
                "temporary")
            if not started then
                -- A second wall operation may be observed while the first
                -- group's return lease is still completing.  Keep this new
                -- queued operation for the next idle tick; dropping it here
                -- would turn a genuinely independent wall action into a
                -- lost refresh.  Schema/identity/API failures remain hard
                -- cancellations below.
                if detail == "another RV relocation or generation is in progress"
                    or detail == "requesting player disconnected or was replaced" then
                    pending.startTick = now + 1
                else
                    cancelPendingWallRoofRepair(pending.roomKey, pending, detail)
                end
            else
                pending.relocationStarted = true
                pending.relocationPhase = "temporary"
                pending.relocationToken = detail
                print("[RailroaderRVTest] roof repair group temporary relocation started room="
                    .. pending.roomKey .. " members="
                    .. tostring(#pending.players) .. " token=" .. tostring(detail))
            end
        end
        return
    end
    if pending.relocationPhase == "temporary" then
        local readyFn = type(server.roofRepairRelocationGroupReady) == "function"
            and server.roofRepairRelocationGroupReady
        local ready = readyFn and readyFn(pending.rvId, pending.generation,
            pending.bitmapVersion) or false
        if not ready then return end
        for i = 1, #pending.players do
            local saved = pending.players[i]
            if not resolveSavedPlayer(saved) then return end
            local arrival = server.consumeRoofRepairRelocationArrival(
                saved.player)
            if not arrival then return end
            saved.player = arrival.player or saved.player
            saved.remoteArrived = true
        end
        pending.relocationPhase = "repairing"
        pending.repairStartTick = now
        pending.dueTicks = {}
        pending.nextAttempt = 1
        for attempt = 1, ROOF_REPAIR_ATTEMPTS do
            pending.dueTicks[attempt] = now
                + attempt * ROOF_REPAIR_DELAY_TICKS
        end
        print("[RailroaderRVTest] roof repair group remote relocation ready room="
            .. pending.roomKey .. " members=" .. tostring(#pending.players)
            .. " target=rv-center-minus-offset dueTicks="
            .. table.concat(pending.dueTicks, ","))
        return
    end
    if pending.relocationPhase == "repairing" then
        local attempt = integer(pending.nextAttempt)
        local dueTick = attempt and pending.dueTicks
            and integer(pending.dueTicks[attempt]) or nil
        if not attempt or attempt < 1 or attempt > ROOF_REPAIR_ATTEMPTS
            or not dueTick then
            cancelPendingWallRoofRepair(pending.roomKey, pending,
                "malformed roof repair group remote wait schedule")
            return
        end
        if now < dueTick then return end
        -- Keep the complete group remote for the requested cross-tick cycle;
        -- repair is intentionally invoked only after every member returns.
        print("[RailroaderRVTest] roof repair group remote wait room="
            .. pending.roomKey .. " attempt=" .. tostring(attempt) .. "/"
            .. tostring(ROOF_REPAIR_ATTEMPTS) .. " result=deferred")
        pending.nextAttempt = attempt + 1
        if attempt >= ROOF_REPAIR_ATTEMPTS then
            local started, detail = beginRoofRepairPhase(nil, pending, "return")
            if not started then
                if detail == "requesting player disconnected or was replaced"
                    or detail == "another RV relocation or generation is in progress" then
                    pending.nextAttempt = attempt
                    return
                end
                cancelPendingWallRoofRepair(pending.roomKey, pending, detail)
            else
                pending.relocationPhase = "returning"
                pending.returnToken = detail
                pending.returnArrived = false
                pending.returnCompleted = {}
                pending.repairWorldApplied = false
                pending.repairCompleted = false
                pending.repairContextIndex = nil
                -- Repair is a continuously required post-return step.  This
                -- is only a retry cadence, never a deadline that can retire
                -- the in-memory transaction while the squares are unloaded.
                pending.repairRetryAtTick = now
                print("[RailroaderRVTest] roof repair group return relocation started room="
                    .. pending.roomKey .. " members="
                    .. tostring(#pending.players) .. " token=" .. tostring(detail))
            end
        end
        return
    end
    if pending.relocationPhase == "returning" then
        for i = 1, #pending.players do
            local saved = pending.players[i]
            if not saved.returnArrived then
                local arrival = server.consumeRoofRepairRelocationArrival(
                    saved.player)
                if arrival then
                    saved.player = arrival.player or saved.player
                    saved.returnArrived = true
                end
            end
        end
        local allArrived = true
        for i = 1, #pending.players do
            if not pending.players[i].returnArrived then
                allArrived = false
                break
            end
        end
        if not allArrived then return end

        -- Complete the authoritative return for every member before invoking
        -- any repair/refresh callback.  A repair exception or a temporarily
        -- unavailable chunk must never strand a player in the remote target.
        for i = 1, #pending.players do
            local saved = pending.players[i]
            if not pending.returnCompleted[i] then
                local completeCallOk, completed, detail = pcall(
                    server.completeRoofRepairRelocation, saved.player,
                    pending.returnToken)
                if completeCallOk and completed == true then
                    pending.returnCompleted[i] = true
                elseif completeCallOk then
                    print("[RailroaderRVTest] roof repair group return wait player="
                        .. tostring(saved.identityKey) .. " detail="
                        .. tostring(detail or completed))
                else
                    print("[RailroaderRVTest] roof repair group return error player="
                        .. tostring(saved.identityKey) .. " detail="
                        .. tostring(completed))
                end
            end
        end

        -- This is a hard phase barrier. A repair callback is never allowed
        -- to mask one member's failed/unfinished authoritative return.
        local allCompleted = true
        for i = 1, #pending.players do
            if not pending.returnCompleted[i] then
                allCompleted = false
                break
            end
        end
        if not allCompleted then return end

        -- This is the same server-authoritative roof/geometry repair path used
        -- by existing RV entry. It runs only after the physical return has
        -- been observed; every callback is bounded/isolated so it cannot
        -- interrupt the remaining members' return handling.
        local representative = pending.repairContextIndex
            and pending.players[pending.repairContextIndex] or nil
        if not representative then
            representative = pending.players[1]
            pending.repairContextIndex = 1
        end
        if pending.repairWorldApplied ~= true
            and now >= (pending.repairRetryAtTick or 0) then
            local loaded, loadedDetail = false,
                "roof repair squares are not loaded after return"
            local loadedCallOk, loadedResult, loadedReason = pcall(
                server.roofRepairSquaresLoaded, representative.player, record)
            if loadedCallOk then
                loaded, loadedDetail = loadedResult, loadedReason
            else
                loadedDetail = tostring(loadedResult)
            end
            if loaded == true then
                local repairCallOk, repaired, detail = pcall(
                    repairRoofForPlayer, representative.player, record, true,
                    "remote-reload-return")
                if not repairCallOk then
                    detail = tostring(repaired)
                    repaired = false
                end
                print("[RailroaderRVTest] roof repair returned room="
                    .. tostring(pending.roomKey) .. " result="
                    .. (repaired and "applied" or "deferred") .. " detail="
                    .. tostring(detail or "unknown"))
                if repaired == true then
                    pending.repairWorldApplied = true
                    pending.repairRetryAtTick = nil
                else
                    pending.repairRetryAtTick = now + ROOF_REPAIR_DELAY_TICKS
                    sendResult(representative.player, false,
                        detail or "roof repair after remote reload was deferred")
                end
            else
                pending.repairRetryAtTick = now + ROOF_REPAIR_DELAY_TICKS
                print("[RailroaderRVTest] roof repair after return deferred room="
                    .. tostring(pending.roomKey) .. " detail=" .. tostring(loadedDetail
                        or "roof repair squares are not loaded after return"))
            end
        end
        if pending.repairWorldApplied == true
            and pending.repairCompleted ~= true then
            local ackCallOk, acknowledged, ackDetail = pcall(
                server.completeRoofRepairRepair, representative.player,
                pending.returnToken)
            if ackCallOk and acknowledged == true then
                pending.repairCompleted = true
            else
                print("[RailroaderRVTest] roof repair completion remains pending room="
                    .. tostring(pending.roomKey) .. " detail="
                    .. tostring(ackCallOk and ackDetail or acknowledged))
            end
        end
        if allCompleted and pending.repairCompleted == true then
            pending.relocationPhase = "complete"
            markSuppressedRoomTransition(pending)
            pendingWallRoofRepairs[pending.roomKey] = nil
            roofRepairRooms[pending.roomKey] = nil
            print("[RailroaderRVTest] roof repair group transaction complete room="
                .. pending.roomKey .. " members=" .. tostring(#pending.players)
                .. " repair=applied return=acknowledged")
        end
        return
    end
    cancelPendingWallRoofRepair(pending.roomKey, pending,
        "unknown roof repair group transaction phase")
end

beginRoofRepairPhase = function(player, pending, phase)
    local server = RailroaderRV and RailroaderRV.Server
    if not server then
        return false, "roof repair relocation service is unavailable"
    end
    if type(pending.players) == "table" then
        if type(server.beginRoofRepairRelocationGroup) ~= "function" then
            return false, "roof repair group relocation service is unavailable"
        end
        local descriptors = {}
        for i = 1, #pending.players do
            local saved = pending.players[i]
            if not resolveSavedPlayer(saved) then return false, "requesting player disconnected or was replaced" end
            descriptors[#descriptors + 1] = {
                player = saved.player,
                identityKey = saved.identityKey,
            }
        end
        local ok, started, detail = pcall(
            server.beginRoofRepairRelocationGroup, {
                roomKey = pending.roomKey,
                rvId = pending.rvId,
                generation = pending.generation,
                bitmapVersion = pending.bitmapVersion,
                phase = phase,
                players = phase == "temporary" and descriptors or nil,
            })
        if not ok then return false, tostring(started) end
        if started ~= true then
            return false, detail or "roof repair group relocation was rejected"
        end
        return true, detail
    end
end

local function promoteFollowUpWallRemoval(map, roomKey)
    if pendingWallRoofRepairs[roomKey] ~= nil then return false end
    local events = followUpWallRemovalEvents[roomKey]
    if type(events) ~= "table" then return false end
    local now = Adapter._ticks or 0
    for eventKey, event in pairs(events) do
        if type(event) ~= "table" then
            events[eventKey] = nil
        elseif event.waitingForGeneration ~= true
            and now > (integer(event.expiresAtTick) or 0) then
            events[eventKey] = nil
        else
            local waitingForGeneration = event.waitingForGeneration == true
            local record = recordForLoco(map, event.rvId)
            if not record or not validRecord(record) then
                if waitingForGeneration then
                    print("[RailroaderRVTest] wall removal follow-up cancelled room="
                        .. tostring(roomKey) .. " event=" .. tostring(eventKey)
                        .. " reason=" .. C.SAVE_REBUILD_REQUIRED)
                end
                events[eventKey] = nil
            else
                local currentRoomKey = roofRepairRoomKey(record)
                if not currentRoomKey then
                    if waitingForGeneration then
                        print("[RailroaderRVTest] wall removal follow-up cancelled room="
                            .. tostring(roomKey) .. " event=" .. tostring(eventKey)
                            .. " reason=" .. C.SAVE_REBUILD_REQUIRED)
                    end
                    events[eventKey] = nil
                elseif currentRoomKey ~= roomKey then
                    -- Generation may replace the current identity while this
                    -- bounded follow-up is waiting.  Re-key it to the new
                    -- current record and let the next pass run the complete
                    -- schedule/schema/player validation; do not discard it as
                    -- an old room merely because the generation changed.
                    local currentEvents = followUpWallRemovalEvents[currentRoomKey]
                    if type(currentEvents) ~= "table" then
                        currentEvents = {}
                        followUpWallRemovalEvents[currentRoomKey] = currentEvents
                    end
                    if currentEvents[eventKey] == nil then
                        local count = 0
                        for _ in pairs(currentEvents) do count = count + 1 end
                        if count < WALL_REMOVAL_FOLLOWUP_MAX then
                            event.roomKey = currentRoomKey
                            event.rvId = tostring(record.rvId)
                            if waitingForGeneration then
                                -- The current record/rvId/generation/
                                -- bitmapVersion is now proven complete.  Give
                                -- this accepted event a fresh full lease.
                                event.expiresAtTick = now
                                    + ROOF_REPAIR_QUEUED_DEADLINE_TICKS
                                event.waitingForGeneration = nil
                            end
                            currentEvents[eventKey] = event
                            events[eventKey] = nil
                        elseif waitingForGeneration then
                            print("[RailroaderRVTest] wall removal follow-up cancelled room="
                                .. tostring(roomKey) .. " event="
                                .. tostring(eventKey)
                                .. " reason=bounded-queue-after-generation")
                            events[eventKey] = nil
                        end
                    else
                        if waitingForGeneration then
                            print("[RailroaderRVTest] wall removal follow-up cancelled room="
                                .. tostring(roomKey) .. " event="
                                .. tostring(eventKey)
                                .. " reason=duplicate-current-event-after-generation")
                        end
                        events[eventKey] = nil
                    end
                else
                    if waitingForGeneration then
                        -- Revalidation succeeded against the complete current
                        -- record.  Only now does the follow-up re-enter its
                        -- bounded offline/rebind wait.
                        event.expiresAtTick = now
                            + ROOF_REPAIR_QUEUED_DEADLINE_TICKS
                        event.waitingForGeneration = nil
                    end
                    local scheduled = scheduleRoofRepair(map, record,
                        "follow-up-wall-removal", eventKey,
                        event.coordinateKey)
                    if scheduled then
                        events[eventKey] = nil
                        return true
                    end
                    -- A transient busy/identity gate must not swallow a distinct
                    -- wall operation.  Keep the stable event until its explicit
                    -- expiry; a schema-invalid record is still rejected by the
                    -- normal current-only gate on the next pass.
                    event.lastAttemptTick = now
                    break
                end
            end
        end
    end
    local empty = true
    for _ in pairs(events) do empty = false; break end
    if empty then followUpWallRemovalEvents[roomKey] = nil end
    return false
end

-- A wall event can be accepted while the independent generation transaction
-- is already moving the same managed scope.  Keep the queued operation
-- entirely in memory, then re-read the current record after generation has
-- released its mutex; never start a roof group against the old generation.
local function revalidateQueuedRoofRepairAfterGeneration(map, roomKey,
    pending, now)
    if type(pending) ~= "table" or pending.relocationPhase ~= "queued" then
        return "ready"
    end
    local waitingForGeneration = pending.waitingForGeneration == true
    local deadline = integer(pending.revalidateUntilTick)
        or (now + WALL_REMOVAL_FOLLOWUP_TICKS)
    pending.revalidateUntilTick = deadline
    local record = recordForLoco(map, pending.rvId)
    local currentRoomKey = record and validRecord(record)
        and roofRepairRoomKey(record) or nil
    local identityMatches = currentRoomKey == roomKey
        and integer(record and record.generation) == integer(pending.generation)
        and integer(record and record.bitmapVersion)
            == integer(pending.bitmapVersion)
    if not waitingForGeneration and identityMatches then
        pending.revalidateUntilTick = nil
        return "ready"
    end
    if not waitingForGeneration then
        -- The adapter may run after RV_Server has completed a generation on
        -- the same game tick.  Detect that identity swap even when the prior
        -- tick could not mark the queue as waiting.
        if currentRoomKey == nil then return "ready" end
        pending.waitingForGeneration = true
        waitingForGeneration = true
    end
    if not record or not validRecord(record) then
        if now <= deadline then return "wait" end
        return "expired"
    end
    if not currentRoomKey then
        if now <= deadline then return "wait" end
        return "expired"
    end
    if currentRoomKey == roomKey
        and integer(record.generation) == integer(pending.generation)
        and integer(record.bitmapVersion) == integer(pending.bitmapVersion) then
        -- A generation-owned queue had its old lease paused rather than
        -- consumed.  Once the complete current identity is confirmed, start
        -- a fresh bounded rebind window; never carry the pre-generation
        -- deadline into the new generation.
        if waitingForGeneration then
            pending.queuedDeadlineTick = now
                + ROOF_REPAIR_QUEUED_DEADLINE_TICKS
        end
        pending.waitingForGeneration = nil
        pending.revalidateUntilTick = nil
        return "ready"
    end

    -- Re-capture all authoritative inside players and the exact current RV
    -- identity.  This preserves one event/one transaction while preventing a
    -- pre-generation return coordinate from being used after a swap.
    local players = insidePlayersForRecord(map, record)
    if #players == 0 then
        if now <= deadline then return "wait" end
        return "expired"
    end
    local existing = pendingWallRoofRepairs[currentRoomKey]
    if existing ~= nil and existing ~= pending then
        -- A room observation may have accepted a fresh current-generation
        -- schedule on the same tick.  Keep the older wall event as a bounded
        -- follow-up instead of overwriting that active transaction.
        local eventKey = pending.wallEventKey
        if type(eventKey) == "string" and eventKey ~= "" then
            rememberFollowUpWallRemoval(record, currentRoomKey, eventKey,
                pending.wallCoordinateKey, now)
            pendingWallRoofRepairs[roomKey] = nil
            return "revalidated"
        end
        return "wait"
    end
    pendingWallRoofRepairs[roomKey] = nil
    pending.roomKey = currentRoomKey
    pending.player = players[1].player
    pending.players = players
    pending.rvId = tostring(record.rvId)
    pending.generation = integer(record.generation)
    pending.bitmapVersion = integer(record.bitmapVersion)
    pending.identityKey = players[1].identityKey
    pending.returnPosition = players[1].originalPosition
    pending.startTick = now + 1
    pending.queuedDeadlineTick = now + ROOF_REPAIR_QUEUED_DEADLINE_TICKS
    pending.dueTicks = nil
    pending.nextAttempt = 1
    pending.relocationStarted = false
    pending.relocationPhase = "queued"
    pending.relocationToken = nil
    pending.returnToken = nil
    pending.waitingForGeneration = nil
    pending.revalidateUntilTick = nil
    pendingWallRoofRepairs[currentRoomKey] = pending
    print("[RailroaderRVTest] roof repair queue revalidated after generation room="
        .. currentRoomKey .. " source=" .. tostring(pending.source))
    return "revalidated"
end

local function processPendingWallRoofRepairs()
    local now = Adapter._ticks or 0
    local server = RailroaderRV and RailroaderRV.Server
    if not server or type(server.getRoofRepairRelocationState) ~= "function"
        or type(server.isGenerationTransactionActive) ~= "function" then
        return
    end
    local generationCallOk, generationActive = pcall(
        server.isGenerationTransactionActive)
    if not generationCallOk or type(generationActive) ~= "boolean" then
        -- The cross-module mutex is authoritative.  If its read is
        -- unavailable, leave every accepted queue untouched and fail closed.
        return
    end
    if generationActive then
        for roomKey, pending in pairs(pendingWallRoofRepairs) do
            if type(pending) == "table"
                and pending.relocationPhase == "queued"
                and pending.relocationStarted ~= true
                and pending.relocationToken == nil
                and pending.returnToken == nil then
                -- Do not resurrect a queued operation whose original lease
                -- was already exhausted before it entered the generation
                -- wait.  Once marked waiting, this old deadline is paused.
                if pending.waitingForGeneration ~= true then
                    local queuedDeadline = integer(pending.queuedDeadlineTick)
                    if queuedDeadline == nil then
                        cancelPendingWallRoofRepair(roomKey, pending,
                            "malformed queued roof repair deadline")
                    elseif now >= queuedDeadline then
                        cancelPendingWallRoofRepair(roomKey, pending,
                            "queued roof repair member rebind deadline expired")
                    else
                        pending.waitingForGeneration = true
                    end
                end
                if pendingWallRoofRepairs[roomKey] == pending
                    and pending.waitingForGeneration == true then
                    -- Both the queued deadline and this revalidation window
                    -- are paused while generation owns the scope.  Refreshing
                    -- the absolute timestamp makes a long generation
                    -- disconnect incapable of consuming an accepted roof
                    -- event's budget.
                    pending.revalidateUntilTick = now
                        + WALL_REMOVAL_FOLLOWUP_TICKS
                end
            end
        end
        return
    end
    -- A queued item marked waiting above must first pass the current-record
    -- revalidation below; only then may its fresh queued deadline run.
    expireQueuedWallRoofRepairs(now)
    local mapOk, mapOrReason = pcall(mapData)
    if not mapOk or type(mapOrReason) ~= "table" then
        -- A transient ModData read/engine exception must not silently erase an
        -- already accepted follow-up.  Keep its bounded/expiring queue until
        -- the next successful current-schema read; the explicit schema gate
        -- below is the only path allowed to reject it.
        local detail = type(mapOrReason) == "string" and mapOrReason or ""
        if string.find(detail, C.SAVE_REBUILD_REQUIRED, 1, true) then
            clearRoofRepairRuntimeState(true)
        end
        return
    end
    local map = mapOrReason
    for roomKey in pairs(followUpWallRemovalEvents) do
        if pendingWallRoofRepairs[roomKey] == nil then
            promoteFollowUpWallRemoval(map, roomKey)
        end
    end
    for roomKey, pending in pairs(pendingWallRoofRepairs) do
        if type(pending) ~= "table"
            or integer(pending.generation) == nil
            or integer(pending.bitmapVersion) ~= C.BITMAP_VERSION
            or type(pending.returnPosition) ~= "table" then
            cancelPendingWallRoofRepair(roomKey, pending, "malformed roof repair schedule")
        elseif pendingWallRoofRepairs[roomKey] == pending then
            local revalidation = revalidateQueuedRoofRepairAfterGeneration(
                map, roomKey, pending, now)
            if revalidation == "wait" or revalidation == "revalidated" then
                -- The current generation is still unavailable, or the queue
                -- was moved to its new room key.  Both remain in memory for
                -- the next successful current-schema read.
            elseif revalidation == "expired" then
                cancelPendingWallRoofRepair(roomKey, pending,
                    "roof repair generation revalidation expired")
            else
                local state, stateDetail = server.getRoofRepairRelocationState(
                    pending.rvId, pending.generation, pending.bitmapVersion,
                    pending.relocationToken or pending.returnToken)
                if state == "failed" then
                    server.consumeRoofRepairRelocationFailure(pending.rvId,
                        pending.generation, pending.bitmapVersion,
                        pending.relocationToken or pending.returnToken)
                    cancelPendingWallRoofRepair(roomKey, pending,
                        stateDetail or "roof repair relocation failed")
                else
                    local record = recordForLoco(map, pending.rvId)
                    if not record or tostring(record.rvId) ~= pending.rvId
                        or integer(record.generation) ~= pending.generation
                        or integer(record.bitmapVersion) ~= pending.bitmapVersion
                        or not validRecord(record) then
                        cancelPendingWallRoofRepair(roomKey, pending,
                            "identity-mismatch")
                    else
                        if type(pending.players) == "table" then
                            processPendingWallRoofRepairGroup(map, pending,
                                record, server, now)
                        else
                            cancelPendingWallRoofRepair(roomKey, pending,
                                "roof repair schedule has no grouped authoritative players")
                        end
                    end
                end
            end
        end
    end
end

function Adapter.OnTick()
    Adapter._ticks = (Adapter._ticks or 0) + 1
    pruneRoofRepairDedupeState(Adapter._ticks)
    pruneRoofRepairRooms(Adapter._ticks)
    processPendingWallRoofRepairs()
    -- Run the stateless z=-15 safety net only after ordinary in-memory roof
    -- transactions have had their phase/claim opportunity for this tick.
    processStatelessRelocationSentinel()
    if Adapter._ticks % 30 ~= 0 then return end
    local ok, mapOrReason = pcall(mapData)
    if not ok or type(mapOrReason) ~= "table" then
        if not Adapter._schemaWarning then
            print("[RailroaderRVTest] " .. tostring(mapOrReason
                or C.SAVE_REBUILD_REQUIRED))
            Adapter._schemaWarning = true
        end
        local detail = type(mapOrReason) == "string" and mapOrReason or ""
        if string.find(detail, C.SAVE_REBUILD_REQUIRED, 1, true) then
            clearRoofRepairRuntimeState(true)
        end
        return
    end
    Adapter._schemaWarning = nil
    local map = mapOrReason
    local changed = false
    for _, record in pairs(map.locomotives or {}) do
        if type(record) == "table" and record.locoId ~= nil then
            local train = findTrain(record.locoId)
            local position = train and trainPose(train)
            if position then
                local old = record.locoPosition
                if not old or old.x ~= position.x or old.y ~= position.y
                    or old.z ~= position.z then
                    record.locoPosition = position
                    record.updatedAt = os.time()
                    changed = true
                end
            end
        end
    end
    repairInsidePlayers(map)
    if changed then transmitMap() end
end

-- PZ loads files in this directory alphabetically, so this adapter can be
-- evaluated before RV_Server.lua has created RailroaderRV.Server.  Expose a
-- one-shot installer and let RV_Server.lua call it again after its public
-- setters exist; require() then returns the cached adapter without rerunning
-- this file.
function Adapter.installTransactionHooks()
    local server = RailroaderRV and RailroaderRV.Server
    if not server
        or type(server.setRailroaderValidationHook) ~= "function"
        or type(server.setRailroaderCommitHook) ~= "function"
        or type(server.setRailroaderFailureHook) ~= "function" then
        return false
    end
    server.setRailroaderValidationHook(validateGeneration)
    server.setRailroaderCommitHook(commitGeneration)
    server.setRailroaderFailureHook(restoreAfterGenerationFailure)
    return true
end

Adapter._installed = true
Adapter.installTransactionHooks()
if Events and Events.OnClientCommand and type(Events.OnClientCommand.Add) == "function" then
    Events.OnClientCommand.Add(Adapter.OnClientCommand)
end
if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(Adapter.OnTick)
end
if Events and Events.OnObjectAboutToBeRemoved
    and type(Events.OnObjectAboutToBeRemoved.Add) == "function" then
    Events.OnObjectAboutToBeRemoved.Add(Adapter.onObjectAboutToBeRemoved)
end
if Events and Events.OnDestroyIsoThumpable
    and type(Events.OnDestroyIsoThumpable.Add) == "function" then
    Events.OnDestroyIsoThumpable.Add(Adapter.onDestroyIsoThumpable)
end

return Adapter
