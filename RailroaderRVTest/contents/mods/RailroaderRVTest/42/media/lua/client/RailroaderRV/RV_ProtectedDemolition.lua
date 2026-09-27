-- Block demolition only for generation-tagged objects classified as category 3.

local C = require "RailroaderRV/RV_Constants"
local BoundaryClient = require "RailroaderRV/RV_BoundaryClient"
local Template = require "RailroaderRV/RV_Template"
local ProtectionManifest = require "RailroaderRV/RV_ProtectionManifest"
local TemplateGeometry = require "RailroaderRV/RV_TemplateGeometry"
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

-- TEMP diagnostic tracing for the next runtime capture; remove after diagnosis.
local function demolitionTrace(event, detail)
    print("[RailroaderRVTest][DemolitionTrace] event=" .. tostring(event)
        .. " tick=" .. tostring(BoundaryClient._tick or "unknown") .. " "
        .. tostring(detail or ""))
end

local function playerIdentity(character)
    local ok, onlineId = call(character, "getOnlineID")
    if ok then return tostring(onlineId) end
    local playerOk, playerNum = call(character, "getPlayerNum")
    return playerOk and ("playerNum:" .. tostring(playerNum)) or "unknown"
end

local function tagSummary(data, tag)
    data = type(data) == "table" and data or {}
    tag = type(tag) == "table" and tag or {}
    return "root={owner:" .. tostring(data.owner)
        .. ",role:" .. tostring(data.role)
        .. ",rvId:" .. tostring(data.rvId)
        .. ",generation:" .. tostring(data.generation)
        .. ",bitmapVersion:" .. tostring(data.bitmapVersion) .. "}"
        .. " tag={owner:" .. tostring(tag.owner)
        .. ",role:" .. tostring(tag.role)
        .. ",rvId:" .. tostring(tag.rvId)
        .. ",generation:" .. tostring(tag.generation)
        .. ",bitmapVersion:" .. tostring(tag.bitmapVersion)
        .. ",templateIndex:" .. tostring(tag.templateIndex)
        .. ",protectionClass:" .. tostring(tag.protectionClass)
        .. ",templateXYZ:" .. tostring(tag.templateX) .. ","
        .. tostring(tag.templateY) .. "," .. tostring(tag.templateZ)
        .. ",templateClass:" .. tostring(tag.templateClass)
        .. ",templateName:" .. tostring(tag.templateName)
        .. ",templateSprite:" .. tostring(tag.templateSprite)
        .. ",templateDirection:" .. tostring(tag.templateDirection)
        .. ",templateNorth:" .. tostring(tag.templateNorth)
        .. ",anchorXYZ:" .. tostring(tag.templateAnchorX) .. ","
        .. tostring(tag.templateAnchorY) .. "," .. tostring(tag.templateAnchorZ)
        .. ",worldXYZ:" .. tostring(tag.templateWorldX) .. ","
        .. tostring(tag.templateWorldY) .. "," .. tostring(tag.templateWorldZ)
        .. "}"
end

local objectCoordinates
local function objectCoordinateSummary(object)
    local x, y, z = objectCoordinates(object)
    return "squareXYZ=" .. tostring(x) .. "," .. tostring(y) .. ","
        .. tostring(z)
end

local function itemSledgehammerState(item)
    if not item then return "none" end
    local brokenOk, broken = call(item, "isBroken")
    if brokenOk and broken == true then return "broken" end
    local typeOk, itemType = call(item, "getType")
    if typeOk and (itemType == "Sledgehammer"
        or itemType == "Sledgehammer2") then
        return "true:type=" .. tostring(itemType)
    end
    local tagOk, sledgeTag = pcall(function()
        return ItemTag and ItemTag.SLEDGEHAMMER
    end)
    if tagOk and sledgeTag ~= nil then
        local hasTagOk, hasTag = call(item, "hasTag", sledgeTag)
        if hasTagOk and hasTag == true then
            return "true:tag:type=" .. tostring(typeOk and itemType)
        end
    end
    return "false:type=" .. tostring(typeOk and itemType)
end

