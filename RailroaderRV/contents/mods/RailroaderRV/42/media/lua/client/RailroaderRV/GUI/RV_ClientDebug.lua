-- Client-side diagnostic reports sent to the server log.

local C = require("RailroaderRV/Common/RV_Constants")

RailroaderRV = RailroaderRV or {}
local ClientDebug = {}

function ClientDebug.report(player, message)
    return sendClientCommand(player, C.MOD_ID,
        C.COMMAND_RV_CLIENT_DEBUG, { message = message })
end

RailroaderRV.ClientDebug = ClientDebug
return ClientDebug
