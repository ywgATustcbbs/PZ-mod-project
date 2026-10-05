# server/RailroaderRV/Water 模块分析
> **状态（RailroaderRV 1.0）**：本文件是静态审计记录；其行号、计数和源码结论并非本次发布的全量重核，也不是运行时验证。当前实现以 [源码](../../contents/mods/RailroaderRV/42/) 与 [README](../../README.md) 为准，项目约束以 [agents.md](../../../agents.md) 为准。历史建议不构成修复授权，采纳前须按现行约束重新取证。

## 假设、范围、成功条件与验证方式

- **假设**：`contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/` 下当前 5 个 Lua 文件构成本报告要分析的服务端水务模块；共享身份/能力目录、Store、UtilityServer、客户端菜单与官方 Lua/Java 只作接口交叉核对，不纳入本模块函数清单。这里的“服务端 Water”按当前 B42 服务端调用语义解释。
- **范围**：覆盖本目录 5 个文件及其全部具名函数、`local function` 与表方法；只读检索 `media/lua` 全树判断公开 API 的调用点、事件接线与跨模块数据访问。唯一写入目标是本报告。
- **成功条件**：每个函数都有精确起始行、参数含义、返回值或副作用、模块语义和必要性判断；给出复用/提取/拆分结论；逐条列出直接读写其他模块数据的位置与是否应改为接口；对旧报告的两处静态发现（恒真表达式、`onObjectRemoved` 接线）给出当前源码结论；所有结论区分“源码事实”与“条件性推断”。不修改源码、不运行游戏或测试脚本。
- **验证方式**：列目录与行数（shell）；用两条独立的正则扫描（`local function` / `function Name` / `= function(`）统计函数定义数并逐条对照起始行；逐行编号通读 5 个文件；对 `onObjectRemoved`、`onTick`、`identityKey`、`exactKeys`、`squareSnapshot`、`strictSquareSnapshot`、`objectModData`、`sinks`、`Water.` 等关键字做全树检索，并核对调用点（`Core/RV_UtilityServer.lua`、`Core/RV_Server_Commands.lua`、`Core/RV_UtilityStore.lua`、客户端菜单/面板）。源码扫描是静态分析，不替代运行时验证。

## 目录职责与清单

本目录当前只承担一件服务端事务：把客户端提交的“水槽连接意图 + 目标提示”重新解析为服务端确认的世界对象，核对当前 RV mapping 身份与距离权限，给对象写入当前水槽身份标签，切换原生外接水状态，并把连接事实写入 canonical water ledger 后提交。旧版报告描述的异步移除见证（pending removal / reconcile 状态机）、ledger 结构校验与失败补偿在当前源码中**已不存在**（见接口边界问题 S2）。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_UtilityWater.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater.lua) | 1 | Water 模块唯一公开门面：把 `Commands.setConnection` 作为 `Water.setConnection` 转发给 Core |
| [RV_UtilityWater_Commands.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Commands.lua) | 2 | 连接事务编排：工具判定、record/state 检查、对象解析、身份落标签、plumbing 应用、ledger 写入与 `Store.commit` |
| [RV_UtilityWater_Ledger.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Ledger.lua) | 3 | ledger 条目寻址键、条目读取与条目构造（不做内容校验、不做状态迁移、不提交） |
| [RV_UtilityWater_Objects.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua) | 7 | 不可信 hint 的严格校验、context/mapping 校验、服务端距离与区域判定、唯一对象重查、身份标签写入与后置校验 |
| [RV_UtilityWater_Plumbing.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Plumbing.lua) | 3 | 原生 `usesExternalWaterSource` 与 ModData `canBeWaterPiped` 的读取、写入、同步与读回核验（无回滚） |
| **总计** | **16** | 8 个 `local function` + 8 个 `function M.x` 表方法；匿名函数表达式 0 个 |

函数数包括 `local function` 与 `function M.x` 表方法；`local integer = StrictSchema.integer`（Objects L25）这类导出别名赋值不计数。本目录没有作为参数或回调传入的匿名函数表达式，因此匿名函数计数为 0。

## 逐文件、逐函数分析

### RV_UtilityWater.lua

模块在 [RV_UtilityWater.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater.lua)。它只做一件事：`require` 本目录 Commands（L3），并把 `setConnection` 暴露为 `Water.setConnection`（L7-L9）。文件不注册事件、不持状态、不做校验；唯一调用者是 [RV_UtilityServer.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:13)（L13 require、L209 调用）。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| M.setConnection（L7） | identity 当前 RV 身份、context 服务端上下文、targetHint 客户端目标提示、record Store 工作副本；原样 `return Commands.setConnection(...)`，无额外校验与副作用。本模块语义：Water 子系统的唯一公开入口。 | **保留理由（当前不是功能必需）**：Core 当前 require 的正是本文件并调用此名（`Core/RV_UtilityServer.lua:13,209`），删除它必须让 Core 直接依赖 Water 内部实现文件；但文件本身零语义、零状态，去掉也不会改变行为。保留成本是一行转发，收益是模块边界与命名一致，因此保留，且必须禁止它继续累积逻辑。 |

### RV_UtilityWater_Commands.lua

