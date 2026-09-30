# Construction 子目录模块分析

## 范围、假设与验收

- 范围：本目录 6 个 Lua 文件：RV_Construction.lua、RV_Server_WorldObjects.lua、RV_Server_GenerationBuild.lua、RV_Server_PlayerValidation.lua、RV_Server_GenerationFlow.lua、RV_Server_GenerationAck.lua。
- 假设：RV_Server.lua 创建并按序填充共享 ctx；本目录模块通过 ctx 共享函数和事务数据。ctx 上赋值并由其他模块调用的函数视作内部模块合同；pendingGeneration、roofRefreshRelocationGroup 等可变表视作共享实现状态。
- 取舍：只分析本子目录实现；为核实调用关系，定向查阅 RV_Server.lua、TemplateRecovery 和 RoofRefresh 对应引用，不扩展成其他模块的完整分析。静态扫描不等同运行时验证。
- 成功条件：列出每个文件中的具名、赋值、嵌套及匿名回调函数；逐项说明形参、结果/副作用、当前必要性和行号；分析复用、拆分、数据访问及接口取舍。
- 验证：目录文件与函数声明/闭包扫描、源码行号交叉核对、Markdown 结构检查。未改源码，未运行 runtime 测试。

## 文件与职责概览

| 文件 | 行数 | 职责 |
|---|---:|---|
| RV_Construction.lua | 319 | 将清场、建造操作包成服务门禁；核对活动事务、布局、manifest、模板及目标空闲范围。 |
| RV_Server_WorldObjects.lua | 891 | 构造楼层、墙、发电机、捕获模板对象；校验对象状态、添加 generation/protection 标签及同步。 |
| RV_Server_GenerationBuild.lua | 373 | 清场、按模板建造、重算结构，推进 manifest 阶段并处理失败回滚。 |
| RV_Server_PlayerValidation.lua | 418 | 玩家/权限验证、断线重绑定、generation relocation 续发及 RoofRefresh 成员重绑定。 |
| RV_Server_GenerationFlow.lua | 759 | 接收生成意图、分配服务端 RV 区域、排队搬运、建造并等待最终 ACK 后提交。 |
| RV_Server_GenerationAck.lua | 572 | 验证 generation relocation ACK、失败回滚；也推进 RoofRefresh 组成员 ACK/到达状态。 |

RV_Server.lua 按顺序装配共享 ctx：WorldObjects、GenerationBuild、PlayerValidation、ManifestValidation、TemplateRecovery、RoofRefresh、GenerationFlow、RecordValidation、GenerationAck、Commands。[RV_Server.lua:L206-L218] 后加载模块在事件发生时读取此前注册的 ctx 函数/字段，因而加载顺序是隐式装配合同。

## 逐文件函数分析

“必需”针对当前职责与仓库内可见调用；没有可见调用的内部函数会标为未证实或当前未用。异常路径通常以 error 终止当前事务。

### RV_Construction.lua

| 函数与源码 | 参数 | 结果/副作用；模块语义 | 当前必要性 |
|---|---|---|---|
| validPoint [L13-L18] | point：候选坐标表 | 返回 x/y/z 均为有限整数的布尔值；无修改。 | 必需；锚点及位置比较需严格坐标。 |
| samePoint [L20-L23] | left、right：坐标表 | 仅当两者有效且三轴相同才 true。 | 必需；防止不完整坐标通过身份门禁。 |
| currentIdentity [L25-L49] | manifest：身份来源；generation：当前代号 | 返回规范化 RV ID、代号、bitmapVersion、slotIndex 和复制的 anchor；不合法则 nil。 | 必需；拒绝旧版本、错槽或错代身份。 |
| sameIdentity [L51-L58] | left、right：身份表 | 比对 RV、代、bitmap、slot、anchor。 | 必需；清场/建造前后确认身份不变。 |
| currentTemplate [L60-L68] | 无 | 返回经 validate 的当前 RoomTemplate；失效返回 nil 与原因。 | 必需；固定当前静态模板版本。 |
| sameBounds [L70-L115] | left、right：布局 bounds | 检查整数边界字段相同；编码 bitmap 后递归比较 bitmap、shellEdges、wallCoordinates。返回布尔值。 | 必需；拒绝旧 bounds 或改写几何。 |
| samePlainTree [L90-L104] | leftValue、rightValue：递归值 | 递归比较类型、叶值、表键和键数；假定无环纯表。 | sameBounds 所必需；不应直接泛化为任意对象比较器。 |
| Construction.new [L117-L317] | context：依赖与共享状态；operations：clear/build/setGenerationPhase 回调 | 校验依赖后返回 service 表，内部定义几何门禁和 service 方法；依赖错误则抛异常。 | 必需；为现有写世界操作提供统一服务门禁。 |
| validatePlannedGeometry [L127-L156] | player、layout、bounds、generation、identitySource：事务人、布局、边界、代号、身份来源 | 验证事务锁/玩家、模板、身份、锚点与重算 bounds；返回 identity/template 或抛错。 | 必需；任何世界变更前验证服务端当前计划。 |
| preflightClearTarget [L158-L208] | player、cell、layout、bounds、generation、identitySource、existingManifest | 拒绝无完整 undo 的同槽重建；遍历已有 squares，要求完整快照且范围完全空。返回 true 或抛错。 | 必需；清场没有完整反向快照，任何占用都必须拒绝。 |
| walkBounds 匿名回调 [L190-L206] | square：范围内现存方块 | 获取 strictSquareSnapshot；不完整、含玩家或其他对象均抛错；不创建缺失方块。 | 必需于空范围预检。 |
| service.preflightCurrentGeneration [L210-L214] | player、cell、layout、bounds、generation、identitySource、existingManifest | 调用 preflightClearTarget，返回 true；供 GenerationFlow 写 manifest/清世界前使用。 | 必需的服务入口。 |
| validateCurrentPlan [L216-L233] | player、layout、bounds、generation、manifest | 要求当前 RUNNING manifest、bounds 匹配，再运行计划校验；返回 identity/template。 | 必需；清场与建造共享同一 current-plan 规则。 |
| validateManifestGate [L235-L249] | manifest、generation、phase | 复制 plain manifest，在副本设置 phase 并要求 manifest gate 原样接受；无返回，失败抛错。 | 必需；校验时避免先修改真实 manifest。 |
| service.clearCurrentGeneration [L251-L266] | cell、bounds、generation、manifest；player/layout 从 context 取 | 校验计划/manifest/空范围，设置 CLEARING，复核身份后调用 operations.clear 并转发结果。 | 必需的清场门禁。 |
| service.buildCurrentGeneration [L268-L280] | player、layout、bounds、generation、manifest | 校验计划；要求 CLEARING 阶段及本代 phaseGeneration，再调用 operations.build。 | 必需，防止跳过清场阶段。 |
| service.restoreCurrentCell [L282-L314] | player；boundary：边界记录；x/y：待修复 cell | 校验 RV/代号/bitmap/托管范围后调用当前模板 reconcile；返回 restored 布尔值及原因，异常转 false/错误串。 | 必需于 TemplateRecovery 的受限单格修复入口。 |