local function demolitionActionState(action)
    local character = action and action.character
    local item = action and action.item
    local pxOk, px = call(character, "getX")
    local pyOk, py = call(character, "getY")
    local pzOk, pz = call(character, "getZ")
    px, py, pz = pxOk and px or nil, pyOk and py or nil,
        pzOk and pz or nil

    local squareOk, square = call(item, "getSquare")
    local sxOk, sx = call(square, "getX")
    local syOk, sy = call(square, "getY")
    local szOk, sz = call(square, "getZ")
    local objectIndexOk, objectIndex = call(item, "getObjectIndex")
    local dx, dy
    if px ~= nil and sxOk and sx ~= nil then
        dx = math.abs(sx + 0.5 - px)
    end
    if py ~= nil and syOk and sy ~= nil then
        dy = math.abs(sy + 0.5 - py)
    end

    local menu = rawget(_G, "ISBuildMenu")
    local buildMenuCheat = type(menu) == "table" and menu.cheat or nil
    local buildCheatOk, buildCheat = call(character, "isBuildCheat")
    local handOk, primaryHand = call(character, "getPrimaryHandItem")
    local inventoryOk, inventory = call(character, "getInventory")
    local firstEvalOk, inventoryHammer = call(inventory, "getFirstEvalRecurse",
        function(candidate)
            return itemSledgehammerState(candidate):find("true", 1, true) == 1
        end)

    return "playerXYZ=" .. tostring(px) .. "," .. tostring(py) .. ","
        .. tostring(pz) .. " playerPositionOk=" .. tostring(pxOk and pyOk and pzOk)
        .. " actionMaxTime=" .. tostring(action and action.maxTime)
        .. " targetXYZ=" .. tostring(sxOk and sx) .. ","
        .. tostring(syOk and sy) .. "," .. tostring(szOk and sz)
        .. " targetSquareOk=" .. tostring(squareOk and square ~= nil)
        .. " objectIndex=" .. tostring(objectIndexOk and objectIndex)
        .. " objectIndexOk=" .. tostring(objectIndexOk)
        .. " dx=" .. tostring(dx) .. " dy=" .. tostring(dy)
        .. " withinNativeRange=" .. tostring(dx ~= nil and dy ~= nil
            and dx <= 1.6 and dy <= 1.6)
        .. " ISBuildMenu.cheat=" .. tostring(buildMenuCheat)
        .. " characterBuildCheat=" .. tostring(buildCheatOk and buildCheat)
        .. " primaryHand={" .. itemSledgehammerState(handOk and primaryHand)
        .. "} inventoryOk=" .. tostring(inventoryOk)
        .. " inventorySledgehammer={found="
        .. tostring(firstEvalOk and inventoryHammer ~= nil)
        .. ",searchOk=" .. tostring(firstEvalOk) .. ",item="
        .. itemSledgehammerState(firstEvalOk and inventoryHammer) .. "}"
end

local function packValues(...)
    return { n = select("#", ...), ... }
end

local unpackValues = table.unpack or unpack

local function traceTimedActionMethod(action, actionName, methodName)
    if type(action) ~= "table" or type(action[methodName]) ~= "function"
        or action["_rvDemolitionTraceWrapped_" .. methodName] == true then
        return
    end
    local originalMethod = action[methodName]
    action[methodName] = function(self, ...)
        demolitionTrace("action." .. methodName .. ".enter",
            "action=" .. actionName .. " " .. demolitionActionState(self))
        local results = packValues(originalMethod(self, ...))
        local result = results.n > 0 and results[1] or nil
        demolitionTrace("action." .. methodName .. ".return",
            "action=" .. actionName .. " result=" .. tostring(result)
                .. " returnCount=" .. tostring(results.n) .. " "
                .. demolitionActionState(self))
        return unpackValues(results, 1, results.n)
    end
    action["_rvDemolitionTraceWrapped_" .. methodName] = true
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