模块在 [RV_UtilityWater_Commands.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Commands.lua)。它是连接事务的唯一编排点，顺序固定：record 形状与 `water.state` 检查（L25-L30）→ 工具检查（L31-L33）→ 对象解析（L34-L36）→ ledger 命中（L37-L38）→ 对象身份落标签（L40-L42）→ plumbing 应用（L44-L46）→ ledger 条目写入（L48-L49）→ `Store.commit`（L50-L51）→ 成功返回 `true,{record,connected}`（L52）。文件私有函数只有工具判定一个，没有模块级可变状态。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| hasPipeWrench（L17，私有） | player 玩家对象；`Util.invoke(player,"getInventory")` 后 `Util.invoke(inventory,"contains","Base.PipeWrench")`；返回 boolean。无副作用。本模块语义：服务端工具权限判定。 | **必须**：连接事务的权限合同来自服务端背包，不读客户端字段；客户端同名检查（[RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:53)）只用于菜单显示。 |
| M.setConnection（L24） | identity 当前 RV 身份、context 服务端上下文（内部使用 `context.player`）、hint 客户端目标提示、record 本次工作副本；返回 `true,{record,connected}` 或 `false,reason`。副作用：写对象 ModData 身份标签并 `transmitModData`；改原生 `usesExternalWaterSource` 并同步；写 `record.water.sinks[key]`；`Store.commit` 持久化。 | **必须**：当前唯一的连接入口，把“校验 → 世界对象变更 → canonical 提交”串成一个线性事务；删除它就没有任何写入路径。`desired` 直接取 `sink.connected`（L44），即 hint 的布尔值被当作目标状态而非开关。 |

### RV_UtilityWater_Ledger.lua

模块在 [RV_UtilityWater_Ledger.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Ledger.lua)。当前职责收缩为三点：用坐标求 ledger 键（委托 Store）、按地址读条目、构造条目（L8-L10 注释说明：RV 身份与 slot 已由调用方 mapping record 证明，条目只存连接事实）。**它不提供任何 set/remove/state transition 接口，也不校验已有条目内容**，写入由 Commands 直接完成（Commands L49）。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| M.sinkKey（L11） | sink 表（需含 x/y/z）；类型非 table 返回 nil，否则 `Store.waterSinkKey(sink.x,sink.y,sink.z)`（[RV_UtilityStore.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:163) 的 L163-L165 → L42-L46，格式 `"%d:%d:%d"`）。无副作用。本模块语义：water ledger 条目寻址规则的唯一出口。 | **必须**：条目键必须与持久层键算法完全一致；本模块不自造键格式，避免读写两侧漂移。 |
| M.getEntry（L16） | water 为 `record.water`，sink 为已解析对象；返回 `true, water.sinks[key], key`（entry 可能为 nil 表示首次登记），键非法返回 `false, C.INVALID_RV_DATA`。只读。 | **必须**：Commands 需要旧条目来决定 `sequence`（L48）与判断是否首次登记；这是 ledger 唯一的读接口。 |
| M.newEntry（L22） | sink、connected（归一化为 `connected == true`）、sequence（缺省 0）；返回新表 `{x,y,z,connected,sequence}`，不写容器。 | **必须**：条目形状的唯一构造点；坐标取自服务端已确认的 sink（非客户端原始值），使 Commands 不必自己拼表。 |

### RV_UtilityWater_Objects.lua

