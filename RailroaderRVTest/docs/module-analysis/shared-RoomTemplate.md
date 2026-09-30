# shared/RailroaderRV/RoomTemplate 模块分析

## 范围、假设与验收口径

- 范围仅为 `media/lua/shared/RailroaderRV/RoomTemplate/` 中实际枚举的 5 个 Lua 文件。这里的“模块”按文件夹职责理解，并在文件级逐项分析。
- 源码只读；调用位置只扫描同一模组的 `media/lua/`，用于判断本目录公开函数和数据的实际消费者。
- “必需”按当前模块目标和现有调用契约判断；标为“当前无外部调用”的查询 API 并非无效代码，但其是否保留取决于是否承诺该查询契约。
- 行号以本次读取到的文件为准。函数清单覆盖具名函数、局部函数、嵌套函数和匿名回调；纯数据文件明确记为 0。
- 成功标准：5 个文件全部覆盖；逐函数说明语义、参数、返回/副作用与必要性；说明跨文件复用、拆分和直接访问关系；给出静态核对结果。未运行游戏或服务器运行时测试。

## 目录与文件职责

| 文件 | 行数 | 函数数 | 职责 |
|---|---:|---:|---|
| RV_Template.lua | 442 | 0 | 原始、有序的 412 个对象捕获数据、24 个 build cell 与 schema 11 身份信息；无行为函数。 |
| RV_ProtectionManifest.lua | 553 | 8 | 与捕获对象逐项对应的静态保护等级账本，以及账本校验和查询接口。 |
| RV_RoomTemplate.lua | 819 | 25 | 验证原始捕获与保护账本、将原始数据编译成稀疏按坐标/楼层索引的模板、验证编译结果并提供查询接口。 |
| RV_Layout.lua | 415 | 12 | 以可信地图锚点生成清理范围、管理范围、活动 bitmap、模板对象副本及墙边所有权计划；不直接改世界。 |
| RV_TemplateGeometry.lua | 168 | 14 | 100×100 区域的世界/模板坐标转换、对象索引和 cab build-cell 查询。 |

总计 **59 个函数定义**。文件依赖主链为：RV_Template + RV_ProtectionManifest → RV_RoomTemplate → RV_Layout / RV_TemplateGeometry；RV_Layout 另依赖共享 Bitmap 与 Constants。ProtectionManifest 也被客户端表现、服务端生成及修复代码直接调用。

## 文件逐项分析

### 1. RV_Template.lua：纯捕获数据

该文件只创建 buildCells 和返回一个根数据表（见 1–442 行），没有具名函数、赋值函数、嵌套函数或匿名回调。根表声明 schemaVersion=11、sourceTarget、objectCount=412、buildCells 以及有序 objects。buildCells 是 cab 的 6×4=24 个格子；objects 保留同一捕获顺序，后续以 templateIndex 对齐保护账本。

这些数据就是捕获源模块的全部功能，不能以运行时推断取代：对象身份、重复占格顺序和保护账本都依赖这些精确记录。该文件没有函数可抽取，也不应把对象行拆成会丢失索引含义的派生配置。

### 2. RV_ProtectionManifest.lua：保护身份账本和接口

1–427 行是 412 条静态账本记录及类别数量常量：1=允许拆除、2=拆除后恢复、3=禁止拆除并恢复、4=特殊；当前数量为 49/0/363/0。其余函数将该账本与捕获模板的稳定索引和对象身份逐项核对，并给客户端/服务端提供只读查询。

