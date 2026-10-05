# server/RailroaderRV/RoomOwnership 模块分析
> **状态（RailroaderRV 1.0）**：本文件是静态审计记录；其行号、计数和源码结论并非本次发布的全量重核，也不是运行时验证。当前实现以 [源码](../../contents/mods/RailroaderRV/42/) 与 [README](../../README.md) 为准，项目约束以 [agents.md](../../../agents.md) 为准。历史建议不构成修复授权，采纳前须按现行约束重新取证。

## 假设、范围、成功条件与验证方式

- **假设（源码事实）**：分析范围严格限于 `media/lua/server/RailroaderRV/RoomOwnership/` 的当前直接子文件。本次列目录确认该目录**只有 1 个 Lua 文件**：[RV_Server_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua)，562 行、23,344 字节。所有行号来自本次逐行读取的当前源码。
- **新文档声明（源码事实）**：`docs/module-analysis/` 此前**没有** `server-RoomOwnership.md`；本模块过去被塞在 `server-RoofRefresh.md` 里与另外 6 个文件合并描述（该报告称 RoomOwnership 有 812 行、36 个函数）。当前目录只有 1 个文件、562 行、30 个函数定义，旧描述整体作废。本报告是**新建**文档，按当前源码逐函数覆盖。
- **范围**：覆盖本文件全部函数定义，包括作为工厂体、`Layout.eachStructureCoordinate` 回调、`pcall` 体、`ServerSchema.walkBounds` 回调的匿名函数表达式；只读检查本模块 10 个 ctx 导出的消费方（Construction / Core / RVMapping）以及客户端同名模块 [RV_ContextMenu_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua) 的接口关系，但**不逐函数分析**其他文件。唯一写入目标是本报告。
- **成功条件**：目录清单、行数、`function` 扫描与逐行读取三者一致；每个函数有精确起始行、参数语义、返回/副作用、模块语义与必要性结论；回答 guard 状态由谁创建/读写、generation 回滚与失败通知归属谁、与客户端和 RoofRefresh/Core 的关系；明确区分「源码事实」与「条件性推断」。
- **验证方式**：`Get-ChildItem` 列目录；`Get-Content` 统计行数（562）；`Select-String '\bfunction\b'` 扫描（31 处命中，其中 L24 是 `type(...) ~= "function"` 类型判定，故函数定义 30 个）；全树检索 `roomOwnershipGuards`、10 个导出名、`ctx.serverTick`、`isWallReloadTransactionActive`、`RefreshRoomOwnership` 的命令与事件注册点。全部为静态只读分析，**不运行游戏或任何测试**。

## 目录职责与清单

本目录是**动态房间所有权清理服务**（ctx 注入式工厂，文件头注释 [RV_Server_RoomOwnership.lua:1-2](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:1)）。它解决的问题是：`IsoRegions` 重建动态房间时，`WorldRegionToMetaGrid.removeIsoRoom` 会先清空 `IsoRoom.def`，而世界格上的 `roomID` 引用可能仍指向已退休房间。本模块只修正这一种失效引用——`getRoom()` 存在但 `getRoomDef()` 已为 nil 的格——把它重置为 −1，绝不修改有效的新旧房间或重叠替换房间。

职责可归为四类：①单格失效引用清理原语；②每 RV 身份的 guard（guard 容器、调度、3×3 邻域探测、降级与退休）；③generation 回滚（按 owner+generation 标签清理 + 严格复核 + 房间复扫）；④客户端 guard 布防命令与失败通知。它不注册事件（事件在 [RV_Server_Commands.lua:392-393](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:392) 注册到本模块导出），不写 ModData，不持有存档状态。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_Server_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua) | 30 | 失效房间引用清理、guard 生命周期与每 tick 探测/延迟全扫、generation 回滚与回滚后验证、服务端→客户端 footprint 布防、generation 失败通知 |
| **总计** | **30** | 1 个文件、562 行：25 个具名 `local function`、5 个匿名函数表达式（工厂体 L2、L81、L431、L491、L500） |

函数口径：计入具名函数、`local function`、表方法与作为参数/回调的匿名函数表达式；不计入 [L552-561](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:552) 的 10 个 `ctx.X = localFunction` 导出别名赋值，也不计入 [L16](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:16) 的常量。

## 逐文件、逐函数分析

### RV_Server_RoomOwnership.lua

