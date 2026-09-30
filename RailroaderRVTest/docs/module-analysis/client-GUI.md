# client/RailroaderRV/GUI 模块分析

## 假设、范围与核验方法

- 假设：目录中的 Lua 文件共同构成客户端 GUI/交互层；名称含 Client、Visuals 的文件属于该目录模块，即使没有窗口控件也纳入分析。
- 范围：逐一分析 media/lua/client/RailroaderRV/GUI/ 的 11 个直接文件。仅为验证调用关系，少量只读查看其入口、共享常量及服务端对应 wire payload 的定义位置；不把目录外文件算作本模块函数清单，不对它们作完整分析。
- 成功标准：11 个文件全部入册；所有函数表达式（具名、表方法、赋值、嵌套、匿名 pcall/UI/Event 回调）均列出精确起始行，并说明参数、返回或副作用、GUI 语义及功能必要性；另覆盖通用提取、拆分和跨模块数据边界。
- 只读核验：PowerShell 文件清单/行数、rg 函数表达式扫描、逐行查看源码并交叉核对条目；只写本文档，不运行 Lua、游戏或 runtime 测试。
- 已核验：目录包含以下 11 个 Lua 文件、未见其他直接文件；函数表达式扫描总计 290 处（本报告按文件逐项列出）。

## 模块划分

| 文件 | 子模块职责 |
|---|---|
| RV_ContextMenu.lua | GUI 加载入口和依赖协调；自身无函数定义。 |
| RV_ContextMenu_Relocation.lua | 技术生成菜单回调、临时/最终迁移阶段、客户端 ACK。 |
| RV_ContextMenu_RoomOwnership.lua | 房间归属失效检测、修复、持续守卫及迁移目的房间检查。 |
| RV_RailroaderContextMenu.lua | Railroader 机车进出 RV 菜单、映射候选、Ride 状态过渡。 |
| RV_UtilityClient.lua | 实用设施命令意图、请求 ID/session、ACK/snapshot/超时缓存。 |
| RV_UtilityContextMenu.lua | 水槽连接和仪表盘的世界/物品上下文菜单。 |
| RV_UtilityDashboard.lua | 客户端电力与水务快照展示、操作按钮和回执状态。 |
| RV_BoundaryClient.lua | 接收服务端边界纠正并更新本地玩家位置。 |
| RV_ProtectedDemolition.lua | 拦截不应拆除的受保护模板对象。 |
| RV_BoundaryWallVisuals.lua | 对严格身份匹配的边界木墙关闭本地渲染。 |
| RV_WardrobeVisuals.lua | 对严格身份匹配的衣柜对象关闭本地渲染。 |

下文「必要」判断是指该功能是否为当前代码所提供的模块职责所需，不等于判断每个局部 helper 是否必须保持为独立函数。参数中 callback / predicate 均按调用约定解释；异常保护闭包没有显式参数，其读取被捕获的对象并把引擎方法结果交给 pcall。未注明返回值的 Lua 函数在源码中没有显式 return，按 nil/副作用理解。

## 按文件逐函数清单

### RV_ContextMenu.lua

共 79 行，0 个函数表达式。第 8–24 行载入常量、两种视觉模块、拆除保护、边界客户端及 Layout；第 25–74 行集中构造 Client 与 context 状态；第 76–77 行把同一 context 交给迁移和房间归属闭包，第 79 行返回 Client。该文件本身必须保留为入口（依赖加载顺序和状态组装都在此处）；没有独立函数可评估参数或输出。入口在第 12–17 行 pcall require BoundaryClient 并记录失败，但第 11 行先无保护 require ProtectedDemolition，而后者第 4 行又无保护 require BoundaryClient；因此正常顺序下 BoundaryClient 真正缺失时会先由嵌套 require 中断，入口的 pcall 不能使该依赖变成可选。

### RV_BoundaryClient.lua

功能：消费服务端权威的 boundary correction wire 消息，按 onlineId 找到本地玩家，仅应用更新序号更大的纠正；保存每玩家 identity/序号。清除事件断开后的本地状态。

| 行 / 函数 | 参数、结果与模块语义；必要性 |
|---|---|
| 18 number(value) | number/string/可数值转换对象转为 number，否则 nil；用于安全解析 correction。必需的解析步骤。 |
| 22 匿名 pcall 闭包 | 无参数，捕获 value 并计算 value + 0；返回转换值或由 pcall 捕获错误。Lua userdata 转换兼容分支必需。 |
| 28 integer(value) | 先转数值，再要求 floor 不变；整数或 nil。供身份、代次、序号校验。必需。 |
| 34 call(target, method, ...) | 安全调用目标方法；返回成功标志及最多三个结果，供 Java 对象 API 边界。必需的防异常包装。 |
| 43 onlineId(player) | 玩家对象 -> 有效 online ID；无网络 ID 时回退 playerNum。用于多本地玩家查找。必需。 |
| 51 localPlayerByOnlineId(id) | 服务端 ID -> 当前活动本地玩家或 nil。必需，否则不能把纠正应用到正确客户端角色。 |
| 63 applyPosition(player, target) | player 与 x/y/z 表；调用 teleportTo、坐标/运动历史 setter 和可用的 current-square setter；返回是否有任一坐标写调用成功。执行纠正的核心步骤。 |
| 84 Client.onCorrection(args) | 服务端参数表；校验 bitmap/generation/sequence/onlineId/坐标，拒绝过期序号，成功后更新 _states；无返回。必须，身份和顺序门。 |
| 107 Client.onServerCommand(module, command, args) | 网络模块名、命令名、payload；仅对本模组 boundary correction 转发，无返回。事件入口必需。 |
| 114 Client.onTick() | 无参；增加并导出 _tick。当前不参与纠正判定，只是已暴露计数状态；对本文件现有功能非必需，可删除或说明消费者（目录内未见消费者）。 |
| 126 匿名 OnDisconnect 回调 | 无参；新建 states 并更新 Client._states；断线清理必需。 |

### RV_BoundaryWallVisuals.lua

功能：只隐藏带当前代次、bitmap、template manifest、owner、边界角色及对象身份标记的三个支撑木墙；对象新增和 square 加载/复用时重试。变更仅为客户端渲染状态，不删除对象。

| 行 / 函数 | 参数、结果与模块语义；必要性 |
|---|---|
| 30 call(target, method, ...) | 对象安全方法调用，返回 success 和结果；通用本地 API 包装。对安全访问必要，与邻接视觉文件重复。 |
| 39 integer(value) | 委托 C.finiteInteger；验证标记字段。必需的严格字段校验薄包装。 |
| 43 warnOnce(message) | 首次打印视觉 API 失败原因；无返回。故障观测辅助，隐藏功能本身不依赖它。 |
| 50 isTaggedBoundarySupportWall(object) | 对象 -> 是否为本代、受保护且精确 manifest 身份的边界支撑墙；必需的 fail-closed 命中条件。 |
| 93 hideBoundarySupportWall(object) | 只有命中时 setDoRender(false)、复读验证并 dirty redraw；无返回。模块核心必要副作用。 |
| 113 onObjectAdded(object) | OnObjectAdded 参数；委托隐藏函数。事件适配必需。 |
| 117 onGridSquareLoaded(square) | GridSquare 参数；迭代 Java object list 并对对象逐一隐藏。处理存档/流送重用必需。 |

### RV_WardrobeVisuals.lua

功能：不移除衣柜碰撞对象，只对固定模板坐标/衣柜身份和当前 schema 完全匹配的对象关闭本地绘制，并在对象新增、square 加载或复用时补做。

