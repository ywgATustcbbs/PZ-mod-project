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


class FlatcarVisualRecordTests(unittest.TestCase):
    def test_bare_locomotive_record_without_units_is_ignored(self) -> None:
        source = CLIENT_FILE.read_text(encoding="utf-8")
        duplicate_locations = lua_block(
            source,
            "local function duplicateRecordLocations()",
            "local function visitRecord",
        )
        visit_record = lua_block(
            source,
            "local function visitRecord(record, seen, duplicates)",
            "local function syncRecords()",
        )
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(
            r"""
            records = { { id = 1 } }
            duplicateRecords = {}
            Cargo = { debug = function() end }
            function recordIdentity(record)
                return "record#" .. tostring(record.id)
            end
            """
            + duplicate_locations
            + visit_record
            + r"""
            duplicates = duplicateRecordLocations()
            visitRecord(records[1], {}, duplicates)
            assert(next(duplicates) == nil)
            """
        )


if __name__ == "__main__":
    unittest.main()
