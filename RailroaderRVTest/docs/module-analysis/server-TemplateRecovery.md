# server/RailroaderRV/TemplateRecovery 模块分析

## 假设、范围、成功条件与验证方式

- **假设**：只分析模组当前目录 `media/lua/server/RailroaderRV/TemplateRecovery/` 的直接子文件；行号以本次读取的当前源码版本为准（本目录 2 个文件合计 648 行：`RV_Server_TemplateProtectionRepair.lua` 473 行、`RV_TemplateRecovery.lua` 175 行）。行数按 `(Get-Content f).Count` 统计，**包含空行**（`Measure-Object -Line` 会跳过空行并给出偏小值，未使用）。这里是服务端模板保护恢复层，按当前 B42 服务端调用语义解释；旧报告描述的是已经不存在的 1,729 行单文件版本，其行号与结构一律不沿用。
- **范围**：覆盖本目录 2 个 Lua 文件及其所有具名函数、局部函数、表字段函数与匿名函数表达式；只读检查调用方（Core 装配根、BoundaryGuard/Sweep、WallReloadProtection、Construction/WorldObjects）用于判断导出 API 的实际使用面与跨模块数据访问。唯一写入目标是本报告。
- **成功条件**：每个函数都有精确起始行、参数含义、返回值或副作用、模块语义和必要性判断；另外回答「哪些函数应提取为公用功能」「是否应进一步拆分」并给出理由；接口章节逐条给出 `文件:行` 证据并说明接口收益低于直接访问的原因；明确区分「源码事实」与「条件性推断」。不运行游戏、服务器或任何测试脚本。
- **验证方式**：列目录文件与行数；逐行编号读取两个文件全文（1-473、1-175）；对全树 `function` 关键字做分类扫描（区分定义行、`type(x) ~= "function"` 比较行与含 `function` 字样的注释行）交叉核对定义数与起始行；在 `media/lua` 全树检索 `TemplateRecovery`、`RecoveryQueue`、`repairCell`、`isTemplateProtectionRepairRemoval`、`_templateProtectionRepairRemovalObject` 与旧报告符号（`RV_TemplateRecoveryIndex`、`RV_TemplateRecoveryQueue`、`RV_Server_RoofRelocation`、`onTemplateProtectionRepairTick`、`observeTemplateProtectionRepairTransitions`、`sampleTemplateProtectionRepairPlayer`、`processTemplateProtectionRepairQueue`、`shouldSampleTemplateProtectionRepair`、`addTransitionLifecycleListener`、`reconcileCurrentTemplateCell`、`restoreCurrentCell`、`_builders`）确认当前接口面；完成后检查报告的文件清单、函数条目数、路径及行号引用。源码扫描是静态分析，不替代运行时验证。

## 目录职责与清单

TemplateRecovery/ 现在由两个文件构成一条单向流水线：`RV_TemplateProtectionRepair.lua` 拥有「模板期望项 + 对象身份/安全策略 + 单元格世界修复」，`RV_TemplateRecovery.lua` 拥有「候选格采样 + 单环形队列 + 每 tick 预算」，并在每 tick 末尾由 BoundaryGuard 的 sweep 调用。两个文件都用 `instance` 单例守卫（Repair L5/L7、Recovery L8/L10），且都不注册事件、不写存档。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_Server_TemplateProtectionRepair.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua) | 31 | 从编译期模板派生期望对象与 shell edge 归属；判定对象身份/捕获状态/容器/多格安全；在单个 XY 上删除多余对象、补建缺失模板对象，并把「本模块发起的移除」发布给 WallReloadProtection |
| [RV_TemplateRecovery.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/TemplateRecovery/RV_TemplateRecovery.lua) | 9 | 按 10 tick 周期在活跃玩家周围采样 3×3 候选格，写入单一容量 256 的环形队列；每 tick 按预算取格、找到同代际玩家后调用修复模块，并只记录失败 |
| **总计** | **40** | 2 个文件、648 行；36 个 `local function` + 1 个表字段函数（Repair L463）+ 2 个模块工厂匿名函数（Repair L6、Recovery L9）+ 1 个 `pcall` 匿名闭包（Repair L132） |

函数数包括具名局部/嵌套函数、表字段函数与作为参数传入的匿名函数表达式；`instance` 单例守卫（Repair L5-L7、Recovery L8-L10）是赋值与条件判断，不重复计数。本目录两个文件的 `function` 关键字命中数与定义数完全一致（31 与 9）：目录内没有 `type(x) ~= "function"` 比较行，也没有含 `function` 字样的注释行。

## 逐文件、逐函数分析

### RV_Server_TemplateProtectionRepair.lua

