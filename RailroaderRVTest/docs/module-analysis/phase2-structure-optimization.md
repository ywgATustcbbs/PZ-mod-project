# RailroaderRV 第二阶段结构优化

## 范围、假设、取舍与验收

本次按状态所有权和输入合同优化既有结构，不按行数拆分。范围限于附件列出的 TemplateRecovery、Generation、RoofRefresh、Boundary/Demolition、客户端 RoomOwnership/Relocation 和重复 helper；保持 `docs/module-analysis/` 中其余模块既有职责。`RV_RailroaderContextMenu.lua` 经调用边界评估后保留原结构：字段读取已由 adapter 边界集中，拆分不会进一步减少 Railroader 内部字段依赖。

关键取舍：只有合同完全一致时才复用 helper。严格 schema 校验拒绝数字字符串、Java numeric wrapper 和 metatable；较宽松的数值正规化、Bitmap key-shape 和各自的对象保护策略继续留在领域 owner。GenerationTransaction 对外给 detached record snapshot，但保留 `player`、`generationCell` 的原对象引用，因为它们是 engine identity references 而不是可复制的数据值。

成功条件：每个事务、queue、cache 有唯一 owner；其他模块不直接读取私有状态表；不放宽当前身份、权限、坐标、安全和 schema 检查；文档说明移动、接口、状态 owner 和保留差异；完成静态 diff 检查以及项目要求的一键整体运行时测试。运行时验证只能从项目根目录直接执行 `python testserver/run_test.py`，不做预检、不拆测，服务器控制台保持可见。

## 最终模块职责与状态 owner

| 模块/服务 | 唯一核心职责 | Mutable state owner |
|---|---|---|
| `shared/Common/RV_StrictSchema.lua` | 提供共享的原生有限整数及无 metatable 精确键校验原语。 | 无运行态状态。 |
| `shared/RVMapping/RV_RegionSlots.lua`、`shared/Water/RV_UtilityCatalog.lua` | 使用 StrictSchema 验证槽位与 Water 标签的严格合同；各自保留领域映射/身份逻辑。 | 无运行态状态。 |
| `server/TemplateRecovery/RV_TemplateRecoveryIndex.lua` | 验证当前 manifest/template 身份，建立只读坐标、edge、captured-object 索引。 | 修复索引 cache。 |
| `server/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua`（WorldRepair） | 对象安全、footprint/container/保护策略、删除非法对象并恢复当前模板对象；只通过 Construction 的恢复接口写世界。 | 门/报告抑制与移除 trace；不拥有 queue 或 Boundary 状态。 |
| `server/TemplateRecovery/RV_TemplateRecoveryQueue.lua` | 玩家采样、FIFO、tick quota、transition 暂停/恢复；把格子修复交给 `RV.Server.Construction.restoreCurrentCell`。 | proximity queue、失败报告、pause/grace ticks。 |
| `server/Construction/RV_Server_GenerationTransaction.lua` | generation 事务身份、阶段、ACK、rebind、断线、cancel/rollback/release 的唯一状态入口。 | 完整进程内 generation transaction。 |
| `server/Construction/RV_Server_GenerationFlow.lua` | 生成验证、计划、阶段编排、初始 staging destination。 | 不直接持有异步事务表；通过 GenerationTransaction 操作。 |
| `server/Construction/RV_Server_GenerationBuild.lua`、`RV_Construction.lua` | 同步清理/建造、受控失败处理及当前 schema 的单格恢复。 | 世界修改/恢复动作经 Construction service；异步状态由 GenerationTransaction 持有。 |
| `server/Construction/RV_Server_PlayerValidation.lua`、`RV_Server_GenerationAck.lua` | 玩家身份与重连/rebind；generation ACK 和取消/回滚调度。 | 不直接持有 transaction table。GenerationAck 不含 Roof group/member processor。 |
| `server/RoofRefresh/RV_Server_RoofRelocation.lua` 与 RoofRefresh API | 分组搬运、ACK/到达/重试/失败/final-return 生命周期及完成证明。 | RoofRefresh relocation group、failure、final-return、member 状态由 RoofRefresh 包拥有；Core 仅建组合 context 的初始空 slot。 |
| `server/BoundaryGuard` | boundary record/geometry cache、player guard/transition lease、tick/事件处理与后玩家 tick dispatcher。 | `Boundary._states` 与 geometry registry 只在 BoundaryGuard 包内；其他模块只用 identity snapshot/listener API。 |
| `server/DemolitionProtection/RV_BoundaryServer_Objects.lua` | 玩家建造/拆除保护，以及异步 build correlation。 | 本地 `BuilderActionLedger` 独自持有提交、匹配、唯一候选、过期、prune、generation 失效及消费状态。 |
| `client/GUI/RV_ContextMenu_RoomOwnership.lua` | 客户端 room guard 状态与 bounded scan。 | 本地 `roomOwnershipGuards`。 |
| `client/GUI/RV_ContextMenu_Relocation.lua` | relocation 与 final relocation 状态机。 | 本地 `pendingFinalRelocation`。 |
| `server/Core/RV_RailroaderServer.lua` | Railroader adapter 的 mapping epoch owner API。 | 私有 `mappingEpoch`；`_mappingEpoch` 仅为兼容模块热重载保留的镜像，其他模块通过 API 读/增。 |

