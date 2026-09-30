# `server/RailroaderRV/Water` 模块分析

## 假设、范围与验收条件

- 假设：当前工作副本中的 `media/lua/server/RailroaderRV/Water/` 是本报告要分析的完整服务端水务模块；共享身份/能力规则、调用者和存档门只作接口交叉核对，不纳入本模块函数清单。
- 范围：只读分析该目录 5 个 Lua 文件；引用 `shared/RailroaderRV/Water/RV_UtilityCatalog.lua`、`Core/RV_UtilityStore.lua`、`Core/RV_DevSaveSchemaGate.lua`、`Core/RV_UtilityServer.lua`、`RVMapping/RV_RailroaderServer_EntryExit.lua` 及通用工具，说明契约和调用关系。唯一写入目标是本文件。
- 成功条件：5 个文件的所有函数均逐项记录参数、返回/副作用、模块语义和当前必要性；列出跨模块复用、拆分和内部数据访问判断；水槽身份与存档 schema 的关系有当前源码行号依据；全树检索证据与未覆盖边界明确。
- 验证方式：文件清单、函数声明扫描、源码逐行交叉核对、文档结构和引用核验。该报告是静态分析；未改 Lua 源码，未运行 runtime 测试。

行号以当前包内 `media/lua/` 下源码为准。下文“必需”表示实现当前模块职责是否需要该功能，不表示这份 Lua 函数必须采用当前写法。

## 目录职责与函数清单

目录职责是服务端水槽连接事务：从客户端收到不可信目标提示后，由服务端重新定位并验证当前世界对象，核对 RV 映射身份和水管状态，给对象写入当前水槽身份，更新原生水管状态与持久 ledger，并在提交失败时补偿；另有延迟确认对象移除并清理 ledger 的流程。

目录包含 5 个文件、42 个函数定义。按文件计数：`RV_UtilityWater_Plumbing.lua` 7 个，`RV_UtilityWater_Objects.lua` 11 个，`RV_UtilityWater_Ledger.lua` 7 个，`RV_UtilityWater_Commands.lua` 14 个，`RV_UtilityWater.lua` 3 个。扫描没有发现匿名 `function(...)` 回调或函数赋值式回调。代码的分层是：对象解析/身份、ledger 校验和构造、原生水管变更补偿、命令与移除编排、对外 facade。

## 按文件与函数分析

### `RV_UtilityWater.lua`：模块 facade

- **`M.setConnection(identity, context, targetHint, record)`**（L7-L9）：`identity` 是当前 RV 的 `rvId/generation/bitmapVersion`；`context` 是服务端已解析的玩家/RV 上下文；`targetHint` 是客户端提交、仍须服务端重查的目标提示；`record` 是 Store 返回的本次工作副本。返回 `Commands.setConnection` 的所有返回值，没有额外副作用。作为 Core 与 Water 内部实现之间的稳定入口是必要的；自身不应承载校验或事务逻辑。
- **`M.onObjectRemoved(object)`**（L11-L13）：参数是即将从世界移除的对象；原样转发 Commands 的返回值和副作用。对外事件入口有意义；当前源码的实际事件注册/调用链未能由全树静态检索证实，见“调用接线风险”。
- **`M.onTick()`**（L15-L17）：无参数，无返回值；转发到 Commands 推进待确认移除队列。是异步移除清理的必要入口；上层 UtilityServer 会逐 tick 调用。

### `RV_UtilityWater_Plumbing.lua`：原生水管状态读写与补偿

