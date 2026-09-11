# client/RailroaderRV

RV_RailroaderContextMenu.lua 负责识别官方 rr_loco、提交进入/退出意图、接收服务端
座位/车外传送，并在官方动物菜单与世界菜单 hook 上替换机车入口；RV_ContextMenu.lua
保留生成事务的客户端定向传送与房间 guard。进入请求只提交 locoId 提示，退出请求为空；
服务端重新验证机车、玩家座位、速度、范围和所有坐标。房车内部菜单只根据固定 100x100
坐标区间显示退出，不依赖 room/id。

世界菜单优先使用 `RR.Ride.nearestBoardable` 的 2.1 活跃机车记录，并保留点击动物路径；若
官方 `RR_AnimalMenuFilter` 尚未安装，才对 `AnimalContextMenu.doMenu` 做一次回退包装，同时
保留官方 re-rail 入口。

结构：`RV_RailroaderContextMenu.lua` 接管 Railroader 2.1 的机车世界/动物右键入口；
`RV_ContextMenu.lua` 仅保留生成事务的客户端定向传送与房间 guard。两者共同处理服务端
定向的安全撤离命令。

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

服务端选定的 `RVTeleport`/`FinalRelocate` 落地后，客户端可调用官方
`IsoMovingObject:setCurrentSquareFromPosition(float x, float y, float z)` 三参重载刷新
玩家的 `IsoMovingObject.current` 缓存。反编译基线显示该重载只读取
`cell.getGridSquare(x,y,z)` 并调用 `setCurrent(current)`；`teleportTo` 本身只写坐标。
目标方格尚未流式加载时允许缓存暂为空，不能凭客户端坐标拒绝服务器传送。

`RVTeleport` 还登记一个有界的跨 tick current-square refresh：如果传送回调发生在目标
房间方格仍在流式同步的窗口内，会继续对同一服务端坐标调用该官方重载，直到 current
命中目标方格、玩家死亡/离线或达到超时；这只修客户端缓存，不改变服务端位置、房间
关系或传送权限。客户端不得给 Java `IsoPlayer` userdata 写入
`dirtyRecalcGridStack` 等字段（Kahlua 会报 `attempted index of non-table`）。屋顶视觉
修复以服务端在房车西北墙角西侧临时添加并删除木地板的事务为事实源，客户端刷新不替代
该事务。

房车内部退出入口同时注册在 `OnPreFillWorldObjectContextMenu` 和
`OnFillWorldObjectContextMenu`：官方后一个事件在右键目标没有可抓取世界对象时会被
`fetch.c == 0` 短路，而 RV 内通常只右键普通地板。前一个事件只依据玩家是否位于
固定 100x100 RV 区块添加 `Exit RV`，不依赖 locomotive 实体、room 或 ModData 已经
在客户端恢复；服务器收到退出意图后再按持久化区块映射反查机车，映射损坏时走默认
马尔德劳退出点。

Railroader 2.1 的 `RVTeleport` 处理还必须经过 `RR.Ride`：进入和生成失败先调用官方
`dismount(true)`，让 `RR_MPClient` 的 `_dismountAt` stale-seat grace 先于坐标写入；生成失败
仅设置官方 `_boardPending` 本地门闩，等待服务端恢复座位快照。退出到 driver/passenger 不在
MP 客户端伪造 `rider/seat`，而是等待 `RR_MPClient` 的正式 snapshot 调用 `mountRecord`；
只有 SP 没有 snapshot 时，才在传送完成后调用同一官方 `mountRecord`。菜单距离使用
`RR.Ride.MOUNT_REACH`/`nearestBoardable` 的 `RR.Body.hullDistance` 契约，不再使用中心半径。

生成清场的首次 `Relocate` 仅在服务端 payload 带
`railroaderTransition=true` 时调用 `prepareGenerationStaging`，在 staging
`teleportTo` 前执行一次 `prepareRideTransition`；普通技术 `Generate` 不带该标记。
Railroader 生成 token 会贯穿 staging 与 `FinalRelocate`，重复回调不重复
`dismount(true)`，避免官方 `placePlayerBeside` 覆盖最终服务端坐标。退出到
driver/passenger 时，即使本地 `RR.Ride.current` 已经为空，也要在目标官方 record
上设置 `_boardPending`；beside 退出不设置该门闩。
普通技术 `FinalRelocate` 没有 `railroaderTransition` marker 时，客户端 adapter 必须严格
no-op，不得因玩家当前恰好乘坐机车而调用 `prepareRideTransition`；同 token 的已存在
staging transition 才是唯一允许的无 marker 重试例外。