| 行 / 函数 | 参数、结果与模块语义；必要性 |
|---|---|
| 25 call(target, method, ...) | 安全调用引擎方法，返回成功及结果；失败时不带出异常值。必要的对象访问包装，与 BoundaryWallVisuals 重复。 |
| 34 integer(value) | 委托 C.finiteInteger；用于 modData 严格比较。必需薄包装。 |
| 38 warnOnce(message) | 最多记录一条视觉故障；非核心观察功能。 |
| 45 isWardrobeTemplateEntry(entry) | 模板条目 -> 固定类别、位置、sprite、朝向、protectionClass 和隐藏状态是否齐全；防止宽泛隐藏，必需。 |
| 56 isTaggedWardrobe(object) | 对象 -> 核对 owner/rvId/generation/bitmap/manifest/anchor/世界坐标和 live object name/sprite/direction；必需的身份门。 |
| 112 hideWardrobe(object) | 验证后设置 doRender false、复核并标记渲染块 dirty；模块核心副作用。 |
| 134 onObjectAdded(object) | 新对象事件转发到 hideWardrobe；必需。 |
| 138 onGridSquareLoaded(square) | 对加载/复用 square 中对象重试隐藏；必需处理迟到对象。 |

### RV_ProtectedDemolition.lua

功能：仅在本地客户端拦截拆毁/拆卸属于当前 RV 且 manifest 明确标为禁止的模板对象；缺字段或身份矛盾按失效数据拒绝操作并通知。Cab 内部和承载门窗的位置排除。该模块同时需要验证持久标记与现场对象身份。第 4 行要求 BoundaryClient 加载以取得其事件注册副作用，但局部 BoundaryClient 变量后续无引用；RV_ContextMenu 入口也负责加载它，当前正常入口中形成冗余 require。

| 行 / 函数 | 参数、结果与模块语义；必要性 |
|---|---|
| 25 call(target, method, ...) | 安全调用对象方法，返回 success 与结果；异常失败不返回错误细节。用于客户端 Java API，必需。与其他 GUI 文件重复。 |
| 34 finiteInteger(value) | 委托 C.finiteInteger；所有 tag 数值统一校验，必需。 |
| 39 tagMatchesStaticIdentity(tag, expected, templateIndex, protectionClass) | 持久 tag、模板 manifest 条目、索引与保护类 -> 布尔；只校验静态字段。防止标记被改后误豁免，必需。 |
| 59 objectCoordinates(object)（赋值定义） | object -> 方格 x/y/z 整数或 nil；用于真实 world/template 对应。必需。 |
| 72 isDoorOrWindow(object) | 判断 Door/Window 原生类或 Thumpable 子类的 door/window 状态；决定 cab-door host 排除。该排除规则需要它。 |
| 93 showInvalidRVData(character) | 角色对象；优先调用 UtilityClient 通知，回退本地 halo；无有用返回。错误提示是 fail-closed 可理解性所需，但共享提示函数可减少重复。 |
| 111 匿名 halo pcall 闭包 | 无参，捕获 character/message 并设置白色 5 秒 halo；返回 nil，由 pcall 提供成功标志。仅为 fallback UI 的异常隔离所需。 |
| 114 templateTagFailureReason(data, tag) | root modData 与嵌套 tag -> 具体首个 schema 不匹配字符串，成功 nil；错误定位所需。 |
| 115 嵌套 fail(reason) | 字符串 -> 原样返回，供上方稳定地产生原因；对校验流程有用但结构上可内联。 |
| 142 rejectInvalidRVData(character, reason) | 打印原因、提示并返回 true（表示拒绝/拦截）；fail-closed 核心。 |
| 149 objectMatchesStaticIdentity(object, tag, expected, templateIndex, protectionClass) | 持久字段与现场对象 -> 匹配 true/false；另查 index/square/class/name/sprite/direction/north。保护决策必须验证 live 身份。 |
| 151 嵌套 fail(reason, detail) | 错误代号及诊断细节 -> 固定 false；当前 body 未使用 detail 参数、也不向外返回它，是可删冗余参数/局部封装。对保护判定非独立必要。 |
| 204 resolveTemplateObject(object, tag) | 对象和 tag -> 当前模板对象/索引/保护/anchor/world/offset，或 nil 与原因；借 TemplateGeometry 将 world coordinate 对回 manifest，核心必要。 |
| 242 cabDoorWindowHost(offset) | 模板 offset -> 是否为 cabin 东/南侧门窗 host；供合法 cab 门窗排除，必要。 |
| 253 isCurrentProhibitedObject(object, character) | 现场对象及角色 -> 当前对象是否禁止拆除；检查归属、tag、manifest/live identity、Cab 边界和 protectionClass；主策略函数必需。 |
| 308 actionIsBlocked(actionName, character, object) | timed-action 标识、角色、对象 -> client 且当前受保护时 true；服务器端不在此重复拦截。连接策略与 action wrapper 所需。actionName 当前未参与计算，可删参数。 |
| 317 wrapDestroyAction(action) | 定时动作类表；有原 new 且未包装时替换构造器；无返回。接入 ISDestroyStuffAction 所需。 |
| 323 赋值闭包 action.new(self, character, item, cornerCounter) | timed-action receiver、角色、目标 item、corner counter；拦截时返回 ignoreAction 表，否则逐参转发原构造函数。兼容原参数并阻止受保护拆毁，必需。 |
| 332 wrapDismantleAction(action) | 拆卸动作类表；幂等安装 wrapper。接入 ISDismantleAction 所需。 |
| 338 赋值闭包 action.new(self, character, thumpable) | receiver、角色、拆卸对象；受保护返回 ignoreAction，否则原参数转发。必要拦截点。 |

### RV_UtilityClient.lua

功能：客户端发实用设施“意图”而不直接改世界/物品；请求携带 requestId/sessionNonce 和仅供服务端重查的 hint。维护 ACK 等待状态、snapshot 展示缓存、超时与连接清理。此为 utility GUI 与服务端命令之间必需的传输边界。

| 行 / 函数 | 参数、结果与模块语义；必要性 |
|---|---|
| 28 Client.clearConnectionState() | 无参；清 sequence/nonce/pending/snapshot，并通知菜单/仪表盘清映射和 UI。断线/重连隔离必需。 |
| 44 finite(value) | value -> 是否 number。注：不排除 NaN/±inf，名称比实际范围校验更强；服务于时间戳判定。 |
| 48 nowSeconds() | 无参；安全调用 os.time，返回数值秒或 nil。用于请求超时，必需。 |
| 53 text(key, fallback) | 本地化 key 与默认文本 -> 翻译或 fallback；提示显示必需。 |
| 63 Client.showFeedback(player, message) | 玩家与文本 -> halo 是否成功；客户端请求提示接口，必需。 |
| 69 rejectSend(player) | 玩家；通知 Dashboard send-failure 或 halo，返回 false,nil。集中化发送失败处理，必要。 |
| 83 newNonce() | 无参；时间加可用 ZombRand 得到 session 字符串。隔离请求序列必需。 |
| 93 localPlayer(playerNum) | 本地玩家槽号 -> 玩家或 nil；默认 snapshot/错误提示定位。必需。 |
| 99 nextRequestId() | 无参；增加请求计数，返回 nonce:sequence 字符串。请求关联 ACK 所需。 |
| 104 hintForObject(object) | 世界对象 -> x/y/z/objectIndex hint 或 nil；客户端坐标仅是服务端重新校验的选择提示，不是可信状态。必要。 |
| 107 匿名 pcall 闭包 | 无参，捕获 object，返回 object:getSquare()；保护 Java getter 失败。 |
| 109 匿名 pcall 闭包 | 无参，捕获 square，返回 square:getX()；安全提取 hint 的 X。 |
| 110 匿名 pcall 闭包 | 无参，捕获 square，返回 square:getY()；安全提取 hint 的 Y。 |
| 111 匿名 pcall 闭包 | 无参，捕获 square，返回 square:getZ()；安全提取 hint 的 Z。 |
| 112 匿名 pcall 闭包 | 无参，捕获 object，返回 getObjectIndex；安全提取对象序号。以上四个 getter 闭包是逐项字段读取的防异常边界。 |
| 117 hintForItem(item) | 物品 -> itemId hint 或 nil；只让服务器重查选中物品，必需。 |
| 119 匿名 pcall 闭包 | 无参，捕获 item，返回 item:getID()；读取 ID 且隔离 userdata 异常。 |
| 123 Client.ensureSession() | 无参；惰性建 nonce 并返回它。由 Client.send 调用，可与 send 合并但维持会话 API 也可读。 |
| 128 Client.send(player, operation, targetHint, sourceHint) | 玩家、本次操作枚举、可空目标/来源 hint -> 成功和 requestId 或 false,nil；构造命令并登记 pending。核心 wire 传输。 |
| 160 Client.requestAddFuel(player, item) | 玩家与物品；构造来源 item hint 后发 add-fuel 意图；fuel UI 必需。 |
| 166 Client.requestAddBattery(player, item) | 玩家与物品；battery 意图；必需。 |
| 172 Client.requestInstallComponent(player, operation, item) | 玩家、组件操作码、物品；通用安装意图包装；chargers/inverters 共用，必要。 |
| 178 Client.requestRemoveBattery(player, batteryId) | 玩家与服务端 snapshot 内 battery id；发拆卸意图；必需。 |
| 183 Client.requestPowerOperation(player, operation) | 玩家与操作码；发启动/停止类意图；必需。 |
| 187 Client.requestRefreshDevices(player) | 玩家；请求服务端重扫设备；必需。 |
| 191 Client.requestSnapshot(player) | 玩家；请求当前只读 UI 状态；必需。 |
| 195 Client.requestGenerator(player, operation, object) | 玩家、操作码、对象；对象 hint 后发命令。目录内 rg 只找到定义、没有调用方；当前功能非必需/疑似遗留，可删或接入明确按钮前保留为预留 API。 |
| 201 Client.requestWaterConnection(player, object, connected) | 玩家、对象、必须为 boolean 的目标连接状态；加入目标 hint 后发意图；必需。 |
| 213 Client.isRequestPending(requestId) | 请求 ID -> 本地是否还待 ACK；Window.close 用于关闭提示；必需。 |
| 217 notifyRequestTimeout(requestId, request) | ID 和本地 pending 记录；告知 dashboard 或 halo；无返回。必要的 timeout UI。 |
| 232 Client.onTick() | 无参；清理超过 15 秒的 pending 请求并通知；避免永久等待提示，必要。 |
| 244 showInvalidRVData(player) | 玩家 -> 用翻译/default halo 提示需删测试档重建；无返回。当前 schema fail-closed 的用户解释必要。 |
| 255 匿名 pcall 闭包 | 无参，捕获 player/message，设置 5 秒 halo；由 pcall 捕获 API 异常。 |
| 261 Client.showInvalidRVData(player) | 可选玩家；未传则取 slot 0，调用内部提示函数；外部接口必要。 |
| 265 Client.onServerCommand(module, command, args) | 网络模块、wire 命令、payload；分派 mapping/snapshot/ACK、删除 pending 并通知 dashboard/玩家。客户端接收核心入口。 |
| 318 赋值闭包 Client.getSnapshot() | 无显式参数；返回缓存的只读展示 snapshot。Dashboard 用作 UI 数据接口；必要。 |

