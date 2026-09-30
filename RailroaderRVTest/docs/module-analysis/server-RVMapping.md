# 服务端 RVMapping 子目录代码分析

## 假设、范围与成功条件

- 假设：分析对象是 `contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RVMapping/` 当前实际存在的全部代码。本报告按文件划分模块，不把同名目录之外的脚本纳入实现评价。
- 范围：4 个 Lua 文件，源码行数分别为 Mapping 620、EntryExit 811、Train 623、RecordValidation 333。目录中没有 `RV_RegionSlots.lua`，源码对它存在 `require`；本任务不检查被引用目录外实现。
- 成功条件：列全具名、赋值、嵌套和匿名函数；按函数说明职责、本模块语义、参数、返回/副作用与必要性；记录模块间复用、拆分和跨模块数据访问的判断及源码行号。
- 验证方式：只读列文件、函数声明扫描和带行号源文逐段交叉核对；完成后校验文档存在、章节/表格行数和路径。未运行游戏或测试脚本。
- 限制：跨目录依赖仅依据本目录可见的调用点和注释描述；未打开兄弟目录、官方脚本或反编译来源，故不把本报告当作对外部接口实现的独立核验。

## 文件与模块职责

| 文件 | 模块职责 | 主要共享面 |
|---|---|---|
| `RV_RailroaderServer_Mapping.lua` | 初始化当前 schema 的列车映射存档；定义区域/记录校验、槽位分配、坐标反查；维护屋顶刷新缓存和墙体移除回调去重。 | 通过 `ctx` 输出映射服务；向 `Adapter` 暴露区域分配和映射身份查询；为 BoundaryValidation 注入窄依赖。 |
| `RV_RailroaderServer_EntryExit.lua` | 解析并授权玩家进入/退出；处理列车座位和玩家映射关系；接驳生成事务、生成提交与失败恢复。 | 读取 Mapping/Train 写入 `ctx` 的函数；调用 `Boundary`、`RailroaderRV.Server`、`ServerTeleport`。 |
| `RV_RailroaderServer_Train.lua` | 适配 Railroader 列车记录与 SP/MP 权威来源；提供玩家/列车位置、方向、距离、座位查询和座位变更。 | 将通用 helper 写入 `ctx`，供 EntryExit 和 Mapping 调用。 |
| `RV_Server_RecordValidation.lua` | 验证当前映射、manifest、bitmap 和几何身份；提供生成 hook、屋顶刷新及房间所有权监视的服务端 API。 | 向 `RV.Server` 注册窄接口；依赖 `ctx`、Adapter 的 current mapping 查询、Boundary 与 roof helper。 |

函数清单共 **113 项**：Mapping 28、EntryExit 23、Train 45、RecordValidation 17。数字包含文件初始化闭包和代码中的匿名闭包；不把 `type(x) == "function"` 之类类型检查误计为定义。

## Mapping：`RV_RailroaderServer_Mapping.lua`

行号是函数定义或函数值赋值所在行。

