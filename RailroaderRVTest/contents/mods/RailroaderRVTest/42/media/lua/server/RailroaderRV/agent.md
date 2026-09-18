# server/RailroaderRV

RV_RoofRepair.lua 是服务器权威的房顶缓存修复模块；RV_RailroaderServer.lua 是 Railroader 2.1 的最小适配层，负责 rr_loco 识别、服务器
权威进入/退出、座位规则与存档地图 ModData 映射；MP 读取官方 `RR.ServerTrain.active`
和 `driver/passengers`，SP 明确切换到 `RR.TrainEntity.active` 的 `rider/seat/passenger`
及 `RR.Ride.current`，不把 SP 布尔 rider 当成 online ID，不改写官方源文件或恢复
独立旧适配层。座位坐标使用 `RR.Body.seatWorld`，外部交互距离使用官方
`RR.Body.hullDistance` + `RR.Ride.MOUNT_REACH=2.0` 契约；无 Body 仅允许同样 2.0 格的
保守中心距离回退。

结构：`RV_Server.lua` 是 facade/bootstrap、事件唯一所有者并执行服务端生成事务；
`RV_ServerUtil.lua` 提供无副作用的调用/数值/空 payload 工具；
`RV_ServerWorld.lua` 提供服务端方格、对象快照/标签/清理与回滚原语；
`RV_ServerSchema.lua` 提供当前 layout/bitmap、目标坐标和加载预检契约；其在文件前部前置声明
后文定义的当前 manifest gate，确保清理旧 generation 时使用当前 schema 函数而不是全局
缺失值；`RV_RoofRepair.lua` 只执行一次性的官方临时木地板 add/remove 邻居重算；
`RV_RailroaderServer.lua` 在首次生成、已有房车进入以及重连驻留检测时调用它。拆墙入口以
当前 42.20.4 服务端 `SledgehammerDestroyPacket -> RemoveItemFromSquarePacket` 触发的
`OnObjectAboutToBeRemoved` 为主：该事件在对象脱离前仅接受当前 `IsoThumpable` 生成墙的完整
tag 与 shell ledger identity；`OnDestroyIsoThumpable` 只作为直接 thumpable 销毁路径的同一
严格匹配补充入口。两条事件按完整 `rvId:generation:bitmapVersion` 房间 key 去重；对象事件
未暴露时，30-tick map/presence 流程读取 authoritative player square 的 `isInARoom()`，以
`getRoom()/getRoomDef()` 作支持状态，只在当前 RV scope 内检测到 inside→outside transition
时安排修复。

拆墙修复是一个边界 lease 保护下的多玩家状态机：`queued` →
`temporary` → `repairing` → `returning` → `complete`。服务端枚举当前 RV scope 的全部
在线玩家，逐人捕获服务端原始 `x/y/z`、identity 和当前 schema 关系；复用
`Relocate`/严格 token-only `RelocateAck`，将所有成员送到当前 bitmap 中心减去刷新向量
`(18000,0,15)` 的远端点，跨 tick 确认全部成员到达后才
允许继续。`queued` 阶段在尚未建立 Boundary lease 前最多等待 600 ticks 以重绑离线成员，
超时安全取消；进入 `temporary`/`repairing`/`returning` 后不使用该期限。临时阶段向客户端发送严格 marker，客户端只显示本地 ASCII 提示并执行服务端坐标
和回执，不提交坐标/世界状态；远端层可能没有 `GridSquare`，所以服务端以重新读取的权威
玩家坐标作为到达条件，并保留有界跨 tick 等待；远端等待用于强制 RV 区块卸载/重载。
远端阶段的 Boundary correction lease 由 `RV_Server.OnTick` 在调用 Boundary callback 前续租；
lease 存续时 Boundary 普通 geometry/cleanup 与服务端 stale-room ownership 扫描暂停，避免
从远端玩家 cell 解析原 RV footprint 造成 tick 阻塞。所有成员完成权威回传、修复确认和 lease
释放后才恢复普通扫描。
跨 chunk 回传可先以服务端目标坐标完成 token-only ACK，而等待原 RV `GridSquare`
重新绑定；服务端仍以权威位置、身份和 current-schema context 复核，并保持 lease，
直到 `completeRoofRepairRelocation` 与 `roofRepairSquaresLoaded` 证明加载完成。
generation 占用共享 managed scope 时，已接受的 queued/follow-up 以
`waitingForGeneration` 暂停 `queuedDeadlineTick`/`expiresAtTick`；generation 结束后先复核
当前 `rvId:generation:bitmapVersion`，仅在完整 current record 通过时重建 600-tick 等待窗口，
失败则明确取消并提示存档重建。

