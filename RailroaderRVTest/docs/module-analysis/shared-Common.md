# shared/RailroaderRV/Common 模块分析

## 假设、范围、成功条件与验证方式

- **假设**：只分析模组当前目录 `media/lua/shared/RailroaderRV/Common/` 的 4 个直接子文件，行号以本次读取的当前源码版本为准（本目录 4 个文件合计 322 行：136 + 13 + 61 + 112）。shared 层在客户端与服务端都会被加载，因此这里按「双端共享合同」解释，不按任一端的调用语义解释；凡涉及提取的结论都额外检查「shared 不得反向依赖 server 路径」这条加载方向约束。
- **范围**：覆盖 4 个文件的全部具名函数、`local function`、表方法与匿名函数表达式；只读检索整个 `media/lua` 树（当前 65 个 `.lua` 文件）用于判断导出 API 的真实使用面与跨模块数据访问。唯一写入目标是本报告。
- **成功条件**：每个函数都有精确起始行、参数含义、返回/副作用、本模块语义和必要性判断；另外给出复用/提取/拆分建议、接口边界证据，并明确区分「源码事实」与「条件性推断」。不运行游戏或 runtime 测试。
- **验证方式**：列目录文件与行数；用 `function` 关键字扫描并排除 `type(x) ~= "function"` 类比较行，再与逐行编号全文读取交叉核对定义与起始行；用全树调用搜索核对每个导出符号的调用点（按 `require` 别名、`RailroaderRV.*` 全局表、ctx 注入三种绑定方式分别核查）；完成后核对报告的文件清单、函数条目数与行号引用。源码扫描是静态分析，不替代运行时验证。

## 目录职责与清单

Common/ 目前含四类职责：共享协议与布局常量（含宽松数值正规化）、严格标量 schema 原语、utility 数据合同、隐藏 sprite 注册。四个文件互不依赖同目录兄弟文件的实现，只有 `RV_UtilityConstants.lua` 与 `RV_UtilitySprite.lua` require `RV_Constants`。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_Constants.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_Constants.lua) | 3 | 全包唯一的共享常量表：mod/命令/ModData 键、save schema 版本、RV 区域与 Z 范围、传送与偏移、sprite 与生成器参数；外加两个宽松数值正规化函数 |
| [RV_StrictSchema.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_StrictSchema.lua) | 1 | 严格标量 schema 原语：唯一导出 `integer`，只接受原生 Lua number，不转换字符串或 Java 包装 |
| [RV_UtilityConstants.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_UtilityConstants.lua) | 0 | utility（水/电）层数据合同：store key、reach、请求长度、operation/state/reason 稳定码；另转出 `PowerConfig` 并触发 utility items 加载 |
| [RV_UtilitySprite.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_UtilitySprite.lua) | 6 | 注册并校验隔离的隐藏 utility sprite（含 ID 碰撞拒绝、双索引一致性、blueprint 属性后置条件）与一次性 `OnGameBoot` 安装入口 |
| **总计** | **10** | 5 个表方法 + 4 个 `local function` + 1 个匿名函数表达式 |

函数计数口径：计入具名函数、`local function`、表方法（`C.foo = function` / `function M:foo()`）和作为参数/回调的匿名函数表达式；不计入纯常量字段赋值与 `M.foo = localFunction` 形式的导出别名。计数时必须排除 `type(x) == "function"` 这类比较行 —— 本目录唯一命中该陷阱的是 `RV_UtilitySprite.lua` L16 与 L105（两行均不是函数定义）。本目录没有 `M.foo = localFunction` 导出别名。

## 逐文件、逐函数分析

### RV_Constants.lua

模块在 [RV_Constants.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_Constants.lua)，无 `require`、无事件注册、无存档写入，只把常量写进本地表 `C`（L11）并 `return C`（L136），同时发布到全局 `RailroaderRV.Constants`（L9）。行分四组：两个数值正规化函数（L13-L37），协议与布局常量（L39-L131），其中 `SAVE_SCHEMA_VERSION = 9`（L54）是全包唯一的存档 schema 版本号 —— 本次全树搜索 `schemaVersion|SCHEMA_VERSION` 只命中 `RV_Constants.lua:54` 与消费方 `RV_RailroaderServer.lua:53/L58/L60/L61`、`RV_RailroaderServer_EntryExit.lua:492`；`RV_RoomTemplate.lua:7` 的 `CURRENT_TEMPLATE_VERSION = 11` 是模板数据版本，属另一条合同，不是存档 schema 版本。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| C.finiteNumber（L13） | value 任意：`number` 原样、`string` 走 `tonumber`、其他非 nil 值走受保护的 `value + 0`（L23 匿名闭包）以兼容网络表里的 Java 数值包装；返回有限 Lua number，NaN/±Inf/不可转换返回 nil（L26-L30）。无写入型副作用，仅创建一次性闭包。本模块语义：共享层唯一的**宽松**数值正规化入口，负责把跨网络到达的字符串与 Java 代理值收敛成有限 number。 | **必须**：它是本文件 `finiteInteger` 的底座，也是客户端读取网络 payload 的唯一宽松转换实现。本次全树检索 `finiteNumber` 的 33 处命中显示消费者**全部在 client**（`RV_RailroaderContextMenu.lua:18/L59/L76-L77/L211-L212/L267/L411-L412/L630`、`RV_ContextMenu_RoomOwnership.lua:11/L290`、`RV_ContextMenu_Relocation.lua:20` 经 ctx 注入），shared/server 内没有任何调用点。删掉会让客户端被迫各写一份网络数值转换。 |
| C.finiteNumber 中匿名函数（L23） | 捕获 value，无参数；受 `pcall` 保护执行 `value + 0`，返回转换结果或错误对象，由外层判断 `type(numeric) == "number"`。 | **实现必需**：注释（L21-L22）说明 Java 数值代理的算术可能抛错，探测必须被折叠成 nil 而不是打断调用方；若内联成普通表达式，一次代理异常就会逃出 `finiteNumber`。 |
| C.finiteInteger（L33） | value 同 `finiteNumber` 的输入域；先经 `finiteNumber`，再要求 `math.floor(number) == number`（L35），返回整数 number 或 nil。无副作用。本模块语义：宽松输入 → 严格整数输出的正规化规则，用于把客户端 payload 的 onlineId/generation/坐标收敛成整数。 | **必须**：`finiteInteger` 全树 53 处命中，是客户端协议解析的实际标准（`RV_ProtectedDemolition.lua:34-L35/L84/L106/L111-L112/L156`、`RV_WardrobeVisuals.lua:55/L60/L78`、`RV_BoundaryWallVisuals.lua:48/L52/L75`、`RV_ContextMenu_RoomOwnership.lua` 多处，并经 `RV_ContextMenu_RoomOwnership.lua:291` 以 `ctx.finiteInteger` 转发给 `RV_ContextMenu_Relocation.lua`）。**不能**用它替换 `RV_StrictSchema.integer`：后者只接受原生 number，本函数接受数字字符串与可算术转换的 Java 包装，输入合同不同（见复用章节）。 |