### RV_Server_WorldObjects.lua

匿名模块工厂 [L2-L891] 参数 ctx 提供 OWNER、Constants、ServerUtil、ServerWorld；无显式返回，通过 ctx 暴露能力，运行时会改世界对象/modData 并发同步包。该入口对于当前服务器装配必需。

| 函数与源码 | 参数 | 结果/副作用；模块语义 | 当前必要性 |
|---|---|---|---|
| applyIntegerState [L10-L21] | object；state/key：状态表与字段名；setter/getter：引擎访问器，setter 可 nil | 字段缺省时无操作；否则要求整数、写入（若提供 setter）并读回匹配；无返回或抛错。 | 必需；模板 health/maxHealth 严格应用/核验。 |
| applyBooleanState [L23-L34] | object、state、key、setter、getter | 可选字段存在时写入并读回；无返回或抛错。 | 必需；避免重复实现布尔属性核验。 |
| capturedObjectContext [L36-L43] | entry：捕获对象 | 返回索引/class/name/sprite/世界坐标诊断串。 | 必需于捕获对象错误消息。 |
| ensureCapturedHiddenSprite [L45-L54] | entry | 非隐藏 sprite 返回 nil；隐藏 key 时注册并返回预期 sprite；失败抛错。 | 必需；构造器使用前注册隐藏 sprite。 |
| bindCapturedHiddenSprite [L56-L78] | object、entry、expectedSprite：引擎对象、条目、注册 sprite | setSpriteFromName 后核验 sprite 对象及名称；无返回或抛错。 | 必需；防止构造器绑定默认/错误 sprite。 |
| applyCapturedHealthState [L80-L88] | object、entry | IsoWindow 只读回 constructor health；其他对象调用 setter 并核验；无返回。 | 必需；适配不同引擎类 health API。 |
| applyCapturedIdentityAndState [L90-L236] | object、entry；deferHealth：是否延迟写 health | 校验记录/class/north/字段白名单；设置 name、方向和捕获属性，再读回核验。无返回或抛错。 | 必需；捕获对象生成的严格状态合同。 |
| capturedTagData [L238-L297] | entry；可选 edge；tagContext：世界锚点/身份 | 交叉核对 ProtectionManifest、TemplateGeometry 索引与 world-to-template 坐标，返回对象保护标签字段。 | 必需；生成标签必须可与静态账本互证。 |
| isVisualCornerTemplateEntry [L299-L304] | entry | 精确识别特定 IsoObject Wooden Wall 角块；返回布尔。 | 必需于捕获类分派；角饰不能按 floor slot 建。 |
| configureCapturedDoorFrame [L306-L318] | object、entry | 仅接受固定门框身份，设置通行、门框及 thumpable 状态；无返回或抛错。 | 必需；对象工厂和模板恢复共享该特殊状态。 |
| ensureRoofSquare [L320-L356] | cell、x/y/z：cell 和宿主坐标 | 复用现有 square；否则尝试构造+连接并窄回退 createNewGridSquare，读回连接结果后返回。会创建/连接世界格。 | 必需；模板 roof 层缺格时需建立宿主格。 |
| createFloor [L358-L440] | square、sprite、generation、role、tagContext；可选 capturedEntry/edge | 新建或更新 floor sprite，保存最初 sprite/生成归属供回滚；可应用捕获态、打标签、同步并重算；返回 floor。 | 必需；captured floor 及分阶段 floor 更新共用。 |
| addSpecialObject [L442-L464] | square、object | 按需 AddSpecialObject、核验 objectIndex、重算 square；不发包。 | 必需于特种对象路径；让调用方在对象状态最终后统一传输。 |
| createWall [L466-L486] | cell、square、sprite、north、generation、role、extraData、tagContext | 构造 IsoThumpable，设 thumpable、打标签、连接并发完整包；返回 wall。 | ctx.createWall 有导出 [L887]，但本仓库无调用点；当前必要性未证实。 |
| validatePlayerLightSprite [L488-L581] | spriteObject、spriteName | 校验指定 wallLamp、flag、IsoObjectType、tile 属性和元数据；返回 properties。 | 仅由 createLight 调用；若保留该构造则必要。 |
| createLight [L583-L647] | cell、square、sprite、generation、tagContext | 验证 sprite、建 IsoLightSwitch、准备 modData/电源/光源、连接激活同步；返回 light。 | 本目录无调用且未导出；当前路径未证实需要。 |
| createGenerator [L649-L712] | cell、square、sprite、generation、tagContext；sprite 形参在函数体未读取，实际使用 Constants.SPRITES.utilityHidden.sprite | 创建 Base.Generator 和 IsoGenerator，配置隐藏 sprite、fuel、condition、连接/激活态，打标签、连接、更新和同步；返回 generator。 | 必需；GenerationBuild、TemplateRecovery 均调用。可复核是否删去多余 sprite 参数。 |
| createFurniture [L714-L742] | cell、square、sprite、generation、role、tagContext | 计划构造家具、实体组件、sink FluidContainer、标签及 tile attachment。引用 createEntityFromSprite 和 addNormalObject，但本文件及 server/RailroaderRV 下未发现定义；当前也无调用点。 | 当前用途未证实；若保留，须注入/实现 helper，不能依赖未声明全局。 |
| createCapturedTemplateObject [L744-L879] | cell、square、entry、generation、tagContext、edge | 按捕获 class 分派构造，验证状态与标签、添加/同步，返回对象；失败抛错。 | 必需；GenerationBuild 与 TemplateRecovery 的模板对象工厂。 |

