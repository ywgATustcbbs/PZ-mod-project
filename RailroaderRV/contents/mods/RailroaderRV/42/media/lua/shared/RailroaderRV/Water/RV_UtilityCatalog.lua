-- Shared identity and capability rules for RV water sinks.
--
-- A sink is current only when its Water tag names the complete current mapping
-- identity. Native plumbing capability is checked separately.

require "RailroaderRV/Common/RV_Constants"

RailroaderRV = RailroaderRV or {}
local C = RailroaderRV.Constants
local M = {}

-- The tag names the owning RV generation and the slot allocation that fixes
-- the sink's position in the slot matrix.  `anchor` is deliberately absent:
-- it is `RegionSlots.indexToAnchor(slotIndex)`, a pure template lookup.
M.WATER_TAG_KEY = "RailroaderRVWater"

local function tagForObject(object)
    if object == nil then return nil end
    local data = object:getModData()
    local tag = data[M.WATER_TAG_KEY]
    if tag == nil then return nil end
    if type(tag) ~= "table" then
        error("RailroaderRV: water sink tag is not a table")
    end
    if tag.owner ~= C.MOD_ID or tag.role ~= "sink" then return nil end
    assert(type(tag.rvId) == "string" and tag.rvId ~= ""
        and type(tag.generation) == "number" and tag.generation >= 1
        and type(tag.slotIndex) == "number",
        "RailroaderRV: water sink identity is incomplete")
    return tag
end

function M.readSinkIdentity(object)
    local tag = tagForObject(object)
    if not tag then return nil end
    return {
        rvId = tag.rvId,
        generation = tag.generation,
        slotIndex = tag.slotIndex,
    }
end

function M.hasSinkIdentity(object)
    if object == nil then return false end
    local data = object:getModData()
    return type(data) == "table" and data[M.WATER_TAG_KEY] ~= nil
end

-- The server always supplies identity and mappingRecord. Client callers may
-- omit both arguments only to decide whether a context-menu option is useful.
function M.isCurrentWaterSink(object, identity, mappingRecord)
    local tag = tagForObject(object)
    if not tag then return false end
    if identity == nil and mappingRecord == nil then return true end
    return tostring(tag.rvId) == tostring(identity.rvId)
        and tag.generation == identity.generation
        and tostring(mappingRecord.locoId) == tostring(identity.rvId)
        and mappingRecord.generation == identity.generation
end

local function hasWaterPipedFlag(object)
    local sprite = object:getSprite()
    if not sprite then return false end
    local properties = sprite:getProperties()
    local flags = rawget(_G, "IsoFlagType")
    local waterPiped = flags and flags.waterPiped
    if not properties or waterPiped == nil then return false end
    return properties:has(waterPiped) == true
end

function M.isWaterPipedDevice(object)
    if object == nil then return false end
    if hasWaterPipedFlag(object) then return true end
    local data = object:getModData()
    return type(data) == "table" and data.canBeWaterPiped == true
end

function M.hasFluidContainer(object)
    return object:getFluidContainer() ~= nil
end

return M
