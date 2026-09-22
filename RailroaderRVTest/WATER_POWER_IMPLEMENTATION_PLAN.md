# Railroader RV 水电系统实施计划（已实施，待运行时验证）

> 状态：本文件同时记录当前实现契约与验收路线。Lua、Python 静态断言、README 和相关 agent.md 已按本路线更新；尚未完成整体运行时验证，未执行 `python testserver/run_test.py`。

## 1. 冻结的目标与决策

### 1.1 目标

房车中的原生水槽、浴缸、普通马桶，以及模组创建但仍被原版判定为可接入供水的 fixture，都可以连接到房车水系统。连接后，玩家继续使用原版的取水、饮用、清洗和其他用水动作；模组只提供房车范围内的隐藏水源和服务端结算。

最终模型分为 canonical record、usage settlement tank 和 fixture proxy 三层：

1. 每辆 RV 一个服务端权威、持久化的 canonicalTank 记录，字段包括 capacity、amount、sequence、state 以及 checkpoint/projectionPending 所需的检查字段。它是唯一最终余额，容量沿用当前项目的 UTILITY_WATER_CAPACITY 契约；它不是 world object，也不是 FluidContainer。
2. RV 所在区域一个隐藏真实“用水结算水箱”世界对象（IsoObject + FluidContainer）。它是 canonicalTank 的工作镜像/结算缓冲，不是最终权威，且自身不能被 fixture 的原版 3x3 搜索直接发现。
3. 每个已连接 fixture 正上方、位于原版搜索范围内的一个隐藏真实代理对象。原版动作从代理扣水；proxy 事件先汇总/扣减 usage settlement tank，再由低频 settlement 按 baseline/sequence 与 canonicalTank 结算，最后沿 canonicalTank → usage tank → proxies 重新投影。

三条行为通道分别是：usage consumption（负向，原版动作经 proxy 进入）、manual player input（正向，玩家库存中允许的 clean/tainted water source 事务直接进入 canonicalTank）和 future auto-refill（正向，当前 DISABLED，不生成/扫描/结算雨水桶）。canonicalTank 不记录 source kind；usage tank/proxy 始终投影为干净 Water。房顶不生成可见的真实雨水桶，不改变原版 3x3 搜索范围，不把引擎全局范围改为 20x40，也不把隐藏结算水箱注册成 SRainBarrelSystem 的雨水收集器。新建 RV 的 canonicalTank 初始 amount 默认 0，除非未来明确修改当前容量/初始量契约；当前计划不预灌水。

### 1.2 非目标

- 不实现 LG Extended Plumbing 的跨建筑、多雨水桶汇总、管线、液体分类、重力或发电上推。
- 不修改 Java、Lua 全局原版的 FindExternalWaterSource 3x3/z+1 算法。
- 不按对象名称、sprite 名称、FluidContainer 容量或 DEVICE_CATALOG 白名单决定原生资格。
- 不要求连接前已经存在 FindExternalWaterSource 结果；连接事务本身负责创建代理并在提交前证明结果。
- 不迁移旧 manifest、旧 bitmap、旧 RV mapping、旧可见雨水桶、旧 registry、旧 ledger 或旧代理对象。
- 不在本阶段保证所有向 fixture 输入液体的原版路径。第一阶段以原生取水/饮用/用水为主；输入能力另行按明确事务扩展。
- 不声称跨对象水量完全原子守恒。用户已经接受少量不守恒和极端并发误差，但安全不变量仍然必须 fail-closed。

### 1.3 冻结的取舍

- 以服务端 canonicalTank record 的 amount 为最终权威；usage settlement tank 的 FluidContainer 和每个 proxy 都只是干净 Water 工作镜像/结算缓冲，保存的 snapshot 不能成为第二个余额，source 的 clean/tainted kind 不进入 canonical ledger。
- OnWaterAmountChange 是 proxy 事件的首选入口，先按代理 baseline 差异汇总到 usage settlement tank；固定 tick 负责漏事件兜底，低频 settlement 再按 usage tank baseline/sequence 将确认消耗吸收到 canonicalTank，并重新投影三层状态。
- 连接、生成、删除、重建、同步和结构性失败必须有事务回滚，但回滚域只覆盖本次操作尚未提交的结构写入；已经确认并记入 canonicalTank 的 consumption settlement 不因后续投影或结构步骤失败而回滚或重扣。单次原生用水在 canonicalTank 水量不足或极端并发下允许小量误差，但 canonicalTank 余额绝不能为负。
- 保留现有电力设计和服务端权威/current-only schema 原则。电力不作为隐藏代理的额外水源，也不改变原生发电机行为。
- 不再重复核验 42.20.0 与 42.20.4 的 Java 差异。后续实现直接使用当前项目基线和已经审阅的官方/反编译证据；若唯一整体运行时测试暴露接口行为差异，在“测试→修复”阶段针对证据修正。

## 2. 只读证据和参考边界

### 2.1 原版 plumbing 能力与搜索链

已经审阅的 B42.20 反编译证据：

- game-decompiled/42.20.0/src/zombie/iso/ISWorldObjectContextMenuLogic.java:455-460：原版菜单候选同时看 modData.canBeWaterPiped、sprite property waterPiped、房间/停水状态和 FindExternalWaterSource；这不是按容量或名称的白名单。
- game-decompiled/42.20.0/src/zombie/iso/IsoObject.java:2340-2419：doFindExternalWaterSource 从对象上方 z+1 搜索中心格及周围八格；FindWaterSourceOnSquare 要求对象是 IsoThumpable、非实体地板 sprite、usesExternalWaterSource=false 且有可用 FluidContainer。搜索范围是固定 3x3。
- game-decompiled/42.20.0/src/zombie/iso/IsoObject.java:2557-2682：external source 的容量、amount、取水和加水会委托给被找到的源；服务端变更后会同步并触发 OnWaterAmountChange 相关路径。
- game-decompiled/42.20.0/src/zombie/iso/IsoObject.java:2861-2961：外部水源对象参与原生 UI、输入锁、净水和可用性判断。
- game-decompiled/42.20.0/src/zombie/iso/IsoObject.java:1505-1508、981-1095：外部标志及 FluidContainer/对象变化需要保存和网络同步。
- game-decompiled/42.20.0/src/zombie/iso/FluidContainer.java:203-235,481-499,625-660,826-915：输入锁、容量、amount、添加/移除和容量缩放是组件级行为，不能把组件容量当作 fixture 资格。
- official lua scripts/shared/Moveables/ISMoveableSpriteProps.lua:2335-2337：原生 moveable sprite 的 waterPiped 属性会设置 modData.canBeWaterPiped=true。
- official lua scripts/shared/TimedActions/ISPlumbItem.lua:31-37：原生 plumbing 完成时设置 external-water-source 标志并发送对象变化。
- official lua scripts/shared/TimedActions/ISTakeWaterAction.lua:25-29,136-141,151-160,175-203：原生取水动作在服务端进行 transfer/drink，适合由代理承接。
- official lua scripts/shared/TimedActions/ISAddFluidFromItemAction.lua:22-50,86-95 与 official lua scripts/shared/Fluids/ISFluidTransferAction.lua:24-32,70-77：输入液体有不同路径，后者可能直接操作组件而绕过对象 amount 事件，必须由阶段性支持策略明确处理。

这些证据只证明能力链和接口边界，不替代运行时验证。

### 2.2 化学马桶排除

原生对象资格先判断 plumbing 能力，再做明确的化学马桶拒绝。化学马桶身份使用原版明确的 MOV_CHEMICAL_TOILET（证据：game-decompiled/42.20.0/src/zombie/scripting/objects/ItemKey.java:1684）和当前对象/脚本身份，不使用模糊的名称包含判断。普通马桶只要通过原生 waterPiped/canBeWaterPiped 能力检查即可。

### 2.3 LG Extended Plumbing 只读参考

本地只读参考目录为：

- reference mods/3779561845/mods/LGExtendedPlumbing/42.20/mod.info:1-6
- reference mods/3779561845/mods/LGExtendedPlumbing/42.20/media/lua/shared/LGExtendedPlumbing/LGEPCore.lua:1-18,1562-1576,3023-3029
- reference mods/3779561845/mods/LGExtendedPlumbing/42.20/media/lua/shared/LGExtendedPlumbing/LGEPGhost.lua:1-28,86-193,236-339,1064-1133,1179-1431
- reference mods/3779561845/mods/LGExtendedPlumbing/42.20/media/lua/server/LGExtendedPlumbing/LGEPPlumbing.lua:407-430,1230-1435,1562-1689,4480-4650,4989-?

