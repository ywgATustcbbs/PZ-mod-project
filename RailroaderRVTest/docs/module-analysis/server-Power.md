# server/RailroaderRV/Power 模块代码分析

## 1. 假设、范围与成功条件

### 假设与范围

- 本报告只把 `media/lua/server/RailroaderRV/Power/` 直接包含的 Lua 文件视为被分析模块；目录清单为 `RV_UtilityPower.lua`、`RV_UtilityPowerDevices.lua` 两个文件。
- 为确认模块调用边界和数据耦合，只读检索了 `media/lua/` 中对这两个模块、其导出方法和 power 记录字段的引用；对公共 helper、存储、schema gate 和 UI 只读取了相关行。
- 函数“必需”判断描述当前代码路径及模块职责，不等同于运行时实测。文件局部函数、模块导出函数、嵌套函数和匿名回调都纳入清单。
- 当前配置文件实际位于 `media/lua/shared/RailroaderRV/Power/RV_UtilityPowerConfig.lua`，不属于本次 server 子目录。

### 成功条件

1. 覆盖目录内每个代码文件及每个函数定义，并说明参数、返回值或副作用、模块语义和当前必要性。
2. 对跨模块复用、拆分建议、跨模块读取 power 内部数据和接口收益给出具体源码位置。
3. 只改写本报告文件；报告内行号可直接在所列源文件复核。

### 只读验证方式

- 文件枚举确认目录内 2 个 Lua 文件。
- 对两个源文件逐段读取完整内容，并用函数定义检索核对清单：共 78 项，Power 文件 54 项（包括内部匿名闭包及嵌套函数），Devices 文件 24 项。
- 使用 `rg` 检索整个 `media/lua/` 的模块引用、导出方法调用、power 字段和通用 helper；对报告所引调用点逐行读取确认。
- 不执行 runtime 测试，也不修改模组代码。

## 2. 文件夹模块职责

| 文件 | 模块职责 |
|---|---|
| `media/lua/server/RailroaderRV/Power/RV_UtilityPower.lua` | RV 电力服务端权威核心：管理虚拟燃油和电池能量结算、断路器状态、发电机代理绑定、玩家物品安装/移除交易、持久化提交、失败回滚及面向调用方的电力快照。 |
| `media/lua/server/RailroaderRV/Power/RV_UtilityPowerDevices.lua` | 设备扫描与状态适配器：从 RV 室内方格识别可供电对象，缓存坐标和原始身份信息，按设备类型读取通电状态并汇总负载；缓存不持有 IsoObject 引用。 |

依赖方向：Power 依赖 shared 常量、Core 存储、Common 世界/API 工具和同目录 Devices；Devices 依赖 shared 常量及 Common 世界/API 工具。Devices 不依赖 Power，二者没有循环依赖。

## 3. RV_UtilityPower.lua 函数清单

源文件共 826 行。以下范围为函数定义/函数体的精确源码行号。参数含义按调用和字段使用解释；返回描述含隐式副作用。

