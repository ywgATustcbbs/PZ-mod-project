# BoundaryGuard 模块分析

## 分析前提、范围与完成条件

- **范围**：只读分析 `contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/BoundaryGuard/` 中全部 4 个 Lua 文件。对目录外代码只做定向调用点搜索和少量上下文读取，用来辨认接口与内部状态耦合；没有把目录外文件纳入逐函数审阅。
- **假设**：目录边界代表一次子模块分析单元；`BoundaryServer.lua` 是服务入口，Geometry、Sweep、BoundaryValidation 是互相协作的组件。函数输入和输出按源码路径说明，不推断运行时环境一定提供的 API。
- **成功条件**：列齐 4 个文件及扫描到的具名、赋值、嵌套、匿名回调函数；逐项说明参数、返回值/副作用、本模块语义和当前是否必需；给出跨模块复用、拆分、数据访问和接口收益判断，并附可复核的源码行号。
- **验证方法**：递归文件清单；`rg` 函数定义扫描；对每个文件按行号通读并交叉检查函数调用、上下文注入和边界状态字段；完成后核对报告章节和文件/函数清单。未运行游戏、服务器或一键运行时测试，未修改任何源码。

## 文件与模块职责

| 文件 | 模块职责 | 结构判断 |
|---|---|---|
| `RV_BoundaryServer.lua` | 服务门面：拒绝纯客户端装载、建立共享 `Boundary` 表、建立组件上下文并装配几何、对象保护和 tick 扫描组件。 | 很薄的装配层，边界明确。源码第 54 行装配的 Objects 实现在 `DemolitionProtection/`，不属于本次逐函数分析范围。 |
| `RV_BoundaryServer_Geometry.lua` | 编码/验证边界记录、持有已登记几何缓存、与 RailroaderServer 的当前映射验证衔接，并提供玩家状态、转场租约和纠正位置上下文。 | 最大文件，承载记录/缓存与玩家状态/纠正两条相邻但可区分的职责。 |
| `RV_BoundaryServer_Sweep.lua` | 每 tick 采样在线玩家，处理正常跟踪和受限的未跟踪玩家探测，再把活跃 RV 范围交给修复队列。 | 调度层单一、独立性较好。 |
| `RV_RailroaderServer_BoundaryValidation.lua` | RailroaderServer 适配器里的玩家关系、当前 schema、manifest、几何一致性验证缓存及预热事件。 | 从 Boundary 几何服务中分离合理；当前通过 `Adapter`、`Boundary` 多个下划线字段共享状态。 |

### 装载与数据流

`RV_BoundaryServer.lua:21-23` 在纯客户端进程返回空表；服务侧建立 `ctx` 后依次装载 Geometry、DemolitionProtection Objects、Sweep（第 43-55 行）。Geometry 将安全调用、身份、边界键、状态和 bitmap 处理函数放入该局部 `ctx`，供 Objects 和 Sweep 复用（`RV_BoundaryServer_Geometry.lua:773-786`）。BoundaryValidation 则由 RVMapping 的 `RV_RailroaderServer_Mapping.lua:227-244` 用另一份 adapter 上下文装载；它不是 `BoundaryServer.lua` 的 Geometry `ctx`。

常规路径是 GenerationFlow 以 `Boundary.makeBoundary` 形成持久记录（`Construction/RV_Server_GenerationFlow.lua:249-257`），DevSaveSchemaGate/映射流程再用 `Boundary.registerGeneration` 登记。玩家 guard 通过 `boundaryForPlayer` 调用 Mapping 注入的验证器；Sweep 的 `onTick` 以 `updatePlayer` 取得活跃边界，并调用 repair tick 钩子。服务 tick 调度见 `Core/RV_Server_Commands.lua:49-60`。

### 装配断点：Sweep 所需 `ctx.updatePlayer` 无源码提供者