ctx 导出的对象工厂为 ensureRoofSquare/createFloor/createWall/createGenerator/createCapturedTemplateObject/configureCapturedDoorFrame [L885-L890]。GenerationBuild 消费其中 ensureRoofSquare/createCapturedTemplateObject/createGenerator [GenerationBuild.lua:L16-L18]；TemplateRecovery 取用 roof square、captured factory、门框配置、generator [TemplateProtectionRepair.lua:L9-L33, L1201-L1288, L1489]。createLight/createFurniture 未导出。
### RV_Server_GenerationBuild.lua

匿名 ctx 工厂 [L2-L373]；safeErrorText 是具名赋值函数 [L20-L36]。

| 函数与源码 | 参数 | 结果/副作用；模块语义 | 当前必要性 |
|---|---|---|---|
| 模块工厂 [L2-L373] | ctx：运行时依赖/共享状态 | 无显式返回；安装清场、构建、phase、失败处理及 Construction 服务到 ctx。 | 必需于服务器装配。 |
| safeErrorText 赋值函数 [L20-L36] | err：任意 Lua 错误值 | 安全 tostring，可用时带 traceback；格式化失败使用占位文本。 | 必需；异常终结路径不能被 tostring 再次打断。 |
| setManifestState [L38-L44] | manifest、state、可选 reason | 写 state/updatedAt 和 lastError；无返回。 | 必需；持久 generation 状态更新。 |
| manifestTable [L46-L55] | 无 | 从 ModData 取/建 manifest table 并返回；API 不可用或类型错时抛错。 | 必需；持久状态入口。 |
| setGenerationPhase [L57-L65] | manifest、generation、phase | 写阶段、代号、时间并打印日志；无返回。 | 必需；清场/构建/ACK 依赖当前阶段。 |
| recalcAndCheckStructure [L67-L115] | cell、bounds、layout | 对现有房间格及模板/墙宿主格重算；探测 room 元信息，返回重算数量。内含 recalcAt。 | 必需；生成后让结构变化可被引擎看见。 |
| recalcAt [L70-L85] | x/y/z：square 坐标；required：缺格是否错误 | 缺少必需格时报错；按坐标去重后 recalc，返回 square 或 nil。 | 必需于唯一重算及模板宿主检查。 |
| clearGenerationArea [L117-L125] | cell、bounds、generation、manifest | 写 CLEARING 并 walkBounds 对现存方格 clearSquare；无显式返回。 | 必需；只清理 Construction 已通过预检的托管范围。 |
| walkBounds 匿名回调 [L122-L124] | square：bounds 中现存 square | 调 ServerWorld.clearSquare(square,nil)，改世界，无返回。 | 必需于逐格清理。 |
| buildGeneration [L127-L275] | player、layout、bounds、generation、manifest | 校验模板/账本/412 条目及坐标，逐个构造模板对象，重算结构，最后造 generator；无返回，错误交给上层回滚。 | 必需；实际建造主体。 |
| capturedObjectsAt [L184-L193] | x/y/z：目标坐标 | 过滤 layout.templateObjects 并返回该坐标条目数组。 | 必需；下述冲突检测共用。 |
| expectFloorOnly [L194-L200] | point、role：布局点及错误标识 | 要求恰有单一 IsoObject，否则报错；无返回。 | 文件内只见定义，没有调用；当前未证实必要。 |
| expectCapturedRoofObject [L201-L212] | point、role | 要求单一 roof 层 IsoThumpable 与静态模板索引/class/sprite 一致；无返回或报错。 | 必需；确认 generator 落在捕获 roof 对象上。 |
| sameCapturedState [L218-L227] | actual、expected：两个状态表 | 双向完全比较字段及值，返回布尔值。 | 必需；布局状态须与只读模板一致。 |
| markGenerationFailed [L277-L310] | manifest、errorText | 尝试设置 FAILED；常规写入失败时保护块内写最小失败标记。返回 success、可选失败原因。 | 必需；后续回滚和重建门禁依赖持久结果。 |
| FAILED 主写入闭包 [L289-L292] | 无显式参数；捕获 manifest/errorText | 写 phase 后调用 setManifestState；其返回交由 pcall。 | 必需于安全尝试失败标记。 |
| FAILED fallback 闭包 [L299-L304] | 无显式参数；捕获 manifest/errorText | 写 phase/state/lastError/updatedAt 的 best-effort 最小集；交由 pcall。 | 作为可靠性兜底所需；不迁移旧 schema。 |
| finalizeGeneration [L312-L345] | manifest、ok、resultOrError、preserveManifestOnFailure | 失败时按标志写 FAILED 并清 boundary；统一释放 busy/player。返回成功及结果/错误。 | 必需；同步建造流程统一释放锁点。 |
| finalize 内部保护闭包 [L314-L336] | 无显式参数；捕获 finalizeGeneration 参数/ctx | 格式化错误、标记失败、清玩家 boundary，或返回成功结果；被 pcall 包住。 | 必需；避免错误格式化/清理异常卡住锁。 |

