# server

结构：`RailroaderRV/` 服务端命令入口与生成事务。

职责：权威校验、固定生成 anchor 与 staging 分离传送；传送前仅用 `isValidSquare` 预检固定目标及严格
101×101 闭区间坐标，并优先选择清场矩形正上方的居中、半径 51 staging 格
`(anchorX, clearMinY-1)`（保存旧 bounds 与新 bounds 均排除），再用有界搜索兜底；
传送后等待并复核 staging 安全性与完整 base footprint、破坏性清理、程序化建造、
同步、失败回滚；不得在传送前要求远端方格存在，也不得创建未预检地图格。请求玩家在
清场/重建期间留在 staging，不进入任何结构 footprint。清场成功后
才进入完整房间/对象生成；生成成功后、提交 `READY` 前，服务端通过独立
`FinalRelocate` 命令并同步服务端玩家对象，把请求玩家送到 `(20050.5,2050.5,0)`；
该命令不走初次 `RelocateAck`。B42 服务端按 64×64 cell 和 online chunk-grid width
加载相关区域；不完整 footprint 只返回可重试状态，硬超时在任何清场前取消，禁止以部分加载范围继续。
清场、建造或最终传送任一阶段失败都必须沿现有 generation 回滚路径收敛。
