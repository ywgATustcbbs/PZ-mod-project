# client/RailroaderRV/GUI 模块分析
> **状态（RailroaderRV 1.0）**：本文件是静态审计记录；其行号、计数和源码结论并非本次发布的全量重核，也不是运行时验证。当前实现以 [源码](../../contents/mods/RailroaderRV/42/) 与 [README](../../README.md) 为准，项目约束以 [agents.md](../../../agents.md) 为准。历史建议不构成修复授权，采纳前须按现行约束重新取证。

## 假设、范围、成功条件与验证方式

- **假设**：只分析模组当前目录 `contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/` 的直接子文件；行号以本次读取的文件版本为准。本层是客户端表现/交互层，按当前 B42 客户端事件与 Railroader 2.1 适配语义解释；服务端仍是权限、身份和世界变更的唯一权威。
- **范围**：覆盖本目录 11 个 Lua 文件及其全部具名函数、`local function`、表方法定义和作为回调/参数传递的匿名函数表达式；只读检查调用方（服务端 wire 生产者、shared 模块、Railroader 官方表）以判断公开 API 使用面与跨模块数据访问。唯一写入目标是本报告。
- **成功条件**：每个函数都有精确起始行、参数类型与含义、返回值或副作用、本模块语义和加粗必要性结论；另外列出复用/拆分建议、接口边界、直接跨模块数据访问位置及证据。不运行游戏、服务器或 runtime 测试。
- **验证方式**：枚举目录文件与行数；用函数定义扫描（`function` 后接可选名字与左括号）逐行核对定义清单；对 `42/media/lua` 全树搜索本模块导出符号、`require` 路径和服务的 wire payload 生产者；完成后检查报告的文件清单、函数条目数、路径与行号引用。源码扫描是静态分析，不替代运行时验证。

## 目录职责与清单

GUI/ 目前承载客户端五类职责：世界菜单/交互入口（Railroader 进出菜单与技术生成入口）、迁移与房间归属事务的客户端侧（阶段校验、本地就绪证明、ACK）、本地渲染隐藏（边界支撑木墙、衣柜）、拆除保护拦截、以及水电实用设施的意图传输与面板显示。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_BoundaryClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_BoundaryClient.lua) | 10 | 消费服务端 `RVBoundaryCorrection`，按 onlineId 定位本地玩家、按序号去重后应用权威位置纠正 |
| [RV_BoundaryWallVisuals.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_BoundaryWallVisuals.lua) | 6 | 对严格身份匹配的边界支撑木墙关闭本地渲染并标脏重画 |
| [RV_ContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua) | 0 | 客户端组合根：加载依赖、组装 `ctx`、把两个职责闭包接线到 `RailroaderRV.Client` |
| [RV_ContextMenu_Relocation.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua) | 25 | `Relocate`/`FinalRelocate` 客户端侧：阶段校验、传送、证明、ACK；技术生成入口（当前未注册） |
| [RV_ContextMenu_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua) | 28 | 房间归属守卫：按身份维护 old/new bounds、每 tick 当前格检查、事件/失败触发的有界全量扫描与修复 |
| [RV_ProtectedDemolition.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ProtectedDemolition.lua) | 17 | 包装 `ISDestroyStuffAction`/`ISDismantleAction`，对受保护模板对象拒绝本地拆除 |
| [RV_RailroaderContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua) | 69 | Railroader 适配：进出菜单、utility mapping 缓存、Ride/生成过渡、current-square 延迟刷新、官方 hook patch |
| [RV_UtilityClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityClient.lua) | 29 | 实用设施意图传输（requestId 关联）、只读 snapshot 缓存、ACK/失败反馈 |
| [RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua) | 15 | 水槽连接、加油、面板入口的世界/物品上下文菜单项 |
| [RV_UtilityDashboard.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua) | 63 | 水电面板窗口：控件构建、snapshot 渲染、操作按钮、库存候选菜单与回执状态 |
| [RV_WardrobeVisuals.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_WardrobeVisuals.lua) | 7 | 对严格身份匹配的衣柜对象关闭本地渲染并标脏重画 |
| **总计** | **269** | 59 个具名表函数、120 个局部/嵌套函数、6 个函数表达式赋值形式的方法、84 个匿名函数表达式 |

函数数口径：计入具名函数定义、`local function`（含嵌套）、`function Client.foo()`/`function M:foo()` 形式的表方法，以及作为参数或回调传递的匿名函数表达式（`function(...) ... end`，含 `pcall(function() ... end)`）；不计 `M.foo = localFunction` 这类导出别名赋值。逐文件数字与 `Media/lua` 扫描结果的对应关系见第 6 节机械核对表；`function` 关键字原始出现次数高于本表，差额来自 `type(x) == "function"` 这类字符串比较，已单独列出。

## 逐文件、逐函数分析

### RV_BoundaryClient.lua

模块在 [RV_BoundaryClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_BoundaryClient.lua:82) 上注册 `Client.onCorrection`（L82）与 `Client.onServerCommand`（L103），在 L110-L118 注册 `Events.OnServerCommand` 和 `Events.OnDisconnect`，L119 返回 `Client`；`_states`（L13-L14）是模块级序号/身份表，未导出访问器。修正来源为服务端 [RV_BoundaryServer_Sweep.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Sweep.lua:100) 的 `rvId/generation/sequence/onlineId/x/y/z`。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| number（L16） | value：任意值（number、string、可算术转换的 Java 代理或 nil）；返回 Lua number 或 nil，不修改状态。 | **必须**：网络表数值可能是 Kahlua 代理或字符串，纠正字段必须先进统一数值化。与 `C.finiteNumber` 语义重叠，但本实现不排除 NaN/±inf（见第 4 节）。 |
| number 中匿名函数（L20） | 无参，捕获 value 执行 `value + 0`；返回转换值，异常由外层 pcall 吞掉。 | **实现必需**：Java 数值代理的算术可能抛错，异常不能穿出纠正路径。 |
| integer（L26） | value：任意值；先经 number 再要求 `math.floor(result) == result`；返回整数或 nil。 | **必须**：onlineId、sequence、generation 必须整数才能做身份匹配与序号单调比较。 |
| call（L32） | target：对象或 nil；method：方法名字符串；`...`：可变调用参数；返回 `true,a,b,c`，目标/方法缺失或调用抛错时 `false,error或nil`。 | **必须**：本文件所有 Java 玩家对象调用（teleportTo、坐标 setter）都需统一异常保护与成功标志。 |
| onlineId（L41） | player：本地玩家对象；先取 `getOnlineID` 并要求整数且 ≥0，失败时回退 `getPlayerNum`；返回 id 或 nil。 | **必须**：纠正按 onlineId 定位玩家；单机/部分 B42 构建不提供可用 online ID，需要槽号回退。 |
| localPlayerByOnlineId（L49） | id：服务端在线 ID（整数）；要求 `getNumActivePlayers`/`getSpecificPlayer` 可用，遍历 0..count-1 逐个比较；返回玩家对象或 nil。 | **必须**：纠正只能作用于身份匹配的本地玩家，不能广播式写所有本地角色。 |
| applyPosition（L61） | player：玩家对象；target：`{x,y,z}` 数值表；依次调用 teleportTo、`setX/setY/setZ/setNextX/setNextY/setLastX/setLastY/setLastZ`，API 存在时再 `setCurrentSquareFromPosition`；返回是否有任一调用成功。副作用：改写本地玩家坐标、下一步坐标与移动历史。 | **必须**：服务端纠正必须同时清掉被拒轨迹的 next/last 记录，否则下一帧会重放被拒移动。 |
| Client.onCorrection（L82） | args：服务端 correction payload 表；校验 onlineId/sequence/generation≥1/rvId 非空/x,y,z 数值，定位玩家并跳过死亡玩家，拒绝 `sequence <= 上次值`，应用成功后写 `_states[onlineId] = {rvId,generation,lastCorrectionSequence}`；无返回（全部为早退）。 | **必须**：身份、顺序去重与重复包门；缺此门会把乱序或重放包当成新纠正。 |
| Client.onServerCommand（L103） | module：命令模块名；command：命令名；args：payload；仅当 `module == C.MOD_ID` 且 `command == C.COMMAND_RV_BOUNDARY_CORRECTION` 时转 `Client.onCorrection`；无返回。 | **必须**：本模块唯一的网络入口，负责从共享命令通道中筛选自身消息。 |
| OnDisconnect 中匿名函数（L114） | 无参；用新空表同时替换闭包内 `states` 与 `Client._states`；副作用清空上次会话的纠正序号与身份。 | **必须**：否则重连后旧 sequence 会挡住新会话更小的纠正值，玩家位置纠正失效。 |

### RV_BoundaryWallVisuals.lua

模块在 [RV_BoundaryWallVisuals.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_BoundaryWallVisuals.lua:120) 注册 `OnObjectAdded`、`LoadGridsquare`、`ReuseGridsquare` 三个事件，无导出表、无返回值。它只改本地 `doRender` 渲染标志，不删除对象。身份 schema 来自服务端 [RV_Server_WorldObjects.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_WorldObjects.lua:261)（tag 只存 `templateIndex`/`edgeKey`，属性从模板重读）。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| call（L25） | target、method、`...`；返回 `true,a,b` 或 `false,error或nil`。 | **必须**：本地对象/容器的 getter 与 setter 都可能抛错，视觉路径不允许异常扩散。 |
| warnOnce（L34） | message：错误文本；首次调用打印固定前缀并置 `warned = true`，此后静默；无返回。 | **实现必需**：`LoadGridsquare` 会高频触发，逐格告警会淹没日志。 |
| isTaggedBoundarySupportWall（L41） | object：世界对象；读 `getModData().RailroaderRV`，校验 owner/rvId/generation≥1/role ∈ {wall-north,wall-west,corner-nw}，用 `templateIndex` 从编译模板取 expected 条目并比对 class/name/sprite/state.doRender/north，再把对象世界坐标经模板锚点转偏移与 expected 的 x/y/z 比对；返回 boolean。 | **必须**：只有角色、模板条目和世界偏移同时成立才允许关闭渲染，避免误隐藏普通木墙。 |
| hideBoundarySupportWall（L85） | object：世界对象；身份通过后 `setDoRender(false)` 并复读确认，再取 `FBORenderChunk.DIRTY_REDRAW` 调用 `invalidateRenderChunkLevel`；失败走 warnOnce；无返回。 | **必须**：`doRender` 是本地渲染标志，必须在对象入格后重新施加并让渲染块失效，否则视觉状态会回退。 |
| onObjectAdded（L105） | object：新加入方块的对象；仅转调 `hideBoundarySupportWall`；无返回。 | **必须**：对象添加事件是隐藏的一次机会，客户端对象同步后即触发。 |
| onGridSquareLoaded（L109） | square：加载/复用的方格；经 `getObjects`/`size`/`get` 遍历后逐个调用隐藏；无返回。 | **必须**：已保存或复用的格子不会再发 OnObjectAdded，必须逐格补应用本地渲染标志。 |

### RV_ContextMenu.lua

[RV_ContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:52) 是组合根，本身 **0 个函数定义**：L8-L11 载入常量与三个表现/保护模块，L12-L17 以 pcall 载入 BoundaryClient，L19-L24 建立 `RailroaderRV.Client` 与 Layout 引用，L25-L49 固定菜单键、命令名与超时/刷新常量，L52-L68 把 15 个键组装进 `ctx`，L70-L71 依次以 `ctx` 调用房间归属与迁移工厂，L73 返回 `Client`。本文件没有可评估参数或输出的独立函数，必要性只能按"是否必须保留为入口"判断：`ctx` 的键集合、两个工厂的调用顺序和 `RailroaderRV.Client` 的建立都在此处，**必须保留**。

需要记录的源码事实与条件性推断：

- `GENERATION_HALO_TEXT`（L32）声明后在本文件与整个 `42/media/lua` 中都没有读取点，只有 L33-L35 的注释解释它保留为客户端语义标签；当前渲染实际使用 ASCII 的 `GENERATION_HALO_RENDER_TEXT`（L36）。
- L12-L17 的 `pcall(require, "RailroaderRV/GUI/RV_BoundaryClient")` 声明 BoundaryClient 可选，但 L11 无保护 require 的 `RV_ProtectedDemolition` 在其 L4 又无保护 require 同一模块；按当前依赖顺序，BoundaryClient 真缺失时会先由嵌套 require 抛错，本处兜底不可达。
- 本文件不被任何 Lua 文件 `require`（全树搜索 `RailroaderRV/GUI/` 的结果见第 5 节）；它被执行只能依赖游戏客户端 Lua 加载器对 `media/lua/client` 的目录加载（**条件性推断**，未运行游戏验证）。

### RV_WardrobeVisuals.lua

模块在 [RV_WardrobeVisuals.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_WardrobeVisuals.lua:131) 注册与边界墙视觉相同的一组事件，无导出表。语义差异只在身份 validator：这里要求 `role == "captured-template"`、`edgeKey == nil`，并用 `wardrobeSpritesByY` 逐 y 绑定 sprite。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| call（L20） | target、method、`...`；返回 `true,a,b` 或 `false,nil`（与其他文件的 call 不同，这里丢弃错误值）。 | **必须**：衣柜身份探测要读 name/sprite/north/坐标，任何一个 getter 抛错都不能中断方格遍历。 |
| warnOnce（L29） | message：错误文本；首次调用打印并置 `warned = true`；无返回。 | **实现必需**：与边界墙同因，避免逐格重复告警。 |
| isWardrobeTemplateEntry（L36） | entry：模板条目表；要求 class=IsoThumpable、name=Dark Fancy Wardrobe、x=-5、z=0、sprite 与 `wardrobeSpritesByY[entry.y]` 一致、north=true、direction="N"、protected=true、state.doRender=false；返回 boolean。 | **必须**：把"这个模板索引确实是一个被隐藏的衣柜"固定为可读合同，供身份校验复用。 |
| isTaggedWardrobe（L47） | object：世界对象；读 ModData tag 校验 owner/rvId/generation/`role == "captured-template"`/`edgeKey == nil`，取模板条目过 `isWardrobeTemplateEntry`，再把世界坐标转模板偏移与 entry 的 x/y/z 比对，并复核 live 对象的 name/sprite/north；返回 boolean。 | **必须**：tag 不存几何，只有"模板条目 + live 对象 + 世界偏移"三重一致才能安全隐藏。 |
| hideWardrobe（L94） | object：世界对象；身份通过后 `setDoRender(false)`、复读确认、`invalidateRenderChunkLevel`；失败 warnOnce；无返回。 | **必须**：与边界墙同一渲染机制；保留对象本体以维持碰撞与拆除保护链路。 |
| onObjectAdded（L116） | object：新加入对象；转调 `hideWardrobe`；无返回。 | **必须**：对象同步后的首次隐藏机会。 |
| onGridSquareLoaded（L120） | square：加载/复用方格；遍历其对象逐个处理；无返回。 | **必须**：覆盖存档复用与跨块重载场景。 |

