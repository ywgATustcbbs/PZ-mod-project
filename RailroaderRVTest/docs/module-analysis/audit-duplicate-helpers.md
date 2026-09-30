# 重复实现与公用功能提取审计

## 审计范围与方法

**事务边界**：本报告只回答一个问题——模块之间哪些功能重复、哪些函数具有通用性、应当提取为公用功能。
本次审计**只读**：未修改任何 `.lua` 源码、配置或测试文件；未运行游戏、服务端或任何测试脚本（未执行 `python testserver/run_test.py`）。本文件是本事务唯一的写入。

**路径约定**：本报告所有 `文件:行` 均相对 `contents/mods/RailroaderRVTest/42/media/lua/`，例如 `server/RailroaderRV/Common/RV_Common.lua:7` 即
`contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_Common.lua:7`。
行号来自本次实际读取（read 工具与 grep 的行号在此树中一致；`Get-Content | Measure-Object -Line` 会少算每个文件的末行，本报告不采用该计数）。

**检索方式**（关键词 + 形状两类，全部实际执行）：

- 形状类：`local function (invoke|finite|call|identityKey|objectModData|safeErrorText|exactKeys|classInstance|toNumber|integer|onlinePlayersSnapshot)`、`local (invoke|finite|call|identity|classInstance|toNumber|isFiniteNumber|integer|snapshot|object|world|player|modData) = `
- 关键词类：`onlinePlayersSnapshot`、`getOnlinePlayers`、`getPlayer`、`Linear`/`RailroaderRVTest`、`MOD_ID`、`\.RailroaderRVTest\b`、`getModData|transmitModData`、`getObjectIndex|getSquare\(`、`instanceof|classInstance|instanceOf`、`identityKey|onlineId|username|\.key\b`、`StrictSchema|exactKeys`、`getWorldAgeHours|getGameTime|GameTime`、`pcall\(function\(\) return`
- 计数类：对 `call(` / `invoke(` / `callGlobal(` / `callSucceeded(` 做逐文件调用点计数（结果见下表「调用点数」列）

**分层约束（贯穿全部结论）**：`shared/` 不得 `require` `server/` 路径；只有「server 单向依赖 shared」与「client 单向依赖 shared」两个方向可行。因此**任何同时被 client、server、shared 三方消费的公用函数只能归属 `shared/`**；反之，只被 server 消费的公用函数可以留在 `server/`。凡建议归属 `shared/` 的项，均已在「建议提取项」中说明它如何避免反向依赖。

**判断口径**：

- **应提取**：存在 ≥2 份真实实现（不是命名别名），且相同部分的契约可以统一，且提取后不缩小现有严格校验。
- **不应提取**：语义差异是**契约性**的（失败返回形状、是否接受非原生 number、是否 error、持久化格式），统一会改变既有行为或削弱校验。
- **暂缓**：重复确实存在，但当前分叉由调用方的失败策略差异驱动，需先统一下游策略。
- 单行命名别名（`local invoke = Util.invoke`、`local call = ctx.call`、`local finiteInteger = C.finiteInteger`）**不计入重复实现**，但在清单中单列并给出「不应提取」判定。

---

## 结论摘要

1. **全树不存在任何被三方共用的「受保护引擎调用」层。** `invoke`/`call` 形状有 **9 份实现**（1 份规范 + 8 份重复），承载 **103 个调用点**；`callGlobal` 3 份、`callSucceeded` 2 份、`instanceof` 检查 4 种写法。各份的差别不是风格：`server/Common/RV_Common.lua:9` 用 `pcall` 保护**属性读取**，而 `shared/Water/RV_UtilityCatalog.lua:67`、`shared/Common/RV_UtilitySprite.lua:15`、`server/.../RV_BoundaryServer_Geometry.lua:39`、4 个 client 文件都直接 `target[method]` 索引，Java 代理在索引阶段抛出时这些调用点会直接冒泡成 Lua 错误。这是本审计中**最有价值、且只有放进 `shared/` 才能被 client/server/shared 同时消费**的提取项。
2. **`modData` 身份标签读取被复制 14 次**（`data.RailroaderRVTest`，另有 2 处写入）：`server/Common/RV_ServerWorld.lua:167` 与 `server/DemolitionProtection/RV_BoundaryServer_Objects.lua:18` 是同名同义的两个 `objectModData`，其余 12 处为内联读取。应提取「读取命名空间 + owner 校验」这一机械部分到 `shared/`；各模块对 `role`/`templateIndex`/`generation` 的**谓词校验必须保留在本地**。
3. **玩家身份三元组 `{username, onlineId, key}` 有 5 套独立构建**（`server/.../RV_BoundaryServer_Geometry.lua:73`、`server/.../RV_RailroaderServer_Train.lua:48`、`server/.../RV_Server_PlayerValidation.lua:103`、`server/.../RV_RailroaderServer_BoundaryValidation.lua:186`、`server/Core/RV_UtilityServer.lua:22`），`key = tostring(onlineId)..":"..name` 另在 6 处手工拼接。注意 `Common.identityKey`（`RV_Common.lua:80`）**不是**这个键——它是长度前缀格式，只服务 RV 身份（`RV_UtilityPowerDevices.lua:191` 等 8 处），不可合并。
4. **`onlinePlayersSnapshot` 有 3 份实现、3 种返回契约**：`RV_BoundaryServer_Sweep.lua:23` 返回 1 个值、`RV_RailroaderServer_Sentinel.lua:79` 返回 1 个值（去重、且 `getPlayer` 兜底），`RV_Server_RoomOwnership.lua:147` 返回 `(list, ok)`。这直接造成「快照不可用」在三处的失败策略不同：Sweep 静默继续、RoomOwnership `error`（`RV_Server_RoomOwnership.lua:235`、`:273`）、Sentinel 兜底单机 `getPlayer`。这是**同一事实的三种语义**，不是三种风格。
5. **数值家族有 12 个私有变体**，而 `shared` 已经有 `C.finiteNumber`/`C.finiteInteger`（`shared/Common/RV_Constants.lua:13`、`:33`）、`StrictSchema.integer`（`shared/Common/RV_StrictSchema.lua:4`）和 `Common.toNumber/isFiniteNumber/integer`（`server/Common/RV_Common.lua:57`、`:67`、`:72`）。语义轴共 4 条：是否接受字符串/Java 包装、返回断言布尔还是可空值、是否拒绝 NaN/±inf、失败时返回 nil 还是 `error`。其中**唯一一处「统一即收紧」的源码事实**：`RV_UtilityStore.integer`（`server/Core/RV_UtilityStore.lua:9-11`）因 `math.floor(math.huge) == math.huge` 而接受 `math.huge`，与 `C.finiteInteger` 不一致。
6. **`RV_StrictSchema` 的能力缺口是事实，不是复用**：该文件共 13 行，只导出 `M.integer`（`RV_StrictSchema.lua:4-11`），**没有 `exactKeys`**；消费者只有 `shared/Water/RV_UtilityCatalog.lua:13` 与 `shared/RVMapping/RV_RegionSlots.lua:21`。全树唯一的 `exactKeys` 是 `server/Water/RV_UtilityWater_Objects.lua:13-23` 的本地实现，仅在 `:60` 使用一次，不做 metatable 检查，用 `pairs` 计数而非 `#value`。历史上「StrictSchema 提供 integer+exactKeys 并被 Water Objects 复用」的说法与当前源码不符，**本报告以当前源码为准**。
7. **`OWNER` 字面量有 3 处硬编码**（`server/Common/RV_ServerWorld.lua:8`、`server/Core/RV_Server.lua:7`、`:8`），而 `C.MOD_ID` 已在 `shared/Common/RV_Constants.lua:39` 定义并被 10 处引用。这是低风险、零争议的提取项（重命名漂移隐患）。
8. **属于「有意别名」而非重复**：`server/Power/RV_UtilityPower.lua:13`、`server/Power/RV_UtilityPowerDevices.lua:16`、`server/Common/RV_ServerUtil.lua:10-18`（9 行）、各 `ctx.*` 注入（`RV_BoundaryServer_Sweep.lua:6-14` 等 7 个文件）、4 个 `local function safeErrorText(...) return ctx.safeErrorText(...) end`（`RV_Server_GenerationAck.lua:9`、`RV_Server_Commands.lua:22`、`RV_Server_RecordValidation.lua:10`、`RV_Server_GenerationFlow.lua:21`）。这些**不应**被当作重复实现处理。

**整体判断**：本树的重复集中在「引擎边界适配层」（调用包装、modData 读取、玩家/世界快照、数值强制转换）。这些正是通用性最强、语义最应当被单点定义的部分，且全部可以在 `shared/` 落地而不违反分层约束。反过来，各模块的**判定策略**（role 集合、templateIndex 交叉校验、失败是 error 还是布尔、持久化键格式）差异真实且必要，不应被「统一」掉。

---

## 重复实现清单

`调用点数` = 本次逐文件正则计数的实际调用点数量（含本文件内调用），不是实现行数。

