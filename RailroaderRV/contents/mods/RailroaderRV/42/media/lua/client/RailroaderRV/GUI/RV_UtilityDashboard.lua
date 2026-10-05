-- Client utility dashboard. Server snapshots are the only source of displayed
-- system state; menu actions submit inventory items or device IDs as intent.
require("ISUI/ISCollapsableWindow")
require("ISUI/ISLabel")
require("ISUI/ISPanel")
require("ISUI/ISScrollingListBox")
require("ISUI/ISTabPanel")
require("ISUI/ISContextMenu")

local Client = require("RailroaderRV/GUI/RV_UtilityClient")
local RoofWindow = require("RailroaderRV/GUI/RV_RoofDeviceWindow")
local Roof = require("RailroaderRV/Roof/RV_RoofDevices")
local Inventory = require("RailroaderRV/GUI/RV_UtilityInventory")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local W = require("RailroaderRV/Water/RV_UtilityWaterConstants")
local P = U.POWER
local Generation = require("RailroaderRV/Power/RV_Generation")

local BUTTON_TONES = {
    neutral = { r = 0.22, g = 0.28, b = 0.34 },
    positive = { r = 0.10, g = 0.48, b = 0.18 },
    negative = { r = 0.64, g = 0.13, b = 0.14 },
}
local STATUS_TONES = {
    running = { r = 0.25, g = 0.95, b = 0.35 },
    stopped = { r = 1.0, g = 0.25, b = 0.25 },
}

RailroaderRV = RailroaderRV or {}
RailroaderRV.UtilityDashboard = RailroaderRV.UtilityDashboard or {}
local Dashboard = RailroaderRV.UtilityDashboard

local function display(value, digits)
    return string.format("%." .. tostring(digits or 1) .. "f", value)
end

local function itemDisplayName(fullType)
    return getItemNameFromFullType(fullType)
end

local function mappingKey(value)
    return Client.mappingKey(value)
end

local function currentUtilityMapping()
    return RailroaderRV.RailroaderContextMenu.getUtilityMapping()
end

local function hasCurrentUtilityContext(player, expectedMappingKey)
    local menu = RailroaderRV.RailroaderContextMenu
    local mapping = menu.getUtilityMapping()
    return mapping ~= nil
        and mappingKey(mapping) == expectedMappingKey
        and menu.hasUtilityDashboardCandidate(player)
end

local function fluidFuel(item)
    if type(item.getFluidContainer) ~= "function" then return false end
    local container = item:getFluidContainer()
    local fluid = Fluid
    return container ~= nil and fluid and fluid.Petrol ~= nil
        and container:contains(fluid.Petrol)
        and not container:isMixture() and container:getAmount() > 0
end

local function batteryItem(item)
    local itemType = item:getFullType()
    return P.BATTERY_TYPES[itemType] ~= nil
end

local batteryTypeKeys = {
    ["Base.CarBattery1"] = "UI_RailroaderRV_Utility_BatteryTypeStandard",
    ["Base.CarBattery2"] = "UI_RailroaderRV_Utility_BatteryTypeCommercial",
    ["Base.CarBattery3"] = "UI_RailroaderRV_Utility_BatteryTypePerformance",
}

local function hasDamagedCondition(items)
    for _, item in ipairs(items) do
        if item.condition <= 0 then return true end
    end
    return false
end

local function itemLabel(item)
    local fullType = item:getFullType()
    local label = item:getName()
    if batteryItem(item) then
        label = label .. "  |  " .. getText("UI_RailroaderRV_Utility_BatteryCharge") .. " "
            .. display(item:getCurrentUsesFloat() * 100, 0) .. "%"
    end
    if fluidFuel(item) then
        label = label .. "  " .. display(item:getFluidContainer():getAmount(), 1) .. " L"
    end
    local waterKind = Inventory.waterKind(item)
    if waterKind then
        local kindText = waterKind == "clean"
            and getText("UI_RailroaderRV_Utility_CleanWater")
            or getText("UI_RailroaderRV_Utility_TaintedWater")
        label = label .. "  |  " .. kindText .. "  "
            .. display(item:getFluidContainer():getAmount(), 1) .. " L"
    end
    if P.GAS_TANK_TYPES[fullType] then
        label = label .. "  " .. display(P.gasTankCapacity(item:getMaxCapacity(), item:getCondition()), 1) .. " L"
    end
    return label
end

local function itemMenu(window, anchor, matches, choose, emptyText, labelFor)
    local player = window.player
    local inventoryItems = {}
    Inventory.appendItems(player:getInventory(), inventoryItems, {})
    local menu = ISContextMenu.get(player:getPlayerNum(), anchor.x, anchor.y)
    local found = 0
    for _, item in ipairs(inventoryItems) do
        if matches(item) then
            found = found + 1
            local selectedItem = item
            menu:addOption(labelFor and labelFor(item) or itemLabel(item), window, function(target)
                choose(target, selectedItem)
            end)
        end
    end
    if found == 0 then
        local option = menu:addOption(emptyText)
        option.notAvailable = true
    end
    menu:addToUIManager()
end

local PowerList = ISScrollingListBox:derive("RVUtilityPowerList")

local function buttonLayout(list, row)
    local buttons = row.buttons
    local count = #buttons
    local width, gap, right = 104, 5, list:getWidth() - 8
    return right - count * width - (count - 1) * gap, width, gap
end

local function buttonGeometry(list, row, index, rowY, rowHeight)
    local startX, width, gap = buttonLayout(list, row)
    local buttonY, buttonHeight
    if row.kind == "section" then
        buttonY, buttonHeight = rowY + 4, rowHeight - 8
    elseif row.kind == "meter" then
        buttonY, buttonHeight = rowY + 3, 22
    else
        buttonY, buttonHeight = rowY + 5, rowHeight - 10
    end
    return startX + (index - 1) * (width + gap), buttonY, width, buttonHeight
end

local function drawActionProgress(list, y, row, height)
    if not row.progressOperation then return end
    local window = list.page.window
    local action
    if row.useWaterActionHandle then
        action = window.activeWaterAction
    else
        local queue = ISTimedActionQueue.getTimedActionQueue(window.player)
        action = queue.queue[1]
    end
    if row.useWaterActionHandle and (not action or not action.action) then
        return
    end
    if not action or not action.action
            or action.operation ~= row.progressOperation
            or action.rvUtilityMappingKey ~= window.mappingKey then
        return
    end
    if row.progressTargetField
            and action.targetHint[row.progressTargetField] ~= row.progressTargetId then
        return
    end
    if row.progressDeviceType and Roof.typeForItem(action.item) ~= row.progressDeviceType then
        return
    end
    local progress = action:getJobDelta()
    local width = math.floor(list:getWidth() * progress)
    if width > 0 then
        list:drawRect(0, y, width, height, 0.2, 0.4, 1.0, 0.3)
    end
end

