-- RV_Server: WorldObjects responsibilities.
return function(ctx)
local OWNER = ctx.OWNER
local Constants = ctx.Constants
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local ProtectionManifest = require("RailroaderRV/RV_ProtectionManifest")

local function applyIntegerState(object, state, key, setter, getter)
    local expected = state[key]
    if expected == nil then return end
    if type(expected) ~= "number" or math.floor(expected) ~= expected
        or (setter and not ServerUtil.callSucceeded(object, setter, expected)) then
        error("RailroaderRVTest: captured object " .. key .. " could not be applied")
    end
    local readOk, actual = ServerUtil.invoke(object, getter)
    if not readOk or ServerUtil.toNumber(actual) ~= expected then
        error("RailroaderRVTest: captured object " .. key .. " did not match")
    end
end

local function applyBooleanState(object, state, key, setter, getter)
    local expected = state[key]
    if expected == nil then return end
    if type(expected) ~= "boolean"
        or not ServerUtil.callSucceeded(object, setter, expected) then
        error("RailroaderRVTest: captured object " .. key .. " could not be applied")
    end
    local readOk, actual = ServerUtil.invoke(object, getter)
    if not readOk or actual ~= expected then
        error("RailroaderRVTest: captured object " .. key .. " did not match")
    end
end

local function capturedObjectContext(entry)
    return " templateIndex=" .. tostring(entry.templateIndex)
        .. " class=" .. tostring(entry.class)
        .. " name=" .. tostring(entry.name)
        .. " sprite=" .. tostring(entry.sprite)
        .. " world=" .. tostring(entry.x) .. "," .. tostring(entry.y)
        .. "," .. tostring(entry.z)
end

local function ensureCapturedHiddenSprite(entry)
    if entry.sprite ~= Constants.UTILITY_HIDDEN_SPRITE_KEY then return end
    local utilitySprite = require("RailroaderRV/RV_UtilitySprite")
    local ready, expectedSprite, reason = utilitySprite.ensureHiddenSprites()
    if not ready or not expectedSprite then
        error("RailroaderRVTest: captured hidden blocker sprite is unavailable;"
            .. capturedObjectContext(entry) .. " reason=" .. tostring(reason))
    end
    return expectedSprite
end

local function bindCapturedHiddenSprite(object, entry, expectedSprite)
    if entry.sprite ~= Constants.UTILITY_HIDDEN_SPRITE_KEY then return end
    if not expectedSprite then
        error("RailroaderRVTest: captured hidden blocker sprite was not registered before construction;"
            .. capturedObjectContext(entry))
    end
    if not ServerUtil.callSucceeded(object, "setSpriteFromName", entry.sprite) then
        error("RailroaderRVTest: captured hidden blocker sprite bind failed;"
            .. capturedObjectContext(entry))
    end
    local spriteOk, actualSprite = ServerUtil.invoke(object, "getSprite")
    local nameOk, actualName = ServerUtil.invoke(actualSprite, "getName")
    local objectNameOk, actualObjectName = ServerUtil.invoke(object, "getSpriteName")
    if not spriteOk or actualSprite ~= expectedSprite
        or not nameOk or tostring(actualName) ~= entry.sprite
        or not objectNameOk or tostring(actualObjectName) ~= entry.sprite then
        error("RailroaderRVTest: captured hidden blocker sprite bind did not match;"
            .. capturedObjectContext(entry)
            .. " expectedSprite=" .. tostring(entry.sprite)
            .. " actualSprite=" .. tostring(actualName)
            .. " objectSpriteName=" .. tostring(actualObjectName))
    end
end

local function applyCapturedHealthState(object, entry)
    local setter = "setHealth"
    if entry.class == "IsoWindow" then
        -- IsoWindow exposes a health getter but no setter; retain the strict
        -- read-back check against the constructor-provided template value.
        setter = nil
    end
    applyIntegerState(object, entry.state, "health", setter, "getHealth")
end

