-- Server-side natural source selection and strict water-fluid classification.

local U = require("RailroaderRV/Common/RV_UtilityConstants")
local W = require("RailroaderRV/Water/RV_UtilityWaterConstants")
local World = require("RailroaderRV/Common/RV_ServerWorld")
local Util = require("RailroaderRV/Common/RV_ServerUtil")

local M = {}
local pumpSprites = {
    ["camping_01_16"] = true,
    ["camping_01_64"] = true,
    ["camping_01_65"] = true,
    ["camping_01_66"] = true,
    ["camping_01_67"] = true,
}

local function classifyFluid(fluid)
    if fluid == Fluid.Water then return "clean" end
    if fluid == Fluid.TaintedWater then return "tainted" end
    return nil
end

function M.exactWaterKind(fluidContainer)
    local sample = fluidContainer:createFluidSample()
    local size = sample:size()
    if size == 0 then
        sample:release()
        return nil
    end

    local sawWater, sawTainted = false, false
    for index = 0, size - 1 do
        local kind = classifyFluid(sample:getFluid(index))
        if kind == "clean" then
            sawWater = true
        elseif kind == "tainted" then
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

local function sourceSprite(source)
    local sprite = source:getSprite()
    if not sprite then return nil end
    return sprite:getName()
end

local function isNaturalSource(source)
    local spriteName = sourceSprite(source)
    if type(spriteName) ~= "string" then return false end
    local lakeOrRiver = spriteName:sub(1, 17) == "blends_natural_02"
    if not lakeOrRiver and not pumpSprites[spriteName] then return false end
    return source:getUsesExternalWaterSource() ~= true
end

function M.sourceWaterKind(source)
    local fluidContainer = source:getFluidContainer()
    if fluidContainer ~= nil then
        return M.exactWaterKind(fluidContainer)
    end

    local fluid
    if pumpSprites[sourceSprite(source)] then
        fluid = Fluid.Water
    else
        fluid = source:getPrimaryFluid()
    end
    return classifyFluid(fluid)
end

local function sourceHintValues(hint)
    if type(hint) ~= "table" then return nil end
    local count = 0
    for key in pairs(hint) do
        if key ~= "x" and key ~= "y" and key ~= "z"
            and key ~= "objectIndex" then
            return nil
        end
        count = count + 1
    end
    if count ~= 4 then return nil end
    local x, y, z = Util.integer(hint.x), Util.integer(hint.y),
        Util.integer(hint.z)
    local objectIndex = Util.integer(hint.objectIndex)
    if x == nil or y == nil or z == nil or objectIndex == nil
        or objectIndex < 0 then
        return nil
    end
    return x, y, z, objectIndex
end

local function sourceAtSquare(square, objectIndex)
    local objects = World.squareSnapshot(square)
    for index = 1, #objects do
        local source = objects[index]
        if (objectIndex == nil or source:getObjectIndex() == objectIndex)
            and isNaturalSource(source) then
            local kind = M.sourceWaterKind(source)
            if kind and source:getFluidAmount() > 0 then
                return { object = source, kind = kind }
            end
        end
    end
    return nil
end

function M.resolveNaturalSource(player, hint)
    local playerX, playerY, playerZ = player:getX(), player:getY(), player:getZ()
    local centerX, centerY, centerZ = math.floor(playerX), math.floor(playerY),
        math.floor(playerZ)
    local cell = World.getCellForPlayer(player)
    if hint ~= nil then
        local x, y, z, objectIndex = sourceHintValues(hint)
        if x == nil then return false, U.REASONS.INVALID_REQUEST end
        local dx, dy = x - centerX, y - centerY
        local radius = W.NATURAL_SOURCE_RADIUS
        if z ~= centerZ or dx * dx + dy * dy > radius * radius then
            return false, U.REASONS.PERMISSION
        end
        local square = World.getSquare(cell, x, y, z)
        if not square then return false, U.REASONS.TARGET_NOT_LOADED end
        local source = sourceAtSquare(square, objectIndex)
        if not source then return false, U.REASONS.SOURCE_INVALID end
        return true, source
    end

    local radius = W.NATURAL_SOURCE_RADIUS
    for dx = -radius, radius do
        for dy = -radius, radius do
            if dx * dx + dy * dy <= radius * radius then
                local square = World.getSquare(cell,
                    centerX + dx, centerY + dy, centerZ)
                if square then
                    local source = sourceAtSquare(square, nil)
                    if source then return true, source end
                end
            end
        end
    end
    return false, U.REASONS.SOURCE_INVALID
end

return M
