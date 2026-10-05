# server/RailroaderRV/Common 模块分析
> **状态（RailroaderRV 1.0）**：本文件是静态审计记录；其行号、计数和源码结论并非本次发布的全量重核，也不是运行时验证。当前实现以 [源码](../../contents/mods/RailroaderRV/42/) 与 [README](../../README.md) 为准，项目约束以 [agents.md](../../../agents.md) 为准。历史建议不构成修复授权，采纳前须按现行约束重新取证。

## 假设、范围、成功条件与验证方式

- **假设**：只分析模组当前目录 media/lua/server/RailroaderRV/Common/ 的 5 个直接子文件；行号以本次读取的当前源码版本为准（本目录 5 个文件合计 823 行）。这里是服务端公共层，按当前 B42 服务端调用语义解释，不引用精简前代码的旧行号。
- **范围**：覆盖本目录 5 个 Lua 文件及其所有具名函数、局部/嵌套函数、表方法和匿名函数表达式；只读检查调用方，用于判断导出 API 的实际使用面与跨模块数据访问。唯一写入目标是本报告。
- **成功条件**：每个函数都有精确起始行、参数含义、返回值或副作用、模块语义和必要性判断；另外给出复用/拆分建议、接口边界和证据，并明确区分「源码事实」与「条件性推断」。不运行游戏或 runtime 测试。
- **验证方式**：列目录文件与行数；用 `function` 关键字扫描加逐行编号全文读取交叉核对定义与起始行；用整个 media/lua 树的调用搜索核对导出 API 使用面（按 require 别名 / ctx 注入分别核查）；完成后检查报告的文件清单、函数条目数、路径及行号引用。源码扫描是静态分析，不替代运行时验证。

## 目录职责与清单

Common/ 目前含通用 Java/Lua 调用与数值校验、服务端校验门面、服务端传送、布局 bounds 展开与加载状态判定、世界对象快照与清理五类职责。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_Common.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_Common.lua) | 13 | 无状态的通用 Java/Lua 保护调用、数值转换与有限性/整数判定、身份键编码 |
| [RV_ServerUtil.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerUtil.lua) | 2 | 服务端输入门面：转出 Common 函数，另加抛错式的必需数值/整数校验 |
| [RV_ServerTeleport.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerTeleport.lua) | 2 | 服务端权威传送：按给定位置传送、按服务端 mapping 记录解析 RV 出生点 |
| [RV_ServerSchema.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerSchema.lua) | 7 | 布局 bounds 展开、clear 区域遍历、目标坐标/世界合法性校验、加载状态三态 |
| [RV_ServerWorld.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua) | 29 | 世界格 cell/square 访问、对象枚举快照、生成身份标签、分类清理、楼板回滚与 square 重算 |
| **总计** | **53** | 48 个具名函数定义及 5 个匿名函数表达式 |

函数数包括具名局部/嵌套函数、导出函数、表方法，以及 pcall 包装中的匿名函数；`M.foo = localFunction`（RV_ServerSchema.lua L151-L155、RV_ServerWorld.lua L464-L478）与 `M.foo = Common.foo`（RV_ServerUtil.lua L37-L45）这类导出赋值不重复计数，只在「对外字段」说明里列出导出清单。

## 逐文件、逐函数分析

### RV_Common.lua

模块不注册事件、不写存档、不持有状态，只返回 `Common` 表（L92）；3 个匿名函数都是 pcall 包装体。行号参见 [RV_Common.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_Common.lua)。10 个表字段全是公共 helper，没有私有局部函数。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| Common.invoke（L7） | target 对象、name 方法名、可变方法参数；保护性读取方法并以 target 为 self 调用。返回 true,a,b,c,d（最多 4 个返回值）；target 为 nil、属性读取抛错或不是函数时 false,nil；调用抛错时 false,error。 | **必须**：服务端所有 Java 对象访问的基座，直接消费者是 RV_ServerUtil.lua L10 的转出，间接覆盖 server 树 107 处 `invoke` 调用点。 |
| Common.invoke 中匿名函数（L9） | 捕获 target/name，保护读取 `target[name]`，把结果交回外层。 | **实现必需**：Java proxy 的属性读取本身可能抛错，不能让它逃出 invoke。 |
| Common.callSucceeded（L17） | 与 invoke 同参；把 invoke 结果折叠为「调用成功且首返回值不等于 false」的布尔值。 | **必须**：写操作的统一成功判断，server 树 63 处调用点（如 RV_Server_WorldObjects.lua L289-L291）。 |
| Common.invokeClass（L22） | class 类表、signatures 参数数组列表；保护读取 `class.new`，按顺序用 `unpackFn` 展开每个签名调用，首个非 nil 实例返回 true,value，全部失败或参数形状非法返回 false,nil。 | **必须**：Java 构造器签名在不同 engine 版本间有候选差异，创建对象必须统一保护并逐个试签。 |
| Common.invokeClass 中匿名函数（L26） | 捕获 class，保护读取 `class.new`。 | **实现必需**：类代理的构造器属性读取可能抛错。 |
| Common.callGlobal（L37） | _G 中的全局函数名及参数；全局不存在或不是函数时 false,nil；调用抛错时 false,error；成功返回 true 及最多三个结果。 | **必须**：服务端需要调用全局 engine API 并统一保护；server 树 17 处调用点（如 RV_Server_WorldObjects.lua L366 取 `getSprite`）。 |
| Common.callGlobalSucceeded（L45） | 全局函数名及参数；把 callGlobal 首结果折叠为布尔成功值，engine 返回 false 也视为失败。 | **必须**：发送服务端命令统一走此约定，7 处调用点（如 RV_Server_RoomOwnership.lua L472 的 `sendServerCommand`）。 |
| Common.classInstance（L50） | 对象、instanceof 需要的类名；`instanceof` 不可用时 false；保护调用并要求结果严格等于 true。 | **必须**：清理与验证需要区分玩家/车辆/僵尸/动物/尸体等类型；14 处调用点，其中 RV_BoundaryServer_Objects.lua L134-L135 是唯一直接 require Common 使用它的外部模块。 |
| Common.toNumber（L57） | 任意值；number 原样返回，string 走 tonumber，其他非 nil 值保护执行 `value + 0` 以兼容 Java 数值包装，失败返回 nil。 | **必须**：Kahlua/Java 返回值不总是 Lua number；server 树 27 处调用点。 |
| Common.toNumber 中匿名函数（L62） | 捕获 value，保护执行 `value + 0`。 | **实现必需**：数值代理转换异常必须折叠为 nil 而不是中断请求。 |
| Common.isFiniteNumber（L67） | 任意值；只接受 `type == "number"` 且非 NaN、非正负无穷，不转换字符串或 Java 包装。 | **必须**：坐标与 generation 等的有限性判定；8 处直接调用点，外加 RV_ServerTeleport.lua L7/L32-L34 与内部 integer。 |
| Common.integer（L72） | 任意可数值化值；先 toNumber 再要求有限且 `math.floor(v) == v`，否则 nil。 | **必须**：探测式读取要「失败给 nil」，与 ServerUtil.requiredInteger 的抛错策略分层，服务端坐标读取普遍复用。 |
| Common.identityKey（...）（L80） | 可变身份字段；任一分量为 nil 立即返回 nil，否则每段转字符串并加「长度:」前缀后用 `|` 拼接，避免简单拼接碰撞。 | **必须**：服务端缓存键。RV_UtilityPowerDevices.lua L191/L269/L277/L316/L333/L341/L353/L360 经 `Util.identityKey(identity.rvId, identity.generation)` 使用，是 ServerUtil 中唯一不定义在本文件的导出字段（RV_ServerUtil.lua L46）。 |

