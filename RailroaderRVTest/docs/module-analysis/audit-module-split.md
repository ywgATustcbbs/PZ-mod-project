# 模块拆分候选审计

> 独立审计事务 C：模块/文件是否应当进一步拆分。本报告只做静态结构审计，**未修改任何 `.lua` 源码、配置或测试文件，未运行游戏/服务器/任何测试脚本**（唯一写入文件为本文件）。

## 审计范围与方法

**统计口径（本次唯一口径，全部数字可复核）**

1. 目录范围：`contents/mods/RailroaderRVTest/42/media/lua/`，`Get-ChildItem -Recurse -Filter *.lua`，实测 **65 个 `.lua` 文件、16,484 行、791 个函数定义**。
2. 行数 = 文件的物理总行数（含空行与注释），与既有模块报告的"源码行数"口径一致。
3. 函数定义数 = 满足以下两条正则中任意一条的行数：
   - `^\s*(local\s+)?function\s+[\w\.:]+`（含 `local function f(`、`function M.f(`、`function Window:f(`）
   - `^\s*[\w\.\[\]"'':]+\s*=\s*function\s*\(`（含 `Client.getSnapshot = function()`、`sourceWithinRange = function(`）
4. **排除规则**：同一行既含 `type(` 又含 `function` 的比较行不计（例如 `RowOwnership:RV_Server_RoomOwnership.lua:24`、`WorldObjects:498/708`、`RoofRefresh:85/92`）。
5. **不计**：匿名闭包实参（如 `pcall(function() ... end)`、`return function(ctx)`）。因此本报告的函数数一般**小于**既有报告：既有报告把匿名闭包计入。已抽样核对两处：`RV_Server_WorldObjects.lua` 本报告 22 + 匿名 3（`:2` 工厂、`:746`、`:788`）= `server-Construction.md` 的 25；`RV_UtilityPower.lua` 本报告 39 + 匿名 3 = `server-Power.md` 的 42。**这是口径差异，不是数据冲突。**
6. 变更频率证据：仓库根为 `C:/Users/ustcy/Desktop/PZ-mod-project`（61 个提交），用 `git log --oneline -- <file>` 的提交数作为辅助信号。**该信号被最近的"精简/合并"重构串显著放大，仅作辅证，不作单独判据。**
7. 全部结论携带 `文件:行`。已明确区分**源码事实**与**条件性推断**。

**未做**：未运行 `python testserver/run_test.py`，未启动服务端/客户端，未做任何布局或数量断言以外的运行时验证。

## 实测规模表

### 分层汇总

| 层 | 文件数 | 总行数 | 函数定义数 | 目录数 |
|---|---|---|---|---|
| `client/` | 11 | 3,278 | 182 | 1（`RailroaderRV/GUI`） |
| `server/` | 42 | 11,313 | 531 | 12 |
| `shared/` | 12 | 1,893 | 78 | 5（均在 `RailroaderRV/` 下） |
| **合计** | **65** | **16,484** | **791** | 18 |

`shared/Translate/{CN,EN}/UI_*.json` 为非 Lua 资源，不计入规模；`client/RailroaderRV/` 与 `server/RailroaderRV/` 下**已无扁平 `.lua` 转发入口**（实测 `Get-ChildItem client/RailroaderRV -Filter *.lua` = 0）。

### client/RailroaderRV/GUI（11 文件 / 3,278 行）

| 层 | 文件 | 行数 | 函数定义数 | 备注 |
|---|---|---|---|---|
| client | RV_BoundaryClient.lua | 119 | 8 | 服务端位置纠正消费 |
| client | RV_BoundaryWallVisuals.lua | 134 | 6 | 边界支撑墙渲染隐藏 |
| client | RV_ContextMenu.lua | 73 | 0 | 组合根：只建 `ctx`（`:52-68`），零函数定义 |
| client | RV_ContextMenu_Relocation.lua | 454 | 9 | Relocate/FinalRelocate 客户端状态机 |
| client | RV_ContextMenu_RoomOwnership.lua | 292 | 16 | 房间归属 guard |
| client | RV_ProtectedDemolition.lua | 281 | 16 | 拆除拦截 |
| client | RV_RailroaderContextMenu.lua | 719 | 46 | **全树第 3 大**；Railroader 适配 |
| client | RV_UtilityClient.lua | 269 | 22 | 意图传输 + 只读 snapshot |
| client | RV_UtilityContextMenu.lua | 210 | 13 | 菜单项构造 |
| client | RV_UtilityDashboard.lua | 582 | 39 | **全树第 6 大**；水电面板窗口 |
| client | RV_WardrobeVisuals.lua | 145 | 7 | 衣柜渲染隐藏 |

### server/RailroaderRV（12 目录 / 42 文件 / 11,313 行）

| 模块 | 文件 | 行数 | 函数定义数 | 备注 |
|---|---|---|---|---|
| BoundaryGuard | RV_BoundaryServer.lua | 51 | 2 | 门面：建 `_states`/`_tick`/`ctx`，装配 3 组件（`:47-49`） |
| BoundaryGuard | RV_BoundaryServer_Geometry.lua | 388 | 23 | 通用 helper + 几何派生 + 租约（首要线索之一） |
| BoundaryGuard | RV_BoundaryServer_Sweep.lua | 180 | 6 | 每 tick 越界纠正 |
| BoundaryGuard | RV_RailroaderServer_BoundaryValidation.lua | 247 | 10 | 准入缓存 + 预热 |
| Common | RV_Common.lua | 92 | 10 | 零依赖通用层 |
| Common | RV_ServerUtil.lua | 50 | 2 | 服务端输入门面（转出 Common + 2 个抛错校验） |
| Common | RV_ServerTeleport.lua | 44 | 2 | 权威传送原语 |
| Common | RV_ServerSchema.lua | 157 | 6 | bounds/坐标合法性 |
| Common | RV_ServerWorld.lua | 480 | 28 | 世界格/对象/标签/清理/回滚 |
| Construction | RV_Construction.lua | 79 | 7 | 清场/建造门禁 |
| Construction | RV_Server_GenerationTransaction.lua | 53 | 6 | 唯一事务 owner（1 个 upvalue） |
| Construction | RV_Server_GenerationAck.lua | 146 | 4 | 两个 ACK + 唯一 abort 路径 |
| Construction | RV_Server_GenerationBuild.lua | 179 | 7 | 清场/建造实现 + 服务装配 |
| Construction | RV_Server_GenerationFlow.lua | 471 | 9 | **函数均长最高**（52 行/函数）；次要线索 |
| Construction | RV_Server_PlayerValidation.lua | 324 | 13 | 身份/坐标校验 + relocation 命令 |
| Construction | RV_Server_WorldObjects.lua | 816 | 22 | **全树最大**；首要线索 |
| Core | RV_RailroaderServer.lua | 119 | 5 | adapter 组合根 + schema 版本比较 |
| Core | RV_RailroaderServer_Sentinel.lua | 212 | 9 | Enter/Exit 命令门 + 互斥查询 |
| Core | RV_RailroaderServer_Tick.lua | 109 | 3 | adapter 周期工作 |
| Core | RV_Server.lua | 152 | 1 | 服务端组合根：建 `ctx`（`:105-136`）并装配 10 个子模块（`:141-150`） |
| Core | RV_Server_Commands.lua | 431 | 12 | tick/命令入口 |
| Core | RV_Server_Core.lua | 129 | 9 | 逻辑 tick + 事件分发器 |
| Core | RV_UtilityServer.lua | 366 | 21 | utility 协议门面 |
| Core | RV_UtilityStore.lua | 167 | 19 | utility ModData 仓库 |
| DemolitionProtection | RV_BoundaryServer_Objects.lua | 504 | 22 | shell 归属策略 + BuilderActionLedger |
| Power | RV_UtilityPower.lua | 661 | 39 | **全树第 4 大**；首要线索 |
| Power | RV_UtilityPowerDevices.lua | 365 | 22 | 设备扫描/负载（持有 3 张缓存表） |
| RoofRefresh | RV_RoofRefresh.lua | 131 | 9 | 已由 7 文件 4,331 行合并为单文件 |
| RoomOwnership | RV_Server_RoomOwnership.lua | 562 | 25 | guard 生命周期 |
| RVMapping | RV_RailroaderServer_EntryExit.lua | 720 | 19 | **全树第 2 大；此前所有线索均未列入** |
| RVMapping | RV_RailroaderServer_Mapping.lua | 312 | 18 | 映射/区域/槽位 |
| RVMapping | RV_RailroaderServer_Train.lua | 623 | 39 | **全树第 5 大**；向 ctx 发布 28 个 helper（`:595-622`） |
| RVMapping | RV_Server_RecordValidation.lua | 216 | 13 | manifest/roof 服务门面 |
| TemplateRecovery | RV_Server_TemplateProtectionRepair.lua | 473 | 29 | 已由多文件合并；唯一导出 `repairCell`（`:469-471`） |
| TemplateRecovery | RV_TemplateRecovery.lua | 175 | 8 | 已由多文件合并；环形队列 `queue`（`:23`） |
| WallReloadProtection | RV_RailroaderServer_WallReload.lua | 311 | 13 | adapter hook；**无模块报告** |
| WallReloadProtection | RV_WallReloadProtection.lua | 508 | 23 | 三阶段搬出/重载/返回状态机 |
| Water | RV_UtilityWater.lua | 11 | 1 | **全树最小**；单函数门面 |
| Water | RV_UtilityWater_Commands.lua | 55 | 2 | 连接事务编排 |
| Water | RV_UtilityWater_Ledger.lua | 30 | 3 | ledger 条目 |
| Water | RV_UtilityWater_Objects.lua | 157 | 7 | hint 校验 + 对象身份 |
| Water | RV_UtilityWater_Plumbing.lua | 57 | 3 | 原生属性读写核验 |

