-- Block demolition only for generation-tagged objects classified as category 3.

local C = require "RailroaderRV/Common/RV_Constants"
local BoundaryClient = require "RailroaderRV/GUI/RV_BoundaryClient"
local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local TemplateGeometry = require "RailroaderRV/RoomTemplate/RV_TemplateGeometry"
require "TimedActions/ISDestroyStuffAction"
require "TimedActions/ISDismantleAction"

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

local function showInvalidRVData(character)
    if not character then return end
    local rv = rawget(_G, "RailroaderRV")
    local utilityClient = rv and rv.UtilityClient
    if utilityClient and type(utilityClient.showInvalidRVData) == "function" then
        local shown = pcall(utilityClient.showInvalidRVData, character)
        if shown then return end
    end
    if type(character.setHaloNote) ~= "function" then return end
    local message = "RV data is invalid. Delete this test save and recreate it."
    if type(getText) == "function" then
        local ok, translated = pcall(getText,
            "UI_RailroaderRVTest_InvalidRVData")
        if ok and type(translated) == "string" and translated ~= ""
            and translated ~= "UI_RailroaderRVTest_InvalidRVData" then
            message = translated
        end
    end
    pcall(function() character:setHaloNote(message, 255, 255, 255, 5000) end)
end

local function templateTagFailureReason(tag)
    if type(tag) ~= "table" then return "template-tag-missing" end
    if tag.owner ~= C.MOD_ID then return "template-tag-owner-mismatch" end
    if type(tag.rvId) ~= "string" or tag.rvId == "" then
        return "template-tag-rv-id-invalid"
    end
    local generation = C.finiteInteger(tag.generation)
    if generation == nil or generation < 1 then
        return "template-tag-generation-invalid"
    end
    return nil
end

local function rejectInvalidRVData(character, reason)
    print("[RailroaderRVTest] demolition fail-closed reason="
        .. tostring(reason or "unknown"))
    showInvalidRVData(character)
    return true
end

local function objectMatchesStaticIdentity(object, tag, expected,
    templateIndex)
    local function fail(reason, detail)
        return false
    end
    -- The tag names the template entry and stores no copy of its attributes;
    -- `expected` is that entry, re-read from the compiled template.
    if type(tag) ~= "table"
        or C.finiteInteger(tag.templateIndex) ~= templateIndex then
        return fail("template-tag-index-mismatch")
    end
    local indexOk, objectIndex = call(object, "getObjectIndex")
    local squareOk, square = call(object, "getSquare")
    if not indexOk or C.finiteInteger(objectIndex) == nil
        or C.finiteInteger(objectIndex) < 0 or not squareOk or not square then
        return fail("object-index-or-square-invalid", "objectIndex="
            .. tostring(objectIndex) .. " indexOk=" .. tostring(indexOk)
            .. " squareOk=" .. tostring(squareOk) .. " square=" .. tostring(square))
    end

    local classOk = false
    local instanceOf = rawget(_G, "instanceof")
    if type(instanceOf) == "function" then
        local ok, result = pcall(instanceOf, object, expected.class)
        classOk = ok and result == true
    end
    if not classOk then return fail("object-class-mismatch",
        "expectedClass=" .. tostring(expected.class)) end

    local nameOk, name = call(object, "getName")
    local spriteOk, sprite = call(object, "getSprite")
    local spriteNameOk, spriteName = call(sprite, "getName")
    local directionOk, direction = call(object, "getDir")
    local directions = rawget(_G, "IsoDirections")
    local expectedDirection = directions and directions[expected.direction]
    if not nameOk or name ~= expected.name
        or not spriteNameOk or tostring(spriteName) ~= expected.sprite
        or not directionOk or not expectedDirection or direction ~= expectedDirection then
        return fail("object-live-identity-mismatch", "nameOk="
            .. tostring(nameOk) .. " name=" .. tostring(name)
            .. " spriteNameOk=" .. tostring(spriteNameOk) .. " sprite="
            .. tostring(spriteName) .. " directionOk=" .. tostring(directionOk)
            .. " direction=" .. tostring(direction) .. " expectedDirection="
            .. tostring(expectedDirection))
    end

    if expected.north ~= "none" then
        local northOk, north = call(object, "getNorth")
        if not northOk or north ~= expected.north then
            return fail("object-north-mismatch", "northOk=" .. tostring(northOk)
                .. " north=" .. tostring(north) .. " expected="
                .. tostring(expected.north))
        end
    end
    return true