| # | 重复组 | 各实现位置（文件:行） | 相同点 | 语义差异 | 调用点数 | 判断 | 理由 |
|---|---|---|---|---|---|---|---|
| 1 | `invoke`/`call` 受保护引擎调用 | 规范：`server/Common/RV_Common.lua:7`；重复：`shared/Water/RV_UtilityCatalog.lua:66`、`shared/Common/RV_UtilitySprite.lua:13`、`server/BoundaryGuard/RV_BoundaryServer_Geometry.lua:38`、`server/RVMapping/RV_RailroaderServer_Train.lua:28`、`client/GUI/RV_BoundaryClient.lua:32`、`client/GUI/RV_WardrobeVisuals.lua:20`、`client/GUI/RV_BoundaryWallVisuals.lua:25`、`client/GUI/RV_ProtectedDemolition.lua:18` | 都是「取方法 → 调用 → 返回 `(ok, ...)`」 | ①属性读取是否被 `pcall` 保护：只有 `RV_Common.lua:9` 保护；②返回元数 1/2/3/4：`Catalog` 只回 1 个值，`Sprite`/client 回 2，`Geometry`/`Common` 回 4；③失败第二返回值：`Common`/`Sprite`/`Train` 回 error 对象，`Geometry`/client 回 `nil`；④`Train.call:29` 要求 `type(method)=="string"` 并用 `unpackFn` 包一层闭包 | 103（`call` 78 + `invoke` 20 + `callGlobal` 5，均在上述重复文件内） | **应提取** | 相同部分是纯机械契约；差异部分应以「一个函数 + 明确返回值契约」单点定义，而不是 9 份各自演化。放 `shared/` 是唯一能同时覆盖 client/server/shared 的位置 |
| 2 | `callGlobal` | 规范：`server/Common/RV_Common.lua:37`；重复：`server/BoundaryGuard/RV_BoundaryServer_Geometry.lua:47`、`server/RVMapping/RV_RailroaderServer_Train.lua:36` | `rawget(_G,name)` + 类型检查 + pcall | 返回元数：`Common` 4 值、`Geometry` 4 值、`Train` 直接透传 `pcall` 结果 | 15（全树） | **应提取**（并入项 1） | 与项 1 同属一个引擎边界层，拆开提取会留下两套命名 |
| 3 | `callSucceeded` | 规范：`server/Common/RV_Common.lua:17`；重复：`shared/Common/RV_UtilitySprite.lua:22` | `ok and result ~= false` | 无实质差异 | 83（全树，绝大多数走 `ServerUtil`/`Util` 别名） | **应提取**（并入项 1） | 唯一一处 100% 同义的重复实现，零风险 |
| 4 | `instanceof` 检查 | 规范：`server/Common/RV_Common.lua:50`（`classInstance`，`rawget(_G,"instanceof")`+pcall，失败返 false）；内联：`client/GUI/RV_ProtectedDemolition.lua:43-58`、`:119-123`，`client/GUI/RV_RailroaderContextMenu.lua:117-121`；错层：`server/WallReloadProtection/RV_RailroaderServer_WallReload.lua:133-134` 用 `callGlobal("instanceof", ...)` 绕过 `classInstance` | 都判定 Java 类归属 | `classInstance` 失败返 `false`；`ProtectedDemolition:43` 在 `instanceof` 不存在时整体跳过类检查（**放宽**）；`WallReload:133` 走 `callGlobal` 需要两次 pcall 且返回值形状不同（`(callOk, result)` vs `(bool)`） | 28 个 `classInstance` 家族调用点（`ServerUtil.classInstance` 17：`RV_Server_WorldObjects.lua:120`、`:656`、`:679`、`:767`，`RV_Server_PlayerValidation.lua:35`、`:64`，`RV_ServerWorld.lua:225`、`:233`×2、`:418`、`:422`、`:426`，`RV_Server_Commands.lua:53`，`RV_Server_TemplateProtectionRepair.lua:174`、`:248`、`:294`、`:302`；`Common.classInstance` 2：`RV_BoundaryServer_Objects.lua:134`、`:135`；`Util.classInstance` 别名 9：`RV_UtilityPowerDevices.lua:56`、`:58`、`:60`、`:62`、`:64`、`:66`、`:69`、`:72`、`:300`）+ 内联 5 + `callGlobal` 2 | **应提取** | 应统一到 `classInstance`；`ProtectedDemolition:43` 的「缺函数即跳过」是校验放宽点，迁移时改为失败即返回 false，属于收紧 |
| 5 | `objectModData` / `getModData` 读取 | 命名重复：`server/Common/RV_ServerWorld.lua:167`、`server/DemolitionProtection/RV_BoundaryServer_Objects.lua:18`；内联：`shared/Water/RV_UtilityCatalog.lua:21-23`、`:46-48`、`:86`，`server/WallReloadProtection/RV_RailroaderServer_WallReload.lua:143-144`、`:206`，`server/Water/RV_UtilityWater_Objects.lua:136-137`，`server/Water/RV_UtilityWater_Plumbing.lua:13-14`、`:26-27`，`server/Construction/RV_Server_WorldObjects.lua:451`，`client/GUI/RV_ProtectedDemolition.lua:191-192`、`client/GUI/RV_BoundaryWallVisuals.lua:42-43`、`client/GUI/RV_WardrobeVisuals.lua:48-49` | 「取 modData，非 table 返回 nil」 | ①`RV_ServerWorld`/`RV_BoundaryServer_Objects`/client 走 pcall 包装的 `invoke`/`call`；`RV_UtilityCatalog.lua:21` 直接 `type(object.getModData) ~= "function"` + `pcall(object.getModData, object)`（**索引未保护**，且写法与自身 `:66` 的 `invoke` 不一致）；②`Catalog` 同一文件出现 2 次（`:22`、`:47`），`Plumbing` 出现 2 次（`:13`、`:26`） | 12 个读取点 / 10 个文件 | **应提取** | 机械契约完全一致；提取后 `RV_UtilityCatalog` 内部的不一致写法一并消除 |
| 6 | `data.RailroaderRVTest` 命名空间读取 | 读：`server/Common/RV_ServerWorld.lua:218`、`:321`、`:364`，`server/Construction/RV_Server_WorldObjects.lua:351`、`:646`，`server/DemolitionProtection/RV_BoundaryServer_Objects.lua:27`，`server/WallReloadProtection/RV_RailroaderServer_WallReload.lua:145`、`:207`，`server/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:141`，`server/Power/RV_UtilityPower.lua:59`，`client/GUI/RV_ProtectedDemolition.lua:195`、`client/GUI/RV_BoundaryWallVisuals.lua:44`、`client/GUI/RV_WardrobeVisuals.lua:51`；写：`server/Common/RV_ServerWorld.lua:206`、`server/DemolitionProtection/RV_BoundaryServer_Objects.lua:309` | 同一个 modData 命名空间、同一个 owner | 各处随后做的谓词完全不同：`role` 集合（`WallReload:153`、`BoundaryWallVisuals:49`）、`templateIndex` 交叉校验（`WardrobeVisuals:60`、`BoundaryServer_Objects:159`）、`generation` 范围（`WardrobeVisuals:55`、`UtilityPower:63`）、owner 比较对象（`C.MOD_ID` vs 本地 `OWNER`） | 14 个读取点 + 2 个写入点 | **应提取**（仅读取+owner） | 只统一「读命名空间 + `owner == MOD_ID`」；谓词必须留在本地，否则会把 5 种不同契约压成一个 |
| 7 | 玩家身份三元组 `{username, onlineId, key}` | `server/BoundaryGuard/RV_BoundaryServer_Geometry.lua:55-79`（`playerName`+`playerOnlineId`+`identity`，含 `getPlayerNum` 单机兜底）、`server/RVMapping/RV_RailroaderServer_Train.lua:48-68`（`playerId`+`playerName`，单机兜底返 0，**不建 key**）、`server/Construction/RV_Server_PlayerValidation.lua:103-118`（`playerIdentity`，返回 `false, reason` 而非 nil）、`server/BoundaryGuard/RV_RailroaderServer_BoundaryValidation.lua:186-191`（内联构建）、`server/Core/RV_UtilityServer.lua:22-30`（`playerKey`，用 `getFullName` 兜底与 `"0"`/`"unknown"` 占位）；`key` 手工拼接另见 `:78`、`:116`、`:55`+`:59`、`:188-189`、`RV_RailroaderServer_WallReload.lua:91`、`RV_WallReloadProtection.lua:200` | 都从 `getOnlineID`+`getUsername` 派生稳定身份 | ①失败形状：`Geometry` 返 nil、`PlayerValidation` 返 `false, reason`、`UtilityServer` 返 nil；②`onlineId<0` 是否拒绝（`Geometry:65` 拒绝，`Train:51` 接受）；③key 分隔符与占位符不同（`UtilityServer:29` 用 `"0"`/`"unknown"`）；④`Train` 不产出 key，`EntryExit` 只好只用 `onlineId` | 5 个构建点（`key` 拼接共 6 处） | **应提取** | 稳定玩家身份是全树最基础的契约，5 份实现会让「同名不同 ID」「同 ID 改名」在各模块表现不一致 |
| 8 | `onlinePlayersSnapshot` | `server/BoundaryGuard/RV_BoundaryServer_Sweep.lua:23-45`、`server/Core/RV_RailroaderServer_Sentinel.lua:79-109`（并导出为 `Adapter.onlinePlayersSnapshot`，`:115`、`:189`）、`server/RoomOwnership/RV_Server_RoomOwnership.lua:147-178` | 都是「`getOnlinePlayers` 优先，逐个 `size()`/`get(i)`，支持 table 回退」 | ①返回契约：前两者返 1 值，`RoomOwnership` 返 `(list, ok)`；②去重：只有 Sentinel/RoomOwnership 用 `seen`；③`getPlayer` 兜底条件：Sweep/Sentinel 在「结果为空」时兜底，`RoomOwnership:149` 只在「collection == nil」时兜底（因此 0 在线时也会 `error`，见 `:235`）；④`RoomOwnership:160` 遇到读取失败即 `return result, false` | 6 个外部消费者（`RV_WallReloadProtection.lua:189`、`RV_UtilityServer.lua:141`、`:277`、`RV_RailroaderServer_Tick.lua:27`、`RV_RailroaderServer_Mapping.lua:162-166`、`RV_RailroaderServer_BoundaryValidation.lua:203`）+ 3 个内部调用点 | **应提取** | 这是「同一事实三种语义」的典型；合并时必须保留完整性标志（`list, complete`），否则 `RoomOwnership` 的 fail-closed 会退化为静默 |
| 9 | Java 集合 → Lua 数组枚举 | `server/Common/RV_ServerWorld.lua:31-65`（`collectionSnapshot`，strict/required 两档）、`server/BoundaryGuard/RV_BoundaryServer_Sweep.lua:27-38`、`server/Core/RV_RailroaderServer_Sentinel.lua:83-100`、`server/RoomOwnership/RV_Server_RoomOwnership.lua:155-176`、`client/GUI/RV_UtilityDashboard.lua:54-71`（`collectionItems`，pcall 直接调方法）、`server/Common/RV_ServerWorld.lua:339-357`（`squareContainsObject` 同形状） | `size()` 循环 `get(i)` + table 回退 | ①失败策略：strict 档 `error`/返回 `nil,false,reason`，非 strict 档跳过；②`RV_UtilityDashboard:57` 用 `type(collection.size)=="function"` 预检（**索引未保护**）而 server 侧用 `invoke`；③是否要求 size 为整数（`ServerWorld:42` 用 `toNumber`+floor，`Sweep:28` 用 `integer`） | 6 个循环点 | **暂缓** | 重复真实，但分叉由「失败是致命还是可跳过」驱动；应先落项 1，让所有调用点共享一个受保护的 `size/get` 原语，再评估是否值得再抽一层 |
| 10 | 数值转换 / 有限性判定家族 | 共享已有：`shared/Common/RV_Constants.lua:13`（`finiteNumber`）、`:33`（`finiteInteger`）、`shared/Common/RV_StrictSchema.lua:4`（`integer`）；规范：`server/Common/RV_Common.lua:57`（`toNumber`）、`:67`（`isFiniteNumber`）、`:72`（`integer`）、`server/Common/RV_ServerUtil.lua:20`（`requiredNumber`）、`:28`（`requiredInteger`）；私有变体：`server/BoundaryGuard/RV_BoundaryServer_Geometry.lua:13`、`:23`、`:29`，`server/RVMapping/RV_RailroaderServer_Train.lua:7`、`:22`，`client/GUI/RV_BoundaryClient.lua:16`、`:26`，`server/Construction/RV_Server_WorldObjects.lua:10`，`server/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:20`，`server/Core/RV_UtilityStore.lua:9`、`:13`、`:36`，`server/Power/RV_UtilityPower.lua:17`，`shared/RoomTemplate/RV_TemplateGeometry.lua:31`、`:36`，`shared/RoomTemplate/RV_RoomTemplate.lua:17` | 都是「把值变成可用的 number」 | ①是否接受 string/Java 包装：`RV_Common.toNumber:57-65`、`C.finiteNumber:16-25`、`Geometry.number:13-21`、`Train.number:7-20`、`WorldObjects.integer:11` 接受；`isFiniteNumber`、`StrictSchema.integer`、`TemplateGeometry.finiteNumber`、`RoomTemplate.integer`、`UtilityStore.integer/number` **只接受原生 number**；②返回断言布尔还是可空值（`TemplateGeometry:31`/`RoomTemplate:17` 返回布尔，其余返回 `nil|number`）；③是否拒绝 NaN/±inf（`UtilityStore.integer:10`、`:14` **不拒绝**）；④失败是否 `error`（`requiredNumber/Integer`） | 全部数值入口（`toNumber` 类 30+ 处，本次抽样覆盖 12 个变体文件） | **应提取**（部分） | `WorldObjects.integer:10-18` 与 `TemplateProtectionRepair.integer:20-28` 是**逐字节同义**；`UtilityStore.waterInteger:36-40` ≡ `C.finiteInteger`；`Geometry` 三个变体可由 `toNumber`+`C.finiteNumber` 组合得到。但「原生严格 vs 强制转换」两轴必须保留两个具名函数，见「不应提取」B3 |
| 11 | `getObjectIndex` + 整数化 | `server/DemolitionProtection/RV_BoundaryServer_Objects.lua:139-140`、`server/Construction/RV_Server_WorldObjects.lua:421-423`、`:431-433`、`:534-536`、`server/Water/RV_UtilityWater_Objects.lua:75-76`、`server/Power/RV_UtilityPowerDevices.lua:172-175`（已封成 `objectIndex`）、`server/WallReloadProtection/RV_RailroaderServer_WallReload.lua:139-141`、`client/GUI/RV_ProtectedDemolition.lua:109-112`、`client/GUI/RV_UtilityClient.lua:95-101` | 「读 `getObjectIndex`，取整，`< 0` 视为无效」 | ①整数化器不同（`integer` vs `ServerUtil.toNumber`+floor vs `C.finiteInteger`）；②`WorldObjects:421-423` 与 `:534-536` 返回 `>= 0` 判定，`BoundaryServer_Objects:140` 要求 `integer(index) >= 0`，`UtilityPowerDevices:174` 只做整数化不判负；③`RV_UtilityClient:95` 额外要求 `getSquare`/`getObjectIndex` 都是 function | 9 处 / 7 个文件 | **应提取** | 这是「一个 Java 事实、9 种取值方式」，且 `<0` 判定在内联处极易漏写；`UtilityPowerDevices.objectIndex` 已是正确形态，可作为提取原型 |
| 12 | 方块/对象坐标三元组读取 | `server/DemolitionProtection/RV_BoundaryServer_Objects.lua:34-56`（`objectSquare`+`objectCell`，含 object 回退）、`server/Power/RV_UtilityPowerDevices.lua:161-170`（`squareCoordinates`）、`server/BoundaryGuard/RV_BoundaryServer_Geometry.lua:338-348`（`currentSquareMatches`）、`:81-99`（`playerPosition`，含 RV 区域判定）、`server/RVMapping/RV_RailroaderServer_Train.lua:75-85`（`playerPosition`）、`server/Construction/RV_Server_PlayerValidation.lua:22-32`（`readPlayerCoordinate`，失败 `error`）、`server/Water/RV_UtilityWater_Objects.lua:47-53`（`withinReach` 内的玩家坐标读取）、`client/GUI/RV_ProtectedDemolition.lua:29-40`（`objectCoordinates`）、`client/GUI/RV_UtilityClient.lua:96-103`（对象+index hint）、`client/GUI/RV_ContextMenu_RoomOwnership.lua:75-77` | 「`getX/getY/getZ` → 有限化」 | ①整数化 vs 保留小数；②失败形状：nil / `error` / 布尔；③是否附带策略（`Geometry:89-97` 附带 RV 区域判定，`UtilityWater_Objects:46-57` 附带 reach 判定） | 10 处 | **应提取**（仅纯坐标部分） | 机械部分（对象/方块 → xyz）应统一；带策略的 `playerPosition` 变体应调用统一原语后再各自施加策略 |
| 13 | 坐标键字符串 | `shared/RoomTemplate/RV_RoomTemplate.lua:23-25`（`cellKey`，`":"`）、`shared/RoomTemplate/RV_Layout.lua:42`、`server/Construction/RV_Server_GenerationBuild.lua:53`、`server/Core/RV_Server_Commands.lua:103`、`server/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:30-32`（**逗号**分隔的 `coordinateKey`）、`client/GUI/RV_ContextMenu_RoomOwnership.lua:118`、`:157`、`server/Power/RV_UtilityPowerDevices.lua:178-180`（4 段 `deviceId`）、`:194`（带尾随 `:` 的前缀）、`server/Core/RV_UtilityStore.lua:42-45`（`string.format("%d:%d:%d")`） | 「把 (x,y,z) 变成稳定字符串」 | 3 种分隔符格式（`":"`、`","`、`string.format`），两种用途：进程内比较/查找 vs **持久化 ModData 键** | 9 处 | **应提取**（仅进程内比较用途；持久化键见 B2） | 前 8 处是同一用途的同一格式，提取后 `TemplateProtectionRepair:30` 的逗号格式统一可消除「同点不同键」隐患 |
| 14 | `OWNER`/`MOD_ID` 字面量 | 规范：`shared/Common/RV_Constants.lua:39`；硬编码重复：`server/Common/RV_ServerWorld.lua:8`、`server/Core/RV_Server.lua:7`、`:8`；已正确引用 `C.MOD_ID` 的 10 处：`server/BoundaryGuard/RV_BoundaryServer.lua:33`、`server/WallReloadProtection/RV_RailroaderServer_WallReload.lua:18`、`shared/Water/RV_UtilityCatalog.lua:26`、`server/Water/RV_UtilityWater_Objects.lua:143`、`client/GUI/RV_WardrobeVisuals.lua:53`、`client/GUI/RV_BoundaryWallVisuals.lua:46`、`client/GUI/RV_ProtectedDemolition.lua:80`、`:203`、`server/WallReloadProtection/RV_WallReloadProtection.lua:149`、`server/Core/RV_Server_Commands.lua:324` | 同一个命名空间标识 | 无（纯字面量复制） | 3 处 | **应提取** | 零风险；`RV_ServerWorld.OWNER` 与 `C.MOD_ID` 命名空间比较（`:219`、`:322`、`:365`）一旦与 `tagObject` 写入值漂移即静默失配 |
| 15 | `safeErrorText` | 规范：`server/Construction/RV_Server_GenerationBuild.lua:16-32`（`pcall(tostring)` + `debug.traceback`，并 `ctx.safeErrorText = safeErrorText` 于 `:178`）；ctx 转发别名：`server/Construction/RV_Server_GenerationAck.lua:9`、`server/Core/RV_Server_Commands.lua:22`、`server/RVMapping/RV_Server_RecordValidation.lua:10`、`server/Construction/RV_Server_GenerationFlow.lua:21`；内联回退：`server/Common/RV_ServerSchema.lua:123-126` | 「把任意错误值转成可打印字符串」 | 4 个转发别名是**有意别名**（延迟查 `ctx`，因此不受 `RV_Server.lua:143`-`:150` 的 require 顺序影响）。`ServerSchema:123-126` 是默认参数回退：无 traceback、回退文案不同（`"<error formatting failed>"`） | 5 个使用位置共 25 处调用（`GenerationFlow` `:158`、`:248`、`:279`、`:318`；`Ack` `:73`、`:96`、`:116`、`:123`；`Commands` `:176`、`:217`、`:259`、`:275`、`:288`、`:294`、`:310`、`:313`、`:337`、`:350`、`:357`、`:362`、`:368`、`:373`、`:405`；`RecordValidation` `:150`、`:207`）+ 1 处内联（`ServerSchema:123-126`，并经 `:217` 作为参数传入） | **暂缓** | 别名不是重复实现，不应动；`ServerSchema` 的内联回退与规范版并存是真实的双实现，但替换会把单行消息变成多行 traceback，收益低，见「暂缓」C2 |
| 16 | `getCellForPlayer`/`getSquare` 薄包装 | 规范：`server/Common/RV_ServerWorld.lua:11-21`、`:23-29`；重复：`server/BoundaryGuard/RV_BoundaryServer_Geometry.lua:135-140`（`playerCell`）、`:142-146`（`square`） | 都是「取 cell，取不到退 `getCell()`」/「`cell:getGridSquare(x,y,z)`」 | `RV_ServerWorld.getCellForPlayer:20` **无 cell 时 `error`**；`Geometry.playerCell:139` 返回 `nil`。`square` 两者**完全同义**（都返回 `ok and result or nil`） | 4（Geometry 内 `playerCell:136`、`:138`；`square:144`；消费者 `Sweep.lua:11`、`Objects.lua:11`） | **应提取** | `square` 可直接替换为 `ServerWorld.getSquare`；`getCellForPlayer` 需保留两种失败策略，因此建议在 `RV_ServerWorld` 增加 `findCellForPlayer`（返 nil）并让 `getCellForPlayer` 保留 error。依赖方向为 server→server，不违反分层约束 |
| 17 | 客户端 `localPlayerByOnlineId` | `client/GUI/RV_BoundaryClient.lua:41-59`、`client/GUI/RV_RailroaderContextMenu.lua:28-52`、`client/GUI/RV_ContextMenu_RoomOwnership.lua:23-32` | 「按 onlineId 反查本地 IsoPlayer」 | ①单机兜底策略：`BoundaryClient:45` 回退 `getPlayerNum`、`RailroaderContextMenu:50` 在 `onlineId==0` 时回退槽位 0、`RoomOwnership:23` **无兜底**；②索引保护：`RailroaderContextMenu:43` 用 pcall 包住 `getOnlineID`，另两者直接调用 | 3 个实现 + 消费者（`RV_ContextMenu_Relocation.lua:16` 用 `ctx.localPlayerByOnlineId`） | **暂缓** | 分叉点是「单机该不该兜底」这一策略，不是机械代码；需先定一个客户端策略，见「暂缓」C3 |
| 18 | `StrictSchema.exactKeys` 归属缺口 | 实现：`server/Water/RV_UtilityWater_Objects.lua:13-23`；消费：同文件 `:60`；`shared/Common/RV_StrictSchema.lua:1-13` 只导出 `integer` | —（全树仅 1 份） | ①不做 metatable 检查；②用 `pairs` 计数 + `allowed` 白名单，允许 `expected` 有重复项时误判；③位于 `server/` 而 `StrictSchema` 位于 `shared/`，方向正确（server→shared）但归属错位 | 1 个调用点 | **应提取** | 这是「本应公用但被就地实现」的形式；`exactKeys` 是纯函数、无 server 依赖，归属 `shared/Common/RV_StrictSchema.lua` 才符合文件既有职责。**不得**为兼容旧调用而在 Water Objects 保留第二份 |
| 19 | `Common.identityKey` vs 玩家 `"id:name"` 键 | `server/Common/RV_Common.lua:80-90`（长度前缀、任一 nil 即 nil）vs `key = tostring(onlineId)..":"..name` 6 处（`RV_BoundaryServer_Geometry.lua:78`、`RV_Server_PlayerValidation.lua:116`、`RV_RailroaderServer_BoundaryValidation.lua:55`、`:59`、`:188-189`、`RV_RailroaderServer_WallReload.lua:91`、`RV_WallReloadProtection.lua:200`） | 都产出「稳定身份字符串」 | 格式不同（`3:abc|1:5` vs `5:abc`）、nil 语义不同（`identityKey` 遇 nil 返 nil，玩家键用占位符）、消费者不同（RV 身份 vs 玩家身份） | `identityKey` 8 个调用点（`RV_UtilityPowerDevices.lua:191`、`:269`、`:277`、`:316`、`:333`、`:341`、`:353`、`:360`） | **不应提取** | 见「不应提取」B1：统一会改变 RV 缓存键并吞掉 `identityKey` 的 nil 语义 |
| 20 | `RV_UtilityStore.waterSinkKey` 持久化键 | `server/Core/RV_UtilityStore.lua:42-45`（`%d:%d:%d`，导出为 `M.waterSinkKey:163-165`）vs 项 13 的进程内坐标键 | 都是坐标三元组键 | 用 `string.format("%d")` 生成**已持久化的 ModData 子键**：消费者为 `server/Water/RV_UtilityWater_Ledger.lua:13`（`M.sinkKey`），其产物经 `RV_UtilityWater_Ledger.lua:19`（`water.sinks[key]`）进入 `RV_UtilityStore.newWater` 的 `sinks` 表（`RV_UtilityStore.lua:68-71`），再由 `M.commit:132` 随 `record` 写入 ModData | 1 个消费者（`RV_UtilityWater_Ledger.lua:13`，另有 `:17` 通过 `M.sinkKey` 间接使用） | **不应提取** | 见「不应提取」B2：统一会改变已持久化键格式，收益为零 |
| 21 | `safeErrorText` 的 4 个 ctx 转发别名 | `RV_Server_GenerationAck.lua:9`、`RV_Server_Commands.lua:22`、`RV_Server_RecordValidation.lua:10`、`RV_Server_GenerationFlow.lua:21` | 逐字节同形 | 无（都是 `return ctx.safeErrorText(...)`） | 25（4 文件内 `safeErrorText(...)` 调用点：`GenerationFlow` 4、`Ack` 4、`Commands` 15、`RecordValidation` 2） | **不应提取** | 见「不应提取」B6：这是 ctx 注入模式的有意别名，与 `local call = ctx.call` 同类；统一为直接 `require` 会破坏既有的依赖注入结构 |