### RV_ServerUtil.lua

模块在 [RV_ServerUtil.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerUtil.lua) 中只 require RV_Common（L7），本身无副作用、不注册事件；文件头注释（L1-L5）说明它独立成 chunk 的目的是把 RV_Server.lua 压在 Kahlua 的 200 活跃局部上限之下。L37-L48 是导出区：10 个字段是 Common 函数引用，2 个是本文件实现。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| requiredNumber（L20，私有后导出） | 值和错误标签；经 toNumber 并要求 isFiniteNumber，否则抛「<label> is not a finite number」；成功返回 number。 | **必须**：权威玩家坐标等协议/存档字段需要失败关闭并带诊断。RV_Server_PlayerValidation.lua L27 是当前唯一外部调用点。 |
| requiredInteger（L28，私有后导出） | 值和错误标签；在 requiredNumber 之上要求整数，否则抛「<label> must be an integer」；成功返回整数。 | **必须**：把客户端 payload 与 bounds 字段转成整数坐标。RV_Server_RoomOwnership.lua L326、L454、L480、L531 使用（L454 逐字段校验 bounds 的 14 个整数边界）。 |

**对外字段**：L37-L48 导出 12 个字段 —— Common 的 invoke、callSucceeded、invokeClass、callGlobal、callGlobalSucceeded、classInstance、toNumber、isFiniteNumber、integer、identityKey，加本文件的 requiredNumber、requiredInteger。它们都是函数引用，不暴露 Common 的局部变量。消费方包括 Core/RV_Server.lua L80（转出给 ctx）、RV_UtilityServer.lua L14、RV_Server_RoomOwnership.lua L9（ctx 注入）、RV_WallReloadProtection.lua L14、RV_RoofRefresh.lua L14、RV_UtilityPower.lua L9、RV_UtilityPowerDevices.lua L6、RV_UtilityWater_Objects.lua L7、RV_UtilityWater_Plumbing.lua L3、RV_UtilityWater_Commands.lua L10。本次全树核查未发现 floorInt、isEmptyCommandArgs、copyPoint、makeLayout、getSquare、newPlayerPositionCache 等旧导出（精简前存在），12 个导出字段当前全部有真实调用点。

### RV_ServerTeleport.lua

模块在 [RV_ServerTeleport.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerTeleport.lua)，只 require RV_Common（L3），不依赖旧的 dev-save schema gate；向 Core 与 RVMapping/EntryExit 提供服务端权威传送。两个函数都会改变服务端玩家位置。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| M.teleportToPosition（L5） | player、position{x,y,z}；player 为空、position 非表、xyz 任一非有限数或 `player.teleportTo` 不是函数时返回 false；否则保护调用 `teleportTo(x,y,z)`，成功且首结果非 false 返回 true，抛错或返回 false 返回 false。副作用：服务端玩家位置变更。 | **必须**：传送的单一实现与失败处理。调用点：RV_RailroaderServer_EntryExit.lua L181；经 Core/RV_Server.lua L138 转出为 `RV.Server.teleportToPosition` 后被 RV_Server_PlayerValidation.lua L213/L268、RV_WallReloadProtection.lua L138-L139、RV_BoundaryServer_Sweep.lua L95-L96 使用。 |
| M.teleportToRVSpawn（L18） | player、source{rvId,generation}、可选 expectedPosition；source 非表返回 false；从 `_G.RailroaderRV.RailroaderServer` 取 adapter 并要求 `currentMappingRecord` 是函数，否则 false；查询记录后要求 record.rvPosition 为有限 xyz，若给了 expectedPosition 则要求完全一致；最后委托 M.teleportToPosition。返回 false 或 true,target。副作用：服务端玩家位置变更，坐标只来自服务端 mapping。 | **必须**：RV 进入流程按服务端当前 mapping 解析出生点并拒绝陈旧预期位置，绝不采用客户端坐标。当前唯一调用点是 RV_RailroaderServer_EntryExit.lua L179（Core 于 L139 另做了一次转出，未见其他调用者）；调用点少但它是不走客户端坐标的唯一路径，不能由调用方内联替代。 |

### RV_ServerSchema.lua

