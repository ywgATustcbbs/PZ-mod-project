# RailroaderRVTest

Railroader RV 的程序化生成技术验证包。RailroaderMP 的功能已合并进 Railroader 官方版本；独立版本不再维护，也不作为本包依赖或实现对照。当前目标是 Railroader RV，命名空间固定为 `RailroaderRV`，模组 ID 为 `RailroaderRVTest`。

## 技术路线

不内置地图或地图包。玩家点击现有按钮后，服务端固定生成 anchor 为 `(20050,2050,0)`；首次生成的临时 staging 点由当前 layout/bitmap 管理 scope 中心计算为
`(managedOriginX+floor(width/2), managedOriginY+floor(height/2), -15)`，不再使用房车边界附近的点。
该 `-15` 层仅用于让目标区块加载，客户端在严格阶段标记下显示本地常量“正在生成房车”。B42 服务端按 64×64 cell、玩家 online chunk-grid width 的一半加载相关区域；服务端等待并复核半开区间 `x=[20000,20100)`、`y=[2000,2100)` 的 100×100 清场范围完整加载后，才清理该范围并继续完整房间/对象生成；缺失方格在等待期间返回可重试状态，不抛每 tick 的 Lua/Kahlua 异常，硬超时仍在任何清场前取消。客户端只负责显示菜单并提交空意图。照明灯需要运行时启用的 BuildingCraft（Workshop 3459887404）提供自建房灯具图集与 tile definition；本包不复制其贴图或数据文件。

服务端权威约束：客户端请求不携带可信坐标，也不能直接修改世界。服务端从权威玩家对象验证身份和权限，固定生成 anchor 为共享常量 `(20050,2050,0)`；首次生成的 staging 只接受上述 current-schema 管理中心 `z=-15`，再等待并复核固定 anchor 周围完整 100×100 base footprint 已加载。staging 到达前、加载等待期间和清场/重建期间玩家都不在已生成结构 footprint 内。若客户端网格宽度不足以覆盖全部 base footprint，预检只等待并最终硬取消，不进行部分清场。最后由服务端执行对象删除、程序化房间/对象生成和网络同步，建造成功后才独立传送到 `(20050.5,2050.5,0)`。清理只访问已存在方格，覆盖僵尸、尸体、石块、地表装饰、树木、杂草、灌木、地板等对象；不会由客户端提交范围或世界状态。当前范围严格为 `x=[20000,20100)`、`y=[2000,2100)`，遍历有效的已加载 `z` 层。生成前底层 100×100 与墙体坐标必须已加载，屋顶才可按合法世界坐标创建缺失的 `z+1` 方格。manifest、bitmap、shell ledger 或 mapping 只要不是当前完整 schema，服务端即拒绝本次 RV 操作，不执行旧范围遍历、房间引用修复、标签删除、对象清理或玩家传送，并提示删除该测试存档后重建。

## RV boundary contract

所有 stale-room guard 与 roof-repair runtime cache 均以完整
`rvId:generation:bitmapVersion` 作为索引，并在复用前逐字段比对当前 managed bitmap、
shell edges 与 wall/bounds geometry；同一 identity 下的几何快照不一致会丢弃旧 cache，
不会让不同 RV 或不同几何代际互相覆盖。

拆除当前 RV 外墙时，服务端以 B42 42.20.4 的
`SledgehammerDestroyPacket -> RemoveItemFromSquarePacket` 所触发的
`OnObjectAboutToBeRemoved` 为主入口；该回调在 authoritative `IsoThumpable` 脱离前严格校验
当前 tag、object index、sprite 与 shell ledger。`OnDestroyIsoThumpable` 仅覆盖直接 thumpable
销毁路径，并复用相同匹配器。两条事件按完整房间 identity 去重；若对象事件未暴露，服务端
30-tick current map/presence 流程会读取 authoritative player square 的 `isInARoom()`（并采样
`getRoom()/getRoomDef()`），只在当前 RV scope 内观察到 inside→outside transition 时安排修复。