模块是一个 `return function(ctx)` 工厂（[RV_Server_TemplateProtectionRepair.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:6)），从 ctx 取 Constants/RV/ServerUtil/ServerWorld/createCapturedTemplateObject/configureCapturedDoorFrame/Boundary（L8-L14），require shared 的 `RV_RoomTemplate` 与 `RV_TemplateGeometry`（L15-L16），在加载时一次性捕获编译期模板与其有序对象表（L17-L18），并据此建立模块级 `entriesByCell` 索引（L37-L50）。它对外只发布 `repairCell`（L469-L471），并另外在 `RV.Server` 上安装移除来源查询（L461-L467）。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| 工厂匿名函数 function(ctx)（L6） | ctx 提供 `Constants`、`RV`、`ServerUtil`、`ServerWorld`、`createCapturedTemplateObject`、`configureCapturedDoorFrame`、`Boundary`。加载 RoomTemplate/TemplateGeometry，捕获 `Template` 与 `templateObjects`（L17-L18），建立 `entriesByCell`（L41-L50），定义全部函数，安装 `RV.Server.isTemplateProtectionRepairRemoval`（L461-L467），返回 `{repairCell}`（L469-L471）。 | **必须**：本目录唯一装配入口，Core 在 RV_Server.lua:145 调用；`instance` 守卫（L5、L7）保证 Recovery 在 L14 再次 require 时拿到同一实例。 |
| integer（L20，私有） | value 任意值；`ServerUtil.toNumber` 之后要求 `type == "number"`、非 NaN、非正负无穷且 `math.floor(v) == v`，否则 `nil`；返回有限整数或 `nil`，无副作用。 | **必须**：模板索引、世界坐标、`tag.templateIndex` 与 `objectCount` 比较全部依赖整数化；规则与 `Common.integer`（RV_Common.lua:72）等价，见复用章节。 |
| coordinateKey（L30，私有） | x/y/z；返回 `"x,y,z"` 字符串。 | **保留理由**：只服务两条排障日志（L357、L363）；它与查找键 `templateCellKey`（L38，`"x:y"`）分隔符不同，属诊断格式，删掉只损失日志可读性。 |
| templateCellKey（L38，私有） | x/y；返回 `"x:y"` 字符串。 | **必须**：模板对象按模板 XY 分桶的键（L43、L94）；与 `coordinateKey` 的格式差异是有意区分「模板格」与「世界坐标」。 |
| shellEdgeMap（L56，私有） | boundary；遍历 `boundary.shellEdges`，校验 key 为 string、edge 为 table 且 `edge.edgeKey == key`、`role` 为 string（L59-L63）、`templateIndices` 非空且首项等于 `edge.templateIndex`（L64-L69）、每个序号落在 `1..Template.metadata.objectCount` 且未重复（L70-L79），任一不满足即 `error`；返回 templateIndex → edge 映射。 | **必须**：每次 cell 检查重建、从不缓存（注释 L52-L55：ledger 按 generation 生成）；模板作者数据自相矛盾时 raise 而不静默降级，是本模块 fail-fast 的基座。 |
| entryAt（L84，私有） | anchor、edgeMap、x/y/z；经 `TemplateGeometry.worldToTemplate`（L85-L87）求模板偏移并要求三轴都是整数（L89-L93），再在 `entriesByCell` 中找同 Z 的捕获项，返回展开的期望表 `{templateIndex,x,y,z,class,name,sprite,north,direction,state,protected,edge}` 或 `nil`。 | **必须**：模板期望对象及其世界坐标的唯一派生点；`edge` 由 edgeMap 挂上，供后续 shell 身份校验。 |
| templateEntriesAt（L119，私有） | boundary、anchor、edgeMap、x/y；在 `boundary.managed.minZ .. maxZ-1` 逐层调用 entryAt，返回该世界 XY 上的全部期望项数组。 | **必须**：把「一层一个对象槽」的模板语义收成一次查询；空数组即「该格不受模板保护」（L406 据此直接返回）。 |
| loadedLayerForCell（L128，私有） | cell、x/y/z；`ServerUtil.invoke(cell,"getChunkForGridSquare",...)` 失败或 chunk 为空返回 `false`；否则 pcall 读取 `chunk.loaded`，只在严格 `true` 时返回 `true`。 | **必须**：禁止对未加载层做快照/删除/重建；枚举缺失与「未加载」必须区分。 |
| loadedLayerForCell 中匿名函数（L132） | 无参数，捕获 `chunk`；在 pcall 内返回 `chunk.loaded`。 | **实现必需**：Java chunk 代理属性读取可能抛错，必须折叠为 `false` 而不是打断整次修复。 |
| objectTag（L139，私有） | object；经 `ServerWorld.objectModData` 取 ModData 原表，读 `data.RailroaderRVTest`，要求是 table 且 `tag.owner == Constants.MOD_ID`（L142-L144），否则 `nil`。 | **必须**：判断「对象是否本模组捕获对象」的唯一可信身份读取口；tag 布局由 `ServerWorld.tagObject`（RV_ServerWorld.lua:178-L211）写入，`templateIndex` 是「标签只存索引、属性由模板解析」的核心字段。 |
| objectTemplateIndex（L148，私有） | object；objectTag 成功后返回 `integer(tag.templateIndex)`，否则 `nil`。 | **必须**：模板槽匹配键（L233、L260、L377、L438）；玩家建造对象没有 `templateIndex`，这正是它与被替换模板对象的区分（注释 L136-L138）。 |
| objectCell（L153，私有） | object；invoke `getX/getY/getZ`，三轴都成功且为整数时返回三个整数（`xOk and yOk and zOk and integer(x), integer(y), integer(z)`）。 | **必须**：删除前的定位与排障坐标来源（L351-L354）；坐标不可读时调用方 raise，避免盲删。 |
| isOpenableClass（L160，私有） | className；`"IsoDoor"` 或 `"IsoWindow"` 返回 `true`。 | **实现必需**：门窗的开关/上锁是正常玩法，状态比对必须对它们放宽，该放宽只由 objectMatchesTemplate 使用（L215）。 |
| isVisualCorner（L164，私有） | entry；`class == "IsoObject"`、`name == "Wooden Wall"`、`sprite == "walls_interior_house_02_35"` 三者同时成立。 | **实现必需**：视觉角不是 floor 槽，该判定只服务 isFloorEntry 与 floor 身份规则（L170、L249）。 |
| isFloorEntry（L169，私有） | entry；`class == "IsoObject"` 且不是视觉角。 | **必须**：区分 square 的 floor 槽与普通对象列表（与 L434 的 `floor == object` 比较配套）；floor 槽的删除/重建语义不同。 |
| objectMatchesCaptured（L173，私有） | object、expected；`classInstance` 命中 class，`getName`、`getDir`（经 `IsoDirections` 表）、`ServerWorld.getSpriteName` 全部相等，`expected.north` 非 nil 时再比 `getNorth`；返回布尔。 | **必须**：外观身份必须与捕获模板一致；缺它则「位置+标签」就足以让一个玩家重建物冒充模板对象。 |
| objectMatchesStoredState（L193，私有） | object、expected；用固定 getter 表（`health`/`maxHealth`/`hoppable`/`locked`/`canPassThrough`/`blockAllTheSquare`/`doRender`/`thumpable`，L194-L200）逐字段要求相等，未知 state 键直接返回 `false`。 | **必须**：防止接受状态被改写的对象；未知键 fail-closed 保证模板 schema 扩展不会静默放行。 |
| objectMatchesTemplate（L213，私有） | object、expected；先 objectMatchesCaptured，门窗直接 `true`，否则追加 objectMatchesStoredState。 | **必须**：把「门窗只比身份、其余比完整状态」的放宽集中在一个判据（注释 L210-L212），供 L234、L265 复用。 |
| objectHasShellIdentity（L222，私有） | object、edge；edge 为 `nil` 返回 `true`；否则要求 tag 的 `role` 与 `edgeKey` 等于 edge 的对应字段。 | **必须**：shell ledger 靠 role/edgeKey 认墙（注释 L219-L221）；缺这两个字段的重建墙不算模板项，是墙体重载与模板恢复不互相破坏的前提。 |
| objectIsTemplateEntry（L230，私有） | objects、entry；任一对象 templateIndex 相同且 objectMatchesTemplate 且 objectHasShellIdentity 即 `true`。 | **实现必需**：单元格缺项检测的单一谓词（仅 L444 使用）。 |
| isRepairTarget（L245，私有） | object、entries、objectIsFloor；任一条 `protected` 期望项与对象 class 相同，或对象是 floor 且该期望项是 floor 槽时为 `true`。 | **实现必需**：移除授权白名单，只被 isSpareObject 使用；`protected` 标志来自模板 schema 而不是本文件的常量表。 |
| isSpareObject（L258，私有） | object、entries、objectIsFloor；先 isRepairTarget；无 templateIndex 即 `true`；有则要求 index/identity/shell 全匹配，全不匹配才 `true`。 | **必须**：删除授权判据（L436）；把「仍是模板对象」与「占了保护位的多余对象」分开（注释 L256-L257）。 |
| isBloodOrSplat（L273，私有） | object；sprite 或 name 小写后含 `"blood"`，name 含 `"splat"` 也计入；返回布尔。 | **必须**：血迹等动态世界内容不得被模板修复清除，与 protectedWorldObject 组合成完整保护名单。 |
| protectedWorldObject（L286，私有） | object；isPlayerObject / isVehicleObject / `IsoWorldInventoryObject` / `IsoZombie` / `IsoAnimal` / `IsoDeadBody` / blood-or-splat 任一命中即 `true`。 | **必须**：世界对象安全门禁核心（L435），全部经 ServerWorld 公开导出与 ServerUtil.classInstance 判定，不依赖对象自身字段。 |
| hasStoredContainerItems（L301，私有） | object；先 `getContainerCount`（读不到且是 `IsoThumpable` 视为有内容，`count > 1` 直接拒绝），再沿 `getContainer`/`getItems`/`size` 判断，凡不能证明为空即 `true`。 | **必须**：删除前唯一的物品保护检查（L355）；fail-closed 语义保证箱柜与不确定容器不被清掉。 |
| squareContainsObject（L321，私有） | square、object；pcall 调 `ServerWorld.squareContainsObject`，抛错即 raise，否则要求严格 `true`。 | **实现必需**：删除后的权威复核（L343）；把「查询本身失败」与「对象仍在」区分开，前者必须中止而不是当成功。 |
| removeObject（L332，私有） | square、object；把对象写进 `RV.Server._templateProtectionRepairRemovalObject`（L334-L335），pcall `ServerWorld.removeGenericObject(square, object, false)`（L336-L337），恢复旧标记（L338），失败 raise（L339-L342），最后要求 squareContainsObject 为假（L343-L345）。 | **必须**：唯一的世界移除执行点；第三个实参 `false` 表示不回滚 tagged floor，标记用于让 WallReloadProtection 区分「本模块修复移除」与玩家拆墙（见接口章节）。 |
| deleteCapturedObject（L350，私有） | square、object、templateIndex；objectCell 不可读即 raise；hasStoredContainerItems 为真时打印保留原因并返回 `false`；否则 removeObject 并打印 rebuilt 日志，返回 `true`。 | **必须**：把「保留（容器有内容）」与「已删除、等待重建」两种结果显式分开并留痕，是 repaired 汇总值（L437-L438）的来源之一。 |
| restoreEntry（L373，私有） | cell、square、objects、entry、boundary；若某对象 index/identity/shell 全匹配则该槽已在位（`"Wooden Door Frame"` 额外 pcall `configureCapturedDoorFrame` 恢复通行状态），直接返回；否则 `createCapturedTemplateObject(cell, square, entry, boundary.generation, tagContext, entry.edge)` 重建。 | **必须**：模板对象补建的唯一路径；shell edge 必须传给创建器，否则重建墙缺 role/edgeKey 会被 shell ledger 忽略（注释 L367-L372）。 |
| repairTemplateProtectionCell（L392，私有，导出为 repairCell） | player、expectedBoundary、x/y。`pcall(Boundary.boundaryForPlayer, player)` 并要求返回 boundary 与 expectedBoundary **引用相等**，否则 `false,"queued RV generation is stale"`（L393-L396）；派生 anchor（L397）；buildable 格直接返回 `false`（L400-L403，注释说明那是玩家的合法建造行为）；取该 XY 全部期望项，空即返回 `false`（L404-L406）；按期望项 Z 层建 `repairLayers`（L408-L411）；取 player cell（L412-L415）；对 `managed.minZ .. maxZ-1` 逐层：pcall getSquare（L419-L422），已加载且该层有期望项时 squareSnapshot（L424-L427）与 `getFloor`（L428-L431），先删「非 protectedWorldObject 且 isSpareObject」的对象（L432-L440），再对缺失期望项 restoreEntry 且每次重建后重新快照（L441-L455）；返回 `repaired`。 | **必须**：本文件唯一对外函数，Recovery 在 L137 以 pcall 调用；单元格修复的全部语义（身份时效、buildable 豁免、删除授权、重建、复核）都收在这一处。 |
| server.isTemplateProtectionRepairRemoval（L463，表字段函数） | object；要求 object 非 nil 且与当前 `_templateProtectionRepairRemovalObject` 引用相同。 | **必须**：WallReloadProtection 的移除来源过滤器（RV_RailroaderServer_WallReload.lua:157-L166）用它识别「本模块自己的同步移除」；这是本模块唯一的跨模块公开查询。 |

