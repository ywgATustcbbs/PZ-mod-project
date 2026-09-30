# shared/RailroaderRV/Common 模块只读分析

## 假设、范围和完成条件

只读分析 media/lua/shared/RailroaderRV/Common/ 下全部代码文件；跨目录检索仅用于确认这些 Common 模块的调用和数据耦合。以文件夹为模块边界，必要性依据当前共享协议、bitmap schema 和 fail-closed 存档约束判断。完成条件为逐函数列明参数、结果/副作用、语义、必要性，并有复核行号、复用/拆分建议、接口耦合判断、静态证据。只使用文件/函数/依赖检索和逐行检查，不运行运行时测试。未改源代码。

## 目录及函数提取证据

| 文件 | 行数 | 声明函数 |
|---|---:|---:|
| RV_Constants.lua | 179 | 2 |
| RV_Bitmap.lua | 542 | 39 |
| RV_UtilitySprite.lua | 112 | 6 |
| RV_UtilityConstants.lua | 81 | 0 |
| 合计 | 914 | 47 |

全模组有 72 个 Lua 文件。目录文件数：client/RailroaderRV 1、client/GUI 11；server/RailroaderRV 2；server/BoundaryGuard 4、Common 5、Construction 6、Core 10、DemolitionProtection 1、Power 2、RoofRefresh 7、RVMapping 4、TemplateRecovery 1、Water 5；shared/Common 4、Power 2、RoomTemplate 5、RVMapping 1、Water 1。

