# server/RailroaderRV/Power 模块分析
> **状态（RailroaderRV 1.0）**：本文件是静态审计记录；其行号、计数和源码结论并非本次发布的全量重核，也不是运行时验证。当前实现以 [源码](../../contents/mods/RailroaderRV/42/) 与 [README](../../README.md) 为准，项目约束以 [agents.md](../../../agents.md) 为准。历史建议不构成修复授权，采纳前须按现行约束重新取证。

## 假设、范围、成功条件与验证方式

- **假设**：只分析模组当前目录 media/lua/server/RailroaderRV/Power/ 的直接子文件，即 [RV_UtilityPower.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Power/RV_UtilityPower.lua)（661 行）与 [RV_UtilityPowerDevices.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Power/RV_UtilityPowerDevices.lua)（365 行）。行号以本次读取的文件版本为准；本目录是服务端权威电力账本与设备状态适配区域，按当前 B42 服务端调用语义解释。
- **范围**：覆盖上述 2 个文件及其全部具名函数、局部函数、表方法和匿名函数表达式；只读检查调用方（Core、Construction、RVMapping、Water、client GUI）以判断公开 API 使用和跨模块数据访问。只读参考 `media/scripts/RV_UtilityPower.txt`，不逐函数分析。唯一写入目标为本报告与同事务的 shared-Power.md。
- **成功条件**：每个函数都有精确起始行、参数含义、返回值或副作用、模块语义和必要性判断；另外列出复用/拆分建议、接口边界与证据，并把「源码事实」与「条件性推断」分开表述。不运行游戏或 runtime 测试。
- **验证方式**：目录文件枚举与行数统计；用 `function` 关键字扫描取得全部定义行，再逐行编号读取全文交叉核对；用全 media/lua 树检索本模块导出 API、identityKey/classInstance 与电力设备 API 的调用点；对照 Core/RV_UtilityServer.lua、Core/RV_UtilityStore.lua、Common/RV_ServerWorld.lua、RVMapping 记录合同、shared 配置与 scripts 定义核对字段与常量来源。源码扫描是静态分析，不替代运行时验证。
- **区分口径**：文中标注「源码事实」的是本目录及同仓其他文件的直接可读证据；标注「条件性推断」的是依赖运行时数据形状、未被静态断言覆盖的判断。

## 目录职责与清单

Power/ 目录承担两类职责：RV 电力账本（虚拟燃油、电池包、充电器/逆变器事务、断路器与原生发电机代理、结算与快照），以及 RV 室内电力设备的发现、状态采样与负载汇总。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_UtilityPower.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Power/RV_UtilityPower.lua) | 42 | 服务端权威能量结算与持久化事务：原生发电机绑定/代理维护、虚拟燃油与电池包、充放电与发电结算、物品安装/拆除、意图分派与电力快照（33 个 `local function` + 8 个 `function M.*` + 1 个匿名函数） |
| [RV_UtilityPowerDevices.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Power/RV_UtilityPowerDevices.lua) | 22 | 设备发现与状态适配：按 RV 室内方格扫描可供电对象、分类并缓存原始身份、按设备类型读通电状态、汇总负载与计数、缓存生命周期（15 个 `local function` + 7 个 `function M.*`） |
| **总计** | **64** | 64 个函数体定义，其中 1 个匿名函数表达式；`M.ensureRuntime = ensureRuntime`（L317）是导出别名赋值，不重复计数 |

依赖方向（源码事实）：Power require shared 常量 `RV_Constants`（L3）与 `RV_UtilityConstants`（L4）、shared 配置 `RV_UtilityPowerConfig`（L5）、Core 存储 `RV_UtilityStore`（L6）、同目录 `RV_UtilityPowerDevices`（L7）、Common 的 `RV_ServerWorld`（L8）与 `RV_ServerUtil`（L9）；Devices require shared 常量 `RV_Constants`（L3）、shared 配置（L4）、Common 的 `RV_ServerWorld`（L5）与 `RV_ServerUtil`（L6）、RoomTemplate（L7）与 TemplateGeometry（L8）。两者都不 require `RV_Common`，通用 helper 一律经 `RV_ServerUtil` 门面取得。Devices 不 require Power，两者无循环依赖。

## 逐文件、逐函数分析

### RV_UtilityPower.lua

