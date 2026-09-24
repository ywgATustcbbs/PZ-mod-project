-- Client utility dashboard.
--
-- This is a normal in-world panel, not a halo notification.  Values are
-- display-only snapshots from the server; every button sends an operation
-- intent and an item id for server-side revalidation.

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
    local translated = getText(key)
    return translated and translated ~= key and translated ~= ""
        and translated or fallback
end

local function utilityMapping()
    local rv = rawget(_G, "RailroaderRV")
    local menu = rv and rv.RailroaderContextMenu
    if menu and type(menu.getUtilityMapping) == "function" then
        return menu.getUtilityMapping()
    end
    return nil
end

local function mappingKey(value)
    if type(value) ~= "table" then return nil end
    if value.rvId == nil or value.generation == nil or value.bitmapVersion == nil then
        return nil
    end
    return tostring(value.rvId) .. ":" .. tostring(value.generation) .. ":"
        .. tostring(value.bitmapVersion)
end

local function number(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) end
    return nil
end

local function text(value)
    local numeric = number(value)
    if numeric ~= nil then return string.format("%.1f", numeric) end
    return value == nil and "-" or tostring(value)
end

local function ratio(amount, capacity)
    amount, capacity = number(amount), number(capacity)
    if not amount or not capacity or capacity <= 0 then return 0 end
    return math.max(0, math.min(1, amount / capacity))
end

