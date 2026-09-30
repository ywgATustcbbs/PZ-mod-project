# RailroaderRV 模组代码分析：全局总结

## 假设、范围与核验方式

本总结汇总同目录下的逐模块分析报告、三份专项审计报告，并交叉核对当前模组代码目录。实际模块数按 Lua 文件夹划分为 **client 1 个、server 12 个、shared 5 个，共 18 个模块目录**；`client/RailroaderRV/` 与 `server/RailroaderRV/` 两个根目录当前已不含任何 Lua 文件（只剩 `agent.md`），不再是模块。

- **规模基线（主 agent 独立机械统计，与各模块报告逐项对齐）**：**65 个 Lua 文件 / 16,484 行 / 942 个函数定义**。
- 统计口径：行数含空行（`(Get-Content f).Count`；`Measure-Object -Line` 会跳过空行并给出偏小值，本总结不采用）；函数定义数 = 排除 `type(x) == "function"` 这类字符串比较行与「含 function 字样的整行注释」后的真实定义（Python 式伪代码：跳过 `^\s*--` 行，再匹配 `function\s*[\w:.]*\s*\(`）。
- 全树原始计数：`function` 字样 1,184 次；其中 237 次是 `"function"` 字符串比较、5 次是注释行 → 942 个定义。
- 成功标准：实际 Lua 文件全部映射到对应模块报告；列出每个模块的文件数、行数、函数定义数；回答「哪些函数具有通用性、应提取为公用功能」「是否有模块应进一步拆分」「模块之间是否存在直接访问内部数据、是否应提供接口、以及接口收益何时低于直接访问」四组问题，并给出证据与条件性影响。
- **验证边界**：本总结与全部被汇总报告均为**静态源码分析**。本轮**未运行游戏、服务器、Lua 解释器或任何测试脚本**（含 `python testserver/run_test.py`），也**未修改任何 .lua 源码、配置或测试文件**。凡「恒失败 / 必然抛错 / 静默失效」等表述均为标注了触发条件的条件性推断，需运行时或联机验收才能定论。

---

## 1. 模块索引与职责

| 层 | 模块目录 | 文件 | 行数 | 函数定义 | 主要职责 | 逐模块报告 |
|---|---|---:|---:|---:|---|---|
| Client | client/RailroaderRV/GUI | 11 | 3,278 | 269 | 菜单与上下文菜单、交互意图提交、实用设施仪表盘、Ride 适配、回执状态、边界/衣柜/拆除表现 | [client-GUI.md](client-GUI.md) |
| Server | server/RailroaderRV/BoundaryGuard | 4 | 866 | 45 | 权威 AABB 边界记录与几何缓存、玩家 guard/transition 租约、周期扫描纠正、Mapping 适配校验 | [server-BoundaryGuard.md](server-BoundaryGuard.md) |
| Server | server/RailroaderRV/Common | 5 | 823 | 53 | 受保护 Java/Lua 调用、数值与身份键、布局 bounds 展开、目标坐标校验、世界对象快照/标签/清理 | [server-Common.md](server-Common.md) |
| Server | server/RailroaderRV/Construction | 7 | 2,068 | 80 | 生成意图校验、区域分配与计划、稀疏清理与对象创建、搬运阶段、ACK、失败回滚 | [server-Construction.md](server-Construction.md) |
| Server | server/RailroaderRV/Core | 8 | 1,685 | 93 | 服务端组合根、事件/tick 总线、命令路由、ModData 仓库、utility 协议、存档 schema 版本检查 | [server-Core.md](server-Core.md) |
| Server | server/RailroaderRV/DemolitionProtection | 1 | 504 | 23 | 壳墙归属判定、玩家建造/拆除保护、异步 build correlation（BuilderActionLedger） | [server-DemolitionProtection.md](server-DemolitionProtection.md) |
| Server | server/RailroaderRV/Power | 2 | 1,026 | 64 | 虚拟燃油/电池账本、发电与负载结算、原版 generator 代理、设备扫描与快照 | [server-Power.md](server-Power.md) |
| Server | server/RailroaderRV/RoofRefresh | 1 | 131 | 10 | 模板驱动的屋顶/房间邻接重算（临时地板 + room/roof metadata recalc） | [server-RoofRefresh.md](server-RoofRefresh.md) |
| Server | server/RailroaderRV/RoomOwnership | 1 | 562 | 30 | room ownership guard 的注册/刷新/清理、客户端 stale-room 监视器布防、扫描调度 | [server-RoomOwnership.md](server-RoomOwnership.md) |
| Server | server/RailroaderRV/RVMapping | 4 | 1,871 | 99 | Railroader 适配、RV 记录与槽位分配、列车/乘员关系、进出 RV、记录与几何验证 | [server-RVMapping.md](server-RVMapping.md) |
| Server | server/RailroaderRV/TemplateRecovery | 2 | 648 | 40 | 当前模板身份与修复索引、对象安全检查与恢复、玩家采样与限速队列、转场暂停 | [server-TemplateRecovery.md](server-TemplateRecovery.md) |
| Server | server/RailroaderRV/WallReloadProtection | 2 | 819 | 38 | 外墙移除检测与触发、把权威玩家移出再放回的三阶段事务（MOVE_OUT/WAIT_RELOAD/RETURN） | [server-WallReloadProtection.md](server-WallReloadProtection.md) |
| Server | server/RailroaderRV/Water | 5 | 310 | 16 | 水槽身份/对象适配、plumbing 补偿、ledger、连接命令、门面 | [server-Water.md](server-Water.md) |
| Shared | shared/RailroaderRV/Common | 4 | 322 | 10 | 多端常量与 schema 版本、严格整数原语、utility 常量、视觉注册工具 | [shared-Common.md](shared-Common.md) |
| Shared | shared/RailroaderRV/Power | 2 | 122 | 10 | 电力参数与纯计算、电池效率曲线、配方制作回调 | [shared-Power.md](shared-Power.md) |
| Shared | shared/RailroaderRV/RoomTemplate | 4 | 1,199 | 44 | 捕获模板编译与校验、布局/几何计划、壳边 ledger、模板与世界坐标变换 | [shared-RoomTemplate.md](shared-RoomTemplate.md) |
| Shared | shared/RailroaderRV/RVMapping | 1 | 155 | 10 | 固定 RV 区域槽位、锚点与矩形之间的严格映射、空位分配 | [shared-RVMapping.md](shared-RVMapping.md) |
| Shared | shared/RailroaderRV/Water | 1 | 95 | 8 | 客户端/服务端共用的水槽身份读取与设备能力只读目录 | [shared-Water.md](shared-Water.md) |
| **合计** | **Client 1 / Server 12 / Shared 5** | **65** | **16,484** | **942** | 18 个模块报告全覆盖 | |

