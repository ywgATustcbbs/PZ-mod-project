# shared/RailroaderRV

结构：`RV_Constants.lua` 定义版本、尺寸、贴图与初始状态；`RV_Layout.lua` 仅通过纯函数 `Layout.make` 生成坐标契约；`RV_Bitmap.lua` 提供共享的 packed bitmap、cell、segment 和序列化操作；`RV_UtilityConstants.lua` 声明水电 current schema、操作与稳定 reason code；`RV_UtilityCatalog.lua` 声明 FluidContainer 能力和仅允许干净/污染水组成的 profile。

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
roof-refresh 的远端传送点必须由当前 boundary bitmap/manifest 的
`originX + floor(width/2)`、`originY + floor(height/2)`、`minZ` 派生，再动态减去当前刷新
向量 `(18000,0,15)`；不得使用绝对远端坐标、旧 bounds 或客户端坐标。该派生点用于跨
chunk unload/reload；所有 RV scope 内玩家必须逐人记录并最终
回传，回传后复用既有 repair/geometry 路径。
`COMMAND_REFRESH_ROOM_OWNERSHIP` 固定声明服务端向所有客户端广播 stale-room guard 的共享命令名；边界内容仍只能由服务端 manifest 与布局产生。

共享常量还声明首次 generation 的 `z=-15` staging 与 roof-refresh 的中心远点向量；这些
常量只用于当前 layout/bitmap 的服务端计算。generation/roof 临时传送的 token、稳定异步
identity、精确原坐标和阶段只保存在服务进程内存，客户端不解释或提交坐标，也不提供中间
传送记录的 schema、字段 alias 或 migration。

schema 只支持当前版本：manifest、bitmap、shell ledger、RV mapping 和异步身份的
缺失/不匹配必须 fail-closed，由服务端提示删除测试存档并重建。共享模块 MUST NOT
提供旧字段别名、旧 bounds/bitmap fallback 或新旧数据转换；空的新容器才可初始化为当前 schema。

水电共享契约同样 current-only。设备目录条目在整体联机验证前保持
`runtimeValidated=false`，不能由客户端或服务端猜测性启用；`fluidProfile` 只表示空、干净水、污染的水或两者原生混合，不能包含其他液体。
混合 profile 只在可读的 per-fluid amount 与总量闭合时接受；无法证明组成则拒绝。客户端的
`REQUEST_SNAPSHOT` 只是只读快照意图，不改变 current schema 或任何世界状态。
