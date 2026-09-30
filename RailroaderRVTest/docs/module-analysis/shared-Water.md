# shared/RailroaderRV/Water 模块分析

## 假设、范围、成功条件与验证方式

- **假设**：`contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Water/` 下当前 1 个 Lua 文件 `RV_UtilityCatalog.lua` 构成本报告要分析的共享水务模块；服务端 `server/RailroaderRV/Water/`、客户端 GUI、共享 `Common/RV_StrictSchema` 与 `RVMapping/RV_RegionSlots` 只作接口交叉核对，不纳入本文件函数清单。
- **范围**：覆盖该文件的全部函数定义（`local function` 与 `M.foo = function`）与导出常量；只读检索 `media/lua` 全树判断调用点、共享层可依赖边界与跨模块数据访问。唯一写入目标是本报告。
- **成功条件**：每个函数都有精确起始行、参数含义、返回值或副作用、模块语义和必要性判断；给出复用/提取/拆分结论；逐条列出跨模块数据访问与接口边界问题；说明旧报告结论（metatable 拒绝、bitmapVersion/anchor 校验、`SINK_IDENTITY_FIELDS`、私有 invoke 保留）在当前源码中的状态。不修改源码、不运行游戏或测试脚本。
- **验证方式**：目录枚举与行数（shell）；两条独立正则扫描统计函数定义数并逐条对照起始行；逐行编号通读文件；全树检索 `RV_UtilityCatalog`、`WATER_TAG_KEY`、`hasSinkIdentity`、`isCurrentWaterSink`、`readSinkIdentity`、`isWaterPipedDevice`、`hasFluidContainer`、`invoke`、`getmetatable`、`pcall(` 等关键字核对消费者与同类实现；核对官方 Lua 与反编译 Java 中的 `canBeWaterPiped`/`waterPiped` 语义。源码扫描是静态分析，不替代运行时验证。

## 目录职责与清单

本目录只有一份共享只读目录（catalog）：从游戏对象 ModData 读取并校验 RV 水槽身份标签，另外探测设备能力（原生 `waterPiped` 标志、ModData `canBeWaterPiped`、FluidContainer）。文件不注册事件、不写对象、不访问存档，客户端与服务端各自 require 同一份实现。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_UtilityCatalog.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Water/RV_UtilityCatalog.lua) | 8 | 水槽身份标签的解析/形状校验（L20-L64）与设备能力只读探测（L66-L93）；导出 ModData 标签键 `WATER_TAG_KEY`（L18） |
| **总计** | **8** | 3 个局部函数（`tagForObject`、`invoke`、`hasWaterPipedFlag`）+ 5 个模块表方法；匿名函数表达式 0 个 |

计数口径：`local integer = StrictSchema.integer`（L13）、`local C = RailroaderRV.Constants`（L11）是别名/取值赋值，不属于函数定义，不计数。文件没有作为参数或回调传入的匿名函数表达式。

## 逐文件、逐函数分析

### RV_UtilityCatalog.lua

