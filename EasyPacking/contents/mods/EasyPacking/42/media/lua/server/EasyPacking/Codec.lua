local Codec = {}
local Access = require 'EasyPacking/Access'

Codec.MAX_ITEMS_PER_PARCEL = 200
Codec.MAX_SERIALIZED_ITEM_BYTES = 850000

local MOD_DATA_KEY = 'EasyPackingParcel'
local ITEM_HEADER_RESERVE_BYTES = 131072
local MAX_TABLE_DEPTH = 64
local MAX_TABLE_ENTRIES = 2147483647
local FOOD_PARCEL_TYPE = 'EasyPacking.FoodParcel'
local PARCEL_TYPE = 'EasyPacking.Parcel'

local function hasClass(item, className)
    return instanceof(item, className)
end

local function isFiniteNumber(value)
    return value == value and value ~= math.huge and value ~= -math.huge
end

local function utf8ByteLength(value)
    local utf16Length = #value
    local byteLength = 0
    local index = 1
    while index <= utf16Length do
        local codeUnit = string.byte(value, index)
        if codeUnit <= 0x7F then
            byteLength = byteLength + 1
        elseif codeUnit <= 0x7FF then
            byteLength = byteLength + 2
        elseif codeUnit >= 0xD800 and codeUnit <= 0xDBFF then
            local nextCodeUnit = index < utf16Length and string.byte(value, index + 1) or nil
            if nextCodeUnit and nextCodeUnit >= 0xDC00 and nextCodeUnit <= 0xDFFF then
                byteLength = byteLength + 4
                index = index + 1
            else
                byteLength = byteLength + 1
            end
        elseif codeUnit >= 0xDC00 and codeUnit <= 0xDFFF then
            byteLength = byteLength + 1
        else
            byteLength = byteLength + 3
        end
        index = index + 1
    end
    return byteLength
end

local function copyModData(value, path, depth)
    if depth > MAX_TABLE_DEPTH then
        return nil, 'modDataTooDeep'
    end

    if type(value) ~= 'table' then
        if type(value) == 'string' then
            if utf8ByteLength(value) > 32767 then
                return nil, 'modDataStringTooLong'
            end
            return value
        end

        if type(value) == 'number' then
            if not isFiniteNumber(value) then
                return nil, 'modDataUnsupportedValue'
            end
            return value
        end

        if type(value) == 'boolean' then
            return value
        end

        return nil, 'modDataUnsupportedValue'
    end

    if path[value] then
        return nil, 'modDataCycle'
    end

    path[value] = true
    local result = {}
    local entries = 0

    for key, child in pairs(value) do
        local keyType = type(key)
        if keyType ~= 'string' and keyType ~= 'number' then
            path[value] = nil
            return nil, 'modDataUnsupportedKey'
        end
        if keyType == 'string' and utf8ByteLength(key) > 32767 then
            path[value] = nil
            return nil, 'modDataStringTooLong'
        end
        if keyType == 'number' and not isFiniteNumber(key) then
            path[value] = nil
            return nil, 'modDataUnsupportedKey'
        end

        entries = entries + 1
        if entries > MAX_TABLE_ENTRIES then
            path[value] = nil
            return nil, 'modDataTooLarge'
        end

        local copied, failure = copyModData(child, path, depth + 1)
        if failure then
            path[value] = nil
            return nil, failure
        end
        result[key] = copied
    end

    path[value] = nil
    return result
end

local function cloneSerializableTable(value)
    return copyModData(value, {}, 0)
end

