# RoofRefresh 目录模块分析

## 前提、范围与验收

- 假设：分析范围严格限于 `media/lua/server/RailroaderRV/RoofRefresh/` 的全部 Lua 文件；代码只读。本报告是该目录报告，不代替最后的全局总结。
- 函数口径：统计外层工厂函数、具名/local 函数、函数赋值、嵌套函数和匿名函数表达式，包括 `pcall` / 坐标遍历传入的闭包。只把传给本模块的源码定义算作目录函数，ctx 中的外部函数作为依赖说明。
- 成功条件：7 个文件全部纳入；每个函数列出声明行、参数语义、作用、副作用/输出及当前必要性；给出跨模块复用、拆分建议、内部数据访问/API收益判断；最终函数数与源码扫描数量相符，报告结构和行号可回查。
- 只读验证：文件清单、`function` 源码扫描、声明/闭包逐行复核、文档链接与函数数检查。不读写源码，不运行 runtime 测试。

## 目录职责概览

此目录承担 Railroader RV 的屋顶/动态房间更新完整生命周期。七个文件按职责分为四段：

1. `RV_RoofRefresh.lua`：共享于服务端的就绪性查询和单个已捕获地板的房间/屋顶元数据刷新。
2. `RV_RailroaderServer_RoofRefresh.lua` 与 `RV_RailroaderServer_RoofRefreshFlow.lua`：Railroader 适配层。前者观察玩家、墙体移除事件并排队；后者推进多玩家远程卸载/返回/刷新状态机。
3. `RV_Server_RoofDestinations.lua`、`RV_Server_RoofRelocation.lua`、`RV_Server_RoofApi.lua`：服务端事务层。分别计算/验证目的地与回滚，执行成组搬运及边界租约，向调用者提供事务 API。
4. `RV_Server_RoomOwnership.lua`：动态 IsoRegions 重建后，扫描并清理无效的 IsoRoom 引用；同时管理服务端回滚防护和客户端重查命令。

下文将函数按文件列出。标为“需要”表示当前功能链有明确调用方或安全/生命周期责任；标为“可合并”只表示实现有复用空间，不表示可删除。

## 1. 共享房间刷新 `RV_RoofRefresh.lua`

文件导出 `RailroaderRV.RoofRefresh.isLoaded` 与 `run`，并用 `_busy` 阻止并发刷新。它不生成/删除地板对象，只检查当前模板规定的唯一 captured floor 身份，在原地同步房间、屋顶邻居和 IsoRegions 状态。

| 行 | 函数与输入参数 | 功能、模块语义、输出/副作用 | 当前是否需要及原因 |
|---|---|---|---|
| 25 | `toNumber(value)`；value 可为数字、字符串或引擎数值包装 | 安全转成 number；转换失败为 nil。供坐标、身份字段统一解析。 | 需要；容纳 Lua/Java 绑定数值并拒绝不可解析值。 |
| 29 | 匿名闭包 `function()`；无显式参数，捕获 value | 保护 `value + 0` 的引擎 userdata 强制转换；由 pcall 返回转换结果或异常。 | 需要；防止 Java 数值包装转换异常逸出。 |
| 33 | `invoke(target, method, ...)`；对象、方法名、方法参数 | 检查方法存在并以 target 为 self 保护调用；返回调用成功标志、至多两个方法值，失败时返回异常值。 | 需要；所有 Iso 对象调用使用同一异常边界。 |
| 38 | `invoke` 内匿名闭包；无显式参数，捕获 target/method/args | 执行对象方法并保留多返回值；由 pcall 捕捉引擎异常。 | 需要；是 invoke 的保护实现。 |
| 45 | `callGlobal(name, ...)`；全局函数名、参数 | 从 `_G` 取函数并以 pcall 调用；返回是否成功及首返回值/错误。 | 需要；全局引擎 API 可能缺失或抛错。 |
| 49 | `callGlobal` 内匿名闭包；无显式参数，捕获 fn/args | 调用全局函数，供 pcall 隔离异常。 | 需要；保证该封装实际捕获错误。 |
| 54 | `callSucceeded(target, method, ...)`；对象、方法、参数 | `invoke` 成功且首返回值不为 false 时返回 true，否则 false；不抛出引擎方法错误。 | 需要；把多个必须成功的世界同步操作转为 fail-closed 布尔门。 |
| 59 | `integer(value, label)`；待检值、诊断字段名 | 转数值并要求数学整数；非法时报带字段名的错误，合法返回整数。 | 需要；几何边界不能接受小数或缺字段。 |
| 68 | `getCell(player)`；玩家 | 先取玩家 cell，再取全局 cell；都不可用则 nil。 | 需要；刷新只作用在玩家当前服务端 IsoCell。 |
| 76 | `getSquare(cell, x, y, z)`；cell 与格坐标 | 安全调用 `getGridSquare`，返回 square 或 nil。 | 需要；供加载检测与刷新取得当前格。 |
| 81 | `worldSquareIsValid(x, y, z)`；世界格坐标 | 若 getWorld 不可用视为未能判非法；有 world 时要求 isValidSquare 结果为 true，调用不可用也按可用处理。 | 需要但契约较宽；上游仍会要求 square 已加载，无法用此替代 schema 几何验证。 |
| 88 | `roomRefreshFloorTarget(bounds)`；当前房间 bounds | 校验 roomMinX/Y、z 为整数，套用常量锚点偏移及 RoomTemplate 的屋顶刷新目标，返回含 kind/坐标/templateIndex/identity 的目标描述。 | 需要；目标必须来自当前模板而非推测坐标。 |
| 107 | `recalcSquare(cell, square)`；当前 cell、已捕获 floor 所在 square | 按序执行 EnsureSurroundNotNull、RecalcProperties、checkHaveRoof、clearWater、RecalcAllWithNeighbours、IsoRegions.squareChanged，并可触发灯光重算；返回成功或原因。 | 需要；这是世界状态刷新本体，且中途失败必须上报。 |
| 124 | `recalcSquare` 内匿名闭包；无显式参数，捕获 IsoRegions | 在 pcall 中读取 `IsoRegions.squareChanged`，返回该方法。 | 需要；引擎绑定静态属性读取也可能出错。 |
| 143 | `loadedRefreshSquares(player, bounds)`；玩家、当前 RV 边界 | 要求有效 bounds 和 cell，遍历完整墙格并检查模板目标地板格的世界合法性和加载状态；返回布尔及原因。 | 需要；在触发异步远程往返前证明刷新所需格已加载。 |
| 150 | `requireSquare(x, y, z, role)`，嵌于 `loadedRefreshSquares`；格坐标、诊断角色 | 坐标去重；检查世界合法与 `getGridSquare` 存在，返回布尔及具体失败原因。 | 需要；避免墙格和目标格缺块时误报就绪。 |
| 183 | `Refresh.isLoaded(player, bounds)`；玩家、边界 | pcall 包装加载检测；返回 `loaded == true, reason`，异常变成文本原因。 | 需要；对外的只读 readiness 接口。 |
| 189 | `diagnosticValue(value)`；任意值 | 安全 tostring 并压平 CR/LF；nil/不可打印时返回占位串。 | 需要；身份拒绝诊断须安全且单行。 |
| 196 | `identityTagSummary(tag)`；ModData 标签 | 将 owner、rvId、generation、bitmapVersion 拼为诊断文本；非表返回 missing。 | 需要；区分顶层/嵌套身份标签错误。 |
| 204 | `capturedFloorMismatch(floor, target, identity)`；捕获对象、模板目标、RV 身份 | 校验当前 bitmap schema identity、精确 sprite、生成标签和模板索引/类别/名称/朝向字段；匹配返回 nil，否则返回逐字段原因。 | 需要；刷新之前及之后拒绝误碰玩家建造或过期对象。 |
| 267 | `capturedFloorMatches(floor, target, identity)`；同上 | 将 mismatch 检查转为布尔匹配结果。 | 需要；后刷新复核时复用同一完整身份合同。 |
| 272 | `reportFloorIdentityMismatch(target, identity, detail)`；目标、身份、拒绝原因 | 以 RV 身份为键抑制完全重复日志，输出坐标和失败字段；不改变世界对象。 | 需要；保护诊断可读性，去重仅影响日志。 |
| 288 | `refreshRoomMetadata(player, bounds, identity)`；玩家、边界、当前身份 | 再取 cell/模板目标，校验世界格和 floor 身份，执行 recalc，再确认 floor 仍是同一个对象且标签有效；返回同步结果和诊断。 | 需要；将身份门、刷新、后置完整性校验串成原子语义步骤。 |
| 323 | `Refresh.run(player, bounds, identity)`；同上 | `_busy` 时拒绝；否则加锁、pcall 调用刷新本体、解锁；返回成功与原因。 | 需要；服务端入口必须序列化，并保证异常后解锁。 |