每个命中事件都启动一个短时、服务端权威的 roof-refresh 事务：枚举当前 RV scope 内全部
在线玩家，逐人记录服务端权威的原始 `x/y/z` 与 identity，再复用现有 `Relocate`/严格
token-only `RelocateAck` 将所有成员送到当前 bitmap 中心减去刷新向量 `(18000,0,15)` 的
远端点。`queued` 阶段尚未发送 `Relocate` 或建立 Boundary lease 时，仅等待成员重绑最多
600 ticks；期限内掉线成员可按稳定 identity 重绑，超时安全取消并释放事务占用。进入
`temporary`/`repairing`/`returning` 后不使用该排队期限。远端移动必须跨 tick 完成并等待所有成员到达，
以强制 RV 区块卸载/重载；远端合法坐标可能暂时没有客户端 `GridSquare`，服务端仍以重新
读取的权威玩家坐标推进阶段，等待期间不运行局部 repair。服务端只接受当前 schema/manifest/
bitmap 身份，不读取客户端坐标或旧 bounds。
若 generation 全局事务占用共享 managed scope，已接受的 queued roof 或 follow-up 会标记
`waitingForGeneration` 并暂停 `queuedDeadlineTick`/`expiresAtTick`；generation 结束后必须先按
当前 `rvId:generation:bitmapVersion` 复核记录，成功才重新建立完整 600-tick 等待窗口，失败则
明确取消并提示重建存档，不静默丢弃事件。
一次事务的失败状态绑定到唯一 relocation token；正在回传的原事务继续消费该状态，尚未启动的后续独立墙体操作不会被旧失败记录吞掉，而会在当前事务空闲后重新排程。

所有成员先远移返回并释放各自的 boundary correction lease，随后服务端按进入已有 RV 的同一
`repairRoofVisuals`/roof geometry 路径对该房间执行一次修复（多成员只选一个有效权威上下文，不重复 force 世界变更）；修复/刷新异常被
隔离并转为明确失败，不能阻断其余成员的回传。任何中间异常、断线、死亡、对象失效、身份/schema 变化、加载
超时或阶段/ACK 不匹配都会进入最终逐人回传；只要权威坐标仍为 `z=-15`，事务就保持 current-schema
身份与 lease 并持续受控重试，直到每位在线成员回到各自记录的合法 RV 方格。服务端日志只
报告权威 add/remove 应用，不能把它冒充为客户端视觉成功。

每个已生成 RV 的记录带有独立 `rvId + generation + bitmapVersion`。`RV_Bitmap.lua` 保存每个管理 z 层的两个 100×100 packed bitset：`walkBits` 是 active/inactive 移动几何，`buildBits` 是可建造几何；bitmap 的 cell 结果是最终判定，AABB 只用于遍历和粗筛。半开 scope 为 `[originX,originX+100)`、`[originY,originY+100)`、`[minZ,maxZ)`，所有新增边界入口先经同一 scope resolver，当前位置在 scope 外一律不拦截、不传送，cleanup 也不会访问 scope 外方格。

移动保护借鉴 Railroader 的“保存前一位置并检查 swept transition”思路，但不调用或复制任何 `RR_*` collider/body/servercollision，也不生成隐形墙。客户端 `RV_BoundaryClient` 只用快照做即时预测；服务端 `RV_BoundaryServer` 每 tick 以 authoritative player 坐标检查当前 active cell 和 `segmentValid`，只在 segment 合法时更新 generation-scoped `lastValid`。已经落入 inactive cell 或穿越 hole 时，服务端仅在仍处于该 RV scope 内才传送回最近合法 active cell；scope 外严格 no-op。transition token、generation、bitmapVersion 和 correction sequence 防止生成/进出/重连期间的抖动与旧包覆盖。