### 专项审计报告

| 报告 | 回答的问题 | 结论分布 |
|---|---|---|
| [audit-cross-module-access.md](audit-cross-module-access.md) | 模块之间是否直接访问彼此内部数据；是否应提供接口 | 跨包 25 条、包内 15 条；「应提供接口」4 条、「登记」4 条、其余判「接口收益低于直接访问」 |
| [audit-duplicate-helpers.md](audit-duplicate-helpers.md) | 哪些功能重复、哪些应提取为公用 | 重复组 21；「应提取」15、「暂缓」3、「不应提取」3；建议提取项 E1–E12 |
| [audit-module-split.md](audit-module-split.md) | 是否有模块应进一步拆分或合并 | 「建议拆分」3、「暂缓」3、「不建议拆分」11、「不建议合并」7（全部合并候选否决） |

### 分层责任关系

| 层 | 责任边界 | 主要输入与输出 |
|---|---|---|
| Shared | 定义当前 schema、常量、几何/模板数据与纯计算，供两端消费；**不得 require server 路径** | 常量、schema 版本、已验证布局/模板、槽位映射、Power 公式、Water 身份查询 |
| Client | 展示可用操作、提交用户意图、消费 ACK/snapshot；本地筛选与视觉隐藏只服务表现 | 读取 Shared 合同；经 `sendClientCommand` 发意图；显示服务端回执 |
| Server | 以服务端玩家身份、当前 mapping、权限、请求阶段与 schema 为唯一依据执行世界/持久化变更与失败恢复 | 接收不可信意图；由 Core 组合根装配 Core/Common/Construction/RVMapping/BoundaryGuard/RoofRefresh/RoomOwnership/DemolitionProtection/TemplateRecovery/WallReloadProtection/Power/Water |

主数据流：Shared 提供合同 → Client 形成并发送意图 → Server 校验身份/范围/阶段 → Server 执行并同步 → Client 展示回执。客户端提交的坐标、槽位或 UI 状态不是授权依据；静态分析未把客户端检查当作服务端验证。

### 本轮结构现状（相对上一版总结的变化）

上一版总结描述的是**精简前**结构（72 文件 / 1,341 函数表达式 / 18 模块目录，且假设存在根目录转发入口）。当前实际状态：

- 文件 72 → **65**，函数表达式 1,341 → **942**；
- `Core/RV_DevSaveSchemaGate.lua`（旧 1,644 行）与 `Core/RV_Server_ManifestValidation.lua` **已删除**，全树对 `DevSaveSchemaGate`/`schemaGate`/`requireCurrentManifest` 零命中；存活的 schema 符号只有 `Core/RV_RailroaderServer.lua:42-79` 的 `checkSaveSchemaVersion` 与 `RV_Constants.lua:54` 的 `SAVE_SCHEMA_VERSION = 9`；
- `client/RailroaderRV/` 与 `server/RailroaderRV/` 根目录的**扁平转发入口 .lua 全部删除**，两目录现只有 `agent.md`；全树 63 处 `"RailroaderRV/…"` 模块路径**全部是三段式**，不存在旧根路径 require；
- `RoofRefresh/` 由 7 文件 4,331 行合并为 **1 文件 131 行**；`TemplateRecovery/` 由多文件合并为 **2 文件 648 行**；`shared/RoomTemplate/RV_ProtectionManifest.lua`、`shared/Common/RV_Bitmap.lua` 已删除；
- 屋顶/房间**分组搬运、ACK 与阶段推进的 owner 现在是 WallReloadProtection**（不是 RoofRefresh，也不是 Construction/Core）；RoofRefresh 退化为纯重算模块。

---

## 2. 对比模块之间的功能：哪些函数具有通用性、应提取为公用

三份审计的交叉结论是：重复集中在**引擎边界适配层**（受保护调用、ModData 读取、玩家/世界快照、数值转换），而各模块的**判定策略**（role 集合、templateIndex 交叉校验、失败是 error 还是布尔、持久化键格式）差异真实且必要，不应被「统一」掉。

### 2.1 已合适地集中的公共功能（无需再抽）

`shared/RoomTemplate` 的布局/几何计划与模板编译、`shared/RVMapping` 的槽位映射、`shared/Power` 的电池参数与效率公式、`server/Common` 的 `invoke/classInstance/toNumber/integer/identityKey` 与 `ServerWorld` 的快照/标签、`Power` 与 `Devices` 的显式接口、客户端 `UtilityClient`/`Dashboard` 的命名 API。几何侧的正面例子是 `TemplateGeometry.edgeKey/edgeForSide`（全树单一实现）。

`RV_StrictSchema.integer` 的复用面已确认：仅 `shared/Water/RV_UtilityCatalog.lua:13` 与 `shared/RVMapping/RV_RegionSlots.lua:21` 两个消费者。

### 2.2 建议提取的公用功能（按收益排序）