### RV_TemplateRecovery.lua

模块是第二个 `return function(ctx)` 工厂（[RV_TemplateRecovery.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/TemplateRecovery/RV_TemplateRecovery.lua:9)），从 ctx 取 Core/Constants/ServerUtil（L11-L13），并直接用同一 ctx require 修复模块（L14）。它持有唯一的跨 RV 环形队列（L22-L28）与采样周期 `Constants.TEMPLATE_PROTECTION_REPAIR_SAMPLE_INTERVAL_TICKS`（L30，值 10，见 RV_Constants.lua:98），把实例发布为 `RailroaderRV.RecoveryQueue`（L172-L173）并返回（L174）。文件头注释（L1-L7）明确声明它不注册任何回调、实例由 sweep 在运行时查找。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| 工厂匿名函数 function(ctx)（L9） | ctx 提供 `Core`、`Constants`、`ServerUtil`（L11-L13）；require 并调用 Repair 工厂（L14）；建立环形队列 `queue`（L23-L28）与 `sampleInterval`（L30）；定义全部函数；把 `{onPostPlayerTick}` 发布为实例并写入 `RailroaderRV.RecoveryQueue`（L169-L174）。不注册事件、不写存档（L1-L7）。 | **必须**：Core 在 RV_Server.lua:146 调用；`instance` 守卫（L8、L10）保证重复 require 返回同一队列实例。 |
| queuedWindowWraps（L36，私有） | 无参数；返回 `queue.count > 0 and queue.tail < queue.head`。 | **必须**：环形窗口的环绕判据；注释 L32-L35 说明用 count 兜住空队列（`tail = 0` 也满足 `tail < head`）这一边界。 |
| enqueueCell（L40，私有） | rvId 字符串、generation、x、y；队列满（`count == CAPACITY`）返回 `false`；在已排队窗口内按 x/y 去重（L44-L59，含环绕两段遍历）；写入 `{rvId,generation,x,y}` 并推进 tail/count，返回 `true`。 | **必须**：唯一入队点，保证同一格在窗口内不重复且不覆盖未处理项；`CAPACITY = 256`（L22）是硬上限。 |
| dequeueCell（L68，私有） | 无参数；空队列返回 `nil`；取出 head、清槽、count 减 1；空时复位 `head = 1, tail = 0`，否则推进 head；返回 entry。 | **必须**：唯一出队点；空态复位规则是环形队列正确性的前提（配合 L36 的环绕判据）。 |
| tickBudget（L82，私有） | 无参数；`count > 128` 返回 4，`count > 64` 返回 2，否则 1。 | **必须**：每 tick 修复上限（L126、L129）；注释 L81 说明加深队列只提高吞吐上限，不改变每格流程。 |
| enqueuePlayerCells（L91，私有） | item（sweep 提供的 `{boundary, player}`）；player/boundary 缺失直接返回；invoke `getX`/`getY` 并 toNumber，任一不可用返回；对 `floor(x)±1 × floor(y)±1` 共 9 格调用 enqueueCell，rvId 取 `tostring(boundary.rvId)`（L103-L104）。 | **必须**：候选格产生的唯一实现；以玩家所在格为中心的 3×3 覆盖是本模块的采样语义。 |
| findQueuedPlayer（L112，私有） | activePlayers 数组、entry；线性查找 rvId 字符串与 generation 都相等的玩家，返回 player,boundary，否则 `nil,nil`。 | **必须**：队列项只记身份不记玩家引用；没有活动玩家的旧代际项会被丢弃（L130-L131）而不是堵住队首（注释 L109-L111）。 |
| processQueuedCells（L125，私有） | activePlayers；按 tickBudget 出队，找到玩家才 pcall `Repair.repairCell(player, boundary, x, y)`（L137-L138）；pcall 失败打印 failed、返回 `false` 且带 reason 时打印 skipped（L139-L147）；只有真正检查过的格才计入预算（L148）。 | **必须**：队列消费与限速的唯一实现；把修复模块「按设计 raise」与「本格跳过」两种结果降级为日志而不中断 sweep（注释 L133-L136），也保证失败格下次采样重新入队。 |
| onPostPlayerTick（L154，私有，实例方法） | tick、activePlayers、activeBoundaries；activePlayers 非 table 返回 `false,"active player list is unavailable"`（L155-L157）；`Core.tickModulo(sampleInterval)` 为真时遍历入队（L160-L164）；随后 processQueuedCells（L165）；返回 `true`。 | **必须**：sweep 在每 tick 末尾运行时查找 `RailroaderRV.RecoveryQueue` 并调用（RV_BoundaryServer_Sweep.lua:168-L177）。形参 `tick` 与 `activeBoundaries` 在函数体内从未被读取，属**保留理由**：签名对齐调用点（`Boundary._tick, activePlayers, activeBoundaries`），节拍由 `Core.tickModulo` 自取全局时钟；删除形参会与调用点不一致。 |

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **模板派生几何已全部复用 shared API，本目录不再自带几何（源码事实）**：`RoomTemplate.get`（RV_RoomTemplate.lua:129）、`RoomTemplate.orderedObjects`（RV_RoomTemplate.lua:149）、`RoomTemplate.TEMPLATE_ID`（RV_RoomTemplate.lua:6）、`Template.metadata.objectCount`（RV_RoomTemplate.lua:47）与 `TemplateGeometry.worldToTemplate`（RV_TemplateGeometry.lua:86）、`anchorFromManaged`（RV_TemplateGeometry.lua:174）、`isBuildable`（RV_TemplateGeometry.lua:133）都在 L15-L18、L73、L85、L397、L400 被直接使用。判断：保持现状，本目录只消费 shared 的公开函数，不复制模板几何。
- **`integer`（L20）是多份「宽松整数」实现之一，可提取但收益小**：与 `Common.integer`（RV_Common.lua:72-L78）规则等价（先 toNumber，再要求有限且 `math.floor(v) == v`），而 `ctx.ServerUtil` 已经转出 `integer`（RV_ServerUtil.lua:45，见 server-Common.md）。其余并行实现见 RV_BoundaryServer_Geometry.lua:23、RV_Server_WorldObjects.lua:10、RV_TemplateGeometry.lua:36。判断：**当前不建议单独改动**——替换只省 9 行，收益与 server-Common.md 里 finite/integer 收敛是同一件事；要么一起做，要么都不做，避免只统一一处造成「哪份是规范」更难判断。
- **捕获状态字段清单在两个模块里各写一遍，是真实的漂移源（源码事实）**：本文件 `objectMatchesStoredState` 的 getter 表（L194-L200）与 `RV_Server_WorldObjects.lua:131-L133` 的 `stateKeys` 是同一组 8 个字段（`health`/`maxHealth`/`hoppable`/`locked`/`canPassThrough`/`blockAllTheSquare`/`doRender`/`thumpable`）——写方在 Construction，比对放行方在本模块。**这是本目录最值得提取的一项**：把字段清单与 getter 名放进 shared 纯数据表（例如与 captured entry schema 同处），两侧共同 require。净收益是模板 schema 扩展时不会出现「写进去了但比对放行」或反之的半更新；成本是 shared 新增一个纯数据表，加载方向仍是 server → shared，不违反 shared 不得依赖 server helper 的约束。今天两份清单一致，属下次改动 captured schema 时应一并做的收敛，不是当前缺陷。
- **对象枚举与删除已全部走 ServerWorld 公开导出，无重复实现（源码事实）**：`objectModData`（L140）、`getSpriteName`（L182、L274）、`isPlayerObject`/`isVehicleObject`（L287-L288）、`squareContainsObject`（L322）、`removeGenericObject`（L336）、`getCellForPlayer`（L412）、`getSquare`（L419）、`squareSnapshot`（L424、L449）对应 RV_ServerWorld.lua:464-L478 的导出清单。判断：无需提取，也不应在本目录再造一份。
- **环形队列与采样限速是本目录独有实现，不建议通用化（源码事实）**：全树检索环形队列符号（`queue.tail`、`dequeueCell`、以及本文件 L22 的 `CAPACITY` 常量）只命中 RV_TemplateRecovery.lua:22-L86、L112-L152；其它模块出现的 `CAPACITY` 都是燃油/电池常量名（RV_UtilityPowerConfig.lua:7、L15；RV_UtilityConstants.lua:52），不是队列实现。RoomOwnership、WallReloadProtection、Power 都没有第二个 FIFO 需求。判断：做成通用队列框架属投机扩展。
- **诊断键与查找键格式不同（小问题）**：`coordinateKey`（L30，`"x,y,z"`）只用于日志，`templateCellKey`（L38，`"x:y"`）用于索引查找；两者共存无功能影响，但阅读时容易误认为同一协议。判断：说明即可，不必改。

