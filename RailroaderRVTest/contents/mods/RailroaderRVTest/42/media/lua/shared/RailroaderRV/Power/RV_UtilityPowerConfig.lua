-- Tunable values and unit conversions for the virtual RV power system.
RailroaderRV = RailroaderRV or {}
local P = {}

P.FUEL_WH_PER_L = 1250
P.GAS_GENERATOR_POWER_W = 5000
P.VIRTUAL_FUEL_CAPACITY_L = 100
P.NATIVE_GENERATOR_CONDITION_MAX = 100
P.NUMERIC_EPSILON = 0.000001
P.IDLE_FUEL_FRACTION = 0.10
P.RESTART_CHARGE_FRACTION = 0.05
P.DEFAULT_CHARGER_EFFICIENCY = 0.90
P.DEFAULT_INVERTER_EFFICIENCY = 0.90

P.BATTERY_CAPACITY_WH = 720
P.BATTERY_MAX_CHARGE_W = 250
P.BATTERY_MAX_DISCHARGE_W = 1500
P.BATTERY_CHARGE_FACTOR = function(health)
    return 1 - (1 - health) * (1 - health)
end
P.BATTERY_CAPACITY_FACTOR = P.BATTERY_CHARGE_FACTOR
P.BATTERY_DISCHARGE_FACTOR = function(health)
    return health * health
end

P.DEVICE_SCAN_INTERVAL_TICKS = 10
P.DEVICE_SCAN_SQUARES_PER_TICK = 20
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

function P.batteryParameters(condition, maxCondition)
    if type(condition) ~= "number" or type(maxCondition) ~= "number"
        or maxCondition <= 0 then return nil end
    local health = math.max(0, math.min(1, condition / maxCondition))
    local capacityFactor = P.BATTERY_CAPACITY_FACTOR(health)
    local chargeFactor = P.BATTERY_CHARGE_FACTOR(health)
    local dischargeFactor = P.BATTERY_DISCHARGE_FACTOR(health)
    return {
        health = health,
        capacityWh = P.BATTERY_CAPACITY_WH * capacityFactor,
        maxChargePowerW = P.BATTERY_MAX_CHARGE_W * chargeFactor,
        maxDischargePowerW = P.BATTERY_MAX_DISCHARGE_W * dischargeFactor,
    }
end

function P.craftEfficiency(electricalLevel, randomOffset)
    electricalLevel = math.max(0, math.min(10, tonumber(electricalLevel) or 0))
    randomOffset = tonumber(randomOffset) or 0
    return math.max(P.CRAFT_EFFICIENCY_MIN, math.min(P.CRAFT_EFFICIENCY_MAX,
        P.CRAFT_EFFICIENCY_BASE + electricalLevel * P.CRAFT_EFFICIENCY_PER_ELECTRICAL
            + randomOffset))
end

return P