- **`invoke(target, method, ...)`**（L8-L10）：`target` 为游戏对象，`method` 为方法名，余参原样传给该方法；返回 `Util.invoke` 的调用成功标记和结果。没有独立规则，可直接用 `Util.invoke` 替代；当前仅是本文件私有薄封装，功能不必单独保留。
- **`readState(object)`**（L12-L27）：读取 `getUsesExternalWaterSource()` 和 `getModData().canBeWaterPiped`。参数是待操作水槽对象；返回 `true, {connected, hasPipableFlag, pipableFlag}`，或 `false, API_ERROR/DEVICE_INVALID`。区分字段不存在和字段为 `false`，供事务保存原值；实现补偿必需。
- **`applyState(object, connected, pipableFlag)`**（L29-L49）：参数是对象、期望的原生连接位和期望的 modData 标记；调用 `setUsesExternalWaterSource`、写 `canBeWaterPiped`、发送 modData 与 `usesExternalWaterSource` 对象变更，再读回核验。返回 `accepted, observedStateOrNil`；副作用是世界对象变更和网络同步。对可验证提交及失败补偿必需。
- **`previousFlag(previous)`**（L51-L54）：参数为 `readState` 快照；返回原 `canBeWaterPiped` 值，原先没有此字段则返回 `nil`。使回滚能恢复“字段缺失”而非强行写入布尔值；补偿必需。
- **`M.readState(object)`**（L56-L58）：参数和返回值同私有 `readState`，无写副作用。当前 Water 目录及 `media/lua` 调用检索未发现外部调用者；若不打算将其作为诊断/测试 API 对外承诺，则不是当前连接流程必需的导出函数。
- **`M.apply(object, desiredConnected)`**（L60-L76）：参数为对象及严格布尔期望连接态；先读旧态、应用连接态与可水管标记、验证后置条件；失败时恢复旧态。成功返回 `true, {previous, observed}`；请求非法返回 `false, INVALID_REQUEST`；预读失败返回 `false, reason, true`；应用失败返回 `false, POSTCONDITION_FAILED, restoredBoolean, previous`。修改并同步对象，失败时负责原生状态补偿，是连接事务必需步骤。L69 的表达式问题及调用后果见后文。
- **`M.rollback(object, previous)`**（L78-L85）：参数是此前 `readState` 结构；拒绝缺少连接态/字段存在位的输入，否则恢复旧态并确认读回。返回严格布尔值，无额外结果。供 canonical commit 失败时恢复世界对象，事务补偿必需。

### `RV_UtilityWater_Objects.lua`：不可信目标解析和对象身份管理