## 2. Railroader 事件适配 `RV_RailroaderServer_RoofRefresh.lua`

该文件是回调/观察入口，不直接修改 RV 几何。它将对象事件严格匹配到当前 shell wall、收集服务端权威在线玩家、按 RV 身份排队，并处理临时传送 z 层的无状态哨兵。文件结尾把可跨 factory 使用的 helper 放入 ctx；ctx 字段同时也是本文件访问状态的内部合同。

| 行 | 函数与输入参数 | 功能、模块语义、输出/副作用 | 当前是否需要及原因 |
|---|---|---|---|
| 2 | 外层 factory `function(ctx)`；ctx 为服务端适配器共享状态/依赖表 | 文件返回该 factory；调用时捕获服务端接口、状态表和策略常量并注册 Adapter 回调与 ctx helper，factory body 不返回值。 | 需要；由主服务装配器注入依赖，避免此文件自行创建事务状态副本。 |
| 29 | `recordForLoco(...)`；原样转发 ctx.lookup 参数 | 代理 ctx 中的当前 RV 记录查询，输出由该 lookup 决定。 | 需要；在本 factory 内形成方便引用的依赖别名。 |
| 33 | `serverTransactionMutexStatus(...)`；无固定参数，转发 ctx 参数 | 查询 generation/roof 事务占用与原因，原样返回。 | 需要；排队前必须遵守 service-wide mutex。 |
| 59 | `playerPositionInRegion(player, region)`；玩家和半开区域边界 | 服务端读取 x/y/z，将 z 按楼层比较，验证 x/y/z 在区域范围，返回坐标快照或 nil。 | 需要；区分是否真的在 RV managed region。 |
| 84 | `processStatelessRelocationSentinel()`；无参数，使用当前 tick/在线玩家 | 周期扫描 z=-15 玩家；清除离线 identity 的冷却表；查服务器事务和当前 mapping；对未被事务认领的当前身份请求返回 RV，并对错误/重复尝试限频告警。 | 需要；处理服务重启、异步故障后残留在临时层的玩家；依赖服务端状态重新确认身份。 |
| 214 | `authoritativeRoomState(player)`；服务端玩家对象 | 从当前 square 读取 isInARoom 作为动态房间权威态，附 room/roomDef 是否存在作诊断；不全则 nil。 | 非核心；当前结果只用于 room transition 诊断日志，不参与事务门限。 |
| 230 | `sampleRoofRefreshPlayers(map)`；当前已校验 map | 遍历在线玩家，筛 RV 区域及 inside rider，按房间聚合房间状态；识别 reconnect/首次出现并 armed room ownership guard；没有同 room relocation 时调用刷新入口；清除离线 presence 缓存并预热边界玩家。 | 需要；将进入、重连和房间监视接到 RoofRefresh 状态机。 |
| 323 | `scheduleRoofRefresh(map, record, source, eventKey, coordinateKey)`；map、当前 RV record、事件来源与稳定去重键 | 通过 record/事务/共享 scope/抑制状态门限，捕获权威 inside players 和身份，创建 queued pending group（起始、deadline、身份、事件键和返回位置）；返回是否成功。 | 需要；提供事件适配器和 follow-up 流程共用的唯一排队入口。 |
| 399 | `rememberFollowUpWallRemoval(record, roomKey, eventKey, coordinateKey, now, waitingForGeneration)`；RV、房间键、稳定事件键、tick 与 generation 等待标记 | 对同 room 次级对象事件去重并限长，存入带过期 tick 的 follow-up ledger；返回是否接纳。 | 需要；并发事务或活动组期间不得静默吞掉另一项墙体操作。 |
| 432 | `pauseFollowUpWallRemovalDeadlines(now)`；tick 或 nil | 将达到过期点的 follow-up 标成 waitingForGeneration，冻结其事件寿命，返回 nil。 | 需要；generation 占用时保留已接受操作，避免过期后丢事件。 |
| 462 | `cheapShellWallCandidate(object)`；即将移除的世界对象 | 先要求 host square、thumpable/window 类型、对象索引和双层 owner/rvId/generation/bitmapVersion 标签完整，再限于 wall-north/wall-west/corner-nw；返回候选布尔。 | 需要；便宜前置过滤，禁止仅凭坐标或客户端意图把任意对象当壳墙。 |
| 501 | `queueWallRoofRefreshForObject(object, source)`；对象、事件来源 | 排除模板保护修复对象；通过候选检查后，当前 mapping 中必须唯一匹配 `Boundary.isCurrentShellWall`；生成 stable event/coordinate key，去重，活动组时保留 bounded follow-up，mutex 忙时延后，否则排队。输出排队布尔并写内存 ledger/日志。 | 需要；连接世界对象移除事实与 roof refresh，不接受客户端坐标。 |
| 626 | `Adapter.onObjectAboutToBeRemoved(object)`；引擎将移除对象 | 以 `object-about-to-be-removed` 来源调用队列入口；无显式返回。 | 需要；覆盖普通对象移除及 B42 锤毁路径。 |
| 634 | `Adapter.onDestroyIsoThumpable(object)`；引擎销毁的 thumpable | 以独立来源调用相同 matcher/去重路径；无显式返回。 | 需要；补充直接 thumpable destroy 路径，去重避免与上个 hook 双排。 |
| 642 | `insidePlayersForRecord(map, record)`；当前 map、RV record | 服务端遍历在线玩家，要求区域内、alive、map 与 record 双侧 rider relation 为 inside、loco/onlineId 匹配；返回含对象引用、stable identity 和原位置副本的数组。 | 需要；成组移动前先由服务端抓取完整成员和返回位置。 |
| 677 | `observeRoomTransitions(map, observedRooms)`；当前实现未使用的 map 参数、观察到的 room 状态 | 更新 roomTransitionStates 并记录 inside→outside 诊断；清理缺少 presence 的 room/pending 状态，保留已启动 relocation。当前 pending 的缺席清理又在第二个循环独立执行。 | 非核心/可简化；转场记忆仅服务诊断，room-state 清理重复；保留 pending 缺席取消逻辑即可维持任务语义。 |

### 该文件的状态和边界

- 本文件直接读写 ctx 注入的 `roofRefreshPlayers`、`roomMonitorPlayers`、`pendingWallRoofRefreshes`、`followUpWallRemovalEvents`、`roomTransitionStates`、`suppressedRoomTransitions`、`seenWallRemovalEvents` 及 sentinel 冷却/告警/忙碌表。这些是与 Flow 共享的私有运行时状态，不是存档 schema。
- `RailroaderRV.Server` 的 `isRelocationIdentityClaimed`、`currentRVManifestForRelocation`、`isGenerationTransactionActive`、`isRoofRefreshTransactionActive` 是跨模块查询接口。唯独 `_templateProtectionRepairRemovalObject` 是另一个服务模块的下划线内部字段直读（行 502–505）；若所有者模块无法提供更高层对象匹配接口，可接受当前一次相等性过滤，单独加接口收益很低。
- map.players / map.locomotives / record.players 是领域数据，不是其他 Lua 模块私有变量；但字段解析规则仍依赖共享 mapping schema 的当前合同。

## 3. RoofRefresh 调度状态机 `RV_RailroaderServer_RoofRefreshFlow.lua`

该文件管理 queued → temporary → refreshing → returning → complete 的 adapter 侧阶段，所有组成员返回并完成服务端 acknowledgement 后才调用房间刷新并退休 schedule。和 `RV_Server_RoofRelocation.lua` 形成两端协作：此处管理业务阶段及房间队列，服务端事务模块管理移动/Boundary lease。

