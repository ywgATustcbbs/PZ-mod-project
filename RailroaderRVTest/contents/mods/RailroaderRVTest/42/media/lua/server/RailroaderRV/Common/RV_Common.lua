-- Shared server helpers for identity, Java/Lua values, and world-square access.
-- This module has no event registrations or persistence.
local unpackFn = (table and table.unpack) or unpack

local Common = {}

function Common.invoke(target, name, ...)
    if target == nil then return false, nil end
    local accessOk, method = pcall(function() return target[name] end)
    if not accessOk then return false, nil end
    if type(method) ~= "function" then return false, nil end
    local ok, a, b, c, d = pcall(method, target, ...)
    if not ok then return false, a end
    return true, a, b, c, d
end

function Common.callSucceeded(target, name, ...)
    local ok, result = Common.invoke(target, name, ...)
    return ok and result ~= false
end

function Common.invokeClass(class, signatures)
    if class == nil or type(signatures) ~= "table" then
        return false, nil
    end
    local accessOk, constructor = pcall(function() return class.new end)
    if not accessOk or type(constructor) ~= "function" then return false, nil end
    for i = 1, #signatures do
        local args = signatures[i]
        if type(args) ~= "table" then return false, nil end
        local ok, value = pcall(constructor, unpackFn(args))
        if ok and value ~= nil then return true, value end
    end
    return false, nil
end

function Common.callGlobal(name, ...)
    local fn = rawget(_G, name)
    if type(fn) ~= "function" then return false, nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return false, a end
    return true, a, b, c
end

function Common.callGlobalSucceeded(name, ...)
    local ok, result = Common.callGlobal(name, ...)
    return ok and result ~= false
end

function Common.classInstance(object, className)
    local checker = rawget(_G, "instanceof")
    if type(checker) ~= "function" then return false end
    local ok, result = pcall(checker, object, className)
    return ok and result == true
end

function Common.toNumber(value)
    local valueType = type(value)
    if valueType == "number" then return value end
    if valueType == "string" then return tonumber(value) end
    if value == nil then return nil end
    local ok, numeric = pcall(function() return value + 0 end)
    if ok and type(numeric) == "number" then return numeric end
    return nil
end

function Common.isFiniteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

function Common.integer(value)
    local numeric = Common.toNumber(value)
    if not Common.isFiniteNumber(numeric) or math.floor(numeric) ~= numeric then
        return nil
    end
    return numeric
end

function Common.identityKey(...)
    local parts = {}
    local count = select("#", ...)
    for index = 1, count do
        local value = select(index, ...)
        if value == nil then return nil end
        local part = tostring(value)
        parts[index] = tostring(#part) .. ":" .. part
    end
    return table.concat(parts, "|")
end

return Common