- **静态可证事实**：门面创建 `ctx` 时只含 `processIsServer`、`Bitmap`、`Boundary`、`C`、`Core`、`OWNER`、`exactKeys`（`RV_BoundaryServer.lua:43-51`），装配顺序为 Geometry → DemolitionProtection Objects → Sweep（`L53-L55`）。Geometry 最后对 `ctx` 的赋值清单位于 `RV_BoundaryServer_Geometry.lua:773-786`，不包含 `updatePlayer`。对整个 `media/lua` 搜索 `updatePlayer`，唯一命中是 Sweep `L10` 读取 `ctx.updatePlayer` 和 `L75/L103` 两处调用；目录外已装载的 Objects 文件也没有 `ctx.updatePlayer` 赋值或导出。因此在当前可见源码装配路径中，Sweep 装载时 `local updatePlayer = ctx.updatePlayer` 捕获到 `nil`。
- **条件性运行时推断**：若一次 `Boundary.onTick` 进入已跟踪/区域内玩家分支，或冷态区域外候选探测分支，分别会在 Sweep `L75` 或 `L103` 调用这个 `nil`，Lua 将抛出调用错误；入口在 `Core/RV_Server_Commands.lua:58-59` 由 `pcall(Boundary.onTick)` 包裹，推测会截断本轮 Boundary sweep 并由外层吞掉错误，其他 server tick 后续步骤仍可能继续。此处没有进行运行时复现，故为静态调用链推断，不是实测结论。
- **分析状态**：这是影响 Boundary tick 主路径的高优先级未解决集成问题。需要负责实现的工作者确认 `updatePlayer` 预期提供者/接口后修复；本报告任务只读，不在此补实现。

## 函数逐项说明

以下每项都给出定义起始行及所在函数范围；`return function(ctx)` 是被 `require` 后调用的工厂，不是游戏事件回调。这里的“必要”表示对当前目录声明的功能是否有静态调用/职责依据，不等于运行时验证结论。

### `RV_BoundaryServer.lua`

- **`processIsClient()`（L9-L13）**：无参数。安全调用全局 `isClient`；返回布尔值，仅严格 `true` 视为客户端，缺 API 或报错时为 `false`。用于决定是否提前退出；对避免客户端建立 server authority 状态必需。
- **`processIsServer()`（L15-L19）**：无参数。安全调用全局 `isServer`；API 缺失时按服务端处理，异常/非真值为 `false`。用于客户端门控和注入 Geometry；必需，但缺 API 默认服务端是显式的 fail-open 选择，需依赖游戏装载环境保证。

### `RV_BoundaryServer_Geometry.lua`

