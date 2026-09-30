# shared/RailroaderRV/RoomTemplate 模块分析

## 假设、范围、成功条件与验证方式

- **假设**：只分析模组当前目录 `contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/` 中实际存在的 4 个 Lua 文件（RV_Template.lua 452 行、RV_TemplateGeometry.lua 247 行、RV_Layout.lua 347 行、RV_RoomTemplate.lua 153 行，合计 1199 行，shell 计数）。该目录是共享层：捕获模板数据、模板编译与查询、布局计划、模板坐标几何；它不注册事件、不写存档、不触碰世界。行号全部来自本次逐行读取，不使用旧报告行号。
- **范围**：4 个文件中的全部具名函数、`local function`、表方法（`function M.foo()` / `M.foo = function`）以及作为参数/回调的匿名函数表达式；消费者扫描覆盖整个 `contents/mods/RailroaderRVTest/42/media/lua/`（shared/server/client）。唯一写入目标是本报告；未修改任何 .lua、配置或测试文件。
- **成功条件**：4 个文件全覆盖；每个函数有精确起始行、参数含义、返回/副作用、本模块语义与加粗结论式的必要性判断；给出 A（逐文件函数数与行数）与 B（函数索引）机械核对结果，且报告表格与 shell 统计完全一致；对「已验证布局/模板」数据的 owner、服务端直读内部字段的定性、几何转换重复实现给出带 `文件:行` 证据的判断，并区分源码事实与条件性推断；说明旧报告与当前源码的全部主要偏差。
- **验证方式**：(1) 逐文件编号全文读取（read）；(2) `function` 关键字扫描并用规则排除 `type(x) == "function"` 类比较行（本目录此类行为 0，规则仍执行）；(3) 全树 grep 检索本模块导出符号与内部字段（`RoomTemplate.*`、`Layout.*`、`TemplateGeometry.*`、`metadata/misc/celldef`、`shellEdges/wallCoordinates/managed/templateObjects`）的实际读取点；(4) 对模板数据做**只读静态推导**（PowerShell 正则解析 RV_Template.lua 的 412 条对象行后重放 RV_Layout 的候选筛选规则），用于核对壳边 ledger 条数、候选重数、结构坐标枚举量——这是静态推导，不是运行时验证。本轮**未运行游戏、服务器或任何测试脚本**。

## 目录职责与清单

该目录按「数据 → 编译 → 计划 → 几何」四段划分：RV_Template.lua 是纯捕获数据；RV_RoomTemplate.lua 把它编译成按坐标/楼层稀疏索引的模板并发布只读查询；RV_Layout.lua 由服务端可信槽位锚点生成纯 Lua 布局计划（含壳边 ledger）；RV_TemplateGeometry.lua 提供 100×100 区域的世界/模板坐标变换与对象定位。依赖方向单向：RV_Template → RV_RoomTemplate → RV_Layout / RV_TemplateGeometry，后两者只额外依赖 shared/Common（RV_Constants、RV_TemplateGeometry 亦然）。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_Template.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_Template.lua) | 0 | 452 行纯捕获数据：`templateVersion = 11`（L17）、`sourceTarget`（L18）、`objectCount = 412`（L19）、24 个 cab buildCells（L7-L14、L22）、1 个 walk AABB（L23-L26）、1 个 roof refresh 点（L30-L32）与 412 条有序对象（L33-L451，其中 z=0 共 324 条、z=1 共 88 条）。无行为函数 |
| [RV_RoomTemplate.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_RoomTemplate.lua) | 10 | 模板编译与查询：常量（L6-L15）、buildCellSet 与对象编译（L27-L89）、roof refresh 点一致性校验（L94-L115）、6 个导出查询（supportsZ/get/cellAt/hasLayer/roofRefreshPoints/orderedObjects） |
| [RV_Layout.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_Layout.lua) | 13 | 纯布局计划：roofZOffset/walk 几何的加载期快照（L14-L26）、结构坐标枚举（L27-L51）、墙 host 与壳边 ledger 构造（L53-L196）、`Layout.make` 组装 clear/managed/room/wall/roof/shellEdges/模板对象世界副本/generator（L201-L345） |
| [RV_TemplateGeometry.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_TemplateGeometry.lua) | 21 | 100×100 区域坐标契约与模板几何查询：数值门（L31-L62）、区块/锚点变换（L64-L96）、可行走·可建造·managed 区域判定（L98-L187）、边键编码（L189-L209）、模板对象定位（L211-L245） |
| **总计** | **44** | 1199 行；23 个表方法 + 20 个局部/嵌套函数 + 1 个匿名回调；RV_Template.lua 为 0 函数数据文件 |

计数口径：`M.foo = localFunction` 这类导出别名赋值在本目录不存在，无重复计数；RV_Layout.lua L3 的注释行含 "function" 字样，已排除；本目录没有 `type(x) == "function"` 比较行（该计数陷阱不适用，但按规则核查过）。

## 逐文件、逐函数分析

### RV_Template.lua

模块在 [RV_Template.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_Template.lua) 中只构造两个局部表并 `return` 一个根数据表（L16-L452）：`buildCells`（L7-L14）与根表字段（L17-L451）。全文件没有具名函数、局部函数、表方法或匿名函数，因此**没有逐函数表**——它的全部功能就是数据本身：412 条捕获对象的顺序即 `templateIndex`（RV_RoomTemplate.lua L57-L80 直接按 `Source.objects[index]` 顺序编译），`state` 子表（如 L35）是后续所有对象的共享引用源，`buildCells`/`walkAabbs`/`roofRefreshPoints` 是共享权限与刷新契约。z=1 的 88 条对象（L351-L438）是屋顶层，其中 87 条为 `IsoThumpable/Thumpable/location_shop_fossoil_01_39`、1 条为同 sprite 的 `IsoObject`（静态推导）；这 88 条全部落在屋顶矩形内，是 `Layout.eachStructureCoordinate` 屋顶枚举的输入。

### RV_RoomTemplate.lua