| 行 | 函数与输入参数 | 功能、模块语义、输出/副作用 | 当前是否需要及原因 |
|---|---|---|---|
| 2 | 外层 factory `function(ctx)`；调度器状态/依赖表 | 文件返回该 factory；调用时捕获 queue、tick 和操作接口，并把本模块操作写回 ctx，factory body 不返回值。 | 需要；由服务装配器将本模块连到 Adapter/事务层。 |
| 19 | `recordForLoco(...)`；原样转发查找条件 | 调用 ctx 中的当前 RV record lookup。 | 需要；状态机需逐 tick 重新解析当前记录。 |
| 20 | `insidePlayersForRecord(...)`；原样转发 map/record | 取当前 inside 玩家快照。 | 需要；重新校验身份/玩家绑定。 |
| 21 | `scheduleRoofRefresh(...)`；原样转发 map/record/event 元数据 | 调用唯一 queued schedule 创建入口并原样返回。 | 需要；follow-up 晋升也使用相同排队规则。 |
| 36 | `currentPendingRoomKey(roomKey, pending)`；候选键、pending 对象 | 优先检查候选键当前仍指向同一 table，否则在 map 中按 table identity 找到当前键；返回键或 nil。 | 需要；避免清理/完成已被替换的交易。 |
| 46 | `cancelPendingWallRoofRefresh(roomKey, pending, reason)`；候选房间、pending、理由 | 确认 pending 仍为当前项；若服务端可能持有 lease，则调用取消 API；退休排队项，必要时通知尚未搬运的在线成员失败。返回布尔。 | 需要；对所有取消路径维持服务端 lease 与 adapter map 一致。 |
| 119 | `finishCompletedRoofRefresh(map, pending, record)`；当前 map、已完成 pending、当前 RV record | 只接受 relocationPhase=complete 且 map 仍持有此 pending；清理当前项，若 identity 仍有效则晋升 follow-up。返回布尔。 | 需要；唯一完成退休点，并串行处理后续墙体事件。 |
| 148 | `tickText(tick)`；tick | 当前 schema tick 格式化，非法为 unknown。 | 诊断辅助；只用于 due tick 日志，可内联或留作可读性 helper。 |
| 153 | `tickAfter(tick, delta)`；tick 与增量 | 调用 Core.tickAdd；不能得到当前 tick schema 时抛错，否则返回 tick。 | 需要；所有期限都采用 64-bit tick helper，防止无效 deadline。 |
| 164 | `expireQueuedWallRoofRefreshes(now)`；当前 tick | 仅检查未开始且无 token 的 queued 组；缺失/到期 deadline 调用取消；已等待 generation 的 deadline 不消费。 | 需要；限制从未开始的玩家重绑等待，且不误退活动 lease。 |
| 184 | `processPendingWallRoofRefreshGroup(map, pending, record, server, now)`；当前 mapping、单组状态、公共服务、tick | 驱动完整组状态机：等待/开始临时位移，消费抵达，跨 tick 空间卸载等待，开始返回，逐成员完成服务器归位，确认格加载后刷新房间并 ack；硬失败取消。通过修改 pending 推进阶段，无直接返回值。 | 需要；把事件排队落实为有屏障、可重试、成员全体归位后刷新的事务。 |
| 465 | `beginRoofRefreshPhase(player, pending, phase)`；兼容的 player 参数（本实现未使用）、pending、temporary/return 阶段 | 将组成员解析成服务端 descriptor，并调用 `RV.Server.beginRoofRefreshRelocationGroup`；输出成功与 token/原因。仅对组结构分支有实现。 | 需要；adapter 状态机需要受服务端验证的移动入口。 |
| 500 | `promoteFollowUpWallRemoval(map, roomKey)`；当前 map、已释放房间键 | 当前无活动组时扫描去重事件；删除坏/过期项，重验证当前 mapping；generation 后重键并重开 lease；能排队时晋升首个事件，返回是否晋升。 | 需要；保留并串行执行活动事务期间的新墙操作。 |
| 611 | `revalidateQueuedRoofRefreshAfterGeneration(map, roomKey, pending, now)`；当前 map/key/queued 状态/tick | generation 占用后再校验 RV 身份；可保留等待、过期、迁移到新 roomKey、冲突时转 follow-up，或用新 inside 玩家重建原 pending；返回 ready/wait/expired/revalidated。 | 需要；拒绝用旧 generation 的返回坐标或 schema 继续 relocation。 |
| 713 | `clearRoofRefreshRuntimeState()`；无参数，使用当前服务状态 | 要求可取消 roof group，取消后清空 roof 队列/缓存/转场/去重运行态；不会清理世界或 ModData；服务缺失或取消失败时报错。 | 需要；mapping schema 被拒绝时必须使 roof-only runtime cache 失效并先交还服务端 lease。 |
| 729 | `clearEntries(state)`，嵌于 `clearRoofRefreshRuntimeState`；一个可清空 map | 将传入运行时 map 的全部 key 置 nil；无返回值。 | 需要；重复的表清空逻辑局部化，避免漏清一个 roof-only map。 |

### 状态接口

- `pendingWallRoofRefreshes`、`followUpWallRemovalEvents` 及 presence/monitor/transition/suppression/dedupe 表通过 ctx 在前一个 Adapter 文件和本文件间共享并被两边直接写入。两者是同一调度状态机的拆分实现，ctx 私有函数/状态接口比公开 `RV.Server` API 更合适；若进一步模块化，应把 pending map 封装为专用队列对象以集中不变量。
- 本文件以 `RV.Server` 的 `cancelRoofRefreshRelocation`、`beginRoofRefreshRelocationGroup`、`roofRefreshRelocationGroupReady`、`consumeRoofRefreshRelocationArrival`、`completeRoofRefreshRelocation`、`roofRefreshSquaresLoaded`、`completeRoofRefresh` 作为事务边界接口，没有直接写服务端 relocation group 内部状态。

## 4. 服务端 Roof API `RV_Server_RoofApi.lua`

该文件向适配器暴露跨模块查询、确认、取消方法；群组成员状态和 Boundary read proof 被封装为 RV.Server API。模块同时直接读同一服务 ctx 内的活动交易数据。