RoofRefresh 的 group 由 RoofRelocation 处理并由 RoofRefresh API 提供已验证操作；RoofApi 与 RoofRelocation 作为同一 RoofRefresh 包内部协作。它们仍经 Core 的内部 `ctx` 组合对象传递 process-local 状态，外部 Construction、Generation、RoomOwnership 和 Railroader adapter 不再解析 group/member 字段。

## 移动清单

| 原位置 → 新 owner | 移动内容 | 原因 |
|---|---|---|
| TemplateRecovery 大模块 → `RV_TemplateRecoveryIndex.lua` | 当前 identity、repair-index build/cache、edge/坐标/captured identity helper。 | 只读模板派生索引独立于队列及世界修改生命周期。 |
| TemplateRecovery 大模块 → `RV_TemplateRecoveryQueue.lua` | 玩家采样、FIFO、tick quota、Boundary 生命周期暂停、跨 generation 清理。 | 队列状态和采样策略由 queue 自己拥有，避免暴露在 Boundary namespace。 |
| TemplateRecovery → `Construction/RV_Server_WorldObjects.lua` | `ensureGeneratorForEntry` 的验证、存在性检查、创建/核验及 rollback。 | Generator 完整性是受控世界构建职责；EntryExit 调用 `RV.Server.Construction.ensureGeneratorForEntry`。 |
| `Boundary._builders` → DemolitionProtection | build-action submit、匹配、unique-candidate、过期/prune、generation invalidation、matched-object consumption。 | 生命周期随玩家建造操作和生成身份，归 BuilderActionLedger owner。 |
| `Boundary._states` 消费者 → BoundaryGuard API | TemplateRecovery 直接遍历改为 `transitionActivitySnapshot` 及生命周期 listener；Boundary 内部保留自己的 transition state 与 timeout 处理。 | Queue 只拿 identity/activity 的 detached facts，不依赖 lease table 形状；completion 的短 stamp 和 queue grace 保持。 |
| `GenerationAck` → RoofRefresh | relocation group ACK 识别入口委派给 `acknowledgeRoofRefreshRelocation`；group arrival/retry/failure processor 移至 RoofRelocation。 | GenerationAck 仅调度 generation 事务，RoofRefresh 负责它自己的成员状态。 |
| `RoofDestinations.lua` → `GenerationFlow.lua` | `selectGenerationStagingDestination`、`playerIsAtStagingDestination`。 | 这些只服务首次 generation staging，不属于 roof 的 remote relocation destination。 |
| client context composition → 子模块私有状态 | `pendingFinalRelocation` 完全收归 Relocation；`roomOwnershipGuards` 收归 RoomOwnership。 | sibling 以按 identity 的 guard 状态/刷新接口及 reopen-final-scan 语义通信，不再读取或改写对方 table。 |
| 分散事务写入者 → GenerationTransaction | `pendingGeneration`、busy/player owner、阶段/ACK/retry/disconnect/cancel/rollback 更新改为 owner 操作。 | GenerationFlow/Build/PlayerValidation/ACK 不再共享任意字段写入权限。 |

## 新增/保留接口与公共化判断

### 真正共享的基础原语

- `StrictSchema.integer(value)`：只接受原生有限 Lua number 且为整数。
- `StrictSchema.exactKeys(value, requiredKeys)`：只接受普通 table、无 metatable、required key 集合无缺漏/额外键。
- RegionSlots 与共享 Water Catalog 复用同一实现。服务端 Water Objects 也复用严格 integer；其 `exactKeys` 仍保留本地合同，因为它允许 metatable。
- 既有 `Common.identityKey`、`Common.classInstance`、`Common.isFiniteNumber`、`ServerUtil.invoke`/`identityKey` 优先复用，不新增相同实现。

