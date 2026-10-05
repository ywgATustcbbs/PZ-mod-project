require "TimedActions/ISBaseTimedAction"

local U = require("RailroaderRV/Common/RV_UtilityConstants")
local P = require("RailroaderRV/Power/RV_UtilityPowerConfig")
local Water = require("RailroaderRV/Water/RV_UtilityWaterConstants")

ISRVUtilityAction = ISBaseTimedAction:derive("ISRVUtilityAction")

local function serverUtility()
    return require("RailroaderRV/Core/RV_UtilityServer")
end

local function isWaterTransfer(operation)
    return operation == Water.OP_ADD_WATER_FROM_CONTAINER
        or operation == Water.OP_DRAW_WATER_FROM_SOURCE
end

function ISRVUtilityAction:isValid()
    if self.operation == U.OP_ADD_FUEL and not self.item then return false end
    if isClient() then return true end
    return serverUtility().validateTimedAction(self.character,
        self.operation, self.item, self.targetHint)
end

function ISRVUtilityAction:start()
    if self.operation == U.OP_ADD_FUEL then
        self:setActionAnim("refuelgascan")
        self:setOverrideHandModels(self.item:getStaticModel(), nil)
        self.sound = self.character:playSound("VehicleAddFuelFromCanister")
    else
        self:setActionAnim("Loot")
    end
end

function ISRVUtilityAction:update()
    if self.operation == U.OP_ADD_FUEL then
        self.item:setJobDelta(self:getJobDelta())
        self.item:setJobType(getText("ContextMenu_VehicleAddGas"))
        self.character:setMetabolicTarget(Metabolics.HeavyDomestic)
    else
        self.character:setMetabolicTarget(Metabolics.MediumWork)
    end
end

function ISRVUtilityAction:serverStart()
    if self.operation == U.OP_ADD_FUEL then
        local accepted, amount = serverUtility().beginFuelTimedAction(
            self.character, self.item)
        if not accepted then
            self.serverFuelInvalid = true
            self.netAction:forceComplete()
            return
        end
        self.serverFuelAmount = amount
        self.lastFuelProgress = 0
        emulateAnimEvent(self.netAction, 1000, "FuelProgress", nil)
        return
    end
    if not isWaterTransfer(self.operation) then return end
    local accepted = serverUtility().beginWaterTimedAction(self)
    if not accepted then
        self.serverWaterInvalid = true
        self.netAction:forceComplete()
        return
    end
    emulateAnimEvent(self.netAction, 1000, "WaterProgress", nil)
end

function ISRVUtilityAction:applyFuelProgress(progress)
    if self.serverFuelInvalid then return false end
    assert(progress >= self.lastFuelProgress and progress <= 1,
        "RV fuel action progress is outside its server action")
    local delta = self.serverFuelAmount * (progress - self.lastFuelProgress)
    if delta <= 0 then return true end
    local accepted = serverUtility().progressFuelTimedAction(
        self.character, self.item, delta)
    if not accepted then
        self.serverFuelInvalid = true
        self.netAction:forceComplete()
        return false
    end
    self.lastFuelProgress = progress
    return true
end

function ISRVUtilityAction:animEvent(event)
    if not isClient() and event == "FuelProgress" then
        self:applyFuelProgress(self.netAction:getProgress())
    elseif not isClient() and event == "WaterProgress" then
        serverUtility().progressWaterTimedAction(self)
    end
end

function ISRVUtilityAction:serverStop()
    if self.operation == U.OP_ADD_FUEL then
        if not self.serverFuelInvalid then self:applyFuelProgress(self.netAction:getProgress()) end
        serverUtility().finishFuelTimedAction(self.character)
        return
    end
    if isWaterTransfer(self.operation) then
        serverUtility().finishWaterTimedAction(self)
    end
end

function ISRVUtilityAction:complete()
    if not isClient() then
        if self.operation == U.OP_ADD_FUEL then
            if not self.serverFuelInvalid then self:applyFuelProgress(1) end
            serverUtility().finishFuelTimedAction(self.character)
        elseif isWaterTransfer(self.operation) then
            if not self.serverWaterInvalid then
                serverUtility().finishWaterTimedAction(self)
            end
        else
            local accepted = serverUtility().performTimedAction(self.character,
                self.operation, self.targetHint, self.item)
            return accepted == true
        end
    end
    return true
end

local function notifyActionEnded(self)
    local callback = self.onUtilityActionEnded
    if callback then
        self.onUtilityActionEnded = nil
        callback(self)
    end
    local callback = self.onRoofActionEnded
    if callback then
        self.onRoofActionEnded = nil
        callback(self)
    end
end

function ISRVUtilityAction:stop()
    if self.operation == U.OP_ADD_FUEL and self.item then
        self.item:setJobDelta(0)
        self.character:stopOrTriggerSound(self.sound)
    end
    notifyActionEnded(self)
    ISBaseTimedAction.stop(self)
end

function ISRVUtilityAction:perform()
    if self.operation == U.OP_ADD_FUEL and self.item then
        self.item:setJobDelta(0)
        self.character:stopOrTriggerSound(self.sound)
    end
    ISBaseTimedAction.perform(self)
    notifyActionEnded(self)
end

function ISRVUtilityAction:getDuration()
    if isWaterTransfer(self.operation) then return -1 end
    if self.operation == U.OP_ADD_FUEL then
        return math.max(1, self.item:getFluidContainer():getAmount()
            * P.FUEL_ACTION_TICKS_PER_LITER)
    end
    if self.operation == U.OP_INSTALL_ROOF_DEVICE
        or self.operation == U.OP_REMOVE_ROOF_DEVICE then
        return P.GENERATOR_INSTALL_TIME
    end
    return P.COMPONENT_INSTALL_TIME
end

function ISRVUtilityAction:adjustMaxTime(time)
    return ISBaseTimedAction.adjustMaxTime(self, time)
end

function ISRVUtilityAction:new(character, operation, item, targetHint, targetObject)
    local o = ISBaseTimedAction.new(self, character)
    o.operation = operation
    o.item = item
    o.targetHint = targetHint
    o.targetObject = targetObject
    o.maxTime = o:getDuration()
    return o
end

return ISRVUtilityAction