---

## 建议提取项

以下 12 项建议提取。全部提取项都遵守分层约束：**只有当 client 与 server 都消费时才归属 `shared/`**，且 `shared/` 侧不得出现 `require("RailroaderRV/<server 路径>")`。

### E1. `shared/RailroaderRV/Common/RV_SafeCall.lua`（对应清单 1、2、3、4）

- **接口**
  - `M.invoke(target, method, ...) -> ok, ... | false, err`（最多 4 个成功返回值，与 `RV_Common.lua:7-15` 完全一致）
  - `M.callSucceeded(target, method, ...) -> boolean`
  - `M.callGlobal(name, ...) -> ok, ... | false, err`
  - `M.callGlobalSucceeded(name, ...) -> boolean`
  - `M.classInstance(object, className) -> boolean`
- **建议归属层**：`shared/`。理由：这 5 个函数的消费者跨三层——`shared/Water/RV_UtilityCatalog.lua:66`、`shared/Common/RV_UtilitySprite.lua:13`、`client/GUI/*`（4 文件）、`server/**`（4 文件）。放在 `server/Common/RV_Common.lua` 会让 client 无法消费（client 不得 require `server/`）；放在 client 同理。`shared/` 是唯一可行层，且这 5 个函数只依赖 `pcall`/`rawget`/`_G`，无 server 依赖。
- **消费者与迁移范围**（8 份重复实现 → 0）：
  1. `shared/Water/RV_UtilityCatalog.lua:66-70` 删除本地 `invoke`，改用 `M.invoke`；注意其调用点 `:73`、`:75`、`:79`、`:86`、`:91` 都写成 `ok and ...`，与统一后的 `false, err` 失败形状兼容，**无需改调用点**。
  2. `shared/Common/RV_UtilitySprite.lua:13-20`、`:22-25` 删除本地两函数；调用点 `:31`、`:33`、`:36-37`、`:40`、`:46`、`:53`、`:56`、`:61`、`:67`、`:69`、`:72`、`:77`、`:96` 共 14 处 `invoke` + 4 处 `callSucceeded` 全部保持写法不变（统一版返回更多值不影响既有绑定）。
  3. `server/BoundaryGuard/RV_BoundaryServer_Geometry.lua:38-45`、`:47-53` 删除，改 `ctx.call = SafeCall.invoke`、`ctx.callGlobal = SafeCall.callGlobal`（保持 `ctx.*` 注入接口不变，`RV_BoundaryServer_Sweep.lua:7-8`、`RV_BoundaryServer_Objects.lua:9` 无需改动）。
  4. `server/RVMapping/RV_RailroaderServer_Train.lua:28-34` 删除，改 `ctx.call = SafeCall.invoke`（消费者 `RV_RailroaderServer_WallReload.lua:20`、`RV_RailroaderServer_EntryExit.lua:15` 等 5 个文件的 `local call = ctx.call` 别名不变）。
  5. `client/GUI/RV_BoundaryClient.lua:32-39`、`RV_WardrobeVisuals.lua:20-27`、`RV_BoundaryWallVisuals.lua:25-32`、`RV_ProtectedDemolition.lua:18-25` 删除本地 `call`，改 `require` 共享模块。
  6. `server/Common/RV_Common.lua:7-55` 改为转发 `SafeCall.*`（保留 `Common.*` 名字，`RV_ServerUtil.lua:10-18`、`RV_ServerTeleport.lua:7-8`、`RV_ServerWorld.lua` 全部零改动）。
  7. 顺带统一 `server/WallReloadProtection/RV_RailroaderServer_WallReload.lua:133-134` 的 `callGlobal("instanceof", ...)` 为 `classInstance`；`client/GUI/RV_ProtectedDemolition.lua:43-58`、`:119-123` 与 `client/GUI/RV_RailroaderContextMenu.lua:117-121` 的内联 `instanceof` 改为 `classInstance`。
