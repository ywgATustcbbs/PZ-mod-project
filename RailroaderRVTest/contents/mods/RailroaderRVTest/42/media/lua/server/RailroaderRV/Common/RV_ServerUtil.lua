-- RailroaderRVTest server-side pure helpers.
--
-- This module is deliberately side-effect free: it does not register events or
-- touch the world.  Keeping the generic call/validation helpers in their own
-- require chunk leaves RV_Server.lua below Kahlua's 200 active-local limit.

local LayoutContract = require("RailroaderRV/RoomTemplate/RV_Layout")
local Common = require("RailroaderRV/Common/RV_Common")

local M = {}
local invoke = Common.invoke
local callSucceeded = Common.callSucceeded
local invokeClass = Common.invokeClass
local callGlobal = Common.callGlobal
local callGlobalSucceeded = Common.callGlobalSucceeded
local classInstance = Common.classInstance
local toNumber = Common.toNumber
local isFiniteNumber = Common.isFiniteNumber
local integer = Common.integer

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
M.exactKeys = Common.exactKeys
M.copyPlain = Common.copyPlain
M.identityKey = Common.identityKey
M.getPlayerPosition = Common.getPlayerPosition
M.getSquare = Common.getSquare
M.newPlayerPositionCache = Common.newPlayerPositionCache
M.requiredNumber = requiredNumber
M.requiredInteger = requiredInteger
M.floorInt = floorInt
M.copyPoint = copyPoint
M.makeLayout = makeLayout

return M
