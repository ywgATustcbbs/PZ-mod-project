# server/RailroaderRV/RoofRefresh 模块分析

## 假设、范围、成功条件与验证方式

- **假设（源码事实）**：分析范围严格限于 `media/lua/server/RailroaderRV/RoofRefresh/` 的当前直接子文件。本次列目录确认该目录**只有 1 个 Lua 文件**：[RV_RoofRefresh.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua)，131 行、5,476 字节。所有行号来自本次逐行读取的当前源码。
- **旧报告作废声明（源码事实）**：本文件的历史版本声称本目录含 7 个文件、4,331 行、143 个函数表达式，并逐函数描述了 `RV_RailroaderServer_RoofRefresh.lua`、`RV_RailroaderServer_RoofRefreshFlow.lua`、`RV_Server_RoofApi.lua`、`RV_Server_RoofDestinations.lua`、`RV_Server_RoofRelocation.lua`、`RV_Server_RoomOwnership.lua`。**这些文件当前全部不存在**（只有 `RV_RoofRefresh.lua` 存活；RoomOwnership 已迁到独立目录 `server/RailroaderRV/RoomOwnership/`）。对 `contents/mods/RailroaderRVTest/42/media/lua` 全树的正则检索确认：`roofRefreshRelocationGroup`、`roofRefreshGroupFinalReturn`、`roofRefreshGroupFailure`、`acknowledgeRoofRefreshRelocation`、`isRoofRefreshTransactionActive`、`beginRoofRefreshRelocationGroup`、`RoofRelocation`、`RoofApi`、`RoofDestinations`、`finalReturn` 全部 **0 命中**。旧报告的整份函数清单（`isLoaded`、`_busy`、`capturedFloorMismatch`、`roomRefreshFloorTarget`、`worldSquareIsValid`、`groupClaims`、`promoteFollowUpWallRemoval` 等）在当前源码中不存在，本报告不保留其任何条目。
- **范围**：覆盖本目录当前唯一文件的全部具名/local 函数、表方法与作为回调的匿名函数表达式；只读检查调用方与相邻模块，用于判定本模块**当前**的职责边界、对外接口与跨模块数据访问。唯一写入目标是本报告。
- **成功条件**：目录清单与函数数在 shell 扫描、`function` 关键字扫描和逐行读取三者间一致；每个函数有精确起始行、参数语义、返回/副作用、模块语义与必要性结论；明确区分「源码事实」与「条件性推断」；说明屋顶/房间重算、分组搬运、ACK、最终返回、状态 owner 当前实际落在哪个模块哪个文件与函数上。
- **验证方式**：`Get-ChildItem` 列目录；`Get-Content` 统计行数；`Select-String '\bfunction\b'` 扫描（本文件 12 处命中，其中 2 处是 `type(...) == "function"` 类型判定，故函数定义 10 个）；全文逐行读取交叉核对定义与起始行；对全 `media/lua` 树检索本模块导出 API 的调用点与 roof/room ownership 符号。全部为静态只读分析，**不运行游戏或任何测试**。

## 目录职责与清单

本目录当前是**单一叶子服务**：它把「当前模板声明的屋顶/房间刷新点」翻译成一次同步的世界格重算，不拥有任何事务、队列、重试、租约或搬运状态。文件头注释（[RV_RoofRefresh.lua:1-8](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:1)）明确声明：每个声明点在一个同步周期内刷新（临时未标记地板被创建后再移除），模板声明的地板对象永不被本路径替换，且 **"this module owns no transaction, retry or relocation state"**。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_RoofRefresh.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua) | 10 | 模板驱动的屋顶/房间重算：按模板刷新点派生世界格、创建并移除临时未标记地板、执行已验证的 square 重算序列（EnsureSurroundNotNull / RecalcProperties / checkHaveRoof / clearWater / RecalcAllWithNeighbours / IsoRegions.squareChanged） |
| **总计** | **10** | 1 个文件、131 行：8 个具名 `local function`、1 个匿名回包体（pcall 内）、1 个表方法 `Refresh.run` |