- **风险与前置条件**：
  - **行为收紧点（须显式确认）**：统一到「保护属性读取」后，`RV_ProtectedDemolition.lua:43` 的「`instanceof` 不存在则跳过类检查」会变成「不存在则 `false`」，即 demolish 保护从放宽转为收紧。这是**收紧**，符合「不得放宽校验」，但会改变 `instanceof` 缺失环境下的菜单行为。
  - **调用点兼容性**：统一版失败时返回 `(false, err)` 而非 `(false, nil)`。已核对全部 8 份实现的调用点写法，均为 `ok and ...` 或只取首值，无一处依赖「失败第二值为 nil」。
  - `Train.call:29` 额外要求 `type(method)=="string"`；统一版签名是 `(target, name, ...)` 且用 `target[name]`——若调用方传入非字符串 name，统一版会走 `pcall` 索引并按失败处理，语义等价或更严。`Train.call:30-33` 的 `unpackFn` 包装在 Lua 5.1/Kahlua 下与直接 `...` 传递等价，可安全丢弃。
  - 前置：`shared/Common/RV_UtilitySprite.lua` 目前有 14 处 `invoke`，是本次单个改动面最大的文件，建议单独一步迁移并单独验证（`RV_UtilitySprite.install:102-110` 在 `OnGameBoot` 上注册，任何回归都会影响启动期精灵注册）。

