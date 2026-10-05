# shared/RailroaderRV/RVMapping 模块分析
> **状态（RailroaderRV 1.0）**：本文件是静态审计记录；其行号、计数和源码结论并非本次发布的全量重核，也不是运行时验证。当前实现以 [源码](../../contents/mods/RailroaderRV/42/) 与 [README](../../README.md) 为准，项目约束以 [agents.md](../../../agents.md) 为准。历史建议不构成修复授权，采纳前须按现行约束重新取证。

## 假设、范围、成功条件与验证方式

- **假设**：只分析模组当前目录 `media/lua/shared/RailroaderRV/RVMapping/` 下的文件。目录扫描到 **1 个文件**：[RV_RegionSlots.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RVMapping/RV_RegionSlots.lua)（155 行）。行号以本次读取的当前源码为准。本模块被客户端与服务端同时 `require`，因此按「双端共享坐标合同」解释。
- **范围**：覆盖该文件全部具名函数、局部函数与表方法（本文件没有匿名函数表达式）；只读检索整个 `media/lua` 树（当前 65 个 `.lua` 文件）判断导出 API 的真实使用面、槽位/锚点/矩形映射的双端消费者，以及「谁绕过了本模块」这类接口边界问题。唯一写入目标是本报告。
- **成功条件**：每个函数都有精确起始行、参数含义、返回/副作用、本模块语义和必要性判断；给出复用/提取/拆分建议与接口边界证据；明确区分「源码事实」与「条件性推断」。不运行游戏或 runtime 测试。
- **验证方式**：列目录文件与行数；用 `function` 关键字扫描（排除 `type(x) ~= "function"` 类比较行）并与逐行编号全文读取交叉核对定义与起始行；用全树搜索 `RegionSlots`、`slotIndex`、`anchor`、`rvPosition`、`getmetatable` 核对导入方、公开字段读取、函数调用位置与被绕过情况；完成后核对报告的文件清单、函数条目数与行号引用。源码扫描是静态分析，不替代运行时验证。

## 目录职责与清单

RVMapping/ 目前只有一个文件，职责是「RV 管理区域的纯坐标合同」：把 1-based 槽位索引在「行列坐标 / 100×100 半开 XY 矩形 / 区域中心锚点」三者之间双向换算，并在分配前严格校验占用矩形列表并选出首个空槽。本模块不读世界状态、不写 ModData、不注册事件、不做网络、不持有跨调用缓存。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_RegionSlots.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RVMapping/RV_RegionSlots.lua) | 10 | 5×20 槽位矩阵的索引↔行列↔半开矩形↔中心锚点双向映射；占用列表的稠密/形状/对齐/重叠校验与首个空槽分配 |
| **总计** | **10** | 6 个 `local function` + 4 个 `Slots` 表方法，无匿名函数表达式 |

函数计数口径：计入具名函数、`local function`、表方法（`function Slots.foo()`）与作为参数/回调的匿名函数表达式；不计入纯常量字段赋值（L15-L18 的 `Slots.ROWS/COLUMNS/COUNT/REGION_SIZE`）与 `local a = StrictSchema.integer` 这类绑定（L21）。本文件没有 `type(x) == "function"` 比较行，也没有匿名闭包，因此机械扫描的 10 条定义与报告表格一一对应。

## 逐文件、逐函数分析

### RV_RegionSlots.lua