模块在 [RV_UtilityCatalog.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Water/RV_UtilityCatalog.lua)。加载时 `require "RailroaderRV/Common/RV_Constants"`（L6）取全局 `RailroaderRV.Constants`（L10-L11），`require "RailroaderRV/Common/RV_StrictSchema"`（L7）取严格整数（L13），并 `require "RailroaderRV/RVMapping/RV_RegionSlots"`（L8，见接口边界问题 3：当前未使用）。全部 8 个函数只读对象状态，不存在写入型副作用；文件不导出内部状态，只导出 `M.WATER_TAG_KEY` 与 5 个查询函数。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| tagForObject（L20，私有） | object 游戏对象；先要求 `type(object.getModData) == "function"`，再 `pcall(object.getModData, object)` 取 ModData（L21-L23），读取 `data[M.WATER_TAG_KEY]`；要求 tag 是 table、`owner == C.MOD_ID`、`role == "sink"`、`rvId` 是非空 string、`StrictSchema.integer(generation)` 通过且 `>= 1`、`slotIndex` 是整数（L25-L30）；通过返回 **对象 ModData 内的 tag 原表引用**（非副本），否则 nil。只读。本模块语义：身份标签的唯一解析与形状判定。 | **必须**：所有身份判断都必须经过同一套字段规则；它是本文件其余身份 API 的基础，避免各自为政。注意它不再校验 bitmapVersion，也不再校验 anchor（旧报告结论已过时）。 |
| M.readSinkIdentity（L35） | object；`tagForObject` 通过后返回新表 `{rvId, generation, slotIndex}`，否则 nil；无副作用（不返回 tag 引用本身）。 | **必须**：客户端菜单需要 `slotIndex` 与本地计算的 slot 比对（`client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:110-112`）；它是身份快照的唯一读接口。 |
| M.hasSinkIdentity（L45） | object；要求 `type(object.getModData) == "function"`（L46）后 `pcall` 调用（L47），只判断 `data[WATER_TAG_KEY] ~= nil`；返回 boolean。 | **必须**：它有意只判断“标签是否存在”，不判断合法性，使损坏/过期标签不会被当成未标记的普通设备（服务端据此分流，`server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:115-121`）。与 `isCurrentWaterSink` 分工，不能合并。 |
| M.isCurrentWaterSink（L53） | object、可选 identity{rvId,generation}、可选 mappingRecord；tag 无效返回 false（L54-L55）；identity 与 mappingRecord **同时为 nil** 时返回 true（L56，客户端菜单用的宽松模式）；否则要求两者都是 table、`identity.rvId` 非空 string、`integer(identity.generation)` 非 nil（L57-L61），最后只比较 `tostring(tag.rvId) == tostring(identity.rvId)` 且 generation 整数相等（L62-L63）。不写对象。 | **必须**：服务端身份比对入口（Objects L116、L131、L151）与客户端筛选入口（ContextMenu L109）。但 `mappingRecord` 仅参与类型检查、`slotIndex` 从未比较，函数名与形参承诺强于实现，见接口边界问题 1。 |
| invoke（L66，私有） | target 对象、method 方法名、可变参数；`target == nil` 或 `type(target[method]) ~= "function"` 返回 `false`（L67），否则 `pcall(target[method], target, ...)` 返回 `ok,result`（L68-L69）。 | **保留理由**：共享层不能依赖 `media/lua/server` 下的 `Util.invoke`（`Common/RV_Common.invoke` 才是其实现），因此本文件需要自己的安全调用器；它只在能力探测（L73-L79、L86、L91）使用，抽取到新的共享公共模块需要新增/约定模块与错误形状，收益低于成本。同一模式在共享层已有第二份实现（`Common/RV_UtilitySprite.lua:13-20`），见复用一节。 |
| hasWaterPipedFlag（L72，私有） | object；`getSprite` → `getProperties` → `rawget(_G,"IsoFlagType").waterPiped` → `properties:has(flag)`（L73-L79）；任一步不可用或 `waterPiped == nil` 返回 false，只有结果严格 `true` 才返回 true（L80）。 | **必须**：原生 sprite 标志是设备能力的第一判据；全局 `IsoFlagType` 用 `rawget` 保护，缺失时按“不支持”处理（fail-closed）。 |
| M.isWaterPipedDevice（L83） | object；`object == nil` 直接 false；先 `hasWaterPipedFlag`，否则读 ModData `canBeWaterPiped == true`（L86-L87）；返回 boolean。 | **必须**：服务端用它判定无标签候选设备（Objects L119），客户端用它决定菜单是否可用（ContextMenu L115）；两种能力来源（原生标志 / 模组与官方共用的 ModData 键）必须合并判断。 |
| M.hasFluidContainer（L90） | object；`invoke(object,"getFluidContainer")` 成功且返回值非 nil 时 true。只读，不检查容器内容。 | **必须**：`resolveSink` 的水设备前置条件（Objects L108）与客户端候选筛选（ContextMenu L96）都依赖它；语义窄是刻意设计（不判断水量/流体类型）。 |

