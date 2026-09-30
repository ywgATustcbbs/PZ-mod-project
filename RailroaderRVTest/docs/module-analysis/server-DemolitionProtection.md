# 服务端 DemolitionProtection 模块分析

## 假设、范围与验收条件

- 将指定子文件夹内所有 Lua 文件视为本模块；只读扫描发现该目录目前只有 `RV_BoundaryServer_Objects.lua`。
- 逐函数清单只覆盖该文件。为确定调用契约和直接数据依赖，额外只读查看 BoundaryGuard Geometry/Sweep、事件注册、TemplateProtectionRepair、RoofRefresh 和公共 world helper 的少量相关位置；这些文件不纳入本模块逐函数清单。
- 分析依据是当前静态源码。仓库内搜索不能排除外部模组或动态调用；凡未找到调用点均标为“仓库内未发现”，不据此断言 API 永远无人使用。
- 完成条件：列出模块内具名函数、表字段函数和匿名函数；逐个说明参数、结果/副作用、语义和当前实现必要性；分析复用、拆分、跨模块数据访问与接口价值；提供行号、核对范围和未覆盖项。
- 验证限于文件/符号扫描、逐行交叉核对和本文档检查；未修改源码，未运行运行时测试。

## 文件与职责

| 文件 | 内容 |
|---|---|
| `media/lua/server/RailroaderRV/DemolitionProtection/RV_BoundaryServer_Objects.lua` | 由 BoundaryServer 传入共享上下文并扩展 Boundary 服务。负责校验当前生成的 shell wall 身份、将服务端建造意图和新对象关联后写入玩家建造标记，以及检查/移除受管理范围内不允许的玩家建造对象。 |

文件以 `return function(ctx)` 工厂形式加载。工厂加载 RoomTemplate，校验当前模板，并把方法写入 ctx.Boundary。无另一个本目录入口文件。源码共有 25 个函数形式：1 个匿名工厂和 24 个具名/表字段函数；未发现额外匿名回调定义。事件回调是具名表字段函数，之后由 Core 注册。

## 函数明细

### 模块初始化与对象元数据

#### 匿名模块工厂（L2-L24，L665）

- 入参：ctx 是 BoundaryServer 组装的服务上下文，包含 Boundary、Bitmap、Core、常量、数字与安全 Java 调用辅助函数，以及 boundary identity 辅助函数。
- 结果/副作用：没有显式返回值；读取并校验 RoomTemplate，错误时抛出异常；在传入的 Boundary 表上安装下文所列公开函数。
- 模块语义：完成启动期依赖捕获和模板前置校验。
- 必要性：必要。对象校验依赖模板索引，回调依赖 Boundary 的共享服务和当前布局身份。
- 备注：L13 捕获的 ctx.square 在此文件没有后续引用；其余捕获项均有使用。

#### objectModData（L26-L29）

- 入参：object，PZ 世界对象。
- 结果/副作用：安全调用 getModData；成功且结果为表时返回该表，否则返回 nil；不修改对象。
- 模块语义：集中处理对象 modData 的可用性检查。
- 必要性：必要。rvTag 和 markTagPlayerBuilt 都依赖它安全读取或更新对象标记。

#### rvTag（L31-L48）

- 入参：object。
- 结果/副作用：返回经 owner 冲突检查后可认领的 RailroaderRVTest 命名空间或顶层 tag；缺失、冲突或无本模组 owner 时返回 nil；不写入。
- 模块语义：选择对象当前有效的所有权标记，避免顶层和嵌套字段相互覆盖产生误删授权。
- 必要性：必要。shell 身份与建造审核都需要对模组 tag 作保守判定。

#### objectSquare（L50-L54）

- 入参：object。
- 结果/副作用：安全调用 getSquare；成功时返回 square，否则 nil；不修改世界。
- 模块语义：为对象坐标定位提供方格引用。
- 必要性：必要。objectCell 需要 square 坐标并将其返回给 shell 校验/移除路径。

#### objectCell（L56-L72）