函数口径：计入具名函数、`local function`、表方法、以及作为参数/回调的匿名函数表达式（[RV_RoofRefresh.lua:82](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:82) 的 pcall 闭包）。不计入 :17-20 的命名空间赋值与 :131 的 `return Refresh`。

## 逐文件、逐函数分析

### RV_RoofRefresh.lua

模块在 require 阶段（[RV_RoofRefresh.lua:10-15](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:10)）读取共享模板与公共层：`RoomTemplate.get(TEMPLATE_ID)`、`RoomTemplate.roofRefreshPoints`、`RoomTemplate.orderedObjects`、`ServerUtil`、`ServerWorld`；随后在全局命名空间挂出 `RailroaderRV.RoofRefresh`（:17-20），文件返回该表（:131）。它不注册任何事件、不写 ModData、不持有运行时状态表，唯一公开方法是 `Refresh.run`。当前模板 `RV_Template.lua:30-32` 只声明 **1 个**刷新点 `{x=-4, y=3, z=0, templateIndex=34}`，所以循环体当前只执行一次，但实现按「点集」写成通用形式。两个调用方都是外部模块（见第 4、5 章），本文件不 require 它们中任何一个。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| coordinate（L22） | x、y、z 任意可 tostring 值；返回 `"x,y,z"` 字符串，无副作用。 | **保留理由**：仅作诊断文本（L41 未加载原因、L109 成功原因），内联完全可行；保留是为了两处消息共用同一坐标格式。 |
| fail（L26） | reason 任意值；打印 `[RailroaderRVTest] roof refresh failed: <reason>`，返回 `false, reason`。 | **必须**：本模块唯一的失败出口，`Refresh.run` 的两条失败分支（L126、L127）都经它返回。 |
| pointCell（L33） | bounds（含 `anchor.x/anchor.y/z` 的 flat bounds 记录）、point（模板偏移 `{x,y,z}`）；返回三个世界坐标数，无副作用。 | **必须**：世界格坐标的**唯一**推导点，且只从**当前** bounds 锚点推导（注释 L31-32 明示绝不使用已存坐标）；删掉它就必须在调用处重复「锚点 + 模板偏移」这条安全规则。 |
| loadedSquare（L38） | cell、x、y、z；经 `ServerWorld.getSquare` 取格，取不到时返回 `nil, "roof refresh square is not loaded at x,y,z"`。 | **必须**：刷新前必须证明目标格已加载，且失败原因要能定位到具体格。 |
| createTemporaryFloor（L51） | cell、square、sprite；用 `ServerUtil.invokeClass(rawget(_G,"IsoObject"), {{cell, square, sprite}})` 直接构造，构造失败即 `error`；再要求 `square:transmitAddObjectToSquare(temporary, -1)` 成功，失败即 `error`；成功返回临时对象。副作用：向世界格加入一个**不带 generation 标记**的地板对象。 | **必须**：这是「不碰模板自身地板对象」的关键实现（注释 L46-50 说明 `IsoGridSquare.addFloor` 会删掉同格所有 solid floor，从而毁掉模板捕获对象与它的 generation tag），没有等价替代路径。 |
| recalcSquare（L65） | cell、已捕获 square；先保护读取 `getX/getY`，再顺序要求 `EnsureSurroundNotNull`、`RecalcProperties`、`cell:checkHaveRoof(x,y)`、`clearWater`、`RecalcAllWithNeighbours(true)` 全部成功，最后读 `IsoRegions.squareChanged` 并调用它，可选触发 `IsoGridSquare.setRecalcLightTime(-1)`。返回 `true` 或 `false, 原因`。副作用：重算该格属性、房间与邻格缓存。 | **必须**：本模块的世界状态刷新本体；任何一步失败都返回带原因的三元组而不是静默成功。 |
| `recalcSquare` 中匿名函数（L82） | 无显式参数，捕获 `regions`（`rawget(_G,"IsoRegions")`）；由 `pcall` 调用并返回 `regions.squareChanged`。 | **实现必需**：Java 绑定静态属性读取本身可能抛错（L85 随后要求它确实是 function），不能让它逃出 `recalcSquare`。 |
| refreshPoint（L98） | cell、bounds、单个模板刷新点；派生世界格 → 加载门 → 取 `templateObjects[point.templateIndex].sprite` → 创建临时地板 → `ServerWorld.removeGenericObject(square, temporary)` 移除它 → 调 `recalcSquare`。成功返回 `true, "room synchronized at x,y,z"`，失败返回 `false, 原因`。 | **必须**：把「声明点」落实为一次完整、可诊断的刷新单元，是 `refreshAllPoints` 的循环体。 |
| refreshAllPoints（L112） | player、bounds；用 `ServerWorld.getCellForPlayer(player)` 取权威 cell（不可用时抛错，由外层 pcall 兜住），按 `#refreshPoints` 顺序逐点调用 `refreshPoint`；首个失败即返回 `false, pointReason`，全部成功返回 `true, 最后一点的原因`。 | **必须**：同步批处理的唯一实现，也是 `pcall` 的受保护目标；模板点数为 0 时返回 `true, nil`（当前模板有 1 点，不触发该分支）。 |
| Refresh.run（L124，表方法，文件唯一导出） | player、bounds；`pcall(refreshAllPoints, player, bounds)`；`pcall` 失败时 `fail(refreshed)`（异常文本作为 reason），`refreshed ~= true` 时 `fail(reason)`，否则返回 `true, reason`。副作用：打印失败日志 + 世界格重算。 | **必须**：对外唯一入口，被 2 个外部模块调用（见第 5 章）；它把「抛错」与「返回 false」折叠成同一 fail-open 语义，调用方只需判断首返回值。 |

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **通用性最强的部分已经复用，不需要再提取**：坐标/数值/方法保护调用统一走 [RV_ServerUtil.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerUtil.lua)（`invoke`、`callSucceeded`、`invokeClass`），取格与删除对象统一走 [RV_ServerWorld.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua)（`getCellForPlayer`、`getSquare`、`removeGenericObject`）。旧报告建议的「二次实现 toNumber/invoke/callGlobal/integer」在本文件已不存在（源码事实：全文件无这些本地实现）。
- **模板声明点是真正的共享合同**：刷新点由 [RV_Template.lua:30-32](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_Template.lua:30) 声明，由 [RV_RoomTemplate.lua:94-115](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_RoomTemplate.lua:94) 在加载时校验「每个点必须命中同坐标的捕获条目」，再由本模块消费。这是「模板驱动」的唯一证据链，**不建议**把校验或点集下沉到本模块。
- **`recalcSquare` 的重算序列具有跨模块通用性（证据）**：[RV_ServerWorld.lua:433](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua:433) 的 `recalcSquare(square)` 只做 `RecalcProperties` + `RecalcAllWithNeighbours(true)`。两者语义**不同**：本模块额外要求 `EnsureSurroundNotNull`、`checkHaveRoof`、`clearWater`、`IsoRegions.squareChanged` 与灯光重算，并逐项 fail-closed。**净收益**：若强行合并，通用版会被迫接受「房间同步 + IsoRegions」这些屋顶/房间专属语义，或本模块要接受「重算不保证房间同步」的弱化。结论：保留两份实现，但在文档层面标注「本模块的序列是房间级强同步，Common 版是格级属性重算」。
- **`coordinate` 式坐标键**在客户端/服务端多处重复（本文件 L22-24、[RV_Server_RoomOwnership.lua:317-319](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:317) 的 guard key、客户端 [RV_ContextMenu_RoomOwnership.lua:118](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua:118) 的 `seen` 键）。可提取为共享 `identityKey`/坐标键 helper（[RV_Common.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_Common.lua) 已有 `identityKey`）。**净收益低**：三处格式不同（`x,y,z` / `rvId:generation` / `x:y:z`），统一会改变诊断文本与去重键，收益仅是少几行；不作为本轮建议项。

