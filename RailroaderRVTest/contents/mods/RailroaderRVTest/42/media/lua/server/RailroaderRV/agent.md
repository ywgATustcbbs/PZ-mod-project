# server/RailroaderRV

结构：`RV_Server.lua` 聚合共享契约并执行服务端生成事务。

职责：严格处理 `OnClientCommand`；只接受有效玩家和空 args；服务端固定生成 anchor 为共享目标 `(20050,2050,0)`，并以 `isValidSquare` 预检后优先选择清场矩形正上方居中的 `(anchorX, clearMinY-1)` staging 格（半径 51，位于保存旧 bounds 与新 bounds 外），再以有界搜索兜底；不得在初次传送前读取或要求远端方格已加载。B42 服务端按 64×64 cell 和 online chunk-grid width 的一半加载相关区域，Java 整数除法使该布局需要至少 grid width 14 才能覆盖完整 101×101；客户端与服务端到达并确认 staging 安全后，在硬超时内等待完整 101×101 base footprint 已加载，再清理已加载的有效 `z` 层。缺失方格在轮询中返回可重试状态而不抛 Kahlua 异常；若加载范围始终不足则硬取消且不发生部分清场。清理通过快照和服务端网络移除覆盖僵尸、石块、地表装饰、树木、杂草、灌木、地板等对象；清场成功后才进入完整房间/对象生成。若清场失败，必须短路 `buildGeneration`；若任一生成阶段失败，必须沿既有 generation 回滚路径移除本代对象。生成前仍先预检 101×101 底层/墙体已加载、屋顶 6×40 的世界坐标及 `z+1` 合法。跳过 `PLAYER_METAL_FLOOR`/整片金属地板阶段，仅生成房屋内部 6×40 的 `floors_interior_carpet_01_5` 地板；直墙为 `walls_interior_house_03_20`/WallN 配对 `..._21`，NW/SE 单角条为 `..._22`/`..._23`。`ROOF_FLOOR` 阶段按官方玩家建造路径，在已预检的目标范围内用 `IsoGridSquare.new` + `ConnectNewSquare(..., false)` 创建缺失的上层方格（兼容 `createNewGridSquare`），校验连接结果后再 `addFloor`；已有方格直接复用。

地板事务会在第一次替换每个对象时记录原 sprite；室内精确 carpet→roof floor 的连续阶段保留同一份初始快照。已有地板使用 `transmitUpdatedSpriteToClients`，新建地板使用添加包。失败回滚对已有地板恢复原 sprite 并清除本模组标签，对本轮新建地板只调用 `transmitRemoveItemFromSquare`；该 B42 API 负责网络、移除事件、本地脱离和重算，随后重新扫描边界，只有服务端权威对象上不再存在该 generation 标签时才报告 `rollback=COMPLETE`。

实体脚本由 B42 `GameEntityFactory.CreateIsoObjectEntity` 创建；该 Java API 是 void，不能以返回值或 `getEntity` 判断成功。调用后检查同一 `IsoObject:getEntityScript`，雨桶还必须检查真实的 `getFluidContainer` 组件，并以组件的 `getCapacity/getAmount/isFull` 作为满水后置条件。官方 `stateToIsoObject` 未达到后置条件时只允许通过 B42 支持的 `Empty/addFluid` 组件方法修复，并调用所属 `IsoObject:sync`；失败诊断必须包含组件和对象的实际容量/数量，不能吞掉不一致。最终组件实际数量会同步回 `luaObject.waterAmount`、对象 modData，并调用 `updateOnClient`。清理 generation 标签只清除已知字段并保留空命名空间及无关 modData 键，不依赖 Kahlua 不提供的 `next`。无实体脚本的普通柜台/水槽允许走普通家具路径；有脚本但工厂或组件验证失败则拒绝生成。重试不会重复创建方格或对象。
官方无 payload 请求在服务端以 `nil` 到达，这是 `Generate` 的规范表示；同时兼容普通 Lua 空 table，或 B42 网络层的
`PZNetKahluaTableImpl` 且 `size()==0`。非空 payload 和其他类型一律拒绝。

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

当前清场事务先由服务端通过定向 `Relocate` 命令驱动客户端 `teleportTo` 到 staging，并同时以相同的 staging 坐标更新服务端玩家对象；anchor 与 staging 坐标均只来自服务端计划，客户端只用无坐标 token 回执。客户端不得在传送前调用 `getGridSquare` 拒绝远端目标。只有回执完成、至少跨过请求后与回执后的保护 tick、服务端玩家身份、权限、staging 位置/安全性及传送后的完整 101×101 方格预检再次通过后，才允许清场；加载等待期间不删除任何对象。`buildGeneration` 完成后，服务端才发送独立 `FinalRelocate` 命令，把玩家送到 `(20050.5,2050.5,0)`，客户端在该命令处理器内同步刷新 stale-room guard 后再本地 teleport，并在最终命令失败时走同一回滚路径；最终命令不产生初次 ack。pending 请求按 online ID+用户名绑定，重复请求拒绝；断线、死亡、身份变化、权限丢失、超时或不可恢复的位置/加载校验失败时在任何世界修改前取消。

旧动态房间删除还可能让旧 7x41 墙环、其包含的 6x40 室内或 6x40 屋顶 footprint 的方格保留一个指向
`RoomDef=nil` 的 `IsoRoom`；玩家稍后走过该格时，音频房间参数会触发异常。服务端在
`removeOldGeneration` 之前广播由 manifest/plan 生成的旧、新边界，并登记本地 guard；staging
让请求玩家在删除期间离开 footprint；删除后、最终入室前、提交前、提交后以及后续 tick 都检查完整旧/新
7x41 墙矩形（其包含 6x40 室内）与屋顶 footprint。唯一允许的
修正条件是 `square:getRoom() ~= nil` 且 `square:getRoomDef() == nil`，此时只调用
`square:setRoomID(-1)`；不得调用 `setRoom(nil)`、强制重建 region，或清除任何仍有有效
`RoomDef` 的新旧房间。IsoRegions 没有公开的 Lua 完成事件，因此 guard 使用最短生命周期、
连续稳定 tick 和硬超时，完成或超时后一定释放；请求失败也不会留下永久 guard。
