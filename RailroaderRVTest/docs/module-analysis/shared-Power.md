# shared/RailroaderRV/Power 模块分析

## 假设、范围、成功条件与验证方式

- **假设**：只分析模组当前目录 media/lua/shared/RailroaderRV/Power/ 的直接子文件，即 [RV_UtilityPowerConfig.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Power/RV_UtilityPowerConfig.lua)（73 行）与 [RV_UtilityItems.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Power/RV_UtilityItems.lua)（49 行）。行号以本次读取的文件版本为准；这里是 RV 电力系统的共享参数/纯计算与制作回调注册区，同时被 server 与 client 加载。
- **范围**：覆盖上述 2 个文件及其全部具名函数、局部函数、表方法和匿名函数表达式；只读检查跨端消费者以判断共享接口的实际使用面。唯一写入目标为本报告与同事务的 server-Power.md。只读参考 `media/scripts/RV_UtilityPower.txt`（配方 `OnCreate` 绑定与物品定义），不逐函数分析。
- **成功条件**：每个函数都有精确起始行、参数含义、返回值或副作用、模块语义和必要性判断；列出「可提取机会」并明确共享层不得依赖 server helper 这一约束对提取方案的影响；给出拆分判断与接口边界证据。不运行游戏或 runtime 测试。
- **验证方式**：目录文件枚举与逐行编号读取；用 `function` 关键字与赋值扫描取得全部函数体位置后逐行核对；在 media/lua 全域检索两个模块的 require 点、配置字段与回调键的消费点；在 shared 子树检索是否存在对 server/client 路径的 require；对照 `RV_UtilityPower.txt` 的 `OnCreate` 绑定行核对回调键名。源码扫描是静态分析，不替代运行时验证。
- **区分口径**：标「源码事实」的是同仓文件可直接读到的证据（例如消费者位置、要求的字段名）；标「条件性推断」的是依赖运行时行为、未被静态断言覆盖的判断（例如引擎回调签名与执行时机）。

## 目录职责与清单

Power/（shared）目录承担两类职责：一是 RV 电力系统唯一的参数与纯计算来源（燃油热值、发电功率、电池健康曲线、设备额定功率、扫描预算、制作质量），二是充电器/逆变器两个物品的制作完成回调注册。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_UtilityPowerConfig.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Power/RV_UtilityPowerConfig.lua) | 4 | 集中声明电力系统常量与设备功率表，并提供电池参数换算与制作效率两个纯函数（4 个均为表方法：2 个函数表达式 + 2 个 `function P.*` 定义） |
| [RV_UtilityItems.lua](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Power/RV_UtilityItems.lua) | 6 | 注册 RVCharger/RVInverter 制作的 OnCreate 回调，把按 Electrical 等级与随机偏移算出的效率写入产出物 condition（2 个局部函数 + 2 个 pcall 匿名函数 + 2 个表方法） |
| **总计** | **10** | 10 个函数体定义（Config 4 + Items 6）；`P.BATTERY_CAPACITY_FACTOR = P.BATTERY_CHARGE_FACTOR`（L21）是同一函数对象的别名赋值，不计入函数定义数 |

依赖方向（源码事实）：`RV_UtilityItems.lua:2` require shared 配置；`RV_UtilityPowerConfig.lua` 不 require 任何 RV 模块，只写全局 `RailroaderRV`（L2）并返回局部表 `P`。**本目录不 require 任何 server/client 路径**（在 media/lua/shared 子树检索 `RailroaderRV/server`、`RailroaderRV/client`、`RV_ServerUtil`、`RV_Common` 均无匹配），加载方向保持 shared → 无、server → shared。

## 逐文件、逐函数分析

### RV_UtilityPowerConfig.lua