| 函数（源码行） | 输入参数 | 功能、输出/副作用、模块语义 | 当前是否必需及原因 |
|---|---|---|---|
| `invoke`（15–17） | target：Java/Lua 对象；method：方法名；...：方法参数 | 转调 `Util.invoke`，返回调用是否成功及其返回值；统一处理游戏 Java API 调用。 | 是。该文件所有原生对象访问依赖相同失败语义；本地包装本身很薄。 |
| `finite`（19–22） | value：候选数字 | 先转数字，再排除 nil、NaN 和正负无穷；返回布尔值。 | 是。能量、时间和物品流体处理不能接受非有限值。 |
| `identityKey`（24–27） | identity：RV id、generation、bitmapVersion | 将三字段拼成运行时缓存键。 | 是。隔离不同 RV 版本的运行时故障和初始化状态；键算法与公共 Common helper 不同，见第 6 节。 |
| `failClosed`（29–31） | identity | 将该 RV identity 在 `runtimeFaults` 中标记为故障。 | 是。物品/流体补偿状态无法确定时，阻止后续操作继续消耗或生成资源。 |
| `ensureHealthy`（33–38） | identity | 返回 `true`，或 `false, POSTCONDITION_FAILED`。 | 是。将 fail-closed 标记变成后续操作的拒绝门。 |
| `worldAgeHours`（40–62） | 无 | 依次尝试全局 `getGameTime()`、`GameTime.getInstance/instance`，读取非负 world age 小时；失败返回 nil。 | 是。结算必须有可信时间基准。 |
| world-time 匿名回调（50–56） | 无显式参数；闭包捕获 `gameTime` | 受保护地读取 singleton；优先 `getInstance()`，否则读 `instance`。结果交给 `pcall`。 | 是。仅在首选全局 getter不可用时作为 API 兼容读取路径，并限制 Java/Lua 异常传播。 |
| `callSucceeded`（64–66） | target、method、... | 转调 `Util.callSucceeded`，将调用是否成功规范为布尔值。 | 是。用于写入对象/库存 API，并判断其是否明确拒绝。 |
| `objectIndex`（68–71） | object：方格对象 | 读取并转成整数 object index；读取失败返回 nil。 | 是。提供方格内对象定位线索，辅助绑定对象识别。 |
| `objectFingerprint`（73–78） | object | 读取 sprite name，输出 `generator:<name>`；获取失败时 name 为空字符串。 | 是。绑定后重找 generator 时用于防止同坐标替换成不相干对象。 |
| `generatedGenerator`（80–88） | object、identity | 读取对象 ModData 中 RailroaderRVTest 标签，验证 owner、role、rvId、generation、bitmapVersion；返回布尔值。 | 是。确保控制对象由本模组生成且属于当前 RV identity。 |
| `objectAt`（90–107） | identity、binding（坐标及可选指纹）、player | 通过 player 所在 cell、坐标和方格快照，返回符合身份及指纹的 generator 对象或 nil。 | 是。绑定和后续代理操作都需要重新解析世界对象，避免持久保存易失的 IsoObject 引用。 |
| `bindingFor`（109–133） | identity、record、player | 从 `record.rvPosition` 与 generator offset 计算坐标，定位对象、复核其 square 坐标，返回含 identity、token、fingerprint 的 binding。 | 是。初始化发电机代理时建立持久化的可复核绑定。 |
| `readProxy`（135–147） | object | 读取 fuel、max fuel、condition、active 并验证类型/数值；成功返回状态表，否则 nil。 | 是。代理状态未验证前不能安全地切换或维护原生发电机。 |
| `boundProxy`（149–154） | identity、power、player | 按 `power.generator` 重新解析对象并读取状态；返回 object,state，失败返回 nil。 | 是。统一代理重解析和状态校验。 |
| `bindProxy`（156–163） | identity、power、context | 已绑定时返回成功；否则根据 context.record/player 调 `bindingFor`，将 binding 写入 `power.generator`。 | 是。负责持久化绑定字段的唯一内部建立路径。 |
| `restoreItemData`（165–172） | item、新建物品应恢复的 data | 读取目标 ModData，将 data 覆盖到 factory 默认表上；返回布尔值。 | 是。移除电池/组件后重建物品时保留其模组数据并保留未覆盖的 factory 默认值。 |
| `serializableCopy`（174–191） | value、depth、seen | 递归复制字符串/数字/布尔值和有限深度的表；去掉不可序列化值、深度超限项和循环边。 | 是。将物品 ModData 从游戏对象转为可存储的 primitive 数据。 |
| `itemModData`（193–196） | item | 获取并序列化物品 ModData；失败或非表返回空表。 | 是。为存入 power 记录的电池/组件保留物品状态。 |
| `inventoryItems`（198–208） | inventory、result 数组、seen 集合 | 遍历容器及物品嵌套库存，把每项记作 `{item, inventory}`；用 seen 避免循环。 | 是。玩家物品可能嵌套在包/容器内，安装/加油操作需按实际 item id 搜索。 |
| `findInventoryItem`（210–221） | player、itemId | 递归收集玩家库存物品，按 getID 字符串匹配；返回 item 与所属 inventory，未找到返回 nil。 | 是。客户端只给物品提示 id，服务端在权威库存内重新解析物品。 |
| `itemType`（223–226） | item | 返回 full type 字符串，读取失败返回空字符串。 | 是。按完整类型验证 CarBattery 或指定组件类型。 |
| `itemCondition`（228–238） | item | 读取 condition/max/current uses；验证条件范围，返回 condition、maxCondition、夹到 0–1 的 usedDelta；失败返回 nil。 | 是。电池容量/荷电与组件效率从服务端物品状态计算。 |
| `inventoryContains`（240–272） | inventory、target item | 递归确认目标是否存在，返回 true/false/nil；nil 表示查询无法确定。支持对象引用及 item id。 | 是。作为 Add/Remove 后置条件验证基础；nil 会触发 fail-closed。 |
| `inventoryContains.scan`（245–270） | container；闭包捕获 targetId、seen | 遍历容器集合及嵌套库存；找到 target 返回 true，完整扫描未找到返回 false，读取异常返回 nil。 | 是。内部递归步骤，保留三态结果来区分“确实不存在”和“无法验证”。 |
| `removeInventoryItem`（274–281） | found（item+inventory）、identity | 调用 Remove 后重新检查库存；确认移除才成功，无法确认时标记 identity fault。 | 是。所有消耗玩家电池/组件的可回滚事务共用此后置检查。 |
| `addInventoryItem`（283–290） | inventory、item、identity | 调用 AddItem 后重新检查库存；确认存在才成功，无法确认时标记 fault。 | 是。用于回滚或返还物品，避免重复/丢失未被发现。 |
| `createItem`（292–302） | fullType、condition、modData、usedDelta | 通过 InventoryItemFactory 创建，设置 condition/使用量并恢复 ModData；失败返回 nil。 | 是。拆除组件和电池后需重建等价库存物品。 |
| `syncItem`（304–308） | item | 若存在 `syncItemFields` 则调用同步；无明确返回值。 | 条件性必需。帮助把已创建物品字段同步给网络端；native 方法缺失时不构成错误。 |
| `itemHintId`（310–312） | hint | 从表中取 `itemId`，否则取 `id`；非表返回 nil。 | 是。统一客户端提示字段读取，但不信任提示中的物品对象/坐标。 |
| `recomputeBatteryPack`（314–328） | power | 对 battery rows 汇总容量/充放电功率，回写 pack 字段并把 batteryWh 限制在新容量内。 | 是。增删电池后恢复 pack 汇总不变量。 |
| `bump`（330–332） | power | 递增 `power.sequence`。 | 是。标记服务端 power 状态变更，供协议快照识别新状态。 |
| `commit`（334–336） | record、identity | 转调 `Store.commit` 并回传其结果。 | 是。统一该模块的持久化提交入口。 |
| `circuitShouldBeOn`（338–344） | power | 当前为 ON 时只要电量大于 epsilon 就继续 ON；当前为 OFF 时须容量非零且达到重启比例才 ON。 | 是。实现上下电迟滞，避免电量阈值附近反复跳变。 |
| `syncCircuitProxy`（346–359） | identity、power、player | 计算并更新 circuitState；有已绑定对象且 active 不符时 setActivated/sync；返回成功或 API_ERROR。 | 是。把账本中的断路器状态投影到原生发电机代理并同步网络。 |
| `settleGeneration`（361–398） | power、elapsedHours | 按 generatorEnabled、虚拟燃油、充电容量/功率和效率结算电量与耗油；更新虚拟 fuel/battery，返回平均发电 W。 | 是。核心虚拟能量运算，原生发电机燃油不会被当成账本燃油。 |
| `ensureRuntime`（400–419） | identity、record | 检查健康状态和内存初始化标记；初次设置时间、当前负载、发电状态，校准代理，递增 sequence 并提交。 | 是。运行时第一次操作需要建立不追溯计费的基准时间和状态。 |
| `M.beginRuntime`（421–423） | identity、record | 对外转调 `ensureRuntime`，返回成功或失败原因。 | 是。被 Core UtilityServer 定时 tick 调用以按 identity 初始化运行时。 |
| `M.settleAndRefreshLoad`（425–462） | identity、player、可选 providedRecord | 获取 record（若未传入），确保运行时，按两时间戳最大值结算上个采样点负载、虚拟发电和电池输出，校准电路代理、刷新设备负载、更新时间/sequence、提交；返回 true,record 或 false,reason。 | 是。所有周期结算和多种电力操作前的统一账本入口。 |
| `resolveFuelSource`（464–482） | player、hint | 从服务端库存找 item id，验证 fluid container 含纯 Petrol 且 amount 有效；成功返回 found、container、amount、petrol。 | 是。加燃油只能消费服务端实际持有的纯汽油。 |
| `restorePetrolAmount`（484–508） | container、petrol、expectedAmount、identity | 比较当前量，补回缺量并复核精确数量/纯汽油；无法恢复则 fail-closed。 | 是。提交失败或 API 返回异常后，用于汽油流体事务补偿。 |
| `M.addFuel`（510–548） | identity、context、hint | 健康检查、读记录、验证库存燃油，按容量移除流体，复核实际转移量，提交虚拟燃油；失败时恢复流体；成功返回 record、plannedTransfer、confirmedTransfer。 | 是。UtilityServer 直接调用的服务端加油操作。 |
| `isBatteryType`（550–553） | fullType | 判断类型是否属于 Base.CarBattery/CarBattery1/2/3。 | 是。限制电池安装来源类型。 |
| `M.addBattery`（555–593） | identity、context、hint | 从玩家库存解析/验证电池，新增 battery row，按 usedDelta 增加能量、重算 pack、移除实际物品、提交；失败时让物品仍在库存或触发 fail-closed。 | 是。由 `handleIntent` 调用，建立实体电池到虚拟 pack 的权威转换。 |
| `M.removeBattery`（595–633） | identity、context、hint（含 batteryId） | 查找账本电池，按全包荷电比例重建物品并加入玩家库存；删除 row、扣除该电池所占荷电、重算 pack、提交；失败回滚物品，成功同步 proxy/item。 | 是。由 `handleIntent` 调用，支持安全拆卸且尽量维持 pack 荷电比例。 |
| `componentRow`（635–643） | item、expectedType | 校验 fullType、非零 condition、规定最大耐久后返回可持久化组件 row；失败 nil。 | 是。安装 charger/inverter 前把输入物品转换成 schema row。 |
| `installComponent`（645–674） | identity、context、hint、field、fullType | 验证健康、未占槽、服务端物品类型和 condition；消费物品并写入 charger/inverter 与效率，提交；失败时重置字段并返还物品。 | 是。charger/inverter 安装共用交易流程并维护效率字段。 |
| `removeComponent`（676–704） | identity、context、field | 从账本读取组件、重建并放回玩家库存，移除组件并恢复默认效率，提交；失败时撤回新物品。 | 是。charger/inverter 拆卸共用交易与补偿流程。 |
| `setGeneratorEnabled`（706–719） | identity、context、enabled | 先结算当前负载，再更新 generatorEnabled（关闭时清 generationPowerW）、递增并提交。 | 是。启动/停止操作必须先结算旧运行区间。 |
| `M.handleIntent`（721–747） | identity、context、operation、hint | 要求 context.authorized 且 phase READY，按 operation 分派电池/组件/发电机操作；未知操作返回 INVALID_REQUEST。 | 是。Core UtilityServer 的通用电力意图接口，也是内部安装/拆卸函数的入口。 |
| `M.bindGenerator`（749–758） | identity、context | 获取记录、绑定代理、递增 sequence 并提交，返回 record。 | 当前主流程未见静态调用者。作为导出方法可能供动态调用；若确认不做动态接入，可删除或改为内部实现，现有初始化已有 `bindProxy` 路径。 |
| `M.maintainNativeProxy`（760–789） | identity、record | 将代理燃油和 condition 恢复满值，active 对齐 circuitState，必要时 sync，重新读取并验证后返回布尔值。 | 是。UtilityServer 每小时调用，确保原生发电机只表现账本断路器且不消耗原生燃油。 |
| `M.initializeRecord`（791–814） | identity、context | 创建/取记录，设置时间，绑定生成对象，初始化断路器 OFF/发电关闭/发电功率 0，维护代理并提交；成功返回 true,record。 | 是。UtilityServer 在新建 utility 状态时直接调用。 |
| `M.snapshot`（816–824） | record、identity、context | 以 Store.snapshot 生成 power 副本，加缓存设备数和代理 active 状态；返回快照表。 | 是。UtilityServer 广播时调用；是 server 到 UI 的电力快照构造点。 |

