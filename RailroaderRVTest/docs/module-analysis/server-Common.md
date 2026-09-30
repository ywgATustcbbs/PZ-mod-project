# server/RailroaderRV/Common 模块分析

## 假设、范围、成功条件与验证方式

- **假设**：只分析模组当前目录 media/lua/server/RailroaderRV/Common/ 的直接子文件；行号以本次读取的文件版本为准。这里是服务端 helper 区域，按当前 B42 服务端调用语义解释。
- **范围**：覆盖本目录 5 个 Lua 文件及其所有具名函数、局部嵌套函数、表方法和匿名函数表达式；只读检查调用方以判断公开 API 使用和跨模块数据访问。唯一写入目标是本报告。
- **成功条件**：每个函数都有精确起始行、参数含义、返回值或副作用、模块语义和必要性判断；另外列出复用/拆分建议、接口边界和证据。不运行游戏或 runtime 测试。
- **验证方式**：列目录文件；用函数定义扫描和逐行编号读取交叉核对；用 server Lua 树上的调用搜索核对公开 API；完成后检查报告的文件清单、函数条目数、路径及行号引用。源码扫描是静态分析，不替代运行时验证。

## 目录职责与清单

Common/ 目前含通用 Java/Lua 调用与校验、服务端兼容工具、世界对象快照和清理、布局/区域 schema 校验、服务端传送五类职责。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_Common.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_Common.lua) | 25 | 可保护地调用 Java/Lua API、数值/表校验、玩家位置读取和带作用域的采样缓存 |
| [RV_ServerUtil.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerUtil.lua) | 7 | 服务端参数校验、空命令参数识别、点位复制和布局构造；复用并转出 RV_Common API |
| [RV_ServerTeleport.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerTeleport.lua) | 3 | 受开发存档 schema gate 保护的服务端传送，RV 出生点从服务端 mapping 查询 |
| [RV_ServerSchema.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerSchema.lua) | 13 | 校验当前布局、墙体/壳体 ledger、目标坐标及结构方格遍历 |
| [RV_ServerWorld.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua) | 32 | 世界格对象快照、生成身份标签、对象分类清理、楼板回滚和 square 重算 |
| **总计** | **80** | 74 个具名函数定义及 6 个匿名函数表达式 |

函数数包括具名局部/嵌套函数、导出函数、cache 表方法，以及 pcall/遍历回调中的匿名函数；M.x = localFunction 这种导出赋值不重复计数。

## 逐文件、逐函数分析

### RV_Common.lua