- 入参：object。
- 结果/副作用：优先读取对象 square 的整数 x/y/z；不可用时读取对象自身坐标、转为数字后向下取整。成功返回 x、y、z、square；失败返回 nil；无世界修改。
- 模块语义：统一对象宿主坐标，兼容对象 square 与对象坐标两种 API 路径。
- 必要性：必要。多条保护路径需要在 bitmap 和 shell ledger 中准确定位对象。

### Footprint 与 shell ledger 校验

#### footprint（L74-L91）

- 入参：tag 及宿主 x/y/z。
- 结果/副作用：无 footprint 时，普通单格对象返回仅含宿主格的列表；标为 multiTile 时返回 nil。已有 footprint 时校验每项为表、坐标为整数且含宿主格，然后返回规范化坐标列表；不完整或相对坐标证据不足时返回 nil。无副作用。
- 模块语义：只接受可证明为绝对世界坐标的对象占地范围。
- 必要性：必要。disallowedPlayerBuild 和 auditObject 要确保复合对象整体都在本 RV 管理范围内。

#### shellEdgeHasTemplateIndex（L93-L113）

- 入参：edge ledger 项、候选 templateIndex。
- 结果/副作用：验证 templateIndices 是连续正整数数组、首项与主 templateIndex 一致，并判断候选索引是否存在；返回布尔值，无副作用。
- 模块语义：阻止稀疏、别名或自相矛盾的模板索引记录通过 shell 身份验证。
- 必要性：必要。shellEdgeAllowed 和 isCurrentShellWall 都以它验证当前 ledger 项。

#### shellEdgeAllowed（L115-L169）

- 入参：boundary、对象 tag、对象宿主坐标。
- 结果/副作用：从 tag 的 edgeKey/edgeKeys 找 ledger 项，核对 RV/generation/bitmap 身份、模板定义、角色、锚点相对位置及实际宿主坐标；任一精确条件匹配时返回 true，否则 false；只读。
- 模块语义：证明对象确属当前 boundary ledger 中可替换的 shell edge。
- 必要性：必要。当前墙身份检查及玩家建造/审计路径必须识别并保留由 ledger 保护的边界对象。

#### shellHostOwnershipUnknown（L177-L188）

- 入参：boundary 和对象宿主坐标。
- 结果/副作用：若任何 shellEdges 项记录了同一对象宿主坐标，返回 true；否则 false；只读。
- 模块语义：当 host 与 ledger 相关但不能证明合法替换时，指出所有权仍不确定，支持 fail-open 保留对象。
- 必要性：只服务 auditObject 的防误删分支；该分支本身在仓库内未发现调用者。若保留公开审计功能，此保护判断是必要的。

#### Boundary.isCurrentShellWall（L196-L280）

- 入参：object 和 boundary。
- 结果/副作用：严格检查对象类型、object index、坐标和 bitmap scope；校验顶层/嵌套 tag 与当前 RV 身份；比对当前 RoomTemplate 捕获对象的 class/name/sprite/north/direction/role；再精确核对 shell ledger。只返回布尔值，不改变世界。
- 模块语义：判定被移除对象是否确为当前生成世代的 shell wall/窗口/角件。
- 必要性：必要且有仓库内消费者。RoofRefresh 使用它决定移除事件是否应触发对应 RV 的 roof refresh（RoofRefresh L507-L524）。

#### appendShellEdgeKey（L282-L286）

- 入参：result 列表、seen 集合、候选 key。
- 结果/副作用：丢弃非字符串和重复 key；否则写入 seen 与 result；没有显式返回值。
- 模块语义：构造去重后的候选 ledger key 列表。
- 必要性：必要。shellEdgeKeysForAction 合并定向和宿主坐标匹配结果时使用。

#### shellAxisMatches（L288-L295）

- 入参：edge 和 axis（可为 nil）。
- 结果/副作用：nil 允许任意 side；N/W/E/S 分别匹配 north/west/east/south；未知方向返回 false；只读。
- 模块语义：按建造回调报告的方向限制 shell ledger 候选。
- 必要性：必要。shellEdgeKeysForAction 扫描 ledger 时用于过滤；没有方向时允许宿主坐标兜底匹配。

