-- Shared water-device and fluid-profile rules.
--
-- runtimeTestEnabled is a development allowlist for the compatibility-test
-- path.  It does not enable general water support.

RailroaderRV = RailroaderRV or {}
local C = require("RailroaderRV/RV_Constants")
local U = require("RailroaderRV/RV_UtilityConstants")

local M = {}
local EPSILON = U.PROFILE_EPSILON

M.DEVICE_CATALOG = {
    sink = {
        id = "sink", aliases = { "sink", "faucet", "washbasin" },
        runtimeTestEnabled = true,
    },
    -- Native plumbing capability is intentionally a catalog entry rather than
    -- a name allowlist.  The entry is used as the current-schema deviceType
    -- for any object that the B42 context-menu plumbing rule accepts, including
    -- mod-added furniture with an unknown sprite/name.
    nativeWaterDevice = {
        id = "nativeWaterDevice", aliases = {},
        runtimeTestEnabled = false,
    },
    toilet = {
        id = "toilet", aliases = { "toilet", "wc" },
        runtimeTestEnabled = false,
    },
    bathtub = {
        id = "bathtub", aliases = { "bathtub", "bath" },
        runtimeTestEnabled = false,
    },
    shower = {
        id = "shower", aliases = { "shower" },
        runtimeTestEnabled = false,
    },
    washingMachine = {
        id = "washingMachine", aliases = { "washingmachine", "washing_machine", "washer" },
        runtimeTestEnabled = false,
    },
}

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function number(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) end
    if value == nil then return nil end
    local ok, result = pcall(function() return value + 0 end)
    return ok and type(result) == "number" and result or nil
end

local function invoke(target, method, ...)
    if target == nil or type(target[method]) ~= "function" then return false end
    local ok, a, b, c = pcall(target[method], target, ...)
    return ok, a, b, c
end

local function lower(value)
    if value == nil then return "" end
    return string.lower(tostring(value))
end

local function profile(kind, clean, tainted)
    clean = number(clean) or 0
    tainted = number(tainted) or 0
    if not finite(clean) or not finite(tainted) or clean < 0 or tainted < 0 then
        return nil
    end
    local resultKind = kind
    if clean <= EPSILON and tainted <= EPSILON then resultKind = "EMPTY"
    elseif tainted <= EPSILON then resultKind = "CLEAN"
    elseif clean <= EPSILON then resultKind = "TAINTED"
    else resultKind = "MIXED" end
    return { kind = resultKind, cleanAmount = clean, taintedAmount = tainted }
end

function M.emptyProfile()
    return profile("EMPTY", 0, 0)
end

function M.copyProfile(value)
    if type(value) ~= "table" then return nil end
    return profile(value.kind, value.cleanAmount, value.taintedAmount)
end

function M.profileAmount(value)
    if type(value) ~= "table" then return nil end
    local clean, tainted = number(value.cleanAmount), number(value.taintedAmount)
    if not finite(clean) or not finite(tainted) or clean < 0 or tainted < 0 then return nil end
    return clean + tainted
end

local function fluidTypeString(fluid)
    if fluid == nil then return nil end
    local ok, value = invoke(fluid, "getFluidTypeString")
    if ok and value ~= nil then return tostring(value) end
    return nil
end

local function readComponents(container, totalAmount)
    -- FluidContainer's internal list is not a Lua collection contract.  The
    -- supported public component API exposes per-fluid amounts instead; if a
    -- build does not expose that method, mixed fluids remain unsupported and
    -- are rejected rather than guessed from the primary fluid.
    local fluidClass = rawget(_G, "Fluid")
    if not fluidClass or fluidClass.Water == nil
        or fluidClass.TaintedWater == nil then return nil end
    local cleanOk, clean = invoke(container, "getSpecificFluidAmount", fluidClass.Water)
    local taintedOk, tainted = invoke(container, "getSpecificFluidAmount",
        fluidClass.TaintedWater)
    clean, tainted, totalAmount = number(clean), number(tainted), number(totalAmount)
    if not cleanOk or not taintedOk or not finite(clean) or not finite(tainted)
        or not finite(totalAmount) or clean < 0 or tainted < 0
        or math.abs(clean + tainted - totalAmount) > EPSILON then
        return nil
    end
    return profile(nil, clean, tainted)
end