**导出常量**：`M.WATER_TAG_KEY = "RailroaderRVTestWater"`（L18）。它是服务端写入（Objects L149）与共享读取（L24、L48）之间的唯一键约定，必须保持公开。旧报告提到的 `M.SINK_IDENTITY_FIELDS` 在当前源码中**已不存在**。

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **严格整数已复用（源码事实）**：身份字段与 generation 校验使用 `StrictSchema.integer`（L13、L28-L29、L59、L63），即 [RV_StrictSchema.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_StrictSchema.lua:4) 的 L4-L11；该函数只接受有限 Lua number，拒绝字符串数字。旧报告里本文件自带的 `integer` 局部函数已被替换，无需再提取。
- **可提取：共享安全调用器（两份实现，收益明确）**：本文件 `invoke`（L66-L70）与 [RV_UtilitySprite.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_UtilitySprite.lua:13) 的 L13-L25 `invoke`/`callSucceeded` 是同一模式的两份实现，差异是返回形状（本文件只返回首个结果 `false,result`；UtilitySprite 返回 `false,error` 与最多两个结果，并在 `callSucceeded` 中把“首结果为 false”折叠成失败）。建议提取为共享 `Common` 下的安全调用工具（`invoke` + `callSucceeded`），本文件与 UtilitySprite 共同依赖。净收益：一处实现、统一的失败形状；成本：本文件的调用点只用到 `ok,result` 两值，需要选择兼容两者返回值的签名（例如统一返回 `ok, a, b`）。两项都属于只读探测，提取不涉及 server-only 依赖。判：**建议提取，但优先级中等**——它不是当前缺陷，只是重复。
- **可提取/可补齐：直接共享的安全调用器应保护属性读取**：本文件 L67 与 UtilitySprite L15 都在 `pcall` 之外读取 `target[method]`，而服务端 [RV_Common.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_Common.lua:7) 的 L7-L15 连属性读取一起保护。若做上一条提取，应顺便把属性读取放进 `pcall`；否则至少在本文件内改。收益：消除“Java proxy 属性读取抛错”穿透到引擎事件回调的风险（条件性影响见接口边界问题 2）。
- **可提取：plain-table 精确键校验（跨层，非本目录必需）**：本文件已不再有 `exactKeys`（旧报告结论过时），但共享层仍存在同类规则——[RV_RegionSlots.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RVMapping/RV_RegionSlots.lua:67) 的 L67-L82 `denseRegionList` 用 `getmetatable(regions) ~= nil` 拒绝 metatable 并校验键集合；服务端 [RV_UtilityWater_Objects.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:13) 的 L13-L23 则用数组 + 计数相等、不拒绝 metatable；[RV_UtilityServer.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:95) 的 L95-L105 用 allowed-set 校验命令信封。若要统一“精确字段/键集合”语义，应在 `RV_StrictSchema` 增加一个可选的 `exactKeys`（并提供“是否拒绝 metatable”的明确合同），供服务端 hint 与命令信封使用；本共享目录当前没有消费点，因此这项属于跨层机会，不是本模块的提取需求。
- **不建议泛化**：`tagForObject`、`readSinkIdentity`、`hasSinkIdentity`、`isCurrentWaterSink`、`isWaterPipedDevice`、`hasFluidContainer` 都绑定 RV 水槽身份/设备能力语义，脱离当前领域没有复用价值；`hasWaterPipedFlag` 依赖全局 `IsoFlagType` 与 sprite 属性，也不适合做成通用工具。

### 是否进一步拆分

