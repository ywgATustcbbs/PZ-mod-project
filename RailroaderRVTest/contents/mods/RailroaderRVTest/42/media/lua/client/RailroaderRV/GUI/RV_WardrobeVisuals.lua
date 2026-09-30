-- Hide only the four generation-tagged wardrobe tiles placed west of the cab.
-- Keep the IsoThumpable object itself in the square so its collision and the
-- existing demolition protection/template protection repair continue to work.

local C = require "RailroaderRV/Common/RV_Constants"
local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local ProtectionManifest = require "RailroaderRV/RoomTemplate/RV_ProtectionManifest"

local templateValid, templateError = RoomTemplate.validate(Template)
if not templateValid then
    error("RailroaderRVTest: current wardrobe RoomTemplate is invalid: "
        .. tostring(templateError))
end

local wardrobeSpritesByY = {
    [-2] = "furniture_storage_01_25",
    [-1] = "furniture_storage_01_24",
    [0] = "furniture_storage_01_25",
    [1] = "furniture_storage_01_24",
}

local warned = false

local function call(target, method, ...)
    if target == nil or type(target[method]) ~= "function" then
        return false, nil
    end
    local ok, a, b = pcall(target[method], target, ...)
    if not ok then return false, nil end
    return true, a, b
end

local function warnOnce(message)
    if warned then return end
    warned = true
    print("[RailroaderRVTest] RV wardrobe visual update failed: "
        .. tostring(message))
end

local function isWardrobeTemplateEntry(entry)
    return type(entry) == "table"
        and entry.class == "IsoThumpable"
        and entry.name == "Dark Fancy Wardrobe"
        and entry.x == -5 and entry.z == 0
        and wardrobeSpritesByY[entry.y] == entry.sprite
        and entry.north == true and entry.direction == "N"
        and entry.protectionClass == ProtectionManifest.PROHIBITED
        and type(entry.state) == "table" and entry.state.doRender == false
end

local function isTaggedWardrobe(object)
    local dataOk, data = call(object, "getModData")
    if not dataOk or type(data) ~= "table" then return false end

    local tag = data.RailroaderRVTest
    if type(tag) ~= "table"
        or data.owner ~= C.MOD_ID or tag.owner ~= C.MOD_ID
        or type(data.rvId) ~= "string" or data.rvId == ""
        or data.rvId ~= tag.rvId
        or C.finiteInteger(data.generation) == nil or C.finiteInteger(data.generation) < 1
        or C.finiteInteger(data.generation) ~= C.finiteInteger(tag.generation)
        or C.finiteInteger(data.bitmapVersion) ~= C.BITMAP_VERSION
        or C.finiteInteger(tag.bitmapVersion) ~= C.BITMAP_VERSION
        or data.role ~= "captured-template"
        or tag.role ~= data.role then
        return false
    end

    local templateIndex = C.finiteInteger(tag.templateIndex)
    if templateIndex == nil or templateIndex < 1 then return false end
    local entry = ProtectionManifest.get(templateIndex)
    local anchorX, anchorY, anchorZ = C.finiteInteger(tag.templateAnchorX),
        C.finiteInteger(tag.templateAnchorY), C.finiteInteger(tag.templateAnchorZ)
    if not isWardrobeTemplateEntry(entry)
        or tag.templateClass ~= entry.class
        or tag.templateName ~= entry.name
        or tag.templateSprite ~= entry.sprite
        or tag.templateNorth ~= entry.north
        or tag.templateDirection ~= entry.direction
        or C.finiteInteger(tag.protectionClass) ~= entry.protectionClass
        or C.finiteInteger(tag.templateX) ~= entry.x
        or C.finiteInteger(tag.templateY) ~= entry.y
        or C.finiteInteger(tag.templateZ) ~= entry.z
        or anchorX == nil or anchorY == nil or anchorZ == nil
        or C.finiteInteger(tag.templateWorldX) ~= anchorX + entry.x
        or C.finiteInteger(tag.templateWorldY) ~= anchorY + entry.y
        or C.finiteInteger(tag.templateWorldZ) ~= anchorZ + entry.z
        or tag.edgeKey ~= nil or tag.axis ~= nil then
        return false
    end

    local nameOk, name = call(object, "getName")
    local spriteOk, sprite = call(object, "getSprite")
    local spriteNameOk, spriteName = call(sprite, "getName")
    local northOk, north = call(object, "getNorth")
    local xOk, x = call(object, "getX")
    local yOk, y = call(object, "getY")
    local zOk, z = call(object, "getZ")
    return nameOk and name == entry.name
        and spriteNameOk and tostring(spriteName) == entry.sprite
        and northOk and north == entry.north
        and xOk and C.finiteInteger(x) == C.finiteInteger(tag.templateWorldX)
        and yOk and C.finiteInteger(y) == C.finiteInteger(tag.templateWorldY)
        and zOk and C.finiteInteger(z) == C.finiteInteger(tag.templateWorldZ)
end

local function hideWardrobe(object)
    if not isTaggedWardrobe(object) then return end

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
    hideWardrobe(object)
end

local function onGridSquareLoaded(square)
    local objectsOk, objects = call(square, "getObjects")
    local sizeOk, size = false, nil
    if objectsOk then sizeOk, size = call(objects, "size") end
    if not sizeOk or type(size) ~= "number" or size < 1 then return end
    for index = 0, size - 1 do
        local objectOk, object = call(objects, "get", index)
        if objectOk and object then hideWardrobe(object) end
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