- **`exactKeys(value, expected)`**（L12-L22）：`value` 是待校验表，`expected` 是以字符串组成的数组；逐项构造允许键集合，并要求无额外键且键数量相等。返回布尔值。限制网络 hint 字段形状所需；写法可换成适配该精确语义的共享 helper。
- **`integer(value)`**（L24-L28）：输入必须是有限 Lua number 且为整数；返回原数或 `nil`，不接受字符串数字。供世界坐标、objectIndex 和身份关联校验使用，拒绝小数/NaN/无穷值，当前安全校验必需。
- **`finite(value)`**（L30-L33）：输入为有限 number 时返回布尔 `true`，否则返回 `false`；只用于玩家坐标范围核对，当前必需。它不是整数校验。
- **`invoke(target, method, ...)`**（L35-L37）：参数与返回语义同本目录 Plumbing 的同名 wrapper，直接转发 `Util.invoke`。无额外语义，当前实现可内联替代，不必单独保留。
- **`validContext(context, identity)`**（L39-L59）：校验服务端 context、当前 `READY` 阶段、授权位、context record 与 identity 的 RV/generation/bitmap 一致性，并验证 slotIndex 对应的当前 anchor/region。返回 `true, record, expectedAnchor, region` 或 `false`。它不改世界；防止调用者传来的 context/映射错配，是定位 sink 的前置条件。
- **`withinReach(player, x, y, z)`**（L61-L71）：参数为服务端玩家与候选整数坐标；读取玩家三轴位置，要求均为有限 number，并按 3D 平方距离与 `U.DEVICE_REACH` 比较。返回布尔值。权限范围检查必需；距离常量定义于 shared `RV_UtilityConstants.lua:21`。
- **`hintValues(hint)`**（L73-L82）：参数是客户端提示表；只接受精确键 `{x,y,z,objectIndex,connected}`、布尔 `connected`、整数坐标和非负 objectIndex。返回五个标准化原值 `(x,y,z,index,connected)` 或 `nil`。只把提示视为定位/意图输入，不把坐标当作可信事实；服务端验证必需。
- **`findHintedObject(square, index)`**（L84-L96）：遍历 `World.squareSnapshot(square)`，用当前对象的 `getObjectIndex()` 匹配提示索引；只有恰好一个匹配时返回对象，否则 `nil`。不改世界；避免 stale/歧义对象索引，必需。
- **`M.resolveSink(identity, context, hint)`**（L98-L145）：参数为当前身份、服务端上下文、客户端提示；依次验证 hint、context/mapping、RV 区域及管理 Z 范围、玩家距离、cell/square 已加载、唯一对象、对象仍属于该 square、具有 FluidContainer、原生外接水状态可读，并核对已有对象标签是否属于当前 identity。成功返回 `true, {object,x,y,z,slotIndex,anchor,connected,currentConnected,hasIdentity}`；失败返回 `false, reason`。只读世界；将意图约束到服务端实际对象，是命令安全边界必需环节。
- **`M.ensureSinkIdentity(object, identity, mappingRecord)`**（L147-L180）：给没有身份标签的合格对象写当前 `Catalog.WATER_TAG_KEY` 标签，字段为 owner/role/RV identity/slot/anchor，广播并调用 `Catalog.isCurrentWaterSink` 做后置验证。已存在且当前标签返回 `true,{created=false}`；旧/畸形/错配标签拒绝；新写成功返回 `true,{created=true,tag}`；失败会清除刚写标签并同步，返回失败原因和是否成功补偿。对象标签写入与回滚令牌是 ledger 更新事务必需的身份绑定。
- **`M.rollbackSinkIdentity(object, identityToken)`**（L182-L190）：仅当令牌声明本次创建且对象当前 tag 与令牌中的 tag 是同一 table 时清除标签并同步；未创建时视为无需回滚而返回 `true`。返回补偿是否确认成功。避免清掉外部/后续写入的身份数据，失败路径必需。

### `RV_UtilityWater_Ledger.lua`：当前水槽 ledger 校验和条目构造

- **`sameAnchor(a, b)`**（L11-L14）：比较两个表的 x/y/z；返回布尔值。不单独验证 exact keys/整数，因为此处字段已由 schema/slot 生产路径约束；供映射归属核验，必需。
- **`mappedEntry(entry, identity, mappingRecord, sink)`**（L16-L24）：确认 entry 属于同一 rvId/generation/bitmapVersion/slot/anchor，且 entry 坐标等于 sink 坐标；返回布尔值。将 ledger 命中锁定到本 RV 当前映射，必需。
- **`M.validateMapping(water, identity, mappingRecord)`**（L26-L47）：验证 schema gate 已 ready、参数表结构、Water 状态、映射 slot/anchor 与 `RegionSlots` 一致，以及 `water.sinks` 每项均对应当前身份/映射。返回 `true` 或 `false, INVALID_RV_DATA`。入口条件先允许 `ACTIVE` 或 `NEEDS_RECONCILE`，但循环后只有 `ACTIVE` 才返回成功（L45-L46）；因此 `NEEDS_RECONCILE` 最终仍会被拒绝。`setConnection` 使用它禁止异常 ledger 继续连接，必需；前置状态允许项可以简化，但不代表兼容旧状态。
- **`M.sinkKey(sink)`**（L49-L52）：参数为带 x/y/z 的 sink 表；把坐标转交 `Store.waterSinkKey`，返回规范坐标键或 `nil`。供 `getEntry` 查 ledger，功能必需；目前未发现目录外调用，因此若不打算提供公共 API，可收窄为文件内 local helper。键算法的唯一运行时实现归 Store。
- **`M.getEntry(water, identity, mappingRecord, sink)`**（L54-L62）：按 `sinkKey` 查找条目；已存在时用 `mappedEntry` 验证。返回 `false, INVALID_RV_DATA`，或 `true, entryOrNil, key`。是调用端核对当前连接值/身份的必需读接口。
- **`M.newEntry(identity, mappingRecord, sink, connected, sequence)`**（L64-L76）：以当前 identity/mapping/sink 生成 ledger entry，复制 anchor，`connected` 归一化为 `connected == true`，sequence 缺省为 0。返回新表，不修改 Water 容器；写入当前 schema 条目必需。
- **`M.copyEntry(entry)`**（L78-L90）：复制 entry 的当前字段和 anchor；非表输入返回 `nil`。返回用于事务补偿的副本，不做 store commit。commit 失败时恢复旧 ledger entry 必需；它是按当前 schema 明确复制，不承担旧 schema 转换。