建造审计采用低侵入的 dirty-cell/post-create 路径，标准事件不可可靠 veto 时不阻塞建造系统；事件或对象归属不明确则 fail-open。已确认属于当前 RV 且完整 footprint 位于 scope 内的玩家对象，如果落在 inactive/buildBits 外，由服务端删除并广播；周期 cleanup 仅以当前 RV 的 100×100×Z cursor 兜底。shell ledger 与 cell bitmap 分离：canonical edge 只存 N/W，east edge 使用 `W(x+1,y,z)`，south edge 使用 `N(x,y+1,z)`。因此东/南墙、门、窗即使 host tile 落在 inactive cell，也因 `edgeKey + rvId + generation + bitmapVersion` 被保留；ledger 不会重建被玩家拆掉的墙，也不恢复旧对象。记录到 shell host 但无法由 ledger 证明归属的对象同样 fail-open，避免把 host tile 当成无条件删除依据。

实现约束：Lua 服务端对 canonical `edgeKey` 的 N/W 解析统一使用字符类 `([NW])`；不得改回不受 Lua pattern 支持的 `N|W` alternation。`RV_Server` 与 `RV_BoundaryServer` 的解析契约必须保持一致。

重复生成会让 B42 动态房间系统移除旧 `IsoRoom` 并重建 `RoomDef`；当前房间/对象生成已启用，清场失败会短路生成，任一生成阶段失败则进入本代回滚。B42.20 没有向 Lua 暴露 `GameServer.sendTeleport`，所以服务端向目标客户端发送自有 `Relocate` staging 命令并同步调用服务端玩家的 `teleportTo`；客户端仅回传无坐标 token。任何 roof-refresh 或首次 generation-staging 临时传送前，服务端先验证当前 schema、RV identity、稳定异步身份、精确原坐标和服务端目标，再把它们保存在当前进程的内存事务中；验证失败即禁止传送。回执后还需跨 tick，并由服务端再次核对 online ID+用户名、权限、当前位置、staging 安全性和固定 anchor 的完整加载状态，才执行 100×100 清场及后续生成。完整建造成功后、提交 `READY` 前，服务端发送独立 `FinalRelocate` 命令并同步调用服务端玩家 `teleportTo(20050.5,2050.5,0)`；客户端在该命令处理器内先同步扫描并清除目标旧/新 footprint 中 `room~=nil && RoomDef==nil` 的引用，再执行本地 teleport，只有 guard/room scan/实际目标坐标均成功才发送严格 token-only `FinalRelocateAck`。玩家掉线时，当前进程保留稳定 online ID+用户名、精确浮点原坐标和阶段；同一身份重新上线后继续权威回传，不能因替换 `IsoPlayer` 对象而丢失事务。服务器进程崩溃、关闭或重启会丢弃这些内存事务；中间传送不建立持久记录，也不恢复原坐标、repair、`READY` 或最终回传阶段。服务端在加载等待期间不做任何世界修改，并以硬超时结束；旧、缺失或部分持久 schema 一律提示删档重建，不自动迁移。

除正常事务外，服务端还运行无状态的 `z=-15` 哨兵：在普通事务处理之后按固定 tick 扫描在线玩家，只考虑 `floor(z)==-15` 且没有被当前内存 generation/roof 事务以稳定身份占用的玩家。玩家的 `floor(x/y)` 必须精确命中当前 bitmap 派生的单个临时格：首次 generation 是 managed bitmap 中心，roof-refresh 是该中心减去 `(18000,0,15)`；不是宽范围或旧 bounds。哨兵只有在当前 manifest、mapping、boundary、bitmap、双向 `inside=true` 玩家关系和异步身份均通过 current-schema 校验，且匹配到恰好一个 RV 时才继续，并在传送前后再次检查事务 claim。回传目标复用正常 Enter 使用的当前 `record.rvPosition` 与权威 record 契约，并验证 active bitmap 和合法世界坐标；哨兵不恢复原坐标、不执行 roof repair、不改变 manifest phase/`READY`，匹配不唯一或 schema/身份不完整时 fail-closed 并提示 `SAVE_REBUILD_REQUIRED`。短 cooldown 和 busy 标记防止重复发送；玩家仍停留在 `-15` 时只受控延迟重试，不会永久吞掉候选。