### E2. `shared/RailroaderRV/Common/RV_ObjectTag.lua`（对应清单 5、6）

- **接口**
  - `M.TAG_KEY = "RailroaderRVTest"`（值取自 `shared/Common/RV_Constants.lua:39`，不新写字面量）
  - `M.modData(object) -> table | nil`（受保护读取 `getModData`，非 table 返 nil）
  - `M.read(object) -> table | nil`（`modData` + 取 `TAG_KEY` + `type(tag)=="table"`）
  - `M.isOwned(tag) -> boolean`（`type(tag)=="table" and tag.owner == C.MOD_ID`）
- **建议归属层**：`shared/`。`RV_UtilityCatalog`（shared）与 client 三个文件都读取同一命名空间；`server/Common/RV_ServerWorld.lua` 是唯一写入者，写入函数 `tagObject:178-211` **必须留在 server**（它调用 `transmitModData` 附近的写入语义与 server 事务绑定）。因此拆分是「读取到 shared，写入留 server」，方向为 server→shared，合法。
- **消费者与迁移范围**（12 处 `getModData` 读取中的 10 处 + 2 个命名 `objectModData`）：
  - 删除 `server/Common/RV_ServerWorld.lua:167-173`，改 `M.modData`；`RV_ServerWorld.lua:217`、`:317`、`:363` 的 `data and data.RailroaderRVTest` 改 `M.read`；`:213-222`（`isTaggedForGeneration`）的 `owner` 比较改 `M.isOwned`。
  - 删除 `server/DemolitionProtection/RV_BoundaryServer_Objects.lua:18-21`，`rvTag:25-32` 改为 `M.read` + `M.isOwned`（role 谓词保留在 `:28` 之后）。
  - `server/WallReloadProtection/RV_RailroaderServer_WallReload.lua:143-145`、`:206-207` 改 `M.modData`/`M.read`（role 判定 `:152-154` **保留**）。
  - `client/GUI/RV_ProtectedDemolition.lua:191-195`、`RV_BoundaryWallVisuals.lua:42-44`、`RV_WardrobeVisuals.lua:48-51` 改 `M.modData`/`M.read`（各自的 `templateIndex`/`role` 交叉校验**保留**）。
  - `server/Common/RV_ServerWorld.lua:8` 的 `local OWNER` 删除，改 `C.MOD_ID`（与 E10 合并执行）。
- **风险与前置条件**：唯一行为变化是 `shared/Water/RV_UtilityCatalog.lua:21`、`:46` 从「未保护索引」变为「受保护读取」——收紧，不放松。`RV_UtilityCatalog` 的 `tagForObject:20-33`（role=="sink"、rvId 为非空 string、generation>=1、slotIndex 为整数）与 `hasSinkIdentity:45-49` 是**水槽专用谓词，不在提取范围**。

### E3. `shared/RailroaderRV/Common/RV_PlayerIdentity.lua`（对应清单 7）

- **接口**
  - `M.read(player) -> { username = string, onlineId = number, key = string } | nil, reason`
  - `M.onlineId(player) -> number | nil`
  - `M.username(player) -> string | nil`
  - `M.key(rvIdOrOnlineId, name) -> string`（**保留 `tostring(onlineId)..":"..name` 这一既有格式**，不引入新格式）
- **建议归属层**：`shared/`。消费者包含 client（`RV_BoundaryClient`）与 server（5 处），且不得依赖 `server/Common/RV_ServerUtil`。
- **消费者与迁移范围**：`RV_BoundaryServer_Geometry.lua:55-79`（保留 `playerOnlineId` 的 `processIsServer` 单机兜底策略为调用方适配）、`RV_RailroaderServer_Train.lua:48-68`、`RV_Server_PlayerValidation.lua:103-118`（`false, reason` 形状由调用方在 `M.read` 之上保留）、`RV_RailroaderServer_BoundaryValidation.lua:186-191`、`RV_UtilityServer.lua:22-30`（`getFullName` 兜底与 `"0"`/`"unknown"` 占位须显式决定是否保留——**这是本项的开放决策点**，建议保留为调用方传入的 fallback 参数，而不是写进公用函数）。
- **风险与前置条件**：`onlineId < 0` 的接受度在 `Geometry:65`（拒绝）与 `Train:51`（接受）不同；统一前必须确认 `Train` 的宽松是否为 `EntryExit` 所需（`RV_RailroaderServer_EntryExit.lua:56`、`:141`、`:298`、`:427`、`:651` 都依赖 `playerId` 非 nil，SP 场景下 `getOnlineID` 可能返回 -1/0）。**条件性推断**：若 `EntryExit` 在 SP 下依赖宽松分支，则 `M.read` 必须暴露 `allowNegativeId` 选项，否则 SP 入口会拒绝进入。
- 不得把 `Common.identityKey`（`RV_Common.lua:80`）当作本接口的 `key`：格式与 nil 语义都不同（见 B1）。

### E4. `server/RailroaderRV/Common/RV_PlayerSnapshot.lua`（对应清单 8）

