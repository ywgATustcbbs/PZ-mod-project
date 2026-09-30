# `server/RailroaderRV/TemplateRecovery/` 模块分析

## 范围、假设与成功条件

- 范围是 `media/lua/server/RailroaderRV/TemplateRecovery/` 下的全部代码；目录当前只有 `RV_Server_TemplateProtectionRepair.lua` 一个文件，共 1,729 行。
- 本报告按 Lua 实际函数定义逐项列出具名函数、工厂函数与匿名闭包。函数“必要性”指它是否支撑当前模板保护恢复功能、安全约束或模块间接线；日志诊断函数单独标为可选诊断。
- `ctx`、`Boundary`、`RV.Server` 及模板数据按源码中实际使用的字段和调用方式视为模块接口。带下划线的 `Boundary` / `RV.Server` 字段视为隐藏实现状态，除非已有外部调用明确依赖。
- 成功条件：逐函数说明职责、模块语义、参数、返回值/副作用和必要性；列出跨模块复用、拆分和内部状态耦合；用源码扫描、行号复核和文档检查验证覆盖。
- 这是静态只读分析；未改 Lua 源码，也未运行 runtime 测试。

## 1. 文件与模块职责

| 文件 | 职责 |
|---|---|
| `RV_Server_TemplateProtectionRepair.lua` | 注入当前 RV 的边界、服务端世界操作、模板、保护清单和对象工厂；根据已提交且身份一致的 manifest 建立受保护模板坐标索引；按玩家附近的 XY 队列逐格扫描已加载层，识别可安全移除的错误对象，补回或核对受保护的模板对象；在玩家进入 RV 时确认发电机；在边界转换期间暂停恢复队列。 |

模块的外部入口是一个初始化工厂 `return function(ctx)`（第 2–40 行）。它注册边界转换监听器和对象移除事件，然后向 `Boundary` 与 `ctx` 暴露少量服务。队列每次只处理一个 XY 坐标；每格再遍历 bitmap 的 Z 层。扫描必须先通过当前玩家、RV 身份、manifest schema、对象归属、模板身份、可移除范围、容器和多格 footprint 等检查。

初始化硬门（第 22–40 行）要求服务函数存在、当前 template metadata/object 数为 412、模板和保护 manifest 验证通过；否则立即报错。因此该模块针对当前捕获模板和当前 schema 工作，不是一般的建筑清理器。

## 2. 函数清单

下表行号是源文件中的定义行；所有返回值与副作用均按静态代码路径整理。

### 2.1 初始化、身份和队列键（第 2–198 行）

| 函数 / 行 | 参数含义 | 功能、输出或副作用 | 必要性 |
|---|---|---|---|
| `return function(ctx)` / 2–40 | `ctx`：服务端启动器提供的 Core、Boundary、常量、World/Util 服务、manifest 校验器和对象创建函数。 | 加载依赖、校验模板/schema依赖、初始化本模块状态、注册事件并挂接 API；无显式返回值。 | 是；本目录唯一装配入口。 |
| `tickAfter(tick, delta)` / 61–67 | `tick`：Core tick；`delta`：加 tick 数。 | 经 `Core.tickAdd` 计算截止 tick；无效则抛错。 | 是；统一处理转换宽限期和移除痕迹过期时间。 |
| `removeTemplateProtectionRepairObject(square, object)` / 72–95 | `square`：对象所在格；`object`：待移除对象。 | 在 `RV.Server` 上设置移除来源标记，记录对象/坐标及两 tick 的过期时间，调用 `ServerWorld.removeGenericObject`，恢复旧标记；返回 `pcall` 是否无异常及引擎返回值。 | 是；恢复时移除对象要避免 RoofRefresh 把同一移除误认为玩家拆墙，并验证事件痕迹。 |
| `integer(value)` / 97–105 | `value`：数字或可由 `ServerUtil.toNumber` 转换的值。 | 接受有限整数，拒绝非数、NaN、正负无穷和小数；返回整数或 `nil`。 | 是；identity、坐标、对象标签和索引均依赖整数约束。 |
| `isVisualCornerTemplate(entry)` / 107–112 | `entry`：模板条目。 | 判断是否为特定 `IsoObject` / Wooden Wall 视觉角对象；返回布尔值。 | 是；后续地板目标分类需将该视觉角特殊处理。 |
| `isTemplateFloorObject(entry)` / 114–117 | `entry`：模板条目。 | 判断是 `IsoObject` 且不是视觉角模板对象；返回布尔值。 | 是；区分 square 的 floor 槽位与普通对象列表。 |
| `sameIdentity(left, right)` / 119–124 | `left`、`right`：含 `rvId`、`generation`、`bitmapVersion` 的记录。 | 校验表类型并按规范化 RV id 与整数 generation/bitmapVersion 比较；返回布尔值。 | 是；阻止旧 generation / bitmap 的记录或对象被当作当前数据。 |
| `queueKey(boundary, record)` / 126–137 | `boundary`：当前边界；`record`：当前 RV mapping 记录。 | 先用 `sameIdentity` 验证身份，再产生 `rvId:generation:bitmapVersion`；非法输入返回 `nil`。 | 是；按 generation 隔离队列、失败日志和修复索引。 |
| `coordinateKey(x, y, z)` / 139–141 | `x,y,z`：世界格坐标。 | 返回 `x:y:z` 字符串键。 | 是；模板索引及坐标目标查询需要稳定键。 |
| `xyKey(x, y)` / 143–145 | `x,y`：世界平面坐标。 | 返回 `x:y` 字符串键。 | 是；队列按 XY 去重，同一格多个 Z 层只排一项。 |
| `currentProtectedCoordinateTargets(index, boundary, x, y, z)` / 147–157 | `index`：修复索引；`boundary`：当前边界；`x,y,z`：坐标。 | 校验索引与边界身份一致，再返回该坐标的非空目标数组，否则返回 `nil`。 | 是；候选移除授权需要目标属于当前索引。 |
| `repairIdentityKey(rvId, generation, bitmapVersion)` / 159–168 | `rvId`、`generation`、`bitmapVersion`：RV 身份三元组。 | 校验 id 非空且 generation/version 为合法整数，返回规范化三元组键或 `nil`。 | 是；转换暂停状态不依赖具体玩家，只按 RV generation 聚合。 |
| `clearQueuedIdentity(identityKey)` / 170–174 | `identityKey`：身份键。 | 删除该身份的待处理队列和错误去重记录；无显式返回值。 | 是；转换开始、generation 变更或边界失效时丢弃旧扫描工作。 |
| `isIdentityPaused(identityKey, tick)` / 189–198 | `identityKey`：身份键；`tick`：当前 Core tick。 | 若仍有活动转换或 grace deadline 未到则返回 `true`；过期 deadline 会清除并返回 `false`。 | 是；避免传送/房间流送过程中扫描或修复。 |