local function applyCapturedIdentityAndState(object, entry, deferHealth)
    if type(entry) ~= "table" or type(entry.templateIndex) ~= "number"
        or type(entry.class) ~= "string"
        or type(entry.name) ~= "string" or type(entry.sprite) ~= "string"
        or entry.direction ~= "N" or type(entry.state) ~= "table" then
        error("RailroaderRVTest: captured object identity is malformed")
    end
    if not ServerUtil.classInstance(object, entry.class) then
        error("RailroaderRVTest: captured object class did not match")
    end
    if entry.class == "IsoThumpable" or entry.class == "IsoWindow"
        or entry.class == "IsoDoor" then
        if type(entry.north) ~= "boolean" then
            error("RailroaderRVTest: captured object north state is malformed")
        end
    elseif entry.north ~= nil then
        error("RailroaderRVTest: captured object has an unexpected north state")
    end
    local stateKeys = { health = true, maxHealth = true, hoppable = true,
        locked = true, canPassThrough = true, blockAllTheSquare = true,
        doRender = true, thumpable = true }
    for key in pairs(entry.state) do
        if not stateKeys[key] then
            error("RailroaderRVTest: captured object state has an unsupported field")
        end
    end
    if not ServerUtil.callSucceeded(object, "setName", entry.name) then
        error("RailroaderRVTest: captured object name could not be applied")
    end
    local directions = rawget(_G, "IsoDirections")
    local expectedDirection = directions and directions[entry.direction]
    if not expectedDirection
        or not ServerUtil.callSucceeded(object, "setDir", expectedDirection) then
        error("RailroaderRVTest: captured object direction could not be applied")
    end
    if entry.north ~= nil then
        local northOk, actualNorth = ServerUtil.invoke(object, "getNorth")
        if not northOk or actualNorth ~= entry.north then
            error("RailroaderRVTest: captured object north state did not match")
        end
    end

    applyIntegerState(object, entry.state, "maxHealth", "setMaxHealth",
        "getMaxHealth")
    if not deferHealth then applyCapturedHealthState(object, entry) end

    if entry.state.hoppable ~= nil then
        if type(entry.state.hoppable) ~= "boolean" then
            error("RailroaderRVTest: captured object hoppable state is malformed")
        end
        -- Plain captured IsoObject floors, captured IsoWindows, and captured
        -- IsoLightSwitches have no hoppable setter path in this template. Keep
        -- their recorded false state strict through the getter below.
        local setter = "setIsHoppable"
        local applied = (entry.class == "IsoObject"
            or entry.class == "IsoWindow"
            or entry.class == "IsoLightSwitch") and entry.state.hoppable == false
        if not applied then
            applied = ServerUtil.callSucceeded(object, "setIsHoppable",
                entry.state.hoppable)
        end
        if not applied then
            setter = "setHoppable"
            applied = ServerUtil.callSucceeded(object, "setHoppable",
                entry.state.hoppable)
        end
        if not applied then
            error("RailroaderRVTest: captured object hoppable state could not be applied;"
                .. capturedObjectContext(entry) .. " setter=" .. setter
                .. " expected=" .. tostring(entry.state.hoppable))
        end
        local readOk, actual = ServerUtil.invoke(object, "isHoppable")
        local getter = "isHoppable"
        if not readOk then
            getter = "getIsHoppable"
            readOk, actual = ServerUtil.invoke(object, "getIsHoppable")
        end
        if not readOk or actual ~= entry.state.hoppable then
            error("RailroaderRVTest: captured object hoppable state did not match;"
                .. capturedObjectContext(entry) .. " setter=" .. setter
                .. " getter=" .. getter .. " expected="
                .. tostring(entry.state.hoppable) .. " actual="
                .. (readOk and tostring(actual) or "<unreadable>"))
        end
    end

    applyBooleanState(object, entry.state, "canPassThrough",
        "setCanPassThrough", "isCanPassThrough")
    applyBooleanState(object, entry.state, "blockAllTheSquare",
        "setBlockAllTheSquare", "isBlockAllTheSquare")
    applyBooleanState(object, entry.state, "doRender", "setDoRender",
        "getDoRender")
    applyBooleanState(object, entry.state, "thumpable", "setIsThumpable",
        "isThumpable")

    if entry.state.locked ~= nil then
        if type(entry.state.locked) ~= "boolean" or entry.state.locked == true then
            error("RailroaderRVTest: captured locked state is unsupported")
        end
        local lockSetterOk = ServerUtil.callSucceeded(object, "setIsLocked", false)
        local observedLockState = false
        local hasLockState = false
        for _, getter in ipairs({ "isLocked", "getIsLocked" }) do
            local readOk, actual = ServerUtil.invoke(object, getter)
            if readOk then
                hasLockState = true
                observedLockState = observedLockState or actual == true
            end
        end
        local padlockOk, padlocked = ServerUtil.invoke(object, "isLockedByPadlock")
        if padlockOk then
            hasLockState = true
            observedLockState = observedLockState or padlocked == true
        end
        local codeOk, lockCode = ServerUtil.invoke(object, "getLockedByCode")
        if codeOk then
            hasLockState = true
            observedLockState = observedLockState
                or (ServerUtil.toNumber(lockCode) or 0) > 0
        end
        if not hasLockState and not lockSetterOk then
            error("RailroaderRVTest: captured unlocked state cannot be verified")
        end
        if observedLockState then
            error("RailroaderRVTest: captured object remained locked")
        end
    end

    local nameOk, actualName = ServerUtil.invoke(object, "getName")
    local dirOk, actualDirection = ServerUtil.invoke(object, "getDir")
    local spriteName = ServerWorld.getSpriteName(object)
    local nameMatches = nameOk and tostring(actualName) == entry.name
    local directionMatches = dirOk and actualDirection == expectedDirection
    local spriteMatches = tostring(spriteName) == entry.sprite
    if not nameMatches or not directionMatches or not spriteMatches then
        error("RailroaderRVTest: captured object identity read-back failed;"
            .. capturedObjectContext(entry)
            .. " expectedName=" .. tostring(entry.name)
            .. " actualName=" .. tostring(actualName)
            .. " nameReadable=" .. tostring(nameOk)
            .. " expectedDirection=" .. tostring(expectedDirection)
            .. " actualDirection=" .. tostring(actualDirection)
            .. " directionReadable=" .. tostring(dirOk)
            .. " expectedSprite=" .. tostring(entry.sprite)
            .. " actualSprite=" .. tostring(spriteName))
    end
