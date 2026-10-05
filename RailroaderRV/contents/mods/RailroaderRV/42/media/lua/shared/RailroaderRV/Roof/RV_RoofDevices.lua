-- Shared roof-device definitions and pure placement rules.
local P = require("RailroaderRV/Power/RV_UtilityPowerConfig")
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")

local M = {}

M.DEVICE_SOLAR = "SOLAR"
M.DEVICE_WIND = "WIND"
M.DEVICE_FUEL = "FUEL"
M.DEVICE_RAIN = "RAIN"

local roofCellSets = setmetatable({}, { __mode = "k" })

function M.key(cell)
    return tostring(cell.x) .. ":" .. tostring(cell.y) .. ":"
        .. tostring(cell.z)
end

local function roofCellSet(template)
    local result = roofCellSets[template]
    if result then return result end
    result = {}
    local cells = RoomTemplate.roofCells(template)
    for index = 1, #cells do
        result[M.key(cells[index])] = true
    end
    roofCellSets[template] = result
    return result
end

function M.cells(template)
    return RoomTemplate.roofCells(template)
end

function M.isRoofCell(template, cell)
    if type(cell) ~= "table" then return false end
    return roofCellSet(template)[M.key(cell)] == true
end

local function generatorTypeForFullType(fullType)
    local profile = P.GENERATOR_TYPES[fullType]
    if not profile then return nil end
    if profile.renewableType == "SOLAR" then return M.DEVICE_SOLAR end
    if profile.renewableType == "WIND" then return M.DEVICE_WIND end
    if profile.renewableType == nil then return M.DEVICE_FUEL end
    error("RailroaderRV: unknown renewable generator type "
        .. tostring(profile.renewableType))
end

function M.typeForItem(item)
    if instanceof(item, "Moveable") then
        local worldSprite = item:getWorldSprite()
        if P.RAIN_COLLECTOR_MOVEABLE_SPRITES[worldSprite] then
            return M.DEVICE_RAIN
        end
    end
    return generatorTypeForFullType(item:getFullType())
end

function M.devices(record)
    local result = {}
    for _, generator in ipairs(record.power.generators) do
        local deviceType = generatorTypeForFullType(generator.fullType)
        if not deviceType then
            error("RailroaderRV: stored roof generator has unknown item "
                .. tostring(generator.fullType))
        end
        result[#result + 1] = { x = generator.x, y = generator.y,
            z = generator.z, type = deviceType,
            itemType = generator.fullType, id = generator.id }
    end
    for id, collector in pairs(record.water.roofCollectors) do
        result[#result + 1] = { x = collector.x, y = collector.y,
            z = collector.z, type = M.DEVICE_RAIN,
            itemType = collector.factoryType, id = id,
            waterCapacityL = collector.capacityL }
    end
    table.sort(result, function(left, right)
        if left.z ~= right.z then return left.z < right.z end
        if left.y ~= right.y then return left.y < right.y end
        return left.x < right.x
    end)
    return result
end

function M.deviceAt(devices, cell)
    for index = 1, #devices do
        local device = devices[index]
        if device.x == cell.x and device.y == cell.y
            and device.z == cell.z then
            return device
        end
    end
    return nil
end

function M.canPlace(template, devices, cell, deviceType)
    if not M.isRoofCell(template, cell) then
        return false, "NOT_ROOF_CELL"
    end
    if deviceType ~= M.DEVICE_SOLAR and deviceType ~= M.DEVICE_WIND
        and deviceType ~= M.DEVICE_FUEL and deviceType ~= M.DEVICE_RAIN then
        error("RailroaderRV: unknown internal roof device type "
            .. tostring(deviceType))
    end
    if M.deviceAt(devices, cell) then return false, "OCCUPIED" end
    if deviceType ~= M.DEVICE_RAIN then
        local generatorCount = 0
        for index = 1, #devices do
            if devices[index].type ~= M.DEVICE_RAIN then
                generatorCount = generatorCount + 1
            end
        end
        if generatorCount >= P.MAX_GENERATORS then
            return false, "CAPACITY_FULL"
        end
    end
    if deviceType == M.DEVICE_SOLAR or deviceType == M.DEVICE_WIND
        or deviceType == M.DEVICE_RAIN then
        for dx = -1, 1 do
            for dy = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    local neighbor = M.deviceAt(devices, {
                        x = cell.x + dx, y = cell.y + dy, z = cell.z,
                    })
                    if neighbor and ((deviceType == M.DEVICE_RAIN
                        and (neighbor.type == M.DEVICE_SOLAR
                            or neighbor.type == M.DEVICE_WIND))
                        or ((deviceType == M.DEVICE_SOLAR
                            or deviceType == M.DEVICE_WIND)
                            and neighbor.type == M.DEVICE_RAIN)) then
                        return false, "RAIN_CLEARANCE"
                    end
                end
            end
        end
    end
    return true
end

return M