相同墙对象事件用短期稳定 `roomKey:x:y:z:objectIndex` 或坐标 fallback 去重；事务期间不同坐标/对象索引的独立事件进入有界 follow-up 队列，前一 token 完成后按当前 mapping 重新验证并启动，不会被吞掉或触发同一事件的第二次传送；稳定 key 无法取得时 fail-closed。首次 generation staging 仍只使用当前 managed scope 中心的 `z=-15`，已移除旧边界搜索 staging 路径。

staging 撤离解决了“重建瞬间玩家正站在旧房间内”的路径。旧房 7x41 墙环（其包含 6x40 室内）或 6x40 屋顶
footprint 仍可能有方格残留非 `-1` room ID，指向已被
`WorldRegionToMetaGrid.removeIsoRoom` 清空 `RoomDef` 的旧 `IsoRoom`；玩家稍后走到该格同样
会触发 `ParameterFirearmRoomSize` 异常。生成事务因此会在清除旧 generation 前，把服务端
manifest 与新 plan 产生的权威旧/新边界广播给所有已连接客户端，并在服务端同步登记 guard。
服务端在删除后、最终入室前、提交前、提交后刷新；客户端在 `FinalRelocate` 的同步处理器中先清理，随后双方还会跨 tick 扫描完整旧/新 7x41 墙矩形（其包含 6x40 室内）与屋顶
footprint。只有 `square:getRoom() ~= nil` 且 `square:getRoomDef() == nil` 的非法引用会被
`setRoomID(-1)`；有有效 `RoomDef` 的新房、旧房和重叠区域均保持不变，不伪造 RoomDef、
不清除真实房间化，也不调用 `setRoom(nil)` 或强制 region 重建。IsoRegions 未暴露 Lua
完成事件，所以客户端 guard 在初始连续稳定 tick 后仍以完整
`rvId:generation:bitmapVersion` identity 持续监测；`OnTick` 位于
`IsoRegions.update` 之后、下一次 `IsoPlayer.updateInternal2/updateEmitter` 之前，能覆盖
READY 后墙/地板移除触发的异步 region 更新。新的当前 generation 会替换旧 monitor，
不推断旧 bounds/geometry。进入已有 RV 或重连驻留时，服务端先验证当前 manifest、
mapping record 与完整 `rvId:generation:bitmapVersion`，再用当前 manifest bounds
向对应客户端定向重发 monitor；验证失败返回 `SAVE_REBUILD_REQUIRED` 且不传送，客户端
不能从本地状态重建 geometry。

## 目录职责

```text
contents/mods/RailroaderRVTest/42/
  media/lua/client/RailroaderRV/RV_ContextMenu.lua       菜单与意图请求
  media/lua/client/RailroaderRV/RV_BoundaryClient.lua    bitmap 预测与修正反馈
  media/lua/server/RailroaderRV/RV_Server.lua            权威验证、生成、同步、回滚
  media/lua/server/RailroaderRV/RV_BoundaryServer.lua    边界 guard、建造审计、周期清理
  media/lua/server/RailroaderRV/RV_RailroaderServer.lua  RV↔玩家↔机车适配、无状态哨兵
  media/lua/shared/RailroaderRV/RV_Constants.lua          共享常量契约
  media/lua/shared/RailroaderRV/RV_Layout.lua             共享布局契约
  media/lua/shared/RailroaderRV/RV_Bitmap.lua             100×100×Z packed bitmap
  media/lua/shared/Translate/                        UI 翻译
  mod.info                                             模组元数据
README.md                                               技术路线与验收契约
workshop.txt                                            Workshop 元数据
```

