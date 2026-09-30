# server/RailroaderRV/Construction 模块分析

## 假设、范围、成功条件与验证方式

- **假设**：只分析模组当前目录 `media/lua/server/RailroaderRV/Construction/` 的直接子文件；行号以本次读取的文件版本为准，本目录 7 个文件合计 **2068 行**（旧报告描述的是 6 个文件版本、其文件表行数合计 3332；任务书中的"约 1967 行"与本次 shell 统计不符，一律以本次统计为准）。服务端装配根是 [RV_Server.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:51)：它在 L51-L52 创建 generation 事务对象，在 L105-L136 组装同一个 ctx 表，并在 L141-L150 按序调用各模块工厂。ctx 字段不是类型化接口，靠约定名与加载顺序成立。
- **事务状态 owner 的当前事实**：`RV_Server_GenerationTransaction.lua` 的闭包 upvalue `record`（L9）是"当前是否存在活动 generation 事务"的唯一 owner；它同时定义初始阶段与释放点（L21-L23、L43-L44、L48-L50）。**记录表本体不由该文件持有**：它由 [RV_Server_GenerationFlow.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:396) 在一次请求内构造，随后以 `record` / `prepared` 形参被本模块其它文件与 Core 逐字段读写。旧报告中的 `pendingGeneration`、`roofRefreshRelocationGroup`、manifest 持久化字段在当前源码中已全部不存在（全树检索：`pendingGeneration` 仅剩 Core 的 `processPendingGeneration` 函数名，与本模块无关）。
- **范围**：本目录 7 个 Lua 文件及其全部具名函数、`local function`、表字段函数与匿名函数表达式；只读检查调用方（Core、RVMapping、RoomOwnership、TemplateRecovery、WallReloadProtection、BoundaryGuard、Common、RoofRefresh）以判定公开 API 使用面与跨模块数据访问。唯一写入目标是本报告。
- **成功条件**：每个函数都有精确起始行、参数类型/含义、返回值或副作用、模块语义和加粗必要性结论；复用/提取、拆分、接口边界与隐藏状态逐条给出 `文件:行` 证据；机械核对的函数数与行数自洽；源码事实与条件性推断明确区分。
- **验证方式**：列目录并统计行数；逐文件做 `function` 关键字扫描并与定义语义分类交叉核对（本目录共 **80** 个函数定义）；逐文件编号读取全文；在 `media/lua` 全树检索本模块导出符号的消费者、事务记录字段读写点、以及 `createFurniture` / `createWall` / `createLight` / `pendingGeneration` / `roofRefreshRelocationGroup` 等旧符号。**本轮未运行游戏、服务器或任何测试脚本**；静态扫描不替代运行时验证。

## 目录职责与清单

Construction/ 是服务端权威生成事务的实现区：验证 → 计划 → 清理/建造 → ACK → 回滚。本目录不保存持久状态，所有并发、阶段与失败事实都在进程内的事务记录里；世界几何一律来自编译后的模板与 `ServerSchema` 合同。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_Construction.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Construction.lua) | 8 | 构造清场/建造的服务门禁：要求活动事务、要求当前 clear 阶段、要求清场范围完全为空 |
| [RV_Server_GenerationTransaction.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationTransaction.lua) | 7 | 进程内 generation 事务的唯一 owner：单活动记录、初始阶段、所有权查询、取消标记与释放 |
| [RV_Server_GenerationAck.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationAck.lua) | 5 | 两个客户端 ACK（staging / final）的验签与置位，以及唯一的 abort 路径（回滚 + 送回玩家 + 释放记录） |
| [RV_Server_GenerationBuild.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationBuild.lua) | 9 | 装配 Construction 服务；实现清场、按模板建造、结构重算、阶段日志与 `ensureGeneratorForEntry` 服务包装 |
| [RV_Server_GenerationFlow.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua) | 12 | 请求校验、区域分配、事务记录构造、清场/建造编排、最终搬运与提交（mapping commit） |
| [RV_Server_PlayerValidation.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_PlayerValidation.lua) | 14 | 玩家身份/权限/坐标校验、位置证明、两个服务端→客户端 relocation 命令与 boundary 租约续期/重发 |
| [RV_Server_WorldObjects.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_WorldObjects.lua) | 25 | 捕获模板对象的状态校验与逐类构造、roof square 创建、generator 创建与入口修复 |
| **总计** | **80** | 7 个文件、2068 行 |

函数数口径：计入具名函数声明、`local function`、表字段函数（含 `name = function(...)` 赋值形式）与匿名函数表达式（模块工厂 `return function(ctx)`、`pcall(function() ... end)`、`walkBounds` 回调）；`clearGenerationArea = construction.clearCurrentGeneration` 一类的导出别名赋值不计数。

## 逐文件、逐函数分析

### RV_Construction.lua

本文件是唯一非 ctx 工厂的模块：`return Construction`（L79），只导出 `Construction.new`（L7）。它从整个 ctx 中只读取 `GenerationTransaction`（L9）、`ServerWorld`（L19）、`ServerSchema`（L20）三个字段，并从 operations 表接收 `clear` / `build` / `setGenerationPhase`（由 [RV_Server_GenerationBuild.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationBuild.lua:153) 提供）。所有方法都以"活动事务 + 当前阶段"为前置条件，缺一即 `error`，因此它是清场/建造的唯一门禁。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| Construction.new（L7） | `context`：组合根 ctx（仅使用 L9/L19/L20 三个字段）；`operations`：`{clear, build, setGenerationPhase}`（L153-L157 提供）。返回 `service` 表（L76），内含 3 个门禁方法与 3 个嵌套函数；不修改世界，依赖缺失时由内部 `error` 终止。 | **必须**：本目录唯一的服务装配点，GenerationBuild 与 GenerationFlow 的全部清场/建造都经它约束。 |
| requireCurrentBuild（L11） | `player`：服务端玩家；要求非 nil 且 `generationTransaction.owns(player) == true`，否则 `error`。无返回。 | **必须**：把"只有活动事务的 owner 能触发世界变更"变成单点判定，缺它则任何玩家路径都能进入清场/建造。 |
| preflightClearTarget（L17） | `player`、`cell`、`bounds`：托管范围；用 `schema.walkBounds` 逐格 `pcall(world.strictSquareSnapshot)`，快照不可验证、含玩家或含任何对象都 `error`（L23-L38）。无返回。 | **必须**：本代没有完整 undo 快照，所以清场必须 fail-closed 地要求空范围；这是 `clearSquare` 之前的唯一保护。 |
| preflightClearTarget 中匿名函数（L22） | `square`：walkBounds 传入的现存方格（实际签名 `fn(square, x, y, z)`，见 [RV_ServerSchema.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerSchema.lua:43)）；逐格判定占用并 `error`。 | **实现必需**：预检只能通过 walkBounds 的逐格回调表达；注意 L28-L37 的循环体对第一个对象必然 `error`，净语义是"范围内任一对象即拒绝"。 |
| service.preflightCurrentGeneration（L41） | `player`、`cell`、`layout`、`bounds`、`generation`、`identitySource`：Flow 的准备结果；函数体只把 `player/cell/bounds` 转发给 `preflightClearTarget`（L43），**`layout`、`generation`、`identitySource` 未被读取**。返回 `true`。 | **必须**：Flow 在任何世界写入前调用的唯一目标预检入口（[RV_Server_GenerationFlow.lua:188](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:188)）；三个未读形参属接口冗余，删除需同步改 Flow 的调用点。 |
| requireCurrentMutation（L50） | `player`：服务端玩家；先 `requireCurrentBuild`，再要求 `generationTransaction.current().stage == "BUILD"`（L52-L55），否则 `error`（错误文本称 clear phase）。无返回。 | **必须**：清场只允许在记录处于 BUILD 时发生；L47-L49 注释明确"clear pass runs while the record is in BUILD"，两个阶段共用该 stage 值。 |
| service.clearCurrentGeneration（L58） | `cell`、`bounds`、`generation`；从 `current()` 取 `player`（L59-L60），校验阶段，再跑一次 `preflightClearTarget`（L62），写日志阶段 `CLEARING`（L63），返回 `operations.clear(...)` 的结果。副作用：经 Build 的清场实现删除范围内对象。 | **必须**：Flow 通过 `ctx.clearGenerationArea` 使用的门禁化清场入口；直接调 operations.clear 会绕过事务与空范围检查。 |
| service.buildCurrentGeneration（L67） | `player`、`layout`、`bounds`、`generation`；要求 `owns(player)`（L68）且 `tostring(current().generation) == tostring(generation)`（L70），返回 `operations.build(...)`。副作用：创建模板对象与 generator。 | **必须**：防止把一次建造结果写进另一代/另一玩家的记录；`tostring` 比较兼容数字与字符串代号。 |

### RV_Server_GenerationTransaction.lua

