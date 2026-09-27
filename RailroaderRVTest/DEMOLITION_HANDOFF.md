# Railroader RV 拆除故障移交报告

## 结论

最近的调查有实质进展，但拆除修复尚未验证成功。此前只能看到客户端短暂启动拆除动作；2026-09-27 22:03 的新日志首次同时记录了客户端放行、NetTimedAction 网络请求、服务端重建动作和 `complete` 入口。19 个服务端请求都带着 `actionArgs.object = null`，重建后的 `ISDestroyStuffAction.item` 都是 `nil`。

当前最可信的故障候选是客户端临时包装器改了 `ISDestroyStuffAction.new` 第二个形参的名字：原版形参叫 `item`，包装器叫 `object`。只读静态 Java 参考显示，NetTimedAction 序列化会按 `new` 函数的形参名称从动作表中取值，而原版构造函数把目标存到 `action.item`。这套源码推导与日志中的 `object:null`、服务端 `item=nil` 相吻合，但没有在这个候选上实施单点修正并运行时复测，因此仍应标为**高度可信、未经修复验证**，不能写成已修复或已最终证实的根因。

本报告只交接拆除问题。没有修改模组代码或启动、停止测试。其余故障不在本报告范围内。

## 故障描述与范围

用户反复报告房车驾驶室北墙、西墙及室内家具无法拆除。早期反馈是大锤光标能高亮目标，读条短暂出现后没有拆除；部分轮次角色头顶出现过不完整的“RV data invalid, delete …”提示。最近的新存档反馈为拆除进度条刚出现就消失，未看到头顶提示。

用户明确了拆除规则：命中驾驶室坐标就允许拆除；南、东墙上的门窗再按对象类型识别，不能按名称限制。用户也明确，客户端检查只是用户体验，服务端模板保护负责兜底；模板数据是开发期固定数据，可在客户端和服务端共用本地定义。

本次最新日志记录的是管理员建造作弊路径。它不能代替非作弊模式、持有普通大锤时的独立验证。

## 按时间整理的拆除证据

### 旧的快照过期拦截：19:26 客户端日志

日志：`Z:\RailroaderRVTestCache\client\Logs\logs_2026-09-27\2026-09-27_19-26_DebugLog.txt`

2026-09-27 19:30:14.975，客户端对北墙对象（世界坐标 `20048,2048,0`，模板索引 134）执行对象检查。对象标签中的 RV、generation、bitmap 身份有效：紧邻的 `identity.validate.return` 记录是 `result=true`。但客户端快照缓存年龄为 234 tick，超过当时的 120 tick 限制，于是 `snapshot.lookup.return` 为 `nil / snapshot-stale`，最后 `object-check.return blocked=true reason=snapshot-stale`。该次构造没有调用原版动作构造函数。

这是一个**曾经确实发生的客户端 fail-closed 路径**。它能解释那次尝试为什么在客户端被拦截，但不解释 22:03 的失败：最新日志里的北墙和家具都记录为 `cab-coordinate-allowed`，并继续调用原版构造函数。不要把旧的快照过期记录当成当前所有拆除失败的解释。

### 20:54 服务端 / 20:55 客户端日志：只跟到构造器放行

日志：

- `Z:\RailroaderRVTestCache\server\Logs\logs_2026-09-27\2026-09-27_20-54_DebugLog-server.txt`
- `Z:\RailroaderRVTestCache\client\Logs\logs_2026-09-27\2026-09-27_20-55_DebugLog.txt`

客户端在 20:57:33–20:58:10 期间记录了 25 次 `ISDestroyStuffAction` 构造检查；25 次都是 `blocked=false reason=cab-coordinate-allowed`，并调用原版构造函数。日志样例包括北墙（`20048,2048,0`，索引 134）、另一墙体（`20049,2048,0`，索引 166）和家具（`20046,2049,0`，索引 22）。其余多次尝试集中在北墙坐标。

该轮客户端 trace 当时只覆盖 `action.new`，没有记录 `isValid`、`start`、`stop`、`perform` 或 `complete`。对应服务端日志里没有 `ISDestroyStuffAction`、`NetTimedAction accepted` 或 `RV-TimedActionTrace` 记录。因此这轮只能证明客户端检查通过，无法判断动作是否入队、是否发送请求、服务端是否收到目标对象。

20:55 日志没有记录当时是否启用了建造作弊或持有大锤，不能据此区分两种模式。

### 21:13 日志：客户端确实启动后又停止，服务端路径仍缺证据

日志：

