# client

结构：`RailroaderRV/` 客户端上下文菜单、请求入口与服务端定向撤离桥；世界菜单识别
先以官方 `instanceof(object, "IsoAnimal")` 门控 `getAnimalType`。

职责：发送无坐标、空参数的生成意图；接受初次 `Relocate` 后将服务端选定且位于旧/新
结构 footprint 外的 staging 坐标应用到匹配本地玩家，并只回传无坐标 token。建造完成后
接受独立 `FinalRelocate` 入室命令，在处理器内同步清理 `room!=nil && RoomDef==nil`
引用后，将服务端选定的 `(20050.5,2050.5,0)` 应用到本地玩家，不发送 ack，也不把
最终命令混入初次 pending relocation。`RV_BoundaryClient.lua` 只做服务端 bitmap 快照的
即时移动预测；缺快照、scope 外位置或预测失败时不施加世界级限制。客户端不提交可信世界
状态、不执行世界生成，服务端 recovery/build audit/cleanup 始终是 authority。

拆墙后的第一阶段 roof-refresh 也复用同一 `Relocate`/`RelocateAck` 通道：客户端只接受
服务端携带的完整 `rvId:generation:bitmapVersion`、token 与坐标（Z 为服务端固定的
`ROOF_REPAIR_TEMP_Z=-15`），临时阶段显示服务端提供的
中文头顶提示“正在刷新房间”，然后执行 `teleportTo`，在当前方格更新后只回传 token。客户端
不提交临时目标、回程位置、加载状态或地板操作；服务端在 5/10/15 tick 修复后另发回程命令。
同 x/y 改 z 不会被客户端当作 chunk unload/reload；跨 chunk 方案留待第一阶段运行时失败后
单独实验。