模块不注册事件、不直接写 ModData：所有持久化都经 `Store.getRecord/commit/snapshot`。L11 起的 `M` 表是本模块唯一的公开出口，共导出 9 个函数（`ensureRuntime`、`settleAndRefreshLoad`、`addFuel`、`addBattery`、`removeBattery`、`handleIntent`、`maintainNativeProxy`、`initializeRecord`、`snapshot`）；`invoke`/`callSucceeded`/`commit` 是转出 `Util`/`Store` 的薄包装，`worldAgeHours`、`finite`、代理与库存事务函数均保持私有。文件头注释声明设计边界：原生发电机燃油/耐久由维护重置，永不结算 RV 能量。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| invoke（L13） | target 对象、method 方法名、`...` 方法参数；转调 `Util.invoke`，返回 ok,a,b,c,d 或 false,error/nil。 | **必须**：本文件所有 Java 对象访问（发电机、方格、容器、物品、玩家）依赖同一保护语义与多返回值约定。 |
| finite（L17） | value 任意可数值化值；先把 value 经 `Util.toNumber` 转换，再排除 nil、NaN 与正负无穷，返回布尔值。 | **必须**：结算时间、能量与流体的任何一步都不接受非有限值；它与 `Util.isFiniteNumber` 的区别是转换在前（见复用章节）。 |
| worldAgeHours（L22） | 无参数；依次尝试全局 `getGameTime()`、`GameTime.getInstance()` 或 `GameTime.instance`，经 invoke 读 `getWorldAgeHours` 并数值化，非负有限值才返回，否则 nil。 | **必须**：结算是时间差驱动的，必须有可信且可失败的时间基准；这是全仓唯一读取 world age 的实现。 |
| worldAgeHours 中匿名函数（L32） | 无显式参数，捕获 `gameTime`；在 pcall 内选择 `getInstance()` 或 `instance` 单例。 | **实现必需**：singleton 属性读取本身可能抛错，且要兼容两种 B42 时间入口。 |
| callSucceeded（L46） | target、method、`...`；转调 `Util.callSucceeded`，把调用折叠为「成功且首返回值不为 false」的布尔值。 | **必须**：`setActivated`/`setFuel`/`setCondition`/`sync`/`Remove` 等写操作需要统一判定明确失败。 |
| objectFingerprint（L50） | object 世界对象；经 getSprite/getName 取 sprite 名，返回 `"generator:<name>"`，取不到时 name 为空串。 | **必须**：绑定后重新解析代理对象时用它排除同坐标被替换成别的对象。 |
| generatedGenerator（L57） | object、identity{rvId,generation}；经 `World.objectModData` 读嵌套 `RailroaderRV` tag，校验 owner==C.MOD_ID、role=="generator"、rvId 与 generation 一致，返回布尔。 | **必须**：绑定与代理操作只能作用于本模组为当前 RV 代际生成的发电机（见接口章节对 ModData 直读的说明）。 |
| objectAt（L66） | identity、binding{坐标,可选 objectFingerprint}、player；经 `World.getCellForPlayer/getSquare/squareSnapshot` 在绑定坐标枚举对象，返回首个身份与指纹都匹配的对象或 nil。 | **必须**：持久化记录里不能保存易失的 IsoObject，任何代理操作都要按坐标+身份重新解析。 |
| bindingFor（L85） | identity、record（mapping 记录）、player；从 `record.rvPosition` 加 `C.GENERATOR_OFFSET` 得目标坐标，找到对象后用 `getSquare/getX/getY/getZ` 复核实际坐标，返回 {rvId,generation,x,y,z,objectToken,objectFingerprint} 或 nil。 | **必须**：这是唯一建立持久化 `power.generator` 绑定的路径，并自带坐标复核防止写入错误位置。 |
| readProxy（L111） | object；读 fuel/maxFuel/condition/isActivated 并校验类型与有限性，成功返回 {fuel,maxFuel,condition,active}，否则 nil。 | **必须**：代理状态不可读时不能切换或维护原生发电机，否则会把坏状态当成好状态。 |
| boundProxy（L125） | identity、power、player；按 `power.generator` 重新解析对象并读状态，返回 object,state 或 nil。 | **必须**：把「重解析+状态校验」收敛成一处，供结算、维护、快照三处共用。 |
| bindProxy（L132） | identity、power、context；已绑定直接返回 true；否则用 context.record/context.player 走 bindingFor 并写入 `power.generator`。 | **必须**：初始化记录时建立持久绑定的唯一入口，失败返回 `U.REASONS.GENERATOR_INVALID`。 |
| inventoryItems（L141） | inventory 容器、result 目标数组、seen 已访问集合；递归遍历容器与物品嵌套库存，把每项记为 {item,inventory}。无返回值，写入 result。 | **必须**：玩家物品可能装在包/容器的子库存里，按 item id 搜索必须覆盖嵌套层级并防环。 |
| findInventoryItem（L153） | player、itemId；收集玩家全部嵌套库存物品，按 `getID` 字符串匹配，返回 {item,inventory} 或 nil。 | **必须**：客户端只提交物品提示 id，服务端必须在权威库存里重新解析出物品与所属容器。 |
| itemType（L166） | item；读 getFullType 并转 string，失败返回空串。 | **必须**：电池与充电器/逆变器安装按完整类型校验来源物品。 |
| itemCondition（L171） | item；读 getCondition/getConditionMax/getCurrentUsesFloat，校验范围后返回 condition、maxCondition、夹到 0..1 的 usedDelta，任一不合法返回 nil。 | **必须**：电池容量/荷电与组件效率都由服务端物品状态换算，非法值必须失败而不是近似。 |
| removeInventoryItem（L183） | found{item,inventory}；调用容器 `Remove`，返回布尔成功标志。 | **必须**：安装/拆除交易消费物品的唯一出口；失败即中止事务。 |
| addInventoryItem（L188） | inventory、item；调用 `AddItem` 并要求返回非 nil、非 false。 | **必须**：回滚与拆除都靠它把物品交还玩家，必须能识别 engine 的明确拒绝。 |
| createItem（L194） | fullType、condition、可选 usedDelta；经全局 `InventoryItemFactory.CreateItem` 建物品，失败返回 nil；condition/usedDelta 设置失败也返回 nil。 | **必须**：拆除电池/组件后需要重建等价物品；返回 nil 让调用方在改动账本前中止。 |
| syncItem（L205） | item；存在 `syncItemFields` 时调用它。无返回值。 | **保留理由**：把新建物品字段同步给客户端；方法缺失不算错误，因此当前成功路径不依赖它。 |
| itemHintId（L211） | hint 任意值；表则取 `hint.itemId` 或 `hint.id`，否则 nil。 | **必须**：统一客户端提示字段读取，同时明确不信任提示中的对象或坐标。 |
| recomputeBatteryPack（L215） | power 账本子表；对 batteries 逐节累加 `P.batteryParameters` 的容量/充放电上限并回写三个 pack 字段，再把 batteryWh 夹到新容量。 | **必须**：增删电池后恢复 pack 汇总不变量，是结算读取字段的唯一生产者。 |
| bump（L231） | power；`power.sequence = power.sequence + 1`。 | **必须**：每次账本变更递增序号，供快照/广播识别状态更新。 |
| commit（L235） | record、identity；转调 `Store.commit` 并把结果原样返回。 | **必须**：本模块唯一的持久化提交入口，失败原因（含 CANONICAL_COMMIT_FAILED）要透传给调用方补偿。 |
| circuitShouldBeOn（L239） | power；当前 ON 时只需 batteryWh>epsilon 即保持 ON；当前 OFF 时需容量>0 且荷电达到 `RESTART_CHARGE_FRACTION` 才置 ON，返回布尔。 | **必须**：实现上下电迟滞，避免电量在阈值附近抖动导致原生发电机反复开关。 |
| syncCircuitProxy（L247） | identity、power、player；先按 circuitShouldBeOn 写 `power.circuitState`，再重解析代理，若 active 不一致则 `setActivated` 并 `sync`，失败返回 false,`U.REASONS.API_ERROR`。 | **必须**：把账本断路器状态投影到原生发电机；这是 RV 电路与原生供电对象之间唯一的同步点。 |
| settleGeneration（L262） | power、elapsedHours；按 generatorEnabled 构造汽油源（虚拟燃油>0 才有额定功率），在剩余容量、充电功率、效率与燃油热值约束下计算发电量/耗油/报告功率；无负载可接受时按 `IDLE_FUEL_FRACTION` 空转耗油；更新 virtualFuelL 与 batteryWh，返回平均发电 W。 | **必须**：核心虚拟能量运算，且决定「原生燃油不参与账本」这一设计成立。 |
| ensureRuntime（L303，导出 L317） | identity、record；`lastUpdateTime>0` 直接 true；否则取 world age，写入 lastUpdateTime/lastSettlementTime/generationPowerW(0)/state(READY)，校准电路代理，bump 并提交；无时间基准返回 false,API_ERROR。 | **必须**：运行时第一次操作需要建立不追溯计费的基准时间；被 UtilityServer 定时 tick 直接调用。 |
| M.settleAndRefreshLoad（L319） | identity、player、可选 providedRecord；缺记录时取 Store 记录，确保运行时，按两个时间戳最大值算 elapsedHours，先 `Devices.resolveCached` 剔除不可解析设备，再取 `Devices.currentLoadW` 算电池输出、`settleGeneration` 算发电、更新 batteryWh、同步电路代理、`Devices.refreshStates` 刷新设备状态、更新时间戳、bump 并提交；成功返回 true,record，否则 false,reason。 | **必须**：所有周期结算与电力操作前的统一账本入口，也是唯一的十分钟采样点。 |
| resolveFuelSource（L356） | player、hint；按 hint 的 item id 在服务端库存找物品，经 `getFluidContainer` 与全局 `Fluid.Petrol` 验证容器含纯汽油且 amount>0；成功返回 true,found,container,amount,petrol，否则 false,reason。 | **必须**：加燃油只能消费服务端实际持有的纯汽油，混合物或空容器必须拒绝。 |
| M.addFuel（L376） | identity、context、hint；读记录→校验油源→按 `VIRTUAL_FUEL_CAPACITY_L` 算可注入量→`removeFluid` 移除→读回 `getAmount` 复核真实转移量→累加 virtualFuelL→bump→提交；提交失败把已转移燃油 `addFluid` 还给油桶后再返回失败；成功返回 true,{record}。 | **必须**：由 UtilityServer 直接调用的服务端加油事务；复核与补偿是防止物品与账本两侧不一致的关键。 |
| isBatteryType（L408） | fullType；判断是否为 Base.CarBattery / CarBattery1 / CarBattery2 / CarBattery3。 | **必须**：限制可安装的电池来源类型，避免任意物品进入电池包。 |
| M.addBattery（L413） | identity、context、hint；定位并校验物品类型与 condition，按 `P.batteryParameters` 要求容量>0，追加 battery row（id 为列表序号+1，不持久化 id）、按 usedDelta 增加 batteryWh、重算 pack、从库存移除物品、bump、提交；提交或移除失败时把物品放回，返回 false；成功后同步电路代理，返回 true,{record}。 | **必须**：把实体电池转换为虚拟电池包的权威交易，也是 `handleIntent` 的 ADD_BATTERY 分支。 |
| M.removeBattery（L450） | identity、context、hint.batteryId；按 id 定位 row，按 pack 荷电比创建物品并放入玩家库存，删除 row、扣除该节贡献、重算 pack、bump、提交；提交失败把新物品收回，成功返回 true,{record}。 | **必须**：安全拆卸电池；先入库后改账本的顺序保证失败可回滚。 |
| componentRow（L488） | item、expectedType；要求 fullType 匹配、`itemCondition` 有效、maxCondition 等于 `P.COMPONENT_CONDITION_MAX` 且 condition>0，返回 {fullType,condition,conditionMax} 或 nil。 | **必须**：安装充电器/逆变器前把输入物品转换成可持久化的组件 row，并拒绝磨损到零或非本模组的物品。 |
| installComponent（L498） | identity、context、hint、field（charger/inverter）、fullType；槽位已占返回 CAPACITY_FULL；在库存中校验组件行，移除物品，写入 `power[field]` 与 `power[field.."Efficiency"] = condition/conditionMax`，bump、提交；失败时把物品放回，成功返回 true,{record}。 | **必须**：充电器与逆变器共用的安装事务，并维护结算读取的效率字段。 |
| removeComponent（L523） | identity、context、field；账本无该组件返回 SOURCE_INVALID；创建等价物品并放入玩家库存，清空 `power[field]` 并把效率恢复为对应默认值，bump、提交；失败收回物品，成功返回 true,{record}。 | **必须**：拆卸共用事务，效率必须回到默认值否则下次安装前结算会用到旧效率。 |
| setGeneratorEnabled（L551） | identity、context、enabled；先 `M.settleAndRefreshLoad` 结清上一个运行区间，状态相同直接成功，否则写 generatorEnabled（关闭时清零 generationPowerW）、bump、提交。 | **必须**：启停必须先把旧区间结算掉，否则会按新状态回算历史用电。 |
| M.handleIntent（L566） | identity、context、operation、hint；要求 context 为表、authorized==true、phase=="READY"，按 operation 分派电池/充电器/逆变器/发电机启停，未知操作返回 false,`U.REASONS.INVALID_REQUEST`。 | **必须**：Core UtilityServer 的通用电力意图入口，也是安装/拆卸私有函数的唯一外部入口。 |
| M.maintainNativeProxy（L594） | identity、record；重解析代理，把 fuel 补满、condition 提到 `NATIVE_GENERATOR_CONDITION_MAX`、active 对齐 circuitState，任一变更后要求 `sync` 成功，最后重新读取并复核三项，返回布尔。 | **必须**：UtilityServer 每小时调用，确保原生发电机只表现账本断路器且不消耗原生燃油/耐久。 |
| M.initializeRecord（L625） | identity、context；`Store.getRecord(identity,true)`，取 world age 写入两个时间戳，`bindProxy` 绑定生成对象，初始化 circuitState=OFF/generatorEnabled=false/generationPowerW=0，bump，`M.maintainNativeProxy` 维护代理，提交；成功返回 true,record。 | **必须**：UtilityServer 在 RV 生成完成后建立 utility 记录的入口，绑定失败即整体失败。 |
| M.snapshot（L648） | record、identity、context；以 `Store.snapshot(record).power` 为底，补 `currentLoadW`、`deviceCount` 与 `proxyActive`（经 boundProxy 读原生 active，读不到保持 false），返回快照表。 | **必须**：Server→client 的电力 wire 合同构造点；负载必须是实时读数而不是持久化副本。 |

