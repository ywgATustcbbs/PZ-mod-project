# server

结构：`RailroaderRV/` 服务端命令入口与生成事务；其中 `RV_Server.lua` 是 facade/bootstrap
与事件唯一所有者，`RV_ServerUtil.lua`、`RV_ServerWorld.lua`、`RV_ServerSchema.lua`、
`RV_BoundaryServer.lua`、`RV_RoofRepair.lua` 与 `RV_RailroaderServer.lua` 分别承载纯工具、
世界对象原语、当前 schema/加载预检、边界审计、roof-refresh 辅助和 Railroader 适配；
`RV_Server.lua` 前置声明后文的当前 manifest gate，使 generation 清理调用到当前 schema
校验而非未定义全局。

职责：权威校验、固定生成 anchor 与 staging 分离传送；首次 generation staging 严格由当前
layout/bitmap 管理 scope 中心计算为 `(managedOriginX+floor(width/2),
managedOriginY+floor(height/2), -15)`，不再选择房车边界附近的格；roof-refresh 则独立使用
当前 bitmap 中心减去 `(18000,0,15)` 的远点。传送前仅用 `isValidSquare` 预检固定目标及严格
100×100 半开区间坐标；
传送后等待并复核 staging 安全性与完整 base footprint、破坏性清理、程序化建造、
同步、失败回滚；不得在传送前要求远端方格存在，也不得创建未预检地图格。请求玩家在
清场/重建期间留在 staging，不进入任何结构 footprint。清场成功后
才进入完整房间/对象生成；生成成功后、提交 `READY` 前，服务端通过独立
`FinalRelocate` 命令并同步服务端玩家对象，把请求玩家送到 `(20050.5,2050.5,0)`；
客户端 guard/room-scan/实际坐标均成功后只回传严格 token-only `FinalRelocateAck`，服务端重读
current manifest/权威坐标；若 B42 网络 tick 暂时暴露旧位置，服务端最多一次用自身目标坐标
重断言并再次读取，仍不能证明目标则拒绝 ACK，之后才提交 `READY`；缺失 ACK 或 600 tick
超时走原始坐标回滚，
该命令不走初次 `RelocateAck`。B42 服务端按 64×64 cell 和 online chunk-grid width
加载相关区域；不完整 footprint 只返回可重试状态，硬超时在任何清场前取消，禁止以部分加载范围继续。RV 边界
服务仅接受当前玩家映射的 `rvId/generation`，在该 RV 的 100×100×Z scope 内使用 bitmap；scope 外
对玩家和对象均 no-op。客户端只做预测，服务端执行无状态 `z=-15` 哨兵、建造审计和周期清理。
清场、建造或最终传送任一阶段失败都必须沿现有 generation 回滚路径收敛。
进出或 generation 切换先向对应客户端发送匹配当前上一代 key 的 `RVBitmapClear`，再重置 runtime
snapshot/latch；它只撤销客户端预测缓存，不改变持久化 RV↔玩家关系。
bitmap snapshot、dirty action、cleanup cursor、correction、对象标签和持久化
shell edge ledger 均携带 `rvId/generation/bitmapVersion`；对象位于登记的 shell host
但 edge ownership 无法证明时一律 fail-open，不按 inactive cell 直接删除。
异步 stale-room guard 与 roof-repair cache 也以完整
`rvId:generation:bitmapVersion` 作为索引，并在复用前逐字段验证当前 managed bitmap、
shell edges 与 wall/bounds geometry；同一 identity 的几何快照不一致会使 cache 失效，
不得复用旧边界。
服务端拆除链以当前 42.20.4 的 `SledgehammerDestroyPacket` →
`RemoveItemFromSquarePacket` → `OnObjectAboutToBeRemoved` 为权威入口；该事件在原版对象仍
附着时识别当前生成的 `IsoThumpable` 外墙，对象必须带有与 shell ledger 完全匹配的当前 tag
和 object index。`OnDestroyIsoThumpable` 仅作为直接 thumpable 销毁路径的同一严格匹配补充
入口；两条事件按完整房间 key 与稳定坐标/object-index 键去重，活动 token 期间的不同键进入有界
follow-up 队列，前一事务结束后按当前 mapping 重新验证再启动，不吞掉独立墙事件。对象事件未暴露时，现有 30-tick map/presence 流程读取
authoritative player square 的 `isInARoom()`，以 `getRoom()/getRoomDef()` 作支持状态，只在
当前 RV scope 内检测到 inside→outside transition 时安排修复。