| 优先级 | 候选 | 现状与证据 | 建议归属与收益 |
|---|---|---|---|
| 高 | **受保护引擎调用层**（`invoke`/`call`/`callGlobal`/`callSucceeded`/`classInstance`） | 形状有 **9 份实现（1 规范 + 8 重复）承载 103 个调用点**；`callGlobal` 3 份、`callSucceeded` 2 份、`instanceof` 4 种写法。差异是契约性的：只有 `server/Common/RV_Common.lua:9` 用 `pcall` 保护**属性读取**，`shared/Water/RV_UtilityCatalog.lua:67`、`shared/Common/RV_UtilitySprite.lua:15`、`BoundaryGuard/RV_BoundaryServer_Geometry.lua:39` 与 4 个 client 文件直接 `target[method]` 索引；返回元数 1/2/4 不一 | 只能归属 `shared/`（client+server+shared 三方消费）。统一后所有调用点写法可保持不变。E1 |
| 高 | **`data.RailroaderRVTest` 读取 + owner 校验** | 读取被复制 **14 次 + 2 处写入**；`RV_ServerWorld.lua:167` 与 `RV_BoundaryServer_Objects.lua:18` 是同义的两个 `objectModData`，且 `RV_UtilityCatalog.lua:21/46`、`RV_UtilityWater_Plumbing.lua:13/26` 各自在**同一文件内重复两次** | 只统一「读命名空间 + `owner == MOD_ID`」到 shared；**role/templateIndex/generation 谓词必须留在本地**，否则会把 6 种业务契约压成一个。E2 |
| 高 | **稳定玩家身份三元组** `{username, onlineId, key}` | **5 套独立构建**（`Geometry.lua:55-79`、`Train.lua:48-68`、`PlayerValidation.lua:103-118`、`BoundaryValidation.lua:186-191`、`UtilityServer.lua:22-30`），`key = tostring(onlineId)..":"..name` 另在 6 处手工拼接 | 稳定玩家身份是最基础契约，5 份实现会让「同名不同 ID」「同 ID 改名」在各模块表现不一致。E3（开放点：`Train.lua:51` 接受 `onlineId<0` 而 `Geometry.lua:65` 拒绝） |
| 中 | **`onlinePlayersSnapshot`** | 3 份实现 = **同一事实的 3 种语义**：`Sweep.lua:23` 返 1 值、`Sentinel.lua:79` 返 1 值（去重 + `getPlayer` 兜底）、`RoomOwnership.lua:147` 返 `(list, ok)`；直接造成失败策略不同（静默 / `error`（`:235`、`:273`）/ 兜底） | 合并**必须保留完整性标志**，否则 `RoomOwnership` 的 fail-closed 会退化为静默。E4 |
| 中 | **数值家族收敛** | 12 个私有变体 vs `C.finiteNumber/finiteInteger`、`StrictSchema.integer`、`Common.toNumber/isFiniteNumber/integer`。其中 `WorldObjects.integer:10-18` 与 `TemplateProtectionRepair.integer:20-28` **逐字节同义**；`UtilityStore.waterInteger:36-40` ≡ `C.finiteInteger`；`BoundaryServer_Geometry` 的 3 个变体可由 `toNumber`+`C.finiteNumber` 组合得到 | 可无歧义迁移 6 个。「原生严格 vs 强制转换」两轴**必须保留两个具名函数**，不可合成一个。唯一「统一即收紧」点是 `UtilityStore.integer:9-11`（因 `math.floor(math.huge)==math.huge` 而接受 `math.huge`） |
| 中 | **`getObjectIndex` + 整数化** | 「一个 Java 事实、9 种取值方式」（7 文件 9 处），`<0` 判定在内联处极易漏写；`UtilityPowerDevices.objectIndex:172-175` 已是正确形态，可作原型 | 提取（不含各自的附加策略） |
| 低 | **`OWNER`/`MOD_ID` 字面量** | 3 处硬编码（`RV_ServerWorld.lua:8`、`Core/RV_Server.lua:7`、`:8`），而 `C.MOD_ID` 已定义且被 10 处引用 | 零风险；namespace 比较一旦漂移即**静默失配** |
| 低 | **坐标三元组键（仅进程内用途）** | 8 处同一用途同一格式，另 1 处 `TemplateProtectionRepair.lua:30-32` 用**逗号**分隔 | 提取进程内比较用途可消除「同点不同键」隐患；**持久化键必须排除**（见 2.3） |
| 低 | **`StrictSchema.exactKeys` 归属缺口** | `shared/Common/RV_StrictSchema.lua` 现为 **13 行、只导出 `integer`（L4-L11），没有 exactKeys**；全树唯一 `exactKeys` 是 `server/Water/RV_UtilityWater_Objects.lua:13-23` 的本地实现，仅 `:60` 用一次，不做 metatable 检查 | 纯函数、无 server 依赖，归属 shared 才符合该文件既有职责；但只有 1 个消费者，**净收益≈0**，列为可选 |

### 2.3 判定为「不应提取」的项及原因

| 项 | 原因（语义差异证据） |
|---|---|
| `Common.identityKey` vs 玩家 `"id:name"` 键 | 格式完全不同（长度前缀 `3:abc\|1:5` vs `5:abc`）、nil 语义不同（前者任一 nil 即 nil，后者用占位符）、消费者不同（RV 身份缓存 vs 玩家身份）。统一会改变 RV 缓存键并吞掉 nil 语义 |
| `RV_UtilityStore.waterSinkKey` | 是**已持久化的 ModData 子键**（`string.format("%d:%d:%d")`），产物进入 `water.sinks` 并随 record 提交；统一会改变存档键格式 |
| `C.finiteInteger/finiteNumber` vs `StrictSchema.integer` | 接受域**刻意不同**：前者宽松（接受数字字符串/Java numeric wrapper），后者只接受原生 number。`phase2` 报告明确要求不得统一 |
| 4 个 `local function safeErrorText(...) return ctx.safeErrorText(...) end` | 是有意的 ctx 注入别名（延迟查 `ctx`，因此不受 require 顺序影响），不是重复实现 |
| 各模块的 modData tag 谓词 | role 集合、templateIndex 交叉校验、owner 比较对象各不相同（server 树 6 处读取习惯语各有不同的「门」） |
| `Power`/`Devices` 的单行 `invoke` 别名、`Geometry.lua:38` 的 `call` | 命名动词别名，底层直接是既有实现，无独立策略 |

**暂缓项**：Java 集合枚举（`collectionSnapshot` 家族，需先落 E1）；`ServerSchema:123-126` 的内联 `safeErrorText` 回退；客户端 `localPlayerByOnlineId`（需先定「单机该不该兜底」策略，**不得**为统一而给 `RoomOwnership` 加兜底）。

---

## 3. 是否有模块应该进一步拆分

**结论：只有 3 项建议拆分，且都不是上一版总结列为首要候选的文件。** 本轮精简把多个已拆分的模块合并回单文件（RoofRefresh 7→1、TemplateRecovery 多文件→2、删除 SchemaGate/ManifestValidation、删除根目录转发），因此**基调是不要为行数拆分，也不要把刚合并的结构再拆回去**。

