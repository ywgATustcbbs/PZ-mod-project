-- Block demolition only for generation-tagged objects classified as category 3.

local C = require "RailroaderRV/Common/RV_Constants"
require "RailroaderRV/GUI/RV_BoundaryClient"
local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"
local TemplateGeometry = require "RailroaderRV/RoomTemplate/RV_TemplateGeometry"
require "TimedActions/ISDestroyStuffAction"
require "TimedActions/ISDismantleAction"
require "TimedActions/ISTakeGenerator"

local templateRoles = {
    ["captured-template"] = true,
    ["wall-north"] = true,
    ["wall-west"] = true,
    ["corner-nw"] = true,
}

local function call(target, method, ...)
    if target == nil or type(target[method]) ~= "function" then
        return false, nil
    end
    local ok, a, b = pcall(target[method], target, ...)
    if not ok then return false, nil end
    return true, a, b
end

local objectCoordinates

objectCoordinates = function(object)
    local squareOk, square = call(object, "getSquare")
    local xOk, x = call(square, "getX")
    local yOk, y = call(square, "getY")
    local zOk, z = call(square, "getZ")
    x, y, z = xOk and C.finiteInteger(x), yOk and C.finiteInteger(y),
        zOk and C.finiteInteger(z)
    if not squareOk or not square or not x or not y or not z then
        return nil
    end
    return x, y, z
end

local function isDoorOrWindow(object)
    local instanceOf = rawget(_G, "instanceof")
    if type(instanceOf) == "function" then
        for _, className in ipairs({ "IsoDoor", "IsoWindow" }) do
            local ok, result = pcall(instanceOf, object, className)
            if ok and result == true then
                return true
            end
        end
        local ok, thumpable = pcall(instanceOf, object, "IsoThumpable")
        if ok and thumpable == true then
            local doorOk, door = call(object, "isDoor")
            local windowOk, window = call(object, "isWindow")
            if doorOk and door == true or windowOk and window == true then
                return true
            end
        end
    end
    return false
end

local function objectMatchesStaticIdentity(object, expected)
    -- The tag names the template entry and stores no copy of its attributes;
    -- `expected` is that entry, re-read from the compiled template.
    local indexOk, objectIndex = call(object, "getObjectIndex")
    local squareOk, square = call(object, "getSquare")
    if not indexOk or C.finiteInteger(objectIndex) == nil
        or C.finiteInteger(objectIndex) < 0 or not squareOk or not square then
        return false
    end

    local classOk = false
    local instanceOf = rawget(_G, "instanceof")
    if type(instanceOf) == "function" then
        local ok, result = pcall(instanceOf, object, expected.class)
        classOk = ok and result == true
    end
    if not classOk then return false end

    local nameOk, name = call(object, "getName")
    local spriteOk, sprite = call(object, "getSprite")
    local spriteNameOk, spriteName = call(sprite, "getName")
    local directionOk, direction = call(object, "getDir")
    local directions = rawget(_G, "IsoDirections")
    local expectedDirection = directions and directions[expected.direction]
    if not nameOk or name ~= expected.name
        or not spriteNameOk or tostring(spriteName) ~= expected.sprite
        or not directionOk or not expectedDirection or direction ~= expectedDirection then
        return false
    end

    if expected.north ~= "none" then
        local northOk, north = call(object, "getNorth")
        if not northOk or north ~= expected.north then
            return false
        end
    end
    return true
end

local function resolveTemplateObject(object, tag)
    local index = tag.templateIndex
    local template = assert(RoomTemplate.get(tag.templateId),
        "RailroaderRV: tagged template ID is unknown")
    local indexedObject, indexedAt =
        TemplateGeometry.lookupObjectByIndex(index, template)
    assert(type(indexedObject) == "table" and indexedAt == index,
        "RailroaderRV: tagged template index is unknown")

    local x, y, z = objectCoordinates(object)
    if x == nil then return nil, "object-world-coordinate-unavailable" end
    -- The tag stores no anchor; the live square derives both anchor and offset,
    -- and a square from a neighbouring region fails the lookup below.
    local anchor = TemplateGeometry.templateAnchorForWorld(x, y, z)
    if type(anchor) ~= "table" then return nil, "template-anchor-unavailable" end
    local world = { x = x, y = y, z = z }
    local offset = TemplateGeometry.worldToTemplate(world, anchor)
    if type(offset) ~= "table" then return nil, "world-to-template-failed" end

    local matches = TemplateGeometry.lookupObjectsAtWorld(world, anchor,
        template)
    if type(matches) ~= "table" then return nil, "template-world-lookup-failed" end
    for i = 1, #matches do
        local match = matches[i]
        if match.index == index then
            return match.object, match.index, anchor, world, template
        end
    end
    return nil, "template-index-does-not-match-world-coordinate"
end

local function cabDoorWindowHost(world, anchor, template)
    return TemplateGeometry.isBuildCellSideHost(world, anchor, template)
end

local function isCurrentProhibitedObject(object)
    local dataOk, data = call(object, "getModData")
    if not dataOk or type(data) ~= "table" then
        return false
    end
    local tag = data.RailroaderRV
    if tag == nil then
        -- Ordinary world content: no owner, nothing to protect.
        return false
    end
    if type(tag) ~= "table" then return false end
    if tag.owner ~= C.MOD_ID then
        return false
    end
    if tag.role == RoomTemplate.PROXY_ROLES.power
        or tag.role == RoomTemplate.PROXY_ROLES.water then
        return true
    end

    if not templateRoles[tag.role] then return false end

    local expected, index, anchor, world, template =
        resolveTemplateObject(object, tag)
    if not expected then return false end
    if not objectMatchesStaticIdentity(object, expected) then
        return false
    end
    if TemplateGeometry.isBuildable(world, anchor, template) then
        return false
    end
    if cabDoorWindowHost(world, anchor, template) and isDoorOrWindow(object) then
        return false
    end
    if expected.protected ~= true then
        return false
    end
    return true
end

local function actionIsBlocked(object)
    local clientCall = type(isClient) == "function" and isClient()
    return clientCall and isCurrentProhibitedObject(object)
end

local function wrapDestroyAction(action)
    if type(action) ~= "table" or type(action.new) ~= "function"
        or action._rvProtectedDemolitionWrapped == true then
        return
    end
    local originalNew = action.new
    action.new = function(self, character, item, cornerCounter)
        if actionIsBlocked(item) then
            return { ignoreAction = true }
        end
        return originalNew(self, character, item, cornerCounter)
    end
    action._rvProtectedDemolitionWrapped = true
end

local function wrapDismantleAction(action)
    if type(action) ~= "table" or type(action.new) ~= "function"
        or action._rvProtectedDemolitionWrapped == true then
        return
    end
    local originalNew = action.new
    action.new = function(self, character, thumpable)
        if actionIsBlocked(thumpable) then
            return { ignoreAction = true }
        end
        return originalNew(self, character, thumpable)
    end
    action._rvProtectedDemolitionWrapped = true
end

local function wrapTakeGeneratorAction(action)
    if type(action) ~= "table" or type(action.new) ~= "function"
        or action._rvProtectedDemolitionWrapped == true then
        return
    end
    local originalNew = action.new
    action.new = function(self, character, generator)
        if actionIsBlocked(generator) then
            return { ignoreAction = true }
        end
        return originalNew(self, character, generator)
    end
    action._rvProtectedDemolitionWrapped = true
end

wrapDestroyAction(rawget(_G, "ISDestroyStuffAction"))
wrapDismantleAction(rawget(_G, "ISDismantleAction"))
wrapTakeGeneratorAction(rawget(_G, "ISTakeGenerator"))