## 4. RV_UtilityPowerDevices.lua 函数清单

源文件共 360 行。缓存以 identity 和 primitive 坐标/类型信息为主，不缓存 IsoObject 实例。

| 函数（源码行） | 输入参数 | 功能、输出/副作用、模块语义 | 当前是否必需及原因 |
|---|---|---|---|
| `invoke`（13–15） | target、method、... | 转调 `Util.invoke`，返回调用状态和结果。 | 是。所有设备 native API 访问走同一异常保护方式。 |
| `identityKey`（17–20） | identity | 将 rvId/generation/bitmapVersion 拼成缓存 key。 | 是。将不同 RV 世代的扫描缓存分开；编码与 Common.identityKey 不同。 |
| `instanceOf`（22–27） | object、className | 受保护调用全局 instanceof 并返回布尔值。 | 是。用于按游戏原生类识别设备；现有 Util.classInstance 可复用。 |
| `spriteName`（29–34） | object | 读 object.sprite.name，失败为空字符串。 | 是。对象重新解析时作为身份校验字段。 |
| `objectName`（36–40） | object | 读取 getObjectName；失败时用 IsoObject。 | 是。分类与重解析时兼容非 instanceof 分支。 |
| `containerFor`（42–45） | object、kind | 读取指定类型容器，失败返回 nil。 | 是。冰箱/冷冻柜靠 fridge/freezer 容器分类和读状态。 |
| `booleanResult`（47–50） | ok、value | 仅在调用成功且结果为布尔值时返回值，否则 nil。 | 是。拒绝不明确的设备状态，避免错误地累计负载。 |
| `classify`（52–104） | object | 根据 fridge/freezer 容器或设备原生类输出 deviceType、objectClass、sprite、ratedPowerW；未知对象按 name+sprite 只打印一次并忽略。 | 是。建立类型专属状态读取及耗电额定值的映射。 |
| `poweredCandidate`（106–109） | object | 调用 couldBePoweredByGenerator，仅明确 true 才纳入扫描。 | 是。过滤不受发电机供电的对象。 |
| `readActive`（111–142） | object、deviceType | 按灯、收音机/电视、冰箱/冷冻柜、洗烘设备、炉具对应 API 读取通电状态；未知/读取不明为 nil。 | 是。原生设备类型 API 不同，统一为 tri-state active。 |
| `devicePowerW`（144–166） | object、deviceType、ratedPowerW、circuitOn | 电路关闭返回 0；洗烘组合和堆叠设备按模式/子设备分别计算，否则按 active 返回额定功率或 0；状态不明 nil。 | 是。转换设备状态为结算所需 watt 负载。 |
| `squareCoordinates`（168–177） | square | 读取并整数化 x/y/z；成功多返回坐标，失败 nil。 | 是。扫描缓存要以方格坐标定位。 |
| `objectIndex`（179–182） | object | 读取 getObjectIndex 并整数化；失败 nil。 | 是。扫描及重解析时用于稳定定位同一对象槽位。 |
| `deviceId`（184–187） | device row（x/y/z/objectIndex） | 将方格坐标及 index 拼成缓存 id。 | 是。每方格缓存按对象位置替换及查找条目。 |
| `scanSquare`（189–239） | identity、player、x/y/z | 通过 player 所在 cell 获取方格快照，移除该方格旧项，发现 powered candidate 后分类建 primitive row；若旧 row 类型信息一致，则继承已知状态/功率/解析状态。返回扫描方格成功标记。 | 是。完整扫描与定时增量扫描共用同一缓存刷新入口。 |
| `interior`（241–257） | record（含 rvPosition） | floor RV anchor，并按 interior offset 范围生成所有三维方格坐标；位置无效返回 nil。 | 是。限定设备搜索区域，避免扫描 RV 外世界。 |
| `M.scanAll`（259–269） | identity、record、player | 为 interior 的每个 square 调 scanSquare，cursor 重置为 1；返回坐标有效与否。 | 是。UtilityServer 的用户刷新设备操作直接调用。其 true 表示区域可枚举，不代表每个方格成功加载。 |
| `M.scanTick`（271–285） | identity、record、player | 每 tick 扫描配置数量方格并循环 cursor；区域无效返回 false，否则 true。 | 是。UtilityServer 周期性增量发现对象，避免一次扫描整个室内。 |
| `resolveDevice`（287–310） | identity、device cache row、player | 重新读取该坐标方格，并按 objectIndex、poweredCandidate、class、sprite、type 重新定位对象；返回当前 IsoObject 或 nil。 | 是。缓存不持对象引用，需要使用时向当前 world cell 解析。 |
| `M.refreshStates`（312–327） | identity、player、circuitOn | 遍历缓存逐项解析对象并刷新 resolved；状态可读则更新 lastKnownPowerW、active、stateKnown。 | 是。Power 结算前后用其采样当前负载状态。 |
| `M.resolveCached`（329–334） | identity、player | 只刷新缓存项的 resolved 标记，不重采 watts。 | 是。Power 在按上次采样点结算前先排除已卸载/删除对象。 |
| `M.currentLoadW`（336–346） | identity | 对已解析、状态已知且 active 的缓存设备合计 lastKnownPowerW 或额定功率；返回 total,count。 | 是。Power 用 total 计算电池输出功率；count 当前 API 同时可用于调用方诊断。 |
| `M.count`（348–352） | identity | 返回该 identity 的缓存设备条目数，含当前未解析条目。 | 是。Power.snapshot 将其公开为 deviceCount。 |
| `M.clear`（354–359） | identity | 删除该 identity 的 cache 和 scan cursor。 | 当前没检索到仓内调用者。对当前缓存消费路径不是必需入口；作为 lifecycle 清理接口有益，避免旧 generation 缓存常驻，需在生命周期调用后才发挥作用。 |