| 优先级 | 候选 | 可分出的责任 | 前置条件与代价 | 净收益 |
|---|---|---|---|---|
| 高 | `RVMapping/RV_RailroaderServer_EntryExit.lua:424-596`（720 行 / 20 函数）——**本审计新提出，此前所有报告均漏掉** | 生成提交/失败恢复簇（`commitGeneration`、`restoreAfterGenerationFailure`、`validateGeneration`） | 这 3 个函数**已发布在 ctx 上**（`:716-718`，被 `Core/RV_RailroaderServer_Tick.lua:13-15` 消费）→ 抽出**零新增公开接口**；需随簇迁移 `markPlayerInside`（`:211`，唯一调用点 `:524` 在簇内），并提升 `movePlayer`（`:148`）1 个 helper。该簇独占耦合生成生命周期（`:527-533` 调 ledger、`:534-535` 初始化 utility record），与进入/退出簇变更来源不同 | 高：文件是全树第 2 大；边界清楚、接口面不增 |
| 中 | `DemolitionProtection/RV_BoundaryServer_Objects.lua:335-411`（504 行 / 23 函数）——低成本候选 | `BuilderActionLedger`（约 77 行，6 个方法） | 仅 2 个外部消费者且都只调单个方法；需注入 `actionMatchesObject`/`boundaryForPlayer`/`inManagedRegion`/tick 四个依赖 | 中：触发条件是 ledger 方法增至约 10 个、出现第 3 个消费者，或需要持久化 action |
| 中 | `WallReloadProtection/RV_RailroaderServer_WallReload.lua:37-44` + `:284-309`（311 行 / 14 函数） | 「客户端 stale-room 监视器周期重挂」（`armRoomOwnership` + `rearmRoomOwnershipMonitors` + 常量） | 唯一调用点是 `Core/RV_RailroaderServer_Tick.lua:65-67`；依赖为 `Core.getTick`、`Boundary.boundaryForPlayer`、`Adapter.onlinePlayersSnapshot` | 中：本目录唯一「独立 upvalue 状态（`nextMonitorRearmTick`）+ 独立职责 + 单一调用点」三者齐备的缝，**零行为变化**；与 `server-WallReloadProtection.md` 的独立结论一致 |

**暂缓 3 项**（各有明确触发条件）：

- `Construction/RV_Server_WorldObjects.lua`（816 行，上一版总结的首要候选）：该文件**零模块级可变状态**，22 个函数全是纯函数，唯一跨簇共享原语是 `addSpecialObject`（`:418`）。拆它只买到「可独立审阅 137 行回滚路径」，代价是 2 个 require + 1 个 ctx 导出 + 把 5 处写入顺序不变量（`:262-265`/`:436-438`/`:487-489`/`:545-553`/`:573-575`）与调用点分到不同文件。
- `Construction/RV_Server_GenerationFlow.lua`（471 行）：拆分前置条件比 `server-Construction.md` 所述更窄——`record.stage =` 的写点只有 **4 处 / 2 文件**（Flow `:124`/`:133`/`:320` + `GenerationTransaction:21`），Ack/PlayerValidation/Commands 的相关行**全部只读**。应先收敛 Flow 的 3 处写点。
- `client/GUI/RV_UtilityDashboard.lua:54-113`：触发条件是支持充电器/逆变器之外的第三类设备。

**不建议拆分 11 项**：`Power/RV_UtilityPower.lua`（`commit`/`bump` 是「先改库存再改账本、失败即补偿」顺序的载体，拆出任一簇都会把唯一补偿顺序变成跨文件协议）、`RVMapping/RV_RailroaderServer_Train.lua`（向 ctx 发布 28 个 helper，是 RVMapping 层的**共享低层库**，其价值正是把外部实现依赖关在 1 个文件内）、`Common/RV_ServerWorld.lua`（四段共享同一条 `clearSquare → removeObject → removeGenericObject → restoreTaggedFloor → clearGenerationTag → recalcSquare` 事务链）、`BoundaryGuard/RV_BoundaryServer_Geometry.lua`（A 簇 10 个 helper 已发布到 ctx，拆开只是再转一手；真正的收益在**去重而非拆文件**）、`TemplateRecovery/`（**明确反对把刚合并的结构再拆回去**）、`WallReloadProtection` 服务层、`RoomOwnership`、`client/RailroaderContextMenu.lua`（4 个状态字段挂在公开表上且被多处共同持有）、`server/RVMapping/RV_RailroaderServer_Mapping.lua`（旧报告建议的 `:263-451` 已超出当前 312 行）。

**不建议合并任何模块**（7 个合并候选全部否决）。代表性理由：`server/Water/RV_UtilityWater.lua`（11 行）是 Water 唯一公开名且其返回值形状是跨端合同；`shared/Common/RV_StrictSchema.lua`（13 行）与 `RV_Constants.finiteInteger` 接受域刻意不同，**物理分文件是对「不要统一」这一决定最廉价的强制**；`RV_ServerTeleport.lua`（44 行）是服务端权威传送原语，并入通用层会削弱「哪些操作是权威世界变更」的可读边界。

---

## 4. 模块之间是否存在直接访问其他模块内部数据的情况

**整体判断**：耦合不是系统性失控。全树 25 条跨包访问 + 15 条包内互访中，只有 **4 条判为「应提供接口」**、4 条「登记」，其余均判「接口收益低于直接访问」。共享命名空间上的写入点大多有身份门与单一所有者；风险集中在**接口缺口**与**一处记录字段误用**两类，而不是「模块互相翻私有表」。

### 4.1 应提供接口的 4 项