- `Z:\RailroaderRVTestCache\server\Logs\logs_2026-09-27\2026-09-27_21-13_DebugLog-server.txt`
- `Z:\RailroaderRVTestCache\client\Logs\logs_2026-09-27\2026-09-27_21-13_DebugLog.txt`

客户端有 10 次动作构造检查，10 次都通过 `cab-coordinate-allowed` 并调用原版构造函数。此轮新增动作生命周期跟踪：`isValid` 进入和返回各 229 次，所有记录结果为 `true`；`start` 进入/返回各 10 次，`stop` 进入/返回各 10 次；客户端侧没有 `perform` 或 `complete` 记录。

这 10 次的状态字段都显示 `ISBuildMenu.cheat=true`、`characterBuildCheat=true`，主手没有物品，背包递归查找不到大锤。前两次对象位于北墙（`20048,2048,0`，索引 134）和家具（`20046,2049,0`，索引 22），当时记录的距离超过普通动作距离；`isValid` 仍为真，因为建造作弊分支直接放行。其余多次尝试也都处于作弊模式。该轮因此**只实测了建造作弊路径**，没有独立覆盖普通非作弊大锤路径。

对应服务端日志没有 timed-action trace 或 `NetTimedAction accepted` 记录。没有这类日志不等于服务端一定没收到，只能说该轮没有观测到服务端处理阶段。

### 22:03 日志：首次定位到服务端动作目标为空

日志：

- `Z:\RailroaderRVTestCache\client\Logs\2026-09-27_22-03_DebugLog.txt`
- `Z:\RailroaderRVTestCache\server\Logs\2026-09-27_22-03_DebugLog-server.txt`

客户端统计：

- `action.new.enter`、`action.new.decision`、`action.new.call-original` 各 24 次。
- 24 次目标检查均放行；其中北墙索引 134 的目标是 `20048,2048,0`，家具索引 22 的目标是 `20046,2049,0`。
- `action.isValid.enter/return` 各 361 次，返回值均为 `true`。
- `action.start.enter/return`、`action.stop.enter/return` 各 19 次。
- 客户端没有 `action.perform` 或 `action.complete` trace。

这轮 361 条状态记录显示建造作弊为真，主手为空，背包中找不到大锤。北墙目标的样例 `isValid` 为真且目标方格和 object index 均有效；家具样例的普通距离检查为假，但作弊模式下 `isValid` 仍为真。用户最新观察到的“读条出现后立即消失”与客户端确有 `start` 后 `stop` 的顺序相符，但单凭顺序不能判定谁触发了停止。

服务端统计：

- 19 条 `NetTimedAction accepted`，类型均为 `ISDestroyStuffAction`，时间范围 22:08:20.713–22:09:01.569。
- 19 条 `serverStart.enter`，对应重建后的动作全部记录 `item=nil`；`maxTime=1`，玩家 `isBuildCheat=true`。
- 19 条 `complete.enter`，入口时仍全部记录 `item=nil`。
- **没有** `complete.return` 记录。

代表行：

- 服务端第 2619 行：请求被接受，但 `actionArgs` 是 `{"character": ..., "object": null}`。
- 服务端第 2620 行：`serverStart.enter` 显示 `item=nil`。
- 服务端第 2636 行：`complete.enter` 显示 `item=nil`。
- 客户端第 1281–1284 行：北墙对象检查放行并调用原版构造函数。
- 客户端第 1440–1445 行：家具对象检查放行；随后的 `isValid.return` 为真。

**不要把 `NetTimedAction accepted` 当成对象已删除。**它仅表明服务端接受了 timed-action 请求；同一日志的动作参数和服务端动作状态显示，拆除目标没有传到重建后的动作中。

日志中另有 19 条 `GeneralAction client reject`，每条的 `Action.id` 都与一条 `ISDestroyStuffAction` 的 `NetTimedAction accepted` id 对应（1、2、7–23）；日志文本也明确记录 `state="Reject"`。因此可以确认这 19 条 reject 记录和这轮拆除动作逐条对应。它们不能单独证明 reject 的触发原因，也不能代替缺失的 `complete.return` 或 NetTimedAction 最终状态记录。

## 最可信的故障候选：包装器改写了网络序列化所需的形参名

当前客户端包装器位于 `RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_ProtectedDemolition.lua:491-520`。其中：

```lua
action.new = function(self, character, object, ...)
    ...
    return originalNew(self, character, object, ...)
end
```