- **不建议拆分本文件（95 行 / 8 函数）**。文件内确有两组职责：身份标签（L20-L64）与设备能力探测（L66-L93）。若拆成 `WaterSinkIdentity` 与 `WaterDeviceCapabilities`，客户端与服务端都要多 require 一个模块，而两者当前消费点高度重叠（同一个 `addWaterOptions` / `resolveSink` 同时用身份与能力，[RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:96) 的 L96-L115、[RV_UtilityWater_Objects.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:108) 的 L108-L121）。拆分收益是文件更短，成本是导航与加载项增加，净收益为负。**当前保持单文件。**
- **拆分触发条件**：出现第二个设备族（例如电力/燃料设备目录）或身份标签需要第二套 schema（例如 anchor 重新纳入标签）时，再按“身份”与“能力”拆；届时共享层已有两个独立消费者，拆分才划算。
- **本目录无需门面文件**：唯一文件即公开合同本身，不需要像 server 侧那样再加一层转发。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **导出面（源码事实）**：`M.WATER_TAG_KEY`（L18）、`M.readSinkIdentity`（L35）、`M.hasSinkIdentity`（L45）、`M.isCurrentWaterSink`（L53）、`M.isWaterPipedDevice`（L83）、`M.hasFluidContainer`（L90）。`tagForObject`、`invoke`、`hasWaterPipedFlag` 是本文件私有，不对外。
- **服务端消费者（源码事实）**：[RV_UtilityWater_Objects.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:108) 使用 `hasFluidContainer`（L108）、`hasSinkIdentity`（L115、L130）、`isCurrentWaterSink`（L116、L131、L151）、`isWaterPipedDevice`（L119）、`WATER_TAG_KEY`（L149）。服务端是本文件唯一的**写入方协作者**：它写标签、同步、再用本模块复验（L142-L153）。
- **客户端消费者（源码事实）**：[RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:96) 使用 `hasFluidContainer`（L96）、`hasSinkIdentity`（L108）、`isCurrentWaterSink(object)`（L109，无 identity/mappingRecord）、`readSinkIdentity`（L110）、`isWaterPipedDevice`（L115）。客户端只用返回值筛选菜单，不做写入。
- **返回值合同**：身份读取失败统一用 `nil`/`false`，没有错误码，也没有服务端 `Util.invoke` 那样的 `(ok, value)` 元组；调用方按布尔或 nil 判定，现状已适配。
- **`isCurrentWaterSink` 的三态合同**（L53-L64）：tag 形状无效 → false；identity 与 mappingRecord 同缺 → true（宽松模式，仅用于客户端筛选）；只缺一个 → false（类型检查不通过）。当前服务端始终传两个参数，客户端始终不传，因此三态都被实际使用。

### 直接读写其他模块的数据

1. **只读游戏对象 API，不写任何对象（源码事实）**：`object.getModData`（L21-L22 的 `type` 检查 + `pcall` 调用；L46-L47 同上）、`getSprite`/`getProperties`/`properties:has`（L73-L79，经私有 `invoke`）、`getFluidContainer`（L91，经 `invoke`）。全文件没有 `rawset`、`transmitModData`、`sendObjectChange` 或 `ModData.*` 调用，也没有 `Events` 注册。
2. **读全局 `IsoFlagType`（L76）**：`rawget(_G,"IsoFlagType")` 后取 `waterPiped`，缺失即按不支持处理。这是读取引擎全局常量表，属正常共享层用法（不依赖 server-only 模块），**不需要接口化**。
3. **RV 内部依赖（源码事实）**：`RV_Constants`（L6、L11、L26 用 `C.MOD_ID`）、`RV_StrictSchema.integer`（L7、L13）、`RV_RegionSlots`（L8，**当前未使用**）。前两者是稳定的共享常量/校验合同，合理；第三条见接口边界问题 3。
4. **没有访问任何其他 RV 模块的内部状态（源码事实）**：本文件不读 Store、不读 `ServerWorld`、不读 utility record；它对“水槽身份”的全部知识来自对象 ModData 与共享常量。服务端把 ledger/record 判定留在 [RV_UtilityWater_Ledger.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Ledger.lua:1) 与 [RV_UtilityStore.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:1)，共享层只做对象侧身份与能力判断，边界清晰。
5. **`tagForObject` 返回 ModData 内 tag 的原表引用（源码事实）**：L32 直接 `return tag`，不是副本。当前所有使用都在文件内（L36、L54），且 `readSinkIdentity` 会把字段复制进新表（L38-L42），`isCurrentWaterSink` 只读字段，因此**当前没有泄漏可变引用给外部**。但它是一个“函数内部约定”：若将来导出该函数或让调用方持有返回值，调用方就能直接改对象 ModData。建议要么保持私有，要么改为返回副本。