模块是 ctx 注入式工厂：文件返回 `function(ctx)`（[L2](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:2)），由 [Core/RV_Server.lua:141](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:141) 在 `RV.Server` 装配期**第一个**安装，末尾把 10 个函数写回 `ctx`（L552-561）供兄弟模块在加载时捕获。它从 ctx 读取 `COMMAND_MODULE`、`COMMAND_REFRESH_ROOM_OWNERSHIP`、`COMMAND_RV_TELEPORT`、`Constants`、`RV`、`ServerUtil`、`ServerWorld`、`ServerSchema`、`roomOwnershipGuards`、`serverTick`（L4-12），并额外 require 共享纯函数模块 `RailroaderRV/RoomTemplate/RV_Layout`（L3）。guard 容器本身不在本文件创建：它由 [Core/RV_Server.lua:88](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:88) 建立并以引用注入（:131）；本模块是它**唯一**的读写者。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| 外层工厂 function(ctx)（L2） | ctx：装配期依赖与共享状态表（见上文）。返回值为工厂体末尾无返回值；副作用：把 10 个函数写入 ctx（L552-561）、模块加载时定义全部 local helper。 | **必须**：本模块唯一的存在形式；ctx 装配契约由 Core 固定，且 5 个兄弟模块在加载时按名捕获这些导出。 |
| wallReloadActive（L21） | 无参数，读全局 `RailroaderRV.Server`。返回布尔：服务缺失/接口缺失/pcall 失败/返回值非布尔/为 true 时**都返回 true（暂停）**；只有接口明确返回 `false` 才继续。 | **必须**：这是本模块的 fail-closed 暂停门。墙体搬运期间权威玩家被刻意移出 RV 范围，若此时仍按其远端 cell 扫描，会在同一 tick 上对同一 chunk 反复解析 IsoCell（注释 L393-399）。 |
| notifyFailure（L31） | player、reason。player 为 nil 时**隐式返回 nil**；`getOnlineID` 经 `ServerUtil.invoke` + `toNumber`，非有限/非整数/负数时返回 false；reason 文本若包含 `Constants.INVALID_RV_DATA` 则被替换为该常量；最后 `sendServerCommand(player, "RailroaderRV", "RVTeleport", {ok=false, onlineId, reason})` 并返回其成功布尔。 | **必须**：本模块唯一的客户端失败反馈出口，实际被 generation 路径消费：Commands（[L372](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:372)、[L381](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:381)）与 GenerationAck（[L138](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationAck.lua:138)）。 |
| clearInvalidRoomOwnershipSquare（L51） | square 对象。`getRoom` 读取失败即 `error`；room == nil 返回 false；`getRoomDef` 读取失败即 `error`；roomDef ~= nil 返回 false（有效房间/重叠替换房间一律不动）；`setRoomID(-1)` 失败即 `error`；随后复核 `getRoom` 必须为 nil，否则 `error`；修正成功返回 true。副作用：改写格的 roomID。 | **必须**：本模块的核心规则实现（窄到只修「有 room、无 roomDef」这一种 dangling 引用），且是 fail-closed 的：读不到/写不进/复核不过都抛错，绝不假装清理成功。 |
| clearInvalidRoomOwnershipBounds（L78） | cell、bounds（非表时返回 0）。借 `Layout.eachStructureCoordinate` 遍历「墙体平面 + 模板屋顶宿主格」，对每格取 square 并调用单格清理，返回清理计数。 | **必须**：把「一次 bounds 覆盖范围」表达成可复用扫描；范围由共享布局枚举器唯一决定（注释 L76-77），不在本模块重造几何。 |
| `clearInvalidRoomOwnershipBounds` 中匿名函数（L81） | 回调参数 x、y、z（枚举器给的世界坐标）；取格→清理→累加，无返回值。 | **实现必需**：枚举器的回调体，是 :78-88 唯一遍历入口；内联会破坏「同一扫描合同」的可读性（该回调在两处 bounds 调用上复用）。 |
| coordinatesInRoomOwnershipBounds（L90） | x、y、z、bounds；bounds 非表返回 false。墙底面（`wallMinX..wallMaxX` × `wallMinY..wallMaxY` × `z == bounds.z`）或屋顶面（`roofMinX..roofMaxX` × `roofMinY..roofMaxY` × `z == bounds.roofZ`）命中即 true。 | **必须**：事件命中、邻域探测、guard 覆盖范围共用的唯一范围判定；四处调用（L134-135、L213-216、L293-296）。 |
| objectCoordinates（L99） | object；优先 `getSquare`（失败退回对象自身），再 `getX/getY/getZ` 经 `ServerUtil.integer`，任一缺失返回 nil；`getCell` 可选，读不到给 nil。返回 x, y, z, cell。 | **必须**：对象事件必须按**对象宿主格**定位（注释/实现均不使用调用者坐标）；事件入口 `requestRoomOwnershipScan` 完全依赖它。 |
| scheduleRoomOwnershipScan（L117） | guard、cell（可为 nil）。cell 非 nil 时写入 `guard.pendingCells[cell] = true`；`guard.scanDueTick` 为 nil 时设为 `ctx.serverTick + 1`。无返回值。 | **必须**：事件 burst 的合并点——同一 tick 的所有事件只排一次下一 tick 扫描；也是邻域探测发现残留后要求全量复扫的唯一手段（L308）。 |
| requestRoomOwnershipScan（L126） | object、includeOutcome（可选布尔）。无坐标时：includeOutcome 为真返回 nil，否则无返回；否则遍历全部 guard，命中 old/new bounds 时置 hit 并排程；includeOutcome 为真返回 hit。副作用：写 guard 的 pendingCells/scanDueTick。 | **必须**：`OnObjectAdded` 的事件处理器（[RV_Server_Commands.lua:393](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:393) 直接注册它），同时是移除路径的公共实现。**源码事实**：`includeOutcome == true` 的返回值当前无任何消费者（见第 5 章第 5 条），该分支只贡献一个被丢弃的布尔。 |
| requestRoomOwnershipRemovalScan（L143） | object。调用 `requestRoomOwnershipScan(object, true)` 并**丢弃**返回值。无返回。 | **必须**：`OnObjectAboutToBeRemoved` 的事件处理器（[RV_Server_Commands.lua:392](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:392)），名字区分了「移除前 hook」与「一般变更」两种事件语义。**实现本身可简化**：它唯一的增量价值是 `includeOutcome=true`，而该结果被丢弃，故当前等价于 `requestRoomOwnershipScan(object)`。 |
| onlinePlayersSnapshot（L147） | 无参数。`getOnlinePlayers` 可用时按 `size`/`get(i)` 枚举并去重，任何一项读取失败返回「已收集结果, false」；`getOnlinePlayers` 不可用时退回全局 `getPlayer`，成功返回 `{player}, true`；全部不可用返回 `{}, false`；容器是 Lua table 时按 pairs 复制并返回 `result, true`。 | **必须**：清理范围依赖「当前完整在线玩家集」，且必须把「快照不完整」与「无人在线」区分开（后者会被误判为安全的空扫描）。消费方：authoritativePlayerStatesSnapshot（L198）、relevantRoomOwnershipCells（L233）。 |
| authoritativePlayerCoordinates（L180） | player。`getX/getY/getZ` 经 `toNumber`；任一读取失败或为 nil 返回 nil；显式拒绝 NaN 与 ±∞（L188-192）；成功返回 `floor(x), floor(y), floor(z)`。 | **必须**：邻域/事务扫描只能用服务端权威坐标；取整保证与格坐标比较一致，失败给 nil 而不是猜值。 |
| authoritativePlayerStatesSnapshot（L197） | 无参数。先取在线快照，不完整返回 `{}, false`；逐玩家取权威格坐标，任一缺失返回「已收集 states, false」，否则 `states, true`。 | **必须**：同一 tick 内多个 guard、多类探测共用一次读数，避免逐 guard 重复引擎调用（注释 L401-402）。 |
| playerNeighborhoodTouchesGuard（L210） | x、y、z、guard、radius。在 dx/dy 的 ±radius 方形邻域内做 old/new bounds 命中判定，任一命中返回 true，否则 false。 | **必须**：判断「玩家的权威 cell 是否值得纳入本次扫描」的唯一半径语义实现；被 relevantRoomOwnershipCells 以 radius=1 使用（L251）。 |
| addScanCell（L224） | cells 数组、seen 集合、player。经 `ServerWorld.getCellForPlayer(player)` 取 cell（不可用时**抛错**），未登记则加入。无返回值。 | **实现必需**：三处去重收集共用（L253、L262），并且刻意不掩盖「玩家无 cell」这一硬失败。 |
| relevantRoomOwnershipCells（L232） | guard、phase（事务阶段名或 nil）。快照不完整即 `error`；先并入 guard.pendingCells；对每个在线玩家取权威坐标（缺失即 `error`），邻域命中或（事务阶段且是该 guard 的发起玩家）时加入其 cell；事务阶段若发起玩家不在线集合内，仍按其 cell 追加（注释 L259-260）；无任何 cell 时 `error`。返回 cell 数组。 | **必须**：同步扫描（generation 阶段/回滚后）的 cell 范围唯一决定者；它把「事务发起玩家可能暂时在 RV 外」这一点显式补齐，且拒绝在无法证明范围时静默继续。 |
| clearInvalidRoomOwnershipNearPlayers（L270） | guards、playerStates、snapshotOk、neighborhoodDue。snapshotOk 非真即 `error`；由 neighborhoodDue 决定最大半径（0 或 1）；对每个玩家、每个邻域格，收集命中 old/new bounds 的 guard（每个 guard 用自身 due 决定半径），命中则取该玩家的 cell 与 square，清理成功时为所有命中 guard 排一次全量复扫。无返回值。 | **必须**：每 tick 的低成本主动探测；它同时承担「发现残留后升级为全量复扫」的升级路径，是空等事件之外的唯一补救机制。 |
| roomOwnershipGuardKey（L317） | rvId、generation；返回 `tostring(rvId) .. ":" .. tostring(generation)`。 | **必须**：guard 键的唯一生成点，被注册（L342）、按身份查找（L379）、回滚查找（L484）三处共用；客户端有语义相同的镜像实现（见第 4 章）。 |
| registerServerRoomOwnershipGuard（L321） | generation、player、oldBounds、newBounds、rvId。rvId 为 nil/空串即 `error`；`requiredInteger(generation, "room ownership generation")` < 1 即 `error`；建立含 generation/rvId/player/oldBounds/newBounds/pendingCells/scanDueTick/nextNeighborhoodProbeTick 的 guard，写入 key，并**先删除同一 rvId 的其他 guard**；返回 guard。 | **必须**：guard 生命周期的唯一创建点；「一个 RV 身份只保留一个 guard」的规则（注释 L343-344：generation READY 之后的墙体/地板移除仍要能被修复）就在这里。消费方：GenerationFlow（[L206](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:206)）。 |
| refreshServerRoomOwnershipGuard（L354） | guard、phase（阶段名或 nil，仅用于日志）。取相关 cell 后对每个 cell 依次全扫 oldBounds 与 newBounds，累计清理数；清空 pendingCells/scanDueTick；cleared > 0 时打印带 generation/phase 的日志；返回 cleared。 | **必须**：同步全量扫描的唯一实现，四个场景共用：generation 构建前（GenerationFlow L224）、提交前后（L294/L300）、回滚后（L518）、事件排程到点（L436）。**源码事实**：形参只有 2 个，而 GenerationFlow L224 传了第 3 个实参 `true`（旧语义 requireFullNewRoof），该实参当前被忽略（见第 5 章第 1 条）。 |
| refreshGenerationRoomOwnershipGuard（L373） | rvId、generation、phase。generation 需为整数、rvId 非空串，否则 `error`；按 key 查 guard，非表即 `error`；委托 refreshServerRoomOwnershipGuard。返回清理数。 | **必须**：generation 流程按持久身份（而不是持有 guard 引用）复扫的入口；GenerationFlow 在提交前后两次调用（L294、L300），必须能证明「这个 rvId:generation 的 guard 仍存在」。 |
| processServerRoomOwnershipGuards（L386） | 无参数，读 `ctx.serverTick`。无 guard 直接返回；wallReloadActive 为真直接返回；建立一次权威玩家状态快照与 per-guard 的 neighborhoodDue（并预置下一次探测 tick）；快照可用且有玩家时 `pcall` 邻域探测，失败只打印；随后 `pcall` 处理到点的延迟全扫（先清 pendingCells/scanDueTick 再复扫），失败只打印。无返回值。 | **必须**：每 tick 调度入口（[RV_Server_Commands.lua:284](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:284) 调用）。**源码事实**：它把邻域探测的 snapshotOk 实参**硬编码为 true**（L420-421）；两级 pcall 是刻意的——本函数跑在没有 pcall 的公共 tick 里，一次扫描前提失败不能连带停掉边界扫描、utility tick 与 generation tick（注释 L415-418）。 |
| `processServerRoomOwnershipGuards` 中匿名函数（L431） | 无显式参数，捕获 `roomOwnershipGuards`、`ctx.serverTick`；遍历到点的 guard，先清 pendingCells/scanDueTick 再复扫。 | **实现必需**：延迟全扫的 pcall 体；「先清标记再扫描」保证一次抛错不会每 tick 重复（注释 L427-430）。 |
| copyRoomRefreshBounds（L446） | target（payload 表）、prefix（"old"/"new"）、bounds。对 14 个字段（wall/room/roof 的 min/max、z、roofZ）逐个 `ServerUtil.requiredInteger(bounds[field], label)` 写入 `target[prefix..field]`，缺失/非整数即抛错。无返回值。 | **必须**：服务端发给客户端的 footprint 必须是权威构造的整数边界；字段清单与客户端解析器逐字镜像（第 4 章）。 |
| armClientRoomOwnershipGuard（L459） | generation、oldBounds（可为 nil）、newBounds、rvId。构造 `{generation, rvId=tostring(rvId), hasOld=type(oldBounds)=="table"}`，hasOld 时复制 old 前缀，始终复制 new；随后无 player 重载地 `sendServerCommand(COMMAND_MODULE, COMMAND_REFRESH_ROOM_OWNERSHIP, payload)`（广播全体客户端），失败即 `error`。无返回值。 | **必须**：非请求玩家之后也可能走进已退休房间 footprint，所以生成前必须给所有在线客户端布防（注释 L470-471）。消费方：GenerationFlow（[L205](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:205)）。 |
| removeGeneration（L478） | cell、bounds、generation、rvId。任一身份/边界非法即 `error`；按 key 查 guard，缺失即 `error`；`ServerSchema.walkBounds` 内逐格 `ServerWorld.clearSquare(square, generation, rvId)`；再次 walkBounds 用 `strictSquareSnapshot` 统计仍带该 generation 标签的对象（快照不完整即 `error`），仍有残留即 `error`；最后 `refreshServerRoomOwnershipGuard(guard, "after-rollback")`。无显式返回值，失败抛错。 | **必须**：generation 失败回滚的唯一执行点，被 abortGeneration 在 pcall 中调用（[RV_Server_GenerationAck.lua:111](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationAck.lua:111)）。它同时是本模块唯一「写世界」的函数。 |
| `removeGeneration` 中匿名函数（L491） | 回调参数 square；调用 `ServerWorld.clearSquare(square, generation, rvId)` 清除本代对象。 | **实现必需**：按 owner+generation 标签清理的执行体；清除策略属于 ServerWorld（Common 层），本模块只提供身份与遍历。 |
| `removeGeneration` 中匿名函数（L500） | 回调参数 square；取严格快照（不完整即 `error`），累加仍带本代标签的对象数。 | **实现必需**：回滚的验证体，保证函数返回前已证明「本代标签对象为 0」；专用服务端上 `clearSquare` 的 pcall 成功不足以证明删除生效（注释 L495-498）。 |
| armTargetedClientRoomOwnershipGuard（L526） | player、generation、newBounds、rvId。player 为 nil 即 `error`；generation 经 `requiredInteger` 且 ≥ 1；rvId 非空；构造 `{generation, rvId, hasOld=false}` 并只复制 new 前缀；向**该玩家**发送同一条 RefreshRoomOwnership 命令，失败即 `error`。无返回值。 | **必须**：已有 RV 的进入/重连不经过 generation 广播（注释 L521-525），必须单独给这个客户端布防；它刻意不接受任何客户端坐标或几何，bounds 由调用方的服务端 manifest 提供。消费方：RecordValidation（[L204](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_Server_RecordValidation.lua:204)）。 |

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **已经复用的（源码事实，不需要再提取）**：Java 调用保护与数值校验走 [RV_ServerUtil.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerUtil.lua)（`invoke`、`callSucceeded`、`callGlobal`、`callGlobalSucceeded`、`toNumber`、`integer`、`requiredInteger`）；取格/取 cell/标签判定/清理走 [RV_ServerWorld.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua)（`getSquare`、`getCellForPlayer`、`clearSquare`、`strictSquareSnapshot`、`isTaggedForGeneration`）；bounds 遍历走 [RV_ServerSchema.walkBounds](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerSchema.lua:43)；结构坐标枚举走共享 [Layout.eachStructureCoordinate](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_Layout.lua:27)。本模块没有重复实现这些能力。
- **可提取机会 1：bounds 字段清单（净收益中）**。服务端 [copyRoomRefreshBounds:446-457](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:446) 与客户端 [readRoomRefreshBounds:34-59](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua:34) 各自硬编码同一份 14 字段清单。**语义差异（源码事实）**：服务端只做 `requiredInteger`（权威构造，必须抛错）；客户端额外校验 min ≤ max 且 room 必须落在 wall 内（拒绝 payload）。**净收益**：可共享「字段清单常量」，**不能**共享校验策略；提取为一个 shared 的字段顺序表 + 生成/迭代 helper，可消除 28 处字面量的漂移风险。这是本轮唯一建议的提取。
- **可提取机会 2：guard 键（净收益低）**。服务端 [roomOwnershipGuardKey:317-319](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:317) 与客户端 [RV_ContextMenu_RoomOwnership.lua:7-9](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua:7) 完全相同（`rvId:generation`）。可下沉到 shared Common 的键 helper；但两份实现都只有 2 行且键只在各自进程内使用，跨进程一致性由 payload 字段保证，**收益仅是风格统一**，不作为强建议。
- **不可提取：单格清理规则的两份实现**。客户端 [inspectRoomOwnershipSquare:96-108](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua:96) 与服务端 [clearInvalidRoomOwnershipSquare:51-74](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:51) 规则相同（有 room、无 roomDef → setRoomID(-1) → 复核），但**错误合同相反**：客户端用 pcall 且「无法检查/重置」返回 `false, 0` 让调用方排下一次重试，服务端读不到就抛错（fail-closed，服务端不许假装成功）。合并会迫使一侧接受错误的合同，属于「相似但不可共用」，应保留两份并在文档标注。
- **不可提取：玩家快照**。本模块的 `onlinePlayersSnapshot`（L147）语义是「权威玩家集 + 完整性布尔 + getPlayer 退回」；adapter 侧 [RV_RailroaderServer_WallReload.lua:62-99](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua:62) 的 `insidePlayersForRecord` 是「按 mapping/rider 关系筛 inside 成员 + identityKey」，两者输入输出都不同；`Adapter.onlinePlayersSnapshot` 已被本模块之外的 wall reload 复用，本模块直接用全局 `getOnlinePlayers` 更适合「全部 cell 都要扫」的需求，不必强行统一。