#### shellEdgeKeysForAction（L303-L343）

- 入参：boundary、动作坐标 x/y/z、axis（可缺省）。
- 结果/副作用：根据 N/W/E/S 的 canonical Bitmap key 查找；axis 缺省时探测四边；再扫描记录对象宿主坐标的 ledger 项。返回去重 key 列表，不改 boundary。
- 模块语义：兼容 PZ 建造回调给 active edge cell 或对象相邻 host tile 两种坐标约定。
- 必要性：必要。建造意图的边界对象归属需要对应实际 host，而不能只信回调坐标约定。

#### actionMatchesObject（L345-L363）

- 入参：建造 action 和新增对象 x/y/z。
- 结果/副作用：若对象等于 action 坐标则 true；否则通过 action 的边方向和 shell ledger 检查真实 host；缺字段或不匹配为 false。只读。
- 模块语义：把异步 OnProcessAction 意图与 OnObjectAdded 对象关联。
- 必要性：必要。无唯一坐标匹配时回调不会给对象打玩家建造标记。

### 所有权判定与建造审核

#### sameOwner（L365-L382）

- 入参：tag 和 boundary。
- 结果/副作用：要求完整 owner、rvId、generation、bitmapVersion，且与 boundary 一致；返回布尔值，无副作用。
- 模块语义：拒绝缺字段或属于其他 RV/世代的 tag。
- 必要性：只由 auditObject 的可选审计路径使用；若保留该路径则必要，当前仓库内未发现 auditObject 调用者。

#### removeObject（L384-L388）

- 入参：object 和 square。
- 结果/副作用：调用 square.transmitRemoveItemFromSquare(object)，返回调用成功且结果非 false 的布尔值；会请求服务端权威移除及同步。
- 模块语义：封装唯一的对象移除副作用。
- 必要性：只被 auditObject 的非法玩家建造分支使用；对该分支必要，但该入口当前仓库内未发现调用点。

#### protectedWorldObject（L390-L398）

- 入参：object。
- 结果/副作用：用 instanceof 排除世界物品、玩家、僵尸、动物、尸体和车辆；返回布尔值。
- 模块语义：保护不可由 cab 建造审核删除的世界对象类别。
- 必要性：仅由 disallowedPlayerBuild 使用；若审核路径投入使用则必要，当前审核入口未发现本仓库调用者。

#### disallowedPlayerBuild（L400-L445）

- 入参：object、boundary。
- 结果/副作用：拒绝受保护类、无效 boundary、非管理范围对象、tag 身份不匹配、非玩家建造、shell edge 或不明 footprint；检查所有 footprint cell。只有对象不全在 cab 内、且不全属于 bitmap 的 buildable 格时返回 true 和 removal square；否则 false。无移除副作用。
- 模块语义：判定已标记为玩家创建的对象是否处于禁止建造区域，并先验证整件对象范围。
- 必要性：为 isDisallowedPlayerBuild 与 auditObject 提供核心判定；目前两条公开入口在仓库内均未发现调用方。

#### Boundary.isDisallowedPlayerBuild（L447-L450）

- 入参：object、boundary。
- 结果/副作用：调用本地 disallowedPlayerBuild，仅返回是否为 true 的布尔值；不会移除对象。
- 模块语义：公开纯判定接口。
- 必要性：仓库内没有调用点；不是当前已注册事件链路的必要步骤。若保留则是潜在外部 API。

#### Boundary.auditObject（L455-L495）

- 入参：object、player、可选 forcedBoundary。未提供 forcedBoundary 时从 player 查 boundary。
- 结果/副作用：返回布尔值和原因字符串。非法玩家建造时尝试服务端移除并返回结果；其他情况按 scope、tag generation、shell ledger、footprint 和 buildable bitmap 返回保留原因。此函数可产生世界移除副作用。
- 模块语义：对单个对象执行完整审核和必要清理。
- 必要性：仓库内未发现调用点，因此无法证明当前运行流程依赖它；如果目标是提供外部可调用的单对象审核，则内部保护分支是必要的。建议先确认调用合同，再决定保留或接回队列。