| 函数（行） | 参数含义 | 返回值 / 副作用 | 当前必要性 |
|---|---|---|---|
| 模块初始化 `return function`（2） | `ctx`：服务端组合根注入的常量、适配器与 helper。 | 无显式返回；配置 schema gate，构造 boundary validator，并把实现写到 `ctx` / `Adapter`。 | 必需：本文件是按共享上下文装配的模块工厂。 |
| `serverTransactionMutexStatus`（19） | 任意参数原样转发。 | 返回 `ctx.serverTransactionMutexStatus` 的全部结果。 | 条件必需：给下面队列清理提供事务忙闲查询的局部入口；单纯转发可直接捕获 ctx 函数，但保留可读性尚可。 |
| `invalidateBoundaryValidationCache`（44） | 无。 | 清空 `validatedMapCache`；若 validator 已创建则调用 `invalidate`，否则标记 Adapter warm-pending。 | 必需：映射 epoch 变化后避免继续使用旧边界校验结果。 |
| `mapData`（53） | 无。 | 返回 ModData 中当前 schema 的 RV 映射表；不可用、格式不符或 schema gate 未就绪时抛错。仅空的新容器会初始化 `schemaVersion/locomotives/players`。 | 必需：所有映射查询和槽位分配共用的当前 schema 入口；严格拒绝非空旧容器是开发期存档门要求。 |
| `markMappingChanged`（102） | `boundaryChanged`：显式 `false` 时跳过边界 epoch/cache 失效。 | 递增 Adapter mapping epoch；通常也递增 boundary epoch 并清缓存。 | 必需：通知服务端缓存映射更新；不广播整个 map 是该模块注释说明的设计。 |
| `rvRegion`（114） | `anchor`：可选锚点表；缺省时用常量基点。 | 返回完整 RV identity 区域矩形，宽高由 region size × slot 行列数构成，Z 使用 identity min/max。 | 必需：区分单个 slot 与整个 RV 分配空间，也用于玩家范围筛选。 |
| `regionForAnchor`（132） | `anchor`：slot 锚点。 | 返回该锚点对应的单 slot 区域（在完整区域上把 maxX/maxY 收窄一个 region size）。 | 必需：持久化某列车 RV 的空间范围。 |
| `playerPositionInRegion`（139） | `player`：玩家对象；`region`：边界表。 | 成功返回 `{x,y,z}`，否则 nil；以服务端玩家坐标检查半开区间。 | 必需：不能用请求方给的坐标做归属授权。 |
| `inRegion`（164） | `position`：坐标表；`region`：边界表。 | 返回合法坐标是否落在半开区间内。 | 必需：与 player 取值版本配套，用于每条已映射记录的区域判定。 |
| `validRegion`（182） | `region`：待验证的持久化 region。 | 返回尺寸、整数坐标、固定 Z 和世界 Z 限制是否全部满足。 | 必需：拒绝陈旧或伪造的区域边界。 |
| `validMapRelation`（194） | `relation`：玩家映射关系；`requireLocoId`：是否要求非空列车 ID。 | 返回当前 schema gate 及关系字段类型/范围是否合法。 | 必需：声明了稳定关系 schema 的共享校验规则。 |
| `validMappingRecord`（202） | `record`：列车映射记录。 | 返回记录是否属于当前 gate、generated RV identity、generation 与 bitmap 版本。 | 必需：身份主门；分配、坐标反查、commit 都依赖。 |
| `validRecord`（211） | `record`：映射记录。 | 直接返回 `validMappingRecord(record)`。 | 可合并：当前无额外语义；可删薄别名并统一调用主校验器。 |
| `recordForLoco`（215，赋值函数） | `map`：映射根；`locoId`：目标列车 ID。 | 返回匹配的 record 和其表键；缺失时两个 nil。 | 必需：调用方不应假设 map table key 等于 ID；字符串规范化集中在此处。 |
| `onlinePlayersSnapshot`（239，匿名回调） | 无显式参数；捕获 `ctx`。 | 调用 ctx 快照提供者，缺失时返回空表；作为依赖注入给 BoundaryValidation。 | 必需：提供边界校验所需在线玩家快照而不让其直接依赖全局。 |
| `roofRefreshRoomKey`（245） | `record`：映射记录。 | 返回 `rvId:generation:bitmapVersion` 键；身份不完整时 nil。 | 必需：用 generation 身份隔离屋顶刷新缓存。 |
| `isWallRemovalSource`（257） | `source`：墙体移除来源字符串。 | 返回来源是否是三个被抑制/跟进处理的移除事件之一。 | 必需：集中限定对哪些破坏事件作延迟处理。 |
| `markSuppressedRoomTransition`（263） | `pending`：pending transition 记录。 | 对有效墙体来源和 room key 记录 token、短期过期 tick；无返回值。 | 必需：避免墙拆除触发的房间转换和 RV relocation 重复生效。 |
| `consumeSuppressedRoomTransition`（276） | `roomKey`：待消费房间键。 | 删除过期/匹配 suppression 并返回布尔值；匹配时记录诊断日志。 | 必需：抑制标记必须一次性消费。 |
| `pruneRoofRefreshDedupeState`（295） | `now`：可选 tick。 | 清掉过期 seen/suppression/follow-up 项；mutex 状态不可确认时保守保留 generation 队列。 | 必需：限制事件状态增长，并保护 generation 中事件。 |
| `pruneRoofRefreshDedupeState` 内闭包（302，匿名） | 无；捕获 mutex 查询。 | 安全执行 mutex 查询，`pcall` 返回调用成功和 active 状态。 | 条件必需：将可能抛错的锁查询转为 fail-closed 分类；可由稳定的安全调用 helper 替代。 |
| `wallRemovalEventKey`（354） | `object`：移除的世界对象；`roomKey`：RV 房间身份。 | 返回对象索引事件键及坐标别名；缺索引时用坐标 fallback，坐标无效时 nil。 | 必需：不保留 userdata 也能跨移除回调去重。 |
| `refreshRoofForPlayer`（396） | `player`、`record`、`force`：是否跳过缓存、`reason`：日志原因。 | 返回成功与详情；调用 `RV.Server.refreshRoofVisuals`，成功后写缓存/玩家状态并记录日志。 | 必需：现有 RV 进入与 OnTick 重试共用 roof refresh 入口。 |
| `pruneRoofRefreshRooms`（437） | `now`：可选 tick。 | 删除格式无效、未来时间或超过 TTL 的缓存项。 | 必需：使 room cache 有界且可在当前 identity 变化后失效。 |
| `armRoomOwnershipMonitor`（457） | `player`、`record`、`reason`。 | 返回布尔值及失败原因；调用服务端 targeted monitor API。 | 必需：已有 RV 进入/重连也要补装生成事务以外的 ownership guard。 |
| `recordAtPlayerCoordinate`（484） | `map`：已读映射；`player`：服务端玩家对象。 | 返回 record、key、live train、状态；状态为 active/inactive mapped、outside-rv 或 unmapped-rv。无写入。 | 必需：以服务端坐标反向定位 RV，不从世界房间或客户端 ID 推断归属。 |
| `allocateRVRegion`（502） | `locoId`：可选列车 ID，已存在则复用原槽。 | 返回成功、slot、anchor、region、可选 generation；失败返回原因。读当前 map/manifest 并防止重复槽分配。 | 必需：generation 前为 RV 选唯一空间并保留当前 manifest 占用槽。 |
| `currentMappingRecord`（579） | `rvId`、`generation`、`bitmapVersion`：待查身份三元组。 | 返回成功与 record；任何 schema 或 identity 不匹配返回统一无效数据错误。 | 必需：提供给 Adapter 与 RecordValidation 的窄身份查询接口。 |

