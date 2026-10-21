-- RV_RailroaderServer: Train responsibilities.
return function(ctx)
local processIsServer = ctx.processIsServer
local C = ctx.C
local unpackFn = ctx.unpackFn

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
    if type(result) ~= "number" then return nil end
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
    ctx.transitionSequence = ctx.transitionSequence + 1
    return tostring(kind) .. ":" .. tostring(record and record.locoId or "rv")
        .. ":" .. tostring(record and record.generation or 0) .. ":"
        .. tostring(os.time()) .. ":" .. tostring(ctx.transitionSequence)
end

local function railroaderAPI()
    return RR.API
end

local Units = require("RailroaderRV/RVMapping/RV_RailroaderUnits")
local Adapter = ctx.Adapter

local function trainId(train)
    return train and train.id or nil
end

local function engineIdForUnit(unit)
    if not unit then return nil end
    if unit.isLocomotive then return unit.id end
    return unit.locomotiveId
end

local function findTrain(unitId)
    if unitId == nil then return nil end
    return Units.find(unitId)
end

local function trainPosition(train)
    return copyPosition(train)
end

local function trainSpeed(train)
    return number(train.speed)
end

local function trainMoving(train)
    local speed = trainSpeed(train)
    return math.abs(speed) > C.RV_STOPPED_SPEED
end

local function trainDirection(train)
    if not train then return nil, nil end
    return number(train.dirX), number(train.dirY)
end

local function trainPose(train)
    local position = trainPosition(train)
    if not position then return nil end
    local dx, dy = trainDirection(train)
    if dx == nil or dy == nil then return nil end
    position.dirX, position.dirY = dx, dy
    return position
end

local function trainGeometry(train, x, y)
    if not train then return nil end
    return Units.geometry(train, x, y)
end

local function seatPosition(train, seat)
    local engineId = engineIdForUnit(train)
    if engineId == nil then return nil end
    local currentGeometry = railroaderAPI().locomotiveGeometry(engineId)
    if not currentGeometry then return nil end
    return copyPosition(currentGeometry.seatPositions[seat])
end

local function interactionGeometry(player, train)
    local position = playerPosition(player)
    if not position then return nil, nil end
    local geometry, reason = trainGeometry(train, position.x, position.y)
    if not geometry then return nil, nil, reason end
    local reach
    if train.isLocomotive then
        reach = geometry.mountReachTiles
    else
        reach = C.RV_MOUNT_REACH
    end
    return geometry.hullDistanceTiles, reach
end

local function playerRole(train, player)
    local engineId = engineIdForUnit(train)
    if engineId == nil then
        if (train.kind == "car_box" or train.kind == "car_bx40")
            and train.isCut == true then
            return "external", nil
        end
        return nil, "current owner locomotive is not available"
    end
    local state, reason = railroaderAPI().riderState(engineId, player)
    if not state then return nil, reason end
    if state.role == "outside" then return "external", nil end
    return state.role, state.seatIndex
end

local function forgetTrainSeat(train, player)
    local role, seat = playerRole(train, player)
    if role == nil then return nil, seat end
    if role == "external" then return role, seat end
    local engineId = engineIdForUnit(train)
    local released, reason = railroaderAPI().releaseRider(engineId, player)
    if not released then return nil, reason end
    return released.role, released.seatIndex
end

local function assignTrainSeat(train, player, role, seat)
    local engineId = engineIdForUnit(train)
    if engineId == nil then
        return nil, "current owner locomotive is not available"
    end
    return railroaderAPI().assignRider(engineId, player, role, seat)
end


ctx.number = number
ctx.integer = integer
ctx.call = call
ctx.callGlobal = callGlobal
ctx.playerId = playerId
ctx.playerName = playerName
ctx.playerDead = playerDead
ctx.playerPosition = playerPosition
ctx.copyPosition = copyPosition
ctx.newTransitionToken = newTransitionToken
ctx.trainId = trainId
ctx.findTrain = findTrain
ctx.engineIdForUnit = engineIdForUnit
ctx.trainPosition = trainPosition
ctx.trainSpeed = trainSpeed
ctx.trainMoving = trainMoving
ctx.trainPose = trainPose
ctx.trainGeometry = trainGeometry
ctx.singleplayerMode = function()
    return railroaderAPI().mode() == "singleplayer"
end
ctx.seatPosition = seatPosition
ctx.interactionGeometry = interactionGeometry
ctx.playerRole = playerRole
ctx.forgetTrainSeat = forgetTrainSeat
ctx.assignTrainSeat = assignTrainSeat
Adapter.findUnit = findTrain
end