### RV_StrictSchema.lua

模块在 [RV_StrictSchema.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_StrictSchema.lua)，共 13 行，无 `require`、不发布全局、不注册事件，`local M = {}`（L2）后 `return M`（L13）。它是 shared 层最小严格标量合同，当前**只有 1 个导出函数**。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| M.integer（L4） | value 任意；只接受 `type(value) == "number"`，且非 NaN（`value ~= value`）、非 ±Inf（L6）、`math.floor(value) == value`（L9）；返回原 number 或 nil。**不**转换字符串、**不**做受保护算术转换。无副作用、不写任何表。本模块语义：shared 层的严格 schema 原语 —— 判定「这个值是不是当前 schema 允许的整数」，而不是「能不能变成整数」。 | **必须**：3 个模块、4 个调用点都在用，且跨双端：shared `RV_RegionSlots.lua:21`、shared `RV_UtilityCatalog.lua:13`、server `RV_UtilityWater_Objects.lua:25`。三处都把 `integer` 直接绑成局部名再用于槽位索引、锚点、tag 与 hint 字段；它是「槽位索引必须是干净的 Lua 整数」这一契约的唯一实现。 |

### RV_UtilityConstants.lua

模块在 [RV_UtilityConstants.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_UtilityConstants.lua)，文件头（L1-L5）自称 deliberately data-only，实际含两个有副作用的 `require`：L14 把 `RV_UtilityPowerConfig` 表挂成 `U.POWER`，L15 `require RV_UtilityItems` 会执行 `Recipe.OnCreate.RVUtilityCharger`/`RVUtilityInverter` 的注册（`RV_UtilityItems.lua:3-L4`、L41、L45）。其余 40 余行全是数据合同字段，无任何函数定义。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| —（本文件函数定义数为 0，无数据行） | — | — |

本文件不提供函数，`return U`（L61）导出的是纯数据表；`U.POWER`（L14）是另一个模块的表引用而非本文件实现。数据字段的消费面（源码事实）：`STORE_KEY` → `RV_UtilityStore.lua:48/L55/L137`；`DEVICE_REACH` → `RV_UtilityWater_Objects.lua:56`；`MAX_REQUEST_ID_LENGTH` → `RV_UtilityServer.lua:100`；`WATER_STATE_ACTIVE` → `RV_UtilityStore.lua:70`、`RV_UtilityWater_Commands.lua:28`；`POWER_STATE_READY` → `RV_UtilityStore.lua:82`、`RV_UtilityPower.lua:310`；`CIRCUIT_ON`/`CIRCUIT_OFF` → `RV_UtilityPower.lua:240/L249/L347/L607/L635`、`RV_UtilityStore.lua:75`；`REASONS.*` 70 处；`REASON_INVALID_RV_DATA` → `RV_UtilityClient.lua:253`、`RV_UtilityServer.lua:34/L63`；`OP_*` 125 处（客户端 `RV_UtilityClient.lua`、`RV_UtilityDashboard.lua` 发出，服务端 `RV_UtilityServer.lua:108-L116`/`RV_UtilityPower.lua:569-L590` 消费）；`U.POWER` → `RV_UtilityDashboard.lua:359`、`RV_UtilityServer.lua:309`。

### RV_UtilitySprite.lua

