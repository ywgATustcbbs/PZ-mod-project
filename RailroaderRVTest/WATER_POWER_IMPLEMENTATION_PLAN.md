# Railroader RV 水电系统完整执行方案

> 状态：本文件是实施前冻结的方案，尚未实施代码。
>
> 本文件不表示已经更新、下载或锁定 Project RV Interior Rebase，不表示已经新增
> RailroaderRVTest 的 Lua/配置代码，也不表示已经完成游戏、联机或运行时测试。

## 1. 本次修订摘要

本方案现在统一采用以下当前规则：

- 水系统只有一个持久化的 canonical `sharedAmount`。中央水箱和每个已连接设备的
  原生 `FluidContainer` 都是它的运行时镜像；设备镜像不构成额外余额，不能互相求和。
- 消费只由已连接设备水量相对上一基线的正向下降计算。容量变化不计作消费。
- 设备注册只来自玩家右键操作、管钳和服务端验证。每次消费预计算前直接遍历当前
  registry，现场生成本轮有效集合；本轮集合不保留到后续调用。
- RV、schema、manifest、mapping 等整体 gate 失败时拒绝整个 RV 操作；普通设备被移除、
  替换或身份失效只清理该设备的登记和基线，继续处理其他设备；重复身份、同一对象多重
  登记和明确跨 RV 占用属于结构性冲突，拒绝当前整轮操作。
- 授权加水在同一受控执行段内先结算已有设备消费，再由服务端计算
  `plannedTransfer`，确认独立物品源容器的 `confirmedTransfer` 后同步增加 canonical
  余额；canonical 增量不来自客户端请求量或计划量。
- 液体范围已经冻结为干净水、污染的水以及仅由两者组成的混合液体；混合沿用经过基线
  核验的游戏原生规则，不自行净化、稀释或选择性提取。
- 低水量多设备同时消费、设备移除/卸载、服务器崩溃和 API 异常造成的少扣、多扣或
  免费用水属于明确接受的产品边界，不引入跨对象事务、崩溃日志、回滚或额度预留。
- 电力继续使用原生发电机作为唯一燃油事实源；本次只同步修订与水系统直接相关的
  文件职责和验收文字。

## 2. 目标、范围与成功条件

### 2.1 目标

未来为 `RailroaderRVTest` 实现一个服务端权威、可持久化、以原生 FluidContainer
兼容原版用水动作的房车水电系统。本文只冻结模型、协议、schema、生命周期、实施步骤和
验收范围，不实施代码或运行游戏。

范围包括：

- 锁定并分析 Project RV Interior Rebase 的可复现上游快照；
- 参考其他供水模组的外部水源/原生容器兼容思路，但在 `RailroaderRVTest/` 内原创实现；
- 管理中央水箱、已连接设备、服务端结算、玩家授权加水和存档持久化；
- 维持 current-schema fail-closed、服务端权限、对象身份、请求幂等和 RV 隔离；
- 保持现有原生发电机电力方案。

### 2.2 成功条件

正常初始化或一次成功结算完成后：

- canonical `sharedAmount` 是有限值，且位于 `[0, capacity]`；
- 中央投影和本轮仍有效、已加载的设备镜像具有相同的 `capacity`、`amount` 和允许的
  `fluidProfile`；
- 一次消费只按 `sum(max(Dprev[id] - Dobs[id], 0))` 影响共享余额；
- 一次授权加水的 canonical 增量只按服务端确认的独立物品源容器实际扣减量
  `confirmedTransfer` 计算；正常成功路径中二者相同；
- 保存/重载继续使用完整 current schema，设备加载后重新建立基线；
- 客户端不能以坐标、对象状态、数量或最终结果改变服务端结算；
- 普通单设备异常不会阻断其他仍有效的设备；无法证明 RV/schema/manifest/mapping 等
  整体结构，或发现结构性身份冲突时，才拒绝整个当前 RV 操作；普通设备失效不触发
  删除测试存档重建。

## 3. 三类设计状态

### 3.1 已确定设计

- `sharedAmount` 是唯一持久化水余额，服务端是唯一权威。
- 已连接设备使用原生 FluidContainer 作为共享镜像，不拥有独立水账本。
- 消费使用设备水量下降公式；多设备超用结果 clamp 到零，不撤销已发生的设备动作。
- 设备必须由玩家手动连接；服务端每次结算现场确认 registry 条目。
- 普通设备失效只影响该设备；整体 gate 失败或结构性身份冲突才拒绝当前整轮。
- tick 和命令入口各自取得一次每-RV 保护，内部 `settleUnderGuard` 在已有保护下完成
  检查、读取、计算、应用和提交，不重复获取或因为调用者持有保护而跳过结算。
- 加水请求在同一保护段内同步完成消费结算、`plannedTransfer` 计算、独立物品源容器的
  `confirmedTransfer` 确认、canonical 入账、镜像和基线更新。
- 设备生命周期使用简单的 `ACTIVE`/`NEEDS_INIT` 状态；未加载、访问异常和服务器重启后
  的登记设备先待初始化，恢复后按 canonical 重建镜像和基线。
- 中央只接受干净水、污染的水及其原生混合物；加水后的 profile 由已有 canonical 组成和
  已确认转入组成共同计算，不能被源 profile 直接覆盖。
- current schema 不迁移、不转换、不兼容旧字段；电力仍由原生 generator 提供燃油事实源。

### 3.2 接受的误差边界

以下不是阻止实施的缺陷，而是本产品取舍：

- 同一结算周期内多个设备的下降总量可以超过中央余额，`newShared` 最终直接为零，
  不回撤设备已经完成的原版动作。
- 设备在移除、方格卸载、服务器崩溃或 API 异常前产生的变化可能少扣、多扣或免费，
  不承诺恢复历史的精确水量。
- 不实现跨对象原子事务、crash journal、事务回滚、额度预留、余额分配或逐项 hook
  原版用水动作。
- 任何有效设备来源的实际水量下降都视为消费，不区分原版动作、其他模组、管理员或
  脚本来源。