| # | 现状（证据） | 建议接口与理由 |
|---|---|---|
| 1 | `BoundaryGuard/RV_RailroaderServer_BoundaryValidation.lua:67-73` 直读 `Boundary._states[identityKey]` 的 `leaseToken/leaseUntil` + `_tick` | `Boundary.transitionActive(identityKey)`。**不能改用 `ctx.stateFor`**，因为后者有**创建副作用**（`Geometry.lua:271-282` 会写入 `_states` 条目）——这正是「接口收益低于直接访问」的典型证据，但该只读语义值得一个正式名称。失效方向是 fail-open（4 个静默失效面） |
| 2 | `DemolitionProtection/RV_BoundaryServer_Objects.lua:411` 把整个 ledger 表挂到 `Boundary.builderActionLedger`，产生 3 处字段形状依赖 | `Boundary.pruneBuilderActions(tick)` + `Boundary.invalidateBuilderActionsForGeneration(rvId, generation)`。其中 `RVMapping/RV_RailroaderServer_EntryExit.lua:527-533` 是 **fail-closed**：字段或方法缺失即拒绝 generation 的 mapping 提交，字段改名会让 generation 无法提交映射。**必须保留 fail-closed 语义，不得放宽** |
| 3 | `Power/RV_UtilityPowerDevices.lua:235` 读 `record.anchor`——**该字段不存在**：持久 mapping 记录只含 `generated/locoId/generation/slotIndex/rvPosition/locoPosition/players`（`EntryExit.lua:507-513`），全树对 `anchor` 的写入**零命中** | 改为由 slotIndex 派生：`RegionSlots.indexToAnchor(integer(record.slotIndex))`（同仓正确写法见 `Water/RV_UtilityWater_Objects.lua:35-39`）。**注意 `scanAll` 的失败串同时是客户端 ACK 的失败原因**（`RV_UtilityServer.lua:229-232`），接口调整须保持返回值形状 |
| 4 | 客户端 GUI 包内此前的互相读写**已收敛**：`roomOwnershipGuards` 现为 `RV_ContextMenu_RoomOwnership.lua:5` 的文件局部表，`pendingFinalRelocation` 为 `RV_ContextMenu_Relocation.lua:22` 的局部变量，二者经 ctx 导出的函数协作 | 已是正例。当前仅剩 `ctx.clientTick` 一个跨文件可变标量（`Relocation.lua:328` 写、`RoomOwnership.lua:189/273` 读），判「收益低」 |

### 4.2 明确判定「接口收益明显低于直接访问」的项及原因

- **`mapData()` 返回的 ModData 持久映射活表**（12 个调用点跨 4 个包）：该表**就是存档 schema 合同本身**，调用方必须就地改写（`Tick.lua:54-58` 持久化位置）或整表原子交换提交（`EntryExit.lua:541-543`）；任何 getter 都只能再交出同一张表 → 收益低于直接访问。读侧已有 `validMappingRecord` 统一门（`Mapping.lua:126-132`）。
- **`boundary.managed` / `shellEdges` / `bounds.*` / `anchor` 等派生几何视图**：由 slotIndex + 编译模板**纯函数派生**，公开性由 `RV_Server_RecordValidation.lua:29-34` 明文声明；表即数据合同。加 getter 不隐藏可变性，也不消除 schema 合同。
- **`record.power` / `record.water` / Store 快照子表**：`RV_UtilityStore` 定义记录形状，Power 与 Water 各自**独占一半**（Power 只写 `record.power`，Water 只写 `record.water`）；快照类读取是深拷贝 value 对象（`RV_UtilityStore.lua:147-161`）。
- **`ctx.pendingSerial` / `ctx.transitionSequence`**：各自唯一读写点都在单一文件内；Core 侧同名本地变量在 ctx 构造后即死值。自增语义要求写回，**getter/setter 不隐藏可变性**；真正的收敛是所有权移动（改为使用方文件局部），不属于接口。
- **`Adapter._ticks`**：读取处已自带回退 `Adapter._ticks or Core.getTick()`（`BoundaryValidation.lua:74`），而 `Core.getTick()` 就是等价接口，再加一层是重复。
- **`ctx.serverTick`**：接口（`Core.getTick()`）已存在且同值（Core 先自增再 dispatch）；字段缺失会立即 `nil + 1` 报错，不会静默错值。
- **`Boundary._tick`（DemolitionProtection 4 处只读）**：值恒等于 `Core.getTick()`。**本轮最优解不是加接口而是直接改用 `Core.getTick()`**——该文件已捕获未使用的 `ctx.Core`（`:4`），可**零新增接口**消除这 4 处私有读取。
- **`data.canBeWaterPiped`（vanilla 协议字段）**：vanilla 侧也读写它，无 Lua API 可包装；本地 façade 只会把同一字段假设搬到另一个文件。
- **客户端对 Railroader 官方表的直读直写**（`_boardPending`、`RR.BoardMenu.addForAnimal`、`AnimalContextMenu.doMenu`、`RR.TrainEntity.active`）：官方只暴露函数槽与内部记录表，没有 seat/stale-gate/record-lookup/菜单注册 API；再包一层只是把字段假设移位，且这些访问**已集中在单一 adapter 文件**。
- **`ctx.roomOwnershipGuards`**：全树唯一消费者（仅 `RV_Server.lua:88/131` 与 `RV_Server_RoomOwnership.lua:12/345/350`）；表由 Core 创建但语义完全属 RoomOwnership。**登记**：所有权应收敛到 RoomOwnership 局部（是所有权移动，不是接口）。
- **`GenerationTransaction.current()` 返回的共享记录字段**：该记录被 `GenerationTransaction.lua:1-7` **明文定义为「调用方直接写字段、`record.stage` 是唯一阶段权威、没有 snapshot/whitelist/stage API」**；加二级 getter 只是再包一层，且会改变既有以 `error` 表达阶段违约的失败语义，与本仓「让错误按正常游戏异常抛出」的约定冲突。
- **`ctx` 组合对象本身**：模块写入的都是**自己的导出函数**（这就是本仓的模块装配协议），不是读取他人私有状态。

### 4.3 外部 Railroader 适配边界

`server/RVMapping/RV_RailroaderServer_Train.lua` 是外部实现形状依赖的**唯一集中点**（唯一例外：`EntryExit.lua:247-249` 读 `RR.Ride.MOUNT_REACH`）。它读取 `RR.ServerTrain.active`、`RR.TrainEntity.active`、`RR.Ride.*`、`RR.Body.*` 以及 train 记录上的 driver/passengers/rider/seat/pose 与多个下划线私有字段（`_seatNames`/`_claims`/`_cmdSeq`/`_stopping`/`_startEnv` 等）。**本仓不含 Railroader 官方源码，因此不能据此断定这些字段是否官方公开或会否变化**；模组内其他模块应继续通过 Adapter 的具名服务接入，而不要重复读取这些字段。

