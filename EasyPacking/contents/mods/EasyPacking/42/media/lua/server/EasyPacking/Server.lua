local Access = require 'EasyPacking/Access'
local Codec = require 'EasyPacking/Codec'

local COMMAND_MODULE = 'EasyPacking'
local PARCEL_LIMIT = 200
local MAX_PACKET_BYTES = Codec.MAX_SERIALIZED_ITEM_BYTES
local PACK_SIZES = { 10, 20, 50, 100, 200 }

local function result(player, code, extraArgs)
    if player then
        local success = code == 'Packed'
            or code == 'PackedMultiple'
            or code == 'Taken'
            or code == 'Marked'
            or code == 'Unmarked'
        local args = {
            message = 'ContextMenu_EasyPacking_Result_' .. code,
            playerNum = player:getPlayerNum(),
            success = success,
        }
        if extraArgs ~= nil then
            for key, value in pairs(extraArgs) do
                args[key] = value
            end
        end
        if isServer() then
            sendServerCommand(player, COMMAND_MODULE, 'Result', args)
        else
            triggerEvent('OnServerCommand', COMMAND_MODULE, 'Result', args)
        end
    end
end

local function isAllowedCount(count)
    for index = 1, #PACK_SIZES do
        if count == PACK_SIZES[index] then
            return true
        end
    end
    return false
end

local function isPositiveInteger(value)
    return type(value) == 'number'
        and value == math.floor(value)
        and value > 0
end

local function inventoryOf(player)
    return player:getInventory()
end

local function removeItem(player, item, location)
    player:removeFromHands(item)
    local wornLocation = player:getWornItems():getLocation(item)
    if wornLocation ~= nil then
        player:removeWornItem(item, false)
    end
    if player:getAttachedItems():getLocation(item) ~= nil then
        player:removeAttachedItem(item)
    end
    if location.inventory then
        location.inventory:Remove(item)
        sendRemoveItemFromContainer(location.inventory, item)
        return true
    end

    location.square:transmitRemoveItemFromSquare(location.worldItem)
    return true
end

local function addItem(inventory, item)
    local added = inventory:AddItem(item)
    if added == nil or added == false then
        return false
    end
    sendAddItemToContainer(inventory, item)
    return true
end

local function retransmitUpdatedParcel(parcel, location)
    if location.inventory then
        location.inventory:Remove(parcel)
        sendRemoveItemFromContainer(location.inventory, parcel)
        if not addItem(location.inventory, parcel) then
            error('EasyPacking: updated parcel could not be restored to its container', 0)
        end
        return
    end

    local square = location.square
    local worldItem = location.worldItem
    local x = worldItem:getX() - square:getX()
    local y = worldItem:getY() - square:getY()
    local height = worldItem:getZ() - square:getZ()
    square:transmitRemoveItemFromSquare(worldItem)
    square:AddWorldInventoryItem(parcel, x, y, height)
end

local function locateAll(player, items)
    local locations = {}
    for index = 1, #items do
        local item = items[index]
        local location = Access.locate(player, item)
        if location == nil or not Access.canPack(item) then
            return nil
        end
        locations[index] = location
    end
    return locations
end

local function removeSources(player, items, locations)
    for index = 1, #items do
        if not removeItem(player, items[index], locations[index]) then
            error('EasyPacking: validated source item could not be removed', 0)
        end
    end
end

local function removeNewItems(inventory, items)
    for index = #items, 1, -1 do
        local item = items[index]
        inventory:Remove(item)
        sendRemoveItemFromContainer(inventory, item)
    end
end