本文件是工厂函数 `return function() ... end`（L8），不接收 ctx，返回 `api` 表（L52）。它只有两个 upvalue：`record`（L9，单活动记录指针）与 `api`。文件头注释（L1-L7）明确记录是"由调用者拥有的普通表"，调用者直接写字段，`record.stage` 是唯一阶段权威，且这里没有 snapshot、白名单、语义阶段 API 或回滚账本。也就是说：**指针与生命周期归本文件，字段 schema 与阶段流转归调用者**。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| 模块工厂（L8） | 无参数；返回 `api`（L52）。创建 `record` upvalue 并封装 6 个操作。 | **必须**：装配根的唯一调用点 [RV_Server.lua:51-L52](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:51) 用 `require(...)()` 创建它并放进 `ctx.GenerationTransaction`（L122）。 |
| api.begin（L13） | `player`：请求者；`recordTable`：Flow 构造的记录表。要求当前无活动记录（L14-L16）且 `recordTable.player == player`（L17-L20），写 `recordTable.stage = "WAIT_STAGING"`（L21）并持有引用（L22）。返回 `true`，冲突则 `error`。 | **必须**：唯一建立活动事务并写初始阶段的位置；缺它则并发请求不会被拒绝。 |
| api.current（L26） | 无参数；返回**活动记录本体**（不是快照），无活动记录返回 nil。 | **必须**：tick 状态机、ACK、Construction 门禁、Build 与 RecordValidation 都经它读取当前事务；返回活引用正是当前共享表合同的入口。 |
| api.owns（L30） | `player`：服务端玩家；`token`：可选事务令牌。无记录返回 false；`player` 不匹配返回 false；`token` 不匹配返回 false；否则 true。纯查询，无副作用。 | **必须**：`owns(player)` 是 Construction 与 `generateForPlayer` 的所有权门禁（[RV_Construction.lua:12](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Construction.lua:12)、[RV_Server_GenerationFlow.lua:129](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:129)）；`token` 分支当前无调用者使用（两处都只传 player），属签名预留。 |
| api.isActive（L37） | 无参数；返回是否存在活动记录。 | **必须**：`queueGeneration` 的并发门禁（[RV_Server_GenerationFlow.lua:327](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:327)）；也是对外 mutex 查询的天然实现，但当前未被发布（见接口章节）。 |
| api.cancel（L41） | `reason`：失败说明；无记录返回 false，否则写 `record.cancelled = true`（L43）与 `record.failureReason = reason`（L44），返回 true。不改阶段、不释放。 | **当前不是功能必需**：这两个字段在全树没有任何读取点（唯一读取者不存在），Core 的 abort 序列也直接把同一 `reason` 传给 `abortGeneration`（[RV_Server_Commands.lua:172-L173](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:172)）。保留它就必须补一个观察者，否则删除需同步改 Core 调用点。 |
| api.release（L48） | 无参数；把 `record` 置 nil，无返回。 | **必须**：提交（[RV_Server_Commands.lua:250](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:250)）、入队失败（Flow L434/L440/L453）与 abort（Ack L140）都靠它收尾；缺它活动记录永不释放，后续 generation 永久被 `isActive` 拒绝。 |

### RV_Server_GenerationAck.lua

本文件是 ctx 工厂（L3-L146），在末尾把三个操作写到 ctx（L143-L145）。它只负责两件事：两个客户端 ACK 的验签/置位，以及唯一的 abort 路径。**旧报告中由本文件承担的 RoofRefresh 组 ACK/成员处理已经不存在**（见"接口边界问题"）。ACK 的分派不在本文件：Core 按命令名调用 ctx 上的处理函数（[RV_Server_Commands.lua:333-L365](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:333)）。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| 模块工厂（L3） | `ctx`：需要 `Constants`、`Boundary`、`ServerWorld`、`GenerationTransaction`（L4-L7）、`require` 的 WallReload（L8）、`safeErrorText`、`notifyFailure`、`removeGeneration`、`generationPositionProof`、`playerIdentity`、`resolvePendingPlayer`（L9-L14）。无返回，末尾注册 L143-L145。 | **必须**：ACK 与 abort 是服务端事务的两个关键观测点，装配根在 L149 调用它。 |
| safeErrorText（L9） | 单行 `local function`，可变参数；原样转发 `ctx.safeErrorText`。 | **实现必需**：abort 路径的错误格式化本身不能再抛错；实现已在 Build L16-L32 集中，此转发等价于直接引用 ctx 函数，属可省薄包装。 |
| acknowledgeRelocation（L16） | `player`：ACK 发送者；`args`：客户端负载（只取 `args.token`，L23）。先路由 `WallReload.acknowledge(player, token)`（L19-L28），再由 generation 处理：要求存在记录、`record.stage == "WAIT_STAGING"`（L33）、身份 key 相同（L36-L40）。副作用：写 `record.player`、`record.stagingAcked = true`、`record.deadlineTick = serverTick + RELOCATION_TIMEOUT_TICKS`（L41-L46）。返回 true 或 false+原因。 | **必须**：staging ACK 是 WAIT_STAGING 前进的唯一信号（[RV_Server_Commands.lua:203](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:203)）；身份校验在此取代了 token 比对。 |
| acknowledgeFinalRelocation（L53） | `player`、`args`（**`args` 在函数体未被读取**）。门禁：`record.stage == "WAIT_FINAL"`（L55）、身份 key 相同（L58-L62）、`resolvePendingPlayer(record)` 成功（L63-L64）、`generationPositionProof(livePlayer, record.finalDestination)` 为真（L66-L78）。副作用：写 `record.player`、`record.finalAcked = true`（L85-L86），失败时打印目标/状态诊断（L74-L84）。返回 true 或 false+原因。 | **必须**：final ACK 是 WAIT_FINAL 提交的唯一入口（[RV_Server_Commands.lua:244-L247](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:244)），且必须以服务端权威位置证明为前提。 |
| abortGeneration（L94） | `record`：失败事务记录；`reason`：失败原因。best-effort 序列：日志（L97-L100）→ 重解析在线玩家（L101-L103）→ 阶段为 BUILD/WAIT_FINAL 时 `pcall(removeGeneration, cell, record.bounds, record.generation, record.rvId)` 回滚已建对象（L104-L118）→ 存在 `originalPosition` 时 `ctx.sendStagingRelocation(record, "return")` 送回（L119-L125）→ `pcall(Boundary.completeTransition, player, token)` 结清租约（L126-L129）→ `pcall(ctx.railroaderFailureHook, ...)`（L130-L134）→ 原因含 `INVALID_RV_DATA` 时 `notifyFailure`（L135-L139）→ `GenerationTransaction.release()`（L140）。无返回，任何单步失败只打印。 | **必须**：唯一的 abort 路径；`removeGeneration` 失败仍继续释放是刻意的，因为不释放会让后续生成永久阻塞。 |

### RV_Server_GenerationBuild.lua