模块缓存 CapturedTemplate 与 RoomTemplate 列表 [L9-L14]，构建时仍运行 validate；核心计划来自 Flow。它创建 Construction 服务，将 clear/build 原始操作作为 operations，再挂 ctx [L347-L369]；导出的 manifest、phase、构建、失败和错误格式函数见 [L361-L372]。

### RV_Server_PlayerValidation.lua

匿名 ctx 工厂 [L2-L418]；另外有无参 IIFE [L17-L160] 返回局部 validator 函数表。

| 函数与源码 | 参数 | 结果/副作用；模块语义 | 当前必要性 |
|---|---|---|---|
| 模块工厂 [L2-L418] | ctx：共享服务、配置、tick、事务状态 | 无返回；导出玩家验证与 relocation 续期帮助函数。 | 必需。 |
| cancelPending 转发器 [L15] | 可变参数：原样传给 ctx.cancelPending | 转发该函数的返回值；实际实现稍后由 GenerationAck 注册。 | 必需的加载顺序解耦。 |
| relocationServices IIFE [L17-L160] | 无 | 创建 validator 帮助函数并以表返回；只组织局部命名空间，不改世界。 | 非业务必需；若无后续扩展价值，可直接局部声明来简化。 |
| readPlayerCoordinate [L18-L28] | player、methodName：getX/getY/getZ、label：报错字段名 | 读引擎坐标，验证有限数和 z 合法范围，返回数值；缺值/越界则抛错。 | 必需；所有坐标信任服务端 IsoPlayer。 |
| validateAuthoritativePlayer [L30-L54] | player：请求发送者 | 验证 IsoPlayer/存活/服务器坐标/world square；返回 true+向下取整的位置或 false+原因。 | 必需；一般生成请求资格验证。 |
| authoritativePlayerPosition [L58-L79] | player：服务器玩家 | 执行同类 player/world 校验，返回原始浮点 x/y/z；不造方格中心。 | 必需；relocation/回滚依赖实际精度位置。 |
| validateGenerationPermission [L81-L96] | player | 验证角色有 UseDebugContextMenu capability；返回布尔及原因。 | 必需；限制普通技术生成权限。 |
| playerIdentity [L98-L113] | player | 验证非负整数 onlineId 和非空 username；返回 identity 表（含稳定 key）或 false/原因。 | 必需；跨重连识别玩家。 |
| resolvePendingPlayer [L115-L144] | pending：含稳定 identity 和旧 player 的进程内记录 | 按 onlineId 找活动玩家并核对稳定 key；userdata 更换时更新 pending.player、断旧坐标缓存、记 tick 并要求同 token 重发。返回 bool+当前 player/原因。 | 必需；处理重连后 IsoPlayer userdata 替换。 |
| relocationPositionsEqual [L146-L149] | left、right：位置表 | 三坐标完全相等返回 true。 | 必需；Flow/Ack 均通过 ctx 共用。 |
| tryAuthoritativePlayerPosition [L174-L180] | player | pcall 原始位置函数并剥掉 pcall 自身状态值；返回布尔和位置/原因。 | 必需；让 tick/ACK 流程安全处理异常。 |
| generationDisconnected [L182-L184] | reason：身份解析失败原因 | 精确识别“断开或被替换”状态。 | 必需；断线应暂停而非取消。 |
| pauseGenerationForDisconnect [L186-L191] | pending：generation 状态 | 仅首次写 disconnectStartedTick；无返回。 | 必需；暂存断线起点。 |
| resumeGenerationAfterDisconnect [L193-L214] | pending | 将断线历时补到队列/截止 tick，清断线标记，允许立即重发；无返回。 | 必需；离线时间不消耗正常操作期限。 |
| rearmGenerationTransition [L216-L239] | pending、player、kind：事务、当前玩家、transition 类型 | 尝试延长现 token；不行则重新 begin 并再延长；返回是否成功。 | 必需；重连后重新安装同一 boundary 保护。 |
| resendGenerationPhase [L245-L351] | pending、player、phase：事务、当前玩家、temporary/final/rollback | 从服务器记录构造 payload，发送并 teleport/校准位置，更新重试/ACK 状态；返回成功布尔。 | 必需；同 token 有界恢复 relocation。 |
| keepGenerationTransitionAlive [L353-L385] | 无；读取 ctx.pendingGeneration | 重解析玩家，处理断线/恢复、延长 transition，并按 retry tick 重发当前阶段；返回 true。 | 必需；每 tick 保持 generation boundary lease。 |
| resolveRoofRefreshGroupPlayer [L390-L401] | group、member：RoofRefresh 组与成员 | 重解析稳定成员身份，更新 group.allowedPlayers 中旧/新 userdata；返回解析结果。 | 必需于 ACK 文件对 RoofRefresh 组的处理，但属跨子目录协作。 |