LG 的可复用事实是“每个 fixture 上方放置真实隐藏对象，并通过 FluidContainer/ledger 处理代理变化”；它没有修改原版 3x3，而是用每 fixture 的代理实现更大拓扑。LG 的建筑搜索、多桶汇总、管网、重力/发电机和液体分类不属于本项目。不得复制其数据文件或大段源码；实现必须是只参考接口和机制的最小 RV 版本。

Workshop LG Connect To Water Supply（3779251515 / LGMainsWater）只作为“原版 plumbing 标志决定资格”的说明来源，不把其 mains 逻辑当作雨水范围扩展。

## 3. 原生资格与客户端提示

### 3.1 唯一资格判定

服务端 isNativePlumbableFixture(object) 的判定顺序固定为：

1. 解析对象当前身份和 IsoObject/sprite properties。
2. 明确拒绝化学马桶。
3. 接受原生 sprite property waterPiped，或原版/模组在 modData 提供的 canBeWaterPiped=true 能力标记。
4. 不读取或比较名称、sprite 猜测表、FluidContainer 容量、当前 amount，也不要求当前已有 external source。
5. 用 RV 范围、房间/高度、玩家权限和请求阶段做独立的安全检查；这些条件不改变“原生能力”本身。

因此，未知名称的模组 fixture 只要当前对象真实具备上述原生能力就接受；没有能力标志的任意容器不因“看起来像水槽”而接受。

### 3.2 客户端与服务端职责

- 客户端只显示候选、提交 requestId、对象提示和意图；客户端 candidate、runtimeTestEnabled、hint 均不可信。
- 服务端收到请求后重新解析对象、玩家、RV identity、权限、距离、工具、当前 schema、generation、对象 token/fingerprint、fixture 能力和当前请求阶段。
- DEVICE_CATALOG 只保存显示名、图标、可选的测试描述和 deviceType 提示，不再承担资格白名单。
- runtimeTestEnabled 只控制测试路径是否可被测试脚本请求；runtimeValidated 只记录已经经过整体运行时矩阵的案例，二者都不能绕过服务端能力判定。
- 连接前不得因为 FindExternalWaterSource 为 nil 而隐藏或拒绝候选；连接后必须由服务端证明找到的源正是本次生成的代理。

### 3.3 已登记设备的持续身份

首次连接才需要 3.1 的 waterPiped/canBeWaterPiped 能力判定。已登记设备在持续审计、取水、同步、拆除和恢复时，不要求 canBeWaterPiped 仍为 true；该标志在原版连接后可能变化，不能因此把合法设备误断开。

持续验证只使用当前 registry identity、RV/generation、fixture 坐标、稳定 fixture token/fingerprint、proxy 后置证明和 chemical toilet deny。fixture fingerprint 必须排除 amount、FluidContainer 水量、external flag、canBeWaterPiped、可变 modData、连接状态和其他正常运行时变化字段；object token 负责对象实例寿命，fingerprint 负责稳定的对象/脚本/sprite 身份。对象替换即使名称和坐标相同，也必须因 token 或稳定 fingerprint 不一致被识别。

## 4. 对象架构、坐标、隐藏、网络与保存

### 4.1 隐藏 usage settlement tank 对象

推荐实现为普通 IsoObject（带唯一隐藏 sprite 和真实 FluidContainer），而不是可被原版 3x3 自动发现的 IsoThumpable。它是隐藏 usage settlement tank，放在 RV 所在区域的确定性 usageTankOffset，不放在房顶，不使用可见雨水桶 sprite，不进入 SRainBarrelSystem。它的 modData 只写当前 schema 的工作镜像 identity tag：

    role=rv_hidden_usage_tank
    rvId, generation, bitmapVersion, schemaVersion
    objectToken, objectFingerprint

canonicalTank record 只保存 capacity、amount、sequence、state 及 checkpoint/projectionPending 所需字段，并决定最终可用余额。usage tank FluidContainer 只保存干净 Water 的 amount/capacity 工作镜像；任何 usage tank 本地变化都必须按 usage baseline/sequence 回收到 canonicalTank，不能把它当作独立库存或第二 canonical。

usage tank 不设置 rain catcher，不接受天气补水，不允许客户端写入，不被 fixture 的原版 3x3 直接发现。canonicalTank fresh 初始量为 0；生成 usage tank 时只投影 canonicalTank 当前值，不凭空预灌水。

对象和结算方向固定如下：

    manual ADD_WATER (+, source confirmed)
                 │
                 ▼
    canonicalTank record  ← future auto-refill (+, DISABLED)
       │                 ▲
       │ low-frequency   │ usageDelta settlement
       │ projection      │ (baseline/sequence)
       ▼                 │
    hidden usage tank ───┘
       │
       │ original 3x3/z+1 lookup
       ▼
    hidden proxy per fixture
       │
       └─ native consumption (-) → OnWaterAmountChange / tick

只有 canonicalTank record 决定最终余额；usage tank 是结算缓冲，proxy 是原版动作入口。

### 4.2 每 fixture 代理

每个已连接 fixture 只创建一个真实 IsoThumpable 代理：

- 坐标严格为 (fixture.x, fixture.y, fixture.z + 1)，即落入原版固定 3x3/z+1 搜索；
- 代理必须确定性插入到可被原版 objects 扫描的 square/object 集合位置，sprite 使用专用且非实体地板的隐藏/blueprint sprite；object index 只是当前运行时 hint，可因加载、重建或其他对象变化而改变，绝不是持久化 identity 契约；
- usesExternalWaterSource=false，rainCatcher=0，不贡献自然降雨；
- FluidContainer 由服务端创建并设置当前容量、初始 amount 为干净 Water、inputLocked；
- modData 身份包含 role=rv_hidden_proxy、rvId、deviceId、generation、schemaVersion、objectToken、objectFingerprint；
- 不修改普通雨水桶 sprite，也不把 fixture 的 sprite 改成模组私有名称来猜资格。

setDoRender(false) 只能视为客户端表现优化，不能视为保存契约。对象进入客户端、加载 chunk 或重连后必须按当前 identity 重新应用隐藏表现；真实对象、FluidContainer、tag 和 registry 仍由服务端保存/同步。

### 4.3 创建和同步

canonicalTank record 的创建、读取、更新、持久化和回滚，以及 usage tank/代理对象创建、添加到 square、组件初始化、transmitAdd、sendObjectChange、删除和回滚均由服务端执行；这些回滚只覆盖当前尚未提交的结构/投影写入，不回滚已确认的 consumption settlement。客户端不提交可信坐标，不创建对象，不写 record 或 FluidContainer。代理创建后必须等待对象挂入 world/index，再同步组件；直接修改已挂对象的组件时只做一次批量同步，避免事件和同步循环。

usage tank 的 IsoObject/GameEntity 保存能力和 FluidContainer 网络同步沿用原版接口；canonicalTank 通过当前 water schema 持久化。加载时先验证 canonicalTank/schema、usage identity 和代理 identity，再决定恢复或 fail-closed。客户端发现未知旧 sprite、缺失组件或 record/object 不一致时只显示不可用状态并等待服务端，不自行补造 record、usage tank 或代理。

## 5. 服务端连接事务与后置证明

连接命令是意图，不是状态。服务端事务按下列顺序执行：

1. 校验 requestId/session、玩家在线身份、管理员/工具要求、当前阶段、RV identity、距离和权限。
2. 解析目标当前 square/object，验证 object token/fingerprint；首次连接执行 3.1 的 native capability，已登记设备只执行 3.3 的持续 identity 检查和 chemical toilet deny。
3. 验证目标属于当前 RV 且没有同一 deviceId 的活动 registry；目标移动、替换、旧 generation 或旧 schema 立即拒绝。
4. 在任何创建/覆盖 proxy 前调用 flushBeforeOverwrite(rvId, CONNECT, context)；若相关内部 chunk 未权威加载，标记 DEFERRED/NEEDS_RECONCILE，不创建 proxy、不建立 baseline。
5. 计算 (x,y,z+1)，确认 square 可加载且不存在第二个当前 identity 的代理；不信任客户端或存档中的 object index，服务端按坐标和当前 objects 集合重新解析。不能清理或改写旧 schema 的未知对象。
6. 在服务端创建代理、组件、tag、FluidContainer 和 baseline；挂入 square 并同步。
7. 重新调用原版 external-source 查找，要求返回的对象坐标、token/fingerprint 与新代理完全一致；object index 仅用于这次查找的运行时提示，不能作为证明。此步骤是创建后的 postcondition，不是连接前置条件。
8. 服务端设置 fixture external flag，发送原版 object change，再次验证 fixture 当前 source 仍为该代理。
9. 只有上述后置证明全部通过，才写入 registry/proxy ledger 并提交 transaction sequence。
10. 任何结构性失败都按逆序撤销本事务新建的 fixture flag、代理、registry 和 ledger；回滚只针对本次 current generation 新对象，不能触碰旧存档对象。