### 是否进一步拆分

- **建议保持单文件（562 行 / 30 函数）**。四类职责围绕同一个 guard 生命周期：清理原语被 bounds 扫描与邻域探测共享；邻域探测的升级路径写 pendingCells/scanDueTick，而这两个字段由调度器与同步扫描共同消费；回滚必须复用同一 guard 复扫；客户端布防依赖 guard 键。硬拆会把 guard 字段变成跨文件共享可变状态，需要引入队列对象才能守住不变量，成本高于 562 行的可读性收益。
- **第一候选拆分（若将来要拆）：`removeGeneration`（:478-519）与 `notifyFailure`（:31-49）**。这两者语义不属于 room ownership：前者是 generation 失败回滚（含按标签清理与严格验证），后者是向客户端发送 `RVTeleport` 失败包。**证据**：`removeGeneration` 的唯一调用者是 abortGeneration（[RV_Server_GenerationAck.lua:111](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationAck.lua:111)），`notifyFailure` 的三个调用点全在 generation 命令路径（Commands L372/L381、GenerationAck L138）。**边界与成本**：`removeGeneration` 结尾必须刷新房间 guard，拆出后仍可通过 `ctx.refreshServerRoomOwnershipGuard`（已导出）调用，成本低；收益是「回滚代码与 abortGeneration 相邻、命名与实际职责一致」。**建议**：本轮不改代码；若后续为 Construction 做拆分，把这两个函数一并迁走，并保留本模块对外的 8 个 guard/清理接口。
- **不建议拆分 `processServerRoomOwnershipGuards` 与探测函数（:232-444）**：`pendingCells`、`scanDueTick`、`nextNeighborhoodProbeTick` 三个字段在 6 个函数间交错读写（L119-122、L238、L337-339、L363-364、L406-413、L433-435），拆出需要一个 guard 队列对象并重新定义「谁清标记、谁排程」；当前注释已明确这些顺序是不变量（L427-430），拆分会把它们变成跨文件协议。
- **不建议按「清理 / guard / 回滚 / 客户端」拆成 4 个文件**：本包的历史证据表明过度拆分已被回退——旧 RoofRefresh 目录曾把屋顶相关职责拆成 7 个文件，现在是 1 个文件（见 [server-RoofRefresh.md](server-RoofRefresh.md)），分组搬运/ACK/最终返回统一收敛到 `WallReloadProtection/`。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