### 是否进一步拆分

- **不需要进一步拆分（源码事实 + 判断）**：当前 131 行只承担「刷新点 → 世界格 → 临时地板 → 重算」这一条闭环，没有第二类职责可切；文件内 8 个 local helper 都只服务 `Refresh.run` 一条路径，且除 `Refresh.run` 外没有任何外部调用点。
- **相反方向的历史证据**：本目录曾经把「分组搬运/ACK/final-return/重试/presence 采样」拆成 5 个额外文件（旧报告描述），当前已被删除或合并（见第 5 章：这些职责现在落在 `WallReloadProtection/`）。这说明「按职责拆成多文件」在本包内已被验证为过度拆分，本模块保持单文件是有意的收敛。
- **不建议的拆分**：把 `recalcSquare` 的引擎调用序列抽成「EngineIsoRegionRefresher」之类的独立模块没有当前收益——它只服务一条调用链，且失败的 reason 文本直接面向 `WallReload`/entry 日志。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **模块返回值**：`return Refresh`（[RV_RoofRefresh.lua:131](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:131)），同时挂在全局 `RailroaderRV.RoofRefresh`（:17-20）。**唯一公开方法**：`Refresh.run(player, bounds)`（:124）。
- **参数合同（源码事实）**：`player` 是服务端权威玩家对象（用于 `getCellForPlayer`）；`bounds` 是 [RV_ServerSchema.lua:13](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerSchema.lua:13) `boundsFor` 产出的 flat bounds，本模块只读 `bounds.anchor.x/anchor.y` 与 `bounds.z`（:34-35）。**本模块不接受也不校验 RV 身份（rvId/generation/bitmapVersion）**：谁调用谁负责在调用前证明身份。
- **返回合同**：`true, detail` 或 `false, reason`；不抛错（内部 `error` 一律由 :125 的 pcall 折叠）。两个调用方都把非 `true` 当作「本次不刷新」而非致命错误。
- **调用点（全树检索，仅 2 处）**：
  1. [RV_RailroaderServer_WallReload.lua:12](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua:12) `require`，并在 :104-119 的 `runRoofRefresh(player, bounds)` 中 `pcall(RoofRefresh.run, player, bounds)`；该回调经 :217-220 `WallReload.begin({rvId, generation}, runRoofRefresh)` 注册为「全员回到 RV 之后」的收尾步骤。
  2. [RV_Server_RecordValidation.lua:131-149](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RVMapping/RV_Server_RecordValidation.lua:131) 的 `RV.Server.refreshRoofVisuals(player, record)`：进入/重连路径在重验 boundary/manifest 身份后 `pcall(RoofRefresh.run, player, bounds)`；其唯一消费者是 [RV_RailroaderServer_Mapping.lua:172-194](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Mapping.lua:172) 的 `refreshRoofForPlayer`（entry/reconnect）。