连接成功后，玩家动作必须走原版目标。玩家不能直接把代理 object id、坐标或 amount 作为可信参数提交。

## 6. 两级 ledger、结算顺序和允许的误差

### 6.1 两级运行时状态

第一级是服务端 canonicalTank ledger：capacity、amount、sequence、state、checkpoint 和 projectionPending 由服务端内存 record 持有并按 current-only water schema 持久化。它是最终权威余额，记为 C；任何 world object 或 proxy amount 都不能替代它。canonicalTank 不记录 source kind。

第二级是 usage settlement ledger：隐藏 usage tank 的 FluidContainer 记为 U，始终只装干净 Water；每个当前已加载 proxy P_i 也始终只投影干净 Water，并保存 baseline B_i、上次观察值和 proxy sequence。U 是原版 external-source 的工作镜像，P_i 是原版动作接口的工作副本；不能把 U 或所有 P_i 的 amount 相加成第三份库存。

### 6.2 统一 flushBeforeOverwrite 服务入口

除 damaged-object emergency quarantine 这一明确的紧急停供分支外，所有会覆盖、补满、重建或删除 proxy/usage tank 的服务端路径只能进入一个入口：flushBeforeOverwrite(rvId, operation, context)。它持有 per-RV accounting guard，并在相关内部 chunk 已权威加载时严格执行以下唯一顺序；紧急分支必须遵守 9.2.1 的 suppression/隔离顺序，不能把完整 flush 当作继续供水的理由。

1. collectAllLoadedProxyDeltas：读取当前所有已加载且 current identity 有效的 P_i；对每个 proxy 以 B_i/sequence 收集尚未处理的 delta，先扣 U，推进 proxy/usage sequence。该收集在低频 settlement 内直接调用，不能依赖另一个 tick 先执行。
2. settleUsageToCanonical：读取 U 相对 usage baseline 的尚未结算 usage delta，按 sequence 只提交一次到 C，推进 canonicalTank.sequence 和已消费 sequence；checkpoint 仅是候选，不能在投影未完成时发布。不能在收集前覆盖 U，也不能把 usage tank 当前 amount 直接当作 C。
3. executeOperation：执行本次 manual add、connect、detach、scheduled sync、recovery、故障隔离或其他明确操作。manual add 只在此阶段增加 C；connect/detach 不把结构操作伪装成 consumption。quarantine/dry quarantine 的目标必须在本阶段开始时从 ACTIVE projection set 排除，后续步骤不得重新补满它。
4. projectCanonicalToUsage：将 C 的 amount 按 capacity 投影到 U；U 只写干净 Water，任何旧 U amount 在写前都已完成收集/结算。
5. projectUsageToProxies：将 U 投影到 executeOperation 后仍处于 ACTIVE 的 P_i；每个 proxy 单独写入并确认，只有对应写入成功才更新该 proxy 的 baseline、projection sequence 和状态。任何 proxy 覆盖前已完成本次 flush；不能把未确认的 proxy 当作已投影。

已加载时新连接、内部 ADD_WATER、scheduled sync、恢复、正常拆除和 manual detach 都必须调用该入口，不能各自实现不同顺序；damaged-object emergency quarantine 使用第 9.2.1 节的紧急分支，不以该入口完整 flush 成功为停供前提。低频 settlement 不是独立捷径，第一步永远是 collectAllLoadedProxyDeltas。入口内的 projection guard 会阻止“C→U→proxy”写入再次进入 consumption 结算。

### 6.2.1 结算提交与部分投影失败边界

- `settleUsageToCanonical` 是 consumption settlement 的提交边界。C 的 amount、canonical sequence 和已消费 usage sequence 一旦服务端确认提交，就不能因后续 usage/proxy 投影、对象同步或结构操作失败而撤销，也不能在重试时再次扣除同一 sequence。
- C→U 与 U→P 是彼此可审计的逐对象 projection commit。usage tank 的实际写入成功后才更新 `usageTankSnapshot` 的 amount/baseline、`projectionSequence` 和状态；每个 proxy 的实际写入成功后才更新其 `proxyLedger` amount、baseline、`projectionSequence` 和状态。world 写入及其对应 ledger/baseline 更新必须作为同一次逻辑确认；任一侧无法确认时都按未完成处理，即使当前 amount 看起来已经等于目标，也不提前推进失败对象的 sequence。
- 如果 U 写入失败，则不覆盖任何 proxy；如果 U 成功而部分 proxy 失败，已成功的 U/proxy 投影和其 baselines 保留，失败 proxy 标记 `NEEDS_RECONCILE` 或进入 dry quarantine，并从后续 ACTIVE projection set 排除。处于 `NEEDS_RECONCILE` 的失败项仍阻止完整 checkpoint；只有该项投影成功，或完成 dry quarantine 且后置证明已不可供水后，才可从必要集合移除。`canonicalTank.projectionPending=true`，记录 pending sequence/reason；重试只处理未确认的 U/proxy 投影。
- 任何必要的 U/proxy 投影未完成时，`checkpoint.state` 保持 `UNSETTLED`/`DEFERRED`，不能发布新的完整 checkpoint。只有 U 和全部必要 ACTIVE proxy 的投影、baseline 和 sequence 都确认成功，且所有失败项已完成可审计的 quarantine/suspension 后，才写入匹配的 SETTLED checkpoint 并清除 projection pending。
- 连接、拆除、重建等结构事务失败时，只撤销该事务尚未提交的 fixture flag、对象、registry 或 ledger 写入；不能顺带回滚此前已经提交的 consumption settlement。结构回滚和 projection retry 都不得重放 source transaction。

LOCOMOTIVE 在内部 chunk 未加载时的 canonical-only manual add 是唯一明确的 deferred exception：它不覆盖或写入任何 world object，因此只执行 canonical source transaction、推进 canonical sequence 并记录 projectionPending；后续 chunk 加载仍必须回到本入口先 reconcile 旧 U/P，再 projection。

### 6.3 事件、tick、sequence 与恢复分类

OnWaterAmountChange 收到 proxy/fixture 变化时只调用受 guard 保护的 collectProxyDelta；直接组件操作漏发事件时，服务端 tick 调用同一个 collectAllLoadedProxyDeltas。事件、tick 和低频 settlement 都使用 proxy sequence/usage sequence/canonical sequence 去重，不能把同一 delta 再次扣除。

恢复必须按以下优先级执行：

1. **先检查当前已加载对象，再解释 checkpoint**：相关 chunk 已由服务端权威加载时，必须先读取当前 U、每个当前 proxy P_i、各自 baseline/usage sequence 和 usage snapshot。checkpoint 与 snapshot 匹配只证明上一次完整结算曾经完成，不能证明本次加载前没有新发生且尚未处理的 delta。
2. **发现任何 pending delta 时优先 collect/settle**：只要任一 P_i 相对 baseline 有差值、usage sequence 高于已确认 sequence、U 相对 usage baseline/snapshot 有差值，或 projection/checkpoint 状态为未完成，就先按 sequence collect 全部可确认 proxy delta，再 settle U→C；在此之前不得按 C 覆盖 U/P、建立新 baseline 或发布 checkpoint。即使历史 checkpoint 匹配，也必须遵守此优先级。
3. **确认无 pending delta 后才能直接投影**：只有当前 U/P 与基准和 snapshot 明确无待处理差值，且 checkpoint 为 SETTLED、sequence/amount 相互匹配时，才允许按最新 C 直接重建 U 并投影 ACTIVE proxy。投影成功规则仍受 6.2.1 约束。
4. **相关 chunk 未加载**：标记 NEEDS_RECONCILE/DEFERRED（故障路径使用 QUARANTINE_PENDING），不认定对象缺失、不投影 C、不建立新 baseline。第 9.2 节的未加载规则优先于 schema 的“缺失对象”判断。

正常 record、world object、component 的加载先后差异不等于 partial write；必须等待预期对象/record 到齐并完成上述当前对象检查。只有当前 schema 本身部分写入、sequence 冲突无法解释，或权威加载并审计证明对象缺失/重复/identity 错，才进入 REBUILD_REQUIRED。不能声称“先写 C 再写 object”自动形成一致 checkpoint；checkpoint 只有在两级 ledger 按 flush 顺序完成、所有必要投影均确认并记录相互匹配的 sequence 后才成立。

