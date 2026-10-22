-- Lua-readable state snapshot for real vehicle transport.
--
-- This module stores only plain Lua data. It intentionally does not use
-- BaseVehicle/VehiclePart private save data or retain Java objects.
local State = {}

local VEHICLE_FIELDS = {
    { key = "skinIndex", getter = "getSkinIndex", setter = "setSkinIndex" },
    { key = "rust", getter = "getRust", setter = "setRust" },
    { key = "keyId", getter = "getKeyId", setter = "setKeyId" },
    { key = "hotwired", getter = "isHotwired", setter = "setHotwired" },
    { key = "hotwiredBroken", getter = "isHotwiredBroken", setter = "setHotwiredBroken" },
    { key = "alarmed", getter = "isAlarmed", setter = "setAlarmed" },
    { key = "headlightsOn", getter = "getHeadlightsOn", setter = "setHeadlightsOn" },
    { key = "windowLightsOn", getter = "getWindowLightsOn", setter = "setWindowLightsOn" },
    { key = "stoplightsOn", getter = "getStoplightsOn", setter = "setStoplightsOn" },
    { key = "lightbarLightsMode", getter = "getLightbarLightsMode", setter = "setLightbarLightsMode" },
    { key = "sirenStartTime", getter = "getSirenStartTime", setter = "setSirenStartTime" },
}

local PART_FIELDS = {
    { key = "condition", getter = "getCondition", setter = "setCondition" },
    { key = "lastUpdated", getter = "getLastUpdated", setter = "setLastUpdated" },
    { key = "category", getter = "getCategory", setter = "setCategory" },
    { key = "specificItem", getter = "isSpecificItem", setter = "setSpecificItem" },
    { key = "wheelFriction", getter = "getWheelFriction", setter = "setWheelFriction" },
    { key = "mechanicSkillInstaller", getter = "getMechanicSkillInstaller", setter = "setMechanicSkillInstaller" },
    { key = "suspensionDamping", getter = "getSuspensionDamping", setter = "setSuspensionDamping" },
    { key = "suspensionCompression", getter = "getSuspensionCompression", setter = "setSuspensionCompression" },
    { key = "engineLoudness", getter = "getEngineLoudness", setter = "setEngineLoudness" },
    { key = "durability", getter = "getDurability", setter = "setDurability" },
}

local DEVICE_FIELDS = {
    { key = "minChannelRange", getter = "getMinChannelRange", setter = "setMinChannelRange" },
    { key = "maxChannelRange", getter = "getMaxChannelRange", setter = "setMaxChannelRange" },
    { key = "highTier", getter = "getIsHighTier", setter = "setIsHighTier" },
    { key = "batteryPowered", getter = "getIsBatteryPowered", setter = "setIsBatteryPowered" },
    { key = "hasBattery", getter = "getHasBattery", setter = "setHasBattery" },
    { key = "micRange", getter = "getMicRange", setter = "setMicRange" },
    { key = "micMuted", getter = "getMicIsMuted", setter = "setMicIsMuted" },
    { key = "headphoneType", getter = "getHeadphoneType", setter = "setHeadphoneType" },
    { key = "baseVolumeRange", getter = "getBaseVolumeRange", setter = "setBaseVolumeRange" },
    { key = "deviceVolume", getter = "getDeviceVolume", setter = "setDeviceVolumeRaw" },
    { key = "television", getter = "getIsTelevision", setter = "setIsTelevision" },
    { key = "deviceName", getter = "getDeviceName", setter = "setDeviceName" },
    { key = "twoWay", getter = "getIsTwoWay", setter = "setIsTwoWay" },
    { key = "transmitRange", getter = "getTransmitRange", setter = "setTransmitRange" },
    { key = "portable", getter = "getIsPortable", setter = "setIsPortable" },
    { key = "turnedOn", getter = "getIsTurnedOn", setter = "setTurnedOnRaw" },
    { key = "channel", getter = "getChannel", setter = "setChannelRaw" },
    -- DeviceData.getUseDelta() returns the internal per-minute decrement,
    -- while setUseDelta() accepts the unclamped initial value and divides it by 60.
    { key = "useDelta", getter = "getUseDelta", setter = "setUseDelta", restoreScale = 60 },
    { key = "power", getter = "getPower", setter = "setPower" },
    { key = "mediaType", getter = "getMediaType", setter = "setMediaType" },
}