### 建造意图标记与事件回调

#### markTagPlayerBuilt（L497-L557）

- 入参：object、builder 身份对象、action。
- 结果/副作用：仅在 modData 可写、无其他 owner 冲突、action identity/version 有效，且没有跨 generation tag 或已生成模板 tag 时写入 RailroaderRVTest 命名空间。设置 owner/playerBuilt/builder/RV 身份和可选 edge/footprint 字段，并清掉模板归属字段；成功返回 true，否则 false。
- 模块语义：以已验证的服务端建造意图标记对象归属，不把模板对象或不明对象变成玩家对象。
- 必要性：必要。onProcessAction 的即时对象路径和 onObjectAdded 的异步关联路径都调用它。

#### commandArgument（L559-L563）

- 入参：args 和 key。
- 结果/副作用：args 是 Lua table 时读 args[key]；否则安全调用 Java 风格 get(key)；缺失时 nil。只读。
- 模块语义：兼容两种事件参数容器。
- 必要性：必要。命令坐标、item、axis、footprint 都来自回调参数。

#### commandCoordinate（L565-L567）

- 入参：args 和坐标字段 key。
- 结果/副作用：经 commandArgument 读取并用整数转换；成功返回整数，否则 nil。
- 模块语义：将事件坐标转成可用于 bitmap 验证的整数。
- 必要性：必要。onProcessAction 需要校验 x/y/z。

#### Boundary.onProcessAction（L569-L627）

- 入参：actionName、player、args。
- 结果/副作用：不返回值。只处理名称含 build/place/moveable 的动作；解析坐标并找玩家当前 boundary、identity；建立含 generation、bitmap、footprint、edge 与 expiry 的短期 action，写入 Boundary._builders。若 args.item 已暴露 Java object，还会立刻校验 scope/host 并调用 markTagPlayerBuilt。
- 模块语义：接收服务端建造事件，记录待关联意图；不能从客户端坐标单独授予可信所有权，仍验证 boundary scope 与后续对象位置。
- 必要性：必要。Core 注册此函数处理 OnProcessAction（RV_Server_Commands L286-L288）。

#### Boundary.onObjectAdded（L629-L662）

- 入参：新加入世界的 object。
- 结果/副作用：不返回值。取得对象坐标，扫描仍有效的 _builders action，按 action 坐标/edge ledger 匹配，并重新查询玩家当前 boundary、比较 generation identity 和 scope；只有恰好一个匹配时才写 playerBuilt tag。
- 模块语义：用有时限且唯一的服务端建造意图关联异步新增对象；不确定或冲突时不标记。
- 必要性：必要。Core 注册此函数处理 OnObjectAdded（RV_Server_Commands L289-L290）。

## 模块间复用机会

| 候选 | 源码证据与差异 | 建议 |
|---|---|---|
| 对象 modData 安全读取 | 本模块 objectModData，L26-L29；公共 ServerWorld 已导出 objectModData（Common/RV_ServerWorld.lua L168-L174、L527）。 | 可以复用现有 helper，减少安全调用包装重复；迁移时确认调用约定一致。当前 `ctx.call` 已由 Geometry 安全封装，因此收益小到中等。 |
| 对象类别保护 | 本模块 protectedWorldObject，L390-L398；TemplateProtectionRepair 的同名 helper 在 L638-L648 也排除类似类，并用 ServerWorld/ServerUtil 分类工具。 | 适合抽取“安全类检查”底层原语；不宜直接合并完整保护策略，因为 TemplateRecovery 额外保护 blood/splat，而本模块类集也有自己的语义。 |
| footprint 解析 | 本模块 footprint，L74-L91；TemplateProtectionRepair footprintAllowsRemoval/objectFootprintAllowsRemoval，TemplateRecovery L703-L740。两者都会核对宿主格和坐标，但后者还检查 dense key、重复格、加载状态、移除范围及 cab 例外。 | 可考虑抽取纯粹的绝对坐标 footprint 解析器，再由每个消费者保留自己的范围/加载/删除策略。不得把两个安全策略合并成一个宽松布尔判断。 |
| 数字、Java 调用、identity、boundary key/相等性 | 由 Geometry 写入共享 ctx（BoundaryServer_Geometry.lua L773-L784），本模块在 L8-L16 捕获。Bitmap edge key 也直接复用 Bitmap API。 | 已经是共享 helper，不需再从本模块另行提取。L13 的 ctx.square 未使用，可清掉这项依赖以缩小 context 合同。 |