function M.readProfile(container)
    if container == nil then return nil end
    local amountOk, amount = invoke(container, "getAmount")
    amount = amountOk and number(amount) or nil
    if not finite(amount) or amount < 0 then return nil end
    if amount <= EPSILON then return M.emptyProfile() end
    local mixedOk, mixed = invoke(container, "isMixture")
    if not mixedOk then return nil end
    if mixedOk and mixed == true then
        local mixedProfile = readComponents(container, amount)
        local mixedAmount = mixedProfile and M.profileAmount(mixedProfile) or nil
        if mixedAmount == nil or math.abs(mixedAmount - amount) > EPSILON then
            return nil
        end
        return mixedProfile
    end
    local primaryOk, primary = invoke(container, "getPrimaryFluid")
    local name = lower(primaryOk and fluidTypeString(primary) or nil)
    if name == "water" then return profile("CLEAN", amount, 0) end
    if name == "taintedwater" or name == "tainted_water" then
        return profile("TAINTED", 0, amount)
    end
    return nil
end

function M.isAllowedProfile(value)
    if type(value) ~= "table" then return false end
    local count = 0
    for key in pairs(value) do
        if key ~= "kind" and key ~= "cleanAmount" and key ~= "taintedAmount" then
            return false
        end
        count = count + 1
    end
    if count ~= 3 then return false end
    if value.kind ~= "EMPTY" and value.kind ~= "CLEAN"
        and value.kind ~= "TAINTED" and value.kind ~= "MIXED" then return false end
    local copy = M.copyProfile(value)
    return copy ~= nil and copy.kind == value.kind
end

function M.applyProfile(container, capacity, value)
    local amount = M.profileAmount(value)
    capacity = number(capacity)
    if container == nil or not finite(capacity) or capacity < 0
        or not M.isAllowedProfile(value) or amount == nil or amount > capacity + EPSILON then
        return false
    end
    local unlockCallOk, unlockResult = invoke(container, "setInputLocked", false)
    if not unlockCallOk or unlockResult == false then return false, "set-input-unlocked" end
    local function failedProjection()
        -- Best-effort relock: a failed projection must not leave a device
        -- container open for an untracked native refill path.
        invoke(container, "setInputLocked", true)
        return false
    end
    -- A freshly-created FluidContainer starts with zero capacity.  B42's
    -- removeFluid/Empty path can reject that state, so establish the current
    -- schema capacity before clearing or projecting its contents.  Existing
    -- containers use the same fixed capacity and remain equivalent.
    local capacityCallOk, capacityResult = invoke(container, "setCapacity", capacity)
    if not capacityCallOk or capacityResult == false then
        failedProjection()
        return false, "set-capacity"
    end
    local removeCallOk, removeResult = invoke(container, "removeFluid")
    local removeOk = removeCallOk and removeResult ~= false
    if not removeOk then
        local emptyCallOk, emptyResult = invoke(container, "Empty")
        removeOk = emptyCallOk and emptyResult ~= false
    end
    if not removeOk then
        failedProjection()
        return false, "clear-fluid"
    end
    if value.cleanAmount > EPSILON then
        local fluid = rawget(_G, "FluidType") and FluidType.Water
        if fluid == nil then
            failedProjection()
            return false, "clean-fluid-type"
        end
        local addCallOk, addResult = invoke(container, "addFluid", fluid, value.cleanAmount)
        if not addCallOk or addResult == false then
            failedProjection()
            return false, "add-clean-fluid"
        end
    end
    if value.taintedAmount > EPSILON then
        local fluid = rawget(_G, "FluidType") and FluidType.TaintedWater
        if fluid == nil then
            failedProjection()
            return false, "tainted-fluid-type"
        end
        local addCallOk, addResult = invoke(container, "addFluid", fluid, value.taintedAmount)
        if not addCallOk or addResult == false then
            failedProjection()
            return false, "add-tainted-fluid"
        end
    end
    -- This property is a compatibility gate, not a source of authority.  A
    -- missing method makes the projection unverifiable and is handled by the
    -- caller as a NEEDS_INIT/API failure.
    local lockCallOk, lockResult = invoke(container, "setInputLocked", true)
    if not lockCallOk or lockResult == false then return false, "set-input-locked" end
    return true
end

function M.entryIsRuntimeTestEnabled(entry)
    return type(entry) == "table" and entry.runtimeTestEnabled == true
