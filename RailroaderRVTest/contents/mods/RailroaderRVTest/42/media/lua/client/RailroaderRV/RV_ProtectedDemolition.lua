-- Block demolition only for generation-tagged objects classified as category 3.

local C = require "RailroaderRV/RV_Constants"
local Template = require "RailroaderRV/RV_Template"
local ProtectionManifest = require "RailroaderRV/RV_ProtectionManifest"
require "TimedActions/ISDestroyStuffAction"
require "TimedActions/ISDismantleAction"

local manifestValid, manifestError = ProtectionManifest.validateTemplate(Template)
if not manifestValid then
    error("RailroaderRVTest: demolition protection ledger is invalid: "
        .. tostring(manifestError))
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

local function finiteInteger(value)
    return C.finiteInteger(value)
end

local function tagMatchesStaticIdentity(tag, expected)
    if type(tag) ~= "table" or type(expected) ~= "table"
        or finiteInteger(tag.templateIndex) ~= expected.templateIndex
        or finiteInteger(tag.templateX) ~= expected.x
        or finiteInteger(tag.templateY) ~= expected.y
        or finiteInteger(tag.templateZ) ~= expected.z
        or tag.templateClass ~= expected.class
        or tag.templateName ~= expected.name
        or tag.templateSprite ~= expected.sprite
        or tag.templateDirection ~= expected.direction
        or finiteInteger(tag.protectionClass) ~= expected.protectionClass then
        return false
    end
    if expected.north == "none" then
        return tag.templateNorth == nil
    end
    return tag.templateNorth == expected.north
end

local function objectMatchesStaticIdentity(object, tag, expected)
    if not tagMatchesStaticIdentity(tag, expected) then return false end
    local anchorX, anchorY, anchorZ = finiteInteger(tag.templateAnchorX),
        finiteInteger(tag.templateAnchorY), finiteInteger(tag.templateAnchorZ)
    if anchorX == nil or anchorY == nil or anchorZ == nil
        or finiteInteger(tag.templateWorldX) ~= anchorX + expected.x
        or finiteInteger(tag.templateWorldY) ~= anchorY + expected.y
        or finiteInteger(tag.templateWorldZ) ~= anchorZ + expected.z then
        return false
    end

    local indexOk, objectIndex = call(object, "getObjectIndex")
    local squareOk, square = call(object, "getSquare")
    if not indexOk or finiteInteger(objectIndex) == nil
        or finiteInteger(objectIndex) < 0 or not squareOk or not square then
        return false
    end

    local xOk, x = call(object, "getX")
    local yOk, y = call(object, "getY")
    local zOk, z = call(object, "getZ")
    if not xOk or not yOk or not zOk
        or finiteInteger(x) ~= anchorX + expected.x
        or finiteInteger(y) ~= anchorY + expected.y
        or finiteInteger(z) ~= anchorZ + expected.z then
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
        if not northOk or north ~= expected.north then return false end
    end
    return true
end

local function isCurrentProhibitedObject(object)
    local dataOk, data = call(object, "getModData")
    if not dataOk or type(data) ~= "table" then return false end
    local tag = data.RailroaderRVTest
    local owned = data.owner == C.MOD_ID
        or type(tag) == "table" and tag.owner == C.MOD_ID
    if not owned then return false end

    local role = type(tag) == "table" and tag.role or data.role
    local hasTemplateMarker = type(tag) == "table"
        and (tag.templateIndex ~= nil or tag.protectionClass ~= nil
            or templateRoles[tag.role] == true)
    if not hasTemplateMarker and not templateRoles[role] then
        -- The native generator and other feature-owned objects have their own
        -- lifecycle and do not belong to the captured-template protection set.
        return false
    end

    -- A malformed or stale marker owned by this mod fails closed.
    if type(tag) ~= "table"
        or data.owner ~= C.MOD_ID or tag.owner ~= C.MOD_ID
        or data.role ~= tag.role
        or type(data.rvId) ~= "string" or data.rvId == ""
        or data.rvId ~= tag.rvId
        or finiteInteger(data.generation) == nil
        or finiteInteger(data.generation) < 1
        or finiteInteger(data.generation) ~= finiteInteger(tag.generation)
        or finiteInteger(data.bitmapVersion) ~= C.BITMAP_VERSION
        or finiteInteger(tag.bitmapVersion) ~= C.BITMAP_VERSION then
        return true
    end

    local index = finiteInteger(tag.templateIndex)
    local expected = index and ProtectionManifest.get(index) or nil
    if not expected then
        return true
    end

    -- Free-demolition and restore-only objects must remain dismantleable even
    -- when an open door/window or a damaged object exposes a changed live
    -- sprite. Their category is carried by the generation-time static tag.
    if expected.protectionClass == ProtectionManifest.FREE_DEMOLITION
        or expected.protectionClass == ProtectionManifest.RESTORE_ONLY then
        if not tagMatchesStaticIdentity(tag, expected) then return true end
        return false
    end

    if not objectMatchesStaticIdentity(object, tag, expected) then return true end
    return expected.protectionClass == ProtectionManifest.PROHIBITED
end

local function wrapAction(action)
    if type(action) ~= "table" or type(action.new) ~= "function"
        or action._rvProtectedDemolitionWrapped == true then
        return
    end
    local originalNew = action.new
    action.new = function(self, character, object, ...)
        if type(isClient) == "function" and isClient()
            and isCurrentProhibitedObject(object) then
            return { ignoreAction = true }
        end
        return originalNew(self, character, object, ...)
    end
    action._rvProtectedDemolitionWrapped = true
end

wrapAction(rawget(_G, "ISDestroyStuffAction"))
wrapAction(rawget(_G, "ISDismantleAction"))
