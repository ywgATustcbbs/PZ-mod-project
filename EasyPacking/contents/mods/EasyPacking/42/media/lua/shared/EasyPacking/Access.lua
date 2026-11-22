local Access = {}

local parcelTypes = {
    ["EasyPacking.Parcel"] = true,
    ["EasyPacking.FoodParcel"] = true,
}

local function isInventoryContainer(item)
    return item ~= nil and item:IsInventoryContainer()
end

function Access.isParcel(item)
    return item ~= nil and parcelTypes[item:getFullType()] == true
end

function Access.isMarked(item)
    return item ~= nil and item:getModData().EasyPackingSkip == true
end

function Access.isPlayerInventoryMarked(player)
    return player:getModData().EasyPackingSkipInventory == true
end

local function worldContainerIndex(container)
    local parent = container:getParent()
    if parent == nil then
        return nil, nil
    end
    local index = parent:getContainerIndex(container)
    if index < 0 then
        return nil, nil
    end
    return parent, index
end

local function markedWorldContainer(container)
    local parent, index = worldContainerIndex(container)
    if parent == nil then
        return false
    end
    local markedContainers = parent:getModData().EasyPackingSkipContainers
    return markedContainers ~= nil and markedContainers[index] == true
end

function Access.isContainerMarked(player, container)
    if container == nil then
        return false
    end
    if player ~= nil and container == player:getInventory() then
        return Access.isPlayerInventoryMarked(player)
    end

    local containingItem = container:getContainingItem()
    if containingItem ~= nil then
        return Access.isMarked(containingItem)
    end

    return markedWorldContainer(container)
end

local function isAccessibleWorldContainer(player, container)
    local parent = container:getParent()
    if parent == nil or parent:getContainerIndex(container) < 0 or parent:getObjectIndex() < 0 then
        return false
    end

    local square = parent:getSquare()
    local currentSquare = player:getCurrentSquare()
    if square == nil or currentSquare == nil
        or currentSquare:DistToProper(square) > 1.5
        or not currentSquare:canReachTo(square) then
        return false
    end

    return not (instanceof(parent, "IsoThumpable") and parent:isLockedToCharacter(player))
end

function Access.isAccessibleContainer(player, container)
    if container == nil then
        return false
    end
    if container == player:getInventory() or container:isInCharacterInventory(player) then
        return true
    end

    local rootContainer = container
    while rootContainer:getContainingItem() ~= nil do
        rootContainer = rootContainer:getContainingItem():getContainer()
        if rootContainer == nil then
            return false
        end
        if rootContainer:isInCharacterInventory(player) then
            return true
        end
    end

    local worldItem = rootContainer:getWorldItem()
    if worldItem ~= nil then
        local square = worldItem:getSquare()
        local currentSquare = player:getCurrentSquare()
        return square ~= nil and currentSquare ~= nil
            and currentSquare:DistToProper(square) <= 1.5
            and currentSquare:canReachTo(square)
    end

    return isAccessibleWorldContainer(player, rootContainer)
end

function Access.getContainerProtectionTarget(player, container)
    if container == nil then
        return nil
    end
    if container == player:getInventory() then
        return { scope = "playerInventory" }
    end

    local containingItem = container:getContainingItem()
    if containingItem ~= nil then
        if not isInventoryContainer(containingItem)
            or not Access.isAccessibleContainer(player, container)
            or Access.findItem(player, containingItem:getID()) == nil then
            return nil
        end
        return { scope = "item", id = containingItem:getID() }
    end

    if not isAccessibleWorldContainer(player, container) then
        return nil
    end

    local parent, containerIndex = worldContainerIndex(container)
    local square = parent:getSquare()
    local objectIndex = parent:getObjectIndex()
    if objectIndex < 0 then
        return nil
    end

    return {
        scope = "worldObject",
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
        index = objectIndex,
        containerIndex = containerIndex,
    }
end

