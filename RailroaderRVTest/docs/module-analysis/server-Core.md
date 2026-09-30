# `server/RailroaderRV/Core/` 模块分析

## 假设、范围与完成标准

- 按实际目录将每个 Lua 文件视为一个实现模块；同文件中的局部函数、赋值给表字段的函数、返回给 `ctx` 的加载闭包、嵌套函数和匿名回调都计入清单。匿名回调按所在调用点命名。
- 只读分析 `contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/` 的 10 个 Lua 文件。为判断本目录 API 的使用方及跨模块直接访问，只对相邻服务端代码做符号级引用搜索，不把相邻模块纳入逐函数分析。
- 目标交付是每个定义都列出源码起始行、参数含义、返回值/副作用、当前实现中是否承担必要职责；另总结复用、拆分与数据边界。
- 静态检查覆盖全部 10 个文件及函数表达式；逐行核对每个定义的位置；文档清单数与扫描数一致。未运行游戏、runtime 测试或修改 Lua 源码。

## 目录模块划分

| 文件 | 职责 |
|---|---|
| `RV_Server.lua` | 服务端组合根：加载公共依赖，创建 `RV.Server` 与共享 `ctx`，装配生成、屋顶刷新、记录验证、命令等子模块。 |
| `RV_Server_Commands.lua` | `RV.Server` 的 tick 与客户端命令入口；驱动生成事务和 utility 命令，并向 `RV.Core` 注册事件。 |
| `RV_Server_ManifestValidation.lua` | 把 manifest 的开发期校验委托给 schema gate，并在 `ctx` 上发布当前 manifest 状态接口。 |
| `RV_Server_Core.lua` | 进程内 64 位逻辑 tick、稳定事件分发器和具名 handler 注册表。 |
| `RV_DevSaveSchemaGate.lua` | 开发期一次性验证 mapping、manifest、utility ledger 与 mapping/manifest geometry；失败后 fail-closed。源码明确标记发行前整体移除。 |
| `RV_UtilityStore.lua` | utility ModData ledger 的读、复制、提交、快照与当前 identity 门禁。 |
| `RV_UtilityServer.lua` | 服务端 utility 协议、nonce/idempotency、身份解析、utility 操作调度和周期性维护。 |
| `RV_RailroaderServer.lua` | Railroader 服务端适配器组合根，避免 client-only process 注册服务端 handler，并装配 adapter 子模块。 |
| `RV_RailroaderServer_Tick.lua` | Railroader adapter 的 tick 生命周期、屋顶刷新队列推进、mapping 位置采样和 generation hook 安装。 |
| `RV_RailroaderServer_Sentinel.lua` | Railroader Enter/Exit 命令、玩家快照与 utility mapping 同步；校验服务锁、mapping 几何并处理临时 sentinel cell 返还。 |

## 函数清单与逐函数职责

以下“必要性”是对当前源码所实现的运行职责的判断，不代表该函数必须保持目前的拆分或命名。

### `RV_UtilityStore.lua` — 持久化仓库（20 个函数表达式）

| 函数 / 行 | 职责、参数与输出/副作用 | 当前功能必要性 |
|---|---|---|
| `integer(value)` L11 | 数值整数归一化；非 number 或非整数返回 `nil`。 | 是：校验 ledger 的 schema/identity 数字字段。 |
| `number(value)` L15 | 仅接受 number，否则 `nil`。 | 否（当前无调用点）：目标文件内符号检索只命中定义，属可清理的局部死代码；不影响其它 ledger 校验。 |
| `empty(value)` L19 | 输入 table 时检查是否无键；非 table 为 false。 | 是：区分空的新容器与已有持久数据。 |
| `copyTable(value)` L25 | 递归复制 table，保留非 table 原值；输入一个 ledger 子树，输出脱离 ModData 的工作副本。 | 是：防止未 commit 修改直接污染持久根。 |
| `identityValid(identity)` L32 | 检查 `{rvId,generation,bitmapVersion}` 当前标识；输出布尔值。 | 是：新建/枚举阶段的 schema 身份门禁。 |
| `waterInteger(value)` L39 | 校验有限整数；输出原值或 `nil`。 | 是：sink 坐标需为有限格点整数。 |
| `waterSinkKey(x,y,z)` L45 | 三个坐标转 `x:y:z` 字符串；无效输入返回 `nil`。 | 是：水槽 ledger 的稳定键，另由 `M.waterSinkKey` 暴露给水模块。 |
| `readRoot()` L52 | 无参数；先检查 schema gate，再 `ModData.get` STORE_KEY；根未创建时返回 nil，异常/类型不符则抛 `INVALID_RV_DATA`。 | 是：统一所有读取的 fail-closed 入口。 |
| `root(allowCreate)` L66 | 读取根；允许时用 `getOrCreate` 初始化空根的 schemaVersion/records；输出已初始化根或抛错误。 | 是：只在显式创建路径初始化当前 schema。 |
| `currentIdentityGate(identity)` L82 | 检查 identity 并调用 `RV.Server.currentRVManifestForBoundary`、`validateCurrentUtilityIdentity`；输出 `true` 或 `false, reason`。 | 是：保证记录归属当前 manifest 和 mapping。 |
| `newWater()` L98 | 无参数，构造当前水 ledger 默认记录；输出 table。 | 是：新 utility record 初始化。 |
| `newPower()` L103 | 无参数，按 UtilityConstants/PowerConfig 默认构造电力字段、空设备和状态；输出 table。 | 是：新 utility record 初始化。 |
| `newRecord(identity)` L116 | 输入 RV identity，拼出 rvId/generation/bitmapVersion 与默认 power/water；输出新记录。 | 是：允许创建新 RV utility 记录。 |
| `M.validateIdentity(identity)` L122 | 输入 identity，原样转交当前身份 gate；输出 `bool, reason?`。 | 是：供扫描调用者确认记录仍是当前 RV。 |
| `M.getRecord(identity,allowCreate)` L126 | 输入身份及创建开关；先过 gate，再读取匹配持久记录并复制；没有记录仅在 allowCreate 时生成工作副本；输出 `true,record` 或 `false,reason`。 | 是：power/water 服务唯一受控记录读取口。 |
| `M.commit(record,identity)` L154 | 输入脱离存储的工作记录及身份；检查字段一致、更新持久根副本并 transmit；失败回滚根中旧记录；输出成功布尔值/失败原因。 | 是：提供明确提交点及失败原子性。 |
| `M.allRecords()` L185 | 无参数；读取根，校验每个键与 identity 基本契约并深拷贝，输出 `true,entries` 或拒绝原因。 | 是：周期维护需安全枚举记录。 |
| `M.validateGenerationUtilityState(identity)` L210 | 输入候选新 identity；检查所有现存记录中同 RV 的 generation/bitmapVersion 是否已匹配；输出 `true` 或拒绝原因。 | 是：generation 改世界状态前的 utility 持久状态门禁。 |
| `M.snapshot(record)` L227 | 输入记录；复制 power/water 并剔除设备 `modData`，输出面向网络的快照。 | 是：防止内部实体元数据进入客户端消息，且网络状态与可变仓库脱离。 |
| `M.waterSinkKey(x,y,z)` L237 | 公共薄封装，坐标参数同私有 helper；输出 canonical sink key。 | 是：仓库对水 ledger 消费者的最小接口。 |