模块在 [RV_ServerSchema.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerSchema.lua)，require RV_Constants、RV_ServerUtil、RV_ServerWorld、RVMapping/RV_RegionSlots（L5-L8）。当前职责是「把 RV_Layout 的布局表展开成 flat bounds 记录」+「clear 区域遍历」+「目标坐标与世界合法性校验」+「加载状态三态」；布局/墙/壳合同校验已不在本文件（见复用与接口章节）。5 个函数经 L151-L155 导出。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| boundsFor（L13，私有后导出） | layout（RV_Layout.make 结果）；读取 layout.clear/managed/room/wall/roof/wallEdgeCounts/shellEdges/wallCoordinates/wallObjectCount/wallCoordinateCount/wallCornerCount/anchor，返回一个新的 flat bounds 表（clear*/managed*/room*/wall*/roof* 边界、z、roofZ、anchor 等）。**当前不做任何字段校验、不抛错、无副作用**。 | **必须**：GenerationFlow.lua L375 与 RV_Server_RecordValidation.lua L52 依赖它把 layout 变成唯一的几何值对象；消费方按字段直读（RV_Server_GenerationBuild.lua L83 读 bounds.roomMinX/roomMinY/z，RV_Server_RoomOwnership.lua L446-L457 读 wall/room/roof 的 min/max 与 z/roofZ）。字段名即合同，当前不能删。 |
| walkBounds（L43，私有后导出） | cell、bounds、fn(square,x,y,z) 回调、可选 requireLoaded；按 z→x→y 三重循环遍历 `[clearMin*, clearMax*-1]` 半开区域，square 存在时调用回调；`requireLoaded == true` 且 square 缺失时抛「clear bounds contain an unloaded square」。无返回。 | **必须**：清理/构建/验证遍历的唯一区域规则。4 个调用点：RV_Construction.lua L22、RV_Server_GenerationBuild.lua L97、RV_Server_RoomOwnership.lua L491/L500，全部只传 3 个参数。`requireLoaded` 分支当前无人使用（**保留理由**：它是「要求完整 footprint 已加载」这一策略的唯一开关，删掉会把该策略从接口上抹去，代价是暂时存在一条不可达错误路径）。 |
| validateTargetCoordinates（L59，私有后导出） | bounds、destination{x,y,z}；依次校验 RegionSlots.indexForAnchor 认得目标锚点、目标 z/clearZ/z/roofZ 落在 Constants.WORLD_MIN_Z..MAX_Z、目标在 room 内部，再取全局 getWorld 并逐点调用 isValidSquare（目标点、clear 底面、wallCoordinates 全部墙点、roof 全区）。全部通过则无返回值，任一失败抛错。不读取 square、不修改世界。 | **必须**：构建前的目标合法性门禁；RV_Server_GenerationFlow.lua L384 是当前唯一调用点。 |
| validWorldCoordinate（L81，嵌套私有函数） | x、y、z、role 角色名；z 超出 Constants 合法范围立即抛错，否则保护调用 `world:isValidSquare(x,y,z)`，非 true 时抛带角色的错误。无返回值。 | **实现必需**：validateTargetCoordinates 内 4 处调用（L91、L94、L99、L103）共用同一条 z+world 检查与报错措辞，内联会把同一段判断复制四遍。 |
| preflightLoaded（L107，私有后导出） | cell、bounds；cell 为 nil 时抛「preflight has no IsoCell」，否则直接返回 true。正文注释（L111-L114）说明稀疏模板下 clear 遍历只检查已存在的 square，不要求模板底面或上层 z 预先生成。 | **保留理由**：当前行为只有「cell 非空断言」，`bounds` 参数未被读取，返回恒为 true；但它被 RV_Server_GenerationFlow.lua L180 当作构建前复验钩子调用，也是 targetAreaLoadStatus 的 pcall 目标（L135-L141），删掉需要同时改造三态实现。名字比行为强，属文档/命名问题而非功能缺口。 |
| targetAreaLoadStatus（L122，私有后导出） | player、bounds、可选 safeErrorText；保护调用 ServerWorld.getCellForPlayer，失败时若错误文本包含 "no IsoCell available" 返回 false,message（可重试），否则返回 nil,message（硬失败）；cell 到手后 pcall preflightLoaded，抛错返回 nil,safeText(err)，true 返回 true，false 返回 false,safeText(preflightError)，其他返回 nil,固定文本。 | **必须**：三态是公开协议，RV_Server_Commands.lua L216-L224 用它区分 nil→abort 与 false→本 tick 直接 return（远程传送本身就是 chunk streaming 触发条件，目标 cell 可能尚未可用）。 |
| targetAreaLoadStatus 中默认 safeText 匿名函数（L123） | err；捕获后保护执行 tostring，成功且结果是 string 时返回该文本，否则返回 "<error formatting failed>"。 | **保留理由**：只在该参数缺省时生效；当前唯一调用点 RV_Server_Commands.lua L216 自带了 safeErrorText，所以默认分支实际未被执行。保留它使第三个参数保持可选，删掉会强制所有调用方自备格式化函数。 |

### RV_ServerWorld.lua