end

local function resolveTemplateObject(object, tag)
    local index = C.finiteInteger(tag and tag.templateIndex)
    if index == nil then return nil, "template-index-unavailable" end
    local indexedObject, indexedAt =
        TemplateGeometry.lookupObjectByIndex(index, Template)
    if type(indexedObject) ~= "table" or indexedAt ~= index then
        return nil, "template-index-unrecognized"
    end

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
        Template)
    if type(matches) ~= "table" then return nil, "template-world-lookup-failed" end
    for i = 1, #matches do
        local match = matches[i]
        if match.index == index then
            return match.object, match.index, anchor, world, offset
        end
    end
    return nil, "template-index-does-not-match-world-coordinate"
end

local function cabDoorWindowHost(world, anchor)
    return TemplateGeometry.isBuildCellSideHost(world, anchor, Template)
end

local function isCurrentProhibitedObject(object, character)
    local dataOk, data = call(object, "getModData")
    if not dataOk or type(data) ~= "table" then
        return false
    end
    local tag = data.RailroaderRVTest
    if tag == nil then
        -- Ordinary world content: no owner, nothing to protect.
        return false
    end
    if type(tag) ~= "table" then
        return rejectInvalidRVData(character, "template-tag-unavailable")
    end
    if tag.owner ~= C.MOD_ID then
        return false
    end

    local hasTemplateMarker = tag.templateIndex ~= nil
        or templateRoles[tag.role] == true
    if not hasTemplateMarker then
        -- The native generator and other feature-owned objects have their own
        -- lifecycle and do not belong to the captured-template protection set.
        return false
    end

    local tagFailure = templateTagFailureReason(tag)
    if tagFailure then
        return rejectInvalidRVData(character, tagFailure)
    end

    local expected, index, anchor, world =
        resolveTemplateObject(object, tag)
    if not expected then
        return rejectInvalidRVData(character,
            index or "template-object-unrecognized")
    end
    if not objectMatchesStaticIdentity(object, tag, expected, index) then
        return rejectInvalidRVData(character, "template-static-identity-mismatch")
    end
    if TemplateGeometry.cabContainsWorld(world, anchor, Template) then
        return false
    end
    if cabDoorWindowHost(world, anchor) and isDoorOrWindow(object) then
        return false
    end
    if expected.protected ~= true then
        return false
    end
    return true
end

local function actionIsBlocked(actionName, character, object)
    local clientCall = type(isClient) == "function" and isClient()
    local blocked = clientCall and isCurrentProhibitedObject(object, character)
    if blocked then
        return true
    end
    return false
end

local function wrapDestroyAction(action)
    if type(action) ~= "table" or type(action.new) ~= "function"
        or action._rvProtectedDemolitionWrapped == true then
        return
    end
    local originalNew = action.new
    action.new = function(self, character, item, cornerCounter)
        if actionIsBlocked("ISDestroyStuffAction", character, item) then
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
        if actionIsBlocked("ISDismantleAction", character, thumpable) then
            return { ignoreAction = true }
        end
        return originalNew(self, character, thumpable)
    end
    action._rvProtectedDemolitionWrapped = true
end

wrapDestroyAction(rawget(_G, "ISDestroyStuffAction"))
wrapDismantleAction(rawget(_G, "ISDismantleAction"))
