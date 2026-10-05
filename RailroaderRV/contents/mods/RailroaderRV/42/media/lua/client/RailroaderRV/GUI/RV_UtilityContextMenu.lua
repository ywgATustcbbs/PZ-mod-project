-- Client-side utility menu hooks.  Every option submits intent only; the
-- server resolves the player, RV, object, tool, identity and FluidContainer.

local Client = require("RailroaderRV/GUI/RV_UtilityClient")
local Dashboard = require("RailroaderRV/GUI/RV_UtilityDashboard")
local Catalog = require("RailroaderRV/Water/RV_UtilityCatalog")
require("RailroaderRV/Common/RV_Constants")
local RegionSlots = require("RailroaderRV/RVMapping/RV_RegionSlots")

RailroaderRV = RailroaderRV or {}
RailroaderRV.UtilityContextMenu = RailroaderRV.UtilityContextMenu or {}
local Menu = RailroaderRV.UtilityContextMenu
local C = RailroaderRV.Constants
local ICON_UTILITY_DASHBOARD = "media/ui/RailroaderRV/managementpannel.png"

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

function Menu.openDashboard(player)
    Dashboard.show(player)
end

local function hasPipeWrench(player)
    if not player or type(player.getInventory) ~= "function" then return false end
    local ok, inventory = pcall(player.getInventory, player)
    if not ok or not inventory or type(inventory.contains) ~= "function" then return false end
    local containsOk, contains = pcall(inventory.contains, inventory, "Base.PipeWrench")
    return containsOk and contains == true
end

local function setWaterConnection(player, object, connected)
    return Client.requestWaterConnection(player, object, connected) == true
end

local function localSlot(player, x, y, z)
    local pxOk, px = pcall(player.getX, player)
    local pyOk, py = pcall(player.getY, player)
    local pzOk, pz = pcall(player.getZ, player)
    if not pxOk or not pyOk or not pzOk
        or type(px) ~= "number" or type(py) ~= "number" or type(pz) ~= "number" then
        return nil
    end
    for slotIndex = 1, RegionSlots.COUNT do
        local region = RegionSlots.indexToRegion(slotIndex)
        local anchor = RegionSlots.indexToAnchor(slotIndex)
        if region and anchor and px >= region.minX and px < region.maxX
            and py >= region.minY and py < region.maxY
            and pz >= anchor.z + C.RV_MANAGED_MIN_Z_OFFSET
            and pz < anchor.z + C.RV_MANAGED_MAX_Z_OFFSET
            and x >= region.minX and x < region.maxX
            and y >= region.minY and y < region.maxY
            and z >= anchor.z + C.RV_MANAGED_MIN_Z_OFFSET
            and z < anchor.z + C.RV_MANAGED_MAX_Z_OFFSET then
            return slotIndex
        end
    end
    return nil
end

local function addWaterOptions(player, context, worldObjects)
    if not hasPipeWrench(player) then return end
    local seen = {}
    for _, object in pairs(worldObjects or {}) do
        if object and Catalog.hasFluidContainer(object) then
            local squareOk, square = pcall(object.getSquare, object)
            local xOk, x, yOk, y, zOk, z = false, nil, false, nil, false, nil
            if squareOk and square then
                xOk, x = pcall(square.getX, square)
                yOk, y = pcall(square.getY, square)
                zOk, z = pcall(square.getZ, square)
            end
            local key = xOk and yOk and zOk
                and tostring(x) .. ":" .. tostring(y) .. ":" .. tostring(z) or nil
            local stateOk, connected = pcall(object.getUsesExternalWaterSource, object)
            local slotIndex = key and localSlot(player, x, y, z) or nil
            local tagged = Catalog.hasSinkIdentity(object)
            local currentTag = Catalog.isCurrentWaterSink(object)
            local identity = Catalog.readSinkIdentity(object)
            local validTagForSlot = not tagged or (currentTag and identity
                and identity.slotIndex == slotIndex)
            if key and slotIndex and not seen[key] and validTagForSlot
                and stateOk and type(connected) == "boolean"
                and (connected or Catalog.isWaterPipedDevice(object)) then
                seen[key] = true
                local label = connected
                    and text("ContextMenu_RailroaderRV_DisconnectWaterSink",
                        "Disconnect sink from water")
                    or text("ContextMenu_RailroaderRV_ConnectWaterSink",
                        "Connect sink to water")
                if not already(context, label) then
                    context:addOption(label, player, setWaterConnection, object,
                        not connected)
                end
            end
        end
    end
end

local function addDashboardOption(player, context)
    local rv = rawget(_G, "RailroaderRV")
    local railroader = rv and rv.RailroaderContextMenu
    local candidate = railroader
        and type(railroader.hasUtilityDashboardCandidate) == "function"
    local candidateOk = false
    if candidate then
        local ok, value = pcall(railroader.hasUtilityDashboardCandidate,
            player, true)
        candidateOk = ok and value == true
    end
    if not candidateOk then return end
    local label = text("ContextMenu_RailroaderRV_UtilityDashboard",
        "RV utility panel")
    if not already(context, label) then
        local option = context:addOption(label, player, Menu.openDashboard)
        option.iconTexture = getTexture(ICON_UTILITY_DASHBOARD)
    end
end

function Menu.onPreFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if not context then return end
    local player = localPlayer(playerNum)
    if player then
        addDashboardOption(player, context)
    end
end

function Menu.onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if not context or type(worldObjects) ~= "table" then return end
    local player = localPlayer(playerNum)
    if not player then return end
    addDashboardOption(player, context)
    addWaterOptions(player, context, worldObjects)
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
                local label = text("ContextMenu_RailroaderRV_AddFuel",
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
