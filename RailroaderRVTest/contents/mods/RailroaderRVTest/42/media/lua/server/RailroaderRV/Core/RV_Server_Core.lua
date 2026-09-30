-- RailroaderRVTest server Core: the single owner of RV event subscriptions
-- and the in-process logical server clock.
--
-- This module owns transient dispatch state only. It never writes SandboxVars,
-- ModData, or any other persisted state.
local RV = rawget(_G, "RailroaderRV") or {}
rawset(_G, "RailroaderRV", RV)

local Core = type(RV.Core) == "table" and RV.Core or {}
local UINT32_BASE = 4294967296
local UINT32_MAX = 4294967295
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_INTERVAL = 2147483647

local function isUInt32(value)
    return type(value) == "number" and value == value
        and value >= 0 and value <= UINT32_MAX
        and value == math.floor(value)
end

local function isTick(value)
    if type(value) ~= "table" then return false end
    local hi32 = rawget(value, "hi32")
    local lo32 = rawget(value, "lo32")
    if not isUInt32(hi32) or not isUInt32(lo32) then return false end
    local count = 0
    for key in pairs(value) do
        if key ~= "hi32" and key ~= "lo32" then return false end
        count = count + 1
    end
    return count == 2
end

local function copyTick(value)
    return { hi32 = value.hi32, lo32 = value.lo32 }
end

local function validDelay(value)
    return type(value) == "number" and value == value
        and value >= 0 and value <= MAX_SAFE_INTEGER
        and value == math.floor(value)
end

local function tickCompare(left, right)
    if not isTick(left) or not isTick(right) then
        return nil, "invalid-tick"
    end
    if left.hi32 < right.hi32 then return -1 end
    if left.hi32 > right.hi32 then return 1 end
    if left.lo32 < right.lo32 then return -1 end
    if left.lo32 > right.lo32 then return 1 end
    return 0
end

local function tickAdd(tick, delta)
    if not isTick(tick) then return nil, "invalid-tick" end

    local addHi, addLo
    if type(delta) == "table" then
        if not isTick(delta) then return nil, "invalid-tick-delta" end
        addHi, addLo = delta.hi32, delta.lo32
    else
        if not validDelay(delta) then return nil, "invalid-tick-delta" end
        addHi = math.floor(delta / UINT32_BASE)
        addLo = delta % UINT32_BASE
    end

    local lowSum = tick.lo32 + addLo
    local lo32 = lowSum % UINT32_BASE
    local carry = math.floor(lowSum / UINT32_BASE)
    local hi32 = tick.hi32 + addHi + carry
    if hi32 > UINT32_MAX then return nil, "tick-overflow" end
    return { hi32 = hi32, lo32 = lo32 }
end

local function tickReached(now, deadline)
    local comparison, reason = tickCompare(now, deadline)
    if comparison == nil then return false, reason end
    return comparison >= 0
end

local function tickElapsed(now, since)
    local comparison, reason = tickCompare(now, since)
    if comparison == nil then return nil, reason end
    if comparison < 0 then return nil, "tick-order-invalid" end

    local hi32 = now.hi32 - since.hi32
    local lo32
    if now.lo32 < since.lo32 then
        hi32 = hi32 - 1
        lo32 = now.lo32 + UINT32_BASE - since.lo32
    else
        lo32 = now.lo32 - since.lo32
    end
    return { hi32 = hi32, lo32 = lo32 }
end

local function tickElapsedAtLeast(now, since, duration)
    local deadline, reason = tickAdd(since, duration)
    if deadline == nil then return false, reason end
    return tickReached(now, deadline)
end

local function addModulo(left, right, modulus)
    local gap = modulus - right
    if left >= gap then return left - gap end
    return left + right
end

local function multiplyModulo(left, right, modulus)
    local result = 0
    while right > 0 do
        if right % 2 == 1 then
            result = addModulo(result, left, modulus)
        end
        right = math.floor(right / 2)
        if right > 0 then left = addModulo(left, left, modulus) end
    end
    return result
end