local function collectionItems(collection)
    local result = {}
    if not collection then return result end
    if type(collection.size) == "function" and type(collection.get) == "function" then
        for i = 0, collection:size() - 1 do
            local item = collection:get(i)
            if item then result[#result + 1] = item end
        end
        return result
    end
    if type(collection) == "table" then
        for _, item in pairs(collection) do
            if item then result[#result + 1] = item end
        end
    end
    return result
end

local function inventoryItems(inventory, result, seen)
    if not inventory or seen[inventory] then return end
    seen[inventory] = true
    local collection = inventory:getItems()
    for _, item in ipairs(collectionItems(collection)) do
        result[#result + 1] = item
        -- Most inventory items are not containers.  Calling a Java method
        -- which is absent on those userdata objects raises a RuntimeException
        -- in B42 and aborts the source-menu walk, so only invoke the nested
        -- inventory API when the item actually exposes it.
        local methodOk, getInventory = pcall(function()
            return item and item.getInventory
        end)
        if methodOk and type(getInventory) == "function" then
            local nested = item:getInventory()
            if nested then inventoryItems(nested, result, seen) end
        end
    end
end

local function fluidAmount(item, fluid)
    if not item or type(item.getFluidContainer) ~= "function" then return nil end
    local container = item:getFluidContainer()
    if not container or type(container.contains) ~= "function" then return nil end
    if container:contains(fluid) ~= true then return nil end
    local amount = number(container:getAmount())
    return amount and amount > (U.PROFILE_EPSILON or 0.000001) and amount or nil
end

local function itemLabel(item)
    if item and type(item.getName) == "function" then
        local name = item:getName()
        if name then return tostring(name) end
    end
    return "Item"
end

local function localPlayer(player)
    if player then return player end
    if type(getSpecificPlayer) ~= "function" then return nil end
    return getSpecificPlayer(0)
end

local Window = nil
if ISCollapsableWindow then
    Window = ISCollapsableWindow:derive("RVUtilityDashboardWindow")

    function Window:createChildren()
        ISCollapsableWindow.createChildren(self)
        local top = self:titleBarHeight() + 12
        local left = 16
        local width = self:getWidth() - 32
        local fontHeight = getTextManager():getFontHeight(UIFont.Small)
        local function addLabel(name, x, y, w, h)
            local label = ISLabel:new(x, y, h or fontHeight, name, 1, 1, 1, 1,
                UIFont.Small, true)
            label:initialise()
            label:setWidth(w or width)
            self:addChild(label)
            return label
        end
        local function addBar(x, y, w, h, color)
            local bar = ISProgressBar:new(x, y, w, h, nil, UIFont.Small)
            bar:initialise()
            bar.progressColor = color
            self:addChild(bar)
            return bar
        end
        self.statusLabel = addLabel(tr("UI_RailroaderRVTest_Utility_Waiting",
            "Waiting for server snapshot"), left, top, width)
        top = top + fontHeight + 10
        self.waterLabel = addLabel(tr("UI_RailroaderRVTest_Utility_Water", "Water tank")
            .. ": - / - L", left, top, width)
        top = top + fontHeight + 4
        self.waterBar = addBar(left, top, width, 20, { r = 0.20, g = 0.65, b = 1.0, a = 1 })
        top = top + 32
        self.fuelLabel = addLabel(tr("UI_RailroaderRVTest_Utility_Fuel", "Fuel")
            .. ": - / - L", left, top, width)
        top = top + fontHeight + 4
        self.fuelBar = addBar(left, top, width, 20, { r = 1.0, g = 0.65, b = 0.15, a = 1 })
        top = top + 32
        self.powerLabel = addLabel(tr("UI_RailroaderRVTest_Utility_Generator",
            "Generator") .. ": -", left, top, width)
        top = top + fontHeight + 4
        self.deviceLabel = addLabel(tr("UI_RailroaderRVTest_Utility_Devices",
            "Water devices") .. ": -", left, top, width)
        top = top + fontHeight + 14
        local buttonWidth = math.floor((width - 12) / 3)
        self.waterButton = ISButton:new(left, top, buttonWidth, 28,
            tr("UI_RailroaderRVTest_Utility_AddWater", "Add water"), self,
            Window.onAddWater)
        self.waterButton:initialise()
        self.waterButton.displayBackground = true
        self:addChild(self.waterButton)
        self.fuelButton = ISButton:new(left + buttonWidth + 6, top, buttonWidth, 28,
            tr("UI_RailroaderRVTest_Utility_AddFuel", "Add fuel"), self, Window.onAddFuel)
        self.fuelButton:initialise()
        self.fuelButton.displayBackground = true
        self:addChild(self.fuelButton)
        self.refreshButton = ISButton:new(left + (buttonWidth + 6) * 2, top, buttonWidth,
            28, tr("UI_RailroaderRVTest_Utility_Refresh", "Refresh"), self,
            Window.onRefresh)
        self.refreshButton:initialise()
        self.refreshButton.displayBackground = true
        self:addChild(self.refreshButton)
    end

    function Window:setStatus(value)
        if self.statusLabel then self.statusLabel:setNameWithoutMoving(tostring(value)) end
    end

    function Window:refresh(snapshot)
        local candidate = snapshot
        if candidate == nil and Client.getSnapshot then candidate = Client.getSnapshot() end
        if mappingKey(candidate) ~= self.mappingKey then candidate = nil end
        local value = Dashboard.read(candidate)
        if not value.available then
            if not self.operationStatus then
                self:setStatus(tr("UI_RailroaderRVTest_Utility_Waiting",
                    "Waiting for server snapshot"))
            end
            self.waterLabel:setNameWithoutMoving(
                tr("UI_RailroaderRVTest_Utility_Water", "Water tank")
                .. ": - / - L")
            self.fuelLabel:setNameWithoutMoving(
                tr("UI_RailroaderRVTest_Utility_Fuel", "Fuel") .. ": - / - L")
            self.powerLabel:setNameWithoutMoving(
                tr("UI_RailroaderRVTest_Utility_Generator", "Generator") .. ": -")
            self.deviceLabel:setNameWithoutMoving(
                tr("UI_RailroaderRVTest_Utility_Devices", "Water devices") .. ": -")
            self.waterBar:setProgress(0)
            self.waterBar:setText("0%")
            self.fuelBar:setProgress(0)
            self.fuelBar:setText("0%")
            return
        end
        local water = value.water
        local canonical = water.canonicalTank or {}
        local amount, capacity = number(canonical.amount) or 0,
            number(canonical.capacity) or 0
        self.waterLabel:setNameWithoutMoving(
            tr("UI_RailroaderRVTest_Utility_Water", "Water tank") .. ": "
            .. text(amount) .. " / " .. text(capacity) .. " L")
        self.waterBar:setProgress(ratio(amount, capacity))
        self.waterBar:setText(string.format("%.0f%%", ratio(amount, capacity) * 100))
        local native = value.generator and value.generator.native or nil
        local fuel = native and number(native.fuel) or nil
        local fuelCapacity = native and number(native.fuelCapacity) or nil
        self.fuelLabel:setNameWithoutMoving(
            tr("UI_RailroaderRVTest_Utility_Fuel", "Fuel") .. ": "
            .. text(fuel) .. " / " .. text(fuelCapacity) .. " L")
        self.fuelBar:setProgress(ratio(fuel, fuelCapacity))
        self.fuelBar:setText(string.format("%.0f%%", ratio(fuel, fuelCapacity) * 100))
        local active = native and native.active == true
            and tr("UI_RailroaderRVTest_Utility_Running", "Running")
            or tr("UI_RailroaderRVTest_Utility_Stopped", "Stopped")
        if not native then
            active = tr("UI_RailroaderRVTest_Utility_Unbound", "Unbound")
        end
        self.powerLabel:setNameWithoutMoving(
            tr("UI_RailroaderRVTest_Utility_Generator", "Generator") .. ": " .. active
            .. "  " .. tr("UI_RailroaderRVTest_Utility_State", "State") .. "="
            .. tostring(value.generator and value.generator.state or "-"))
        local total, activeCount = 0, 0
        for _, entry in pairs(water.registry or {}) do
            total = total + 1
            if type(entry) == "table" and entry.status == U.STATUS_ACTIVE then
                activeCount = activeCount + 1
            end
        end
        self.deviceLabel:setNameWithoutMoving(
            tr("UI_RailroaderRVTest_Utility_Devices", "Water devices") .. ": "
            .. tostring(activeCount) .. " / " .. tostring(total) .. " "
            .. tr("UI_RailroaderRVTest_Utility_Connected", "connected"))
        if not self.operationStatus then
            self:setStatus(tr("UI_RailroaderRVTest_Utility_Updated",
                "Server snapshot updated"))
        end
    end

    function Window:openSourceMenu(kind)
        local player = self.player
        if not player or not ISContextMenu or type(ISContextMenu.get) ~= "function" then
            self:setStatus("Unable to open item menu")
            return
        end
        local inventoryOk, inventory = pcall(function() return player:getInventory() end)
        if not inventoryOk or not inventory then
            self:setStatus("Unable to read inventory")
            return
        end
        local fluid = rawget(_G, "Fluid")
        local wanted = kind == "fuel" and fluid and fluid.Petrol or nil
        local water = fluid and fluid.Water
        local tainted = fluid and fluid.TaintedWater
        local items = {}
        inventoryItems(inventory, items, {})
        local menu = ISContextMenu.get(player:getPlayerNum(), self:getAbsoluteX() + 20,
            self:getAbsoluteY() + self:getHeight() - 30)
        if not menu then
            self:setStatus("Unable to open item menu")
            return
        end
        local count = 0
        for _, item in ipairs(items) do
            local amount = wanted and fluidAmount(item, wanted)
                or (fluidAmount(item, water) or fluidAmount(item, tainted))
            if amount then
                count = count + 1
                local operationItem = item
                menu:addOption(itemLabel(item) .. " (" .. text(amount) .. " L)", self,
                    function(window)
                        if kind == "fuel" then
                            Client.requestAddFuel(window.player, operationItem)
                        else
                            local entryPoint = U.ENTRY_INTERNAL
                            local rv = rawget(_G, "RailroaderRV")
                            local railroader = rv and rv.RailroaderContextMenu
                            if railroader and type(railroader.utilityEntryPoint) == "function" then
                                local pointOk, point = pcall(
                                    railroader.utilityEntryPoint, window.player)
                                if pointOk and point then entryPoint = point end
                            end
                            Client.requestAddWater(window.player, operationItem, entryPoint)
                        end
                        window.operationStatus = tr(
                            "UI_RailroaderRVTest_Utility_Submitted",
                            "Operation submitted; waiting for server")
                        window:setStatus(window.operationStatus)
                    end)
            end
        end
        if count == 0 then
            local empty = menu:addOption(kind == "fuel"
                and tr("UI_RailroaderRVTest_Utility_NoFuel", "No usable fuel")
                or tr("UI_RailroaderRVTest_Utility_NoWater", "No usable water"))
            empty.notAvailable = true
        end
    end

    function Window:onAddWater()
        self:openSourceMenu("water")
    end

    function Window:onAddFuel()
        self:openSourceMenu("fuel")
    end

    function Window:onRefresh()
        self.operationStatus = nil
        Client.requestSnapshot(self.player)
        self:setStatus(tr("UI_RailroaderRVTest_Utility_Waiting",
            "Waiting for server snapshot"))
    end

    function Window:close()
        self:setVisible(false)
        if Dashboard.instance == self then Dashboard.instance = nil end
    end

    function Window:new(x, y, player)
        local o = ISCollapsableWindow:new(x, y, 440, 330)
        setmetatable(o, self)
        self.__index = self
        o.player = player
        o.mappingKey = mappingKey(utilityMapping())
        o.operationStatus = nil
        o:setResizable(false)
        o:setTitle(tr("UI_RailroaderRVTest_Utility_Title", "RV utility panel"))
        return o
    end
end

function Dashboard.read(snapshot)
    snapshot = snapshot or (Client.getSnapshot and Client.getSnapshot() or nil)
    if type(snapshot) ~= "table" or type(snapshot.water) ~= "table" then
        return { available = false, label = tr("UI_RailroaderRVTest_Utility_Waiting",
            "Waiting for server snapshot") }
    end
    local water = snapshot.water
    return {
        available = true,
        rvId = snapshot.rvId,
        water = water,
        canonicalTank = water.canonicalTank,
        amount = water.canonicalTank and water.canonicalTank.amount or 0,
        capacity = water.canonicalTank and water.canonicalTank.capacity or 0,
        state = water.state,
        registry = water.registry,
        generator = snapshot.power,
    }
end

function Dashboard.format(value)
    value = value or Dashboard.read()
    if type(value) ~= "table" or value.available ~= true then
        return tr("UI_RailroaderRVTest_Utility_Waiting",
            "Waiting for server snapshot")
    end
    return tr("UI_RailroaderRVTest_Utility_Water", "Water tank") .. " "
        .. text(value.amount) .. " / "
        .. text(value.capacity) .. " L"
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
    local window = Window:new((screenWidth - 440) / 2, (screenHeight - 330) / 2, player)
    window:initialise()
    window:addToUIManager()
    Dashboard.instance = window
    window:refresh()
    return true
end

function Dashboard.onSnapshot(player, snapshot)
    local instance = Dashboard.instance
    if not instance or not instance:getIsVisible() or instance.player ~= player then
        return false
    end
    local snapshotKey = mappingKey(snapshot)
    if not snapshotKey or snapshotKey ~= instance.mappingKey then return false end
    Dashboard.refresh(snapshot)
    return true
end

function Dashboard.onAck(player, ack)
    if not Dashboard.instance or not Dashboard.instance:getIsVisible()
        or Dashboard.instance.player ~= player then return end
    if type(ack) ~= "table" then return end
    if ack.ok == true then
        Dashboard.instance.operationStatus = tr(
            "UI_RailroaderRVTest_Utility_Confirmed",
            "Operation confirmed; refreshing values")
        Dashboard.instance:setStatus(Dashboard.instance.operationStatus)
    else
        Dashboard.instance.operationStatus = tr(
            "UI_RailroaderRVTest_Utility_Rejected", "Operation rejected")
            .. ": " .. tostring(ack.reason or "unknown reason")
        Dashboard.instance:setStatus(Dashboard.instance.operationStatus)
    end
end

return Dashboard