### Mapping 访问与边界

- `mapData` 直接读写 `ModData` 的 map 容器及 schema 字段（53–99）；`allocateRVRegion` 另从 `ModData.get(C.MANIFEST_KEY)` 读取单条生成事务记录（531–570）。这些是映射/空间分配拥有的持久化合同，空容器初始化有显式限制。
- 本文件直接访问 Adapter 的 `_mappingEpoch`、`_boundaryValidationEpoch`、`_boundaryValidationWarmPending`、`_ticks`（103–108、271、296、420）。这些以下划线命名的状态是模块间共享的隐藏缓存/时钟状态。将 epoch 递增和取当前 tick 包装成 Adapter 方法会减少字段耦合；收益中等，因为本文件本身是 adapter 的组成实现且需要同步失效缓存。
- BoundaryValidation 通过构造器注入窄函数和一个在线快照闭包（227–244）。这是明确的内部接口；优于让它反查 Mapping 局部函数。
- `ctx` 输出 `mapData`、校验、区域、刷新、坐标反查及分配函数（596–616）；Adapter 公开 `allocateRVRegion/currentMappingRecord`（617–618）。这是本子目录内其余模块实际依赖的合同。

## EntryExit：`RV_RailroaderServer_EntryExit.lua`

| 函数（行） | 参数含义 | 返回值 / 副作用 | 当前必要性 |
|---|---|---|---|
| 模块初始化（2） | `ctx`：前序模块提供的服务和共享状态。 | 无显式返回；捕获依赖并在结尾将 entry/exit hooks 写回 ctx。 | 必需：共享服务装配点。 |
| `recordForLoco`（10，转发） | 任意参数。 | 转发 `ctx.recordForLoco` 的所有结果。 | 可合并：薄 wrapper 可直接使用 ctx 成员；当前仅用于局部命名便利。 |
| `roofRefreshTransactionBlocks`（11，转发） | 任意参数。 | 转发事务阻塞结果。 | 条件必需：调用方清晰度有帮助；无独立逻辑。 |
| `currentGeometryGate`（12，转发） | 任意参数。 | 转发当前 geometry gate 结果。 | 条件必需：调用方清晰度有帮助；无独立逻辑。 |
| `Adapter.resolveCurrentUtilityRV`（51） | `player`：服务端玩家。 | 返回授权结果和 identity/record/relation/train/status 上下文；验证玩家位置、关系、在线身份、边界和当前 schema。 | 必需：水/utility 这类操作从可信服务端位置解析 RV 的入口。 |
| `Adapter.validateCurrentUtilityIdentity`（128） | `identity`：服务端异步任务保存的 RV identity。 | 返回有效与 `{record,train}`；逐阶段拒绝并日志化，不写映射。 | 必需：tick settlement 再验证异步身份，不能使用旧 snapshot。 |
| `reject`（129，嵌套局部函数） | `stage`：失败阶段字符串。 | 打印诊断并返回统一无效数据错误。 | 可合并：只在上层使用一次；内联也可，保留阶段标签便于定位。 |
| `Adapter.currentUtilityRecord`（171） | `identity`：异步身份三元组。 | 再调 validate，返回当前 record 或统一错误。 | 条件必需：更窄的返回合同；若无外部调用者可并入 validator。 |
| `settleUtilityTransition`（180） | `record`、`player`、`phase`：当前 RV、触发玩家、诊断阶段。 | 返回是否被 Server 接受；以 identity 调用 settlement。 | 必需：进出转换前等待 utility load 状态收敛。 |
| `sendResult`（200） | `player`、`ok`、`reason`。 | 无显式返回；发 RV teleport 结果 server command。 | 必需：为调用者提供统一客户端结果应答。 |
| `movePlayer`（208） | `player`、可信目标 `position`、`action`、可选 `relation`。 | 返回 teleport 是否完成；先发送服务器提示，SP 允许无网络 channel，entry 用 spawn teleport，其他动作用目标位置 teleport。 | 必需：把服务端 teleport 与客户端表现提示合并在一个事务步骤。 |
| `markPlayerOutside`（248） | `map`、`record`、`key`（当前未使用）、`player`、可信落点、seat、role。 | 无显式返回；写 map.players 和可选 record.players 的 outside relation 与 exit position。 | 必需：出口成功后持久化关系；建议移除未用 `key` 参数以免误示表键参与逻辑。 |
| `markPlayerInside`（277） | `map`、`record`、`key`（当前未使用）、`player`、原位置、原 role/seat。 | 无显式返回；写顶层与 RV record 双份 inside relation，字段格式异常时抛错。 | 必需：进入/生成提交都需可逆的玩家归属状态；`key` 可移除。 |
| `otherGeneratedRecord`（303） | `map`、`locoId`：当前目标列车。 | 返回第一个已生成且绑定另一 locomotive 的记录，否则 nil。 | 必需：防止一个新的列车偷用已分配给另一列车的 RV。 |
| `sourceWithinRange`（313，赋值函数） | `player`、`train`。 | 返回 hull distance 是否不大于 Railroader reach/配置 reach。 | 必需：外部玩家上车入口范围验证；供 utility 定位和 entry 授权复用。 |
| `requestData`（321） | `train`、`player`、来源 role/seat、服务端来源坐标。 | 返回 generation 请求数据，含 locomotive ID、server entry position、完整 locomotive pose。 | 必需：将 entry 阶段可信状态传给生成事务。 |
| `removeSeatForEntry`（338） | `train`、`player`、`onlineId`。 | 返回 `forgetTrainSeat` 得到的 role 与 seat。 | 可合并：纯转发；名称强调用途但无独立效果。 |
| `enterExisting`（342） | 玩家、列车、现有 record/key、来源 role/seat/position、map。 | 返回成功或原因；依次检查事务/geometry/generator，布置 guard，拆座、记录关系、移动，失败则还原关系/座位。 | 必需：已有 RV 进入与首次生成路径的事务不同，需独立回滚。 |
| `enterPlayer`（423） | `player`、请求目标 `locoId`。 | 返回是否接纳；验证玩家、事务、坐标、列车、角色、速度和交互范围；复用已有 RV 或清座后排队生成。 | 必需：服务端进入主流程，拒绝客户端提供的位置/角色。 |
| `restoreAfterGenerationFailure`（493） | `player`、generation `data`。 | 无显式返回；尽量恢复原驾驶/乘客座、移回可信来源位置并清 boundary transition。 | 必需：generation 失败补偿。 |
| `commitGeneration`（523） | `player`、原请求 `data`、事务生成的 `prepared` 结果。 | 返回成功/原因；验证槽位/anchor/region，构造 candidate map 与两份玩家关系，注册 Boundary，交换 map 表，初始化 utility，失败恢复原表。 | 必需：generation 世界结果与持久化身份的原子提交钩子。 |
| `validateGeneration`（672） | `player`、generation `data`。 | 返回布尔值及拒绝原因；确认玩家仍可用、列车仍存在、非乘客列车未移动。 | 必需：生成耗时期间的再次授权/目标状态校验。 |
| `exitPlayer`（682） | `player`。 | 返回成功或原因；从服务端坐标解析 RV，验证几何；按列车是否在线/是否移动选择旁站或驾驶/乘客座，teleport、更新关系并清 transition。 | 必需：服务端出口主流程及失败补偿。 |