| 行 | 函数与输入参数 | 功能、模块语义、输出/副作用 | 当前是否需要及原因 |
|---|---|---|---|
| 2 | 外层 factory function(ctx)；RV.Server 服务装配 context | 文件返回该 factory；调用时捕获 transaction 内部 helper/state，并在 RV.Server 上安装 API，factory body 不返回值。 | 需要；提供稳定跨模块接口。 |
| 9 | safeErrorText(...)；原样转发任意错误 | 调 ctx 中的错误文本规整函数。 | 需要；在 readiness pcall 失败路径将异常转可读原因。 |
| 10 | requireCurrentManifest(...)；原样转发 manifest 查询参数 | 调 ctx 中的当前 manifest 必需查询。 | 当前未使用；源码中只有定义，没有函数体内调用，属于可移除的死代理。 |
| 24 | RV.Server.consumeRoofRefreshRelocationArrival(player)；权威玩家对象 | 通过 group member 查找并重新 resolve live player；仅对已到达且未消费成员标记 arrivalConsumed 后返回 member，否则 nil。 | 需要；防止一个 arrival 被多次消费或旧对象继续推进组阶段。 |
| 36 | RV.Server.roofRefreshRelocationGroupReady(rvId, generation, bitmapVersion)；当前 RV identity | 要求 group identity 一致、phase=temporary 且全员 arrived，返回布尔。 | 需要；Flow 的全体临时位移屏障。 |
| 48 | RV.Server.isGenerationTransactionActive()；无参数 | 返回 pendingGeneration 存在或 transactionBusy。 | 需要；sentinel 和 RoofRefresh 共享 scope 前置锁。 |
| 52 | RV.Server.isRoofRefreshTransactionActive(_rvId)；可选 RV id（当前刻意忽略） | 查活动 group 和 final-return group，状态损坏也视为 busy；返回忙碌布尔及诊断。 | 需要；全服务 scope 只有一个事务，不能按别的 rvId 绕过锁。 |
| 57 | busyGroup(group)，嵌于 isRoofRefreshTransactionActive；一个内部 group 状态 | nil 表示空闲；损坏表/缺失 rvId 视为未知忙碌；有效表返回 busy 及 reason。 | 需要；对坏状态 fail-closed。 |
| 87 | RV.Server.isRelocationIdentityClaimed(identityKey)；stable onlineID:username key | 检查 generation、活动 relocation group 和 final return owner 是否占用该 identity；返回 true/false，无法验证状态时 nil。 | 需要；哨兵不与活动中的玩家 transaction 竞争。 |
| 91 | groupClaims(group)，嵌于 identity 查询；一个 group | 校验 members 数组与每个 identityKey，查目标成员；true/false/nil 表示占用/未占用/状态坏。 | 需要；group 身份状态不完整时不得返回“未占用”。 |
| 134 | RV.Server.getRoofRefreshRelocationState(rvId, generation, bitmapVersion, token)；identity 与令牌 | 回报匹配 group 的 active+phase、匹配失败记录的 failed+reason，否则 idle。 | 需要；本目录内未看到调用点，但作为状态查询接口给同服务事务流程/诊断使用；需核全局 callers 后才能判死代码。 |
| 151 | RV.Server.isRoofRefreshBoundaryReadAllowed(rvId, generation, bitmapVersion, identityKey)；身份和成员 key | 仅 return phase 且成员完成后，验证 server authoritative return ack proof 的 identity、token、generation 和坐标精确匹配 target。 | 需要；允许 Boundary 在归位后重新读取 RV 边界的强证明门。 |
| 184 | RV.Server.isRoofRefreshBoundaryContextReadAllowed(rvId, generation, bitmapVersion, identityKey)；身份与成员 key | 仅 temporary/return phase 下，要求 group 与 member 的 RV/generation/version/key 全匹配；返回是否可读事务上下文。 | 需要；供关联边界查询在移动期间确认本组成员身份。 |
| 206 | RV.Server.consumeRoofRefreshRelocationFailure(rvId, generation, bitmapVersion, token)；失败交易身份/令牌 | 匹配一次性 failure 记录后取原因并清除，返回 reason；不匹配为 nil。 | 需要；确保失败信号按 token 被消费一次。 |
| 221 | RV.Server.completeRoofRefreshRelocation(player, token)；服务端玩家对象、组令牌 | 只接受 return phase 对应成员；重新绑定身份/current context；检查/必要时重申精确服务端坐标，证明当前 square；完成 Boundary lease，保存权威 return proof，最后返回成功/原因。 | 需要；服务端归位 ACK 是 lease 释放和后续房间刷新先决条件。 |
| 316 | RV.Server.completeRoofRefresh(player, token)；代表成员与回程 token | 要求组内全员完成且每个成员身份/context/proof/target 均仍有效，设置全员 refreshCompleted 并清除活动组；返回成功与代表 context reason。 | 需要；唯一事务完成/释放 service-wide RoofRefresh 状态的 API。 |
| 372 | RV.Server.cancelRoofRefreshRelocation(reason)；可选取消原因 | 有 group 时调用统一失败/返回处理并 true；无 group 返回 false 与说明。 | 需要；Adapter 清理排队状态前须先让服务端处理持有中的 Boundary lease。 |
| 383 | RV.Server.roofRefreshSquaresLoaded(player, record)；权威玩家与 map record | 再校 manifest identity、player identity/current context/record 与 boundary 一致，最后 pcall 调共享 RoofRefresh.isLoaded；返回 ready 与原因。 | 需要；避免异步返回后用旧 record 或未加载格运行刷新。 |

### 对共享状态的接口判断

- API 文件直接访问 ctx.pendingGeneration、transactionBusy、roofRefreshRelocationGroup、roofRefreshGroupFailure 和 roofRefreshGroupFinalReturn。这些是相邻 RV.Server 内部 transaction 状态，不属于对外客户端合同；本文件正负责把它们封装成上述 RV.Server API，因此保留 ctx 访问比为同一事务再引入一层 getter/setter 更清楚。
- 下游 adapter 对外走 RV.Server 方法，没有自行读这些状态表。内部函数 busyGroup / groupClaims 只用于把 fail-closed 规则集中在对应接口中。

## 5. 目的地与回滚 RV_Server_RoofDestinations.lua

文件从当前 bitmap/manifest 计算 destination，校验返回坐标仍落在当前 active geometry，处理临时格安全性及 authoritative teleport；并含有 generation staging helpers，说明它目前是通用 RV relocation destination 服务，而不是严格只服务 RoofRefresh 的单一文件。

| 行 | 函数与输入参数 | 功能、模块语义、输出/副作用 | 当前是否需要及原因 |
|---|---|---|---|
| 2 | 外层 factory function(ctx)；服务端目的地依赖 | 文件返回该 factory；调用时注册目的地/回滚 helper 到 ctx，factory body 不返回值。 | 需要；事务模块通过 ctx 使用目的地实现。 |
| 11 | safeErrorText(...)；原样转发错误 | 调用统一错误文本清理。 | 需要；rollback 日志不应直接 tostring 任意错误对象。 |
| 25 | squareIsSafeForRelocation(square, countCharacters)；候选格、是否把角色计为占用 | 要求 floor 存在且 solid/free；房间为空、roomID=-1、region 非 playerRoom、无车辆；返回布尔。 | 需要；通用安全格判断，用在 generation/relocation destination。 |
| 58 | squareHasRoofRefreshOccupant(square, allowedPlayers)；临时目标格、允许的组玩家集合 | 检查 objects/special/moving/world objects/corpses collections 和车；moving objects 仅允许当前事务玩家；保守占用时 true。 | 需要；批量搬运成员可以互相占格，但不可覆盖外部对象。 |
| 102 | roofRefreshTemporarySquareSafe(square, allowedPlayers)；临时格、同组玩家集合 | 有标准 solid floor 时复用通用 safe；否则要求空对象/车、无 room/roomID、非 player room。 | 需要；临时远程目标可能没有常规 floor，但仍须排除活动世界内容。 |
| 126 | selectGenerationStagingDestination(layout, bounds)；当前 generation layout 与管理区 bounds | 校验 bitmap 宽高/原点与 bounds 完全一致，计算 managed scope 中心及 staging z，核 world 合法；返回 generation-center 目标。 | 对 generation relocation 必需；但放在 RoofRefresh 目录/文件名中职责不匹配，宜拆出通用 destination 文件。 |
| 167 | playerIsAtStagingDestination(player, destination, bounds)；权威玩家、预期目标、当前 bounds | 验证服务端玩家坐标精确到目标；generation-center 还校验 managed center 与 staging z，返回布尔/原因。 | generation staging 必需；和屋顶专用事务无关，宜随上项迁移到 Generation/Relocation 模块。 |
| 190 | relocationPositionStillSyncing(reason)；上一个同步失败原因 | 对三类仅位置尚未同步/当前 square 未绑定错误返回 true。 | 需要；将可重试的位置延迟与死亡/身份/权限硬失败分开。 |
| 200 | roofRefreshPosition(position, label)；服务器位置表、诊断标签 | 校验 x/y/z finite numeric、z 合法，保留精确浮点坐标副本；非法抛错。 | 需要；回程必须保存并再次使用准确服务端浮点位置。 |
| 218 | roofRefreshWorldCoordinateValid(destination)；目标坐标 | 查 world.isValidSquare（按 floor square）；成功返回 true，否则 false 与原因。 | 需要；teleport 前拒绝世界边界外坐标。 |
| 237 | currentRoofRefreshContext(player, request)；权威玩家、含 rvId/generation/version/identityKey 请求 | 重新解析 boundary、player relation、rider、manifest、record geometry 和缓存 bitmap；所有请求身份必须与当前服务端 mapping 相符；返回完整 context 或拒绝原因。 | 需要；移动跨 tick 后仍必须重验当前 mapping/schema。 |
| 322 | roofRefreshDestination(context, request)；已校验 context、phase/returnPosition | temporary 目标由 validated bitmap 中心减远程向量计算；return 目标要求精确位置仍在 bitmap scope 且 active；返回目标/拒绝理由。 | 需要；客户端不提供目的地，服务端唯一计算并验证坐标。 |
| 374 | playerAtRoofRefreshDestination(player, destination, allowMissingSquare)；玩家、目标、临时/返回缺 square 策略 | 验权威位置所在格；检查当前 square 坐标与目标一致；必要时返回 square，支持暂时未绑定的临时远程目标。 | 需要；客户端 ACK 不能替代服务端坐标和 square 验证。 |
| 407 | applyRoofRefreshTeleport(player, target, temporary)；玩家、服务端目标、是否临时阶段 | 检查数值；临时位移加 .5 square 中心偏移；调用官方服务端 teleport 及 setX/Y/Z/LastX/LastY；全调用成功才 true。 | 需要；teleport 与网络更新位置字段必须同时重申，避免同步包取整漂移。 |
| 424 | roofRefreshTargetReady(player, destination, phase, allowedPlayers)；成员、目标、阶段、同组豁免集合 | 核玩家到位；temporary 阶段读取 cell/square 并检查临时格安全，允许因 chunk 未绑定继续等待；return 阶段只要求坐标到位供随后 proof/加载门继续。 | 需要；把暂时未落格/占用危险区分为重试和失败。 |
| 471 | copyRoofRefreshPosition(position)；任意位置表 | 仅复制有限数字 x/y/z 且 z 在 world 范围；非法 nil。 | 需要；保存不共享可变表的精确目标快照。 |
| 485 | validatedRoofRefreshReturn(pending)；单人 pending 事务 | 重新绑定同一玩家 identity、校当前 context 和 manifest，将 server-captured return 坐标要求为当前 bitmap active 格；返回 identity/context/position 或错误。 | 需要；回滚及最终返回不得使用 stale schema 或客户端位置。 |
| 525 | rollbackRoofRefreshRelocation(pending)；已开始的单人 roof relocation 状态 | 重验回程目标和 world；发送 server-authored cancel/return 命令，服务端 teleport，检查准确归位并完成 Boundary lease；返回完成布尔/失败原因。 | 需要；错误、断线或超时都必须保留可再次调用的权威归位路径。 |