IIFE 中的 helper 在函数表后赋给本地变量 [L151-L169]；只有部分作为 ctx 接口导出，清单见 [L404-L417]。
### RV_Server_GenerationFlow.lua

匿名 ctx 工厂 [L2-L759]；坐标均由服务端规划，客户端只给出空操作意图。

| 函数与源码 | 参数 | 结果/副作用；模块语义 | 当前必要性 |
|---|---|---|---|
| 模块工厂 [L2-L759] | ctx：generation/boundary/schema/utility/事务/room guard 服务 | 无返回；注册 request、queue、build、finalize 入口。 | 必需。 |
| allocateRVRegion [L16-L23] | 可变参数；当前传 Railroader locoId 或 nil | 经全局 RailroaderRV.RailroaderServer 适配器分配区域；缺 API 返回 false 和 INVALID_RV_DATA，否则转发结果。 | 必需；分配服务端 RV slot。 |
| safeErrorText 转发器 [L24] | 可变参数 | 转发 ctx.safeErrorText。 | 错误流程需要其语义；包装本身可直接引用 ctx 函数。 |
| requireCurrentManifest 转发器 [L25] | 可变参数 | 转发 ctx.requireCurrentManifest。 | manifest 验证必需；包装可直接 alias。 |
| validateGenerationUtilityState [L26-L38] | identity：RV/代/bitmap 身份表 | pcall UtilityServer validator；返回 true 或 false、原因。 | 必需；写世界前验证 utility ledger 与当前代。 |
| validateRequest [L58-L77] | module、command、player、args：网络事件字段 | 验证协议、空参数、服务端玩家和权限；返回 true+服务端位置或 false+原因。 | 必需；命令入口校验。 |
| relocatePlayerIntoHouse [L82-L146] | player、prepared：服务器玩家与可信生成计划 | 验证最终点是 anchor 中心，构造服务端 final payload、发送、teleport/calibrate；写 prepared sent/ACK/deadline/destination；无返回。 | 必需；建造完成后的异步最终搬运阶段。 |
| generateForPlayer [L148-L382] | player、prepared | 获取事务锁；复验玩家/身份/权限、目标/utility/manifest；注册 room guards；初始化 manifest；清理、建造、复扫；最终搬运或回滚。返回 finalizeGeneration 结果或 await-final-relocate。 | 必需；主 generation use case。 |
| generateForPlayer protected body [L199-L379] | 无显式参数，闭包捕获 player/prepared/manifest 等 | 执行校验、manifest 更新、clear/build、room guard 扫描、relocation 和 rollback；异步等待时返回 sentinel，错误抛给 finalize。 | 必需；保护跨引擎调用的事务体。 |
| rollback pcall 匿名回调 [L360-L363] | 无显式参数；捕获 cell、bounds、generation、manifest | 调 removeGeneration 清除此代对象/标签并交由 pcall 捕获异常；无显式返回。 | 必需；回滚若失败，上层必须保留失败状态并阻止当作成功继续。 |
| finalizeGenerationAfterRelocate [L388-L507] | player、prepared：ACK 玩家及服务端 pending 计划 | 验证 ACK/服务端位置/manifest/anchor/guard，完成 boundary transition、置 READY、执行 Railroader mapping commit；返回 true 或 false+安全错误。 | 必需；唯一完成 READY 和持久 mapping commit 的 continuation。 |
| continuation protected body [L394-L500] | 无显式参数，捕获 player/prepared | 做 final position proof、schema、boundary 和提交验证；返回给 pcall。 | 必需；保护异步 continuation 不跳过失败处理。 |
| queueGeneration [L509-L752] | player；authoritativePosition：调用处传入的已验证坐标；railroaderData：可选 Railroader 上下文 | 校验忙状态，获取稳定身份、重新读取服务端位置/manifest、分配 slot、规划 layout/bounds/目标和 token；写 pendingGeneration、arm boundary、下发 staging relocation 并 teleport。返回 true 或 false/原因。形参 authoritativePosition 在函数体未读取。 | 必需；把请求转成服务端计划；未使用形参建议维护时确认是否可移除。 |
| slot/layout plan protected closure [L545-L610] | 无显式参数，捕获 railroaderData/manifest | 分配 slot，拒绝无 undo 的同槽构建，填 Railroader 计划，计算 bounds 和合法 staging/final 点；返回 layout、bounds、targets、slot/id/generation。 | 必需；把分配和纯计划失败限制在保护区内。 |