### `RV_UtilityWater_Commands.lua`：连接命令和延迟移除协调

文件私有 `runtimeFaults` 与 `pendingRemovals` 表在 L14-L16 声明；没有导出，目录外无直接访问。前者阻止发生不确定补偿后的同 identity 操作，后者保存等待下一 tick 确认的对象移除见证。

- **`identityKey(identity)`**（L18-L21）：按 rvId/generation/bitmapVersion 拼接本进程故障分区键，返回字符串。用于隔离某代 RV 的故障状态，必需；已有 `Util.identityKey` 可表达相同字段身份且使用长度前缀，见通用性建议。
- **`markNeedsReconcile(identity, record)`**（L23-L29）：将工作副本 `record.water.state` 标为 `NEEDS_RECONCILE` 并 `Store.commit`；提交失败时设置本地 runtime fault。返回提交是否成功。记录无法确认的跨 world/store 状态，是 fail-closed 处理必需。
- **`currentMappingRecord(identity)`**（L31-L42）：通过 `_G.RailroaderRV.RailroaderServer.currentUtilityRecord(identity)` 取已校验的当前 mapping record；对调用用 `pcall`，失败返回 `false, INVALID_RV_DATA`，成功返回 `true, record`。查当前映射必需；该成员在 `RV_RailroaderServer_EntryExit.lua:171-L178` 是显式导出的 adapter 接口，不是读隐藏字段。
- **`copyIdentity(identity)`**（L44-L47）：只复制 rvId/generation/bitmapVersion，返回快照表。用于 pending 异步状态避免保留外部可变表别名，必需。
- **`copyMappingRecord(record)`**（L49-L53）：验证 record/anchor 是表后只复制 slotIndex 和 anchor 三轴，否则返回 `nil`。返回 pending 使用的最小映射快照，防止后续引用变动，必需。
- **`sinkCoordinates(object)`**（L55-L65）：读取 object square 和 x/y/z，再用 `Util.integer` 验证坐标；成功返回 `{x,y,z}`，失败 `nil`。用于 ledger 键和移除见证定位，必需。
- **`pendingKey(identity, x, y, z)`**（L67-L70）：把 identity key 与坐标合成移除队列键，返回字符串。将同一身份/坐标的重复事件幂等化，必需。
- **`pendingCount(identity)`**（L72-L79）：统计队列中属于该 identity 的待确认项，返回计数。决定完成一项后 Water 状态是否仍须 reconcile，必需。
- **`markRemovalFault(pending, record)`**（L81-L84）：有工作副本时调用 `markNeedsReconcile`，并无条件设置此 identity 的 runtime fault。没有显式返回值；把不可安全完成的异步清理锁定为故障，必需。
- **`processRemoval(pending, pendingId)`**（L86-L174）：单次 tick 处理一项移除见证。参数为 pending 快照和队列 id；无显式返回值。cell/square 暂不可读时最多累计 `REMOVAL_CONFIRM_TICKS=20` 次后标故障；严格 snapshot 不完整、原对象仍在、映射变化、同坐标出现另一当前身份 sink 或 store/ledger 校验失败时标故障并丢弃 pending；确认原对象已不在且当前映射仍一致后移除 ledger 项、提交，并依据余下 pending 数恢复 `ACTIVE` 或保持 `NEEDS_RECONCILE`。会读写世界快照、队列、canonical Store；延迟提交 sink 删除、防止把“about to remove”误认为已删除，是必需流程。
- **`M.onObjectRemoved(object)`**（L176-L232）：接收引擎即将移除的对象；未带水槽身份直接返回 `true`；否则读取当前 tag identity/坐标、当前 mapping、记录和 ledger entry，验证原生连接状态与 ledger 一致后先持久化 `NEEDS_RECONCILE`，再登记 pending。重复同对象事件幂等；冲突/验证失败返回 `false, reason`，成功返回 `true`。有写 Store 和私有队列的副作用。实现上必要，但调用它的 hook 是否确已注册无法由当前静态调用图确认。
- **`M.onTick()`**（L234-L238）：无参数、无显式返回值；遍历 pending 并调用 `processRemoval`。推进移除见证到提交的必需驱动函数。
- **`hasPipeWrench(player)`**（L240-L245）：读取玩家 inventory 并查询 `Base.PipeWrench`；返回是否包含工具。连接操作的服务端物品权限校验，必需。
- **`M.setConnection(identity, context, hint, record)`**（L247-L315）：入口参数与 facade 相同。拒绝非当前/故障/非 ACTIVE 记录、缺 Pipe Wrench、ledger mapping 不一致、对象解析失败、原生态与 ledger 不一致、对象标签有无与 ledger 不一致；随后确保身份、应用 Plumbing、产生新 sequence/entry 并 Store.commit。成功返回 `true,{record,connected,sequence}`；失败返回 `false,reason`，必要时恢复 ledger、原生水管状态和 tag，并把不确定补偿持久化成 reconcile。这个函数是完整连接事务编排核心，必需。