- **工厂 `function(ctx)`（L2-L787）**：输入门面准备的依赖对象；副作用是向 `Boundary` 安装边界、缓存、身份、转场方法，并把通用 helper 放回 `ctx`；没有显式返回值。必需的组件装配入口。
- **`number(value)`（L17-L25）**：把数字、数字字符串或可用 `+ 0` 转成 number；转换失败返回 `nil`。供几何字段标准化，且导出给 Objects；必需。
- **匿名转换回调 `function()`（L21）**：无参数，返回 `value + 0`，由 `pcall` 隔离 Lua/Java 转换异常；仅是 `number` 的保护壳，不应独立提取。
- **`integer(value)`（L27-L31）**：复用 `number`，只接受整数，失败返回 `nil`。跨记录、坐标、generation 校验的基础 helper；必需且导出给 Objects 和 Sweep。
- **`finiteNumber(value)`（L33-L40）**：将 number 结果限制为有限值，拒绝 NaN 和正负无穷；返回有限数或 `nil`。玩家坐标验证必需。
- **`call(target, method, ...)`（L53-L60）**：输入对象、方法名和方法参数；保护调用对象方法，返回 `false, nil/错误` 或 `true, 最多四个返回值`。适配 Java 对象/API，是 Geometry 与 Objects 共用的基础 helper；必需并经 `ctx` 导出。
- **`callGlobal(name, ...)`（L62-L68）**：输入全局函数名与参数；通过 `_G` 找函数并以 `pcall` 调用，返回与 `call` 相同形态。用于玩家/格子/网络 API；必需并导出。
- **`succeeded(target, method, ...)`（L70-L73）**：包装 `call`，返回调用成功且第一结果不为 `false` 的布尔值。全目录搜索未发现调用，且未导出；当前不是必需代码，可能是遗留 helper。
- **`playerName(player)`（L75-L80）**：输入玩家；读取并转成非空用户名，缺失返回 `nil`。身份组成部分；必需。
- **`playerOnlineId(player)`（L82-L91）**：输入玩家；优先读非负 `getOnlineID()`，非服务进程才尝试 `getPlayerNum()`；服务侧无可靠 online ID 则返回 `nil`。避免在服务端将客户端编号当身份；必需。
- **`identity(player)`（L93-L99）**：输入玩家；返回 `{username, onlineId, key}`，key 为 `onlineId:username`，身份不完整则 `nil`。跨转场、缓存、build attribution 的稳定进程内身份；必需并导出。
- **`playerPosition(player)`（L101-L119）**：输入玩家；安全读取 x/y/z 并要求有限数；返回位置表及 `inRVRegion` 布尔值。region 按 Constants 的偏移、宽高槽数和 Z 范围计算；Sweep 用它筛选玩家，必需并导出。
- **`Boundary.diagnoseGuardState(player, knownIdentity, position, relation, record, reason)`（L121-L156）**：输入玩家、已校验身份（可选）、位置、映射 relation、RV record、拒绝原因；只对服务端、位置表和指定无效数据原因处理。每身份最多发一次 `INVALID_RV_DATA` 命令并打印服务端诊断，返回是否发送成功。用于将 schema/manifest/几何拒绝反馈给用户；当前验证提示必需。函数体未读取 `relation`、`record` 的内容，它们目前只是透传形参。
- **`playerCell(player)`（L158-L163）**：输入玩家；优先取玩家 cell，失败后尝试全局 cell；返回 cell 或 `nil`。纠正玩家前用于目标格加载验证；必需，当前通过 `ctx` 暴露但两个已装载子组件没有引用。
- **`square(cell, x, y, z)`（L165-L169）**：输入 cell 和格坐标；安全调用 `getGridSquare`，返回格对象或 `nil`。阻止向未加载位置发纠正；必需，供 Objects 和 Geometry 使用并导出。
- **`encodeShellEdges(source, rvId, generation, bitmapVersion)`（L171-L198）**：输入布局 shell-edge 表和记录身份；复制已知字段，规范化坐标/索引，并为每条边写入完整 RV 身份。返回新边表（坏输入返回空表）；避免持久数据保留共享布局引用，构建新记录必需。
- **`Boundary.makeBoundary(layout, rvId, generation)`（L202-L252）**：输入 layout、RV ID、generation；验证 bitmap、managed bounds 一致和当前 bitmap 版本，编码 bitmap/shellEdges，生成含 schema/identity/bounds 的持久边界记录；成功返回 record，失败返回 `nil, reason`。将运行时 layout 转成当前 schema 必需。
- **`decodeBoundary(boundary)`（L254-L271）**：输入持久/新建 boundary；依次尝试原表快照缓存、新建对象的 decoded bitmap，以及只在 `DevSaveSchemaGate.isValidating()` 阶段允许的 schema gate 解码。返回 bitmap、rvId、generation、bitmapVersion 或 `nil`。拒绝 runtime cache miss 重新解释旧数据，符合开发期 fail-closed 门；必需并导出给 Objects。
- **`boundaryKey(boundary)`（L272-L275）**：输入至少含身份字段的边界；返回 `rvId:generation:bitmapVersion` 字符串。作为缓存/登记键必需并导出。
- **`sameBoundaryManaged(left, right)`（L277-L289）**：输入两组 managed bounds；要求精确字段集合及整数值相同，返回布尔值。防止边界 bounds 与几何身份不一致，登记缓存比较必需。
- **`sameBoundaryBitmap(left, right)`（L291-L307）**：输入两个 decoded bitmap；比对 bounds 和每层 walk/build bit 编码，返回布尔值。发现同身份不同几何，阻断旧 cache 复用；必需。
- **`sameBoundaryShellEdges(left, right)`（L309-L338）**：输入两个 edge map；要求 edge schema keys、字段、templateIndices 序列和条目数一致，返回布尔值。记录同身份几何变更的完整比较；必需。
- **`sameBoundaryGeometry(cached, boundary, bitmap)`（L344-L350）**：输入已登记缓存、当前记录和 decoded bitmap；合并调用 bounds、bitmap、shellEdges 比较，返回几何一致布尔值。防止缓存键复用到不同 geometry；必需。
- **`sameBoundary(left, right)`（L352-L355）**：输入两边界；只比较 `boundaryKey` 身份三元组，不比较实际 bitmap/edge 内容；返回布尔值。Objects 用它确认短时 build action 仍对应同一 generation（`DemolitionProtection/RV_BoundaryServer_Objects.lua:642-645`）；可用，但名称容易被误读为几何相等，应在接口文档明确身份相等语义。
- **赋值函数 `sourceCacheHit(boundary)`（L357-L391）**：输入 source boundary；命中弱键缓存后验证原始字段/子表引用和值仍一致，并要求注册表仍指向缓存对象；返回缓存注册对象或 `nil`。降低每 tick 的 schema/geometry 重验成本，同时拒绝原记录被原地改写；必需。
- **`rememberSourceBoundary(boundary, loaded)`（L393-L413）**：输入持久 source 记录和 decoded 注册对象；把其关键身份、边界、bitmap 子表引用和值保存到 weak-key source cache；无返回值。供上一个缓存校验使用，必需。
- **`geometryChanged()`（L415-L417）**：无参数；递增 `Boundary._geometryEpoch`，无显式返回。使 BoundaryValidation 的玩家 cache 感知登记几何变化；必需，但 epoch 是跨组件内部耦合点。
- **`loadedBoundary(boundary)`（L419-L459）**：输入记录；查 source/generated 缓存或在 schema validating 阶段 decode；检查当前 bitmap 版本，按身份键复用一致的登记对象，或清掉同键旧 geometry 并登记新对象；返回规范化 `{rvId,generation,bitmapVersion,bitmap,encoded,shellEdges}` 或 `nil`。这是所有 guard 消费几何前的统一准入点，必需。
- **`Boundary.registerGeneration(rvId, generation, boundary, record)`（L461-L479）**：输入身份、boundary、可选 record；要求已 load、调用身份匹配，若给 record 则其身份/version/边界引用也精确匹配；登记并返回 `true/false`。Generation 和 schema gate 建立 boundary 当前身份必需。
- **`Boundary.boundaryForPlayer(player, knownIdentity, deferValidationMiss, forceValidationRefresh, roofRefreshContextRead, roofRefreshGuardRead)`（L481-L518）**：输入玩家、可选预校验身份、缓存 miss 是否延后、是否强制 refresh、两种 RoofRefresh 授权读标记；调用 Adapter 验证器，然后核验 relation/identity/manifest 与 record 身份，最后经 `loadedBoundary` 取规范几何。成功返回 boundary、record、relation、identity、manifest；可返回 `nil, "validation-deferred"` 或 `nil`。guard、entry/roof 等从服务端映射取得唯一可信边界的核心接口；必需。
- **`stateFor(player, knownIdentity)`（L520-L531）**：输入玩家和可选身份；按 identity key 读取或建立 `Boundary._states` 状态，更新 `state.identity`；返回 state 或 `nil`。转场租约与纠正序号的创建点；必需。
- **`Boundary.addTransitionLifecycleListener(name, listener)`（L543-L550）**：输入唯一 listener 名及函数；校验后登记/覆盖监听函数，返回布尔值。为独立组件提供 transition 生命周期信号；当前 TemplateProtectionRepair 使用的扩展点，必需。
- **`notifyTransitionLifecycle(eventName, player, state)`（L552-L564）**：输入事件名、玩家、状态；逐 listener 安全调用并记录失败，不传播回调错误；无返回值。保证辅助 listener 不阻断 authoritative 转场；必需。
- **`Boundary.beginTransition(player, rvId, generation, token, kind, bitmapVersion)`（L566-L585）**：输入玩家、generation identity、token、可选类别/version；校验身份/version 后创建/更新状态、写入 token/kind/超时 tick、清除 refresh tick并发 `begin`；返回布尔值。Entry、RoofRefresh、Sentinel、Generation relocation 暂停普通 guard 的公开接口；必需。
- **`Boundary.completeTransition(player, token)`（L587-L596）**：输入玩家及可选 token；token 不匹配拒绝，否则清除 token/kind、写入两 tick 完成戳并通知 `complete`；返回布尔值。完成 relocation 的公开接口；必需。
- **`Boundary.extendTransition(player, token, untilTick)`（L604-L617）**：输入玩家、有效 token、新到期 tick；只允许相同活动 token，按 tick 顺序只延长不缩短租约；返回布尔值。RoofRefresh/长交易保留 guard 暂停状态所需；必需。
- **`Boundary.clearPlayer(player)`（L619-L627）**：输入玩家；删除 identity 对应状态并通知 `clear`，身份无法读取时仍返回 `true`。清理异常/失败转场状态的公开接口；必需。
- **`transitionActive(state)`（L629-L638）**：输入状态；token 存在且到期 tick 未过期则 `true`；过期/失效则清空租约、发 timeout 并返回 `false`。Sweep 与 guard 共用的 lease 解释；必需并导出给 Sweep。
- **`prepareCorrection(player, boundary, state, target)`（L640-L662）**：输入玩家、边界、状态和目标位置；要求目标 bitmap active、权威 cell 中精确目标格已加载且身份可靠；递增 correction sequence 后返回带 rvId/generation/version/onlineId/坐标的 payload，否则 `false`。不向未知格传送的关键防护；必需。
- **`notifyCorrection(player, payload)`（L664-L667）**：输入玩家和 correction payload；发送 `COMMAND_RV_BOUNDARY_CORRECTION`，当前忽略发送结果。把服务端纠正意图发给客户端表现层；必需。
- **`currentSquareMatches(player, position)`（L669-L684）**：输入玩家和刚读取的位置；验证 `getCurrentSquare()` 已加载且格坐标与 floor(position) 相同，返回布尔值。只对新鲜、格状态一致的位置作 guard 决策；必需。
- **`guardContextForPlayer(player, position, knownIdentity, deferValidationMiss)`（L686-L761）**：输入玩家、位置、可选身份和 miss defer 标记；读取当前 boundary，复验 relation 与 record rider、维护玩家快照、阻止活动转场/未加载 current square；返回供对象 guard 使用的 position/bitmap/AABB/boundary/spawn identity/expected spawn 与两个回调，失败为 `nil`。职责上是 player guard context 组装核心；本目录当前没有从 Geometry `ctx` 导出的已装载子组件调用它，需确认是否保留为预留钩子。
- **匿名 `preparePullback()`（L754-L756）**：无参数；捕获玩家、boundary、state、record spawn，委托 `prepareCorrection` 并返回 payload/false。惰性创建纠正 payload，避免 guard 需要纠正时重复拼字段；依赖 `guardContextForPlayer`，目前随父函数无可见消费者。
- **匿名 `notifyPullback(payload)`（L757-L759）**：输入 correction payload；捕获玩家并委托 `notifyCorrection`，无显式返回。与上述回调同样当前无可见消费者。
- **`Boundary.cachedBitmap(record)`（L763-L770）**：输入 record；按其身份键查注册对象，并要求编码记录引用匹配；返回已验证 decoded bitmap 或 `nil`。Sentinel/RoofRefresh 复用启动 gate 已校验的 bitmap，避免重解持久 schema；必需。