本文件是 ctx 工厂（L2-L179）：先定义清场/建造实现与阶段日志，再用 `ConstructionModule.new` 构造门禁服务（L153-L157），把服务方法重新绑定为本地 `clearGenerationArea` / `buildGeneration`（L164-L165），最后把阶段函数、清场、建造、服务表与 `RV.Server.Construction` 写到 ctx（L171-L177）。因此本文件是"实现 + 装配"的混合点：Flow 捕获的 `ctx.clearGenerationArea` 实际是 RV_Construction 的门禁方法，而不是这里的原始实现。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| 模块工厂（L2） | `ctx`：`Constants`、`Boundary`（L4，**全文件未被使用**）、`ServerUtil`、`ServerWorld`、`ServerSchema`、`GenerationTransaction`（L5-L14）以及 4 个由 WorldObjects 预先注册的工厂（L10-L13）。无返回，写 ctx L171-L177。 | **必须**：装配根在 L143 调用；它同时是本模块 Construction 服务的创建者。 |
| safeErrorText（L16） | `err`：任意 Lua 错误值（L9 已声明局部变量）。保护性 `tostring`，可用时附加 `debug.traceback`（L21-L31）。返回字符串。 | **必须**：本模块的错误格式化单一实现，Flow/Ack 都经 `ctx.safeErrorText` 使用；L178 把它发布到 ctx。 |
| setGenerationPhase（L37） | `generation`、`phase`：代号与阶段名；只 `print`（L38-L39），不写任何内存或持久状态。无返回。 | **保留理由**（当前不是功能必需）：事务阶段权威是 `record.stage`，本函数对状态机零影响；保留成本仅为 6 个调用点（Build L93/L124/L139/L142、[RV_Construction.lua:63](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Construction.lua:63) 经 `operations`、[RV_Server_GenerationFlow.lua:233](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:233)）提供的排障可见性。 |
| recalcAndCheckStructure（L42） | `cell`、`bounds`、`layout`：目标 cell、托管范围与布局；按 room 矩形、`layout.templateObjects`、`bounds.wallCoordinates` 去重重算（L65-L77），再探测 room 元信息（L83-L88）。返回去重重算的方格数。副作用：重算世界属性。 | **必须**：建造后必须让引擎重新计算邻格/房间/碰撞，否则生成的结构对玩家与 room ownership 不可见。 |
| recalcAt（L45） | `x`、`y`、`z`：方格坐标；`required`：缺格是否致命（L48-L51）。按 `x:y:z` 去重后调用 `ServerWorld.recalcSquare`（L56-L57）。返回 square 或 nil。 | **必须**：recalcAndCheckStructure 的唯一执行体；模板对象宿主格必须存在（L70-L73 传 true），room 矩形则允许缺失（L67 传 false）。 |
| clearGenerationArea（L92） | `cell`、`bounds`、`generation`；先 `setGenerationPhase(..., "CLEARING")`（L93），再 `ServerSchema.walkBounds` 对每个现存方格调 `ServerWorld.clearSquare(square, nil)`（L97-L99）。无返回。 | **必须**：实际清场实现；`nil` 表示不限 identity，因为 Construction 预检已保证范围为空且本代无 undo 快照。 |
| clearGenerationArea 中匿名函数（L97） | `square`：范围内现存方格；调用 `clearSquare`，无返回。 | **实现必需**：清场必须逐格调用世界删除 API，且只能作用于已加载方格。 |
| buildGeneration（L102） | `player`、`layout`、`bounds`、`generation`；取 cell 与 generator sprite（L103-L105），从 `GenerationTransaction.current()` 取 `rvId` 组成 tagContext（L108-L111），建立 templateIndex→shell edge 映射（L113-L120），逐条创建捕获模板对象（L125-L137），重算结构（L140），最后定位并创建 generator（L143-L148）。无返回，失败 `error`。 | **必须**：实际建造主体，所有对象身份/几何都来自编译模板与当前记录的 rvId。 |
| construction.ensureGeneratorForEntry（L158） | `player`、`record`；先检查 `ctx.ensureGeneratorForEntry` 是函数（L159-L161），再转发（L162）。返回工厂的 `(true)` 或 `(false, 原因)`。 | **必须**：把 WorldObjects 的入口修复实现包装成 Construction 服务方法，是 EntryExit 的唯一入口（[RV_RailroaderServer_EntryExit.lua:286-L293](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:286)）；属对外合同的一部分。 |

### RV_Server_GenerationFlow.lua

本文件是 ctx 工厂（L2-L471）与本模块最大的编排者：它校验请求、分配 RV 区域、构造唯一的事务记录、编排清场/建造/最终搬运，并在最终 ACK 后完成 boundary 与 mapping 提交。它在加载时捕获 ctx 函数（L23-L35），但在少数位置改为动态读取（L14 的全局 adapter、L187 的 `ctx.constructionService`、L233 的 `ctx.setGenerationPhase`），两种风格对加载顺序的容忍度不同。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| 模块工厂（L2） | `ctx`：命令名常量、`Constants`、`Boundary`、`RV`、`ServerUtil`、`ServerWorld`、`ServerSchema`、`GenerationTransaction`、RoomOwnership 守卫、玩家校验/传送和 railroader 钩子（L3-L35）。无返回，注册 L465-L470。 | **必须**：装配根在 L147 调用；入口四函数与 staging 帮助函数都由此发布。 |
| allocateRVRegion（L13） | 可变参数（当前传 `railroaderData.locoId` 或 nil，L354-L355）；经全局 `RailroaderRV.RailroaderServer.allocateRVRegion` 分配（L14-L19），不可用返回 `false, INVALID_RV_DATA`。 | **必须**：服务端区域槽分配只能由 mapping 适配器决定，客户端不参与；L14-L19 的全局探测使 Railroader 保持可选依赖。 |
| safeErrorText（L21） | 单行 `local function`，转发 `ctx.safeErrorText`。 | **实现必需**：pcall 结果格式化不可再抛错；与 Ack 的同名转发重复，可直接引用 ctx。 |
| selectGenerationStagingDestination（L43） | `layout`、`bounds`：当前布局与托管范围（`layout` 未参与计算）；按托管范围中心 + `GENERATION_STAGING_Z = -15`（L41）造目的地，并用 `getWorld():isValidSquare` 验证（L52-L60）。返回目的地表（含 `purpose = "generation-center"`），非法即 `error`。 | **必须**：staging 点是服务端选定的空域坐标，客户端不提供；`layout` 形参未使用。 |
| playerIsAtStagingDestination（L64） | `player`、`destination`、`bounds`：要证明的玩家与目的地；读权威位置（L65-L68），逐轴比较（L69-L72），再核对 `generation-center` 身份与中心坐标是否与当前 bounds 一致（L73-L84）。返回 true 或 false+原因。 | **必须**：防止旧目的地/旧 bounds 的 ACK 被当成当前 staging 到达（tick 与 Core 都依赖它，[RV_Server_Commands.lua:206](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:206)）。 |
| validateRequest（L87） | `module`、`command`、`player`：网络事件字段；核对命令模块与命令名（L88-L93）、权威玩家（L94-L97）、调试权限（L98-L101）。返回 `true, 位置` 或 `false, 原因`。 | **必须**：命令入口的第一道门禁，且返回的服务端位置供 Core 继续使用（[RV_Server_Commands.lua:366-L379](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:366)）。 |
| relocatePlayerIntoHouse（L108） | `player`、`prepared`：事务记录；要求最终点恰为 anchor+0.5（L113-L115），发最终 relocation 并带新 deadline（L119-L120），写 `prepared.stage = "WAIT_FINAL"` 与 `prepared.finalAcked = false`（L124-L125）。无返回，发送失败 `error`。 | **必须**：这是"建造成功 → 进屋 → 等 final ACK"的唯一切换点；`record.stage` 在此改变，Core 的 WAIT_FINAL 分支据此生效。 |
| generateForPlayer（L128） | `player`、`prepared`：tick 传入的活动记录；先要求 `owns(player)` 且 `stage == "WAIT_STAGING"`（L129-L132），把阶段置为 BUILD（L133），再在 `pcall` 内执行：复验玩家/权限/railroader 钩子/身份（L138-L167）、取 layout/bounds/anchor（L168-L170）与 cell（L171）、证明仍在 staging（L172-L176）、`ServerSchema.preflightLoaded`（L180）、Construction 目标预检（L187-L199）、arm/注册 room ownership 守卫（L205-L207）、`pcall(clearGenerationArea)`（L209-L210）、仅在清场成功后 `pcall(buildGeneration)`（L214-L217）、提交前守卫复扫（L223-L231）、置 `FINAL_RELOCATE` 阶段并做最终搬运（L232-L238）、成功返回 `"await-final-relocate"`（L242）。失败返回 `false, safeErrorText(错误)`（L247-L250）。副作用：世界清场/建造、守卫注册、记录阶段改写。 | **必须**：本模块的核心 use case 与唯一的世界变更编排点；返回字符串 `"await-final-relocate"` 是给 Core 的异步 sentinel。 |
| generateForPlayer 中匿名函数（L137） | 无显式参数，闭包捕获 `player`/`prepared`；是 `pcall` 保护体，承载全部校验与清场/建造顺序。返回值原样交给 pcall。 | **实现必需**：世界变更必须整体受 pcall 保护，失败原因交给 abort 路径。 |
| finalizeGenerationAfterRelocate（L257） | `player`、`prepared`；要求 `stage == "WAIT_FINAL"` 且 `finalAcked == true`（L258-L260）。`pcall` 内：位置证明（L264-L290，未证明则重发最终 relocation 并 `error` 让 tick 下一轮重试）、`refreshGenerationRoomOwnershipGuard(..., "before-commit")`（L294-L295）、`Boundary.completeTransition(player, token)` 必须为 true（L296-L299）、`"pre-mapping-commit"` 复扫（L300-L301）、可选 railroader mapping commit 并置 `prepared.commitApplied = true`（L304-L315）。成功写 `prepared.stage = "DONE"`（L320）并返回 true。 | **必须**：唯一的提交点；room/transition/mapping 三类检查的顺序与失败语义都在这里固定。 |
| finalizeGenerationAfterRelocate 中匿名函数（L262） | 无显式参数，闭包捕获 `player`/`prepared`；是 `pcall` 保护体，返回 nil 或错误对象。 | **实现必需**：异步 continuation 必须在保护区里运行，否则 tick 的 pcall 无法转成 abort。 |
| queueGeneration（L324） | `player`：请求者；`authoritativePosition`：**函数体未读取**（L347 重新读取权威位置）；`railroaderData`：可选 Railroader 上下文。流程：`GenerationTransaction.isActive()` 并发门禁（L325-L329）→ 查询 `RV.Server.isWallReloadTransactionActive` 互斥（L333-L342）→ 玩家身份（L343-L346）→ 服务端原始位置（L347-L350）→ `allocateRVRegion`（L354-L358）→ 拒绝同槽重建（L366-L369）→ `Layout.make` + `ServerSchema.boundsFor` + `validateTargetCoordinates`（L374-L384）→ 选 staging 点（L385）→ 生成 token（L386-L388）→ 构造记录表（L396-L430）→ `GenerationTransaction.begin`（L431）→ `Boundary.beginTransition`（L433-L442）→ `sendStagingRelocation(record, "temporary")`（L448）→ 打印队列日志（L456-L460）。返回 true 或 false+原因；失败路径释放事务。 | **必须**：把客户端意图转成服务端计划与进程内事务；所有坐标、槽位与 token 都在这里定型。 |