模块在 [RV_UtilitySprite.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_UtilitySprite.lua)，只 require `RV_Constants`（L8）。它把「注册一个隔离隐藏 sprite 并使它在服务端 add 包与客户端 intMap 里解析为同一个 blueprint sprite」这件事做成幂等操作：先查名称表判断是否已注册，再拒绝数字 ID 碰撞，最后校验 sprite 的 ID、名称与 blueprint 属性三者后置条件。隐藏状态只有模块级 `local eventRegistered = false`（L11）和 4 个私有 helper；`return M`（L112）只导出 2 个函数。全树检索 `AddSprite|IsoSpriteManager|getNamedMap` 显示**没有任何其他模块重复实现这类 sprite 注册**。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| invoke（L13） | target 对象、method 方法名、可变方法参数；target 为 nil 或 `type(target[method]) ~= "function"` 时返回 false,nil（L16）；`pcall` 调用失败返回 false,error（L18）；成功返回 true 及最多两个返回值。无副作用（被调方法自身可能有）。本模块语义：本文件所有 Java 交互（IsoSpriteManager、IsoSprite、IsoSpriteProperties）的唯一保护调用点。 | **实现必需**：L16 的 `type(fn) ~= "function"` 判定本身是计数陷阱行而非定义；该 helper 被 `callSucceeded`、`ensureBlueprint`、`ensureOne`、`ensureHiddenSprites` 共 14 处调用。Java 代理的方法读取与调用都可能抛错，不折叠就会让一次 sprite 注册异常逃到 `OnGameBoot` 事件链上。 |
| callSucceeded（L22） | 与 `invoke` 同参；把结果折叠为「调用成功且首个返回值不为 false」的布尔值（L23-L24）。 | **实现必需**：blueprint 的 `set`/`CreateKeySet` 与 sprite 的 `setName` 都是「返回 false 表示失败」的 setter，需要一个与 `invoke` 分层、只回答成败的判定；当前 3 处调用（L36、L37、L75）。 |
| ensureBlueprint（L27） | sprite；经 `rawget(_G, "IsoFlagType")` 取 blueprint 标志（L28-L29），读 properties（L31-L32），`has` 判定并必要时 `set` + `CreateKeySet`（L36-L38），最后复读 `has` 要求严格 true（L40-L41）；返回 true 或 false,reason。副作用：修改该 sprite 的 properties 位标志。 | **必须**：文件头注释（L4-L6）说明 blueprint 是共享 IsoSprite 实例的属性，借用普通家具 sprite 会让所有使用该 sprite 的对象一起变形，因此隐藏 sprite 必须**自己**带上 blueprint；这是隐藏 IsoThumpable 参与方块属性聚合与 add 包的前置条件，且复读后置条件不可省。 |
| ensureOne（L45） | manager、namedMap、key sprite 名、id 数字 ID；先查名称表（L46），不存在时先查 `getSprite(id)` 拒绝碰撞（L53-L55）再 `AddSprite(key, id)`（L56）；随后校验 `sprite:getID() == id`（L61-L66）、`manager:getSprite(id)` 与 `manager:getSprite(key)` 双向都指向同一 sprite（L67-L70）、名称为 key（L72-L81）、blueprint 就绪（L83）；返回 true,sprite 或 false,nil,reason。副作用：可能写入 sprite manager 的 intMap 与名称表、设置 sprite 名称与属性。 | **必须**：这是本模块唯一会改动游戏全局资源的函数，四处后置条件各自对应一种真实失败：ID 被无关 sprite 占用、名称表命中了别的对象、两个索引不一致、名称与蓝本不一致。注释（L50-L52）明确 `AddSprite` 会先写 intMap 再返回，所以碰撞检查必须放在它之前。 |
| M.ensureHiddenSprites（L88） | 无参数；`rawget(_G, "IsoSpriteManager").instance` 缺失时 false,nil,"sprite-manager-missing"（L89-L91），否则取 `getNamedMap`（L96-L97）后以 `C.UTILITY_HIDDEN_SPRITE_KEY` / `C.UTILITY_HIDDEN_SPRITE_ID` 调 `ensureOne`（L98-L99）；返回 true,sprite 或 false,nil,reason。副作用：可能注册 sprite。 | **必须**：对外幂等安装口，客户端与服务端都直接用它（server `RV_Server_WorldObjects.lua:71`、L456）。注释（L93-L95）说明不能每次启动盲目 `AddSprite`，否则会替换已有 Java 对象并破坏对象指针身份与 intMap —— 这条语义只在这里实现。 |
| M.install（L102） | 无参数；先调 `M.ensureHiddenSprites`（L103），再在 `Events.OnGameBoot.Add` 可用且未注册过时注册**具名**的 `M.ensureHiddenSprites`（L104-L107），置 `eventRegistered = true`；返回被调用那次的 ok,sprite,reason。副作用：修改 sprite manager + 订阅一次 OnGameBoot + 改模块级 `eventRegistered`。 | **必须**：客户端唯一入口 `RV_UtilityClient.lua:12` 在模块加载时调用它并只用返回值做日志（L12-L15），真正的重试依赖 OnGameBoot 事件。删掉 `install` 会让客户端失去「sprite manager 尚未就绪时下次 boot 重试」的能力。注意 L104-L107 注册的是具名函数引用，**不产生匿名函数表达式**，因此不单独计数。 |

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **共享严格原语已经收敛成一份（已消除的重复）**：`RV_StrictSchema.integer`（L4-L11）是 shared 内唯一严格整数判定，`RV_RegionSlots.lua:7/L21` 与 `RV_UtilityCatalog.lua:7/L13` 都改为绑定它，不再各留一份私有 `integer`。**旧报告的结论需要更正**：`RV_StrictSchema` 现在**没有** `exactKeys`，本次全树检索 `exactKeys` 只有 2 处命中 —— server 侧 `RV_UtilityWater_Objects.lua:13` 的本地定义与 L60 的唯一调用，shared 侧已经没有任何 exactKeys。也就是说「严格 integer + exactKeys 被 shared RegionSlots 与 shared Water Catalog 复用」这句话现在只剩 integer 成立。
- **exactKeys 不值得重新提取回 shared（条件性推断 + 源码事实）**：唯一消费者是 `RV_UtilityWater_Objects.lua:60`，只查一个固定键集 `{x,y,z,objectIndex,connected}`；该实现（L13-L23）**不检查 metatable**，而 shared 侧历史上那份会拒绝 metatable，全树 `getmetatable` 只剩 `RV_RegionSlots.lua:68` 一处（用于 dense array 判定）。把它搬回 shared 会重新引出「metatable 策略由谁决定」的分歧，净收益接近零。
- **`finiteNumber`/`finiteInteger` 与 `StrictSchema.integer` 不能合并（源码事实）**：`C.finiteNumber` 接受数字字符串与受保护算术可转换的 Java 包装（L18-L25），`StrictSchema.integer` 只接受原生 number（L5）；返回约定也不同（number|nil vs number|nil，但输入域不同）。消费者分层也清楚：宽松版 53/33 处命中**全在 client**（网络 payload），严格版 4 处在 shared/server（schema 字段）。合并会改变输入合同，属于语义破坏而非重构。
- **server 侧仍有 5 份「转换 + 有限 + 整数」重复实现，其中 2 份可与 `C.finiteInteger` 逐行等价替换（条件性推断，证据充分）**：
  - `RV_BoundaryServer_Geometry.lua:23-L27` 的 `integer` 与 L29-L36 的 `finiteNumber` 是 `C.finiteInteger` / `C.finiteNumber` 的逐行等价实现（相同的 `number`→`pcall(value+0)` 转换 + 有限性判定 + floor 判定）；前者文件内约 28 处调用、后者 1 处。
  - `RV_UtilityStore.lua:36-L40` 的 `waterInteger`（返回 number|nil，含 NaN/±Inf 拒绝与 floor 判定）与 `StrictSchema.integer`（L4-L11）规则完全一致，文件内 3 处调用（L43）。
  - 语义**不同、不能直接替换**的三份：`RV_Server_WorldObjects.lua:10-L18` 与 `RV_Server_TemplateProtectionRepair.lua:20-L28` 是 `ServerUtil.toNumber` + 有限性 + floor，等价于 `C.finiteInteger`（可作为同一批候选，但依赖 server 公共层）；`RV_RailroaderServer_Train.lua:7-L26` 与 `RV_UtilityStore.lua:9-L11/L13-L15` 的 `integer`/`number` **不拒绝 NaN/±Inf**（`math.floor(math.huge) == math.huge` 为真，会原样返回 ±Inf），与 `C.finiteInteger` 输入合同不同，替换会收紧行为。
  - shared 侧同族但返回布尔的有 `RV_RoomTemplate.lua:17-L21`（文件内 3 处调用）与 `RV_TemplateGeometry.lua:31-L38`（文件内约 14 处调用）；它们与 `StrictSchema.integer` 的判定规则逐项相同，只是返回 boolean 而非 value|nil。
  - **净收益与成本**：把上述等价实现改为引用 `C.finiteInteger` / `StrictSchema.integer` 能消除规则漂移，成本是需要逐文件确认返回约定（value|nil / boolean）与调用点数量；建议按「逐行等价的三处先换」（BoundaryServer_Geometry.integer、BoundaryServer_Geometry.finiteNumber、UtilityStore.waterInteger）推进，语义更松的 `Train.number/integer`、`UtilityStore.integer/number` 保持不动。
