local Access = require "EasyPacking/Access"
local TimedAction = require "EasyPacking/TimedAction"
require "ISUI/ISInventoryPane"
require "ISUI/ISInventoryPage"
require "ISUI/ISInventoryItem"

local Menu = {}
local batchSizes = { 10, 20, 50, 100, 200 }

local function drawMissingParcelIcon(panel, x, y, alpha, width, height)
    local texture = getTexture("media/inventory/Question_On.png")
    if texture == nil then
        return
    end

    panel:drawTextureScaled(texture, x, y,
        width or texture:getWidthOrig(), height or texture:getHeightOrig(), alpha or 1, 1, 1, 1)
end

local parcelIconCache = {}

local function scriptItemTexture(scriptItem)
    if scriptItem == nil then
        return nil
    end

    local icons = scriptItem:getIconsForTexture()
    if icons ~= nil and not icons:isEmpty() then
        local texture = icons:get(0)
        if texture ~= nil then
            return texture
        end
    end
    return scriptItem:getNormalTexture()
end

local function parcelSourceTextures(parcelData, record)
    local food = record.food
    local modData = record.modData
    local customIcon = modData and modData.customInventoryIcon or ""
    if type(customIcon) ~= "string" then
        customIcon = ""
    end
    local key = table.concat({ parcelData.fullType, customIcon,
        food and (food.cooked and "cooked" or "raw") or "item",
        food and (food.burnt and "burnt" or "normal") or "" }, "\31")
    local cached = parcelIconCache[key]
    if cached ~= nil then
        return cached
    end

    local scriptItem = getScriptManager():FindItem(parcelData.fullType)
    local source = instanceItem(parcelData.fullType)
    if modData ~= nil then
        source:copyModData(modData)
    end

    local baseTexture = source:getTexture()
    if baseTexture == nil then
        baseTexture = scriptItemTexture(scriptItem)
    end

    cached = { base = baseTexture }
    if food ~= nil then
        cached.cooked = source:getTextureCooked() or baseTexture
        cached.burnt = source:getTextureBurnt() or baseTexture
        cached.rotten = source:getTexturerotten() or baseTexture
    end
    if food ~= nil and food.burnt then
        cached.base = cached.burnt
        cached.rotten = cached.burnt
    elseif food ~= nil and food.cooked then
        cached.base = cached.cooked
    end
    if cached.base == nil then
        cached.base = getTexture("media/inventory/Question_On.png")
    end

    parcelIconCache[key] = cached
    return cached
end

local function setParcelIcon(item, parcelData)
    local textures = parcelSourceTextures(parcelData, parcelData.records[1])
    item:setTexture(textures.base)
    if item:IsFood() then
        item:setTexturerotten(textures.rotten or textures.base)
    end
end

local originalRenderItemIcon = ISInventoryItem.renderItemIcon
ISInventoryItem.renderItemIcon = function(panel, item, x, y, alpha, width, height)
    if Access.isParcel(item) then
        local parcelData = item:getModData().EasyPackingParcel
        setParcelIcon(item, parcelData)
        if item:getTex() ~= nil then
            return originalRenderItemIcon(panel, item, x, y, alpha, width, height)
        end

        return drawMissingParcelIcon(panel, x, y, alpha, width, height)
    end

    return originalRenderItemIcon(panel, item, x, y, alpha, width, height)
end

local function selectedInventoryItem(entry)
    if type(entry) == "table" and entry.items ~= nil then
        return selectedInventoryItem(entry.items[1])
    end
    return entry
end