### `RV_UtilityServer.lua` — utility 服务端协议与调度（37 个函数表达式）

| 函数 / 行 | 职责、参数与输出/副作用 | 当前功能必要性 |
|---|---|---|
| `key(identity)` L20 | 将 RV id、generation、bitmapVersion 组成锁键。 | 是：以完整版本身份隔离并发操作。 |
| `playerKey(player)` L25 | 调用玩家 online ID/name，name 缺失时取 full name；输出稳定会话键或 nil。 | 是：绑定会话与 idempotency 到连接身份。 |
| `stableReason(reason)` L35 | 将非法 RV 数据/已知错误映射为协议原因字符串。 | 是：稳定地向客户端报告失败类别。 |
| `send(player,command,payload)` L45 | 通过公共 `sendServerCommand` 发送 RailroaderRV 命令；输出调用是否成功。 | 是：ack/snapshot 的统一消息出口。 |
| `resolveRV(player)` L51 | 输入权威 server player；调用 `RV.Server.resolveCurrentUtilityRV`，再验证身份字段、补入 context.player；输出 `true,context` 或 `false,reason`。 | 是：操作权限与 RV 归属均由服务端解析。 |
| `serviceBusy()` L73 | 无参数；查询 generation/roof transaction 活跃状态；缺少服务或读取失败时按 busy；输出布尔值。 | 是：阻止 utility 写与大事务竞态。 |
| `validText(value,maxLength)` L90 | 校验非空 string 和长度上限；输出 bool。 | 是：request/session nonce 字段约束。 |
| `validHint(value)` L94 | `nil` 或 table 可接受；输出 bool。 | 是：位置 hint 只能以可检查的数据容器进入协议。 |
| `validRequest(args)` L99 | 验证请求 table 的精确字段集合、ID/nonce/operation/hints；输出 `bool,reason`。 | 是：协议 allow-list 和基本输入门禁。 |
| `knownOperation(operation)` L113 | 检查操作名是否为已实现的 utility 指令。 | 是：拒绝未支持操作。 |
| `acquire(identity)` L123 | 获取按身份区分的进程内锁；输出 `true,key` 或 busy。 | 是：避免同一 RV 同步重入写入。 |
| `release(identityKey)` L130 | 释放指定锁；无输出。 | 是：配合锁生命周期。 |
| `withGuard(identity,callback)` L134 | 获取锁后 `pcall(callback)`，总是释放锁；callback 无实参且约定返回 `accepted,result`；输出该结果或稳定错误。 | 是：所有受保护 utility 修改共享一致的锁与异常路径。 |
| `acknowledge(player,requestId,accepted,result)` L143 | 构造并发送 ack；成功时选取序号/传输字段，失败时标准化 reason。 | 是：协议对每个请求给出结果。 |
| `remember(session,requestId,response)` L160 | 写入当前会话响应去重表，最多保留约 64 项；无返回值。 | 是：重复请求可重放结果，限制会话内存增长。 |
| `sessionFor(nonce,player,previous)` L174 | 新 nonce/玩家建会话，并继承 retired nonce 集且 retire 旧 nonce；输出 session table。 | 是：重连隔离旧 idempotency namespace。 |
| `replaceSession(id,player,nonce,previous)` L180 | 建立并保存新 session；输出 session。 | 是：集中替换会话状态。 |
| `broadcast(context,record)` L186 | 输入授权上下文和记录；生成 Store/Power 快照并发给当前玩家。 | 是：统一序列化 utility 状态。 |
| `broadcastToRV(identity,record)` L193 | 枚举在线玩家并重新解析每人当前 RV，仅向身份三元组一致者广播。 | 是：将更新同步到当前同 RV 玩家而不信任客户端归属。 |
| `currentMappingRecord(identity)` L210 | 通过 adapter 公共 `currentUtilityRecord` 取有效 mapping record；输出 `bool,record/reason`。 | 是：周期扫描必须把 utility ledger 与当前 mapping 对齐。 |
| `forCurrentRecords(callback)` L223 | 读取 `Store.allRecords`，逐个通过 identity 与 mapping 校验后调用 `callback(identity,record,mappingRecord)`；无结果表返回。 | 是：周期维护统一排除过期/未映射记录。 |
| `M.handleCommand(player,args)` L239 | 校验请求、会话 nonce、重复 ID、忙碌状态、RV/phase；在身份锁内调 Water/Power/Devices，成功或部分 settle 时向 RV 广播，保存并发送 ack；返回 `bool,result/reason`。 | 是：客户端 utility intent 唯一服务端调度入口。 |
| `handleCommand` 内身份锁 callback L291 | 无显式参数；闭包使用已验证的 context/identity/args/工作记录分派水、电、设备、snapshot 操作；返回 `accepted,detail` 并可能改写/广播数据。 | 是：操作需要在 `withGuard` 的锁区内执行。 |
| `syncUtilityMappings()` L360 | 无参数；按在线玩家快照和 adapter epoch 重发候选 utility mapping 同步；更新/清理 `mappingSyncState`。 | 是：重连或 mapping 更新后恢复客户端提示。 |
| `M.onTick(tick)` L390 | 输入逻辑 tick；忽略无效/重复 tick，跑 water removal reconciliation、定期 mapping sync 和设备扫描。 | 是：周期服务入口。 |
| `onTick` 的 `forCurrentRecords` callback L405 | 输入 identity/record/mappingRecord；启动 power runtime，成功后执行设备扫描。 | 是：每条有效 RV 记录的周期设备维护动作。 |
| `M.onObjectRemoved(object)` L414 | 输入即将移除的世界对象；安全转交 Water 留下短期 witness；输出成功或待重试原因。 | 当前 wiring 未证实：注释称由 Core owner 注册，但目录引用扫描未找到调用点；`RV_Server_Commands.lua:L292-L294` 注册的是 room ownership scan callback。若确实无动态外部调用，此 facade 当前不起作用，需由项目维护者决定接线或移除。 |
| `M.onEveryTenMinutes()` L424 | 无参数；枚举当前记录、在 RV 锁内结算并刷新负载，成功后广播。 | 是：游戏时间周期性结算资源消耗。 |
| `onEveryTenMinutes` 枚举 callback L425 | 输入 identity/record；为该记录调用 `withGuard` 完成 settlement。 | 是：把批量循环逐条包进身份锁。 |
| 上述 `withGuard` callback L426 | 无参数；以现存 record 结算并返回 Power 结果。 | 是：锁内提交避免 tick/命令重入。 |
| `M.onEveryHour()` L435 | 无参数；对所有当前记录调用 native proxy maintenance。 | 是：按小时维护实体 proxy。 |
| `onEveryHour` 枚举 callback L436 | 输入 identity/record；转交 Power native proxy 维护。 | 是：适配每条记录的周期任务。 |
| `M.settleAndRefreshLoad(identity,player)` L441 | 输入当前 identity 与可选玩家；读取、锁内结算、成功后广播；输出 `bool,record/reason`。 | 是：向 generation/其他服务提供 utility load 结算接口。 |
| 上述 `withGuard` callback L444 | 无参数；调用 Power settlement 并返回状态/更新记录。 | 是：该公开接口也必须遵守统一锁。 |
| `M.snapshotForPlayer(player)` L453 | 输入 server player；重解析当前 RV 后读取并发送快照；输出成功/record 或失败原因。 | 当前项目内无调用点：作为将来/外部 require API 有效；若它应承担重连初始快照，当前 `syncUtilityMappings` 路径并未调用它。现有 command snapshot 操作由 `handleCommand` 实现。 |
| `M.validateGenerationUtilityState(identity)` L462 | 输入候选 identity；转交 Store 的 generation 持久状态校验；输出 bool/reason。 | 是：被 generation 流作为前置门禁。 |
| `M.initializeRecord(identity,context)` L469 | 输入 generation 身份和上下文；调用 Power 初始化并记录日志，可向当前玩家广播；输出初始化记录或原因。 | 是：新 generation 成功后建立其 utility 状态。 |