## 5. 模块间职责与调用接口

### 5.1 已有公开边界及调用点

| 提供者 → 调用者 | 已见调用点 | 传递的数据及职责 |
|---|---|---|
| Core.UtilityServer → Power | `RV_UtilityServer.lua:300–304, 306–314, 322–343, 406–407, 427, 437, 445, 472` | 在命令处理、tick、十分钟结算、小时维护和记录初始化期间调用 Power 导出函数。UtilityServer 将身份、授权 context、operation/hint、player 或 store record 传入，不读取 battery/charger 内部字段。 |
| Core.UtilityServer → Devices | `RV_UtilityServer.lua:309–310, 407` | 用户刷新时全量扫描；定时 tick 增量扫描。 |
| Power → Devices | `RV_UtilityPower.lua:443–455, 818` | 结算时解析 cached objects、读写负载状态、汇总当前瓦数；快照时读取设备数量。调用均经过 Devices 的导出 API，不读取其私有 caches/scans。 |
| UtilityServer → Power 快照 → client UI | `RV_UtilityServer.lua:186–190`；`RV_UtilityDashboard.lua:251, 317–320, 361–408, 444, 479–484` | Power.snapshot 的电力状态通过 Store.snapshot 和 sendServerCommand 发给 UI。UI 消费电池、燃油、发电机、断路器、负载、效率、设备数量、proxy 状态等字段。这些字段是外部 wire contract，变更需同时更新客户端。 |
| Power → Store | Power 文件行 334–336、428–430、513–514、558–559、598–599、648–649、679–680、750–757、792–793、816–818 | 使用 Store 提供的 getRecord/commit/snapshot。Power 不直接接触 ModData root 的私有保存路径。 |

