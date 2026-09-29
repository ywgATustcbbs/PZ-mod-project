-- Hide only the generation-tagged wooden wall backing used under RV fences.
-- IsoObject.doRender is a local render flag, so apply it after client object
-- sync and again when a saved/reused grid square enters the loaded area.

local C = require "RailroaderRV/Common/RV_Constants"
local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local ProtectionManifest = require "RailroaderRV/RoomTemplate/RV_ProtectionManifest"

local templateValid, templateError = RoomTemplate.validate(Template)
if not templateValid then
    error("RailroaderRVTest: current boundary RoomTemplate is invalid: "
        .. tostring(templateError))
end

local boundaryRoles = {
    ["wall-north"] = true,
    ["wall-west"] = true,
    ["corner-nw"] = true,
}

local supportWallSprites = {
    walls_interior_house_02_32 = true,
    walls_interior_house_02_33 = true,
    walls_interior_house_02_35 = true,
}

local warned = false

local function call(target, method, ...)
    if target == nil or type(target[method]) ~= "function" then
        return false, nil
    end
    local ok, a, b = pcall(target[method], target, ...)
    if not ok then return false, a end
    return true, a, b
end

local function integer(value)
    return C.finiteInteger(value)
end

local function warnOnce(message)
    if warned then return end
    warned = true
    print("[RailroaderRVTest] RV boundary wall visual update failed: "
        .. tostring(message))
end

local function isTaggedBoundarySupportWall(object)
    local dataOk, data = call(object, "getModData")
    if not dataOk or type(data) ~= "table" then return false end
    local tag = data.RailroaderRVTest
    local templateIndex = type(tag) == "table" and integer(tag.templateIndex) or nil
    local expected = templateIndex and ProtectionManifest.get(templateIndex) or nil
    local anchorX = type(tag) == "table" and integer(tag.templateAnchorX) or nil
    local anchorY = type(tag) == "table" and integer(tag.templateAnchorY) or nil
    local anchorZ = type(tag) == "table" and integer(tag.templateAnchorZ) or nil
    if type(tag) ~= "table" or tag.templateBoundarySupportWall ~= true
        or data.owner ~= C.MOD_ID or tag.owner ~= C.MOD_ID
        or type(data.rvId) ~= "string" or data.rvId == ""
        or data.rvId ~= tag.rvId
        or integer(data.generation) == nil or integer(data.generation) < 1
        or integer(data.generation) ~= integer(tag.generation)
        or integer(data.bitmapVersion) ~= C.BITMAP_VERSION
        or integer(tag.bitmapVersion) ~= C.BITMAP_VERSION
        or data.role ~= tag.role or not boundaryRoles[tag.role]
        or not expected or expected.protectionClass ~= ProtectionManifest.PROHIBITED
        or integer(tag.protectionClass) ~= expected.protectionClass
        or integer(tag.templateX) ~= expected.x
        or integer(tag.templateY) ~= expected.y
        or integer(tag.templateZ) ~= expected.z
        or anchorX == nil or anchorY == nil or anchorZ == nil
        or integer(tag.templateWorldX) ~= anchorX + expected.x
        or integer(tag.templateWorldY) ~= anchorY + expected.y
        or integer(tag.templateWorldZ) ~= anchorZ + expected.z
        or tag.templateClass ~= "IsoThumpable"
        or expected.class ~= "IsoThumpable"
        or expected.name ~= "Wooden Wall"
        or tag.templateName ~= expected.name
        or not supportWallSprites[expected.sprite]
        or tag.templateSprite ~= expected.sprite
        or tag.templateDirection ~= expected.direction then
        return false
    end
    if tag.templateNorth ~= expected.north then return false end
    if tag.role == "wall-north" or tag.role == "corner-nw" then
        return expected.north == true
    end
    return expected.north == false
end

local function hideBoundarySupportWall(object)
    if not isTaggedBoundarySupportWall(object) then return end
    local setOk = call(object, "setDoRender", false)
    local readOk, doRender = call(object, "getDoRender")
    if not setOk or not readOk or doRender ~= false then
        warnOnce("setDoRender(false) could not be verified")
        return
    end
    local renderer = rawget(_G, "FBORenderChunk")
    local dirtyRedraw = renderer and renderer.DIRTY_REDRAW
    if dirtyRedraw == nil then
        warnOnce("FBORenderChunk.DIRTY_REDRAW is unavailable")
        return
    end
    local invalidated = call(object, "invalidateRenderChunkLevel", dirtyRedraw)
    if not invalidated then
        warnOnce("invalidateRenderChunkLevel is unavailable")
    end
end

local function onObjectAdded(object)
    hideBoundarySupportWall(object)
end

local function onGridSquareLoaded(square)
    local objectsOk, objects = call(square, "getObjects")
    local sizeOk, size = false, nil
    if objectsOk then sizeOk, size = call(objects, "size") end
    if not sizeOk or type(size) ~= "number" or size < 1 then return end
    for index = 0, size - 1 do
        local objectOk, object = call(objects, "get", index)
        if objectOk and object then hideBoundarySupportWall(object) end
    end
end

local events = rawget(_G, "Events")
if events then
    if events.OnObjectAdded
        and type(events.OnObjectAdded.Add) == "function" then
        events.OnObjectAdded.Add(onObjectAdded)
    end
    if events.LoadGridsquare
        and type(events.LoadGridsquare.Add) == "function" then
        events.LoadGridsquare.Add(onGridSquareLoaded)
    end
    if events.ReuseGridsquare
        and type(events.ReuseGridsquare.Add) == "function" then
        events.ReuseGridsquare.Add(onGridSquareLoaded)
    end
end