end

local function hasWaterPipedFlag(object)
    local spriteOk, sprite = invoke(object, "getSprite")
    if not spriteOk or not sprite then return false end
    local propertiesOk, properties = invoke(sprite, "getProperties")
    local flags = rawget(_G, "IsoFlagType")
    local waterPiped = flags and flags.waterPiped
    if not propertiesOk or not properties or waterPiped == nil then return false end
    local hasOk, has = invoke(properties, "has", waterPiped)
    return hasOk and has == true
end

local function modDataCanBeWaterPiped(object)
    local ok, data = invoke(object, "getModData")
    return ok and type(data) == "table" and data.canBeWaterPiped == true
end

local MOV_CHEMICAL_TOILET = "Base.Mov_ChemicalToilet"

local function isChemicalToilet(object)
    -- ItemKey.MOV_CHEMICAL_TOILET is the exact vanilla identity.  A placed
    -- object can retain it in movableData; never use names or sprite prefixes.
    local dataOk, data = invoke(object, "getModData")
    local movable = dataOk and type(data) == "table" and data.movableData or nil
    if type(movable) == "table" then
        for _, key in ipairs({ "fullType", "fulltype", "itemType", "type" }) do
            local value = movable[key]
            if value ~= nil and lower(value) == string.lower(MOV_CHEMICAL_TOILET) then
                return true
            end
        end
    end
    local itemOk, itemType = invoke(object, "getItemType")
    if itemOk and itemType ~= nil and lower(itemType) == string.lower(MOV_CHEMICAL_TOILET) then
        return true
    end
    return false
end

-- This mirrors the B42 plumbing capability gate.  Source lookup is deliberately
-- not part of the predicate: connection creates a proxy and proves the source
-- as a postcondition.  Names, capacity, and current amount are not allowlists.
-- Room, range, player permission, RV identity, and request phase remain server
-- responsibilities outside this shared capability helper.
function M.isWaterPipedDevice(object)
    if object == nil or isChemicalToilet(object) then return false end
    if not hasWaterPipedFlag(object) and not modDataCanBeWaterPiped(object) then
        return false
    end
    return true
end

-- A player-placed native fixture has no RailroaderRVTest geometry tag.  Its
-- eligibility is exactly the current B42 plumbing capability above; names and
-- FluidContainer capacity are intentionally not used as the allowlist.
function M.isNativeWaterDevice(object)
    return not M.isGeneratedSink(object) and M.isWaterPipedDevice(object)
end

-- Compatibility name retained for callers during the current schema; it now
-- means any native water-piped fixture, not only a named sink.
function M.isNativeSink(object)
    return M.isNativeWaterDevice(object)
end

function M.hasFluidContainer(object)
    local ok, container = invoke(object, "getFluidContainer")
    return ok and container ~= nil
end

-- Only the object generated by the current RV builder may enter the explicit
-- sink compatibility-test path.  A generic sink elsewhere in the RV (or a
-- client-created/lookalike object) is not a test target.
function M.isGeneratedSink(object, identity)
    if object == nil or type(object.getModData) ~= "function" then return false end
    local ok, data = pcall(function() return object:getModData() end)
    local tag = ok and type(data) == "table" and data.RailroaderRVTest or nil
    if type(tag) ~= "table" or tag.owner ~= C.MOD_ID or tag.role ~= "sink" then
        return false
    end
    if identity == nil then return true end
    return tostring(tag.rvId) == tostring(identity.rvId)
        and number(tag.generation) == number(identity.generation)
        and number(tag.bitmapVersion) == number(identity.bitmapVersion)
end

function M.findEntry(object)
    if object == nil then return nil end
    -- Current generated sinks retain the stable sink deviceType.  The
    -- FluidContainer check here is a data-mirror contract and a legacy-save
    -- detector; plumbing eligibility itself is decided by isWaterPipedDevice.
    if M.isGeneratedSink(object) then
        return M.hasFluidContainer(object) and M.DEVICE_CATALOG.sink or nil
    end
    if M.isNativeWaterDevice(object) then
        -- The current compatibility allowlist has one sink entry.  The
        -- entry is metadata only; the capability predicate above decides
        -- whether this native fixture is actually eligible.
        return M.DEVICE_CATALOG.sink
    end
    return nil
end

return M