### 2.2 转换生命周期、事件与上下文验证（第 204–426 行）

| 函数 / 行 | 参数含义 | 功能、输出或副作用 | 必要性 |
|---|---|---|---|
| `Boundary.observeTemplateProtectionRepairTransitions(tick)` / 204–273 | `tick`：当前 Core tick。 | 读 `Boundary._states`，按 identity 判断活动/刚完成的 transition；活动时清队列，结束时设置 100 tick grace；清理过期 pause 与移除坐标痕迹。返回成功布尔值。 | 是；保证每 tick 先观察状态，避免 Sweep 查询时清理 timeout token 导致漏掉转换结束。 |
| `identityHasActiveTransition(identityKey, tick)` / 275–288 | `identityKey`：RV 身份键；`tick`：当前 tick。 | 扫描 `Boundary._states`，查找同一 RV 身份仍有效的转换；返回布尔值。 | 是；一个玩家转换完成时，若同一 RV 还有其他玩家转换，不可提前解除暂停。 |
| `onBoundaryTransitionLifecycle(eventName, player, state, tick)` / 290–317 | `eventName`：begin/complete/clear/timeout；`player`：事件玩家（当前未读取）；`state`：Boundary 状态；`tick`：事件 tick，可回退到 Boundary/Core tick。 | begin 时标记活动并清队列；结束事件检查同身份是否仍有活动转换，否则开 100 tick grace；清理队列。无显式返回值。 | 是；通过 Boundary 生命周期通知及时丢弃传送前采样工作。 |
| `loadedLayerForCell(cell, x, y, z)` / 324–334 | `cell`：服务端 cell；`x,y,z`：待检查格。 | 查 chunk 并安全读取 `chunk.loaded`；返回 `true` 或 `false, reason`。 | 是；只处理已加载区域，避免实例化/查看未加载格。 |
| `objectTag(object)` / 336–350 | `object`：IsoObject 类对象。 | 读取 `ServerWorld.objectModData(object).RailroaderRVTest`，并验证 owner、RV 身份和双份字段一致；返回合法嵌套 tag 或 `nil`。 | 是；需要当前模组写入且内部一致的对象归属证据。 |
| `onTemplateProtectionObjectAboutToBeRemoved(object)` / 352–366 | `object`：引擎即将移除的对象。 | 按对象弱引用和位置查找最近移除痕迹并清除；无显式返回值。 | 是；避免 repair removal trace 残留，供下游识别移除来源。 |
| `registerTemplateProtectionRemovalTrace()` / 368–378 | 无。 | 通过 `Core.registerEvent` 注册 `OnObjectAboutToBeRemoved` 回调；重复注册时直接返回；注册失败抛错，成功后设置标志。 | 是；建立上述移除痕迹清理钩子。 |
| `validCurrentContext(player, expectedBoundary)` / 382–427 | `player`：当前玩家；`expectedBoundary`：可选的预期边界对象引用。 | 经 `Boundary.boundaryForPlayer`、manifest helper 和当前 schema 检查 boundary/record/manifest/bitmap identity、READY+COMMITTED 阶段、模板版本及 bounds/region/bitmap 一致性。返回 `true,boundary,record,manifest,identity` 或 `false,reason`。 | 是；恢复入口和队列执行前的服务端权威门禁。 |

### 2.3 模板索引、对象身份与移除安全策略（第 429–1040 行）

