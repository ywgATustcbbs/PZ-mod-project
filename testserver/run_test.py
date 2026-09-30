#!/usr/bin/env python3
"""Prepare and launch the local Railroader RV multiplayer test environment.

The script deliberately leaves the in-game connection and all gameplay actions
to a human.  It stages the local mod and required BuildCraft dependency, writes
an isolated server profile, starts ``testserver/run.bat`` and launches the
regular Project Zomboid client.

Only Python's standard library is required.  The normal run uses Windows;
``--dry-run``, ``--prepare-only`` and ``--smoke-test`` are also useful for
static/CI checks.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence


MOD_ID = "RailroaderRVTest"
BUILDCRAFT_MOD_ID = "BuildingCraft"
BUILDCRAFT_WORKSHOP_ID = "3459887404"
SERVER_NAME = "test"
DEFAULT_PORT = 16261
DEFAULT_UDP_PORT = 16262
SERVER_READY_MARKER = "*** SERVER STARTED"
# Windows' SW_SHOWNORMAL value.  Keep this local instead of importing a GUI
# package: the launcher must remain standard-library only.
SW_SHOWNORMAL = 1
INSTANCE_STATE_FILENAME = ".railroader-rv-test-instance.json"
INSTANCE_LOCK_FILENAME = ".railroader-rv-test.lock"
CACHE_LAYOUT_FILENAME = ".railroader-rv-test-cache-layout.json"
RAMDISK_CACHE_ROOT = Path(r"Z:\RailroaderRVTestCache")
RAMDISK_WARN_FREE_BYTES = 256 * 1024 * 1024
RAMDISK_URGENT_FREE_BYTES = 128 * 1024 * 1024
# This is deliberately a fixed credential for the isolated, local test server
# only.  It is printed when the server is ready and documented in agent.md.
TEST_ADMIN_USERNAME = "admin"
TEST_ADMIN_PASSWORD = "RailroaderRVTestAdmin42"

# These are written to the isolated server profile before the Java server is
# launched.  In B42 the enum values alone are not the complete runtime
# setting: the water/electricity shutdown code reads the corresponding
# ``*Modifier`` values, and ``-1`` is the instant-shutdown value.
SANDBOX_ASSIGNMENTS: Mapping[str, str] = {
    "VERSION": "6",
    "WaterShut": "1",
    "ElecShut": "1",
    "WaterShutModifier": "-1",
    "ElecShutModifier": "-1",
    "AllowMiniMap": "true",
    "AllowWorldMap": "true",
    "MapAllKnown": "true",
    "MapNeedsLight": "true",
}
SANDBOX_TEMPLATE = """SandboxVars = {
    VERSION = 6,
    WaterShut = 1,
    ElecShut = 1,
    WaterShutModifier = -1,
    ElecShutModifier = -1,
    Map = {
        AllowMiniMap = true,
        AllowWorldMap = true,
        MapAllKnown = true,
        MapNeedsLight = true,
    },
}
"""


class RunnerError(RuntimeError):
    """A user-actionable setup or process error."""


def log(message: str) -> None:
    print(f"[RailroaderRVTest] {message}", flush=True)


def warn(message: str) -> None:
    print(f"[RailroaderRVTest][WARN] {message}", flush=True)


def resolve_path(value: Path | None, base: Path) -> Path | None:
    if value is None:
        return None
    if not value.is_absolute():
        value = base / value
    return value.expanduser().resolve()


def require_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise RunnerError(f"找不到{label}: {path}")


def ensure_directory(path: Path, label: str, dry_run: bool) -> None:
    if path.exists() and not path.is_dir():
        raise RunnerError(f"{label}不是目录: {path}")
    if dry_run:
        log(f"[dry-run] 将确保目录存在: {path}")
    else:
        path.mkdir(parents=True, exist_ok=True)


def parse_mod_id(mod_info: Path) -> str | None:
    try:
        text = mod_info.read_text(encoding="utf-8-sig")
    except OSError as exc:
        raise RunnerError(f"无法读取模组元数据 {mod_info}: {exc}") from exc
    for line in text.splitlines():
        match = re.match(r"^\s*id\s*=\s*(\S+)\s*$", line)
        if match:
            return match.group(1)
    return None


def validate_mod_source(source: Path) -> None:
    if not source.is_dir():
        raise RunnerError(f"找不到本地模组目录: {source}")
    mod_info = source / "mod.info"
    # The repository intentionally keeps only the versioned package layout:
    # RailroaderRVTest/42/mod.info.  A root mod.info is also accepted for
    # normal Workshop-style packages.
    if not mod_info.is_file():
        mod_info = source / "42" / "mod.info"
    require_file(mod_info, "模组 mod.info（根目录或 42/ 目录）")
    mod_id = parse_mod_id(mod_info)
    if mod_id != MOD_ID:
        raise RunnerError(
            f"模组 ID 不匹配: {mod_info} 中为 {mod_id!r}，预期 {MOD_ID!r}"
        )


def validate_buildcraft_source(source: Path) -> None:
    """Validate a complete local BuildingCraft package root.

    The Workshop package is not itself the PZ package root: it normally has
    ``mods/BuildingCraft/common`` and ``mods/BuildingCraft/42.0`` below the
    Workshop item directory.  Keep both version layouts when staging and do
    not require a root-level ``mod.info`` that the package does not provide.
    """

    if not source.is_dir():
        raise RunnerError(f"找不到 BuildCraft 模组目录: {source}")

    common_info = source / "common" / "mod.info"
    version_info = source / "42.0" / "mod.info"
    root_info = source / "mod.info"
    infos = [path for path in (common_info, version_info) if path.is_file()]
    if len(infos) == 2:
        for mod_info in infos:
            mod_id = parse_mod_id(mod_info)
            if mod_id != BUILDCRAFT_MOD_ID:
                raise RunnerError(
                    f"BuildCraft ID 不匹配: {mod_info} 中为 {mod_id!r}，"
                    f"预期 {BUILDCRAFT_MOD_ID!r}"
                )
        return

    # Accept a conventional single-root package as an explicit override, but
    # never mistake a Workshop item root for one: the item root has neither a
    # root mod.info nor the versioned package content.
    if root_info.is_file():
        mod_id = parse_mod_id(root_info)
        if mod_id == BUILDCRAFT_MOD_ID:
            return
        raise RunnerError(
            f"BuildCraft ID 不匹配: {root_info} 中为 {mod_id!r}，"
            f"预期 {BUILDCRAFT_MOD_ID!r}"
        )

    missing = ", ".join(
        str(path.relative_to(source))
        for path in (common_info, version_info)
        if not path.is_file()
    )
    raise RunnerError(
        "BuildCraft 包不完整：需要 package root 下的 "
        f"common/mod.info 和 42.0/mod.info（缺少 {missing or 'mod.info'}）: {source}"
    )


def _unique_paths(paths: Sequence[Path]) -> list[Path]:
    result: list[Path] = []
    seen: set[str] = set()
    for path in paths:
        normalized = str(path.expanduser().resolve()).casefold()
        if normalized in seen:
            continue
        seen.add(normalized)
        result.append(path.expanduser().resolve())
    return result


def _buildcraft_package_candidates(path: Path) -> list[Path]:
    """Return known package-root shapes for a user-supplied path."""

    path = path.expanduser().resolve()
    # Make ``--buildcraft-source .../BuildingCraft/42.0`` and
    # ``.../BuildingCraft/common`` convenient without recursively scanning a
    # user directory.
    if path.name.casefold() in {"common", "42", "42.0"}:
        candidates = [
            path.parent,
            path,
            path / BUILDCRAFT_MOD_ID,
            path / "mods" / BUILDCRAFT_MOD_ID,
        ]
    else:
        candidates = [
            path,
            path / BUILDCRAFT_MOD_ID,
            path / "mods" / BUILDCRAFT_MOD_ID,
        ]
    return _unique_paths(candidates)


def resolve_buildcraft_source(explicit: Path | None) -> Path:
    """Find and validate BuildCraft's package root without mutating it."""

    if explicit is not None:
        candidates = _buildcraft_package_candidates(explicit)
    else:
        candidates = []
        for library in find_steam_libraries():
            item_root = (
                library
                / "steamapps"
                / "workshop"
                / "content"
                / "108600"
                / BUILDCRAFT_WORKSHOP_ID
            )
            candidates.extend(_buildcraft_package_candidates(item_root))
        candidates = _unique_paths(candidates)

    validation_errors: list[str] = []
    for candidate in candidates:
        if not candidate.is_dir():
            continue
        try:
            validate_buildcraft_source(candidate)
        except RunnerError as exc:
            validation_errors.append(str(exc))
            continue
        return candidate

    if explicit is not None:
        location = str(explicit.expanduser().resolve())
        raise RunnerError(
            "找不到可用的 BuildCraft 本地 package root。请使用 "
            f"--buildcraft-source 指向包含 common/mod.info 和 42.0/mod.info 的 "
            f"BuildingCraft 目录（当前路径: {location}）。"
        )

    libraries = ", ".join(str(path) for path in find_steam_libraries())
    raise RunnerError(
        f"找不到 BuildCraft（Workshop {BUILDCRAFT_WORKSHOP_ID}，mod id "
        f"{BUILDCRAFT_MOD_ID}）。请在 Steam 安装/订阅该 Workshop，或用 "
        "--buildcraft-source 指定本地 package root；已检查 Steam 库: "
        f"{libraries or '（未发现 Steam 库）'}。"
    )


