# Railroader RV 重构设计细化草案

本文记录 RailroaderRV 当前目录拆分后的模块边界与接口，并保留后续设计约定。运行时代码已按 `Core`、`Common`、`Construction`、`RVMapping`、`BoundaryGuard`、`RoofRefresh`、`DemolitionProtection`、`TemplateRecovery`、`Power`、`Water`、`RoomTemplate` 和 `GUI` 分组；各节须结合当前实现状态阅读。目录迁移本身不授权修改运行时行为、当前 schema 声明或存档门逻辑。所有会读写世界、存档或联机状态的接口归服务端；客户端只提交意图和显示服务端结果。

## 关键设计决定

- 每个模块有自己的目录，并按运行域放入 `media/lua/shared/RailroaderRV/`、`media/lua/server/RailroaderRV/` 或 `media/lua/client/RailroaderRV/`。模板是只读共享数据；Core、映射和所有世界操作仅放服务端；GUI 仅放客户端。共享常量仍是无世界副作用的数据契约。
- **模板层存在摘要**与当前边界/许可位图是两种不同数据。模板摘要回答“这个 XY 格的某个 Z 段是否有模板定义”；当前 `RV_Bitmap` 回答逐 Z 层哪些 XY 可走、可建。不得共用字段或把其中一个解释成另一个。
- 对当前声明的 schema 做完整校验后才能进行任何 RV 操作。缺失、过期、字段别名、部分写入或版本不符即拒绝，并明确提示删除测试存档后重建；不迁移、不猜测、不走旧结构回退。
- 游戏与 RV 的有效世界 Z 均为 `z=-32..31`，共 64 层；所有范围用 `maxZ` 半开区间表示，即 `[-32,32)`。模板层存在性用三段布尔摘要和 `celldef`，不使用逐层位编码或 Lua 位运算。建造范围、边界 AABB、映射记录和位图的 `minZ/maxZ` 仍须分别声明。
- 任何全量建造、恢复、拆除或回滚先验证身份、权限、目标、schema、事务阶段、方块加载状态和可用世界 API。客户端提供的坐标只是意图，不能作为服务端事实。

## 模板层存在摘要与遍历选择

模板有效 Z 范围是 `[-32,32)`，即 `z=-32..31` 共 64 层，分为 `[-32,-1]`、`[0,3]`、`[4,31]` 三段。每个 XY 单元的模板 `bitmap[y][x]` 保存三个布尔值：`negative`、`z0to3`、`z4to31`。每个标志当且仅当对应段至少有一个有效 `celldef[y][x].layers[z]` 非空对象数组时为 `true`；否则为 `false`。`celldef` 可稀疏，空 XY 的 cell 或缺少的 `z` 键都表示没有模板定义。空对象数组不是合法层定义；`z=31` 是普通有效层，正常参与摘要。

模板层存在性完全取消逐层 bit 映射和位运算；`z=31` 不再是保留位或忽略层，而是第三段的最后一个有效 Z。`supportsZ(z)` 对整数 `-32..31` 返回 true；`celldef.layers` 仅接受这些整数键，所有范围外 Z、非整数键或未知字段由校验拒绝。摘要一致性、对象数、保护策略、查询、生成、清理和回滚都覆盖 `z=-32..31`。

目标结构是重构实施后新声明的当前模板 schema：完整的 100×100 三布尔摘要加 `celldef`。当前运行时代码仍使用既有旧结构；实施时必须更新 schema/version。重构后的加载器严格验证三个值均为 boolean，并逐 cell/段核对其与 `celldef` 的 `z=-32..31` 有效层完全一致；缺失、额外、过期或不匹配都 fail closed。旧结构的非空测试存档在切换到新 schema 后必须拒绝，并提示删除测试存档后重建；不提供旧 bitmap、别名、推断、转换、兼容或迁移分支。模板存在性通过三段布尔摘要和普通表键表达，不使用位运算；摘要不能取代 `celldef`，只用于快速判断整段是否确定为空。

