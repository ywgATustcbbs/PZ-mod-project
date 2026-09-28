# Railroader RV 重构设计细化草案

本文细化模块 0–10，并纳入追加的 GUI 模块 11。它是待实施的设计约定；本次只整理接口与复用边界，不移动或修改运行时代码。所有会读写世界、存档或联机状态的接口归服务端；客户端只提交意图和显示服务端结果。

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

这里的成本是 Lua 模板表访问/迭代次数，不会减少必须的 world 清理操作。当前没有完整的当前 generation 实例对象层 ledger：`RV_ProtectionManifest.lua:1–2, 13` 是静态模板身份/保护清单；`RV_Server_RoomOwnership.lua:128–136` 通过 `RV_ServerSchema.walkBounds` 清理旧 generation，而 `walkBounds` 固定遍历每个有效 z/x/y 并调用 `getSquare`（`RV_ServerSchema.lua:169–180`），`RV_ServerWorld.clearSquare` 再检查 square 内对象的 generation 身份（`RV_ServerWorld.lua:430–451`）。因此 restore 不能把三段全空误作无需世界检查；段标志只省去该段的 Lua `celldef` 索引。若以后有完整、严格校验且随每次对象增删原子更新的实例 ledger，才可由它枚举实际待清理对象并重新比较方案。

推荐按操作分流：全量建造必须先按权限/身份策略清理 `z=-32..31`，随后对每个非空 `celldef` cell 用 `pairs(layers)` 遍历，并仅在 `supportsZ(z)` 为真时解释或生成该层；恢复则每 XY 顺序检查 `z=-32..31`，利用三布尔摘要跳过空段的模板查找，但仍逐层执行安全的 world 清理。定义层内对象按有序数组处理；跨 z 的层顺序允许无序，不创建每次排序的索引。Lua 5.1 规范明确 `next` 的键枚举顺序未指定，`pairs` 基于 `next` 遍历所有键；Kahlua 手册将 `next`、`pairs`、`ipairs` 列为与 Lua 行为相同。当前没有游戏内 benchmark，所以“稀疏建造时 `pairs` 较少做查找”和“三段标志减少空段查表”是基于循环/查表数量的性能推断，不是实测结论；密集层、Kahlua 表迭代成本及 world API 成本都可能改变实际用时。