objectCoordinates = function(object)
    local squareOk, square = call(object, "getSquare")
    local xOk, x = call(square, "getX")
    local yOk, y = call(square, "getY")
    local zOk, z = call(square, "getZ")
    x, y, z = xOk and finiteInteger(x), yOk and finiteInteger(y),
        zOk and finiteInteger(z)
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
                demolitionTrace("door-window.class-match", "class=" .. className
                    .. " result=true " .. objectCoordinateSummary(object))
                return true
            end
        end
        local ok, thumpable = pcall(instanceOf, object, "IsoThumpable")
        if ok and thumpable == true then
            local doorOk, door = call(object, "isDoor")
            local windowOk, window = call(object, "isWindow")
            if doorOk and door == true or windowOk and window == true then
                demolitionTrace("door-window.thumpable-match", "isDoor="
                    .. tostring(doorOk and door) .. " isWindow="
                    .. tostring(windowOk and window) .. " result=true "
                    .. objectCoordinateSummary(object))
                return true
            end
        end
    end
    demolitionTrace("door-window.no-match", "result=false "
        .. objectCoordinateSummary(object))
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
    demolitionTrace("identity.validate.enter", tagSummary(data, tag))
    local function fail(reason)
        demolitionTrace("identity.validate.return", "result=false reason=" .. reason)
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
    local dataGeneration = finiteInteger(data.generation)
    if dataGeneration == nil or dataGeneration < 1 then
        return fail("template-root-generation-invalid")
    end
    if dataGeneration ~= finiteInteger(tag.generation) then
        return fail("template-tag-generation-mismatch")
    end
    if finiteInteger(data.bitmapVersion) ~= C.BITMAP_VERSION then
        return fail("template-root-bitmap-version-mismatch")
    end
    if finiteInteger(tag.bitmapVersion) ~= C.BITMAP_VERSION then
        return fail("template-tag-bitmap-version-mismatch")
    end
    demolitionTrace("identity.validate.return", "result=true rvId="
        .. tostring(data.rvId) .. " generation=" .. tostring(dataGeneration)
        .. " bitmapVersion=" .. tostring(data.bitmapVersion))
    return nil
end

local function rejectInvalidRVData(character, reason)
    print("[RailroaderRVTest] demolition fail-closed reason="
        .. tostring(reason or "unknown"))
    showInvalidRVData(character)
    return true
end

local function objectMatchesStaticIdentity(object, tag, expected)
    demolitionTrace("static-identity.enter", "expected={index="
        .. tostring(expected.templateIndex) .. ",class=" .. tostring(expected.class)
        .. ",name=" .. tostring(expected.name) .. ",sprite="
        .. tostring(expected.sprite) .. ",direction="
        .. tostring(expected.direction) .. ",protectionClass="
        .. tostring(expected.protectionClass) .. "} " .. tagSummary(nil, tag)
        .. " " .. objectCoordinateSummary(object))
    local function fail(reason, detail)
        demolitionTrace("static-identity.return", "result=false reason=" .. reason
            .. " " .. tostring(detail or ""))
        return false
    end
    if not tagMatchesStaticIdentity(tag, expected) then
        return fail("template-tag-static-fields-mismatch")
    end
    local indexOk, objectIndex = call(object, "getObjectIndex")
    local squareOk, square = call(object, "getSquare")
    if not indexOk or finiteInteger(objectIndex) == nil
        or finiteInteger(objectIndex) < 0 or not squareOk or not square then
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
    demolitionTrace("static-identity.return", "result=true index="
        .. tostring(expected.templateIndex))
    return true
end

local function resolveTemplateObject(object, tag)
    local index = finiteInteger(tag and tag.templateIndex)
    if index == nil then return nil, "template-index-unavailable" end
    local indexedObject, indexedAt, indexedProtection =
        TemplateGeometry.lookupObjectByIndex(index, Template, ProtectionManifest)
    if type(indexedObject) ~= "table" or indexedAt ~= index
        or type(indexedProtection) ~= "table" then
        return nil, "template-index-unrecognized"
    end

    local x, y, z = objectCoordinates(object)
    if x == nil then return nil, "object-world-coordinate-unavailable" end
    local anchorX, anchorY, anchorZ = finiteInteger(tag.templateAnchorX),
        finiteInteger(tag.templateAnchorY), finiteInteger(tag.templateAnchorZ)
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
    if type(offset) ~= "table" or offset.z ~= Template.sourceTarget.z then
        return false
    end
    local east = offset.x == C.CAB_MAX_OFFSET_X + 1
        and offset.y >= C.CAB_MIN_OFFSET_Y and offset.y <= C.CAB_MAX_OFFSET_Y
    local south = offset.y == C.CAB_MAX_OFFSET_Y + 1
        and offset.x >= C.CAB_MIN_OFFSET_X and offset.x <= C.CAB_MAX_OFFSET_X
    return east or south
end