### 直接读写其他模块的数据

| 位置 | 访问内容 | 判断 |
|---|---|---|
| [RV_RoofRefresh.lua:10-13](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:10) | `RoomTemplate.get/roofRefreshPoints/orderedObjects`，并在 :12-13 缓存为模块级 `refreshPoints`/`templateObjects` | 显式模块 API + 只读共享模板数据；`orderedObjects` 返回的是 `RV_RoomTemplate.lua` 内部 `objectsByIndex` 表的**原引用**。模板是本次加载期的不可变产物，直读可接受；若要收紧，应由 RoomTemplate 提供一个只读投影，但当前收益低。 |
| [RV_RoofRefresh.lua:102](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:102) | `templateObjects[point.templateIndex].sprite` 直接下标 + 字段读取，**无 nil/类型检查** | **边界问题（源码事实）**：安全性依赖 [RV_RoomTemplate.lua:94-115](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_RoomTemplate.lua:94) 在 require 期的强校验（每个 `templateIndex` 必须存在且坐标一致，否则加载即报错）。**条件性推断**：因为 RoomTemplate 在 :10 先于本模块被 require，且校验在 RoomTemplate 加载期完成，运行期下标不会为 nil；因此现状可接受，但一旦模板校验被弱化，本行会变成 nil 索引错误。 |
| [RV_RoofRefresh.lua:39/106/113](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:39) | `ServerWorld.getSquare` / `ServerWorld.removeGenericObject` / `ServerWorld.getCellForPlayer` | 三个都是 ServerWorld 的公开函数；`getCellForPlayer` 在无 cell 时抛 `no IsoCell available`，本模块靠 :125 的 pcall 折叠为 `false, reason`。属接口调用，非私有状态直读。 |
| [RV_RoofRefresh.lua:78-93](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:78) | `rawget(_G, "IsoRegions")`、`rawget(_G, "IsoGridSquare")`、`IsoGridSquare.setRecalcLightTime` | 引擎全局能力探测，不是其他 Lua 模块的数据；`setRecalcLightTime` 按「可用则调用」处理（:91-94），不影响返回值。 |
| [RV_RoofRefresh.lua:52](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:52) | `rawget(_G, "IsoObject")` + `ServerUtil.invokeClass` | 引擎类构造入口；`invokeClass` 是 Common 层的公开函数，失败由本模块转成 `error`。 |