local function hasMarkedDescendant(item, visited)
    if not isInventoryContainer(item) then
        return false
    end

    local itemId = item:getID()
    if visited[itemId] then
        return false
    end
    visited[itemId] = true

    local contents = item:getInventory():getItems()
    for index = 0, contents:size() - 1 do
        local child = contents:get(index)
        if Access.isMarked(child) or hasMarkedDescendant(child, visited) then
            return true
        end
    end

    return false
end

local function hasParcelDescendant(item, visited)
    if not isInventoryContainer(item) then
        return false
    end

    local itemId = item:getID()
    if visited[itemId] then
        return false
    end
    visited[itemId] = true

    local contents = item:getInventory():getItems()
    for index = 0, contents:size() - 1 do
        local child = contents:get(index)
        if Access.isParcel(child) or hasParcelDescendant(child, visited) then
            return true
        end
    end

    return false
end

local function hasMarkedAncestor(item)
    local container = item:getContainer()
    local insideItemContainer = false
    while container ~= nil do
        local containingItem = container:getContainingItem()
        if containingItem == nil then
            if Access.isContainerMarked(nil, container) then
                return true
            end
            local parent = container:getParent()
            return not insideItemContainer
                and parent ~= nil
                and instanceof(parent, "IsoPlayer")
                and Access.isPlayerInventoryMarked(parent)
        end
        if Access.isMarked(containingItem) then
            return true
        end
        insideItemContainer = true
        container = containingItem:getContainer()
    end
    return false
end

function Access.canPack(item)
    if item == nil or Access.isParcel(item) or Access.isMarked(item) or hasMarkedAncestor(item) then
        return false
    end
    return not hasMarkedDescendant(item, {}) and not hasParcelDescendant(item, {})
end

local function isAncestorOf(ancestor, item)
    local container = item:getContainer()
    while container ~= nil do
        local containingItem = container:getContainingItem()
        if containingItem == nil then
            return false
        end
        if containingItem:getID() == ancestor:getID() then
            return true
        end
        container = containingItem:getContainer()
    end
    return false
end

function Access.matches(anchor, item)
    if anchor == nil or item == nil or not Access.canPack(anchor) or not Access.canPack(item) then
        return false
    end
    if anchor:getFullType() ~= item:getFullType() then
        return false
    end

    if anchor:IsFood() then
        return item:IsFood() and anchor:isCooked() == item:isCooked()
    end

    return not item:IsFood()
end

