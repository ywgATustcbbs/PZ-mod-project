# client

结构：`RailroaderRV/` 客户端上下文菜单、请求入口与服务端定向撤离桥；世界菜单识别
先以官方 `instanceof(object, "IsoAnimal")` 门控 `getAnimalType`。

职责：发送无坐标、空参数的生成意图；接受初次 `Relocate` 后将服务端选定的 current-schema
managed scope 中心 `z=-15` staging 坐标应用到匹配本地玩家，并只回传无坐标 token；该阶段
以严格 `generationTransition=true`/`generationPhase=temporary` 标记显示本地语义常量“正在生成房车”；
B42 渲染器不稳定显示非 ASCII halo 文本，因此实际 `setHaloNote` 使用本地 ASCII
`"Generating RV"`，不读取或传输网络提示正文。
服务端 current-schema gate 失败时只发送稳定原因码 `SAVE_REBUILD_REQUIRED`；客户端仅匹配该
本地原因常量，并用 ASCII `setHaloNote("Delete this test save and rebuild it",...)` 明确提示删除该测试存档并重建。
网络原因正文不作为 UI 渲染，也不触发旧存档传送、迁移或兼容；其他失败仍保留原有诊断行为。
建造完成后接受独立 `FinalRelocate` 入室命令，在处理器内同步清理
`room!=nil && RoomDef==nil` 引用后，将服务端选定的 `(20050.5,2050.5,0)` 应用到本地玩家，
并仅在 guard、room scan 和实际坐标证明均通过后发送独立 token-only `FinalRelocateAck`；
最终命令不混入初次 pending relocation。`RV_BoundaryClient.lua` 只做服务端 bitmap 快照的
即时移动预测；缺快照、scope 外位置或预测失败时不施加世界级限制。客户端不提交可信世界
状态、不执行世界生成，服务端无状态哨兵/build audit/cleanup 始终是 authority。

拆墙后的第一阶段 roof-refresh 也复用同一 `Relocate`/`RelocateAck` 通道：客户端只接受
服务端携带的完整 `rvId:generation:bitmapVersion`、token 与坐标（Z 为服务端固定的
`ROOF_REPAIR_TEMP_Z=-15`），临时阶段显示本地 ASCII 头顶提示“Refreshing room”，然后执行
`teleportTo`，在当前方格更新后只回传 token。generation staging 的中文提示不从网络正文读取，
与 roof-refresh 提示严格区分。客户端
不提交临时目标、回程位置、加载状态或地板操作；服务端在 5/10/15 tick 修复后另发回程命令。
同 x/y 改 z 不会被客户端当作 chunk unload/reload；当前 roof-refresh 的远端点已按服务端
中心减 `(18000,0,15)` 设计为跨 chunk 卸载/重载路径，客户端只执行命令并回传 token。
屋顶视觉结果仍需实机联机观察，未有可靠 ACK 时不能宣称刷新完成。