只读命令：rg --files media/lua -g '*.lua' 得72；rg --files media/lua/shared/RailroaderRV/Common -g '*.lua' 得4；PowerShell [IO.File]::ReadAllLines(...).Length 得上表行数。函数清单用 rg -n 搜索行首 local function/function、name=function、return function，得47条，再逐文件逐行复核。rg -n 搜索 function( 得3处：Constants:23匿名 pcall 算术闭包、Bitmap:31匿名 pcall 算术闭包、Bitmap:293命名 function expression layerBits。两个匿名闭包归到外层转换函数，layerBits 单列。无匿名事件回调；UtilitySprite 直接注册具名 ensureHiddenSprites。

## 1. shared/Common 模块逐函数说明

### RV_Constants.lua：共享常量与数值正规化

数据键按组为网络命令（39–55）、存档 key/schema（56–71）、区域与坐标（75–112）、边界迁移时限（110–122）、模板/cab/wall/roof 偏移（128–141）、sprite/生成器（145–179）。这些公开数据是多端共同合同。

| 函数/行 | 输入和输出 | 副作用、语义、必要性 |
|---|---|---|
| C.finiteNumber（13） | value 可为数、数字字符串、可受保护加法转换的 Java numeric wrapper；输出有限数或 nil。 | 无持久副作用；23行匿名 closure 仅用 pcall 保护 value+0。统一拒绝 NaN/Inf/无效输入，坐标与协议验证核心。 |
| C.finiteInteger（33） | 同类 value；输出整数或 nil。 | 调用 finiteNumber 并判断 floor；无其他副作用。共享 integer 校验核心。 |

### RV_Bitmap.lua：packed bitmap、空间查询、编码

字段结构是公开的 bitmap schema；私有缓存 walkBoundsCache 不供其他模块访问。

| 函数/行 | 参数及返回值 | 语义、副作用和必要性 |
|---|---|---|
| finiteNumber（27） | 数/数字字符串/Java wrapper → 有限数或 nil。 | 31行匿名 pcall closure 保护 wrapper 加法；供本文件内部校验。与 Constants:13 重复。 |
| integer（37） | value → 整数或 nil。 | 纯校验；尺寸、坐标、索引、schema 必需。 |
| exactKeys（43） | table、expected 键数组 → 精确键集合 bool。 | 纯校验；54行导出 Bitmap.hasExactKeys，schema 检查必需。 |
| dimensions（56） | width/height → 规范宽高和 ceil(面积/8)，或 nil；缺失/非整数用默认尺寸，非正整数拒绝。 | 纯计算，位串分配必需。 |
| byteLength（63） | width/height → 字节数或 nil。 | 私有包装，统一位串长度。 |
| bitIndex（68） | width、本地 x/y → 行优先零基 bit index。 | 纯换算，packed bitset 必需。 |
| validIndex（72） | width/height/index → index 是否在整数范围内。 | 防越界读写。 |
| byteAndMask（77） | 零基 index → 一基 byte 序号和 bit mask。 | 位定位必需。 |
| rawGet（83） | bits/index/width/height → bool；无效 false。 | 只读底层位操作。 |
| rawSet（92） | bits/index/enabled/width/height → 新 string；非法输入返回原 string。 | 以替换字节方式更新不可变 string，不改原值；位写必需。 |
| Bitmap.byteLength（105） | width/height → 字节数或 nil。 | 公开给外部校验使用。 |
| Bitmap.newBitset（109） | width/height/fill → 全0/全1 bytes string 或 nil。 | 分配位串；bitmap 初始化必需。 |
| Bitmap.get（118） | bits/index/width/height → bool。 | 只读位接口；缺省尺寸用默认值。 |
| Bitmap.set（124） | bits/index/enabled/width/height → 新 string。 | 仅 enabled==true 置位；不改原串。 |
| Bitmap.index（130） | scope 与世界 x/y → 零基 index、本地 x/y 或 nil。 | 先正规化/下取整坐标并检查范围；世界到 bitmap 索引核心。 |
| Bitmap.cell（142） | scope、世界 x/y → 含 index、本地和世界 x/y 的表或 nil。 | 纯构造，提供坐标映射结果。 |
| Bitmap.containsScope（150） | scope、世界 x/y/z → bool，XY/Z 使用半开范围。 | 纯范围门禁，RV 范围安全核心。 |
| rowContains（165） | walk bits、宽高、y、firstX/lastX → 指定区段是否全为可走位。 | buildWalkBounds 的内部扫描 helper。 |
| buildWalkBounds（176） | bitmap/z → outer 和 inner AABB 或 nil。 | 扫描层 walk bits；结果弱缓存到 walkBoundsCache。outer 快速排空白，inner 是验证过的全可走矩形；高频 boundary query 所需。 |
| Bitmap.prepareWalkBounds（227） | bitmap → bool。 | 预扫 minZ 到 maxZ 的 bounds，写进进程缓存、不改 schema；避免第一次 tick 扫描。 |
| Bitmap.walkBounds（235） | bitmap/z → 已缓存 AABB 或 nil。 | 仅取缓存，不惰性扫描，维持 query 成本稳定。 |
| Bitmap.inAABB（243） | box、x/y → 半开 AABB 包含 bool。 | 纯 predicate，快查基础。 |
| Bitmap.walkableFast（248） | bitmap、世界 x/y/z → 是否可走、是否内框命中两个 bool。 | scope/outer 拒绝后，inner 返回 true,true，边带查询 isActive 并返回 result,false；无世界副作用，移动 query 核心。 |
| Bitmap.makeScope（258） | originX/Y、minZ/maxZ、width/height → 合法 scope 表或 nil。 | 纯构造，统一几何合同。 |
| Bitmap.newLayer（274） | width/height/walkFill/buildFill → 带两位串和 bytes encoding 的层。 | bitmap 构建所需。 |
| Bitmap.layer（284） | bitmap/z → 数字或字符串 z key 对应层/nil。 | 只读公开 accessor；validator 仍要求数字层 key。 |
| layerBits（293） | layer/field/width/height → 长度正确的位串或 nil。 | function expression；内部保证层位串长度。 |
| Bitmap.isActive（301） | bitmap、世界 x/y/z → walkBits bool。 | scope→层→位只读查询，可走区域核心。 |
| Bitmap.isBuildable（311） | 同上 → buildBits bool。 | cab build permission 核心查询。 |
| Bitmap.setCell（321） | layer、本地 ix/iy、enabled、宽高、field → bool。 | 改 layer 内的 walkBits/buildBits；field==build 才取 build，其余为 walk；非法坐标 false，坏位串重置空串后写入。布局构建必需。 |
| Bitmap.toHex（339） | bytes string → hex string 或 nil。 | 纯转换，避免 NUL 穿过 ModData/network 截断。 |
| Bitmap.fromHex（351） | hex、宽高 → 长度正确 bytes string 或 nil。 | 纯解码。 |
| Bitmap.encodeLayer（366） | bytes layer、宽高 → hex layer 表或 nil。 | 要求当前 bytes encoding 和准确长度。 |
| Bitmap.decodeLayer（378） | hex layer、宽高 → bytes layer 或 nil。 | 仅接受当前 hex encoding。 |
| Bitmap.encode（391） | bitmap → 当前 hex bitmap 或 nil。 | validate(false)、预热缓存、返回新表；不改输入。持久化/network 核心编码接口。 |
| Bitmap.decode（413） | encoded 表 → bytes bitmap 或 nil。 | 精确字段、schema/version、scope、层数/层结构检查后解码和预热；不迁移旧 schema，当前存档 fail-closed 核心。 |
| Bitmap.validate（458） | bitmap、allowEncoded → bool。 | 精查 keys、版本、固定100x100、层覆盖和 bitstring/hex 编码/长度；只读 schema 门禁。 |
| Bitmap.edgeKey（514） | N/W axis 与整数 x/y/z → N:x:y:z 或 W:x:y:z key/nil。 | 纯 identity 编码；边界和标签必需。 |
| Bitmap.edgeForSide（525） | side north/west/east/south 或 N/W/E/S，整数 x/y/z → 宿主 key/nil。 | east 映射 W(x+1,y,z)，south 映射 N(x,y+1,z)，匹配 PZ 边归属；跨边界/拆除共享合同。 |

导出别名：Bitmap.hasExactKeys（54）指 exactKeys；Bitmap.boundaryEdge（539）指 edgeForSide。静态检索未命中外部 boundaryEdge 调用。

### RV_UtilitySprite.lua：隐藏 sprite 注册

| 函数/行 | 参数和返回 | 副作用、必要性 |
|---|---|---|
| invoke（13） | target/method/varargs → ok,a,b；缺方法/异常 false,原因。 | pcall 包装 Java API，是本模块内部 helper。 |
| callSucceeded（22） | target/method/varargs → 调用成功且首返回不为 false 的 bool。 | setter 后置校验 helper。 |
| ensureBlueprint（27） | sprite → true 或 false,reason。 | 读 blueprint flag，缺少时设置、CreateKeySet、复读；会改专用 sprite properties，确保隐藏对象的网络/渲染属性。 |
| ensureOne（45） | manager/namedMap/key/id → bool,sprite/reason。 | 查名称/数字表、拒绝 ID 碰撞、必要时登记/设名、校验双索引和 blueprint；可能更改游戏 sprite manager。避免覆盖已有资源，核心。 |
| M.ensureHiddenSprites（88） | 无输入 → bool,sprite,reason。 | 获取 IsoSpriteManager.instance/namedMap 并调用 ensureOne；对外安装接口。 |
| M.install（102） | 无输入 → 同上。 | 立即保证 sprite；OnGameBoot 存在时只注册一次具名 ensureHiddenSprites。修改 sprite manager 和事件订阅，是初始化入口。无匿名事件函数。 |

### RV_UtilityConstants.lua：utility 合同数据

无任何函数。行7 require Constants、18 require PowerConfig、19 require UtilityItems；其余为 store/schema、reach、请求限制、operation/command/state/reason 等数据合同，客户端和服务端直接读取。直接暴露表字段有明确语义，单字段 getter 收益很低。但注释称 data-only（1–5），require UtilityItems 会注册 recipe OnCreate 回调，造成加载副作用。可考虑 bootstrap 显式加载 recipe 或拆分数据与注册；收益是读取常量不触发注册，风险是现有游戏加载顺序依赖，需全局确认再定。

## 2. 通用化建议

- Constants.finiteNumber/finiteInteger（13/33）和 Bitmap 私有 finiteNumber/integer（27/37）行为相同；Bitmap 已依赖 Constants。可让 Bitmap 改调 C 的公开转换并删副本，降低 Java wrapper/NaN 规则漂移；收益中等、风险低，需保持字符串/wrapper 输入语义。
- exactKeys 不宜不加区分合并：Bitmap:43 只限制字段集合；其他模块版本有 metatable、optional key、稠密数组等额外策略。抽象需增加策略参数，当前收益低。
- invoke/call helpers 在别处也常见，但多返回值、异常、false 语义不同。UtilitySprite 的 invoke/callSucceeded 只为 sprite manager 后置条件服务；抽到全局会把 Java 对象调用细节扩大为公共依赖，收益低。
- bit寻址、空间查询、walk cache、编码和 edge identity 同属 bitmap 格式合同，应保留在 Bitmap。
- boundaryEdge 别名未在本模组调用；合并全局审计后可评估，当前不直接移除。

## 3. 拆分判断

- Constants：不拆，协议/布局各端需要单一配置源。
- UtilityConstants：不拆小数据表；解决 recipe 注册副作用边界即可。
- UtilitySprite：登记、配置、验证是单个 sprite 生命周期，拆分会暴露 manager 细节。
- Bitmap：542行、39函数，是本目录最大模块，但查询、cache、层结构、序列化都紧依赖 packed schema，暂不拆。若 hex/persistence 增长，可将文本 codec/encode/decode 拆出，并保证版本合同仅有单一 owner；当前收益不抵版本漂移成本。

## 4. 跨模块访问与接口判断

### 引用证据

只读 rg require 搜索结果：
- Constants：shared Common 内 Bitmap/UtilitySprite/UtilityConstants；shared/Water/RV_UtilityCatalog.lua:6；shared/RVMapping/RV_RegionSlots.lua:6；shared/RoomTemplate/RV_TemplateGeometry.lua:6、RV_RoomTemplate.lua:5、RV_Layout.lua:7；client GUI 的 RV_BoundaryClient:6、RV_BoundaryWallVisuals:5、RV_ContextMenu:8、RV_RailroaderContextMenu:7、RV_ProtectedDemolition:3、RV_WardrobeVisuals:5、RV_UtilityContextMenu:7、RV_UtilityClient:6；server 的 RV_UtilityWater_Objects:3、RV_UtilityWater_Ledger:3、RV_UtilityWater_Commands:3、RV_UtilityStore:3、RV_UtilityServer:4、RV_UtilityPowerDevices:3、RV_UtilityPower:3、RV_ServerWorld:7、RV_DevSaveSchemaGate:942、RV_BoundaryServer:25、RV_RailroaderServer:28。
- Bitmap：shared/RoomTemplate/RV_Layout.lua:8；server/RV_TemplateProtectionRepair.lua:10、RV_Construction.lua:7、RV_ServerSchema.lua:15、RV_BoundaryServer.lua:27；其他服务端边界几何/拆除/roof/schema gate/Sentinel 调其 API。
- UtilitySprite：client/RV_UtilityClient.lua:9；server/RV_Server_WorldObjects.lua:47、662。
- UtilityConstants：client/RV_RailroaderContextMenu.lua:8、RV_UtilityDashboard.lua:10、RV_UtilityClient.lua:15；server/RV_UtilityWater_Plumbing.lua:4、RV_UtilityWater_Objects.lua:4、RV_UtilityWater_Ledger.lua:4、RV_UtilityWater_Commands.lua:4、RV_UtilityStore.lua:4、RV_UtilityServer.lua:5、RV_UtilityPower.lua:4、RV_DevSaveSchemaGate.lua:943。

Bitmap 代表调用：shared/RoomTemplate/RV_Layout.lua:121、224、254、278、285、292；server/RV_Construction.lua:109–110；BoundaryServer_Geometry.lua:210、299、641、743；BoundaryServer_Objects.lua:210、310–326、408、427–490、581–645；TemplateProtectionRepair.lua:536、699、895、1193、1303、1401–1442；RoofDestinations/RoofRelocation 使用 scope/active；RV_ServerSchema.lua:127–163；RV_DevSaveSchemaGate.lua:591–599、708、722、1380–1381。

### 内部访问与接口收益

没有外部模块调用私有 helper（rawGet/rawSet、walkBoundsCache、layerBits、UtilitySprite.invoke/ensureOne）；没有检出其他模块覆写 Constants/Bitmap 导出成员。外部使用明示的 API/数据字段。

多个 server 模块直接读 bitmap schema 字段：RV_ServerSchema.lua:104–137 校验 bitmap、managed 和逐层位串；BoundaryServer_Geometry.lua:215–236 构造持久记录、372–410 对比缓存与编码身份；RV_DevSaveSchemaGate.lua:590–617 比较 persisted/current/expected layout 的位层。涉及 schema/version、原点、尺寸、Z 范围、layers、walkBits/buildBits/encoding。这些属于 Bitmap.validate/encode/decode 约定的数据合同，不是隐藏 cache。调用方需比较多份数据、检测部分替换。

RV_ServerSchema 的 bitstring 长度检查与 Bitmap.validate 有部分重复，可考虑改用 Bitmap.validate(bitmap,false) 再做自身几何一致性校验；完整 validate 增加一轮 bitset/schema 扫描，需要 server 子模块确认调用频率。BoundaryServer_Geometry 与 DevSaveSchemaGate 必须逐层比较两个 bitmap 内容；getter 不会省去比较。只有多处调用需要相同 equality/current-layout 规则时，新增该语义 API 才值得。Constants/UtilityConstants 字段是多端协议合同，直接读优于一字段一 getter。Lua table 可写，但赋值检索只命中模块自己的初始化，常量不变靠约定。UtilitySprite 外部只用 ensure/install 接口，不访问注册细节。

## 未解决/覆盖限制

只覆盖 shared/Common 的函数；其他目录由其独立报告分析。没有游戏或服务器运行时证据，因为任务为只读静态分析。rg 可能漏掉动态 require 或反射式访问，但本目录四个文件均逐行检查。boundaryEdge 未见外部调用和 UtilityConstants 的 recipe 注册副作用留待全局报告合并确认。

## 第二阶段 strict-schema helper

新增 `RV_StrictSchema.lua`，只包含共享严格原生整数与 plain exact-key primitive；`RV_RegionSlots` 和共享 Water Catalog 共用它。它不承接 Bitmap、template identity、dense array 或 optional-key policy。`RV_Bitmap.integer` 不由 Constants `finiteInteger` 替代：源实现还接受数字字符串/算术可转的 Java wrapper，且对非有限值的处理不同；合并会改变输入合同。见[第二阶段报告](phase2-structure-optimization.md)。