函数扫描口径补充：Client.onServerCommand 内对已存在 function 值的检查或 pcall 调用不是新的函数表达式；本文件的 36 个计数只包括本清单标出的位置。

### RV_UtilityContextMenu.lua

功能：世界物件菜單列出水槽連/斷水意圖和儀表盤入口；物品菜單列出加燃料。客户端检查候选位置/工具和标记来避免误显示，但服务端仍须重查世界对象、玩家及物品身份。

| 行 / 函数 | 参数、结果与模块语义；必要性 |
|---|---|
| 15 text(key, fallback) | 翻译 key/default -> 文本；菜单双语显示必需。 |
| 26 localPlayer(playerNum) | 本地玩家编号 -> 玩家或 nil；事件适配必需。 |
| 32 already(context, label) | 菜单与标题 -> 是否已有同名项；防多个 OnPre/OnFill hook 重复加项，必需。 |
| 44 addFuelOption(player, item) | 玩家、燃料候选 -> 转交 Client.requestAddFuel；必须提供菜单回调。 |
| 48 dashboardOption(player) | 玩家 -> 显示 Dashboard 并请求新 snapshot；仪表盘菜单回调必要。 |
| 53 hasPipeWrench(player) | 玩家 -> 背包含 PipeWrench 与否；水管操作的 UI 提示过滤必要，非权限门。 |
| 61 setWaterConnection(player, object, connected) | 玩家、sink 对象、目标布尔态 -> false 或 true/requestId；菜单回调桥接 utility API，必要。 |
| 67 localSlot(player, x, y, z) | 玩家和目标对象格坐标 -> 二者同属的 managed slot 编号或 nil；仅决定本地候选菜单，当前几何/schema；降低误显示所需，不能替代服务端授权。 |
| 92 addWaterOptions(player, context, worldObjects) | 玩家、菜单、被点选对象列表；核验管钳、fluid sink identity、状态和 slot，再添加切换选项；水务交互必要。 |
| 131 addDashboardOption(player, context) | 玩家与菜单；询问 RailroaderContextMenu 候选 API，符合时添加一项；仪表盘入口必要。 |
| 149 Menu.onPreFillWorldObjectContextMenu(playerNum, context, worldObjects, test) | 游戏上下文菜单事件参数；空方格也尝试加仪表盘入口；无返回。该入口时序为 dashboard 在空地上可用所需。test 参数当前未用。 |
| 157 Menu.onFillWorldObjectContextMenu(playerNum, context, worldObjects, test) | 菜单事件；增加 dashboard 与水务选项。实际世界物件事件必要；test 参数未用。 |
| 165 Menu.onFillInventoryObjectContextMenu(playerNum, context, items) | 玩家编号、菜单、选中物品列表；找可加汽油的 FluidContainer 并加选项，发现后返回；物品入口必要。 |
| 172 匿名 pcall 闭包 | 无参，捕获 item 并返回 item:getFluidContainer()；读取液体容器且隔离引擎异常，必要。 |
| 180 匿名 pcall 闭包 | 无参，捕获 container/fluid 并返回 container:contains(Fluid.Petrol)；只检测是否含汽油，不改液体；必要的本地过滤。 |

### RV_UtilityDashboard.lua

功能：快照驱动的单实例 ISCollapsableWindow；展示服务器电池/燃油/发电机/水务数据，按钮只调用 Client 意图接口。客户端递归浏览玩家主背包和容器，给物品选择菜单，不直接消费/安装物品。

