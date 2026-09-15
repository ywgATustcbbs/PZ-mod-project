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
local COMMAND_FINAL_RELOCATE_ACK = "FinalRelocateAck"
local COMMAND_REFRESH_ROOM_OWNERSHIP = "RefreshRoomOwnership"
local COMMAND_RV_ENTER = "EnterRV"
local COMMAND_RV_EXIT = "ExitRV"
local COMMAND_RV_TELEPORT = "RVTeleport"
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
local boundaryLoaded, Boundary = pcall(require, "RailroaderRV/RV_BoundaryServer")
if not boundaryLoaded or type(Boundary) ~= "table" then
    Boundary = nil
    print("[RailroaderRVTest] RV boundary service unavailable; boundary hooks disabled")
end
local bitmapLoaded, Bitmap = pcall(require, "RailroaderRV/RV_Bitmap")
if not bitmapLoaded or type(Bitmap) ~= "table" then
    Bitmap = nil
    print("[RailroaderRVTest] RV bitmap contract unavailable")
end
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
-- A wall-removal refresh relocates every authoritative player in the current
-- RV scope as one transaction.  The target is derived from the current
-- bitmap/layout center and offset by the current contract vector; it is not a
-- persisted coordinate or a client-provided destination.
local roofRepairRelocationGroup = nil
local roofRepairGroupFailure = nil
local roofRepairGroupFinalReturn = nil
local roofRepairGroupSerial = 0
local pendingSerial = 0
local serverTick = 0
local roomOwnershipGuards = {}
local safeErrorText
local requireCurrentManifest

-- The client acknowledgement requires a full server -> client -> server
-- round trip.  Keep an additional cross-tick guard before touching the old
-- player-built room so the client cannot still be evaluating its stale
-- IsoRoom while WorldRegionToMetaGrid rebuilds the room definitions.
local RELOCATION_MIN_TICKS = 3
local RELOCATION_POST_ACK_TICKS = 2
local RELOCATION_TIMEOUT_TICKS = 600
local ROOF_REPAIR_RETURN_RETRY_TICKS = 5
local ROOF_RELOCATION_RETRY_TICKS = 5
local GENERATION_RELOCATION_RETRY_TICKS = 5
local ROOF_REPAIR_REMOTE_OFFSET_X = Constants.ROOF_REPAIR_REMOTE_OFFSET_X
local ROOF_REPAIR_REMOTE_OFFSET_Y = Constants.ROOF_REPAIR_REMOTE_OFFSET_Y
local ROOF_REPAIR_REMOTE_OFFSET_Z = Constants.ROOF_REPAIR_REMOTE_OFFSET_Z
local ROOF_REPAIR_TEMP_Z = Constants.RELOCATION_SENTINEL_Z
local GENERATION_STAGING_Z = Constants.RELOCATION_SENTINEL_Z

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

local function callGlobalSucceeded(name, ...)
    local ok, result = callGlobal(name, ...)
    return ok and result ~= false
end