### RV_ProtectedDemolition.lua

模块在 [RV_ProtectedDemolition.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ProtectedDemolition.lua:280) 加载时立即包装两个官方 timed action 表，无导出表、无返回值。`templateRoles`（L11-L16）固定本模块负责的角色集合；身份合同是"tag 只存 `templateIndex`，class/name/sprite/north/direction/protected 全部从编译模板重读"，与 [RV_Server_WorldObjects.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_WorldObjects.lua:266) 的写入侧一致。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| call（L18） | target、method、`...`；返回 `true,a,b` 或 `false,nil`。 | **必须**：拆除路径上的对象 getter（getModData/getObjectIndex/getSprite）可能抛错，需统一保护。 |
| objectCoordinates（L29，L27 前向声明的赋值） | object：世界对象；经 `getSquare` 与 square 的 getX/getY/getZ 取整数坐标；返回 x,y,z 或 nil。前向声明使 L164 之前的调用点可引用同一函数体。 | **必须**：模板反查需要世界坐标推导锚点与偏移，是本模块所有几何证明的输入。 |
| isDoorOrWindow（L42） | object：世界对象；用 `instanceof` 判定 IsoDoor/IsoWindow，对 IsoThumpable 再探测 `isDoor`/`isWindow`；返回 boolean。 | **必须**：车门/车窗 host 属于可拆除集合，不能仅凭模板条目 protected 就拦截。 |
| showInvalidRVData（L63） | character：角色对象；先要求 `setHaloNote` 可用，尝试翻译键 `UI_RailroaderRV_InvalidRVData`，失败用英文回退文本，pcall 提示 5000ms；无返回。 | **必须**：fail-closed 拒绝必须给玩家可见原因，否则表现为"点击无效"。 |
| showInvalidRVData 中匿名函数（L75） | 无参，捕获 message；保护 `character:setHaloNote(...)` 调用。 | **实现必需**：halo API 在死亡/切换角色时可能抛错，不能中断拆除拦截。 |
| templateTagFailureReason（L78） | tag：ModData 命名空间表；逐项返回 `template-tag-missing`/`owner-mismatch`/`rv-id-invalid`/`generation-invalid`，合法返回 nil。 | **必须**：把"身份 tag 不可用"的具体原因固定为可打印字符串，供 fail-closed 诊断。 |
| rejectInvalidRVData（L91） | character：角色对象；reason：原因文本；打印 `demolition fail-closed reason=...`、调用 showInvalidRVData，返回 true。 | **必须**：集中表达"数据无效即拒绝拆除"的失败关闭语义，返回值直接作为拦截结果。 |
| objectMatchesStaticIdentity（L98） | object：世界对象；tag：身份 tag；expected：模板条目；templateIndex：模板索引；比对 tag 索引、对象索引/方格可用性、`instanceof expected.class`、live name/sprite、方向与 north（expected.north ~= "none" 时）；返回 boolean。 | **必须**：只有 live 对象与模板静态身份一致时才允许继续，避免 tag 指向别的对象却被保护。 |
| objectMatchesStaticIdentity 内嵌 fail（L100） | reason：失败原因；detail：附加诊断（当前未进入返回值）；始终返回 false。 | **保留理由**：当前实现只返回 false 并丢弃 reason/detail，诊断文本由调用方统一成 `template-static-identity-mismatch`；保留该局部函数可让每个失败分支保持同一返回形状，若要恢复细粒度原因直接改这一个函数即可，成本低。 |
| resolveTemplateObject（L155） | object：世界对象；tag：身份 tag；用 `templateIndex` 取模板条目与索引，再把世界坐标转锚点/偏移，并用 `lookupObjectsAtWorld` 找出与索引匹配的 live 对象；返回 `object,index,anchor,world,offset` 或 `nil,reason`。 | **必须**：tag 不存几何，只有"索引 + 世界坐标 + 编译模板"三方匹配才能定位被保护对象。 |
| cabDoorWindowHost（L186） | world：世界坐标表；anchor：模板锚点；转调 `TemplateGeometry.isBuildCellSideHost`；返回 boolean。 | **必须**：把几何判定集中在 shared 模块，本模块只表达"该格是车门/车窗 host"的语义。 |
| isCurrentProhibitedObject（L190） | object：世界对象；character：执行拆除的角色；读 tag；无 tag 或 owner 不匹配返回 false，非表 tag 或身份字段非法走 fail-closed 拒绝，`templateIndex`/模板角色标记缺失按"其他特性所有"返回 false，随后执行 resolveTemplateObject、objectMatchesStaticIdentity、isBuildable、车门车窗豁免、`expected.protected`；返回 boolean。 | **必须**：本模块的核心判定，覆盖普通世界内容豁免、特性隔离、身份失败关闭与 protected 拦截四种语义。 |
| actionIsBlocked（L241） | actionName：动作名（当前只用于诊断语义）；character：角色；object：目标对象；要求 `isClient()` 为真再调用 isCurrentProhibitedObject；返回 boolean。 | **必须**：服务端不执行客户端 action，此判断把保护限定在本地主动作，避免影响服务端流程。 |
| wrapDestroyAction（L250） | action：官方 action 表（`ISDestroyStuffAction`）；要求是表、有 `new` 函数且未被本模块包装过，保存原 `new` 并替换；无返回。 | **必须**：破坏动作没有公开钩子，替换 `new` 是唯一可拦截点；包装标志防止重复包装。 |
| action.new（L256，包装后的破坏动作入口） | self：action 实例；character：角色；item：被破坏对象；cornerCounter：官方参数；被拦截时返回 `{ ignoreAction = true }`，否则调用原 `new` 并透传其返回值。 | **必须**：官方忽略动作的约定信号就是 `{ ignoreAction = true }`，返回该表比抛错更安全。 |
| wrapDismantleAction（L265） | action：官方 `ISDismantleAction` 表；同样的表/方法/标志检查与替换；无返回。 | **必须**：拆卸是与破坏并列的第二个拆除入口，缺它则受保护对象仍可被拆卸。 |
| action.new（L271，包装后的拆卸动作入口） | self：action 实例；character：角色；thumpable：被拆卸对象；拦截时返回 `{ ignoreAction = true }`，否则调用原 `new`。 | **必须**：与破坏侧对称的拦截出口，保持同一忽略约定。 |

### RV_ContextMenu_RoomOwnership.lua

模块在 [RV_ContextMenu_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua:2) 以 `return function(ctx)` 工厂形式加载，由 [RV_ContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:70) 调用；它把 7 个函数写回 `ctx`（L285-L291）供迁移模块复用。`roomOwnershipGuards`（L5）是模块级私有表，键为 `rvId:generation`；遍历一律用 `pairs`（L196、L223、L248）。payload 字段来自服务端 [RV_Server_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:459)。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| 工厂匿名函数（L2） | ctx：组合根表（含 C、Layout、clientTick）；无返回值；在闭包内建立 guards 表、定义全部局部函数并把 7 个函数导出到 ctx。 | **必须**：本模块的加载形式，也是与迁移模块共享函数而不共享状态表的唯一接口。 |
| roomOwnershipGuardKey（L7） | rvId：RV 标识（任意可 tostring 值）；generation：代次；返回 `"rvId:generation"` 字符串。 | **必须**：guard 生命周期按身份+代次隔离，防止旧代次几何被复用。 |
| validRailroaderFinalHint（L14） | args：payload 表；要求 `railroaderTransition == true`、token 非空字符串、locoId/rvId 非空、generation ≥ 1 整数；返回 boolean。 | **必须**：只有服务端创建的 Railroader 迁移标记才允许触碰本地 Ride 状态；本函数被迁移模块经 ctx 复用（L285、Relocation L15）。 |
| localPlayerByOnlineId（L23） | onlineId：整数在线 ID；直接遍历 `getNumActivePlayers`/`getSpecificPlayer`（本文件假定全局 API 可用）；返回玩家对象或 nil。 | **必须**：本地玩家检查需要把服务端 identity 映射到本地对象。 |
| readRoomRefreshBounds（L34） | args：payload 表；prefix：`"old"` 或 `"new"`；按 14 个固定字段名逐个 `finiteInteger`，并校验 wall/room/roof 三个矩形的 min≤max 与 room 包含于 wall；返回 bounds 表或 nil。 | **必须**：服务端 payload 的唯一校验入口，字段缺失或矩形倒置必须拒绝而不是使用半截几何。 |
| eachStructureSquare（L61） | cell：IsoCell；bounds：readRoomRefreshBounds 结果；callback：`(square或nil, x, y, z)` 回调；按 `Layout.eachStructureCoordinate` 遍历并对每格调用 `cell:getGridSquare`；无返回。 | **必须**：把共享几何遍历与 pcall 取格组合，供两处扫描复用（L131-L132、L275 经 refreshInvalidRoomOwnership）。 |
| eachStructureSquare 中匿名函数（L65） | x,y,z：坐标；捕获 cell/callback，保护调用 `cell:getGridSquare`，把 `squareOk and square or nil` 与坐标交给 callback。 | **实现必需**：取格 API 可能抛错，回调必须能区分"该格未加载"与"遍历失败"。 |
| eachStructureSquare 中匿名函数（L66） | 无参，捕获 x/y/z 与 cell，执行 `cell:getGridSquare(x,y,z)`。 | **实现必需**：把可能抛错的取格调用包进 pcall。 |
| squareCoordinates（L73） | square：方格对象；pcall 读取 getX/getY/getZ 并整数化；返回 x,y,z 或 nil。 | **必须**：方格坐标是后续 in-bounds 判断与去重键的输入。 |
| squareCoordinates 中匿名函数（L75） | 无参，捕获 square，执行 `square:getX()`；结果交外层整数化。 | **实现必需**：方格代理读取异常必须转成 nil 而不是中断扫描。 |
| squareCoordinates 中匿名函数（L76） | 无参，捕获 square，执行 `square:getY()`。 | **实现必需**：同上，x/y/z 三项读取失败必须整体判为坐标不可用。 |
| squareCoordinates 中匿名函数（L77） | 无参，捕获 square，执行 `square:getZ()`。 | **实现必需**：同上。 |
| coordinatesInBounds（L85） | x,y,z：整数坐标；bounds：bounds 表；先按 wall 矩形（z == bounds.z）再按 roof 矩形（z == bounds.roofZ）判断半开式包含；返回 boolean。 | **必须**：事件触发的扫描调度和当前格检查共用同一包含规则。 |
| inspectRoomOwnershipSquare（L96） | square：方格对象；pcall 读 `getRoom`/`getRoomDef`，room 非空或 roomDef 非空即视为合法，room 非空但 roomDef 为空时执行 `setRoomID(-1)` 并复读确认；返回 `inspected, reset`。 | **必须**：这是"房间已被释放但方格仍持有 room 引用"的修复动作，复读确认保证修复可验证。 |
| inspectRoomOwnershipSquare 中匿名函数（L97） | 无参，捕获 square，执行 `square:getRoom()`。 | **实现必需**：读 room 失败必须与"room 为空"区分，前者返回 `false,0` 触发后续重试。 |
| inspectRoomOwnershipSquare 中匿名函数（L100） | 无参，捕获 square，执行 `square:getRoomDef()`。 | **实现必需**：读 roomDef 失败同样表示不可检查，不能当成需要修复。 |
| inspectRoomOwnershipSquare 中匿名函数（L103） | 无参，捕获 square，执行 `square:setRoomID(-1)`。 | **实现必需**：这是唯一的修复写操作，失败必须上报为"不可修复"。 |
| inspectRoomOwnershipSquare 中匿名函数（L105） | 无参，捕获 square，再次执行 `square:getRoom()`。 | **实现必需**：修复必须复读确认，否则无法证明 room 引用真的被释放。 |
| refreshInvalidRoomOwnership（L110） | guard：单个 guard 记录；取 `getCell`，对 `guard.oldBounds` 与 `guard.newBounds` 各跑一次结构扫描，按 `"x:y:z"` 去重；返回清理计数（无 cell 时为 0）。 | **必须**：有界全量扫描的具体实现，承载"一次事务最多一次窗口"的成本控制。 |
| refreshInvalidRoomOwnership 内嵌 inspect（L117） | square：方格或 nil；x,y,z：坐标；去重后调用 inspectRoomOwnershipSquare，无法检查时直接返回（不计数）；无返回。 | **必须**：把去重与"不可检查即放弃但保留后续重试机会"的语义固定在扫描回调内。 |
| refreshCurrentPlayerRoomOwnership（guard） （L136） | guard：单个 guard 记录；要求全局 API 可用，遍历所有活动玩家的 `getCurrentSquare`，只对落在 old/new bounds 内的方格做同一修复；返回 `scanOk（本轮是否完成）, cleared`。 | **必须**：玩家当前格是最高频的失效点（进出 RV 的房间所有权失效），需要每 tick 的低成本检查而不是全量扫描。 |
| refreshCurrentPlayerRoomOwnership 中匿名函数（L148） | 无参，捕获 player，执行 `player:getCurrentSquare()`。 | **实现必需**：当前格读取失败必须表现为 `scanOk=false` 触发边沿重试，而不是静默跳过。 |
| objectCoordinates（L174） | object：世界对象；若对象有 `getSquare` 则改读其 square，再转调 squareCoordinates；返回 x,y,z 或 nil。 | **必须**：对象事件回调需要把对象坐标映射到 bounds 判断。 |
| objectCoordinates 中匿名函数（L178） | 无参，捕获 object，执行 `object:getSquare()`。 | **实现必需**：对象的 getSquare 读取异常需降级为 nil。 |
| scheduleRoomOwnershipScan（guard） （L187） | guard：单个 guard 记录；若 `nextScanTick` 为空则置为 `ctx.clientTick + 1`；无返回。 | **必须**：同一 tick 的多个触发合并成一次扫描，是本模块的成本控制核心。 |
| requestRoomOwnershipScan（object） （L193） | object：触发事件的世界对象；取其坐标后对每个 guard 判断包含关系并调度扫描；无返回。 | **必须**：对象增删（墙/楼板变化）是房间失效的早期信号；该函数被迁移模块注册到 `OnObjectAdded`/`OnObjectAboutToBeRemoved`（Relocation L427、L431）。 |
| beginRoomOwnershipRefresh（args） （L204） | args：`RefreshRoomOwnership` payload；校验 rvId/generation≥1/`hasOld` 为布尔/new bounds（hasOld 时还要 old bounds），删除同一 rvId 的其他代次 guard，写入新 guard（`currentCheckErrorLatched=false`、`nextScanTick=nil`），立即执行一次全量扫描并调度下一 tick 复扫；无返回。 | **必须**：服务端广播的授权包是守卫唯一合法来源；删除同 rvId 旧 guard 防止旧几何变成永久客户端路径。 |
| updateRoomOwnershipGuards（L247） | 无参；对每个 guard：先做当前格检查，API 失败按边沿触发一次全量扫描（同 generation 只打印一次）、成功则重置边沿标志；有清理时再调度扫描；到期 tick 执行一次全量扫描并打印计数；无返回。 | **必须**：每 tick 的守卫驱动；把"持久失败不刷屏、成功后再武装边沿"的语义集中在此。 |