### `RV_Server_ManifestValidation.lua` — manifest gate 适配器（3 个函数表达式）

| 函数 / 行 | 职责、参数与输出/副作用 | 当前功能必要性 |
|---|---|---|
| 文件加载闭包 `return function(ctx)` L2 | 输入组合根 `ctx`；装配依赖并调用 `Gate.configureManifest`，无返回值。 | 是：把 RV_Server 的依赖注入给一次性 gate，而不让 gate 自行猜取业务模块。 |
| `requireCurrentManifest(manifest)` L23 | 输入 manifest；gate 未通过时抛 `INVALID_RV_DATA`，通过时返回原表。 | 是：向其他 RV_Server 子模块提供“当前已校验”门禁；内容扫描由 gate 完成。 |
| `ctx.currentManifestValid()` 闭包 L28 | 无参数；返回 gate 是否 ready。 | 是：提供只读状态接口给组合根的其他服务模块。 |

### `RV_Server_Core.lua` — 逻辑时钟与事件总线（28 个函数表达式）

| 函数 / 行 | 职责、参数与输出/副作用 | 当前功能必要性 |
|---|---|---|
| `isUInt32(value)` L17 | 校验 0..2^32−1 整数 number；返回 bool。 | 是：两段式 tick 的字字段校验。 |
| `isTick(value)` L23 | 检查精确 `{hi32,lo32}` table 和两个 UInt32；返回 bool。 | 是：所有 tick 运算和入口共用的结构契约。 |
| `copyTick(value)` L36 | 复制已知 tick 的两字段；返回新 table。 | 是：避免调用者直接改 Core 时钟对象。 |
| `validDelay(value)` L40 | 校验非负、安全整数 tick 延迟；返回 bool。 | 是：防止精度溢出破坏 tick deadline。 |
| `tickCompare(left,right)` L46 | 比较两个 tick；输出 -1/0/1，非法时 `nil,reason`。 | 是：统一时序先后判断。 |
| `tickAdd(tick,delta)` L57 | tick 加安全整数或两字 tick；输出新 tick，非法/溢出为 `nil,reason`。 | 是：所有跨帧截止时间计算。 |
| `tickReached(now,deadline)` L78 | 是否已到 deadline；输出 bool/reason。 | 是：事务与缓存 deadline 检查。 |
| `tickElapsed(now,since)` L84 | 计算两个 tick 的无符号差；逆序/非法时 nil+reason。 | 是：避免把大 tick 转成不精确的单 number。 |
| `tickElapsedAtLeast(now,since,duration)` L100 | 判断 elapsed 是否达时长；输出 bool/reason。 | 是：跨帧超时判断共用入口。 |
| `addModulo(left,right,modulus)` L106 | 安全地算模加法；输出余数。 | 是：服务 64-bit tick 的模运算而不构造不精确大数。 |
| `multiplyModulo(left,right,modulus)` L112 | 倍增算法作模乘；输出余数。 | 是：计算高位字对 interval 的贡献。 |
| `tickModuloFor(tick,interval)` L124 | 校验 tick/周期后判断 tick 模 interval 是否为 0；输出 bool 或 `false,reason`。 | 是：大 tick 周期调度的精确实现。 |
| `getTick()` L150 | 无参数；返回当前进程时钟副本。 | 是：Core 公共只读时钟接口。 |
| `formatTick(tick)` L154 | 格式化为 `hi32:lo32`，非法为 `invalid`。 | 是：便于日志显示而不丢失两段信息。 |
| `tickModulo(interval)` L159 | 对内部当前 tick 调用 `tickModuloFor`；输出 bool/reason。 | 是：调用方不用接触 Core 内部时钟状态。 |
| `nextTick()` L163 | 增加全局 tick，跨 lo32 进位；溢出返回 false/reason。 | 是：单一 dispatcher 上 OnTick 的时钟推进点。 |
| `callOrdered(entries,predicate,...)` L176 | 顺序调用 entries 中通过可选 predicate 的 `callback`；透传事件参数；异常 fail-fast。 | 是：保持同一 dispatcher 内事务顺序和失败隔离。 |
| `dispatchEvent(eventName,...)` L190 | 等 gate ready 后按 OnTick、OnClientCommand 或普通事件分派；OnTick 先递增 tick。 | 是：全部注册 handler 唯一入口，启动 gate 未过时不运行 RV 逻辑。 |
| tick predicate 闭包 L198 | 输入一个注册项；用当前 tick 与 entry.interval 判定是否调用。 | 是：将周期筛选留在中央时钟里。 |
| command predicate 闭包 L206 | 输入一个注册项；通配符或命令名相等时返回 true。 | 是：命令分发按注册名过滤。 |
| `ensureEngineListener(eventName)` L215 | 输入允许注册的引擎事件名；安全读取 `Events[eventName].Add`、建 dispatcher 并注册；返回成功/错误。 | 是：保证 Core 注册成功前不向调用者谎报 handler 已安装。 |
| 读取事件闭包 L218 | 无显式参数；在 `pcall` 中取 `Events[eventName]`；输出 event。 | 是：引擎 API 访问异常时走失败返回。 |
| 读取 Add 闭包 L223 | 无显式参数；在 `pcall` 中读取 `event.Add`；输出 Add 函数。 | 是：保护 Java/引擎代理属性访问。 |
| dispatcher 闭包 L233 | 输入引擎传入的 varargs；调用 `dispatchEvent(eventName,...)`。 | 是：让每个 engine event 仅安装本模块拥有的单个入口。 |
| `registerTick(name,interval,callback)` L244 | 校验 ID/周期/函数，拒绝同名不同配置，确保 OnTick dispatcher 后登记；返回 bool/reason。 | 是：所有定期 server 服务的公开注册口。 |
| `registerCommand(name,callback)` L271 | 校验命令/函数并按名字去重，确保 OnClientCommand dispatcher；返回 bool/reason。 | 是：命令 handler 的公开注册口。 |
| `registerEvent(eventName,name,callback)` L303 | 只允许 allowlist 事件；具名去重后确保 dispatcher，返回 bool/reason。 | 是：对象/动作事件共用的注册口。 |
| `sendToClient(player,command,payload)` L331 | 验证玩家和命令，取 module id，安全调用 `sendServerCommand`；返回 bool/reason。 | 当前项目内无调用点：公共 helper 本身完整，但实际命令服务采用 Common `Util`；可统一调用策略或移除这项未使用导出。 |

### `RV_Server_Commands.lua` — RV_Server 命令与 tick 汇总（6 个函数表达式）