### 该文件函数清点与边界

本文件有 18 个 function 表达式（factory、代理和 16 个具名 helper），无匿名 function 闭包。Boundary.boundaryForPlayer、Boundary.cachedBitmap、RV.Server.currentRVManifestForBoundary 和 currentRVRecordGeometryConsistent 是显式服务 API；本文件将结果组织成事务 context。record.players、relation 和 manifest.bounds 是被验证的领域记录字段，非模块私有缓存。

目的地/回滚接口通过 ctx 输出到同一 server factory 内；对其他 Lua 子系统的调用均走 ServerUtil/ServerWorld/Boundary/RV.Server，未发现直接读其他模块私有运行时表。selectGenerationStagingDestination 和 playerIsAtStagingDestination 体现功能混放：宜移入 generation relocation destination 子模块；共享底层方格安全检测保留在通用 relocation helper。无需为一次性本地 helper 全部建立公开接口。

## 6. 成组搬运服务 `RV_Server_RoofRelocation.lua`

此服务在服务端以稳定玩家身份建立一个 relocation group；先为全体成员启动 Boundary transition，再发临时移出命令，跨 tick 处理 ACK/重连，最后对每个成员验证回程并保留必要的长期、限频纠正。group 数据只存在本进程内。

| 行 | 函数与输入参数 | 功能、模块语义、输出/副作用 | 当前是否需要及原因 |
|---|---|---|---|
| 4 | 外层 factory function(ctx)；事务 context | 文件返回该 factory；调用时捕获 ServerUtil、Boundary、destination helper 和当前事务状态并安装 API/ctx 函数，factory body 不返回值。 | 需要；将世界副作用集中在服务端事务层。 |
| 13 | safeErrorText(...)；原样转发任意错误 | ctx 错误归一化代理。 | 需要；交易主 pcall 的异常需变成安全诊断。 |
| 32 | processRoofRefreshRelocationGroup(...)；原样转发 ctx handler | 调用 ctx 中 relocation group handler。 | 当前未使用；仅定义一次，未被文件体调用也未导出到 ctx；可直接移除该死代理。 |
| 34 | earlierTick(left, right)；两个 Core tick | 比较两个 deadline 并返回较早 tick 的副本；无效比较返回 nil。 | 需要；Boundary lease 期限不能超过 transaction deadline。 |
| 41 | roofRefreshGroupMatches(group, rvId, generation, bitmapVersion)；事务表和 identity | 将组 identity 字段与请求严格比较；返回布尔。 | 需要；API、服务分支共用一致的 group match 规则。 |
| 48 | roofRefreshGroupMember(group, player, token)；组、玩家对象或稳定身份、可选 token | 先解析当前 identity key，再按对象或身份和 token 查成员；未命中 nil。 | 需要；重连后不能只按过期对象引用识别玩家。 |
| 68 | roofRefreshGroupAll(group, field, value)；组、成员字段和值 | 要求非空合法 members，并检查全员字段相等；返回布尔。 | 需要；temporary arrival、return completion 等全员阶段屏障。 |
| 79 | roofRefreshExactPosition(player)；玩家 | 直接转发权威服务端 x/y/z position query。 | 当前可内联；仅作为一次性语义命名代理，源码只有一个使用点。 |
| 87 | failRoofRefreshRelocationGroup(reason)；失败原因 | 取走当前 group，记录 token/identity 失败；逐成员执行权威 rollback 和通知；任一不能返回时创建 finalReturn owner 供后续持续重试。 | 需要；各种中断场景不得丢弃仍在远程层的玩家。 |
| 128 | processRoofRefreshGroupFinalReturn()；无显式参数，使用服务器 tick 与 finalReturn owner | 周期核查已标记返回成员是否仍在原始精确位置；对未归位者再 rollback；全归位才清除 owner，否则设有限速 nextTick。 | 需要；确保失败路径不靠一次命令成功推断已安全返回。 |
| 193 | RV.Server.beginRoofRefreshRelocationGroup(request)；阶段、roomKey、identity 和 temporary phase 玩家 descriptors | 在保护调用中执行 mutex/identity/schema/current geometry gates。temporary 路径重新验证所有玩家及精确回程点，建立 group token，给全员 arm Boundary lease 后发相同临时位移；return 路径复验所有成员及 return scope，更新目标/phase 并发起回程。返回成功与 token/原因。 | 需要；世界移动、lease、成员验证的唯一服务端事务入口。 |
| 194 | `beginRoofRefreshRelocationGroup` 内匿名闭包 function()；无显式参数，捕获 request | 包含完整 transaction 请求处理体，作为 pcall 的异常隔离边界，输出内部的 success/result/reason。 | 需要；请求 malformed/引擎 API 异常不得跳过统一错误转换。 |
| 454 | keepRoofRefreshFinalReturnAlive(member)；最终回程成员 | resolve 同一在线 identity；续期原 token 的 Boundary lease，lease 不在时只按同一 token/identity 重建并续期。无返回值。 | 需要；finalReturn 恢复期必须持续持有 Boundary correction lease。 |
| 485 | resendRoofRefreshMemberPhase(group, member)；当前组与单个成员 | 只对未 arrived/completed 且当前 phase 有效的成员重发同一 token 临时/返回命令，再次服务端 teleport 并重置 ACK/arrival 状态；返回是否重发成功。 | 需要；处理 reconnect 让客户端遗失的 in-flight relocation 状态。 |
| 540 | keepRoofRefreshTransitionAlive()；无参数，使用当前事务/服务器 tick | 对 final return 续 lease；对活动组检测断线并暂停 timeout；身份重绑后调整期限、需要时标记重发；保持/续期所有未完成成员 Boundary lease，处理 lease 失效和超时。返回是否仍可继续。 | 需要；每 tick 事务管理器的存活/恢复逻辑。 |

### 状态接口及直接访问