### shared/RailroaderRV（5 目录 / 12 文件 / 1,893 行）

| 模块 | 文件 | 行数 | 函数定义数 | 备注 |
|---|---|---|---|---|
| Common | RV_Constants.lua | 136 | 2 | 协议/布局/schema 配置源 |
| Common | RV_StrictSchema.lua | 13 | 1 | 严格整数（3 个消费者） |
| Common | RV_UtilityConstants.lua | 61 | 0 | 纯常量 |
| Common | RV_UtilitySprite.lua | 112 | 6 | 隐藏 sprite 注册 |
| Power | RV_UtilityPowerConfig.lua | 73 | 4 | 参数与纯公式 |
| Power | RV_UtilityItems.lua | 49 | 4 | 制作回调注册 |
| RoomTemplate | RV_Template.lua | 452 | 0 | **纯数据表**（`buildCells` + 412 条对象捕获），无行为函数 |
| RoomTemplate | RV_Layout.lua | 347 | 12 | 范围/墙边计划 |
| RoomTemplate | RV_RoomTemplate.lua | 153 | 10 | 编译 + 查询 |
| RoomTemplate | RV_TemplateGeometry.lua | 247 | 21 | 世界/模板坐标变换 |
| RVMapping | RV_RegionSlots.lua | 155 | 10 | 槽位矩阵坐标合同 |
| Water | RV_UtilityCatalog.lua | 95 | 8 | 水槽身份 + 能力探测 |

### 行数/函数数显著高于同层的文件（本报告评估对象）

按"行数 ≥ 450 或 函数数 ≥ 35"筛选，共 13 个：`RV_Server_WorldObjects.lua`(816/22)、`RV_RailroaderServer_EntryExit.lua`(720/19)、`RV_RailroaderContextMenu.lua`(719/46)、`RV_UtilityPower.lua`(661/39)、`RV_RailroaderServer_Train.lua`(623/39)、`RV_UtilityDashboard.lua`(582/39)、`RV_Server_RoomOwnership.lua`(562/25)、`RV_WallReloadProtection.lua`(508/23)、`RV_BoundaryServer_Objects.lua`(504/22)、`RV_ServerWorld.lua`(480/28)、`RV_Server_TemplateProtectionRepair.lua`(473/29)、`RV_Server_GenerationFlow.lua`(471/9)、`RV_ContextMenu_Relocation.lua`(454/9)。另有 `RV_Template.lua`(452/0) 与 `RV_BoundaryServer_Geometry.lua`(388/23) 按线索要求单独评估。

## 结论摘要

1. **"是否应当进一步拆分"的答案是"是，但只有 3 项，且都不是靠行数得出的"。** ①明确建议：`server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua`（720 行，全树第 2 大）抽出已发布的生成提交/失败恢复簇（`:424-596`）；②低成本建议：`server/RailroaderRV/DemolitionProtection/RV_BoundaryServer_Objects.lua` 抽出 `BuilderActionLedger`（`:335-411`，零新增公开接口）；③低优先建议：`server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua` 抽出 RoomOwnership 监视器重挂（`:37-44` + `:284-309`，独立 upvalue `nextMonitorRearmTick` `:285`，1 处调用点 `Core/RV_RailroaderServer_Tick.lua:65-67`）。
2. **先前报告列为首要候选的 `RV_Server_WorldObjects.lua`（816 行）本审计判定为"暂缓，不建议现在拆"。** 关键事实：该文件**没有任何模块级可变状态**，全部 22 个函数都是纯函数；唯一跨簇共享原语是 `addSpecialObject`（定义 `:418`，被 generator 簇 `:497` 与捕获对象簇 `:572/:591/:608/:629` 使用）。拆分只买到"可独立审阅 137 行回滚路径"，代价是 2 个新 require、1 个新 `ctx` 导出、以及把 5 处写入顺序不变量注释（`:262-265`、`:436-438`、`:487-489`、`:545-553`、`:573-575`）与调用点拆到不同文件。
3. **变更频率证据支持"EntryExit 才是更好的候选"**：`:424-596` 的提交簇独占地耦合生成生命周期（`Boundary.builderActionLedger.invalidateForGeneration`，`:527-533`；`RailroaderRV.Server.initializeUtilityRecord`，`:534-535`），而进入/退出簇（`:235-423`、`:597-712`）只耦合 Railroader 座位 API。**两者变更来源不同**。且这 3 个函数**已经发布在 `ctx` 上**（`:716-718`）并被 `Core/RV_RailroaderServer_Tick.lua:13-15` 消费，抽出只需新增 1 个 `ctx` 键（文件私有 helper `movePlayer`，`:148`）。
4. **不建议为行数拆分 `RV_UtilityPower.lua`（661）**：物品事务原语簇（`:141-214`）的全部调用点集中在 `:319-593`；账本数学簇的 `commit`（`:235`）/`bump`（`:231`）被 `:314/:351/:398/:438/:475/:512/:539/:561/:643` 跨簇共享，拆出任一簇都要新公开提交时序。
5. **不建议拆分 `RV_RailroaderServer_Train.lua`（623/39）**：它向 `ctx` 发布 28 个 helper（`:595-622`），是 RVMapping 层的共享低层库，而不是职责混杂模块；拆成"只读读取/座位写入"会切开权威来源。
6. **不建议拆分 `RV_RailroaderContextMenu.lua`（719/46）**：其 4 个状态字段全部挂在公开表上（`Menu._rvUtilityMapping` `:16/:113/:225/:246/:251`；`Menu._rvGenerationTransition` `:298/:301/:336/:517/:541`；`Menu._rvCurrentSquareRefresh` `:424/:436/:441/:446/:452/:459/:463/:468`；`Menu._rvCurrentSquareRefreshHook` `:714/:716`），其中 `_rvCurrentSquareRefresh` 被"追赶块"（`:424-468`）与"官方 hook patch 块"（`:714-716`）**共同持有**；拆分会把同一个 flag 的所有权切成两半，并把已被 4 个外部模块经 pcall 全局查找调用的公开方法（`UtilityClient:36/:211`、`UtilityDashboard:48`、`UtilityContextMenu:138`、`Relocation:193-200/:273-285`）变成跨文件合同。
7. **不建议合并任何模块（7 个合并候选全部否决）**，包括全树最小的 `server/Water/RV_UtilityWater.lua`（11 行单函数门面）与 `shared/Common/RV_StrictSchema.lua`（13 行单函数）：前者是 Water 模块唯一公开名 `Water.setConnection`（唯一调用者 `Core/RV_UtilityServer.lua:13/:209`），后者与 `RV_Constants.finiteInteger` 的**接受域刻意不同**，同文件会诱发把两个合同错误统一。
8. **最紧急的动作不是拆代码，而是修文档**：`server-TemplateRecovery.md` 仍在描述**已不存在的 1,729 行单文件**并"建议拆分"（该模块刚由多文件合并为 2 文件 648 行）；`server-RVMapping.md`、`server-DemolitionProtection.md`、`global-summary.md`、`phase2-structure-optimization.md` 含已删除文件或过期行数（详见末节）。**审计期间有 4 份报告被并发重写**（`shared-Common.md` 4:02、`shared-RVMapping.md` 4:02、`server-WallReloadProtection.md` 4:02（新建）、`shared-RoomTemplate.md` 4:03），它们现已自我声明并替换了旧版数据，本报告已同步复核；此外新重写的 `server-Common.md:5`/`:176` 自身存在求和错误（声明 762 行，实测 823 行）。

## 拆分候选逐一评估

### server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua（720 行 / 19 函数）—— **本审计新提出的首要候选**

- **实测规模**：720 行，19 个函数定义（展开子块另计：`:10-11` 两个转发器、`:245` 一个函数表达式）。`git log` 提交数 9。全树第 2 大文件。**此前所有线索与报告都未把它列为拆分候选。**
- **职责簇（含行号范围）**：
  - A 效用 RV 内省：`resolveCurrentUtilityRV`(`:50-110`)、`currentUtilityRecord`(`:111-120`) → `:50-120`
  - B 转场/传送原语：`settleUtilityTransition`(`:121-139`)、`sendResult`(`:140-147`)、`movePlayer`(`:148-183`)、`markPlayerOutside`(`:184-210`)、`markPlayerInside`(`:211-234`) → `:121-234`
  - C 进入：`otherGeneratedRecord`(`:235-244`)、`sourceWithinRange`(`:245-252`)、`requestData`(`:253-269`)、`removeSeatForEntry`(`:270-273`)、`enterExisting`(`:274-353`)、`enterPlayer`(`:354-423`) → `:235-423`
  - **D 生成提交与失败恢复：`restoreAfterGenerationFailure`(`:424-452`)、`commitGeneration`(`:453-586`)、`validateGeneration`(`:587-596`) → `:424-596`（173 行）**
  - E 退出：`exitPlayer`(`:597-712`)
  - 导出：`:713-719`