| 函数 / 行 | 职责、参数与输出/副作用 | 当前功能必要性 |
|---|---|---|
| 文件加载闭包 `return function(ctx)` L2 | 从组合根取依赖并安装 `RV.Server` handler/事件；无返回值。 | 是：把依赖注入与事件生命周期绑定在 server 服务装配阶段。 |
| `safeErrorText(...)` L15 | varargs 转交 ctx 的安全错误文本格式化；输出安全字符串。 | 是：错误日志不直接 stringify 任意异常对象。可由直接调用格式化器代替，但封装便于此模块的注入边界。 |
| `isInvalidRVData(reason)` L43 | 检查 reason 是否包含常量中的 fail-closed marker；输出 bool。 | 是：识别 schema 错误并通知玩家/取消事务。 |
| `RV.Server.OnTick(tick)` L49 | 输入逻辑 tick；阻止 gate 未通过；更新 `ctx.serverTick`；维持迁移 lease、推进 room/roof 状态；调 utility tick；恢复/取消/校验 generation relocation 与 ACK、目标加载，最后触发生成。无显式返回值，可能修改事务和世界。 | 是：当前聚合事务的主 tick 协调器。 |
| `RV.Server.OnClientCommand(module,command,player,args)` L198 | 按 mod/命令分派 utility、Enter/Exit 让 adapter 处理、两种 relocation ACK 或 Generate；验证失败通知/日志，成功后排队 generation。 | 是：服务端权威命令入口。 |
| `requireCoreRegistration(ok,reason)` L278 | 注册失败则抛错；无成功返回值。 | 是：启动时 fail-fast，防止 server 以为 handler 已可用。 |

### `RV_Server.lua` — RV_Server 组合根（4 个函数表达式）

| 函数 / 行 | 职责、参数与输出/副作用 | 当前功能必要性 |
|---|---|---|
| `loadModule(name,globalName)` L27 | 输入模块名与调试全局名；安全 require，按全局/RV 子字段回退，最后返回空 table。 | 是：缺失常量/layout 时阻止 nil 解引用；global fallback 仅供 debugger reload。 |
| `ctx.samplePlayerPosition(player,tick,interval)` L161 | 位置缓存采样 facade；返回缓存器的采样结果。 | 是：把 Common cache 作为注入服务交给 relocation 子模块。 |
| `ctx.getPlayerPosition(player,options)` L164 | 位置缓存读取 facade；返回缓存器当前位置与状态。 | 是：同上，集中共享取位缓存。 |
| `ctx.invalidatePlayerPosition(player)` L167 | 使该玩家位置缓存失效；返回 cache 结果。 | 是：传送或位置身份变化后清除陈旧观察。 |

### `RV_RailroaderServer.lua` — Railroader adapter 组合根（2 个函数表达式）

| 函数 / 行 | 职责、参数与输出/副作用 | 当前功能必要性 |
|---|---|---|
| `processIsClient()` L10 | 无参数；安全调用引擎 `isClient()`，无 API/失败时 false。 | 是：区分 client-only Lua pass。 |
| `processIsServer()` L16 | 无参数；安全调用 `isServer()`；函数不存在时按 server 兼容路径返回 true。 | 是：与上一函数组合判断 client-only 进程。 |

### `RV_RailroaderServer_Tick.lua` — adapter tick 生命周期（7 个函数表达式）

| 函数 / 行 | 职责、参数与输出/副作用 | 当前功能必要性 |
|---|---|---|
| 文件加载闭包 `return function(ctx)` L2 | 接收 adapter 私有 ctx，捕获队列、mapping 操作并注册函数；无返回值。 | 是：按模块加载顺序装配 adapter tick 子系统。 |
| `recordForLoco(...)` L9 | varargs 透传到 adapter 的同名查找接口；返回其结果。 | 是：消除本模块对上下文查找 helper 的重复绑定；可用局部直接别名替代。 |
| `processPendingWallRoofRefreshes()` L33 | 无参数；检查 pending/follow-up 队列与 generation mutex，暂停或过期排队事务，读取当前 mapping、提升 follow-up、重验身份/状态并推进 roof relocation group；无直接返回值，改写 adapter 私有排程状态。 | 是：接受的 wall-removal 工作需有有界、可重验的推进路径。 |
| `Adapter.OnTick(tick)` L173 | 输入 Core tick；设置 adapter tick、周期 prune/处理队列/sentinel；每 30 tick 读取 mapping，每 120 tick 更新 train pose；采样 roof-refresh 玩家并在 mapping 改变时提交。 | 是：adapter 所有 tick 工作的唯一生命周期入口。 |
| `Adapter.installTransactionHooks()` L226 | 无参数；检查 RV.Server 的 validation/commit/failure setter，并安装 `validateGeneration`、`commitGeneration` 和 rollback hook；返回 bool。 | 是：把可选 Railroader 事务与通用 generation 生命周期接合。 |
| failure hook 闭包 L236 | 接收任意失败参数；失效 boundary cache 后转交 generation rollback；返回恢复结果。 | 是：失败回滚必须先清陈旧 geometry cache。 |
| `requireCoreRegistration(ok,reason)` L247 | 失败时抛出注册错误；无成功返回。 | 是：命令/tick/对象回调缺注册时停止 adapter 装配。 |

### `RV_RailroaderServer_Sentinel.lua` — adapter 安全门与 sentinel（21 个函数表达式）