| 函数与位置 | 模块语义、参数 | 返回值/副作用 | 对当前模块是否必需 |
|---|---|---|---|
| sameState(actual, expected)（428–437） | 比较两个状态表；参数分别是实际和期望状态。 | 两表键值完全相同则 true；不修改输入。 | 必需；身份匹配必须检测缺项、多项和状态值差异。 |
| northValue(record)（439–442） | 把账本中用字符串 none 表示的“无方向”转换为模板约定的 nil。参数为账本记录。 | 返回 boolean 或 nil。 | 必需；统一账本 sentinel 与模板对象字段表示。 |
| sameIdentity(record, captured)（449–460） | 比较一条保护记录与原始捕获对象；拒绝捕获对象的未知字段，并比较坐标、类名、对象名、sprite、方向、north 和状态。 | 返回身份完全相同的 boolean。 | 必需；账本校验不能只按 index 盲信保护类别。 |
| P.validateTemplate(template)（462–501） | 检查捕获模板版本、412 条密集索引、账本索引、逐条对象身份和四类数量。 | 返回 true 或 false, reason；仅遍历数据。 | 必需；是静态保护策略和捕获顺序一致性的 fail-closed 门。 |
| P.get(templateIndex)（503–506） | 按 1-based templateIndex 查静态保护记录。 | 返回记录引用或 nil；索引要求数值整数。 | 必需；布局编译、客户端判断、世界对象创建/修复均按索引取得策略。 |
| P.matchesLayoutEntry(index, entry, anchor)（508–517） | 检查世界坐标布局项是否与账本记录加 anchor 后的完整身份相符。参数为索引、布局项、模板世界锚点。 | 返回 boolean；不改入参。 | 必需；服务端修复等路径需要确认布局记录没有被替换或错位。 |
| P.matchesCapturedEntry(index, entry)（519–529） | 检查模板空间记录与账本对象身份/保护类别是否相符。 | 返回 boolean。 | 必需；服务端世界对象生成前校验捕获身份。 |
| P.worldEntry(templateIndex, anchor)（531–551） | 将索引对应的静态记录平移到给定世界锚点。参数是索引和含 x/y/z 的锚点表。 | 返回带世界坐标及完整身份、protectionClass 的新表，非法输入返回 nil；state 字段沿用账本状态表引用。 | 必需；修复路径需要从可信账本重建预期世界项。 |

### 3. RV_RoomTemplate.lua：模板编译、schema 校验与查询

该文件把有序捕获源编译成统一模板对象。启动时先校验捕获源与 ProtectionManifest 身份，再构造 bitmap/celldef、build/walk AABB 和 roof target，最后验证编译结果。编译结果元数据为 100×100、坐标范围 x/y ∈ [-50,50)、z ∈ [-32,32)，模板对象数 412。

#### 3.1 输入校验、复制和编译辅助函数

| 函数与位置 | 模块语义、参数 | 返回值/副作用 | 对当前模块是否必需 |
|---|---|---|---|
| finiteInteger(value)（48–52） | 检查数值、排除 NaN/正负无穷并要求整数。 | boolean。 | 必需；schema 中的坐标、索引和范围均须是有限整数。 |
| exactKeys(value, expected, optional)（54–71） | 对表的允许键集做精确检查；expected 是必需键集合，optional 是可省略键集合。 | boolean；非表、未知键或缺失必需键均失败。 | 必需；禁止旧字段别名和未知字段进入当前开发期 schema。 |
| denseList(value)（73–86） | 检查 1 开始连续、无洞且只有整数索引的数组。 | 返回元素数或 nil。 | 必需；对象、build cell、segment、roof target 等顺序表依赖稳定索引。 |
| sameScalarTable(left, right, allowedKeys)（88–97） | 对允许字段范围内的状态表做精确键值比较。 | boolean。 | 必需；用来核对捕获状态与账本及 roof identity。 |
| sameCaptureIdentity(source, record, index)（99–109） | 比较一个原始对象和账本记录；把记录的 north=none 规范为 nil。 | boolean。 | 必需；供 assertSource 拒绝顺序/对象身份不一致。 |
| assertSource()（111–177） | 无参数；验证捕获源根 schema、版本、对象数、对象字段、每项状态、保护记录一致性和完整 cab build mask。 | 成功时无返回；不满足时抛出错误终止模块加载。 | 必需；编译前 fail-closed，避免任何旧/部分/错序源数据生成 geometry。 |
| newRowWithEmptyFlags()（179–185） | 无参数；建出全 100 个 x 位置且三个 z segment 标记为 false 的 bitmap 行。 | 返回新行表。 | 必需；初始化 bitmap 的空格语义。 |
| copyState(source)（187–191） | 浅拷贝对象状态表。 | 返回新表。 | 必需；编译后的对象/identity 与原始捕获状态不共享可变 state 表。 |
| copySegments()（193–203） | 复制三段 z segment schema。 | 返回新数组，每项含 name/minZ/maxZExclusive。 | 必需；编译元数据需携带当前 segment 契约副本。 |
| copyObject(source, index, protectionClass)（205–219） | 按当前 schema 编译一条原始对象，并赋 templateIndex 与保护类别。 | 返回新对象表，state 单独复制。 | 必需；这是原始列表变为 cell/layer 索引对象的单项转换。 |
| compileAabbs()（221–246） | 无参数；walk 范围取室内常量，build 范围从 buildCells 求外接矩形。 | 返回 walkAabbs、buildAabbs 两个列表。 | 必需；向消费者提供行走与建造范围并接受后续身份校验。 |
| compileRoofTargets(objects)（248–305） | 在编译对象中，以 buildCells 的南侧 cab 窗为锚识别唯一窗口和其南侧唯一地板。参数为按原索引顺序的编译对象列表。 | 返回一个含完整对象 identity 的 room-refresh-floor target 列表；数量不唯一时抛错。 | 必需；屋顶刷新需要稳定目标而不能运行时猜测地板对象。 |