local function hasUnsupportedWeaponState(item)
    return (item:getDisplayCategory() ~= 'MaterialWeapon'
            and item:getFullType() ~= 'Base.Branch_Broken'
            and item:getFullType() ~= 'Base.MetalPipe_Broken')
        or item:isRanged()
        or item:getMaxAmmo() > 0
        or item:getCurrentAmmoCount() > 0
        or item:isContainsClip()
        or item:isRoundChambered()
        or item:isSpentRoundChambered()
        or item:isJammed()
        or item:getSpentRoundCount() > 0
        or item:getExplosionTimer() ~= 0
        or item:getBloodLevel() > 0
        or item:getAllWeaponParts():size() > 0
        or item:getHeadConditionMax() > 0
        or item:getHaveBeenRepaired() > 0
        or (item:hasSharpness() and item:getSharpness() ~= item:getMaxSharpness())
end

local function validateSupportedClass(item)
    local fullType = item:getFullType()
    if fullType == PARCEL_TYPE or fullType == FOOD_PARCEL_TYPE then
        return false, 'nestedParcelUnsupported'
    end

    if item:getFluidContainer() ~= nil then
        return false, 'fluidStateUnsupported'
    end

    if (hasClass(item, 'HandWeapon') and hasUnsupportedWeaponState(item))
        or hasClass(item, 'WeaponPart')
        or hasClass(item, 'Clothing')
        or hasClass(item, 'KeyRing')
        or hasClass(item, 'Key')
        or hasClass(item, 'AlarmClock')
        or hasClass(item, 'AnimalInventoryItem')
        or hasClass(item, 'MapItem')
        or hasClass(item, 'Literature')
        or hasClass(item, 'Radio')
        or hasClass(item, 'Moveable') then
        return false, 'itemStateUnsupported'
    end

    if item:IsInventoryContainer() and not hasClass(item, 'InventoryContainer') then
        return false, 'itemStateUnsupported'
    end

    return true
end

local function foodState(item)
    item:updateAge()
    return {
        age = item:getAge(),
        offAge = item:getOffAge(),
        offAgeMax = item:getOffAgeMax(),
        freezingTime = item:getFreezingTime(),
        frozen = item:isFrozen(),
        canBeFrozen = item:canBeFrozen(),
        cooked = item:isCooked(),
        isCookable = item:isIsCookable(),
        burnt = item:isBurnt(),
        rotten = item:isRotten(),
        canAge = item:canAge(),
        tainted = item:isTainted(),
        heat = item:getHeat(),
        cookingTime = item:getCookingTime(),
        lastCookMinute = item:getLastCookMinute(),
        hungChange = item:getHungChange(),
        thirstChange = item:getThirstChange(),
        baseHunger = item:getBaseHunger(),
        calories = item:getCalories(),
        carbohydrates = item:getCarbohydrates(),
        lipids = item:getLipids(),
        proteins = item:getProteins(),
        boredomChange = item:getBoredomChange(),
        unhappyChange = item:getUnhappyChange(),
    }
end

local containsAgingFood

