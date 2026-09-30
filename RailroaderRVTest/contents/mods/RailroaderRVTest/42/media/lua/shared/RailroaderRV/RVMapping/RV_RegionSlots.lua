-- Pure coordinate contract for the candidate RV management regions.
-- Slots are ordered row-major from the southwest corner: X advances first,
-- then Y advances to the next row. This module never reads or changes world
-- state or ModData.

require "RailroaderRV/Common/RV_Constants"
local StrictSchema = require "RailroaderRV/Common/RV_StrictSchema"

RailroaderRV = RailroaderRV or {}
RailroaderRV.RegionSlots = RailroaderRV.RegionSlots or {}

local Slots = RailroaderRV.RegionSlots
local C = RailroaderRV.Constants

Slots.ROWS = C.RV_REGION_SLOT_ROWS
Slots.COLUMNS = C.RV_REGION_SLOT_COLUMNS
Slots.COUNT = C.RV_REGION_SLOT_COUNT
Slots.REGION_SIZE = C.RV_REGION_SIZE

local SIZE = Slots.REGION_SIZE
local integer = StrictSchema.integer
local exactKeys = StrictSchema.exactKeys
local FIRST_MIN_X = C.TELEPORT_X + C.RV_REGION_MIN_OFFSET_X
local FIRST_MIN_Y = C.TELEPORT_Y + C.RV_REGION_MIN_OFFSET_Y
local FIRST_Z = C.TELEPORT_Z

if type(SIZE) ~= "number" or SIZE ~= 100 then
    error("RailroaderRVTest: RV region slot size must be 100")
end

local function slotForIndex(index)
    index = integer(index)
    if not index or index < 1 or index > Slots.COUNT then return nil end
    local zeroBased = index - 1
    return math.floor(zeroBased / Slots.COLUMNS) + 1,
        zeroBased % Slots.COLUMNS + 1
end

local function indexForSlot(row, column)
    row, column = integer(row), integer(column)
    if not row or not column or row < 1 or row > Slots.ROWS
        or column < 1 or column > Slots.COLUMNS then
        return nil
    end
    return (row - 1) * Slots.COLUMNS + column
end

local function boundsForSlot(row, column)
    local minX = FIRST_MIN_X + (column - 1) * SIZE
    local minY = FIRST_MIN_Y + (row - 1) * SIZE
    return {
        minX = minX,
        minY = minY,
        maxX = minX + SIZE,
        maxY = minY + SIZE,
    }
end

local function anchorForSlot(row, column)
    local region = boundsForSlot(row, column)
    return {
        x = region.minX + SIZE / 2,
        y = region.minY + SIZE / 2,
        z = FIRST_Z,
    }
end

local function denseRegionList(regions)
    if type(regions) ~= "table" or getmetatable(regions) ~= nil then
        return nil
    end
    local count, highest = 0, 0
    for key in pairs(regions) do
        if type(key) ~= "number" or integer(key) ~= key
            or key < 1 or key > Slots.COUNT then
            return nil
        end
        count = count + 1
        if key > highest then highest = key end
    end
    if count ~= highest then return nil end
    return count
end

local function validatedRegion(region)
    if not exactKeys(region, { "minX", "minY", "maxX", "maxY" }) then
        return nil
    end
    local minX, minY = integer(region.minX), integer(region.minY)
    local maxX, maxY = integer(region.maxX), integer(region.maxY)
    if not minX or not minY or not maxX or not maxY
        or maxX ~= minX + SIZE or maxY ~= minY + SIZE then
        return nil
    end

    local dx, dy = minX - FIRST_MIN_X, minY - FIRST_MIN_Y
    if dx < 0 or dy < 0 or dx >= Slots.COLUMNS * SIZE
        or dy >= Slots.ROWS * SIZE or dx % SIZE ~= 0 or dy % SIZE ~= 0 then
        return nil
    end
    local column, row = dx / SIZE + 1, dy / SIZE + 1
    local index = indexForSlot(row, column)
    if not index then return nil end
    return index, { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
end

function Slots.indexToSlot(index)
    return slotForIndex(index)
end

function Slots.slotToIndex(row, column)
    return indexForSlot(row, column)
end

function Slots.indexToAnchor(index)
    local row, column = slotForIndex(index)
    if not row then return nil end
    return anchorForSlot(row, column)
end

function Slots.indexToRegion(index)
    local row, column = slotForIndex(index)
    if not row then return nil end
    return boundsForSlot(row, column)
end

function Slots.indexForAnchor(anchor)
    if not exactKeys(anchor, { "x", "y", "z" }) then return nil end
    local x, y, z = integer(anchor.x), integer(anchor.y), integer(anchor.z)
    if not x or not y or z ~= FIRST_Z then return nil end

    local dx, dy = x - (FIRST_MIN_X + SIZE / 2),
        y - (FIRST_MIN_Y + SIZE / 2)
    if dx < 0 or dy < 0 or dx >= Slots.COLUMNS * SIZE
        or dy >= Slots.ROWS * SIZE or dx % SIZE ~= 0 or dy % SIZE ~= 0 then
        return nil
    end
    return indexForSlot(dy / SIZE + 1, dx / SIZE + 1)
end

function Slots.indexForRegion(region)
    local index = validatedRegion(region)
    return index
end

function Slots.findFirstFree(regions)
    local count = denseRegionList(regions)
    if count == nil then return nil, "invalid-region-list" end

    local occupied, validated = {}, {}
    for i = 1, count do
        local index, region = validatedRegion(regions[i])
        if not index then return nil, "invalid-region" end
        for j = 1, #validated do
            local other = validated[j]
            if region.minX < other.maxX and other.minX < region.maxX
                and region.minY < other.maxY and other.minY < region.maxY then
                return nil, "overlapping-regions"
            end
        end
        occupied[index] = true
        validated[#validated + 1] = region
    end

    for index = 1, Slots.COUNT do
        if not occupied[index] then
            return index, Slots.indexToAnchor(index), Slots.indexToRegion(index)
        end
    end
    return nil, "no-free-slot"
end

return Slots
