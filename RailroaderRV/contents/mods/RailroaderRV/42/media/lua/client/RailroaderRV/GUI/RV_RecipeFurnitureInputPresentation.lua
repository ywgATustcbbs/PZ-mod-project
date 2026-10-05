require "Entity/ISUI/CraftRecipe/ISWidgetInput"

local recipes = {
    ["Assemble RV Motor"] = {
        previewSprites = {
            "appliances_laundry_01_0",
            "appliances_laundry_01_4",
            "appliances_cooking_01_69",
        },
        staticSprites = {
            ["Base.Mov_BlueComboWasherDryer"] = "appliances_laundry_01_0",
            ["Base.Mov_ExtractorHood"] = "appliances_cooking_01_69",
        },
    },
    ["Assemble RV Water Supply Pump"] = {
        previewSprites = {
            "appliances_laundry_01_0",
            "appliances_cooking_01_73",
            "appliances_cooking_01_77",
        },
        staticSprites = {
            ["Base.Mov_BlueComboWasherDryer"] = "appliances_laundry_01_0",
            ["Base.Mov_BrownDishwasher"] = "appliances_cooking_01_73",
            ["Base.Mov_MetalDishwasher"] = "appliances_cooking_01_77",
        },
    },
    ["Assemble RV Smart Power Controller"] = {
        previewSprites = {
            "appliances_com_01_72",
        },
        staticSprites = {
            ["Base.Mov_DesktopComputer"] = "appliances_com_01_72",
        },
    },
}

local spriteItems = {}

local function spriteItem(sprite)
    local item = spriteItems[sprite]
    if not item then
        item = instanceItem("Moveables." .. sprite)
        spriteItems[sprite] = item
    end
    return item
end

local function furnitureInputInfo(widget, inputScript)
    if not widget.logic:getRecipe() then return nil end

    local recipe = recipes[widget.logic:getRecipe():getName()]
    if not recipe or inputScript:getResourceType() ~= ResourceType.Item then
        return nil
    end

    local possibleItems = inputScript:getPossibleInputItems()
    for index = 0, possibleItems:size() - 1 do
        if possibleItems:get(index):getFullName() == "Base.Moveable" then
            return recipe
        end
    end
    return nil
end

local function presentationForItem(item, recipe)
    local itemName = item:getDisplayName()
    local scriptItem = item:getScriptItem()
    local scriptFullName = scriptItem:getFullName()

    if scriptFullName == "Base.Moveable" then
        return itemName, item:getTexture()
    end

    local sprite = recipe.staticSprites[scriptFullName]
    if not sprite then
        error("RailroaderRV: unexpected static furniture recipe input "
            .. scriptFullName)
    end
    return itemName, spriteItem(sprite):getTexture()
end

local function currentFurniturePresentation(widget, inputScript, recipe)
    local satisfiedItems = widget.logic:getSatisfiedInputInventoryItems(inputScript)
    if satisfiedItems:size() > 0 then
        local index = UIManager.getSyncedIconIndex(
            widget.player:getPlayerNum(), satisfiedItems:size())
        return presentationForItem(satisfiedItems:get(index), recipe)
    end

    local index = UIManager.getSyncedIconIndex(
        widget.player:getPlayerNum(), #recipe.previewSprites)
    local item = spriteItem(recipe.previewSprites[index + 1])
    return item:getDisplayName(), item:getTexture()
end

local originalUpdateScriptValues = ISWidgetInput.updateScriptValues
function ISWidgetInput:updateScriptValues(values)
    local oldName = values.iconText
    local editedBefore = self.editedLabels
    originalUpdateScriptValues(self, values)

    local recipe = furnitureInputInfo(self, values.script)
    if not recipe then return end

    local itemName, texture = currentFurniturePresentation(self, values.script, recipe)
    values.iconText = itemName
    values.iconTexture = texture
    if values.icon then
        values.icon.texture = texture
        values.icon:setMouseOverText(values.tooltipText or itemName)
    end

    if oldName == itemName then
        self.editedLabels = editedBefore
    else
        self.editedLabels = true
    end
end

local originalUpdateValues = ISWidgetInput.updateValues
function ISWidgetInput:updateValues()
    originalUpdateValues(self)

    local recipe = furnitureInputInfo(self, self.inputScript)
    if not recipe then return end
    if not self.interactiveMode or not self.logic:isManualSelectInputs() then return end

    local selectedItem = self.logic:getRecipeData():getFirstManualInputFor(self.inputScript)
    if not selectedItem then return end

    local itemName, texture = presentationForItem(selectedItem, recipe)
    if self.primary.iconText ~= itemName then
        self.primary.iconText = itemName
        self.editedLabels = true
    end
    self.primary.icon.texture = texture
    self.primary.icon:setMouseOverText(self.primary.tooltipText or itemName)

    if self.editedLabels then
        self.editedLabels = false
        self:calculateLayout(self.width, self.height)
    end
end
