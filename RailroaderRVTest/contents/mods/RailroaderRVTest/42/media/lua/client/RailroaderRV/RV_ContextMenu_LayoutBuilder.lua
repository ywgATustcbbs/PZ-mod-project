-- RV_ContextMenu: manual layout-builder responsibilities.
return function(ctx)
local Client = ctx.Client
local C = ctx.C

local function requestLayoutCommand(playerObj, command)
    if playerObj and type(sendClientCommand) == "function" then
        sendClientCommand(playerObj, C.MOD_ID, command, {})
    end
end

function Client.requestLayoutBuild(playerObj)
    requestLayoutCommand(playerObj, C.COMMAND_LAYOUT_BUILD)
end

function Client.requestLayoutFinish(playerObj)
    requestLayoutCommand(playerObj, C.COMMAND_LAYOUT_FINISH)
end

function Client.onFillLayoutBuilderContextMenu(playerNum, context, worldObjects, test)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or playerObj:isDead() or not context then return end
    local buildLabel = getText("ContextMenu_RailroaderRVTest_BuildLayout")
    local finishLabel = getText("ContextMenu_RailroaderRVTest_FinishLayout")
    if test then
        context:addOption(buildLabel, playerObj, Client.requestLayoutBuild)
        context:addOption(finishLabel, playerObj, Client.requestLayoutFinish)
        if ISWorldObjectContextMenu and ISWorldObjectContextMenu.setTest then
            return ISWorldObjectContextMenu.setTest()
        end
        return true
    end
    context:addOption(buildLabel, playerObj, Client.requestLayoutBuild)
    context:addOption(finishLabel, playerObj, Client.requestLayoutFinish)
end

if Events and Events.OnFillWorldObjectContextMenu
    and type(Events.OnFillWorldObjectContextMenu.Add) == "function" then
    Events.OnFillWorldObjectContextMenu.Add(Client.onFillLayoutBuilderContextMenu)
end

return Client
end