两级 ledger 的覆盖保护示例：checkpoint 为 C=100、U baseline=100，proxy 已发生但尚未结算的消费使当前 U=90。此时 LOCOMOTIVE 入口在内部 chunk 未加载，确认补水 50 只更新 C=150、设置 projectionPending=true，U 仍为 90；chunk 加载后先读取旧 U/P、collect/settle 旧 10，使 C=140，再执行 C→U→P 投影，最终 U/P=140。若在加载前直接用 C 覆盖 U，或在补水时把 U=90 当作 C，会丢失该 10；flushBeforeOverwrite 禁止这种覆盖。

### 6.4 崩溃、partial save 和误差

已加载对象的保存/同步只有在 flushBeforeOverwrite 完成、U 与全部必要 proxy 投影逐项确认后，才能生成 usageTankSnapshot 与 canonicalTank.checkpoint 的匹配 sequence；部分投影只能保存 pending/reconcile 状态，不能伪造完整 checkpoint。LOCOMOTIVE 未加载路径可单独持久化 canonicalTank amount/sequence，并明确 projectionPending、pendingProjectionSequence、pendingProjectionReason，不生成 checkpoint。记录和 world object 的物理写入顺序不作为一致性证明；重启时按第 6.3 节分类，未提交 usage delta 最多按当前 sequence 再结算一次，不能按旧 proxy snapshot 重放多次。

接受的误差：

- proxy event、tick、低频 settlement 之间的少量竞态可能造成小量不守恒；
- 多 fixture 同 tick、低频结算同时发生时允许极端并发误差；
- canonical 不足时已经从 usage/proxy 扣掉的少量原生用水不保证跨对象原子回滚。

### 6.5 安全不变量和输入边界

绝不允许的安全违规：

- canonicalTank amount 为负或超过 capacity；
- 客户端直接创建/修改 canonical record、usage tank、proxy，或跨 RV 读写；
- usage→canonical settlement 已消费的 sequence 再次结算，或者 canonical→usage→proxy 投影被当成输入，凭空生成水；
- 普通不具备原生能力的容器、化学马桶、旧 generation 或旧 schema 获得连接；
- 同一 fixture/deviceId 有两个当前 proxy，或 usage tank/proxy 被另一个 RV registry 认领；
- 结构性连接/删除/重建失败后留下半提交 registry、external flag 或重复代理；结构事务回滚不触碰此前已提交的 consumption settlement。
- 旧存档被自动迁移、alias、字段推断、自动清理或继续运行；
- 客户端 hint、坐标、amount、deviceType 覆盖服务端重新解析结果。

- 原版动作、manual input 或 future provider 的 clean/tainted water source 之外的汽油、酒精等非水 source 被接受；
- quarantine/detach 造成的 proxy 清空 delta 被计为玩家 consumption；
- 未加载 chunk 被误判成缺失并投影、建 baseline 或自动生成对象。

### 6.6 原版输入动作和阶段支持

第一阶段只保证原生从 external source 读取的动作，包括 ISTakeWaterAction 及其饮用/清洗路径；proxy 和 usage tank 默认 inputLocked，避免不受控的输入改变两级 ledger。ISAddFluidFromItemAction 的 external 边界和 ISFluidTransferAction 的直接 FluidContainer 路径不得绕过 canonicalTank。除本计划第 7.1 节的 manual ADD_WATER 外，第一阶段保持输入锁定并明确记录“不支持从物品向 RV proxy/usage tank 输入”。不得把事件未触发误认为输入成功。

## 7. 容量、来源、停水停电

- canonicalTank capacity 使用当前 UTILITY_WATER_CAPACITY（当前契约为 1000.0）；创建/恢复时先设置容量，再设置 amount。容量缩小时先清理超出部分，不能由客户端指定新容量。
- usage tank/proxy capacity 是承接原生动作的工作容量，由 canonicalTank 当前可用量投影；proxy/usage 总和不是额外库存。
- canonicalTank 不记录 source kind；usage tank/proxy 每次都从 canonicalTank 投影为干净 Water。manual/未来 auto-refill 的 source 只能是原版允许的 clean Water 或 tainted water；汽油、酒精等非水 source 拒绝。source 的 clean/tainted kind 不传播到 canonical、usage 或 proxy，也不在 ledger 中做额外转换。
- usage tank/proxy 不设置 rain catcher，不接入 SRainBarrelSystem；canonicalTank 也不接受天气输入，不因天气或房顶位置自动增水。
- 居民区停水只影响原版 mains/无限水源判断；连接后的 RV 水量来自当前 canonicalTank。停水、恢复供水和原生 preWaterShutoff 分支都必须在运行时矩阵中验证，不能以水箱容量字段替代原版资格。
- 电力仍沿用当前 native IsoGenerator 设计。水箱/代理不伪造发电、泵或电网，也不因发电机开关改变基础取水；如果未来新增泵规则必须另开 schema 和权限事务。

### 7.1 手动向房车加水（ADD_WATER）

“向房车加水”是独立的、低频离散 manual input channel，不是向 fixture 或 proxy/usage tank 倒水。新建 RV 的 canonicalTank amount 默认 0；只有当前常量以后明确声明初始量时才例外，当前计划不凭空预灌。

该命令有两个服务端 entryPoint，二者都使用同一 source planned/confirmed 事务和同一 requestId 幂等逻辑：

- **INTERNAL**：服务端确认玩家当前属于该 RV，inside relation/bitmap 有效，且玩家处于房车内部允许交互范围。内部入口需要相关 RV 状态可权威加载；未加载时不能凭客户端 hint 判断 inside。
- **LOCOMOTIVE**：服务端重新解析当前机车实体，验证玩家与机车固定范围，且机车恰好映射到一个 current RV mapping 并具备权限。此入口只要求 canonicalTank/mapping 有效，不要求 RV 内部 chunk、usage tank 或 proxy 已加载。

客户端只提交 entryPoint、requestId、sessionNonce 和不可信的 item/source hint。服务端必须重新解析玩家当前库存中的 source FluidContainer，并验证玩家身份、entryPoint 对应的权限/范围、当前 RV identity、current schema、请求阶段和 source token。source 只允许原版 clean Water 或 tainted water；汽油、酒精等非水 source 拒绝。复用现有 ADD_WATER 的命令分发、requestId/session guard、独立 inventory source 解析、权限/范围/schema 检查和 source FluidContainer 读回辅助逻辑；删除其中把 confirmed 值写入旧 sharedAmount、直接镜像 fixture amount 或把 proxy 当作输入目标的部分。

当 INTERNAL 或 LOCOMOTIVE 操作时相关内部 chunk 已权威加载，必须先调用 flushBeforeOverwrite；统一顺序是 collectAllLoadedProxyDeltas → settleUsageToCanonical → 执行本次 source transaction 增加 canonicalTank → projectCanonicalToUsage → projectUsageToProxies → 更新 checkpoint/baselines/sequences。不得先覆盖 usage tank。

当 LOCOMOTIVE 入口有效但内部 chunk 未加载时，只更新 canonicalTank，设置 projectionPending=true，并记录 pendingProjectionSequence=本次 canonical sequence 与 pendingProjectionReason=LOCOMOTIVE_ADD_UNLOADED；不扫描/创建 usage tank 或 proxy，不建立新 baseline。以后内部加载时，先按第 6.3 节处理旧 pending consumption/usage sequence，再把包含新增量的 canonicalTank 投影到 usage tank/proxy。该顺序保证先发生的消费不会被新增水覆盖。

source 事务顺序固定为：

1. 以服务端实际 source FluidContainer 和 canonicalTank 当前 capacity 计算 plannedTransfer；客户端 amount、source 坐标和容量不可信。canonicalTank 已满或 source 不可用时 plannedTransfer 为 0，不能先扣 source。
2. 服务端先从 source 扣除 plannedTransfer，然后读取 source 前后实际差值，得到 confirmedSource/confirmedTransfer；未确认的计划量不得进入 canonicalTank。
3. 只按 confirmedTransfer 增加 canonicalTank record，读取 record 写入后的实际 confirmedCanonical；这一步直接修改 canonicalTank，不写 proxy，不写 usage tank 作为权威。
4. 若 canonical 写入失败或 confirmedCanonical 小于 confirmedTransfer，按同一服务端事务偿还未进入 canonical 的 source 差额并读回；补偿失败时拒绝提交、锁定该 request 的重放并将 current canonicalTank/state 置为 REBUILD_REQUIRED，等待用户重建，绝不凭空增加 canonical。成功后记录 requestLedger.entryPoint。
5. 成功提交后，已加载路径按统一 guard 投影干净 Water；LOCOMOTIVE 未加载路径保持 projectionPending，不能提前生成 world object。

同一 sessionNonce/requestId/entryPoint 的重试必须返回 requestLedger 已记录的结果，不得再次扣玩家 source；不同 requestKey 或 entryPoint 必须重新通过服务端阶段验证。

### 7.2 未来 auto-refill channel（当前禁用）