模块在 [RV_UtilityWater_Objects.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua)。职责是把不可信 hint 变成“服务端确认的唯一世界对象”，并在需要时补写当前身份标签。它只读世界（`World.getCellForPlayer`/`World.getSquare`/`World.squareSnapshot`），唯一的写操作是 `ensureSinkIdentity` 写对象 ModData。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| exactKeys（L13，私有） | value 待验表、expected 键名数组；先由 expected 构造允许键集合，再遍历 `pairs(value)` 拒绝未知键并要求计数等于 `#expected`；返回 boolean。不做 metatable 检查。 | **必须**：hint 直接来自网络，必须拒绝多余与缺失字段；这是全树**唯一**的 exactKeys 实现（见复用一节）。 |
| validContext（L27，私有） | context（`authorized/phase/record/player`）、identity；要求 `authorized == true`、`phase == "READY"`、`record.locoId == identity.rvId`、generation 整数相等（L29-L34），再由 `record.slotIndex` 经 `RegionSlots.indexToAnchor/indexToRegion` 得到 anchor 与 region（L37-L39）；成功返回 `true,record,anchor,region`，否则 `false`。无副作用。 | **必须**：把请求绑定到服务端当前 mapping，slot 是唯一持久坐标事实，anchor/region 都是派生值。 |
| withinReach（L46，私有） | player、x/y/z；`Util.invoke` 读玩家三轴并用 `Util.isFiniteNumber` 校验，再按 3D 平方距离与 `U.DEVICE_REACH`（[RV_UtilityConstants.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/Common/RV_UtilityConstants.lua:16)，值 3.0）比较；返回 boolean。无副作用。 | **必须**：服务端距离权限判定，不信任客户端坐标。 |
| hintValues（L59，私有） | hint 表；`exactKeys` 要求键恰为 `{x,y,z,objectIndex,connected}` 且 `connected` 是 boolean（L60-L62），坐标与 objectIndex 用 `StrictSchema.integer` 严格整数化（拒绝字符串数字与小数），`index < 0` 拒绝（L64-L66）；成功返回 `x,y,z,index,connected`，否则 nil。 | **必须**：网络边界的第一道校验；用 shared `StrictSchema.integer`（[RV_StrictSchema.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/Common/RV_StrictSchema.lua:4)，只接受有限 Lua number）而不是会接受可转换字符串的 `Util.integer`。 |
| findHintedObject（L70，私有） | square、index；遍历 `World.squareSnapshot(square)`（L71），用 `Util.invoke(object,"getObjectIndex")` 严格整数比较；只有恰好 1 个匹配才返回该对象，0 或 >1 返回 nil。 | **必须**：objectIndex 只是客户端提示，必须回到服务端方格重查；拒绝歧义可避免连错对象。 |
| M.resolveSink（L84） | identity、context、hint；依次校验 hint（L85）→ context/mapping（L87）→ 坐标落在 region 与 `anchor.z + C.RV_MANAGED_MIN_Z_OFFSET/MAX_Z_OFFSET` 带内（L90-L95）→ 距离（L96-L98）→ cell 与 square 可加载（L100-L103）→ 唯一对象（L104-L105）→ 对象仍在同一 square 且有 FluidContainer（L106-L110）→ 外接水状态可读（L111-L114）→ 已有标签必须是当前身份（L115-L118），无标签设备必须有 waterPiped/canBeWaterPiped 能力或已外接水（L119-L121）。成功返回 `true,{object,x,y,z,connected}`，失败返回 `false,reason`（INVALID_REQUEST / INVALID_RV_DATA / DEVICE_NOT_CURRENT / PERMISSION / TARGET_NOT_LOADED / DEVICE_INVALID / API_ERROR / DEVICE_NOT_SUPPORTED）。 | **必须**：命令的安全边界与错误码来源；所有 reason 都是 shared `U.REASONS`（[RV_UtilityConstants.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/Common/RV_UtilityConstants.lua:38) 的 L38-L57）里的稳定码。返回的 `connected` 是 hint 值（L125），作为目标状态使用。 |
| M.ensureSinkIdentity（L129） | object、identity、mappingRecord；已有标签时：当前身份 → `true`（无第二返回值），否则 `false,DEVICE_NOT_CURRENT`（L130-L135）；无标签时取 ModData（L136-L139），写入 `data[Catalog.WATER_TAG_KEY] = {owner,role="sink",rvId,generation,slotIndex=mappingRecord.slotIndex}`（L142-L149），随后要求 `transmitModData` 成功且 `Catalog.isCurrentWaterSink` 后置校验通过（L150-L153），否则 `false,POSTCONDITION_FAILED`。副作用：对象 ModData 写入与网络同步。 | **必须**：水槽身份必须由服务端在首次连接时补写，客户端菜单与后续解都依赖该标签；写后立即用共享规则复验，避免半成功。注意它不返回回滚令牌（见 S2）。 |

### RV_UtilityWater_Plumbing.lua

模块在 [RV_UtilityWater_Plumbing.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Plumbing.lua)。它是原生 B42 外接水状态的唯一适配层：读态、写态并同步、读回核验。当前**没有**任何恢复旧状态的分支（旧报告的 `previousFlag`/`M.readState`/`M.rollback` 均已不存在）。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| readState（L8，私有） | object；读 `getUsesExternalWaterSource`（必须成功后类型为 boolean）与 `getModData().canBeWaterPiped`（必须是 nil 或 boolean）；返回 `true,{connected,pipableFlag}` 或 `false,API_ERROR/DEVICE_INVALID`。只读（`getModData` 返回原表引用但不写入）。 | **实现必需**：写入侧必须区分“字段缺失（nil）”与“字段为 false”，并在写后以同一读取路径做后置比较；这是 adapter 的读半边。 |
| applyState（L24，私有） | object、connected、pipableFlag；依次 `setUsesExternalWaterSource(connected)`（`Util.callSucceeded`，L25）、写 `data.canBeWaterPiped = pipableFlag`（L26-L31）、`transmitModData`（L32）、`sendObjectChange("usesExternalWaterSource",{value=connected})`（L33-L36），任一步失败置 `accepted=false`；最后 `readState` 读回，若 connected 或 pipableFlag 与期望不符也置 false（L37-L41）；返回 boolean。副作用：世界对象属性与 ModData 变更 + 网络同步。 | **实现必需**：以“写入 + 同步 + 读回”代替信任返回值，是当前唯一的原生状态变更路径；字符串形式的事件名与官方 [ClientCommands.lua](<../../../official lua scripts/server/ClientCommands.lua:74>) 一致（Java 侧只声明 `IsoObjectChange` 重载：[IsoObject.java](<../../../game-decompiled/42.21.0/zombie/iso/IsoObject.java:4668>) 的 L4668、L4678、L4688），桥接细节属条件性推断。 |
| M.apply（L45） | object、desiredConnected；非 boolean 返回 `false,INVALID_REQUEST`；计算 `desiredPipable`（L51）后调用 `applyState`，失败返回 `false,POSTCONDITION_FAILED`，成功仅返回 `true`（无第二返回值）。副作用同 applyState。 | **必须**：Commands 的 plumbing 步骤入口，负责参数门与失败码；但失败时**不恢复**原状态（S1/S2）。 |