所有成员先完成服务端权威回传，再由适配层选择一个有效权威上下文，按既有进入 RV 的 `repairRoofVisuals`/geometry 路径对房间执行一次修复，
修复/刷新异常在受控 `pcall` 内转为明确失败，不得阻断其余成员的回传；
再在完整 identity、权威 relation 和玩家状态仍匹配时回到每人事件前服务端捕获的合法 RV
方格并释放 correction lease。任何中间异常、断线、死亡、对象失效、schema/identity 变化、
加载超时或 ACK/阶段不匹配都会尝试最终逐人回传；只要任何成员仍在 `z=-15`，当前进程内存中的
回传上下文、lease 和稳定 identity 就必须保留并持续重试，不能由 repair 成功掩盖回传失败。
玩家掉线只暂停内存事务，稳定 online ID+用户名重新上线后继续精确回传；服务器进程结束时
事务自然丢失，不读取或写入中间传送记录，也不跨重启恢复原坐标、repair、phase 或 `READY`。
generation 临时/最终/回滚阶段会在同一 token 上续租，并在稳定 identity 重绑后按受控间隔重发
当前阶段命令；不因 IsoPlayer userdata 替换而重复创建事务或让 boundary lease 过期。
服务端只记录 add/remove 已应用，不能据此宣称客户端视觉成功。
失败状态绑定当前唯一 relocation token；原事务仍可消费自己的失败记录，后续尚未启动的独立墙体操作不被旧 token 误取消，并在前一事务释放后再尝试。
回传完成前适配层有显式 `allCompleted` 门，任何成员未确认都不会调用 repair；回传完成后
只在当前进程内存中将 `repairCompleted` 置位，且只执行一次世界修复。墙事件去重键带有
坐标与 object index；活动 token 期间出现的不同稳定键进入有界 follow-up 队列，前一事务释放后
按当前 mapping 重新校验并启动，重复键不会制造第二次传送；follow-up 有上限和过期时间，无法取得稳定键时 fail-closed。

BoundaryServer 仅通过适配器的完整 current map/record schema hook 取得边界，并在 cache 复用前
比较当前 bitmap、managed scope、shell edge 与 bounds/wall geometry；缺失 hook、schema 或几何
不一致时 fail-closed。roof/sentinel 共用 RV_Server 的 record↔manifest geometry gate，哨兵失败
原因始终是稳定字符串，不会把表值写入诊断。

`OnClientCommand` 在 generation/roof-refresh identity 占用时会以明确原因拒绝进入或退出，
并保持服务端事务互斥；B42 浮点 `teleportTo` 的半格目标由服务端和客户端在官方传送调用后
分别通过 `setX/setY/setZ`、`setLastX/setLastY` 恢复，再进行最终位置证明与严格回执。
若 B42 的 IsoPlayer 网络更新在最终回执前把半格 x/y 归一化为包含方格，最终证明保留
精确值优先，并仅在 z 精确且 floor(x/y) 仍命中同一服务端目标方格时接受该引擎归一化；
跨方格仍 fail-closed。