| 行 / 函数 | 参数、结果与模块语义；必要性 |
|---|---|
| 15 tr(key, fallback) | 翻译 key/default -> 文本；必要 UI helper。 |
| 21 number(value) | number 或数值字符串 -> number/nil；展示解析需要。 |
| 27 display(value, digits) | 数值、精度 -> 格式化字符串，空为“-”；读数显示需要。 |
| 33 ratio(amount, capacity) | 当前值、容量 -> clamp 到 [0,1] 比例，非法/非正容量为 0；进度条必须。 |
| 39 mappingKey(value) | snapshot/映射表 -> rvId:generation:bitmapVersion 或 nil；防旧 RV snapshot 串到新映射，必要。 |
| 46 utilityMapping() | 无参；向 RailroaderContextMenu 要映射副本，缺接口为 nil；UI identity scoping 需要。 |
| 55 collectionItems(collection) | Java list 或 Lua table -> Lua 数组；物品遍历的兼容层，必要。 |
| 59 匿名 pcall 闭包 | 无参，捕获 collection 并返回 size()；安全读 list 长度。 |
| 62 匿名 pcall 闭包 | 无参，捕获 collection/index 并返回 get(index)；安全读每项。 |
| 74 inventoryItems(inventory, result, seen) | 背包、结果数组、已访问表；递归累加物品并避免容器循环。item 菜单所需。 |
| 77 匿名 pcall 闭包 | 无参，返回 inventory:getItems()；安全进入背包。 |
| 81 匿名 pcall 闭包 | 无参，读 item.getInventory 方法成员（不调用）；用于判断 item 是否是容器，防 userdata 访问异常。 |
| 83 匿名 pcall 闭包 | 无参，调用 item:getInventory()；递归进入容器，必要。 |
| 89 itemType(item) | 物品 -> fullType 字符串；安装物品筛选必要。 |
| 90 匿名 pcall 闭包 | 无参，返回 item:getFullType()；隔离 Lua/Java API 访问异常。 |
| 94 itemName(item) | 物品 -> 显示名，失败 fallback 到 itemType；菜单易读性需要。 |
| 95 匿名 pcall 闭包 | 无参，返回 item:getName()；隔离 API 异常。 |
| 99 fluidFuel(item) | 物品 -> 可用纯汽油数量或 nil；只作 UI 筛选，服务端再次验证。必要的燃料菜单规则。 |
| 100 匿名 pcall 闭包 | 无参，返回 item FluidContainer。 |
| 103 匿名 pcall 闭包 | 无参，返回 container 是否含 Petrol。 |
| 104 匿名 pcall 闭包 | 无参，返回 container 是否 mixture。 |
| 105 匿名 pcall 闭包 | 无参，返回 container amount。 |
| 111 batteryType(fullType) | fullType -> 是否四类支持的 Base 汽车电瓶；物品筛选必要。 |
| 116 setSubmitted(window, sent, requestId) | window、发送状态、请求 ID；保存等待状态并更新 status label；多个按钮共用，必要。 |
| 128 Window:createChildren() | self；创建状态文本、进度条、九个按钮；完整仪表 UI 必需。 |
| 134 内嵌 label(x, y, w, value) | 控件坐标/宽度/文本 -> 已初始化并加入窗口的 ISLabel；只在 createChildren 使用，可局部存在。 |
| 142 内嵌 bar(y, color) | y 与颜色 -> 已初始化进度条；同上。 |
| 210 Window:setStatus(value) | 文本；改写状态 label，无返回；状态显示必需。 |
| 214 Window:request(operation) | 操作码；调用 Client.requestPowerOperation 并设 sent 状态；多个简单按钮共用，必要。 |
| 218 Window:openInventoryMenu(predicate, callback, emptyLabel) | item 筛选、发请求回调、无候选文案；递归搜本地背包后生成 context menu；加燃料/电池/组件共用，必要。 |
| 225 匿名 pcall 闭包 | 无参，捕获 player 并返回 getInventory；读本地 inventory 时防异常。 |
| 237 匿名 menu callback(window) | 菜单回调传入窗口；捕获 candidate/item 和 callback，调用意图接口、更新等待状态；菜单点选必需。 |
| 248 Window:openBatteryRemovalMenu() | self；按服务器快照中 battery id 列项供拆除，空列表禁用提示；必要。 |
| 263 匿名 menu callback(window) | 捕获 battery id；调用 requestRemoveBattery 并显示等待状态；必要。 |
| 275 Window:onAddFuel() | self；传入纯燃油 predicate、Client.requestAddFuel callback 和空列表文案；按钮入口必要。 |
| 276 匿名 predicate(item) | 物品 -> fluidFuel 是否可用；提供燃料过滤，必要。 |
| 277 匿名 callback(player, item) | 窗口玩家和选中的物品 -> Client.requestAddFuel 结果；纯 adapter，必要。 |
| 281 Window:onAddBattery() | self；用 batteryType 筛选并发 add battery 请求；按钮入口必要。 |
| 282 匿名 predicate(item) | 物品 -> supported battery fullType 布尔值；必要过滤。 |
| 283 匿名 callback(player, item) | 玩家/物品 -> Client.requestAddBattery 结果；必要 adapter。 |
| 287 Window:onRemoveBattery() | self；打开服务端 snapshot 拆除项；按钮入口必要。 |
| 291 Window:onInstallCharger() | self；配置目标 fullType 过滤、组件意图和空态；按钮入口必要。 |
| 292 匿名 predicate(item) | 物品 -> 是否 RVCharger；安装候选筛选必要。 |
| 294 匿名 callback(player, item) | 玩家/物品 -> INSTALL_CHARGER 请求结果；必要 adapter。 |
| 299 Window:onInstallInverter() | self；配置逆变器筛选及意图；按钮入口必要。 |
| 300 匿名 predicate(item) | 物品 -> 是否 RVInverter；必要。 |
| 302 匿名 callback(player, item) | 玩家/物品 -> INSTALL_INVERTER 请求结果；必要 adapter。 |
| 307 Window:onRemoveCharger() | self；发 REMOVE_CHARGER；按钮入口必要。 |
| 311 Window:onRemoveInverter() | self；发 REMOVE_INVERTER；按钮入口必要。 |
| 315 Window:onGeneratorToggle() | self；根据快照 generatorEnabled 选择启动/停止意图；按钮入口必要。 |
| 322 Window:onRefreshDevices() | self；向服务端请求刷新并设等待状态；按钮入口必要。 |
| 326 Window:refresh(snapshot) | 可选 snapshot；仅接受与当前 mappingKey 同一 identity 的状态，重绘电力/水务读数；缺快照显示 placeholder。窗口核心更新函数。 |
| 454 Window:close() | self；若仍 pending 提醒，隐藏并解绑 Dashboard.instance；生命周期必需。 |
| 464 Window:new(x, y, player) | 窗口位置及玩家；造窗口实例、记录映射 key、设标题和大小；构造必要。 |
| 478 Dashboard.format(snapshot) | snapshot -> 简短电池摘要或 waiting 文案；rg 在 media/lua 中只有定义，无调用；当前 UI 不是必需，疑似过时 helper。 |
| 488 Dashboard.refresh(snapshot) | 可选 snapshot；若单实例存在转到 Window.refresh；跨 client callback 的窄接口，必要。 |
| 494 Dashboard.onConnectionReset() | 无参；隐藏并移除旧窗口，清单例；跨 client disconnect 接口必要。 |
| 502 localPlayer(player) | 可选玩家；缺省取 slot 0；多入口打开窗口必需。 |
| 509 Dashboard.show(player) | 玩家；复用/置顶现有窗口，或按屏幕尺寸新建并加入 UI manager；核心打开接口。 |
| 530 Dashboard.onSnapshot(player, snapshot) | 玩家、snapshot；只刷新可见且拥有该玩家和 mappingKey 的窗口，返回是否接收。客户端消息回调门，必要。 |
| 539 Dashboard.onRequestSent(player, requestId) | 玩家、请求 ID；当前窗口置为 submitted；返回是否展示。必要 UI callback。 |
| 551 Dashboard.onSendFailure(player) | 玩家；清请求并展示失败状态，返回是否展示；必要 callback。 |
| 563 Dashboard.onAck(player, ack, request) | 玩家、ACK、pending 请求；验证当前 ID 后显示 success/reject/water 状态，返回是否处理；必要 callback。 |
| 588 Dashboard.onTimeout(player, requestId) | 玩家、过时请求 ID；对应窗口提示超时并清请求；返回是否展示。必要 callback。 |


### RV_RailroaderContextMenu.lua

功能：客户端对接 Railroader 的 RR 动物/世界菜单，增加 Enter/Exit RV；位置或已接收 mapping 仅用作菜单 affordance。RVTeleport 与 generation relocate 命令到来时按服务器提示协调 Ride seat 状态和客户端 current-square 缓存。Utility 模块也通过此处取得已接收的 RV/locomotive mapping。

