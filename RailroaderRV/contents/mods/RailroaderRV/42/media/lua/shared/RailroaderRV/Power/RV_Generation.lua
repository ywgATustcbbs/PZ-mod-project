-- Pure renewable generation formulas plus server-side world sampling.
local P = require("RailroaderRV/Power/RV_UtilityPowerConfig")
local M = {}

local solarPowerProfile = P.GENERATOR_TYPES["RailroaderRV.SolarPanel"]
local windPowerProfile = P.GENERATOR_TYPES["RailroaderRV.WindTurbine"]

function M.solarPowerW(hour, month, cloudIntensity,
    precipitationIntensity, fogIntensity)
    local dailySun = math.max(0,
        1.2 * math.sin(math.pi * (hour - 6) / 12))
    local seasonalSun = 0.75
        + 0.35 * math.cos(2 * math.pi * (month - 7) / 12)
    local sunIntensity = dailySun * seasonalSun
    local weatherFactor = sunIntensity
        * (1 - cloudIntensity * 0.5)
        * (1 - precipitationIntensity * 0.3)
        * (1 - fogIntensity * 0.2)
    return solarPowerProfile.maxPowerW * math.min(1, weatherFactor)
end

function M.windPowerW(windSpeedKph)
    if windSpeedKph < 10 then return 0 end
    if windSpeedKph < 45 then
        return windPowerProfile.maxPowerW
            * (windSpeedKph ^ 3 - 10 ^ 3) / (45 ^ 3 - 10 ^ 3)
    end
    if windSpeedKph < 90 then return windPowerProfile.maxPowerW end
    return 0
end

function M.currentSolarPowerW()
    local gameTime = getGameTime()
    local climate = getClimateManager()
    return M.solarPowerW(gameTime:getTimeOfDay(), gameTime:getMonth() + 1,
        climate:getCloudIntensity(), climate:getPrecipitationIntensity(),
        climate:getFogIntensity())
end

function M.currentWindPowerW()
    return M.windPowerW(getClimateManager():getWindspeedKph())
end

return M