local function notifyFailure(player, reason)
    if not player then return end
    callGlobal("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_RV_TELEPORT, { ok = false, reason = tostring(reason) })
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

-- Schema and identity gates use nil for malformed values so callers can
-- reject current-only data without raising a Kahlua error.  Keep this
-- conversion local to the server transaction; requiredInteger remains the
-- throwing helper for trusted layout values.
local function isFiniteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
    local numeric = toNumber(value)
    if not isFiniteNumber(numeric) or math.floor(numeric) ~= numeric then
        return nil
    end
    return numeric
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
    -- The current empty-payload contract also accepts the B42 network table
    -- representation; every non-empty or unrelated value remains rejected.
    if type(args) == "table" then
        return tableIsEmpty(args)
    end
    if not classInstance(args, "PZNetKahluaTableImpl") then
        return false
    end
    local ok, size = invoke(args, "size")
    return ok and toNumber(size) == 0
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

local function copyPoint(value, label)
    if type(value) ~= "table" then
        error("RailroaderRVTest: " .. tostring(label) .. " is missing")
    end
    return {
        x = requiredInteger(value.x, tostring(label) .. ".x"),
        y = requiredInteger(value.y, tostring(label) .. ".y"),
        z = requiredInteger(value.z, tostring(label) .. ".z"),
    }
end

local function makeLayout(x, y, z)
    local planner = LayoutContract.make
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

    if requiredInteger(planned.schemaVersion, "shared layout schemaVersion")
        ~= Constants.LAYOUT_SCHEMA_VERSION then
        error(Constants.SAVE_REBUILD_REQUIRED)
    end
    local requiredTables = { "anchor", "clear", "managed", "bitmap", "shellEdges",
        "room", "wall", "roof", "wallCoordinates" }
    for i = 1, #requiredTables do
        local field = requiredTables[i]
        if type(planned[field]) ~= "table" then
            error("RailroaderRVTest: shared RV_Layout contract missing " .. field)
        end
    end
    if not Bitmap or not Bitmap.validate(planned.bitmap) then
        error("RailroaderRVTest: shared RV_Layout bitmap is invalid")
    end
    local managed = planned.managed
    if requiredInteger(managed.originX, "shared managed.originX") == nil
        or requiredInteger(managed.originY, "shared managed.originY") == nil
        or requiredInteger(managed.width, "shared managed.width") ~= 100
        or requiredInteger(managed.height, "shared managed.height") ~= 100
        or requiredInteger(managed.minZ, "shared managed.minZ") == nil
        or requiredInteger(managed.maxZ, "shared managed.maxZ") == nil
        or requiredInteger(managed.maxZ, "shared managed.maxZ")
            <= requiredInteger(managed.minZ, "shared managed.minZ") then
        error("RailroaderRVTest: shared managed scope is not 100x100xZ")
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
        if not Bitmap.containsScope(planned.bitmap, point.x, point.y, point.z) then
            error("RailroaderRVTest: shared layout point " .. field
                .. " is outside the bitmap scope")
        end
    end
    local anchor = planned.anchor
    requiredInteger(anchor.x, "shared layout anchor.x")
    requiredInteger(anchor.y, "shared layout anchor.y")
    requiredInteger(anchor.z, "shared layout anchor.z")
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
    local generationNumber = toNumber(generation)
    if generationNumber == nil or math.floor(generationNumber) ~= generationNumber
        or generationNumber < 1 or role == nil then
        error("RailroaderRVTest: generated object tag is incomplete")
    end
    generation = generationNumber
    local rvId = extraData and extraData.rvId
    local bitmapVersion = extraData and toNumber(extraData.bitmapVersion)
    if rvId == nil or tostring(rvId) == ""
        or bitmapVersion ~= Constants.BITMAP_VERSION then
        error("RailroaderRVTest: generated object boundary identity is incomplete")
    end
    data.owner = OWNER
    data.rvId = tostring(rvId)
    data.generation = generation
    data.bitmapVersion = bitmapVersion
    data.role = role
    if data.RailroaderRVTest ~= nil and type(data.RailroaderRVTest) ~= "table" then
        error("RailroaderRVTest: generated object tag namespace is not a table")
    end
    data.RailroaderRVTest = data.RailroaderRVTest or {}
    data.RailroaderRVTest.owner = OWNER
    data.RailroaderRVTest.rvId = tostring(rvId)
    data.RailroaderRVTest.generation = generation
    data.RailroaderRVTest.bitmapVersion = bitmapVersion
    data.RailroaderRVTest.role = role
    if type(extraData) == "table" then
        for key, value in pairs(extraData) do
            data.RailroaderRVTest[key] = value
        end
    end
    -- Re-assert all ownership identity after copying optional metadata.
    -- `extraData` is only descriptive (edge/sprite state), never authority.
    data.RailroaderRVTest.owner = OWNER
    data.RailroaderRVTest.rvId = tostring(rvId)
    data.RailroaderRVTest.generation = generation
    data.RailroaderRVTest.bitmapVersion = bitmapVersion
    data.RailroaderRVTest.role = role
    -- New objects are not on the client yet.  Do not transmit an object-index
    -- modData delta here: the creator sends one complete object packet after
    -- attachment and all object-specific state is final.  Existing objects
    -- (notably replaced floors) explicitly send their deltas in createFloor.
    local verify = objectModData(object)
    if not verify or verify.owner ~= OWNER
        or tostring(verify.rvId) ~= tostring(rvId)
        or verify.role ~= role
        or toNumber(verify.generation) ~= toNumber(generation)
        or toNumber(verify.bitmapVersion) ~= bitmapVersion then
        error("RailroaderRVTest: generated object tag verification failed for role " .. tostring(role))
    end
end

local function withTagIdentity(extraData, tagContext)
    local bitmapVersion = type(tagContext) == "table"
        and toNumber(tagContext.bitmapVersion) or nil
    if type(tagContext) ~= "table" or tagContext.rvId == nil
        or tostring(tagContext.rvId) == ""
        or bitmapVersion ~= Constants.BITMAP_VERSION then
        error("RailroaderRVTest: boundary tag identity is incomplete")
    end
    local result = {}
    if type(extraData) == "table" then
        for key, value in pairs(extraData) do result[key] = value end
    end
    -- Context identity is authoritative; per-object metadata must not be
    -- able to overwrite the RV/generation snapshot tokens.
    result.rvId = tostring(tagContext.rvId)
    result.bitmapVersion = bitmapVersion
    return result
end

local function isTaggedForGeneration(object, generation, rvId, bitmapVersion)
    if generation == nil or rvId == nil or bitmapVersion == nil then
        return false
    end
    local data = objectModData(object)
    if not data then
        return false
    end
    local function matches(tag)
        if type(tag) ~= "table" or tag.owner ~= OWNER
            or toNumber(tag.generation) ~= toNumber(generation) then
            return false
        end
        return tostring(tag.rvId) == tostring(rvId)
            and toNumber(tag.bitmapVersion) == toNumber(bitmapVersion)
    end
    if matches(data) then
        return true
    end
    local nested = data.RailroaderRVTest
    return matches(nested)
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
        data.rvId = nil
        data.generation = nil
        data.bitmapVersion = nil
        data.role = nil
    end
    local nested = data.RailroaderRVTest
    if type(nested) == "table" and nested.owner == OWNER then
        nested.owner = nil
        nested.rvId = nil
        nested.generation = nil
        nested.bitmapVersion = nil
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

local function clearSquare(square, onlyGeneration, rvId, bitmapVersion)
    local objects = squareSnapshot(square)
    -- Validate all vehicles before removing any object on this square.  This
    -- makes an unknown vehicle API a clean transaction failure, not data loss.
    for i = 1, #objects do
        if isVehicleObject(objects[i]) and (not onlyGeneration
            or isTaggedForGeneration(objects[i], onlyGeneration, rvId,
                bitmapVersion)) then
            validateVehiclePath(objects[i])
        end
    end
    for i = 1, #objects do
        local object = objects[i]
        if not onlyGeneration or isTaggedForGeneration(object, onlyGeneration,
            rvId, bitmapVersion) then
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
    local managed = layout.managed
    local bitmap = layout.bitmap
    local shellEdges = layout.shellEdges
    local room = layout.room
    local wall = layout.wall
    local roof = layout.roof
    local anchor = layout.anchor
    if type(clear) ~= "table" or type(managed) ~= "table"
        or type(bitmap) ~= "table" or type(shellEdges) ~= "table"
        or type(room) ~= "table" or type(wall) ~= "table"
        or type(roof) ~= "table" or type(anchor) ~= "table" then
        error("RailroaderRVTest: layout bounds contract is incomplete")
    end
    local function field(source, label, name)
        local value = source[name]
        if value == nil then
            error("RailroaderRVTest: layout contract missing " .. label)
        end
        return requiredInteger(value, label)
    end
    local ax = requiredInteger(anchor.x, "layout anchor.x")
    local ay = requiredInteger(anchor.y, "layout anchor.y")
    local az = requiredInteger(anchor.z, "layout anchor.z")
    local clearMinZ = field(clear, "layout clear.minZ", "minZ")
    local clearMaxZ = field(clear, "layout clear.maxZ", "maxZ")
    local clearMinX = field(clear, "layout clear.minX", "minX")
    local clearMaxX = field(clear, "layout clear.maxX", "maxX")
    local clearMinY = field(clear, "layout clear.minY", "minY")
    local clearMaxY = field(clear, "layout clear.maxY", "maxY")
    local roomMinX = field(room, "layout room.minX", "minX")
    local roomMaxX = field(room, "layout room.maxX", "maxX")
    local roomMinY = field(room, "layout room.minY", "minY")
    local roomMaxY = field(room, "layout room.maxY", "maxY")
    local roomZ = field(room, "layout room.z", "z")
    local wallMinX = field(wall, "layout wall.minX", "minX")
    local wallMaxX = field(wall, "layout wall.maxX", "maxX")
    local wallMinY = field(wall, "layout wall.minY", "minY")
    local wallMaxY = field(wall, "layout wall.maxY", "maxY")
    local wallZ = field(wall, "layout wall.z", "z")
    local roofMinX = field(roof, "layout roof.minX", "minX")
    local roofMaxX = field(roof, "layout roof.maxX", "maxX")
    local roofMinY = field(roof, "layout roof.minY", "minY")
    local roofMaxY = field(roof, "layout roof.maxY", "maxY")
    local roofZ = requiredInteger(roof.z, "layout roof.z")
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
    local managedMinZ = field(managed, "layout managed.minZ", "minZ")
    local managedMaxZ = field(managed, "layout managed.maxZ", "maxZ")
    local managedOriginX = field(managed, "layout managed.originX", "originX")
    local managedOriginY = field(managed, "layout managed.originY", "originY")
    local managedWidth = field(managed, "layout managed.width", "width")
    local managedHeight = field(managed, "layout managed.height", "height")
    if managedWidth ~= 100 or managedHeight ~= 100
        or managedMaxZ <= managedMinZ
        or managedOriginX ~= requiredInteger(bitmap.originX,
            "layout bitmap.originX")
        or managedOriginY ~= requiredInteger(bitmap.originY,
            "layout bitmap.originY")
        or managedWidth ~= requiredInteger(bitmap.width,
            "layout bitmap.width")
        or managedHeight ~= requiredInteger(bitmap.height,
            "layout bitmap.height")
        or managedMinZ ~= requiredInteger(bitmap.minZ,
            "layout bitmap.minZ")
        or managedMaxZ ~= requiredInteger(bitmap.maxZ,
            "layout bitmap.maxZ")
        or clear.minX ~= managedOriginX or clear.minY ~= managedOriginY
        or clear.maxX ~= managedOriginX + managedWidth
        or clear.maxY ~= managedOriginY + managedHeight
        or clearMinZ ~= managedMinZ or clearMaxZ ~= managedMaxZ
        or clear.halfOpen ~= true then
        error("RailroaderRVTest: managed scope must be half-open 100x100xZ")
    end
    if not Bitmap or not Bitmap.validate(bitmap) then
        error("RailroaderRVTest: layout bitmap failed validation")
    end
    local scopeMinX, scopeMinY = managedOriginX, managedOriginY
    local scopeMaxX = managedOriginX + managedWidth
    local scopeMaxY = managedOriginY + managedHeight
    local function rectInside(minX, maxX, minY, maxY, z, label)
        if minX > maxX or minY > maxY
            or minX < scopeMinX or maxX >= scopeMaxX
            or minY < scopeMinY or maxY >= scopeMaxY
            or z < managedMinZ or z >= managedMaxZ then
            error("RailroaderRVTest: " .. tostring(label)
                .. " is outside the bitmap scope")
        end
    end
    if roomZ ~= az or wallZ ~= az or roofZ < managedMinZ
        or roofZ >= managedMaxZ then
        error("RailroaderRVTest: layout structure z is outside the bitmap scope")
    end
    rectInside(roomMinX, roomMaxX, roomMinY, roomMaxY, roomZ, "room")
    rectInside(wallMinX, wallMaxX, wallMinY, wallMaxY, wallZ, "wall")
    rectInside(roofMinX, roofMaxX, roofMinY, roofMaxY, roofZ, "roof")
    for i = 1, #layout.wallCoordinates do
        local entry = layout.wallCoordinates[i]
        if type(entry) ~= "table"
            or not Bitmap.containsScope(bitmap, entry.x, entry.y, entry.z) then
            error("RailroaderRVTest: wall object host is outside bitmap scope")
        end
    end
    return {
        schemaVersion = Constants.LAYOUT_SCHEMA_VERSION,
        clearMinX = clearMinX, clearMaxX = clearMaxX,
        clearMinY = clearMinY, clearMaxY = clearMaxY,
        clearMinZ = clearMinZ, clearMaxZ = clearMaxZ,
        managedOriginX = managedOriginX, managedOriginY = managedOriginY,
        managedWidth = managedWidth, managedHeight = managedHeight,
        managedMinZ = managedMinZ, managedMaxZ = managedMaxZ,
        bitmap = bitmap, shellEdges = shellEdges,
        roomMinX = roomMinX, roomMaxX = roomMaxX,
        roomMinY = roomMinY, roomMaxY = roomMaxY, roomZ = roomZ,
        wallMinX = wallMinX, wallMaxX = wallMaxX,
        wallMinY = wallMinY, wallMaxY = wallMaxY, wallZ = wallZ,
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
    for z = bounds.clearMinZ, bounds.clearMaxZ - 1 do
        for x = bounds.clearMinX, bounds.clearMaxX - 1 do
            for y = bounds.clearMinY, bounds.clearMaxY - 1 do
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
            and Constants.SPRITES.wall.northSprite
            or Constants.SPRITES.wall.sprite
        if entry.corner then
            if coordinateKey == nwKey then
                expectedRole = "corner-nw"
                expectedSprite = Constants.SPRITES.wallNW.sprite
            elseif coordinateKey == seKey then
                expectedRole = "corner-se"
                expectedSprite = Constants.SPRITES.wallSE.sprite
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

-- Shell ownership is a separate persisted ledger, not a deduction from the
-- wall object's inactive host cell.  Validate the generated identity here so
-- a malformed plan cannot enter the destructive generation transaction.
local function validateShellEdgeContract(bounds)
    if type(bounds.shellEdges) ~= "table" then
        error("RailroaderRVTest: shell edge ledger is missing")
    end
    local seen = {}
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        local key = entry.edgeKey
        if type(key) ~= "string" or seen[key] then
            error("RailroaderRVTest: shell edge key is missing or duplicated")
        end
        local axis, edgeX, edgeY, edgeZ = string.match(
            key, "^([NW]):(-?%d+):(-?%d+):(-?%d+)$")
        edgeX, edgeY, edgeZ = tonumber(edgeX), tonumber(edgeY), tonumber(edgeZ)
        if not axis or edgeX == nil or edgeY == nil or edgeZ == nil
            or entry.axis ~= axis then
            error("RailroaderRVTest: shell edge is not canonical N/W")
        end
        local ledger = bounds.shellEdges[key]
        if type(ledger) ~= "table"
            or ledger.edgeKey ~= key
            or requiredInteger(ledger.hostX, "shell edge hostX") ~= edgeX
            or requiredInteger(ledger.hostY, "shell edge hostY") ~= edgeY
            or requiredInteger(ledger.z, "shell edge z") ~= edgeZ
            or requiredInteger(ledger.objectX, "shell edge objectX") ~= entry.x
            or requiredInteger(ledger.objectY, "shell edge objectY") ~= entry.y
            or requiredInteger(ledger.objectZ, "shell edge objectZ") ~= entry.z
            or ledger.replacementAllowed ~= true then
            error("RailroaderRVTest: shell edge ledger identity is inconsistent")
        end
        seen[key] = true
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
        or bounds.clearMinZ < WORLD_MIN_Z or bounds.clearMaxZ - 1 > WORLD_MAX_Z
        or bounds.clearMinZ >= bounds.clearMaxZ
        or bounds.z < WORLD_MIN_Z or bounds.z > WORLD_MAX_Z
        or bounds.roofZ < WORLD_MIN_Z or bounds.roofZ > WORLD_MAX_Z then
        error("RailroaderRVTest: layout z bounds are outside the legal world")
    end
    -- The managed footprint is strictly half-open x=[20000,20100),
    -- y=[2000,2100) for the fixed (20050,2050) destination.
    if bounds.clearMinX ~= targetX - 50 or bounds.clearMaxX ~= targetX - 50 + 100
        or bounds.clearMinY ~= targetY - 50 or bounds.clearMaxY ~= targetY - 50 + 100
        or bounds.z ~= targetZ or bounds.clearMinZ ~= bounds.managedMinZ
        or bounds.clearMaxZ ~= bounds.managedMaxZ then
        error("RailroaderRVTest: clear footprint does not match the fixed target")
    end
    if bounds.clearMaxX - bounds.clearMinX ~= 100
        or bounds.clearMaxY - bounds.clearMinY ~= 100 then
        error("RailroaderRVTest: managed footprint must be exactly half-open 100x100")
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
    validateShellEdgeContract(bounds)

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
    -- Validate the entire required 100x100 base footprint without requiring any
    -- of those remote squares to be loaded yet.
    for y = bounds.clearMinY, bounds.clearMaxY - 1 do
        for x = bounds.clearMinX, bounds.clearMaxX - 1 do
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

    -- All 10000 base squares in the half-open 100x100 scope must already
    -- exist before any clear/remove pass.
    for y = bounds.clearMinY, bounds.clearMaxY - 1 do
        for x = bounds.clearMinX, bounds.clearMaxX - 1 do
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
    requireCurrentManifest(manifest, true)
    if manifest.generation == nil then return end
    local generation = requiredInteger(manifest.generation, "manifest generation")
    local oldBounds = manifest.bounds
    local rvId, bitmapVersion = manifest.rvId, manifest.bitmapVersion
    walkBounds(cell, oldBounds, function(square)
        clearSquare(square, generation, rvId, bitmapVersion)
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

local function roomOwnershipGuardKey(rvId, generation, bitmapVersion)
    return tostring(rvId) .. ":" .. tostring(generation) .. ":"
        .. tostring(bitmapVersion)
end

local function registerServerRoomOwnershipGuard(generation, player, oldBounds,
    newBounds, rvId, bitmapVersion)
    if rvId == nil or tostring(rvId) == "" then
        error("RailroaderRVTest: room ownership RV identity is incomplete")
    end
    local generationNumber = requiredInteger(generation,
        "room ownership generation")
    if generationNumber < 1 then
        error("RailroaderRVTest: room ownership generation is invalid")
    end
    local version = requiredInteger(bitmapVersion,
        "room ownership bitmapVersion")
    if version < 1 then
        error("RailroaderRVTest: room ownership bitmapVersion is invalid")
    end
    local guard = {
        generation = generationNumber,
        rvId = tostring(rvId),
        bitmapVersion = version,
        player = player,
        oldBounds = oldBounds,
        newBounds = newBounds,
        ticks = 0,
        stableTicks = 0,
        totalCleared = 0,
    }
    guard.key = roomOwnershipGuardKey(guard.rvId, guard.generation, version)
    roomOwnershipGuards[guard.key] = guard
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

local function armClientRoomOwnershipGuard(generation, oldBounds, newBounds,
    rvId, bitmapVersion)
    local payload = {
        generation = generation,
        rvId = tostring(rvId),
        bitmapVersion = requiredInteger(bitmapVersion,
            "client room ownership bitmapVersion"),
        hasOld = type(oldBounds) == "table",
    }
    if payload.hasOld then
        copyRoomRefreshBounds(payload, "old", oldBounds)
    end
    copyRoomRefreshBounds(payload, "new", newBounds)
    -- The no-player overload broadcasts to every connected client. A player
    -- other than the requester may later walk through the retired footprint.
    if not callGlobalSucceeded("sendServerCommand", COMMAND_MODULE,
        COMMAND_REFRESH_ROOM_OWNERSHIP, payload) then
        error("RailroaderRVTest: client room ownership guards could not be armed")
    end
end

local function removeGeneration(cell, bounds, generation, rvId, bitmapVersion)
    if not cell or type(bounds) ~= "table" or not generation then
        return
    end
    -- Failed builds are rolled back by the same owner+generation tag used by
    -- repeat generation.  This includes roof floors, generators, barrels and
    -- the final light, even when the failure occurs in the last phase.
    walkBounds(cell, bounds, function(square)
        clearSquare(square, generation, rvId, bitmapVersion)
    end)

    -- A successful pcall around clearSquare is not enough on a dedicated
    -- server: transmitRemoveItemFromSquare owns the packet, event, local
    -- detach, and neighbour recalculation.  Verify the authoritative cell has
    -- no tagged object left before reporting rollback=COMPLETE.
    local remaining = 0
    walkBounds(cell, bounds, function(square)
        local objects = squareSnapshot(square)
        for i = 1, #objects do
            if isTaggedForGeneration(objects[i], generation, rvId,
                bitmapVersion) then
                remaining = remaining + 1
            end
        end
    end)
    if remaining > 0 then
        error("RailroaderRVTest: rollback verification found " .. tostring(remaining)
            .. " tagged objects still present")
    end
end

-- Existing-RV entry/reconnects do not run the generation broadcast below.  Arm
-- only the corresponding client with the current manifest footprint so a fresh
-- client cannot enter a room whose IsoRoom reference may be retired later.
-- This helper intentionally accepts no client coordinates or client geometry;
-- its caller supplies the server-validated current manifest bounds.
local function armTargetedClientRoomOwnershipGuard(player, generation, newBounds,
    rvId, bitmapVersion)
    if player == nil then
        error("RailroaderRVTest: targeted room ownership player is unavailable")
    end
    local generationNumber = requiredInteger(generation,
        "targeted room ownership generation")
    if generationNumber < 1 then
        error("RailroaderRVTest: targeted room ownership generation is invalid")
    end
    if rvId == nil or tostring(rvId) == "" then
        error("RailroaderRVTest: targeted room ownership RV identity is incomplete")
    end
    local version = requiredInteger(bitmapVersion,
        "targeted room ownership bitmapVersion")
    if version ~= Constants.BITMAP_VERSION then
        error("RailroaderRVTest: targeted room ownership bitmapVersion is invalid")
    end
    local payload = {
        generation = generationNumber,
        rvId = tostring(rvId),
        bitmapVersion = version,
        hasOld = false,
    }
    copyRoomRefreshBounds(payload, "new", newBounds)
    if not callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_REFRESH_ROOM_OWNERSHIP, payload) then
        error("RailroaderRVTest: targeted room ownership guard could not be armed")
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
        -- Alternate runtime API path for bindings that do not expose the class.
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

local function createFloor(square, sprite, generation, role, tagContext)
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
    local tagged, tagError = pcall(tagObject, floor, generation, role,
        withTagIdentity({
        previousSprite = previousSprite,
        createdByGeneration = createdByGeneration,
        }, tagContext))
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

local function createWall(cell, square, sprite, north, generation, role, extraData,
    tagContext)
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
    tagObject(wall, generation, role, withTagIdentity(extraData, tagContext))
    addSpecialObject(square, wall)
    if not callSucceeded(wall, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: wall client transmission failed")
    end
    return wall
end

local function validatePlayerLightSprite(spriteObject, spriteName)
    local expectedSprite = Constants.SPRITES.wallLamp.sprite
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
    local lightProperties = Constants.LIGHT_PROPERTIES
    if type(lightProperties) ~= "table" then
        error("RailroaderRVTest: light property contract is unavailable")
    end

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

local function createLight(cell, square, sprite, generation, tagContext)
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
    tagObject(light, generation, "light", withTagIdentity(nil, tagContext))
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

local function createGenerator(cell, square, sprite, generation, tagContext)
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
        itemData.fuel = Constants.GENERATOR_INITIAL_FUEL
    end
    local ok, generator = invokeClass(cls, {
        { item, cell, square },
    })
    if not ok then
        error("RailroaderRVTest: IsoGenerator construction failed")
    end
    tagObject(generator, generation, "generator", withTagIdentity(nil, tagContext))
    if not callSucceeded(generator, "setCondition", 100)
        or not callSucceeded(generator, "setFuel", Constants.GENERATOR_INITIAL_FUEL)
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

local function createRainBarrel(cell, square, sprite, generation, tagContext)
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
    tagObject(barrel, generation, "rain_barrel", withTagIdentity(nil, tagContext))
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

local function createFurniture(cell, square, sprite, generation, role, tagContext)
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
    tagObject(object, generation, role, withTagIdentity(nil, tagContext))
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
    local sprites = Constants.SPRITES
    local woodSprite = sprites and sprites.woodFloor and sprites.woodFloor.sprite
    local northWallSprite = sprites and sprites.wall and sprites.wall.northSprite
    local westWallSprite = sprites and sprites.wall and sprites.wall.sprite
    local nwWallSprite = sprites and sprites.wallNW and sprites.wallNW.sprite
    local seWallSprite = sprites and sprites.wallSE and sprites.wallSE.sprite
    local roofFloorSprite = sprites and sprites.roofFloor and sprites.roofFloor.sprite
    local lightSprite = sprites and sprites.wallLamp and sprites.wallLamp.sprite
    local generatorSprite = sprites and sprites.generator and sprites.generator.sprite
    local barrelSprite = sprites and sprites.rainCollector and sprites.rainCollector.sprite
    local counterSprite = sprites and sprites.counter and sprites.counter.sprite
    local sinkSprite = sprites and sprites.sink and sprites.sink.sprite
    if not woodSprite or not northWallSprite or not westWallSprite
        or not nwWallSprite or not seWallSprite
        or not roofFloorSprite or not lightSprite or not barrelSprite
        or not generatorSprite or not counterSprite or not sinkSprite then
        error("RailroaderRVTest: shared sprite contract is incomplete")
    end

    -- Every feature point is part of the current shared layout contract.
    local anchor = layout.anchor
    local anchorX = requiredInteger(anchor.x, "layout anchor.x")
    local anchorY = requiredInteger(anchor.y, "layout anchor.y")
    local anchorZ = requiredInteger(anchor.z, "layout anchor.z")
    local tagContext = {
        rvId = manifest and manifest.rvId,
        bitmapVersion = manifest and manifest.bitmapVersion,
    }
    if tagContext.rvId == nil or tostring(tagContext.rvId) == ""
        or toNumber(tagContext.bitmapVersion) == nil then
        error("RailroaderRVTest: generation boundary identity is incomplete")
    end
    local lightPoint = copyPoint(layout.light, "layout.light")

    setGenerationPhase(manifest, generation, "WOOD_FLOOR")
    -- Interior floor: exactly 6x40, using the shared carpet sprite.
    for x = bounds.roomMinX, bounds.roomMaxX do
        for y = bounds.roomMinY, bounds.roomMaxY do
            local square = getSquare(cell, x, y, bounds.z)
            if not square then
                error("RailroaderRVTest: interior square is not loaded")
            end
            createFloor(square, woodSprite, generation, "wood_floor", tagContext)
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
        createWall(cell, square, sprite, north, generation, role, {
            edgeKey = entry.edgeKey,
            axis = entry.axis or (north and "N" or "W"),
        }, tagContext)
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
            createFloor(square, roofFloorSprite, generation, "roof-floor", tagContext)
        end
    end

    setGenerationPhase(manifest, generation, "STRUCTURE_RECALC")
    recalcAndCheckStructure(cell, bounds)

    setGenerationPhase(manifest, generation, "GENERATOR")
    local generatorPoint = copyPoint(layout.generator, "layout.generator")
    local generatorSquare = getSquare(cell, generatorPoint.x, generatorPoint.y, bounds.roofZ)
    if not generatorSquare then
        error("RailroaderRVTest: generator square is not loaded")
    end
    createGenerator(cell, generatorSquare, generatorSprite, generation, tagContext)

    setGenerationPhase(manifest, generation, "RAIN_BARREL")
    local barrelPoint = copyPoint(layout.barrel, "layout.barrel")
    local barrelSquare = getSquare(cell, barrelPoint.x, barrelPoint.y, bounds.roofZ)
    if not barrelSquare then
        error("RailroaderRVTest: rain barrel square is not loaded")
    end
    createRainBarrel(cell, barrelSquare, barrelSprite, generation, tagContext)

    setGenerationPhase(manifest, generation, "COUNTER_SINK")
    -- The counter and sink are directly below the barrel's roof square.  The
    -- sink may share the counter square because it is placed on the counter.
    local counterPoint = copyPoint(layout.counter, "layout.counter")
    local sinkPoint = copyPoint(layout.sink, "layout.sink")
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
    local counter = createFurniture(cell, counterSquare, counterSprite, generation,
        "counter", tagContext)
    if not callSucceeded(counter, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: counter client transmission failed")
    end
    local sink = createFurniture(cell, sinkSquare, sinkSprite, generation, "sink",
        tagContext)
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
    createLight(cell, lightSquare, lightSprite, generation, tagContext)
end

local function markGenerationFailed(manifest, errorText)
    if not manifest then
        return true, nil
    end
    local empty = true
    for _ in pairs(manifest) do
        empty = false
        break
    end
    if empty then
        return true, nil
    end
    local ok, failure = pcall(function()
        manifest.phase = "FAILED"
        setManifestState(manifest, "FAILED", errorText)
    end)
    if ok then
        return true, nil
    end
    -- Keep a best-effort current-schema failure marker in memory/ModData.  No
    -- relocation transaction state is written; a process restart intentionally
    -- forgets all in-flight relocation state.
    local fallbackOk, fallbackFailure = pcall(function()
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
            if Boundary and type(Boundary.clearPlayer) == "function" then
                if pendingGeneration then pendingGeneration.boundaryCleared = true end
                pcall(Boundary.clearPlayer, transactionPlayer)
            end
            return false, message
        end
        return true, resultOrError
    end)
    -- This remains the single lock-release point for the synchronous build
    -- body.  An asynchronous final relocation keeps its own pending record.
    transactionBusy = false
    transactionPlayer = nil
    if not finalized then
        return false, safeErrorText(finalResult)
    end
    return finalResult, finalReason
end

-- Relocation state is process-local. The server keeps exact authoritative
-- coordinates and stable identities only while this process is alive; no
-- intermediate relocation record is read from or written to ModData.
local relocationServices = (function()
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

-- teleportTo.  The ordinary validator intentionally returns floor squares for
-- the raw authoritative coordinates instead of inventing a square center.
local function authoritativePlayerPosition(player)
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
    local validOk, valid = invoke(world, "isValidSquare", math.floor(px),
        math.floor(py), math.floor(pz))
    if not validOk or valid ~= true then
        return false, "authoritative player coordinate is outside the legal world"
    end
    return true, { x = px, y = py, z = pz }
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
    if type(pending) ~= "table" or type(pending.identity) ~= "table"
        or not isFiniteNumber(pending.identity.onlineId) then
        return false, "relocation player identity is unavailable"
    end
    local foundOk, current = callGlobal("getPlayerByOnlineID", pending.identity.onlineId)
    if not foundOk or current == nil then
        return false, "requesting player disconnected or was replaced"
    end
    local identityOk, identityOrReason = playerIdentity(current)
    if not identityOk or identityOrReason.key ~= pending.identity.key then
        return false, identityOk and "requesting player identity changed" or identityOrReason
    end
    -- The online ID is the stable server identity across a transient
    -- IsoPlayer object replacement.  Keep the live object on the transaction
    -- so every later tick/phase uses the authoritative instance.  A changed
    -- userdata is also a protocol event: the client-side pending command is
    -- gone after a reconnect, so the owner must re-arm/re-send the same phase
    -- token before it can continue.
    local previous = pending.player
    pending.player = current
    if previous ~= nil and previous ~= current then
        pending.playerReboundAtTick = serverTick
        pending.relocationNeedsResend = true
    end
    return true, current
end

local function relocationPositionsEqual(left, right)
    return type(left) == "table" and type(right) == "table"
        and left.x == right.x and left.y == right.y and left.z == right.z
end

return {
    readPlayerCoordinate = readPlayerCoordinate,
    validateAuthoritativePlayer = validateAuthoritativePlayer,
    authoritativePlayerPosition = authoritativePlayerPosition,
    validateGenerationPermission = validateGenerationPermission,
    playerIdentity = playerIdentity,
    resolvePendingPlayer = resolvePendingPlayer,
    relocationPositionsEqual = relocationPositionsEqual,
}
end)()

-- These validators are shared by the rest of the server transaction code.
local readPlayerCoordinate = relocationServices.readPlayerCoordinate
local validateAuthoritativePlayer = relocationServices.validateAuthoritativePlayer
local authoritativePlayerPosition = relocationServices.authoritativePlayerPosition
local validateGenerationPermission = relocationServices.validateGenerationPermission
local playerIdentity = relocationServices.playerIdentity
local resolvePendingPlayer = relocationServices.resolvePendingPlayer
local relocationPositionsEqual = relocationServices.relocationPositionsEqual

local function generationDisconnected(reason)
    return reason == "requesting player disconnected or was replaced"
end

local function pauseGenerationForDisconnect(pending)
    if type(pending) ~= "table" then return end
    if pending.disconnectStartedTick == nil then
        pending.disconnectStartedTick = serverTick
    end
end

local function resumeGenerationAfterDisconnect(pending)
    if type(pending) ~= "table"
        or pending.disconnectStartedTick == nil then
        return
    end
    local paused = serverTick - pending.disconnectStartedTick
    if paused > 0 then
        -- Do not let a missing IsoPlayer consume the normal transaction
        -- timeout.  The in-memory owner remains live until this identity
        -- reconnects; no value here is persisted.
        pending.queuedAtTick = (pending.queuedAtTick or serverTick) + paused
        if pending.finalRelocationDeadlineTick ~= nil then
            pending.finalRelocationDeadlineTick =
                pending.finalRelocationDeadlineTick + paused
        end
    end
    pending.disconnectStartedTick = nil
    pending.relocationNeedsResend = true
    pending.relocationRetryAtTick = serverTick
end

local function rearmGenerationTransition(pending, player, kind)
    if type(pending) ~= "table" or pending.boundaryCleared == true
        or not Boundary then
        return false
    end
    local token = pending.token
    if type(token) ~= "string" or token == "" then return false end
    if type(Boundary.extendTransition) == "function" then
        local extendOk, extended = pcall(Boundary.extendTransition, player,
            token, serverTick + RELOCATION_POST_ACK_TICKS + 2)
        if extendOk and extended == true then return true end
    end
    if type(Boundary.beginTransition) ~= "function" then return false end
    local beginOk, armed = pcall(Boundary.beginTransition, player,
        pending.rvId, pending.generation, token, kind or "generation",
        pending.bitmapVersion)
    if not beginOk or armed ~= true then return false end
    if type(Boundary.extendTransition) == "function" then
        pcall(Boundary.extendTransition, player, token,
            serverTick + RELOCATION_POST_ACK_TICKS + 2)
    end
    return true
end

-- Reissue only the currently owned phase after a stable identity rebind.  A
-- reconnect invalidates the client's pending command, but never changes the
-- server token or its exact destination.  The retry tick is deliberately
-- bounded so a transient send failure cannot flood the network every tick.
local function resendGenerationPhase(pending, player, phase)
    if type(pending) ~= "table" or not player then return false end
    local identity = pending.identity
    if type(identity) ~= "table" then return false end
    local payload
    if phase == "final" then
        local target = pending.finalDestination
        if type(target) ~= "table" then return false end
        payload = {
            token = pending.token,
            onlineId = identity.onlineId,
            rvId = tostring(pending.rvId),
            generation = pending.generation,
            bitmapVersion = pending.bitmapVersion,
            x = target.x, y = target.y, z = target.z,
        }
        if type(pending.railroader) == "table" then
            payload.railroaderTransition = true
            payload.action = "enter"
            payload.locoId = pending.railroader.locoId
            payload.role = pending.railroader.sourceRole
            payload.seat = pending.railroader.sourceSeat
        end
        if not callGlobalSucceeded("sendServerCommand", player,
            COMMAND_MODULE, COMMAND_FINAL_RELOCATE, payload)
            or not callSucceeded(player, "teleportTo", target.x, target.y,
                target.z) then
            return false
        end
        if pending.finalRelocationDeadlineTick == nil then
            pending.finalRelocationDeadlineTick = serverTick
                + RELOCATION_TIMEOUT_TICKS
        end
        pending.relocationLastSentTick = serverTick
        pending.relocationRetryAtTick = serverTick
        pending.relocationNeedsResend = false
        return true
    end

    local target
    if phase == "rollback" then
        target = pending.originalPosition
    else
        target = pending.stagingDestination
    end
    if type(target) ~= "table" then return false end
    payload = {
        token = pending.token,
        onlineId = identity.onlineId,
        rvId = tostring(pending.rvId),
        generation = pending.generation,
        bitmapVersion = pending.bitmapVersion,
        x = target.x, y = target.y, z = target.z,
        generationTransition = true,
        generationPhase = phase == "rollback" and "return" or "temporary",
    }
    if phase == "rollback" then payload.action = "cancel" end
    if type(pending.railroader) == "table" and phase ~= "rollback" then
        payload.railroaderTransition = true
        payload.action = "enter"
        payload.locoId = pending.railroader.locoId
        payload.role = pending.railroader.sourceRole
        payload.seat = pending.railroader.sourceSeat
    end
    local teleportX = phase == "rollback" and target.x or target.x + 0.5
    local teleportY = phase == "rollback" and target.y or target.y + 0.5
    if not callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_RELOCATE, payload)
        or not callSucceeded(player, "teleportTo", teleportX, teleportY,
            target.z) then
        return false
    end
    pending.relocationLastSentTick = serverTick
    pending.relocationRetryAtTick = serverTick
    pending.relocationNeedsResend = false
    if phase == "rollback" then
        pending.rollbackLastSentTick = serverTick
    else
        pending.acknowledged = false
        pending.acknowledgedAtTick = nil
    end
    return true
end

local function keepGenerationTransitionAlive()
    local pending = pendingGeneration
    if type(pending) ~= "table" then return true end
    local resolved, playerOrReason = resolvePendingPlayer(pending)
    if not resolved then
        if generationDisconnected(playerOrReason) then
            pauseGenerationForDisconnect(pending)
        end
        -- OnTick owns identity/death failure decisions.  A missing player is
        -- intentionally non-fatal while this process waits for rebind.
        return true
    end
    resumeGenerationAfterDisconnect(pending)
    local player = playerOrReason
    transactionPlayer = player
    local phase = pending.cancelled and "rollback"
        or pending.finalRelocationSent and "final" or "temporary"
    local rearmed = rearmGenerationTransition(pending, player,
        phase == "final" and "generation-final" or "generation")
    if not rearmed then
        -- Keep trying the same token; do not clear the pending transaction or
        -- invent a new one merely because a lease API briefly failed.
        pending.relocationNeedsResend = true
    end
    if pending.relocationNeedsResend and not pending.cancelled
        and serverTick >= (pending.relocationRetryAtTick or 0) then
        resendGenerationPhase(pending, player, phase)
        pending.relocationRetryAtTick = serverTick
            + GENERATION_RELOCATION_RETRY_TICKS
    end
    return true
end

-- A reconnect can replace the IsoPlayer userdata while the stable identity
-- remains the same.  Keep the temporary occupancy allow-list in sync with the
-- rebound object so a valid member is not mistaken for a foreign occupant.
local function resolveRoofRepairGroupPlayer(group, member)
    local previous = type(member) == "table" and member.player or nil
    local resolved, current = resolvePendingPlayer(member)
    if resolved and type(group) == "table"
        and type(group.allowedPlayers) == "table" then
        if previous ~= nil and previous ~= current then
            group.allowedPlayers[previous] = nil
        end
        group.allowedPlayers[current] = true
    end
    return resolved, current
end

local function currentBoundsValid(bounds, managed, bitmap)
    local function onlyKeys(value, expected)
        if type(value) ~= "table" then return false end
        local allowed = {}
        for i = 1, #expected do allowed[expected[i]] = true end
        for key in pairs(value) do
            if not allowed[key] then return false end
        end
        return true
    end
    local boundKeys = {
        "schemaVersion", "clearMinX", "clearMaxX", "clearMinY",
        "clearMaxY", "clearMinZ", "clearMaxZ", "managedOriginX",
        "managedOriginY", "managedWidth", "managedHeight", "managedMinZ",
        "managedMaxZ", "roomMinX", "roomMaxX", "roomMinY", "roomMaxY",
        "roomZ", "wallMinX", "wallMaxX", "wallMinY", "wallMaxY", "wallZ",
        "wallCoordinates", "wallObjectCount", "wallCoordinateCount",
        "wallEdgeCounts", "wallCornerCount", "northEdges", "westEdges",
        "roofMinX", "roofMaxX", "roofMinY", "roofMaxY", "z", "roofZ",
        "bitmap", "shellEdges",
    }
    if type(bounds) ~= "table" or type(managed) ~= "table"
        or type(bitmap) ~= "table"
        or not onlyKeys(bounds, boundKeys)
        or requiredInteger(bounds.schemaVersion, "manifest bounds schemaVersion")
            ~= Constants.LAYOUT_SCHEMA_VERSION then
        return false
    end
    local fields = {
        "clearMinX", "clearMaxX", "clearMinY", "clearMaxY",
        "clearMinZ", "clearMaxZ", "managedOriginX", "managedOriginY",
        "managedWidth", "managedHeight", "managedMinZ", "managedMaxZ",
        "roomMinX", "roomMaxX", "roomMinY", "roomMaxY", "roomZ",
        "wallMinX", "wallMaxX", "wallMinY", "wallMaxY", "wallZ",
        "roofMinX", "roofMaxX", "roofMinY", "roofMaxY", "roofZ", "z",
        "wallObjectCount", "wallCoordinateCount", "northEdges", "westEdges",
        "wallCornerCount",
    }
    local values = {}
    for i = 1, #fields do
        local field = fields[i]
        values[field] = requiredInteger(bounds[field], "manifest bounds " .. field)
    end
    if values.managedWidth ~= Constants.RV_MANAGED_WIDTH
        or values.managedHeight ~= Constants.RV_MANAGED_HEIGHT
        or values.managedOriginX ~= requiredInteger(managed.originX,
            "manifest managed.originX")
        or values.managedOriginY ~= requiredInteger(managed.originY,
            "manifest managed.originY")
        or values.managedMinZ ~= requiredInteger(managed.minZ,
            "manifest managed.minZ")
        or values.managedMaxZ ~= requiredInteger(managed.maxZ,
            "manifest managed.maxZ")
        or values.clearMinX ~= values.managedOriginX
        or values.clearMaxX ~= values.managedOriginX + values.managedWidth
        or values.clearMinY ~= values.managedOriginY
        or values.clearMaxY ~= values.managedOriginY + values.managedHeight
        or values.clearMinZ ~= values.managedMinZ
        or values.clearMaxZ ~= values.managedMaxZ
        or values.clearMaxX <= values.clearMinX
        or values.clearMaxY <= values.clearMinY
        or values.clearMaxZ <= values.clearMinZ
        or values.roomZ ~= values.z or values.wallZ ~= values.z
        or values.roofZ < values.managedMinZ
        or values.roofZ >= values.managedMaxZ
        or values.wallObjectCount ~= 92
        or values.wallCoordinateCount ~= 92
        or values.northEdges ~= 12 or values.westEdges ~= 80
        or values.wallCornerCount ~= 2 then
        return false
    end
    -- `bounds.bitmap` is the decoded current-layout snapshot persisted inside
    -- manifest.bounds, while the boundary copy arrives in encoded form and is
    -- decoded by currentManifestValid before this function is called.  Both
    -- are part of the current schema: validating only boundary.bitmap would
    -- allow a stale/corrupt bounds snapshot to steer wall/region consumers.
    if not Bitmap or type(bounds.bitmap) ~= "table"
        or type(Bitmap.validate) ~= "function" then
        return false
    end
    local boundsBitmapOk, boundsBitmapValid = pcall(Bitmap.validate,
        bounds.bitmap)
    local boundaryBitmapOk, boundaryBitmapValid = pcall(Bitmap.validate,
        bitmap)
    if not boundsBitmapOk or boundsBitmapValid ~= true
        or not boundaryBitmapOk or boundaryBitmapValid ~= true then
        return false
    end
    local bitmapFields = { "schemaVersion", "bitmapVersion", "originX",
        "originY", "width", "height", "minZ", "maxZ", "encoding" }
    for i = 1, #bitmapFields do
        local field = bitmapFields[i]
        if bounds.bitmap[field] ~= bitmap[field] then return false end
    end
    for z = bitmap.minZ, bitmap.maxZ - 1 do
        local boundsLayer, boundaryLayer = Bitmap.layer(bounds.bitmap, z),
            Bitmap.layer(bitmap, z)
        if type(boundsLayer) ~= "table" or type(boundaryLayer) ~= "table"
            or boundsLayer.walkBits ~= boundaryLayer.walkBits
            or boundsLayer.buildBits ~= boundaryLayer.buildBits
            or boundsLayer.encoding ~= boundaryLayer.encoding then
            return false
        end
    end
    if bitmap.originX ~= values.managedOriginX
        or bitmap.originY ~= values.managedOriginY
        or bitmap.width ~= values.managedWidth
        or bitmap.height ~= values.managedHeight
        or bitmap.minZ ~= values.managedMinZ
        or bitmap.maxZ ~= values.managedMaxZ
        or bounds.bitmap.originX ~= values.managedOriginX
        or bounds.bitmap.originY ~= values.managedOriginY
        or bounds.bitmap.width ~= values.managedWidth
        or bounds.bitmap.height ~= values.managedHeight
        or bounds.bitmap.minZ ~= values.managedMinZ
        or bounds.bitmap.maxZ ~= values.managedMaxZ then
        return false
    end
    if type(bounds.wallCoordinates) ~= "table"
        or #bounds.wallCoordinates ~= values.wallCoordinateCount
        or type(bounds.wallEdgeCounts) ~= "table"
        or not onlyKeys(bounds.wallEdgeCounts, { "north", "west" })
        or requiredInteger(bounds.wallEdgeCounts.north,
            "manifest bounds wallEdgeCounts.north") ~= values.northEdges
        or requiredInteger(bounds.wallEdgeCounts.west,
            "manifest bounds wallEdgeCounts.west") ~= values.westEdges
        or type(bounds.shellEdges) ~= "table" then
        return false
    end
    local wallCoordinateKeys = 0
    for key in pairs(bounds.wallCoordinates) do
        if type(key) ~= "number" or not isFiniteNumber(key)
            or math.floor(key) ~= key or key < 1
            or key > values.wallCoordinateCount then
            return false
        end
        wallCoordinateKeys = wallCoordinateKeys + 1
    end
    if wallCoordinateKeys ~= values.wallCoordinateCount then return false end
    local shellEdgeKeys = 0
    for key in pairs(bounds.shellEdges) do
        if type(key) ~= "string" or key == "" then return false end
        shellEdgeKeys = shellEdgeKeys + 1
    end
    if shellEdgeKeys ~= values.wallCoordinateCount then return false end
    local function inside(minX, maxX, minY, maxY, z)
        return minX <= maxX and minY <= maxY
            and minX >= values.managedOriginX
            and maxX < values.managedOriginX + values.managedWidth
            and minY >= values.managedOriginY
            and maxY < values.managedOriginY + values.managedHeight
            and z >= values.managedMinZ and z < values.managedMaxZ
    end
    if not inside(values.roomMinX, values.roomMaxX, values.roomMinY,
            values.roomMaxY, values.roomZ)
        or not inside(values.wallMinX, values.wallMaxX, values.wallMinY,
            values.wallMaxY, values.wallZ)
        or not inside(values.roofMinX, values.roofMaxX, values.roofMinY,
            values.roofMaxY, values.roofZ) then
        return false
    end
    local wallEntryKeys = {
        "x", "y", "z", "north", "sprite", "role", "corner",
        "edgeNorth", "edgeWest", "axis", "edgeKey", "edgeSide",
        "edgeCellX", "edgeCellY", "edgeHostX", "edgeHostY",
    }
    local expectedShellKeys = {}
    local shellEntryKeys = {
        "edgeKey", "rvId", "generation", "hostX", "hostY", "z", "axis",
        "side", "objectX", "objectY", "objectZ", "role", "corner",
        "replacementAllowed",
    }
    for i = 1, #bounds.wallCoordinates do
        local entry = bounds.wallCoordinates[i]
        if not onlyKeys(entry, wallEntryKeys)
            or type(entry) ~= "table"
            or type(entry.north) ~= "boolean"
            or type(entry.corner) ~= "boolean"
            or type(entry.edgeNorth) ~= "boolean"
            or type(entry.edgeWest) ~= "boolean"
            or entry.edgeNorth == entry.edgeWest
            or type(entry.edgeKey) ~= "string"
            or entry.edgeKey == ""
            or requiredInteger(entry.x, "manifest wall coordinate x") == nil
            or requiredInteger(entry.y, "manifest wall coordinate y") == nil
            or requiredInteger(entry.z, "manifest wall coordinate z") == nil
            or requiredInteger(entry.edgeCellX,
                "manifest wall coordinate edgeCellX") == nil
            or requiredInteger(entry.edgeCellY,
                "manifest wall coordinate edgeCellY") == nil
            or requiredInteger(entry.edgeHostX,
                "manifest wall coordinate edgeHostX") == nil
            or requiredInteger(entry.edgeHostY,
                "manifest wall coordinate edgeHostY") == nil
            or type(entry.sprite) ~= "string"
            or type(entry.role) ~= "string"
            or type(entry.axis) ~= "string"
            or (entry.axis ~= "N" and entry.axis ~= "W")
            or type(entry.edgeSide) ~= "string"
            or not Bitmap.containsScope(bitmap, entry.x, entry.y, entry.z) then
            return false
        end
        local expectedAxis = entry.north and "N" or "W"
        local expectedSide, expectedCellX, expectedCellY
        if entry.north then
            expectedSide = entry.y == values.wallMaxY and "south" or "north"
            expectedCellX = entry.x
            expectedCellY = entry.y - (expectedSide == "south" and 1 or 0)
        else
            expectedSide = entry.x == values.wallMaxX and "east" or "west"
            expectedCellX = entry.x - (expectedSide == "east" and 1 or 0)
            expectedCellY = entry.y
        end
        local expectedEdgeKey = Bitmap.edgeForSide and Bitmap.edgeForSide(
            expectedSide, expectedCellX, expectedCellY, entry.z) or nil
        local expectedRole = entry.north and "wall-north" or "wall-west"
        local expectedSprite = entry.north and Constants.SPRITES.wall.northSprite
            or Constants.SPRITES.wall.sprite
        if entry.corner then
            if entry.x == values.wallMinX and entry.y == values.wallMinY then
                expectedRole = "corner-nw"
                expectedSprite = Constants.SPRITES.wallNW.sprite
            elseif entry.x == values.wallMaxX and entry.y == values.wallMaxY then
                expectedRole = "corner-se"
                expectedSprite = Constants.SPRITES.wallSE.sprite
            else
                return false
            end
        end
        if entry.axis ~= expectedAxis
            or entry.edgeNorth ~= (expectedAxis == "N")
            or entry.edgeWest ~= (expectedAxis == "W")
            or entry.edgeSide ~= expectedSide
            or requiredInteger(entry.edgeCellX,
                "manifest wall coordinate edgeCellX") ~= expectedCellX
            or requiredInteger(entry.edgeCellY,
                "manifest wall coordinate edgeCellY") ~= expectedCellY
            or requiredInteger(entry.edgeHostX,
                "manifest wall coordinate edgeHostX") ~= entry.x
            or requiredInteger(entry.edgeHostY,
                "manifest wall coordinate edgeHostY") ~= entry.y
            or entry.edgeKey ~= expectedEdgeKey
            or entry.role ~= expectedRole
            or entry.sprite ~= expectedSprite then
            return false
        end
        expectedShellKeys[entry.edgeKey] = true
    end
    for key, edge in pairs(bounds.shellEdges) do
        if not expectedShellKeys[key]
            or type(edge) ~= "table"
            or not onlyKeys(edge, shellEntryKeys)
            or edge.edgeKey ~= key
            or edge.rvId ~= nil
            or edge.generation ~= nil
            or requiredInteger(edge.hostX, "manifest shell edge hostX") == nil
            or requiredInteger(edge.hostY, "manifest shell edge hostY") == nil
            or requiredInteger(edge.z, "manifest shell edge z") == nil
            or requiredInteger(edge.objectX, "manifest shell edge objectX") == nil
            or requiredInteger(edge.objectY, "manifest shell edge objectY") == nil
            or requiredInteger(edge.objectZ, "manifest shell edge objectZ") == nil
            or type(edge.axis) ~= "string"
            or type(edge.side) ~= "string"
            or type(edge.role) ~= "string"
            or type(edge.corner) ~= "boolean"
            or edge.replacementAllowed ~= true then
            return false
        end
        local wallEntry
        for i = 1, #bounds.wallCoordinates do
            if bounds.wallCoordinates[i].edgeKey == key then
                wallEntry = bounds.wallCoordinates[i]
                break
            end
        end
        if not wallEntry
            or edge.axis ~= wallEntry.axis
            or edge.side ~= wallEntry.edgeSide
            or edge.hostX ~= wallEntry.edgeHostX
            or edge.hostY ~= wallEntry.edgeHostY
            or edge.z ~= wallEntry.z
            or edge.objectX ~= wallEntry.x
            or edge.objectY ~= wallEntry.y
            or edge.objectZ ~= wallEntry.z
            or edge.role ~= wallEntry.role
            or edge.corner ~= wallEntry.corner then
            return false
        end
    end
    for key in pairs(expectedShellKeys) do
        if bounds.shellEdges[key] == nil then return false end
    end
    return true
end

local function currentManifestValid(manifest, allowEmpty)
    if type(manifest) ~= "table" then return false end
    local hasField = false
    for _ in pairs(manifest) do
        hasField = true
        break
    end
    if not hasField then return allowEmpty == true end
    local manifestKeys = {
        schemaVersion = true, techVersion = true, generation = true,
        owner = true, anchor = true, bounds = true, rvId = true,
        boundarySchemaVersion = true, bitmapVersion = true, boundary = true,
        startedAt = true, rollback = true, state = true, updatedAt = true,
        phase = true, phaseGeneration = true, phaseUpdatedAt = true,
        completedAt = true, lastError = true,
    }
    for key in pairs(manifest) do
        if not manifestKeys[key] then return false end
    end
    if manifest.version ~= nil or manifest.managed ~= nil
        or manifest.bitmap ~= nil or manifest.shellEdges ~= nil
        or requiredInteger(manifest.schemaVersion, "manifest schemaVersion")
        ~= Constants.MANIFEST_SCHEMA_VERSION
        or manifest.techVersion ~= Constants.TECH_VERSION
        or manifest.owner ~= OWNER
        or type(manifest.state) ~= "string"
        or (manifest.state ~= "RUNNING" and manifest.state ~= "READY"
            and manifest.state ~= "FAILED")
        or requiredInteger(manifest.generation, "manifest generation") < 1
        or type(manifest.rvId) ~= "string" or manifest.rvId == ""
        or requiredInteger(manifest.bitmapVersion, "manifest bitmapVersion")
            ~= Constants.BITMAP_VERSION
        or requiredInteger(manifest.boundarySchemaVersion,
            "manifest boundarySchemaVersion") ~= Constants.BOUNDARY_SCHEMA_VERSION
        or type(manifest.anchor) ~= "table"
        or requiredInteger(manifest.anchor.x, "manifest anchor.x") == nil
        or requiredInteger(manifest.anchor.y, "manifest anchor.y") == nil
        or requiredInteger(manifest.anchor.z, "manifest anchor.z") == nil
        or type(manifest.bounds) ~= "table"
        or type(manifest.boundary) ~= "table"
        or requiredInteger(manifest.boundary.schemaVersion,
            "manifest boundary schemaVersion") ~= Constants.BOUNDARY_SCHEMA_VERSION
        or tostring(manifest.boundary.rvId) ~= tostring(manifest.rvId)
        or requiredInteger(manifest.boundary.generation,
            "manifest boundary generation") ~= requiredInteger(manifest.generation,
            "manifest generation")
        or requiredInteger(manifest.boundary.bitmapVersion,
            "manifest boundary bitmapVersion") ~= requiredInteger(manifest.bitmapVersion,
            "manifest bitmapVersion")
        or type(manifest.boundary.managed) ~= "table"
        or type(manifest.boundary.bitmap) ~= "table"
        or type(manifest.boundary.shellEdges) ~= "table" then
        return false
    end
    local boundaryBitmapOk, boundaryBitmap = false, nil
    if Bitmap and type(Bitmap.decode) == "function" then
        boundaryBitmapOk, boundaryBitmap = pcall(Bitmap.decode,
            manifest.boundary.bitmap)
    end
    if not boundaryBitmapOk or type(boundaryBitmap) ~= "table"
        or not currentBoundsValid(manifest.bounds,
            manifest.boundary.managed, boundaryBitmap) then
        return false
    end
    local startedAt = requiredInteger(manifest.startedAt, "manifest startedAt")
    local updatedAt = requiredInteger(manifest.updatedAt, "manifest updatedAt")
    local phaseGeneration = requiredInteger(manifest.phaseGeneration,
        "manifest phaseGeneration")
    local phaseUpdatedAt = requiredInteger(manifest.phaseUpdatedAt,
        "manifest phaseUpdatedAt")
    local generation = requiredInteger(manifest.generation, "manifest generation")
    if type(manifest.phase) ~= "string"
        or (manifest.phase ~= "RUNNING"
            and manifest.phase ~= "CLEARING"
            and manifest.phase ~= "WOOD_FLOOR"
            and manifest.phase ~= "WALLS"
            and manifest.phase ~= "ROOF_FLOOR"
            and manifest.phase ~= "STRUCTURE_RECALC"
            and manifest.phase ~= "GENERATOR"
            and manifest.phase ~= "RAIN_BARREL"
            and manifest.phase ~= "COUNTER_SINK"
            and manifest.phase ~= "LIGHT"
            and manifest.phase ~= "FINAL_RELOCATE"
            and manifest.phase ~= "COMMITTED"
            and manifest.phase ~= "ROLLED_BACK"
            and manifest.phase ~= "FAILED")
        or startedAt < 1 or updatedAt < startedAt
        or phaseGeneration ~= generation or phaseUpdatedAt < startedAt
        or manifest.rollback ~= nil
            and manifest.rollback ~= "COMPLETE"
            and manifest.rollback ~= "FAILED"
        or manifest.lastError ~= nil and type(manifest.lastError) ~= "string"
        or manifest.completedAt ~= nil
            and requiredInteger(manifest.completedAt, "manifest completedAt") < 1
        or (manifest.state == "READY"
            and (manifest.phase ~= "COMMITTED"
                or requiredInteger(manifest.completedAt,
                    "manifest completedAt") == nil)) then
        return false
    end
    local bitmap = boundaryBitmap
    local bitmapValidOk, bitmapValid = false, false
    if Bitmap and type(Bitmap.validate) == "function" then
        bitmapValidOk, bitmapValid = pcall(Bitmap.validate, bitmap)
    end
    if not bitmapValidOk or bitmapValid ~= true
        or bitmap.bitmapVersion ~= Constants.BITMAP_VERSION
        or bitmap.originX ~= manifest.boundary.managed.originX
        or bitmap.originY ~= manifest.boundary.managed.originY
        or bitmap.width ~= manifest.boundary.managed.width
        or bitmap.height ~= manifest.boundary.managed.height
        or bitmap.minZ ~= manifest.boundary.managed.minZ
            or bitmap.maxZ ~= manifest.boundary.managed.maxZ then
        return false
    end
    if not Boundary or type(Boundary.registerGeneration) ~= "function" then
        return false
    end
    local boundaryOk, registered = pcall(Boundary.registerGeneration,
        manifest.rvId, manifest.generation, manifest.boundary, nil)
    if not boundaryOk or registered ~= true then return false end
    return true
end

requireCurrentManifest = function(manifest, allowEmpty)
    local ok, valid = pcall(currentManifestValid, manifest, allowEmpty)
    if not ok or valid ~= true then
        error(Constants.SAVE_REBUILD_REQUIRED)
    end
    return manifest
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

local function squareHasRoofRepairOccupant(square, allowedPlayers)
    if not square then return true end
    local collections = {
        "getObjects", "getSpecialObjects", "getStaticMovingObjects",
        "getMovingObjects", "getWorldObjects", "getDeadBodys", "getCorpses",
    }
    for i = 1, #collections do
        local collectionOk, collection = invoke(square, collections[i])
        if collectionOk and collection ~= nil then
            local sizeOk, size = invoke(collection, "size")
            local numericSize = toNumber(size)
            if sizeOk and numericSize ~= nil and numericSize > 0 then
                if collections[i] ~= "getMovingObjects"
                    or type(allowedPlayers) ~= "table" then
                    return true
                end
                local foreign = false
                for index = 0, numericSize - 1 do
                    local itemOk, item = invoke(collection, "get", index)
                    if not itemOk or item ~= nil and not allowedPlayers[item] then
                        foreign = true
                        break
                    end
                end
                if foreign then return true end
            end
            if type(collection) == "table" then
                for _, value in pairs(collection) do
                    if value ~= nil and (collections[i] ~= "getMovingObjects"
                        or type(allowedPlayers) ~= "table"
                        or not allowedPlayers[value]) then
                        return true
                    end
                end
            end
        end
    end
    local vehicleOk, vehicle = invoke(square, "getVehicleContainer")
    return vehicleOk and vehicle ~= nil
end

-- The remote experiment may land on a layer without an ordinary floor. Still
-- reject any room/vehicle/object occupancy; if the engine presents a normal
-- solid floor, retain the stricter shared relocation check above.
local function roofRepairTemporarySquareSafe(square, allowedPlayers)
    if squareIsSafeForRelocation(square, false) then return true end
    if not square or squareHasRoofRepairOccupant(square, allowedPlayers) then
        return false
    end
    local roomOk, room = invoke(square, "getRoom")
    local roomIdOk, roomId = invoke(square, "getRoomID")
    if not roomOk or room ~= nil or not roomIdOk or toNumber(roomId) ~= -1 then
        return false
    end
    local regionOk, region = invoke(square, "getIsoWorldRegion")
    if not regionOk then return false end
    if region ~= nil then
        local playerRoomOk, playerRoom = invoke(region, "isPlayerRoom")
        if not playerRoomOk or playerRoom == true then return false end
    end
    return true
end

-- First-generation staging deliberately lands at the current managed-scope
-- center on z=-15.  The point is computed only from the validated
-- layout/bitmap contract; unlike roof refresh, it is not the remote
-- center-minus-(18000,0,15) experiment and it is allowed to have no ordinary
-- GridSquare while the destination chunk streams.
local function selectGenerationStagingDestination(layout, bounds)
    if type(layout) ~= "table" or type(bounds) ~= "table"
        or type(layout.bitmap) ~= "table" then
        error("RailroaderRVTest: generation staging contract is incomplete")
    end
    local originX = requiredInteger(bounds.managedOriginX,
        "generation managed origin x")
    local originY = requiredInteger(bounds.managedOriginY,
        "generation managed origin y")
    local width = requiredInteger(bounds.managedWidth,
        "generation managed width")
    local height = requiredInteger(bounds.managedHeight,
        "generation managed height")
    if width ~= requiredInteger(layout.bitmap.width, "generation bitmap width")
        or height ~= requiredInteger(layout.bitmap.height,
            "generation bitmap height")
        or originX ~= requiredInteger(layout.bitmap.originX,
            "generation bitmap origin x")
        or originY ~= requiredInteger(layout.bitmap.originY,
            "generation bitmap origin y")
        or width <= 0 or height <= 0 then
        error("RailroaderRVTest: generation staging bitmap identity is stale")
    end
    local destination = {
        x = originX + math.floor(width / 2),
        y = originY + math.floor(height / 2),
        z = GENERATION_STAGING_Z,
        purpose = "generation-center",
    }
    local worldOk, world = callGlobal("getWorld")
    if not worldOk or world == nil then
        error("RailroaderRVTest: getWorld is unavailable for generation staging")
    end
    local validOk, valid = invoke(world, "isValidSquare", destination.x,
        destination.y, destination.z)
    if not validOk or valid ~= true then
        error("RailroaderRVTest: generation center staging coordinate is illegal")
    end
    return destination
end

local function playerIsAtStagingDestination(player, destination, bounds, _oldBounds)
    local playerOk, positionOrReason = validateAuthoritativePlayer(player)
    if not playerOk then
        return false, positionOrReason
    end
    if positionOrReason.x ~= destination.x or positionOrReason.y ~= destination.y
        or positionOrReason.z ~= destination.z then
        return false, "server player has not reached the relocation destination"
    end
    if destination.purpose == "generation-center" then
        local expectedX = bounds.managedOriginX
            + math.floor(bounds.managedWidth / 2)
        local expectedY = bounds.managedOriginY
            + math.floor(bounds.managedHeight / 2)
        if destination.z ~= GENERATION_STAGING_Z
            or destination.x ~= expectedX or destination.y ~= expectedY then
            return false, "generation staging destination identity is stale"
        end
        return true
    end
    return false, "generation staging destination identity is stale"
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

local function roofRepairPosition(position, label)
    if type(position) ~= "table" then
        error("RailroaderRVTest: roof repair " .. tostring(label)
            .. " position is unavailable")
    end
    local x = requiredNumber(position.x, "roof repair " .. tostring(label) .. " x")
    local y = requiredNumber(position.y, "roof repair " .. tostring(label) .. " y")
    local z = requiredNumber(position.z, "roof repair " .. tostring(label) .. " z")
    if z < WORLD_MIN_Z or z > WORLD_MAX_Z then
        error("RailroaderRVTest: roof repair " .. tostring(label)
            .. " z is outside the legal world range")
    end
    -- Keep the exact finite server position in the transaction.  Bitmap and
    -- world safety callers floor this snapshot only for square membership;
    -- the return payload and teleportTo use these raw coordinates verbatim.
    return { x = x, y = y, z = z }
end

local function roofRepairWorldCoordinateValid(destination)
    local worldOk, world = callGlobal("getWorld")
    if not worldOk or not world then
        return false, "roof repair world is unavailable"
    end
    local validOk, valid = invoke(world, "isValidSquare",
        math.floor(destination.x), math.floor(destination.y),
        math.floor(destination.z))
    if not validOk or valid ~= true then
        return false, "roof repair relocation target is outside the legal world"
    end
    return true
end

-- Read the current mapping/boundary identity from the authoritative server
-- player.  The request object is built by RV_RailroaderServer; it never carries
-- a client coordinate or persisted legacy geometry.  Rechecking the manifest
-- here keeps the generic relocation bridge safe if a generation changes between
-- the wall event and the next server tick.
local function currentRoofRepairContext(player, request)
    local requestGeneration = type(request) == "table"
        and integer(request.generation) or nil
    local requestBitmapVersion = type(request) == "table"
        and integer(request.bitmapVersion) or nil
    if type(request) ~= "table"
        or tostring(request.rvId or "") == ""
        or requestGeneration == nil or requestGeneration < 1
        or requestBitmapVersion ~= Constants.BITMAP_VERSION then
        return false, Constants.SAVE_REBUILD_REQUIRED
   end
    if not Boundary or type(Boundary.boundaryForPlayer) ~= "function" then
        return false, "RV boundary service is unavailable"
    end
    local boundaryOk, boundary, record, relation, boundaryIdentity = pcall(
        Boundary.boundaryForPlayer, player)
    if not boundaryOk or type(boundary) ~= "table"
        or type(record) ~= "table" or type(relation) ~= "table"
        or type(boundaryIdentity) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    if tostring(boundary.rvId) ~= tostring(request.rvId)
        or integer(boundary.generation) ~= requestGeneration
        or integer(boundary.bitmapVersion) ~= requestBitmapVersion
        or relation.inside ~= true
        or tostring(boundaryIdentity.key) ~= tostring(request.identityKey) then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local name = boundaryIdentity.username
    local rider = type(record.players) == "table" and record.players[name] or nil
    if type(rider) ~= "table" or rider.inside ~= true
        or integer(rider.onlineId) ~= integer(relation.onlineId)
        or integer(rider.onlineId) ~= integer(boundaryIdentity.onlineId) then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end

    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local manifest = manifestOrError
    local schemaOk = pcall(requireCurrentManifest, manifest, false)
    if not schemaOk or tostring(manifest.rvId) ~= tostring(request.rvId)
        or integer(manifest.generation) ~= requestGeneration
        or integer(manifest.bitmapVersion) ~= requestBitmapVersion
        or type(manifest.boundary) ~= "table"
        or tostring(manifest.boundary.rvId) ~= tostring(request.rvId)
        or integer(manifest.boundary.generation) ~= integer(request.generation)
        or integer(manifest.boundary.bitmapVersion) ~= integer(request.bitmapVersion) then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    -- All consumers share one cross-object geometry proof.  Keeping this
    -- check in RV_Server prevents the roof path, boundary guard, and
    -- stateless sentinel from each accepting a different "current" snapshot.
    local geometryService = RV and RV.Server
        and RV.Server.currentRVRecordGeometryConsistent
    if type(geometryService) ~= "function" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local geometryCallOk, geometryConsistent = pcall(geometryService, record,
        manifest)
    if not geometryCallOk or geometryConsistent ~= true then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local bitmap = boundary.bitmap
    if type(bitmap) ~= "table" or not Bitmap
        or type(Bitmap.validate) ~= "function" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local bitmapOk, bitmapValid = pcall(Bitmap.validate, bitmap)
    if not bitmapOk or bitmapValid ~= true then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    return true, {
        boundary = boundary,
        record = record,
        relation = relation,
        identity = boundaryIdentity,
        manifest = manifest,
        bitmap = bitmap,
    }
end

local function roofRepairDestination(context, request)
    local bitmap = context and context.bitmap
    if type(bitmap) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local phase = tostring(request.phase or "")
    if phase == "temporary" then
        local width = requiredInteger(bitmap.width, "roof repair bitmap width")
        local height = requiredInteger(bitmap.height, "roof repair bitmap height")
        local originX = requiredInteger(bitmap.originX, "roof repair bitmap originX")
        local originY = requiredInteger(bitmap.originY, "roof repair bitmap originY")
        if width ~= Constants.RV_MANAGED_WIDTH
            or height ~= Constants.RV_MANAGED_HEIGHT then
            return false, Constants.SAVE_REBUILD_REQUIRED
        end
        local centerZ = requiredInteger(bitmap.minZ,
            "roof repair bitmap center z")
        if centerZ < WORLD_MIN_Z or centerZ > WORLD_MAX_Z then
            return false, Constants.SAVE_REBUILD_REQUIRED
        end
        -- Force the RV scope to leave the loaded chunk set.  The center comes
        -- from the current validated bitmap (the same layout contract used by
        -- generation), then the current refresh vector is subtracted.  Never
        -- replace this with a fixed absolute world coordinate or a boundary
        -- edge/staging square.
        local destination = {
            x = originX + math.floor(width / 2)
                - ROOF_REPAIR_REMOTE_OFFSET_X,
            y = originY + math.floor(height / 2)
                - ROOF_REPAIR_REMOTE_OFFSET_Y,
            z = centerZ - ROOF_REPAIR_REMOTE_OFFSET_Z,
        }
        if destination.z < WORLD_MIN_Z or destination.z > WORLD_MAX_Z then
            return false, Constants.SAVE_REBUILD_REQUIRED
        end
        return true, destination
    end
    if phase ~= "return" then
        return false, "roof repair relocation phase is invalid"
    end
    local destinationOk, destination = pcall(roofRepairPosition,
        request.returnPosition, "return")
    if not destinationOk then return false, Constants.SAVE_REBUILD_REQUIRED end
    local x, y, z = math.floor(destination.x), math.floor(destination.y),
        math.floor(destination.z)
    if not Bitmap.containsScope(bitmap, x, y, z)
        or not Bitmap.isActive(bitmap, x, y, z) then
        return false, "roof repair return position is not current active RV geometry"
    end
    return true, destination
end

local function playerAtRoofRepairDestination(player, destination,
    allowMissingSquare)
    local playerOk, positionOrReason = validateAuthoritativePlayer(player)
    if not playerOk then return false, positionOrReason end
    if math.floor(positionOrReason.x) ~= math.floor(destination.x)
        or math.floor(positionOrReason.y) ~= math.floor(destination.y)
        or math.floor(positionOrReason.z) ~= math.floor(destination.z) then
        return false, "server player has not reached the roof repair destination"
    end
    local squareOk, current = invoke(player, "getCurrentSquare")
    if not squareOk or current == nil then
        if allowMissingSquare then return true end
        return false, "server player has no current square after roof repair relocation"
    end
    local xOk, x = invoke(current, "getX")
    local yOk, y = invoke(current, "getY")
    local zOk, z = invoke(current, "getZ")
    if not xOk or not yOk or not zOk
        or toNumber(x) ~= math.floor(destination.x)
        or toNumber(y) ~= math.floor(destination.y)
        or toNumber(z) ~= math.floor(destination.z) then
        return false,
            "server player current square does not match roof repair destination"
    end
    return true, current
end

local function roofRepairTargetReady(player, destination, phase, allowedPlayers)
    local allowMissingSquare = phase == "temporary"
        and type(allowedPlayers) == "table"
    local atDestination, destinationReason = playerAtRoofRepairDestination(
        player, destination, allowMissingSquare)
    if not atDestination then return false, destinationReason end
    if phase ~= "temporary" then return true end
    -- A grouped roof refresh intentionally targets the current-schema center
    -- minus the remote vector.  That legal server coordinate can be in an
    -- unloaded/empty layer, so a missing GridSquare is not evidence that the
    -- authoritative teleport failed.  The bounded adapter wait still keeps
    -- this phase across multiple ticks before return is armed.
    if allowMissingSquare then
        local cellOk, cell = pcall(getCellForPlayer, player)
        if not cellOk or not cell then return true end
        local square = getSquare(cell, math.floor(destination.x),
            math.floor(destination.y), math.floor(destination.z))
        if not square then return true end
        if not roofRepairTemporarySquareSafe(square, allowedPlayers) then
            return false, "roof repair temporary destination is still room geometry"
        end
        return true
    end
    local cellOk, cell = pcall(getCellForPlayer, player)
    if not cellOk or not cell then
        return false, "roof repair temporary destination cell is not loaded"
    end
    local square = getSquare(cell, math.floor(destination.x),
        math.floor(destination.y), math.floor(destination.z))
    if not square then
        return false, "roof repair temporary destination square is not loaded"
    end
    -- The temporary move is only considered complete after the player has left
    -- the dynamic room geometry.  A wall-removal callback can arrive before
    -- IsoRegions has retired the old room, so this remains a retryable status
    -- until the bounded relocation timeout expires.
    if not roofRepairTemporarySquareSafe(square, allowedPlayers) then
        return false, "roof repair temporary destination is still room geometry"
    end
    return true
end

local function copyRoofRepairPosition(position)
    if type(position) ~= "table" then return nil end
    local x, y, z = toNumber(position.x), toNumber(position.y),
        toNumber(position.z)
    if not isFiniteNumber(x) or not isFiniteNumber(y)
        or not isFiniteNumber(z) then return nil end
    if z < WORLD_MIN_Z or z > WORLD_MAX_Z then return nil end
    return { x = x, y = y, z = z }
end

-- Validate the server-captured return square immediately before every final
-- return attempt.  No client coordinate is accepted and no old mapping or
-- geometry can be used as a fallback.  This gate deliberately re-reads the
-- current boundary/manifest identity so a stale transaction fails closed.
local function validatedRoofRepairReturn(pending)
    if type(pending) ~= "table" or not pending.player
        or not pending.identity then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local resolved, livePlayerOrReason = resolvePendingPlayer(pending)
    if not resolved then return false, livePlayerOrReason end
    local livePlayer = livePlayerOrReason
    local identityOk, identityOrReason = playerIdentity(livePlayer)
    if not identityOk or identityOrReason.key ~= pending.identity.key then
        return false, identityOk and "roof repair return identity changed"
            or identityOrReason
    end
    local contextOk, contextOrReason = currentRoofRepairContext(livePlayer,
        { rvId = pending.rvId, generation = pending.generation,
            bitmapVersion = pending.bitmapVersion,
            identityKey = identityOrReason.key })
    if not contextOk then return false, contextOrReason end
    local returnPosition = copyRoofRepairPosition(pending.returnPosition)
    if not returnPosition then return false, Constants.SAVE_REBUILD_REQUIRED end
    local returnX, returnY, returnZ = math.floor(returnPosition.x),
        math.floor(returnPosition.y), math.floor(returnPosition.z)
    if not Bitmap.containsScope(contextOrReason.bitmap, returnX, returnY,
        returnZ)
        or not Bitmap.isActive(contextOrReason.bitmap, returnX, returnY,
            returnZ) then
        return false, "roof repair return position is not current active RV geometry"
    end
    return true, {
        identity = identityOrReason,
        context = contextOrReason,
        position = returnPosition,
    }
end

-- Roll a temporary roof relocation back to the server-captured inside
-- position.  This path is used for timeout, disconnect/death and identity or
-- schema changes.  It never edits ModData or world objects.  The client gets
-- the same server-authored RVTeleport bridge used by normal entry/exit, while
-- the authoritative server object is moved first/alongside it.
local function rollbackRoofRepairRelocation(pending)
    if type(pending) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local targetOk, targetOrReason = validatedRoofRepairReturn(pending)
    if not targetOk then
        print("[RailroaderRVTest] roof repair rollback refused room="
            .. tostring(pending.roomKey or "unknown") .. " reason="
            .. safeErrorText(targetOrReason))
        return false, targetOrReason
    end
    local player = pending.player
    if not player then return false, Constants.SAVE_REBUILD_REQUIRED end
    local returnPosition = targetOrReason.position
    local identity = targetOrReason.identity
    local liveCallOk, livePosition, liveReason = pcall(
        authoritativePlayerPosition, player)
    if not liveCallOk or type(livePosition) ~= "table" then
        local reason = liveCallOk and liveReason or livePosition
        print("[RailroaderRVTest] roof repair rollback refused room="
            .. tostring(pending.roomKey or "unknown") .. " reason="
            .. safeErrorText(reason) .. " return="
            .. tostring(returnPosition.x) .. "," .. tostring(returnPosition.y)
            .. "," .. tostring(returnPosition.z))
        return false, reason
    end
    local worldOk, worldReason = roofRepairWorldCoordinateValid(returnPosition)
    if not worldOk then
        print("[RailroaderRVTest] roof repair rollback refused room="
            .. tostring(pending.roomKey or "unknown") .. " reason="
            .. safeErrorText(worldReason) .. " return=" .. tostring(returnPosition.x)
            .. "," .. tostring(returnPosition.y) .. ","
            .. tostring(returnPosition.z))
        return false, worldReason
    end

    local payload = {
        ok = true,
        action = "roof-repair-cancel",
        token = pending.token,
        onlineId = identity.onlineId,
        rvId = tostring(pending.rvId),
        generation = integer(pending.generation),
        bitmapVersion = integer(pending.bitmapVersion),
        x = returnPosition.x, y = returnPosition.y, z = returnPosition.z,
        roofRepairTransition = true,
        roofRepairPhase = "return",
    }
    local sentOk = callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_RELOCATE, payload)
    local moved = callSucceeded(player, "teleportTo", returnPosition.x,
        returnPosition.y, returnPosition.z)
    -- A successful teleport call is not enough: the authoritative object must
    -- have actually left the remote z=-15 target and be back on the exact
    -- server-captured active square before the lease/context may be retired.
    local positionOk, currentPosition = authoritativePlayerPosition(player)
    local atCapturedReturn = positionOk
        and currentPosition.z ~= ROOF_REPAIR_TEMP_Z
        and currentPosition.x == returnPosition.x
        and currentPosition.y == returnPosition.y
        and currentPosition.z == returnPosition.z
    local leaseComplete = false
    if sentOk and moved and atCapturedReturn
        and Boundary and type(Boundary.completeTransition) == "function"
        and type(pending.token) == "string" then
        local completeOk, completeResult = pcall(
            Boundary.completeTransition, player, pending.token)
        leaseComplete = completeOk and completeResult == true
    end
    -- Never clear a live correction lease while the authoritative player is
    -- still underground or the client/server return handshake is incomplete.
    -- The bounded/async final-return owner retries this same current-schema
    -- context instead of stranding the player after a finite retry budget.
    local rolledBack = sentOk and moved and atCapturedReturn and leaseComplete
    print("[RailroaderRVTest] roof repair rollback room="
        .. tostring(pending.roomKey or "unknown") .. " result="
        .. (rolledBack and "complete" or "failed") .. " current="
        .. tostring(livePosition.x) .. "," .. tostring(livePosition.y) .. ","
        .. tostring(livePosition.z) .. " return=" .. tostring(returnPosition.x)
        .. "," .. tostring(returnPosition.y) .. ","
        .. tostring(returnPosition.z))
    if rolledBack then return true end
    if currentPosition and currentPosition.z == ROOF_REPAIR_TEMP_Z then
        return false, "roof repair player remains at temporary z=-15"
    end
    if not atCapturedReturn then
        return false, "roof repair player has not reached the captured return square"
    end
    if not leaseComplete then
        return false, "roof repair boundary transition could not be completed"
    end
    return false, "roof repair return command or authoritative teleport failed"
end

local function roofRepairGroupMatches(group, rvId, generation, bitmapVersion)
    return type(group) == "table"
        and tostring(group.rvId) == tostring(rvId)
        and integer(group.generation) == integer(generation)
        and integer(group.bitmapVersion) == integer(bitmapVersion)
end

local function roofRepairGroupMember(group, player, token)
    if type(group) ~= "table" or type(group.members) ~= "table" then
        return nil
    end
    local identityKey = nil
    if player ~= nil then
        local identityOk, identity = playerIdentity(player)
        if identityOk then identityKey = identity.key end
    end
    for i = 1, #group.members do
        local member = group.members[i]
        if (member.player == player
                or identityKey ~= nil and member.identityKey == identityKey)
            and (token == nil or member.token == token) then
            return member
        end
    end
    return nil
end

local function roofRepairGroupAll(group, field, value)
    if type(group) ~= "table" or type(group.members) ~= "table"
        or #group.members == 0 then
        return false
    end
    for i = 1, #group.members do
        if group.members[i][field] ~= value then return false end
    end
    return true
end

local function roofRepairExactPosition(player)
    return authoritativePlayerPosition(player)
end

-- The group fail-safe never trusts a position supplied by the adapter.  Each
-- member's exact original position is captured from the authoritative server
-- object before the first remote command; returnPosition is only the integer
-- square required by the token-only client bridge.
local function failRoofRepairRelocationGroup(reason)
    local group = roofRepairRelocationGroup
    if not group then return end
    roofRepairRelocationGroup = nil
    roofRepairGroupFailure = {
        roomKey = group.roomKey,
        rvId = group.rvId,
        generation = group.generation,
        bitmapVersion = group.bitmapVersion,
        token = group.token,
        reason = safeErrorText(reason),
    }
    local allReturned = true
    for i = 1, #group.members do
        local member = group.members[i]
        member.finalReturnReason = reason
        local rollbackCallOk, returned, returnReason = pcall(
            rollbackRoofRepairRelocation, member)
        if not rollbackCallOk then
            returnReason = safeErrorText(returned)
            returned = false
        end
        member.finalReturned = returned == true
        member.finalReturnReason = returnReason or reason
        if not member.finalReturned then allReturned = false end
        notifyFailure(member.player, reason)
    end
    if not allReturned then
        roofRepairGroupFinalReturn = {
            group = group,
            attempts = 0,
            nextTick = serverTick + 1,
        }
    else
    end
    print("[RailroaderRVTest] roof repair group cancelled room="
        .. tostring(group.roomKey or "unknown") .. " members="
        .. tostring(#group.members) .. " reason=" .. safeErrorText(reason)
        .. " finalReturn=" .. (allReturned and "complete" or "pending"))
end

local function processRoofRepairGroupFinalReturn()
    local retry = roofRepairGroupFinalReturn
    if not retry or serverTick < (retry.nextTick or serverTick) then return end
    local group = retry.group
    retry.attempts = (retry.attempts or 0) + 1
    local allReturned = true
    for i = 1, #(group.members or {}) do
        local member = group.members[i]
        if member.finalReturned then
            -- A member marked returned on the previous tick is still polled
            -- authoritatively.  Do not retire the in-memory return owner if it
            -- drifted back to z=-15 or anywhere other than its captured RV coordinate.
            local resolved, playerOrReason = resolveRoofRepairGroupPlayer(
                group, member)
            local positionOk, position = false, nil
            if resolved then
                positionOk, position = pcall(authoritativePlayerPosition,
                    playerOrReason)
            end
            local original = member.originalPosition or member.returnPosition
            if not positionOk or type(position) ~= "table"
                or type(original) ~= "table"
                or position.z == ROOF_REPAIR_TEMP_Z
                or position.x ~= original.x or position.y ~= original.y
                or position.z ~= original.z then
                member.finalReturned = false
            end
        end
        if not member.finalReturned then
            local rollbackCallOk, returned, returnReason = pcall(
                rollbackRoofRepairRelocation, member)
            if not rollbackCallOk then
                returnReason = safeErrorText(returned)
                returned = false
            end
            member.finalReturned = returned == true
            member.finalReturnReason = returnReason
        end
        if not member.finalReturned then allReturned = false end
    end
    if allReturned then
        print("[RailroaderRVTest] roof repair group final return complete room="
            .. tostring(group.roomKey or "unknown") .. " attempts="
            .. tostring(retry.attempts))
        roofRepairGroupFinalReturn = nil
        return
    end
    -- A member at the remote z=-15 target is not a recoverable completion.
    -- Keep the current-schema identity/context alive and continue bounded-rate
    -- retries until the authoritative object is actually back.  In particular,
    -- do not clear the Boundary lease or drop the group after a finite count.
    retry.nextTick = serverTick + ROOF_REPAIR_RETURN_RETRY_TICKS
    print("[RailroaderRVTest] roof repair group final return pending room="
        .. tostring(group.roomKey or "unknown") .. " attempt="
        .. tostring(retry.attempts + 1) .. " reason=authoritative-return-required")
end

-- Begin or advance the multi-player refresh transaction. The adapter supplies
-- only authoritative player object references; this function re-reads every
-- identity, schema relation and x/y/z before arming any transition. The
-- temporary move is sent to all members before the adapter may run repair, so
-- the complete RV scope can unload and stream back in as one operation.
function RV.Server.beginRoofRepairRelocationGroup(request)
    local callOk, result, reason = pcall(function()
        if (type(request) ~= "table" or request.phase == "temporary")
            and (roofRepairRelocationGroup ~= nil
                or roofRepairGroupFinalReturn ~= nil)
            or transactionBusy
            or pendingGeneration ~= nil then
            return false, "another RV relocation or generation is in progress"
        end
        if type(request) ~= "table"
            or (request.phase ~= "temporary" and request.phase ~= "return") then
            return false, "roof repair group relocation request is malformed"
        end
        local rvId = tostring(request.rvId or "")
        local generation = integer(request.generation)
        local bitmapVersion = integer(request.bitmapVersion)
        local roomKey = tostring(request.roomKey or "")
        if rvId == "" or generation == nil or generation < 1
            or bitmapVersion ~= Constants.BITMAP_VERSION
            or roomKey ~= rvId .. ":" .. tostring(generation) .. ":"
                .. tostring(bitmapVersion) then
            return false, Constants.SAVE_REBUILD_REQUIRED
        end

        if request.phase == "return" then
            local group = roofRepairRelocationGroup
            if not roofRepairGroupMatches(group, rvId, generation,
                bitmapVersion) or group.roomKey ~= roomKey
                or group.phase ~= "temporary"
                or not roofRepairGroupAll(group, "arrived", true) then
                return false, "roof repair group temporary phase is not complete"
            end
            local returnToken = group.token
            for i = 1, #group.members do
                local member = group.members[i]
                local resolved, playerOrReason = resolveRoofRepairGroupPlayer(
                    group, member)
                if not resolved then
                    -- A live-process disconnect is retryable; the stable
                    -- identity remains owned by this in-memory group.
                    if playerOrReason == "requesting player disconnected or was replaced" then
                        return false, playerOrReason
                    end
                    failRoofRepairRelocationGroup(playerOrReason)
                    return false, playerOrReason
                end
                local livePlayer = playerOrReason
                local contextOk, contextOrReason = currentRoofRepairContext(
                    livePlayer, {
                        rvId = rvId, generation = generation,
                        bitmapVersion = bitmapVersion,
                        identityKey = member.identity.key,
                    })
                if not contextOk then
                    failRoofRepairRelocationGroup(contextOrReason)
                    return false, contextOrReason
                end
                local returnPosition = member.returnPosition
                local returnX, returnY, returnZ = math.floor(returnPosition.x),
                    math.floor(returnPosition.y), math.floor(returnPosition.z)
                if not Bitmap.containsScope(contextOrReason.bitmap, returnX,
                    returnY, returnZ)
                    or not Bitmap.isActive(contextOrReason.bitmap, returnX,
                        returnY, returnZ) then
                    local failure = "roof repair group return position is not current active RV geometry"
                    failRoofRepairRelocationGroup(failure)
                    return false, failure
                end
                local worldOk, worldReason = roofRepairWorldCoordinateValid(
                    returnPosition)
                if not worldOk then
                    failRoofRepairRelocationGroup(worldReason)
                    return false, worldReason
                end
                member.phase = "return"
                member.target = copyRoofRepairPosition(returnPosition)
                member.acknowledged = false
                member.arrived = false
                member.arrivalConsumed = false
                member.returnPayload = {
                    token = returnToken,
                    onlineId = member.identity.onlineId,
                    rvId = rvId, generation = generation,
                    bitmapVersion = bitmapVersion,
                    x = member.target.x, y = member.target.y, z = member.target.z,
                    roofRepairTransition = true,
                    roofRepairPhase = "return",
                }
            end
            group.phase = "return"
            group.returnStartedAtTick = serverTick
            for i = 1, #group.members do
                local member = group.members[i]
                local resolved, playerOrReason = resolveRoofRepairGroupPlayer(
                    group, member)
                if not resolved then
                    if playerOrReason == "requesting player disconnected or was replaced" then
                        return false, playerOrReason
                    end
                    failRoofRepairRelocationGroup(playerOrReason)
                    return false, playerOrReason
                end
                local sentOk = callGlobalSucceeded("sendServerCommand", playerOrReason,
                    COMMAND_MODULE, COMMAND_RELOCATE, member.returnPayload)
                if not sentOk or not callSucceeded(playerOrReason, "teleportTo",
                    member.target.x, member.target.y, member.target.z) then
                    local failure = "roof repair group return relocation failed"
                    failRoofRepairRelocationGroup(failure)
                    return false, failure
                end
                member.relocationLastSentTick = serverTick
                member.relocationRetryAtTick = serverTick
                    + ROOF_RELOCATION_RETRY_TICKS
                member.relocationNeedsResend = false
            end
            print("[RailroaderRVTest] roof repair group return queued room="
                .. roomKey .. " members=" .. tostring(#group.members)
                .. " target=server-captured-squares")
            return true, returnToken
        end

        if type(request.players) ~= "table" or #request.players < 1 then
            return false, "roof repair group has no authoritative inside players"
        end
        local members = {}
        local seen = {}
        local sharedContext = nil
        for i = 1, #request.players do
            local descriptor = request.players[i]
            local player = type(descriptor) == "table" and descriptor.player or nil
            local identityOk, identityOrReason = playerIdentity(player)
            if not identityOk then return false, identityOrReason end
            if type(descriptor.identityKey) == "string"
                and descriptor.identityKey ~= identityOrReason.key then
                return false, "roof repair group player identity changed"
            end
            if seen[identityOrReason.key] then
                return false, "roof repair group contains duplicate player identity"
            end
            seen[identityOrReason.key] = true
            local contextOk, contextOrReason = currentRoofRepairContext(player,
                { rvId = rvId, generation = generation,
                    bitmapVersion = bitmapVersion,
                    identityKey = identityOrReason.key })
            if not contextOk then return false, contextOrReason end
            sharedContext = sharedContext or contextOrReason
            local exactOk, exactOrReason = roofRepairExactPosition(player)
            if not exactOk then return false, exactOrReason end
            local returnOk, returnPosition = pcall(roofRepairPosition,
                exactOrReason, "group return")
            if not returnOk then return false, Constants.SAVE_REBUILD_REQUIRED end
            if not Bitmap.containsScope(contextOrReason.bitmap,
                returnPosition.x, returnPosition.y, returnPosition.z)
                or not Bitmap.isActive(contextOrReason.bitmap,
                    returnPosition.x, returnPosition.y, returnPosition.z) then
                return false, "roof repair group return position is not current active RV geometry"
            end
            members[#members + 1] = {
                player = player,
                identity = identityOrReason,
                identityKey = identityOrReason.key,
                roomKey = roomKey,
                rvId = rvId,
                generation = generation,
                bitmapVersion = bitmapVersion,
                originalPosition = exactOrReason,
                returnPosition = returnPosition,
                acknowledged = false,
                arrived = false,
                arrivalConsumed = false,
                finalReturned = false,
                relocationNeedsResend = false,
                relocationRetryAtTick = serverTick,
                relocationLastSentTick = nil,
                -- Keep the repair bit present from the first in-memory member
                -- record so completion is explicit and idempotent.
                repairCompleted = false,
            }
            print("[RailroaderRVTest] roof repair group member captured room="
                .. roomKey .. " player=" .. tostring(identityOrReason.key)
                .. " original=" .. tostring(exactOrReason.x) .. ","
                .. tostring(exactOrReason.y) .. ","
                .. tostring(exactOrReason.z))
        end
        if not sharedContext then
            return false, Constants.SAVE_REBUILD_REQUIRED
        end
        local destinationOk, destinationOrReason = roofRepairDestination(
            sharedContext, { phase = "temporary" })
        if not destinationOk then return false, destinationOrReason end
        local destination = destinationOrReason
        local worldOk, worldReason = roofRepairWorldCoordinateValid(destination)
        if not worldOk then return false, worldReason end

        roofRepairGroupSerial = roofRepairGroupSerial + 1
        local token = "roof-repair-group:" .. rvId .. ":"
            .. tostring(generation) .. ":" .. tostring(serverTick) .. ":"
            .. tostring(roofRepairGroupSerial)
        local group = {
            roomKey = roomKey, rvId = rvId, generation = generation,
            bitmapVersion = bitmapVersion, phase = "temporary", token = token,
            target = copyRoofRepairPosition(destination), members = members,
            allowedPlayers = {},
            startedAt = os.time(),
            queuedAtTick = serverTick,
            deadlineTick = serverTick + RELOCATION_TIMEOUT_TICKS,
            disconnectStartedTick = nil,
        }
        roofRepairRelocationGroup = group
        roofRepairGroupFailure = nil
        for i = 1, #members do
            local member = members[i]
            member.token = token
            group.allowedPlayers[member.player] = true
            local beginCallOk, armed = false, false
            if Boundary and type(Boundary.beginTransition) == "function" then
                beginCallOk, armed = pcall(Boundary.beginTransition,
                    member.player, rvId, generation, token,
                    "roof-repair-group", bitmapVersion)
            end
            if not beginCallOk or armed ~= true then
                local failure = "roof repair group boundary transition could not be armed"
                failRoofRepairRelocationGroup(failure)
                return false, failure
            end
        end
        for i = 1, #members do
            local member = members[i]
            local payload = {
                token = token, onlineId = member.identity.onlineId,
                rvId = rvId, generation = generation,
                bitmapVersion = bitmapVersion,
                x = group.target.x, y = group.target.y, z = group.target.z,
                roofRepairTransition = true, roofRepairPhase = "temporary",
            }
            local sentOk = callGlobalSucceeded("sendServerCommand", member.player,
                COMMAND_MODULE, COMMAND_RELOCATE, payload)
            if not sentOk or not callSucceeded(member.player, "teleportTo",
                group.target.x + 0.5, group.target.y + 0.5, group.target.z) then
                local failure = "roof repair group temporary relocation failed"
                failRoofRepairRelocationGroup(failure)
                return false, failure
            end
            member.relocationLastSentTick = serverTick
            member.relocationRetryAtTick = serverTick
                + ROOF_RELOCATION_RETRY_TICKS
            member.relocationNeedsResend = false
        end
        print("[RailroaderRVTest] roof repair group relocation queued room="
            .. roomKey .. " members=" .. tostring(#members) .. " target="
            .. tostring(group.target.x) .. "," .. tostring(group.target.y)
            .. "," .. tostring(group.target.z)
            .. " targetKind=rv-center-minus-offset")
        return true, token
    end)
    if not callOk then return false, safeErrorText(result) end
    return result, reason
end

local function keepRoofRepairFinalReturnAlive(member)
    if type(member) ~= "table" or type(member.token) ~= "string"
        or not Boundary then return end
    local resolved, playerOrReason = resolvePendingPlayer(member)
    if not resolved then return end
    member.player = playerOrReason
    local livePlayer = playerOrReason
    local keepUntil = serverTick + RELOCATION_POST_ACK_TICKS + 2
    if type(Boundary.extendTransition) == "function" then
        local extendCallOk, extended = pcall(Boundary.extendTransition,
            livePlayer, member.token, keepUntil)
        if extendCallOk and extended == true then return end
    end
    -- If the live lease expired while the same process was waiting, re-arm only
    -- this exact in-memory token and stable identity; no guessed player is used.
    if type(Boundary.beginTransition) == "function" then
        local beginCallOk, armed = pcall(Boundary.beginTransition, livePlayer,
            member.rvId, member.generation, member.token, "roof-repair-return",
            member.bitmapVersion)
        if armed == true and type(Boundary.extendTransition) == "function" then
            pcall(Boundary.extendTransition, livePlayer, member.token, keepUntil)
            print("[RailroaderRVTest] roof repair return lease re-armed identity="
                .. tostring(member.identityKey))
        end
    end
end

-- A reconnect drops the client's in-flight relocation state.  Re-send only
-- the current grouped phase for the same member/token, at a bounded cadence;
-- this is process-local and never creates a second roof transaction.
local function resendRoofRepairMemberPhase(group, member)
    if type(group) ~= "table" or type(member) ~= "table"
        or not member.player or type(member.token) ~= "string"
        or member.token == "" then
        return false
    end
    -- An already observed arrival is still owned by the grouped transaction,
    -- but it no longer needs a relocation packet.  In particular, a reconnect
    -- between the arrival ACK and the adapter's consume call must not reset
    -- that barrier and make the group wait for a packet the client no longer
    -- owns.
    if member.arrived == true or member.completed == true then
        member.relocationNeedsResend = false
        return false
    end
    local payload, target, exactReturn
    if group.phase == "temporary" then
        target = group.target
        payload = {
            token = member.token,
            onlineId = member.identity and member.identity.onlineId,
            rvId = member.rvId, generation = member.generation,
            bitmapVersion = member.bitmapVersion,
            x = target and target.x, y = target and target.y,
            z = target and target.z,
            roofRepairTransition = true, roofRepairPhase = "temporary",
        }
        exactReturn = false
    elseif group.phase == "return" then
        payload = member.returnPayload
        target = member.target
        exactReturn = true
    else
        return false
    end
    if type(payload) ~= "table" or type(target) ~= "table"
        or type(target.x) ~= "number" or type(target.y) ~= "number"
        or type(target.z) ~= "number" then
        return false
    end
    local sentOk = callGlobalSucceeded("sendServerCommand", member.player,
        COMMAND_MODULE, COMMAND_RELOCATE, payload)
    local teleportX = exactReturn and target.x or target.x + 0.5
    local teleportY = exactReturn and target.y or target.y + 0.5
    local moved = callSucceeded(member.player, "teleportTo", teleportX,
        teleportY, target.z)
    if not sentOk or not moved then return false end
    member.relocationNeedsResend = false
    member.relocationRetryAtTick = serverTick
    member.relocationLastSentTick = serverTick
    member.acknowledged = false
    member.acknowledgedAtTick = nil
    member.arrived = false
    member.arrivalConsumed = false
    member.completed = false
    return true
end

local function keepRoofRepairTransitionAlive()
    if roofRepairGroupFinalReturn and roofRepairGroupFinalReturn.group then
        local group = roofRepairGroupFinalReturn.group
        for i = 1, #(group.members or {}) do
            local member = group.members[i]
            if not member.finalReturned then
                keepRoofRepairFinalReturnAlive(member)
            end
        end
    end
    local group = roofRepairRelocationGroup
    if group then
        local disconnected = false
        for i = 1, #(group.members or {}) do
            local resolved, reason = resolveRoofRepairGroupPlayer(group,
                group.members[i])
            if not resolved then
                if reason == "requesting player disconnected or was replaced" then
                    disconnected = true
                end
            end
        end
        if disconnected then
            -- Do not spend the timeout while an authoritative player object is
            -- absent; the group remains owned until reconnect.  The deadline
            -- is shifted only when all identities have rebound, preserving the
            -- same token and one transaction.
            if group.disconnectStartedTick == nil then
                group.disconnectStartedTick = serverTick
            end
            return true
        end
        if group.disconnectStartedTick ~= nil then
            local paused = serverTick - group.disconnectStartedTick
            if paused > 0 then
                group.queuedAtTick = (group.queuedAtTick or serverTick) + paused
                group.deadlineTick = (group.deadlineTick or serverTick) + paused
            end
            group.disconnectStartedTick = nil
            for i = 1, #(group.members or {}) do
                local member = group.members[i]
                if not member.arrived and not member.completed then
                    member.relocationNeedsResend = true
                    member.relocationRetryAtTick = serverTick
                end
            end
        end
        if serverTick > (group.deadlineTick or serverTick) then
            failRoofRepairRelocationGroup("roof repair group relocation transaction timed out")
            return false
        end
        if not Boundary or type(Boundary.extendTransition) ~= "function" then
            failRoofRepairRelocationGroup("roof repair group boundary lease service is unavailable")
            return false
        end
        for i = 1, #(group.members or {}) do
            local member = group.members[i]
            if not member.completed then
                local resolved, livePlayer = resolveRoofRepairGroupPlayer(
                    group, member)
                if not resolved then return true end
                member.player = livePlayer
                local extendCallOk, extended = pcall(
                    Boundary.extendTransition, member.player, member.token,
                    math.min(group.deadlineTick,
                        serverTick + RELOCATION_POST_ACK_TICKS + 2))
                if not extendCallOk or extended ~= true then
                    keepRoofRepairFinalReturnAlive(member)
                    local retryOk, retryLive = resolveRoofRepairGroupPlayer(
                        group, member)
                    if not retryOk or not retryLive then return true end
                    local recheckOk, rechecked = pcall(Boundary.extendTransition,
                        retryLive, member.token,
                        math.min(group.deadlineTick,
                            serverTick + RELOCATION_POST_ACK_TICKS + 2))
                    if not recheckOk or rechecked ~= true then
                        failRoofRepairRelocationGroup(
                            "roof repair group boundary transition expired")
                        return false
                    end
                end
            end
        end
        for i = 1, #(group.members or {}) do
            local member = group.members[i]
            if member.arrived or member.completed then
                member.relocationNeedsResend = false
            elseif member.relocationNeedsResend
                and serverTick >= (member.relocationRetryAtTick or 0) then
                local resent = resendRoofRepairMemberPhase(group, member)
                member.relocationRetryAtTick = serverTick
                    + ROOF_RELOCATION_RETRY_TICKS
                if not resent then
                    -- Keep the same transaction alive and retry at the bounded
                    -- cadence; processRoofRepairRelocationGroup remains the
                    -- authoritative failure/timeout path.
                    member.relocationNeedsResend = true
                end
            end
        end
    end
    return true
end

function RV.Server.consumeRoofRepairRelocationArrival(player)
    local member = roofRepairGroupMember(roofRepairRelocationGroup, player)
    if not member or not member.arrived or member.arrivalConsumed then
        return nil
    end
    local resolved, current = resolveRoofRepairGroupPlayer(
        roofRepairRelocationGroup, member)
    if not resolved then return nil end
    member.arrivalConsumed = true
    return member
end

function RV.Server.roofRepairRelocationGroupReady(rvId, generation,
    bitmapVersion)
    local group = roofRepairRelocationGroup
    return roofRepairGroupMatches(group, rvId, generation, bitmapVersion)
        and group.phase == "temporary"
        and roofRepairGroupAll(group, "arrived", true)
end

-- Cross-module mutex queries.  These expose only live process state; no
-- relocation ledger or save field is involved.  A roof group remains busy
-- through temporary, return, repair and its final-return retry object so the
-- adapter cannot mutate the same RV while its captured members are returning.
function RV.Server.isGenerationTransactionActive()
    return pendingGeneration ~= nil or transactionBusy
end

function RV.Server.isRoofRepairTransactionActive(_rvId)
    -- This is a service-wide mutex query.  The optional rvId is retained in
    -- the signature for callers that want to keep their diagnostic context,
    -- but an active roof transaction must never be bypassed by naming another
    -- RV in the same managed world scope.
    local function busyGroup(group)
        if group == nil then return false end
        if type(group) ~= "table" then
            return true, "roof repair transaction state is unavailable"
        end
        if type(group.rvId) ~= "string" or group.rvId == "" then
            return true, "roof repair transaction state is unavailable"
        end
        return true, "roof repair refresh is in progress (rvId="
            .. tostring(group.rvId) .. ")"
    end
    local active, reason = busyGroup(roofRepairRelocationGroup)
    if active then return true, reason end
    if roofRepairGroupFinalReturn ~= nil
        and type(roofRepairGroupFinalReturn) ~= "table" then
        return true, "roof repair transaction state is unavailable"
    end
    local finalReturn = roofRepairGroupFinalReturn
        and roofRepairGroupFinalReturn.group or nil
    if roofRepairGroupFinalReturn ~= nil and type(finalReturn) ~= "table" then
        return true, "roof repair transaction state is unavailable"
    end
    active, reason = busyGroup(finalReturn)
    if active then return true, reason end
    return false
end

-- The stateless z=-15 sentinel must never race a transaction that this live
-- process still owns.  Claims are keyed only by the stable onlineID+username
-- identity and exist in memory for the lifetime of the transaction.
function RV.Server.isRelocationIdentityClaimed(identityKey)
    if type(identityKey) ~= "string" or identityKey == "" then
        return false
    end
    local function groupClaims(group)
        if group == nil then return false end
        if type(group) ~= "table" or type(group.members) ~= "table"
            or #group.members < 1 then
            return nil
        end
        for i = 1, #(group and group.members or {}) do
            local member = group.members[i]
            if type(member) ~= "table" or type(member.identityKey) ~= "string"
                or member.identityKey == "" then
                return nil
            end
            if member.identityKey == identityKey
                or type(member.identity) == "table"
                and member.identity.key == identityKey then
                return true
            end
        end
        return false
    end
    if pendingGeneration ~= nil then
        if type(pendingGeneration) ~= "table"
            or type(pendingGeneration.identity) ~= "table"
            or type(pendingGeneration.identity.key) ~= "string"
            or pendingGeneration.identity.key == "" then
            return nil
        end
        return pendingGeneration.identity.key == identityKey
    end
    local activeClaims = groupClaims(roofRepairRelocationGroup)
    if activeClaims ~= false then return activeClaims end
    if roofRepairGroupFinalReturn ~= nil
        and (type(roofRepairGroupFinalReturn) ~= "table"
            or type(roofRepairGroupFinalReturn.group) ~= "table") then
        return nil
    end
    local finalGroup = roofRepairGroupFinalReturn
        and roofRepairGroupFinalReturn.group or nil
    local finalClaims = groupClaims(finalGroup)
    if finalClaims ~= false then return finalClaims end
    return false
end

function RV.Server.getRoofRepairRelocationState(rvId, generation,
    bitmapVersion, token)
    if roofRepairGroupMatches(roofRepairRelocationGroup, rvId, generation,
        bitmapVersion) then
        return "active", roofRepairRelocationGroup.phase
    end
    if roofRepairGroupFailure
        and roofRepairGroupMatches(roofRepairGroupFailure, rvId, generation,
            bitmapVersion)
        and type(token) == "string"
        and token ~= ""
        and roofRepairGroupFailure.token == token then
        return "failed", roofRepairGroupFailure.reason
    end
    return "idle"
end

function RV.Server.consumeRoofRepairRelocationFailure(rvId, generation,
    bitmapVersion, token)
    if roofRepairGroupFailure
        and roofRepairGroupMatches(roofRepairGroupFailure, rvId, generation,
            bitmapVersion)
        and type(token) == "string"
        and token ~= ""
        and roofRepairGroupFailure.token == token then
        local failure = roofRepairGroupFailure
        roofRepairGroupFailure = nil
        return failure.reason
    end
    return nil
end

function RV.Server.completeRoofRepairRelocation(player, token)
    if roofRepairRelocationGroup then
        local group = roofRepairRelocationGroup
        local member = roofRepairGroupMember(group, player, token)
        if not member or group.phase ~= "return" then
            return false, "roof repair group return acknowledgement is stale"
        end
        local resolved, livePlayerOrReason = resolveRoofRepairGroupPlayer(
            group, member)
        if not resolved then
            return false, livePlayerOrReason
        end
        local livePlayer = livePlayerOrReason
        local identityOk, identityOrReason = playerIdentity(livePlayer)
        if not identityOk or identityOrReason.key ~= member.identityKey then
            return false, identityOk and "roof repair group return identity changed"
                or identityOrReason
        end
        local contextOk, contextOrReason = currentRoofRepairContext(livePlayer,
            { rvId = member.rvId, generation = member.generation,
                bitmapVersion = member.bitmapVersion,
                identityKey = member.identityKey })
        if not contextOk then return false, contextOrReason end
        local atTarget, targetReason = playerAtRoofRepairDestination(livePlayer,
            member.target)
        if not atTarget then return false, targetReason end
        local authoritativeOk, authoritativePosition =
            authoritativePlayerPosition(livePlayer)
        if not authoritativeOk then return false, authoritativePosition end
        if authoritativePosition.z == ROOF_REPAIR_TEMP_Z
            or authoritativePosition.x ~= member.target.x
            or authoritativePosition.y ~= member.target.y
            or authoritativePosition.z ~= member.target.z then
            member.completed = false
            member.arrived = false
            member.arrivalConsumed = false
            return false, "roof repair group player has not reached captured return position"
        end
        if not member.completed then
            if Boundary and type(Boundary.completeTransition) == "function"
                and Boundary.completeTransition(livePlayer, token) ~= true then
                return false, "roof repair group boundary transition could not be completed"
            end
            member.completed = true
        end
        if roofRepairGroupAll(group, "completed", true)
            and not group.returnLogged then
            group.returnLogged = true
            print("[RailroaderRVTest] roof repair group relocation returned room="
                .. tostring(group.roomKey or "unknown") .. " members="
                .. tostring(#group.members) .. " repair=pending")
        end
        return true, contextOrReason
    end
    return false, "roof repair return acknowledgement is stale"
end

-- Mark one existing-entry roof repair complete after every grouped member has
-- already returned to its captured coordinate. The per-member repair bit stays
-- in the in-memory group until this idempotent completion call.
function RV.Server.completeRoofRepairRepair(player, token)
    local group = roofRepairRelocationGroup
    if not group or group.phase ~= "return" then
        return false, "roof repair group repair acknowledgement is stale"
    end
    local member = roofRepairGroupMember(group, player, token)
    if not member or member.completed ~= true then
        return false, "roof repair group member has not completed return"
    end
    if not roofRepairGroupAll(group, "completed", true) then
        return false, "roof repair group return is not complete for every member"
    end
    local resolved, livePlayerOrReason = resolveRoofRepairGroupPlayer(
        group, member)
    if not resolved then return false, livePlayerOrReason end
    local representativeReason
    for i = 1, #group.members do
        local groupMember = group.members[i]
        local memberResolved, livePlayer = resolveRoofRepairGroupPlayer(
            group, groupMember)
        if not memberResolved then return false, livePlayer end
        local contextOk, contextOrReason = currentRoofRepairContext(livePlayer, {
            rvId = groupMember.rvId, generation = groupMember.generation,
            bitmapVersion = groupMember.bitmapVersion,
            identityKey = groupMember.identityKey,
        })
        if not contextOk then return false, contextOrReason end
        local positionOk, position = authoritativePlayerPosition(livePlayer)
        if not positionOk or not relocationPositionsEqual(position,
            groupMember.originalPosition) then
            return false, "roof repair member return coordinate is not authoritative"
        end
        representativeReason = representativeReason or contextOrReason
    end
    if not roofRepairGroupAll(group, "repairCompleted", true) then
        for i = 1, #group.members do
            group.members[i].repairCompleted = true
        end
    end
    roofRepairRelocationGroup = nil
    print("[RailroaderRVTest] roof repair group transaction complete room="
        .. tostring(group.roomKey or "unknown") .. " members="
        .. tostring(#group.members) .. " repair=applied return=acknowledged")
    return true, representativeReason
end

function RV.Server.cancelRoofRepairRelocation(reason)
    if roofRepairRelocationGroup then
        failRoofRepairRelocationGroup(reason or "roof repair group relocation cancelled")
        return true
    end
    return false, "no roof repair group relocation is active"
end

-- Public read-only readiness gate used by the Railroader adapter immediately
-- before each RoofRepair.run call.  It validates current mapping identity again
-- and then checks every wall/roof/candidate square without mutating the world.
function RV.Server.roofRepairSquaresLoaded(player, record)
    if not RoofRepair or type(RoofRepair.isLoaded) ~= "function" then
        return false, "roof repair readiness service is unavailable"
    end
    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local manifest = manifestOrError
    local schemaOk = pcall(requireCurrentManifest, manifest, false)
    if not schemaOk then return false, Constants.SAVE_REBUILD_REQUIRED end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then return false, identityOrReason end
    local contextOk, contextOrReason = currentRoofRepairContext(player,
        { rvId = manifest.rvId, generation = manifest.generation,
            bitmapVersion = manifest.bitmapVersion,
            identityKey = identityOrReason.key })
    if not contextOk then return false, contextOrReason end
    if type(record) == "table"
        and (tostring(record.rvId) ~= tostring(contextOrReason.boundary.rvId)
            or integer(record.generation) ~= contextOrReason.boundary.generation
            or integer(record.bitmapVersion)
                ~= contextOrReason.boundary.bitmapVersion) then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local loadedOk, loaded, reason = pcall(RoofRepair.isLoaded, player,
        manifest.bounds)
    if not loadedOk then return false, safeErrorText(loaded) end
    return loaded == true, reason
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
-- client never sends coordinates and completion uses a separate token-only ACK.
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
            rvId = tostring(prepared.rvId),
            bitmapVersion = requiredInteger(prepared.boundary
                and prepared.boundary.bitmapVersion,
                "final relocation bitmapVersion"),
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
    local sentOk = callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_FINAL_RELOCATE, finalPayload)
    if not sentOk then
        error("RailroaderRVTest: final server-to-client relocation command failed")
    end
    if not callSucceeded(player, "teleportTo", x, y, z) then
        error("RailroaderRVTest: final authoritative server relocation failed")
    end
    -- Do not advance the manifest here. The client must complete its guard/
    -- room scan and prove the exact target with the token-only final ACK; the
    -- in-memory transaction owns the deadline and rollback.
    prepared.finalRelocationSent = true
    prepared.finalRelocationAcked = false
    prepared.finalRelocationAckAtTick = nil
    prepared.finalRelocationDeadlineTick = serverTick + RELOCATION_TIMEOUT_TICKS
    prepared.finalDestination = {
        x = x, y = y, z = z,
    }
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
        if Boundary and type(Boundary.clearPlayer) == "function" then
            Boundary.clearPlayer(player)
        end
        transactionBusy = false
        transactionPlayer = nil
        return false, safeErrorText(manifestOrError)
    end
    manifest = manifestOrError
    local schemaOk, schemaError = pcall(requireCurrentManifest, manifest, true)
    if not schemaOk then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            Boundary.clearPlayer(player)
        end
        transactionBusy = false
        transactionPlayer = nil
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    if manifest.state == "RUNNING" then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            Boundary.clearPlayer(player)
        end
        transactionBusy = false
        transactionPlayer = nil
        return false, "generation already in progress"
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
        local oldBounds = prepared.oldBounds
        local atStaging, stagingReason = playerIsAtStagingDestination(player,
            prepared.stagingDestination, bounds, oldBounds)
        if not atStaging then
            error(stagingReason)
        end
        -- No object/system mutation is allowed before this complete loaded
        -- region check.  In particular, an old generation is not removed
        -- until the new half-open 100x100 bitmap/base/wall/roof contract is ready.
        preflightLoaded(cell, bounds)
        local generation = (manifest.generation == nil and 1
            or requiredInteger(manifest.generation, "manifest generation") + 1)
        if not Boundary then
            error("RailroaderRVTest: RV boundary service is unavailable")
        end
        local rvId = prepared.railroader and prepared.railroader.locoId
            or ("technical:" .. tostring(anchor.x) .. ":" .. tostring(anchor.y))
        local boundaryOk, boundaryOrReason = pcall(Boundary.makeBoundary,
            layout, rvId, generation)
        if not boundaryOk or type(boundaryOrReason) ~= "table" then
            error(boundaryOk and "RailroaderRVTest: boundary manifest is unavailable"
                or safeErrorText(boundaryOrReason))
        end
        prepared.rvId = tostring(rvId)
        prepared.boundary = boundaryOrReason
        -- Arm every connected client before any old wall or roof is removed.
        -- Reliable packet order installs the guard before the following world
        -- deltas; the requester remains at the validated staging square,
        -- outside both old and new structure footprints, while later client
        -- ticks repair any missed retired room ID.
        armClientRoomOwnershipGuard(generation, oldBounds, bounds,
            prepared.rvId, boundaryOrReason.bitmapVersion)
        local roomOwnershipGuard = registerServerRoomOwnershipGuard(generation,
            player, oldBounds, bounds, prepared.rvId,
            boundaryOrReason.bitmapVersion)
        -- Remove only objects owned by a prior generation before taking the
        -- new generation lock in persistent state.
        removeOldGeneration(cell, manifest)
        refreshServerRoomOwnershipGuard(roomOwnershipGuard, "after-remove")
        manifest.schemaVersion = Constants.MANIFEST_SCHEMA_VERSION
        manifest.techVersion = Constants.TECH_VERSION
        manifest.generation = generation
        manifest.owner = OWNER
        manifest.anchor = { x = anchor.x, y = anchor.y, z = anchor.z }
        manifest.bounds = bounds
        manifest.rvId = prepared.rvId
        manifest.boundarySchemaVersion = boundaryOrReason.schemaVersion
        manifest.bitmapVersion = boundaryOrReason.bitmapVersion
        manifest.boundary = boundaryOrReason
        manifest.startedAt = os.time()
        manifest.rollback = nil
        manifest.completedAt = nil
        manifest.lastError = nil
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
            end
            if buildOk then
                setGenerationPhase(manifest, generation, "FINAL_RELOCATE")
                local finalRelocationOk, finalRelocationError = pcall(
                    relocatePlayerIntoHouse, player, prepared)
                if not finalRelocationOk then
                    buildOk = false
                    buildError = finalRelocationError
                else
                    prepared.manifest = manifest
                    prepared.generationCell = cell
                    prepared.generationRoomOwnershipGuard = roomOwnershipGuard
                    prepared.generationNumber = generation
                    -- Keep the process-local transaction alive across the
                    -- asynchronous client readiness proof. The continuation
                    -- below is the only path that can commit READY.
                    return "await-final-relocate"
                end
            end
        end
        if not buildOk then
            -- The lamp is intentionally last, but any phase can fail.  Remove
            -- every object tagged by this generation before exposing FAILED;
            -- otherwise a failed lamp/API call would leave a powered
            -- generator, full barrel or roof as a half-built cabin.
            local rollbackOk, rollbackError = pcall(function()
                removeGeneration(cell, bounds, generation, manifest.rvId,
                    manifest.bitmapVersion)
            end)
            if rollbackOk then
                manifest.rollback = "COMPLETE"
                manifest.phase = "ROLLED_BACK"
                print("[RailroaderRVTest] generation=" .. tostring(generation)
                    .. " rollback=COMPLETE")
            else
                manifest.rollback = "FAILED"
                print("[RailroaderRVTest] generation=" .. tostring(generation)
                    .. " rollback=FAILED: " .. safeErrorText(rollbackError))
                error(safeErrorText(buildError) .. " (rollback failed: "
                    .. safeErrorText(rollbackError) .. ")")
            end
            error(buildError)
        end
        error("RailroaderRVTest: generation did not enter final relocation")
    end)
    return finalizeGeneration(manifest, ok, resultOrError)
end

-- Continue generation only after the client has sent the strict
-- FinalRelocateAck.  This function is intentionally separate from the build
-- body: a client readiness failure can never fall through to READY, and the
-- in-memory transaction remains the idempotent retry owner.
local function finalizeGenerationAfterRelocate(player, prepared)
    if type(prepared) ~= "table"
        or prepared.finalRelocationSent ~= true
        or prepared.finalRelocationAcked ~= true then
        return false, "final relocation acknowledgement is still pending"
    end
    local ok, result = pcall(function()
        local positionOk, position = authoritativePlayerPosition(player)
        if not positionOk or not relocationPositionsEqual(position,
            prepared.finalDestination) then
            error("final relocation authoritative target proof failed")
        end
        local manifest = prepared.manifest
        if type(manifest) ~= "table" then manifest = manifestTable() end
        local schemaOk = pcall(requireCurrentManifest, manifest, false)
        if not schemaOk or manifest.state ~= "RUNNING"
            or manifest.phase ~= "FINAL_RELOCATE"
            or tostring(manifest.rvId) ~= tostring(prepared.rvId)
            or integer(manifest.generation) ~= prepared.generation
            or integer(manifest.bitmapVersion) ~= prepared.bitmapVersion then
            error(Constants.SAVE_REBUILD_REQUIRED)
        end
        local anchor = manifest.anchor
        local anchorX = requiredInteger(anchor.x, "final manifest anchor x")
        local anchorY = requiredInteger(anchor.y, "final manifest anchor y")
        local anchorZ = requiredInteger(anchor.z, "final manifest anchor z")
        if prepared.finalDestination.x ~= anchorX + 0.5
            or prepared.finalDestination.y ~= anchorY + 0.5
            or prepared.finalDestination.z ~= anchorZ then
            error(Constants.SAVE_REBUILD_REQUIRED)
        end
        local guard = prepared.generationRoomOwnershipGuard
        if guard then
            refreshServerRoomOwnershipGuard(guard, "before-commit")
        end
        if prepared.railroader ~= nil and not railroaderCommitHook then
            error("Railroader RV commit hook is unavailable")
        end
        if prepared.railroader ~= nil and not prepared.commitApplied then
            local commitOk, commitResult, commitReason = pcall(
                railroaderCommitHook, player, prepared.railroader, prepared)
            if not commitOk then error(commitResult) end
            if commitResult ~= true then
                error(commitReason or "Railroader RV mapping commit failed")
            end
            prepared.commitApplied = true
        end
        if not Boundary or type(Boundary.completeTransition) ~= "function"
            or Boundary.completeTransition(player, prepared.token) ~= true then
            error("generation boundary transition could not be completed")
        end
        setGenerationPhase(manifest, prepared.generation, "COMMITTED")
        manifest.completedAt = os.time()
        setManifestState(manifest, "READY")
        if guard then refreshServerRoomOwnershipGuard(guard, "after-commit") end
        local readySchemaOk = pcall(requireCurrentManifest, manifest, false)
        if not readySchemaOk or manifest.state ~= "READY"
            or manifest.phase ~= "COMMITTED" then
            error(Constants.SAVE_REBUILD_REQUIRED)
        end
        prepared.finalizationReady = true
    end)
    if not ok then
        return false, safeErrorText(result)
    end
    transactionBusy = false
    transactionPlayer = nil
    return true
end

local function queueGeneration(player, authoritativePosition, railroaderData)
    if pendingGeneration ~= nil or transactionBusy then
        return false, "generation already queued or in progress"
    end
    -- Generation and roof refresh both mutate the current managed scope and
    -- stream the same world region.  The roof group owns the service-wide
    -- mutex until its active/repair/final-return state has fully retired.
    if roofRepairRelocationGroup ~= nil
        or roofRepairGroupFinalReturn ~= nil then
        return false, "roof repair refresh is in progress"
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then
        return false, identityOrReason
    end
    local positionOk, originalPosition = authoritativePlayerPosition(player)
    if not positionOk then
        return false, originalPosition
    end

    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        return false, safeErrorText(manifestOrError)
    end
    local manifest = manifestOrError
    local schemaOk = pcall(requireCurrentManifest, manifest, true)
    if not schemaOk then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    if manifest.state == "RUNNING" then
        return false, "generation already in progress"
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
        local oldBounds = manifest.generation ~= nil and manifest.bounds or nil
        local stagingDestination = selectGenerationStagingDestination(layout,
            plannedBounds)
        return layout, plannedBounds, destination, finalDestination,
            stagingDestination, oldBounds
    end)
    if not planOk then
        return false, safeErrorText(layoutOrError)
    end

    pendingSerial = pendingSerial + 1
    local token = identityOrReason.key .. ":" .. tostring(serverTick)
        .. ":" .. tostring(pendingSerial)
    local transitionRvId = railroaderData and railroaderData.locoId
        or ("technical:" .. tostring(destination.x) .. ":" .. tostring(destination.y))
    local transitionGeneration = (manifest.generation == nil and 1
        or requiredInteger(manifest.generation, "manifest generation") + 1)
    local transitionBitmapVersion = requiredInteger(
        layoutOrError.bitmap and layoutOrError.bitmap.bitmapVersion,
        "planned generation bitmapVersion")
    pendingGeneration = {
        player = player,
        identity = identityOrReason,
        originalPosition = {
            x = originalPosition.x,
            y = originalPosition.y,
            z = originalPosition.z,
        },
        token = token,
        rvId = tostring(transitionRvId),
        generation = transitionGeneration,
        bitmapVersion = transitionBitmapVersion,
        queuedAtTick = serverTick,
        acknowledged = false,
        relocationPhase = "temporary",
        relocationLastSentTick = nil,
        relocationRetryAtTick = serverTick,
        relocationNeedsResend = false,
        disconnectStartedTick = nil,
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
            purpose = stagingDestination.purpose,
        },
        railroader = railroaderData,
    }
    if type(railroaderData) == "table" then
        -- Keep the complete generation identity on the adapter's asynchronous
        -- failure/commit payload as well as on pendingGeneration itself.
        railroaderData.rvId = tostring(transitionRvId)
        railroaderData.generation = transitionGeneration
        railroaderData.bitmapVersion = transitionBitmapVersion
    end

    if not Boundary or type(Boundary.beginTransition) ~= "function" then
        pendingGeneration = nil
        return false, "RV boundary transition service is unavailable"
    end
    local transitionOk, transitionResult = pcall(Boundary.beginTransition,
        player, transitionRvId, transitionGeneration, token, "generation",
        transitionBitmapVersion)
    if not transitionOk or transitionResult ~= true then
        pendingGeneration = nil
        return false, "RV boundary transition could not be armed"
    end

    -- GameServer.sendTeleport is not exposed to B42.20 Lua.  The targeted
    -- server command performs the client half of relocation; teleportTo is
    -- also applied to the authoritative server object.  The acknowledgement
    -- carries only an opaque token and cannot supply a trusted destination.
    local relocatePayload = {
        token = token,
        onlineId = identityOrReason.onlineId,
        rvId = tostring(transitionRvId),
        generation = transitionGeneration,
        bitmapVersion = transitionBitmapVersion,
        x = stagingDestination.x,
        y = stagingDestination.y,
        z = stagingDestination.z,
        generationTransition = true,
        generationPhase = "temporary",
    }
    -- Re-assert the complete generation identity after constructing the
    -- asynchronous payload.  The marker below is only valid with this exact
    -- RV/generation/bitmap snapshot; keep these assignments explicit so no
    -- later payload extension can silently drop or replace one token.
    relocatePayload.rvId = tostring(transitionRvId)
    relocatePayload.generation = transitionGeneration
    relocatePayload.bitmapVersion = transitionBitmapVersion
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
    local sentOk = callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,
        COMMAND_RELOCATE, relocatePayload)
    if not sentOk then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            pcall(Boundary.clearPlayer, player)
        end
        pendingGeneration = nil
        return false, "server-to-client relocation command failed"
    end
    if not callSucceeded(player, "teleportTo", stagingDestination.x + 0.5,
        stagingDestination.y + 0.5, stagingDestination.z) then
        if Boundary and type(Boundary.clearPlayer) == "function" then
            pcall(Boundary.clearPlayer, player)
        end
        pendingGeneration = nil
        return false, "authoritative server relocation failed"
    end
    pendingGeneration.relocationLastSentTick = serverTick
    pendingGeneration.relocationRetryAtTick = serverTick
    print("[RailroaderRVTest] generation queued after relocation player="
        .. identityOrReason.key .. " staging=" .. tostring(stagingDestination.x)
        .. "," .. tostring(stagingDestination.y) .. ","
        .. tostring(stagingDestination.z) .. " anchor=" .. tostring(destination.x)
        .. "," .. tostring(destination.y) .. "," .. tostring(destination.z))
    return true
end

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

-- Read-only current-schema gate for the stateless -15 sentinel.  It returns
-- the manifest only after the same strict validator used by normal entry has
-- checked the persisted boundary/bitmap contract; it never repairs or writes.
function RV.Server.currentRVManifestForRelocation(rvId, generation,
    bitmapVersion)
    local manifestOk, manifest = pcall(manifestTable)
    if not manifestOk or type(manifest) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local schemaOk = pcall(requireCurrentManifest, manifest, false)
    if not schemaOk or manifest.state ~= "READY"
        or tostring(manifest.rvId) ~= tostring(rvId)
        or integer(manifest.generation) ~= integer(generation)
        or integer(manifest.bitmapVersion) ~= integer(bitmapVersion)
        or type(manifest.boundary) ~= "table"
        or tostring(manifest.boundary.rvId) ~= tostring(rvId)
        or integer(manifest.boundary.generation) ~= integer(generation)
        or integer(manifest.boundary.bitmapVersion) ~= integer(bitmapVersion) then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    return true, manifest
end

-- BoundaryServer needs the same strict manifest/geometry identity while a
-- generation is still RUNNING (the normal roof/entry guard must not require
-- READY until the final acknowledgement commits it).  This narrow hook keeps
-- that exception explicit and still rejects FAILED/partial/unknown schemas.
function RV.Server.currentRVManifestForBoundary(rvId, generation,
    bitmapVersion)
    local manifestOk, manifest = pcall(manifestTable)
    if not manifestOk or type(manifest) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local schemaOk = pcall(requireCurrentManifest, manifest, false)
    if not schemaOk
        or (manifest.state ~= "RUNNING" and manifest.state ~= "READY")
        or tostring(manifest.rvId) ~= tostring(rvId)
        or integer(manifest.generation) ~= integer(generation)
        or integer(manifest.bitmapVersion) ~= integer(bitmapVersion) then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    return true, manifest
end

-- Cross-object current-geometry gate shared by boundary/roof/sentinel paths.
-- The map record and manifest are independently persisted snapshots, so an
-- identity tuple alone is insufficient: a stale bitmap, bounds, wall ledger,
-- shell edge set, or region must fail closed even when rvId/generation still
-- match.  This helper is read-only apart from registering the validated
-- current boundary snapshot in Boundary's process-local cache.
function RV.Server.currentRVRecordGeometryConsistent(record, manifest)
    local function exactKeys(value, fields)
        if type(value) ~= "table" then return false end
        local allowed = {}
        for i = 1, #fields do allowed[fields[i]] = true end
        for key in pairs(value) do
            if not allowed[key] then return false end
        end
        for i = 1, #fields do
            if value[fields[i]] == nil then return false end
        end
        return true
    end

    local function integerFieldsEqual(left, right, fields)
        if not exactKeys(left, fields) or not exactKeys(right, fields) then
            return false
        end
        for i = 1, #fields do
            if integer(left[fields[i]]) ~= integer(right[fields[i]]) then
                return false
            end
        end
        return true
    end

    local function integerFieldsMatch(left, right, fields)
        if type(left) ~= "table" or type(right) ~= "table" then return false end
        for i = 1, #fields do
            if integer(left[fields[i]]) ~= integer(right[fields[i]]) then
                return false
            end
        end
        return true
    end

    local managedFields = { "originX", "originY", "width", "height",
        "minZ", "maxZ" }
    local boundaryFields = { "schemaVersion", "rvId", "generation",
        "bitmapVersion", "managed", "bitmap", "shellEdges" }
    local shellFields = { "edgeKey", "rvId", "generation", "bitmapVersion",
        "hostX", "hostY", "z", "axis", "side", "objectX", "objectY",
        "objectZ", "role", "corner", "replacementAllowed" }
    local boundsShellFields = { "edgeKey", "hostX", "hostY", "z", "axis",
        "side", "objectX", "objectY", "objectZ", "role", "corner",
        "replacementAllowed" }
    local regionFields = { "minX", "minY", "maxX", "maxY", "minZ", "maxZ" }

    if type(record) ~= "table" or type(manifest) ~= "table"
        or record.generated ~= true
        or record.version ~= nil or manifest.version ~= nil
        or type(record.boundary) ~= "table"
        or type(manifest.boundary) ~= "table"
        or type(manifest.bounds) ~= "table"
        or type(manifest.anchor) ~= "table" then
        return false
    end
    local recordGeneration, manifestGeneration = integer(record.generation),
        integer(manifest.generation)
    local recordBitmapVersion, manifestBitmapVersion = integer(record.bitmapVersion),
        integer(manifest.bitmapVersion)
    if type(record.rvId) ~= "string" or record.rvId == ""
        or tostring(record.locoId) ~= record.rvId
        or tostring(manifest.rvId) ~= record.rvId
        or recordGeneration == nil or recordGeneration < 1
        or recordGeneration ~= manifestGeneration
        or recordBitmapVersion ~= Constants.BITMAP_VERSION
        or manifestBitmapVersion ~= recordBitmapVersion
        or integer(record.schemaVersion) ~= Constants.RV_RECORD_SCHEMA_VERSION
        or integer(record.boundarySchemaVersion) ~= Constants.BOUNDARY_SCHEMA_VERSION
        or integer(manifest.schemaVersion) ~= Constants.MANIFEST_SCHEMA_VERSION
        or manifest.techVersion ~= Constants.TECH_VERSION
        or integer(manifest.boundarySchemaVersion)
            ~= Constants.BOUNDARY_SCHEMA_VERSION
        or integer(record.boundary.schemaVersion)
            ~= Constants.BOUNDARY_SCHEMA_VERSION
        or integer(manifest.boundary.schemaVersion)
            ~= Constants.BOUNDARY_SCHEMA_VERSION
        or tostring(record.boundary.rvId) ~= record.rvId
        or tostring(manifest.boundary.rvId) ~= record.rvId
        or integer(record.boundary.generation) ~= recordGeneration
        or integer(manifest.boundary.generation) ~= recordGeneration
        or integer(record.boundary.bitmapVersion) ~= recordBitmapVersion
        or integer(manifest.boundary.bitmapVersion) ~= recordBitmapVersion
        or not exactKeys(record.boundary, boundaryFields)
        or not exactKeys(manifest.boundary, boundaryFields) then
        return false
    end

    local decoded = {}
    local function decodeCurrent(encoded)
        if not Bitmap or type(Bitmap.decode) ~= "function"
            or type(Bitmap.validate) ~= "function" then
            return nil
        end
        local decodeOk, bitmap = pcall(Bitmap.decode, encoded)
        if not decodeOk or type(bitmap) ~= "table" then return nil end
        local validOk, valid = pcall(Bitmap.validate, bitmap)
        if not validOk or valid ~= true then return nil end
        return bitmap
    end
    decoded.record = decodeCurrent(record.boundary.bitmap)
    decoded.manifest = decodeCurrent(manifest.boundary.bitmap)
    if not decoded.record or not decoded.manifest then return false end

    local function bitmapsEqual(left, right)
        if not integerFieldsMatch(left, right, managedFields)
            or integer(left.bitmapVersion) ~= integer(right.bitmapVersion) then
            return false
        end
        for z = left.minZ, left.maxZ - 1 do
            local leftLayer, rightLayer = Bitmap.layer(left, z),
                Bitmap.layer(right, z)
            if type(leftLayer) ~= "table" or type(rightLayer) ~= "table"
                or leftLayer.walkBits ~= rightLayer.walkBits
                or leftLayer.buildBits ~= rightLayer.buildBits then
                return false
            end
        end
        return true
    end
    local bitmapCompareOk, bitmapSame = pcall(bitmapsEqual, decoded.record,
        decoded.manifest)
    if not bitmapCompareOk or bitmapSame ~= true
        or not integerFieldsEqual(record.boundary.managed,
            manifest.boundary.managed, managedFields)
        or not integerFieldsEqual(record.managed, record.boundary.managed,
            managedFields) then
        return false
    end
    if not integerFieldsMatch(decoded.record, record.boundary.managed,
            managedFields)
        or not integerFieldsMatch(decoded.manifest, manifest.boundary.managed,
            managedFields) then
        return false
    end

    local function shellSetEqual(left, right)
        if type(left) ~= "table" or type(right) ~= "table" then return false end
        local leftCount, rightCount = 0, 0
        for key, edge in pairs(left) do
            leftCount = leftCount + 1
            local other = right[key]
            if type(key) ~= "string" or type(edge) ~= "table"
                or type(other) ~= "table"
                or not exactKeys(edge, shellFields)
                or not exactKeys(other, shellFields) then
                return false
            end
            for i = 1, #shellFields do
                local field = shellFields[i]
                if edge[field] ~= other[field] then return false end
            end
        end
        for _ in pairs(right) do rightCount = rightCount + 1 end
        return leftCount == rightCount
    end
    if not shellSetEqual(record.boundary.shellEdges,
            manifest.boundary.shellEdges) then
        return false
    end

    -- The manifest wall/shell contract is already validated by the strict
    -- current-only validator.  Re-run it here so this public cross-object
    -- hook remains safe when a caller reaches it without first calling the
    -- manifest helper.
    local manifestValidOk, manifestValid = pcall(currentManifestValid,
        manifest, false)
    if not manifestValidOk or manifestValid ~= true then return false end
    -- currentManifestValid also gates this snapshot for normal callers, but
    -- keep the cross-object contract explicit here: bounds.bitmap is a
    -- decoded current-layout bitmap and must be byte/bit identical to the
    -- encoded boundary bitmap and the record copy before any consumer uses
    -- the center, region, or shell geometry.
    local boundsBitmap = manifest.bounds and manifest.bounds.bitmap
    local boundsBitmapOk, boundsBitmapValid = false, false
    if Bitmap and type(Bitmap.validate) == "function" then
        boundsBitmapOk, boundsBitmapValid = pcall(Bitmap.validate, boundsBitmap)
    end
    if not boundsBitmapOk or boundsBitmapValid ~= true
        or not bitmapsEqual(boundsBitmap, decoded.manifest) then
        return false
    end
    local bounds = manifest.bounds
    local boundsShell = bounds.shellEdges
    for key, edge in pairs(record.boundary.shellEdges) do
        local boundEdge = type(boundsShell) == "table" and boundsShell[key]
            or nil
        if type(boundEdge) ~= "table"
            or not exactKeys(boundEdge, boundsShellFields) then
            return false
        end
        for i = 1, #boundsShellFields do
            local field = boundsShellFields[i]
            if edge[field] ~= boundEdge[field] then return false end
        end
    end
    local boundaryCount, boundsCount = 0, 0
    for _ in pairs(record.boundary.shellEdges) do boundaryCount = boundaryCount + 1 end
    for _ in pairs(boundsShell or {}) do boundsCount = boundsCount + 1 end
    if boundaryCount ~= boundsCount then return false end

    local anchor = manifest.anchor
    if not exactKeys(anchor, { "x", "y", "z" })
        or integer(anchor.x) == nil or integer(anchor.y) == nil
        or integer(anchor.z) == nil then
        return false
    end
    local anchorX, anchorY, anchorZ = integer(anchor.x), integer(anchor.y),
        integer(anchor.z)
    local boundsManaged = {
        originX = integer(bounds.managedOriginX),
        originY = integer(bounds.managedOriginY),
        width = integer(bounds.managedWidth),
        height = integer(bounds.managedHeight),
        minZ = integer(bounds.managedMinZ),
        maxZ = integer(bounds.managedMaxZ),
    }
    if not integerFieldsEqual(boundsManaged, record.managed, managedFields)
        or anchorX ~= boundsManaged.originX + math.floor(boundsManaged.width / 2)
        or anchorY ~= boundsManaged.originY + math.floor(boundsManaged.height / 2)
        or anchorZ ~= integer(bounds.z)
        or type(record.rvPosition) ~= "table"
        or not exactKeys(record.rvPosition, { "x", "y", "z" })
        or toNumber(record.rvPosition.x) ~= anchorX + 0.5
        or toNumber(record.rvPosition.y) ~= anchorY + 0.5
        or toNumber(record.rvPosition.z) ~= anchorZ then
        return false
    end

    local regionSize = integer(Constants.RV_REGION_SIZE)
    local regionMinXOffset = integer(Constants.RV_REGION_MIN_OFFSET_X)
    local regionMinYOffset = integer(Constants.RV_REGION_MIN_OFFSET_Y)
    local managedMinZOffset = integer(Constants.RV_MANAGED_MIN_Z_OFFSET)
    local managedMaxZOffset = integer(Constants.RV_MANAGED_MAX_Z_OFFSET)
    if not regionSize or not regionMinXOffset or not regionMinYOffset
        or not managedMinZOffset or not managedMaxZOffset then
        return false
    end
    local expectedRegion = {
        minX = anchorX + regionMinXOffset,
        minY = anchorY + regionMinYOffset,
        maxX = anchorX + regionMinXOffset + regionSize,
        maxY = anchorY + regionMinYOffset + regionSize,
        minZ = anchorZ + managedMinZOffset,
        maxZ = anchorZ + managedMaxZOffset,
    }
    if not integerFieldsEqual(record.region, expectedRegion, regionFields) then
        return false
    end

    if not Boundary or type(Boundary.registerGeneration) ~= "function" then
        return false
    end
    local registerOk, registered = pcall(Boundary.registerGeneration,
        record.rvId, recordGeneration, record.boundary, record)
    return registerOk and registered == true
end

-- Narrow current-only gate for adapter Enter/Exit mutations.  Callers do not
-- supply a manifest snapshot: the service reads the current persisted
-- manifest, requires the READY/COMMITTED contract, and then reuses the full
-- cross-object geometry validator above.  A failed gate has one stable public
-- result so an adapter cannot accidentally continue with a partial snapshot.
function RV.Server.validateCurrentRVRecord(record)
    if type(record) ~= "table" or type(record.rvId) ~= "string"
        or record.rvId == "" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local manifestCallOk, manifestAccepted, manifestOrReason = pcall(
        RV.Server.currentRVManifestForRelocation, record.rvId,
        record.generation, record.bitmapVersion)
    if not manifestCallOk or manifestAccepted ~= true
        or type(manifestOrReason) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local geometryCallOk, consistent = pcall(
        RV.Server.currentRVRecordGeometryConsistent, record, manifestOrReason)
    if not geometryCallOk or consistent ~= true then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    return true, manifestOrReason
end

-- Re-run the official add-floor/remove-floor neighbour invalidation after an
-- existing RV entry or reconnect.  The current manifest gate must pass before
-- any persisted bounds are handed to the repair helper.
function RV.Server.repairRoofVisuals(player)
    if not RoofRepair then
        return false, "roof repair module is unavailable"
    end
    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        return false, safeErrorText(manifestOrError)
    end
    local manifest = manifestOrError
    local schemaOk = pcall(requireCurrentManifest, manifest, false)
    if not schemaOk then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then return false, identityOrReason end
    local contextOk, contextOrReason = currentRoofRepairContext(player, {
        rvId = manifest.rvId,
        generation = manifest.generation,
        bitmapVersion = manifest.bitmapVersion,
        identityKey = identityOrReason.key,
    })
    if not contextOk then return false, contextOrReason end
    local bounds = manifest.bounds
    local ok, result, reason = pcall(RoofRepair.run, player, bounds)
    if not ok then return false, safeErrorText(result) end
    return result == true, reason
end

-- Re-arm a client's persistent stale-room monitor when it enters an already
-- generated RV or appears after reconnect.  The mapping record is checked for
-- the current schema/identity, while the manifest remains the sole source of
-- the bounds sent over the wire.  No client state or persisted legacy geometry
-- participates in this command.
function RV.Server.armCurrentRoomOwnershipMonitor(player, record)
    if type(record) ~= "table" or record.version ~= nil
        or record.generated ~= true
        or record.locoId == nil or tostring(record.locoId) == ""
        or record.rvId == nil or tostring(record.rvId) ~= tostring(record.locoId)
        or type(record.boundary) ~= "table"
        or record.boundary.version ~= nil
        or type(record.boundary.managed) ~= "table"
        or type(record.boundary.bitmap) ~= "table"
        or type(record.boundary.shellEdges) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local recordSchemaVersion = toNumber(record.schemaVersion)
    local recordBoundarySchemaVersion = toNumber(record.boundarySchemaVersion)
    local boundarySchemaVersion = toNumber(record.boundary.schemaVersion)
    if recordSchemaVersion ~= Constants.RV_RECORD_SCHEMA_VERSION
        or recordBoundarySchemaVersion ~= Constants.BOUNDARY_SCHEMA_VERSION
        or boundarySchemaVersion ~= Constants.BOUNDARY_SCHEMA_VERSION then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local recordGeneration = toNumber(record.generation)
    if not isFiniteNumber(recordGeneration) or math.floor(recordGeneration)
        ~= recordGeneration or recordGeneration < 1 then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local recordBitmapVersion = toNumber(record.bitmapVersion)
    local boundaryGeneration = toNumber(record.boundary.generation)
    local boundaryBitmapVersion = toNumber(record.boundary.bitmapVersion)
    if recordBitmapVersion ~= Constants.BITMAP_VERSION
        or tostring(record.boundary.rvId) ~= tostring(record.rvId)
        or boundaryGeneration ~= recordGeneration
        or boundaryBitmapVersion ~= recordBitmapVersion then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end

    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk then return false, identityOrReason end
    local manifestOk, manifestOrError = pcall(manifestTable)
    if not manifestOk or type(manifestOrError) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local manifest = manifestOrError
    local schemaOk = pcall(requireCurrentManifest, manifest, false)
    if not schemaOk then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    if manifest.state ~= "READY" then
        return false, "RV manifest is not READY"
    end
    local manifestGeneration = toNumber(manifest.generation)
    local manifestBitmapVersion = toNumber(manifest.bitmapVersion)
    if tostring(manifest.rvId) ~= tostring(record.rvId)
        or manifestGeneration ~= recordGeneration
        or manifestBitmapVersion ~= recordBitmapVersion
        or tostring(manifest.boundary.rvId) ~= tostring(record.rvId)
        or toNumber(manifest.boundary.generation) ~= recordGeneration
        or toNumber(manifest.boundary.bitmapVersion) ~= recordBitmapVersion then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end

    local armedOk, armedError = pcall(armTargetedClientRoomOwnershipGuard,
        player, recordGeneration, manifest.bounds, record.rvId,
        recordBitmapVersion)
    if not armedOk then
        return false, safeErrorText(armedError)
    end
    print("[RailroaderRVTest] targeted room ownership monitor armed player="
        .. tostring(identityOrReason.key) .. " rvId=" .. tostring(record.rvId)
        .. " generation=" .. tostring(recordGeneration)
        .. " bitmapVersion=" .. tostring(recordBitmapVersion))
    return true
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
    if roofRepairRelocationGroup then
        local token = ackPayloadToken(args)
        local member = token and roofRepairGroupMember(
            roofRepairRelocationGroup, player, token) or nil
        if not member then
            return false, "unexpected or malformed roof repair group acknowledgement"
        end
        local resolved, playerOrReason = resolvePendingPlayer(member)
        if not resolved then
            return false, playerOrReason
        end
        local identityOk, identityOrReason = playerIdentity(player)
        if not identityOk or identityOrReason.key ~= member.identityKey then
            return false, identityOk
                and "acknowledgement sender does not own the group request"
                or identityOrReason
        end
        member.acknowledged = true
        member.acknowledgedAtTick = serverTick
        return true
    end
    local pending = pendingGeneration
    local token = ackPayloadToken(args)
    if pending == nil or token == nil or token ~= pending.token then
        return false, "unexpected or malformed relocation acknowledgement"
    end
    local resolved, playerOrReason = resolvePendingPlayer(pending)
    if not resolved then
        return false, playerOrReason
    end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk or identityOrReason.key ~= pending.identity.key then
        return false, identityOk and "acknowledgement sender does not own the request"
            or identityOrReason
    end
    pending.acknowledged = true
    pending.acknowledgedAtTick = serverTick
    return true
end

-- FinalRelocate has its own ACK namespace.  The payload is deliberately only
-- the opaque token; all RV identity, destination and room/guard evidence is
-- re-read from the server-owned pending plan and current manifest.
local function acknowledgeFinalRelocation(player, args)
    local pending = pendingGeneration
    local token = ackPayloadToken(args)
    if not pending or pending.finalRelocationSent ~= true
        or token == nil or token ~= pending.token then
        return false, "unexpected or malformed final relocation acknowledgement"
    end
    local resolved, livePlayerOrReason = resolvePendingPlayer(pending)
    if not resolved then return false, livePlayerOrReason end
    local identityOk, identityOrReason = playerIdentity(player)
    if not identityOk or identityOrReason.key ~= pending.identity.key then
        return false, identityOk
            and "final acknowledgement sender does not own the request"
            or identityOrReason
    end
    local manifestOk, manifest = pcall(manifestTable)
    if not manifestOk or type(manifest) ~= "table" then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local schemaOk = pcall(requireCurrentManifest, manifest, false)
    if not schemaOk or manifest.state ~= "RUNNING"
        or manifest.phase ~= "FINAL_RELOCATE"
        or tostring(manifest.rvId) ~= tostring(pending.rvId)
        or integer(manifest.generation) ~= pending.generation
        or integer(manifest.bitmapVersion) ~= pending.bitmapVersion then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local anchor = manifest.anchor
    local anchorX = type(anchor) == "table"
        and requiredInteger(anchor.x, "final acknowledgement anchor x") or nil
    local anchorY = type(anchor) == "table"
        and requiredInteger(anchor.y, "final acknowledgement anchor y") or nil
    local anchorZ = type(anchor) == "table"
        and requiredInteger(anchor.z, "final acknowledgement anchor z") or nil
    local target = pending.finalDestination
    if anchorX == nil or anchorY == nil or anchorZ == nil
        or type(target) ~= "table"
        or target.x ~= anchorX + 0.5 or target.y ~= anchorY + 0.5
        or target.z ~= anchorZ then
        return false, Constants.SAVE_REBUILD_REQUIRED
    end
    local stateOk, state = authoritativePlayerPosition(livePlayerOrReason)
    if not stateOk or not relocationPositionsEqual(state, target) then
        return false, "final relocation acknowledgement has no authoritative target proof"
    end
    pending.finalRelocationAcked = true
    pending.finalRelocationAckAtTick = serverTick
    return true
end

local function rollbackPendingGenerationWorld(pending, reason)
    if type(pending) ~= "table"
        or pending.finalRelocationSent ~= true
        or pending.rollbackApplied == true then
        return true
    end
    if serverTick < (pending.rollbackWorldRetryAtTick or 0) then
        return false
    end
    local manifest = pending.manifest
    if type(manifest) ~= "table" then
        local manifestOk, manifestOrReason = pcall(manifestTable)
        if not manifestOk or type(manifestOrReason) ~= "table" then
            print("[RailroaderRVTest] final relocation rollback deferred reason="
                .. safeErrorText(manifestOrReason))
            return false
        end
        manifest = manifestOrReason
    end
    local cell = pending.generationCell
    if not cell then
        local cellOk, cellOrReason = pcall(getCellForPlayer, pending.player)
        if not cellOk or not cellOrReason then
            print("[RailroaderRVTest] final relocation rollback deferred reason="
                .. safeErrorText(cellOrReason))
            return false
        end
        cell = cellOrReason
    end
    local rollbackOk, rollbackReason = pcall(removeGeneration, cell,
        pending.bounds, pending.generation, pending.rvId,
        pending.bitmapVersion)
    if not rollbackOk then
        manifest.rollback = "FAILED"
        pending.rollbackWorldRetryAtTick = serverTick
            + GENERATION_RELOCATION_RETRY_TICKS
        print("[RailroaderRVTest] final relocation rollback failed: "
            .. safeErrorText(rollbackReason))
        return false
    end
    manifest.rollback = "COMPLETE"
    local markedOk, marked, markedReason = pcall(markGenerationFailed, manifest,
        safeErrorText(reason or "final relocation acknowledgement failed"))
    if not markedOk or marked ~= true then
        pending.rollbackWorldRetryAtTick = serverTick
            + GENERATION_RELOCATION_RETRY_TICKS
        print("[RailroaderRVTest] final relocation failure marker deferred: "
            .. safeErrorText(markedOk and markedReason or marked))
        return false
    end
    pending.rollbackApplied = true
    transactionBusy = false
    transactionPlayer = nil
    return true
end

local function cancelPending(reason)
    local pending = pendingGeneration
    if not pending then return end
    pending.failureReason = reason
    pending.cancelled = true
    local resolved, livePlayerOrReason = resolvePendingPlayer(pending)
    if not resolved then
        if generationDisconnected(livePlayerOrReason) then
            pauseGenerationForDisconnect(pending)
        end
        transactionBusy = true
        transactionPlayer = nil
        print("[RailroaderRVTest] generation cancellation deferred identity="
            .. tostring(pending.identity and pending.identity.key or "unknown")
            .. " reason=" .. safeErrorText(livePlayerOrReason))
        return
    end
    local livePlayer = livePlayerOrReason
    pending.player = livePlayer
    resumeGenerationAfterDisconnect(pending)
    if pending.boundaryCleared ~= true
        and not rearmGenerationTransition(pending, livePlayer, "generation") then
        pending.rollbackRetryAtTick = serverTick
            + GENERATION_RELOCATION_RETRY_TICKS
        transactionBusy = true
        transactionPlayer = livePlayer
        return
    end
    if pending.finalRelocationSent == true and pending.rollbackApplied ~= true then
        local rollbackOk = rollbackPendingGenerationWorld(pending, reason)
        if not rollbackOk then
            transactionBusy = true
            transactionPlayer = livePlayer
            return
        end
    end
    local positionOk, position = authoritativePlayerPosition(livePlayer)
    local original = pending.originalPosition
    local atOriginal = positionOk and type(position) == "table"
        and type(original) == "table"
        and relocationPositionsEqual(position, original)
    if not atOriginal then
        if type(original) ~= "table" then
            transactionBusy = true
            transactionPlayer = livePlayer
            return
        end
        if serverTick < (pending.rollbackRetryAtTick or 0) then
            transactionBusy = true
            transactionPlayer = livePlayer
            return
        end
        local returned = resendGenerationPhase(pending, livePlayer, "rollback")
        pending.rollbackRetryAtTick = serverTick
            + GENERATION_RELOCATION_RETRY_TICKS
        if not returned then
            transactionBusy = true
            transactionPlayer = livePlayer
            return
        end
        local afterOk, after = authoritativePlayerPosition(livePlayer)
        if not afterOk or not relocationPositionsEqual(after, original) then
            pending.rollbackRetryAtTick = serverTick
                + GENERATION_RELOCATION_RETRY_TICKS
            transactionBusy = true
            transactionPlayer = livePlayer
            return
        end
    end
    if pending.boundaryCleared ~= true and Boundary
        and type(Boundary.completeTransition) == "function"
        and pending.token ~= nil then
        local completeOk, complete = pcall(Boundary.completeTransition,
            livePlayer, pending.token)
        if not completeOk or complete ~= true then
            pending.rollbackRetryAtTick = serverTick
                + GENERATION_RELOCATION_RETRY_TICKS
            transactionBusy = true
            transactionPlayer = livePlayer
            return
        end
    end
    if pending.railroader ~= nil and railroaderFailureHook then
        pcall(railroaderFailureHook, livePlayer, pending.railroader, reason,
            pending)
    end
    notifyFailure(livePlayer, reason)
    pendingGeneration = nil
    transactionBusy = false
    transactionPlayer = nil
    print("[RailroaderRVTest] queued generation cancelled player="
        .. tostring(pending.identity and pending.identity.key or "unknown") .. ": "
        .. safeErrorText(reason))
end

local function roofRepairRelocationPositionStillSyncing(reason)
    return reason == "server player has not reached the roof repair destination"
        or reason == "server player has no current square after roof repair relocation"
        or reason == "server player current square does not match roof repair destination"
        or reason == "roof repair temporary destination cell is not loaded"
        or reason == "roof repair temporary destination square is not loaded"
        or reason == "roof repair temporary destination is still room geometry"
end

local function processRoofRepairRelocationGroup()
    local group = roofRepairRelocationGroup
    if not group then return end
    -- A live process owns the exact-float group across a player disconnect.
    -- Defer all phase work until every stable identity has a live IsoPlayer;
    -- this avoids converting a reconnect into a failed/cancelled transaction.
    for i = 1, #(group.members or {}) do
        local resolved = resolveRoofRepairGroupPlayer(group,
            group.members[i])
        if not resolved then return end
    end
    if serverTick > (group.deadlineTick or serverTick) then
        failRoofRepairRelocationGroup("roof repair group relocation transaction timed out")
        return
    end
    for i = 1, #(group.members or {}) do
        local member = group.members[i]
        if not member.arrived then
            local resolved, playerOrReason = resolveRoofRepairGroupPlayer(
                group, member)
            if not resolved then
                return
            end
            local stateCallOk, stateOk, stateOrReason = pcall(
                validateAuthoritativePlayer, playerOrReason)
            if not stateCallOk then
                failRoofRepairRelocationGroup(safeErrorText(stateOk))
                return
            end
            if not stateOk then
                failRoofRepairRelocationGroup(stateOrReason)
                return
            end
            local contextCallOk, contextOk, contextOrReason = pcall(
                currentRoofRepairContext, playerOrReason, {
                    rvId = member.rvId, generation = member.generation,
                    bitmapVersion = member.bitmapVersion,
                    identityKey = member.identityKey,
                })
            if not contextCallOk then
                contextOrReason = safeErrorText(contextOk)
                contextOk = false
            end
            if not contextOk then
                failRoofRepairRelocationGroup(contextOrReason)
                return
            end
            local target = group.phase == "temporary"
                and group.target or member.target
            if group.phase == "return" then
                local exactCallOk, exactPosition = pcall(
                    authoritativePlayerPosition, playerOrReason)
                local atTarget = exactCallOk and type(exactPosition) == "table"
                    and exactPosition.x == target.x
                    and exactPosition.y == target.y
                    and exactPosition.z == target.z
                    and exactPosition.z ~= ROOF_REPAIR_TEMP_Z
                if not atTarget then
                    -- A stale/fallen member needs the same return command again,
                    -- but never once per tick.  Clear any old ACK first so a
                    -- delayed packet cannot complete a command that has just
                    -- been reissued.
                    member.acknowledged = false
                    member.arrivalConsumed = false
                    member.completed = false
                    member.arrived = false
                    member.relocationNeedsResend = true
                    if serverTick < (member.relocationRetryAtTick or 0) then
                        -- Wait for the bounded retry cadence below.
                    elseif type(member.returnPayload) ~= "table" then
                        failRoofRepairRelocationGroup(
                            "roof repair group return payload is unavailable")
                        return
                    else
                        local sentOk = callGlobalSucceeded("sendServerCommand",
                            playerOrReason, COMMAND_MODULE, COMMAND_RELOCATE,
                            member.returnPayload)
                        local moved = callSucceeded(playerOrReason, "teleportTo",
                            target.x, target.y, target.z)
                        member.relocationLastSentTick = serverTick
                        member.relocationRetryAtTick = serverTick
                            + ROOF_RELOCATION_RETRY_TICKS
                        if not sentOk or not moved then
                            -- A transient send/teleport failure is retried with
                            -- this token; the transaction timeout remains the
                            -- final bounded failure path.
                            member.relocationNeedsResend = true
                        else
                            member.relocationNeedsResend = false
                        end
                    end
                end
            end
            local elapsed = serverTick - group.queuedAtTick
            if not member.acknowledged
                or elapsed < RELOCATION_MIN_TICKS
                or serverTick - (member.acknowledgedAtTick or serverTick)
                    < RELOCATION_POST_ACK_TICKS then
                -- The player may still be synchronizing its current square;
                -- do not treat an absent ACK as a permanent failure yet.
            else
                    local readyCallOk, ready, readyReason = pcall(
                        roofRepairTargetReady, playerOrReason, target,
                        group.phase, group.allowedPlayers)
                    if not readyCallOk then
                        readyReason = safeErrorText(ready)
                        ready = false
                    end
                if not ready then
                    if roofRepairRelocationPositionStillSyncing(readyReason) then
                        -- Wait for the authoritative square/current cell to
                        -- settle on the next server tick.
                    else
                        failRoofRepairRelocationGroup(readyReason)
                        return
                    end
                else
                    member.arrived = true
                    member.arrivedAtTick = serverTick
                    print("[RailroaderRVTest] roof repair group member arrived room="
                        .. tostring(group.roomKey or "unknown") .. " player="
                        .. tostring(member.identityKey) .. " phase="
                        .. tostring(group.phase) .. " target="
                        .. tostring(target.x) .. "," .. tostring(target.y)
                        .. "," .. tostring(target.z))
                end
            end
        end
    end
end

function RV.Server.OnTick()
    serverTick = serverTick + 1
    -- Extend the token-scoped boundary lease before Boundary.onTick runs.  The
    -- roof transaction may temporarily place the player outside the active
    -- bitmap while the engine settles room state; correction must stay paused
    -- for that bounded transaction only.
    if not keepRoofRepairTransitionAlive() then return end
    if not keepGenerationTransitionAlive() then return end
    if Boundary and type(Boundary.onTick) == "function" then
        pcall(Boundary.onTick)
    end
    processServerRoomOwnershipGuards()
    processRoofRepairRelocationGroup()
    processRoofRepairGroupFinalReturn()
    local pending = pendingGeneration
    if pending == nil then
        return
    end
    if pending.cancelled == true then
        cancelPending(pending.failureReason or "generation transaction cancelled")
        return
    end
    local resolved, playerOrReason = resolvePendingPlayer(pending)
    if not resolved then
        -- A live server keeps the exact-float transaction until the same stable
        -- identity reconnects; no timeout or failure callback is run on a
        -- missing player object.
        if not generationDisconnected(playerOrReason) then
            cancelPending(playerOrReason)
        else
            pauseGenerationForDisconnect(pending)
        end
        return
    end
    resumeGenerationAfterDisconnect(pending)
    local elapsed = serverTick - pending.queuedAtTick
    if pending.finalRelocationSent ~= true
        and elapsed > RELOCATION_TIMEOUT_TICKS then
        cancelPending("relocation acknowledgement timed out before world mutation")
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
    if pending.finalRelocationSent == true then
        if not pending.finalRelocationAcked then
            if serverTick > (pending.finalRelocationDeadlineTick
                or serverTick) then
                cancelPending("final relocation acknowledgement timed out")
            end
            return
        end
        local finalOk, finalReason = finalizeGenerationAfterRelocate(
            playerOrReason, pending)
        if finalOk then
            pendingGeneration = nil
            print("[RailroaderRVTest] generation committed READY")
        else
            pending.failureReason = finalReason
            pending.cancelled = true
            cancelPending(finalReason)
            print("[RailroaderRVTest] generation finalization failed: "
                .. safeErrorText(finalReason))
        end
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
    -- every base square in the exact 100x100 footprint is present; no cleanup
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
    if not ok then
        completedPending.failureReason = reason
        completedPending.cancelled = true
        cancelPending(reason)
        print("[RailroaderRVTest] generation failed: " .. tostring(reason))
    elseif reason == "await-final-relocate" then
        print("[RailroaderRVTest] generation awaiting FinalRelocateAck")
    else
        pendingGeneration = nil
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
    if module == COMMAND_MODULE and command == COMMAND_FINAL_RELOCATE_ACK then
        local ackOk, accepted, reason = pcall(acknowledgeFinalRelocation,
            player, args)
        if not ackOk then
            reason = safeErrorText(accepted)
            accepted = false
        end
        if not accepted then
            print("[RailroaderRVTest] final relocation acknowledgement rejected: "
                .. safeErrorText(reason))
        end
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
        notifyFailure(player, reason)
        print("[RailroaderRVTest] generation request failed: " .. tostring(reason))
    end
end

if Events and Events.OnClientCommand and type(Events.OnClientCommand.Add) == "function" then
    Events.OnClientCommand.Add(RV.Server.OnClientCommand)
end
if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(RV.Server.OnTick)
end
if Boundary and Events and Events.OnProcessAction
    and type(Events.OnProcessAction.Add) == "function" then
    Events.OnProcessAction.Add(Boundary.onProcessAction)
end
if Boundary and Events and Events.OnObjectAdded
    and type(Events.OnObjectAdded.Add) == "function" then
    Events.OnObjectAdded.Add(Boundary.onObjectAdded)
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