模块在 [RV_ServerWorld.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua)，只 require RV_ServerUtil（L7）。头部注释（L1-L5）声明本 chunk 只提供确定性 helper，不注册事件、不接受客户端坐标；`OWNER = "RailroaderRV"`（L8）是所有身份标签的命名空间。L464-L478 导出 15 个函数，其余 13 个（含 1 个匿名）为模块私有。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| getCellForPlayer（L11，私有后导出） | player 或 nil；先保护调用 `player:getCell()`，再退到全局 `getCell()`，都拿不到时抛「no IsoCell available」；返回 cell。 | **必须**：服务端所有 cell 入口。13 处调用点（如 RV_Server_Commands.lua L99、RV_RoofRefresh.lua L113、RV_UtilityPower.lua L68），并且它是 targetAreaLoadStatus 判定「可重试」的错误来源。 |
| getSquare（L23，私有后导出） | cell、x、y、z；保护调用 `cell:getGridSquare(x,y,z)`，成功且非 nil 返回 square，否则 nil；不自行整数化坐标。 | **必须**：19 处调用点（如 RV_Server_GenerationBuild.lua L46/L128、RV_Server_RoomOwnership.lua L82/L305、RV_RoofRefresh.lua L39）。精简后 Common/ServerUtil 都不再导出同名函数，本文件是该封装的唯一实现，不存在两份 getSquare。 |
| collectionSnapshot（L31，私有后导出） | collection、strict、required；collection 为 nil 时：strict 且 required 返回 nil,false,"required square collection is unavailable"，否则空表,true；有 size/get 时按 `size` 与 `get(i)` 逐项复制，枚举失败在 strict 下返回 nil,false,原因；否则按 Lua table pairs 复制；size 不可用且 strict 返回 nil,false,原因。返回数组,complete 或 nil,false,原因。 | **必须**：脱离 Java 容器的统一枚举。内部被 squareSnapshotInternal（L111）使用，外部被 RV_UtilityPower.lua L145 以 `World.collectionSnapshot(collection)` 单参调用（物品 inventory 枚举）。 |
| appendUnique（L67，私有） | result 数组、seen 集合、object；object 非 nil 且未登记时写入 seen 并追加，无返回。 | **实现必需**：square 的多个列表 API（objects/special/moving/world/deadBody/corpse/floor/vehicle）会返回重叠对象，去重后才能安全逐个删除；在 L115、L126、L142、L153 使用。 |
| squareSnapshotInternal（L74，私有） | square、strict；遍历 7 个列表 getter（getObjects/getSpecialObjects/getStaticMovingObjects/getMovingObjects/getWorldObjects/getDeadBodys/getCorpses），getCorpses 记为 optionalGetters；再追加 getFloor、getCorpse/getDeadBody 别名结果与 getVehicleContainer。strict 下 getter 无法探测、必需列表缺失、枚举不完整、floor/corpse/vehicle 读取失败都返回 nil,false,原因；成功返回去重后的对象数组,true。 | **必须**：本文件最核心的枚举语义；squareSnapshot 与 strictSquareSnapshot 都是它的薄封装，删除会同时破坏宽松与 fail-closed 两条路径。 |
| getterAvailable（L81，嵌套私有函数） | getter 名；保护读取 `square[name]`，访问抛错返回 nil（无法判定），否则返回布尔（是否函数）。 | **实现必需**：枚举必须先区分「engine 没有这个 getter」与「读取本身失败」，两者在 strict 下结论不同（L93-L103）。 |
| getterAvailable 中匿名函数（L82） | 捕获 square/name，保护读取 `square[name]`。 | **实现必需**：Java proxy getter 探测不能抛错逃出。 |
| failOrContinue（L86，嵌套私有函数） | message；strict 返回 false,message，宽松返回 true。 | **实现必需**：集中决定「getter 不可用/读取失败」是否中止整次快照（L101-L102、L107-L108）。 |
| squareSnapshot（L158，私有后导出） | square；宽松调用 squareSnapshotInternal，失败时回空数组；返回对象数组。 | **必须**：非事务调用点需要「尽力而为」的对象列表；9 处调用点（如 RV_Server_Commands.lua L109、RV_UtilityWater_Objects.lua L71）。 |
| strictSquareSnapshot（L163，私有后导出） | square；返回 squareSnapshotInternal 的 objects,complete,reason 三元组。 | **必须**：安全清理与占位验证不能把枚举失败当空格。RV_Construction.lua L24、RV_Server_RoomOwnership.lua L501 依赖 `complete == true` 才继续。 |
| objectModData（L167，私有后导出） | engine object；保护取 `getModData()`，结果是 table 时返回**原表引用**，否则 nil。 | **必须且高影响**：生成对象标签的读写口，也是本模块最宽的状态出口。4 个服务端模块经它读写标签：RV_Server_WorldObjects.lua L350/L645、RV_UtilityPower.lua L58、RV_Server_TemplateProtectionRepair.lua L140；详见接口章节。 |
| tagObject（L178，私有后导出） | object、generation、role、tagContext、可选 extraData；要求对象有 modData、generation 为 ≥1 整数、role 非空、`tagContext.rvId` 非空，否则抛错；把 extraData 浅拷贝进新 tag 后依次写入 owner/rvId/generation/role，最后整体赋给 `data.RailroaderRV`。特地把身份字段放在 extraData 之后覆盖，使描述性数据无法伪造身份；不在此处发送 modData 同步（L207-L210 注释：新对象由创建者的完整 object packet 送达，已存在对象如被替换的 floor 在 createFloor 里显式发 delta）。 | **必须**：生成对象的身份来源，清理与回滚都靠它；7 处调用点全部在 RV_Server_WorldObjects.lua（L387、L496、L529、L570、L589、L606、L627）。 |
| isTaggedForGeneration（L213，私有后导出） | object、generation、rvId；generation 或 rvId 为 nil 直接 false；否则要求 tag 是 table、owner == OWNER、generation 数值相等、rvId 字符串相等。返回布尔。 | **必须**：按当前代际筛选清理对象；RV_Server_RoomOwnership.lua L507 用它复核回滚后是否仍有残留 tagged 对象，clearSquare（L453）内部也用它。 |
| isPlayerObject（L224，私有后导出） | object；先 `classInstance(object,"IsoPlayer")`，再保护调用 `object:isPlayer()` 并要求严格 true。 | **必须**：清理必须保护玩家对象；RV_Construction.lua L30、RV_Server_Commands.lua L48、RV_Server_TemplateProtectionRepair.lua L287。 |
| isVehicleObject（L232，私有后导出） | object；先 `classInstance` 检查 BaseVehicle/IsoVehicle，再保护调用 `object:isVehicle()`。 | **必须**：车辆必须走 permanentlyRemove，不能当普通物件摘除；RV_Server_Commands.lua L48、RV_Server_TemplateProtectionRepair.lua L288，clearSquare L446 也用它做先验。 |
| deregisterSpecialSystems（L240，私有） | object；原样返回 object，无副作用。注释说明工具对象就是普通 IsoObject/IsoThumpable，不参与全局集合系统，移除由 transmitRemoveItemFromSquare 负责。 | **当前不是功能必需**：唯一调用点 removeGenericObject L394 忽略返回值，函数体不改变任何状态。保留它是作为扩展钩子；已不再从 M 表导出（精简前曾导出）。 |
| removeCorpse（L247，私有） | square、corpse；调用 `square:removeCorpse(corpse, false)`，API 不可用则抛错。注释说明 B42.20 是双参签名，传 false 才会让服务端发出 RemoveCorpseFromMap，旧的单参探测与 true 回退会吞掉包。 | **必须**：尸体的服务端网络同步删除入口；被 removeZombie（L269）与 removeObject（L427）使用。 |
| removeZombie（L257，私有） | square、zombie；先 `dieNetwork(nil,nil,true,nil)`，失败则 `setHealth(0)` 后重试；成功且有返回尸体时经 removeCorpse 清理并返回；仍失败则回退 `die`/`removeFromWorld`/`removeFromSquare`。无显式返回。 | **必须**：僵尸的专用死亡+清理路径，避免客户端残留活体；唯一调用点 removeObject L419。 |
| removeAnimal（L281，私有） | animal；依次 invoke `delete`、`removeFromWorld`、`removeFromSquare`，不直接改列表。无返回。 | **必须**：IsoAnimal 有独立 B42 生命周期；唯一调用点 removeObject L423。 |
| removeVehicleSafely（L289，私有） | vehicle；`callSucceeded(vehicle,"permanentlyRemove")`，失败即抛「vehicle present but B42.20 permanentlyRemove is unavailable」。 | **必须**：永久车辆删除需要服务端持久化与网络删除，不能猜路径；唯一调用点 removeObject L415。 |
| validateVehiclePath（L298，私有） | vehicle；要求 `vehicle.permanentlyRemove` 是函数，否则抛同样的错。 | **必须**：clearSquare（L445-L450）在删除任何对象之前先验证所有车辆的删除路径，把「API 缺失」变成干净的整笔失败而不是部分删除。 |
| getSpriteName（L304，私有后导出） | object；经 `getSprite()`→`getName()` 取名字并 tostring，任一环节失败或 nil 返回 nil。 | **必须**：楼板回滚与模板修复需要按 sprite 名比对/恢复；5 处调用点（RV_Server_WorldObjects.lua L243/L343、RV_Server_Commands.lua L123、RV_Server_TemplateProtectionRepair.lua L182/L274）。 |
| clearGenerationTag（L316，私有） | object；要求有 modData，否则抛错；仅当 tag 是 table 且 owner == OWNER 时清空 owner/rvId/generation/role/previousSprite/createdByGeneration，保留命名空间本身（注释说明专用服务端 Kahlua 不提供 `next`，空命名空间安全且不碰其他 modData 键），随后要求 `transmitModData` 成功，否则抛错。 | **实现必需**：restoreTaggedFloor L385 的唯一依赖，负责「还原旧 floor 后去掉本代标记并同步客户端」；不导出，避免外部绕过身份检查。 |
| squareContainsObject（L338，私有后导出） | square、object；取 `getObjects()` 并按其 size 逐个 `get(i)` 做引用比较；任一 API 不可用返回 nil（不确定），找到 true，完整遍历未找到 false。 | **必须**：transmitRemoveItemFromSquare 之后必须用权威 cell 观察删除是否真的生效；RV_Server_WorldObjects.lua L692/L789、RV_Server_TemplateProtectionRepair.lua L322。 |
| restoreTaggedFloor（L362，私有） | square、object；tag 必须是 table、owner == OWNER、`createdByGeneration == false` 且 tag.previousSprite 非空，否则返回 false；当前 sprite 读不到时抛错；sprite 与 previousSprite 不同则 `getSprite(previousSprite)`、`setSprite`、`transmitUpdatedSpriteToClients` 三步全部要求成功，否则抛错；最后 clearGenerationTag 并返回 true。 | **实现必需**：回滚时把「生成前就存在的 floor」还原而不是删除；唯一调用点 removeGenericObject L391。 |
| removeGenericObject（L389，私有后导出） | square、object、restoreTaggedFloors；`restoreTaggedFloors` 为真、对象就是该 square 的 floor 且 restoreTaggedFloor 成功时直接返回（还原而不删除）；否则调 deregisterSpecialSystems，再 `transmitRemoveItemFromSquare(object)`，要求成功且返回索引是 ≥0 数，然后用 squareContainsObject 要求结果严格为 false，否则抛错。 | **必须**：普通物件/楼板的统一移除并验证；4 处调用点（RV_RoofRefresh.lua L106、RV_Server_WorldObjects.lua L390/L686、RV_Server_TemplateProtectionRepair.lua L336）。 |
| removeObject（L410，私有） | square、object、restoreTaggedFloors；玩家直接跳过；车辆走 removeVehicleSafely；IsoZombie → removeZombie；IsoAnimal → removeAnimal；IsoDeadBody → removeCorpse；其余走 removeGenericObject。无返回。 | **实现必需**：clearSquare 的类型分派点，保证特殊世界对象不会走到通用删除；唯一调用点 clearSquare L458。 |
| recalcSquare（L433，私有后导出） | square；调用 `RecalcProperties()` 与 `RecalcAllWithNeighbours(true)`（注释说明小写拼写不是 engine 方法，旧实现因此留下过期碰撞/房间缓存）。无返回。 | **必须**：世界变更后刷新碰撞、房间与邻格缓存；4 处调用点（RV_Server_GenerationBuild.lua L56、RV_Server_WorldObjects.lua L414/L439/L539）。 |
| clearSquare（L441，私有后导出） | square、可选 onlyGeneration、rvId；先取宽松快照，对「将按身份删除」的车辆逐台 validateVehiclePath（先验，避免删到一半才发现 API 缺失）；再按 `onlyGeneration == nil` 或 isTaggedForGeneration 过滤逐个 removeObject，其中 restoreTaggedFloors 参数取 `onlyGeneration ~= nil`（代际回滚才还原旧 floor，仅清理时连上一代留下的 tagged floor 也删）；最后 recalcSquare。无返回，异常中止。 | **必须且高影响**：生成清理与回滚的唯一执行入口。RV_Server_GenerationBuild.lua L98 传 `(square, nil)` 做整区清理，RV_Server_RoomOwnership.lua L492 传 `(square, generation, rvId)` 做代际回滚。 |

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **通用 Java 调用只有一份实现，不要再加一层**：invoke/callGlobal/invokeClass/classInstance/toNumber/integer 全在 RV_Common（L7-L78），RV_ServerUtil L37-L45 只是把同一批函数引用转出，不是第二份实现。外部模块两条路径都用：RV_BoundaryServer_Objects.lua L12 直接 require RV_Common（只用 classInstance，L134-L135），其余经 ServerUtil 或 ctx 注入。判断：现状合理，ServerUtil 的门面价值在 Kahlua 活跃局部上限（RV_ServerUtil.lua L1-L5）而不是抽象。
- **finite/integer 判断存在多处并行实现，可提取但需先统一语义**：
  - 规则等价但返回语义不同：`Common.isFiniteNumber`（L67）返回布尔且**不转换**输入；shared 的 `RV_Constants.C.finiteNumber`（RV_Constants.lua L13-L31）返回 number 或 nil，并会把 string 与 Java 包装值转换；`C.finiteInteger`（L33-L37）在它之上再收整数。`Common.integer`（L72）与 `C.finiteInteger` 规则完全等价，只是实现各写一遍。
  - 另有 8 处模块内手写同类判断：RV_UtilityPower.lua L17-L20、RV_BoundaryServer_Geometry.lua L29-L32、RV_StrictSchema.lua L6、RV_RoomTemplate.lua L19、RV_UtilityStore.lua L38、RV_Server_TemplateProtectionRepair.lua L23、RV_Server_WorldObjects.lua L13、RV_Server_RoomOwnership.lua L189-L191。
  - 证据与净收益：这些手写点里至少 4 处（Power/WorldObjects/TemplateProtectionRepair/RoomOwnership）是先 `toNumber` 再比 `math.huge`，与 Common.isFiniteNumber+C.toNumber 的组合等价。合并能消除规则漂移，但成本是 server 公共层要么依赖 shared 常量、要么把「转换+finite+integer」三层合并导出，且会改变错误语义（nil / boolean / 抛错三种）。判断：**当前不建议立即合并**；当出现第三处需要「同一返回语义」的调用点时，再把 `C.finiteNumber`/`C.finiteInteger` 作为唯一实现、Common 侧改为转发。
