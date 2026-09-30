# RailroaderRV 模组代码分析：全局总结

## 假设、范围与核验方式

本总结汇总同目录下 18 份逐模块分析文档，并交叉核对当前模组代码目录。实际模块数按 Lua 文件夹划分为 client 2 个、server 11 个、shared 5 个。逐函数的输入、返回值、副作用与必要性见各模块文档；本文件提供导航和跨模块结论。

成功标准：实际 Lua 文件全部映射到对应模块文档；列出每个模块的源码文件数、函数表达式数和文档链接；总结客户端、服务端、共享层的职责；对可提取函数、拆分候选和跨模块内部状态访问给出证据、语义差异及接口收益判断；静态问题区分源码事实与未验证的运行时影响。

静态核对结果：

- 对 18 个实际模块目录递归枚举 Lua 文件，共 72 个；逐目录比较了模块文件数，并逐一确认对应文档含有该目录每个实际文件名，未发现缺项。
- 18 份模块报告均存在，路径均为 docs/module-analysis/<模块>.md。
- 函数总数从各模块报告中的扫描/复核数字逐项相加，合计 1,341 个函数表达式。口径包含工厂、嵌套函数和匿名回调；模块公开别名不重复算函数体。shared/Common 的分项表列出 47 个具名函数，另有 2 个匿名 pcall 闭包，故全局按 49 计。
- 按层小计为 Client 12 文件/290 个表达式、Server 47/906、Shared 13/145；三层相加为 72/1,341。
- 本总结只做源码、报告、路径和数字的静态核对；没有运行 Lua、游戏或一键 runtime 测试。运行时后果仅以条件性推断表述。

## 1. 模块索引与职责

| 层 | 模块目录 | Lua 文件 | 函数表达式 | 主要职责 | 逐模块文档 |
|---|---|---:|---:|---|---|
| Client | client/RailroaderRV | 1 | 0 | 单行转发入口，原样返回 GUI 菜单模块的 require 结果。 | [client-root.md](client-root.md) |
| Client | client/RailroaderRV/GUI | 11 | 290 | 客户端菜单、交互意图、实用设施仪表盘、Ride 适配、回执状态及边界/衣柜/拆除表现。 | [client-GUI.md](client-GUI.md) |
| Server | server/RailroaderRV | 2 | 0 | 两份转发入口，实际组合根位于 Core。 | [server-root.md](server-root.md) |
| Server | server/RailroaderRV/BoundaryGuard | 4 | 64 | 边界记录与几何缓存、玩家验证/纠正状态、周期扫描及 Mapping 适配校验。 | [server-BoundaryGuard.md](server-BoundaryGuard.md) |
| Server | server/RailroaderRV/Common | 5 | 80 | 安全调用、参数/布局 schema 验证、世界对象快照和清理、坐标/传送工具。 | [server-Common.md](server-Common.md) |
| Server | server/RailroaderRV/Construction | 6 | 99 | 服务端生成意图校验、构建计划与对象创建、搬运阶段、ACK、失败回滚。 | [server-Construction.md](server-Construction.md) |
| Server | server/RailroaderRV/Core | 10 | 187 | 服务端组合与事件/tick 总线、ModData 仓库、utility 协议和开发期 schema gate。 | [server-Core.md](server-Core.md) |
| Server | server/RailroaderRV/DemolitionProtection | 1 | 25 | 校验玩家放置/拆除对象身份与范围，保护模板壳体及可恢复对象。 | [server-DemolitionProtection.md](server-DemolitionProtection.md) |
| Server | server/RailroaderRV/Power | 2 | 78 | 电力记录、发电机/电池/设备操作、扫描、负载计算及同步。 | [server-Power.md](server-Power.md) |
| Server | server/RailroaderRV/RoofRefresh | 7 | 143 | 房间归属维护、屋顶刷新、分组搬运、边界租约、ACK 与回滚。 | [server-RoofRefresh.md](server-RoofRefresh.md) |
| Server | server/RailroaderRV/RVMapping | 4 | 113 | Railroader 映射适配、列车和乘员关系、进出 RV、记录与几何验证。 | [server-RVMapping.md](server-RVMapping.md) |
| Server | server/RailroaderRV/TemplateRecovery | 1 | 75 | 校验捕获模板身份，扫描并恢复允许修复的对象，维护限速队列和转场暂停。 | [server-TemplateRecovery.md](server-TemplateRecovery.md) |
| Server | server/RailroaderRV/Water | 5 | 42 | 水槽身份/对象适配、plumbing 补偿、ledger、命令和移除见证。 | [server-Water.md](server-Water.md) |
| Shared | shared/RailroaderRV/Common | 4 | 49 | 多端常量、bitmap 编码/查询、共享 utility 常量和视觉注册工具。 | [shared-Common.md](shared-Common.md) |
| Shared | shared/RailroaderRV/Power | 2 | 10 | 电力参数与纯计算、配方制作回调。 | [shared-Power.md](shared-Power.md) |
| Shared | shared/RailroaderRV/RoomTemplate | 5 | 59 | 捕获模板数据与保护账本、模板编译/验证、布局计划和模板坐标几何。 | [shared-RoomTemplate.md](shared-RoomTemplate.md) |
| Shared | shared/RailroaderRV/RVMapping | 1 | 15 | 固定 RV 区域槽位、锚点和矩形之间的严格映射与空位分配。 | [shared-RVMapping.md](shared-RVMapping.md) |
| Shared | shared/RailroaderRV/Water | 1 | 12 | 客户端/服务端共用的水槽身份读取和设备能力只读目录。 | [shared-Water.md](shared-Water.md) |
| **合计** | **Client 2 / Server 11 / Shared 5** | **72** | **1,341** | **18 个模块文档全部覆盖。** | |