| 行 / 函数 | 参数、结果与模块语义；必要性 |
|---|---|
| 21 text(key, fallback) | 翻译 key/default -> 文本；菜单需要。 |
| 23 匿名 pcall 闭包 | 无参，捕获 key/result 并调用 getText；隔离文本 API 不可用/失败。 |
| 28 localPlayer(playerNum) | 本地槽号 -> player 或 nil；菜单、网络事件定位必需。 |
| 34 localPlayerByOnlineId(onlineId) | 服务端 online id -> 目前的本地 player；SP 允许 slot 0 回退，MP 仍按 id 匹配。迁移配对必需。 |
| 43 匿名 pcall 闭包 | 无参，捕获 player 并读 getOnlineID；隔离 userdata 方法异常。 |
| 54 playerPosition(player) | player -> 有限 x/y/z 表或 nil；菜单范围提示必需。 |
| 56 匿名 getter 闭包 | 无参，取 player:getX()；隔离 API。 |
| 57 匿名 getter 闭包 | 无参，取 player:getY()；隔离 API。 |
| 58 匿名 getter 闭包 | 无参，取 player:getZ()；隔离 API。 |
| 64 targetRegion() | 无参；用常量构造测试 RV 世界区与管理层高度范围；本地菜单判断需要。 |
| 74 inRegion(position, region) | 玩家位置和范围表 -> 是否落入半开 x/y/z 区间；必需。 |
| 85 mapContainsPlayer(player) | player -> 固定目标区域内与否；只控制菜单提示，不授予服务器权限。菜单筛选必需。 |
| 95 validUtilityMapping(value) | mapping 表 -> 当前 RV/loco/generation/bitmap/map-schema 均匹配与否；映射 fail-closed 必需。 |
| 105 rememberUtilityMapping(args) | 服务器提示字段；仅 enter/exit 收到且 schema 有效时复制进 Menu 私有 mapping；无返回。utility 菜单候选所需。 |
| 121 isIsoAnimal(animal) | animal -> instanceof IsoAnimal；菜单对象类型过滤必需。 |
| 127 locomotiveType(animal) | animal -> string 类型或 nil；必需分类。 |
| 129 匿名 pcall 闭包 | 无参，读 animal:getAnimalType()；异常安全。 |
| 133 isLocomotive(animal) | animal -> 类型等于 rr_loco；集中 Railroader 筛选必要。 |
| 137 locomotiveId(animal) | animal -> animalID 或 nil；必要的 request hint。 |
| 139 匿名 pcall 闭包 | 无参，读 animal:getAnimalID()；隔离引擎异常。 |
| 143 optionAlreadyExists(context, label) | 菜单与标题 -> 是否已有重名项；跨事件防重复显示需要。 |
| 157 markTest() | 无参；若菜单引擎支持则调用 ISWorldObjectContextMenu.setTest，返回 true；手柄/测试 pass 菜单构造需要。 |
| 164 requestEnter(player, locoId) | 玩家与机车 ID；发 EnterRV 意图，无返回；菜单动作必要。 |
| 172 requestExit(player) | 玩家；发 ExitRV 意图；必要。 |
| 180 addExit(playerNum, context, test) | 槽号、菜单、test 标志；加 Exit 菜单项并返回成功/已存在 true；用于在 RV 内退出，必要。 |
| 194 addEnter(playerNum, context, animal, test) | 槽号、菜单、候选 animal、test 标志；仅机车时加 Enter，返回是否处理；必要。 |
| 209 nearestLocomotive() | 无参；调用官方 Ride.nearestBoardable(MOUNT_REACH) 并确认 animal 类型，返回机车或 nil；附近菜单候选必需。 |
| 219 匿名 pcall 闭包 | 无参，捕获 ride/reach 并调用 nearestBoardable；隔离官方 API 失败。 |
| 228 Menu.getUtilityMapping() | 无参；验证后返回 mapping 字段副本或 nil；Dashboard 所需公开读取接口。 |
| 242 Menu.acceptUtilityMapping(args) | 服务端发来的 mapping 候选 -> true/false；还校验 onlineId 是本地玩家且 schema 新鲜；断线重连恢复菜单所需，仍不是授权门。 |
| 258 Menu.clearUtilityMapping() | 无参；清空 utility candidate；断线隔离必需。 |
| 262 Menu.hasUtilityDashboardCandidate(player) | 玩家 -> 有效 mapping 且在固定区域或相同 loco 最近可上车时 true；utility 菜单显示门必需。 |
| 276 Menu.utilityEntryPoint(player) | 玩家 -> INTERNAL/LOCOMOTIVE 菜单入口 hint；media/lua 中 rg 仅找到定义，当前无调用点；现有 GUI 功能非必需，疑似预留/遗留 API。 |
| 291 nowMs() | 无参；优先 engine timestamp，回退 os.time*1000；转移 marker TTL 必需。 |
| 309 generationTransitionMatches(pending, args) | 本地迁移态和新消息 -> 是否同 rv/gen/bitmap/token 或 loco；防重复 Ride dismount，必要。 |
| 326 activeGenerationTransition() | 无参；过期清理后返回当前 pending 或 nil；转移去重/生命周期必需。 |
| 336 localTrainRecord(locoId) | 机车 ID -> RR.TrainEntity.active 中本地 record 或 nil；用于只对真实 Seat 更新 _boardPending，必要但直接耦合官方表结构。 |
| 345 匿名 pcall 闭包 | 无参，捕获 record 并从 record.animal:getAnimalID() fallback 读 ID；隔离 API。 |
| 357 prepareRideTransition(args) | 服务端 transition payload；更新 _rvTransition、按 enter/failed/exit 调官方 Ride dismount、给 seat record 设置 _boardPending；返回匹配 train record。处理同步竞态的核心。 |
| 417 refreshCurrentSquare(player, x, y, z) | 玩家和服务器下发的目标坐标；调用官方 current-square setter，返回成功；teleport 缓存刷新必要。 |
| 421 匿名 pcall 闭包 | 无参，捕获玩家/坐标并调用 setCurrentSquareFromPosition；安全刷新缓存。 |
| 427 currentSquareMatches(player, x, y, z) | 玩家与目标 -> current square 的整数格坐标是否一致；必要确认步骤。 |
| 431 匿名 pcall 闭包 | 无参，读 player current square。 |
| 433 匿名 pcall 闭包 | 无参，读当前 square X。 |
| 434 匿名 pcall 闭包 | 无参，读当前 square Y。 |
| 435 匿名 pcall 闭包 | 无参，读当前 square Z。 |
| 442 playerStillAtTargetSquare(player, x, y, z) | 玩家/目标 -> true/false/nil（API 失败为 nil）；避免在别人已移动玩家后重置旧 square，必要。 |
| 444 匿名 pcall 闭包 | 无参，读 player X。 |
| 445 匿名 pcall 闭包 | 无参，读 player Y。 |
| 446 匿名 pcall 闭包 | 无参，读 player Z。 |
| 458 scheduleCurrentSquareRefresh(player, x, y, z, relation) | 玩家、下发目标、RV identity payload；写 bounded retry state 并立即试刷；必要调度。 |
| 478 Menu.onTick() | 无参；为 current-square 缓存做 bounded tick retry，若死亡/过期/玩家已离开目标则清除；必要的异步补偿。 |
| 488 匿名 pcall 闭包 | 无参，捕获 player/dead 并检查 isDead；Tick 不因 native API 失败退出。 |
| 510 finishRideTransition(args, record, player) | transition、Train record、玩家；只在 SP 非 MPClient 下调用官方 mountRecord 恢复 exit/generation-failed seat；必要 SP 收尾。 |
| 523 validGenerationFinalHint(args) | payload -> 当前 identity/token/loco/bitmap 标记是否完整；防普通 Generate 扰动 Ride，必要。 |
| 538 Menu.prepareGenerationRelocation(args) | 最终迁移消息；承认同 transition 重播或先验证严格 server marker、记 mapping、做 Ride 准备；返回是否可让通用 Relocation 继续。必要跨模块钩子。 |
| 573 Menu.prepareGenerationStaging(args) | server staging payload；严格 marker 校验后准备 Ride 并记 TTL 状态；普通 Generate 不触碰 RR。必要跨模块钩子。 |
| 594 worldLocomotive(worldObjects) | 近邻或事件对象列表 -> 首个 Railroader locomotive；菜单候选查找需要。 |
| 604 Menu.OnFillWorldObjectContextMenu(playerNum, context, worldObjects, test) | world menu 事件参数；根据玩家是否在目标区域分发 Enter/Exit；事件入口必要。 |
| 611 匿名 pcall 闭包 | 无参，捕获 player 并检查 isDead；保护菜单 hook。 |
| 622 Menu.addForAnimal(playerNum, context, animal, test) | Animal menu 事件参数；按位置和类型添加 Exit/Enter；RR 适配 hook 必须。 |
| 638 Menu.OnPreFillWorldObjectContextMenu(playerNum, context, worldObjects, test) | PreFill 事件参数；对 RV 内玩家即使点空方格也加 Exit；避免原版空对象过滤导致无退出项，必要。 |
| 645 匿名 pcall 闭包 | 无参，捕获 player 并检查 isDead；防 API 异常。 |
| 654 Menu.OnServerCommand(module, command, args) | 服务器消息；处理 RVTeleport 错误/提示，记录 mapping，按 server 坐标 teleports 并安排 cache refresh/Ride 结束；RV/seat 同步必要。 |
| 664 匿名 pcall 闭包 | 无参，捕获 player/message，显示 invalid data halo；错误用户反馈隔离。 |
| 679 匿名 pcall 闭包 | 无参，捕获 player/坐标执行 teleportTo；失败受控并阻止后续 square refresh。 |
| 686 removeOfficialWorldHook() | 无参；若能取 RR.BoardMenu.OnFill，就从 world menu 移除原钩子并返回成功；防官方 cab 选项与 RV 选项冲突。 |
| 698 patchAnimalHook() | 无参；重设 RR BoardMenu.addForAnimal、移除官方 world hook；若官方 filter 不在，则包 AnimalContextMenu.doMenu 并保留 rerail 项。集成必需，但与 Railroader 内部字段强耦合。 |
| 705 赋值闭包 board.addForAnimal(playerNum, context, animal, test) | 转发给本模块 addForAnimal，覆盖官方动态 callback；保留 Railroader filter funnel，必要。 |
| 719 赋值闭包 AnimalContextMenu.doMenu(playerNum, context, animal, test) | 对 rr_loco 加 RV 项并保留 rerail，其他动物调用原函数；只在官方 filter 缺失时 fallback。集成所需兼容路径。 |