### RV_UtilityPowerDevices.lua

模块不注册事件、不写存档、不引用 `IsoObject`：`caches`（L12）、`scans`（L13）、`unknownLogged`（L14）都是文件内私有的进程内状态，L11 的 `M` 表导出 8 个函数。注释明确缓存「只含坐标与原始身份数据，绝不保存 IsoObject 引用」。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| invoke（L16） | target、method、`...`；转调 `Util.invoke`。 | **必须**：本文件所有 native 对象访问共享同一保护语义。 |
| instanceOf（L20） | 无函数体，是 `local instanceOf = Util.classInstance` 的直接绑定。 | **必须**：设备分类与重解析按游戏原生类判定；此处已统一到公共 helper（见复用章节）。 |
| spriteName（L22） | object；经 getSprite/getName 取 sprite 名，失败返回空串。 | **必须**：sprite 名是设备缓存的身份字段，重解析时用它确认同一对象。 |
| objectName（L29） | object；读 `getObjectName`，为 nil 时返回 `"IsoObject"`。 | **必须**：为非 instanceof 分支提供稳定分类名（如 Thumpable/自定义名）。 |
| containerFor（L35） | object、kind（"fridge"/"freezer"）；经 `getContainerByType` 取容器或 nil。 | **必须**：冰箱/冷冻柜只能靠容器类型分类，也是读其 isPowered 状态的入口。 |
| booleanResult（L40） | ok 调用成功标志、value 返回值；仅当调用成功且值为 boolean 时返回值，否则 nil。 | **必须**：设备状态必须三态化，读不到就不能当成「关闭」。 |
| classify（L45） | object；先按 fridge/freezer 容器判定 FridgeFreezer/Fridge/Freezer，再按 instanceof 判定 Light/Radio/TV/Washer/Dryer/WasherDryer/StackedWasherDryer，最后对 IsoStove 用 `isMicrowave` 区分 Stove/Microwave；未识别对象按 name+sprite 只打印一次日志并返回 nil；成功返回 {deviceType,objectClass,sprite,ratedPowerW}。 | **必须**：设备类型→读取 API→额定功率的映射表；日志去重避免每次扫描刷屏。 |
| poweredCandidate（L99） | object；调用 `couldBePoweredByGenerator`，仅明确 true 才返回 true。 | **必须**：过滤不受发电机供电的对象，否则会把不可供电对象计入负载。 |
| readActive（L104） | object、deviceType；Light/洗烘设备用 `isActivated`，Radio/TV 用 `getDeviceData` 的 getIsTurnedOn 且非电池供电，冰箱类用容器 `isPowered`，Stove/Microwave 用 `Activated`；未知类型或读取不明返回 nil。 | **必须**：不同原生设备的通电 API 完全不同，必须在这里归一为三态 active。 |
| devicePowerW（L137） | object、deviceType、ratedPowerW、circuitOn；电路关闭返回 0；WasherDryer 按 `isModeWasher` 返回 Washer/Dryer 功率，StackedWasherDryer 按 `isWasherActivated`/`isDryerActivated` 相加，其余按 active 返回额定功率或 0；状态不明返回 nil。 | **必须**：把设备状态转换成结算所需的瓦数，组合洗烘设备必须按子设备分别计量。 |
| squareCoordinates（L161） | square；读并整数化 getX/getY/getZ，任一失败返回 nil。 | **必须**：扫描缓存以整数方格坐标作为身份的一部分。 |
| objectIndex（L172） | object；读 `getObjectIndex` 并整数化，失败 nil。 | **必须**：同一方格内相同类型多对象只能靠 object index 区分。 |
| deviceId（L177） | device row（x/y/z/objectIndex）；拼成 `x:y:z:index` 字符串 id。 | **必须**：缓存条目的键，也是跨扫描继承状态的匹配依据。 |
| scanSquare（L182） | identity、player、x、y、z；取 cell 与 square（失败返回 false），算整数坐标，删掉缓存中该方格旧条目并保留为 `previous`，对每个候选对象分类建 primitive row（含 lastKnownActive/stateKnown/resolved），类型、sprite、deviceType 一致时继承旧状态；返回扫描是否执行。 | **必须**：全量扫描与增量扫描共用的缓存刷新入口，也是状态继承规则的唯一实现。 |
| interior（L234） | record（需含 `anchor{x,y,z}` 整数）；遍历 `Template.misc.walkAabbs`，对每个方格调 `TemplateGeometry.isWalkable` 去重后返回 world 坐标数组；anchor 缺失或坐标非整数返回 nil。 | **必须（存在缺陷）**：室内坐标集是扫描范围的唯一定义。但它读取 `record.anchor`，而当前调用方传入的 mapping 记录只持久化 slotIndex（见接口边界章节）。 |
| M.scanAll（L262） | identity、record、player；对 interior 的每个方格调 scanSquare 并重置 cursor=1；成功返回 true，坐标无效返回 false,"RV interior coordinates are invalid"。 | **必须**：UtilityServer 处理用户 REFRESH_DEVICES 时的全量扫描入口。返回 true 只表示坐标集可枚举，不表示每个方格都加载成功。 |
| M.scanTick（L274） | identity、record、player；取该 identity 的 cursor 状态，连续扫描 `P.DEVICE_SCAN_SQUARES_PER_TICK` 个方格并循环推进 cursor；坐标无效返回 false，否则 true。 | **必须**：UtilityServer 周期 tick 的增量发现入口，避免一次扫完整个室内。 |
| resolveDevice（L290） | identity、device row、player；在当前 cell 重新取方格快照，按 objectIndex、poweredCandidate、类（`Iso` 前缀走 instanceof，否则比 objectName）与 sprite 匹配，再要求 classify 结果 deviceType 相同，返回对象或 nil。 | **必须**：缓存不持有对象引用，任何读取状态前必须重新解析；多重校验防止坐标复用导致认错对象。 |
| M.refreshStates（L315） | identity、player、circuitOn；遍历该 identity 缓存，逐条解析对象并写 `resolved`；对象存在且瓦数可读时更新 lastKnownPowerW/lastKnownActive/stateKnown。 | **必须**：结算末尾的负载采样点，同时把电路开关状态注入功率计算。 |
| M.resolveCached（L332） | identity、player；只刷新每条缓存的 `resolved`，不重采瓦数。 | **必须**：按上一次采样点结算前先剔除已卸载/删除对象，避免陈旧负载被继续计费。 |
| M.currentLoadW（L339） | identity；对 resolved 且 stateKnown 且 lastKnownActive 的条目累加 lastKnownPowerW（缺省用 ratedPowerW），返回 total,count。 | **必须**：Power 用它计算电池输出功率；count 供调用方诊断。 |
| M.count（L351） | identity；返回该 identity 的缓存条目数（含未解析条目）。 | **必须**：Power.snapshot 将其作为 `deviceCount` 暴露给客户端。 |
| M.clear（L359） | identity；删除该 identity 的 `caches` 与 `scans` 条目。 | **当前不是功能必需**：全 media/lua 树检索不到任何调用点，缓存因此按 RV/generation 永久驻留；作为生命周期清理出口有保留价值，但需要实际接入才有作用。 |

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **identityKey 已统一（源码事实）**：Devices 不再有本地实现，L191、L269、L277、L316、L333、L341、L353、L360 八处直接调用 `Util.identityKey(identity.rvId, identity.generation)`，即 [RV_ServerUtil.lua:46](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerUtil.lua:46) 转出的 [RV_Common.lua:80](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_Common.lua:80)。旧文档描述的两处本地 `identityKey`（含 bitmapVersion 的拼接实现）在本次读取的源码中已不存在。**注意语义变化**：当前键只含 rvId 与 generation，bitmapVersion 不再参与缓存作用域。
- **instanceof 已统一（源码事实）**：Devices L20 的 `local instanceOf = Util.classInstance` 是直接函数引用，不是包装；`Util.classInstance` 即 `Common.classInstance`（[RV_Common.lua:50](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_Common.lua:50)）。旧文档所称「Devices 自建 instanceof 包装」已不存在。
- **invoke 包装是有意保留的命名别名（源码事实，结论未变）**：Power L13、Devices L16 的 `invoke` 都只有一行 `return Util.invoke(...)`，Power L46 的 `callSucceeded`、L235 的 `commit` 同理。它们不引入新语义，只把 `Util.`/`Store.` 前缀从数百个调用点里去掉。**净收益判断**：删除它们需要改动 60 余个调用点，收益仅是少一层转调，因此**不建议为「去重」而删除**；但也不应再新增同类别名。
- **finite 与公共 helper 语义不同（源码事实，不应合并）**：Power L17 的 `finite` 先 `Util.toNumber` 再判有限，而 [Common.isFiniteNumber](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_Common.lua:67) 只接受 `type(value)=="number"`；直接替换会把 Java 数值包装值判成非法。若要合并，只能在 `Common` 增加「先转换再判有限」的新 helper，收益是消除一个 4 行函数，成本是一次跨模块改动，**当前不值得**。
- **worldAgeHours 是唯一实现，可考虑上移（源码事实 + 条件性推断）**：全 media/lua 树中 `getWorldAgeHours` 仅出现在 Power L41，`getGameTime` 仅出现在 Power L24，即当前没有第二个时间基准消费者。若 Water 或未来的结算模块也需要墙钟时间，把它移到 [RV_ServerWorld.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua)（已有 `getCellForPlayer`/`getSquare` 等 world 访问）比留在 Power 更合适；在只有一个消费者前提取属于投机扩展。
- **object index 读取共有 7 处（源码事实）**：Devices.objectIndex（L172）与 [RV_UtilityWater_Objects.lua:75](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:75)、[RV_Server_WorldObjects.lua:421/431/534](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_WorldObjects.lua:421)、[RV_RailroaderServer_WallReload.lua:139](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua:139)、[RV_BoundaryServer_Objects.lua:139](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/DemolitionProtection/RV_BoundaryServer_Objects.lua:139) 都是「invoke getObjectIndex → 整数化」三步。这是跨模块重复度最高的候选；但它是 3 行 helper，且各调用点的失败语义已一致，抽取的净收益主要在一致性而非代码量，**建议与其他 server helper 一起评估，而不是单独新增一层**。
- **对象身份 tag 判定与 ServerWorld 重复（源码事实，值得提取）**：Power.generatedGenerator（L57-L64）与 [RV_ServerWorld.isTaggedForGeneration](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua:213) 都在做「读 `data.RailroaderRV` → 比 owner → 比 generation → 比 rvId」，差别只有 Power 额外要求 `role == "generator"`，且 Power 用 `Util.integer` 而 World 用 `Util.toNumber` 比较 generation。建议在 ServerWorld 增加 `objectTag(object)` 返回 tag 表（或 `hasTag(object, generation, rvId, role)`），让 Power 只做 role/身份消费。**收益**：tag 字段布局由写入方（`tagObject`，L178）与读取方共用一个访问口，避免命名空间字符串 `"RailroaderRV"` 散落在 Power / WorldObjects / World 三处。
- **设备状态适配不应上移 shared（源码事实）**：`readActive`/`devicePowerW`/`classify` 依赖 `getDeviceData`、`isModeWasher`、`isPowered`、`Activated` 等引擎侧对象 API，并且只在服务端解析世界对象时有意义；客户端已经通过快照 `currentLoadW`/`deviceCount` 消费结果。**结论：设备分类/状态读取留在 server**；唯一适合 shared 的部分是 `P.DEVICE_POWER_W`（已经在 shared 配置里，L28-L40）。
- **纯能量计算的上移判断（条件性推断）**：`settleGeneration`（L262）、`circuitShouldBeOn`（L239）、`recomputeBatteryPack`（L215）确实是无世界访问的纯函数，理论上可跨端复用。但当前客户端只需要展示结果字段，没有任何客户端消费者，而且它们直接读写账本子表字段（`virtualFuelL`/`batteryWh`/`circuitState`），这些字段的 schema 由 server 侧 `Store.newPower`（[RV_UtilityStore.lua:73](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:73)）定义。**结论：留在 server**；若未来客户端要预测能耗，应把「输入输出都显式声明」的纯函数版本放到 shared，而不是搬运现有实现。