- 当前交易由同一 server factory 通过 ctx.roofRefreshRelocationGroup、ctx.roofRefreshGroupFailure、ctx.roofRefreshGroupFinalReturn、ctx.roofRefreshGroupSerial、ctx.serverTick、ctx.pendingGeneration、ctx.transactionBusy 共用。RoofApi 在同一 ctx 上读取这些字段；这属于服务内部实现共享，不是外部客户端写入状态。
- 对外/跨上下游公开动作使用 RV.Server.beginRoofRefreshRelocationGroup 等 API 和 Boundary begin/extend/completeTransition；Flow 并未直接编辑内部 group members。此处直接更新 group/private lease data 是事务状态机所有者，若抽接口只会把每个字段操作切成薄包装，收益不明显。
- 与 RoomOwnership 的暂停逻辑只检查是否存在 group/finalReturn，这是一处不同服务文件对私有状态的直接 mutex 读取（见下节）。可考虑新增只读 `isRoofRefreshTransactionActive` 复用 API；不过该 API 现在就有，RoomOwnership 改用它会更清楚且成本低。

## 7. 动态房间所有权清理 `RV_Server_RoomOwnership.lua`

该文件避免从世界格删除有效房间或新旧重叠房间，只把 `getRoom()` 存在而 `getRoomDef()` 已被退休清空的格的 roomID 重置为 -1。对象事件触发限量重查；generation/rollback 可同步全扫描；客户端另收 server-authored bounds footprint 做行走时复查。

| 行 | 函数与输入参数 | 功能、模块语义、输出/副作用 | 当前是否需要及原因 |
|---|---|---|---|
| 2 | 外层 factory function(ctx)；服务端 room ownership context | 文件返回该 factory；调用时注册运行时 guard、回滚和客户端 guard 操作，factory body 不返回值。 | 需要；由生成/进入流程通过 ctx 注入使用。 |
| 16 | safeErrorText(...)；错误对象 | 转发 ctx 错误字符串化函数。 | 需要；扫描失败进入 guard 诊断时规整错误。 |
| 17 | requireCurrentManifest(...)；manifest 查询参数 | 转发 ctx 当前 manifest 查询。 | 当前未使用；只有局部定义，无调用点，属死代理。 |
| 34 | tickAfter(tick, delta)；当前 tick 与延时 | Core.tickAdd 失败则抛出带字段原因的错误，否则返回 tick。 | 需要；scan lease/deadline 采用统一 tick schema。 |
| 42 | notifyFailure(player, reason)；玩家与失败原因 | 校验 finite 非负整数 onlineId，必要时将错误规整为 INVALID_RV_DATA，再发送服务端失败命令；返回发送成功布尔。 | 需要；room-ownership 交易失败须反馈客户端。 |
| 62 | removeOldGeneration(cell, manifest)；旧 cell/manifest 参数（当前刻意未使用） | 无条件抛错，明确拒绝因当前 schema 没有完整 undo snapshot 而执行旧 generation 清理。 | 作为 fail-closed 防线需要；不能把旧数据当作可迁移或可安全删除的对象。 |
| 67 | structureCoordinates(bounds, callback, materializedRoofCoordinates)；边界、坐标回调、可选屋顶实际格列表 | 校 bounds 且遍历墙格；若无实格列表，用当前模板的 sparse roof object hosts；若有列表只遍历已 materialize 上层格；通过回调输出坐标，无显式返回。 | 需要；把旧/新结构覆盖范围表达成同一可核对扫描合同。 |
| 99 | emitRoof(x, y, z)，嵌于 structureCoordinates；屋顶格坐标 | 以坐标 key 去重后调用外部 callback。 | 需要；模板稀疏 roof 可能共享 host square，需只扫描一次。 |
| 144 | clearInvalidRoomOwnershipSquare(square)；一个格对象 | 若 getRoom 有效但 getRoomDef 已空，则将 roomID 置 -1 并复验 room 已清；其他有效/重叠 room 不动；返回是否清理。 | 需要；窄范围修复 retired-room dangling reference 的核心规则。 |
| 169 | clearInvalidRoomOwnershipReferences(cell, oldBounds, newBounds, materializedNewRoofCoordinates)；cell、新旧边界、可选新 roof 实际格 | 构造去重 expected coordinates，扫描存在的格并清理 dangling refs；要求 expected/visited 数量一致，缺扫描时报错；返回清理数量。 | 需要；提供 generation 同步扫描/rollback 后验证，避免部分扫描假装成功。 |
| 176 | markExpected(x, y, z)，嵌于 clearInvalidRoomOwnershipReferences；格坐标 | 将唯一坐标加入 expected set 和遍历数组。 | 需要；内层构造全量可验证扫描计划。 |
| 187 | inspect(square, x, y, z)，嵌于 clearInvalidRoomOwnershipReferences；格对象与坐标 | 坐标去重后运行单格 dangling-room 检查并累计修复数。 | 需要；保证重合的新旧 footprint 不重复计数。 |
| 212 | coordinatesInRoomOwnershipBounds(x, y, z, bounds)；格坐标、bounds | 判断是否位于 wall base plane 或 roof plane 的闭区间；返回布尔。 | 需要；对象事件和在线玩家邻域共用 footprint 命中判断。 |
| 221 | objectCoordinates(object)；世界对象 | 从 host square（或对象本身）读取整数格坐标和 cell；坐标缺失返回 nil，否则返回 x,y,z,cell。 | 需要；event hook 必须按实际对象宿主格定位，而非调用者坐标。 |
| 236 | scheduleRoomOwnershipScan(guard, cell)；当前 guard、对象所属 cell | 取消稳定计时、记录 cell；若尚无 scan series，启动并安排第一延迟重查。 | 需要；事件 burst 合并成有限重试序列。 |
| 248 | requestRoomOwnershipScan(object, includeOutcome)；对象、是否返回命中结果 | 算对象坐标后找旧/新 footprint 相交的 guard，触发扫描；可返回 hit / nil，否则无返回。 | 需要；提供普通对象事件的内部入口。 |
| 265 | requestRoomOwnershipRemovalScan(object)；将被删除的对象 | 请求 scan 并要求返回命中标志；包装用途在事件层记录结果。 | 需要；移除前 hook 与一般变更扫描语义有区分。 |
| 269 | onlinePlayersSnapshot()；无参数 | 取 getOnlinePlayers 或单人 fallback；返回去重数组和快照可信布尔，读取失败时不谎称无人在线。 | 需要；清理范围依赖当前完整在线玩家集。 |
| 302 | authoritativePlayerCoordinates(player)；服务端玩家 | 优先用 ctx 定时权威样本；sample not due 则要求 maxAge=0，sample identity/interval 错误则 fresh 读取；缺能力时读服务端坐标；校 finite 并 floor，输出 x,y,z 或 nil。 | 需要；邻域扫描不能用客户端坐标或陈旧快照。 |
| 350 | authoritativePlayerStatesSnapshot()；无参数 | 一次抓在线玩家列表及每个权威格坐标；有任一位置缺失返回 states,false，否则 states,true。 | 需要；供同 tick 的多个 guard 共用坐标读数。 |
| 363 | playerNeighborhoodTouchesGuard(x, y, z, guard, radius)；玩家所在格、guard、探测半径 | 遍历 xy 邻域，判断任一格与旧/新 bounds 相交；返回布尔。 | 需要；每隔 120 tick 扫描玩家附近 3x3 dangling room refs。 |
| 377 | addScanCell(cells, seen, player)；待扫描数组、去重集合、玩家 | 取玩家服务端 cell，唯一加入 cells；无返回值。 | 需要；避免同一 cell 被多个在线玩家重复扫描。 |
| 385 | relevantRoomOwnershipCells(guard, phase)；guard、同步阶段或 nil | 合并事件相关 cell 与邻近在线玩家 cell；事务阶段还必须包含发起玩家 cell；快照/坐标/cell 不可用就报错；返回 cell 数组。 | 需要；限定扫描 cell 并保证交易同步检查覆盖 requester。 |
| 423 | clearInvalidRoomOwnershipNearPlayers(guards, playerStates, snapshotOk, neighborhoodDue)；guard map、权威玩家快照及各 guard 是否 3x3 due | 合并 overlap guard 查询，读取玩家所在/邻格；发现 dangling ref 时清理并为相关 guard 排入完整重查 series。无显式返回。 | 需要；每 tick 低成本采样及时修复新房间边缘的陈旧引用。 |
| 470 | roomOwnershipGuardKey(rvId, generation, bitmapVersion)；mapping identity | 返回稳定 `rvId:generation:bitmapVersion` 内存键。 | 需要；同 RV 的 generation 防护状态隔离。 |
| 484 | collectMaterializedRoofCoordinates(cell, bounds)；事务 cell 与屋顶 bounds | 借 structureCoordinates 读取 roofZ 上已存在的格并返回坐标数组。 | 需要；generation 未完成时仅扫描实际生成的 roof squares。 |
| 488 | collectMaterializedRoofCoordinates 内匿名闭包 `function(x, y, z)`；屋顶格坐标 | 仅在 roofZ 且当前 cell 已有 square 时，将坐标加入数组。 | 需要；是 structureCoordinates 的实际 roof host 收集回调。 |
| 496 | registerServerRoomOwnershipGuard(generation, player, oldBounds, newBounds, rvId, bitmapVersion)；当前/旧 identity、发起玩家、新旧 bounds | 校 identity 和版本，建含 bounded tick/scan/stability/roof materialization 状态的 guard，存入 roomOwnershipGuards 并返回 guard。 | 需要；generation 与 rollback 共用一份 room cleanup owner。 |
| 538 | refreshServerRoomOwnershipGuard(guard, phase, requireFullNewRoof)；guard、可选事务阶段、是否要求完整新屋顶 | 找当前相关 cells，对 old footprint 全扫、新 footprint 按物化/完整合同扫；累计清理，设置新 roof 完成标记和稳定 tick；返回清理数。 | 需要；generation/rollback 同步触发修复并用于判定验证结果。 |
| 569 | processServerRoomOwnershipGuards()；无参数，每个 server tick 调用 | 空 guard 时返回；RoofRefresh relocation/final return 活动期间暂停。否则共享一次玩家快照，做邻域快速 probe 和延迟完整 scan；达到最小稳定期或最大寿命后退休 guard。 | 需要；动态 IsoRegions 更新有异步尾部，事件不能只扫一次。 |
| 662 | copyRoomRefreshBounds(target, prefix, bounds)；目标 payload、字段前缀、新边界表 | 逐个校验并复制 wall/room/roof/z 坐标整数。 | 需要；server 发给客户端的 footprint 必须是当前 service 生成的整数边界。 |
| 675 | armClientRoomOwnershipGuard(generation, oldBounds, newBounds, rvId, bitmapVersion)；generation、新旧 bounds、RV/version | 构造包含身份、hasOld 和旧/新边界的广播 payload，向全体客户端发送 room ownership refresh command；失败时报错。 | 需要；非请求玩家之后也可能进入退休房间 footprint。 |
| 696 | removeGeneration(cell, bounds, generation, rvId, bitmapVersion, generationPhase)；回滚 cell/边界/identity/失败阶段 | 要求当前 identity 与 guard 有效；按 generation tag 清理 bounds 内对象，再严格快照验证 tagged 对象为零；根据阶段确定是否要求完整 roof scan，刷新并验证 ownership guard；失败抛错。 | 需要；generation rollback 不能留下带本 generation tag 的对象或未核完 room refs。 |
| 713 | removeGeneration 内匿名闭包 `function(square)`；一个遍历到的格 | 调 ServerWorld.clearSquare 清除当前 generation/rvId/version 匹配对象；由 walkBounds 调用。 | 需要；将严格限定的 tag 清理应用到所有 bounds 格。 |
| 722 | removeGeneration 内匿名闭包 `function(square)`；一个遍历到的格 | 获取 strict snapshot，确保完整；统计仍带目标 generation identity 的对象；由 walkBounds 调用。 | 需要；删除函数返回前证明 rollback 已完成。 |
| 770 | armTargetedClientRoomOwnershipGuard(player, generation, newBounds, rvId, bitmapVersion)；客户端对象及当前服务端 identity/bounds | 校验玩家、positive generation、rvId/current bitmapVersion，复制新 bounds 并只向目标玩家发 guard 命令；发送失败抛错。 | 需要；已有 RV 的进入/重连路径没有 generation 广播，需为新 client 单独布防。 |