def _copy_mod_tree(source: Path, destination: Path, dry_run: bool) -> tuple[int, int]:
    """Overlay the source mod without deleting files at the destination.

    The destination is normally an isolated cache.  Overlaying rather than
    recursively deleting it keeps an explicitly supplied destination safe;
    stale files are reported so they can be investigated without data loss.
    """

    if source.resolve() == destination.resolve():
        log(f"模组目的地已是源目录，跳过复制: {destination}")
        return (0, 0)

    source_files: set[Path] = set()
    copied = 0
    directories = 0
    for item in source.rglob("*"):
        relative = item.relative_to(source)
        target = destination / relative
        if item.is_symlink():
            raise RunnerError(f"模组中不支持符号链接（为避免越界读取）: {item}")
        if item.is_dir():
            directories += 1
            if not dry_run:
                if target.exists() and not target.is_dir():
                    raise RunnerError(f"复制模组时目标类型冲突: {target}")
                target.mkdir(parents=True, exist_ok=True)
            continue
        if not item.is_file():
            continue
        source_files.add(relative)
        copied += 1
        if dry_run:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.is_dir():
            raise RunnerError(f"复制模组时目标类型冲突: {target}")
        shutil.copy2(item, target)

    if destination.is_dir():
        destination_files = {
            item.relative_to(destination)
            for item in destination.rglob("*")
            if item.is_file()
        }
        stale = sorted(destination_files - source_files)
        if stale:
            warn(
                f"模组目的地存在 {len(stale)} 个源包中没有的旧文件，未删除: {destination}"
            )
    return (copied, directories)


def stage_mod(
    source: Path,
    cache_dir: Path,
    label: str,
    dry_run: bool,
    mod_id: str = MOD_ID,
) -> None:
    destination = cache_dir / "mods" / mod_id
    ensure_directory(destination, f"{label}模组目录", dry_run)
    files, directories = _copy_mod_tree(source, destination, dry_run)
    action = "将复制" if dry_run else "已复制"
    log(
        f"{action}{label}模组: {files} 个文件、{directories} 个目录 "
        f"{source} -> {destination}"
    )


def update_ini(path: Path, values: Mapping[str, str], dry_run: bool) -> None:
    """Update only the named server options, preserving all other options."""

    if path.exists():
        try:
            original = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise RunnerError(f"无法读取服务器配置 {path}: {exc}") from exc
    else:
        original = ""

    lines = original.splitlines(keepends=True)
    seen: set[str] = set()
    updated: list[str] = []
    for line in lines:
        match = re.match(r"^\s*([^#;\s][^=]*)=(.*?)(\r?\n)?$", line)
        if not match:
            updated.append(line)
            continue
        key = match.group(1).strip()
        if key not in values:
            updated.append(line)
            continue
        seen.add(key)
        newline = match.group(3) or "\n"
        updated.append(f"{key}={values[key]}{newline}")

    for key, value in values.items():
        if key not in seen:
            updated.append(f"{key}={value}\n")
    rendered = "".join(updated)

    if dry_run:
        log(f"[dry-run] 将更新服务器配置: {path}")
        for key, value in values.items():
            log(f"[dry-run]   {key}={value}")
        return

    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(rendered)
        os.replace(temporary, path)
        temporary = None
    except OSError as exc:
        raise RunnerError(f"无法写入服务器配置 {path}: {exc}") from exc
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass
    log(f"已准备服务器配置: {path}")


def update_sandbox_vars(path: Path, dry_run: bool) -> None:
    """Write the B42 sandbox settings used by the isolated test server.

    The server profile is Lua rather than ``test.ini``.  Keep comments and
    all unrelated options from an existing generated profile, but fail closed
    when a supposedly existing profile is partial or contains duplicate
    assignments.  A missing profile is initialized with the small current-B42
    template; the server fills and rewrites the remaining defaults on startup.
    """

    if path.exists():
        try:
            original = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise RunnerError(f"无法读取 SandboxVars 配置 {path}: {exc}") from exc
    else:
        original = SANDBOX_TEMPLATE

    assignment = re.compile(
        r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^,\r\n]*)(,?)(\r?\n)?$"
    )
    seen: set[str] = set()
    updated: list[str] = []
    for line in original.splitlines(keepends=True):
        match = assignment.match(line)
        if not match:
            updated.append(line)
            continue
        key = match.group(2)
        if key not in SANDBOX_ASSIGNMENTS:
            updated.append(line)
            continue
        if key in seen:
            raise RunnerError(
                f"SandboxVars 配置包含重复键 {key}: {path}；"
                "请删除该测试配置后由一键脚本重新创建"
            )
        seen.add(key)
        newline = match.group(5) or "\n"
        comma = match.group(4)
        updated.append(
            f"{match.group(1)}{key} = {SANDBOX_ASSIGNMENTS[key]}{comma}{newline}"
        )

    missing = [key for key in SANDBOX_ASSIGNMENTS if key not in seen]
    if missing:
        raise RunnerError(
            f"SandboxVars 配置缺少当前 B42 测试键 {', '.join(missing)}: {path}；"
            "请删除该测试配置后由一键脚本重新创建"
        )
    rendered = "".join(updated)

    if dry_run:
        log(f"[dry-run] 将更新 SandboxVars 配置: {path}")
        for key, value in SANDBOX_ASSIGNMENTS.items():
            map_keys = {"AllowMiniMap", "AllowWorldMap", "MapAllKnown", "MapNeedsLight"}
            label = key if key not in map_keys else f"Map.{key}"
            log(f"[dry-run]   {label}={value}")
        return

    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(rendered)
        os.replace(temporary, path)
        temporary = None
    except OSError as exc:
        raise RunnerError(f"无法写入 SandboxVars 配置 {path}: {exc}") from exc
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass
    log(f"已准备 SandboxVars 配置: {path}")