### 是否进一步拆分

- **不建议进一步拆分，旧报告的「高优先拆分」结论在当前规模下已不成立**。当前是 2 个文件 / 648 行 / 40 函数，边界已经按「模板策略 + 世界修复」（473 行 / 31 函数）与「采样 + 队列 + 限速」（175 行 / 9 函数）切开，依赖方向单一（Recovery → Repair，RV_TemplateRecovery.lua:14），没有共享可变状态：Repair 只持有 `entriesByCell` 这张只读模板索引，Recovery 只持有环形队列。旧报告建议拆出的 `RV_TemplateRecoveryIndex.lua`、`RV_TemplateRecoveryQueue.lua` 与 `RV_Server_RoofRelocation` 在当前树中都不存在（见验证记录），而**现在的 175 行队列文件就是旧报告想要的 Queue 边界**；模板索引现在是加载时构建的模块级 `entriesByCell`（L37-L50），不需要独立文件与缓存生命周期。
- **Repair 的唯一自然切点是「期望项与身份比对」对「世界修改」，但收益为负**：(a) L20-L297 是不触碰世界的模板/身份/策略层（integer、键、shellEdgeMap、entryAt、templateEntriesAt、loadedLayerForCell、objectTag、身份与状态比对、protectedWorldObject、hasStoredContainerItems）；(b) L321-L459 是世界修改层（squareContainsObject、removeObject、deleteCapturedObject、restoreEntry、repairTemplateProtectionCell）。两侧共享 `entry`/`entries` 值对象、`boundary` 合同与同一条 Z 层循环，拆开需要把 6 个以上 helper 变成跨文件导出，接口面扩大而内聚度不变。触发条件应是出现「第二条修复策略」（例如非模板对象的清理需求），当前不存在。
- **`repairTemplateProtectionCell`（L392-L459）不需要再抽子函数**：删除阶段与重建阶段共享 `entries`、`objects`、`square` 与 `repairLayers`，抽出只会引入参数转手；其 68 行线性流程的可读性来自「身份检查 → 逐层删除 → 逐层重建 → 复核」的固定顺序，而不是函数个数。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **`RV_Server_TemplateProtectionRepair` 只发布一个函数**：`instance = { repairCell = repairTemplateProtectionCell }`（L469-L471）。唯一消费者是 RV_TemplateRecovery.lua:14（require 工厂）与 :137（`pcall(Repair.repairCell, player, boundary, x, y)`）。返回值有三种形态（源码事实）：单值 `false`（L402 buildable 格、L406 无期望项、L458 无可修复项）、`false, reason`（L395 stale generation、L414 cell 不可用、L421 square 查询失败、L426/L451 快照失败、L430 floor 读取失败）、raise（shell ledger 不一致 L61/L67/L75、容器对象坐标缺失 L353、移除失败 L340、移除不可观测 L344）。调用方必须区分这三类，当前队列的消费方式正确（RV_TemplateRecovery.lua:139-L147）。
- **`RV_TemplateRecovery` 发布 `RailroaderRV.RecoveryQueue`（L172-L173）与工厂返回值（L174）**，实例只有一个方法 `onPostPlayerTick(tick, activePlayers, activeBoundaries)`（L169-L171）。唯一消费者是 BoundaryGuard 的 sweep：运行时 `rawget(_G,"RailroaderRV")` 取 `RecoveryQueue` 后调用 `Recovery.onPostPlayerTick(Boundary._tick, activePlayers, activeBoundaries)`（RV_BoundaryServer_Sweep.lua:168-L177）。参数形状（源码事实）：`activePlayers` 是数组 `{boundary, player}`（Sweep L157-L159），`activeBoundaries` 是 `"rvId:generation" → {boundary, player}` 的哈希（Sweep L160-L162，键由 Sweep L19-L21 的 `boundaryKey` 生成）；本模块只读 `activePlayers`。
- **`RV.Server.isTemplateProtectionRepairRemoval(object)`（L463-L466）是本模块第二个公开出口**：唯一消费者是 WallReloadProtection 的移除来源过滤（RV_RailroaderServer_WallReload.lua:157-L166，运行时取 `RailroaderRV.Server` 后 pcall 调用）。契约是「当前这一次同步移除是否由模板修复发起」，调用方只看严格 `true`（L163）。
- **本模块不注册事件、不写存档、不发布到 ctx**：文件头注释明确声明不注册回调（RV_TemplateRecovery.lua:1-L7），两个文件都没有 `Events.OnX.Add`/`Core.onTick`/`Core.registerEvent` 调用；`ctx.ensureGeneratorForEntry`、`ctx.reconcileCurrentTemplateCell`、`Boundary.onTemplateProtectionRepairTick` 等旧导出在当前源码中命中数为 0（见验证记录）。