### 分层责任关系

| 层 | 责任边界 | 主要输入与输出 |
|---|---|---|
| Shared | 定义当前 schema、常量、几何/模板数据和纯计算；供两端消费。 | 常量、已验证布局/身份结构、bitmap、Power 配置与公式、Water 身份查询。 |
| Client | 展示可用操作、提交用户意图、消费 ACK/snapshot；本地筛选和视觉隐藏只服务于客户端表现。 | 读取 Shared 合同；通过命令发送意图并处理服务端回执。 |
| Server | 以当前玩家、映射、权限、请求阶段和 schema 校验为依据，执行世界/持久化变更、同步及失败恢复。 | 接收不可信意图；读取 Shared 合同；由 Core/Mapping/Construction/Boundary/utility 子系统完成权威处理。 |

可见的主数据流是：Shared 提供合同 → Client 形成并发送操作意图 → Server 验证当前身份、范围与阶段 → Server 执行和同步 → Client 展示回执。客户端传入的坐标、槽位候选或 UI 状态不是授权依据；静态分析未把客户端检查当作服务端验证。

## 2. 可复用函数与提取判断

| 候选函数/实现 | 交叉证据与语义差异 | 建议与净收益 |
|---|---|---|
| 严格 integer 与 exact-key 校验 | shared/RVMapping 的 integer/exactKeys 与 shared/Water 的同名私有 helper 重复；shared/Common 的 Constants.finiteInteger 也用于数值正规化，但允许数字字符串或 Java numeric wrapper，接受范围更宽。Boundary、TemplateRecovery、视觉校验也有相近 helper。 | 可评估一个 shared 严格 schema helper，只接受约定的 Lua 整数并要求精确键集合、无 metatable；不能用宽松的 finiteInteger 替换严格校验，也不能添加别名、旧字段转换或 fallback。跨多目录重复明显，收益中等。 |
| 安全调用底层 | client 的 Boundary/Visuals/Demolition call 与 server Common.invoke、Water 的局部 invoke 都以 pcall 调对象方法。Common.invoke 还保护方法属性读取并保留多返回值；其他实现的错误和返回形状更窄。 | 可共享一个明确约定的底层 invoke primitive；模块仍可保留各自的便捷返回包装。client/shared 不应依赖 server 路径。若不能统一属性读取异常、错误值和多返回值语义，提取只会新增分支，收益有限。 |
| 整数坐标和安全格读取 | GUI RoomOwnership、RailroaderContextMenu、BoundaryClient、Relocation 都读取或复核坐标，但房间/方格使用整数格，迁移玩家位置允许不同的坐标精度。shared Layout/TemplateGeometry/RegionSlots 已提供域内转换。 | 只可提供分别命名的 integer-square reader 和 precise-position reader；不合并为单一坐标比较器。沿用已有 Layout.eachStructureCoordinate、RegionSlots、TemplateGeometry，避免把 RV 几何规则重复散落到通用层。 |
| footprint 与受保护对象分类 | TemplateRecovery 的 protectedWorldObject/footprintAllowsRemoval 和 DemolitionProtection 的 footprint/类别检查相近，但 TemplateRecovery 还考虑 vehicle、blood/splat、容器和各格 loaded 状态；DemolitionProtection 针对玩家建造物并有 shell/buildable 检查。 | 先统一策略和安全边界，再考虑只抽低层 footprint 解析；现在直接合并判定会改变各自保护政策，收益不足以抵消风险。 |
| RoomDef stale 检查、菜单去重和无效数据提示 | GUI RoomOwnership 两处执行相似 stale room 检查/复读；多个 client 文件重复文本本地化、菜单项去重和 invalid-RV 提示，部分调用已通过 UtilityClient 集中。 | RoomDef 可抽一个有明确定义结果状态的 inspect/reset helper。UI 可先复用现有 notifier/option helper，再决定是否需要跨模块公共 client helper；不要为每个按钮建立通用命令框架。 |
| Bitmap 与 schema 几何比较 | ServerSchema 有位串长度检查，与 Bitmap.validate 有部分重叠；Boundary geometry 和 DevSaveSchemaGate 又需比较完整位层/边界。 | 优先复用已有 Bitmap.validate；如要加 equality API，应只表示明确的当前 schema 几何相等，不能把身份键相等、managed bounds 相等和 bitmap 全内容相等混成一个比较器。 |

