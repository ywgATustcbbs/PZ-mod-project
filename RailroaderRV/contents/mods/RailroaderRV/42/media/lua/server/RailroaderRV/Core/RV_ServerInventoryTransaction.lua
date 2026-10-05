-- Shared staged inventory changes for server-owned virtual RV installations.
local Util = require("RailroaderRV/Common/RV_ServerUtil")
local M = {}

local function finite(value)
    value = Util.toNumber(value)
    return value ~= nil and value == value
        and value < math.huge and value > -math.huge
end

function M.itemType(item)
    return item:getFullType()
end

function M.itemCondition(item)
    local condition = Util.integer(item:getCondition())
    local maxCondition = Util.integer(item:getConditionMax())
    local usedDelta = Util.toNumber(item:getCurrentUsesFloat())
    if maxCondition == nil or maxCondition <= 0
        or condition == nil or condition < 0 or condition > maxCondition
        or not finite(usedDelta) then
        return nil
    end
    return condition, maxCondition, math.max(0, math.min(1, usedDelta))
end

function M.createItem(fullType, condition, usedDelta)
    local item = instanceItem(fullType)
    if condition ~= nil then item:setCondition(condition) end
    if usedDelta ~= nil then item:setCurrentUsesFloat(usedDelta) end
    return item
end

function M.syncItem(item)
    item:syncItemFields()
end

local function inventoryItems(inventory, result, seen)
    if not inventory or seen[inventory] then return end
    seen[inventory] = true
    local collection = inventory:getItems()
    local items = {}
    for index = 0, collection:size() - 1 do
        items[#items + 1] = collection:get(index)
    end
    for index = 1, #items do
        local item = items[index]
        result[#result + 1] = { item = item, inventory = inventory }
        if instanceof(item, "InventoryContainer") then
            inventoryItems(item:getInventory(), result, seen)
        end
    end
end

function M.findItem(player, itemId)
    if itemId == nil then return nil end
    local all = {}
    inventoryItems(player:getInventory(), all, {})
    for index = 1, #all do
        if tostring(all[index].item:getID()) == tostring(itemId) then
            return all[index]
        end
    end
    return nil
end

function M.new(player)
    local transaction = { player = player, undo = {}, finished = false }

    function transaction:consumeFound(found)
        self.player:removeFromHands(found.item)
        assert(found.inventory:Remove(found.item) ~= false,
            "RV source item could not be removed from its inventory")
        self.undo[#self.undo + 1] = function()
            local restored = found.inventory:AddItem(found.item)
            assert(restored ~= nil and restored ~= false,
                "RV source item could not be restored to its inventory")
            sendAddItemToContainer(found.inventory, found.item)
        end
        sendRemoveItemFromContainer(found.inventory, found.item)
        return found
    end

    function transaction:returnItem(inventory, item)
        local added = inventory:AddItem(item)
        assert(added ~= nil and added ~= false,
            "RV item could not be added to player inventory")
        self.undo[#self.undo + 1] = function()
            self.player:removeFromHands(item)
            assert(inventory:Remove(item) ~= false,
                "RV returned item could not be removed from its inventory")
            sendRemoveItemFromContainer(inventory, item)
        end
        sendAddItemToContainer(inventory, item)
        return item
    end

    function transaction:commit()
        assert(not self.finished, "RV inventory transaction already ended")
        self.finished = true
        self.undo = nil
    end

    function transaction:rollback()
        assert(not self.finished, "RV inventory transaction already ended")
        for index = #self.undo, 1, -1 do
            self.undo[index]()
        end
        self.finished = true
        self.undo = nil
    end

    return transaction
end

return M