### `RV_BoundaryServer_Sweep.lua`

- **工厂 `function(ctx)`（L2-L121）**：接收服务门面/Geometry 提供的 state、identity、position、tick、queue helpers，并安装 `Boundary.onTick`；无显式返回值。组件装配入口，必需。
- **`untrackedOutsideProbeDue(identityKey)`（L17-L21）**：输入身份 key；检查私有 retry deadline 是否缺失/无效/已到期，返回布尔值。限制重启后未跟踪玩家的 map 验证频率；必需。
- **`deferUntrackedOutsideProbe(identityKey)`（L23-L29）**：输入身份 key；将该玩家的下一次探测安排在 300 tick 后（Core tick 相加成功时才保存）；无返回值。配合上一函数作逐身份限频；必需。
- **`onlinePlayersSnapshot()`（L31-L53）**：无参数；优先复制 `getOnlinePlayers()` 集合，兼容 Java size/get 和 Lua table；若结果为空，回退到 `getPlayer()`；返回玩家数组。让一轮 sweep 遍历稳定列表，必需。
- **`Boundary.onTick(tick)`（L55-L119）**：输入可选游戏 tick；更新 `_tick`，取在线玩家位置和 identity；更新已跟踪/区域内玩家，跳过有活动 transition lease 的玩家；每 tick 最多处理一个冷态区域外候选；构造 activePlayers/activeBoundaries 并调用 TemplateProtectionRepair tick hook；无显式返回值。是区域内玩家 guard 与队列工作的调度入口，必需。注意其 `updatePlayer` 依赖在当前源码未注入，详见上方装配断点。