### 直接读写其他模块的数据

1. **`RV.Server._templateProtectionRepairRemovalObject` 是本目录唯一的跨模块隐藏状态**：写入/恢复在 L334-L338，读取只在同文件 L465。第三方不直接读该字段，而是经 L463 的公开查询消费（RV_RailroaderServer_WallReload.lua:157-L166）。判断：**方向正确（有查询封装），但字段挂在 Core 拥有的 `RV.Server` 表上**（RV_Server.lua:72-L74 创建），且 L461 在加载时一次性捕获（`local server = type(RV) == "table" and RV.Server or nil`）。收益：把标记收回本文件闭包、查询函数读闭包，可去掉对另一个模块表字段名的依赖，改动局部。当前未构成缺陷：RV_Server.lua:72-L74 在 L145 装载本模块之前执行，装配顺序成立。
2. **`Boundary.boundaryForPlayer(player)` 是唯一的 Boundary 依赖**（L393），且只传 1 个实参：`knownIdentity`/`deferValidationMiss`/`forceValidationRefresh` 全部缺省（对照签名 RV_BoundaryServer_Geometry.lua:236-L237）。返回的 boundary 与 `expectedBoundary` 做**引用比较**（L394）。判断：**保留直接调用**——`boundaryForPlayer` 是 BoundaryGuard 的公开方法，队列项只存身份不存引用，引用比较是「本队列项是否已过期」的最廉价判据；它依赖 Geometry 的每 slot 记忆化（RV_BoundaryServer_Geometry.lua:210-L232）与 BoundaryValidation 缓存的同一表引用（见 server-BoundaryGuard.md 的「表引用同一性」一节）。若改成比较 rvId/generation，就不会受记忆化策略变化影响，属可选收紧，不是当前缺陷。
3. **ServerWorld 的 9 个公开入口**：`objectModData`（L140）、`getSpriteName`（L182、L274）、`isPlayerObject`/`isVehicleObject`（L287-L288）、`squareContainsObject`（L322）、`removeGenericObject`（L336）、`getCellForPlayer`（L412）、`getSquare`（L419）、`squareSnapshot`（L424、L449）。判断：全部是 RV_ServerWorld.lua:464-L478 的显式导出，不读其私有局部，不需要新接口。
4. **ServerUtil 的三个公开函数**：`toNumber`（L21）、`invoke`（L129、L154-L156、L175-L176、L187、L204、L279、L303、L311、L314、L316、L428）、`classInstance`（L174、L248、L294、L302）。判断：同上，公开合同。
5. **对象 ModData tag 是跨模块持久数据合同**：读在 `objectTag`（L139-L146：`owner`/`templateIndex`，以及 L226 的 `role`/`edgeKey`），写方是 `ServerWorld.tagObject`（RV_ServerWorld.lua:178-L211）；同一 namespace 还有第二个写入方 `RV_BoundaryServer_Objects.lua:309`（playerBuilt 形状，见 server-Common.md 接口章节）。判断：**保留直接读**。本模块读的字段与创建器写入的字段一一对应，tag 布局本身就是合同；新增 getter 会把「哪些字段稳定」变成隐式承诺，而本模块是除创建器外唯一需要 `templateIndex` 语义的读者。若将来字段扩展，应与 Construction 的对象生成侧一起迁移。
6. **ctx 注入的 7 个字段**：`Constants`、`RV`、`ServerUtil`、`ServerWorld`、`createCapturedTemplateObject`、`configureCapturedDoorFrame`、`Boundary`（L8-L14）。其中后两者由 `RV_Server_WorldObjects.lua:813-L814` 发布，装载顺序在本模块之前（RV_Server.lua:142 → :145）。判断：显式依赖注入，比直接 require Construction 更清晰，保持。