- 中央/设备容量变化本身不计作消费；只看设备 amount 的实际下降。
- 极小浮点误差、数学上的负数和超出上限直接 clamp 或抹平，不增加精度账本。
- 普通设备在检查或镜像期间失效时可以被跳过并标记 `NEEDS_INIT`，或在已确认拆除/替换
  后清除登记、基线和运行时引用；不为此回滚其他设备，也不承诺恢复该设备历史窗口。
- 源容器扣减 API 的异常可能造成源容器与 canonical 的少量偏差；不通过事务回滚或日志
  重放精确恢复。

### 3.3 待运行时验证的兼容性

以下内容是实施时必须通过整体运行时测试确认的兼容性，不得把静态 API 推断写成已完成
测试，也不得仅因尚未核验就改换共享镜像架构：

- 各类原生水槽、马桶、浴缸、淋浴、洗衣机和明确登记的第三方设备是否允许安全改写
  FluidContainer 容量、amount、液体组成和相关锁定属性，以及其是否能作为本轮已支持设备；
- 计划使用的 `inputLocked=true`、`usesExternalWaterSource=false` 组合在各设备上的实际
  行为；
- 后台洗衣机或其他异步原版动作是否能被设备水量下降观测覆盖；
- 对象重载、读回同步、设备替换和各类 FluidContainer API 异常的实际表现；
- 具体基线 API、Kahlua 行为、服务器 tick 回调频率、原生液体混合/污染 API、液体类型
  标识、污染表示方式以及 UI 显示方式。

允许的液体范围本身已经是确定设计，不是阶段 A 的产品待决项；只有上述具体 API、标识、
表示和设备兼容性需要基线核验及整体运行时验证。

## 4. 来源、上游锁定与实施门

### 4.1 只读来源约束

- `game-decompiled/42.20.4/metadata.txt` 是版本、BuildID、反编译元数据和复核结果的唯一
  事实源；不能以其他目录猜测或替代 42.20.4。
- `official lua scripts/` 只读，用于 API/脚本 ground truth；不能把静态参考当运行时证据。
- `reference mods/` 只读，仅用于实现思路和配置分析；禁止修改或复制其数据文件。
- `game-decompiled/` 只读，仅用于接口核验和静态分析。
- `modinfos.json` 只允许定向搜索，禁止全量读取或修改。

### 4.2 Project RV Interior Rebase

实施阶段必须将 Project RV Interior Rebase 和 `PROJECTRVInterior42` 依赖放入独立 staging，
记录来源 URL、具体 commit、快照哈希、依赖版本/哈希、文件清单和获取日期。未锁定这些
信息时，不能称为“最新版本”，不能覆盖 `reference mods/`，也不能把上游文件复制到本项目。

上游分析只用于确认原生 generator、FluidContainer、对象身份和相关 API 的实现思路。
本项目水电 schema、服务端结算、注册表和持久化契约以本文为唯一实施依据。

### 4.3 当前实施门

开始代码实施前仍需处理：

1. 工作区若没有规定的 `game-decompiled/42.20.4/metadata.txt`，必须恢复/提供该基线，
   不能静默使用其他版本。
2. 必须锁定上游 Project RV Interior Rebase 与 `PROJECTRVInterior42` 的可复现身份。
3. 必须用官方 Lua/当前基线核验 FluidContainer、容量改写、锁定属性和 generator API，
   最终仍需整体联机运行时验证。

这些是实施前提，不是对本文共享镜像模型的重新设计要求。

## 5. 共享镜像水模型

### 5.1 唯一余额和镜像关系

每辆 RV 有一份服务端水记录：

```text
capacity     = 当前 schema 声明的中央水箱容量
sharedAmount = 唯一持久化的中央共享余额
fluidProfile = 干净水、污染的水及两者原生混合后的组成/污染状态
```

运行时关系为：

```text
central.capacity             = capacity
central.amount               = sharedAmount
connectedDevice.capacity     = capacity
connectedDevice.amount       = sharedAmount
connectedDevice.fluidProfile = fluidProfile
```

中央对象和设备对象均是投影。设备镜像的 amount 不能与中央 amount 相加，不能把多个
设备镜像当作额外储水量；UI 的房车水量显示为 `sharedAmount / capacity`。可以附加显示
设备数量、在线状态和本轮状态，但不重复统计镜像。

设备接入后，服务端计划在能力允许时写入 `capacity`、`amount`、`fluidProfile`，保持
`usesExternalWaterSource=false`，并尝试使用 `inputLocked=true` 防止原生入口绕过授权。
这些属性的具体兼容性属于第 3.3 节的运行时验证项；验证失败时记录稳定错误并跳过该
对象，不以猜测性行为扩展支持范围。

### 5.2 液体组成

中央水箱只接受以下液体：干净水、污染的水，以及仅由这两者组成的混合液体。含有任何
其他液体成分的源容器全部拒绝；不能仅因源容器“包含水”就接收其全部内容，也不从混合液
中选择性提取干净水或污染的水。

干净水与污染的水混合时沿用游戏原生液体混合和污染判定规则，不自行发明净化、稀释阈值
或额外化学模型。具体液体类型标识、原生混合 API 和污染表示方式必须先由规定基线核验，
再通过整体运行时验证；方案不猜测这些 API 的名称或返回值。

`fluidProfile` 持久化并反映混合后的组成/污染状态，中央与设备镜像保持一致。加水后的
profile 必须以结算后已有 canonical 水量及组成，加上本次 `confirmedTransfer` 对应的实际
转入水量及组成，按照经核验的原生规则计算，不能直接用源容器 profile 覆盖整箱。结算、
重载和镜像过程不能把污染水凭空变成干净水；无法解析组成、包含其他成分或原生规则拒绝
的来源不增加 canonical 余额。

### 5.3 容量和未授权变化