- **状态 owner 分析（源码事实）**：本文件**无模块级可变状态**（仅 13 个 `ctx` 注入别名 + 4 个 require，见 `:3-48`）。状态在 `map`（`mapData`）与 Boundary lease 中。
  - D 段实际使用的 `ctx` helper：`integer`(`:456/:457/:460/:462/:463/:464/:469`)、`number`(`:436/:516/:517`)、`copyPosition`(`:441/:511`)、`copyPose`(`:513`)、`findTrain`(`:426/:503/:589`)、`mapData`(`:454`)、`playerId`(`:427`)、`playerDead`(`:588`)、`putDriver`(`:431`)、`putPassenger`(`:438`)、`seatForPlayer`(`:433`)、`trainMoving`(`:591`)、`trainPose`(`:512`) —— **全部由其它文件注入，不需要迁移所有权**。
  - D 段**唯一**使用的文件私有 helper 是 `movePlayer`（`:441`，定义 `:148`，另有 `:323`/`:634`/`:692` 三处调用）→ **需要新公开的私有 helper 恰好 1 个**。
  - D 段**不**使用 `settleUtilityTransition`（`:343`/`:633`/`:691` 均在簇外）、`markPlayerOutside`/`markPlayerInside`、`sourceWithinRange`、`requestData`、`removeSeatForEntry`。
  - **D 段独有的外部耦合（源码事实）**：`Boundary.builderActionLedger.invalidateForGeneration`(`:527-533`) 与 `RailroaderRV.Server.initializeUtilityRecord`(`:534-535`) 只出现在 `:424-596` 内。这是"生成事务身份失效"语义，属于"提交"，不属于"座位进出"。
- **建议（**建议拆分**）+ 边界与接口**：抽出 `server/RailroaderRV/RVMapping/RV_RailroaderServer_GenerationCommit.lua`，收纳 `:424-596`。
  - 新接口：**零新增**——`restoreAfterGenerationFailure`/`commitGeneration`/`validateGeneration` 已经写入 `ctx`（`:716-718`），消费者 `Core/RV_RailroaderServer_Tick.lua:13-15` 通过 `ctx` 读取，抽取后读取路径不变。
  - 唯一需要提升为共享接口的是 `movePlayer`（1 个新 `ctx` 键；也可选择把 `restoreAfterGenerationFailure` 留在原文件、只抽 `commitGeneration` + `validateGeneration`，则连这 1 个键都不需要，代价是失败恢复路径与提交路径分离）。
  - 装配顺序：新文件需在 `Core/RV_RailroaderServer.lua` 的 adapter 装配序列中位于注入其依赖（`RV_RailroaderServer_Train` 发布 `ctx.*`）之后、被 Tick 消费之前。**源码事实**：Train `:595-622` 先发布 28 个 helper，EntryExit 在 `:3-48` 捕获它们，因此新文件必须晚于 Train、且早于 Tick 的首次调用（Tick 在 `Adapter.installTransactionHooks`/`OnTick` 时按 `ctx` 查找，见 `RV_RailroaderServer_Tick.lua:13-15`）。
- **代价**：1 个新文件 + 1 条 require + 1 个新 `ctx` 键（或 0 个，见上）+ 装配顺序校验。没有状态迁移，没有 schema/校验语义变化。
- **净收益**：720 行 → 约 550 行；"座位进出与转场"（`:50-234`、`:235-423`、`:597-712`）与"生成事务提交/失败恢复"（`:424-596`）按**变更来源**分开——前者随 Railroader 官方座位/机车 API 变化，后者随 Construction 生成事务变化。**条件性推断**：本文件的 9 次提交无法按簇归因，因此"变更来源不同"是从依赖方向（`:527-535` 的生成身份耦合只存在于 D 段）推出的结构性推断，不是提交历史统计。

### server/RailroaderRV/DemolitionProtection/RV_BoundaryServer_Objects.lua（504 行 / 22 函数）—— **低成本候选**

- **实测规模**：504 行，22 函数。提交数 10。既有报告 `server-DemolitionProtection.md:222` 的结论是"目前不建议仅因文件长度立即拆分……若继续扩展，优先把建造意图 ledger 及其过期清理（移出）"。
- **职责簇（含行号范围）**：
  - A shell 身份/边界策略：`objectModData`(`:18-24`)、`rvTag`(`:25-33`)、`objectSquare`(`:34-39`)、`objectCell`(`:40-`)、`shellEdgeHasTemplateIndex`(`:58-79`)、`shellEdgeAllowed`(`:80-122`)、`Boundary.isCurrentShellWall`(`:123-200`)
  - B 事件/动作匹配：`appendShellEdgeKey`(`:201-206`)、`shellAxisMatches`(`:207-221`)、`shellEdgeKeysForAction`(`:222-263`)、`actionMatchesObject`(`:264-286`)、`markTagPlayerBuilt`(`:287-323`)、`commandArgument`(`:324-329`)、`commandCoordinate`(`:330-334`)
  - **C BuilderActionLedger：`:335-411`（`local BuilderActionLedger = { actions = {} }` `:335`；`prune` `:337`、`invalidateForGeneration` `:348`、`submit` `:365`、`uniqueCandidate` `:374`、`objectMatchConsumed` `:394`、`consumeObjectMatch` `:399`；发布 `Boundary.builderActionLedger` `:411`）**
  - D 入口：`Boundary.onProcessAction`(`:413-479`)、`Boundary.onObjectAdded`(`:480-504`)
- **状态 owner 分析（源码事实）**：C 拥有唯一的可变表 `BuilderActionLedger.actions`（`:335`），有自己的生命周期（`prune(tick)` `:337`、`invalidateForGeneration` `:348`）与消费语义（`:394`/`:399`）。该对象**已经作为独立句柄发布**（`:411`），外部读者只有两处：`BoundaryGuard/RV_BoundaryServer_Sweep.lua:111-113`（`local actionLedger = Boundary.builderActionLedger` → `prune(Boundary._tick)`）与 `RVMapping/RV_RailroaderServer_EntryExit.lua:527-533`（`invalidateForGeneration`）。C 段对外部状态的依赖已参数化：`Boundary._tick` 由调用点传入（`:414`、`:482`）。
- **建议（**建议拆分（低优先）**）+ 边界与接口**：抽出 `RV_BoundaryBuilderLedger.lua`（`:335-411`，约 77 行），由本文件 `require` 后继续在 `:411` 发布同一个 `Boundary.builderActionLedger`。
  - 新接口：**零新增**（`Boundary.builderActionLedger` 已存在；`prune`/`invalidateForGeneration` 已是其公开方法）。
  - 前置条件：需同时决定该文件的**目录归属**。**源码事实**：本文件位于 `DemolitionProtection/`，却由另一个包的门面装配（`BoundaryGuard/RV_BoundaryServer.lua:48`）；`server-BoundaryGuard.md:116` 已把这一"跨包硬编码路径"列为职责边界问题。ledger 被 Sweep 与 EntryExit 读取，归属 BoundaryGuard 亦合理。
- **代价**：1 个新文件 + 1 条 require + 1 次目录归属决策（若同时调整归属，还需改 `RV_BoundaryServer.lua:48`）。
- **净收益**：这是全树**唯一**"状态表 + 生命周期 + 已发布句柄"三者齐备、且抽取不新增任何公开接口的候选；把 77 行与"shell 归属策略"无关的状态管理从 504 行文件中移出。净收益为正是因为它满足"状态 owner 真正分离"这一条，而不是因为文件长。

### server/RailroaderRV/Construction/RV_Server_WorldObjects.lua（816 行 / 22 函数）—— **首要线索，判定暂缓**

- **实测规模**：816 行（全树最大），22 函数（+ 匿名 3 = `server-Construction.md:240` 的 25）。提交数 11。既有报告 `server-Construction.md:176` 结论为"首要候选"，建议拆为 `RV_Server_CapturedObject`（状态 + 工厂）与 `RV_Server_GeneratorEntry`（白名单 + 入口修复）。
- **职责簇（含行号范围）**：
  - A 通用/身份 helper：`integer`(`:10-18`)、`identityOf`(`:20-24`)、`sameIdentity`(`:26-31`)
  - B 捕获状态应用：`applyIntegerState`(`:33-44`)、`applyBooleanState`(`:46-57`)、`capturedObjectContext`(`:59-66`)、`ensureCapturedHiddenSprite`(`:68-77`)、`bindCapturedHiddenSprite`(`:79-101`)、`applyCapturedHealthState`(`:103-111`)、`applyCapturedIdentityAndState`(`:113-259`，147 行)
  - C 捕获标签/角饰/门框：`capturedTagData`(`:261-273`)、`isVisualCornerTemplateEntry`(`:275-280`)、`configureCapturedDoorFrame`(`:282-294`)
  - D roof square：`ensureRoofSquare`(`:296-332`)（**无内部调用点，只在 `:811` 导出**）
  - E square 插入原语：`createFloor`(`:334-416`)、`addSpecialObject`(`:418-440`)
  - F generator 构造：`createGenerator`(`:442-505`)
  - G 捕获对象构造：`createCapturedTemplateObject`(`:507-642`)
  - H generator 白名单/回滚：`generatorObjectTag`(`:644-651`)、`isWhitelistedGenerator`(`:653-667`)、`rollbackEntryGenerator`(`:669-700`)
  - I 入口检查：`ensureGeneratorForEntry`(`:702-805`)
  - 导出：`ctx.ensureRoofSquare`/`createGenerator`/`createCapturedTemplateObject`/`configureCapturedDoorFrame`/`ensureGeneratorForEntry`（`:811-815`）
- **状态 owner 分析（源码事实，与报告结论的差异点）**：
  - 本文件**没有任何模块级可变表或 upvalue 状态**（`:3-8` 仅 8 个别名）。因此本候选**不存在状态 owner 迁移问题**——这是它被列为首要候选的主要弱点：拆分的收益只剩"文件更短 + 可独立审阅"。
  - 跨簇共享原语**恰好 1 个**：`addSpecialObject`（定义 `:418`；被 `createGenerator` `:497` 与 `createCapturedTemplateObject` `:572`/`:591`/`:608`/`:629` 使用）。
  - A 簇（`:10-31`）**只为 generator 簇服务**：`integer` 仅在 `:664/:665/:666` 使用，`sameIdentity` 仅在 `:655`/`:682` 使用，`identityOf` 仅在 `:27`/`:28` 使用 —— 全部落在 H 段（`:644-700`）。这说明"A 簇归属 generator 侧"比既有报告的切法更精确。
  - `createFloor`（`:334`）只被 `createCapturedTemplateObject`（`:547`）使用；`isWhitelistedGenerator`（`:653`）只在 H/I 段（`:765`/`:792`）使用。
  - 写入顺序不变量与调用点**同文件**：`:262-265`（标签只存 `templateIndex`）、`:436-438`（调用方必须只 transmit 一次）、`:487-489`（generator 值先于入格）、`:545-553`（角饰 vs 地板槽位）、`:573-575`（health setter 依赖 square）。