模块不注册事件、不写存档；通过 return Common 暴露表。行号参见 [RV_Common.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_Common.lua)。Common 表是公共 helper API；playerIdentity、copyTick、playerScopeKey 和缓存状态保持模块私有。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| Common.invoke（L7） | target 对象、name 方法名、可变方法参数；保护性读取方法并以 target 为 self 调用。返回 true,a,b,c,d；报错/不可读/不存在则 false,error或nil。 | **必须**：服务端普遍调用 Java 对象 API，封装代理访问异常和多返回值。 |
| Common.callSucceeded（L17） | 与 invoke 同参；返回调用成功且首返回值不等于 false 的布尔值。 | **必须**：当前写操作共用此成功判断。 |
| Common.invokeClass（L22） | class 类表、signatures 参数数组列表；按顺序保护调用 class.new，首个非 nil 结果为 true,instance，全部失败为 false,nil。 | **必须**：Construction 创建多个 Java 对象时要尝试签名候选并统一保护异常。 |
| Common.invokeClass 中匿名函数（L26） | 捕获 class，保护读取 class.new 并交给外层检查是否可调用。 | **实现必需**：Java class proxy 的构造器属性读取可能抛错。 |
| Common.callGlobal（L37） | _G 中全局函数名及参数；全局不存在或调用失败返回 false,nil/错误，成功返回 true 及最多三个结果。 | **必须**：服务端多模块调用全局 engine API，并需要统一保护和成功标志。 |
| Common.callGlobalSucceeded（L45） | 全局函数名及参数；将 callGlobal 的首结果折叠为布尔成功值，engine 返回 false 也视为失败。 | **必须**：发送命令、全局操作等反复需要此约定。 |
| Common.classInstance（L50） | 对象和 instanceof 所需类名；返回检查器成功且结果严格为 true。 | **必须**：用于区分玩家、车辆、僵尸及 Java 网络表等类型。 |
| Common.toNumber（L57） | Lua/Java 值；接受 number、解析 string，或保护执行 value+0 转换 Java 数值包装值；无效时 nil。 | **必须**：Kahlua/Java 返回值不总是 Lua number，服务端边界校验大量复用。 |
| Common.isFiniteNumber（L67） | 任意值；只接受有限 number，排除 NaN 和正负无穷。 | **必须**：坐标和世界数值须排除非有限值。 |
| Common.integer（L72） | 任意可数值化值；返回有限整数或 nil。 | **必须**：坐标、generation、schema 字段都依赖统一整数转换。 |
| Common.exactKeys（L80） | value 待验表、expected 必需键映射、可选 optional 键映射；拒绝非表、未知键或必需键缺失，成功 true。 | **必须**：身份/tick/plain-data schema 使用精确字段拒绝未知输入。 |
| Common.copyPlain（L99） | value 原始值或表，seen 为递归循环检测表；深拷贝允许的基本值和普通表；拒绝 metatable、循环、非法键和非 plain 值时抛错。 | **必须**：服务端快照/存档不能保留 Java 对象、循环或不受控表元数据；Construction 使用。 |
| Common.identityKey（L124） | 可变身份字段；任何 nil 返回 nil，否则转字符串并长度前缀编码后拼接，避免简单拼接碰撞。 | **必须**：缓存按玩家身份和 RV/generation 作用域建立稳定键。 |
| Common.getPlayerPosition（L136） | 玩家对象；保护调用 getX/getY/getZ 并数值化。成功 true,{x,y,z}，否则 false,原因文本。 | **必须**：读取服务端玩家坐标并供缓存采样。 |
| Common.getSquare（L150） | cell 和 x/y/z；三坐标先转整数，再调用 getGridSquare，返回 是否取得,square或nil。 | **保留理由**：提供带坐标验证的通用接口；当前 server 调用搜索未发现直接调用，需核实兼容承诺后再决定删除。与 ServerWorld.getSquare 参数要求不完全相同。 |
| playerIdentity（L159，私有） | 玩家对象；读取 username 与 onlineID，要求非空用户名、非负整数 ID，返回 identityKey 或 nil。 | **必须**：缓存需稳定区分同名/重连玩家；私有化避免消费者构造内部键。 |
| copyTick（L170，私有） | tick 表；要求仅 hi32/lo32 两个整数且在 unsigned 32-bit 范围，返回副本或 nil。 | **必须**：不保存调用方可变 tick 表，并校验 Core 双字 tick 结构。 |
| playerScopeKey（L181，私有） | identity；nil 返回 session sentinel，否则校验 rvId、generation、bitmapVersion、slotIndex、anchor 严格字段与整数范围，返回组合键或 nil。 | **必须**：缓存坐标绑定当前 RV/代际/位图/槽/锚点，身份变化会隔离旧样本。 |
| Common.newPlayerPositionCache（L207） | clock 必须提供 getTick/tickAdd/tickReached，否则抛错；返回闭包状态的缓存对象。 | **必须**：Core 依赖此工厂提供有有效期、代际作用域和显式失效的玩家坐标缓存。 |
| cache:invalidatePlayer（L216，工厂内方法） | self、玩家、可选 reason（当前未读取）；按 username/onlineID 删除该玩家项，返回是否识别身份。 | **必须**：断线/换人等流程可清掉旧位置；reason 当前未使用。 |
| cache:invalidateIdentity（L222，工厂内方法） | self、RV identity 表；按私有 scopeKey 删除所有匹配项，返回是否有项被删。 | **必须**：mapping/代际变更时清除作用域内坐标，防止复用旧 RV 快照。 |
| cache:samplePlayerPosition（L235，工厂内方法） | self、玩家、hi32/lo32 tick、最小间隔、identity；校验身份/间隔，间隔未到返回 false，否则读新位置并缓存，成功 true,{x,y,z}。 | **必须**：控制采样频率且将样本绑定当前 mapping 身份。 |
| cache:getPlayerPosition（L265，工厂内方法） | self、options；fresh=true 时直接读玩家，其他情况按 now/maxAge/identity 查缓存；无项、过期或作用域不符返回 false 和原因，成功返回位置副本。 | **必须**：消费方可选择强制新读或有限期缓存读取。 |
| cache.clear（L286，工厂内方法） | 无声明参数；清空私有 entries，无返回值。当前定义为 cache.clear() 点调用。 | **必须**：提供全量清空出口而不暴露缓存表；如需冒号调用应统一签名。 |
| Common.invoke 中匿名函数（L9） | 捕获 target/name，保护读取 target[name]，把结果交给外层。 | **实现必需**：某些 Java proxy 属性访问本身会抛错。 |
| Common.toNumber 中匿名函数（L62） | 捕获 value，保护执行 value+0；转换异常由外层转成 nil。 | **实现必需**：避免数值代理转换异常中断服务端请求。 |