**未发现**本模块读写其他 Lua 模块的私有运行时表：本模块没有 ctx 注入，不接触 `roomOwnershipGuards`、`operations`、`GenerationTransaction` 等任何兄弟模块状态。

### 接口边界问题

1. **屋顶分组搬运 / ACK / 最终返回 / 状态 owner 当前不在本模块，而在 `WallReloadProtection/`（源码事实）**：
   - 分组（一次操作持有全部 RV 内成员）：[RV_WallReloadProtection.lua:403-440](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_WallReloadProtection.lua:403) `captureMembers`，容器 `operations`（:21），发起入口 `M.begin`（:445）。
   - ACK：[RV_WallReloadProtection.lua:383-399](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_WallReloadProtection.lua:383) `M.acknowledge(player, token)`（token 作用域、无坐标）；服务端接线在 [RV_Server_GenerationAck.lua:16-28](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationAck.lua:16)（`RelocateAck` 先交给 wall reload，再退回 generation 分支）。
   - 阶段推进与最终归位：[RV_WallReloadProtection.lua:337-377](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_WallReloadProtection.lua:337) `M.onTick` + `advanceMoveOut`（:275）/`advanceWaitReload`（:301）/`advanceReturn`（:324）。
   - **跨模块 mutex 的 owner**：`RV.Server.isWallReloadTransactionActive`，由 [RV_RailroaderServer_WallReload.lua:246-258](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua:246) 发布，内部走 `M.isWallReloadActive`（[RV_WallReloadProtection.lua:52](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_WallReloadProtection.lua:52)）。消费方：RoomOwnership（:21-29）、GenerationFlow（:333-342）、BoundaryValidation（:33-38）、Sentinel（:33-38）、UtilityServer（:78-79）。
   - **「最终返回 owner」这一状态当前不存在**（源码事实）：全树 `finalReturn` 0 命中；失败路径 [RV_WallReloadProtection.lua:229-254](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_WallReloadProtection.lua:229) `finishFailure` 只做一次尽力归位后即 `clearOperation(op)`（:248），不保留后续重试账本（模块头注释 :8-11 明确「no queue, no retry ledger, no persisted transaction」）。
   - **`ROOF_REFRESH_*` 命名是残留**（源码事实）：`Constants.ROOF_REFRESH_REMOTE_OFFSET_X/Y/Z`（[RV_Constants.lua:94-96](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_Constants.lua:94)）现在只被 wall reload 的 `temporaryDestination`（[RV_WallReloadProtection.lua:72-74](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_WallReloadProtection.lua:72)）使用；`RefreshRoomOwnership`/`ROOF_REFRESH_HALO_TEXT` 之类的 roof 命名同样落在别的模块。
   - **结论**：本模块的**当前职责边界**是「被调用时执行一次模板驱动的房间/屋顶同步」。它不判定谁该刷新、不给成员分组、不处理 ACK、不持有返回状态、不做重试；这些全部由 `WallReloadProtection`（服务 U 与适配层）以及 `RVMapping` 的进入/重连路径负责，本模块只提供其中的一步世界变更。