### 接口边界问题

- **移除来源标记的所有权与命名不一致**（L334-L338、L461-L466）：`_templateProtectionRepairRemovalObject` 用下划线前缀表达私有，但它挂在 Core 拥有的 `RV.Server` 上，且 L461 的加载时捕获意味着「`RV.Server` 尚未创建时查询函数永不安装」。建议把标记收回本文件闭包，只保留公开查询（同第 1 条）；这不是当前故障，是接口形状问题。
- **`onPostPlayerTick` 的 `tick` 与 `activeBoundaries` 形参未被读取**（L154，函数体 L155-L166 只用 activePlayers；调用点 RV_BoundaryServer_Sweep.lua:175-L176 仍按 3 参传递）：当前行为等价，但读者会以为队列按传入 tick 节流或按活跃 boundary 选择工作。**源码事实**：采样节拍由 `Core.tickModulo(sampleInterval)` 自取（L160），队列处理与 `activeBoundaries` 无关。建议删除多余形参（同时改调用点）或让 `tick` 真正参与节流。
- **`repairCell` 的三类失败语义必须由调用方区分**（L392-L459 与 RV_TemplateRecovery.lua:137-L147）：`false` 是正常跳过（buildable 格、无期望项、无可修复项），`false, reason` 是前置条件不可用（stale generation、cell/square/snapshot/floor），raise 是数据或引擎断言失败（ledger 不一致、移除不可观测）。当前队列对 `false` 不打印、对 `false,reason` 打印 skipped、对 raise 打印 failed，是正确的消费方式；任何新增调用方都必须沿用。
- **`repairCell` 依赖 Boundary 准入缓存的「热态」（条件性推断）**：L393 用缺省参数调用 `boundaryForPlayer`，`deferValidationMiss` 不为 true 时冷缓存返回 `nil` 而不是 `"validation-deferred"`（RV_BoundaryServer_Geometry.lua:246-L250 与 BoundaryValidation 的缓存分支，见 server-BoundaryGuard.md）。因此没有预热时本函数会走 `"queued RV generation is stale"` 分支跳过该格。RV 内玩家由 30 tick 周期预热（RV_RailroaderServer_Tick.lua:37），实际影响需运行时验证；本报告只陈述静态路径。
- **每格重建 shell edge map 是显式取舍**（L52-L55、L404）：`shellEdgeMap` 每次调用都遍历 `boundary.shellEdges` 并做完整一致性校验，未做缓存。当前每 tick 只修 1-4 格（L82-L86），成本可接受；若提高预算，应先考虑按 `rvId:generation` 记忆化，而不是删掉校验。
- **`RV.Server` 查询在加载时安装**（L461-L467）：若 `RV.Server` 尚不存在，`isTemplateProtectionRepairRemoval` 永不安装，WallReloadProtection 的存在性检查会静默降级为「不认为这是修复移除」（RV_RailroaderServer_WallReload.lua:159-L160），后果是墙体重载可能把修复移除当玩家拆墙处理。当前装载顺序（RV_Server.lua:72-L74 → :145）保证成立，属隐式装配合同。