现有生成代码按模板对象清单顺序创建对象，全部创建后才执行结构重算，再创建 generator（`RV_Server_GenerationBuild.lua:218–259`）；当前模板有 `z=0` 与 `z=1` 定义（`RV_Template.lua:24–25, 341–347`），未发现要求这两个 z 之间固定先后的代码契约。依用户确认，跨 z 顺序可以任意；每个 `celldef[z]` 的对象数组仍保留模板顺序，以免改变同格多对象顺序。依据：[Lua 5.1 `next`/`pairs`](https://www.lua.org/manual/5.1/manual.html#pdf-next)、[Kahlua 手册中与 Lua 相同行为的函数](https://github.com/krka/kahlua/blob/master/docs/manual.txt)。

游戏 API 的坐标可行性有当前源码证据：服务端 schema 将合法 Z 声明为 `-32..31`，布局捕获会遍历这个闭区间，并以 `getGridSquare(x,y,z)` 探测各层；`isValidSquare(x,y,z)` 也用于 world 坐标预检。RV 现支持完整范围，采用 `maxZExclusive=32` 和 `[-32,32)`；所有建造、清理、恢复、映射、越界、屋顶、拆除、电水和通用查询均可覆盖 `z=31`。100×100×64 是游戏及 RV 全层操作的范围。未加载的 square 可能为空，世界变更前仍须完整预检。本设计没有把反编译缓存或静态 API 查询当成运行时验证。

证据：`RV_ServerSchema.lua:15–16, 169–180, 409–425`；`RV_Server_LayoutBuilder.lua:99–133, 463–469`；`RV_ServerWorld.lua:24–29`。这些当前源码支持完整 `z=-32..31` 范围及全层扫描设计；本设计仍未把静态 API 检查当成运行时性能验证。

## 建议目录

```text
media/lua/shared/RailroaderRV/RoomTemplate/
media/lua/server/RailroaderRV/Core/
media/lua/server/RailroaderRV/RVMapping/
media/lua/server/RailroaderRV/BoundaryGuard/
media/lua/server/RailroaderRV/RoofRefresh/
media/lua/server/RailroaderRV/DemolitionProtection/
media/lua/server/RailroaderRV/TemplateRecovery/
media/lua/server/RailroaderRV/Power/
media/lua/server/RailroaderRV/Water/
media/lua/server/RailroaderRV/Construction/
media/lua/server/RailroaderRV/Common/
media/lua/client/RailroaderRV/GUI/
```

模块文件只由自身目录持有；跨模块通过小型返回表或 Core 注册接口协作。Core 是服务端唯一事件入口。不要让挪入新目录的文件继续各自注册同一个 `OnTick` 或同一对象事件。

## 模块职责与接口

### 0. 房车核心 `Core`

**接口：**`getTick()`、`tickModulo(interval)`、`registerTick(name, interval, callback)`、`registerCommand(name, callback)`、`readConfig()`、`readCurrentStore(schemaKey)`、`commitStore(schemaKey, value)`、`sendToClient(player, command, payload)`。变更类调用返回成功标记和稳定原因；异常、缺少接口、身份/schema 不确定时拒绝并保持失败状态。

**内部功能：**唯一注册 `OnTick`、客户端命令和服务端对象事件；每个 server tick 只推进一次统一的逻辑时钟，再按 interval 调用模块；管理模块启动顺序、当前 schema gate、ModData 根节点读写、命令路由、同步、事务互斥和统一日志。具体模板、建筑、电水算法留在功能模块。

用户要求的 64 位 tick 不应保存为一个 Lua number。建议用精确的 `{hi32, lo32}` 无符号计数对，每 tick 进位一次，由 Core 提供 `tickModulo(interval)`，其他模块不拼接或比较原始大整数。该时钟是进程内调度时钟，不持久化、不由客户端同步；重启后重新计数。若它以后要作为存档身份，需另外定义持久化 schema。

现有 `RV_Server_Commands.lua:43–65, 184–220, 272–300` 注册了通用 `OnTick`、`OnClientCommand` 和对象事件；Railroader adapter 的 `RV_RailroaderServer_Tick.lua:171–258` 又维护 `_ticks` 并注册 tick/移除事件。将事件入口集中到 Core，但保留各服务的处理函数。当前源码没有可复用的 sandbox 写入 API：`readConfig()` 读取经服务端校验的配置；不要在运行时直接改写 `SandboxVars`。若“配置读写”指可持久编辑值，将其定义为当前 schema 下的模组设置记录，并由 Core 原子提交。

### 1. 房间模板 `RoomTemplate`

**接口：**`get(templateId)`、`validate(template)`、`supportsZ(z)`、`hasLayer(template,x,y,z)`、`hasAnyLayer(template,x,y,zMin,zMax)`、`segmentMayHaveLayer(template,x,y,segment)`、`cellAt(template,x,y)`、`roofTargets(template)`。`supportsZ` 对 `-32..31` 返回 true；段标志与有效 `celldef` 层必须严格一致。所有坐标以模板锚点为原点；纯数据函数不得读取 world 或修改对象。

**内部结构：**每模板一个不可变 table：`metadata`（id、显示名、template/schema 版本、锚点和三段摘要 schema）；`bitmap[y][x]`（三个布尔段摘要，精确定义见前节）；稀疏的 `celldef[y][x].layers[z]`（墙、家具、实体、地板等的有序对象数组及各对象拆除策略）；`misc`（多个按常见命中优先排序的合法行走 AABB、建造 AABB、屋顶刷新目标及身份信息）。所有 `-32..31` 定义，包括 `z=31`，都正常参与摘要一致性、有效对象数、保护策略校验、查询和对象迭代；不得兼容旧逐层位图。

保留同一格/层多个对象和模板顺序；不能把当前扁平对象表按 XY 合并时丢弃重复对象。`allowDemolition` 建议作为清晰枚举或对象策略而非格层整体 bool，因为一个格层可能既有允许拆除家具，也有受保护墙。屋顶目标应记录模板局部坐标和预期对象身份，实例化后再由映射/锚点变换。

复用 `RV_Template.lua:7–23` 的锚点、显式建造格和对象清单；把并行的 `RV_ProtectionManifest.lua:13–17, 462–475` 策略/身份数据合并到相应对象定义或保留为只读生成来源；复用 `RV_TemplateGeometry.lua:49–143` 坐标转换和索引思路及 exact-key 验证。`RV_Bitmap.lua` 继续只服务边界/建造许可区域，不复用其逐层字节/hex 格式表示模板对象层。需要重组织：`RV_Layout.lua:233–290, 365–404` 当前运行时从捕获对象、构建许可和静态边界重新派生模板/边界位图；将其改成明确的模板解析器，不让每个消费者各自解释捕获数据。三布尔摘要/celldef 一致性、对象数和保护策略检查覆盖 `z=-32..31` 的全部 64 层。

### 2. 房车-玩家-车辆映射 `RVMapping`

**接口：**`findAtPosition(serverPosition)` 对 `z=-32..31` 返回唯一的 `{rvId,generation,bitmapVersion,templateId,anchor,record}` 或明确的无匹配/冲突结果；完整有效高度均参与匹配。`findForPlayer(player, freshPosition)` 从服务端玩家对象取身份/坐标并查询；`getCurrent(rvId)` 取得经过当前 schema 校验的记录。重叠多个 RV 区域时必须拒绝歧义，不按表遍历顺序任意选一个。

**内部功能：**维护玩家、机车、RV、模板实例、generation 的双向关系和坐标区域索引；从 Core 读写当前 mapping schema；提交或重新生成时检查范围不重叠、模板存在、generation 一致。它不验证 Lua 客户端给的可信位置，也不要求 live train 必须在线才能解析持久化的 RV。

复用 `RV_RailroaderServer_Mapping.lua:40–105, 121–153, 229–280, 566–613`：当前 map 有 strict schema、玩家坐标查 `record.region`，不依赖 room ID 或生成对象；无 live locomotive 时保留已验证映射。将局部 `recordAtPlayerCoordinate` 变成明确公开 API；坐标采样/cache 由 Common 提供，不在多个 mapping 入口重复读。

### 3. 防越界 `BoundaryGuard`

**接口：**`contains(templateInstance, position)`、`checkPlayer(player, freshPosition, tick)`、`onTick(tick)`。Core 按 interval 调用 `onTick`；callback 不再自行向 `Events.OnTick` 注册或重复计数。

**内部功能：**遍历在线玩家，使用 fresh server position 映射到当前 RV 和模板后，按模板给定顺序逐一检查合法行走 AABB；常见命中区域排在前面，命中任一立即判定合法，全部未命中才判定越界。越界时从已验证 mapping 取出生点/入口，服务端校验 square 世界坐标和加载状态后传送并同步。操作期间存在 generation/roof relocation lease 时暂缓修正。

复用 `RV_BoundaryServer_Sweep.lua:75–145` 的在线玩家遍历、transition lease 和队列调度。重新组织目前分散的 boundary snapshot、epoch 和 interval；AABB 按模板的显式顺序逐个测试，首个命中即合法、全未命中才纠正。安全纠正一律使用 fresh server position，区域判定只读 RoomTemplate 中的合法行走 AABB。

### 4. 屋顶刷新 `RoofRefresh`

**接口：**服务端入口 `request(rvIndex, reason)`、`process(tick)`、`refreshOne(rvRecord, roofTarget)`。`rvIndex` 只作查找键；Mapping/Core 必须据当前 schema、权限和服务端状态将其解析为唯一 current RV record/identity，缺失、过期、歧义或未经授权时拒绝。客户端提交的索引和 reason 均为不可信请求字段，不能直接作为身份或事实使用。

**内部功能：**由 mapping 解析模板实例和 `misc.roofTargets`，去重、检查当前 generation/schema 与相关 square 已加载，执行屋顶/房间刷新；需要临时移玩家时持有 Core 的受限 transition lease，完成后按服务端记录送回。失败不吞事件、不错误报告成功。

复用 `RV_RoofRefresh.lua:318–359` 对既有 captured floor 做 room metadata recalc 和前后对象身份校验的实现；复用 `RV_RailroaderServer_RoofRefresh.lua:276–340, 562–650` 的进入/墙移除触发、重复事件去重、队列和玩家 relocation 流程。当前逻辑刷新的是南窗外既有地板的房间/屋顶邻接元数据，不负责补建或删除屋顶物件；迁移后保留这个边界，通用 roof target 再逐项接入。

### 5. 拆除防护 `DemolitionProtection`

**接口：**`canDemolish(actor, object, currentIdentity)`、`observeRemoval(object, actor)`、`onBuildAttempt(object, actor)`。前者是便于交互层的只读预判；真正放行/拒绝、归属标记和恢复排队由服务端处理。

**内部功能：**把 `celldef` 的拆除策略解释为允许、拆后恢复、禁止/立即恢复或专用策略；核对 object tag 的 owner、templateIndex、RV id、generation、bitmapVersion 和 footprint；处理玩家建造边界。未知归属/旧 generation 对象 fail closed，不靠客户端 tag 判定。

复用 `RV_BoundaryServer_Objects.lua:177–263, 381–435, 547–625` 的壳墙归属、玩家建筑审计与建造/对象事件；复用 `RV_ProtectedDemolition.lua:1–15` 作为客户端预判；复用 `RV_Server_TemplateProtectionRepair.lua:383–435, 1237–1398` 的拆除观察与模板身份检查。必须把 client action hook 降为 UX，不把它视为服务器安全边界。

### 6. 模板恢复 `TemplateRecovery`

**接口：**自动修复内部使用 `enqueue(currentIdentity,x,y,reason)`、`process(tick)`、`reconcileCell(currentIdentity,x,y)`；身份由服务端 Mapping 解析，不能从客户端直接采信。面向操作请求的恢复统一走 `Construction.restore(template,offsetX,offsetY,actor)`：模板由服务端注册表解析，XY 偏移是相对服务端已验证 RV 锚点的模板局部偏移，经范围/权限/schema 校验后才由服务端转换为 world anchor。

**内部功能：**按当前 RV/generation/bitmapVersion 建立有界、去重队列；每个任务再次过 schema、mapping、玩家范围、目标层和 square loaded 检查；仅修复策略明确要求恢复的模板索引。恢复不可判定归属的对象时停止，不清除旧 schema 或外部对象。每个 tick 的处理量和无玩家暂停条件由 Core interval/预算统一配置。

复用 `RV_Server_TemplateProtectionRepair.lua:246–324, 1237–1398, 1629–1742` 的 identity 暂停、3×3 采样、代际队列与逐坐标修复流程。`ensureGeneratorForEntry` 这类入口补建检查可以随政策搬入；事务、对象创建和 tag 写入改由 Construction/Common 共享。

### 7. 电力 `Power`

**接口：**`handleIntent(player, operation, itemHint)`、`onTick(tick)`、`settleAndRefresh(identity, player)`、`snapshotForPlayer(player)`、`initialize(identity)`。命令只传操作和不可信的物品提示；identity、目标设备、物品所有权和权限由服务器重新取得并验证。

**内部功能：**虚拟燃油/电池/负载结算、原版 generator 代理、设备扫描和状态快照；保存副本，执行世界/物品动作后再显式 commit；任何 API 或后置条件失败返回失败，不提交半份账本。

可直接拆分 `RV_UtilityPower.lua:363–405, 424–628, 639–704`、`RV_UtilityPowerDevices.lua:271–354`、`RV_UtilityServer.lua:235–352, 383–443` 与 `RV_UtilityStore.lua:51–60, 437–542`。保留设备缓存只存坐标/状态、不要持有长寿命 IsoObject 引用；utility identity 必须和 Mapping 的当前 generation/schema 对齐。

### 8. 供水 `Water`

**接口：**预期由服务端提供 `handleIntent(player, operation, itemHint)`、`onObjectAdded/Removed(object)`、`snapshotForPlayer(player)`；操作 identity 从 Mapping 解析，所有物体坐标、pipe 状态和目标范围由服务器重查。

**当前可复用边界：**现有 `RV_UtilityWater_Commands.lua`、`_Ledger.lua`、`_Objects.lua`、`_Plumbing.lua` 包含水量结算、连接、流水账和对象操作代码，但中央 `RV_UtilityServer.lua:4–9` 只装配 Store/Power/Devices，没有装配 Water；`RV_UtilityStore.lua:1–4` 与 README 开发期说明也明确当前合同不含水 identity、隐藏水箱或 proxy。故这些文件是待审计/停放实现，不能仅移动目录就重新启用。先确认目标供水行为和当前 schema 中要持久化的字段，再选取无旧身份依赖的纯 API；不得恢复旧记录、隐式创建旧水路对象或做数据迁移。

### 9. 建造 `Construction`

**接口：**内部 `build(template,offsetX,offsetY,actor)`、`restore(template,offsetX,offsetY,actor)`、`reconcileCell(currentIdentity,x,y)`。Core 路由的网络请求只携带 `templateId`、`offsetX`、`offsetY` 和 request ID；服务端从 RoomTemplate 注册表解析模板，以服务端 Mapping 中当前 RV 的锚点为基准验证偏移并计算 world anchor。客户端不能提交或指定可信 world anchor、RV identity、权限、generation 或模板对象；actor、mapping 和当前状态均由服务端取得并复核。成功返回 committed identity，失败返回稳定原因和可观测的事务阶段。

**建造步骤：**建造操作的空间范围是 XY 100×100、Z `-32..31`，共 100×100×64 个格层；包括 `z=31` 在内的所有有效层均可查询、清理、建造和回滚。事务顺序固定为：在 mutex 内校验服务端解析的模板、权限、当前 schema、当前 RV mapping、XY 偏移、world 坐标、目标范围不重叠及所有目标 square/API；确认目标范围可安全恢复后，先写入 current-schema 事务意图并完整保存 undo；然后清理有效范围 `z=-32..31` 中经上述策略许可的对象；全清理后，对每个非空 `celldef` cell 用 `pairs(layers)` 遍历其键，仅当 `supportsZ(z)` 为真时才解释该层并按层内对象数组顺序生成，层间顺序不作承诺。schema validator 接受 `z=-32..31` 的整数键并拒绝其他非法层键。最后核对对象身份/数量、重算邻接并同步，全部成功才提交并清除 undo。任一预检或快照不能覆盖本次完整清理目标时，必须在第一次世界修改前拒绝；清理、构建或核对失败则用 undo 回滚，回滚失败时保留事务阶段并封锁后续盲目重试，不得留下未记录的部分清场。要满足“清理范围内所有现有对象”的原始语义，必须先能完整快照并逆向重建该范围内所有受支持对象类型；能力不足时，只允许空白区域或仅含本 RV 当前 generation 所有对象的区域，否则整次拒绝，不得部分清场。只清理可识别的 RV 所有对象而保留任意对象，不等同于全量清除，需按上述限制明确接受。

**恢复步骤：**恢复接口同样接收服务端解析的模板、`offsetX/offsetY` 和 actor；服务端从 current mapping 确定锚点、校验偏移并转换坐标。它和建造共用身份、加载、逐 cell 生成和后置检查，但不做跨模板范围全量清除；遍历完整有效范围 `z=-32..31`，包括 `z=31`。由于恢复必须清理模板缺定义的层，且当前没有能列出实例全部存活对象的 ledger，对每个目标 XY 仍须逐层检查 world 并清理由该 RV 当前 generation 明确拥有且策略允许删除的对象。若对应段标志为 false，整段可判定为空并直接清理各 z，无需查询 `celldef[z]`；标志为 true 时逐 z 查层定义，nil 层清理、定义层按层内对象顺序幂等恢复。有效 `z=31` 的 celldef 正常参与摘要、对象数、保护策略、清理和恢复计划。模板没有定义不代表可以删除不明对象或其他玩家对象。重复执行应得到同一对象集合；部分失败保留可识别的 transaction phase，不能再次盲目清场。

可以借鉴 `RV_Server_GenerationFlow.lua:214–286, 328–336` 的阶段、预检、清理/建造与失败处理，`RV_Server_GenerationBuild.lua:109–180` 的 manifest identity 和生成构造，`RV_ServerWorld.lua:378–428` 的同步删除和邻接重算。`RV_Server_LayoutBuilder.lua:99–133, 187–192` 的全范围预检可以参考；其注释明确 arbitrary existing objects 没有通用事务式恢复能力，运行时移除失败会留下 partial clear。因此它当前用于布局采集/清场，不可直接当成具备完整 rollback 的通用建造器。若要求清除含任意既有建筑的 100×100×64 RV 有效范围，须先实现并验证完整对象快照与逆向构建能力；否则只接受空白或本 RV 当前代际独占范围。

### 10. 公用模块 `Common`

**接口：**`samplePlayerPosition(player,tick,interval)`、`getPlayerPosition(player,{fresh,maxAge})`、`invalidatePlayer(player,reason)`、`identityKey(...)`、`getSquare(cell,x,y,z)`、`invoke/callSucceeded(...)`、plain-table copy/exact-key/finite-number validators。

**内部功能：**服务端维护 identity/session/generation 标注的短期坐标缓存；按玩家身份和 tick 时间戳过期，在 teleport、进出 RV、断线重连、mapping epoch/generation 变化时失效。非实时 UI/批处理消费者可取最近快照；边界纠正、建造、拆除、权限和请求范围校验必须 fresh 采样，不接受过期缓存。

复用 `RV_ServerUtil.lua` 的安全调用/数值工具、`RV_ServerWorld.lua:24–27, 422–428` 的 world/square 与邻接操作、`RV_TemplateGeometry.lua:49–93` 纯坐标变换。当前多个位置/验证缓存各自维护 TTL 和 epoch（如 `RV_RailroaderServer_BoundaryValidation.lua:16–28` 与 Mapping），应抽到 Common 或留给对应模块但共用失效事件；缓存不能成为持久化身份。

### 11. GUI `GUI`

**接口：**`openBuildMenu(player)`、`requestBuild(templateId, offsetX, offsetY, requestId)`、`requestRestore(templateId, offsetX, offsetY, requestId)`、`onServerAck(command,args)`、`showSnapshot(snapshot)`。GUI 只提交模板选择和期望的模板局部 XY 偏移作为操作意图；这些字段可被伪造，服务端必须重新解析模板、读取 actor 的服务端坐标/当前 mapping、验证权限与范围并计算 world anchor。客户端不得提供可被信任的玩家坐标、RV identity/index、generation、当前权限、bitmap 或世界对象状态；返回 ACK 是 UI 展示依据，不是授权事实。

**内部功能：**菜单、模板选择、加载/失败状态、服务端 ACK 展示、超时与重复请求处理；仅将服务器确认的 template metadata 用于显示。GUI 不读写 mapping/manifest ModData，不本地建造/传送/改存档。

复用 `RV_ContextMenu.lua` 和 `RV_ContextMenu_Relocation.lua:30–36, 226–260, 376–488` 的意图请求、ACK 与等待状态；复用 `RV_RailroaderContextMenu.lua:171–189` 的 entry/exit 请求、`RV_UtilityClient.lua:90–161` 的请求封装与服务端快照显示、`RV_UtilityContextMenu.lua` 和 Dashboard 的操作面板。`RV_ContextMenu_LayoutBuilder.lua:6–18` 可作为最小菜单意图示例。`RV_ProtectedDemolition.lua` 的本地动作拦截留在 UX 层；是否可拆仍由模块 5 的服务端逻辑决定。

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

- 水模块要保留哪些功能，以及新供水 identity/tank 是否属于当前开发期 schema；旧 Water 文件存在不构成重启旧水路合同的授权。
- “Sandbox 配置写入”若指修改游戏 `SandboxVars`，当前 RV 源码没有展示可复用写接口；设计采用只读沙盒输入，需写入的模组选项落在新声明的当前 schema 中。
- 100×100×64 的 RV 有效范围是否需要全范围加载、清理和回滚。按现有证据，枚举 Z 坐标可行，但加载成本及任意既有对象可逆恢复能力未得到运行时验证。若不限定空白/独占范围，当前代码不能承诺原子回滚。
- 建造目标由管理员选点还是玩家近距离选点、多个模板是否允许空间重叠，须在接口实现前确定校验规则；服务端始终重算目标并检查唯一性。

静态核对命令：`rg -n "RV_MANAGED_MIN_Z_OFFSET|RV_MANAGED_MAX_Z_OFFSET|WORLD_MIN_Z|WORLD_MAX_Z|recordAtPlayerCoordinate|function Refresh.run|function M.handleCommand" RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua`。本次仅做设计与源码定向检查，不运行游戏联机测试。
