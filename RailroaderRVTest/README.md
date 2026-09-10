# RailroaderRVTest

Railroader RV 的程序化生成技术验证包。RailroaderMP 的功能已合并进 Railroader 官方版本；独立版本不再维护，也不作为本包依赖或实现对照。当前目标是 Railroader RV，命名空间固定为 `RailroaderRV`，模组 ID 为 `RailroaderRVTest`。

## 技术路线

不内置地图或地图包。玩家点击现有按钮后，服务端固定生成 anchor 为 `(20050,2050,0)`，并在新布局与 manifest 保存的旧布局之外，优先选择清场矩形正上方的居中 staging 格 `(anchorX, clearMinY-1)`（半径 51），再使用有界环搜索兜底；客户端先被传送到该 staging 格，以远距传送触发目标区块加载，避免玩家在旧房间 footprint 内等待重建。B42 服务端按 64×64 cell、玩家 online chunk-grid width 的一半加载相关区域；由于该除法在 Java 中取整，居中上边缘需要至少 grid width 14 才能覆盖完整范围。服务端等待并复核闭区间 `x=20000..20100`、`y=2000..2100` 的 101×101 清场范围完整加载后，才清理该范围并继续完整房间/对象生成；缺失方格在等待期间返回可重试状态，不抛每 tick 的 Lua/Kahlua 异常，硬超时仍在任何清场前取消。客户端只负责显示菜单并提交空意图。照明灯需要运行时启用的 BuildingCraft（Workshop 3459887404）提供自建房灯具图集与 tile definition；本包不复制其贴图或数据文件。

服务端权威约束：客户端请求不携带可信坐标，也不能直接修改世界。服务端从权威玩家对象验证身份和权限，固定生成 anchor 为共享常量 `(20050,2050,0)`，把服务端和客户端都定向传送到同一个服务端选择、且经旧/新 footprint 排除的 staging 格，再等待并复核固定 anchor 周围完整 101×101 base footprint 已加载；staging 到达前、加载等待期间和清场/重建期间玩家都不在结构 footprint 内。若客户端网格宽度不足以覆盖全部 base footprint，预检只等待并最终硬取消，不进行部分清场。最后由服务端执行对象删除、程序化房间/对象生成和网络同步，建造成功后才独立传送到 `(20050.5,2050.5,0)`。清理只访问已存在方格，覆盖僵尸、尸体、石块、地表装饰、树木、杂草、灌木、地板等对象；不会由客户端提交范围或世界状态。当前范围严格为 `x=20000..20100`、`y=2000..2100`，遍历有效的已加载 `z` 层。生成前底层 101×101 与墙体坐标必须已加载，屋顶才可按合法世界坐标创建缺失的 `z+1` 方格。

重复生成会让 B42 动态房间系统移除旧 `IsoRoom` 并重建 `RoomDef`；当前房间/对象生成已启用，清场失败会短路生成，任一生成阶段失败则进入本代回滚。B42.20 没有向 Lua 暴露 `GameServer.sendTeleport`，所以服务端向目标客户端发送自有 `Relocate` staging 命令并同步调用服务端玩家的 `teleportTo`；客户端仅回传无坐标 token。回执后还需跨 tick，并由服务端再次核对 online ID+用户名、权限、当前位置、staging 安全性和固定 anchor 的完整加载状态，才执行 101×101 清场及后续生成。完整建造成功后、提交 `READY` 前，服务端发送独立 `FinalRelocate` 命令并同步调用服务端玩家 `teleportTo(20050.5,2050.5,0)`；客户端在该命令处理器内先同步扫描并清除目标旧/新 footprint 中 `room~=nil && RoomDef==nil` 的引用，再执行本地 teleport，最终命令不产生初次 ack。服务端在加载等待期间不做任何世界修改，并以硬超时结束；重复请求、断线、死亡、权限丢失、身份变化、超时或复核失败均在世界修改前取消，不删除或重置存档。

staging 撤离解决了“重建瞬间玩家正站在旧房间内”的路径。旧房 7x41 墙环（其包含 6x40 室内）或 6x40 屋顶
footprint 仍可能有方格残留非 `-1` room ID，指向已被
`WorldRegionToMetaGrid.removeIsoRoom` 清空 `RoomDef` 的旧 `IsoRoom`；玩家稍后走到该格同样
会触发 `ParameterFirearmRoomSize` 异常。生成事务因此会在清除旧 generation 前，把服务端
manifest 与新 plan 产生的权威旧/新边界广播给所有已连接客户端，并在服务端同步登记 guard。
服务端在删除后、最终入室前、提交前、提交后刷新；客户端在 `FinalRelocate` 的同步处理器中先清理，随后双方还会跨 tick 扫描完整旧/新 7x41 墙矩形（其包含 6x40 室内）与屋顶
footprint。只有 `square:getRoom() ~= nil` 且 `square:getRoomDef() == nil` 的非法引用会被
`setRoomID(-1)`；有有效 `RoomDef` 的新房、旧房和重叠区域均保持不变，不伪造 RoomDef、
不清除真实房间化，也不调用 `setRoom(nil)` 或强制 region 重建。IsoRegions 未暴露 Lua
完成事件，所以 guard 采用最短监测期、连续稳定 tick 与硬超时，并在完成/超时后自动释放；
新客户端重连时则从最终世界状态重建。

## 目录职责

```text
contents/mods/RailroaderRVTest/42/
  media/lua/client/RailroaderRV/RV_ContextMenu.lua  菜单与意图请求
  media/lua/server/RailroaderRV/RV_Server.lua       权威验证、生成、同步、回滚
  media/lua/shared/RailroaderRV/RV_Constants.lua    共享常量契约
  media/lua/shared/RailroaderRV/RV_Layout.lua       共享布局契约
  media/lua/shared/Translate/                        UI 翻译
  mod.info                                             模组元数据
README.md                                               技术路线与验收契约
workshop.txt                                            Workshop 元数据
```

## 当前验证范围

普通世界右键菜单会显示“测试生成房车”。客户端只向模块
`RailroaderRVTest` 发送 `Generate` 命令，payload 为空，不发送可信坐标。服务端应从
共享固定目标常量生成布局，并从权威玩家对象验证身份、权限和请求阶段，负责全部世界修改。官方服务端对该无 payload 数据包传入
`nil`；服务端也兼容历史调用产生的空 table 包装，但拒绝任何非空内容。

布局契约如下：

- 固定目标为 `(20050,2050,0)`；清场 XY 为闭区间 `x=20000..20100`、`y=2000..2100`（即相对中心 `x±50`、`y±50`），服务端应遍历所有有效 `z` 层；技术验证会破坏性移除该范围内现有对象。
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

当前运行时阶段顺序固定为：服务端目标/旧新 footprint 校验 → 选择并定向传送到安全 staging 格 → 等待客户端 token/跨 tick 复核 → 服务端等待并复核 10201 个 base 方格加载 → 101×101 清场 → 6×40 carpet 地板 → NW/SE 单角条与 N/W 直墙 →
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

每个对象都带有 `RailroaderRVTest` owner/generation 标签。地板首次被替换时还保存原
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