`capacity` 是中央和设备镜像的统一上限。容量变化只触发上限规范化，不产生 usage。
设备水量增加、中央容器未经授权增加或中央容器下降，都不改变 canonical balance；结算
完成时服务端把投影重新设置为 canonical 值。中央世界容器没有独立权威地位，未经授权
的直接变化不会成为加水或消费记录。

## 6. 设备注册和生命周期

### 6.1 注册入口

设备注册与水量结算分离。只有以下路径可以增加 registry 条目：

1. 玩家位于当前 RV 内，对水槽、马桶、浴缸、淋浴、洗衣机或明确登记的兼容对象执行
   右键操作。
2. 客户端仅提交连接意图、`requestId`、`sessionNonce` 和目标提示；必须有管钳的事实
   由服务端检查。
3. 服务端重新解析玩家、当前 RV、权限、距离、目标方格、对象类型、FluidContainer
   能力、对象身份、generation 和 RV 归属。
4. 通过验证后服务端生成 `deviceId`，写入 registry 和对象身份标签，按当前
   `sharedAmount` 初始化对象，并在镜像读回确认后建立初始 baseline、标记 `ACTIVE`；连接
   动作不产生消费或加水。写入或读回失败时保留登记但标记 `NEEDS_INIT`，不让该对象参与
   消费统计。

客户端不能直接登记设备，不能提交可信坐标、RV 身份、amount、capacity 或最终结果。

### 6.2 每次结算前的本轮检查

服务端在每次 server tick 的消费预计算前遍历当前 registry，现场生成本轮有效设备集合。
本轮集合只服务于当前顺序调用，不保留到后续调用；必要的设备生命周期状态只通过
registry 的 `status` 或等价的简单运行时标记保留，不引入复杂状态机。

对每个 registry 条目执行：

- 方格未加载：保留 registry 及身份记录，标记为 `NEEDS_INIT`，使已有 baseline 不再
  参与本轮 usage；不因暂时取不到对象而删除，也不追记卸载期间的消费。
- 方格已加载且确认对象缺失、被替换、原 token/fingerprint 不再匹配或身份失效：这是
  普通设备失效，不是整体 schema gate。移除该条目、对应 baseline/snapshot 和运行时引用，
  不追记这一设备的消费，然后继续检查其他 registry 条目。
- 对象重新加载且身份仍匹配，或处于 `NEEDS_INIT` 的对象重新可访问：先按当前 canonical
  `sharedAmount` 写入镜像并读回确认，再建立新 baseline、标记 `ACTIVE`；不把加载前或
  异常窗口的差额算作消费。初始化完成前该设备不参与 usage。
- 本轮检查通过、实际访问设备时又发现对象失效或 API 异常：跳过该设备，标记
  `NEEDS_INIT`，继续处理其他设备；后续恢复时按当前 canonical 重新镜像和建立 baseline。
- 若设备在上次结算后已经消费、但在本轮检查前被确认拆除或替换：清理该设备登记和
  baseline，忽略这部分变化；不要因为移除一台设备而重置其他有效设备的 baseline。
- 重复 `deviceId`、多个登记指向同一对象、明确跨 RV/generation 占用或无法判定 owner：
  这是结构性身份冲突，拒绝当前整轮水操作并返回稳定冲突原因；不猜测保留哪一条，也不
  自动删除或修复冲突条目。它与普通设备失效分开处理。

以上逻辑假定 Lua 顺序调用不会让出执行，不引入假想多线程竞态。tick 入口和命令入口各自
只获取一次每辆 RV 的 `inWaterSettlement` 保护，并覆盖本次检查、读取、计算、应用和提交；
内部结算函数只在已持有保护的前提下执行，不重复获取保护，也不因调用者持有保护而跳过。
保护必须在正常返回和异常退出路径均释放。

### 6.3 移除和重新连接

被确认拆除或替换的设备必须重新右键连接并获得新的 `deviceId`。清理只影响该设备的
registry、baseline/snapshot 和运行时引用，不改变其他设备的 baseline，不把清理动作计作
消费。未加载、暂时访问异常或服务器重启后的登记设备不删除，而是保持 registry 身份并处于
`NEEDS_INIT`；恢复后先镜像 canonical、读回确认并建立新 baseline，之后才重新统计消费。
服务器重启时所有已登记设备从 `NEEDS_INIT` 开始；一个设备的初始化或移除不得重置其他
正常设备的 baseline。

## 7. 消费结算算法

### 7.1 变量和预计算

对每辆 RV：

- `S`：本次预计算开始时 canonical `sharedAmount`；
- `capacity`：current schema 的中央容量；
- `Dprev[id]`：状态为 `ACTIVE` 的设备上一份已提交 baseline；
- `Dobs[id]`：本轮检查后读取到的设备 amount；
- `validLoadedSet`：本轮现场检查得到的、已加载、身份有效且可访问的 `ACTIVE` 设备集合，
  仅存在于本轮顺序调用中；`NEEDS_INIT` 设备不在该集合内。

预计算先将读数复制到普通 Lua 数据结构，只做有限性和边界处理，不写 FluidContainer，
不发送网络包，不改变世界对象：

```text
usage     = sum(max(Dprev[id] - Dobs[id], 0))
newShared = clamp(S - usage, 0, capacity)
```

设备 amount 上升不形成加水；设备容量变化不形成 usage。只有 `validLoadedSet` 中拥有
可比较 baseline 的设备参与本轮 `usage`。新连接、重载或异常恢复的设备先镜像并建
baseline，从下一次观察开始统计下降。中央对象的读数不参与 `S` 的推导；`S` 始终来自
持久化 canonical record。

### 7.2 应用顺序

一次正常 server tick 由入口取得一次 RV 保护，然后调用只假定保护已存在的
`settleUnderGuard(rv)`，按以下顺序执行：

1. 在保护内验证 manifest、mapping、generation、bitmap、water schema、RV identity 和
   当前结构关系。整体 gate 失败时拒绝整个 RV 操作并提示删除测试存档重建；普通设备
   失效不在此处升级为 schema 错误；结构性身份冲突拒绝当前整轮并返回冲突原因。
