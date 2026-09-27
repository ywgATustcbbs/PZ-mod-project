-- Client power panel. All displayed values come from server snapshots;
-- inventory/world changes are operation requests validated by the server.
require("ISUI/ISCollapsableWindow")
require("ISUI/ISButton")
require("ISUI/ISLabel")
require("ISUI/ISProgressBar")
require("ISUI/ISContextMenu")

local Client = require("RailroaderRV/RV_UtilityClient")
local U = require("RailroaderRV/RV_UtilityConstants")
RailroaderRV = RailroaderRV or {}
RailroaderRV.UtilityDashboard = RailroaderRV.UtilityDashboard or {}
local Dashboard = RailroaderRV.UtilityDashboard

local function tr(key, fallback)
    local translated = type(getText) == "function" and getText(key) or nil
    return translated and translated ~= key and translated ~= ""
        and translated or fallback
end

local function number(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) end
    return nil
end

local function display(value, digits)
    local numeric = number(value)
    if numeric == nil then return value == nil and "-" or tostring(value) end
    return string.format("%." .. tostring(digits or 1) .. "f", numeric)
end

local function ratio(amount, capacity)
    amount, capacity = number(amount), number(capacity)
    if not amount or not capacity or capacity <= 0 then return 0 end
    return math.max(0, math.min(1, amount / capacity))
end

local function mappingKey(value)
    if type(value) ~= "table" or value.rvId == nil
        or value.generation == nil or value.bitmapVersion == nil then return nil end
    return tostring(value.rvId) .. ":" .. tostring(value.generation) .. ":"
        .. tostring(value.bitmapVersion)
end

local function utilityMapping()
    local rv = rawget(_G, "RailroaderRV")
    local menu = rv and rv.RailroaderContextMenu
    if menu and type(menu.getUtilityMapping) == "function" then
        return menu.getUtilityMapping()
    end
    return nil
end