模块的对外合同**不是** `RV.Server.*`，而是装配期写回 `ctx` 的 10 个函数（[L552-561](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:552)）。逐个列出导出与真实消费者：

| ctx 导出 | 定义行 | 消费者（文件:行） |
|---|---:|---|
| ctx.notifyFailure | 31 | [RV_Server_Commands.lua:23](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:23)（调用 L372、L381）、[RV_Server_GenerationAck.lua:10](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationAck.lua:10)（调用 L138） |
| ctx.removeGeneration | 478 | [RV_Server_GenerationAck.lua:11](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationAck.lua:11)（调用 L111，pcall 内） |
| ctx.requestRoomOwnershipScan | 126 | [RV_Server_Commands.lua:24](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:24) → 事件注册 L393（`OnObjectAdded`） |
| ctx.requestRoomOwnershipRemovalScan | 143 | [RV_Server_Commands.lua:25](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:25) → 事件注册 L392（`OnObjectAboutToBeRemoved`） |
| ctx.registerServerRoomOwnershipGuard | 321 | [RV_Server_GenerationFlow.lua:23](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:23)（调用 L206） |
| ctx.refreshServerRoomOwnershipGuard | 354 | [RV_Server_GenerationFlow.lua:24](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:24)（调用 L224，**传 3 实参**） |
| ctx.refreshGenerationRoomOwnershipGuard | 373 | [RV_Server_GenerationFlow.lua:25](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:25)（调用 L294、L300） |
| ctx.processServerRoomOwnershipGuards | 386 | [RV_Server_Commands.lua:26](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:26)（调用 L284，每个 server tick） |
| ctx.armClientRoomOwnershipGuard | 459 | [RV_Server_GenerationFlow.lua:26](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:26)（调用 L205） |
| ctx.armTargetedClientRoomOwnershipGuard | 526 | [RV_Server_RecordValidation.lua:11](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_Server_RecordValidation.lua:11)（调用 L204，pcall 内） |