### RV_ServerUtil.lua

模块在 [RV_ServerUtil.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerUtil.lua) 中 require RV_Layout 和 RV_Common。它把 Common 通用函数绑定/转出为服务端门面，另外实现命令参数和报错式数值校验。M.invoke 到 M.newPlayerPositionCache 等字段是 Common 函数引用（L86-L100），不是重复实现。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| tableIsEmpty（L21，私有） | 值；仅 Lua table 可检查，遇到任意键返回 false，无键 true，非表 false。 | **作为空包识别必需**：供 isEmptyCommandArgs 处理 B42 Lua table 表示，避免依赖 Kahlua 不提供的 next。 |
| isEmptyCommandArgs（L32，私有后导出） | 客户端命令 args；nil、空 Lua 表或空 PZNetKahluaTableImpl 接受，其他拒绝，返回布尔。 | **必须**：生成协议只接受空参数，同时兼容当前网络层两种空表形式。 |
| requiredNumber（L50，私有后导出） | 值和错误标签；经 toNumber 并要求有限值，否则带标签抛错；成功返回 number。 | **必须**：输入/存档字段需要失败关闭并有诊断。 |
| requiredInteger（L58，私有后导出） | 值和错误标签；在 requiredNumber 上再要求整数，否则抛错；成功返回整数。 | **必须**：坐标、版本和 schema 字段共享严格校验。 |
| floorInt（L67，私有后导出） | 可数值化值；不能转换时取 0，返回 math.floor。 | **当前可选**：server Lua 树的直接调用搜索无调用方；默认 0 可能把坏输入转成合法坐标，应确认契约后决定保留。 |
| copyPoint（L71，私有后导出） | value table 和 label；要求 xyz 均为整数，返回仅含整数 x/y/z 的新表，否则抛错。 | **必须**：GenerationBuild 用它复制 generator 点位并拒绝错误值。 |
| makeLayout（L82，私有后导出） | x/y/z；直接返回 RV_Layout.make 的结果。 | **必须**：GenerationFlow 由服务端锚点构造当前布局，避免其他层直接依赖布局实现。 |

**对外字段**：L86-L107 导出 22 个 API：Common 的 15 个函数，加本文件 7 个函数。多个 Construction、Core、RoofRefresh、TemplateRecovery、Water、Power 模块依赖此门面。例如严格整数校验用于 GenerationFlow 与 DevSaveSchemaGate。本次 server 树内搜索未发现 ServerUtil.floorInt、ServerUtil.getSquare、ServerUtil.newPlayerPositionCache 的直接调用；Common 内部仍会用其底层实现。没有直接调用者不代表范围外没有 API 消费者。

### RV_ServerTeleport.lua

