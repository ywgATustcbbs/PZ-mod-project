#!/usr/bin/env python3
"""Run static and contract checks for the Railroader RV test package.

This test intentionally uses only Python's standard library.  It never starts
the server or the game client; the local luaparse command is used only for the
existing Lua syntax check.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path


MOD_ID = "RailroaderRVTest"


class Checks:
    def __init__(self) -> None:
        self.failures: list[str] = []

    def true(self, condition: bool, message: str) -> None:
        if not condition:
            self.failures.append(message)


def aggregate_lua_sources(paths: list[Path]) -> str:
    return "\n".join(read_utf8(path) for path in paths if path.is_file())


def read_utf8(path: Path) -> str:
    """Read repository text while accepting either UTF-8 or UTF-8 with BOM."""

    return path.read_text(encoding="utf-8-sig")


def section(text: str, start: str, end: str) -> str | None:
    match = re.search(r"(?s)" + start + r"(.*?)" + end, text)
    return match.group(1) if match else None


def run_lua_syntax_checks(root: Path, checks: Checks) -> None:
    parser = root / ".rv-lua-parse" / "node_modules" / ".bin" / "luaparse.cmd"
    checks.true(parser.is_file(), f"local luaparse is missing: {parser}")
    if not parser.is_file():
        return

    lua_root = (
        root
        / "RailroaderRVTest"
        / "contents"
        / "mods"
        / MOD_ID
        / "42"
        / "media"
        / "lua"
    )
    for lua_file in sorted(lua_root.rglob("*.lua")):
        command = [str(parser), "--quiet", "--file", str(lua_file)]
        if os.name == "nt":
            # Windows cannot execute a .cmd file directly with shell=False.
            command = ["cmd.exe", "/d", "/c", *command]
        result = subprocess.run(
            command,
            cwd=root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        output = " ".join(
            part.strip() for part in (result.stdout, result.stderr) if part.strip()
        )
        checks.true(
            result.returncode == 0,
            f"Lua syntax parse failed: {lua_file} {output}".rstrip(),
        )


def lua_top_level_local_count(root: Path, lua_file: Path) -> int | None:
    """Count the locals active in a Lua chunk's main function.

    Kahlua's 200-local limit applies to the chunk scope, so nested function
    locals are intentionally not included.  Use the same local luaparse
    dependency as the syntax check instead of a regex that would count every
    nested helper variable.
    """

    module_root = root / ".rv-lua-parse" / "node_modules"
    script = (
        "const fs=require('fs'),p=require('luaparse');"
        "const a=p.parse(fs.readFileSync(process.argv[1],'utf8'));"
        "let n=0;for(const s of a.body){"
        "if(s.type==='LocalStatement')n+=s.variables.length;"
        "else if(s.type==='FunctionDeclaration'&&s.isLocal)n++;}"
        "process.stdout.write(String(n));"
    )
    try:
        result = subprocess.run(
            ["node", "-e", script, str(lua_file)],
            cwd=module_root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    try:
        return int(result.stdout.strip())
    except ValueError:
        return None


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    package_root = root / "RailroaderRVTest" / "contents" / "mods" / MOD_ID / "42"
    media_lua_root = package_root / "media" / "lua"
    server_root = media_lua_root / "server" / "RailroaderRV"
    client_root = media_lua_root / "client" / "RailroaderRV"
    shared_root = media_lua_root / "shared" / "RailroaderRV"
    server_path = server_root / "Core" / "RV_Server.lua"
    server_util_path = server_root / "Common" / "RV_ServerUtil.lua"
    server_world_path = server_root / "Common" / "RV_ServerWorld.lua"
    server_schema_path = server_root / "Common" / "RV_ServerSchema.lua"
    client_path = client_root / "GUI" / "RV_ContextMenu.lua"
    railroader_server_path = (
        server_root / "Core" / "RV_RailroaderServer.lua"
    )
    railroader_client_path = (
        client_root / "GUI" / "RV_RailroaderContextMenu.lua"
    )
    constants_path = shared_root / "Common" / "RV_Constants.lua"
    region_slots_path = shared_root / "RVMapping" / "RV_RegionSlots.lua"
    constants = read_utf8(constants_path) if constants_path.is_file() else ""
    region_slots = read_utf8(region_slots_path) if region_slots_path.is_file() else ""
    layout_path = shared_root / "RoomTemplate" / "RV_Layout.lua"
    template_path = shared_root / "RoomTemplate" / "RV_Template.lua"
    room_template_path = shared_root / "RoomTemplate" / "RV_RoomTemplate.lua"
    protection_manifest_path = shared_root / "RoomTemplate" / "RV_ProtectionManifest.lua"
    bitmap_path = shared_root / "Common" / "RV_Bitmap.lua"
    mapping_path = server_root / "RVMapping" / "RV_RailroaderServer_Mapping.lua"
    boundary_geometry_path = server_root / "BoundaryGuard" / "RV_BoundaryServer_Geometry.lua"
    boundary_sweep_path = server_root / "BoundaryGuard" / "RV_BoundaryServer_Sweep.lua"
    boundary_server_path = server_root / "BoundaryGuard" / "RV_BoundaryServer.lua"
    boundary_client_path = client_root / "GUI" / "RV_BoundaryClient.lua"
    boundary_wall_visuals_path = client_root / "GUI" / "RV_BoundaryWallVisuals.lua"
    protected_demolition_path = client_root / "GUI" / "RV_ProtectedDemolition.lua"
    wardrobe_visuals_path = client_root / "GUI" / "RV_WardrobeVisuals.lua"
    utility_catalog_path = shared_root / "Water" / "RV_UtilityCatalog.lua"
    utility_constants_path = shared_root / "Common" / "RV_UtilityConstants.lua"
    utility_context_path = client_root / "GUI" / "RV_UtilityContextMenu.lua"
    utility_client_path = client_root / "GUI" / "RV_UtilityClient.lua"
    utility_server_path = server_root / "Core" / "RV_UtilityServer.lua"
    utility_water_path = server_root / "Water" / "RV_UtilityWater.lua"
    utility_water_commands_path = server_root / "Water" / "RV_UtilityWater_Commands.lua"
    utility_water_ledger_path = server_root / "Water" / "RV_UtilityWater_Ledger.lua"
    utility_objects_path = server_root / "Water" / "RV_UtilityWater_Objects.lua"
    utility_plumbing_path = server_root / "Water" / "RV_UtilityWater_Plumbing.lua"
    utility_store_path = server_root / "Core" / "RV_UtilityStore.lua"
    utility_power_path = server_root / "Power" / "RV_UtilityPower.lua"
    utility_power_devices_path = server_root / "Power" / "RV_UtilityPowerDevices.lua"
    generation_build_path = server_root / "Construction" / "RV_Server_GenerationBuild.lua"
    generation_flow_path = server_root / "Construction" / "RV_Server_GenerationFlow.lua"
    generation_ack_path = server_root / "Construction" / "RV_Server_GenerationAck.lua"
    construction_path = server_root / "Construction" / "RV_Construction.lua"
    core_path = server_root / "Core" / "RV_Server_Core.lua"
    player_validation_path = server_root / "Construction" / "RV_Server_PlayerValidation.lua"
    roof_destinations_path = server_root / "RoofRefresh" / "RV_Server_RoofDestinations.lua"
    roof_relocation_path = server_root / "RoofRefresh" / "RV_Server_RoofRelocation.lua"
    roof_api_path = server_root / "RoofRefresh" / "RV_Server_RoofApi.lua"
    server_commands_path = server_root / "Core" / "RV_Server_Commands.lua"
    layout_builder_path = server_root / "RV_Server_LayoutBuilder.lua"
    layout_builder_client_path = client_root / "RV_ContextMenu_LayoutBuilder.lua"
    server_agent_path = server_root / "agent.md"
    room_ownership_path = server_root / "RoofRefresh" / "RV_Server_RoomOwnership.lua"
    record_validation_path = server_root / "RVMapping" / "RV_Server_RecordValidation.lua"
    adapter_roof_refresh_path = server_root / "RoofRefresh" / "RV_RailroaderServer_RoofRefresh.lua"
    adapter_roof_refresh_flow_path = server_root / "RoofRefresh" / "RV_RailroaderServer_RoofRefreshFlow.lua"
    adapter_tick_path = server_root / "Core" / "RV_RailroaderServer_Tick.lua"
    adapter_mapping_path = server_root / "RVMapping" / "RV_RailroaderServer_Mapping.lua"
    client_room_ownership_path = client_root / "GUI" / "RV_ContextMenu_RoomOwnership.lua"
    client_relocation_path = client_root / "GUI" / "RV_ContextMenu_Relocation.lua"
    world_objects_path = server_root / "Construction" / "RV_Server_WorldObjects.lua"
    template_protection_repair_path = server_root / "TemplateRecovery" / "RV_Server_TemplateProtectionRepair.lua"
    template_recovery_index_path = server_root / "TemplateRecovery" / "RV_TemplateRecoveryIndex.lua"
    entry_exit_path = server_root / "RVMapping" / "RV_RailroaderServer_EntryExit.lua"
    boundary_objects_path = server_root / "DemolitionProtection" / "RV_BoundaryServer_Objects.lua"
    start_bat_path = root / "testserver" / "steamcmd" / "380870" / "StartServer64 - test.bat"
    runner_path = root / "testserver" / "run_test.py"
    testserver_agent_path = root / "testserver" / "agent.md"
    readme_path = root / "RailroaderRVTest" / "README.md"
    mod_info_path = package_root / "mod.info"

    checks = Checks()
    tests_dir = Path(__file__).resolve().parent
    checks.true(
        not any(tests_dir.glob("*.ps1")),
        "PowerShell test files are disabled; use the Python test instead",
    )
    checks.true(server_path.is_file(), f"server Lua is missing: {server_path}")
    checks.true(server_util_path.is_file(), f"server utility Lua is missing: {server_util_path}")
    checks.true(server_world_path.is_file(), f"server world Lua is missing: {server_world_path}")
    checks.true(server_schema_path.is_file(), f"server schema Lua is missing: {server_schema_path}")
    checks.true(client_path.is_file(), f"client Lua is missing: {client_path}")
    checks.true(
        railroader_server_path.is_file(),
        f"Railroader server adapter is missing: {railroader_server_path}",
    )
    checks.true(
        railroader_client_path.is_file(),
        f"Railroader client adapter is missing: {railroader_client_path}",
    )
    checks.true(constants_path.is_file(), f"shared constants Lua is missing: {constants_path}")
    checks.true(template_path.is_file(), f"captured RV template Lua is missing: {template_path}")
    checks.true(bitmap_path.is_file(), f"shared bitmap Lua is missing: {bitmap_path}")
    for current_contract_path in (
        generation_build_path,
        generation_flow_path,
        generation_ack_path,
        construction_path,
        core_path,
        player_validation_path,
        roof_destinations_path,
        server_commands_path,
        room_ownership_path,
        record_validation_path,
        client_room_ownership_path,
        client_relocation_path,
        world_objects_path,
        template_protection_repair_path,
        template_recovery_index_path,
        entry_exit_path,
        boundary_objects_path,
    ):
        checks.true(
            current_contract_path.is_file(),
            f"current RV contract Lua is missing: {current_contract_path}",
        )
    checks.true(
        boundary_server_path.is_file(),
        f"boundary server Lua is missing: {boundary_server_path}",
    )
    checks.true(
        boundary_client_path.is_file(),
        f"boundary client Lua is missing: {boundary_client_path}",
    )
    checks.true(
        boundary_wall_visuals_path.is_file(),
        f"boundary wall visual Lua is missing: {boundary_wall_visuals_path}",
    )
    checks.true(
        protected_demolition_path.is_file(),
        f"protected demolition Lua is missing: {protected_demolition_path}",
    )
    checks.true(
        wardrobe_visuals_path.is_file(),
        f"wardrobe visual Lua is missing: {wardrobe_visuals_path}",
    )
    checks.true(
        protection_manifest_path.is_file(),
        f"protection manifest Lua is missing: {protection_manifest_path}",
    )
    for utility_path in (
        utility_catalog_path,
        utility_context_path,
        utility_client_path,
        utility_server_path,
        utility_water_path,
        utility_store_path,
        utility_power_path,
        utility_power_devices_path,
    ):
        checks.true(utility_path.is_file(), f"utility Lua is missing: {utility_path}")
    checks.true(start_bat_path.is_file(), f"server launcher batch is missing: {start_bat_path}")

    module_owned_files = (
        (server_path, server_root / "Core"),
        (server_util_path, server_root / "Common"),
        (server_world_path, server_root / "Common"),
        (server_schema_path, server_root / "Common"),
        (client_path, client_root / "GUI"),
        (railroader_server_path, server_root / "Core"),
        (railroader_client_path, client_root / "GUI"),
        (constants_path, shared_root / "Common"),
        (bitmap_path, shared_root / "Common"),
        (layout_path, shared_root / "RoomTemplate"),
        (template_path, shared_root / "RoomTemplate"),
        (room_template_path, shared_root / "RoomTemplate"),
        (mapping_path, server_root / "RVMapping"),
        (boundary_server_path, server_root / "BoundaryGuard"),
        (utility_catalog_path, shared_root / "Water"),
        (utility_water_path, server_root / "Water"),
        (utility_power_path, server_root / "Power"),
        (generation_flow_path, server_root / "Construction"),
        (room_ownership_path, server_root / "RoofRefresh"),
        (template_protection_repair_path, server_root / "TemplateRecovery"),
        (boundary_objects_path, server_root / "DemolitionProtection"),
    )
    checks.true(
        all(path.is_file() and path.parent == module_root
            for path, module_root in module_owned_files),
        "RV source implementations are missing from their declared owning modules",
    )

    if server_path.is_file() and client_path.is_file():
        server_facade = read_utf8(server_path)
        server_util = read_utf8(server_util_path) if server_util_path.is_file() else ""
        server_world = read_utf8(server_world_path) if server_world_path.is_file() else ""
        server_schema = read_utf8(server_schema_path) if server_schema_path.is_file() else ""
        generation_build = (
            read_utf8(generation_build_path) if generation_build_path.is_file() else ""
        )
        generation_flow = (
            read_utf8(generation_flow_path) if generation_flow_path.is_file() else ""
        )
        generation_ack = (
            read_utf8(generation_ack_path) if generation_ack_path.is_file() else ""
        )
        construction = (
            read_utf8(construction_path) if construction_path.is_file() else ""
        )
        core = read_utf8(core_path) if core_path.is_file() else ""
        player_validation = (
            read_utf8(player_validation_path)
            if player_validation_path.is_file()
            else ""
        )
        roof_destinations = (
            read_utf8(roof_destinations_path) if roof_destinations_path.is_file() else ""
        )
        server_commands = (
            read_utf8(server_commands_path) if server_commands_path.is_file() else ""
        )
        layout_builder = (
            read_utf8(layout_builder_path) if layout_builder_path.is_file() else ""
        )
        layout_builder_client = (
            read_utf8(layout_builder_client_path)
            if layout_builder_client_path.is_file()
            else ""
        )
        room_ownership = (
            read_utf8(room_ownership_path) if room_ownership_path.is_file() else ""
        )
        record_validation = (
            read_utf8(record_validation_path) if record_validation_path.is_file() else ""
        )
        client_room_ownership = (
            read_utf8(client_room_ownership_path)
            if client_room_ownership_path.is_file()
            else ""
        )
        client_relocation_source = (
            read_utf8(client_relocation_path)
            if client_relocation_path.is_file()
            else ""
        )
        world_objects = (
            read_utf8(world_objects_path) if world_objects_path.is_file() else ""
        )
        template_protection_repair = (
            read_utf8(template_protection_repair_path) if template_protection_repair_path.is_file() else ""
        )
        template_recovery_index = (
            read_utf8(template_recovery_index_path)
            if template_recovery_index_path.is_file()
            else ""
        )
        # Existing contract checks intentionally inspect one logical server
        # surface.  Include each require chunk, then normalize only the
        # private module qualifier so assertions continue to cover helpers
        # after the split.  Dedicated checks below still verify the facade's
        # imports and per-chunk local budgets.
        server = "\n".join((server_util, server_world, server_schema, server_facade))
        server = re.sub(r"\bServer(?:Util|World|Schema)\.", "", server)
        client = read_utf8(client_path)
        railroader_server = (
            read_utf8(railroader_server_path)
            if railroader_server_path.is_file()
            else ""
        )
        railroader_client = aggregate_lua_sources(
            [railroader_client_path]
            + sorted(railroader_client_path.parent.glob("RV_RailroaderContextMenu_*.lua"))
        )
        bitmap = read_utf8(bitmap_path) if bitmap_path.is_file() else ""
        mapping = read_utf8(mapping_path) if mapping_path.is_file() else ""
        boundary_geometry = (
            read_utf8(boundary_geometry_path)
            if boundary_geometry_path.is_file()
            else ""
        )
        boundary_sweep = (
            read_utf8(boundary_sweep_path)
            if boundary_sweep_path.is_file()
            else ""
        )
        captured_template = read_utf8(template_path) if template_path.is_file() else ""
        room_template = read_utf8(room_template_path) if room_template_path.is_file() else ""
        layout = read_utf8(layout_path) if layout_path.is_file() else ""
        protection_manifest = (
            read_utf8(protection_manifest_path)
            if protection_manifest_path.is_file()
            else ""
        )
        captured_template_rows = re.findall(
            r"(?m)^\s*\{x=-?\d+,\s*y=-?\d+,\s*z=-?\d+,\s*class=",
            captured_template,
        )
        template_object_pattern = re.compile(
            r'^\s*\{x=(?P<x>-?\d+), y=(?P<y>-?\d+), z=(?P<z>-?\d+), '
            r'class="(?P<class>[^"]+)", name="(?P<name>[^"]+)", '
            r'sprite="(?P<sprite>[^"]+)"(?:, north=(?P<north>true|false))?, '
            r'direction="(?P<direction>[^"]+)",\s*'
            r'state=\{(?P<state>[^}]*)\}\},?\s*$',
            re.MULTILINE,
        )
        captured_template_objects = [
            match.groupdict()
            for line in captured_template.splitlines()
            if (match := template_object_pattern.match(line)) is not None
        ]
        protection_object_pattern = re.compile(
            r'^\s*\{templateIndex=(?P<index>\d+), x=(?P<x>-?\d+), '
            r'y=(?P<y>-?\d+), z=(?P<z>-?\d+), class="(?P<class>[^"]+)", '
            r'name="(?P<name>[^"]+)", sprite="(?P<sprite>[^"]+)", '
            r'north=(?P<north>true|false|"none"), direction="(?P<direction>[^"]+)", '
            r'state=\{(?P<state>[^}]*)\}, protectionClass=(?P<protectionClass>[1-4])\},?\s*$',
            re.MULTILINE,
        )
        protection_objects = [
            match.groupdict()
            for line in protection_manifest.splitlines()
            if (match := protection_object_pattern.match(line)) is not None
        ]
        def state_fields(value: str) -> dict[str, str]:
            return dict(item.split("=", 1) for item in value.split(",") if item)

        protection_identity_matches_template = (
            len(captured_template_objects) == 412
            and len(protection_objects) == 412
            and [int(obj["index"]) for obj in protection_objects] == list(range(1, 413))
        )
        if protection_identity_matches_template:
            for captured, protected in zip(captured_template_objects, protection_objects):
                static_north = None if protected["north"] == '"none"' else protected["north"]
                if any(captured[field] != protected[field]
                    for field in ("x", "y", "z", "class", "name", "sprite", "direction")):
                    protection_identity_matches_template = False
                    break
                if captured["north"] != static_north or state_fields(captured["state"]) != state_fields(protected["state"]):
                    protection_identity_matches_template = False
                    break
        protection_class_by_index = {
            int(obj["index"]): int(obj["protectionClass"])
            for obj in protection_objects
        }
        protection_class_counts = {
            protection_class: sum(
                1 for value in protection_class_by_index.values()
                if value == protection_class
            )
            for protection_class in range(1, 5)
        }
        cab_classes_match = len(protection_objects) == 412 and all(
            protection_class_by_index.get(index) == 1
            for index, obj in enumerate(captured_template_objects, 1)
            if int(obj["z"]) == 0
            and -4 <= int(obj["x"]) <= 1
            and -2 <= int(obj["y"]) <= 1
        )
        east_cab_objects = [
            (index, obj)
            for index, obj in enumerate(captured_template_objects, 1)
            if int(obj["z"]) == 0
            and int(obj["x"]) == 2
            and -2 <= int(obj["y"]) <= 1
        ]
        east_cab_classes_match = len(protection_objects) == 412 \
            and len(east_cab_objects) == 6 \
            and all(
                protection_class_by_index.get(index)
                    == (3 if obj["name"] == "Wooden Wall" else 1)
                and obj["name"] in {"Wooden Wall", "Window"}
                for index, obj in east_cab_objects
            )
        south_shell_floors_stay_protected = len(protection_objects) == 412 and all(
            protection_class_by_index.get(index) == 3
            for index, obj in enumerate(captured_template_objects, 1)
            if int(obj["z"]) == 0
            and int(obj["x"]) in {-4, -3, -2, -1, 0, 1}
            and int(obj["y"]) == 2
            and obj["class"] == "IsoObject"
        )
        cab_opening_objects_outside_build_cells = [
            (index, obj)
            for index, obj in enumerate(captured_template_objects, 1)
            if (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["name"])
            in {
                (-4, 2, 0, "Window"),
                (1, 2, 0, "Wooden Door Frame"),
                (1, 2, 0, "Wooden Door"),
            }
        ]
        northwest_support_classes = [
            protection_class_by_index[index]
            for index, obj in enumerate(captured_template_objects, 1)
            if obj["name"] == "Wooden Wall"
            and (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
            in {(-4, -6, 0, "true"), (-4, -6, 0, "false")}
            and obj["sprite"] in {
                "walls_interior_house_02_32", "walls_interior_house_02_33"
            }
        ]
        protected_activity_corner_walls = [
            obj for obj in captured_template_objects
            if obj["name"] == "Wooden Wall"
            and (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
            in {
                (-4, 16, 0, "false"),
                (2, -6, 0, "false"),
                (2, 16, 0, "false"),
                (2, 17, 0, "false"),
            }
            and "doRender=false" in obj["state"]
            and "hoppable=false" in obj["state"]
        ]
        protected_wardrobe_tiles = [
            obj for obj in captured_template_objects
            if obj["name"] == "Dark Fancy Wardrobe"
            and obj["sprite"] in {"furniture_storage_01_24", "furniture_storage_01_25"}
        ]
        west_cab_wall_tiles = [
            obj for obj in captured_template_objects
            if obj["name"] == "Wooden Wall"
            and int(obj["x"]) == -4
            and int(obj["y"]) in {-2, -1, 0, 1}
            and int(obj["z"]) == 0
            and obj["north"] == "false"
        ]
        fence_sprites = {"fixtures_railings_01_36", "fixtures_railings_01_37"}
        fence_rows = [
            obj for obj in captured_template_objects
            if obj["class"] == "IsoThumpable" and obj["sprite"] in fence_sprites
        ]
        fence_keys = {
            (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
            for obj in fence_rows
        }
        wall_rows_by_key: dict[tuple[int, int, int, str | None], list[dict[str, str | None]]] = {}
        for obj in captured_template_objects:
            if obj["class"] != "IsoThumpable" or obj["name"] != "Wooden Wall":
                continue
            key = (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
            wall_rows_by_key.setdefault(key, []).append(obj)
        perimeter_keys = {
            *((x, -6, 0, "true") for x in range(-4, 2)),
            *((-4, y, 0, "false") for y in range(-6, 17)),
            *((2, y, 0, "false") for y in range(-6, 17)),
            *((x, 17, 0, "true") for x in range(-4, 2)),
            (2, 17, 0, "false"),
        }
        paired_keys = fence_keys & set(wall_rows_by_key)
        off_boundary_fence_keys = paired_keys - perimeter_keys
        boundary_fence_keys = paired_keys & perimeter_keys
        hidden_boundary_wall_rows = [
            wall
            for key in boundary_fence_keys
            for wall in wall_rows_by_key[key]
        ]
        expected_off_boundary_fence_keys = {
            (-4, -5, 0, "true"),
            (-4, 16, 0, "true"),
            (1, -5, 0, "true"),
            (1, 16, 0, "true"),
        }
        captured_shell_cells = {
            (int(x), int(y))
            for x, y in re.findall(
                r'(?m)^\s*\{x=(-?\d+), y=(-?\d+), z=0, '
                r'class="(?:IsoThumpable|IsoWindow)", '
                r'name="(?:Wooden Wall|Wooden Door Frame|Wooden Door|Window)",',
                captured_template,
            )
        }
        captured_roof_cells = {
            (int(x), int(y))
            for x, y in re.findall(
                r"(?m)^\s*\{x=(-?\d+), y=(-?\d+), z=1, class=",
                captured_template,
            )
        }
        northwest_west_wall_rows = [
            obj for obj in captured_template_objects
            if (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
            == (-4, -6, 0, "false")
            and obj["class"] == "IsoThumpable"
            and obj["name"] == "Wooden Wall"
            and obj["sprite"] == "walls_interior_house_02_32"
            and "doRender=false" in obj["state"]
            and "hoppable=false" in obj["state"]
        ]
        northwest_north_wall_rows = [
            obj for obj in captured_template_objects
            if (int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
            == (-4, -6, 0, "true")
            and obj["class"] == "IsoThumpable"
            and obj["name"] == "Wooden Wall"
            and obj["sprite"] == "walls_interior_house_02_33"
            and "doRender=false" in obj["state"]
            and "hoppable=false" in obj["state"]
        ]
        boundary_server = (
            read_utf8(boundary_server_path) if boundary_server_path.is_file() else ""
        )
        boundary_objects = (
            read_utf8(boundary_objects_path) if boundary_objects_path.is_file() else ""
        )
        boundary_client = (
            read_utf8(boundary_client_path) if boundary_client_path.is_file() else ""
        )
        boundary_wall_visuals = (
            read_utf8(boundary_wall_visuals_path)
            if boundary_wall_visuals_path.is_file()
            else ""
        )
        protected_demolition = (
            read_utf8(protected_demolition_path)
            if protected_demolition_path.is_file()
            else ""
        )
        wardrobe_visuals = (
            read_utf8(wardrobe_visuals_path)
            if wardrobe_visuals_path.is_file()
            else ""
        )
        entry_exit = read_utf8(entry_exit_path) if entry_exit_path.is_file() else ""
        utility_catalog = (
            read_utf8(utility_catalog_path) if utility_catalog_path.is_file() else ""
        )
        utility_constants = (
            read_utf8(utility_constants_path)
            if utility_constants_path.is_file() else ""
        )
        utility_context = (
            read_utf8(utility_context_path) if utility_context_path.is_file() else ""
        )
        utility_client = (
            read_utf8(utility_client_path) if utility_client_path.is_file() else ""
        )
        utility_server = (
            read_utf8(utility_server_path) if utility_server_path.is_file() else ""
        )
        utility_water = (
            read_utf8(utility_water_path) if utility_water_path.is_file() else ""
        )
        utility_water_commands = (
            read_utf8(utility_water_commands_path)
            if utility_water_commands_path.is_file() else ""
        )
        utility_water_ledger = (
            read_utf8(utility_water_ledger_path)
            if utility_water_ledger_path.is_file() else ""
        )
        utility_objects = (
            read_utf8(utility_objects_path) if utility_objects_path.is_file() else ""
        )
        utility_plumbing = (
            read_utf8(utility_plumbing_path) if utility_plumbing_path.is_file() else ""
        )
        utility_store = (
            read_utf8(utility_store_path) if utility_store_path.is_file() else ""
        )

        lua_server_root = server_root
        lua_client_root = client_root
        railroader_server = aggregate_lua_sources(
            [railroader_server_path]
            + sorted(server_root.rglob("RV_RailroaderServer_*.lua"))
        )
        boundary_server = aggregate_lua_sources(
            sorted(boundary_server_path.parent.glob("RV_BoundaryServer*.lua"))
            + [boundary_objects_path]
        )
        boundary_client = aggregate_lua_sources(
            [boundary_client_path, boundary_wall_visuals_path, wardrobe_visuals_path]
        )
        generation_flow_source = read_utf8(generation_flow_path) if generation_flow_path.is_file() else ""
        generation_ack_source = read_utf8(generation_ack_path) if generation_ack_path.is_file() else ""
        player_validation_source = read_utf8(player_validation_path) if player_validation_path.is_file() else ""
        roof_relocation_source = read_utf8(roof_relocation_path) if roof_relocation_path.is_file() else ""
        roof_api_source = read_utf8(roof_api_path) if roof_api_path.is_file() else ""
        adapter_roof_refresh_source = read_utf8(adapter_roof_refresh_path) if adapter_roof_refresh_path.is_file() else ""
        adapter_roof_refresh_flow_source = read_utf8(adapter_roof_refresh_flow_path) if adapter_roof_refresh_flow_path.is_file() else ""
        adapter_tick_source = read_utf8(adapter_tick_path) if adapter_tick_path.is_file() else ""
        adapter_mapping_source = read_utf8(adapter_mapping_path) if adapter_mapping_path.is_file() else ""
        # Keep the logical server surface complete as the codebase is split
        # into focused modules.  A hand-maintained list silently dropped the
        # roof, mapping, utility, and adapter chunks from older contracts.
        server_contract_paths = sorted(lua_server_root.rglob("*.lua"))
        server = aggregate_lua_sources(server_contract_paths)
        server = re.sub(r"\bServer(?:Util|World|Schema)\.", "", server)
        client = aggregate_lua_sources(
            sorted(lua_client_root.rglob("*.lua"))
        )

        checks.true(
            'require("RailroaderRV/Common/RV_ServerUtil")' in server_facade
            and 'require("RailroaderRV/Common/RV_ServerWorld")' in server_facade
            and 'require("RailroaderRV/Common/RV_ServerSchema")' in server_facade,
            "RV_Server facade does not load the split utility/world/schema modules",
        )
        local_budgets = (
            ("RV_Server.lua", server_path),
            ("RV_ServerUtil.lua", server_util_path),
            ("RV_ServerWorld.lua", server_world_path),
            ("RV_ServerSchema.lua", server_schema_path),
            ("RV_RailroaderServer.lua", railroader_server_path),
        )
        for label, lua_file in local_budgets:
            local_count = lua_top_level_local_count(root, lua_file)
            checks.true(
                local_count is not None and local_count < 200,
                f"{label} exceeds or cannot prove the Kahlua main-chunk local budget: {local_count}",
            )

        checks.true(
            all(token in utility_catalog for token in (
                'M.WATER_TAG_KEY = "RailroaderRVTestWater"',
                '"owner", "role", "rvId", "generation", "bitmapVersion", "slotIndex", "anchor"',
                "function M.readSinkIdentity", "function M.isCurrentWaterSink",
                "function M.isWaterPipedDevice", "function M.hasFluidContainer",
                "RegionSlots.indexToAnchor(tag.slotIndex)",
            ))
            and "UTILITY_ROLE_PROXY" not in utility_catalog
            and "proxyFingerprint" not in utility_catalog,
            "Water catalog does not enforce the new exact RV mapping identity and native sink capability",
        )
        water_options = section(
            utility_context,
            r"local function addWaterOptions",
            r"local function addDashboardOption",
        )
        checks.true(
            water_options is not None
            and "hasPipeWrench(player)" in utility_context
            and "localSlot(player, x, y, z)" in water_options
            and "Catalog.isCurrentWaterSink(object)" in water_options
            and "Catalog.isWaterPipedDevice(object)" in water_options
            and "Client.requestWaterConnection" in utility_context,
            "client water menu does not limit requests to reachable native sinks in an RV matrix slot",
        )
        checks.true(
            "function Client.requestWaterConnection" in utility_client
            and "hint.connected = connected" in utility_client
            and "U.OP_CONNECT_WATER_DEVICE" in utility_client
            and "return { x = x, y = y, z = z, objectIndex = index }" in utility_client
            and all(field not in utility_client for field in (
                "hint.rvId", "hint.generation", "hint.slotIndex", "hint.anchor",
            )),
            "client Water intent includes trusted RV identity or omits the target-only hint",
        )
        water_resolution = section(
            utility_objects,
            r"function M\.resolveSink",
            r"function M\.ensureSinkIdentity",
        )
        checks.true(
            water_resolution is not None
            and 'exactKeys(hint, { "x", "y", "z", "objectIndex", "connected" })' in utility_objects
            and "validContext(context, identity)" in water_resolution
            and "RegionSlots.indexForAnchor(anchor) ~= record.slotIndex" in utility_objects
            and "if x < region.minX" in water_resolution
            and "withinReach(context.player, x, y, z)" in water_resolution
            and "World.getSquare(cell, x, y, z)" in water_resolution
            and "findHintedObject(square, objectIndex)" in water_resolution
            and "Catalog.hasFluidContainer(object)" in water_resolution
            and "Catalog.isCurrentWaterSink(object, identity, record)" in water_resolution,
            "server does not re-resolve and validate the sink against current Mapping, range, loaded square, and exact identity",
        )
        checks.true(
            "function M.setConnection" in utility_water_commands
            and "hasPipeWrench(context and context.player)" in utility_water_commands
            and "Ledger.validateMapping(record.water" in utility_water_commands
            and "Objects.resolveSink(identity, context, hint)" in utility_water_commands
            and "Objects.ensureSinkIdentity" in utility_water_commands
            and "Plumbing.apply(sink.object, desired)" in utility_water_commands
            and "Store.commit(record, identity)" in utility_water_commands
            and "Plumbing.rollback(sink.object, detail.previous)" in utility_water_commands
            and "Objects.rollbackSinkIdentity" in utility_water_commands
            and "markNeedsReconcile(identity, record)" in utility_water_commands,
            "Water connect/disconnect lacks authoritative tool, identity, commit, and compensation gates",
        )
        checks.true(
            all(token in utility_plumbing for token in (
                '"getUsesExternalWaterSource"', '"setUsesExternalWaterSource"',
                '"sendObjectChange"', '"usesExternalWaterSource"',
                "canBeWaterPiped", '"transmitModData"',
                "function M.apply", "function M.rollback",
            ))
            and "observed.connected ~= connected" in utility_plumbing,
            "native external-water state lacks synchronization, postcondition, or compensation checks",
        )
        water_validator = section(
            utility_store,
            r"local function validWater\(value, identity\)",
            r"local function validGenerator",
        )
        checks.true(
            water_validator is None
            and "if type(value) == \"table\" and empty(value) and allowCreate == true then" in utility_store
            and "local function newWater()" in utility_store
            and "sinks = {}," in utility_store
            and "schemaVersion" not in utility_store
            and "local function newPower()" in utility_store,
            "Utility storage must initialize current records without nested schema tags",
        )
        checks.true(
            "function M.validateMapping" in utility_water_ledger
            and "function M.getEntry" in utility_water_ledger
            and "function M.newEntry" in utility_water_ledger
            and '"rvId", "generation", "bitmapVersion", "slotIndex",' in utility_store
            and "waterSinkKey(sink.x, sink.y, sink.z) ~= key" in utility_store
            and all(token not in utility_water + utility_water_commands + utility_water_ledger + utility_objects + utility_plumbing + utility_store for token in (
                "canonicalTank", "usageTank", "proxyLedger", "proxyFingerprint",
                "rv_hidden_proxy", "rv_hidden_usage_tank", "oldTagAlias", "ADD_WATER",
            ))
            and all(token not in constants + utility_constants for token in (
                "UTILITY_TANK_OFFSET", "UTILITY_PROXY_Z_OFFSET", "UTILITY_ROLE_TANK",
                "UTILITY_ROLE_PROXY", "UTILITY_WATER_CAPACITY", "OP_ADD_WATER",
                "AUTO_REFILL_PROVIDER", "WATER_STATE_DEFERRED",
            ))
            and "function M.detachDevice" not in utility_water,
            "new Water ledger retains a deprecated hidden tank/proxy, inventory-transfer, or compatibility path",
        )
        checks.true(
            "function Client.showInvalidRVData" in utility_client
            and "Delete this test save and recreate it." in utility_client
            and "OnObjectAdded" not in utility_server + utility_water + utility_water_commands,
            "Water schema failures do not tell players to rebuild, or automatic sink tagging was added",
        )

        checks.true(
            all(token in bitmap for token in (
                "newBitset", "toHex", "fromHex",
                "containsScope", "isActive", "isBuildable", "walkBounds",
                "inAABB", "edgeForSide", "bitmapVersion ~= C.BITMAP_VERSION",
            ))
            and "schemaVersion" not in bitmap
            and all(token not in bitmap for token in (
                "segmentValid", "nearestActive", "local function addTime",
                "local function sortUniqueTimes",
            )),
            "shared RV bitmap contract is incomplete or retains movement-history helpers",
        )
        checks.true(
            "local function exactKeys(value, expected)" in bitmap
            and "if not allowed[key] then return false end" in bitmap
            and "return count == #expected" in bitmap
            and "Bitmap.hasExactKeys = exactKeys" in bitmap
            and "local exactKeys = Bitmap.hasExactKeys" in boundary_server
            and "schemaVersion" not in boundary_geometry
            and "integer(managed.originX) ~= integer(bitmap.originX)" not in boundary_geometry
            and "not exactKeys(edge, fields)" in boundary_geometry,
            "bitmap codec retained a persisted schema-version or geometry cross-check",
        )
        checks.true(
            "function M.profileAdd" not in utility_catalog
            and "function M.profileSubtract" not in utility_catalog
            and "function M.entryIsValidated" not in utility_catalog
            and "function Boundary.managedContains" not in boundary_server
            and "function M.isLocked" not in utility_server
            and "function M.setPlayerContext" not in utility_water
            and "function M.emergencyQuarantine" not in utility_water
            and "emergency" not in utility_water
            and "local function fixtureTag" not in utility_water
            and "local function playerForObject" not in utility_client
            and "getLastAck" not in utility_client
            and "_sessionNonce" not in utility_client
            and "lastAck" not in utility_client
            and "playerFloor" not in read_utf8(layout_path)
            and 'local C = require("RailroaderRV/RV_Constants")' not in read_utf8(utility_context_path)
            and 'local C = require("RailroaderRV/Common/RV_Constants")' in read_utf8(
                utility_power_path
            )
            and "C.MOD_ID" in read_utf8(utility_power_path)
            and "C.GENERATOR_OFFSET" in read_utf8(utility_power_path),
            "retired internal APIs, dead helpers, diagnostic state, or redundant requires remain",
        )
        checks.true(
            "x + 1" in bitmap and "y + 1" in bitmap
            and 'edgeKey("W", x + 1' in bitmap
            and 'edgeKey("N", x, y + 1' in bitmap,
            "east/south shell ownership does not use adjacent PZ W/N hosts",
        )
        checks.true(
            '"^([NW]):(-?%d+):(-?%d+):(-?%d+)$"' in server
            and '"^([NW]):(-?%d+):(-?%d+):(-?%d+)$"' in boundary_geometry
            and '"^(N|W):' not in server
            and '"^(N|W):' not in boundary_server,
            "shell edge validators use unsupported Lua pattern alternation",
        )
        update_guard = section(
            boundary_geometry,
            r"local function updatePlayer",
            r"\n\nctx\.number",
        )
        fresh_boundary_position = section(
            boundary_geometry,
            r"local function playerPosition",
            r"\n\nlocal function playerCell",
        )
        checks.true(
            update_guard is not None
            and all(token in update_guard for token in (
                "Bitmap.walkBounds", "if bounds and Bitmap.inAABB(bounds.outer, position.x, position.y)",
                "currentSquareMatches(player, position)",
                "correction(player, boundary, state, record.rvPosition)",
                "relation.inside ~= true",
                "integer(rider.onlineId) ~= currentOnlineId",
                "local inManagedScope = Bitmap.containsScope(",
            ))
            and "not Bitmap.containsScope(boundary.bitmap" not in update_guard
            and re.search(
                r"local bounds = inManagedScope\s+and Bitmap\.walkBounds",
                update_guard,
            ) is not None
            and update_guard.find("if transitionActive(state)")
                < update_guard.find("if not currentSquareMatches(player, position)")
            and update_guard.find("if not currentSquareMatches(player, position)")
                < update_guard.find("correction(player, boundary, state, record.rvPosition)")
            and re.search(
                r"correction\(player, boundary, state, record\.rvPosition\)\s+return nil",
                update_guard,
            ) is not None
            and all(token not in update_guard for token in (
                "Bitmap.walkableFast", "Bitmap.isActive", "segmentValid",
                "nearestActive",
            ))
            and all(token not in boundary_geometry for token in (
                "lastValid", "lastPosition", "invalidSegment",
                "lastObservedBoundaryTick", "nextValidRecordTick",
                "recoveryCooldown", "BOUNDARY_RECOVERY_COOLDOWN_TICKS",
                "copyPosition", "segmentValid", "Bitmap.nearestActive",
            ))
            and "BOUNDARY_RECOVERY_COOLDOWN_TICKS" not in constants,
            "server boundary guard does not validate inside identity and defer safe entry correction",
        )
        checks.true(
            fresh_boundary_position is not None
            and all(token in fresh_boundary_position for token in (
                'call(player, "getX")', 'call(player, "getY")',
                'call(player, "getZ")', "finiteNumber(x)", "finiteNumber(y)",
                "finiteNumber(z)", "return { x = x, y = y, z = z }",
                "local inRVRegion =", "C.RV_REGION_SIZE * C.RV_REGION_SLOT_COLUMNS",
                "C.RV_REGION_SIZE * C.RV_REGION_SLOT_ROWS",
            )),
            "boundary guard does not read finite authoritative server positions",
        )
        checks.true(
            fresh_boundary_position is not None
            and "Boundary._states[id.key] == nil" not in fresh_boundary_position
            and "return { x = x, y = y, z = z }, inRVRegion" in fresh_boundary_position
            and "UNTRACKED_OUTSIDE_PROBE_RETRY_TICKS = 300" in boundary_sweep
            and "#coldOutsideCandidates > 0" in boundary_sweep
            and "untrackedOutsideProbeCursor" in boundary_sweep
            and "updatePlayer(candidate.player, candidate.position" in boundary_sweep
            and "candidate.identity, false)" in boundary_sweep,
            "boundary guard skips cold persisted inside relations for untracked outside players",
        )
        failure_notify = section(
            room_ownership,
            r"local function notifyFailure",
            r"\n\nlocal function removeOldGeneration",
        )
        cancel_pending_ack = section(
            generation_ack,
            r"local function cancelPending\(reason\)",
            r"\n\nlocal function roofRefreshRelocationPositionStillSyncing",
        )
        final_ack = section(
            server_commands,
            r"if module == COMMAND_MODULE and command == COMMAND_FINAL_RELOCATE_ACK then",
            r"if module == COMMAND_MODULE and command == COMMAND_RELOCATE_ACK then",
        )
        request_rejection = section(
            server_commands,
            r"local checkOk, accepted, reason = pcall\(validateRequest",
            r"\nend\n\nlocal function requireCoreRegistration",
        )
        invalid_feedback = section(
            railroader_client,
            r"function Menu.OnServerCommand",
            r"\n\s*rememberUtilityMapping\(args\)",
        )
        checks.true(
            failure_notify is not None
            and 'ServerUtil.invoke(player, "getOnlineID")' in failure_notify
            and "onlineId = onlineId" in failure_notify
            and "string.find(reasonText, invalidRVData, 1, true)" in failure_notify
            and "notifyFailure(livePlayer, reason)" in generation_ack
            and cancel_pending_ack is not None
            and "isInvalidRVData(reason)" in cancel_pending_ack
            and "pending.invalidRVDataNoticeSent = notifyFailure(livePlayer, reason) == true"
                in cancel_pending_ack
            and cancel_pending_ack.find("pending.invalidRVDataNoticeSent =")
                < cancel_pending_ack.find("rearmGenerationTransition")
            and "if pending.invalidRVDataNoticeSent ~= true then" in cancel_pending_ack
            and "if isInvalidRVData(reason) then notifyFailure(player, reason) end"
                in (request_rejection or "")
            and final_ack is not None
            and "if isInvalidRVData(reason) then" in final_ack
            and "cancelPending(reason)" in final_ack
            and invalid_feedback is not None
            and "localPlayerByOnlineId(onlineId)" in invalid_feedback
            and "C.INVALID_RV_DATA" in invalid_feedback
            and "UI_RailroaderRVTest_InvalidRVData" in invalid_feedback
            and "Delete this test save and recreate it." in invalid_feedback
            and all(token not in invalid_feedback for token in (
                "args.x", "args.y", "args.z",
            )),
            "generation schema failures do not reach the affected player with the save-rebuild prompt",
        )
        checks.true(
            "current square has not been loaded" in boundary_geometry
            and "if not ok or current == nil then return false end" in boundary_geometry,
            "server boundary state advances across unloaded squares",
        )
        checks.true(
            "Roof relocation owns the boundary lease while the player is" in boundary_sweep
            and "Normal position, queue," in boundary_sweep
            and "and guard work resumes only after transition completion" in boundary_sweep
            and "local state = Boundary._states[id.key]" in boundary_sweep
            and "if state or inRVRegion then" in boundary_sweep
            and re.search(
                r"if state and transitionActive\(state\) then[\s\S]*?"
                r"else\s+local boundary = updatePlayer",
                boundary_sweep,
            ) is not None,
            "boundary OnTick still scans RV geometry through a remote roof-relocation cell",
        )
        checks.true(
            all(token in boundary_server for token in (
                "tag.rvId ~= nil", "tag.generation ~= nil",
                "tag.bitmapVersion ~= nil", "tostring(tag.rvId)",
                "integer(tag.bitmapVersion)", "edge.bitmapVersion",
                "shell host ownership is uncertain", "shellEdgeKeysForAction",
                "actionMatchesObject", "existingNamespace",
                "overwrite it merely because a build event happened at the same",
                "tag.edgeKeys = action.edgeKeys", "edge.side ~= \"north\"",
                "integer(edge.objectX) ~= edgeX", "includesHost",
                "Bitmap.containsScope(boundary.bitmap, objectX, objectY, objectZ)",
                "conflicting top-level/nested owner",
                "actionMatchesObject(action, objectX, objectY, objectZ)",
            )),
            "shell/build audit does not require full tag identity or host-aware attribution",
        )
        generation_cleanup = section(
            room_ownership,
            r"local function removeOldGeneration",
            r"local function structureCoordinates",
        )
        checks.true(
            generation_cleanup is not None
            and "old-generation cleanup is refused because" in generation_cleanup
            and "the current schema has no complete undo snapshot" in generation_cleanup
            and "ServerSchema.walkBounds" not in generation_cleanup
            and "ServerWorld.clearSquare" not in generation_cleanup
            and "removeOldGeneration(cell, manifest)" not in generation_flow,
            "obsolete old-generation cleanup is reachable without a complete undo snapshot",
        )
        repair_context = section(
            template_recovery_index,
            r"local function validCurrentContext",
            r"local function isCabCoordinate",
        )
        checks.true(
            repair_context is not None
            and "pcall(Boundary.boundaryForPlayer, player)" in repair_context
            and "pcall(requireCurrentManifest" not in repair_context
            and 'manifest.state ~= "READY"' in repair_context
            and 'manifest.phase ~= "COMMITTED"' in repair_context
            and "sameIdentity(manifest, boundary)" in repair_context
            and "schemaVersion" not in repair_context,
            "template protection repair does not require the current committed manifest before using bounds",
        )
        checks.true(
            "local function rectInside" in server_schema
            and "local scopeMinX, scopeMinY = managedOriginX, managedOriginY" in server_schema
            and "maxX >= scopeMaxX" in server_schema
            and "maxY >= scopeMaxY" in server_schema
            and 'rectInside(roomMinX, roomMaxX, roomMinY, roomMaxY, roomZ, "room")'
                in server_schema
            and 'rectInside(wallMinX, wallMaxX, wallMinY, wallMaxY, wallZ, "wall")'
                in server_schema
            and 'rectInside(roofMinX, roofMaxX, roofMinY, roofMaxY, roofZ, "roof")'
                in server_schema
            and "Bitmap.containsScope(bitmap, entry.x, entry.y, entry.z)" in server_schema,
            "layout structure rectangles and captured wall hosts are not clipped to the bitmap scope",
        )
        checks.true(
            "function Boundary.beginTransition(player, rvId, generation, token, kind," in boundary_server
            and "local version = integer(bitmapVersion)" in boundary_server
            and "bitmapVersion = transitionBitmapVersion" in server
            and "transitionBitmapVersion)" in server
            and "record.bitmapVersion)" in railroader_server,
            "transition state does not carry the complete RV bitmap identity",
        )
        checks.true(
            "RV boundary entry service is unavailable" in railroader_server
            and "RV boundary exit service is unavailable" in railroader_server,
            "Railroader entry/exit can bypass the server boundary service",
        )
        checks.true(
            "currentRVManifestForBoundary" in record_validation
            and "schemaVersion" not in boundary_geometry
            and "Bitmap.decode(boundary.bitmap)" in boundary_geometry,
            "current manifest identity or latest-format bitmap decode path is missing",
        )
        checks.true(
            "local function roomOwnershipGuardKey" in room_ownership
            and "guard.key = roomOwnershipGuardKey" in room_ownership
            and "roomOwnershipGuards[guard.key] = guard" in room_ownership,
            "server room-ownership guard is not keyed by the full RV boundary identity",
        )
        checks.true(
            all(token in boundary_client for token in (
                "OnTick", "OnServerCommand", "COMMAND_RV_BOUNDARY_CORRECTION",
                "function Client.onCorrection",
            ))
            and all(token not in boundary_client for token in (
                "OnPlayerUpdate", "OnRenderTick", "previous",
                "segmentValid", "nearestActive", "setBlockMovement",
            )),
            "client boundary code retains independent previous-position prediction",
        )
        checks.true(
            "applyPosition(player, { x = x, y = y, z = z })" in boundary_client
            and '"setNextX"' in boundary_client
            and '"setLastZ"' in boundary_client,
            "client correction does not reset movement history fields",
        )

        # Railroader adapter executable contracts.  These source-level tests
        # intentionally exercise the authority/race decisions without loading
        # the game: the official Lua snapshot is not a runtime test substitute.
        checks.true(
            '== "rr_loco"' in railroader_server
            and '== "rr_loco"' in railroader_client,
            "Railroader adapter does not identify rr_loco on both sides",
        )
        checks.true(
            'serverTrain.active' in railroader_server
            and 'trainEntity.active' in railroader_server
            and 'authority == "singleplayer"' in railroader_server
            and "train.rider" in railroader_server
            and "RR.Ride" in railroader_server,
            "adapter does not distinguish RR_ServerTrain MP and TrainEntity/Ride SP state",
        )
        checks.true(
            ".Body.hullDistance" in railroader_server
            and "sourceWithinRange" in railroader_server
            and "RV_MOUNT_REACH" in railroader_server
            and "or 24" not in railroader_server,
            "server entry range is not the Railroader hull-distance contract",
        )
        checks.true(
            "ride.MOUNT_REACH" in railroader_client
            and "nearestBoardable(reach)" in railroader_client
            and "C.RV_ENTER_RANGE or 24" not in railroader_client,
            "client menu does not use Railroader MOUNT_REACH",
        )
        checks.true(
            "singleplayerDismount" in railroader_server
            and "singleplayerMount" in railroader_server
            and "ride.dismount" in railroader_server
            and "ride.mountRecord" in railroader_server
            and "ride.dismount, true" in railroader_client
            and "ride.mountRecord" in railroader_client,
            "SP Ride cleanup/remount and client transition ordering are missing",
        )
        checks.true(
            'args.action ~= "exit"' in railroader_client
            and 'args.action ~= "generation-failed"' in railroader_client,
            "SP generation-failed transition does not remount through Ride after teleport",
        )
        checks.true(
            all(token in railroader_server for token in (
                "_seatNames", "_claims", "_cmdSeq", "markResync",
                "setBlockMovement", "setCanShout", "setIsResting",
            )),
            "MP seat writes do not cover official claim/name/command/resync and player flags",
        )
        checks.true(
            "action == \"enter\"" in railroader_client
            and "action == \"generation-failed\"" in railroader_client
            and "action == \"exit\"" in railroader_client
            and "prepareGenerationRelocation" in railroader_client
            and "prepareGenerationRelocation" in client
            and "rr.MPClient" in railroader_client
            and "_boardPending" in railroader_client,
            "RVTeleport transition does not cover enter/failure/exit MP snapshot races",
        )

        # The current-square refresh uses the public IsoMovingObject overload;
        # Java userdata is not a Lua table, so writing dirty grid-stack fields
        # would flood the client log with an exception on every retry tick.
        current_square_refresh = section(
            railroader_client,
            r"local function refreshCurrentSquare",
            r"local function currentSquareMatches",
        )
        checks.true(
            current_square_refresh is not None
            and "player:setCurrentSquareFromPosition(x, y, z)" in current_square_refresh
            and "pcall" in current_square_refresh
            and "dirtyRecalcGridStack" not in railroader_client,
            "Railroader client current-square refresh uses an unsafe Java-field write or lacks the official three-argument call",
        )
        checks.true(
            "playerObj:setCurrentSquareFromPosition(x, y, z)" in client
            and "dirtyRecalcGridStack" not in client,
            "generic client relocation still uses an unsafe current-square refresh path",
        )
        checks.true(
            "CURRENT_SQUARE_REFRESH_TICKS" in railroader_client
            and "pending.ticks > CURRENT_SQUARE_REFRESH_TICKS" in railroader_client
            and "Menu._rvCurrentSquareRefresh = nil" in railroader_client,
            "current-square refresh retry is not bounded and cleaned up",
        )

        # The first generation Relocate is a separate race from RVTeleport:
        # the server may have removed the seat while the client is still
        # locally mounted.  Verify the Railroader-only marker, call ordering,
        # and token-scoped duplicate-dismount guard precisely.
        queue_transition = section(
            generation_flow_source,
            r"local function queueGeneration",
            r"ctx\.queueGeneration\s*=\s*queueGeneration",
        )
        relocate_handler = section(
            client_relocation_source,
            r"function Client\.onServerCommand",
            r"function Client\.onTick",
        )
        ride_transition = section(
            railroader_client,
            r"local function prepareRideTransition",
            r"local function finishRideTransition",
        )
        generation_relocation = section(
            railroader_client,
            r"function Menu\.prepareGenerationRelocation",
            r"local function worldLocomotive",
        )
        generation_staging = section(
            railroader_client,
            r"function Menu\.prepareGenerationStaging",
            r"local function worldLocomotive",
        )
        final_handler = section(
            client,
            r"if command == COMMAND_FINAL_RELOCATE then",
            r"if command ~= COMMAND_RELOCATE then return end",
        )
        final_relocation = section(
            server,
            r"local function relocatePlayerIntoHouse",
            r"local function generateForPlayer",
        )
        checks.true(
            queue_transition is not None
            and re.search(
                r'if type\(railroaderData\) == "table" then[\s\S]*?'
                r'relocatePayload\.railroaderTransition = true[\s\S]*?end',
                queue_transition,
            ) is not None
            and "relocatePayload.rvId = tostring(transitionRvId)" in queue_transition
            and "generation = transitionGeneration" in queue_transition
            and "bitmapVersion = transitionBitmapVersion" in queue_transition
            and "COMMAND_RELOCATE, relocatePayload" in queue_transition,
            "Railroader staging marker is not server-only or not sent via Relocate payload",
        )
        if queue_transition is not None:
            marker_guard = queue_transition.find(
                'if type(railroaderData) == "table" then'
            )
            marker_write = queue_transition.find(
                "relocatePayload.railroaderTransition = true"
            )
            checks.true(
                marker_guard >= 0 and marker_write > marker_guard,
                "Relocate marker is not guarded by Railroader generation data",
            )
        checks.true(
            relocate_handler is not None
            and "args.railroaderTransition == true" in relocate_handler
            and "local rvId = args.rvId" in relocate_handler
            and "rvId = tostring(rvId)" in relocate_handler
            and "prepareGenerationStaging" in relocate_handler
            and "if not preparedOk or prepared ~= true then return end" in relocate_handler,
            "client Relocate handler does not recognize the strict Railroader staging marker",
        )
        if relocate_handler is not None:
            marker_pos = relocate_handler.find("args.railroaderTransition == true")
            staging_pos = relocate_handler.find(
                "prepareGenerationStaging", marker_pos
            )
            teleport_pos = relocate_handler.find(
                "playerObj:teleportTo", staging_pos
            )
            checks.true(
                marker_pos >= 0 and staging_pos > marker_pos and teleport_pos > staging_pos,
                "staging Ride cleanup is not ordered before the server Relocate teleport",
            )
        checks.true(
            generation_staging is not None
            and "validGenerationFinalHint(args)" in generation_staging
            and "prepareRideTransition(args)" in generation_staging
            and "_rvGenerationTransition" in railroader_client,
            "Railroader staging helper does not use the existing Ride transition and guard",
        )
        checks.true(
            generation_relocation is not None
            and "generationTransitionMatches" in generation_relocation
            and "pending.finalSeen = true" in generation_relocation
            and "prepareRideTransition(args)" in generation_relocation,
            "FinalRelocate does not distinguish the first staging transition from duplicate callbacks",
        )
        checks.true(
            final_relocation is not None
            and re.search(
                r'if type\(prepared\.railroader\) == "table" then[\s\S]*?'
                r'finalPayload\.railroaderTransition = true',
                final_relocation,
            ) is not None,
            "Railroader FinalRelocate payload does not carry the strict server marker",
        )
        checks.true(
            final_handler is not None
            and "validRailroaderFinalHint(args)" in final_handler
            and "if marked and railroaderMenu" in final_handler
            and "hasGenerationTransition" not in final_handler
            and "if (marked or pending)" not in final_handler
            and "prepareGenerationRelocation" in final_handler,
            "FinalRelocate handler does not gate Ride preparation on the current server marker",
        )
        if final_handler is not None:
            prepare_pos = final_handler.find("prepareGenerationRelocation")
            guard_pos = final_handler.find("if marked and railroaderMenu")
            checks.true(
                guard_pos >= 0 and prepare_pos > guard_pos,
                "ordinary FinalRelocate can call the Railroader transition without its gate",
            )
        checks.true(
            generation_relocation is not None
            and "if not validGenerationFinalHint(args) then return false end" in generation_relocation
            and "return false" in generation_relocation,
            "Railroader FinalRelocate adapter does not no-op ordinary technical payloads",
        )

        # On a quick authoritative exit, the target record must receive the
        # official gate even if Ride.current is already nil; a beside exit may
        # not arm that gate.
        exit_transition = None
        if ride_transition is not None:
            exit_start = ride_transition.find('elseif action == "exit" then')
            return_pos = ride_transition.find("    return record", exit_start)
            if exit_start >= 0 and return_pos > exit_start:
                exit_transition = ride_transition[exit_start:return_pos]
        checks.true(
            exit_transition is not None
            and "if wantsSeat and record then" in exit_transition
            and "record._boardPending = true" in exit_transition
            and "if ride.current then" in exit_transition
            and exit_transition.find("record._boardPending = true")
            < exit_transition.find("if ride.current then")
            and re.search(r"if old then\s*old\._boardPending", exit_transition) is None,
            "exit transition does not arm the target record independently of Ride.current (or arms beside)",
        )
        checks.true(
            "recordAtPlayerCoordinate" in railroader_server
            and "inRegion(position, record.region)" in railroader_server
            and "RV_REGION_SIZE" in railroader_server
            and "validMappingRecord" in railroader_server
            and "copyPose(record.locoPosition)" in railroader_server
            and "inactive-mapped" in railroader_server
            and "persistedBesidePosition" in railroader_server
            and "type(record.boundary) ~= \"table\"" in railroader_server
            and "record.bitmapVersion" in railroader_server
            and "roofRefreshRoomKey" in railroader_server
            and "tostring(record.bitmapVersion)" in railroader_server
            and '"outside-rv"' in railroader_server
            and "trainPose(train)" in railroader_server
            and "usableCoordinate" in railroader_server
            and 'isValidSquare' in railroader_server,
            "exit reverse lookup does not use the current 100x100 mapping contract",
        )
        existing_entry = section(
            entry_exit,
            r"local function enterExisting",
            r"local function enterPlayer",
        )
        checks.true(
            existing_entry is not None,
            "existing RV entry path is missing",
        )
        if existing_entry is not None:
            monitor_pos = existing_entry.find("armRoomOwnershipMonitor")
            transition_pos = existing_entry.find("local armed = Boundary.beginTransition")
            move_pos = existing_entry.find("movePlayer")
            checks.true(
                monitor_pos >= 0
                and transition_pos > monitor_pos
                and move_pos > monitor_pos,
                "existing RV entry moves before arming its current room monitor",
            )

        presence_monitor = section(
            adapter_roof_refresh_source,
            r"local function sampleRoofRefreshPlayers",
            r"\r?\nend\r?\n",
        )
        checks.true(
            presence_monitor is not None,
            "inside-player presence/reconnect monitor path is missing",
        )
        if presence_monitor is not None:
            checks.true(
                "roomMonitorPlayers[presenceKey] == player" in presence_monitor
                and "roomMonitorPlayers[presenceKey] = player" in presence_monitor
                and "for presenceKey in pairs(roomMonitorPlayers)" in presence_monitor
                and "armRoomOwnershipMonitor(player, record" in presence_monitor,
                "presence/reconnect path does not re-arm the per-client current monitor",
            )

        shell_wall = section(
            boundary_objects,
            r"function Boundary\.isCurrentShellWall",
            r"local function appendShellEdgeKey",
        )
        checks.true(
            shell_wall is not None,
            "boundary server has no strict current RV shell-wall detector",
        )
        if shell_wall is not None:
            checks.true(
                all(
                    token in shell_wall
                    for token in (
                        "decodeBoundary",
                        'instanceof", object, "IsoThumpable"',
                        'getObjectIndex")',
                        "RailroaderRVTest",
                        "nested.edgeKey",
                        "shellEdgeAllowed(boundary, nested",
                        "Bitmap.containsScope(bitmap",
                    )
                )
                and "wall-north" in shell_wall
                and "wall-west" in shell_wall
                and "corner-nw" in shell_wall
                and "corner-se" not in shell_wall,
                "shell-wall detector does not require the current type/tag/ledger identity",
            )

        wall_removal = section(
            railroader_server,
            r"local function queueWallRoofRefreshForObject",
            r"insidePlayersForRecord = function",
        )
        checks.true(
            wall_removal is not None,
            "Railroader server has no object-removal roof-refresh hook",
        )
        if wall_removal is not None:
            checks.true(
                all(
                    token in wall_removal
                    for token in (
                        "processIsServer()",
                        "Boundary.isCurrentShellWall",
                        "validRecord(record)",
                        "wall removal matched",
                        "wall roof refresh queued",
                    )
                ),
                "wall-removal matcher does not use server identity and room-key debounce",
            )
            checks.true(
                "seenWallRemovalEvents" in wall_removal
                and "wallRemovalEventKey" in wall_removal
                and "coordinateKey" in wall_removal
                and "fallback-wall" in railroader_server
                and "WALL_REMOVAL_EVENT_DEDUPE_TICKS" in wall_removal
                and "WALL_REMOVAL_FOLLOWUP_MAX" in railroader_server
                and "wall removal event suppressed" in wall_removal,
                "duplicate wall-removal callbacks are not suppressed per object/cycle",
            )
            checks.true(
                "token = group.token" in server
                and "roofRefreshGroupFailure.token == token" in server
                and "pending.relocationToken or pending.returnToken" in railroader_server
                and "another RV relocation or generation is in progress" in railroader_server,
                "failed roof cycles are not token-scoped for in-memory return and queued independent operations",
            )
        scheduled_roof = section(
            railroader_server,
            r"scheduleRoofRefresh = function",
            r"local function queueWallRoofRefreshForObject",
        )
        checks.true(
            scheduled_roof is not None,
            "delayed roof refresh scheduler is missing",
        )
        if scheduled_roof is not None:
            checks.true(
                all(
                    token in scheduled_roof
                    for token in (
                        "validRecord(record)",
                        "insidePlayersForRecord(map, record)",
                        "pendingWallRoofRefreshes[roomKey]",
                        "ROOF_REFRESH_QUEUED_DEADLINE_TICKS",
                        "queuedDeadlineTick",
                        "dueTicks",
                        "nextAttempt",
                        "ROOF_REFRESH_DELAY_TICKS",
                        "ROOF_REFRESH_ATTEMPTS",
                    )
                ),
                "roof refresh scheduler does not enforce current identity/inside player or bounded retries",
            )
            checks.true(
                "ROOF_REFRESH_DELAY_TICKS = 5" in railroader_server
                and "ROOF_REFRESH_ATTEMPTS = 3" in railroader_server
                and "ROOF_REFRESH_QUEUED_DEADLINE_TICKS = 600" in railroader_server
                and "queued roof refresh member rebind deadline expired"
                in railroader_server
                and "pending.dueTicks[attempt] = tickAfter(now," in adapter_roof_refresh_flow_source
                and "attempt * ROOF_REFRESH_DELAY_TICKS" in adapter_roof_refresh_flow_source
                and "local function tickAfter(tick, delta)" in adapter_roof_refresh_flow_source
                and "Core.tickAdd(tick, delta)" in adapter_roof_refresh_flow_source,
                "wall-removal repair schedule does not define the bounded 5/10/15-tick contract",
            )
        checks.true(
            "function Adapter.onObjectAboutToBeRemoved" in adapter_roof_refresh_source
            and "queueWallRoofRefreshForObject(object, \"object-about-to-be-removed\")"
            in adapter_roof_refresh_source
            and "function Adapter.onDestroyIsoThumpable" in adapter_roof_refresh_source
            and 'queueWallRoofRefreshForObject(object, "destroy-iso-thumpable")'
            in adapter_roof_refresh_source,
            "wall-removal events do not share the strict de-duplicated matcher",
        )
        tick_refresh = section(
            adapter_tick_source,
            r"function Adapter\.OnTick",
            r"-- PZ loads files in this directory alphabetically",
        )
        checks.true(
            tick_refresh is not None
            and "processPendingWallRoofRefreshes()" in tick_refresh
            and "if not Core.tickModulo(30) then return end" in tick_refresh
            and "sampleRoofRefreshPlayers(map)" in tick_refresh,
            "delayed roof refresh is not deferred into the server 30-tick presence path",
        )
        checks.true(
            "clearRoofRefreshRuntimeState" not in adapter_roof_refresh_flow_source
            and "clearRoofRefreshRuntimeState" not in tick_refresh
            and "local map = mapData()" in tick_refresh
            and "pcall(mapData)" not in tick_refresh,
            "roof refresh still suppresses invalid saved-map reads or clears queued work on schema failure",
        )
        checks.true(
            "local function cancelPendingWallRoofRefresh" in adapter_roof_refresh_flow_source
            and "ctx.cancelPendingWallRoofRefresh = cancelPendingWallRoofRefresh"
            in adapter_roof_refresh_flow_source
            and "local function finishCompletedRoofRefresh" in adapter_roof_refresh_flow_source
            and "ctx.finishCompletedRoofRefresh = finishCompletedRoofRefresh"
            in adapter_roof_refresh_flow_source,
            "roof refresh queue cancellation/completion helpers are defined and exported",
        )
        room_transition = section(
            adapter_roof_refresh_source,
            r"local function authoritativeRoomState",
            r"\r?\nend\r?\n",
        )
        checks.true(
            room_transition is not None,
            "authoritative server room-state sampler is missing",
        )
        if room_transition is not None:
            checks.true(
                all(
                    token in room_transition
                    for token in (
                        'getCurrentSquare")',
                        'getRoom")',
                        'getRoomDef")',
                        'isInARoom")',
                        "inRoom",
                    )
                ),
                "room transition sampler does not use authoritative square room state",
            )
        transition_monitor = section(
            adapter_roof_refresh_source,
            r"observeRoomTransitions = function",
            r"ctx\.processStatelessRelocationSentinel",
        )
        checks.true(
            transition_monitor is not None
            and "previous.inRoom == true" in transition_monitor
            and "refresh=not-scheduled-without-wall-removal" in transition_monitor
            and "observed.roomStateAvailable" in transition_monitor
                and "roomTransitionStates[roomKey] = nil" in transition_monitor
                and "reason=presence-lost" in transition_monitor,
                "room transition monitoring no longer clears stale presence or preserve the wall-event-only schedule policy",
        )
        checks.true(
            "markSuppressedRoomTransition(pending)" in adapter_roof_refresh_flow_source
            and 'elseif source == "room-transition"' in adapter_roof_refresh_source
            and "suppressedRoomTransitions[roomKey] ~= nil" in adapter_roof_refresh_source
            and "suppressedRoomTransitions[roomKey] = nil" in adapter_roof_refresh_source
            and "reason=wall-removal-relocation" in adapter_mapping_source,
            "self-generated room transitions can start duplicate wall-removal refreshes",
        )
        delayed_attempts = section(
            adapter_tick_source,
            r"local function processPendingWallRoofRefreshes",
            r"function Adapter\.OnTick",
        )
        checks.true(
            delayed_attempts is not None
            and "processPendingWallRoofRefreshGroup(map, pending," in delayed_attempts
            and "identity-mismatch" in delayed_attempts
            and "no grouped authoritative players" in delayed_attempts,
            "delayed roof attempts do not remain on the grouped authoritative path",
        )
        checks.true(
            delayed_attempts is not None
            and "isGenerationTransactionActive" in delayed_attempts
            and "expireQueuedWallRoofRefreshes(now)" in delayed_attempts
            and "waitingForGeneration" in delayed_attempts
            and "local queuedDeadline = pending.queuedDeadlineTick" in delayed_attempts
            and "Core.tickReached(now, queuedDeadline)" in delayed_attempts
            and "pending.waitingForGeneration ~= true" in delayed_attempts
            and "malformed queued roof refresh deadline" in delayed_attempts
            and "revalidateQueuedRoofRefreshAfterGeneration" in adapter_tick_source
            and "revalidateUntilTick" in railroader_server
            and "pending.revalidateUntilTick = deadline" in adapter_roof_refresh_flow_source
            and "pending.queuedDeadlineTick = tickAfter(now," in adapter_roof_refresh_flow_source
            and "roof refresh queue revalidated after generation room=" in railroader_server
            and "currentRoomKey ~= roomKey" in adapter_roof_refresh_flow_source
            and "followUpWallRemovalEvents[currentRoomKey]" in adapter_roof_refresh_flow_source
            and "event.roomKey = currentRoomKey" in adapter_roof_refresh_flow_source,
            "queued wall follow-ups are not held through generation and revalidated against the new current record",
        )
        follow_up_wait = section(
            adapter_roof_refresh_flow_source,
            r"promoteFollowUpWallRemoval = function\(map, roomKey\)",
            r"local function revalidateQueuedRoofRefreshAfterGeneration",
        )
        checks.true(
            follow_up_wait is not None
            and "event.waitingForGeneration ~= true" in follow_up_wait
            and "Core.tickCompare(now, event.expiresAtTick) == 1" in follow_up_wait
            and "event.expiresAtTick = tickAfter(now," in follow_up_wait
            and "ROOF_REFRESH_QUEUED_DEADLINE_TICKS" in follow_up_wait
            and "wall removal follow-up cancelled room=" in follow_up_wait,
            "generation-held wall follow-ups do not pause, revalidate, and renew their bounded lease",
        )
        follow_up_prune = section(
            adapter_mapping_source,
            r"local function pruneRoofRefreshDedupeState",
            r"local function wallRemovalEventKey",
        )
        checks.true(
            follow_up_prune is not None
            and "generationBusy" in follow_up_prune
            and "event.waitingForGeneration == true" in follow_up_prune
            and "Core.tickCompare(now, expiresAt) == 1" in follow_up_prune
            and "event.waitingForGeneration = true" in follow_up_prune,
            "follow-up pruning does not preserve accepted events across generation ownership",
        )
        queued_disconnect = section(
            railroader_server,
            r"local function processPendingWallRoofRefreshGroup",
            r"if pending.relocationPhase == \"temporary\"",
        )
        checks.true(
            queued_disconnect is not None
            and "queuedDeadlineTick" in queued_disconnect
            and "relocationStarted ~= true" in queued_disconnect
            and "pending.relocationToken == nil" in queued_disconnect
            and "pending.returnToken == nil" in queued_disconnect
            and "cancelPendingWallRoofRefresh(pending.roomKey, pending," in queued_disconnect
            and "queued roof refresh member rebind deadline expired" in queued_disconnect
            and "for i = 1, #pending.players do" in queued_disconnect
            and "resolveSavedPlayer(pending.players[i])" in queued_disconnect,
            "queued roof refresh has no bounded offline rebind cancellation before relocation",
        )
        roof_relocation = roof_destinations
        checks.true(
            roof_relocation is not None
            and "currentRVManifestForBoundary" in roof_relocation
            and "currentRVRecordGeometryConsistent" not in roof_relocation
            and "originX + math.floor(width / 2)" in roof_relocation
            and "originY + math.floor(height / 2)" in roof_relocation
            and "ROOF_REFRESH_REMOTE_OFFSET_X" in roof_relocation
            and "ROOF_REFRESH_REMOTE_OFFSET_Y" in roof_relocation
            and "ROOF_REFRESH_REMOTE_OFFSET_Z" in roof_relocation
            and "centerZ - ROOF_REFRESH_REMOTE_OFFSET_Z" in roof_relocation
            and "targetKind=rv-center-minus-offset" in server
            and "roofRefreshTemporarySquareSafe" in roof_relocation
            and "roof refresh temporary destination is still room geometry"
            in roof_relocation,
            "roof relocation does not derive a current-schema remote center-minus-offset target",
        )
        roof_relocation_service = section(
            roof_relocation_source,
            r"function RV.Server.beginRoofRefreshRelocationGroup",
            r"local function keepRoofRefreshFinalReturnAlive",
        )
        checks.true(
            roof_relocation_service is not None
            and "Boundary.beginTransition" in roof_relocation_service
            and "COMMAND_RELOCATE, member.returnPayload" in roof_relocation_service
            and "roofRepairTransition = true" in roof_relocation_service
            and 'relocatePayload.haloText = "正在刷新房间"' not in roof_relocation_service
            and "teleportTo" in roof_relocation_service
            and "request.players" in roof_relocation_service
            and "originalPosition = exactOrReason" in roof_relocation_service,
            "grouped roof relocation service does not keep authority/identity/visual marker on the existing bridge",
        )
        roof_server_tick = section(
            generation_ack_source,
            r"local function processRoofRefreshRelocationGroup",
            r"ctx\.processRoofRefreshRelocationGroup\s*=",
        )
        checks.true(
            roof_server_tick is not None
            and "roofRefreshTargetReady" in roof_server_tick
            and "RelocateAck" not in roof_server_tick
            and "roofRefreshRelocationGroup" in roof_server_tick,
            "roof relocation server tick does not wait for authoritative arrival/readiness",
        )
        checks.true(
            roof_server_tick is not None
            and "applyRoofRefreshTeleport" in roof_server_tick
            and "return target wait" in roof_server_tick
            and "returnTargetLogTick" in roof_server_tick,
            "roof return does not reassert server float coordinates or expose target proof waits",
        )
        checks.true(
            roof_relocation is not None
            and "allowMissingSquare" in roof_relocation
            and "type(allowedPlayers) == \"table\"" in roof_relocation
            and "pending.roofRepairTransition" in client
            and "pending.roofRepairPhase == \"temporary\"" in client
            and "pending.roofRepairPhase == \"return\"" in client
            and "function RV.Server.completeRoofRefreshRelocation" in roof_api_source
            and "function RV.Server.roofRefreshSquaresLoaded" in roof_api_source,
            "remote roof relocation cannot acknowledge a valid unloaded target across ticks",
        )
        checks.true(
            all(token in client for token in (
                "roofRepairTransition", "roofRepairPhase",
                "generationTransition", "generationPhase",
                "GENERATION_HALO_TEXT", "ROOF_REFRESH_HALO_TEXT",
                "setHaloNote", "RelocateAck",
            )),
            "client roof relocation handler lacks display-only halo and token ACK contract",
        )
        checks.true(
            "if not roofRefreshTransition and roofRefreshPhase ~= nil then" in client
            and "if not generationTransition and generationPhase ~= nil then" in client
            and "or roofRefreshTransition) then" in client,
            "client does not fail closed on mixed relocation phase markers",
        )
        relocation_services = section(
            player_validation_source,
            r"local relocationServices = \(function\(\)",
            r"local readPlayerCoordinate = relocationServices\.readPlayerCoordinate",
        )
        checks.true(
            relocation_services is not None
            and "Relocation state is process-local" in server
            and "playerIdentity = playerIdentity" in server
            and "resolvePendingPlayer = resolvePendingPlayer" in server
            and "relocationPositionsEqual = relocationPositionsEqual" in server
            and "ModData" not in relocation_services,
            "relocation state still depends on a persisted intermediate ledger",
        )
        generation_rebind = section(
            player_validation_source,
            r"local function generationDisconnected",
            r"ctx\.generationDisconnected\s*=",
        )
        checks.true(
            generation_rebind is not None
            and "resolvePendingPlayer" in generation_rebind
            and "relocationNeedsResend" in generation_rebind
            and "disconnectStartedTick" in generation_rebind
            and "resumeGenerationAfterDisconnect" in generation_rebind
            and "resendGenerationPhase" in generation_rebind
            and "Boundary.extendTransition" in generation_rebind
            and "GENERATION_RELOCATION_RETRY_TICKS" in generation_rebind,
            "generation relocation does not rebind stable identities and renew/retry the same token",
        )
        generation_rollback = section(
            server,
            r"local function resendGenerationPhase",
            r"local function keepGenerationTransitionAlive",
        )
        checks.true(
            generation_rollback is not None
            and 'if phase == "rollback" then' in generation_rollback
            and 'callSucceeded(player, "setX", target.x)' in generation_rollback
            and 'callSucceeded(player, "setY", target.y)' in generation_rollback
            and 'callSucceeded(player, "setZ", target.z)' in generation_rollback
            and 'callSucceeded(player, "setLastX", target.x)' in generation_rollback
            and 'callSucceeded(player, "setLastY", target.y)' in generation_rollback,
            "generation rollback does not reassert the server-captured exact position",
        )
        roof_rebind = section(
            roof_relocation_source,
            r"local function resendRoofRefreshMemberPhase",
            r"local function keepRoofRefreshTransitionAlive",
        )
        roof_disconnect_pause = section(
            roof_relocation_source,
            r"local function keepRoofRefreshTransitionAlive",
            r"ctx\.keepRoofRefreshTransitionAlive",
        )
        roof_retry = section(
            generation_ack,
            r"local function processRoofRefreshRelocationGroup",
            r"ctx\.processRoofRefreshRelocationGroup",
        )
        checks.true(
            roof_rebind is not None
            and "member.relocationNeedsResend" in roof_rebind
            and "member.arrived == true or member.completed == true" in roof_rebind,
            "roof relocation phase resend does not preserve one token across reconnect",
        )
        checks.true(
            roof_retry is not None
            and "ROOF_RELOCATION_RETRY_TICKS" in roof_retry
            and "member.relocationNeedsResend" in roof_retry
            and "member.relocationRetryAtTick" in roof_retry,
            "roof relocation resend is missing its bounded retry cadence",
        )
        checks.true(
            roof_disconnect_pause is not None
            and "disconnectStartedTick" in roof_disconnect_pause
            and "Core.tickElapsed(ctx.serverTick" in roof_disconnect_pause
            and "group.deadlineTick" in roof_disconnect_pause
            and "member.relocationNeedsResend = true" in roof_disconnect_pause,
            "roof relocation does not pause its timeout and rebind members after reconnect",
        )
        checks.true(
            "currentRVManifestForRelocation" in record_validation
            and "currentRVManifestForBoundary" in record_validation
            and "currentRVRecordGeometryConsistent" not in record_validation
            and "validateCurrentRVRecord" not in record_validation,
            "current manifest reads still depend on the removed cross-geometry validator",
        )
        mutex_gate = section(
            roof_relocation_source,
            r"function RV.Server.beginRoofRefreshRelocationGroup",
            r"local function keepRoofRefreshFinalReturnAlive",
        )
        checks.true(
            mutex_gate is not None
            and "transactionBusy" in mutex_gate
            and "pendingGeneration ~= nil" in mutex_gate
            and "roofRefreshRelocationGroup ~= nil" in mutex_gate
            and "roofRefreshGroupFinalReturn ~= nil" in mutex_gate,
            "roof/generation relocation service does not enforce the server-side bidirectional mutex",
        )
        checks.true(
            "function RV.Server.isGenerationTransactionActive" in server
            and "function RV.Server.isRoofRefreshTransactionActive" in server
            and "function RV.Server.validateCurrentRVRecord" not in server
            and "function RV.Server.isRoofRefreshTransactionActive(_rvId)" in server
            and "active roof transaction must never be bypassed" in server
            and "roof refresh is in progress" in server
            and "another RV relocation or generation is in progress" in server,
            "server transaction mutex does not expose active roof/generation state and explicit rejection reasons",
        )
        adapter_mutex = section(
            railroader_server,
            r"(?:local function serverTransactionMutexStatus|serverTransactionMutexStatus = function)",
            r"local function sentinelWarn",
        )
        checks.true(
            adapter_mutex is not None
            and "serverTransactionMutexStatus" in adapter_mutex
            and "isGenerationTransactionActive" in adapter_mutex
            and "isRoofRefreshTransactionActive" in adapter_mutex
            and "isRoofRefreshTransactionActive, nil" in adapter_mutex
            and "pendingWallRoofRefreshes" in adapter_mutex
            and "INVALID_RV_DATA" in adapter_mutex
            and all(
                token in railroader_server
                for token in (
                    "local roofBlocked, roofReason = roofRefreshTransactionBlocks(record.rvId)",
                    "local roofBlocked, roofReason = roofRefreshTransactionBlocks(locoId)",
                )
            ),
                "all-player Enter/Exit paths do not honor the current RV roof transaction mutex",
        )
        roof_owner = section(
            railroader_server,
            r"roofRefreshOwnsPlayer = function",
            r"serverTransactionMutexStatus = function",
        )
        checks.true(
            roof_owner is not None
            and "queuedRoofRefreshClaims(identityKey)" in roof_owner
            and "isRoofRefreshTransactionActive" in roof_owner
            and "roofActive ~= true" in roof_owner,
            "adapter roof-owner gate confuses a generation claim with roof refresh",
        )
        checks.true(
            "currentGeometryGate" not in railroader_server
            and "currentRVRecordGeometryConsistent" not in railroader_server
            and "currentManifestForRecord" not in railroader_server,
            "Entry/Exit still contain removed cross-module geometry or manifest guards",
        )
        existing_entry = section(
            railroader_server,
            r"local function enterExisting",
            r"local function enterPlayer",
        )
        checks.true(
            existing_entry is not None
            and "currentManifestForRecord(record)" not in existing_entry
            and "local armed = Boundary.beginTransition" in existing_entry
            and "armRoomOwnershipMonitor" in existing_entry,
            "existing RV entry retains a removed manifest guard or lost boundary transition checks",
        )
        exit_entry = section(
            entry_exit,
            r"local function exitPlayer",
            r"\r?\nend\r?\n",
        )
        checks.true(
            exit_entry is not None
            and "currentManifestForRecord(record)" not in exit_entry
            and "local armed = Boundary.beginTransition" in exit_entry
            and "markPlayerOutside" in exit_entry,
            "RV exit retains a removed manifest guard or lost boundary transition checks",
        )
        boundary_gate = section(
            boundary_server,
            r"function Boundary.boundaryForPlayer",
            r"local function stateFor",
        )
        checks.true(
            boundary_gate is not None
            and "validateCurrentBoundaryPlayer" in boundary_gate
            and "loadedBoundary(boundary)" in boundary_gate
            and "if not hookOk" in boundary_gate,
            "boundary guard does not fail closed through its current identity and player checks",
        )
        checks.true(
            "sameBoundaryGeometry" in boundary_server
            and "state.boundaryReference ~= boundary" in boundary_server
            and "currentRVManifestForBoundary" in railroader_server
            and "currentRVRecordGeometryConsistent" not in railroader_server,
            "boundary cache lost its local snapshot check or retained a cross-record geometry dependency",
        )
        checks.true(
            "function RV.Server.isRelocationIdentityClaimed" in server
            and "function RV.Server.currentRVManifestForRelocation" in server
            and "function processStatelessRelocationSentinel" in railroader_server
            and "RELOCATION_SENTINEL_Z" in railroader_server
            and "math.floor(position.z) ~= RELOCATION_SENTINEL_Z" in railroader_server
            and "sentinelPosition" in railroader_server
            and "player left the temporary cell" in railroader_server
            and "sentinelRecordManifestConsistent" not in railroader_server
            and "queuedRoofRefreshClaims" in railroader_server
            and "for _, saved in pairs(pending.players or {})" in railroader_server
            and "sentinelWarn" in railroader_server
            and "relocation sentinel matched no current RV records" in railroader_server
            and "relocation sentinel matched multiple RV records" in railroader_server,
            "stateless -15 relocation sentinel is missing its identity/current-schema gates",
        )
        sentinel_mutex = section(
            railroader_server,
            r"local function processStatelessRelocationSentinel",
            r"local function authoritativeRoomState",
        )
        checks.true(
            sentinel_mutex is not None
            and "isGenerationTransactionActive" in sentinel_mutex
            and "isRoofRefreshTransactionActive" in sentinel_mutex
            and "if generationActive or roofActive then return end" in sentinel_mutex,
            "stateless sentinel can race an active generation or roof transaction",
        )
        checks.true(
            "recoverRelocationLedger" not in server
            and "recoveryOnly" not in server
            and "RECOVERY_REQUIRED" not in server
            and "setGenerationRecoveryValidator" not in server
            and "setRoofRefreshRecoveryValidator" not in server
            and "setRoofRefreshRecoveryRepairer" not in server,
            "server still contains the retired restart-recovery state machine",
        )
        checks.true(
            "returnRepairDeadline" not in railroader_server
            and "ROOF_REFRESH_RETURN_TIMEOUT_TICKS" not in railroader_server
            and "refreshRetryAtTick" in railroader_server
            and "continuously required post-return step" in railroader_server,
            "roof refresh still exposes a fake return deadline instead of a retry cadence",
        )
        checks.true(
            "GENERATION_HALO_REFRESH_TICKS" in client
            and "pending.generationTransition and pending.generationPhase == \"temporary\""
            in client
            and "GENERATION_HALO_TEXT" in client
            and "server payload contains only the phase marker" in client,
            "generation halo does not stay visible through the complete temporary phase",
        )
        checks.true(
            "if string.find(detail, C.INVALID_RV_DATA, 1, true) then"
            in railroader_server
            and "already accepted follow-up" in railroader_server
            and "expiresAtTick" in railroader_server,
            "transient map reads can silently discard accepted bounded follow-up wall events",
        )
        roof_return = section(
            server,
            r"local function rollbackRoofRefreshRelocation",
            r"local function roofRefreshGroupMatches",
        )
        checks.true(
            roof_return is not None
            and "currentPosition.z == ROOF_REFRESH_TEMP_Z" in roof_return
            and "roof refresh player remains at temporary z=-15" in roof_return
            and "currentPosition.z ~= ROOF_REFRESH_TEMP_Z" in roof_return
            and "token = pending.token" in roof_return,
            "roof return does not reject an authoritative player still at z=-15",
        )
        checks.true(
            "keepRoofRefreshFinalReturnAlive" in server
            and "reason=authoritative-return-required" in server
            and "Boundary.beginTransition" in server
            and "roof refresh final return exhausted" not in server
            and "roof refresh group final return exhausted" not in server,
            "roof return failure can exhaust and discard its context instead of continuing in-memory return",
        )
        checks.true(
            "server.completeRoofRefreshRelocation" in railroader_server
            and "roofRefreshSquaresLoaded" in railroader_server
            and "pending.dueTicks[attempt] = tickAfter(now," in adapter_roof_refresh_flow_source
            and "attempt * ROOF_REFRESH_DELAY_TICKS" in railroader_server
            and "originalPosition = copyPosition(position)" in railroader_server
            and "beginRoofRefreshRelocationGroup" in railroader_server
            and "remote-reload-return" in railroader_server
            and "pending.relocationStarted" in railroader_server,
            "Railroader adapter does not implement grouped remote reload, repair and captured-position return",
        )
        group_flow = section(
            adapter_roof_refresh_flow_source,
            r"local function processPendingWallRoofRefreshGroup",
            r"beginRoofRefreshPhase = function",
        )
        checks.true(
            group_flow is not None
            and "server.completeRoofRefreshRelocation" in group_flow
            and "pcall(\n                    refreshRoofForPlayer" in group_flow
            and "refreshWorldApplied" in group_flow
            and "refreshCompleted" in group_flow
            and "if not allCompleted then return end" in group_flow
            and "completeRoofRefresh" in group_flow
            and group_flow.find("server.completeRoofRefreshRelocation")
                < group_flow.find("server.roofRefreshSquaresLoaded"),
            "group return does not complete per-player return before isolating repair callbacks",
        )
        checks.true(
            "local rollbackCallOk, returned, returnReason = pcall(" in server
            and "wallRemovalEventKey" in railroader_server,
            "roof final-return failures are not isolated and wall dedupe retains userdata",
        )
        checks.true(
            'Core.registerEvent("OnObjectAboutToBeRemoved",' in adapter_tick_source
            and '"RailroaderRV.Adapter.ObjectAboutToBeRemoved"' in adapter_tick_source
            and "Adapter.onObjectAboutToBeRemoved" in adapter_tick_source,
            "server shell-wall removal hook is not registered on the authoritative event",
        )
        checks.true(
            'Core.registerEvent("OnDestroyIsoThumpable",' in adapter_tick_source
            and '"RailroaderRV.Adapter.DestroyIsoThumpable"' in adapter_tick_source
            and "Adapter.onDestroyIsoThumpable" in adapter_tick_source,
            "server thumpable-destroy event supplement is not registered",
        )
        exit_player = section(
            entry_exit,
            r"local function exitPlayer",
            r"\r?\nend\r?\n",
        )
        checks.true(
            exit_player is not None
            and "if damaged or not record or not train" not in exit_player
            and re.search(
                r'if lookupState == "outside-rv" then[\s\S]*?'
                r'return false, "player is outside the RV area"[\s\S]*?'
                r'end\s+if not record then',
                exit_player,
            ) is not None
            and re.search(
                r'if not record then[\s\S]*?C\.INVALID_RV_DATA',
                exit_player,
            ) is not None
            and re.search(
                r'if not train then[\s\S]*?persistedBesidePosition\(record\)'
                r'[\s\S]*?lookupState ~= "inactive-mapped"[\s\S]*?'
                r'role = "beside"',
                exit_player,
            ) is not None
            and all(token in exit_player for token in (
                "Boundary.beginTransition", "movePlayer", "markPlayerOutside",
                "Boundary.clearPlayer", "markMappingChanged",
            ))
            and exit_player.find("Boundary.beginTransition")
                < exit_player.find("movePlayer")
                < exit_player.find("markPlayerOutside")
                < exit_player.find("Boundary.clearPlayer")
                < exit_player.find("markMappingChanged")
            and "putPassenger" not in exit_player[exit_player.find("if not train then"):]
            .split("local onlineId", 1)[0],
            "exit does not retain its beside fallback and boundary lease through the outside mapping update",
        )
        checks.true(
            re.search(
                r'if moving then[\s\S]*?freePassengerSeat\(train\)[\s\S]*?all passenger positions',
                railroader_server,
            ) is not None
            and re.search(
                r'freePassengerSeat\(train\)[\s\S]*?elseif train\.driver == nil[\s\S]*?besidePosition',
                railroader_server,
            ) is not None,
            "exit seat order does not enforce moving-passenger and stopped passenger/driver/beside rules",
        )

        if constants_path.is_file():
            checks.true(
                all(token in constants for token in (
                    "SAVE_SCHEMA_VERSION", "BITMAP_VERSION",
                    "RELOCATION_SENTINEL_Z",
                    "RELOCATION_SENTINEL_INTERVAL_TICKS",
                    "RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS",
                    "ROOF_REFRESH_REMOTE_OFFSET_X",
                    "ROOF_REFRESH_REMOTE_OFFSET_Y",
                    "ROOF_REFRESH_REMOTE_OFFSET_Z",
                    "INVALID_RV_DATA",
                ))
                and 'C.INVALID_RV_DATA = "RailroaderRVTest: RV data is invalid; delete this development test save and rebuild it"' in constants,
                "current schema constants do not expose the generic invalid-RV-data contract",
            )
            checks.true(
                "followUpWallRemovalEvents" in railroader_server
                and "rememberFollowUpWallRemoval" in railroader_server
                and "promoteFollowUpWallRemoval" in railroader_server
                and "WALL_REMOVAL_FOLLOWUP_TICKS" in railroader_server,
                "independent wall events are not retained in a bounded stable follow-up queue",
            )
            checks.true(
                "function checkSaveSchemaVersion()" in railroader_server
                and "events.OnInitGlobalModData" in railroader_server
                and "map.schemaVersion = C.SAVE_SCHEMA_VERSION" in railroader_server
                and "map.schemaVersion ~= C.SAVE_SCHEMA_VERSION" in railroader_server
                and "Continuing without migration" in railroader_server
                and "The user promises not to use old saves" in railroader_server
                and railroader_server.count("map.schemaVersion = C.SAVE_SCHEMA_VERSION") == 1
                and railroader_server.count("map.schemaVersion ~= C.SAVE_SCHEMA_VERSION") == 1
                and "pcall(mapData)" not in railroader_server
                and "pcall(ModData.getOrCreate" not in railroader_server
                and "return ModData.get(C.RV_MAP_KEY)" in mapping
                and "pcall(ModData.get, C.RV_MAP_KEY)" not in mapping
                and "map.locomotives = {}" not in mapping
                and "map.players = {}" not in mapping
                and "schemaVersion ~= " not in mapping
                and "schemaVersion = map.schemaVersion" in entry_exit
                and all("schemaVersion" not in source for source in (
                    generation_build, generation_flow, server_schema,
                    record_validation, layout, bitmap,
                    boundary_geometry, utility_store,
                )),
                "the single warning-only startup schema check or unguarded runtime read path is missing",
            )
            checks.true(
                "C.RV_REGION_SLOT_ROWS = 5" in constants
                and "C.RV_REGION_SLOT_COLUMNS = 20" in constants
                and "C.RV_REGION_SLOT_COUNT = C.RV_REGION_SLOT_ROWS * C.RV_REGION_SLOT_COLUMNS" in constants
                and "local FIRST_MIN_X" in region_slots
                and "local FIRST_MIN_Y" in region_slots
                and "indexToAnchor" in region_slots
                and "indexToRegion" in region_slots
                and "findFirstFree" in region_slots
                and "RegionSlots.findFirstFree(occupied)" in mapping,
                "5x20 row-major slot matrix or mapping-only free-slot allocation is incomplete",
            )
            checks.true(
                "local function mapData()" in mapping
                and "return ModData.get(C.RV_MAP_KEY)" in mapping
                and "function Bitmap.decode(encoded)" in bitmap
                and "local bitmap = Bitmap.decode(boundary.bitmap)" in boundary_geometry
                and all("schemaVersion" not in source for source in (
                    mapping, generation_build, generation_flow, bitmap,
                    boundary_geometry, utility_store,
                )),
                "runtime paths must use current data without nested save-schema gates",
            )
            checks.true(
                re.search(r"C\.TELEPORT_X\s*=\s*20050", constants) is not None
                and re.search(r"C\.TELEPORT_Y\s*=\s*2050", constants) is not None
                and re.search(r"C\.TELEPORT_Z\s*=\s*0", constants) is not None,
                "shared constants do not define the fixed 20050,2050,0 destination",
            )
            checks.true(
                re.search(r"C\.CLEAR_MIN_OFFSET_X\s*=\s*-50", constants) is not None
                and re.search(
                    r"C\.CLEAR_MAX_OFFSET_X\s*=\s*C\.CLEAR_MIN_OFFSET_X\s*\+\s*C\.RV_MANAGED_WIDTH",
                    constants,
                ) is not None
                and re.search(r"C\.CLEAR_MIN_OFFSET_Y\s*=\s*-50", constants) is not None
                and re.search(
                    r"C\.CLEAR_MAX_OFFSET_Y\s*=\s*C\.CLEAR_MIN_OFFSET_Y\s*\+\s*C\.RV_MANAGED_HEIGHT",
                    constants,
                ) is not None
                and re.search(r"C\.RV_MANAGED_WIDTH\s*=\s*100", constants) is not None
                and re.search(r"C\.RV_MANAGED_HEIGHT\s*=\s*100", constants) is not None,
                "shared constants do not define the half-open 100x100 managed footprint",
            )
            checks.true(
                re.search(r'C\.COMMAND_FINAL_RELOCATE\s*=\s*["\']FinalRelocate["\']', constants)
                is not None,
                "shared constants do not define the final relocation command",
            )
            template_version = re.search(
                r"C\.CAPTURED_TEMPLATE_VERSION\s*=\s*(\d+)", constants
            )
            source_template_version = re.search(
                r"templateVersion\s*=\s*(\d+)", captured_template
            )
            room_template_version = re.search(
                r"CURRENT_TEMPLATE_VERSION\s*=\s*(\d+)", room_template
            )
            checks.true(
                template_version is not None
                and source_template_version is not None
                and room_template_version is not None
                and template_version.group(1) == source_template_version.group(1)
                and template_version.group(1) == room_template_version.group(1)
                and re.search(r"objectCount\s*=\s*412", captured_template)
                is not None
                and len(captured_template_rows) == 412
                and len(captured_template_objects) == 412
                and protection_identity_matches_template
                and "protectFromDemolition" not in captured_template,
                "current RoomTemplate/source/schema identity or object count is stale",
            )
            checks.true(
                all(
                    f"{enum} = {value}" in protection_manifest
                    for enum, value in (
                        ("P.FREE_DEMOLITION", 1),
                        ("P.RESTORE_ONLY", 2),
                        ("P.PROHIBITED", 3),
                        ("P.SPECIAL", 4),
                    )
                )
                and "P.OBJECT_COUNT = 412" in protection_manifest
                and "P.EXPECTED_CLASS_COUNTS = { [1] = 49, [2] = 0, [3] = 363, [4] = 0 }" in protection_manifest
                and "function P.validateTemplate(template)" in protection_manifest
                and "not sameIdentity(record, captured)" in protection_manifest
                and protection_class_counts == {1: 49, 2: 0, 3: 363, 4: 0},
                "current ProtectionManifest schema or category counts differ from the captured template",
            )
            checks.true(
                cab_classes_match,
                "current internal cab cells are not all free-demolition class",
            )
            checks.true(
                east_cab_classes_match,
                "east cab wall/window protection classes do not match the current manifest",
            )
            checks.true(
                south_shell_floors_stay_protected,
                "south shell floors do not remain prohibited from demolition",
            )
            checks.true(
                len(cab_opening_objects_outside_build_cells) == 3
                and all(protection_class_by_index.get(index)
                    == (3 if obj["name"] == "Wooden Door Frame" else 1)
                    for index, obj in cab_opening_objects_outside_build_cells),
                "cab-side door/window/door-frame protection does not match the manifest",
            )
            checks.true(
                sorted(northwest_support_classes) == [3, 3],
                "NW corner support walls do not both use protected demolition class",
            )
            checks.true(
                all(
                    protection_class_by_index.get(index) == 3
                    for index, obj in enumerate(captured_template_objects, 1)
                    if obj["name"] == "Dark Fancy Wardrobe"
                )
                and "Hidden RV Corner Block" not in captured_template
                and len(protected_activity_corner_walls) == 4
                and {(int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
                    for obj in protected_activity_corner_walls}
                    == {(-4, 16, 0, "false"), (2, -6, 0, "false"),
                        (2, 16, 0, "false"), (2, 17, 0, "false")}
                and len(protected_wardrobe_tiles) == 4
                and {(int(obj["x"]), int(obj["y"]), int(obj["z"]), obj["north"])
                    for obj in protected_wardrobe_tiles}
                    == {(-5, -2, 0, "true"), (-5, -1, 0, "true"),
                        (-5, 0, 0, "true"), (-5, 1, 0, "true")},
                "current protected corner walls or wardrobe identity/count is stale",
            )
            checks.true(
                len(captured_roof_cells) == 88,
                "current captured template roof-host square count is stale",
            )
            checks.true(
                len(northwest_north_wall_rows) == 1
                and len(northwest_west_wall_rows) == 1
                and "for y = interiorMinY, interiorMaxY do" in layout
                and 'or (north and "wall-north" or "wall-west")' in layout
                and "northwestEntries.north.role ~= \"corner-nw\"" in server_schema
                and "northwestEntries.west.role ~= \"wall-west\"" in server_schema
                and "coordinateKey ~= nwKey" in server_schema
                and "templateBoundarySupportWall = true" in world_objects
                and '["wall-west"] = true' in boundary_wall_visuals
                and "return expected.north == false" in boundary_wall_visuals,
                "NW corner does not have the exact corner-north/wall-west support pair with current visual tags",
            )
            checks.true(
                re.search(r"C\.SAVE_SCHEMA_VERSION\s*=\s*9", constants)
                and re.search(r"C\.RV_REGION_SLOT_ROWS\s*=\s*5", constants)
                and re.search(r"C\.RV_REGION_SLOT_COLUMNS\s*=\s*20", constants)
                and re.search(r"C\.BITMAP_VERSION\s*=\s*6", constants),
                "the single save schema version or shared RV matrix/bitmap contract is missing",
            )
            checks.true(
                len(captured_template_objects) == 412
                and len(fence_rows) == 50
                and len(paired_keys) == 46
                and len(boundary_fence_keys) == 46
                and len(hidden_boundary_wall_rows) == 47
                and not off_boundary_fence_keys
                and len(expected_off_boundary_fence_keys & fence_keys) == 4
                and all(
                    "doRender=false" in wall["state"]
                    and "hoppable=false" in wall["state"]
                    for wall in hidden_boundary_wall_rows
                )
                and all(
                    not wall_rows_by_key.get(key)
                    for key in expected_off_boundary_fence_keys
                )
                and len(wall_rows_by_key.get((2, 2, 0, "false"), [])) == 2,
                "captured fence backing does not match the 46-edge/47-wall boundary contract",
            )
            checks.true(
                'require "RailroaderRV/GUI/RV_BoundaryWallVisuals"' in client
                and "templateBoundarySupportWall = true" in world_objects
                and 'setIsThumpable", true' in world_objects
                and 'tag.templateClass ~= "IsoThumpable"' in boundary_wall_visuals
                and 'expected.name ~= "Wooden Wall"' in boundary_wall_visuals
                and "supportWallSprites[expected.sprite]" in boundary_wall_visuals
                and 'boundaryRoles[tag.role]' in boundary_wall_visuals
                and 'setDoRender", false' in boundary_wall_visuals
                and "invalidateRenderChunkLevel" in boundary_wall_visuals
                and "OnObjectAdded" in boundary_wall_visuals
                and "LoadGridsquare" in boundary_wall_visuals
                and "ReuseGridsquare" in boundary_wall_visuals,
                "client does not hide only generation-tagged boundary support walls across sync/load",
            )
            checks.true(
                'require "RailroaderRV/GUI/RV_WardrobeVisuals"' in client
                and 'local RoomTemplate = require "RailroaderRV/RoomTemplate/RV_RoomTemplate"' in wardrobe_visuals
                and 'RoomTemplate.get(RoomTemplate.TEMPLATE_ID)' in wardrobe_visuals
                and 'entry.state.doRender == false' in wardrobe_visuals
                and 'data.role ~= "captured-template"' in wardrobe_visuals
                and "tag.role ~= data.role" in wardrobe_visuals
                and "integer(tag.bitmapVersion) ~= C.BITMAP_VERSION" in wardrobe_visuals
                and 'setDoRender", false' in wardrobe_visuals
                and "getDoRender" in wardrobe_visuals
                and "invalidateRenderChunkLevel" in wardrobe_visuals
                and "OnObjectAdded" in wardrobe_visuals
                and "LoadGridsquare" in wardrobe_visuals
                and "ReuseGridsquare" in wardrobe_visuals
                and "Dark Fancy Wardrobe" in wardrobe_visuals,
                "wardrobes are not hidden through the client entry point with current generation identity and render invalidation",
            )
            checks.true(
                "protection.protectionClass ~= ProtectionManifest.PROHIBITED" in protected_demolition
                and "objectMatchesStaticIdentity(object, tag, expected, index," in protected_demolition
                and "TemplateGeometry.lookupObjectByIndex(index, Template, ProtectionManifest)" in protected_demolition
                and "TemplateGeometry.lookupObjectsAtWorld(world, anchor" in protected_demolition
                and "templateAnchorX" in protected_demolition
                and "C.TELEPORT_X" not in protected_demolition
                and re.search(
                    r"if not indexOk[\s\S]*?or not squareOk or not square then\s*return fail\(",
                    protected_demolition,
                ) is not None
                and "if not expected then\n        return rejectInvalidRVData" in protected_demolition
                and "return originalNew(self, character, item, cornerCounter)" in protected_demolition
                and "return { ignoreAction = true }" in protected_demolition,
                "protected demolition does not block only category 3 after validating the static object identity",
            )
            checks.true(
                "wallLamp" not in captured_template
                and "lighting_indoor_01_16" not in captured_template
                and "createLight" not in generation_build
                and "createCapturedTemplateObject" in generation_build,
                "captured RV generation still depends on the retired synthetic wall-lamp stage",
            )
            checks.true(
                re.search(
                    r'C\.COMMAND_REFRESH_ROOM_OWNERSHIP\s*=\s*["\']RefreshRoomOwnership["\']',
                    constants,
                )
                is not None
                and "C.COMMAND_REFRESH_ROOM_OWNERSHIP" in client
                and 'COMMAND_REFRESH_ROOM_OWNERSHIP = "RefreshRoomOwnership"' in server,
                "shared/server/client room-ownership command contract is inconsistent",
            )
            checks.true(
                re.search(
                    r'C\.COMMAND_FINAL_RELOCATE\s*=\s*["\']FinalRelocate["\']',
                    constants,
                ) is not None
                and "COMMAND_FINAL_RELOCATE" in client
                and "COMMAND_FINAL_RELOCATE" in server,
                "shared/server/client final relocation command contract is inconsistent",
            )

        if layout_path.is_file():
            layout = read_utf8(layout_path)
            checks.true(
                "playerFloor" not in layout
                and "local clear = rectangle(" in layout
                and "clear = clear" in layout,
                "shared layout retains a dead player-floor rectangle or loses its clear bounds",
            )
            checks.true(
                "C.INTERIOR_MIN_OFFSET_X" in layout
                and "C.INTERIOR_MAX_OFFSET_X" in layout
                and "C.INTERIOR_MIN_OFFSET_Y" in layout
                and "C.INTERIOR_MAX_OFFSET_Y" in layout
                and '"corner-nw"' in layout
                and '"corner-se"' not in layout
                and "#Template.misc.buildCells ~= 24" in layout,
                "shared layout does not expose the captured 6x23 interior and 6x4 cab build mask",
            )
            checks.true(
                "templateObjects" in layout
                and "templateIndex" in layout
                and "bounds.wallObjectCount ~= 59" in server_schema
                and "bounds.northEdges ~= 12 or bounds.westEdges ~= 47" in server_schema
                and "bounds.wallCornerCount ~= 1" in server_schema
                and "return edgeCount == 59" in boundary_geometry,
                "captured shell contract is not 59 edges with N12/W47/corner1",
            )
            checks.true(
                "local protection = ProtectionManifest.get(i)" in layout
                and "protectionClass = protection.protectionClass" in layout
                and "not ProtectionManifest.matchesLayoutEntry(i, entry, anchor)" in generation_build
                and "ProtectionManifest.matchesCapturedEntry(entry.templateIndex, entry)" in world_objects
                and "protectionClass = protection.protectionClass" in world_objects
                and "templateAnchorX = anchorX" in world_objects
                and "templateIndex = entry.templateIndex" in world_objects
                and "local expected = ProtectionManifest.worldEntry(templateIndex, anchor)" in template_protection_repair
                and "for templateIndex = 1, ProtectionManifest.OBJECT_COUNT do" in template_protection_repair
                and "local protected = protectionClass == ProtectionManifest.RESTORE_ONLY" in template_protection_repair
                and "or protectionClass == ProtectionManifest.PROHIBITED" in template_protection_repair
                and "tag.role ~= \"captured-template\"" in template_protection_repair
                and len(west_cab_wall_tiles) == 4
                and "protectFromDemolition" not in layout + generation_build + world_objects + protected_demolition + template_protection_repair,
                "static protection classes do not flow through layout, generation, tags, client demolition, and repair",
            )

        helper = section(
            server,
            r"local function isEmptyCommandArgs\(args\)",
            r"local function requiredNumber",
        )
        checks.true(helper is not None, "isEmptyCommandArgs helper is missing")
        if helper is not None:
            checks.true(
                re.search(
                    r"if\s+args\s*==\s*nil\s+then\s+return\s+true",
                    helper,
                )
                is not None,
                "canonical nil no-payload branch is missing",
            )
            checks.true(
                re.search(r'type\(args\)\s*==\s*"table"', helper) is not None,
                "plain Lua table branch is missing its type check",
            )
            checks.true(
                "tableIsEmpty(args)" in helper,
                "plain Lua table branch does not require an empty table",
            )
            checks.true(
                re.search(
                    r'classInstance\(args,\s*"PZNetKahluaTableImpl"\)', helper
                )
                is not None,
                "B42 PZNetKahluaTableImpl type check is missing",
            )
            checks.true(
                re.search(r'invoke\(args,\s*"size"\)', helper) is not None,
                "B42 payload branch does not read size()",
            )
            checks.true(
                re.search(r"toNumber\(size\)\s*==\s*0", helper) is not None,
                "B42 payload branch does not require size()==0",
            )
        checks.true(
            "local function tableIsEmpty" in server
            and "for _ in pairs(value)" in server
            and "next(" not in server,
            "server empty-table checks should use the broadly available pairs iterator",
        )
        clear_tag = section(
            server,
            r"local function clearGenerationTag\(object\)",
            r"local function squareContainsObject",
        )
        checks.true(clear_tag is not None, "clearGenerationTag function is missing")
        if clear_tag is not None:
            checks.true(
                "tableIsEmpty(nested)" not in clear_tag
                and "pairs(" not in clear_tag,
                "generation-tag cleanup still scans the Kahlua modData namespace",
            )
            for field_name in (
                "owner",
                "rvId",
                "generation",
                "bitmapVersion",
                "role",
                "previousSprite",
                "createdByGeneration",
            ):
                checks.true(
                    f"nested.{field_name} = nil" in clear_tag,
                    f"generation-tag cleanup does not clear nested {field_name}",
                )

        tagger = section(
            server,
            r"local function tagObject\(object, generation, role, extraData\)",
            r"local function isTaggedForGeneration",
        )
        checks.true(tagger is not None, "tagObject helper is missing")
        if tagger is not None:
            checks.true(
                all(
                    network_call not in tagger
                    for network_call in (
                        "transmitModData",
                        "transmitCompleteItemToClients",
                        "sendObjectChange",
                        '"sync"',
                    )
                ),
                "tagObject emits a pre-attachment object-index network packet",
            )
            checks.true(
                "generated object tag verification failed" in tagger,
                "tagObject no longer verifies its local tag before the creator sends it",
            )
            checks.true(
                "generated object boundary identity is incomplete" in tagger
                and "data.rvId" in tagger
                and "data.bitmapVersion" in tagger
                and "data.RailroaderRVTest.rvId" in tagger
                and "data.RailroaderRVTest.bitmapVersion" in tagger,
                "generated objects do not carry the full rvId/generation/bitmapVersion identity",
            )

        validate = section(
            generation_flow,
            r"local function validateRequest\(module, command, player, args\)",
            r"local function generateForPlayer",
        )
        checks.true(validate is not None, "validateRequest function is missing")
        if validate is not None:
            checks.true(
                "if not ServerUtil.isEmptyCommandArgs(args) then" in validate,
                "validateRequest does not call strict payload validation",
            )
            checks.true(
                re.search(r'type\(args\)\s*~=\s*"table"', validate) is None,
                "validateRequest still rejects every non-plain-table payload",
            )

        relocation_safety = section(
            roof_destinations,
            r"local function squareIsSafeForRelocation",
            r"local function selectGenerationStagingDestination",
        )
        checks.true(relocation_safety is not None, "relocation square safety helper is missing")
        if relocation_safety is not None:
            for required_check in (
                'invoke(square, "getFloor")',
                'invoke(square, "TreatAsSolidFloor")',
                'invoke(square, "isFree"',
                'invoke(square, "getRoom")',
                'invoke(square, "getRoomID")',
                'invoke(square, "getIsoWorldRegion")',
                'invoke(square, "getVehicleContainer")',
            ):
                checks.true(
                    required_check in relocation_safety,
                    f"relocation safety omits {required_check}",
                )

        relocation_search = section(
            roof_destinations,
            r"local function selectGenerationStagingDestination",
            r"local function playerIsAtStagingDestination",
        )
        checks.true(relocation_search is not None, "center generation staging helper is missing")
        if relocation_search is not None:
            checks.true(
                "managedOriginX" in relocation_search
                and "managedOriginY" in relocation_search
                and "GENERATION_STAGING_Z" in relocation_search,
                "generation staging is not derived from the current managed center",
            )
            checks.true(
                "math.floor(width / 2)" in relocation_search
                and "math.floor(height / 2)" in relocation_search
                and 'purpose = "generation-center"' in relocation_search,
                "generation staging does not use the center z=-15 destination",
            )

        generation_staging_server = section(
            roof_destinations,
            r"local function selectGenerationStagingDestination",
            r"local function playerIsAtStagingDestination",
        )
        checks.true(
            generation_staging_server is not None
            and all(
                token in generation_staging_server
                for token in (
                    "layout.bitmap",
                    "managedOriginX",
                    "managedOriginY",
                    "math.floor(width / 2)",
                    "math.floor(height / 2)",
                    "GENERATION_STAGING_Z",
                    'purpose = "generation-center"',
                    'isValidSquare", destination.x',
                )
            ),
            "first generation staging is not the current managed-scope center at z=-15",
        )
        checks.true(
            "GENERATION_STAGING_Z = Constants.RELOCATION_SENTINEL_Z" in server
            and "RELOCATION_SENTINEL_Z = -15" in constants
            and 'generationTransition = true' in generation_flow
            and 'generationPhase = "temporary"' in generation_flow
            and 'GENERATION_HALO_TEXT = "正在生成房车"' in client,
            "generation staging phase marker or exact local Chinese halo is missing",
        )

        queue = section(
            generation_flow,
            r"local function queueGeneration",
            r"ctx\.queueGeneration\s*=",
        )
        checks.true(queue is not None, "delayed generation queue is missing")
        if queue is not None:
            checks.true(
                "ctx.pendingGeneration ~= nil or ctx.transactionBusy" in queue,
                "generation queue does not reject duplicate/pending requests",
            )
            checks.true(
                "allocateRVRegion(railroaderData and railroaderData.locoId or nil)" in queue
                and re.search(
                    r'requiredInteger\(selectedSlot,\s*"allocated RV slot index"\)',
                    queue,
                ) is not None
                and re.search(
                    r'requiredInteger\(anchor\.x,\s*"allocated RV target x"\)',
                    queue,
                ) is not None
                and re.search(
                    r'requiredInteger\(anchor\.y,\s*"allocated RV target y"\)',
                    queue,
                ) is not None
                and re.search(
                    r'requiredInteger\(anchor\.z,\s*"allocated RV target z"\)',
                    queue,
                ) is not None
                and "layout = layoutOrError" in queue
                and "bounds = bounds" in queue
                and "oldBounds = oldBounds" in queue
                and "stagingDestination =" in queue,
                "Mapping-selected matrix slot cleanup plan is not captured before relocation",
            )
            checks.true(
                'manifestRvId == expectedTechnicalId' in queue
                and "manifestSlot == slotIndex" in queue
                and 'error("current generation identity does not match the selected RV slot")' in queue
                and "if manifest.generation ~= nil then" in queue
                and 'error("RailroaderRVTest: same-slot rebuild is refused because "' in queue
                and "if prepared.oldBounds ~= nil then" in generation_flow
                and "same-slot rebuild is refused because" in generation_flow
                and "removeOldGeneration(cell, manifest)" not in generation_flow,
                "same-slot rebuild is not refused when its prior generation lacks a complete undo snapshot",
            )
            checks.true(
                "pcall(manifestTable)" in queue
                and "if not manifestOk or type(manifestOrError) ~= \"table\" then" in queue
                and "manifestSlot = ServerUtil.integer(manifest.slotIndex)" in queue
                and "manifestRvId = tostring(manifest.rvId)" in queue
                and "priorGeneration ~= nil and oldBounds == nil" in queue
                and "persistedBoundsMatchBoundary" not in queue
                and "prior bounds are untrusted" not in queue,
                "generation queue does not check the current manifest root before using its fields",
            )
            validation_pos = queue.find(
                "validateTargetCoordinates(plannedBounds, destination)"
            )
            send_pos = queue.find('callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE')
            teleport_pos = queue.find('callSucceeded(player, "teleportTo"')
            checks.true(
                validation_pos >= 0
                and send_pos > validation_pos
                and teleport_pos > send_pos,
                "target legality validation is not ordered before relocation and server teleport",
            )
            checks.true(
                'callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE' in queue
                and "COMMAND_RELOCATE" in queue
                and 'callSucceeded(player, "teleportTo"' in queue,
                "queue does not relocate both targeted client and authoritative server player",
            )
            checks.true(
                re.search(
                    r'callSucceeded\(player, "teleportTo",\s*'
                    r'stagingDestination\.x \+ 0\.5,\s*'
                    r'stagingDestination\.y \+ 0\.5,\s*'
                    r'stagingDestination\.z\)',
                    queue,
                ) is not None
                and re.search(
                    r'callSucceeded\(player, "teleportTo",\s*'
                    r'destination\.x \+ 0\.5',
                    queue,
                ) is None,
                "server initial teleport must use staging, never the anchor destination",
            )
            checks.true(
                "selectGenerationStagingDestination(layout,\n            plannedBounds)" in queue
                and "x = stagingDestination.x" in queue
                and "y = stagingDestination.y" in queue
                and "z = stagingDestination.z" in queue
                and "generationTransition = true" in queue
                and "generationPhase = \"temporary\"" in queue,
                "queue does not use the server-selected staging destination",
            )
            checks.true(
                "ctx.pendingGeneration = {" in queue
                and "identity = identityOrReason" in queue
                and "originalPosition = {" in queue
                and "queuedAtTick = ctx.serverTick" in queue
                and "relocationServices.relocationLedger" not in queue
                and "ModData" not in queue,
                "generation staging does not retain its exact identity/position in process memory",
            )
            checks.true(
                "preflightLoaded" not in queue
                and "targetAreaLoadStatus" not in queue
                and "getSquare(" not in queue
                and "getGridSquare" not in queue,
                "queue still requires the remote target or complete footprint before teleport",
            )
            checks.true(
                "GameServer.sendTeleport" in queue,
                "queue does not document why the custom B42 Lua relocation bridge is required",
            )
            checks.true(
                "removeOldGeneration" not in queue and "buildGeneration" not in queue,
                "queue mutates the world before relocation acknowledgement",
            )

        construction_preflight = section(
            construction,
            r"local function preflightClearTarget",
            r"function service\.preflightCurrentGeneration",
        )
        clear_cleanup = section(
            generation_build,
            r"local function clearGenerationArea",
            r"local function buildGeneration",
        )
        exact_tag_check = section(
            construction,
            r"local function preflightClearTarget",
            r"function service\.preflightCurrentGeneration",
        )
        checks.true(
            construction_preflight is not None
            and "schema.walkBounds(cell, bounds" in construction_preflight
            and re.search(r"end,\s*true\)", construction_preflight) is None
            and "world.strictSquareSnapshot" in construction_preflight
            and "complete ~= true" in construction_preflight
            and "world.isPlayerObject" in construction_preflight
            and "clearing requires an empty scope because no complete undo" in construction_preflight
            and "if visited ~= expected then" not in construction_preflight,
            "clear preflight must snapshot each existing square and reject objects without a complete undo path",
        )
        checks.true(
            clear_cleanup is not None
            and "ServerSchema.walkBounds(cell, bounds" in clear_cleanup
            and "ServerWorld.clearSquare(square, nil)" in clear_cleanup
            and re.search(r"end,\s*true\)", clear_cleanup) is None
            and "squareSnapshotInternal(square, false)" in server_world
            and "squareSnapshotInternal(square, true)" in server_world
            and "world.strictSquareSnapshot" in construction_preflight,
            "preflight and clear must share a bounds walker that skips missing squares",
        )
        checks.true(
            "required square object list is unavailable" in server_world
            and "square object list could not be read" in server_world
            and "square collection could not be fully enumerated" in server_world
            and "square collection size is unavailable" in server_world
            and "clear bounds contain an unloaded square" in server_schema,
            "unknown square occupancy or a partial collection can still be silently accepted",
        )
        checks.true(
            exact_tag_check is not None
            and "type(existingManifest) == \"table\"" in exact_tag_check
            and "previous generation has no complete undo snapshot" in exact_tag_check
            and "clearing requires an empty scope because no complete undo" in exact_tag_check,
            "preflight can clear existing objects without a complete inverse snapshot",
        )

        def policy_allows_clear(
            square_exists: bool,
            enumeration_complete: bool,
            occupants: list[bool],
        ) -> bool:
            if not square_exists:
                return True
            if not enumeration_complete:
                return False
            return len(occupants) == 0

        preflight_cases = (
            ("empty existing square", True, True, [], True),
            ("missing square is skipped", False, False, [], True),
            ("incomplete object enumeration", True, False, [], False),
            ("player object", True, True, [True], False),
            ("object without complete undo", True, True, [False], False),
        )
        for name, square_exists, complete, occupants, expected in preflight_cases:
            checks.true(
                policy_allows_clear(square_exists, complete, occupants) is expected,
                f"clear preflight policy matrix failed: {name}",
            )

        preflight_call = generation_flow.find(
            "construction.preflightCurrentGeneration"
        )
        manifest_write = generation_flow.find("manifest.techVersion =")
        preserve_failure_gate = generation_flow.find(
            "local preserveManifestOnFailure = true"
        )
        first_preserve_false = generation_flow.find(
            "preserveManifestOnFailure = false", preflight_call
        )
        checks.true(
            preflight_call >= 0
            and manifest_write > preflight_call and preserve_failure_gate >= 0
            and first_preserve_false > preflight_call
            and "not ok and preserveManifestOnFailure ~= true" in generation_build,
            "read-only target preflight does not precede manifest writes or preserve the prior manifest on rejection",
        )

        target_coordinates = section(
            server_schema,
            r"local function validateTargetCoordinates\(bounds, destination\)",
            r"local function preflightLoaded",
        )
        checks.true(
            target_coordinates is not None,
            "pre-relocation target coordinate validation helper is missing",
        )
        if target_coordinates is not None:
            checks.true(
                "getWorld" in target_coordinates
                and 'invoke(world, "isValidSquare"' in target_coordinates
                and "getSquare(" not in target_coordinates
                and "getGridSquare" not in target_coordinates,
                "target coordinate validation reads squares or omits world legality checks",
            )
            checks.true(
                "relocation target" in target_coordinates
                and "RegionSlots.indexForAnchor" in target_coordinates
                and "outside the current RV slot matrix" in target_coordinates
                and "clearMinX ~= targetX - 50" in target_coordinates
                and "clearMaxX ~= targetX + 50" in target_coordinates
                and "clearMinY ~= targetY - 50" in target_coordinates
                and "clearMaxY ~= targetY + 50" in target_coordinates
                and "bounds.clearMaxX - bounds.clearMinX ~= 100" in target_coordinates
                and "bounds.clearMaxY - bounds.clearMinY ~= 100" in target_coordinates
                and "for y = bounds.clearMinY, bounds.clearMaxY - 1" in target_coordinates
                and "for x = bounds.clearMinX, bounds.clearMaxX - 1" in target_coordinates
                and "for y = bounds.roofMinY, bounds.roofMaxY" in target_coordinates
                and 'validWorldCoordinate(x, y, bounds.roofZ, "roof")' in target_coordinates
                and "bounds.roomMaxX - bounds.roomMinX + 1 ~= 6" in target_coordinates
                and "bounds.roomMaxY - bounds.roomMinY + 1 ~= 23" in target_coordinates
                and "bounds.wallMaxX - bounds.wallMinX + 1 ~= 7" in target_coordinates
                and "bounds.wallMaxY - bounds.wallMinY + 1 ~= 24" in target_coordinates
                and "bounds.roofMaxX - bounds.roofMinX + 1 ~= 6" in target_coordinates
                and "bounds.roofMaxY - bounds.roofMinY + 1 ~= 23" in target_coordinates
                and "final relocation center is outside the interior" in target_coordinates,
                "target coordinate validation does not enforce the fixed cleanup and 6x23 room contract",
            )

        preflight = section(
            server_schema,
            r"local function preflightLoaded\(cell, bounds(?:, allowIncomplete)?\)",
            r"local function targetAreaLoadStatus",
        )
        checks.true(preflight is not None, "loaded-area preflight is missing")
        if preflight is not None:
            checks.true(
                "validateTargetCoordinates(bounds" in preflight
                and "Missing squares are valid for this sparse template" in preflight
                and "requiredLoaded" not in preflight
                and "getSquare(" not in preflight
                and "return true" in preflight,
                "loaded-area preflight still requires non-template squares to exist",
            )

        load_wait = section(
            server_schema,
            r"local function targetAreaLoadStatus",
            r"local function eachStructureSquare",
        )
        checks.true(load_wait is not None, "post-teleport target loading wait is missing")
        if load_wait is not None:
            checks.true(
                "pcall(preflightLoaded" in load_wait
                and "cellOrError, bounds)" in load_wait
                and "loaded == false" in load_wait
                and "return false" in load_wait,
                "post-teleport wait does not retry an unavailable target cell",
            )
            checks.true(
                "return nil" in load_wait,
                "post-teleport loading wait does not fail closed on non-loading errors",
            )

        cleanup = section(
            generation_build,
            r"local function clearGenerationArea",
            r"local function buildGeneration",
        )
        checks.true(cleanup is not None, "fixed cleanup helper is missing")
        if cleanup is not None:
            checks.true(
                "ServerWorld.clearSquare(square, nil)" in cleanup
                and "ServerSchema.walkBounds(cell, bounds" in cleanup,
                "fixed cleanup helper does not walk loaded squares authoritatively",
            )

        structure_recalc = section(
            generation_build,
            r"local function recalcAndCheckStructure",
            r"local function clearGenerationArea",
        )
        checks.true(
            structure_recalc is not None
            and "recalcAt(x, y, bounds.z, false)" in structure_recalc
            and "recalcAt(entry.x, entry.y, entry.z, true)" in structure_recalc,
            "structure recalculation requires blank room cells or skips defined template hosts",
        )

        build_generation = section(
            generation_build,
            r"local function buildGeneration",
            r"local function markGenerationFailed",
        )
        checks.true(build_generation is not None, "buildGeneration helper is missing")
        if build_generation is not None:
            checks.true(
                "METAL_FLOOR" not in build_generation
                and "metalSprite" not in build_generation
                and "metal_floor" not in build_generation,
                "buildGeneration still enables the retired full metal-floor stage",
            )
            checks.true(
                'setGenerationPhase(manifest, generation, "CAPTURED_TEMPLATE")' in build_generation
                and "Template.metadata.objectCount ~= 412" in build_generation
                and "createCapturedTemplateObject(cell, square, entry" in build_generation
                and "entry.z == bounds.z or entry.z == bounds.roofZ" in build_generation
                and "square = ensureRoofSquare(cell, entry.x, entry.y, entry.z)" in build_generation
                and "captured object host square could not be created" in build_generation
                and "captured object differs from the current template" in build_generation,
                "buildGeneration does not apply only the current template object hosts",
            )

        entry_generator_helper = section(
            world_objects,
            r"local function ensureGeneratorForEntry\(player, record\)",
            r"local function compactQueue",
        )
        checks.true(
            entry_generator_helper is not None,
            "existing-entry generator check helper is missing",
        )
        if entry_generator_helper is not None:
            checks.true(
                'manifest.state ~= "READY"' in entry_generator_helper
                and 'manifest.phase ~= "COMMITTED"' in entry_generator_helper
                and "not sameIdentity(record, record.boundary)" in entry_generator_helper
                and "not sameIdentity(record, manifest.boundary)" in entry_generator_helper
                and "manifest.templateVersion ~= Constants.CAPTURED_TEMPLATE_VERSION" in entry_generator_helper
                and "if ambiguous then return false" in entry_generator_helper
                and "if present then return true end" in entry_generator_helper
                and entry_generator_helper.count("rollbackEntryGenerator") >= 2
                and "generatorOnClickedSquare" not in world_objects,
                "entry generator repair does not require the committed current identity or roll back failed creation",
            )
        entry_existing_pos = entry_exit.find("local function enterExisting")
        generator_entry_pos = entry_exit.find("construction.ensureGeneratorForEntry", entry_existing_pos)
        transition_pos = entry_exit.find("Boundary.beginTransition", generator_entry_pos)
        checks.true(
            entry_existing_pos >= 0
            and generator_entry_pos > entry_existing_pos
            and transition_pos > generator_entry_pos
            and "if generatorReady ~= true then" in entry_exit,
            "existing RV entry does not reject a failed generator check before transition/teleport",
        )

        generation = section(
            generation_flow,
            r"local function generateForPlayer",
            r"local function finalizeGenerationAfterRelocate",
        )
        checks.true(generation is not None, "generation transaction is missing")
        if generation is not None:
            checks.true(
                re.search(
                    r"(?m)^\s*buildOk, buildError = pcall\(buildGeneration,"
                    r"\s*player, layout, bounds,\s*generation, manifest\)"
                    ,
                    generation,
                )
                is not None,
                "room/object generation call is not enabled",
            )
            clear_call = generation.find(
                "local buildOk, buildError = pcall(clearGenerationArea"
            )
            build_call = generation.find(
                "buildOk, buildError = pcall(buildGeneration", clear_call
            )
            checks.true(
                clear_call >= 0 and build_call > clear_call,
                "buildGeneration is not ordered after clearGenerationArea",
            )
            cleanup_gate = section(
                generation,
                r"local buildOk, buildError = pcall\(clearGenerationArea",
                r"if not buildOk then",
            )
            checks.true(cleanup_gate is not None, "cleanup/build gate is missing")
            if cleanup_gate is not None:
                checks.true(
                    re.search(
                        r"if buildOk then\s+buildOk, buildError = pcall\(buildGeneration,"
                        r"\s*player, layout, bounds,\s*generation, manifest\)\s+end",
                        cleanup_gate,
                    )
                    is not None,
                    "cleanup failure does not short-circuit before buildGeneration",
                )
            rollback_start = generation.find("if not buildOk then")
            rollback_call = generation.find(
                "local rollbackOk, rollbackError = pcall(function()", rollback_start
            )
            remove_call = generation.find(
                "removeGeneration(cell, bounds, generation, manifest.rvId",
                rollback_call
            )
            checks.true(
                rollback_start >= 0
                and rollback_call > rollback_start
                and remove_call > rollback_call,
                "generation failure does not enter the existing rollback path",
            )
            final_relocate = generation.find("relocatePlayerIntoHouse, player, prepared")
            await_final_relocate = generation.find('return "await-final-relocate"')
            checks.true(
                final_relocate > build_call
                and await_final_relocate > final_relocate
                and 'setManifestState(manifest, "READY")' not in generation,
                "post-build final relocation does not hand off to its asynchronous ACK phase",
            )
            checks.true(
                'setGenerationPhase(manifest, generation, "FINAL_RELOCATE")' in generation
                and "finalRelocationOk" in generation
                and "removeGeneration(cell, bounds, generation, manifest.rvId" in generation,
                "final relocation failure does not enter the generation rollback path",
            )
            phase_pos = generation_flow.find(
                'setGenerationPhase(manifest, generation, "FINAL_RELOCATE")'
            )
            checks.true(
                phase_pos >= 0
                and "prepared.finalRelocationAcked = false" in generation_flow
                and "pending.finalRelocationAcked = true" in generation_ack
                and 'manifest.phase ~= "FINAL_RELOCATE"' in generation_ack
                and "publishFinalRelocationLedger" not in generation_flow + generation_ack,
                "generation FINAL_RELOCATE does not use its process-local ACK transaction",
            )

        final_relocation = section(
            generation_flow,
            r"local function relocatePlayerIntoHouse",
            r"local function generateForPlayer",
        )
        checks.true(final_relocation is not None, "final in-house relocation helper is missing")
        if final_relocation is not None:
            checks.true(
                'COMMAND_FINAL_RELOCATE' in final_relocation
                and 'x = x' in final_relocation
                and 'y = y' in final_relocation
                and 'z = z' in final_relocation
                and 'callSucceeded(player, "teleportTo", x, y, z)' in final_relocation
                and "finalRelocationSent = true" in final_relocation
                and "finalRelocationAcked = false" in final_relocation,
                "final relocation does not send and synchronize server-selected coordinates",
            )
            checks.true(
                "anchorX + 0.5" in final_relocation
                and "anchorY + 0.5" in final_relocation,
                "final relocation is not fixed to the house interior center",
            )

        final_ack = section(
            generation_ack,
            r"local function acknowledgeFinalRelocation",
            r"local function rollbackPendingGenerationWorld",
        )
        checks.true(
            final_ack is not None
            and "finalRelocationReasserted" in final_ack
            and "callSucceeded(livePlayerOrReason" in final_ack
            and "final relocation target proof mismatch" in final_ack,
            "final relocation ACK does not perform one bounded server-target reassertion",
        )
        final_generation = section(
            generation_flow,
            r"local function finalizeGenerationAfterRelocate",
            r"local function queueGeneration",
        )
        checks.true(
            final_generation is not None
            and "final relocation authoritative target is still synchronizing" in final_generation
            and "final relocation target pending" in final_generation
            and 'callSucceeded(player' in final_generation
            and '"teleportTo", target.x, target.y, target.z' in final_generation,
            "generation finalization does not wait for a post-update authoritative target proof",
        )
        checks.true(
            final_generation is not None
            and 'refreshServerRoomOwnershipGuard(guard, "before-commit")' in final_generation
            and 'refreshServerRoomOwnershipGuard(guard, "pre-mapping-commit")' in final_generation
            and final_generation.find('"before-commit"')
                < final_generation.find('setGenerationPhase(manifest, prepared.generation, "COMMITTED")')
            and final_generation.find('setManifestState(manifest, "READY")')
                < final_generation.find('"pre-mapping-commit"')
            and final_generation.find('"pre-mapping-commit"')
                < final_generation.find("local commitOk"),
            "manifest commit is missing its room-ownership scan after READY and before mapping publication",
        )

        tick = section(
            server_commands,
            r"function RV\.Server\.OnTick\(tick\)",
            r"function RV\.Server\.OnClientCommand",
        )
        checks.true(tick is not None, "pending generation OnTick processor is missing")
        if tick is not None:
            for required_guard in (
                "processServerRoomOwnershipGuards()",
                "RELOCATION_TIMEOUT_TICKS",
                "RELOCATION_MIN_TICKS",
                "RELOCATION_POST_ACK_TICKS",
                "resolvePendingPlayer(pending)",
                "validateGenerationPermission(playerOrReason)",
                "pcall(validateAuthoritativePlayer",
                "playerIsAtStagingDestination(playerOrReason",
            ):
                checks.true(
                    required_guard in tick,
                    f"pending generation tick omits {required_guard}",
                )
            checks.true(
                tick.find("playerIsAtStagingDestination") < tick.find("generateForPlayer"),
                "world generation can run before the server verifies relocation",
            )
            checks.true(
                tick.find("targetAreaLoadStatus") < tick.find("generateForPlayer")
                and tick.find("targetAreaLoadStatus") > tick.find("playerIsAtStagingDestination"),
                "cleanup can run before the post-teleport loaded-area wait",
            )
            checks.true(
                "pendingGeneration = nil" in tick,
                "pending generation is not cleared after completion/failure",
            )
            checks.true(
                "final relocation target synchronization timed out" in tick
                and "final relocation authoritative target is still synchronizing" in tick,
                "generation OnTick treats stale final-relocation coordinates as an immediate hard failure",
            )
            checks.true(
                "ServerSchema.targetAreaLoadStatus(playerOrReason" in tick
                and "local ok, reason = generateForPlayer" in tick
                and tick.find("ServerSchema.targetAreaLoadStatus(playerOrReason")
                < tick.find("local ok, reason = generateForPlayer"),
                "post-teleport target loading wait is not ordered before generation",
            )

            destination_wait = section(
                tick,
                r"if not atStaging then",
                r"local ok, reason = generateForPlayer",
            )
            checks.true(
                destination_wait is not None,
                "pending generation destination wait branch is missing",
            )
            if destination_wait is not None:
                wait_pos = destination_wait.find("relocationPositionStillSyncing(stagingReason)")
                wait_return_pos = destination_wait.find("return", wait_pos)
                hard_cancel_pos = destination_wait.find("cancelPending(stagingReason)")
                checks.true(
                    wait_pos >= 0
                    and wait_return_pos > wait_pos
                    and hard_cancel_pos > wait_return_pos,
                    "first server-position mismatch does not wait before hard cancellation",
                )
                checks.true(
                    "generateForPlayer" not in destination_wait,
                    "relocation wait branch can generate before exact server arrival",
                )

            wait_helper = section(
                roof_destinations,
                r"local function relocationPositionStillSyncing\(reason\)",
                r"local function roofRefreshPosition",
            )
            checks.true(
                wait_helper is not None,
                "relocation position synchronization helper is missing",
            )
            if wait_helper is not None:
                for transient_reason in (
                    "server player has not reached the relocation destination",
                    "server player has no current square after relocation",
                    "server player current square does not match relocation destination",
                ):
                    checks.true(
                        transient_reason in wait_helper,
                        f"relocation wait helper omits transient reason: {transient_reason}",
                    )

            permission_pos = tick.find("validateGenerationPermission(playerOrReason)")
            state_pos = tick.find("pcall(validateAuthoritativePlayer")
            ack_gate_pos = tick.find("if not pending.acknowledged")
            generation_pos = tick.find("local ok, reason = generateForPlayer")
            checks.true(
                permission_pos >= 0
                and state_pos > permission_pos
                and ack_gate_pos > state_pos
                and generation_pos > ack_gate_pos,
                "relocation wait does not recheck permission/liveness before the ack gate and generation",
            )
            timeout_pos = tick.find("Core.tickElapsedAtLeast(ctx.serverTick")
            timeout_cancel_pos = tick.find("cancelPending(", timeout_pos)
            checks.true(
                timeout_pos >= 0
                and timeout_cancel_pos > timeout_pos
                and "RELOCATION_TIMEOUT_TICKS + 1" in tick
                and generation_pos > timeout_cancel_pos,
                "relocation timeout does not cancel before any generation call",
            )

            for cancellation_reason in (
                "requesting player disconnected or was replaced",
                "requesting player identity changed",
                "sender is dead or has no authoritative death state",
                "sender lacks UseDebugContextMenu capability",
            ):
                checks.true(
                    cancellation_reason in player_validation + generation_flow,
                    f"relocation safety regression omits cancellation reason: {cancellation_reason}",
                )

        prepared_generate = section(
            generation_flow,
            r"local function generateForPlayer\(player, prepared\)",
            r"local function finalizeGenerationAfterRelocate",
        )
        checks.true(prepared_generate is not None, "prepared generation executor is missing")
        if prepared_generate is not None:
            checks.true(
                "makeLayout(" not in prepared_generate
                and "local layout = prepared.layout" in prepared_generate
                and "local bounds = prepared.bounds" in prepared_generate,
                "generation executor recomputes layout from the evacuated position",
            )
            old_bounds_rejection = prepared_generate.find(
                "if prepared.oldBounds ~= nil then"
            )
            destination_check = prepared_generate.find(
                "playerIsAtStagingDestination"
            )
            checks.true(
                old_bounds_rejection >= 0
                and "same-slot rebuild is refused because" in prepared_generate
                and "removeOldGeneration" not in prepared_generate
                and "ServerWorld.clearSquare" not in prepared_generate
                and "buildGeneration" in prepared_generate,
                "generation can clear an old same-slot room without a complete undo snapshot",
            )
            preflight_pos = prepared_generate.find("preflightLoaded(cell, bounds)")
            clear_pos = prepared_generate.find("pcall(buildGeneration")
            checks.true(
                destination_check >= 0
                and preflight_pos > destination_check
                and clear_pos > preflight_pos,
                "cleanup transaction does not keep the final loaded-area preflight before mutation",
            )
            arm_pos = prepared_generate.find("armClientRoomOwnershipGuard")
            server_guard_pos = prepared_generate.find(
                "registerServerRoomOwnershipGuard"
            )
            generation_build_pos = prepared_generate.find("pcall(buildGeneration")
            checks.true(
                arm_pos >= 0
                and server_guard_pos > arm_pos
                and generation_build_pos > server_guard_pos,
                "client/server stale-room guards are not registered before generation build",
            )
            checks.true(
                '"before-final-relocate"' in prepared_generate,
                "server stale-room refresh is missing immediately before final relocation",
            )

        structure_scan = section(
            server_schema,
            r"local function eachStructureSquare",
            r"M\.boundsFor = boundsFor",
        )
        checks.true(
            structure_scan is not None,
            "server complete old structure-footprint scanner is missing",
        )
        if structure_scan is not None:
            for footprint_field in (
                "wallMinX",
                "wallMaxX",
                "wallMinY",
                "wallMaxY",
                "roofMinX",
                "roofMaxX",
                "roofMinY",
                "roofMaxY",
                "roofZ",
            ):
                checks.true(
                    footprint_field in structure_scan,
                    f"server stale-room scan omits old footprint field {footprint_field}",
                )
            checks.true(
                "roomMinX" not in structure_scan
                and "roomMaxX" not in structure_scan
                and "roomMinY" not in structure_scan
                and "roomMaxY" not in structure_scan
                and "local seen" not in structure_scan
                and "seen[key]" not in structure_scan
                and "Layout.eachStructureCoordinate(scanBounds" in structure_scan
                and "ServerWorld.getSquare(cell, x, y, z)" in structure_scan
                and "ServerUtil.requiredInteger(bounds.wallMinX" in structure_scan
                and "ServerUtil.requiredInteger(bounds.roofZ" in structure_scan,
                "server stale-room scan does not share the coordinate traversal or retain strict server bounds and square access",
            )
        structure_coordinates = section(
            layout,
            r"function Layout\.eachStructureCoordinate",
            r"local function point",
        )
        checks.true(
            structure_coordinates is not None
            and "for x = bounds.wallMinX, bounds.wallMaxX do" in structure_coordinates
            and "for y = bounds.wallMinY, bounds.wallMaxY do" in structure_coordinates
            and "callback(x, y, bounds.z)" in structure_coordinates
            and "for i = 1, #templateObjects do" in structure_coordinates
            and "local captured = templateObjects[i]" in structure_coordinates
            and "if captured.z == C.ROOF_Z_OFFSET then" in structure_coordinates
            and "local seen = {}" in structure_coordinates
            and "if not seen[key] then" in structure_coordinates
            and "seen[key] = true" in structure_coordinates
            and "callback(x, y, bounds.roofZ)" in structure_coordinates
            and "roomMin" not in structure_coordinates,
            "shared structure traversal does not scan the base walls plus unique captured roof squares",
        )

        server_room_clear = section(
            room_ownership,
            r"local function clearInvalidRoomOwnershipReferences",
            r"local function registerServerRoomOwnershipGuard",
        )
        server_room_square_clear = section(
            room_ownership,
            r"local function clearInvalidRoomOwnershipSquare\(square\)",
            r"local function clearInvalidRoomOwnershipReferences",
        )
        checks.true(server_room_clear is not None, "server stale-room correction is missing")
        checks.true(
            server_room_square_clear is not None,
            "server stale-room square inspector is missing",
        )
        if server_room_clear is not None and server_room_square_clear is not None:
            checks.true(
                "clearInvalidRoomOwnershipSquare(square)" in server_room_clear
                and 'invoke(square, "getRoom")' in server_room_square_clear
                and 'invoke(square, "getRoomDef")' in server_room_square_clear
                and "if roomDef ~= nil then return false end" in server_room_square_clear,
                "server stale-room correction does not require room!=nil and RoomDef=nil",
            )
            checks.true(
                server_room_square_clear.count('callSucceeded(square, "setRoomID", -1)') == 1
                and server_room_square_clear.find("if roomDef ~= nil then return false end")
                < server_room_square_clear.find('callSucceeded(square, "setRoomID", -1)'),
                "server stale-room correction is absent, duplicated, or outside the RoomDef=nil branch",
            )
            checks.true(
                '"setRoom"' not in server_room_square_clear
                and "ResetIsoWorldRegion" not in server_room_square_clear
                and "RecalcAllWithNeighbours" not in server_room_square_clear,
                "server stale-room correction mutates valid engine room/region state",
            )
            checks.true(
                "structureCoordinates(oldBounds, markExpected)" in server_room_clear
                and "structureCoordinates(newBounds, markExpected, materializedNewRoofCoordinates)"
                    in server_room_clear
                and "for i = 1, #expectedCoordinates do" in server_room_clear
                and "ServerWorld.getSquare(cell, coordinate.x" in server_room_clear,
                "server stale-room correction does not cover complete old and new footprints",
            )

        room_guard_broadcast = section(
            room_ownership,
            r"local function armClientRoomOwnershipGuard",
            r"local function armTargetedClientRoomOwnershipGuard",
        )
        checks.true(room_guard_broadcast is not None, "client room-guard broadcast is missing")
        if room_guard_broadcast is not None:
            checks.true(
                'callGlobalSucceeded("sendServerCommand", COMMAND_MODULE,'
                in room_guard_broadcast
                and 'callGlobal("sendServerCommand", player,'
                not in room_guard_broadcast,
                "stale-room guard is targeted only to the requester instead of all clients",
            )
            checks.true(
                "copyRoomRefreshBounds(payload, \"old\", oldBounds)"
                in room_guard_broadcast
                and "copyRoomRefreshBounds(payload, \"new\", newBounds)"
                in room_guard_broadcast,
                "broadcast room guard does not carry server-authoritative old/new bounds",
            )

        targeted_room_guard = section(
            room_ownership,
            r"local function armTargetedClientRoomOwnershipGuard",
            r"ctx\.armTargetedClientRoomOwnershipGuard\s*=",
        )
        checks.true(
            targeted_room_guard is not None,
            "targeted existing-entry room monitor helper is missing",
        )
        if targeted_room_guard is not None:
            checks.true(
                'callGlobalSucceeded("sendServerCommand", player, COMMAND_MODULE,'
                in targeted_room_guard
                and "hasOld = false" in targeted_room_guard
                and 'copyRoomRefreshBounds(payload, "new", newBounds)'
                in targeted_room_guard,
                "targeted room monitor does not send only the current server bounds",
            )

        current_room_monitor = section(
            record_validation,
            r"function RV\.Server\.armCurrentRoomOwnershipMonitor",
            r"\nend\s*\n\s*end\s*$",
        )
        checks.true(
            current_room_monitor is not None,
            "current-manifest room monitor API is missing",
        )
        if current_room_monitor is not None:
            checks.true(
                "pcall(manifestTable)" in current_room_monitor
                and "RV.Server.currentRVManifestForBoundary(" in current_room_monitor
                and "manifest.bounds" in current_room_monitor
                and "manifest.rvId" in current_room_monitor
                and "record.rvId" in current_room_monitor
                and "record.generation" in current_room_monitor
                and "record.bitmapVersion" in current_room_monitor
                and "return false, Constants.INVALID_RV_DATA"
                in current_room_monitor,
                "existing-entry monitor does not fail closed on current identity/schema",
            )

        server_guard_tick = section(
            room_ownership,
            r"local function processServerRoomOwnershipGuards",
            r"local function copyRoomRefreshBounds",
        )
        checks.true(server_guard_tick is not None, "server stale-room tick guard is missing")
        if server_guard_tick is not None:
            checks.true(
                "ROOM_OWNERSHIP_MIN_TICKS" in server_guard_tick
                and "ROOM_OWNERSHIP_STABLE_TICKS" in server_guard_tick
                and "ROOM_OWNERSHIP_MAX_TICKS" in server_guard_tick,
                "server stale-room guard lacks bounded and stable lifecycle",
            )
            checks.true(
                "roomOwnershipGuards[finished[i]] = nil" in server_guard_tick,
                "server stale-room guard is not cleaned after completion/timeout",
            )
            checks.true(
                "ctx.roofRefreshRelocationGroup ~= nil or ctx.roofRefreshGroupFinalReturn ~= nil"
                in server_guard_tick
                and "pause only this non-transactional cleanup until the member returns"
                in server_guard_tick,
                "server room-ownership guard still scans remote cells during roof relocation",
            )

        client_room_clear = section(
            client_room_ownership,
            r"local function inspectRoomOwnershipSquare",
            r"local function beginRoomOwnershipRefresh",
        )
        checks.true(client_room_clear is not None, "client stale-room correction is missing")
        if client_room_clear is not None:
            checks.true(
                "local roomOk, room = pcall" in client_room_clear
                and "return square:getRoom()" in client_room_clear
                and "local roomDefOk, roomDef = pcall" in client_room_clear
                and "return square:getRoomDef()" in client_room_clear
                and "if roomDef ~= nil then return true, 0 end" in client_room_clear,
                "client stale-room correction does not require room!=nil and RoomDef=nil",
            )
            checks.true(
                client_room_clear.count("square:setRoomID(-1)") == 1
                and client_room_clear.find("if roomDef ~= nil then return true, 0 end")
                < client_room_clear.find("square:setRoomID(-1)"),
                "client stale-room correction is absent, duplicated, or outside the RoomDef=nil branch",
            )
            checks.true(
                "setRoom(nil)" not in client_room_clear
                and "ResetIsoWorldRegion" not in client_room_clear
                and "RecalcAllWithNeighbours" not in client_room_clear,
                "client stale-room correction mutates valid engine room/region state",
            )
            checks.true(
                "eachStructureSquare(cell, guard.oldBounds, inspect)"
                in client_room_clear
                and "eachStructureSquare(cell, guard.newBounds, inspect)"
                in client_room_clear,
                "client stale-room correction does not cover complete old and new footprints",
            )
            client_room_refresh = section(
                client_room_ownership,
                r"local function refreshInvalidRoomOwnership",
                r"local function refreshCurrentPlayerRoomOwnership",
            )
            checks.true(
                client_room_refresh is not None
                and "inspectRoomOwnershipSquare(square)" in client_room_refresh,
                "client complete room scan bypasses the safe room ownership inspector",
            )

        client_room_event = section(
            client_room_ownership,
            r"local function requestRoomOwnershipScan",
            r"local function beginRoomOwnershipRefresh",
        )
        checks.true(
            client_room_event is not None
            and "if x == nil then return end" in client_room_event
            and "x == nil or coordinatesInBounds" not in client_room_event,
            "client room mutation events wake every guard when object coordinates are unavailable",
        )

        client_structure_scan = section(
            client_room_ownership,
            r"local function eachStructureSquare",
            r"local function refreshInvalidRoomOwnership",
        )
        checks.true(
            client_structure_scan is not None,
            "client complete old structure-footprint scanner is missing",
        )
        if client_structure_scan is not None:
            checks.true(
                "Layout.eachStructureCoordinate(bounds" in client_structure_scan
                and "cell:getGridSquare(x, y, z)" in client_structure_scan
                and all(
                    field not in client_structure_scan
                    for field in ("roomMinX", "roomMaxX", "roomMinY", "roomMaxY")
                )
                and "local seen" not in client_structure_scan
                and "for x =" not in client_structure_scan,
                "client stale-room scan does not use the shared traversal and client square API",
            )

        client_room_begin = section(
            client_room_ownership,
            r"local function beginRoomOwnershipRefresh",
            r"local function updateRoomOwnershipGuards",
        )
        checks.true(client_room_begin is not None, "client room-guard registration is missing")
        if client_room_begin is not None:
            checks.true(
                "localPlayerByOnlineId" not in client_room_begin
                and "roomOwnershipGuardKey" in client_room_begin
                and "roomOwnershipGuards[key]" in client_room_begin,
                "client room guard is requester-only or not keyed by full RV identity",
            )
            checks.true(
                "local rvId = args.rvId" in client_room_begin
                and "local bitmapVersion = finiteInteger(args.bitmapVersion)" in client_room_begin
                and "rvId = tostring(rvId)" in client_room_begin
                and "bitmapVersion = bitmapVersion" in client_room_begin,
                "client room guard does not retain the full RV boundary identity",
            )
            checks.true(
                "for existingKey, existingGuard in pairs(roomOwnershipGuards)" in client_room_begin
                and "roomOwnershipGuards[existingKey] = nil" in client_room_begin,
                "client room monitor retains stale geometry after a same-RV generation swap",
            )

        final_client_room = section(
            client_relocation_source,
            r"local function tryApplyFinalRelocation",
            r"local function applyFinalRelocation",
        )
        checks.true(
            final_client_room is not None
            and "local rvId = args.rvId" in final_client_room
            and "local bitmapVersion = finiteInteger(args.bitmapVersion)" in final_client_room
            and "guard.bitmapVersion ~= bitmapVersion" in final_client_room,
            "final relocation does not reject stale RV generation/bitmap identity",
        )

        client_room_tick = section(
            client_room_ownership,
            r"local function updateRoomOwnershipGuards",
            r"ctx\.updateRoomOwnershipGuards\s*=",
        )
        checks.true(client_room_tick is not None, "client room-guard tick processor is missing")
        if client_room_tick is not None:
            checks.true(
                "ROOM_OWNERSHIP_MIN_TICKS" in client_room_tick
                and "guard.monitorReady" in client_room_tick,
                "client room monitor does not track its readiness age",
            )
            checks.true(
                "ROOM_OWNERSHIP_MAX_TICKS" not in client_room_ownership
                and "roomOwnershipGuards[finished[i]] = nil" not in client_room_tick
                and "client room ownership guard active generation=" in client_room_tick,
                "client room monitor still retires after the initial generation tail",
            )
            checks.true(
                re.search(r"local clientTick\s*=\s*0", client) is not None
                and "ctx.clientTick = ctx.clientTick + 1" in client_relocation_source
                and "refreshCurrentPlayerRoomOwnership(guard)" in client_room_tick
                and "guard.scanRequested" in client_room_tick,
                "client room monitor lacks an owned tick counter or mutation-safe immediate scan",
            )
            checks.true(
                "if (guard.scanRetryRemaining or 0) > 0 then" in client_room_tick
                and "guard.scanRequested = true" in client_room_tick
                and "if currentScanOk and currentCleared > 0 then" in client_room_tick
                and "scheduleRoomOwnershipScan(guard, 0)" in client_room_tick,
                "client room monitor drops failed full-scan retries",
            )

        utility_mapping_sync = section(
            utility_server,
            r"local function syncUtilityMappings",
            r"function M\.onTick",
        )
        checks.true(
            utility_mapping_sync is not None,
            "utility mapping sync helper is missing",
        )
        if utility_mapping_sync is not None:
            checks.true(
                re.search(
                    r"if syncOk and accepted == true and type\(identity\) == \"table\" then\s+"
                    r"mappingSyncState\[recipientKey\]",
                    utility_mapping_sync,
                ) is not None,
                "utility mapping sync caches a business failure or send failure",
            )

        server_room_event = section(
            room_ownership,
            r"local function requestRoomOwnershipScan",
            r"local function requestRoomOwnershipRemovalScan",
        )
        checks.true(
            server_room_event is not None
            and "if x == nil then" in server_room_event
            and server_room_event.find("if x == nil then")
                < server_room_event.find("for _, guard in pairs(roomOwnershipGuards) do")
            and "x == nil or" not in server_room_event,
            "server room mutation events wake every guard when object coordinates are unavailable",
        )

        checks.true(
            "GameServer.sendTeleport(" not in server,
            "server Lua calls GameServer.sendTeleport even though B42.20 does not expose it",
        )
        shared_number = section(
            constants,
            r"function C\.finiteNumber\(value\)",
            r"function C\.finiteInteger",
        )
        shared_integer = section(
            constants,
            r"function C\.finiteInteger\(value\)",
            r"C\.MOD_ID",
        )
        checks.true(
            shared_number is not None
            and 'valueType == "number"' in shared_number
            and 'valueType == "string"' in shared_number
            and "return value + 0" in shared_number
            and "pcall" in shared_number
            and "number ~= number" in shared_number
            and "math.huge" in shared_number
            and shared_integer is not None
            and "C.finiteNumber(value)" in shared_integer
            and "math.floor(number) ~= number" in shared_integer
            and "local finiteNumber = C.finiteNumber" in client_room_ownership
            and "local finiteInteger = C.finiteInteger" in client_room_ownership
            and "local finiteNumber = C.finiteNumber" in railroader_client
            and "local finiteInteger = C.finiteInteger" in railroader_client,
            "client adapters do not share Java-aware finite and integer conversion with NaN/infinity rejection",
        )
        client_relocation = section(
            client_relocation_source,
            r"function Client\.onServerCommand",
            r"function Client\.onTick",
        )
        checks.true(client_relocation is not None, "client relocation command handler is missing")
        if client_relocation is not None:
            teleport_pos = client_relocation.find("playerObj:teleportTo")
            checks.true(
                teleport_pos >= 0
                and client_relocation.find("pendingRelocation = {") > teleport_pos,
                "client does not queue a delayed acknowledgement after teleportTo",
            )
            checks.true(
                "playerObj:getCurrentSquare()" not in client_relocation,
                "client incorrectly assumes teleportTo refreshes current square immediately",
            )
            checks.true(
                re.search(
                    r"(?m)^\s*(?:local\s+\w+\s*=\s*)?\w+:getGridSquare\s*\(",
                    client_relocation,
                )
                is None,
                "client rejects remote relocation before the target chunk can stream",
            )
            checks.true(
                "localPlayerByOnlineId(onlineId)" in client_relocation,
                "targeted relocation is not restricted to the matching local player",
            )

        final_client_relocation = section(
            client_relocation_source,
            r"local function tryApplyFinalRelocation",
            r"function Client\.onServerCommand",
        )
        checks.true(
            final_client_relocation is not None,
            "client final relocation command helper is missing",
        )
        if final_client_relocation is not None:
            checks.true(
                "playerObj:teleportTo(x, y, z)" in final_client_relocation
                and "sendFinalRelocationAck" in final_client_relocation,
                "client final relocation does not apply the server-selected center",
            )
            cleanup_pos = final_client_relocation.find("tryFinalRelocationGuardScan")
            teleport_pos = final_client_relocation.find("playerObj:teleportTo")
            checks.true(
                cleanup_pos >= 0
                and teleport_pos > cleanup_pos
                and "generation" in final_client_relocation
                and "pendingFinalRelocation" in final_client_relocation,
                "client final relocation does not complete its guarded full scan before teleport",
            )
            checks.true(
                "COMMAND_FINAL_RELOCATE_ACK" in final_client_relocation
                and "sendClientCommand" in final_client_relocation
                and "pendingRelocation = {" not in final_client_relocation,
                "client final relocation does not use its separate strict ACK flow",
            )
        server_command_handler = section(
            client_relocation_source,
            r"function Client\.onServerCommand",
            r"function Client\.onTick",
        )
        checks.true(
            server_command_handler is not None
            and "COMMAND_FINAL_RELOCATE" in (server_command_handler or "")
            and "applyFinalRelocation(args)" in (server_command_handler or ""),
            "client server-command handler does not route FinalRelocate separately",
        )

        client_tick = section(
            client_relocation_source,
            r"function Client\.onTick\(\)",
            r"Events\.OnServerCommand\.Add",
        )
        checks.true(client_tick is not None, "client delayed relocation OnTick is missing")
        if client_tick is not None:
            checks.true(
                "updateRoomOwnershipGuards()" in client_tick,
                "client OnTick does not run the stale-room guard lifecycle",
            )
            current_pos = client_tick.find("playerObj:getCurrentSquare()")
            ack_pos = client_tick.find("COMMAND_RELOCATE_ACK")
            checks.true(
                current_pos >= 0 and ack_pos > current_pos,
                "client acknowledges before its current square reaches the safe destination",
            )
            ack_payload = re.search(
                r"sendClientCommand\([\s\S]*?COMMAND_RELOCATE_ACK,\s*"
                r"\{\s*token\s*=\s*pending\.token\s*\}\)",
                client_tick,
            )
            checks.true(
                ack_payload is not None,
                "relocation acknowledgement must carry only the opaque token",
            )
            checks.true(
                "RELOCATION_TIMEOUT_TICKS" in client_tick
                and "pendingRelocation = nil" in client_tick,
                "client relocation wait has no timeout/cleanup",
            )

        preflight = section(
            server_schema,
            r"local function preflightLoaded\(cell, bounds(?:, allowIncomplete)?\)",
            r"local function targetAreaLoadStatus",
        )
        checks.true(preflight is not None, "preflightLoaded function is missing")
        if preflight is not None:
            checks.true(
                "validateTargetCoordinates(bounds" in preflight,
                "preflight does not reuse legal world-coordinate validation",
            )
            checks.true(
                'requiredLoaded(x, y, bounds.roofZ, "roof")' not in preflight,
                "preflight still requires every roof square to exist",
            )
            checks.true(
                "validateTargetCoordinates(bounds" in preflight
                and 'requiredLoaded(x, y, bounds.roofZ, "roof")' not in preflight,
                "preflight does not allow missing roof squares for the build phase",
            )

        roof_helper = section(
            world_objects,
            r"local function ensureRoofSquare\(cell, x, y, z\)",
            r"local function createFloor",
        )
        checks.true(roof_helper is not None, "ensureRoofSquare helper is missing")
        if roof_helper is not None:
            checks.true(
                "IsoGridSquare" in roof_helper,
                "roof helper does not use the official IsoGridSquare constructor",
            )
            checks.true(
                re.search(r'ConnectNewSquare",\s*created,\s*false', roof_helper)
                is not None,
                "roof helper does not connect constructor-created squares",
            )
            checks.true(
                "createNewGridSquare" in roof_helper,
                "roof helper has no documented alternate square-creation API path",
            )
            checks.true(
                roof_helper.count("getSquare(cell, x, y, z)") >= 2,
                "roof helper does not verify the connected square by reading it back",
            )

        roof_phase = section(
            generation_build,
            r'setGenerationPhase\(manifest, generation, "CAPTURED_TEMPLATE"\)',
            r'setGenerationPhase\(manifest, generation, "STRUCTURE_RECALC"\)',
        )
        checks.true(roof_phase is not None, "CAPTURED_TEMPLATE phase is missing")
        if roof_phase is not None:
            checks.true(
                "ensureRoofSquare(cell, entry.x, entry.y, entry.z)" in roof_phase,
                "captured roof objects do not create or reuse their upper squares",
            )
            checks.true(
                roof_phase.find("ensureRoofSquare(cell, entry.x")
                < roof_phase.find("createCapturedTemplateObject(cell, square, entry"),
                "captured template objects are added before their square exists",
            )

        captured_factory = section(
            world_objects,
            r"local function createCapturedTemplateObject",
            r"-- Error objects are not required",
        )
        checks.true(
            captured_factory is not None
            and all(
                f'entry.class == "{class_name}"' in captured_factory
                for class_name in ("IsoObject", "IsoThumpable", "IsoWindow", "IsoLightSwitch")
            )
            and "applyCapturedIdentityAndState" in captured_factory
            and "captured object client transmission failed" in captured_factory
            and "createFurniture(" not in generation_build
            and "createLight(" not in generation_build,
            "generation does not construct captured classes from their current template entries",
        )
        checks.true(
            "function Menu.utilityEntryPoint" in railroader_client
            and "ENTRY_INTERNAL" in railroader_client
            and "ENTRY_LOCOMOTIVE" in railroader_client,
            "client utility menu does not preserve its two RV entry-point intents",
        )
        checks.true(
            "local function readRoot" in utility_store
            and "local function copyTable" in utility_store
            and "record = copyTable(persisted)" in utility_store
            and "value.records[id] = copyTable(record)" in utility_store
            and "local previous = value.records[id]" in utility_store
            and "value.records[id] = previous" in utility_store,
            "utility store does not isolate live ModData records across commit failure",
        )
        initialize_record = section(
            utility_server,
            r"function M\.initializeRecord",
            r"return M",
        )
        checks.true(
            initialize_record is not None
            and "Power.initializeRecord(identity, context)" in initialize_record
            and "Water.ensureUsageTank" not in initialize_record
            and "local committed, reason = Store.commit" not in initialize_record,
            "utility initialization constructs or migrates a Water world object instead of using the fresh current ledger",
        )
        checks.true(
            "RAIN_BARREL" not in server
            and "RainBarrel" not in server
            and "SRainBarrelSystem" not in server
            and "rainCollector" not in server
            and "layout.barrel" not in server,
            "server still contains the retired visible rain-barrel path",
        )
        special_add = section(
            world_objects,
            r"local function addSpecialObject\(square, object\)",
            r"local function createWall",
        )
        checks.true(special_add is not None, "addSpecialObject helper is missing")
        if special_add is not None:
            checks.true(
                "transmitCompleteItemToClients" not in special_add,
                "addSpecialObject still sends a premature full-object packet",
            )
            checks.true(
                "recalcSquare(square)" in special_add,
                "addSpecialObject no longer recalculates after attachment",
            )
        generator = section(
            world_objects,
            r"local function createGenerator",
            r"local function createFurniture",
        )
        checks.true(generator is not None, "createGenerator function is missing")
        if generator is not None:
            checks.true(
                generator.count("transmitCompleteItemToClients") == 1,
                "generator does not have exactly one final full-object packet",
            )
            checks.true(
                generator.find("transmitCompleteItemToClients") > generator.find("setActivated"),
                "generator full-object packet is sent before final activation",
            )
            checks.true(
                generator.find("setActivated") >= 0
                and generator.find("tagObject") > generator.find("setActivated")
                and generator.find("addSpecialObject") > generator.find("tagObject"),
                "generator is not initialized and tagged before square attachment",
            )
            checks.true(
                all(
                    network_call not in generator
                    for network_call in (
                        "transmitModData",
                        "sendObjectChange",
                        '"sync"',
                        "transmitUpdatedSpriteToClients",
                        "transmitRemoveItemFromSquare",
                    )
                ),
                "generator emits a pre-complete object-index network packet",
            )

        checks.true(
            "createRainBarrel" not in server
            and "ensureRainBarrelGlobalObject" not in server
            and "getRainBarrelGlobalClass" not in server,
            "retired rain-barrel creator or global bridge remains in the server facade",
        )

        captured_builder = section(
            world_objects,
            r"local function createCapturedTemplateObject",
            r"-- Error objects are not required",
        )
        checks.true(
            captured_builder is not None
            and "IsoThumpable" in captured_builder
            and "IsoWindow" in captured_builder
            and "captured object client transmission failed" in captured_builder,
            "captured-template builder does not transmit the current captured object classes",
        )

        captured_template_phase = section(
            generation_build,
            r'setGenerationPhase\(manifest, generation, "CAPTURED_TEMPLATE"\)',
            r'setGenerationPhase\(manifest, generation, "STRUCTURE_RECALC"\)',
        )
        checks.true(
            captured_template_phase is not None
            and "for i = 1, #templateObjects do" in captured_template_phase
            and "local captured = capturedTemplateObjects[i]" in captured_template_phase
            and "createCapturedTemplateObject(cell, square, entry" in captured_template_phase
            and "captured object differs from the current template" in captured_template_phase
            and re.search(
                r'setGenerationPhase\(manifest, generation,\s*"COUNTER_SINK"',
                generation_build,
            ) is None,
            "generation does not apply the current captured template entry by entry",
        )

        cab_region = section(
            template_protection_repair,
            r"local function isCabCoordinate",
            r"local function templateEntry",
        )
        cab_editable = section(
            template_protection_repair,
            r"local function isCabEditableCoordinate",
            r"local function isRemovalScopeCoordinate",
        )
        cab_side_host = section(
            template_protection_repair,
            r"local function isCabSideHostCoordinate",
            r"local function isRuntimeDoorOrWindow",
        )
        template_protection_repair_index = section(
            template_protection_repair,
            r"local function buildRepairIndex",
            r"local function footprintAllowsRemoval",
        )
        player_build_policy = section(
            boundary_objects,
            r"local function disallowedPlayerBuild",
            r"function Boundary\.isDisallowedPlayerBuild",
        )
        checks.true(
            all(
                cell in captured_shell_cells
                for cell in ((-4, -2), (-4, -1), (-4, 2), (2, -2))
            )
            and all(token in constants for token in (
                "C.CAB_MIN_OFFSET_X = -4", "C.CAB_MAX_OFFSET_X = 1",
                "C.CAB_MIN_OFFSET_Y = -2", "C.CAB_MAX_OFFSET_Y = 1",
            ))
            and cab_region is not None
            and all(token in cab_region for token in (
                "Constants.CAB_MIN_OFFSET_X", "Constants.CAB_MAX_OFFSET_X",
                "Constants.CAB_MIN_OFFSET_Y", "Constants.CAB_MAX_OFFSET_Y",
                "return false",
            ))
            and cab_editable is not None
            and "index.cabEditableCoordinates[coordinateKey(x, y, z)] == true" in cab_editable
            and "index.protectedCoordinates[coordinate] = true" in template_protection_repair_index
            and cab_side_host is not None
            and "Constants.CAB_MAX_OFFSET_X + 1" in cab_side_host
            and "Constants.CAB_MAX_OFFSET_Y + 1" in cab_side_host
            and template_protection_repair_index is not None
            and "for templateIndex = 1, ProtectionManifest.OBJECT_COUNT do" in template_protection_repair_index
            and "local protected = protectionClass == ProtectionManifest.RESTORE_ONLY" in template_protection_repair_index
            and "or protectionClass == ProtectionManifest.PROHIBITED" in template_protection_repair_index
            and "if protected and not editableCab and not sideDoorOrWindow then" in template_protection_repair_index
            and "index.byCoordinate[coordinate]" in template_protection_repair_index
            and "function Boundary.sampleTemplateProtectionRepairPlayer" in template_protection_repair
            and "for offsetY = -1, 1 do" in template_protection_repair
            and "for offsetX = -1, 1 do" in template_protection_repair
            and "enqueueXY(queue, centerX + offsetX, centerY + offsetY)" in template_protection_repair
            and "function Boundary.processTemplateProtectionRepairQueue" in template_protection_repair
            and "local entry = popXY(selected.queue)" in template_protection_repair
            and "capturedClasses[captured.class] = true" in template_protection_repair
            and player_build_policy is not None
            and "CAB_MIN_OFFSET_X" in player_build_policy
            and "CAB_MAX_OFFSET_X" in player_build_policy
            and "CAB_MIN_OFFSET_Y" in player_build_policy
            and "CAB_MAX_OFFSET_Y" in player_build_policy
            and "if cabOnly or buildableOnly then return false end" in player_build_policy,
            "static repair classes, cab edits, and queued dynamic-object cleanup do not follow the current policy",
        )
        repair_candidate = section(
            template_protection_repair,
            r"local function isProtectedBuildingCandidate",
            r"local function isWhitelistedTemplateObject",
        )
        checks.true(
            repair_candidate is not None
            and "not sameIdentity(index, boundary)" in repair_candidate
            and "ProtectionManifest.get(templateIndex)" in repair_candidate
            and "currentProtectedCoordinateTargets(index, boundary" in repair_candidate
            and "currentTemplateTagMismatch(object, expected" in repair_candidate
            and "objectMatchesCapturedIdentity(object, expected)" in repair_candidate
            and "expected.x ~= x or expected.y ~= y or expected.z ~= z" in repair_candidate
            and "className ~= expected.class" in repair_candidate,
            "template repair candidate is not tied to the current protected template identity and live class/position",
        )

        def repair_candidate_identity_matches(boundary, index, expected, tag,
            position, player_object=False):
            if player_object or not all(isinstance(value, dict) for value in (
                boundary, index, expected, tag, position
            )):
                return False
            identity = ("rvId", "generation", "bitmapVersion")
            if any(boundary.get(key) != index.get(key)
                or boundary.get(key) != tag.get(key) for key in identity):
                return False
            if tag.get("templateIndex") != expected.get("templateIndex"):
                return False
            if any(expected.get(key) != position.get(key)
                for key in ("x", "y", "z")):
                return False
            if any(tag.get("template" + key.upper()) != expected.get(key)
                for key in ("x", "y", "z")):
                return False
            return tag.get("templateClass") == expected.get("class")

        current_boundary = {
            "rvId": "rv-current", "generation": 8, "bitmapVersion": 6,
        }
        current_index = dict(current_boundary)
        current_expected = {
            "templateIndex": 24, "x": 20004, "y": 2048, "z": 1,
            "class": "IsoThumpable",
        }
        current_tag = {
            **current_boundary, "templateIndex": 24,
            "templateX": 20004, "templateY": 2048, "templateZ": 1,
            "templateClass": "IsoThumpable",
        }
        current_position = {"x": 20004, "y": 2048, "z": 1}
        checks.true(
            repair_candidate_identity_matches(
                current_boundary, current_index, current_expected,
                current_tag, current_position
            )
            and not repair_candidate_identity_matches(
                current_boundary, current_index, current_expected,
                {**current_tag, "role": "player-build", "templateIndex": None},
                current_position, player_object=True
            )
            and not repair_candidate_identity_matches(
                current_boundary, current_index, current_expected,
                {**current_tag, "generation": 7}, current_position
            )
            and not repair_candidate_identity_matches(
                current_boundary, current_index, current_expected,
                {**current_tag, "rvId": "rv-other-slot"}, current_position
            ),
            "repair authorization accepts a player object, old generation, or another RV slot",
        )

        captured_identity = section(
            template_protection_repair,
            r"local function objectMatchesCapturedIdentity",
            r"local function objectMatchesCaptured\(",
        )
        checks.true(
            captured_identity is not None
            and "ServerUtil.classInstance(object, entry.class)" in captured_identity
            and 'ServerUtil.invoke(object, "getName")' in captured_identity
            and 'ServerUtil.invoke(object, "getDir")' in captured_identity
            and "entry.sprite" in captured_identity
            and "entry.north" in captured_identity
            and repair_candidate is not None
            and "not objectMatchesCapturedIdentity(object, expected)" in repair_candidate,
            "repair candidates are not classified by the current template's exact engine class and live object identity",
        )

        floor_helper = section(
            world_objects,
            r"local function createFloor",
            r"local function addSpecialObject",
        )
        checks.true(floor_helper is not None, "createFloor helper is missing")
        if floor_helper is not None:
            checks.true(
                "previousSprite" in floor_helper and "createdByGeneration" in floor_helper,
                "floor helper does not persist its pre-generation snapshot",
            )
            checks.true(
                'transmitUpdatedSpriteToClients' in floor_helper,
                "floor replacement does not use the B42 sprite-update packet",
            )
            checks.true(
                'transmitModData' in floor_helper,
                "existing floor replacement does not send its generation/modData delta",
            )
            checks.true(
                floor_helper.count("transmitCompleteItemToClients") == 1,
                "new floor path does not have exactly one complete packet",
            )
            updated_position = floor_helper.find("transmitUpdatedSpriteToClients")
            mod_data_position = floor_helper.find("transmitModData")
            complete_position = floor_helper.find("transmitCompleteItemToClients")
            checks.true(
                updated_position >= 0
                and mod_data_position > updated_position
                and complete_position > mod_data_position,
                "floor sprite/modData incremental updates and new-floor complete packet are misordered",
            )
            checks.true(
                "new floor client transmission failed" in floor_helper
                and "existing floor sprite transmission failed" in floor_helper
                and "existing floor modData transmission failed" in floor_helper,
                "floor client transmission failures are not hard errors",
            )
        rollback_remove = section(
            server_world,
            r"local function removeGenericObject",
            r"local function removeObject",
        )
        checks.true(rollback_remove is not None, "removeGenericObject helper is missing")
        if rollback_remove is not None:
            checks.true(
                "restoreTaggedFloor" in rollback_remove,
                "rollback does not attempt to restore an existing floor",
            )
            checks.true(
                'transmitRemoveItemFromSquare' in rollback_remove
                and 'removeFromSquare' not in rollback_remove
                and 'removeFromWorld' not in rollback_remove,
                "rollback duplicates the B42 removal path with manual detachment",
            )
            checks.true(
                "squareContainsObject" in rollback_remove,
                "rollback removal has no authoritative postcondition",
            )
            checks.true(
                'invoke(square, "setFloor"' not in rollback_remove,
                "rollback still calls the nonexistent IsoGridSquare:setFloor API",
            )
        special_remove = section(
            server_world,
            r"local function deregisterSpecialSystems",
            r"local function removeCorpse",
        )
        checks.true(special_remove is not None, "special-system removal helper is missing")
        if special_remove is not None:
            checks.true(
                "return object" in special_remove
                and "unregisterRainBarrelGlobalObject" not in special_remove
                and "SRainBarrelSystem" not in special_remove
                and 'callGlobal("triggerEvent"' not in special_remove
                and "local systems =" not in special_remove,
                "utility cleanup still assumes a global rain-barrel system",
            )
        rollback = section(
            room_ownership,
            r"local function removeGeneration",
            r"ctx\.removeGeneration\s*=",
        )
        checks.true(rollback is not None, "removeGeneration function is missing")
        if rollback is not None:
            checks.true(
                "rollback verification found" in rollback
                and "isTaggedForGeneration" in rollback,
                "rollback does not verify that tagged objects are gone",
            )
            checks.true(
                rollback.count(
                    "ServerSchema.walkBounds(cell, bounds, function(square)"
                ) == 2
                and "end, true)" not in rollback
                and "ServerWorld.strictSquareSnapshot(square)" in rollback
                and "complete ~= true" in rollback
                and "ServerWorld.clearSquare(square, generation, rvId, bitmapVersion)"
                    in rollback
                and "if remaining > 0 then" in rollback
                and "if not square and requireLoaded == true then" in server_schema
                and re.search(
                    r"if square then\s+fn\(square, x, y, z\)\s+end",
                    server_schema,
                ) is not None,
                "generation rollback does not use sparse bounds with strict per-square object verification",
            )

        checks.true(
            re.search(
                r"sendClientCommand\([^\n]*\{\s*\}\s*\)", client_relocation_source
            )
            is not None,
            "client request no longer uses an empty payload",
        )

    if start_bat_path.is_file():
        start_bat = read_utf8(start_bat_path)
        checks.true(
            re.search(r"(?im)^@?chcp\s+65001\s+>nul", start_bat) is not None,
            "server launcher batch does not set the UTF-8 console code page",
        )
        checks.true(
            "-Dfile.encoding=UTF-8" in start_bat,
            "server launcher batch does not specify Java UTF-8 file encoding",
        )
        checks.true(
            "%*" in start_bat,
            "server launcher batch does not forward all arguments",
        )
        checks.true(
            "exit /b %EXIT_CODE%" in start_bat,
            "server launcher batch does not return the Java exit code",
        )

    if testserver_agent_path.is_file():
        testserver_agent = read_utf8(testserver_agent_path)
        checks.true(
            "saves, player database and admin permissions" in testserver_agent,
            "testserver docs do not identify the persistent server data reused between runs",
        )
        checks.true(
            "does not automatically reset that data" in testserver_agent,
            "testserver docs do not prohibit automatic server data reset",
        )
        checks.true(
            "UTF-8" in testserver_agent,
            "testserver docs do not record the UTF-8 startup constraint",
        )
        checks.true(
            "Z:\\RailroaderRVTestCache\\client" in testserver_agent
            and "Z:\\RailroaderRVTestCache\\server" in testserver_agent,
            "testserver docs do not identify the persistent server/client caches",
        )

    checks.true(mod_info_path.is_file(), f"mod.info is missing: {mod_info_path}")
    if mod_info_path.is_file():
        mod_info = read_utf8(mod_info_path)
        checks.true(
            re.search(r"(?m)^require=\\BuildingCraft,\\Railroader\s*$", mod_info)
            is not None
            and len(re.findall(r"(?m)^require=", mod_info)) == 1,
            "RailroaderRVTest mod.info must preserve BuildingCraft and require Railroader",
        )

    if readme_path.is_file():
        readme = read_utf8(readme_path)
        checks.true(
            "BuildingCraft_Light_17" in readme
            and "自建房电灯开关1" in readme
            and "3459887404" in readme,
            "README does not identify the required BuildCraft custom-house switch dependency",
        )
        checks.true(
            "x=[20000,20100)" in readme
            and "y=[2000,2100)" in readme
            and "staging" in readme
            and "加载等待期间不做任何世界修改" in readme
            and "等待目标" in readme
            and "不要求预先加载完整" in readme
            and "缺失 square 会跳过" in readme
            and "固定模板对象的宿主 square" in readme
            and "fail closed" in readme
            and "10000 个 base 方格" not in readme,
            "README does not document sparse cleanup, template-host construction, and fail-closed preflight",
        )
        checks.true(
            "不铺整片金属地板" in readme
            and "FinalRelocate" in readme
            and "(20050.5,2050.5,0)" in readme,
            "README does not document the no-metal-floor build and final relocation",
        )
        checks.true(
            "412 个模板对象" in readme
            and "6×23" in readme
            and "驾驶室内部 x=-4..1、y=-2..1" in readme
            and "每 10 tick" in readme
            and "59 条捕获墙边" in readme
            and "四段隐形墙补齐活动区域边界缺口" in readme,
            "README does not document the captured 6x23 RV and 59-edge shell",
        )
        checks.true(
            "位于旧、新边界之外的安全格" not in readme,
            "README still documents the retired safe-square relocation plan",
        )
        checks.true(
            "lighting_indoor_01_16" not in readme
            and "Facing=E" not in readme,
            "README still documents the retired vanilla lamp or Facing=E assumption",
        )
        checks.true(
            "全部" in readme
            and "(18000,0,15)" in readme
            and "chunk" in readme
            and "逐人回传" in readme,
            "README does not document the grouped remote chunk-cycle roof refresh",
        )
        checks.true(
            "managedOriginX+floor(width/2)" in readme
            and "managedOriginY+floor(height/2)" in readme
            and "正在生成房车" in readme
            and "进程内存" in readme
            and "-15" in readme
            and "无状态" in readme
            and "不恢复原坐标" in readme,
            "README does not document generation-center staging and the stateless -15 sentinel",
        )

    active_commands = read_utf8(server_commands_path) if server_commands_path.is_file() else ""
    generation_validation = section(
        generation_flow,
        r"local function validateRequest\(module, command, player, args\)",
        r"-- Deliver the final in-house relocation",
    )
    checks.true(
        not layout_builder_path.exists()
        and not layout_builder_client_path.exists()
        and "COMMAND_LAYOUT_BUILD" not in active_commands
        and "COMMAND_LAYOUT_FINISH" not in active_commands
        and "LayoutBuilder" not in active_commands
        and "RemovalTrace" not in active_commands
        and "queueGeneration(player, reason)" in active_commands
        and generation_validation is not None
        and "command ~= COMMAND" in generation_validation,
        "LayoutBuilder is not retired while the authoritative Generate route remains active",
    )

    if server_agent_path.is_file():
        server_agent = read_utf8(server_agent_path)
        checks.true(
            "does not require all 10,000 base squares" in server_agent
            and "skipping missing squares" in server_agent
            and "fails closed if the target contains any existing object" in server_agent
            and "creates objects only at current template-object hosts" in server_agent,
            "server agent docs do not describe sparse cleanup and fail-closed template-host construction",
        )
        checks.true(
            "PerfTrace" not in server_agent
            and "PerfTrace" not in read_utf8(client_root / "agent.md"),
            "agent docs still describe removed performance diagnostics",
        )

    checks.true(runner_path.is_file(), f"one-click test runner is missing: {runner_path}")
    if runner_path.is_file():
        runner = read_utf8(runner_path)
        checks.true(
            'runtime_root = run_bat.parent / "runtime"' in runner
            and "_acquire_instance_lock(runtime_root, settings.run_bat)" in runner,
            "one-click test runner does not isolate lock/instance state under testserver/runtime",
        )
        checks.true(
            'RAMDISK_CACHE_ROOT = Path(r"Z:\\RailroaderRVTestCache")' in runner
            and 'server_cache = server_cache or (RAMDISK_CACHE_ROOT / "server")' in runner
            and 'client_cache = client_cache or (RAMDISK_CACHE_ROOT / "client")' in runner,
            "one-click test runner does not use the documented persistent Z: cache defaults",
        )
        checks.true(
            "_copy_mod_tree" in runner,
            "one-click test runner does not use overlay mod synchronization",
        )
        checks.true(
            'BUILDCRAFT_MOD_ID = "BuildingCraft"' in runner
            and 'BUILDCRAFT_WORKSHOP_ID = "3459887404"' in runner,
            "one-click test runner does not pin the BuildCraft mod/workshop identifiers",
        )
        checks.true(
            "find_steam_libraries" in runner
            and "workshop" in runner
            and "--buildcraft-source" in runner,
            "one-click test runner lacks Steam discovery or --buildcraft-source override",
        )
        checks.true(
            '"common" / "mod.info"' in runner
            and '"42.0" / "mod.info"' in runner,
            "one-click test runner does not validate BuildCraft common/42.0 metadata",
        )
        checks.true(
            re.search(
                r"stage_mod\(\s*buildcraft_source,\s*settings\.server_cache[\s\S]*?BUILDCRAFT_MOD_ID",
                runner,
            )
            is not None
            and re.search(
                r"stage_mod\(\s*buildcraft_source,\s*settings\.client_cache[\s\S]*?BUILDCRAFT_MOD_ID",
                runner,
            )
            is not None,
            "BuildCraft is not overlaid to both server/client mods/BuildingCraft caches",
        )
        checks.true(
            '"Mods": f"{BUILDCRAFT_MOD_ID};{MOD_ID}"' in runner
            and '"WorkshopItems": ""' in runner,
            "server options do not enforce BuildCraft-first Mods and offline WorkshopItems",
        )
        checks.true(
            re.search(r"(?im)\b(?:rmtree|Remove-Item|shutil\.rmtree)\b", runner)
            is None,
            "one-click test runner contains an automatic runtime data delete/reset operation",
        )

    run_lua_syntax_checks(root, checks)

    if checks.failures:
        for failure in checks.failures:
            print(f"[FAIL] {failure}", file=sys.stderr)
        return 1

    print(
        "RV static tests passed: payload contract, UTF-8 launcher contract, "
        "relocation handshake, stale-room guard, entity/fluid component contract, rollback contract, "
        "Railroader SP/MP adapter, hull-distance/seat transition contracts, transaction/sentinel documentation, "
        "Lua syntax."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