- **建议（**暂缓，不建议现在拆**）+ 触发条件**：若拆，最省的切法是"generator 簇 = F+H+I + A 簇 + D"与"捕获对象簇 = B+C+E+G"，`addSpecialObject` 提升为 `ctx` 导出（1 个新键）。
  - **代价**：2 个新 require 并进入 `Core/RV_Server.lua:142` 的装配序列（当前 WorldObjects 只占一个槽位，`:142` 先于 `:143` 的 GenerationBuild，后者在 `:10-13` 捕获 4 个 `ctx` 键）→ 需要显式保证"原语文件 → 捕获文件 → generator 文件"的加载顺序；**5 处顺序不变量注释与调用点分离**，而这些不变量正是该文件最脆弱的部分。
  - **净收益**：可独立审阅 `:669-805`（137 行白名单 + 回滚 + 入口修复）。**判断：不足以抵消上述代价**，因为该文件无状态可分离、无第二调用方、且当前无迹象表明两个簇必须分别演化。
  - **触发条件（明确）**：出现以下任一情形再拆——(a) generator 入口路径出现第二个调用方或第二类修复需求（例如发电机替换/维修）；(b) 出现第三类需要写入 square 的对象原语，使 E 簇真正成为共享层；(c) `:669-805` 的回滚逻辑需要独立测试或独立演化。

### server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua（471 行 / 9 函数）—— 次要线索，判定暂缓

- **实测规模**：471 行，9 函数（+ 匿名 2 = `server-Construction.md:238` 的 12）。**函数均长 52.3 行，全树最高**。提交数 **14，全树最高**。既有报告 `server-Construction.md:177` 建议按"计划/排队（`:43-126`、`:324-462`）、同步编排（`:128-251`）、提交（`:257-322`）"拆分，前置条件是先收敛 `prepared.stage` 的写点。
- **职责簇（含行号范围）**：`allocateRVRegion`(`:13-20`)、`selectGenerationStagingDestination`(`:43-63`)、`playerIsAtStagingDestination`(`:64-86`)、`validateRequest`(`:87-107`)、`relocatePlayerIntoHouse`(`:108-127`)、`generateForPlayer`(`:128-256`，129 行)、`finalizeGenerationAfterRelocate`(`:257-323`)、`queueGeneration`(`:324-470`，147 行)；导出 `:465-470`。
- **状态 owner 分析（源码事实）**：本文件**不持有**事务状态；`record` 在一次请求内构造后以形参流转，唯一 owner 是 `RV_Server_GenerationTransaction.lua` 的闭包 upvalue（该文件 53 行/6 函数）。
  - **对既有报告的事实更正**：`server-Construction.md:177` 称 "Flow 自己写 L124/L133/L320，Ack/PlayerValidation/Core 也写"。全树实测 `.stage =` 写点只有 **4 处 / 2 个文件**：`RV_Server_GenerationFlow.lua:124`、`:133`、`:320` 与 `RV_Server_GenerationTransaction.lua:21`；`RV_Server_GenerationAck.lua:104`、`RV_Server_PlayerValidation.lua:308`、`RV_Server_Commands.lua:202`/`:234`/`:243` **全部是只读**。
- **建议（**暂缓**）+ 边界与接口**：拆分的真正前置条件比报告中所述更窄——先把 Flow 的 3 处 `prepared.stage` 写点收敛为 GenerationTransaction 的具名阶段操作（这样阶段机 owner 与编排者分离）。完成后再按"异步编排（`:128-323`）"与"计划/排队（`:43-127`、`:324-470`）"分文件。
  - **代价（若现在拆）**：同一个可变表（`prepared`）的写点会从 1 个文件扩散到 2 个，而 Flow 是全树变更最频繁的文件（14 次提交），风险不对称。
  - **净收益**：现在拆 ≈ 0（仅导航），收敛写点后拆 ≈ 明确（阶段机与编排分离）。

### server/RailroaderRV/Power/RV_UtilityPower.lua（661 行 / 39 函数）—— 判定**不建议拆分**

- **实测规模**：661 行，39 函数（+ 匿名 3 = `server-Power.md:17` 的 42）。提交数 6（偏低）。
- **职责簇（含行号范围）**：A 基础调用/世界时钟(`:13-65`)；B 设备绑定与原生代理(`:66-140`)；C 库存物品事务原语(`:141-214`)；D 账本数学与运行时(`:215-318`)；E 公开操作(`:319-593`)；F 原生维护/生命周期/快照(`:594-661`)。
- **状态 owner 分析（源码事实）**：本文件无模块级可变表；账本在 `record.power`（`RV_UtilityStore` 拥有，ModData 持久化）。**跨簇共享的提交原语**：`commit`(`:235`) 用于 `:314/:351/:398/:438/:475/:512/:539/:561/:643`，`bump`(`:231`) 用于 `:313/:350/:397/:437/:474/:511/:538/:560/:638` —— 同时覆盖 D、E、F 三簇。C 簇的全部物品原语（`findInventoryItem` `:153`、`removeInventoryItem` `:183`、`addInventoryItem` `:188`、`createItem` `:194`、`syncItem` `:205`、`itemCondition` `:171`、`itemHintId` `:211`）**只被 `:319-593` 的公开操作消费**（`:357`/`:416`/`:503`、`:434`/`:478`/`:506`/`:542`、`:441`/`:468`/`:515`/`:532`、`:465`/`:529`、`:484`/`:547`、`:419`/`:490`）。
- **建议（**不建议拆分**）+ 理由**：C 是 E 的私有原语层，D 的 `commit`/`bump` 是"先改库存再改账本、失败即补偿"这一顺序的载体；拆出任一簇都必须新公开 `commit`/`bump` 或复制提交时序，从而把当前唯一的补偿顺序变成跨文件协议。**净收益为负**。与 `server-Power.md:120` 结论一致（其理由是"职责闭环而不是行数"，本次以调用点分布独立验证）。

### server/RailroaderRV/RVMapping/RV_RailroaderServer_Train.lua（623 行 / 39 函数）—— 判定**不建议拆分**

- **实测规模**：623 行，39 函数。它向 `ctx` 发布 **28 个 helper**（`:595-622`：`number`/`integer`/`call`/`callGlobal`/`safeCall`/`playerId`/`playerName`/`playerDead`/`playerPosition`/`copyPosition`/`newTransitionToken`/`copyPose`/`trainId`/`findTrain`/`trainPosition`/`trainMoving`/`trainPose`/`seatPosition`/`besidePosition`/`usableCoordinate`/`persistedBesidePosition`/`hullDistance`/`seatForPlayer`/`freePassengerSeat`/`playerRole`/`forgetTrainSeat`/`putPassenger`/`putDriver`）。
- **建议（**不建议拆分**）**：它是 RVMapping 层的**共享低层库**，不是职责混杂的业务模块；消费者是 Mapping、EntryExit（`:13-45` 捕获 33 个别名）、Sentinel（`:14-23`）、Tick（`:6-15`）。拆为"只读读取"与"座位写入"需要把这些 helper 的所有权与权威来源切开，且 28 个已发布键会被迫重新分配归属。与 `server-RVMapping.md:198` 一致。净收益为负。

### server/RailroaderRV/Common/RV_ServerWorld.lua（480 行 / 28 函数）—— 判定**不建议拆分**

- **职责簇**：快照(`:11-165`)、身份标签与 modData(`:167-222`)、特殊实体删除(`:240-408`)、square 事务(`:433-462`)。
- **状态 owner 分析（源码事实）**：无模块级可变状态；跨簇共享的私有步骤密集——`objectModData`(`:167`) 同时用于标签簇(`:179`/`:217`)与 square 事务簇(`:317`/`:363`)；`isTaggedForGeneration`(`:213`) 用于 `:447`/`:453`（`clearSquare` 区域）；`clearGenerationTag`(`:316`) 用于 `:385`（`restoreTaggedFloor`）；`removeObject`(`:410`) 用于 `:458`（`clearSquare`）；`removeGenericObject`(`:389`) 用于 `:430`。
- **建议（**不建议拆分**）**：四段共享同一条 `clearSquare → removeObject → removeGenericObject → restoreTaggedFloor → clearGenerationTag → recalcSquare` 事务链，拆分需要把上述 5 个私有步骤提升为跨文件导出，扩大接口面而不减少耦合。与 `server-Common.md:134` 一致。**触发条件**：若增加第三个只读消费者（当前 Construction/Power/Water/TemplateRecovery 只消费快照与标签两类语义），优先拆"对象枚举/快照"与"身份标签"两块。

### server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Geometry.lua（388 行 / 23 函数）—— 判定**不建议拆分**（复核线索）