- **integer 与 requiredInteger 的分层必须保留**：`Common.integer`（L72）失败给 nil，服务探测式读取用；`ServerUtil.requiredNumber`/`requiredInteger`（L20/L28）失败抛带字段标签的错误，客户端 payload 与 bounds 字段用（RV_Server_RoomOwnership.lua L454、L326/L480/L531；RV_Server_PlayerValidation.lua L27）。这是「宽松解析」与「严格合同」两种策略，不应合并成一个函数。
- **getSquare 已无重复实现**：精简后 RV_Common 与 RV_ServerUtil 都不再导出 getSquare，RV_ServerWorld.getSquare（L23）是唯一封装。树内仍有 3 处直接调用 `getGridSquare`：RV_BoundaryServer_Geometry.lua L144（服务端，自带 `call` 风格）、client RV_ContextMenu_RoomOwnership.lua L67 与 client RV_ContextMenu_Relocation.lua L78（客户端不能 require server 模块，属正常边界）。判断：服务端那一处可以改用 ServerWorld.getSquare，但封装体只有 6 行且无额外语义，替换收益接近于零，说明即可，不必提取新公共函数。
- **objectModData 有一份重复实现，且存在第二个 tag 写入方**：RV_BoundaryServer_Objects.lua L18-L21 自写 `getModData`→table 读取，与 ServerWorld.objectModData（L167-L173）等价；该文件 L309 还直接写 `data.RailroaderRV = {...}`。判断：前者是可提取项（改用已导出的 ServerWorld.objectModData 即可删掉 4 行），净收益小但方向明确；后者是真正的复用缺口 —— tagObject（L178-L211）是唯一强制 owner/rvId/generation/role 的写入路径，playerBuilt 标签绕过它意味着「同一 namespace 两种 tag 形状」这一事实只存在于两个文件的注释里（见接口章节）。
- **对象枚举去重（appendUnique/collectionSnapshot/squareSnapshotInternal）是本目录单点实现**，其他模块只通过 ServerWorld 的导出消费，未发现重复的枚举/去重实现。
- **布局几何校验在本目录已被移除，不要再引回**：boundsFor（L13-L42）现在只做字段展开，旧版的 wall/shell 合同校验已由 RV_Server_RecordValidation.lua L174（boundary.shellEdges 形状）与 RV_BoundaryServer_Geometry.lua L180/L200（encodeShellEdges）承担，ledger 本身由 RV_Layout.lua L278-L306 生成、L315/L325-L326 汇总 wallEdgeCounts/wallCornerCount。判断：这些规则依赖当前 RV template/schema，不适合作为通用 server helper 重新塞回本目录。

