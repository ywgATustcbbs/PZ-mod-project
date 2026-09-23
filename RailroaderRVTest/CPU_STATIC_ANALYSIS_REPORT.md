# RailroaderRVTest CPU 静态分析报告

> 本报告的热点章节记录修复前基线；“已实施修复”章节记录本轮代码变更后的状态。

## 结论

修复前工作树中存在多个明确的高频高计算量路径。玩家进入已生成 RV 后，服务端和客户端都会进入持续监测状态；其中最可能造成明显 CPU 上升的首要原因是：

1. 客户端 stale-room monitor 在 `OnTick` 中永久扫描房间 footprint。
2. 服务端 boundary cleanup 每个 tick 扫描 128 个管理方格，并且完整扫描结束后循环重启。
3. 服务端 boundary 每个 tick 对同一玩家重复执行完整 map/schema/bitmap/geometry gate。
4. Railroader adapter 在没有待处理 roof 事件时，仍然每个 tick 读取并验证完整 RV map；每 5 tick 的 sentinel 又会重复一次。

这些结论来自静态调用链和循环规模，未经过运行时 profiler，所以报告确认的是代码级热点，不宣称已经完成实机 CPU 占比测量。

## 已实施修复

本轮未改变 current-schema、authority、对象归属或 fail-closed 规则，只调整常驻路径的调度和重复工作：

- 客户端 stale-room monitor 保留 guard 安装时的即时扫描，后续 footprint 扫描改为每 30 tick；稳定计时和无效 room 引用清理仍然保留。
- 服务端 room ownership guard 保留生命周期与稳定窗口，但完整 footprint 重扫改为每 30 tick。
- boundary cleanup fallback 从每 tick 改为每 10 tick；`OnProcessAction`、`OnObjectAdded` 和 dirty-cell 审计仍可即时工作。
- `Boundary.onTick` 复用 `updatePlayer` 已解析的 boundary，移除同一玩家同一 tick 的重复 `boundaryForPlayer`/current-schema gate。
- roof-repair adapter 在没有 pending/follow-up 工作时直接返回，不再空闲读取完整 RV map。
- relocation sentinel 先筛选在线玩家是否位于 `z=-15`；没有候选时不进入 map/manifest/geometry gate。
- utility mapping 同步按玩家对象和 mapping epoch 缓存，仅在重连或 `transmitMap()` 后重新解析当前映射。

这些改动已通过现有静态契约和 Lua 语法检查；尚未通过实机 profiler 或联机操作观察 CPU。

## 直接热点

### P0：客户端永久扫描 527 个房间方格

调用链：

`Events.OnTick` -> `Client.onTick` -> `updateRoomOwnershipGuards` -> `refreshInvalidRoomOwnership` -> `eachStructureSquare`。

相关代码：

