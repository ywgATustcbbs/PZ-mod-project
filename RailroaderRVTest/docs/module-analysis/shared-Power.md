# Shared / RailroaderRV / Power 模块分析

## 范围与分析口径

- 范围：`contents/mods/RailroaderRVTest/42/media/lua/shared/RailroaderRV/Power/` 下全部 Lua 代码文件，仅此文件夹。
- 文件数：2。逐函数清单包含命名函数、赋值函数、传给 `pcall` 的匿名闭包和配方回调赋值；`P.BATTERY_CAPACITY_FACTOR` 是现有函数的同一引用，不另计一个函数体。
- 依据当前源码解释语义。输入参数和回调生命周期按调用方式及命名推断；没有运行游戏或验证 Project Zomboid 的运行时回调签名。
- 只读核对：列举文件、按行查看两个文件、用函数声明/赋值/匿名函数正则扫描交叉检查，并搜索 Power 相关模块的 `require` 与配置字段引用。未改源码、未运行 runtime 测试。

## 1. 文件夹模块职责

这个文件夹承担共享 RV 电力系统的配置/纯计算，以及共享的可制作电气组件回调注册。服务端会读取其中的配置并执行世界状态逻辑；共享层本身的这两份代码不负责世界对象扫描或服务端权威状态变更。

### `RV_UtilityPowerConfig.lua`

此文件构造局部表 `P` 并以 `return P` 暴露模块接口。它集中保存燃料、发电机、电池、设备扫描/负载、效率及条件值常量，并提供电池参数和制作效率两项纯计算。

配置项按职责分组（均为文件内明确赋值，单位/含义依字段名及注释）：

- 燃料/发电：`FUEL_WH_PER_L=1250`、`GAS_GENERATOR_POWER_W=5000`、`VIRTUAL_FUEL_CAPACITY_L=100`、`NATIVE_GENERATOR_CONDITION_MAX=100`、`IDLE_FUEL_FRACTION=0.10`、`RESTART_CHARGE_FRACTION=0.05`。
- 数值比较与持久化校验：`NUMERIC_EPSILON=0.000001`、`PERSISTED_POWER_TOLERANCE=0.01`。
- 充电器/逆变器默认效率：均为 `0.90`。
- 电池：容量 `720 Wh`，最大充电功率 `250 W`，最大放电功率 `1500 W`；充电和容量共用一条健康曲线，放电使用另一条健康曲线。
- 设备扫描：间隔 `10` ticks，每 tick 扫描 `20` 个 squares。`DEVICE_POWER_W` 为设备类型的功率表：Light 60、Radio 15、TV 100、Fridge 125、Freezer 150、FridgeFreezer 160、Washer 500、Dryer 4500、Microwave 2000、Stove 3000、LuxuryOven 4000（单位字段为 W）。
- 制作质量：基础效率 `0.75`，每级 Electrical 增加 `0.02`，随机偏移范围 `-0.05..0.05`，最终夹在 `0.70..0.98`；`COMPONENT_CONDITION_MAX=1000`。

文件第 2 行还初始化全局 `RailroaderRV`，但本文件后续没有读写该全局；表 `P` 是通过返回值提供给调用者的。该初始化就当前文件计算功能而言没有可见必要性。

#### 函数逐项说明

| 函数 / 行号 | 参数 | 返回值与副作用 | 本模块内语义及必要性 |
|---|---|---|---|
| `P.BATTERY_CHARGE_FACTOR(health)`，19–21 | `health`：预期为 0..1 的电池健康比例。 | 返回 `1 - (1-health)^2`；无副作用。 | 充电功率随健康度变化的曲线。`batteryParameters` 调用它；是当前共享电池参数规则的一部分。函数本身未夹紧输入，规范化由 `batteryParameters` 完成。 |
| `P.BATTERY_CAPACITY_FACTOR`，22 | 无新参数；直接引用 `P.BATTERY_CHARGE_FACTOR`。 | 是同一个函数对象，不产生新闭包。 | 为容量因子提供单独的语义名称，同时复用充电曲线；`batteryParameters` 通过该名称计算容量。当前等式意味着容量与充电功率退化曲线相同。 |
| `P.BATTERY_DISCHARGE_FACTOR(health)`，23–25 | `health`：预期为 0..1 的健康比例。 | 返回 `health * health`；无副作用。 | 放电能力随健康度变化的曲线；由 `batteryParameters` 使用。 |
| `P.batteryParameters(condition, maxCondition)`，51–64 | `condition`：当前电池 condition；`maxCondition`：该电池 condition 上限。 | 参数类型不为 number 或 `maxCondition <= 0` 时返回 `nil`。否则把比值夹在 0..1，返回 `{health, capacityWh, maxChargePowerW, maxDischargePowerW}`；无副作用。 | 把物品 condition 统一换算为电池健康、容量及功率上限。此函数将输入校验、曲线与标称参数集中到共享 API；服务端电力模块和开发存档 schema gate 均实际调用它，因此是避免两边公式漂移的必要共享规则。 |
| `P.craftEfficiency(electricalLevel, randomOffset)`，66–72 | `electricalLevel`：Electrical 等级，转换为数字并夹紧到 0..10；`randomOffset`：随机质量偏移，转为数字，缺失/非法时按 0。 | 返回 `base + level*perLevel + offset`，并夹紧到 0.70..0.98；无副作用。 | 计算组件制作效率，交由制作回调写入新物品 condition。单一公式保证等级贡献与上下界一致；当前制作回调直接依赖它。 |