## 是否需要继续拆分

当前单文件约 665 行，职责有三组：

1. shell ledger 与生成对象的精确身份确认（L93-L343、L196-L280），其中 isCurrentShellWall 被 RoofRefresh 调用。
2. 玩家建造意图记录和异步对象标记（L497-L662），与 Boundary._builders 有共享状态耦合。
3. cab 范围外建造分类和对象移除审核（L365-L495），但 auditObject 与 isDisallowedPlayerBuild 当前仓库内未发现调用方。

职责边界存在，但目前不建议仅因文件长度立即拆分：shell 匹配、tag 规则、footprint 和 Boundary identity 校验彼此共享；拆分会迫使这些规则变成额外跨文件合同。若继续扩展，优先把建造意图 ledger 及其过期清理接口集中到独立所有者；shell 身份判定也可在确保 tag/ledger helper 接口稳定后拆出。先确认未使用的审核入口是否仍需作为兼容接口。

## BoundaryGuard 接口及内部数据访问

### 已有接口与调用关系

- BoundaryServer 在 Geometry、DemolitionProtection、Sweep 顺序下传入同一个 ctx（BoundaryServer.lua L43-L55）。Geometry 在加载本模块前提供 number、integer、call、callGlobal、identity、square、decodeBoundary、boundaryKey、sameBoundary 等（Geometry.lua L773-L784）。这是模块工厂间的内部依赖接口。
- Boundary.boundaryForPlayer 是 Boundary 服务的公开方法；本模块在 onProcessAction 与 onObjectAdded 中调用它（Objects.lua L580、L643）。Boundary.isCurrentShellWall 是表字段公开函数，并由 RoofRefresh 进行类型检查后调用（RoofRefresh.lua L507-L524）。
- onProcessAction 和 onObjectAdded 是公开表字段回调，Core 在服务端将它们注册到 OnProcessAction 和 OnObjectAdded（RV_Server_Commands.lua L286-L290）。
- Boundary.makeBoundary 的 boundary 数据形状由 Geometry 明确构造，含 rvId、generation、bitmapVersion、managed、bitmap、shellEdges（Geometry.lua L202-L251）；loadedBoundary 生成供运行时使用的 registered view（Geometry.lua L419-L459）。
- 需区分两种 boundary：makeBoundary 的持久化/源记录含 managed；loadedBoundary 在 L451-L454 构造的 registered view 只含身份、bitmap、encoded 和 shellEdges，没有 managed。boundaryForPlayer 返回该 loaded view（Geometry.lua L510-L517）。

### 直接字段访问

- 本模块直接读 boundary.bitmap（例如 Objects.lua L581-L623、L468-L490），boundary.shellEdges（L136、L268-L279、L305-L340）和 boundary.managed（L117-L127），以及 rvId/generation/bitmapVersion、shell edge 字段。bitmap、身份与 shellEdges 是 Geometry 创建的 boundary 版本化数据合同，并非 Boundary 服务内部的 process-local 状态；对稳定数据快照直接取字段简单且低成本，增加每字段 getter 收益有限。若需隐藏 schema，应整体提供 scope/ledger 查询 API 并迁移所有消费者，否则单独封装反而重复暴露同一形状。
- 静态接口不一致：shellEdgeAllowed 依赖 boundary.managed（L117-L127），但 Geometry 的 registered view 不含 managed；Boundary.boundaryForPlayer 返回该 view。因而将该返回值传入 shellEdgeAllowed 时，它会在 anchor 检查处返回 false。当前仓库 RoofRefresh 调用 isCurrentShellWall 时传入的是 record.boundary（RoofRefresh.lua L523-L524），源 boundary 带 managed；而 auditObject 可默认取得 loaded view。审核入口当前仓库内未发现调用方，所以记录为待确认的合同缺口，不推断实际运行影响。若接口本来允许传 registered view，应由 Boundary 提供统一 shell/范围谓词，或令 Geometry 返回完整结构；若参数要求源记录，则应明确约束。
- 本模块直接读写 Boundary._builders，并读 Boundary._tick（Objects.lua L589、L609、L634-L640）。BoundaryServer 初始化两者（BoundaryServer.lua L37-L40）；Sweep 更新 _tick（Sweep.lua L55-L56）；TemplateProtectionRepair 遍历清理过期 _builders（TemplateRepair.lua L1722-L1726）。它们是真正的共享私有状态，跨模块依赖字段名称、action 结构和时限规则。