### 语义接口清单

| 接口 | 使用方及范围 |
|---|---|
| `GenerationTransaction.begin/owns/current/advanceStage/recordAck/markBoundaryCleared/setPlayer/cancel/rollback/release` 及断线/重试操作 | Construction 内部事务服务；`current()` 给 detached snapshot，外部通过命名状态操作变更。 |
| `Boundary.transitionActivitySnapshot`、`addTransitionLifecycleListener`、`addPostPlayerTickHandler` | BoundaryGuard 向独立服务提供 identity/activity facts 与受控后 tick/lifecycle hook。 |
| `Boundary.pruneBuilderActionLedger`、`invalidateBuilderActionsForGeneration` | Boundary 的事件/注册流程通知 DemolitionProtection ledger，调用者不接触 ledger table。 |
| `RV.Server.Construction.ensureGeneratorForEntry`、`restoreCurrentCell` | RVMapping/EntryExit 与 TemplateRecovery 使用的受控世界修改服务。 |
| `RV.Server.acknowledgeRoofRefreshRelocation`、`isRoofRefreshTransactionActive` | 公开 ACK 分发、mutex 状态查询；不泄漏 Roof group/member table。 |
| client `roomOwnershipGuardStatus`、`refreshRoomOwnershipByIdentity`、`reopenFinalRelocationScan` | GUI 子模块内部按 identity 交互；不暴露 guard/final-relocation table。 |
| `Adapter.currentMappingEpoch`、`advanceMappingEpoch` | UtilityServer 与 RVMapping 映射变更同步；不再直接读取或递增 `_mappingEpoch`。 |

不把 manifest、layout、mapping record、bitmap、boundary record、已验证 Roof identity 或 snapshot 的公开 schema 字段机械包 getter；这些是 value-object 合同，调用者依既有严格 validator 使用。

## 重复 helper 审计

| helper 组 | 结论 | 语义依据 |
|---|---|---|
| strict `integer` / `exactKeys` | 已统一 StrictSchema；共享 RegionSlots、Water Catalog 使用它，server Water Objects 的 strict integer 亦复用。 | StrictSchema integer 拒绝数字字符串和 Java numeric wrapper；`exactKeys` 拒绝 metatable。server Water Objects `exactKeys` 可接受 metatable，故不替换。 |
| `RV_Bitmap` integer 与 `Constants.finiteInteger` | 有意保持分开。 | Bitmap 旧实现先用 `finiteNumber` 转数字字符串/wrapper，再 floor；`Constants.finiteInteger` 显式拒绝 NaN/±Inf，接受域并非逐项一致。结构任务不改变 Bitmap 输入合同。Bitmap 的 `finiteNumber` 也用于坐标正规化与 key 检查。 |
| Server Water `invoke` | 已统一。Objects、Commands、Plumbing 删除仅转发 `Util.invoke` 的本地 wrapper，直接调用 `Util.invoke`。 | 参数顺序、pcall 结果和多返回值一致。Shared Catalog 仍保留私有 invoke，因为共享层不能依赖 server helper，且仅提供只读能力探测。 |
| Water/Power `identityKey` | 已统一至 `ServerUtil.identityKey`。 | 这些调用前由领域流程验证 RV id/generation/bitmapVersion；新编码采用已有 length-delimited key，减少冒号拼接碰撞。TemplateRecovery 仍使用领域本地 key，不是 Water 普通身份键候选。 |
| Demolition `objectModData` 与 `ServerWorld.objectModData` | 有意保持不同。 | Demolition 的 `ctx.call` 在读取 `target[method]` 时没有 pcall，异常会传播；ServerWorld 经 `Common.invoke` 连读取方法属性都保护并返回 nil。替换会改变异常/失败语义。 |
| Power Devices `instanceof` | 已统一至 `Util.classInstance`/`Common.classInstance`。 | 原本地防护对 `instanceof` 调用 pcall 并仅接受严格 true，Common 合同相同。 |
| ServerTeleport `finite` | 已统一至 `Common.isFiniteNumber`。 | 两者均只接受原生 number，拒绝 NaN 与 ±Inf。 |
| Client `finiteInteger` 薄 wrapper | 已删除无附加政策的转发函数。 | 直接沿用 Shared Constants 的原生有限整数合同。 |
| footprint/safety 策略 | 有意保持领域实现分开。 | TemplateRecovery 处理车辆、血污、容器、加载格和恢复安全；DemolitionProtection 处理玩家建造归属、壳体和 buildable 区域。统一会改变对象保留/移除政策。 |
| Power Devices `invoke` shorthand | 有意保留为本地命名别名；底层直接是既有 `Util.invoke`，无独立实现或策略。 | 此次明确收敛 Water wrapper；Power 调用点多并在模块内使用一个命名动词，不另造底层 helper。 |