模块在 [RV_ServerTeleport.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerTeleport.lua)，依赖 DevSaveSchemaGate，向 Core 和 RVMapping/EntryExit 提供服务端传送 API。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| finite（L5，私有） | 值；判断是否有限 number，返回布尔值。 | **校验必需**：传送坐标须有限；与 Common.isFiniteNumber 同义，可复用。 |
| M.teleportToPosition（L10） | 玩家、position{x,y,z}；schema gate 未就绪、坐标非法或 teleportTo 不存在则 false；否则保护调用 teleportTo，成功且首结果非 false 时 true。会改变服务端玩家位置。 | **必须**：集中 gate、坐标检查和服务端传送失败处理；Core 转出此 API。 |
| M.teleportToRVSpawn（L23） | 玩家、source{rvId,generation,bitmapVersion}、可选 expectedPosition；从全局 mapping adapter 查询当前 record，检查 rvPosition 有限且与预期一致后传送；返回 false 或 true,target，不使用客户端目标坐标。 | **必须**：RV 进入/退出流程按服务器当前 mapping 获取出生点并拒绝陈旧预期位置。 |

### RV_ServerSchema.lua

模块在 [RV_ServerSchema.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerSchema.lua)。初始化时验证捕获模板和保护 manifest；函数围绕单一 RV 布局与当前存档/bitmap 合同。L543-L550 导出 8 个函数。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| boundsFor（L35） | Layout.make 结果；逐层校验布局表、整数边界、100x100 半开 bitmap 和 packed layer 长度、房间/墙/屋顶边界及 wallCoordinates；返回 bounds 记录，非法抛错。 | **必须**：Generation、mapping、schema gate 等共享同一几何规范。 |
| field（L53，boundsFor 内私有函数） | 来源子表、错误标签、字段名；要求存在并用 requiredInteger 转换，返回整数或抛错。 | **必须**：boundsFor 字段校验的局部实现，只服务本合同。 |
| rectInside（L144，boundsFor 内私有函数） | 矩形 min/max x/y、z、标签；验证矩形非倒置且在 bitmap scope 内，否则抛错。 | **必须**：房间/墙/屋顶不能超出本代管理范围。 |
| walkBounds（L193） | cell、bounds、square 回调、requireLoaded；按 clear 半开区域逐格访问，square 存在时调用回调，requireLoaded=true 且缺失则抛错；无返回。 | **必须**：GenerationBuild 与 RoomOwnership 遍历共享区域规则。 |
| validateWallContract（L209） | bounds；检查 59 个墙边坐标、方向、角色、唯一性、模板索引与北/西边计数及西北角规则；非法抛错，无返回。 | **必须**：让捕获模板与程序生成墙环一致，避免错误几何进入破坏性事务。 |
| validateShellEdgeContract（L321） | bounds；逐墙 edgeKey 与 shellEdges ledger 比对 host/object 坐标、template index、sprite/orientation/替换许可和多部件索引；非法抛错。 | **必须**：核验壳体 ownership ledger，不能从 wall 对象 host cell 推断。 |
| validateTargetCoordinates（L370） | bounds、destination{x,y,z}；检查整数、RegionSlots、合法世界 z、选中槽与 100x100/室内/墙体/屋顶几何、wall/shell 合同及底面/墙/屋顶坐标；成功无值返回，失败抛错；不读取 square。 | **必须**：服务端需在加载/构建前拒绝非法目标位置。 |
| validWorldCoordinate（L432，嵌套私有函数） | x/y/z、错误角色名；保护调用 getWorld/isValidSquare，z 超界或世界方格无效时抛错。 | **必须**：供 validateTargetCoordinates 逐点校验。 |
| preflightLoaded（L469） | cell、bounds；要求 cell 存在，然后用管理区中心位置运行完整目标/布局校验；返回 true 或抛错。当前并不逐格要求 100x100 或屋顶 squares 已加载。 | **当前调用所需**：GenerationFlow 在构建前复验计划与 cell；名称容易被理解为完整 loaded-area 检查，实际只拒绝无 cell。 |
| targetAreaLoadStatus（L489） | 玩家、bounds、可选安全错误格式化函数；保护取得 cell 和 preflight，返回 true（可继续）、false（无 cell/明确暂不可用）或 nil（合同/engine 硬错误）及错误文本。 | **必须**：RV_Server_Commands 用三态区分重试与终止。 |
| 默认 safeText 匿名函数（L490） | err；保护 tostring 并返回显示文本，格式化失败时返回固定占位文本。 | **实现必需**：错误格式化失败不能覆盖原始加载/校验错误。 |
| eachStructureSquare（L518） | cell、bounds、回调；校验墙/屋顶坐标整数后调用 Layout.eachStructureCoordinate；square 存在时调用给定回调，缺失时跳过。 | **必须**：构建/清理结构区沿用同一坐标生成规则。 |
| eachStructureSquare 传给 Layout 的匿名函数（L535） | x/y/z；从 cell 取 square，有 square 时把 square 与坐标传给调用者回调。 | **实现必需**：在 Layout 坐标合同和当前 cell API 间适配。 |