| 函数 / 行 | 职责、参数与输出/副作用 | 当前功能必要性 |
|---|---|---|
| 文件加载闭包 `return function(ctx)` L2 | 捕获 adapter、world APIs、队列及安全检查 helper，然后将接口写回 ctx；无返回值。 | 是：Sentinel 是组合 adapter 的一部分，依赖该共享契约。 |
| `commandArgument(args,key)` L37 | 从 Lua table 取值，或对 Java Args 调 `get(key)`；返回参数或 nil。 | 是：同时兼容两种引擎命令参数容器。 |
| `Adapter.OnClientCommand(module,command,player,args)` L44 | 只处理本 mod 的 Enter/Exit；检查 roof claim，校验 Enter 的 locoId，调用 adapter 操作并向失败玩家回包。 | 是：Railroader Enter/Exit 需要服务端授权与事务门禁。 |
| `onlinePlayersSnapshot()` L72 | 无参数；安全读取在线列表、去重并转普通 Lua array；不可用/空时尝试单机 `getPlayer`。 | 是：所有 adapter 在线扫描使用一个安全快照。 |
| `Adapter.onlinePlayersSnapshot()` L108 | 无参数；公开包装在线玩家快照。 | 是：utility/server 其他模块需要玩家列表而不触碰引擎 Java 容器。 |
| `Adapter.syncUtilityMapping(player)` L112 | 输入玩家；重新解析当前 RV/identity/record，构造客户端 mapping hint 并发送；返回 send 是否成功与 identity。 | 是：客户端 affordance 重连恢复；hint 不授予服务端权限。 |
| `resolveSavedPlayer(saved)` L142 | 输入保存过的 player descriptor；用 identityKey 与在线玩家匹配，成功时将当前 player 对象写回 `saved.player`；输出 bool。 | 是：群组 relocation 后可将保存身份重绑到替换的 player userdata。 |
| `sentinelIdentity(player)` L160 | 输入玩家；取得 online ID/name；输出 `id:name,id,name`，任一缺失则三个值为 nil。 | 是：安全门以稳定玩家身份而非 userdata 追踪。 |
| `queuedRoofRefreshClaims(identityKey)` L166 | 输入身份键；扫描待处理 roof refresh 与成员快照，输出是否占有此身份。 | 是：queued 事务尚未取得 relocation token 时也不能与新 Enter/Exit 竞争。 |
| `sentinelClaimState(server,identityKey)` L183 | 输入 server facade 和身份键；queued roof claim 优先，否则调用公开 relocation claim；输出 bool 或 nil（不可判定）。 | 是：sentinel 必须证明身份未被别的事务占用。 |
| `roofRefreshOwnsPlayer(player)` L196 | 输入玩家；先判断 queued claim，再核验 roof mutex 和 server claim；输出 roof 是否占有。 | 是：Enter/Exit 拒绝原因与 roof/generation 互斥状态需明确区分。 |
| `serverTransactionMutexStatus()` L221 | 无参数；调用公开 generation 与全局 roof mutex 查询；输出两个 bool 和可选 reason，接口缺失/异常时 `nil,nil,reason`。 | 是：共同服务锁必须在移动/座位/mapping 变更前 fail-closed。 |
| `roofRefreshTransactionBlocks(rvId)` L243 | 输入 rvId（当前实现未用此参数）；读取全局事务互斥，并检查所有 pending 和未过期 follow-up；输出 `true,reason` 或 false。 | 是：屋顶刷新按全服务世界范围互斥；不按 RV 过滤是当前规则。可删未用参数以减少误导，但行为门禁本身必要。 |
| `currentGeometryGate(record)` L288 | 输入 mapping record；调用 `RV.Server.validateCurrentRVRecord`，缺失/异常/拒绝均返回 invalid RV；输出 bool/reason。 | 是：移动前证明 record 与当前 manifest geometry 一致。 |
| `sentinelWarn(identityKey,reason)` L300 | 输入身份和原因；去重后输出临时 cell 安全拒绝日志。 | 是：防止反复 tick 刷屏，同时保留异常提示。 |
| `sentinelRelationsConsistent(map,record)` L310 | 输入 mapping root 和 record；双向对照 map.players 与 record.players 的 inside、RV、onlineId 关系；输出 bool。 | 是：自动返还玩家前拒绝不一致的双份关系。 |
| `sentinelBitmapAndCenter(record)` L348 | 输入 record；检查 gate、managed/boundary、缓存 bitmap、center/anchor 与 active cell；输出 `true,{bitmap,centerX,centerY,centerZ}` 或 false/reason。 | 是：从当前生成 geometry 计算 sentinel 返回位置，不能用客户端坐标。 |
| `sentinelRecordManifestConsistent(record,manifest)` L389 | 输入 mapping record 与当前 manifest；调用公开 server 几何一致性接口；输出 bool。 | 是：同 identity 也可能携带不同 bitmap，需做完整比较。 |
| `sentinelRecordCandidate(map,player,server)` L397 | 输入当前 mapping、玩家、server facade；只接受玩家位于唯一当前 generation/roof sentinel cell 的有效 record，校验 manifest 和关系；输出 candidate、identityKey、reason。 | 是：返还动作须先唯一定位并完整验证目标 RV。 |
| `sentinelReturnToRV(candidate,player,map)` L488 | 输入候选、玩家、mapping；二次核验身份/位置/claim/manifest/bitmap/target，启动 ownership monitor 与 boundary transition，传送并完成 transition；输出 bool/reason，不修复 mapping。 | 是：唯一执行安全返还世界变更的路径。 |
| `warnSentinelPlayersAtTemporaryCell(reason,knownSentinelPlayers)` L606 | 输入拒绝原因和可选已知玩家列表；对 sentinel cell 玩家按身份去重警告。 | 是：当 sentinel 自动返还条件未满足时避免玩家无反馈滞留。 |

### `RV_DevSaveSchemaGate.lua` — 开发期存档 schema gate（59 个函数表达式）

此文件的目的在源码 L1-L4 已标明：开发期间在 `OnInitGlobalModData` 后对当前存档做一次 gate，不迁移/创建旧数据；发行前需整体移除。这里的 validation helper 虽然数量多，但它们组合成“mapping、manifest、utility、record geometry 四项全部通过才开放”的 fail-closed 约束。