2. 遍历 registry，生成本轮 `validLoadedSet`，同时按第 6.2 节处理未加载、普通失效、
   `NEEDS_INIT`、重载和结构性冲突。普通设备被跳过或清理不使整轮失败。
3. 从 canonical record 读取 `S`，读取本轮有效设备的 `Dprev/Dobs` 副本；重载、初次连接
   或恢复中的对象先按 `S` 初始化镜像并建立 baseline，不把旧读数纳入 usage。
4. 计算并提交本轮 canonical 目标：

   ```text
   usage     = sum(max(Dprev[id] - Dobs[id], 0))
   newShared = clamp(S - usage, 0, capacity)
   ```

   该计算只使用普通 Lua 副本；canonical record 的 `sharedAmount` 提交值就是 `newShared`，
   不是中央对象或设备读回值推导出的其他数值。
5. 将中央投影设置为 `capacity/newShared/fluidProfile`，并对本轮仍可访问的有效设备
   设置同一镜像。canonical record 的提交/保存是整轮关键步骤；若 record 的 canonical
   提交或保存失败，整轮报告失败，不让任何设备读回反向改写 canonical。中央和设备对象
   都只是投影；中央投影本身的写入/读回异常不得改变 canonical，设备写入/读回失败按
   单设备规则处理，均不增加精确恢复机制。
6. 对每个设备单独读回，验证 finite、下限、上限、amount/profile 是否符合刚写入的镜像。
   读回只用于确认镜像写入并更新该设备 baseline：验证成功的设备标记 `ACTIVE`，其
   baseline 对应本轮已提交的 `newShared`；写入或读回失败的设备标记 `NEEDS_INIT` 并跳过。
   单个设备失败不改变 `newShared`，不阻断其他设备。
7. 更新 `sequence`、RV 状态、成功验证设备的 baseline，保存 current record，并广播服务端
   快照。保存/广播失败按现有服务端错误处理；任何读回结果都不得重新计算或覆盖已提交的
   canonical `sharedAmount`。

镜像一致性只要求在成功初始化或结算完成后成立，不要求原版动作正在修改设备容器的
任意瞬间都与中央投影一致。未加载对象不执行不存在的对象写入；重载或异常恢复后按当前
canonical 余额建立镜像和新 baseline。中央/设备投影的读回永远是验证方向
`canonical → mirror`，不是反向余额来源。

### 7.3 异常处理

普通对象失效或 API 读写异常的目标是跳过问题设备、标记 `NEEDS_INIT`（确认拆除/替换时
则清理其 registry、baseline 和运行时引用），让其他有效设备继续结算；对象恢复并再次
通过身份检查后，按当前 canonical `sharedAmount` 重新镜像并建立 baseline。不承诺恢复
被跳过设备在历史窗口中的精确消费，也不因设备恢复而重置其他设备 baseline。

服务端不实现 crash journal、PREPARED/COMMITTED 记录、跨对象回滚、跨区块持久事务或
服务器崩溃后的历史重放。运行时异常造成的少扣、多扣或免费用水按第 3.2 节处理，
canonical 余额每次落盘仍保持有限且有界。

`settleUnderGuard` 不获取或释放 RV 保护，也不通过“发现当前调用者已持有保护”来跳过
结算；保护的获取和释放只由 tick/命令入口负责。入口必须在正常返回和异常退出路径均
释放保护，避免异常后该 RV 永久无法结算。

## 8. 授权加水：同步结算和入账

### 8.1 服务端入口

中央水箱增加水量只有服务端授权的 `ADD_WATER` 请求。V1 的加水源只能是玩家持有、经
服务端重新解析和验证的独立液体物品容器。中央世界投影以及任何 RV 的已连接设备镜像
都不能直接作为加水源；玩家可以先通过正常游戏动作把水取入独立物品容器，再发起本请求。
请求入口先取得一次该 RV 的保护，随后在同一受控执行段中按以下顺序完成：

1. 在保护内验证玩家在线身份、权限、当前 RV、距离、阶段、`requestId` 幂等性，并由服务
   端重新解析源容器。源容器必须是玩家持有的独立液体物品容器，实际存在且可读；中央
   投影和已连接设备镜像明确拒绝作为 source。验证液体组成只能接受干净水、污染的水及
   仅由两者构成的混合物，含其他成分或无法解析时拒绝。
2. 在同一保护段内调用第 7 节的 `settleUnderGuard`，先结清请求前已经发生的设备消费，
   得到 `settledShared`，并同步当前可用设备镜像和 baseline。普通设备被跳过或标记
   `NEEDS_INIT` 不等于结算失败；只有整体 gate、结构性身份冲突或 canonical 关键步骤
   失败时，才停止本请求，不扣源、不增加 canonical。
3. 读取结算后的剩余容量和服务端观察到的源容器可用量，计算计划转移上限：

   ```text
   freeCapacity    = max(capacity - settledShared, 0)
   sourceAvailable = clamp(actualSourceAmount, 0, sourceLimit)
   plannedTransfer = min(freeCapacity, sourceAvailable)
   ```

   `sourceLimit` 和 `actualSourceAmount` 均由服务端从独立源容器读取；客户端提交的请求
   数量只作为意图，不能直接计入 canonical 余额。`plannedTransfer` 只是上限，不是已经
   发生的转移。
4. 按 `plannedTransfer` 请求源容器扣减，并由服务端读回/确认本次实际扣减量
   `confirmedTransfer`。它必须表示独立源容器实际减少的数量，并限制在
   `[0, plannedTransfer]`；无法确认有效扣减时不得凭请求量或计划量虚构入账。正常成功
   路径中源容器扣减量与 `confirmedTransfer` 相同。
5. 只有在确认扣减后，才按 `confirmedTransfer` 增加 canonical `sharedAmount`，并用结算后
   已有水量/组成与本次实际转入水量/组成，调用经基线核验的原生混合和污染规则更新
   `fluidProfile`：

   ```text
   finalShared = clamp(settledShared + confirmedTransfer, 0, capacity)
   ```

