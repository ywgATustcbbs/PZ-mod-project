from __future__ import annotations

import unittest
from pathlib import Path

from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "contents/mods/RailroaderRV/42/media/lua"


def make_lua() -> LuaRuntime:
    lua = LuaRuntime(unpack_returned_tuples=True)
    shared = (MOD / "shared").as_posix()
    client = (MOD / "client").as_posix()
    server = (MOD / "server").as_posix()
    lua.execute(
        "package.path = "
        + repr(f"{shared}/?.lua;{client}/?.lua;{server}/?.lua;")
        + " .. package.path"
    )
    return lua


class RVClientDebugTests(unittest.TestCase):
    def test_client_report_sends_only_message_and_returns_transport_result(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            sentCommands = {}
            function sendClientCommand(player, module, command, args)
                sentCommands[#sentCommands + 1] = {
                    player = player, module = module,
                    command = command, args = args,
                }
                return "transport-result"
            end
            reporter = require("RailroaderRV/GUI/RV_ClientDebug")
            player = {}
            result = reporter.report(player, "roof snapshot accepted")
            samePlayer = sentCommands[1].player == player
            payloadFieldCount = 0
            for _ in pairs(sentCommands[1].args) do
                payloadFieldCount = payloadFieldCount + 1
            end
            """
        )
        command = lua.globals().sentCommands[1]
        self.assertEqual(lua.globals().result, "transport-result")
        self.assertTrue(lua.globals().samePlayer)
        self.assertEqual(command.module, "RailroaderRV")
        self.assertEqual(command.command, "clientDebug")
        self.assertEqual(command.args.message, "roof snapshot accepted")
        self.assertEqual(lua.globals().payloadFieldCount, 1)

    def test_server_logs_actual_player_identity_and_validates_text_payload(self) -> None:
        lua = make_lua()
        lua.execute(
            r"""
            logs = {}
            function print(message) logs[#logs + 1] = message end
            player = {
                getOnlineID = function() return 73 end,
                getUsername = function() return "ActualUser" end,
            }
            Debug = require("RailroaderRV/Core/RV_Server_ClientDebug")
            accepted = Debug.handle(player, {
                message = "snapshot received\nfake log line",
                onlineId = 999, username = "SpoofedUser",
            })
            invalidTable = Debug.handle(player, { message = 42 })
            invalidArgs = Debug.handle(player, "not a table")
            """
        )
        self.assertTrue(lua.globals().accepted)
        self.assertFalse(lua.globals().invalidTable)
        self.assertFalse(lua.globals().invalidArgs)
        self.assertEqual(len(lua.globals().logs), 1)
        log_line = lua.globals().logs[1]
        self.assertIn("[RailroaderRV][RVDEBUG][id=73 user=ActualUser]", log_line)
        self.assertIn("snapshot received fake log line", log_line)
        self.assertNotIn("999", log_line)
        self.assertNotIn("SpoofedUser", log_line)
        self.assertNotIn("\n", log_line)


if __name__ == "__main__":
    unittest.main()