end

local function capturedTagData(entry, edge, tagContext)
    if not ProtectionManifest.matchesCapturedEntry(entry.templateIndex, entry) then
        error("RailroaderRVTest: captured protection identity is incomplete at index "
            .. tostring(entry.templateIndex))
    end
    local protection = ProtectionManifest.get(entry.templateIndex)
    local anchorX = ServerUtil.requiredInteger(tagContext and tagContext.anchorX,
        "captured tag anchorX")
    local anchorY = ServerUtil.requiredInteger(tagContext and tagContext.anchorY,
        "captured tag anchorY")
    local anchorZ = ServerUtil.requiredInteger(tagContext and tagContext.anchorZ,
        "captured tag anchorZ")
    if entry.x ~= anchorX + protection.x or entry.y ~= anchorY + protection.y
        or entry.z ~= anchorZ + protection.z then
        error("RailroaderRVTest: captured tag coordinates differ from static ledger at index "
            .. tostring(entry.templateIndex))
    end
    local result = {
        templateIndex = entry.templateIndex,
        templateX = protection.x,
        templateY = protection.y,
        templateZ = protection.z,
        templateAnchorX = anchorX,
        templateAnchorY = anchorY,
        templateAnchorZ = anchorZ,
        templateWorldX = entry.x,
        templateWorldY = entry.y,
        templateWorldZ = entry.z,
        templateClass = entry.class,
        templateName = entry.name,
        templateSprite = entry.sprite,
        templateNorth = entry.north,
        protectionClass = protection.protectionClass,
        templateDirection = entry.direction,
    }
    if edge then
        result.edgeKey = edge.edgeKey
        result.axis = edge.axis
    end
    if type(entry.state) == "table" and entry.class == "IsoThumpable"
        and entry.name == "Wooden Wall" and entry.state.doRender == false
        and type(edge) == "table"
        and (edge.role == "wall-north" or edge.role == "wall-west"
            or edge.role == "corner-nw") then
        result.templateBoundarySupportWall = true
    end
    return result
end

local function isVisualCornerTemplateEntry(entry)
    return type(entry) == "table"
        and entry.class == "IsoObject"
        and entry.name == "Wooden Wall"
        and entry.sprite == "walls_interior_house_02_35"
end

local function configureCapturedDoorFrame(object, entry)
    if type(entry) ~= "table" or entry.class ~= "IsoThumpable"
        or entry.name ~= "Wooden Door Frame"
        or entry.sprite ~= "walls_interior_house_02_43"
        or entry.north ~= true or entry.direction ~= "N" then
        error("RailroaderRVTest: captured door frame identity is invalid")
    end
    if not ServerUtil.callSucceeded(object, "setCanPassThrough", true)
        or not ServerUtil.callSucceeded(object, "setIsDoorFrame", true)
        or not ServerUtil.callSucceeded(object, "setIsThumpable", false) then
        error("RailroaderRVTest: captured door frame pass-through state failed")
    end
end

local function ensureRoofSquare(cell, x, y, z)
    -- B42's player-building path creates a missing upper square with the
    -- IsoGridSquare constructor, then connects it to the cell.  Keep this
    -- operation idempotent so a retry reuses an existing square (including a
    -- square left empty after a failed addFloor) instead of creating a
    -- duplicate/unconnected object.
    local square = ServerWorld.getSquare(cell, x, y, z)
    if square then
        return square
    end

    local cls = rawget(_G, "IsoGridSquare")
    local constructed, created = ServerUtil.invokeClass(cls, {
        -- Match official BuildRecipeCode/buildRecipeCode.lua exactly:
        -- IsoGridSquare.new(cell, nil, x, y, z), followed by ConnectNewSquare.
        { cell, nil, x, y, z },
    })
    if constructed then
        if not ServerUtil.callSucceeded(cell, "ConnectNewSquare", created, false) then
            error("RailroaderRVTest: unable to connect roof square")
        end
    else
        -- Keep the official DebugIsoRegionsEdit construction API as a narrow
        -- Alternate runtime API path for bindings that do not expose the class.
        -- constructor.  This method connects the square itself.
        local createdOk, fallback = ServerUtil.invoke(cell, "createNewGridSquare", x, y, z, true)
        if not createdOk or not fallback then
            error("RailroaderRVTest: unable to construct roof square")
        end
    end

    local connected = ServerWorld.getSquare(cell, x, y, z)
    if not connected then
        error("RailroaderRVTest: roof square construction was not observable")
    end
    return connected
end

