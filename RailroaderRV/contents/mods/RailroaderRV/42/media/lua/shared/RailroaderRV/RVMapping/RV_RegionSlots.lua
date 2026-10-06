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
local FIRST_MIN_X = C.TELEPORT_X + C.RV_REGION_MIN_OFFSET_X
local FIRST_MIN_Y = C.TELEPORT_Y + C.RV_REGION_MIN_OFFSET_Y
local FIRST_Z = C.TELEPORT_Z

if type(SIZE) ~= "number" or SIZE ~= 100 then
    error("RailroaderRV: RV region slot size must be 100")
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

function Slots.findFirstFree(regions)
    local occupied = {}
    for i = 1, #regions do
        local region = regions[i]
        local column = (region.minX - FIRST_MIN_X) / SIZE + 1
        local row = (region.minY - FIRST_MIN_Y) / SIZE + 1
        occupied[indexForSlot(row, column)] = true
    end

    for index = 1, Slots.COUNT do
        if not occupied[index] then
            return index, Slots.indexToAnchor(index), Slots.indexToRegion(index)
        end
    end
    return nil, "no-free-slot"
end

return Slots
