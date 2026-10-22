# RailroaderRV 当前模块索引

本页是模块职责与主要加载入口的导航，不是逐函数审计。源码行为以 RailroaderRV/contents/mods/RailroaderRV/42/ 当前实现为准；静态检查不能代替游戏和联机运行结果。设计和验收约束见[项目 README](../../README.md)。

## 客户端

| 模块入口 | 职责 |
|---|---|
| [GUI/RV_ContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua) | 通用上下文菜单、生成请求、异步 relocation 接线及可选模板开发菜单。 |
| [GUI/RV_RailroaderContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua) | 注册 Railroader 机车/车头菜单入口；客户端只发送操作意图。 |
| [GUI/RV_UtilityContextMenu.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityContextMenu.lua) 与 [GUI/RV_UtilityDashboard.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_UtilityDashboard.lua) | 水电交互菜单、管理面板与服务端状态展示。 |
| [GUI/RV_FlatcarVisualClient.lua](../../contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_FlatcarVisualClient.lua) | 平车和载车的客户端视觉实体、加载清理及装卸意图。 |
| GUI 内其他文件 | 房车边界表现、拆除反馈、屋顶设备窗口、局部搬运/所有权交互、衣柜外观和配方输入预览。 |

## 服务端

| 模块 | 职责与主要入口 |
|---|---|
| [Core/RV_Server.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server.lua)、[Core/RV_Server_Core.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Core.lua)、[Core/RV_Server_Commands.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua) | 服务端装配、Railroader adapter、事件/命令路由和服务端 tick。 |
| Common/ | 服务端 schema 初始化、ModData 持久化、世界访问与共用业务原语。 |
| Construction/ | 玩家/目标验证、管理区域加载、生成清理与构建、异步阶段推进和 mapping 提交。 |
| RVMapping/ | 每个 Railroader unit 的稳定 mapping、当前世界查询以及房车进入/退出。 |
| BoundaryGuard/ | 服务端权威房车边界与玩家转移状态。 |
| DemolitionProtection/ | 房车外壳墙对象归属和拆除保护。 |
| TemplateRecovery/ | 当前模板受保护对象的修复。 |
| RoomOwnership/ | 房间归属检查与服务端房间所有权规则。 |
| RoofRefresh/ | 房间和屋顶元数据刷新。 |
| WallReloadProtection/ | 外墙移除后的独立异步远移、chunk 刷新和成员返回流程。 |
| Roof/、Power/、Water/ | 屋顶虚拟设备、水务和电力服务及其持久状态。 |
| Safehouse/ | 房车对应原生安全屋的认领与释放。 |
| VehicleTransport/、CarVisual/ | 车辆装卸状态快照、平车清单、服务端请求和视觉数据广播。详见[车辆运输说明](vehicle-transport-implementation.md)。 |
| TemplateDevelopment/、Items/ | 受限模板开发命令和物品/战利品分布。 |

## 共享定义

| 模块 | 职责 |
|---|---|
| Common/ | 唯一 Lua schema 常量、共享常量、严格定义与通用 utility 参数。 |
| RoomTemplate/ | 捕获模板、模板注册、布局计划与模板几何。 |
| RVMapping/ | 共享槽位、区域锚点和 Railroader unit 公开视图适配。 |
| Roof/、Power/、Water/ | 屋顶设备定义、电力物品/参数和水务 catalog。 |
| Cargo/ | 平车车型、容量与货物 catalog。 |

## 当前审计边界

- ModData schema 在 Lua 中集中声明并启动时比较一次；版本不一致或缺失只报警。旧档迁移、结构回退和重复接口校验不属于当前实现契约。
- 模组生成的模板、mapping、utility record 和进程内状态按可信数据使用；服务端根据当前世界权威验证客户端意图。
- 网络依赖游戏提供的可靠有序传输；ACK 只用于服务器后续依赖客户端完成的异步步骤。
- GenerationTransaction 只保存进程内记录，没有持久回滚账本。生成失败中止（包括 WAIT_FINAL 截止时间超时）不撤销已产生的世界对象变更；下一次没有 mapping 的请求会先完整清理管理区再生成。这与根目录 agents.md 的失败回滚要求不一致，是尚未解决的契约差异；该结论来自静态源码审阅，未作运行时复现或修复。
- 车辆装卸的条件性撤销边界另见[车辆运输说明](vehicle-transport-implementation.md)；native exception 是否会触发尚无运行时证据。
- 源码和离线行为检查不构成游戏内验收。整体运行时验证只能从项目根目录使用 python testserver/run_test.py 启动可见服务器控制台和常规客户端；不做预检、不拆开客户端和服务器。
