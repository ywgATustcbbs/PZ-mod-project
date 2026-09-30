-- Block demolition only for generation-tagged objects classified as category 3.

local C = require "RailroaderRV/Common/RV_Constants"
local BoundaryClient = require "RailroaderRV/GUI/RV_BoundaryClient"
local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"
local Template = RoomTemplate.get(RoomTemplate.TEMPLATE_ID)
local ProtectionManifest = require "RailroaderRV/RoomTemplate/RV_ProtectionManifest"
local TemplateGeometry = require "RailroaderRV/RoomTemplate/RV_TemplateGeometry"
require "TimedActions/ISDestroyStuffAction"
require "TimedActions/ISDismantleAction"

local templateValid, templateError = RoomTemplate.validate(Template)
if not templateValid then
    error("RailroaderRVTest: current demolition RoomTemplate is invalid: "
        .. tostring(templateError))
end

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
local function tagMatchesStaticIdentity(tag, expected, templateIndex,
    protectionClass)
    if type(tag) ~= "table" or type(expected) ~= "table"
        or C.finiteInteger(tag.templateIndex) ~= templateIndex
        or C.finiteInteger(tag.templateX) ~= expected.x
        or C.finiteInteger(tag.templateY) ~= expected.y
        or C.finiteInteger(tag.templateZ) ~= expected.z
        or tag.templateClass ~= expected.class
        or tag.templateName ~= expected.name
        or tag.templateSprite ~= expected.sprite
        or tag.templateDirection ~= expected.direction
        or C.finiteInteger(tag.protectionClass) ~= protectionClass then
        return false
    end
    if expected.north == "none" then
        return tag.templateNorth == nil
    end
    return tag.templateNorth == expected.north
end

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

local function templateTagFailureReason(data, tag)
    local function fail(reason)
        return reason
    end
    if type(tag) ~= "table" then return fail("template-tag-missing") end
    if data.owner ~= C.MOD_ID then return fail("template-root-owner-mismatch") end
    if tag.owner ~= C.MOD_ID then return fail("template-tag-owner-mismatch") end
    if data.role ~= tag.role then return fail("template-role-mismatch") end
    if type(data.rvId) ~= "string" or data.rvId == "" then
        return fail("template-root-rv-id-invalid")
    end
    if data.rvId ~= tag.rvId then return fail("template-tag-rv-id-mismatch") end
    local dataGeneration = C.finiteInteger(data.generation)
    if dataGeneration == nil or dataGeneration < 1 then
        return fail("template-root-generation-invalid")
    end
    if dataGeneration ~= C.finiteInteger(tag.generation) then
        return fail("template-tag-generation-mismatch")
    end
    if C.finiteInteger(data.bitmapVersion) ~= C.BITMAP_VERSION then
        return fail("template-root-bitmap-version-mismatch")
    end
    if C.finiteInteger(tag.bitmapVersion) ~= C.BITMAP_VERSION then
        return fail("template-tag-bitmap-version-mismatch")
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
    templateIndex, protectionClass)
    local function fail(reason, detail)
        return false
    end
    if not tagMatchesStaticIdentity(tag, expected, templateIndex,
        protectionClass) then
        return fail("template-tag-static-fields-mismatch")
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
    local indexedObject, indexedAt, indexedProtection =
        TemplateGeometry.lookupObjectByIndex(index, Template, ProtectionManifest)
    if type(indexedObject) ~= "table" or indexedAt ~= index
        or type(indexedProtection) ~= "table" then
        return nil, "template-index-unrecognized"
    end

    local x, y, z = objectCoordinates(object)
    if x == nil then return nil, "object-world-coordinate-unavailable" end
    local anchorX, anchorY, anchorZ = C.finiteInteger(tag.templateAnchorX),
        C.finiteInteger(tag.templateAnchorY), C.finiteInteger(tag.templateAnchorZ)
    if anchorX == nil or anchorY == nil or anchorZ == nil then
        return nil, "template-anchor-unavailable"
    end
    local anchor = TemplateGeometry.templateAnchorForWorld(x, y, anchorZ)
    if type(anchor) ~= "table" then return nil, "template-anchor-unavailable" end
    if anchor.x ~= anchorX or anchor.y ~= anchorY then
        return nil, "template-anchor-does-not-match-world-region"
    end
    local world = { x = x, y = y, z = z }
    local offset = TemplateGeometry.worldToTemplate(world, anchor)
    if type(offset) ~= "table" then return nil, "world-to-template-failed" end

    local matches = TemplateGeometry.lookupObjectsAtWorld(world, anchor,
        Template, ProtectionManifest)
    if type(matches) ~= "table" then return nil, "template-world-lookup-failed" end
    for i = 1, #matches do
        local match = matches[i]
        if match.index == index then
            return match.object, match.index, match.protection, anchor, world, offset
        end
    end
    return nil, "template-index-does-not-match-world-coordinate"
end

local function cabDoorWindowHost(offset)
    if type(offset) ~= "table" or offset.z ~= Template.metadata.sourceTarget.z then
        return false
    end
    local east = offset.x == C.CAB_MAX_OFFSET_X + 1
        and offset.y >= C.CAB_MIN_OFFSET_Y and offset.y <= C.CAB_MAX_OFFSET_Y
    local south = offset.y == C.CAB_MAX_OFFSET_Y + 1
        and offset.x >= C.CAB_MIN_OFFSET_X and offset.x <= C.CAB_MAX_OFFSET_X
    return east or south
end

local function isCurrentProhibitedObject(object, character)
    local dataOk, data = call(object, "getModData")
    if not dataOk or type(data) ~= "table" then
        return false
    end
    local tag = data.RailroaderRVTest
    local owned = data.owner == C.MOD_ID
        or type(tag) == "table" and tag.owner == C.MOD_ID
    if not owned then
        return false
    end

    local hasTemplateMarker = type(tag) == "table"
        and (tag.templateIndex ~= nil or tag.protectionClass ~= nil
            or templateRoles[tag.role] == true)
        or templateRoles[data.role] == true
    if not hasTemplateMarker then
        -- The native generator and other feature-owned objects have their own
        -- lifecycle and do not belong to the captured-template protection set.
        return false
    end

    if type(tag) ~= "table" then
        return rejectInvalidRVData(character, "template-tag-unavailable")
    end
    local tagFailure = templateTagFailureReason(data, tag)
    if tagFailure then
        return rejectInvalidRVData(character, tagFailure)
    end

    local expected, index, protection, anchor, world, offset =
        resolveTemplateObject(object, tag)
    if not expected then
        return rejectInvalidRVData(character,
            index or "template-object-unrecognized")
    end
    if not tagMatchesStaticIdentity(tag, expected, index,
        protection.protectionClass)
        or not objectMatchesStaticIdentity(object, tag, expected, index,
            protection.protectionClass) then
        return rejectInvalidRVData(character, "template-static-identity-mismatch")
    end
    if TemplateGeometry.cabContainsWorld(world, anchor, Template) then
        return false
    end
    if cabDoorWindowHost(offset) and isDoorOrWindow(object) then
        return false
    end
    if type(protection) ~= "table"
        or protection.protectionClass ~= ProtectionManifest.PROHIBITED then
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
