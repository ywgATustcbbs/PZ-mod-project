-- RV_Server: WorldObjects responsibilities.
return function(ctx)
local OWNER = ctx.OWNER
local Constants = ctx.Constants
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld
local RoomTemplate = require("RailroaderRV/RoomTemplate/RV_RoomTemplate")

local function applyIntegerState(object, state, key, setter, getter)
    local expected = state[key]
    if expected == nil then return end
    if type(expected) ~= "number" or math.floor(expected) ~= expected
        or (setter and not ServerUtil.callSucceeded(object, setter, expected)) then
        error("RailroaderRV: captured object " .. key .. " could not be applied")
    end
    local readOk, actual = ServerUtil.invoke(object, getter)
    if not readOk or ServerUtil.toNumber(actual) ~= expected then
        error("RailroaderRV: captured object " .. key .. " did not match")
    end
end

local function applyBooleanState(object, state, key, setter, getter)
    local expected = state[key]
    if expected == nil then return end
    if type(expected) ~= "boolean"
        or not ServerUtil.callSucceeded(object, setter, expected) then
        error("RailroaderRV: captured object " .. key .. " could not be applied")
    end
    local readOk, actual = ServerUtil.invoke(object, getter)
    if not readOk or actual ~= expected then
        error("RailroaderRV: captured object " .. key .. " did not match")
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
    local utilitySprite = require("RailroaderRV/Common/RV_UtilitySprite")
    local ready, expectedSprite, reason = utilitySprite.ensureHiddenSprites()
    if not ready or not expectedSprite then
        error("RailroaderRV: captured hidden blocker sprite is unavailable;"
            .. capturedObjectContext(entry) .. " reason=" .. tostring(reason))
    end
    return expectedSprite
end