### RV_ContextMenu_Relocation.lua

模块在 [RV_ContextMenu_Relocation.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua:2) 以 `return function(ctx)` 工厂形式加载，被 [RV_ContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:71) 调用。它把 5 个方法写到 `RailroaderRV.Client`（requestGenerate/requestTemplateCapture/onFillWorldObjectContextMenu/onServerCommand/onTick），在 L424-L432 注册 `OnServerCommand`、`OnTick`、`OnObjectAdded`、`OnObjectAboutToBeRemoved`，并在 L440-L451 以 pcall 加载 Railroader 适配与实用设施菜单。事务状态有两个：模块级 `pendingFinalRelocation`（L22）与共享的 `ctx.pendingRelocation`（由 [RV_ContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:39) 初始化、本文件读写）。`Relocate` payload 由服务端 [RV_Server_PlayerValidation.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_PlayerValidation.lua:188) 与 [RV_WallReloadProtection.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_WallReloadProtection.lua:147) 生成，`FinalRelocate` payload 由 [RV_Server_PlayerValidation.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_PlayerValidation.lua:240) 生成。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| 工厂匿名函数（L2） | ctx：组合根表；无返回值；捕获 19 个 ctx 键、建立 `pendingFinalRelocation`、定义并导出全部方法、注册事件与尾随 require。 | **必须**：本模块的加载与接线形式。 |
| Client.requestGenerate（L24） | playerObj：玩家对象；发送 `COMMAND_GENERATE` 空表 payload；无返回。 | **当前不是功能必需但保留合同**：唯一调用点是同文件 L48/L57 的未注册 handler；服务端仍以 `"Generate"`（RV_Server.lua L9 → GenerationFlow）处理该命令，删除会丢掉技术生成入口合同。 |
| Client.requestTemplateCapture（L33） | playerObj：玩家对象；发送 `COMMAND_DUMP_TEMPLATE_CAPTURE` 空表 payload；无返回。 | **当前不是功能必需但保留合同**：调用点同样只在 L49/L58 的未注册 handler；服务端 [RV_Server_Commands.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:324) 仍处理该命令。 |
| Client.onFillWorldObjectContextMenu（L39） | playerNum：玩家槽号；context：ISContextMenu；worldObjects：世界对象表（本函数未使用）；test：发现模式布尔；test 与正常模式都添加生成/模板捕获两个选项，test 时还调用 `ISWorldObjectContextMenu.setTest()` 并返回；无其他返回。 | **当前不是功能必需**：全树搜索没有任何 `Events.OnFillWorldObjectContextMenu.Add(Client.onFillWorldObjectContextMenu)`，L433-L434 注释也说明世界菜单已归 RV_RailroaderContextMenu；保留它是"技术测试入口"的待接线代码。 |
| destinationSquareIsLoaded（L66） | x,y,z：数值；要求三者是整数、`getCell` 可用、`cell:getGridSquare` 返回非空；返回 boolean。 | **必须**：最终迁移前唯一的本地就绪证明，防止传送到本机尚未加载的方格并随即 ACK。 |
| destinationSquareIsLoaded 中匿名函数（L77） | 无参，捕获 cell 与目标坐标，执行 `cell:getGridSquare(x,y,z)`。 | **实现必需**：取格调用可能抛错，必须折叠为"未加载"。 |
| tryApplyFinalRelocation（L83） | args：`FinalRelocate` payload；pending：本文件事务表；校验 token/onlineId/x,y,z（z ∈ [-32,31]）、定位并排除死亡玩家；未传送过时要求目标已加载再 `teleportTo`，随后用 `setX/setY/setZ/setLastX/setLastY` 恢复半格中心、可选 `setCurrentSquareFromPosition`，最后用 getX/getY/getZ 精确复核；返回 boolean，并写 `pending.teleported`/`pending.failed`。 | **必须**：最终迁移的坐标应用与"服务端选定坐标已被精确落实"的唯一证明。 |
| tryApplyFinalRelocation 中匿名函数（L108） | 无参，捕获 playerObj 与坐标，执行 `playerObj:teleportTo(x,y,z)`。 | **实现必需**：teleportTo 失败或抛错必须转成 `pending.failed` 而不是继续 ACK。 |
| tryApplyFinalRelocation 中匿名函数（L119） | 无参，捕获 playerObj 与坐标，连续执行 setX/setY/setZ/setLastX/setLastY。 | **实现必需**：B42.20 浮点传送会向下取整，半格中心必须用官方 setter 复原。 |
| tryApplyFinalRelocation 中匿名函数（L133） | 无参，捕获 playerObj 与坐标，执行 `setCurrentSquareFromPosition(x,y,z)`。 | **实现必需**：传送只改坐标，current square 缓存需官方三参重载刷新；该调用必须可选且受保护。 |
| tryApplyFinalRelocation 中匿名函数（L137） | 无参，捕获 playerObj，执行 `playerObj:getX()`。 | **实现必需**：精确复核依赖读数；任一读取失败都不能发 ACK。 |
| tryApplyFinalRelocation 中匿名函数（L138） | 无参，捕获 playerObj，执行 `getY()`。 | **实现必需**：同上。 |
| tryApplyFinalRelocation 中匿名函数（L139） | 无参，捕获 playerObj，执行 `getZ()`。 | **实现必需**：同上。 |
| sendFinalRelocationAck（L150） | playerObj：玩家对象；token：非空字符串；pcall 发送 `FinalRelocateAck {token}`；返回是否发送成功。 | **必须**：最终迁移是独立事务，必须用只含 token 的严格 ACK，不能与普通 RelocateAck 混用。 |
| applyFinalRelocation（L159） | args：`FinalRelocate` payload；清空 `ctx.pendingRelocation`（L163），建立 `pendingFinalRelocation{args,ticks,applied}`，立即尝试一次并在成功时发 ACK（成功即清空 pending）；无返回。 | **必须**：在命令回调内先于引擎 update/audio 路径完成传送，失败则留给 OnTick 有界重试。 |
| Client.onServerCommand（L181） | module：模块名；command：命令名；args：payload；按命令分派：`RefreshRoomOwnership`→beginRoomOwnershipRefresh；`FinalRelocate`→（Railroader 标记时先经 `prepareGenerationRelocation`，失败即中止）applyFinalRelocation；`Relocate`→校验 token/onlineId/rvId/generation/坐标与阶段组合，必要时按阶段显示 halo、清 Ride 状态、传送到 `x+0.5/y+0.5`（return 阶段用精确坐标）并登记 `ctx.pendingRelocation`；无返回（全部早退或 return）。 | **必须**：本文件所有服务端事务的唯一入口；阶段合法性（wallReload/generation 与 temporary/return 的组合）必须在此拒绝，否则客户端会执行未授权移动。 |
| Client.onServerCommand 中匿名函数（L254） | 无参，捕获 playerObj；pcall `setHaloNote(ROOF_REFRESH_HALO_TEXT,255,255,255,1500)`。 | **实现必需**：墙体重载 temporary 阶段需要本地可见提示，halo 不可用时不得影响迁移。 |
| Client.onServerCommand 中匿名函数（L263） | 无参，捕获 playerObj；pcall `setHaloNote(GENERATION_HALO_RENDER_TEXT,...)`。 | **实现必需**：生成 temporary 阶段的本地提示；只显示 ASCII 文本，中文仅作客户端常量。 |
| Client.onServerCommand 中匿名函数（L296） | 无参，捕获 playerObj 与目标坐标；pcall `playerObj:teleportTo(teleportX, teleportY, z)`。 | **实现必需**：teleportTo 同时是远程目标的 streaming 触发器，失败要记录并放弃本次 ACK。 |
| Client.onTick（L327） | 无参；`ctx.clientTick + 1`、调用 `updateRoomOwnershipGuards()`、处理 `pendingFinalRelocation`（超时丢弃/重试应用/发 ACK）与 `ctx.pendingRelocation`（超时、玩家死亡、temporary 阶段 halo 周期刷新、current square 或精确坐标匹配后发送 `RelocateAck`）；无返回。副作用：推进共享 tick、清除两个事务状态。 | **必须**：迁移 ACK 必须等到 current square 真正刷新后再发；这是唯一的客户端应用证明节拍。 |
| Client.onTick 中匿名函数（L372） | 无参，捕获 playerObj；pcall `setHaloNote(GENERATION_HALO_RENDER_TEXT,...)`。 | **实现必需**：temporary 阶段可能跨越多个 tick（含重连重发），需要周期重设本地提示。 |
| Client.onTick 中匿名函数（L394） | 无参，捕获 playerObj，执行 `playerObj:getX()`。 | **实现必需**：current square 尚未绑定时用精确坐标做后备匹配，读数失败必须视为不匹配。 |
| Client.onTick 中匿名函数（L395） | 无参，捕获 playerObj，执行 `getY()`。 | **实现必需**：同上。 |
| Client.onTick 中匿名函数（L396） | 无参，捕获 playerObj，执行 `getZ()`。 | **实现必需**：同上。 |
| Client.onTick 中匿名函数（L413） | 无参，捕获 playerObj 与 token；pcall 发送 `RelocateAck {token}`。 | **实现必需**：发送失败必须保留 pending 以便下一 tick 重试。 |

### RV_RailroaderContextMenu.lua

