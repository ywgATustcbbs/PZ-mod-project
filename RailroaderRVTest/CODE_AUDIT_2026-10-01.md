# RailroaderRVTest 代码精简静态审计报告

日期：2026-10-01。审查基准：`a83b639d92ade73982ab7c40f544a9b94fcf00f4`；开始审查时工作树干净。此报告记录本轮审查与修正后的静态结论，不等同于运行时或联机验收。

## 范围与方法

审查覆盖 `42/media/lua/` 下 59 个非水系统 Lua 文件，按共享模板与槽位、客户端 GUI、服务端 Core/Common、Construction/TemplateRecovery、BoundaryGuard/DemolitionProtection、RVMapping/RoomOwnership/WallReloadProtection/RoofRefresh、Power 七个独立事务分派给全新上下文的 `luna_worker`。另行分派了范围梳理、一键脚本诊断、项目文档对齐和最终跨模块复核。主 agent 核对了各事务的源码调用链、Git diff、修正 diff 和静态验证结果，再编写文档。

审查对照了代码精简及结构调整历史，包括 `021fb2f`、`2b47750`、`fdccd1c`、`89ae61b`、`796491e`、`ec78909`、`e1554cb`、`d37e012`、`767aed8`；`a83b639` 只更新代码分析报告。`RailroaderRVTest/docs/` 下的报告只作参考，未审计、未修订。水系统尚未完成，代码与行为均排除在审查外。

审查按以下契约判断：自生成的模板、ModData、mapping、utility record 与内部状态可信；理论上不可能的内部状态应暴露错误；PZ 已提供可靠有序传输，不增加丢包、乱序、重复包协议；服务端以当前世界状态为权威，仅后续步骤依赖客户端异步动作时使用 ACK/timeout。

## 已确认并修正的功能问题

| 问题与证据 | 影响 | 本轮修正 |
| --- | --- | --- |
| `Core/RV_Server_Core.lua` 的 `onCommand("*")` 被精确字符串比较挡住；`Core/RV_Server_Commands.lua` 使用该注册。此缺陷早于本轮主要精简提交。 | 通用 Generate、Utility 与搬迁 ACK 入口无法收到命令。 | `"*"` 接收任意命令名，具名处理器仍精确匹配。 |
| 生成阶段机对未知内部阶段静默等待超时。现有阶段写入点只使用 `WAIT_STAGING`、`BUILD`、`WAIT_FINAL`，成功后同步释放。 | 若代码错误产生不可能阶段，错误会被延迟掩盖。 | 在三个已知阶段分支后直接抛错，符合 fail-fast 约定。 |
| `89ae61b` 移除旧生成事务查询后，`RV.Server.isGenerationTransactionActive` 无生产者；Sentinel 与 WallReload 仍读取。 | 进出 Gate 不安装，墙重载拒绝启动，utility 的忙碌判断失准。 | 在 `Core/RV_Server.lua` 将现有 `GenerationTransaction.isActive` 发布到服务端门面。 |
| `RVMapping/RV_RailroaderServer_Mapping.lua` 将未定义的 `serverTransactionMutexStatus` 传给 BoundaryValidation；Mapping 装配早于 Sentinel。 | 边界验证调用 nil；预热报错或纠正路径得不到有效边界。 | 注入调用时读取共享 `ctx` 的闭包。 |
| `796491e` 后 `allocateRVRegion` 的第 4 返回值仍是 region，而 GenerationFlow 将它当 `priorGeneration`。 | 新槽位也被当成旧代，生成在修改世界前被拒。 | 统一返回 `(ok, slotIndex, anchor, priorGeneration?)`，新槽位第 4 值为空。 |
| `RegionSlots.indexToRegion` 只返回 XY，Mapping 与 WallReload 却传给要求 XYZ 的 `inRegion`。 | 映射区域反查失败，墙重载捕获不到成员。 | 从 slot 派生的记录区域补入 identity Z 范围，两个调用者共用同一函数。 |
| WallReload adapter 读取共享 `ctx.playerPositionInRegion`，Mapping 原先只把该函数传入 BoundaryValidation 子 context。 | 墙移事件命中成员捕获时调用 nil。 | Mapping 向共享 `ctx` 发布已有坐标函数。 |
| `767aed8` 后客户端 FinalRelocate 加载门要求整数 x/y，服务端目标是 `anchor+0.5`。 | 客户端不传送或发送最终 ACK；服务端等待超时并回滚。 | 客户端接受有限 x/y，只在查询 grid square 时取整；实际传送和位置证明保留半格目标。 |
| `d37e012` 后已跟踪玩家离开预热范围、缓存过期时不再强制刷新验证。 | 边界守卫无法持续取得边界并纠正越界。 | 已跟踪玩家每 60 tick 强制刷新；未恢复未跟踪范围外探测。 |
| `ec78909` 把电池 ID 改成数组长度加一，删除中间项后会重复。 | 按 ID 拆卸可能选错电池。 | 当前 utility record 使用持久递增 ID，客户端快照不暴露计数器；单一 schema 版本随持久字段变更同步提升。 |
| `e1554cb` 简化燃油路径后，扣除部分燃油或提交失败时补偿不足。 | 物品液量与虚拟账本可能不同步。 | 按操作前后实际液量补回并核对结果；未恢复额外 fail-closed 状态。 |
| 电力 `scanAll` 忽略逐格 `scanSquare=false`，此问题早于本轮精简；设备扫描还要求已从持久 mapping 中删除的 `record.anchor`。 | 全量扫描可能把部分结果报告成功；周期扫描无法得到内部坐标。 | 逐格失败向上传播；从可信 `slotIndex` 派生扫描锚点。 |