- **接口**：`M.onlinePlayers() -> list, complete`（`complete=false` 表示枚举中断；`list` 已去重、已按 `getPlayer` 兜底）
- **建议归属层**：`server/`。三个实现全在 server，client 无消费者（client 侧只有 `RV_RailroaderContextMenu.lua:34-52` 的**按 ID 反查**，不同问题）。归属 `server/Common/` 与 `RV_ServerWorld`/`RV_ServerUtil` 同级。
- **消费者与迁移范围**：
  - `server/Core/RV_RailroaderServer_Sentinel.lua:79-109` 改为转发（`:115-117` 的 `Adapter.onlinePlayersSnapshot` 与 `:189` 的 `ctx.onlinePlayersSnapshot` 接口保持不变，因此 `RV_RailroaderServer_Mapping.lua:162-166`、`RV_RailroaderServer_Tick.lua:27`、`RV_WallReloadProtection.lua:189`、`RV_UtilityServer.lua:141`、`:277`、`RV_RailroaderServer_BoundaryValidation.lua:203` 全部零改动）。
  - `server/BoundaryGuard/RV_BoundaryServer_Sweep.lua:23-45` 删除，`ctx.onlinePlayersSnapshot = Snapshot.onlinePlayers`（`:115` 调用点需要从「1 值」改为「2 值」绑定或忽略第二值）。
  - `server/RoomOwnership/RV_Server_RoomOwnership.lua:147-178` 删除，`:198`、`:233` 的 `(players, snapshotOk)` 直接改成统一接口的第二返回值，`:235`、`:273` 的 `error` 保留（**fail-closed 语义必须保留**）。
- **风险与前置条件**：三个实现的 `getPlayer` 兜底条件不同（空结果 vs collection==nil）。统一必须选定**更保守**的一侧：建议「`getOnlinePlayers` 存在但枚举为空 或 枚举失败」都尝试 `getPlayer` 兜底，并把「枚举中断」通过 `complete=false` 上报，由 `RoomOwnership` 决定 `error`。这样 Sweep/Sentinel 从「静默」变为「可感知」，属收紧。

### E5. `shared/RailroaderRV/Common/RV_Number.lua`（对应清单 10 的强制转换子集）

- **接口**
  - `M.toNumber(value) -> number | nil`（接受 number/string/Java 包装，与 `RV_Common.lua:57-65` 逐字节一致）
  - `M.finiteNumber(value) -> number | nil`（`toNumber` 后拒绝 NaN/±inf；与 `C.finiteNumber` 一致）
  - `M.finiteInteger(value) -> number | nil`（`finiteNumber` 后要求整数；与 `C.finiteInteger` 一致）
  - `M.isFiniteNumber(value) -> boolean`（**只接受原生 number**，与 `RV_Common.lua:67-70` 一致——两条语义轴各自具名，见 B3）
- **建议归属层**：`shared/`。理由：`shared/RoomTemplate/RV_TemplateGeometry.lua:31-38`、`shared/RoomTemplate/RV_RoomTemplate.lua:17-21`、`shared/Common/RV_Constants.lua:13-37` 都是 shared 内的数值逻辑，server 与 client 都要消费。
- **消费者与迁移范围（可无歧义迁移的 6 个变体）**：
  - `server/Construction/RV_Server_WorldObjects.lua:10-18`、`server/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:20-28`（两者逐字节同义）→ `M.finiteInteger`
  - `server/Core/RV_UtilityStore.lua:9-11`（`integer`）→ `M.finiteInteger`（**收紧**：不再接受 `math.huge`）；`:13-15`（`number`）→ `M.finiteNumber`（**收紧**：不再接受 NaN/±inf）；`:36-40`（`waterInteger`）→ `M.finiteInteger`
  - `server/BoundaryGuard/RV_BoundaryServer_Geometry.lua:13-36` 三个函数 → `M.toNumber` / `M.finiteInteger` / `M.finiteNumber`
  - `server/RVMapping/RV_RailroaderServer_Train.lua:7-26`、`client/GUI/RV_BoundaryClient.lua:16-30` → 同上
  - `server/Power/RV_UtilityPower.lua:17-20`（`finite` 谓词）→ `M.finiteNumber(v) ~= nil`
  - `shared/Common/RV_Constants.lua:13-37` 的 `C.finiteNumber`/`C.finiteInteger` 改为转发（保留 `C.*` 名字，`RV_Constants.lua` 的 30+ 消费点零改动）
  - `server/Common/RV_Common.lua:57-78` 的 `toNumber`/`isFiniteNumber`/`integer` 改为转发
- **风险与前置条件**：
  - **收紧点必须逐处确认**：`RV_UtilityStore.integer` 当前接受 `math.huge`（源码事实：`math.floor(math.huge) == math.huge` 为真），`identityValid:31-33` 与 `getRecord:109-111`、`commit:123-125`、`:124` 都用它校验 `generation`。迁移后 `generation = math.huge` 会被拒绝并返回 `C.INVALID_RV_DATA`。**条件性推断**：从 Lua 网络表或 ModData 传入双精度 `inf` 才可能触达，正常 generation 是 1..N，因此实际可观测差异应为零；但严格说这是行为变更，应作为独立一步并列入验收点。
  - **不得迁移**：`RV_ServerUtil.requiredNumber/Integer:20-35`（error 语义，见 B5）、`RV_StrictSchema.integer`（原生严格，见 B3）。

### E6. `shared/RailroaderRV/Common/RV_ObjectProbe.lua`（对应清单 11、12）

- **接口**
  - `M.objectIndex(object) -> number | nil`（`getObjectIndex` 失败或 `<0` 返 nil；已存在于 `server/Power/RV_UtilityPowerDevices.lua:172-175` 的原型）
  - `M.squareCoordinates(square) -> x, y, z | nil`
  - `M.objectCoordinates(object) -> x, y, z, square | nil`（先试 `getSquare`，再回退 object 自身坐标，形态取自 `RV_BoundaryServer_Objects.lua:34-56`）
- **建议归属层**：`shared/`。`client/GUI/RV_UtilityClient.lua:95-103`、`client/GUI/RV_ProtectedDemolition.lua:29-40`、`client/GUI/RV_ContextMenu_RoomOwnership.lua:75-77` 与 5 个 server 文件同用。
- **消费者与迁移范围**：清单 11 的 9 处 + 清单 12 的「纯坐标」7 处（`RV_BoundaryServer_Objects:34-56`、`RV_UtilityPowerDevices:161-170`、`RV_BoundaryServer_Geometry:338-348`、`RV_ProtectedDemolition:29-40`、`RV_UtilityClient:96-103`、`RV_ContextMenu_RoomOwnership:75-77`、`RV_UtilityWater_Objects:47-53` 内的坐标读取部分）。带策略的 `playerPosition`（`RV_BoundaryServer_Geometry:81-99`、`RV_RailroaderServer_Train:75-85`、`RV_Server_PlayerValidation:22-32`、`RV_UtilityWater_Objects:47-57`）**只把坐标读取部分**替换为共享原语，RV 区域判定/reach 判定/`error` 语义留在原位。
- **风险与前置条件**：`objectIndex` 统一为「`<0` 即 nil」后，`RV_UtilityPowerDevices.lua:174` 由「只整数化」变为「额外判负」——这是收紧；`deviceId:177-180` 使用 `device.objectIndex or 0`，仍兼容。`RV_UtilityClient.lua:95-101` 使用 `pcall(function() ... end)` 方法调用式而非 `target[method]`，迁移到 `SafeCall`（E1）后索引保护更强，无回归风险。

### E7. `shared/RailroaderRV/Common/RV_CoordinateKey.lua`（对应清单 13 的进程内用途）

- **接口**：`M.key(x, y, z) -> string`（固定 `tostring(x)..":"..tostring(y)..":"..tostring(z)`）、`M.prefix(x, y, z) -> string`（带尾随 `:`，服务 `RV_UtilityPowerDevices.lua:194` 的前缀匹配）
- **建议归属层**：`shared/`。`shared/RoomTemplate/RV_RoomTemplate.lua:23-25`、`shared/RoomTemplate/RV_Layout.lua:42` 已在 shared 内使用该格式。
- **消费者与迁移范围**：`RV_RoomTemplate.lua:23-25`、`RV_Layout.lua:42`、`RV_Server_GenerationBuild.lua:53`、`RV_Server_Commands.lua:103`、`RV_ContextMenu_RoomOwnership.lua:118`、`:157`、`RV_UtilityPowerDevices.lua:178-180`（4 段 deviceId，需专用 `deviceKey`）、`:194`（prefix）+ `TemplateProtectionRepair.lua:30-32`（逗号格式，改为统一格式需确认该键仅进程内使用——**已在本次审计中确认它是每进程重建的 `entriesByCell` 子键，不写入 ModData**）。
- **风险与前置条件**：**不得**纳入 `RV_UtilityStore.waterSinkKey:42-45`（持久化键，见 B2）。

### E8. `RV_UtilityStore.waterSinkKey` 之外——`OWNER` 字面量收敛（对应清单 14）

- **做法**：`server/Common/RV_ServerWorld.lua:8` 改为 `local OWNER = require("RailroaderRV/Common/RV_Constants").MOD_ID`；`server/Core/RV_Server.lua:7`、`:8` 改为从已加载的 `Constants` 取（该文件 `:49` 已有 `Constants`，`loadModule` 有全局回退，需确认回退分支下 `Constants.MOD_ID` 可用——**条件性推断**：`:37-40` 的 `loadModule` 回退只映射 `Constants`/`Layout` 两个嵌套名，`MOD_ID` 在其中，可用）。
- **风险**：`RV_ServerWorld` 目前不 require `RV_Constants`（只 require `RV_ServerUtil`）。新增一个 shared require 不违反分层约束（server→shared）。若担心 `RV_Server.lua:54-57` 的「Boundary 加载失败仍继续」路径，此处无影响。

