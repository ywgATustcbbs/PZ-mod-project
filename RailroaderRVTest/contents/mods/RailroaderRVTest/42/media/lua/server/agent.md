# server

结构：`RailroaderRV/` 服务端命令入口与生成事务；`RV_Server.lua` 前置声明后文的当前
manifest gate，使 generation 清理调用到当前 schema 校验而非未定义全局。

职责：权威校验、固定生成 anchor 与 staging 分离传送；传送前仅用 `isValidSquare` 预检固定目标及严格
100×100 半开区间坐标，并优先选择清场矩形正上方的居中 staging 格
`(anchorX, clearMinY-1)`（保存旧 bounds 与新 bounds 均排除），再用有界搜索兜底；
传送后等待并复核 staging 安全性与完整 base footprint、破坏性清理、程序化建造、
同步、失败回滚；不得在传送前要求远端方格存在，也不得创建未预检地图格。请求玩家在
清场/重建期间留在 staging，不进入任何结构 footprint。清场成功后
才进入完整房间/对象生成；生成成功后、提交 `READY` 前，服务端通过独立
`FinalRelocate` 命令并同步服务端玩家对象，把请求玩家送到 `(20050.5,2050.5,0)`；
该命令不走初次 `RelocateAck`。B42 服务端按 64×64 cell 和 online chunk-grid width
加载相关区域；不完整 footprint 只返回可重试状态，硬超时在任何清场前取消，禁止以部分加载范围继续。RV 边界
服务仅接受当前玩家映射的 `rvId/generation`，在该 RV 的 100×100×Z scope 内使用 bitmap；scope 外
对玩家和对象均 no-op。客户端只做预测，服务端执行 recovery、建造审计和周期清理。
清场、建造或最终传送任一阶段失败都必须沿现有 generation 回滚路径收敛。
进出或 generation 切换先向对应客户端发送匹配当前上一代 key 的 `RVBitmapClear`，再重置 runtime
snapshot/latch；它只撤销客户端预测缓存，不改变持久化 RV↔玩家关系。
bitmap snapshot、dirty action、cleanup cursor、correction、对象标签和持久化
shell edge ledger 均携带 `rvId/generation/bitmapVersion`；对象位于登记的 shell host
但 edge ownership 无法证明时一律 fail-open，不按 inactive cell 直接删除。
异步 stale-room guard 与 roof-repair cache 也以完整
`rvId:generation:bitmapVersion` 作为索引，避免不同 RV 或 bitmap 代际互相覆盖。
服务端拆除链以当前 42.20.4 的 `SledgehammerDestroyPacket` →
`RemoveItemFromSquarePacket` → `OnObjectAboutToBeRemoved` 为权威入口；该事件在原版对象仍
附着时识别当前生成的 `IsoThumpable` 外墙，对象必须带有与 shell ledger 完全匹配的当前 tag
和 object index。`OnDestroyIsoThumpable` 仅作为直接 thumpable 销毁路径的同一严格匹配补充
入口；两条事件按完整房间 key 去重。对象事件未暴露时，现有 30-tick map/presence 流程读取
authoritative player square 的 `isInARoom()`，以 `getRoom()/getRoomDef()` 作支持状态，只在
当前 RV scope 内检测到 inside→outside transition 时安排修复。

拆墙后由 `RV_Server` 与 Railroader 适配器共同维护有界 roof-refresh 状态机：
`queued` → `temporary` → `repairing` → `returning` → `complete`。服务端复用
`Relocate`/严格 token-only `RelocateAck`，从当前 boundary bitmap 的 100×100 managed scope
派生中心与固定实验层 `ROOF_REPAIR_TEMP_Z=-15`，验证临时方格已脱离 room geometry、repair
目标及墙/屋顶相关方格已加载，然后在到达后的 5/10/15 server ticks
（约 0.5/1.0/1.5 秒、运行时约 10 Hz）调用一次现有地板 add/remove 修复。临时阶段向客户端
发送仅展示用的“正在刷新房间”头顶提示；客户端只执行服务端命令和 token ACK，不提交坐标或
世界状态。完成后在完整 `rvId/generation/bitmapVersion`、权威 relation、玩家状态仍匹配时
返回拆墙前服务端捕获的合法 RV 位置并释放 boundary correction lease。断线、死亡、
schema/identity 变化、加载超时或 ACK/阶段不匹配安全取消并尝试回滚，不修改存档；服务端
日志只表示权威 add/remove 已应用，不表示客户端视觉已成功。

当前只实现同 scope 第一阶段；同 x/y 改 z 不等于客户端 chunk unload/reload。若运行时仍
无法刷新屋顶，下一轮才按实际 client chunk-grid streaming 半径开展跨 chunk 卸载/重载实验，
没有可靠 ACK 时不得伪造完成。每次尝试都重验 current map/record/relation/identity 与
authoritative inside player；无人、scope 外或不兼容 schema 均取消，不使用坐标猜测或永久
0.5 秒无条件刷新。匹配、调度、加载、回滚阶段均有受控日志。
进入已有 RV 与重连驻留由同一 current-only monitor 入口处理：服务端先校验
mapping record 与 current manifest/boundary identity，再以 manifest 的当前 bounds
向对应客户端定向发送 `RefreshRoomOwnership`；schema 或 identity 不完整时返回
`SAVE_REBUILD_REQUIRED`，不执行该路径的传送。

开发期存档只接受当前 manifest、bitmap、shell ledger、mapping 和异步身份 schema。
缺失或不匹配时服务端必须拒绝操作并提示删除测试存档后重建；不得迁移、转换、使用
旧 bounds、清理对象、传送玩家或运行 boundary guard。空的新容器才可按当前 schema 初始化。
