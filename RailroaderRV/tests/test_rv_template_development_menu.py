from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "contents/mods/RailroaderRV/42/media/lua"
OFFICIAL_CONTEXT_MENU = (
    ROOT.parent / "official lua scripts/client/ISUI/ISWorldObjectContextMenu.lua"
)


def official_discovery_set_test() -> str:
    source = OFFICIAL_CONTEXT_MENU.read_text(encoding="utf-8")
    assert 'triggerEvent("OnFillWorldObjectContextMenu", player, context, worldobjects, test);' in source
    assert "if test then return ISWorldObjectContextMenu.Test end" in source

    start = source.index("function ISWorldObjectContextMenu.setTest()")
    end = source.index("\nend", start) + len("\nend")
    return source[start:end]


def make_lua() -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    set_test_function = official_discovery_set_test()
    client = MOD / "client"
    lua.execute(
        "package.path = "
        + repr(f"{client.as_posix()}/?.lua;")
        + " .. package.path"
    )
    lua.execute(
        r"""
        local function makeControlMethods(control)
            function control:initialise()
                self.children = {}
                self.childrenInOrder = {}
            end
            function control:instantiate()
                local javaObject = {
                    owner = self,
                    children = {},
                }
                function javaObject:AddChild(child)
                    child.parent = self
                    self.children[#self.children + 1] = child
                end
                function javaObject:setVisible(visible)
                    self.visible = visible
                end
                self.javaObject = javaObject
                if self.createChildren then self:createChildren() end
            end
            function control:createChildren() end
            function control:getParent()
                return self.parent
            end
            function control:addChild(child)
                if self.javaObject == nil then self:instantiate() end
                if child.javaObject == nil then child:instantiate() end
                self.children = self.children or {}
                self.children[#self.children + 1] = child
                self.childrenInOrder = self.childrenInOrder or {}
                self.childrenInOrder[#self.childrenInOrder + 1] = child
                self.javaObject:AddChild(child.javaObject)
                child.parent = self
            end
            function control:addToUIManager()
                if self.javaObject == nil then self:instantiate() end
                UIManager.AddUI(self.javaObject)
            end
            function control:setVisible(visible)
                if self.javaObject == nil then self:instantiate() end
                self.javaObject:setVisible(visible)
            end
            function control:removeFromUIManager()
                self.removed = true
            end
            return control
        end

        ISPanelJoypad = {}
        function ISPanelJoypad:derive(name)
            local class = { typeName = name }
            setmetatable(class, { __index = self })
            class.__index = class
            return class
        end
        function ISPanelJoypad.new(self, x, y, width, height)
            local panel = {
                x = x, y = y, width = width, height = height, children = {},
                anchorLeft = true, anchorRight = false,
                anchorTop = true, anchorBottom = false,
                background = true,
            }
            return setmetatable(panel, self)
        end
        function ISPanelJoypad:initialise()
            self.children = {}
            self.childrenInOrder = {}
        end
        makeControlMethods(ISPanelJoypad)
        package.preload["ISUI/ISPanelJoypad"] = function()
            return ISPanelJoypad
        end

        ISLabel = {}
        function ISLabel:new(x, y, height, name, r, g, b, a, font)
            local label = makeControlMethods({
                x = x, y = y, height = height, name = name,
                color = { r = r, g = g, b = b, a = a }, font = font,
                visible = true,
            })
            function label:setName(value) self.name = value end
            return label
        end
        package.preload["ISUI/ISLabel"] = function() return ISLabel end

        ISButton = {}
        function ISButton:new(x, y, width, height, title, target, onclick)
            return makeControlMethods({
                x = x, y = y, width = width, height = height,
                title = title, target = target, onclick = onclick,
            })
        end
        package.preload["ISUI/ISButton"] = function() return ISButton end

        ISTextEntryBox = {}
        function ISTextEntryBox:new(title, x, y, width, height)
            local entry = makeControlMethods({
                title = title, text = title,
                x = x, y = y, width = width, height = height,
            })
            function entry:getText() return self.text end
            function entry:setText(value) self.text = value end
            return entry
        end
        package.preload["ISUI/ISTextEntryBox"] = function()
            return ISTextEntryBox
        end

        ISComboBox = {}
        function ISComboBox:new(x, y, width, height, target, onChange)
            local combo = makeControlMethods({
                x = x, y = y, width = width, height = height,
                target = target, onChange = onChange,
                options = {}, selected = 0,
            })
            function combo:addOptionWithData(text, data)
                self.options[#self.options + 1] = { text = text, data = data }
                if self.selected == 0 then self.selected = 1 end
            end
            function combo:getOptionData(index)
                local option = self.options[index]
                return option and option.data or nil
            end
            return combo
        end
        package.preload["ISUI/ISComboBox"] = function() return ISComboBox end

        ISContextMenu = {}
        function ISContextMenu:newRoot()
            return setmetatable(
                { options = {}, subMenus = {} }, { __index = ISContextMenu }
            )
        end
        function ISContextMenu:getNew(parent)
            return setmetatable(
                { options = {}, subMenus = {}, parent = parent },
                { __index = ISContextMenu }
            )
        end
        function ISContextMenu:addOption(name, target, onSelect, ...)
            local params = { ... }
            local option = {
                name = name, target = target, onSelect = onSelect,
                param1 = params[1], param2 = params[2], param3 = params[3],
                param4 = params[4], param5 = params[5], param6 = params[6],
                param7 = params[7], param8 = params[8], param9 = params[9],
                param10 = params[10],
            }
            self.options[#self.options + 1] = option
            return option
        end
        function ISContextMenu:addSubMenu(option, menu)
            option.subMenu = menu
            self.subMenus[#self.subMenus + 1] = menu
        end
        package.preload["ISUI/ISContextMenu"] = function()
            return ISContextMenu
        end

        UIFont = { Small = "small" }
        function getText(key) return key end
        function getCore()
            return {
                getScreenWidth = function() return 1280 end,
                getScreenHeight = function() return 720 end,
            }
        end

        shownPanels = {}
        UIManager = {
            AddUI = function(panel)
                shownPanels[#shownPanels + 1] = panel
            end,
        }
        Capability = { UseDebugContextMenu = "UseDebugContextMenu" }
        activePlayer = {
            debugContextMenuEnabled = false,
            role = {
                useDebugContextMenu = false,
                hasCapability = function(self, capability)
                    return capability == Capability.UseDebugContextMenu
                        and self.useDebugContextMenu
                end,
            },
            getRole = function(self) return self.role end,
            canUseDebugContextMenu = function(self)
                return self.debugContextMenuEnabled
            end,
        }
        function getSpecificPlayer(playerNum)
            if playerNum == 0 then return activePlayer end
            return nil
        end

        sentCommands = {}
        function sendClientCommand(player, module, command, args)
            sentCommands[#sentCommands + 1] = {
                player = player, module = module, command = command, args = args,
            }
            return "sent"
        end

        worldMenuHandler = nil
        Events = {
            OnFillWorldObjectContextMenu = {
                Add = function(callback) worldMenuHandler = callback end,
            },
        }

        function selectOption(option)
            return option.onSelect(
                option.target, option.param1, option.param2, option.param3,
                option.param4, option.param5, option.param6, option.param7,
                option.param8, option.param9, option.param10
            )
        end
        function optionNamed(menu, name)
            for _, option in ipairs(menu.options) do
                if option.name == name then return option end
            end
            return nil
        end
        function clickButton(button)
            return button.onclick(button.target, button)
        end
        function fieldCount(value)
            local count = 0
            for _ in pairs(value) do count = count + 1 end
            return count
        end
        function sameRef(first, second) return rawequal(first, second) end
        """
    )
    lua.execute("ISWorldObjectContextMenu = { Test = false }")
    lua.execute(set_test_function)
    lua.execute(
        r"""
        function triggerEvent(name, playerNum, context, worldObjects, test)
            if name == "OnFillWorldObjectContextMenu" then
                worldMenuHandler(playerNum, context, worldObjects, test)
            end
        end
        function discoverWorldContextMenu(playerNum, context, worldObjects)
            ISWorldObjectContextMenu.Test = false
            triggerEvent(
                "OnFillWorldObjectContextMenu", playerNum, context,
                worldObjects, true
            )
            return ISWorldObjectContextMenu.Test
        end
        """
    )
    lua.execute(
        r"""
        templateDevelopmentInit = require(
            "RailroaderRV/GUI/RV_TemplateDevelopment"
        )
        templateDevelopmentInit({
            C = {
                MOD_ID = "RailroaderRV",
                COMMAND_RV_TEMPLATE_DEVELOPMENT = "TemplateDevelopment",
            },
        })
        """
    )
    return lua