### 连接事务中的布尔表达式静态发现

【源码事实】[RV_UtilityWater_Plumbing.lua:51](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Plumbing.lua:51) 仍然是 `local desiredPipable = desiredConnected and false or true`。`desiredConnected` 已在 L46 被要求为 boolean，故：true 时 `true and false` 得 `false`，再 `false or true` 得 `true`；false 时直接落到 `or true` 仍得 `true`。**该表达式恒为 true**，等价于 `local desiredPipable = true`。因此 `applyState` 每次都以 `canBeWaterPiped = true` 写入并核验（核验用同一期望值，所以不会失败）。

【源码事实】L49-L50 注释的意图与官方一致：[ISPlumbItem.lua](<../../../official lua scripts/shared/TimedActions/ISPlumbItem.lua:33>) 的 L33-L36 在连接时写 `canBeWaterPiped = false` + `setUsesExternalWaterSource(true)` + `transmitModData` + `sendObjectChange(IsoObjectChange.USES_EXTERNAL_WATER_SOURCE,{value=true})`。即连接后应把“可接水管”标记清掉，断开后应恢复。

【条件性推断】运行时后果需要分消费者判断，且本次未运行游戏：

- 服务端连接流程不受影响：对已带标签的对象，`resolveSink` 走身份分支（L115-L118），不使用 `isWaterPipedDevice`；断开请求传 `desiredConnected=false`，得到的仍是 `canBeWaterPiped=true`，与官方意图一致。
- 模组内读取方（shared `Catalog.isWaterPipedDevice`，[RV_UtilityCatalog.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/Water/RV_UtilityCatalog.lua:83) 的 L83-L88）与客户端菜单（[RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:115) 的 L115 `connected or isWaterPipedDevice(object)`）在两种状态下都会给出正确选项文本（已连接→“断开”，未连接→“连接”）。
- Java 侧 `IsoObject.isWaterInfinite()`（[IsoObject.java](<../../../game-decompiled/42.21.0/zombie/iso/IsoObject.java:2617>) 的 L2617-L2643）在 `getUsesExternalWaterSource() == true` 时于 L2630 提前返回 false，因此连接对象的 `getFluidAmount()`/`getPrimaryFluid()` 路径（L2685-L2691、L3021-L3025）不被该标记影响；但 `getInfiniteWaterType()`/`isUnmovedPipedWaterSource()`（L2646-L2666）与原生菜单条件 [ISWorldObjectContextMenuLogic.java](<../../../game-decompiled/42.21.0/zombie/iso/ISWorldObjectContextMenuLogic.java:554>) 的 L554-L565 会读 `canBeWaterPiped`：其中 L555 在 `canBeWaterPiped == true`、方格在房间内且 `FindExternalWaterSource() ~= null` 时仍会给出原生“接水管”选项。也就是说，在满足这些前提的方格上，**已连接**的 RV 水槽可能仍出现原生 plumb 菜单项，而官方写 `false` 正是为了消除它。是否实际出现取决于运行时房间判定与外部水源发现结果，属未验证的条件性推断。
- 最小修复方向（仅建议，本报告不改源码）：`local desiredPipable = not desiredConnected`。

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **通用 Java/Lua 调用已有单一实现，且本目录已全部复用（源码事实）**：`Util.invoke` / `Util.callSucceeded` / `Util.isFiniteNumber` 由 [RV_Common.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_Common.lua:7) 实现、经 [RV_ServerUtil.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerUtil.lua:37) 的 L37-L48 转出。本目录没有任何 `local function invoke` 之类的薄封装，调用点全部是 `Util.invoke`（Commands L18、L20；Objects L47-L49、L75、L106、L111、L136；Plumbing L9、L13、L26）与 `Util.callSucceeded`（Objects L150；Plumbing L25、L32、L33）。旧报告的“本地 invoke wrapper 待统一”在当前源码中已不存在。
- **`identityKey` 在本目录已成空集（源码事实）**：全树检索 `identityKey` 在 `server/RailroaderRV/Water/` 下 0 命中；`Util.identityKey`（[RV_ServerUtil.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerUtil.lua:46) 的 L46，实现 `Common.identityKey`）当前由 Power 使用（[RV_UtilityPowerDevices.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Power/RV_UtilityPowerDevices.lua:191) 的 L191 等）。即“统一到 ServerUtil.identityKey”这一结论现在无需执行任何迁移，只需保持不在 Water 里新造键格式。
- **`exactKeys` 只剩一处实现（源码事实）**：全树 `exactKeys|hasExactKeys` 仅命中 Objects L13（定义）与 L60（唯一调用）；[RV_StrictSchema.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/Common/RV_StrictSchema.lua:4) 现在只有 `M.integer`（L4-L11），已无 exactKeys。旧报告“server Water 的 exactKeys 可接受 metatable、StrictSchema 的 exactKeys 拒绝 metatable，故未统一”的对比对象**已不存在**。可提取机会仍在：[RV_UtilityServer.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:95) 的 L95-L105 用 allowed-set 加 `pairs` 做同类“顶层字段精确校验”。若要把规则收成一处，可在 shared `RV_StrictSchema` 增加 `M.exactKeys(value, allowedSet)`（对象键集合），供 UtilityServer 命令信封与 Water hint 共用；净收益是“精确字段”语义只有一个定义，成本是两种现有写法（数组 + 计数相等 vs 集合成员）需要统一并把 hint 错误仍归到 `U.REASONS.INVALID_REQUEST`。判：收益中等偏小，不是当前缺陷。
- **严格整数与宽松整数应保持分层（源码事实 + 语义差异）**：hint 用 `StrictSchema.integer`（Objects L25、L64-L65）拒绝可转换字符串；`Util.integer`/`Common.integer` 先 `toNumber`，接受字符串与 Java 数值包装。两者服务不同边界（网络输入 vs 内部数值），不建议合并；若要统一，应先明确“是否接受字符串数字”的合同。
- **标签形状存在两处描述，可加一个共享纯构造函数**：校验在 shared `Catalog.tagForObject`（[RV_UtilityCatalog.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/Water/RV_UtilityCatalog.lua:20) 的 L20-L33：owner/role/rvId/generation/slotIndex），构造在 `Objects.ensureSinkIdentity` 内联（L142-L149，硬编码字段名与 `"sink"` 字面量）。可在 shared Catalog 增加纯函数 `buildSinkTag(identity, mappingRecord)` 返回新表，服务端继续负责写 ModData、`transmitModData` 与后置校验。净收益：字段列表只留一处，避免改字段时两侧漂移；成本：共享层新增一个纯函数、调用点仍需服务端写世界。判：收益中等，可在下次改动 tag 字段时一并做，不是当前必需。
- **不建议提取**：`resolveSink`/`ensureSinkIdentity` 强绑定服务端 World、RegionSlots 与权限语义；`Plumbing.applyState` 是原生对象适配且必须 server-only；`Ledger.sinkKey` 已通过 `Store.waterSinkKey` 复用，不应复制键算法。