| 函数 / 行 | 职责、参数与输出/副作用 | 当前功能必要性 |
|---|---|---|
| `fail(message)` L22 | 输入失败文本；首次失败固定状态、记录 reason 并提示删除测试存档重建。 | 是：gate 唯一 fail-closed 状态转换。 |
| `Gate.configureMapping(dependencies)` L32 | 接入 mapping schema 依赖；启动扫描前、状态 pending 且输入 table 才成功，否则 fail。 | 是：mapping validator 需显式注入，不依赖加载时序猜测。 |
| `Gate.configureManifest(dependencies)` L42 | 接入 manifest/boundary/layout 等依赖并写入局部配置；输出 bool。 | 是：验证 manifest 与 boundary 的当前契约。 |
| `Gate.configureRecordGeometry(dependencies)` L59 | 接入 `ServerSchema`；输出 bool，晚于 startup 或无效输入则 fail。 | 是：geometry 对照依赖服务端 bounds 计算器。 |
| `Gate.isReady()` L68 | 无参数；返回 status 是否 passed。 | 是：world/utility 调用方的 fail-closed 门禁。 |
| `Gate.failureReason()` L72 | 无参数；返回缓存的失败文本。 | 当前项目内无调用点：仅诊断 API；对 gate fail-closed 行为本身非必要。 |
| `Gate.isValidating()` L76 | 无参数；返回 startup 校验期间标志。 | 是：Boundary 在 startup 扫描 boundary 时允许读取已经逐条认证的缓存，避免循环拒绝。 |
| `exactKeys(value,expected)` L80 | table 只能出现 expected 键，允许 expected 键缺省；输出 bool。 | 是：拒绝 schema 新旧字段混杂。 |
| `boundaryInteger(value)` L88 | 接受整数 number/string 或能在保护下转整数的数值对象；输出整数或 nil。 | 是：兼容 ModData/Java numeric 表现，同时收敛到整数。 |
| 数值 coercion 闭包 L97 | 无参数；对 `value + 0` 做 pcall 并取结果；输出 number 或 nil。 | 是：保护 userdata 数值转换异常。 |
| `validShellEdges(edges,rvId,generation,bitmapVersion,managed,C,Template)` L105 | 校验固定数量 59 个边、精确字段、edge key/几何/身份与模板对象、索引数组；输出 bool。 | 是：拒绝损坏或旧 shell-edge ledger。 |
| `validateBoundarySchema(boundary)` L212 | 输入 persisted boundary；检查精确 schema、bitmap 解码/验证、managed 范围、identity 与 shell edges；缓存解析结果，输出 bitmap/身份或 nil。 | 是：mapping/manifest 几何都以此作为 boundary 当前契约认证入口。 |
| `Gate.validateBoundarySchema(boundary)` L259 | 公开转交 boundary validator；输出解码 bitmap/identity 或 nil。 | 当前项目内无调用点：私有 validator 在此文件内部使用；其他服务实际消费 `validatedBoundary`。仅在外部模块需要直接 decode 时保留公开 wrapper。 |
| `Gate.validatedBoundary(boundary)` L263 | 输入 table；仅返回该对象此前缓存的已验 bitmap/身份，否则 nil。 | 是：Boundary 在启动验证阶段消费已检查对象，不重复解析未验证对象。 |
| `validateMappingPosition(value,pose,dependencies)` L271 | 校验位置精确字段、数值、世界高度与 copyPosition；pose=true 时要求方向向量；输出 bool。 | 是：mapping relation/train pose 共用严格位置合同。 |
| `validateMappingRegion(region,dependencies)` L286 | 校验 region 精确字段、尺寸、identity z 与世界高度；输出 bool。 | 是：slot/region 是 mapping identity 的空间契约。 |
| `validateMappingRelation(relation,requireLocoId,dependencies)` L302 | 校验玩家关系 exact schema、版本、onlineId/inside/seat，并按 inside 选择 enter/exit 坐标；输出 bool。 | 是：拒绝半写入或旧版 player relation。 |
| `validateMappingRecord(record,dependencies)` L322 | 校验完整 RV record 字段/identity/slot/region/anchor/geometry/boundary/玩家关系，并注册已验证 generation；输出 bool。 | 是：map root 中每个记录都必须通过当前 schema 与 boundary 注册。 |
| `validateMappingRoot(map,dependencies)` L392 | 校验 root 字段、schemaVersion、每条记录与唯一 slot，且 inside relation 与 record.players 双向匹配；输出 bool。 | 是：启动时验证整个 mapping root，而不是只验被访问条目。 |
| `validateMappingAtStartup()` L433 | 无参数；读 `RV_MAP_KEY`，缺失/空根通过，有效 table 经 root validator；返回 bool/reason。 | 是：四项 startup 扫描之一。 |
| `currentBoundsValid(bounds,managed,bitmap,anchor)` L447 | 校验当前布局 bounds 精确字段、固定几何/墙数量、anchor/预期 layout、bounds bitmap 与 boundary bitmap 位层相同、wall coordinates/shellEdges 逐项一致；输出 bool。 | 是：防止单独合法但彼此冲突的旧 bounds/boundary 影响 world 操作。 |
| `currentBoundsValid.onlyKeys(value,expected)` L448 | 输入 table 与允许字段；拒绝额外键，输出 bool。 | 是：bounds 内部每种结构的 exact shape 子检查。 |
| `currentBoundsValid.sameTemplateIndices(left,right)` L457 | 校验两个稠密正整数数组长度与元素一致；输出 bool。 | 是：wall/shell 模板组合必须保持原顺序。 |
| `currentBoundsValid.inside(minX,maxX,minY,maxY,z)` L647 | 检查矩形/楼层在 managed bounding volume 内；输出 bool。 | 是：约束 room/wall/roof 范围不越出 managed geometry。 |
| `currentManifestValid(manifest,allowEmpty)` L798 | 校验 manifest exact field allowlist、schema/version/state/phase、identity、anchor、boundary、bounds/bitmap和生命周期时间；成功时注册 boundary；输出 bool。 | 是：拒绝过期/部分 manifest，并验证业务当前 manifest。 |
| `validateManifestAtStartup()` L921 | 无参数；读 manifest root，nil/空 root 通过；验证并缓存已通过的 persisted root；输出 bool/reason。 | 是：四项 startup 扫描之一。 |
| `integer(value)` L945 | utility schema 域严格接受整数 number，其他为 nil。 | 是：与 boundary 的宽容 numeric coercion 有意不同。 |
| `number(value)` L949 | utility schema 域仅接受 number，否则 nil。 | 是：字段类型校验。 |
| `exactKeys(value,keys)` L953 | utility 字段必须只包含列表键且每个键都存在；输出 bool。 | 是：严格拒绝多余/缺失字段。 |
| `exactKeysWithOptional(value,allowedKeys,requiredKeys)` L962 | 允许字段集合中部分可选，但 requiredKeys 必须存在；输出 bool。 | 是：Power 记录允许少数 optional component/generator 字段。 |
| `empty(value)` L971 | table 是否为空；输出 bool。 | 是：新空容器可按当前 schema 初始化，不把旧数据当空。 |
| `copyTable(value)` L981 | 递归复制 table；输出 detached copy。 | 是：utility 消费者工作副本与 ModData 根隔离。 |
| `finite(value)` L988 | 输入数值只接受有限 number；输出 bool。 | 是：排除 NaN/±inf ledger 值。 |
| `validPlainData(value,depth,seen)` L993 | 递归验证 modData 的简单标量/table、键类型、深度和循环引用；输出 bool。 | 是：电池/组件 modData 只存可序列化 plain data。 |
| `identityValid(identity)` L1013 | 校验 utility identity 的 rvId/generation/bitmapVersion；输出 bool。 | 是：各 utility record 对当前 identity 有一致结构要求。 |
| `identityMatches(value,identity)` L1020 | 校验 value identity 与请求 identity 三项相同；输出 bool。 | 是：阻止记录/子对象身份串线。 |
| `waterInteger(value)` L1030 | 有限整数 number 校验；输出原值或 nil。 | 是：sink 坐标及 sequence 的 schema 检查。 |
| `waterSinkKey(x,y,z)` L1036 | 坐标转 canonical key；无效输入 nil。 | 是：与 Store/Water ledger 键语义完全一致。 |
| `validWaterAnchor(anchor,slotIndex)` L1042 | 校验精确整数 anchor 是否等于该 slot 的预期 anchor；输出 bool。 | 是：sink 空间身份不能自行声明。 |
| `validWaterSink(value,identity)` L1051 | 校验 sink 字段、identity、slot anchor、格点坐标和 sequence，要求坐标落在 slot managed z；输出 bool。 | 是：防止损坏 sink 指向 RV 外世界位置。 |
| `validWater(value,identity)` L1071 | 校验 water 子 schema/state/sinks，并核对每项 key 与坐标一致；输出 bool。 | 是：utility root 完整校验的一部分。 |
| `validGenerator(value,identity)` L1088 | nil 可接受；非 nil 时校验当前身份、坐标和 object token/fingerprint；输出 bool。 | 是：generator object identity 要防止过期/伪造引用。 |
| `validBattery(value)` L1105 | 校验 battery item schema、允许 fullType、condition、usedDelta 和 plain modData；输出 bool。 | 是：电池 ledger 会影响持久容量与库存变更。 |
| `validComponent(value,fullType)` L1116 | nil 可选；否则校验充电器/逆变器指定类型、condition 与 modData；输出 bool。 | 是：设备组件 ledger 需满足物品型别和状态合同。 |
| `validPower(value,identity)` L1126 | 校验 power 字段/state/效率/功率/时间/设备，再聚合 battery 计算容量、最大充放电功率及 next id；输出 bool。 | 是：power 账本字段相互依赖，需交叉验证派生量。 |
| `validRecord(value,identity)` L1191 | 校验 record 精确 schema/identity，并递归验证 power/water；输出 bool。 | 是：utility root 每条记录唯一顶层谓词。 |
| `validateUtilityRoot(value)` L1198 | nil/空 root 可接受；否则校验 STORE schema 和所有记录，要求 generator 已绑定；输出 bool。 | 是：启动时不接受过期或半初始化的 utility 持久根。 |
| `validateUtilityAtStartup()` L1220 | 无参数；读取 utility STORE_KEY 并运行 root validator；输出 bool/reason。 | 是：四项 startup 扫描之一。 |

