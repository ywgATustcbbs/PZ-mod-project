# Lua 目录

结构：`client/` 客户端菜单与意图请求；`server/` 服务端权威校验、区域预检、程序化生成、同步、事务回滚；`shared/` 共享常量与纯布局契约。

职责：仅 RV 模组 Lua 代码；不内置地图或复制外部资源；运行时依赖 BuildingCraft 与 Railroader，所有世界变更由服务端执行。
