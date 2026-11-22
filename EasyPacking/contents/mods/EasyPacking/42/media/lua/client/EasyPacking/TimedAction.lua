require "TimedActions/ISBaseTimedAction"

local Access = require "EasyPacking/Access"

local TimedAction = ISBaseTimedAction:derive("EasyPackingTimedAction")
local activeProgressItems = {}
local activeProgressItemCount = 0

function TimedAction.registerProgressItem(item)
    local itemId = item:getID()
    if not activeProgressItems[itemId] then
        activeProgressItems[itemId] = true
        activeProgressItemCount = activeProgressItemCount + 1
    end
end

function TimedAction.clearProgressItem(item)
    local itemId = item:getID()
    if activeProgressItems[itemId] then
        activeProgressItems[itemId] = nil
        activeProgressItemCount = activeProgressItemCount - 1
    end
end

function TimedAction.isProgressItem(item)
    return activeProgressItems[item:getID()] == true
end

function TimedAction.hasActiveProgress()
    return activeProgressItemCount > 0
end

local function parcelRecords(item)
    local parcelData = item:getModData().EasyPackingParcel
    return parcelData and parcelData.records or nil
end

function TimedAction.durationForWeight(weight)
    local minutes = math.max(1, math.min(weight / 40, 2.5))
    return minutes * getGameTime():getMinutesPerDay() * 2
end

function TimedAction:isValidStart()
    return self:isValid()
end

function TimedAction:isValid()
    if Access.locate(self.character, self.item) == nil then
        return false
    end

    if self.command == "Take" then
        local records = parcelRecords(self.item)
        return records ~= nil
            and #records > 0
            and (self.count == nil or (self.count > 0 and self.count < #records))
    end

    return not Access.isParcel(self.item) and Access.canPack(self.item)
end

function TimedAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
    self:setOverrideHandModels(nil, nil)
    for _, item in ipairs(self.progressItems) do
        TimedAction.registerProgressItem(item)
        item:setJobType(self.jobType)
        item:setJobDelta(0.01)
    end
end

function TimedAction:update()
    local progress = self:getJobDelta()
    for _, item in ipairs(self.progressItems) do
        item:setJobDelta(progress)
    end
end

function TimedAction:clearProgress()
    for _, item in ipairs(self.progressItems) do
        item:setJobDelta(0)
        TimedAction.clearProgressItem(item)
    end
end

function TimedAction:stop()
    self:clearProgress()
    ISBaseTimedAction.stop(self)
end

function TimedAction:perform()
    self:clearProgress()
    sendClientCommand(self.character, "EasyPacking", self.command, {
        id = self.itemId,
        count = self.count,
    })
    ISBaseTimedAction.perform(self)
end

function TimedAction:adjustMaxTime(maxTime)
    return maxTime
end

function TimedAction:new(character, item, command, count, weight, progressItems)
    local action = ISBaseTimedAction.new(self, character)
    action.item = item
    action.itemId = item:getID()
    action.command = command
    action.count = count
    action.maxTime = TimedAction.durationForWeight(weight)
    action.jobType = getText(command == "Take"
        and "ContextMenu_EasyPacking_Progress_Taking"
        or "ContextMenu_EasyPacking_Progress_Packing")
    action.progressItems = progressItems
    return action
end

return TimedAction
