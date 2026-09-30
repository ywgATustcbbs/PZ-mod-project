# `shared/RailroaderRV/Water` 模块分析

## 范围、假设与验收方式

- 范围是 `contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Water/` 下的全部代码文件。本次枚举到 1 个 Lua 文件：`RV_UtilityCatalog.lua`。
- “模块”按该目录的 Lua 文件划分；函数职责与参数含义依据源码和项目内调用点判断。游戏 API 的运行时行为没有在本报告中验证。
- 成功条件：列出目录内每个代码文件；逐个说明其中全部函数（含局部函数）的参数、返回值/副作用、本模块语义和必要性；给出跨模块复用、拆分和数据访问判断及源码位置。
- 只读核验：递归枚举目录文件；带行号通读 `RV_UtilityCatalog.lua`；用 `rg -n '\bfunction\b'` 核对函数声明；用 `rg` 搜索导出函数、常量和标签键的项目内调用点。没有修改 Lua 源码，也没有运行测试。

## 文件与模块职责

### `RV_UtilityCatalog.lua`

路径：`contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Water/RV_UtilityCatalog.lua`

它是客户端与服务端共用的水槽/水设备只读目录。文件分成两类职责：

1. **水槽身份检查**：从对象 ModData 读取身份标签，按当前字段集合、模组 ID、角色、RV 身份、generation、bitmap 版本、slot 与锚点严格校验；对外返回复制后的身份或当前性判断。主要位置为第 13–106 行。
2. **设备能力检查**：检查对象是否有原生 `waterPiped` 标志、ModData 中的 `canBeWaterPiped` 声明，或可用的 FluidContainer。主要位置为第 108–135 行。

文件只读取对象状态，不注册事件、不写存档、不修改世界对象。它依赖共享常量 `RV_Constants`（第 6、10 行）和 `RV_RegionSlots.indexToAnchor`（第 7、66 行），用于确认身份归属、当前 bitmap 版本以及 slot 对应锚点。

## 函数清单与职责

源码共核对到 **12 个函数声明**；其中 7 个是局部函数，5 个挂在模块表 `M` 上。文件没有匿名函数或回调函数。下面的“必要”指当前模块职责中是否需要该判断/转换，不表示只能采用当前函数写法。