ctx 导出 validateRequest、generateForPlayer、finalizeGenerationAfterRelocate、queueGeneration [L755-L758]。Flow 调 constructionService.preflightCurrentGeneration [L263-L280]；clear/build 则由 GenerationBuild 用 Construction 服务包装 [GenerationBuild.lua:L347-L369]。

### RV_Server_GenerationAck.lua

匿名 ctx 工厂 [L2-L572]。本文件同时处理 generation ACK/rollback 和 RoofRefresh relocation group 队列。

| 函数与源码 | 参数 | 结果/副作用；模块语义 | 当前必要性 |
|---|---|---|---|
| 模块工厂 [L2-L572] | ctx：generation ACK、身份、回滚、RoofRefresh/world 服务 | 无返回；向 ctx 注册 ACK handler、取消和 group processor。 | 必需。 |
| safeErrorText 转发器 [L11] | 可变参数 | 转发 ctx.safeErrorText。 | 错误语义必需；包装可直接 alias。 |
| requireCurrentManifest 转发器 [L12] | 可变参数 | 转发 ctx.requireCurrentManifest。 | manifest 校验必需；包装可直接 alias。 |
| isInvalidRVData [L19-L23] | reason：错误/原因 | 判断 reason 是否包含 INVALID_RV_DATA marker；返回布尔。 | 必需；控制无效存档通知限次。 |
| ackPayloadToken [L45-L71] | args：客户端 ACK table | 只接受仅含单一非空 token 的普通/Kahlua table；返回 token 或 nil。 | 必需；拒绝 ACK 携带客户端坐标或额外状态。 |
| acknowledgeRelocation [L73-L112] | player、args：sender 与临时 relocation ACK | RoofRefresh 活动时验证其 group member，否则验证 generation pending token 和 identity；设置对应 acknowledged/ack tick。返回 true 或 false/原因。 | 必需；客户端只交 opaque token，服务端核对所属事务。 |
| acknowledgeFinalRelocation [L117-L224] | player、args：最终搬运 ACK sender 与仅 token payload | 校验 pending/token/身份/manifest/anchor；读取服务器当前位置，必要时一次重置服务器目标；只有精确或同格规范化位置证明才置 final ACK。返回 true 或 false/原因。 | 必需；最终 ACK 必须有服务端权威位置证明。 |
| rollbackPendingGenerationWorld [L226-L281] | pending、reason：失败事务及原因 | 根据 retry tick 清 generation 对象、写 rollback 和 FAILED，成功释放锁；返回布尔。 | 必需；final relocation 后失败须先恢复世界。 |
| cancelPending [L283-L382] | reason：取消/失败原因 | 标 cancelled，解析玩家、重新 arm boundary；必要时回滚世界及玩家，执行 Railroader hook 和通知，最后清 pending/锁；断线/重试时延后。无显式返回。 | 必需；统一的有界/幂等取消流程。 |
| roofRefreshRelocationPositionStillSyncing [L384-L391] | reason：RoofRefresh readiness 错误 | 对一组固定的暂时同步错误串返回布尔。 | 当前 group processor 需要；建议以状态码取代字符串协议。 |
| processRoofRefreshRelocationGroup [L393-L565] | 无；读取 ctx.roofRefreshRelocationGroup | 重解析所有成员、检查 timeout/context、按 phase 检查位置、重发 relocation、在 ACK/延迟条件满足后标记 arrived；失败则调用 group failure。直接读写 group/member 字段。 | RoofRefresh group 能力需要，但不适宜归 GenerationAck；建议移入 RoofRefresh 的状态 owner。 |

ctx 导出 acknowledgeRelocation、acknowledgeFinalRelocation、cancelPending、processRoofRefreshRelocationGroup [L568-L571]。
## 跨模块复用与公用接口建议