### `RV_RailroaderServer_BoundaryValidation.lua`

- **工厂 `function(ctx)`（L2-L309）**：输入 RVMapping 传入的 Boundary、Adapter、map/region/record 检查器、mutex、身份 helper、在线玩家快照；创建本地 cache/pending 与预热节流状态，安装三个 `Adapter` 方法和三个事件回调，并返回 `{invalidate=...}`。该分层入口必需。
- **`invalidate()`（L24-L29）**：无参数；清空私有验证 cache/pending、重置 prewarm tick，并写 `Adapter._boundaryValidationWarmPending=true`；无返回值。映射变化时作 cache 失效必需；warm pending 在当前代码搜索中是写入而未读取的标志。
- **`roofRefreshBoundaryReadAllowed(server, record, identityKey)`（L31-L40）**：输入 server API、record、玩家身份 key；安全调用 RoofRefresh 的只读授权 hook，只有严格 `true` 返回 `true`。允许 guard cache 在 RoofRefresh transaction 中作特许读取；保持 fail-closed 必需。
- **`roofRefreshBoundaryContextReadAllowed(server, record, identityKey)`（L42-L53）**：同上，但调用更窄的 boundary-context read 授权 hook；返回严格布尔值。区分 RoofRefresh 构造事务上下文所需的授权与普通 guard 读取；安全策略不同，不建议为减少几行而抹平成同一种授权。
- **`validatePlayer(player, suppliedIdentity, knownMap, forceRefresh, deferCacheMiss, roofRefreshContextRead, roofRefreshGuardRead)`（L55-L216）**：输入玩家、可复用的 identity/map、是否强制刷新/延迟 cache miss、两种 RoofRefresh read mode；拒绝不一致身份、generation mutex、活动转场非法读、无效 map/relation/rider/record/manifest/geometry 和未获准 RoofRefresh 状态。通过时返回 boundary、record、relation、validatedIdentity、manifest；普通成功结果入带 mapping/geometry epoch 和 60-tick TTL 的 cache，失败清对应 cache，延迟路径标 pending。唯一的当前数据准入点，必需。
- **嵌套 `diagnose(reason)`（L141-L147）**：输入拒绝原因；将当前玩家、validated identity、玩家是否在 RV 区、relation/record 和原因交给 `Boundary.diagnoseGuardState`（若存在）；无显式返回。把验证失败接入用户提示和 server log，必需。
- **`Adapter.validateCurrentBoundaryPlayer(player, suppliedIdentity, deferCacheMiss, forceRefresh, roofRefreshContextRead, roofRefreshGuardRead)`（L218-L224）**：输入 guard 调用者参数；把 bool 严格规范为 `true` 后委托 `validatePlayer`，输出沿用 validator 的多返回值。Geometry 调用的 adapter 合同，必需。
- **`needsRefresh(identityKey, forceRefresh)`（L226-L237）**：输入身份 key 和强制标记；对比本地 cache、mapping/geometry epoch、tick 有效性及 30-tick refresh 周期，返回布尔值。让批预热周期性重验；必需。
- **`Adapter.prewarmCurrentBoundaryPlayer(player, knownMap, forceRefresh)`（L239-L246）**：输入玩家、可选共享 map、强制 refresh 标记；建立稳定 identity 并委托 `validatePlayer`，输出验证多返回值或 `nil`。单玩家缓存预热入口；必需。
- **`Adapter.prewarmCurrentBoundaryPlayers(knownMap, knownPlayers)`（L248-L282）**：输入可选 map 与已筛选玩家列表；generation 事务不忙且达到节流 tick 后，选定或生成 RV 区候选，取 map 并逐玩家预热；清 pending/warm 标志并返回成功布尔值。批预热，必需。
- **`prewarmAfterWorldLoad()`（L284-L286）**：无参数；委托批预热当前玩家；作为 OnGameStart/OnServerStarted 回调，必需。
- **`prewarmCreatedPlayer(playerIndex, player)`（L288-L294）**：接收 OnCreatePlayer 的 index/player 参数；优先实际 player，确认在 RV 区、取得 map 后预热该玩家；无显式返回。新建玩家进入范围时准备 cache，必需。