### RV_ServerWorld.lua

模块在 [RV_ServerWorld.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua)。高影响接口是对象枚举、身份标签、移除和方格重算。OWNER 与算法状态未暴露，L522-L546 将局部函数集中导出。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| getCellForPlayer（L12） | 玩家或 nil；先取玩家 cell，再尝试全局 getCell，均无结果时抛错；返回 cell。 | **必须**：多种服务端上下文需要当前 IsoCell。 |
| getSquare（L24） | cell 和 x/y/z；保护调用 getGridSquare，成功且非 nil 返回 square，否则 nil；不自行整数化。 | **必须**：生成/清理/工具功能按校验后的坐标取格；与 Common.getSquare 的输入合同不同。 |
| collectionSnapshot（L32） | collection、strict、required；通过 size/get 或 Lua table 遍历复制成新数组；strict 下缺失必需 collection 或枚举失败返回 nil,false,原因，其他情况返回 result,true。 | **必须**：脱离 Java 容器并在清理前识别枚举不完整。 |
| appendUnique（L68，私有） | result 数组、seen 集合、object；非 nil 且未见过时登记并追加，无返回。 | **必须**：多 API 列表可能重叠，避免对象被重复清理。 |
| squareSnapshotInternal（L75，私有） | square、strict；收集 objects/special/moving/corpse/floor/vehicle 列表；strict 时 API 不完整返回 nil,false,原因，成功 result,true。 | **必须**：统一收集格内对象；strict 为保护性修复/破坏性流程提供 fail-closed 枚举。 |
| getterAvailable（L82，嵌套私有函数） | getter 名；保护读取 square[name]，返回 nil（访问报错）或函数存在布尔值。 | **必须**：区分 getter 不存在与读取失败。 |
| failOrContinue（L87，嵌套私有函数） | 错误文本；strict 返回 false,message，宽松模式 true。 | **必须**：集中决定不完整 getter 是否中止 snapshot。 |
| squareSnapshot（L159） | square；宽松调用内部 snapshot，失败时回空数组。 | **必须**：非事务调用点需要尽可能可用的对象列表；被多个子系统调用。 |
| strictSquareSnapshot（L164） | square；返回内部 strict 的 objects,complete,reason 三元组。 | **必须**：安全清理和 occupancy 判断不能把枚举失败当空格。 |
| objectModData（L168） | engine object；通过 getModData 取得且结果为 table 时返回原表，否则 nil。暴露可变底层 ModData 引用。 | **当前有用且公开**：Construction、Power、RoofRefresh、TemplateRecovery 检查或更新 ModData；也是本模块最宽的状态访问口，见接口章节。 |
| tagObject（L176） | object、generation、role、extraData；写 owner/rvId/generation/bitmapVersion/role 和嵌套 namespace，重验身份；失败抛错。 | **必须**：生成对象需带当前服务器身份，清理/回滚据此筛选。 |
| withTagIdentity（L233） | extraData、tagContext；校验 context 身份，浅复制额外元数据后以 context 的 rvId/version 覆盖，返回合并表。 | **必须**：防止 per-object 元数据覆盖 authoritative mapping identity。 |
| isTaggedForGeneration（L252） | object、generation、rvId、bitmapVersion；检查平面或嵌套 tag 的 owner 与身份，返回布尔。 | **必须**：cleanup/rollback/roof ownership 按当前代际筛选。 |
| matches（L260，isTaggedForGeneration 内私有函数） | tag 表；校验 owner、generation、rvId、bitmapVersion 是否匹配，返回布尔。 | **必须**：统一匹配平面与嵌套 tag，不暴露规则细节。 |
| isPlayerObject（L275） | object；先 instanceof IsoPlayer，再试 isPlayer；返回布尔。 | **必须**：清理时保护玩家对象。 |
| isVehicleObject（L283） | object；先 instanceof BaseVehicle/IsoVehicle，再试 isVehicle；返回布尔。 | **必须**：车辆需永久删除，不能作为普通物件摘除。 |
| deregisterSpecialSystems（L291） | object；当前原样返回 object，无副作用，调用方忽略返回。 | **当前不是功能必需**：removeGenericObject 调用它但本实现无登记系统；可去掉或保留作扩展钩子。 |
| removeCorpse（L298） | square、corpse；调用 B42.20 removeCorpse(corpse,false)，API 不可用时抛错。 | **必须**：尸体走服务端网络同步删除入口。 |
| removeZombie（L308） | square、zombie；尝试 dieNetwork，必要时 setHealth(0) 重试；有 corpse 时经 removeCorpse 清理；失败时走本地 die/remove 回退。 | **必须**：删除僵尸并同步死亡状态，避免客户端残留活体。 |
| removeAnimal（L332） | animal；调用 delete/removeFromWorld/removeFromSquare，无显式返回。 | **必须**：动物有独立 B42 生命周期，不应直接改 collection。 |
| removeVehicleSafely（L340） | vehicle；调用 permanentlyRemove，失败或缺 API 时抛错。 | **必须**：永久车辆删除需服务端持久化和网络删除。 |
| validateVehiclePath（L349） | vehicle；要求 permanentlyRemove 是函数，否则抛错。 | **必须**：clearSquare 先验证所有车辆路径，避免删除部分对象后才发现未知 API。 |
| getSpriteName（L355） | object；经 getSprite/getName 取名称并转 string，缺失时 nil。 | **必须**：楼板回滚及模板修复需要 sprite 名校验/恢复。 |
| clearGenerationTag（L367） | object；清掉本 owner 身份字段与嵌套 previousSprite/createdByGeneration，调用 transmitModData；失败抛错。保留 namespace 和其他 ModData。 | **必须**：还原旧 floor 后移除本代标记且同步客户端，不能误删他模组字段。 |
| squareContainsObject（L397） | square、object；遍历 getObjects 做引用比较；API 不可用 nil，找到 true，完整遍历未找到 false。 | **必须**：transmitRemoveItemFromSquare 后验证 engine 确实摘除对象。 |
| restoreTaggedFloor（L419） | square、object；仅处理本 owner、createdByGeneration=false 且有 previousSprite 的 tag；必要时恢复 sprite 并同步，清 tag 后 true；不可恢复则 false。 | **必须**：rollback 还原生成前已有 floor，而不永久删除。 |
| removeGenericObject（L446） | square、object、restoreTaggedFloors；满足条件先还原旧 floor，否则执行普通移除并验证；异常抛错。 | **必须**：集中封装一般物件移除和 rollback floor 特例。 |
| removeObject（L467） | square、object、restoreTaggedFloors；玩家跳过，车辆/僵尸/动物/尸体走专用 API，其他走通用删除。 | **必须**：clearSquare 类型分派，避免特殊世界对象使用错误删除 API。 |
| recalcSquare（L490） | square；调用 RecalcProperties 和 RecalcAllWithNeighbours(true)，无返回。 | **必须**：world mutation 后更新碰撞、房间与邻格缓存。 |
| clearSquare（L498） | square、可选 generation、rvId、bitmapVersion；先取快照并预验证车辆永久移除能力，再按身份过滤删除，最后重算 square；无返回，异常中止。 | **必须且高影响**：generation/区域清理和 rollback 执行入口；车辆 API 先验可减少部分删除后失败。 |
| getterAvailable 中匿名函数（L83） | 捕获 square/name 并读取 square[name]，由 pcall 保护 Java proxy getter。 | **实现必需**：探测 engine 方法时属性读取异常不可逃出。 |

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **通用调用与数值验证已有单一实现**：RV_Common 的 invoke/callGlobal/classInstance/toNumber/integer 是 RV_ServerUtil 基础；ServerWorld、Construction、Core、RoofRefresh、Water、Power、TemplateRecovery 使用 ServerUtil 门面。没有必要再加一套通用 utility。
- **可合并 finite 判断**：RV_ServerTeleport.finite（L5）与 RV_Common.isFiniteNumber（L67）规则等价。复用会减少重复规则，代价是 Teleport 增 Common/ServerUtil 依赖，收益明确但较小。
- **两个 getSquare 重叠但合同不等价**：RV_Common.getSquare（L150）先要求整数坐标，RV_ServerWorld.getSquare（L24）仅保护调用并返回 nil。提取前须决定统一转换还是由调用方验证；直接替换可能改变输入失败语义。
- **integer 与 requiredInteger 应保持分层**：Common.integer 失败返回 nil；ServerUtil.requiredInteger 失败抛带字段标签错误，是宽松解析与严格 schema 校验两种策略。
- **对象枚举去重仅需在 ServerWorld**：appendUnique/collectionSnapshot 服务多来源 engine collection，没有看到其他 Common 文件重复实现同等机制。
- **不建议泛化布局几何校验**：100x100 footprint、59 壳边、slot/z 约束依赖当前 RV template/schema，不适合作为通用 server helper。