### EntryExit 访问与边界

- `mapData` 返回原始持久化 map；EntryExit 直接读写 `map.players`、`record.players` 和 `map.locomotives`，包括拷贝 candidate table 后整体交换两个顶层表（62–93、248–300、484–491、523–669、690–800）。这使事务提交可同步替换完整视图并在失败时恢复原表；把每个字段改为独立接口的收益低于维护 candidate clone/swap 的复杂度。建议长期只给关系读写加窄接口，不要隐藏事务提交所需的 map snapshot。
- `Boundary.beginTransition/completeTransition/clearPlayer/registerGeneration` 与 `RailroaderRV.Server.*` 是显式方法接口；本文件同时检查方法存在和返回状态（352–380、612–669、686–800）。
- `RV.Server`、`RailroaderRV.Server` 在不同段落读取同一全局的嵌套引用（108–114、151–168、180–197、474–482、618–669）。可统一成一个局部获取函数以减少空值检查重复，但直接访问公开 Server 方法本身不属于隐藏状态。
- 可见的直接函数耦合主要来自 `ctx` 注入：EntryExit 捕获 Train 和 Mapping helper（14–49）。依赖显式且职责窄；`recordForLoco`、`removeSeatForEntry` 等薄 wrapper 若没有调试或替换价值可清理。

## Train：`RV_RailroaderServer_Train.lua`