模块在 [RV_RegionSlots.lua](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RVMapping/RV_RegionSlots.lua)。L6 `require` `RV_Constants`，L7 `require` `RV_StrictSchema`，L10 在全局 `RailroaderRV` 下创建或复用 `RegionSlots`，L12-L24 把常量快照进模块级局部（`SIZE`、`integer`、`FIRST_MIN_X/Y`、`FIRST_Z`），L26-L28 是加载期断言（区域尺寸必须恰为 100，否则 `error`），L155 `return Slots`。文件头注释（L1-L4）声明槽位从西南角按行优先排序（先 X 后 Y），且本模块从不读取或修改世界状态与 ModData —— 本次全树核查与该声明一致：文件内没有任何 `getSquare`/`ModData`/`Events`/`sendClientCommand` 调用。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| slotForIndex（L30） | index：槽位序号（任意值，先过 `integer`）；`nil`、< 1 或 > `Slots.COUNT` 时返回 nil（L31-L32）；否则按零基 `math.floor(zeroBased / COLUMNS) + 1` 与 `zeroBased % COLUMNS + 1` 返回 `(row, column)`（L34-L35）。无副作用。本模块语义：索引 → 行优先行列的唯一换算，是锚点、矩形与正向导出的共同底座。 | **必须**：所有导出映射的入口校验，内部消费点为 `indexToAnchor`（L104）、`indexToRegion`（L110）。行列顺序（先 X 后 Y）是矩阵布局合同本身，写错会让锚点与矩形整体错位。 |
| indexForSlot（L38） | row、column：1-based 行列（任意值，先过 `integer`）；越界返回 nil（L40-L43）；否则返回 `(row - 1) * Slots.COLUMNS + column`（L44）。无副作用。本模块语义：行列 → 索引的反向换算，同时被矩形与锚点校验复用。 | **必须**：`indexForAnchor`（L125）与 `validatedRegion`（L98）都用它把几何反查成索引；删除会让「锚点/矩形必须落在某个真实槽位上」这条判定失去唯一实现。 |
| boundsForSlot（L47） | row、column：假定已由调用方校验（本函数不重复校验）；返回**新表** `{minX, minY, maxX, maxY}`，`maxX = minX + SIZE`、`maxY = minY + SIZE`（L48-L55），即半开区间。无副作用。本模块语义：槽位 → XY 矩形的唯一几何实现。 | **必须**：`indexToRegion`（L112）与 `anchorForSlot`（L59）都依赖它；半开语义（`max = min + SIZE`）必须与消费方的 `x >= minX and x < maxX` 判定一致，本次核查确认 `RV_UtilityContextMenu.lua:78`-L85、`RV_UtilityWater_Objects.lua:92`-L93、`RV_RailroaderServer_Mapping.lua:107` 都按半开比较。 |
| anchorForSlot（L58） | row、column：假定已校验；返回新表 `{x = region.minX + SIZE / 2, y = region.minY + SIZE / 2, z = FIRST_Z}`，即区域中心 + `Constants.TELEPORT_Z`（L59-L65）。无副作用。本模块语义：锚点的唯一定义 —— 锚点**是**区域中心，不是任意可用点。 | **必须**：`indexToAnchor`（L106）与 `findFirstFree`（L149 第二个返回值）都依赖它。锚点被写入水槽 tag（`RV_UtilityWater_Objects.lua:142`-L148 只写 slotIndex，锚点由本函数推导）、边界推导（`RV_BoundaryServer_Geometry.lua:220`）与模板布局原点（`RV_Server_RecordValidation.lua:47` 用 anchor 调 `Layout.make`），公式改动会同时移动世界几何。 |
| denseRegionList（L67） | regions：占用矩形数组表；非表或**带 metatable**返回 nil（L68-L70），任一键不是 1..`Slots.COUNT` 范围内的整数返回 nil（L73-L75），键计数不等于最大键（即稀疏或含空洞）返回 nil（L80），合法时返回元素个数（空表返回 0）。只创建局部计数变量，无副作用。本模块语义：把「稠密数组」这一输入约束变成可判定的前置条件，避免对稀疏表使用 `#`。 | **必须**：`findFirstFree`（L129）用它决定遍历区间。Kahlua 的 `#` 对稀疏表结果不确定，且带 metatable 的表可能把 `__index` 伪装成合法占用项；这两条判定是该函数当前唯一的存在理由（全树 `getmetatable` 只剩本行 L68 一处）。 |
| validatedRegion（L84） | region：预期只有 `minX/minY/maxX/maxY` 的矩形表；四个字段必须是整数且 `maxX == minX + SIZE`、`maxY == minY + SIZE`（L85-L90）；随后要求相对首槽的 `dx/dy` 非负、在半开矩阵范围内且能被 `SIZE` 整除（L92-L96）；合法时返回 `(index, 规范化矩形副本)`，否则返回 nil（L99-L100）。返回的是**新表**，不修改入参。本模块语义：矩形 → 槽位的反查，同时产出供重叠检测使用的规范化副本。 | **必须**：`findFirstFree`（L134）用它逐项校验占用记录。它同时承担形状校验（恰好 100×100）、对齐校验（必须落在槽位网格上）与范围校验三层语义，是「客户端不能伪造任意矩形占位」在纯映射层的基础。 |
| Slots.indexToAnchor（L103） | index：槽位索引；经 `slotForIndex` 失败返回 nil（L105），否则返回 `anchorForSlot` 的新表。无副作用。本模块语义：索引 → 锚点的对外正向接口。 | **必须**：全树 6 个真实调用点，跨客户端与服务端：server `RV_UtilityWater_Objects.lua:38`、`RV_BoundaryServer_Geometry.lua:220`、`RV_Server_RecordValidation.lua:41`、`RV_RailroaderServer_Mapping.lua:254`、`RV_RailroaderServer_EntryExit.lua:458`；client `RV_UtilityContextMenu.lua:77`。另在 shared `RV_UtilityCatalog.lua:17` 的注释里被指定为「锚点应由此推导」的权威入口。 |
| Slots.indexToRegion（L109） | index：槽位索引；失败返回 nil（L111），否则返回 `boundsForSlot` 的新半开 XY 矩形（L112），**不含 Z**。无副作用。本模块语义：索引 → XY 矩形的对外正向接口。 | **必须**：全树 5 个调用点：server `RV_UtilityWater_Objects.lua:39`、`RV_RailroaderServer_WallReload.lua:69`、`RV_RailroaderServer_Mapping.lua:123`/L257；client `RV_UtilityContextMenu.lua:76`。调用方自行补 Z 契约（例如 `RV_UtilityWater_Objects.lua:90`-L91 用 anchor.z 加常量偏移）。 |
| Slots.indexForAnchor（L115） | anchor：`{x,y,z}`（任意值，先逐个过 `integer`）；`z ~= FIRST_Z` 直接 nil（L117）；随后要求相对首槽中心的 `dx/dy` 非负、在半开矩阵范围内且能被 `SIZE` 整除（L119-L124），最后返回 `indexForSlot(dy / SIZE + 1, dx / SIZE + 1)`。无副作用。本模块语义：锚点 → 槽位的**严格**逆映射 —— 校验的是「这个点恰好是某个槽位的中心」，而不是「这个点落在某个槽位里」。 | **必须（但外部消费面很窄）**：当前全树只有 1 个外部调用点 `RV_ServerSchema.lua:62`（在 `validateTargetCoordinates` 里判断 relocation 目标是否等于某个合法锚点），其余使用都在本文件内部逻辑之外无。它的语义无法由 `indexToRegion` 替代：后者接受矩形内任意点，会放过「目标点不是锚点」的非法目标。保留，但调用面窄这一点应在改动前确认（见拆分章节）。 |
| Slots.findFirstFree（L128） | regions：当前占用矩形数组；`denseRegionList` 失败返回 `nil, "invalid-region-list"`（L130），任一项 `validatedRegion` 失败返回 `nil, "invalid-region"`（L135），任两项 AABB 相交返回 `nil, "overlapping-regions"`（L138-L140），全部槽位占用返回 `nil, "no-free-slot"`（L152），成功返回 `(index, anchor, region)` 三元组（L149）。只建局部 `occupied`/`validated` 集合与返回表，不修改入参。本模块语义：槽位分配的唯一权威判定（严格校验 + 两两重叠检测 + 行优先取首个空位）。 | **必须**：唯一外部调用点 `RV_RailroaderServer_Mapping.lua:276`（`allocateRVRegion` 分配新 RV 槽位），且调用方只取前两个返回值，L280 另用 `regionForAnchor(anchor)` 重算 XY 矩形。O(n²) 重叠扫描在当前 100 槽上限下可接受。 |

