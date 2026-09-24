# Test server scripts

- `run_test.py` stages the local RV and BuildCraft mods, prepares the isolated multiplayer profile, and launches the visible server console plus the regular game client.
- The default full client and server cache roots are `Z:\RailroaderRVTestCache\client` and `Z:\RailroaderRVTestCache\server`. Each process receives its cache through `-cachedir`; saves, logs, settings, and staged mods therefore stay together on the RAM disk.
- On first use, the launcher copies the matching `testserver/runtime/{client,server}` cache only when the Z: destination does not exist. The workspace source remains untouched. A layout marker under `testserver/runtime/` records the stable destination; ambiguous existing caches or a missing previously registered Z: cache stop startup instead of merging or recreating from a potentially stale copy.
- The Z: cache and its saves/logs are not copied back or automatically deleted. They survive launcher runs while the RAM disk contents survive; a volatile RAM disk reset can lose them. Users manage Z: capacity and preserve any needed data before clearing it.
- Passing `--client-cache` or `--server-cache` explicitly overrides that process's default Z: path. The one-click runtime test remains `python testserver/run_test.py` from the project root; do not start a separate server or client for runtime verification.