| 函数（行） | 参数含义 | 返回值 / 副作用 | 当前必要性 |
|---|---|---|---|
| 模块初始化（2） | `ctx`：服务器状态与配置。 | 无显式返回；构建本地函数并把通用/列车 helper 写入 ctx（595–622）。 | 必需：其余模块通过该表使用 Train adapter。 |
| `number`（7） | `value`：外部数值或可强转 userdata。 | 不额外检查 NaN/无穷；返回 number 或 nil。 | 必需：统一兼容 Java/Lua 数值类型。 |
| 闭包 `value + 0`（15，匿名） | 捕获 `value`。 | 尝试 coercion，结果受 pcall 保护。 | 条件必需：只用于特殊 userdata 强转。 |
| `integer`（22） | 任意待转换值。 | 返回整数或 nil。 | 必需：ID、seat 与坐标边界需要整数检查。 |
| `call`（28） | `target`、方法名、任意方法参数。 | 返回 pcall 的成功标记与被调用返回值；方法以 target 作 self。 | 必需：安全调用 PZ/Java 对象方法并兼容缺失对象。 |
| 闭包 `target[method]`（31，匿名） | 捕获目标、方法名、参数数组。 | 执行方法调用并转发返回。 | 必需：`call` 的受保护方法调用体。 |
| `callGlobal`（36） | 全局函数名及参数。 | 返回 pcall 状态和全局函数返回值。 | 必需：安全调用 `getWorld/sendServerCommand` 等全局 API。 |
| 闭包 `fn(...)`（40，匿名） | 捕获全局函数与参数数组。 | 执行全局函数，转发返回值。 | 必需：`callGlobal` 受保护调用体。 |
| `safeCall`（43） | `target`、方法名、任意参数。 | 仅返回方法是否成功执行的布尔值。 | 必需：运动/休息等不需读取返回值的 player 设置。 |
| `playerId`（48） | `player`。 | 返回 online ID；SP 非服务器 pass 缺失时尝试 playerNum，最终本地默认 0；服务器缺失时 nil。 | 必需：关系记录和座位键的身份来源。 |
| `playerName`（63） | `player`。 | 返回非空 username 或 nil。 | 必需：映射以名称索引关系表。 |
| `playerDead`（70） | `player`。 | 返回是否被安全读取为 dead=true。 | 必需：entry/exit 权限门。 |
| `playerPosition`（75） | `player`。 | 返回服务端 `{x,y,z}` 或 nil。 | 必需：来源坐标和 hull range 计算。 |
| `copyPosition`（87） | position 表。 | 验证/复制有限数值含义的 x/y/z；错误返回 nil。 | 必需：不共享传入坐标表且不保留杂项字段。 |
| `newTransitionToken`（94） | `kind`：entry/exit 类型；`record`：可选当前 mapping。 | 返回含 type、loco、generation、时间和递增序列的 token；递增 ctx 序列。 | 必需：Boundary transition 一次性身份。 |
| `copyPose`（104） | locomotive pose 表。 | 返回复制的位置；合法时归一化方向向量。 | 必需：persisted fallback 需要方向但不接受非单位向量。 |
| `animalType`（117） | animal 对象。 | 返回调用 getAnimalType 的字符串值或 nil。 | 必需：限制目标只接受 Railroader locomotive。 |
| `isRailroaderLocomotive`（122） | animal 对象。 | 返回是否为 rr_loco。 | 必需：不把其他 Animal/train 当目标。 |
| `animalId`（126） | animal 对象。 | 返回 getAnimalID 值或 nil。 | 必需：从 train record 缺少 id 时构造 identity。 |
| `trainId`（131） | `train`：Railroader train record。 | 返回 record.id 或其 animal ID；格式不符 nil。 | 必需：上层只依赖单一 locomotive ID 提取规则。 |
| `trainList`（142） | 无。 | 返回当前权威 train table 与 `server/singleplayer` 来源标签；host 不回退空的 server 列表。 | 必需：SP/MP 权威数据源选择边界。 |
| `findTrain`（170） | `locoId`：待查列车 ID。 | 返回匹配的 train 及权威标签；只接受 rr_loco。 | 必需：Mapping/EntryExit 按 ID 解析 live train。 |
| `authorityForTrain`（187） | train record。 | 返回该表当前属于哪个权威列表，无法确认时 nil。 | 必需：决定 seat mutate 应遵守 SP 还是 MP schema。 |
| `trainPosition`（198） | train record。 | 优先返回 live animal 坐标，否则复制记录 pose；均不可用时 nil。 | 必需：范围、exit 和 snapshot 坐标。 |
| `trainSpeed`（216） | train record。 | 返回 drive.v、v、speed 首个可转换值；默认 0。 | 必需：入口/出口是否允许的移动判定基础。 |
| `trainMoving`（225） | train record。 | 返回绝对速度是否大于 stopped threshold。 | 必需：调用点用此拒绝移动车辆 driver/安排 passenger。 |
| `trainDirection`（229） | train record。 | 返回单位方向 x/y；依次读 record、pose、animal forward direction，缺省朝 north。 | 必需：座位、旁站及 pose 计算方向。 |
| `trainPose`（250） | train record。 | 返回含位置和单位方向的表或 nil。 | 必需：事务快照 locomotive pose。 |
| `trainSize`（258） | train record。 | 返回 animal size；缺省 0.7。 | 必需：官方 hull/seat geometry 函数的几何参数。 |
| `seatPosition`（268） | train record、seat index（0 为驾驶位）。 | 返回目标座位坐标或 nil；优先官方 `RR.Body.seatWorld`，失败时用本地固定偏移公式。 | 必需：出 RV 后服务端安排正确列车座位位置。 |
| `besidePosition`（303） | train record。 | 返回 locomotive 朝向右侧 2 tile 的旁站坐标或 nil。 | 必需：无可用座位时让玩家安全落到车旁。 |
| `usableCoordinate`（311） | position 表。 | 返回坐标整数化后的 world square 是否存在；不改世界。 | 必需：卸载 locomotive 的 persisted beside fallback 需有效落点。 |
| `persistedBesidePosition`（327） | RV mapping `record`。 | 仅用当前 record 的完整 locomotive pose，尝试六个相邻位置并返回第一个合法位置。 | 必需：locomotive 未加载时仍允许合法退出而不捏造座位。 |
| `hullDistance`（358） | player、train。 | 返回 official Body hull distance 或中心距离 fallback；位置缺失 nil。 | 必需：外部上车的距离判断保持官方交互半径。 |
| `seatForPlayer`（381） | train、`onlineId`。 | 返回 passengers 表匹配的 seat，支持数字/字符串 key；无匹配 nil。 | 必需：恢复已有 passenger role。 |
| `isDriver`（395） | train、`onlineId`。 | 返回 driver 字段是否与玩家 ID 字符串相等。 | 必需：role 分类。 |
| `freePassengerSeat`（399） | train。 | 返回第一个空闲乘客 seat 或 nil。 | 必需：出口分配 passenger seat。 |
| `playerRole`（413） | train、`onlineId`。 | 返回 driver/passenger/external 及 seat；SP 与 MP 走不同状态合同。 | 必需：角色/座位决定移动门和映射内容。 |
| `singleplayerMount`（436） | SP train record、seat。 | 优先调用 Ride.mountRecord；未挂载成功时写 rider/seat/passenger 字段；返回布尔值。 | 条件必需：B42 SP Ride 表可能在不同 Lua pass 不可见。 |
| `singleplayerDismount`（451） | SP train record。 | 可见 Ride 时调用 dismount；随后清空 rider/seat/passenger 状态；返回 true。 | 条件必需：SP 离座后持久化状态需同步。 |
| `syncSeatAfterPut`（468） | train、player、onlineId、seat、role、authority。 | MP 更新 seatNames/claims/cmd sequence，改变 player flags 并标记服务器 train resync；SP 不处理。 | 必需：直接 seat 写入后同步 Railroader 客户端和瞬时数据。 |
| `forgetTrainSeat`（493） | train、player、onlineId、可选 authority。 | 返回被移除 role/seat；MP 清驾驶或乘客字段、claims、玩家状态并 markResync；SP dismount。 | 必需：RV 内玩家不能继续受列车座位 pin/输入控制。 |
| `player:setBed` 闭包（544，匿名） | 捕获 `player`。 | 尝试清空玩家 bed 标记，外层 pcall 忽略异常。 | 条件必需：注释说明对应官方 release 的 transient cab shelter 清理；仅在可见 player 时使用。 |
| `putPassenger`（552） | train、player、onlineId、目标 seat。 | 返回成功；SP 走 mount，MP 检查空位后写 passenger 表并同步。 | 必需：出口 passenger slot assignment 及失败恢复。 |
| `putDriver`（575） | train、player、onlineId。 | 返回成功；SP mount seat 0，MP 仅在 driver 空时写 driver 并同步。 | 必需：出口驾驶位分配及失败恢复。 |