模块在 [RV_RailroaderContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:11) 建立 `RailroaderRV.RailroaderContextMenu`，并在 L692-L717 安装官方 hook 与事件注册。它同时是 Railroader 官方表（`RR.Ride`/`RR.TrainEntity`/`RR.BoardMenu`/`AnimalContextMenu`）的唯一访问点：读 `ride.nearestBoardable`、`ride.MOUNT_REACH`、`ride.current`、`RR.TrainEntity.active`，写 `record._boardPending`、`board.addForAnimal`、`AnimalContextMenu.doMenu`。服务端 RVTeleport payload 见 [RV_RailroaderServer_EntryExit.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:143)，utility mapping payload 见 [RV_RailroaderServer_Sentinel.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_RailroaderServer_Sentinel.lua:134)。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| text（L21） | key：翻译键；fallback：回退文本；pcall `getText(key)`，结果为空或等于 key 时用 fallback；返回最终文本。 | **必须**：菜单标签必须有可读回退，翻译缺失不能让选项变成键名。 |
| text 中匿名函数（L23） | 无参，捕获 key，执行 `getText(key)` 并写回外层 result。 | **实现必需**：`getText` 在某些构建不可用或抛错，必须降级。 |
| localPlayer（L28） | playerNum：槽号；要求 `getSpecificPlayer` 可用并 pcall 调用；返回玩家对象或 nil。 | **必须**：菜单回调只拿到槽号，需要统一取本地玩家。 |
| localPlayerByOnlineId（L34） | onlineId：服务端在线 ID；先取活动玩家数，逐个 pcall `getOnlineID` 比较，`onlineId == 0` 且有多人槽位时回退槽 0；返回玩家对象或 nil。 | **必须**：RVTeleport 按 onlineId 寻址；单机没有网络槽位但服务端仍以 0 作为 identity。 |
| localPlayerByOnlineId 中匿名函数（L43） | 无参，捕获 player，执行 `player:getOnlineID()`。 | **实现必需**：部分 B42 构建的 getOnlineID 读取会抛错，必须降级为不匹配。 |
| playerPosition（L54） | player：玩家对象；pcall 读 getX/getY/getZ 并 `finiteNumber` 化；返回 `{x,y,z}` 或 nil。 | **必须**：区域内判断需要玩家坐标。 |
| playerPosition 中匿名函数（L56） | 无参，捕获 player，执行 `player:getX()`。 | **实现必需**：坐标读取失败必须整体判为位置不可用。 |
| playerPosition 中匿名函数（L57） | 无参，捕获 player，执行 `getY()`。 | **实现必需**：同上。 |
| playerPosition 中匿名函数（L58） | 无参，捕获 player，执行 `getZ()`。 | **实现必需**：同上。 |
| targetRegion（L64） | 无参；由 `C.TELEPORT_X/Y/Z`、`C.RV_REGION_MIN_OFFSET_X/Y`、`C.RV_REGION_SIZE`、z 偏移常量组合出半开区域表；返回 region。 | **必须**：客户端本地判断与共享常量必须同源，否则会出现"人在 RV 内但看不到 Exit"。 |
| inRegion（L74） | position：`{x,y,z}`；region：targetRegion 结果；按 x/y 半开区间与 z 的 floor 区间判断；返回 boolean。 | **必须**：区域判断的唯一定义，避免多处边界漂移。 |
| mapContainsPlayer（L85） | player：玩家对象；取位置后调用 inRegion；返回 boolean。 | **必须**：菜单显示（Exit vs Enter）的客户端本地依据；服务端 mapping gate 仍是权威（注释 L90-L91）。 |
| validUtilityMapping（L95） | value：任意值；要求 rvId/locoId 为非空字符串、generation 为 ≥1 整数；返回 boolean。 | **必须**：dashboard 候选与 mapping 接受都必须先通过同一形状校验。 |
| rememberUtilityMapping（L103） | args：payload 表；要求 `action` 为 `"enter"` 或 `"exit"`，再按 rvId/locoId/generation 构造 mapping 并写入 `Menu._rvUtilityMapping`；无返回。 | **必须**：RVTeleport 自身也携带可用的 mapping，抓到它可让面板在 mapping 广播缺失时仍可判定候选。 |
| isIsoAnimal（L117） | animal：任意对象；要求全局 `instanceof` 可用并判定 IsoAnimal；返回 boolean。 | **必须**：世界菜单回调会传入非动物对象，需要类型门。 |
| locomotiveType（L123） | animal：任意对象；经 isIsoAnimal 后 pcall `getAnimalType`；返回类型字符串或 nil。 | **必须**：只处理 `rr_loco`，不能把其它 Railroader 动物当成机车。 |
| locomotiveType 中匿名函数（L125） | 无参，捕获 animal，执行 `animal:getAnimalType()`。 | **实现必需**：动物类型读取异常必须降级为"不是机车"。 |
| isLocomotive（L129） | animal：任意对象；`locomotiveType(animal) == "rr_loco"`；返回 boolean。 | **必须**：进出菜单的唯一定义，供世界菜单与动物菜单共用。 |
| locomotiveId（L133） | animal：任意对象；pcall `getAnimalID`；返回 id 或 nil。 | **必须**：菜单只发送 id 作为操作提示，服务端重新解析 live 机车。 |
| locomotiveId 中匿名函数（L135） | 无参，捕获 animal，执行 `animal:getAnimalID()`。 | **实现必需**：id 读取失败必须阻止发送命令。 |
| optionAlreadyExists（L139） | context：菜单对象；label：选项文本；按 `context.numOptions` 或 `#context.options` 遍历，兼容 `option.name`/`option.label`；返回 boolean。 | **必须**：多个事件（PreFill/OnFill/动物 hook）会重复进入，去重是菜单不重复的唯一保证。 |
| markTest（L153） | 无参；若 `ISWorldObjectContextMenu.setTest` 是函数则 pcall 调用；返回 true。 | **必须**：控制器/菜单发现阶段必须标记"本菜单有选项"，否则手柄与部分 UI 流程拿不到条目。 |
| requestEnter（L160） | player：玩家对象；locoId：机车 id；打印日志并 `sendClientCommand(..., EnterRV, {locoId})`；无返回。 | **必须**：进入动作的意图提交点（不提交坐标）。 |
| requestExit（L168） | player：玩家对象；打印日志并发送 `ExitRV` 空表；无返回。 | **必须**：离开动作的意图提交点。 |
| addExit（L176） | playerNum：槽号；context：菜单；test：发现模式；去重后以 `requestExit` 添加选项，test 时返回 `markTest()`；返回 boolean。 | **必须**：Exit 选项的构造与去重集中一处，OnFill/PreFill 两条路径共用。 |
| addEnter（L190） | playerNum、context、animal、test；不是机车时返回 false，取玩家与 id（缺失返回 false），去重后以 `requestEnter` 添加选项（携带 id）；返回 boolean。 | **必须**：Enter 选项的构造点，明确只传 id 不传坐标。 |
| nearestLocomotive（L205） | 无参；从 `RR.Ride` 取 `MOUNT_REACH`（回退 `C.RV_MOUNT_REACH`、2.0）并 pcall `ride.nearestBoardable(reach)`，仅在结果为表且其 `animal` 是机车时返回该 animal；否则 nil。 | **必须**：Railroader 2.1 的官方 hull 距离可达判定必须复用，不能用中心半径近似（注释 L209-L210）。 |
| nearestLocomotive 中匿名函数（L215） | 无参，捕获 reach，执行 `ride.nearestBoardable(reach)` 并把结果写入外层 record。 | **实现必需**：官方 Ride API 调用需保护，失败等价于"附近无机车"。 |
| Menu.getUtilityMapping（L224） | 无参；校验内部 mapping 后返回其副本（仅 rvId/locoId/generation）或 nil。 | **必须**：对外唯一读取入口，返回副本避免调用方改写模块状态。 |
| Menu.acceptUtilityMapping（L236） | args：`RVUtilityMapping` payload；要求 `ok == true`、onlineId 能在本地解析、rvId/locoId/generation 合法；成功写入 `Menu._rvUtilityMapping` 并返回 true。 | **必须**：断线重连后由服务端创建候选；payload 不携带权限或坐标，不构成授权。 |
| Menu.clearUtilityMapping（L250） | 无参；把 `Menu._rvUtilityMapping` 置 nil；无返回。 | **必须**：连接/断开时清除候选，避免旧映射在新会话继续显示面板入口。 |
| Menu.hasUtilityDashboardCandidate（L254） | player：玩家对象；无有效 mapping 或玩家返回 false；玩家坐标在 RV 区域内返回 true，否则用 `nearestLocomotive()` 的 id 与 mapping.locoId 比对；返回 boolean。 | **必须**：面板入口的可见性判定；两种路径分别覆盖"人在 RV 内"与"人在机车旁"。 |
| nowMs（L264） | 无参；优先 pcall `getTimestampMs` 并 `finiteNumber` 化，失败用 `os.time() * 1000`；返回毫秒。 | **必须**：生成过渡 TTL 需要单调性尚可的时钟；引擎时间戳缺失时必须有回退。 |
| generationTransitionMatches（L282） | pending：过渡记录；args：payload；要求 rvId 一致、generation 相同，token 双方存在时比较 token，否则比较 locoId；返回 boolean。 | **必须**：重复的 FinalRelocate/Relocate 回调必须能识别为同一事务，否则会二次 dismount。 |
| activeGenerationTransition（L297） | 无参；取 `Menu._rvGenerationTransition`，过期则清空并返回 nil，否则原样返回。 | **必须**：TTL 让"未收到结束包"的过渡不会永久抑制后续状态恢复。 |
| localTrainRecord（L307） | locoId：机车 id；从 `RR.TrainEntity.active` 按 `record.id`（缺失时 pcall `record.animal:getAnimalID()`）查找；返回 record 或 nil。 | **必须**：`_boardPending` 是 per-record 的陈旧快照门，必须解析到官方记录对象。 |
| localTrainRecord 中匿名函数（L316） | 无参，捕获 record，执行 `record.animal:getAnimalID()` 并写回 id。 | **实现必需**：record.id 缺失时读取 animal id 可能抛错，必须降级为不匹配。 |
| prepareRideTransition（L328） | args：payload；按 `action` 分派：`generation-failed` 清过渡标记；`enter`/`generation-failed` 时 `ride.dismount(true)`，失败生成时对目标 record 与角色设置 `_boardPending`；`exit` 时对目标 record 与旧的 `ride.current` 设置 `_boardPending` 并通过 Ride 清除本地座位；返回 record。 | **必须**：RV 传送必须与 Railroader 座位状态有序交接，否则 RR_MPClient 的陈旧快照会把玩家放回机车旁。 |
| refreshCurrentSquare（L381） | player：玩家对象；x,y,z：目标坐标；要求 `setCurrentSquareFromPosition` 可用，pcall 调用；返回 boolean。 | **必须**：传送后必须刷新客户端 current square；注释 L379-L380 明确禁止直接写 Java 字段（Kahlua userdata 非表）。 |
| refreshCurrentSquare 中匿名函数（L385） | 无参，捕获 player 与坐标，执行 `player:setCurrentSquareFromPosition(x,y,z)`。 | **实现必需**：官方三参重载可能抛错，失败不能中断 tick。 |
| currentSquareMatches（L391） | player、x,y,z；pcall 读 `getCurrentSquare` 及其坐标并与 `math.floor(x/y/z)` 比较；返回 boolean。 | **必须**：判断 current square 是否已跟上传送目标，决定是否继续刷新。 |
| currentSquareMatches 中匿名函数（L395） | 无参，捕获 player，执行 `player:getCurrentSquare()`。 | **实现必需**：方格代理读取失败必须判定为不匹配，而不是误判成功。 |
| currentSquareMatches 中匿名函数（L397） | 无参，捕获 square，执行 `square:getX()`。 | **实现必需**：坐标读取失败必须判定为不匹配。 |
| currentSquareMatches 中匿名函数（L398） | 无参，捕获 square，执行 `getY()`。 | **实现必需**：同上。 |
| currentSquareMatches 中匿名函数（L399） | 无参，捕获 square，执行 `getZ()`。 | **实现必需**：同上。 |
| playerStillAtTargetSquare（L406） | player、x,y,z；pcall 读玩家精确坐标并整数化；三者缺失返回 nil（未知），否则返回是否仍在目标格。 | **必须**：三态返回区分"未知"与"已离开"，避免在信息不足时误清或误改其它系统的位置状态。 |
| playerStillAtTargetSquare 中匿名函数（L408） | 无参，捕获 player，执行 `player:getX()`。 | **实现必需**：坐标读取失败必须表现为 nil（未知），不能误清或误改其它系统的位置状态。 |
| playerStillAtTargetSquare 中匿名函数（L409） | 无参，捕获 player，执行 `getY()`。 | **实现必需**：同上。 |
| playerStillAtTargetSquare 中匿名函数（L410） | 无参，捕获 player，执行 `getZ()`。 | **实现必需**：同上。 |
| scheduleCurrentSquareRefresh（L422） | player、x,y,z、relation：payload 或 nil；写 `Menu._rvCurrentSquareRefresh{player,x,y,z,ticks,rvId,generation}`，立即刷新一次，匹配则立刻清空；无返回。 | **必须**：把"传送后等待 current square 追上"变成有界、可取消的模块状态。 |
| Menu.onTick（L440） | 无参；无 pending 直接返回；递增 ticks、玩家缺失或超 `CURRENT_SQUARE_REFRESH_TICKS` 清空、玩家死亡清空、玩家已离开目标格清空（不改他人状态）、已匹配清空，否则再刷新一次；无返回。 | **必须**：有界重试是 current square 缓存的唯一驱动；越界与离开检测防止覆盖其它系统的位置状态。 |
| Menu.onTick 中匿名函数（L450） | 无参，捕获 player，执行 `dead = player:isDead()`。 | **实现必需**：死亡检测不能因 API 异常中断 tick。 |
| finishRideTransition（L472） | args：payload；record：火车记录；player：玩家对象；仅在 `ride` 存在、action 为 `exit`/`generation-failed` 且无 `rr.MPClient`（单机）时，用 `ride.mountRecord(record,true,seat)` 恢复座位；无返回。 | **必须**：单机没有官方快照回填，必须走官方 Ride API；多人下 deliberately 不介入（L477-L478 注释）。 |
| validGenerationFinalHint（L485） | args：payload；与 [RV_ContextMenu_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua:14) 同规则：`railroaderTransition == true`、token/locoId/rvId 非空、generation ≥ 1；返回 boolean。 | **必须**：本文件不能依赖 RoomOwnership 的 ctx（两者无组合关系），因此保留第二份实现；提取建议见第 4 节。 |
| Menu.prepareGenerationRelocation（L497） | args：`FinalRelocate` payload；若已有匹配过渡则标记 `finalSeen`、延长 TTL、记录 mapping 并返回 true；否则要求 validGenerationFinalHint，补 `action = "enter"`、记录 mapping、执行 prepareRideTransition 并建立过渡记录；返回 boolean。 | **必须**：被迁移模块以 pcall 调用（Relocation L198-L200），false 会让客户端拒绝执行最终传送。 |
| Menu.prepareGenerationStaging（L531） | args：`Relocate` payload；要求 validGenerationFinalHint；已有匹配过渡直接返回 true；否则 `action = "enter"`、执行 prepareRideTransition 并建立过渡记录；返回 boolean。 | **必须**：staging 阶段是唯一一次 dismount，重复回调必须幂等（Relocation L277-L279 依赖其返回值）。 |
| worldLocomotive（L551） | worldObjects：世界对象表；先试 `nearestLocomotive()`，否则遍历表中对象找机车；返回对象或 nil。 | **必须**：远程 RV 内可能没有"最近可登乘"记录，需要退回点击对象。 |
| Menu.OnFillWorldObjectContextMenu（L561） | playerNum、context、worldObjects、test；无 context/玩家/已死亡直接返回；在 RV 区域内走 addExit，否则走 addEnter（用 worldLocomotive）；返回两个 add 函数的返回值。 | **必须**：世界菜单的正式入口（L698 注册）。 |
| Menu.OnFillWorldObjectContextMenu 中匿名函数（L568） | 无参，捕获 player，执行 `dead = player:isDead()`。 | **实现必需**：与其它回调一致的死亡保护。 |
| Menu.addForAnimal（L579） | playerNum、context、animal、test；非机车或无 context 返回；区域内走 addExit，否则 addEnter；返回 add 函数返回值。 | **必须**：动物菜单路径的公开入口，被官方 BoardMenu 动态字段转调（L662-L664）。 |
| Menu.OnPreFillWorldObjectContextMenu（L595） | playerNum、context、worldObjects、test；无 context/玩家/死亡返回；仅在玩家处于 RV 区域内时添加 Exit；无返回。 | **必须**：空格子右键不会触发 OnFill，Exit 必须在 PreFill 阶段就可用（注释 L589-L594）。 |
| Menu.OnPreFillWorldObjectContextMenu 中匿名函数（L602） | 无参，捕获 player，执行 `dead = player:isDead()`。 | **实现必需**：同一死亡保护。 |
| Menu.OnServerCommand（L611） | module、command、args；仅处理 `RVTeleport`；失败包按 `INVALID_RV_DATA` 显示 halo 并打印原因；成功包校验 onlineId/坐标/z 范围，定位玩家，执行 prepareRideTransition、`teleportTo`、scheduleCurrentSquareRefresh、finishRideTransition；无返回。 | **必须**：Railroader 侧传送与座位过渡的唯一网络入口。 |
| Menu.OnServerCommand 中匿名函数（L621） | 无参，捕获 player 与 message；pcall `setHaloNote(message,255,255,255,5000)`。 | **实现必需**：无效数据提示不可中断命令处理。 |
| Menu.OnServerCommand 中匿名函数（L636） | 无参，捕获 player 与坐标；pcall `player:teleportTo(x,y,z)`。 | **实现必需**：传送失败时必须跳过 current-square 调度与座位收尾。 |
| removeOfficialWorldHook（L643） | 无参；从 `RR.BoardMenu` 取 `OnFill`，存在时用 `Events.OnFillWorldObjectContextMenu.Remove` 摘除；返回是否摘除。 | **必须**：替换 BoardMenu 行为时必须卸掉官方世界菜单钩子，否则会出现两个选项或官方选项。 |
| patchAnimalHook（L655） | 无参；把 `board.addForAnimal` 替换为转调 `Menu.addForAnimal` 并置 `board.rrRVReplaced`，随后摘除官方世界 hook；若 `AnimalContextMenu.doMenu` 未被官方过滤器包装，则以保留 rerail 选项的 wrapper 替换并置 `rrRVWrapped`；无返回。 | **必须**：这是把 RV 选项接入官方动物菜单的最小侵入点，同时保留 Railroader 独立的重上轨选项。 |
| board.addForAnimal（L662，替换的官方动态字段） | playerNum、context、animal、test；转调 `Menu.addForAnimal`；返回其返回值。 | **必须**：RR_AnimalMenuFilter 调用该动态字段，替换字段即可在不改官方过滤器的前提下接管选项。 |
| AnimalContextMenu.doMenu（L676，后备包装） | playerNum、context、animal、test；机车时先加 RV 选项再转调 `rerail.addForAnimal`，否则调用原 `doMenu`；返回原函数返回值或空。 | **保留理由**：仅在官方 `RR_AnimalMenuFilter` 缺席时生效（L672 条件），是兼容旧/无过滤器安装的后备路径；当前 Railroader 2.1 通常走 board 字段路径。 |