已经合适地集中实现的公共功能包括 shared Power 的 batteryParameters、RoomTemplate/Layout 几何计划、RVMapping 槽位映射、server Common/ServerWorld 工具、Power 与 Devices 的显式接口，以及 UtilityClient 与 Dashboard 的命名 API。直接读取经过验证的公开字段往往比给每个标量加 getter 更清楚。

## 3. 拆分候选及成本

| 优先级 | 候选 | 可分出的责任 | 成本与建议 |
|---|---|---|---|
| 高 | server/TemplateRecovery：单文件约 1,729 行、75 个函数表达式。 | 模板 identity/index；对象安全检查和恢复；扫描/限速队列；transition pause 与生命周期。 | 边界清楚但共享 Boundary/队列状态较多。先明确服务 API 和状态 owner，再按实际变更分阶段拆；把其他模块状态清理移回所有者。 |
| 中 | client GUI 的 RV_RailroaderContextMenu.lua：762 行、70 个函数表达式；UtilityDashboard.lua：599 行、64 个函数表达式。 | 前者将菜单/mapping 与 Ride transition/Railroader hook 适配分开；后者可将库存遍历和候选物品菜单辅助逻辑分开。 | Railroader 模块的外部适配边界更清楚、收益较高；Dashboard 的 UI callback 共享 player/request state，拆分价值较低。待实际继续扩展或需要独立验证时实施。 |
| 中/条件性 | server Construction 的 WorldObjects、GenerationFlow，以及 GenerationAck 中的 RoofRefresh group processor。 | 新对象类别可将工厂和模板状态应用分层；Flow 可按计划/搬运/最终提交划分；约 170 行 RoofRefresh group processor 更适合由 RoofRefresh 状态 owner 持有。 | GenerationFlow 的 pending transaction 必须保留唯一 owner；RoofRefresh processor 归位比按文件机械拆分更有价值。WorldObjects 已接近 900 行，先确认未用工厂能力和缺失依赖。 |
| 条件性 | shared/RoomTemplate 的 RV_RoomTemplate.lua：819 行；server/Core 的 RV_DevSaveSchemaGate.lua：1,644 行、59 个函数表达式。 | RoomTemplate 可按源编译、编译结果验证、查询 facade 划分；SchemaGate 可分 validator 子模块。 | RoomTemplate 当前共享单例/schema/helper，等出现第二模板或校验增长再拆。SchemaGate 属开发期 gate，报告说明 release 前要删除；不建议为临时代码投入大拆分，也不应因此降低当前 schema 严格性。 |
| 低/暂缓 | GUI Relocation、RoofRefresh destinations、RV_Construction/GenerationBuild、Shared Common、Water。 | 有些职责可以继续拆或移动，但目前已有窄入口或共同事务边界。 | Relocation 与 room ownership 共用 ACK/交易；Construction 与 GenerationBuild 必须一致回滚；Shared Common 的 Bitmap 规模大但独立且公用；Water 当前单文件职责集中。不要仅按函数数拆分。 |