## 跨模块复用与抽取判断

1. **安全对象/全局调用和数值身份 helper**：`number`、`integer`、`call`、`callGlobal`、`identity` 在 Geometry 中集中，并由同一个 `ctx` 给 Objects 复用（Geometry `L773-L786`，Objects `L8-L16`）；比各自复制错误处理更一致，当前归属合理。若未来更多 server 模块要用，应提取到 Core/Shared 的小型 server utility；现在继续保留在 `Boundary` 包内的收益高于新增全局 API。
2. **边界三种相等比较**：managed bounds、bitmap bits、shell edge 内容（Geometry `L277-L350`）是不同深度的相等概念。可以共用字段表/规范化 helper，但不应混成一个宽泛 `sameBoundary`；当前 `sameBoundary` 只比较身份 key（`L352-L355`），命名需要把“身份相同”写进合同。
3. **验证器中的 RoofRefresh 授权包装**：`roofRefreshBoundaryReadAllowed` 和 `roofRefreshBoundaryContextReadAllowed` 形状近似（Validation `L31-L53`），但分别代表 guard 读取和事务上下文读取两种不同权限。少量调用重复低于安全语义分离的价值，保持具名双接口更清晰。
4. **关系复核逻辑**：BoundaryValidation `validatePlayer`（`L135-L165`）验证 map relation 与 record rider；Geometry `guardContextForPlayer`（`L701-L715`）又核验 relation、locoId、rider 和 onlineId。可抽为同一目录私有校验器或让后者信任明确的 validator 输出，但须保留后者对 record/relation 当前身份的额外保护。抽取收益中等，首先应明确哪一层是最终权威，避免重构时削弱第二次 guard。
5. **回调/预热**：`prewarmAfterWorldLoad` 和 `prewarmCreatedPlayer` 不能合并成同一个无参 callback，事件参数形状和处理范围不同；二者共享批量/单人预热 API 已足够。