- **隐式装配顺序合同（源码事实）**：Core 在 [RV_Server.lua:141](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:141) 先安装本模块，再安装 GenerationFlow（L147）、RecordValidation（L148）、GenerationAck（L149）、Commands（L150）；后四者都在**加载时**用 `local x = ctx.x` 捕获函数引用。因此本模块必须在它们之前把 10 个导出写入 ctx，否则捕获到的是 nil——这是一条靠装配顺序维持、没有断言保护的合同。
- **客户端命令合同（源码事实）**：模块名 `"RailroaderRV"`、命令 `"RefreshRoomOwnership"`（payload：`generation`、`rvId`、`hasOld`，以及 `old*`/`new*` 各 14 个整数边界字段）。客户端路由在 [RV_ContextMenu_Relocation.lua:185-188](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua:185) → `beginRoomOwnershipRefresh`；客户端每 tick 在 [RV_ContextMenu_Relocation.lua:327-329](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua:327) 调 `updateRoomOwnershipGuards`。失败方向使用另一条命令 `"RVTeleport"` 且 `ok=false`（L45-48）。
- **与 RoofRefresh 的关系（源码事实）**：两者**互不引用**。RoofRefresh 是 `RailroaderRV.RoofRefresh.run(player, bounds)`（[RV_RoofRefresh.lua:124](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:124)），不接受也不校验房间身份；RoomOwnership 只通过 `isWallReloadTransactionActive` 间接与「触发 RoofRefresh 的那次搬运」互斥。两者共同的上游是 `WallReloadProtection`：搬运完成回调里调 RoofRefresh（[RV_RailroaderServer_WallReload.lua:109](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua:109)），搬运期间 RoomOwnership 暂停（L400）。

