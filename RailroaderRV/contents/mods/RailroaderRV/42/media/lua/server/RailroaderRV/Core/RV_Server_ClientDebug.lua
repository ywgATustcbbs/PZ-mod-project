-- Server-side receiver for client diagnostic text.

local Debug = {}

function Debug.handle(player, args)
    if type(args) ~= "table" or type(args.message) ~= "string" then
        return false
    end
    local username = string.gsub(player:getUsername(), "[\r\n]", " ")
    local message = string.gsub(args.message, "[\r\n]", " ")
    print("[RailroaderRV][RVDEBUG][id=" .. tostring(player:getOnlineID())
        .. " user=" .. username .. "] " .. message)
    return true
end

return Debug