为未来玩家安装并由服务端登记的雨水收集桶预留稳定 provider/channel 接口，但本版本明确禁用：

    providerId, channelId, rvId, generation,
    schemaVersion, sequence, state=DISABLED,
    confirmedDelta, objectToken, objectFingerprint

未来 provider 必须先验证来源是允许的 clean Water 或 tainted water，再进入独立的 auto-refill settlement layer/adapter，按低频 sequence 产出 confirmed positive delta，由 canonicalTank 吸收；不能直接写 proxy 或 usage tank。当前实现不得生成、扫描、连接、结算或 fallback 到任何雨水桶，未知 provider/channel 必须拒绝。若以后启用，必须显式 bump schema、登记 provider identity 并重新授权，不得把 DISABLED 字段当作当前可用能力。

## 8. Current-only schema 和版本门

### 8.1 当前 water 记录的精确字段

最终实现只接受以下结构；缺失、额外旧字段、类型错误、版本不匹配或 partial write 都是 SAVE_REBUILD_REQUIRED：

    water = {
        schemaVersion,
        canonicalTank,
        usageTankIdentity,
        usageTankSnapshot,
        registry,
        proxyLedger,
        requestLedger,
        autoRefill,
        state
    }

    canonicalTank = {
        capacity, amount, sequence, state,
        projectionPending, pendingProjectionSequence,
        pendingProjectionReason, faultPolicy, checkpoint
    }

    checkpoint = {
        canonicalSequence, usageSequence,
        usageAmount, state
    }

    usageTankIdentity = {
        role, rvId, generation, bitmapVersion,
        x, y, z, objectToken, objectFingerprint
    }

    usageTankSnapshot = {
        capacity, amount, baselineSequence,
        usageSequence, settledCanonicalSequence,
        projectionSequence, state
    }

    registry[deviceId] = {
        deviceId, deviceType, rvId, generation, bitmapVersion,
        fixtureX, fixtureY, fixtureZ,
        fixtureToken, fixtureFingerprint,
        proxyX, proxyY, proxyZ,
        proxyToken, proxyFingerprint,
        registeredSequence, status
    }

    proxyLedger[deviceId] = {
        deviceId, amount, capacity,
        baselineSequence, usageSequence,
        projectionSequence, status
    }

    requestLedger[sessionNonce:entryPoint:requestId] = {
        requestId, sessionNonce, entryPoint,
        operation, status, plannedTransfer,
        confirmedSource, confirmedCanonical, sequence
    }

    autoRefill = {
        providerId, channelId, rvId, generation,
        schemaVersion, sequence, state,
        confirmedDelta, objectToken, objectFingerprint
    }

canonicalTank.amount 是最终权威余额；usageTankSnapshot.amount 只是 U 的最后一次已确认工作镜像检查点，usage tank FluidContainer 也只是可重建的干净 Water 工作镜像。`projectionSequence` 只表示对应 U/P 的 C→world projection 已实际确认，不是新的水量或 consumption sequence；投影失败时不能推进它。checkpoint 只有在 canonicalSequence、usageSequence、usageAmount、usageTankSnapshot 以及所有必要 ACTIVE proxy 的 projectionSequence/状态相互匹配时才证明镜像已完整结算。加载时按第 6.3 节分类，不把 world FluidContainer 或 snapshot 变成第二份可消费余额。canonicalTank.state 和顶层 state 只允许当前代码声明的 ACTIVE、NEEDS_RECONCILE、DEFERRED、QUARANTINE_PENDING、REBUILD_REQUIRED；autoRefill.state 当前必须为 DISABLED；未知状态立即拒绝。deviceType 是当前身份记录，不是资格判断。
usageTankSnapshot.state 只允许 SETTLED、UNSETTLED、DEFERRED；registry/proxyLedger.status 只允许 ACTIVE、NEEDS_RECONCILE、DEFERRED、QUARANTINE_PENDING、SUSPENDED、REBUILD_REQUIRED。未加载 chunk 使用 DEFERRED/NEEDS_RECONCILE，不得直接改成 REBUILD_REQUIRED。
checkpoint.state 只允许 SETTLED、UNSETTLED、DEFERRED；只有 SETTLED 且 usageSequence/usageAmount 与 usageTankSnapshot 一致时才可按 C 重建 U/P。
projectionPending=false 时 pendingProjectionSequence 和 pendingProjectionReason 必须为空；LOCOMOTIVE 在内部 chunk 未加载时可设置 projectionPending=true，并记录本次 canonical sequence 和固定原因代码，直到加载后的 collect/settle/project/checkpoint 完成后清除。
faultPolicy 只允许 NONE、UNCONFIRMED_CONSUMPTION_REBUILD；后者表示损坏对象导致存在无法确认的 consumption，必须保持人工重建/存档重建门，不能猜测 amount 或再次扣账。usageTankSnapshot.projectionSequence 和 proxyLedger[deviceId].projectionSequence 只在对应 world 写入成功后推进，不能因计划投影或部分失败提前推进。
requestLedger 只保留当前实现声明的有限幂等窗口；同一 sessionNonce/entryPoint/requestId 重试必须返回已记录结果而不再次扣源，未知或过期 requestKey 重新走服务端阶段校验。它不是水量余额，confirmed 字段只记录审计结果。
requestLedger.status 只允许当前事务声明的 COMMITTED、REJECTED、REBUILD_REQUIRED；未提交的 PLANNED 状态只存在服务端内存事务中，不得作为可消费余额持久化。
当前 autoRefill 记录必须存在且为 DISABLED：providerId、channelId、objectToken、objectFingerprint 为空，confirmedDelta=0，sequence=0；任何非空 provider、非零 delta、未知 channel 或未知字段都直接拒绝，而不是降级到当前实现。

旧的 sharedAmount、旧 centralIdentity/centralSnapshot、以 layout.barrel 为 central 的记录、旧 registry 的单一 fixture token、无 proxy identity 的记录和旧 previousSnapshot 结构都不再读取。
当前 schema 不保存 object index；任何依赖持久 object index 的记录都视为过期结构并触发 SAVE_REBUILD_REQUIRED。加载、重连和后置证明始终按 usageTank/proxy identity、坐标、token 和 fingerprint 重新解析当前 objects。

### 8.2 必须 bump 的 schema 域

实施时同一变更必须同步 bump 当前代码声明的以下 schema/版本域，不能用 alias 或兼容分支掩盖旧结构：

- RV_Constants.lua 当前声明的 TECH_VERSION、MANIFEST_SCHEMA_VERSION、MAP_SCHEMA_VERSION、RV_RECORD_SCHEMA_VERSION、RV_RELATION_SCHEMA_VERSION、BOUNDARY_SCHEMA_VERSION、LAYOUT_SCHEMA_VERSION、UTILITY_STORE_SCHEMA_VERSION、UTILITY_WATER_SCHEMA_VERSION、UTILITY_POWER_SCHEMA_VERSION、BITMAP_SCHEMA_VERSION 和 BITMAP_VERSION；
- manifest/技术版本和 SAVE_REBUILD_REQUIRED 门；
- generation、layout、bitmap 和 boundary geometry；
- RV mapping 与 shell ledger；
- canonicalTank amount/checkpoint/projectionPending/faultPolicy、usageTankIdentity/usageTankSnapshot/projectionSequence、proxy ledger/projectionSequence、manual request identity 和未来 autoRefill provider/channel schema；
- 当前对象 tag/fingerprint 版本；
- 若 DEVICE_CATALOG、runtimeTestEnabled 或 runtimeValidated 的字段契约变化，则对应 registry/test schema 也必须 bump。

具体数值由现有常量一次性递增并只保留新值；本计划不重新核验 Java 版本，也不允许实现时保留 old/new fallback、字段 alias 或自动转换。

### 8.3 旧存档处理

旧 manifest、旧 bitmap、旧 generation、旧 mapping、旧 shell ledger、旧 visible barrel、旧 water registry、旧 sharedAmount、旧 centralIdentity/centralSnapshot、缺失 canonicalTank/usageTankIdentity、autoRefill 非 DISABLED、旧 proxy/central tag、当前 record 的部分写入或不可解释的 sequence 冲突全部直接显示 SAVE_REBUILD_REQUIRED，拒绝当前 RV 操作。当前对象的缺失、重复、组件缺失或 identity 错误只有在预期 square 已权威加载并完成第 9.2 节审计后才触发该门；暂未加载使用 DEFERRED/NEEDS_RECONCILE/QUARANTINE_PENDING。服务端不得传送玩家、生成 geometry、删除旧对象、自动清理、自动改名或迁移字段。用户必须手动删除测试存档并重建。

## 9. 生成、生命周期和失败恢复

### 9.1 生成与布局