## 4. 跨模块数据访问与接口收益

| 访问类型 | 代码关系 | 接口判断 |
|---|---|---|
| 公开 schema、布局和只读数据 | Server/client 读取 Layout 的 managed/bitmap/bounds、mapping record、manifest、RoomTemplate 元数据、共享 Constants/PowerConfig，以及命令 payload/snapshot 字段。服务端先对当前 schema 和身份做严格验证；这些是已发布的数据合同。 | 直接读字段能表达完整结构比较和遍历，单字段 getter 不隐藏表可变性、也不消除 schema 合同，收益低。应通过现有 validator 和明确 schema 管字段形状。所有代码仍只支持当前声明的 manifest、bitmap、ledger、mapping 和异步身份 schema；禁止提出旧数据兼容、迁移或推断。 |
| 游戏对象 ModData 身份标签 | Client Visuals/Demolition 和 Server Water/TemplateRecovery 等读取对象 ModData；ServerWorld/Construction/Water 写入身份字段，Shared Water Catalog 提供只读验证。 | 对象标签本身必须由消费者读取才能判断现场对象身份；接口无法隐藏引擎对象属性。可以共享严格的字段校验，但保留服务端拥有写入/回滚，不能把世界改动移到 shared。 |
| Client RoomOwnership ↔ Relocation | RoomOwnership 拥有/修改 roomOwnershipGuards；Relocation 直接索引 guard。反向地 RoomOwnership 读取并更新 pendingFinalRelocation 的 args/failed/teleported 字段。 | 这是直接读写 sibling 可变私有状态，接口收益明显：提供按 identity 取 guard 和重新开启 bounded scan 的窄函数；Relocation 自己保留 transaction 字段与阶段 owner。 |
| Construction 生成事务 | GenerationFlow 建立 pendingGeneration；PlayerValidation 更新重连/重试字段；GenerationAck 处理 ACK、取消和回滚；GenerationBuild 更新状态；Construction 读取同一事务锁/owner。 | 多个写入者共同依赖字段名和阶段布尔值，错误释放锁或阶段失配风险来自分散写入。适合集中到 GenerationTransaction 服务，提供 begin/owns/stage/ack/cancel/rollback/release 等状态操作；不应只给每个字段增加薄 getter。 |
| RoofRefresh 分组状态 | RoofRelocation 创建 group；Construction/GenerationAck 遍历并改 group/member；Flow 读取存在性；RoomOwnership 直接检查 group/finalReturn。 | ACK 的 group processor 应移到 RoofRefresh 状态 owner；RoomOwnership 可改用已经存在的 RV.Server.isRoofRefreshTransactionActive()。同一个 RoofRefresh factory 内 ctx 字段由状态 owner 读写，额外 getter 收益低。 |
| Boundary 内部状态 | TemplateRecovery 遍历 Boundary._states 与 transition token/kind/until，扫描同 RV 的其他玩家转场；也读取 _tick。它还负责清理由 DemolitionProtection 写入的 Boundary._builders expires。 | _states 宜由 Boundary 暴露身份级 active-transition 查询或受控 snapshot/iteration，保留过期和短完成戳语义；_builders 的过期清理宜移回 DemolitionProtection owner。单独给已在 callback 中传递的 tick 加 getter 收益较低。 |
| Adapter、utility 与 Water ledger 状态 | UtilityServer 读取 RailroaderServer._mappingEpoch；Sentinel/RVMapping 访问 adapter 的 tick/epoch 缓存。Water Commands 直接改 record.water.state/sinks；Water Ledger 目前提供条目验证/构造/复制，而非 set/remove/state transition。 | epoch 可由 adapter 提供 currentMappingEpoch 或 shouldResync，收益中等。Water 可评估由 Ledger 提供 setEntry/removeEntry/setState，把 ledger 条目形状和不变量留在 owner；当前只有 Commands 写入且 SchemaGate 复核，故收益中等而非缺陷。 |
| TemplateRecovery ↔ RoofRefresh 的移除标记 | TemplateRecovery 在移除对象前保存、设置并恢复 RV.Server._templateProtectionRepairRemovalObject；RoofRefresh 在唯一过滤点按对象引用比较。见 [TemplateRecovery 源码](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua#L83) 和 [RoofRefresh 源码](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RoofRefresh/RV_RailroaderServer_RoofRefresh.lua#L501)。 | 两份报告判断不同：TemplateRecovery 认为具名 predicate/作用域函数能去掉字段和保存/恢复双边耦合；RoofRefresh 认为单一引用相等检查不足以值回新 API。静态证据表明它确是隐藏共享字段，但协议仅在同步 remove 调用期间标记同一个对象，RoofRefresh 只有一个比较点。建议将其列为低到中收益边界：若继续扩散，添加 owner 的 isTemplateRepairRemoval(object)；若希望同时封装标记生命周期，则需要围绕 remove 操作设计 owner 回调接口。当前没有足够收益要求新增一层 getter。 |

### 外部 Railroader 适配边界

RVMapping/Train 适配器读取 Railroader active/current/record 等表和字段，并触及若干下划线字段；报告将其标为对外部实现形状的依赖。该分析未审阅外部 Railroader 源码，不能据此断定某字段是否官方公开或会否变化。模组内部其他模块应继续通过 Adapter 的 trainList/findTrain/playerRole 等服务接入，而不要重复读取这些字段。

## 5. 静态问题与验证边界

以下是静态扫描可直接确认的源码事实。第二列只写可由调用路径推出的条件性影响；没有把它们当成 runtime 复现结果。

| 项目 | 可证静态事实 | 条件性影响与未验证点 |
|---|---|---|
| BoundaryGuard Sweep 的 updatePlayer provider | Sweep 在加载时捕获 ctx.updatePlayer 并在两个路径调用它；BoundaryServer 建 ctx 和 Geometry 填充 ctx 的源码均未提供该字段。见 [Sweep](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Sweep.lua#L10)、[Boundary 装配](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer.lua#L43) 和 [Geometry 注入项](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Geometry.lua#L773)。 | 若 tick 进入已跟踪玩家或冷态候选分支，会调用 nil；[RV.Server tick](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua#L58) 用 pcall 包住 Boundary.onTick，因此静态上推断该轮 sweep 会被中断并由外层捕获。没有运行时复现。 |
| Water desiredPipable 恒真表达式 | [Plumbing](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Plumbing.lua#L69) 使用 desiredConnected and false or true。Lua 的 and/or 选择式对两个布尔输入都得到 true。 | 当 getModData 返回 table 时，[applyState 写入 canBeWaterPiped](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Plumbing.lua#L33)；传入的 pipableFlag 静态上确定为 true。引擎最终可观察的管线/菜单行为未经运行时验证。 |
| UtilityServer.onObjectRemoved 未接线 | [RV_UtilityServer.onObjectRemoved](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua#L414) 存在并转发到 Water；全模组服务端源码搜索没有找到该方法的调用/事件注册。可见的 OnObjectAboutToBeRemoved 注册是 [RV.Server.RoomOwnershipRemovalScan](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua#L292)。 | 从可见注册路径看，Water 的对象移除处理可能没有由该入口触发；外部脚本或动态注册路径未作运行时检查。 |
| Demolition shellEdgeAllowed 与 registered view | [shellEdgeAllowed](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/DemolitionProtection/RV_BoundaryServer_Objects.lua#L115) 从 boundary.managed 派生锚点；Boundary 的 [loadedBoundary](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Geometry.lua#L451) 登记视图不含 managed，而 boundaryForPlayer 返回该视图。 | 若该视图传入 shellEdgeAllowed，managed 缺失会使其在锚点检查处返回 false。仓内未发现 auditObject 调用方；已核实 RoofRefresh 调 isCurrentShellWall 时传的是带 managed 的 record.boundary。因此这是需明确源记录/registered view 契约的静态接口缺口，未证实为运行故障。 |
| Construction.createFurniture 的依赖与调用 | [createFurniture](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Server_WorldObjects.lua#L714) 调用 createEntityFromSprite 与 addNormalObject；本模块/同一 server/RailroaderRV 源码树未找到这两个定义。该局部函数没有导出，也未发现仓内调用点。 | 当前可见生成路径不能证明会调用它；若未来调用，两个未解析名称会按 Lua 全局查找，外部环境是否提供未知。 |
| RoofRefresh/GenerationAck 状态 owner 不一致 | Construction 报告显示 GenerationAck 处理 RoofRefresh group/member；RoofRefresh 报告显示 group API/状态 owner 在 RoofRefresh。 | 这是静态责任错位与耦合证据，不是已证实运行故障；拆移 processor 前需保持唯一事务状态 owner 与原有 ACK/rollback 顺序。 |

## 6. 最终结论

当前结构按 shared 合同、client 意图/UI、server 验证与权威事务大体分层清楚。高收益改进主要集中在隐藏可变事务状态：客户端 RoomOwnership/Relocation、服务端 Generation transaction、RoofRefresh group、Boundary transition state，以及 TemplateRecovery 对 DemolitionProtection builder 清理的越界责任。公开布局、manifest、mapping、ModData 和网络字段按当前 schema 直接读取，多数是必要的数据合同；逐字段 getter 的维护成本通常超过收益。

可以优先收敛严格 schema helper 的重复、复用现有 Bitmap 和 client notifier API，并明确各 transaction 的状态 owner。拆分应按职责与变更边界进行，优先 TemplateRecovery 和 Railroader client adapter；避免拆解共同事务的函数或开发期即将移除的 gate。所有建议继续 fail-closed，仅接受当前源码声明的 schema；本次未对旧数据兼容、迁移或 runtime 行为作任何扩展判断。

## 第二阶段结构更新

上面的文件数、函数数、职责表和建议是第二阶段改动前的静态基线，不代表当前源码计数。状态 owner、责任移动、helper 合同判断、当前符号扫描和验证结果以[第二阶段结构优化报告](phase2-structure-optimization.md)为准。本轮代码变化及对应模块补充说明已记录在该报告；旧函数清单中的行号不再描述改动后源文件。