### 是否进一步拆分

- **两文件合计 1026 行（661 + 365），逐函数分析 64 项；当前不建议拆分。** 依据是职责闭环而不是行数：Power 的三个区块（原生发电机代理解析/绑定/维护 L50-L139、L247-L260、L594-L623；发电/负载/电池结算与运行时 L215-L354；玩家物品事务与补偿 L141-L213、L356-L564）共享同一个 `record.power` 结构、同一个 `commit` 时机与同一套「先改库存再改账本、失败即补偿」顺序。拆出 adapter 会让 `power.generator` 的字段写入分散到两个文件，并把 `Store`/`Devices`/`Util` 的依赖复制两份；拆出物品事务则要暴露 `commit`/`bump` 或引入新的提交回调。按当前规模，拆分的收益主要是文件导航，成本是新的模块间合同。
- **优先拆分信号（未来条件）**：如果出现第二种原生供电对象（例如第二个发电机类或车载电源）需要独立绑定时，把 L50-L139 + L594-L623 抽成 `RV_UtilityPowerProxy.lua` 才有明确边界；如果 Water 或其他子系统开始复用「库存物品消费+回滚」模式（L141-L213），再抽 `RV_ServerInventoryTxn` 之类的中立模块才划算。
- **Devices 365 行、22 个函数，边界已经清楚**：`classify`/`readActive`/`devicePowerW`（L45-L159）是纯适配器，`scanSquare`/`interior`/`resolveDevice`（L182-L313）是空间缓存，`currentLoadW`/`count`/`clear`（L339-L363）是查询接口。如果设备类型适配显著增长（例如新增十几种家电），可把适配器表拆成独立文件并只暴露 `classify/readActive/devicePowerW` 三个函数，条件是缓存结构保持私有。当前 22 个函数、三个私有表，拆分没有净收益。
- **不建议按「server/shared 对称」拆分**：Power 的 `worldAgeHours`、代理、事务都依赖 server 侧世界访问与 Store；强行把与 shared 配置同名的部分搬到 shared 只会制造跨层依赖。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **RV_UtilityPower 导出 9 个函数**（`M.ensureRuntime` L317、`M.settleAndRefreshLoad` L319、`M.addFuel` L376、`M.addBattery` L413、`M.removeBattery` L450、`M.handleIntent` L566、`M.maintainNativeProxy` L594、`M.initializeRecord` L625、`M.snapshot` L648）。调用方全部是 [Core/RV_UtilityServer.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua)：L133 快照、L212/L221/L233/L241/L320/L336 结算、L219 加油、L253/L256 意图分派、L313 运行时初始化、L329 小时维护、L346 记录初始化；[Core/RV_Server.lua:95-99](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:95) 又把 `initializeRecord`/`settleAndRefreshLoad` 转出为 `RV.Server.initializeUtilityRecord`/`settleRVUtilityLoad`，后者被 [EntryExit.settleUtilityTransition](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:121) 在进出车厢时调用。
- **RV_UtilityPowerDevices 导出 7 个函数**（`M.scanAll` L262、`M.scanTick` L274、`M.refreshStates` L315、`M.resolveCached` L332、`M.currentLoadW` L339、`M.count` L351、`M.clear` L359）。外部调用点只有 [RV_UtilityServer.lua:227](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:227)（用户刷新）与 L314（每 tick 增量扫描）；`refreshStates`/`resolveCached`/`currentLoadW`/`count` 只由 Power L337、L338、L347、L652、L653 消费。**`M.clear` 没有任何调用点（源码事实）**。
- **Server→client wire 字段合同**：`M.snapshot` 返回 `Store.snapshot(record).power` 的全部持久字段再加 `currentLoadW`/`deviceCount`/`proxyActive`；客户端消费点在 [RV_UtilityDashboard.lua:377-407](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:377)（`proxyActive`、`currentLoadW`、`deviceCount`）。这是跨端协议，改字段必须同步 UI。
- **私有状态**：Power 只有 `M` 表与 require 绑定，没有计数器/缓存类模块级可变状态；Devices 的 `caches`/`scans`/`unknownLogged` 均为文件内 local，其他模块无法直接触达，只能经 `M.*` 交互。