| 函数 / 行 | 参数含义 | 功能、输出或副作用 | 必要性 |
|---|---|---|---|
| `isCabCoordinate(x, y, anchor)` / 429–438 | `x,y`：坐标；`anchor`：manifest 锚点。 | 按常量 cab offset 范围判断是否位于可编辑驾驶室；返回布尔值。 | 是；驾驶室内建造格不能由模板保护流程清理。 |
| `isCabSideHostCoordinate(x, y, z, index)` / 440–450 | `x,y,z`：候选格；`index`：含 cab 锚点的修复索引。 | 判断是否为锚点 Z 层上 cab 东侧/南侧的 host 格；返回布尔值。 | 是；驾驶室侧门窗 host 不属于普通模板恢复/清理目标。 |
| `isRuntimeDoorOrWindow(object)` / 452–461 | `object`：游戏对象。 | 识别 `IsoDoor`、`IsoWindow`，以及 `IsoThumpable:isDoor/isWindow`；返回布尔值。 | 是；door/window 的运行时类可能是 Thumpable，需要保护驾驶室开口。 |
| `isCabSideDoorOrWindow(object, x, y, z, index)` / 463–466 | `object`：游戏对象；`x,y,z`：格坐标；`index`：cab 锚点索引。 | 同时满足 cab 侧 host 与门窗判定时返回 `true`。 | 是；把几何位置限制与运行时类型限制合并成一条保护规则。 |
| `templateEntry(templateIndex, anchor)` / 468–476 | `templateIndex`：捕获模板序号；`anchor`：世界锚点。 | 读取 `ProtectionManifest.worldEntry` 并校验 layout；缺失时抛错，否则返回世界坐标期望项。 | 是；修复目标必须来自当前模板映射。 |
| `expectedEdgeMap(manifest)` / 478–508 | `manifest`：已验证当前 manifest。 | 校验 shell edge 键、identity、side 与 templateIndices 的唯一性，返回 template 序号到 edge 的映射；非法返回 `nil`。 | 是；构造边界墙对象时验证它属于当前 shell ledger edge。 |
| `buildRepairIndex(boundary, manifest)` / 510–571 | `boundary`：当前边界；`manifest`：当前 committed manifest。 | 校验锚点和 edge map；验证 cab 格 buildable；遍历保护 manifest，生成身份、anchor、edge、坐标目标、cab editable 集合及日志去重集合。失败返回 `nil`。 | 是；把全模板校验一次后变成每格查找索引，支持安全授权和限时扫描。 |
| `objectMatchesCapturedIdentity(object, entry)` / 573–589 | `object`：游戏对象；`entry`：模板期望项。 | 对比 class、name、direction、sprite 和可选 north；返回布尔值。 | 是；对象外观身份必须与捕获模板一致。 |
| `objectMatchesCaptured(object, entry)` / 591–607 | `object`：游戏对象；`entry`：含 state 的模板项。 | 先做 captured identity 比对，再按 state getter 表对比 health、锁、通行、render 等字段；返回布尔值。 | 是；防止只凭位置/标签而接受错误运行时状态。 |
| `objectClassName(object)` / 609–616 | `object`：游戏对象。 | 从 `getClass()` 字符串提取类名；不可读时返回 `nil`。 | 是；分类保护对象和检查期望 class。 |
| `isBloodOrSplat(object)` / 618–636 | `object`：游戏对象。 | 在类名、sprite、name 中搜索 blood/splat；返回布尔值。 | 是；血迹等动态世界对象不得被模板修复清除。 |
| `protectedWorldObject(object)` / 638–648 | `object`：游戏对象。 | 保护玩家、车辆、世界物品、僵尸、动物、尸体和血迹；返回布尔值。 | 是；对象安全策略核心门禁。 |
| `hasStoredContainerItems(object, className)` / 650–669 | `object`：游戏对象；`className`：已解析类名，可用来保守识别容器。 | 查询容器数和 items；存在物品或关键状态无法验证时返回 `true`，明确为空/无容器时才返回 `false`。 | 是；不丢弃箱柜及不确定的容器对象。 |
| `hasTemplateFloorTarget(targets)` / 671–676 | `targets`：当前坐标目标数组。 | 判断是否含模板 floor `IsoObject` 目标；返回布尔值。 | 是；识别 floor 槽位是否需要处理。 |
| `hasTemplateIsoObjectTarget(targets)` / 678–683 | `targets`：当前坐标目标数组。 | 判断是否含任何 `IsoObject` 目标；返回布尔值。 | 是；floor 查询不可验证时 fail closed。 |
| `objectAtCoordinate(object, x, y, z)` / 685–691 | `object`：游戏对象；`x,y,z`：预期格坐标。 | 安全取对象坐标并比较整数坐标；返回布尔值。 | 是；坐标匹配属于移除授权的一部分。 |
| `isCabEditableCoordinate(x, y, z, index)` / 693–696 | `x,y,z`：坐标；`index`：cab editable 集合和 anchorZ。 | 查集合并验证 Z 层；返回布尔值。 | 是；屏蔽 cab 格清理。 |
| `isRemovalScopeCoordinate(boundary, index, x, y, z)` / 698–701 | `boundary`：当前边界；`index`：cab 索引；`x,y,z`：候选坐标。 | 判断在当前 bitmap scope 内且不在可编辑 cab；返回布尔值。 | 是；限制移除不得越出当前 RV/驾驶室保护区。 |
| `footprintAllowsRemoval(tag, boundary, index, x, y, z, cell)` / 703–728 | `tag`：对象 metadata；`boundary/index`：当前作用域；`x,y,z`：host；`cell`：当前 cell。 | 验证多格对象 footprint 完整、唯一、整数、host 包含在内、每格已加载且属于移除范围；返回布尔值。缺少普通单格 footprint 时允许，标记为 multiTile 却无 footprint 时拒绝。 | 是；多格对象任一部分越界/未加载都不得移除。 |
| `objectFootprintAllowsRemoval(object, boundary, index, x, y, z, cell)` / 730–740 | `object`：对象；`boundary/index`：当前 scope；坐标为 host；`cell`：服务端 cell。 | 检查原始 modData 及嵌套 RV tag 的 footprint；任一不安全则返回 `false`。 | 是；同时核对对象持久字段和模组 tag，避免只验证其中一个。 |
| `reportUnsafeRemoval(index, object, boundary, x, y, z, cell)` / 742–757 | `index`：去重集合；`object`：候选对象；`boundary`：当前 RV；`x,y,z`：坐标；`cell`：服务端 cell。 | 对容器内容不明或 footprint 不安全的对象打印一次保留原因；更新 `reportedSafetyBlocks`；无显式返回值。 | 诊断可选；日志有助于解释未修复。真正拒绝移除由调用处的安全检查完成。 |
| `isProtectedBuildingCandidate(object, x, y, z, boundary, index, claimedTarget, cell)` / 759–828 | `object`：候选对象；`x,y,z`：所在格；`boundary/index`：当前身份与目标索引；`claimedTarget`：当前坐标模板目标；`cell`：加载状态查询对象。 | 必须证明目标仍属于当前保护索引、标签和对象身份有效、类匹配、不是 cab opening/player/vehicle/blood/container，footprint 安全且在 scope 内；返回 `bool, reason`。 | 是；允许谨慎清理占据保护格的错误建筑对象，但不允许坐标巧合成为授权。 |
| `isWhitelistedTemplateObject(object, boundary, manifest, edges, objectIsFloor)` / 830–896 | `object`：现存对象；`boundary/manifest`：当前状态；`edges`：shell edge map；`objectIsFloor`：是否为 floor 槽对象。 | 验证 tag、模板项、anchor/world 坐标、floor slot、captured state、edge role 和 bitmap scope；返回布尔值。 | 是；扫描时跳过已证明属于当前模板的对象。 |
| `isWhitelistedGenerator(object, boundary, manifest)` / 898–912 | `object`：候选发电机；`boundary/manifest`：当前 RV 身份和 anchor。 | 验证 generator tag/class/role 与配置偏移坐标；返回布尔值。 | 是；避免重复生成或错误清理正确 generator。 |
| `currentTemplateTagMismatch(object, expected, edge, boundary)` / 914–968 | `object`：现存对象；`expected`：当前模板期望项；`edge`：可选 edge；`boundary`：当前身份。 | 逐字段比较当前 identity、模板坐标/class/name/sprite/direction/north/protectionClass、锚点、edgeKey/axis/role；返回首个不匹配说明字符串或 `nil`。 | 是；判定声称归属当前模板的对象是否能被信任。 |
| `exactExpectedTag(object, expected, edge, boundary)` / 970–976 | `object`：现存对象；`expected`、`edge`、`boundary`：期望数据。 | 标签无 mismatch 且对象 captured identity/state 匹配时返回 `true`。 | 是；恢复后精确确认对象可留存。 |
| `reportIncompleteClaimedFloorTag(index, object, boundary, expected, edge)` / 978–988 | `index`：去重集合；`object`：占据 floor 槽的对象；`boundary`：身份；`expected/edge`：目标身份。 | 记录一次身份阻断并打印字段差异；无显式返回值。 | 诊断可选；安全阻断由调用处 `blocked[index]` 执行。 |
| `currentTemplateTarget(object, boundary, targets)` / 990–1001 | `object`：已有 tag 的对象；`boundary`：当前身份；`targets`：当前格合法目标数组。 | 按 tag.templateIndex 找对应目标；返回目标或 `nil`。 | 是；区分属于哪个模板槽位，避免误处理旁边对象。 |
| `currentTemplateClaimIsSafe(object, target, boundary, index, x, y, z, objectIsFloor, cell)` / 1003–1021 | `object/target`：对象及对应目标；`boundary/index`：当前状态；`x,y,z`：当前格；`objectIsFloor`：槽位标志；`cell`：加载检查源。 | 校验坐标、class、保护类、blood/container/footprint、floor 类别；返回布尔值。 | 是；明确的当前模板 claim 也不能绕过一般世界对象安全门禁。 |
| `markMatchingTargetsBlocked(object, targets, blocked, objectIsFloor)` / 1023–1040 | `object`：不能处理的对象；`targets`：本坐标目标；`blocked`：输出集合；`objectIsFloor`：floor 槽标志。 | 按类、captured identity 和 floor/非-floor 槽标记被占目标序号；无显式返回值。 | 是；保留歧义对象时阻止在同一槽位盲目重建。 |