### RV_Server_PlayerValidation.lua

本文件是 ctx 工厂（L7-L324），承担三类职责：玩家/权限/坐标校验（L22-L118）、位置证明与两个 relocation 命令（L140-L279）、以及每 tick 的 boundary 租约续期与重发（L286-L313）。它不读其它文件内部状态，只按字段读取传入的事务记录，并把记录当参数向下传。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| 模块工厂（L7） | `ctx`：命令名常量、`Boundary`、`RV` 门面、`ServerUtil`、`RELOCATION_TIMEOUT_TICKS`、`WORLD_MIN_Z/WORLD_MAX_Z`（L8-L16）。无返回，导出 L315-L323。 | **必须**：装配根在 L144 调用；玩家校验与 relocation 是生成事务的前置与推进条件。 |
| readPlayerCoordinate（L22） | `player`、`methodName`（`getX`/`getY`/`getZ`）、`label`：诊断标签；保护调用并数值化（L23-L27），`getZ` 额外校验世界 z 范围（L28-L30）。返回 number，失败 `error`。 | **必须**：所有坐标信任都集中在服务端 IsoPlayer；两个校验器共用它。 |
| validateAuthoritativePlayer（L34） | `player`：发送者；校验 IsoPlayer 类型（L35-L37）、未死亡（L38-L41）、三轴坐标与世界方格合法（L42-L53）。返回 `true, {x,y,z}`（floor 后的方格坐标）或 `false, 原因`。 | **必须**：请求资格与 staging 判定的基础；返回 floor 坐标是刻意的方格语义。 |
| authoritativePlayerPosition（L63） | `player`：服务端玩家；同样的类型/存活/世界校验，但返回**未取整**的 `{x,y,z}`（L83）。 | **必须**：位置证明与回滚必须比较真实精度位置，不能与方格中心混淆；仅 Flow 使用（L347）。 |
| validateGenerationPermission（L86） | `player`：发送者；要求 `Capability.UseDebugContextMenu` 存在（L87-L91）且角色具备该 capability（L92-L99）。返回 true 或 false+原因。 | **必须**：非 Railroader 的调试生成路径必须限权；Railroader 路径在自己的适配器里已校验，Flow L145-L150 据此跳过本检查。 |
| playerIdentity（L103） | `player`：服务端玩家；要求非负整数 `getOnlineID`（L104-L108）与非空 `getUsername`（L109-L112）。返回 `{onlineId, username, key = "id:name"}` 或 false+原因。 | **必须**：跨重连的稳定身份键，事务记录、ACK 比对与 RecordValidation 都用它（[RV_Server_RecordValidation.lua:12](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RVMapping/RV_Server_RecordValidation.lua:12)）。 |
| resolvePendingPlayer（L123） | `record`：含稳定 identity 的事务记录；按 `onlineId` 全局查找活动玩家（L128-L132）并复核 key（L133-L136）。返回 `true, IsoPlayer` 或 `false, 原因`；**不写记录、无副作用**。 | **必须**：把"记录里的旧 userdata"与"当前在线对象"解耦，重连后仍能证明同一个人；tick、ACK、abort 三处都依赖它。 |
| relocationPositionsEqual（L140） | `left`、`right`：位置表；三轴严格相等返回 true。 | **必须**：位置证明的精确比较原语，避免在多处重复比较逻辑。 |
| generationPositionProof（L150） | `player`、`target`：权威玩家与期望目标；先精确比较（L156），再只接受"目标为半格中心且当前落在同一格"的 B42 规范化（L157-L166）。返回 `true, "exact"/"target-cell"`，否则 `false, 位置或原因, 是否可读`。 | **必须**：最终 ACK 与提交步骤共用的唯一位置证明；第三个返回值区分"位置不可读"与"位置不符"，但当前两个调用点都只取两个值（Flow L264、Ack L66）。 |
| earlierTick（L170） | `left`、`right`：tick 值；返回较小者。 | **必须**：租约不能超过记录 deadline，续期取 min 需要它。 |
| sendRelocate（L174） | `player`、`payload`：目标与身份；经 `ServerUtil.callGlobalSucceeded("sendServerCommand", ...)` 发 `COMMAND_RELOCATE`。返回成功布尔。 | **必须**：staging 阶段的服务器→客户端命令唯一发送点。 |
| sendStagingRelocation（L182） | `record`、`phase`（`"temporary"` 或 `"return"`）：事务记录与语义；按 phase 选 staging 或原始位置（L183-L184），构造只含服务端选定坐标的 payload（L188-L198），Railroader 路径附座位提示（L201-L207），发送后由 `RV.Server.teleportToPosition` 落位（L212-L215），`return` 再用官方 setter 恢复精确坐标（L218-L229）。写 `record.lastSentTick`（L230）。返回 true 或 false+原因。 | **必须**：初始 staging、重发与 abort 送回三条路径共用一个实现；返回目标必须是精确捕获位置，否则 abort 无法在有证明的位置上释放。 |
| sendFinalRelocation（L236） | `record`、`deadline`（可选，仅首次发送提供）；发 `COMMAND_FINAL_RELOCATE`（L261-L264），teleport + setter 恢复半格中心（L268-L275），可选写 `record.deadlineTick`（L276）与 `record.lastSentTick`（L277）。返回 true 或 false+原因。 | **必须**：final relocation 的唯一发送点，且是"提交步骤重新声明目标"的实现（Flow L274 无 deadline 调用）。 |
| keepGenerationTransitionAlive（L286） | `record`：活动事务记录；仅处理 `WAIT_STAGING`/`WAIT_FINAL`（L287-L290）。解析在线玩家：失败则只延长 deadline（L294-L297）；成功则写回 `record.player`（L299）、用 `min(deadlineTick, now+30)` 续 boundary 租约（L300-L302），并按 30 tick 节流重发当前阶段的 relocation（L303-L312）。无返回。 | **必须**：每 tick 保持 token 范围的 boundary 租约并重发 relocation；断线时延长而非取消，是本模块的可用性合同。 |

### RV_Server_WorldObjects.lua