### E9. `shared/Common/RV_StrictSchema.lua` 补齐 `exactKeys`（对应清单 18）

- **接口**：`M.exactKeys(value, expected) -> boolean`，契约按 `server/Water/RV_UtilityWater_Objects.lua:13-23` 的现有语义迁移（key 白名单 + 数量相等）。
- **建议归属层**：`shared/Common/RV_StrictSchema.lua`（该文件现有的唯一职责就是「当前 shared schema 契约的严格检查」，`:1`）。
- **消费者**：`server/Water/RV_UtilityWater_Objects.lua:60` 改为 `StrictSchema.exactKeys`，删除本地实现。
- **风险与前置条件**：现状实现用 `pairs` 计数 + `#expected` 比较，若 `expected` 含重复项会误判；迁移时**保持同一算法**（不顺手改判定），以免把「补齐归属」变成「改变校验强度」。**不得**保留本地副本作为兼容别名。

### E10. `RV_BoundaryServer_Geometry.playerCell/square` 收敛（对应清单 16）

- **做法**：`RV_BoundaryServer_Geometry.lua:142-146` 的 `square` 直接删除，改用 `ServerWorld.getSquare`（两者逐字节同义）；`:135-140` 的 `playerCell` 删除，改用在 `RV_ServerWorld` 中新增的 `findCellForPlayer(player) -> cell | nil`（`getCellForPlayer:11-21` 保留 `error` 语义，改为 `local ok, cell = findCellForPlayer(player); if not ok/cell then error(...) end`）。
- **建议归属层**：`server/Common/RV_ServerWorld.lua`（server 内部公用）。
- **消费者**：`RV_BoundaryServer_Geometry.lua:378-387` 的 `ctx.playerCell`/`ctx.square` 赋值改为指向 `RV_ServerWorld`；`RV_BoundaryServer_Sweep.lua:10-11`、`RV_BoundaryServer_Objects.lua:11` 的别名行不变。
- **风险与前置条件**：`RV_BoundaryServer.lua:25-26` 目前只 require `RV_Constants`/`RV_Server_Core`，这是有意的低依赖设计（`:1-7` 的注释说明它不引入 Railroader 对象）。新增 `require("RailroaderRV/Common/RV_ServerWorld")` 会引入 `RV_ServerWorld → RV_ServerUtil → RV_Common` 链。`RV_Server.lua:53` 用 `pcall(require, ...)` 加载 BoundaryServer，因此加载失败会走 `:54-57` 的「boundary hooks disabled」分支——**若新增依赖引入任何加载期错误，边界保护会整体静默关闭**。必须验证该 require 链在 dedicated server 下无副作用（`RV_ServerWorld` 顶部无事件注册、无持久化，见 `:1-5`，因此风险低）。

### E11. `server/Common/RV_PlayerSnapshot.lua` 的 Java 集合原语（对应清单 9 的**前置**，不是清单 9 本身）

- **做法**：在 E4 的模块内提供 `M.collectionToList(collection) -> list, complete`，`complete=false` 表示枚举中途失败。先让清单 9 的 5 个循环点（`RV_ServerWorld.collectionSnapshot:31-65` 最复杂，保留其 strict 包装；`Sweep`、`Sentinel`、`RoomOwnership`、`RV_UtilityDashboard.collectionItems`）改用该原语，**暂不合并各自的 strict/可选策略**。
- **理由**：清单 9 的分叉由「失败是否致命」驱动，直接合并会改变 fail-closed 行为；先共享原语可以把 6 份 `size()/get(i)` 循环降为 1 份，同时保留 5 种失败策略不变。

### E12. `client/RailroaderRV/GUI/` 内的客户端玩家反查（对应清单 17 的**前置**）

- **做法**：新增 `client/RailroaderRV/GUI/RV_ClientPlayers.lua`，提供 `M.byOnlineId(id) -> IsoPlayer | nil`，并把它作为 `RV_BoundaryClient.lua:49`、`RV_RailroaderContextMenu.lua:34`、`RV_ContextMenu_RoomOwnership.lua:23` 的共同实现。
- **建议归属层**：`client/`，**不是** `shared/`——该函数只在 client 侧有意义，放 `shared/` 会让 dedicated server 也加载 client-only 逻辑。
- **风险与前置条件**：三个实现的单机兜底策略不同（见清单 17），合并前必须先在「单机该不该兜底」上取得一致；因此本项**只有在 C3 决策后才可执行**。

---

## 判定为「不应提取」的项及原因

### B1. `Common.identityKey` 与玩家 `"id:name"` 键不可合并（清单 19）

- **证据**：`server/Common/RV_Common.lua:80-90` 产出的键是**长度前缀 + `|` 连接**（`#part .. ":" .. part`，多段用 `|`），且任一分量为 `nil` 即返回 `nil`。玩家键（`RV_BoundaryServer_Geometry.lua:78` 等 6 处）是 `tostring(onlineId)..":"..name`，并在 `RV_UtilityServer.lua:29` 用 `"0"`/`"unknown"` 占位。
- **为何无法统一**：①`identityKey` 的 nil 传播是 `RV_UtilityPowerDevices.lua:191` 等 8 处缓存键的**正确性前提**（nil identity 必须不产生缓存条目）；②玩家键的占位符是单机（无 network slot）下的故意设计；③两者的消费者集合完全不重叠。
- **结论**：这是两个不同问题（RV 身份 vs 玩家身份），共用名字但契约不同。应各自保留，**不得**为「看起来只有一份 identity 函数」而合并。

### B2. `RV_UtilityStore.waterSinkKey` 的持久化键不可并入 `RV_CoordinateKey`（清单 20）

- **证据**：`server/Core/RV_UtilityStore.lua:42-45` 用 `string.format("%d:%d:%d")`，其产物经 `M.commit:132`（`value.records[id] = copyTable(record)`）与 `M.getRecord:104`（`value.records[id]`）成为 **ModData 持久化子键**（`U.STORE_KEY = "RailroaderRVTest.Utility"`，`shared/Common/RV_UtilityConstants.lua:13`）。唯一消费者是 `server/Water/RV_UtilityWater_Ledger.lua:13`，该键直接作为 `water.sinks[key]` 的查找键（`RV_UtilityWater_Ledger.lua:19`）。而清单 13 的其他 8 处都是**进程内**比较/查找键（例如 `TemplateProtectionRepair.entriesByCell` 每进程重建，`RV_Server_GenerationBuild.lua:53` 的 `key` 只用于同一次构建内的查表）。
- **为何无法统一**：统一会改变已写入 ModData 的键格式，收益为零（不会减少任何语义重复，因为 `%d` 还承担了「拒绝非整数」的作用），风险是数据失配。
- **结论**：保留。若未来确实要统一格式，必须作为独立的数据格式变更处理，而不是作为「消除重复」的副产物。

### B3. `StrictSchema.integer`（原生严格）与 `C.finiteNumber`（强制转换）不能合成一个函数（清单 10）

- **证据**：`shared/Common/RV_StrictSchema.lua:4-11` 与 `shared/RoomTemplate/RV_TemplateGeometry.lua:31-38`、`RV_RoomTemplate.lua:17-21` 都**只接受 `type(value) == "number"`**；`shared/Common/RV_Constants.lua:16-25`、`server/Common/RV_Common.lua:57-65` 明确接受字符串与 Java 包装（注释 `RV_Constants.lua:21-22` 说明网络表数字是 Java 包装，必须走 `pcall(function() return value + 0 end)`）。
- **为何无法统一**：这两条语义轴服务两个不同的信任边界——模板编译期常量（内部、必须原生）vs 网络/ModData 输入（外部、必须强制转换）。合并成一个「宽容」函数会让模板期的内部错误数据静默通过；合并成一个「严格」函数会让所有网络输入直接失效。
- **结论**：只能共享**两个具名函数**（E5 的 `isFiniteNumber` 与 `finiteNumber`），不能合并为一个。**不得**把 `StrictSchema.integer` 改成强制转换版本，也**不得**为它增加兼容别名。

### B4. 各模块的 modData tag 谓词不可统一（清单 5、6 的「差异」部分）

- **证据**：`RV_BoundaryServer_Objects.lua:128-173`（role ∈ {wall-north, wall-west, corner-nw} + `edgeKey` 为 string + `templateIndex` 交叉校验 + `captured.class`/`north`/`sprite`/`direction` 逐项比对）、`RV_UtilityPower.lua:57-64`（role=="generator" + `rvId`/`generation` 与当前 identity 相等）、`RV_WardrobeVisuals.lua:52-68`（role=="captured-template" + `templateIndex` 指向特定衣柜条目 + `edgeKey` 必须为 nil）、`RV_BoundaryWallVisuals.lua:45-69`（role 集合 + 特定 sprite 白名单 + `doRender==false`）、`RV_WallReloadProtection`/`RV_RailroaderServer_WallReload.lua:146-154`（owner + rvId 非空 + generation 有效 + role 集合）、`RV_ServerWorld.isTaggedForGeneration:213-222`（owner + generation + rvId）。
- **为何无法统一**：这些不是同一谓词的复制，而是**六种不同的业务契约**。强行统一会产生一个带 6 个开关的「通用校验器」，既失去可读性，也会让任何一处的契约变更影响其余五处。
- **结论**：只提取 E2 的机械部分（读取 + owner），谓词留在各自模块。

