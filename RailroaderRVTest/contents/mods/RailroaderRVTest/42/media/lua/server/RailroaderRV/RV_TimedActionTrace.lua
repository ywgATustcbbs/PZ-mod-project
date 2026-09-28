-- Temporary server-side trace for the vanilla sledgehammer demolition action.
-- Remove this module and its loader call after the demolition failure is fixed.

local Trace = {}

local PREFIX = "[RV-TimedActionTrace] "
local MARKER_KEY = "_RailroaderRVTimedActionTrace"
local nativeActionTraceEnabled = false
local nextActionSequence = 0
local unpackValues = (table and table.unpack) or unpack

local function safeText(value)
    local ok, result = pcall(tostring, value)
    if ok then return result end
    return "<tostring-error>"
end

local function safeField(target, key)
    if target == nil then return false, nil end
    local ok, value = pcall(function() return target[key] end)
    return ok, value
end

local function safeCall(target, methodName, ...)
    if target == nil then return false, nil end
    local methodOk, method = safeField(target, methodName)
    if not methodOk or type(method) ~= "function" then return false, nil end
    local result = { pcall(method, target, ...) }
    if not result[1] then return false, result[2] end
    return true, result[2]
end

local function valueOrUnknown(ok, value)
    if not ok then return "<unavailable>" end
    return safeText(value)
end

local function emit(message)
    local text = PREFIX .. message
    if type(print) == "function" then pcall(print, text) end
    if nativeActionTraceEnabled and type(log) == "function"
        and DebugType and DebugType.Action then
        pcall(log, DebugType.Action, text)
    end
end

local function emitCallPath(message)
    if not nativeActionTraceEnabled or not DebugType or not DebugType.Action
        or not LogSeverity or not LogSeverity.Trace then
        return
    end
    local stackOk, stackTrace = safeField(DebugType.Action, "printStackTrace")
    if stackOk and type(stackTrace) == "function" then
        pcall(stackTrace, DebugType.Action, LogSeverity.Trace, 14, PREFIX .. message)
    end
end

local function enableNativeActionTrace()
    if not DebugType or not DebugType.Action or not LogSeverity
        or not LogSeverity.Trace then
        emit("native DebugType.Action Trace API unavailable; use visible server console command: log Action Trace")
        return false
    end

    local setterOk, setter = safeField(DebugType.Action, "setLogSeverity")
    if not setterOk or type(setter) ~= "function" then
        emit("DebugType.Action:setLogSeverity unavailable; use visible server console command: log Action Trace")
        return false
    end

    local ok, err = pcall(setter, DebugType.Action, LogSeverity.Trace)
    if not ok then
        emit("could not enable native Action Trace: " .. safeText(err)
            .. "; use visible server console command: log Action Trace")
        return false
    end

    nativeActionTraceEnabled = true
    emit("native DebugType.Action Trace enabled; NetTimedAction accepted/rejected messages should be visible")
    return true
end