### `RV_UtilityItems.lua`

此文件依赖 `RV_UtilityPowerConfig`，初始化/复用全局 `Recipe.OnCreate` 表，并注册 Charger 和 Inverter 两个制作回调。回调把按角色 Electrical 等级和随机偏移算出的效率编码进产出物 condition。它从共享常量入口被加载：`Common/RV_UtilityConstants.lua:18–19` 将配置放进 `U.POWER` 并 `require` 本文件以注册回调。

#### 函数逐项说明

| 函数 / 行号 | 参数 | 返回值与副作用 | 本模块内语义及必要性 |
|---|---|---|---|
| `randomOffset()`，6–13 | 无显式参数。 | 若全局 `ZombRandFloat` 是函数，则用配置范围调用并以 `pcall` 隔离异常；成功且结果为数字时返回该值，否则返回 `0`。不改游戏状态。 | 为新组件质量提供可选随机扰动。支持设计中的质量随机性；不是基础制作流程的硬依赖，因为 RNG 缺失/失败时可退回零偏移。 |
| 匿名闭包（`pcall(function() ... end)`），19–21 | 无显式参数；闭包捕获 `craftRecipeData`。 | 闭包返回 `craftRecipeData:getAllCreatedItems()` 的结果；外层 `pcall` 接收成功标志及结果。 | 保护 Java/Lua 桥接调用失败不向外抛出；错误时回调安全退出。它不是独立业务函数，保护边界有价值，但匿名包装本身可由其他等效错误处理写法替代。 |
| 匿名闭包（`pcall(function() return createdItems:get(0) end)`），25 | 无显式参数；闭包捕获 `createdItems`。 | 返回索引 `0` 的产出物；外层 `pcall` 接收成功标志及物品。 | 保护读取第一个产出物的桥接调用。与上一闭包同类，仅该局部调用需要保护；没有证据表明值得为这两个点另建通用抽象。 |
| `createComponent(craftRecipeData, player)`，15–39 | `craftRecipeData`：制作完成数据；代码要求它有 `getAllCreatedItems()`，返回集合须有 `get(0)`。`player`：制作玩家；可选地用于读取 `Perks.Electricity` 等级。 | 无显式返回值。成功取得首个物品后，计算效率并将 `floor(efficiency*1000+0.5)` 通过 `setCondition` 写到物品上；缺少依赖/调用失败时提前退出。等级不可用时默认 0。 | Charger 和 Inverter 共用的制作后处理：把品质/效率持久化到物品 condition，供后续逻辑读取。对两个配方的共同功能是必要的；已正确收敛到一个内部函数。 |
| `Recipe.OnCreate.RVUtilityCharger(craftRecipeData, player)`，41–43 | 同配方回调形参：制作数据及制作玩家。 | 调用 `createComponent`；自身无返回值，效果是可能更新新物品 condition。 | 将共同组件逻辑绑定到 Charger 配方名。注册项是引擎配方回调契约所需；此处包装函数体和另一个回调完全相同。 |
| `Recipe.OnCreate.RVUtilityInverter(craftRecipeData, player)`，45–47 | 同上。 | 调用 `createComponent`；自身无返回值，效果是可能更新新物品 condition。 | 将共同组件逻辑绑定到 Inverter 配方名。注册项必要；单独包装闭包并非业务所需，可考虑让两个键直接引用 `createComponent`，前提是确认引擎允许同一函数直接用作两项回调。 |

回调所用 `Perks`、`ZombRandFloat` 和物品方法均通过全局/对象成员探测及 `pcall` 使用。具体引擎签名未在此项静态分析中另行核验。

## 1.2 模块间调用关系与数据边界

Power 文件夹内部的实际依赖为：

- `RV_UtilityItems.lua:2` 通过 `require("RailroaderRV/Power/RV_UtilityPowerConfig")` 取得配置接口；随后调用 `P.craftEfficiency` 并读取制作随机范围及 condition 标度。
- `RV_UtilityPowerConfig.lua` 不依赖 Power 文件夹内其他文件；它返回 `P`。

与其他文件夹有关、仅限 Power 证据的实际引用：

