-- Server-authoritative roof-device validation and virtual inventory mutation.
local U = require("RailroaderRV/Common/RV_UtilityConstants")
local P = require("RailroaderRV/Power/RV_UtilityPowerConfig")
local Roof = require("RailroaderRV/Roof/RV_RoofDevices")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")
local Inventory = require("RailroaderRV/Core/RV_ServerInventoryTransaction")
local Util = require("RailroaderRV/Common/RV_ServerUtil")

local M = {}

local function actionIntent(roofOperation, targetHint, item)
    if roofOperation ~= U.OP_INSTALL_ROOF_DEVICE
        and roofOperation ~= U.OP_REMOVE_ROOF_DEVICE then
        return nil, U.REASONS.INVALID_REQUEST
    end
    if type(targetHint) ~= "table" then
        return nil, U.REASONS.DEVICE_INVALID
    end
    for key in pairs(targetHint) do
        if key ~= "x" and key ~= "y" and key ~= "z" then
            return nil, U.REASONS.INVALID_REQUEST
        end
    end
    local x, y, z = Util.integer(targetHint.x), Util.integer(targetHint.y),
        Util.integer(targetHint.z)
    if x == nil or y == nil or z == nil then
        return nil, U.REASONS.DEVICE_INVALID
    end
    if roofOperation == U.OP_INSTALL_ROOF_DEVICE then
        if not item then return nil, U.REASONS.SOURCE_INVALID end
    elseif item ~= nil then
        return nil, U.REASONS.INVALID_REQUEST
    end
    return { roofOperation = roofOperation,
        targetHint = { x = x, y = y, z = z }, item = item }
end

local function planAction(context, intent, record)
    local template = RoomTemplate.get(context.record.templateId)
    local cell = intent.targetHint
    if not Roof.isRoofCell(template, cell) then
        return false, U.REASONS.DEVICE_INVALID
    end
    local devices = Roof.devices(record)
    if intent.roofOperation == U.OP_INSTALL_ROOF_DEVICE then
        local found = Inventory.findItem(context.player, intent.item:getID())
        if not found then return false, U.REASONS.SOURCE_NOT_INVENTORY end
        local fullType = Inventory.itemType(found.item)
        local deviceType = Roof.typeForItem(found.item)
        if not deviceType then return false, U.REASONS.SOURCE_INVALID end
        local canPlace, reason = Roof.canPlace(template, devices, cell,
            deviceType)
        if not canPlace then
            return false, reason == "CAPACITY_FULL"
                and U.REASONS.CAPACITY_FULL or U.REASONS.DEVICE_INVALID
        end
        local condition, maxCondition, usedDelta, name, nativeFuel
        if deviceType ~= Roof.DEVICE_RAIN then
            condition, maxCondition, usedDelta = Inventory.itemCondition(found.item)
            if condition == nil or maxCondition == nil then
                return false, U.REASONS.SOURCE_INVALID
            end
            name = found.item:getName()
            nativeFuel = found.item:getModData().fuel
            if type(name) ~= "string"
                or (nativeFuel ~= nil and not (type(nativeFuel) == "number"
                    and nativeFuel == nativeFuel and nativeFuel < math.huge
                    and nativeFuel > -math.huge)) then
                return false, U.REASONS.SOURCE_INVALID
            end
        end
        local factoryType, capacityL, containerName, rainCatcher
        if deviceType == Roof.DEVICE_RAIN then
            local fluidContainer = found.item:getFluidContainer()
            factoryType = "Moveables." .. found.item:getWorldSprite()
            capacityL = fluidContainer:getCapacity()
            containerName = fluidContainer:getContainerName()
            rainCatcher = fluidContainer:getRainCatcher()
        end
        return true, { record = record, template = template, cell = cell,
            found = found, fullType = fullType, deviceType = deviceType,
            factoryType = factoryType,
            capacityL = capacityL, containerName = containerName,
            rainCatcher = rainCatcher,
            condition = condition, usedDelta = usedDelta, name = name,
            nativeFuel = nativeFuel }
    end
    local device = Roof.deviceAt(devices, cell)
    if not device then return false, U.REASONS.DEVICE_INVALID end
    return true, { record = record, template = template, cell = cell,
        device = device }
end

function M.devices(record)
    return Roof.devices(record)
end

function M.performAction(context, roofOperation, targetHint, item, record)
    local intent, reason = actionIntent(roofOperation, targetHint, item)
    if not intent then return false, reason end
    local accepted, planOrReason = planAction(context, intent, record)
    if not accepted then return false, planOrReason end
    local plan = planOrReason
    local record = plan.record
    local transaction = Inventory.new(context.player)

    if roofOperation == U.OP_INSTALL_ROOF_DEVICE then
        transaction:consumeFound(plan.found)
        if plan.deviceType == Roof.DEVICE_RAIN then
            record.water.roofCollectors[Roof.key(plan.cell)] = {
                x = plan.cell.x, y = plan.cell.y, z = plan.cell.z,
                factoryType = plan.factoryType,
                capacityL = plan.capacityL,
                containerName = plan.containerName,
                rainCatcher = plan.rainCatcher,
            }
        else
            local generator = { id = record.power.nextGeneratorId,
                fullType = plan.fullType, name = plan.name,
                condition = plan.condition, usedDelta = plan.usedDelta,
                nativeFuel = plan.nativeFuel,
                enabled = P.GENERATOR_TYPES[plan.fullType].renewableType ~= nil,
                x = plan.cell.x, y = plan.cell.y, z = plan.cell.z }
            record.power.generators[#record.power.generators + 1] = generator
            record.power.nextGeneratorId = record.power.nextGeneratorId + 1
        end
    else
        local device = plan.device
        if device.type == Roof.DEVICE_RAIN then
            local collector = record.water.roofCollectors[device.id]
            local item = Inventory.createItem(collector.factoryType)
            local fluidContainer = ComponentType.FluidContainer:CreateComponent()
            fluidContainer:setCapacity(collector.capacityL)
            fluidContainer:setContainerName(collector.containerName)
            fluidContainer:setRainCatcher(collector.rainCatcher)
            GameEntityFactory.AddComponent(item, true, fluidContainer)
            transaction:returnItem(context.player:getInventory(), item)
            record.water.roofCollectors[device.id] = nil
        else
            local generatorIndex, generator
            for index = 1, #record.power.generators do
                local current = record.power.generators[index]
                if current.id == device.id then
                    generatorIndex, generator = index, current
                    break
                end
            end
            if not generator then
                error("RailroaderRV: roof device has no stored generator")
            end
            local item = Inventory.createItem(generator.fullType,
                generator.condition, generator.usedDelta)
            item:setName(generator.name)
            item:getModData().fuel = generator.nativeFuel
            transaction:returnItem(context.player:getInventory(), item)
            table.remove(record.power.generators, generatorIndex)
        end
    end

    return true, { record = record, transaction = transaction }
end

return M