local function describeItem(item)
    if item == nil then return "item=nil" end

    local itemXOk, itemX = safeCall(item, "getX")
    local itemYOk, itemY = safeCall(item, "getY")
    local itemZOk, itemZ = safeCall(item, "getZ")
    local indexOk, objectIndex = safeCall(item, "getObjectIndex")
    local squareOk, square = safeCall(item, "getSquare")
    local spriteOk, sprite = safeCall(item, "getSprite")
    local spriteNameOk, spriteName = safeCall(sprite, "getName")

    local squareXYZ = "squareXYZ=<unavailable>"
    local squareLoaded = "squareLoaded=<unknown>"
    local squareObjectIndex = "squareObjectsIndex=<unknown>"
    local squareObjectCount = "squareObjectsCount=<unknown>"

    if squareOk and square ~= nil then
        local sxOk, sx = safeCall(square, "getX")
        local syOk, sy = safeCall(square, "getY")
        local szOk, sz = safeCall(square, "getZ")
        squareXYZ = "squareXYZ=" .. valueOrUnknown(sxOk, sx) .. ","
            .. valueOrUnknown(syOk, sy) .. "," .. valueOrUnknown(szOk, sz)

        local cellOk, cell
        if type(getCell) == "function" then
            cellOk, cell = pcall(getCell)
        end
        if cellOk and cell ~= nil and sxOk and syOk and szOk then
            local loadedOk, loadedSquare = safeCall(cell, "getGridSquare", sx, sy, sz)
            if loadedOk then
                squareLoaded = "squareLoaded=" .. safeText(loadedSquare ~= nil
                    and loadedSquare == square)
            end
        end

        local objectsOk, objects = safeCall(square, "getObjects")
        if objectsOk and objects ~= nil then
            local sizeOk, size = safeCall(objects, "size")
            if sizeOk and type(size) == "number" then
                squareObjectCount = "squareObjectsCount=" .. safeText(size)
                local indices = {}
                for i = 0, size - 1 do
                    local entryOk, entry = safeCall(objects, "get", i)
                    if entryOk and entry == item then
                        indices[#indices + 1] = safeText(i)
                    end
                end
                squareObjectIndex = "squareObjectsIndex="
                    .. (#indices > 0 and table.concat(indices, ",") or "<not-found>")
            end
        end
    elseif squareOk then
        squareLoaded = "squareLoaded=false"
    end

    return "item=" .. safeText(item)
        .. " itemXYZ=" .. valueOrUnknown(itemXOk, itemX) .. ","
        .. valueOrUnknown(itemYOk, itemY) .. "," .. valueOrUnknown(itemZOk, itemZ)
        .. " objectIndex=" .. valueOrUnknown(indexOk, objectIndex)
        .. " " .. squareXYZ .. " " .. squareLoaded .. " " .. squareObjectIndex
        .. " " .. squareObjectCount
        .. " sprite=" .. valueOrUnknown(spriteNameOk, spriteName)
end

local function describePlayer(character)
    if character == nil then return "character=nil" end
    local xOk, x = safeCall(character, "getX")
    local yOk, y = safeCall(character, "getY")
    local zOk, z = safeCall(character, "getZ")
    local userOk, username = safeCall(character, "getUsername")
    local accessOk, access = safeCall(character, "getAccessLevel")
    local buildCheatOk, buildCheat = safeCall(character, "isBuildCheat")
    local instantOk, instant = safeCall(character, "isTimedActionInstant")
    local menuCheatOk, menuCheat = safeField(ISBuildMenu, "cheat")

    return "player=" .. valueOrUnknown(userOk, username)
        .. " access=" .. valueOrUnknown(accessOk, access)
        .. " playerXYZ=" .. valueOrUnknown(xOk, x) .. ","
        .. valueOrUnknown(yOk, y) .. "," .. valueOrUnknown(zOk, z)
        .. " isBuildCheat=" .. valueOrUnknown(buildCheatOk, buildCheat)
        .. " isTimedActionInstant=" .. valueOrUnknown(instantOk, instant)
        .. " ISBuildMenu.cheat=" .. valueOrUnknown(menuCheatOk, menuCheat)
end

local function nextStageCount(action, stage)
    local countsOk, counts = safeField(action, "_rvTimedActionTraceCounts")
    if not countsOk or type(counts) ~= "table" then
        counts = {}
        pcall(function() action._rvTimedActionTraceCounts = counts end)
    end
    local count = (tonumber(counts[stage]) or 0) + 1
    pcall(function() counts[stage] = count end)
    return count
end

local function sequenceFor(action)
    local sequenceOk, sequence = safeField(action, "_rvTimedActionTraceSequence")
    if sequenceOk and sequence ~= nil then return sequence end
    nextActionSequence = nextActionSequence + 1
    sequence = nextActionSequence
    pcall(function() action._rvTimedActionTraceSequence = sequence end)
    return sequence
end

local function describeAction(action, stage, count)
    local typeOk, actionType = safeField(action, "Type")
    local nameOk, name = safeField(action, "name")
    local durationOk, duration = safeField(action, "maxTime")
    local cornerOk, corner = safeField(action, "cornerCounter")
    local frameOk, frame = safeField(action, "spriteFrame")
    local itemOk, item = safeField(action, "item")
    local characterOk, character = safeField(action, "character")

    return "seq=" .. safeText(sequenceFor(action))
        .. " stage=" .. stage .. " call=" .. safeText(count)
        .. " actionType=" .. valueOrUnknown(typeOk, actionType)
        .. " name=" .. valueOrUnknown(nameOk, name)
        .. " action=" .. safeText(action)
        .. " maxTime=" .. valueOrUnknown(durationOk, duration)
        .. " cornerCounter=" .. valueOrUnknown(cornerOk, corner)
        .. " spriteFrame=" .. valueOrUnknown(frameOk, frame)
        .. " " .. (itemOk and describeItem(item) or "item=<field-error>")
        .. " " .. (characterOk and describePlayer(character) or "character=<field-error>")
end

local function pack(...)
    return { n = select("#", ...), ... }
end

local function packedValues(values)
    local parts = {}
    for i = 1, values.n do
        parts[#parts + 1] = safeText(values[i])
    end
    return table.concat(parts, ",")
end

function Trace.install()
    if type(isClient) == "function" and isClient()
        and (type(isServer) ~= "function" or not isServer()) then
        return false, "client-only process"
    end

    local actionClass = rawget(_G, "ISDestroyStuffAction")
    if type(actionClass) ~= "table" then
        local requireOk, requireError = pcall(require, "TimedActions/ISDestroyStuffAction")
        actionClass = rawget(_G, "ISDestroyStuffAction")
        if not requireOk or type(actionClass) ~= "table" then
            emit("ISDestroyStuffAction class unavailable after require: " .. safeText(requireError))
            return false, "ISDestroyStuffAction unavailable"
        end
    end

    local existingMarkerOk, existingMarker = safeField(actionClass, MARKER_KEY)
    if existingMarkerOk and type(existingMarker) == "table"
        and existingMarker.installed == true then
        if type(print) == "function" then pcall(print, PREFIX .. "installed (already installed)") end
        return true, "already installed"
    end

    local originalComplete = actionClass.complete
    if type(originalComplete) ~= "function" then
        emit("ISDestroyStuffAction.complete is not callable; no wrapper installed")
        return false, "complete unavailable"
    end
    local originalServerStart = actionClass.serverStart
    local originalServerStop = actionClass.serverStop

    actionClass.serverStart = function(self, ...)
        local count = nextStageCount(self, "serverStart")
        local context = describeAction(self, "serverStart.enter", count)
        emit(context)
        emitCallPath(context .. " callPath")
        if type(originalServerStart) ~= "function" then return end
        local results = pack(originalServerStart(self, ...))
        emit("seq=" .. safeText(sequenceFor(self)) .. " stage=serverStart.return values="
            .. packedValues(results))
        return unpackValues(results, 1, results.n)
    end

    actionClass.serverStop = function(self, ...)
        local count = nextStageCount(self, "serverStop")
        local context = describeAction(self, "serverStop.enter", count)
        emit(context)
        emitCallPath(context .. " callPath")
        if type(originalServerStop) ~= "function" then return end
        local results = pack(originalServerStop(self, ...))
        emit("seq=" .. safeText(sequenceFor(self)) .. " stage=serverStop.return values="
            .. packedValues(results))
        return unpackValues(results, 1, results.n)
    end

    actionClass.complete = function(self, ...)
        local count = nextStageCount(self, "complete")
        local context = describeAction(self, "complete.enter", count)
        emit(context)
        emitCallPath(context .. " callPath")
        local args = pack(...)
        local ok, result = pcall(function()
            return pack(originalComplete(self, unpackValues(args, 1, args.n)))
        end)
        if not ok then
            emit("seq=" .. safeText(sequenceFor(self)) .. " stage=complete.error error="
                .. safeText(result) .. " " .. describeItem(self.item))
            error(result, 0)
        end
        local results = result
        emit("seq=" .. safeText(sequenceFor(self)) .. " stage=complete.return values="
            .. packedValues(results) .. " " .. describeItem(self.item))
        return unpackValues(results, 1, results.n)
    end

    actionClass[MARKER_KEY] = {
        installed = true,
        originalComplete = originalComplete,
        originalServerStart = originalServerStart,
        originalServerStop = originalServerStop,
    }

    enableNativeActionTrace()
    if type(print) == "function" then pcall(print, PREFIX .. "installed") end
    if nativeActionTraceEnabled and type(log) == "function"
        and DebugType and DebugType.Action then
        pcall(log, DebugType.Action,
            PREFIX .. "server wrappers installed for ISDestroyStuffAction.serverStart/serverStop/complete")
    end
    return true, "installed"
end

return Trace