模块在 [RV_RoomTemplate.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_RoomTemplate.lua)，只 require 数据文件 RV_Template（L2）；加载期做一次「编译 + 一次 fail-closed 校验 + 6 个导出」的收尾工作，不注册事件、不写 ModData。`protected` 标记（L78）由本地 `buildCellSet` 推导，取代了旧版的独立保护账本文件。编译结果 `template`（L34-L54）与 `objectsByIndex`（L56-L89）是模块级单例，`get()` 返回同一引用。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| integer（L17） | value 任意值；返回布尔：`type=="number"`、非 NaN、非 ±`math.huge` 且 `math.floor(value)==value` 才真。无副作用。本模块语义：坐标/楼层/索引的有限整数门。 | **实现必需**：cellCoordinates（L118）与 supportsZ（L124）都以它为前提；删除会让同一条规则在两处各写一遍（全树另有 9 处同类手写，见复用章节）。注意它不做字符串或 Java 包装转换，与 RV_Constants.finiteNumber（RV_Constants.lua L13-L31）语义不同。 |
| cellKey（L23） | x,y,z 数值；返回 `tostring(x)..":"..tostring(y)..":"..tostring(z)`。无副作用。本模块语义：编译期查表键（buildCellSet 写入 L30、protected 判定 L60-L64 查询）。 | **实现必需**：`protected` 必须按模板坐标 O(1) 命中，删除后要在两处内联同一拼接规则。键规则在下游还有 4 份副本（见复用章节），导出优于复制。 |
| validateRoofRefreshPoints（L94） | points（RV_Template.roofRefreshPoints 数组）、orderedObjects（objectsByIndex 索引表）；逐点要求 `templateIndex` 指向真实条目且条目的 x/y/z 与点完全相等，否则 `error(...)`；成功原样返回 points。本模块语义：把「刷新点」与其命中的捕获条目绑定，属加载期数据一致性门（L114 立即执行）。 | **必须**：refresh 点的世界格由 point 偏移推导（RV_RoofRefresh.lua L33-L36、L99、L102），点与条目错位会让刷新落到错误格子，且下游没有第二处一致性校验；这是本模块仅存的加载期 fail-closed 检查。 |
| cellCoordinates（L117） | x,y 数值；返回布尔：均为整数且落在 `[MIN_X,MAX_X_EXCLUSIVE)`×`[MIN_Y,MAX_Y_EXCLUSIVE)`（L119-L120）。无副作用。本模块语义：模板平面坐标边界门。 | **实现必需**：cellAt 的唯一入口检查；与 supportsZ（z 门）构成平面/楼层两层边界。 |
| RoomTemplate.supportsZ（L123） | z 任意值；返回布尔：整数且 `[-32,32)`。无副作用。本模块语义：对外发布的 z 合法性判定。 | **必须**：唯一外部消费者是 RV_TemplateGeometry.lua L119（contains 的 z 门），内部 hasLayer L140 也用它；删除会让 -32/32 这对常量在消费者里硬编码并可能与 MIN_Z/MAX_Z_EXCLUSIVE 分叉。 |
| RoomTemplate.get（L128） | templateId 字符串；等于 TEMPLATE_ID 时返回编译模板单例（可变引用），否则 nil。无副作用。本模块语义：编译模板的唯一取用口。 | **必须**：10 个外部文件共 12 处 `require` + `get(TEMPLATE_ID)`（RV_Layout L16、RV_TemplateGeometry L11、RV_WardrobeVisuals L7、RV_ProtectedDemolition L6、RV_BoundaryWallVisuals L7、RV_RoofRefresh L11、RV_BoundaryServer_Sweep L17、RV_UtilityPowerDevices L9、RV_BoundaryServer_Geometry L11、RV_Server_TemplateProtectionRepair L17、RV_BoundaryServer_Objects L15、RV_Server_Commands L20）。这是跨层唯一模板入口，不可由调用方自建模板。 |
| RoomTemplate.cellAt（L133） | value 模板表、x,y 模板坐标；坐标越界或该行/列不存在返回 nil，否则返回内部 cell 表引用（含 `layers`）。无副作用。本模块语义：稀疏 `celldef` 的行列查询基础。 | **必须**：唯一外部调用者是 RV_TemplateGeometry.lookupObjectsAtTemplate（L225），hasLayer（L141）也依赖它。注意它返回可变内部引用且不校验 value 是否为当前模板（见接口边界）。 |
| RoomTemplate.hasLayer（L139） | value、x,y,z；z 非法返回 false；否则要求 cell 存在且 `cell.layers[z] ~= nil`。无副作用。本模块语义：精确到单格单层的存在性查询。 | **必须**：RV_TemplateGeometry.contains（L120）与 isWalkable（L130）的判定末端；它把「世界点 → 模板相对格 → 是否有对象」串成可用谓词，删掉则这两个对外谓词无处落地。 |
| RoomTemplate.roofRefreshPoints（L145） | value（**未被使用**）；总是返回模块级 `roofRefreshPoints`（L114 校验过的同一数组引用）。无副作用。本模块语义：刷新点的唯一发布口。 | **必须**：RV_RoofRefresh.lua L12 是唯一消费者且 L115-L117 直接按索引遍历；但参数被忽略属接口缺陷（见接口边界）。 |
| RoomTemplate.orderedObjects（L149） | value（**未被使用**）；总是返回模块级 `objectsByIndex`（按 templateIndex 1..412 排列，元素是编译对象引用，非拷贝）。无副作用。本模块语义：稳定捕获顺序的唯一发布口。 | **必须**：8 处外部调用（RV_Layout L17、RV_TemplateGeometry L12、RV_WardrobeVisuals L8、RV_BoundaryWallVisuals L8、RV_RoofRefresh L13、RV_Server_TemplateProtectionRepair L18、RV_BoundaryServer_Objects L16、RV_Server_Commands L21）。服务端标签只存 `templateIndex`、属性按索引回查模板（RV_Server_WorldObjects.lua L261-L273），所以「索引→对象」必须是稳定单一序列。 |

### RV_Layout.lua

模块在 [RV_Layout.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_Layout.lua)，require RV_Constants 与同目录 RV_RoomTemplate/RV_TemplateGeometry（L7-L9）。加载期快照当前模板的 `templateObjects`、`walkAabbs[1]` 与 roofZOffset（L16-L26）；`Layout.make` 每次调用新建完整计划表，模块内不缓存计划、不触碰世界（L1-L5 注释）。消费者只有 2 + 3 个调用点：eachStructureCoordinate 由服务端 RV_Server_RoomOwnership.lua L81 与客户端 RV_ContextMenu_RoomOwnership.lua L65 使用；make 由 RV_Server_GenerationFlow.lua L374、RV_Server_RecordValidation.lua L47、RV_BoundaryServer_Geometry.lua L228 使用。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| Layout.eachStructureCoordinate（L27） | bounds（须含 wallMinX/MaxX/MinY/MaxY、roomMinX/MinY、roofMinX/MaxX/MinY/MaxY、z、roofZ）、callback(x,y,z)；无返回，输出全部通过对 callback 的调用产生。本模块语义：把「墙矩形 + 顶层模板对象（屋顶宿主格）」的结构坐标集合做成跨层共享枚举（L20-L22 注释：物理计划只描述主壳体）。 | **必须**：服务端清理失效房间归属与客户端本地复查共用同一规则；静态推导当前模板每次发出 168 个墙格（7×24）+ 88 个屋顶格 = 256 个坐标（无重复键）。 |
| point（L53） | x,y,z；返回新 `{x=,y=,z=}`。无副作用。本模块语义：Layout 三维点构造器。 | **保留理由**：只有 offsetPoint（L71）一个调用者，可直接内联；保留是为了与 rectangle 一起统一本模块的点/矩形表形状。属可读性收益，不是功能必需。 |
| rectangle（L57） | minX,maxX,minY,maxY,z,minZ,maxZ,halfOpen；返回新 bounds 表，`halfOpen` 仅在严格 `true` 时为 true。无副作用。本模块语义：clear/interior/wall/roof 四个矩形的统一字段契约定义点。 | **实现必需**：4 次调用（L233、L243、L250、L257）共享字段名，是 bounds 形状的唯一出处；内联会把 8 字段结构复制 4 遍。 |
| offsetPoint（L70） | anchor、offset（均为 x/y/z 表）；返回逐分量相加的新点。无副作用。本模块语义：`generator = anchor + Constants.GENERATOR_OFFSET`（L321）。 | **必须**：generator 世界坐标是生成阶段必需数据（RV_Server_GenerationBuild.lua L122、L143-L148 建 IsoGenerator 并校验收回）。 |
| appendWall（L74） | result 数组、x,y,z、north 布尔、sprite、role、corner；把墙条目（含 x/y/z/north/sprite/role/corner/edgeNorth/edgeWest/axis/edgeKey）追加进 result，edgeKey 经 TemplateGeometry.edgeKey（L87）编码；无返回。本模块语义：单条墙 host 记录的规范构造。 | **必须**：wallCoordinates 与 shellEdges 的全部条目都经它构造。但 `edgeNorth`/`edgeWest`（L84-L85）全树无读取者，`axis`（L86）随后在 L284 被按 side 重算覆盖——属可从出生即删除的冗余字段。 |
| isShellSprite（L91） | entry（含 sprite）；返回布尔：sprite 前缀属 `walls_`、`fixtures_railings_01_`、`fixtures_windows_`、`location_restaurant_pileocrepe_` 之一。无副作用。本模块语义：壳体（墙/栏杆/窗/该门）候选过滤器。 | **必须**：它是「哪些捕获对象可以拥有边界边」的唯一规则；去掉后 412 条对象（含 88 条 z=1 屋顶对象、家具、灯开关）都会成为候选，ledger 语义崩塌。 |
| shellPriority（L98） | entry；返回 1..6 的确定性优先级（Wooden Wall=1、栏杆=2、窗=3、Door Frame=4、Wooden Door=5、其他=6）。无副作用。本模块语义：同一边多个捕获对象时决定边界归属者的稳定规则。 | **必须**：静态推导当前 59 条边中 50 条有 ≥2 个候选（合计 110 个候选成员，占 412 条对象的 110 条）；没有它会退化为捕获顺序/pairs 顺序依赖。当前数据下所有被选中的首候选都落在优先级 1，排序仍决定 `templateIndices` 的顺序，而服务端要求 `parts[1] == edge.templateIndex`（RV_Server_TemplateProtectionRepair.lua L64-L71）。 |
| wallCoordinatesForAnchor（L113） | cx,cy,cz（可信锚点平移）、interior 矩形；返回墙条目数组（每条含 templateIndex/templateIndices/sprite/north/role/corner）。只读 templateObjects。本模块语义：从捕获模板推导边界 host 账本。 | **必须**：59 条墙记录的唯一来源（静态推导：59 个候选位全部至少一个候选）。它同时承载北/西/东/南与南角的特殊 host 规则（L151-L163：东墙由 x=interiorMaxX+1 承载、南墙由 y=interiorMaxY+1 承载）。 |
| wallCoordinatesForAnchor 中嵌套函数 addCapturedEdge（L120） | side、x,y（对象格）、north；在 templateObjects 中筛 `x-cx/y-cy/z-cz` 精确相等、class 为 IsoThumpable/IsoWindow、north 相同且 isShellSprite 的候选，排序后取首条 appendWall，并写 templateIndex 与 templateIndices；无候选时直接返回（该位不产生条目）。无返回值。本模块语义：单条边的 host 解析过程。 | **必须**：闭包捕获 cx/cy/cz/interior/result，是「一条边恰好一个归属条目、N 个成员索引」规则的实现点；当前模板 59 个位点全部命中（9 个位点单候选、50 个位点多候选）。 |
| wallCoordinatesForAnchor 中匿名函数（L131） | left,right（`{index=,object=}` 候选）；比较器：先 shellPriority 升序，同优先级按 index 升序。无副作用。本模块语义：候选排序的确定性保证。 | **必须**：table.sort 的默认比较对相等元素不保证顺序；去掉后 ledger 的 templateIndex/templateIndices[1] 会随数据顺序漂移，而这两者正是服务端校验的键。 |
| annotateWallEdges（L172） | wallCoordinates、interior；就地写入每条 entry 的 edgeSide/edgeCellX/edgeCellY/edgeHostX/edgeHostY/edgeKey；无显式返回。本模块语义：把「墙对象所在格」与「它拥有的逻辑边界」分离并给出规范 edge key（L167-L171 注释：东墙宿主为 `W(x+1,y,z)`、南墙为 `N(x,y+1,z)`）。 | **必须**：edgeKey 是 tag、ledger、拆除归属的共同键（RV_BoundaryServer_Objects.lua L90-L91、L188-L195 按 `tag.edgeKey` 反查 ledger）；edgeSide 也是服务端判轴（edge.side，L209-L212）的依据。 |
| Layout.make（L201） | cx,cy,cz（服务端槽位锚点）；直接 `math.floor` 后组装 managed（L225-L232）、clear（L233-L242）、interior（L243-L249）、wall（L250-L256）、roof（L257-L263）、wallCoordinates + 注释（L264-L265）、shellEdges ledger（L278-L309）、412 条模板对象世界副本（L327-L343）与 generator（L321）；返回完整 plan 表，不修改世界、不读写 ModData。本模块语义：布局计划器主接口。 | **必须**：3 个服务端调用点（GenerationFlow L374 生成前规划、RecordValidation L47 清单重建、BoundaryServer_Geometry L228 boundary 派生）。说明：统计字段 wallObjectCount/wallCoordinateCount（L323-L324，两值恒等）与 wallEdgeCounts/wallCornerCount（L325-L326）除被 RV_ServerSchema L33-L37 抄进 bounds 外全树无读取者；ledger 的 rvId/generation 在此留 nil（L287-L288），身份由 RV_BoundaryServer_Geometry.encodeShellEdges（L155）在服务端填入，保证 Layout 保持纯几何。 |
| Layout.make 中嵌套函数 includeZ（L207） | minZ,maxZ；闭包更新 managedMinZ/managedMaxZ（取并集）；无返回。本模块语义：把 objects z、walkAabbs minZ/maxZExclusive、buildCells z（缺省取 `metadata.anchor.z`）折成 managed 的 z 半开区间。 | **实现必需**：managed z 区间是服务端 footprint 与 `anchorFromManaged` 反算 z 的基础。但同一「三类来源 + buildCells 默认 z」规则在 RV_TemplateGeometry.lua L17-L29（只取 min）、RV_RoomTemplate.lua L30-L31（默认 z 用字面量 0）、RV_Server_Commands.lua L141-L143 各写一遍，应提取（见复用章节）。 |

