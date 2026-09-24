# RailroaderRV server Lua

- `RV_Server.lua` composes the server event handlers and generation transaction modules.
- `RV_RailroaderServer*.lua` handles server-authoritative Railroader entry, exit, mapping, and transition validation.
- `RV_BoundaryServer*.lua` implements bitmap-scoped boundary tracking, transition leases, sweeping, and object cleanup.
- `RV_Server_*.lua`, `RV_ServerSchema.lua`, and `RV_ServerWorld.lua` provide generation, persistence validation, and world operations; `RV_Utility*.lua` and `RV_RoofRepair.lua` provide utility and repair services.
- Keep world changes authoritative on the server, accept client intent only, and reject persisted data that does not match the current declared schema.