### 5.2 可复用函数与抽取建议

| 重复/候选能力 | 具体位置 | 建议与收益评估 |
|---|---|---|
| RV 身份 key | Power.lua:24–27；PowerDevices.lua:17–20；Core/RV_UtilityServer.lua:20–23；Water/RV_UtilityWater_Commands.lua:18–21。Common 已有 `Common.identityKey`（Common/RV_Common.lua:124–134），ServerUtil 在 RV_ServerUtil.lua:97 暴露别名。 | 推荐统一调用现有 `Util.identityKey(rvId,generation,bitmapVersion)`，避免多处复制，并利用长度前缀编码避免分隔符碰撞。需要保持 key 的字段集合一致；各模块的 map 是私有的，改变编码不影响持久化字段。 |
| protected object API 调用 | 两文件的 `invoke`：Power.lua:15–17、Devices.lua:13–15；已有 Common.invoke（Common/RV_Common.lua:7–15），UtilityPower 两模块实际由 ServerUtil 提供。 | 可直接使用 `Util.invoke`，或保留薄包装以缩短调用；独立新增通用模块收益很低。 |
| callSucceeded 与有限数值 | Power.lua:19–22、64–66；Common.callSucceeded 和 Common.isFiniteNumber 在 Common/RV_Common.lua:17–20、67–70。 | 已有公共能力足够。Power 的 finite 还主动执行 `Util.toNumber`，可以按参数实际类型组合既有转换和 finite helper；不值得另建 API。 |
| instanceof 防护 | Devices.lua:22–27；Common.classInstance 在 Common/RV_Common.lua:50–55。 | 可替换为已存在 helper，减少重复的 protected global 调用；行为一致性收益清楚，代码量收益较小。 |
| object index 读取 | Power.lua:68–71 与 Devices.lua:179–182 内实现相同的 getObjectIndex→integer 流程；其他 server 子系统也有相似模式，例如 Water_Objects.lua:89、Mapping.lua:356。 | 候选公共 helper，但只有在多个模块确实统一错误处理和返回约定后才抽取；两处函数都很小，为此新增层级单独看收益偏低。 |
| item ModData、安全库存变更、逆向补偿 | Power.lua:165–312、464–508、645–704 | 这是 power 物品交易专属逻辑，Water/plumbing 并不消费库存物品；暂不抽成通用服务更清楚。serializableCopy 的“丢弃不支持值”语义也不同于 Common.copyPlain 的严格报错语义，不能简单替代。 |
| 设备状态适配 | Devices.lua:52–166 | 各设备 getter、额定功率和组合洗烘模式高度领域化；当前没有第二个调用方，不应提到 Common。 |