### RV_TemplateGeometry.lua

模块在 [RV_TemplateGeometry.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_TemplateGeometry.lua)，require RV_Constants 与 RV_RoomTemplate（L6-L8）。加载期取模板单例、`orderedObjects` 与模板 z 下限偏移（L11-L29）；区域大小取 `Constants.RV_REGION_SIZE`，锚点偏移固定 `math.floor(REGION_SIZE/2)`（L14-L15）。它是本目录被最广泛依赖的文件（10 个外部文件 require），全部函数都是纯查询，无副作用。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| finiteNumber（L31） | value；返回布尔：`type=="number"`、非 NaN、非 ±∞。无副作用。本模块语义：世界坐标允许小数，先做有限性门。 | **实现必需**：integer（L37）、validPoint、blockOriginForWorld（L65）、templateAnchorForWorld（L73）、inManagedRegion（L165）都依赖它；规则与 RV_Constants.finiteNumber 等价但返回语义不同（见复用章节）。 |
| integer（L36） | value；返回布尔：finiteNumber 且 `math.floor==value`。无副作用。本模块语义：锚点、模板索引、边键坐标的整数门。 | **实现必需**：validAnchor（L47-L49）、edgeKey（L191）、edgeForSide（L198）、lookupObjectByIndex（L213）、lookupObjectsAtTemplate（L222）共 10 处调用；与 RV_RoomTemplate.integer（L17）规则相同，是模块内第二份实现。 |
| validPoint（L40） | point；返回布尔：table 且 x/y/z 均为有限数值。无副作用。本模块语义：世界/模板点的形状门。 | **实现必需**：worldToTemplate（L87）与 inManagedRegion（L165）的入参门；它把「非表/缺分量」折叠为 false 而不是抛错，符合查询语义。 |
| validAnchor（L46） | anchor；返回布尔：x/y/z 整数且 x/y 恰为其所在 100 格区块左下角 + 50（L51-L54）。无副作用。本模块语义：模板锚点必须是区块中心，防止把邻区坐标当作本 RV 的相对坐标。 | **必须**：worldToTemplate（L87）依赖它；它是「世界点 → 模板相对坐标」唯一的前置条件。注意它是**通用 100 网格中心**判定（不校验 z=TELEPORT_Z，也不限制在 100 槽位矩阵内），与 RegionSlots.indexForAnchor 的槽位判定语义不同（RV_ServerSchema.lua L62 用后者做槽位身份校验）。 |
| sameRegion（L57） | world、anchor；返回布尔：二者 XY 的 `floor(/100)` 区块坐标相同。无副作用。本模块语义：拒绝跨区转换。 | **必须**：世界的 100 格区块边界与 RV 区域边界重合，跨区点若按本 RV 锚点解释会得到越界相对坐标；这是 worldToTemplate 的第二道门。 |
| G.blockOriginForWorld（L64） | x,y 有限数值；返回 `{x=,y=}` 区块左下原点，否则 nil。无副作用。本模块语义：世界 XY → 100 区块原点。 | **实现必需**：templateAnchorForWorld 的唯一依赖（L74）。加载/消费面核查显示它没有外部调用者，导出属多余。 |
| G.templateAnchorForWorld（L72） | x,y,z（z 只需有限）；返回区块中心锚点 `{x=origin.x+50,y=origin.y+50,z=z}`，x/y 非法返回 nil。无副作用。本模块语义：从任意世界位置反推该 RV 的模板锚点。 | **必须**：4 处跨层调用——RV_Server_Commands.lua L93（采集命令的几何门）、RV_ProtectedDemolition.lua L168（客户端拆除识别）、RV_WardrobeVisuals.lua L82、RV_BoundaryWallVisuals.lua L78（客户端表现层）。它把「锚点约定」这个事实同时供给了服务端与客户端。 |
| G.worldToTemplate（L86） | world（x/y/z 有限）、anchor（区块中心）；任一不合法或不同区返回 nil，否则返回 `world - anchor` 的相对点（可为小数）。无副作用。本模块语义：世界 → 模板相对空间的唯一变换。 | **必须**：4 处跨层调用（RV_ProtectedDemolition.lua L171、RV_Server_TemplateProtectionRepair.lua L85、RV_WardrobeVisuals.lua L83、RV_BoundaryWallVisuals.lua L79）；它是「对象是否属于模板」判定的入口。 |
| inBoxes（L98） | boxes（AABB 数组）、offset 或 nil；返回布尔：offset 落在某 box 的 `[minX,maxX)`×`[minY,maxY)`×`[minZ,maxZExclusive)`。无副作用。本模块语义：walkAabbs 的纯几何包含判定。 | **实现必需**：isWalkable 的唯一几何部分；与 `RoomTemplate.hasLayer` 组合成「AABB 内且模板在该格有对象」的可行走定义。 |
| G.contains（L111） | world、anchor、可选 template；非法坐标/跨区/越 z 返回 false，否则返回 `hasLayer(template,floor 相对坐标)`。无副作用。本模块语义：世界点是否属于模板占用格。 | **当前不是功能必需**：全树 grep 未发现任何调用点（仅 L111 定义），能力已被 isWalkable（更严格）与 hasLayer 覆盖。保留可作为「含任意对象格」的语义补集，但当前属零调用者导出。 |
| G.isWalkable（L123） | world、anchor、可选 template；返回布尔：相对格在该模板 walkAabbs 内**且**该格有对象层。无副作用。本模块语义：权威可行走判定。 | **必须**：RV_UtilityPowerDevices.lua L247（电表/设备落点枚举）与 RV_Server_Commands.lua L95（采集命令允许范围）使用；isWalkableInManagedRegion（L186）也复用它。 |
| G.isBuildable（L133） | world、anchor、可选 template；返回 true,index 或 false：相对格命中某个 buildCell（`cell.z==nil` 时取 `metadata.anchor.z`）。无副作用。本模块语义：cab 建造格判定。 | **必须**：RV_ProtectedDemolition.lua L229（客户端判断能否建造/拆除）与 RV_Server_TemplateProtectionRepair.lua L400（服务端修复时排除 cab 格）；它把 buildCells 的默认 z 规则封装在查询内。 |
| G.isBuildCellSideHost（L148） | world、anchor、可选 template；返回 true,index 或 false：相对格等于某 buildCell 的北邻或东邻（`x+1,y` 或 `x,y+1`）。无副作用。本模块语义：cab 格侧边宿主判定（这些格子由边界保护而不是建造权限覆盖）。 | **必须**：RV_ProtectedDemolition.lua L187 是唯一调用者，用于区分「cab 内可建」与「紧邻格由墙规则处理」；规则与 buildCells 数据强耦合，不能由调用方自己遍历。 |
| G.inManagedRegion（L164） | world（x/y/z 有限）、managed（originX/originY/width/height/minZ/maxZ，半开）；返回布尔，world 非法返回 false。无副作用。本模块语义：世界点是否落在 managed footprint 内。 | **必须**：RV_BoundaryServer_Objects.lua L143、L384、L426、L471 用它做拆除/搭建归属的前置范围判定；它是「plan 的 managed 字段」与「世界坐标」之间的唯一桥。 |
| G.anchorFromManaged（L174） | managed、可选 template；返回 `{x=originX-minX,y=originY-minY,z=minZ-managedMinZOffset}`（不校验，纯粹按公式构造）。无副作用。本模块语义：managed footprint → 模板锚点的逆变换。 | **必须**：7 处调用点（RV_BoundaryServer_Geometry.lua L193/L253、RV_BoundaryServer_Objects.lua L85、RV_Server_WorldObjects.lua L659/L723、RV_Server_TemplateProtectionRepair.lua L397）。服务端持久化记录只存 slotIndex/generation，几何在读取时用本函数重算（RV_Server_RecordValidation.lua L30-L34、L171），所以「managed → 锚点」必须是单一实现。注意它自身不做合法性判断，验证由调用者用 validAnchor 间接完成（RV_BoundaryServer_Geometry.lua L193）。 |
| G.isWalkableInManagedRegion（L183） | world、managed、可选 template；先 anchorFromManaged 再 isWalkable。返回布尔。无副作用。本模块语义：只给 managed 时的便捷可行走判定。 | **必须**：RV_BoundaryServer_Sweep.lua L82、L89、L145 三个调用点都只持有 boundary.managed；去掉会让扫描模块自己拼 anchor（重复 L174-L181 公式）。 |
| G.edgeKey（L189） | axis（"N"/"W"，其他归 nil）、x,y,z 整数；返回 `axis..":"..x..":"..y..":"..z`，非法输入 nil。无副作用。本模块语义：边界边的规范字符串键。 | **必须**：RV_Layout L87（墙条目）与 RV_BoundaryServer_Objects.lua L229/L242/L243（按 tag.edgeKey 反查）共用；它是 tag、ledger、拆除归属三方共享的唯一编码，全树未发现第二份拼接实现。 |
| G.edgeForSide（L197） | side（north/south/east/west 或 N/S/E/W）、x,y,z 整数；side 键归一：north→`N(x,y)`、west→`W(x,y)`、east→`W(x+1,y)`、south→`N(x,y+1)`；非法 nil。无副作用。本模块语义：逻辑边 → 规范 host 边的映射（东/南的宿主偏移规则）。 | **必须**：RV_Layout.annotateWallEdges（L189）与服务端 RV_BoundaryServer_Objects.lua L231/L244/L245 使用；东/南宿主偏移是易错规则，集中在此处是正确取舍。 |
| G.lookupObjectByIndex（L211） | templateIndex（整数 ≥1）；返回 `object, templateIndex`，越界或非整数返回 nil。**第二参数 template 被接受但未被使用**（L216 直接读模块级 templateObjects）。本模块语义：稳定索引 → 捕获对象。 | **必须**：RV_ProtectedDemolition.lua L159 用它把服务端/对象侧索引还原成模板条目以判定保护；这是「tag 只存索引」设计在客户端的唯一回查口。但同时存在误导性参数（见接口边界）。 |
| G.lookupObjectsAtTemplate（L220） | x,y,z 整数、可选 template；返回 `{index,object}` 数组（可为空），输入非法返回 nil。经 RoomTemplate.cellAt（L225）读层。无副作用。本模块语义：模板空间同格多层对象的枚举。 | **实现必需**：当前唯一调用者是同文件 lookupObjectsAtWorld（L244）；它是「同格可叠多对象，单值查找会丢失身份」这一事实的实现点，独立导出便于内层复用。 |
| G.lookupObjectsAtWorld（L238） | world、anchor、可选 template；先 worldToTemplate 并要求相对坐标三轴均为整数，再委托 lookupObjectsAtTemplate。返回数组或 nil。无副作用。本模块语义：世界坐标 → 该格全部模板对象。 | **必须**：RV_ProtectedDemolition.lua L174 用它验证「世界对象与本格模板索引集合一致」；它把三轴取整校验与外层变换串起来，调用方无法用一次减法替代（还要同区/边界门）。 |

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **边键与边→宿主映射已经是单一实现，正面例子**：`TemplateGeometry.edgeKey`（L189）与 `edgeForSide`（L197）由 RV_Layout（L87、L189）与服务端（RV_BoundaryServer_Objects.lua L229-L245）共用，全树没有第二份边键拼接。唯一缺口是反向查询：服务端需要「轴 → side」时自己维护了一张表（RV_BoundaryServer_Objects.lua L207-L214 `shellAxisMatches`）。若要补，应在 TemplateGeometry 加 `sideForAxis(axis)`，而不是让服务端继续维护轴枚举。
- **有限数值/整数判定可在 shared/Common 收口，但需先统一返回语义**：本目录有两份实现——RV_TemplateGeometry.finiteNumber（L31）/integer（L36）与 RV_RoomTemplate.integer（L17），规则都是「number + 非 NaN/∞ + floor 相等」。shared 侧已有 `RV_StrictSchema.integer`（RV_StrictSchema.lua L4-L11，返回 value 或 nil，已被 RV_RegionSlots.lua L21、RV_UtilityCatalog.lua L13、RV_UtilityWater_Objects.lua L25 采用）与 `RV_Constants.finiteNumber/finiteInteger`（L13-L37，返回 number 或 nil 并可转换字符串/Java 包装）。全树另有 7 个文件手写同类判定：RV_BoundaryServer_Geometry.lua L13/L23/L29、RV_RailroaderServer_Train.lua L7/L22、RV_UtilityStore.lua L9/L13、RV_Server_WorldObjects.lua L10、RV_Server_TemplateProtectionRepair.lua L20、RV_BoundaryClient.lua L16/L26、RV_UtilityDashboard.lua L21。净收益是消除规则漂移；成本是本目录 44 个函数中大量 `if integer(x) then` 要改成 `if StrictSchema.integer(x) ~= nil then`（布尔语义 → 值语义），可读性下降。**判断：规则应统一到 shared/Common，但只在 StrictSchema 增加布尔变体（如 `isInteger`/`isFiniteNumber`）之后本目录才值得改；在此之前保留局部实现更简单。**
- **模板 z 范围推导有 4 份副本，是本目录最值得提取的一项**：RV_Layout.make 的 includeZ 循环（L206-L223，objects + walkAabbs + buildCells，取 min 与 max）与 RV_TemplateGeometry 的 managedMinZOffset（L17-L29，同一三类来源只取 min）是模块内两份；`buildCells 缺 z 时取默认楼层` 这一规则又在 RV_RoomTemplate.lua L30-L31（**默认值写成字面量 0**）与 RV_Server_Commands.lua L141-L143（默认值写 `Template.metadata.anchor.z`）各复制一次。当前 `metadata.anchor.z == 0`（RV_RoomTemplate.lua L39），所以四处结果一致；一旦锚点 z 非 0，RV_RoomTemplate 的 `buildCellSet` 会与其余三处悄悄分叉，而它决定 `protected` 标记（L78）——属**条件性风险**，不是当前缺陷。建议在 RoomTemplate 增加 `zExtent(template)`（返回 minZ/maxZ，内部统一默认 z 规则），Layout/Geometry/Commands 改为消费它：净收益是删掉 4 份副本并把分叉不可能化，成本是 1 个新导出 + 3 处改造。
- **「100×100 区域/锚点」约定被 4 处独立推导，是真正的重复几何实现**：① RV_RegionSlots.anchorForSlot/indexForAnchor（RV_RegionSlots.lua L58-L65、L115-L126，基于 TELEPORT + 槽位行列矩阵）；② RV_TemplateGeometry.blockOriginForWorld/templateAnchorForWorld/validAnchor（L46-L81，基于世界 100 网格中心）；③ RV_Layout.make 的 managed 原点（L226-L232，基于 `metadata.minX/minY`）；④ 服务端 RV_RailroaderServer_Mapping.rvRegion/regionForAnchor/validRegion（RV_RailroaderServer_Mapping.lua L42-L65、L110-L120）与 RV_BoundaryServer_Geometry.playerPosition 的 `inRVRegion`（L89-L97，基于 TELEPORT + RV_REGION_MIN_OFFSET + size×COLUMNS/ROWS）。**静态推导**：只要 `TELEPORT_X=20050`、`TELEPORT_Y=2050`（RV_Constants.lua L59-L60）、`RV_REGION_MIN_OFFSET_X/Y=-50`（L77-L78）、`RV_REGION_SIZE=100`（L66）、`RoomTemplate.MIN_X/MIN_Y=-50`（RV_RoomTemplate.lua L10-L11）同时成立，四种推导完全一致（槽位锚点 = 世界 100 网格中心 = managed 原点 + 50）；这个恒等式没有任何加载期断言保护。另有语义差异：`validAnchor` 接受**任意** 100 网格中心与任意整数 z，槽位身份判定实际由 RV_ServerSchema.lua L62 的 `RegionSlots.indexForAnchor` 完成，两套判定互不知情。**建议**：把「区域↔锚点」的事实留在 RegionSlots（它已持有 COLUMNS/ROWS/COUNT），TemplateGeometry 改为消费它，或在加载期断言 `RV_REGION_SIZE/2 == ANCHOR_OFFSET` 且 `TELEPORT_X % RV_REGION_SIZE == ANCHOR_OFFSET`（Y 同理）。收益是消除一类静默漂移——客户端表现层同样用 templateAnchorForWorld（RV_WardrobeVisuals.lua L82、RV_BoundaryWallVisuals.lua L78），服务端与客户端一旦对锚点约定理解不同，表现为「找不到模板对象」而不是报错。
- **去重键拼接有 5 份副本**：RV_RoomTemplate.cellKey（L23-L25，`x:y:z`）、RV_Layout.eachStructureCoordinate 的 seen 键（L42-L43，`x:y:roofZ`）、RV_Server_GenerationBuild.lua L53（`x:y:z`）、RV_Server_TemplateProtectionRepair.lua L38-L39（`x:y`）、RV_RoofRefresh.lua L22-L24（逗号分隔）。用途不同（边身份 vs 访问集合去重）、生命周期都只在一次扫描内，且分隔符不一致不影响正确性。**判断：暂不提取**；但 RoomTemplate.cellKey 已是现成实现，若将来需要跨模块共享模板坐标去重，导出它优于再复制。
- **eachStructureCoordinate 已成功吸收服务端/客户端重复枚举**：墙 + 屋顶扫描现在只有一份（RV_Server_RoomOwnership.lua L81、RV_ContextMenu_RoomOwnership.lua L65）。仍未共用的是「坐标是否落在墙/屋顶 bounds 内」这一谓词：服务端 `coordinatesInRoomOwnershipBounds`（RV_Server_RoomOwnership.lua L90-L97）与客户端 `coordinatesInBounds`（RV_ContextMenu_RoomOwnership.lua L85-L94）逐字重复。若要收口，最自然的位置是 Layout（它定义了 wall/room/roof 三个矩形），增加 `Layout.containsStructureCoordinate(bounds,x,y,z)`，而不是在两侧继续维护同一谓词。