| 函数 / 行 | 职责、参数与输出/副作用 | 当前功能必要性 |
|---|---|---|
| `manifestViewForRecord(record)` L1229 | 输入 mapping record；检查关键字段并计算当前 layout bounds，构造临时 READY/COMMITTED manifest view；无效时 nil。 | 是：当当前 mapping 有记录而独立 manifest 缺失时，geometry cross-check 仍需比较同一当前布局。 |
| `validateCurrentRVRecordGeometrySchema(record,manifest)` L1268 | 输入 mapping record 与 persisted/synthetic manifest；严格比较 identity、schema、boundary snapshots、bitmap 位层、shell edge、managed/anchor/position/region，并在通过后注册 boundary；输出 bool。 | 是：把 mapping 与 manifest 作为一组几何合同检查，避免各自字段分别合法但互相冲突。 |
| 几何 `exactKeys(value,fields)` L1269 | table 必须恰有 fields 且不能缺字段；输出 bool。 | 是：geometry 子结构字段形状校验。 |
| 几何 `integerFieldsEqual(left,right,fields)` L1282 | 两个 table 都需 exactKeys；比较每个字段的整数归一值；输出 bool。 | 是：比较 managed/region 等必须同形且同值的结构。 |
| 几何 `integerFieldsMatch(left,right,fields)` L1294 | 两个 table 存在且指定整数值匹配，不强制无额外字段；输出 bool。 | 是：对解码 bitmap、managed 等字段作投影一致性检查。 |
| 几何 `decodeCurrent(encoded)` L1367 | 输入 boundary table；转交 `validateBoundarySchema`；输出 bitmap/identity 或 nil。 | 是：record 与 manifest 两个快照都必须使用相同 decoder/gate。 |
| 几何 `bitmapsEqual(left,right)` L1374 | 对比 managed 字段、bitmapVersion 及每层 walk/build bits；输出 bool。 | 是：直接发现 bitmap 内容分叉。 |
| 几何 `integerArraysEqual(left,right)` L1406 | 对比两个稠密、有效整数数组；输出 bool。 | 是：模板索引序列必须严格一致。 |
| 几何 `shellSetEqual(left,right)` L1435 | 对比两张 keyed shell-edge table 的严格字段与模板索引；输出 bool。 | 是：record 与 manifest 边界壳不能共享身份却有不同结构。 |
| `validateRecordGeometryAtStartup()` L1563 | 无参数；读取 mapping/manifest roots；对每条 mapping 选 persisted manifest 或 synthetic view，执行 geometry gate；输出 bool/reason。 | 是：四项 startup 扫描之一，保证记录与 manifest 的跨根一致性。 |
| `validateAtStartup()` L1604 | 无参数；只运行一次，依序 pcall mapping/manifest/utility/geometry validators；首个失败关闭 gate，全部通过后标记 passed。 | 是：总 gate 唯一 startup 控制流程。 |

## 跨模块比较、复用与抽取建议

### 已有的公共职责边界

- **tick 与事件**：`RV_Server_Core.lua` 已把两段式逻辑 tick、tick 算术和事件注册集中起来。RV_Server、Railroader adapter、BoundaryGuard、屋顶刷新和生成事务都调用 `Core.tick*`；各模块不应自行转成大 Lua number 或注册平行 engine listener。无需再抽取同类工具。
- **utility 持久访问**：Power 与 Water 代码通过 `RV_UtilityStore` 的 `getRecord`/`commit` 等函数访问 ledger；Store 的 detached copy 与显式 commit 是清楚的公共边界。生成前校验走 `UtilityServer.validateGenerationUtilityState`，也已有 facade。
- **schema gate**：mapping、manifest、Boundary、utility ledger、record validation 都显式配置或查询 `DevSaveSchemaGate`。它是开发期统一开关；其全部存在价值会随发行前移除而结束。
- **RV transaction ctx**：`RV_Server.lua` 装配 `ctx` 后按职责 require 子模块；这些模块共享权威 transaction state 和注入函数，形成内部 package contract。此 ctx 不是外部网络 API。

### 有复用收益的候选

| 重复点 | 证据与建议 | 抽取价值判断 |
|---|---|---|
| water sink 整数校验和 key | Store `waterInteger`/`waterSinkKey` L39-L50 与 Gate L1030-L1040 实现相同；Gate 的结果要求和 Store key 必须一致。 | 若 gate 会长期保留，可提炼纯函数 canonical key；当前 Gate 标明开发期整体移除，立即抽取会增加临时依赖面，收益有限。保留两份时应持续用清单确认规则一致。 |
| 深复制 | `RV_UtilityStore.copyTable` L25 与 Gate `copyTable` L981 都递归复制。 | 算法简单且职责绑定 ModData 隔离；因 Gate 临时、消费者不同，共用模块收益低，暂不建议。 |
| 整数/有限数值 helper | Store L11/L39、Gate L88/L945/L988、UtilityServer 所用 `ServerUtil.integer` 各有不同接受范围。 | 不建议无参数地合并：gate 的 `boundaryInteger` 接受 string/Java numeric，utility integer 只接受整数 number，错误归一会放宽 schema。若未来集中，应分别命名严格与宽松契约。 |
| player identity key | UtilityServer `playerKey` L25 允许 ID/name 任一存在；Sentinel `sentinelIdentity` L160 要求两者同时存在。 | 可共用 `id:name` 格式化的小函数，但输入准入政策不同，抽取收益很小；不应把准入也合并。 |
| transaction busy 查询 | UtilityServer `serviceBusy` L73 与 Sentinel `serverTransactionMutexStatus` L221 都问 generation/roof；Sentinel 要求两个 API 均可用，UtilityServer 对缺少的单项 API不视为 busy。 | 可在 `RV.Server` 提供统一 fail-closed busy 接口并返回原因，避免两套口径分歧；收益中等，前提是先确定缺接口时的统一行为。 |
| Core 注册失败检查 | Commands L278 与 adapter Tick L247 有相同的 `requireCoreRegistration`。 | 仅两处短 helper，作为每个组合模块的本地启动边界容易定位；抽成公共工具的维护收益低。 |

## 拆分判断

1. **优先候选：`RV_RailroaderServer_Sentinel.lua`**。约 636 行/21 个函数，同时提供 Enter/Exit 命令处理、在线玩家与 utility mapping 同步、roof/generation mutex、geometry gate、sentinel 定位及返还。建议在继续扩展时拆成 `EntryExit`（命令、玩家快照与 mapping 同步、事务 gate）和 `SentinelRecovery`（候选识别、返还和告警）两个子模块；跨事务 mutex 和 geometry gate 应由同一个安全服务持有，避免拆开后出现不同门禁。它已有 `ctx` 组装模式可承接拆分。
2. **体量最大但暂不宜投入：`RV_DevSaveSchemaGate.lua`**。1,644 行、59 个函数表达式，内部明显分成 boundary/mapping、manifest/bounds、utility ledger、record geometry 四组。若开发期继续长期依赖，可拆四个 validator 子模块，保留本文件负责 configure、状态和顺序执行；但源码明确要求 release 前删除整个 gate，因此短期拆分会扩张一份临时机制。
3. **可观察而非当前必拆：`RV_UtilityServer.lua`**。492 行、37 个函数表达式，前半为命令协议/session/idempotency，后半为 tick 与每小时/十分钟维护。若 utility 服务增长，可分成 command/session 与 lifecycle 两个文件；现在两者共用私有 store、锁与广播函数，拆分需要再做一个内部 context。
4. `RV_Server.lua` 虽然装配依赖多，但它是组合根；继续拆会模糊初始化顺序。`RV_Server_Core.lua` 的 tick 算术与 dispatcher 都属于单一“服务端事件时基”，不建议为了代码长度拆开。