- 从 RV_Constants.lua/RV_Layout.lua 移除屋顶可见 RAIN_COLLECTOR_OFFSET、可见 barrel sprite 和 barrel role。
- 从 RV_Server.lua 移除可见 rain barrel 生成、SRainBarrelSystem bridge、雨水桶全局对象和依赖 barrel sprite 的生成前置条件。
- 生成 shell 后先初始化 current canonicalTank（fresh amount=0），再在当前 generation 的确定性 usageTankOffset 创建隐藏 usage tank 并完成 FluidContainer/identity/postcondition；没有成功 canonical record 或 usage tank 就回滚本次 RV generation。
- registry 为空时不预生成 fixture proxy；只有连接事务成功后才创建代理。
- bitmap/manifest/layout 的新版本必须与“无可见屋顶桶、存在 usage tank offset、canonicalTank 不占 world object、代理按 fixture z+1”一致。

### 9.2 fixture 移动、拆除和重复对象

- 相关 chunk 未加载时，规则优先级高于 schema 的“缺失对象”判断：只标记 NEEDS_RECONCILE/DEFERRED；故障路径标记 QUARANTINE_PENDING。不能因为暂时 nil square 认定缺失、投影 C、建立新 baseline、删除对象或修改 canonicalTank。
- 只有预期 square 已由服务端权威加载，且审计证明 proxy/usage tank 缺失、重复、坐标错误、组件缺失或 identity 错误，才进入 dry quarantine/SUSPENDED/REBUILD_REQUIRED；正常 record/world object 加载先后差异不是 partial write。
- 服务端对象事件或定期审计发现 fixture token/fingerprint、坐标或 generation 改变时，正常已加载路径必须先调用 flushBeforeOverwrite；如果同一审计确认 usage/proxy/component 已损坏或缺失，则转入 9.2.1 的 damaged-object emergency quarantine。拆除本身不改变 canonicalTank，但此前已发生的 consumption 必须按对应路径结算，然后等待新的显式连接请求。

#### 9.2.1 实际停供的 dry quarantine

对已加载且 current identity 已确认的 fixture/proxy，停供不是只改 registry/state，并明确区分正常拆除和损坏对象紧急隔离：

- **正常 detach/manual detach**：先完整调用 `flushBeforeOverwrite`，收集全部可见 proxy delta 并 settle U→C；确认该 consumption settlement 提交后，再进入 accounting suppression，撤销 fixture external source 并清空/移除 proxy。拆除本身不改变 C，且隔离产生的变化不计为 consumption。
- **damaged-object emergency quarantine**：usage tank、proxy component 或相关对象损坏/缺失而无法完整 flush 时，完整结算不是停供前提。先在 executeOperation 阶段把目标从 ACTIVE projection set 排除；在 accounting suppression 下尽力读取 identity 明确且组件可读的 proxy delta，并仅结算实际可确认的 U→C 数据。U、proxy 或 baseline 缺失时立即停止等待，不能猜测未确认的 amount，也不能以“flush 失败”为由继续供水。

紧急路径的实际动作固定为：撤销 fixture external source 并发送原版 object change；若仍可能被原版发现，则将身份明确的 current proxy amount 与 capacity 置 0 或移除 current proxy，使 FindExternalWaterSource 不能继续供水。suppression guard 内由清空/移除产生的 delta 不计为玩家 consumption，也不得重新写回 C；已经确认并提交到 C 的 settlement 保留，未确认部分记录为 `faultPolicy=UNCONFIRMED_CONSUMPTION_REBUILD`，同时将该 RV 的 canonical/state 置于 REBUILD_REQUIRED，进入人工/存档重建处理，不能在重试时重复扣账或继续接受补水/用水操作。

只有后置证明 fixture 找不到该 proxy 且代理不可供水，才将 registry 标记 SUSPENDED；如果后置证明失败但 current identity/对象无法恢复，则标记 REBUILD_REQUIRED。任何撤销、清空、移除或后置证明失败都保持/重试 dry quarantine，并向服务端日志报告；不能假装已停供。相关 chunk 未加载时只标记 QUARANTINE_PENDING，chunk 加载后在任何原版用水、普通 flush、projection 或新 baseline 前优先执行紧急隔离流程。

RV rebuild 只删除本次 current generation 且 identity 完全匹配的 usage tank/proxy；仅对本次尚未提交的结构记录执行回滚或重建。已经提交的 canonical consumption sequence/amount 不因 rebuild 清理而回滚，任何旧 generation/未知 tag 都转为 rebuild required，不跨 generation 清理。

### 9.3 加载、重启、重连和卸载

- world/chunk load、服务端重启和客户端重连时，先读取 current canonicalTank/schema，但不因 usage/proxy 尚未加载就投影或建立 baseline；若存在 QUARANTINE_PENDING，先执行第 9.2.1 节的 emergency quarantine，再按第 6.3 节区分 checkpoint 已结算、存在未结算 delta 和 DEFERRED。
- 预期 square 未权威加载时保持 NEEDS_RECONCILE/DEFERRED，不能自动 REBUILD_REQUIRED；确认 square/object 到齐后，先读取旧 U/P 与旧 baselines，collect 全部 proxy delta，settle 旧 U delta 到最新 C，再 project C→U→P，最后更新 baseline/checkpoint 并清除 projectionPending、pendingProjectionSequence 和 pendingProjectionReason。
- canonicalTank record 的恢复先后不构成自动 checkpoint；即使 checkpoint sequence/amount 匹配，也必须先完成第 6.3 节的当前已加载 U/P 与 baseline 检查；只有确认没有 pending delta、checkpoint 已 SETTLED 且 projection 条件满足时，才可按 C 重建 usage tank。不能把客户端缓存或 world FluidContainer amount 写回 canonical。
- 断线不改变 registry；服务端继续按 loaded objects 结算，重连后只同步当前状态；涉及未加载 chunk 的设备维持 DEFERRED，不作缺失清理。
- 模组卸载前必须有明确的服务端 teardown 工具/流程；未执行 teardown 时，隐藏对象可能作为带模组 sprite/component 的残留，系统必须拒绝继续使用并提示恢复/重建。不能在模组缺失时自动删除未知对象。
- 所有结构性操作使用一次 current transaction sequence；canonicalTank 初始化、usage tank/代理创建、标记、注册、同步任一步骤失败都回滚本次操作尚未提交的新 record/对象和 registry，不回滚其他 RV，也不回滚此前已提交的 consumption settlement。部分投影按 6.2.1 保留成功项并进入 pending/reconcile/quarantine，不伪装成完整 checkpoint。

## 10. 文件级改造范围

本文件规定本次最小改动范围；当前实现已覆盖：

| 文件 | 计划改造 |
| --- | --- |
| RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RV_Constants.lua | 新 canonicalTank/usageTank/proxy role、hidden sprite/offset、容量和所有 current-only schema bump；移除 visible barrel 契约，并声明 autoRefill=DISABLED。 |
| RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RV_Layout.lua | 删除 roof barrel layout，增加确定性 usage tank offset，保持 shell/bitmap 当前契约一致。 |
| RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_Server.lua | 删除 visible rain barrel/SRainBarrelSystem 生成，加入 canonicalTank 初始化、usage tank 创建、同步和 generation 回滚。 |
| RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_ServerWorld.lua | 只允许当前 identity 的 usage tank/proxy 生命周期清理、flushBeforeOverwrite 和 dry quarantine；canonicalTank 记录按 current transaction 管理，旧对象 fail-closed。 |
| RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RV_UtilityCatalog.lua | 将 catalog 改为显示/测试元数据；用 waterPiped/canBeWaterPiped 能力谓词和明确 chemical deny 替换容量/source/name gate。 |
| RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_UtilityStore.lua | 实现本文件第 8 节的 canonicalTank/usageTank/proxy/requestLedger/autoRefill exact current schema、identity/fingerprint、strict gate 和 SAVE_REBUILD_REQUIRED。 |
| RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_UtilityWater.lua | usage tank/proxy 创建、连接 postcondition、flushBeforeOverwrite、逐对象 projection commit、OnWaterAmountChange 优先、tick 兜底、低频 usage→canonical settlement、canonical→usage→proxy projection、manual ADD_WATER、deferred projection、normal detach、damaged-object emergency quarantine 和结构性回滚域。 |
| RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_UtilityServer.lua | 服务端命令验证、INTERNAL/LOCOMOTIVE entryPoint 的玩家/机车/RV mapping guard、库存 source 重解析、planned/confirmed ADD_WATER、projectionPending、faultPolicy 和 normal/emergency dry quarantine；客户端参数不可信。 |
| RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_UtilityContextMenu.lua | 只显示服务端能力候选并提交意图；不要求预先找到 external source。 |
| RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_UtilityClient.lua | 仅负责隐藏表现、状态显示、同步反馈；不写对象或 amount。 |
| RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua 及初始化入口 | 注册当前事件/同步顺序，确保 canonicalTank、usage tank 和 proxy 先于使用动作可见，并保持 autoRefill disabled。 |
| RailroaderRVTest/tests/ 或现有静态断言位置 | 增加能力谓词、chemical deny、schema exact、visible barrel removal、proxy identity、ledger safety 和客户端 hint 不可信断言。 |