6. 将中央和本轮仍有效、已加载的设备同步为
   `capacity/finalShared/finalFluidProfile`，逐个读回验证并更新成功设备 baseline；写入或
   读回失败的设备标记 `NEEDS_INIT`，不回写或反向改变 canonical。更新 `sequence` 和
   `state`，按现有机制保存并返回结果。

正常成功路径中，源容器扣减量、`confirmedTransfer` 和 canonical 增量一一对应；API
异常允许少量误差，不因此增加事务系统，也不依据请求量或 `plannedTransfer` 补记。源
容器、液体组成或原生混合验证失败时不增加余额；若源容器已经发生无法确认的异常扣减，
按已接受误差边界处理，不回滚或重放。

### 8.2 顺序和幂等

同一 tick 内多个不同合法请求各自取得同一 RV 保护，并按到达顺序依次执行；后一个请求读取前一个
请求完成后的 canonical 余额和源容器状态。重复 `requestId` 返回首次结果，不再次扣源、
不再次入账。客户端断线重连后必须使用新 `sessionNonce`；旧 nonce 拒绝。

中央世界容器只是 canonical record 的投影。未经授权的中央增加不改变余额，结算时被
镜像覆盖；未经授权的中央下降也不作为设备 usage，且中央投影不能作为 `ADD_WATER` source。
`settleUnderGuard` 不再次获取保护；命令入口无论正常完成、整体失败还是异常退出都必须
释放已取得的保护。

### 8.3 加水顺序核对例

必须用以下例子检查实现顺序：

```text
旧 sharedAmount = 100
设备旧 baseline = 100
设备已经消费到 90
授权加水请求的源容器可提供 20
```

请求先执行消费结算：`usage=100-90=10`，所以 `settledShared=90`。结算后剩余容量若
足够，服务端计算 `plannedTransfer=20`；源容器实际扣除并确认 `confirmedTransfer=20`，
最终 `sharedAmount=90+20=110`。中央镜像、当前设备镜像和新 baseline 都是 `110`。

实现不能直接把旧余额覆盖为 `120` 而漏记消费，不能把 `plannedTransfer` 当作已确认扣减，
也不能只抬高设备 baseline 把加水误记为消费。

## 9. 持久化和 current schema

### 9.1 水记录

每辆 RV 的 current water record 只声明以下顶层字段：

```text
water = {
  schemaVersion,
  capacity,
  sharedAmount,
  fluidProfile,
  registry,
  previousSnapshot,
  sequence,
  state
}
```

字段含义：

- `schemaVersion`：当前唯一支持的水系统版本；
- `capacity`：有限、非负的中央容量；
- `sharedAmount`：唯一持久化余额，始终 clamp 到 `[0, capacity]`；
- `fluidProfile`：只由干净水、污染的水及两者混合组成的当前液体/污染摘要；具体类型
  标识和污染表示按规定基线核验的原生表示保存；
- `registry`：服务端验证并登记的设备条目；
- `previousSnapshot`：按 `deviceId` 保存的设备 baseline 和生命周期可用性；只有 `ACTIVE`
  设备 baseline 参与下降结算，`NEEDS_INIT` 不参与；
- `sequence`：服务端生成的单 RV 单调序列；
- `state`：`READY`、`WAITING_FOR_OBJECTS` 或受控 `DEGRADED` 等当前状态。

`registry[deviceId]` 至少包含：

```text
{
  deviceId,
  deviceType,
  rvId,
  generation,
  bitmapVersion,
  x, y, z,
  objectToken,
  objectFingerprint,
  registeredSequence,
  status
}
```

`status` 只使用简单的 `ACTIVE` 或 `NEEDS_INIT`（以及实现所需的等价稳定标记）。
`NEEDS_INIT` 表示登记仍然有效但暂时不能用旧 baseline 统计消费；恢复后必须先按当前
canonical 写入并验证镜像、建立新 baseline，再回到 `ACTIVE`。确认拆除、替换或身份失效
的普通设备则从 registry 和 `previousSnapshot` 清理，不以 `NEEDS_INIT` 永久保留。

客户端提供的目标提示不能写成可信身份；坐标、generation、token、fingerprint 和序列均
由服务端产生或验证。运行时的本轮有效集合、重入标记和对象引用不属于持久化 schema。

### 9.2 保存、重载和 schema gate

设备原生 FluidContainer 和中央世界对象是否由游戏对象系统保留，属于运行时兼容性验证项；
无论对象层如何保存，它们都不是 canonical 余额。服务端保存 `sharedAmount` 后，在成功
初始化、重载或结算完成时重建镜像。服务器重启读取合法 current record 后，所有已登记设备
都先置为 `NEEDS_INIT`，不能使用重启前 baseline；对象可访问后先镜像当前 canonical 并建立
新 baseline，再恢复消费统计。

以下任何情况都立即拒绝当前 RV 水电操作，并明确提示“开发版本存档不兼容，请删除该
测试存档并重建”：

- water record 缺失、版本不一致、字段别名、部分写入、未知字段结构或类型错误；
- `capacity/sharedAmount/fluidProfile/registry/previousSnapshot/sequence/state` 不完整，
  或无法证明属于当前 RV；
- RV 级 `rvId/generation/bitmapVersion`、manifest、mapping、shell ledger、异步身份或
  其他整体 identity 不匹配；
- 使用旧 bounds、旧 bitmap、旧 mapping、旧 generation 或其他非当前 identity。

单个 registry 条目的对象已经拆除、被替换、原 token/fingerprint 不再匹配，属于第 6 节
定义的普通设备失效：只清理该条目的登记、baseline/snapshot 和运行时引用，继续结算其余
设备，不触发上述存档重建提示。重复身份、同一对象多重登记或明确跨 RV 占用属于结构性
身份冲突，拒绝当前整轮并返回稳定冲突原因；不得把它静默当作普通设备清理，也不得猜测
自动修复。