local function createFloor(square, sprite, generation, role, tagContext, capturedEntry, edge)
    if not sprite then
        error("RailroaderRVTest: floor sprite is not configured")
    end
    local ok, floor = ServerUtil.invoke(square, "getFloor")
    local hadFloor = ok and floor ~= nil
    local previousSprite
    local createdByGeneration = not hadFloor
    if hadFloor then
        previousSprite = ServerWorld.getSpriteName(floor)
        if not previousSprite then
            error("RailroaderRVTest: existing floor has no sprite")
        end
        -- Metal and wood are two phases over the same object.  Keep the first
        -- pre-generation sprite so rollback can restore the original floor;
        -- the wood/roof stages never overwrite this initial snapshot.
        local existingData = ServerWorld.objectModData(floor)
        local existingTag = existingData and existingData.RailroaderRVTest or nil
        if type(existingTag) == "table" and existingTag.owner == OWNER
            and existingTag.previousSprite
            and ServerUtil.toNumber(existingTag.generation) == ServerUtil.toNumber(generation) then
            previousSprite = tostring(existingTag.previousSprite)
            createdByGeneration = existingTag.createdByGeneration == true
        end
    end
    if not ok or not floor then
        local added = ServerUtil.callSucceeded(square, "addFloor", sprite)
        if not added then
            error("RailroaderRVTest: addFloor failed")
        end
        ok, floor = ServerUtil.invoke(square, "getFloor")
    else
        local spriteObject = select(2, ServerUtil.callGlobal("getSprite", sprite))
        if spriteObject then
            if not ServerUtil.callSucceeded(floor, "setSprite", spriteObject) then
                error("RailroaderRVTest: floor sprite update failed")
            end
        else
            if not ServerUtil.callSucceeded(floor, "setSprite", sprite) then
                error("RailroaderRVTest: floor sprite update failed")
            end
        end
    end
    if not floor then
        error("RailroaderRVTest: floor object was not created")
    end
    if capturedEntry then
        applyCapturedIdentityAndState(floor, capturedEntry)
    end
    local floorTagData = capturedEntry
        and capturedTagData(capturedEntry, edge, tagContext) or {}
    floorTagData.previousSprite = previousSprite
    floorTagData.createdByGeneration = createdByGeneration
    local tagged, tagError = pcall(ServerWorld.tagObject, floor, generation, role,
        ServerWorld.withTagIdentity(floorTagData, tagContext))
    if not tagged then
        local removed, removeError = pcall(ServerWorld.removeGenericObject, square, floor)
        if not removed then
            error(tostring(tagError) .. " (untagged floor cleanup failed: "
                .. tostring(removeError) .. ")")
        end
        error(tagError)
    end
    if hadFloor then
        -- This floor is already present in the client object map.  Send the
        -- two independent deltas explicitly: the replacement sprite and the
        -- generation snapshot/tag.  Neither delta is valid for a new object.
        if not ServerUtil.callSucceeded(floor, "transmitUpdatedSpriteToClients") then
            error("RailroaderRVTest: existing floor sprite transmission failed")
        end
        if not ServerUtil.callSucceeded(floor, "transmitModData") then
            error("RailroaderRVTest: existing floor modData transmission failed")
        end
    else
        -- A newly-added floor is absent from the client object map, so its
        -- complete packet is the sole initial object broadcast.
        if not ServerUtil.callSucceeded(floor, "transmitCompleteItemToClients") then
            error("RailroaderRVTest: new floor client transmission failed")
        end
    end
    ServerWorld.recalcSquare(square)
    return floor
end

local function addSpecialObject(square, object)
    -- Some native constructors attach their object before this helper runs.
    -- Add only when needed, then require an observable square-list index.
    local indexOk, index = ServerUtil.invoke(object, "getObjectIndex")
    local indexNumber = ServerUtil.toNumber(index)
    local attached = indexOk and indexNumber and indexNumber >= 0
    local ok = attached
    if not attached then
        ok = ServerUtil.callSucceeded(square, "AddSpecialObject", object)
    end
    if not ok then
        error("RailroaderRVTest: unable to attach object to square")
    end
    local indexOk, attachedIndex = ServerUtil.invoke(object, "getObjectIndex")
    local attachedNumber = ServerUtil.toNumber(attachedIndex)
    if not indexOk or not attachedNumber or attachedNumber < 0 then
        error("RailroaderRVTest: object attachment was not observable")
    end
    -- The caller must transmit exactly once, after all object-specific state is
    -- final. Sending here would duplicate the complete packet for the same
    -- object index.
    ServerWorld.recalcSquare(square)
end