### 直接读写其他模块的数据

| 位置 | 访问内容 | 判断 |
|---|---|---|
| [L12](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:12) → 读：[L119-122](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:119)、[L133-138](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:133)、[L238-243](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:238)、[L331-350](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:331)、[L355-364](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:355)、[L388-439](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:388)、[L484-487](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:484) | `ctx.roomOwnershipGuards`（容器由 [Core/RV_Server.lua:88](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:88) 创建、[L131](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:131) 注入） | **guard 状态 owner 明确**：容器由装配层持有，内容（key、generation、rvId、player、oldBounds、newBounds、pendingCells、scanDueTick、nextNeighborhoodProbeTick）由本模块独占读写；全树检索确认**没有任何其他模块**触碰这些字段。因此这里**不需要** getter/setter 接口：加一层只会把字段操作切成薄包装。容器本身由 ctx 注入（而不是本模块 `require` 时自建）是既有装配约定，代价是「guard 容器在工厂执行前就存在」这一隐性前提。 |
| [L122](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:122)、[L339](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:339)、[L408](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:408)、[L411](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:411)、[L433](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:433) | `ctx.serverTick` | **可变共享字段直读**（owner：[RV_Server_Commands.lua:267](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:267) 每 tick 写入）。本模块只读，用于 guard 的 1-tick 延迟与 120-tick 邻域周期。**判断**：这是服务内部 tick 约定，同一字段另有 GenerationFlow/PlayerValidation/GenerationAck 等 6 处读者；改成 `Core.getTick()` 调用需要本模块额外 require Core，收益仅是少一个共享可变量。**建议**：保留现状，但应把它记为「跨模块可变字段」而不是模块 API。 |
| [L21-29](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:21) | `RailroaderRV.Server.isWallReloadTransactionActive`（由 [RV_RailroaderServer_WallReload.lua:246-258](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua:246) 发布） | **已经是接口调用**（正确方向），并且是 fail-closed：服务缺失/接口缺失/pcall 失败/返回非布尔一律视为「忙」。这里**不再**像旧报告描述的那样直读 `ctx.roofRefreshRelocationGroup`/`ctx.roofRefreshGroupFinalReturn`——那些字段已不存在（全树 0 命中）。 |
| [L3](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:3) → [L81](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:81) | `require("RailroaderRV/RoomTemplate/RV_Layout").eachStructureCoordinate` | 直接 require 共享纯函数模块，而不是经 ctx 注入。**判断**：该函数是共享只读坐标规划 API（[RV_Layout.lua:27](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_Layout.lua:27)），不持有状态；与 ctx 注入风格不一致，但收益低，可保留。 |
| [L82](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:82)、[L113](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:113)、[L225](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:225)、[L303](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:303)、[L305](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:305)、[L491-492](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:491)、[L500-507](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:500) | `ServerWorld.getSquare/getCellForPlayer/clearSquare/strictSquareSnapshot/isTaggedForGeneration`、`ServerSchema.walkBounds` | 显式 Common 层公开函数调用；`clearSquare(square, generation, rvId)` 与 `strictSquareSnapshot` 是本模块唯一的「直接写世界」路径（其余都是格的 roomID 修正）。 |
| [L40-44](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:40) | `Constants.INVALID_RV_DATA` | 只读常量，用于把失败文本规范化成协议错误码后发给客户端。 |