尚无需要本轮扩大的 helper 合并。`Common.identityKey` 的不同 length-delimited 编码不会改变已通过严格领域校验的身份字段含义；任何新用途仍须先校验输入字段。

## 私有字段扫描审计

扫描范围：`contents/mods/RailroaderRVTest/42/media/lua/`；关键词为 `_states`、`_builders`、`_mappingEpoch`、`pendingGeneration`、`roofRefreshRelocationGroup`、`roofRefreshGroupFinalReturn`、`pendingFinalRelocation`、`roomOwnershipGuards`。

| 关键词 | 剩余引用及判断 |
|---|---|
| `_states` | Client `BoundaryClient._states` 只由客户端 BoundaryClient 自己读写；Server `Boundary._states` 由 BoundaryGuard 包内 Geometry、Sweep、BoundaryValidation 读写，TemplateRecovery 等外部包不再访问。 |
| `_builders` | Lua 源码零命中；BuilderActionLedger 以 DemolitionProtection 私有 table 实现。 |
| `_mappingEpoch` | 只留在 Adapter 根模块对旧内部数值的初始化/镜像，外部 Mapping 改用 `advanceMappingEpoch`，UtilityServer 改用 `currentMappingEpoch`。 |
| `pendingGeneration` | Lua 源码零命中；owner 是 GenerationTransaction 的私有 `state.record`。 |
| `roofRefreshRelocationGroup` / `roofRefreshGroupFinalReturn` | 仅 Core 内部 `ctx` 空状态初始化和 RoofRefresh 包内部访问；Core 不解析记录内容，RoofRefresh 外部通过 API 查询/操作。 |
| `pendingFinalRelocation` | 只在客户端 Relocation 模块拥有；RoomOwnership 通过 `reopenFinalRelocationScan` 请求 bounded scan 重开。 |
| `roomOwnershipGuards` | 客户端只由 RoomOwnership 模块拥有；Relocation 用按 identity 的查询/刷新接口。服务端由 RoofRefresh RoomOwnership 模块拥有，Core 仅在组装时创建传入的状态容器。 |

RoofApi 和 RoofRelocation 仍在同一 RoofRefresh 包内部协作读取 group/member 快照并调用具名生命周期操作；没有 Construction、GenerationAck、RoomOwnership 或 Adapter 直接修改成员字段。Boundary 内部 state 跨同一 package 文件访问是 Boundary package 的内部实现，不是目录外访问。

## 保留不动清单

- `RV_RailroaderContextMenu.lua`：保留；Railroader 字段读依赖已在 adapter 边界，继续拆分不集中更多外部字段访问。
- Boundary geometry registry 与 player guard 暂不拆成两个独立包；transition state、geometry cache 与内部 helper 仍紧密耦合，拆分会要求公开私有 helper；当前用 package ownership 和 identity-level activity API 收窄外部边界。
- Power Devices 与 Water 事务分层不重组；Water `Ledger/Plumbing/Commands/facade` 保持。Shared Bitmap/RoomTemplate/Power 仍由既有领域模块持有各自 schema、几何和纯计算。
- RVMapping Train、RecordValidation、Core composition root/event/tick dispatcher、DevSaveSchemaGate 不为行数拆分；root forwarding files 保持，未猜测外部加载约定。
- TemplateRecovery 与 DemolitionProtection 的 footprint/protected-world policy 不合并；Bitmap strictness/identity 与 manifest/schema 读取继续按当前合同处理，不增加旧 schema alias、转换或迁移路径。

## 验证状态

- 静态结构关键词审计及代表性调用路径审阅已执行，结果见上表。
- `git diff --check` 已通过；输出仅有现有 Git 行尾转换提示，没有 whitespace error。
- 已从项目根目录直接以可见 TTY 执行唯一整体 runtime 命令 `python testserver/run_test.py`。Python 报告 `testserver/run_test.py` 不存在；失败后再检查确认 `testserver/` 目录也不存在。仓内存在 `tests/test_rv_server.py`，但未把它当成 runtime 入口或拆开运行。
- 未启动服务器，因此客户端交互/联机验收没有运行；修复测试入口需在后续环境变化后再执行指定一键流程。