**加载期断言（非函数，单列说明）**：L26-L28 在模块加载时要求 `SIZE` 是 number 且恰为 100，否则 `error("RailroaderRV: RV region slot size must be 100")`。它不是函数定义、不计入函数数，但它是本模块唯一会主动中断加载的行为：任何 `require` 本模块的代码（含 shared `RV_UtilityCatalog.lua:8`，见接口章节）都会连带触发该校验。

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **严格整数判定已经收敛（已消除的重复，源码事实）**：本文件 L7 与 L21 改为 `StrictSchema.integer`，不再自带私有 `integer`。同一轮里 shared Water Catalog 也做了同样的替换（`RV_UtilityCatalog.lua:7`/L13），server `RV_UtilityWater_Objects.lua:9`/L25 是第三个消费者。**旧报告的结论需要更正**：`RV_StrictSchema` 现在**不含** `exactKeys`，本次全树检索 `exactKeys` 只剩 server 本地 2 处命中（`RV_UtilityWater_Objects.lua:13` 定义、L60 调用），旧报告所说「本文件的 exactKeys 与共享水务目录的同名函数逐项一致，应提取 strictInteger/exactKeys」对当前源码只对 integer 成立。
- **严格区域/锚点规则不应泛化，应留在本模块（源码事实 + 判断）**：`boundsForSlot`/`anchorForSlot`/`validatedRegion`/`findFirstFree` 绑定三件事：5×20 矩阵、每格 100×100、锚点取区域中心且 Z 为 `TELEPORT_Z`。这三件事来自 `RV_Constants`（L15-L18、L22-L24），任何一处配置化都会同时移动世界几何（生成原点、边界、水槽锚点）。判断：不提取、不参数化。
- **矩阵整体 XY 外框公式仍有两份实现，值得集中但收益有限（条件性推断）**：`RV_RailroaderServer_Mapping.lua:43`-L63 用 `C.RV_REGION_SIZE` × `RegionSlots.COLUMNS/ROWS`（L56-L57）算全矩阵外框并补 Z，`RV_BoundaryServer_Geometry.lua:89`-L97 用 `C.RV_REGION_SIZE * C.RV_REGION_SLOT_COLUMNS/ROWS` 直接重算同一 XY 外框（L93-L95）。两处都从常量推导，规则等价，但都自行拼装而不是调本模块。净收益：新增一个「整体 XY 外框」导出能消除公式漂移；成本：本模块目前不暴露矩阵原点偏移语义（它只暴露单槽几何），新增导出需要把 `FIRST_MIN_X/Y` 与行列数一起外泄，反而扩大了合同面。判断：**当前不建议新增**，因为 `RV_BoundaryServer_Geometry` 还需要在同一处表达 Z 范围与半开 `maxZ`，集中 XY 后仍要各自补 Z，净收益不抵新增接口。
- **`findFirstFree` 的第三个返回值 `region` 当前无调用者（源码事实）**：L149 返回 `(index, anchor, Slots.indexToRegion(index))`，唯一调用点 `RV_RailroaderServer_Mapping.lua:276` 只接收 `slotIndex, anchor`，L280 用 `regionForAnchor(anchor)` 重算 XY 矩形。判断：这是**可直接受益的复用点**（接收第三个返回值即可删掉一次 XY 重算），但 `regionForAnchor` 在 L280 是既有路径的共用分支（L256-L257 对已存在记录也用它），替换需要同时处理两条分支；属条件性推断，未做改造实验。
- **「锚点不是持久化数据」是本模块最重要的语义，且已有 module 违反（源码事实 → 见接口章节）**：`RV_UtilityCatalog.lua:15`-L17 明确写「tag 里故意不含 anchor，它是 `RegionSlots.indexToAnchor(slotIndex)`，一次纯模板查表」；`RV_RailroaderServer_EntryExit.lua:504`-L511 明确写「durable record 只存 identity、slot 分配与两个跨重启姿态；anchor/region/bounds/shell edges 在被读取时由 slotIndex 与编译模板推导」。这正是本模块存在价值的对外表述。**禁止把 anchor 落盘**应作为本模块合同的一部分被其他报告引用。
- **本模块没有任何可提取到 `shared/Common` 的通用工具（判断）**：文件内 6 个私有 helper（`slotForIndex`/`indexForSlot`/`boundsForSlot`/`anchorForSlot`/`denseRegionList`/`validatedRegion`）全部绑定本矩阵语义；唯一通用性候选 `denseRegionList`（稠密数组判定）全树没有第二个实现，而 `getmetatable` 拒绝策略只在这里（L68）出现一次，提取到 Common 会让「谁来决定 metatable 策略」失去 owner，净收益为零。