模块无事件注册、无副作用（除 `RailroaderRV` 全局表的空值初始化），L3 建局部表 `P`，L73 `return P` 暴露全部字段。数值常量按用途分组：燃油/发电（L5-L11）、电池与健康曲线（L15-L24）、设备扫描预算与功率表（L26-L40）、制作质量（L42-L48）。这些字段是 server 结算（[RV_UtilityPower.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Power/RV_UtilityPower.lua)）、设备适配（[RV_UtilityPowerDevices.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Power/RV_UtilityPowerDevices.lua)）、账本默认值（[RV_UtilityStore.lua:78-79](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:78)）、扫描节拍（[RV_UtilityServer.lua:309](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:309)）与客户端显示（[RV_UtilityDashboard.lua:359](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:359)）共同读取的权威来源。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| P.BATTERY_CHARGE_FACTOR（L18） | health 预期为 0..1 的健康比例；返回 `1-(1-health)^2`，无副作用。 | **必须**：电池最大充电功率随健康度衰减的曲线；由 `batteryParameters` 在 L55 调用。函数本身不夹紧输入，规范化交给调用方。 |
| P.BATTERY_DISCHARGE_FACTOR（L22） | health 同上；返回 `health*health`，无副作用。 | **必须**：最大放电功率随健康度衰减的另一条曲线；由 `batteryParameters` 在 L56 调用。 |
| P.batteryParameters（L50） | condition 当前耐久、maxCondition 耐久上限；任一非 number 或 maxCondition<=0 返回 nil，否则把比值夹到 0..1 后返回 {health,capacityWh,maxChargePowerW,maxDischargePowerW}，无副作用。 | **必须**：把物品耐久换算成电池容量与充放电上限的唯一公式。server 的三处调用（Power L218 重算电池包、L423 安装校验、L461 拆卸恢复）共享同一结果，若公式分叉会出现「装上与拆下容量不一致」。 |
| P.craftEfficiency（L65） | electricalLevel Electrical 等级（转数字后夹到 0..10）、randomOffset 随机质量偏移（转数字，非法按 0）；返回夹在 `CRAFT_EFFICIENCY_MIN..CRAFT_EFFICIENCY_MAX` 内的基础值+等级贡献+偏移，无副作用。 | **必须**：制作效率的唯一公式；`RV_UtilityItems.createComponent` 依赖它把等级与随机性折算成产出物 condition，server 侧 `installComponent` 又按 `COMPONENT_CONDITION_MAX` 反推效率，两端必须用同一标度。 |

**同文件中的别名与非常量字段**：`P.BATTERY_CAPACITY_FACTOR`（L21）与 `P.BATTERY_CHARGE_FACTOR` 是同一函数对象，`batteryParameters` 通过它计算容量（L54），语义上「容量曲线=充电曲线」是显式选择。`P.LuxuryOven = 4000`（L39）在设备功率表里但 `RV_UtilityPowerDevices.classify` 没有对应分支，属于当前未被消费的条目（与设备适配的新增类型预留一致，无功能影响）。

### RV_UtilityItems.lua

模块 L4 初始化/复用全局 `Recipe.OnCreate` 表，L41/L45 注册两个回调键，L49 `return Recipe.OnCreate` 把该表作为模块返回值。它由 [RV_UtilityConstants.lua:15](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_UtilityConstants.lua:15) 以 `require("RailroaderRV/Power/RV_UtilityItems")` 触发加载（返回值未被使用，加载即注册）。回调键名与 [RV_UtilityPower.txt:37](../../contents/mods/RailroaderRVTest/42/media/scripts/RV_UtilityPower.txt:37)、`:59` 的 `OnCreate = Recipe.OnCreate.RVUtilityCharger/RVUtilityInverter` 逐字对应，产出物类型 `RailroaderRVTest.RVCharger`/`RVInverter` 与 Power L573/L580 安装校验、客户端 Dashboard L292/L300 的物品识别类型一致。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| randomOffset（L6） | 无参数；全局 `ZombRandFloat` 存在时用配置的 `CRAFT_EFFICIENCY_RANDOM_MIN/MAX` 调用并以 pcall 隔离异常，成功且为 number 才返回，否则返回 0。不改变游戏状态。 | **保留理由**：为制作质量提供可选随机扰动；RNG 全局缺失或抛错时回退为零偏移，因此不是基础流程的硬依赖，但去掉会破坏「同配方产出有质量差异」的设计。 |
| createComponent（L15） | craftRecipeData 制作完成数据（要求 `getAllCreatedItems()`），player 制作玩家（可选，用于读 `Perks.Electricity` 等级）；无返回值。成功取得首个产出物后计算效率，把 `floor(efficiency*COMPONENT_CONDITION_MAX+0.5)` 经 `setCondition` 写入物品；依赖缺失/调用失败时提前返回，等级不可用按 0。 | **必须**：两个组件配方共用的制作后处理，把品质持久化到物品 condition，供后续安装时换算效率。它把桥接保护（pcall）与业务计算收敛在一处，两个回调只是转发。 |
| createComponent 中匿名函数（L19） | 无显式参数，捕获 `craftRecipeData`；在 pcall 内调用 `craftRecipeData:getAllCreatedItems()`，返回产出物集合。 | **实现必需**：Java/Lua 桥接调用可能抛错，必须隔离并把成功标志交给外层判断。 |
| createComponent 中匿名函数（L25） | 无显式参数，捕获 `createdItems`；在 pcall 内返回 `createdItems:get(0)`，即第一个产出物。 | **实现必需**：索引 0 的读取同样可能抛错；用同一模式保护，避免回调抛异常打断制作流程。 |
| Recipe.OnCreate.RVUtilityCharger（L41） | craftRecipeData、player，与引擎配方回调形参一致；调用 `createComponent` 后结束，自身无返回值，副作用是可能更新产出物 condition。 | **必须**：`RV_UtilityPower.txt` 的 RVCharger 配方把 `OnCreate` 绑定到该键，缺少注册则充电器不会带质量。函数体与下一项完全相同。 |
| Recipe.OnCreate.RVUtilityInverter（L45） | 同上一项；调用 `createComponent`，无返回值，副作用同上。 | **必须**：RVInverter 配方的 `OnCreate` 绑定键；注册本身必需，但独立函数体不是业务所需（见可提取机会）。 |