### B5. `requiredNumber`/`requiredInteger` 的 `error` 语义不可改为返回 nil（清单 10）

- **证据**：`server/Common/RV_ServerUtil.lua:20-35` 用 `error("RailroaderRVTest: ... is not a finite number")`。其唯一消费者是 `server/Construction/RV_Server_PlayerValidation.lua:22-32` 的 `readPlayerCoordinate`，该函数把「读不到权威坐标」定义为**事务级失败**，由 `:25`、`:29` 抛出并沿 `pcall` 边界向上传播（`RV_Server_Commands.lua` 的 `safeErrorText` 路径）。
- **为何无法统一**：改成返回 nil 会让「权威坐标不可读」从硬失败退化为可继续执行，属于**放宽当前严格校验**。
- **结论**：保留。它们是 `RV_Common.integer` 之上的**策略层**（fail-closed），与 `integer`（可空）是两个不同契约，不是重复实现。

### B6. 4 个 `safeErrorText` ctx 转发别名不是重复实现（清单 15、21）

- **证据**：`RV_Server_GenerationAck.lua:9`、`RV_Server_Commands.lua:22`、`RV_Server_RecordValidation.lua:10`、`RV_Server_GenerationFlow.lua:21` 都是 `local function safeErrorText(...) return ctx.safeErrorText(...) end`——函数体是**延迟查表**，不是复制实现。
- **为何不应处理**：①真实实现只有一份（`RV_Server_GenerationBuild.lua:16-32`），`:178` 把 `ctx.safeErrorText` 补上；②`RV_Server.lua:132` 在 ctx 构建时传的是 `nil`（`local safeErrorText` 于 `:89`），正因为别名是延迟查表，`require` 顺序（`:143` GenerationBuild 早于 `:147`/`:148`/`:149`/`:150` 的四个消费者）才不成为约束；改成直接 `require` 会把「注入」变成「硬依赖」，破坏既有的 `ctx` 结构。
- **结论**：保留。这是有意的单行命名别名，与 `local call = ctx.call`（`RV_BoundaryServer_Sweep.lua:7` 等 7 个文件）同类。

---

## 暂缓项与再评估条件

### C1. Java 集合 → Lua 数组枚举（清单 9）

- **暂缓理由**：6 个循环点的差异集中在「枚举失败是否致命」，直接合并会改变 `RV_ServerWorld.squareSnapshotInternal:86-118` 的 fail-closed 语义（`:94-96`、`:101-103`、`:106-109` 三处 `return nil, false, "<具体原因>"`）。
- **再评估条件**：E1（`RV_SafeCall`）与 E11（`collectionToList` 原语）落地并通过一次运行时验证后，逐点确认各调用方的失败策略，再决定是否把 `strict` 变成该原语的显式参数。**若 `collectionToList` 无法在不引入 `strict` 开关的前提下覆盖 `RV_ServerWorld` 的三档错误消息，则判定为「不应提取」并结案。**

### C2. `RV_ServerSchema.lua:123-126` 的 `safeErrorText` 内联回退（清单 15）

- **暂缓理由**：真实双实现，但替换会使单行消息变为多行 traceback。消费者 `RV_ServerSchema.lua:130` 用 `string.find(message, "no IsoCell available", 1, true)` 做子串匹配——**条件性推断**：`debug.traceback(text, 3)` 的返回值为 `text .. "\nstack traceback:..."`，子串仍在，因此替换在功能上兼容；但 `:148` 的返回文案也会跟着变长，影响下游 `print` 可读性。
- **再评估条件**：若后续需要统一错误文本格式（例如日志前缀规范），把 `safeErrorText` 提升为 `server/Common/` 的公用模块并让 `ServerSchema` 通过 ctx 注入获取（而不是 `require`），即同时消除内联回退与 4 个别名。**在此之前保持现状。**

### C3. 客户端 `localPlayerByOnlineId` 三实现（清单 17）

- **暂缓理由**：分叉点是业务策略不是机械代码——`RV_BoundaryClient.lua:41-47` 在 `getOnlineID` 无效时回退 `getPlayerNum`（`RV_RailroaderContextMenu.lua:47-50` 注释说明「B42 某些构建返回 nil/-1」），而 `RV_ContextMenu_RoomOwnership.lua:23-32` 没有回退。
- **再评估条件**：先确认「单机/co-op 宿主下 `getOnlineID` 的返回值集合」，据此定下唯一策略；**若不能确定一个对三处都成立的策略，则判定为「不应提取」并结案**。在此之前不得为统一而给 `RoomOwnership` 添加兜底（那会改变房间所有权判定路径）。

---

## 覆盖与未覆盖

**已覆盖**

- `server/`：Common（`RV_Common`、`RV_ServerUtil`、`RV_ServerWorld`、`RV_ServerSchema`、`RV_ServerTeleport`）、Core（`RV_Server`、`RV_RailroaderServer`、`RV_RailroaderServer_Sentinel`、`RV_RailroaderServer_Tick`、`RV_UtilityServer`、`RV_UtilityStore`、`RV_Server_Commands` 顶部）、Construction（`RV_Server_WorldObjects` 关键段、`RV_Server_PlayerValidation`、`RV_Server_GenerationBuild` 顶部、`RV_Server_GenerationAck` 顶部、`RV_Server_GenerationFlow` 顶部）、RVMapping（`RV_RailroaderServer_Train` 顶部与身份段、`RV_RailroaderServer_Mapping` 的 snapshot 转发、`RV_Server_RecordValidation` 顶部）、BoundaryGuard（`RV_BoundaryServer`、`RV_BoundaryServer_Geometry`、`RV_BoundaryServer_Sweep`、`RV_RailroaderServer_BoundaryValidation` 身份段）、DemolitionProtection（`RV_BoundaryServer_Objects` 顶部与 `isCurrentShellWall`）、RoofRefresh（`RV_RoofRefresh` 部分）、RoomOwnership（`RV_Server_RoomOwnership` 身份段与 snapshot）、TemplateRecovery（`RV_Server_TemplateProtectionRepair` 顶部）、WallReloadProtection（两文件的身份与 tag 段）、Power（`RV_UtilityPower` 顶部、`RV_UtilityPowerDevices` 顶部与 objectIndex/square 段）、Water（`RV_UtilityWater_Objects`、`RV_UtilityWater_Plumbing`）
- `shared/`：Common（`RV_Constants`、`RV_StrictSchema`、`RV_UtilitySprite` 全量）、RoomTemplate（`RV_RoomTemplate` 顶部、`RV_TemplateGeometry` 顶部）、RVMapping（`RV_RegionSlots` 的 StrictSchema 使用）、Water（`RV_UtilityCatalog` 全量）
- `client/`：GUI 全部 11 文件已定位重复点，其中 `RV_BoundaryClient`、`RV_WardrobeVisuals`、`RV_BoundaryWallVisuals`、`RV_ProtectedDemolition`、`RV_UtilityClient`、`RV_ContextMenu_RoomOwnership`、`RV_RailroaderContextMenu`、`RV_UtilityDashboard`、`RV_ContextMenu_Relocation` 已读关键段

**未覆盖 / 覆盖不足**

- `server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua`（697 行）只读了身份/座位相关行，其内部的坐标与座位键逻辑未逐行审计；`playerId`/`playerName` 的宽松语义是否被 SP 场景依赖，是 E3 的开放决策点（见 E3 的风险段）。
- `server/RailroaderRV/Construction/RV_Server_WorldObjects.lua`（816 行）只读了 4 个关键段；其 `apply*State` 系列（`:33-40` 起）是否包含第 10 组之外的数值转换变体未穷举。
- `server/RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua`（473 行）只读了顶部与三处 `objects[index]` 循环点。
- `server/RailroaderRV/WallReloadProtection/RV_WallReloadProtection.lua`（508 行）只读身份/成员段；其状态机与 tick 逻辑不在本审计范围。
- `server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua`（562 行）只读身份/snapshot 段。
- `client/RailroaderRV/GUI/RV_UtilityDashboard.lua`（582 行）与 `RV_RailroaderContextMenu.lua`（719 行）只读关键段。
- 清单 20 的 `waterSinkKey` 消费者已定位（`server/Water/RV_UtilityWater_Ledger.lua:13`、`:17`），其**持久化路径**的完整写入/读取往返未逐行跟踪（只确认了 `RV_UtilityStore.commit:132` 的写入侧与 `getRecord:104` 的读取侧）。
- 本审计为**静态只读**：所有「统一后行为不变」的判断都是源码级比对（参数、返回值、失败分支），**未经运行时验证**。任何提取落地后必须走项目的一键整体运行时测试（`python testserver/run_test.py`），本事务不运行该测试。
- 本次未核查 `game-decompiled/` 与 `official lua scripts/`：`getOnlineID`/`getPlayerNum`/`getObjectIndex`/`instanceof` 等 Java 侧真实签名与返回值集合未与反编译基线交叉验证。E3 与 C3 的开放决策点需要该交叉验证才能定案。