- **身份判定重复只应在 server 内部提取，绝不能放进 shared/Common（源码事实 + 约束）**：`RV_ServerWorld.isTaggedForGeneration`（[RV_ServerWorld.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua:213)，导出 L471）判定 `tag.owner == OWNER / generation / rvId`；`RV_UtilityPower.generatedGenerator`（[RV_UtilityPower.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Power/RV_UtilityPower.lua:57)）自己读 `World.objectModData` 后判定 `tag.owner == C.MOD_ID` 且 `tag.role == "generator"` 再比对 `rvId/generation`。两者字段集不完全相同（后者多一个 role 条件，`isTaggedForGeneration` 的签名里没有 role 参数），语义差异明确；另有 `RV_UtilityCatalog.tagForObject`（shared，L20-L33）判定同样的 owner/role/rvId/generation 但额外要求 slotIndex。**关键约束**：`RV_ServerWorld`/`RV_ServerUtil` 属 server 路径，shared 模块不得 require 它们 —— shared 在客户端也会加载，反向 require 会把 server chunk 拉进客户端。因此「共享身份判定」的可行落点是 server 层内部（例如让 `RV_ServerWorld` 增加按 role 过滤的判定并删除 `generatedGenerator` 的字段副本），而不是 `shared/Common`；当前 `generatedGenerator` 已经复用了导出的 `World.objectModData`（L58），只剩字段判定是副本，净收益中等。
- **隐藏 sprite 注册没有重复实现，且跨端复用是真实的（源码事实）**：全树 `AddSprite`/`IsoSpriteManager`/`getNamedMap` 只出现在 `RV_UtilitySprite.lua` 与常量注释里。跨端使用方式为：客户端 `RV_UtilityClient.lua:11-L15` 调 `install()`（模块加载时一次 + OnGameBoot 重试），服务端 `RV_Server_WorldObjects.lua:70-L71` 与 L455-L459 直接调 `ensureHiddenSprites()` 并要求它成功，否则抛带上下文的错误。判断：现状合理，`install` 是「客户端需要的自动安装」，`ensureHiddenSprites` 是「服务端需要的显式幂等保证」，两者共享同一实现，不需要再加公共层。
- **本目录内的 sprite Java 调用 helper 不建议提取**：`invoke`/`callSucceeded`（L13/L22）与 server 侧 `RV_Common.invoke`/`callSucceeded`（[RV_Common.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_Common.lua:7)）看起来同名，但前者只处理 sprite manager 上的 `get/set/has/CreateKeySet` 且最多返回两个值，后者返回 4 个值并被 107 处调用；把 sprite 注册细节提升为全局公共依赖，收益低于把「Java 对象调用约定」扩散成两份语义的成本。