- `shared/RailroaderRV/Common/RV_UtilityConstants.lua:18` 将同一配置模块赋给 `U.POWER`；第 19 行 require `RV_UtilityItems.lua` 触发配方回调注册。
- `server/RailroaderRV/Power/RV_UtilityPower.lua:5` require 配置，使用 `batteryParameters` 和燃料、电池、epsilon、效率等配置字段。
- `server/RailroaderRV/Power/RV_UtilityPowerDevices.lua:4` require 配置，读取设备功率表及扫描预算（例如第 58–87、153、160–161、277 行）。
- `server/RailroaderRV/Core/RV_UtilityStore.lua:6` require 配置并用默认充电器/逆变器效率初始化数据（第 109–110 行）。
- `server/RailroaderRV/Core/RV_DevSaveSchemaGate.lua:945` require 配置，并用其字段校验组件 condition、燃料/发电上限、电池派生字段及默认效率（第 1121、1143、1149、1167、1177–1188 行）。

## 2. 通用功能与提取机会

- `batteryParameters` 已是跨服务端电力逻辑与 schema 校验共用的纯计算接口；继续保留集中实现，避免重复重建电池字段。底层 charge/capacity 曲线也已通过同一函数对象复用。
- `craftEfficiency` 已把制作效率规则独立于配方回调，`createComponent` 负责物品桥接/写入。当前边界清楚，不需要再提取。
- 两个 recipe 回调内容重复，但只是一行转发；可以直接共享同一回调函数引用，可能省去两个微小闭包。收益有限，且应先确认回调系统对共享函数引用的要求。
- `pcall` 中的两个匿名闭包均是单点 Java/Lua 对象访问保护。它们虽有相似外壳，但操作目标、结果不同，当前代码量不足以支持新增通用“安全调用”层；没有观察到这类帮助函数在本文件夹内重复使用的证据。
- `randomOffset` 是制作域的窄小辅助函数。没有本范围内的跨模块复用证据，不建议抽成全局工具。

## 3. 是否进一步拆分

现有两个文件按职责已分开：一个是全电力系统共用常量/纯公式，另一个是物品制作回调与物品写入。当前均较小、引用明确，进一步拆分会增加模块加载与依赖管理成本，没有明显收益。

`RV_UtilityPowerConfig.lua` 同时包含燃料、电池、设备和制作参数，但这些都是同一共享电力系统的权威调参与公式入口，且服务端多个模块按需读取。只有当这些领域出现独立生命周期、独立消费者或显著增长时，再按领域拆分才可能有净收益；这是未来条件，不是当前必须改动。

## 4. 直接访问模块内部数据及接口判断

- `RV_UtilityPowerConfig.lua` 用 `local P` 隐藏局部变量名，再 `return P`；调用方拿到的是模块明确导出的表。`U.POWER` 又将这张表挂到共享常量对象。因此其他模块直接读取 `P.X` / `PowerConfig.X` 是访问公开配置接口，不是绕过 Lua 局部变量访问模块内部状态。
- 已搜索到的外围引用是配置字段读取和 `batteryParameters` 调用，没有发现外围代码改写这些字段。该表本身可变，故接口约定应保持为消费者只读；目前把标量常量再包一层 getter 收益很低，会增加样板且不增强纯数据语义。对于派生数据，已有 `batteryParameters` 函数接口，schema gate 和服务端逻辑共同使用它。
- `RV_UtilityItems.lua` 对全局 `Recipe.OnCreate` 的写入是注册引擎回调的显式接口副作用；两个命名键就是外部配方系统入口。此处不能只保留文件局部函数而不登记回调。
- 当前没有证据显示 Power 代码直接访问其他 Power 文件夹模块的未导出局部变量。模块间边界主要是 `require` 返回值和配方回调注册。

## 静态核对记录

- 文件枚举：`rg --files 'media/lua/shared/RailroaderRV/Power'`，得到 `RV_UtilityPowerConfig.lua`、`RV_UtilityItems.lua`，共 2 个文件。
- 函数候选扫描：`rg --pcre2 -n --glob '*.lua' '(?:^\s*(?:local\s+)?function\s+[\w.:]+|^\s*[\w.]+\s*=\s*function\s*\(|function\s*\()' 'media/lua/shared/RailroaderRV/Power'`，返回 10 个函数体位置；逐行阅读后确认包括 4 个配置函数体、2 个命名内部辅助函数、2 个 `pcall` 匿名闭包、2 个 recipe 回调。第 22 行容量因子是别名，不是新函数体。
- 交叉引用扫描：对 `media/lua` 搜索 `RV_UtilityPowerConfig`、`RV_UtilityItems`、关键函数和配置字段；然后检查 `PowerConfig.*` / `P.*` 读取位置，形成上文调用关系清单。
- 未覆盖项：未检查其他子文件夹的函数实现；仅查看 Power 相关调用点作为边界证据。未运行静态分析器或游戏测试，也未验证引擎回调签名及运行时行为。
- 修改：只新增本模块分析文档；本次范围内 Lua 源码未修改。