只允许完全空的新容器按当前 schema 初始化；不提供自动迁移、转换、别名、fallback、旧
字段兼容或自动删除/修改旧存档。异常运行数值仅按 finite/clamp 规则处理，不构成旧数据
迁移。

### 9.3 不做崩溃恢复

本系统不保存 crash journal，不回放服务器崩溃前未完成的对象操作，不跨区块卸载建立持久
事务。重启后只读取完整 current record，以持久化 `sharedAmount` 为设备重载镜像并建立
新的 baseline；这不承诺补回崩溃窗口中的精确消费或加水。服务器重启只重置设备生命周期
状态为 `NEEDS_INIT`，不重置其他 canonical 字段，也不自动迁移或修复存档。

## 10. 服务端协议和客户端职责

### 10.1 请求字段

客户端只提交操作意图和服务端可重新解析的目标提示：

```text
{
  requestId,
  sessionNonce,
  operation,
  targetHint,
  sourceHint
}
```

连接操作使用 `CONNECT_WATER_DEVICE`；加水操作使用 `ADD_WATER`。`targetHint/sourceHint`
只用于定位玩家点击的对象或源容器，不能作为可信坐标、RV identity、amount、capacity、
usage、fluidProfile 或最终结果。`ADD_WATER` 的 `sourceHint` 必须重新解析为玩家持有的
独立液体物品容器；中央投影和任何已连接设备镜像不属于合法 source。

### 10.2 服务端处理顺序

服务端 facade 的 tick 入口和命令入口分别对当前 RV 获取一次保护，并将对应完整流程置于
保护内：

1. 从权威玩家对象或当前 tick 上下文解析 RV、权限、位置、阶段和完整 identity；
2. 获取该 RV 的一次性保护；保护获取失败返回稳定 busy reason，不进入内部结算；
3. 在保护内验证 manifest、mapping、water/power schema、generation、对象标签、nonce 和
   request 幂等性。整体 gate 失败拒绝整个 RV 操作并提示重建；普通设备失效交给第 6 节
   清理，不升级为 schema 错误；结构性身份冲突拒绝当前整轮；
4. 对目标和源容器只使用服务端重解析结果。`CONNECT_WATER_DEVICE` 按第 6 节登记、
   镜像并建立 baseline；`ADD_WATER` 按第 8 节先调用已有保护下的 `settleUnderGuard`，
   再计算 `plannedTransfer`、确认 `confirmedTransfer`、入账并同步；
5. 检查 canonical amount/capacity/profile、registry identity 以及各设备镜像读回。设备
   写入或读回失败只标记 `NEEDS_INIT`，不能反向覆盖 canonical；
6. 保存 current record，广播服务端快照/稳定错误码，正常应用后返回 ACK；无论正常、整体
   失败还是异常退出，入口都必须释放保护。

内部 `settleUnderGuard` 假定调用者已经持有保护，不再次获取、不检查“当前调用者已持有
保护”来跳过结算，也不负责释放入口保护。单个普通设备被跳过不等于整轮失败；只有整体
gate、结构性冲突或 canonical 关键步骤失败才停止本轮。重复请求最多应用一次；权限失败、
缺少管钳、目标未加载、对象不兼容、身份冲突、容量不足、源容器不足和 schema 要求重建都
使用稳定 reason code。

### 10.3 客户端职责

客户端负责：

- 在房车内对候选设备显示连接菜单和管钳提示；
- 生成 `requestId`、维护 `sessionNonce`、发送连接或加水意图；
- 接收 water/power snapshot、设备状态和错误码；
- 显示 `sharedAmount/capacity`、液体 profile、设备数量/状态和 generator 状态；
- 播放提示、动画和 UI 表现。

客户端不得直接写中央/设备 amount、capacity、profile、锁定属性、registry 或 generator
fuel，不得以本地 FluidContainer、坐标或 UI 计算结果替代服务端余额。

## 11. 电力方案（保持不变）

V1 电力以原生 `IsoGenerator` 为唯一燃油和 condition 事实源：

- 原生 generator 保存 fuel、condition、连接和开关状态；自定义 power record 不保存可
  独立消费的第二份燃料余额。
- 服务端只保存 generator 身份绑定、RV/generation、回路状态、设备策略和序列；不把
  fuel/condition 镜像成另一份可消费余额。
- 客户端提交启动、关闭、连接、维修等意图；服务端验证玩家、权限、范围、目标身份、
  fuel/condition 和请求阶段后调用原生 API。
- generator 替换、拆除、跨 RV 绑定或身份不匹配时拒绝操作，不静默重绑定。
- 虚拟电池、独立电量账本和电池到回路注入不属于当前 schema；以后必须获得明确授权并
  升级 schema，不能在现有字段上添加兼容分支。

## 12. 文件职责和分阶段实施

本阶段只维护本方案文档。以下是未来实施的最小文件范围，不现在创建或修改这些 Lua
文件；实现过程中只做与水电直接相关的最小改动。

### 阶段 A：锁定来源和契约

- 在独立 staging 获取 Project RV Interior Rebase 可复现快照，记录 URL、commit、哈希、
  依赖哈希、日期和文件清单。
- 只读核验 official Lua、42.20.4 基线和参考模组；不能复制数据文件。
- 冻结 water/power schema、device catalog、reason code、server tick 结算频率和协议字段。
- 液体范围在本方案中已经冻结为干净水、污染的水及仅由两者组成的混合物；阶段 A 只核验
  规定基线中的具体类型标识、原生混合/污染 API 和 profile 表示，不重新选择允许范围，
  也不猜测未核验的 API 行为。

### 阶段 B：共享定义和设备目录

拟新增或修改：

- `media/lua/shared/RailroaderRV/RV_UtilityConstants.lua`：schema 版本、操作名、reason
  code、有限性和 clamp 常量、server tick 结算契约；不声明额外的 registry 周期任务。