### 是否进一步拆分

- **RV_Constants.lua（136 行、3 函数）不拆**。它是全包唯一的协议/布局/schema 配置源，被 25 个本目录之外的文件 `require`（本次检索 `RailroaderRV/Common/RV_Constants` 共 26 处命中，减去本目录 `RV_UtilityConstants.lua:7` 后为 25：shared 5 个 —— `RV_UtilitySprite.lua:8`、`RV_UtilityCatalog.lua:6`、`RV_Layout.lua:7`、`RV_TemplateGeometry.lua:6`、`RV_RegionSlots.lua:6`；client 8 个 —— `RV_BoundaryClient.lua:6`、`RV_ContextMenu.lua:8`、`RV_RailroaderContextMenu.lua:7`、`RV_UtilityClient.lua:8`、`RV_UtilityContextMenu.lua:7`、`RV_ProtectedDemolition.lua:3`、`RV_WardrobeVisuals.lua:5`、`RV_BoundaryWallVisuals.lua:5`；server 12 个 —— `RV_UtilityWater_Objects.lua:3`、`RV_UtilityWater_Ledger.lua:3`、`RV_UtilityWater_Commands.lua:7`、`RV_UtilityPower.lua:3`、`RV_UtilityPowerDevices.lua:3`、`RV_UtilityStore.lua:3`、`RV_UtilityServer.lua:8`、`RV_Server.lua:49`、`RV_ServerSchema.lua:5`、`RV_RailroaderServer.lua:28`、`RV_BoundaryServer.lua:25`、`RV_WallReloadProtection.lua:13`）并另有 ctx 注入路径（`RV_Server.lua:134-L135`、`RV_RailroaderServer.lua:104-L105`）。按职责切成「协议常量 / 几何常量 / sprite 常量」会让同一份坐标合同散到多个加载单元，收益为负。
- **RV_StrictSchema.lua（13 行、1 函数）不拆，但名实需要收口**。文件头 L1 写的是 "Strict checks for current shared schema contracts"（复数），实际只剩一个 `integer`；当前它很薄，拆没有意义。是否把 shared 内两份布尔型严格判定（`RV_RoomTemplate.lua:17`、`RV_TemplateGeometry.lua:31`）收进来属于「提取」决策而非「拆分」决策，且需要先统一返回约定（boolean vs value|nil），本报告只登记证据。
- **RV_UtilityConstants.lua（61 行、0 函数）不拆**。作为数据合同它必须只有一个 owner。真正值得处理的是加载边界而非文件边界：L15 的 `require RV_UtilityItems` 使「读常量」附带 recipe 注册副作用（`RV_UtilityItems.lua:41`/L45），而本文件自称 data-only（L1-L5）。可选方向是把 recipe 注册移到显式 bootstrap，净收益是「纯读取不再产生注册副作用」；风险是现有加载顺序（客户端 `RV_RailroaderContextMenu.lua:8` 只 require 本文件）可能依赖这个隐式注册，需先确认再动。
- **RV_UtilitySprite.lua（112 行、6 函数）不拆**。注册、配置、校验是同一个 sprite 生命周期的四个阶段，`ensureOne`（L45）与 `ensureBlueprint`（L27）共用同一套 `invoke`/`callSucceeded` 约定；拆开只会把 sprite manager 细节变成跨文件接口。
- **四个文件也不建议合并**。它们有清晰的加载与依赖分界：`RV_Constants` 无依赖并被其余两个 require；`RV_StrictSchema` 无依赖且被 shared 的 RegionSlots/Catalog 与 server 复用；`RV_UtilityConstants` 依赖 Constants 并带 Power 层副作用；`RV_UtilitySprite` 依赖 Constants 并触碰游戏全局 sprite manager。合并后 `RV_StrictSchema` 的「严格」语义会被常量表稀释，且任何 require 常量表的模块都会连带加载 sprite 注册代码。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **RV_Constants**：`return C`（L136）导出全部字段；同时发布全局 `RailroaderRV.Constants`（L9）。无函数以外的隐藏状态（只有 L11 的 `local C`）。`C.finiteNumber`（L13）与 `C.finiteInteger`（L33）是两个函数字段，其余全是数据字段。**SAVE_SCHEMA_VERSION（L54）是全包唯一的存档 schema 版本号**，只有 `RV_RailroaderServer.lua:53`（写入 `map.schemaVersion`）与 L58-L61（比较并只报警）在消费；`RV_RailroaderServer_EntryExit.lua:492` 在构造候选 map 时原样拷贝 `map.schemaVersion`。
- **RV_StrictSchema**：`return M`（L13）导出 1 个函数字段 `integer`；不发布全局、无隐藏状态、不注册事件。3 个消费方：`RV_RegionSlots.lua:7`、`RV_UtilityCatalog.lua:7`（都取 `.integer` 绑成局部名）、server `RV_UtilityWater_Objects.lua:9/L25`。
- **RV_UtilityConstants**：`return U`（L61）导出数据合同字段，并额外转出 `U.POWER`（L14，指向 `RV_UtilityPowerConfig` 的表引用）；发布全局 `RailroaderRV.UtilityConstants`（L9），当前无外部读者使用该全局路径。消费方 9 个：client `RV_UtilityDashboard.lua:10`、`RV_UtilityClient.lua:17`、`RV_RailroaderContextMenu.lua:8`；server `RV_UtilityWater_Plumbing.lua:4`、`RV_UtilityWater_Objects.lua:4`、`RV_UtilityWater_Commands.lua:8`、`RV_UtilityStore.lua:4`、`RV_UtilityServer.lua:9`、`RV_UtilityPower.lua:4`。无「零调用者」的死字段（`REASON_INVALID_RV_DATA` 只有 3 处消费者但确实在用）。
- **RV_UtilitySprite**：`return M`（L112）导出 2 个函数 `ensureHiddenSprites`（L88）与 `install`（L102）。隐藏状态为 `local eventRegistered`（L11）与 4 个私有 helper。消费方 3 处：client `RV_UtilityClient.lua:11`（`install`）、server `RV_Server_WorldObjects.lua:70`、L455（都是 `ensureHiddenSprites`）。没有任何外部模块访问私有 helper 或 `eventRegistered`。