- **职责簇**：A 通用调用/数值/身份 helper(`:13-99`)；B 记录→几何派生 + 槽位记忆化(`:148-269`)；C 玩家状态/租约/纠正前置校验(`:271-376`)；导出 10 个键(`:378-387`)。
- **状态 owner 分析（源码事实）**：`local boundariesBySlot = {}`(`:210`) **只服务** `boundaryFor`(`:211-235`)；`Boundary._states` 经 `stateFor`(`:271`) 单一入口读写。
- **建议（**不建议拆分**；真正的收益在去重而非拆文件）**：A 簇的 10 个 helper 已被发布到 `ctx`（`:378-387`）并被 `DemolitionProtection/RV_BoundaryServer_Objects.lua:7-11`、`RV_BoundaryServer_Sweep.lua:6-14`、`RV_RailroaderServer_BoundaryValidation.lua:12-15` 消费；把 A 簇拆成独立文件只是把这 10 个 helper 经 `ctx` 再转一手，**净收益为负**。**建议顺序**（与 `server-BoundaryGuard.md:112-113` 一致）：先把 A 簇中与本模块语义无关的通用 helper（`number`/`integer`/`finiteNumber`/`call`/`callGlobal`/`playerName`）去重到 `Common/RV_ServerUtil.lua`——**那是去重，不是拆文件**。触发条件：出现第二份几何缓存或第二份租约状态。

### server/RailroaderRV/TemplateRecovery/（2 文件 / 648 行）—— 判定**不建议拆分**（既有报告的"建议拆分"已失效）

- **实测规模**：`RV_Server_TemplateProtectionRepair.lua` 473 行/29 函数；`RV_TemplateRecovery.lua` 175 行/8 函数。合计 648 行。
- **状态 owner 分析（源码事实）**：repair 侧 `entriesByCell = {}`(`RV_Server_TemplateProtectionRepair.lua:37`) 是 cell 级索引缓存（`templateCellKey` `:38`/`:43`/`:94`、`templateEntriesAt` `:119`/`:404`），单例门 `instance`(`:5`/`:7`/`:469`/`:472`)；queue 侧 `queue`(`RV_TemplateRecovery.lua:23`) 环形缓冲 + `sampleInterval`(`:30`) + 单例门 `instance`(`:8`/`:10`/`:169`/`:174`，并镜像到 `RailroaderRV.RecoveryQueue` `:173`)。两侧唯一的跨文件接口是 `Repair.repairCell`(`:469-471`)，由 queue 以 `pcall(Repair.repairCell, player, ...)` 调用(`RV_TemplateRecovery.lua:137`)。
- **建议（**不建议拆分**）**：repair 的 `:20-460` 是一条"索引 → 身份判定 → 移除策略 → 删除/恢复"的线性流水线；谓词簇 `:139-244` 只被 `:245-320` 与 `:404-460` 消费（如 `objectMatchesTemplate` `:213`→`:234`/`:265`；`objectHasShellIdentity` `:222`→`:235`/`:266`/`:379`；`protectedWorldObject` `:286`→`:435`），拆开需把这些谓词提升为跨文件导出。**且该模块刚刚由"index + queue + repair 多文件"合并为 2 文件**（`git da740e1` 删除 `RV_TemplateRecoveryIndex.lua`/`RV_TemplateRecoveryQueue.lua`）。**明确反对把刚合并的结构再拆回去。**
- **既有报告状态**：`server-TemplateRecovery.md:5` 仍称"目录当前只有 `RV_Server_TemplateProtectionRepair.lua` 一个文件，共 1,729 行"，`:142` 结论为"建议拆分"，`:149` 引用了 `:1722-1726` 的 `_builders` 清理、`:136` 引用 `Common/RV_Bitmap.lua:37`。**这些行号与文件在当前源码中都不存在**，该报告的拆分结论对本轮无参考价值（详见末节）。

### server/RailroaderRV/WallReloadProtection/（2 文件 / 819 行）—— 服务层判定**不建议拆分**；adapter 层判定**建议拆分（低优先）**

- **实测规模**：`RV_WallReloadProtection.lua` 508 行 / 23 函数（提交数 **2，全树最低**）；`RV_RailroaderServer_WallReload.lua` 311 行 / 13 函数；目录合计 819 行。
- **职责簇**：A tick/门面(`:36-51`)、B 目标与上下文(`:64-159`)、C 成员与租约(`:160-222`)、D 操作生命周期(`:223-336`)、E 入口(`M.onTick` `:337`、`M.acknowledge` `:383`、`M.begin` `:445`)。
- **状态 owner 分析（源码事实）**：`local operations = {}`(`:21`) 与 `local lastTick = nil`(`:34`) 是本状态机唯一的可变状态；三个 phase 推进器 `advanceMoveOut`(`:275`)、`advanceWaitReload`(`:301`)、`advanceReturn`(`:324`) 读写同一 `op` 表与 `operations` 索引；`PHASE_MOVE_OUT`/`PHASE_WAIT_RELOAD`/`PHASE_RETURN`(`:28-30`) 与 `OPERATION_TIMEOUT_TICKS`(`:25`) 定义同一状态机的状态空间。
- **建议（**不建议拆分**）**：所有簇围绕同一个 `operations` owner 与同一条三阶段生命周期；拆开需要把 `operations` 所有权外移或引入队列对象，把一个单文件状态机变成跨文件协议。配合**全树最低的提交频率**（2 次），当前没有变更边界需要隔离。
- **相关：`RV_RailroaderServer_WallReload.lua`（311 行 / 13 函数）—— 判定**建议拆分（低优先）**。** 该模块报告在本审计进行中才出现（`server-WallReloadProtection.md`，mtime 4:02），其 `:96` 的结论与本审计独立一致。**状态 owner 分析（源码事实）**：文件只有一处模块级可变 upvalue `nextMonitorRearmTick`（`:285`，配 `MONITOR_REARM_INTERVAL_TICKS = 60` `:284`），它**只服务** `Adapter.rearmRoomOwnershipMonitors`（`:287-309`）；该函数与 `armRoomOwnership`（`:37-44`）构成"客户端 stale-room 监视器周期重挂"，其依赖是 `Core.getTick`(`:288`)、`Boundary.boundaryForPlayer`(`:291`/`:296`)、`Adapter.onlinePlayersSnapshot`(`:293`)，与外墙重载判据（`cheapShellWallCandidate` `:128`、`wallReloadForObject` `:157`、两个 hook `:231`/`:238`）**零语义重叠**。**边界与接口**：把这 4 项（`armRoomOwnership`、两个常量、`rearmRoomOwnershipMonitors`）迁入 RoomOwnership，并改唯一调用点 `Core/RV_RailroaderServer_Tick.lua:65-67`（`if type(Adapter.rearmRoomOwnershipMonitors) == "function" then ... end`）。**代价**：1 处调用点改名/改发布表 + 1 个新文件（或并入现有 RoomOwnership 文件，则文件数不变）。**净收益**：这是本目录唯一"独立 upvalue 状态 + 独立职责 + 单一调用点"三者齐备的缝，且无行为变化。

### client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua（719 行 / 46 函数）—— 判定**不建议拆分**

- **职责簇**：A utility mapping(`:21-262`)、B Ride/生成过渡 + current-square 追赶(`:264-549`)、C 官方菜单与 hook patch(`:551-717`)。
- **状态 owner 分析（源码事实）**：状态**不在文件私有 upvalue**，而在公开表 `Menu` 的 4 个字段上。访问行号：`Menu._rvUtilityMapping` `:16`/`:113`/`:225`/`:246`/`:251`（仅 A 簇）；`Menu._rvGenerationTransition` `:298`/`:301`/`:336`/`:517`/`:541`（仅 B 簇）；`Menu._rvCurrentSquareRefresh` `:424`/`:436`/`:441`/`:446`/`:452`/`:459`/`:463`/`:468`（B 簇）**以及 `:714`/`:716`（C 簇）**；`Menu._rvCurrentSquareRefreshHook` `:714`/`:716`（C 簇）。
- **建议（**不建议拆分**）+ 理由**：
  1. **B 与 C 共享状态**：`_rvCurrentSquareRefresh` 与 `_rvCurrentSquareRefreshHook` 由 B 簇的追赶调度器（`:424-468`）与 C 簇的官方 hook 安装器（`:714-716`）共同持有——拆开必须把同一个 flag 的所有权切成两半，或新增跨文件接口。
  2. 它的公开方法已被 4 个外部文件消费（`RV_UtilityClient.lua:36`/`:211`、`RV_UtilityDashboard.lua:48`、`RV_UtilityContextMenu.lua:138`、`RV_ContextMenu_Relocation.lua:193-200`/`:273-285`），且这些调用点经 pcall 全局查找（`client-GUI.md:400`）——拆分把这些点变成硬合同。
  3. 三个簇共享同一类外部依赖（Railroader 官方 `RR.Ride`/`RR.TrainEntity`/`RR.BoardMenu`/`AnimalContextMenu` 内部字段），集中在一个 adapter 文件降低了版本耦合面。与 `client-GUI.md:400`、`phase2-structure-optimization.md:105` 一致。

### client/RailroaderRV/GUI/RV_UtilityDashboard.lua（582 行 / 39 函数）—— 判定**暂缓**

- **职责簇**：A 值格式化与 mapping(`:15-52`)、B 库存/物品扫描(`:54-113`)、C 窗口构建与渲染(`:115-470`)、D 模块回调与实例生命周期(`:472-582`)。
- **状态 owner 分析（源码事实）**：`Dashboard.instance` 只在 `:455`/`:483`/`:489-490`/`:506-511`/`:519`/`:525`/`:534`/`:546`/`:558` 内读写，无外部消费者（`client-GUI.md:424`）。B 簇函数的调用点全部落在 C 簇内：`collectionItems`(`:54`→`:78`，`inventoryItems` 内部)、`inventoryItems`(`:73`→`:83`/`:227`)、`itemName`(`:93`→`:236`)、`fluidFuel`(`:98`→`:275`)。
- **建议（**暂缓**）+ 触发条件**：抽出 `RV_UtilityItemScan`（`:54-113`）只有在**需要支持充电器/逆变器之外的第三类设备**、或物品分类规则需要独立演化时才划算；届时需注入提交回调（`:217` 的 `openInventoryMenu(predicate, callback, emptyLabel)` 已经参数化，接口成本不高）。**当前**拆分的收益仅是文件变短，而 B 簇只有 4 个消费点且都在同一窗口实例内。与 `client-GUI.md:401` 的触发条件一致。

