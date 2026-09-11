-- RailroaderRVTest server-side generation transaction.
--
-- This file deliberately owns no client UI and does not depend on RailroaderMP.
-- The shared RV_Constants/RV_Layout modules are required at request time. A
-- missing or malformed shared contract rejects the request before world I/O.

local OWNER = "RailroaderRVTest"
local COMMAND_MODULE = "RailroaderRVTest"
local COMMAND = "Generate"
local COMMAND_RELOCATE = "Relocate"
local COMMAND_RELOCATE_ACK = "RelocateAck"
local COMMAND_FINAL_RELOCATE = "FinalRelocate"
local COMMAND_REFRESH_ROOM_OWNERSHIP = "RefreshRoomOwnership"
local COMMAND_RV_ENTER = "EnterRV"
local COMMAND_RV_EXIT = "ExitRV"
local MANIFEST_KEY = "RailroaderRVTest.Manifest"
local unpackFn = (table and table.unpack) or unpack

-- Railroader entry/exit is implemented by RV_RailroaderServer.lua.  These
-- callbacks keep the long-running generation transaction authoritative without
-- making the generic Generate command depend on Railroader being installed.
local railroaderValidationHook = nil
local railroaderCommitHook = nil
local railroaderFailureHook = nil

local function loadModule(name, globalName)
    local ok, result = pcall(require, name)
    if ok and type(result) == "table" then
        return result
    end
    local value = rawget(_G, globalName)
    if type(value) == "table" then
        return value
    end
    local rv = rawget(_G, "RailroaderRV")
    if type(rv) == "table" then
        local nestedName = globalName == "RV_Constants" and "Constants"
            or globalName == "RV_Layout" and "Layout" or nil
        if nestedName and type(rv[nestedName]) == "table" then
            return rv[nestedName]
        end
    end
    return {}
end

-- PZ's Lua loader uses slash-separated media paths (the same contract used by
-- RV_Layout.lua and the vanilla RainBarrel scripts).  Keep the global fallback
-- only for a debugger reload; normal loading must return the actual tables.
local Constants = loadModule("RailroaderRV/RV_Constants", "RV_Constants")
local LayoutContract = loadModule("RailroaderRV/RV_Layout", "RV_Layout")
local roofRepairOk, RoofRepair = pcall(require, "RailroaderRV/RV_RoofRepair")
if not roofRepairOk or type(RoofRepair) ~= "table"
    or type(RoofRepair.run) ~= "function" then
    RoofRepair = nil
end

local RV = rawget(_G, "RailroaderRV") or {}
rawset(_G, "RailroaderRV", RV)
RV.Server = RV.Server or {}

local transactionBusy = false
local transactionPlayer = nil
local pendingGeneration = nil
local pendingSerial = 0
local serverTick = 0
local roomOwnershipGuards = {}
local safeErrorText

-- The client acknowledgement requires a full server -> client -> server
-- round trip.  Keep an additional cross-tick guard before touching the old
-- player-built room so the client cannot still be evaluating its stale
-- IsoRoom while WorldRegionToMetaGrid rebuilds the room definitions.
local RELOCATION_MIN_TICKS = 3
local RELOCATION_POST_ACK_TICKS = 2
local RELOCATION_TIMEOUT_TICKS = 600
local SAFE_SEARCH_MAX_RADIUS = 80

-- IsoRegions does not expose a Lua callback for completion of its asynchronous
-- dynamic-room rebuild. Keep scanning the small wall+roof footprint for a
-- bounded period, and require a stable tail before retiring each guard.
local ROOM_OWNERSHIP_MIN_TICKS = 1800
local ROOM_OWNERSHIP_STABLE_TICKS = 120
local ROOM_OWNERSHIP_MAX_TICKS = 7200

local WORLD_MIN_Z = -32
local WORLD_MAX_Z = 31

local function invoke(target, name, ...)
    if target == nil then
        return false, nil
    end
    local method = target[name]
    if type(method) ~= "function" then
        return false, nil
    end
    local ok, a, b, c, d = pcall(method, target, ...)
    if not ok then
        return false, a
    end
    return true, a, b, c, d
end

-- A Java void method returns nil, while a failed boolean API returns false.
-- Keep both cases distinct so critical creation/synchronisation calls cannot
-- silently accept an explicit false result.
local function callSucceeded(target, name, ...)
    local ok, result = invoke(target, name, ...)
    return ok and result ~= false
end

local function invokeClass(class, signatures)
    if class == nil or type(class.new) ~= "function" then
        return false, nil
    end
    for i = 1, #signatures do
        local args = signatures[i]
        local ok, value = pcall(class.new, unpackFn(args))
        if ok and value ~= nil then
            return true, value
        end
    end
    return false, nil
end

local function callGlobal(name, ...)
    local fn = rawget(_G, name)
    if type(fn) ~= "function" then
        return false, nil
    end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        return false, a
    end
    return true, a, b, c
end

local function classInstance(obj, className)
    local checker = rawget(_G, "instanceof")
    if type(checker) ~= "function" then
        return false
    end
    local ok, result = pcall(checker, obj, className)
    return ok and result == true
end

-- Kahlua represents Java primitive numeric returns as Double.  Those values
-- are already Lua numbers and must not be passed through tonumber when they
-- arrive from a Java getter.  In particular, a final-position select() call
-- can expand extra return values and send tonumber down its radix/String
-- branch, which rejects a Java Double.  Keep string parsing for Lua data and
-- use a guarded arithmetic fallback for other numeric userdata.
local function toNumber(value)
    local valueType = type(value)
    if valueType == "number" then
        return value
    end
    if valueType == "string" then
        return tonumber(value)
    end
    if value == nil then
        return nil
    end
    local ok, numeric = pcall(function()
        return value + 0
    end)
    if ok and type(numeric) == "number" then
        return numeric
    end
    return nil
end

local function tableIsEmpty(value)
    if type(value) ~= "table" then
        return false
    end
    -- Kahlua's server environment does not expose Lua's global `next`.
    for _ in pairs(value) do
        return false
    end
    return true
end

local function isEmptyCommandArgs(args)
    -- GameServer.receiveClientCommand passes nil when the wire packet has no
    -- args table.  This is the canonical representation for this command.
    if args == nil then
        return true
    end
    -- Keep compatibility with callers that still provide {}: on B42 this can
    -- arrive as a PZNetKahluaTableImpl rather than a plain Lua table.  The
    -- payload contract remains strict: every non-empty or unrelated value is
    -- rejected.
    if type(args) == "table" then
        return tableIsEmpty(args)
    end
    if not classInstance(args, "PZNetKahluaTableImpl") then
        return false
    end
    local ok, size = invoke(args, "size")
    return ok and toNumber(size) == 0
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function requiredNumber(value, label)
    local number = toNumber(value)
    if not isFiniteNumber(number) then
        error("RailroaderRVTest: " .. tostring(label) .. " is not a finite number")
    end
    return number
end

local function requiredInteger(value, label)
    local number = requiredNumber(value, label)
    local integer = math.floor(number)
    if integer ~= number then
        error("RailroaderRVTest: " .. tostring(label) .. " must be an integer")
    end
    return integer
end

local function floorInt(value)
    return math.floor(toNumber(value) or 0)
end

local function copyPoint(value, fallback)
    if type(value) ~= "table" then
        return { x = fallback.x, y = fallback.y, z = fallback.z }
    end
    return {
        x = floorInt(value.x or fallback.x),
        y = floorInt(value.y or fallback.y),
        z = floorInt(value.z or fallback.z),
    }
end

local function makeLayout(x, y, z)
    local planner = LayoutContract.plan or LayoutContract.build or LayoutContract.create
        or LayoutContract.make or LayoutContract.forAnchor
    if type(planner) ~= "function" then
        error("RailroaderRVTest: shared RV_Layout planner is unavailable")
    end
    local ok, planned = pcall(planner, x, y, z)
    if not ok then
        local textOk, text = pcall(tostring, planned)
        error("RailroaderRVTest: shared RV_Layout planning failed: "
            .. (textOk and text or "<error formatting failed>"))
    end
    if type(planned) ~= "table" then
        error("RailroaderRVTest: shared RV_Layout planner returned no plan")
    end

    -- Accept only naming aliases already used by the shared contract.  Never
    -- synthesize missing geometry here: a broken/missing shared plan must
    -- reject the request before any world mutation.
    local features = type(planned.features) == "table" and planned.features or {}
    planned.anchor = planned.anchor or planned.center
    planned.clear = planned.clear or planned.clearArea or planned.clearBounds
    planned.room = planned.room or planned.interior or planned.roomBounds
    planned.wall = planned.wall or planned.walls or planned.wallBounds
    planned.light = planned.light or planned.lightPoint or features.lamp
    planned.generator = planned.generator or planned.generatorPoint or features.generator
    planned.barrel = planned.barrel or planned.rainBarrel or planned.barrelPoint
        or planned.rainCollector or features.rainCollector
    planned.counter = planned.counter or planned.counterPoint or features.counter
    planned.sink = planned.sink or planned.sinkPoint or features.sink
    local requiredTables = { "anchor", "clear", "room", "wall", "roof", "wallCoordinates" }
    for i = 1, #requiredTables do
        local field = requiredTables[i]
        if type(planned[field]) ~= "table" then
            error("RailroaderRVTest: shared RV_Layout contract missing " .. field)
        end
    end
    local requiredPoints = { "light", "generator", "barrel", "counter", "sink" }
    for i = 1, #requiredPoints do
        local field = requiredPoints[i]
        local point = planned[field]
        if type(point) ~= "table" or point.x == nil or point.y == nil or point.z == nil then
            error("RailroaderRVTest: shared RV_Layout contract missing point " .. field)
        end
        requiredInteger(point.x, "shared layout " .. field .. ".x")
        requiredInteger(point.y, "shared layout " .. field .. ".y")
        requiredInteger(point.z, "shared layout " .. field .. ".z")
    end
    local anchor = planned.anchor
    requiredInteger(anchor.x or anchor.cx, "shared layout anchor.x")
    requiredInteger(anchor.y or anchor.cy, "shared layout anchor.y")
    requiredInteger(anchor.z or anchor.cz, "shared layout anchor.z")
    return planned
end

local function getCellForPlayer(player)
    local ok, cell = invoke(player, "getCell")
    if ok and cell then
        return cell
    end
    local okGlobal, globalCell = callGlobal("getCell")
    if okGlobal and globalCell then
        return globalCell
    end
    error("RailroaderRVTest: no IsoCell available")
end

local function getSquare(cell, x, y, z)
    local ok, square = invoke(cell, "getGridSquare", x, y, z)
    if ok and square then
        return square
    end
    return nil
end