本文件是 ctx 工厂（L2-L816），也是目录中最大的文件：它提供捕获模板对象的严格状态应用与逐类构造、roof square 的幂等创建、generator 的创建，以及"玩家进入已生成 RV 时修复缺失 generator"的入口逻辑。它导出的 5 个函数是 Build 与 TemplateRecovery 共用的对象工厂合同（L811-L815）。除对象 ModData 标签外，它不持有跨请求状态。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| 模块工厂（L2） | `ctx`：`OWNER`、`Constants`、`Boundary`、`ServerUtil`、`ServerWorld`（L3-L7）与 `require` 的 `TemplateGeometry`（L8）。无返回，导出 L811-L815。 | **必须**：装配根在 L142 调用；它是本模块最早的装配点，其导出被后续 Build/Flow 与 TemplateRecovery 捕获。 |
| integer（L10） | `value`：任意可数值化值；经 `ServerUtil.toNumber` 后要求有限整数（L11-L17）。返回整数或 nil。 | **必须**：generator 坐标与 generation 比较需要"失败即 nil"的严格整数，不能复用会抛错或默认 0 的变体。 |
| identityOf（L20） | `value`：标签或边界表；返回 `(rvId 或 locoId 的字符串, generation 整数)`。 | **必须**：标签与 boundary 的两种身份来源（`rvId` / `locoId`）需要统一取值。 |
| sameIdentity（L26） | `left`、`right`：含身份的表；两边 id 与 generation 都相等才 true。 | **必须**：generator 白名单与回滚筛选的唯一身份判定。 |
| applyIntegerState（L33） | `object`、`state`、`key`、`setter`（可为 nil）、`getter`：目标对象、状态表、字段名与引擎访问器。字段缺省即返回；否则要求整数并写回、读回（L34-L43），不匹配即 `error`。 | **必须**：捕获模板的 health/maxHealth 必须严格应用并读回验证，否则生成出的对象与模板不符且无法察觉。 |
| applyBooleanState（L46） | 同上但针对布尔字段（L47-L56）。 | **必须**：canPassThrough/blockAllTheSquare/doRender/thumpable 四类布尔状态共用严格写读回。 |
| capturedObjectContext（L59） | `entry`：捕获条目；拼接 templateIndex/class/name/sprite/世界坐标诊断串。 | **必须**（诊断）：捕获对象失败必须能定位到具体模板条目，否则捕获模板对象的构造失败无法排查。 |
| ensureCapturedHiddenSprite（L68） | `entry`：捕获条目；非隐藏 sprite key 直接返回 nil（L69），否则要求 `RV_UtilitySprite.ensureHiddenSprites()` 就绪并返回预期 sprite（L70-L77），失败 `error`。 | **必须**：自定义隐藏 sprite 必须在字符串构造器之前注册，否则 sprite manager 会缓存未索引项。 |
| bindCapturedHiddenSprite（L79） | `object`、`entry`、`expectedSprite`：对象、条目与已注册 sprite；非隐藏 key 返回（L80），否则 `setSpriteFromName` 后核验 sprite 对象、`getName` 与 `getSpriteName` 三者一致（L85-L100），失败 `error`。 | **必须**：构造器可能绑定默认 sprite，必须用三重读回证明绑定结果。 |
| applyCapturedHealthState（L103） | `object`、`entry`；IsoWindow 无 setter，只做读回；其它类调用 `setHealth` 并读回（L104-L110）。 | **必须**：适配不同引擎类的 health API 差异，属模板状态合同的一部分。 |
| applyCapturedIdentityAndState（L113） | `object`、`entry`、`deferHealth`：目标对象、捕获条目、是否延迟 health；校验记录字段与 class（L114-L122）、north 与 state 白名单（L123-L138）、写 setName/setDir（L139-L147）、按类应用 hoppable 双 API（L159-L197）、四个布尔状态（L199-L206）、locked 三路读回（L208-L239），最后核对 name/dir/sprite（L241-L258）。无返回，任何不符 `error`。 | **必须**：捕获对象的严格状态合同；任何放宽都会让"模板捕获"与"程序生成"产生不可检测的偏差。 |
| capturedTagData（L261） | `entry`、`edge`：捕获条目与可选壳体边；返回只含 `templateIndex`（与可选 `edgeKey`）的标签数据。 | **必须**：标签只携带身份，几何在读取时从模板与方格推导；这是"无几何副本"合同的关键实现。 |
| isVisualCornerTemplateEntry（L275） | `entry`；精确匹配 `IsoObject` + `Wooden Wall` + `walls_interior_house_02_35`。返回布尔。 | **必须**：角饰必须走 tile object 路径而不是 floor slot，判定条件必须精确。 |
| configureCapturedDoorFrame（L282） | `object`、`entry`；要求固定门框身份（L283-L288），设置通行、门框与非 thumpable（L289-L292），失败 `error`。 | **必须**：门框对象的特殊通行状态无法由通用状态表表达；被模板修复复用（[RV_Server_TemplateProtectionRepair.lua:13](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:13)）。 |
| ensureRoofSquare（L296） | `cell`、`x`、`y`、`z`：目标 cell 与坐标；存在即返回（L302-L305），否则用 `IsoGridSquare.new(cell, nil, x, y, z)` + `ConnectNewSquare` 构造连接（L307-L316），类不可用时回退 `cell:createNewGridSquare(x, y, z, true)`（L321-L325），最后读回确认（L327-L331）。返回 square，失败 `error`。副作用：创建并连接世界方格。 | **必须**：roof 层宿主格缺失时必须能建立或复用，且必须幂等（含 addFloor 失败后的空方格），否则重试会造出重复/未连接对象。 |
| createFloor（L334） | `square`、`sprite`、`generation`、`role`、`tagContext`、`capturedEntry`、`edge`：宿主格、sprite、代号、角色、标签上下文与可选捕获条目/壳体边。新建或替换 floor sprite（L338-L379），可应用捕获状态（L380-L382），写 previousSprite/createdByGeneration 并打标签（L383-L396），按新旧对象分别同步（L397-L413），最后重算方格。返回 floor。 | **必须**：捕获 floor 与多阶段 floor 更新的共用实现，且必须保留生成前 sprite 供回滚。 |
| addSpecialObject（L418） | `square`、`object`：宿主格与对象；已附着则跳过，否则 `AddSpecialObject`（L421-L430），再要求 `getObjectIndex >= 0`（L431-L435），最后重算方格（L439）。无返回，不发包。 | **必须**：让调用方在所有对象状态最终确定后只发一次完整包；此处发包会造成同一对象索引的重复包。 |
| createGenerator（L442） | `cell`、`square`、`sprite`（**函数体未读取**）、`generation`、`tagContext`：目标 cell、宿主格、代号与标签上下文。构造 `Base.Generator` item 并设 condition/fuel（L446-L454），要求隐藏 sprite 就绪（L455-L462），用 `IsoGenerator(cell)` 构造并设 info/隐藏 sprite 并读回（L463-L479），设 square 并读回（L480-L486），设 condition/fuel/connected/activated（L490-L495），打标签（L496）、附着（L497）、可选 `updateGenerator`（L498-L500）、发完整包（L501-L503）。返回 generator。 | **必须**：GenerationBuild 主建造路径与 entry 修复路径都调用它（[GenerationBuild.lua:148](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationBuild.lua:148)、L774）；`sprite` 形参是历史残留，三个调用点仍传 `Constants.SPRITES.generator.sprite`。 |
| createCapturedTemplateObject（L507） | `cell`、`square`、`entry`、`generation`、`tagContext`、`edge`：目标 cell/方格、捕获条目、代号、标签上下文与可选壳体边。按 class 分派：视觉角饰走 `IsoObject` + `AddTileObject`（L516-L543），其它 `IsoObject` 走 floor 槽（L544-L549），`IsoThumpable`（L550-L577）、`IsoDoor`（L578-L592）、`IsoWindow`（L593-L610）、`IsoLightSwitch`（L611-L633）各自构造、应用状态、打标签、附着，最后统一发完整包（L638-L640）；未知 class `error`（L634-L637）。返回对象。 | **必须**：本模块的对象工厂主入口，Build 与 TemplateRecovery 共用（[GenerationBuild.lua:11](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationBuild.lua:11)、[RV_Server_TemplateProtectionRepair.lua:12](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:12)）。 |
| generatorObjectTag（L644） | `object`：世界对象；从 `ServerWorld.objectModData` 取本模组 namespace 标签，要求 `owner == Constants.MOD_ID`（L645-L650）。返回标签或 nil。 | **必须**：generator 白名单与回滚筛选都要先确认标签归属本模组。 |
| isWhitelistedGenerator（L653） | `object`、`boundary`：候选对象与当前边界；要求标签身份一致、`role == "generator"`、类为 `IsoGenerator`（L654-L658），再按模板 anchor + `Constants.GENERATOR_OFFSET` 核对世界坐标（L659-L666）。返回布尔。 | **必须**：区分"本 RV 的 generator"与"其它 RV/玩家的 generator"，坐标与身份必须同时成立。 |
| rollbackEntryGenerator（L669） | `square`、`before`、`boundary`、`created`（可选）：宿主格、操作前对象集合、边界与本函数本次创建的对象。快照后逐个判定候选（引用相同或标签身份匹配，L674-L684），删除并验证摘除（L685-L697）。返回 true 或 false+原因。 | **必须**：entry 修复是"创建或复用"语义，失败必须清理自己造出的 generator，否则下次进入会看到歧义对象。 |
| ensureGeneratorForEntry（L702） | `player`、`record`：进入者与 mapping 记录；先要求 `RV.Server.currentRVManifestForRelocation` 接受身份（L706-L718），由 boundary 推出 anchor 与 generator 坐标（L719-L729），取 cell/chunk 并处理未加载（L731-L745），chunk 未加载即成功返回（L746-L750），取方格与快照（L752-L759），判定 present/ambiguous（L761-L772），缺失则 `createGenerator` 并回滚式验证（L774-L804）。返回 true 或 false+原因。 | **必须**：玩家进入已生成 RV 时修复缺失 generator 的唯一入口，经 Construction 服务对外发布；nil chunk 视为"未加载即正常"，避免在未加载区域造格。 |
| ensureGeneratorForEntry 中匿名函数（L746） | 无显式参数，闭包捕获 `chunk`；`pcall` 读取 `chunk.loaded`。 | **实现必需**：Java proxy 属性读取可能抛错，必须转成"未加载/非法"而非中断。 |
| ensureGeneratorForEntry 中匿名函数（L788） | 无显式参数，闭包捕获 `square`/`created`/`boundary`；核验附着与白名单，返回布尔。 | **实现必需**：附着与身份读回必须在保护区内完成，失败要落到回滚分支。 |

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **错误格式化已集中，但有两个薄转发**：实现只在 [RV_Server_GenerationBuild.lua:16](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationBuild.lua:16)，并发布到 `ctx.safeErrorText`（L178）；[RV_Server_GenerationAck.lua:9](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationAck.lua:9) 与 [RV_Server_GenerationFlow.lua:21](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua:21) 各有一个单行转发器。语义无差异，可直接在各调用点写 `ctx.safeErrorText(...)`；净收益是减少两个"看起来像实现"的包装，风险接近零，但改动会触碰 6 个调用点，收益很小，可延后。
- **玩家坐标读取已在文件内提取**：`readPlayerCoordinate`（L22）被 `validateAuthoritativePlayer`（L42-L44）与 `authoritativePlayerPosition`（L71-L73）共用。两者返回精度不同（floor 方格 vs 原始浮点）是刻意合同，**不应**压成单一返回语义，提取到公共库的收益为负。
- **位置证明已是单一实现并跨文件复用**：`generationPositionProof`（L150）经 `ctx.generationPositionProof` 被 Flow（L33/L264）与 Ack（L12/L66）共用。这是本目录内正确复用的一条；其"半格规范化"分支只应存在一份。
- **传送发送与 payload 构造已集中**：`sendStagingRelocation`（L182）/`sendFinalRelocation`（L236）是全目录唯一构造 relocation payload 的地方，Flow 与 Ack 只调用不复制。`sendRelocate`（L174）是更窄的发送原语。建议保持。
- **捕获状态写读回**（`applyIntegerState` L33、`applyBooleanState` L46、`applyCapturedHealthState` L103）只在 WorldObjects 内被调用，且深度绑定模板字段白名单与引擎 API 差异，**不宜**提升为通用工具。
- **身份三元组比较有两套**：本目录 `identityOf`/`sameIdentity`（L20/L26）接受 `rvId` 或 `locoId` 两种键；[RV_Server_RecordValidation.lua:188-L189](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RVMapping/RV_Server_RecordValidation.lua:188) 用 `tostring(pending.rvId)` + `ServerUtil.integer(pending.generation)` 直接比较。语义差异真实（一个做键回退，一个做数字归一），提取前必须先决定"身份表 schema"，否则会引入不兼容的宽松化；当前不建议合并。
- **整数校验已由 Common 提供**：`ServerUtil.integer`（[RV_ServerUtil.lua:45](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerUtil.lua:45)）存在，但 WorldObjects 仍自定义 `integer`（L10）——后者经 `toNumber` 并允许 nil 返回，是刻意的宽松解析，属可接受的分层，不建议强制统一。
- **可直接共用的候选**：`GenerationBuild.recalcAt`（L45）与 `ServerSchema.walkBounds`（[RV_ServerSchema.lua:43](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerSchema.lua:43)）都在做"坐标 → 方格"遍历。前者需要去重与 `required` 语义，后者只遍历已加载格；强行合并会改变失败语义，保持分离。