**回调契约说明（条件性推断）**：`craftRecipeData`/`player` 的形参顺序与 `getAllCreatedItems`、`getPerkLevel(player, Perks.Electricity)`、`setCondition` 的用法按 B42 常见配方回调约定书写，本报告只核对了本仓脚本绑定与调用形态，未运行引擎验证签名。

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **共享层的硬约束（源码事实 + 约束推论）**：`media/lua/shared` 是 server 与 client 都会加载的路径，`require` 只能指向同样在两端可用的模块。**shared 不得 require server helper（例如 `RailroaderRV/Common/RV_ServerUtil`、`RailroaderRV/Common/RV_Common`、`RailroaderRV/Common/RV_ServerWorld`），server 路径也不应被 shared 反向依赖**——本目录当前没有任何此类 require，这是必须保持的性质。**对提取方案的影响**：任何「把 server 里的通用 helper 提到 shared 以便两端共用」的方案都不成立，因为 server helper 的实现本身依赖服务端 API（`Common.invoke` 的 pcall 访问模式、`ServerWorld` 的 cell/square 访问）。**可行的方向只有相反方向**：把「不含世界访问、不含 API 调用、纯数值/纯表变换」的规则放到 shared，再由 server 单向 require；本目录的 `batteryParameters`、`craftEfficiency` 与 `DEVICE_POWER_W` 正是按这条线划分的。
- **`batteryParameters` 已是正确的共享粒度（源码事实）**：输入是物品耐久两个数，输出是容量与功率上限，没有对象访问；server 三处调用（Power L218/L423/L461）与客户端的字段消费都建立在同一结果上。**结论：保持现状，不要下沉到 server，也不要再加一层 getter。**
- **`craftEfficiency` 与 `COMPONENT_CONDITION_MAX` 构成一对跨端标度（源码事实）**：制作回调写 condition、server 安装时按 `P.COMPONENT_CONDITION_MAX` 校验（Power L491）并换算效率（L510）。二者同处 shared 配置，任何改动必须同时考虑两侧，这是**当前划分正确**的证据。
- **设备额定功率留在 shared、设备状态适配留在 server（源码事实）**：`P.DEVICE_POWER_W`（L28-L40）是纯数据，被 server 适配器消费；`readActive`/`devicePowerW`（Devices L104-L159）依赖 `getDeviceData`、`isModeWasher`、`isPowered`、`Activated` 等引擎对象方法，只在能解析世界对象的一侧有意义。**结论**：不要把设备适配上移 shared；客户端已经通过快照字段 `currentLoadW`/`deviceCount` 消费结果（[RV_UtilityDashboard.lua:385-407](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:385)）。
- **两个配方回调可共用同一函数引用（源码事实，收益有限）**：`RVUtilityCharger`（L41）与 `RVUtilityInverter`（L45）函数体逐字相同，都只调 `createComponent`。可写成 `Recipe.OnCreate.RVUtilityCharger = createComponent` 与 `...RVUtilityInverter = createComponent`，省下两个闭包。**净收益很小**，且要先确认引擎对同一函数作为两个 `OnCreate` 键没有额外要求；**建议保留显式包装**，因为显式形参在当前文件中同时起到文档作用。
- **`randomOffset` 不建议上移（源码事实）**：它只服务本文件的制作回调，全仓没有第二处 `CraftEfficiency` 随机需求；抽成全局工具属于投机扩展。
- **可考虑的 shared 内部收敛**：`RV_UtilityItems.lua` 通过 `P.craftEfficiency` 与 `P.COMPONENT_CONDITION_MAX` 两个字段依赖配置，粒度已经合适；若未来新增第三、第四个可制作组件，应复用 `createComponent` 而不是复制回调体。