#### 3.2 编译后数据的验证函数

| 函数与位置 | 模块语义、参数 | 返回值/副作用 | 对当前模块是否必需 |
|---|---|---|---|
| validPoint(point)（414–418） | 检查坐标表键集合恰为 x/y/z 且数值有限为整数。 | boolean。 | 必需；metadata 锚点和 sourceTarget 有明确坐标 schema。 |
| validObject(object, x, y, z)（420–446） | 检查单条 celldef 对象、所在坐标、索引、保护类、字符串身份字段、north 类型和允许状态字段。 | boolean；不修改对象。 | 必需；阻止编译结果中的漏字段、未知字段、越层或重复身份。 |
| validAabbList(list)（448–469） | 检查非空密集 AABB 列表、坐标边界和 min < max。 | boolean。 | 必需；walk/build 几何范围是可被服务端消费的权限/范围契约。 |
| RoomTemplate.validate(value)（471–707） | 校验根字段、当前 metadata、3 段 schema、100×100 bitmap 密度、每个对象与 templateIndex 唯一连续性、bitmap 与 celldef 的一致、AABB/buildCells/roof target identity。参数为模板表。 | 成功返回 true，失败返回 false, reason；只读遍历。 | 必需；编译后结构和其汇总位图都影响生成、范围和恢复行为；校验保证只有当前完整 schema 可继续。 |

#### 3.3 对外查询接口与坐标校验

| 函数与位置 | 模块语义、参数 | 返回值/副作用 | 对当前模块是否必需 |
|---|---|---|---|
| cellCoordinates(x, y)（709–713） | 检查模板平面坐标整数且在 100×100 边界内。 | boolean。 | 必需；给 cell 和 layer 查询共用边界门。 |
| RoomTemplate.supportsZ(z)（715–718） | 检查 z 是否为 [-32,32) 的整数。 | boolean。 | 必需；validate 和消费者查询共享统一楼层范围。 |
| RoomTemplate.get(templateId)（720–723） | 按固定 TEMPLATE_ID 取唯一编译模板。 | 当前 id 返回模板单例，否则 nil。 | 必需；本目录内 Geometry/Layout 与多处 client/server 使用该入口。 |
| RoomTemplate.cellAt(value, x, y)（725–729） | 按模板平面坐标读取稀疏 celldef cell；只接受模块编译出的模板单例。 | 返回内部 cell 表引用或 nil。 | 作为内部/公开查询基础是必需；但返回的是可变引用，不能视为只读隔离。 |
| RoomTemplate.segmentMayHaveLayer(value, x, y, segment)（731–737） | 用 bitmap 粗筛某 cell 是否可能在指定 z segment 有层；仅认当前模板和三个 segment 名称。 | boolean；bitmap 为 false 时可快速排除。 | 当前未见目录外调用；若承诺粗筛 API 则必要，否则属于可移除查询接口。 |
| RoomTemplate.hasLayer(value, x, y, z)（739–750） | 检查 bitmap segment 后再确认单个 z 的对象层非空。 | boolean。 | 当前未见目录外调用；保留时提供精确单层查询。 |
| RoomTemplate.hasAnyLayer(value, x, y, zMin, zMax)（752–774） | 对半开 z 区间 [zMin,zMax) 检查任意一层是否有对象，先按 segment bitmap 筛选。 | boolean。 | 当前未见目录外调用；保留时提供区间层查询；与 hasLayer 是同一查询族。 |
| RoomTemplate.roofTargets(value)（776–779） | 取得当前模板的 roof refresh target 列表。 | 返回内部列表引用或 nil。 | 必需；RV_RoofRefresh.lua:10 使用此接口。 |
| RoomTemplate.orderedObjects(value)（784–811） | 把稀疏 celldef 的对象通过 templateIndex 重排成原始捕获顺序，并拒绝索引非法、重复、缺项。 | 返回新数组（其中对象仍是内部对象引用），不完整时 nil。 | 必需；Layout、客户端拆除、服务端生成/保护修复依赖稳定顺序和重复占格身份。 |