### 4.4 与「模块按既定接口直接协作」约定的关系

上述「应提供接口」的 4 项全部是**收敛字段形状依赖**（把行为放到所有者一侧），不新增跨模块校验、不改变现有校验强度、不引入兼容或回退分支；反问方向（加 getter 不能隐藏可变性 / 调用点唯一 / 本就是公开数据合同）一律判「收益低于直接访问」。这与 `server/RailroaderRV/agent.md:7` 的约定一致。

---

## 5. 静态问题与验证边界

以下是静态扫描可直接确认的**源码事实**，第二列只写可由调用路径推出的条件性影响；没有把它们当成 runtime 复现结果。前 5 条互相独立、由不同 worker 分别发现并交叉验证。

| # | 项目 | 可证静态事实 | 条件性影响与未验证点 |
|---|---|---|---|
| 1 | `RV.Server.isGenerationTransactionActive` **无生产者** | 全树 7 处命中**全部是读取/类型探测**（`Sentinel.lua:153/157/201`、`UtilityServer.lua:73/74`、`WallReloadProtection.lua:456/460`），不存在任何声明或赋值。姊妹查询 `isWallReloadTransactionActive` 有完整发布链（`RV_RailroaderServer_WallReload.lua:246-258` 定义、`:265-271` 发布）。真实状态在 `GenerationTransaction.isActive`（`:37-39`），经 `ctx.GenerationTransaction`（`RV_Server.lua:122`）注入，但**未转发到 facade** | 触发条件＝运行时确无外部提供。**注意两侧失败方向相反**：`Sentinel.lua:153` 是 `~= "function"` 判定 → `serverTransactionMutexStatus` 恒 nil → `wallReloadTransactionBlocks` 恒 true、`installTransactionGate` 恒 false；而 `UtilityServer.lua:73` 是 `== "function"` 判定 → **fail-open** 跳过 generation 一半的 busy 检查。同一缺失在两条路径上导致相反口径，**不应通过放宽任一侧来消除差异**。另有 `BoundaryValidation` 的 `transactionStateValid` 恒 false → 守卫不纠正玩家 |
| 2 | Power 读**不存在的** `record.anchor` | `RV_UtilityPowerDevices.lua:235`（`interior`，定义 `:234`）读 `record.anchor`；两个调用点传入的都是持久 mapping 记录（`RV_UtilityServer.lua:227` 传 `context.record`、`:314` 传 `currentUtilityRecord`），而记录只写 `generated/locoId/generation/slotIndex/rvPosition/locoPosition`（`EntryExit.lua:507-513`）。同仓正确写法在 `Water/RV_UtilityWater_Objects.lua:35-39`（用 `RegionSlots.indexToAnchor`） | 推断：`interior` 返 nil → `scanAll`/`scanTick` 恒失败；该失败串会被当作客户端 ACK 原因下发（`RV_UtilityServer.lua:229-232`）。**`scanTick` 的返回值无人消费**（`:314` 忽略），因此缺陷只在 `OP_REFRESH_DEVICES` 路径可见。未运行时验证 |
| 3 | `ctx.playerPositionInRegion` 在**主 ctx 上缺失** | 该函数在 `RVMapping/RV_RailroaderServer_Mapping.lua:67` 定义，并在 `:155` 注入 **BoundaryValidation 的子 ctx**；但主 ctx（`Core/RV_Server.lua:105-136`）**不含该键**，而 `WallReloadProtection/RV_RailroaderServer_WallReload.lua:30`（调用 `:74`）与 `Core/RV_RailroaderServer_Tick.lua:12`（调用 `:33`）都从自己收到的 ctx 取值 | 推断：这两处捕获到 nil，调用点会以 nil 调用抛错。`BoundaryValidation.lua:8` 因走子 ctx 而正常。未运行时验证 |
| 4 | `Core.onCommand` 的 `"*"` **不通配** | `Core/RV_Server_Core.lua:85-90` 是精确比较 `if received ~= command then return end`，无通配分支（`:82-84` 注释却称 catch-all）；`RV_Server_Commands.lua:386` 用 `"*"` 注册 `RV.Server.OnClientCommand`（该 handler 负责 module 过滤、`FinalRelocate`/`RelocateAck`、utility 操作与 generation 推进） | 推断：`RV.Server.OnClientCommand` 不会被调度。**不是全体命令失效**：`Adapter.OnClientCommand` 在 `Sentinel.lua:206-207` 以精确名 `COMMAND_RV_ENTER`/`COMMAND_RV_EXIT` 注册，仍可调度；`Core.onTick` 与 4 个对象事件注册不受影响。未运行时验证 |
| 5 | 子 ctx 的**值捕获在生产者之前** | `Mapping.lua:158` 把 `serverTransactionMutexStatus` 作为**裸全局**（无 local、无 `ctx.` 前缀）传入 BoundaryValidation，而写裸全局的位置**全树不存在**（仅 8 处命中，Sentinel `:190` 写的是 `ctx.` 字段、`:150` 写的是 `Adapter.` 字段）；且装配顺序为 Mapping(`RV_RailroaderServer.lua:113`) 早于 Sentinel(`:116`) | 推断：`BoundaryValidation.lua:11` 得到 nil，`:64`/`:195` 无保护调用会抛错；`:195` 链路（`Tick.lua:37`）无 pcall 包裹。旧报告称 Mapping 曾有同名转发函数（L19），现已删除——属回归。未运行时验证 |
| 6 | `RegionSlots.indexToRegion` 只产出 XY | `shared/RVMapping/RV_RegionSlots.lua:47-56`（`boundsForSlot`）只返回 minX/minY/maxX/maxY，`:109-113` 直接返回它；而 `Mapping.lua:95-100`（`inRegion`）要求 `region.minZ`/`region.maxZ` 为 number，否则 `return false`。两个调用点（`Mapping.lua:122-124`、`WallReload.lua:69`）都喂 XY-only region | 推断：`recordAtPlayerCoordinate` 恒「unmapped-rv」→ `exitPlayer` 恒 `INVALID_RV_DATA`；`resolveCurrentUtilityRV` 恒 false（utility/水/电命令被拒）；`enterPlayer` 把「已在内」判为 INVALID_RV_DATA；WallReload 成员捕获恒为空。对照客户端 `RV_UtilityContextMenu.lua:76-85`「region 取 XY + anchor.z 另算 Z」，说明 XY-only 是设计形状、消费侧假设不符。未运行时验证 |
| 7 | `allocateRVRegion` 返回值位置错位 | `Mapping.lua:280` 返回 `(true, slotIndex, anchor, regionForAnchor(anchor))`、`:256-257` 返回 `(true, slotIndex, anchor, indexToRegion(slotIndex), integer(existing.generation))`——第 4 位是 region、第 5 位才是 generation；唯一消费方 `GenerationFlow.lua:354` 绑定 `local allocated, selectedSlot, anchor, priorGeneration`，第 5 位被丢弃，`:366` 据 `priorGeneration ~= nil` 拒绝 | 推断：成功路径上 `priorGeneration` 恒为 region 表（非 nil）→ `queueGeneration` 恒拒绝 → 首次 RV 生成无法完成。`GenerationFlow.lua:352-353` 注释与变量名表明第 4 位本意是 region。未运行时验证 |
| 8 | Water 恒真表达式仍在 | `RV_UtilityWater_Plumbing.lua:51` 的 `desiredConnected and false or true` 恒为 true（`desiredConnected` 已在 `:46` 限定为 boolean），因此 `applyState` 总写 `canBeWaterPiped = true` 并用同一期望值核验（永不失败） | 模组自身服务端/客户端菜单不受影响；vanilla plumb 菜单条件会读该标记，可能仍给出原生接水管选项。建议修法 `not desiredConnected`（本轮未改码）。未运行时验证 |
| 9 | Water 水槽移除链**已被整体删除** | 大小写不敏感检索 `onObjectRemoved`/`pendingRemoval`/`runtimeFaults`/`REMOVAL_CONFIRM` 全树 **0 命中**；`OnObjectAboutToBeRemoved` 的服务端注册只有 `Core/RV_RailroaderServer_Tick.lua:101-102`（接到 WallReloadProtection），与 Water 无关 | 推断：水槽被拆/移动后 ledger 条目**无清理路径**，会遗留在存档并被客户端面板计入统计。旧报告「onObjectRemoved 未接线」的表述应更新为「整条链已删除」。未运行时验证 |
| 10 | `shared/Common/RV_StrictSchema.lua` 的**能力与文档不符** | 该文件 **13 行、只导出 `M.integer`（L4-L11），没有 `exactKeys`**；消费者仅 `shared/Water/RV_UtilityCatalog.lua:13` 与 `shared/RVMapping/RV_RegionSlots.lua:21`。全树唯一 `exactKeys` 是 `server/Water/RV_UtilityWater_Objects.lua:13-23` 的本地实现（仅 `:60` 用一次，不做 metatable 检查）。`phase2-structure-optimization.md` 中「StrictSchema 提供 integer+exactKeys 并被 Water Objects 复用」的说法与当前源码不符 | 属**归属缺口**而非复用；搬回 shared 净收益≈0（1 个消费者）。`phase2` 报告是历史记录，其 helper 审计表对该文件的描述已失效 |
| 11 | 设备扫描死导出与死参数 | `RV_UtilityPowerDevices.clear`（`:359`）全树无调用点；`GenerationFlow.lua:223-225` 向只有 2 个形参的 `refreshServerRoomOwnershipGuard`（`RoomOwnership.lua:354`）传 3 个实参（第 3 个 `true` 被 Lua 静默忽略）；`RV.Server.Construction`（`GenerationBuild.lua:176`）全树**零读者**（同对象另有被使用的 `ctx.constructionService`）；`Boundary.beginTransition` 的 `kind` 与 `Boundary.onTick` 的 `tick` 为死参数；`RecoveryQueue.onPostPlayerTick` 的 `tick`/`activeBoundaries` 形参从未被读取 | 均为静态事实；删除死参数属可选清理，本轮未改码。除此之外，`shared-Power` 与 `shared-Common` 的导出、`server-Common` 的 12 个 ServerUtil 导出**全部有真实调用点** |
| 12 | 测试脚本不是当前接口基线 | `tests/test_rv_server.py:1891` 要求源码存在 `function RV.Server.isGenerationTransactionActive`（当前不存在）；`:1892` 要求已移除的 `isRoofRefreshTransactionActive`；`:1041` 断言 Sweep 必须保留 `Boundary._states[id.key]`（静态锁定内部访问）；`:1386` 断言 `if old then old._boardPending` 不存在，而当前 `RV_RailroaderContextMenu.lua:367` 正是该写法 | 静态事实：该测试与当前源码多处不一致，不能作为契约基线；本轮**未运行**它 |