### 是否进一步拆分

- **RV_RoomTemplate.lua（153 行 / 10 函数）不需要拆，且旧报告的拆分理由已消失**。当前文件只有三段：加载期编译（L27-L89）、一次点/条目一致性校验（L94-L115）、6 个导出查询（L123-L151）。旧报告面对的 819 行版本同时含 schema 深校验、bitmap/segment 编译、保护账本核对与查询族，那才需要评估 compile/validate/query 三拆；现在拆只会新增内部 require 契约，并且编译产物与查询共享同一单例，拆开反而要处理跨文件单例所有权。
- **RV_Layout.lua（347 行 / 13 函数）当前不建议拆**，但边界清楚，可分三块：加载期模板快照（L14-L26）、墙/壳边账本构造（L53-L196）、plan 组装（L201-L345）。账本块（isShellSprite/shellPriority/appendWall/wallCoordinatesForAnchor/annotateWallEdges）只依赖 templateObjects、walkGeometry 与 TemplateGeometry.edgeKey/edgeForSide，是可独立的一块；触发拆分的条件是出现第二种壳体策略或第二个模板形态。现在拆的代价是把 `appendWall`/`annotateWallEdges` 变成跨文件契约，而它们目前只服务一个调用者（Layout.make）。
- **RV_TemplateGeometry.lua（247 行 / 21 函数）不需要拆**，三组职责（数值门 L31-L62、区域/锚点变换 L64-L96、模板实体查询 L98-L245）共享同一个隐式单例（L11-L12 的 `Template`/`templateObjects`）。真正的拆分触发条件是**第二个模板**：查询组有函数接受 `template` 参数却在实现里读模块级单例（lookupObjectByIndex L211-L218；contains/isWalkable/isBuildable/isBuildCellSideHost/anchorFromManaged 的 `template = template or Template` 只是默认值，但内部一律经单例的 `cellAt`/walkAabbs）。届时必须先让「模板参数」名副其实，再谈按「区域变换」与「模板查询」拆文件。
- **RV_Template.lua（452 行 / 0 函数）保持纯数据**。不要为文件行数或「方便访问」增加 accessor 层：412 行对象数据与 templateIndex 的严格顺序、state 表引用关系就是它的全部价值，任何派生索引都应由 RoomTemplate 发布（如现有 orderedObjects/cellAt）。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **RV_RoomTemplate**：导出常量 TEMPLATE_ID/CURRENT_TEMPLATE_VERSION/WIDTH/HEIGHT/MIN_X/MIN_Y/MAX_X_EXCLUSIVE/MAX_Y_EXCLUSIVE/MIN_Z/MAX_Z_EXCLUSIVE（L6-L15）与 6 个函数（L123、L128、L133、L139、L145、L149）。实际消费统计：`get` 12 处（含同目录 2 处）、`orderedObjects` 8 处、`roofRefreshPoints` 1 处（RV_RoofRefresh.lua L12）、`hasLayer` 2 处与 `supportsZ` 1 处（均在 RV_TemplateGeometry 内）、`cellAt` 1 处（RV_TemplateGeometry.lua L225）。`CURRENT_TEMPLATE_VERSION`（L7）只被写入 `metadata.templateVersion`（L38），全树无消费者；`metadata.templateVersion` 本身也无读取者。
- **RV_Layout**：导出 `eachStructureCoordinate`（L27）与 `make`（L201）。plan 的字段契约（L311-L326）为：anchor、clear、managed、shellEdges、templateObjects、room、wall、roof、wallCoordinates、generator，外加 wallObjectCount/wallCoordinateCount/wallEdgeCounts/wallCornerCount。消费点：eachStructureCoordinate 2 处（服务端 RV_Server_RoomOwnership.lua L81、客户端 RV_ContextMenu_RoomOwnership.lua L65），make 3 处（RV_Server_GenerationFlow.lua L374、RV_Server_RecordValidation.lua L47、RV_BoundaryServer_Geometry.lua L228）。
- **RV_TemplateGeometry**：导出 15 个函数（L64、L72、L86、L111、L123、L133、L148、L164、L174、L183、L189、L197、L211、L220、L238）与 2 个数据字段 REGION_SIZE/ANCHOR_OFFSET（L14-L15）。**零外部调用者的导出**：`contains`（L111，全树无调用）、`blockOriginForWorld`（L64，仅被同文件 L74 使用）、`lookupObjectsAtTemplate`（L220，仅被同文件 L244 使用）、`REGION_SIZE`/`ANCHOR_OFFSET`（仅同文件内部使用，且与 RV_RegionSlots.REGION_SIZE 是同一常量的第二份拷贝）。调用最多的导出是 `anchorFromManaged`（7 处）与 `templateAnchorForWorld`/`worldToTemplate`（各 4 处）。
- **RV_Template**：没有函数导出，只作为 `require` 的数据源被 RV_RoomTemplate 读取（L2）；外部模块不允许也不需要通过它取数据（全树只有 RV_RoomTemplate.lua L2 一处 require 它）。

