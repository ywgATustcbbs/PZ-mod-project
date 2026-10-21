-- Server-side receiver for client diagnostic text.

local Debug = {}

function Debug.handle(player, args)
    local username = player:getUsername()
    local message = args.message
    print("[RailroaderRV][RVDEBUG][id=" .. tostring(player:getOnlineID())
        .. " user=" .. username .. "] " .. message)
    return true
end

return Debug