## 函数清单、覆盖和验证记录

- **扫描文件**：`RV_Server_TemplateProtectionRepair.lua`（473 行）、`RV_TemplateRecovery.lua`（175 行）；目录扫描确认 TemplateRecovery/ 恰有这 2 个 Lua 文件、无子目录，合计 **648** 行（`(Get-Content f).Count`，含空行）。
- **函数定义扫描**：逐行分类扫描（排除 `type(x) ~= "function"` 比较行与含 `function` 字样的注释行）得到 31 与 9，合计 **40**，与上表一致。构成：36 个 `local function`（Repair 28、Recovery 8）、1 个表字段函数（Repair L463）、2 个模块工厂匿名函数（Repair L6、Recovery L9）、1 个 `pcall` 匿名闭包（Repair L132）。两个文件的 `function` 关键字命中数分别为 31、9，没有非定义命中，因此本目录不存在「关键字命中 ≠ 定义数」的偏差。
- **逐行交叉核对**：两个文件按编号全文读取（1-473、1-175）；条目中的行号都是定义语句（或函数表达式赋值）的起始行；跨行签名以首行为准。
- **跨模块调用扫描**：在 `media/lua` 全树检索 `TemplateRecovery`、`RecoveryQueue`、`repairCell`、`isTemplateProtectionRepairRemoval`、`_templateProtectionRepairRemovalObject`，命中只有 RV_Server.lua:145-L146（装配顺序：Repair 先于 Recovery）、RV_BoundaryServer_Sweep.lua:168-L177（每 tick 调用）、RV_RailroaderServer_WallReload.lua:157-L166（移除来源过滤）与本目录自身。
- **旧报告失效项（源码事实）**：旧报告描述的单文件 1,729 行版本、其按该单文件编号的行号区间（如 2–198、429–1040、1578–1728）与「70 个具名函数 + 5 个匿名闭包」口径对当前源码全部失效；旧报告提到的拆分产物 `RV_TemplateRecoveryIndex.lua`、`RV_TemplateRecoveryQueue.lua` 与 `RV_Server_RoofRelocation` 在当前树中都不存在；旧报告列出的公开入口 `Boundary.onTemplateProtectionRepairTick`、`Boundary.observeTemplateProtectionRepairTransitions`、`Boundary.sampleTemplateProtectionRepairPlayer`、`Boundary.processTemplateProtectionRepairQueue`、`Boundary.shouldSampleTemplateProtectionRepair`、`Boundary.ensureGeneratorForEntry`、`ctx.reconcileCurrentTemplateCell`、`Boundary.addTransitionLifecycleListener`、`Boundary._templateProtectionRepairPauseUntil`、`Boundary._templateProtectionRepairActiveTransitions`、`Boundary._templateProtectionRepairRemovalTraceRegistered`、`Boundary._builders` 清理、`RV.Server.Construction.restoreCurrentCell`、`repairTemplateProtectionLayer`、`repairQueuedTemplateProtectionXY`、`repairTemplateProtectionCoordinate` 全树命中数为 0；模板索引现在是模块级 `entriesByCell`（L37-L50），转换暂停、事件监听、`_states` 遍历与 `_builders` 过期清理都不再由本目录承担。`ensureGeneratorForEntry` 已迁到 Construction（RV_Server_WorldObjects.lua:702 与 :815、RV_Server_GenerationBuild.lua:158-L162），不再属于本目录。
- **未覆盖项 / 条件性推断**：源码事实包括文件与行数、函数数与起始行、调用点、未被读取的形参、公开导出与旧符号消失；条件性推断只有两条——「冷缓存下 `repairCell` 会以 stale generation 跳过本格」与「每格重建 edge map 的成本随每 tick 预算变化」。没有穷举 ServerWorld/RoomTemplate 的每个调用行；未运行游戏、服务器或任何测试脚本，本文不宣称运行时行为已验证。
- **修改范围**：整体重写本分析文档 `docs/module-analysis/server-TemplateRecovery.md`；未修改任何 Lua 源码、配置或测试文件，未运行任何测试脚本。