## 是否需要进一步拆分

- **建议评估将 Geometry 拆为两个内聚组件**：`makeBoundary`/`encodeShellEdges`、`decodeBoundary`、相等比较、source/generated cache、`loadedBoundary`、`registerGeneration`、`cachedBitmap` 是“持久记录与几何登记”；`identity`、`stateFor`、transition lifecycle/租约、`prepareCorrection`、`guardContextForPlayer` 是“玩家 guard/转场”。它们集中在一个 787 行文件，且前一类由 `Boundary._registered`/`_geometryEpoch` 管理，后一类由 `Boundary._states` 管理。按这个状态所有权拆，能让同身份几何缓存和玩家状态接口更清楚。
- **拆分不是立即强制项**：`boundaryForPlayer` 同时串接 Adapter 验证和 geometry cache；拆分需通过工厂依赖注入一个清晰的验证结果接口，避免跨文件直接读取另一组件的私有缓存。若拆分后只搬函数并暴露全部 helper，收益会被耦合抵消。
- **Sweep 和 BoundaryValidation 暂无进一步拆分必要**：Sweep 的小型限频、候选选择和 onTick 调度为单一流程；Validation 虽有缓存和预热两部分，但预热正是验证 cache 生命周期的触发方式，尚无足够独立的数据所有权来拆成更多文件。

## 直接访问模块内部数据与接口建议

| 访问方 → 数据所有者 | 直接访问位置 | 判断与接口收益 |
|---|---|---|
| Sweep → Geometry/Boundary 状态 | Sweep `L55-L57` 写 `Boundary._tick`；`L66-L68` 读 `Boundary._states[id.key]` 与 identity。 | 同一门面下的组件协作，tick 必须和同轮 `transitionActive`/队列一致。tick 是单个同步标量，getter/setter 包装收益很低；可增加私有 `trackedState(identity)` 查询避免直接取整张 `_states`，但无需返回完整状态。 |
| BoundaryValidation → Geometry 玩家状态 | Validation `L81-L88` 读 `_states[key].transitionToken/transitionUntil`、`Boundary._tick`、`Boundary._geometryEpoch`；`L200-L202` 与 `L231-L232` 再读 epoch。 | 属于两个不同服务模块之间的内部 schema 访问。`transitionToken/transitionUntil` 是状态实现细节，宜由 Boundary 提供 `canValidateCachedBoundary(identity, roofMode)` 一类只读判定；几何 epoch 可用只读 revision hook。收益明显，减少字段改名造成静默误判；验证 cache 仍应保留 mapping/geometry revision 语义。 |
| BoundaryValidation ↔ Adapter/Mapping | Validation `L28,L87-L89,L115,L121,L200-L202,L229-L232,L251,L267,L280` 读写 `Adapter._boundaryValidationWarmPending`、`_boundaryValidationEpoch`、`_ticks`；Mapping `L102-L108,L227-L244` 改 epoch、调用 validator invalidate 并注入 helpers。 | `_boundaryValidationEpoch` 可由现有 `boundaryValidation.invalidate()` 的缓存清空承担，或由 validation 私有 revision 管理；不必暴露在 Adapter。`_ticks` 是全 Adapter 多模块共享的当前 tick，抽象收益较低，允许只读快照接口即可。`_boundaryValidationWarmPending` 在全源码扫描里只被写未读；若无外部非 Lua 读取，应删除状态或补上真实消费者，当前没有行为收益。 |
| TemplateRecovery → Boundary transition 状态 | `TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:L204-L221,L275-L288` 遍历 `_states` 并读 RV identity、token、kind、until；`L295` 读 `_tick`。 | 这是目录外消费者访问 Boundary 私有状态。已有 lifecycle listener 注册点（Geometry `L533-L550`），但 repair 还做定期扫描以观察超时/完成窗口和重建状态；不能简单删掉扫描。可提供窄的 `transitionSnapshot()`/`forEachTransition`，隐藏其它玩家状态字段；收益中高，需维持恢复与两 tick stamp 的语义。只读 `_tick` 为同步时间值，接口收益低于重建多余的时间副本。 |
| TemplateRecovery → DemolitionProtection build-action 队列 | Objects `DemolitionProtection/RV_BoundaryServer_Objects.lua:L580-L609,L629-L647` 创建和消费 `Boundary._builders`；TemplateRecovery `L1722-L1726` 扫描并删除过期 action。 | `_builders` 是以 `_` 标识的模块内部异步队列，却由另一个目录清理，所有权不清。建议让 Objects 暴露 `pruneExpiredBuilderActions(tick)` 或在对象队列自己的 tick 接口中清理；这样有明确收益，防止队列字段/过期规则分叉。 |
| 其他服务 → Boundary 公共行为 | Construction 调用 `makeBoundary`（`Construction/RV_Server_GenerationFlow.lua:249-L257`）；Mapping/schema gate 调用 `registerGeneration`；EntryExit、RoofRefresh、Sentinel 使用 `begin/complete/extend/clearTransition`；RoofRefresh/Sentinel 使用 `cachedBitmap`；服务 tick 调 `onTick`。 | 这些是方法调用合同，没有发现调用者直接改 `_registered`。应保留为公开行为接口，并写清 token、identity 和 fail-closed 返回含义。 |
| BoundaryValidation → RailroaderServer/RoofRefresh 接口 | Validation `L166-L198` 调 `currentRVManifestForBoundary`、`currentRVRecordGeometryConsistent`、两个 `isRoofRefreshBoundary*ReadAllowed`。定义/提供分别见 `RVMapping/RV_Server_RecordValidation.lua:L160-L206` 与 `RoofRefresh/RV_Server_RoofApi.lua:L151-L195`。 | 这是服务方法合同，不是直接读取其他模块数据；调用用 `pcall` 且需严格 `true`，边界清晰。保留窄接口优于读取 RoofRefresh 的 relocation group 内部状态。 |

