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

RailroaderRV = RailroaderRV or {}
RailroaderRV.RailroaderServer = RailroaderRV.RailroaderServer or {}

local Adapter = RailroaderRV.RailroaderServer
local C = RailroaderRV.Constants
local unpackFn = (table and table.unpack) or unpack
local roofRepairRooms = {}
local roofRepairPlayers = {}

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

local function usableFallbackCoordinate(position)
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
-- only the server-persisted locomotive pose, then choose a conservative side
-- neighbour and validate its legal world square.  Older records may lack a
-- direction, so the candidate list includes both sides and one-tile fallbacks.
local function persistedBesidePosition(record)
    if type(record) ~= "table" then return nil end
    local base = copyPose(record.locoPosition)
    local historical = copyPose(record.enterPosition)
    if not base then base = historical end
    if not base then return nil end

    local dx, dy = number(base.dirX), number(base.dirY)
    if (dx == nil or dy == nil) and historical then
        dx, dy = number(historical.dirX), number(historical.dirY)
    end
    dx, dy = dx or 0, dy or -1
    local length = math.sqrt(dx * dx + dy * dy)
    if length <= 0.0001 then dx, dy = 0, -1
    else dx, dy = dx / length, dy / length end

    local candidates = {
        { x = base.x - dy * 2.0, y = base.y + dx * 2.0, z = base.z },
        { x = base.x + dy * 2.0, y = base.y - dx * 2.0, z = base.z },
        { x = base.x + 1.0, y = base.y, z = base.z },
        { x = base.x - 1.0, y = base.y, z = base.z },
        { x = base.x, y = base.y + 1.0, z = base.z },
        { x = base.x, y = base.y - 1.0, z = base.z },
    }
    for i = 1, #candidates do
        if usableFallbackCoordinate(candidates[i]) then
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
    if not ModData or type(ModData.getOrCreate) ~= "function" then
        error("ModData.getOrCreate is unavailable")
    end
    local ok, map = pcall(ModData.getOrCreate, C.RV_MAP_KEY)
    if not ok or type(map) ~= "table" then
        error("Railroader RV map ModData is unavailable")
    end
    map.version = 1
    if type(map.locomotives) ~= "table" then map.locomotives = {} end
    if type(map.players) ~= "table" then map.players = {} end
    return map
end

local function transmitMap()
    if ModData and type(ModData.transmit) == "function" then
        pcall(ModData.transmit, C.RV_MAP_KEY)
    end
end

local function rvRegion()
    local minX = integer(C.TELEPORT_X) + (integer(C.RV_REGION_MIN_OFFSET_X) or -50)
    local minY = integer(C.TELEPORT_Y) + (integer(C.RV_REGION_MIN_OFFSET_Y) or -50)
    local size = integer(C.RV_REGION_SIZE) or 100
    return { minX = minX, minY = minY, maxX = minX + size,
        maxY = minY + size, z = integer(C.TELEPORT_Z) or 0, size = size }
end

local function inRegion(position, region)
    if type(position) ~= "table" or type(region) ~= "table" then return false end
    local x, y, z = number(position.x), number(position.y), number(position.z)
    local minX, minY = number(region.minX), number(region.minY)
    local maxX, maxY = number(region.maxX), number(region.maxY)
    local regionZ = number(region.z)
    if not x or not y or not z or not minX or not minY or not maxX or not maxY
        or not regionZ then return false end
    return x >= minX and x < maxX and y >= minY and y < maxY
        and math.floor(z) == math.floor(regionZ)
end

local function validRegion(region)
    if type(region) ~= "table" then return false end
    local size = integer(C.RV_REGION_SIZE) or 100
    local minX, minY = integer(region.minX), integer(region.minY)
    return minX ~= nil and minY ~= nil and integer(region.maxX) == minX + size
        and integer(region.maxY) == minY + size and integer(region.z) ~= nil
end