### 是否进一步拆分

- **RV_UtilityWater.lua（11 行 / 1 函数）：保留门面，但不承认为“功能必需”**。它当前唯一作用是让 Core 通过 `RailroaderRV/Water/RV_UtilityWater` 访问 Water（[RV_UtilityServer.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:209) 的 L13 require、L209 调用），删除可省一个文件，但会让 Core 直接 require Water 内部实现文件；保留成本是一行转发。判断：**保留**，条件是门面保持零逻辑；若 Water 将来新增第二个公开操作（例如对象移除后的 ledger 清理、诊断读取），门面才会真正起到聚合作用。作为“必须存在的门面”证据不足。
- **RV_UtilityWater_Objects.lua（157 行 / 7 函数）：暂不拆**。内部可分成 hint 校验（L13-L82，含 integer 别名）与对象/身份解析（L84-L155）两段，但同属一个线性事务、共用 `validContext` 结果与 `Catalog` 校验，拆文件会引入 require 与参数转手，收益低于新增复杂度。若未来出现第二个 hint 类型（例如批量目标或多设备操作），再按“Hint 校验”与“对象身份”拆分。
- **RV_UtilityWater_Commands.lua（55 行 / 2 函数）：不需要拆**。当前无状态机、无队列、无私有运行时表，只是线性编排 + 一个工具判定；远低于拆分阈值。
- **RV_UtilityWater_Ledger.lua（30 行 / 3 函数）：先补接口，再谈拆分**。若按接口边界问题第 1 条给 Ledger 增加写入/状态前置接口，它会有 4–5 个函数，仍是单职责小文件，不需要拆。
- **不要按行数硬拆**：本目录总量 310 行，当前最大文件 157 行；拆分只会增加跨文件参数传递，而事务的正确性依赖“解析 → 标签 → 原生状态 → ledger → commit”的顺序，文件边界应按职责保持现状。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **`Water.setConnection(identity, context, targetHint, record)`**（[RV_UtilityWater.lua:7](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater.lua:7)）：返回 `true,{record,connected}` 或 `false,reason`。**唯一调用者**是 [RV_UtilityServer.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:209) 的 L209（全树 `Water.<api>` 检索只有这一处）。返回值形状被上游消费：`detail.record` 用于广播（L264-L265），`detail.connected` 写入 ack 的 `payload.connected`（L118-L128），客户端据此显示连接/断开（[RV_UtilityDashboard.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:563) 的 L563-L569、[RV_UtilityClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityClient.lua:239) 的 L239-L244）。因此 `connected` 是**跨端可见的合同字段**，不能随意改名。
- **失败 reason 合同**：Objects 返回 `U.REASONS.*`；`C.INVALID_RV_DATA`（[RV_Constants.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/Common/RV_Constants.lua:55) 的 L55）会被 `RV_UtilityServer.stableReason`（L32-L40）折叠为 `U.REASON_INVALID_RV_DATA`，客户端收到后提示“删除测试存档重建”（[RV_UtilityClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityClient.lua:253) 的 L253-L255）。
- **Ledger 公开合同**（`RV_UtilityWater_Ledger.lua:11,16,22`）：`sinkKey` / `getEntry` / `newEntry`。没有 `setEntry`/`removeEntry`/`setState`/`validate`；条目形状由 `newEntry` 单点定义。目录外无调用者（全树检索仅 Commands 使用）。
- **Objects 公开合同**（`RV_UtilityWater_Objects.lua:84,129`）：`resolveSink` / `ensureSinkIdentity`；目录外无调用者，属 Water 内部 API。
- **未接线/未导出**：本目录不注册任何事件；`RV_UtilityWater` 只导出 `setConnection`。旧报告的 `M.onObjectRemoved`、`M.onTick`、`Commands.onObjectRemoved/onTick` 在当前 5 个文件中都不存在。