local function addRoot(roots, seenContainers, seenWorldItems, root)
    if root.container ~= nil then
        if seenContainers[root.container] then
            return
        end
        seenContainers[root.container] = true
    elseif root.worldItem ~= nil then
        if seenWorldItems[root.worldItem] then
            return
        end
        seenWorldItems[root.worldItem] = true
    else
        return
    end
    roots[#roots + 1] = root
end

local function addNearbyRoots(player, roots, seenContainers, seenWorldItems)
    local center = player:getCurrentSquare()
    if center == nil then
        return
    end

    local cell = getCell()
    for yOffset = -1, 1 do
        for xOffset = -1, 1 do
            local square = cell:getGridSquare(center:getX() + xOffset, center:getY() + yOffset, center:getZ())
            if square ~= nil and center:DistToProper(square) <= 1.5 and center:canReachTo(square) then
                local worldItems = square:getWorldObjects()
                for index = 0, worldItems:size() - 1 do
                    local worldItem = worldItems:get(index)
                    local item = worldItem:getItem()
                    if item ~= nil then
                        addRoot(roots, seenContainers, seenWorldItems, { worldItem = worldItem })
                    end
                end

                local objects = square:getObjects()
                for index = 0, objects:size() - 1 do
                    local object = objects:get(index)
                    if not (instanceof(object, "IsoThumpable") and object:isLockedToCharacter(player)) then
                        for containerIndex = 0, object:getContainerCount() - 1 do
                            local container = object:getContainerByIndex(containerIndex)
                            if container ~= nil then
                                addRoot(roots, seenContainers, seenWorldItems, {
                                    container = container,
                                    worldObject = object,
                                    containerIndex = containerIndex,
                                })
                            end
                        end
                    end
                end
            end
        end
    end
end

local function accessibleRoots(player)
    local roots = {}
    local seenContainers = {}
    local seenWorldItems = {}
    addRoot(roots, seenContainers, seenWorldItems, { container = player:getInventory() })
    addNearbyRoots(player, roots, seenContainers, seenWorldItems)
    return roots
end

local function visitItem(item, visitor, visitedItems)
    if item == nil then
        return
    end

    local itemId = item:getID()
    if visitedItems[itemId] then
        return
    end
    visitedItems[itemId] = true
    visitor(item)

    if not isInventoryContainer(item) then
        return
    end

    local contents = item:getInventory():getItems()
    for index = 0, contents:size() - 1 do
        visitItem(contents:get(index), visitor, visitedItems)
    end
end

local function visitAccessibleItems(player, visitor)
    local visitedItems = {}
    for _, root in ipairs(accessibleRoots(player)) do
        if root.container ~= nil then
            local items = root.container:getItems()
            for index = 0, items:size() - 1 do
                visitItem(items:get(index), visitor, visitedItems)
            end
        else
            visitItem(root.worldItem:getItem(), visitor, visitedItems)
        end
    end
end

function Access.findItem(player, itemId)
    local foundItem
    visitAccessibleItems(player, function(item)
        if foundItem == nil and item:getID() == itemId then
            foundItem = item
        end
    end)
    return foundItem
end

function Access.collect(player, anchor)
    local candidates = {}
    if not Access.canPack(anchor) then
        return candidates
    end

    local visitedItems = {}
    local candidateIds = {}
    candidateIds[anchor:getID()] = true
    candidates[#candidates + 1] = anchor
    local function visit(item)
        if item == nil then
            return
        end
        local itemId = item:getID()
        if visitedItems[itemId] then
            return
        end
        visitedItems[itemId] = true

        if Access.isMarked(item) then
            return
        end
        if itemId == anchor:getID() then
            return
        end
        if Access.matches(anchor, item) and not isAncestorOf(item, anchor) then
            if not candidateIds[itemId] then
                candidateIds[itemId] = true
                candidates[#candidates + 1] = item
            end
            return
        end
        if not isInventoryContainer(item) then
            return
        end

        local contents = item:getInventory():getItems()
        for index = 0, contents:size() - 1 do
            visit(contents:get(index))
        end
    end

    for _, root in ipairs(accessibleRoots(player)) do
        if root.container ~= nil then
            local isMarkedMainInventory = root.container == player:getInventory()
                and Access.isPlayerInventoryMarked(player)
            if not Access.isContainerMarked(player, root.container) or isMarkedMainInventory then
                local items = root.container:getItems()
                if root.container == player:getInventory() and Access.isPlayerInventoryMarked(player) then
                    for index = 0, items:size() - 1 do
                        local item = items:get(index)
                        if isInventoryContainer(item) then
                            visit(item)
                        end
                    end
                else
                    for index = 0, items:size() - 1 do
                        visit(items:get(index))
                    end
                end
            end
        else
            visit(root.worldItem:getItem())
        end
    end

    return candidates
end

function Access.locate(player, item)
    if item == nil then
        return nil
    end

    local worldItem = item:getWorldItem()
    if worldItem ~= nil then
        local square = worldItem:getSquare()
        if square ~= nil and player:getCurrentSquare() ~= nil and player:getCurrentSquare():DistToProper(square) <= 1.5 and player:getCurrentSquare():canReachTo(square) then
            return {
                worldItem = worldItem,
                square = square,
                x = square:getX(),
                y = square:getY(),
                z = square:getZ(),
            }
        end
    end

    local container = item:getContainer()
    if container ~= nil and Access.isAccessibleContainer(player, container) then
        return { inventory = container }
    end

    return nil
end

return Access