## 一键测试脚本

`testserver/run_test.py` 原先只记录本次使用默认 RAM disk 的 cache 角色。跨次运行改变 `--server-cache` / `--client-cache` 覆盖组合时，新使用默认路径的角色在布局标记中不存在，脚本会误报路径不一致而退出。修正后，已登记角色仍检查原路径与目录；未登记角色沿用现有安全初始化流程，成功后合并入同一布局标记。失败时保留 `initializing` 状态供诊断，不覆盖已登记缓存。该问题在脚本初始提交 `6a30feb3` 中已存在。

## 未修的静态观察

- `RV_TemplateGeometry.contains` 和若干布局中间字段在当前非水系统树内没有调用者；未发现它们影响现有功能，本轮未为了继续压缩而删除。
- 静态审查不能确认屋顶临时地板移除、原版液体与库存 API 的实际副作用，以及联机事件时序；这些属于后续整体运行时验收范围。

## 文档修订与保留事项

- `README.md` 更新槽位派生、恢复预算、模板许可、屋顶与墙重载分工、电池 ID、模块目录及本轮验证状态；明确水系统尚未完成。
- `REFACTOR_DESIGN.md` 改为当前实现说明，去除已不存在的位图、ProtectionManifest、顶层转发文件和旧 schema fail-closed 叙述。
- 客户端 `agent.md` 更新 FinalRelocate 与边界纠正流程。服务端 `agent.md`、`testserver/agent.md` 未发现需改的事实描述。
- `RailroaderRVTest/docs/` 是现有代码分析报告，本轮未审计或修订。它们在本轮源码修正之前生成；涉及上述已修接口的描述应视为当时的静态快照，不能把它们当成本轮修正后的运行时证据。

## 验证与限制

各审查事务执行了定向 `rg` 调用点检索、`git show`/`git blame` 历史对照、逐文件源码检查；修正后复核了相关 diff 与跨模块返回值、数据形状和装配顺序。`git diff --check` 通过；`luaparser` 成功解析本轮修改的 11 个 Lua 文件，一键脚本通过 Python AST 解析，均未执行入口。**全程没有运行 `python testserver/run_test.py`、游戏服务端、客户端或任何实际运行时测试。**

静态结论说明上述确定性源码断链已修正；方格流送、事件顺序、原版物品/液体 API 行为与联机回滚仍需后续整体运行时验收。本轮不为尚无证据的边界情况扩展功能或网络协议。