### 直接读写其他模块的数据

1. **本模块读其他模块的数据**：`RV_UtilitySprite.lua:98-L99` 读 `C.UTILITY_HIDDEN_SPRITE_KEY` / `C.UTILITY_HIDDEN_SPRITE_ID`，`RV_UtilityConstants.lua:14` 取 `RV_UtilityPowerConfig` 表；两者都是对公开合同的消费。判断：**保留直接访问**。sprite 名与 ID 就是跨端共享数据合同（server 必须用同一个名字调 `setSpriteFromName`：`RV_Server_WorldObjects.lua:85`、L457），加 getter 只会让 `RV_UtilitySprite` 变成唯一的间接层而没有新增保证。
2. **本模块读引擎全局而非 RV 模块**：`RV_UtilitySprite.lua:89`（`IsoSpriteManager`）、L105（`Events`）、L28（`IsoFlagType`）都是 `rawget(_G, ...)` 探测式读取，属对 B42 API 的可用性判定，不涉及其他 RV 模块内部状态。
3. **其他模块直接读取本模块的常量/表数据（文件:行）** —— 这是本目录最主要的对外形态，逐条列出：
   - `Constants.MOD_ID`：client `RV_WardrobeVisuals.lua:53`、`RV_UtilityClient.lua:88`/L207、`RV_RailroaderContextMenu.lua:163`/L173/L612、`RV_ProtectedDemolition.lua:80`/L203、`RV_ContextMenu_Relocation.lua:30`/L35/L154/L182/L414、`RV_BoundaryClient.lua:104`；shared `RV_UtilityCatalog.lua:26`；server `RV_WallReloadProtection.lua:149`、`RV_RailroaderServer_WallReload.lua:18`、`RV_Server_TemplateProtectionRepair.lua:142`、`RV_UtilityServer.lua:44`、`RV_UtilityPower.lua:60`、`RV_RailroaderServer_EntryExit.lua:143`/L171、`RV_BoundaryServer_Sweep.lua:100`、`RV_Server_Commands.lua:324`、`RV_Server_WorldObjects.lua:647`、`RV_BoundaryServer.lua:33`、`RV_BoundaryServer_Geometry.lua:119`、`RV_RailroaderServer_Sentinel.lua:51`/L141、`RV_UtilityWater_Objects.lua:143`。
   - `Constants.INVALID_RV_DATA`：81 处命中，覆盖 `RV_Server_GenerationAck.lua:34`/L136-L137、`RV_Server_WorldObjects.lua:704`-L748、`RV_UtilityStore.lua:65`-L125、`RV_Server_RecordValidation.lua:19`-L201、`RV_WallReloadProtection.lua:70`-L475、`RV_RailroaderServer_Mapping.lua:209`-L288、`RV_UtilityServer.lua:33`/L158、`RV_RailroaderContextMenu.lua:616`、`RV_UtilityWater_Commands.lua:26`-L38 等。
   - `Constants.RV_MAP_KEY`：`RV_RailroaderServer_Mapping.lua:30`、`RV_RailroaderServer.lua:46`。`SAVE_SCHEMA_VERSION`：`RV_RailroaderServer.lua:53`/L58/L60/L61。
   - `Constants.WORLD_MIN_Z`/`WORLD_MAX_Z`：`RV_ServerSchema.lua:9`-L10/L66-L69/L82、`RV_Server_PlayerValidation.lua:15`-L16/L28、`RV_RailroaderServer.lua:104`-L105、`RV_Server.lua:134`-L135、`RV_RailroaderServer_Mapping.lua:8`-L9/L119、`RV_WallReloadProtection.lua:75`。
   - `Constants.SPRITES`：`RV_Server_GenerationBuild.lua:104`-L105、`RV_Server_WorldObjects.lua:457`/L775；`UTILITY_HIDDEN_SPRITE_KEY`：`RV_Server_WorldObjects.lua:69`/L80/L459；`GENERATOR_OFFSET`：`RV_Server_WorldObjects.lua:664`-L666/L727-L729、`RV_UtilityPower.lua:91`-L93、`RV_Layout.lua:321`；`GENERATOR_INITIAL_FUEL`：`RV_Server_WorldObjects.lua:453`/L491。
   - 区域几何：`RV_BoundaryServer_Geometry.lua:89`-L97、`RV_RailroaderServer_Mapping.lua:43`-L63/L112-L118、`RV_TemplateGeometry.lua:14`、`RV_RailroaderContextMenu.lua:65`-L69、`RV_UtilityContextMenu.lua:80`-L85、`RV_UtilityWater_Objects.lua:90`-L91。
   - 其余单点：`RV_MOUNT_REACH` → `RV_RailroaderContextMenu.lua:212`、`RV_RailroaderServer_EntryExit.lua:249`；`RV_STOPPED_SPEED` → `RV_RailroaderServer_Train.lua:226`；`RV_MAX_PASSENGERS` → L402；`ROOF_REFRESH_REMOTE_OFFSET_X/Y/Z` → `RV_WallReloadProtection.lua:72`-L74；`BOUNDARY_TRANSITION_TIMEOUT_TICKS` → `RV_BoundaryServer_Geometry.lua:295`；`TEMPLATE_PROTECTION_REPAIR_SAMPLE_INTERVAL_TICKS` → `RV_TemplateRecovery.lua:30`。
   - `Constants.COMMAND_*`：`RV_ContextMenu_Relocation.lua:36`、`RV_Server_Commands.lua:325`、`RV_RailroaderContextMenu.lua:163`/L173/L612、`RV_RailroaderServer_Sentinel.lua:52`/L61/L206-L207/L142、`RV_BoundaryServer_Geometry.lua:119`、`RV_BoundaryServer_Sweep.lua:101`、`RV_BoundaryClient.lua:105`、`RV_UtilityClient.lua:89`/L208/L216/L226、`RV_UtilityServer.lua:127`/L134。
   - `Constants.finiteInteger`/`finiteNumber`：53 + 33 处，全部在 client（见函数表），并经 `RV_ContextMenu_RoomOwnership.lua:290`-L291 以 `ctx.finiteNumber`/`ctx.finiteInteger` 二次转发。
   - 判断：**这些直接访问都不应改为接口**。常量表本身就是公开数据合同，字段名与字面量是双端协议的一部分；一字段一 getter 只会增加一层转发，并让「同一字面量在两个文件里各写一遍」这种真正的漂移问题更难发现。`RailroaderRV.Constants` 全局路径（L9）有 11 个外部读者（`RV_BoundaryClient.lua:12`、`RV_ContextMenu.lua:23`、`RV_RailroaderContextMenu.lua:14`、`RV_UtilityClient.lua:22`、`RV_UtilityContextMenu.lua:13`、`RV_BoundaryServer.lua:32`、`RV_RailroaderServer.lua:36`、`RV_Layout.lua:15`、`RV_TemplateGeometry.lua:8`、`RV_UtilityCatalog.lua:11`、`RV_RegionSlots.lua:13`），本次核查这 11 处**全部**先 `require` 了本文件，因此该全局只是第二访问路径，不是隐式依赖（唯一的例外是 `RV_Server.lua:35`-L41 的 `rawget(_G,"RailroaderRV")` 调试器重载兜底，注释 L46-L48 已说明）。
   - `RV_RegionSlots` 与 `RV_UtilityCatalog` 读 `RV_Constants` 的方式是「require 后把字段拷进模块级局部」（`RV_RegionSlots.lua:15`-L18、L22-L24；`RV_TemplateGeometry.lua:14`），因此运行期改动 `RV_Constants` 字段不会生效；这是刻意的初始化快照，不是隐藏状态。

