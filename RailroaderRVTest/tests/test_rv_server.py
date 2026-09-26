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
    server_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_Server.lua"
    server_util_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_ServerUtil.lua"
    server_world_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_ServerWorld.lua"
    server_schema_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_ServerSchema.lua"
    client_path = package_root / "media" / "lua" / "client" / "RailroaderRV" / "RV_ContextMenu.lua"
    railroader_server_path = (
        package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_RailroaderServer.lua"
    )
    railroader_client_path = (
        package_root / "media" / "lua" / "client" / "RailroaderRV" / "RV_RailroaderContextMenu.lua"
    )
    constants_path = package_root / "media" / "lua" / "shared" / "RailroaderRV" / "RV_Constants.lua"
    constants = read_utf8(constants_path) if constants_path.is_file() else ""
    layout_path = package_root / "media" / "lua" / "shared" / "RailroaderRV" / "RV_Layout.lua"
    template_path = package_root / "media" / "lua" / "shared" / "RailroaderRV" / "RV_Template.lua"
    protection_manifest_path = package_root / "media" / "lua" / "shared" / "RailroaderRV" / "RV_ProtectionManifest.lua"
    bitmap_path = package_root / "media" / "lua" / "shared" / "RailroaderRV" / "RV_Bitmap.lua"
    mapping_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_RailroaderServer_Mapping.lua"
    manifest_validation_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_Server_ManifestValidation.lua"
    boundary_geometry_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_BoundaryServer_Geometry.lua"
    boundary_server_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_BoundaryServer.lua"
    boundary_client_path = package_root / "media" / "lua" / "client" / "RailroaderRV" / "RV_BoundaryClient.lua"
    boundary_wall_visuals_path = package_root / "media" / "lua" / "client" / "RailroaderRV" / "RV_BoundaryWallVisuals.lua"
    protected_demolition_path = package_root / "media" / "lua" / "client" / "RailroaderRV" / "RV_ProtectedDemolition.lua"
    wardrobe_visuals_path = package_root / "media" / "lua" / "client" / "RailroaderRV" / "RV_WardrobeVisuals.lua"
    utility_catalog_path = package_root / "media" / "lua" / "shared" / "RailroaderRV" / "RV_UtilityCatalog.lua"
    utility_context_path = package_root / "media" / "lua" / "client" / "RailroaderRV" / "RV_UtilityContextMenu.lua"
    utility_client_path = package_root / "media" / "lua" / "client" / "RailroaderRV" / "RV_UtilityClient.lua"
    utility_server_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_UtilityServer.lua"
    utility_water_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_UtilityWater.lua"
    utility_objects_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_UtilityWater_Objects.lua"
    utility_plumbing_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_UtilityWater_Plumbing.lua"
    utility_store_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_UtilityStore.lua"
    generation_build_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_Server_GenerationBuild.lua"
    generation_flow_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_Server_GenerationFlow.lua"
    generation_ack_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_Server_GenerationAck.lua"
    player_validation_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_Server_PlayerValidation.lua"
    roof_destinations_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_Server_RoofDestinations.lua"
    server_commands_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_Server_Commands.lua"
    room_ownership_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_Server_RoomOwnership.lua"
    record_validation_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_Server_RecordValidation.lua"
    client_room_ownership_path = package_root / "media" / "lua" / "client" / "RailroaderRV" / "RV_ContextMenu_RoomOwnership.lua"
    client_relocation_path = package_root / "media" / "lua" / "client" / "RailroaderRV" / "RV_ContextMenu_Relocation.lua"
    world_objects_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_Server_WorldObjects.lua"
    template_repair_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_Server_TemplateRepair.lua"
    entry_exit_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_RailroaderServer_EntryExit.lua"
    boundary_objects_path = package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_BoundaryServer_Objects.lua"
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
        player_validation_path,
        roof_destinations_path,
        server_commands_path,
        room_ownership_path,
        record_validation_path,
        client_room_ownership_path,
        client_relocation_path,
        world_objects_path,
        template_repair_path,
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
    ):
        checks.true(utility_path.is_file(), f"utility Lua is missing: {utility_path}")
    checks.true(start_bat_path.is_file(), f"server launcher batch is missing: {start_bat_path}")

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
        template_repair = (
            read_utf8(template_repair_path) if template_repair_path.is_file() else ""
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
        railroader_client = (
            read_utf8(railroader_client_path)
            if railroader_client_path.is_file()
            else ""
        )
        bitmap = read_utf8(bitmap_path) if bitmap_path.is_file() else ""
        mapping = read_utf8(mapping_path) if mapping_path.is_file() else ""
        manifest_validation = (
            read_utf8(manifest_validation_path)
            if manifest_validation_path.is_file()
            else ""
        )
        boundary_geometry = (
            read_utf8(boundary_geometry_path)
            if boundary_geometry_path.is_file()
            else ""
        )
        captured_template = read_utf8(template_path) if template_path.is_file() else ""
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
            r'direction="(?P<direction>[^"]+)",'
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
        east_cab_classes_match = len(protection_objects) == 412 and all(
            protection_class_by_index.get(index) == 1
            for index, obj in enumerate(captured_template_objects, 1)
            if int(obj["z"]) == 0
            and int(obj["x"]) == 2
            and -2 <= int(obj["y"]) <= 1
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
        utility_objects = (
            read_utf8(utility_objects_path) if utility_objects_path.is_file() else ""
        )
        utility_plumbing = (
            read_utf8(utility_plumbing_path) if utility_plumbing_path.is_file() else ""
        )
        utility_store = (
            read_utf8(utility_store_path) if utility_store_path.is_file() else ""
        )

        checks.true(
            'require("RailroaderRV/RV_ServerUtil")' in server_facade
            and 'require("RailroaderRV/RV_ServerWorld")' in server_facade
            and 'require("RailroaderRV/RV_ServerSchema")' in server_facade,
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

        sink_test_gate = re.search(
            r"sink\s*=\s*\{(?:(?!\n\s*\},).)*?runtimeTestEnabled\s*=\s*true,",
            utility_catalog,
            re.S,
        )
        other_test_gates = all(
            re.search(
                rf"{name}\s*=\s*\{{(?:(?!\n\s*\}},).)*?runtimeTestEnabled\s*=\s*false,",
                utility_catalog,
                re.S,
            )
            for name in ("toilet", "bathtub", "shower", "washingMachine")
        )
        checks.true(
            sink_test_gate is not None
            and other_test_gates
            and "runtimeValidated" not in utility_catalog
            and "function M.entryIsRuntimeTestEnabled" in utility_catalog
            and "function M.entryIsValidated" not in utility_catalog
            and "function M.isGeneratedSink" in utility_catalog,
            "utility catalog retains a dead validation export or loses the sink test allowlist",
        )
        checks.true(
            "function M.isNativeSink" in utility_catalog
            and "getFluidContainer" in utility_catalog,
            "utility catalog does not expose the current native-sink FluidContainer gate",
        )
        utility_candidate = section(
            utility_context,
            r"local function candidate",
            r"local function generatorCandidate",
        )
        checks.true(
            utility_candidate is not None
            and "entryIsRuntimeTestEnabled" in utility_candidate
            and "isGeneratedSink" in utility_candidate
            and "isNativeSink" in utility_candidate
            and "mapping == nil" in utility_candidate
            and "entryIsValidated" not in utility_candidate,
            "client utility menu does not separate native sinks from generated identity tags",
        )
        checks.true(
            "local function staleGeneratedSink" in utility_context
            and "ContextMenu_RailroaderRVTest_UtilitySaveRebuild" in utility_context
            and "Client.showSaveRebuildRequired" in utility_context
            and "function Client.showSaveRebuildRequired" in utility_client
            and "AddComponent" not in utility_context,
            "legacy generated sinks are silently hidden or client-side component repair is present",
        )
        utility_connect = section(
            utility_water,
            r"function M\.connectDevice",
            r"function M\.addWater",
        )
        checks.true(
            utility_connect is not None
            and "isGeneratedSink(object, identity)" in utility_connect
            and "Catalog.isNativeSink(object)" in utility_connect
            and 'entry.id ~= "sink"' in utility_connect
            and "local taggedSink = Catalog.isGeneratedSink(object)" in utility_connect
            and "U.REASON_INVALID_RV_DATA" in utility_connect
            and "entryIsRuntimeTestEnabled" in utility_connect
            and "entryIsValidated" not in utility_connect,
            "server utility connect path does not distinguish native sinks from stale generated objects",
        )
        checks.true(
            "local function objectCoordinates" in utility_water
            and "x = x, y = y, z = z" in utility_water
            and "x = hint.x, y = hint.y, z = hint.z" not in utility_water,
            "server utility registry persists client coordinate hints instead of the resolved object",
        )
        registry_gate = section(
            utility_store,
            r"local function validRegistryEntry",
            r"local function validWater",
        )
        checks.true(
            registry_gate is not None
            and "entryIsRuntimeTestEnabled" in registry_gate
            and "entryIsValidated" not in registry_gate,
            "utility current-schema registry gate still requires the unachievable validation bit",
        )

        detach_device = section(
            utility_water,
            r"local function detachDevice",
            r"-- B42 raises this event before an IsoObject is detached",
        )
        checks.true(
            detach_device is not None
            and "if emergency then" not in detach_device
            and "emergency" not in detach_device
            and "function M.detachDevice" not in utility_water
            and 'flushBeforeOverwrite(identity, "DETACH", context, execute)' in detach_device
            and "restoreFixtureTag(fixture, nil)" in detach_device
            and "record.water.registry[deviceId] = nil" in detach_device
            and "record.water.proxyLedger[deviceId] = nil" in detach_device
            and re.search(
                r"\bdetachDevice\(identity,\s*context,\s*tag\.deviceId\)",
                utility_water,
            ) is not None,
            "water fixture removal does not retain its ordinary detach transaction without the dead emergency path",
        )

        checks.true(
            all(token in bitmap for token in (
                "BITMAP_SCHEMA_VERSION", "newBitset", "toHex", "fromHex",
                "containsScope", "isActive", "isBuildable", "walkBounds",
                "inAABB", "edgeForSide", "bitmapVersion ~= C.BITMAP_VERSION",
            ))
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
            and "not exactKeys(boundary," in boundary_server
            and "not exactKeys(managed," in boundary_server
            and "not exactKeys(edge, fields)" in boundary_server,
            "bitmap and boundary schema validators do not share exact current-field rejection",
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
            and 'require("RailroaderRV/RV_Constants")' not in read_utf8(utility_context_path)
            and 'local C = require("RailroaderRV/RV_Constants")' not in read_utf8(
                package_root / "media" / "lua" / "server" / "RailroaderRV" / "RV_UtilityPower.lua"
            ),
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
            and '"^([NW]):(-?%d+):(-?%d+):(-?%d+)$"' in boundary_server
            and '"^(N|W):' not in server
            and '"^(N|W):' not in boundary_server,
            "shell edge validators use unsupported Lua pattern alternation",
        )
        update_guard = section(
            boundary_geometry,
            r"local function updatePlayer",
            r"\n\nctx\.number",
        )
        checks.true(
            update_guard is not None
            and all(token in update_guard for token in (
                "Bitmap.walkBounds", "if bounds and Bitmap.inAABB(bounds.outer, position.x, position.y)",
                "currentSquareMatches(player, position)",
                "correction(player, boundary, state, record.rvPosition)",
            ))
            and "not Bitmap.containsScope(boundary.bitmap" in update_guard
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
            "server boundary guard does not use only current AABB and trusted entry correction",
        )
        checks.true(
            "current square has not been loaded" in boundary_geometry
            and "if not ok or current == nil then return false end" in boundary_geometry,
            "server boundary state advances across unloaded squares",
        )
        checks.true(
            "authoritative object is intentionally in a different chunk" in boundary_server
            and "processing resumes after completeTransition" in boundary_server
            and "local state = stateFor(player)" in boundary_server
            and "if not state or not transitionActive(state) then" in boundary_server,
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
        generation_cleanup_world_gate = section(
            server_world,
            r"local function isTaggedForGeneration",
            r"local function isPlayerObject",
        )
        checks.true(
            generation_cleanup is not None
            and "requireCurrentManifest(manifest, true)" in generation_cleanup
            and "ServerSchema.walkBounds(cell, oldBounds" in generation_cleanup
            and "ServerWorld.clearSquare(square, generation, rvId, bitmapVersion)"
                in generation_cleanup
            and generation_cleanup_world_gate is not None
            and "tag.owner ~= OWNER" in generation_cleanup_world_gate
            and "tag.generation" in generation_cleanup_world_gate
            and "tag.rvId" in generation_cleanup_world_gate
            and "tag.bitmapVersion" in generation_cleanup_world_gate,
            "generation cleanup lacks the current manifest and full object identity gates",
        )
        repair_context = section(
            template_repair,
            r"local function validCurrentContext",
            r"local function isCabCoordinate",
        )
        checks.true(
            repair_context is not None
            and "pcall(requireCurrentManifest, manifest, false)" in repair_context
            and 'manifest.state ~= "READY"' in repair_context
            and 'manifest.phase ~= "COMMITTED"' in repair_context
            and "sameIdentity(manifest, boundary)" in repair_context
            and "manifest.bounds.schemaVersion ~= Constants.LAYOUT_SCHEMA_VERSION"
                in repair_context,
            "template repair does not require the current committed manifest before using bounds",
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
            "currentBoundsValid" in server
            and "manifest.boundary.managed" in server
            and "Bitmap.containsScope(bitmap, entry.x, entry.y, entry.z)" in server,
            "persisted RV bounds are not checked against the current bitmap scope",
        )
        checks.true(
            "local function roomOwnershipGuardKey" in room_ownership
            and "guard.key = roomOwnershipGuardKey" in room_ownership
            and "roomOwnershipGuards[guard.key] = guard" in room_ownership,
            "server room-ownership guard is not keyed by the full RV boundary identity",
        )
        checks.true(
            all(token in boundary_client for token in (
                "OnTick", "OnServerCommand", "COMMAND_RV_BITMAP_CLEAR",
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
            server,
            r"local function queueGeneration",
            r"local function ackPayloadToken",
        )
        relocate_handler = section(
            client,
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
            and "roofRepairRoomKey" in railroader_server
            and "tostring(record.bitmapVersion)" in railroader_server
            and '"outside-rv"' in railroader_server
            and "trainPose(train)" in railroader_server
            and "usableCoordinate" in railroader_server
            and 'isValidSquare' in railroader_server,
            "exit reverse lookup does not use the current 100x100 mapping contract",
        )
        existing_entry = section(
            railroader_server,
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
            railroader_server,
            r"local function repairInsidePlayers",
            r"function Adapter\.OnTick",
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
            r"local function queueWallRoofRepairForObject",
            r"insidePlayersForRecord = function",
        )
        checks.true(
            wall_removal is not None,
            "Railroader server has no object-removal roof-repair hook",
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
                        "wall roof repair queued",
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
                and "roofRepairGroupFailure.token == token" in server
                and "pending.relocationToken or pending.returnToken" in railroader_server
                and "another RV relocation or generation is in progress" in railroader_server,
                "failed roof cycles are not token-scoped for in-memory return and queued independent operations",
            )
        scheduled_roof = section(
            railroader_server,
            r"scheduleRoofRepair = function",
            r"local function queueWallRoofRepairForObject",
        )
        checks.true(
            scheduled_roof is not None,
            "delayed roof repair scheduler is missing",
        )
        if scheduled_roof is not None:
            checks.true(
                all(
                    token in scheduled_roof
                    for token in (
                        "validRecord(record)",
                        "insidePlayersForRecord(map, record)",
                        "pendingWallRoofRepairs[roomKey]",
                        "ROOF_REPAIR_QUEUED_DEADLINE_TICKS",
                        "queuedDeadlineTick",
                        "dueTicks",
                        "nextAttempt",
                        "ROOF_REPAIR_DELAY_TICKS",
                        "ROOF_REPAIR_ATTEMPTS",
                    )
                ),
                "roof repair scheduler does not enforce current identity/inside player or bounded retries",
            )
            checks.true(
                "ROOF_REPAIR_DELAY_TICKS = 5" in railroader_server
                and "ROOF_REPAIR_ATTEMPTS = 3" in railroader_server
                and "ROOF_REPAIR_QUEUED_DEADLINE_TICKS = 600" in railroader_server
                and "queued roof repair member rebind deadline expired"
                in railroader_server
                and "pending.dueTicks[attempt] = now"
                in railroader_server,
                "wall-removal repair schedule does not define the bounded 5/10/15-tick contract",
            )
        checks.true(
            "function Adapter.onObjectAboutToBeRemoved" in railroader_server
            and "queueWallRoofRepairForObject(object, \"object-about-to-be-removed\")"
            in railroader_server
            and "function Adapter.onDestroyIsoThumpable" in railroader_server
            and "queueWallRoofRepairForObject(object, \"destroy-iso-thumpable\")"
            in railroader_server,
            "wall-removal events do not share the strict de-duplicated matcher",
        )
        tick_repair = section(
            railroader_server,
            r"function Adapter\.OnTick",
            r"-- PZ loads files in this directory alphabetically",
        )
        checks.true(
            tick_repair is not None
            and "processPendingWallRoofRepairs()" in tick_repair
            and "if Adapter._ticks % 30 ~= 0 then return end" in tick_repair
            and "repairInsidePlayers(map)" in tick_repair,
            "delayed roof repair is not deferred into the server 30-tick presence path",
        )
        runtime_clear = section(
            railroader_server,
            r"local function clearRoofRepairRuntimeState",
            r"local function processPendingWallRoofRepairs",
        )
        checks.true(
            runtime_clear is not None
            and "roomTransitionStates = {}" in runtime_clear
            and "pendingWallRoofRepairs[roomKey] = nil" in runtime_clear
            and "clearRoofRepairRuntimeState(true)" in tick_repair
            and "followUpWallRemovalEvents = {}" in runtime_clear,
            "schema failure rejects queued roof state while transient reads retain it",
        )
        room_transition = section(
            railroader_server,
            r"local function authoritativeRoomState",
            r"local function repairInsidePlayers",
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
            railroader_server,
            r"observeRoomTransitions = function",
            r"local function processPendingWallRoofRepairs",
        )
        checks.true(
            transition_monitor is not None
            and "previous.inRoom == true" in transition_monitor
            and 'scheduleRoofRepair(map, observed.record, "room-transition")'
            in transition_monitor
            and "consumeSuppressedRoomTransition(roomKey)" in transition_monitor
            and "suppressed=" in transition_monitor
            and "observed.roomStateAvailable" in transition_monitor
            and "roomTransitionStates[roomKey] = nil" in transition_monitor
                and "reason=presence-lost" in transition_monitor,
                "room transition monitor does not schedule once per current identity or clear stale presence",
            )
        checks.true(
            "markSuppressedRoomTransition" in railroader_server
            and "consumeSuppressedRoomTransition(roomKey)" in transition_monitor
            and "reason=wall-removal-relocation" in railroader_server,
            "self-generated room transition is not consumed after the unique wall cycle",
        )
        delayed_attempts = section(
            railroader_server,
            r"local function processPendingWallRoofRepairs",
            r"function Adapter\.OnTick",
        )
        checks.true(
            delayed_attempts is not None
            and "processPendingWallRoofRepairGroup(map, pending," in delayed_attempts
            and "identity-mismatch" in delayed_attempts
            and "no grouped authoritative players" in delayed_attempts,
            "delayed roof attempts do not remain on the grouped authoritative path",
        )
        checks.true(
            delayed_attempts is not None
            and "isGenerationTransactionActive" in delayed_attempts
            and "expireQueuedWallRoofRepairs(now)" in delayed_attempts
            and "waitingForGeneration" in delayed_attempts
            and "local queuedDeadline = integer(pending.queuedDeadlineTick)" in delayed_attempts
            and "now >= queuedDeadline" in delayed_attempts
            and "pending.waitingForGeneration ~= true" in delayed_attempts
            and "malformed queued roof repair deadline" in delayed_attempts
            and "revalidateQueuedRoofRepairAfterGeneration" in railroader_server
            and "revalidateUntilTick" in railroader_server
            and "pending.revalidateUntilTick = now" in delayed_attempts
            and "pending.queuedDeadlineTick = now" in railroader_server
            and "roof repair queue revalidated after generation room=" in railroader_server
            and "currentRoomKey ~= roomKey" in railroader_server
            and "followUpWallRemovalEvents[currentRoomKey]" in railroader_server
            and "event.roomKey = currentRoomKey" in railroader_server,
            "queued wall follow-ups are not held through generation and revalidated against the new current record",
        )
        follow_up_wait = section(
            railroader_server,
            r"local function promoteFollowUpWallRemoval",
            r"local function revalidateQueuedRoofRepairAfterGeneration",
        )
        checks.true(
            follow_up_wait is not None
            and "event.waitingForGeneration ~= true" in follow_up_wait
            and "event.expiresAtTick = now" in follow_up_wait
            and "ROOF_REPAIR_QUEUED_DEADLINE_TICKS" in follow_up_wait
            and "wall removal follow-up cancelled room=" in follow_up_wait,
            "generation-held wall follow-ups do not pause, revalidate, and renew their bounded lease",
        )
        follow_up_prune = section(
            railroader_server,
            r"local function pruneRoofRepairDedupeState",
            r"local function wallRemovalEventKey",
        )
        checks.true(
            follow_up_prune is not None
            and "generationBusy" in follow_up_prune
            and "event.waitingForGeneration == true" in follow_up_prune
            and "elseif now > expiresAt" in follow_up_prune
            and "event.waitingForGeneration = true" in follow_up_prune,
            "follow-up pruning does not preserve accepted events across generation ownership",
        )
        queued_disconnect = section(
            railroader_server,
            r"local function processPendingWallRoofRepairGroup",
            r"if pending.relocationPhase == \"temporary\"",
        )
        checks.true(
            queued_disconnect is not None
            and "queuedDeadlineTick" in queued_disconnect
            and "relocationStarted ~= true" in queued_disconnect
            and "pending.relocationToken == nil" in queued_disconnect
            and "pending.returnToken == nil" in queued_disconnect
            and "cancelPendingWallRoofRepair(pending.roomKey, pending," in queued_disconnect
            and "queued roof repair member rebind deadline expired" in queued_disconnect
            and "for i = 1, #pending.players do" in queued_disconnect
            and "resolveSavedPlayer(pending.players[i])" in queued_disconnect,
            "queued roof refresh has no bounded offline rebind cancellation before relocation",
        )
        roof_relocation = section(
            server,
            r"local function currentRoofRepairContext",
            r"local function validateRequest",
        )
        checks.true(
            roof_relocation is not None
            and "currentRVRecordGeometryConsistent" in roof_relocation
            and "originX + math.floor(width / 2)" in roof_relocation
            and "originY + math.floor(height / 2)" in roof_relocation
            and "ROOF_REPAIR_REMOTE_OFFSET_X" in roof_relocation
            and "ROOF_REPAIR_REMOTE_OFFSET_Y" in roof_relocation
            and "ROOF_REPAIR_REMOTE_OFFSET_Z" in roof_relocation
            and "centerZ - ROOF_REPAIR_REMOTE_OFFSET_Z" in roof_relocation
            and "targetKind=rv-center-minus-offset" in server
            and "roofRepairTemporarySquareSafe" in roof_relocation
            and "roof repair temporary destination is still room geometry"
            in roof_relocation,
            "roof relocation does not derive a current-schema remote center-minus-offset target",
        )
        roof_relocation_service = section(
            server,
            r"function RV.Server.beginRoofRepairRelocationGroup",
            r"function RV.Server.consumeRoofRepairRelocationArrival",
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
            server,
            r"local function processRoofRepairRelocationGroup",
            r"function RV.Server.OnTick",
        )
        checks.true(
            roof_server_tick is not None
            and "roofRepairTargetReady" in roof_server_tick
            and "RelocateAck" not in roof_server_tick
            and "roofRepairRelocationGroup" in roof_server_tick,
            "roof relocation server tick does not wait for authoritative arrival/readiness",
        )
        checks.true(
            roof_server_tick is not None
            and "applyRoofRepairTeleport" in roof_server_tick
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
            and "completeRoofRepairRelocation" in server
            and "roofRepairSquaresLoaded" in server,
            "remote roof relocation cannot acknowledge a valid unloaded target across ticks",
        )
        checks.true(
            all(token in client for token in (
                "roofRepairTransition", "roofRepairPhase",
                "generationTransition", "generationPhase",
                "GENERATION_HALO_TEXT", "ROOF_REPAIR_HALO_TEXT",
                "setHaloNote", "RelocateAck",
            )),
            "client roof relocation handler lacks display-only halo and token ACK contract",
        )
        checks.true(
            "if not roofRepairTransition and roofRepairPhase ~= nil then" in client
            and "if not generationTransition and generationPhase ~= nil then" in client
            and "or roofRepairTransition) then" in client,
            "client does not fail closed on mixed relocation phase markers",
        )
        relocation_services = section(
            server,
            r"local relocationServices = \(function\(\)",
            r"local function currentBoundsValid",
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
            server,
            r"local function generationDisconnected",
            r"local function currentBoundsValid",
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
            server,
            r"local function resendRoofRepairMemberPhase",
            r"function RV.Server.consumeRoofRepairRelocationArrival",
        )
        checks.true(
            roof_rebind is not None
            and "disconnectStartedTick" in roof_rebind
            and "ROOF_RELOCATION_RETRY_TICKS" in roof_rebind
            and "member.relocationNeedsResend" in roof_rebind
            and "member.arrived == true or member.completed == true" in roof_rebind,
            "roof relocation does not pause/rebind/retry one token across a live reconnect",
        )
        geometry_gate = section(
            server,
            r"function RV.Server.currentRVRecordGeometryConsistent",
            r"-- Re-run the official add-floor/remove-floor",
        )
        checks.true(
            geometry_gate is not None
            and "currentManifestValid" in geometry_gate
            and "record.region" in geometry_gate
            and "record.rvPosition" in geometry_gate
            and "bounds.shellEdges" in geometry_gate
            and "record.boundary.shellEdges" in geometry_gate
            and "Boundary.registerGeneration" in geometry_gate,
            "current RV geometry gate does not compare record/manifest bitmap, walls, shell and region identity",
        )
        bounds_bitmap_gate = section(
            server,
            r"local function currentBoundsValid",
            r"local function currentManifestValid",
        )
        checks.true(
            bounds_bitmap_gate is not None
            and all(
                token in bounds_bitmap_gate
                for token in (
                    "type(bounds.bitmap) ~= \"table\"",
                    "Bitmap.validate",
                    "bounds.bitmap[field] ~= bitmap[field]",
                    "boundsLayer.walkBits ~= boundaryLayer.walkBits",
                    "boundsLayer.buildBits ~= boundaryLayer.buildBits",
                )
            )
            and "manifest.bounds.bitmap" in server,
            "current bounds gate does not validate/compare manifest.bounds.bitmap layer bits",
        )
        mutex_gate = section(
            server,
            r"function RV.Server.beginRoofRepairRelocationGroup",
            r"function RV.Server.isRelocationIdentityClaimed",
        )
        checks.true(
            mutex_gate is not None
            and "transactionBusy" in mutex_gate
            and "pendingGeneration ~= nil" in mutex_gate
            and "roofRepairRelocationGroup ~= nil" in mutex_gate
            and "roofRepairGroupFinalReturn ~= nil" in mutex_gate,
            "roof/generation relocation service does not enforce the server-side bidirectional mutex",
        )
        checks.true(
            "function RV.Server.isGenerationTransactionActive" in server
            and "function RV.Server.isRoofRepairTransactionActive" in server
            and "function RV.Server.validateCurrentRVRecord" in server
            and "function RV.Server.isRoofRepairTransactionActive(_rvId)" in server
            and "active roof transaction must never be bypassed" in server
            and "roof repair refresh is in progress" in server
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
            and "isRoofRepairTransactionActive" in adapter_mutex
            and "isRoofRepairTransactionActive, nil" in adapter_mutex
            and "pendingWallRoofRepairs" in adapter_mutex
            and "INVALID_RV_DATA" in adapter_mutex
            and all(
                token in railroader_server
                for token in (
                    "local roofBlocked, roofReason = roofRepairTransactionBlocks(record.rvId)",
                    "local roofBlocked, roofReason = roofRepairTransactionBlocks(locoId)",
                )
            ),
                "all-player Enter/Exit paths do not honor the current RV roof transaction mutex",
        )
        roof_owner = section(
            railroader_server,
            r"roofRepairOwnsPlayer = function",
            r"serverTransactionMutexStatus = function",
        )
        checks.true(
            roof_owner is not None
            and "queuedRoofRepairClaims(identityKey)" in roof_owner
            and "isRoofRepairTransactionActive" in roof_owner
            and "roofActive ~= true" in roof_owner,
            "adapter roof-owner gate confuses a generation claim with roof repair",
        )
        checks.true(
            "local function currentGeometryGate" in railroader_server
            or "currentGeometryGate = function" in railroader_server,
            "adapter does not expose a narrow current geometry gate for Enter/Exit",
        )
        existing_entry = section(
            railroader_server,
            r"local function enterExisting",
            r"local function enterPlayer",
        )
        checks.true(
            existing_entry is not None
            and "currentGeometryGate(record)" in existing_entry
            and existing_entry.find("currentGeometryGate(record)")
            < existing_entry.find("local armed = Boundary.beginTransition")
            and existing_entry.find("currentGeometryGate(record)")
            < existing_entry.find("armRoomOwnershipMonitor"),
            "existing RV entry does not gate current geometry before mutation",
        )
        exit_entry = section(
            railroader_server,
            r"local function exitPlayer",
            r"local function commandArgument",
        )
        checks.true(
            exit_entry is not None
            and "currentGeometryGate(record)" in exit_entry
            and exit_entry.find("currentGeometryGate(record)")
            < exit_entry.find("local armed = Boundary.beginTransition")
            and exit_entry.find("currentGeometryGate(record)")
            < exit_entry.find("markPlayerOutside"),
            "RV exit does not gate current geometry before mutation",
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
            "boundary guard does not fail closed through the full current map/record validator",
        )
        checks.true(
            "sameBoundaryGeometry" in boundary_server
            and "state.boundaryReference ~= boundary" in boundary_server
            and "currentRVManifestForBoundary" in railroader_server
            and "currentRVRecordGeometryConsistent" in railroader_server,
            "boundary cache/state can reuse an inconsistent geometry snapshot",
        )
        checks.true(
            "function RV.Server.isRelocationIdentityClaimed" in server
            and "function RV.Server.currentRVManifestForRelocation" in server
            and "function processStatelessRelocationSentinel" in railroader_server
            and "RELOCATION_SENTINEL_Z" in railroader_server
            and "math.floor(position.z) ~= RELOCATION_SENTINEL_Z" in railroader_server
            and "sentinelPosition" in railroader_server
            and "player left the temporary cell" in railroader_server
            and "sentinelRecordManifestConsistent" in railroader_server
            and "queuedRoofRepairClaims" in railroader_server
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
            and "isRoofRepairTransactionActive" in sentinel_mutex
            and "if generationActive or roofActive then return end" in sentinel_mutex,
            "stateless sentinel can race an active generation or roof transaction",
        )
        checks.true(
            "recoverRelocationLedger" not in server
            and "recoveryOnly" not in server
            and "RECOVERY_REQUIRED" not in server
            and "setGenerationRecoveryValidator" not in server
            and "setRoofRepairRecoveryValidator" not in server
            and "setRoofRepairRecoveryRepairer" not in server,
            "server still contains the retired restart-recovery state machine",
        )
        checks.true(
            "returnRepairDeadline" not in railroader_server
            and "ROOF_REPAIR_RETURN_TIMEOUT_TICKS" not in railroader_server
            and "repairRetryAtTick" in railroader_server
            and "continuously required post-return step" in railroader_server,
            "roof repair still exposes a fake return deadline instead of a retry cadence",
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
            r"local function rollbackRoofRepairRelocation",
            r"local function roofRepairGroupMatches",
        )
        checks.true(
            roof_return is not None
            and "currentPosition.z == ROOF_REPAIR_TEMP_Z" in roof_return
            and "roof repair player remains at temporary z=-15" in roof_return
            and "currentPosition.z ~= ROOF_REPAIR_TEMP_Z" in roof_return
            and "token = pending.token" in roof_return,
            "roof return does not reject an authoritative player still at z=-15",
        )
        checks.true(
            "keepRoofRepairFinalReturnAlive" in server
            and "reason=authoritative-return-required" in server
            and "Boundary.beginTransition" in server
            and "roof repair final return exhausted" not in server
            and "roof repair group final return exhausted" not in server,
            "roof return failure can exhaust and discard its context instead of continuing in-memory return",
        )
        checks.true(
            "server.completeRoofRepairRelocation" in railroader_server
            and "roofRepairSquaresLoaded" in railroader_server
            and "pending.dueTicks[attempt] = now" in railroader_server
            and "attempt * ROOF_REPAIR_DELAY_TICKS" in railroader_server
            and "originalPosition = copyPosition(position)" in railroader_server
            and "beginRoofRepairRelocationGroup" in railroader_server
            and "remote-reload-return" in railroader_server
            and "pending.relocationStarted" in railroader_server,
            "Railroader adapter does not implement grouped remote reload, repair and captured-position return",
        )
        group_flow = section(
            railroader_server,
            r"local function processPendingWallRoofRepairGroup",
            r"beginRoofRepairPhase = function",
        )
        checks.true(
            group_flow is not None
            and "server.completeRoofRepairRelocation" in group_flow
            and "pcall(\n                    repairRoofForPlayer" in group_flow
            and "repairWorldApplied" in group_flow
            and "repairCompleted" in group_flow
            and "if not allCompleted then return end" in group_flow
            and "completeRoofRepairRepair" in group_flow
            and group_flow.find("server.completeRoofRepairRelocation")
                < group_flow.find("server.roofRepairSquaresLoaded"),
            "group return does not complete per-player return before isolating repair callbacks",
        )
        checks.true(
            "local rollbackCallOk, returned, returnReason = pcall(" in server
            and "wallRemovalEventKey" in railroader_server,
            "roof final-return failures are not isolated and wall dedupe retains userdata",
        )
        checks.true(
            "Events.OnObjectAboutToBeRemoved.Add(Adapter.onObjectAboutToBeRemoved)"
            in railroader_server,
            "server shell-wall removal hook is not registered on the authoritative event",
        )
        checks.true(
            "Events.OnDestroyIsoThumpable.Add(Adapter.onDestroyIsoThumpable)"
            in railroader_server,
            "server thumpable-destroy event supplement is not registered",
        )
        exit_player = section(
            railroader_server,
            r"local function exitPlayer",
            r"local function commandArgument",
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
            and "putPassenger" not in exit_player[exit_player.find("if not train then"):]
            .split("local onlineId", 1)[0],
            "inactive mapping does not use a persisted beside target without inventing a seat",
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
                    "MANIFEST_SCHEMA_VERSION", "MAP_SCHEMA_VERSION",
                    "RV_RECORD_SCHEMA_VERSION", "RV_RELATION_SCHEMA_VERSION",
                    "BOUNDARY_SCHEMA_VERSION", "LAYOUT_SCHEMA_VERSION",
                    "BITMAP_SCHEMA_VERSION", "BITMAP_VERSION",
                    "RELOCATION_SENTINEL_Z",
                    "RELOCATION_SENTINEL_INTERVAL_TICKS",
                    "RELOCATION_SENTINEL_RETRY_COOLDOWN_TICKS",
                    "ROOF_REPAIR_REMOTE_OFFSET_X",
                    "ROOF_REPAIR_REMOTE_OFFSET_Y",
                    "ROOF_REPAIR_REMOTE_OFFSET_Z",
                    "INVALID_RV_DATA",
                ))
                and 'C.INVALID_RV_DATA = "RailroaderRVTest: RV data is invalid"' in constants,
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
                "if not manifestKeys[key] then return false end" in manifest_validation
                and 'not mapOnlyKeys(map, { "schemaVersion", "locomotives", "players" })' in mapping
                and "integer(map.schemaVersion) ~= C.MAP_SCHEMA_VERSION" in mapping
                and 'not exactKeys(encoded, { "schemaVersion", "bitmapVersion"' in bitmap
                and 'not exactKeys(boundary, { "schemaVersion", "rvId"' in boundary_geometry,
                "current manifest, mapping, bitmap, and boundary validators do not enforce current exact fields",
            )
            checks.true(
                "requireCurrentManifest(manifest, true)" in server
                and "error(C.INVALID_RV_DATA)" in mapping
                and "error(Constants.INVALID_RV_DATA)" in manifest_validation
                and "Bitmap.decode(encoded)" in boundary_server
                and "schemaVersion ~= Bitmap.SCHEMA_VERSION" in bitmap
                and "integer(boundary.schemaVersion) ~= C.BOUNDARY_SCHEMA_VERSION" in boundary_geometry,
                "current schema mismatch does not fail closed with generic invalid-RV-data",
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
            checks.true(
                re.search(r"C\.CAPTURED_TEMPLATE_VERSION\s*=\s*9", constants)
                is not None
                and re.search(r"schemaVersion\s*=\s*9", captured_template)
                is not None
                and re.search(r"objectCount\s*=\s*412", captured_template)
                is not None
                and len(captured_template_rows) == 412
                and len(captured_template_objects) == 412
                and protection_identity_matches_template
                and "protectFromDemolition" not in captured_template
                and all(
                    f"{enum} = {value}" in protection_manifest
                    for enum, value in (
                        ("P.FREE_DEMOLITION", 1),
                        ("P.RESTORE_ONLY", 2),
                        ("P.PROHIBITED", 3),
                        ("P.SPECIAL", 4),
                    )
                )
                and "P.OBJECT_COUNT = 412" in protection_manifest
                and "P.EXPECTED_CLASS_COUNTS = { [1] = 54, [2] = 0, [3] = 358, [4] = 0 }" in protection_manifest
                and "function P.validateTemplate(template)" in protection_manifest
                and "not sameIdentity(record, captured)" in protection_manifest
                and protection_class_counts == {1: 54, 2: 0, 3: 358, 4: 0}
                and cab_classes_match
                and east_cab_classes_match
                and south_shell_floors_stay_protected
                and len(cab_opening_objects_outside_build_cells) == 3
                and all(protection_class_by_index.get(index) == 1
                    for index, _ in cab_opening_objects_outside_build_cells)
                and sorted(northwest_support_classes) == [3, 3]
                and all(
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
                        (-5, 0, 0, "true"), (-5, 1, 0, "true")}
                and len(captured_roof_cells) == 88,
                "current captured template version/count, corner walls, wardrobes, or roof-host count is stale",
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
                re.search(r"C\.MANIFEST_SCHEMA_VERSION\s*=\s*9", constants)
                and re.search(r"C\.MAP_SCHEMA_VERSION\s*=\s*6", constants)
                and re.search(r"C\.RV_RECORD_SCHEMA_VERSION\s*=\s*5", constants)
                and re.search(r"C\.RV_RELATION_SCHEMA_VERSION\s*=\s*4", constants)
                and re.search(r"C\.BOUNDARY_SCHEMA_VERSION\s*=\s*6", constants)
                and re.search(r"C\.LAYOUT_SCHEMA_VERSION\s*=\s*11", constants)
                and re.search(r"C\.BITMAP_VERSION\s*=\s*6", constants),
                "current manifest, mapping, boundary, layout, and bitmap versions were not advanced",
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
                'require "RailroaderRV/RV_BoundaryWallVisuals"' in client
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
                'require "RailroaderRV/RV_WardrobeVisuals"' in client
                and 'local Template = require "RailroaderRV/RV_Template"' in wardrobe_visuals
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
                "expected.protectionClass == ProtectionManifest.PROHIBITED" in protected_demolition
                and "objectMatchesStaticIdentity(object, tag, expected)" in protected_demolition
                and "ProtectionManifest.get(index)" in protected_demolition
                and "templateAnchorX" in protected_demolition
                and "C.TELEPORT_X" not in protected_demolition
                and re.search(
                    r"if not indexOk[\s\S]*?or not squareOk or not square then\s*return false",
                    protected_demolition,
                ) is not None
                and "if not expected or not objectMatchesStaticIdentity(object, tag, expected) then\n        return true" in protected_demolition
                and "action.new(self, character, object, ...)" in protected_demolition,
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
                and "#Template.buildCells ~= 24" in layout,
                "shared layout does not expose the captured 6x23 interior and 6x4 cab build mask",
            )
            checks.true(
                "Template.objects" in layout
                and "templateIndex" in layout
                and "bounds.wallObjectCount ~= 59" in server_schema
                and "bounds.northEdges ~= 12 or bounds.westEdges ~= 47" in server_schema
                and "bounds.wallCornerCount ~= 1" in server_schema
                and "values.wallObjectCount ~= 59" in manifest_validation
                and "values.northEdges ~= 12 or values.westEdges ~= 47" in manifest_validation
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
                and "local expected = ProtectionManifest.worldEntry(templateIndex, anchor)" in template_repair
                and "for templateIndex = 1, ProtectionManifest.OBJECT_COUNT do" in template_repair
                and "local protected = protectionClass == ProtectionManifest.RESTORE_ONLY" in template_repair
                and "or protectionClass == ProtectionManifest.PROHIBITED" in template_repair
                and "tag.role ~= \"captured-template\"" in template_repair
                and len(west_cab_wall_tiles) == 4
                and "protectFromDemolition" not in layout + generation_build + world_objects + protected_demolition + template_repair,
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
            "server Lua still relies on the unavailable Kahlua global next",
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
                "requiredInteger(Constants.TELEPORT_X" in queue
                and "requiredInteger(Constants.TELEPORT_Y" in queue
                and "requiredInteger(Constants.TELEPORT_Z" in queue
                and "layout = layoutOrError" in queue
                and "bounds = bounds" in queue
                and "oldBounds = oldBounds" in queue
                and "stagingDestination =" in queue,
                "fixed cleanup plan is not captured before relocation",
            )
            checks.true(
                "requireCurrentManifest" in queue
                and "local oldBounds = manifest.generation ~= nil and manifest.bounds or nil" in queue
                and "persistedBoundsMatchBoundary" not in queue
                and "prior bounds are untrusted" not in queue,
                "generation queue does not gate current manifest data before using bounds",
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
                and "clearMinX ~= targetX - 50" in target_coordinates
                and "clearMaxX ~= targetX - 50 + 100" in target_coordinates
                and "clearMinY ~= targetY - 50" in target_coordinates
                and "clearMaxY ~= targetY - 50 + 100" in target_coordinates
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
                and "All 10000 base squares" in preflight,
                "loaded-area preflight does not reuse the target contract before loading",
            )
            checks.true(
                "All 10000 base squares" in preflight,
                "loaded-area preflight does not document all 10000 base squares",
            )
            checks.true(
                "allowIncomplete" in preflight
                and "return false, reason" in preflight,
                "loaded-area preflight cannot report an incomplete footprint without raising",
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
                and "cellOrError, bounds, true" in load_wait
                and "loaded == false" in load_wait
                and "return false" in load_wait,
                "post-teleport loading wait does not retry incomplete target footprints",
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
                and "Template.objectCount ~= 412" in build_generation
                and "createCapturedTemplateObject(cell, square, entry" in build_generation
                and "captured object differs from the current template" in build_generation,
                "buildGeneration does not apply the current 412-object template",
            )

        entry_generator_helper = section(
            template_repair,
            r"function Boundary\.ensureGeneratorForEntry\(player, record\)",
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
                and "generatorOnClickedSquare" not in template_repair,
                "entry generator repair does not require the committed current identity or roll back failed creation",
            )
        entry_existing_pos = entry_exit.find("local function enterExisting")
        generator_entry_pos = entry_exit.find("Boundary.ensureGeneratorForEntry", entry_existing_pos)
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
            and 'refreshServerRoomOwnershipGuard(guard, "after-commit")' in final_generation
            and final_generation.find('"before-commit"')
                < final_generation.find('setGenerationPhase(manifest, prepared.generation, "COMMITTED")')
            and final_generation.find('setManifestState(manifest, "READY")')
                < final_generation.find('"after-commit"'),
            "manifest commit is missing the asynchronous room-ownership scans around READY",
        )

        tick = section(
            server_commands,
            r"function RV\.Server\.OnTick\(\)",
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
                r"local function roofRepairPosition",
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
            timeout_pos = tick.find("elapsed > RELOCATION_TIMEOUT_TICKS")
            timeout_cancel_pos = tick.find("cancelPending(", timeout_pos)
            checks.true(
                timeout_pos >= 0
                and timeout_cancel_pos > timeout_pos
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
            checks.true(
                prepared_generate.find("playerIsAtStagingDestination")
                < prepared_generate.find("removeOldGeneration"),
                "old room cleanup can run before the defensive destination check",
            )
            preflight_pos = prepared_generate.find("preflightLoaded(cell, bounds)")
            clear_pos = prepared_generate.find("pcall(clearGenerationArea")
            checks.true(
                preflight_pos > prepared_generate.find("playerIsAtStagingDestination")
                and clear_pos > preflight_pos,
                "cleanup transaction does not keep the final loaded-area preflight before mutation",
            )
            arm_pos = prepared_generate.find("armClientRoomOwnershipGuard")
            server_guard_pos = prepared_generate.find(
                "registerServerRoomOwnershipGuard"
            )
            remove_old_pos = prepared_generate.find("removeOldGeneration")
            checks.true(
                arm_pos >= 0
                and server_guard_pos > arm_pos
                and remove_old_pos > server_guard_pos,
                "client/server stale-room guards are not registered before old-generation removal",
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
            and "for i = 1, #Template.objects do" in structure_coordinates
            and "local captured = Template.objects[i]" in structure_coordinates
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
                and "pcall(requireCurrentManifest, manifest, false)"
                in current_room_monitor
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
                "ctx.roofRepairRelocationGroup ~= nil or ctx.roofRepairGroupFinalReturn ~= nil"
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
            and "local finiteNumber = C.finiteNumber" in client
            and "local finiteInteger = C.finiteInteger" in client
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
        hidden_component = section(
            utility_water,
            r"local function addFluidComponent",
            r"objectAttached = function",
        )
        checks.true(hidden_component is not None, "hidden utility fluid component helper is missing")
        if hidden_component is not None:
            checks.true(
                'rawget(_G, "GameEntityFactory")' in hidden_component
                and "AddComponent" in hidden_component
                and "CreateComponent" in hidden_component
                and "object, true, component" in hidden_component
                and "objectContainer(object)" in hidden_component,
                "hidden utility objects do not mount and verify their current FluidContainer",
            )
        hidden_attach = section(
            utility_water,
            r"local function attachObject",
            r"local function addFluidComponent",
        )
        hidden_create = section(
            utility_water,
            r"local function makeObject",
            r"local function fixtureInside",
        )
        checks.true(
            hidden_attach is not None
            and "transmitAddObjectToSquare" in hidden_attach,
            "hidden utility object attach helper is missing",
        )
        if hidden_attach is not None:
            checks.true(
                '"transmitAddObjectToSquare", object, -1' in hidden_attach
                and "local before = objectAttached(square, object)" in hidden_attach
                and "local after = objectAttached(square, object)" in hidden_attach
                and "if after ~= true then return false end" in hidden_attach,
                "hidden utility object attach does not send one add packet and verify square/index state",
            )
        checks.true(hidden_create is not None, "hidden utility object constructor helper is missing")
        if hidden_create is not None:
            checks.true(
                "C.UTILITY_HIDDEN_OBJECT_CLASS" in hidden_create
                and "Util.invokeClass(cls," in hidden_create
                and "Util.classInstance(object, C.UTILITY_HIDDEN_OBJECT_CLASS)" in hidden_create
                and "applyAmount(object, initial" in hidden_create
                and "U.WATER_CAPACITY, true)" in hidden_create
                and "attachObject(square, object)" in hidden_create
                and hidden_create.find("applyAmount(object, initial")
                < hidden_create.find("attachObject(square, object)"),
                "IsoThumpable identity/tag/fluid projection is not finalized before square attachment",
            )
        checks.true(
            "validUtilityTag" in utility_water
            and "schemaVersion = U.WATER_SCHEMA_VERSION" in utility_water
            and "sameGenerationIdentity" in utility_water
            and "retired role/schema" in utility_water
            and 'validUtilityTag(oldTag, identity, "fixture", oldTag.deviceId)' in utility_water
            and "proxyFingerprint = hiddenObjectFingerprint(C.UTILITY_ROLE_PROXY," in utility_water
            and "proxyPostcondition" in utility_water
            and "objectFingerprint(found, C.UTILITY_ROLE_PROXY)" in utility_water,
            "utility object tags/postcondition do not enforce current identity and stable proxy fingerprint",
        )
        checks.true(
            "OnObjectAdded" in utility_client
            and "OnLoadGridsquare" in utility_client
            and "setDoRender(false)" in utility_client,
            "client does not reapply hidden utility rendering state after object/square load",
        )
        checks.true(
            "function Menu.utilityEntryPoint" in railroader_client
            and "ENTRY_INTERNAL" in railroader_client
            and "ENTRY_LOCOMOTIVE" in railroader_client,
            "client utility menus do not select the two current manual-water entry points",
        )
        checks.true(
            all(token in utility_water for token in (
                "ensureUsageTank", "flushBeforeOverwrite", "collectAllLoadedProxyDeltas",
                "settleUsageToCanonical", "projectUsageToProxies", "projectionPending",
                "FAULT_UNCONFIRMED_CONSUMPTION_REBUILD", "onWaterAmountChange",
                "doFindExternalWaterSource", "FindExternalWaterSource",
                "UTILITY_PROXY_Z_OFFSET",
            )),
            "water module is missing the current usage/proxy settlement and postcondition contract",
        )
        ensure_tank = section(
            utility_water,
            r"function M\.ensureUsageTank",
            r"local function hasPipeWrench",
        )
        checks.true(ensure_tank is not None, "usage-tank initialization transaction is missing")
        if ensure_tank is not None:
            invalid_gate = 'status == "duplicate" or status == "invalid"'
            checks.true(
                invalid_gate in ensure_tank
                and ensure_tank.find(invalid_gate) < ensure_tank.find("makeObject"),
                "usage-tank initialization can create a replacement beside an incompatible object",
            )
            checks.true(
                "workingRecord" in ensure_tank
                and "Store.validateRecord(workingRecord, identity)" in ensure_tank
                and "recordMeta.fresh" in ensure_tank
                and "recordFresh and object" in ensure_tank
                and ensure_tank.find("recordFresh and object") < ensure_tank.find("makeObject")
                and "not recordFresh and not object" in ensure_tank
                and ensure_tank.find("not recordFresh and not object") < ensure_tank.find("makeObject")
                and "Store.commit(record, identity)" in ensure_tank,
                "usage-tank initialization does not carry fresh metadata or fail closed for persisted-missing objects",
            )
        checks.true(
            "retiredObjectTag" not in utility_objects + utility_plumbing
            and "if sameGenerationIdentity(tag, identity) then" in utility_objects
            and "validUtilityTag(tag, identity, role, deviceId)" in utility_objects
            and 'validUtilityTag(oldTag, identity, "fixture", oldTag.deviceId)' in utility_plumbing,
            "usage-tank square audit retains current utility tag validation without retired-object handling",
        )
        checks.true(
            "local recordFresh = false" in utility_store
            and "recordFresh = true" in utility_store
            and "return true, record, recordFresh" in utility_store,
            "utility store does not expose trusted fresh-versus-persisted record metadata",
        )
        checks.true(
            "objectAttached = function(square, object)" in utility_water
            and "local function rollbackCreatedObject" in utility_water
            and "local function creationFailure" in utility_water
            and "if attached == false then return true end" in utility_water
            and "if attached ~= true then return false end" in utility_water
            and "removeObject and removeObject(object) == true" in utility_water
            and "if object and not rollbackCreatedObject(square, object) then" in utility_water
            and "return creationFailure(square, object, U.REASONS.API_ERROR)" in utility_water,
            "hidden-object creation failure does not have an observable square rollback path",
        )
        checks.true(
            "local function readRoot" in utility_store
            and "local function restoreRoot" in utility_store
            and "local function copyTable" in utility_store
            and "record = copyTable(persisted)" in utility_store
            and "value.records[tostring(identity.rvId)] = copyTable(record)" in utility_store
            and "restoreRoot(before)" in utility_store,
            "utility store does not isolate live ModData records across commit failure",
        )
        checks.true(
            "local ok, accepted, detail, commitFailed = pcall" in utility_water
            and "return accepted, detail, commitFailed" in utility_water
            and "markCurrentWaterRebuild(identity, result)" in utility_water,
            "utility flush does not carry commit failure into a current-only rebuild gate",
        )
        initialize_record = section(
            utility_server,
            r"function M\.initializeRecord",
            r"return M",
        )
        checks.true(
            initialize_record is not None
            and "local recordOk, recordOrReason, recordFresh = Store.getRecord(identity, true)" in initialize_record
            and "Water.ensureUsageTank(identity, context, recordOrReason," in initialize_record
            and "fresh = recordFresh" in initialize_record
            and "local committed, reason = Store.commit" not in initialize_record,
            "utility initialization does not pass Store fresh metadata or still performs a second unisolated record commit",
        )
        connect_transaction = section(
            utility_water,
            r"function M\.connectDevice",
            r"local function inventoryItems",
        )
        checks.true(connect_transaction is not None, "utility connect transaction is missing")
        if connect_transaction is not None:
            checks.true(
                "runtimeObjects[key(identity)" in connect_transaction
                and "removeObject(createdProxy)" in connect_transaction
                and "restoreFixtureTag(object, oldTag)" in connect_transaction
                and "proxySquareEvidence" in connect_transaction
                and 'proxyState == "orphan"' in connect_transaction
                and 'proxyState == "registered"' in connect_transaction
                and connect_transaction.find('proxyState == "orphan"') < connect_transaction.find("makeObject")
                and 'if existing or status == "duplicate" then return false, C.INVALID_RV_DATA end'
                and "result.committed ~= true" in connect_transaction
                and "markCurrentWaterRebuild(identity, result)" in connect_transaction,
                "CONNECT does not gate orphan/duplicate proxy squares or prove proxy/fixture rollback around the isolated root",
            )
        checks.true(
            "local function completeProxyRegistration" in utility_water
            and "local function proxySquareEvidence" in utility_water
            and "local function genericObjectTag" in utility_water
            and "generic.role == C.UTILITY_ROLE_PROXY" in utility_water
            and "entry.proxyToken" in utility_water
            and "entry.proxyFingerprint" in utility_water
            and "ledger.deviceId" in utility_water,
            "CONNECT has no complete registry/proxy-ledger evidence gate for an existing proxy",
        )
        checks.true(
            "restoreSourceOrRebuild" in utility_water
            and "markSourceBoundaryRebuild" in utility_water
            and "if transferResult then" in utility_water
            and "lock this current record for manual rebuild" in utility_water,
            "manual water source rollback/commit ambiguity does not fail closed",
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
                generator.find("setActivated") > generator.find("tagObject")
                and generator.find("addSpecialObject") > generator.find("setActivated"),
                "generator attachment is not ordered after its final local/tag state",
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
            and "local captured = Template.objects[i]" in captured_template_phase
            and "createCapturedTemplateObject(cell, square, entry" in captured_template_phase
            and "captured object differs from the current template" in captured_template_phase
            and re.search(
                r'setGenerationPhase\(manifest, generation,\s*"COUNTER_SINK"',
                generation_build,
            ) is None,
            "generation does not apply the current captured template entry by entry",
        )

        cab_region = section(
            template_repair,
            r"local function isCabCoordinate",
            r"local function templateEntry",
        )
        cab_editable = section(
            template_repair,
            r"local function isCabEditableCoordinate",
            r"local function isRemovalScopeCoordinate",
        )
        template_repair_index = section(
            template_repair,
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
            and "index.cabEditableCoordinates[coordinate]" in cab_editable
            and "index.protectedCoordinates[coordinate]" in cab_editable
            and "return offsetX ~= Constants.CAB_MAX_OFFSET_X" in cab_editable
            and template_repair_index is not None
            and "for templateIndex = 1, ProtectionManifest.OBJECT_COUNT do" in template_repair_index
            and "local protected = protectionClass == ProtectionManifest.RESTORE_ONLY" in template_repair_index
            and "or protectionClass == ProtectionManifest.PROHIBITED" in template_repair_index
            and "if not protected then" in template_repair_index
            and "index.cabEditableCoordinates[coordinateKey(expected.x," in template_repair_index
            and "function Boundary.sampleBuildGuardPlayer" in template_repair
            and "for offsetY = -1, 1 do" in template_repair
            and "for offsetX = -1, 1 do" in template_repair
            and "enqueueTile(queue, x, y)" in template_repair
            and "function Boundary.processBuildGuardQueue" in template_repair
            and "local entry = popTile(selected.queue)" in template_repair
            and "capturedClasses[captured.class] = true" in template_repair
            and player_build_policy is not None
            and "CAB_MIN_OFFSET_X" in player_build_policy
            and "CAB_MAX_OFFSET_X" in player_build_policy
            and "CAB_MIN_OFFSET_Y" in player_build_policy
            and "CAB_MAX_OFFSET_Y" in player_build_policy
            and "if cabOnly or buildableOnly then return false end" in player_build_policy,
            "static repair classes, cab edits, and queued dynamic-object cleanup do not follow the current policy",
        )

        building_object_classes = section(
            template_repair,
            r"local buildingObjectClasses = {",
            r"local structuralSpriteFlagNames",
        )
        plain_structural = section(
            template_repair,
            r"local function isStructuralPlainObject",
            r"local function objectAtCoordinate",
        )
        structural_flags = section(
            template_repair,
            r"local function hasStructuralSpriteFlag",
            r"local function hasStructuralObjectType",
        )
        structural_types = section(
            template_repair,
            r"local function hasStructuralObjectType",
            r"local function isStructuralPlainObject",
        )
        protected_candidate = section(
            template_repair,
            r"local function isProtectedBuildingCandidate",
            r"local function isWhitelistedTemplateObject",
        )
        checks.true(
            building_object_classes is not None
            and '"IsoDoor"' in building_object_classes
            and '"IsoWindowFrame"' in building_object_classes
            and plain_structural is not None
            and "hasStructuralObjectType(object)" in plain_structural
            and "hasStructuralSpriteFlag(object)" in plain_structural
            and structural_flags is not None
            and 'rawget(_G, "IsoFlagType")' in structural_flags
            and 'invoke(properties, "has", flag)' in structural_flags
            and structural_types is not None
            and 'rawget(_G, "IsoObjectType")' in structural_types
            and protected_candidate is not None
            and 'className == "IsoObject"' in protected_candidate
            and "not isStructuralPlainObject(object)" in protected_candidate
            and "elseif not isBuildingObjectClass(object) then" in protected_candidate,
            "official door/frame classes and TileWalls_51-style engine structure metadata are not classified independently of sprite-family names",
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
            "现有存档、玩家数据库、管理员权限" in testserver_agent,
            "testserver docs do not declare reuse of existing saves and permissions",
        )
        checks.true(
            "不会删除、重建或自动重置" in testserver_agent,
            "testserver docs do not prohibit automatic reset",
        )
        checks.true(
            "UTF-8" in testserver_agent,
            "testserver docs do not record the UTF-8 startup constraint",
        )
        checks.true(
            "runtime/server/" in testserver_agent
            and "runtime/client/" in testserver_agent,
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
            and "再等待并复核" in readme
            and "加载等待期间不做任何世界修改" in readme
            and "10000 个 base 方格" in readme,
            "README does not document the fixed footprint and post-teleport wait",
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

    checks.true(runner_path.is_file(), f"one-click test runner is missing: {runner_path}")
    if runner_path.is_file():
        runner = read_utf8(runner_path)
        checks.true(
            'runtime_root = run_bat.parent / "runtime"' in runner,
            "one-click test runner does not use the persistent testserver/runtime cache",
        )
        checks.true(
            'server_cache = resolve_path(args.server_cache, project_root) or (runtime_root / "server")'
            in runner,
            "one-click test runner has an unexpected default server cache path",
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