职责：严格处理 `OnClientCommand`；普通 `Generate` 只接受有效玩家和空 args，Railroader `EnterRV` 只接受服务端生成的机车 id 提示，`ExitRV` 不接受可信坐标；对其他模组的共享命令直接忽略，避免把外部流量记录成 RV 拒绝。适配器通过 `installTransactionHooks()` 与 `RV_Server` 连接，以适应 B42 按文件名先加载适配器、后加载事务入口的顺序。服务端固定生成 anchor 为共享目标 `(20050,2050,0)`；首次 generation staging 只允许 current-schema layout/bitmap managed scope 中心的 `(managedOriginX+floor(width/2), managedOriginY+floor(height/2), -15)`，roof-refresh 远点才是当前 bitmap 中心减去 `(18000,0,15)`，不得在初次传送前读取或要求远端方格已加载。B42 服务端按 64×64 cell 和 online chunk-grid width 的一半加载相关区域；客户端与服务端到达并确认 staging 安全后，在硬超时内等待完整半开 `100×100` base footprint 已加载，再清理已加载的有效 `z` 层。缺失方格在轮询中返回可重试状态而不抛 Kahlua 异常；若加载范围始终不足则硬取消且不发生部分清场。清理通过快照和服务端网络移除覆盖僵尸、石块、地表装饰、树木、杂草、灌木、地板等对象；清场成功后才进入完整房间/对象生成。若清场失败，必须短路 `buildGeneration`；若任一生成阶段失败，必须沿既有 generation 回滚路径移除本代对象。生成前仍先预检 `100×100` 底层/墙体已加载、屋顶 6×40 的世界坐标及 `z+1` 合法。跳过 `PLAYER_METAL_FLOOR`/整片金属地板阶段，仅生成房屋内部 6×40 的 `floors_interior_carpet_01_5` 地板；直墙为 `walls_interior_house_03_20`/WallN 配对 `..._21`，NW/SE 单角条为 `..._22`/`..._23`。`ROOF_FLOOR` 阶段按官方玩家建造路径，在已预检的目标范围内用 `IsoGridSquare.new` + `ConnectNewSquare(..., false)` 创建缺失的上层方格（保留运行时 API 的必要探测），校验连接结果后再 `addFloor`；已有方格直接复用。

地板事务会在第一次替换每个对象时记录原 sprite；室内精确 carpet→roof floor 的连续阶段保留同一份初始快照。已有地板使用 `transmitUpdatedSpriteToClients`，新建地板使用添加包。失败回滚对已有地板恢复原 sprite 并清除本模组标签，对本轮新建地板只调用 `transmitRemoveItemFromSquare`；该 B42 API 负责网络、移除事件、本地脱离和重算，随后重新扫描边界，只有服务端权威对象上不再存在该 generation 标签时才报告 `rollback=COMPLETE`。

实体脚本由 B42 `GameEntityFactory.CreateIsoObjectEntity` 创建；该 Java API 是 void，不能以返回值或 `getEntity` 判断成功。调用后检查同一 `IsoObject:getEntityScript`，雨桶还必须检查真实的 `getFluidContainer` 组件，并以组件的 `getCapacity/getAmount/isFull` 作为满水后置条件。官方 `stateToIsoObject` 未达到后置条件时只允许通过 B42 支持的 `Empty/addFluid` 组件方法修复，并调用所属 `IsoObject:sync`；失败诊断必须包含组件和对象的实际容量/数量，不能吞掉不一致。最终组件实际数量会同步回 `luaObject.waterAmount`、对象 modData，并调用 `updateOnClient`。清理 generation 标签只清除已知字段并保留空命名空间及无关 modData 键，不依赖 Kahlua 不提供的 `next`。无实体脚本的普通柜台/水槽允许走普通家具路径；有脚本但工厂或组件验证失败则拒绝生成。重试不会重复创建方格或对象。
官方无 payload 请求在服务端以 `nil` 到达，这是 `Generate` 的规范表示；B42 网络层也可能以空 Lua table 或
`PZNetKahluaTableImpl` 且 `size()==0` 表示同一个当前空 payload。非空 payload 和其他类型一律拒绝。