function PowerList:doDrawItem(y, entry)
    local row = entry.item
    local height = entry.height
    if row.kind == "section" then
        self:drawRect(0, y, self:getWidth(), height, 0.82, 0.16, 0.19, 0.22)
        if row.alert then
            self:drawRect(0, y, self:getWidth(), height, 0.32, 0.95, 0.08, 0.08)
        end
        self:drawRectBorder(0, y, self:getWidth(), height, 0.55, 0.42, 0.46, 0.50)
        drawActionProgress(self, y, row, height)
        self:drawText(row.text, 12, y + math.floor((height - self.fontHgt) / 2),
            0.95, 0.95, 0.95, 1, UIFont.Medium)
        if #row.buttons > 0 then
            for index, button in ipairs(row.buttons) do
                local buttonX, buttonY, width, buttonHeight =
                    buttonGeometry(self, row, index, y, height)
                local color = BUTTON_TONES[button.tone]
                self:drawRect(buttonX, buttonY, width, buttonHeight,
                    0.9, color.r, color.g, color.b)
                self:drawRectBorder(buttonX, buttonY, width, buttonHeight,
                    0.9, 0.58, 0.62, 0.66)
                self:drawTextCentre(button.text, buttonX + width / 2,
                    buttonY + math.floor((buttonHeight - self.fontHgt) / 2),
                    1, 1, 1, 1, UIFont.Small)
            end
        end
    elseif row.kind == "meter" then
        self:drawRect(0, y, self:getWidth(), height, 0.18, 0, 0, 0)
        drawActionProgress(self, y, row, height)
        self:drawText(row.text .. ": " .. row.value, 12, y + 3,
            0.94, 0.94, 0.94, 1, self.font)
        if #row.buttons > 0 then
            for index, button in ipairs(row.buttons) do
                local buttonX, buttonY, width, buttonHeight =
                    buttonGeometry(self, row, index, y, height)
                local color = BUTTON_TONES[button.tone]
                self:drawRect(buttonX, buttonY, width, buttonHeight,
                    0.9, color.r, color.g, color.b)
                self:drawRectBorder(buttonX, buttonY, width, buttonHeight,
                    0.9, 0.58, 0.62, 0.66)
                self:drawTextCentre(button.text, buttonX + width / 2,
                    buttonY + math.floor((buttonHeight - self.fontHgt) / 2),
                    1, 1, 1, 1, UIFont.Small)
            end
        end
        local barX, barY = 12, y + 25
        local barWidth = self:getWidth() - 24
        local barHeight = 14
        self:drawRect(barX, barY, barWidth, barHeight, 0.9, 0.13, 0.14, 0.15)
        if row.fraction ~= nil then
            local red, green
            if row.fraction <= 0.5 then
                red, green = 1, row.fraction * 2
            else
                red, green = (1 - row.fraction) * 2, 1
            end
            local filled = math.floor(barWidth * row.fraction)
            if filled > 0 then
                self:drawRect(barX, barY, filled, barHeight,
                    0.9, red, green, 0)
            end
        end
        self:drawRectBorder(barX, barY, barWidth, barHeight,
            0.8, 0.52, 0.54, 0.56)
    else
        self:drawRect(0, y, self:getWidth(), height, 0.16, 0, 0, 0)
        if row.alert then
            self:drawRect(0, y, self:getWidth(), height, 0.32, 0.95, 0.08, 0.08)
        end
        self:drawRectBorder(0, y, self:getWidth(), height, 0.32,
            0.30, 0.32, 0.34)
        drawActionProgress(self, y, row, height)
        local firstY = y + (row.sub and 5 or math.floor((height - self.fontHgt) / 2))
        self:drawText(row.text, 12, firstY, 0.92, 0.92, 0.92, 1,
            row.kind == "device" and self.font or self.font)
        if row.statusText then
            local color = STATUS_TONES[row.statusTone]
            local statusX = 12 + getTextManager():MeasureStringX(self.font, row.text) + 10
            self:drawText(row.statusText, statusX, firstY,
                color.r, color.g, color.b, 1, self.font)
        end
        if row.sub then
            self:drawText(row.sub, 12, y + 27, 0.72, 0.74, 0.76, 1, UIFont.Small)
        end
        if row.sub2 then
            self:drawText(row.sub2, 12, y + 48, 0.72, 0.74, 0.76, 1, UIFont.Small)
        end
        if row.sub3 then
            self:drawText(row.sub3, 12, y + 69, 0.72, 0.74, 0.76, 1, UIFont.Small)
        end
        if #row.buttons > 0 then
            for index, button in ipairs(row.buttons) do
                local buttonX, buttonY, width, buttonHeight =
                    buttonGeometry(self, row, index, y, height)
                local color = BUTTON_TONES[button.tone]
                self:drawRect(buttonX, buttonY, width, buttonHeight,
                    0.9, color.r, color.g, color.b)
                self:drawRectBorder(buttonX, buttonY, width, buttonHeight,
                    0.9, 0.58, 0.62, 0.66)
                self:drawTextCentre(button.text, buttonX + width / 2,
                    buttonY + math.floor((buttonHeight - self.fontHgt) / 2),
                    1, 1, 1, 1, UIFont.Small)
            end
        end
    end
    return y + height
end

function PowerList:onMouseDown(x, y)
    if self:isMouseOverScrollBar() then return end
    local index = self:rowAt(x, y)
    local entry = self.items[index]
    if not entry then return end
    local row = entry.item
    if #row.buttons == 0 then return end
    local rowY = y - self:topOfItem(index)
    for buttonIndex, button in ipairs(row.buttons) do
        local buttonX, buttonY, width, height =
            buttonGeometry(self, row, buttonIndex, 0, entry.height)
        if x >= buttonX and x < buttonX + width
                and rowY >= buttonY and rowY < buttonY + height then
            local anchor = {
                x = self:getAbsoluteX() + buttonX + width,
                y = self:getAbsoluteY() + self:topOfItem(index)
                    + buttonY + self:getYScroll(),
            }
            self.page.window:clearLocalStatus()
            button.action(self.page.window, anchor)
            return
        end
    end
end

local function addRow(list, row, height)
    local entry = list:addItem(row.text or "", row)
    entry.height = height
end

local PowerPage = ISPanel:derive("RVUtilityPowerPage")

function PowerPage:createChildren()
    self.list = PowerList:new(0, 0, self.width, self.height)
    self.list.page = self
    self.list:initialise()
    self.list:instantiate()
    self.list:setFont("Small", 4)
    self.list.selected = -1
    self:addChild(self.list)
end

function PowerPage:section(text, buttons, progressOperation, alert)
    addRow(self.list, { kind = "section", text = text,
        buttons = buttons or {}, progressOperation = progressOperation,
        alert = alert }, 34)
end

function PowerPage:detail(text, sub, progressOperation, alert)
    addRow(self.list, { kind = "detail", text = text, sub = sub,
        buttons = {}, progressOperation = progressOperation, alert = alert },
        sub and 54 or 34)
end

function PowerPage:meter(text, value, amount, capacity, buttons)
    local fraction
    if capacity > 0 then fraction = amount / capacity end
    addRow(self.list, { kind = "meter", text = text, value = value,
        fraction = fraction, buttons = buttons or {} }, 48)
end

