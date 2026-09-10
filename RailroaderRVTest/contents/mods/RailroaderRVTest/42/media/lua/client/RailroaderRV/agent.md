# client/RailroaderRV

结构：`RV_ContextMenu.lua` 注册 RV 世界右键菜单、发送生成意图，并处理服务端定向的
安全撤离命令。

职责：客户端表现与请求；生成/清理请求始终为空 payload，生成 anchor 与传送坐标由服务端
固定选择。当前远距清场中，客户端只接受服务端给匹配本地 online ID 的、位于旧/新
footprint 外的 `Relocate` staging 目标，完成本地 `teleportTo` 后回传无坐标 token；不得在
传送前要求目标 `getGridSquare` 存在。位置、权限、到达复核、传送后加载等待和世界变更仍
由服务端决定。

`RefreshRoomOwnership` 是服务端向所有已连接客户端广播的旧/新 footprint guard，不按请求
玩家过滤。完整 7x41 墙矩形已经包含 6x40 室内，扫描不再重复追加 room loop。客户端只在
方格仍返回 `IsoRoom`、但该方格的 `RoomDef` 已为 `nil` 时执行 `setRoomID(-1)`；最终
`FinalRelocate` 处理器会在本地 `teleportTo` 前同步执行同一 guard 扫描；有效的新房或旧房
room ID 不得被修改，也不得调用 `setRoom(nil)`、`ResetIsoWorldRegion` 或额外重算。由于没有
公开的 region rebuild 完成事件，多个 generation guard 可并存，并以最短监测期、连续稳定
tick 和硬超时跨 tick 运行后自动清理。
