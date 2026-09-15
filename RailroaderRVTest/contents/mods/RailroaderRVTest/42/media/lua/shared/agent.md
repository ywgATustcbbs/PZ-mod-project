# shared

结构：`RailroaderRV/` 共享常量与纯坐标布局规划；`Translate/` 文本资源。

职责：提供客户端/服务端一致的常量、固定传送目标和布局数据；不访问世界、不执行生成。
布局入口是当前代码声明的纯 `Layout.make`，不从玩家对象推导 geometry，也不保留未使用的遍历/清场 helper。
首次 generation staging 的中心坐标与 `z=-15` 语义、roof-refresh 的远点向量必须由服务端按
当前 layout/bitmap 契约解释，客户端只接收严格阶段标记。临时传送事务只由服务端进程内存
保存，shared 层不声明或兼容任何中间传送存档记录。
