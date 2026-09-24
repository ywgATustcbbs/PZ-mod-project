-- RV_Server: WorldObjects responsibilities.
return function(ctx)
local OWNER = ctx.OWNER
local Constants = ctx.Constants
local ServerUtil = ctx.ServerUtil
local ServerWorld = ctx.ServerWorld

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

local function createFloor(square, sprite, generation, role, tagContext)
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
    local tagged, tagError = pcall(ServerWorld.tagObject, floor, generation, role,
        ServerWorld.withTagIdentity({
        previousSprite = previousSprite,
        createdByGeneration = createdByGeneration,
        }, tagContext))
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
    -- IsoGenerator's B42.20 constructor already calls AddSpecialObject.  Do
    -- not insert it a second time; all other constructors arrive unattached.
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
    -- final.  Sending here made the subsequent light/generator sync send
    -- a second AddItemToMap for the same object index.
    ServerWorld.recalcSquare(square)
end

local function addNormalObject(square, object)
    -- B42.20 has AddTileObject for ordinary IsoObject instances; AddObject
    -- and addObject are not IsoGridSquare methods.  Counters/sinks must remain
    -- tile objects so their sprite/entity behavior is preserved.
    local ok = ServerUtil.callSucceeded(square, "AddTileObject", object)
    if not ok then
        error("RailroaderRVTest: unable to attach normal object to square")
    end
    local indexOk, attachedIndex = ServerUtil.invoke(object, "getObjectIndex")
    local attachedNumber = ServerUtil.toNumber(attachedIndex)
    if not indexOk or not attachedNumber or attachedNumber < 0 then
        error("RailroaderRVTest: normal object attachment was not observable")
    end
    -- The creator owns the one final full-object packet so plumbing/entity
    -- state can be completed before it is sent.
    ServerWorld.recalcSquare(square)
end

local function hasEntityComponent(object, componentName)
    if componentName == "FluidContainer" then
        local containerOk, container = ServerUtil.invoke(object, "getFluidContainer")
        return containerOk and container ~= nil
    end
    local componentTypes = rawget(_G, "ComponentType")
    local componentType = componentTypes and componentTypes[componentName] or nil
    if not componentType then
        return false
    end
    local hasOk, has = ServerUtil.invoke(object, "hasComponent", componentType)
    if hasOk and has == true then
        return true
    end
    local componentOk, component = ServerUtil.invoke(object, "getComponent", componentType)
    return componentOk and component ~= nil
end

local function ensureSinkFluidContainer(object)
    if hasEntityComponent(object, "FluidContainer") then return true end
    local componentTypes = rawget(_G, "ComponentType")
    local fluidType = componentTypes and componentTypes.FluidContainer or nil
    local factory = rawget(_G, "GameEntityFactory")
    if not fluidType or not factory
        or type(fluidType.CreateComponent) ~= "function"
        or type(factory.AddComponent) ~= "function" then
        return false
    end
    local created, component = pcall(function()
        return fluidType:CreateComponent()
    end)
    if not created or not component then return false end
    local added = pcall(factory.AddComponent, object, true, component)
    return added and hasEntityComponent(object, "FluidContainer")
end

local function createEntityFromSprite(object, sprite, requiredComponent)
    local configManager = rawget(_G, "SpriteConfigManager")
    if not configManager or type(configManager.getObjectInfoFromSprite) ~= "function" then
        return requiredComponent and false or nil
    end
    local okInfo, info = pcall(configManager.getObjectInfoFromSprite, sprite)
    if not okInfo or not info or type(info.getScript) ~= "function" then
        -- Ordinary furniture such as the counter/sink has no entity script;
        -- absence is not an entity-creation failure for those sprites.
        return requiredComponent and false or nil
    end
    local okScript, script = pcall(info.getScript, info)
    if not okScript or not script or type(script.getParent) ~= "function" then
        return false
    end
    local okParent, parent = pcall(script.getParent, script)
    if not okParent or not parent then
        return false
    end
    local factory = rawget(_G, "GameEntityFactory")
    if not factory or type(factory.CreateIsoObjectEntity) ~= "function" then
        return false
    end
    -- The factory is the B42.20-supported way to attach FluidContainer and
    -- other entity components to an IsoObject created from a sprite.
    -- CreateIsoObjectEntity is Java void; pcall success is only invocation
    -- success, never a returned entity value.
    local okEntity = pcall(factory.CreateIsoObjectEntity, object, parent, true)
    if not okEntity then
        return false
    end
    -- The factory catches its own Java exceptions, so also require the script
    -- component to be observable on the same IsoObject after the call.
    local attachedScriptOk, attachedScript = ServerUtil.invoke(object, "getEntityScript")
    if not attachedScriptOk or not attachedScript then
        return false
    end
    if requiredComponent and not hasEntityComponent(object, requiredComponent) then
        return false
    end
    return true
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
    -- B42.20's only world constructor is
    -- IsoGenerator(InventoryItem, IsoCell, IsoGridSquare).  The item carries
    -- the initial condition/fuel state and also selects the world sprite.
    local itemOk, item = ServerUtil.callGlobal("instanceItem", "Base.Generator")
    if not itemOk or not item then
        error("RailroaderRVTest: Base.Generator item is unavailable")
    end
    ServerUtil.invoke(item, "setCondition", 100)
    local itemDataOk, itemData = ServerUtil.invoke(item, "getModData")
    if itemDataOk and type(itemData) == "table" then
        itemData.fuel = Constants.GENERATOR_INITIAL_FUEL
    end
    local ok, generator = ServerUtil.invokeClass(cls, {
        { item, cell, square },
    })
    if not ok then
        error("RailroaderRVTest: IsoGenerator construction failed")
    end
    ServerWorld.tagObject(generator, generation, "generator", ServerWorld.withTagIdentity(nil, tagContext))
    if not ServerUtil.callSucceeded(generator, "setCondition", 100)
        or not ServerUtil.callSucceeded(generator, "setFuel", Constants.GENERATOR_INITIAL_FUEL)
        or not ServerUtil.callSucceeded(generator, "setConnected", true)
        or not ServerUtil.callSucceeded(generator, "setActivated", true) then
        error("RailroaderRVTest: generator initial state failed")
    end
    if type(cls.updateGenerator) == "function" then
        pcall(cls.updateGenerator, square)
    end
    -- IsoGenerator's B42.20 constructor attaches the object itself.  Keep the
    -- explicit helper after all local/tag state is final so it only validates
    -- that attachment and recalculates the square; it emits no packet.
    addSpecialObject(square, generator)
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

-- Error objects are not required to be strings in Lua.  Keep diagnostics
-- useful without allowing a hostile __tostring/debug implementation to
-- escape the transaction's protected/finalize path.

ctx.ensureRoofSquare = ensureRoofSquare
ctx.createFloor = createFloor
ctx.createWall = createWall
ctx.createLight = createLight
ctx.createGenerator = createGenerator
ctx.createFurniture = createFurniture
end