| 函数与位置 | 输入参数 | 输出与副作用 | 本模块语义、必要性 |
|---|---|---|---|
| `integer(value)`，第 18–25 行 | 任意 Lua 值 | 有限整数时返回原数值，否则返回 `nil`；无副作用。 | 身份字段和坐标的基础校验，拒绝非数字、NaN、正负无穷和小数。当前严格标签校验必需。 |
| `exactKeys(value, keys)`，第 27–37 行 | 待校验值；允许的键数组 | 返回布尔值；无副作用。 | 要求输入是无 metatable 的 table，且键集合与 `keys` 完全相同，拒绝缺字段或额外字段。对开发期身份 schema 的 fail-closed 校验必需。 |
| `validAnchor(anchor)`，第 39–46 行 | 锚点 table | 当且仅当它恰有 `x/y/z` 三个有限整数时返回 `true`。 | 约束持久身份中锚点的形状和坐标类型，是比较身份锚点前的必要前置校验。 |
| `sameAnchor(a, b)`，第 48–51 行 | 两个锚点 | 两者都有效且三坐标相等时返回 `true`；无副作用。 | 用于确认标签锚点与 slot 映射锚点一致，避免仅凭 slot 或客户端数据接受对象。 |
| `tagForObject(object)`，第 53–69 行 | 游戏对象 | 合法且属于当前 schema 的标签 table；对象无效、读取失败或标签不合格时返回 `nil`。调用 `getModData` 时用 `pcall`；不写数据。 | 身份标签的唯一解析与完整校验路径：要求 `owner == C.MOD_ID`、`role == "sink"`、非空 `rvId`、正整数 generation、当前 bitmap 版本、整数 slot，并验证 slot 映射出的锚点。其余身份 API 复用它，防止各自采用不同判定规则。 |
| `M.readSinkIdentity(object)`，第 71–81 行 | 游戏对象 | 无有效标签时返回 `nil`；否则返回含 `rvId/generation/bitmapVersion/slotIndex/anchor` 的新 table。无对象写入。 | 向调用者提供身份快照；锚点也被复制，避免调用者通过返回值修改对象 ModData 中的标签。供服务端验证/命令流程读取，必需。 |
| `M.hasSinkIdentity(object)`，第 83–87 行 | 游戏对象 | 若成功读取 ModData 且指定键的值非 `nil`，返回 `true`；否则 `false`。读取受 `pcall` 保护，无写入。 | 有意只判断“标签是否存在”，不判断标签是否合法。这样损坏或过期标签不会被误认为未标记的普通设备并走外部设备路径；与 `isCurrentWaterSink` 分工，必需。 |
| `M.isCurrentWaterSink(object, identity, mappingRecord)`，第 91–106 行 | 对象；可选的 `identity`（期望的 `rvId/generation/bitmapVersion`）；可选的 `mappingRecord`（期望的 `slotIndex/anchor`） | 返回布尔值；不修改对象。两项参数都省略时，只判断对象是否带有有效当前 schema 标签；只提供其中一项时返回 `false`。 | 先由 `tagForObject` 校验对象标签。服务端传入两项时再比较调用上下文身份和映射记录；客户端上下文菜单可按注释省略两项，只筛掉无效标签。是当前身份判定的核心接口。 |
| `invoke(target, method, ...)`，第 108–112 行 | 目标对象、方法名、转发给目标方法的任意参数 | 目标/方法不可用时返回 `false`；否则通过 `pcall` 调用并返回 `(ok, result)`，调用报错时第二项为错误值。无其他副作用。 | 统一本文件对 Java/Lua 对象方法的调用结果形状，供能力探测使用。当前跨 API 边界的容错有用；但它没有用 `pcall` 保护 `target[method]` 取值，安全范围有限。 |
| `hasWaterPipedFlag(object)`，第 114–123 行 | 游戏对象 | 只有 `getSprite`、`getProperties`、全局 `IsoFlagType.waterPiped` 和 `properties:has(...)` 均可用且最终结果严格为 `true` 时返回 `true`；否则返回 `false`。只读。 | 判断对象 sprite 是否具有原生水管能力标志，是原生设备探测路径的必要部分。 |
| `M.isWaterPipedDevice(object)`，第 125–130 行 | 游戏对象 | 返回布尔值；依次读取 sprite 标志，失败时再读取 ModData 的 `canBeWaterPiped == true`；无写入。 | 合并原生标志与模组自声明能力，供客户端筛选连接选项和服务端验证普通设备能力。 |
| `M.hasFluidContainer(object)`，第 132–135 行 | 游戏对象 | `getFluidContainer` 调用成功且返回非 `nil` 时为 `true`，否则为 `false`；无写入。 | 只判断 FluidContainer 是否可用，不检查容器内容；用于筛选水设备候选对象，职责简单且被客户端、服务端共用。 |

模块还导出 `M.WATER_TAG_KEY`（第 16 行）作为对象 ModData 的身份标签键，以及 `M.SINK_IDENTITY_FIELDS`（第 13–15 行）作为标签字段白名单。后者目前仅在本文件第 58 行使用，项目内没有其他代码读取它。

## 调用关系与跨模块复用

### 项目内调用点

- 客户端 `RV_UtilityContextMenu.lua` 第 96、108–115 行调用 `hasFluidContainer`、`hasSinkIdentity`、无附加参数的 `isCurrentWaterSink`、`readSinkIdentity` 和 `isWaterPipedDevice`，只用于菜单候选筛选。
- 服务端 `RV_UtilityWater_Objects.lua` 第 122、129–134、147–189 行用目录查询对象能力和身份，并在写入后重新验证标签。
- 服务端 `RV_UtilityWater_Commands.lua` 第 120、176–186 行用目录确认移除对象的身份仍与待处理记录一致。
- 除服务端对象管理模块使用导出的 `WATER_TAG_KEY` 外，调用方通过目录函数访问判断结果。项目内没有其他模块读取 `SINK_IDENTITY_FIELDS`（以 `rg` 搜索结果核对）。

### 可复用函数候选

