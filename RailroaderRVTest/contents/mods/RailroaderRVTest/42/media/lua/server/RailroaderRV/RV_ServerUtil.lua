-- RailroaderRVTest server-side pure helpers.
--
-- This module is deliberately side-effect free: it does not register events or
-- touch the world.  Keeping the generic call/validation helpers in their own
-- require chunk leaves RV_Server.lua below Kahlua's 200 active-local limit.

local LayoutContract = require("RailroaderRV/RV_Layout")
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
    return type(value) == "number"
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
    return LayoutContract.make(x, y, z)
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