### RV_UtilityClient.lua

模块在 [RV_UtilityClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityClient.lua:20) 建立 `RailroaderRV.UtilityClient`，L11-L16 在加载期安装隔离 sprite（失败直接 `error`），L260-L268 注册 `OnServerCommand`/`OnConnected`/`OnDisconnect`，L269 返回 Client。请求只带 operation 与"服务端会重新校验的提示"，requestId 只用于状态关联；snapshot 只写本地显示状态。服务端对应：[RV_UtilityServer.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:118) 的 ACK 与 snapshot 广播、[RV_UtilityStore.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:158) 的 snapshot 形状。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| Client.clearConnectionState（L29） | 无参；重置模块级 `requestSequence`/`sentRequestId`/`sentOperation` 与 `Client.snapshot`，再经全局表 pcall `RailroaderContextMenu.clearUtilityMapping` 与 `UtilityDashboard.onConnectionReset`；无返回。 | **必须**：连接/断开都必须清掉请求关联与 mapping，否则新会话会把旧 ACK 当成本次请求的结果。 |
| text（L45） | key：翻译键；fallback：回退文本；pcall `getText`；返回文本。 | **必须**：反馈文本必须有可读回退。 |
| Client.showFeedback（L55） | player：玩家对象；message：任意可 tostring 的文本；要求 `setHaloNote` 可用并 pcall 调用；返回是否成功。 | **必须**：提交/拒绝/发送失败都需要本地可见反馈，且失败不能中断请求流程。 |
| rejectSend（L61） | player：玩家对象；先尝试 dashboard 的 `onSendFailure`，未被接受时显示 `UI_RailroaderRV_Utility_SendFailed`；返回 `false,nil`。 | **必须**：发送失败的一致返回形状与提示，供所有 request 包装函数直接 return。 |
| localPlayer（L75） | playerNum：槽号；pcall `getSpecificPlayer`；返回玩家对象或 nil。 | **必须**：客户端命令必须绑定本地玩家对象。 |
| nextRequestId（L81） | 无参；递增 `requestSequence` 并返回其字符串形式。 | **必须**：ACK 关联需要单调递增 id，字符串形式与 wire 字段一致。 |
| transmit（L86） | player：玩家对象；payload：请求表；pcall `sendClientCommand(player, C.MOD_ID, C.COMMAND_RV_UTILITY, payload)`；返回是否成功。 | **必须**：唯一的网络发送点，保证所有操作走同一模块与命令。 |
| hintForObject（L93） | object：世界对象；要求对象有 `getSquare`/`getObjectIndex`，pcall 读取方格坐标与对象索引；返回 `{x,y,z,objectIndex}` 或 nil。 | **必须**：水槽连接需要服务端可重新解析的目标提示；索引不可读时必须拒绝而不是发送空提示。 |
| hintForObject 中匿名函数（L96） | 无参，捕获 object，执行 `object:getSquare()`。 | **实现必需**：任一读取失败都必须让提示整体为 nil。 |
| hintForObject 中匿名函数（L98） | 无参，捕获 square，执行 `square:getX()`。 | **实现必需**：同上。 |
| hintForObject 中匿名函数（L99） | 无参，捕获 square，执行 `getY()`。 | **实现必需**：同上。 |
| hintForObject 中匿名函数（L100） | 无参，捕获 square，执行 `getZ()`。 | **实现必需**：同上。 |
| hintForObject 中匿名函数（L101） | 无参，捕获 object，执行 `object:getObjectIndex()`。 | **实现必需**：对象索引是服务端重新解析目标的必要提示，读不到就不能发送。 |
| hintForItem（L106） | item：物品对象；要求 `getID` 可用并 pcall 读取；返回 `{itemId = id}` 或 nil。 | **必须**：加油/加电池/安装组件需要物品身份提示（服务端仍会重新定位物品）。 |
| hintForItem 中匿名函数（L108） | 无参，捕获 item，执行 `item:getID()`。 | **实现必需**：物品 id 读取失败必须阻止发送。 |
| Client.send（L112） | player、operation：操作名、targetHint：目标提示表或 nil、sourceHint：来源提示表或 nil；生成 requestId 与 payload，发送失败走 rejectSend；成功时记录 `sentRequestId/sentOperation` 并尝试 dashboard `onRequestSent`，未接受则显示已提交提示；返回 `true,requestId` 或 `false,nil`。 | **必须**：本模块唯一的请求装配与状态登记点，所有语义化 request 函数都收敛到这里。 |
| Client.requestAddFuel（L133） | player、item：燃料物品；先取物品提示，缺失返回 `false,nil`；否则以 `U.OP_ADD_FUEL` 发送；返回 send 的结果。 | **必须**：加油是当前面板与世界菜单都需要的操作。 |
| Client.requestAddBattery（L139） | player、item：电池物品；语义同上，操作为 `U.OP_ADD_BATTERY`。 | **必须**：电池安装入口。 |
| Client.requestInstallComponent（L145） | player、operation：`U.OP_INSTALL_CHARGER` 或 `U.OP_INSTALL_INVERTER`、item：组件物品；取提示后发送；返回 send 结果。 | **必须**：两个安装操作只有 operation 不同，合并为一个函数是当前最小的实现。 |
| Client.requestRemoveBattery（L151） | player、batteryId：快照中电池 id；以 `targetHint = {batteryId}` 发送 `U.OP_REMOVE_BATTERY`；返回 send 结果。 | **必须**：移除已安装电池只能按 snapshot id 寻址。 |
| Client.requestPowerOperation（L156） | player、operation：电力操作名；无提示发送；返回 send 结果。 | **必须**：面板的启停/移除充放电组件共用入口。 |
| Client.requestRefreshDevices（L160） | player：玩家对象；以 `U.OP_REFRESH_DEVICES` 无提示发送；返回 send 结果。 | **必须**：设备缓存刷新是服务端重扫的唯一触发方式。 |
| Client.requestSnapshot（L166） | player：玩家对象；生成新 requestId 并以 `U.OP_REQUEST_SNAPSHOT` 直接 transmit，不登记 pending；返回 `true` 或 rejectSend 的结果。 | **必须**：只读刷新不应占用唯一 pending 关联（注释 L164-L165），否则会顶掉正在等待的操作回执。 |
| Client.requestWaterConnection（L173） | player、object：水槽对象、connected：布尔目标状态；非布尔或缺对象提示时走 rejectSend；把 `connected` 并入提示后发送 `U.OP_CONNECT_WATER_DEVICE`；返回 send 结果。 | **必须**：连接/断开是同一命令的两个布尔方向，非法布尔必须本地拒绝。 |
| Client.isRequestPending（L185） | requestId：字符串；返回是否等于当前 pending id。 | **必须**：面板关闭时用它判断是否需要提示"仍在等待服务端"。 |
| showInvalidRVData（L189） | player：玩家对象；要求 `setHaloNote` 可用，优先翻译 `UI_RailroaderRV_InvalidRVData`，pcall 显示 5000ms；无返回。 | **必须**：服务端 `REASON_INVALID_RV_DATA` 拒绝必须有统一可见提示。 |
| showInvalidRVData 中匿名函数（L200） | 无参，捕获 player 与 message；pcall `player:setHaloNote(message,255,255,255,5000)`。 | **实现必需**：提示失败不能中断命令处理。 |
| Client.onServerCommand（L206） | module、command、args；`RVUtilityMapping`→转 `RailroaderContextMenu.acceptUtilityMapping`；`RVUtilitySnapshot`→写 `Client.snapshot` 并转 dashboard `onSnapshot`；`RVUtilityAck`→仅接受与 `sentRequestId` 相同的 requestId，清 pending 后转 dashboard `onAck`，未显示时按 ok/connected/reason 组文案反馈，`REASON_INVALID_RV_DATA` 时额外提示；无返回。 | **必须**：唯一的服务端消息入口，同时承担 requestId 关联与回退反馈。 |
| Client.getSnapshot（L258） | 无参；返回 `Client.snapshot`（原表引用）。 | **必须**：面板与菜单需要读取最近一次快照；当前返回内部表引用，调用方只读（见第 5 节）。 |

### RV_UtilityContextMenu.lua

模块在 [RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:11) 建立 `RailroaderRV.UtilityContextMenu`，L197-L208 注册三个菜单事件，L210 返回 Menu。它复用 shared 的 [RV_UtilityCatalog.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/Water/RV_UtilityCatalog.lua) 与 [RV_RegionSlots.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RVMapping/RV_RegionSlots.lua) 公开函数，不直接读它们的内部状态。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| text（L15） | key：翻译键；fallback：回退文本；pcall `getText`；返回文本。 | **必须**：菜单标签的本地化回退。 |
| localPlayer（L26） | playerNum：槽号；pcall `getSpecificPlayer`；返回玩家对象或 nil。 | **必须**：菜单回调需要本地玩家对象。 |
| already（L32） | context：菜单对象；label：选项文本；按 `numOptions`（或 `#options`）遍历并兼容 `option.name`/`option.label`；返回 boolean。 | **必须**：PreFill 与 OnFill 都会加同一批选项，去重是避免重复菜单项的唯一保证。 |
| addFuelOption（L44） | player：玩家对象；item：燃料物品；转调 `Client.requestAddFuel`；无返回（丢弃结果）。 | **必须**：物品菜单选项的回调适配，必须与 `addOption` 的调用约定一致。 |
| dashboardOption（L48） | player：玩家对象；先 `Dashboard.show(player)` 再 `Client.requestSnapshot(player)`；无返回。 | **必须**：打开面板时立即用新快照刷新，否则会显示上一次 mapping 的残留数值。 |
| hasPipeWrench（L53） | player：玩家对象；要求 `getInventory` 可用，pcall 取 inventory 并 pcall `contains("Base.PipeWrench")`；返回 boolean（严格 `== true`）。 | **必须**：水槽连接需要管钳；这个本地检查只是菜单可见性，服务端仍会重新校验工具（注释 L1-L2）。 |
| setWaterConnection（L61） | player、object：水槽对象、connected：布尔；转调 `Client.requestWaterConnection`；返回 `true,requestId` 或 `false`。 | **必须**：把菜单回调签名适配到请求函数，并把 requestId 透出给需要它的调用方。 |
| localSlot（L67） | player：玩家对象；x,y,z：目标方格坐标；pcall 读取玩家坐标，再遍历 `RegionSlots.COUNT` 个槽，要求玩家与目标同时落在同一槽的 XY 半开区间与 z 管理区间；返回 slotIndex 或 nil。 | **必须**：水槽 tag 必须与"玩家所在 RV 槽"一致才允许操作，这是本地防串槽检查。 |
| addWaterOptions（L92） | player、context：菜单、worldObjects：世界对象表；无管钳直接返回；对每个 `Catalog.hasFluidContainer` 对象读取方格坐标、连接状态与 tag，要求 slot 匹配、tag 合法、已连接或本身是管道设备，去重后按当前状态添加连接/断开选项；无返回。 | **必须**：水槽选项的完整可见性规则，包含对象身份、槽一致性与连接状态三重要求。 |
| addDashboardOption（L131） | player、context；经全局表取 `RailroaderContextMenu.hasUtilityDashboardCandidate` 并 pcall 判定，未通过直接返回；去重后添加面板选项；无返回。 | **必须**：面板入口的可见性由 mapping 候选决定，本函数只做菜单适配。 |
| Menu.onPreFillWorldObjectContextMenu（L149） | playerNum、context、worldObjects、test；无 context 返回；有玩家时添加面板选项；无返回。 | **必须**：空格子右键不会触发 OnFill，面板入口必须在 PreFill 就可用。 |
| Menu.onFillWorldObjectContextMenu（L157） | playerNum、context、worldObjects、test；无 context 或 worldObjects 非表返回；添加面板与水槽选项；无返回。 | **必须**：世界菜单的水槽操作入口。 |
| Menu.onFillInventoryObjectContextMenu（L165） | playerNum、context、items：物品表；遍历物品，找到含 `Fluid.Petrol` 的流体容器后添加加油选项并返回；无返回。 | **必须**：加油操作从物品菜单发起；`return` 保证每个菜单只加一个加油项。 |
| Menu.onFillInventoryObjectContextMenu 中匿名函数（L172） | 无参，捕获 item，执行 `item:getFluidContainer()`。 | **实现必需**：物品不一定是容器，读取可能抛错。 |
| Menu.onFillInventoryObjectContextMenu 中匿名函数（L180） | 无参，捕获 container 与 `Fluid.Petrol`，执行 `container:contains(fluid.Petrol)`。 | **实现必需**：容器类型不匹配时 `contains` 可能抛错，必须降级为"不是燃料容器"。 |

### RV_UtilityDashboard.lua