### 是否进一步拆分

- **不建议拆分本文件（155 行、10 函数）**。四类职责（索引换算 L30-L45、几何生成 L47-L65、占用校验 L67-L101、对外映射与分配 L103-L153）通过窄接口互锁：`validatedRegion` 复用 `indexForSlot`，`findFirstFree` 同时复用 `denseRegionList`+`validatedRegion`+`indexToAnchor`+`indexToRegion`。拆成多文件只会把 `SIZE`/`FIRST_MIN_X/Y`/`FIRST_Z` 三个私有快照变成跨文件合同。
- **不建议把 `findFirstFree` 拆成「校验」与「分配」两个模块**。校验与分配共用同一份规范化矩形副本（L134-L144 的 `validated` 数组同时服务重叠检测与占用标记），拆开需要把规范化矩形结构提升为对外类型，成本高于收益。
- **不建议把本文件并入 `shared/Common`**。Common/ 的四个文件都是「无几何语义的常量与标量工具」，本模块携带矩阵布局与分配策略；合并会让 `RV_Constants` 的消费者意外连带加载加载期断言（L26-L28）。
- **如果矩阵维度或分配策略增长，拆点唯一候选是「分配」**：把 `denseRegionList`/`validatedRegion`/`findFirstFree` 三个函数（L67-L153）单独成 `RV_RegionAllocator.lua`，本文件只保留纯几何映射。当前规模（一个调用点）不支持这个动作。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **导出形态**：`return Slots`（L155）返回表本身，同时 L10 把同一个表发布到全局 `RailroaderRV.RegionSlots`。本次全树检索 `RailroaderRV.RegionSlots` 只命中本文件 L10/L12，**没有**模块走全局路径绕过 `require`；所有消费者都通过 `require("RailroaderRV/RVMapping/RV_RegionSlots")` 取得同一张表。
- **函数字段（4 个，全部有真实调用点）**：`indexToAnchor`（L103，6 个调用点，跨 client/server）、`indexToRegion`（L109，5 个调用点，跨 client/server）、`indexForAnchor`（L115，1 个调用点，server）、`findFirstFree`（L128，1 个调用点，server）。
- **数据字段（4 个）**：`ROWS = C.RV_REGION_SLOT_ROWS`（L15）、`COLUMNS = C.RV_REGION_SLOT_COLUMNS`（L16）、`COUNT = C.RV_REGION_SLOT_COUNT`（L17）、`REGION_SIZE = C.RV_REGION_SIZE`（L18）。外部读取点：`RegionSlots.COUNT` → client `RV_UtilityContextMenu.lua:75`；`RegionSlots.COLUMNS` → server `RV_RailroaderServer_Mapping.lua:56`；`RegionSlots.ROWS` → server `RV_RailroaderServer_Mapping.lua:57`；`RegionSlots.REGION_SIZE` → **无任何外部读者**（本次全树检索 `RegionSlots.REGION_SIZE` 命中 0，只有本文件 L18 的赋值；`RV_TemplateGeometry.lua:14` 与 `RV_RailroaderServer_Mapping.lua:43` 都直接读 `Constants.RV_REGION_SIZE` 而不是读本字段）。
- **不存在的旧接口（旧报告失效项）**：旧 `shared-RVMapping.md` 记录的 `Slots.indexToSlot`、`Slots.slotToIndex`、`Slots.indexForRegion` 在当前源码中**已不存在**；旧报告称「15 个函数、8 局部 + 7 导出、其中两个公开包装函数无调用点」，当前实际是 **10 个函数、6 局部 + 4 导出**，且 4 个导出全部有调用点。
- **双端使用结论（源码事实）**：本模块**同时被客户端与服务端使用**。客户端 1 个文件：`RV_UtilityContextMenu.lua:8` 导入，L75 读 `COUNT`、L76-L77 调 `indexToRegion`/`indexToAnchor`（`localSlot` 遍历全部槽位判断玩家与目标水务对象是否同槽）。服务端 8 个文件：`RV_UtilityWater_Objects.lua:5`（L38-L39）、`RV_RailroaderServer_WallReload.lua:10`（L69）、`RV_Server_RecordValidation.lua:9`（L41）、`RV_RailroaderServer_Mapping.lua:7`（L56-L57、L123、L254、L257、L276）、`RV_RailroaderServer_EntryExit.lua:4`（L458）、`RV_BoundaryServer_Geometry.lua:10`（L220）、`RV_ServerSchema.lua:8`（L62）。shared 侧 1 个文件：`RV_UtilityCatalog.lua:8`（**只 import，不调用**，见接口边界问题）。
- **典型调用形态（源码事实）**：服务端一律先做严格整数化再交给本模块，例如 `RV_UtilityWater_Objects.lua:37`-L39 `local slotIndex = integer(record.slotIndex); local anchor = RegionSlots.indexToAnchor(slotIndex); local region = RegionSlots.indexToRegion(slotIndex)`；`RV_Server_RecordValidation.lua:39`-L41 `local slotIndex = ServerUtil.integer(record.slotIndex); local anchor = slotIndex and RegionSlots.indexToAnchor(slotIndex) or nil`；`RV_BoundaryServer_Geometry.lua:215`-L220 `local slotIndex = integer(record.slotIndex)` 后 `RegionSlots.indexToAnchor(slotIndex)`。

