-- RailroaderRVTest server Core: the single owner of RV event subscriptions
-- and the in-process logical server clock.
--
-- The logical tick is a plain Lua number owned by this module.  Every value
-- stored in RV in-memory records is produced here or by arithmetic on it, so
-- consumers compare numbers directly instead of validating tick shape.
--
-- This module owns transient dispatch state only. It never writes SandboxVars,
-- ModData, or any other persisted state.
local RV = rawget(_G, "RailroaderRV") or {}
rawset(_G, "RailroaderRV", RV)

local Core = type(RV.Core) == "table" and RV.Core or {}

local state = type(Core._state) == "table" and Core._state or {}
Core._state = state
state.tick = type(state.tick) == "number" and state.tick or 0
state.tickCallbacks = type(state.tickCallbacks) == "table" and state.tickCallbacks or {}
state.commandCallbacks = type(state.commandCallbacks) == "table"
    and state.commandCallbacks or {}
state.subscribed = state.subscribed == true

local handlers = {
    OnTick = state.tickCallbacks,
    OnClientCommand = state.commandCallbacks,
    OnProcessAction = {},
    OnObjectAdded = {},
    OnObjectAboutToBeRemoved = {},
    OnDestroyIsoThumpable = {},
}

local function getTick()
    return state.tick
end

local function tickAdd(tick, delta)
    return tick + delta
end

local function tickReached(now, deadline)
    return now >= deadline
end

local function tickElapsedAtLeast(now, since, duration)
    return (now - since) >= duration
end

local function tickModulo(interval)
    return state.tick % interval == 0
end

-- The engine sees exactly one Core dispatcher per engine event.  Preserve the
-- fail-fast contract: a handler that raises stops that event's dispatch
-- instead of being silently swallowed.
local function dispatch(eventName, ...)
    local callbacks = handlers[eventName]
    if type(callbacks) ~= "table" then
        error("RailroaderRVTest: unknown engine event " .. tostring(eventName), 0)
    end
    for index = 1, #callbacks do
        local ok, err = pcall(callbacks[index], ...)
        if not ok then
            print("[RailroaderRVTest] " .. eventName .. " handler failed: "
                .. tostring(err))
            return
        end
    end
end

local function on(eventName, callback)
    local callbacks = handlers[eventName]
    if type(callbacks) ~= "table" then
        error("RailroaderRVTest: unknown engine event " .. tostring(eventName), 0)
    end
    callbacks[#callbacks + 1] = callback
end

local function onTick(callback)
    on("OnTick", callback)
end

-- Registration order is dispatch order.  RV_Server_Commands registers the "*"
-- catch-all before the adapter registers its named commands, so the engine
-- command is offered to "*" first and then to a named handler.
local function onCommand(command, callback)
    on("OnClientCommand", function(module, received, player, args)
        if command ~= "*" and received ~= command then return end
        return callback(module, received, player, args)
    end)
end

Core.getTick = getTick
Core.tickAdd = tickAdd
Core.tickReached = tickReached
Core.tickElapsedAtLeast = tickElapsedAtLeast
Core.tickModulo = tickModulo
Core.on = on
Core.onTick = onTick
Core.onCommand = onCommand

RV.Core = Core

-- One direct engine subscription per event name, evaluated once per process.
-- A debugger reload of this file must not add a second listener; the handler
-- lists in Core._state survive the reload and stay attached to this dispatcher.
if not state.subscribed then
    state.subscribed = true
    Events.OnTick.Add(function()
        state.tick = state.tick + 1
        dispatch("OnTick", state.tick)
    end)
    Events.OnClientCommand.Add(function(module, command, player, args)
        dispatch("OnClientCommand", module, command, player, args)
    end)
    Events.OnProcessAction.Add(function(action, player, args)
        dispatch("OnProcessAction", action, player, args)
    end)
    Events.OnObjectAdded.Add(function(object)
        dispatch("OnObjectAdded", object)
    end)
    Events.OnObjectAboutToBeRemoved.Add(function(object)
        dispatch("OnObjectAboutToBeRemoved", object)
    end)
    Events.OnDestroyIsoThumpable.Add(function(object)
        dispatch("OnDestroyIsoThumpable", object)
    end)
end

return Core