### 其余高行数文件（已核，判定**不建议拆分**）

| 文件 | 实测 | 判定理由（源码事实） |
|---|---|---|
| `server/RoomOwnership/RV_Server_RoomOwnership.lua` | 562 行/25 函数 | 状态是注入的 `ctx.roomOwnershipGuards`（`Core/RV_Server.lua:88`/`:131`）；guard 的 `pendingCells`/`scanDueTick`/`nextNeighborhoodProbeTick` 在 `:119-122`、`:238`、`:337-339`、`:363-364`、`:406-413`、`:433-435` 六个函数间交错读写，拆开需把三态标记的所有权外移。与 `server-RoomOwnership.md:77` 一致。 |
| `client/GUI/RV_ContextMenu_Relocation.lua` | 454 行/9 函数 | 普通 `Relocate` 两阶段与 `FinalRelocate` 事务共享 `Events.OnServerCommand`/`Events.OnTick` 与 `ctx.clientTick`，私有状态 `pendingFinalRelocation`(`:22`) 已按 `phase2:44` 收归本文件；拆开需把它提升为显式接口。与 `client-GUI.md:402` 一致。 |
| `shared/RoomTemplate/`（4 文件） | 1,199 行；`RV_Template.lua` 452/0、`RV_Layout.lua` 347/12、`RV_RoomTemplate.lua` 153/10、`RV_TemplateGeometry.lua` 247/21 | 合计 1,199 行、43 个函数定义，**没有一个文件超过 452 行**；其中 452 行是纯数据表（0 函数定义）。按行数拆一个纯数据文件没有意义；`RV_TemplateGeometry` 的 21 个函数全部服务于同一"世界↔模板坐标与对象索引"用途。**不支持对这 4 个文件做进一步拆分。** |
| `server/RailroaderRV/RVMapping/RV_RailroaderServer_Mapping.lua` | 312 行/18 函数 | 旧报告建议抽出 `RoofRefreshIntegration`（`server-RVMapping.md:196` 引用 `:263-451`/`:396-435`）。**该行号已超出当前文件长度（312 行）**，属过期建议；当前文件的状态由 `mapData`(ModData) 与 `Adapter._mappingEpoch`（经 `currentMappingEpoch`/`advanceMappingEpoch` API，`:82-90`）持有，无独立 roof 状态段可切。**暂缓**：若 roof/wall 刷新状态段重新出现，再按"注入显式共享状态"的方式抽出。 |

## 合并候选评估

**总体判定：7 个合并候选全部否决，“是否有模块应当合并”的答案是“没有”。** 合并的收益一律是 -1 文件 / -N 行，而代价是改动本已稳定的 require 面或把两个刻意的合同合并。逐一给出理由。

### server/RailroaderRV/Water/RV_UtilityWater.lua（11 行 / 1 函数）—— 全树最小，判定**不建议合并**

- **实测规模**：11 行，1 函数。函数体是 `return Commands.setConnection(identity, context, targetHint, record)`（`:7-9`），单行转发，无逻辑。
- **状态 owner 分析**：无状态。唯一调用者 `Core/RV_UtilityServer.lua:13`（require）+ `:209`（调用），调用条件是 `operation == U.OP_CONNECT_WATER_DEVICE`(`:208`)。
- **建议（**不建议合并**）+ 代价**：删除门面可省 11 行，但会让 Core 直接 require Water 的**内部实现文件名** `RV_UtilityWater_Commands`，同时删除模块唯一公开名 `Water.setConnection`（该返回值形状是跨端合同：`detail.connected` 被客户端 `RV_UtilityDashboard.lua:563`、`RV_UtilityClient.lua:239` 消费，见 `server-Water.md:114`）。这与 `server/RailroaderRV/agent.md:8`（实现归属留在模块目录）冲突。**净收益为负**。保留成本确实只是"一行转发"，但**触发条件**明确：若 Water 永远只有这一个公开操作，可在某次纯清理中把门面并入 `Commands` 并同步改 `RV_UtilityServer.lua:13`/`:209` 一处调用；当前无此必要。

### server/RailroaderRV/Common/RV_ServerUtil.lua（50 行 / 2 函数）—— 判定**不建议合并**

- **实测规模**：50 行，2 函数定义（`requiredNumber` `:20`、`requiredInteger` `:28`），其余是 10 个 `Common.*` 的本地别名（`:10-18`）。
- **消费者（源码事实）**：12 处 require —— `Water/Plumbing:3`、`Water/Objects:7`、`Water/Commands:10`、`WallReloadProtection:14`、`RoofRefresh:14`、`Common/ServerWorld:7`、`Common/ServerSchema:6`、`Core/RV_Server:80`、`Power/PowerDevices:6`、`Power/UtilityPower:9`、`Core/UtilityServer:14`。
- **建议（**不建议合并**）**：并入 `Common/RV_Common.lua`（92 行）需改 12 个 require 点；而 `RV_Common` 是零依赖通用层（`:3` `unpackFn`、无 require），`RV_ServerUtil` 是"服务端输入门面 + 抛错式必需值校验"。合并会把服务端专属的抛错语义塞进通用层。`phase2-structure-optimization.md:54` 已把 `ServerUtil` 定为复用首选。**净收益为负。**

### shared/RailroaderRV/Common/RV_StrictSchema.lua（13 行 / 1 函数）—— 判定**不建议合并**

- **实测规模**：13 行，1 函数 `M.integer`（`:4-11`，拒绝 `type ~= "number"`、NaN、±Inf、非整数）。
- **消费者**：`shared/RailroaderRV/RVMapping/RV_RegionSlots.lua:7`、`shared/RailroaderRV/Water/RV_UtilityCatalog.lua:7`、`server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:9`（跨 shared 与服务端，共 3 处）。
- **建议（**不建议合并**）**：它与 `shared/Common/RV_Constants.lua` 的 `C.finiteNumber`(`:13`)/`C.finiteInteger`(`:33`) **接受域刻意不同**；`phase2-structure-optimization.md:74-75` 明确要求两者**不得统一**（"strict integer 拒绝数字字符串和 Java numeric wrapper"）。若并入同一文件，两个外观相似但合同不同的整数校验器同处一室，正是漂移风险最高的形态。**物理分文件是对"不要统一"这一决定最廉价的强制。净收益为负。**

### server/RailroaderRV/Common/RV_ServerTeleport.lua（44 行 / 2 函数）—— 判定**不建议合并**

- **实测规模**：44 行，2 函数（`teleportToPosition` `:5-14`、`teleportToRVSpawn` `:18-42`）。
- **消费者**：`Core/RV_Server.lua:81` → 转出为 `RV.Server.teleportToPosition`/`teleportToRVSpawn`（`:138-139`）；`RVMapping/RV_RailroaderServer_EntryExit.lua:5` 直接 require。
- **建议（**不建议合并**）**：它是**服务端权威传送原语**（`:6-10` 拒绝非有限坐标与缺失 `teleportTo`；`:16-18` 注释明确"调用方提供已验证的 mapping identity，绝不使用客户端坐标"）。把它并入 `RV_Common` 会把一条安全原语降级为通用工具函数，削弱"哪些操作是权威世界变更"的可读边界。**净收益为负。**

### server/RailroaderRV/Construction/ 的三个薄文件（79 / 53 / 146 行）—— 判定**不建议合并**

- `RV_Construction.lua`（79 行/7 函数）是清场/建造门禁：`requireCurrentBuild`(`:11`)、`preflightClearTarget`(`:17`)、`preflightCurrentGeneration`(`:41`)、`requireCurrentMutation`(`:50`)、`clearCurrentGeneration`(`:58`)、`buildCurrentGeneration`(`:67`)。
- `RV_Server_GenerationTransaction.lua`（53 行/6 函数）是唯一事务 owner：`begin`(`:13`)、`current`(`:26`)、`owns`(`:30`)、`isActive`(`:37`)、`cancel`(`:41`)、`release`(`:48`)，1 个闭包 upvalue 持有活动记录。
- `RV_Server_GenerationAck.lua`（146 行/4 函数）含唯一 abort 路径 `abortGeneration`(`:94`)。
- **建议（**不建议合并**）**：三者的状态 owner 完全不同（门禁 / 事务身份 / 失败释放），且 `server-Construction.md:179-181` 已分别给出"不建议拆"的理由——**同理，把它们并回一个文件会让"谁能在失败时释放事务"重新变成同文件内的隐式问题**。注意 `RV_Construction.lua` 虽只有 79 行却有 11 次提交，说明它的变更来自两侧调用方的接口变化，而不是自身职责膨胀；合并只会放大这种耦合。

### client/GUI 的三个菜单/组合文件（73 / 454 / 292 行）—— 判定**不建议合并**

- `RV_ContextMenu.lua` 是 **0 函数定义**的组合根：只建 `ctx`(`:52-68`)；`RV_ContextMenu_Relocation.lua` 在 `:3-21` 读出 ctx 键、并在 `:163`/`:308`/`:352`/`:358`/`:363`/`:420` 改写 `ctx.pendingRelocation`；`RV_ContextMenu_RoomOwnership.lua` 在 `:285-291` 写入 7 个键。
- **建议（**不建议合并**）**：合并会让 `Relocation`/`RoomOwnership` 反向依赖组合根，并使两处已按 `phase2-structure-optimization.md:44` 收归各自的私有状态（`pendingFinalRelocation` `Relocation:22`、`roomOwnershipGuards` `RoomOwnership:5`）重新靠同一作用域共享。`client-GUI.md:421` 也判定"不建议改成访问器或消息总线——接口层成本高于收益"。**净收益为负。**