local NATIVE_BLOOD_IDS = { "Front", "Rear", "Left", "Right" }

local function engineFeatureLoudnessInput(storedLoudness)
    -- BaseVehicle:setEngineFeature() calls VehicleEngine.setFeatures(), which
    -- stores (int)(input * 0.37037036). Choose an input that restores the
    -- integer returned by getEngineLoudness() after that conversion.
    local input = math.floor(storedLoudness * 2.7)
    if storedLoudness < 0 then
        return input - 1
    end
    return input + 1
end

local function copyPureData(value, copies)
    local valueType = type(value)
    if valueType == "nil" or valueType == "boolean"
            or valueType == "number" or valueType == "string" then
        return value
    end
    if valueType ~= "table" then
        error("RailroaderRV vehicle snapshot ModData contains a non-Lua value: " .. valueType)
    end

    copies = copies or {}
    if copies[value] ~= nil then return copies[value] end
    local result = {}
    copies[value] = result
    for key, child in pairs(value) do
        result[copyPureData(key, copies)] = copyPureData(child, copies)
    end
    return result
end

local function captureModData(object)
    if not object:hasModData() then return nil end
    return copyPureData(object:getModData())
end

local function restoreModData(object, snapshot)
    if snapshot == nil and not object:hasModData() then return end
    local target = object:getModData()
    local keys = {}
    for key in pairs(target) do
        keys[#keys + 1] = key
    end
    for _, key in ipairs(keys) do
        target[key] = nil
    end
    if snapshot ~= nil then
        for key, value in pairs(snapshot) do
            target[copyPureData(key)] = copyPureData(value)
        end
    end
end

local function captureFluidContainer(container)
    if container == nil then return nil end

    local state = {
        capacity = container:getCapacity(),
        inputLocked = container:isInputLocked(),
        canPlayerEmpty = container:canPlayerEmpty(),
        rainCatcher = container:getRainCatcher(),
        containerName = container:getContainerName(),
        fluids = {},
    }
    local allFluids = Fluid.getAllFluids()
    for index = 0, allFluids:size() - 1 do
        local fluid = allFluids:get(index)
        local amount = container:getSpecificFluidAmount(fluid)
        if amount > 0 then
            state.fluids[#state.fluids + 1] = {
                type = fluid:getFluidTypeString(),
                amount = amount,
            }
        end
    end
    table.sort(state.fluids, function(first, second)
        return first.type < second.type
    end)
    return state
end

local function restoreFluidContainer(container, snapshot)
    if snapshot == nil then return end
    container:setInputLocked(false)
    container:setCanPlayerEmpty(true)
    container:removeFluid()
    container:setCapacity(snapshot.capacity)
    for _, fluid in ipairs(snapshot.fluids) do
        container:addFluid(fluid.type, fluid.amount)
    end
    container:setInputLocked(snapshot.inputLocked)
    container:setCanPlayerEmpty(snapshot.canPlayerEmpty)
    container:setRainCatcher(snapshot.rainCatcher)
    container:setContainerName(snapshot.containerName)
end

local function clearDeviceMedia(deviceData)
    if not deviceData:hasMedia() then return end
    local container = ItemContainer.new()
    deviceData:removeMediaItem(container)
    local mediaItem = container:getItems():get(0)
    container:Remove(mediaItem)
    getCell():getProcessItems():remove(mediaItem)
end

local function captureDeviceData(deviceData)
    if deviceData == nil then return nil end

    local state = { fields = {}, presets = nil }
    for _, field in ipairs(DEVICE_FIELDS) do
        state.fields[field.key] = deviceData[field.getter](deviceData)
    end

    local presets = deviceData:getDevicePresets()
    local entries = presets:getPresets()
    local presetState = { maxPresets = presets:getMaxPresets(), entries = {} }
    for index = 0, entries:size() - 1 do
        local entry = entries:get(index)
        presetState.entries[#presetState.entries + 1] = {
            name = entry:getName(),
            frequency = entry:getFrequency(),
        }
    end
    state.presets = presetState
    return state
end

local function restoreDeviceData(deviceData, snapshot)
    clearDeviceMedia(deviceData)
    if snapshot == nil then return end
    for _, field in ipairs(DEVICE_FIELDS) do
        local value = snapshot.fields[field.key]
        if field.restoreScale ~= nil then
            value = value * field.restoreScale
        end
        deviceData[field.setter](deviceData, value)
    end

    local presets = deviceData:getDevicePresets()
    presets:setMaxPresets(snapshot.presets.maxPresets)
    presets:clearPresets()
    for _, entry in ipairs(snapshot.presets.entries) do
        presets:addPreset(entry.name, entry.frequency)
    end
end

local function captureItem(item)
    if item == nil then return nil end

    local state = {
        fullType = item:getFullType(),
        condition = item:getCondition(),
        keyId = item:getKeyId(),
        displayName = item:getDisplayName(),
        timesRepaired = item:getTimesRepaired(),
        weight = item:getWeight(),
        actualWeight = item:getActualWeight(),
        itemCapacity = item:getItemCapacity(),
        maxCapacity = item:getMaxCapacity(),
        modData = captureModData(item),
        fluidContainer = captureFluidContainer(item:getFluidContainer()),
        deviceData = nil,
    }
    local color = item:getColor()
    state.color = {
        color:getR(),
        color:getG(),
        color:getB(),
        color:getAlphaFloat(),
    }
    if instanceof(item, "DrainableComboItem")
            or instanceof(item, "WeaponPart") then
        state.usedDeltaKind = "currentUsesFloat"
        state.usedDelta = item:getCurrentUsesFloat()
    elseif instanceof(item, "Clothing") then
        state.usedDeltaKind = "usedDelta"
        state.usedDelta = item:getUsedDelta()
    end
    if instanceof(item, "Food") then
        state.age = item:getAge()
    end
    if instanceof(item, "Radio") then
        state.deviceData = captureDeviceData(item:getDeviceData())
    end
    return state
end

local function restoreItem(item, snapshot)
    if snapshot == nil then return end

    restoreModData(item, snapshot.modData)
    item:setCondition(snapshot.condition)
    item:setKeyId(snapshot.keyId)
    item:setName(snapshot.displayName)
    item:setTimesRepaired(snapshot.timesRepaired)
    item:setWeight(snapshot.weight)
    item:setActualWeight(snapshot.actualWeight)
    item:setItemCapacity(snapshot.itemCapacity)
    item:setMaxCapacity(snapshot.maxCapacity)
    local color = item:getColor()
    color:set(snapshot.color[1], snapshot.color[2], snapshot.color[3], snapshot.color[4])
    item:setColor(color)
    if snapshot.usedDeltaKind == "currentUsesFloat" then
        item:setUsedDelta(snapshot.usedDelta)
    elseif snapshot.usedDeltaKind == "usedDelta" then
        item:setUsedDelta(snapshot.usedDelta)
    end
    if snapshot.age ~= nil then
        item:setAge(snapshot.age)
    end
    restoreFluidContainer(item:getFluidContainer(), snapshot.fluidContainer)
    if instanceof(item, "Radio") then
        local deviceData = item:getDeviceData()
        if deviceData ~= nil then
            restoreDeviceData(deviceData, snapshot.deviceData)
        end
    end
end

local function capturePart(part)
    local state = {
        id = part:getId(),
        fields = {},
        modData = captureModData(part),
        installedItem = captureItem(part:getInventoryItem()),
        container = nil,
        door = nil,
        window = nil,
        light = nil,
        deviceData = captureDeviceData(part:getDeviceData()),
    }
    for _, field in ipairs(PART_FIELDS) do
        state.fields[field.key] = part[field.getter](part)
    end

    if part:isContainer() then
        state.container = { capacity = part:getContainerCapacity() }
        if state.modData ~= nil and state.modData.contentAmount ~= nil then
            state.container.contentAmount = part:getContainerContentAmount()
        end
    end

    local door = part:getDoor()
    if door ~= nil then
        state.door = {
            open = door:isOpen(),
            locked = door:isLocked(),
            lockBroken = door:isLockBroken(),
        }
    end

    local window = part:getWindow()
    if window ~= nil then
        state.window = {
            open = window:isOpen(),
            openDelta = window:getOpenDelta(),
        }
    end

    local light = part:getLight()
    if light ~= nil then
        state.light = {
            active = light:getActive(),
        }
    end
    return state
end

local function captureBloodIntensity(vehicle, partSnapshots)
    local state = {}
    for _, id in ipairs(NATIVE_BLOOD_IDS) do
        state[id] = vehicle:getBloodIntensity(id)
    end
    for _, part in ipairs(partSnapshots) do
        state[part.id] = vehicle:getBloodIntensity(part.id)
    end
    return state
end

local function restorePart(part, snapshot)
    local item = nil
    if snapshot.installedItem ~= nil then
        item = instanceItem(snapshot.installedItem.fullType)
    end
    part:setInventoryItem(item)

    for _, field in ipairs(PART_FIELDS) do
        part[field.setter](part, snapshot.fields[field.key])
    end
    if snapshot.container ~= nil then
        part:setContainerCapacity(snapshot.container.capacity)
        if snapshot.container.contentAmount ~= nil then
            part:setContainerContentAmount(snapshot.container.contentAmount)
        end
    end
    restoreItem(item, snapshot.installedItem)

    if snapshot.door ~= nil then
        local door = part:getDoor()
        door:setOpen(snapshot.door.open)
        door:setLocked(snapshot.door.locked)
        door:setLockBroken(snapshot.door.lockBroken)
    end
    if snapshot.window ~= nil then
        local window = part:getWindow()
        window:setOpen(snapshot.window.open)
        window:setOpenDelta(snapshot.window.openDelta)
    end
    if snapshot.light ~= nil then
        local light = part:getLight()
        light:setActive(snapshot.light.active)
    end
    local deviceData = part:getDeviceData()
    if snapshot.deviceData ~= nil and deviceData == nil then
        deviceData = part:createSignalDevice()
    end
    if deviceData ~= nil then
        restoreDeviceData(deviceData, snapshot.deviceData)
    end
    restoreModData(part, snapshot.modData)
end

function State.capture(vehicle)
    local snapshot = {
        vehicleScript = vehicle:getScriptName(),
        fields = {},
        modData = captureModData(vehicle),
        parts = {},
    }
    for _, field in ipairs(VEHICLE_FIELDS) do
        snapshot.fields[field.key] = vehicle[field.getter](vehicle)
    end
    snapshot.fields.colorHSV = {
        vehicle:getColorHue(),
        vehicle:getColorSaturation(),
        vehicle:getColorValue(),
    }
    snapshot.fields.engineFeature = {
        quality = vehicle:getEngineQuality(),
        loudness = vehicle:getEngineLoudness(),
        power = vehicle:getEnginePower(),
    }
    snapshot.fields.engineRunning = vehicle:isEngineRunning()
    snapshot.fields.lightbarSirenMode = vehicle:getLightbarSirenMode()

    for index = 0, vehicle:getPartCount() - 1 do
        snapshot.parts[#snapshot.parts + 1] = capturePart(vehicle:getPartByIndex(index))
    end
    snapshot.fields.bloodIntensity = captureBloodIntensity(vehicle, snapshot.parts)
    return snapshot
end

function State.restore(vehicle, snapshot)
    local ignitionKey = vehicle:getCurrentKey()
    if ignitionKey ~= nil then
        ignitionKey:getContainer():removeAllItems()
    end

    local partsById = {}
    for index = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(index)
        local container = part:getItemContainer()
        if container ~= nil then
            container:removeAllItems()
        end
        partsById[part:getId()] = part
    end
    for _, partSnapshot in ipairs(snapshot.parts) do
        restorePart(partsById[partSnapshot.id], partSnapshot)
    end

    vehicle:setColorHSV(
        snapshot.fields.colorHSV[1],
        snapshot.fields.colorHSV[2],
        snapshot.fields.colorHSV[3])
    vehicle:setRust(snapshot.fields.rust)
    vehicle:setEngineFeature(
        snapshot.fields.engineFeature.quality,
        engineFeatureLoudnessInput(snapshot.fields.engineFeature.loudness),
        snapshot.fields.engineFeature.power)
    vehicle:setLightbarSirenMode(snapshot.fields.lightbarSirenMode)
    for _, field in ipairs(VEHICLE_FIELDS) do
        vehicle[field.setter](vehicle, snapshot.fields[field.key])
    end
    for id, intensity in pairs(snapshot.fields.bloodIntensity) do
        vehicle:setBloodIntensity(id, intensity)
    end
    restoreModData(vehicle, snapshot.modData)

    -- This uses BaseVehicle's public state methods without explicit registration
    -- or custom synchronization; the native engine transition may transmit.
    if vehicle:getEngine() ~= nil then
        if snapshot.fields.engineRunning then
            vehicle:engineDoRunning()
        else
            vehicle:engineDoIdle()
        end
    end
end

return State