### 接口收益判断

- 建议为 _builders 提供窄接口，例如提交待关联建造 action、按对象查询匹配候选、以及由 ledger 所有者统一清理过期项。收益明显：一个模块不必知道 action map 的 key/字段及另一个模块的清理时机，还可把唯一匹配和 generation 过期规则放在同一所有者。TemplateProtectionRepair 的现有直接清理也应改调该接口。
- 对 _tick 可由 Sweep 在事件入口传 tick、或提供当前 server tick accessor；收益中等。它能去掉对调度器字段的直接读，但当前系统内部同属一个 Boundary 服务，若只多一个无其他用途的 getter，收益有限。
- boundary 的 managed/bitmap/shellEdges 是 Geometry 构造并版本化的数据接口。对这些数据直接读的收益目前高于逐字段 getter；只有当所有 shell policy 都要统一时，才值得提供整体语义方法（如 scope 或 ledger 验证），避免重复封装。
- `isDisallowedPlayerBuild` 与 `auditObject` 虽写在 Boundary 命名空间，但当前仓库内未发现消费者；在确认目标用途之前不应把它们当作已建立跨模块合同。

## 扫描与验证记录

- 文件清单：对指定目录运行 `rg --files`，结果仅 `RV_BoundaryServer_Objects.lua` 一个 Lua 源文件。
- 函数清单：对该文件运行 `rg -n '\bfunction\b|\bfunction\s*\('`，逐行核对 25 个函数形式；确认仅 L2 是匿名模块工厂，没有遗漏嵌套/匿名回调。
- 逐行交叉核对：读取源文件带行号全文，并分段复查 L385-L500；函数说明中的起始位置、参数和副作用据此核对。
- 跨模块调用/数据搜索：在 server/client RailroaderRV 范围搜索 Boundary 方法、_builders、_tick、shellEdges、footprint、对象 tag；单独核对 BoundaryServer ctx 组装、Geometry ctx 注入、Sweep tick 维护、事件注册、TemplateProtectionRepair 清理和 RoofRefresh 消费点。
- 文档检查：已确认本文包含全部 24 个具名函数和匿名模块工厂、所需分析章节、范围说明及未覆盖项；逐项对照函数声明行号和跨模块引用行号，均落在对应源码文件范围内。
- 未覆盖项：静态搜索不能发现外部模组或运行时动态索引 Boundary 表的消费者。按照只读分析要求，没有运行 runtime 测试，也没有验证游戏中 Java 对象行为。

## 第二阶段状态 owner 更新

本模块现在本地拥有 `BuilderActionLedger`：记录已验证 build action，匹配新 object、确认唯一候选、过期/prune、按 generation 失效并消费 object match。Boundary 不再保存 `_builders`；Boundary tick 与 generation registration 只调用 prune/invalidation 语义接口。`objectModData` 保留本地实现：其 `ctx.call` 在读取 `target[method]` 时未用 pcall，属性访问异常会传播；`ServerWorld.objectModData` 经 `Common.invoke` 保护属性读取并在失败时返回 nil，失败语义不同，故未合并。见[第二阶段报告](phase2-structure-optimization.md)。
