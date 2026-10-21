require "ISUI/ISPanelJoypad"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "ISUI/ISContextMenu"

local DIALOG_WIDTH = 460
local DIALOG_HEIGHT = 225
local BUTTON_HEIGHT = 24

local TemplateDevelopmentDialog = ISPanelJoypad:derive("RVTemplateDevelopmentDialog")

local function addControl(parent, control)
    control:initialise()
    control:instantiate()
    parent:addChild(control)
    return control
end

function TemplateDevelopmentDialog:new(player, C)
    local screenWidth = getCore():getScreenWidth()
    local screenHeight = getCore():getScreenHeight()
    local x = math.max(0, (screenWidth - DIALOG_WIDTH) / 2)
    local y = math.max(0, (screenHeight - DIALOG_HEIGHT) / 2)
    local o = ISPanelJoypad.new(self, x, y, DIALOG_WIDTH, DIALOG_HEIGHT)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.85 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    o.C = C
    return o
end

function TemplateDevelopmentDialog:initialise()
    ISPanelJoypad.initialise(self)

    self.titleLabel = addControl(self, ISLabel:new(
        18, 14, 22,
        getText("ContextMenu_RailroaderRV_TemplateDevelopment_NewTemplate"),
        1, 1, 1, 1, UIFont.Small
    ))

    self.kindLabel = addControl(self, ISLabel:new(
        18, 50, 22,
        getText("UI_RailroaderRV_TemplateDevelopmentType"),
        1, 1, 1, 1, UIFont.Small
    ))
    self.kindCombo = ISComboBox:new(255, 46, 185, BUTTON_HEIGHT, self, nil)
    self.kindCombo:addOptionWithData(
        getText("ContextMenu_RailroaderRV_TemplateDevelopment_Loco"), "loco"
    )
    self.kindCombo:addOptionWithData(
        getText("ContextMenu_RailroaderRV_TemplateDevelopment_CarBox"), "car_box"
    )
    self.kindCombo.selected = 1
    addControl(self, self.kindCombo)

    self.northSouthLabel = addControl(self, ISLabel:new(
        18, 91, 22,
        getText("UI_RailroaderRV_TemplateDevelopmentNorthSouthLength"),
        1, 1, 1, 1, UIFont.Small
    ))
    self.northSouthLengthEntry = addControl(self, ISTextEntryBox:new(
        "", 255, 87, 100, BUTTON_HEIGHT
    ))

    self.eastWestLabel = addControl(self, ISLabel:new(
        18, 131, 22,
        getText("UI_RailroaderRV_TemplateDevelopmentEastWestWidth"),
        1, 1, 1, 1, UIFont.Small
    ))
    self.eastWestWidthEntry = addControl(self, ISTextEntryBox:new(
        "", 255, 127, 100, BUTTON_HEIGHT
    ))

    self.sizeHint = addControl(self, ISLabel:new(
        18, 160, 22,
        getText("UI_RailroaderRV_TemplateDevelopmentSize"),
        0.75, 0.75, 0.75, 1, UIFont.Small
    ))

    self.submitButton = addControl(self, ISButton:new(
        250, 187, 90, BUTTON_HEIGHT,
        getText("UI_RailroaderRV_TemplateDevelopmentSubmit"),
        self, TemplateDevelopmentDialog.onSubmit
    ))
    self.cancelButton = addControl(self, ISButton:new(
        350, 187, 90, BUTTON_HEIGHT,
        getText("UI_Cancel"), self, TemplateDevelopmentDialog.onCancel
    ))
end

function TemplateDevelopmentDialog:close()
    self:setVisible(false)
    self:removeFromUIManager()
end

function TemplateDevelopmentDialog:onCancel()
    self:close()
end

function TemplateDevelopmentDialog:onSubmit()
    local northSouthLength = tonumber(self.northSouthLengthEntry:getText())
    local eastWestWidth = tonumber(self.eastWestWidthEntry:getText())
    local kind = self.kindCombo:getOptionData(self.kindCombo.selected)
    local result = sendClientCommand(
        self.player,
        self.C.MOD_ID,
        self.C.COMMAND_RV_TEMPLATE_DEVELOPMENT,
        {
            operation = "new",
            kind = kind,
            northSouthLength = northSouthLength,
            eastWestWidth = eastWestWidth,
        }
    )
    self:close()
    return result
end

local function openNewTemplateDialog(player, C)
    local dialog = TemplateDevelopmentDialog:new(player, C)
    dialog:initialise()
    dialog:addToUIManager()
    dialog:setVisible(true)
    return dialog
end

local function sendKindCommand(player, C, operation, kind)
    return sendClientCommand(
        player,
        C.MOD_ID,
        C.COMMAND_RV_TEMPLATE_DEVELOPMENT,
        { operation = operation, kind = kind }
    )
end

local function addKindSubmenu(menu, player, C, operation, optionTextKey)
    local option = menu:addOption(getText(optionTextKey))
    local kindMenu = ISContextMenu:getNew(menu)
    menu:addSubMenu(option, kindMenu)
    kindMenu:addOption(
            getText("ContextMenu_RailroaderRV_TemplateDevelopment_Loco"),
        player, sendKindCommand, C, operation, "loco"
    )
    kindMenu:addOption(
            getText("ContextMenu_RailroaderRV_TemplateDevelopment_CarBox"),
        player, sendKindCommand, C, operation, "car_box"
    )
end

return function(ctx)
    local C = ctx.C

    local function onFillWorldObjectContextMenu(playerNum, context, _worldObjects, test)
        local player = getSpecificPlayer(playerNum)
        if not player
                or not player:getRole():hasCapability(Capability.UseDebugContextMenu) then
            return
        end

        if test then
            return ISWorldObjectContextMenu.setTest()
        end

        local rootOption = context:addOption(
            getText("ContextMenu_RailroaderRV_TemplateDevelopment")
        )
        local menu = ISContextMenu:getNew(context)
        context:addSubMenu(rootOption, menu)

        menu:addOption(
            getText("ContextMenu_RailroaderRV_TemplateDevelopment_NewTemplate"),
            player, openNewTemplateDialog, C
        )
        addKindSubmenu(
            menu, player, C, "edit",
            "ContextMenu_RailroaderRV_TemplateDevelopment_EditTemplate"
        )
        addKindSubmenu(
            menu, player, C, "save",
            "ContextMenu_RailroaderRV_TemplateDevelopment_SaveTemplate"
        )
    end

    Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
end