目前目录外调用扫描未发现 segmentMayHaveLayer、hasLayer、hasAnyLayer 的调用；cellAt 主要被本文件的查询实现使用。保留这些方法的理由是它们构成完整的只读空间查询面，不是已证明的当前跨模块依赖。

### 4. RV_Layout.lua：完整布局计划和壳边所有权

该模块在加载时先校验模板、保护账本及 6×4 cab buildCells；Layout.make 再根据服务端可信锚点构造纯 Lua 计划对象。计划含清理矩形、managed bitmap、room/wall/roof bounds、墙坐标及 shell-edge ledger、412 个世界坐标模板对象副本、generator 点。代码明确不直接修改世界。

| 函数与位置 | 模块语义、参数 | 返回值/副作用 | 对当前模块是否必需 |
|---|---|---|---|
| Layout.eachStructureCoordinate(bounds, callback)（64–85） | bounds 含墙矩形、room/roof 坐标与楼层；对墙矩形坐标及转换到 roofZ 的捕获屋顶对象坐标调用 callback(x,y,z)，并去重屋顶坐标。 | 无返回；调用 callback 是全部输出。 | 必需；RV_ServerSchema.lua:535 与客户端 RV_ContextMenu_RoomOwnership.lua:84 共用墙/屋顶扫描规则。 |
| point(x, y, z)（87–89） | 构造三维点。 | 新 {x,y,z} 表。 | 必需的小型私有构造器；统一 Layout 点数据形状。 |
| rectangle(minX,maxX,minY,maxY,z,minZ,maxZ,halfOpen)（91–102） | 构造 bounds；halfOpen 只在传 true 时为 true。 | 新 bounds 表，含平面范围、可选 z、z 范围和半开标志。 | 必需；make 中多个区域共用同一契约。 |
| offsetPoint(anchor, offset)（104–106） | 将偏移加到 anchor。参数均为 x/y/z 表。 | 新三维点表。 | 必需；用于生成 generator 世界点。 |
| appendWall(result,x,y,z,north,sprite,role,corner)（108–123） | 将选中的捕获墙/边界对象转成墙条目，推入 result；用 Bitmap.edgeKey 构成规范 edge key。 | 无显式返回；修改传入 result。 | 必需；墙对象、朝向和边界管理 key 在此统一成单行结构。 |
| isShellSprite(entry)（125–131） | 按墙、栏杆、窗及指定门 sprite 前缀识别壳体对象。 | boolean。 | 必需；防止室内家具等被误选为边界墙 host。 |
| shellPriority(entry)（133–140） | 给同一边的候选对象按木墙、栏杆、窗、门框、门及其他对象排序。 | 返回排序等级整数。 | 必需；重叠 host 需确定性选择，避免 pairs/捕获变化导致 ledger 不稳定。 |
| wallCoordinatesForAnchor(cx, cy, cz)（148–200） | 依据室内矩形遍历北/西/东/南及角点 host，在模板对象中筛选 z0 壳体候选，并记录选中 templateIndex 与候选 index 列表。 | 返回墙坐标数组；读取 templateObjects，不改捕获数据。 | 必需；生成边界 host ledger 的来源。 |
| 嵌套 addCapturedEdge(side,x,y,north)（155–184） | side/x/y/north 描述当前边；闭包捕获 anchor、result 和室内界限。筛选同格同朝向的 IsoThumpable/IsoWindow shell sprite 候选，按优先级排序并 append。 | 无显式返回；无候选时不添加，否则修改闭包中的 result。 | 必需；是单边 host 解析过程，不能简单换成全格对象或每边一对象。 |
| table.sort 匿名比较回调（166–171） | left/right 是候选项；按 shellPriority 排序，同优先级按 template index 稳定排序。 | comparator boolean；无外部副作用。 | 必需；消除相同边多对象时非确定性。 |
| annotateWallEdges(wallCoordinates,cx,cy)（207–234） | 从 north/host 坐标恢复其所属 north/south/east/west 边和相邻 cell，并写入 host 坐标与 edge key。 | 无显式返回；原位补充每条 wall entry 字段，格式错误时抛错。 | 必需；壳体对象所在格和逻辑边界 edge 是不同事实，server schema/guard 需要规范元数据。 |
| Layout.make(cx, cy, cz)（239–413） | 输入可信模板锚点；内部 floor 坐标，再创建清理范围、managed scope/bitmap、活动/建造格、room/wall/roof bounds、壳边 ledger、模板对象世界坐标副本和 generator 点。 | 返回完整 plan 表；不触碰世界对象；必要前提不满足时加载期或调用期报错。 | 必需；布局规划的主接口，被 server schema、generation、RVMapping 和存档 schema gate 使用。 |