客户端检查层使用 `object` 这个名字本身没有问题。候选机制是 NetTimedAction 按 `new` 函数元数据中的形参名称组装网络动作参数。只读官方 Lua 中 `ISDestroyStuffAction:new(character, item, cornerCounter)` 将目标写入动作表字段 `o.item`（`official lua scripts/shared/TimedActions/ISDestroyStuffAction.lua:330-340`）。只读静态参考 `game-decompiled/42.20.0/src/zombie/core/NetTimedAction.java:42-55` 显示该代码会读取 `new` 函数形参名，并用每个名字执行 `action.rawget(paramName)`；字段不存在时，将 null 放入网络参数。客户端包装器把第二个形参从 `item` 改成 `object`，动作表却仍只有 `item`，因此按这份静态实现推导会取到空的 `action.object`。

**版本与证据限定：**`game-decompiled/42.20.0/.../NetTimedAction.java` 是只读静态参考，不是当前 42.20.4 基线的事实源。此处的机制候选来自本模组包装器、官方 Lua 构造器字段与 22:03 运行日志三者相互吻合；静态 Java 代码不能单独证明当前运行时实现。若之后恢复该问题的诊断，仍需对“客户端动作字段到服务端构造参数”这一边界做一次运行时单点验证。

随后该静态参考中的 `NetTimedAction.write` 序列化请求（同文件 177-185 行）；服务端 `NetTimedAction.parse` 根据网络参数重建调用 `new`（同文件 145-170 行）。22:03 日志中实见的 `actionArgs.object:null` 和服务端 `item=nil` 与这个传递链相符。该静态参考中的 `NetTimedActionPacket.processServer` 会在请求结构一致且动作对象成功构造时先接受并启动（`game-decompiled/42.20.0/src/zombie/network/packets/NetTimedActionPacket.java:62-83`），所以“请求被 accepted”和“有有效拆除目标”可以同时相反；当前运行时对这一点的匹配仍需上述单点验证。

官方 `ISDestroyStuffAction:complete` 开头检查 `self.item`，为空时按源码立即 `return false`（`official lua scripts/shared/TimedActions/ISDestroyStuffAction.lua:91-94`）。如果目标非空，服务端常规分支才会调用 `transmitRemoveItemFromSquare`（同文件 276-303 行）；Java 服务端实现最终移除方格对象（`game-decompiled/42.20.0/src/zombie/iso/IsoGridSquare.java:5278-5319`）。这是静态源码推论，不是本次日志证明的 `complete` 返回值。

`RV_ProtectedDemolition.lua:520` 也用同一包装函数包装 `ISDismantleAction.new`。官方该函数的形参名是 `thumpable`，构造器将其存入 `o.thumpable`（`official lua scripts/shared/TimedActions/ISDismantleAction.lua:105-110`）。这存在同类形参名风险，但这轮实测对象是 `ISDestroyStuffAction`，不能据此声称 dismantle 已经失败。

### `complete.return` 缺失需要保留为未解观测

本轮 `RV_TimedActionTrace` 对 19 个服务端 `complete` 都记录了 `.enter`，却没有任何 `.return`。因此报告只能说：服务端进入了 `complete`，且入口时 `item=nil`；官方静态代码预期此时返回 false。不能写成“日志证明 19 次返回 false”。

下一位开发者应查清 trace 为什么没有落下 `.return`，或调整临时包装使无论原函数返回还是抛错都记录 `result/exception`。没有完成原因之前，不要把 GeneralAction Reject 记录、客户端停条或源码推演写成已确认的完整因果链。

## 普通大锤与作弊模式的证据边界

| 证据来源 | 可确认的模式 | 不能确认的部分 |
|---|---|---|
| 用户早期反馈 | 用户称使用过建造作弊和普通大锤方式，房车目标无法拆除；曾看到高亮、短暂读条和不完整的 invalid/delete 提示 | 早期没有完整日志，提示原文、具体动作类与每种模式的调用路径无法复原 |
| 20:55 客户端日志 | `ISDestroyStuffAction` 构造检查通过 | 当轮没记录作弊、主手或背包状态，无法分类 |
| 21:13 客户端日志 | 建造作弊开启；无手持或背包大锤；客户端动作 start 后 stop | 不能代表普通非作弊大锤测试 |
| 22:03 客户端/服务端日志 | 建造作弊开启；无手持或背包大锤；服务器收到的 19 个动作目标为空 | 仍没有独立的普通非作弊大锤运行时证据 |

官方 `ISDestroyStuffAction:isValid` 在 `ISBuildMenu.cheat` 为真时会直接放行（`official lua scripts/shared/TimedActions/ISDestroyStuffAction.lua:11-19`）；22:03 的客户端 `isValid=true` 与此相符。它不能验证普通模式需要的大锤物品检查及距离条件。

## 已证实的失败路径与尚未证实的路径