def server_options(port: int, udp_port: int) -> dict[str, str]:
    # Keep this list intentionally small.  Missing options receive the game's
    # defaults; these values are the ones that make a local manual test safe
    # and deterministic.
    return {
        "PVP": "false",
        "PauseEmpty": "true",
        "Open": "true",
        "DefaultPort": str(port),
        "UDPPort": str(udp_port),
        "Mods": f"{BUILDCRAFT_MOD_ID};{MOD_ID}",
        "Map": "Muldraugh, KY",
        "DoLuaChecksum": "true",
        "Public": "false",
        "PublicName": "Railroader RV local test",
        "PublicDescription": "Manual local test for Railroader RV",
        "MaxPlayers": "4",
        "Password": "",
        "WorkshopItems": "",
        "SteamVAC": "false",
        "UPnP": "false",
        "VoiceEnable": "false",
        "SaveWorldEveryMinutes": "0",
    }


def find_steam_libraries() -> list[Path]:
    roots: list[Path] = []
    for variable in ("ProgramFiles(x86)", "ProgramFiles", "LOCALAPPDATA"):
        value = os.environ.get(variable)
        if value:
            roots.append(Path(value) / "Steam")
    steam_path = os.environ.get("STEAM_PATH") or os.environ.get("STEAM_ROOT")
    if steam_path:
        roots.insert(0, Path(steam_path).expanduser())

    libraries: list[Path] = []
    for root in roots:
        libraries.append(root)
        vdf = root / "steamapps" / "libraryfolders.vdf"
        if not vdf.is_file():
            continue
        try:
            text = vdf.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        # This intentionally handles the simple path records used by Steam;
        # it is not a general VDF parser and does not mutate the file.
        for raw_path in re.findall(r'"path"\s+"([^"]+)"', text, flags=re.IGNORECASE):
            libraries.append(Path(raw_path.replace("\\\\", "\\")))

    result: list[Path] = []
    seen: set[str] = set()
    for path in libraries:
        normalized = str(path.expanduser()).lower()
        if normalized in seen:
            continue
        seen.add(normalized)
        result.append(path.expanduser())
    return result


