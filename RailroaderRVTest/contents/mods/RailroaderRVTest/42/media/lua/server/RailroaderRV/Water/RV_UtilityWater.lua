-- Server-authoritative native water plumbing for current RV sink identities.

local Commands = require("RailroaderRV/Water/RV_UtilityWater_Commands")

local M = {}

function M.setConnection(identity, context, targetHint, record)
    return Commands.setConnection(identity, context, targetHint, record)
end

return M