**「已验证布局/模板」数据的所有权判断（源码事实）**：编译模板的唯一 owner 是 RV_RoomTemplate —— 唯一构造点（L34-L89）、唯一加载期校验点（L94-L115）、唯一发布口（L128/L133/L139/L145/L149），全树没有第二份模板副本。布局计划的唯一 owner 是 `Layout.make`；计划每次调用新建、Layout 内不缓存，服务端只在派生 boundary 上做按槽位的记忆化（RV_BoundaryServer_Geometry.lua L210-L233），而 mapping 记录与 boundary 都刻意**不持久化几何**、改为读时用模板重算（RV_Server_RecordValidation.lua L30-L34、L66-L71、L171；RV_BoundaryServer_Geometry.lua L205-L209）。

### 直接读写其他模块的数据

**(a) 本模块读写其他模块的位置**

1. **shared 常量**：RV_Layout require RV_Constants（L7）并读取 `C.GENERATOR_OFFSET`（L321）；RV_TemplateGeometry 读取 `Constants.RV_REGION_SIZE`（L14）。两者都是共享层常量，不是隐藏状态。
2. **本模块读取「自己的」编译模板**：`RoomTemplate.get` + 直接字段访问——`Template.misc.walkAabbs`（RV_Layout L18、L215-L216；RV_TemplateGeometry L21-L23、L129）、`Template.misc.buildCells`（RV_Layout L219-L221；RV_TemplateGeometry L25-L28、L139、L154）、`Template.metadata.minX/minY/width/height`（RV_Layout L226-L229）、`Template.metadata.anchor.z`（RV_Layout L221；RV_TemplateGeometry L28、L140、L155）。这些是同一个 owner 内部的数据（RV_RoomTemplate 是同目录文件），并且查询族统一经 `RoomTemplate.cellAt`/`hasLayer`（RV_TemplateGeometry L120、L130、L225）而不是自己遍历 `celldef`。**本模块没有读写任何 server 模块的数据**，依赖方向是 shared→shared。
3. **别名关系（供他人判断可变性）**：`RV_Template.lua` 的 `state` 子表 → RV_RoomTemplate.lua L77 直接引用（不拷贝）→ `orderedObjects` 原样外发 → RV_Layout.make L340 复制进 `plan.templateObjects[].state`。因此一次对 `state` 的写入会同时改变静态模板数据、所有已存在的 plan 与服务端读回结果。全树未发现对 `entry.state`/`captured.state` 的写入（RV_Server_WorldObjects.lua L110-L209 只读取并写入世界对象；RV_WardrobeVisuals.lua L44 只读 `doRender`）。
4. `RoomTemplate.get` 返回单例、`orderedObjects` 每次返回同一个数组引用、`cellAt`/`lookupObjectsAt*` 返回内部对象引用——「只读」目前是调用约定，不是语言级保证。全树 grep 赋值模式（`templateObjects[...].x =`、`Template.metadata.* =`、`layout.* =`、`edge.* =` 等）只命中本模块自身的加载期赋值（RV_RoomTemplate.lua L6-L15、RV_Layout.lua L190-L194、L284），未发现外部写入者。