### 未覆盖与未验证

- 未逐行通读全部 65 个文件（约 16,484 行）；`shared/RoomTemplate` 的 3 个大文件与部分客户端文件只读了代表区段，`Power/RV_UtilityPower.lua` 等为关键区段。
- 未审计 Railroader 官方模组源码（本工作目录不存在 `official lua scripts/` 或 `reference mods/`），因此外部字段依赖只依据本仓调用形状与注释；也未与 `game-decompiled/` 交叉验证 `getOnlineID`/`getPlayerNum`/`getObjectIndex`/`instanceof` 的 Java 侧签名。
- `modinfos.json`、`reference mods/`、`official lua scripts/` 均未纳入本轮范围。
- **未运行任何运行时验证**：没有启动游戏或服务器，没有运行 `python testserver/run_test.py`，没有执行 `tests/`。第 5 章全部「恒失败/抛错/静默」结论都是标注了触发条件的条件性推断。
- 全部 23 个 worker 事务均声明其唯一写入为 `docs/module-analysis/` 下的报告；`git status --porcelain -- '*.lua'` 为空，可确认**本轮没有修改任何 .lua 源码、配置或测试文件**。

---

## 6. 文档勘误与遗留不一致

本轮修订中已发现并处理的报告缺陷（均已修正，记录在此以便复核）：

