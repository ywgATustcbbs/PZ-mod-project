# Railroader RV 当前移交报告

更新时间：2026-09-13。此报告对应本轮代码归档；本轮不再启动游戏运行时测试。

## 当前结论

RV 的当前 schema 门、边界 identity、已有房车进入/重连保护、拆墙事件识别以及房顶修复事务的设计与静态契约已经落盘，但房顶修复事务目前被一个新的服务端 Lua 运行时错误阻断，不能宣称修复成功。

下一名 agent 必须先修复 `RV_Server.lua:3189` 的 `currentRoofRepairContext` 中 `Object tried to call nil`，再按仓库一键测试流程验证。静态阅读同时看到该函数调用了未在 `RV_Server.lua` 声明的 `integer` helper；这与运行时 nil 位置相符，应由下一名 agent 负责最小修复并复测。不得在本报告对应的状态上直接实现跨区块方案或扩大为永久轮询。

## 强制的 current-only 存档策略

开发期只接受当前代码声明的 manifest、bitmap、shell ledger、RV mapping 和异步 identity schema。

任何缺失、过期、部分写入、字段别名、旧 bounds、旧 bitmap、旧 mapping、旧 generation 或旧 manifest 都必须立即拒绝相关 RV 操作，并返回稳定错误码 `SAVE_REBUILD_REQUIRED`，明确通知用户删除测试存档并重新生成。代码不得迁移、转换、读取旧字段别名、推断旧 geometry/bounds、用旧数据遍历或删除对象、恢复玩家、生成 bitmap、运行 boundary guard，也不得自动清除或修改旧存档。只有空的新容器可以按当前 schema 初始化。

当前测试存档来自旧数据结构时，必须由用户手工删除并重新建立；代码不会自动处理旧存档。未来若要支持迁移，必须由用户重新明确授权。

## 已完成与静态验证

- 完成当前-only manifest、bitmap、boundary/shell ledger、mapping 和异步 identity 的严格校验，删除旧 fallback、alias、转换和旧 geometry 路径。
- 保留并加强 stale-room guard：只对 `room ~= nil` 且 `RoomDef == nil` 的失效引用调用 `setRoomID(-1)`；已有 RV entry、presence/reconnect 和 generation 路径均有定向 guard，历史房间引用导致的客户端房间音频异常已不再复现为客户端崩溃。
- 拆墙入口按当前 42.20.4 链路接入 `OnObjectAboutToBeRemoved`，`OnDestroyIsoThumpable` 仅作同一严格匹配的补充入口；二者按完整 `rvId:generation:bitmapVersion` 去抖。若对象事件没有暴露，则由权威玩家 `isInARoom()` 的 inside→outside transition 作为补充触发。
- 房顶刷新设计为有限状态机 `queued → temporary → repairing → returning → complete`，拆墙或 room transition 后延迟三次尝试，目标为到达后 5/10/15 个服务端 tick；每次都重新校验当前 schema、identity、关系、在线身份、scope 和权威玩家状态。
- 当前第一阶段临时传送点设计为当前 boundary bitmap 所声明的 100×100 managed scope 中心：`originX + floor(width / 2)`、`originY + floor(height / 2)`，Z 固定实验值 `-15`。这里的 Z 不是房车实际 bitmap/building bounds 的 `minZ`，也不读取游戏源码推导。客户端阶段提示应为“正在刷新房间”，修复后回送事件前捕获的合法 RV 位置。
- 当前设计不把同一 XY 改 Z 宣称为区块卸载/重载；只有第一阶段运行时验证仍失败，后续 agent 才能另行设计跨 chunk 的最低层实验。
- 现有静态测试覆盖 schema 拒绝、完整 identity、边界与 shell ledger、stale-room guard、拆墙事件入口、延迟调度、临时传送点和 token-only 回执等契约。

## 已运行验证

此前运行中，拆除外墙曾通过 `IsoRoom:getRoomDef() == nil` 触发客户端 `ParameterFirearmRoomSize.getRoomSize` 空引用并闪退到主界面；加入连续 stale-room monitor、已有 RV entry/presence 定向 arm 后，后续一键联机运行未再出现该客户端 NPE，客户端与服务器均能正常退出。该历史 crash 修复只代表崩溃链已止住，不代表房顶视觉刷新已成功。

本报告对应的最新运行文件为：