### 内部数据访问和接口价值

- 本模块拥有 roomOwnershipGuards，并由其 helper 读写 guard 细节；ctx 暴露的是操作函数（register/refresh/process/remove），而非让 Adapter 直接写单个 guard 字段，这是合适的内部接口边界。
- `processServerRoomOwnershipGuards` 直接检查 `ctx.roofRefreshRelocationGroup` 与 `ctx.roofRefreshGroupFinalReturn` 来暂停本服务。这是跨模块直接访问 RoofRelocation 私有状态。已存在 `RV.Server.isRoofRefreshTransactionActive()` 能覆盖 group/finalReturn 并 fail-closed；改用公开只读接口收益明显、实现代价低，可以消除私有字段耦合。
- RoomTemplate.orderedObjects、ServerSchema.walkBounds、ServerWorld strict snapshot/tag/clear、ServerUtil 与 Boundary 等是显式模块 API；`templateObjects` 与 mapping record/bounds 是已验证模板/领域数据，不属于模块私有运行时表。

## 8. 跨文件功能对比、复用和拆分建议

### 8.1 函数数量复核

| 文件 | 源码行数 | function 定义/匿名闭包 | 主职责 |
|---|---:|---:|---|
| RV_RailroaderServer_RoofRefresh.lua | 735 | 16 | 玩家采样、哨兵恢复、墙体事件匹配/排队 |
| RV_RailroaderServer_RoofRefreshFlow.lua | 749 | 16 | adapter 侧组事务阶段、取消、follow-up |
| RV_RoofRefresh.lua | 332 | 24 | 加载检测、captured floor 身份验证、房间属性刷新 |
| RV_Server_RoofApi.lua | 416 | 18 | 事务查询、边界读取证明、完成/取消接口 |
| RV_Server_RoofDestinations.lua | 631 | 18 | destination、安全格、回滚和 generation staging 坐标 |
| RV_Server_RoofRelocation.lua | 656 | 15 | 成组权威传送、lease/ACK/reconnect/最终归位 |
| RV_Server_RoomOwnership.lua | 812 | 36 | 动态房间无效引用扫描、guard、rollback 验证 |
| **合计** | **4,331** | **143** |  |

计数口径是源码中的 `function` 表达式，包含 7 个外层 factory、ctx 代理、嵌套函数和匿名回调；不是只统计 public methods。各节函数表行数依次为 16、16、24、18、18、15、36，总计与扫描值一致。

### 8.2 可共用逻辑

| 功能 | 当前分布 | 建议与边界 |
|---|---|---|
| 安全对象/全局函数调用、数值转型 | RV_RoofRefresh.lua:25–65 实现 toNumber/invoke/callGlobal/callSucceeded/integer；其余 server helper 多处使用 ServerUtil.invoke、callGlobalSucceeded、toNumber、requiredInteger | 优先核对 ServerUtil 已公开 helper 是否能覆盖异常保护、self 调用、错误返回和有限数值规则；可等价时直接复用 ServerUtil，避免第二份实现。`invoke` 和 ServerUtil 的返回约定若不同，应明确适配，不可为少几行而模糊错误结果。 |
| 在线玩家快照 | RoofRefresh adapter 通过 ctx.onlinePlayersSnapshot（RV_RailroaderServer_RoofRefresh.lua:51）注入；RoomOwnership.lua:269 有本地 onlinePlayersSnapshot，返回 players 与 snapshotOk | 有真实复用价值。若共同服务 API 能保留“快照完整性布尔”和 getPlayer fallback 语义，RoomOwnership 可共用；否则保留现状，因为不完整快照在 RoomOwnership 中必须 fail-closed。 |
| tick 增量并验证 | RoofRefreshFlow.lua:153 和 RoomOwnership.lua:34 都将 Core.tickAdd 失败转异常 | 可提取到 Core 的共享 strict tick helper，但只有两处小重复且当前语义已一致；不值得仅为抽象新增一层接口。 |
| 世界格合法性/平方位置 | RoofRefresh.lua:81 的 worldSquareIsValid 与 RoofDestinations.lua:218 的 roofRefreshWorldCoordinateValid 都用 getWorld/isValidSquare；前者 World 缺失/调用失败采取 permissive，后者明确返回不可用错误 | 表面相似但容错合同相反，不能直接抽成单一 bool helper。若未来复用，采用显式“世界 API 不可用”状态或调用方策略参数。 |
| 位移格安全检测 | RoofDestinations.lua:25、58、102 | 已经复用 squareIsSafeForRelocation 于临时格安全检查；moving-object allowlist 是群组语义，不宜再拆散。 |
| 几何/边界遍历 | RoomOwnership.lua:67 的 structureCoordinates 与 RV_RoofRefresh.lua:143 的 wall/floor loaded scan | 都遍历坐标但用途/合同不同：一个基于 sparse template roof 和物化 roof 集，一个要求当前全部 wall plus refresh target loaded；不应为了语法相似合并。 |
| 玩家及 RV 身份校验 | Adapter 的 insidePlayersForRecord 与 RoofDestinations 的 currentRoofRefreshContext | 都使用 onlineId/inside 关系，但后者还重验 boundary、manifest、geometry、bitmap，是移动安全服务端门。可以由更上游稳定身份 API共享基本关系解析，不能绕过当前 context 完整校验。 |
| 事件去重 | 同一个 object removal 可能分别进入 onObjectAboutToBeRemoved 与 onDestroyIsoThumpable；都落到 queueWallRoofRefreshForObject | 已集中到一个 matcher 和 eventKey/coordinateKey 去重逻辑，无需抽取。 |