- [RV_ContextMenu.lua](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_ContextMenu.lua#L161) 定义 7x41 base wall rectangle 和 6x40 roof rectangle。
- [RV_ContextMenu.lua](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_ContextMenu.lua#L183) 对每个方格调用 `getRoom()`、必要时调用 `getRoomDef()`，并创建坐标去重键。
- [RV_ContextMenu.lua](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_ContextMenu.lua#L309) 每次 client tick 执行该扫描。
- [RV_ContextMenu.lua](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_ContextMenu.lua#L622) 无条件调用 `updateRoomOwnershipGuards`。
- [RV_ContextMenu.lua](contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_ContextMenu.lua#L724) 注册了常驻 `OnTick`。

当前布局的单个 footprint 规模是：

```text
7 * 41 + 6 * 40 = 527 个方格
```

`beginRoomOwnershipRefresh` 创建 guard 后，`updateRoomOwnershipGuards` 只更新 `ticks/stableTicks/monitorReady`，没有删除已稳定 guard 的逻辑。也就是说，`monitorReady` 只是状态和日志，不是停止扫描的门。生成时服务端还会向所有连接客户端广播该 guard：[RV_Server.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_Server.lua#L3775)。

因此，单机或多人客户端在完成生成后，即使玩家没有继续移动，也会持续进行约 527 次 `getGridSquare`，以及最多 527 次房间状态检查；按注释中的约 10 Hz 运行频率估算，约为 5270 个方格检查/秒/guard。旧、新 footprint 不重叠时，上限可接近 1054 个方格/tick。

这是与“玩家进入房车区域后 CPU 上升”最吻合的客户端热点。严格来说，当前实现中 guard 一旦安装，扫描不依赖玩家当前是否仍在 RV 内；区域进入、生成完成或重连只是触发该常驻状态的条件。

### P0：服务端 boundary cleanup 是每 tick 的持续全范围扫描

相关代码：

- [RV_Constants.lua](contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RV_Constants.lua#L73) 将 `BOUNDARY_TICK_INTERVAL` 设为 `1`。
- [RV_BoundaryServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_BoundaryServer.lua#L1309) 创建每个 boundary 的共享 cleanup cursor。
- [RV_BoundaryServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_BoundaryServer.lua#L1325) 每次调用固定处理 `budget = 128` 个方格。
- [RV_BoundaryServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_BoundaryServer.lua#L1340) 对每个方格获取多个对象集合并审计对象。
- [RV_BoundaryServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_BoundaryServer.lua#L1350) 每个服务端 tick 驱动玩家检查和 cleanup。

一个 boundary 当前有 100x100x2 = 20000 个 bitmap cell，但 cleanup 实际只在加载的方格上推进 cursor。若管理范围已经加载，单个 RV 每 tick 会执行 128 次 `getGridSquare`，每个方格还会查询 `getObjects`、`getSpecialObjects`、`getWorldObjects`、`getStaticMovingObjects`、`getMovingObjects`、`getDeadBodys` 和 floor。每个完整 100x100x2 范围约 78 个 tick 扫完，然后 cursor 被清空并在下一轮重新开始；因此这是持续循环扫描，而非一次性兜底。

对象集合扫描代码位于 [RV_BoundaryServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_BoundaryServer.lua#L1255)，对象审计入口位于 [RV_BoundaryServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_BoundaryServer.lua#L1027)。当方格内有对象时，审计还会读取坐标、modData、tag、footprint、shell ledger 和 bitmap buildability。

这条路径只有在 `activeBoundaries` 中出现已映射的 RV 时执行；`Boundary.onTick` 会先以玩家身份解析 boundary，再把它加入 active set：[RV_BoundaryServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_BoundaryServer.lua#L1368)。所以它正是“玩家在 RV 内”时服务端负载持续升高的直接候选。

### P0：每 tick 重复完整 current-schema geometry gate

`Boundary.onTick` 对每个在线玩家调用一次 `updatePlayer`，而 `updatePlayer` 内部调用 `Boundary.boundaryForPlayer`：[RV_BoundaryServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_BoundaryServer.lua#L662)。随后 `onTick` 为建立 `activeBoundaries` 又再次调用 `Boundary.boundaryForPlayer`：[RV_BoundaryServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_BoundaryServer.lua#L1368)。因此每个玩家每个 tick 至少重复一次同样的完整解析。

`Boundary.boundaryForPlayer` 委托到 [RV_RailroaderServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua#L931)。该函数每次都：

- 读取 `ModData` 并调用 `mapData()`；
- 通过 `validateMapSchema` 验证所有 locomotive record 和 player relation；
- 重新验证当前 record；
- 读取并验证当前 manifest；
- 调用 `currentRVRecordGeometryConsistent`。[RV_RailroaderServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua#L962)

geometry gate 位于 [RV_Server.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_Server.lua#L4261)。它会重新 decode record/manifest bitmap，比较每个 z layer 的 packed bitset，比较 92 条 shell edge，并再次运行 manifest validity 检查。bitmap decode 本身会把每层 hex 字符串重新转换为 bytes：[RV_Bitmap.lua](contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RV_Bitmap.lua#L326)。`loadedBoundary` 即使命中 process-local cache，也会先 decode，再执行 geometry 比较：[RV_BoundaryServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_BoundaryServer.lua#L397)。

这不是一次昂贵检查，而是被放到了常驻移动保护的最外层。一个已在 RV 内的玩家因此会在每个 server tick 触发两次完整 schema/geometry 路径，且该路径没有按 tick、map generation 或 geometry identity 做结果缓存。

## 服务端叠加热点

### P1：空闲状态仍每 tick 读取 RV map

Railroader adapter 单独注册了一个 `OnTick`：[RV_RailroaderServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua#L3682)。该 tick 首先调用 `processPendingWallRoofRepairs`：[RV_RailroaderServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua#L3686)。在没有 generation transaction 的正常状态下，该函数仍会进入 `mapData()`，然后才遍历 pending queue；即使 queue 为空，也没有早退。

`mapData()` 从 [RV_RailroaderServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua#L693) 读取 map，并通过 [RV_RailroaderServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua#L885) 的 schema validation 重新校验全部 mapping。

这里的报告路径链接以实际文件为准，正确引用是：[RV_RailroaderServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua#L693) 和 [RV_RailroaderServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua#L885)。

### P1：每 5 tick 的 relocation sentinel 在无候选时也做 map gate

`Adapter.OnTick` 每 5 tick 调用 `processStatelessRelocationSentinel`：[RV_RailroaderServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua#L2449)。该函数先读取完整 `mapData()`，再枚举在线玩家并检查是否有人位于 `z=-15` sentinel：[RV_RailroaderServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua#L2477)。绝大多数 tick 没有 sentinel 候选，但完整 map/record/bitmap 验证仍已经发生。

### P1：room ownership server guard 在稳定窗口内每 tick 扫 footprint

服务端 generation 会注册 guard：[RV_Server.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_Server.lua#L3777)。`processServerRoomOwnershipGuards` 每 tick 调用旧/新 bounds 的结构扫描：[RV_Server.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_Server.lua#L145)。当前稳定策略要求至少 1800 tick 后才允许结束，最大生命周期为 7200 tick：[RV_Server.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_Server.lua#L121)。按代码注释使用的约 10 Hz 估算，至少持续约 3 分钟，异常或不稳定时可持续到约 12 分钟。

这与客户端永久 monitor 叠加，生成后短期 CPU 峰值会特别明显。

### P2：每 30 tick 的 utility 同步/结算会再次进入完整 gate

Utility server 每 tick 被 facade 调用，但每 30 tick 会同步在线玩家 utility mapping，并进入 water settlement：[RV_UtilityServer.lua](contents/mods/RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_UtilityServer.lua#L332)。具体分支位于 [RV_UtilityServer.lua](contents/mods/RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_UtilityServer.lua#L335) 和 [RV_UtilityServer.lua](contents/mods/RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_UtilityServer.lua#L337)。

`syncUtilityMappings` 对在线玩家重新调用 `resolveCurrentUtilityRV`，inside RV 时会重新走 boundary/current geometry gate：[RV_RailroaderServer.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua#L1928)。结算路径会读取全部 utility records：[RV_UtilityStore.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_UtilityStore.lua#L493)，并对 registry 中每个 fixture/proxy 做对象定位和水量收集：[RV_UtilityWater.lua](contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_UtilityWater.lua#L665)。当前测试通常只有少量 utility entry，所以它不是第一嫌疑，但会周期性放大主热点。

## 次要路径

客户端 boundary 还同时注册 `OnPlayerUpdate`、`OnTick`、`OnRenderTick`：[RV_BoundaryClient.lua](contents/mods/RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_BoundaryClient.lua#L358)。`OnRenderTick` 会再次调用玩家 boundary prediction。这个路径主要是 packed bitmap 的 scope/active/segment 判断，没有 527 方格 world scan，因此相对上述 room monitor 较轻，但仍会重复做移动状态处理，值得在后续 profiling 中确认。

生成、rollback、roof refresh 的 100x100 清场、对象枚举和 recalc 也很重，但它们是阶段性工作，不是玩家稳定停留在 RV 内时的首要常驻原因。

## 建议方案

### 第一优先级：把 room ownership monitor 改为事件/状态驱动

保持 current-schema 和 fail-closed 规则不变，调整生命周期：

1. guard 安装时立即扫描一次。
2. 只在 generation、wall removal、floor/roof mutation、reconnect 或服务端明确下发 refresh token 后启动有限的稳定窗口。
3. 稳定窗口结束后停止扫描；`monitorReady` 应真正成为扫描门，而不只是日志字段。
4. 已知异步 region rebuild 的窗口内使用有限次数或有限 tick 的重扫；不要对 READY RV 永久每 tick 扫描。
5. 客户端 guard 只接受服务端发送的当前 `rvId:generation:bitmapVersion` 和 bounds，不从旧本地状态推导 geometry。

服务端已有对象移除事件和 dirty action 入口，应优先将这些作为 refresh trigger，而不是保留全范围轮询。若必须保留 fallback，应改为低频、单轮、可被 mutation epoch 重新激活的 cursor。

### 第二优先级：按 tick/identity 缓存 current geometry proof

建议在 `RV_Server` 建立 process-local current snapshot，至少复用以下结果：

- 当前 map/schema 验证结果；
- 当前 manifest/record/boundary 对应的 decoded bitmap；
- `rvId:generation:bitmapVersion` 对应的 geometry proof。

缓存只能在同一个 server tick 或明确未发生 ModData/world identity mutation 的 epoch 内复用；generation、manifest、mapping、boundary 或 shell ledger 写入后必须显式失效。这样不会引入旧 schema 兼容，也不会以旧 geometry 执行世界操作。

同时让 `Boundary.onTick` 的 `updatePlayer` 返回已解析的 boundary，避免紧接着再次调用 `Boundary.boundaryForPlayer`。`loadedBoundary` 也应在当前 snapshot 有效时直接复用已 decode 的 boundary，不要每次先 decode 再比较完整 bitmap 和 92 条 edge。

### 第三优先级：让 cleanup 只响应 dirty/mutation

当前 `Boundary._dirty` 已经存在，但完整 cleanup 仍由 `BOUNDARY_TICK_INTERVAL = 1` 驱动。建议：

- generation 完成后允许一次有限的完整 audit；
- `OnProcessAction`、`OnObjectAdded` 和已确认的当前 RV mutation 只审计受影响 cell/footprint；
- 只有 dirty epoch 变化时才重新启动 cursor；
- 若需要防漏的低频 fallback，限制为一轮扫描并设置足够大的间隔，不要扫完立即重启。

审计仍必须保留当前 owner/tag/shell ledger/buildBits 证明；不明确归属的对象继续 fail-open。

### 第四优先级：修掉无意义的空闲 map 读取

这是低风险、高收益的调度调整：

- `processPendingWallRoofRepairs` 在 follow-up 和 pending queue 都为空时直接返回，不进入 `mapData()`；
- sentinel 先以廉价的在线玩家位置检查筛选 `z=-15` 候选，再对候选 RV 执行完整 map/manifest/geometry gate；
- utility mapping 只在连接、mapping identity 变化或显式请求时发送，不要每 30 tick 对所有在线玩家重发；
- water fixed-tick fallback 只处理有 active/deferred/pending 状态的 utility record，无变化时跳过对象级 projection。

### 第五优先级：合并或门控客户端移动回调

保留必要的即时预测，但避免 `OnPlayerUpdate` 与 `OnRenderTick` 对同一玩家重复执行完整逻辑。可以按 position/current-square 变化、snapshot generation 和 last processed render tick 做轻量门控；不应因此把客户端可信状态提交给服务端。

## 推荐验证顺序

本次只做静态分析，没有启动游戏或修改 Lua。现有静态检查已通过：

```text
python RailroaderRVTest/tests/test_rv_server.py
退出码：0
```

实现修复后，建议按以下顺序验证：

1. 为 `mapData`、`currentRVRecordGeometryConsistent`、`Boundary.onTick`、cleanup、room guard 和 utility settlement 加计数/耗时日志，确认 steady-state 每秒调用数。
2. 生成 RV 后静置，分别观察客户端 Lua CPU、服务端 tick duration 和每秒 world API 调用数。
3. 移动、建造、拆墙、重连各一次，确认 room guard 只在相关 mutation 窗口重新激活。
4. 最后运行仓库要求的一键整体测试 `python testserver/run_test.py`，再由用户完成联机操作观察 boundary、roof refresh、回传和 room safety。

## 修复前最终判断

最可能的首要根因是“常驻 room footprint 扫描 + 常驻 boundary cleanup”，而不是 `Bitmap.isActive` 或单次几何计算本身。服务端重复 current-schema geometry proof 和 adapter 的空闲 `mapData()` 又把同一成本叠加了多次。

本轮已停止每 tick 的 room footprint 重扫和 boundary cleanup，消除了空闲 roof queue/sentinel 的完整存档验证，并移除了 boundary tick 内的一次重复解析。剩余的 current-schema gate、每 5 tick 的 sentinel 在线位置筛选、每 30 tick 的 water settlement 和低频 cleanup 都需要通过运行时耗时日志确认实际占比；本报告不把静态降频等同于实机 CPU 验收。