### 直接读写其他模块的数据

1. **`World.objectModData` 返回的 ModData 原表：Power L58-L63 直接读嵌套 tag（源码事实，本目录唯一一处）**。`local data = World.objectModData(object)`，随后 `data.RailroaderRV.owner/role/rvId/generation`。这是 [ServerWorld.objectModData](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua:167) 显式导出的数据口（返回 engine 原表），因此不是读取 World 的私有状态；**本目录没有对 ModData 的写操作**（唯一写者是 Construction：`ServerWorld.tagObject(generator, generation, "generator", tagContext)`，[RV_Server_WorldObjects.lua:496](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_WorldObjects.lua:496)）。判断：**当前直读可以接受**，因为 tag 只有 4 个字段、写入方集中在 server（World.tagObject 与 DemolitionProtection L309）、Power 只读；但同一判定已在 ServerWorld.isTaggedForGeneration 与 WorldObjects.generatorObjectTag（[L644](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_WorldObjects.lua:644)）各写一遍，而 `data.RailroaderRV` 这一命名空间串在全 media/lua 树出现 14 次（Power L59、World L206/L218/L321/L364、WorldObjects L351/L646、DemolitionProtection L27/L309、TemplateProtectionRepair L141、WallReload L145/L207，以及 client 的 WardrobeVisuals L51、ProtectedDemolition L195、BoundaryWallVisuals L44），说明 tag 字段布局事实上已是跨端合同。**建议改为接口**：由 ServerWorld 提供 `objectTag`/`hasTag`，收益是命名空间与字段布局只在一处解析；若未来 Power 需要写 tag，则应优先收紧写入接口而不是继续直读。
2. **Store 的记录结构：Power 全文件读写 `record.power` 字段（源码事实）**。读 `rvPosition`（L86）、`power.*` 计 30 余处（如 L304、L330、L382、L425、L502）；写 `power.generator`（L137）、`batteryWh`/`batteryCapacityWh`/`maxChargePowerW`/`maxDischargePowerW`（L225-L228）、`virtualFuelL`（L296/L395）、`batteries`（L430/L471）、`charger`/`inverter`/效率（L509-L510、L535-L537）、`lastUpdateTime`/`lastSettlementTime`/`generationPowerW`/`state`（L307-L310、L342-L349）、`circuitState`（L249、L635）、`generatorEnabled`（L558）、`sequence`（L232）。这些字段是同仓 schema 的公开结构（[Store.newPower](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:73) 定义，Store 的 `getRecord` 做浅拷贝、`commit` 再做一次拷贝）。判断：**保持直接访问**。给每个字段加 getter/setter 会把一次字段读取变成函数调用，且在 Kahlua 下没有封装收益；真正的风险点不是访问方式而是「谁在什么时候 commit」，而这一点已经收敛在 `commit` + `bump` 两个入口。**若要把 `power` 结构做成跨模块合同，应复制到 shared 常量层声明字段清单，而不是加运行时接口。**
3. **mapping 记录：Power L86 直读 `record.rvPosition`；Devices L235 直读 `record.anchor`（源码事实）**。两者都是调用方传入的 mapping/context 数据，不是某模块的私有 Lua 表。`rvPosition` 由 mapping 记录持久化（[EntryExit.lua:511](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:511)）；`anchor` 则**不在** mapping 记录里——记录只持久化 `generated/locoId/generation/slotIndex/rvPosition/locoPosition` 与 players（[EntryExit.lua:504-513](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:504)），注释明确「anchor、region、bounds、shell edge 读取时从 slotIndex 与编译模板派生」。详见下节。
4. **Devices 读共享模板数据**：`Template.misc.walkAabbs`（L241）与 `TemplateGeometry.isWalkable`（L247）来自 [RV_RoomTemplate](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_RoomTemplate.lua) 与 [RV_TemplateGeometry](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_TemplateGeometry.lua:123)，是 shared 的显式导出接口；shared 不依赖 server，方向正确。
5. **没有发现本目录直接读写其他模块的私有 local 表或闭包变量**（源码事实）：Core、Water、Construction 的调用都经导出函数完成；Power/Devices 也不被其他模块反向 require 内部状态。