### 是否进一步拆分

- **RV_ServerWorld（480 行）是唯一值得评估的对象，但当前不建议拆**。四段职责清晰：collection/square 快照（L31-L165）、身份标签与 modData（L167-L222）、特殊实体删除（L240-L408）、square 事务（L433-L462）。不拆的理由是它们共享同一个事务上下文（clearSquare→removeObject→removeGenericObject→restoreTaggedFloor→clearGenerationTag→recalcSquare），拆开需要把这些私有步骤变成跨文件导出，反而扩大接口面。若继续增长，优先拆「对象枚举/快照」与「身份标签」两块 —— Construction、Power、TemplateRecovery 只消费这两类语义（RV_Construction.lua L22-L30、RV_UtilityPower.lua L58/L145、RV_Server_TemplateProtectionRepair.lua L140）。
- **RV_ServerSchema（157 行）可分三类职责**：bounds 展开（L13-L42）、clear 区域遍历（L43-L57）、目标几何校验（L59-L106）与加载状态三态（L107-L149）。当前规模与依赖方向（后半依赖前半的 bounds 合同）都不支持拆分；若 z/world 约束或加载策略继续增长，可把 preflightLoaded/targetAreaLoadStatus 独立成「loaded-area 适配」，因为它们是唯一与 cell/加载时序相关、其余函数只做纯计算的边界。
- **RV_Common（92 行）、RV_ServerUtil（50 行）、RV_ServerTeleport（44 行）不需要拆**：Common 无状态、无 require；ServerUtil 是受 Kahlua 活跃局部上限驱动的门面（L1-L5），拆开就失去存在理由；Teleport 两个函数紧密相关且只依赖 Common。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **RV_Common**：`return Common`（L92）导出 10 个函数字段（L7、L17、L22、L37、L45、L50、L57、L67、L72、L80）；模块无状态、不注册事件、不写存档。直接 require 的消费者只有 RV_ServerUtil.lua L7、RV_ServerTeleport.lua L3、RV_BoundaryServer_Objects.lua L12。
- **RV_ServerUtil**：L37-L48 的 M 表是公开 facade（12 个字段，10 个为 Common 引用）；不暴露 Common 的局部变量。核心消费方是 Core/RV_Server.lua L80（再经 ctx 分发给各 server 子模块）。
- **RV_ServerWorld**：L464-L478 导出 15 个函数，全部有真实外部调用点：getCellForPlayer(13 处)、getSquare(19 处)、collectionSnapshot(1 处)、squareSnapshot(9 处)、strictSquareSnapshot(2 处)、objectModData(4 处)、tagObject(7 处)、isTaggedForGeneration(1 处 + 内部)、isPlayerObject(3 处)、isVehicleObject(2 处)、getSpriteName(5 处)、squareContainsObject(3 处)、removeGenericObject(4 处)、recalcSquare(4 处)、clearSquare(3 处，含注释引用)。未导出的是 appendUnique、squareSnapshotInternal、getterAvailable、failOrContinue、deregisterSpecialSystems、removeCorpse、removeZombie、removeAnimal、removeVehicleSafely、validateVehiclePath、clearGenerationTag、restoreTaggedFloor、removeObject。
- **RV_ServerSchema**：L151-L155 导出 5 个函数 —— boundsFor（GenerationFlow.lua L375、RV_Server_RecordValidation.lua L52）、walkBounds（RV_Construction.lua L22、GenerationBuild.lua L97、RoomOwnership.lua L491/L500）、validateTargetCoordinates（GenerationFlow.lua L384）、preflightLoaded（GenerationFlow.lua L180）、targetAreaLoadStatus（Commands.lua L216）。
- **RV_ServerTeleport**：L5/L18 两个方法；Core 在 RV_Server.lua L138-L139 转出为 `RV.Server.teleportToPosition` / `RV.Server.teleportToRVSpawn`，前者被 PlayerValidation.lua L213/L268、WallReloadProtection.lua L138-L139、BoundaryServer_Sweep.lua L95-L96 使用，后者只有 RV_RailroaderServer_EntryExit.lua L179。