玩家建筑灯依赖运行时 BuildingCraft（Workshop 3459887404）的 `BuildingCraft_Light_17`，即“自建房电灯开关1”西墙方向；不得替换成系统房开关或原版壁灯。其 `attachedW` 是 `PropertyContainer` 的 `IsoFlagType` 位标志，必须使用 `IsoFlagType.attachedW` 调用 `properties:has`；`lightswitch` 是 `IsoObjectType.lightswitch`，必须使用 sprite 的 `getType()` 精确校验。该自建房开关没有 `Facing` 键，方向由 `attachedW` 决定；`IsMoveAble`、半径、RGB、`CustomName=Switch`、`GroupName=Light` 和 `MoveType=WallObject` 是需要校验的字符串元数据。这样可避免把 tile 定义里的元数据误当成对象类型或把附墙标志误判为缺失。

对象网络同步遵循官方创建顺序：新对象的 `tagObject`、`addSpecialObject`/
`addNormalObject` 只写本地状态、附着对象、校验 `getObjectIndex` 并重算，不发送对象
索引增量包；创建者在首次广播时恰好调用一次 `transmitCompleteItemToClients`。墙体、
柜台、发电机和灯在标签/必要本地状态完成并附着后发送该唯一完整包，灯仍在附着后
激活再发送。雨桶先附着并发送唯一完整包，然后才进入会调用 `sync`、
`transmitModData`、`updateOnClient` 的全局对象/FluidContainer 状态桥。水槽同样先
附着并发送唯一完整包，再执行 `setUsesExternalWaterSource`、
`doFindExternalWaterSource`，最后按官方路径发送 `transmitModData` 和
`sendObjectChange` 增量，防止客户端重复 `AddItemToMap` 导致对象索引错位。已有地板
替换则显式发送 `transmitUpdatedSpriteToClients` 与 `transmitModData` 两个增量；新建
地板只发送一次完整对象包。回滚阶段对已存在客户端对象的标签清理和地板恢复同步仍
保留显式增量发送。

当前清场事务先由服务端通过定向 `Relocate` 命令驱动客户端 `teleportTo` 到 staging，并同时以相同的 staging 坐标更新服务端玩家对象；anchor 与 staging 坐标均只来自服务端计划，客户端只用无坐标 token 回执。任何 roof-refresh/generation-staging 临时传送前，服务端先验证当前 schema 的唯一 token/phase、事务类型、RV identity、每位成员稳定异步 identity、原始坐标和服务端目标，再将这些值保存在内存事务中；写入或校验失败即禁止传送。客户端不得在传送前调用 `getGridSquare` 拒绝远端目标。只有回执完成、至少跨过请求后与回执后的保护 tick、服务端玩家身份、权限、staging 位置/安全性及传送后的完整 `100×100` 方格预检再次通过后，才允许清场；加载等待期间不删除任何对象。`buildGeneration` 完成后，服务端才发送独立 `FinalRelocate` 命令，把玩家送到 `(20050.5,2050.5,0)`，客户端在该命令处理器内同步刷新 stale-room guard 后再本地 teleport，只有 guard、room-scan 与实际坐标全部成功才发送独立严格 token-only `FinalRelocateAck`；最终命令失败或超时走同一回滚路径。pending 请求按 online ID+用户名绑定，重复请求拒绝；掉线只在同一服务进程内等待同 identity 重连，服务器进程结束则丢弃内存事务，不跨重启恢复。
`FinalRelocateAck` 的服务端位置证明在 B42 网络 tick 暂时暴露旧坐标时，最多使用一次服务端自有目标坐标重断言并再次读取；仍不能证明目标即拒绝 ACK，不能仅凭客户端 token 放行。

服务端还在普通事务处理之后按固定 tick 扫描无状态 `z=-15` 哨兵。候选玩家必须不在当前
内存 generation/roof relocation 的稳定 identity claim 中，且 `floor(x/y)` 精确命中当前
bitmap 派生的单个 generation 中心格或中心减 `(18000,0,15)` 的 roof 远点格。当前
manifest、mapping、boundary、bitmap 与 map/record 双向 `inside=true` identity 关系必须
完整，且候选 RV 恰好一个；否则 fail-closed 并提示 `SAVE_REBUILD_REQUIRED`。返回目标
复用正常 Enter 的 `record.rvPosition` 和权威 record 契约，并验证 active bitmap/合法坐标。
哨兵不恢复原坐标、不执行 repair、不改变 manifest phase/`READY`；busy/短 cooldown 避免
重复发送，玩家仍在 `-15` 时继续受控重试。

