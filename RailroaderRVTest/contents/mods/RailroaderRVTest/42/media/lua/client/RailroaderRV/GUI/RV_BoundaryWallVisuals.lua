-- Hide only the generation-tagged wooden wall backing used under RV fences.
-- IsoObject.doRender is a local render flag, so apply it after client object
-- sync and again when a saved/reused grid square enters the loaded area.

local C = require "RailroaderRV/Common/RV_Constants"
local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local templateObjects = RoomTemplate.orderedObjects(Template)
local TemplateGeometry = require "RailroaderRV/RoomTemplate/RV_TemplateGeometry"

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
    if type(tag) ~= "table"
        or tag.owner ~= C.MOD_ID
        or type(tag.rvId) ~= "string" or tag.rvId == ""
        or C.finiteInteger(tag.generation) == nil or C.finiteInteger(tag.generation) < 1
        or not boundaryRoles[tag.role] then
        return false
    end
    local templateIndex = C.finiteInteger(tag.templateIndex)
    local expected = templateIndex and templateObjects[templateIndex] or nil
    if not expected then return false end
    -- The boundary role is exactly the set the server assigns to captured shell
    -- edges; every attribute below is re-read from the compiled template entry
    -- named by `templateIndex`, because the tag stores no copy of it.
    if expected.class ~= "IsoThumpable"
        or expected.name ~= "Wooden Wall"
        or not supportWallSprites[expected.sprite]
        or type(expected.state) ~= "table"
        or expected.state.doRender ~= false then
        return false
    end
    if tag.role == "wall-north" or tag.role == "corner-nw" then
        if expected.north ~= true then return false end
    elseif expected.north ~= false then
        return false
    end

    local xOk, x = call(object, "getX")
    local yOk, y = call(object, "getY")
    local zOk, z = call(object, "getZ")
    if not xOk or not yOk or not zOk then return false end
    x, y, z = C.finiteInteger(x), C.finiteInteger(y), C.finiteInteger(z)
    if x == nil or y == nil or z == nil then return false end
    -- The live square derives both anchor and offset; see RV_WardrobeVisuals.
    local anchor = TemplateGeometry.templateAnchorForWorld(x, y, z)
    local offset = type(anchor) == "table" and TemplateGeometry.worldToTemplate(
        { x = x, y = y, z = z }, anchor) or nil
    return type(offset) == "table" and offset.x == expected.x
        and offset.y == expected.y and offset.z == expected.z
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
