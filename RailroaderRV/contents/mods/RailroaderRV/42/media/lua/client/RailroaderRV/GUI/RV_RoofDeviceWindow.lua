require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISContextMenu"
require "ISUI/ISPanel"

local Client = require("RailroaderRV/GUI/RV_UtilityClient")
local Inventory = require("RailroaderRV/GUI/RV_UtilityInventory")
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local P = U.POWER
local Roof = require("RailroaderRV/Roof/RV_RoofDevices")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")

RailroaderRV = RailroaderRV or {}
RailroaderRV.RoofDeviceWindow = RailroaderRV.RoofDeviceWindow or {}
local RoofWindow = RailroaderRV.RoofDeviceWindow

local COLORS = {
    SOLAR = { r = 1.00, g = 0.82, b = 0.05 },
    RAIN = { r = 0.73, g = 0.20, b = 0.88 },
    FUEL = { r = 0.92, g = 0.20, b = 0.20 },
    WIND = { r = 0.08, g = 0.48, b = 1.00 },
}

local BUTTON_TONES = {
    positive = { r = 0.10, g = 0.48, b = 0.18 },
    negative = { r = 0.64, g = 0.13, b = 0.14 },
}

local DEVICE_LABELS = {
    SOLAR = "UI_RailroaderRV_Roof_Solar",
    RAIN = "UI_RailroaderRV_Roof_RainCollector",
    FUEL = "UI_RailroaderRV_Roof_FuelGenerator",
    WIND = "UI_RailroaderRV_Roof_WindTurbine",
}

local function mappingKey(value)
    return Client.mappingKey(value)
end

local function currentMapping()
    return RailroaderRV.RailroaderContextMenu.getUtilityMapping()
end

local function hasCurrentUtilityContext(player, expectedMappingKey)
    local menu = RailroaderRV.RailroaderContextMenu
    local mapping = menu.getUtilityMapping()
    return mapping ~= nil
        and mappingKey(mapping) == expectedMappingKey
        and menu.hasUtilityDashboardCandidate(player)
end