- `media/lua/shared/RailroaderRV/RV_UtilityCatalog.lua`：支持设备目录、FluidContainer 能力
  要求、干净/污染水 profile 规则和待验证的锁定属性；未通过运行时验证的设备不能列入
  本轮已支持目录。
- `media/lua/shared/RailroaderRV/RV_Constants.lua`：挂接 utility schema 与 RV identity。

### 阶段 C：服务端存储和结算

拟新增：

- `RV_UtilityStore.lua`：current water/power record、严格 schema gate、空容器初始化、
  序列和持久化 snapshot。
- `RV_UtilityWater.lua`：连接验证、registry 现场检查、`ACTIVE/NEEDS_INIT` 生命周期、
  `settleUnderGuard` 消费预计算、canonical→镜像应用、独立物品源验证、
  `plannedTransfer/confirmedTransfer` 加水和有限性 clamp。
- `RV_UtilityPower.lua`：原生 generator 绑定、回路状态和意图验证。
- `RV_UtilityServer.lua`：facade、每-RV 保护获取/释放、nonce、幂等、协议路由、快照广播
  和 OnTick 调度；内部结算不得再次获取保护。

拟修改：

- `RV_Server.lua`：单点注册客户端命令、OnTick、current schema gate 和 utility facade；
- `RV_ServerSchema.lua`：把 utility identity 与现有 manifest/bitmap/mapping/generation gate
  串联；
- `RV_ServerWorld.lua`：仅补充读取、标记和同步已登记对象的最小原语；
- `RV_RailroaderServer.lua`：提供当前 RV/玩家/机车权威身份适配，不读取客户端坐标。

### 阶段 D：客户端菜单和状态

拟新增：

- `RV_UtilityContextMenu.lua`：右键候选设备显示连接意图，发送目标提示和 requestId；
- `RV_UtilityClient.lua`：接收 snapshot/delta，维护 nonce、错误码和设备状态；
- `RV_UtilityDashboard.lua`：显示共享余额、profile、设备状态和 generator 状态。

拟修改 `RV_ContextMenu.lua`，仅挂接当前 RV 内部入口，保持服务端重解析和无可信坐标
约束。

### 阶段 E：说明同步

实际代码变更完成后，按目录职责更新 `README.md`、shared/server/client 相关 `agent.md`
和测试说明，记录 canonical 余额、现场 registry 检查、current schema、接受的误差边界、
待验证兼容性和完整测试范围。本阶段不修改这些说明文件。

### 阶段 F：实现和整体测试

未来每轮遵守“直接实现 → 一键整体测试 → 修复问题”：

1. 只实现本文 current design 的最小代码；
2. 直接启动仓库一键整体测试入口，不拆开测试客户端和服务端；
3. 测试服务器控制台保持可见，用户负责客户端启动后的连接、移动、点击和观察；
4. 静态 Lua/JSON/布局检查只能辅助验证，不能替代整体联机运行时证据。

## 13. 测试矩阵

### 13.1 Schema、身份和持久化

- 空新容器按当前 water/power schema 初始化，保存、退出、重载后字段完整且 identity 一致；
- 缺失、过期、部分写入、字段别名、旧 bounds/bitmap/mapping/generation/manifest、非法
  type、错误 identity 全部拒绝并提示删除测试存档重建；
- 不存在自动迁移、转换、fallback、旧字段兼容或自动删改存档路径；
- `sharedAmount`、`capacity`、`fluidProfile`、`registry`、`previousSnapshot`、`sequence`、
  `state` 与服务端快照一致；
- 液体 profile 只允许干净水、污染的水及两者原生混合，含其他成分的 source 不能通过
  current schema 的水规则；
- 单个 registry 对象 token/fingerprint 失效不会触发 schema 重建 gate，而是按 13.2 清理；
  重复身份、同对象多登记和跨 RV 占用拒绝当前整轮并返回结构性冲突；
- 重载或服务器重启后登记设备先处于 `NEEDS_INIT`，按 canonical 重建镜像和 baseline，
  不把加载前/重启前差额计作消费；
- 服务器重启或方格卸载后只验证 current record 能重新镜像并继续结算，不要求精确恢复
  中断窗口。

### 13.2 注册、检查和对象生命周期

- 支持设备在 RV 内右键显示连接意图；无管钳、越权、超距、RV 外、未加载、错误 generation
  或不兼容对象时拒绝；
- 连接后 `deviceId`、标签、token、fingerprint 和 registry 一致，且镜像目标为中央
  `capacity/sharedAmount/profile`；
- 每个 server tick 的消费预计算直接遍历 registry：未加载条目保留并标记 `NEEDS_INIT`，
  已加载确认缺失/替换/token 或 fingerprint 失效的普通设备及 baseline 被移除；
- 检查后访问失效或 API 异常的设备标记 `NEEDS_INIT` 并跳过，其他设备仍继续；移除或
  初始化一台设备不重置其他 baseline；
- 对象恢复或重载先按 canonical 重建镜像并建立新 baseline，恢复前消费不计入；服务器
  重启后全部登记设备先 `NEEDS_INIT`；
- 重复身份、同对象多 ID、明确跨 RV 占用为结构性冲突，拒绝当前整轮而不自动清理；
- 新对象必须重新右键连接并获得新 `deviceId`。

### 13.3 消费和共享镜像

- 单设备饮水、洗澡、冲厕、洗衣等原版动作造成的 amount 下降可在 server tick 结算中按
  公式识别；只有完成对应整体运行时验证的设备/功能才纳入本轮已支持清单，其他保持未
  支持；
- 多设备同时下降时按设备正向下降求和，低余额结果 clamp 到零，不撤销设备动作；
- 设备 amount 上升、容量变化、未授权中央增加/下降均不形成 canonical 加水或消费；
- `newShared` 由 canonical `S` 和公式提交；对象读回只验证镜像写入并更新对应 baseline，
  不能反向改变 canonical；
- 成功结算后中央和本轮仍有效、读回验证通过的已加载设备镜像一致；写入/读回失败设备
  为 `NEEDS_INIT`，不阻断其他设备，也不要求原版动作执行中的任意瞬间一致；