模块在 [RV_UtilityDashboard.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:12) 建立 `RailroaderRV.UtilityDashboard`，L124-L470 在 `ISCollapsableWindow` 可用时派生窗口类 `RVUtilityDashboardWindow`，L582 返回 Dashboard。所有显示值来自服务端 snapshot；所有操作都经 [RV_UtilityClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityClient.lua:112) 提交。snapshot 字段形状来自 [RV_UtilityStore.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:158) 与 [RV_UtilityServer.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:130)。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| tr（L15） | key：翻译键；fallback：回退文本；`getText` 不可用或返回键名时用 fallback；返回文本。 | **必须**：面板文本量大，必须有统一回退。 |
| number（L21） | value：任意值；number 直接返回、string 用 `tonumber`；返回 number 或 nil（不接受 Java 代理）。 | **保留理由**：snapshot 是服务端 plain-data 表，数值已是 Lua number/string；与 BoundaryClient.number 的代理兼容分支用途不同，合并会引入不必要的 pcall 成本。 |
| display（L27） | value：任意值；digits：小数位数（默认 1）；不可数值化时返回 `"-"`（nil）或 `tostring`，否则 `string.format`；返回字符串。 | **必须**：所有数值展示共用的格式化与占位规则。 |
| ratio（L33） | amount、capacity：数值；不可用或 capacity ≤ 0 返回 0，否则 clamp 到 [0,1]；返回 number。 | **必须**：进度条比例必须防御除零与越界。 |
| mappingKey（L39） | value：任意值；要求表中 `rvId`/`generation` 非 nil；返回 `"rvId:generation"` 或 nil。 | **必须**：面板与快照的代次匹配键；跨 RV 的旧快照必须被忽略。 |
| utilityMapping（L45） | 无参；经全局表调用 `RailroaderContextMenu.getUtilityMapping`；返回 mapping 或 nil。 | **必须**：面板需要当前 mapping 计算自身 mappingKey。 |
| collectionItems（L54） | collection：Java 集合或 Lua 表；对有 `size`/`get` 的集合按 0..size-1 复制，否则用 `pairs` 复制为数组；返回数组。 | **必须**：库存枚举必须同时支持 B42 的 Java 容器与 Lua 表。 |
| collectionItems 中匿名函数（L58） | 无参，捕获 collection，执行 `collection:size()`。 | **实现必需**：集合 API 抛错时必须返回已收集的部分而不是中断。 |
| collectionItems 中匿名函数（L61） | 无参，捕获 collection 与 index，执行 `collection:get(index)`。 | **实现必需**：单个元素读取失败必须跳过而不是放弃整份库存。 |
| inventoryItems（L73） | inventory：物品容器；result：输出数组；seen：已访问集合（防止背包递归环）；把 `getItems()` 展平并把带 `getInventory` 的物品递归进去；无返回（结果写入 result）。 | **必须**：容器内物品（背包/工具箱）也算候选，递归必须有环检测。 |
| inventoryItems 中匿名函数（L76） | 无参，捕获 inventory，执行 `inventory:getItems()`。 | **实现必需**：容器枚举失败时必须放弃该容器的嵌套扫描而不中断整份库存。 |
| inventoryItems 中匿名函数（L80） | 无参，捕获 item，读取 `item.getInventory` 属性。 | **实现必需**：非容器物品的属性读取可能抛错，必须降级为"无嵌套容器"。 |
| inventoryItems 中匿名函数（L82） | 无参，捕获 item，执行 `item:getInventory()`。 | **实现必需**：嵌套容器读取失败不能让整份库存候选列表失败。 |
| itemType（L88） | item：物品对象；pcall `getFullType`；返回字符串（失败为 `""`）。 | **必须**：组件/电池识别依赖 full type。 |
| itemType 中匿名函数（L89） | 无参，捕获 item，执行 `item:getFullType()`。 | **实现必需**：类型读取失败必须降级为空串而不是中止枚举。 |
| itemName（L93） | item：物品对象；pcall `getName`，失败回退 itemType；返回字符串。 | **必须**：菜单标签需要可读名称。 |
| itemName 中匿名函数（L94） | 无参，捕获 item，执行 `item:getName()`。 | **实现必需**：名称读取失败时回退到类型名。 |
| fluidFuel（L98） | item：物品对象；要求 `Fluid.Petrol` 全局存在、容器 `contains(Petrol)` 为真、`isMixture()` 为假且 `getAmount() > 0`；返回数量或 nil。 | **必须**：加油候选筛选规则；混合物与空容器不能当燃料提交。 |
| fluidFuel 中匿名函数（L99） | 无参，捕获 item，执行 `item:getFluidContainer()`。 | **实现必需**：非流体物品的读取会失败，必须降级为"不是燃料容器"。 |
| fluidFuel 中匿名函数（L102） | 无参，捕获 container 与 `Fluid.Petrol`，执行 `container:contains(fluid.Petrol)`。 | **实现必需**：容器类型不匹配时 `contains` 可能抛错。 |
| fluidFuel 中匿名函数（L103） | 无参，捕获 container，执行 `container:isMixture()`。 | **实现必需**：混合物判定失败必须视为不可用燃料。 |
| fluidFuel 中匿名函数（L104） | 无参，捕获 container，执行 `container:getAmount()`。 | **实现必需**：数量读取失败必须视为空容器。 |
| batteryType（L110） | fullType：类型字符串；匹配 `Base.CarBattery`/`CarBattery1..3`；返回 boolean。 | **必须**：电池候选识别（与车辆电池共用 base 类型）。 |
| setSubmitted（L115） | window：面板实例；sent：发送是否成功；requestId：请求 id；写 `window.operationRequestId`/`operationStatus` 并调用 `setStatus`；无返回。 | **必须**：所有按钮的统一提交状态显示，避免每个按钮各写一套文案。 |
| Window:createChildren（L127） | self：面板实例；调用父类 createChildren，创建 9 个标签、2 个进度条与 9 个按钮（含 generator 按钮引用）；无返回。 | **必须**：面板控件的唯一构建点。 |
| Window:createChildren 内嵌 label（L133） | x,y：位置；w：宽度；value：文本；创建 `ISLabel`、initialise、设宽、挂到面板；返回控件。 | **实现必需**：createChildren 内的局部构造 helper，只服务本函数。 |
| Window:createChildren 内嵌 bar（L141） | y：纵坐标；color：进度条颜色表；创建 `ISProgressBar`、initialise、设色、挂到面板；返回控件。 | **实现必需**：同上。 |
| Window:setStatus（L209） | self；value：任意文本；`statusLabel` 存在时用 `setNameWithoutMoving` 更新；无返回。 | **必须**：状态行的唯一更新入口。 |
| Window:request（L213） | self；operation：电力操作名；调用 `Client.requestPowerOperation(self.player, operation)` 并交给 setSubmitted；无返回。 | **必须**：无参数电力操作的统一提交路径。 |
| Window:openInventoryMenu（L217） | self；predicate：物品筛选函数；callback：`(player,item)` 提交函数；emptyLabel：空态文本；取玩家与 `ISContextMenu`，展平库存、按谓词生成选项（回调内 `setSubmitted`），无候选时加不可用占位项；无返回。 | **必须**：加油/加电池/安装组件的共用候选菜单，包含空态反馈。 |
| Window:openInventoryMenu 中匿名函数（L224） | 无参，捕获 player，执行 `player:getInventory()`。 | **实现必需**：库存读取失败必须给出状态提示而不是抛错。 |
| Window:openInventoryMenu 中匿名函数（L236） | window：菜单回调传入的面板实例；执行 `setSubmitted(window, callback(window.player, candidate))`。 | **必须**：把菜单选择转换为"提交 + 状态显示"，是选项回调的适配点。 |
| Window:openBatteryRemovalMenu（L247） | self；从 `Client.getSnapshot()` 取 `power.batteries`，用 `ISContextMenu` 为每个电池生成 `#id type 电量/上限` 选项（回调发 `requestRemoveBattery`），无电池时加不可用占位项；无返回。 | **必须**：移除电池只能按服务端快照的电池 id 选择。 |
| Window:openBatteryRemovalMenu 中匿名函数（L262） | window：菜单回调传入的面板实例；执行 `Client.requestRemoveBattery(window.player, id)` 并交给 setSubmitted。 | **必须**：把快照 id 转成移除请求。 |
| Window:onAddFuel（L274） | self；以 `fluidFuel` 为谓词、`Client.requestAddFuel` 为回调打开库存菜单；无返回。 | **必须**：面板加油按钮。 |
| Window:onAddFuel 中匿名函数（L275） | item：候选物品；谓词 `fluidFuel(item) ~= nil`，返回 boolean。 | **实现必需**：菜单工厂要求谓词函数表达式，燃料筛选只在这里表达。 |
| Window:onAddFuel 中匿名函数（L276） | player：玩家对象；item：选中物品；转调 `Client.requestAddFuel`，返回其结果。 | **实现必需**：菜单工厂要求提交回调函数表达式。 |
| Window:onAddBattery（L280） | self；以 `batteryType(itemType(item))` 为谓词、`Client.requestAddBattery` 为回调打开库存菜单；无返回。 | **必须**：面板加电池按钮。 |
| Window:onAddBattery 中匿名函数（L281） | item：候选物品；谓词 `batteryType(itemType(item))`，返回 boolean。 | **实现必需**：电池筛选规则只在谓词内表达。 |
| Window:onAddBattery 中匿名函数（L282） | player、item：选中物品；转调 `Client.requestAddBattery`，返回其结果。 | **实现必需**：提交回调函数表达式。 |
| Window:onRemoveBattery（L286） | self；转调 `openBatteryRemovalMenu`；无返回。 | **必须**：按钮与菜单构造分离。 |
| Window:onInstallCharger（L290） | self；谓词匹配 `RailroaderRV.RVCharger`，回调以 `U.OP_INSTALL_CHARGER` 调 `Client.requestInstallComponent`；无返回。 | **必须**：充电器安装入口。 |
| Window:onInstallCharger 中匿名函数（L291） | item：候选物品；跨行谓词闭包，要求 `itemType(item) == "RailroaderRV.RVCharger"`。 | **实现必需**：组件筛选按 full type 精确匹配，不能放宽到名称。 |
| Window:onInstallCharger 中匿名函数（L293） | player、item：选中物品；跨行回调闭包，以 `U.OP_INSTALL_CHARGER` 调 `Client.requestInstallComponent`。 | **实现必需**：提交回调函数表达式。 |
| Window:onInstallInverter（L298） | self；谓词匹配 `RailroaderRV.RVInverter`，回调以 `U.OP_INSTALL_INVERTER` 调 `requestInstallComponent`；无返回。 | **必须**：逆变器安装入口。 |
| Window:onInstallInverter 中匿名函数（L299） | item：候选物品；跨行谓词闭包，要求 `itemType(item) == "RailroaderRV.RVInverter"`。 | **实现必需**：逆变器筛选规则。 |
| Window:onInstallInverter 中匿名函数（L301） | player、item：选中物品；跨行回调闭包，以 `U.OP_INSTALL_INVERTER` 调 `Client.requestInstallComponent`。 | **实现必需**：提交回调函数表达式。 |
| Window:onRemoveCharger（L306） | self；`self:request(U.OP_REMOVE_CHARGER)`；无返回。 | **必须**：拆除充电器入口。 |
| Window:onRemoveInverter（L310） | self；`self:request(U.OP_REMOVE_INVERTER)`；无返回。 | **必须**：拆除逆变器入口。 |
| Window:onGeneratorToggle（L314） | self；从快照读 `power.generatorEnabled`，据此选择 `U.OP_STOP_GENERATOR`/`U.OP_START_GENERATOR` 提交；无返回。 | **必须**：发电机按钮必须按最近快照决定方向，不能由客户端维护开关状态。 |
| Window:onRefreshDevices（L321） | self；`setSubmitted(self, Client.requestRefreshDevices(self.player))`；无返回。 | **必须**：设备刷新入口。 |
| Window:refresh（L325） | snapshot：可选快照；为空时取 `Client.getSnapshot()`，mappingKey 不匹配则丢弃；无 power 时把全部标签/进度条置为占位态并返回；否则渲染燃料、电池、发电机/回路/负载/发电、限值、效率、预计续航、设备数、电池清单、水务统计与发电机按钮标题，并在无本地操作状态时显示"已更新"；无返回。 | **必须**：面板渲染的唯一实现；mappingKey 门是防止跨 RV 旧数据污染的关键。 |
| Window:close（L448） | self；若仍有 pending 请求则提示"面板关闭但仍在等待服务端"，隐藏窗口并在自己是当前实例时清空 `Dashboard.instance`；无返回。 | **必须**：关闭窗口不能把未回执的操作静默丢弃，也不能留下悬空实例引用。 |
| Window:new（L458） | x,y：屏幕坐标；player：玩家对象；调用父类构造 620x540，设 metatable、player、`mappingKey`（构造时快照）、清空操作状态、禁用缩放、设标题；返回实例。 | **必须**：窗口工厂；mappingKey 必须在打开时绑定当前 RV 代次。 |
| Dashboard.format（L472） | snapshot：快照表；无 power 时返回等待文本，否则返回 `Battery x / y Wh`；返回字符串。 | **保留理由**：当前 GUI 目录内无调用者，是面板外的紧凑状态文本 API（例如外部 HUD/调试调用）；删除前需确认无外部消费者。 |
| Dashboard.refresh（L482） | snapshot：快照表；实例存在且可 refresh 时转调；无返回。 | **必须**：模块级刷新入口，供 UtilityClient 与自身 show 使用。 |
| Dashboard.onConnectionReset（L488） | 无参；取实例并清空 `Dashboard.instance`，实例存在时隐藏并从 UI 管理器移除；无返回。 | **必须**：断线时窗口必须消失，否则新会话里会残留旧数据窗口。 |
| localPlayer（L496） | player：玩家对象或 nil；为空时 pcall `getSpecificPlayer(0)`；返回玩家对象或 nil。 | **必须**：Dashboard.show 允许无参调用，需要槽 0 回退。 |
| Dashboard.show（L503） | player：玩家对象或 nil；无窗口类或无玩家返回 false；已有实例则置顶、更新 player 与 mappingKey、显示并 refresh；否则按屏幕尺寸居中创建、initialise、加入 UI 管理器、保存实例并 refresh；返回 true/false。 | **必须**：面板入口，同时负责实例复用与重绑定当前 player/mapping。 |
| Dashboard.onSnapshot（L524） | player：玩家对象；snapshot：快照表；要求实例存在、可见、player 相同且 snapshot 与实例 mappingKey 一致，然后 `Dashboard.refresh`；返回 boolean 是否消费。 | **必须**：UtilityClient 回调的第一个消费者；返回 false 让客户端走通用反馈，避免吞掉提示。 |
| Dashboard.onRequestSent（L533） | player：玩家对象；requestId：字符串；要求实例存在、可见且 player 匹配，然后记录 requestId 与提交文案；返回 boolean。 | **必须**：请求提交状态必须与实例绑定，否则会把别人的请求显示成本面板的状态。 |
| Dashboard.onSendFailure（L545） | player：玩家对象；要求实例存在、可见且 player 匹配，清 requestId 并显示拒绝文案；返回 boolean。 | **必须**：发送失败必须清掉 pending，否则 `isRequestPending` 会长期为真。 |
| Dashboard.onAck（L557） | player：玩家对象；ack：服务端回执；operation：原操作名；要求实例存在、可见、player 匹配、ack 是表且 `ack.requestId == instance.operationRequestId`；清 requestId 后按 ok/水管/其它/reason 生成状态文案；返回 boolean。 | **必须**：回执关联与文案的最终落点；requestId 不匹配必须返回 false 让客户端回退提示。 |

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **安全方法调用包装重复 4 份，应提取**：[RV_BoundaryClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_BoundaryClient.lua:32) 的 `call` 返回 4 个值，[RV_BoundaryWallVisuals.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_BoundaryWallVisuals.lua:25) 与 [RV_ProtectedDemolition.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ProtectedDemolition.lua:18) 返回 3 个值，[RV_WardrobeVisuals.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_WardrobeVisuals.lua:20) 返回 2 个值并丢弃错误对象。语义差异只在"是否透出 pcall 错误值"，调用方全部只用首值或 `ok` 标志。**提取净收益为正**：可消除 4 份重复的 `type(target[method]) ~= "function"` 前置判断与异常边界，且必须显式固定统一返回形状（建议 `ok, a, b, c`）；成本是一个 shared/客户端通用模块与加载顺序，收益随下一次修改这 4 个文件而兑现。
- **本地化 `text`/`tr` 重复 4 份，应提取**：[RV_RailroaderContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:21)、[RV_UtilityClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityClient.lua:45)、[RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:15)、[RV_UtilityDashboard.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:15) 四份实现规则相同（`getText` 不可用、返回空串或返回键名时用 fallback）。**提取净收益清晰**，且四处的失败语义一致，不存在需要保留的策略差异。
- **本地玩家解析重复 3+3 份，建议提取两个明确语义的函数**：按槽号取玩家出现在 RailroaderContextMenu（L28）、UtilityClient（L75）、UtilityContextMenu（L26）；按 onlineId 取玩家出现在 BoundaryClient（L49，带 getPlayerNum 回退）、RoomOwnership（L23，无全局 API 保护）、RailroaderContextMenu（L34，带 `onlineId == 0` 单机回退）。**语义差异真实存在**（单机回退、API 缺失保护、回退到槽号），因此提取时不能合并成一个宽松实现，而应提供 `playerForSlot(playerNum)` 与 `playerForOnlineId(id, options)` 两个带明确选项的入口。**净收益中等偏高**：identity 解析是本层最容易出现行为漂移的地方。
- **菜单去重规则重复 2 份，应提取**：[RV_RailroaderContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:139) 的 `optionAlreadyExists` 与 [RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:32) 的 `already` 规则等价（都兼容 `name`/`label` 与 `numOptions`），只是写法不同。**提取净收益为正**（规则必须一致，否则同一个菜单里两个模块的去重结果会不同）。
- **无效 RV 数据提示重复 3 处，应提取单一 notifier**：[RV_ProtectedDemolition.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ProtectedDemolition.lua:63) 的 `showInvalidRVData`、[RV_UtilityClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityClient.lua:189) 的 `showInvalidRVData` 逻辑逐字相同（同一翻译键、同一 5000ms、同一英文回退），[RV_RailroaderContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:619) 还在 OnServerCommand 内联了同一段。**提取净收益高**：提示文案与时长是跨模块的用户可见合同，三份实现存在漂移风险。
- **模板身份几何重复 3 处，建议下沉到 shared 的几何模块**：BoundaryWallVisuals（L78-L82）、WardrobeVisuals（L82-L88）、ProtectedDemolition（L168-L172）都执行同一对调用 `TemplateGeometry.templateAnchorForWorld` + `worldToTemplate` 得到模板偏移。可以在 [RV_TemplateGeometry.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_TemplateGeometry.lua:72) 增加 `offsetForWorld(x,y,z)` 一次返回 `anchor, world, offset`。**净收益中等**：三处都是 3 行，但偏移推导与锚点规则属于几何所有权，放在 3 个 client 文件里会让共享几何的改动需要三处同步。
- **tag 读取前缀重复 3 处，只能提取"公共前缀"**：三个身份 validator 都以 `getModData().RailroaderRV` 开始，校验 owner/rvId/generation（BoundaryWallVisuals L42-L52、WardrobeVisuals L48-L61、ProtectedDemolition L191-L218）。但后续语义 **必须保持不同**：ProtectedDemolition 对非表 tag 与字段非法走 fail-closed 拒绝并提示，两个 Visuals 只静默返回 false。因此应提取的是"读取并做 owner/rvId/generation 基础校验，返回 tag 或原因"的窄函数，**不要**合并成单一的 strict/loose 函数；否则会把"数据损坏要提示并拦截"降级成"静默跳过"。**净收益中等**：减少字段名漂移，同时保留两套失败语义。
- **渲染隐藏与标脏重复 2 份，应提取**：[RV_BoundaryWallVisuals.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_BoundaryWallVisuals.lua:85) 与 [RV_WardrobeVisuals.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_WardrobeVisuals.lua:94) 的 `hide*` 函数体除告警前缀外逐字相同（setDoRender→复读→取 `FBORenderChunk.DIRTY_REDRAW`→invalidate→warnOnce）。**提取净收益高**：这段行为必须完全一致，两处独立实现没有任何正当差异。
- **current-square 追赶逻辑重复 2 份，建议提取"调度 + 判定"部分**：RailroaderContextMenu 的 `scheduleCurrentSquareRefresh`/`currentSquareMatches`/`refreshCurrentSquare`/`playerStillAtTargetSquare`（L381-L438、L440-L470）与 Relocation 的 current-square 匹配与 ACK 逻辑（L137-L145、L377-L421）。两者语义差异真实：前者只维护本地显示缓存（可放弃），后者是服务器等待的事务证明（必须 ACK）。可提取的是"刷新并验证 current square"的低层 helper（含三态 `playerStillAtTargetSquare`），ACK/状态清理留在各自模块。**净收益中等**：两处 pcall/floor 比较规则必须一致，否则会出现"一边认为到了、一边认为没到"的分歧。
- **`validGenerationFinalHint` 逐字重复 2 份，应提取一份**：[RV_ContextMenu_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua:14) 与 [RV_RailroaderContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:485) 的 8 个条件完全相同。二者都必须与服务端 FinalRelocate payload（[RV_Server_PlayerValidation.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_PlayerValidation.lua:240)）保持同步，**双份实现是明确的漂移风险**；提取到 shared 或（更小成本地）让迁移模块直接复用 RoomOwnership 已写入 `ctx` 的那一份即可，**净收益高、成本极低**。
- **不建议提取的部分**：各文件的身份 validator 主体（角色集合、live 对象属性、几何偏移）用途不同；`ProtectedDemolition` 的模板静态身份比对（L98-L153）包含 class/direction/north 与诊断分支，只有它自己使用；utility 与 relocation 的 wire payload 消费形状不同（见第 5 节），不应合并成一个"通用 payload 校验器"。