### server/RailroaderRV/RoofRefresh/ 是否并回 WallReloadProtection —— 判定**不建议合并**

- `RV_RoofRefresh.lua` 131 行/9 函数，只承担"刷新点 → 世界格 → 临时地板 → 重算"一条闭环（`server-RoofRefresh.md:52`）；提交数 7。
- **建议（**不建议合并**）**：它被两条独立路径复用——`RVMapping` 的 `refreshRoofForPlayer`（由 `RV_RailroaderServer_Mapping.lua:172` 定义、`:305` 发布）与 `WallReloadProtection/RV_RailroaderServer_WallReload.lua:12`/`:104` 的 `runRoofRefresh`。它是**共享服务**而不是 WallReload 的内部步骤；合并会使 RVMapping 反向依赖 WallReload。**注意**：该模块是本轮"7 文件 4,331 行 → 1 文件 131 行"合并的产物（`git 89ae61b` 删除 5 个 Roof 文件），**不应再拆回去**。

### 目录级问题（不是文件合并，但需一并决策）

- `server/RailroaderRV/DemolitionProtection/` **只有 1 个文件**（504 行），且由**另一个包**的门面装配：`BoundaryGuard/RV_BoundaryServer.lua:48` `require("RailroaderRV/DemolitionProtection/RV_BoundaryServer_Objects")(ctx)`，该文件随后向 `Boundary` 命名空间写字段（`:411`）。`server-BoundaryGuard.md:116` 已把它列为职责边界问题。
- **建议（**低优先，与 BuilderActionLedger 抽取一并决策**）**：二选一——(a) 把 `RV_BoundaryServer_Objects.lua` 迁入 `BoundaryGuard/`，使"由谁装配"与"在哪个目录"一致；(b) 保留在 `DemolitionProtection/`，但把门面的硬编码路径改成运行时查找（同 RecoveryQueue 模式）。本项**不改变文件数量**，只修正归属；无行为收益，故仅为低优先。

## 优先级排序表

| 优先级 | 候选 | 可分出的责任 | 前置条件 | 预期收益 | 风险 |
|---|---|---|---|---|---|
| **高**（文档） | 5 份过期/历史文件（`server-TemplateRecovery.md`、`server-RVMapping.md`、`server-DemolitionProtection.md`、`global-summary.md`、`phase2-structure-optimization.md`）+ `server-Common.md` 的目录求和（762 → 823） | 过期行数/已删除文件的引用；已失效的"建议拆分"结论；一处算术错误 | 无（纯文档）；`global-summary.md` 由主 agent 负责，其余报告需其 owner 重跑 | 立即消除"按 1,729 行单文件去拆一个 648 行两文件模块"的错误指令（`global-summary.md:68` 的高优先项因此不再成立） | 无代码风险；**本报告不改他人报告**；注意审计期间已有 4 份报告被并发重写，重跑前需重新取 mtime 快照 |
| **中** | `RVMapping/RV_RailroaderServer_EntryExit.lua:424-596` | 生成提交与失败恢复（`restoreAfterGenerationFailure`/`commitGeneration`/`validateGeneration`，173 行） | 装配顺序：新文件晚于 `RV_RailroaderServer_Train`、早于 Tick 首次调用；决定 `movePlayer` 是否提升为 `ctx` 键 | 720 行 → 约 550 行；按变更来源分开"座位进出"与"生成提交"；3 个函数已是已发布接口 | 中：装配顺序错位会让 `ctx` 键为 nil；`movePlayer` 若不提升则需保留失败恢复路径在原文件 |
| **低** | `DemolitionProtection/RV_BoundaryServer_Objects.lua:335-411` | `BuilderActionLedger`（独立状态表 + prune/invalidate 生命周期，约 77 行） | 同时决策 ledger 归属目录（BoundaryGuard 还是 DemolitionProtection） | 零新增公开接口（`Boundary.builderActionLedger` 已发布，`Sweep:111-113`/`EntryExit:527-533` 读取路径不变） | 低—中：若同时改目录归属需改 `RV_BoundaryServer.lua:48` |
| **低** | `WallReloadProtection/RV_RailroaderServer_WallReload.lua:37-44` + `:284-309` | RoomOwnership 监视器周期重挂（`armRoomOwnership`、`MONITOR_REARM_INTERVAL_TICKS`、独立 upvalue `nextMonitorRearmTick` `:285`、`Adapter.rearmRoomOwnershipMonitors`） | 决定迁往 RoomOwnership 还是 Core tick 路径 | 独立状态 owner + 独立职责（服务 RoomOwnership，与外墙判据零重叠）；无行为变化 | 低：唯一调用点 `Core/RV_RailroaderServer_Tick.lua:65-67` 需同步；`server-WallReloadProtection.md:96` 独立给出同一结论 |
| **低** | `BoundaryGuard/RV_BoundaryServer_Geometry.lua:13-99` | 6 个通用 helper（`number`/`integer`/`finiteNumber`/`call`/`callGlobal`/`playerName`）**去重**到 `Common/RV_ServerUtil.lua` | 确认各调用点失败语义一致（`server-BoundaryGuard.md:112`） | 减少全树重复 helper（另见 `RVMapping/Train:7-48`、`WorldObjects:10-18`、`TemplateRecovery:20`） | 低：`call`/`callGlobal` 的 pcall 语义在各文件存在细微差异，需逐点核对；**不改变文件数**；完整清单见 `audit-duplicate-helpers.md`（兄弟审计） |
| **暂缓** | `Construction/RV_Server_WorldObjects.lua`（816 行，首要线索） | generator 簇（F+H+I+A）与捕获对象簇（B+C+E+G）；共享 `addSpecialObject`(`:418`) | 触发条件：generator 入口出现第二调用方/第二类修复需求；或 E 簇成为真正的共享原语层 | 可独立审阅 `:669-805` 的 137 行回滚路径 | 中：5 处写入顺序不变量（`:262-265`/`:436-438`/`:487-489`/`:545-553`/`:573-575`）与调用点分离；无状态可分离，收益偏低 |
| **暂缓** | `Construction/RV_Server_GenerationFlow.lua`（471 行，函数均长 52.3 最高） | 异步编排(`:128-323`) 与 计划/排队(`:43-127`、`:324-470`) | 先把 Flow 的 3 处 `prepared.stage` 写点（`:124`/`:133`/`:320`）收敛为 GenerationTransaction 的具名阶段操作 | 阶段机 owner 与编排者分离；当前拆分收益≈0 | 中：全树变更最频繁文件（14 次提交）；`prepared` 写点会扩散到 2 个文件 |
| **暂缓** | `client/GUI/RV_UtilityDashboard.lua:54-113` | 库存/物品扫描与分类（`collectionItems`/`inventoryItems`/`itemName`/`fluidFuel`） | 触发条件：支持充电器/逆变器之外的第三类设备 | 与 PZ 物品 API 强耦合的部分独立，便于替换；提交回调已由 `:217` 参数化 | 低：4 个消费点都在同一窗口实例内，收益仅为导航 |
| **不建议** | `Power/RV_UtilityPower.lua`（661/39） | — | — | — | 拆分需新公开 `commit`(`:235`)/`bump`(`:231`)，把唯一补偿时序变成跨文件协议 |
| **不建议** | `RVMapping/RV_RailroaderServer_Train.lua`（623/39） | — | — | — | 它是发布 28 个 helper（`:595-622`）的共享低层库 |
| **不建议** | `RoomOwnership/RV_Server_RoomOwnership.lua`（562/25） | — | — | — | 三个 guard 字段在 6 个函数间交错读写 |
| **不建议** | `WallReloadProtection/RV_WallReloadProtection.lua`（508/23，服务层） | — | — | — | 单一 `operations`(`:21`)+`lastTick`(`:34`) 状态机，相位推进器 `:275`/`:301`/`:324` 共享同一 op 表；提交数仅 2 |
| **不建议** | `Common/RV_ServerWorld.lua`（480/28） | — | — | — | 标签簇与 square 事务簇经 5 个私有步骤互锁 |
| **不建议** | `TemplateRecovery/`（648/37） | — | — | — | 刚由多文件合并；单条线性流水线 + 单例门 |
| **不建议** | `BoundaryGuard/RV_BoundaryServer_Geometry.lua`（388/23） | — | — | — | A 簇已发布到 `ctx`(`:378-387`)；拆它=把 helper 再转一手 |
| **不建议** | `client/GUI/RV_RailroaderContextMenu.lua`（719/46） | — | — | — | B/C 簇共享 `_rvCurrentSquareRefresh`(`:424-468`、`:714-716`)；4 个外部消费者 |
| **不建议** | `client/GUI/RV_ContextMenu_Relocation.lua`（454/9） | — | — | — | 两阶段与最终事务共享事件/tick/玩家查找 |
| **不建议** | `shared/RoomTemplate/`（1,199 行，最大文件 452 行为纯数据） | — | — | — | 无文件超过 452 行，且 452 行文件 0 个函数 |
| **不建议合并** | 7 个合并候选全部（`Water/RV_UtilityWater.lua` 11 行、`Common/RV_ServerUtil.lua` 50 行、`shared/Common/RV_StrictSchema.lua` 13 行、`Common/RV_ServerTeleport.lua` 44 行、Construction 三薄文件、client 三菜单文件、RoofRefresh 并回 WallReload） | — | — | 各自 -1 文件 | 见"合并候选评估"逐条：改动稳定 require 面或合并刻意区分的合同 |

## 覆盖与未覆盖

**统计覆盖**