当前 HEAD 中“要求已有 external source 才允许 native device”的中途能力门控不是最终实现；实施时必须整体替换为本文件第 3 节资格 + 第 5 节连接后置证明。当前旧 sharedAmount 镜像、以 fixture FluidContainer 容量为资格、visible barrel central、按 fixture downward delta 直接改共享余额的路径均不得保留为并行 fallback。电力模块不因本改造删除或改写。

## 11. 实施与验证阶段

顺序固定为：

1. **直接实现**：按本计划一次性替换旧 water path、schema、generation、canonicalTank/usage tank/proxy lifecycle 和服务端 guard；不做 Java 版本复核循环，不下载或修改参考模组。
2. **静态测试**：执行 Lua/JSON 语法与现有静态回归断言，检查没有 visible barrel/SRainBarrelSystem/旧 sharedAmount/旧来源字段/source-required gate/客户端写入/旧 schema fallback，并确认 flushBeforeOverwrite、恢复优先级、逐对象 projection commit、faultPolicy、normal/emergency quarantine、checkpoint、双 entryPoint 和 DISABLED autoRefill 契约存在。
3. **修复**：只修复静态测试实际暴露的问题，保持 current-only 和服务端权威；不先做额外 preflight。
4. **唯一整体运行时测试**：从项目根目录直接运行可见控制台的 python testserver/run_test.py。不拆分客户端/服务器，不隐藏窗口，不用手工替代入口。服务器启动应由整体脚本呈现 *** SERVER STARTED *** 和可见客户端 PID；随后由用户执行游戏内操作并反馈。

已执行“直接实现 → 静态测试 → 修复”阶段；整体运行时测试仍需由主 agent 在用户可操作客户端时按第 4 步启动，不能以静态检查替代。

## 12. 运行时矩阵

整体测试至少覆盖下表；SP、host MP 和 dedicated MP 都要执行关键项，专用服务器还要覆盖重连/重启。

| 类别 | SP | Host MP | Dedicated MP | 验收重点 |
| --- | --- | --- | --- | --- |
| 新档生成 | 是 | 是 | 是 | 无可见屋顶桶、无 SRainBarrelSystem 对象；canonicalTank 初始 0，只有一个隐藏 usage tank。 |
| 原生资格 | 是 | 是 | 是 | 原生水槽、浴缸、普通马桶可见候选；化学马桶明确拒绝；未知名称但有 waterPiped/canBeWaterPiped 的模组 fixture 可见。 |
| 连接事务 | 是 | 是 | 是 | 手中工具/权限/范围、旧 token、错误 RV、重复连接和客户端伪造坐标均按服务端结果处理；失败无半提交。 |
| 连接后置证明 | 是 | 是 | 是 | fixture external source 重新解析到该代理；代理位于 fixture 正上方 3x3；连接前 source nil 不阻塞。 |
| 原生取水/饮用 | 是 | 是 | 是 | 原版动作扣 proxy，事件/tick 先结算 usage tank，低频 settlement 再减少 canonicalTank 并重新投影；客户端不能直接改 amount。 |
| 手动 ADD_WATER / INTERNAL | 是 | 是 | 是 | 服务端确认 inside relation/bitmap/内部范围，planned→confirmed 先扣允许的 clean/tainted water source 再加 canonicalTank，已加载路径必须 flush 后投影，幂等重试不重复扣源。 |
| 手动 ADD_WATER / LOCOMOTIVE | 是 | 是 | 是 | 服务端解析当前机车、固定玩家范围和恰好一个 current RV mapping；内部 chunk 未加载也可确认 C，设置 projectionPending/sequence/reason，不写 world object。 |
| usage settlement / 崩溃恢复 | 是 | 是 | 是 | 相关 chunk 已加载时先检查当前 U/P 与 baselines；checkpoint 只证明历史结算完成，任何 pending delta 先 collect/settle，确认无 pending 后才可按 C 恢复，world FluidContainer 不能覆盖权威。 |
| 部分投影失败与重试 | 是 | 是 | 是 | C settlement/consumed sequence 一旦提交不回滚、不重扣；U/proxy 逐项确认，成功项保留，失败项 pending/reconcile/quarantine，重试只处理未完成项，完整 checkpoint 延后。 |
| deferred projection | 否 | 是 | 是 | 示例 C=100/U=90，机车旁 +50 后 C=150/U=90/pending；加载先结算旧 10 得 C=140，再投影 U/P=140。 |
| flushBeforeOverwrite | 是 | 是 | 是 | connect/add/detach/scheduled sync/recovery/normal quarantine 均走同一 guard；damaged-object emergency 使用独立紧急分支；覆盖 U/P 前不丢 pending delta，不依赖另一个 tick。 |
| auto-refill channel | 是 | 是 | 是 | provider/channel 明确为 DISABLED；不生成、扫描、结算或 fallback 雨水桶，未知 provider 拒绝。 |
| 多 fixture 并发 | 是 | 是 | 是 | 不产生额外 canonical；允许小量/极端误差，但 canonicalTank 不负、无跨 RV 泄漏和重复代理。 |
| 水量/来源/容量 | 是 | 是 | 是 | 1000.0 契约、clean/tainted water source 均可合法补水，非水 source 拒绝，canonical 不记录 source kind，容量边界和 overflow 不凭空增水。 |
| 输入动作阶段 | 是 | 是 | 是 | 第一阶段输入锁定；未实现的 item-to-fixture 路径明确拒绝/记录，不伪报成功。 |
| 停水停电 | 是 | 是 | 是 | 原版停水判断、RV canonicalTank 存水、发电机开关互不越权；不生成自然雨水。 |
| 移动/拆除/干式隔离 | 是 | 是 | 是 | normal detach 先完整 flush；damaged-object emergency 不以完整 flush 为前提，先排除 ACTIVE projection、尽力结算可确认数据并立即撤销 external/清空/移除 proxy；隔离变化不计 consumption，后置证明成功才 SUSPENDED/REBUILD_REQUIRED。 |
| chunk/重启/重连 | 否 | 是 | 是 | 未加载先 DEFERRED/NEEDS_RECONCILE/QUARANTINE_PENDING；加载确认对象后先 reconcile 旧 delta，再投影并清 projectionPending。 |
| RV rebuild | 否 | 是 | 是 | 仅删除当前 generation 完全匹配对象；旧/未知对象触发 rebuild required。 |
| schema 门 | 是 | 是 | 是 | 缺失/过期/重复/旧 visible barrel/旧 sharedAmount 一律 SAVE_REBUILD_REQUIRED，无迁移或自动清理。 |
| 恶意客户端 | 否 | 是 | 是 | 伪造坐标、amount、deviceType、RV id、权限、阶段、item/source hint、重复 request 全部以服务端重解析为准。 |
| 电力回归 | 是 | 是 | 是 | 现有 native generator、供电范围、燃料和同步行为不因 water 改造回归。 |

## 13. 日志、性能与验收标准

### 13.1 安全和功能验收