local function validMappingRecord(record)
    if type(record) ~= "table" or record.generated ~= true
        or record.locoId == nil or not validRegion(record.region) then
        return false
    end
    if record.players ~= nil and type(record.players) ~= "table" then
        return false
    end
    return copyPosition(record.rvPosition) ~= nil
end

local function validRecord(record)
    return validMappingRecord(record)
end

local function recordForLoco(map, locoId)
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

local function roofRepairRoomKey(record)
    if type(record) ~= "table" or record.locoId == nil then return nil end
    return tostring(record.locoId) .. ":" .. tostring(record.generation or "0")
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
    if not force and roofRepairRooms[roomKey] then return true, "already repaired" end
    local ok, repaired, detail = pcall(server.repairRoofVisuals, player)
    if not ok then
        print("[RailroaderRVTest] roof visual repair error: " .. tostring(repaired))
        return false, tostring(repaired)
    end
    if repaired == true then
        roofRepairRooms[roomKey] = true
        local name = playerName(player)
        if name then roofRepairPlayers[name] = true end
        print("[RailroaderRVTest] roof visual repair complete room=" .. roomKey
            .. " reason=" .. tostring(reason or "entry")
            .. " detail=" .. tostring(detail or "ok"))
        return true, detail
    end
    print("[RailroaderRVTest] roof visual repair deferred room=" .. roomKey
        .. " reason=" .. tostring(reason or "entry")
        .. ": " .. tostring(detail or "unknown"))
    return false, detail
end

-- The reverse lookup intentionally starts with the passenger coordinate.  It
-- never asks a world-room API, a room identifier, or a generated object which RV the
-- player belongs to.  A coordinate in the target region with no sound mapping
-- is the explicit damaged-data state handled by exitPlayer().  A valid mapping
-- whose live locomotive is temporarily absent is retained for a persisted
-- vehicle-pose beside fallback.  Coordinates outside the target 100x100 region
-- are a separate outside-rv rejection and never use the damaged-map fallback.
local function recordAtPlayerCoordinate(map, player)
    local position = playerPosition(player)
    if not position then return nil, nil, nil, false, "outside-rv" end
    local target = rvRegion()
    if not inRegion(position, target) then
        return nil, nil, nil, false, "outside-rv"
    end
    local sawRegion = false
    for key, record in pairs(map.locomotives or {}) do
        if type(record) == "table" and inRegion(position, record.region) then
            sawRegion = true
            if validMappingRecord(record) then
                local train = findTrain(record.locoId)
                if train and trainPosition(train) then
                    return record, key, train, false, "active-mapped"
                end
                if copyPose(record.locoPosition)
                    or copyPose(record.enterPosition) then
                    return record, key, nil, false, "inactive-mapped"
                end
                return nil, nil, nil, true, "damaged-map"
            end
            return nil, nil, nil, true, "damaged-map"
        end
    end
    if sawRegion then return nil, nil, nil, true, "damaged-map" end
    return nil, nil, nil, false, nil
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
        payload.fallback = relation.fallback
    end
    local sent = callGlobal("sendServerCommand", player, C.MOD_ID,
        C.COMMAND_RV_TELEPORT, payload)
    -- A single-player world has no network command channel.  Its official
    -- TrainEntity/Ride state is updated locally; the same call still sends the
    -- RVTeleport hint when the channel exists.  MP/co-op must have the command
    -- path or the transaction fails closed.
    if not sent and processIsServer() then return false end
    return safeCall(player, "teleportTo", position.x, position.y, position.z)
end