### 接口边界问题

1. **`mappingRecord` 是名义参数（源码事实 + 跨模块影响）**：L57 只要求 `type(mappingRecord) == "table"`，此后**从未使用**它，`slotIndex` 也不参与比较（L62-L63 只比 rvId 与 generation）。跨模块后果已在服务端报告列出：[RV_UtilityWater_Objects.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:116) 的 L116、L131、L151 传入 mapping record，但“当前身份”判定实际不含 slot；客户端菜单却要求 `identity.slotIndex == 本地 slotIndex`（[RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:110) 的 L110-L112），两侧对“current”的定义不一致。【条件性推断】只有同 rvId/generation 下 slot 被重新分配、导致标签 slotIndex 陈旧时才会观察到差异（服务端接受、客户端不可见）。建议二选一：把 `slotIndex` 纳入比较，或把函数改名为“标签形状有效且属于当前 rvId/generation”，并在注释中明确 slot 一致性由服务端坐标区域检查承担（[RV_UtilityWater_Objects.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:90) 的 L90-L95 + [RV_RegionSlots.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RVMapping/RV_RegionSlots.lua:47) 的 L47-L56 1:1 slot/区域网格）。
2. **属性读取未受保护（源码事实 + 条件性影响）**：L21、L46、L67 都在 `pcall` 之外读取对象属性（`object.getModData`、`target[method]`），而服务端 [RV_Common.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Common/RV_Common.lua:7) 的 L7-L15 保护了这一步。【条件性推断】若某个 Java proxy 的属性读取抛错：客户端侧 `Menu.onFillWorldObjectContextMenu`（[RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:157) 的 L157-L163）直接注册在引擎事件上且无 pcall（同文件 L201-L204），异常会穿透到引擎事件分发；服务端侧 `UtilityServer.handleCommand` 有 pcall（[RV_Server_Commands.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:306) 的 L306-L307），异常会变成“记录一条 utility command error 且不发送 ack”的失败。两者都未在本轮运行验证。建议把属性读取放进 pcall（本文件三处 + 可选的共享调用器提取）。
3. **`RV_RegionSlots` 是死依赖（源码事实）**：L8 require 了 `RV_RegionSlots`，全文件除注释（L15-L17 说明 anchor 是 `RegionSlots.indexToAnchor(slotIndex)`）外没有任何 `RegionSlots.*` 调用——anchor 校验已从标签 schema 中移除。影响：客户端与服务端加载时都会多加载一份 [RV_RegionSlots.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RVMapping/RV_RegionSlots.lua:1)，且注释仍描述已不存在的校验，容易误导读者。建议删除该 require 并同步注释；若打算恢复 anchor 校验，则应同时把注释与实现补齐。收益：去掉无用加载与语义误导，成本一行。
4. **`WATER_TAG_KEY` 的写入方在服务端，字段规则在共享（源码事实，属刻意分工）**：服务端内联构造 tag（[RV_UtilityWater_Objects.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:142) 的 L142-L149）而形状校验在本文件（L25-L30）。这带来两处字段列表：改字段必须同时改 `tagForObject` 与 `ensureSinkIdentity`。可选改进：在共享层增加纯函数 `buildSinkTag(identity, mappingRecord)`（返回新表，不写对象），服务端继续负责 ModData 写入、`transmitModData` 与后置复验。收益：字段列表单点化，避免漂移；成本：共享层新增一个纯构造函数。当前只有一个写入点，因此不是必须项。
5. **没有隐藏状态（源码事实）**：本文件没有模块级可变表（只有 `M`、`local integer`、`local C`）；不需要为并发/多 RV 场景保存任何缓存。这一点与服务端 Water 目录一致（该目录当前也没有进程内状态）。

## 函数清单、覆盖和验证记录

**函数清单（起始行，本次实际读取）**

