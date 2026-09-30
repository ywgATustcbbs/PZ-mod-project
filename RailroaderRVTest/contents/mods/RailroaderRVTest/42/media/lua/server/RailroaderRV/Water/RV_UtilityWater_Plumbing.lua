-- Apply B42 external-water-source plumbing to one resolved sink.

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
    return true, { connected = connected, pipableFlag = pipable }
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
    if not readOk or observed.connected ~= connected
        or observed.pipableFlag ~= pipableFlag then
        accepted = false
    end
    return accepted
end

function M.apply(object, desiredConnected)
    if type(desiredConnected) ~= "boolean" then
        return false, U.REASONS.INVALID_REQUEST
    end
    -- Mirror the vanilla plumb action: a connected object is no longer a
    -- pending plumbing target. Disconnecting makes the fixture plumbable again.
    local desiredPipable = desiredConnected and false or true
    local applied = applyState(object, desiredConnected, desiredPipable)
    if not applied then return false, U.REASONS.POSTCONDITION_FAILED end
    return true
end

return M