local function collectionSnapshot(collection)
    local result = {}
    if collection == nil then
        return result
    end
    local okSize, size = invoke(collection, "size")
    local sizeNumber = toNumber(size)
    if okSize and sizeNumber then
        for i = 0, sizeNumber - 1 do
            local okItem, item = invoke(collection, "get", i)
            if okItem and item then
                result[#result + 1] = item
            end
        end
        return result
    end
    if type(collection) == "table" then
        for _, item in pairs(collection) do
            if item then
                result[#result + 1] = item
            end
        end
    end
    return result
end

local function appendUnique(result, seen, object)
    if object ~= nil and not seen[object] then
        seen[object] = true
        result[#result + 1] = object
    end
end

local function squareSnapshot(square)
    local result, seen = {}, {}
    local listNames = {
        "getObjects", "getSpecialObjects", "getStaticMovingObjects",
        "getMovingObjects", "getWorldObjects", "getDeadBodys", "getCorpses",
    }
    for i = 1, #listNames do
        local ok, collection = invoke(square, listNames[i])
        if ok then
            local snapshot = collectionSnapshot(collection)
            for j = 1, #snapshot do
                appendUnique(result, seen, snapshot[j])
            end
        end
    end
    local okFloor, floor = invoke(square, "getFloor")
    if okFloor and floor then
        appendUnique(result, seen, floor)
    end
    local corpseMethods = { "getCorpse", "getDeadBody" }
    for i = 1, #corpseMethods do
        local ok, corpse = invoke(square, corpseMethods[i])
        if ok and corpse then
            appendUnique(result, seen, corpse)
        end
    end
    -- Vehicles live in the chunk vehicle list rather than square:getObjects();
    -- getVehicleContainer() is the B42.20 bridge needed for permanent removal.
    local okVehicle, vehicle = invoke(square, "getVehicleContainer")
    if okVehicle and vehicle then
        appendUnique(result, seen, vehicle)
    end
    return result
end

local function objectModData(object)
    local ok, data = invoke(object, "getModData")
    if ok and type(data) == "table" then
        return data
    end
    return nil
end

local function tagObject(object, generation, role, extraData)
    local data = objectModData(object)
    if not data then
        error("RailroaderRVTest: generated object has no modData for role " .. tostring(role))
    end
    if generation == nil or role == nil then
        error("RailroaderRVTest: generated object tag is incomplete")
    end
    data.owner = OWNER
    data.generation = generation
    data.role = role
    if data.RailroaderRVTest ~= nil and type(data.RailroaderRVTest) ~= "table" then
        error("RailroaderRVTest: generated object tag namespace is not a table")
    end
    data.RailroaderRVTest = data.RailroaderRVTest or {}
    data.RailroaderRVTest.owner = OWNER
    data.RailroaderRVTest.generation = generation
    data.RailroaderRVTest.role = role
    if type(extraData) == "table" then
        for key, value in pairs(extraData) do
            data.RailroaderRVTest[key] = value
        end
    end
    -- New objects are not on the client yet.  Do not transmit an object-index
    -- modData delta here: the creator sends one complete object packet after
    -- attachment and all object-specific state is final.  Existing objects
    -- (notably replaced floors) explicitly send their deltas in createFloor.
    local verify = objectModData(object)
    if not verify or verify.owner ~= OWNER or verify.role ~= role
        or toNumber(verify.generation) ~= toNumber(generation) then
        error("RailroaderRVTest: generated object tag verification failed for role " .. tostring(role))
    end
end

local function isTaggedForGeneration(object, generation)
    local data = objectModData(object)
    if not data then
        return false
    end
    if data.owner == OWNER and toNumber(data.generation) == toNumber(generation) then
        return true
    end
    local nested = data.RailroaderRVTest
    return type(nested) == "table" and nested.owner == OWNER
        and toNumber(nested.generation) == toNumber(generation)
end

local function isPlayerObject(object)
    if classInstance(object, "IsoPlayer") then
        return true
    end
    local ok, result = invoke(object, "isPlayer")
    return ok and result == true
end

local function isVehicleObject(object)
    if classInstance(object, "BaseVehicle") or classInstance(object, "IsoVehicle") then
        return true
    end
    local ok, result = invoke(object, "isVehicle")
    return ok and result == true
end

local function isOwnedRainBarrel(object)
    local data = objectModData(object)
    if type(data) ~= "table" then
        return false
    end
    if data.owner == OWNER and data.role == "rain_barrel" then
        return true
    end
    local nested = data.RailroaderRVTest
    return type(nested) == "table" and nested.owner == OWNER
        and nested.role == "rain_barrel"
end

local function getRainBarrelSystem()
    local class = rawget(_G, "SRainBarrelSystem")
    local instance = type(class) == "table" and class.instance or nil
    if instance then
        return instance
    end
    return nil
end

local function unregisterRainBarrelGlobalObject(object)
    -- B42.20's vanilla SRainBarrelSystem:isValidIsoObject() is deliberately
    -- `false`, so OnObjectAboutToBeRemoved cannot unregister this mod's barrel.
    -- Remove the public global-object entry explicitly while the IsoObject is
    -- still attached to its square; this is the inverse of newLuaObjectOnSquare.
    if not isOwnedRainBarrel(object) then
        return
    end
    local system = getRainBarrelSystem()
    if not system or not system.system then
        error("RailroaderRVTest: SRainBarrelSystem is unavailable while removing a rain barrel")
    end
    local square = select(2, invoke(object, "getSquare"))
    if not square then
        return
    end
    local x = floorInt(select(2, invoke(square, "getX")))
    local y = floorInt(select(2, invoke(square, "getY")))
    local z = floorInt(select(2, invoke(square, "getZ")))
    local globalObject = select(2, invoke(system.system, "getObjectAt", x, y, z))
    if not globalObject then
        return
    end
    local okLua, luaObject = invoke(system, "newLuaObject", globalObject)
    if not okLua or not luaObject then
        error("RailroaderRVTest: unable to wrap rain barrel global object for removal")
    end
    local removed = callSucceeded(system, "removeLuaObject", luaObject)
    if not removed then
        error("RailroaderRVTest: unable to unregister rain barrel global object")
    end
end

local function deregisterSpecialSystems(object)
    -- Explicitly unregister our barrel while it is still attached.  Vanilla's
    -- event bridge cannot see it because SRainBarrelSystem:isValidIsoObject()
    -- is false in B42.20.  The normal OnObjectAboutToBeRemoved event is owned
    -- by transmitRemoveItemFromSquare and must not be triggered here as well.
    unregisterRainBarrelGlobalObject(object)
end

local function removeCorpse(square, corpse)
    -- B42.20's signature is removeCorpse(IsoDeadBody, boolean).  Passing
    -- false lets the server emit RemoveCorpseFromMap; the old one-argument
    -- probe failed and the true (remote) fallback suppressed that packet.
    local ok = invoke(square, "removeCorpse", corpse, false)
    if not ok then
        error("RailroaderRVTest: B42.20 removeCorpse API is unavailable")
    end
end

local function removeZombie(square, zombie)
    -- IsoGameCharacter.dieNetwork(killer, weapon, gory, listener) is the
    -- dedicated-server death API.  Calling it with no arguments (the old
    -- implementation) never matched the B42.20 method and left clients with
    -- live zombies.
    local networkDied, body = invoke(zombie, "dieNetwork", nil, nil, true, nil)
    if not networkDied then
        invoke(zombie, "setHealth", 0)
        networkDied, body = invoke(zombie, "dieNetwork", nil, nil, true, nil)
    end
    if networkDied then
        if body then
            removeCorpse(square, body)
        end
        return
    end
    -- Single-player/debug fallback.  die() creates the corpse locally; the
    -- next square rebuild will include it in getDeadBodys if the engine keeps
    -- one, while these calls ensure the zombie itself is gone.
    invoke(zombie, "die")
    invoke(zombie, "removeFromWorld")
    invoke(zombie, "removeFromSquare")
end

local function removeAnimal(animal)
    -- IsoAnimal:delete() is the B42 removal entry point; no list mutation is
    -- performed directly, so the moving-object systems retain their invariants.
    invoke(animal, "delete")
    invoke(animal, "removeFromWorld")
    invoke(animal, "removeFromSquare")
end

local function removeVehicleSafely(vehicle)
    -- Do not guess at a vehicle removal path.  B42.20's permanent removal
    -- method performs the server-side persistence and network deletion.
    local ok = callSucceeded(vehicle, "permanentlyRemove")
    if not ok then
        error("RailroaderRVTest: vehicle present but B42.20 permanentlyRemove is unavailable")
    end
end

local function validateVehiclePath(vehicle)
    if type(vehicle.permanentlyRemove) ~= "function" then
        error("RailroaderRVTest: vehicle present but B42.20 permanentlyRemove is unavailable")
    end
end

local function getSpriteName(object)
    local spriteOk, sprite = invoke(object, "getSprite")
    if not spriteOk or not sprite then
        return nil
    end
    local nameOk, name = invoke(sprite, "getName")
    if not nameOk or name == nil then
        return nil
    end
    return tostring(name)
end

local function clearGenerationTag(object)
    local data = objectModData(object)
    if not data then
        error("RailroaderRVTest: generated object has no modData while clearing tag")
    end
    if data.owner == OWNER then
        data.owner = nil
        data.generation = nil
        data.role = nil
    end
    local nested = data.RailroaderRVTest
    if type(nested) == "table" and nested.owner == OWNER then
        nested.owner = nil
        nested.generation = nil
        nested.role = nil
        nested.previousSprite = nil
        nested.createdByGeneration = nil
        -- Keep the namespace itself.  The dedicated-server Kahlua runtime does
        -- not provide Lua's `next` primitive, and an empty namespace is safe;
        -- retaining it also avoids touching unrelated modData keys.
    end
    if not callSucceeded(object, "transmitModData") then
        error("RailroaderRVTest: generated object tag removal transmission failed")
    end
end

local function squareContainsObject(square, object)
    local objectsOk, objects = invoke(square, "getObjects")
    if not objectsOk or not objects then
        return nil
    end
    local sizeOk, size = invoke(objects, "size")
    local sizeNumber = toNumber(size)
    if not sizeOk or not sizeNumber then
        return nil
    end
    for i = 0, sizeNumber - 1 do
        local itemOk, item = invoke(objects, "get", i)
        if not itemOk then
            return nil
        end
        if item == object then
            return true
        end
    end
    return false
end

local function restoreTaggedFloor(square, object)
    local data = objectModData(object)
    local nested = data and data.RailroaderRVTest or nil
    if type(nested) ~= "table" or nested.owner ~= OWNER
        or nested.createdByGeneration ~= false or not nested.previousSprite then
        return false
    end

    local previousSprite = tostring(nested.previousSprite)
    local currentSprite = getSpriteName(object)
    if not currentSprite then
        error("RailroaderRVTest: tagged floor has no current sprite during rollback")
    end
    if currentSprite ~= previousSprite then
        local spriteOk, spriteObject = callGlobal("getSprite", previousSprite)
        if not spriteOk or not spriteObject then
            error("RailroaderRVTest: previous floor sprite is unavailable: " .. previousSprite)
        end
        if not callSucceeded(object, "setSprite", spriteObject)
            or not callSucceeded(object, "transmitUpdatedSpriteToClients") then
            error("RailroaderRVTest: previous floor sprite restoration failed")
        end
    end
    clearGenerationTag(object)
    return true
end

local function removeGenericObject(square, object, restoreTaggedFloors)
    local floor = select(2, invoke(square, "getFloor"))
    if restoreTaggedFloors and floor == object and restoreTaggedFloor(square, object) then
        return
    end
    deregisterSpecialSystems(object)
    local removeOk, removeIndex = invoke(square, "transmitRemoveItemFromSquare", object)
    local indexNumber = toNumber(removeIndex)
    if not removeOk or not indexNumber or indexNumber < 0 then
        error("RailroaderRVTest: object removal transmission failed")
    end
    -- On the B42 server this call delegates to GameServer.RemoveItemFromMap,
    -- which emits the packet, fires OnObjectAboutToBeRemoved, detaches the
    -- object from world/square, and recalculates neighbours.  Calling any of
    -- those steps again risks a double event or a second list mutation.
    local stillPresent = squareContainsObject(square, object)
    if stillPresent ~= false then
        error("RailroaderRVTest: object removal was not observable")
    end
end

local function removeObject(square, object, restoreTaggedFloors)
    if isPlayerObject(object) then
        return
    end
    if isVehicleObject(object) then
        removeVehicleSafely(object)
        return
    end
    if classInstance(object, "IsoZombie") then
        removeZombie(square, object)
        return
    end
    if classInstance(object, "IsoAnimal") then
        removeAnimal(object)
        return
    end
    if classInstance(object, "IsoDeadBody") then
        removeCorpse(square, object)
        return
    end
    removeGenericObject(square, object, restoreTaggedFloors)
end

local function recalcSquare(square)
    invoke(square, "RecalcProperties")
    -- B42.20 exposes the Java method as RecalcAllWithNeighbours(boolean).
    -- The lower-case spellings are not engine methods and silently made the
    -- old implementation leave collision/room caches stale.
    invoke(square, "RecalcAllWithNeighbours", true)
end

local function clearSquare(square, onlyGeneration)
    local objects = squareSnapshot(square)
    -- Validate all vehicles before removing any object on this square.  This
    -- makes an unknown vehicle API a clean transaction failure, not data loss.
    for i = 1, #objects do
        if isVehicleObject(objects[i]) and (not onlyGeneration or isTaggedForGeneration(objects[i], onlyGeneration)) then
            validateVehiclePath(objects[i])
        end
    end
    for i = 1, #objects do
        local object = objects[i]
        if not onlyGeneration or isTaggedForGeneration(object, onlyGeneration) then
            -- Generation rollback restores a tagged pre-existing floor, while
            -- the cleanup-only pass must remove every floor, including one
            -- left tagged by an earlier generation.
            removeObject(square, object, onlyGeneration ~= nil)
        end
    end
    recalcSquare(square)
end

local function boundsFor(layout)
    if type(layout) ~= "table" then
        error("RailroaderRVTest: layout plan is not a table")
    end
    local clear = layout.clear
    local room = layout.room
    local wall = layout.wall
    local roof = layout.roof
    local anchor = layout.anchor
    if type(clear) ~= "table" or type(room) ~= "table" or type(wall) ~= "table"
        or type(roof) ~= "table" or type(anchor) ~= "table" then
        error("RailroaderRVTest: layout bounds contract is incomplete")
    end
    local function firstValue(source, ...)
        for i = 1, select("#", ...) do
            local value = source[select(i, ...)]
            if value ~= nil then
                return value
            end
        end
        return nil
    end
    local function field(source, label, ...)
        local value = firstValue(source, ...)
        if value == nil then
            error("RailroaderRVTest: layout contract missing " .. label)
        end
        return requiredInteger(value, label)
    end
    -- RV_Layout exposes both x/y/z and cx/cy/cz for compatibility. Missing
    -- coordinates are rejected; they must never be coerced to world origin.
    local ax = requiredInteger(anchor.x or anchor.cx, "layout anchor.x")
    local ay = requiredInteger(anchor.y or anchor.cy, "layout anchor.y")
    local az = requiredInteger(anchor.z or anchor.cz, "layout anchor.z")
    local clearMinZ = requiredInteger(firstValue(clear, "minZ", "zMin", "min_z")
        or Constants.CLEAR_MIN_Z or Constants.CLEAR_Z_MIN or Constants.MIN_Z or Constants.Z_MIN,
        "layout clear.minZ")
    local clearMaxZ = requiredInteger(firstValue(clear, "maxZ", "zMax", "max_z")
        or Constants.CLEAR_MAX_Z or Constants.CLEAR_Z_MAX or Constants.MAX_Z or Constants.Z_MAX,
        "layout clear.maxZ")
    local clearMinX = field(clear, "layout clear.minX", "minX", "xMin", "min_x")
    local clearMaxX = field(clear, "layout clear.maxX", "maxX", "xMax", "max_x")
    local clearMinY = field(clear, "layout clear.minY", "minY", "yMin", "min_y")
    local clearMaxY = field(clear, "layout clear.maxY", "maxY", "yMax", "max_y")
    local roomMinX = field(room, "layout room.minX", "minX", "xMin", "min_x")
    local roomMaxX = field(room, "layout room.maxX", "maxX", "xMax", "max_x")
    local roomMinY = field(room, "layout room.minY", "minY", "yMin", "min_y")
    local roomMaxY = field(room, "layout room.maxY", "maxY", "yMax", "max_y")
    local wallMinX = field(wall, "layout wall.minX", "minX", "xMin", "min_x")
    local wallMaxX = field(wall, "layout wall.maxX", "maxX", "xMax", "max_x")
    local wallMinY = field(wall, "layout wall.minY", "minY", "yMin", "min_y")
    local wallMaxY = field(wall, "layout wall.maxY", "maxY", "yMax", "max_y")
    local roofMinX = field(roof, "layout roof.minX", "minX", "xMin", "min_x")
    local roofMaxX = field(roof, "layout roof.maxX", "maxX", "xMax", "max_x")
    local roofMinY = field(roof, "layout roof.minY", "minY", "yMin", "min_y")
    local roofMaxY = field(roof, "layout roof.maxY", "maxY", "yMax", "max_y")
    local roofZ = requiredInteger(layout.roofZ or roof.z, "layout roof.z")
    if type(layout.wallCoordinates) ~= "table" then
        error("RailroaderRVTest: layout wallCoordinates is missing")
    end
    local wallObjectCount = requiredInteger(layout.wallObjectCount, "layout wallObjectCount")
    local wallCoordinateCount = requiredInteger(layout.wallCoordinateCount, "layout wallCoordinateCount")
    local wallEdgeCounts = layout.wallEdgeCounts
    if type(wallEdgeCounts) ~= "table" then
        error("RailroaderRVTest: layout wallEdgeCounts is missing")
    end
    local northEdges = requiredInteger(wallEdgeCounts.north, "layout wallEdgeCounts.north")
    local westEdges = requiredInteger(wallEdgeCounts.west, "layout wallEdgeCounts.west")
    local wallCornerCount = requiredInteger(layout.wallCornerCount, "layout wallCornerCount")
    return {
        clearMinX = clearMinX, clearMaxX = clearMaxX,
        clearMinY = clearMinY, clearMaxY = clearMaxY,
        clearMinZ = clearMinZ, clearMaxZ = clearMaxZ,
        roomMinX = roomMinX, roomMaxX = roomMaxX,
        roomMinY = roomMinY, roomMaxY = roomMaxY,
        wallMinX = wallMinX, wallMaxX = wallMaxX,
        wallMinY = wallMinY, wallMaxY = wallMaxY,
        wallCoordinates = layout.wallCoordinates,
        wallObjectCount = wallObjectCount,
        wallCoordinateCount = wallCoordinateCount,
        wallEdgeCounts = layout.wallEdgeCounts,
        wallCornerCount = wallCornerCount,
        northEdges = northEdges, westEdges = westEdges,
        roofMinX = roofMinX, roofMaxX = roofMaxX,
        roofMinY = roofMinY, roofMaxY = roofMaxY,
        z = az,
        roofZ = roofZ,
    }
end

local function walkBounds(cell, bounds, fn)
    for z = bounds.clearMinZ, bounds.clearMaxZ do
        for x = bounds.clearMinX, bounds.clearMaxX do
            for y = bounds.clearMinY, bounds.clearMaxY do
                local square = getSquare(cell, x, y, z)
                if square then
                    fn(square, x, y, z)
                end
            end
        end
    end
end

local function validateWallContract(bounds)
    if type(bounds.wallCoordinates) ~= "table" or #bounds.wallCoordinates ~= 92
        or bounds.wallObjectCount ~= 92 or bounds.wallCoordinateCount ~= 92
        or bounds.northEdges ~= 12 or bounds.westEdges ~= 80
        or bounds.wallCornerCount ~= 2 then
        error("RailroaderRVTest: wall layout contract is invalid")
    end
    local coordinates, orientations, exact, both = {}, {}, {}, {}
    local uniqueCoordinates, northEdges, westEdges, corners = 0, 0, 0, 0
    local nwKey = tostring(bounds.wallMinX) .. ":" .. tostring(bounds.wallMinY)
        .. ":" .. tostring(bounds.z)
    local seKey = tostring(bounds.wallMaxX) .. ":" .. tostring(bounds.wallMaxY)
        .. ":" .. tostring(bounds.z)
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        if type(entry) ~= "table" or type(entry.x) ~= "number"
            or type(entry.y) ~= "number" or type(entry.z) ~= "number"
            or type(entry.north) ~= "boolean" or type(entry.role) ~= "string"
            or type(entry.sprite) ~= "string" or type(entry.corner) ~= "boolean" then
            error("RailroaderRVTest: malformed wall entry at index " .. tostring(i))
        end
        local x = requiredInteger(entry.x, "wall[" .. tostring(i) .. "].x")
        local y = requiredInteger(entry.y, "wall[" .. tostring(i) .. "].y")
        local z = requiredInteger(entry.z, "wall[" .. tostring(i) .. "].z")
        if x < bounds.wallMinX or x > bounds.wallMaxX
            or y < bounds.wallMinY or y > bounds.wallMaxY or z ~= bounds.z then
            error("RailroaderRVTest: wall entry is outside the wall bounds")
        end
        local coordinateKey = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        local orientation = entry.north and "north" or "west"
        local orientationKey = coordinateKey .. ":" .. orientation
        local exactKey = orientationKey .. ":" .. entry.role
        if exact[exactKey] or orientations[orientationKey] then
            error("RailroaderRVTest: duplicate wall coordinate/orientation")
        end
        exact[exactKey] = true
        orientations[orientationKey] = true
        if not coordinates[coordinateKey] then
            coordinates[coordinateKey] = true
            uniqueCoordinates = uniqueCoordinates + 1
        end
        both[coordinateKey] = both[coordinateKey] or {}
        both[coordinateKey][orientation] = true
        local expectedRole = "wall-" .. orientation
        local expectedSprite = entry.north
            and (Constants.WALL_NORTH_SPRITE or "walls_interior_house_03_21")
            or (Constants.WALL_WEST_SPRITE or "walls_interior_house_03_20")
        if entry.corner then
            if coordinateKey == nwKey then
                expectedRole = "corner-nw"
                expectedSprite = Constants.WALL_NW_SPRITE or "walls_interior_house_03_22"
            elseif coordinateKey == seKey then
                expectedRole = "corner-se"
                expectedSprite = Constants.WALL_SE_SPRITE or "walls_interior_house_03_23"
            else
                error("RailroaderRVTest: corner wall is not at NW or SE")
            end
        end
        if entry.role ~= expectedRole or entry.sprite ~= expectedSprite then
            error("RailroaderRVTest: wall role/sprite does not match orientation")
        end
        if entry.north then northEdges = northEdges + 1 else westEdges = westEdges + 1 end
        if entry.corner == true then corners = corners + 1 end
    end
    for coordinateKey, orientationSet in pairs(both) do
        if orientationSet.north and orientationSet.west then
            error("RailroaderRVTest: wall ring cannot duplicate an orientation at " .. coordinateKey)
        end
    end
    if uniqueCoordinates ~= 92 or northEdges ~= 12 or westEdges ~= 80 or corners ~= 2 then
        error("RailroaderRVTest: wall contract must contain 92 coordinates/objects, north12/west80/corner2")
    end
end

-- Validate only the fixed target contract and world coordinates.  This helper
-- deliberately never reads an IsoGridSquare: queueGeneration must be able to
-- reject an impossible destination before sending Relocate, while the
-- post-teleport preflight below remains responsible for waiting on loaded
-- squares.
local function validateTargetCoordinates(bounds, destination)
    if type(bounds) ~= "table" then
        error("RailroaderRVTest: target bounds are not a table")
    end
    if type(destination) ~= "table" then
        error("RailroaderRVTest: relocation destination is not a table")
    end

    local targetX = requiredInteger(destination.x, "relocation target x")
    local targetY = requiredInteger(destination.y, "relocation target y")
    local targetZ = requiredInteger(destination.z, "relocation target z")
    local expectedX = requiredInteger(Constants.TELEPORT_X,
        "shared teleport target x")
    local expectedY = requiredInteger(Constants.TELEPORT_Y,
        "shared teleport target y")
    local expectedZ = requiredInteger(Constants.TELEPORT_Z,
        "shared teleport target z")
    if targetX ~= expectedX or targetY ~= expectedY or targetZ ~= expectedZ then
        error("RailroaderRVTest: relocation target is not the fixed shared destination")
    end

    if targetZ < WORLD_MIN_Z or targetZ > WORLD_MAX_Z
        or bounds.clearMinZ < WORLD_MIN_Z or bounds.clearMaxZ > WORLD_MAX_Z
        or bounds.clearMinZ > bounds.clearMaxZ
        or bounds.z < WORLD_MIN_Z or bounds.z > WORLD_MAX_Z
        or bounds.roofZ < WORLD_MIN_Z or bounds.roofZ > WORLD_MAX_Z then
        error("RailroaderRVTest: layout z bounds are outside the legal world")
    end
    -- The cleanup footprint is strictly x=20000..20100, y=2000..2100 for
    -- the fixed (20050,2050) destination; keep the inclusive 101x101
    -- contract explicit here.
    if bounds.clearMinX ~= targetX - 50 or bounds.clearMaxX ~= targetX + 50
        or bounds.clearMinY ~= targetY - 50 or bounds.clearMaxY ~= targetY + 50
        or bounds.z ~= targetZ then
        error("RailroaderRVTest: clear footprint does not match the fixed target")
    end
    if bounds.clearMaxX - bounds.clearMinX + 1 ~= 101
        or bounds.clearMaxY - bounds.clearMinY + 1 ~= 101 then
        error("RailroaderRVTest: clear footprint must be exactly 101x101")
    end
    if bounds.roomMaxX - bounds.roomMinX + 1 ~= 6
        or bounds.roomMaxY - bounds.roomMinY + 1 ~= 40 then
        error("RailroaderRVTest: room footprint must be exactly 6x40")
    end
    if bounds.wallMaxX - bounds.wallMinX + 1 ~= 7
        or bounds.wallMaxY - bounds.wallMinY + 1 ~= 41 then
        error("RailroaderRVTest: wall footprint must be exactly 7x41")
    end
    if bounds.roofMaxX - bounds.roofMinX + 1 ~= 6
        or bounds.roofMaxY - bounds.roofMinY + 1 ~= 40 then
        error("RailroaderRVTest: roof footprint must be exactly 6x40")
    end
    if targetX < bounds.roomMinX or targetX > bounds.roomMaxX
        or targetY < bounds.roomMinY or targetY > bounds.roomMaxY then
        error("RailroaderRVTest: final relocation center is outside the interior")
    end
    if bounds.roofZ ~= bounds.z + 1 then
        error("RailroaderRVTest: roof must be exactly one level above the base")
    end
    validateWallContract(bounds)

    local worldOk, world = callGlobal("getWorld")
    if not worldOk or not world then
        error("RailroaderRVTest: getWorld is unavailable for coordinate validation")
    end
    local function validWorldCoordinate(x, y, z, role)
        if z < WORLD_MIN_Z or z > WORLD_MAX_Z then
            error("RailroaderRVTest: " .. tostring(role) .. " is outside legal z range")
        end
        local validOk, valid = invoke(world, "isValidSquare", x, y, z)
        if not validOk or valid ~= true then
            error("RailroaderRVTest: " .. tostring(role) .. " is outside the legal world")
        end
    end

    validWorldCoordinate(targetX, targetY, targetZ, "relocation target")
    -- Validate the entire required 101x101 base footprint without requiring any
    -- of those remote squares to be loaded yet.
    for y = bounds.clearMinY, bounds.clearMaxY do
        for x = bounds.clearMinX, bounds.clearMaxX do
            validWorldCoordinate(x, y, bounds.z, "base")
        end
    end
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        local x = requiredInteger(entry.x, "wall[" .. tostring(i) .. "].x")
        local y = requiredInteger(entry.y, "wall[" .. tostring(i) .. "].y")
        local z = requiredInteger(entry.z, "wall[" .. tostring(i) .. "].z")
        if z ~= bounds.z then
            error("RailroaderRVTest: wall entry is not on the base z level")
        end
        validWorldCoordinate(x, y, z, "wall")
    end
    -- The upper footprint must be legal, but its squares may remain nil until
    -- the player-building phase creates them.
    for y = bounds.roofMinY, bounds.roofMaxY do
        for x = bounds.roofMinX, bounds.roofMaxX do
            validWorldCoordinate(x, y, bounds.roofZ, "roof")
        end
    end
end

local function preflightLoaded(cell, bounds, allowIncomplete)
    if not cell then
        error("RailroaderRVTest: preflight has no IsoCell")
    end
    validateTargetCoordinates(bounds, {
        x = Constants.TELEPORT_X,
        y = Constants.TELEPORT_Y,
        z = Constants.TELEPORT_Z,
    })
    local function requiredLoaded(x, y, z, role)
        local square = getSquare(cell, x, y, z)
        if not square then
            local message = "RailroaderRVTest: required " .. tostring(role)
                .. " square is not loaded at " .. tostring(x) .. ","
                .. tostring(y) .. "," .. tostring(z)
            -- A missing square is the normal result while the remote
            -- teleport is still streaming its target cells.  The polling
            -- caller must receive a status instead of raising a Kahlua
            -- exception on every OnTick; strict callers still fail closed.
            if allowIncomplete then
                return nil, message
            end
            error(message)
        end
        return square
    end

    -- All 10201 base squares must already exist before any clear/remove pass.
    for y = bounds.clearMinY, bounds.clearMaxY do
        for x = bounds.clearMinX, bounds.clearMaxX do
            local square, reason = requiredLoaded(x, y, bounds.z, "base")
            if not square then
                return false, reason
            end
        end
    end
    -- The explicit oriented wall list is part of the same loaded base layer.
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        local x = requiredInteger(entry.x, "wall[" .. tostring(i) .. "].x")
        local y = requiredInteger(entry.y, "wall[" .. tostring(i) .. "].y")
        local z = requiredInteger(entry.z, "wall[" .. tostring(i) .. "].z")
        if z ~= bounds.z then
            error("RailroaderRVTest: wall entry is not on the base z level")
        end
        local square, reason = requiredLoaded(x, y, z, "wall")
        if not square then
            return false, reason
        end
    end
    return true
end

-- A remote teleport is also the engine's chunk-streaming trigger.  The target
-- may therefore be unloaded when queueGeneration sends the relocation command.
-- Retry only the two expected loading failures here; malformed contracts or
-- other engine failures cancel the request before any world mutation.
local function targetAreaLoadStatus(player, bounds)
    local cellOk, cellOrError = pcall(getCellForPlayer, player)
    if not cellOk then
        local message = safeErrorText(cellOrError)
        if string.find(message, "no IsoCell available", 1, true) then
            return false, message
        end
        return nil, message
    end
    local preflightOk, loaded, preflightError = pcall(preflightLoaded,
        cellOrError, bounds, true)
    if not preflightOk then
        -- Unexpected contract/engine errors remain a hard cancellation; only
        -- the explicit incomplete-footprint status is retryable.
        return nil, safeErrorText(loaded)
    end
    if loaded == true then
        return true
    end
    if loaded == false then
        return false, safeErrorText(preflightError)
    end
    return nil, "RailroaderRVTest: loaded-area preflight returned no status"
end

local function removeOldGeneration(cell, manifest)
    local generation = toNumber(manifest.generation)
    local oldBounds = manifest.bounds
    if not generation or type(oldBounds) ~= "table" then
        return
    end
    walkBounds(cell, oldBounds, function(square)
        clearSquare(square, generation)
    end)
end

local function eachStructureSquare(cell, bounds, callback)
    if type(bounds) ~= "table" then
        return
    end
    local function visit(x, y, z)
        local square = getSquare(cell, x, y, z)
        if square then
            callback(square, x, y, z)
        end
    end
    local baseZ = requiredInteger(bounds.z, "saved bounds z")
    for x = requiredInteger(bounds.wallMinX, "saved bounds wallMinX"),
        requiredInteger(bounds.wallMaxX, "saved bounds wallMaxX") do
        for y = requiredInteger(bounds.wallMinY, "saved bounds wallMinY"),
            requiredInteger(bounds.wallMaxY, "saved bounds wallMaxY") do
            visit(x, y, baseZ)
        end
    end
    -- The complete 7x41 wall rectangle already contains the 6x40 interior.
    -- Do not add a second room loop: it only revisits the same base squares and
    -- can hide an incomplete wall scan behind a de-duplication table.
    local roofZ = requiredInteger(bounds.roofZ, "saved bounds roofZ")
    for x = requiredInteger(bounds.roofMinX, "saved bounds roofMinX"),
        requiredInteger(bounds.roofMaxX, "saved bounds roofMaxX") do
        for y = requiredInteger(bounds.roofMinY, "saved bounds roofMinY"),
            requiredInteger(bounds.roofMaxY, "saved bounds roofMaxY") do
            visit(x, y, roofZ)
        end
    end
end

local function clearInvalidRoomOwnershipReferences(cell, oldBounds, newBounds)
    local cleared = 0
    local seen = {}
    local function inspect(square, x, y, z)
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if seen[key] then
            return
        end
        seen[key] = true
        local roomOk, room = invoke(square, "getRoom")
        if not roomOk or room == nil then
            return
        end
        local roomDefOk, roomDef = invoke(square, "getRoomDef")
        if not roomDefOk then
            error("RailroaderRVTest: room definition inspection failed")
        end
        -- WorldRegionToMetaGrid.removeIsoRoom clears IsoRoom.def before every
        -- square has necessarily lost the retired room ID. Only that exact
        -- invalid reference is corrected. Valid old/new rooms, including an
        -- overlapping replacement, are never modified.
        if roomDef == nil then
            if not callSucceeded(square, "setRoomID", -1) then
                error("RailroaderRVTest: invalid room ownership reset failed")
            end
            local verifyOk, verifyRoom = invoke(square, "getRoom")
            if not verifyOk or verifyRoom ~= nil then
                error("RailroaderRVTest: invalid room ownership reset did not take effect")
            end
            cleared = cleared + 1
        end
    end
    eachStructureSquare(cell, oldBounds, inspect)
    eachStructureSquare(cell, newBounds, inspect)
    return cleared
end

local function registerServerRoomOwnershipGuard(generation, player, oldBounds, newBounds)
    local guard = {
        generation = generation,
        player = player,
        oldBounds = oldBounds,
        newBounds = newBounds,
        ticks = 0,
        stableTicks = 0,
        totalCleared = 0,
    }
    roomOwnershipGuards[generation] = guard
    return guard
end

local function refreshServerRoomOwnershipGuard(guard, phase)
    local cleared = clearInvalidRoomOwnershipReferences(getCellForPlayer(guard.player),
        guard.oldBounds, guard.newBounds)
    guard.totalCleared = guard.totalCleared + cleared
    if cleared > 0 or phase ~= nil then
        print("[RailroaderRVTest] room ownership refresh generation="
            .. tostring(guard.generation) .. " phase=" .. tostring(phase or "tick")
            .. " cleared=" .. tostring(cleared))
    end
    return cleared
end

local function processServerRoomOwnershipGuards()
    local finished = {}
    for generation, guard in pairs(roomOwnershipGuards) do
        guard.ticks = guard.ticks + 1
        local ok, clearedOrError = pcall(refreshServerRoomOwnershipGuard, guard, nil)
        if not ok then
            guard.stableTicks = 0
            guard.lastError = safeErrorText(clearedOrError)
        elseif clearedOrError > 0 then
            guard.stableTicks = 0
            guard.lastError = nil
        else
            guard.stableTicks = guard.stableTicks + 1
            guard.lastError = nil
        end
        if guard.ticks >= ROOM_OWNERSHIP_MAX_TICKS then
            print("[RailroaderRVTest] room ownership guard expired generation="
                .. tostring(generation) .. " cleared=" .. tostring(guard.totalCleared)
                .. (guard.lastError and " error=" .. guard.lastError or ""))
            finished[#finished + 1] = generation
        elseif guard.ticks >= ROOM_OWNERSHIP_MIN_TICKS
            and guard.stableTicks >= ROOM_OWNERSHIP_STABLE_TICKS then
            print("[RailroaderRVTest] room ownership guard complete generation="
                .. tostring(generation) .. " cleared=" .. tostring(guard.totalCleared))
            finished[#finished + 1] = generation
        end
    end
    for i = 1, #finished do
        roomOwnershipGuards[finished[i]] = nil
    end
end

local function copyRoomRefreshBounds(target, prefix, bounds)
    local fields = {
        "wallMinX", "wallMaxX", "wallMinY", "wallMaxY",
        "roomMinX", "roomMaxX", "roomMinY", "roomMaxY",
        "roofMinX", "roofMaxX", "roofMinY", "roofMaxY", "z", "roofZ",
    }
    for i = 1, #fields do
        local field = fields[i]
        target[prefix .. field] = requiredInteger(bounds[field],
            "room refresh " .. prefix .. field)
    end
end

local function armClientRoomOwnershipGuard(generation, oldBounds, newBounds)
    local payload = {
        generation = generation,
        hasOld = type(oldBounds) == "table",
    }
    if payload.hasOld then
        copyRoomRefreshBounds(payload, "old", oldBounds)
    end
    copyRoomRefreshBounds(payload, "new", newBounds)
    -- The no-player overload broadcasts to every connected client. A player
    -- other than the requester may later walk through the retired footprint.
    if not callGlobal("sendServerCommand", COMMAND_MODULE,
        COMMAND_REFRESH_ROOM_OWNERSHIP, payload) then
        error("RailroaderRVTest: client room ownership guards could not be armed")
    end
end

local function removeGeneration(cell, bounds, generation)
    if not cell or type(bounds) ~= "table" or not generation then
        return
    end
    -- Failed builds are rolled back by the same owner+generation tag used by
    -- repeat generation.  This includes roof floors, generators, barrels and
    -- the final light, even when the failure occurs in the last phase.
    walkBounds(cell, bounds, function(square)
        clearSquare(square, generation)
    end)

    -- A successful pcall around clearSquare is not enough on a dedicated
    -- server: transmitRemoveItemFromSquare owns the packet, event, local
    -- detach, and neighbour recalculation.  Verify the authoritative cell has
    -- no tagged object left before reporting rollback=COMPLETE.
    local remaining = 0
    walkBounds(cell, bounds, function(square)
        local objects = squareSnapshot(square)
        for i = 1, #objects do
            if isTaggedForGeneration(objects[i], generation) then
                remaining = remaining + 1
            end
        end
    end)
    if remaining > 0 then
        error("RailroaderRVTest: rollback verification found " .. tostring(remaining)
            .. " tagged objects still present")
    end
end

local function ensureRoofSquare(cell, x, y, z)
    -- B42's player-building path creates a missing upper square with the
    -- IsoGridSquare constructor, then connects it to the cell.  Keep this
    -- operation idempotent so a retry reuses an existing square (including a
    -- square left empty after a failed addFloor) instead of creating a
    -- duplicate/unconnected object.
    local square = getSquare(cell, x, y, z)
    if square then
        return square
    end

    local cls = rawget(_G, "IsoGridSquare")
    local constructed, created = invokeClass(cls, {
        -- Match official BuildRecipeCode/buildRecipeCode.lua exactly:
        -- IsoGridSquare.new(cell, nil, x, y, z), followed by ConnectNewSquare.
        { cell, nil, x, y, z },
    })
    if constructed then
        if not callSucceeded(cell, "ConnectNewSquare", created, false) then
            error("RailroaderRVTest: unable to connect roof square")
        end
    else
        -- Keep the official DebugIsoRegionsEdit construction API as a narrow
        -- compatibility fallback for bindings that do not expose the class
        -- constructor.  This method connects the square itself.
        local createdOk, fallback = invoke(cell, "createNewGridSquare", x, y, z, true)
        if not createdOk or not fallback then
            error("RailroaderRVTest: unable to construct roof square")
        end
    end

    local connected = getSquare(cell, x, y, z)
    if not connected then
        error("RailroaderRVTest: roof square construction was not observable")
    end
    return connected
end

local function createFloor(square, sprite, generation, role)
    if not sprite then
        error("RailroaderRVTest: floor sprite is not configured")
    end
    local ok, floor = invoke(square, "getFloor")
    local hadFloor = ok and floor ~= nil
    local previousSprite
    local createdByGeneration = not hadFloor
    if hadFloor then
        previousSprite = getSpriteName(floor)
        if not previousSprite then
            error("RailroaderRVTest: existing floor has no sprite")
        end
        -- Metal and wood are two phases over the same object.  Keep the first
        -- pre-generation sprite so rollback can restore the original floor;
        -- the wood/roof stages never overwrite this initial snapshot.
        local existingData = objectModData(floor)
        local existingTag = existingData and existingData.RailroaderRVTest or nil
        if type(existingTag) == "table" and existingTag.owner == OWNER
            and existingTag.previousSprite
            and toNumber(existingTag.generation) == toNumber(generation) then
            previousSprite = tostring(existingTag.previousSprite)
            createdByGeneration = existingTag.createdByGeneration == true
        end
    end
    if not ok or not floor then
        local added = callSucceeded(square, "addFloor", sprite)
        if not added then
            error("RailroaderRVTest: addFloor failed")
        end
        ok, floor = invoke(square, "getFloor")
    else
        local spriteObject = select(2, callGlobal("getSprite", sprite))
        if spriteObject then
            if not callSucceeded(floor, "setSprite", spriteObject) then
                error("RailroaderRVTest: floor sprite update failed")
            end
        else
            if not callSucceeded(floor, "setSprite", sprite) then
                error("RailroaderRVTest: floor sprite update failed")
            end
        end
    end
    if not floor then
        error("RailroaderRVTest: floor object was not created")
    end
    local tagged, tagError = pcall(tagObject, floor, generation, role, {
        previousSprite = previousSprite,
        createdByGeneration = createdByGeneration,
    })
    if not tagged then
        local removed, removeError = pcall(removeGenericObject, square, floor)
        if not removed then
            error(tostring(tagError) .. " (untagged floor cleanup failed: "
                .. tostring(removeError) .. ")")
        end
        error(tagError)
    end
    if hadFloor then
        -- This floor is already present in the client object map.  Send the
        -- two independent deltas explicitly: the replacement sprite and the
        -- generation snapshot/tag.  Neither delta is valid for a new object.
        if not callSucceeded(floor, "transmitUpdatedSpriteToClients") then
            error("RailroaderRVTest: existing floor sprite transmission failed")
        end
        if not callSucceeded(floor, "transmitModData") then
            error("RailroaderRVTest: existing floor modData transmission failed")
        end
    else
        -- A newly-added floor is absent from the client object map, so its
        -- complete packet is the sole initial object broadcast.
        if not callSucceeded(floor, "transmitCompleteItemToClients") then
            error("RailroaderRVTest: new floor client transmission failed")
        end
    end
    recalcSquare(square)
    return floor
end

local function addSpecialObject(square, object)
    -- IsoGenerator's B42.20 constructor already calls AddSpecialObject.  Do
    -- not insert it a second time; all other constructors arrive unattached.
    local indexOk, index = invoke(object, "getObjectIndex")
    local indexNumber = toNumber(index)
    local attached = indexOk and indexNumber and indexNumber >= 0
    local ok = attached
    if not attached then
        ok = callSucceeded(square, "AddSpecialObject", object)
    end
    if not ok then
        error("RailroaderRVTest: unable to attach object to square")
    end
    local indexOk, attachedIndex = invoke(object, "getObjectIndex")
    local attachedNumber = toNumber(attachedIndex)
    if not indexOk or not attachedNumber or attachedNumber < 0 then
        error("RailroaderRVTest: object attachment was not observable")
    end
    -- The caller must transmit exactly once, after all object-specific state is
    -- final.  Sending here made the subsequent light/generator/barrel sync send
    -- a second AddItemToMap for the same object index.
    recalcSquare(square)
end

local function addNormalObject(square, object)
    -- B42.20 has AddTileObject for ordinary IsoObject instances; AddObject
    -- and addObject are not IsoGridSquare methods.  Counters/sinks must remain
    -- tile objects so their sprite/entity behavior is preserved.
    local ok = callSucceeded(square, "AddTileObject", object)
    if not ok then
        error("RailroaderRVTest: unable to attach normal object to square")
    end
    local indexOk, attachedIndex = invoke(object, "getObjectIndex")
    local attachedNumber = toNumber(attachedIndex)
    if not indexOk or not attachedNumber or attachedNumber < 0 then
        error("RailroaderRVTest: normal object attachment was not observable")
    end
    -- The creator owns the one final full-object packet so plumbing/entity
    -- state can be completed before it is sent.
    recalcSquare(square)
end

local function hasEntityComponent(object, componentName)
    if componentName == "FluidContainer" then
        local containerOk, container = invoke(object, "getFluidContainer")
        return containerOk and container ~= nil
    end
    local componentTypes = rawget(_G, "ComponentType")
    local componentType = componentTypes and componentTypes[componentName] or nil
    if not componentType then
        return false
    end
    local hasOk, has = invoke(object, "hasComponent", componentType)
    if hasOk and has == true then
        return true
    end
    local componentOk, component = invoke(object, "getComponent", componentType)
    return componentOk and component ~= nil
end

local function createEntityFromSprite(object, sprite, requiredComponent)
    local configManager = rawget(_G, "SpriteConfigManager")
    if not configManager or type(configManager.getObjectInfoFromSprite) ~= "function" then
        return requiredComponent and false or nil
    end
    local okInfo, info = pcall(configManager.getObjectInfoFromSprite, sprite)
    if not okInfo or not info or type(info.getScript) ~= "function" then
        -- Ordinary furniture such as the counter/sink has no entity script;
        -- absence is not an entity-creation failure for those sprites.
        return requiredComponent and false or nil
    end
    local okScript, script = pcall(info.getScript, info)
    if not okScript or not script or type(script.getParent) ~= "function" then
        return false
    end
    local okParent, parent = pcall(script.getParent, script)
    if not okParent or not parent then
        return false
    end
    local factory = rawget(_G, "GameEntityFactory")
    if not factory or type(factory.CreateIsoObjectEntity) ~= "function" then
        return false
    end
    -- The factory is the B42.20-supported way to attach FluidContainer and
    -- other entity components to an IsoObject created from a sprite.
    -- CreateIsoObjectEntity is Java void; pcall success is only invocation
    -- success, never a returned entity value.
    local okEntity = pcall(factory.CreateIsoObjectEntity, object, parent, true)
    if not okEntity then
        return false
    end
    -- The factory catches its own Java exceptions, so also require the script
    -- component to be observable on the same IsoObject after the call.
    local attachedScriptOk, attachedScript = invoke(object, "getEntityScript")
    if not attachedScriptOk or not attachedScript then
        return false
    end
    if requiredComponent and not hasEntityComponent(object, requiredComponent) then
        return false
    end
    return true
end

local function createWall(cell, square, sprite, north, generation, role)
    local cls = rawget(_G, "IsoThumpable")
    local ok, wall = invokeClass(cls, {
        -- B42.20: IsoThumpable(IsoCell, IsoGridSquare, String, boolean,
        -- KahluaTable).  nil is the ordinary no-build-info table.
        { cell, square, sprite, north, nil },
    })
    if not ok then
        error("RailroaderRVTest: IsoThumpable construction failed")
    end
    if not callSucceeded(wall, "setIsThumpable", true) then
        error("RailroaderRVTest: wall initial state failed")
    end
    tagObject(wall, generation, role)
    addSpecialObject(square, wall)
    if not callSucceeded(wall, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: wall client transmission failed")
    end
    return wall
end

local function validatePlayerLightSprite(spriteObject, spriteName)
    local expectedSprite = Constants.LIGHT_SPRITE or "BuildingCraft_Light_17"
    if tostring(spriteName) ~= tostring(expectedSprite) then
        error("RailroaderRVTest: player light must be BuildCraft custom-house switch 1: "
            .. tostring(expectedSprite))
    end
    if not spriteObject then
        error("RailroaderRVTest: light sprite is unavailable: " .. tostring(spriteName))
    end
    local propertiesOk, properties = invoke(spriteObject, "getProperties")
    if not propertiesOk or not properties then
        error("RailroaderRVTest: light sprite has no property container: " .. tostring(spriteName))
    end

    -- BuildingCraft_Light_17 is the dependency's Custom House Light Switch 1.
    -- Requiring the tile metadata that IsoLightSwitch/addLightSourceFromSprite
    -- consumes prevents a system-house or decorative tile from silently
    -- creating a switch without the player-built-house semantics.
    local lightProperties = Constants.LIGHT_PROPERTIES or {
        attachedFlag = "attachedW",
        objectType = "lightswitch",
        movable = "IsMoveAble",
        radius = "LightRadius",
        red = "lightR",
        green = "lightG",
        blue = "lightB",
        customName = "CustomName",
        customNameValue = "Switch",
        groupName = "GroupName",
        groupNameValue = "Light",
        moveType = "MoveType",
        moveTypeValue = "WallObject",
    }

    -- PropertyContainer stores attachedW in its IsoFlagType bitset.  Passing
    -- the literal string to has() checks the ordinary key/value map instead,
    -- so a valid player-built wall lamp is falsely rejected.
    local flagTypes = rawget(_G, "IsoFlagType")
    local attachedFlag = flagTypes and flagTypes[lightProperties.attachedFlag]
    if not attachedFlag then
        error("RailroaderRVTest: IsoFlagType is unavailable for player light flag "
            .. tostring(lightProperties.attachedFlag))
    end
    local attachedOk, hasAttached = invoke(properties, "has", attachedFlag)
    if not attachedOk or hasAttached ~= true then
        error("RailroaderRVTest: player light sprite " .. tostring(spriteName)
            .. " is missing flag " .. tostring(lightProperties.attachedFlag))
    end

    -- `lightswitch` is an IsoObjectType enum, not an ordinary tile property.
    -- The tile definition may expose a same-named metadata entry, but the
    -- engine's moveable-light path decides the object class from getType().
    local objectTypes = rawget(_G, "IsoObjectType")
    local expectedType = objectTypes and objectTypes.lightswitch
    if not expectedType then
        error("RailroaderRVTest: IsoObjectType is unavailable for player light type "
            .. tostring(lightProperties.objectType))
    end
    local typeOk, spriteType = invoke(spriteObject, "getType")
    if not typeOk or spriteType ~= expectedType then
        error("RailroaderRVTest: player light sprite " .. tostring(spriteName)
            .. " is not IsoObjectType." .. tostring(lightProperties.objectType))
    end

    local required = {
        lightProperties.movable,
        lightProperties.radius,
        lightProperties.red,
        lightProperties.green,
        lightProperties.blue,
    }
    for i = 1, #required do
        local propertyName = required[i]
        local hasOk, hasProperty = invoke(properties, "has", propertyName)
        if not hasOk or hasProperty ~= true then
            error("RailroaderRVTest: player light sprite " .. tostring(spriteName)
                .. " is missing property " .. tostring(propertyName))
        end
    end

    local expectedMetadata = {
        { lightProperties.customName, lightProperties.customNameValue },
        { lightProperties.groupName, lightProperties.groupNameValue },
        { lightProperties.moveType, lightProperties.moveTypeValue },
    }
    for i = 1, #expectedMetadata do
        local propertyName, expectedValue = expectedMetadata[i][1], expectedMetadata[i][2]
        local valueOk, value = invoke(properties, "get", propertyName)
        if not valueOk or tostring(value) ~= tostring(expectedValue) then
            error("RailroaderRVTest: player light sprite " .. tostring(spriteName)
                .. " has unexpected " .. tostring(propertyName) .. " (expected "
                .. tostring(expectedValue) .. ")")
        end
    end
    for _, propertyName in ipairs({ lightProperties.radius, lightProperties.red,
        lightProperties.green, lightProperties.blue }) do
        local valueOk, value = invoke(properties, "get", propertyName)
        local numeric = toNumber(value)
        if not valueOk or not numeric then
            error("RailroaderRVTest: player light property is not numeric: "
                .. tostring(propertyName))
        end
    end
    return properties
end

local function createLight(cell, square, sprite, generation)
    local cls = rawget(_G, "IsoLightSwitch")
    local spriteOk, spriteObject = callGlobal("getSprite", sprite)
    if not spriteOk then
        error("RailroaderRVTest: getSprite failed for player light")
    end
    validatePlayerLightSprite(spriteObject, sprite)
    local roomOk, roomId = invoke(square, "getRoomID")
    if not roomOk or roomId == nil then
        roomId = -1
    end
    roomId = toNumber(roomId) or -1
    local ok, light = invokeClass(cls, {
        -- B42.20: IsoLightSwitch(IsoCell, IsoGridSquare, IsoSprite, long).
        { cell, square, spriteObject, roomId },
    })
    if not ok then
        error("RailroaderRVTest: IsoLightSwitch construction failed")
    end
    -- This is the BuildCraft player-built-light sequence adapted to B42.20:
    -- construct -> IsLighting/power -> sprite light source -> update -> add
    -- to square -> recalc -> activate/sync only after getObjectIndex exists.
    -- No hand-built independent light fallback is used; the sprite's RGB/radius
    -- properties are the single source of truth and avoid duplicate lights.
    local lightData = objectModData(light)
    if not lightData then
        error("RailroaderRVTest: player light has no modData")
    end
    lightData.IsLighting = true
    tagObject(light, generation, "light")
    if not callSucceeded(light, "setPower", 2) then
        error("RailroaderRVTest: player light initial state failed")
    end
    local addedLightOk = callSucceeded(light, "addLightSourceFromSprite")
    if not addedLightOk then
        error("RailroaderRVTest: addLightSourceFromSprite failed")
    end
    local lightsOk, lights = invoke(light, "getLights")
    local lightsSizeOk, lightsSize = invoke(lights, "size")
    if not lightsOk or not lights or not lightsSizeOk or (toNumber(lightsSize) or 0) < 1 then
        error("RailroaderRVTest: player light sprite produced no light source")
    end
    if not callSucceeded(light, "update") then
        error("RailroaderRVTest: player light update failed")
    end
    addSpecialObject(square, light)
    -- The object is now attached, so setActive can pass the engine's object
    -- index/electricity checks.  `ignoreSwitchCheck` is intentional for the
    -- technical test: the roof generator is built first, but its vertical
    -- power bridge is not an IsoRoom yet.
    if not callSucceeded(light, "setActivated", true) then
        error("RailroaderRVTest: player light activation failed")
    end
    local activeOk, active = invoke(light, "setActive", true, false, true)
    if not activeOk or active ~= true then
        if not callSucceeded(light, "switchLight", true) then
            error("RailroaderRVTest: player light switch failed")
        end
    end
    if not callSucceeded(light, "update")
        or not callSucceeded(light, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: player light synchronisation failed")
    end
    return light
end

local function createGenerator(cell, square, sprite, generation)
    local cls = rawget(_G, "IsoGenerator")
    -- B42.20's only world constructor is
    -- IsoGenerator(InventoryItem, IsoCell, IsoGridSquare).  The item carries
    -- the initial condition/fuel state and also selects the world sprite.
    local itemOk, item = callGlobal("instanceItem", "Base.Generator")
    if not itemOk or not item then
        error("RailroaderRVTest: Base.Generator item is unavailable")
    end
    invoke(item, "setCondition", 100)
    local itemDataOk, itemData = invoke(item, "getModData")
    if itemDataOk and type(itemData) == "table" then
        itemData.fuel = Constants.GENERATOR_INITIAL_FUEL or 10.0
    end
    local ok, generator = invokeClass(cls, {
        { item, cell, square },
    })
    if not ok then
        error("RailroaderRVTest: IsoGenerator construction failed")
    end
    tagObject(generator, generation, "generator")
    if not callSucceeded(generator, "setCondition", 100)
        or not callSucceeded(generator, "setFuel", Constants.GENERATOR_INITIAL_FUEL or 10.0)
        or not callSucceeded(generator, "setConnected", true)
        or not callSucceeded(generator, "setActivated", true) then
        error("RailroaderRVTest: generator initial state failed")
    end
    if type(cls.updateGenerator) == "function" then
        pcall(cls.updateGenerator, square)
    end
    -- IsoGenerator's B42.20 constructor attaches the object itself.  Keep the
    -- explicit helper after all local/tag state is final so it only validates
    -- that attachment and recalculates the square; it emits no packet.
    addSpecialObject(square, generator)
    if not callSucceeded(generator, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: generator client transmission failed")
    end
    return generator
end

local function getRainBarrelGlobalClass()
    local class = rawget(_G, "SRainBarrelGlobalObject")
    if class then
        return class
    end
    local requireFn = rawget(_G, "require")
    if type(requireFn) == "function" then
        pcall(requireFn, "RainBarrel/SRainBarrelGlobalObject")
    end
    return rawget(_G, "SRainBarrelGlobalObject")
end

local function getRainBarrelFluidContainer(barrel)
    -- IsoObject is itself the GameEntity in B42.20; the required component is
    -- therefore exposed directly on the barrel.  Do not probe a nonexistent
    -- nested getEntity() object or treat modData as the component state.
    local ok, container = invoke(barrel, "getFluidContainer")
    if ok and container then
        return container
    end
    return nil
end

local function getRainBarrelCapacity(barrel)
    local container = getRainBarrelFluidContainer(barrel)
    if not container then
        error("RailroaderRVTest: rain barrel FluidContainer component is unavailable")
    end
    -- B42.20's FluidContainer API exposes the authoritative capacity directly.
    -- Do not fall back to a guessed constant: a wrong entity script must fail
    -- before generation is reported as successful.
    local capacityOk, capacity = invoke(container, "getCapacity")
    capacity = toNumber(capacity)
    if not capacityOk or not capacity or capacity <= 0 then
        error("RailroaderRVTest: rain barrel FluidContainer capacity is unavailable"
            .. " (ok=" .. tostring(capacityOk) .. ", value=" .. tostring(capacity) .. ")")
    end
    return capacity, container
end

local function readRainBarrelFluidState(barrel, container)
    local state = {}
    state.amountOk, state.amount = invoke(container, "getAmount")
    state.amount = toNumber(state.amount)
    state.capacityOk, state.capacity = invoke(container, "getCapacity")
    state.capacity = toNumber(state.capacity)
    state.fullOk, state.full = invoke(container, "isFull")
    state.objectAmountOk, state.objectAmount = invoke(barrel, "getFluidAmount")
    state.objectAmount = toNumber(state.objectAmount)
    state.objectCapacityOk, state.objectCapacity = invoke(barrel, "getFluidCapacity")
    state.objectCapacity = toNumber(state.objectCapacity)
    state.taintedOk, state.tainted = invoke(barrel, "isTaintedWater")
    return state
end

local function rainBarrelFluidStateText(state)
    return "componentAmount=" .. tostring(state.amount)
        .. " componentCapacity=" .. tostring(state.capacity)
        .. " componentIsFull=" .. tostring(state.full)
        .. " objectAmount=" .. tostring(state.objectAmount)
        .. " objectCapacity=" .. tostring(state.objectCapacity)
        .. " objectTainted=" .. tostring(state.tainted)
end

local function rainBarrelFluidStateIsFull(state, expectedCapacity)
    local amount = state.amount
    local componentCapacity = state.capacity
    return state.amountOk and state.capacityOk and state.fullOk
        and amount ~= nil and componentCapacity ~= nil
        and math.abs(amount - expectedCapacity) <= 0.001
        and math.abs(componentCapacity - expectedCapacity) <= 0.001
        and state.full == true
end

local function refillRainBarrelFluid(container, barrel, capacity)
    -- `stateToIsoObject` already follows the vanilla bridge.  If the bridge's
    -- postcondition is not observable on this freshly-created entity, repair
    -- the same component through B42's supported FluidContainer methods.  The
    -- component API has Empty()/addFluid(), not setAmount()/setTainted*().
    local fluidTypes = rawget(_G, "FluidType")
    local fluidType = fluidTypes and (fluidTypes.TaintedWater or fluidTypes.Water) or nil
    if not fluidType then
        return false, "FluidType.TaintedWater and FluidType.Water are unavailable"
    end
    local emptied = callSucceeded(container, "Empty")
    local added = false
    if emptied then
        added = callSucceeded(container, "addFluid", fluidType, capacity)
    end
    local synced = false
    if emptied and added then
        synced = callSucceeded(barrel, "sync")
    end
    if not emptied or not added or not synced then
        return false, "Empty=" .. tostring(emptied)
            .. " addFluid=" .. tostring(added)
            .. " sync=" .. tostring(synced)
    end
    return true, nil
end

local function ensureRainBarrelGlobalObject(barrel)
    local system = getRainBarrelSystem()
    if not system or not system.system then
        error("RailroaderRVTest: SRainBarrelSystem is unavailable")
    end
    if not getRainBarrelGlobalClass() then
        error("RailroaderRVTest: SRainBarrelGlobalObject is unavailable")
    end
    local square = select(2, invoke(barrel, "getSquare"))
    if not square then
        error("RailroaderRVTest: rain barrel has no square")
    end
    local x = floorInt(select(2, invoke(square, "getX")))
    local y = floorInt(select(2, invoke(square, "getY")))
    local z = floorInt(select(2, invoke(square, "getZ")))
    local globalObject = select(2, invoke(system.system, "getObjectAt", x, y, z))
    local luaObject
    if globalObject then
        -- Loading is explicit because vanilla isValidIsoObject() is false.
        local wrapped, existing = invoke(system, "newLuaObject", globalObject)
        if not wrapped or not existing then
            error("RailroaderRVTest: unable to load rain barrel global object")
        end
        luaObject = existing
    else
        -- This is the public SGlobalObjectSystem creation API.  It calls
        -- SRainBarrelGlobalObject:new() and publishes the object to clients.
        local created, fresh = invoke(system, "newLuaObjectOnSquare", square)
        if not created or not fresh then
            error("RailroaderRVTest: unable to create rain barrel global object")
        end
        luaObject = fresh
        local initialized = callSucceeded(luaObject, "initNew")
        if not initialized then
            error("RailroaderRVTest: unable to initialize rain barrel global object")
        end
    end

    local capacity, fluidContainer = getRainBarrelCapacity(barrel)
    local outsideOk, outside = invoke(square, "isOutside")
    outside = outsideOk and outside == true or false
    luaObject.waterMax = capacity
    luaObject.waterAmount = capacity
    luaObject.exterior = outside
    luaObject.taintedWater = true

    -- Use the official global-object state bridge.  It writes the four
    -- SRainBarrelGlobalObject fields, fills the entity FluidContainer with
    -- tainted water, sets waterMax on IsoObject modData, and transmits it.
    local stateOk = callSucceeded(luaObject, "stateToIsoObject", barrel)
    if not stateOk then
        error("RailroaderRVTest: rain barrel stateToIsoObject failed")
    end

    -- Validate the component that GameEntityFactory attached, rather than
    -- relying only on IsoObject's convenience getter.  B42's FluidContainer
    -- implements getAmount()/getCapacity()/isFull(); these are the authoritative
    -- values used by the entity system and tolerate its documented float
    -- epsilon.  A failed state bridge is repaired once through Empty()+addFluid
    -- and remains a hard failure if the component still is not full.
    local fluidState = readRainBarrelFluidState(barrel, fluidContainer)
    local refillReason
    if not rainBarrelFluidStateIsFull(fluidState, capacity) then
        local refilled
        refilled, refillReason = refillRainBarrelFluid(fluidContainer, barrel, capacity)
        if refilled then
            luaObject.waterMax = capacity
            luaObject.waterAmount = capacity
            luaObject.taintedWater = true
            fluidState = readRainBarrelFluidState(barrel, fluidContainer)
        end
    end
    if not rainBarrelFluidStateIsFull(fluidState, capacity) then
        error("RailroaderRVTest: rain barrel fluid postcondition failed at capacity "
            .. tostring(capacity) .. " (" .. rainBarrelFluidStateText(fluidState)
            .. "; refill=" .. tostring(refillReason) .. ")")
    end

    -- The component is authoritative.  Mirror its observed amount/capacity in
    -- the vanilla global object and object modData, rather than assuming the
    -- requested capacity survived the bridge unchanged.
    luaObject.waterMax = fluidState.capacity
    luaObject.waterAmount = fluidState.amount
    luaObject.taintedWater = true
    local data = objectModData(barrel)
    if data then
        data.waterMax = fluidState.capacity
        data.waterAmount = fluidState.amount
        data.exterior = outside
        data.taintedWater = true
    end
    if not callSucceeded(barrel, "transmitModData") then
        error("RailroaderRVTest: rain barrel modData synchronisation failed")
    end
    local synced = callSucceeded(luaObject, "updateOnClient")
    if not synced then
        local fallbackSync = callSucceeded(system, "updateLuaObjectOnClient", luaObject)
        if not fallbackSync then
            error("RailroaderRVTest: rain barrel global object sync failed")
        end
    end
    return luaObject
end

local function createRainBarrel(cell, square, sprite, generation)
    local cls = rawget(_G, "IsoThumpable")
    local ok, barrel = invokeClass(cls, {
        -- Match vanilla MORainCollectorBarrel: a large full collector is a
        -- thumpable with its entity script supplying the FluidContainer.
        { cell, square, sprite, false, nil },
    })
    if not ok then
        error("RailroaderRVTest: rain barrel construction failed")
    end
    if not callSucceeded(barrel, "setName", "Rain Collector Barrel")
        or not callSucceeded(barrel, "setCanPassThrough", false)
        or not callSucceeded(barrel, "setCanBarricade", false)
        or not callSucceeded(barrel, "setBlockAllTheSquare", true)
        or not callSucceeded(barrel, "setIsThumpable", true) then
        error("RailroaderRVTest: rain barrel initial state failed")
    end
    if not createEntityFromSprite(barrel, sprite, "FluidContainer") then
        error("RailroaderRVTest: rain barrel entity script is unavailable")
    end
    tagObject(barrel, generation, "rain_barrel")
    addSpecialObject(square, barrel)
    -- The global-object bridge below emits object-index deltas (`sync`,
    -- `transmitModData`, and updateOnClient).  Publish the newly attached
    -- IsoObject exactly once before entering that bridge, so every later
    -- incremental update targets an object the client already knows.
    if not callSucceeded(barrel, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: rain barrel client transmission failed")
    end
    -- Do not rely on OnObjectAdded: B42.20's vanilla validity callback is
    -- fixed false.  Register/load the SRainBarrelGlobalObject directly.
    ensureRainBarrelGlobalObject(barrel)
    return barrel
end

local function createFurniture(cell, square, sprite, generation, role)
    local cls = rawget(_G, "IsoObject")
    local ok, object = invokeClass(cls, {
        { cell, square, sprite },
        { square, sprite },
    })
    if not ok then
        error("RailroaderRVTest: furniture construction failed for " .. tostring(role))
    end
    -- Some B42.20 sprites (including fluid fixtures) carry an entity script;
    -- attach it before AddTileObject so the engine initializes its components.
    local entityCreated = createEntityFromSprite(object, sprite)
    if entityCreated == false then
        error("RailroaderRVTest: furniture entity creation failed for " .. tostring(role))
    end
    tagObject(object, generation, role)
    addNormalObject(square, object)
    -- Counter and sink callers own the complete packet.  The sink publishes
    -- its initial object here at the call site, then sends plumbing deltas
    -- only after that packet has made the object visible to the client.
    return object
end

-- Error objects are not required to be strings in Lua.  Keep diagnostics
-- useful without allowing a hostile __tostring/debug implementation to
-- escape the transaction's protected/finalize path.
safeErrorText = function(err)
    local textOk, text = pcall(tostring, err)
    if not textOk or type(text) ~= "string" then
        text = "<error formatting failed>"
    end
    local debugTable = rawget(_G, "debug")
    if type(debugTable) == "table" and type(debugTable.traceback) == "function" then
        local traceOk, trace = pcall(debugTable.traceback, text, 3)
        if traceOk then
            local traceTextOk, traceText = pcall(tostring, trace)
            if traceTextOk and type(traceText) == "string" then
                return traceText
            end
        end
    end
    return text
end

local function setManifestState(manifest, state, reason)
    manifest.state = state
    manifest.updatedAt = os.time()
    if reason then
        manifest.lastError = safeErrorText(reason)
    end
    if ModData and type(ModData.transmit) == "function" then
        pcall(ModData.transmit, MANIFEST_KEY)
    end
end

local function manifestTable()
    if not ModData or type(ModData.getOrCreate) ~= "function" then
        error("RailroaderRVTest: ModData.getOrCreate is unavailable")
    end
    local manifest = ModData.getOrCreate(MANIFEST_KEY)
    if type(manifest) ~= "table" then
        error("RailroaderRVTest: manifest is not a table")
    end
    return manifest
end

local function setGenerationPhase(manifest, generation, phase)
    if manifest then
        manifest.phase = phase
        manifest.phaseGeneration = generation
        manifest.phaseUpdatedAt = os.time()
        if ModData and type(ModData.transmit) == "function" then
            pcall(ModData.transmit, MANIFEST_KEY)
        end
    end
    print("[RailroaderRVTest] generation=" .. tostring(generation)
        .. " phase=" .. tostring(phase))
end

local function recalcAndCheckStructure(cell, bounds)
    local seen = {}
    local checked = 0
    local function recalcAt(x, y, z)
            local square = getSquare(cell, x, y, z)
        if not square then
            error("RailroaderRVTest: structure square is not loaded")
        end
        local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z)
        if not seen[key] then
            seen[key] = true
            recalcSquare(square)
            checked = checked + 1
        end
        return square
    end

    -- Rebuild the lower-room and upper-floor neighbours before any entity
    -- object is placed.  This is the ordering used by the player-building
    -- scripts and makes roof/region probes observe the finished structure.
    for x = bounds.roomMinX, bounds.roomMaxX do
        for y = bounds.roomMinY, bounds.roomMaxY do
            recalcAt(x, y, bounds.z)
        end
    end
    for x = bounds.roofMinX, bounds.roofMaxX do
        for y = bounds.roofMinY, bounds.roofMaxY do
            local roofSquare = recalcAt(x, y, bounds.roofZ)
            local floorOk, floor = invoke(roofSquare, "getFloor")
            if not floorOk or not floor then
                error("RailroaderRVTest: roof floor missing after structure recalc")
            end
        end
    end
    for i = 1, #(bounds.wallCoordinates or {}) do
        local entry = bounds.wallCoordinates[i]
        recalcAt(entry.x, entry.y, bounds.z)
    end

    -- B42.20 can report room/roof metadata only after the neighbour pass.  A
    -- nil room is expected in this technical phase (IsoRoom registration is
    -- deferred), but probing it here keeps the phase observable and ensures
    -- the methods themselves are safe on the generated squares.
        local probe = getSquare(cell, bounds.roomMinX, bounds.roomMinY, bounds.z)
    if probe then
        invoke(probe, "getRoom")
        invoke(probe, "getRoomID")
        invoke(probe, "getRoofHideBuilding")
    end
    return checked
end

local function clearGenerationArea(cell, bounds, generation, manifest)
    setGenerationPhase(manifest, generation, "CLEARING")
    -- Cleanup is intentionally limited to already-loaded squares.  The
    -- snapshot/removal path handles zombies, corpses, trees, vegetation,
    -- rocks, decorative objects, and floors while emitting server-authoritative
    -- removal packets for every object it removes.
    walkBounds(cell, bounds, function(square)
        clearSquare(square, nil)
    end)
end

local function buildGeneration(player, layout, bounds, generation, manifest)
    local cell = getCellForPlayer(player)
    local woodSprite = Constants.WOOD_FLOOR_SPRITE or Constants.WOOD_FLOOR
    local northWallSprite = Constants.WALL_NORTH_SPRITE or Constants.WALL_SPRITE_NORTH
    local westWallSprite = Constants.WALL_WEST_SPRITE or Constants.WALL_SPRITE_WEST
    local nwWallSprite = Constants.WALL_NW_SPRITE or "walls_interior_house_03_22"
    local seWallSprite = Constants.WALL_SE_SPRITE or "walls_interior_house_03_23"
    local roofFloorSprite = Constants.ROOF_FLOOR_SPRITE or woodSprite
    local lightSprite = Constants.LIGHT_SPRITE or Constants.LIGHT_SWITCH_SPRITE
    local generatorSprite = Constants.GENERATOR_SPRITE or "appliances_misc_01_0"
    local barrelSprite = Constants.RAIN_BARREL_SPRITE or Constants.LARGE_RAIN_BARREL_SPRITE
    local counterSprite = Constants.COUNTER_SPRITE or "furniture_counters_01_0"
    local sinkSprite = Constants.SINK_SPRITE or "fixtures_sinks_01_0"
    if not woodSprite or not northWallSprite or not westWallSprite
        or not nwWallSprite or not seWallSprite
        or not roofFloorSprite or not lightSprite or not barrelSprite
        or not generatorSprite or not counterSprite or not sinkSprite then
        error("RailroaderRVTest: shared sprite contract is incomplete")
    end

    -- Keep every defensive feature point derived from the same authoritative
    -- anchor as RV_Layout.make(). The shared plan carries both x/y/z and
    -- cx/cy/cz spellings; accepting either keeps the compatibility surface
    -- explicit without inventing a layout when the shared planner fails.
    local anchor = layout.anchor or {}
    local anchorX = requiredInteger(anchor.x or anchor.cx, "layout anchor.x")
    local anchorY = requiredInteger(anchor.y or anchor.cy, "layout anchor.y")
    local anchorZ = requiredInteger(anchor.z or anchor.cz, "layout anchor.z")
    local lightPoint = copyPoint(layout.light, {
        x = anchorX - 2,
        y = anchorY,
        z = anchorZ,
    })
    -- A light is specifically a west-wall fixture. Keep this invariant even
    -- if a future layout contract supplies a decorative alternate point.
    lightPoint.x = anchorX - 2
    lightPoint.y = anchorY
    lightPoint.z = anchorZ

    setGenerationPhase(manifest, generation, "WOOD_FLOOR")
    -- Interior floor: exactly 6x40, using the shared carpet sprite.
    for x = bounds.roomMinX, bounds.roomMaxX do
        for y = bounds.roomMinY, bounds.roomMaxY do
            local square = getSquare(cell, x, y, bounds.z)
            if not square then
                error("RailroaderRVTest: interior square is not loaded")
            end
            createFloor(square, woodSprite, generation, "wood_floor")
        end
    end

    setGenerationPhase(manifest, generation, "WALLS")
    -- Apply the explicit wall ring from the shared layout.  NW and SE are
    -- single corner strips; all other entries are directional straight walls.
    local wallCoordinates = bounds.wallCoordinates or {}
    if #wallCoordinates ~= 92 then
        error("RailroaderRVTest: wall layout must contain exactly 92 objects")
    end
    local coordinateKeys = {}
    local orientationKeys = {}
    local exactKeys = {}
    local orientationByCoordinate = {}
    local uniqueCoordinates = 0
    local northEdges, westEdges, corners = 0, 0, 0
    local nwKey = tostring(bounds.wallMinX) .. ":" .. tostring(bounds.wallMinY)
        .. ":" .. tostring(bounds.z)
    local seKey = tostring(bounds.wallMaxX) .. ":" .. tostring(bounds.wallMaxY)
        .. ":" .. tostring(bounds.z)
    for i = 1, #wallCoordinates do
        local entry = wallCoordinates[i]
        if type(entry) ~= "table" or type(entry.x) ~= "number"
            or type(entry.y) ~= "number" or type(entry.z) ~= "number"
            or type(entry.north) ~= "boolean" or type(entry.role) ~= "string"
            or type(entry.sprite) ~= "string" or type(entry.corner) ~= "boolean" then
            error("RailroaderRVTest: malformed wall entry at index " .. tostring(i))
        end
        local coordinateKey = tostring(entry.x) .. ":" .. tostring(entry.y)
            .. ":" .. tostring(entry.z)
        local orientationKey = coordinateKey .. ":" .. (entry.north and "north" or "west")
        local exactKey = orientationKey .. ":" .. entry.role
        if exactKeys[exactKey] then
            error("RailroaderRVTest: duplicate wall coordinate/orientation/role " .. exactKey)
        end
        if orientationKeys[orientationKey] then
            error("RailroaderRVTest: duplicate wall direction " .. orientationKey)
        end
        exactKeys[exactKey] = true
        orientationKeys[orientationKey] = true
        if not coordinateKeys[coordinateKey] then
            coordinateKeys[coordinateKey] = true
            uniqueCoordinates = uniqueCoordinates + 1
        end
        orientationByCoordinate[coordinateKey] = orientationByCoordinate[coordinateKey] or {}
        orientationByCoordinate[coordinateKey][entry.north and "north" or "west"] = true
        local expectedRole = entry.north and "wall-north" or "wall-west"
        local expectedSprite = entry.north and northWallSprite or westWallSprite
        if entry.corner then
            if coordinateKey == nwKey then
                expectedRole = "corner-nw"
                expectedSprite = nwWallSprite
            elseif coordinateKey == seKey then
                expectedRole = "corner-se"
                expectedSprite = seWallSprite
            else
                error("RailroaderRVTest: corner wall is outside NW/SE")
            end
        end
        if entry.role ~= expectedRole or entry.sprite ~= expectedSprite then
            error("RailroaderRVTest: wall role does not match orientation at " .. coordinateKey)
        end
        if entry.north then northEdges = northEdges + 1 else westEdges = westEdges + 1 end
        if entry.corner then corners = corners + 1 end
    end
    for coordinateKey, orientations in pairs(orientationByCoordinate) do
        if orientations.north and orientations.west then
            error("RailroaderRVTest: wall ring cannot duplicate an orientation at " .. coordinateKey)
        end
    end
    if uniqueCoordinates ~= 92 or northEdges ~= 12 or westEdges ~= 80 or corners ~= 2 then
        error("RailroaderRVTest: wall contract must contain 92 coordinates/objects, north12/west80/corner2")
    end
    local function addWallAt(entry)
        local x, y = entry.x, entry.y
        local north, sprite, role = entry.north, entry.sprite, entry.role
        if entry.corner then
            local key = tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(entry.z)
            if key == nwKey then
                sprite = nwWallSprite
            elseif key == seKey then
                sprite = seWallSprite
            else
                error("RailroaderRVTest: corner wall is outside NW/SE")
            end
        elseif north then
            sprite = northWallSprite
        else
            sprite = westWallSprite
        end
        local square = getSquare(cell, x, y, bounds.z)
        if not square then
            error("RailroaderRVTest: wall square is not loaded")
        end
        createWall(cell, square, sprite, north, generation, role)
    end
    for i = 1, #wallCoordinates do
        addWallAt(wallCoordinates[i])
    end

    setGenerationPhase(manifest, generation, "ROOF_FLOOR")
    -- The roof is ordinary flat floor on z+1, exactly over the 6x40 interior.
    -- Preflight proved the footprint is legal.  Missing upper-level squares
    -- are created through the official player-building path before addFloor.
    for x = bounds.roofMinX, bounds.roofMaxX do
        for y = bounds.roofMinY, bounds.roofMaxY do
            local square = ensureRoofSquare(cell, x, y, bounds.roofZ)
            createFloor(square, roofFloorSprite, generation, "roof-floor")
        end
    end

    setGenerationPhase(manifest, generation, "STRUCTURE_RECALC")
    recalcAndCheckStructure(cell, bounds)

    setGenerationPhase(manifest, generation, "GENERATOR")
    local generatorPoint = copyPoint(layout.generator, { x = anchorX - 1, y = anchorY, z = anchorZ + 1 })
    local generatorSquare = getSquare(cell, generatorPoint.x, generatorPoint.y, bounds.roofZ)
    if not generatorSquare then
        error("RailroaderRVTest: generator square is not loaded")
    end
    createGenerator(cell, generatorSquare, generatorSprite, generation)

    setGenerationPhase(manifest, generation, "RAIN_BARREL")
    local barrelPoint = copyPoint(layout.barrel, { x = anchorX + 1, y = anchorY, z = anchorZ + 1 })
    local barrelSquare = getSquare(cell, barrelPoint.x, barrelPoint.y, bounds.roofZ)
    if not barrelSquare then
        error("RailroaderRVTest: rain barrel square is not loaded")
    end
    createRainBarrel(cell, barrelSquare, barrelSprite, generation)

    setGenerationPhase(manifest, generation, "COUNTER_SINK")
    -- The counter and sink are directly below the barrel's roof square.  The
    -- sink may share the counter square because it is placed on the counter.
    local counterPoint = copyPoint(layout.counter, { x = anchorX + 1, y = anchorY, z = anchorZ })
    local sinkPoint = copyPoint(layout.sink, { x = anchorX + 1, y = anchorY, z = anchorZ })
    counterPoint.x, counterPoint.y, counterPoint.z = barrelPoint.x, barrelPoint.y, bounds.z
    sinkPoint.x, sinkPoint.y, sinkPoint.z = barrelPoint.x, barrelPoint.y, bounds.z
    if sinkPoint.x == lightPoint.x and sinkPoint.y == lightPoint.y and sinkPoint.z == lightPoint.z then
        error("RailroaderRVTest: sink/light placement collides")
    end
    local counterSquare = getSquare(cell, counterPoint.x, counterPoint.y, bounds.z)
    local sinkSquare = getSquare(cell, sinkPoint.x, sinkPoint.y, bounds.z)
    if not counterSquare or not sinkSquare then
        error("RailroaderRVTest: counter or sink square is not loaded")
    end
    local counter = createFurniture(cell, counterSquare, counterSprite, generation, "counter")
    if not callSucceeded(counter, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: counter client transmission failed")
    end
    local sink = createFurniture(cell, sinkSquare, sinkSprite, generation, "sink")
    -- The sink is already attached by createFurniture.  Publish it before
    -- plumbing APIs below: setUsesExternalWaterSource/doFindExternalWaterSource
    -- and their official deltas address an object index that must exist on the
    -- client first.  Rollback removes this broadcast object if plumbing fails.
    if not callSucceeded(sink, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: sink client transmission failed")
    end
    -- IsoObject's B42.20 plumbing flag is setUsesExternalWaterSource; the
    -- setHasExternalWaterSource/setExternalWaterSource names do not exist.
    if not callSucceeded(sink, "setUsesExternalWaterSource", true)
        or not callSucceeded(sink, "doFindExternalWaterSource")
        or not callSucceeded(sink, "transmitModData") then
        error("RailroaderRVTest: sink water-source synchronisation failed")
    end
    -- IsoObject.sendObjectChange resolves the B42.20 enum, not an arbitrary
    -- string.  The official plumbing action uses this exact constant.
    if not IsoObjectChange or not IsoObjectChange.USES_EXTERNAL_WATER_SOURCE
        or not callSucceeded(sink, "sendObjectChange",
            IsoObjectChange.USES_EXTERNAL_WATER_SOURCE, { value = true }) then
        error("RailroaderRVTest: sink object-change synchronisation failed")
    end

    local lightSquare = getSquare(cell, lightPoint.x, lightPoint.y, lightPoint.z)
    if not lightSquare then
        error("RailroaderRVTest: light square is not loaded")
    end
    setGenerationPhase(manifest, generation, "LIGHT")
    -- The lamp is deliberately last: the structure, roof and generator are
    -- already attached, so the post-attach setActive/sync path has a valid
    -- square/object index and the failure rollback can remove all prior roles.
    createLight(cell, lightSquare, lightSprite, generation)
end

local function markGenerationFailed(manifest, errorText)
    if not manifest then
        return true, nil
    end
    local ok, failure = pcall(function()
        manifest.recovery = "RECOVERY_REQUIRED"
        manifest.phase = "FAILED"
        setManifestState(manifest, "FAILED", errorText)
    end)
    if ok then
        return true, nil
    end

    -- Preserve the persistent failure markers even if the normal state helper
    -- itself failed (for example, a debugger-supplied ModData implementation).
    -- Each fallback write is protected independently so cleanup can always
    -- reach the lock release below and the original failure remains visible.
    local fallbackOk, fallbackFailure = pcall(function()
        manifest.recovery = "RECOVERY_REQUIRED"
        manifest.phase = "FAILED"
        manifest.state = "FAILED"
        manifest.lastError = errorText
        manifest.updatedAt = os.time()
    end)
    if fallbackOk then
        return false, safeErrorText(failure)
    end
    return false, safeErrorText(failure) .. " (fallback manifest update failed: "
        .. safeErrorText(fallbackFailure) .. ")"
end

local function finalizeGeneration(manifest, ok, resultOrError)
    -- Protect the finalizer as well as the generation body.  This keeps an
    -- unexpected failure in diagnostics/ModData handling from bypassing the
    -- one unconditional release below.
    local finalized, finalResult, finalReason = pcall(function()
        local finalizationFailure
        if not ok then
            local errorText = safeErrorText(resultOrError)
            local marked, markerFailure = markGenerationFailed(manifest, errorText)
            if not marked then
                finalizationFailure = markerFailure
            end
        end

        if not ok then
            local message = safeErrorText(resultOrError)
            if finalizationFailure then
                message = message .. " (manifest finalization failed: "
                    .. safeErrorText(finalizationFailure) .. ")"
            end
            return false, message
        end
        return true, resultOrError
    end)

    -- This is the single lock-release point.  Keep it after all protected
    -- manifest work so no failure in diagnostics can strand the transaction.
    transactionBusy = false
    transactionPlayer = nil

    if not finalized then
        return false, safeErrorText(finalResult)
    end
    return finalResult, finalReason
end

local function readPlayerCoordinate(player, methodName, label)
    local ok, value = invoke(player, methodName)
    if not ok then
        error("RailroaderRVTest: authoritative player " .. tostring(label) .. " is unavailable")
    end
    local number = requiredNumber(value, "authoritative player " .. tostring(label))
    if methodName == "getZ" and (number < WORLD_MIN_Z or number > WORLD_MAX_Z) then
        error("RailroaderRVTest: authoritative player z is outside legal world range")
    end
    return number
end

local function validateAuthoritativePlayer(player)
    if not player or not classInstance(player, "IsoPlayer") then
        return false, "sender is not a valid IsoPlayer"
    end
    local deadOk, dead = invoke(player, "isDead")
    if not deadOk or dead ~= false then
        return false, "sender is dead or has no authoritative death state"
    end
    local px = readPlayerCoordinate(player, "getX", "x")
    local py = readPlayerCoordinate(player, "getY", "y")
    local pz = readPlayerCoordinate(player, "getZ", "z")
    local worldOk, world = callGlobal("getWorld")
    if not worldOk or not world then
        return false, "getWorld is unavailable"
    end
    local validOk, valid = invoke(world, "isValidSquare", math.floor(px), math.floor(py), math.floor(pz))
    if not validOk or valid ~= true then
        return false, "authoritative player coordinate is outside the legal world"
    end
    return true, {
        x = math.floor(px),
        y = math.floor(py),
        z = math.floor(pz),
    }
end

local function validateGenerationPermission(player)
    local capabilityClass = rawget(_G, "Capability")
    local requiredCapability = capabilityClass and capabilityClass.UseDebugContextMenu or nil
    if requiredCapability == nil then
        return false, "UseDebugContextMenu capability is unavailable"
    end
    local roleOk, role = invoke(player, "getRole")
    if not roleOk or role == nil then
        return false, "sender role is unavailable"
    end
    local capabilityOk, allowed = invoke(role, "hasCapability", requiredCapability)
    if not capabilityOk or allowed ~= true then
        return false, "sender lacks UseDebugContextMenu capability"
    end
    return true
end

local function playerIdentity(player)
    local idOk, onlineId = invoke(player, "getOnlineID")
    onlineId = idOk and toNumber(onlineId) or nil
    if not isFiniteNumber(onlineId) or math.floor(onlineId) ~= onlineId or onlineId < 0 then
        return false, "sender has no stable online ID"
    end
    local usernameOk, username = invoke(player, "getUsername")
    if not usernameOk or type(username) ~= "string" or username == "" then
        return false, "sender has no stable username"
    end
    return true, {
        onlineId = onlineId,
        username = username,
        key = tostring(onlineId) .. ":" .. username,
    }
end

local function resolvePendingPlayer(pending)
    local foundOk, current = callGlobal("getPlayerByOnlineID", pending.identity.onlineId)
    if not foundOk or current == nil or current ~= pending.player then
        return false, "requesting player disconnected or was replaced"
    end
    local identityOk, identityOrReason = playerIdentity(current)
    if not identityOk or identityOrReason.key ~= pending.identity.key then
        return false, identityOk and "requesting player identity changed" or identityOrReason
    end
    return true, current
end

local function boundsContainXY(bounds, x, y)
    if bounds == nil then
        return false
    end
    if type(bounds) ~= "table" then
        error("RailroaderRVTest: saved manifest bounds are malformed")
    end
    local minX = requiredInteger(bounds.clearMinX, "saved bounds clearMinX")
    local maxX = requiredInteger(bounds.clearMaxX, "saved bounds clearMaxX")
    local minY = requiredInteger(bounds.clearMinY, "saved bounds clearMinY")
    local maxY = requiredInteger(bounds.clearMaxY, "saved bounds clearMaxY")
    if minX > maxX or minY > maxY then
        error("RailroaderRVTest: saved manifest bounds are inverted")
    end
    return x >= minX and x <= maxX and y >= minY and y <= maxY
end

local function squareIsSafeForRelocation(square, countCharacters)
    if square == nil then
        return false
    end
    local floorOk, floor = invoke(square, "getFloor")
    local solidOk, solid = invoke(square, "TreatAsSolidFloor")
    local freeOk, free = invoke(square, "isFree", countCharacters ~= false)
    if not floorOk or floor == nil or not solidOk or solid ~= true
        or not freeOk or free ~= true then
        return false
    end
    local roomOk, room = invoke(square, "getRoom")
    local roomIdOk, roomId = invoke(square, "getRoomID")
    if not roomOk or room ~= nil or not roomIdOk or toNumber(roomId) ~= -1 then
        return false
    end
    local regionOk, region = invoke(square, "getIsoWorldRegion")
    if not regionOk then
        return false
    end
    if region ~= nil then
        local playerRoomOk, playerRoom = invoke(region, "isPlayerRoom")
        if not playerRoomOk or playerRoom == true then
            return false
        end
    end
    local vehicleOk, vehicle = invoke(square, "getVehicleContainer")
    if not vehicleOk or vehicle ~= nil then
        return false
    end
    return true
end

-- The fixed test destination is deliberately allowed to contain the objects
-- that the subsequent server cleanup removes.  Keep only the checks that make
-- teleporting into a loaded square meaningful; the client does not choose this
-- square and the server remains the authority for the final coordinate.
-- Select the first legal staging coordinate on a deterministic ring outside
-- both the new destructive footprint and any saved generation footprint.  The
-- coordinate check is intentionally world-only: the remote square may be
-- unloaded before the client relocation, and the server validates its actual
-- loaded/safe square after the relocation acknowledgement.
local function selectStagingDestination(bounds, oldBounds, anchor)
    if type(bounds) ~= "table" or type(anchor) ~= "table" then
        error("RailroaderRVTest: staging destination contract is incomplete")
    end
    local anchorX = requiredInteger(anchor.x, "staging anchor x")
    local anchorY = requiredInteger(anchor.y, "staging anchor y")
    local anchorZ = requiredInteger(anchor.z, "staging anchor z")
    local worldOk, world = callGlobal("getWorld")
    if not worldOk or world == nil then
        error("RailroaderRVTest: getWorld is unavailable for staging validation")
    end
    local function candidate(x, y)
        if boundsContainXY(bounds, x, y) or boundsContainXY(oldBounds, x, y) then
            return nil
        end
        local validOk, valid = invoke(world, "isValidSquare", x, y, anchorZ)
        if validOk and valid == true then
            return { x = x, y = y, z = anchorZ }
        end
        return nil
    end

    -- ServerMap.characterIn loads whole 64x64 cells using half the player's
    -- online chunk-grid width.  At the minimum safe width (14), the
    -- staging point immediately above the clear rectangle keeps X centered
    -- and its cell-aligned Y range still covers the full 101x101 footprint.
    -- Prefer that point (and nearby points on the same safe edge) before the
    -- generic ring: the old diagonal-first search left x=20096 outside the
    -- loaded cells even though the player was only 51 tiles away diagonally.
    local preferredTop = {
        { x = anchorX, y = bounds.clearMinY - 1 },
        { x = anchorX, y = bounds.clearMinY - 2 },
        { x = anchorX, y = bounds.clearMinY - 3 },
        { x = anchorX, y = bounds.clearMinY - 4 },
    }
    for i = 1, #preferredTop do
        local found = candidate(preferredTop[i].x, preferredTop[i].y)
        if found then return found end
    end

    -- Keep the bounded search as a fail-closed fallback when the preferred
    -- edge is occupied by a saved footprint.  targetAreaLoadStatus still
    -- requires every base square; an unsupported client grid therefore waits
    -- and hard-cancels before any destructive mutation.
    for radius = 51, SAFE_SEARCH_MAX_RADIUS do
        for dx = -radius, radius do
            local found = candidate(anchorX + dx, anchorY - radius)
            if found then return found end
            found = candidate(anchorX + dx, anchorY + radius)
            if found then return found end
        end
        for dy = -radius + 1, radius - 1 do
            local found = candidate(anchorX - radius, anchorY + dy)
            if found then return found end
            found = candidate(anchorX + radius, anchorY + dy)
            if found then return found end
        end
    end
    error("RailroaderRVTest: no legal staging destination outside saved/new footprints")
end

local function playerIsAtStagingDestination(player, destination, bounds, oldBounds)
    local playerOk, positionOrReason = validateAuthoritativePlayer(player)
    if not playerOk then
        return false, positionOrReason
    end
    if positionOrReason.x ~= destination.x or positionOrReason.y ~= destination.y
        or positionOrReason.z ~= destination.z then
        return false, "server player has not reached the relocation destination"
    end
    local squareOk, square = invoke(player, "getCurrentSquare")
    if not squareOk or square == nil then
        return false, "server player has no current square after relocation"
    end
    local xOk, squareX = invoke(square, "getX")
    local yOk, squareY = invoke(square, "getY")
    local zOk, squareZ = invoke(square, "getZ")
    if not xOk or not yOk or not zOk
        or toNumber(squareX) ~= destination.x or toNumber(squareY) ~= destination.y
        or toNumber(squareZ) ~= destination.z then
        return false, "server player current square does not match relocation destination"
    end
    if boundsContainXY(bounds, destination.x, destination.y)
        or boundsContainXY(oldBounds, destination.x, destination.y) then
        return false, "staging destination overlaps a saved or new footprint"
    end
    -- The staging square is the only square occupied while the old room is
    -- removed. Require a loaded, solid, unoccupied, non-room square before any
    -- destructive world mutation is permitted.
    if not squareIsSafeForRelocation(square, false) then
        return false, "staging destination is not a safe loaded square"
    end
    return true
end

local function relocationPositionStillSyncing(reason)
    -- teleportTo updates the client immediately, but the authoritative server
    -- player can retain its previous square for several server ticks.  These
    -- position-only failures are therefore retryable; death, identity,
    -- permission, room, and vehicle failures remain hard cancellation paths.
    return reason == "server player has not reached the relocation destination"
        or reason == "server player has no current square after relocation"
        or reason == "server player current square does not match relocation destination"
end

local function validateRequest(module, command, player, args)
    if module ~= COMMAND_MODULE then
        return false, "invalid command module"
    end
    if command ~= COMMAND then
        return false, "invalid command"
    end
    if not isEmptyCommandArgs(args) then
        return false, "command args must be nil or an empty table"
    end
    local ok, positionOrReason = validateAuthoritativePlayer(player)
    if not ok then
        return false, positionOrReason
    end
    local permissionOk, permissionReason = validateGenerationPermission(player)
    if not permissionOk then
        return false, permissionReason
    end
    return true, positionOrReason
end

-- Deliver the final in-house relocation only after buildGeneration succeeds.
-- The payload is created entirely from the server's prepared anchor; the
-- client never sends coordinates and this command has no acknowledgement path.
local function relocatePlayerIntoHouse(player, prepared)
    local destination = prepared.finalDestination
    local anchor = prepared.anchor
    if type(destination) ~= "table" or type(anchor) ~= "table" then
        error("RailroaderRVTest: final relocation contract is incomplete")
    end
    local x = requiredNumber(destination.x, "final relocation x")
    local y = requiredNumber(destination.y, "final relocation y")
    local z = requiredNumber(destination.z, "final relocation z")
    local anchorX = requiredInteger(anchor.x, "final relocation anchor x")
    local anchorY = requiredInteger(anchor.y, "final relocation anchor y")
    local anchorZ = requiredInteger(anchor.z, "final relocation anchor z")
    if x ~= anchorX + 0.5 or y ~= anchorY + 0.5 or z ~= anchorZ then
        error("RailroaderRVTest: final relocation is not the house interior center")
    end
    local finalPayload = {
            token = prepared.token,
            generation = requiredInteger(prepared.generation,
                "final relocation generation"),
            onlineId = prepared.identity.onlineId,
            x = x,
            y = y,
            z = z,
    }
    -- Railroader generation removed the official seat before staging.  Carry
    -- only a transition hint so the client adapter can run Ride.dismount(true)
    -- before this final RV teleport; seat truth still comes from Railroader's
    -- next server snapshot.
    if type(prepared.railroader) == "table" then
        finalPayload.railroaderTransition = true
        finalPayload.action = "enter"
        finalPayload.locoId = prepared.railroader.locoId
        finalPayload.role = prepared.railroader.sourceRole
        finalPayload.seat = prepared.railroader.sourceSeat
    end
    local sentOk = callGlobal("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_FINAL_RELOCATE, finalPayload)
    if not sentOk then
        error("RailroaderRVTest: final server-to-client relocation command failed")
    end
    if not callSucceeded(player, "teleportTo", x, y, z) then
        error("RailroaderRVTest: final authoritative server relocation failed")
    end
end

local function generateForPlayer(player, prepared)
    if transactionBusy then
        return false, "generation already in progress"
    end
    if type(prepared) ~= "table" or type(prepared.layout) ~= "table"
        or type(prepared.bounds) ~= "table" or type(prepared.anchor) ~= "table"
        or type(prepared.destination) ~= "table"
        or type(prepared.stagingDestination) ~= "table"
        or type(prepared.finalDestination) ~= "table" then
        return false, "prepared generation plan is incomplete"
    end
    transactionBusy = true
    transactionPlayer = player
    local manifest
    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        transactionBusy = false
        transactionPlayer = nil
        return false, safeErrorText(manifestOrError)
    end
    manifest = manifestOrError
    if manifest.state == "RUNNING" then
        transactionBusy = false
        transactionPlayer = nil
        return false, "generation already in progress or recovery is required"
    end
    -- B42 Kahlua exposes pcall; the protected body returns
    -- the raw error; finalizeGeneration formats it safely and records FAILED.
    local ok, resultOrError = pcall(function()
        local playerOk, positionOrReason = validateAuthoritativePlayer(player)
        if not playerOk then
            error(positionOrReason)
        end
        -- The ordinary technical-test button requires the debug capability.
        -- Railroader requests have already passed their own server-side train,
        -- range, seat and movement checks in RV_RailroaderServer.
        if prepared.railroader == nil then
            local permissionOk, permissionReason = validateGenerationPermission(player)
            if not permissionOk then
                error(permissionReason)
            end
        end
        if prepared.railroader ~= nil and not railroaderValidationHook then
            error("Railroader RV validation hook is unavailable")
        end
        if prepared.railroader ~= nil and railroaderValidationHook then
            local railOk, railResult, railReason = pcall(
                railroaderValidationHook, player, prepared.railroader, prepared)
            if not railOk then
                error(safeErrorText(railResult))
            end
            if railResult ~= true then
                error(railReason or "Railroader generation request is no longer valid")
            end
        end
        local identityOk, identityOrReason = playerIdentity(player)
        if not identityOk or identityOrReason.key ~= prepared.identity.key then
            error(identityOk and "requesting player identity changed" or identityOrReason)
        end
        local layout = prepared.layout
        local bounds = prepared.bounds
        local anchor = prepared.anchor
        local cell = getCellForPlayer(player)
        local oldBounds = toNumber(manifest.generation) ~= nil and manifest.bounds or nil
        if type(prepared.oldBounds) == "table" then
            oldBounds = prepared.oldBounds
        end
        local atStaging, stagingReason = playerIsAtStagingDestination(player,
            prepared.stagingDestination, bounds, oldBounds)
        if not atStaging then
            error(stagingReason)
        end
        -- No object/system mutation is allowed before this complete loaded
        -- region check.  In particular, an old generation is not removed
        -- until the new 101x101 cleanup/base/wall/roof contract is ready.
        preflightLoaded(cell, bounds)
        local generation = (toNumber(manifest.generation) or 0) + 1
        -- Arm every connected client before any old wall or roof is removed.
        -- Reliable packet order installs the guard before the following world
        -- deltas; the requester remains at the validated staging square,
        -- outside both old and new structure footprints, while later client
        -- ticks repair any missed retired room ID.
        armClientRoomOwnershipGuard(generation, oldBounds, bounds)
        local roomOwnershipGuard = registerServerRoomOwnershipGuard(generation,
            player, oldBounds, bounds)
        -- Remove only objects owned by a prior generation before taking the
        -- new generation lock in persistent state.
        removeOldGeneration(cell, manifest)
        refreshServerRoomOwnershipGuard(roomOwnershipGuard, "after-remove")
        manifest.version = 1
        manifest.generation = generation
        manifest.owner = OWNER
        manifest.anchor = { x = anchor.x, y = anchor.y, z = anchor.z }
        manifest.bounds = bounds
        manifest.startedAt = os.time()
        manifest.rollback = nil
        setManifestState(manifest, "RUNNING")
        local buildOk, buildError = pcall(clearGenerationArea, cell, bounds,
            generation, manifest)
        -- Generation is allowed to start only after the complete cleanup pass
        -- succeeds.  Keep this explicit gate: pcall reports a cleanup error in
        -- buildOk, and a failed cleanup must never enter buildGeneration.
        if buildOk then
            buildOk, buildError = pcall(buildGeneration, player, layout, bounds,
                generation, manifest)
        end
        if buildOk then
            -- Scan once more on the server immediately before the final
            -- client command.  The client repeats the same scan synchronously
            -- before its teleport; neither side relies on a later OnTick to
            -- repair the square after the player enters the room.
            local refreshOk, refreshError = pcall(
                refreshServerRoomOwnershipGuard, roomOwnershipGuard,
                "before-final-relocate")
            if not refreshOk then
                buildOk = false
                buildError = refreshError
            else
                prepared.generation = generation
                setGenerationPhase(manifest, generation, "FINAL_RELOCATE")
                local finalRelocationOk, finalRelocationError = pcall(
                    relocatePlayerIntoHouse, player, prepared)
                if not finalRelocationOk then
                    buildOk = false
                    buildError = finalRelocationError
                end
            end
        end
        if buildOk and prepared.railroader ~= nil and not railroaderCommitHook then
            buildOk = false
            buildError = "Railroader RV commit hook is unavailable"
        end
        if buildOk and prepared.railroader ~= nil and railroaderCommitHook then
            -- Persist the train/RV/player relation while the generation is
            -- still inside the same rollback gate.  A failed mapping write is
            -- therefore treated like any other failed build stage.
            local commitOk, commitResult, commitReason = pcall(
                railroaderCommitHook, player, prepared.railroader, prepared)
            if not commitOk then
                buildOk = false
                buildError = commitResult
            elseif commitResult ~= true then
                buildOk = false
                buildError = commitReason or "Railroader RV mapping commit failed"
            end
        end
        if not buildOk then
            -- The lamp is intentionally last, but any phase can fail.  Remove
            -- every object tagged by this generation before exposing FAILED;
            -- otherwise a failed lamp/API call would leave a powered
            -- generator, full barrel or roof as a half-built cabin.
            local rollbackOk, rollbackError = pcall(function()
                removeGeneration(cell, bounds, generation)
            end)
            if rollbackOk then
                manifest.rollback = "COMPLETE"
                manifest.phase = "ROLLED_BACK"
                print("[RailroaderRVTest] generation=" .. tostring(generation)
                    .. " rollback=COMPLETE")
            else
                manifest.rollback = "FAILED"
                manifest.recovery = "RECOVERY_REQUIRED"
                print("[RailroaderRVTest] generation=" .. tostring(generation)
                    .. " rollback=FAILED: " .. safeErrorText(rollbackError))
                error(safeErrorText(buildError) .. " (rollback failed: "
                    .. safeErrorText(rollbackError) .. ")")
            end
            error(buildError)
        end
        refreshServerRoomOwnershipGuard(roomOwnershipGuard, "before-commit")
        setGenerationPhase(manifest, generation, "COMMITTED")
        manifest.completedAt = os.time()
        manifest.recovery = nil
        setManifestState(manifest, "READY")
        refreshServerRoomOwnershipGuard(roomOwnershipGuard, "after-commit")
        return true
    end)
    return finalizeGeneration(manifest, ok, resultOrError)
end

local function queueGeneration(player, authoritativePosition, railroaderData)
    if pendingGeneration ~= nil or transactionBusy then
        return false, "generation already queued or in progress"
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then
        return false, identityOrReason
    end

    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        return false, safeErrorText(manifestOrError)
    end
    local manifest = manifestOrError
    if manifest.state == "RUNNING" then
        return false, "generation already in progress or recovery is required"
    end

    -- Capture the fixed destination plan before relocation.  It is never
    -- recomputed from the client, and the client contributes no coordinates.
    local planOk, layoutOrError, bounds, destination, finalDestination,
        stagingDestination, oldBounds = pcall(function()
        local targetX = requiredInteger(Constants.TELEPORT_X,
            "shared teleport target x")
        local targetY = requiredInteger(Constants.TELEPORT_Y,
            "shared teleport target y")
        local targetZ = requiredInteger(Constants.TELEPORT_Z,
            "shared teleport target z")
        local layout = makeLayout(targetX, targetY, targetZ)
        local plannedBounds = boundsFor(layout)
        local destination = { x = targetX, y = targetY, z = targetZ }
        local finalDestination = {
            x = targetX + 0.5,
            y = targetY + 0.5,
            z = targetZ,
        }
        -- This is a pure world-coordinate legality check.  It must precede
        -- both network relocation and the authoritative server teleport; it
        -- intentionally does not inspect loaded target squares.
        validateTargetCoordinates(plannedBounds, destination)
        local oldBounds = nil
        if toNumber(manifest.generation) ~= nil then
            if type(manifest.bounds) ~= "table" then
                error("RailroaderRVTest: saved generation has no usable bounds")
            end
            oldBounds = manifest.bounds
            -- Validate the saved XY range before using it for old-generation
            -- removal. The current pass has a server-fixed target; the boolean
            -- result is intentionally not used to reject an older manifest at
            -- another anchor.
            boundsContainXY(oldBounds, targetX, targetY)
        end
        local stagingDestination = selectStagingDestination(plannedBounds,
            oldBounds, { x = targetX, y = targetY, z = targetZ })
        return layout, plannedBounds, destination, finalDestination,
            stagingDestination, oldBounds
    end)
    if not planOk then
        return false, safeErrorText(layoutOrError)
    end

    pendingSerial = pendingSerial + 1
    local token = identityOrReason.key .. ":" .. tostring(serverTick)
        .. ":" .. tostring(pendingSerial)
    pendingGeneration = {
        player = player,
        identity = identityOrReason,
        token = token,
        queuedAtTick = serverTick,
        acknowledged = false,
        layout = layoutOrError,
        bounds = bounds,
        oldBounds = oldBounds,
        anchor = {
            x = destination.x,
            y = destination.y,
            z = destination.z,
        },
        destination = { x = destination.x, y = destination.y, z = destination.z },
        finalDestination = {
            x = finalDestination.x,
            y = finalDestination.y,
            z = finalDestination.z,
        },
        stagingDestination = {
            x = stagingDestination.x,
            y = stagingDestination.y,
            z = stagingDestination.z,
        },
        railroader = railroaderData,
    }

    -- GameServer.sendTeleport is not exposed to B42.20 Lua.  The targeted
    -- server command performs the client half of relocation; teleportTo is
    -- also applied to the authoritative server object.  The acknowledgement
    -- carries only an opaque token and cannot supply a trusted destination.
    local relocatePayload = {
        token = token,
        onlineId = identityOrReason.onlineId,
        x = stagingDestination.x,
        y = stagingDestination.y,
        z = stagingDestination.z,
    }
    -- Only a Railroader-backed generation carries a local Ride transition
    -- hint.  The marker is intentionally server-created and is not part of
    -- the ordinary technical Generate protocol; its coordinates remain the
    -- server-selected staging destination above.
    if type(railroaderData) == "table" then
        relocatePayload.railroaderTransition = true
        relocatePayload.action = "enter"
        relocatePayload.locoId = railroaderData.locoId
        relocatePayload.role = railroaderData.sourceRole
        relocatePayload.seat = railroaderData.sourceSeat
    end
    local sentOk = callGlobal("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_RELOCATE, relocatePayload)
    if not sentOk then
        pendingGeneration = nil
        return false, "server-to-client relocation command failed"
    end
    if not callSucceeded(player, "teleportTo", stagingDestination.x + 0.5,
        stagingDestination.y + 0.5, stagingDestination.z) then
        pendingGeneration = nil
        return false, "authoritative server relocation failed"
    end
    print("[RailroaderRVTest] generation queued after relocation player="
        .. identityOrReason.key .. " staging=" .. tostring(stagingDestination.x)
        .. "," .. tostring(stagingDestination.y) .. ","
        .. tostring(stagingDestination.z) .. " anchor=" .. tostring(destination.x)
        .. "," .. tostring(destination.y) .. "," .. tostring(destination.z))
    return true
end

-- Public only to the sibling Railroader adapter.  Keeping these tiny hooks on
-- the existing transaction avoids exposing generation internals to clients.
function RV.Server.setRailroaderValidationHook(callback)
    railroaderValidationHook = type(callback) == "function" and callback or nil
end

function RV.Server.setRailroaderCommitHook(callback)
    railroaderCommitHook = type(callback) == "function" and callback or nil
end

function RV.Server.setRailroaderFailureHook(callback)
    railroaderFailureHook = type(callback) == "function" and callback or nil
end

function RV.Server.requestRailroaderGeneration(player, railroaderData)
    if type(railroaderData) ~= "table" then
        return false, "Railroader generation data is missing"
    end
    if not railroaderValidationHook or not railroaderCommitHook
        or not railroaderFailureHook then
        return false, "Railroader RV transaction hooks are unavailable"
    end
    return queueGeneration(player, nil, railroaderData)
end

-- Re-run the official add-floor/remove-floor neighbour invalidation after an
-- existing RV entry or reconnect.  Bounds come from the persisted generation
-- manifest; only a damaged/legacy manifest falls back to the fixed shared
-- anchor, never to client coordinates.
function RV.Server.repairRoofVisuals(player)
    if not RoofRepair then
        return false, "roof repair module is unavailable"
    end
    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        return false, safeErrorText(manifestOrError)
    end
    local manifest = manifestOrError
    local bounds = manifest.bounds
    if type(bounds) ~= "table" then
        local targetX = requiredInteger(Constants.TELEPORT_X,
            "roof repair anchor x")
        local targetY = requiredInteger(Constants.TELEPORT_Y,
            "roof repair anchor y")
        local targetZ = requiredInteger(Constants.TELEPORT_Z,
            "roof repair anchor z")
        local layoutOk, layoutOrError = pcall(makeLayout, targetX, targetY,
            targetZ)
        if not layoutOk then return false, safeErrorText(layoutOrError) end
        local boundsOk, boundsOrError = pcall(boundsFor, layoutOrError)
        if not boundsOk then return false, safeErrorText(boundsOrError) end
        bounds = boundsOrError
    end
    local ok, result, reason = pcall(RoofRepair.run, player, bounds)
    if not ok then return false, safeErrorText(result) end
    return result == true, reason
end

local function ackPayloadToken(args)
    if args == nil then
        return nil
    end
    local token = args.token
    if type(token) ~= "string" or token == "" then
        return nil
    end
    if type(args) == "table" then
        local count = 0
        for key in pairs(args) do
            if key ~= "token" then
                return nil
            end
            count = count + 1
        end
        return count == 1 and token or nil
    end
    if not classInstance(args, "PZNetKahluaTableImpl") then
        return nil
    end
    local sizeOk, size = invoke(args, "size")
    if not sizeOk or toNumber(size) ~= 1 then
        return nil
    end
    return token
end

local function acknowledgeRelocation(player, args)
    local pending = pendingGeneration
    local token = ackPayloadToken(args)
    if pending == nil or token == nil or token ~= pending.token then
        return false, "unexpected or malformed relocation acknowledgement"
    end
    local resolved, playerOrReason = resolvePendingPlayer(pending)
    if not resolved or playerOrReason ~= player then
        return false, resolved and "acknowledgement sender does not own the request"
            or playerOrReason
    end
    pending.acknowledged = true
    pending.acknowledgedAtTick = serverTick
    return true
end

local function cancelPending(reason)
    local pending = pendingGeneration
    pendingGeneration = nil
    if pending and pending.railroader ~= nil and railroaderFailureHook then
        pcall(railroaderFailureHook, pending.player, pending.railroader, reason,
            pending)
    end
    print("[RailroaderRVTest] queued generation cancelled player="
        .. (pending and pending.identity.key or "unknown") .. ": "
        .. safeErrorText(reason))
end

function RV.Server.OnTick()
    serverTick = serverTick + 1
    processServerRoomOwnershipGuards()
    local pending = pendingGeneration
    if pending == nil then
        return
    end
    local elapsed = serverTick - pending.queuedAtTick
    if elapsed > RELOCATION_TIMEOUT_TICKS then
        cancelPending("relocation acknowledgement timed out before world mutation")
        return
    end
    local resolved, playerOrReason = resolvePendingPlayer(pending)
    if not resolved then
        cancelPending(playerOrReason)
        return
    end
    if pending.railroader == nil then
        local permissionOk, permissionReason = validateGenerationPermission(playerOrReason)
        if not permissionOk then
            cancelPending(permissionReason)
            return
        end
    end
    -- Keep the liveness/world-coordinate check active while waiting for the
    -- server-side player object to observe the client relocation.  A stale
    -- coordinate is retryable, but a dead/invalid player is not.
    local stateCallOk, stateOk, stateOrReason = pcall(validateAuthoritativePlayer,
        playerOrReason)
    if not stateCallOk then
        cancelPending(safeErrorText(stateOk))
        return
    end
    if not stateOk then
        cancelPending(stateOrReason)
        return
    end
    if not pending.acknowledged or elapsed < RELOCATION_MIN_TICKS
        or serverTick - pending.acknowledgedAtTick < RELOCATION_POST_ACK_TICKS then
        return
    end
    local atStaging, stagingReason = playerIsAtStagingDestination(playerOrReason,
        pending.stagingDestination, pending.bounds, pending.oldBounds)
    if not atStaging then
        if relocationPositionStillSyncing(stagingReason) then
            return
        end
        cancelPending(stagingReason)
        return
    end

    -- The relocation itself is what streams the remote target.  Wait until
    -- every base square in the exact 101x101 footprint is present; no cleanup
    -- or other world mutation is allowed while this preflight is incomplete.
    local targetLoaded, targetLoadReason = targetAreaLoadStatus(playerOrReason,
        pending.bounds)
    if targetLoaded == nil then
        cancelPending(targetLoadReason)
        return
    end
    if not targetLoaded then
        return
    end

    local completedPending = pending
    local ok, reason = generateForPlayer(playerOrReason, completedPending)
    pendingGeneration = nil
    if not ok then
        if completedPending.railroader ~= nil and railroaderFailureHook then
            pcall(railroaderFailureHook, playerOrReason,
                completedPending.railroader, reason, completedPending)
        end
        print("[RailroaderRVTest] generation failed: " .. tostring(reason))
    else
        print("[RailroaderRVTest] generation committed READY")
    end
end

function RV.Server.OnClientCommand(module, command, player, args)
    -- OnClientCommand is shared by every mod.  Foreign Railroader/vanilla
    -- commands are not RV requests and must not be reported as malformed RV
    -- traffic.
    if module ~= COMMAND_MODULE then
        return
    end
    -- The Railroader adapter owns these two commands.  This handler is also
    -- registered on the same event, so do not let the generic empty-payload
    -- validator log them as malformed Generate requests.
    if module == COMMAND_MODULE
        and (command == COMMAND_RV_ENTER or command == COMMAND_RV_EXIT) then
        return
    end
    if module == COMMAND_MODULE and command == COMMAND_RELOCATE_ACK then
        local ackOk, accepted, reason = pcall(acknowledgeRelocation, player, args)
        if not ackOk then
            reason = safeErrorText(accepted)
            accepted = false
        end
        if not accepted then
            print("[RailroaderRVTest] relocation acknowledgement rejected: "
                .. safeErrorText(reason))
        end
        return
    end
    local checkOk, accepted, reason = pcall(validateRequest, module, command, player, args)
    if not checkOk then
        reason = safeErrorText(accepted)
        accepted = false
    end
    if not accepted then
        print("[RailroaderRVTest] command rejected: " .. safeErrorText(reason))
        return
    end
    -- Request validation and ownership come from the server-side player object;
    -- generation coordinates come from the shared fixed target. Args are
    -- intentionally ignored to prevent client-side placement spoofing.
    local ok, reason = queueGeneration(player, reason)
    if not ok then
        print("[RailroaderRVTest] generation request failed: " .. tostring(reason))
    end
end

if Events and Events.OnClientCommand and type(Events.OnClientCommand.Add) == "function" then
    Events.OnClientCommand.Add(RV.Server.OnClientCommand)
end
if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(RV.Server.OnTick)
end

-- Load after RV.Server has been fully constructed.  The adapter is intentionally
-- a separate file so the generic generation transaction remains readable and
-- the Railroader dependency stays optional for the technical test button.
local railroaderAdapterOk, railroaderAdapterOrError = pcall(require,
    "RailroaderRV/RV_RailroaderServer")
if not railroaderAdapterOk then
    print("[RailroaderRVTest] Railroader RV adapter unavailable: "
        .. safeErrorText(railroaderAdapterOrError))
elseif type(railroaderAdapterOrError) == "table"
    and type(railroaderAdapterOrError.installTransactionHooks) == "function" then
    local hooksInstalled = railroaderAdapterOrError.installTransactionHooks()
    if hooksInstalled then
        print("[RailroaderRVTest] Railroader RV transaction hooks installed.")
    else
        print("[RailroaderRVTest] Railroader RV transaction hooks unavailable.")
    end
end

return RV.Server