Layout.make 自身没有验证参数类型或拒绝小数，而是直接 math.floor；调用端必须传入可信、合法锚点。这符合项目“客户端不提供可信坐标”的约束，但也使调用者校验成为接口前置条件。

### 5. RV_TemplateGeometry.lua：区域变换与模板对象定位

模块加载时获取并验证唯一当前模板，缓存 orderedObjects。区域大小来自 Constants，锚点偏移固定为 50。负坐标使用 floor 对齐 100 格区块；转换还检查两点属于相同区块，避免把邻区坐标误解释成此房车局部坐标。

| 函数与位置 | 模块语义、参数 | 返回值/副作用 | 对当前模块是否必需 |
|---|---|---|---|
| finiteNumber(value)（23–26） | 检查有限数值且排除 NaN/无穷。 | boolean。 | 必需；world point 可为数值而不一定先假设整数。 |
| integer(value)（28–30） | 以 finiteNumber 为前提检查整数。 | boolean。 | 必需；锚点、模板索引和对象偏移要求整数。 |
| validPoint(point)（32–36） | 检查 table 且 x/y/z 均为有限数值。 | boolean。 | 必需；世界/模板坐标转换的基础参数门。 |
| validAnchor(anchor)（38–47） | 要求 x/y/z 为整数且 x/y 是所属 100 格区块起点+50。 | boolean。 | 必需；确保锚点只能落在预定区域中心。 |
| sameRegion(world, anchor)（49–54） | 比较 world 与 anchor 的 XY 区块坐标。 | boolean。 | 必需；阻止跨 RV 区域转换。 |
| G.blockOriginForWorld(x, y)（56–62） | 对任意有限世界 XY 取所属 100×100 区块左下原点。 | 返回 {x,y} 或 nil。 | 必需；是锚点构造的基础；当前直接外部调用不多，templateAnchorForWorld 内部使用。 |
| G.templateAnchorForWorld(x, y, z)（64–73） | 根据世界 XY 得到区块中心锚点，Z 原样来自可信调用方。 | 返回 {x,y,z} 或 nil。 | 必需；ProtectedDemolition 用它核实 tag anchor 与世界区域一致。 |
| G.worldToTemplate(world, anchor)（78–88） | 校验点、锚点和同区域后做 world-anchor 差值。 | 返回相对 {x,y,z} 或 nil。 | 必需；客户端对象识别及服务端 tag/对象验证都使用。 |
| G.templateToWorld(offset, anchor)（90–99） | 把偏移加到 anchor，并要求结果仍处同一 XY 区块。 | 返回 world point 或 nil。 | 作为双向转换能力是合理接口；本次扫描未找到目录外直接调用。 |
| validTemplate(template)（101–103） | 只接受 RoomTemplate 单例本身，拒绝形似但替代的表。 | boolean。 | 必需；查询不能绕过启动时验证，拿任意伪造模板查缓存索引。 |
| G.lookupObjectByIndex(templateIndex, template, manifest)（105–120） | 按捕获顺序取对象，可选指定 template 与 manifest；不提供时用当前单例/账本。 | 返回 object, templateIndex, protection；错误/越界返回 nil。 | 必需；客户端/服务端以稳定 index 区分同坐标对象。 |
| G.lookupObjectsAtTemplate(x,y,z,template,manifest)（122–142） | 在模板空间筛选指定整数 cell/layer 的全部对象。 | 返回 {index,object,protection} 数组；输入或模板无效时 nil；零匹配返回空数组。 | 必需；同一格可叠放多对象，单值查找会丢失身份；目前主要作为 lookupObjectsAtWorld 的内层查询。 |
| G.lookupObjectsAtWorld(world,anchor,template,manifest)（144–151） | 先 worldToTemplate 再查询当前相对格对象。 | 返回匹配数组或 nil。 | 必需；RV_ProtectedDemolition.lua:230 使用 world 坐标验证对象与 index 一致。 |
| G.cabContainsWorld(world,anchor,template)（153–166） | 检查世界点是否换算到 z0 buildCells 中，并返回命中的 buildCell 索引。 | 返回 boolean,index；失败返回 false。 | 必需；RV_ProtectedDemolition.lua:295 用于 cab 拆除保护范围排除判断。 |