def build_menu(lua: LuaRuntime):
    lua.execute(
        r"""
        testContext = ISContextMenu:newRoot()
        worldMenuHandler(0, testContext, {}, false)
        """
    )
    return lua.globals().testContext


def named_option(lua: LuaRuntime, menu, name: str):
    option = lua.globals().optionNamed(menu, name)
    if option is None:
        raise AssertionError(f"missing context option: {name}")
    return option


def click(lua: LuaRuntime, option) -> None:
    lua.globals().selectOption(option)


class RVTemplateDevelopmentMenuTests(unittest.TestCase):
    def test_menu_uses_role_capability_not_debug_context_toggle(self) -> None:
        lua = make_lua()
        lua.execute("discoveryContext = ISContextMenu:newRoot()")
        denied = lua.globals().discoverWorldContextMenu(
            0, lua.globals().discoveryContext, lua.eval("{}")
        )
        self.assertFalse(denied)
        self.assertEqual(len(lua.globals().discoveryContext.options), 0)

        lua.execute("activePlayer.debugContextMenuEnabled = true")
        lua.execute("discoveryContext = ISContextMenu:newRoot()")
        denied_with_debug_toggle = lua.globals().discoverWorldContextMenu(
            0, lua.globals().discoveryContext, lua.eval("{}")
        )
        self.assertFalse(denied_with_debug_toggle)
        self.assertEqual(len(lua.globals().discoveryContext.options), 0)

        lua.execute(
            "activePlayer.role.useDebugContextMenu = true; "
            "activePlayer.debugContextMenuEnabled = false"
        )
        lua.execute("discoveryContext = ISContextMenu:newRoot()")
        discovered = lua.globals().discoverWorldContextMenu(
            0, lua.globals().discoveryContext, lua.eval("{}")
        )
        self.assertTrue(discovered)
        self.assertEqual(len(lua.globals().discoveryContext.options), 0)
        self.assertEqual(len(lua.globals().shownPanels), 0)
        self.assertEqual(len(lua.globals().sentCommands), 0)

        menu = build_menu(lua)
        self.assertEqual(len(menu.options), 1)
        self.assertEqual(
            menu.options[1].name,
            "ContextMenu_RailroaderRV_TemplateDevelopment",
        )
        edit_menu = named_option(
            lua, menu.options[1].subMenu,
            "ContextMenu_RailroaderRV_TemplateDevelopment_EditTemplate",
        ).subMenu
        self.assertEqual(len(edit_menu.options), 2)

    def test_new_template_dialog_sends_custom_dimensions_without_coords(self) -> None:
        lua = make_lua()
        lua.execute("activePlayer.role.useDebugContextMenu = true")
        root = build_menu(lua)
        dev_menu = root.options[1].subMenu
        new_option = named_option(
            lua, dev_menu,
            "ContextMenu_RailroaderRV_TemplateDevelopment_NewTemplate",
        )
        click(lua, new_option)

        dialog = lua.globals().shownPanels[1].owner
        java_dialog = lua.globals().shownPanels[1]
        self.assertTrue(lua.globals().sameRef(java_dialog, dialog.javaObject))
        self.assertEqual(len(java_dialog.children), 10)
        for control_name in (
            "titleLabel",
            "kindLabel",
            "kindCombo",
            "northSouthLabel",
            "northSouthLengthEntry",
            "eastWestLabel",
            "eastWestWidthEntry",
            "sizeHint",
            "submitButton",
            "cancelButton",
        ):
            control = getattr(dialog, control_name)
            self.assertTrue(
                lua.globals().sameRef(control.javaObject.parent, java_dialog),
                control_name,
            )
        self.assertEqual(dialog.width, 460)
        self.assertEqual(dialog.height, 225)
        self.assertTrue(dialog.background)
        self.assertTrue(dialog.anchorLeft)
        self.assertFalse(dialog.anchorRight)
        self.assertTrue(dialog.anchorTop)
        self.assertFalse(dialog.anchorBottom)
        self.assertTrue(java_dialog.visible)
        self.assertEqual(len(dialog.kindCombo.options), 2)
        self.assertEqual(dialog.kindCombo.options[2].data, "car_box")
        dialog.northSouthLengthEntry.setText(dialog.northSouthLengthEntry, "23")
        dialog.eastWestWidthEntry.setText(dialog.eastWestWidthEntry, "6")
        self.assertIsNone(dialog.northSouthLengthEntry.onlyNumbers)
        self.assertIsNone(dialog.eastWestWidthEntry.onlyNumbers)
        self.assertIsNone(dialog.errorLabel)
        dialog.kindCombo.selected = 2
        lua.globals().clickButton(dialog.submitButton)

        self.assertEqual(len(lua.globals().sentCommands), 1)
        command = lua.globals().sentCommands[1]
        self.assertTrue(
            lua.globals().sameRef(command.player, lua.globals().activePlayer)
        )
        self.assertEqual(command.module, "RailroaderRV")
        self.assertEqual(command.command, "TemplateDevelopment")
        self.assertEqual(command.args.operation, "new")
        self.assertEqual(command.args.kind, "car_box")
        self.assertEqual(command.args.northSouthLength, 23)
        self.assertEqual(command.args.eastWestWidth, 6)
        self.assertEqual(lua.globals().fieldCount(command.args), 4)
        self.assertTrue(dialog.removed)

    def test_edit_and_save_submenus_send_only_operation_and_kind(self) -> None:
        lua = make_lua()
        lua.execute("activePlayer.role.useDebugContextMenu = true")
        root = build_menu(lua)
        dev_menu = root.options[1].subMenu
        edit_menu = named_option(
            lua, dev_menu,
            "ContextMenu_RailroaderRV_TemplateDevelopment_EditTemplate",
        ).subMenu
        save_menu = named_option(
            lua, dev_menu,
            "ContextMenu_RailroaderRV_TemplateDevelopment_SaveTemplate",
        ).subMenu
        self.assertEqual(len(edit_menu.options), 2)
        self.assertEqual(len(save_menu.options), 2)

        click(lua, named_option(
            lua, edit_menu, "ContextMenu_RailroaderRV_TemplateDevelopment_Loco"
        ))
        click(lua, named_option(
            lua, save_menu, "ContextMenu_RailroaderRV_TemplateDevelopment_CarBox"
        ))

        self.assertEqual(len(lua.globals().sentCommands), 2)
        edit, save = lua.globals().sentCommands[1], lua.globals().sentCommands[2]
        self.assertEqual(edit.args.operation, "edit")
        self.assertEqual(edit.args.kind, "loco")
        self.assertEqual(lua.globals().fieldCount(edit.args), 2)
        self.assertEqual(save.args.operation, "save")
        self.assertEqual(save.args.kind, "car_box")
        self.assertEqual(lua.globals().fieldCount(save.args), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
