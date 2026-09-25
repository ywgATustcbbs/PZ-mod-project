-- Server-authoritative developer workflow for preparing and capturing a hand-built RV layout.
return function(ctx)
local C = ctx.Constants
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local WORLD_MIN_Z = ctx.WORLD_MIN_Z
local WORLD_MAX_Z = ctx.WORLD_MAX_Z
local validateAuthoritativePlayer = ctx.validateAuthoritativePlayer
local validateGenerationPermission = ctx.validateGenerationPermission

local AREA_SIZE = 100
local M = {}
local captureStore

local function fail(message)
    return false, message
end

local function safeString(value)
    local ok, result = pcall(tostring, value)
    if not ok or type(result) ~= "string" then return "?" end
    return string.gsub(result, "[\r\n\t|=]", "_")
end

local function playerIdentity(player)
    local idOk, onlineId = ServerUtil.invoke(player, "getOnlineID")
    local usernameOk, username = ServerUtil.invoke(player, "getUsername")
    onlineId = idOk and ServerUtil.toNumber(onlineId) or nil
    if not ServerUtil.isFiniteNumber(onlineId)
        or math.floor(onlineId) ~= onlineId or onlineId < 0
        or not usernameOk or type(username) ~= "string" or username == "" then
        return nil
    end
    return {
        key = tostring(onlineId) .. ":" .. username,
        onlineId = onlineId,
        username = username,
    }
end

local function validateActor(player)
    local valid, positionOrReason = validateAuthoritativePlayer(player)
    if not valid then return nil, positionOrReason end
    local allowed, permissionReason = validateGenerationPermission(player)
    if not allowed then return nil, permissionReason end
    local identity = playerIdentity(player)
    if not identity then return nil, "player identity is unavailable" end
    return { identity = identity, position = positionOrReason }
end

local function layoutBounds(position, referenceZ)
    -- Derive the same world-space block independently on every command. This
    -- lets a saved construction be captured after a server or client restart.
    local origin = {
        x = math.floor(position.x / AREA_SIZE) * AREA_SIZE,
        y = math.floor(position.y / AREA_SIZE) * AREA_SIZE,
        z = referenceZ == nil and position.z or referenceZ,
    }
    return {
        minX = origin.x,
        maxX = origin.x + AREA_SIZE,
        minY = origin.y,
        maxY = origin.y + AREA_SIZE,
        z = origin.z,
    }, origin
end

local function hasMethod(target, name)
    local ok, method = pcall(function() return target[name] end)
    return ok and type(method) == "function"
end

local function validateObjectRemoval(square, object)
    if ServerWorld.isPlayerObject(object) then return end
    if ServerWorld.isVehicleObject(object) then
        ServerWorld.validateVehiclePath(object)
    elseif ServerUtil.classInstance(object, "IsoZombie") then
        if not hasMethod(object, "dieNetwork") or not hasMethod(object, "setHealth")
            or not hasMethod(object, "die") or not hasMethod(object, "removeFromWorld")
            or not hasMethod(object, "removeFromSquare")
            or not hasMethod(square, "removeCorpse") then
            error("a zombie in the layout area cannot be safely removed by the current server API")
        end
    elseif ServerUtil.classInstance(object, "IsoAnimal") then
        if not hasMethod(object, "delete") or not hasMethod(object, "removeFromWorld")
            or not hasMethod(object, "removeFromSquare") then
            error("an animal in the layout area cannot be safely removed by the current server API")
        end
    elseif ServerUtil.classInstance(object, "IsoDeadBody") then
        if not hasMethod(square, "removeCorpse") then
            error("a corpse in the layout area cannot be safely removed by the current server API")
        end
    elseif not hasMethod(square, "transmitRemoveItemFromSquare")
        or not hasMethod(square, "getObjects") then
        error("a layout object cannot be safely removed by the current server API")
    end
end