local function createWall(cell, square, sprite, north, generation, role, extraData,
    tagContext)
    local cls = rawget(_G, "IsoThumpable")
    local ok, wall = ServerUtil.invokeClass(cls, {
        -- B42.20: IsoThumpable(IsoCell, IsoGridSquare, String, boolean,
        -- KahluaTable).  nil is the ordinary no-build-info table.
        { cell, square, sprite, north, nil },
    })
    if not ok then
        error("RailroaderRVTest: IsoThumpable construction failed")
    end
    if not ServerUtil.callSucceeded(wall, "setIsThumpable", true) then
        error("RailroaderRVTest: wall initial state failed")
    end
    ServerWorld.tagObject(wall, generation, role, ServerWorld.withTagIdentity(extraData, tagContext))
    addSpecialObject(square, wall)
    if not ServerUtil.callSucceeded(wall, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: wall client transmission failed")
    end
    return wall
end

local function validatePlayerLightSprite(spriteObject, spriteName)
    local expectedSprite = Constants.SPRITES.wallLamp.sprite
    if tostring(spriteName) ~= tostring(expectedSprite) then
        error("RailroaderRVTest: player light must be BuildCraft custom-house switch 1: "
            .. tostring(expectedSprite))
    end
    if not spriteObject then
        error("RailroaderRVTest: light sprite is unavailable: " .. tostring(spriteName))
    end
    local propertiesOk, properties = ServerUtil.invoke(spriteObject, "getProperties")
    if not propertiesOk or not properties then
        error("RailroaderRVTest: light sprite has no property container: " .. tostring(spriteName))
    end

    -- BuildingCraft_Light_17 is the dependency's Custom House Light Switch 1.
    -- Requiring the tile metadata that IsoLightSwitch/addLightSourceFromSprite
    -- consumes prevents a system-house or decorative tile from silently
    -- creating a switch without the player-built-house semantics.
    local lightProperties = Constants.LIGHT_PROPERTIES
    if type(lightProperties) ~= "table" then
        error("RailroaderRVTest: light property contract is unavailable")
    end

    -- PropertyContainer stores attachedW in its IsoFlagType bitset.  Passing
    -- the literal string to has() checks the ordinary key/value map instead,
    -- so a valid player-built wall lamp is falsely rejected.
    local flagTypes = rawget(_G, "IsoFlagType")
    local attachedFlag = flagTypes and flagTypes[lightProperties.attachedFlag]
    if not attachedFlag then
        error("RailroaderRVTest: IsoFlagType is unavailable for player light flag "
            .. tostring(lightProperties.attachedFlag))
    end
    local attachedOk, hasAttached = ServerUtil.invoke(properties, "has", attachedFlag)
    if not attachedOk or hasAttached ~= true then
        error("RailroaderRVTest: player light sprite " .. tostring(spriteName)
            .. " is missing flag " .. tostring(lightProperties.attachedFlag))
    end

    -- `lightswitch` is an IsoObjectType enum, not an ordinary tile property.
    -- The tile definition may expose a same-named metadata entry, but the
    -- engine's moveable-light path decides the object class from getType().
    local objectTypes = rawget(_G, "IsoObjectType")
    local expectedType = objectTypes and objectTypes.lightswitch
    if not expectedType then
        error("RailroaderRVTest: IsoObjectType is unavailable for player light type "
            .. tostring(lightProperties.objectType))
    end
    local typeOk, spriteType = ServerUtil.invoke(spriteObject, "getType")
    if not typeOk or spriteType ~= expectedType then
        error("RailroaderRVTest: player light sprite " .. tostring(spriteName)
            .. " is not IsoObjectType." .. tostring(lightProperties.objectType))
    end

    local required = {
        lightProperties.movable,
        lightProperties.radius,
        lightProperties.red,
        lightProperties.green,
        lightProperties.blue,
    }
    for i = 1, #required do
        local propertyName = required[i]
        local hasOk, hasProperty = ServerUtil.invoke(properties, "has", propertyName)
        if not hasOk or hasProperty ~= true then
            error("RailroaderRVTest: player light sprite " .. tostring(spriteName)
                .. " is missing property " .. tostring(propertyName))
        end
    end

    local expectedMetadata = {
        { lightProperties.customName, lightProperties.customNameValue },
        { lightProperties.groupName, lightProperties.groupNameValue },
        { lightProperties.moveType, lightProperties.moveTypeValue },
    }
    for i = 1, #expectedMetadata do
        local propertyName, expectedValue = expectedMetadata[i][1], expectedMetadata[i][2]
        local valueOk, value = ServerUtil.invoke(properties, "get", propertyName)
        if not valueOk or tostring(value) ~= tostring(expectedValue) then
            error("RailroaderRVTest: player light sprite " .. tostring(spriteName)
                .. " has unexpected " .. tostring(propertyName) .. " (expected "
                .. tostring(expectedValue) .. ")")
        end
    end
    for _, propertyName in ipairs({ lightProperties.radius, lightProperties.red,
        lightProperties.green, lightProperties.blue }) do
        local valueOk, value = ServerUtil.invoke(properties, "get", propertyName)
        local numeric = ServerUtil.toNumber(value)
        if not valueOk or not numeric then
            error("RailroaderRVTest: player light property is not numeric: "
                .. tostring(propertyName))
        end
    end
    return properties
end

local function createLight(cell, square, sprite, generation, tagContext)
    local cls = rawget(_G, "IsoLightSwitch")
    local spriteOk, spriteObject = ServerUtil.callGlobal("getSprite", sprite)
    if not spriteOk then
        error("RailroaderRVTest: getSprite failed for player light")
    end
    validatePlayerLightSprite(spriteObject, sprite)
    local roomOk, roomId = ServerUtil.invoke(square, "getRoomID")
    if not roomOk or roomId == nil then
        roomId = -1
    end
    roomId = ServerUtil.toNumber(roomId) or -1
    local ok, light = ServerUtil.invokeClass(cls, {
        -- B42.20: IsoLightSwitch(IsoCell, IsoGridSquare, IsoSprite, long).
        { cell, square, spriteObject, roomId },
    })
    if not ok then
        error("RailroaderRVTest: IsoLightSwitch construction failed")
    end
    -- This is the BuildCraft player-built-light sequence adapted to B42.20:
    -- construct -> IsLighting/power -> sprite light source -> update -> add
    -- to square -> recalc -> activate/sync only after getObjectIndex exists.
    -- No hand-built independent light fallback is used; the sprite's RGB/radius
    -- properties are the single source of truth and avoid duplicate lights.
    local lightData = ServerWorld.objectModData(light)
    if not lightData then
        error("RailroaderRVTest: player light has no modData")
    end
    lightData.IsLighting = true
    ServerWorld.tagObject(light, generation, "light", ServerWorld.withTagIdentity(nil, tagContext))
    if not ServerUtil.callSucceeded(light, "setPower", 2) then
        error("RailroaderRVTest: player light initial state failed")
    end
    local addedLightOk = ServerUtil.callSucceeded(light, "addLightSourceFromSprite")
    if not addedLightOk then
        error("RailroaderRVTest: addLightSourceFromSprite failed")
    end
    local lightsOk, lights = ServerUtil.invoke(light, "getLights")
    local lightsSizeOk, lightsSize = ServerUtil.invoke(lights, "size")
    if not lightsOk or not lights or not lightsSizeOk or (ServerUtil.toNumber(lightsSize) or 0) < 1 then
        error("RailroaderRVTest: player light sprite produced no light source")
    end
    if not ServerUtil.callSucceeded(light, "update") then
        error("RailroaderRVTest: player light update failed")
    end
    addSpecialObject(square, light)
    -- The object is now attached, so setActive can pass the engine's object
    -- index/electricity checks.  `ignoreSwitchCheck` is intentional for the
    -- technical test: the roof generator is built first, but its vertical
    -- power bridge is not an IsoRoom yet.
    if not ServerUtil.callSucceeded(light, "setActivated", true) then
        error("RailroaderRVTest: player light activation failed")
    end
    local activeOk, active = ServerUtil.invoke(light, "setActive", true, false, true)
    if not activeOk or active ~= true then
        if not ServerUtil.callSucceeded(light, "switchLight", true) then
            error("RailroaderRVTest: player light switch failed")
        end
    end
    if not ServerUtil.callSucceeded(light, "update")
        or not ServerUtil.callSucceeded(light, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: player light synchronisation failed")
    end
    return light
end

local function createGenerator(cell, square, sprite, generation, tagContext)
    local cls = rawget(_G, "IsoGenerator")
    -- The cell-only constructor does not attach or transmit. Configure the
    -- registered hidden sprite first, then assign the square and add it.
    local itemOk, item = ServerUtil.callGlobal("instanceItem", "Base.Generator")
    if not itemOk or not item then
        error("RailroaderRVTest: Base.Generator item is unavailable")
    end
    ServerUtil.invoke(item, "setCondition", 100)
    local itemDataOk, itemData = ServerUtil.invoke(item, "getModData")
    if itemDataOk and type(itemData) == "table" then
        itemData.fuel = Constants.GENERATOR_INITIAL_FUEL
    end
    local utilitySprite = require("RailroaderRV/RV_UtilitySprite")
    local spriteReady, hiddenSprite, spriteReason = utilitySprite.ensureHiddenSprites()
    local hiddenSpriteName = Constants.SPRITES.utilityHidden.sprite
    if not spriteReady or not hiddenSprite
        or hiddenSpriteName ~= Constants.UTILITY_HIDDEN_SPRITE_KEY then
        error("RailroaderRVTest: generator hidden sprite is unavailable: "
            .. tostring(spriteReason))
    end
    local ok, generator = ServerUtil.invokeClass(cls, {
        { cell },
    })
    if not ok then
        error("RailroaderRVTest: IsoGenerator construction failed")
    end
    if not ServerUtil.callSucceeded(generator, "setInfoFromItem", item)
        or not ServerUtil.callSucceeded(generator, "setSprite", hiddenSpriteName)
        or not ServerUtil.callSucceeded(generator, "setSpriteFromName", hiddenSpriteName) then
        error("RailroaderRVTest: generator hidden initialization failed")
    end
    local spriteOk, actualSprite = ServerUtil.invoke(generator, "getSprite")
    local nameOk, actualSpriteName = ServerUtil.invoke(generator, "getSpriteName")
    if not spriteOk or actualSprite ~= hiddenSprite or not nameOk
        or tostring(actualSpriteName) ~= tostring(hiddenSpriteName) then
        error("RailroaderRVTest: generator hidden sprite did not persist")
    end
    if not ServerUtil.callSucceeded(generator, "setSquare", square) then
        error("RailroaderRVTest: generator square assignment failed")
    end
    local squareOk, actualSquare = ServerUtil.invoke(generator, "getSquare")
    if not squareOk or actualSquare ~= square then
        error("RailroaderRVTest: generator square assignment did not match")
    end
    -- Tag before attachment so a partially completed add remains discoverable
    -- by transaction rollback; the explicit square above makes removal safe.
    ServerWorld.tagObject(generator, generation, "generator", ServerWorld.withTagIdentity(nil, tagContext))
    addSpecialObject(square, generator)
    if not ServerUtil.callSucceeded(generator, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: generator initial client transmission failed")
    end
    if not ServerUtil.callSucceeded(generator, "setCondition", 100)
        or not ServerUtil.callSucceeded(generator, "setFuel", Constants.GENERATOR_INITIAL_FUEL)
        or not ServerUtil.callSucceeded(generator, "setConnected", true)
        or not ServerUtil.callSucceeded(generator, "setActivated", true) then
        error("RailroaderRVTest: generator initial state failed")
    end
    if type(cls.updateGenerator) == "function" then
        pcall(cls.updateGenerator, square)
    end
    if not ServerUtil.callSucceeded(generator, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: generator client transmission failed")
    end
    return generator
end

local function createFurniture(cell, square, sprite, generation, role, tagContext)
    local cls = rawget(_G, "IsoObject")
    local ok, object = ServerUtil.invokeClass(cls, {
        { cell, square, sprite },
        { square, sprite },
    })
    if not ok then
        error("RailroaderRVTest: furniture construction failed for " .. tostring(role))
    end
    -- Some B42.20 sprites (including fluid fixtures) carry an entity script;
    -- attach it before AddTileObject so the engine initializes its components.
    local entityCreated = createEntityFromSprite(object, sprite)
    if entityCreated == false then
        error("RailroaderRVTest: furniture entity creation failed for " .. tostring(role))
    end
    -- The vanilla sink sprite is ordinary furniture and may have no entity
    -- script.  The utility catalog and authoritative water mirror both need
    -- the public FluidContainer component, so attach the B42 component before
    -- tagging, tile attachment, and the sink's unique full-object packet.
    if role == "sink" and not ensureSinkFluidContainer(object) then
        error("RailroaderRVTest: generated sink FluidContainer creation failed")
    end
    ServerWorld.tagObject(object, generation, role, ServerWorld.withTagIdentity(nil, tagContext))
    addNormalObject(square, object)
    -- Counter and sink callers own the complete packet.  The sink publishes
    -- its initial object here at the call site, then sends plumbing deltas
    -- only after that packet has made the object visible to the client.
    return object
end

local function createCapturedTemplateObject(cell, square, entry, generation,
    tagContext, edge)
    if type(entry) ~= "table" or type(entry.class) ~= "string"
        or type(entry.templateIndex) ~= "number" then
        error("RailroaderRVTest: captured template object is malformed")
    end
    local role = edge and edge.role or "captured-template"
    local tagData = capturedTagData(entry, edge, tagContext)
    local object
    if isVisualCornerTemplateEntry(entry) then
        if entry.class ~= "IsoObject" then
            error("RailroaderRVTest: captured corner trim class is invalid")
        end
        local cls = rawget(_G, "IsoObject")
        local constructed, tileObject = ServerUtil.invokeClass(cls, {
            { cell, square, entry.sprite },
            { square, entry.sprite },
        })
        if not constructed then
            error("RailroaderRVTest: captured corner trim construction failed")
        end
        applyCapturedIdentityAndState(tileObject, entry)
        ServerWorld.tagObject(tileObject, generation, role,
            ServerWorld.withTagIdentity(tagData, tagContext))
        if not ServerUtil.callSucceeded(square, "AddTileObject", tileObject) then
            error("RailroaderRVTest: captured corner trim attachment failed")
        end
        local indexOk, objectIndex = ServerUtil.invoke(tileObject, "getObjectIndex")
        local indexNumber = ServerUtil.toNumber(objectIndex)
        if not indexOk or not indexNumber or indexNumber < 0 then
            error("RailroaderRVTest: captured corner trim attachment was not observable")
        end
        ServerWorld.recalcSquare(square)
        if not ServerUtil.callSucceeded(tileObject, "transmitCompleteItemToClients") then
            error("RailroaderRVTest: captured corner trim client transmission failed")
        end
        return tileObject
    elseif entry.class == "IsoObject" then
        -- The corner trim entries above are tile objects; other captured
        -- IsoObject entries in this template occupy the floor slot.
        object = createFloor(square, entry.sprite, generation, role, tagContext,
            entry, edge)
        return object
    elseif entry.class == "IsoThumpable" then
        -- Register the numeric sprite before the string constructor performs
        -- its name lookup; otherwise the manager can cache an unindexed
        -- DEFAULT_SPRITE_ID entry under this custom key.
        local expectedHiddenSprite = ensureCapturedHiddenSprite(entry)
        local cls = rawget(_G, "IsoThumpable")
        local constructed, thumpable = ServerUtil.invokeClass(cls, {
            { cell, square, entry.sprite, entry.north, nil },
        })
        if not constructed then
            error("RailroaderRVTest: captured IsoThumpable construction failed")
        end
        if not ServerUtil.callSucceeded(thumpable, "setIsThumpable", true) then
            error("RailroaderRVTest: captured IsoThumpable state failed")
        end
        bindCapturedHiddenSprite(thumpable, entry, expectedHiddenSprite)
        applyCapturedIdentityAndState(thumpable, entry, true)
        if entry.name == "Wooden Door Frame" then
            configureCapturedDoorFrame(thumpable, entry)
        end
        ServerWorld.tagObject(thumpable, generation, role,
            ServerWorld.withTagIdentity(tagData, tagContext))
        addSpecialObject(square, thumpable)
        -- The B42 health setter resolves the object through its square. Apply
        -- captured health after attachment, while the generation tag already
        -- lets transaction rollback remove it if the setter or read-back fails.
        applyCapturedHealthState(thumpable, entry)
        object = thumpable
    elseif entry.class == "IsoDoor" then
        local cls = rawget(_G, "IsoDoor")
        local constructed, door = ServerUtil.invokeClass(cls, {
            -- The native door constructor uses the captured closed tile and
            -- orientation, so no guessed open-sprite index is needed.
            { cell, square, entry.sprite, entry.north },
        })
        if not constructed then
            error("RailroaderRVTest: captured IsoDoor construction failed")
        end
        applyCapturedIdentityAndState(door, entry)
        ServerWorld.tagObject(door, generation, role,
            ServerWorld.withTagIdentity(tagData, tagContext))
        addSpecialObject(square, door)
        object = door
    elseif entry.class == "IsoWindow" then
        local spriteOk, spriteObject = ServerUtil.callGlobal("getSprite", entry.sprite)
        local cls = rawget(_G, "IsoWindow")
        local constructed, window = ServerUtil.invokeClass(cls, {
            { cell, square, spriteObject, entry.north },
        })
        if not spriteOk or not spriteObject or not constructed then
            error("RailroaderRVTest: captured IsoWindow construction failed")
        end
        if not ServerUtil.callSucceeded(window, "setIsLocked", false) then
            error("RailroaderRVTest: captured window unlocked state failed")
        end
        applyCapturedIdentityAndState(window, entry, true)
        ServerWorld.tagObject(window, generation, role,
            ServerWorld.withTagIdentity(tagData, tagContext))
        addSpecialObject(square, window)
        applyCapturedHealthState(window, entry)
        object = window
    elseif entry.class == "IsoLightSwitch" then
        local spriteOk, spriteObject = ServerUtil.callGlobal("getSprite", entry.sprite)
        local roomOk, roomId = ServerUtil.invoke(square, "getRoomID")
        roomId = roomOk and ServerUtil.toNumber(roomId) or -1
        local cls = rawget(_G, "IsoLightSwitch")
        local constructed, light = ServerUtil.invokeClass(cls, {
            { cell, square, spriteObject, roomId },
        })
        if not spriteOk or not spriteObject or not constructed then
            error("RailroaderRVTest: captured IsoLightSwitch construction failed")
        end
        applyCapturedIdentityAndState(light, entry)
        if not ServerUtil.callSucceeded(light, "addLightSourceFromSprite")
            or not ServerUtil.callSucceeded(light, "update") then
            error("RailroaderRVTest: captured light switch state failed")
        end
        ServerWorld.tagObject(light, generation, role,
            ServerWorld.withTagIdentity(tagData, tagContext))
        addSpecialObject(square, light)
        if not ServerUtil.callSucceeded(light, "update") then
            error("RailroaderRVTest: captured light switch update failed")
        end
        object = light
    else
        error("RailroaderRVTest: unsupported captured object class "
            .. tostring(entry.class))
    end
    if not ServerUtil.callSucceeded(object, "transmitCompleteItemToClients") then
        error("RailroaderRVTest: captured object client transmission failed")
    end
    return object
end

-- Error objects are not required to be strings in Lua.  Keep diagnostics
-- useful without allowing a hostile __tostring/debug implementation to
-- escape the transaction's protected/finalize path.

ctx.ensureRoofSquare = ensureRoofSquare
ctx.createFloor = createFloor
ctx.createWall = createWall
ctx.createGenerator = createGenerator
ctx.createCapturedTemplateObject = createCapturedTemplateObject
ctx.configureCapturedDoorFrame = configureCapturedDoorFrame
end