Railroader 生成请求的首次 `Relocate` payload 额外由服务端写入
`railroaderTransition=true`、token/loco/seat 过渡提示；普通技术 `Generate` 不携带该字段。
构造异步 `Relocate` payload 后，服务端显式重申同一
`rvId/generation/bitmapVersion` 身份，再附加 Railroader marker，防止后续 payload 扩展丢失
代际令牌；客户端只把该严格标记交给 `prepareGenerationStaging`，先清理本地官方 Ride，再执行服务端
staging 坐标；同一 token 的 `FinalRelocate` 回调/重试不会二次 dismount。该提示不替代
Railroader 的服务端座位快照，也不能改变任一服务端坐标。

动态房间删除还可能让当前 generation 的 7x41 墙环、其包含的 6x40 室内或 6x40 屋顶 footprint 的方格保留一个指向
`RoomDef=nil` 的 `IsoRoom`；玩家稍后走过该格时，音频房间参数会触发异常。服务端在
`removeOldGeneration` 之前广播由 manifest/plan 生成的旧、新边界，并登记本地 guard；staging
让请求玩家在删除期间离开 footprint；删除后、最终入室前、提交前、提交后以及后续 tick 都检查完整旧/新
7x41 墙矩形（其包含 6x40 室内）与屋顶 footprint。唯一允许的
修正条件是 `square:getRoom() ~= nil` 且 `square:getRoomDef() == nil`，此时只调用
`square:setRoomID(-1)`；不得调用 `setRoom(nil)`、强制重建 region，或清除任何仍有有效
`RoomDef` 的新旧房间。IsoRegions 没有公开的 Lua 完成事件；服务端 generation guard 仍使用
连续稳定 tick 和硬超时并在事务完成/超时后释放，而客户端收到的同一服务端 identity 会在
初始稳定尾部后保留为持续 monitor。客户端 `OnTick` 位于 `IsoRegions.update` 之后、下一次
`IsoPlayer.updateInternal2/updateEmitter` 之前，能够处理 READY 后玩家拆墙/拆地板触发的
后续异步 region 更新；请求失败时服务端不会留下 guard。已有 RV 的 `enterExisting` 在
座位变更和传送前调用 `RV.Server.armCurrentRoomOwnershipMonitor`，重连/驻留扫描对每个
当前在线 player object 复用同一入口；该入口只读取已校验 mapping record 的完整
`rvId:generation:bitmapVersion`，并从 current manifest 取得 bounds 定向发送客户端命令。

RV 与 Railroader 座位交接：MP 直接写官方 2.1 的 `driver/passengers` 后，同时维护
`_seatNames`、按用户名清除 `_claims`、driver 重置 `_cmdSeq`、玩家 block/shout/rest 状态，
并调用公开 `RR.ServerTrain.markResync` 让正式快照广播到达；释放时执行对应的 latch、claim、
shelter 清理。SP 优先调用 `RR.Ride.mountRecord`/`dismount(true)`，仅在该模块未加载的
服务端 Lua pass 才回写 `TrainEntity` 的官方 `rider/seat/passenger` 持久化字段。RVTeleport
的 relation 只用于本地过渡顺序，不能替代服务器 seat snapshot。退出反查先按玩家坐标落入
100x100 RV 区块，再找 locomotive 实时 pose；若 locomotive 暂时 inactive/unloaded，仍使用
当前 schema 存档 `locoPosition` 计算并验证保守车旁坐标，不分配虚构座位，标记为
`inactive-mapped`；mapping schema 不完整时拒绝并提示删除测试存档后重建。
玩家坐标不在目标 RV 的 100x100 区块时标记为 `outside-rv` 并拒绝 ExitRV，不发送成功
传送、不修改地图关系；车外请求严格 no-op。
`FinalRelocate` 只有服务端 `railroaderTransition` marker 且完整的
`rvId/generation/bitmapVersion`、token/loco 合法时才进入 Ride 过渡；普通技术
FinalRelocate 必须 no-op。