| 路径 | 结论 | 证据边界 |
|---|---|---|
| 旧客户端快照过期拦截 | **该轮确实发生**：identity 校验成功，但 snapshot age=234 超过 120，客户端 blocked=true | 19:26 日志，只解释那次尝试 |
| 最新客户端坐标/对象检查阻止驾驶室目标 | **最新日志不支持**：北墙、家具均为 `cab-coordinate-allowed`，调用原构造函数 | 22:03 客户端 trace |
| 客户端动作未通过 `isValid` | **最新日志不支持**：361 次 `isValid` 结果均 true | 22:03 客户端 trace；仅作弊模式 |
| 服务端拒绝了 timed-action 请求 | **不支持**：19 个初始请求均显示 `NetTimedAction accepted` | accepted 不代表世界删除成功 |
| 服务端拥有实际目标 | **明确失败**：19 个服务端动作的请求参数中 `object=null`，重建对象 `item=nil` | 22:03 服务端 trace；这是当前最强定位 |
| 服务端 `complete` 已返回 false | **未被日志证明** | 没有任何 `complete.return`；官方源码只说明 nil 时应走 false 分支 |
| TemplateProtectionRepair 阻止了拆除 | **未确认**：没有记录到其对这些具体目标的恢复决策 | 不要把 roof-refresh-wall 的 `candidate=0` 计数说成模板保护计数 |
| 普通非作弊大锤路径重现了同一错误 | **尚未独立验证** | 最新运行时状态全是作弊开启且无大锤 |

服务端 22:03 日志里确有 `handler=roof-refresh-wall ... candidate=0` 的 PerfTrace 样例（如第 2185、2371、2380、2472 行），但这属于屋顶刷新对象移除钩子，不是 `TemplateProtectionRepair` 扫描结果。它只说明这个屋顶刷新 handler 在那些采样窗口没有匹配的墙体候选；不能拿来证明模板保护已运行、未运行或放过了目标。

## 临时诊断代码与保留要求

当前用于这次拆除定位的代码位置：

- 客户端对象身份、坐标放行、构造器及 `isValid/start/stop` 跟踪：`RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/RV_ProtectedDemolition.lua:37-42, 491-525`。
- 服务端 `serverStart/serverStop/complete`、动作字段和 Lua 调用栈跟踪：`RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_TimedActionTrace.lua:220-300`。
- 服务端 trace 模块加载点：`RailroaderRVTest/contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua:23-39`。

这些 trace 是临时诊断信息，频率高。修复经用户复测通过后，按用户要求移除；在此之前不应删掉可复现关键序列所需的日志。

## 后续最小诊断顺序

当前用户要求转为移交报告，没有在本次任务实施代码修复或启动测试。若以后恢复拆除工作，建议下一位开发者只围绕目标参数传递做一次最小验证：

1. 先保护 NetTimedAction 需要的原始构造函数参数名。对 `ISDestroyStuffAction.new`，包装器应保留第二个参数名 `item`，或改用不会替换 `new` 函数参数元数据的拦截方式。不要同时改 TemplateProtectionRepair 或再增加快照同步分支。
2. 下一个完整运行时测试分别记录两个用例：管理员建造作弊拆北墙/家具；关闭作弊并持有普通大锤拆同样对象。项目验收仍使用根目录规定的一键整体测试流程，由测试进程保持可见；用户在客户端操作并回报观察。
3. 对每个操作比较客户端原始动作字段与服务端入参：应看到目标字段名与字段值非空；服务端重建后 `item` 必须非空。再记录 `complete.enter`、`complete.return` 或异常、NetTimedAction 最终状态，以及实际移除请求中的坐标和 object index。
4. 如果保留原参数名后服务端字段仍为空，再增加最少量的序列化边界日志：客户端 `new` 原型形参名称、动作表 `item/object` 键值、`NetTimedAction.actionArgs`；服务端 parse 的字段顺序和值，以及重建后动作字段。这样可把问题分到序列化、参数顺序或服务端重建，不必再猜模板数据或坐标门禁。
5. 单独观测 `TemplateProtectionRepair` 对同一坐标和 object index 的扫描、判定、恢复队列；不要把 `roof-refresh-wall` handler 的 PerfTrace 当作它的证据。

## 本报告没有下的结论

- 没有声称拆除已修复。
- 没有声称服务端 `complete` 已实测返回 false；该返回 trace 缺失。
- 没有声称普通非作弊大锤路径已被最新日志覆盖。
- 没有声称模板保护系统导致本次失败，也没有把屋顶刷新钩子等同于模板保护。
- 没有据 `NetTimedAction accepted` 推断世界对象已删除。