### 是否进一步拆分

本目录 7 个文件、2068 行，拆分判断集中在 WorldObjects 与 Flow 两个文件。

1. **WorldObjects.lua（816 行 / 25 函数）是首要候选。** 三类职责边界清楚：捕获状态、标签与角饰/门框判定（L10-L294，约 285 行）、对象工厂（L296-L642，含 floor/generator/角饰/门窗/灯开关，约 350 行）、generator 白名单与 entry 修复（L644-L805，约 160 行）。建议拆为 `RV_Server_CapturedObject`（状态 + 工厂）与 `RV_Server_GeneratorEntry`（白名单 + 入口修复）。成本是 `createGenerator` 被两条路径共用（工厂路径 L148 与 entry 路径 L774），必须保留一个共享导出；收益是 entry 修复的回滚逻辑（L669-L804）与对象构造可以独立审阅。
2. **GenerationFlow.lua（471 行 / 12 函数）可按"计划/排队（L43-L126、L324-L462）、同步编排（L128-L251）、提交（L257-L322）"拆分。** 建议前提：先把 `prepared.stage` 的写入点集中。**源码事实**：全树 `stage =` 赋值只有 4 处、2 个文件——Flow L124、L133、L320 与 [RV_Server_GenerationTransaction.lua:21](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationTransaction.lua:21)；GenerationAck（L33、L55、L99、L104）、PlayerValidation（L288、L308）、RV_Construction（L53）与 Core/RV_Server_Commands.lua（L197-L198、L202、L234、L243）中的相关行**全部是只读**，没有任何一处写 `stage`。否则拆分只会把同一个可变表的写点扩散到更多文件。
3. **PlayerValidation.lua（324 行 / 14 函数）可拆为"身份与授权校验（L22-L118）"与"位置证明 + relocation 租约（L140-L313）"。** 两者共享同一记录字段合同与 `ctx.serverTick`，拆分收益中等；若近期还要扩展 lease/重连语义，再拆更划算。
4. **GenerationAck.lua（146 行 / 5 函数）不建议拆。** `abortGeneration`（L94）是唯一 abort 路径，必须与两个 ACK 处理同属一个 owner，拆开会让"谁能在失败时释放事务"变成跨文件问题。
5. **RV_Construction.lua（79 行）与 GenerationBuild.lua（179 行）不建议拆。** 前者是纯门禁，后者是"实现 + 服务装配"；两者合计 258 行，边界已经清晰，按函数数量机械切分只会加重 ctx 注册表。
6. **GenerationTransaction.lua（53 行）不建议拆。** 它只有 6 个操作与 1 个 upvalue；真正需要收敛的不是它的体积，而是它**没有**掌握的阶段字段（见下节）。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **创建与装配**：`GenerationTransaction` 由装配根创建并注入（[RV_Server.lua:51-L52](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:51) 与 L122）；本目录另外 5 个文件是 `return function(ctx)` 工厂（WorldObjects L2、Build L2、PlayerValidation L7、Flow L2、Ack L3），RV_Construction 是 `return Construction` 表（L79）。装配顺序为 WorldObjects → GenerationBuild → PlayerValidation → TemplateRecovery ×2 → Flow → RecordValidation → Ack → Commands（[RV_Server.lua:141-L150](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:141)）。**这个顺序是隐式合同**：Flow 在 L27-L35 捕获 `ctx.clearGenerationArea` / `ctx.buildGeneration` / `ctx.sendStagingRelocation` 等，而它们分别由 Build（L172-L173）与 PlayerValidation（L316-L317）更早发布。
- **ctx 导出与其全树消费者**：
  - Build：`setGenerationPhase`（L171，消费者 Flow L233）、`clearGenerationArea`（L172，Flow L27）、`buildGeneration`（L173，Flow L28）、`constructionService`（L174，Flow L187）、`RV.Server.Construction`（L176，RVMapping EntryExit L286-L293）。
  - PlayerValidation：`keepGenerationTransitionAlive`（L315，Core Commands L27）、`sendStagingRelocation`（L316，Flow L34 与 Ack L120 动态读取）、`sendFinalRelocation`（L317，Flow L35）、`validateAuthoritativePlayer`（L318，Commands L28、Flow L29）、`authoritativePlayerPosition`（L319，Flow L30）、`validateGenerationPermission`（L320，Commands L29、Flow L31）、`playerIdentity`（L321，RecordValidation L12、Ack L13、Flow L32）、`resolvePendingPlayer`（L322，Commands L30、Ack L14）、`generationPositionProof`（L323，Flow L33、Ack L12）。
  - Flow：`validateRequest`（L465，Commands L32）、`generateForPlayer`（L466，Commands L33）、`finalizeGenerationAfterRelocate`（L467，Commands L34）、`queueGeneration`（L468，Commands L35、RecordValidation L13）、`selectGenerationStagingDestination`（L469，**全树无消费者**）、`playerIsAtStagingDestination`（L470，Commands L31）。
  - Ack：`acknowledgeRelocation`（L143，Commands L36）、`acknowledgeFinalRelocation`（L144，Commands L37）、`abortGeneration`（L145，Commands L38）。
  - WorldObjects：`ensureRoofSquare`（L811，Build L10）、`createGenerator`（L812，Build L12）、`createCapturedTemplateObject`（L813，Build L11、TemplateProtectionRepair L12）、`configureCapturedDoorFrame`（L814，TemplateProtectionRepair L13）、`ensureGeneratorForEntry`（L815，Build L13）。