**未发现**本模块读写其他 Lua 模块的私有运行时表；唯一的跨模块状态耦合是 `ctx.serverTick`（可变字段）与 `RV.Server.isWallReloadTransactionActive`（函数接口）。

### 接口边界问题

1. **`refreshServerRoomOwnershipGuard` 的实参个数与旧语义（源码事实）**：定义只有 2 个形参（[L354](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:354)），而 [GenerationFlow:223-225](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:223) 传了 3 个实参（第 3 个为 `true`，旧签名里是 `requireFullNewRoof`）。Lua 静默忽略多余实参，因此**该策略开关已失效**。**条件性推断**：这个差别在运行时不会报错，也不会改变「构建前全量扫 old+new footprint」的当前行为（当前实现本来就全扫）。**建议**：要么删除调用点的第 3 个实参以消除误导，要么恢复形参并在实现中明确它控制什么；二者都需要改代码，本轮不改。
2. **`notifyFailure` 的归属与命名（源码事实）**：它住在 RoomOwnership 模块里，但发送的是 `"RVTeleport"` 失败包（L45-48），消费方全是 generation 路径。**判断**：功能上正确（客户端需要一个统一失败提示），但模块归属与命名会让读者以为它是房间所有权专用。**建议**：随第 4 章第一候选拆分一起迁到 generation 失败/回滚模块；当前不宜只改名字（那会造成引用点全改而无行为收益）。
3. **`removeGeneration` 跨职责（源码事实）**：名字是 generation 回滚，实现里包含按标签清理、严格验证与房间 guard 复扫（[L518](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:518)）。**判断**：复扫是必要的（回滚删掉墙体/地板，必须重查退休 roomID，注释 L516-517），属于两个模块的正当协作；问题只在归属，不在耦合方式。
4. **`processServerRoomOwnershipGuards` 硬编码 snapshotOk（源码事实）**：[L419-421](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:419) 在已知 `snapshotOk == true` 的分支内仍向 `clearInvalidRoomOwnershipNearPlayers` 传字面量 `true`。当前**等价**，但掩盖了「该函数自己也会检查 snapshotOk 并抛错」的契约（L272-274）。属可读性/一致性缺陷。
5. **`requestRoomOwnershipRemovalScan` 丢弃 hit（源码事实）**：[L143-145](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:143) 调 `requestRoomOwnershipScan(object, true)` 后丢弃返回值；全树检索确认 `includeOutcome` 无其他消费者。旧报告的「包装用途在事件层记录结果」已不存在。**判断**：`hit` 计算是当前无消费者的死值；可简化为 `requestRoomOwnershipScan(object)`，行为不变（事件处理器本来也不返回值）。
6. **客户端同名状态与服务端无共享（源码事实）**：客户端 [RV_ContextMenu_RoomOwnership.lua:5](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua:5) 自建 `roomOwnershipGuards`，字段是 `key/rvId/generation/oldBounds/newBounds/currentCheckErrorLatched/nextScanTick`，与服务端 guard 字段**不同名不同义**。两端唯一的合同是 `RefreshRoomOwnership` payload；这意味着任何 payload 变更必须同时改两侧（服务端 [copyRoomRefreshBounds](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:446) / 客户端 [readRoomRefreshBounds](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua:34)），当前没有任何自动校验拦住漂移——这是本模块对外最脆的边界。