### 直接读写其他模块的数据

1. **本模块读其他模块的公开常量（唯一一处外部依赖）**：`RV_Constants` 的 `RV_REGION_SLOT_ROWS`（L15）、`RV_REGION_SLOT_COLUMNS`（L16）、`RV_REGION_SLOT_COUNT`（L17）、`RV_REGION_SIZE`（L18）、`TELEPORT_X`/`RV_REGION_MIN_OFFSET_X`（L22）、`TELEPORT_Y`/`RV_REGION_MIN_OFFSET_Y`（L23）、`TELEPORT_Z`（L24），以及经 L7 间接的 `RV_StrictSchema.integer`（L21）。全部是模块初始化时读取并快照进局部变量，运行期不再读常量表；不访问 Constants 的任何私有数据（该模块也没有私有数据）。判断：**保留直接访问**，常量表本身即公开数据合同，且这里读的是「布局参数」而不是「运行期状态」。
2. **本模块不读、不写其他任何模块的数据**：没有 `ModData`、没有 `getSquare`/`getCell`、没有 `Events`、没有 `sendClientCommand`/`sendServerCommand`、没有对 `RailroaderRV` 其他命名空间（`Constants` 除外）的访问；模块级隐藏状态只有 `SIZE`、`integer`、`FIRST_MIN_X`、`FIRST_MIN_Y`、`FIRST_Z`（L20-L24）与 `Slots` 表本身，没有缓存表、没有跨调用可变状态（`findFirstFree` 的 `occupied`/`validated` 都是每次调用新建的局部表）。
3. **其他模块直接读取本模块的常量/表数据（文件:行）**：
   - `RegionSlots.COUNT` → `RV_UtilityContextMenu.lua:75`。
   - `RegionSlots.COLUMNS` → `RV_RailroaderServer_Mapping.lua:56`。
   - `RegionSlots.ROWS` → `RV_RailroaderServer_Mapping.lua:57`。
   - `RegionSlots.REGION_SIZE` → 无外部读者（0 处）。
   - 判断：**不应改为接口**。`ROWS`/`COLUMNS`/`COUNT` 是稳定布局契约，调用方直接读比新增只返回同值的 getter 更清楚；且这三个字段本身就是 `RV_Constants` 字段的转发快照（L15-L17），加 getter 会形成「常量 → 快照字段 → getter」三级转发而没有新增任何保证。唯一值得记录的是 `REGION_SIZE`：它被发布但无人读，属**保留理由**（它是对外声明的槽位边长，删除会削弱「本模块拥有槽位几何」这一合同的可读性；且 `Slots.REGION_SIZE` 与 `Constants.RV_REGION_SIZE` 的一致性由 L26-L28 断言保证）。
   - 本模块**没有**被任何外部模块改写：全树没有对 `RegionSlots.*` 或 `Slots.*` 的赋值（除本文件 L15-L18 的初始化）。

