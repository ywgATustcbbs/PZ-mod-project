# shared/RailroaderRV

结构：`RV_Constants.lua` 定义版本、尺寸、贴图与初始状态；`RV_Layout.lua` 纯函数生成坐标契约；`RV_Bitmap.lua` 提供共享的 packed bitmap、cell、segment 和序列化操作。

职责：布局必须显式返回固定目标 `(20050,2050,0)` 周围半开区间
`x=[20000,20100)`、`y=[2000,2100)` 的 100×100×Z 管理 scope；每层 bitmap
是 active/buildable 的最终几何依据，AABB 仅供粗筛和遍历。当前布局另返回 6×40
净室内、7×41 墙环、6×40 z+1 屋顶及功能点；缺失契约由服务端拒绝。清场后启用
完整 `buildGeneration`，但不再铺整片金属地板，仅在室内生成精确
`floors_interior_carpet_01_5` 地板。直墙使用 `walls_interior_house_03_20`
及其 WallN 配对 sprite `..._21`，NW/SE 单角条分别为 `..._22`/`..._23`。
墙体的 canonical shell edge 只登记 N/W；east/south 对象由其相邻 tile 的 W/N
edgeKey 表示，不能按 inactive anchor cell 删除。
bitmap 快照和 shell edge ledger 的持久化 identity 均要求正整数
`bitmapVersion`，与 `rvId/generation` 一起参与边界缓存、对象标签和 stale
数据拒绝；不完整 identity 不得被当作当前 RV 的几何证据。
roof-refresh 的临时传送点 XY 必须由当前 boundary bitmap/manifest 的
`originX + floor(width/2)`、`originY + floor(height/2)` 派生；Z 使用服务端固定实验常量
`ROOF_REPAIR_TEMP_Z=-15`，不读取建筑 `minZ`、旧 bounds 或客户端坐标。该同 scope、同 x/y
的外移不宣称会触发
客户端 chunk unload/reload；若第一阶段运行时失败，跨 chunk 方案另行设计。
`COMMAND_REFRESH_ROOM_OWNERSHIP` 固定声明服务端向所有客户端广播 stale-room guard 的共享命令名；边界内容仍只能由服务端 manifest 与布局产生。

schema 只支持当前版本：manifest、bitmap、shell ledger、RV mapping 和异步身份的
缺失/不匹配必须 fail-closed，由服务端提示删除测试存档并重建。共享模块 MUST NOT
提供旧字段别名、旧 bounds/bitmap fallback 或新旧数据转换；空的新容器才可初始化为当前 schema。