### 直接读写其他模块的数据

1. **Commands → Store 工作副本的 water 子表（本模块内最明显的跨界数据结构访问）**：[RV_UtilityWater_Commands.lua:28](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Commands.lua:28) 读 `record.water.state` 并要求等于 `U.WATER_STATE_ACTIVE`；[RV_UtilityWater_Commands.lua:49](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Commands.lua:49) 写 `record.water.sinks[deviceKey] = Ledger.newEntry(...)`。record 由 `Store.getRecord` 返回（[RV_UtilityStore.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:94) 的 L94-L117），提交由 `Store.commit`（L119-L145）完成。是否应改为接口：**收益有限，但可小幅收口**。全树 `sinks[...] =` 只有这一处写入（读只有 Ledger L19 与客户端 Dashboard L420-L427），Ledger 已经提供构造与读取；“给 Ledger 增加 setEntry/requireActive”能把“state 前置 + 条目形状”收在一处，但只服务一个写入点，且 Store.commit 仍必须由 Commands 负责（[RV_UtilityStore.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:119) 的 L119 只校验 identity/rvId/generation，**不校验 water 结构**，所以条目形状完全依赖 Ledger.newEntry）。结论：不是缺陷，属可选规范化；若做，优先加 `Ledger.setEntry(water, sink, entry)` 与 `Ledger.isActive(water)` 两个窄接口，不要引入完整状态机。
2. **Ledger → Store 的键函数**：[RV_UtilityWater_Ledger.lua:13](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Ledger.lua:13) 调用 `Store.waterSinkKey`（[RV_UtilityStore.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:163) 的 L163-L165）。这是公开 API 调用（Store L163 显式导出），不是内部字段访问，**保持现状**。
3. **Objects → ServerWorld 的三个公开入口（源码事实）**：`World.squareSnapshot(square)`（[RV_UtilityWater_Objects.lua:71](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:71) → [RV_ServerWorld.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua:159) 的 L159、L467）、`pcall(World.getCellForPlayer, context.player)`（L100 → 同文件 L12）、`World.getSquare(cell,x,y,z)`（L102 → 同文件 L24）。**本目录没有使用 `ServerWorld.objectModData`，也没有使用 `strictSquareSnapshot`**：全树 `strictSquareSnapshot` 的消费方是 [RV_Server_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:501) 的 L501 与 [RV_Construction.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Construction.lua:24) 的 L24，与 Water 无关。
4. **Objects → 游戏对象 ModData 的身份标签**：[RV_UtilityWater_Objects.lua:136-149](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:136) 直接经 `Util.invoke(object,"getModData")` 取表并写 `data[Catalog.WATER_TAG_KEY]`（键由 shared `RV_UtilityCatalog.lua:18` 公布），随后 L150 `transmitModData`、L151 用 shared 规则复验。是否改为接口：**不应改**。写世界对象与网络同步必须留在 server；shared Catalog 保持只读校验，正好构成“共享规则 / 服务端副作用”的分工。若要让 shared 参与，只能加纯构造函数（见复用一节），不能把写入搬进共享层。
5. **Plumbing → 原生对象属性**：[RV_UtilityWater_Plumbing.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Plumbing.lua:9) 的 L9、L13、L25-L26、L32-L33 直接读写 `usesExternalWaterSource` 与 ModData `canBeWaterPiped`。这些是游戏原生属性（官方脚本同样读写：[ISPlumbItem.lua](<../../../official lua scripts/shared/TimedActions/ISPlumbItem.lua:33>)、[ISMoveableSpriteProps.lua](<../../../official lua scripts/shared/Moveables/ISMoveableSpriteProps.lua:2493>)、[ClientCommands.lua](<../../../official lua scripts/server/ClientCommands.lua:71>)），不是 RV 内部 Lua 状态，**不应为形式封装再加一层接口**。
6. **隐藏状态（源码事实）**：本目录没有任何模块级可变表——Commands 只有 `M`（L15），Ledger/Objects/Plumbing 只有 `M`，`RV_UtilityWater` 只有 `M`（L5）与一个 require（L3）。旧报告的 `runtimeFaults`、`pendingRemovals` 等进程内隐藏状态在本目录 0 命中。Store 侧状态通过工作副本 + 显式 commit 隔离（`RV_UtilityStore.lua:128-132` 提交后仍保持调用方副本独立）。

### 接口边界问题