### RV_ContextMenu_Relocation.lua

功能：返回一个初始化闭包，安装技术生成菜单和服务端迁移命令处理。普通迁移、FinalRelocate 与 ACK 分属不同阶段；对 final 迁移，先等目标加载、验证旧/新区域房间所有权并校验目的房间，再 teleport、复核坐标和发 token ACK。房间守卫工具由 RV_ContextMenu_RoomOwnership 注入 ctx。

| 行 / 函数 | 参数、结果与模块语义；必要性 |
|---|---|
| 2 返回闭包 function(ctx) | 入口提供共享 Client/constants/guard/state 函数；注册事件并加载 Railroader/Utility 菜单；无值体返回。模块初始化必要。 |
| 30 Client.requestGenerate(playerObj) | 玩家；发送无坐标的 Generate 意图，server 选目标和 staging；保留server authoritative 必需。 |
| 39 Client.onFillWorldObjectContextMenu(playerNum, context, worldObjects, test) | world menu 事件；本地验证角色后添加 Generate，并在 controller test 时标记 setTest。文件内无 Events 注册/目录内无调用方，现有入口所需性存疑，似乎已被 Railroader menu hook 取代。 |
| 58 tryFinalRelocationGuardScan(guard, pending, phase) | guard、final 交易、pre/post 阶段；间隔重试区域 scan，达到最大次数标失败、阻断 ACK；迁移原子性必需。 |
| 93 tryApplyFinalRelocation(args, pending) | server payload 与 pending 状态 -> 是否可完成；检查 token/schema/guard/current-square error，等方块加载，pre scan、目的 room 检查、teleport、精确坐标 setters、post scan/room proof；最终迁移核心。 |
| 141 匿名 pcall 闭包 | 无参，捕获 player/目标坐标并调用 teleportTo，返回引擎结果；安全隔离。 |
| 152 匿名 pcall 闭包 | 无参，执行 setX/Y/Z 和 lastX/Y；恢复 server 选定的半格精度；失败则事务 fail，必需。 |
| 166 匿名 pcall 闭包 | 无参，调用 setCurrentSquareFromPosition(x,y,z) 更新客户端方格缓存；可选 API，保护迁移流程。 |
| 170 匿名 pcall getter | 无参，读取 final player X；是坐标证明项。 |
| 171 匿名 pcall getter | 无参，读取 final player Y；是坐标证明项。 |
| 172 匿名 pcall getter | 无参，读取 final player Z；是坐标证明项。 |
| 195 sendFinalRelocationAck(playerObj, token) | 玩家与非空 token -> pcall 成功布尔；只回传 token，不发送坐标；服务端阶段收束必需。 |
| 204 applyFinalRelocation(args) | final payload；清普通迁移态、建立 final pending 并立即尝试；无返回。异步处理入口必需。 |
| 226 Client.onServerCommand(module, command, args) | wire module/命令/payload；分派 room ownership refresh、FinalRelocate、常规 Relocate，严格检查并准备 Railroader ride hook；网络事件必要。 |
| 300 匿名 pcall 闭包 | 无参，显示 roof-refresh 本地 halo；不应影响迁移命令，反馈增强。 |
| 309 匿名 pcall 闭包 | 无参，显示本地 ASCII generation halo；不依赖网络文本，反馈增强。 |
| 342 匿名 pcall 闭包 | 无参，执行普通/临时迁移 teleport；失败时不 arm pending；核心隔离边界。 |
| 376 Client.onTick() | 无参；更新 clientTick/room guards，驱动 final 与普通迁移的 bounded retry、坐标确认和 ACK；整个异步事务必须。 |
| 421 匿名 pcall 闭包 | 无参，重绘持续 generation halo；反馈增强，不影响事务。 |
| 443 匿名 pcall getter | 无参，读取当前玩家 X，供未加载方格时的坐标 fallback proof。 |
| 444 匿名 pcall getter | 无参，读取当前玩家 Y；同上。 |
| 445 匿名 pcall getter | 无参，读取当前玩家 Z；同上。 |
| 468 匿名 pcall 闭包 | 无参，捕获 pending 并发送 RelocateAck token；异常隔离，ACK 必需。 |

### RV_ContextMenu_RoomOwnership.lua

功能：返回闭包并通过 ctx 提供 room guard 函数。接受服务端旧/新 footprint wire payload，验证边界结构尺寸和 bitmap version；清理局部 square 上 room 存在但 RoomDef 已失效的状态；为玩家当前格、加载事件和迁移目的格建立 bounded repair/verification。