## 函数清单、覆盖和验证记录

**文件与函数总数（与 shell 机械核对一致）**

| 文件 | 行数 | `function` 关键字命中 | 其中类型判定 | 函数定义数 |
|---|---:|---:|---:|---:|
| RV_Server_RoomOwnership.lua | 562 | 31 | 1（L24 的 `type(...) ~= "function"`） | 30 |
| **总计** | **562** | **31** | **1** | **30** |

**函数索引（相对路径 TAB 起始行 TAB 函数名 TAB kind）**

```text
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	2	(anonymous outer factory)	anon
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	21	wallReloadActive	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	31	notifyFailure	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	51	clearInvalidRoomOwnershipSquare	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	78	clearInvalidRoomOwnershipBounds	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	81	(anonymous)	anon
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	90	coordinatesInRoomOwnershipBounds	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	99	objectCoordinates	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	117	scheduleRoomOwnershipScan	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	126	requestRoomOwnershipScan	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	143	requestRoomOwnershipRemovalScan	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	147	onlinePlayersSnapshot	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	180	authoritativePlayerCoordinates	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	197	authoritativePlayerStatesSnapshot	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	210	playerNeighborhoodTouchesGuard	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	224	addScanCell	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	232	relevantRoomOwnershipCells	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	270	clearInvalidRoomOwnershipNearPlayers	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	317	roomOwnershipGuardKey	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	321	registerServerRoomOwnershipGuard	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	354	refreshServerRoomOwnershipGuard	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	373	refreshGenerationRoomOwnershipGuard	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	386	processServerRoomOwnershipGuards	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	431	(anonymous)	anon
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	446	copyRoomRefreshBounds	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	459	armClientRoomOwnershipGuard	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	478	removeGeneration	local
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	491	(anonymous)	anon
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	500	(anonymous)	anon
contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua	526	armTargetedClientRoomOwnershipGuard	local
```

**覆盖与验证**

- 覆盖：上表 30 条即本文件全部函数定义；「逐文件、逐函数分析」表同样 30 行，条目一一对应，无遗漏、无多记。
- 未计入项（源码事实）：[L16](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:16) 的 `ROOM_OWNERSHIP_3X3_INTERVAL_TICKS` 常量、[L552-561](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:552) 的 10 个 `ctx.X = localFunction` 导出别名赋值（按口径不重复计数，已在「公开合同」表列出）、以及 [L24](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:24) 的 `type(...) ~= "function"` 能力判定。
- 只读验证：目录清单（1 文件、23,344 字节）、行数（562）、`function` 关键字扫描（31 命中 → 30 定义）、逐行全文读取、全树检索 10 个导出名 + `roomOwnershipGuards` + `ctx.serverTick` + `isWallReloadTransactionActive` + 客户端 payload 消费者。**未运行任何测试脚本或游戏进程。**
- 未覆盖项：本报告不包含运行时验证。第 5 章第 1 条（第 3 个实参被忽略）与第 5 条（hit 被丢弃）是源码事实；其余带「条件性推断」标记的结论需要在联机运行时（生成一次 RV、拆除外墙、触发一次失败回滚）观察 guard 日志 `room ownership refresh generation=… cleared=…` 才能定论。