- fresh current-schema RV 的 canonicalTank 唯一且初始 amount=0；每个 RV 最多一个匹配 usage tank，每个 active fixture 最多一个匹配 proxy。
- 任何时刻 canonicalTank amount >= 0 且 <= capacity；usage tank/proxy amount 不可被用来创建第二份余额或覆盖 canonicalTank。
- usage tank/proxy 始终为干净 Water；manual/未来 source 只允许 clean Water 或 tainted water，非水 source 拒绝，canonicalTank 不记录 source kind。
- 普通原生 fixture 首次连接由能力标志和 chemical deny 决定；已登记设备持续验证不要求 canBeWaterPiped 仍为 true，并依赖稳定 identity/token/fingerprint。
- manual ADD_WATER 的 INTERNAL/LOCOMOTIVE 双入口均只按服务端 confirmed source delta 增加 canonicalTank；失败补偿、entryPoint、幂等 requestLedger 和后续 projection 均可审计。
- 所有正常已加载覆盖路径都经过 flushBeforeOverwrite：collect 全部 proxy→settle U→C→执行操作→C→U→proxy；damaged-object emergency quarantine 使用明确的 suppression/隔离分支，不能用另一个 tick 代替正常 collection，也不能以 flush 失败为由继续供水。
- 恢复时 checkpoint 匹配只证明上次结算完成；相关 chunk 已加载时必须先检查当前 U/P 与 baselines，任何 pending delta 都优先 collect/settle，只有明确无 pending 才能直接按 C 投影。
- consumption settlement 与 projection commit 边界明确：已提交 C/consumed sequence 永不因后续投影失败回滚或重扣；U 和各 proxy 逐项确认，失败项进入 pending/reconcile/quarantine，完整 checkpoint 只在全部必要投影成功后发布。
- 合法 deferred projection 不被当作 schema 损坏：LOCOMOTIVE 未加载可保存 C+projectionPending；加载后先 reconcile 旧 consumption，再投影并清 pending。
- normal dry quarantine/detach 先 flush；damaged-object emergency quarantine 不以完整 flush 为前提，尽力记录可确认 delta 后在 suppression 下立即停供；无法确认的 consumption 设 faultPolicy 并将该 RV 置于 REBUILD_REQUIRED/人工重建门，隔离清空不计玩家 consumption，只有 fixture 后置证明不再找到 proxy 才进入 SUSPENDED/REBUILD_REQUIRED。
- 结构操作回滚只覆盖本次尚未提交的结构写入，不回滚此前已提交的 consumption settlement；部分投影保留成功项并只重试未完成项。
- autoRefill provider/channel 当前为 DISABLED；未知 provider、雨水桶和直接 proxy/usage 输入全部拒绝。
- 所有 record/world 变化、同步、删除和回滚由服务端完成；客户端只产生意图。
- 连接失败、对象移动、fixture 拆除、proxy 缺失/重复、schema 失败均不留下半提交 current state；chunk 暂不可见只产生带 sequence 的合法 DEFERRED/NEEDS_RECONCILE/QUARANTINE_PENDING，不被伪装成完成或缺失。
- 旧数据不迁移、不 alias、不 fallback、不自动删改。

### 13.2 日志和性能阈值

- utility water path 在成功测试中不得产生 ERROR、stack trace、无限重试或由本模组触发的 PlayerUpdateReliable connection is null；原版已有的网络噪声须能从模组日志区分。
- 服务端 tick 复杂度为当前 RV 已注册且已加载 proxy 数量的 O(n)，禁止每 tick 扫描 20x40 地图或全世界对象。
- 单次事件结算最多一次 usage sync；低频 settlement 最多一次 canonical record/usage sync，加上实际变化 proxy 的一次同步；不得出现 canonical→usage→proxy→event 的无界循环。日志应记录 collect count、settled usage sequence、projection sequence 和 skipped/deferred 状态。
- 部分投影日志必须逐项记录 usage/proxy projection sequence、成功/失败状态、pending/reconcile/quarantine 原因和重试目标；不得把已提交的 consumption 记录成回滚或重复结算。
- 反复 LoadGridsquare、重连、重启和 rebuild 100 次后，当前 canonicalTank/usage tank/proxy identity 不得重复；合法 projectionPending、NEEDS_RECONCILE、DEFERRED 和 QUARANTINE_PENDING 必须有明确日志，不得被误报为 partial write。
- 普通单次原生动作的 canonical/usage drift 目标不超过 max(0.01, 0.001 * capacity)；极端并发可超过该目标，但必须满足第 6.5 节的绝对安全边界并记录 sequence/原因。
- dry quarantine 日志必须区分 flush consumption、suppressed clear、external revoke、postcondition result 和 retry；不得把 suppression 产生的 delta 计入玩家 consumption。
- 20x40 内部不应因 water audit 造成可见长帧；若整体脚本能提供计时，服务端单 RV 结算应报告 proxy 数量、事件数、tick 兜底次数和同步数。

## 14. 推荐路线、备选路线和未决点

推荐路线是“服务端 canonicalTank record + 隐藏 usage tank IsoObject + 每 fixture 隐藏 IsoThumpable + 原版 3x3 后置证明 + OnWaterAmountChange 优先/tick 兜底/低频 settlement”。它保留原生动作和原生能力判定，避免改引擎全局，也符合当前服务端权威/current-only 架构。

可接受的备选是把 usage tank 放在同一 RV 的另一个确定性隐藏 square，前提是它仍只是 canonicalTank 的工作镜像，且不被原版 external-source 搜索误认；不接受把 canonicalTank 伪装成 world FluidContainer、可见 roof barrel 或 SRainBarrelSystem 容器。

不推荐的路线包括：继续用 sharedAmount 作为 canonical、把 world FluidContainer 当最终权威、复制每个 fixture 的 amount 并求和、按容量/名称白名单、扩大原版 3x3、只在客户端创建代理、在连接前强制 FindExternalWaterSource、把 ADD_WATER 写入 proxy/usage tank、启用未登记 auto-refill、保留旧 schema fallback，或复制 LG 的跨建筑/多桶/管线实现。

未决但必须在整体运行时测试中确认的事项：

1. 当前 B42.20 运行时创建带 FluidContainer 的 usage tank IsoObject 的最小构造和 sprite rebind 顺序；
2. OnWaterAmountChange 在所有目标原生动作上的具体触发对象（fixture 或 proxy），以及直接 FluidContainer transfer 的漏事件边界；
3. canonicalTank checkpoint、usage snapshot、pendingProjectionSequence 和 requestLedger 在服务端重启/partial save 时的实际恢复分类；
4. INTERNAL/LOCOMOTIVE 两个 ADD_WATER entryPoint 的实际 inside/bitmap、机车 mapping/权限和 source readback/补偿边界；
5. flushBeforeOverwrite 在多 fixture、detach、scheduled sync、deferred projection 和 dry quarantine 中的事件顺序；
6. 部分 U/proxy projection 失败后的逐项保留、重试和 checkpoint 发布边界，以及 damaged-object emergency quarantine 在 U/组件缺失时的 faultPolicy 与实际停供；
7. 代理/usage input lock 对所有目标原生 UI 的实际表现，以及 stable fingerprint 排除可变字段后对对象替换的识别；
8. 多客户端同时动作时引擎事件顺序和可接受 drift；
9. 模组卸载/缺失时残留对象的用户可恢复流程。

这些是运行时验证项，不得在静态计划中伪造为已解决或已验证。

## 15. 当前交付状态

当前交付已实施 Lua、Python 静态断言、README 和相关 agent.md 改动；未修改、迁移或自动清理任何存档，未启动服务器，未运行 `python testserver/run_test.py`，因此尚未完成运行时验证。静态测试通过不代表水电在游戏内、SP、Host MP 或 Dedicated MP 中已验证；需按第 12 节矩阵由用户操作客户端并反馈。

当前代码还明确执行结构事务隔离：Store 读写使用 working-copy/root snapshot，commit/transmit
失败恢复本次 root，fresh record 不先写入 ModData；usage tank 初始化显式复用该 working
record。`ensureUsageTank` 对 squareObject 的 `invalid` 与 `duplicate` 同样立即进入
`SAVE_REBUILD_REQUIRED`，不会在旧 role/schema/barrel tag 旁建替代对象；hidden object
创建的 attach/component/完整包失败路径按方格实际附着状态回滚，无法证明清理时 fail-closed。
`flushBeforeOverwrite` 另行传递 commit-failure 标记；CONNECT/DETACH/settlement 在结构清理
后尽力写入当前 record 的 `REBUILD_REQUIRED` lock，避免未确认的 world delta 被下一次操作
重复结算；已经成功提交的 consumption settlement 不走该补偿路径。

当前对象审计进一步收紧为证据驱动的 retired-role 门：只有历史精确 role
`rain_barrel` 才会从 generic `RailroaderRVTest` namespace 触发旧对象拒绝；当前生成 sink
以及 floor/roof/counter/generator 的 generic tags 会被忽略，不会阻止合法 utility 创建或
连接。`Store.getRecord` 现在显式返回本次 working record 是否 fresh；fresh record 在其
usage-tank square 发现任意 current/retired utility tank evidence 时拒绝并提示重建，不能
采纳、迁移或删除既有对象。CONNECT 目标 proxy square 的 current/duplicate/orphan object
只有在 registry 与 proxyLedger 均按坐标、token、fingerprint 完整对应时才算已登记冲突；
否则返回 `SAVE_REBUILD_REQUIRED`，保留未知世界对象不作清理。
对于 persisted current record，expected usage tank 缺失同样直接返回
`SAVE_REBUILD_REQUIRED`；计划 9.3 所需的 loaded U/P、baseline、pending delta 与 checkpoint
恢复证明尚未由独立 recovery transaction 提供前，不从 canonical amount 自动重建或创建替代
对象。只有 fresh 空容器在目标 square 无任何 utility tank evidence 时允许创建第一个 usage tank。
