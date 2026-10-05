-- Recipe callbacks store one fixed efficiency on the crafted item's condition.
local P = require("RailroaderRV/Power/RV_UtilityPowerConfig")
Recipe = Recipe or {}
Recipe.OnCreate = Recipe.OnCreate or {}

local function randomOffset()
    return ZombRandFloat(P.CRAFT_EFFICIENCY_RANDOM_MIN,
        P.CRAFT_EFFICIENCY_RANDOM_MAX)
end

local function createComponent(craftRecipeData, player)
    local createdItems = craftRecipeData:getAllCreatedItems()
    local result = createdItems:get(0)
    local level = player:getPerkLevel(Perks.Electricity)
    local efficiency = P.craftEfficiency(level, randomOffset())
    local condition = math.floor(efficiency * P.COMPONENT_CONDITION_MAX + 0.5)
    result:setCondition(condition)
end

Recipe.OnCreate.RVUtilityCharger = function(craftRecipeData, player)
    createComponent(craftRecipeData, player)
end

Recipe.OnCreate.RVUtilityInverter = function(craftRecipeData, player)
    createComponent(craftRecipeData, player)
end

return Recipe.OnCreate