### 直接读写其他模块的数据

1. **没有发现外部模块读取这 5 个文件的私有局部变量或闭包状态**：模块级隐藏状态只有 `OWNER`（RV_ServerWorld.lua L8）；所有跨模块访问都经上表的导出字段。
2. **layout / bounds / mapping record 属跨模块 value-object 合同，字段直读是消费公开数据，不是访问模块隐藏状态**：
   - RV_ServerSchema.boundsFor 读 layout.clear、managed、room、wall、roof、wallEdgeCounts、shellEdges、wallCoordinates、wallObjectCount、wallCoordinateCount、wallCornerCount、anchor（L14-L41），由 RV_Layout 产出；L62 调 RegionSlots.indexForAnchor 做锚点→槽位判定。
   - bounds 的下游字段读取：RV_Server_GenerationBuild.lua L83（roomMinX/roomMinY/z）、RV_Server_RoomOwnership.lua L446-L457（wall/room/roof 的 min/max 与 z/roofZ，共 14 个字段经 requiredInteger 复制进网络 payload）。
   - RV_ServerTeleport.lua L20-L31 经 `_G.RailroaderRV.RailroaderServer` 取 adapter，调 `currentMappingRecord(rvId, generation)`（实现见 RV_RailroaderServer_Mapping.lua L283、L310）并消费 `record.rvPosition`；同一方法已是公开查询口，另有 RV_Server_RecordValidation.lua L15-L21、RV_UtilityPower.lua L86、RV_BoundaryServer_Sweep.lua L62 在使用。
   - 判断：都**不应改为新接口**。bounds 是纯值对象；currentMappingRecord 是 mapping 已公开的方法，Teleport 只是多一个调用者。唯一可议的是 Teleport 用 `rawget(_G, ...)` 硬取适配器（L20），代价是失败时只能返回 false、没有原因文本；这是为了避免 server 公共层反向依赖 RVMapping。
3. **ServerWorld.objectModData 暴露 engine 可变 ModData 原表（L167-L173，导出 L469）**，调用方直接读写 tag 字段：
   - RV_Server_WorldObjects.lua L350-L356 读旧 tag 的 previousSprite/createdByGeneration，L385-L386 写回新 floor 的这两个字段；L645-L646 读 tag（generator 校验路径）。
   - RV_UtilityPower.lua L58-L59 读 `data.RailroaderRV` 做生成归属判断。
   - RV_Server_TemplateProtectionRepair.lua L140-L141、L150 读 `tag.templateIndex`。
   - 判断：**保留直接访问**。这是显式导出的数据口，读多写少；tag 字段布局本身就是跨模块合同（`templateIndex` 是「标签只存索引、属性由模板解析」这一设计的核心，RV_ServerWorld.lua L175-L177 注释）。新增 getTag 查询能隐藏字段名，但会把「哪些字段稳定」变成隐式承诺，在 4 个调用点的规模下收益不足。另有 RV_RailroaderServer_WallReload.lua L143-L145、L206-L207 及 3 个客户端文件（RV_WardrobeVisuals.lua L48-L51、RV_BoundaryWallVisuals.lua L42-L44、RV_ProtectedDemolition.lua L191-L207）不走 ServerWorld 而自取 modData —— 客户端不能 require server 模块，属正常边界。
