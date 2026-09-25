# RV / Railroader 定时任务审计

## 范围和结论边界

本次只读盘点了 RV 与 Railroader 适配代码中的 `OnTick`、`OnRenderTick`、tick 计数器重试，以及会触发这些任务的对象/玩家事件。源码中没有发现 `EveryXMinutes` 一类定时器。表中的固定频率和工作量来自当前 Lua 源码；实测频率来自此前临时 `[TeleportTrace]` 计数日志。日志记录的是回调次数，不是回调耗时或 CPU 占用，不能单独证明它造成黑屏。

本文件不改运行时代码，也没有重跑服务器。此前冷目标传送的用户对照中，未经过 RV 的冷区远传也出现过黑屏；该对照目标和访问历史不同，不能量化 RV 对耗时的影响。风扇/CPU 观察是调查线索，不是函数级性能证据。

## 调度任务清单

| 位置 / 任务 | 频率 | 运行条件与工作量 | 离开 RV 后 |
|---|---|---|---|
| 客户端 room ownership guard：[`RV_ContextMenu_Relocation.lua`](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_ContextMenu_Relocation.lua#L313) 调用 [`RV_ContextMenu_RoomOwnership.lua`](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_ContextMenu_RoomOwnership.lua#L301) | `OnTick` 每 tick；全 footprint 兜底每 30 tick；命中 RV 范围的对象增删事件会请求下一 tick 扫描 | 每个 guard、每 tick 遍历本地活动玩家，读取其当前位置，只对落在该 RV 范围内的当前方格做 ownership 检查。到期或事件触发时完整扫描 old/new footprint。一个 guard 可由一次新建广播到所有客户端，因此成本按客户端数和每个客户端保留的 guard 数增长。 | **会继续。** 客户端 guard 没有稳定后过期的分支；源码注释明确要求在当前 RV identity 生命周期内保持 armed。新的同 RV identity 会替换旧 guard。即使玩家已离开 footprint，每 tick 的玩家位置筛查和每 30 tick 的完整扫描仍会运行。 |
| 客户端最终传送重试：[`RV_ContextMenu_Relocation.lua`](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_ContextMenu_Relocation.lua#L55) / `tryApplyFinalRelocation` | 每 tick，最多 600 tick | final relocation 尚未应用时，每次尝试先同步调用完整 ownership 扫描，再检查目标方格和房间状态。目标方格不可用时返回 false，下一 tick 重复。如果扫描失败/目标未加载而一直重试，这是单次工作量最大的已找到路径。完成传送后还会再做一次完整扫描。 | 事务结束或 600 tick 超时后停止。若失败原因持续存在，最多约 600 次同步完整扫描。普通 relocation 的轮询也每 tick 执行，但不做完整 footprint 扫描。 |
| 客户端 boundary 预测：[`RV_BoundaryClient.lua`](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_BoundaryClient.lua#L382) | `OnTick` 每 tick；存在 `OnRenderTick` 时，预测在每 render tick；否则退回 `OnTick` | 有 boundary snapshot 才调用活动本地玩家检查。每玩家做当前 bitmap 范围/可走格判断；只有跨格移动时才做线段检查。`onBitmapClear` 清理对应 snapshot 后，两个回调都会快速返回。 | 成功退出并收到 bitmap clear 后，不再做玩家预测；回调仍被注册，但仅检查空状态。临时 trace 的 `renderTicks` 计数器只证明渲染回调频率，不能证明此回调在空状态时仍有重计算。 |
| 客户端 current-square refresh：[`RV_RailroaderContextMenu.lua`](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_RailroaderContextMenu.lua#L488) | `OnTick` 每 tick，单次最多 120 tick | 仅当服务器选定的 RV 传送后当前 square 尚未同步时执行；验证玩家仍在目标附近并刷新当前方格。完成、玩家死亡/离开目标或超时后清除 pending。 | 有界的单次任务；清除 pending 后为空操作。 |
| 客户端 utility 表现处理：[`RV_UtilityClient.lua`](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_UtilityClient.lua#L227) | 没有周期任务；`OnObjectAdded` / `OnLoadGridsquare` 触发 | 检查对象 identity tag；加载方格事件会遍历对象和 special objects，并仅隐藏被当前 utility schema 标记的水箱/代理对象。调用频率跟世界对象流入相关，单次工作按该格对象数增长。 | 仍注册事件，但非 utility 对象只经过 tag/schema 快速筛选；不轮询 RV。 |
| 服务端主 tick：[`RV_Server_Commands.lua`](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_Server_Commands.lua#L41) | `OnTick` 每服务器 tick | 更新 transaction lease；随后调用 boundary 更新、room ownership guard、屋顶修复组状态机、utility tick 和 pending generation 状态机。无 pending transaction 时后半段提前返回。Boundary 自身见下行；本入口的事务扫描主要在生成/修复阶段同步执行。 | 仍每 tick 运行入口；无活跃 transaction 时执行状态检查后快速返回。某些 ownership guard 和全局 sentinel 独立于当前玩家是否在 RV。 |
| 服务端 room ownership guard：[`RV_Server_RoomOwnership.lua`](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_Server_RoomOwnership.lua#L164) | 每 tick 遍历 guard；每 30 tick 扫描，范围内对象增删事件请求下一 tick 扫描 | 每 guard 完整检查 old/new footprint。generation 事务还会在 after-remove、before-final-relocate、before-commit、after-commit 等正确性阶段同步刷新。单次扫描最多 1,054 个唯一坐标（旧、新 RV footprint 不重叠时）。 | **有界但可跨越退出。** 最少保留 1,800 server tick；连续稳定后才完成，异常/不稳定时最长 7,200 tick。以诊断日志约 10 tick/s 的服务端节奏换算，约 3 至 12 分钟；实际墙钟时间随服务器 tick 率变化。屋顶修复远传阶段会暂停该非事务扫描。 |
| 服务端 boundary 验证与清理：[`RV_BoundaryServer_Sweep.lua`](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_BoundaryServer_Sweep.lua#L152) | `Boundary.onTick` 每 tick；每 10 tick 执行一批清理 | 每 tick 读取在线玩家快照并更新其 boundary 状态，成本至少随在线玩家数 P 增长。存在 active boundary 时，每个唯一 RV boundary 最多处理 64 个 bitmap square；每格读取最多 6 类 object collection、floor，并审计其中对象。bitmap 是 100×100、两层；一个完整 cursor pass 最多 20,000 格，遇到未加载方格会停住而不强制加载。完整清理完成后 6,000 tick 才重新扫。 | 玩家离开受管范围后不再把其 RV 加入 active cleanup group；在线玩家状态检查仍每 tick 进行。若其他玩家留在该 RV 内，边界组清理仍继续，按不同 active boundary 组数 B 增长。 |
| Railroader 服务端 tick adapter：[`RV_RailroaderServer_Tick.lua`](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer_Tick.lua#L171) | 每 tick 检查 pending 屋顶修复；每 5 tick 运行 relocation sentinel；每 30 tick 读地图、清理缓存并检查 RV 内玩家；每 120 tick 更新机车位置 | 无屋顶修复/跟进事件时，repair 队列检查很快返回。sentinel 每 5 tick 扫在线玩家位置（O(P)，仅发现 sentinel 玩家后才读地图/尝试找回）。每 30 tick 的 `repairInsidePlayers` 扫在线玩家并检查映射为 inside 的玩家；每 120 tick 遍历 locomotive records（O(L)，对每条记录查询 train/pose）。 | sentinel 和固定周期 map/player 工作仍会跑，但找不到 RV 内玩家/哨兵时不进入相应修复逻辑。pending wall/roof transaction 在完成、取消或截止前继续按状态机运行。 |
| 服务端 utility settlement：[`RV_UtilityServer.lua`](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_UtilityServer.lua#L343) | 主 tick 中每 30 tick；mapping sync 也是每 30 tick | mapping sync 扫在线玩家。settlement 读取全部 utility records（R），逐条解析权威 RV/player context 并在有效时结算水量；服务忙时跳过。工作量按在线玩家数和存档 utility record 数增长，不按 footprint 方格数增长。 | 只要记录存在就继续周期结算；玩家不在 RV 时通常在权威 context 检查处拒绝/跳过。当前日志中存在重复 `UTILITY_TARGET_NOT_LOADED`，它证明周期任务执行过，不是 CPU 计时数据。 |
| 服务端 boundary validation cache warm：[`RV_RailroaderServer_BoundaryValidation.lua`](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer_BoundaryValidation.lua#L155) | `OnGameStart` / `OnServerStarted` / `OnCreatePlayer` 触发；失败/待预热后由每 30 tick 的 repair pass 重试 | 只处理当前 RV region 内候选玩家；cache TTL 60 tick，常规 refresh 30 tick。重验证需要读 map、对照 mapping、manifest 与 geometry；事务繁忙时延后。 | 没有 region 内玩家时清空待预热并结束；在线玩家在 RV 内时才继续。 |

### 事件触发但不是独立定时器的任务

- `OnObjectAdded` / `OnObjectAboutToBeRemoved`：客户端和服务端的 room ownership handler 先取 object 坐标、按 old/new footprint 过滤，并将 guard 标为 `scanRequested`。同一 tick 内多次事件会合并成一次扫描；事件横跨多个 tick 时可每 tick 各触发一次完整 footprint scan。生成/回滚会批量增删对象，所以这是周期兜底以外的重要触发源。注册点见 [`RV_ContextMenu_Relocation.lua`](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_ContextMenu_Relocation.lua#L417) 和 [`RV_Server_Commands.lua`](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_Server_Commands.lua#L278)。
- `OnProcessAction` / `Boundary.onObjectAdded`：针对边界范围内的对象变更记录 dirty action，后续 flush 时回查方格对象；事件只处理命中 boundary 的坐标，数量由玩家建筑操作和对象事件决定。
- `OnWaterAmountChange`、utility 对象增删：立即更新/复核水量来源身份，没有周期扫描；触发数由游戏原生水变化和对象变化决定。
- `OnObjectAboutToBeRemoved` / `OnDestroyIsoThumpable`：屋顶/墙拆除进入去重、延后与跟进修复队列。主要延迟/截止是 5、10、600 tick；队列活跃时 server adapter 每 tick 推进状态，普通空闲时不跑 footprint 扫描。
- `OnClientCommand`：玩家意图触发服务端校验、生成/退出/utility 操作。它不是自动轮询，但事务中会启动上表中的 pending 状态机与事务阶段扫描。

## Footprint 扫描的坐标来源及上界

[`RV_Layout.lua`](contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RV_Layout.lua#L18) 的 `eachStructureCoordinate` 对 base `wallMinX..wallMaxX × wallMinY..wallMaxY` 和 roof `roofMinX..roofMaxX × roofMinY..roofMaxY` 两个矩形逐格调用回调。当前尺寸来自 bounds schema：base 为 7×41 = 287；roof 为 6×40 = 240；一个 footprint 合计 **527 个坐标**。这不是“92 个 wall object”的扫描：墙对象计划本身是 92 个坐标；ownership 检查读取的是方格的 `getRoom()/getRoomDef()` 状态。

当前 6×40 cabin interior 位于 base 矩形内，共 240 格；base 矩形额外覆盖 47 格。roof 层再覆盖 240 格。仅扫墙边会跳过 cabin interior 与 roof interior 中央格。由于检查目标是方格是否仍关联一个无 `RoomDef` 的房间对象，边界几何本身无法证明内部格没有同一类失效关联。历史日志累计出现 `cleared=240`，说明旧测试中该 guard 曾累计清除 240 个这种关联；它没有坐标清单，不能据此断言这 240 格恰好是一整层，也不能据此证明每格都必须扫。

客户端和服务端都在 old/new bounds 间按坐标去重。因此：无旧 footprint 时每次最多 527 坐标；旧、新 footprint 分离时最多 1,054；重叠时低于此上界。每个坐标至少一次 `getGridSquare`；已加载方格再读取 `getRoom`，只有 room 非 nil 时才读 `getRoomDef`；发现失效关联才执行 `setRoomID(-1)` 并复查 `getRoom`。每坐标的绑定调用数取决于分支和方格是否已加载，源码没有记录毫秒耗时。

## 工作量估算（推算，不是性能实测）

- 临时客户端计数日志中，`tick=24930 → 24960 → 24990` 的间隔分别约 0.499 秒和 0.501 秒；`renderTicks=55438 → 55468 → 55498` 同样每约半秒增加 30。该次运行的回调率约为 **60/s**。这是同一诊断运行的计数，不能推广为所有机器/帧率的固定值。
- 客户端一 guard 每 30 tick 做一次兜底全扫；按该样本约 60 tick/s 推算为每 guard 2 次/s，即单 footprint 约 1,054 次 `getGridSquare` 坐标查询/s，old+new 分离时最多约 2,108/s。generation guard 会广播到所有连接客户端，汇总成本还乘以客户端数 C 和各端 guard 数 G。
- 若 final relocation 因目标方格未加载而连续返回 false，`tryApplyFinalRelocation` 在最多 600 tick 的 pending 生命周期内每 tick 重复全扫。按 60 tick/s，单 footprint 理论上最多约 31,620 坐标查询/s，双 footprint 约 63,240/s；一段 600 tick 超时最多约 316,200 / 632,400 次坐标查询。它是源码上界，不是此次失败现场的观测次数；当前现场未测到 final relocation 是否仍 pending，也没有扫描计数。
- 服务端 room ownership 兜底间隔 30 tick。诊断 trace 中 server tick 一度约 10/s，按此估算约每 3 秒/guard 扫一次，单 footprint 平均约 176 坐标查询/s；双 footprint 约 351/s。事件跨 tick 连续到来可将完整扫描推到每服务器 tick一次；服务器线程节奏和事件率会改变该值。
- server boundary cleanup 对每个不同 active RV boundary 每 10 tick 最多访问 64 个 square。按同一约 10 tick/s 样本，约为每 boundary 每秒 64 格；若有 B 个不同 active boundary，格访问上限按 B 线性增长。每格对象量没有静态上限，且遇到未加载格会暂停 cursor。
- 这些估算只计循环/方格/玩家/存档记录数量。没有采到 Lua/Java 函数耗时、客户端/服务器 CPU profile、每秒 room guard 实际扫描数或对象事件频率；不能从“调用量大”直接推出黑屏或 CPU 上升的因果关系。

## RoomDef 清理的证据与未知影响

代码实际处理的精确条件是：`square:getRoom()` 成功且非 nil，随后 `square:getRoomDef()` 成功但为 nil；只有这个状态才调用 `setRoomID(-1)`，并要求复查 `getRoom()` 已变为 nil。合法房间不会被清除。该检查位于客户端 [`RV_ContextMenu_RoomOwnership.lua`](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_ContextMenu_RoomOwnership.lua#L110) 和服务端 [`RV_Server_RoomOwnership.lua`](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_Server_RoomOwnership.lua#L36)。

Git 历史补充了这项防护的设计理由。当前可见历史从 `9c5a220`（2026-09-10，`chore: initialize project repository`）开始；`git log --all --oneline --reverse` 没有更早的父提交，因此无法追溯这段逻辑在仓库初始化之前如何引入。该初始提交中的 `RailroaderRVTest/README.md`（当时第 11–23 行）称，重复生成会由 B42 动态房间流程移除旧 `IsoRoom` 并重建 `RoomDef`；`WorldRegionToMetaGrid.removeIsoRoom` 清空旧 `IsoRoom` 的 `RoomDef` 后，部分方格可能暂时保留旧 room ID，玩家之后走到该格可能触发 `ParameterFirearmRoomSize` 异常。因此代码只对 `room ~= nil && RoomDef == nil` 调用 `setRoomID(-1)`，并保留有效房间。初始提交中的服务端注释（`RV_Server.lua` 当时第 1145–1158 行）也明确写出该状态及复查条件。

后续提交 `d2d9506`（2026-09-13，`feat: enforce current RV schema and refresh workflow`）说明了客户端 guard 为什么改为常驻：即使首次生成已稳定，之后墙或地板被移除仍可能触发新的异步房间重建；如果 guard 在静稳期后退出，下一次玩家更新仍可能读到 `RoomDef=nil`。该提交因此保留当前 RV identity 的客户端监视器，并为进入已生成 RV 或重连的客户端重新布防。这解释的是客户端 guard 的生命周期设计，不应推成服务端 tick guard 也同时常驻。

上述 README 和提交注释记录的是作者当时的风险判断与设计动机，不是运行时异常栈、游戏崩溃复现或独立验证的引擎行为。历史中的测试代码断言清理条件和代码结构；它没有复现 `ParameterFirearmRoomSize` 异常。具体行为的证据边界见下方日志与影响说明。

可确认的事实：

- 归档客户端日志 `testserver/runtime/client/Logs/logs_2026-09-13/2026-09-13_16-58_DebugLog.txt:1203` 记录 `client room ownership monitor active generation=8317:1:1 cleared=240`。计数只在清理动作成功且 `getRoom()` 复查为 nil 后增加，因此旧测试至少发现并修正过 240 个符合该条件的引用（累计数；没有坐标列表）。同一文件 `:1195` 先记录 `cleared=0`，` :1196` 和 `:1204` 之间有 `sending ExitRV`；时间顺序本身不能证明失效引用导致退出问题。
- 最新一键测试的客户端日志 `testserver/runtime/client/Logs/2026-09-24_21-27_DebugLog.txt:1209` 是 `cleared=0`；服务端生成事务在 `2026-09-24_21-26_DebugLog-server.txt:2354,2363,2391,2397` 的四次阶段扫描也均记录 `cleared=0`。这表示该轮没有实际触发清理分支。
- 对最新客户端/服务端日志定向搜索，没有发现 `ParameterFirearmRoomSize`、RoomDef stale 的异常栈或对应 Lua error。日志有 `duplicate RoomDef.metaID` 的启动错误，但没有证据把它和 RV guard 或远传黑屏关联起来。
- 官方 Lua 快照中既有对 `room` / `room:getRoomDef()` 做 nil 检查的例子（`server/Farming/SFarmingSystem.lua:162-164`、`client/ISUI/ISInventoryPage.lua:1418-1419`），也有未做这些检查的连续解引用（`server/ClientCommands.lua:322-326`）。这表明 nil 防护可能避免脚本消费者在无效数据下访问 nil；它不能证明该消费者曾在 RV 测试中被触发。模块注释提到的 `ParameterFirearmRoomSize` 当前没有与本报告可采的当前 Java 基线相匹配的接口/调用证据，因此其具体空值行为仍属**未证实**。
- “不清理会崩溃/抛异常”目前**未证实**；“会造成屋顶隐藏或错误渲染”也**未证实**。旧日志中的 `cleared=240` 证明有失效引用存在，不证明具体玩家可见故障。

若后续要判定这项清理是否可删或可缩范围，需要在同一生成/拆除场景采集被清除格的坐标和楼层，记录清理前后的 `getRoom`、`getRoomDef`、`isInARoom`；保留完整 client/server exception stack；并在相同存档上对比启用/停用清理时的房间归属、屋顶显示和 firearm room-size 行为。没有这组对照前，不应把 crash、roof/render 或黑屏作为清理的已证实后果，也不应把边界扫描替代全 footprint 当作已验证安全。

## 后续人工评审应优先确认

1. 客户端 guard 是否应继续对所有收到 generation 广播的客户端永久保留；当前代码每 tick 检查所有本地玩家、每 30 tick 做全范围扫描，即便本地玩家已离开。
2. final relocation 目标未加载的重试路径是否会实际重复扫描 527/1,054 格；需要在运行时分别计数 final-pending 尝试数、room-ownership 扫描数、扫描坐标数及耗时。
3. `cleared=240` 的历史数量来自哪些坐标和楼层；若主要是 240 个 base interior 格，则边界-only 策略会漏掉已观察到的内部失效实例。屋顶 240 格是否也出现过同类引用，目前日志没有分布证据。
4. 服务端 `OnTick` 与 `Adapter.OnTick` 是两个每 tick 回调；需要 profile 后再决定是 footprint 扫描、对象事件风暴、boundary object audit、事务重试还是其他原生流送成本占主导。

## 2026-09-25 一键测试：周期轨迹与 CPU 采样

### 测试流程与观察

本轮由用户在新存档中完成整体测试：房车生成前先地图传送到远处、再回机车旁，区域约 1 秒加载；首次进入并退出房车后，再次传送到远处，直到目标 ready 约 73.7 秒。该结果确认本轮复现了 RV 首次生成之后冷区域加载显著变慢的现象。

### 采样结果

- 服务端日志显示，`02:14:40.202–02:15:46.897` 之间 server tick 只前进 1 tick；同一时段服务端进程 CPU 使用约为一个逻辑处理器。客户端 tick 在这段时间仍持续推进。
- RoomDef、boundary 和 utility 的周期性 `[PerfTrace]` 汇总在服务端 tick 停滞时一并停止；对应观测窗口中记录的周期全 footprint 扫描数为 0。因此这些被埋点的周期工作没有在该窗口持续执行，现有记录不能把 tick 停滞归因于它们。
- 首次生成阶段的 RoomDef 扫描记录为：服务端 3,162 个格子、约 9 ms；客户端 5,797 个格子、约 11 ms。这些是扫描代码记录的单次经过时间，不涵盖整个生成事务或 Java/引擎工作。
- Utility 约每 30 tick 对未加载目标重试一次失败，单次 wall 时间约 0.4 秒。它是可继续观察的周期调用，但 tick 停滞期间其日志也停止，当前证据不支持它解释分钟级加载延迟。
- CPU 频率计数器全程报告 4,501 MHz；该计数器结果不足以证明处理器实际频率全程稳定。记录到的磁盘延迟峰值为 18.12 ms。
- 目前没有定位到具体的服务端 CPU 热点或导致 server tick 停滞的调用栈。客户端继续 tick、服务端进程仍消耗约一个逻辑核，只能说明两端当时的进度不同，不能据此推定根因。

### 临时决定与证据保存

用户决定将本性能问题标记为**暂不处理**。此结论表示根因尚未定位、性能问题未解决；本轮的周期诊断埋点暂时保留，供后续与 CPU 采样时间对照。以后实际修复该性能问题时，再移除这些临时埋点。

本轮 CPU 频率 CSV 位于 `Z:\RailroaderRVTestCache\perf\cpu_frequency_samples.csv`；事件 CSV 位于同目录的 `cpu_frequency_events.csv`。服务端日志为 `Z:\RailroaderRVTestCache\server\Logs\2026-09-25_02-09_DebugLog-server.txt`，客户端日志为 `Z:\RailroaderRVTestCache\client\Logs\logs_2026-09-25\2026-09-25_02-09_DebugLog.txt`。Z 盘是易失 RAM 磁盘，文件可能被重启或人工清理移除；这些路径仅作当前证据位置记录，不保证长期留存，也不纳入版本控制。

## 2026-09-25 调查续篇：JFR 与服务端停滞

此前记录的“暂不处理”已由用户授权恢复调查；现有性能证据仍不足以把根因归属到单一实现。

### 证据与时序

- 原始 JFR：`%LOCALAPPDATA%\RailroaderRVTest\profiles\rv_teleport_25924_20260925T043354777227+0800.jfr`（2,192,029 bytes）；关联 .events.csv、.summary.txt、.threads.txt、.session.json。日志备份：`%LOCALAPPDATA%\RailroaderRVTest\profiles\logs_2026-09-25_0426`。
- 只为本次调查在 `%LOCALAPPDATA%\RailroaderRVTest\tools\azul-zulu-25.0.1-25.30.17.0` 安装了一次性 JDK 25.0.1 x64，归档 SHA-256：`72844ba8dddf9259ab9cfda9d515d0c850179705f74278a75973d73f0c5b2d2b`。jcmd、jstack attach 成功，短 JFR start/stop 与读取校验成功；游戏 JRE 未修改。一键测试的可见控制台流程正常，服务端最终 exit code 为 0。
- JFR 录制开始于 `04:33:54.777 +08:00`，停止请求为 `04:37:23.062 +08:00`。事件 CSV 的人工提示标记是 `04:34:50.830`，ready 反馈是 `04:37:22.970`；它们都不等于实际点击时刻或独立确认的恢复时刻。
- 服务端 [PerfTrace] 在 `04:34:57.638` 记录 `f=2231/t=2230`，下次在 `04:36:04.397` 记录 `f=2232/t=2231`：间隔 66.759 秒只前进一 tick。服务端该窗口 boundary `sq=0`、roomguard `fs=0`；停滞前 utility 记录的单次最大耗时为 426 ms。客户端同期 tick 继续推进。

### JFR 样本

- 该 66.759 秒窗口有 6,312 个 jdk.ExecutionSample：6,306 个在线程 main，6,305 个含 ServerMap.preupdate，6,240 个含 ErosionMain.LoadGridsquare，6,234 个含 IsoGridSquare.RemoveTileObject；其中 NatureBush.replaceExistingObject 为 4,336 个，NatureTrees.replaceExistingObject 为 1,898 个。
- 代表样本 `04:35:30.004334300 +08:00` 的栈为 KahluaThread.luaMainloop → LuaCaller.protectedCallVoid → Event.trigger → LuaEventManager.triggerEvent → IsoGridSquare.RemoveTileObject → NatureBush.replaceExistingObject → ErosionWorld.validateSpawn → ErosionMain.LoadGridsquare → IsoChunk.doLoadGridsquare → ServerCell.RecalcAll2/Load2 → ServerMap.preupdate → GameServer.main。同一 Erosion 栈在 `04:34:47.998809600` 已出现，早于人工提示标记。
- 录制最初 50 秒，IngameState.update 出现在 786 个样本中的 724 个；从服务端 PerfTrace 恢复记录至 ready 反馈的窗口，出现在 1,080 个样本中的 1,030 个，ServerMap.preupdate 为 1/1,080。停滞窗口 ThreadCPULoad 的 6 个 main 记录平均约占整机 3.04%；以 32 个逻辑处理器折算约为一核。NativeMethodSample 的 FileSystemWatchService 栈停在 GetQueuedCompletionStatus 等待路径，不作为 CPU 热点解释。

### 结论边界与后续

JFR 能看到进入 LuaEventManager.triggerEvent 的 Java 调用栈，但看不到 Lua 事件名、具体回调函数和各回调耗时，因此不能拆分引擎 Erosion 与 RV/官方监听器的工作份额，也不能确认停滞由管理员点击触发。当前证据不证明周期扫描是根因，不据此提出玩法修复。

待用户恢复运行时测试后，最小后续验证是在准确标记实际点击的同时，分别记录 RV 三个 OnObjectAboutToBeRemoved 处理器的调用次数和累计耗时，再与同轮 JFR 对齐；本轮未实施。

## 2026-09-25 全周期续篇：对象移除监听器与服务端 tick 停滞

### 归档与时序

- 原始归档位于 `%LOCALAPPDATA%\RailroaderRVTest\profiles\RailroaderRVTest_20260925_121058_+0800_PID30052_1e909e12.jfr` 及同前缀 `_timeline.jsonl`；服务端/客户端日志位于 `%LOCALAPPDATA%\RailroaderRVTest\logs\RailroaderRVTest_20260925_121058_+0800_PID30052_1e909e12_logs`。JFR 为 3,907,707 bytes；`jfr summary` 读取成功，录制从 12:10:58 到 12:19:50 +08，持续 532 秒。该证据来自可见控制台的一键整体测试，服务器退出码为 0；本次审计未启动新测试。
- 时间线中的点击时间 `12:17:00`、黑屏 `12:17:15–12:18:25` 是用户报告估值。服务端 `2026-09-25_12-07_admin.txt:2` 记录管理员远传命令于 `12:17:15.076` 执行；客户端 chat 记录于 `12:17:15.130` 收到远传消息。此前 RV 阶段为 `EnterRV` 请求 `12:14:11.258`、mapping 进入 `12:14:16.679`、`ExitRV` 完成 `12:14:25.798`。
- 服务端周期日志从 `12:17:22.079` 的 `t=4589` 到 `12:18:18.414` 的 `t=4591`，间隔 56.335 秒只前进 2 tick；对应窗口 roomguard `fs=0`、boundary `sq=0`。客户端 10 秒汇总仍约增加 599–600 tick，约 60 tick/s。

### JFR 样本

- JFR 全程有 11,601 个 `jdk.ExecutionSample`。按 `jfr print --exact --events jdk.ExecutionSample --stack-depth 64` 逐事件分析，并以服务端 tick 两条日志的 `[12:17:22.079, 12:18:18.414] +08` 为含端点的窗口，得到 5,323 个样本，其中 `main` 线程 5,279 个。`jfr print --json` 的时间戳明确带 `+08:00`；stack-depth 64 与 128 的计数相同。对每个样本按栈中是否包含目标帧计一次：`ServerMap.preupdate` 5,242，`ErosionMain.LoadGridsquare` 5,188，`IsoGridSquare.RemoveTileObject` 5,178，`LuaEventManager.triggerEvent` 5,224，`NatureBush.replaceExistingObject` 2,863，`NatureTrees.replaceExistingObject` 2,316。另一份同窗口独立统计给出 main 5,248、Erosion 5,157、RemoveTileObject 5,147、LuaEvent 5,175、NatureBush 2,871、NatureTrees 2,277；统计口径差异尚未解释，以下判断不依赖分项的精确值。
- 代表样本 `12:17:22.607614800` 的主线程栈经过 `KahluaThread.luaMainloop → Event.trigger → LuaEventManager.triggerEvent → IsoGridSquare.RemoveTileObject → NatureBush.replaceExistingObject → ErosionWorld.validateSpawn → ErosionMain.LoadGridsquare → IsoChunk.doLoadGridsquare → ServerCell.RecalcAll2/Load2 → ServerMap.preupdate → GameServer.main`。JFR 能确认该调用路径在停滞窗口内反复采到，但不显示 Lua 事件名，也无法分配具体 Lua 回调的时间。

### RV 对象移除计时与静态候选

- 服务端 `[PerfTrace] server/object-remove` 在 `12:17:15.661–12:18:18.409` 记录 shell-roof-repair 2,171 次、2,171 次成功计时，累计 61,427 ms、单次最大 51 ms；首末跨度 62,748 ms。完整的约 10 秒窗口分别测得约 9.3–9.9 秒、332–355 次。同期 utility-fixture 累计 21 ms，room-ownership 累计 45 ms，均 2,171 次且 room-ownership `hit=0`。进入 RV 的对象流阶段三者各 23,046 次，shell-roof-repair 为 183 ms（utility 88 ms、room-ownership 216 ms）。
- 临时计时器以 `getTimestampMs()` 记录回调开始/结束之间的墙钟经过时间，在聚合输出前已结束计量。该值不是精确 CPU 时间；时钟单调性没有独立验证；若回调重入，累计耗时会包含嵌套区间。
- 静态路径候选见 [`RV_RailroaderServer_RoomRepair.lua`](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer_RoomRepair.lua#L451)：每次对象移除先读取 map、遍历 locomotive records、检查 `validRecord`，再调用 `Boundary.isCurrentShellWall`。该判定见 [`RV_BoundaryServer_Objects.lua`](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_BoundaryServer_Objects.lua#L141)：先解码 boundary，再检查 `IsoThumpable` 类型，所以普通植被对象也会经过前置校验。现有计时没有拆出 mapData、validRecord、boundary decode 各自耗时，也没有拆分其他监听器在 JFR 样本中的份额。

### 结论边界与下一步

多份证据支持：Erosion 对象移除活动期间，RV shell-roof-repair 监听器承担了高开销，是这次服务端停滞的强候选因素；目前不能把耗时归到单个子步骤，也不能断言它独自解释全部 56 秒 tick 间隔。若继续评估玩法改动，先对 `mapData`、`validRecord`、`isCurrentShellWall` 分段计时并检查重入，再据实评估是否可将非候选对象的廉价类型/身份筛选前移；保留当前 schema 与身份拒绝语义。本轮没有修改玩法逻辑。

## 2026-09-25 P0 单客户端运行时复核

### 运行范围与归档

- 本次用户授权的一键整体运行时测试已经结束。会话元数据记载入口为从项目根目录运行 `python testserver/run_test.py`，服务器 PID 为 28400，客户端 PID 为 25848，客户端数为 1；按测试记录，服务器控制台可见。本次审计只离线读取归档，没有启动新测试。
- 原始 JFR：`%LOCALAPPDATA%\RailroaderRVTest\profiles\RailroaderRVTest_20260925_145731_+0800_PID28400_P0.jfr`，4,121,872 bytes。直接对该文件运行 `jfr summary` 成功：1 chunk，开始时间 `2026-09-25 06:57:31 UTC`（`14:57:31 +08`），持续 446 秒，包含 8,139 个 `jdk.ExecutionSample`。该 summary 是采样事件总量，不是方法调用数或 CPU 时间。
- 双端日志归档目录：`%LOCALAPPDATA%\RailroaderRVTest\logs\RailroaderRVTest_20260925_145731_PID28400_P0_logs`。关键来源为 `server/2026-09-25_14-55_admin.txt`、`server/2026-09-25_14-55_DebugLog-server.txt`、`client/2026-09-25_14-56_DebugLog.txt`；JFR summary 与会话/时间线分析文件在同一 `profiles` 目录。

### RV 阶段与传送观察

- 首次进入/退出的客户端请求分别记在 `client/2026-09-25_14-56_DebugLog.txt:1297,1310`。服务端 `CycleTrace` EnterRV 时间为 `14:59:57.913`（日志行显示 `.914`，`ms` 字段为 `.913`；`DebugLog-server.txt:2314`）；`generation committed READY` 为 `15:00:04.109`（`:2372`）；Exit 完成为 `15:00:07.292`（`ms` 字段；`:2377`）。
- 管理员日志确认第一次传送发生在 `15:01:31.072`，目标 `10348,12636,0`（`admin.txt:2`）。用户确认这是本次未到过的冷区域，黑屏约 1 秒；先前报的 `15:00:30` 是误记。第二次在 `15:03:06.192` 传至 `10276,9064,0`（`:3`），用户说该地点似乎也未到过。第三次 `15:03:23.443` 返回起始区域（`:4`），只作为辅助返回，不计作冷目标主结果。
- JFR 窗口边界明确为第一次 `[15:01:25,15:01:40)`、第二次 `[15:03:00,15:03:15)`。双方一致的栈帧成员统计为第一次 `ServerMap.preupdate=41`、`ErosionMain.LoadGridsquare=7`，第二次分别为 `41`、`34`；两个窗口均确有 `IsoGridSquare.RemoveTileObject` 栈样本。这里的帧计数表示样本栈中包含该帧，不是 Lua/Java 调用次数或耗时。归档分析记录中，管理员命令后 2 秒窗口的 main 采样最大间隔分别为 `0.363 s`、`0.304 s`。JFR 采样不能观测用户看到的黑屏帧，也不能由栈样本分配引擎、RV 与官方监听器各自耗时。

### 对象移除监听器与相邻周期

服务端 `[PerfTrace] server/object-remove` 原始行（`DebugLog-server.txt:2540–2542, 2652–2654`）给出下列聚合值。`ms` 是诊断计时的累计经过时间 / 单次最大经过时间 / 调用数，属于墙钟经过时间，不是 CPU 时间。

| 冷目标时间窗 | shell-roof-repair | utility-fixture | room-ownership | shell-roof-repair 过滤结果 |
|---|---:|---:|---:|---|
| `15:01:31.577–15:01:32.738` | 717 次，6 ms / 1 ms | 717 次，1 ms / 1 ms | 717 次，5 ms / 1 ms，`hit=0` | `objectRemoveTotal=aboutToRemoveTotal=cheapReject=717`；`candidate=0`、`strictMatch=0`、`repairQueued=0` |
| `15:03:06.896–15:03:08.927` | 3,100 次，27 ms / 1 ms | 3,100 次，14 ms / 1 ms | 3,100 次，32 ms / 1 ms，`hit=0` | `objectRemoveTotal=aboutToRemoveTotal=cheapReject=3100`；`candidate=0`、`strictMatch=0`、`repairQueued=0` |

相邻 `server/boundary` 周期摘要分别为 `15:01:30.019 → 15:01:40.089`，tick `2033 → 2123`（+90，`st` 差 10.069 秒；`DebugLog-server.txt:2494,2537`），以及 `15:03:00.092 → 15:03:10.097`，tick `2836 → 2924`（+88，10.005 秒；`:2588,2649`）。它们是周期汇总，不能给出单个 tick 的最大停顿。客户端相邻 10 秒周期约增加 597–600 tick（`client/DebugLog.txt:1355–1356,1365–1366,1399–1400,1403–1404`），约 60 tick/s；这与用户报告的短暂黑屏不是同一种观测。

### 结论边界与剩余工作

- 本次两个传送窗口没有复现旧记录中的服务端 `56.335 s` 仅前进 2 tick 的停滞，也没有复现旧窗口 `shell-roof-repair` 2,171 次、累计 61,427 ms、单次最大 51 ms 的耗时。旧窗口与本次目标位置、会话及跨会话冷热缓存条件不同或未知，因此本次结果不能称为同条件终验，也不能据此宣布根因已解决。
- `UTILITY_TARGET_NOT_LOADED` 仍在 RV 退出后周期重试。两个目标前后各约 10 秒的 utility 汇总累计经过时间为 `1.3–1.5 s`（通常 3 次失败重试；`DebugLog-server.txt:2496,2539,2590,2651`），应与分钟级 tick 停滞分开看待。
- 本轮单客户端结果未覆盖多人负载，也未实测合法拆除 shell 墙/屋顶的修复流程。P0 范围记录为 `RV_RailroaderServer_RoomRepair.lua` 与 `RV_Server_ObjectRemovalTrace.lua`；诊断埋点继续保留，P1/P2/P3 尚未实施。当前证据支持先停在 P0 并等待更广测试；它没有验证这些未覆盖场景。
