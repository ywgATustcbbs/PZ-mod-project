-- Strict checks for current shared schema contracts.
local M = {}

function M.integer(value)
    if type(value) ~= "number" or value ~= value
        or value >= math.huge or value <= -math.huge then
        return nil
    end
    if math.floor(value) ~= value then return nil end
    return value
end

return M