### 是否进一步拆分

- **RV_RailroaderContextMenu.lua（719 行、69 函数）是首要评估对象，但当前不建议拆**。文件内已有三个内聚块：utility mapping（L95-L262）、Ride/生成过渡与 current-square 追赶（L264-L549）、官方菜单与 hook patching（L551-L717）。可拆边界是 `RV_RailroaderRideAdapter`（prepareRideTransition/localTrainRecord/finishRideTransition/prepareGenerationRelocation/prepareGenerationStaging）与"菜单 + mapping"两部分。**成本**：迁移模块以 pcall 全局查找调用 `prepareGenerationRelocation`/`prepareGenerationStaging`（Relocation L193-L200、L273-L285），UtilityClient 调用 `acceptUtilityMapping`/`clearUtilityMapping`（L36、L211），UtilityContextMenu 调用 `hasUtilityDashboardCandidate`（L138），拆分会把这些点变成跨文件合同，需要一次性明确接口；**收益**：Railroader 官方字段假设集中在一个文件其实降低了版本耦合面。**建议**：等 Railroader 官方提供公开 seat/menu API 或本文件继续增长时再拆，优先把"官方表访问"集中为一个内部小节而不是拆文件。
- **RV_UtilityDashboard.lua（582 行、63 函数）是第二候选**。窗口构建/渲染（L124-L470）与库存候选扫描/物品判定（L54-L113、L217-L245）是两种职责，可拆出 `RV_UtilityItemScan`（collectionItems/inventoryItems/itemType/itemName/fluidFuel/batteryType）。**成本**：候选谓词与 `setSubmitted`/window 状态共享，拆后需要用回调注入提交函数；**收益**：库存递归与物品分类是唯一与 PZ 物品 API 强耦合的部分，独立后更容易替换。**建议**：若后续要支持更多组件类型（充电器/逆变器之外的设备）就拆，否则保留。
- **RV_ContextMenu_Relocation.lua（454 行、25 函数）：不建议拆**。普通 `Relocate` 两阶段与 `FinalRelocate` 事务共享 `Events.OnServerCommand`、`Events.OnTick`、`ctx.clientTick` 与玩家查找；拆开后必须把 `pendingFinalRelocation` 提升为显式接口，接口成本高于当前单文件内的清晰分区（L83-L179 为最终事务，L181-L325 为分派，L327-L422 为 tick 驱动）。
- **RV_ContextMenu_RoomOwnership.lua（292 行、28 函数）：不建议拆**。payload gate（L34-L59）、扫描执行（L96-L134）、调度（L187-L202）、guard 生命周期（L204-L282）围绕同一张 guard 表，且只通过 7 个 ctx 导出与迁移模块协作，边界已经清晰。
- **其余 7 个文件均为单一职责，不建议拆分**：RV_BoundaryClient（网络纠正）、RV_BoundaryWallVisuals / RV_WardrobeVisuals（两个身份各异的渲染隐藏）、RV_ProtectedDemolition（拆除拦截）、RV_UtilityClient（意图传输 + 只读缓存，二者共享 requestId 状态，拆开需要额外接口）、RV_UtilityContextMenu（菜单项构造）、RV_ContextMenu（0 函数的薄组合根，应保持最小）。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **`RailroaderRV.Client`**（由 [RV_ContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:20) 建立、L73 返回）：`requestGenerate`（Relocation L24）、`requestTemplateCapture`（L33）、`onFillWorldObjectContextMenu`（L39）、`onServerCommand`（L181）、`onTick`（L327）。其中只有 `onServerCommand`/`onTick` 在模块内注册为事件处理器；全树搜索没有任何其它文件读取 `RailroaderRV.Client`，三个请求函数也**没有任何注册点**。
- **`RailroaderRV.BoundaryClient`**（[RV_BoundaryClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_BoundaryClient.lua:9)）：`onCorrection`、`onServerCommand` 与下划线字段 `_states`。事件在模块内注册；除本文件外无消费者（见下）。
- **`RailroaderRV.RailroaderContextMenu`**（[RV_RailroaderContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:11)）：公开方法 `getUtilityMapping`、`acceptUtilityMapping`、`clearUtilityMapping`、`hasUtilityDashboardCandidate`、`onTick`、`prepareGenerationRelocation`、`prepareGenerationStaging`、`OnFillWorldObjectContextMenu`、`addForAnimal`、`OnPreFillWorldObjectContextMenu`、`OnServerCommand`；另暴露 `_rvUtilityMapping`、`_rvGenerationTransition`、`_rvCurrentSquareRefresh`、`_rvCurrentSquareRefreshHook` 四个状态字段。实际消费者：UtilityClient（L36、L211）、UtilityDashboard（L48）、UtilityContextMenu（L138）、Relocation（L193-L200、L273-L285）。
- **`RailroaderRV.UtilityClient`**（[RV_UtilityClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityClient.lua:20)，L269 返回）：`clearConnectionState`、`showFeedback`、`send`、`requestAddFuel`、`requestAddBattery`、`requestInstallComponent`、`requestRemoveBattery`、`requestPowerOperation`、`requestRefreshDevices`、`requestSnapshot`、`requestWaterConnection`、`isRequestPending`、`onServerCommand`、`getSnapshot`，以及状态字段 `snapshot`。消费者：UtilityDashboard（L9）与 UtilityContextMenu（L4）。
- **`RailroaderRV.UtilityDashboard`**（[RV_UtilityDashboard.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:12)，L582 返回）：`format`、`refresh`、`onConnectionReset`、`show`、`onSnapshot`、`onRequestSent`、`onSendFailure`、`onAck` 与状态字段 `instance`。消费者：UtilityContextMenu（L5）与 UtilityClient 经全局表调用（L40、L64、L121、L221、L233）。
- **`RailroaderRV.UtilityContextMenu`**（[RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:11)，L210 返回）：`onPreFillWorldObjectContextMenu`、`onFillWorldObjectContextMenu`、`onFillInventoryObjectContextMenu`。
- **`ctx` 是本目录内部的组合合同**（[RV_ContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:52) 提供 15 个键）：RoomOwnership 读取 `C`/`Layout`/`clientTick`（L3-L4、L189、L273）并**写回 7 个函数**（L285-L291）；Relocation 捕获 19 个值（L3-L21）并读写 `ctx.pendingRelocation`/`ctx.clientTick`（L163、L308、L328、L352、L358、L363、L420）。
- **服务端 wire 合同**（客户端只消费，不构造权威数据）：`RVBoundaryCorrection`（[RV_BoundaryServer_Sweep.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Sweep.lua:100)）、`Relocate`（[RV_Server_PlayerValidation.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_PlayerValidation.lua:188)、[RV_WallReloadProtection.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_WallReloadProtection.lua:147)）、`FinalRelocate`（RV_Server_PlayerValidation.lua:240）、`RefreshRoomOwnership`（[RV_Server_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:459)、:539）、`RVTeleport`（[RV_RailroaderServer_EntryExit.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:143)）、`RVUtilityMapping`/`RVUtilityAck`/`RVUtilitySnapshot`（[RV_UtilityServer.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:118)、:130、[RV_RailroaderServer_Sentinel.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_RailroaderServer_Sentinel.lua:134)）。

### 直接读写其他模块的数据

