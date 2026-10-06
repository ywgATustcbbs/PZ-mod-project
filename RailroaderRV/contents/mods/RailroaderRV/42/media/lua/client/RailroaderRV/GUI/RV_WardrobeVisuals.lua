-- Hide only the four generation-tagged wardrobe tiles placed west of the cab.
-- Keep the IsoThumpable object itself in the square so its collision and the
-- existing demolition protection/template protection repair continue to work.

local C = require "RailroaderRV/Common/RV_Constants"
local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local templateObjects = RoomTemplate.orderedObjects(Template)
local TemplateGeometry = require "RailroaderRV/RoomTemplate/RV_TemplateGeometry"

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
    print("[RailroaderRV] RV wardrobe visual update failed: "
        .. tostring(message))
end

local function isWardrobeTemplateEntry(entry)
    return type(entry) == "table"
        and entry.class == "IsoThumpable"
        and entry.name == "Dark Fancy Wardrobe"
        and entry.x == -5 and entry.z == 0
        and wardrobeSpritesByY[entry.y] == entry.sprite
        and entry.north == true and entry.direction == "N"
        and entry.protected == true
        and type(entry.state) == "table" and entry.state.doRender == false
end

local function isTaggedWardrobe(object)
    local dataOk, data = call(object, "getModData")
    if not dataOk or type(data) ~= "table" then return false end

    local tag = data.RailroaderRV
    if type(tag) ~= "table"
        or tag.owner ~= C.MOD_ID
        or tag.role ~= "captured-template" then
        return false
    end

    local templateIndex = tag.templateIndex
    local entry = assert(templateObjects[templateIndex],
        "RailroaderRV: tagged wardrobe template index is unknown")
    -- Every template attribute comes from the compiled entry named by
    -- `templateIndex`; the tag stores no copy of them.
    if not isWardrobeTemplateEntry(entry)
        or tag.edgeKey ~= nil then
        return false
    end

    local nameOk, name = call(object, "getName")
    local spriteOk, sprite = call(object, "getSprite")
    local spriteNameOk, spriteName = call(sprite, "getName")
    local northOk, north = call(object, "getNorth")
    local xOk, x = call(object, "getX")
    local yOk, y = call(object, "getY")
    local zOk, z = call(object, "getZ")
    if not spriteOk or not xOk or not yOk or not zOk then return false end
    x, y, z = C.finiteInteger(x), C.finiteInteger(y), C.finiteInteger(z)
    if x == nil or y == nil or z == nil then return false end
    -- The tag stores no geometry: the 100x100 RV region is centred on its
    -- template anchor, so the live square derives both anchor and offset.
    local anchor = TemplateGeometry.templateAnchorForWorld(x, y, z)
    local offset = type(anchor) == "table" and TemplateGeometry.worldToTemplate(
        { x = x, y = y, z = z }, anchor) or nil
    if type(offset) ~= "table" or offset.x ~= entry.x or offset.y ~= entry.y
        or offset.z ~= entry.z then
        return false
    end
    return nameOk and name == entry.name
        and spriteNameOk and tostring(spriteName) == entry.sprite
        and northOk and north == entry.north
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
