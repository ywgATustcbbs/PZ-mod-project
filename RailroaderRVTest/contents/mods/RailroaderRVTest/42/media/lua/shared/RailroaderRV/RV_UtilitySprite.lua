-- RailroaderRVTest's isolated hidden utility sprite registration.
--
-- The utility tank/proxy are invisible IsoThumpables, but their sprite still
-- participates in square property aggregation and in the object save/add
-- packet.  Never borrow a normal furniture sprite: blueprint is a property
-- of the shared IsoSprite instance and would alter every object using it.

local C = require("RailroaderRV/RV_Constants")

local M = {}
local eventRegistered = false

local function invoke(target, method, ...)
    if target == nil then return false, nil end
    local fn = target[method]
    if type(fn) ~= "function" then return false, nil end
    local ok, a, b = pcall(fn, target, ...)
    if not ok then return false, a end
    return true, a, b
end

local function callSucceeded(target, method, ...)
    local ok, result = invoke(target, method, ...)
    return ok and result ~= false
end

local function ensureBlueprint(sprite)
    local flagType = rawget(_G, "IsoFlagType")
    local blueprint = flagType and flagType.blueprint
    if blueprint == nil then return false, "blueprint-flag-missing" end
    local propertiesOk, properties = invoke(sprite, "getProperties")
    if not propertiesOk or not properties then return false, "properties-missing" end
    local hasOk, hasBlueprint = invoke(properties, "has", blueprint)
    if not hasOk then return false, "blueprint-read" end
    if not hasBlueprint then
        if not callSucceeded(properties, "set", blueprint)
            or not callSucceeded(properties, "CreateKeySet") then
            return false, "blueprint-set" end
    end
    local verifyOk, verified = invoke(properties, "has", blueprint)
    if not verifyOk or verified ~= true then return false, "blueprint-postcondition" end
    return true
end

local function ensureOne(manager, namedMap, key, id)
    local existingOk, sprite = invoke(namedMap, "get", key)
    if not existingOk then return false, nil, "named-map-read" end
    if not sprite then
        -- AddSprite(name, id) writes intMap before it returns.  Inspect the
        -- numeric slot first so a pre-existing unrelated sprite cannot be
        -- overwritten while this registration is being rejected.
        local collisionOk, collision = invoke(manager, "getSprite", id)
        if not collisionOk then return false, nil, "sprite-id-read" end
        if collision then return false, nil, "sprite-id-collision" end
        local addOk, added = invoke(manager, "AddSprite", key, id)
        if not addOk or not added then return false, nil, "sprite-register" end
        sprite = added
    end

    local idOk, spriteId = invoke(sprite, "getID")
    if not idOk or spriteId ~= id then return false, nil, "sprite-id" end
    local byIdOk, byId = invoke(manager, "getSprite", id)
    if not byIdOk or byId ~= sprite then return false, nil, "sprite-id-map" end
    local byNameOk, byName = invoke(manager, "getSprite", key)
    if not byNameOk or byName ~= sprite then return false, nil, "sprite-name-map" end

    local nameOk, name = invoke(sprite, "getName")
    if not nameOk then return false, nil, "sprite-name-read" end
    if name == nil then
        if not callSucceeded(sprite, "setName", key) then
            return false, nil, "sprite-name-set" end
        nameOk, name = invoke(sprite, "getName")
    end
    if not nameOk or name == nil or tostring(name) ~= tostring(key) then
        return false, nil, "sprite-name-postcondition"
    end

    local blueprintOk, blueprintReason = ensureBlueprint(sprite)
    if not blueprintOk then return false, nil, blueprintReason end
    return true, sprite
end

function M.ensureHiddenSprites()
    local managerClass = rawget(_G, "IsoSpriteManager")
    local manager = managerClass and managerClass.instance
    if not manager then return false, nil, "sprite-manager-missing" end

    -- getNamedMap lets us distinguish an existing registration from a new
    -- one.  Calling AddSprite blindly on every boot can replace the existing
    -- Java object; that would invalidate object pointer identity and intMap.
    local mapOk, namedMap = invoke(manager, "getNamedMap")
    if not mapOk or not namedMap then return false, nil, "named-map-missing" end
    return ensureOne(manager, namedMap, C.UTILITY_HIDDEN_SPRITE_KEY,
        C.UTILITY_HIDDEN_SPRITE_ID)
end

function M.install()
    local ok, sprite, reason = M.ensureHiddenSprites()
    if not eventRegistered and Events and Events.OnGameBoot
        and type(Events.OnGameBoot.Add) == "function" then
        Events.OnGameBoot.Add(M.ensureHiddenSprites)
        eventRegistered = true
    end
    return ok, sprite, reason
end

return M