local function fallbackPosition()
    local rr = rawget(_G, "RR")
    local spawn = rr and rr.Spawn and rr.Spawn.DEPOT
    local spline = rr and rr.Spline
    local routes = rr and rr.Routes
    if spawn and spline and routes and type(spline.sample) == "function"
        and type(routes.get) == "function" then
        local ok, route = pcall(routes.get, spawn.routeId)
        if ok and route then
            local sampled, point = pcall(spline.sample, route, spawn.distance)
            if sampled and type(point) == "table"
                and number(point.x) and number(point.y) then
                return { x = number(point.x), y = number(point.y),
                    z = number(point.z) or 0 }
            end
        end
    end
    return { x = number(C.RV_FALLBACK_X) or 11606,
        y = number(C.RV_FALLBACK_Y) or 9851,
        z = number(C.RV_FALLBACK_Z) or 0 }
end

local function markPlayerOutside(map, record, key, player, position, seat, role)
    local name = playerName(player)
    if not name then return end
    local relation = map.players[name]
    if type(relation) ~= "table" then relation = {} end
    relation.locoId = record and tostring(record.locoId) or relation.locoId
    relation.locomotive = key or relation.locomotive
    relation.onlineId = playerId(player)
    relation.inside = false
    relation.role = role
    relation.seat = seat
    relation.exitPosition = copyPosition(position)
    map.players[name] = relation
    if record then
        if type(record.players) ~= "table" then record.players = {} end
        local rider = record.players[name]
        if type(rider) ~= "table" then rider = {} end
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
    local relation = {
        locoId = tostring(record.locoId), locomotive = key,
        onlineId = playerId(player), inside = true,
        role = sourceRole, seat = sourceSeat,
        enterPosition = copyPosition(sourcePosition),
    }
    map.players[name] = relation
    if type(record.players) ~= "table" then record.players = {} end
    record.players[name] = {
        onlineId = relation.onlineId, inside = true,
        role = sourceRole, seat = sourceSeat,
        enterPosition = copyPosition(sourcePosition),
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
        or number(C.RV_ENTER_RANGE) or 2.0
    return distance ~= nil and distance <= reach
end

local function requestData(train, player, role, seat, sourcePosition)
    return {
        locoId = tostring(trainId(train)), sourceRole = role, sourceSeat = seat,
        playerUsername = playerName(player), playerOnlineId = playerId(player),
        entryPosition = copyPosition(sourcePosition),
        region = rvRegion(), rvPosition = {
            x = (integer(C.TELEPORT_X) or 0) + 0.5,
            y = (integer(C.TELEPORT_Y) or 0) + 0.5,
            z = integer(C.TELEPORT_Z) or 0,
        },
        locoPosition = trainPose(train),
    }
end

local function removeSeatForEntry(train, player, onlineId)
    return forgetTrainSeat(train, player, onlineId)
end

local function enterExisting(player, train, record, key, sourceRole,
    sourceSeat, sourcePosition, map)
    local onlineId = playerId(player)
    local target = copyPosition(record.rvPosition)
    if not target then return false, "RV entry point is damaged" end
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
    })
    if not moved then
        map.players[playerName(player)] = oldRelation
        record.players = oldRiders
        if removedRole == "driver" then
            putDriver(train, player, onlineId)
        elseif removedRole == "passenger" and removedSeat ~= nil then
            putPassenger(train, player, onlineId, removedSeat)
        end
        return false, "RV entry teleport failed"
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
    local map = mapData()
    local _, _, _, inside = recordAtPlayerCoordinate(map, player)
    if inside then return false, "player is already inside an RV" end
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
    local source = copyPosition(data.sourcePosition or data.entryPosition)
    if source then
        movePlayer(player, source, "generation-failed", {
            locoId = data.locoId, role = data.sourceRole, seat = data.sourceSeat,
        })
    end
end