## 开发期存档 schema 强制门

开发阶段只支持当前代码声明的 manifest、bitmap、shell ledger、RV mapping 和
异步身份 schema；临时传送事务只存在于当前服务进程内存。任何缺失字段、版本不匹配、部分写入或旧字段结构都会在服务端
current-only gate 失败；本次 RV 操作随即停止，不使用旧 geometry，不清理对象，不
运行 boundary guard，也不传送玩家。服务端日志和客户端失败通知必须明确提示：
“开发版本存档不兼容，请删除该测试存档并重建”。模组不会自动删除或修改存档。

代码 MUST NOT 自动迁移、转换、字段别名兼容、推断旧 bounds/bitmap/mapping/generation，
也不得为这些路径保留 fallback。只有完全空的新容器可以按当前 schema 初始化；这不
是旧数据迁移。未来若需要存档兼容，必须由用户另行明确授权。

## 当前验证范围

普通世界右键菜单会显示“测试生成房车”。客户端只向模块
`RailroaderRVTest` 发送 `Generate` 命令，payload 为空，不发送可信坐标。服务端应从
共享固定目标常量生成布局，并从权威玩家对象验证身份、权限和请求阶段，负责全部世界修改。官方服务端对该无 payload 数据包传入
`nil`；B42 网络层也可能以空 table 表示同一个当前空 payload，但拒绝任何非空内容。

布局契约如下：

- 固定目标为 `(20050,2050,0)`；RV 管理 XY 为半开区间 `x=[20000,20100)`、`y=[2000,2100)`（相对 anchor 为 `-50..+49`），每个 `z` 层由 100×100 packed bitmap 决定 active/buildable cell；AABB 只用于遍历粗筛，不能作为合法性结论。技术验证会破坏性移除该管理范围内现有对象。
- 清场后不铺整片金属地板；房屋净室内为东西宽 6、南北长 40，即相对中心
  `x-2..x+3`、`y-19..y+20`，生成精确 sprite `floors_interior_carpet_01_5`。
- 外墙是包住该净室内的严格 7x41 墙环，且无门。NW 使用精确的单角条
  `walls_interior_house_03_22`，SE 使用同组对应的 `walls_interior_house_03_23`；
  直墙按 tile definition 的方向配对使用 `walls_interior_house_03_20`（WallW）与
  `walls_interior_house_03_21`（WallN）：

  ```text
  [NW][N][N][N][N][N][W]
  [W] [ ][ ][ ][ ][ ][W]
  [W] [ ][ ][ ][ ][ ][W]
  ... 38 further interior rows ...
  [W] [ ][ ][ ][ ][ ][W]
  [N] [N][N][N][N][N][SE]
  ```

  总计 92 个唯一墙坐标和 92 个对象，其中 2 个为单角条（NW/SE），直墙为
  11 个 north 方向和 79 个 west 方向；两个角条的构造方向各贡献一个计数。
  墙体去重键为坐标+朝向+role，拒绝同一坐标的同一朝向重复。
  角条选择已由只读 B42 tile definition 定向查证：`walls_interior_house_03_22`
  明确声明 `WallNW` 并对应 `CornerNorthWall/CornerWestWall`，
  `walls_interior_house_03_23` 明确声明 `WallSE`；同一组的直墙条目为
  `..._20` (`WallW`) 与 `..._21` (`WallN`)。仓库中的 BuildingCraft 墙体数据也将
  `20/21` 作为同一普通墙对，将 `22` 作为单角条。