### 接口边界问题

- **`RV_Server.lua:7`-L17 把共享常量重新写成字面量**：`OWNER`/`COMMAND_MODULE = "RailroaderRVTest"`、`"FinalRelocate"`、`"FinalRelocateAck"`、`"RefreshRoomOwnership"`、`"EnterRV"`、`"ExitRV"`、`"RVTeleport"` 与 `RV_Constants.lua:39`-L52 重复，而同一个文件 L49 又 require 了 `RV_Constants`（`Constants` 用于 `WORLD_MIN_Z`/`WORLD_MAX_Z` 转发，L134-L135）。这是当前**真实存在**的常量漂移点：客户端 `RV_ContextMenu.lua:28`-L37 从 `C` 读同一批值（并带 `or "FinalRelocate"` 兜底字面量），服务端另有本地副本。属「应改为引用同一合同」的接口问题，不属于本目录内部缺陷。
- **`RV_StrictSchema` 名实不符**：`L1` 的注释与其文件名都承诺「strict checks（复数）」，实际只有 `integer` 一个原语，且 `exactKeys` 已不在其中。当前没有功能缺口，但下一个想找「严格 exactKeys」的读者会被名字误导。
- **`RV_UtilityConstants` 的 data-only 声明与加载副作用不一致**：L1-L5 声明本模块不解析世界对象、不读坐标、不改 FluidContainer，这一点属实；但它同时通过 L14-L15 两个 require 触发 `PowerConfig` 表发布与 `Recipe.OnCreate` 注册（`RV_UtilityItems.lua:3`-L4/L41/L45），而 `Recipe` 是全局单例。这属于加载顺序合同，需要时应在文件头显式写出，而不是只写 data-only。
- **`RV_UtilitySprite` 的两个入口语义不同，容易被误用**：`ensureHiddenSprites`（L88）幂等但不注册事件；`install`（L102）幂等且注册一次 `OnGameBoot`。客户端必须走 `install`（`RV_UtilityClient.lua:12`），服务端走 `ensureHiddenSprites`（`RV_Server_WorldObjects.lua:71`/L456）—— 服务端不注册事件是有意的（服务端没有 OnGameBoot 重试需求，且它要求当场成功否则抛错）。当前两个调用方都选对了入口，但接口本身没有文档说明，新增调用方容易漏掉「客户端需要 install」这一点。
- **`C.finiteInteger` 与 `RV_StrictSchema.integer` 在同一棵树里并存，且名字都像「整数校验」**：前者宽松（接受字符串/Java 包装）、后者严格（只接受原生 number）。本次检索确认两者目前没有交叉误用（shared/server 的 schema 读取只走 StrictSchema，客户端 payload 只走 Constants），但这是**依赖约定而非机制**；两处注释（`RV_Constants.lua:21`-L22、`RV_StrictSchema.lua:1`）是目前唯一的区分说明。
- **`RV_UtilityConstants` 的 `REASONS`/`OP_*` 是客户端与服务端共同字面量**：服务端 `RV_UtilityServer.lua:36`-L38 把内部原因字符串（`"outside-rv"`/`"unmapped-rv"`/`"permission-denied"`）映射到 `U.REASONS.*`，客户端 `RV_UtilityClient.lua:253` 依赖 `U.REASON_INVALID_RV_DATA`。映射表本身只存在于 `RV_UtilityServer.lua:32`-L40，属可接受的单点适配，不是隐藏状态。