### 是否进一步拆分

- **当前不建议拆分**：两个文件合计 122 行、10 个函数（Config 4 + Items 6），职责边界就是「参数与纯公式」对「制作回调注册」，引用方向单一（Items → Config），没有共享可变状态。拆出 `RV_BatteryConfig`/`RV_DevicePowerConfig` 之类只会增加 require 与加载顺序考虑，收益为零。
- **未来拆分条件**：若电力配置出现独立生命周期或独立消费者（例如客户端要单独校验电池曲线、或设备功率表增长到几十项并由不同模块维护），再按「电池与效率公式」/「设备功率与扫描预算」两块拆分才有净收益；这是条件，不是当前必须改动。
- **不建议把 `RV_UtilityItems.lua` 合并进配置文件**：它是注册引擎回调的副作用模块，由 `RV_UtilityConstants` 显式 require 触发加载；把注册逻辑混进纯数据模块会让「加载配置」与「注册回调」两个时机不可分离。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **RV_UtilityPowerConfig**：以 `return P` 暴露整张字段表（L73）。消费者分三类（源码事实）：server 结算与适配（Power L5、Devices L4）、账本默认值（[RV_UtilityStore.lua:78-79](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_UtilityStore.lua:78) 只用两个默认效率）、跨端汇总入口（[RV_UtilityConstants.lua:14](../../contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Common/RV_UtilityConstants.lua:14) 把同一张表挂成 `U.POWER`）。此外 [RV_UtilityServer.lua:309](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_UtilityServer.lua:309) 经 `U.POWER.DEVICE_SCAN_INTERVAL_TICKS` 读扫描节拍、[RV_UtilityDashboard.lua:359](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua:359) 经 `U.POWER.VIRTUAL_FUEL_CAPACITY_L` 读油量上限。**`U.POWER` 与 `P` 是同一张可变表**，因此「消费者只读」是约定而非强制。
- **RV_UtilityItems**：`return Recipe.OnCreate`（L49），同时把两个回调键写入全局 `Recipe.OnCreate` 表（L41、L45）。真正的对外合同是那两个键名与 `RV_UtilityPower.txt` 的绑定行，不是返回值；`RV_UtilityConstants.lua:15` 只 require 不使用返回值。
- **RV_UtilityPowerConfig 的隐藏状态**：无。`local P` 是局部名字，导出后即为公开表；文件内没有缓存或计数器。
- **RV_UtilityItems 的隐藏状态**：只有 `local P`（配置引用）与局部函数 `randomOffset`/`createComponent`；除此之外没有模块级可变状态，回调之间不共享数据。

### 直接读写其他模块的数据

1. **没有发现本目录读取其他模块的私有 local 表或闭包变量**（源码事实）。`RV_UtilityItems` 只读 `P` 的公开字段（`CRAFT_EFFICIENCY_RANDOM_MIN/MAX`、`craftEfficiency`、`COMPONENT_CONDITION_MAX`），`P` 是 `RV_UtilityPowerConfig` 明确 return 的表。
2. **对全局命名空间的写入是显式接口副作用**：`Recipe = Recipe or {}`、`Recipe.OnCreate = Recipe.OnCreate or {}`（L3-L4）与 `RailroaderRV = RailroaderRV or {}`（Config L2）。前者登记引擎配方回调（必需，否则 `RV_UtilityPower.txt` 的 `OnCreate` 找不到函数）；后者只是初始化共享根表，本文件后续没有读写该全局。
3. **反向数据访问：shared 被 server/client 读取，而不是 shared 读取它们**（源码事实）。Power/Devices/Store/UtilityServer 读配置字段、Dashboard 读 `U.POWER`，均属于消费公开配置接口。**边界结论**：本目录没有需要改为接口的直读点；把标量常量再包一层 getter 只会增加样板，不增强「只读配置」的语义。若将来要防止误写，正确做法是约定加注释或冻结字段，而不是逐个加访问器。
4. **没有发现跨端不一致的读取路径**（源码事实）：server 与 client 拿到的都是同一张 `U.POWER` 表（通过 shared `RV_UtilityConstants`），因此不存在「两端各自复制常量导致漂移」的风险；本目录的公式函数 `batteryParameters`/`craftEfficiency` 也只有 server 侧调用，客户端展示的充放电上限直接来自快照字段而不是重新计算。