- **公开门面**：本模块在 `RV.Server` 上只发布一个字段 `Construction`（[RV_Server_GenerationBuild.lua:176](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationBuild.lua:176)），其方法集是 `preflightCurrentGeneration`、`clearCurrentGeneration`、`buildCurrentGeneration`（RV_Construction 内定义）加上 Build 事后追加的 `ensureGeneratorForEntry`（L158）。唯一外部消费者是 [RV_RailroaderServer_EntryExit.lua:286-L293](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:286)，它只调用 `ensureGeneratorForEntry`。
- **未发布却被外部期望的查询**：`RV.Server.isGenerationTransactionActive` 被 3 处消费者查询——[RV_RailroaderServer_Sentinel.lua:153](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_RailroaderServer_Sentinel.lua:153) 与 L201、[RV_UtilityServer.lua:73](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:73)、[RV_WallReloadProtection.lua:456](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_WallReloadProtection.lua:456)——但全树既没有 `function RV.Server.isGenerationTransactionActive(...)` 声明也没有 `RV.Server.isGenerationTransactionActive = ...` 赋值（`RV.Server` 上的写入点只有 Construction（Build L176）、`resolveCurrentUtilityRV`（Commands L418）、utility 两项（[RV_Server.lua:96](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:96)、L99）、teleport 两项（L138-L139）以及本目录外的若干 `function RV.Server.X` 声明）。GenerationTransaction 已有 `isActive`（L37-L39），当前只在模块内被 Flow L327 使用。**条件性推断**（未运行时验证）：这些 gate 会走"state is unavailable"分支——Sentinel 的 `serverTransactionMutexStatus` 返回 nil、`wallReloadTransactionBlocks` 返回 true（[Sentinel:171-L173](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_RailroaderServer_Sentinel.lua:171)），`installTransactionGate` 直接返回 false（L197-L204），WallReloadProtection `M.begin` 与 UtilityServer 同样拿到不可用。即：**本模块发布了服务对象，却没有发布"事务是否活动"的查询**，这是当前对外契约最明显的缺口。
- **ACK 命令名不在本文件**：`COMMAND_RELOCATE` / `COMMAND_FINAL_RELOCATE`（发送，PlayerValidation L176/L262）与 `COMMAND_RELOCATE_ACK` / `COMMAND_FINAL_RELOCATE_ACK`（分派，[Commands:333-L365](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:333)）都定义在 Core；本模块只提供处理函数。

### 直接读写其他模块的数据

1. **事务记录是跨文件共享可变表（本模块最大的隐藏状态面）。** owner 只有引用：`record` upvalue 在 [RV_Server_GenerationTransaction.lua:9](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_GenerationTransaction.lua:9)，写点 L21（初始 stage）、L43-L44（cancel）、L49（release）；读取入口 L27 `current()`、L30-L35 `owns`、L38 `isActive`。
   - 调 `current()` 的文件：RV_Construction L52/L59/L69、Ack L29/L54、Build L108、Core Commands L184/L277/L346、RecordValidation L186。
   - 直接在记录上写字段的文件：Flow（构造 L396-L430，另写 L124、L125、L133、L186、L314、L320）、Ack（L41、L42、L45、L85、L86、L103）、PlayerValidation（L230、L276、L277、L296、L299）、GenerationTransaction（L21、L43-L44）、Core Commands（经 `cancel` L172）。
   - 直接读字段的文件：RV_Construction（`pending.stage` L53、`pending.player` L60、`pending.generation` L70）、Build（`pending.rvId` L110）、Ack（`record.stage` L33/L55/L104、`record.identity.key` L37/L59、`record.finalDestination` L65、`record.originalPosition` L119、`record.bounds`/`record.generation`/`record.rvId` L112）、PlayerValidation（`record.identity.onlineId`/`key` L125/L129/L134/L190/L243、`record.originalPosition`/`stagingDestination`/`finalDestination` L183-L184/L237、`record.stage` L288/L308、`record.deadlineTick` L296/L300、`record.lastSentTick` L303）、Core Commands（`deadlineTick` L196、`stage` L202/L234/L243、`stagingAcked` L203、`stagingDestination`/`bounds` L206-L207、`finalAcked` L244）。
   - **是否应改为接口**：收益明显，因为 `stage` 与两个 ack 标志合计只有 3 个文件写入（`stage` 仅 GenerationTransaction L21 与 Flow L124、L133、L320；ack 标志为 Flow L125、L428-L429 与 Ack L42、L86），读者还包括本文件与 Core。但改造成本集中在 Core：`processPendingGeneration`（Commands L183-L264）把 `stage` 当唯一权威并逐字段读取，若引入 `advanceStage/recordAck`，必须同步让 tick 只经查询函数取阶段。**建议顺序**：先加 `GenerationTransaction.stage()` / `markStagingAcked()` / `markFinalAcked()` 三个语义操作并把 Flow/Ack 的写点迁入，再改 Core 的读取；不要一步改成"记录不可变"。
2. **写 `RV.Server` 门面**：Build L175-L176 把服务写进 `ctx.RV.Server.Construction`，而该门面由 [RV_Server.lua:72-L74](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:72) 创建并拥有。这是"本模块写另一个模块的表"的**唯一**实例；语义清楚（发布公开服务），但接口形状由两个文件共同决定（RV_Construction 定义 3 个方法，Build L158 追加第 4 个）。
3. **直接自增 Core 的计数器**：Flow L386-L388 读 `ctx.pendingSerial` 后写回 `ctx.pendingSerial = ctx.pendingSerial + 1`，用于 token 唯一性；该字段由 [RV_Server.lua:86](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:86) 定义、L129 注入。这是**直接写外部模块状态**而非接口调用。当前无功能危害（Core 的本地 `pendingSerial` 之后不再被读），但应改为 `ctx.core.nextSerial()` 之类的接口，或明确把该字段划归本模块。
4. **读 Core 的 tick**：Flow L120/L387/L427、Ack L45、PlayerValidation L230/L277/L296/L300/L305 都读 `ctx.serverTick`，写点在 [Commands:267](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:267)。所有读取都是调用时字段访问（不是加载时快照），因此与 tick 更新一致；这是数据合同，不是内部状态访问。
5. **RoomOwnership 守卫是干净的接口访问**：Flow 只调用 4 个接口函数——`armClientRoomOwnershipGuard`（L205）、`registerServerRoomOwnershipGuard`（L206）、`refreshServerRoomOwnershipGuard`（L224）、`refreshGenerationRoomOwnershipGuard`（L294、L300）；实现与注册表 owner 是 [RV_Server_RoomOwnership.lua:12](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:12) 与 L321-L384，注册表本身由 [RV_Server.lua:88](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:88)、L131 创建。Flow 只保存并回传守卫句柄（L206-L207、L224），**没有读写守卫字段**。无需改动。
6. **Boundary 只经公开方法使用**：Flow `boundary.beginTransition`（L437）、`Boundary.completeTransition`（L296-L299）、`Boundary.clearPlayer`（L451）；Ack `Boundary.completeTransition`（L126-L128）；PlayerValidation `Boundary.extendTransition`（L291-L302）；WorldObjects `Boundary.boundaryFor(record)`（L719）并读 `boundary.managed`（L720、L723）。这些方法在 [RV_BoundaryServer_Geometry.lua:234-L328](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Geometry.lua:234) 公开定义；本模块从未触碰 `Boundary._states`（[RV_BoundaryServer.lua:35](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer.lua:35)）。
7. **WallReload 作为 ACK 路由器被直接 require**：Ack L8 `require(...RV_WallReloadProtection)`，L19-L25 调 `WallReload.acknowledge(player, token)` 并在 `wallHandled` 时提前返回。这是跨模块**功能复用**（同一命令名承载两类 ACK），读的是公开函数；但它把 WallReload 变成 GenerationAck 的硬依赖（缺模块时 staging ACK 直接被拒，L19-L22）。
8. **模板与工具模块**：Flow L12 `require RV_Layout` 用于 `Layout.make`（L374）；WorldObjects L8 `require RV_TemplateGeometry` 用于 `anchorFromManaged`（L659、L723）；WorldObjects L70/L455 在函数内 `require RV_UtilitySprite` 调 `ensureHiddenSprites`。都是公开 API，无内部状态访问。
9. **对象 ModData 标签字段被直接读取**：WorldObjects L350-L356 读旧 floor 标签的 `owner`/`previousSprite`/`generation`/`createdByGeneration`；L644-L651 读 generator 标签的 `owner`/`rvId` 或 `locoId`/`generation`/`role`。写入统一走 `ServerWorld.tagObject`（L387-L388、L496、L529-L530、L570-L571、L589-L590、L606-L607、L627-L628），标签布局由 [RV_ServerWorld.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua:470) 的公开写入口定义。当前只有两处窄读取，增加 `ServerWorld.getTag(object)` 的收益有限；若将来有第三个读取者或字段扩展，应优先补该读取器。
10. **全局 `RailroaderRV` 直读**：Flow L14-L15（取 `RailroaderServer.allocateRVRegion`）、WorldObjects L706-L707（取 `Server.currentRVManifestForRelocation`）。这不是读取模块私有 upvalue，但绕过了 ctx 注入，属隐藏依赖；好处是 Railroader 适配器可选加载（Flow L16-L18、WorldObjects L708-L710 都做了函数存在性检查）。

### 接口边界问题