local function tickModuloFor(tick, interval)
    if not isTick(tick) then return false, "invalid-tick" end
    if not validDelay(interval) or interval < 1 or interval > MAX_INTERVAL then
        return false, "invalid-tick-interval"
    end
    if interval == 1 then return true end

    -- Compute hi32 * 2^32 + lo32 modulo interval without ever constructing
    -- the 64-bit tick or an imprecise intermediate product as a Lua number.
    local highRemainder = multiplyModulo(tick.hi32 % interval,
        UINT32_BASE % interval, interval)
    local remainder = addModulo(highRemainder, tick.lo32 % interval, interval)
    return remainder == 0
end

local state = type(Core._state) == "table" and Core._state or {}
Core._state = state
if not isTick(state.tick) then
    state.tick = { hi32 = 0, lo32 = 0 }
end
state.tickHandlers = type(state.tickHandlers) == "table" and state.tickHandlers or {}
state.commandHandlers = type(state.commandHandlers) == "table" and state.commandHandlers or {}
state.eventHandlers = type(state.eventHandlers) == "table" and state.eventHandlers or {}
state.installedEvents = type(state.installedEvents) == "table" and state.installedEvents or {}
state.dispatchers = type(state.dispatchers) == "table" and state.dispatchers or {}

local function getTick()
    return copyTick(state.tick)
end

local function formatTick(tick)
    if not isTick(tick) then return "invalid" end
    return tostring(tick.hi32) .. ":" .. tostring(tick.lo32)
end

local function tickModulo(interval)
    return tickModuloFor(state.tick, interval)
end

local function nextTick()
    local tick = state.tick
    if tick.hi32 == UINT32_MAX and tick.lo32 == UINT32_MAX then
        return false, "tick-overflow"
    end
    if tick.lo32 == UINT32_MAX then
        state.tick = { hi32 = tick.hi32 + 1, lo32 = 0 }
    else
        state.tick = { hi32 = tick.hi32, lo32 = tick.lo32 + 1 }
    end
    return true
end

local function callOrdered(entries, predicate, ...)
    local count = #entries
    for index = 1, count do
        local entry = entries[index]
        if predicate == nil or predicate(entry) then
            -- The engine now sees one Core dispatcher instead of independent
            -- listeners. Preserve fail-fast behavior: a failed transaction
            -- must not be followed by another world's write from a later
            -- handler in the same dispatch.
            entry.callback(...)
        end
    end
end

local function dispatchEvent(eventName, ...)
    if eventName == "OnTick" then
        local advanced, reason = nextTick()
        if not advanced then error(reason, 0) end
        local tick = getTick()
        callOrdered(state.tickHandlers, function(entry)
            return tickModuloFor(tick, entry.interval)
        end, tick)
        return
    end

    if eventName == "OnClientCommand" then
        local module, command = ...
        callOrdered(state.commandHandlers, function(entry)
            return entry.name == "*" or entry.name == command
        end, ...)
        return
    end

    callOrdered(state.eventHandlers[eventName] or {}, nil, ...)
end

local function ensureEngineListener(eventName)
    if state.installedEvents[eventName] == true then return true end
    local events = rawget(_G, "Events")
    local eventOk, event = pcall(function()
        return events and events[eventName]
    end)
    local addOk, add = false, nil
    if eventOk and event ~= nil then
        addOk, add = pcall(function() return event.Add end)
    end
    if not eventOk or event == nil or not addOk or type(add) ~= "function" then
        -- Fail closed: callers must not report a handler as registered while
        -- the engine has no dispatcher. A later registration attempt (or Core
        -- reload) can retry after the event API becomes available.
        return false, "event-api-unavailable"
    end
    local dispatcher = state.dispatchers[eventName]
    if type(dispatcher) ~= "function" then
        dispatcher = function(...)
            return dispatchEvent(eventName, ...)
        end
        state.dispatchers[eventName] = dispatcher
    end
    local ok, result = pcall(add, dispatcher)
    if not ok or result == false then return false, "event-register-failed" end
    state.installedEvents[eventName] = true
    return true
end

