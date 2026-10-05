"""Offline behavior checks for direct roof-device timed actions."""

from __future__ import annotations

import json
from pathlib import Path
import re
import unittest

from lupa import LuaError, LuaRuntime


ROOT = Path(__file__).resolve().parents[2]
MOD_ROOT = ROOT / "RailroaderRV" / "contents" / "mods" / "RailroaderRV" / "42"
LUA_ROOT = MOD_ROOT / "media/lua"
CLIENT_ROOT = LUA_ROOT / "client/RailroaderRV/GUI"
WINDOW = CLIENT_ROOT / "RV_RoofDeviceWindow.lua"
CLIENT = CLIENT_ROOT / "RV_UtilityClient.lua"
INVENTORY = CLIENT_ROOT / "RV_UtilityInventory.lua"
TRANSLATIONS = [
    LUA_ROOT / "shared/Translate/CN/UI.json",
    LUA_ROOT / "shared/Translate/EN/UI.json",
]


LUA_STUBS = r"""
local function classBase()
    local base = {}
    function base:derive(name)
        local class = { Type = name }
        setmetatable(class, { __index = self })
        class.__index = class
        return class
    end
    function base:new(x, y, width, height)
        return setmetatable({ x = x, y = y, width = width,
            height = height, children = {}, visible = true }, self)
    end
    function base:initialise()
        if self.createChildren then self:createChildren() end
    end
    function base:addChild(child)
        self.children[#self.children + 1] = child
    end
    function base:titleBarHeight() return 32 end
    function base:setResizable(value) self.resizable = value end
    function base:setTitle(value) self.title = value end
    function base:setVisible(value) self.visible = value end
    function base:getIsVisible() return self.visible end
    function base:addToUIManager() self.visible = true end
    function base:removeFromUIManager() self.visible = false end
    function base:bringToTop() end
    function base:prerender() end
    function base:drawPolygon(_, _, _, _, _, _, _, _, _, r, g, b, a)
        self.fills = self.fills or {}
        self.fills[#self.fills + 1] = { r = r, g = g, b = b, a = a }
    end
    function base:drawLine() end
    function base:drawRect(x, y, width, height, a, r, g, b)
        self.rects = self.rects or {}
        self.rects[#self.rects + 1] = {
            x = x, y = y, width = width, height = height,
            a = a, r = r, g = g, b = b,
        }
    end
    function base:drawRectBorder() end
    function base:drawText() end
    function base:drawTextCentre() end
    function base:getMouseX() return 0 end
    function base:getMouseY() return 0 end
    return base
end

ISCollapsableWindow = classBase()
ISPanel = classBase()
ISCollapsableWindow.createChildren = function() end
package.preload["ISUI/ISCollapsableWindow"] = function()
    return ISCollapsableWindow
end
package.preload["ISUI/ISPanel"] = function() return ISPanel end

ISButton = {
    new = function(_, x, y, width, height, title, target, callback)
        return setmetatable({ x = x, y = y, width = width, height = height,
            title = title, target = target, callback = callback }, {
            __index = {
                initialise = function() end,
                setFont = function() end,
                setEnable = function(self, value) self.enabled = value end,
                getAbsoluteX = function(self) return self.x end,
                getAbsoluteY = function(self) return self.y end,
                getWidth = function(self) return self.width end,
            },
        })
    end,
}
package.preload["ISUI/ISButton"] = function() return ISButton end
ISContextMenu = { get = function() return {
    addOption = function() return {} end,
    addToUIManager = function() end,
} end }
package.preload["ISUI/ISContextMenu"] = function() return ISContextMenu end

UIFont = { Small = "Small", Medium = "Medium" }
getText = function(key) return key end
getItemNameFromFullType = function(value) return value end
getTextManager = function() return { getFontHeight = function() return 12 end } end
getCore = function() return {
    getScreenWidth = function() return 1920 end,
    getScreenHeight = function() return 1080 end,
} end

local mapping = { rvId = "rv-a", generation = 1 }
RailroaderRV = {
    Constants = {
        MOD_ID = "RailroaderRV",
        COMMAND_RV_UTILITY = "utility",
        COMMAND_RV_UTILITY_MAPPING = "mapping",
        COMMAND_RV_UTILITY_SNAPSHOT = "snapshot",
        COMMAND_RV_UTILITY_ACK = "ack",
    },
    RailroaderContextMenu = {
        getUtilityMapping = function() return mapping end,
        acceptUtilityMapping = function(args)
            if args.ok ~= true then return false end
            mapping = { rvId = args.rvId, generation = args.generation }
            return true
        end,
        clearUtilityMapping = function() mapping = nil end,
    },
    UtilityDashboard = {},
}

local t1 = { id = "RV.A", roofCells = {
    { x = 0, y = 0, z = 2 }, { x = 1, y = 0, z = 2 },
} }
local t2 = { id = "RV.B", roofCells = {
    { x = 10, y = 0, z = 3 }, { x = 11, y = 0, z = 3 },
    { x = 12, y = 0, z = 3 },
} }
local templates = { ["RV.A"] = t1, ["RV.B"] = t2 }
package.preload["RailroaderRV/RoomTemplate/RV_RoomTemplate"] = function()
    return { get = function(templateId) return templates[templateId] end }
end

local lastCanPlaceTemplate
local roof = {
    DEVICE_SOLAR = "SOLAR", DEVICE_WIND = "WIND",
    DEVICE_FUEL = "FUEL", DEVICE_RAIN = "RAIN",
    cells = function(template) return template.roofCells end,
    typeForItem = function(fullType)
        if fullType == "RailroaderRV.WindTurbine" then return "WIND" end
        if fullType == "RailroaderRV.SolarPanel" then return "SOLAR" end
        if fullType == "Base.BucketRainWater" then return "RAIN" end
        return nil
    end,
    canPlace = function(template, devices, cell, deviceType)
        lastCanPlaceTemplate = template
        return deviceType == "WIND" or deviceType == "SOLAR"
    end,
    deviceAt = function(devices, cell)
        for _, device in ipairs(devices) do
            if device.x == cell.x and device.y == cell.y
                    and device.z == cell.z then return device end
        end
        return nil
    end,
}
package.preload["RailroaderRV/Roof/RV_RoofDevices"] = function()
    return roof
end

package.preload["RailroaderRV/Common/RV_Constants"] = function()
    return RailroaderRV.Constants
end
package.preload["RailroaderRV/Common/RV_UtilitySprite"] = function()
    return { install = function() return true end }
end
local U = {
    POWER = {
        GENERATOR_TYPES = {
            ["RailroaderRV.WindTurbine"] = { renewableType = "WIND" },
        },
        RAIN_COLLECTOR_TYPE = "Base.BucketRainWater",
    },
    OP_ADD_FUEL = "add_fuel",
    OP_INSTALL_ROOF_DEVICE = "INSTALL_ROOF_DEVICE",
    OP_REMOVE_ROOF_DEVICE = "REMOVE_ROOF_DEVICE",
    OP_REQUEST_SNAPSHOT = "request_snapshot",
}
package.preload["RailroaderRV/Common/RV_UtilityConstants"] = function()
    return U
end

local actionClass = { created = {} }
function actionClass:new(character, operation, item, targetHint)
    local action = {
        character = character, operation = operation, item = item,
        targetHint = targetHint, jobReads = 0,
    }
    function action:setTime(value) self.duration = value end
    function action:begin()
        self.started = true
        self.action = { started = true }
    end
    function action:getJobDelta()
        assert(self.started, "job delta read before native action started")
        self.jobReads = self.jobReads + 1
        return 0.4
    end
    function action:forceStop()
        self.stopped = true
        if self.onRoofActionEnded then self.onRoofActionEnded(self) end
    end
    actionClass.created[#actionClass.created + 1] = action
    return action
end
package.preload["TimedActions/ISRVUtilityAction"] = function()
    return actionClass
end

local actionQueue = {
    queue = {}, current = nil, clearCount = 0, addCount = 0,
    nativeStopCount = 0,
}
function actionQueue:isCurrentActionAddingOtherActions() return false end
function actionQueue:clearQueue()
    self.clearCount = self.clearCount + 1
    for _, action in ipairs(self.queue) do
        if action ~= self.current then action.cancelled = true end
    end
    self.queue = {}
end
ISTimedActionQueue = {
    getTimedActionQueue = function() return actionQueue end,
    clear = function(character)
        local queue = ISTimedActionQueue.getTimedActionQueue(character)
        if not queue:isCurrentActionAddingOtherActions() then
            character:StopAllActionQueue()
        end
        queue:clearQueue()
        return queue
    end,
    add = function(action)
        actionQueue.addCount = actionQueue.addCount + 1
        if player.rejectNextAction then
            player.rejectNextAction = false
            return nil
        end
        actionQueue.queue[#actionQueue.queue + 1] = action
        if #actionQueue.queue == 1 then
            actionQueue.current = action
            action:begin()
        end
        return actionQueue
    end,
}

local sent = {}
sendClientCommand = function(player, module, command, args)
    sent[#sent + 1] = { player = player, module = module,
        command = command, args = args }
    return true
end
getSpecificPlayer = function() return player end
player = {
    setHaloNote = function() end,
    getPlayerNum = function() return 0 end,
    getInventory = function() return { getItems = function() return {} end } end,
        StopAllActionQueue = function()
        actionQueue.nativeStopCount = actionQueue.nativeStopCount + 1
        local current = actionQueue.current
        if current then current.nativeStopped = true end
        actionQueue.current = nil
    end,
    rejectNextAction = false,
}

local serverCommandListener
Events = {
    OnServerCommand = { Add = function(callback) serverCommandListener = callback end },
    OnConnected = { Add = function() end },
    OnDisconnect = { Add = function() end },
}

function harnessState()
    return actionQueue, actionClass.created, sent, t1, t2,
        function() return lastCanPlaceTemplate end
end
"""


class RoofUIBehaviorChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.client_source = CLIENT.read_text(encoding="utf-8")
        cls.window_source = WINDOW.read_text(encoding="utf-8")
        cls.inventory_source = INVENTORY.read_text(encoding="utf-8")

    def make_ui(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(LUA_STUBS)
        inventory = lua.execute(self.inventory_source)
        lua.globals().inventory = inventory
        lua.execute(
            'package.loaded["RailroaderRV/GUI/RV_UtilityInventory"] = inventory'
        )
        client = lua.execute(self.client_source)
        lua.globals().client = client
        lua.execute('package.loaded["RailroaderRV/GUI/RV_UtilityClient"] = client')
        roof_window = lua.execute(self.window_source)
        lua.globals().roofWindow = roof_window
        lua.execute(
            """
            RailroaderRV.RoofDeviceWindow = roofWindow
            RailroaderRV.UtilityDashboard.onSnapshot = function(player, snapshot)
                return roofWindow.onSnapshot(player, snapshot)
            end
            RailroaderRV.UtilityDashboard.onMappingChanged = function(player, mapping)
                return roofWindow.onMappingChanged(player, mapping)
            end
            RailroaderRV.UtilityDashboard.onConnectionReset = function()
                return roofWindow.onConnectionReset()
            end
            """
        )
        lua.globals().client = client
        lua.globals().roof_window = roof_window
        lua.globals().player_obj = lua.globals().player
        lua.execute("roof_window.show(player_obj)")
        lua.execute(
            """
            local w = roof_window.instance
            roof_window.onSnapshot(player_obj, {
                rvId = "rv-a", generation = 1,
                templateId = "RV.A", roofDevices = {},
            })
            """
        )
        lua.execute("sameRef = function(first, second) return rawequal(first, second) end")
        return lua, lua.globals().roof_window.instance

    def test_cell_click_clears_queue_then_tracks_native_started_action(self) -> None:
        lua, window = self.make_ui()
        queue, actions, sent, _, _, _ = lua.globals().harnessState()
        lua.execute(
            """
            local actionQueue = select(1, harnessState())
            oldAction = { kind = "unrelated", reads = 0 }
            function oldAction:getJobDelta() self.reads = self.reads + 1; error("unexpected queue scan") end
            queuedRoof = { operation = "INSTALL_ROOF_DEVICE",
                rvUtilityMappingKey = "rv-a:1" }
            function queuedRoof:getJobDelta() error("future progress must not be read") end
            actionQueue.queue = { oldAction, queuedRoof }
            actionQueue.current = oldAction
            """
        )
        self.assertIsNone(window.activeAction(window))
        window.prerender(window)
        sent_before_click = len(sent)
        lua.globals().item = lua.table_from({
            "id": 41,
            "type": "RailroaderRV.WindTurbine",
            "name": "wind turbine",
        })
        lua.execute(
            """
            item.getID = function(self) return self.id end
            item.getFullType = function(self) return self.type end
            item.getName = function(self) return self.name end
            roof_window.instance:selectItem(item)
            roof_window.instance:onCellClicked({ x = 0, y = 0, z = 2 })
            """,
        )
        self.assertEqual(queue.clearCount, 1)
        self.assertEqual(queue.addCount, 1)
        self.assertEqual(queue.nativeStopCount, 1)
        self.assertTrue(lua.globals().oldAction.nativeStopped)
        self.assertTrue(lua.globals().queuedRoof.cancelled)
        self.assertEqual(len(actions), 1)
        self.assertEqual(len(sent), sent_before_click)
        action = actions[1]
        self.assertTrue(action.started)
        self.assertEqual(action.item.id, 41)
        self.assertTrue(lua.globals().sameRef(window.activeRoofAction, action))

        lua.execute(
            """
            local actionQueue = select(1, harnessState())
            actionQueue.current = { kind = "other", getJobDelta = function() error("read current other action") end }
            actionQueue.queue = setmetatable({}, {
                __index = function() error("window scanned the timed-action queue") end,
                __len = function() error("window counted the timed-action queue") end,
            })
            roof_window.instance:prerender()
            """
        )
        self.assertEqual(action.jobReads, 1)
        self.assertTrue(lua.globals().sameRef(window.activeRoofAction, action))
        has_green_progress = lua.eval(
            "function(w) for _,r in ipairs(w.rects) do "
            "if r.g == 0.82 and r.b == 0.32 then return true end end "
            "return false end"
        )
        self.assertTrue(has_green_progress(window))
        self.assertFalse(window.addGeneratorButton.enabled)
        self.assertFalse(window.addRainButton.enabled)
        self.assertFalse(window.removeButton.enabled)
        self.assertFalse(any(
            sent[i].args.operation in (
                "START_ROOF_ACTION", "COMPLETE_ROOF_ACTION", "CANCEL_ROOF_ACTION"
            )
            for i in range(1, len(sent) + 1)
        ))

        lua.execute("local action=select(2, harnessState())[1]; action.onRoofActionEnded(action)")
        self.assertIsNone(window.activeRoofAction)
        self.assertTrue(window.addGeneratorButton.enabled)
        self.assertTrue(window.addRainButton.enabled)
        self.assertTrue(window.removeButton.enabled)

    def test_right_click_stops_native_action_and_clears_direct_ref(self) -> None:
        lua, window = self.make_ui()
        _, actions, _, _, _, _ = lua.globals().harnessState()
        lua.globals().item = lua.table_from({
            "id": 53, "type": "RailroaderRV.WindTurbine", "name": "turbine"
        })
        lua.execute(
            """
            item.getID = function(self) return self.id end
            item.getFullType = function(self) return self.type end
            item.getName = function(self) return self.name end
            roof_window.instance:selectItem(item)
            roof_window.instance:onCellClicked({ x = 1, y = 0, z = 2 })
            """,
        )
        action = actions[1]
        self.assertTrue(lua.globals().sameRef(window.activeRoofAction, action))
        window.onRightMouseDown(window, 0, 0)
        self.assertTrue(action.stopped)
        self.assertIsNone(window.activeRoofAction)
        self.assertTrue(window.addGeneratorButton.enabled)
        self.assertTrue(window.addRainButton.enabled)
        self.assertTrue(window.removeButton.enabled)

    def test_native_queue_rejection_clears_prepared_direct_ref(self) -> None:
        lua, window = self.make_ui()
        queue, actions, _, _, _, _ = lua.globals().harnessState()
        lua.globals().item = lua.table_from({
            "id": 58, "type": "RailroaderRV.WindTurbine", "name": "turbine"
        })
        lua.execute(
            """
            player.rejectNextAction = true
            item.getID = function(self) return self.id end
            item.getFullType = function(self) return self.type end
            item.getName = function(self) return self.name end
            roof_window.instance:selectItem(item)
            roof_window.instance:onCellClicked({ x = 1, y = 0, z = 2 })
            roof_window.instance:prerender()
            """,
        )
        self.assertEqual(queue.addCount, 1)
        self.assertEqual(len(actions), 1)
        self.assertFalse(actions[1].started)
        self.assertIsNone(window.activeRoofAction)
        self.assertIsNone(window.activeAction(window))
        self.assertTrue(window.addGeneratorButton.enabled)
        self.assertTrue(window.addRainButton.enabled)
        self.assertTrue(window.removeButton.enabled)

    def test_template_switch_and_device_opacity_states(self) -> None:
        lua, window = self.make_ui()
        _, _, _, template_a, template_b, get_template = lua.globals().harnessState()
        lua.execute(
            """
            roof_window.onSnapshot(player_obj, {
                rvId = "rv-a", generation = 1, templateId = "RV.A",
                roofDevices = { { x = 0, y = 0, z = 2, type = "SOLAR" } },
            })
            roof_window.instance.canvas:render()
            """
        )
        solar_fill = window.canvas.fills[1]
        self.assertAlmostEqual(solar_fill.a, 0.70)
        self.assertAlmostEqual(solar_fill.r, 1.0)
        self.assertEqual(len(window.canvas.entries), 2)

        window.selectionMode = "install"
        window.selectedType = "WIND"
        lua.execute("roof_window.instance.canvas.fills = {}")
        window.canvas.render(window.canvas)
        self.assertAlmostEqual(window.canvas.fills[2].a, 0.20)

        window.canvas.hoveredCell = window.canvas.entries[2].cell
        lua.execute("roof_window.instance.canvas.fills = {}")
        window.canvas.render(window.canvas)
        self.assertAlmostEqual(window.canvas.fills[2].a, 1.0)
        self.assertTrue(lua.globals().sameRef(get_template(), template_a))

        lua.execute(
            """
            roof_window.onSnapshot(player_obj, {
                rvId = "rv-a", generation = 1, templateId = "RV.B",
                roofDevices = {},
            })
            """
        )
        self.assertEqual(window.templateId, "RV.B")
        self.assertTrue(lua.globals().sameRef(window.template, template_b))
        self.assertEqual(len(window.canvas.entries), 3)
        self.assertTrue(lua.globals().sameRef(window.roofCells, template_b.roofCells))
        window.selectionMode = "install"
        window.selectedType = "WIND"
        window.canvas.render(window.canvas)
        self.assertTrue(lua.globals().sameRef(get_template(), template_b))

        lua.execute(
            """
            roof_window.onSnapshot(player_obj, {
                rvId = "rv-a", generation = 1, templateId = "RV.B",
                roofDevices = { { x = 10, y = 0, z = 3, type = "UNEXPECTED" } },
            })
            """
        )
        with self.assertRaises(LuaError):
            window.canvas.render(window.canvas)

    def test_mapping_change_stops_active_native_action_and_clears_ref(self) -> None:
        lua, window = self.make_ui()
        queue, actions, sent, _, _, _ = lua.globals().harnessState()
        lua.globals().item = lua.table_from({
            "id": 81,
            "type": "RailroaderRV.WindTurbine",
            "name": "wind turbine",
        })
        lua.execute(
            """
            item.getID = function(self) return self.id end
            item.getFullType = function(self) return self.type end
            item.getName = function(self) return self.name end
            roof_window.instance:selectItem(item)
            roof_window.instance:onCellClicked({ x = 0, y = 0, z = 2 })
            """,
        )
        self.assertEqual(len(actions), 1)
        active = actions[1]
        self.assertTrue(lua.globals().sameRef(window.activeRoofAction, active))

        lua.execute(
            "client.onServerCommand('RailroaderRV', 'mapping', "
            "{ ok=true, rvId='rv-b', generation=2 })"
        )
        self.assertTrue(active.stopped)
        self.assertIsNone(window.activeRoofAction)
        self.assertIsNone(window.snapshot)
        self.assertIsNone(lua.globals().client.getSnapshot())
        operations = [sent[i].args.operation for i in range(1, len(sent) + 1)]
        self.assertNotIn("CANCEL_ROOF_ACTION", operations)
        self.assertNotIn("COMPLETE_ROOF_ACTION", operations)
        self.assertNotIn("START_ROOF_ACTION", operations)

    def test_roof_window_translation_references_exist_in_both_languages(self) -> None:
        source = WINDOW.read_text(encoding="utf-8") + CLIENT.read_text(encoding="utf-8")
        references = {
            value for value in re.findall(
                r'"(UI_RailroaderRV_[A-Za-z0-9_]+)"', source
            )
        }
        catalogs = [json.loads(path.read_text(encoding="utf-8")) for path in TRANSLATIONS]
        for catalog in catalogs:
            missing = sorted(references.difference(catalog))
            self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