## 6. 是否应进一步拆分

### RV_UtilityPower.lua

826 行、54 个函数，职责比其余 Power 文件重。内部可见三个相对稳定的区域：

1. 原生 generator 代理解析、绑定、校准和维护：`68–163、346–359、749–789`。
2. 发电/负载/电池结算与运行时初始化：`314–462`。
3. 玩家库存燃油、电池、充电器、逆变器的事务与补偿：`165–312、464–704`。

可以考虑以后把 generator 代理适配器抽成独立文件，并让本文件保留记录事务和结算协调；这会改善文件导航。但现在拆开会让 adapter 与 Power 内部 `power.generator` 结构、提交时机、fail-closed 语义紧耦合，可能产生更多参数/API 和循环依赖。因此**有拆分候选，暂不构成立即必须拆分**。若将库存项处理抽出，也应只在多个子系统要共用后置检查/补偿机制时考虑；目前它只服务 Power。
另可检查并决定是否保留 `M.bindGenerator`：静态仓内搜索未发现调用者；若无动态接入目标，可移除这个未用导出，减少公共表面。

### RV_UtilityPowerDevices.lua

360 行、24 个函数，分类/适配、方格扫描、对象重解析和缓存负载汇总构成同一条闭环，内部私有缓存不对外泄漏。当前无需拆分。若之后设备类型适配大量增长，可把 `classify/readActive/devicePowerW` 与空间缓存扫描拆开，前提是适配器使用稳定描述表接口，而不是共享私有 cache。

