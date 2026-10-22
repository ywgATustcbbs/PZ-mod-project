from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
CLIENT_FILE = (
    ROOT
    / "contents/mods/RailroaderRV/42/media/lua/client/"
    / "RailroaderRV/GUI/RV_FlatcarVisualClient.lua"
)


def lua_block(source: str, start: str, end: str) -> str:
    start_index = source.index(start)
    end_index = source.index(end, start_index)
    return source[start_index:end_index]


class FlatcarModelResolutionTests(unittest.TestCase):
    def test_raw_vehicle_model_file_is_used_when_no_model_script_exists(self) -> None:
        source = CLIENT_FILE.read_text(encoding="utf-8")
        helpers = lua_block(
            source,
            "local function encodedIdentifier",
            "local function appendCargoModel",
        )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            r"""
            Client = { visualGeneration = 4, dynamicModelScripts = {} }
            Cargo = { anchorAttachmentScale = 0.01,
                bodyLocation = "RVFlatcarCargoBody" }
            ANIMAL_MODEL_SCALE = 1.5
            math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
            ModelScript = {}
            function ModelScript.new()
                local model = {
                    loaded = {}, attachments = {}, scale = 1,
                    static = true,
                }
                function model:setModule(module) self.module = module end
                function model:InitLoadPP(name) self.name = name end
                function model:Load(name, body)
                    self.loaded[#self.loaded + 1] = body
                    self.mesh = body:match("mesh = ([^,%s]+)") or self.mesh
                    self.texture = body:match("texture = ([^,%s]+)")
                        or self.texture
                    local scale = body:match("scale = ([^,%s]+)")
                    if scale then self.scale = tonumber(scale) end
                    for attachment in body:gmatch("attachment ([%w_]+) {") do
                        self.attachments[#self.attachments + 1] = attachment
                    end
                end
                return model
            end
            module = { name = "RailroaderRV" }
            scriptManager = { scripts = {}, requested = {}, added = {} }
            function scriptManager:getModelScript(name)
                self.requested[#self.requested + 1] = name
                return self.scripts[name]
            end
            function scriptManager:getModule(name)
                assert(name == "RailroaderRV")
                return module
            end
            function scriptManager:addModelScript(model)
                model.fullName = module.name .. "." .. model.name
                self.scripts[model.fullName] = model
                self.added[#self.added + 1] = model
            end
            function getScriptManager() return scriptManager end
            """
            + helpers
            + r"""
            function buildCargoModel(modelData, visual, vehicleScript)
                local attachment = attachmentFor(modelData, visual,
                    vehicleScript, 0)
                local fullName = ensureDynamicModelScript(17, 100002,
                    "part_1_0", modelData, attachment, nil, "Vehicles/M163")
                return {
                    attachmentScale = attachment.scale,
                    fullName = fullName,
                    modelScript = scriptManager.added[1],
                }
            end
            rawModel = {
                model = "M163_Seat",
                partId = "SeatFrontLeft",
                wheelIndex = -1,
                offset = { x = 0, y = 0, z = 0 },
                rotate = { x = 0, y = 0, z = 0 },
                scale = 1,
            }
            visual = {
                modelScale = 1,
                body = { offset = { x = 0, y = 0, z = 0 } },
                parts = { rawModel },
            }
            result = buildCargoModel(rawModel, visual, {})
            """
        )

        result = lua.globals().result
        model_script = result["modelScript"]
        self.assertEqual(result["attachmentScale"], 1 / 1.5 / 0.01)
        self.assertEqual(model_script.mesh, "M163_Seat")
        self.assertEqual(model_script.texture, "Vehicles/M163")
        self.assertEqual(model_script.scale, 1)
        self.assertEqual(len(model_script.attachments), 1)
        self.assertEqual(model_script.attachments[1], "RVFlatcarCargoBody")
        requested = lua.globals().scriptManager.requested
        self.assertIn(
            "M163_Seat",
            [requested[index] for index in range(1, len(requested) + 1)],
        )

    def test_model_script_mesh_and_scale_are_preserved(self) -> None:
        source = CLIENT_FILE.read_text(encoding="utf-8")
        helpers = lua_block(
            source,
            "local function encodedIdentifier",
            "local function appendCargoModel",
        )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            r"""
            Client = { visualGeneration = 1, dynamicModelScripts = {} }
            Cargo = { anchorAttachmentScale = 0.01,
                bodyLocation = "RVFlatcarCargoBody" }
            ANIMAL_MODEL_SCALE = 1.5
            math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
            ModelScript = {}
            function ModelScript.new()
                local model = {
                    loaded = {}, attachments = {}, scale = 1,
                    static = true,
                }
                function model:setModule(module) self.module = module end
                function model:InitLoadPP(name) self.name = name end
                function model:Load(name, body)
                    self.loaded[#self.loaded + 1] = body
                    self.mesh = body:match("mesh = ([^,%s]+)") or self.mesh
                    self.texture = body:match("texture = ([^,%s]+)")
                        or self.texture
                    local scale = body:match("scale = ([^,%s]+)")
                    if scale then self.scale = tonumber(scale) end
                    for attachment in body:gmatch("attachment ([%w_]+) {") do
                        self.attachments[#self.attachments + 1] = attachment
                    end
                end
                return model
            end
            module = { name = "RailroaderRV" }
            sourceScript = {
                body = [=[model SourceModel {
                    mesh = vehicles/M163|Seat,
                    scale = 1.25,
                    attachment NativeSeat {
                        offset = 0 0 0,
                    }
                }]=],
            }
            function sourceScript:getMeshName()
                return "vehicles/M163|Seat"
            end
            function sourceScript:getLoadedScriptBodies()
                return { get = function(_, index)
                    assert(index == 1)
                    return sourceScript.body
                end }
            end
            function sourceScript:getLoadedScriptBodyCount() return 2 end
            scriptManager = { scripts = {}, added = {} }
            function scriptManager:getModelScript(name)
                return self.scripts[name]
            end
            function scriptManager:getModule(name)
                assert(name == "RailroaderRV")
                return module
            end
            function scriptManager:addModelScript(model)
                model.fullName = module.name .. "." .. model.name
                self.scripts[model.fullName] = model
                self.added[#self.added + 1] = model
            end
            function getScriptManager() return scriptManager end
            scriptManager.scripts["Base.M163_SeatScript"] = sourceScript
            """
            + helpers
            + r"""
            function buildCargoModel(modelData, visual)
                local attachment = attachmentFor(modelData, visual, {}, 0)
                local fullName = ensureDynamicModelScript(21, 100004,
                    "part_1_0", modelData, attachment, nil, nil)
                return {
                    attachmentScale = attachment.scale,
                    fullName = fullName,
                    modelScript = scriptManager.added[1],
                }
            end
            modelData = {
                model = "Base.M163_SeatScript",
                partId = "SeatFrontLeft",
                wheelIndex = -1,
                offset = { x = 0, y = 0, z = 0 },
                rotate = { x = 0, y = 0, z = 0 },
                scale = 1,
            }
            visual = {
                modelScale = 1,
                body = { offset = { x = 0, y = 0, z = 0 } },
                parts = { modelData },
            }
            result = buildCargoModel(modelData, visual)
            """
        )

        result = lua.globals().result
        model_script = result["modelScript"]
        self.assertAlmostEqual(result["attachmentScale"], 1.25 / 1.5 / 0.01)
        self.assertEqual(len(model_script.loaded), 2)
        self.assertEqual(model_script.mesh, "vehicles/M163|Seat")
        self.assertEqual(model_script.scale, 1)
        self.assertEqual(model_script.attachments[1], "NativeSeat")
        self.assertEqual(model_script.attachments[2], "RVFlatcarCargoBody")

    def test_network_table_identity_does_not_rebuild_existing_cargo(self) -> None:
        source = CLIENT_FILE.read_text(encoding="utf-8")
        function = lua_block(
            source,
            "local function attachCargoModels",
            "local function pinCargoVehicles",
        )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            r"""
            Cargo = { debug = function() end }
            detached, appended = 0, 0
            function detachCargoModels() detached = detached + 1 end
            function appendCargoModel() appended = appended + 1 end
            """
            + function
            + r"""
            function updateCargo(entry, car)
                attachCargoModels(entry, car, "17", 100002, 17)
            end
            entry = {
                animal = { hasActiveModel = function() return true end },
                attachmentsApplied = true,
                visual = {},
                vehicleScript = "Base.M163",
                attachedLocations = { "RVFlatcarCargoBody" },
            }
            oldVisual = entry.visual
            newVisual = { body = {}, parts = {} }
            tableIdentityChanged = oldVisual ~= newVisual
            updateCargo(entry, {
                visual = newVisual,
                vehicleScript = "Base.M163",
            })
            stillApplied = entry.attachmentsApplied
            stillSameOldTable = entry.visual == oldVisual
            """
        )

        self.assertTrue(lua.globals().stillApplied)
        self.assertTrue(lua.globals().stillSameOldTable)
        self.assertTrue(lua.globals().tableIdentityChanged)
        self.assertEqual(lua.globals().detached, 0)
        self.assertEqual(lua.globals().appended, 0)


if __name__ == "__main__":
    unittest.main()
