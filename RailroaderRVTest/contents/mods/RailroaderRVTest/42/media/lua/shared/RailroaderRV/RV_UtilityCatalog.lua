-- Shared water-device and fluid-profile rules.
--
-- Device entries are deliberately marked runtimeValidated=false until the
-- complete B42/MP matrix in WATER_POWER_IMPLEMENTATION_PLAN.md has been run.
-- The server never silently promotes an unverified device into the active
-- registry.

RailroaderRV = RailroaderRV or {}
local U = require("RailroaderRV/RV_UtilityConstants")

local M = {}
local EPSILON = U.PROFILE_EPSILON

M.DEVICE_CATALOG = {
    sink = {
        id = "sink", aliases = { "sink", "faucet", "washbasin" },
        runtimeValidated = false,
    },
    toilet = {
        id = "toilet", aliases = { "toilet", "wc" },
        runtimeValidated = false,
    },
    bathtub = {
        id = "bathtub", aliases = { "bathtub", "bath" },
        runtimeValidated = false,
    },
    shower = {
        id = "shower", aliases = { "shower" },
        runtimeValidated = false,
    },
    washingMachine = {
        id = "washingMachine", aliases = { "washingmachine", "washing_machine", "washer" },
        runtimeValidated = false,
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

function M.profileAdd(left, right, rightAmount, rightTotal)
    left, right = M.copyProfile(left), M.copyProfile(right)
    rightAmount, rightTotal = number(rightAmount), number(rightTotal)
    if not left or not right or not finite(rightAmount) or not finite(rightTotal)
        or rightAmount < 0 or rightTotal <= EPSILON or rightAmount > rightTotal + EPSILON then
        return nil
    end
    local profileTotal = M.profileAmount(right)
    if profileTotal == nil or math.abs(profileTotal - rightTotal) > EPSILON then
        return nil
    end
    local ratio = math.min(1, math.max(0, rightAmount / rightTotal))
    return profile(nil, left.cleanAmount + right.cleanAmount * ratio,
        left.taintedAmount + right.taintedAmount * ratio)
end

function M.profileSubtract(value, amount)
    value = M.copyProfile(value)
    amount = number(amount)
    if not value or not finite(amount) or amount < 0 then return nil end
    local total = M.profileAmount(value)
    if not finite(total) or amount > total + EPSILON then return nil end
    if total <= EPSILON then return M.emptyProfile() end
    local ratio = math.min(1, math.max(0, amount / total))
    return profile(nil, value.cleanAmount * (1 - ratio),
        value.taintedAmount * (1 - ratio))
end

function M.applyProfile(container, capacity, value)
    local amount = M.profileAmount(value)
    capacity = number(capacity)
    if container == nil or not finite(capacity) or capacity < 0
        or not M.isAllowedProfile(value) or amount == nil or amount > capacity + EPSILON then
        return false
    end
    local unlockCallOk, unlockResult = invoke(container, "setInputLocked", false)
    if not unlockCallOk or unlockResult == false then return false end
    local function failedProjection()
        -- Best-effort relock: a failed projection must not leave a device
        -- container open for an untracked native refill path.
        invoke(container, "setInputLocked", true)
        return false
    end
    local removeCallOk, removeResult = invoke(container, "removeFluid")
    local removeOk = removeCallOk and removeResult ~= false
    if not removeOk then
        local emptyCallOk, emptyResult = invoke(container, "Empty")
        removeOk = emptyCallOk and emptyResult ~= false
    end
    if not removeOk then return failedProjection() end
    local capacityCallOk, capacityResult = invoke(container, "setCapacity", capacity)
    if not capacityCallOk or capacityResult == false then return failedProjection() end
    if value.cleanAmount > EPSILON then
        local fluid = rawget(_G, "FluidType") and FluidType.Water
        if fluid == nil then return failedProjection() end
        local addCallOk, addResult = invoke(container, "addFluid", fluid, value.cleanAmount)
        if not addCallOk or addResult == false then return failedProjection() end
    end
    if value.taintedAmount > EPSILON then
        local fluid = rawget(_G, "FluidType") and FluidType.TaintedWater
        if fluid == nil then return failedProjection() end
        local addCallOk, addResult = invoke(container, "addFluid", fluid, value.taintedAmount)
        if not addCallOk or addResult == false then return failedProjection() end
    end
    -- This property is a compatibility gate, not a source of authority.  A
    -- missing method makes the projection unverifiable and is handled by the
    -- caller as a NEEDS_INIT/API failure.
    local lockCallOk, lockResult = invoke(container, "setInputLocked", true)
    return lockCallOk and lockResult ~= false
end

local function objectText(object)
    local parts = {}
    for _, method in ipairs({ "getType", "getObjectName", "getName" }) do
        local ok, value = invoke(object, method)
        if ok and value ~= nil then parts[#parts + 1] = lower(value) end
    end
    local spriteOk, sprite = invoke(object, "getSprite")
    if spriteOk and sprite then
        local ok, value = invoke(sprite, "getName")
        if ok and value ~= nil then parts[#parts + 1] = lower(value) end
    end
    return table.concat(parts, " ")
end

function M.findEntry(object)
    if object == nil then return nil end
    local ok, container = invoke(object, "getFluidContainer")
    if not ok or container == nil then return nil end
    local text = objectText(object)
    for _, entry in pairs(M.DEVICE_CATALOG) do
        for _, alias in ipairs(entry.aliases) do
            if string.find(text, lower(alias), 1, true) then return entry end
        end
    end
    return nil
end

function M.entryIsValidated(entry)
    return type(entry) == "table" and entry.runtimeValidated == true
end

return M