| 报告 | 缺陷 | 处置 |
|---|---|---|
| `server-Common.md` | 正文两处称本目录 5 个文件「合计 762 行」，逐文件数字正确但求和错误（实为 823） | 已改为 823 |
| `shared-Power.md` | 总计行写 6 个函数（实为 10：Config 4 + Items 6），且 Config 构成描述与定义行号有误（`L8`→`L6`） | 已改为 10 并修正构成 |
| `server-Construction.md` | 称 Ack/PlayerValidation/Core 也写 `record.stage`；实测写点只有 4 处 / 2 文件，其余只读 | 已改为「仅 Flow 与 GenerationTransaction 写 stage」 |
| `server-TemplateRecovery.md` | 整体过期：描述已不存在的 1,729 行单文件并据此「建议拆分」 | 已整体重写为当前 2 文件 / 648 行 / 40 函数，拆分结论改为「不建议」 |
| `server-RVMapping.md` | 整体过期（行数 620/811/333 与实际 312/720/216 不符，函数 113→99，引用超出文件长度的行号区间） | 已整体重写 |
| `server-DemolitionProtection.md` | 过期（称 25 函数 / 约 665 行、`Boundary._builders`、footprint/auditObject 等） | 已整体重写为 23 函数 / 504 行 |

**主 agent 自身基线勘误**：本总结初稿曾把全树函数定义数算作 947，原因是把 **5 行含 function 字样的注释**（`RV_BoundaryServer_Geometry.lua:205`、`RV_Server_RecordValidation.lua:30`、`RV_WallReloadProtection.lua:61`、`RV_UtilityWater_Ledger.lua:10`、`RV_Layout.lua:3`）计入了定义。改正后全树为 **942**（client 269 / server 591 / shared 82）。据此，`server-BoundaryGuard.md`（45）与 `server-Water.md`（16）**原本就是正确的**，无需改动——即报告族一直使用「定义口径」，只有汇总公式混入了注释。

`audit-cross-module-access.md` 的检索面描述有一处内部不一致：正文先写「65 个 Lua 文件（client 11 / server 47 / shared 11 + 2 个 agent.md）」，其分层数字与实测（server 42 / shared 12）不符且合计为 70；**该报告的清单与行号证据不受影响**，仅此句分层描述需按 42/12 读取。

### 明确的遗留不一致（超出本轮授权范围，未修改）

以下文件不在 `docs/module-analysis/` 内，本轮未改动，但它们与当前源码/结构不符，建议后续单独处理：

1. `README.md:122` 仍称「迁移中保留的顶层 Lua 文件只转发到模块入口」——实际这些转发文件已全部删除；`:120` 的模块列表也未包含 `RoofRefresh`、`RoomOwnership`、`WallReloadProtection`。
2. `REFACTOR_DESIGN.md:47` 同样称保留顶层转发入口；`:27,69` 引用已删除的 `RV_ProtectionManifest.lua`、`RV_Server_RoomOwnership.lua`（旧路径）、`RV_Bitmap.lua`；其 RoofRefresh/Power 接口清单描述的是合并前结构。
3. `contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/agent.md:3` 仍称「The flat client Lua files retained beside it are forwarding entry points」——该目录当前扁平 `.lua` 数为 0。
4. `docs/module-analysis/phase2-structure-optimization.md` 是**历史记录**（描述合并前结构），其 helper 审计表对 `RV_StrictSchema`（exactKeys）与多处文件的描述已失效；本总结引用的当前事实一律以各模块报告为准。

---

## 7. 最终结论

当前结构按 **shared 合同 → client 意图/UI → server 验证与权威事务** 分层清楚，且本轮精简（72→65 文件、1,341→942 函数定义、删除 schema gate 与全部根目录转发入口、把 RoofRefresh 与 TemplateRecovery 合并回单文件）显著降低了规模与间接层。

**按本轮四个问题归纳：**

1. **模块功能**：18 个模块目录的职责与逐函数语义已由 18 份报告完整覆盖（第 1 节索引表；每个函数的参数、返回/副作用、模块语义与必要性判断见各报告）。
2. **应提取的公用功能**：收益最高的是**受保护引擎调用层**（9 份实现 / 103 个调用点，且只有 `RV_Common` 保护属性读取）与 **`data.RailroaderRVTest` 读取 + owner 校验**（14 处读取 / 2 处写入），其次为**稳定玩家身份三元组**（5 套构建）与 **`onlinePlayersSnapshot`**（同一事实 3 种语义）。它们只能落在 `shared/`（三方消费）。反之，宽松/严格数值合同的差异、持久化键格式、各模块 tag 谓词**不应统一**。
3. **是否应进一步拆分**：只有 3 项建议（`EntryExit.lua:424-596` 生成提交簇、`Objects.lua:335-411` ledger、`RV_RailroaderServer_WallReload.lua` 的 RoomOwnership 监视器重挂），且**都不应仅因行数拆分**；上一版总结列为「高优先」的 TemplateRecovery 与 SchemaGate 拆分在当前源码下已不成立。7 个合并候选全部否决。
4. **跨模块内部数据访问**：存在但**未失控**——25 条跨包 + 15 条包内访问中仅 4 条建议提供接口，其余判「接口收益低于直接访问」，理由集中于「该表就是存档/schema 数据合同」「加 getter 不隐藏可变性」「调用点唯一」「本就是模块装配协议」四类。真正需要处理的是**接口缺口**（第 5 章第 1/3/4/5 条）与**记录字段误用**（第 2/6/7 条）。

**风险最高的一组静态发现全部集中在同一条 mutex/上下文装配链上**：`RV.Server.isGenerationTransactionActive` 无生产者、`Mapping.lua:158` 的裸全局取到 nil、`ctx.playerPositionInRegion` 未注入主 ctx、`Core.onCommand` 不接受 `"*"`。它们各自独立、由不同 worker 在不同上下文发现并交叉验证，且都会导致「守卫不纠正玩家 / 进入退出命令不注册 / 墙载无法启动 / 生成无法完成」这类**功能性阻断**。修复应按「把 `GenerationTransaction.isActive` 转发到 facade」+「把 `playerPositionInRegion` 加入主 ctx」+「让 `onCommand` 支持 `"*"`」三个最小改动进行，但**必须先做运行时确认**。

所有建议继续 fail-closed，仅接受当前源码声明的 schema；本轮未对旧数据兼容、迁移或运行时行为作任何扩展判断，也未修改任何源码或运行任何测试。