local function isCurrentProhibitedObject(object, character)
    demolitionTrace("object-check.enter", "onlineId=" .. playerIdentity(character)
        .. " " .. objectCoordinateSummary(object))
    local dataOk, data = call(object, "getModData")
    if not dataOk or type(data) ~= "table" then
        demolitionTrace("object-check.return", "blocked=false reason=moddata-unavailable"
            .. " dataOk=" .. tostring(dataOk) .. " dataType=" .. type(data))
        return false
    end
    local tag = data.RailroaderRVTest
    demolitionTrace("object-check.moddata", "onlineId=" .. playerIdentity(character)
        .. " " .. tagSummary(data, tag) .. " " .. objectCoordinateSummary(object))
    local owned = data.owner == C.MOD_ID
        or type(tag) == "table" and tag.owner == C.MOD_ID
    if not owned then
        demolitionTrace("object-check.return", "blocked=false reason=not-rv-owned")
        return false
    end

    local hasTemplateMarker = type(tag) == "table"
        and (tag.templateIndex ~= nil or tag.protectionClass ~= nil
            or templateRoles[tag.role] == true)
        or templateRoles[data.role] == true
    if not hasTemplateMarker then
        -- The native generator and other feature-owned objects have their own
        -- lifecycle and do not belong to the captured-template protection set.
        demolitionTrace("object-check.return", "blocked=false reason=no-template-marker")
        return false
    end

    if type(tag) ~= "table" then
        demolitionTrace("object-check.return", "blocked=false reason=template-tag-unavailable")
        return false
    end

    local expected, index, protection, anchor, world, offset =
        resolveTemplateObject(object, tag)
    if not expected then
        demolitionTrace("object-check.return", "blocked=false reason="
            .. tostring(index or "template-object-unrecognized"))
        return false
    end
    if TemplateGeometry.cabContainsWorld(world, anchor, Template) then
        demolitionTrace("object-check.return", "blocked=false reason=cab-coordinate-allowed"
            .. " templateIndex=" .. tostring(index))
        return false
    end
    if cabDoorWindowHost(offset) and isDoorOrWindow(object) then
        demolitionTrace("object-check.return", "blocked=false reason=cab-wall-door-window-allowed"
            .. " templateIndex=" .. tostring(index))
        return false
    end
    if type(protection) ~= "table"
        or protection.protectionClass ~= ProtectionManifest.PROHIBITED then
        demolitionTrace("object-check.return", "blocked=false reason=template-demolition-allowed"
            .. " templateIndex=" .. tostring(index))
        return false
    end
    if not tagMatchesStaticIdentity(tag, expected)
        or not objectMatchesStaticIdentity(object, tag, expected) then
        demolitionTrace("object-check.return", "blocked=false reason=template-identity-unrecognized"
            .. " templateIndex=" .. tostring(index))
        return false
    end
    demolitionTrace("object-check.return", "blocked=true reason=protected-template-object"
        .. " templateIndex=" .. tostring(index))
    return true
end

local function wrapAction(action, actionName)
    if type(action) ~= "table" or type(action.new) ~= "function"
        or action._rvProtectedDemolitionWrapped == true then
        return
    end
    local originalNew = action.new
    action.new = function(self, character, object, ...)
        local clientCall = type(isClient) == "function" and isClient()
        demolitionTrace("action.new.enter", "action=" .. tostring(actionName)
            .. " isClient=" .. tostring(clientCall)
            .. " onlineId=" .. playerIdentity(character) .. " object="
            .. objectCoordinateSummary(object))
        local blocked = clientCall and isCurrentProhibitedObject(object, character)
        demolitionTrace("action.new.decision", "action=" .. tostring(actionName)
            .. " onlineId=" .. playerIdentity(character)
            .. " blocked=" .. tostring(blocked))
        if blocked then
            demolitionTrace("action.new.return", "action=" .. tostring(actionName)
                .. " result=ignoreAction")
            return { ignoreAction = true }
        end
        demolitionTrace("action.new.call-original", "action=" .. tostring(actionName)
            .. " onlineId=" .. playerIdentity(character))
        return originalNew(self, character, object, ...)
    end
    action._rvProtectedDemolitionWrapped = true
end

wrapAction(rawget(_G, "ISDestroyStuffAction"), "ISDestroyStuffAction")
wrapAction(rawget(_G, "ISDismantleAction"), "ISDismantleAction")

local destroyAction = rawget(_G, "ISDestroyStuffAction")
for _, methodName in ipairs({ "isValid", "start", "stop", "perform", "complete" }) do
    traceTimedActionMethod(destroyAction, "ISDestroyStuffAction", methodName)
end