| 行 / 函数 | 参数、结果与模块语义；必要性 |
|---|---|
| 2 返回闭包 function(ctx) | 注入 C/Layout/guard state 并把本地函数发布到 ctx；初始化必要。 |
| 13 roomOwnershipGuardKey(rvId, generation, bitmapVersion) | identity 元组 -> 确定键字符串；新旧迁移 guard 唯一定位必要。 |
| 21 validRailroaderFinalHint(args) | payload -> 是否具备可信形状的 Railroader final transition 标记；迁移桥接条件必需。 |
| 33 localPlayerByOnlineId(onlineId) | 本地在线槽列表 -> player/nil；原始事件路由依赖。 |
| 44 readRoomRefreshBounds(args, prefix) | payload 与 old/new 前缀 -> 验证所有整数 bounds、墙/室/屋顶尺寸、层差，返回 bounds 或 nil；客户端只接受当前精确契约，安全门必要。 |
| 80 eachStructureSquare(cell, bounds, callback) | Cell、结构范围、回调；通过共享 Layout 枚举结构坐标并传 square/坐标；扫描复用，必需。 |
| 84 匿名 Layout callback(x, y, z) | 结构坐标；安全拿 cell grid square 后交给 callback，即使未加载也报告 nil 以证明扫描覆盖；完整扫描必需。 |
| 85 匿名 pcall 闭包 | 无参，捕获 cell/x/y/z 并调用 getGridSquare；异常转 incomplete，必需。 |
| 92 squareCoordinates(square) | GridSquare -> 整数 x/y/z 或 nil；所有事件坐标统一入口，必要。 |
| 94 匿名 getter 闭包 | 无参，返回 square X。 |
| 95 匿名 getter 闭包 | 无参，返回 square Y。 |
| 96 匿名 getter 闭包 | 无参，返回 square Z；三者分别提取坐标并隔离 getter 异常。 |
| 104 coordinatesInBounds(x, y, z, bounds) | 坐标、bounds -> 是否位于 wall footprint 或 roof footprint；玩家/事件扫描筛选必需。 |
| 115 inspectRoomOwnershipSquare(square) | 方格 -> 是否检查成功、清除数；有 room 但无 roomDef 时 setRoomID(-1) 并复查。局部防失效逻辑核心。 |
| 116 匿名 pcall getter | 无参，读 square:getRoom()；失败算扫描失败。 |
| 119 匿名 pcall getter | 无参，读 square:getRoomDef()；确认 stale room 状态。 |
| 122 匿名 pcall setter | 无参，调用 setRoomID(-1)；只有异常才失败，接触本地世界派生状态的必要修复。 |
| 124 匿名 pcall getter | 无参，复读 getRoom()；证明 stale id 确实消失。 |
| 129 refreshInvalidRoomOwnership(guard) | 旧/新 guard；扫描所有结构格、去重并要求完整 loaded coverage；返回覆盖正确与清除数；final teleport 前的核心安全条件。 |
| 138 嵌套 inspect(square, x, y, z) | 每格和坐标；去重、统计覆盖缺格和 inspection 失败；扫描汇总所需。 |
| 158 refreshCurrentPlayerRoomOwnership(guard) | guard；查看每个活跃本地玩家 current square 是否位于 guard，检查或修复；返回成功和清除数。发现 room stale 必须。 |
| 170 匿名 pcall 闭包 | 无参，返回 player:getCurrentSquare()；异常会触发一次扫描，必要防护。 |
| 196 objectCoordinates(object) | World object -> square 坐标或 nil；物件新增/删除事件转成 guard key 范围查询，必要。 |
| 200 匿名 pcall 闭包 | 无参，返回 object:getSquare()；API 安全边界。 |
| 206 scheduleRoomOwnershipScan(guard, delayedRetries) | guard、延迟重试预算；合并/throttle event scans，并为已失败的 final scan 开一次匹配触发重试；bounded repair 必要。 |
| 268 requestRoomOwnershipScan(object) | 物件事件参数；对命中任一旧/新区域的 guard 排入延迟 scan；World event adapter 必要。 |
| 279 beginRoomOwnershipRefresh(args) | server 广播的 RV identity 和 old/new bounds；严格校验、移除同 RV 旧代 guard、立即 arm scan，失败才有限次 retry；通知接收必要。 |
| 339 finalTargetSquare(x, y, z) | 精确目标 -> 已加载 GridSquare 或 nil；迁移流送需要。 |
| 344 匿名 pcall 闭包 | 无参，以 floor(x/y) 查询当前 cell 的 target square；异常/未加载 -> nil。 |
| 353 finalTargetSquareIsLoaded(x, y, z) | 坐标 -> square 是否已加载；清晰单一查询 API，迁移必需。 |
| 357 finalTargetRoomIsValid(x, y, z) | 坐标 -> target square 可用及 room state 证明是否成立；room stale 则清理并复读。迁移安全证明必需。 |
| 365 匿名 pcall getter | 无参，读目标 square:getRoom()；失败拒绝。 |
| 374 匿名 pcall getter | 无参，读目标 square:getRoomDef()；房间定义有效则接受。 |
| 383 匿名 pcall setter | 无参，对失效 room 调 setRoomID(-1)；修复 stale metadata 必需。 |
| 389 匿名 pcall getter | 无参，复读 getRoom()；确认修复成功，必要。 |
| 395 updateRoomOwnershipGuards() | 无参；逐 guard 做 current-player check、edge-triggered bounded 扫描、累计修复和监视状态；迁移守卫持续运行必需。 |


## 跨模块比较与可提取的通用功能

| 重复/相近功能 | 证据与差异 | 建议与收益 |
|---|---|---|
| 安全调用 Java/Lua 对象方法 | call(target,method,...) 分别在 RV_BoundaryClient.lua:34、RV_BoundaryWallVisuals.lua:30、RV_WardrobeVisuals.lua:25、RV_ProtectedDemolition.lua:25；返回值数与错误信息策略略不同。房间模块另有集中 pcall getter。 | 可提取客户端 common safe-call，但先确定统一返回形状和异常值策略；能统一 userdata 异常边界。不同策略若保留，则共享库仅提供底层 invoke 而各模块维持返回约定。 |
| 整数/数值解析 | 包装 C.finiteInteger 的 helper 出现在 BoundaryWallVisuals.lua:39、WardrobeVisuals.lua:34、ProtectedDemolition.lua:34；玩家和 Dashboard 又各有不同 number/integer 规则（BoundaryClient.lua:18、UtilityDashboard.lua:21、RailroaderContextMenu.lua:18）。 | 直接复用共享 Constants 已有整数 API，薄 wrapper 可删。数值解析器有接受类型差异，不能合并成较宽松的一个而破坏 schema 拒绝策略。 |
| 对象/玩家方格读取与复核 | RoomOwnership.lua:92 和 RailroaderContextMenu.lua:427、442 分别读方格与当前坐标；BoundaryClient.lua:63、Relocation.lua:93 又分别施加坐标。 | 可考虑小型 safe coordinate reader，提供整数方格与有限精确坐标两种明确方法；不合并为一种比较，因为迁移半格坐标和房间整数格语义不同。 |
| strict 视觉验证后的关闭渲染与重画 | BoundaryWallVisuals.lua:93 与 WardrobeVisuals.lua:112 完整重复 setDoRender(false)、复读确认和 dirty redraw。 | 抽出只负责安全 set/verify/invalidate 的共用 helper；衣柜/边界各自的身份 validator 保持独立。此处行为必须一致，但两 consumer 文件很小，收益中等，可随下一次视觉改动再抽。 |
| 本地化、菜单去重和失效数据提示 | text/tr 在 UtilityClient.lua:53、UtilityContextMenu.lua:15、UtilityDashboard.lua:15、RailroaderContextMenu.lua:21 重复；already / optionAlreadyExists 在 UtilityContextMenu.lua:32 与 RailroaderContextMenu.lua:143；invalid-RV提示在 UtilityClient.lua:244、ProtectedDemolition.lua:93 及 RailroaderContextMenu.lua:659。 | 优先统一一处 invalid data notifier（Protected 已优先委托 UtilityClient），并共用 text + menu option helper；减少措辞/去重规则漂移。取舍是新公共模块及加载次序，需保持失败时本地 fallback。 |
| RoomDef stale 清理与验证 | RoomOwnership.lua:115 扫 footprint square，:357 对 final target square 做同类 getRoom/getRoomDef/setRoomID(-1)/复读。 | 可由后者复用一项共享 inspect/reset helper，统一 stale 判定；要求返回状态可区分 unloaded、API error、valid room、reset 成功。收益清晰，避免 proof 逻辑漂移。 |
| 请求提交状态与简单适配函数 | Dashboard.lua:275–323 有相似按钮适配 callback；setSubmitted 在 :116 已集中。 | 现有抽象已经足够；不建议继续把每个单一按钮再抽成通用命令框架。 |

## 进一步拆分判断

- 优先考虑 RV_RailroaderContextMenu.lua：762 行、70 个函数表达式，集合世界/动物菜单、utility mapping、Ride transition、current-square retry、官方 hook patch（入口分别见 :604、:242、:357/:538、:478、:698）。按“菜单/mapping”与“Ride 迁移适配”拆分会让最常改、最依赖外部 RR 的代码有窄接口；建议有后续改动或需要独立验证时再拆，避免当前为拆而拆。
- RV_UtilityDashboard.lua：599 行、64 个函数表达式，窗口控件建立、展示渲染、库存递归与多种操作回调同文件。可把库存/候选 item menu helper 拆出；窗口和 callback 仍需共享 player/request state，拆分收益不如 Railroader 模块明显。
- RV_ContextMenu_Relocation.lua（509 行，23 函数）将普通 relocation 与 FinalRelocate 两阶段事务合并。两者共享事件和 ACK 管道，但状态/证明边界不同；若拆，必须把交易 API 定为明确接口，不能让 room ownership 模块继续读 transaction 字段。
- RV_ContextMenu_RoomOwnership.lua（457 行，36 函数）里的 payload gate、footprint 检查、事件调度和 room guard 生命周期相互紧密耦合；现在可保持一个模块。Boundary/wardrobe visuals、ProtectedDemolition、UtilityClient、UtilityContextMenu 都单一职责，进一步拆分会增加加载/接口成本。
- RV_ContextMenu.lua 本身没有可拆函数逻辑，是薄 composition root，保持小入口合适。

