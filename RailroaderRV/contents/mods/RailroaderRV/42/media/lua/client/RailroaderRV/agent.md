# RailroaderRV 1.0 client Lua

- GUI/ owns context menus, panels, input hooks, local visuals, and requests sent to the server. Clients express intent; they do not choose trusted world coordinates or authoritative object state.
- The server selects operation identities and destinations, checks permissions and current world state, then performs all world changes. Client snapshots and local state are for presentation or a required asynchronous step.
- RV_ContextMenu.lua wires the general menu flow; RV_RailroaderContextMenu.lua adds Railroader unit interactions; RV_UtilityContextMenu.lua and RV_UtilityDashboard.lua handle water and power UI; RV_FlatcarVisualClient.lua renders flatcar cargo and sends load/unload intent.
- Relocation or boarding acknowledgements are sent only for client-side asynchronous actions whose completion the server needs before advancing the transaction.
- Template development is retained as a developer tool. Its menu is hidden while C.ENABLE_TEMPLATE_DEVELOPMENT is false; when enabled, the client also checks UseDebugContextMenu, and the server independently validates that capability.
- Client code assumes the current shared schema and module interfaces. Do not add repeated schema checks, compatibility paths, fallback coordinates, or cross-module interface guards; let contract errors surface as normal game exceptions.
