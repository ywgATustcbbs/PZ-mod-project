# shared/RVMapping 模块分析

## 范围、假设与结论摘要

- **分析范围：** `media/lua/shared/RailroaderRV/RVMapping/` 中全部 Lua 文件。该目录扫描到 1 个文件：[`RV_RegionSlots.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RVMapping/RV_RegionSlots.lua#L1)。
- **假设：** 以当前模组 `media/lua` 中的调用关系为准；本报告不推断模组外消费者。坐标与表结构契约按源码及共享常量定义解释。
- **模块职责：** 提供不读写世界状态的 RV 槽位矩阵映射：索引、行列、中心锚点和 100×100 XY 区域之间的转换，并严格验证区域形状与可用性。
- **总体判断：** 文件内功能围绕单一坐标契约组织，当前不需要拆分。`integer` 与 `exactKeys` 和共享水务目录模块中的同名私有函数语义完全重复，值得评估提取为共享的严格验证工具；现有 `Constants.finiteInteger` 接受更宽的输入，不能直接替代。两个公开包装函数 `indexToSlot`、`slotToIndex` 在当前 `media/lua` 中未发现外部调用点。

## 文件与模块初始化

[`RV_RegionSlots.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RVMapping/RV_RegionSlots.lua#L6) 引入 `RV_Constants`，在全局 `RailroaderRV` 表下创建或复用 `RegionSlots`，并将 `ROWS`、`COLUMNS`、`COUNT`、`REGION_SIZE` 发布为模块字段（L6-L21）。槽位从源码注释所称的西南角开始按行优先排序，先递增 X，再递增 Y（L1-L4）。载入时要求区域尺寸恰为 100，否则立即报错（L24-L26）。文件末尾返回 `Slots`（L193），供 `require` 调用方作为模块接口使用。

XY 区域边界采用半开区间：相邻区域仅边缘相接时不算重叠。此约定由分配器的严格重叠比较（L176-L177）和共享常量对 RV 管理区域的说明（[`RV_Constants.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_Constants.lua#L79)、L104-L109）互相印证。锚点是区域中心，Z 使用 `TELEPORT_Z`（本文件 L19-L22、L79-L85）。本模块不访问游戏对象、ModData、存档或网络；运行期函数只校验输入、计算坐标并创建返回表。

## 函数清单与逐函数说明

扫描到 **15 个函数定义**：8 个 `local function` 辅助函数和 7 个 `Slots` 表上的导出函数。所有函数定义均位于文件顶层；未发现赋值式匿名函数、嵌套函数或匿名回调。

### 局部辅助函数

| 函数 / 行号 | 参数 | 返回值与副作用 | 模块语义、必要性 |
|---|---|---|---|
| `integer(value)` / L28-L35 | `value`：预期为 Lua number 的索引或坐标字段。 | 有限整数时返回原数字；类型错误、NaN、正负无穷或小数时返回 `nil`。无副作用。 | 矩阵和几何入口共用严格数值规则；拒绝非规范坐标是必要的。局部封装可替换为等价共享工具，但不能改成接受数值字符串或 Java 包装值的宽松转换。 |
| `exactKeys(value, expected)` / L37-L49 | `value`：待验表；`expected`：必需字段名数组。 | 表必须无 metatable、不能含额外键，键数必须等于字段数；满足时返回 `true`，否则 `false`。只创建局部允许键集合。 | 用于锚点和区域的封闭结构校验，防止额外字段被静默容忍。严格形状校验有必要；此版本不支持可选字段。 |
| `slotForIndex(index)` / L51-L57 | `index`：从 1 开始的槽位序号。 | 合法时返回 `(row, column)`；非法返回 `nil`。无副作用。 | 将稳定索引转换为矩阵坐标，是锚点、区域和正向公开转换的基础。 |
| `indexForSlot(row, column)` / L59-L66 | `row`、`column`：从 1 开始的矩阵行、列。 | 合法时返回行优先索引 `(row - 1) * COLUMNS + column`；非法返回 `nil`。无副作用。 | 是反向矩阵转换，也用于区域与锚点校验；属于核心映射逻辑。 |
| `boundsForSlot(row, column)` / L68-L77 | 已验证的矩阵 `row`、`column`；此私有函数本身不重复验证。 | 返回新表 `{minX, minY, maxX, maxY}`，尺寸为 `SIZE × SIZE`。不更改输入或世界状态。 | 将槽位转成 XY 区域，是多个导出功能的共同几何实现；集中计算可避免公式分叉。 |
| `anchorForSlot(row, column)` / L79-L86 | 已验证的 `row`、`column`。 | 返回新表 `{x, y, z}`：XY 为区域中心，Z 为首层/传送层高度。无副作用。 | 统一定义锚点与槽位的正向映射；`indexToAnchor` 依赖它。 |
| `denseRegionList(regions)` / L88-L103 | `regions`：待分配前占用区域的数组表。 | 合法密集数组时返回长度（空数组返回 0）；稀疏、含非整数/越界/非数字索引或带 metatable 时返回 `nil`。无副作用。 | 为 `findFirstFree` 提供确定的遍历范围，避免对稀疏数组使用 `#`。该输入约束对分配器必要。 |
| `validatedRegion(region)` / L105-L125 | `region`：预期只有四个 XY 边界字段的表。 | 合法时返回 `(slotIndex, normalizedRegionCopy)`；非法返回 `nil`。要求边界为整数、恰好 100×100，并对齐到矩阵槽位；不改变原表。 | 将区域反查为唯一槽位，并生成标准化副本供重叠检测；是 `indexForRegion` 和 `findFirstFree` 的核心领域校验。 |

### 导出函数

| 函数 / 行号 | 参数 | 返回值与副作用 | 模块语义、必要性 |
|---|---|---|---|
| `Slots.indexToSlot(index)` / L127-L129 | `index`：1-based 槽位索引。 | 返回 `slotForIndex` 的 `(row, column)` 或 `nil`；无副作用。 | 提供索引到矩阵位置的公共接口。当前模组内未发现外部调用点，因此不是已观察调用链所需 API；可用于对外/未来对称 API。 |
| `Slots.slotToIndex(row, column)` / L131-L133 | `row`、`column`：1-based 行列。 | 返回 `indexForSlot` 的索引或 `nil`；无副作用。 | 提供行列到索引的公共接口。底层映射功能用于内部校验，但此公开包装函数当前模组内无调用点；保留与否取决于是否承诺公共对称 API。 |
| `Slots.indexToAnchor(index)` / L135-L139 | `index`：槽位索引。 | 返回新锚点表或 `nil`；无副作用。 | 统一给出槽位中心锚点。服务端分配、存档/清单校验和水务模块依赖，属于当前必需接口。 |
| `Slots.indexToRegion(index)` / L141-L145 | `index`：槽位索引。 | 返回新 XY 边界表或 `nil`；无副作用。 | 统一给出槽位 XY 范围。客户端命中检查、服务端区域补全和校验均依赖；返回表不带 Z 边界。 |
| `Slots.indexForAnchor(anchor)` / L147-L159 | `anchor`：恰有 `x/y/z` 三键的锚点表。 | 若坐标准确位于槽位中心且 Z 与 `FIRST_Z` 相同，返回索引；否则返回 `nil`。无副作用。 | 严格逆映射，校验的是锚点而非槽位内任意位置。多个服务端持久化/请求校验路径及共享目录使用，属于当前必需接口。 |
| `Slots.indexForRegion(region)` / L161-L164 | `region`：恰有 `minX/minY/maxX/maxY` 的 XY 区域表。 | 返回所属槽位索引或 `nil`；无副作用。 | 把规范化区域反查到槽位。EntryExit 和开发存档 schema 校验使用；调用方需另行校验自己的 Z schema。 |
| `Slots.findFirstFree(regions)` / L166-L191 | `regions`：当前占用区域的密集数组。 | 成功返回 `(index, anchor, region)`；错误返回 `(nil, reason)`，原因包括 `invalid-region-list`、`invalid-region`、`overlapping-regions`、`no-free-slot`。只建局部集合和返回表，不改变传入区域。 | 严格校验每个占用项并作两两重叠检查，再按 1..COUNT 返回首个空槽位。服务端分配器依赖此功能。重叠扫描为 O(n²)，当前最大矩阵为 100 槽。 |

## 模块调用关系与内部数据访问

在 `media/lua` 内找到以下直接导入方和调用点：

| 消费模块 | 对 `RegionSlots` 的直接读取/调用 | 用途 |
|---|---|---|
| [`RV_UtilityCatalog.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Water/RV_UtilityCatalog.lua#L7) | L7 导入；L66 调用 `indexToAnchor`。 | 校验水槽身份标签中的锚点是否与槽位对应。 |
| [`RV_UtilityContextMenu.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua#L8) | L8 导入；L75 读 `COUNT`，L76-L77 调用 `indexToRegion`、`indexToAnchor`。 | 遍历槽位并判断玩家和目标水务对象是否位于同一受管区域（L67-L89）。 |
| [`RV_Construction.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Construction/RV_Construction.lua#L9) | L9 导入；L37 读 `COUNT`，L39 调用 `indexForAnchor`。 | 验证 manifest 的槽位索引与锚点一致。 |
| [`RV_RailroaderServer_Mapping.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Mapping.lua#L8) | L8 导入并在 L31 传给 schema gate；L128-L129 读 `COLUMNS/ROWS`；L547、L550、L560、L572 调用 `COUNT`、`indexForAnchor`、`indexToRegion`、`findFirstFree`。 | 构造矩阵范围、核验已有记录并分配槽位。 |
| [`RV_RailroaderServer_EntryExit.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua#L4) | L4 导入；L535-L538 调用 `indexForAnchor`、`indexForRegion`。 | 提交 mapping 前核对候选锚点、区域和槽位。 |
| [`RV_ServerSchema.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_ServerSchema.lua#L18) | L18 导入；L381-L385 调用 `indexForAnchor`。 | 从服务端 relocation 目标位置确认其属于合法槽位。 |
| [`RV_DevSaveSchemaGate.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_DevSaveSchemaGate.lua#L18) | L18 导入并注入依赖（L54）；L337-L344 验证 count、anchor、region；L842-L844 再核验 manifest；L1046、L1063 生成期望锚点/区域。 | 对 mapping、manifest 和水务数据执行开发存档 schema 校验。 |
| [`RV_UtilityWater_Objects.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua#L5) | L5 导入；L49-L55 调用 `indexToAnchor`、`indexToRegion`、`indexForAnchor`。 | 验证水务记录中的身份锚点并取得所属区域。 |
| [`RV_UtilityWater_Ledger.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Ledger.lua#L5) | L5 导入；L35-L37 调用 `indexToAnchor`、`indexForAnchor`。 | 核对账本记录与 mapping 的槽位、锚点一致。 |
| [`RV_UtilityStore.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua#L5) | L5 导入；搜索该文件的 `RegionSlots` 只有导入行，没有其他读取或调用。 | 当前看是未使用导入；不能据此认定有接口依赖。 |

没有发现调用方读取本文件的局部变量或局部辅助函数。它们通过 `require` 取得返回表，并读取导出的常量或调用导出函数。`RV_RegionSlots` 自己直接读取 `RV_Constants` 的公开字段 `RV_REGION_SLOT_ROWS`、`RV_REGION_SLOT_COLUMNS`、`RV_REGION_SLOT_COUNT`、`RV_REGION_SIZE`、`TELEPORT_X/Y/Z`、`RV_REGION_MIN_OFFSET_X/Y`（本文件 L6-L22）；未访问 Constants 的私有数据。

## 通用性、提取建议与模块拆分

1. **评估抽取严格整数和精确字段校验。** 本文件 `integer`（L28-L35）与共享水务目录 `integer`（[`RV_UtilityCatalog.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Water/RV_UtilityCatalog.lua#L18)、L18-L25）逐项一致；`exactKeys`（L37-L49 与水务目录 L27-L37）也都拒绝 metatable、额外字段并要求精确字段数。两模块都在 `shared` 且依赖 `RV_Constants`，适合评估提供 `strictInteger`、`exactKeys` 等共享 helper，减少校验规则漂移。
2. **不能直接用已有 `Constants.finiteInteger` 替换。** [`RV_Constants.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_Constants.lua#L13) L13-L37 的 `finiteNumber`/`finiteInteger` 接受数字字符串及可通过受保护算术转换的 Java 数值包装；本模块要求原始 Lua number。若提取，应新增明确的严格语义，而不是改变接受范围。
3. **密集数组和区域校验不宜泛化。** [`RV_RoomTemplate.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_RoomTemplate.lua#L54) L54-L85 也有 `exactKeys` 和 dense-list 校验，但支持可选键、没有本模块的槽位上限/对齐约束，输入用途不同。`validatedRegion`、`boundsForSlot`、`anchorForSlot`、`findFirstFree` 绑定 5×20 矩阵、100×100 尺寸及锚点中心规则，应留在 RVMapping。
4. **矩阵整体 XY 外框公式有两个相近实现，可考虑集中 XY 部分。** [`RV_BoundaryServer_Geometry.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Geometry.lua#L109) L109-L117 根据传送坐标、偏移、尺寸和行列数计算全矩阵 XY 范围；[`RV_RailroaderServer_Mapping.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Mapping.lua#L114) L114-L129 的 `rvRegion` 也计算同一 XY 外框并增加 mapping identity 的 Z 范围。若要降低几何漂移，可让 RegionSlots 提供仅含 XY 的整体范围，两个服务端模块各自补充 Z 契约。当前只有两个实现点，若新增 API 会引入额外耦合，收益不明显时保留现状合理。
5. **分配器的第三个返回值未被当前分配调用点使用。** `findFirstFree` 在本文件 L187 返回规范 XY 区域；[`RV_RailroaderServer_Mapping.lua`](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Mapping.lua#L572) L572 只接收索引和锚点，L576 再通过 `regionForAnchor` 计算区域并补齐 Z。可评估接收该 XY 返回值后添加 mapping 所需 Z，减少一处 XY 重算；同一 `regionForAnchor` 在 L514 还用于已有记录，需独立处理。
6. **不建议拆分本文件。** 文件 193 行、15 个函数，均围绕单一矩阵坐标契约；验证、正逆映射、几何生成、空槽分配通过窄接口相互依赖。拆成多个文件会增加加载和跨文件契约，没有新的副作用或变更边界可隔离。
7. **公开维度字段不需要 getter 包装。** `COUNT`、`ROWS`、`COLUMNS` 是稳定布局契约；调用方直接读取比新增只返回相同值的函数更清楚。`REGION_SIZE` 当前仅在本模块初始化时被复制到局部 `SIZE`，本模组内未找到外部读取点。`indexToSlot`、`slotToIndex` 也没有当前模组调用点；若不承诺对外稳定 API，可在后续清理中评估保留价值。
8. **未使用导入值得由其所有者确认。** `RV_UtilityStore.lua:L5` 仅导入 RegionSlots；若该 `require` 不承担加载副作用，可移除。此处报告只记录证据，不修改该文件。

## 扫描和文档验证

- 源目录递归清单：1 个 Lua 文件，即 `RV_RegionSlots.lua`。
- 函数扫描命令 `rg -n '\bfunction\b|\bfunction\s*\('` 返回 15 个定义；再按源文件 L1-L193 逐行交叉核查：8 个局部函数、7 个导出表函数，没有匿名、赋值式、嵌套或回调函数遗漏。
- 对 `media/lua` 执行 `rg -n` 搜索 `RegionSlots` 和导出函数名，核对导入方、公开字段读取、函数调用位置，并搜索全局表写入；具体调用证据列于上表。
- 只读静态分析；按任务范围未运行 runtime 测试。
- 未解决项：当前模组调用图不能判断模组外消费者是否使用 `indexToSlot`、`slotToIndex` 或 `REGION_SIZE`；共享严格整数/键校验是否提取需结合其他共享模块的维护计划决定。

## 第二阶段 strict-schema 更新

原本与共享 Water Catalog 同合同的 `integer` 和 `exactKeys` 已迁到 `shared/Common/RV_StrictSchema.lua`，本模块继续保留 RegionSlots 的槽位、区域与锚点规则。StrictSchema 不包含 dense-array/optional schema 或区域 policy。见[第二阶段报告](phase2-structure-optimization.md)。