local function sendRequest(item, player, action, count)
    if action == "Skip" or action == "Allow" then
        sendClientCommand(player, "EasyPacking", action, {
            id = item:getID(),
        })
        return
    end

    local weight = 0
    local progressItems = {}
    if action == "Take" then
        local parcelData = item:getModData().EasyPackingParcel
        local records = parcelData and parcelData.records or nil
        if records == nil or #records == 0 or (count ~= nil and count >= #records) then
            HaloTextHelper.addBadText(player, getText("ContextMenu_EasyPacking_Result_Changed"))
            return
        end
        local selectedCount = count or #records
        for index = 1, selectedCount do
            weight = weight + records[index].actualWeight
        end
        progressItems[1] = item
    else
        local candidates = Access.collect(player, item)
        local selectedCount
        if action == "PackOne" then
            selectedCount = count or #candidates
            if selectedCount < 1 or selectedCount > #candidates or (count == nil and selectedCount > 200) then
                HaloTextHelper.addBadText(player, getText("ContextMenu_EasyPacking_Result_Changed"))
                return
            end
        else
            if count == nil or count < 1 or math.floor(#candidates / count) < 2 then
                HaloTextHelper.addBadText(player, getText("ContextMenu_EasyPacking_Result_Changed"))
                return
            end
            selectedCount = math.floor(#candidates / count) * count
        end
        for index = 1, selectedCount do
            local candidate = candidates[index]
            weight = weight + candidate:getActualWeight()
            progressItems[index] = candidate
        end
    end

    ISTimedActionQueue.add(TimedAction:new(player, item, action, count, weight, progressItems))
end

local function sourceDisplayName(parcelData, records)
    local customName = records[1].customName
    if customName ~= nil then
        for index = 2, #records do
            if records[index].customName ~= customName then
                customName = nil
                break
            end
        end
    end

    if customName ~= nil then
        return customName
    end

    return getScriptManager():FindItem(parcelData.fullType):getDisplayName()
end

local function updateParcelPresentation(item)
    if not Access.isParcel(item) then
        return
    end

    local parcelData = item:getModData().EasyPackingParcel
    local records = parcelData.records
    setParcelIcon(item, parcelData)
    local displayName = sourceDisplayName(parcelData, records)

    if records[1].food then
        local food = records[1].food
        if food.canAge then
            item:updateAge()
            local age = item:getAge()
            local freshnessKey
            if age < parcelData.freshLimit then
                freshnessKey = "ContextMenu_EasyPacking_Fresh"
            elseif age < parcelData.rottenLimit then
                freshnessKey = "ContextMenu_EasyPacking_Stale"
            else
                freshnessKey = "ContextMenu_EasyPacking_Rotten"
            end

            local nativePrefixAvailable = (freshnessKey == "ContextMenu_EasyPacking_Fresh"
                and item:getOffAge() < 1000000000)
                or (freshnessKey ~= "ContextMenu_EasyPacking_Fresh"
                    and item:getOffAgeMax() < 1000000000)
            local cooking = getText(food.cooked
                and "ContextMenu_EasyPacking_Cooked"
                or "ContextMenu_EasyPacking_Uncooked")
            if nativePrefixAvailable then
                displayName = getText("ContextMenu_EasyPacking_FoodParcelNativeName", displayName, cooking)
            else
                displayName = getText("ContextMenu_EasyPacking_FoodParcelName",
                    displayName, getText(freshnessKey), cooking)
            end
        else
            local cooking = getText(food.cooked
                and "ContextMenu_EasyPacking_Cooked"
                or "ContextMenu_EasyPacking_Uncooked")
            displayName = getText("ContextMenu_EasyPacking_FoodParcelNonPerishableName",
                displayName, getText("ContextMenu_EasyPacking_NonPerishable"), cooking)
        end
    else
        displayName = getText("ContextMenu_EasyPacking_ItemParcelName", displayName)
    end

    item:setName(displayName)
    item:setTooltip(getText("ContextMenu_EasyPacking_ParcelQuantity", #records))
end

local originalRefreshContainer = ISInventoryPane.refreshContainer
function ISInventoryPane:refreshContainer(...)
    if self.inventory ~= nil then
        local items = self.inventory:getItems()
        for index = 0, items:size() - 1 do
            updateParcelPresentation(items:get(index))
        end
    end
    return originalRefreshContainer(self, ...)
end

local originalRenderDetails = ISInventoryPane.renderdetails
function ISInventoryPane:renderdetails(doDragged)
    local result = originalRenderDetails(self, doDragged)
    if doDragged ~= true or self.itemslist == nil or not TimedAction.hasActiveProgress() then
        return result
    end

    local row = 0
    local height = self.itemHgt
    for _, stack in ipairs(self.itemslist) do
        local isCollapsed = self.collapsed[stack.name]
        for index, item in ipairs(stack.items) do
            if index == 1 and not isCollapsed
                and TimedAction.isProgressItem(item)
                and item:getJobDelta() > 0 then
                local top = row * height + self.headerHgt
                local visibleTop = row * height + self:getYScroll()
                if visibleTop + height >= 0 and visibleTop <= self.height then
                    local width = self.column4 - (self:isVScrollBarVisible() and 13 or 0)
                    self:drawRect(1, top, width * item:getJobDelta(), height, 0.2, 0.4, 1.0, 0.3)
                    self:drawText(item:getJobType(), self.column3 + 8, top + (height - self.fontHgt) / 2,
                        0.7, 0.7, 0.7, 1.0, self.font)
                end
            end

            row = row + 1
            if isCollapsed or index == ISInventoryPane.MAX_ITEMS_IN_STACK_TO_RENDER + 1 then
                break
            end
        end
    end

    return result
end

local function refreshVisibleInventories()
    for playerNum = 0, getNumActivePlayers() - 1 do
        local playerData = getPlayerData(playerNum)
        if playerData then
            local windows = {
                playerData.playerInventory,
                playerData.lootInventory,
            }
            for _, window in ipairs(windows) do
                if window and window.inventoryPane and window.inventoryPane.inventory then
                    window.inventoryPane.inventory:setDrawDirty(true)
                end
            end
        end
    end
end

Events.EveryHours.Add(refreshVisibleInventories)

local function addPackingOptions(context, item, player)
    local candidates = Access.collect(player, item)
    local count = #candidates
    if count == 0 then
        return
    end

    local oneOption = context:addOption(getText("ContextMenu_EasyPacking_OneParcel"), item, function() end)
    local oneMenu = ISContextMenu:getNew(context)
    context:addSubMenu(oneOption, oneMenu)

    for _, amount in ipairs(batchSizes) do
        if amount <= count then
            oneMenu:addOption(getText("ContextMenu_EasyPacking_Count", amount), item, sendRequest, player, "PackOne", amount)
        end
    end
    if count <= 200 then
        oneMenu:addOption(getText("ContextMenu_EasyPacking_PackAll", count), item, sendRequest, player, "PackOne", nil)
    end
    if #oneMenu.options == 0 then
        context:removeOptionByName(getText("ContextMenu_EasyPacking_OneParcel"))
    end

    local manyOption = context:addOption(getText("ContextMenu_EasyPacking_MultipleParcels"), item, function() end)
    local manyMenu = ISContextMenu:getNew(context)
    context:addSubMenu(manyOption, manyMenu)
    for _, amount in ipairs(batchSizes) do
        if math.floor(count / amount) >= 2 then
            manyMenu:addOption(getText("ContextMenu_EasyPacking_PerParcel", amount), item, sendRequest, player, "PackMany", amount)
        end
    end
    if #manyMenu.options == 0 then
        context:removeOptionByName(getText("ContextMenu_EasyPacking_MultipleParcels"))
    end
end

local function addParcelOptions(context, item, player)
    local parcelData = item:getModData().EasyPackingParcel
    local contents = parcelData and parcelData.records or nil
    if contents == nil or #contents == 0 then
        return
    end

    local rootOption = context:addOption(getText("ContextMenu_EasyPacking_Take"), item, function() end)
    local submenu = ISContextMenu:getNew(context)
    context:addSubMenu(rootOption, submenu)
    if item:getFullType() == "EasyPacking.FoodParcel" and parcelData.freshLimit ~= nil and parcelData.rottenLimit ~= nil then
        item:updateAge()
        local age = item:getAge()
        local freshnessKey
        if age < parcelData.freshLimit then
            freshnessKey = "ContextMenu_EasyPacking_Fresh"
        elseif age < parcelData.rottenLimit then
            freshnessKey = "ContextMenu_EasyPacking_Stale"
        else
            freshnessKey = "ContextMenu_EasyPacking_Rotten"
        end
        local freshnessOption = submenu:addOption(getText("ContextMenu_EasyPacking_Freshness", getText(freshnessKey)), item, function() end)
        freshnessOption.notAvailable = true
    end
    for _, count in ipairs(batchSizes) do
        if count < #contents then
            submenu:addOption(getText("ContextMenu_EasyPacking_TakeCount", count), item, sendRequest, player, "Take", count)
        end
    end
    submenu:addOption(getText("ContextMenu_EasyPacking_TakeAll", #contents), item, sendRequest, player, "Take", nil)
end

local function addContainerMarkOption(context, item, player)
    if not item:IsInventoryContainer() then
        return
    end

    if Access.isMarked(item) then
        context:addOption(getText("ContextMenu_EasyPacking_Allow"), item, sendRequest, player, "Allow")
    else
        context:addOption(getText("ContextMenu_EasyPacking_Skip"), item, sendRequest, player, "Skip")
    end
end

local function sendContainerProtection(container, player)
    local target = Access.getContainerProtectionTarget(player, container)
    if target == nil then
        return
    end

    local command = Access.isContainerMarked(player, container) and "Allow" or "Skip"
    sendClientCommand(player, "EasyPacking", command, target)
end

local originalBackpackRightMouseDown = ISInventoryPage.onBackpackRightMouseDown
function ISInventoryPage:onBackpackRightMouseDown(x, y)
    local result = originalBackpackRightMouseDown(self, x, y)
    local page = self.parent.parent
    local container = self.inventory
    local player = getSpecificPlayer(page.player)
    if player == nil or container:getContainingItem() ~= nil then
        return result
    end

    local target = Access.getContainerProtectionTarget(player, container)
    if target == nil then
        return result
    end

    local context = getPlayerContextMenu(page.player)
    if context ~= nil then
        local command = Access.isContainerMarked(player, container) and "Allow" or "Skip"
        local textKey = command == "Allow"
            and "ContextMenu_EasyPacking_Allow"
            or "ContextMenu_EasyPacking_Skip"
        context:addOption(getText(textKey), container, sendContainerProtection, player)
    end

    return result
end

local function removeFoodParcelActions(context)
    local names = {
        getText("ContextMenu_Eat"),
        getText("ContextMenu_Cook"),
        getText("ContextMenu_Microwave"),
    }

    local function removeFrom(menu)
        for _, name in ipairs(names) do
            menu:removeOptionByName(name)
        end
        for _, option in ipairs(menu.options) do
            if option.subOption ~= nil then
                local submenu = menu:getSubMenu(option.subOption)
                if submenu ~= nil then
                    removeFrom(submenu)
                end
            end
        end
    end

    removeFrom(context)
end

function Menu.onFillInventoryObjectContextMenu(playerNum, context, selectedItems)
    local player = getSpecificPlayer(playerNum)
    if player == nil or selectedItems == nil then
        return
    end

    for _, entry in ipairs(selectedItems) do
        local selectedItem = selectedInventoryItem(entry)
        if selectedItem ~= nil and selectedItem:getFullType() == "EasyPacking.FoodParcel" then
            removeFoodParcelActions(context)
        end
    end

    if #selectedItems ~= 1 then
        return
    end

    local item = selectedInventoryItem(selectedItems[1])
    if item == nil or Access.findItem(player, item:getID()) == nil then
        return
    end

    if Access.isParcel(item) then
        addParcelOptions(context, item, player)
        return
    end

    addContainerMarkOption(context, item, player)
    addPackingOptions(context, item, player)
end

local function onServerCommand(module, command, args)
    if module ~= "EasyPacking" or command ~= "Result" or args == nil or args.message == nil then
        return
    end

    local player = getSpecificPlayer(args.playerNum or 0)
    if player == nil then
        return
    end

    if args.playerInventoryMarked ~= nil then
        local modData = player:getModData()
        modData.EasyPackingSkipInventory = args.playerInventoryMarked and true or nil
    end

    local message = getText(args.message)
    if args.success then
        HaloTextHelper.addGoodText(player, message)
    else
        HaloTextHelper.addBadText(player, message)
    end
end

Events.OnFillInventoryObjectContextMenu.Add(Menu.onFillInventoryObjectContextMenu)
Events.OnServerCommand.Add(onServerCommand)

return Menu
