-- Recipe callbacks store one fixed efficiency on the crafted item's condition.
local P = require("RailroaderRV/RV_UtilityPowerConfig")
Recipe = Recipe or {}
Recipe.OnCreate = Recipe.OnCreate or {}

local function randomOffset()
    if type(ZombRandFloat) == "function" then
        local ok, value = pcall(ZombRandFloat, P.CRAFT_EFFICIENCY_RANDOM_MIN,
            P.CRAFT_EFFICIENCY_RANDOM_MAX)
        if ok and type(value) == "number" then return value end
    end
    return 0
end

local function createComponent(craftRecipeData, player)
    if not craftRecipeData or type(craftRecipeData.getAllCreatedItems) ~= "function" then
        return
    end
    local outputOk, createdItems = pcall(function()
        return craftRecipeData:getAllCreatedItems()
    end)
    if not outputOk or not createdItems or type(createdItems.get) ~= "function" then
        return
    end
    local itemOk, result = pcall(function() return createdItems:get(0) end)
    if not itemOk or not result then return end
    local level = 0
    local perk = rawget(_G, "Perks")
    if player and perk and perk.Electricity ~= nil
        and type(player.getPerkLevel) == "function" then
        local ok, value = pcall(player.getPerkLevel, player, perk.Electricity)
        if ok then level = tonumber(value) or 0 end
    end
    local efficiency = P.craftEfficiency(level, randomOffset())
    local condition = math.floor(efficiency * P.COMPONENT_CONDITION_MAX + 0.5)
    if type(result.setCondition) == "function" then
        pcall(result.setCondition, result, condition)
    end
end

Recipe.OnCreate.RVUtilityCharger = function(craftRecipeData, player)
    createComponent(craftRecipeData, player)
end

Recipe.OnCreate.RVUtilityInverter = function(craftRecipeData, player)
    createComponent(craftRecipeData, player)
end

return Recipe.OnCreate
