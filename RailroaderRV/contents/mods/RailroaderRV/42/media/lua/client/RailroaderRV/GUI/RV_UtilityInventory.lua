local Inventory = {}

function Inventory.collectionItems(collection)
    local items = {}
    if type(collection) == "table" then
        for _, item in pairs(collection) do items[#items + 1] = item end
        return items
    end
    for index = 0, collection:size() - 1 do
        items[#items + 1] = collection:get(index)
    end
    return items
end

function Inventory.appendItems(inventory, result, seen)
    if seen[inventory] then return end
    seen[inventory] = true
    for _, item in ipairs(Inventory.collectionItems(inventory:getItems())) do
        result[#result + 1] = item
        if type(item.getInventory) == "function" then
            local nested = item:getInventory()
            if nested then Inventory.appendItems(nested, result, seen) end
        end
    end
end

function Inventory.addItemOptions(menu, inventory, target, matches, choose,
        emptyText, labelFor)
    local items = {}
    Inventory.appendItems(inventory, items, {})
    local found = 0
    for _, item in ipairs(items) do
        if matches(item) then
            found = found + 1
            local selectedItem = item
            menu:addOption(labelFor(item), target, function(currentTarget)
                choose(currentTarget, selectedItem)
            end)
        end
    end
    if found == 0 then
        local option = menu:addOption(emptyText)
        option.notAvailable = true
    end
    menu:addToUIManager()
end

function Inventory.waterKind(item)
    if not item then return nil end
    local fluidContainer = item:getFluidContainer()
    if not fluidContainer or fluidContainer:getAmount() <= 0 then return nil end

    local sample = fluidContainer:createFluidSample()
    local size = sample:size()
    local sawWater, sawTainted = false, false
    for index = 0, size - 1 do
        local fluid = sample:getFluid(index)
        if fluid == Fluid.Water then
            sawWater = true
        elseif fluid == Fluid.TaintedWater then
            sawTainted = true
        else
            sample:release()
            return nil
        end
    end
    sample:release()
    if sawTainted then return "tainted" end
    if sawWater then return "clean" end
    return nil
end

function Inventory.canAddWater(item, snapshot)
    local kind = Inventory.waterKind(item)
    if not kind then return false end
    local water = snapshot.water
    if water.tankCount <= 0 or not water.supplyPumpInstalled
        or not water.supplyPumpPowered
        or water.centralL >= water.capacityL then
        return false
    end
    if kind == "tainted" and water.filterRemainingL <= 0 then return false end
    return true
end

return Inventory