- 屋顶是 `z+1` 的 6x40 普通平顶地板，通过 `addFloor` 创建并以角色
  `roof-floor` 标记；不创建屋顶专用 `IsoThumpable`。预检只要求该 6x40
  footprint 的世界坐标合法，不要求上层 `IsoGridSquare` 预先存在；
  `ROOF_FLOOR` 阶段对缺失方格复用官方玩家建造路径
  (`IsoGridSquare.new(cell,nil,x,y,z)` → `cell:ConnectNewSquare(square,false)`)，
  校验连接结果后再铺地板，已有方格则直接复用。
- 西墙玩家建筑照明灯为 `(cx-2,cy,cz)`；柜台和水槽为 `(cx+1,cy,cz)`；雨水收集桶在正上方 `(cx+1,cy,cz+1)`；发电机在 `(cx-1,cy,cz+1)`。
  照明灯必须使用 BuildCraft 的“自建房电灯开关1”`BuildingCraft_Light_17`，而不是
  系统房开关组（`lighting_indoor_01_1/0/2/3`、`lighting_indoor_01_5/4/7/6`）或普通
  原版壁灯。该图集和 tile definition 由运行时 BuildingCraft 依赖提供，本包不复制贴图。
  运行时要求其西墙 `attachedW`（通过 `IsoFlagType.attachedW` 位标志校验）、
  `IsoObjectType.lightswitch`（通过 sprite 的 `getType()` 精确校验）、
  `IsMoveAble`、`LightRadius`、`lightR/lightG/lightB`、`CustomName=Switch`、
  `GroupName=Light` 与 `MoveType=WallObject` 字符串属性齐全。该自建房开关 tile
  没有 `Facing` 键，`attachedW` 是方向依据。`attachedW` 不属于字符串属性键，
  `lightswitch` 也不是字符串属性，不能用 `PropertyContainer:has("attachedW")` 或
  `PropertyContainer:has("lightswitch")` 替代枚举校验。
- 发电机初始开启且燃油 100；雨水桶初始满水；照明灯初始开启。

当前运行时阶段顺序固定为：服务端目标/旧新 footprint 校验 → 选择并定向传送到安全 staging 格 → 等待客户端 token/跨 tick 复核 → 服务端等待并复核 10000 个 base 方格加载 → 100×100 清场 → 6×40 carpet 地板 → NW/SE 单角条与 N/W 直墙 →
  按官方路径创建/复用 z+1 方格并铺 6x40 普通地板 → 整体 `RecalcProperties`/`RecalcAllWithNeighbours(true)`
   与屋顶/区域探测 → 发电机 → 雨水桶 → 柜台/水槽 → 最后照明灯 → 服务端发送
   独立 `FinalRelocate` 并将玩家校正到 `(20050.5,2050.5,0)` → 提交 `READY`。照明灯严格复用
  BuildCraft 的 `IsoLightSwitch` 路径（`IsLighting=true`、`setPower(2)`、
  `addLightSourceFromSprite`、`update`、`AddSpecialObject`、重算），不再手工创建
  或附加独立光源，避免重复光源和 Java 类型风险；对象加入方格后才
  执行开启与网络同步。新对象的 `tagObject`、`addSpecialObject` 与
  `addNormalObject` 只写本地状态、附着、索引校验和重算，不发送对象索引增量包；
  每个创建者在首次广播时恰好调用一次 `transmitCompleteItemToClients`。
  墙体、柜台、发电机和灯在标签/必要本地状态完成并附着后发送该唯一完整包。
  雨桶先附着并发送唯一完整包，再进入会调用 `sync`、`transmitModData` 与
  `updateOnClient` 的官方全局对象/FluidContainer 状态桥；水槽也先附着并发送
  唯一完整包，再执行 `setUsesExternalWaterSource`、`doFindExternalWaterSource`，
  最后按官方路径发送 `transmitModData` 与 `sendObjectChange` 增量。这样所有
  增量都只引用客户端已存在的对象，不会因重复 `AddItemToMap` 造成索引错位。