### 是否进一步拆分

- **RV_ServerWorld 是优先评估对象**：547 行同时包含 collection/square snapshot（L32-L165）、generation tag/modData（L168-L273）、特殊实体删除和通用清理（L275-L519）。若继续增长，可拆 Snapshot、GenerationTag、WorldCleanup，再保留当前 World façade 统一导出；现在它们紧密配合一个清理事务，仅按行数拆分收益有限。
- **RV_ServerSchema 可分几何合同与 cell 遍历/加载适配**：布局/wall/shell/target 坐标校验（L35-L467）与 cell/square 遍历和 load status（L469-L541）是两种职责。若增长，可拆 GeometryContract 和 LoadedArea；目前后半依赖前半，拆分收益中等。
- **RV_Common 中位置缓存是自然边界**：通用调用/数值/表 helper 与玩家位置 cache（L159-L290）主题不同。出现第二个 cache 或独立生命周期需求后可拆 PlayerPositionCache；当前单闭包工厂状态封装良好。
- **RV_ServerUtil、RV_ServerTeleport 不需要拆**：Util 体量小，负责服务端输入门面；Teleport 只有 schema gate 与两个紧密相关操作。Util 同时承载重导出和输入校验，受公共 API 与 Kahlua active-local 分块动机支持。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **RV_Common**：Common 返回表字段为公共 helper；位置缓存只公开 invalidatePlayer、invalidateIdentity、samplePlayerPosition、getPlayerPosition、clear。entries、身份键函数和 tick 校验均为闭包私有。
- **RV_ServerUtil**：L86-L107 的 M 表是公开 facade，多个服务端目录 require 并调用；重导出是函数引用，不暴露局部变量。
- **RV_ServerWorld**：L522-L546 的快照/tag/删除函数被 Construction、TemplateRecovery、RoofRefresh、Power、Water 使用。例如 WorldObjects 调 tagObject/withTagIdentity，TemplateProtectionRepair 用 objectModData/removeGenericObject/squareContainsObject，Water 用 strictSquareSnapshot。
- **RV_ServerSchema**：L543-L550 的布局和几何函数供 GenerationFlow、RecordValidation、DevSaveSchemaGate、RoomOwnership 使用。
- **RV_ServerTeleport**：两个传送方法由 Core 转接，RVMapping EntryExit 使用公开服务端传送入口。