### 2.4 坐标扫描、对象恢复与入口 generator（第 1042–1520 行）

| 函数 / 行 | 参数含义 | 功能、输出或副作用 | 必要性 |
|---|---|---|---|
| `collectCoordinate(cell, x, y, z, boundary, manifest, index)` / 1042–1129 | `cell`：服务端 cell；`x,y,z`：格坐标；`boundary/manifest/index`：当前验证数据。 | 取 square、对象快照和 floor；跳过白名单对象；收集可移除对象、标记阻断目标并输出安全诊断。返回 `false, reason` 或 `true, squareInfo, removals, blocked`。 | 是；把候选发现与后续实际删除分开，先收集并分类。 |
| `removeCandidates(removals)` / 1131–1154 | `removals`：带 object/square/inPlace 的候选数组。 | 对非 inPlace 候选加来源标记移除并检查对象已不在 square；记录 removed/inPlace 集合。返回 `false,reason` 或 `true,removed,inPlace`。 | 是；只执行已通过扫描的候选并验证引擎结果。 |
| `removeDuplicateTemplate(square, object)` / 1156–1171 | `square`：对象所在格；`object`：同槽重复模板对象。 | 仅对非保护对象、捕获类、无容器内容对象执行移除并检查成功；返回 `bool, reason?`。 | 是；允许安全去重，不对任意 class 清理。 |
| `repairTemplateProtectionCoordinate(cell, x, y, z, squareInfo, removed, inPlace, blocked, index, boundary, manifest)` / 1173–1299 | `cell`：world cell；`x,y,z`：目标坐标；`squareInfo`：已扫描 square/floor/对象；`removed/inPlace/blocked`：扫描/删除结果；`index/boundary/manifest`：当前模板数据。 | 对受保护目标逐个检查槽位；按需创建 square、更新可原地恢复的 floor、保留歧义对象、去重复项、配置 door frame，并补建缺失对象。返回 `true` 或 `false, reason`。 | 是；执行模块的核心模板保护恢复。 |
| `repairTemplateProtectionLayer(cell, x, y, z, boundary, manifest, repairIndex)` / 1301–1326 | `cell`：服务端 cell；`x,y,z`：目标格层；`boundary/manifest/repairIndex`：当前已验证数据。 | 跳过 scope 外与 cab 格、跳过未加载层；依次 collect、remove、repair，返回 `true` 或 `false, reason`。第 1320–1324 行的条件块只构造局部 `targets` 后未使用，是无效果代码。 | 是；为一个具体 Z 层编排完整过程；尾部空操作本身不必要。 |
| `repairQueuedTemplateProtectionXY(player, boundary, expectedKey, x, y)` / 1328–1360 | `player`：当前玩家；`boundary`：预期边界；`expectedKey`：generation 键；`x,y`：待修复 XY。 | 再验 context/key，按需建索引，取 player cell，对 bitmap 的 Z 层调用 layer repair；返回 `true` 或错误。每层调用外围 `pcall` 的返回值当前未检查。 | 是；Construction 的单格恢复桥接到全层修复。静态上存在层级失败被吞掉的路径，需运行验证才能评估影响。 |
| `rollbackEntryGenerator(square, before, boundary, created)` / 1362–1393 | `square`：generator square；`before`：创建前对象集合；`boundary`：当前身份；`created`：可选新对象。 | 快照对象，仅移除本次新增且为目标/当前身份 generator 的对象，并验证移除；返回 `true` 或 `false, reason`。 | 是；入口创建失败或未落盘时限制回滚范围并确认回滚。 |
| `reconcileCurrentTemplateCell(player, expectedBoundary, x, y)` / 1395–1411 | `player`：当前玩家；`expectedBoundary`：预期 boundary；`x,y`：Construction 请求坐标。 | 验证当前 context、整数坐标、bitmap scope 和身份 key，转调 queued XY 修复；返回 `bool, reason`。 | 是；`ctx.reconcileCurrentTemplateCell` 被 Construction restore service 使用。 |
| `Boundary.ensureGeneratorForEntry(player, record)` / 1413–1520 | `player`：进入者；`record`：当前 RV mapping record。 | 调用 `RV.Server.validateCurrentRVRecord`，校验当前 committed manifest/anchor/scope；未加载 chunk 时延后检查；已加载则保留合法 generator、拒绝歧义 generator，或创建后验证，失败时精确回滚。返回 `true` 或 `false, reason`。 | 是；EntryExit 在传送玩家前依赖此入口保障。 |
| `compactQueue(queue)` / 1522–1534 | `queue`：含 entries/head/tail 的队列。 | 当已消费前缀足够大时压缩有效项并重置 head/tail；无显式返回值。 | 是；避免长时间运行中数组索引持续增长。 |
| `enqueueXY(queue, x, y)` / 1536–1543 | `queue`：当前 RV 队列；`x,y`：待扫描坐标。 | 按 xyKey 去重后尾部入队并更新 pending/count；无显式返回值。 | 是；以无重复 FIFO 方式记录采样 tile。 |
| `purgePreviousGenerations(rvId, currentKey)` / 1545–1563 | `rvId`：RV id；`currentKey`：当前身份键。 | 清除相同 RV id 的旧队列、旧索引和旧失败日志；无显式返回值。 | 是；避免旧 generation/bitmap 工作跨代继续执行。 |
| `restoreThroughConstruction(player, boundary, x, y)` / 1568–1576 | `player`、`boundary`、`x,y`：Construction 当前格恢复参数。 | 查找 `RV.Server.Construction.restoreCurrentCell` 并转发参数；服务缺失时返回 `false, reason`。 | 是；队列通过 Construction 公共服务复用 manifest/managed 格门禁。 |