## 7. 对其他模块内部数据的直接访问及接口建议

### 7.1 确认到的内部字段访问

- `RV_UtilityStore.lua:227–235` 深拷贝 `record.power`，并在副本上删除电池、charger、inverter 的 `modData` 后生成快照。Store 因此了解 Power 持久化行结构。
- `RV_DevSaveSchemaGate.lua:1191–1215` 将 `value.power` 交给 `validPower` 校验，并在 1214 行直接要求 `record.power.generator` 存在。DevSaveSchemaGate 同样了解 Power 的具体持久化字段。
- `RV_UtilityServer.lua:292–343,405–407` 取出/传递 Store 返回的 record 和 mappingRecord，但未发现它直接读取 `record.power.<field>`。
- Devices 的 `caches`、`scans`、`unknownLogged`，Power 的 `runtimeInitialized`、`runtimeFaults` 都是 local；仓内其他模块没有直接访问这些运行时私有状态。Power 与 Devices 通过明示的 `M.*` 方法交互。

### 7.2 接口边界是否需要调整

- **Store 对 power 持久化结构的访问：现阶段直接访问的收益高于额外 runtime API。** Store 负责当前 schema 的读、写和快照副本；Power 又依赖 Store.getRecord/commit/snapshot。再让 Store require Power 来投影记录会形成反向依赖或 require 环。snapshot 若必须拆出，应移到不依赖两者的中立 schema/projection 模块。
- **DevSaveSchemaGate 对字段的访问：保留当前显式校验更合适。** 它必须在操作前 fail-closed 地拒绝过期/缺字段存档，直接检查 schema 便于审计；调用运行时 Power 接口可能引入加载时序依赖，并把存档有效性判断耦合到玩法模块。若未来要复用，应抽取中立的 declarative schema 定义，而非增加只返回字段的薄 getter。
- **Power → Devices：现有方法接口清晰，值得保留。** Power 消费负载与设备数；扫描缓存细节仍在 Devices 内部，不应由 Power 直接读缓存表。
- **UtilityServer → Power：现有操作接口清晰。** 这些调用通过导出方法进入结算/事务。建议不要让 facade 直接写 `record.power` 字段。
- **client UI → snapshot：这是有意公开的数据协议，不是对 server 私有 Lua 表的直接访问。** 可由 Power.snapshot 继续负责投影；改变字段时同步更新 Dashboard。