### 8.3 是否进一步拆分

- 建议迁移 generation staging 两函数：RoofDestinations.lua:126–188 的 selectGenerationStagingDestination 和 playerIsAtStagingDestination 只服务首次 generation staging，与 RoofRefresh 回远程格流程无关。挪到 generation relocation/destination 模块可修正命名与目录职责；共享 relocation square-safety helper 仍放通用服务。
- 可以考虑把 stateless relocation sentinel（RoofRefresh adapter.lua:84–208）分成 relocation recovery 模块。它解决服务端残留临时层恢复，不依赖墙拆事件或房间属性刷新。但它和 Adapter 共用在线玩家身份/事务状态；拆前应由 ctx operation API 注入依赖，不能继续共享任意表字段。
- 其他文件按闭环职责分得基本合理。RoomOwnership.lua 有 812 行，但 guard 注册、坐标范围、邻域 probe、重扫、rollback 都围绕同一 dangling room ownership 生命周期；再按 helper 类型拆文件会增加共享 guard 状态接口成本。Flow 的 phase transitions 也应先保持在一个状态机文件中。
- RoofRefresh adapter 内 observeRoomTransitions / authoritativeRoomState 当前只贡献诊断及重复 pending cleanup。若不再要求这些诊断，可删除转场态表/采样，并保留第二段基于 observedRooms 的 pending presence 取消；此为可选减法，不是必须的目录重构。
- 本目录已经有 Adapter、Flow、Roof API、Relocation、Destinations、RoomOwnership 分层，不建议整体重组或给每个 local helper 单独建文件。

## 9. 跨模块数据访问与接口价值

### 已有模块合同

- 模组内部公开服务方法主要是 `RV.Server.*` 和 `RailroaderRV.RoofRefresh.isLoaded/run`。Railroader adapter 用 RoofRefresh API 控制刷新；Flow 用 RV.Server transaction API 开始/完成/取消流程。Boundary、ServerUtil、ServerWorld、ServerSchema 和 RoomTemplate 均以模块方法调用。
- ctx 是 RV.Server 装配期的兄弟 factory 合同。各文件把要给兄弟模块调用的 helper 显式赋回 ctx；这类 ctx API 是内部服务接口，而不是 public-to-client 接口。
- map.players、map.locomotives、record.players、record.region/boundary、manifest.bounds、RoomTemplate orderedObjects 是领域/配置数据，经过 schema/current identity 门限的记录，并非其他 Lua 模块的隐藏运行时表。服务端按这些记录校验属于预期直接读取。

### 直接访问 sibling 私有状态

| 位置 | 访问内容 | 评价/接口建议 |
|---|---|---|
| RoofRefresh adapter.lua:502–505 | RailroaderRV.Server._templateProtectionRepairRemovalObject 与 object 直接作引用比较 | 这是下划线隐藏字段。单点过滤而且只比较对象引用；若拥有模块已有统一 owner predicate，优先用它。专门加一个 API 的收益目前较低，需避免把这个字段扩散到更多调用方。 |
| RoomOwnership.lua:583–584 | ctx.roofRefreshRelocationGroup 和 ctx.roofRefreshGroupFinalReturn | 读取 RoofRelocation 内部 group/finalReturn 表状态来暂停自己的扫描。改调现有 RV.Server.isRoofRefreshTransactionActive() 收益明显、成本低；能消除跨文件直接耦合，并复用坏状态 fail-closed 行为。 |
| RoofApi.lua:49、68–80、111–129、136–146、208–216、222–365 | 读取、更新 pendingGeneration、transactionBusy、relocationGroup/failure/finalReturn 等 ctx 数据 | RoofApi/Relocation 属于同一 server transaction service 的实现层。API 文件正是这些数据的拥有者接口边界；在此内部读状态合理，不需为每一处 ctx 字段再包一层 getter。对 Adapter/RoomOwnership 应维持 RV.Server 方法边界。 |
| RoofRelocation.lua:87–185、193–449、540–645 | 建立/更新/退休 ctx relocation group、failure、finalReturn、serial、deadline 和 member state | 这是事务状态机的 owning module，数据变更集中在此是合理的。别的模块只应通过公开 API 或内部 ctx 操作请求，不应写 member/table 字段。 |
| Adapter.lua 与 Flow.lua | 双方对同一队列/presence/去重/transition 多张 ctx map 直接读写（Adapter 12–16；Flow 6–13） | 两文件实际上是一个调度器的事件入口和 tick handler，当前内部访问直接且符合既有 factory 组合方式。若未来继续拆分，收益点是抽一个 scheduler owner 统一创建、退休 pending，而非把 map 复制或逐字段包 getter/setter。 |
| RoofRefresh.lua:18–21、323–329 | RailroaderRV.RoofRefresh namespace 暴露 `_busy` 锁字段，run 自己读写 | 目前实际只有同模块使用。锁可收为 local，以免外部误改；模块对外只需 isLoaded/run，不需要为 busy 增加接口。 |

直接跨模块的 map 数据写入尚未发现；跨模块写入主要是明确 ctx helper 或 `RV.Server` API。两项值得直接改进的边界是 RoomOwnership 对 RoofRelocation 的内部状态探测，以及可将 `_busy` 隐藏在 RoofRefresh 私有 local。一个相等性对象保护字段目前不值得新造 API。

## 10. 只读复核记录及未覆盖项

- 文件清单：RoofRefresh 目录包含本报告列出的 7 个 Lua 文件；总行数 4,331。
- 函数扫描：对每个源码文件运行定义/闭包正则扫描 `function(?:\s+[A-Za-z_][A-Za-z0-9_.:]*)?\s*\(`；逐文件结果为 16 / 16 / 24 / 18 / 18 / 15 / 36，共 143。表格函数起始行逐行对照源码声明/闭包位置后，文档表格也是 143 行，无漏项或多记项。
- 文档结构：7 个模块章节和本总结章节齐全；报告中各模块函数表数量与源码扫描相同。
- 验证边界：未执行 Lua 静态解析器或游戏 runtime 测试；这是只读静态分析。`RV.Server.getRoofRefreshRelocationState` 的跨目录实际调用方、本目录 factory 在总装配器中的生命周期，以及两个看似死代理是否在外部以不可见方式引用，需要全局总结阶段结合相邻目录 caller 再作最终判定。

## 第二阶段职责更新

分组搬运的 ACK、arrival、retry、disconnect rebind 和 failure processor 已从 GenerationAck 迁入 RoofRelocation；GenerationAck 将 ACK token 转交 `acknowledgeRoofRefreshRelocation`，不再读取 group/member table。RoofRefresh `isRoofRefreshTransactionActive()` 成为 RoomOwnership 的事务查询入口。RoofRelocation 与 RoofApi 在 RoofRefresh 包内使用组合 context 状态；包外调用方不解析 group/final-return/member 字段。只服务 generation staging 的 `selectGenerationStagingDestination` / `playerIsAtStagingDestination` 已移入 GenerationFlow。见[第二阶段报告](phase2-structure-optimization.md)。
- 文件变更：只新建本报告，没有改动任何 Lua 源码。