### 2.5 采样、调度和 tick 入口（第 1578–1728 行）

| 函数 / 行 | 参数含义 | 功能、输出或副作用 | 必要性 |
|---|---|---|---|
| `Boundary.sampleTemplateProtectionRepairPlayer(expectedBoundary, player)` / 1578–1605 | `expectedBoundary`：玩家当前边界；`player`：玩家对象。 | 安全读取玩家坐标，对周围 3×3 XY 去重入队并清理旧代状态。主体由 `pcall` 包住且忽略其结果，函数始终返回 `true`。 | 是；产生按接近程度采样的扫描工作；其公开挂载本身可改为局部函数。 |
| `popXY(queue)` / 1607–1616 | `queue`：当前队列。 | 删除队首、解除 pending、减 count 并视情况压缩；返回 entry 或 `nil`。 | 是；每次队列处理消费一个 tile。 |
| `Boundary.processTemplateProtectionRepairQueue(activeBoundaries)` / 1618–1685 | `activeBoundaries`：当前活跃 boundary key 到 `{boundary,player}` 的表。 | 重验每个玩家 context，清除 stale 身份，跳过转换暂停身份；按 key 排序并轮转公平选择一个非空队列，恢复一个 XY；失败按 identity/tile 打印一次。返回 `true`、`false` 或 `false,reason`。 | 是；限速执行修复；目前函数挂在 `Boundary` 上但只由本文件 tick handler 调用。 |
| `Boundary.shouldSampleTemplateProtectionRepair(tick)` / 1687–1689 | `tick`：Core tick。 | 判断 tick 合法且到达 sample interval；返回布尔值。 | 是；分隔采样频率；可设为本地辅助而非公开 Boundary API。 |
| `Boundary.onTemplateProtectionRepairTick(tick, activePlayers, activeBoundaries)` / 1691–1728 | `tick`：当前服务器 tick；`activePlayers`：Sweep 的玩家/boundary 数组；`activeBoundaries`：活跃身份映射。 | 先观察转换；到采样 tick 时对玩家入队；每 tick 最多处理一个坐标；最后还清理 `Boundary._builders` 过期项。无显式返回值。 | Sweep 外部调用此入口，因此入口必要；清理 `_builders` 属于 DemolitionProtection/BoundaryGuard 状态，位置值得拆出。 |