### 接口边界问题

- **`U.POWER` 与 `P` 双入口（源码事实）**：同一张表既可 `require("RailroaderRV/Power/RV_UtilityPowerConfig")` 直接拿到，也可经 `U.POWER` 访问。两种写法在仓内都真实存在（Devices L4 直连；UtilityServer L309 走 `U.POWER`）。它不是数据泄漏，但会让「配置的规范入口」不明确。建议：新代码统一走其中一个（`U.POWER` 更利于跨端一致性），旧代码不必为此改动。
- **`P.LuxuryOven` 无消费者（源码事实）**：`DEVICE_POWER_W` 中的 `LuxuryOven = 4000` 在 `classify` 里没有对应分支，属于预留条目；保留无害，但不要在文档/代码里把它当作已支持设备。
- **回调注册依赖 require 副作用（源码事实 + 条件性推断）**：`RV_UtilityItems` 的返回值无人使用，注册完全依赖「被 require 一次」；如果未来有人把 `RV_UtilityConstants.lua:15` 的 require 当成冗余删掉，两个 `OnCreate` 键会静默消失、制作出的组件 condition 不再按效率设置。**建议**：在该 require 处保留说明性注释（当前已有「触发注册」的语义位置），不要在重构中移除。
- **`RV_UtilityItems` 导出 `Recipe.OnCreate` 表而非自身 API（源码事实）**：模块返回值是全局注册表，任何 require 它的模块都会拿到这张全局表并可能写入。当前只有 `RV_UtilityConstants` require 且不使用返回值，风险为零；若后续新增消费者，应明确「返回值只读」。

## 函数清单、覆盖和验证记录

- **扫描文件**：RV_UtilityPowerConfig.lua（73 行，4 个函数定义：2 个函数表达式 L18/L22 + 2 个 `function P.*` 定义 L50/L65）、RV_UtilityItems.lua（49 行，6 个函数定义：2 个局部函数 L6/L15 + 2 个匿名函数表达式 L19/L25 + 2 个表字段函数 L41/L45）；目录枚举确认除这两个文件外无其他代码文件，两文件合计 122 行、10 个函数定义。
- **函数计数口径**：计入具名函数、`local function`、表方法（`M.foo = function` / `function M:foo()`）与作为参数/回调传入的匿名函数表达式；不计入别名赋值。本目录 10 项全部计入定义，另有 1 项别名（Config L21 `P.BATTERY_CAPACITY_FACTOR = P.BATTERY_CHARGE_FACTOR`）按口径不计；`type(ZombRandFloat) == "function"`（Items L7）、`type(craftRecipeData.getAllCreatedItems) ~= "function"`（L16）等是类型判断，不是函数定义，未计数。
- **逐行交叉核对**：以 `function` 关键字扫描取得全部定义行（Config 4 行：L18/L22/L50/L65；Items 6 行：L6/L15/L19/L25/L41/L45），再逐行编号读取两份全文（1-73、1-49）核对每个条目的起始行、参数、返回值与副作用；`createComponent` 的控制流与两个 pcall 边界逐句确认。本目录没有含 `function` 字样的注释行，关键字命中数与定义数一致。
- **跨模块调用扫描**：在 media/lua 全域检索 `RV_UtilityPowerConfig`、`RV_UtilityItems`、`U.POWER`、`UtilityConstants`，确认消费者为 server Power/Store/UtilityServer 与 client Dashboard/UtilityClient/ContextMenu；在 media/lua/shared 检索 `RailroaderRV/server`、`RailroaderRV/client`、`RV_ServerUtil`、`RV_Common` 均无匹配，据此确认「shared 不依赖 server helper」当前成立。回调键名与 `RV_UtilityPower.txt:37`、`:59` 逐字比对一致；`permanentlyRemove` 之类的引擎细节不在本报告范围。
- **未覆盖项**：没有穷举每个配置字段的全部读取行，也没有审计 Power 目录外模块的内部实现；未运行游戏、服务器或任何测试脚本，配方回调签名与执行时机未做运行时验证（已在文中标为条件性推断）。
- **修改范围**：仅更新本分析文档与同事务的 server-Power.md；未修改任何 Lua 源码、配置或测试文件。