| 候选 | 相似实现与差异 | 建议 |
|---|---|---|
| `integer`（第 18–25 行） | `RV_RegionSlots.lua` 第 28–35 行的有限整数检查语义相同。`RV_Bitmap.lua` 第 37–41 行、`RV_TemplateGeometry.lua` 第 28–30 行以及服务端 `RV_UtilityWater_Objects.lua` 第 24–33 行也有同类检查，但有的依赖本地 `finiteNumber`，返回值表达不同。 | 适合作为通用候选；若抽取，应统一有限整数输入/失败的契约，再逐调用点替换。当前只有数行且模块无共同依赖时，单独抽取收益有限。 |
| `exactKeys`（第 27–37 行） | 与 `RV_RegionSlots.lua` 第 37–48 行完全同类：只接受无 metatable 且键集合完全相等的 table。`RV_Bitmap.lua` 第 43–54 行及服务端 `RV_UtilityWater_Objects.lua` 第 12–22 行不拒绝 metatable，因此语义不完全一致。 | 可以抽取“plain table + 精确键集合”版本给同契约调用者使用；不可直接用 `RV_Bitmap.hasExactKeys` 替换本函数，否则会放宽校验。宜先明确 schema 校验契约。 |
| `invoke`（第 108–112 行） | 服务端 `RV_ServerUtil.invoke` 从 `RV_Common.invoke` 复用实现；`RV_Common.invoke` 第 7–15 行还保护方法属性读取，并保留多个返回值。客户端/共享目录不能依赖 `media/lua/server` 下的实现。 | 可考虑放进客户端与服务端都能加载的共享安全调用工具，但需明确对属性访问异常和多返回值的处理契约。当前 Water 版本只使用首个返回值，且很短，未达到必须抽取的程度。 |
| `validAnchor` / `sameAnchor` | `RV_TemplateGeometry.lua` 第 38–46 行也有锚点校验，但其规则聚焦区域锚点位置，且接受额外字段；不是可直接互换的严格 schema 检查。 | 保持身份模块私有更清晰。若未来需要复用，提取坐标结构校验和区域合法性校验时应分开定义。 |

`tagForObject`、`isCurrentWaterSink`、`isWaterPipedDevice` 是水身份或设备能力的领域判断，不适合作为无上下文的通用 helper。通用校验函数可作为全项目候选，但本模块没有必要单独引入新的工具模块来减少少量代码。

## 是否需要拆分

身份标签读取/比对与设备能力探测是两组职责，因此理论上可拆成 `WaterSinkIdentity` 和 `WaterDeviceCapabilities`。当前目录只有这一份 137 行源码，两个消费端都需要同一目录接口；拆分会增加 require 边界和文件导航成本，没有明确收益。**目前不建议继续拆分。** 若能力探测增长出设备注册表或不同设备适配器，再按职责拆分会更合适。

## 模块内部数据访问与接口收益

- 当前目录没有其他 Lua 文件直接读取本模块的局部变量或修改模块内部表。`SINK_IDENTITY_FIELDS` 虽通过 `M` 导出，但项目内无外部调用；它可以收为局部常量以缩小公开面，收益主要是接口整洁，不影响现有调用。
- 服务端 `RV_UtilityWater_Objects.lua` 第 154–171、176–189 行通过 `object:getModData()` 直接检查、创建和删除 `Catalog.WATER_TAG_KEY` 下的标签；第 161–170 行重复描述标签字段。客户端菜单和服务端命令没有这样访问 ModData，它们使用目录函数。
- `WATER_TAG_KEY` 是有意公开的稳定键常量，服务器对象模块需要围绕它执行 ModData 写入、同步和回滚。把这些副作用移入共享目录会混合客户端可加载的只读查询与服务器事务，接口收益低于保留服务端写入归属。
- 如果要减少标签 schema 的重复，可以由目录提供纯函数构造当前标签（输入身份与映射记录，返回新标签），由服务端继续负责 ModData 写入、`transmitModData` 与补偿。这样能降低字段列表漂移风险，但目前只有一个写入点，收益中等而非必须；不建议为此把服务端事务整体封装到共享模块。

## 未覆盖项

本报告是源码静态分析。没有验证游戏运行时 Java 对象方法行为、客户端/服务器实际加载顺序或多人联机效果；这些需要按项目的一键整体运行时流程另行验证。此次只分析 Water 目录，不替代其他目录的模块报告。

## 第二阶段 strict-schema 更新

`RV_UtilityCatalog` 的身份整数与 plain exact-key validation 已复用 `shared/Common/RV_StrictSchema.lua`。共享层 `invoke` 保留本地实现，因为它不能依赖 server-only `Util.invoke`，且只服务于共享 Water 能力读取。服务端 Water Objects/Commands/Plumbing 中仅转发 `Util.invoke` 的 wrapper 已删除；Water 普通 RV identity key 改用 `ServerUtil.identityKey`。见[第二阶段报告](phase2-structure-optimization.md)。
