# RailroaderRV client Lua

- `RV_ContextMenu*.lua` and `RV_RailroaderContextMenu.lua` own client menus, input hooks, local presentation, and intent-only requests to the server.
- Client command handlers consume server-selected identities, bounds, snapshots, and acknowledgements. Client prediction and retry state is temporary presentation/handshake state; server validation remains authoritative for permissions and world changes.
- `RV_BoundaryClient.lua` applies local movement feedback from server snapshots. `RV_UtilityClient.lua` handles local utility visibility and connection/display state.
- `RV_ContextMenu_RoomOwnership.lua` uses server-provided RV bounds to repair only stale local room references and verify the reset; it does not infer or submit trusted geometry.
- Keep iteration compatible with the game Lua runtime. `RV_BoundaryClient.lua` uses `pairs()` for table presence checks because the tested Kahlua environment does not provide the global `next` function.