### 直接读写其他模块的数据

1. **没有发现模块调用方直接读取 Common、ServerUtil、ServerWorld 或 ServerSchema 的私有局部表/闭包变量。**公开函数经模块表导出；OWNER、缓存 entries 和模板索引等仍私有。
2. **layout、bounds、identity、mapping record 是跨模块 table 合同**，字段读取属于消费公开数据，不是访问模块隐藏状态：
   - ServerSchema.boundsFor 读取 layout.clear/managed/bitmap/shellEdges/room/wall/roof/anchor（L39-L120）及 wallCoordinates（L160-L165），这些由 RV_Layout.make 生成。
   - ServerSchema 比较 RoomTemplate.orderedObjects 返回对象记录的 class/x/y/z/sprite/north（L251-L256），这是模板模块返回记录合同。
   - RV_Common.playerScopeKey 按精确字段读取调用者传入 identity（L181-L204）。
   - RV_ServerTeleport 从 RailroaderRV.RailroaderServer 取 adapter.currentMappingRecord 并消费 record.rvPosition（L25-L41）。调用的是服务端 adapter 方法和返回记录，不是 mapping 私有索引表。它硬编码全局查找，耦合点清晰；可注入 resolver，但 adapter 已提供查询 API，多加接口的收益有限。
3. **ServerWorld.objectModData 暴露 engine 可变 ModData 原表**（L168-L174），调用方直接读写字段：
   - Construction/RV_Server_WorldObjects.lua:374-L378 读取旧 RV tag，:607-L612 写 engine 所需 IsLighting；
   - RoofRefresh/RV_RoofRefresh.lua:231-L233、Power/RV_UtilityPower.lua:81-L84 读取嵌套 RailroaderRVTest tag；
   - TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:337-L340、:732-L735 读取 tag/footprint。
   这是 objectModData 显式导出的数据口，不是读取 World 私有状态。tag 身份字段由 tagObject 集中写、clearGenerationTag 集中清理，其他模块主要读。增加 getTag 查询可隐藏 tag 表字段布局，但 IsLighting 仍需引擎 ModData。当前调用数有限，读取无需转换，窄接口收益小；若未来出现其他模块直接写 owner/generation/version 字段，应优先收紧身份 tag 写接口。