### 接口边界问题

- **`Devices.interior` 的 anchor 来源与调用方传入的记录不一致（源码事实 + 条件性推断）**：`interior(record)` 要求 `record.anchor` 是整数表（L235-L239），但两个调用点传入的都是 mapping 记录——`M.scanAll` 由 [RV_UtilityServer.lua:227](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:227) 传 `context.record`，`M.scanTick` 由 L314 传 `mappingRecord`（`currentUtilityRecord` 返回的持久记录）。当前 mapping 记录没有 `anchor` 字段，因此 `interior` 会返回 nil，`scanAll` 直接返回 `false,"RV interior coordinates are invalid"`、`scanTick` 直接返回 false。**条件性推断**：若运行时 mapping 记录确实如源码所示不含 anchor，则设备扫描在当前代码下不产生缓存，负载恒为 0、`deviceCount` 恒为 0；这需要运行时验证才能定为缺陷。**同仓正确写法就在旁边**：Water 用 `RegionSlots.indexToAnchor(integer(record.slotIndex))` 从 slot 派生（[RV_UtilityWater_Objects.lua:35-43](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Water/RV_UtilityWater_Objects.lua:35)），manifest 视图也把 anchor 与 bounds 一起派生（[RV_Server_RecordValidation.lua:35-61](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_Server_RecordValidation.lua:35)）。**建议**：`interior` 改为接收 slotIndex 或 anchor 由调用方显式派生后传入，使「由 slot 派生几何」的规则只存在于一处；同时把 `M.scanAll` 的返回值语义改成反映真实扫描结果，或明确文档化「true 仅代表坐标集可枚举」。
- **同名的 `record` 在同一文件里指两类数据（源码事实，命名问题）**：`bindingFor(identity, record, player)` 的 `record` 是 **Store 账本记录**（读 `record.rvPosition` 走了 mapping 持久字段，L86），而 `M.initializeRecord(identity, context)` 的 `context.record` 是 **mapping 记录**；`settleAndRefreshLoad` 的 `providedRecord`/局部 `record` 又是账本记录。当前两边都只有 `rvPosition` 被读，因此行为一致，但行文上极易误判。**建议**：把几何来源参数命名为 `mappingRecord`/`ledgerRecord`，成本极低。
- **`M.snapshot` 的 `proxyActive` 依赖重解析结果（源码事实）**：L655 经 `boundProxy` 读原生 active，读不到就保持 false，即「读不到」与「确实关闭」在 wire 上不可区分。当前客户端只把它当展示开关，未影响结算；若将来要用它做判断，需要改成三态。
- **`Devices.clear` 是无人调用的清理出口（源码事实）**：缓存按 rvId/generation 键常驻，RV 结束或重生成时代际变更会让旧键不可达，但也永不回收。接入生命周期清理（例如 Core 在记录销毁处）比删除该函数更合理；当前它对功能不是必需。
- **`M.scanAll` 的失败语义（源码事实）**：它忽略 `scanSquare` 的逐格结果，返回的 true 不代表「所有方格都加载成功」；UtilityServer 会把它当成功继续走二次结算（[L227-235](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:227)）。这属于有意容错（未加载方格自然不计负载），但调用方若把它当完整性证明会得出错误结论。

