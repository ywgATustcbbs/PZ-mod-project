-- Shared identity and capability rules for RV water sinks.
--
-- A sink is current only when its Water tag names the complete current mapping
-- identity. Native plumbing capability is checked separately.

require "RailroaderRV/Common/RV_Constants"
local StrictSchema = require "RailroaderRV/Common/RV_StrictSchema"
local RegionSlots = require "RailroaderRV/RVMapping/RV_RegionSlots"

RailroaderRV = RailroaderRV or {}
local C = RailroaderRV.Constants
local M = {}
local integer = StrictSchema.integer

-- The tag names the owning RV generation and the slot allocation that fixes
-- the sink's position in the slot matrix.  `anchor` is deliberately absent:
-- it is `RegionSlots.indexToAnchor(slotIndex)`, a pure template lookup.
M.WATER_TAG_KEY = "RailroaderRVTestWater"

local function tagForObject(object)
    if object == nil or type(object.getModData) ~= "function" then return nil end
    local ok, data = pcall(object.getModData, object)
    if not ok or type(data) ~= "table" then return nil end
    local tag = data[M.WATER_TAG_KEY]
    if type(tag) ~= "table"
        or tag.owner ~= C.MOD_ID or tag.role ~= "sink"
        or type(tag.rvId) ~= "string" or tag.rvId == ""
        or integer(tag.generation) == nil or tag.generation < 1
        or integer(tag.slotIndex) == nil then
        return nil
    end
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
    if object == nil or type(object.getModData) ~= "function" then return false end
    local ok, data = pcall(object.getModData, object)
    return ok and type(data) == "table" and data[M.WATER_TAG_KEY] ~= nil
end

-- The server always supplies identity and mappingRecord. Client callers may
-- omit both arguments only to decide whether a context-menu option is useful.
function M.isCurrentWaterSink(object, identity, mappingRecord)
    local tag = tagForObject(object)
    if not tag then return false end
    if identity == nil and mappingRecord == nil then return true end
    if type(identity) ~= "table" or type(mappingRecord) ~= "table"
        or type(identity.rvId) ~= "string" or identity.rvId == ""
        or integer(identity.generation) == nil then
        return false
    end
    return tostring(tag.rvId) == tostring(identity.rvId)
        and integer(tag.generation) == integer(identity.generation)
end

local function invoke(target, method, ...)
    if target == nil or type(target[method]) ~= "function" then return false end
    local ok, result = pcall(target[method], target, ...)
    return ok, result
end

local function hasWaterPipedFlag(object)
    local spriteOk, sprite = invoke(object, "getSprite")
    if not spriteOk or not sprite then return false end
    local propertiesOk, properties = invoke(sprite, "getProperties")
    local flags = rawget(_G, "IsoFlagType")
    local waterPiped = flags and flags.waterPiped
    if not propertiesOk or not properties or waterPiped == nil then return false end
    local hasOk, has = invoke(properties, "has", waterPiped)
    return hasOk and has == true
end

function M.isWaterPipedDevice(object)
    if object == nil then return false end
    if hasWaterPipedFlag(object) then return true end
    local dataOk, data = invoke(object, "getModData")
    return dataOk and type(data) == "table" and data.canBeWaterPiped == true
end

function M.hasFluidContainer(object)
    local ok, container = invoke(object, "getFluidContainer")
    return ok and container ~= nil
end

return M