**(b) 其他模块直接读取本模块数据的调用点**

1. **编译模板内部字段**：`RV_Server_TemplateProtectionRepair.lua` L18（orderedObjects）、L41-L42（遍历条目的 x/y/z/class/sprite/direction/state/protected）、L73（`Template.metadata.objectCount` 校验 templateIndex 上界）；`RV_UtilityPowerDevices.lua` L241（`Template.misc.walkAabbs` 枚举室内格）；`RV_Server_Commands.lua` L21/L148-L150（orderedObjects）、L131-L132（`misc.walkAabbs` 四重循环采集）、L141-L143（`misc.buildCells` + `metadata.anchor.z` 默认 z）；`RV_WardrobeVisuals.lua` L8/L64（orderedObjects + `templateObjects[templateIndex]`）、L43-L44（`entry.protected`、`entry.state.doRender`）；`RV_BoundaryWallVisuals.lua` L8/L53；`RV_BoundaryServer_Objects.lua` L16/L92/L164（`templateObjects[tag.templateIndex]` 作为属性唯一来源）；`RV_ProtectedDemolition.lua` L235（`expected.protected`）。
2. **plan 内部字段**：`RV_ServerSchema.lua` L14-L41（把 clear/managed/room/wall/roof/wallEdgeCounts/shellEdges/wallCoordinates/统计字段/anchor 展平成 bounds）、L97-L99（遍历 wallCoordinates 条目 x/y/z）、L101-L103（roof 矩形逐格校验）、L44-L56（按 clear 半开区间 walkBounds）；`RV_BoundaryServer_Geometry.lua` L179-L202（`layout.managed` + `layout.shellEdges`，逐字段重编码成 boundary）、L228；`RV_Server_GenerationFlow.lua` L374-L375 及记录中的 `layout`/`bounds`（L403-L404）；`RV_Server_RecordValidation.lua` L47/L52；`RV_Server_GenerationBuild.lua` L70-L77（`layout.templateObjects` 与 `bounds.wallCoordinates` 逐格重建）、L112-L122（`layout.templateObjects`、`wallCoordinates[].templateIndices`、`layout.generator`）；`RV_RoofRefresh.lua` L34（`bounds.anchor.x/y/z` 与 refresh 点偏移）。
3. **壳边 ledger 字段经服务端复制后的读取面**：`RV_BoundaryServer_Geometry.encodeShellEdges`（L151-L174）把 ledger 的 15 个字段复制进 `boundary.shellEdges`（L155-L165 填入 rvId/generation），随后被 `RV_BoundaryServer_Objects.lua` L90-L111、L188-L195、L209-L212、L253-L257、L273-L277（读 edgeKey/rvId/generation/replacementAllowed/north/role/corner/side/objectX/objectY/objectZ/templateIndex/templateIndices）、`RV_Server_TemplateProtectionRepair.lua` L58-L79、L226（读 edgeKey/role/templateIndex/templateIndices）、`RV_Server_WorldObjects.lua` L270、L513（读 edgeKey/role）消费。**未被任何消费者读取的 ledger 字段**：`hostX`、`hostY`、`axis`、`sprite`（只在 Geometry L156-L164 被复制），以及 wallCoordinates 条目上的 `edgeNorth`/`edgeWest`（RV_Layout.lua L84-L85）与 plan 的 wallObjectCount/wallCoordinateCount/wallEdgeCounts/wallCornerCount（L323-L326，除 RV_ServerSchema L33-L37 抄写外无读取者，northEdges/westEdges 亦然）。
4. **跨网络的 bounds 子集**：`RV_Server_RoomOwnership.lua` L446-L457 从 bounds 复制 14 个字段（wall/room/roof 的 min/max + z/roofZ）进 payload → 客户端 `RV_ContextMenu_RoomOwnership.lua` L34-L59 重建 bounds → 调 `Layout.eachStructureCoordinate`（L65）。也就是说本模块的枚举函数在客户端被一个**结构化但不同的** bounds 表调用。

