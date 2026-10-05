-- Shared power-device profiles and unit conversions for the RV utility system.
RailroaderRV = RailroaderRV or {}
local P = {}

Recipe = Recipe or {}
Recipe.OnTest = Recipe.OnTest or {}
local RV_MOTOR_MOVEABLE_SPRITES = {
    ["appliances_laundry_01_0"] = true,
    ["appliances_laundry_01_1"] = true,
    ["appliances_laundry_01_2"] = true,
    ["appliances_laundry_01_3"] = true,
    ["appliances_laundry_01_4"] = true,
    ["appliances_laundry_01_5"] = true,
    ["appliances_laundry_01_6"] = true,
    ["appliances_laundry_01_7"] = true,
    ["appliances_cooking_01_68"] = true,
    ["appliances_cooking_01_69"] = true,
    ["appliances_cooking_01_70"] = true,
    ["appliances_cooking_01_71"] = true,
}
local RV_WATER_PUMP_MOVEABLE_SPRITES = {
    ["appliances_laundry_01_0"] = true,
    ["appliances_laundry_01_1"] = true,
    ["appliances_laundry_01_2"] = true,
    ["appliances_laundry_01_3"] = true,
    ["appliances_cooking_01_72"] = true,
    ["appliances_cooking_01_73"] = true,
    ["appliances_cooking_01_74"] = true,
    ["appliances_cooking_01_75"] = true,
    ["appliances_cooking_01_76"] = true,
    ["appliances_cooking_01_77"] = true,
    ["appliances_cooking_01_78"] = true,
    ["appliances_cooking_01_79"] = true,
}
local RV_DESKTOP_COMPUTER_MOVEABLE_SPRITES = {
    ["appliances_com_01_72"] = true,
}

local function allowRVMoveable(item, allowedSprites)
    if item:getScriptItem():getFullName() ~= "Base.Moveable" then
        return true
    end
    return allowedSprites[item:getType()] == true
end

function Recipe.OnTest.AssembleRVMotor(item, _character)
    return allowRVMoveable(item, RV_MOTOR_MOVEABLE_SPRITES)
end

function Recipe.OnTest.AssembleRVWaterPump(item, _character)
    return allowRVMoveable(item, RV_WATER_PUMP_MOVEABLE_SPRITES)
end

function Recipe.OnTest.AssembleRVSmartPowerController(item, _character)
    return allowRVMoveable(item, RV_DESKTOP_COMPUTER_MOVEABLE_SPRITES)
end

P.NUMERIC_EPSILON = 0.000001
P.MAX_GENERATORS = 32
P.MAX_FUEL_TANKS = 8
P.MAX_BATTERIES = 16
P.NATIVE_GENERATOR_CONDITION_MAX = 100
P.GENERATOR_INSTALL_TIME = 150
P.COMPONENT_INSTALL_TIME = 100
P.FUEL_ACTION_TICKS_PER_LITER = 25
-- Build 42 rain-collector sprites; 126/127 are their closed-lid states.
P.RAIN_COLLECTOR_MOVEABLE_SPRITES = {
    carpentry_02_54 = true,
    carpentry_02_120 = true,
    carpentry_02_122 = true,
    carpentry_02_124 = true,
    carpentry_02_126 = true,
    carpentry_02_127 = true,
}
P.GENERATOR_TYPES = {
    ["Base.Generator_Old"] = { class = "OLD", maxPowerW = 3000,
        baseFuelLPerHour = 0.15, fuelLPerKWh = 1.35 },
    ["Base.Generator"] = { class = "STANDARD", maxPowerW = 4000,
        baseFuelLPerHour = 0.10, fuelLPerKWh = 1.25 },
    ["Base.Generator_Blue"] = { class = "STANDARD", maxPowerW = 4000,
        baseFuelLPerHour = 0.10, fuelLPerKWh = 1.25 },
    ["Base.Generator_Yellow"] = { class = "ADVANCED", maxPowerW = 5000,
        baseFuelLPerHour = 0.08, fuelLPerKWh = 1.15 },
    ["RailroaderRV.SolarPanel"] = { class = "SOLAR",
        renewableType = "SOLAR", maxPowerW = 250,
        baseFuelLPerHour = 0, fuelLPerKWh = 0 },
    ["RailroaderRV.WindTurbine"] = { class = "WIND",
        renewableType = "WIND", maxPowerW = 400,
        baseFuelLPerHour = 0, fuelLPerKWh = 0 },
}