### 接口边界问题

- **`RV_UtilityPowerDevices.interior` 直接读 `record.anchor`，绕过了本模块的正确入口（源码事实 + 条件性推断，本轮重点核查项）**：
  - **本模块提供的正确入口**是 `Slots.indexToAnchor(index)`（L103）与 `Slots.indexToRegion(index)`（L109）—— 锚点是 `slotIndex` 的纯函数（L58-L65），槽位分配才是唯一持久化坐标事实。
  - **被读的数据不存在（源码事实）**：`RV_UtilityPowerDevices.lua:234`-L239 的 `interior(record)` 取 `record.anchor`；但持久化 mapping 记录按设计只含 `generated`/`locoId`/`generation`/`slotIndex`/`rvPosition`/`locoPosition`/`players`：`RV_RailroaderServer_EntryExit.lua:504`-L513 的注释与赋值逐项列出，而且**全树没有任何 `record.anchor =` 或 `candidateRecord.anchor =` 赋值**（本次检索 `anchor\s*=` 的 28 处命中里，写入 mapping 记录的 0 处；`anchor` 字段只出现在 `RV_Layout.lua:312`（layout 值对象）、`RV_ServerSchema.lua:40`（bounds 值对象）、`RV_Server_RecordValidation.lua:51`（manifest 视图）、`RV_Server_GenerationFlow.lua:405`（内存 generation transaction 的 `prepared` 记录））。`RV_Server_RecordValidation.lua:29`-L34 的注释把这条设计写得更直白：读取方应当「rebuild them instead of reading a persisted geometry copy」。
  - **实际传入的 record 类型（源码事实）**：两个调用点都传持久化 mapping 记录 —— `RV_UtilityServer.lua:227` 传 `context.record`，来自 `Adapter.resolveCurrentUtilityRV`（`RV_RailroaderServer_EntryExit.lua:50`）的 L103-L108，其 `record` 是 `recordAtPlayerCoordinate(map, player)` 从 `map.locomotives` 取出的持久化记录；`RV_UtilityServer.lua:314` 传 `mappingRecord`，来自 `adapter.currentUtilityRecord`（`RV_RailroaderServer_EntryExit.lua:111`-L119），同样是 `map.locomotives` 里的持久化记录。
  - **条件性推断（未做运行时验证）**：在上述两条路径上 `record.anchor` 恒为 nil，`interior` 会在 L236-L239 直接返回 nil，于是 `M.scanAll`（L262-L264）返回 `false, "RV interior coordinates are invalid"`，`M.scanTick`（L274-L276）返回 false。也就是说 `OP_REFRESH_DEVICES` 与周期设备扫描很可能从未真正枚举过 RV 内部方块。静态分析无法排除存在某条未在本次检索中命中的调用路径把「带 anchor 的表」（如 `RV_Server_GenerationFlow.lua:405` 的 `prepared`）传进来，但本次全树检索 `scanAll|scanTick` 只命中 `RV_UtilityServer.lua:227`/L314 两个调用点。
  - **差异性质**：这是「读取方绕过了本模块入口并读了一个不存在的持久化字段」，不是本模块的接口缺陷。修复方向只有两类：调用方改走 `RegionSlots.indexToAnchor(integer(record.slotIndex))`（与 `RV_UtilityWater_Objects.lua:37`-L39、`RV_Server_RecordValidation.lua:39`-L41 完全一致），或让调用方接收 manifest 视图（`RV_Server_RecordValidation.manifestViewForRecord` L35-L61，其 `anchor` 由 L41 推导）。**该文件属 server/Power，不在本报告的事务边界内，本报告只登记证据，不改动任何源码。**

