# Railroader RV 当前移交报告

更新时间：2026-09-15。当前技术版本为 `0.2.0-tech`，与 `mod.info` 及 manifest 的
`techVersion` 一致。本文只描述当前工作树中的 RailroaderRVTest 实现；历史运行日志、旧存档
和旧方案不构成当前契约。

## 当前结论

RailroaderRVTest 当前唯一面向官方 Railroader 2.1 与 Project Zomboid Build 42。模组不内置地图，客户端只提交无坐标操作意图，服务端负责当前 schema 校验、加载、清场、生成、同步、回滚和玩家位置证明。代码只依赖官方适配接口，不加载独立的旧适配层。

首次生成固定使用 anchor `(20050,2050,0)`。当前管理 scope 是半开区间 `x=[20000,20100)`、`y=[2000,2100)` 的 100×100 范围；首次 staging 由当前 manifest/bitmap 的管理中心计算，Z 固定为 `-15`。加载等待期间不修改世界；只有完整 base footprint 已加载并复核后才清场和生成。建造完成后，服务端独立执行 `FinalRelocate`，将玩家送到 `(20050.5,2050.5,0)`，客户端只在 guard、room scan 和实际位置证明通过后回传 token-only ACK。

当前布局为 6×40 室内、7×41 墙环和 z+1 的 6×40 屋顶。墙环有 92 个唯一坐标：直墙为 11 个 north、79 个 west，NW/SE 各一个角条；加上角条后方向条目总数为 12 north-oriented、80 west-oriented。屋顶和墙体均由当前 layout/bitmap 契约生成，不能从客户端坐标推导。

## 当前 schema 门

开发期只接受当前代码声明的 manifest、bitmap、shell ledger、RV mapping 和异步身份 schema。缺失、过期、部分写入、字段别名、旧 bounds、旧 bitmap、旧 mapping、旧 generation 或旧 manifest 必须立即返回 `SAVE_REBUILD_REQUIRED`，提示用户删除测试存档并重建。

代码不得迁移、转换、推断、兼容旧字段，不得使用旧数据生成 geometry、删除对象、传送玩家或运行 boundary guard，也不得自动修改旧存档。只有完全空的新容器可以按当前 schema 初始化；临时 relocation/repair 状态只保存在当前服务进程内存。服务端进程重启后不恢复中间传送、repair、phase、原坐标或 READY。

## 边界与房顶刷新

墙体拆除主入口是当前 B42 链路上的 `OnObjectAboutToBeRemoved`；`OnDestroyIsoThumpable` 只作相同严格匹配的补充入口。对象必须属于当前 `rvId:generation:bitmapVersion`、匹配 shell ledger 和 object index；不确定归属时 fail-open。事件未暴露时，30-tick map/presence 流程只在当前 scope 内观察到 authoritative inside→outside transition 才排队修复，不把普通玩家移动当作拆墙事件。

roof-refresh 状态机为 `queued → temporary → repairing → returning → complete`。事务逐人记录服务端坐标和稳定 identity，持有 Boundary correction lease，把全部成员送到当前 bitmap 中心减去 `(18000,0,15)` 的远端点，跨 tick 复核到达后执行有限的 5/10/15 tick 地板 add/remove 修复，再逐人回传原合法 RV 位置。客户端只显示“正在刷新房间”、执行服务端命令并回传 token；服务端日志只代表权威世界变更，不代表客户端视觉已成功。任何 schema、identity、加载、阶段或 ACK 失败都必须安全取消或持续保留当前进程内存中的回传上下文，不能用 repair 成功掩盖回传失败。

## 清场与建造审计边界

生成清场是破坏性操作，只在当前 scope、当前加载方格和当前 schema 通过后执行。生成失败沿本代事务回滚；对象标签、bitmap、shell edge ledger 和 correction 均携带完整 identity。当前建造审计只删除服务端能够证明属于当前 RV 且完整 footprint 落在 scope 内、同时落在 inactive/buildBits 外的对象；shell ledger 不能证明归属、对象标签来自其他 RV/generation 或对象事件含义不明确时保持 fail-open。该实现不宣称能清除所有第三方/未来模组对象，也不提供门或长期房间系统。

## 当前目录职责

- `media/lua/client/` 只负责菜单、客户端表现、room guard 和意图/ACK；不提交可信坐标或世界状态。
- `media/lua/server/` 负责权威事件入口、schema gate、加载、生成、对象同步、建造审计、边界 guard、roof-refresh 和回滚。
- `media/lua/shared/` 只提供当前常量、`Layout.make`、bitmap 和翻译；不访问世界，不从玩家对象推导布局。
- `tests/` 提供静态契约、Lua 语法和文档一致性检查；只读来源 `official lua scripts/`、`reference mods/`、`game-decompiled/` 与 `modinfos.json` 不属于本模组实现。

## 验证与运行时交接

本轮静态验证命令：

```text
python RailroaderRVTest/tests/test_rv_server.py
git diff --check
```

最终仍需由负责人从项目根目录直接运行仓库定义的一键整体测试脚本 `python testserver/run_test.py`，不得拆分客户端/服务器测试，不得预先做环境检测，且服务器控制台必须对用户可见。脚本若启动客户端，应由用户完成连接 `127.0.0.1:16261`、进入菜单、生成/进入 RV、拆墙以及观察“正在刷新房间”、远端 relocation、回传和房顶视觉结果等操作；未收到人工观察结果前不能宣称运行时验收完成。运行日志、存档、转储和密钥不得提交。