- 实测文件：**65 / 65（100%）**。逐文件行数与函数定义数见"实测规模表"，全部由本次 `Get-ChildItem -Recurse -Filter *.lua` + 逐行正则统计得到。
- 分层：`client/` 11 文件 3,278 行 182 函数（1 个目录）；`server/` 42 文件 11,313 行 531 函数（12 个目录）；`shared/` 12 文件 1,893 行 78 函数（`RailroaderRV/` 下 5 个目录）。合计 16,484 行 / 791 函数。
- 逐一评估的候选：**13 个高行数文件 + `RV_Template.lua` + `RV_BoundaryServer_Geometry.lua` + `RV_RailroaderServer_WallReload.lua`（311 行，随 `server-WallReloadProtection.md` 落盘后补评）= 16 个**；合并候选 7 个；目录级归属 1 项。
- 评估结论分布：**建议拆分 3 项**（`EntryExit:424-596`、`Objects:335-411`、`RV_RailroaderServer_WallReload:37-44`+`:284-309`）；**暂缓 3 项**（`WorldObjects`、`GenerationFlow`、`UtilityDashboard:54-113`）；**不建议拆分 11 项**（Power、Train、RoomOwnership、WallReloadProtection 服务层、ServerWorld、TemplateRecovery 2 文件、BoundaryServer_Geometry、RailroaderContextMenu、ContextMenu_Relocation、shared/RoomTemplate 4 文件、RVMapping/Mapping）；**不建议合并 7 项**（全部合并候选）；文档修正 1 项。
- 非 Lua 资源：`shared/Translate/{CN,EN}/UI_{CN,EN}.json`（不参与规模统计）；`client/RailroaderRV/agent.md`、`server/RailroaderRV/agent.md`。

**与既有报告的规模一致性复核（源码实测为准）**

> **快照时点声明（重要）**：本审计开始于 2026-10-01 约 4:01，`docs/module-analysis/` 在该时点正被其它 worker 并发重写。审计过程中观测到 4 份报告在 4:02–4:03 之间落盘（`shared-Common.md`、`shared-RVMapping.md`、`server-WallReloadProtection.md`（新建）、`shared-RoomTemplate.md`），本节的"一致/过期"判定**已按 4:05 的当前内容复核**。仍保持在 2026-09-30 13:45–13:51 未被重写的报告，才被列为过期。

已核对且**一致**（差异仅为匿名闭包计数口径）：`server-Construction.md`（7 文件 2,068 行；逐文件 79/53/146/179/471/324/816 全部吻合）、`server-Core.md`（8 文件 1,685 行，且已在 `:263-264` 主动复核已删除的 `RV_DevSaveSchemaGate.lua`/`RV_Server_ManifestValidation.lua`）、`server-BoundaryGuard.md`（Geometry 388 行）、`server-Power.md`（42/22 计入口径差异已解释）、`server-RoomOwnership.md`（562/31）、`server-Water.md`（`:146-150` 逐文件函数数吻合）、`server-RoofRefresh.md`（131 行）、`client-GUI.md`（11 文件行数 119/134/73/454/292/281/719/269/210/582/145 全部吻合）、`shared-Power.md`、`shared-Water.md`、`server-root.md`、`client-root.md`。
已核对且**逐文件行数全部吻合、但报告自身求和有误**：`server-Common.md:176` 列出 `RV_Common 92 / RV_ServerUtil 50 / RV_ServerTeleport 44 / RV_ServerSchema 157 / RV_ServerWorld 480`（与实测逐项一致），但 `:5` 与 `:176` 均称"5 个文件合计 **762** 行"——**实测合计 823 行**（92+50+44+157+480）。该报告的逐文件数据可用，目录合计不可用。
已核对且**已由并发重写自行修正**（旧数据保留在报告的"旧报告失效项"章节中，属正确做法，不再构成不可靠输入）：`shared-RoomTemplate.md`（`:212` 逐条列出 5 文件→4 文件、`RV_ProtectionManifest.lua` 删除、819→153、415→347、168→247、442→452；`:211` 确认 `RV_ProtectionManifest.lua` 全树 0 命中）、`shared-Common.md`（`:133` 列出 `RV_Bitmap.lua`、`RV_DevSaveSchemaGate.lua` 均已不在文件树，全树 65 个 Lua 文件；`:130-131` 逐文件定义数 3/1/0/6 与实测口径一致）、`shared-RVMapping.md`（`:100` "155 行"、`:104` 逐条否定旧报告的 193 行/15 函数/`exactKeys` 归属）、`server-WallReloadProtection.md`（新建，`:95-97` 的拆分判定见上节）。

**与实测明显不符（保持在 2026-09-30 未被重写；本报告一律以其为不可靠输入）**

| 报告 | 报告声称 | 本次实测 | 性质 |
|---|---|---|---|
| `server-TemplateRecovery.md` | `:5` 目录只有 1 个文件、`:5`/`:142`/`:179`/`:181` "1,729 行"、`:142` 结论"建议拆分"，`:135` 引用 `Common/RV_Bitmap.lua:37`，`:149` 引用 `:1722-1726`，`:162` 引用 `RV_Server_WorldObjects.lua:885-890` | 2 文件 648 行（473 + 175）；`RV_Bitmap.lua` 已删除；上述行号在当前任何文件中都不存在（WorldObjects 仅 816 行、其导出在 `:811-815`） | **过期**（mtime 2026-09-30 13:45）。其"建议拆分"结论已失效，**不得作为拆分依据** |
| `server-RVMapping.md` | `:6` Mapping 620 / EntryExit 811 / Train 623 / RecordValidation 333；`:196` 建议抽 `RoofRefreshIntegration`（引用 `:263-451`、`:396-435`） | 312 / 720 / 623 / 216；`RoofRefreshIntegration` 段落已不存在（当前文件仅 312 行） | **过期**（mtime 09-30 13:47）；除 Train 外全部不符；`:198` 的 "Train 不建议拆" 仍有效 |
| `server-DemolitionProtection.md` | `:216` "当前单文件约 665 行"；`:212` 引用 `BoundaryServer_Geometry.lua:773-784`；`:237` 依赖 Bitmap | 504 行；Geometry 仅 388 行 | **过期**（mtime 09-30 13:45）；其 `:222` "优先把建造意图 ledger 移出" 的方向与本报告的低优先建议一致 |
| `global-summary.md`（主 agent 撰写中，本报告不修改） | `:68` TemplateRecovery "单文件约 1,729 行、75 个函数表达式"并列为**高优先拆分**；`:69` RailroaderContextMenu 762 行 / UtilityDashboard 599 行；`:70` "GenerationAck 中的 RoofRefresh group processor"；`:71` RV_RoomTemplate 819 行、`RV_DevSaveSchemaGate.lua` 1,644 行 | 648 行 / 2 文件；719 / 582；RoofRefresh group processor 已随 `git 89ae61b` 删除；153 行；文件已删除 | **过期**（mtime 09-30 13:45）；其中 `:68` 的"高优先"项在当前源码下不成立 |
| `phase2-structure-optimization.md` | `:17`/`:19`/`:24`/`:37-38`/`:43` 引用 `RV_TemplateRecoveryIndex.lua`、`RV_TemplateRecoveryQueue.lua`、`RV_Server_RoofRelocation.lua`、`RV_Server_RoofApi.lua`、`RoofDestinations.lua`；`:52` 称 StrictSchema 还提供 `exactKeys` | 上述 5 个文件均不存在；`RV_StrictSchema.lua` 只有 `integer` 1 个函数 | **历史文档**（描述合并前结构）。其 `:5`（"按状态所有权和输入合同优化，不按行数拆分"）、`:105`（保留 RailroaderContextMenu）、`:106`（Boundary geometry 不拆）等**规范性判断仍然有效**，本报告据此执行 |

**功能覆盖缺口**

- `server/RailroaderRV/WallReloadProtection/` 的模块报告在本次审计开始后（4:02）才落盘：`server-WallReloadProtection.md` 现已存在（183 行），其 `:95-97` 的拆分判定与本报告一致；本报告对该目录的两项判定均已独立复核，不再视为缺口。
- `client/RailroaderRV/agent.md:3` 仍称"The flat client Lua files retained beside it are forwarding entry points for moved code"，但实测 `client/RailroaderRV/` 下扁平 `.lua` 文件数为 **0**（转发入口已在 `git 19c0894` 删除）；`server/RailroaderRV/agent.md:8` 已更新为"no flat forwarding entries"。该目录说明文档需同步。
- **与兄弟审计报告的分工**：本审计进行期间另有 `audit-duplicate-helpers.md`（4:03）与 `audit-cross-module-access.md`（4:04）落盘。本报告只把"重复 helper 去重"作为**拆分判断的边界代价证据**（`Geometry:13-99` 等）；去重的完整清单与净收益应以其专项报告为准，本报告不重复穷举。
- 未穷举：`ctx` 键的全量生产者/消费者矩阵（本报告只对评估涉及的候选做了精确扫描，如 `EntryExit:713-719`、`WorldObjects:811-815`、`Geometry:378-387`、`Train:595-622`、`RoomOwnership:552-561`）；`shared/Translate/*.json` 与客户端 4 份 `text/tr` 本地化的对应关系。

**未运行验证声明**

- **未运行** `python testserver/run_test.py`，**未启动**游戏、服务器或客户端，**未运行**任何测试脚本，**未修改**任何 `.lua` 源码、配置、测试文件或他人的模块报告。本报告的唯一写入文件是 `docs/module-analysis/audit-module-split.md`。
- 所有"变更频率"结论来自 `git log` 提交计数（仓库根 `C:/Users/ustcy/Desktop/PZ-mod-project`，共 61 个提交），并被最近的合并/精简重构串放大，仅作辅证。
- 所有"状态 owner""接口代价""顺序风险"结论均为**静态源码事实 + 条件性推断**；静态分析不能替代运行时/联机验收。