拆墙后由 `RV_Server` 与 Railroader 适配器共同维护 roof-refresh 状态机：
`queued` → `temporary` → `repairing` → `returning` → `complete`。服务端复用
`Relocate`/严格 token-only `RelocateAck`，从当前 boundary bitmap 的 100×100 managed scope
派生中心与固定实验层 `ROOF_REPAIR_TEMP_Z=-15`，验证临时方格已脱离 room geometry、repair
目标及墙/屋顶相关方格已加载，然后在到达后的 5/10/15 server ticks
（约 0.5/1.0/1.5 秒、运行时约 10 Hz）调用一次现有地板 add/remove 修复。临时阶段向客户端
发送仅展示用的“正在刷新房间”头顶提示；客户端只执行服务端命令和 token ACK，不提交坐标或
世界状态。完成后在完整 `rvId/generation/bitmapVersion`、权威 relation、玩家状态仍匹配时
返回拆墙前服务端捕获的合法 RV 位置并释放 boundary correction lease。临时传送前先验证
当前 schema、RV identity、成员稳定异步 identity、精确原坐标和服务端目标，再将这些值保存在
服务进程内存；客户端只接收服务端坐标并回传 token。schema/identity 变化、加载超时或 ACK/阶段
不匹配时安全取消；只要成员仍在 `z=-15`，就持续受控回传，不能清理 return context/lease，也
不能让 repair 成功掩盖回传失败。玩家掉线只暂停内存事务，稳定 online ID+用户名重新上线后
继续精确回传；服务器进程崩溃、关闭或重启时内存事务丢失，不恢复原坐标、repair、phase 或
`READY`。服务端日志只表示权威 add/remove 已应用，不表示客户端视觉已成功。

远端 relocation 持有 Boundary correction lease；`RV_Server.OnTick` 先续租再推进组状态，
lease 存续期间跳过 Boundary 普通 geometry/cleanup 扫描及服务端 stale-room ownership
扫描，避免用远端玩家 cell 解析原 RV footprint；全员权威回传并完成后才释放 lease、恢复
普通监测。

跨 chunk 回传可先以服务端目标坐标完成 token-only ACK，而等待原 RV `GridSquare`
重新绑定；服务端仍以权威位置、身份和 current-schema context 复核，并保持 lease，
直到 `completeRoofRepairRelocation` 与 `roofRepairSquaresLoaded` 证明加载完成。

当前 roof-refresh 已使用当前 bitmap 中心减 `(18000,0,15)` 的远端点执行跨 chunk
卸载/重载路径；同 x/y 改 z 不等于客户端 chunk unload/reload。若实机仍无法刷新屋顶，
只能记录为未验收并另行设计后续实验，没有可靠 ACK 时不得伪造完成。每次尝试都重验
current map/record/relation/identity 与 authoritative inside player；generation staging 的
加载等待可硬超时，但 roof-refresh 的最终回传在同一进程内不能因有限 retry 耗尽而清理，
必须保留内存 context 直到成员离开 `-15` 并回到记录方格。匹配、调度、加载、回滚阶段均有
受控日志。

除普通事务外，服务端按固定 tick 运行无状态 `z=-15` 哨兵。候选玩家必须未被当前内存
generation/roof 事务的稳定 identity claim，且 `floor(x/y)` 精确命中当前 bitmap 的单个
generation 中心格或 roof 中心减 `(18000,0,15)` 的远点格。manifest、mapping、boundary、
bitmap 和 map/record 双向 `inside=true` identity 关系必须完整且只属于一个 RV；否则
fail-closed 并提示 `SAVE_REBUILD_REQUIRED`。成功回传使用正常 Enter 的 current
`record.rvPosition`、active bitmap 与合法坐标校验，不恢复原坐标、不运行 repair、不改变
manifest phase/`READY`。busy/短 cooldown 防止重复发送，但玩家仍在 `-15` 时会继续受控重试。
进入已有 RV 与重连驻留由同一 current-only monitor 入口处理：服务端先校验
mapping record 与 current manifest/boundary identity，再以 manifest 的当前 bounds
向对应客户端定向发送 `RefreshRoomOwnership`；schema 或 identity 不完整时返回
`SAVE_REBUILD_REQUIRED`，不执行该路径的传送。

开发期存档只接受当前 manifest、bitmap、shell ledger、mapping 和异步身份 schema；临时传送
状态只存在当前服务进程内存。
manifest 与 mapping 中的 epoch 时间字段写入整秒（`math.floor(os.time())`），并继续由当前
schema 的整数 gate 严格校验；Kahlua 的 `os.time()` 小数返回值不得直接持久化。
缺失或不匹配时服务端必须拒绝操作并提示删除测试存档后重建；不得迁移、转换、使用
旧 bounds、清理对象、传送玩家或运行 boundary guard。空的新容器才可按当前 schema 初始化。

Railroader 适配器由 `RV_Server` 在加载后显式桥接到公共 `RV.Server` facade；utility
初始化只能通过该 facade 的 current mapping/geometry 身份 gate。mapping 与 record 的
`inside=true` rider 关系同时保存当前 `locoId`，供 utility 初始化、重连和边界监视做
严格的 current-schema 双向校验；适配器缺失或身份不匹配时继续 fail-closed。