每个对象都带有 `RailroaderRVTest` owner/rvId/generation/bitmapVersion 标签。地板首次被替换时还保存原
sprite；房屋 carpet 地板与屋顶地板连续改写同一对象时不会覆盖这份初始快照。已有地板使用
`transmitUpdatedSpriteToClients`，本轮新建地板使用添加包。
已有地板的 generation 标签通过单独的 `transmitModData` 增量发送；新建地板不发送
任何前置增量，只发送一次完整对象包。

任一阶段（包括未来重新启用的最后灯光）失败时，服务端会按本次 generation 遍历已记录边界：已有地板
恢复原 sprite 并清除本模组标签，本轮新建地板、墙体、发电机、雨桶、家具和灯只调用 B42 的
`transmitRemoveItemFromSquare`；该 API 自己负责网络包、`OnObjectAboutToBeRemoved`、对象脱离
world/square 与邻居重算，服务端随后再次扫描服务端权威对象，
只有不存在该 generation 标签时才记录 `rollback=COMPLETE`，否则记录
`rollback=FAILED` 并要求恢复。实体脚本使用 B42 `GameEntityFactory` 的 void API，雨桶
创建后必须从同一 `IsoObject` 的 `FluidContainer` 读取真实 `getCapacity/getAmount/isFull`
状态；官方 `stateToIsoObject` 未达到满水后，才使用组件支持的 `Empty/addFluid` 修复，仍
失败时记录组件与对象的实际容量/数量，并将组件实际数量同步回全局对象和 modData。
标签清理只清除已知字段并保留空命名空间及其他 modData 键，不扫描 Kahlua 命名空间、
也不会调用不提供的 `next`。无实体脚本的普通家具仍允许走普通 `AddTileObject` 路径。
生成期间的 `phase` 也会写入 manifest 并打印日志。

`media/lua/shared/RailroaderRV/RV_Constants.lua` 和 `RV_Layout.lua` 是服务端可
`require` 的纯共享契约；它们不直接修改世界。`RV_ContextMenu.lua` 负责菜单、空
生成请求和服务端定向的本地撤离；撤离回执不含坐标，生成布局不会从撤离后位置重算。

## 开发与验证约束

- 基线和版本默认已复核；禁止反复确认基线或检查版本。当前基线唯一事实源为根目录
  `game-decompiled/42.20.4/metadata.txt`。
- 主 agent 只做统筹、约束、审核和验收，禁止自行编码，且必须核查子 agent 的证据；具体实施由 Luna worker 子 agent 完成。除必须复用上下文外，每次任务新建子 agent；没有明确卡死迹象不得中断耗时任务。
- 工作模式为“直接实现 → 测试 → 修复问题”，不是 TDD。
- `modinfos.json` 只读，约含 2000 个模组 metadata；禁止全量读取或加载进上下文，只能定向搜索与房车功能相近、相似或可能解决 bug 的条目。确认目标后可用 `steamcmd` 下载对应模组并参考源代码。

## 明确暂缓

本阶段只验证程序化坐标、对象摆放和 B42 对封闭玩家建筑的动态房间识别；没有门。
房间长期回收、玩家自建对象和丢弃物品的覆盖策略留给后续实现；当前清场明确是破坏性
操作。动态房间重建的瞬态只能通过实机联机确认；源码侧以 Lua 语法扫描、布局数量、
撤离握手和事务顺序断言进行快速检查。

## 本地 Workshop 源包

源包根目录为 `RailroaderRVTest/`，模组实际目录为：

`contents/mods/RailroaderRVTest/42/`

`workshop.txt` 有意不填写 Workshop ID；发布前必须由 Workshop 流程分配真实 ID。
本包不携带地图、贴图、模型、音乐或其他外部资源；路线仅在指定区域加载后由服务端生成。

当前 manifest 若缺少完整 current schema identity，服务端拒绝本次操作并提示删除测试存档后重建；
不会遍历、排除、删除或推断任何不完整的 bounds。