P.GAS_TANK_TYPES = {
    ["Base.SmallGasTank1"] = true,
    ["Base.NormalGasTank1"] = true,
    ["Base.BigGasTank1"] = true,
    ["Base.SmallGasTank2"] = true,
    ["Base.NormalGasTank2"] = true,
    ["Base.BigGasTank2"] = true,
    ["Base.SmallGasTank3"] = true,
    ["Base.NormalGasTank3"] = true,
    ["Base.BigGasTank3"] = true,
}

function P.gasTankCapacity(maxCapacity, condition)
    local adjustedCondition = condition + 20 * (100 - condition) / 100
    local adjustedCapacity = math.floor(math.max(5,
        maxCapacity * adjustedCondition / 100) * 100 + 0.5) / 100
    return math.floor(adjustedCapacity)
end

P.CHARGER_TYPE = "RailroaderRV.RVCharger"
P.INVERTER_TYPE = "RailroaderRV.RVInverter"
P.CONTROLLER_TYPE = "RailroaderRV.RVPowerController"
P.CIRCUIT_BREAKER_TYPE = "RailroaderRV.RVCircuitBreaker"

P.BATTERY_CAPACITY_WH = 720
P.BATTERY_MAX_CHARGE_W = 250
P.BATTERY_MAX_DISCHARGE_W = 1500
P.BATTERY_TYPES = {
    ["Base.CarBattery1"] = { capacity = 1, charge = 1, discharge = 1 },
    ["Base.CarBattery2"] = { capacity = 1.2, charge = 0.85, discharge = 1.1 },
    ["Base.CarBattery3"] = { capacity = 0.9, charge = 1.2, discharge = 1.2 },
}
P.BATTERY_CAPACITY_FACTOR = function(health)
    return 1 - (1 - health) * (1 - health)
end
P.BATTERY_CHARGE_FACTOR = P.BATTERY_CAPACITY_FACTOR
P.BATTERY_DISCHARGE_FACTOR = function(health)
    return health * health
end

P.DEVICE_POWER_W = {
    Light = 60,
    Radio = 15,
    TV = 100,
    Fridge = 125,
    Freezer = 150,
    FridgeFreezer = 160,
    Washer = 500,
    Dryer = 4500,
    Microwave = 2000,
    Stove = 3000,
    LuxuryOven = 4000,
}

P.CRAFT_EFFICIENCY_BASE = 0.75
P.CRAFT_EFFICIENCY_PER_ELECTRICAL = 0.02
P.CRAFT_EFFICIENCY_RANDOM_MIN = -0.05
P.CRAFT_EFFICIENCY_RANDOM_MAX = 0.05
P.CRAFT_EFFICIENCY_MIN = 0.70
P.CRAFT_EFFICIENCY_MAX = 0.98
P.COMPONENT_CONDITION_MAX = 1000

function P.batteryParameters(fullType, condition, maxCondition)
    local profile = P.BATTERY_TYPES[fullType]
    local health = math.max(0, math.min(1, condition / maxCondition))
    local capacityFactor = P.BATTERY_CAPACITY_FACTOR(health)
    local chargeFactor = P.BATTERY_CHARGE_FACTOR(health)
    local dischargeFactor = P.BATTERY_DISCHARGE_FACTOR(health)
    return {
        health = health,
        capacityWh = P.BATTERY_CAPACITY_WH * profile.capacity * capacityFactor,
        maxChargePowerW = P.BATTERY_MAX_CHARGE_W * profile.charge * chargeFactor,
        maxDischargePowerW = P.BATTERY_MAX_DISCHARGE_W * profile.discharge * dischargeFactor,
    }
end

function P.craftEfficiency(electricalLevel, randomOffset)
    return math.max(P.CRAFT_EFFICIENCY_MIN, math.min(P.CRAFT_EFFICIENCY_MAX,
        P.CRAFT_EFFICIENCY_BASE + electricalLevel * P.CRAFT_EFFICIENCY_PER_ELECTRICAL
            + randomOffset))
end

return P