- `NaN`、无穷、负数、超容量和浮点尾差按 finite/clamp 处理，不导致负数余额或异常中止；
- 单个对象 API 异常只跳过并标记该对象，恢复后重新按 canonical 建镜像和 baseline。

### 13.4 授权加水、顺序和幂等

- `ADD_WATER` 验证玩家、权限、RV、距离、requestId、源容器和液体类型；
- 同一受控段先以已有保护执行 `settleUnderGuard` 结算设备消费；普通设备跳过不等于整轮
  失败，整体 gate/结构冲突/canonical 关键失败才停止加水；
- 源必须是玩家持有且服务端验证的独立液体物品容器；中央投影和任何已连接设备镜像拒绝
  作为 source；
- 按剩余容量和服务端观察源量计算 `plannedTransfer`，扣源后确认
  `confirmedTransfer`，canonical 只增加 confirmed 值；请求量和 planned 值不能直接入账；
- 用 `100 → 设备 90 → planned 20 → confirmed 20 → 最终 110` 例子验收，不能得到 `120`；
- 测试确认 clean、tainted、两者混合和含其他液体来源的接受/拒绝，以及混合后
  `fluidProfile` 的原生组成/污染状态；
- 同 tick 不同合法请求按顺序执行，重复 requestId 不重复扣源或入账；
- 未授权中央变化不改变 canonical，并在镜像时被覆盖；异常少量偏差按已接受边界处理；
- source 扣减异常、读回无法确认或 profile 混合 API 异常不凭请求/计划量补记，不引入回滚。

### 13.5 协议和对抗性请求

- 伪造坐标、RV id、generation、deviceId、capacity、amount、usage、profile、对象索引和
  最终结果全部以服务端重解析为准；
- tick 入口和命令入口各自只获取一次每-RV 保护，覆盖检查、读取、计算、应用和提交；
  `settleUnderGuard` 不重复获取、不因调用者持有保护而跳过，正常和异常退出均释放保护；
- 单个普通设备被跳过或标记 `NEEDS_INIT` 不使整轮失败；整体 gate、结构性冲突或 canonical
  关键步骤失败才拒绝整个当前操作；
- 旧 nonce、错误阶段、错误权限、跨 RV 请求拒绝；ACK 只在正常服务端应用后返回；
- 两名玩家同时使用不同设备、连接设备或加水时，每辆 RV 独立互斥，结果不跨 RV 污染；
- 两辆 RV 的水量、registry、snapshot、generator 绑定和 UI 快照完全隔离。

### 13.6 运行时兼容性

- 分别观察水槽、马桶、浴缸、淋浴、洗衣机和登记的第三方设备对 FluidContainer 容量、
  amount、profile、`inputLocked`、`usesExternalWaterSource` 的实际响应；
- 观察后台洗衣机、异步动作、对象重载、读回和设备替换；
- 核验规定基线中的 clean/tainted 类型标识、原生混合与污染判定 API，以及 profile 读写；
  测试混合后保存、重载和重新镜像不会净化污染水；
- 只有实机/联机结果才能将某个设备或功能从“待验证/不支持”移到“已验证/支持”，静态
  推断、反编译和源码扫描不作运行时替代；失败或未运行验证的设备明确排除在本轮支持范围。

### 13.7 电力

- 原生 generator 加油、启动、关闭、断电、损坏、连接、替换和保存重载验证服务端权威；
- 自定义 power record 不重复扣 fuel/condition；
- 虚拟电池和并行燃料余额不在当前验收范围。

## 14. 验收标准和实施边界

水系统的一次实现或某项功能可称为完成，必须同时满足：

- 正常初始化或结算完成时 canonical `sharedAmount` 有界且持久化；
- 当前有效且已加载的设备镜像与中央容量、余额和 profile 一致；
- 消费只来自 `sum(max(Dprev-Dobs,0))`，容量变化不计消费；
- 授权加水只来自独立物品源容器确认的 `confirmedTransfer`，并先结清此前已发生的设备
  消费；
- registry 只含服务端验证过的当前设备，未加载条目不会误删，已确认拆除条目会清理；
- 普通设备失效不会升级成整体 schema rebuild；结构性身份冲突和整体 gate 按 fail-closed
  处理；
- 所有 current-schema、权限、身份和幂等边界有效；
- 客户端不能提交世界状态改变服务端结果；
- 宣称支持的每一种设备和功能都已有对应整体联机运行时证据；未验证或验证失败的设备/功能
  明确排除在本轮完成支持范围，静态分析不得冒充运行时测试。

实施边界：

- `reference mods/`、`modinfos.json`、官方 Lua 和 `game-decompiled/` 永远只读；
- 本方案阶段只修改本文件，不写 Lua、配置或测试代码，不下载/更新模组，不启动游戏，
  不启动一键测试；
- 未来实现不得增加旧 schema 迁移、兼容别名、未声明的余额来源或重型崩溃恢复机制；
- 任何超出本文当前 schema 的虚拟电池、独立设备余额或严格守恒事务，必须另获授权并
  升级 schema。

## 15. 本次文档交付状态

- 已将整体 gate 与普通设备失效分层、canonical→镜像单向数据流、每入口一次保护、最小
  `ACTIVE/NEEDS_INIT` 生命周期、`plannedTransfer/confirmedTransfer` 加水顺序及冻结液体
  规则同步到模型、公式、schema、协议、文件职责、测试矩阵和验收标准。
- 已明确区分已确定设计、接受的误差边界和待运行时验证的 API/设备兼容性；本方案不把
  静态分析写成运行时证据，也不宣称尚未验证的设备已完成支持。
- 本次只允许修改 `RailroaderRVTest/WATER_POWER_IMPLEMENTATION_PLAN.md`；未修改 Lua、配置、
  其他说明文件或只读来源。
- 未启动游戏、未运行测试、未下载或更新任何模组。