1. **`ctx` 表的双向读写（同目录内部合同）**：[RV_ContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:52)-L68 构造，[RV_ContextMenu_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua:285)-L291 往同一个表写入 7 个函数，[RV_ContextMenu_Relocation.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua:3)-L21 再读出来，并在 L163/L308/L352/L358/L363/L420 直接改写 `ctx.pendingRelocation`。**判断**：这是同一 subsystem 的隐式接口而不是隐藏状态（`pendingRelocation` 只在 RV_ContextMenu 里作为初始 nil 占位，L39/L64）。**值得做的最小改进**是把 `ctx` 的键集合与所有权写成注释或契约文档；**不建议**改成访问器或消息总线——只有 1 个组合根与 2 个协作闭包，接口层成本高于收益。
2. **`RailroaderRV.RailroaderContextMenu` 的下划线状态字段**：`_rvUtilityMapping` 在 [RV_RailroaderContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:16)、:113、:225、:246、:251 读写；`_rvGenerationTransition` 在 :298、:301、:336、:517、:541 读写；`_rvCurrentSquareRefresh` 在 :424、:436、:441、:446、:452、:459、:463、:468 读写；`_rvCurrentSquareRefreshHook` 在 :714、:716 读写。**全树搜索确认没有任何外部模块读取这四个字段**（消费者只用公开方法）。**判断**：不需要改为接口；但它们位于公开表上，下划线是唯一保护，建议保持"外部只经 getUtilityMapping/acceptUtilityMapping/clearUtilityMapping 访问"的约定。
3. **`RailroaderRV.UtilityClient.snapshot` 与 `Client.getSnapshot()`**：[RV_UtilityClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityClient.lua:27)、:33、:219 写，:258 导出 getter；消费者 [RV_UtilityDashboard.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:249)、:315、:327 经 getter 读取 `power.batteries`/`power.generatorEnabled` 等字段。**判断**：已经通过 getter 访问（未直接读字段），但返回的是服务端表原引用，调用方若写入会污染缓存。**收益评估**：改为深拷贝的收益低——snapshot 是服务端 plain data，消费方只有面板且只读；**应保留直接访问**，同时明确"调用方只读"的约定。
4. **`RailroaderRV.UtilityDashboard.instance`**：仅在 [RV_UtilityDashboard.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:455)、:483、:489-L490、:506-L511、:519、:525、:534、:546、:558 内读写，无外部消费者。**判断**：模块私有状态误放在公开表上；**保留理由**：这些回调需要跨函数共享单一实例，改成闭包局部变量同样可行但会与 `Dashboard.show` 的模块方法拆分冲突，收益极小。
5. **实例字段跨函数读写**：`Dashboard.onRequestSent`（L538）、`onSendFailure`（L550）、`onAck`（L562-L577）直接写 `instance.operationRequestId`/`operationStatus`，而 `Window:close`（L449）与 `Window:request`（L214）读同一字段。**判断**：这是同一窗口对象的实例数据，不是模块私有状态；**应保留**，但它是"面板状态只能由这三个回调 + setSubmitted 改写"的隐含约定，建议在注释中固定。
6. **Railroader 官方表的直接读写（无法用本地接口消除）**：[RV_RailroaderContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:208)-L221 读 `RR.Ride.nearestBoardable`/`MOUNT_REACH` 并调用；:340-L341、:364-L365 调用 `ride.dismount(true)`；:359-L363 读 `ride.current`；:479-L481 调用 `ride.mountRecord`；:309-L318 遍历 `RR.TrainEntity.active` 并读 `record.id`/`record.animal`；:348、:357、:367 写 `record._boardPending`；:646-L649 读 `RR.BoardMenu.OnFill` 并用 `Events.OnFillWorldObjectContextMenu.Remove` 摘除；:662-L665 覆盖 `board.addForAnimal` 并写 `board.rrRVReplaced`；:672-L688 读 `AnimalContextMenu.rrAnimalMenuFiltered`、覆盖 `AnimalContextMenu.doMenu`、写 `AnimalContextMenu.rrRVWrapped`。**判断**：这些是官方模组（Railroader 2.1）的内部字段与函数槽位，**没有公开等价的 seat-transition / record lookup / menu hook API**；再包一层本地 façade 不会减少依赖，只会把同一批字段假设挪到另一个文件，**接口收益明显低于直接访问的成本**。正确做法是保持它们集中在这一个 adapter 文件，并把版本假设写在就近注释里（源码 L273-L278、L324-L327、L477-L478 已经这样做）。
7. **官方 timed action 表的直接改写**：[RV_ProtectedDemolition.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ProtectedDemolition.lua:255)-L262 与 :270-L277 保存并覆盖 `action.new`，同时把本模块自己的标记 `action._rvProtectedDemolitionWrapped` 写在官方表上；:280-L281 用 `rawget(_G, ...)` 取得并包装两个全局 action 表。**判断**：替换 `new` 是当前唯一可用的拦截点，**必须**；但 `_rvProtectedDemolitionWrapped` 是把 RV 字段写入官方表命名空间——可以改为模块内以 action 表为键的局部去重表，**收益中等偏低**（官方表会被 `require` 缓存，行为等价），若未来出现第二个 RV 包装器再改更合适。
8. **ModData tag 的直接读取**：[RV_BoundaryWallVisuals.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_BoundaryWallVisuals.lua:42)-L52、[RV_WardrobeVisuals.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_WardrobeVisuals.lua:48)-L61、[RV_ProtectedDemolition.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ProtectedDemolition.lua:191)-L218 读取 `object:getModData().RailroaderRV` 的 `owner`/`rvId`/`generation`/`role`/`templateIndex`/`edgeKey`；写入侧是服务端 [RV_Server_WorldObjects.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_WorldObjects.lua:261)-L273（只写 `templateIndex`/`edgeKey`）经 `ServerWorld.tagObject` 写入 owner/rvId/generation/role。**判断**：这是持久化 world object identity schema，consumer 必须读 tag 才能保护对象，**无法通过 getter 隐藏**（引擎 ModData 是可变原表）；可做的是把公共前缀校验提取成 shared 窄函数（第 4 节），**不必**为单个字段造接口。
9. **shared 模块的公开函数读取（属于正常接口使用，列出以界定边界）**：Visuals/ProtectedDemolition 调用 [RV_RoomTemplate.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_RoomTemplate.lua:128) 的 `get`/`orderedObjects` 与 [RV_TemplateGeometry.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_TemplateGeometry.lua:72) 的 `templateAnchorForWorld`/`worldToTemplate`/`lookupObjectByIndex`/`lookupObjectsAtWorld`/`isBuildCellSideHost`/`isBuildable`；RoomOwnership 调用 [RV_Layout.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_Layout.lua:27) 的 `eachStructureCoordinate`；UtilityContextMenu 调用 [RV_UtilityCatalog.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/Water/RV_UtilityCatalog.lua) 的 `hasFluidContainer`/`hasSinkIdentity`/`isCurrentWaterSink`/`readSinkIdentity`/`isWaterPipedDevice` 与 [RV_RegionSlots.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RVMapping/RV_RegionSlots.lua) 的 `COUNT`/`indexToRegion`/`indexToAnchor`。均为具名公开函数/常量，**不构成对内部状态的访问**。
10. **引擎/平台级全局对象读取**：`Fluid.Petrol`（UtilityContextMenu L176-L177、Dashboard L100-L101）、`ISContextMenu.get`（Dashboard L219、L248）、`ISCollapsableWindow:derive`（Dashboard L125）、`ISWorldObjectContextMenu.setTest`（RailroaderContextMenu L154）、`FBORenderChunk.DIRTY_REDRAW`（BoundaryWallVisuals L93-L94、WardrobeVisuals L104-L105）、`getCore`/`getTextManager`/`UIFont.Small`（Dashboard L132、L514）。这些是引擎 API 而非模组模块状态，**必须保持直接访问**。

### 接口边界问题

- **技术生成入口"合同在、注册缺失"**：`RailroaderRV.Client.requestGenerate`/`requestTemplateCapture`/`onFillWorldObjectContextMenu`（Relocation L24、L33、L39）没有任何注册点，而服务端仍处理 `Generate` 与 `DumpTemplateCapture`（RV_Server.lua:9、[RV_Server_Commands.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:324) 与 GenerationFlow）。这是一个需要在"重新挂接到某个菜单"与"连同服务端命令一起删除"之间做明确决定的分叉，不应长期停留。
- **依赖"可选性"声明与实现不一致**：[RV_ContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:12)-L17 用 pcall 声明 BoundaryClient 可选，但 L11 无保护 require 的 [RV_ProtectedDemolition.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ProtectedDemolition.lua:4) 又无保护 require 同一模块；同时 `local BoundaryClient` 在 ProtectedDemolition 中**声明后从未使用**（加载副作用才是目的）。建议去掉该局部绑定或明确注释"此处 require 只为加载模块"。
- **`validGenerationFinalHint` 双份实现**：RoomOwnership L14-L21 与 RailroaderContextMenu L485-L492 必须同时跟随服务端 FinalRelocate payload 变化；两份实现是纯重复，应合并（收益高、成本低）。
- **房间刷新 bounds 字段名双份硬编码**：客户端 [RV_ContextMenu_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua:35)-L39 与服务端 [RV_Server_RoomOwnership.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RoomOwnership/RV_Server_RoomOwnership.lua:447)-L451 各自维护同一 14 字段列表（`wallMinX...roofZ`）。字段名只在运行时才会暴露漂移；建议下沉为 shared 常量数组，两端各自做类型/整数校验。
- **两套 tag 失败语义必须保持区分**：ProtectedDemolition 对不可用 tag 走 fail-closed 并提示（L200-L218），两个 Visuals 只静默跳过（BoundaryWallVisuals L43-L45、WardrobeVisuals L49-L52）。任何"统一 tag 校验器"都必须保留"严格拒绝并提示"与"静默不匹配"两条路径，不能合并为单一 strict 函数。
- **加载期硬失败的两处**：[RV_UtilityClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityClient.lua:12)-L16 在隐藏 sprite 注册失败时 `error`，[RV_UtilityDashboard.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:124)-L125 在 `ISCollapsableWindow` 为 nil 时把 Window 置 nil（后者是软降级）。这是有意的 fail-fast/降级选择，但前者会让整个客户端文件（并可能连带其它 GUI 文件的加载顺序）失败，应作为已知设计约束记录。
- **两处 tick 处理器共存**：Relocation 注册 `Client.onTick`（L425，做迁移 ACK 与房间守卫驱动），RailoContextMenu 注册 `Menu.onTick`（L715，做 current-square 追赶），二者都要求 `Events.OnTick` 存在且各自有幂等标志/早退。当前语义正交（一个是事务证明，一个是显示缓存），但**同一帧内两个 tick 回调的相对顺序不由本层控制**，因此不能假设"ACK 先于 current-square 刷新"；如需顺序保证必须显式合并驱动。

## 函数清单、覆盖和验证记录

- **扫描文件**：`client/RailroaderRV/GUI/` 下 11 个 Lua 文件；目录扫描未见子目录或其它代码文件。同时只读检查了服务端 wire 生产者、shared 几何/常量模块与 Railroader 官方表访问点。
- **机械核对（行数与函数定义数）**：`function` 关键字列统计 `\bfunction\b` 的全部出现（含 `type(x) == "function"` 比较）；定义数列统计 `function` 后接可选名字与左括号的函数表达式（即本报告的计数口径）。两者差额全部来自字符串比较，无遗漏或多余定义。

| 文件 | 行数 | `function` 关键字出现次数 | 函数定义数 | 差额=字符串比较 |
|---|---:|---:|---:|---:|
| RV_BoundaryClient.lua | 119 | 17 | 10 | 7 |
| RV_BoundaryWallVisuals.lua | 134 | 10 | 6 | 4 |
| RV_ContextMenu.lua | 73 | 0 | 0 | 0 |
| RV_ContextMenu_Relocation.lua | 454 | 33 | 25 | 8 |
| RV_ContextMenu_RoomOwnership.lua | 292 | 32 | 28 | 4 |
| RV_ProtectedDemolition.lua | 281 | 25 | 17 | 8 |
| RV_RailroaderContextMenu.lua | 719 | 92 | 69 | 23 |
| RV_UtilityClient.lua | 269 | 48 | 29 | 19 |
| RV_UtilityContextMenu.lua | 210 | 25 | 15 | 10 |
| RV_UtilityDashboard.lua | 582 | 72 | 63 | 9 |
| RV_WardrobeVisuals.lua | 145 | 11 | 7 | 4 |
| **合计** | **3278** | **365** | **269** | **96** |

- **扫描函数计数**：269 个函数定义，构成为具名表函数 59、局部/嵌套函数 120、`表.字段 = function(...)` 形式的方法 6、匿名函数表达式 84。匿名表达式一律以「`外层函数名` 中匿名函数（L行号）」单列，包含 `pcall(function() ... end)`、菜单谓词/回调与工厂 `return function(ctx)`。
- **逐行交叉核对**：逐文件编号读取源码全文，条目行号均为定义语句（或赋值语句）起始行；表方法与模块级赋值（`objectCoordinates = function`、`Client.getSnapshot = function`、`action.new = function`、`board.addForAnimal = function`、`AnimalContextMenu.doMenu = function`）按定义处行号记录。事件注册位置为 RV_BoundaryClient L110-L118、RV_BoundaryWallVisuals L120-L133、RV_ContextMenu_Relocation L424-L432、RV_RailroaderContextMenu L692-L717、RV_UtilityClient L260-L268、RV_UtilityContextMenu L197-L208、RV_WardrobeVisuals L131-L144。
- **跨模块调用扫描**：在 `42/media/lua` 全树搜索 `require` 路径、`RailroaderRV.<Module>` 导出符号、`RailroaderRV/GUI/` 前缀与 wire 命令名，用于确认各公开 API 的消费者（第 5 节逐条给出文件:行），并确认本目录**没有任何文件被 `require` 引用**、`RailroaderRV/RV_ContextMenu` 路径零引用（见 [client-root.md](client-root.md)）。
- **文档验证**：本报告列出 11 个源文件、269 个函数条目，每条含起始行、参数、返回/副作用、模块语义与加粗必要性结论；并覆盖复用/提取、拆分、接口边界与直接数据访问。所有源码引用均为相对链接，行号取自本次读取的当前版本。
- **未覆盖项**：未运行游戏/服务器/runtime 测试，未验证 B42 引擎事件签名、`FBORenderChunk.DIRTY_REDRAW`、`ISCollapsableWindow` 派生与 Kahlua 数值代理的实际运行时表现；未审计 Railroader 官方脚本内部实现（只记录本层对官方字段的读写位置）；未穷举每个 API 的全部调用行，调用搜索只用于确认本目录 API 使用面与数据边界；未做 GUI 视觉验收与性能测量。
- **修改范围**：仅重写本分析文档与 [client-root.md](client-root.md)；未修改任何 Lua 源码、配置或测试文件，未运行测试。