重复进入或重连进入已生成 RV 后，服务器仅在当前 schema manifest 的 `bounds` 完整且
通过 gate 时，先定向 arm 对应客户端的 stale-room monitor，再选择 NW 墙角西侧首选格
`(wallMinX-1, wallMinY, z)`；bounds 缺失或不匹配直接提示删档重建，不使用 anchor 或其它默认 geometry。若该格已有地板、
对象或角色，则沿西墙邻格、最后沿北侧邻格选择空格。空格中临时调用官方 `addFloor`，
发送唯一 `transmitCompleteItemToClients` 完整对象包，随即调用官方
`transmitRemoveItemFromSquare` 广播删除并复核 `getFloor()==nil`，再执行
`RecalcAllWithNeighbours(true)`。已有对象绝不覆盖；任何加载失败可由 `OnTick` 重试，
失败时不会拒绝本次进入。当前固定布局的首选坐标为 `(20047,2031,0)`。

Boundary 建造归属同时接受 active-cell 与实际 object-host 两种回调坐标：东边使用
`W(x+1,y,z)`、南边使用 `N(x,y+1,z)`，缺失方向时由当前 boundary 的 shell ledger
有限反查 object host。已有 foreign RV/generation tag 或无法证明归属时不覆写标签，
保持 fail-open；不会因旧 edge/footprint 元数据残留而把对象误认作当前 generation。
服务端 `RV_ServerSchema.validateShellEdgeContract` 与本模块的 `validShellEdges` 必须使用 Lua
pattern 字符类 `([NW])` 解析 canonical N/W key；Lua 不支持 `N|W` alternation，两个
校验入口必须保持同一语法契约。
manifest、bitmap、shell ledger、mapping 或异步身份只要不是当前完整 schema，服务端必须拒绝本次 RV 操作并提示“开发版本存档不兼容，请删除该测试存档并重建”；不得迁移、转换、使用旧 bounds、运行 boundary guard、清理对象或传送玩家。只有空的新容器可以按当前 schema 初始化。

拆分模块不注册事件、不接受客户端坐标，也不持有持久事务状态；依赖方向为
`RV_ServerUtil` → `RV_ServerWorld` → `RV_ServerSchema` → `RV_Server` facade。
facade 继续单点注册 `OnClientCommand`、`OnTick`、Boundary 事件和 Railroader hook，
并保持公共 `RV.Server` 与 adapter 契约不变。每个服务端 Lua chunk 的主作用域均须
低于 Kahlua 200-local 限制，静态测试使用 luaparse 逐文件核验。

水电服务端模块由 `RV_UtilityStore.lua`、`RV_UtilityWater.lua`、
`RV_UtilityPower.lua` 和 `RV_UtilityServer.lua` 组成。Store 只接受完整 current
schema 的水/电记录；缺失或 identity 不匹配进入 `SAVE_REBUILD_REQUIRED`，不迁移旧字段。
Water 持有唯一 canonical `sharedAmount`，每个 server tick 由 facade 在一次
`inWaterSettlement` guard 内现场遍历 registry，按
`sum(max(Dprev-Dobs,0))` 结算，再单向镜像到中央和设备 FluidContainer。普通设备
失效只清理/标记本设备，重复身份、同对象多登记和跨 RV 占用拒绝整轮。`ADD_WATER`
先服务端验证独立玩家物品源，再调用已有 guard 下的 `settleUnderGuard`，随后扣除源容器并只按确认的
`confirmedTransfer` 入账；中央和设备镜像不允许作为 source。Power 只绑定原生
`IsoGenerator` 身份与回路状态，燃油/condition 不复制为第二份余额。未经过整体
运行时验证的目录设备保持禁用；本目录静态检查不等同于游戏/联机测试。