| 函数/模式 | 源码证据 | 评估和建议 |
|---|---|---|
| 安全错误格式化 | GenerationBuild 定义 safeErrorText [L20-L36]；Flow/Ack 有纯转发器 [GenerationFlow.lua:L24-L25；GenerationAck.lua:L11-L12] | 实际实现已集中。Flow/Ack 可局部直接引用 ctx.safeErrorText，减少薄包装；无需新建公共库。 |
| 精确坐标相等 | PlayerValidation 定义并导出 relocationPositionsEqual [L146-L149, L417]；Flow/Ack 经 ctx 使用 [GenerationFlow.lua:L54, L402；GenerationAck.lua:L38, L159, L326] | 已正确复用，应保持单一实现。 |
| 点/身份/bounds 比较 | Construction validPoint/samePoint/currentIdentity/sameIdentity/sameBounds [RV_Construction.lua:L13-L115]；TemplateProtectionRepair 有简化同名 sameIdentity [L119-L124] | rvId/generation/bitmapVersion 三元概念重复，但语义不完全相同：Construction 还校验 slot/anchor 且要求严格类型；TemplateRecovery 会 tostring/数字归一化。暂不盲目合并。未来若统一规范化身份表，可抽基本三元比较，同时保留各自 schema 门禁。sameBounds 目前单一调用面，不值单建公共库。 |
| captured state setter/readback | applyIntegerState/applyBooleanState [WorldObjects.lua:L10-L34] | 只在 WorldObjects 使用，且绑定模板白名单/引擎 setter 差异；保持局部。 |
| 玩家坐标读取 | readPlayerCoordinate 由两个玩家校验器共享 [PlayerValidation.lua:L18-L79] | 已在模块内提取。上层一个返回 floor 坐标、另一个保留 float，精度合同不同，不宜压成单一返回语义。 |
| 捕获对象构造 | WorldObjects 导出 ensureRoofSquare/createFloor/createWall/createGenerator/createCapturedTemplateObject/configureCapturedDoorFrame [WorldObjects.lua:L885-L890] | GenerationBuild/TemplateRecovery 共用明确 helper。可在将来改为 ctx.WorldObjects 工厂表集中合同；当前已是窄功能接口，仅重命名收益有限。 |
| 清理/建造门禁 | Construction 的 preflight/clear/build service [RV_Construction.lua:L210-L280] | 是有价值的现成模块接口；Flow 不必了解 bounds 比较和 world clear 细节。应保留，避免绕开门禁直接调 operations。 |

静态搜索显示 createFurniture 调用 createEntityFromSprite 和 addNormalObject [WorldObjects.lua:L725, L737]，但未在本目录或 server/RailroaderRV 内定义；该函数目前无仓库内调用且未导出，不足以说明当前生成路径会触发它。若保留家具能力，应显式注入/实现依赖并做函数类型检查，避免依赖未声明全局。

## 是否应进一步拆分

1. **优先把 RoofRefresh group processor 归回 RoofRefresh。** processRoofRefreshRelocationGroup 本身约 170 行，处理另一个子模块创建的 group/member [GenerationAck.lua:L393-L565]，却与 generation ACK/rollback 同文件。放进 RoofRefresh relocation service 后，ACK 模块只负责路由，状态 owner 和状态修改者更一致。
2. **WorldObjects 边界清楚，接近 900 行。** 若继续新增对象类，可分出捕获状态/标签验证与按类对象工厂；现有代码含 floor、特殊墙/门窗、light、generator 多类。拆之前先确认未用 createLight/createFurniture/expectFloorOnly/createWall 是否仍有内部使用承诺，并解决家具构造缺失 helper。
3. **GenerationFlow 可拆成计划/queue、同步构建协调、final relocation commit。** 当前三类职责集中于 queueGeneration、generateForPlayer、finalizeGenerationAfterRelocate [GenerationFlow.lua:L148-L507, L509-L752]。拆分需同时让 pending generation 有唯一状态 owner，不能把结构可变表扩散给更多模块。
4. **PlayerValidation 可候选拆分，不是当前必须。** 玩家身份/授权校验 [PlayerValidation.lua:L18-L169] 与断线租约/重发 [L174-L401] 职责不同；如果继续扩展，可分身份验证和 relocation lease。现阶段都依赖同一 stable identity/rebind 语义，增加 ctx API 的收益有限。
5. **RV_Construction 和 GenerationBuild 暂不建议继续拆。** 前者聚合当前构建门禁，后者聚合同步建造交易及失败释放锁；按函数数量机械切分会加重状态边界。

## 跨模块数据访问、接口与边界