| 方案 | 建造（全清理后） | 恢复（不全量清理） |
| --- | --- | --- |
| 每格三个段标志，true 时逐 z 查 `celldef[z]` | 可跳过 false 段的模板层查找；true 段仍检查其中每个 z，稀疏段会查到 nil。 | 每个 XY 仍需检查有效范围内的 world 层；false 段可直接按空层清理，不查 `celldef`，true 段逐 z 查表并区分定义层与空层。 |
| 固定遍历 `z=-32..31` 并访问 `celldef[z]` | 每个 XY 固定 64 次层查找，容易实现且可在同一顺序处理中建造。 | 每个 XY 固定 64 次层查找，可将清理和定义层恢复合并为一趟；空层也能被识别。 |
| `pairs(celldef.layers)` 遍历已定义层 | 遍历键时先用 `supportsZ(z)` 过滤，仅解释/生成 `z=-32..31`；对稀疏模板通常少于 64 次逐层索引，层间顺序无要求时适合生成。 | 单独遍历不能发现缺失的层键。仍须做有效 Z 清理扫描，或者使用能准确列出所有现存 RV 对象的当前 schema ledger；若额外再 `pairs` 建造，会多一次模板遍历。 |

这里的成本是 Lua 模板表访问/迭代次数，不会减少必须的 world 清理操作。当前没有完整的 generation 实例对象层 ledger：`RoomTemplate/` 保存静态模板身份/保护清单，`server/RailroaderRV/RoofRefresh/RV_Server_RoomOwnership.lua` 负责房间所有权扫描；普通构建回滚由 `Construction/` 按当前 generation 处理，通用旧代清理因没有完整 undo 而拒绝。因此不能把模板段摘要当成世界对象清单，也不能据它跳过需要的 world 检查。若未来另行授权完整、严格校验且随每次对象增删原子更新的实例 ledger，才可由它枚举实际待清理对象并重新比较方案。

下表比较模板层遍历方案的查表成本，不描述当前 Generate 的清理策略。当前 Generate 使用稀疏 bounds walker，只访问目标 cell 中已存在的 square；缺失的非模板 square 会跳过，目标不空或枚举不完整则在修改世界前 fail closed。它不要求 10,000 个管理区基面 square 预先存在。当前完整建造、清理和回滚约束见下方 Construction 一节。

若未来另行授权实现全量 restore，才按操作分流：对目标世界完成权限/身份与对象清单校验后，再对每个非空 `celldef` cell 用 `pairs(layers)` 遍历，并仅在 `supportsZ(z)` 为真时解释或生成该层；恢复则每 XY 顺序检查 `z=-32..31`，利用三布尔摘要跳过空段的模板查找，但仍逐层执行安全的 world 清理。该建议不改变当前 Generate 的稀疏预检和“目标须为空”门。定义层内对象按有序数组处理；跨 z 的层顺序允许无序，不创建每次排序的索引。Lua 5.1 规范明确 `next` 的键枚举顺序未指定，`pairs` 基于 `next` 遍历所有键；Kahlua 手册将 `next`、`pairs`、`ipairs` 列为与 Lua 行为相同。当前没有游戏内 benchmark，所以“稀疏建造时 `pairs` 较少做查找”和“三段标志减少空段查表”是基于循环/查表数量的性能推断，不是实测结论；密集层、Kahlua 表迭代成本及 world API 成本都可能改变实际用时。