## 函数清单、覆盖和验证记录

- **扫描文件**：RV_UtilityPower.lua（661 行，42 个函数定义：33 个 `local function` + 8 个表方法 + 1 个匿名函数表达式）、RV_UtilityPowerDevices.lua（365 行，22 个函数定义：15 个 `local function` + 7 个表方法）；目录枚举确认除这两个文件外无其他代码文件。
- **函数计数口径**：计入具名函数、`local function`、表方法（`M.foo = function` / `function M:foo()`）与作为参数/回调传入的匿名函数表达式；不计入 `M.foo = localFunction` 这类导出别名赋值。本目录 64 项全部是函数体定义，匿名函数表达式共 1 项（Power `worldAgeHours` 内 L32，单列一行），导出别名 1 项（Power L317 `M.ensureRuntime = ensureRuntime`，不计数）。Power L25、L33、L196、L200、L206、L255、L613 及 Devices L100、L110、L123 等处的 `type(x) == "function"` 是类型判断，不是函数定义，未计数（机械计数时须从含 `function` 的行数中扣除）。
- **逐行交叉核对**：以 `function` 关键字扫描取得全部定义行（Power 33 个 local + 8 个 `function M.*` + 1 个匿名、Devices 15 个 local + 7 个 `function M.*`），再逐行编号读取两份全文（1-661、1-365）核对每个条目的起始行、参数、返回值与副作用；`interior`、`scanSquare`、`resolveDevice`、`settleGeneration`、`maintainNativeProxy` 等长函数按语句逐段确认控制流。
- **跨模块调用扫描**：在 media/lua 全域检索 `UtilityPower`、`UtilityPowerDevices`、`Devices.`、`Power.`、`settleAndRefreshLoad`、`ensureRuntime`、`maintainNativeProxy`、`handleIntent`、`currentLoadW`、`deviceCount`、`proxyActive`、`identityKey`、`classInstance`、`getObjectIndex`、`getWorldAgeHours`、`getGameTime`，确认导出 API 使用面、缓存键统一情况、`M.clear` 无调用点以及 ModData tag 的读写分工；`RV_DevSaveSchemaGate.lua`（旧文档引用的 schema 校验方）在当前 server 树中已不存在，server 侧只剩 [RV_UtilityStore.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:78) 读取 `DEFAULT_CHARGER_EFFICIENCY`/`DEFAULT_INVERTER_EFFICIENCY`、[RV_UtilityServer.lua:309](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:309) 读取 `DEVICE_SCAN_INTERVAL_TICKS` 两个配置消费者。
- **引擎侧核对（只读，不计入本模块函数）**：在反编译基线 `game-decompiled/42.21.0` 确认 `IsoStove.Activated()`、`IsoCombinationWasherDryer.isModeWasher()`、`IsoStackedWasherDryer.isWasherActivated()/isDryerActivated()`、`couldBePoweredByGenerator()`（IsoLightSwitch/IsoRadio/IsoTelevision/IsoStove/IsoClothingWasher/IsoClothingDryer/IsoCombinationWasherDryer/IsoStackedWasherDryer）确实存在，因此设备适配调用的方法名不是猜测。
- **未覆盖项**：没有穷举每个调用点的全部代码路径，也没有审计 Power 目录外模块的内部函数；未运行游戏、服务器或任何测试脚本，静态结论不替代运行时验证；`Devices.interior` 的 anchor 数据形状判断依赖运行时记录内容，已在文中标为条件性推断。
- **修改范围**：仅更新本分析文档与同事务的 shared-Power.md；未修改任何 Lua 源码、配置或测试文件。