2. **没有重入/并发门（源码事实）**：旧报告的 `_busy` 锁字段已不存在；`Refresh.run` 可在同一 tick 被不同调用链各调用一次（wall reload 收尾 + entry/reconnect）。**条件性推断**：两条调用链的触发条件不同（前者要求一次墙体移除且全员归位，后者要求进入/重连），同时命中的概率低；重算本身幂等（临时地板创建→移除→重算），重复执行只增加引擎开销，不改变终态，因此当前不设锁是可接受的取舍。若未来出现第三条周期调用链，应在此处恢复一个显式 fail-open 的重入门。
3. **临时地板在失败路径可能残留（条件性推断）**：[refreshPoint:103-106](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:103) 先创建临时地板，随后才调 `ServerWorld.removeGenericObject`；如果该删除失败/抛错（例如 `squareContainsObject` 复核不通过），错误会一路冒泡到 :125 的 pcall 变成 `false, reason`，而**本模块没有补偿路径**。该临时对象不带 generation/rvId 标记，因此 generation 回滚的 `ServerWorld.clearSquare(square, generation, rvId)`（[RV_Server_RoomOwnership.lua:492](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:492)）不会清理它。**这是静态分析得出的风险点，不是已确认的运行时缺陷**；判定需要联机运行时观察该格对象，本轮不运行测试。

## 函数清单、覆盖和验证记录

**文件与函数总数（与 shell 机械核对一致）**

| 文件 | 行数 | `function` 关键字命中 | 其中类型判定 | 函数定义数 |
|---|---:|---:|---:|---:|
| RV_RoofRefresh.lua | 131 | 12 | 2（L85、L92 的 `type(...) == "function"`） | 10 |
| **总计** | **131** | **12** | **2** | **10** |

**函数索引（相对路径 TAB 起始行 TAB 函数名 TAB kind）**

```text
contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua	22	coordinate	local
contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua	26	fail	local
contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua	33	pointCell	local
contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua	38	loadedSquare	local
contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua	51	createTemporaryFloor	local
contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua	65	recalcSquare	local
contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua	82	(anonymous)	anon
contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua	98	refreshPoint	local
contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua	112	refreshAllPoints	local
contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua	124	Refresh.run	method
```

**覆盖与验证**

- 覆盖：上表 10 条即本文件全部函数定义；「逐文件、逐函数分析」表同样 10 行，条目一一对应，无遗漏、无多记。
- 未计入项（源码事实）：:17-20 的 `RailroaderRV.RoofRefresh` 命名空间赋值、:131 的 `return Refresh`、以及 :85/:92 的 `type(...) == "function"` 能力判定。
- 只读验证：目录清单（1 文件）、行数（131）、`function` 关键字扫描（12 命中 → 10 定义）、逐行全文读取、全树符号检索（本模块 2 个外部调用点；旧报告符号 0 命中）。**未运行任何测试脚本或游戏进程。**
- 未覆盖项：本报告的结论不包含运行时行为验证；第 4 章第 3 条的临时地板残留风险、第 5 章第 2 条的重入门判断都需要联机运行时观察才能定论。