- `testserver/runtime/server/Logs/2026-09-13_20-14_DebugLog-server.txt`
- `testserver/runtime/client/Logs/2026-09-13_20-15_DebugLog.txt`

该运行中服务端日志确认：

- room transition 在 `20:18:51` 命中并排队；
- object-about-to-be-removed 在 `20:19:22` 命中并排队；
- 两条路径随后都在调用修复事务前报 `RV_Server.lua:3189 currentRoofRepairContext` 的 `Object tried to call nil`，并记录 `roof repair schedule cancelled`。

因此本次运行没有出现“正在刷新房间”、临时传送、5/10/15 tick 修复或回送；房顶仍未隐藏。没有新的客户端闪退，连接日志显示随后正常退出，服务端也通过控制台 `quit` 正常关闭。

运行中还留有与拆墙/建造链相关的 `consumeMaterial() did not find all required materials` 和 `IsoThumpable not found` 警告（例如服务端日志中 20048,2047,0 与 20054,2054,0），以及游戏/其他模组启动阶段的 `AnimSets`、`actiongroups`、`SpriteConfig` 等通用警告。这些不能替代 RV 功能通过，下一名 agent 应在修复 nil 后重新观察是否仍影响拆墙链。

## 当前 blocker 与下一步

1. 先修复 `currentRoofRepairContext` 的 nil 调用，并保持 current-only fail-closed 行为；修复后直接运行仓库一键测试，不拆分客户端/服务器测试。
2. 使用人工观察确认：进入现有 RV，拆除一面外墙后是否看到“正在刷新房间”；玩家是否暂时传送到同一 RV 100×100 scope 中心的 `z=-15`；是否在约 0.5、1.0、1.5 秒完成三次地板 add/remove；最后是否回到原合法 RV 位置且房顶隐藏。
3. 第一阶段若成功，不实现跨 chunk。若第一阶段仍无法刷新视觉，再单独设计并测试将玩家送入其他 chunk 的游戏可支持最低层，以实际人工反馈调整 `-10` 到 `-20` 的硬编码实验值；不要自行检查游戏源码替代人工反馈。

## 尚未实现的建造范围审计

当前仍未完成用户要求的服务端建造审计/清理，现有仅按已证明的当前对象归属与 shell 保护执行有限路径，不能阻止所有第三方建造物留在 RV scope 内。下一名 agent 必须：

- 按对象最终坐标及完整 multi-tile footprint，并结合当前 managed scope 做服务端权威判定；不能信任玩家所在位置，因此玩家站在室内向室外隔空建造也不得绕过审计。
- 使用白名单而不是黑名单：只允许墙、门框、门、窗户等明确允许的边界物品；未知对象和模组对象默认删除。
- 明确覆盖床、容器、树木、地板、装饰物、电视、雨水桶等 BuildingCraft 或其他模组可建对象。
- 继续保护 current shell ledger，尤其不得误删 east/south host cell 上由相邻 tile 的 W/N edgeKey 表示的合法 shell replacement。

该范围审计未完成前，不应把“scope 内可建造”描述为已验收。

## 归档边界与验证命令

本次提交包含当前 worktree 中除运行时/临时目录外的现有项目改动：RV Lua、共享契约、静态测试、README、各层 `agent.md`、根 `agents.md` 和本报告。

本轮只允许执行以下静态验证：

```text
python RailroaderRVTest/tests/test_rv_server.py
git diff --check
```

本轮实际结果：`python RailroaderRVTest/tests/test_rv_server.py` 通过（payload、UTF-8 启动链、relocation handshake、stale-room guard、实体/流体组件、rollback、Railroader SP/MP、距离/座位交接、持久化文档和 Lua syntax 契约均通过）；`git diff --check` 通过，仅输出 Git 的 LF→CRLF 提示。

不得启动游戏运行时测试。`testserver/runtime/` 已由根 `.gitignore` 的 `/testserver/` 规则忽略；既有 `.tmp-railroader-2.1/` 本轮新增 `.tmp-railroader-2.1/` 规则忽略，二者都不提交。`.github/` 目录本轮仅核对到项目要求的 `copilot-instructions.md`，该文件已显式纳入本次提交；根 `.gitignore` 的 `/.github/` 规则保留不变，后续已跟踪文件仍可正常更新。

没有发现待提交的密钥或其他需要纳入版本库的运行时产物。若后续出现新的未跟踪项，应先判断其是否属于源代码/说明/测试，再加入提交，不要将日志、存档、临时目录或密钥强制加入。
