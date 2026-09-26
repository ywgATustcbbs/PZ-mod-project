-- Client-side utility menu hooks.  Every option submits intent only; the
-- server resolves the player, RV, object, tool, identity and FluidContainer.

local U = require("RailroaderRV/RV_UtilityConstants")
local Client = require("RailroaderRV/RV_UtilityClient")
local Dashboard = require("RailroaderRV/RV_UtilityDashboard")

RailroaderRV = RailroaderRV or {}
RailroaderRV.UtilityContextMenu = RailroaderRV.UtilityContextMenu or {}
local Menu = RailroaderRV.UtilityContextMenu
local C = RailroaderRV.Constants

local function text(key, fallback)
    local value = fallback
    if type(getText) == "function" then
        local ok, translated = pcall(getText, key)
        if ok and translated and translated ~= key and translated ~= "" then
            value = translated
        end
    end
    return value
end

local function localPlayer(playerNum)
    if type(getSpecificPlayer) ~= "function" then return nil end
    local ok, player = pcall(getSpecificPlayer, playerNum)
    return ok and player or nil
end

local function generatorCandidate(object)
    if not object or type(object.getModData) ~= "function" then return false end
    local ok, data = pcall(function() return object:getModData() end)
    local tag = ok and type(data) == "table" and data.RailroaderRVTest or nil
    return type(tag) == "table" and tag.role == "generator"
end

local function already(context, label)
    if not context or type(context.options) ~= "table" then return false end
    local count = context.numOptions or #context.options
    for i = 1, count do
        local option = context.options[i]
        if type(option) == "table" and (option.name == label or option.label == label) then
            return true
        end
    end
    return false
end

local function addFuelOption(player, item)
    Client.requestAddFuel(player, item)
end

local function generatorOption(player, object, operation)
    Client.requestGenerator(player, operation, object)
end

local function dashboardOption(player)
    Dashboard.show(player)
    Client.requestSnapshot(player)
end

local function addDashboardOption(player, context)
    local rv = rawget(_G, "RailroaderRV")
    local railroader = rv and rv.RailroaderContextMenu
    local candidate = railroader
        and type(railroader.hasUtilityDashboardCandidate) == "function"
    local candidateOk = false
    if candidate then
        local ok, value = pcall(railroader.hasUtilityDashboardCandidate, player)
        candidateOk = ok and value == true
    end
    if not candidateOk then return end
    local label = text("ContextMenu_RailroaderRVTest_UtilityDashboard",
        "RV utility panel")
    if not already(context, label) then
        context:addOption(label, player, dashboardOption)
    end
end

function Menu.onPreFillWorldObjectContextMenu(playerNum, context)
    if not context then return end
    local player = localPlayer(playerNum)
    if player then addDashboardOption(player, context) end
end

function Menu.onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if not context or type(worldObjects) ~= "table" then return end
    local player = localPlayer(playerNum)
    if not player then return end
    addDashboardOption(player, context)
    for _, object in pairs(worldObjects) do
        if generatorCandidate(object) then
            local options = {
                { label = "Connect RV generator", operation = U.OP_CONNECT_GENERATOR },
                { label = "Start RV generator", operation = U.OP_START_GENERATOR },
                { label = "Stop RV generator", operation = U.OP_STOP_GENERATOR },
                { label = "Repair RV generator", operation = U.OP_REPAIR_GENERATOR },
            }
            for _, option in ipairs(options) do
                if not already(context, option.label) then
                    context:addOption(option.label, player, generatorOption,
                        object, option.operation)
                end
            end
            if test and ISWorldObjectContextMenu
                and type(ISWorldObjectContextMenu.setTest) == "function" then
                pcall(ISWorldObjectContextMenu.setTest)
            end
            return
        end
    end
end

function Menu.onFillInventoryObjectContextMenu(playerNum, context, items)
    if not context or type(items) ~= "table" then return end
    local player = localPlayer(playerNum)
    if not player then return end
    for _, item in pairs(items) do
        local container
        if item and type(item.getFluidContainer) == "function" then
            local ok, value = pcall(function() return item:getFluidContainer() end)
            if ok then container = value end
        end
        if container then
            local fluid = rawget(_G, "Fluid")
            local fuelOk = fluid and fluid.Petrol ~= nil
                and type(container.contains) == "function"
            if fuelOk then
                local called, containsFuel = pcall(function()
                    return container:contains(fluid.Petrol)
                end)
                fuelOk = called and containsFuel == true
            end
            if fuelOk then
                local label = text("ContextMenu_RailroaderRVTest_AddFuel",
                    "Add fuel to RV")
                if not already(context, label) then
                    context:addOption(label, player, addFuelOption, item)
                end
            end
            if fuelOk then return end
        end
    end
end

if Events and Events.OnPreFillWorldObjectContextMenu
    and type(Events.OnPreFillWorldObjectContextMenu.Add) == "function" then
    Events.OnPreFillWorldObjectContextMenu.Add(Menu.onPreFillWorldObjectContextMenu)
end
if Events and Events.OnFillWorldObjectContextMenu
    and type(Events.OnFillWorldObjectContextMenu.Add) == "function" then
    Events.OnFillWorldObjectContextMenu.Add(Menu.onFillWorldObjectContextMenu)
end
if Events and Events.OnFillInventoryObjectContextMenu
    and type(Events.OnFillInventoryObjectContextMenu.Add) == "function" then
    Events.OnFillInventoryObjectContextMenu.Add(Menu.onFillInventoryObjectContextMenu)
end

return Menu