**判断：是允许的 value-object 合同，还是隐藏状态访问？**

- **编译模板的 metadata/misc/对象字段：允许的 value-object 合同。** 理由：(i) 它是该 owner 的显式公共数据出口，`get()` 返回唯一引用且无第二份副本；(ii) 加载期有一次把点与条目绑定的校验（L94-L115），模板不是未校验的裸数据；(iii) 全树无写入者，读取都是比较/枚举。但它并非「接口完备」：两条语义规则仍留在消费者里——`walkAabbs[1]` 被当作「室内主矩形」四重循环枚举（RV_UtilityPowerDevices.lua L241-L258、RV_Server_Commands.lua L131-L140），而 Layout 只在 L22 用一次并注明「queries use all walk regions」；`buildCells` 的默认 z 规则被复制 4 份（见复用章节）。这两处属**隐藏语义**而非隐藏状态：数据是公开的，规则没有 owner。建议的收口方向是给 RoomTemplate 增加「按模板枚举室内/建造格」的查询或 zExtent 之类的规则出口，而不是给字段加 getter。
- **plan（Layout.make 返回值）：允许的 value-object 合同。** 它是每次调用新建的派生值，不是缓存；RV_ServerSchema.boundsFor 的「展平」也是值变换。真正的问题是这套展平后的字段名成了**跨网络契约**，却分别定义在三处（服务端复制清单 RV_Server_RoomOwnership.lua L447-L451、客户端读取清单 RV_ContextMenu_RoomOwnership.lua L35-L39、Layout 自身读取 L28-L47）。这里加接口的收益明显高于成本，但正确的最小改动不是 getter，而是让 Layout 导出字段名清单（如 `Layout.STRUCTURE_BOUND_FIELDS`），供服务端复制与客户端读取共用一份定义。
- **shellEdges ledger：允许（它是值对象，不是内部缓存）**，但属「写多读少」的宽表：Layout 写 15 个字段、服务端再复制 15 个字段、实际被读取 11 个。要收紧应删字段（hostX/hostY/axis/sprite、edgeNorth/edgeWest），而不是加访问器。
- **不需要改成接口的项**：`anchorFromManaged`/`worldToTemplate`/`edgeKey` 等已经是函数出口，调用方读的是返回值；`RoomTemplate.get` 的单例语义是刻意的（模板是编译期常量，拷贝会破坏索引一致性）。

### 接口边界问题

1. **三个导出函数的 template/value 参数被忽略**：`RoomTemplate.roofRefreshPoints`（L145-L147）与 `orderedObjects`（L149-L151）完全不读参数；`TemplateGeometry.lookupObjectByIndex`（L211-L218）接受 `template` 却索引模块级 `templateObjects`。另外 `cellAt`/`hasLayer` 虽使用 value，却不校验它是否是当前模板（对比旧版曾有只接受单例的 `validTemplate` 门）。后果：调用方传错模板时**静默返回单例数据**，无法察觉。建议二选一：要么删参数、把「单例」写进函数名/注释，要么恢复单例校验（`if value ~= template then return nil end`），后者与 `CURRENT_TEMPLATE_VERSION = 11` 一起才构成真正的模板身份合同。属**源码事实 + 建议**。
2. **Layout.make 不做参数校验，且与几何谓词的接受域不一致**：L202-L204 直接 `math.floor`（nil 会抛错、NaN 会传播），并且接受任意整数锚点；而 TemplateGeometry.validAnchor/anchorFromManaged（L46-L55、L174-L181）只接受「100 网格中心」推导出的 managed。于是非网格锚点不会被 Layout 拒绝，而是在服务端派生阶段退化为 nil boundary（RV_BoundaryServer_Geometry.lua L193-L196 判「managed region bounds are invalid」）。当前 3 个调用点都传 `RegionSlots.indexToAnchor` 的结果（RV_Server_GenerationFlow.lua L354-L374、RV_Server_RecordValidation.lua L41-L47、RV_BoundaryServer_Geometry.lua L220-L228），属**条件性推断**下的潜在缺口。
3. **室内矩形假设 `walkAabbs[1]`**：eachStructureCoordinate 只用第一个 walk AABB（L22）作为室内矩形，而 contains/isWalkable 使用全部 AABB（L129-L130）；L20-L21 的注释已声明这是当前单壳体状态。若模板加入第二个 walk AABB，「房间归属清理」的覆盖范围会与「可行走」判定分叉，且两者都在客户端与服务端各自执行。
4. **客户端 bounds 契约没有单一定义，也没有模板版本核对**：客户端重建的 bounds（RV_ContextMenu_RoomOwnership.lua L34-L59）只做次序/嵌套校验（L49-L55），不校验这些值是否与本地模板一致；而 eachStructureCoordinate 的屋顶部分依赖**本地**模板数据（L16-L26 的 `walkGeometry`/`roofZOffset`/`templateObjects`）。bounds 包中不含 templateVersion，`CURRENT_TEMPLATE_VERSION`（RV_RoomTemplate.lua L7）也无人消费，因此服务端与客户端模板数据不一致时不会被发现——只会表现为屋顶格枚举差异。属**源码事实**；在「客户端与服务端同一 mod 文件」的前提下不构成现实缺陷。
5. **零读取者字段会误导读者**：plan 的 wallObjectCount/wallCoordinateCount（L323-L324，两值恒等）、wallEdgeCounts/wallCornerCount（L325-L326）、ledger 的 hostX/hostY/axis/sprite、墙条目的 edgeNorth/edgeWest（L84-L85）。其中 `edgeNorth`/`edgeWest` 从写入起就没有任何读取者，`axis` 在 L284 被按 side 重算覆盖。保留成本低，但建议下次修改时删除 dead 字段，或明确注释它们是诊断输出而不是合同。
6. **`RoomTemplate.hasLayer`/`cellAt` 返回内部可变引用**：`hasLayer` 只返回布尔（安全），`cellAt` 返回内部 cell 表（含 `layers` 数组），`orderedObjects` 返回内部数组，`Layout.make` 的模板对象副本仍共享 `state`（L340）。当前无写入者，但这些都是「读契约、写风险」的暴露面；若要加强，只需复制外发的 `state`（每次生成 412 次浅拷贝）或明确声明只读，不必引入 getter 层。

## 函数清单、覆盖和验证记录