- **`RV_UtilityCatalog.lua:8` 导入本模块但不再使用（源码事实）**：`RV_UtilityCatalog.lua` L8 `local RegionSlots = require "RailroaderRV/RVMapping/RV_RegionSlots"`，全文再无第二次引用（只有 L17 的注释提到 `RegionSlots.indexToAnchor`）。因此这是一个**死 import**，但带两个真实副作用：(1) 加载顺序耦合 —— shared Water Catalog 会强制先加载 RegionSlots，从而触发 L26-L28 的 `SIZE == 100` 断言；(2) 语义漂移 —— 注释仍然宣称锚点由本模块推导，而代码里已经没有调用。判断：**建议由该文件的所有者确认是否删除 import**（本报告不修改源码）；若删除，需要确认 RegionSlots 的加载期断言仍有其他 shared 加载路径覆盖（当前 shared 内只有它和 `RV_RegionSlots` 自己 require 该断言所在的模块）。
- **旧报告记录的消费方已全部失效，需要按本次结果重读**：旧 `shared-RVMapping.md` 列出的调用点中，`RV_UtilityCatalog.lua:7/L66`（现为 L8 且无调用）、`RV_UtilityContextMenu.lua:8/L75-L77`（仍在，一致）、`RV_Construction.lua:9/L37/L39`（**该文件当前不导入本模块**）、`RV_RailroaderServer_Mapping.lua:8/L128-L129/L547/L550/L560/L572`（文件已改，实际为 L7/L56-L57/L123/L254/L257/L276）、`RV_RailroaderServer_EntryExit.lua:4/L535-L538`（实际为 L4/L458）、`RV_ServerSchema.lua:18/L381-L385`（实际为 L8/L62）、`RV_DevSaveSchemaGate.lua:18/L54/L337-L344/L842-L844/L1046/L1063`（**该文件已不在文件树内**）、`RV_UtilityWater_Objects.lua:5/L49-L55`（实际为 L5/L38-L39）、`RV_UtilityWater_Ledger.lua:5/L35-L37`（**该文件当前不导入本模块**）、`RV_UtilityStore.lua:5`（**该文件当前不导入本模块**，其第 5 行是 require `RV_UtilityPowerConfig`）。即旧报告 10 个消费方里 4 个已完全失效（2 个文件不导入、1 个文件已删除、1 个 import 空转），行号几乎全部漂移。
- **`indexForAnchor` 的消费面很窄**：唯一外部调用点 `RV_ServerSchema.lua:62` 传入的是**新建的临时表** `{ x = targetX, y = targetY, z = targetZ }`，不是任何持久化对象；而本函数的输入要求「恰好落在某个槽位中心且 z == TELEPORT_Z」。当前没有第二个调用者，也没有任何模块用它做反向查询。这不是缺陷（语义不可被 `indexToRegion` 替代，见函数表），但它是本模块 4 个导出里最需要「改动前先确认」的一个。
- **`Slots.COUNT` 的客户端遍历每次都重算 100 个槽位几何**：`RV_UtilityContextMenu.lua:75`-L88 在 `localSlot` 内 `for slotIndex = 1, RegionSlots.COUNT` 循环并对每个槽位调用 `indexToRegion` + `indexToAnchor`（每次返回两张新表）。这是消费方的性能选择，不是本模块的隐藏状态问题（本模块无缓存，也不应有缓存）；登记为事实即可，当前 100 槽规模下无需处理。
- **加载期断言会中断整棵 require 链**：L26-L28 的 `error` 在 `SIZE ~= 100` 时抛出，会让任何 require 本模块的代码（含只要求 Water Catalog 的客户端文件）加载失败。这是刻意的 fail-closed 设计（`Constants.RV_REGION_SIZE` 与槽位矩阵必须一致），但它意味着「改 `RV_Constants.RV_REGION_SIZE` 而不改 `Slots.REGION_SIZE` 检查」这类改动会以模块加载错误的形式暴露，而不是运行期静默错位 —— 判断：保留。