4. **第二个 tag 写入方是真实的接口边界问题**：RV_BoundaryServer_Objects.lua L309 直接写 `data.RailroaderRV = { owner, playerBuilt, builder, rvId, generation, edgeKey, edgeKeys, footprint }`，绕开 tagObject；同文件 L18-L21 自带 objectModData、L25-L32 自带只校验 owner 的 rvTag。当前不构成缺陷（isTaggedForGeneration 只比较 owner/generation/rvId，L213-L222，两套字段集不冲突），但「canonical namespace 有两个 writer」意味着 tagObject 的身份覆盖顺序保证（L196-L206）在这条路径上不成立。**这是本目录最值得收紧的位置**：至少应共享一个「写 canonical namespace」的导出函数，或在 ServerWorld 上显式声明 playerBuilt tag 是受支持的第二形状。
5. **validateVehiclePath（L298-L302）直接读 `vehicle.permanentlyRemove`** 是检查 engine 公共方法以保证破坏性操作可执行，不是访问其他 RV 模块的内部状态。

### 接口边界问题

- **ServerUtil 把 10 个 Common 函数原样转出**（L37-L46），形成 `Common.foo` 与 `ServerUtil.foo` 两条服务端路径。不泄露数据，但会让新代码出现风格分叉；除必须直接用 classInstance 的 RV_BoundaryServer_Objects.lua 外，建议新服务端模块统一走 ServerUtil（或 ctx 注入）。
- **collectionSnapshot 的 strict/required 参数（L31-L38、L61-L64）在外部调用中未被使用**：唯一外部调用 RV_UtilityPower.lua L145 只传 collection，走的是 `strict=nil, required=nil` 的宽松分支；strict 语义只有 squareSnapshotInternal（L111-L112）在用。参数本身是内部策略，公开时容易被误读为「调用方可以要求失败关闭」。
- **walkBounds 的 requireLoaded（L43、L48-L50）当前四个调用点都不传**：这条「clear bounds 必须全部已加载」的 fail-closed 路径目前不可达；它是有意保留的开关还是历史残留，需要从需求侧确认（本报告只陈述源码事实）。
- **preflightLoaded（L107-L116）名实不符**：正文只断言 cell 非 nil 并返回 true，`bounds` 未被读取，而 GenerationFlow.lua L180 把它当构建前复验调用。当前没有功能缺口（稀疏模板策略就写在同一段注释里），但名字会持续误导调用方。
- **targetAreaLoadStatus 三态是公开协议**：true=继续、false=本 tick 可重试（仅 L130-L133 的 "no IsoCell available" 与 L145-L147 的 loaded==false 两种）、nil=合同/engine 硬错误（L140、L148）。RV_Server_Commands.lua L218-L224 正确区分 nil→abort 与 false→return，调用方不能把两种失败合并。
- **deregisterSpecialSystems（L240-L245）是 no-op 且已不再导出**（精简前曾在 M 表导出），仅由 removeGenericObject L394 调用并忽略返回；作为扩展钩子保留可以，但不应重新导出。
- **RV_ServerTeleport 的失败信息只有 false**：teleportToPosition/teleportToRVSpawn 丢弃了底层错误（L11-L13、L25-L30），调用方无法区分「mapping 记录缺失」「坐标非有限」「teleportTo 失败」。当前调用点都只做布尔判断，属可接受取舍，但排障只能靠外层日志。

## 函数清单、覆盖和验证记录

- **扫描文件**：RV_Common.lua(92 行)、RV_ServerUtil.lua(50 行)、RV_ServerTeleport.lua(44 行)、RV_ServerSchema.lua(157 行)、RV_ServerWorld.lua(480 行)；目录扫描未发现子目录或其他代码文件，5 个文件合计 823 行。
- **扫描函数**：本目录 `function` 关键字扫描后逐行核对定义（排除 `type(x) ~= "function"` 类判定行）：RV_Common 17 处关键字中 13 个定义 + 4 个类型判定；RV_ServerSchema 7 个定义；RV_ServerTeleport 4 处中 2 个定义 + 2 个类型判定；RV_ServerUtil 2 个定义；RV_ServerWorld 31 处中 29 个定义 + 2 个类型判定。计数为 13/2/2/7/29，合计 **53**（48 具名 + 5 匿名）；匿名条目为 RV_Common.lua L9、L26、L62，RV_ServerSchema.lua L123，RV_ServerWorld.lua L82。
- **逐行交叉核对**：逐文件编号读取源码全文；条目中的行号是定义语句（`function`/`local function`）的起始行。导出位置：RV_Common 返回表（10 字段）、RV_ServerUtil.lua L37-L48（12 字段）、RV_ServerTeleport.lua L5/L18（2 字段）、RV_ServerSchema.lua L151-L155（5 字段）、RV_ServerWorld.lua L464-L478（15 字段）。
- **跨模块调用扫描**：在 media/lua 全树按「require 别名 + ctx 注入」两种绑定方式搜索导出符号，确认每个导出字段的调用点（见上表与公开合同小节）；同时用同样方式核查旧报告怀疑过的 API —— floorInt、isEmptyCommandArgs、copyPoint、makeLayout、getSquare（Common/ServerUtil 版）、newPlayerPositionCache、getPlayerPosition、exactKeys、copyPlain、withTagIdentity、eachStructureSquare、validateWallContract、validateShellEdgeContract 在当前源码中**已不存在**；重点结论是当前 12+5+15+2 个导出字段**没有**「零调用者」的死导出（collectionSnapshot 只有 1 个外部调用点，但仍在使用）。
- **未覆盖项 / 条件性推断**：没有穷举每个 API 的全部调用行（大文件只核查了命中的符号行）；`requireLoaded`、`preflightLoaded`、默认 safeText 等「当前未被执行」的结论来自静态调用点分析，属源码事实；「合并 finite 判断的净收益」「拆分 RV_ServerWorld 的收益」属条件性推断，未做改造实验。未运行游戏或 runtime 测试，本文不宣称运行时行为已验证；本报告用于替换描述精简前代码的旧版报告，旧版行号与函数数（合计 80）对当前源码已失效。
- **修改范围**：仅重写本分析文档；未修改任何 Lua 源码、配置或测试文件，未运行任何测试脚本。