| 状态/接口 | 直接访问证据 | 评价及接口收益 |
|---|---|---|
| ctx 服务集合 | RV_Server.lua 创建 ctx 服务、配置和初始事务状态 [L135-L198]，按序调用模块工厂 [L206-L218] | 这是 service locator 式内部装配，不是 Lua 私有状态访问；函数注册依赖约定名和加载顺序。小型模组当前可用，新入口应归入明确能力域，避免无限增加根字段。 |
| WorldObjects 工厂 API | WorldObjects 写 ctx 函数 [WorldObjects.lua:L885-L890]；GenerationBuild 捕获调用函数 [GenerationBuild.lua:L16-L18]；TemplateRecovery 读取并检查类型 [TemplateProtectionRepair.lua:L9-L33] | 属明确内部接口，不属隐藏状态。参数约定仍分散在调用点；未来拆文件可改返回一个 WorldObjects API 表。 |
| Construction service | GenerationBuild 构造服务并挂 ctx.constructionService 和 RV.Server.Construction [GenerationBuild.lua:L347-L369]；Flow 调 preflight [GenerationFlow.lua:L263-L280]；TemplateRecovery 用公开 restore 方法 [TemplateProtectionRepair.lua:L1568-L1575] | 当前 service 接口清晰，较直接调用内部 clear/build 实现更安全。建议维持；restoreCurrentCell 是受范围/版本校验的专用入口。 |
| transactionBusy/transactionPlayer | Flow 占有/释放 [GenerationFlow.lua:L149-L164, L504-L505]；Build finalize 释放并取 transactionPlayer [GenerationBuild.lua:L329-L340]；Ack rollback/cancel 多次改写 [GenerationAck.lua:L278-L379]；Construction 校验所有权 [RV_Construction.lua:L127-L131, L251-L254] | 多文件读写相同隐藏锁状态，有漏释放或错误 owner 风险。后续建议提供 transaction service（begin/owns/setPlayer/release），Construction 只询问 owner。收益明显，因同一不变量现有多个写入点。 |
| pendingGeneration | Flow 创建整个记录 [GenerationFlow.lua:L628-L669]；PlayerValidation 改写断线/重试字段 [PlayerValidation.lua:L134-L142, L186-L214, L245-L351]；Ack 读写 ACK、rollback 并清除 [GenerationAck.lua:L95-L110, L118-L222, L226-L382]；Build finalize 写 boundaryCleared [GenerationBuild.lua:L329-L331] | 各模块共同依赖状态字段名、tick 形状、阶段布尔值，是主要隐藏结构耦合。建议后续集中到 GenerationTransaction service，暴露阶段操作而非逐字段 getter。改造前须确定唯一状态 owner，否则接口只是包住共享表。 |
| RoofRefresh group/member | RoofRelocation 写 ctx.roofRefreshRelocationGroup [RoofRelocation.lua:L387-L402]；GenerationAck 遍历并改 member 字段 [GenerationAck.lua:L393-L565]；Flow 只检查 group/finalReturn 是否占用 [GenerationFlow.lua:L510-L519] | ACK 模块直接依赖另一模块的组内布局，属于实质内部数据访问。processor 应移到 RoofRefresh；Flow 的 busy 检查可在状态扩展时改为 RoofRefresh.isBusy()，目前简单存在性检查额外接口收益一般。 |
| manifest/layout/bounds | Flow 生成布局并填 manifest [GenerationFlow.lua:L296-L312]；Construction、GenerationBuild、Ack 按字段验证/读取 | 这是经 requireCurrentManifest/ServerSchema 检查的持久化和几何合同；各阶段必须交换。继续严格 schema 验证即可，针对只读字段访问再包 accessor 的收益较低。 |

本目录对 ServerUtil、ServerWorld、ServerSchema、RoomTemplate、ProtectionManifest、Boundary、RV.Server 等通过方法访问，没有证据表明直接读取它们的 Lua 私有 upvalue。耦合主要来自共享 ctx 和可变事务/组表；ctx 不是冻结/类型化接口，虽有部分 function 检查和 manifest schema gate，但状态结构仍由调用约定维护。

## 扫描、交叉核对与未覆盖项

- 文件清单：rg --files 扫描确认 Construction 目录恰有以上 6 个 Lua 文件。
- 函数清单：逐文件搜索并复核 99 条函数定义/函数表达式源码行，覆盖具名、赋值、嵌套、匿名 pcall/walkBounds 回调及模块工厂。
- 逐行复核：函数范围和跨模块引用以带行号源码输出核对；目标接口另定向查看 RV_Server.lua、TemplateProtectionRepair.lua、RoofRelocation.lua。
- 文档检查：写入后核对目标文档存在、非空、章节/表格起始及源码路径引用；这是文档格式检查，不代表 Lua 或游戏运行行为正确。
- 未覆盖：未完整分析客户端对应代码、模板静态数据、Java API 实际运行时绑定或其余 server 子目录；未使用 Lua 静态解释器或联机/runtime 测试。其他目录只用于核实 Construction 的调用关系，不是完整函数审计。

## 第二阶段职责更新

generation async state 已集中在 `RV_Server_GenerationTransaction.lua`。Flow、Build、PlayerValidation、GenerationAck 通过 `begin/owns/current/advanceStage/recordAck/markBoundaryCleared/setPlayer/cancel/rollback/release` 等语义操作更新事务；`current()` 返回 detached snapshot，但保留 `player` 与 `generationCell` 两个 engine identity 引用。Construction/WorldObjects 现在提供 `ensureGeneratorForEntry`；EntryExit 通过 `RV.Server.Construction` 调用。Generation staging 选择及 arrival proof 已从 RoofDestinations 移入 GenerationFlow。见[第二阶段报告](phase2-structure-optimization.md)。
