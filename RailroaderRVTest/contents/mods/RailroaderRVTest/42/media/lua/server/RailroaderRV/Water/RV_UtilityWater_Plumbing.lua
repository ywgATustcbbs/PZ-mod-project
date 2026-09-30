-- Apply B42 external-water-source plumbing and provide checked compensation.

local Util = require("RailroaderRV/Common/RV_ServerUtil")
local U = require("RailroaderRV/Common/RV_UtilityConstants")

local M = {}

local function readState(object)
    local ok, connected = Util.invoke(object, "getUsesExternalWaterSource")
    if not ok or type(connected) ~= "boolean" then
        return false, U.REASONS.API_ERROR
    end
    local dataOk, data = Util.invoke(object, "getModData")
    if not dataOk or type(data) ~= "table" then
        return false, U.REASONS.API_ERROR
    end
    local pipable = data.canBeWaterPiped
    if pipable ~= nil and type(pipable) ~= "boolean" then
        return false, U.REASONS.DEVICE_INVALID
    end
    return true, { connected = connected, hasPipableFlag = pipable ~= nil,
        pipableFlag = pipable }
end

local function applyState(object, connected, pipableFlag)
    local accepted = Util.callSucceeded(object, "setUsesExternalWaterSource", connected)
    local dataOk, data = Util.invoke(object, "getModData")
    if dataOk and type(data) == "table" then
        data.canBeWaterPiped = pipableFlag
    else
        accepted = false
    end
    if not Util.callSucceeded(object, "transmitModData") then accepted = false end
    if not Util.callSucceeded(object, "sendObjectChange",
        "usesExternalWaterSource", { value = connected }) then
        accepted = false
    end
    local readOk, observed = readState(object)
    local expectedFlag = pipableFlag
    if not readOk or observed.connected ~= connected
        or observed.pipableFlag ~= expectedFlag then
        accepted = false
    end
    return accepted, readOk and observed or nil
end

local function previousFlag(previous)
    if previous.hasPipableFlag then return previous.pipableFlag end
    return nil
end

function M.readState(object)
    return readState(object)
end

function M.apply(object, desiredConnected)
    if type(desiredConnected) ~= "boolean" then
        return false, U.REASONS.INVALID_REQUEST
    end
    local readOk, previousOrReason = readState(object)
    if not readOk then return false, previousOrReason, true end
    local previous = previousOrReason
    -- Mirror the vanilla plumb action: a connected object is no longer a
    -- pending plumbing target. Disconnecting makes the fixture plumbable again.
    local desiredPipable = desiredConnected and false or true
    local applied, observed = applyState(object, desiredConnected, desiredPipable)
    if applied then
        return true, { previous = previous, observed = observed }
    end
    local restored = applyState(object, previous.connected, previousFlag(previous))
    return false, U.REASONS.POSTCONDITION_FAILED, restored == true, previous
end

function M.rollback(object, previous)
    if type(previous) ~= "table" or type(previous.connected) ~= "boolean"
        or type(previous.hasPipableFlag) ~= "boolean" then
        return false
    end
    local accepted = applyState(object, previous.connected, previousFlag(previous))
    return accepted == true
end

return M