local function captureItem(item, seen, depth)
    if depth > MAX_TABLE_DEPTH then
        return nil, 'containerTooDeep'
    end
    if seen[item] then
        return nil, 'containerCycle'
    end

    local supported, failure = validateSupportedClass(item)
    if not supported then
        return nil, failure
    end

    if item:IsInventoryContainer() and Access.isMarked(item) then
        return nil, 'protectedContainer'
    end

    seen[item] = true
    local modData, modDataFailure = cloneSerializableTable(item:getModData())
    if modDataFailure then
        seen[item] = nil
        return nil, modDataFailure
    end

    local record = {
        fullType = item:getFullType(),
        actualWeight = item:getActualWeight(),
        baseWeight = item:getWeight(),
        customWeight = item:isCustomWeight(),
        condition = item:getCondition(),
        conditionMax = item:getConditionMax(),
        uses = item:getCurrentUsesFloat(),
        cooked = item:isCooked(),
        burnt = item:isBurnt(),
        favorite = item:isFavorite(),
        activated = item:isActivated(),
        modData = modData,
    }
    local displayName = item:getDisplayName()
    if displayName ~= item:getScriptItem():getDisplayName() then
        record.customName = displayName
    end

    if hasClass(item, 'Food') then
        record.food = foodState(item)
    end

    if hasClass(item, 'DrainableComboItem') then
        record.drainable = {
            uses = item:getCurrentUsesFloat(),
            delta = item:getUseDelta(),
        }
    end

    if item:IsInventoryContainer() then
        if item:getInventory() == nil then
            seen[item] = nil
            return nil, 'containerStateUnsupported'
        end

        record.contents = {}
        local contents = item:getInventory():getItems()
        for index = 0, contents:size() - 1 do
            local childRecord, childFailure = captureItem(contents:get(index), seen, depth + 1)
            if childFailure then
                seen[item] = nil
                return nil, childFailure
            end
            record.contents[#record.contents + 1] = childRecord
        end
        if containsAgingFood(record.contents) then
            seen[item] = nil
            return nil, 'perishableContentsUnsupported'
        end
    end

    seen[item] = nil
    return record
end

containsAgingFood = function(records)
    for _, record in ipairs(records) do
        if record.food and record.food.canAge then
            return true
        end
        if record.contents and containsAgingFood(record.contents) then
            return true
        end
    end
    return false
end

function Codec.capture(item)
    if not item then
        return nil, 'itemUnavailable'
    end
    return captureItem(item, {}, 0)
end

function Codec.applyFoodState(item, state)
    item:setAge(state.age)
    item:setLastAged(getGameTime():getWorldAgeHours())
    item:setFreezingTime(state.freezingTime)
    item:setFrozen(state.frozen)
    item:setOffAge(state.freshLimit)
    item:setOffAgeMax(state.rottenLimit)
end

local function addFoodState(item, state)
    item:setAge(state.age)
    item:setLastAged(getGameTime():getWorldAgeHours())
    item:setOffAge(state.offAge)
    item:setOffAgeMax(state.offAgeMax)
    item:setFreezingTime(state.freezingTime)
    item:setFrozen(state.frozen)
    item:setCanBeFrozen(state.canBeFrozen)
    item:setCooked(state.cooked)
    item:setIsCookable(state.isCookable)
    item:setBurnt(state.burnt)
    item:setRotten(state.rotten)
    item:setTainted(state.tainted)
    item:setHeat(state.heat)
    item:setCookingTime(state.cookingTime)
    item:setLastCookMinute(state.lastCookMinute)
    item:setHungChange(state.hungChange)
    item:setThirstChange(state.thirstChange)
    item:setBaseHunger(state.baseHunger)
    item:setCalories(state.calories)
    item:setCarbohydrates(state.carbohydrates)
    item:setLipids(state.lipids)
    item:setProteins(state.proteins)
    item:setBoredomChange(state.boredomChange)
    item:setUnhappyChange(state.unhappyChange)
end

local function createItem(record)
    local item = instanceItem(record.fullType)
    if item == nil then
        return nil, 'itemTypeUnavailable'
    end

    item:setWeight(record.baseWeight)
    item:setActualWeight(record.actualWeight)
    item:setCustomWeight(record.customWeight == true)
    item:setConditionMax(record.conditionMax)
    item:setConditionNoSound(record.condition)
    item:setCurrentUsesFloat(record.uses)
    item:setCooked(record.cooked)
    item:setBurnt(record.burnt)
    item:setFavorite(record.favorite)
    item:setActivated(record.activated)
    item:copyModData(record.modData)
    if record.customName ~= nil then
        item:setName(record.customName)
    end

    if record.food then
        if not hasClass(item, 'Food') then
            return nil, 'itemTypeChanged'
        end
        addFoodState(item, record.food)
    end

    if record.drainable then
        if not hasClass(item, 'DrainableComboItem') then
            return nil, 'itemTypeChanged'
        end
        item:setUseDelta(record.drainable.delta)
        item:setCurrentUsesFloat(record.drainable.uses)
    end

    if record.contents then
        if not item:IsInventoryContainer() or item:getInventory() == nil then
            return nil, 'itemTypeChanged'
        end
        local inventory = item:getInventory()
        for _, childRecord in ipairs(record.contents) do
            local child, failure = createItem(childRecord)
            if failure then
                return nil, failure
            end
            inventory:AddItem(child)
        end
    end

    item:setActualWeight(record.actualWeight)
    return item
end

local function calculateFoodState(records, requestedState)
    if requestedState then
        return {
            age = requestedState.age,
            freezingTime = requestedState.freezingTime,
            frozen = requestedState.frozen,
            freshLimit = requestedState.freshLimit,
            rottenLimit = requestedState.rottenLimit,
        }
    end

    local ageTotal = 0
    local agingFoodCount = 0
    local freezingTotal = 0
    local foodCount = 0
    local freshLimit
    local rottenLimit

    for _, record in ipairs(records) do
        if record.food then
            freezingTotal = freezingTotal + record.food.freezingTime
            foodCount = foodCount + 1

            if record.food.canAge then
                ageTotal = ageTotal + record.food.age
                agingFoodCount = agingFoodCount + 1
                if freshLimit == nil then
                    freshLimit = record.food.offAge
                    rottenLimit = record.food.offAgeMax
                end
            end
        end
    end

    if agingFoodCount == 0 then
        return nil
    end

    return {
        age = ageTotal / agingFoodCount,
        freezingTime = freezingTotal / foodCount,
        frozen = freezingTotal / foodCount >= 100,
        freshLimit = freshLimit,
        rottenLimit = rottenLimit,
    }
end

local function isParcelFoodType(item)
    return hasClass(item, 'Food')
end

local function createEmptyParcel(isFood)
    local parcelType = isFood and FOOD_PARCEL_TYPE or PARCEL_TYPE
    return instanceItem(parcelType)
end

function Codec.createParcel(fullType, records, requestedFoodState)
    if type(records) ~= 'table' or #records == 0 or #records > Codec.MAX_ITEMS_PER_PARCEL then
        return nil, 'invalidParcelCount'
    end

    local foodState = calculateFoodState(records, requestedFoodState)
    local parcel = createEmptyParcel(foodState ~= nil)
    if parcel == nil then
        return nil, 'parcelTypeUnavailable'
    end

    if foodState and not isParcelFoodType(parcel) then
        return nil, 'parcelTypeChanged'
    end

    local contentWeight = 0
    for _, record in ipairs(records) do
        contentWeight = contentWeight + record.actualWeight
    end

    parcel:setWeight(contentWeight * 0.8)
    parcel:setActualWeight(contentWeight * 0.8)
    parcel:setCustomWeight(true)
    parcel:getModData()[MOD_DATA_KEY] = {
        fullType = fullType,
        records = records,
        baselineAge = foodState and foodState.age or nil,
        freshLimit = foodState and foodState.freshLimit or nil,
        rottenLimit = foodState and foodState.rottenLimit or nil,
    }

    if foodState then
        Codec.applyFoodState(parcel, foodState)
        parcel:setCanBeFrozen(true)
        parcel:setIsCookable(false)
        parcel:setHungChange(0)
        parcel:setThirstChange(0)
        parcel:setBaseHunger(0)
    end

    return parcel
end

local function serializeValueSize(value, seen, depth)
    if depth > MAX_TABLE_DEPTH then
        return nil, 'modDataTooDeep'
    end

    if type(value) == 'string' then
        if utf8ByteLength(value) > 32767 then
            return nil, 'modDataStringTooLong'
        end
        return 2 + #value
    end
    if type(value) == 'number' then
        if not isFiniteNumber(value) then
            return nil, 'modDataUnsupportedValue'
        end
        return 8
    end
    if type(value) == 'boolean' then
        return 1
    end
    if type(value) ~= 'table' then
        return nil, 'modDataUnsupportedValue'
    end
    if seen[value] then
        return nil, 'modDataCycle'
    end

    seen[value] = true
    local total = 4
    local entries = 0
    for key, child in pairs(value) do
        local keyType = type(key)
        local keySize
        if keyType == 'string' then
            if utf8ByteLength(key) > 32767 then
                seen[value] = nil
                return nil, 'modDataStringTooLong'
            end
            keySize = 2 + #key
        elseif keyType == 'number' and isFiniteNumber(key) then
            keySize = 8
        else
            seen[value] = nil
            return nil, 'modDataUnsupportedKey'
        end

        local valueSize, failure = serializeValueSize(child, seen, depth + 1)
        if failure then
            seen[value] = nil
            return nil, failure
        end
        total = total + 2 + keySize + valueSize
        entries = entries + 1
        if entries > MAX_TABLE_ENTRIES then
            seen[value] = nil
            return nil, 'modDataTooLarge'
        end
    end
    seen[value] = nil
    return total
end

function Codec.measure(item)
    if item == nil then
        return nil, 'itemUnavailable'
    end
    local modDataBytes, failure = serializeValueSize(item:getModData(), {}, 0)
    if failure then
        return nil, failure
    end

    local estimatedBytes = modDataBytes + ITEM_HEADER_RESERVE_BYTES
    if estimatedBytes > Codec.MAX_SERIALIZED_ITEM_BYTES then
        return nil, 'parcelTooLarge'
    end
    return estimatedBytes
end

local function takeRecords(records, count)
    local selected = {}
    local remaining = {}
    for index, record in ipairs(records) do
        if index <= count then
            selected[#selected + 1] = record
        else
            remaining[#remaining + 1] = record
        end
    end
    return selected, remaining
end

local function settleFoodRecords(records, ageDelta, freezingTime, frozen, useFoodClock)
    local settled = {}
    for index, record in ipairs(records) do
        local clone, failure = cloneSerializableTable(record)
        if failure then
            return nil, failure
        end
        if clone.food and useFoodClock then
            clone.food.age = clone.food.age + ageDelta
            if clone.food.canBeFrozen then
                clone.food.freezingTime = freezingTime
                clone.food.frozen = frozen
            end
        end
        settled[index] = clone
    end
    return settled
end

function Codec.openParcel(parcel, count)
    local data = parcel:getModData()[MOD_DATA_KEY]
    if not data then
        return nil, 'parcelDataUnavailable'
    end

    local records = data.records
    if type(records) ~= 'table' or #records == 0 or #records > Codec.MAX_ITEMS_PER_PARCEL then
        return nil, 'invalidParcelData'
    end
    if count == nil then
        count = #records
    end
    if count < 1 or count > #records or count % 1 ~= 0 then
        return nil, 'invalidTakeCount'
    end

    local ageDelta = 0
    local freezingTime = 0
    local frozen = false
    local useFoodClock = isParcelFoodType(parcel)
    if useFoodClock then
        parcel:updateAge()
        ageDelta = parcel:getAge() - data.baselineAge
        freezingTime = parcel:getFreezingTime()
        frozen = parcel:isFrozen()
    end

    local settledRecords, settleFailure = settleFoodRecords(records, ageDelta, freezingTime, frozen, useFoodClock)
    if settleFailure then
        return nil, settleFailure
    end

    local selected, remaining = takeRecords(settledRecords, count)
    local items = {}
    for index, record in ipairs(selected) do
        local item, failure = createItem(record)
        if failure then
            return nil, failure
        end
        items[index] = item
    end

    local nextFoodState
    if #remaining > 0 and isParcelFoodType(parcel) then
        nextFoodState = calculateFoodState(remaining)
        nextFoodState.freezingTime = freezingTime
        nextFoodState.frozen = frozen
    end

    return {
        items = items,
        remaining = remaining,
        foodState = nextFoodState,
    }
end

return Codec