## 函数清单、覆盖和验证记录

- **扫描文件**：`RV_RegionSlots.lua`（155 行）；目录扫描确认 RVMapping/ 只有这 1 个代码文件、无子目录，合计 **155 行**。全树 `.lua` 文件数 65。
- **扫描函数**：对该文件做 `function` 关键字扫描并逐行核对定义：命中 10 条定义，全部是顶层定义；`type(x) ~= "function"` 类比较行 **0 处**；匿名函数表达式 **0 处**（L106 返回的是 `anchorForSlot` 的调用结果，不是闭包；L149 同理）。构成：6 个 `local function`（L30 `slotForIndex`、L38 `indexForSlot`、L47 `boundsForSlot`、L58 `anchorForSlot`、L67 `denseRegionList`、L84 `validatedRegion`）+ 4 个 `Slots` 表方法（L103 `indexToAnchor`、L109 `indexToRegion`、L115 `indexForAnchor`、L128 `findFirstFree`），合计 **10**。不计数项：L15-L18 的常量字段赋值、L21 `local integer = StrictSchema.integer` 绑定、L26-L28 的加载期断言、L155 的 `return Slots`。
- **逐行交叉核对**：逐行编号读取源码全文；条目行号是定义语句起始行，已与机械扫描逐条对齐。导出位置：L155（`return Slots`）；全局发布位置：L10（`RailroaderRV.RegionSlots`）。
- **跨模块调用扫描**：在 `media/lua` 全树按「require 别名 + 全局表」两种绑定方式搜索 `RegionSlots`（28 处命中）、`slotIndex`（37 处命中）、`anchor`、`rvPosition`、`getmetatable`（1 处命中，即本文件 L68），得到本报告第 5 节的消费者清单；同时用同样方式核查被绕过情况，命中 `RV_UtilityPowerDevices.lua:235` 一处。
- **与旧报告的不一致（本次核对）**：旧报告的函数数（15）、局部/导出构成（8 + 7）、行数（193 行）、`exactKeys` 归属、`indexToSlot`/`slotToIndex`/`indexForRegion` 三个导出、10 个消费方中的 4 个、以及「RegionSlots 与共享水务目录各有一份 integer/exactKeys」的重复描述，对当前源码**均已失效**；当前事实见本报告各节。
- **未覆盖项 / 条件性推断**：未穷举矩阵外框公式两个实现点的全部调用行；「`findFirstFree` 第三返回值替换 `regionForAnchor` 的净收益」「新增整体 XY 外框导出的净收益」属条件性推断，未做改造实验；`RV_UtilityPowerDevices.interior` 读 `record.anchor` 的**运行期后果**是条件性推断（依据是字段从不写入 + 两个调用点都传持久化记录），未做运行时验证。未运行游戏或 runtime 测试，本文不宣称运行时行为已验证。
- **修改范围**：仅重写本分析文档；未修改任何 Lua 源码、配置或测试文件，未运行任何测试脚本。
