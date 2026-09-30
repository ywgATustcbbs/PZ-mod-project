# Railroader RV 当前设计说明

本文记录当前 RailroaderRVTest 的代码边界与协作契约。具体实现以 `contents/mods/RailroaderRVTest/42/media/lua/` 下的源码为准；`docs/` 中的模块分析报告只作参考。

## 运行域与数据约定

- `shared/RailroaderRV/Common/`、`RoomTemplate/`、`RVMapping/` 和 `Power/` 保存常量、模板、几何、槽位及电力配置；`client/RailroaderRV/GUI/` 负责菜单、表现和意图请求；世界、物品、映射及事务变更由 `server/RailroaderRV/` 执行。
- 模组自己生成的模板、ModData、mapping、utility record 和内部状态按当前 schema 使用。内部不可能状态直接暴露错误，不为旧存档或人工改档做兼容、迁移或恢复。
- Lua 只声明一个包级 schema 版本并写入 ModData。服务端启动时集中比较；缺失或不一致只报警，操作继续。模块之间按既定接口协作。
- 客户端只提交操作意图或异步动作完成 ACK。服务端从当前世界与玩家对象取得身份、权限、位置、区域和阶段，再执行变更。PZ 传输已有可靠有序语义；不建立丢包、乱序或重复包协议。

## 目录与装配

| 目录 | 当前职责 |
| --- | --- |
| `shared/RailroaderRV/RoomTemplate/` | 捕获模板、布局、活动 AABB、建造格与刷新目标 |
| `shared/RailroaderRV/RVMapping/` | 100×100 槽位矩阵及槽位到锚点、XY 区域的纯函数 |
| `client/RailroaderRV/GUI/` | 进入/退出菜单、搬迁 ACK、边界纠正、房间所有权表现与供电面板 |
| `server/RailroaderRV/Core/`、`Common/` | 服务端装配、命令分发、事务门、共享世界与调用工具 |
| `server/RailroaderRV/Construction/` | 生成阶段、世界对象创建、服务端玩家验证、ACK 与回滚 |
| `server/RailroaderRV/RVMapping/` | 机车与玩家映射、槽位分配、进入/退出及当前记录验证 |
| `server/RailroaderRV/BoundaryGuard/`、`DemolitionProtection/` | 当前边界判断、越界纠正与对象/建造保护 |
| `server/RailroaderRV/TemplateRecovery/`、`RoomOwnership/` | 模板保护修复队列与房间所有权监视 |
| `server/RailroaderRV/RoofRefresh/`、`WallReloadProtection/` | 屋顶元数据刷新与外墙移除后的独立玩家往返流程 |
| `server/RailroaderRV/Power/`、`Core/RV_UtilityStore.lua` | 虚拟供电、设备扫描与持久 utility 记录 |

这些目录下的模块是当前入口和实现位置；客户端及服务端 `RailroaderRV` 根目录没有迁移用的顶层 Lua 转发文件。水系统尚未完成，本次审计不评价其实现。

## 模板、槽位和生成

捕获模板是有序对象清单，当前共有 412 个对象。`RV_TemplateGeometry.lua` 使用 `walkAabbs` 判活动范围、`buildCells` 判可建造格；没有运行中的 `RV_Bitmap.lua` 或独立 ProtectionManifest。布局从模板和服务端锚点派生对象坐标、管理范围、壳边与屋顶刷新点。

槽位按 5 行×20 列排列，每格为半开 100×100 XY 区域。Mapping 的持久记录保存 `slotIndex`、generation、机车/玩家关系及所需位置数据；锚点和区域按槽位重新计算。槽位几何只提供 XY；需要身份 Z 范围的服务端查询补入 `RV_IDENTITY_MIN_Z/MAX_Z`。全高身份匹配与模板实际受管层是不同范围，不把 `z=-32..31` 当作每次建造、清理和修复都要遍历的内容层。

服务端先验证请求玩家、权限、机车及当前状态，再分配空槽。生成事务先把玩家迁至服务端选择的 staging 点，等待客户端完成异步迁移；随后在服务端检查目标区域、清理可清理对象并按模板创建对象。任何世界修改失败由同一事务路径回滚本代生成的对象。已有映射没有完整旧世界 undo 快照，因此拒绝原槽重建。生成完成后，服务端选择锚点中心的半格坐标作为最终目标；客户端在目标 square 加载、传送并核对位置后发送最终 ACK，服务端才提交映射。客户端不提供可信世界坐标。

## 当前世界维护

- `BoundaryGuard` 从当前 Mapping、模板边界和服务端玩家位置判断身份及越界。已跟踪玩家的验证缓存定期刷新；纠正由服务端发起，客户端只应用纠正结果。
- `TemplateRecovery` 将附近坐标放入共享有界队列，按积压量使用每 tick 1、2 或 4 个 XY 坐标的预算。处理时重新查当前玩家和边界；没有匹配在线玩家的条目出队丢弃，不强制加载缺失 square。
- `RoomOwnership` 监视当前房间结构；客户端局部观察只触发显示和刷新请求，服务端以当前世界数据决定操作。
- `RoofRefresh` 在进入或重连路径上尝试刷新房间与屋顶元数据，可临时添加再移除未标记地板。外墙移除后的玩家远移、chunk 周期和返回由 `WallReloadProtection` 单独管理；只有客户端异步传送完成后的阶段才等待 token ACK。
- `DemolitionProtection` 按当前模板对象身份及壳边判断对象保护；客户端菜单判断只是交互表现，服务器负责最终决定。

## 虚拟供电

UtilityStore 以当前 RV identity 保存虚拟燃油、电池、组件及结算状态。电池使用持久递增 ID；物品、液体和设备对象均由服务端从当前玩家及世界状态重新解析。燃油已扣而提交失败时按实际液量差额补偿。设备完整扫描只有全部目标 square 扫描成功才报告成功；服务端快照供客户端面板展示，面板操作反馈不推进世界事务。

## 验证边界

源码与静态检查可以确认函数接线、返回值合同、语法及文件布局，不能证明联机时的方格加载、原版物品 API、副作用回滚或事件时序。本轮审计只做静态验证；实际运行时测试须从项目根目录运行唯一入口 `python testserver/run_test.py`，并按整体服务器与客户端流程验收。本轮没有启动该入口。