### 2.6 匿名闭包（没有独立命名）

| 行 | 形式参数/捕获值 | 功能与输出 | 必要性 |
|---|---|---|---|
| 330 | 无参数；捕获 `chunk`。 | `pcall` 内读取 `chunk.loaded`，将异常转换为状态和错误值。 | 是；隔离引擎属性读取异常。 |
| 1461 | 无参数；捕获 `chunk`。 | `pcall` 读取 `chunk.loaded`，供入口 generator 检查判断 loaded 布尔值。 | 是；该入口检查需要处理 Java/Lua 代理异常。 |
| 1503 | 无参数；捕获 `square`、`created`、`record`、`manifest`。 | 判断对象已挂入 square 且满足当前 whitelisted generator 身份；返回布尔值。 | 是；新 generator 创建后的持久性检查。 |
| 1579 | 无参数；捕获玩家、boundary 和队列状态。 | 包裹整段位置读取和 3×3 入队，避免异常逸出；闭包返回值被忽略。 | 保护性隔离必要；但忽略错误导致外层无法报告采样失败。 |
| 1653 | `left`,`right`：ready 队列项。 | 按队列身份 key 字典序排序；返回比较布尔值。 | 是；保证选择顺序稳定，使轮转公平逻辑可重复。 |

## 3. 模块间功能比较与提取机会

| 候选能力 | 证据位置与判断 | 提取建议 |
|---|---|---|
| RV 身份键 `rvId:generation:bitmapVersion` | 本文件 `queueKey` / `repairIdentityKey`（126–137、159–168）；相同格式也在 `BoundaryServer_Geometry.boundaryKey`（`BoundaryGuard/RV_BoundaryServer_Geometry.lua:272–275`）和 `Core/RV_UtilityServer.lua:20–23`。本文件还额外做严格整数/id 校验。 | 高价值候选：在服务端共享 identity helper 定义规范化、拒绝无效字段的唯一契约，供边界、utility 和本模块共用。不要只抽字符串拼接而遗失本模块的输入校验。 |
| 有限整数转换 | 本文件 `integer`（97–105）；同名局部实现还在 `Common/RV_Bitmap.lua:37`、`BoundaryGuard/RV_BoundaryServer_Geometry.lua:27`、`RoomTemplate/RV_RoomTemplate.lua:48` 等处。 | 候选但需先统一约定：转换/错误行为不完全相同；若 `ServerUtil` 提供 non-throwing `toFiniteInteger` 明确契约，可减少重复。当前小函数本身短，改动收益低于契约不统一带来的风险。 |
| 对象不可破坏名单与多格 footprint | 本文件 `protectedWorldObject` / `footprintAllowsRemoval`（638–740）；`DemolitionProtection/RV_BoundaryServer_Objects.lua:74–90,390–398` 有 footprint 和 protected class 的相似策略。 | 值得抽取低层 helper（footprint 解析、对象类别查询），但当前策略有差异：本模块还保护 vehicle、blood/splat、容器及每个 footprint 格的 loaded 状态；Demolition 额外列出 `IsoPlayer`/`BaseVehicle` 并在调用层做 buildable/shell 检查。共享实现前先统一政策，不能直接复制合并。 |
| 坐标键 / XY 队列操作 | 本文件 `coordinateKey`、`xyKey`、`compactQueue`、`enqueueXY`、`popXY`（139–145、1522–1543、1607–1616）；模板/layout 也有坐标字符串键，例如 `RoomTemplate/RV_RoomTemplate.lua:164,571`。 | 坐标键可放在 `ServerUtil`，但字符串拼接几乎没有维护成本，且使用范围/键顺序并非统一协议；当前没有明显收益。队列只被本模块使用，不值得做通用队列框架。 |
| 捕获模板身份检查 | `objectMatchesCapturedIdentity`、`objectMatchesCaptured`、`currentTemplateTagMismatch`（573–607、914–976）依赖 `ProtectionManifest` 特有字段及模板 edge 标签。 | 留在模板保护域；与通用世界对象工具耦合会使 template schema 规则分散。 |