## 模块间重复能力与公共化判断

### 候选公共函数

1. **有限整数/数值检查**：RV_TemplateGeometry 的 finiteNumber/integer（23–30）与 RV_RoomTemplate 的 finiteInteger（48–52）概念相邻。Geometry 还接受有限小数的 world 坐标；RoomTemplate 强制有限整数。若项目已有共享 Validation 模块，可统一成 isFiniteNumber / isFiniteInteger 并各自按需组合。仅在本目录中增加新通用模块收益有限：目前只有两个消费者文件，依赖与导出面会扩大，保留局部实现更直接。
2. **状态表精确相等**：RV_ProtectionManifest.sameState（428–437）与 RV_RoomTemplate.sameScalarTable（88–97）重复了两表逐键相等检查。RoomTemplate 另要求键属于 allowedKeys；Manifest 的静态 expected 表本身承担允许键约束。若其他模块也需要，可提取 sameScalarMap(left,right,allowedKeys)，再让两边提供不同 key set；当前各自只服务本模块身份校验，单独抽层的收益不明显。
3. **模板对象身份核对**：RoomTemplate.sameCaptureIdentity（99–109）与 Manifest.sameIdentity（449–460）字段高度重叠，但前者以 source/record/index 为方向，后者额外拒绝 captured 未知字段并将 sentinel 转换放在 northValue。二者调用时机与错误职责不同；现在合并会形成依赖循环或把保护账本规则泄漏进编译器，不建议抽为公共业务函数。
4. **buildCells 多次扫描**：compileAabbs（221–246）和 compileRoofTargets（248–305）都扫描 buildCells 求边界。可以抽一个私有 buildCellBounds，但数组仅 24 项、扫描各一次、消费目的不同；当前合并对复杂度/性能没有明显收益。
5. **区域转换与索引查询**：worldToTemplate、lookupObjectsAtWorld 已体现合适的复用层：上游只需提供 world point 和 anchor，无需各调用端重复验证区域、模板坐标、重复对象和保护账本索引。继续向外提取会把模板领域约束扩散到通用工具里。

结论：只有数值校验和状态表比较具备纯函数复用潜力，但不建议为本目录单独新增通用模块；先保持小型校验器与具体 schema 同文件。Layout.eachStructureCoordinate 已解决 server/client 对墙与屋顶扫描范围的重复实现，应继续作为跨层共享接口。

## 拆分建议

- **最有拆分候选：RV_RoomTemplate.lua。** 819 行中同时含原始源校验/编译（111–412）、编译结果深校验（414–707）和查询接口（709–811）。职责边界清晰，可在增长时拆成 compile、validate、query 三个内部模块，再由一个 facade 暴露稳定 API。当前它们共享 schema 常量、segments、内部模板单例和局部 helper；立即拆分会多出内部导入契约，并可能造成 validate/query 互相 require。因此目前保持单文件较简单，等模块增加第二个模板或校验实现膨胀时再拆。
- **RV_Layout.lua 不建议现在拆。** wall host 选择、edge annotation、shellEdges 和 Layout.make 的返回结构直接耦合；拆分需要引入内部子模块契约，当前 415 行且职责仍是一个纯计划器。
- **RV_ProtectionManifest.lua 不因 553 行而拆。** 绝大多数行是静态账本；行为仅 8 个小函数，校验函数与账本身份数据紧邻是优势。
- **RV_Template.lua 保持纯数据文件。** 不应为文件短小而增加 accessor 或函数层。
- **RV_TemplateGeometry.lua 职责集中且 168 行。** 区域变换、索引查找都服务于同一个“把世界对象对应回已捕获模板身份”的用途，无需进一步拆分。

## 直接访问其他模块数据与接口利弊

### 已观察到的直接读取