local function collectionItems(collection)
    local result = {}
    if not collection then return result end
    if type(collection.size) == "function" and type(collection.get) == "function" then
        local ok, size = pcall(function() return collection:size() end)
        if ok and type(size) == "number" then
            for index = 0, size - 1 do
                local itemOk, item = pcall(function() return collection:get(index) end)
                if itemOk and item then result[#result + 1] = item end
            end
        end
    elseif type(collection) == "table" then
        for _, item in pairs(collection) do
            if item then result[#result + 1] = item end
        end
    end
    return result
end

local function inventoryItems(inventory, result, seen)
    if not inventory or seen[inventory] then return end
    seen[inventory] = true
    local ok, collection = pcall(function() return inventory:getItems() end)
    if not ok then return end
    for _, item in ipairs(collectionItems(collection)) do
        result[#result + 1] = item
        local methodOk, getInventory = pcall(function() return item.getInventory end)
        if methodOk and type(getInventory) == "function" then
            local nestedOk, nested = pcall(function() return item:getInventory() end)
            if nestedOk and nested then inventoryItems(nested, result, seen) end
        end
    end
end

local function itemType(item)
    local ok, value = pcall(function() return item:getFullType() end)
    return ok and tostring(value or "") or ""
end

local function itemName(item)
    local ok, value = pcall(function() return item:getName() end)
    return ok and tostring(value or itemType(item)) or itemType(item)
end

local function fluidFuel(item)
    local ok, container = pcall(function() return item:getFluidContainer() end)
    local fluid = rawget(_G, "Fluid")
    if not ok or not container or not fluid or fluid.Petrol == nil then return nil end
    local containsOk, contains = pcall(function() return container:contains(fluid.Petrol) end)
    local amountOk, amount = pcall(function() return container:getAmount() end)
    amount = amountOk and number(amount) or nil
    return containsOk and contains == true and amount and amount > 0 and amount or nil
end

local function batteryType(fullType)
    return fullType == "Base.CarBattery" or fullType == "Base.CarBattery1"
        or fullType == "Base.CarBattery2" or fullType == "Base.CarBattery3"
end

local function setSubmitted(window, sent)
    window.operationStatus = sent
        and tr("UI_RailroaderRVTest_Utility_Submitted", "Submitted; waiting for server")
        or tr("UI_RailroaderRVTest_Utility_Rejected", "Request could not be sent")
    window:setStatus(window.operationStatus)
end

local Window
if ISCollapsableWindow then
    Window = ISCollapsableWindow:derive("RVUtilityDashboardWindow")

    function Window:createChildren()
        ISCollapsableWindow.createChildren(self)
        local left = 16
        local width = self:getWidth() - 32
        local top = self:titleBarHeight() + 10
        local fontHeight = getTextManager():getFontHeight(UIFont.Small)
        local function label(x, y, w, value)
            local control = ISLabel:new(x, y, fontHeight, value, 1, 1, 1, 1,
                UIFont.Small, true)
            control:initialise()
            control:setWidth(w)
            self:addChild(control)
            return control
        end
        local function bar(y, color)
            local control = ISProgressBar:new(left, y, width, 18, nil, UIFont.Small)
            control:initialise()
            control.progressColor = color
            self:addChild(control)
            return control
        end
        self.statusLabel = label(left, top, width,
            tr("UI_RailroaderRVTest_Utility_Waiting", "Waiting for server snapshot"))
        top = top + fontHeight + 5
        self.fuelLabel = label(left, top, width, "Fuel: -")
        top = top + fontHeight + 2
        self.fuelBar = bar(top, { r = 1.0, g = 0.65, b = 0.15, a = 1 })
        top = top + 23
        self.batteryLabel = label(left, top, width, "Battery: -")
        top = top + fontHeight + 2
        self.batteryBar = bar(top, { r = 0.2, g = 0.75, b = 0.35, a = 1 })
        top = top + 22
        self.powerLabel = label(left, top, width, "Power: -")
        top = top + fontHeight + 3
        self.limitsLabel = label(left, top, width, "Limits: -")
        top = top + fontHeight + 3
        self.efficiencyLabel = label(left, top, width, "Efficiency: -")
        top = top + fontHeight + 3
        self.enduranceLabel = label(left, top, width, "Estimated runtime: -")
        top = top + fontHeight + 3
        self.deviceLabel = label(left, top, width, "Devices: -")
        top = top + fontHeight + 3
        self.batteryListLabel = label(left, top, width, "Battery pack: -")
        top = top + fontHeight + 9

        local gap = 6
        local buttonWidth = math.floor((width - gap * 2) / 3)
        local buttonHeight = 28
        local buttons = {
            { "AddFuel", Window.onAddFuel },
            { "GeneratorToggle", Window.onGeneratorToggle },
            { "AddBattery", Window.onAddBattery },
            { "RemoveBattery", Window.onRemoveBattery },
            { "InstallCharger", Window.onInstallCharger },
            { "RemoveCharger", Window.onRemoveCharger },
            { "InstallInverter", Window.onInstallInverter },
            { "RemoveInverter", Window.onRemoveInverter },
            { "RefreshDevices", Window.onRefreshDevices },
        }
        local defaults = {
            AddFuel = "Add fuel", GeneratorToggle = "Start / stop generator",
            AddBattery = "Add battery", RemoveBattery = "Remove battery",
            InstallCharger = "Install charger", RemoveCharger = "Remove charger",
            InstallInverter = "Install inverter", RemoveInverter = "Remove inverter",
            RefreshDevices = "刷新用电设备",
        }
        for index, entry in ipairs(buttons) do
            local row = math.floor((index - 1) / 3)
            local column = (index - 1) % 3
            local key = entry[1]
            local button = ISButton:new(left + column * (buttonWidth + gap),
                top + row * (buttonHeight + gap), buttonWidth, buttonHeight,
                tr("UI_RailroaderRVTest_Utility_" .. key, defaults[key]), self, entry[2])
            button:initialise()
            button.displayBackground = true
            self:addChild(button)
            if key == "GeneratorToggle" then self.generatorButton = button end
        end
    end

    function Window:setStatus(value)
        if self.statusLabel then self.statusLabel:setNameWithoutMoving(tostring(value)) end
    end

    function Window:request(operation)
        setSubmitted(self, Client.requestPowerOperation(self.player, operation))
    end

    function Window:openInventoryMenu(predicate, callback, emptyLabel)
        local player = self.player
        local contextClass = rawget(_G, "ISContextMenu")
        if not player or not contextClass or type(contextClass.get) ~= "function" then
            self:setStatus("Unable to open item menu")
            return
        end
        local inventoryOk, inventory = pcall(function() return player:getInventory() end)
        if not inventoryOk or not inventory then self:setStatus("Inventory unavailable"); return end
        local items = {}
        inventoryItems(inventory, items, {})
        local menu = contextClass.get(player:getPlayerNum(), self:getAbsoluteX() + 20,
            self:getAbsoluteY() + self:getHeight() - 36)
        if not menu then self:setStatus("Unable to open item menu"); return end
        local count = 0
        for _, item in ipairs(items) do
            if predicate(item) then
                count = count + 1
                local candidate = item
                menu:addOption(itemName(item), self, function(window)
                    setSubmitted(window, callback(window.player, candidate))
                end)
            end
        end
        if count == 0 then
            local option = menu:addOption(emptyLabel)
            option.notAvailable = true
        end
    end

    function Window:openBatteryRemovalMenu()
        local contextClass = rawget(_G, "ISContextMenu")
        local snapshot = Client.getSnapshot and Client.getSnapshot() or nil
        local batteries = snapshot and snapshot.power and snapshot.power.batteries or nil
        if not contextClass or type(contextClass.get) ~= "function" then return end
        local menu = contextClass.get(self.player:getPlayerNum(), self:getAbsoluteX() + 20,
            self:getAbsoluteY() + self:getHeight() - 36)
        if not menu then return end
        local count = 0
        for _, battery in ipairs(batteries or {}) do
            count = count + 1
            local id = battery.id
            local label = "#" .. tostring(id) .. "  " .. tostring(battery.fullType)
                .. "  " .. display(battery.condition, 0) .. "/"
                .. display(battery.maxCondition, 0)
            menu:addOption(label, self, function(window)
                setSubmitted(window,
                    Client.requestRemoveBattery(window.player, id))
            end)
        end
        if count == 0 then
            local option = menu:addOption(tr("UI_RailroaderRVTest_Utility_NoBatteries",
                "No installed batteries"))
            option.notAvailable = true
        end
    end

    function Window:onAddFuel()
        self:openInventoryMenu(function(item) return fluidFuel(item) ~= nil end,
            function(player, item) return Client.requestAddFuel(player, item) end,
            tr("UI_RailroaderRVTest_Utility_NoFuel", "No usable fuel"))
    end

    function Window:onAddBattery()
        self:openInventoryMenu(function(item) return batteryType(itemType(item)) end,
            function(player, item) return Client.requestAddBattery(player, item) end,
            tr("UI_RailroaderRVTest_Utility_NoBatteries", "No batteries in inventory"))
    end

    function Window:onRemoveBattery()
        self:openBatteryRemovalMenu()
    end

    function Window:onInstallCharger()
        self:openInventoryMenu(function(item)
            return itemType(item) == "RailroaderRVTest.RVCharger"
        end, function(player, item)
            return Client.requestInstallComponent(player, U.OP_INSTALL_CHARGER, item)
        end, tr("UI_RailroaderRVTest_Utility_NoCharger", "No RV charger in inventory"))
    end

    function Window:onInstallInverter()
        self:openInventoryMenu(function(item)
            return itemType(item) == "RailroaderRVTest.RVInverter"
        end, function(player, item)
            return Client.requestInstallComponent(player, U.OP_INSTALL_INVERTER, item)
        end, tr("UI_RailroaderRVTest_Utility_NoInverter", "No inverter in inventory"))
    end

    function Window:onRemoveCharger()
        self:request(U.OP_REMOVE_CHARGER)
    end

    function Window:onRemoveInverter()
        self:request(U.OP_REMOVE_INVERTER)
    end

    function Window:onGeneratorToggle()
        local snapshot = Client.getSnapshot and Client.getSnapshot() or nil
        local power = snapshot and snapshot.power or {}
        self:request(power.generatorEnabled == true
            and U.OP_STOP_GENERATOR or U.OP_START_GENERATOR)
    end

    function Window:onRefreshDevices()
        setSubmitted(self, Client.requestRefreshDevices(self.player))
    end

    function Window:refresh(snapshot)
        local candidate = snapshot
        if candidate == nil and Client.getSnapshot then candidate = Client.getSnapshot() end
        if mappingKey(candidate) ~= self.mappingKey then candidate = nil end
        local power = type(candidate) == "table" and candidate.power or nil
        if type(power) ~= "table" then
            if not self.operationStatus then
                self:setStatus(tr("UI_RailroaderRVTest_Utility_Waiting",
                    "Waiting for server snapshot"))
            end
            self.fuelLabel:setNameWithoutMoving(
                tr("UI_RailroaderRVTest_Utility_Fuel", "Fuel") .. ": -")
            self.batteryLabel:setNameWithoutMoving(
                tr("UI_RailroaderRVTest_Utility_Battery", "Battery") .. ": -")
            self.powerLabel:setNameWithoutMoving(
                tr("UI_RailroaderRVTest_Utility_Generator", "Generator") .. ": -")
            self.limitsLabel:setNameWithoutMoving(
                tr("UI_RailroaderRVTest_Utility_Limits", "Max charge / discharge") .. ": -")
            self.efficiencyLabel:setNameWithoutMoving(
                tr("UI_RailroaderRVTest_Utility_Efficiency", "Charger / inverter") .. ": -")
            self.enduranceLabel:setNameWithoutMoving(
                tr("UI_RailroaderRVTest_Utility_Endurance", "Estimated runtime") .. ": -")
            self.deviceLabel:setNameWithoutMoving(
                tr("UI_RailroaderRVTest_Utility_Devices", "Cached devices") .. ": -")
            self.batteryListLabel:setNameWithoutMoving(
                tr("UI_RailroaderRVTest_Utility_BatteryList", "Batteries") .. ": -")
            self.fuelBar:setProgress(0)
            self.fuelBar:setText("-")
            self.batteryBar:setProgress(0)
            self.batteryBar:setText("-")
            return
        end
        local fuelCapacity = U.POWER.VIRTUAL_FUEL_CAPACITY_L
        local fuelFraction = ratio(power.virtualFuelL, fuelCapacity)
        self.fuelLabel:setNameWithoutMoving(
            tr("UI_RailroaderRVTest_Utility_Fuel", "Fuel") .. ": "
            .. display(power.virtualFuelL) .. " / " .. display(fuelCapacity, 0) .. " L")
        self.fuelBar:setProgress(fuelFraction)
        self.fuelBar:setText(string.format("%.0f%%", fuelFraction * 100))
        local batteryFraction = ratio(power.batteryWh, power.batteryCapacityWh)
        self.batteryLabel:setNameWithoutMoving(
            tr("UI_RailroaderRVTest_Utility_Battery", "Battery") .. ": "
            .. display(power.batteryWh, 0) .. " / "
            .. display(power.batteryCapacityWh, 0) .. " Wh  ("
            .. display((power.batteryWh or 0) / 1000, 2) .. " kWh)")
        self.batteryBar:setProgress(batteryFraction)
        self.batteryBar:setText(string.format("%.0f%%", batteryFraction * 100))
        local running = power.generatorEnabled == true
            and tr("UI_RailroaderRVTest_Utility_Running", "Running")
            or tr("UI_RailroaderRVTest_Utility_Stopped", "Stopped")
        local proxy = power.proxyActive == true
            and tr("UI_RailroaderRVTest_Utility_ProxyOn", "proxy on")
            or tr("UI_RailroaderRVTest_Utility_ProxyOff", "proxy off")
        self.powerLabel:setNameWithoutMoving(
            tr("UI_RailroaderRVTest_Utility_Generator", "Generator") .. ": " .. running
            .. " / " .. tr("UI_RailroaderRVTest_Utility_Circuit", "Circuit") .. ": "
            .. tostring(power.circuitState or "-") .. " (" .. proxy .. ")  "
            .. tr("UI_RailroaderRVTest_Utility_Load", "Load") .. " "
            .. display(power.currentLoadW, 0) .. " W  "
            .. tr("UI_RailroaderRVTest_Utility_Generation", "Generation") .. " "
            .. display(power.generationPowerW, 0) .. " W")
        self.limitsLabel:setNameWithoutMoving(
            tr("UI_RailroaderRVTest_Utility_Limits", "Max charge / discharge") .. ": "
            .. display(power.maxChargePowerW, 0) .. " / "
            .. display(power.maxDischargePowerW, 0) .. " W")
        self.efficiencyLabel:setNameWithoutMoving(
            tr("UI_RailroaderRVTest_Utility_Efficiency", "Charger / inverter") .. ": "
            .. display((power.chargerEfficiency or 0) * 100, 0) .. "% / "
            .. display((power.inverterEfficiency or 0) * 100, 0) .. "%")
        local loadW, inverterEfficiency = number(power.currentLoadW),
            number(power.inverterEfficiency)
        local batteryWh = number(power.batteryWh)
        local hours = loadW and inverterEfficiency and batteryWh and loadW > 0
            and inverterEfficiency > 0 and batteryWh / (loadW / inverterEfficiency) or nil
        self.enduranceLabel:setNameWithoutMoving(
            tr("UI_RailroaderRVTest_Utility_Endurance", "Estimated runtime") .. ": "
            .. (hours and display(hours, 1) .. " h"
                or tr("UI_RailroaderRVTest_Utility_NoLoad", "No active load")))
        self.deviceLabel:setNameWithoutMoving(
            tr("UI_RailroaderRVTest_Utility_Devices", "Cached devices") .. ": "
            .. tostring(power.deviceCount or 0))
        local batteries, labels = power.batteries or {}, {}
        for _, battery in ipairs(batteries) do
            labels[#labels + 1] = "#" .. tostring(battery.id) .. " "
                .. tostring(battery.fullType) .. " " .. display(battery.condition, 0)
                .. "/" .. display(battery.maxCondition, 0)
        end
        self.batteryListLabel:setNameWithoutMoving(
            tr("UI_RailroaderRVTest_Utility_BatteryList", "Batteries") .. ": "
            .. (#labels > 0 and table.concat(labels, "; ")
                or tr("UI_RailroaderRVTest_Utility_NoBatteries", "None")))
        if self.generatorButton then
            self.generatorButton:setTitle(power.generatorEnabled == true
                and tr("UI_RailroaderRVTest_Utility_StopGenerator", "Stop generator")
                or tr("UI_RailroaderRVTest_Utility_StartGenerator", "Start generator"))
        end
        if not self.operationStatus then
            self:setStatus(tr("UI_RailroaderRVTest_Utility_Updated",
                "Server snapshot updated"))
        end
    end

    function Window:close()
        self:setVisible(false)
        if Dashboard.instance == self then Dashboard.instance = nil end
    end

    function Window:new(x, y, player)
        local o = ISCollapsableWindow:new(x, y, 620, 500)
        setmetatable(o, self)
        self.__index = self
        o.player = player
        o.mappingKey = mappingKey(utilityMapping())
        o.operationStatus = nil
        o:setResizable(false)
        o:setTitle(tr("UI_RailroaderRVTest_Utility_Title", "RV power panel"))
        return o
    end
end

function Dashboard.format(snapshot)
    local power = snapshot and snapshot.power or nil
    if type(power) ~= "table" then
        return tr("UI_RailroaderRVTest_Utility_Waiting", "Waiting for server snapshot")
    end
    return tr("UI_RailroaderRVTest_Utility_Battery", "Battery") .. " "
        .. display(power.batteryWh, 0) .. " / " .. display(power.batteryCapacityWh, 0)
        .. " Wh"
end

function Dashboard.refresh(snapshot)
    if Dashboard.instance and type(Dashboard.instance.refresh) == "function" then
        Dashboard.instance:refresh(snapshot)
    end
end

function Dashboard.onConnectionReset()
    local instance = Dashboard.instance
    Dashboard.instance = nil
    if not instance then return end
    instance:setVisible(false)
    instance:removeFromUIManager()
end

local function localPlayer(player)
    if player then return player end
    if type(getSpecificPlayer) ~= "function" then return nil end
    local ok, value = pcall(getSpecificPlayer, 0)
    return ok and value or nil
end

function Dashboard.show(player)
    player = localPlayer(player)
    if not Window or not player then return false end
    if Dashboard.instance then
        if Dashboard.instance:getIsVisible() then Dashboard.instance:bringToTop() end
        Dashboard.instance.player = player
        Dashboard.instance.mappingKey = mappingKey(utilityMapping())
        Dashboard.instance:setVisible(true)
        Dashboard.instance:refresh()
        return true
    end
    local core = getCore()
    local screenWidth, screenHeight = core:getScreenWidth(), core:getScreenHeight()
    local window = Window:new((screenWidth - 620) / 2, (screenHeight - 500) / 2, player)
    window:initialise()
    window:addToUIManager()
    Dashboard.instance = window
    window:refresh()
    return true
end

function Dashboard.onSnapshot(player, snapshot)
    local instance = Dashboard.instance
    if not instance or not instance:getIsVisible() or instance.player ~= player then return false end
    local snapshotKey = mappingKey(snapshot)
    if not snapshotKey or snapshotKey ~= instance.mappingKey then return false end
    instance.operationStatus = nil
    Dashboard.refresh(snapshot)
    return true
end

function Dashboard.onAck(player, ack)
    local instance = Dashboard.instance
    if not instance or not instance:getIsVisible() or instance.player ~= player
        or type(ack) ~= "table" then return end
    if ack.ok == true then
        instance.operationStatus = tr("UI_RailroaderRVTest_Utility_Confirmed",
            "Operation confirmed; refreshing values")
    else
        instance.operationStatus = tr("UI_RailroaderRVTest_Utility_Rejected",
            "Operation rejected") .. ": " .. tostring(ack.reason or "unknown")
    end
    instance:setStatus(instance.operationStatus)
end

return Dashboard