function PowerPage:refresh(snapshot)
    local scroll = self.list:getYScroll()
    local list = self.list
    list:clear()
    if not snapshot then
        self:detail(getText("UI_RailroaderRV_Utility_Loading"))
        list:setScrollHeight(list.items[1].height)
        list:setYScroll(0)
        return
    end

    local power = snapshot.power
    local generators = power.generators
    local tanks = power.fuelTanks
    local batteries = power.batteries
    local batteryCount = #batteries
    local fuelCapacity = power.fuelCapacityL
    local fuelAmount = power.virtualFuelL
    local batteryCapacity = power.batteryCapacityWh
    local batteryAmount = power.batteryWh
    local fuelRate = power.fuelConsumptionLPerHour

    self:section(getText("UI_RailroaderRV_Utility_Overview"), {
        { text = getText("UI_RailroaderRV_Utility_Refresh"), tone = "neutral",
            action = function(window) Client.requestSnapshot(window.player) end },
    })
    self:detail(getText("UI_RailroaderRV_Utility_LiveGeneration")
        .. ": " .. display(power.generationPowerW, 0) .. " W")
    self:meter(getText("UI_RailroaderRV_Utility_FuelCapacity"),
        display(fuelAmount, 1) .. " / " .. display(fuelCapacity, 1) .. " L",
        fuelAmount, fuelCapacity, {
            { text = getText("UI_RailroaderRV_Utility_Refuel"), tone = "positive",
                action = function(window, anchor) window:addFuel(anchor) end },
        })
    local remainingTime = fuelRate > 0
        and display(fuelAmount / fuelRate, 1) .. " h"
        or getText("UI_RailroaderRV_Utility_NoFuelUse")
    self:detail(getText("UI_RailroaderRV_Utility_FuelRate")
        .. ": " .. display(fuelRate, 2) .. " L/h  |  "
        .. getText("UI_RailroaderRV_Utility_FuelRuntime")
        .. ": " .. remainingTime)
    if batteryCount > 0 then
        self:meter(getText("UI_RailroaderRV_Utility_BatteryEnergy"),
            display(batteryAmount, 0) .. " / " .. display(batteryCapacity, 0)
                .. " Wh (" .. display(batteryAmount / batteryCapacity * 100, 0) .. "%)",
            batteryAmount, batteryCapacity)
    else
        self:detail(getText("UI_RailroaderRV_Utility_BatteryEnergy")
            .. ": " .. getText("UI_RailroaderRV_Utility_NoBattery"))
    end
    self:detail(getText("UI_RailroaderRV_Utility_ChargePower")
        .. ": " .. display(power.batteryChargePowerW, 0) .. " W")
    self:detail(getText("UI_RailroaderRV_Utility_DischargePower")
        .. ": " .. display(power.batteryDischargePowerW, 0) .. " W")
    self:detail(getText("UI_RailroaderRV_Utility_BatteryMaxChargePower")
        .. ": " .. display(power.maxChargePowerW, 0) .. " W")
    self:detail(getText("UI_RailroaderRV_Utility_BatteryMaxDischargePower")
        .. ": " .. display(power.maxDischargePowerW, 0) .. " W")
    self:detail(getText("UI_RailroaderRV_Utility_DeviceTotal")
        .. ": " .. tostring(power.deviceCount))
    self:detail(getText("UI_RailroaderRV_Utility_PotentialLoad")
        .. ": " .. display(power.potentialLoadW, 0) .. " W")
    self:detail(getText("UI_RailroaderRV_Utility_ActiveDevices")
        .. ": " .. tostring(power.activeDeviceCount))
    self:detail(getText("UI_RailroaderRV_Utility_ActiveLoad")
        .. ": " .. display(power.currentLoadW, 0) .. " W")

    self:section(getText("UI_RailroaderRV_Utility_Generators")
        .. " (" .. tostring(#generators) .. "/" .. tostring(P.MAX_GENERATORS) .. ")", {
        { text = getText("UI_RailroaderRV_Roof_InstallRemove"), tone = "positive",
            action = function(window) RoofWindow.show(window.player) end },
    }, nil, #generators == 0 or hasDamagedCondition(generators))
    if #generators == 0 then
        self:detail(getText("UI_RailroaderRV_Utility_NoGenerators"))
    end
    for _, generator in ipairs(generators) do
        local generatorId = generator.id
        local generatorEnabled = generator.enabled
        local profile = P.GENERATOR_TYPES[generator.fullType]
        local renewableType = profile.renewableType
        local generatorText = itemDisplayName(generator.fullType)
        local generatorState = generator.running
            and getText("UI_RailroaderRV_Utility_Running")
            or getText("UI_RailroaderRV_Utility_Stopped")
        local generatorSub
        local generatorSub2
        local generatorSub3
        local generatorButtons = {}
        if renewableType == nil then
            local current = display(generator.currentPowerW, 0)
            local maximum = display(generator.maxPowerW, 0)
            local fuelUse = display(generator.fuelConsumptionLPerHour, 2)
            generatorSub = getText("UI_RailroaderRV_Utility_Power") .. " "
                .. current .. " / " .. maximum .. " W  |  "
                .. getText("UI_RailroaderRV_Utility_FuelRate") .. " "
                .. fuelUse .. " L/h"
            if power.controller then
                generatorText = generatorText .. "  |  "
                    .. getText("UI_RailroaderRV_Utility_ControllerControlled")
            else
                generatorButtons[#generatorButtons + 1] = {
                    text = generatorEnabled
                        and getText("UI_RailroaderRV_Utility_Stop")
                        or getText("UI_RailroaderRV_Utility_Start"),
                    tone = generatorEnabled and "negative" or "positive",
                    action = function(window, anchor)
                        window:toggleGenerator(generatorId, generatorEnabled,
                            fuelAmount, anchor)
                    end,
                }
            end
        elseif renewableType == "WIND" then
            local windSpeed = getClimateManager():getWindspeedKph()
            local windStopReason
            if not generator.running and generator.currentPowerW == 0 then
                if windSpeed <= 10 then
                    windStopReason = getText("UI_RailroaderRV_Utility_WindStoppedLowSpeed")
                elseif windSpeed >= 90 then
                    windStopReason = getText("UI_RailroaderRV_Utility_WindStoppedHighSpeed")
                end
            end
            generatorSub = getText("UI_RailroaderRV_Utility_WindSpeed") .. ": "
                .. display(windSpeed, 1) .. " km/h  |  "
                .. getText("UI_RailroaderRV_Utility_Power") .. ": "
                .. display(generator.currentPowerW, 0) .. " / "
                .. display(generator.maxPowerW, 0) .. " W"
            generatorSub2 = getText("UI_RailroaderRV_Utility_GenerationEfficiency") .. ": "
                .. display(generator.currentPowerW / generator.maxPowerW * 100, 0) .. "%"
            if windStopReason then
                generatorSub2 = generatorSub2 .. "  |  " .. windStopReason
            end
        elseif renewableType == "SOLAR" then
            local gameTime = getGameTime()
            local climate = getClimateManager()
            local clearSkyPower = Generation.solarPowerW(
                gameTime:getTimeOfDay(), gameTime:getMonth() + 1, 0, 0, 0)
            generatorSub = getText("UI_RailroaderRV_Utility_SunlightIntensity") .. ": "
                .. display(clearSkyPower / generator.maxPowerW * 100, 0) .. "%"
            generatorSub2 = getText("UI_RailroaderRV_Utility_Power") .. ": "
                .. display(generator.currentPowerW, 0) .. " / "
                .. display(generator.maxPowerW, 0) .. " W  |  "
                .. getText("UI_RailroaderRV_Utility_EffectiveGeneration") .. ": "
                .. display(generator.currentPowerW / generator.maxPowerW * 100, 0) .. "%"
            generatorSub3 = getText("UI_RailroaderRV_Utility_CloudIntensity") .. ": "
                .. display(climate:getCloudIntensity() * 100, 0) .. "%  |  "
                .. getText("UI_RailroaderRV_Utility_PrecipitationIntensity") .. ": "
                .. display(climate:getPrecipitationIntensity() * 100, 0) .. "%  |  "
                .. getText("UI_RailroaderRV_Utility_FogIntensity") .. ": "
                .. display(climate:getFogIntensity() * 100, 0) .. "%"
        end
        addRow(list, { kind = "device", text = generatorText,
            statusText = generatorState,
            statusTone = generator.running and "running" or "stopped",
            sub = generatorSub, sub2 = generatorSub2, sub3 = generatorSub3,
            buttons = generatorButtons, alert = generator.condition <= 0 },
            generatorSub3 and 96 or generatorSub2 and 78 or 60)
    end

    self:section(getText("UI_RailroaderRV_Utility_FuelTanks")
        .. " (" .. tostring(#tanks) .. "/" .. tostring(P.MAX_FUEL_TANKS) .. ")", {
        { text = getText("UI_RailroaderRV_Utility_AddTank"), tone = "positive",
            action = function(window, anchor) window:addFuelTank(anchor) end },
    }, U.OP_ADD_FUEL_TANK,
        #tanks == 0 or hasDamagedCondition(tanks))
    if #tanks == 0 then
        self:detail(getText("UI_RailroaderRV_Utility_NoFuelTanks"))
    end
    for _, tank in ipairs(tanks) do
        local fuelTankId = tank.id
        addRow(list, { kind = "device",
            text = itemDisplayName(tank.fullType) .. "  |  "
                .. display(tank.capacityL, 0) .. " L",
            buttons = {
                { text = getText("UI_RailroaderRV_Utility_Remove"), tone = "negative",
                    action = function(window)
                        window:removeFuelTank(fuelTankId)
                    end,
                },
            },
            progressOperation = U.OP_REMOVE_FUEL_TANK,
            alert = tank.condition <= 0,
            progressTargetField = "fuelTankId",
            progressTargetId = fuelTankId }, 34)
    end

    local chargerButton
    if power.charger then
        chargerButton = { text = getText("UI_RailroaderRV_Utility_Remove"), tone = "negative",
            action = function(window)
                window:requestTimed(U.OP_REMOVE_CHARGER)
            end }
    else
        chargerButton = { text = getText("UI_RailroaderRV_Utility_Add"), tone = "positive",
            action = function(window, anchor) window:addCharger(anchor) end }
    end
    self:section(getText("UI_RailroaderRV_Utility_Charger"), { chargerButton },
        not power.charger and U.OP_INSTALL_CHARGER or nil,
        not power.charger or power.charger.condition <= 0)
    if power.charger then
        self:detail(itemDisplayName(power.charger.fullType),
            getText("UI_RailroaderRV_Utility_Efficiency") .. ": "
                .. display(power.chargerEfficiency * 100, 0) .. "%",
            U.OP_REMOVE_CHARGER, power.charger.condition <= 0)
    else
        self:detail(getText("UI_RailroaderRV_Utility_Missing"),
            getText("UI_RailroaderRV_Utility_ChargerRequired"))
    end

    local inverterButton
    if power.inverter then
        inverterButton = { text = getText("UI_RailroaderRV_Utility_Remove"), tone = "negative",
            action = function(window)
                window:requestTimed(U.OP_REMOVE_INVERTER)
            end }
    else
        inverterButton = { text = getText("UI_RailroaderRV_Utility_Add"), tone = "positive",
            action = function(window, anchor) window:addInverter(anchor) end }
    end
    self:section(getText("UI_RailroaderRV_Utility_Inverter"), { inverterButton },
        not power.inverter and U.OP_INSTALL_INVERTER or nil,
        not power.inverter or power.inverter.condition <= 0)
    if power.inverter then
        if power.inverter.condition <= 0 then
            self:detail(itemDisplayName(power.inverter.fullType),
                getText("UI_RailroaderRV_Utility_Damaged"),
                U.OP_REMOVE_INVERTER, true)
        else
            self:detail(itemDisplayName(power.inverter.fullType),
                getText("UI_RailroaderRV_Utility_Efficiency") .. ": "
                    .. display(power.inverterEfficiency * 100, 0) .. "%",
                U.OP_REMOVE_INVERTER)
        end
    else
        self:detail(getText("UI_RailroaderRV_Utility_Missing"),
            getText("UI_RailroaderRV_Utility_InverterRequired"))
    end

    local breakerButton
    if power.circuitBreakerInstalled then
        local closed = power.circuitBreakerClosed
        breakerButton = { text = getText(closed
            and "UI_RailroaderRV_Utility_OpenCircuitBreaker"
            or "UI_RailroaderRV_Utility_CloseCircuitBreaker"),
            tone = closed and "negative" or "positive",
            action = function(window)
                Client.requestPowerOperation(window.player,
                    closed and U.OP_OPEN_CIRCUIT_BREAKER
                        or U.OP_CLOSE_CIRCUIT_BREAKER)
            end }
    else
        breakerButton = { text = getText("UI_RailroaderRV_Utility_Add"), tone = "positive",
            action = function(window, anchor)
                window:addCircuitBreaker(anchor)
            end }
    end
    local breakerButtons = { breakerButton }
    if power.circuitBreakerInstalled then
        breakerButtons[#breakerButtons + 1] = {
            text = getText("UI_RailroaderRV_Utility_Remove"), tone = "negative",
            action = function(window)
                window:requestTimed(U.OP_REMOVE_CIRCUIT_BREAKER)
            end,
        }
    end
    self:section(getText("UI_RailroaderRV_Utility_CircuitBreaker"),
        breakerButtons, not power.circuitBreakerInstalled
            and U.OP_INSTALL_CIRCUIT_BREAKER or nil,
        not power.circuitBreakerInstalled or not power.circuitBreakerClosed)
    if power.circuitBreakerInstalled then
        self:detail(getText("UI_RailroaderRV_Utility_Installed")
            .. "  |  " .. getText(power.circuitBreakerClosed
                and "UI_RailroaderRV_Utility_CircuitBreakerClosed"
                or "UI_RailroaderRV_Utility_CircuitBreakerOpen"),
            nil, U.OP_REMOVE_CIRCUIT_BREAKER, not power.circuitBreakerClosed)
    else
        self:detail(getText("UI_RailroaderRV_Utility_NotInstalled"))
    end

    self:section(getText("UI_RailroaderRV_Utility_Batteries")
        .. " (" .. tostring(batteryCount) .. "/" .. tostring(P.MAX_BATTERIES) .. ")", {
        { text = getText("UI_RailroaderRV_Utility_AddBattery"), tone = "positive",
            action = function(window, anchor) window:addBattery(anchor) end },
    }, U.OP_ADD_BATTERY,
        batteryCount == 0 or hasDamagedCondition(batteries))
    if batteryCount == 0 then
        self:detail(getText("UI_RailroaderRV_Utility_NoBattery"))
    end
    for _, battery in ipairs(batteries) do
        local batteryId = battery.id
        local values = P.batteryParameters(battery.fullType, battery.condition, battery.maxCondition)
        addRow(list, { kind = "device",
            text = itemDisplayName(battery.fullType) .. "  |  "
                .. getText(batteryTypeKeys[battery.fullType]),
            sub = getText("UI_RailroaderRV_Utility_Condition") .. " "
                .. tostring(battery.condition) .. "/" .. tostring(battery.maxCondition)
                .. "  |  " .. getText("UI_RailroaderRV_Utility_Capacity") .. " "
                .. display(values.capacityWh, 1) .. " Wh  |  "
                .. getText("UI_RailroaderRV_Utility_ChargeLimit") .. " "
                .. display(values.maxChargePowerW, 1) .. " W  |  "
                .. getText("UI_RailroaderRV_Utility_DischargeLimit") .. " "
                .. display(values.maxDischargePowerW, 1) .. " W",
            buttons = {
                { text = getText("UI_RailroaderRV_Utility_Remove"), tone = "negative",
                    action = function(window)
                        window:removeBattery(batteryId)
                    end,
                },
            },
            progressOperation = U.OP_REMOVE_BATTERY,
            alert = battery.condition <= 0,
            progressTargetField = "batteryId",
            progressTargetId = batteryId }, 60)
    end

    local controllerButton
    if power.controller then
        controllerButton = { text = getText("UI_RailroaderRV_Utility_Remove"), tone = "negative",
            action = function(window)
                window:requestTimed(U.OP_REMOVE_CONTROLLER)
            end }
    else
        controllerButton = { text = getText("UI_RailroaderRV_Utility_Add"), tone = "positive",
            action = function(window, anchor) window:addController(anchor) end }
    end
    self:section(getText("UI_RailroaderRV_Utility_Controller"), { controllerButton },
        not power.controller and U.OP_INSTALL_CONTROLLER or nil,
        not power.controller or power.controller.condition <= 0)
    if power.controller then
        self:detail(getText("UI_RailroaderRV_Utility_Installed")
            .. "  |  " .. itemDisplayName(power.controller.fullType),
            getText("UI_RailroaderRV_Utility_ControllerEffect"),
            U.OP_REMOVE_CONTROLLER, power.controller.condition <= 0)
    else
        self:detail(getText("UI_RailroaderRV_Utility_NotInstalled"),
            getText("UI_RailroaderRV_Utility_ControllerEffect"))
    end
    list:setScrollHeight((function()
        local height = 0
        for _, entry in ipairs(list.items) do height = height + entry.height end
        return height
    end)())
    list:setYScroll(scroll)
end

local function waterSystemUnavailable(water)
    return water.tankCount <= 0
        or not water.supplyPumpInstalled
        or not water.filter
        or not water.supplyPumpPowered
        or water.filterRemainingL <= 0
end

local WaterPage = ISPanel:derive("RVUtilityWaterPage")

function WaterPage:createChildren()
    self.list = PowerList:new(0, 0, self.width, self.height)
    self.list.page = self
    self.list:initialise()
    self.list:instantiate()
    self.list:setFont("Small", 4)
    self.list.selected = -1
    self:addChild(self.list)
end

function WaterPage:refresh(snapshot)
    local scroll = self.list:getYScroll()
    local list = self.list
    list:clear()
    if not snapshot then
        addRow(list, { kind = "detail",
            text = getText("UI_RailroaderRV_Utility_Loading"), buttons = {} }, 38)
        list:setScrollHeight(list.items[1].height)
        list:setYScroll(0)
        return
    end
    local water = snapshot.water
    local sinkKeys, collectorKeys = {}, {}
    local connectedCount = 0
    for key, sink in pairs(water.sinks) do
        sinkKeys[#sinkKeys + 1] = key
        if sink.connected then connectedCount = connectedCount + 1 end
    end
    table.sort(sinkKeys)
    for key in pairs(water.roofCollectors) do
        collectorKeys[#collectorKeys + 1] = key
    end
    table.sort(collectorKeys)
    local filterInstalled = water.filter ~= nil
    local filterExhausted = filterInstalled and water.filterRemainingL <= 0
    local systemStatus
    if water.tankCount <= 0 or not water.supplyPumpInstalled or not filterInstalled then
        systemStatus = getText("UI_RailroaderRV_Utility_WaterMissingRequired")
    elseif not water.supplyPumpPowered then
        systemStatus = getText("UI_RailroaderRV_Utility_WaterMissingPower")
    elseif filterExhausted then
        systemStatus = getText("UI_RailroaderRV_Utility_WaterFilterExhausted")
    else
        systemStatus = getText("UI_RailroaderRV_Utility_WaterAvailable")
    end
    local overviewAlert = waterSystemUnavailable(water)
    addRow(list, { kind = "section",
        text = getText("UI_RailroaderRV_Utility_WaterOverview"),
        buttons = {
            { text = getText("UI_RailroaderRV_Utility_Refresh"),
                tone = "neutral",
                action = function(window) Client.requestSnapshot(window.player) end },
        } }, 34)
    addRow(list, { kind = "detail",
        text = getText("UI_RailroaderRV_Utility_WaterSystemStatus")
            .. ": " .. systemStatus,
        alert = overviewAlert, buttons = {} }, 34)
    local tankButtons = {}
    if water.extractionPump then
        tankButtons[#tankButtons + 1] = {
            text = getText("UI_RailroaderRV_Utility_DrawNaturalWater"),
            tone = "positive",
            action = function(window, anchor) window:drawNaturalWater(anchor) end,
        }
    end
    tankButtons[#tankButtons + 1] = {
        text = getText("UI_RailroaderRV_Utility_AddWaterFromContainer"),
        tone = "positive",
        action = function(window, anchor) window:addWaterFromContainer(anchor) end,
    }
    local tankFraction
    if water.capacityL > 0 then tankFraction = water.centralL / water.capacityL end
    addRow(list, { kind = "meter",
        text = getText("UI_RailroaderRV_Utility_RVWaterTank"),
        value = display(water.centralL, 1) .. " / "
            .. display(water.capacityL, 1) .. " L",
        fraction = tankFraction, buttons = tankButtons }, 48)
    local pumpStatus
    local pumpAlert = false
    if not water.supplyPumpInstalled then
        pumpStatus = getText("UI_RailroaderRV_Utility_SupplyPumpMissingSmall")
    elseif not water.supplyPumpPowered then
        pumpStatus = getText("UI_RailroaderRV_Utility_SupplyPumpUnpowered")
        pumpAlert = true
    else
        pumpStatus = getText("UI_RailroaderRV_Utility_SupplyPumpPowered")
            .. " (" .. tostring(W.SUPPLY_PUMP_WATTS) .. " W)"
    end
    addRow(list, { kind = "detail",
        text = getText("UI_RailroaderRV_Utility_SupplyPump")
            .. ": " .. pumpStatus,
        alert = pumpAlert, buttons = {} }, 34)
    local filterStatus
    if not filterInstalled then
        filterStatus = getText("UI_RailroaderRV_Utility_NotInstalled")
    elseif filterExhausted then
        filterStatus = getText("UI_RailroaderRV_Utility_Installed") .. " — "
            .. getText("UI_RailroaderRV_Utility_FilterExhaustedLabel")
    else
        filterStatus = getText("UI_RailroaderRV_Utility_Installed")
    end
    local filterFraction
    if filterInstalled then
        filterFraction = water.filterRemainingL / W.FILTER_CAPACITY_L
    end
    addRow(list, { kind = "meter",
        text = getText("UI_RailroaderRV_Utility_WaterFilter")
            .. ": " .. filterStatus,
        value = getText("UI_RailroaderRV_Utility_FilterCapacityRemaining") .. " "
            .. display(water.filterRemainingL, 1)
            .. " / " .. display(W.FILTER_CAPACITY_L, 1) .. " L",
        fraction = filterFraction, buttons = {} }, 48)
    local rainFraction
    if water.autoCapacityL > 0 then
        rainFraction = water.autoTankL / water.autoCapacityL
    end
    addRow(list, { kind = "meter",
        text = getText("UI_RailroaderRV_Utility_AutoWater"),
        value = display(water.autoTankL, 1) .. " / "
            .. display(water.autoCapacityL, 1) .. " L",
        fraction = rainFraction, buttons = {} }, 48)
    addRow(list, { kind = "section",
        text = getText("UI_RailroaderRV_Utility_WaterRequiredParts"),
        buttons = {} }, 34)
    local tankInstallButtons = {}
    if water.tankCount < W.MAX_WATER_TANKS then
        tankInstallButtons[1] = {
            text = getText("UI_RailroaderRV_Utility_Install"), tone = "positive",
            action = function(window, anchor) window:addWaterTank(anchor) end,
        }
    end
    addRow(list, { kind = "section",
        text = getText("UI_RailroaderRV_Utility_WaterTank") .. "  ("
            .. tostring(water.tankCount) .. "/" .. tostring(W.MAX_WATER_TANKS) .. ")",
        buttons = tankInstallButtons,
        progressOperation = water.tankCount < W.MAX_WATER_TANKS
            and W.OP_INSTALL_WATER_TANK or nil }, 34)
    if water.tankCount == 0 then
        addRow(list, { kind = "detail",
            text = getText("UI_RailroaderRV_Utility_NotInstalled"),
            buttons = {} }, 34)
    else
        for _ = 1, water.tankCount do
            addRow(list, { kind = "detail",
                text = getText("UI_RailroaderRV_Utility_RVWaterTank")
                    .. "  " .. display(W.LITERS_PER_TANK, 1) .. " L",
                buttons = { {
                    text = getText("UI_RailroaderRV_Utility_Remove"),
                    tone = "negative",
                    action = function(window) window:removeWaterTank() end,
                } }, progressOperation = W.OP_REMOVE_WATER_TANK }, 38)
        end
    end
    local supplyInstallButtons = {}
    if not water.supplyPumpInstalled then
        supplyInstallButtons[1] = {
            text = getText("UI_RailroaderRV_Utility_Install"), tone = "positive",
            action = function(window, anchor) window:addSupplyPump(anchor) end,
        }
    end
    addRow(list, { kind = "section",
        text = getText("UI_RailroaderRV_Utility_SupplyPump") .. "  ("
            .. getText("UI_RailroaderRV_Utility_CannotRemove") .. ")",
        buttons = supplyInstallButtons,
        progressOperation = not water.supplyPumpInstalled
            and W.OP_INSTALL_SUPPLY_PUMP or nil }, 34)
    addRow(list, { kind = "detail",
        text = water.supplyPumpInstalled
            and getText("UI_RailroaderRV_Utility_Installed")
            or getText("UI_RailroaderRV_Utility_SupplyPumpMissingSmall"),
        sub = getText("UI_RailroaderRV_Utility_PermanentSupplyPumpHelp"),
        buttons = {} }, 54)
    local filterButtons = {}
    local filterOperation
    if filterInstalled then
        filterButtons[1] = {
            text = getText("UI_RailroaderRV_Utility_Remove"), tone = "negative",
            action = function(window) window:removeWaterFilter() end,
        }
    else
        filterButtons[1] = {
            text = getText("UI_RailroaderRV_Utility_Install"), tone = "positive",
            action = function(window, anchor) window:addWaterFilter(anchor) end,
        }
        filterOperation = W.OP_INSTALL_WATER_FILTER
    end
    addRow(list, { kind = "section",
        text = getText("UI_RailroaderRV_Utility_WaterFilter"),
        buttons = filterButtons, progressOperation = filterOperation }, 34)
    addRow(list, { kind = "detail",
        text = filterInstalled
            and itemDisplayName(water.filter.fullType)
            or getText("UI_RailroaderRV_Utility_NotInstalled"),
        buttons = {}, progressOperation = filterInstalled
            and W.OP_REMOVE_WATER_FILTER or nil }, 34)
    addRow(list, { kind = "section",
        text = getText("UI_RailroaderRV_Utility_WaterOptionalParts"),
        buttons = {} }, 34)
    local extractionPump = water.extractionPump
    local extractionLabel = extractionPump == "small"
        and itemDisplayName(W.SMALL_PUMP_ITEM)
        or extractionPump == "industrial"
            and itemDisplayName(W.INDUSTRIAL_PUMP_ITEM)
            or getText("UI_RailroaderRV_Utility_NotInstalled")
    local extractionSub = extractionPump == "small"
        and (getText("UI_RailroaderRV_Utility_SmallWaterPump") .. "  "
            .. tostring(W.SMALL_PUMP_FLOW_L_PER_MINUTE) .. " L/min  "
            .. tostring(W.SMALL_PUMP_WATTS) .. " W")
        or extractionPump == "industrial"
            and (getText("UI_RailroaderRV_Utility_IndustrialWaterPump") .. "  "
                .. tostring(W.INDUSTRIAL_PUMP_FLOW_L_PER_MINUTE) .. " L/min  "
                .. tostring(W.INDUSTRIAL_PUMP_WATTS) .. " W")
            or nil
    local extractionButtons = {}
    if extractionPump then
        extractionButtons[1] = {
            text = getText("UI_RailroaderRV_Utility_Remove"), tone = "negative",
            action = function(window) window:removeExtractionPump() end,
        }
    else
        extractionButtons[1] = {
            text = getText("UI_RailroaderRV_Utility_Install"), tone = "positive",
            action = function(window, anchor) window:addExtractionPump(anchor) end,
        }
    end
    addRow(list, { kind = "section",
        text = getText("UI_RailroaderRV_Utility_ExtractionPump"),
        buttons = extractionButtons,
        progressOperation = not extractionPump
            and W.OP_INSTALL_EXTRACTION_PUMP or nil }, 34)
    addRow(list, { kind = "detail",
        text = extractionLabel,
        sub = extractionSub
            and (getText("UI_RailroaderRV_Utility_ExtractionPumpHelp") .. "  "
                .. extractionSub)
            or getText("UI_RailroaderRV_Utility_ExtractionPumpHelp"),
        buttons = {}, progressOperation = extractionPump
            and W.OP_REMOVE_EXTRACTION_PUMP or nil }, 54)
    addRow(list, { kind = "section",
        text = getText("UI_RailroaderRV_Utility_RoofCollectors"),
        buttons = {
            { text = getText("UI_RailroaderRV_Roof_InstallRemove"),
                tone = "neutral",
                action = function(window) RoofWindow.show(window.player) end },
        }, progressOperation = U.OP_INSTALL_ROOF_DEVICE,
        progressDeviceType = Roof.DEVICE_RAIN }, 34)
    if #collectorKeys == 0 then
        addRow(list, { kind = "detail",
            text = getText("UI_RailroaderRV_Utility_NotInstalled"),
            buttons = {} }, 34)
    end
    for _, key in ipairs(collectorKeys) do
        local collector = water.roofCollectors[key]
        addRow(list, { kind = "detail",
            text = itemDisplayName(collector.factoryType)
                .. "  |  " .. display(collector.capacityL, 1) .. " L",
            buttons = {} }, 54)
    end
    addRow(list, { kind = "detail",
        text = getText("UI_RailroaderRV_Utility_WaterSinks")
            .. "  |  " .. tostring(connectedCount) .. " / "
            .. tostring(#sinkKeys),
        sub = getText("UI_RailroaderRV_Utility_WaterConnectHelp"),
        buttons = {} }, 54)
    if #sinkKeys == 0 then
        addRow(list, { kind = "detail",
            text = getText("UI_RailroaderRV_Utility_NoWaterSinks"), buttons = {} }, 38)
    else
        for _, key in ipairs(sinkKeys) do
            local sink = water.sinks[key]
            local state = sink.connected
                and getText("UI_RailroaderRV_Utility_Connected")
                or getText("UI_RailroaderRV_Utility_Disconnected")
            addRow(list, { kind = "detail", text = key .. "  ·  " .. state,
                buttons = {} }, 38)
        end
    end
    local activeAction = self.window.activeWaterAction
    if activeAction then
        local actionName = activeAction.operation == W.OP_ADD_WATER_FROM_CONTAINER
            and getText("UI_RailroaderRV_Utility_AddWaterFromContainer")
            or getText("UI_RailroaderRV_Utility_DrawNaturalWater")
        local stopButton = {
            text = getText("UI_RailroaderRV_Utility_Stop"), tone = "negative",
            action = function(window) window:cancelWaterAction() end,
        }
        addRow(list, { kind = "detail",
            text = getText("UI_RailroaderRV_Utility_WaterActionRunning")
                .. ": " .. actionName,
            buttons = { stopButton }, progressOperation = activeAction.operation,
            useWaterActionHandle = true }, 38)
    end
    local height = 0
    for _, entry in ipairs(list.items) do height = height + entry.height end
    list:setScrollHeight(height)
    list:setYScroll(scroll)
end

local Window = ISCollapsableWindow:derive("RVUtilityDashboardWindow")

    function Window:createChildren()
        ISCollapsableWindow.createChildren(self)
        local top = self:titleBarHeight() + 8
        local width = self.width - 24
        self.statusLabel = ISLabel:new(12, top, getTextManager():getFontHeight(UIFont.Small),
            getText("UI_RailroaderRV_Utility_Loading"),
            1, 1, 1, 1, UIFont.Small, true)
        self.statusLabel:initialise()
        self:addChild(self.statusLabel)

        local tabsY = top + getTextManager():getFontHeight(UIFont.Small) + 6
        local tabHeight = self.height - tabsY - 12
        self.tabs = ISTabPanel:new(12, tabsY, width, tabHeight)
        self.tabs:initialise()
        self.tabs.tabPadX = 30
        self:addChild(self.tabs)

        self.powerPage = PowerPage:new(0, 0, width, tabHeight - self.tabs.tabHeight)
        self.powerPage.window = self
        self.powerPage:initialise()
        self.tabs:addView(getText("UI_RailroaderRV_Utility_ElectricityTab"),
            self.powerPage)

        self.waterPage = WaterPage:new(0, 0, width, tabHeight - self.tabs.tabHeight)
        self.waterPage.window = self
        self.waterPage:initialise()
        self.tabs:addView(getText("UI_RailroaderRV_Utility_WaterTab"),
            self.waterPage)
        self.tabs.target = self
        self.tabs.onActivateView = function(window)
            window:clearLocalStatus()
            Client.requestSnapshot(window.player)
        end
    end

    function Window:prerender()
        if not hasCurrentUtilityContext(self.player, self.mappingKey) then
            self:close(false)
            return
        end
        ISCollapsableWindow.prerender(self)
    end

    function Window:setStatus(value)
        self.statusLabel:setNameWithoutMoving(tostring(value))
    end

    function Window:setLocalStatus(value)
        self.localStatus = tostring(value)
        self:setStatus(self.localStatus)
    end

    function Window:clearLocalStatus()
        self.localStatus = nil
    end

    function Window:requestTimed(operation, targetHint, item)
        self:clearLocalStatus()
        Client.queueTimedAction(self.player, operation, item, targetHint,
            self.mappingKey)
    end

    function Window:startWaterAction(operation, item)
        if self.activeWaterAction then return false end
        local queued = Client.queueTimedAction(self.player, operation, item,
            nil, self.mappingKey, false, function(action)
                action.onUtilityActionEnded = function(endedAction)
                    self:onWaterActionEnded(endedAction)
                end
                self.activeWaterAction = action
            end)
        return queued == true
    end

    function Window:onWaterActionEnded(action)
        if self.activeWaterAction ~= action then return end
        self.activeWaterAction = nil
        self.waterPage:refresh(Client.getSnapshot())
        if self:getIsVisible() then Client.requestSnapshot(self.player) end
    end

    function Window:cancelWaterAction()
        local action = self.activeWaterAction
        if not action then return false end
        return Client.cancelTimedAction(self.player, action)
    end

    function Window:addWaterTank(anchor)
        self:addComponent(anchor, W.OP_INSTALL_WATER_TANK, W.WATER_TANK_ITEM,
            getText("UI_RailroaderRV_Utility_NoWaterTankInInventory"))
    end

    function Window:removeWaterTank()
        self:requestTimed(W.OP_REMOVE_WATER_TANK)
    end

    function Window:addSupplyPump(anchor)
        self:addComponent(anchor, W.OP_INSTALL_SUPPLY_PUMP, W.SMALL_PUMP_ITEM,
            getText("UI_RailroaderRV_Utility_NoSmallPumpInInventory"))
    end

    function Window:addExtractionPump(anchor)
        Client.requestSnapshot(self.player)
        itemMenu(self, anchor, function(item)
            local fullType = item:getFullType()
            return fullType == W.SMALL_PUMP_ITEM
                or fullType == W.INDUSTRIAL_PUMP_ITEM
        end, function(window, item)
            window:requestTimed(W.OP_INSTALL_EXTRACTION_PUMP, nil, item)
        end, getText("UI_RailroaderRV_Utility_NoExtractionPumpInInventory"))
    end

    function Window:removeExtractionPump()
        self:requestTimed(W.OP_REMOVE_EXTRACTION_PUMP)
    end

    function Window:addWaterFilter(anchor)
        self:addComponent(anchor, W.OP_INSTALL_WATER_FILTER, W.WATER_FILTER_ITEM,
            getText("UI_RailroaderRV_Utility_NoWaterFilterInInventory"))
    end

    function Window:removeWaterFilter()
        self:requestTimed(W.OP_REMOVE_WATER_FILTER)
    end

    function Window:addWaterFromContainer(anchor)
        local snapshot = Client.getSnapshot()
        if not snapshot or mappingKey(snapshot) ~= self.mappingKey then return false end
        Client.requestSnapshot(self.player)
        if waterSystemUnavailable(snapshot.water) then
            local menu = ISContextMenu.get(self.player:getPlayerNum(), anchor.x, anchor.y)
            local option = menu:addOption(
                getText("UI_RailroaderRV_Utility_WaterSystemMissingComponents"))
            option.notAvailable = true
            menu:addToUIManager()
            return true
        end
        itemMenu(self, anchor, function(item)
            return Inventory.canAddWater(item, snapshot)
        end, function(window, item)
            window:startWaterAction(W.OP_ADD_WATER_FROM_CONTAINER, item)
        end, getText("UI_RailroaderRV_Utility_NoWaterContainersInInventory"))
        return true
    end

    function Window:drawNaturalWater(anchor)
        self:clearLocalStatus()
        local snapshot = Client.getSnapshot()
        local inventoryItems = {}
        Inventory.appendItems(self.player:getInventory(), inventoryItems, {})
        local hasRubberHose = false
        for _, item in ipairs(inventoryItems) do
            if item:getFullType() == "Base.RubberHose" then
                hasRubberHose = true
                break
            end
        end
        local menu = ISContextMenu.get(self.player:getPlayerNum(), anchor.x, anchor.y)
        if not hasRubberHose then
            local option = menu:addOption(
                getText("UI_RailroaderRV_Utility_MissingRubberHose"))
            option.notAvailable = true
        elseif snapshot.power.circuitState ~= U.CIRCUIT_ON then
            local option = menu:addOption(
                getText("UI_RailroaderRV_Utility_MissingPower"))
            option.notAvailable = true
        else
            local cleanSources, infiniteTainted, largestTainted = {}, nil, nil
            local candidates = Client.listNaturalWaterSources(self.player)
            for _, candidate in ipairs(candidates) do
                if candidate.kind == "clean" then
                    cleanSources[#cleanSources + 1] = candidate
                elseif candidate.kind == "tainted" then
                    if candidate.infinite then
                        if not infiniteTainted then infiniteTainted = candidate end
                    elseif not largestTainted or candidate.volumeL > largestTainted.volumeL then
                        largestTainted = candidate
                    end
                else
                    error("Unexpected natural water source kind: "
                        .. tostring(candidate.kind))
                end
            end
            local choices = cleanSources
            local taintedChoice = infiniteTainted or largestTainted
            if taintedChoice then choices[#choices + 1] = taintedChoice end
            if #choices == 0 then
                local option = menu:addOption(
                    getText("UI_RailroaderRV_Utility_NoNearbyNaturalWater"))
                option.notAvailable = true
            else
                for _, candidate in ipairs(choices) do
                    local selectedCandidate = candidate
                    local kindText = candidate.kind == "clean"
                        and getText("UI_RailroaderRV_Utility_CleanWater")
                        or getText("UI_RailroaderRV_Utility_TaintedWater")
                    menu:addOption(candidate.displayName .. "  |  " .. kindText,
                        self, function(window)
                            if window.activeWaterAction then return end
                            window:clearLocalStatus()
                            Client.requestDrawWaterFromSource(window.player,
                                selectedCandidate.sourceObject, window.mappingKey,
                                function(action)
                                    action.onUtilityActionEnded = function(endedAction)
                                        window:onWaterActionEnded(endedAction)
                                    end
                                    window.activeWaterAction = action
                                end)
                        end)
                end
            end
        end
        menu:addToUIManager()
        return true
    end

    function Window:addFuel(anchor)
        self:clearLocalStatus()
        local snapshot = Client.getSnapshot()
        local missingFuelTank = #snapshot.power.fuelTanks == 0
        Client.requestSnapshot(self.player)
        if missingFuelTank then
            itemMenu(self, anchor, function() return false end, function() end,
                getText("UI_RailroaderRV_Utility_FuelTankRequired"))
            return
        end
        itemMenu(self, anchor, fluidFuel, function(window, item)
            window:requestTimed(U.OP_ADD_FUEL, nil, item)
        end, getText("UI_RailroaderRV_Utility_NoFuel"))
    end

    function Window:addFuelTank(anchor)
        Client.requestSnapshot(self.player)
        itemMenu(self, anchor, function(item)
            return P.GAS_TANK_TYPES[item:getFullType()] == true
        end, function(window, item)
            window:requestTimed(U.OP_ADD_FUEL_TANK, nil, item)
        end, getText("UI_RailroaderRV_Utility_NoFuelTanksInInventory"))
    end

    function Window:removeFuelTank(fuelTankId)
        self:requestTimed(U.OP_REMOVE_FUEL_TANK, { fuelTankId = fuelTankId })
    end

    function Window:addBattery(anchor)
        Client.requestSnapshot(self.player)
        itemMenu(self, anchor, batteryItem, function(window, item)
            window:requestTimed(U.OP_ADD_BATTERY, nil, item)
        end, getText("UI_RailroaderRV_Utility_NoBatteriesInInventory"))
    end

    function Window:removeBattery(batteryId)
        self:requestTimed(U.OP_REMOVE_BATTERY, { batteryId = batteryId })
    end

    function Window:addComponent(anchor, operation, fullType, emptyText, labelFor)
        Client.requestSnapshot(self.player)
        itemMenu(self, anchor, function(item) return item:getFullType() == fullType end,
            function(window, item)
                window:requestTimed(operation, nil, item)
            end, emptyText, labelFor)
    end

    local function componentEfficiencyLabel(item)
        return itemLabel(item) .. "  |  "
            .. getText("UI_RailroaderRV_Utility_Efficiency") .. ": "
            .. display(item:getCondition() / item:getConditionMax() * 100, 0) .. "%"
    end

    function Window:addCharger(anchor)
        self:addComponent(anchor, U.OP_INSTALL_CHARGER, P.CHARGER_TYPE,
            getText("UI_RailroaderRV_Utility_NoChargerInInventory"),
            componentEfficiencyLabel)
    end

    function Window:addInverter(anchor)
        self:addComponent(anchor, U.OP_INSTALL_INVERTER, P.INVERTER_TYPE,
            getText("UI_RailroaderRV_Utility_NoInverterInInventory"),
            componentEfficiencyLabel)
    end

    function Window:addCircuitBreaker(anchor)
        self:addComponent(anchor, U.OP_INSTALL_CIRCUIT_BREAKER,
            P.CIRCUIT_BREAKER_TYPE,
            getText("UI_RailroaderRV_Utility_NoCircuitBreakerInInventory"))
    end

    function Window:addController(anchor)
        self:addComponent(anchor, U.OP_INSTALL_CONTROLLER, P.CONTROLLER_TYPE,
            getText("UI_RailroaderRV_Utility_NoControllerInInventory"))
    end

    function Window:toggleGenerator(generatorId, enabled, fuelAmount, anchor)
        if not enabled and fuelAmount <= 0 then
            local menu = ISContextMenu.get(self.player:getPlayerNum(), anchor.x, anchor.y)
            local option = menu:addOption(
                getText("UI_RailroaderRV_Utility_MissingFuel"))
            option.notAvailable = true
            menu:addToUIManager()
            return false
        end
        Client.requestPowerOperation(self.player,
            enabled and U.OP_STOP_GENERATOR or U.OP_START_GENERATOR,
            { generatorId = generatorId })
    end

    function Window:refresh(snapshot)
        local current = snapshot or Client.getSnapshot()
        if current and mappingKey(current) ~= self.mappingKey then current = nil end
        self.powerPage:refresh(current)
        self.waterPage:refresh(current)
        if self.localStatus and current and #current.power.fuelTanks == 0 then
            self:setStatus(self.localStatus)
        else
            self.localStatus = nil
            self:setStatus(current
                and getText("UI_RailroaderRV_Utility_Updated")
                or getText("UI_RailroaderRV_Utility_Loading"))
        end
    end

    function Window:close(requestSnapshot)
        self:setVisible(false)
        self:removeFromUIManager()
        if Dashboard.instance == self then Dashboard.instance = nil end
        if requestSnapshot ~= false then Client.requestSnapshot(self.player) end
    end

    function Window:new(x, y, width, height, player)
        local o = ISCollapsableWindow:new(x, y, width, height)
        setmetatable(o, self)
        self.__index = self
        o.player = player
        o.activeWaterAction = nil
        o.mappingKey = mappingKey(currentUtilityMapping())
        o:setResizable(false)
        o:setTitle(getText("UI_RailroaderRV_Utility_Title"))
        return o
    end

function Dashboard.refresh(snapshot)
    if Dashboard.instance then Dashboard.instance:refresh(snapshot) end
end

function Dashboard.onConnectionReset()
    RoofWindow.onConnectionReset()
    local instance = Dashboard.instance
    Dashboard.instance = nil
    if instance then
        instance:setVisible(false)
        instance:removeFromUIManager()
    end
end

function Dashboard.show(player)
    if not player then return false end
    if Dashboard.instance then
        Dashboard.instance.player = player
        Dashboard.instance.mappingKey = mappingKey(currentUtilityMapping())
        Dashboard.instance:setVisible(true)
        Dashboard.instance:bringToTop()
        Dashboard.instance:clearLocalStatus()
        Dashboard.instance:refresh()
        Client.requestSnapshot(player)
        return true
    end
    local core = getCore()
    local screenWidth, screenHeight = core:getScreenWidth(), core:getScreenHeight()
    local width = math.min(980, screenWidth - 40)
    local height = math.min(760, screenHeight - 60)
    local window = Window:new((screenWidth - width) / 2,
        (screenHeight - height) / 2, width, height, player)
    window:initialise()
    window:addToUIManager()
    Dashboard.instance = window
    window:refresh()
    Client.requestSnapshot(player)
    return true
end

function Dashboard.onSnapshot(player, snapshot)
    RoofWindow.onSnapshot(player, snapshot)
    local instance = Dashboard.instance
    if not instance or not instance:getIsVisible() or instance.player ~= player then
        return false
    end
    if mappingKey(snapshot) ~= instance.mappingKey then return false end
    instance:refresh(snapshot)
    return true
end

function Dashboard.onMappingChanged(player, mapping)
    local roofChanged = RoofWindow.onMappingChanged(player, mapping)
    local instance = Dashboard.instance
    local dashboardVisible = instance and instance:getIsVisible()
        and instance.player == player
    if dashboardVisible then
        instance:cancelWaterAction()
        instance.mappingKey = mappingKey(mapping)
        instance:clearLocalStatus()
        instance:refresh(nil)
    end
    if roofChanged or dashboardVisible then Client.requestSnapshot(player) end
end

return Dashboard