local function bindCapturedHiddenSprite(object, entry, expectedSprite)
    if entry.sprite ~= Constants.UTILITY_HIDDEN_SPRITE_KEY then return end
    if not expectedSprite then
        error("RailroaderRV: captured hidden blocker sprite was not registered before construction;"
            .. capturedObjectContext(entry))
    end
    if not ServerUtil.callSucceeded(object, "setSpriteFromName", entry.sprite) then
        error("RailroaderRV: captured hidden blocker sprite bind failed;"
            .. capturedObjectContext(entry))
    end
    local spriteOk, actualSprite = ServerUtil.invoke(object, "getSprite")
    local nameOk, actualName = ServerUtil.invoke(actualSprite, "getName")
    local objectNameOk, actualObjectName = ServerUtil.invoke(object, "getSpriteName")
    if not spriteOk or actualSprite ~= expectedSprite
        or not nameOk or tostring(actualName) ~= entry.sprite
        or not objectNameOk or tostring(actualObjectName) ~= entry.sprite then
        error("RailroaderRV: captured hidden blocker sprite bind did not match;"
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
        error("RailroaderRV: captured object identity is malformed")
    end
    if not ServerUtil.classInstance(object, entry.class) then
        error("RailroaderRV: captured object class did not match")
    end
    if entry.class == "IsoThumpable" or entry.class == "IsoWindow"
        or entry.class == "IsoDoor" then
        if type(entry.north) ~= "boolean" then
            error("RailroaderRV: captured object north state is malformed")
        end
    elseif entry.north ~= nil then
        error("RailroaderRV: captured object has an unexpected north state")
    end
    local stateKeys = { health = true, maxHealth = true, hoppable = true,
        locked = true, canPassThrough = true, blockAllTheSquare = true,
        doRender = true, thumpable = true }
    for key in pairs(entry.state) do
        if not stateKeys[key] then
            error("RailroaderRV: captured object state has an unsupported field")
        end
    end
    if not ServerUtil.callSucceeded(object, "setName", entry.name) then
        error("RailroaderRV: captured object name could not be applied")
    end
    local directions = rawget(_G, "IsoDirections")
    local expectedDirection = directions and directions[entry.direction]
    if not expectedDirection
        or not ServerUtil.callSucceeded(object, "setDir", expectedDirection) then
        error("RailroaderRV: captured object direction could not be applied")
    end
    if entry.north ~= nil then
        local northOk, actualNorth = ServerUtil.invoke(object, "getNorth")
        if not northOk or actualNorth ~= entry.north then
            error("RailroaderRV: captured object north state did not match")
        end
    end

    applyIntegerState(object, entry.state, "maxHealth", "setMaxHealth",
        "getMaxHealth")
    if not deferHealth then applyCapturedHealthState(object, entry) end

    if entry.state.hoppable ~= nil then
        if type(entry.state.hoppable) ~= "boolean" then
            error("RailroaderRV: captured object hoppable state is malformed")
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
            error("RailroaderRV: captured object hoppable state could not be applied;"
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
            error("RailroaderRV: captured object hoppable state did not match;"
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
            error("RailroaderRV: captured locked state is unsupported")
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
            error("RailroaderRV: captured unlocked state cannot be verified")
        end
        if observedLockState then
            error("RailroaderRV: captured object remained locked")
        end
    end

    local nameOk, actualName = ServerUtil.invoke(object, "getName")
    local dirOk, actualDirection = ServerUtil.invoke(object, "getDir")
    local spriteName = ServerWorld.getSpriteName(object)
    local nameMatches = nameOk and tostring(actualName) == entry.name
    local directionMatches = dirOk and actualDirection == expectedDirection
    local spriteMatches = tostring(spriteName) == entry.sprite
    if not nameMatches or not directionMatches or not spriteMatches then
        error("RailroaderRV: captured object identity read-back failed;"
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

local function capturedTagData(entry, edge)
    -- Identity only: `templateIndex` names the template entry and the world
    -- transform is derived from the object's own square at read time.  Every
    -- template attribute (class, name, sprite, north, direction) is re-read from
    -- the compiled template through that index instead of being copied here.
    local result = { templateIndex = entry.templateIndex }
    if edge then
        -- The shell edge key is not derivable from the object alone; the
        -- protection ledger still resolves the owning edge through it.
        result.edgeKey = edge.edgeKey
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
        error("RailroaderRV: captured door frame identity is invalid")
    end
    if not ServerUtil.callSucceeded(object, "setCanPassThrough", true)
        or not ServerUtil.callSucceeded(object, "setIsDoorFrame", true)
        or not ServerUtil.callSucceeded(object, "setIsThumpable", false) then
        error("RailroaderRV: captured door frame pass-through state failed")
    end
end

local function ensureRoofSquare(cell, x, y, z)
    -- On GameServer, getGridSquare reads ServerMap. IsoCell:createNewGridSquare
    -- registers a missing square in that map's loaded chunk. Keep this
    -- idempotent so a retry reuses a square left empty after a failed addFloor
    -- instead of creating a duplicate or a cell-cache-only square.
    local square = ServerWorld.getSquare(cell, x, y, z)
    if square then
        return square
    end

    -- The GameServer path checks that the coordinate is valid and its chunk is
    -- loaded, then registers the new square directly in ServerMap.
    local createdOk, created = ServerUtil.invoke(cell,
        "createNewGridSquare", x, y, z, true)
    if not createdOk or not created then
        error("RailroaderRV: unable to construct roof square")
    end

    local connected = ServerWorld.getSquare(cell, x, y, z)
    if not connected then
        error("RailroaderRV: roof square construction was not observable")
    end
    return connected
end

local function createFloor(square, sprite, generation, role, tagContext, capturedEntry, edge)
    if not sprite then
        error("RailroaderRV: floor sprite is not configured")
    end
    local ok, floor = ServerUtil.invoke(square, "getFloor")
    local hadFloor = ok and floor ~= nil
    local previousSprite
    local createdByGeneration = not hadFloor
    if hadFloor then
        previousSprite = ServerWorld.getSpriteName(floor)
        if not previousSprite then
            error("RailroaderRV: existing floor has no sprite")
        end
        -- Metal and wood are two phases over the same object.  Keep the first
        -- pre-generation sprite so rollback can restore the original floor;
        -- the wood/roof stages never overwrite this initial snapshot.
        local existingData = ServerWorld.objectModData(floor)
        local existingTag = existingData and existingData.RailroaderRV or nil
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
            error("RailroaderRV: addFloor failed")
        end
        ok, floor = ServerUtil.invoke(square, "getFloor")
    else
        local spriteObject = select(2, ServerUtil.callGlobal("getSprite", sprite))
        if spriteObject then
            if not ServerUtil.callSucceeded(floor, "setSprite", spriteObject) then
                error("RailroaderRV: floor sprite update failed")
            end
        else
            if not ServerUtil.callSucceeded(floor, "setSprite", sprite) then
                error("RailroaderRV: floor sprite update failed")
            end
        end
    end
    if not floor then
        error("RailroaderRV: floor object was not created")
    end
    if capturedEntry then
        applyCapturedIdentityAndState(floor, capturedEntry)
    end
    local floorTagData = capturedEntry
        and capturedTagData(capturedEntry, edge) or {}
    floorTagData.previousSprite = previousSprite
    floorTagData.createdByGeneration = createdByGeneration
    local tagged, tagError = pcall(ServerWorld.tagObject, floor, generation, role,
        tagContext, floorTagData)
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
            error("RailroaderRV: existing floor sprite transmission failed")
        end
        if not ServerUtil.callSucceeded(floor, "transmitModData") then
            error("RailroaderRV: existing floor modData transmission failed")
        end
    else
        -- A newly-added floor is absent from the client object map, so its
        -- complete packet is the sole initial object broadcast.
        if not ServerUtil.callSucceeded(floor, "transmitCompleteItemToClients") then
            error("RailroaderRV: new floor client transmission failed")
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
        error("RailroaderRV: unable to attach object to square")
    end
    local indexOk, attachedIndex = ServerUtil.invoke(object, "getObjectIndex")
    local attachedNumber = ServerUtil.toNumber(attachedIndex)
    if not indexOk or not attachedNumber or attachedNumber < 0 then
        error("RailroaderRV: object attachment was not observable")
    end
    -- The caller must transmit the complete object exactly once after its
    -- creation state is final; later syncable state changes use their own sync.
    -- Sending here would duplicate the complete packet for the same object.
    ServerWorld.recalcSquare(square)
end

local function createGenerator(cell, square, generation, tagContext)
    local cls = rawget(_G, "IsoGenerator")
    -- The cell-only constructor does not attach or transmit. Initialize the
    -- hidden sprite before attachment, while setInfoFromItem supplies the
    -- initial condition and fuel without sending state syncs.
    local itemOk, item = ServerUtil.callGlobal("instanceItem", "Base.Generator")
    if not itemOk or not item then
        error("RailroaderRV: Base.Generator item is unavailable")
    end
    ServerUtil.invoke(item, "setCondition", 100)
    local itemDataOk, itemData = ServerUtil.invoke(item, "getModData")
    if itemDataOk and type(itemData) == "table" then
        itemData.fuel = Constants.GENERATOR_INITIAL_FUEL
    end
    local utilitySprite = require("RailroaderRV/Common/RV_UtilitySprite")
    local spriteReady, hiddenSprite, spriteReason = utilitySprite.ensureHiddenSprites()
    local hiddenSpriteName = Constants.SPRITES.utilityHidden.sprite
    if not spriteReady or not hiddenSprite
        or hiddenSpriteName ~= Constants.UTILITY_HIDDEN_SPRITE_KEY then
        error("RailroaderRV: generator hidden sprite is unavailable: "
            .. tostring(spriteReason))
    end
    local ok, generator = ServerUtil.invokeClass(cls, {
        { cell },
    })
    if not ok then
        error("RailroaderRV: IsoGenerator construction failed")
    end
    if not ServerUtil.callSucceeded(generator, "setInfoFromItem", item)
        or not ServerUtil.callSucceeded(generator, "setSprite", hiddenSpriteName)
        or not ServerUtil.callSucceeded(generator, "setSpriteFromName", hiddenSpriteName) then
        error("RailroaderRV: generator hidden initialization failed")
    end
    local spriteOk, actualSprite = ServerUtil.invoke(generator, "getSprite")
    local nameOk, actualSpriteName = ServerUtil.invoke(generator, "getSpriteName")
    if not spriteOk or actualSprite ~= hiddenSprite or not nameOk
        or tostring(actualSpriteName) ~= tostring(hiddenSpriteName) then
        error("RailroaderRV: generator hidden sprite did not persist")
    end
    if not ServerUtil.callSucceeded(generator, "setSquare", square) then
        error("RailroaderRV: generator square assignment failed")
    end
    local squareOk, actualSquare = ServerUtil.invoke(generator, "getSquare")
    if not squareOk or actualSquare ~= square then
        error("RailroaderRV: generator square assignment did not match")
    end
    -- Tag before attachment so rollback can identify the object as soon as it
    -- becomes world-visible.
    ServerWorld.tagObject(generator, generation, RoomTemplate.PROXY_ROLES.power, tagContext)
    addSpecialObject(square, generator)
    if type(cls.updateGenerator) == "function" then
        pcall(cls.updateGenerator, square)
    end
    if not ServerUtil.callSucceeded(generator, "transmitCompleteItemToClients") then
        error("RailroaderRV: generator client transmission failed")
    end
    -- setConnected sends SyncIsoObject. Send the complete object first so each
    -- client receives its square index before that state update.
    if not ServerUtil.callSucceeded(generator, "setConnected", true) then
        error("RailroaderRV: generator initial connection state failed")
    end
    return generator
end

local function createWaterProxy(cell, square, generation, tagContext)
    local utilitySprite = require("RailroaderRV/Common/RV_UtilitySprite")
    local spriteReady, hiddenSprite, spriteReason = utilitySprite.ensureHiddenSprites()
    local hiddenSpriteName = Constants.SPRITES.utilityHidden.sprite
    if not spriteReady or not hiddenSprite then
        error("RailroaderRV: water proxy hidden sprite is unavailable: "
            .. tostring(spriteReason))
    end

    local proxy = IsoThumpable.new(cell, square, hiddenSpriteName, false)
    proxy:setSprite(hiddenSprite)
    proxy:setSpriteFromName(hiddenSpriteName)
    proxy:setDoRender(false)
    proxy:setCanPassThrough(true)
    proxy:setBlockAllTheSquare(false)
    proxy:setIsThumpable(false)

    local fluidContainer = ComponentType.FluidContainer:CreateComponent()
    fluidContainer:setCapacity(0.05)
    fluidContainer:setRainCatcher(0)
    GameEntityFactory.AddComponent(proxy, true, fluidContainer)
    ServerWorld.tagObject(proxy, generation, RoomTemplate.PROXY_ROLES.water,
        tagContext)
    addSpecialObject(square, proxy)
    proxy:transmitCompleteItemToClients()
    return proxy
end

local function createCapturedTemplateObject(cell, square, entry, generation,
    tagContext, edge)
    if type(entry) ~= "table" or type(entry.class) ~= "string"
        or type(entry.templateIndex) ~= "number" then
        error("RailroaderRV: captured template object is malformed")
    end
    local role = edge and edge.role or "captured-template"
    local tagData = capturedTagData(entry, edge)
    local object
    if isVisualCornerTemplateEntry(entry) then
        if entry.class ~= "IsoObject" then
            error("RailroaderRV: captured corner trim class is invalid")
        end
        local cls = rawget(_G, "IsoObject")
        local constructed, tileObject = ServerUtil.invokeClass(cls, {
            { cell, square, entry.sprite },
            { square, entry.sprite },
        })
        if not constructed then
            error("RailroaderRV: captured corner trim construction failed")
        end
        applyCapturedIdentityAndState(tileObject, entry)
        ServerWorld.tagObject(tileObject, generation, role,
            tagContext, tagData)
        if not ServerUtil.callSucceeded(square, "AddTileObject", tileObject) then
            error("RailroaderRV: captured corner trim attachment failed")
        end
        local indexOk, objectIndex = ServerUtil.invoke(tileObject, "getObjectIndex")
        local indexNumber = ServerUtil.toNumber(objectIndex)
        if not indexOk or not indexNumber or indexNumber < 0 then
            error("RailroaderRV: captured corner trim attachment was not observable")
        end
        ServerWorld.recalcSquare(square)
        if not ServerUtil.callSucceeded(tileObject, "transmitCompleteItemToClients") then
            error("RailroaderRV: captured corner trim client transmission failed")
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
            error("RailroaderRV: captured IsoThumpable construction failed")
        end
        if not ServerUtil.callSucceeded(thumpable, "setIsThumpable", true) then
            error("RailroaderRV: captured IsoThumpable state failed")
        end
        bindCapturedHiddenSprite(thumpable, entry, expectedHiddenSprite)
        applyCapturedIdentityAndState(thumpable, entry, true)
        if entry.name == "Wooden Door Frame" then
            configureCapturedDoorFrame(thumpable, entry)
        end
        ServerWorld.tagObject(thumpable, generation, role,
            tagContext, tagData)
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
            error("RailroaderRV: captured IsoDoor construction failed")
        end
        applyCapturedIdentityAndState(door, entry)
        ServerWorld.tagObject(door, generation, role,
            tagContext, tagData)
        addSpecialObject(square, door)
        object = door
    elseif entry.class == "IsoWindow" then
        local spriteOk, spriteObject = ServerUtil.callGlobal("getSprite", entry.sprite)
        local cls = rawget(_G, "IsoWindow")
        local constructed, window = ServerUtil.invokeClass(cls, {
            { cell, square, spriteObject, entry.north },
        })
        if not spriteOk or not spriteObject or not constructed then
            error("RailroaderRV: captured IsoWindow construction failed")
        end
        if not ServerUtil.callSucceeded(window, "setIsLocked", false) then
            error("RailroaderRV: captured window unlocked state failed")
        end
        applyCapturedIdentityAndState(window, entry, true)
        ServerWorld.tagObject(window, generation, role,
            tagContext, tagData)
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
            error("RailroaderRV: captured IsoLightSwitch construction failed")
        end
        applyCapturedIdentityAndState(light, entry)
        if not ServerUtil.callSucceeded(light, "addLightSourceFromSprite")
            or not ServerUtil.callSucceeded(light, "update") then
            error("RailroaderRV: captured light switch state failed")
        end
        ServerWorld.tagObject(light, generation, role,
            tagContext, tagData)
        addSpecialObject(square, light)
        if not ServerUtil.callSucceeded(light, "update") then
            error("RailroaderRV: captured light switch update failed")
        end
        object = light
    else
        error("RailroaderRV: unsupported captured object class "
            .. tostring(entry.class))
    end
    if not ServerUtil.callSucceeded(object, "transmitCompleteItemToClients") then
        error("RailroaderRV: captured object client transmission failed")
    end
    return object
end

-- Error objects are not required to be strings in Lua.  Keep diagnostics
-- useful without allowing a hostile __tostring/debug implementation to
-- escape the transaction's protected/finalize path.

ctx.ensureRoofSquare = ensureRoofSquare
ctx.createGenerator = createGenerator
ctx.createWaterProxy = createWaterProxy
ctx.createCapturedTemplateObject = createCapturedTemplateObject
ctx.configureCapturedDoorFrame = configureCapturedDoorFrame
end
