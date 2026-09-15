-- RailroaderRVTest server-side pure helpers.
--
-- This module is deliberately side-effect free: it does not register events or
-- touch the world.  Keeping the generic call/validation helpers in their own
-- require chunk leaves RV_Server.lua below Kahlua's 200 active-local limit.

local Constants = require("RailroaderRV/RV_Constants")
local LayoutContract = require("RailroaderRV/RV_Layout")
local Bitmap = require("RailroaderRV/RV_Bitmap")
local unpackFn = (table and table.unpack) or unpack

local M = {}

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
    local integerValue = math.floor(number)
    if integerValue ~= number then
        error("RailroaderRVTest: " .. tostring(label) .. " must be an integer")
    end
    return integerValue
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

M.invoke = invoke
M.callSucceeded = callSucceeded
M.invokeClass = invokeClass
M.callGlobal = callGlobal
M.callGlobalSucceeded = callGlobalSucceeded
M.classInstance = classInstance
M.toNumber = toNumber
M.isFiniteNumber = isFiniteNumber
M.integer = integer
M.tableIsEmpty = tableIsEmpty
M.isEmptyCommandArgs = isEmptyCommandArgs
M.requiredNumber = requiredNumber
M.requiredInteger = requiredInteger
M.floorInt = floorInt
M.copyPoint = copyPoint
M.makeLayout = makeLayout

return M