local function validateLoadedLayoutArea(cell, bounds)
    local worldOk, world = ServerUtil.callGlobal("getWorld")
    if not worldOk or not world then return nil, "world validation API is unavailable" end
    local squares = {}
    local checkedObjects = 0
    for z = WORLD_MIN_Z, WORLD_MAX_Z do
        for x = bounds.minX, bounds.maxX - 1 do
            for y = bounds.minY, bounds.maxY - 1 do
                local square
                if z == bounds.z then
                    local validOk, valid = ServerUtil.invoke(world, "isValidSquare", x, y, z)
                    if not validOk or valid ~= true then
                        return nil, "layout area is outside valid world coordinates"
                    end
                    square = ServerWorld.getSquare(cell, x, y, z)
                    if not square then
                        return nil, "the complete 100x100 layout area is not loaded"
                    end
                else
                    square = ServerWorld.getSquare(cell, x, y, z)
                end
                if square then
                    local objects = ServerWorld.squareSnapshot(square)
                    if z == bounds.z or #objects > 0 then
                        squares[#squares + 1] = square
                        for i = 1, #objects do
                            validateObjectRemoval(square, objects[i])
                            checkedObjects = checkedObjects + 1
                        end
                    end
                end
            end
        end
    end
    return squares, nil, checkedObjects
end

local function layFloor(square, sprite)
    local added = ServerUtil.callSucceeded(square, "addFloor", sprite)
    if not added then error("addFloor failed") end
    local floorOk, floor = ServerUtil.invoke(square, "getFloor")
    if not floorOk or not floor then error("new floor was not observable") end
    if not ServerUtil.callSucceeded(floor, "transmitCompleteItemToClients") then
        error("new floor synchronization failed")
    end
    ServerWorld.recalcSquare(square)
end

local function beginBuild(player, actor)
    local center = actor.position
    local bounds, origin = layoutBounds(center)
    local schemaOk, schemaOrError = pcall(captureStore)
    if not schemaOk then return fail(safeString(schemaOrError)) end
    local sprites = C.SPRITES
    local floorSprite = sprites and sprites.woodFloor and sprites.woodFloor.sprite
    if type(floorSprite) ~= "string" or floorSprite == "" then
        return fail("the current RV floor sprite is unavailable")
    end
    local cell = ServerWorld.getCellForPlayer(player)
    local squares, preflightReason, checkedObjects = validateLoadedLayoutArea(cell, bounds)
    if not squares then return fail(preflightReason) end

    -- Check every eventual floor square's creation API before clearing any
    -- level.  The new floor object's broadcast API can only be checked after
    -- addFloor creates it, so that call remains a runtime failure boundary.
    local floorMinX = origin.x + math.floor((AREA_SIZE - 6) / 2)
    local floorMaxX = floorMinX + 5
    local floorMinY = origin.y + math.floor((AREA_SIZE - 23) / 2)
    local floorMaxY = floorMinY + 22
    for x = floorMinX, floorMaxX do
        for y = floorMinY, floorMaxY do
            local square = ServerWorld.getSquare(cell, x, y, center.z)
            if not square or not hasMethod(square, "addFloor")
                or not hasMethod(square, "getFloor") then
                return fail("a template floor square lacks the required server API")
            end
        end
    end

    print("[RailroaderRVTest][LayoutBuilder] begin user="
        .. safeString(actor.identity.username)
        .. " origin=" .. tostring(origin.x) .. "," .. tostring(origin.y)
        .. "," .. tostring(origin.z) .. " bounds=100x100 zRange="
        .. tostring(WORLD_MIN_Z) .. ".." .. tostring(WORLD_MAX_Z)
        .. " preflightSquares=" .. tostring(#squares)
        .. " preflightObjects=" .. tostring(checkedObjects)
        .. " floor=6x23 no-walls")

    -- B42 exposes no transaction that can restore arbitrary existing map
    -- objects after removal.  Preflight all discoverable squares and APIs
    -- before this point; an unexpected runtime removal/broadcast failure can
    -- still leave a partial clear and is reported to the player/server log.
    for i = 1, #squares do
        ServerWorld.clearSquare(squares[i], nil)
    end

    -- Centre the 6x23 template inside the fixed hundred-tile block.
    for x = floorMinX, floorMaxX do
        for y = floorMinY, floorMaxY do
            local square = ServerWorld.getSquare(cell, x, y, center.z)
            if not square then error("floor square became unavailable after cleanup") end
            layFloor(square, floorSprite)
        end
    end

    print("[RailroaderRVTest][LayoutBuilder] cleanup complete origin="
        .. tostring(origin.x) .. "," .. tostring(origin.y) .. "," .. tostring(origin.z)
        .. " clearedSquares=" .. tostring(#squares) .. " clearedObjects="
        .. tostring(checkedObjects) .. " floor=6x23 z=" .. tostring(center.z))

    return true
end

local function hasOnlyKeys(value, allowed)
    if type(value) ~= "table" then return false end
    for key in pairs(value) do
        if allowed[key] ~= true then return false end
    end
    return true
end

local function validArray(value)
    if type(value) ~= "table" then return false end
    local length = #value
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or math.floor(key) ~= key
            or key < 1 or key > length then
            return false
        end
        count = count + 1
    end
    return count == length
end

local function finiteStoredNumber(value)
    return type(value) == "number" and ServerUtil.isFiniteNumber(value)
end

local function validStoredPoint(value, centered)
    if type(value) ~= "table" or not hasOnlyKeys(value, { x = true, y = true, z = true })
        or not finiteStoredNumber(value.x) or not finiteStoredNumber(value.y)
        or not finiteStoredNumber(value.z) then
        return false
    end
    if math.floor(value.z) ~= value.z then return false end
    if centered and (math.floor(value.x) + 0.5 ~= value.x
        or math.floor(value.y) + 0.5 ~= value.y) then
        return false
    end
    return true
end

local STATE_KEYS = {
    open = true, locked = true, hoppable = true, health = true,
    maxHealth = true, fuel = true, water = true, uses = true,
}
local OBJECT_KEYS = {
    x = true, y = true, z = true, class = true, name = true,
    sprite = true, direction = true, north = true, state = true,
}

local function simpleValue(value)
    local valueType = type(value)
    return valueType == "string" or valueType == "boolean"
        or valueType == "number" and ServerUtil.isFiniteNumber(value)
end

local function validCapture(capture)
    if type(capture) ~= "table"
        or not hasOnlyKeys(capture, {
            origin = true, width = true, height = true, target = true,
            targetRelative = true, capturedAt = true, createdBy = true,
            objects = true,
        })
        or type(capture.origin) ~= "table"
        or not hasOnlyKeys(capture.origin, { x = true, y = true, z = true })
        or not finiteStoredNumber(capture.origin.x)
        or not finiteStoredNumber(capture.origin.y)
        or not finiteStoredNumber(capture.origin.z)
        or math.floor(capture.origin.x) ~= capture.origin.x
        or math.floor(capture.origin.y) ~= capture.origin.y
        or math.floor(capture.origin.z) ~= capture.origin.z
        or capture.width ~= AREA_SIZE or capture.height ~= AREA_SIZE
        or not validStoredPoint(capture.target, true)
        or not validStoredPoint(capture.targetRelative, true)
        or type(capture.capturedAt) ~= "number"
        or not ServerUtil.isFiniteNumber(capture.capturedAt)
        or math.floor(capture.capturedAt) ~= capture.capturedAt
        or type(capture.createdBy) ~= "string"
        or not validArray(capture.objects) then
        return false
    end
    if capture.targetRelative.x ~= capture.target.x - capture.origin.x
        or capture.targetRelative.y ~= capture.target.y - capture.origin.y
        or capture.targetRelative.z ~= capture.target.z - capture.origin.z
        or capture.targetRelative.x < 0.5
        or capture.targetRelative.x > AREA_SIZE - 0.5
        or capture.targetRelative.y < 0.5
        or capture.targetRelative.y > AREA_SIZE - 0.5 then
        return false
    end
    for i = 1, #capture.objects do
        local object = capture.objects[i]
        if type(object) ~= "table" or not hasOnlyKeys(object, OBJECT_KEYS)
            or type(object.x) ~= "number" or math.floor(object.x) ~= object.x
            or object.x < 0 or object.x >= AREA_SIZE
            or type(object.y) ~= "number" or math.floor(object.y) ~= object.y
            or object.y < 0 or object.y >= AREA_SIZE
            or type(object.z) ~= "number" or math.floor(object.z) ~= object.z
            or object.class ~= nil and type(object.class) ~= "string"
            or object.name ~= nil and type(object.name) ~= "string"
            or object.sprite ~= nil and type(object.sprite) ~= "string"
            or object.direction ~= nil and type(object.direction) ~= "string"
            or object.north ~= nil and type(object.north) ~= "boolean"
            or object.state ~= nil and (type(object.state) ~= "table"
                or not hasOnlyKeys(object.state, STATE_KEYS)) then
            return false
        end
        if type(object.state) == "table" then
            for _, stateValue in pairs(object.state) do
                if not simpleValue(stateValue) then return false end
            end
        end
    end
    return true
end

captureStore = function()
    if not ModData or type(ModData.get) ~= "function"
        or type(ModData.getOrCreate) ~= "function"
        or type(ModData.transmit) ~= "function" then
        error("layout capture ModData API is unavailable")
    end
    local readOk, store = pcall(ModData.get, C.LAYOUT_CAPTURE_KEY)
    if not readOk then error(C.SAVE_REBUILD_REQUIRED) end
    if store == nil then
        local createOk, created = pcall(ModData.getOrCreate, C.LAYOUT_CAPTURE_KEY)
        if not createOk or type(created) ~= "table" then
            error("layout capture ModData container is unavailable")
        end
        store = created
    end
    if type(store) ~= "table" then error(C.SAVE_REBUILD_REQUIRED) end
    local empty = true
    for _ in pairs(store) do
        empty = false
        break
    end
    if empty then
        -- Only a genuinely empty container may be initialized to this schema.
        store.schemaVersion = C.LAYOUT_CAPTURE_SCHEMA_VERSION
        store.capture = false
    elseif not hasOnlyKeys(store, { schemaVersion = true, capture = true })
        or store.schemaVersion ~= C.LAYOUT_CAPTURE_SCHEMA_VERSION
        or not (store.capture == false or validCapture(store.capture)) then
        error(C.SAVE_REBUILD_REQUIRED)
    end
    return store
end

local function scalarResult(object, methodName)
    local ok, value = ServerUtil.invoke(object, methodName)
    if not ok or value == nil then return nil end
    if simpleValue(value) then return value end
    local number = ServerUtil.toNumber(value)
    if number ~= nil and ServerUtil.isFiniteNumber(number) then return number end
    local textOk, text = pcall(tostring, value)
    if textOk and type(text) == "string" then return safeString(text) end
    return nil
end

local function firstName(object)
    local methods = { "getName", "getObjectName", "getCustomName" }
    for i = 1, #methods do
        local name = scalarResult(object, methods[i])
        if type(name) == "string" and name ~= "" then return name end
    end
    return nil
end

local function className(object)
    local classOk, class = ServerUtil.invoke(object, "getClass")
    if classOk and class then
        local textOk, text = pcall(tostring, class)
        if textOk and type(text) == "string" and text ~= "" then
            text = string.gsub(text, "^class%s+", "")
            local simpleName = string.match(text, "([^%.]+)$")
            return safeString(simpleName or text)
        end
    end
    return "unknown"
end

local function isTransientOrNonBuildObject(object)
    if ServerWorld.isPlayerObject(object) or ServerWorld.isVehicleObject(object) then
        return true
    end
    local classNames = { "IsoZombie", "IsoAnimal", "IsoDeadBody", "IsoWorldInventoryObject" }
    for i = 1, #classNames do
        if ServerUtil.classInstance(object, classNames[i]) then return true end
    end
    return false
end

local function objectState(object)
    local values = {
        { "open", "isOpen" }, { "locked", "isLocked" },
        { "hoppable", "isHoppable" }, { "health", "getHealth" },
        { "maxHealth", "getMaxHealth" }, { "fuel", "getFuelAmount" },
        { "water", "getWaterAmount" }, { "uses", "getUses" },
    }
    local state = {}
    for i = 1, #values do
        local value = scalarResult(object, values[i][2])
        if value ~= nil then state[values[i][1]] = value end
    end
    for _ in pairs(state) do return state end
    return nil
end

local function snapshotObject(object, x, y, z, origin)
    if isTransientOrNonBuildObject(object) then return nil end
    local sprite = ServerWorld.getSpriteName(object)
    local northOk, north = ServerUtil.invoke(object, "getNorth")
    local direction = scalarResult(object, "getDir")
    local northValue
    if northOk and type(north) == "boolean" then northValue = north end
    local result = {
        x = x - origin.x,
        y = y - origin.y,
        z = z - origin.z,
        class = className(object),
        name = firstName(object),
        sprite = sprite and safeString(sprite) or nil,
        direction = direction ~= nil and safeString(direction) or nil,
        north = northValue,
        state = objectState(object),
    }
    return result
end

local function scanLayer(cell, bounds, origin, z, objects, requireLoaded)
    local found = 0
    for x = bounds.minX, bounds.maxX - 1 do
        for y = bounds.minY, bounds.maxY - 1 do
            local square = ServerWorld.getSquare(cell, x, y, z)
            if requireLoaded and not square then
                error("layout capture is incomplete: base area square is not loaded")
            end
            if square then
                local snapshot = ServerWorld.squareSnapshot(square)
                for i = 1, #snapshot do
                    local entry = snapshotObject(snapshot[i], x, y, z, origin)
                    if entry then
                        objects[#objects + 1] = entry
                        found = found + 1
                    end
                end
            end
        end
    end
    return found
end

local function scanVertical(cell, bounds, origin)
    local objects = {}
    -- The game supports underground as well as elevated floors. Scan the full
    -- legal Z range so empty levels cannot hide a detached floor or roof.
    for z = WORLD_MIN_Z, WORLD_MAX_Z do
        scanLayer(cell, bounds, origin, z, objects, z == origin.z)
    end
    return objects
end

local function logCapture(capture)
    print("[RailroaderRVTest][LayoutBuilder] capture user=" .. safeString(capture.createdBy)
        .. " origin=" .. tostring(capture.origin.x) .. "," .. tostring(capture.origin.y)
        .. "," .. tostring(capture.origin.z) .. " bounds=100x100")
    print("[RailroaderRVTest][LayoutBuilder] teleport-target world="
        .. tostring(capture.target.x) .. "," .. tostring(capture.target.y)
        .. "," .. tostring(capture.target.z) .. " relative="
        .. tostring(capture.targetRelative.x) .. "," .. tostring(capture.targetRelative.y)
        .. "," .. tostring(capture.targetRelative.z))
    for i = 1, #capture.objects do
        local object = capture.objects[i]
        local stateParts = {}
        if type(object.state) == "table" then
            for key, value in pairs(object.state) do
                stateParts[#stateParts + 1] = key .. "=" .. safeString(value)
            end
            table.sort(stateParts)
        end
        print("[RailroaderRVTest][LayoutBuilder] object rel="
            .. tostring(object.x) .. "," .. tostring(object.y) .. "," .. tostring(object.z)
            .. " class=" .. safeString(object.class)
            .. " name=" .. safeString(object.name or "-")
            .. " sprite=" .. safeString(object.sprite or "-")
            .. " north=" .. safeString(object.north)
            .. " direction=" .. safeString(object.direction or "-")
            .. " state=" .. table.concat(stateParts, ","))
    end
    print("[RailroaderRVTest][LayoutBuilder] capture complete objects="
        .. tostring(#capture.objects) .. " capturedAt=" .. tostring(capture.capturedAt))
end

local function finishBuild(player, actor)
    local current = actor.position
    if current.z < WORLD_MIN_Z or current.z > WORLD_MAX_Z then
        return fail("player target floor is outside the legal world range")
    end
    local bounds, origin = layoutBounds(current, 0)
    local store = captureStore()
    local cell = ServerWorld.getCellForPlayer(player)
    local capture = {
        origin = {
            x = origin.x,
            y = origin.y,
            z = origin.z,
        },
        width = AREA_SIZE,
        height = AREA_SIZE,
        target = { x = current.x + 0.5, y = current.y + 0.5, z = current.z },
        targetRelative = {
            x = current.x + 0.5 - origin.x,
            y = current.y + 0.5 - origin.y,
            z = current.z - origin.z,
        },
        capturedAt = math.floor(os.time()),
        createdBy = actor.identity.username,
        objects = scanVertical(cell, bounds, origin),
    }
    if not validCapture(capture) then error("captured layout failed current-schema validation") end

    local previous = store.capture
    store.capture = capture
    local transmitOk, transmitResult = pcall(ModData.transmit, C.LAYOUT_CAPTURE_KEY)
    if not transmitOk or transmitResult == false then
        store.capture = previous
        error("layout capture persistence failed")
    end
    logCapture(capture)
    return true
end

function M.handleCommand(command, player, args)
    if command ~= C.COMMAND_LAYOUT_BUILD and command ~= C.COMMAND_LAYOUT_FINISH then
        return fail("unknown layout-builder command")
    end
    if not ServerUtil.isEmptyCommandArgs(args) then
        return fail("layout-builder command args must be empty")
    end
    local actor, actorReason = validateActor(player)
    if not actor then return fail(actorReason) end
    local callOk, accepted, reason = pcall(function()
        if command == C.COMMAND_LAYOUT_BUILD then
            return beginBuild(player, actor)
        end
        return finishBuild(player, actor)
    end)
    if not callOk then return fail(safeString(accepted)) end
    return accepted, reason
end

M.getLatestCapture = function()
    local store = captureStore()
    return store.capture ~= false and store.capture or nil
end

ctx.LayoutBuilder = M
return M
end