| 文件 | 函数（起始行） | 小计 |
|---|---|---:|
| RV_UtilityCatalog.lua | `tagForObject`（L20，local）、`M.readSinkIdentity`（L35）、`M.hasSinkIdentity`（L45）、`M.isCurrentWaterSink`（L53）、`invoke`（L66，local）、`hasWaterPipedFlag`（L72，local）、`M.isWaterPipedDevice`（L83）、`M.hasFluidContainer`（L90） | 8 |
| **合计** | 8 个函数定义；匿名函数表达式 0 个 | **8** |

**覆盖**：上表 8 个函数全部在逐函数表中给出参数、返回/副作用、模块语义与必要性判断；导出常量 `M.WATER_TAG_KEY`（L18）单独说明。`local integer = StrictSchema.integer`（L13）与 `local C = RailroaderRV.Constants`（L11）是别名/取值赋值，按计数口径不计入函数定义。

**验证记录（本次实际执行的静态检索）**

- 目录与行数：`shared/RailroaderRV/Water/` 仅 1 个 Lua 文件 `RV_UtilityCatalog.lua`，95 行（shell `Get-Content` 计数，与 read 工具报告的总行数一致）。
- 函数定义数：分类扫描（`local function` / `function Name` / `function M:name` / `= function(`）得 3 个 local + 5 个表方法 = 8；只按定义行正则的独立计数扫描同样得 8。扫描列出的其余含 `function` 行都是注释或 `type(x) ~= "function"` 判断，不是定义。
- 调用点检索（全树 `media/lua`）：`RV_UtilityCatalog` 被 [RV_UtilityWater_Objects.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:6)（L6）与 [RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua:6)（L6）require；`WATER_TAG_KEY` 仅在 `RV_UtilityCatalog.lua:24,48`（读）与 `RV_UtilityWater_Objects.lua:149`（写）出现；`readSinkIdentity`、`hasSinkIdentity`、`isCurrentWaterSink`、`isWaterPipedDevice`、`hasFluidContainer` 的调用点全部落在上述两个消费文件中（行号见“公开合同”）。旧报告的 `SINK_IDENTITY_FIELDS`、`validAnchor`、`sameAnchor`、`exactKeys`、bitmapVersion/anchor 校验在当前文件中均 0 命中。
- 共享层同类实现检索：`local function invoke` 在 shared 树中有两处（本文件 L66、[RV_UtilitySprite.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_UtilitySprite.lua:13) 的 L13）；`getmetatable` 精确键校验在 shared 树中命中 [RV_RegionSlots.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/RVMapping/RV_RegionSlots.lua:68) 的 L68；服务端 `exactKeys` 唯一实现在 [RV_UtilityWater_Objects.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:13) 的 L13，[RV_StrictSchema.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_StrictSchema.lua:1) 当前只有 `M.integer`（L4-L11）。
- 官方/反编译交叉核对（用于“能力标记”语义）：[ISPlumbItem.lua](<../../../official lua scripts/shared/TimedActions/ISPlumbItem.lua:31>)、[ClientCommands.lua](<../../../official lua scripts/server/ClientCommands.lua:71>)、[ISMoveableSpriteProps.lua](<../../../official lua scripts/shared/Moveables/ISMoveableSpriteProps.lua:2493>)；[IsoObject.java](<../../../game-decompiled/42.21.0/zombie/iso/IsoObject.java:2638>)（L2638-L2639、L2663-L2666，Java 侧读取 ModData `canBeWaterPiped`）、[ISWorldObjectContextMenuLogic.java](<../../../game-decompiled/42.21.0/zombie/iso/ISWorldObjectContextMenuLogic.java:554>)（L554-L565，原生接水管菜单条件）。这些用于确认本文件读取的能力标记与官方/引擎约定一致。
- **未覆盖项**：未运行游戏、服务器或任何测试脚本；未验证 Java proxy 属性读取在真实对象上是否抛错（接口边界问题 2 的前提）、未验证“陈旧 slot 标签”状态下的客户端/服务端行为差异（接口边界问题 1）、未验证 `IsoFlagType.waterPiped` 与 `canBeWaterPiped` 在各类水槽 sprite 上的实际组合。本报告是静态分析，不替代运行时验证。