local function itemMenu(window, anchor, matches, choose, emptyText)
    local inventoryItems = {}
    Inventory.appendItems(window.player:getInventory(), inventoryItems, {})
    local menu = ISContextMenu.get(window.player:getPlayerNum(), anchor.x, anchor.y)
    local found = 0
    for _, item in ipairs(inventoryItems) do
        if matches(item) then
            found = found + 1
            local selectedItem = item
            local label = item:getName()
            if Roof.typeForItem(item) == Roof.DEVICE_RAIN then
                label = label .. " ("
                    .. string.format("%.1f L", item:getFluidContainer():getCapacity()) .. ")"
            end
            menu:addOption(label, window, function(target)
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

local function sameCell(first, second)
    return first and second and first.x == second.x and first.y == second.y
        and first.z == second.z
end

local Canvas = ISPanel:derive("RVRoofDeviceCanvas")

function Canvas:new(x, y, width, height, window)
    local o = ISPanel.new(self, x, y, width, height)
    o.window = window
    o.background = true
    o.backgroundColor = { r = 0.025, g = 0.035, b = 0.045, a = 0.92 }
    o.borderColor = { r = 0.34, g = 0.40, b = 0.45, a = 1.0 }
    o.entries = {}
    o.tileWidth = 0
    o.tileHeight = 0
    o:rebuildLayout()
    return o
end

function Canvas:rebuildLayout()
    local roofCells = self.window.roofCells
    if not roofCells then
        self.entries = {}
        self.tileWidth = 0
        self.tileHeight = 0
        return
    end
    local minDiagonal, maxDiagonal = math.huge, -math.huge
    local minDepth, maxDepth = math.huge, -math.huge
    for _, cell in ipairs(roofCells) do
        local diagonal = cell.x - cell.y
        local depth = cell.x + cell.y
        minDiagonal = math.min(minDiagonal, diagonal)
        maxDiagonal = math.max(maxDiagonal, diagonal)
        minDepth = math.min(minDepth, depth)
        maxDepth = math.max(maxDepth, depth)
    end
    local widthSteps = (maxDiagonal - minDiagonal) / 2 + 1
    local heightSteps = (maxDepth - minDepth) / 4 + 0.5
    local tileWidth = math.min(54,
        (self.width - 40) / widthSteps,
        (self.height - 70) / heightSteps)
    self.tileWidth = tileWidth
    self.tileHeight = tileWidth / 2
    local mapWidth = tileWidth * widthSteps
    local mapHeight = tileWidth * heightSteps
    local offsetX = (self.width - mapWidth) / 2 + tileWidth / 2
    local offsetY = (self.height - mapHeight) / 2 + tileWidth / 4
    self.entries = {}
    for _, cell in ipairs(roofCells) do
        self.entries[#self.entries + 1] = {
            cell = cell,
            x = offsetX + (cell.x - cell.y - minDiagonal) * tileWidth / 2,
            y = offsetY + (cell.x + cell.y - minDepth) * tileWidth / 4,
        }
    end
    table.sort(self.entries, function(first, second)
        local firstDepth = first.cell.x + first.cell.y
        local secondDepth = second.cell.x + second.cell.y
        if firstDepth ~= secondDepth then return firstDepth < secondDepth end
        return first.cell.x < second.cell.x
    end)
end

function Canvas:hitTest(x, y)
    local halfWidth, halfHeight = self.tileWidth / 2, self.tileHeight / 2
    for index = #self.entries, 1, -1 do
        local entry = self.entries[index]
        if math.abs(x - entry.x) / halfWidth
                + math.abs(y - entry.y) / halfHeight <= 1 then
            return entry.cell
        end
    end
    return nil
end

function Canvas:onMouseMove(dx, dy)
    self.hoveredCell = self:hitTest(self:getMouseX(), self:getMouseY())
end

function Canvas:onMouseMoveOutside(dx, dy)
    self.hoveredCell = nil
end

function Canvas:onMouseDown(x, y)
    local cell = self:hitTest(x, y)
    if cell then self.window:onCellClicked(cell) end
    return true
end

function Canvas:onRightMouseDown(x, y)
    self.window:clearSelection()
    self.window:cancelRoofAction()
    return true
end

local function drawDiamond(element, centerX, centerY, width, height,
        color, alpha, borderAlpha)
    local left, right = centerX - width / 2, centerX + width / 2
    local top, bottom = centerY - height / 2, centerY + height / 2
    if alpha > 0 then
        element:drawPolygon(nil, centerX, top, right, centerY,
            centerX, bottom, left, centerY,
            color.r, color.g, color.b, alpha)
    end
    local lineAlpha = borderAlpha or alpha
    element:drawLine(nil, centerX, top, right, centerY, 1.0,
        lineAlpha, 0.5, 0.5, 0.5)
    element:drawLine(nil, right, centerY, centerX, bottom, 1.0,
        lineAlpha, 0.5, 0.5, 0.5)
    element:drawLine(nil, centerX, bottom, left, centerY, 1.0,
        lineAlpha, 0.5, 0.5, 0.5)
    element:drawLine(nil, left, centerY, centerX, top, 1.0,
        lineAlpha, 0.5, 0.5, 0.5)
end

function Canvas:render()
    if self.width ~= self.lastWidth or self.height ~= self.lastHeight then
        self.lastWidth, self.lastHeight = self.width, self.height
        self:rebuildLayout()
    end
    local window = self.window
    local devices = window.devices
    for _, entry in ipairs(self.entries) do
        local cell = entry.cell
        local device = Roof.deviceAt(devices, cell)
        local mode = window.selectionMode
        local canOperate = false
        local color
        local alpha = 0
        local borderAlpha = 0.68
        if mode == "install" then
            canOperate = Roof.canPlace(window.template, devices, cell,
                window.selectedType)
            if canOperate then
                color = COLORS[window.selectedType]
                alpha = 0.20
                borderAlpha = 0.82
            end
        elseif mode == "remove" then
            canOperate = device ~= nil
        end
        if device then
            color = COLORS[device.type]
            alpha = mode == "remove" and canOperate and 0.20 or 0.70
            borderAlpha = 0.88
        end

        local hovered = sameCell(self.hoveredCell, cell)
        if hovered and canOperate then
            if mode == "install" then color = COLORS[window.selectedType] end
            alpha = 1.0
            borderAlpha = 1.0
        elseif hovered and not mode and device then
            alpha = 1.0
            borderAlpha = 1.0
        end

        if device or color then
            drawDiamond(self, entry.x, entry.y,
                self.tileWidth, self.tileHeight, color, alpha, borderAlpha)
        else
            drawDiamond(self, entry.x, entry.y,
                self.tileWidth, self.tileHeight,
                { r = 0.58, g = 0.63, b = 0.68 }, 0,
                hovered and 1.0 or 0.58)
        end

        if mode == "install" and not canOperate and hovered then
            self:drawTextCentre("X", entry.x,
                entry.y - getTextManager():getFontHeight(UIFont.Medium) / 2,
                1.0, 0.20, 0.20, 1.0, UIFont.Medium)
        end
    end
end

local Window = ISCollapsableWindow:derive("RVRoofDeviceWindow")

function Window:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight() + 8
    self.sidebarWidth = 300
    self.sidebarX = self.width - self.sidebarWidth - 12
    local footerY = self.height - 52
    self.canvas = Canvas:new(12, top, self.sidebarX - 24,
        footerY - top - 10, self)
    self.canvas:initialise()
    self:addChild(self.canvas)

    local buttonX = self.sidebarX + 12
    local buttonWidth = self.sidebarWidth - 24
    local buttonHeight = 34
    local buttonGap = 8
    local function addButton(y, title, callback, tone)
        local button = ISButton:new(buttonX, y, buttonWidth, buttonHeight,
            title, self, callback)
        local color = BUTTON_TONES[tone]
        button:setBackgroundRGBA(color.r, color.g, color.b, 0.9)
        button:setBackgroundColorMouseOverRGBA(
            color.r + 0.08, color.g + 0.08, color.b + 0.08, 1)
        button:initialise()
        button:setFont(UIFont.Small)
        self:addChild(button)
        return button
    end
    self.addGeneratorButton = addButton(top + 12,
        getText("UI_RailroaderRV_Roof_AddGenerator"),
        Window.onAddGenerator, "positive")
    self.addRainButton = addButton(top + 12 + buttonHeight + buttonGap,
        getText("UI_RailroaderRV_Roof_AddRainCollector"),
        Window.onAddRainCollector, "positive")
    self.removeButton = addButton(top + 12 + 2 * (buttonHeight + buttonGap),
        getText("UI_RailroaderRV_Roof_RemoveDevice"),
        Window.onRemoveDevice, "negative")
    self.addGeneratorButton:setEnable(false)
    self.addRainButton:setEnable(false)
    self.removeButton:setEnable(false)
end

function Window:prerender()
    local dashboardWindow = RailroaderRV.UtilityDashboard.instance
    if dashboardWindow and dashboardWindow.player == self.player
            and not hasCurrentUtilityContext(dashboardWindow.player,
                dashboardWindow.mappingKey) then
        dashboardWindow:close(false)
    end
    if not hasCurrentUtilityContext(self.player, self.mappingKey) then
        self:close()
        return
    end
    ISCollapsableWindow.prerender(self)
    local top = self:titleBarHeight() + 8
    local footerY = self.height - 52
    self:drawRect(self.sidebarX, top, self.sidebarWidth,
        footerY - top - 10, 0.92, 0.04, 0.05, 0.06)
    self:drawRectBorder(self.sidebarX, top, self.sidebarWidth,
        footerY - top - 10, 0.8, 0.34, 0.40, 0.45)
    local titleY = top + 12 + 3 * 34 + 2 * 8 + 12
    self:drawText(getText("UI_RailroaderRV_Roof_Legend"),
        self.sidebarX + 14, titleY, 0.94, 0.94, 0.94, 1.0, UIFont.Medium)

    local legend = {
        { key = "EMPTY", label = "UI_RailroaderRV_Roof_Empty" },
        { key = "SOLAR", label = DEVICE_LABELS.SOLAR },
        { key = "RAIN", label = DEVICE_LABELS.RAIN },
        { key = "FUEL", label = DEVICE_LABELS.FUEL },
        { key = "WIND", label = DEVICE_LABELS.WIND },
        { key = "OPERABLE", label = "UI_RailroaderRV_Roof_Operable" },
        { key = "HOVER", label = "UI_RailroaderRV_Roof_Hovered" },
        { key = "BLOCKED", label = "UI_RailroaderRV_Roof_Blocked" },
    }
    local rowY = titleY + 30
    for _, row in ipairs(legend) do
        local color = COLORS[row.key] or { r = 0.58, g = 0.63, b = 0.68 }
        local alpha = 0.70
        if row.key == "EMPTY" then alpha = 0 end
        if row.key == "OPERABLE" then
            color = self.selectedType and COLORS[self.selectedType]
                or COLORS.WIND
            alpha = 0.20
        elseif row.key == "HOVER" then
            color = COLORS.WIND
            alpha = 1.0
        elseif row.key == "BLOCKED" then
            color = { r = 1.0, g = 0.12, b = 0.12 }
            alpha = 0
        end
        drawDiamond(self, self.sidebarX + 34, rowY + 9, 30, 16,
            color, alpha, row.key == "HOVER" and 1.0 or 0.85)
        if row.key == "BLOCKED" then
            self:drawTextCentre("X", self.sidebarX + 34,
                rowY + 9 - getTextManager():getFontHeight(UIFont.Small) / 2,
                1.0, color.r, color.g, color.b, UIFont.Small)
        end
        self:drawText(getText(row.label), self.sidebarX + 62, rowY,
            0.92, 0.92, 0.92, 1.0, UIFont.Small)
        rowY = rowY + 31
    end
    self:drawText(getText("UI_RailroaderRV_Roof_CellCount")
        .. ": " .. tostring(self.roofCells and #self.roofCells or 0),
        self.sidebarX + 14, rowY + 6, 0.72, 0.76, 0.79, 1.0, UIFont.Small)

    local action = self:activeAction()
    local status
    local progress = nil
    if action then
        local itemName = action.item and action.item:getName()
            or getText("UI_RailroaderRV_Roof_Device")
        local install = action.operation == U.OP_INSTALL_ROOF_DEVICE
        status = getText(install
            and "UI_RailroaderRV_Roof_Installing"
            or "UI_RailroaderRV_Roof_Removing") .. ": " .. itemName
        progress = action:getJobDelta()
    elseif self.selectionMode == "install" then
        status = getText("UI_RailroaderRV_Roof_SelectInstallCell")
            .. ": " .. self.selectedItem:getName()
    elseif self.selectionMode == "remove" then
        status = getText("UI_RailroaderRV_Roof_SelectRemoveCell")
    else
        status = self.snapshot
            and getText("UI_RailroaderRV_Roof_Ready")
            or getText("UI_RailroaderRV_Utility_Loading")
    end
    self:drawText(status, 16, footerY + 6,
        0.94, 0.94, 0.94, 1.0, UIFont.Small)
    local barX = math.min(360, self.width * 0.38)
    local barY = footerY + 7
    local barWidth = self.width - barX - 28
    local barHeight = 18
    self:drawRect(barX, barY, barWidth, barHeight,
        0.85, 0.10, 0.12, 0.14)
    if progress then
        local filled = math.floor(barWidth * progress)
        if filled > 0 then
            self:drawRect(barX, barY, filled, barHeight,
                0.55, 0.08, 0.82, 0.32)
        end
    end
    self:drawRectBorder(barX, barY, barWidth, barHeight,
        0.8, 0.42, 0.48, 0.52)
end

function Window:activeAction()
    return self.activeRoofAction
end

function Window:cancelRoofAction()
    local action = self.activeRoofAction
    if action then action:forceStop() end
    self.activeRoofAction = nil
    self:updateActionButtons()
end

function Window:onRoofActionEnded(action)
    if self.activeRoofAction == action then
        self.activeRoofAction = nil
        self:updateActionButtons()
    end
end

function Window:updateActionButtons()
    local enabled = self.snapshot ~= nil
        and self.activeRoofAction == nil
    self.addGeneratorButton:setEnable(enabled)
    self.addRainButton:setEnable(enabled)
    self.removeButton:setEnable(enabled)
end

function Window:onMappingChanged(mapping)
    local nextKey = mappingKey(mapping)
    if nextKey == self.mappingKey then return false end
    self:cancelRoofAction()
    self.mappingKey = nextKey
    self.snapshot = nil
    self.template = nil
    self.templateId = nil
    self.roofCells = nil
    self.devices = {}
    self:clearSelection()
    self.canvas:rebuildLayout()
    self:updateActionButtons()
    return true
end

function Window:clearSelection()
    self.selectionMode = nil
    self.selectedType = nil
    self.selectedItem = nil
end

function Window:selectItem(item)
    self.selectedType = Roof.typeForItem(item)
    self.selectedItem = item
    self.selectionMode = "install"
end

function Window:contextAnchor(button)
    return {
        x = button:getAbsoluteX() + button:getWidth(),
        y = button:getAbsoluteY(),
    }
end

function Window:onAddGenerator(button)
    Client.requestSnapshot(self.player)
    self:clearSelection()
    itemMenu(self, self:contextAnchor(button), function(item)
        return P.GENERATOR_TYPES[item:getFullType()] ~= nil
            and Roof.typeForItem(item) ~= nil
    end, function(window, item)
        window:selectItem(item)
    end, getText("UI_RailroaderRV_Utility_NoGeneratorsInInventory"))
end

function Window:onAddRainCollector(button)
    Client.requestSnapshot(self.player)
    self:clearSelection()
    itemMenu(self, self:contextAnchor(button), function(item)
        return Roof.typeForItem(item) == Roof.DEVICE_RAIN
    end, function(window, item)
        window:selectItem(item)
    end, getText("UI_RailroaderRV_Roof_NoRainCollectorInInventory"))
end

function Window:onRemoveDevice()
    self.selectedItem = nil
    self.selectedType = nil
    self.selectionMode = "remove"
end

function Window:onRightMouseDown(x, y)
    self:clearSelection()
    self:cancelRoofAction()
    return true
end

function Window:onCellClicked(cell)
    if self.selectionMode == "install" then
        if not Roof.canPlace(self.template, self.devices, cell,
                self.selectedType) then return end
        self:queueRoofAction(U.OP_INSTALL_ROOF_DEVICE,
            self.selectedItem, cell)
        return
    end
    if self.selectionMode == "remove"
            and Roof.deviceAt(self.devices, cell) ~= nil then
        self:queueRoofAction(U.OP_REMOVE_ROOF_DEVICE, nil, cell)
    end
end

function Window:queueRoofAction(operation, item, cell)
    local targetHint = { x = cell.x, y = cell.y, z = cell.z }
    local queued = Client.queueTimedAction(self.player, operation, item,
        targetHint, self.mappingKey, true, function(action)
            action.onRoofActionEnded = function(endedAction)
                self:onRoofActionEnded(endedAction)
            end
            self.activeRoofAction = action
        end)
    if queued then
        self:clearSelection()
        self:updateActionButtons()
    end
    return queued
end

function Window:refresh(snapshot)
    local current = snapshot or Client.getSnapshot()
    if current and mappingKey(current) ~= self.mappingKey then current = nil end
    local templateChanged = current
        and (self.snapshot == nil or self.templateId ~= current.templateId)
    self.snapshot = current
    if current then
        if templateChanged then
            self:cancelRoofAction()
            self:clearSelection()
            self.templateId = current.templateId
            self.template = RoomTemplate.get(current.templateId)
            self.roofCells = Roof.cells(self.template)
            self.canvas:rebuildLayout()
        end
        self.devices = current.roofDevices
    else
        self:cancelRoofAction()
        self.devices = {}
        self.template = nil
        self.templateId = nil
        self.roofCells = nil
        self.canvas:rebuildLayout()
        self:clearSelection()
    end
    self:updateActionButtons()
end

function Window:close()
    self:clearSelection()
    self:cancelRoofAction()
    self:setVisible(false)
    self:removeFromUIManager()
    if RoofWindow.instance == self then RoofWindow.instance = nil end
end

function Window:new(x, y, width, height, player)
    local o = ISCollapsableWindow.new(self, x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.mappingKey = mappingKey(currentMapping())
    o.templateId = nil
    o.template = nil
    o.roofCells = nil
    o.devices = {}
    o.selectionMode = nil
    o.selectedType = nil
    o.selectedItem = nil
    o.activeRoofAction = nil
    o:setResizable(false)
    o:setTitle(getText("UI_RailroaderRV_Roof_Title"))
    return o
end

function RoofWindow.show(player)
    if not player then return false end
    if RoofWindow.instance then
        local window = RoofWindow.instance
        window.player = player
        window.mappingKey = mappingKey(currentMapping())
        window:refresh()
        window:setVisible(true)
        window:bringToTop()
        Client.requestSnapshot(player)
        return true
    end
    local core = getCore()
    local screenWidth, screenHeight = core:getScreenWidth(), core:getScreenHeight()
    local width = math.min(980, screenWidth - 40)
    local height = math.min(720, screenHeight - 60)
    local window = Window:new((screenWidth - width) / 2,
        (screenHeight - height) / 2, width, height, player)
    window:initialise()
    window:addToUIManager()
    window:bringToTop()
    RoofWindow.instance = window
    window:refresh()
    Client.requestSnapshot(player)
    return true
end

function RoofWindow.onSnapshot(player, snapshot)
    local window = RoofWindow.instance
    if not window or not window:getIsVisible() or window.player ~= player then
        return false
    end
    if mappingKey(snapshot) ~= window.mappingKey then return false end
    window:refresh(snapshot)
    return true
end

function RoofWindow.onMappingChanged(player, mapping)
    local window = RoofWindow.instance
    if not window or window.player ~= player then return false end
    return window:onMappingChanged(mapping)
end

function RoofWindow.onConnectionReset()
    local window = RoofWindow.instance
    RoofWindow.instance = nil
    if window then
        window:clearSelection()
        window:cancelRoofAction()
        window:setVisible(false)
        window:removeFromUIManager()
    end
end

return RoofWindow