## 跨模块内部数据访问与接口

| 位置 | 访问内容与分类 | 是否应提供接口 |
|---|---|---|
| `RV_UtilityServer.lua:L369` 读取 `adapter._mappingEpoch`；该字段在 `RV_RailroaderServer.lua:L47` 初始化、mapping 模块更新（符号搜索命中 `RVMapping/RV_RailroaderServer_Mapping.lua:L103`）。 | UtilityServer 直接读取 Railroader adapter 的下划线私有 epoch，这是明确的隐藏进程状态依赖。 | 建议 adapter 提供 `mappingEpoch()`/`currentMappingEpoch()` 只读接口，或直接提供“是否应重同步”接口。收益中等：既能去掉跨模块 `_` 访问，也能防止 epoch 表示方式改变时 utility 层失效。 |
| `RV_RailroaderServer_Sentinel.lua:L275` 读取 `Adapter._ticks`；它由 Tick 模块 L31/L174 更新。 | Adapter 内部子模块之间共享最后一次已接受 tick 的隐藏状态。 | 可以提供返回副本的 `Adapter.currentTick()`；收益偏低到中等，因为同一 adapter 的拆分文件由一个 ctx 组装根加载，且 Core 已有 `getTick()`。若 `_ticks` 只代表已接受 callback tick，则显式 adapter accessor 能比直接 fallback 更清晰。 |
| `RV_Server_Core.lua:L139-L140` 把注册表放在 `Core._state`，便于 require reload 后保留状态；本目录外部调用使用 `Core` 导出的 `register*`/`tick*` API。 | `_state` 是公开 table 上的模块私有 backing state。符号检索未发现其他 RailroaderRV 模块读取它。 | 无需给其它模块新增接口；保持局部 owner 访问即可。更稳妥的后续实现是弱化该字段可见性，但在 Lua require reload 下要保留 registry，因此目前接口隔离收益低。 |
| `RV_Server.lua:L145-L194` 构造并传递 `ctx`；后续 RV_Server 子模块读写 `ctx.pendingGeneration`、`serverTick`、transaction flags/queues 并调用已注入服务。 | 组合根明确把 RV_Server 内部 mutable transaction state 作为 package-private ctx 合同。 | 不建议逐字段造 getter/setter：这些子模块共同推进同一事务，抽象会增加大量样板并让读写流程更难跟踪；应保持为内部注入契约，避免跨 package 暴露。 |
| Sentinel `L310-L388`、`L397-L487` 读取 `map.players`、`map.locomotives`、`record.players/managed/boundary/rvPosition/anchor`。 | 读取 mapping/manifest 持久结构中的字段；这是当前 schema 的公开数据合同，并且函数只读这些字段后做关系/几何安全判断，不是访问 mapping 模块的局部闭包变量。 | 几何一致性已有 `RV.Server.validateCurrentRVRecord`/`currentRVRecordGeometryConsistent` 接口，但候选识别仍需检查具体玩家关系、anchor 和位置。再增加一个完整“sentinel candidate”API会把 adapter 逻辑移回 mapping owner，当前收益低于直接读已验 schema。 |
| `RV_UtilityStore.lua:L82-L96`、UtilityServer L51-L88 通过 `RV.Server` 的命名函数取 current manifest、mapping 和 transaction status；Sentinel 多处也调 `RV.Server` 查询。 | 显式公开服务 API，没有直接读 `RV.Server` 局部事务变量。 | 现有 facade 边界明确，保留即可。 |

## 清单与只读验证证据

- 文件清单（来自 `rg --files media/lua/server/RailroaderRV/Core`）：`RV_UtilityStore.lua`、`RV_UtilityServer.lua`、`RV_Server_ManifestValidation.lua`、`RV_Server_Core.lua`、`RV_Server_Commands.lua`、`RV_Server.lua`、`RV_RailroaderServer_Tick.lua`、`RV_RailroaderServer_Sentinel.lua`、`RV_RailroaderServer.lua`、`RV_DevSaveSchemaGate.lua`，共 10 个。
- 逐文件函数表达式扫描使用 `rg -n -P '\bfunction\s*(?:[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\s*)?\('`；总计 187 处，包含具名、表字段、变量赋值、模块加载闭包、嵌套 helper 与匿名回调。文档按定义起始行逐项核对，合计 187 项：Store 20、UtilityServer 37、ManifestValidation 3、Server_Core 28、Server_Commands 6、Server 4、RailroaderServer_Tick 7、RailroaderServer_Sentinel 21、RailroaderServer 2、DevSaveSchemaGate 59。
- 各文件行数为 241、492、32、382、327、220、271、636、147、1644，合计 4,392 行；函数明细均附对应 Lua 文件名和定义行号。
- 对 `_state`、`Adapter._*`、`server._*` 做了目标目录与 RailroaderRV server Lua 符号检索，用于识别跨模块隐藏状态；对 Core 导出 API、Store、SchemaGate 的引用做了目标包引用搜索，用于区分公开函数和内部状态。
- API 使用扫描额外发现：`RV_UtilityServer.M.onObjectRemoved`、`M.snapshotForPlayer`、`RV_Server_Core.sendToClient`、`DevSaveSchemaGate.failureReason` 和公开 wrapper `validateBoundarySchema` 在当前源码树无显式调用点；`RV_UtilityStore.number` 无本地调用点。动态/外部 require 用途未能通过静态树内搜索确认，因此报告将它们标为未证实或诊断/未来 API，而非断言全局不可达。
- 文档仅在 `docs/module-analysis/server-Core.md` 新建。未修改 Lua/配置/测试，不运行 runtime 测试。
- 覆盖限制：相邻目录只做符号级搜索；它们各自函数的逐项语义由对应模块报告覆盖。本报告不能替代运行时/联机验收。

## 第二阶段组合更新

Core 现在装配 `GenerationTransaction` 服务，并向 WorldObjects/GenerationBuild、TemplateRecovery、RoofRefresh、GenerationFlow 和 Ack 注入依赖。Boundary `onTick` 在 player update 后派发注册的 post-player-tick callbacks；TemplateRecovery 通过这个窄入口运行，不把 queue API 挂在 Boundary namespace。Railroader Adapter 的 mapping epoch 由 `RV_RailroaderServer.lua` 的 `currentMappingEpoch` / `advanceMappingEpoch` 管理，UtilityServer 与 Mapping 不再直接读写 epoch 字段。Roof process-local 状态只在 RoofRefresh 包使用，Core context 仅提供组合容器。见[第二阶段报告](phase2-structure-optimization.md)。