**接口总评**：Boundary 门面方法是合适的跨模块合同；`Boundary._states`、`Boundary._builders`、`Adapter._boundaryValidationEpoch` 更像被跨目录共享的实现字段。优先收口 transition 判定与 builder queue 清理；tick scalar 和同文件夹组件间的短期状态访问收益较低，可暂留但应记录所有者。`Boundary._geometryEpoch` 有实际 cache invalidation 用途，应改成显式只读 revision 合同而非外部猜字段。

## 文件/函数清单与验证记录

- **文件清单**：`RV_BoundaryServer.lua`（57 行）、`RV_BoundaryServer_Geometry.lua`（787 行）、`RV_BoundaryServer_Sweep.lua`（121 行）、`RV_RailroaderServer_BoundaryValidation.lua`（309 行）。目录扫描无其他文件。
- **函数清单复核**：定义扫描共 64 项，含 3 个 `return function(ctx)` 工厂、Geometry 数值转换中的 1 个匿名保护回调、Validation 的嵌套 `diagnose`、Geometry 返回给 context 的 2 个匿名纠正回调，以及所有具名/赋值函数。逐项与报告函数条目核对；事件 Add 的回调是具名 `prewarmAfterWorldLoad` / `prewarmCreatedPlayer`。
- **调用/状态交叉核对**：检查 Geometry 注入的 helper 在本目录 Sweep 和目录外 Objects 的接收点；检查 Adapter 注入位置、边界方法调用、`Boundary._states/_builders/_tick/_geometryEpoch` 与 `Adapter._boundaryValidation*` 引用。另在整个 `media/lua` 扫描 `updatePlayer`：仅得到 Sweep L10/L75/L103 三处，无字段赋值或函数导出；逐行核对门面装配顺序和 Geometry ctx 导出末尾。
- **文档验证**：本文件各章节覆盖四个目标源码文件、逐函数说明、复用/拆分/内部数据接口分析和清单。行号以本次只读扫描时的工作区版本为准。
- **未覆盖项**：没有对 `DemolitionProtection`、`TemplateRecovery`、Mapping、RoofRefresh 等目录逐函数审计；只核对本报告引用的交互点。没有动态验证 bitmap、事件顺序、服务器 API 或游戏运行行为。装配断点的静态结果明确，实际 tick 影响仍未运行时复现。未发现需要因文件所有权冲突而跳过的内容。

## 第二阶段状态边界更新

BoundaryGuard 仍拥有自身 `_states` 与 geometry registry；同目录 Geometry/Sweep/BoundaryValidation 的私有访问保留。目录外 TemplateRecovery 现在只取 `transitionActivitySnapshot(tick)` 的 identity-level 活跃/近期完成事实，并注册 transition lifecycle 与 post-player-tick callback。transition token、timeout 和短 completion stamp 仍由 Boundary 管理，TemplateRecovery 的 100-tick grace 仍由 Queue 管理。`_builders` 已删除；build ledger 的 prune/invalidate 由 DemolitionProtection owner 实现，Boundary tick/registration 只调用语义 wrapper。见[第二阶段报告](phase2-structure-optimization.md)。