### Train 访问与边界

- 本文件是外部 Railroader 私有列车记录的适配层。它直接读 `RR.ServerTrain.active`、`RR.TrainEntity.active`、`RR.Ride.current` 及 train record 的 driver/passengers/rider/seat/engine 等字段（131–168、381–434）。入口把这些访问封装在 `trainList/findTrain/playerRole`，其他 RV 模块不必重复了解权威源选择。
- 它直接读写带下划线的 Railroader 状态 `_seatNames`、`_claims`、`_cmdSeq`、`_stopping`、`_stopHold`、`_starting`、`_startEnv`、`_startPlayer`、`_cruise`、`_cruiseNotch`，也调用 `RR.ServerTrain.markResync`（468–491、493–549、575–591）。本文件注释称这些 board/release helper 在目标 Railroader 版本为 private；本分析未查阅外部源文件，因此这个可见代码内的事实是“实现依赖 private 字段”，其 API 状态仍待外部来源独立复核。
- 如果官方侧提供稳定的 board/release 服务接口，改用它的收益高，因为当前 RV 代码需要镜像多个易变状态字段；若官方没有该接口，则另建本地抽象层只会封装而不会消除脆弱性，收益有限。现有 Train adapter 已将脆弱字段集中在一个模块，建议保持这一隔离并在官方接口出现后替换内部实现。
- `RR.Body.seatWorld/hullDistance`、`RR.ServerTrain.markResync`、`RR.Ride.mountRecord/dismount` 是显式函数调用点；`ctx` 将稳定的 player/position/seat helper 作为内部 API 导出（595–622）。局部 `number/integer/call/callGlobal` 是四文件间可复用的通用候选，当前集中在此处且由其它模块接收，不应另复制。

## RecordValidation：`RV_Server_RecordValidation.lua`

