-- Read-only utility dashboard.  The context-menu entry below renders the
-- latest server snapshot as a short halo note; it never derives or submits
-- world state.

local Client = require("RailroaderRV/RV_UtilityClient")

RailroaderRV = RailroaderRV or {}
RailroaderRV.UtilityDashboard = RailroaderRV.UtilityDashboard or {}
local Dashboard = RailroaderRV.UtilityDashboard

local function text(value)
    return value == nil and "-" or tostring(value)
end

function Dashboard.read()
    local snapshot = Client.getSnapshot and Client.getSnapshot() or nil
    if type(snapshot) ~= "table" or type(snapshot.water) ~= "table" then
        return { available = false, label = "RV water unavailable" }
    end
    local water = snapshot.water
    return {
        available = true,
        rvId = snapshot.rvId,
        sharedAmount = water.sharedAmount,
        capacity = water.capacity,
        fluidProfile = water.fluidProfile,
        state = water.state,
        registry = water.registry,
        generator = snapshot.power,
        label = text(water.sharedAmount) .. " / " .. text(water.capacity),
    }
end

local function profileText(profile)
    if type(profile) ~= "table" then return "profile=-" end
    return "profile=" .. text(profile.kind) .. ":clean=" .. text(profile.cleanAmount)
        .. ":tainted=" .. text(profile.taintedAmount)
end

local function deviceText(registry)
    if type(registry) ~= "table" then return "devices=0" end
    local total, active, initializing = 0, 0, 0
    for _, entry in pairs(registry) do
        total = total + 1
        if type(entry) == "table" and entry.status == "ACTIVE" then
            active = active + 1
        elseif type(entry) == "table" and entry.status == "NEEDS_INIT" then
            initializing = initializing + 1
        end
    end
    return "devices=" .. tostring(total) .. ":active=" .. tostring(active)
        .. ":needsInit=" .. tostring(initializing)
end

local function generatorText(power)
    if type(power) ~= "table" or type(power.generator) ~= "table" then
        return "generator=unbound"
    end
    local native = power.native
    if type(native) ~= "table" then return "generator=bound" end
    return "generator=" .. text(native.active and "ON" or "OFF")
        .. ":fuel=" .. text(native.fuel) .. ":condition=" .. text(native.condition)
end

function Dashboard.format(value)
    value = value or Dashboard.read()
    if type(value) ~= "table" or value.available ~= true then
        return "RV utility unavailable"
    end
    return "RV water " .. value.label .. " state=" .. text(value.state)
        .. " " .. profileText(value.fluidProfile) .. " "
        .. deviceText(value.registry) .. " " .. generatorText(value.generator)
end

function Dashboard.show(player)
    if not player or type(player.setHaloNote) ~= "function" then return false end
    local ok = pcall(function()
        player:setHaloNote(Dashboard.format(), 255, 255, 255, 5000)
    end)
    return ok
end

return Dashboard
