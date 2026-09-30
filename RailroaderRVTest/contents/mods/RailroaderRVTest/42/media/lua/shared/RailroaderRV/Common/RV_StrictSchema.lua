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

function M.exactKeys(value, expected)
    if type(value) ~= "table" or getmetatable(value) ~= nil then
        return false
    end
    local allowed = {}
    for i = 1, #expected do allowed[expected[i]] = true end
    local count = 0
    for key in pairs(value) do
        if not allowed[key] then return false end
        count = count + 1
    end
    return count == #expected
end

return M