| 函数（行） | 参数含义 | 返回值 / 副作用 | 当前必要性 |
|---|---|---|---|
| 模块初始化（2） | `ctx`：Server/Boundary/Schema/roof 服务依赖。 | 无显式返回；配置 record geometry gate 并为 `RV.Server` 注册服务。 | 必需：注册 server-side validation API。 |
| `safeErrorText`（12，转发） | 任意参数。 | 转发 `ctx.safeErrorText` 全部结果。 | 条件必需：统一错误文本边界；可直接用 ctx，无独立逻辑。 |
| `requireCurrentManifest`（13，转发） | 任意参数。 | 转发当前 manifest 验证。 | 必需性较低：仅被本文件的 snapshot helper 使用；若不扩展，可局部直接捕获 ctx。 |
| `currentMappingRecord`（21） | `rvId`、`generation`、`bitmapVersion`。 | 返回成功与当前 record；Adapter 缺失、拒绝或异常统一映射为 INVALID_RV_DATA。 | 必需：将对 Adapter hidden implementation 的访问封装为严格查询。 |
| `manifestViewForRecord`（35） | record：当前映射记录。 | 返回成功与从 record 当前 anchor/managed boundary 重建的 READY manifest 视图；失败统一拒绝。 | 必需：让映射记录与 manifest schema 以同一几何合同比较。 |
| pcall snapshot closure（40，匿名） | 无显式参数；捕获 `record`、模块常量与 schema helper。 | 构造当前 schema snapshot，计算 layout/bounds 并调用 strict manifest validator；返回 snapshot 或被 pcall 捕获的错误。 | 必需：将可能抛错的构造/验证作为原子只读步骤。 |
| `manifestForIdentity`（82） | identity 三元组；`allowRunning`：是否允许匹配的 active RUNNING generation。 | 返回通过身份和几何校验的 manifest view；只读持久化 manifest/mapping，不自动修复。 | 必需：统一普通 relocation 和 boundary guard 的当前 identity gate。 |
| `RV.Server.setRailroaderValidationHook`（125） | callback：generation validation hook 或其他值。 | 在 ctx 保存合法 function，其他类型写 nil。 | 必需：供生成管线安装可替换验证 hook。 |
| `RV.Server.setRailroaderCommitHook`（129） | callback：generation commit hook。 | 在 ctx 保存 function 或 nil。 | 必需：安装 EntryExit commit hook。 |
| `RV.Server.setRailroaderFailureHook`（133） | callback：generation failure hook。 | 在 ctx 保存 function 或 nil。 | 必需：安装失败恢复 hook。 |
| `RV.Server.requestRailroaderGeneration`（137） | player、`railroaderData`：服务端生成请求 snapshot。 | 返回 queueGeneration 结果；缺数据或任一 hook 缺失则拒绝。 | 必需：暴露进入生成事务的服务端入口。 |
| `RV.Server.currentRVManifestForRelocation`（151） | identity 三元组。 | 返回 `manifestForIdentity(..., false)`，禁止 RUNNING 特例。 | 必需：普通进出/utility 只接受 ready current identity。 |
| `RV.Server.currentRVManifestForBoundary`（160） | identity 三元组。 | 返回 `manifestForIdentity(..., true)`，仅特许匹配 active RUNNING transaction。 | 必需：generation 过程中 Boundary guard 仍能验证当前事务。 |
| `currentRVRecordGeometryConsistent`（165） | record、manifest。 | 返回布尔值；比较 schema gate、RV/gen/bitmap、boundary identity 与 managed 六字段。 | 必需：把 current mapping 与 manifest 的持久化几何绑定。 |
| `RV.Server.validateCurrentRVRecord`（211） | record。 | 返回成功与 manifest；先解析当前 relocation manifest，再比对几何。 | 必需：EntryExit 对当前记录的窄 read-only 验证接口。 |
| `RV.Server.refreshRoofVisuals`（234） | player、record。 | 返回成功与 reason；验证当前 manifest 和玩家 roof context 后调用 RoofRefresh.run，可能更新房间/屋顶世界状态。 | 必需：封装屋顶可见刷新及当前身份验证；Mapping 调用此服务而不重复实现。 |
| `RV.Server.armCurrentRoomOwnershipMonitor`（268） | player、record。 | 返回成功或错误；严格核对 mapping/boundary/manifest/READY 和玩家 identity 后发送 targeted guard。 | 必需：已有 RV 进入/重连的 ownership monitor 服务端入口。 |

### RecordValidation 访问与边界

- `manifestForIdentity` 从 `ctx.pendingGeneration` 直接读取 generation 状态（93–102）。这是 Server transaction 的隐藏状态字段。可让 ctx 提供 `isPendingGeneration(identity)`，让字段拥有者保留存储形态；本文件只需判断其身份匹配。收益中等，当前字段读取简短且 `ctx` 本身是组合根合同。
- `RV.Server` 方法是本文件明确发布、其他本目录模块使用的接口；EntryExit 调用 `currentRVManifestForBoundary/currentRVRecordGeometryConsistent/validateCurrentRVRecord`，Mapping 调用 roof/monitor 服务。模块间以 API 方法交换身份结果，未发现调用方直接改写 RecordValidation 局部变量。
- `record.boundary.managed` 和 manifest.boundary.managed 为当前持久化 schema 的直接字段访问（35–75、171–203、268–321）。这是 schema 比对本身的必要数据合同；由于本目录有 strict validator，不建议再包一层只转发同一字段的 getter。