### 连接事务中的布尔表达式静态发现

`Commands.setConnection` 将客户端 `hint.connected` 作为待验证意图传入解析结果；L290-L292 再以 `desired = sink.connected` 调用 `Plumbing.apply(sink.object, desired)`。`Plumbing.apply` 的 L69 使用 `desiredConnected and false or true` 计算 `desiredPipable`。在 Lua 中，无论 `desiredConnected` 为真还是假，该表达式的结果恒为 `true`：真时 `true and false` 得 `false`，随后 `false or true` 得 `true`；假时直接落到 `or true`，仍得 `true`。

因此，静态确定的结果是每次 apply 都向 `applyState` 传 `pipableFlag=true`。`applyState` 会把它写入 `object:getModData().canBeWaterPiped`（L31-L37），并用同一个期望值做读回后置核验（L42-L48），所以核验会接受这个恒 true 的标记。原生连接位仍按 `desiredConnected` 设置并同步。L67-L69 的注释意图是“连接后不再可供水管操作；断开后可再次操作”，但标记实际始终为 true。共享 `Catalog.isWaterPipedDevice` 会把 `canBeWaterPiped == true` 视为可水管设备（`shared/RailroaderRV/Water/RV_UtilityCatalog.lua:125-L130`），故运行时后果是连接后该能力标记仍保持可水管，而不是由此即可断言原生 `connected` 状态或整个连接事务必然失败。此处是代码静态推演，尚未运行时验证。

## 当前水槽身份 schema 与 shared 校验的关系

水对象 tag 和 Store 持久 Water ledger 是两种不同结构，均只认可当前 schema：