local function makeParcels(fullType, records, perParcel)
    local parcels = {}
    for first = 1, #records, perParcel do
        local parcelRecords = {}
        local last = math.min(first + perParcel - 1, #records)
        for index = first, last do
            parcelRecords[#parcelRecords + 1] = records[index]
        end

        local parcel, message = Codec.createParcel(fullType, parcelRecords)
        if parcel == nil then
            return nil, message
        end

        local size, sizeMessage = Codec.measure(parcel)
        if size == nil or size > MAX_PACKET_BYTES then
            return nil, sizeMessage or 'parcelTooLarge'
        end
        parcels[#parcels + 1] = parcel
    end
    return parcels
end

local function prepareRecords(player, anchor, count, candidates)
    candidates = candidates or Access.collect(player, anchor)
    local wanted = count or #candidates
    if wanted < 1 or wanted > #candidates then
        return nil, 'Empty'
    end
    local selected = {}
    local records = {}
    for index = 1, wanted do
        local item = candidates[index]
        if not Access.matches(anchor, item) or not Access.canPack(item) then
            return nil, 'Changed'
        end
        local record, message = Codec.capture(item)
        if record == nil then
            return nil, message or 'UnsupportedItem'
        end
        selected[index] = item
        records[index] = record
    end
    return selected, records
end

local function pack(player, itemId, mode, count)
    local anchor = Access.findItem(player, itemId)
    if anchor == nil or not Access.canPack(anchor) then
        result(player, 'Changed')
        return
    end

    if mode == 'PackOne' then
        if count ~= nil and not isAllowedCount(count) then
            result(player, 'InvalidRequest')
            return
        end
        local candidates = Access.collect(player, anchor)
        if count == nil and #candidates > PARCEL_LIMIT then
            result(player, 'TooManyItems')
            return
        end
        local records
        candidates, records = prepareRecords(player, anchor, count, candidates)
        if candidates == nil then
            result(player, records)
            return
        end

        local parcels, message = makeParcels(anchor:getFullType(), records, PARCEL_LIMIT)
        if parcels == nil then
            result(player, message or 'TooLarge')
            return
        end

        local locations = locateAll(player, candidates)
        if locations == nil then
            result(player, 'Changed')
            return
        end

        local inventory = inventoryOf(player)
        local added = {}
        for index = 1, #parcels do
            if not addItem(inventory, parcels[index]) then
                removeNewItems(inventory, added)
                result(player, 'Failed')
                return
            end
            added[#added + 1] = parcels[index]
        end

        removeSources(player, candidates, locations)
        result(player, 'Packed')
        return
    end

    if mode ~= 'PackMany' or not isAllowedCount(count) then
        result(player, 'InvalidRequest')
        return
    end

    local candidates = Access.collect(player, anchor)
    local parcelCount = math.floor(#candidates / count)
    if parcelCount < 2 then
        result(player, 'Empty')
        return
    end

    local selectedCount = parcelCount * count
    local allCandidates, recordsOrMessage = prepareRecords(player, anchor, selectedCount, candidates)
    if allCandidates == nil then
        result(player, recordsOrMessage)
        return
    end

    local parcels, message = makeParcels(anchor:getFullType(), recordsOrMessage, count)
    if parcels == nil then
        result(player, message or 'TooLarge')
        return
    end

    local locations = locateAll(player, allCandidates)
    if locations == nil then
        result(player, 'Changed')
        return
    end

    local inventory = inventoryOf(player)
    local added = {}
    for index = 1, #parcels do
        if not addItem(inventory, parcels[index]) then
            removeNewItems(inventory, added)
            result(player, 'Failed')
            return
        end
        added[#added + 1] = parcels[index]
    end

    removeSources(player, allCandidates, locations)
    result(player, 'PackedMultiple')
end

local function take(player, itemId, count)
    local parcel = Access.findItem(player, itemId)
    if parcel == nil or not Access.isParcel(parcel) then
        result(player, 'Changed')
        return
    end

    if count ~= nil and not isAllowedCount(count) then
        result(player, 'InvalidRequest')
        return
    end

    local parcelRecords = parcel:getModData().EasyPackingParcel.records
    if count ~= nil and count >= #parcelRecords then
        result(player, 'InvalidRequest')
        return
    end

    local location = Access.locate(player, parcel)
    if location == nil then
        result(player, 'Changed')
        return
    end

    if parcel:IsFood() then
        parcel:updateAge()
    end

    local opened, message = Codec.openParcel(parcel, count or #parcelRecords)
    if opened == nil then
        result(player, message or 'Empty')
        return
    end

    for index = 1, #opened.items do
        local size, sizeMessage = Codec.measure(opened.items[index])
        if size == nil then
            result(player, sizeMessage or 'TooLarge')
            return
        end
    end

    local inventory = inventoryOf(player)
    local added = {}
    for index = 1, #opened.items do
        local item = opened.items[index]
        if not addItem(inventory, item) then
            removeNewItems(inventory, added)
            result(player, 'Failed')
            return
        end
        added[#added + 1] = item
    end

    local parcelData = parcel:getModData().EasyPackingParcel
    if #opened.remaining == 0 then
        if not removeItem(player, parcel, location) then
            removeNewItems(inventory, added)
            result(player, 'Changed')
            return
        end
    else
        parcelData.records = opened.remaining
        if opened.foodState then
            parcelData.baselineAge = opened.foodState.age
            Codec.applyFoodState(parcel, opened.foodState)
        end
        local weight = 0
        for index = 1, #opened.remaining do
            weight = weight + opened.remaining[index].actualWeight
        end
        parcel:setActualWeight(weight * 0.8)
        parcel:setWeight(weight * 0.8)
        parcel:setCustomWeight(true)
        retransmitUpdatedParcel(parcel, location)
    end
    result(player, 'Taken')
end

local function setContainerProtection(player, itemId, shouldSkip)
    local item = Access.findItem(player, itemId)
    if item == nil or not instanceof(item, 'InventoryContainer') then
        result(player, 'Changed')
        return
    end
    local data = item:getModData()
    data.EasyPackingSkip = shouldSkip and true or nil
    item:syncItemFields()
    result(player, shouldSkip and 'Marked' or 'Unmarked')
end

local function isInteger(value)
    return type(value) == 'number' and value == math.floor(value)
end

local function resolveWorldContainer(player, args)
    if not isInteger(args.x) or not isInteger(args.y) or not isInteger(args.z)
        or not isInteger(args.index) or not isInteger(args.containerIndex)
        or args.index < 0 or args.containerIndex < 0 then
        return nil
    end

    local square = getCell():getGridSquare(args.x, args.y, args.z)
    local currentSquare = player:getCurrentSquare()
    if square == nil or currentSquare == nil
        or currentSquare:DistToProper(square) > 1.5
        or not currentSquare:canReachTo(square) then
        return nil
    end

    local parent = square:getObjects():get(args.index)
    if parent == nil or parent:getObjectIndex() ~= args.index
        or (instanceof(parent, 'IsoThumpable') and parent:isLockedToCharacter(player)) then
        return nil
    end

    local container = parent:getContainerByIndex(args.containerIndex)
    if container == nil or parent:getContainerIndex(container) ~= args.containerIndex
        or not Access.isAccessibleContainer(player, container) then
        return nil
    end

    return parent
end

local function setWorldContainerProtection(player, args, shouldSkip)
    local parent = resolveWorldContainer(player, args)
    if parent == nil then
        result(player, 'Changed')
        return
    end

    local markedContainers = parent:getModData().EasyPackingSkipContainers
    if markedContainers == nil then
        markedContainers = {}
        parent:getModData().EasyPackingSkipContainers = markedContainers
    end
    if shouldSkip then
        markedContainers[args.containerIndex] = true
    else
        markedContainers[args.containerIndex] = nil
    end
    parent:transmitModData()
    result(player, shouldSkip and 'Marked' or 'Unmarked')
end

local function setPlayerInventoryProtection(player, shouldSkip)
    local playerData = player:getModData()
    playerData.EasyPackingSkipInventory = shouldSkip and true or nil
    player:transmitModData()
    result(player, shouldSkip and 'Marked' or 'Unmarked', {
        playerInventoryMarked = shouldSkip,
    })
end

local function handleContainerProtection(player, args, shouldSkip)
    if args.scope == 'playerInventory' then
        setPlayerInventoryProtection(player, shouldSkip)
    elseif args.scope == 'worldObject' then
        setWorldContainerProtection(player, args, shouldSkip)
    elseif args.scope == nil or args.scope == 'item' then
        if not isPositiveInteger(args.id) then
            result(player, 'InvalidRequest')
            return
        end
        setContainerProtection(player, args.id, shouldSkip)
    else
        result(player, 'InvalidRequest')
    end
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= COMMAND_MODULE or player == nil or args == nil then
        return
    end

    if command == 'Skip' then
        handleContainerProtection(player, args, true)
    elseif command == 'Allow' then
        handleContainerProtection(player, args, false)
    elseif command == 'PackOne' or command == 'PackMany' or command == 'Take' then
        if not isPositiveInteger(args.id) then
            result(player, 'InvalidRequest')
            return
        end
        if command == 'PackOne' or command == 'PackMany' then
            pack(player, args.id, command, args.count)
        else
            take(player, args.id, args.count)
        end
    end
end)