- **扫描文件与行数（shell 计数）**：[RV_Layout.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_Layout.lua) 347 行、[RV_RoomTemplate.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_RoomTemplate.lua) 153 行、[RV_Template.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_Template.lua) 452 行、[RV_TemplateGeometry.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_TemplateGeometry.lua) 247 行；合计 1199 行，目录内无子目录、无其他代码文件。
- **机械核对 A（函数定义数与行数）**：RV_Layout.lua 13 / 347；RV_RoomTemplate.lua 10 / 153；RV_Template.lua 0 / 452；RV_TemplateGeometry.lua 21 / 247。合计 **44** 个函数定义。关键字扫描命中 45 行，其中 RV_Layout.lua L3 是含 "function" 字样的注释；本目录不存在 `type(x) == "function"` 比较行（规则已执行、结果为 0 排除）。与上表「函数定义数」列一致。
- **机械核对 B（函数索引，44 行；kind：named=表方法/普通具名，local=局部或嵌套具名，anon=匿名回调）**：

```text
RV_Layout.lua	27	Layout.eachStructureCoordinate	method
RV_Layout.lua	53	point	local
RV_Layout.lua	57	rectangle	local
RV_Layout.lua	70	offsetPoint	local
RV_Layout.lua	74	appendWall	local
RV_Layout.lua	91	isShellSprite	local
RV_Layout.lua	98	shellPriority	local
RV_Layout.lua	113	wallCoordinatesForAnchor	local
RV_Layout.lua	120	wallCoordinatesForAnchor/addCapturedEdge	local
RV_Layout.lua	131	wallCoordinatesForAnchor/(anonymous)	anon
RV_Layout.lua	172	annotateWallEdges	local
RV_Layout.lua	201	Layout.make	method
RV_Layout.lua	207	Layout.make/includeZ	local
RV_RoomTemplate.lua	17	integer	local
RV_RoomTemplate.lua	23	cellKey	local
RV_RoomTemplate.lua	94	validateRoofRefreshPoints	local
RV_RoomTemplate.lua	117	cellCoordinates	local
RV_RoomTemplate.lua	123	RoomTemplate.supportsZ	method
RV_RoomTemplate.lua	128	RoomTemplate.get	method
RV_RoomTemplate.lua	133	RoomTemplate.cellAt	method
RV_RoomTemplate.lua	139	RoomTemplate.hasLayer	method
RV_RoomTemplate.lua	145	RoomTemplate.roofRefreshPoints	method
RV_RoomTemplate.lua	149	RoomTemplate.orderedObjects	method
RV_TemplateGeometry.lua	31	finiteNumber	local
RV_TemplateGeometry.lua	36	integer	local
RV_TemplateGeometry.lua	40	validPoint	local
RV_TemplateGeometry.lua	46	validAnchor	local
RV_TemplateGeometry.lua	57	sameRegion	local
RV_TemplateGeometry.lua	64	G.blockOriginForWorld	method
RV_TemplateGeometry.lua	72	G.templateAnchorForWorld	method
RV_TemplateGeometry.lua	86	G.worldToTemplate	method
RV_TemplateGeometry.lua	98	inBoxes	local
RV_TemplateGeometry.lua	111	G.contains	method
RV_TemplateGeometry.lua	123	G.isWalkable	method
RV_TemplateGeometry.lua	133	G.isBuildable	method
RV_TemplateGeometry.lua	148	G.isBuildCellSideHost	method
RV_TemplateGeometry.lua	164	G.inManagedRegion	method
RV_TemplateGeometry.lua	174	G.anchorFromManaged	method
RV_TemplateGeometry.lua	183	G.isWalkableInManagedRegion	method
RV_TemplateGeometry.lua	189	G.edgeKey	method
RV_TemplateGeometry.lua	197	G.edgeForSide	method
RV_TemplateGeometry.lua	211	G.lookupObjectByIndex	method
RV_TemplateGeometry.lua	220	G.lookupObjectsAtTemplate	method
RV_TemplateGeometry.lua	238	G.lookupObjectsAtWorld	method
```

  分类小计：method 23（Layout 2 + RoomTemplate 6 + TemplateGeometry 15）、local 20（Layout 10 + RoomTemplate 4 + TemplateGeometry 6）、anon 1（RV_Layout.lua L131），合计 44。
- **静态推导（只读解析 RV_Template.lua 的 412 条对象行后重放 RV_Layout 规则；非运行时验证）**：对象 z 分布 z=0 共 324、z=1 共 88（roofZOffset=1）；壳边候选位 59 个（北 6 + 西 23 + 东 23 + 南 6 + 南角 1），全部至少命中一个候选，故 ledger 条目数 = 59（其中 50 个位点有 ≥2 个候选，候选成员合计 110，占 110 条对象；corner 条目 1 条），与「shellEdges 共 59 条」这一已知事实一致；`eachStructureCoordinate` 每次发出 168 个墙格（7×24）+ 88 个屋顶格 = 256 个坐标；managed z 半开区间推导为 [0,2)（objects max z+1=2、walkAabb maxZExclusive=1、buildCells 默认 z=0），与 `RV_MANAGED_MIN_Z_OFFSET=0`/`RV_MANAGED_MAX_Z_OFFSET=2`（RV_Constants.lua L79-L82）一致。
- **跨模块调用扫描**：在 media/lua 全树按模块别名检索 `RoomTemplate.*`、`Layout.*`、`TemplateGeometry.*` 以及内部字段（`metadata.`、`misc.`、`celldef`、`shellEdges`、`wallCoordinates`、`managed`、`templateObjects`、`anchor`），确认每个导出字段的调用点（见公开合同与 (b) 小节）；同时确认旧报告的以下 API 在当前源码中**已不存在**：`bitmap`、`segments`/`segmentMayHaveLayer`、`hasAnyLayer`、`roofTargets`、`templateToWorld`、`cabContainsWorld`、`validTemplate`、`validate`、`buildAabbs`、`protectionClass`、`ProtectionManifest`、`RV_ProtectionManifest.lua`（全树 0 命中）。
- **旧报告与当前源码不一致要点（本报告替换旧版的依据）**：① 文件数 5 → 4（RV_ProtectionManifest.lua 已删除，保护语义改为 RV_RoomTemplate.lua L60-L78 由 buildCellSet 推导的 `protected` 布尔）；② 函数总数 59 → 44；③ RV_RoomTemplate.lua 819 行/25 函数 → 153 行/10 函数，schema 深校验（exactKeys/denseList/assertSource/validate）与 bitmap/3 段 segment 全部移除，仅保留 roof refresh 点校验；④ RV_Layout.lua 415 行/12 函数 → 347 行/13 函数，bitmap/activeCells 与 `Bitmap.edgeKey` 消失，改为 TemplateGeometry.edgeKey/edgeForSide 与 shellEdges ledger（L278-L309）；⑤ RV_TemplateGeometry.lua 168 行/14 函数 → 247 行/21 函数，templateToWorld/validTemplate/cabContainsWorld 消失，新增 blockOriginForWorld/templateAnchorForWorld/sameRegion/inManagedRegion/anchorFromManaged/isWalkableInManagedRegion/edgeKey/edgeForSide/isBuildable/isBuildCellSideHost/lookupObjectsAtWorld；`lookupObjectByIndex`/`lookupObjectsAtTemplate`/`lookupObjectsAtWorld` 的 manifest 参数已删除；⑥ RV_Template.lua 442 行 → 452 行，根表字段从 `schemaVersion=11` 变为 `templateVersion=11`，对象 412 条不变但 z=1 屋顶对象 88 条、roofRefreshPoints 改为带 `templateIndex` 的自校验点；⑦ 旧报告的消费者行号多处失效（例如旧文引用 `RV_ServerSchema.lua:535`，当前该文件仅 157 行），本报告所有消费者引用均为本次读取/检索所得。
- **未覆盖项与条件性推断**：未穷举每个导出函数的全部调用行（大范围检索命中行均已列出，未逐文件通读其余模块）；「第二个模板出现时」的拆分触发条件、「模板版本漂移导致客户端屋顶枚举差异」、以及「非网格锚点导致 boundary 退化为 nil」属条件性推断，本报告已标明依据；静态推导（59 条 ledger、256 个结构坐标、z 区间 [0,2)）来自对源数据的规则重放，**不是运行时验证**；未检查参考模组、官方 Lua 与反编译代码。
- **修改范围**：仅重写本分析文档；未修改任何 Lua 源码、配置或测试文件，未运行游戏、服务器或任何测试脚本。
