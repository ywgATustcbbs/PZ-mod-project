-- Shared server helpers for identity, Java/Lua values, player snapshots, and
-- world-square access. This module has no event registrations or persistence.
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

function Common.exactKeys(value, expected, optional)
    if type(value) ~= "table" or type(expected) ~= "table" then return false end
    local count = 0
    for key in pairs(value) do
        if expected[key] ~= true and not (optional and optional[key] == true) then
            return false
        end
        count = count + 1
    end
    local required = 0
    for key, requiredValue in pairs(expected) do
        if requiredValue == true and not (optional and optional[key] == true) then
            required = required + 1
            if value[key] == nil then return false end
        end
    end
    return count >= required
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

function Common.getPlayerPosition(player)
    local xOk, x = Common.invoke(player, "getX")
    local yOk, y = Common.invoke(player, "getY")
    local zOk, z = Common.invoke(player, "getZ")
    x, y, z = xOk and Common.toNumber(x) or nil,
        yOk and Common.toNumber(y) or nil,
        zOk and Common.toNumber(z) or nil
    if not Common.isFiniteNumber(x) or not Common.isFiniteNumber(y)
        or not Common.isFiniteNumber(z) then
        return false, "player position is unavailable"
    end
    return true, { x = x, y = y, z = z }
end

function Common.getSquare(cell, x, y, z)
    x, y, z = Common.integer(x), Common.integer(y), Common.integer(z)
    if x == nil or y == nil or z == nil then
        return false, nil
    end
    local ok, square = Common.invoke(cell, "getGridSquare", x, y, z)
    return ok and square ~= nil, square
end

local function playerIdentity(player)
    local nameOk, name = Common.invoke(player, "getUsername")
    local idOk, onlineId = Common.invoke(player, "getOnlineID")
    if not nameOk or type(name) ~= "string" or name == "" or not idOk then
        return nil
    end
    onlineId = Common.integer(onlineId)
    if onlineId == nil or onlineId < 0 then return nil end
    return Common.identityKey(name, onlineId)
end

local function copyTick(tick)
    if type(tick) ~= "table" or Common.exactKeys(tick,
        { hi32 = true, lo32 = true }) ~= true
        or Common.integer(tick.hi32) == nil or Common.integer(tick.lo32) == nil
        or tick.hi32 < 0 or tick.hi32 > 4294967295
        or tick.lo32 < 0 or tick.lo32 > 4294967295 then
        return nil
    end
    return { hi32 = tick.hi32, lo32 = tick.lo32 }
end

local function playerScopeKey(identity)
    if identity == nil then return "<session>" end
    if type(identity) ~= "table"
        or not Common.exactKeys(identity, {
            rvId = true, generation = true, slotIndex = true, anchor = true,
        })
        or type(identity.rvId) ~= "string" or identity.rvId == "" then
        return nil
    end
    local generation = Common.integer(identity.generation)
    local slotIndex = Common.integer(identity.slotIndex)
    local anchor = identity.anchor
    if generation == nil or generation < 1 or slotIndex == nil or slotIndex < 1
        or not Common.exactKeys(anchor, { x = true, y = true, z = true }) then
        return nil
    end
    local x, y, z = Common.integer(anchor.x), Common.integer(anchor.y),
        Common.integer(anchor.z)
    if x == nil or y == nil or z == nil then return nil end
    return Common.identityKey(identity.rvId, generation, slotIndex, x, y, z)
end

function Common.newPlayerPositionCache(clock)
    if type(clock) ~= "table" or type(clock.getTick) ~= "function"
        or type(clock.tickAdd) ~= "function"
        or type(clock.tickReached) ~= "function" then
        error("RailroaderRV: current Core tick arithmetic is unavailable")
    end
    local entries = {}
    local cache = {}

    function cache:invalidatePlayer(player, reason)
        local key = playerIdentity(player)
        if key ~= nil then entries[key] = nil end
        return key ~= nil
    end

    function cache:invalidateIdentity(identity)
        local scopeKey = playerScopeKey(identity)
        if scopeKey == nil then return false end
        local changed = false
        for key, entry in pairs(entries) do
            if entry.scopeKey == scopeKey then
                entries[key] = nil
                changed = true
            end
        end
        return changed
    end

    function cache:samplePlayerPosition(player, tick, interval, identity)
        local key = playerIdentity(player)
        local currentTick = copyTick(tick)
        local sampleInterval = Common.integer(interval)
        local scopeKey = playerScopeKey(identity)
        if key == nil or currentTick == nil or sampleInterval == nil
            or sampleInterval < 1 or scopeKey == nil then
            return false, "player sample identity or interval is invalid"
        end
        local previous = entries[key]
        if previous ~= nil and previous.scopeKey ~= scopeKey then
            entries[key] = nil
            previous = nil
        end
        if previous ~= nil then
            local nextSample = clock.tickAdd(previous.tick, sampleInterval)
            if not clock.tickReached(currentTick, nextSample) then
                return false, "player sample is not due"
            end
        end
        local positionOk, position = Common.getPlayerPosition(player)
        if not positionOk then return false, position end
        entries[key] = {
            position = position,
            tick = currentTick,
            scopeKey = scopeKey,
        }
        return true, { x = position.x, y = position.y, z = position.z }
    end

    function cache:getPlayerPosition(player, options)
        options = type(options) == "table" and options or {}
        if options.fresh == true then return Common.getPlayerPosition(player) end
        local key = playerIdentity(player)
        local now = copyTick(options.now or clock.getTick())
        local maxAge = Common.integer(options.maxAge)
        local scopeKey = playerScopeKey(options.identity)
        local entry = key and entries[key] or nil
        if entry == nil or now == nil or maxAge == nil or maxAge < 0
            or scopeKey == nil or entry.scopeKey ~= scopeKey then
            return false, "fresh player position is required"
        end
        local expiry = clock.tickAdd(entry.tick, maxAge)
        if not clock.tickReached(expiry, now) then
            return false, "cached player position is stale"
        end
        return true, {
            x = entry.position.x, y = entry.position.y, z = entry.position.z,
        }
    end

    function cache.clear()
        entries = {}
    end

    return cache
end

return Common
