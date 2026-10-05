# RailroaderRV 1.0 client Lua

- `GUI/` owns client menus, input hooks, local presentation, and intent-only requests to the server.
- Client command handlers consume server-selected identities, bounds, snapshots, and acknowledgements using the current interface. Client state is presentation/handshake state; server validation remains authoritative for permissions and world changes. Do not add repeated schema checks or interface compatibility/guard/migration paths between modules; let interface errors surface as normal game exceptions.
- `GUI/RV_BoundaryClient.lua` applies identity-scoped corrections sent by the server. `GUI/RV_UtilityClient.lua` handles local utility visibility and connection/display state.
- `GUI/RV_RecipeFurnitureInputPresentation.lua` supplies furniture previews for the recycling recipes that accept Moveable inputs; it does not alter recipe input identity or server authority.
- `GUI/RV_ContextMenu_RoomOwnership.lua` checks each local player's current square every tick. It schedules a full bounds scan only after a local stale-reference/error hit, a relevant object event, or the initial refresh transaction. Persistent local API errors are edge-triggered until a successful check, and object-event bursts are coalesced by a cooldown with bounded delayed rechecks. A full scan reports incomplete if any base structure square or captured roof-object host is not loaded.
- `GUI/RV_ContextMenu_Relocation.lua` waits for the server-selected destination square to load, applies the relocation, and acknowledges the final phase only after checking the resulting player position. The server owns the destination and transaction phase.
- `GUI/RV_BoundaryClient.lua` keeps correction state by player identity and clears it on disconnect.