## 4. 是否需要进一步拆分

建议拆分。当前单文件 1,729 行同时承担模板索引、对象归属与安全策略、世界对象扫描/删除/重建、转换监听和限速队列、入口 generator 检查。以下边界职责不同、输入输出清楚：

1. **TemplateRecoveryIndex**：`templateEntry`、`expectedEdgeMap`、`buildRepairIndex` 与 captured identity/tag 校验。它提供只读索引和期望身份，不操作世界。
2. **TemplateRecoveryWorldRepair**：`protectedWorldObject`、footprint/container 安全判断、`collectCoordinate`、候选删除和 `repairTemplateProtectionCoordinate`。它负责世界对象的安全扫描及修复。
3. **TemplateRecoveryQueue**：转换暂停/生命周期、player 3×3 采样、FIFO 与每 tick 配额。它通过 `Construction.restoreCurrentCell` 调用修复服务。
4. **入口 generator 完整性**（可放入现有 Construction 或独立小服务）：`ensureGeneratorForEntry` 关注 EntryExit 的预检、生成及回滚，不依赖 proximity repair queue。

拆分时让 manifest/index 和对象修复接口作为显式服务传递；不要继续共享/扩增 `Boundary` 隐藏表。优先移出第 1722–1726 行 `_builders` 过期清理，因为那是另一个功能域的状态维护。

## 5. 跨模块内部数据访问与接口收益

### 5.1 公开合同与调用证据

| 合同 | 调用/定义位置 | 评价 |
|---|---|---|
| `Boundary.onTemplateProtectionRepairTick(tick, activePlayers, activeBoundaries)` | Sweep 调用：`BoundaryGuard/RV_BoundaryServer_Sweep.lua:115–118`。 | 合适的模块入口；Sweep 只传活跃实体列表，具体恢复工作留在本模块。 |
| `Boundary.ensureGeneratorForEntry(player, record)` | EntryExit 检查并调用：`RVMapping/RV_RailroaderServer_EntryExit.lua:356–364`。 | 合适的跨模块入口；错误会阻止玩家进入，符合服务端权威预检。 |
| `ctx.reconcileCurrentTemplateCell(player, boundary, x, y)` | 本文件将函数放入 `ctx`（1565–1566）；`Construction/RV_Construction.lua:282–289` 读取并验证后调用。 | 这是比直接调用 repair 内部函数更好的服务接口。`Boundary.reconcileCurrentTemplateCell` 同时导出但未发现其他模块调用，可删除这个重复导出。 |
| `Boundary.addTransitionLifecycleListener(name, listener)` | 本文件注册回调（319–322）；API 定义于 `BoundaryGuard/RV_BoundaryServer_Geometry.lua:543–549`，事件传入 event/player/state/tick。 | 明确的生命周期扩展点；建议本模块继续经此接口订阅。 |
| `RV.Server.validateCurrentRVRecord(record)` 与 `RV.Server.Construction.restoreCurrentCell(...)` | 前者用于 entry generator 检查（1422–1424）；后者由 `restoreThroughConstruction` 调用（1568–1576）。 | 作为服务方法使用，避免本模块重复实现 record 验证与 Construction 的 managed 格/阶段门禁。 |
| `ctx.ensureRoofSquare`、`ctx.createCapturedTemplateObject`、`ctx.configureCapturedDoorFrame`、`ctx.createGenerator` | 注入字段（9、13–15），由 `Construction/RV_Server_WorldObjects.lua:885–890` 暴露。 | 通过创建/世界对象服务操作引擎对象，属于清楚的依赖注入边界。 |

### 5.2 直接访问的隐藏状态