## 跨模块复用、重复职责和接口判断

### 可复用函数/合同

1. `Train.number/integer/call/callGlobal/copyPosition` 经 ctx 输出并由 Mapping、EntryExit 使用（Train 7–46、87–92、595–604；Mapping 20–27；EntryExit 14–40）。这是当前目录内明确的通用层，应继续保持唯一实现。
2. Mapping 的 `mapData/recordForLoco/validMappingRecord/currentMappingRecord` 经 ctx/Adapter 对 EntryExit 和 RecordValidation 提供唯一 map/schema 查询（Mapping 53–99、202–225、579–619；EntryExit 41–49；RecordValidation 21–33）。接口粒度足以供查询；持久化关系写入仍由事务编排模块负责。
3. RecordValidation 的 manifest identity/geometry gate 与 roof/room 服务经 `RV.Server` 暴露；EntryExit 与 Mapping 依赖它们，而无需自行拼装 manifest schema（RecordValidation 82–123、165–229、234–330；EntryExit 108–168、474–482；Mapping 396–475）。
4. `validRecord`（Mapping 211–213）、EntryExit 的 `removeSeatForEntry`（338–340）、Mapping/EntryExit 的若干 ctx 转发函数均只是别名。它们没有形成独立通用实现；不值得抽成公共工具，清理时可直接引用主函数。
5. 检查到的四个文件没有两份相同的非平凡算法。`playerPositionInRegion` 与 `inRegion` 分别负责从玩家对象取坐标、测试已有坐标，输入合同不同；不应为表面相似合并。Mapping 与 RecordValidation 都处理 roof refresh，但前者管调度、缓存和重试，后者做 manifest gate 与 world refresh；职责互补。

### 是否拆分模块

- **优先考虑 Mapping 的墙体事件/屋顶刷新状态段**：`markSuppressedRoomTransition` 至 `pruneRoofRefreshRooms`（263–451）和 `refreshRoofForPlayer`（396–435）跨越约 190 行，维护 suppression、去重、缓存、日志与重试；与区域槽分配/映射校验（44–245、478–589）关注点不同。可以抽成 `RoofRefreshIntegration`，构造时显式注入现有共享状态和服务。收益是降低高耦合 Mapping 文件的认知负担；成本是新增模块生命周期与 OnTick 状态连接，若近期无独立变更，应暂缓。
- **EntryExit 可考虑分离生成 commit**：`commitGeneration`（523–670）是两阶段生成事务的映射提交/回滚逻辑，与玩家 entry/exit 流程（342–521、682–800）有不同失败语义。可拆到 GenerationMappingCommit hook 文件，但需保持 map swap 与 utility initialization 原子顺序。分拆只有在事务钩子持续增长或单独审查需要时收益明显。
- **Train 暂不建议进一步拆分**：文件偏长（623 行），但其下层读取权威列表、解析姿态、计算座位、维护列车座位状态，是同一个 Railroader compatibility adapter。拆为只读数据与写入座位会暴露共享 helper 和 authority source，当前收益不明显；已由本文件隔离 private 状态。
- **RecordValidation 保持单文件**：所有函数都围绕 current identity/geometry gate，两个服务入口是校验后的副作用扩展；尺寸和主题仍相对一致。

## 只读核对记录与未覆盖项

- 文件清单：`RV_RailroaderServer_Mapping.lua`（620 行）、`RV_RailroaderServer_EntryExit.lua`（811 行）、`RV_RailroaderServer_Train.lua`（623 行）、`RV_Server_RecordValidation.lua`（333 行）。函数定义/赋值/嵌套闭包按 `rg -n "function|local function|=\\s*function|\\bfunction\\s*\\("` 扫描；随后以带行号完整源文及 EntryExit 缺失片段逐行核对。
- 函数核对数：Mapping 28、EntryExit 23、Train 45、RecordValidation 17，共 113 项（计入匿名闭包和工厂函数）。表格中的行号指源文件对应定义行；调用/访问讨论给出相关范围。
- 文档核对：本文档新建于 `docs/module-analysis/server-RVMapping.md`；完成后检查目标文件存在、各章节存在、四张函数表分别含预期条目数。
- 未覆盖：本目录引用但未驻留本目录的 `RV_RegionSlots`、Core、BoundaryValidation、Teleport、Layout、schema gate、RoofRefresh、官方 Railroader 实现及外围调用方；相关接口只按本文件调用点描述。无 runtime、单机、服务器或联机测试。

## 第二阶段接口更新

EntryExit 的生成器存在性检查现在经 `RV.Server.Construction.ensureGeneratorForEntry` 调用；其当前记录/manifest/boundary 身份验证及 fail-closed 行为归受控 Construction 世界服务。Mapping 变更通过 `Adapter.advanceMappingEpoch()` 递增 epoch；UtilityServer 查询用 `Adapter.currentMappingEpoch()`。Train、RecordValidation 与 mapping record 仍按已验证 value-object 合同直接读取。见[第二阶段报告](phase2-structure-optimization.md)。