1. **对象身份 tag**：shared `Catalog` 声明精确字段 `owner, role, rvId, generation, bitmapVersion, slotIndex, anchor` 和 tag 键 `RailroaderRVTestWater`（`shared/RailroaderRV/Water/RV_UtilityCatalog.lua:13-L16`）。`tagForObject` 拒绝额外/缺失字段与 metatable，要求 owner/role 当前、rvId 非空、generation 正整数、bitmapVersion 等于当前 `C.BITMAP_VERSION`、anchor 与 `RegionSlots.indexToAnchor(slotIndex)` 一致（L27-L69）。`isCurrentWaterSink(object, identity, mappingRecord)` 还核对当前 identity、slot 和 anchor（L91-L106）。服务端 `ensureSinkIdentity` 只在 tag 键完全不存在时新建当前格式；任何非 nil 的旧、别名、畸形或错配 tag 都拒绝覆盖（server `RV_UtilityWater_Objects.lua:147-L179`）。这条路径没有旧字段兼容、转换或迁移。
2. **Water 存档 ledger**：SchemaGate 的当前 sink entry 精确字段为 `rvId, generation, bitmapVersion, slotIndex, anchor, x, y, z, connected, sequence`（`Core/RV_DevSaveSchemaGate.lua:1027-L1028,1051-L1069`）；Water 容器精确字段为 `schemaVersion, sinks, state`，版本取当前 `U.WATER_SCHEMA_VERSION`，state 只接受 `ACTIVE` / `NEEDS_RECONCILE`，并要求 map key 等于坐标键（L1071-L1085）。`Store.getRecord` 和 `Store.commit` 都要求 schema gate ready，且 getRecord 对既有记录复制当前记录、对错代 identity 拒绝（`Core/RV_UtilityStore.lua:126-L151,154-L180`）；Ledger 自己再逐 entry 核对 mapping/current identity（本目录 `RV_UtilityWater_Ledger.lua:26-L47`）。
3. **两者的关联**：对象 tag 证明世界对象属于当前 RV generation/bitmap/slot/anchor；ledger entry 额外记录该对象坐标、连接布尔值和 sequence，作为 canonical 状态。`resolveSink` 用 shared Catalog 验 tag，再用 Ledger 与 Store 数据比对。无 tag 的原生候选对象可以在当前操作中被赋予当前格式 tag；这是新身份登记，不是对旧 schema 的兼容。已有任何非 nil 但无效 tag 都不会降级当成未标记对象。

## 模块间复用、拆分和直接数据访问

### 有通用性的函数

- `Commands.identityKey` 的 identity 由三部分组成；`Common.identityKey` 已是通用的长度前缀键生成器，且经 `RV_ServerUtil` 暴露为 `Util.identityKey`（`Common.lua:124-L134`、`RV_ServerUtil.lua:11-L19,86-L98`）。Water 本地 `:` 拼接没有单独格式需求，改用既有函数可减少重复并避免分隔符歧义；提取新函数没有必要。
- `Objects.invoke` 和 `Plumbing.invoke` 都是 `Util.invoke` 的无语义薄封装（各自 L35-L37、L8-L10），应以内联调用现有通用 API 消除重复。shared Catalog 的 `invoke`（`shared/RailroaderRV/Water/RV_UtilityCatalog.lua:108-L112`）是跨 shared/server 边界的本地安全调用器；目前 shared 目录没有同等通用公共调用器，移动它需要调整共享层依赖，收益小于改动成本，可继续局部保留。
- `Objects.integer/finite/exactKeys` 与 `Common`、shared Catalog、SchemaGate 存在同类校验。不能直接把 `Objects.integer` 替换为 `Common.integer`：`Common.integer` 先 `toNumber`，接受可转换字符串/Java numeric value（`Common.lua:57-L78`），而客户端 hint 当前要求原生 number。`Common.exactKeys` 接受 expected set 和 optional mapping，不拒绝 metatable（L80-L97）；Objects 使用数组并严格计数，shared Catalog 还拒绝 metatable（Catalog L27-L37）。若后续要抽取，应先提供可选择并文档化“原生数字/精确键/是否拒绝 metatable”的共享契约；当前为了省几行而合并会改变输入边界。
- sink 坐标键已由 `Store.waterSinkKey` 集中供 Ledger 使用（Store L45-L49、L237-L239；Ledger L49-L52）。SchemaGate 为启动前独立验证存档而保留自己的纯校验键函数（L1036-L1040）；不要让启动 gate 依赖 Store，因为 Store 又依赖 gate。若要统一算法，可把严格坐标键放入不依赖 Store/Gate 的 shared 纯 helper，再由两侧依赖；目前两处都是简单 `x:y:z` 且语义一致，收益有限。
- `sameAnchor`、`copyIdentity`、`copyMappingRecord`、`copyEntry` 都绑定当前 mapping/schema 的窄数据形状。通用化会牺牲只复制必需字段和严格身份边界的清晰度，不建议单独提取。