- **`Construction.new` 接收整个 ctx 只用三个字段**（L9、L19、L20）。它是 service-locator 风格：依赖名无类型合同，字段更名不会在任何一处报错。可改为显式依赖表 `{ transaction = ..., strictSnapshot = ..., walkBounds = ... }`，收益中等（本文件仅 79 行，风险低）。
- **服务表被事后扩展**：`RV_Construction.new` 返回的 `service`（L76）在 Build L158 被追加 `ensureGeneratorForEntry`。接口形状不在单一定义点，`RV.Server.Construction` 的方法集需要读两个文件才能确定。建议把该方法移入 RV_Construction 并让依赖显式注入。
- **加载顺序耦合**：Build L164-L165 把本地 `clearGenerationArea`/`buildGeneration` 重绑定为服务方法后再发布（L172-L173）；Flow L27-L28 在加载时捕获它们。若 Flow 先于 Build 加载，捕获到的是 nil，首次生成才报错。这是隐式的装配合同，应至少在装配根处加注释或改成动态读取。
- **捕获与动态读取风格不一致**：Flow 捕获大部分 ctx 函数（L23-L35），却对 `ctx.constructionService`（L187）与 `ctx.setGenerationPhase`（L233）做动态读取，Ack 对 `ctx.sendStagingRelocation`（L120）也是动态读取。动态读取更宽容但与其余代码不一致，容易让"加载顺序"问题只在一部分符号上暴露。
- **`GenerationTransaction.owns` 的 token 分支无调用者**（L33）：两个调用点只传 player。token 是记录里真实存在的字段（Flow L387、L399）并被改写进 payload（PlayerValidation L189、L242），但没有任何服务端校验使用它——ACK 的门禁是 stage + 身份 + 位置证明。
- **final ACK 不读 `args`**（Ack L53）：文件注释（L50-L52）声明"payload 故意只有不透明 token"，但函数体从未读取 `args`，也没有把 `args.token` 与 `record.token` 比较。staging ACK 虽读取 `args.token`（L23），但只把它转交 WallReload（L24-L25），同样不与 `record.token` 比对。**源码事实**：token 当前是"载荷格式约定"而非服务端验证依据；有效门禁是阶段、身份与位置。
- **未使用形参/局部变量**：`queueGeneration` 的 `authoritativePosition`（L324，L347 重新读取权威位置）；`createGenerator` 的 `sprite`（L442，实际用 L457 的 `Constants.SPRITES.utilityHidden.sprite`，但 Build L148 与 WorldObjects L775 仍传 `Constants.SPRITES.generator.sprite`）；`preflightCurrentGeneration` 的 `layout`/`generation`/`identitySource`（L41-L45）；`generationPositionProof` 第三个返回值（L155、L167）无读取者；Build L4 `local Boundary = ctx.Boundary` 全文件未使用。这些是低风险清理项，但删除会改动调用点，属"文档记录优先"。
- **`ctx.selectGenerationStagingDestination`（Flow L469）无消费者**：函数本身被 `queueGeneration` 使用（L385），导出属预留；若要收紧接口，可删除该发布行。
- **`GenerationTransaction.cancel` 的写入无读取者**（见逐函数分析）：abort 语义当前只由 Core 直接调用 `abortGeneration` 实现，`cancelled`/`failureReason` 是死字段。这是"状态 owner 名义上存在、语义上未被消费"的典型例子，应优先处理。

## 函数清单、覆盖和验证记录

- **扫描文件**：`RV_Construction.lua`、`RV_Server_GenerationTransaction.lua`、`RV_Server_GenerationAck.lua`、`RV_Server_GenerationBuild.lua`、`RV_Server_GenerationFlow.lua`、`RV_Server_PlayerValidation.lua`、`RV_Server_WorldObjects.lua`；目录扫描确认 Construction/ 恰有这 7 个 Lua 文件。
- **机械核对 A（函数定义数 / 行数）**：

| 文件 | 行数 | 函数定义数 | named | local | method | anon |
|---|---:|---:|---:|---:|---:|---:|
| RV_Construction.lua | 79 | 8 | 4 | 3 | 0 | 1 |
| RV_Server_GenerationTransaction.lua | 53 | 7 | 6 | 0 | 0 | 1 |
| RV_Server_GenerationAck.lua | 146 | 5 | 0 | 4 | 0 | 1 |
| RV_Server_GenerationBuild.lua | 179 | 9 | 2 | 5 | 0 | 2 |
| RV_Server_GenerationFlow.lua | 471 | 12 | 0 | 9 | 0 | 3 |
| RV_Server_PlayerValidation.lua | 324 | 14 | 0 | 13 | 0 | 1 |
| RV_Server_WorldObjects.lua | 816 | 25 | 0 | 22 | 0 | 3 |
| **总计** | **2068** | **80** | **12** | **56** | **0** | **12** |

- **kind 口径**：`named` = 具名函数声明（`function X(...)`、`function Table.field(...)`）及对已声明局部变量的 `name = function(...)` 赋值（Build L16）；`local` = `local function`（含嵌套与单行形式）；`method` = 冒号方法 `function M:foo()` 或表字段匿名赋值 `M.foo = function(...)`（本目录没有）；`anon` = 匿名函数表达式（模块工厂 `return function(...)`、`pcall(function() ... end)`、`walkBounds` 回调）。`M.foo = localFunction` 形式的导出别名（如 Build L164-L165）不计数。
- **计数与旧报告差异**：旧报告记录 6 个文件、99 个函数、文件表行数合计 3332；当前为 7 个文件、80 个函数、2068 行。差异原因是第二阶段重构：`RV_Server_GenerationTransaction.lua` 新增（7 函数），manifest 持久化/恢复路径、RoofRefresh 组处理、`createWall`/`createLight`/`createFurniture`、`restoreCurrentCell` 等已整体移除。
- **逐行交叉核对**：全部 7 个文件按编号读取全文；条目中的行号是定义语句起始行；匿名函数另标"外层函数 中匿名函数（L行号）"。
- **跨模块调用扫描**：在 `media/lua` 全树检索本模块 27 个 ctx 导出符号与 `RV.Server.Construction` 的消费者，得到上节清单；另检索 `pendingGeneration`、`roofRefreshRelocationGroup`、`processRoofRefreshRelocationGroup`、`allowedPlayers`、`createFurniture`、`createEntityFromSprite`、`addNormalObject`、`createWall`、`createLight`、`restoreCurrentCell`、`validatePlannedGeometry`、`sameBounds`、`markGenerationFailed`、`resumeGenerationAfterDisconnect` 等旧符号，**均为零命中或仅剩同名的无关函数**（`pendingGeneration` 仅剩 Core 的 `processPendingGeneration`；`isInvalidRVData` 仅剩 Core 的同名局部函数）。
- **旧结论复核（createFurniture）**：旧报告称 `createFurniture` 依赖未定义的 `createEntityFromSprite`/`addNormalObject` 且无调用点。**当前结论：该函数及其未定义依赖已从源码中完全移除**，全树检索 `createFurniture`/`createEntityFromSprite`/`addNormalObject` 均为零命中；`createWall`、`createLight` 同样已移除。当前 WorldObjects 只有 25 个函数，对象构造入口收敛为 `createCapturedTemplateObject`（L507）与 `createGenerator`（L442）。
- **旧结论复核（RoofRefresh 组 ACK）**：**已不由本模块承担。** 旧报告的 `processRoofRefreshRelocationGroup`（约 170 行）与 `ctx.roofRefreshRelocationGroup` 在当前源码中不存在（全树零命中）。当前 RoofRefresh 模块只有 131 行，文件头明确声明"owns no transaction, retry or relocation state"（[RV_RoofRefresh.lua:1-L8](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:1)），只暴露 `Refresh.run(player, bounds)`（L124-L129）；面向玩家的入口 `RV.Server.refreshRoofVisuals` 与 readiness 上下文改由 [RV_Server_RecordValidation.lua:109-L152](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RVMapping/RV_Server_RecordValidation.lua:109) 承担，WallReload 在自己的完成回调里调用 `RoofRefresh.run`（[RV_RailroaderServer_WallReload.lua:104-L109](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua:104)）。本模块的 ACK 文件现在只有 generation 的两个 ACK 与 abort 路径。
- **文档验证**：报告包含 7 个源文件、80 个函数条目（每个含起始行、参数、返回/副作用、模块语义、加粗必要性结论）、复用/拆分判断、接口与数据访问证据。这是文档与静态结构检查，不代表 Lua 或游戏运行行为正确。
- **未覆盖项**：未运行游戏/服务器/测试脚本（本轮明确不运行 `python testserver/run_test.py`）；未审计本目录外模块的内部函数；调用搜索只用于确认本模块 API 使用面与数据边界。`RV.Server.isGenerationTransactionActive` 缺失导致的外部 gate 行为属条件性推断，需运行时或后续集成验证确认。
- **修改范围**：仅写入本分析文档；**未修改任何 Lua 源码、配置或测试文件，未运行任何测试**。