local function commitGeneration(player, data, prepared)
    local map = mapData()
    local locoId = tostring(data.locoId)
    local record, key = recordForLoco(map, locoId)
    if not record then
        key, record = locoId, {}
        map.locomotives[key] = record
    end
    local train = findTrain(locoId)
    record.version = 1
    record.generated = true
    record.locoId = locoId
    record.generation = integer(prepared and prepared.generation) or record.generation
    record.region = data.region or rvRegion()
    record.rvPosition = copyPosition(data.rvPosition)
        or { x = (integer(C.TELEPORT_X) or 0) + 0.5,
            y = (integer(C.TELEPORT_Y) or 0) + 0.5,
            z = integer(C.TELEPORT_Z) or 0 }
    record.enterPosition = copyPosition(data.entryPosition)
        or copyPosition(record.rvPosition)
    record.locoPosition = train and trainPose(train) or data.locoPosition
        or record.locoPosition
    record.updatedAt = os.time()
    markPlayerInside(map, record, key, player,
        data.entryPosition, data.sourceRole, data.sourceSeat)
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

local function damagedMapFallback(player, map)
    local fallback = fallbackPosition()
    if not movePlayer(player, fallback, "damaged-map-fallback") then
        return false, "damaged RV map fallback teleport failed"
    end
    local name = playerName(player)
    if name then
        if type(map.players[name]) ~= "table" then map.players[name] = {} end
        map.players[name].inside = false
    end
    transmitMap()
    return true
end

local function exitPlayer(player)
    if not player or playerDead(player) then
        return false, "player is unavailable"
    end
    local map = mapData()
    local record, key, train, damaged, lookupState =
        recordAtPlayerCoordinate(map, player)
    if lookupState == "outside-rv" then
        return false, "player is outside the RV area"
    end
    if damaged or not record then
        return damagedMapFallback(player, map)
    end
    if not train then
        local target = persistedBesidePosition(record)
        if not target then return damagedMapFallback(player, map) end
        -- The mapping is valid but the locomotive is inactive/unloaded.  Do
        -- not invent a driver/passenger seat; use only a persisted beside
        -- target and retain the explicit state for diagnostics and tests.
        if lookupState ~= "inactive-mapped" then
            return damagedMapFallback(player, map)
        end
        local moved = movePlayer(player, target, "exit", {
            locoId = record.locoId, role = "beside", seat = nil,
            fallback = "inactive-mapped-fallback",
        })
        if not moved then return false, "inactive locomotive exit teleport failed" end
        markPlayerOutside(map, record, key, player, target, nil, "beside")
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

    local assigned = false
    if role == "passenger" then assigned = putPassenger(train, player, onlineId, seat)
    elseif role == "driver" then assigned = putDriver(train, player, onlineId) end
    if role ~= "beside" and not assigned then
        return false, "locomotive seat became occupied"
    end
    local moved = movePlayer(player, target, "exit", {
        locoId = trainId(train), role = role, seat = seat,
    })
    if not moved then
        if role ~= "beside" then forgetTrainSeat(train, player, onlineId) end
        return false, "RV exit teleport failed"
    end
    record.locoPosition = trainPose(train) or record.locoPosition
    markPlayerOutside(map, record, key, player, target, seat, role)
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
    if command == C.COMMAND_RV_ENTER then
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

local function repairInsidePlayers(map)
    local present = {}
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
                present[name] = true
                local currentOnlineId = playerId(player)
                local reconnect = currentOnlineId ~= nil
                    and relation.onlineId ~= nil
                    and tostring(currentOnlineId) ~= tostring(relation.onlineId)
                local firstPresence = roofRepairPlayers[name] ~= true
                repairRoofForPlayer(player, record, firstPresence or reconnect,
                    reconnect and "reconnect" or "presence")
            end
        end
    end
    -- A later appearance of the same username is treated as a new connection,
    -- so the repair is retriggered even when the map generation is unchanged.
    for name in pairs(roofRepairPlayers) do
        if not present[name] then roofRepairPlayers[name] = nil end
    end
end

function Adapter.OnTick()
    Adapter._ticks = (Adapter._ticks or 0) + 1
    if Adapter._ticks % 30 ~= 0 then return end
    local ok, map = pcall(mapData)
    if not ok or type(map) ~= "table" then return end
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

return Adapter
