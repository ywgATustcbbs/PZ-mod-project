# client/RailroaderRV

RV_RailroaderContextMenu.lua 负责识别官方 rr_loco、提交进入/退出意图、接收服务端
座位/车外传送，并在官方动物菜单与世界菜单 hook 上替换机车入口；RV_ContextMenu.lua
保留生成事务的客户端定向传送与房间 guard。进入请求只提交 locoId 提示，退出请求为空；
服务端重新验证机车、玩家座位、速度、范围和所有坐标。房车内部菜单只根据固定 100x100×Z
坐标区间显示退出，不依赖 room/id。

世界菜单优先使用 `RR.Ride.nearestBoardable` 的 2.1 活跃机车记录；点击 `worldObjects` 时
先用官方 `instanceof(object, "IsoAnimal")` 确认对象类别，再读取 `getAnimalType`，避免把
普通世界对象送入动物 API；并保留点击动物路径。若
官方 `RR_AnimalMenuFilter` 尚未安装，才对 `AnimalContextMenu.doMenu` 做一次回退包装，同时
保留官方 re-rail 入口。

结构：`RV_RailroaderContextMenu.lua` 接管 Railroader 2.1 的机车世界/动物右键入口；
`RV_ContextMenu.lua` 仅保留生成事务的客户端定向传送与房间 guard。两者共同处理服务端
定向的安全撤离命令。

职责：客户端表现与请求；生成/清理请求始终为空 payload，生成 anchor 与传送坐标由服务端
固定选择。首次 generation staging 只接受服务端按 current-schema managed scope 中心计算的
`z=-15` 目标，并在严格 `generationTransition/generationPhase` 标记下使用本地语义常量“正在生成房车”；
B42 渲染器对非 ASCII halo 可能显示替换字符，所以实际 `setHaloNote` 使用本地 ASCII
`"Generating RV"`，临时 pending 期间按固定 tick 刷新该本地提示，收到结束/失败或超时后停止刷新。
当前 roof-refresh 只接受服务端给匹配本地 online ID 的中心减 `(18000,0,15)` 远点，完成本地
`teleportTo` 后回传无坐标 token；不得在
传送前要求目标 `getGridSquare` 存在。位置、权限、到达复核、传送后加载等待和世界变更仍
由服务端决定。

`RV_BoundaryClient.lua` 接收服务端的 `rvId/generation/bitmapVersion` 快照，在当前 RV
100×100×Z scope 内用 bitmap 预测 active→inactive 的 swept transition，并同步修正本地
position/next/last 状态；没有快照或当前位置已经在 scope 外时保持 inert。它不创建碰撞体、
不删除对象、不接受客户端坐标作为权限依据；Lua 被关闭、快照过期或预测失败时，服务端
`RV_BoundaryServer` 的服务端权威校验与无状态哨兵仍是唯一安全边界。
服务端在进出 RV、generation swap 或清理映射时发送 `RVBitmapClear`，客户端只清除匹配的
旧反馈快照，避免退出后残留预测在非当前 RV 中生效；该消息不改变服务端关系或权限。

`RefreshRoomOwnership` 在 generation swap 时由服务端向所有已连接客户端广播旧/新 footprint
guard；已有 RV entry 或 reconnect/presence 则由服务端用同一命令定向对应客户端。完整
7x41 墙矩形已经包含 6x40 室内，扫描不再重复追加 room loop。客户端只在
方格仍返回 `IsoRoom`、但该方格的 `RoomDef` 已为 `nil` 时执行 `setRoomID(-1)`；最终
`FinalRelocate` 处理器会在本地 `teleportTo` 后通过官方 `setX/setY/setZ` 与
`setLastX/setLastY` 恢复服务端选定的半格中心，再执行同一 guard 扫描；有效的新房或旧房
room ID 不得被修改，也不得调用 `setRoom(nil)`、`ResetIsoWorldRegion` 或额外重算。由于没有
公开的 region rebuild 完成事件，generation guard 在初始稳定尾部后不会释放，而是作为当前
`rvId:generation:bitmapVersion` 的持续 footprint monitor 每个 `OnTick` 扫描。`OnTick` 位于
`IsoRegions.update` 之后、下一次 `IsoPlayer.updateInternal2/updateEmitter` 之前；因此墙/地板
异步移除导致的后续 `IsoRoom.def=nil` 也会在 FMOD 参数读取前被清除。新的当前 generation
命令会替换旧 identity；monitor 只使用服务端发送的当前 schema bounds，不推断或扩大范围。