## 跨模块数据访问与接口判断

### 模组内部模块

| 访问关系 | 性质和证据 | 是否值得接口化 |
|---|---|---|
| RV_ContextMenu.lua 把 Client、常量、Layout、pending relocation 状态、guards 等装到 ctx，再分别调用两个闭包（RV_ContextMenu.lua:55、76–77）；RoomOwnership 把函数写回 ctx（RV_ContextMenu_RoomOwnership.lua:446–456），Relocation 在载入时捕获大量 ctx 字段（RV_ContextMenu_Relocation.lua:3–26）。 | 这是同一 subsystem 的隐式内部接口：闭包直接共享表引用及函数，不经消息总线。 | 给 ctx 结构及导入 API 命名/记录契约有收益，尤其跨文件重构时。但目前只有 coordinator 和两个协作闭包，构造/调用成本很小，不需要增加通用框架。 |
| RoomOwnership 修改并拥有 roomOwnershipGuards；Relocation 直接按 guardKey 索引该表（Relocation.lua:110–114）；反向地 RoomOwnership.scheduleRoomOwnershipScan 直接查看和改写 ctx.pendingFinalRelocation.args/failed/teleported 等字段（RoomOwnership.lua:246–265），这些是 Relocation 的内部事务状态（Relocation.lua:204–223、376–399）。 | 双向共享了两个模块的内部表形状与迁移状态字段，是本目录最明确的 implementation coupling。 | 值得提供窄接口：Relocation 提供“对匹配 identity 的失败阶段重新开一次 bounded scan”方法，room module 只调用它；guard 则提供按 identity 读 guard 的 helper。这样状态字段可改而不需同步改另一模块，收益高于几行访问器成本。 |
| UtilityClient 经 RailroaderRV.RailroaderContextMenu.clearUtilityMapping/acceptUtilityMapping/getUtilityMapping 和 UtilityDashboard.onConnectionReset/onSnapshot/onAck 等函数交互（UtilityClient.lua:33–40、267–315）；Dashboard 通过 Client.getSnapshot/isRequestPending 等函数取值（UtilityDashboard.lua:46–52、248–265、326–329、454–461）。 | 通过已命名函数而非直接读对方的 mutable internal table；属于清晰的模块接口。命令/ACK/snapshot fields 则是共享 wire schema。 | 保持现有接口。最好把 dashboard APIs 列为显式 contract；无需再为一次值读取造中间模块。 |
| UtilityContextMenu 调用 UtilityCatalog public 函数，并用 RegionSlots.COUNT/indexToRegion/indexToAnchor 获取共享 geometry（UtilityContextMenu.lua:4–8、75–85、96–112）；Dashboard 通过 getUtilityMapping 获取 mapping（Dashboard.lua:46–52）。 | 是明确公开函数/共享常量契约，不读其私有实现状态。 | 已有接口足够；服务端仍验证，不应将客户端 slot result 视为授权。 |
| Dashboard 消费 Client snapshot 的 power/batteries/water 字段（Dashboard.lua:326–442）；RoomOwnership 消费 server old/new bounds payload（RoomOwnership.lua:44–77、279–337）；Relocation 消费 token/identity/坐标/phase（Relocation.lua:93–193、250–374）；BoundaryClient 消费 correction 字段（BoundaryClient.lua:84–105）。 | 这些都是客户端/服务端间的 wire data structure，不是共享内存或别的模块私有变量。共享字段直接读取不可避免，但属于 schema contract。服务端对照：共享命令常量 RV_Constants.lua:43–55；最终迁移 payload RV_Server_GenerationFlow.lua:115–123；room guard payload RV_Server_RoomOwnership.lua:662–692；boundary correction payload RV_BoundaryServer_Geometry.lua:656–666。 | 用共享常量/版本/schema validator 固定契约；不要用客户端通用 fallback 推断缺失字段。UI snapshot 按 mappingKey 过滤是有益的局部 adapter。 |
| Visuals 与 demolition 直接读 object:getModData().RailroaderRVTest tag、owner、generation、bitmapVersion、templateIndex、anchor 等；服务器在创建对象时写入这些字段并为 boundary wall 加 templateBoundarySupportWall（RV_Server_WorldObjects.lua:278–295）。 | 这是持久化 world object identity schema，consumer 必须读取 tag 才能对 world object 作身份保护；不是对 server 模块局部变量的引用。衣柜/墙/拆除 validator 都自行比较部分字段。 | 可把当前 schema 的公共静态 tag 校验提到 shared 模块，收益为减少身份字段漂移；validator 必须严格拒绝过期/缺失字段且保留各用途 live-object/role 检查，不能引入 alias 或兼容路径。读取 world modData 本身无法通过“getter”接口隐藏。 |

### Railroader 官方模块依赖

RV_RailroaderContextMenu.lua 直接接入 RR.Ride.nearestBoardable 与 MOUNT_REACH（:209–225）、读取 Ride.current 并调用官方 dismount/mountRecord（:357–406、:510–521），还枚举 RR.TrainEntity.active 的记录并读取/写入 record.animal/id/_boardPending（:336–350、:382–404），改写 RR.BoardMenu.addForAnimal 和 hook 字段（:686–733）。前两者含官方方法调用；active/current/record 字段、_boardPending 与菜单函数槽位属于对官方表实现形状的直接依赖。源码注释解释 _boardPending 用于 RR_MPClient 忽略陈旧 seat snapshot，本目录代码没有通过本项目接口访问该 gate，因此当前 adapter 直接触达它；本次范围未核查官方脚本是否另有公开替代。

把所有这类引用局部放在当前 Railroader adapter 中已经控制了影响面；再建仅包装这些字段的本地 façade 不会消除对官方内部的依赖，当前收益低。若 Railroader 日后提供公开 seat-transition/record lookup/hook API，届时替换此边界收益高；目前应将版本/字段假设集中在此 adapter，并避免让 Utility 或 Relocation 另行访问 RR 内部状态。

## 文件与函数数交叉核对

| 文件 | 函数表达式数 |
|---|---:|
| RV_ContextMenu.lua | 0 |
| RV_BoundaryClient.lua | 11 |
| RV_BoundaryWallVisuals.lua | 7 |
| RV_ContextMenu_Relocation.lua | 23 |
| RV_ContextMenu_RoomOwnership.lua | 36 |
| RV_ProtectedDemolition.lua | 20 |
| RV_RailroaderContextMenu.lua | 70 |
| RV_UtilityClient.lua | 36 |
| RV_UtilityContextMenu.lua | 15 |
| RV_UtilityDashboard.lua | 64 |
| RV_WardrobeVisuals.lua | 8 |
| 合计 | 290 |

逐行核对方式：对 GUI 目录完整文件清单与各文件行号读取；以 function 关键字后接可选函数名和左括号为函数表达式扫描口径；按每个文件扫描输出对照本报告对应文件表格的行/函数条目。括号内标作匿名闭包的条目也计入 290。没有发现本目录未覆盖文件或漏列函数表达式。

## 未覆盖项与限制

- 未运行 runtime/联机测试，未验证游戏事件签名、异步时序、引擎 API 在 B42 的运行表现；本任务只要求静态只读分析。
- 对 GUI 目录外代码仅核对与本模块直接相连的常量、服务端 wire payload 及持久 tag 写入行号；没有把 server/shared/official API 文件当成本报告模块并逐函数分析。
- 未检查图形界面主观体验、运行时性能与所有 PZ 官方类实现；需要游戏运行方可确认。

## 第二阶段 sibling-state 更新

客户端 `roomOwnershipGuards` 由 RoomOwnership 本地持有，并向 Relocation 暴露按 `(rvId,generation,bitmapVersion)` 查询/刷新接口；Relocation 本地持有 `pendingFinalRelocation`，向 RoomOwnership 暴露匹配 identity 的 bounded scan reopen 操作。顶层 ContextMenu composition 不再传递这两张状态表。`RV_RailroaderContextMenu.lua` 经本轮 adapter 依赖检查后保持原边界，因为拆分不能进一步集中它读取 Railroader 内部字段的位置。见[第二阶段报告](phase2-structure-optimization.md)。