1. **`Catalog.isCurrentWaterSink` 忽略 mappingRecord.slotIndex（源码事实 + 条件性影响）**：shared 实现（`shared/RailroaderRV/Water/RV_UtilityCatalog.lua:53`)只比较 `rvId`/`generation`（L62-L63），形参 `mappingRecord` 仅参与 L57 的类型检查。服务端因此在三处传入 record 却未做 slot 比对：[RV_UtilityWater_Objects.lua:116](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:116)、[:131](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:131)、[:151](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:151)。条件性影响：若某对象的标签 slotIndex 与当前 mapping record 的 slotIndex 不同（本报告推断的唯一现实来源是同 rvId/generation 下 slot 被重新分配），`resolveSink` 仍接受该对象、`ensureSinkIdentity` 仍认为“已是当前身份”而不刷新标签（L130-L135），而客户端菜单要求 `identity.slotIndex == 本地 slot`（`client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:110-112`），于是该水槽在客户端菜单中不可见。坐标区域检查（Objects L90-L95 + `RV_RegionSlots.lua:47-56` 的 1:1 slot/区域网格）覆盖了大部分错配，但覆盖不了“同区域、不同 slot 的陈旧标签”。建议：把 slotIndex 纳入共享比较，或在共享注释中明确“slot 一致性由服务端坐标区域检查代替”。本次未运行游戏，未构造该状态验证。
2. **`ensureSinkIdentity` 与 `resolveSink` 的标签合同不对称（源码事实）**：`resolveSink` 对“有标签但非当前”返回 `DEVICE_NOT_CURRENT`（L115-L118），而 `ensureSinkIdentity` 对同一条件返回同一原因码（L134），两者不冲突；但 `ensureSinkIdentity` 成功时返回 `true`（无第二返回值），Commands 也不保留任何“本次是否新建标签”的信息（L40-L42），因此后续步骤失败时无法只撤销新建的标签。这是 S2 的一部分。
3. **S1 恒真表达式（已在上一节列出）**：[RV_UtilityWater_Plumbing.lua:51](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Plumbing.lua:51)。
4. **S2 移除见证与补偿已整体移除（源码事实 + 条件性影响）**：
   - 事实：`Plumbing.apply` 失败不恢复原状态（L52-L53）；`applyState` 只在内存中累加 `accepted=false`（L25-L41）；`ensureSinkIdentity` 不回滚已写标签；Commands 在 plumbing 失败（L45-L46）或 commit 失败（L50-L51）时直接返回失败，不改 `record.water.state`（全树对 water state 的写入只有 `Core/RV_UtilityStore` 新建时的 `ACTIVE`，`NEEDS_RECONCILE` 已从代码中消失）。全树大小写不敏感检索 `onobjectremoved`、`pendingRemoval`、`runtimeFaults`、`REMOVAL_CONFIRM` **均为 0 命中**；`OnObjectAboutToBeRemoved` 的服务端注册点只有 [RV_RailroaderServer_Tick.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_RailroaderServer_Tick.lua:101) 的 L101-L102（接到 WallReloadProtection 的 `Adapter.onObjectAboutToBeRemoved`，[RV_RailroaderServer_WallReload.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua:231) 的 L231-L233）以及客户端房间扫描（[RV_ContextMenu_Relocation.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua:429) 的 L429-L431），**没有任何注册点指向 Water**。旧报告记录的 `RV_UtilityServer.onObjectRemoved` 未接线问题在当前源码中的结论是：该函数与整条移除见证链都不存在（`RV_UtilityServer.lua` 现为 366 行，也没有旧的 L411 注释），因此不是“未接线”，而是**已被删除**。
   - 条件性影响：失败可能留下“对象已带当前标签 + 原生态不确定 + ledger 未更新”的组合。因为下一次请求会重新执行 `resolveSink` → `getEntry`（条目缺失 → `sequence = 1`）→ `apply` → commit，失败后重试可以自愈；但没有任何自动 reconcile，被玩家拆掉/移动的水槽在其条目上也没有清理路径（全树无 `sinks[key] = nil`），这些条目会持续留在存档中，并计入客户端面板的统计（[RV_UtilityDashboard.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:419) 的 L419-L426 遍历全部 sinks 计数）。是否构成实际问题取决于水槽对象被移除的频率，属未验证的条件性推断。
5. **请求语义是“设置”而非“切换”，且不短路（源码事实 + 影响）**：`resolveSink` 把 hint 的 `connected` 原样放入结果（L125），Commands 直接以它为目标状态（L44），既不与原生当前值比较，也不与旧条目比较。影响：重复或过期的 hint 不会反转状态（幂等，安全），但每次都会写对象、写 ledger 并 `Store.commit`（写放大）；`sequence` 会随每次请求递增（L48）。若要优化，可在 `apply` 前比较原生态并短路返回成功，收益是减少无意义的世界/存档写入，属可选优化。
6. **宽松快照在解析路径上是 fail-closed（条件性推断）**：`findHintedObject` 用 `World.squareSnapshot`（宽松，失败返回空数组，[RV_ServerWorld.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua:159) 的 L159），空列表会导致“找不到唯一对象” → `DEVICE_INVALID` 拒绝请求（Objects L104-L105）。因此 Water 不需要 `strictSquareSnapshot` 的 fail-closed 语义——它不会因为枚举不完整而误删或误改对象，只会拒绝操作。这一点与清理类流程（[RV_Server_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:501) 的 L501）不同。

## 函数清单、覆盖和验证记录

**逐文件函数清单（起始行，本次实际读取）**