### 是否进一步拆分

当前 5 文件边界基本清楚：对象与身份、ledger、原生管道、命令编排和 facade 各自职责集中。`Commands.lua` 是最大文件（317 行），包含连接事务及异步移除状态机，可考虑未来把 pending removal lifecycle 拆成 `Removal` 子模块。但两条路径共用 `runtimeFaults`、reconcile 持久状态、mapping/store gate；现在拆分会增加跨文件状态接口和协调参数，未显示出明显高于新增复杂度的收益。结论：当前没有必须继续拆分的文件；若移除状态机继续增长，再以单一 Removal API 封装其私有队列后拆分。

### 模块直接访问其他模块数据与接口收益

- **Water Commands → `record.water.state/sinks`**：Commands 在 L25、L159-L170、L192-L218、L248-L315 直接读写持久 Water 子表；`Ledger` 已提供 entry 校验/构造/复制，但没有 set/remove/state transition 接口。这是模块内最明显的跨文件 ledger 数据访问。可为 `Ledger` 增加窄的 `setEntry/removeEntry/setState` 内存工作副本接口，让 Commands 仍负责事务与 `Store.commit`，由 Ledger 维护条目形状和状态前置条件。收益中等：维护 Water 不变量更集中；改变需要新增/维护 API，当前只有 Commands 写入、SchemaGate 再做完整持久 schema 核验，所以不是阻止理解/运行的缺陷。
- **Water Commands → adapter `currentUtilityRecord`**：通过 `_G.RailroaderRV.RailroaderServer` 取当前 mapping；这是明确导出的 adapter 方法（`RV_RailroaderServer_EntryExit.lua:171-L178`），且代码检查函数存在并用 `pcall`。直接调用公共合同合理，额外包装接口收益不明显。
- **Water Objects → `context` 字段**：读取 `authorized/phase/record/player`，并由 `record` 读取 RV mapping identity/slot/anchor（Objects L39-L59、98-L145）。调用者通过 `resolveCurrentUtilityRV` 获得 context，Core UtilityServer 验证 `authorized`、附上 `player` 后传入 Water（`Core/RV_UtilityServer.lua:51-L69,283-L298`）。这是水务层与 Core 间隐式结构合同；当前由服务端传入并再校验 record identity，属于合同字段读取，不是访问全局隐藏状态。若更多服务层复用，可用小型只读上下文对象；目前一个调用点，收益不高。
- **Water Objects → 对象 modData 的身份 tag**：直接读写 game object `getModData()` 下由 shared Catalog 公布的 `WATER_TAG_KEY`，并通过 Catalog 的只读校验 API 检查后置条件（Objects L147-L190；Catalog L13-L16、71-L106）。对象写入和补偿必须在 server；把写操作挪入 shared Catalog 会混合共享规则与服务端世界修改，收益低于职责成本。保持当前直接写游戏对象、共享 Catalog 只验证身份是合理的。
- **Water Plumbing → `canBeWaterPiped` modData**：读写由游戏水管流程使用的对象属性（Plumbing L12-L49），不是 RailroaderRV 内部 Lua 模块隐藏状态；直接访问属于原生对象 API 适配，不宜为形式上的封装再加接口。
- **隐藏状态边界**：`runtimeFaults` 和 `pendingRemovals` 只在 Commands 文件中创建和读写，没有被其他模块引用；没有看到跨模块直接访问这些运行时局部状态。`Store.getRecord` 返回工作副本，`Store.commit` 显式复制并持久化（Store L143-L180），Water 没有直接访问 Store 的全局 ModData root。

## 调用接线、验证证据与未覆盖项