## 函数清单、覆盖和验证记录

- **扫描文件**：`RV_Constants.lua`（136 行）、`RV_StrictSchema.lua`（13 行）、`RV_UtilityConstants.lua`（61 行）、`RV_UtilitySprite.lua`（112 行）；目录扫描（`Get-ChildItem -Recurse -File -Filter *.lua`）确认本目录只有这 4 个代码文件、无子目录，合计 **322 行**。
- **扫描函数**：对 4 个文件做 `function` 关键字扫描并逐行核对定义（排除 `type(x) ~= "function"` 类比较行）：RV_Constants 3 个定义（含 1 个匿名 `pcall` 闭包，0 处类型判定行）；RV_StrictSchema 1 个定义；RV_UtilityConstants 0 个定义；RV_UtilitySprite 6 个定义 + 2 处类型判定行（L16、L105，均排除）。计数为 3/1/0/6，合计 **10**（5 个表方法 + 4 个 `local function` + 1 个匿名函数表达式）。匿名条目只有 `RV_Constants.lua:23`（`C.finiteNumber` 中匿名函数）；`RV_UtilitySprite.lua:106` 注册的是具名函数引用，不计入匿名。
- **逐行交叉核对**：逐文件编号读取源码全文；条目行号是定义语句（`function` / `local function`）的起始行，已与机械扫描逐条对齐。导出位置：`RV_Constants.lua:136`（`return C`）、`RV_StrictSchema.lua:13`（`return M`）、`RV_UtilityConstants.lua:61`（`return U`）、`RV_UtilitySprite.lua:112`（`return M`）。
- **跨模块调用扫描**：在 `media/lua` 全树（65 个 `.lua` 文件）按「require 别名 + `RailroaderRV.*` 全局表 + ctx 注入」三种绑定方式搜索导出符号，得到：`finiteInteger` 53 处 / `finiteNumber` 33 处（全部 client）；`SAVE_SCHEMA_VERSION` 4 处；`MOD_ID` 24 处；`RV_MAP_KEY` 2 处；`INVALID_RV_DATA` 81 处；`StrictSchema` 6 处（3 个 require + 3 个绑定）；`UtilityConstants` 9 个消费文件；`RV_UtilitySprite` 3 个 require 点。逐字段枚举每个 Constants 字段的外部读取点见「直接读写其他模块的数据」。
- **旧报告失效项（本次核对）**：旧 `shared-Common.md` 描述的 `RV_Bitmap.lua`（542 行、39 函数）、`RV_UtilityConstants.lua` 81 行、`RV_Constants.lua` 179 行、全模组 72 个 Lua 文件、`RV_DevSaveSchemaGate.lua` 与 `RV_ServerSchema` 的若干调用点在本轮源码中**均已不存在**：`RV_Bitmap.lua` 与 `RV_DevSaveSchemaGate.lua` 不在文件树内，本目录实际只有 4 个文件，全树实际 65 个 Lua 文件。旧报告「StrictSchema 提供严格 integer 与 exactKeys」的说法对当前源码**只有 integer 部分成立**。
- **未覆盖项 / 条件性推断**：未穷举所有 API 的调用行（大文件只核查命中的符号行）；「合并 server 侧 5 份数值判定的净收益」「把 recipe 注册移出 UtilityConstants 的收益」「把 shared 两份布尔型严格判定收进 StrictSchema」都属条件性推断，未做改造实验；「`generatedGenerator` 是否可以由 `isTaggedForGeneration` 扩展 role 参数替代」需要 server 侧报告与实现方确认，本报告只给字段集差异证据。未运行游戏或 runtime 测试，本文不宣称运行时行为已验证。
- **修改范围**：仅重写本分析文档；未修改任何 Lua 源码、配置或测试文件，未运行任何测试脚本。