def discover_client(explicit: Path | None) -> Path | None:
    if explicit is not None:
        return explicit.expanduser().resolve()

    candidates: list[Path] = []
    for library in find_steam_libraries():
        candidates.append(
            library
            / "steamapps"
            / "common"
            / "ProjectZomboid"
            / "ProjectZomboid64.exe"
        )
    # Keep the known default path visible even when Steam has no readable VDF.
    candidates.insert(
        0,
        Path(r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\ProjectZomboid64.exe"),
    )
    candidates.append(
        Path(r"C:\Program Files\Steam\steamapps\common\ProjectZomboid\ProjectZomboid64.exe")
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    return None


def validate_port(port: int, label: str) -> None:
    if not 1 <= port <= 65535:
        raise RunnerError(f"{label}必须在 1..65535 范围内: {port}")


def port_is_free(port: int) -> bool:
    sockets: list[socket.socket] = []
    try:
        # IPv4 is what the local PZ client uses.  Treat an unavailable IPv6
        # stack as non-fatal so machines with IPv6 disabled still work.
        ipv4 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sockets.append(ipv4)
        ipv4.bind(("127.0.0.1", port))
        try:
            ipv6 = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
            sockets.append(ipv6)
            ipv6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            ipv6.bind(("::1", port))
        except OSError:
            pass
        return True
    except OSError:
        return False
    finally:
        for sock in sockets:
            sock.close()


def validate_ports(port: int, udp_port: int) -> None:
    validate_port(port, "DefaultPort")
    validate_port(udp_port, "UDPPort")
    if port == udp_port:
        raise RunnerError("DefaultPort 与 UDPPort 必须不同")
    for value, label in ((port, "DefaultPort"), (udp_port, "UDPPort")):
        if not port_is_free(value):
            raise RunnerError(
                f"{label}={value} 已被占用；请关闭旧服务器或用 --port/--udp-port 选择空闲端口"
            )


def read_tail(path: Path, limit: int = 4000) -> str:
    if not path.is_file():
        return "（尚未生成 server-console.txt）"
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return f"（读取日志失败: {exc}）"
    return text[-limit:]


def build_server_command(run_bat: Path, server_cache: Path) -> list[str]:
    """Build a command that reliably runs a batch file and waits for it.

    Do not use ``start`` here: Windows gives a batch-file target to ``start``
    with ``cmd.exe /K``, so the wrapper shell remains alive after the batch
    (and its Java child) has exited.  ``call`` makes ``cmd /c`` wait for the
    batch and return its exit code instead.  Keeping each token separate lets
    ``subprocess`` quote paths containing spaces; the batch files themselves
    forward all arguments with ``%*``.
    """

    return [
        "cmd.exe",
        "/d",
        "/c",
        "call",
        str(run_bat),
        f"-cachedir={server_cache}",
    ]


def visible_startup_info() -> subprocess.STARTUPINFO | None:
    """Request a normal interactive window for a child process on Windows."""

    if os.name != "nt":
        return None
    startup_info = subprocess.STARTUPINFO()
    startup_info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup_info.wShowWindow = SW_SHOWNORMAL
    return startup_info


def _run_powershell(script: str, *arguments: object) -> subprocess.CompletedProcess[str] | None:
    """Run a narrow PowerShell query used only for this test instance."""

    command = [
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        script,
        *(str(argument) for argument in arguments),
    ]
    try:
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
            startupinfo=visible_startup_info(),
        )
    except OSError:
        return None


def _process_command_line(pid: int) -> str | None:
    if os.name != "nt" or pid <= 0:
        return None
    result = _run_powershell(
        "& { param([int]$processId); "
        "$process = Get-CimInstance Win32_Process "
        "-Filter ('ProcessId = ' + $processId); "
        "if ($null -ne $process) { Write-Output $process.CommandLine } }",
        pid,
    )
    if result is None or result.returncode != 0:
        return None
    command_line = result.stdout.strip()
    return command_line or None


def _process_matches(pid: int, required_tokens: Sequence[str]) -> bool:
    command_line = _process_command_line(pid)
    if not command_line:
        return False
    # cmd.exe and PowerShell commonly add quotes around the value after
    # ``-cachedir=``.  Removing only quotes for comparison preserves the
    # exact path check while accepting both spellings.
    folded = command_line.replace('"', "").casefold()
    return all(token.replace('"', "").casefold() in folded for token in required_tokens)


def _terminate_owned_pid(pid: int, required_tokens: Sequence[str], label: str) -> bool:
    """Terminate a recorded process only after matching its exact launch tokens."""

    if os.name != "nt" or pid <= 0:
        return False
    if not _process_matches(pid, required_tokens):
        warn(f"跳过未能核验归属的{label} PID={pid}")
        return False
    result = subprocess.run(
        ["taskkill", "/PID", str(pid), "/T", "/F"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode not in (0, 128):
        details = result.stderr.strip() or result.stdout.strip()
        warn(f"终止旧{label} PID={pid}失败（exit code {result.returncode}）{details}")
        return False
    log(f"已清理旧一键测试{label}（PID={pid}）")
    return True


def _write_instance_state(path: Path, state: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            json.dump(dict(state), handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
        temporary = None
    except OSError as exc:
        raise RunnerError(f"无法写入一键测试实例状态 {path}: {exc}") from exc
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def _read_instance_state(path: Path) -> dict[str, object] | None:
    if not path.is_file():
        return None
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        warn(f"一键测试实例状态不可读，将移除损坏状态文件 {path}: {exc}")
        try:
            path.unlink()
        except OSError:
            pass
        return None
    if not isinstance(state, dict):
        warn(f"一键测试实例状态不是对象，将移除: {path}")
        try:
            path.unlink()
        except OSError:
            pass
        return None
    return state


def _state_pid(state: Mapping[str, object], key: str) -> int | None:
    value = state.get(key)
    if isinstance(value, bool):
        return None
    try:
        pid = int(value)
    except (TypeError, ValueError):
        return None
    return pid if pid > 0 else None


def _cleanup_recorded_instance(state: Mapping[str, object]) -> None:
    run_bat = str(state.get("run_bat") or "")
    server_cache = str(state.get("server_cache") or "")
    client_exe = str(state.get("client_exe") or "")
    client_cache = str(state.get("client_cache") or "")
    if run_bat and server_cache:
        _terminate_owned_pid(
            _state_pid(state, "server_pid") or -1,
            (run_bat, f"-cachedir={server_cache}"),
            "服务器",
        )
    if client_exe and client_cache:
        _terminate_owned_pid(
            _state_pid(state, "client_pid") or -1,
            (client_exe, f"-cachedir={client_cache}"),
            "客户端",
        )


def _legacy_server_pids(run_bat: Path, server_cache: Path) -> list[int]:
    """Find only old cmd wrappers for this exact run.bat/cache pair.

    This is a one-time compatibility path for instances started before the PID
    manifest existed.  It is intentionally limited to cmd.exe whose command
    line contains both exact project tokens; it does not inspect or terminate
    arbitrary Java/server processes.
    """

    if os.name != "nt":
        return []
    runtime_root = run_bat.parent / "runtime"
    try:
        server_cache.resolve().relative_to(runtime_root.resolve())
    except ValueError:
        if server_cache.resolve() != (RAMDISK_CACHE_ROOT / "server").resolve():
            return []
    result = _run_powershell(
        "& { param($runBat, $serverCache); "
        "$run = $runBat.ToLowerInvariant(); "
        "$cache = $serverCache.ToLowerInvariant(); "
        "Get-CimInstance Win32_Process -Filter \"Name = 'cmd.exe'\" | "
        "Where-Object { $_.CommandLine -and "
        "$_.CommandLine.ToLowerInvariant().Contains($run) -and "
        "$_.CommandLine.ToLowerInvariant().Contains($cache) } | "
        "ForEach-Object { Write-Output $_.ProcessId } }",
        str(run_bat),
        str(server_cache),
    )
    if result is None or result.returncode != 0:
        return []
    pids: list[int] = []
    for line in result.stdout.splitlines():
        try:
            pid = int(line.strip())
        except ValueError:
            continue
        if pid > 0:
            pids.append(pid)
    return pids


def _cleanup_previous_instance(state_path: Path, run_bat: Path, server_cache: Path) -> None:
    state = _read_instance_state(state_path)
    if state is not None:
        expected_run_bat = str(run_bat.resolve()).casefold()
        recorded_run_bat = str(state.get("run_bat") or "").casefold()
        if recorded_run_bat == expected_run_bat:
            _cleanup_recorded_instance(state)
            try:
                state_path.unlink()
            except OSError:
                pass
        else:
            warn(f"保留不属于本项目的实例状态文件: {state_path}")
        return

    # A previous launcher version did not write a manifest.  Adopt only the
    # exact project run.bat/cache command line, then apply the same ownership
    # verification before terminating it.
    legacy_caches = [server_cache]
    ramdisk_server_cache = (RAMDISK_CACHE_ROOT / "server").resolve()
    if server_cache.resolve() == ramdisk_server_cache:
        legacy_caches.append(run_bat.parent / "runtime" / "server")
    seen_caches: set[str] = set()
    for legacy_cache in legacy_caches:
        normalized_cache = str(legacy_cache.resolve()).casefold()
        if normalized_cache in seen_caches:
            continue
        seen_caches.add(normalized_cache)
        for pid in _legacy_server_pids(run_bat, legacy_cache):
            _terminate_owned_pid(
                pid,
                (str(run_bat.resolve()), f"-cachedir={legacy_cache.resolve()}"),
                "服务器",
            )


def _acquire_instance_lock(runtime_root: Path, run_bat: Path):
    runtime_root.mkdir(parents=True, exist_ok=True)
    lock_path = runtime_root / INSTANCE_LOCK_FILENAME
    for _ in range(2):
        try:
            descriptor = os.open(
                lock_path,
                os.O_CREAT | os.O_EXCL | os.O_WRONLY,
            )
            handle = os.fdopen(descriptor, "w", encoding="utf-8")
            json.dump({"pid": os.getpid(), "run_bat": str(run_bat.resolve())}, handle)
            handle.flush()
            return handle
        except FileExistsError:
            try:
                lock_state = json.loads(lock_path.read_text(encoding="utf-8"))
                owner_pid = int(lock_state.get("pid", 0))
            except (OSError, ValueError, TypeError, json.JSONDecodeError):
                owner_pid = 0
            owner_command = _process_command_line(owner_pid) if owner_pid > 0 else None
            if owner_command:
                raise RunnerError("已有另一个 Railroader RV 一键测试启动器正在运行")
            try:
                lock_path.unlink()
            except OSError as exc:
                raise RunnerError(f"无法清理失效的一键测试锁 {lock_path}: {exc}") from exc
    raise RunnerError(f"无法获取一键测试锁: {lock_path}")


def _release_instance_lock(runtime_root: Path, handle: object) -> None:
    try:
        close = getattr(handle, "close", None)
        if close is not None:
            close()
    finally:
        try:
            (runtime_root / INSTANCE_LOCK_FILENAME).unlink()
        except OSError:
            pass


def run_subprocess_smoke() -> None:
    """Exercise batch waiting, exit-code propagation, and spaced paths.

    This deliberately uses a temporary fake server batch and never touches
    the real server/client.  It is exposed as ``--smoke-test`` for a quick
    Windows-only check of the process boundary used by ``launch_server``.
    """

    if os.name != "nt":
        raise RunnerError("subprocess smoke 需要 Windows cmd.exe")

    with tempfile.TemporaryDirectory(prefix="Railroader RV subprocess smoke ") as raw_root:
        root = Path(raw_root)
        run_bat = root / "server wrapper" / "fake server runner.bat"
        cache = root / "cache with spaces"
        marker = run_bat.with_name("arguments.txt")
        run_bat.parent.mkdir(parents=True, exist_ok=True)
        cache.mkdir()
        run_bat.write_text(
            "@echo off\n"
            "setlocal enableextensions\n"
            "> \"%~dp0arguments.txt\" echo %*\n"
            "ping.exe -n 2 127.0.0.1 >nul 2>&1\n"
            "endlocal & exit /b 37\n",
            encoding="ascii",
            newline="\r\n",
        )

        command = build_server_command(run_bat, cache)
        log(f"运行 subprocess smoke: {subprocess.list2cmdline(command)}")
        started_at = time.monotonic()
        process = subprocess.Popen(
            command,
            cwd=str(run_bat.parent),
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        try:
            code = process.wait(timeout=10)
        except subprocess.TimeoutExpired as exc:
            stop_process_tree(process)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise RunnerError("subprocess smoke 超时，批处理生命周期未返回") from exc

        elapsed = time.monotonic() - started_at
        if code != 37:
            raise RunnerError(f"subprocess smoke exit code 错误: 预期 37，实际 {code}")
        if not marker.is_file():
            raise RunnerError(f"subprocess smoke 未生成参数标记: {marker}")
        arguments = marker.read_text(encoding="ascii").strip()
        if str(cache) not in arguments:
            raise RunnerError(
                "subprocess smoke 未收到含空格的 cachedir 参数: "
                f"{arguments!r}"
            )
        if elapsed < 0.4:
            raise RunnerError(
                f"subprocess smoke 返回过快（{elapsed:.2f}s），无法证明父进程等待批处理"
            )
        log(
            "subprocess smoke 通过："
            f"exit code=37，等待={elapsed:.2f}s，含空格路径参数已收到"
        )


def launch_server(run_bat: Path, server_cache: Path) -> subprocess.Popen[bytes]:
    if os.name != "nt":
        raise RunnerError("启动独立服务器需要 Windows cmd.exe")
    command = build_server_command(run_bat, server_cache)
    log(f"启动服务器入口: {run_bat}")
    log(f"服务器缓存: {server_cache}")
    log(f"服务器启动命令: {subprocess.list2cmdline(command)}")
    creation_flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
    try:
        return subprocess.Popen(
            command,
            cwd=str(run_bat.parent),
            creationflags=creation_flags,
            startupinfo=visible_startup_info(),
        )
    except OSError as exc:
        raise RunnerError(f"无法启动 testserver\\run.bat: {exc}") from exc


def wait_for_server(
    process: subprocess.Popen[bytes],
    log_path: Path,
    timeout: float,
    port: int,
    udp_port: int,
) -> None:
    started_at = time.monotonic()
    offset = log_path.stat().st_size if log_path.is_file() else 0
    fallback_since: float | None = None
    while True:
        code = process.poll()
        if code is not None:
            tail = read_tail(log_path)
            raise RunnerError(
                f"服务器进程提前退出（exit code {code}）。最近日志:\n{tail}"
            )

        if log_path.is_file():
            try:
                size = log_path.stat().st_size
                if size < offset:
                    offset = 0
                with log_path.open("r", encoding="utf-8", errors="replace") as handle:
                    handle.seek(offset)
                    new_text = handle.read()
                    offset = handle.tell()
            except OSError:
                new_text = ""
            if SERVER_READY_MARKER in new_text:
                log("服务器已报告 *** SERVER STARTED ***")
                return

        # A few server builds can delay/omit server-console.txt.  If both
        # RakNet UDP sockets are bound by the still-running child, accept that
        # as a conservative fallback after a short stable interval.
        if not port_is_free(port) and not port_is_free(udp_port):
            fallback_since = fallback_since or time.monotonic()
            if time.monotonic() - fallback_since >= 3:
                warn("未在日志中看到启动标记，但两个配置 UDP 端口已稳定占用；继续启动客户端")
                return
        else:
            fallback_since = None

        elapsed = time.monotonic() - started_at
        if elapsed >= timeout:
            raise RunnerError(
                f"等待服务器启动超过 {timeout:.0f} 秒。最近日志:\n{read_tail(log_path)}"
            )
        time.sleep(0.5)


def _launch_client_direct(client_exe: Path, client_cache: Path) -> int:
    """Fallback for hosts where PowerShell cannot create the GUI process."""

    command = [str(client_exe), f"-cachedir={client_cache}"]
    try:
        process = subprocess.Popen(
            command,
            cwd=str(client_exe.parent),
            startupinfo=visible_startup_info(),
        )
    except OSError as exc:
        raise RunnerError(f"无法启动游戏客户端 {client_exe}: {exc}") from exc
    log(f"客户端已启动（PID={process.pid}，窗口=Normal，direct fallback）")
    return process.pid


def launch_client(client_exe: Path, client_cache: Path) -> int:
    if os.name != "nt":
        raise RunnerError("启动常规游戏客户端需要 Windows")
    log(f"启动常规 Project Zomboid 客户端: {client_exe}")
    log(f"客户端缓存: {client_cache}")

    # The agent/terminal that runs this launcher can itself have no visible
    # console.  Start-Process creates the GUI process on the user's interactive
    # desktop and -WindowStyle Normal deliberately prevents inheriting a hidden
    # startup state.  Pass paths as PowerShell parameters instead of embedding
    # them in the script so spaces and shell metacharacters stay data.
    payload = base64.b64encode(
        json.dumps(
            {
                "filePath": str(client_exe),
                "argument": f'-cachedir="{client_cache}"',
                "workingDirectory": str(client_exe.parent),
            },
            ensure_ascii=False,
        ).encode("utf-8")
    ).decode("ascii")
    powershell_script = (
        "$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"
        + payload
        + "')) | ConvertFrom-Json; "
        "$process = Start-Process -FilePath $payload.filePath "
        "-ArgumentList @($payload.argument) "
        "-WorkingDirectory $payload.workingDirectory "
        "-WindowStyle Normal -PassThru; "
        "Write-Output $process.Id"
    )
    encoded_script = base64.b64encode(
        powershell_script.encode("utf-16le")
    ).decode("ascii")
    command = [
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
        encoded_script,
    ]
    try:
        result = subprocess.run(
            command,
            cwd=str(client_exe.parent),
            capture_output=True,
            text=True,
            check=False,
            startupinfo=visible_startup_info(),
        )
    except OSError as exc:
        warn(f"PowerShell Start-Process 无法启动客户端（{exc}），使用可见 direct fallback")
        return _launch_client_direct(client_exe, client_cache)
    if result.returncode != 0:
        details = result.stderr.strip() or result.stdout.strip()
        warn(
            f"PowerShell Start-Process 启动客户端失败（exit code {result.returncode}）"
            f"{': ' + details if details else ''}，使用可见 direct fallback"
        )
    pid_text = result.stdout.strip().splitlines()
    if result.returncode == 0 and pid_text and pid_text[-1].strip().isdigit():
        client_pid = int(pid_text[-1].strip())
        log(f"客户端已启动（PID={client_pid}，窗口=Normal）")
        return client_pid
    return _launch_client_direct(client_exe, client_cache)


def stop_process_tree(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    else:
        process.terminate()


@dataclass(frozen=True)
class Settings:
    project_root: Path
    run_bat: Path
    mod_source: Path
    buildcraft_source: Path | None
    server_cache: Path
    client_cache: Path
    server_cache_is_default: bool
    client_cache_is_default: bool
    client_exe: Path | None
    port: int
    udp_port: int
    startup_timeout: float
    dry_run: bool
    prepare_only: bool
    no_client: bool


def _is_reparse_point(path: Path) -> bool:
    try:
        attributes = getattr(os.lstat(path), "st_file_attributes", 0)
    except OSError:
        return False
    return path.is_symlink() or bool(attributes & 0x400)


def _cache_tree_size(path: Path) -> int:
    """Return a cache tree's size while refusing links that could escape it."""

    if not path.exists():
        return 0
    if _is_reparse_point(path):
        raise RunnerError(f"测试缓存根目录不能是链接或 junction: {path}")
    total = 0

    def fail_on_walk_error(error: OSError) -> None:
        raise RunnerError(f"无法完整检查测试缓存 {path}: {error}") from error

    for raw_root, directories, files in os.walk(
        path,
        followlinks=False,
        onerror=fail_on_walk_error,
    ):
        root = Path(raw_root)
        for name in list(directories):
            child = root / name
            if _is_reparse_point(child):
                raise RunnerError(f"测试缓存包含链接或 junction，拒绝复制: {child}")
        for name in files:
            child = root / name
            if _is_reparse_point(child):
                raise RunnerError(f"测试缓存包含链接或 junction，拒绝复制: {child}")
            try:
                total += child.stat().st_size
            except OSError as exc:
                raise RunnerError(f"无法读取测试缓存文件大小 {child}: {exc}") from exc
    return total


def _ramdisk_free_bytes() -> int:
    try:
        return shutil.disk_usage(RAMDISK_CACHE_ROOT).free
    except OSError as exc:
        raise RunnerError(f"无法读取 Z: RAM disk 可用空间: {exc}") from exc


def _warn_if_ramdisk_low(free_bytes: int, previous_level: int) -> int:
    level = 0
    if free_bytes < RAMDISK_WARN_FREE_BYTES:
        level = 1
    if free_bytes < RAMDISK_URGENT_FREE_BYTES:
        level = 2
    if level > previous_level:
        label = "紧急" if level == 2 else "提醒"
        warn(
            f"{label}：Z: 剩余空间已降至 {free_bytes / (1024 * 1024):.1f} MiB。"
            "请尽快结束本轮测试并由用户清理 RAM disk；脚本不会删除存档或日志。"
        )
    return max(level, previous_level)


def _write_cache_layout(path: Path, layout: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            json.dump(dict(layout), handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
        temporary = None
    except OSError as exc:
        raise RunnerError(f"无法写入 RAM disk cache 布局记录 {path}: {exc}") from exc
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def _read_cache_layout(path: Path) -> dict[str, object] | None:
    if not path.is_file():
        return None
    try:
        layout = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RunnerError(
            f"RAM disk cache 布局记录不可读: {path}；为避免选错或覆盖存档，停止启动。"
        ) from exc
    if not isinstance(layout, dict):
        raise RunnerError(
            f"RAM disk cache 布局记录格式错误: {path}；为避免选错或覆盖存档，停止启动。"
        )
    return layout


def initialize_ramdisk_caches(settings: Settings) -> None:
    """Use stable Z: cache paths and copy the old workspace caches once, safely."""

    requested: dict[str, tuple[Path, Path]] = {}
    if settings.server_cache_is_default:
        requested["server"] = (
            settings.server_cache,
            settings.run_bat.parent / "runtime" / "server",
        )
    if settings.client_cache_is_default:
        requested["client"] = (
            settings.client_cache,
            settings.run_bat.parent / "runtime" / "client",
        )
    if not requested:
        return

    if not Path("Z:/").is_dir():
        raise RunnerError(
            "默认测试 cache 需要 Z: RAM disk，但当前找不到 Z:。"
            "可恢复 RAM disk 后重试，或通过 --server-cache/--client-cache 显式指定其他目录。"
        )

    try:
        RAMDISK_CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise RunnerError(f"无法建立 Z: 测试 cache 根目录 {RAMDISK_CACHE_ROOT}: {exc}") from exc
    marker_path = settings.run_bat.parent / "runtime" / CACHE_LAYOUT_FILENAME
    marker = _read_cache_layout(marker_path)
    expected_root = str(RAMDISK_CACHE_ROOT.resolve())
    expected_caches = {
        role: str(destination.resolve())
        for role, (destination, _source) in requested.items()
    }
    new_roles = dict(requested)
    layout: dict[str, object] | None = None

    if marker is not None:
        if marker.get("version") != 1 or marker.get("root") != expected_root:
            raise RunnerError(
                f"RAM disk cache 布局记录与当前路径不匹配: {marker_path}；"
                "没有修改任何 cache，请人工确认后再运行。"
            )
        if marker.get("status") != "complete":
            raise RunnerError(
                f"上次 RAM disk cache 初始化未完成: {marker_path}。"
                "工作区原始 cache 保留；请先检查 Z: 上的部分副本，不会自动合并或覆盖。"
            )
        recorded = marker.get("caches")
        if not isinstance(recorded, dict):
            raise RunnerError(f"RAM disk cache 布局缺少路径记录: {marker_path}")
        for role, (destination, _source) in requested.items():
            if role not in recorded:
                continue
            if recorded[role] != str(destination.resolve()):
                raise RunnerError(
                    f"RAM disk {role} cache 路径与已有布局记录不一致: {marker_path}。"
                    "没有修改任何存档。"
                )
            if not destination.is_dir():
                raise RunnerError(
                    f"已登记的 Z: {role} cache 不存在: {destination}。"
                    "RAM disk 可能在重启后丢失内容；不会用可能过期的工作区副本自动重建。"
                )
            _cache_tree_size(destination)
        log(f"使用已登记的 Z: 测试 cache: {RAMDISK_CACHE_ROOT}")
        free_bytes = _ramdisk_free_bytes()
        if free_bytes < 128 * 1024 * 1024:
            raise RunnerError(
                f"Z: 剩余空间不足 128 MiB（当前 {free_bytes / (1024 * 1024):.1f} MiB）；"
                "请先由用户清理 RAM disk 后再启动。脚本没有删除任何内容。"
            )
        new_roles = {
            role: entry for role, entry in requested.items() if role not in recorded
        }
        if not new_roles:
            return

        layout = dict(marker)
        merged_caches = dict(recorded)
        merged_caches.update(
            {
                role: str(destination.resolve())
                for role, (destination, _source) in new_roles.items()
            }
        )
        layout["caches"] = merged_caches
        merged_sources = dict(marker.get("sources", {}))
        merged_sources.update(
            {role: str(source.resolve()) for role, (_destination, source) in new_roles.items()}
        )
        layout["sources"] = merged_sources
        layout["status"] = "initializing"

    source_sizes: dict[str, int] = {}
    estimated_copy_bytes = 0
    for role, (destination, source) in new_roles.items():
        if _is_reparse_point(destination):
            raise RunnerError(
                f"Z: 目标 cache 是链接或 junction，拒绝接管: {destination}"
            )
        if destination.exists() and not destination.is_dir():
            raise RunnerError(f"Z: 目标 cache 不是目录: {destination}")
        if destination.exists() and source.exists():
            raise RunnerError(
                f"Z: {role} cache 与工作区旧 cache 同时存在，无法确定哪份存档较新: "
                f"{destination}；{source}。没有覆盖或合并任何文件。"
            )
        if not destination.exists() and source.exists():
            source_sizes[role] = _cache_tree_size(source)
            estimated_copy_bytes += source_sizes[role]

    free_bytes = _ramdisk_free_bytes()
    reserve_bytes = 128 * 1024 * 1024
    if free_bytes < estimated_copy_bytes + reserve_bytes:
        raise RunnerError(
            "Z: 空间不足以安全复制首次测试 cache："
            f"需要约 {(estimated_copy_bytes + reserve_bytes) / (1024 * 1024):.1f} MiB "
            f"（含 128 MiB 保留空间），当前可用 {free_bytes / (1024 * 1024):.1f} MiB。"
            "请清理 RAM disk 后重试。"
        )

    if layout is None:
        layout = {
            "version": 1,
            "status": "initializing",
            "root": expected_root,
            "caches": expected_caches,
            "sources": {
                role: str(source.resolve()) for role, (_destination, source) in requested.items()
            },
        }
    _write_cache_layout(marker_path, layout)
    for role, (destination, source) in new_roles.items():
        if destination.exists():
            _cache_tree_size(destination)
            log(f"采用已有且无工作区副本的 Z: {role} cache: {destination}")
            continue
        if source.exists():
            byte_count = source_sizes[role]
            log(
                f"首次迁移 {role} cache（{byte_count / (1024 * 1024):.1f} MiB）: "
                f"{source} -> {destination}；原工作区副本保留不动"
            )
            try:
                shutil.copytree(source, destination)
            except OSError as exc:
                raise RunnerError(
                    f"复制 {role} cache 到 Z: 失败: {exc}。"
                    "工作区原 cache 未修改；布局记录保留为 initializing，"
                    "不会自动覆盖/合并部分副本。"
                ) from exc
        else:
            destination.mkdir(parents=True, exist_ok=False)
            log(f"创建空的 Z: {role} cache: {destination}")

    layout["status"] = "complete"
    _write_cache_layout(marker_path, layout)
    free_after_copy = _ramdisk_free_bytes()
    log(
        f"Z: 测试 cache 已就绪；剩余 {free_after_copy / (1024 * 1024):.1f} MiB。"
        "测试结束后不会自动清理或复制回工作区。"
    )


def prepare(settings: Settings) -> Path:
    validate_mod_source(settings.mod_source)
    buildcraft_source = resolve_buildcraft_source(settings.buildcraft_source)
    require_file(settings.run_bat, "testserver\\run.bat")
    start_bat = settings.run_bat.parent / "steamcmd" / "380870" / "StartServer64 - test.bat"
    require_file(start_bat, "服务器启动批处理")
    validate_port(settings.port, "DefaultPort")
    validate_port(settings.udp_port, "UDPPort")
    if settings.port == settings.udp_port:
        raise RunnerError("DefaultPort 与 UDPPort 必须不同")
    if not settings.dry_run:
        validate_ports(settings.port, settings.udp_port)

    log(f"项目根目录: {settings.project_root}")
    log(f"本地模组源: {settings.mod_source}")
    log(f"BuildCraft 本地源包（Workshop {BUILDCRAFT_WORKSHOP_ID}）: {buildcraft_source}")
    ensure_directory(settings.server_cache, "独立服务器缓存", settings.dry_run)
    ensure_directory(settings.client_cache, "客户端缓存", settings.dry_run)
    if settings.server_cache.resolve() == settings.client_cache.resolve():
        raise RunnerError("服务器缓存与客户端缓存必须是不同目录")

    stage_mod(settings.mod_source, settings.server_cache, "服务器", settings.dry_run)
    stage_mod(
        buildcraft_source,
        settings.server_cache,
        "服务器 BuildCraft",
        settings.dry_run,
        BUILDCRAFT_MOD_ID,
    )
    if not settings.no_client:
        stage_mod(settings.mod_source, settings.client_cache, "客户端", settings.dry_run)
        stage_mod(
            buildcraft_source,
            settings.client_cache,
            "客户端 BuildCraft",
            settings.dry_run,
            BUILDCRAFT_MOD_ID,
        )

    config_path = settings.server_cache / "Server" / f"{SERVER_NAME}.ini"
    update_ini(config_path, server_options(settings.port, settings.udp_port), settings.dry_run)
    sandbox_path = settings.server_cache / "Server" / f"{SERVER_NAME}_SandboxVars.lua"
    update_sandbox_vars(sandbox_path, settings.dry_run)
    return settings.server_cache / "server-console.txt"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="准备并启动 Railroader RV 的独立服务器与常规 Project Zomboid 客户端。"
    )
    parser.add_argument("--project-root", type=Path, help="项目根目录（默认按脚本位置发现）")
    parser.add_argument("--run-bat", type=Path, help="服务器入口 run.bat")
    parser.add_argument("--mod-source", type=Path, help="本地 RailroaderRVTest 模组目录")
    parser.add_argument(
        "--buildcraft-source",
        "--buildcraft-mod-source",
        dest="buildcraft_source",
        type=Path,
        help=(
            "BuildCraft package root 或 Workshop item 目录；默认从 Steam 库发现 "
            f"Workshop {BUILDCRAFT_WORKSHOP_ID}"
        ),
    )
    parser.add_argument(
        "--server-cache",
        type=Path,
        help=f"服务器完整用户缓存目录（默认 {RAMDISK_CACHE_ROOT / 'server'}）",
    )
    parser.add_argument(
        "--client-cache",
        type=Path,
        help=f"客户端完整用户缓存目录（默认 {RAMDISK_CACHE_ROOT / 'client'}）",
    )
    parser.add_argument("--client-exe", type=Path, help="ProjectZomboid64.exe 的路径")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="服务器 DefaultPort")
    parser.add_argument("--udp-port", type=int, default=DEFAULT_UDP_PORT, help="服务器 UDPPort")
    parser.add_argument(
        "--startup-timeout",
        type=float,
        default=180.0,
        help="等待服务器启动标记的秒数（默认 180）",
    )
    parser.add_argument("--dry-run", action="store_true", help="只检查并打印计划，不写文件或启动进程")
    parser.add_argument(
        "--prepare-only",
        action="store_true",
        help="准备模组与服务器配置后退出，不启动服务器/客户端",
    )
    parser.add_argument(
        "--no-client",
        action="store_true",
        help="只准备并启动服务器（仍不会自动连接游戏）",
    )
    parser.add_argument(
        "--smoke-test",
        action="store_true",
        help="仅运行短时间 Windows 批处理生命周期 smoke，不启动真实服务器/客户端",
    )
    return parser


def make_settings(args: argparse.Namespace) -> Settings:
    script_project_root = Path(__file__).resolve().parents[1]
    project_root = resolve_path(args.project_root, Path.cwd()) or script_project_root
    run_bat = resolve_path(args.run_bat, project_root) or (project_root / "testserver" / "run.bat")
    mod_source = resolve_path(args.mod_source, project_root) or (
        project_root / "RailroaderRVTest" / "contents" / "mods" / MOD_ID
    )
    buildcraft_source = resolve_path(args.buildcraft_source, project_root)
    # Accept the version directory mentioned in the project README while
    # still staging the package root expected by PZ's mod scanner.
    if (
        mod_source.name == "42"
        and mod_source.parent.name == MOD_ID
        and (mod_source / "mod.info").is_file()
    ):
        mod_source = mod_source.parent
    server_cache = resolve_path(args.server_cache, project_root)
    client_cache = resolve_path(args.client_cache, project_root)
    server_cache_is_default = server_cache is None
    client_cache_is_default = client_cache is None
    server_cache = server_cache or (RAMDISK_CACHE_ROOT / "server")
    client_cache = client_cache or (RAMDISK_CACHE_ROOT / "client")
    client_exe = resolve_path(args.client_exe, Path.cwd())
    if client_exe is None and not args.no_client:
        client_exe = discover_client(None)
    if args.startup_timeout <= 0:
        raise RunnerError("--startup-timeout 必须大于 0")
    return Settings(
        project_root=project_root,
        run_bat=run_bat,
        mod_source=mod_source,
        buildcraft_source=buildcraft_source,
        server_cache=server_cache,
        client_cache=client_cache,
        server_cache_is_default=server_cache_is_default,
        client_cache_is_default=client_cache_is_default,
        client_exe=client_exe,
        port=args.port,
        udp_port=args.udp_port,
        startup_timeout=args.startup_timeout,
        dry_run=args.dry_run,
        prepare_only=args.prepare_only,
        no_client=args.no_client,
    )


def run(settings: Settings) -> int:
    if os.name != "nt" and not (settings.dry_run or settings.prepare_only):
        raise RunnerError("此一键启动器只支持 Windows；可在其他平台使用 --dry-run")
    if not settings.no_client and settings.client_exe is None:
        message = (
            "找不到 ProjectZomboid64.exe。请用 --client-exe 指定路径，"
            "或先安装 Steam 版 Project Zomboid。"
        )
        if settings.dry_run or settings.prepare_only:
            warn(message)
        else:
            raise RunnerError(message)
    elif settings.client_exe is not None and not settings.client_exe.is_file():
        if settings.dry_run or settings.prepare_only:
            warn(f"客户端路径当前不存在（实际启动前会失败）: {settings.client_exe}")
        else:
            raise RunnerError(f"客户端路径不存在: {settings.client_exe}")

    if settings.dry_run:
        log("开始准备隔离测试环境")
        server_log = prepare(settings)
        log("[dry-run] 不写入模组/配置，也不启动任何进程")
        log(
            "[dry-run] 将运行: "
            f"{subprocess.list2cmdline(build_server_command(settings.run_bat, settings.server_cache))}"
        )
        if not settings.no_client and settings.client_exe is not None:
            log(f"[dry-run] 将启动客户端: {settings.client_exe}")
        return 0
    if settings.prepare_only:
        initialize_ramdisk_caches(settings)
        log("开始准备隔离测试环境")
        prepare(settings)
        log("准备完成（--prepare-only），未启动服务器或客户端")
        return 0

    runtime_root = settings.run_bat.parent / "runtime"
    instance_state_path = runtime_root / INSTANCE_STATE_FILENAME
    instance_lock = _acquire_instance_lock(runtime_root, settings.run_bat)
    server_process: subprocess.Popen[bytes] | None = None
    instance_state: dict[str, object] | None = None
    try:
        _cleanup_previous_instance(
            instance_state_path,
            settings.run_bat,
            settings.server_cache,
        )
        log("开始准备隔离测试环境")
        initialize_ramdisk_caches(settings)
        server_log = prepare(settings)
        server_process = launch_server(settings.run_bat, settings.server_cache)
        instance_state = {
            "version": 1,
            "run_bat": str(settings.run_bat.resolve()),
            "server_cache": str(settings.server_cache.resolve()),
            "client_exe": str(settings.client_exe.resolve())
            if settings.client_exe is not None
            else "",
            "client_cache": str(settings.client_cache.resolve()),
            "server_pid": server_process.pid,
            "client_pid": None,
        }
        _write_instance_state(instance_state_path, instance_state)
        wait_for_server(
            server_process,
            server_log,
            settings.startup_timeout,
            settings.port,
            settings.udp_port,
        )
        if not settings.no_client:
            assert settings.client_exe is not None
            instance_state["client_pid"] = launch_client(
                settings.client_exe,
                settings.client_cache,
            )
            _write_instance_state(instance_state_path, instance_state)
        log("服务器已就绪；客户端连接、登录和游戏内操作由人工完成。")
        log(f"多人连接信息：IP=127.0.0.1  Port={settings.port}  服务器密码留空")
        log(
            "管理员登录凭据（仅限本地私有测试）："
            f"用户名={TEST_ADMIN_USERNAME}  密码={TEST_ADMIN_PASSWORD}"
        )
        log("请在服务器窗口输入 quit（或按服务器自身方式）结束服务器。")

        last_space_check = time.monotonic()
        ramdisk_warning_level = 0
        while server_process.poll() is None:
            time.sleep(1.0)
            now = time.monotonic()
            if (
                (settings.server_cache_is_default or settings.client_cache_is_default)
                and now - last_space_check >= 15.0
            ):
                ramdisk_warning_level = _warn_if_ramdisk_low(
                    _ramdisk_free_bytes(),
                    ramdisk_warning_level,
                )
                last_space_check = now
        code = server_process.returncode or 0
        log(f"服务器已退出，exit code={code}")
        return 0 if code == 0 else 1
    except KeyboardInterrupt:
        warn("脚本收到 Ctrl+C；不会尝试操作游戏客户端。请在服务器窗口确认是否结束服务器。")
        return 130
    except RunnerError:
        if server_process is not None and server_process.poll() is None:
            warn("启动流程失败，正在停止本次启动的服务器进程")
            stop_process_tree(server_process)
        if instance_state is not None:
            _cleanup_recorded_instance(instance_state)
            try:
                instance_state_path.unlink()
            except OSError:
                pass
        raise
    finally:
        _release_instance_lock(runtime_root, instance_lock)


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.smoke_test:
            run_subprocess_smoke()
            return 0
        return run(make_settings(args))
    except RunnerError as exc:
        print(f"[RailroaderRVTest][ERROR] {exc}", file=sys.stderr, flush=True)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