- **RoomTemplate 编译对象的 schema 字段被其他文件直接读取。** RV_Layout 在 23–27、39–40、289–294 行读取 Template.metadata.templateVersion/objectCount 和 Template.misc.buildCells；RV_TemplateGeometry 在 155–165 行读取 buildCells；RV_Server_GenerationBuild 在 157–159 行、RV_Construction 在 64 行、RV_Server_TemplateProtectionRepair 在 34–35 及 499 行读取 metadata；RV_ProtectedDemolition 在 243 行读取 metadata.sourceTarget.z。这些是结构字段直读，改变 metadata/misc 的 schema 会同时影响多处。
- **Layout.make 的返回 plan 字段由调用模块直接读取。** RV_ServerSchema 在 39–46、84–95、160–183 行读范围、wallCoordinates 与统计字段；BoundaryServer_Geometry 在 203–227 行读 bitmap/shellEdges；GenerationBuild 在 95–101、151、213 行读 templateObjects/generator；RoofDestinations 在 128–144 行读取 bitmap。它们把 Layout 的返回表当显式数据契约消费。
- **ProtectionManifest 没有发现外部代码直接遍历 P.objects。** 外部依赖其常量与 get/validate/match/worldEntry 等接口；这是目录内封装相对较好的一项。
- **Template 源表作为输入传给验证函数。** 各消费者通过 RoomTemplate 接口获得编译模板，ProtectionManifest.validateTemplate 接受原始 CapturedTemplate 做一致性复核；本轮未发现外部对捕获模板、编译 metadata/misc/celldef/bitmap 的直接赋值。

### 接口是否值得增加

- 对 **RoomTemplate metadata/buildCells**，增加 getIdentity()、getBuildCells() 之类接口能减少调用方绑定字段路径，但收益有限：这些字段本身就是该模板显式 schema，调用方需要比较版本/对象数并遍历确切 build mask；浅 getter 若返回原表不会改善可变性，复制 getter又会引入拷贝和新的接口维护成本。当前调用方只读，模块还有完整 validate() fail-closed 检查，故可以把 metadata/misc 视作有意公开的模板数据契约，而不是隐藏实现。
- 若未来需真正封装，优先一次性定义稳定 facade（只暴露模板 identity、build-cell 迭代、roof target 和 object iteration），同时不再暴露原始单例；不要逐字段加零散 getter。Lua 表本身可变，get() 返回模板单例、cellAt()/roofTargets() 返回内部引用、orderedObjects() 返回内部对象引用的新数组；TemplateGeometry 的查找结果也返回对象/账本记录引用，ProtectionManifest.worldEntry 返回的 state 沿用账本引用，Layout.make 的模板对象副本在 RV_Layout.lua:409 仍共享 captured.state 表。当前静态扫描未发现调用端直接写这些字段，但“read-only”主要是调用约定，不是语言级只读保证。若要强化边界，应复制外发的嵌套 state 或定义只读访问协议。
- 对 **Layout 计划字段**，不建议改成大量 getter。它是计划器输出值而非私有缓存；server schema、generator、boundary guard 要消费完整不同部分，结果表的字段契约正是模块输出。应保持 plan 生成归 Layout，世界变更归服务端应用层。
- 对 **ProtectionManifest**，继续只通过现有接口访问即可；objects 虽是导出字段，但未发现外部直接使用，若要加强封装可改为 local ledger 并保持 get() / 校验函数行为不变，不过目前并无足够维护收益要求重构。

## 复核记录与未覆盖项

- **文件枚举**：只读列出本目录实际 5 个 Lua 文件；文件行数分别为 442、553、819、415、168。
- **函数提取与逐行核对**：对本目录执行 rg -n 'function' 并按定义位置复核。定义计数为 Geometry 14、Layout 12（含嵌套 addCapturedEdge 和 table.sort 匿名回调）、RoomTemplate 25、ProtectionManifest 8、Template 0，总数 59。表内行号对应实际函数起始行；RV_Template 与保护账本的长段落是数据表，不包含函数。
- **跨模块引用核对**：对 media/lua/ 搜索 RoomTemplate、Layout、ProtectionManifest、TemplateGeometry 的 API 及 metadata/buildCells/plan 字段调用；检查到的 metadata/misc 直接读取均为只读表达式。本轮没有发现外部对这些模板字段的直接赋值。
- **交付文档检查**：目标文件此前不存在；创建文档后再核对 Markdown 标题、表格行与源码函数清单总数。
- **未覆盖**：未检查参考模组、官方 Lua、反编译代码或运行时行为；未检查其他文件夹内部设计；没有评估性能基准或 Lua 表别名在运行时被第三方修改的情形。