local function registerTick(name, interval, callback)
    if type(name) ~= "string" or name == "" or not validDelay(interval)
        or interval < 1 or interval > MAX_INTERVAL or type(callback) ~= "function" then
        return false, "invalid-tick-registration"
    end
    local duplicate
    for index = 1, #state.tickHandlers do
        local entry = state.tickHandlers[index]
        if entry.name == name then
            if entry.callback ~= callback or entry.interval ~= interval then
                return false, "duplicate-tick-registration"
            end
            duplicate = true
            break
        end
    end
    local installed, reason = ensureEngineListener("OnTick")
    if not installed then return false, reason end
    if duplicate then return true end
    state.tickHandlers[#state.tickHandlers + 1] = {
        name = name,
        interval = interval,
        callback = callback,
    }
    return true
end

local function registerCommand(name, callback)
    if type(name) ~= "string" or name == "" or type(callback) ~= "function" then
        return false, "invalid-command-registration"
    end
    local duplicate
    for index = 1, #state.commandHandlers do
        local entry = state.commandHandlers[index]
        if entry.name == name then
            if entry.callback ~= callback then
                return false, "duplicate-command-registration"
            end
            duplicate = true
            break
        end
    end
    local installed, reason = ensureEngineListener("OnClientCommand")
    if not installed then return false, reason end
    if duplicate then return true end
    state.commandHandlers[#state.commandHandlers + 1] = {
        name = name,
        callback = callback,
    }
    return true
end

local allowedEvents = {
    OnProcessAction = true,
    OnObjectAdded = true,
    OnObjectAboutToBeRemoved = true,
    OnDestroyIsoThumpable = true,
}

local function registerEvent(eventName, name, callback)
    if allowedEvents[eventName] ~= true or type(name) ~= "string" or name == ""
        or type(callback) ~= "function" then
        return false, "invalid-event-registration"
    end
    local entries = state.eventHandlers[eventName]
    if type(entries) ~= "table" then
        entries = {}
        state.eventHandlers[eventName] = entries
    end
    local duplicate
    for index = 1, #entries do
        local entry = entries[index]
        if entry.name == name then
            if entry.callback ~= callback then
                return false, "duplicate-event-registration"
            end
            duplicate = true
            break
        end
    end
    local installed, reason = ensureEngineListener(eventName)
    if not installed then return false, reason end
    if duplicate then return true end
    entries[#entries + 1] = { name = name, callback = callback }
    return true
end

local function sendToClient(player, command, payload)
    if player == nil or type(command) ~= "string" or command == "" then
        return false, "invalid-client-message"
    end
    local send = rawget(_G, "sendServerCommand")
    if type(send) ~= "function" then
        return false, "send-server-command-unavailable"
    end
    local constantsOk, constants = pcall(require, "RailroaderRV/Common/RV_Constants")
    local module = constantsOk and type(constants) == "table"
        and constants.MOD_ID or "RailroaderRVTest"
    local ok, result = pcall(send, player, module, command, payload)
    if not ok or result == false then return false, "send-server-command-failed" end
    return true
end

Core.getTick = getTick
Core.isTick = isTick
Core.formatTick = formatTick
Core.tickAdd = tickAdd
Core.tickCompare = tickCompare
Core.tickReached = tickReached
Core.tickElapsed = tickElapsed
Core.tickElapsedAtLeast = tickElapsedAtLeast
Core.tickModulo = tickModulo
Core.registerTick = registerTick
Core.registerCommand = registerCommand
Core.registerEvent = registerEvent
Core.sendToClient = sendToClient

RV.Core = Core

-- On reload, retry every dispatcher represented in the process-local registry.
-- A failed retry raises during Core initialization so consumers remain failed
-- closed; a later reload can retry once the engine API is available.
local pendingEvents = {}
if #state.tickHandlers > 0 then pendingEvents.OnTick = true end
if #state.commandHandlers > 0 then pendingEvents.OnClientCommand = true end
for eventName, entries in pairs(state.eventHandlers) do
    if type(entries) == "table" and #entries > 0 then
        pendingEvents[eventName] = true
    end
end
for eventName in pairs(pendingEvents) do
    local installed, reason = ensureEngineListener(eventName)
    if not installed then
        error("RV Core dispatcher retry failed for " .. tostring(eventName)
            .. ": " .. tostring(reason), 0)
    end
end

return Core