| 隐藏字段 | 本文件访问位置 | 状态所有者/跨模块情况 | 接口判断 |
|---|---|---|---|
| `Boundary._states`，及各 state 的 `rvId/generation/bitmapVersion/transitionToken/transitionKind/transitionUntil` | 读取于 205–225、275–284。 | `BoundaryGuard/RV_BoundaryServer.lua:37` 初始化该表；Geometry 模块创建和改写状态（例如 `RV_BoundaryServer_Geometry.lua:573–594,619–637`）。本模块读取的是 Boundary 的私有状态结构。 | 应提供 `Boundary.hasActiveTransitionForIdentity(...)` 或在 lifecycle contract 中维护身份级活动计数/快照。收益明显：避免消费者遍历 `_states` 并绑定 transition 字段结构。当前 `addTransitionLifecycleListener` 尚不能单独回答“同一 RV 是否还有其他玩家 transition”，所以需要补一个窄查询/聚合合同。 |
| `Boundary._tick` | 87、295、1633。 | BoundaryGuard 当前 tick 状态；Sweep 也读取同一字段并把它传给 tick callback（Sweep:116）。 | 本模块 `on...Tick` 已有 `tick` 参数，移除 helper 也可从调用上下文传入/保存；生命周期回调已收到 tick。对其余访问可提供 `Boundary.currentTick()`，但这是简单稳定值，单独 getter 的收益不大；改调用路径更直接。 |
| `Boundary._builders` 与每个 builder 的 `expires` | 1722–1726 删除过期项；表由 `RV_BoundaryServer.lua:39` 建立，`DemolitionProtection/RV_BoundaryServer_Objects.lua:609,634–643` 写入和遍历。 | 这是明显的跨模块私有状态读写：TemplateRecovery 的 tick handler 负责删 DemolitionProtection 的 builder action。 | 应移到 DemolitionProtection 自己的 tick/清理接口，或由 BoundaryGuard 调用 owner 提供的 expiry 服务。接口收益高，因为能消除对 action 字段 `expires` 的隐式依赖，并令模块负责人管理自身生命周期。 |
| `Boundary._templateProtectionRepairPauseUntil`、`_templateProtectionRepairActiveTransitions`、`_templateProtectionRemovalTraceRegistered` | 176–187、369–377。 | 当前只有本模块读写；字段挂在共享 Boundary 对象上以持久保留子系统状态/注册标记。 | 对外仍属私有状态；没有证据显示其他模块依赖这些字段。可以集中在 `Boundary._templateProtectionRepairState` 单一命名空间或模块 local 状态；除非要跨重新加载持久化，否则不需要新增公开 API。 |
| `RV.Server._templateProtectionRepairRemovalObject` | 本文件写入/恢复：83–94；RoofRefresh 读取：`RoofRefresh/RV_RailroaderServer_RoofRefresh.lua:501–505`。 | 私有标记形成了两个模块间的隐式协议：本模块移除对象时设置，RoofRefresh 根据对象相同引用跳过刷新排队。 | 建议在 `RV.Server` 暴露具名检查/作用域接口，例如 `isTemplateRepairRemoval(object)` 或 `withRemovalOrigin(origin, object, callback)`。收益明显：去掉字段名和保存/恢复流程的双边耦合，表达来源语义。 |
| 游戏对象的 `modData` 双份 tag / footprint | `objectTag`（336–350）、`footprintAllowsRemoval` 路径（703–740）、模板 tag 校验（830–968）。 | 这是跨持久化对象的 owner/schema 数据，不是某个 Lua 模块的内部表；本模块必须读它来证明对象 identity 和安全 footprint。 | 不需再包接口；应由对象创建器与 schema validator维护同一数据合同。若有字段变更，应与对象生成/Construction 侧一起迁移审核。 |

`Boundary.observeTemplateProtectionRepairTransitions`、`sampleTemplateProtectionRepairPlayer`、`processTemplateProtectionRepairQueue`、`shouldSampleTemplateProtectionRepair` 都只在本文件内部由 tick handler 调用（交叉搜索未发现外部消费者）。它们需要作为功能函数存在，但不必全部挂到 `Boundary` 公共表；建议局部化，只保留 Sweep 需要的 `onTemplateProtectionRepairTick` 入口。相同地，`Boundary.reconcileCurrentTemplateCell` 没有跨模块调用，Construction 已通过 `ctx` 接口访问。

## 6. 文件/函数清单及验证记录

- 文件扫描：`rg --files media/lua/server/RailroaderRV/TemplateRecovery` 得到 1 个文件；PowerShell 行数核对为 1,729。
- 函数扫描：按定义行扫描得到 70 个具名/工厂函数；另核对到 5 个匿名闭包（330、1461、1503、1579、1653）。函数清单逐项与 `rg -n '\bfunction\b'` 结果交叉检查，排除了 `type(...) ~= "function"` 之类非定义用法。
- 行号复核：源文件按 1–400、401–800、801–1200、1201–1521、1522–1729 分段逐行读取，所有报告函数行均对应定义位置。
- 接口交叉核对：只读搜索了 tick/entry/construction/removal-marker 调用点，并对照 Sweep、EntryExit、Construction、WorldObjects、Boundary Geometry、DemolitionProtection 与 RoofRefresh 的相关行；未修改这些文件。
- 文档核对：文档按 70 个具名/工厂函数和 5 个匿名闭包逐项覆盖；函数表行号均来自目标源文件；未运行模组或 runtime 测试。
- 未覆盖项：不评价游戏运行时引擎对象行为、实际转场时序或恢复效果；这些需按整体 runtime 测试流程观察，本次明确按只读分析要求未执行。

## 第二阶段职责更新

当前实现已拆成[TemplateRecoveryIndex](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/TemplateRecovery/RV_TemplateRecoveryIndex.lua)、本文件的 WorldRepair 和[TemplateRecoveryQueue](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/TemplateRecovery/RV_TemplateRecoveryQueue.lua)。Index 只拥有当前模板派生的只读 repair-index cache；WorldRepair 拥有对象安全/footprint/container policy 与实际对象修复；Queue 拥有采样、FIFO、quota 及 transition pause。Queue 用 Boundary identity activity snapshot/lifecycle listener 查询转场，通过 `RV.Server.Construction.restoreCurrentCell` 请求恢复，不遍历 `_states` 或 `_builders`。`ensureGeneratorForEntry` 已迁移到 Construction。历史逐函数扫描对应改动前单文件版本；当前职责与接口以[第二阶段报告](phase2-structure-optimization.md)为准。
