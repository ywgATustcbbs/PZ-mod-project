# shared/RailroaderRV

结构：`RV_Constants.lua` 定义版本、尺寸、贴图与初始状态；`RV_Layout.lua` 纯函数生成坐标契约。

职责：布局必须显式返回固定目标 `(20050,2050,0)` 周围闭区间
`x=20000..20100`、`y=2000..2100` 的 101×101 清场、6×40 净室内、7×41
墙环、6×40 z+1 屋顶及功能点；缺失契约由服务端拒绝。清场后启用完整
`buildGeneration`，但不再铺整片金属地板，仅在室内生成精确
`floors_interior_carpet_01_5` 地板。直墙使用 `walls_interior_house_03_20`
及其 WallN 配对 sprite `..._21`，NW/SE 单角条分别为 `..._22`/`..._23`。
`COMMAND_REFRESH_ROOM_OWNERSHIP` 固定声明服务端向所有客户端广播 stale-room guard 的共享命令名；边界内容仍只能由服务端 manifest 与布局产生。