现有生成代码按模板对象清单顺序创建对象，全部创建后才执行结构重算，再创建 generator（`server/RailroaderRV/Construction/RV_Server_GenerationBuild.lua:218–259`）；当前模板有 `z=0` 与 `z=1` 定义（`shared/RailroaderRV/RoomTemplate/RV_Template.lua:24–25, 341–347`），未发现要求这两个 z 之间固定先后的代码契约。依用户确认，跨 z 顺序可以任意；每个 `celldef[z]` 的对象数组仍保留模板顺序，以免改变同格多对象顺序。依据：[Lua 5.1 `next`/`pairs`](https://www.lua.org/manual/5.1/manual.html#pdf-next)、[Kahlua 手册中与 Lua 相同行为的函数](https://github.com/krka/kahlua/blob/master/docs/manual.txt)。

游戏 API 的坐标可行性有当前源码证据：服务端 schema 将合法 Z 声明为 `-32..31`，布局捕获会遍历这个闭区间，并以 `getGridSquare(x,y,z)` 探测各层；`isValidSquare(x,y,z)` 也用于 world 坐标预检。RV 现支持完整范围，采用 `maxZExclusive=32` 和 `[-32,32)`；所有建造、清理、恢复、映射、越界、屋顶、拆除、电水和通用查询均可覆盖 `z=31`。100×100×64 是游戏及 RV 全层操作的范围。未加载的 square 可能为空，世界变更前仍须完整预检。本设计没有把反编译缓存或静态 API 查询当成运行时验证。

证据来自 `server/RailroaderRV/Common/RV_ServerSchema.lua`、`server/RailroaderRV/Construction/RV_Server_GenerationFlow.lua`、`server/RailroaderRV/Construction/RV_Server_GenerationBuild.lua` 与 `server/RailroaderRV/Common/RV_ServerWorld.lua`。这些当前源码支持完整 `z=-32..31` 坐标范围，以及稀疏 square 遍历和按需创建模板 host 的流程；静态 API 检查不代表运行时性能验证。

## 当前模块目录

```text
media/lua/shared/RailroaderRV/{Common,RoomTemplate,RVMapping,Water,Power}/
media/lua/server/RailroaderRV/{Core,Common,Construction,RVMapping,BoundaryGuard,RoofRefresh,DemolitionProtection,TemplateRecovery,Power,Water}/
media/lua/client/RailroaderRV/GUI/
```

模块文件只由自身目录持有；跨模块通过小型返回表或 Core 注册接口协作。Core 是服务端唯一事件入口。迁移过程中保留的顶层 Lua 文件只作为 require 转发入口，不重复持有模块实现。不要让挪入新目录的文件继续各自注册同一个 `OnTick` 或同一对象事件。

## 模块职责与接口

### 0. 房车核心 `Core`

**接口：**`getTick()`、`tickModulo(interval)`、`registerTick(name, interval, callback)`、`registerCommand(name, callback)`、`readConfig()`、`readCurrentStore(schemaKey)`、`commitStore(schemaKey, value)`、`sendToClient(player, command, payload)`。变更类调用返回成功标记和稳定原因；异常、缺少接口、身份/schema 不确定时拒绝并保持失败状态。

**内部功能：**唯一注册 `OnTick`、客户端命令和服务端对象事件；每个 server tick 只推进一次统一的逻辑时钟，再按 interval 调用模块；管理模块启动顺序、当前 schema gate、ModData 根节点读写、命令路由、同步、事务互斥和统一日志。具体模板、建筑、电水算法留在功能模块。

用户要求的 64 位 tick 不应保存为一个 Lua number。建议用精确的 `{hi32, lo32}` 无符号计数对，每 tick 进位一次，由 Core 提供 `tickModulo(interval)`，其他模块不拼接或比较原始大整数。该时钟是进程内调度时钟，不持久化、不由客户端同步；重启后重新计数。若它以后要作为存档身份，需另外定义持久化 schema。

现有 `server/RailroaderRV/Core/RV_Server_Commands.lua:43–65, 184–220, 272–300` 注册了通用 `OnTick`、`OnClientCommand` 和对象事件；Railroader adapter 的 `server/RailroaderRV/Core/RV_RailroaderServer_Tick.lua:171–258` 又维护 `_ticks` 并注册 tick/移除事件。Core 是当前事件入口，功能服务保留自己的处理函数。当前源码没有可复用的 sandbox 写入 API：`readConfig()` 读取经服务端校验的配置；不要在运行时直接改写 `SandboxVars`。若“配置读写”指可持久编辑值，将其定义为当前 schema 下的模组设置记录，并由 Core 原子提交。

### 1. 房间模板 `RoomTemplate`

**接口：**`get(templateId)`、`validate(template)`、`supportsZ(z)`、`hasLayer(template,x,y,z)`、`hasAnyLayer(template,x,y,zMin,zMax)`、`segmentMayHaveLayer(template,x,y,segment)`、`cellAt(template,x,y)`、`roofTargets(template)`。`supportsZ` 对 `-32..31` 返回 true；段标志与有效 `celldef` 层必须严格一致。所有坐标以模板锚点为原点；纯数据函数不得读取 world 或修改对象。

**内部结构：**每模板一个不可变 table：`metadata`（id、显示名、template/schema 版本、锚点和三段摘要 schema）；`bitmap[y][x]`（三个布尔段摘要，精确定义见前节）；稀疏的 `celldef[y][x].layers[z]`（墙、家具、实体、地板等的有序对象数组及各对象拆除策略）；`misc`（多个按常见命中优先排序的合法行走 AABB、建造 AABB、屋顶刷新目标及身份信息）。所有 `-32..31` 定义，包括 `z=31`，都正常参与摘要一致性、有效对象数、保护策略校验、查询和对象迭代；不得兼容旧逐层位图。

保留同一格/层多个对象和模板顺序；不能把当前扁平对象表按 XY 合并时丢弃重复对象。`allowDemolition` 建议作为清晰枚举或对象策略而非格层整体 bool，因为一个格层可能既有允许拆除家具，也有受保护墙。屋顶目标应记录模板局部坐标和预期对象身份，实例化后再由映射/锚点变换。

复用 `shared/RailroaderRV/RoomTemplate/RV_Template.lua:7–23` 的锚点、显式建造格和对象清单；把并行的 `shared/RailroaderRV/RoomTemplate/RV_ProtectionManifest.lua:13–17, 462–475` 策略/身份数据合并到相应对象定义或保留为只读生成来源；复用 `shared/RailroaderRV/RoomTemplate/RV_TemplateGeometry.lua:49–143` 坐标转换和索引思路及 exact-key 验证。`shared/RailroaderRV/Common/RV_Bitmap.lua` 继续只服务边界/建造许可区域，不复用其逐层字节/hex 格式表示模板对象层。需要重组织：`shared/RailroaderRV/RoomTemplate/RV_Layout.lua:233–290, 365–404` 当前运行时从捕获对象、构建许可和静态边界重新派生模板/边界位图；将其改成明确的模板解析器，不让每个消费者各自解释捕获数据。三布尔摘要/celldef 一致性、对象数和保护策略检查覆盖 `z=-32..31` 的全部 64 层。

### 2. 房车-玩家-车辆映射 `RVMapping`

**接口：**`findAtPosition(serverPosition)` 对 `z=-32..31` 返回唯一的 `{rvId,generation,bitmapVersion,templateId,anchor,record}` 或明确的无匹配/冲突结果；完整有效高度均参与匹配。`findForPlayer(player, freshPosition)` 从服务端玩家对象取身份/坐标并查询；`getCurrent(rvId)` 取得经过当前 schema 校验的记录。重叠多个 RV 区域时必须拒绝歧义，不按表遍历顺序任意选一个。

**内部功能：**维护玩家、机车、RV、模板实例、generation 的双向关系和坐标区域索引；从 Core 读写当前 mapping schema；提交或重新生成时检查范围不重叠、模板存在、generation 一致。它不验证 Lua 客户端给的可信位置，也不要求 live train 必须在线才能解析持久化的 RV。

复用 `server/RailroaderRV/RVMapping/RV_RailroaderServer_Mapping.lua:40–105, 121–153, 229–280, 566–613`：当前 map 有 strict schema、玩家坐标查 `record.region`，不依赖 room ID 或生成对象；无 live locomotive 时保留已验证映射。将局部 `recordAtPlayerCoordinate` 变成明确公开 API；坐标采样/cache 由 Common 提供，不在多个 mapping 入口重复读。

### 3. 防越界 `BoundaryGuard`

**接口：**`contains(templateInstance, position)`、`checkPlayer(player, freshPosition, tick)`、`onTick(tick)`。Core 按 interval 调用 `onTick`；callback 不再自行向 `Events.OnTick` 注册或重复计数。

**内部功能：**遍历在线玩家，使用 fresh server position 映射到当前 RV 和模板后，按模板给定顺序逐一检查合法行走 AABB；常见命中区域排在前面，命中任一立即判定合法，全部未命中才判定越界。越界时从已验证 mapping 取出生点/入口，服务端校验 square 世界坐标和加载状态后传送并同步。操作期间存在 generation/roof relocation lease 时暂缓修正。

复用 `server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Sweep.lua:75–145` 的在线玩家遍历、transition lease 和队列调度。重新组织目前分散的 boundary snapshot、epoch 和 interval；AABB 按模板的显式顺序逐个测试，首个命中即合法、全未命中才纠正。安全纠正一律使用 fresh server position，区域判定只读 RoomTemplate 中的合法行走 AABB。

### 4. 屋顶刷新 `RoofRefresh`

**接口：**服务端入口 `request(rvIndex, reason)`、`process(tick)`、`refreshOne(rvRecord, roofTarget)`。`rvIndex` 只作查找键；Mapping/Core 必须据当前 schema、权限和服务端状态将其解析为唯一 current RV record/identity，缺失、过期、歧义或未经授权时拒绝。客户端提交的索引和 reason 均为不可信请求字段，不能直接作为身份或事实使用。

**内部功能：**由 mapping 解析模板实例和 `misc.roofTargets`，去重、检查当前 generation/schema 与相关 square 已加载，执行屋顶/房间刷新；需要临时移玩家时持有 Core 的受限 transition lease，完成后按服务端记录送回。失败不吞事件、不错误报告成功。

复用 `server/RailroaderRV/RoofRefresh/RV_RoofRefresh.lua:318–359` 对既有 captured floor 做 room metadata recalc 和前后对象身份校验的实现；复用 `server/RailroaderRV/RoofRefresh/RV_RailroaderServer_RoofRefresh.lua:276–340, 562–650` 的进入/墙移除触发、重复事件去重、队列和玩家 relocation 流程。当前逻辑刷新的是南窗外既有地板的房间/屋顶邻接元数据，不负责补建或删除屋顶物件；迁移后保留这个边界，通用 roof target 再逐项接入。

### 5. 拆除防护 `DemolitionProtection`

**接口：**`canDemolish(actor, object, currentIdentity)`、`observeRemoval(object, actor)`、`onBuildAttempt(object, actor)`。前者是便于交互层的只读预判；真正放行/拒绝、归属标记和恢复排队由服务端处理。

**内部功能：**把 `celldef` 的拆除策略解释为允许、拆后恢复、禁止/立即恢复或专用策略；核对 object tag 的 owner、templateIndex、RV id、generation、bitmapVersion 和 footprint；处理玩家建造边界。未知归属/旧 generation 对象 fail closed，不靠客户端 tag 判定。

复用 `server/RailroaderRV/DemolitionProtection/RV_BoundaryServer_Objects.lua:177–263, 381–435, 547–625` 的壳墙归属、玩家建筑审计与建造/对象事件；复用 `client/RailroaderRV/GUI/RV_ProtectedDemolition.lua:1–15` 作为客户端预判；复用 `server/RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:383–435, 1237–1398` 的拆除观察与模板身份检查。必须把 client action hook 降为 UX，不把它视为服务器安全边界。

### 6. 模板恢复 `TemplateRecovery`

**接口：**自动修复内部使用 `enqueue(currentIdentity,x,y,reason)`、`process(tick)`、`reconcileCell(currentIdentity,x,y)`；身份由服务端 Mapping 解析，不能从客户端直接采信。面向操作请求的恢复统一走 `Construction.restore(template,offsetX,offsetY,actor)`：模板由服务端注册表解析，XY 偏移是相对服务端已验证 RV 锚点的模板局部偏移，经范围/权限/schema 校验后才由服务端转换为 world anchor。

**内部功能：**按当前 RV/generation/bitmapVersion 建立有界、去重队列；每个任务再次过 schema、mapping、玩家范围、目标层和 square loaded 检查；仅修复策略明确要求恢复的模板索引。恢复不可判定归属的对象时停止，不清除旧 schema 或外部对象。每个 tick 的处理量和无玩家暂停条件由 Core interval/预算统一配置。

复用 `server/RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:246–324, 1237–1398, 1629–1742` 的 identity 暂停、3×3 采样、代际队列与逐坐标修复流程。`ensureGeneratorForEntry` 这类入口补建检查可以随政策搬入；事务、对象创建和 tag 写入改由 Construction/Common 共享。

### 7. 电力 `Power`

**接口：**`handleIntent(player, operation, itemHint)`、`onTick(tick)`、`settleAndRefresh(identity, player)`、`snapshotForPlayer(player)`、`initialize(identity)`。命令只传操作和不可信的物品提示；identity、目标设备、物品所有权和权限由服务器重新取得并验证。

**内部功能：**虚拟燃油/电池/负载结算、原版 generator 代理、设备扫描和状态快照；保存副本，执行世界/物品动作后再显式 commit；任何 API 或后置条件失败返回失败，不提交半份账本。

当前实现位于 `server/RailroaderRV/Power/RV_UtilityPower.lua`、`server/RailroaderRV/Power/RV_UtilityPowerDevices.lua`、`server/RailroaderRV/Core/RV_UtilityServer.lua` 与 `server/RailroaderRV/Core/RV_UtilityStore.lua`。保留设备缓存只存坐标/状态、不要持有长寿命 IsoObject 引用；utility identity 必须和 Mapping 的当前 generation/schema 对齐。本次仅调整模块边界，不改现有供电行为。

### 8. 供水 `Water`

**当前集成状态：**Water 已由服务端 Utility 服务接入，实现在 `server/RailroaderRV/Water/`，共享目录 `shared/RailroaderRV/Water/` 提供目录与 sink 能力定义。当前 sink 操作、Mapping 身份复核、玩家工具/范围检查、存档提交和失败补偿以 [README](README.md) 的“RV 水管连接”合同为准。这里记录的是已接入模块的归属，不是停放实现；本次模块目录收尾不得重启旧水路方案，也不得改变当前 sink identity 写入时机、交互约束或已声明 schema 门。

目录迁移不新增隐藏水箱、proxy、自动 sink 标记或迁移分支。模块的后续 API 扩展须另有明确授权；本次保持当前 Water 与 Power 行为不变。

### 9. 建造 `Construction`

**接口：**内部 `build(template,offsetX,offsetY,actor)`、`restore(template,offsetX,offsetY,actor)`、`reconcileCell(currentIdentity,x,y)`。Core 路由的网络请求只携带 `templateId`、`offsetX`、`offsetY` 和 request ID；服务端从 RoomTemplate 注册表解析模板，以服务端 Mapping 中当前 RV 的锚点为基准验证偏移并计算 world anchor。客户端不能提交或指定可信 world anchor、RV identity、权限、generation 或模板对象；actor、mapping 和当前状态均由服务端取得并复核。成功返回 committed identity，失败返回稳定原因和可观测的事务阶段。

**当前建造流程：**现行 Generate 先按当前 Mapping 分配空闲 slot，在 staging 迁移完成后等待目标 IsoCell，并复核合法坐标和 schema。它不要求 10,000 个管理区基面 square 预先存在，也不强制加载全部上层。加载区预检与清理使用稀疏 bounds walker：只读取当前 cell 中已存在的 square，缺失的非模板 square 跳过；对象枚举不完整或任一已存在目标 square 含对象时，在首次世界修改前拒绝，因为当前存档没有对任意既有对象的完整 undo。相同 slot 已有上一代时也拒绝重建，不调用通用旧代清理。通过预检后，Construction 仅在捕获模板对象的 host square 上生成对象；缺少的 host square 按需创建，不创建空白基面。RoomDef 检查和回滚遵循当前 generation 阶段，并要求相应结构及 roof host 已加载。对象身份、generation 标签、同步和失败回滚以当前实现为准；不得把“扫描有效范围”解释成“要求整个 100×100 基面已加载”。

目前没有独立的通用 `restore` 网络操作。未来若另行设计恢复接口，仍须由服务端解析 Mapping 和 actor、限定当前 generation 所有且身份完整的对象，并对未知对象 fail closed；这份建议不是本次实现或改动 schema 的授权。

旧 `LayoutBuilder` 清场/采集入口已经停用，服务端和客户端文件均已删除。它不能作为当前 Generate 的加载检查、稀疏清理或事务回滚实现参考；当前行为由 `server/RailroaderRV/Construction/` 与 `server/RailroaderRV/Common/` 中的代码持有。

### 10. 公用模块 `Common`

**接口：**`samplePlayerPosition(player,tick,interval)`、`getPlayerPosition(player,{fresh,maxAge})`、`invalidatePlayer(player,reason)`、`identityKey(...)`、`getSquare(cell,x,y,z)`、`invoke/callSucceeded(...)`、plain-table copy/exact-key/finite-number validators。

**内部功能：**服务端维护 identity/session/generation 标注的短期坐标缓存；按玩家身份和 tick 时间戳过期，在 teleport、进出 RV、断线重连、mapping epoch/generation 变化时失效。非实时 UI/批处理消费者可取最近快照；边界纠正、建造、拆除、权限和请求范围校验必须 fresh 采样，不接受过期缓存。

复用 `server/RailroaderRV/Common/RV_ServerUtil.lua` 的安全调用/数值工具、`server/RailroaderRV/Common/RV_ServerWorld.lua` 的 world/square 与邻接操作，以及 `shared/RailroaderRV/RoomTemplate/RV_TemplateGeometry.lua` 的纯坐标变换。位置与验证缓存仍由其当前所有模块管理并共用失效事件；缓存不能成为持久化身份。

### 11. GUI `GUI`

**接口：**`openBuildMenu(player)`、`requestBuild(templateId, offsetX, offsetY, requestId)`、`requestRestore(templateId, offsetX, offsetY, requestId)`、`onServerAck(command,args)`、`showSnapshot(snapshot)`。GUI 只提交模板选择和期望的模板局部 XY 偏移作为操作意图；这些字段可被伪造，服务端必须重新解析模板、读取 actor 的服务端坐标/当前 mapping、验证权限与范围并计算 world anchor。客户端不得提供可被信任的玩家坐标、RV identity/index、generation、当前权限、bitmap 或世界对象状态；返回 ACK 是 UI 展示依据，不是授权事实。

**内部功能：**菜单、模板选择、加载/失败状态、服务端 ACK 展示、超时与重复请求处理；仅将服务器确认的 template metadata 用于显示。GUI 不读写 mapping/manifest ModData，不本地建造/传送/改存档。

复用 `client/RailroaderRV/GUI/RV_ContextMenu.lua` 与 `client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua` 的意图请求、ACK 与等待状态；复用 `client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua` 的 entry/exit 请求、`client/RailroaderRV/GUI/RV_UtilityClient.lua` 的请求封装与服务端快照显示，以及 `client/RailroaderRV/GUI/RV_UtilityContextMenu.lua` 和 Dashboard 的操作面板。旧 LayoutBuilder 菜单已删除，不再作为客户端入口示例。`client/RailroaderRV/GUI/RV_ProtectedDemolition.lua` 的本地动作拦截留在 UX 层；是否可拆仍由模块 5 的服务端逻辑决定。

## 依赖方向与当前 schema 门

```text
GUI ──intent──> Core ──dispatch──> Mapping / Construction / Power / Water
                                  ├─> BoundaryGuard
                                  ├─> RoofRefresh
                                  ├─> DemolitionProtection ──> TemplateRecovery
                                  └─> TemplateRecovery ──cell reconcile──> Construction
RoomTemplate + Common ───────────────> all server modules
```

依赖只向下；RoomTemplate 和 Common 不调用玩法模块；Construction 不反向依赖 Recovery；Core 不实现玩法规则。所有持久化 root 要精确验证版本、必需字段、额外字段、数组完整性及 identity 关联。新模板位图编码或映射字段不兼容时，增加当前声明 schema/version 并立即 fail closed；不提供旧 bitmap、alias、bounds、mapping 或 generation 转换分支。初始空容器按当前 schema 初始化仍可允许；非空旧存档提示用户删除测试存档并重建。

## 需要后续确认的实现边界

- Water 已接入并按当前 README 合同运行；本次不改变 sink identity、工具/范围门、存档提交或失败补偿。新增水箱、proxy、自动标记和 schema 扩展均不在本次目录收尾的授权范围内。
- “Sandbox 配置写入”若指修改游戏 `SandboxVars`，当前 RV 源码没有展示可复用写接口；设计采用只读沙盒输入，需写入的模组选项落在新声明的当前 schema 中。
- 当前 Generate 不要求 100×100 基面或全部上层 square 预先加载；它稀疏枚举当前 cell 的已有 square，并在目标对象/枚举不完整时于世界修改前拒绝。具体流式加载成本仍需游戏内联机验证；这个验证边界不改变当前 fail-closed 和回滚门。
- 建造目标由管理员选点还是玩家近距离选点、多个模板是否允许空间重叠，须在接口实现前确定校验规则；服务端始终重算目标并检查唯一性。

静态核对命令：`rg -n "RV_MANAGED_MIN_Z_OFFSET|RV_MANAGED_MAX_Z_OFFSET|WORLD_MIN_Z|WORLD_MAX_Z|recordAtPlayerCoordinate|function Refresh.run|function M.handleCommand" RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua`。本次仅做设计与源码定向检查，不运行游戏联机测试。
