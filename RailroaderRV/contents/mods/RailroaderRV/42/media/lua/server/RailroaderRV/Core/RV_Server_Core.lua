-- RailroaderRV server Core: the single owner of RV event subscriptions
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

local Core = RV.Core
if Core == nil then
    Core = {}
    RV.Core = Core
end

local state = Core._state
if state == nil then
    state = {
        tick = 0,
        tickCallbacks = {},
        commandCallbacks = {},
        scheduledCallbacks = {},
        subscribed = false,
    }
    Core._state = state
end

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
        error("RailroaderRV: unknown engine event " .. tostring(eventName), 0)
    end
    for index = 1, #callbacks do
        callbacks[index](...)
    end
end

local function on(eventName, callback)
    local callbacks = handlers[eventName]
    if type(callbacks) ~= "table" then
        error("RailroaderRV: unknown engine event " .. tostring(eventName), 0)
    end
    callbacks[#callbacks + 1] = callback
end

local function onTick(callback)
    on("OnTick", callback)
end

local function scheduleAtTick(targetTick, callback, ...)
    local arguments = { ... }
    state.scheduledCallbacks[#state.scheduledCallbacks + 1] = {
        targetTick = targetTick,
        callback = callback,
        arguments = arguments,
        argumentCount = select("#", ...),
    }
end

local function runScheduledCallbacks(now)
    local index = 1
    while index <= #state.scheduledCallbacks do
        local task = state.scheduledCallbacks[index]
        if tickReached(now, task.targetTick) then
            table.remove(state.scheduledCallbacks, index)
            task.callback(unpack(task.arguments, 1, task.argumentCount))
        else
            index = index + 1
        end
    end
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
Core.scheduleAtTick = scheduleAtTick
Core.onCommand = onCommand

RV.Core = Core

-- One direct engine subscription per event name, evaluated once per process.
-- A debugger reload of this file must not add a second listener; the handler
-- lists in Core._state survive the reload and stay attached to this dispatcher.
if state.subscribed == false then
    onTick(runScheduledCallbacks)
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
elseif state.subscribed ~= true then
    error("RailroaderRV: Core subscription state is invalid", 0)
end

return Core