- **连接路径**：`Core/RV_UtilityServer.lua` 引入 facade（L9），处理 CONNECT_WATER_DEVICE 时调用 `Water.setConnection(identity, context, args.targetHint, record)`（L290-L298）；facade 转到 Commands；Commands 再调用 Objects、Ledger、Plumbing 和 Store。`UtilityServer.onTick` 每 tick 调用 `Water.onTick`（L390-L400；更外层 `Core/RV_Server_Commands.lua:64-L65` 驱动 utility tick）。
- **移除路径接线未证实**：Water Commands 与 facade 定义 `onObjectRemoved`（本目录 Commands L176-L232、facade L11-L13），Core UtilityServer 也定义包装器并调用 `Water.onObjectRemoved`（`Core/RV_UtilityServer.lua:411-L422`）。全 `media/lua/` 树执行 `rg -n 'UtilityServer\.onObjectRemoved|Water\.onObjectRemoved|onObjectRemoved\(' media/lua --glob '*.lua'`，仅命中 Water facade 定义/转发（`Water/RV_UtilityWater.lua:11-L12`）、Commands 定义（`Water/RV_UtilityWater_Commands.lua:176`）、UtilityServer wrapper 定义/其对 Water 的调用（`Core/RV_UtilityServer.lua:414-L415`）；没有 `UtilityServer.onObjectRemoved` 的引用或调用点。全树再执行 `rg -n 'OnObjectAboutToBeRemoved' media/lua --glob '*.lua'`：显式服务端注册命中 Adapter（`Core/RV_RailroaderServer_Tick.lua:260-L262`）、RoomOwnershipRemovalScan（`Core/RV_Server_Commands.lua:292-L293`）和 TemplateProtectionRepair trace（`TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:369-L374`）；客户端命中的是房间 ownership 刷新（`client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua:484-L486`），其余命中为 Core 白名单/注释/世界移除语义。没有一个注册点指向 `UtilityServer.onObjectRemoved`。`RV_UtilityServer.lua:411` 注释称 Core owner 注册该 wrapper，与可见的显式接线不吻合。结论仅是静态接线缺口/不确定性；本次不运行时测试，不能据此断定游戏运行时绝对没有模组外注册。
- **文件/函数清单验证**：`rg --files media/lua/server/RailroaderRV/Water` 返回上述 5 个文件；`rg -n '(^\s*(local\s+)?function\s+|=\s*function\s*\(|function\s*\()' ...` 共命中 42 条函数定义；单独 `rg -n 'function\s*\('` 没有命中匿名函数。每条定义已对照报告函数标题与源码位置。
- **逐行交叉核对范围**：读取了 5 个完整 Water 源文件；对照 Shared Catalog、Utility constants、ServerUtil/Common、UtilityStore、DevSaveSchemaGate 中 Water 相关段落、UtilityServer 调用点、mapping adapter 公共导出及事件注册点。文中身份字段和存档 sink 字段分别核对 Catalog L13-L16/L53-L106、SchemaGate L1027-L1085、Store L126-L180；表达式发现核对 Plumbing L29-L49/L60-L75 与 Commands L283-L315。
- **文档验证**：完成后检查本文件存在、必需章节和 5 个源码文件名均有记录；源码只读，未运行 Lua/runtime 测试。
- **未覆盖项**：未检查 client 水务 UI/发送 hint 的完整实现；未检查官方游戏 runtime 中移除事件的真实触发次序；没有通过联机实测确认 `canBeWaterPiped` 的游戏表现或 pending-removal 回调是否来自本模组以外的加载器。

## 第二阶段 helper 更新

Objects/Commands/Plumbing 已删除仅转发 `Util.invoke` 的本地 wrapper，改用 ServerUtil；Objects 的 strict integer 也复用共享 `StrictSchema.integer`。Water Objects 的 `exactKeys` 保持原合同：拒绝额外/缺失 key，但不像 shared helper 一样拒绝 metatable，因此本轮不替换。Water identity key 改用 `ServerUtil.identityKey`，调用前仍由领域逻辑校验身份字段。见[第二阶段报告](phase2-structure-optimization.md)。




