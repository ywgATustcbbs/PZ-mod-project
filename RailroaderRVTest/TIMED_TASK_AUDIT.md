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