## 8. 文件/函数清单与复核记录

| 文件 | 源码行数 | 函数清单数 | 行号覆盖 |
|---|---:|---:|---|
| `media/lua/server/RailroaderRV/Power/RV_UtilityPower.lua` | 826 | 54 | 15–824，包含内部闭包/嵌套函数及导出方法 |
| `media/lua/server/RailroaderRV/Power/RV_UtilityPowerDevices.lua` | 360 | 24 | 13–359，包含所有 local 与 M 导出函数 |

核对项：

- 文件清单以递归文件枚举复核，确认目标目录目前只有上表两份代码文件。
- 函数定义以 `rg -n "\\bfunction\\b|=\\s*function\\b"` 输出为索引，并逐段通读 1–826、1–360 行后把每个定义对照到报告行号；Power 中的 world-time 匿名回调与库存递归 scan 也列出。
- 跨模块搜索覆盖 `media/lua/`，确认 UtilityServer 的静态调用点、UI 使用的 power 快照字段、Store 和 DevSaveSchemaGate 对记录结构的访问；针对文中引用读取对应源码行复核。
- 文档范围仅包含此次 Power 服务端目录的函数明细和必要跨模块引用。其他文件夹的完整模块分析留在其各自模块报告中。
- 未覆盖运行时/联机行为验证；本任务是只读静态分析，且按约束未运行 runtime 测试。