| 文件 | 函数（起始行） | 小计 |
|---|---|---:|
| RV_UtilityWater.lua | `M.setConnection`（L7） | 1 |
| RV_UtilityWater_Commands.lua | `hasPipeWrench`（L17，local）、`M.setConnection`（L24） | 2 |
| RV_UtilityWater_Ledger.lua | `M.sinkKey`（L11）、`M.getEntry`（L16）、`M.newEntry`（L22） | 3 |
| RV_UtilityWater_Objects.lua | `exactKeys`（L13，local）、`validContext`（L27，local）、`withinReach`（L46，local）、`hintValues`（L59，local）、`findHintedObject`（L70，local）、`M.resolveSink`（L84）、`M.ensureSinkIdentity`（L129） | 7 |
| RV_UtilityWater_Plumbing.lua | `readState`（L8，local）、`applyState`（L24，local）、`M.apply`（L45） | 3 |
| **合计** | 16 个函数定义；匿名函数表达式 0 个 | **16** |

**覆盖**：上表 16 个函数全部在上文逐函数表中给出参数、返回/副作用、模块语义与必要性判断；`local integer = StrictSchema.integer`（Objects L25）是别名赋值，按要求不计数，也不单独成行。目录内没有未分析的函数或回调。

**验证记录（本次实际执行的静态检索）**

- 行数：`RV_UtilityWater.lua` 11 行、`RV_UtilityWater_Commands.lua` 55 行、`RV_UtilityWater_Ledger.lua` 30 行、`RV_UtilityWater_Objects.lua` 157 行、`RV_UtilityWater_Plumbing.lua` 57 行（shell `Get-Content` 计数，与 read 工具报告的总行数一致）。
- 函数定义数：两条独立扫描一致——`local function` / `function Name` / `function M:name` / `= function(` 分类扫描得 1/2/3/7/3；只用“定义行正则”的计数扫描同样得 1/2/3/7/3。扫描同时列出所有含 `function` 字样的行，其余命中都是注释或 `type(x) ~= "function"` 判断，不是定义。具体到本目录的 17 处关键字命中：`RV_UtilityWater_Ledger.lua` 4 处中有 1 处是 L10 的注释（`-- pure function of the slot, ...`），不是定义，该文件定义数为 3；其余 4 个文件没有注释或类型判断命中（1 + 2 + 7 + 3 = 13），因此目录合计 **16**，与上表逐文件小计一致。
- 调用点检索：`Water.<api>` 全树只有 [RV_UtilityServer.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:209) 的 L209；`RV_UtilityWater` 的 require 只有同文件 L13；`resolveSink`/`ensureSinkIdentity`/`Ledger.*` 的调用全部落在本目录内。
- 事件与移除链检索：`onObjectRemoved`（大小写不敏感）、`pendingRemoval`、`runtimeFaults`、`REMOVAL_CONFIRM` 全树 0 命中；`OnObjectAboutToBeRemoved` 的注册点为 [RV_RailroaderServer_Tick.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_RailroaderServer_Tick.lua:101) 的 L101-L102、[RV_Server_Core.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Core.lua:121) 的 L121-L122（本地事件表）、[RV_ContextMenu_Relocation.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua:429) 的 L429-L431，均与 Water 无关。
- 共享/底层交叉核对：[RV_UtilityCatalog.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/Water/RV_UtilityCatalog.lua:18)（L18 键、L20-L33 tag 校验、L53-L64 身份比较、L83-L93 能力判定）；[RV_UtilityStore.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:42)（L42-L46 键、L94-L117 读取、L119-L145 提交、L163-L165 键导出）；[RV_UtilityServer.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:13)（L13、L118-L128 ack、L195-L210 命令分派、L264-L267 广播/ack）；[RV_Server_Commands.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:285)（L285-L290 tick、L306-L307 命令 pcall 边界）；客户端 [RV_UtilityClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityClient.lua:103)（L103、L181 hint 生产者）与 [RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:96)（L96-L115）、[RV_UtilityDashboard.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:419)（L419-L434、L563-L569）消费者。
- 官方/反编译交叉核对（用于判定 S1 与 API 用法）：[ISPlumbItem.lua](<../../../official lua scripts/shared/TimedActions/ISPlumbItem.lua:33>)、[ClientCommands.lua](<../../../official lua scripts/server/ClientCommands.lua:71>)、[ISMoveableSpriteProps.lua](<../../../official lua scripts/shared/Moveables/ISMoveableSpriteProps.lua:2493>)；[IsoObject.java](<../../../game-decompiled/42.21.0/zombie/iso/IsoObject.java:2412>)（L2412、L2416、L2617-L2666、L2685-L2691、L3021-L3025、L4668-L4694）、[ISWorldObjectContextMenuLogic.java](<../../../game-decompiled/42.21.0/zombie/iso/ISWorldObjectContextMenuLogic.java:552>)（L552-L565）。
- **未覆盖项**：未运行游戏、服务器或任何测试脚本；未验证 Java 桥对字符串形式 `sendObjectChange` 的处理、未验证原生 plumb 菜单在 RV 方格上的实际表现（S1 条件性影响）、未验证“同区域陈旧 slot 标签”与“被移除水槽遗留条目”两个条件性推演；未检查客户端 hint 产生的时序与重复点击行为。本报告是静态分析，不替代运行时验证。