4. **ServerWorld.validateVehiclePath 直接读取 vehicle.permanentlyRemove**（L349-L353）是检查 engine 公共方法以保证破坏性操作可执行，不是跨 RV 模块访问内部状态。

### 接口边界问题

- ServerUtil 重导出 Common 的部分 API，形成 Common.foo 与 ServerUtil.foo 两条服务端可用路径。它不泄露数据，但可能让新代码依赖风格分叉；新服务端模块优先使用 ServerUtil 门面。
- ServerUtil.getSquare 与常用 ServerWorld.getSquare 名称相似但输入合同不同；server 树调用搜索未发现 ServerUtil.getSquare 使用。应文档化或在确认兼容范围后收敛别名。
- deregisterSpecialSystems 当前 no-op 却在 M 表导出（ServerWorld.lua L533），实际仅由 World 内部 removeGenericObject 调用；可考虑改私有或去掉调用。
- targetAreaLoadStatus 的三态语义是公开协议：false 当前代表 cell 尚不可取得、可重试；nil 代表合同/engine 硬错误，调用方不能合并两种状态。

## 函数清单、覆盖和验证记录

- **扫描文件**：RV_Common.lua、RV_ServerUtil.lua、RV_ServerTeleport.lua、RV_ServerSchema.lua、RV_ServerWorld.lua；目录扫描未发现子目录或其他代码文件。
- **扫描函数**：本目录函数关键字扫描并逐行核对定义。计数 Common 25、ServerUtil 7、ServerTeleport 3、ServerSchema 13、ServerWorld 32，共 80；匿名 getter/转换/error-format/遍历回调均单列。
- **逐行交叉核对**：逐文件编号读取源码全文；条目中的行号是定义语句起始行。局部和匿名嵌套函数另行标明。导出位置为 RV_ServerUtil.lua L86-L107、RV_ServerSchema.lua L543-L550、RV_ServerWorld.lua L522-L546。
- **跨模块调用扫描**：在 media/lua/server/RailroaderRV 下搜索 require、导出符号调用和 currentMappingRecord/adapter 连接，确认 API 使用面与所述数据访问点。
- **文档验证**：报告列出 5 个源文件及 80 个函数条目；各条目含起始行、参数、输出/副作用和必要性理由，并覆盖复用、拆分、接口与数据访问。
- **未覆盖项**：没有穷举每个 API 的全部调用行，也没有审计 Common 目录外模块内部所有函数；调用搜索只用于确认本区域 API 使用和数据边界。未运行 runtime/游戏测试，本文不宣称运行时行为已验证。
- **修改范围**：仅新增/更新本分析文档；未修改 Lua 源码、配置或测试文件。