服务端选定的 `RVTeleport`/`FinalRelocate` 落地后，客户端可调用官方
`IsoMovingObject:setCurrentSquareFromPosition(float x, float y, float z)` 三参重载刷新
玩家的 `IsoMovingObject.current` 缓存。反编译基线显示该重载只读取
`cell.getGridSquare(x,y,z)` 并调用 `setCurrent(current)`；`teleportTo` 本身只写坐标。
目标方格尚未流式加载时允许缓存暂为空，不能凭客户端坐标拒绝服务器传送。`FinalRelocate`
只有 guard、room scan 和 teleport 后实际坐标均验证成功才发送独立 token-only
`FinalRelocateAck`；失败不发送坐标或世界状态，服务端超时负责回滚。

`RVTeleport` 还登记一个有界的跨 tick current-square refresh：如果传送回调发生在目标
房间方格仍在流式同步的窗口内，会继续对同一服务端坐标调用该官方重载，直到 current
命中目标方格、玩家死亡/离线或达到超时；这只修客户端缓存，不改变服务端位置、房间
关系或传送权限。客户端不得给 Java `IsoPlayer` userdata 写入
`dirtyRecalcGridStack` 等字段（Kahlua 会报 `attempted index of non-table`）。屋顶视觉
修复以服务端在房车西北墙角西侧临时添加并删除木地板的事务为事实源，客户端刷新不替代
该事务。拆墙后的第一阶段 roof-refresh 复用同一 `Relocate`/严格 token-only `RelocateAck`：
服务端枚举 RV scope 内全部玩家，将每个客户端送到当前 bitmap 中心减去 `(18000,0,15)` 的远端
点，客户端只执行服务端坐标并回执 token；临时阶段只校验网络 marker，并以本地 ASCII
`setHaloNote("Refreshing room",255,255,255,1500)`
显示提示，避免网络非 ASCII 字符串泄漏到渲染器。客户端不提交目标坐标、回程位置、加载状态或地板动作；
远端合法坐标可能暂时没有客户端 `GridSquare`，此时客户端只在有界 tick 后按本地传送坐标回执，
服务端仍必须重新读取权威玩家坐标、身份和当前 schema 才能推进阶段；
服务端等待所有成员完成远端跨 tick 后逐人回传，并复用进入 RV 的 repair/geometry 路径。失败时
服务端负责最终逐人回传与持续恢复；任何成员处于 `z=-15` 时不得清理 return context/lease。

房车内部退出入口同时注册在 `OnPreFillWorldObjectContextMenu` 和
`OnFillWorldObjectContextMenu`：官方后一个事件在右键目标没有可抓取世界对象时会被
`fetch.c == 0` 短路，而 RV 内通常只右键普通地板。前一个事件只依据玩家是否位于
固定 100x100 RV 区块添加 `Exit RV`，不依赖 locomotive 实体、room 或 ModData 已经
在客户端恢复；服务器收到退出意图后再按当前 schema 持久化区块映射反查机车；mapping
不完整时拒绝操作，提示删除测试存档并重建，且不执行默认全局退出传送。

`RVTeleport` 失败返回 `SAVE_REBUILD_REQUIRED` 时，客户端只匹配本地稳定原因码，并用 ASCII
`setHaloNote("Delete this test save and rebuild it",...)` 明确提示删除该测试存档并重建；不得把
任意网络 reason 正文渲染为 UI，也不得对旧 schema 传送、迁移或兼容。

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

客户端不得实现任何旧存档/旧字段兼容或转换逻辑；缺少当前 bitmap identity 时保持 inert，
由服务端 authoritative gate 负责拒绝并通知用户删档重建。
