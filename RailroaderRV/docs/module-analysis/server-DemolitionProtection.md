# 服务端 DemolitionProtection 模块分析
> **状态（RailroaderRV 1.0）**：本文件是静态审计记录；其行号、计数和源码结论并非本次发布的全量重核，也不是运行时验证。当前实现以 [源码](../../contents/mods/RailroaderRV/42/) 与 [README](../../README.md) 为准，项目约束以 [agents.md](../../../agents.md) 为准。历史建议不构成修复授权，采纳前须按现行约束重新取证。

## 假设、范围、成功条件与验证方式

- **假设**：只分析 `media/lua/server/RailroaderRV/DemolitionProtection/` 目录；该目录当前只有 1 个 Lua 文件 [RV_BoundaryServer_Objects.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/DemolitionProtection/RV_BoundaryServer_Objects.lua:1)，**504 行、23 个函数定义**（本报告机械复核结果，见末章）。行号全部来自本次对当前源码的逐行读取，不引用精简前版本的旧行号。
- **范围**：覆盖该文件全部具名函数、`local function`、表方法（`function Boundary.x` / `function BuilderActionLedger.x`）与匿名函数表达式（模块工厂）；为判定调用合同与跨模块数据访问边界，只读检查了 BoundaryGuard（Geometry/Sweep/BoundaryServer/Validation）、RVMapping（EntryExit）、WallReloadProtection、Core（RV_Server_Core/RV_Server_Commands）、Common（RV_ServerWorld/RV_Common）、TemplateRecovery 以及 shared（TemplateGeometry/RoomTemplate）中的相关行。这些外部文件**不纳入**本模块逐函数清单。唯一写入目标是本报告。
- **边界说明**：本次任务把本文件描述为「不存在、需新建」，但开始时该路径已存在一份**精简前口径**的旧报告（声称 25 个函数、约 665 行、`Boundary._builders`、footprint、auditObject、isDisallowedPlayerBuild 等）。按任务给定的唯一允许写入路径，本报告对其整体重写为当前源码口径；这属于同一份文档的更新，不涉及源码或其他报告。
- **成功条件**：每个函数都有精确起始行、参数类型/含义、返回值或副作用、本模块语义与加粗必要性结论；给出复用/提取判断、拆分判断、公开合同、双向跨模块数据访问证据（文件:行）与接口取舍；明确区分「源码事实」与「条件性推断」。
- **验证方式**：目录列举 + 行数统计；`function` 关键字全行扫描并与逐行编号全文读取交叉核对（本文件 0 处 `type(x) == "function"` 比较行、0 条含 "function" 的注释行，故关键字命中数即定义数）；在 `contents/mods/RailroaderRV/42/media/lua` 全树检索 `builderActionLedger`、`BuilderActionLedger`、`_builders`、`_tick`、`isCurrentShellWall`、`boundaryForPlayer`、`Boundary.boundaryFor`、`RailroaderRV` 等符号判定接口面；完成后复核函数条目数、路径与行号引用。静态扫描不替代运行时验证，本轮未运行游戏或测试。

## 目录职责与清单

DemolitionProtection/ 目前只有 1 个文件，承担四类职责：对象 tag（canonical 命名空间）的读取与写入门、当前 generation 的 shell 构件身份授权、服务端建造意图与异步 `OnObjectAdded` 对象的关联、以及该关联所需的短期 action ledger（`BuilderActionLedger` 的唯一所有者）。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [RV_BoundaryServer_Objects.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/DemolitionProtection/RV_BoundaryServer_Objects.lua:1) | 23 | 对象 ModData/tag owner 门、对象坐标归一化、shell edge 模板索引与授权判定、`Boundary.isCurrentShellWall` 公开判定、建造 action↔对象匹配、`playerBuilt` tag 写入（canonical 命名空间第二 writer）、`BuilderActionLedger`（submit/prune/generation 失效/唯一候选/消费状态）、`Boundary.onProcessAction` 与 `Boundary.onObjectAdded` 两个已注册回调 |
| **总计** | **23** | 13 个 `local function`、9 个表方法（Boundary 3 + BuilderActionLedger 6）、1 个匿名模块工厂；无全局具名函数 |

计数口径：计入 `local function`、表方法、作为模块入口的匿名工厂（L2）；不计入 `M.foo = localFunction` 这类导出别名赋值（本文件无此类）。本文件没有 `type(x) == "function"` 形式的能力探测行，也没有含 "function" 字样的注释行，因此「关键字命中 23」与「函数定义 23」一致；23 个函数**全部有当前调用者**（本文件内部或跨模块），没有死函数。

## 逐文件、逐函数分析

### RV_BoundaryServer_Objects.lua

本模块以 `return function(ctx)`（L2）工厂形式被 BoundaryServer 加载：RV_BoundaryServer.lua 在 L36 初始化 `Boundary._tick`、L47 先执行 Geometry（它在 L378-L387 把 `number`/`integer`/`call`/`identity`/`square` 等注入 ctx）、L48 执行本文件、L49 再执行 Sweep，因此本文件的依赖全部由 ctx 与 require 提供。模块本身不注册 engine 事件、不持久化任何状态：它在 Boundary 命名空间上安装 4 个字段——`Boundary.isCurrentShellWall`（L123）、`Boundary.builderActionLedger`（L411）、`Boundary.onProcessAction`（L413）、`Boundary.onObjectAdded`（L480）；后两者由 [RV_Server_Commands.lua:389-L390](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:389) 注册到 Core 的 `OnProcessAction`/`OnObjectAdded`。ledger 是进程内短期状态（`expires = Boundary._tick + 2`，L436），随玩家建造操作与 generation 身份生灭。头部注释（L1-L32、L117-L122、L284-L286、L450-L454、L485-L491）把三条策略写成显式合同：tag 只存身份与模板索引、绝不复制模板属性；异步关联不唯一时对象保持未标记（fail-open 保留）；自动删除必须同时具备唯一 action 关联与当前 generation 的 `playerBuilt` tag。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| 匿名模块工厂（L2） | ctx：BoundaryServer 组装的共享上下文（Boundary、Core、C、OWNER，加 Geometry 注入的 number/integer/call/identity/square）。无返回值；副作用是 require Common/RoomTemplate/TemplateGeometry（L12-L14）、解析模板与有序对象表（L15-L16），并把 4 个字段写进 Boundary 命名空间。语义：本目录唯一入口与依赖捕获点。 | **必须**：`require(...)(ctx)` 是 BoundaryServer 加载本模块的唯一方式（[RV_BoundaryServer.lua:48](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer.lua:48)）；L4 `Core`、L5 `C`、L11 `square` 三项捕获在当前文件内无读取者（见接口章节）。 |
| objectModData（L18） | object：engine 对象。经 Geometry 的 `call` 调 `getModData`（L19），成功且结果为 table 时返回 modData **原表引用**（可写句柄），否则 nil；不修改对象。语义：本模块读写 canonical tag 的唯一取表口。 | **实现必需**：仅本文件内部两处消费（rvTag L26、markTagPlayerBuilt L288）；行为与 [RV_ServerWorld.lua:167](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua:167) 的同名导出等价但保护强度不同（见复用章节），故属实现细节而非对外合同。 |
| rvTag（L25） | object。取 modData 的 `RailroaderRV` 命名空间（L27），要求是 table 且 `tostring(tag.owner) == OWNER`（L28），否则 nil；只读。语义：canonical 命名空间的 owner 门——「没有 tag 的是普通世界内容，外来 owner 的不是我们该动的」。 | **必须**：isCurrentShellWall 的 tag 判定（L148）与 markTagPlayerBuilt 的覆盖保护（L295）都经它；删除等于取消 owner 门。 |
| objectSquare（L34） | object。调 `getSquare`，成功且非 nil 返回 square，否则 nil；不写世界。语义：对象宿主 square 探测。 | **实现必需**：仅 objectCell（L41）使用；它把「对象是否已落在世界中」变成显式事实，isCurrentShellWall 在 L141-L146 要求 square 非空后才继续。 |
| objectCell（L40） | object。优先取 square 的整数 x/y/z（L43-L47）；square 不可用时退回对象自身 `getX/getY/getZ`，经 number 转换与 floor（L50-L54）；成功返回 x,y,z,square（square 可能为 nil），全失败返回 nil；不写世界。语义：对象宿主坐标归一化，兼容「有 square」与「只有坐标」两种 engine 状态。 | **必须**：3 个调用点覆盖两条事件路径——isCurrentShellWall L141、onProcessAction L469、onObjectAdded L483。 |
| shellEdgeHasTemplateIndex（L58） | edge：shell ledger 项；templateIndex：候选模板索引。要求 `edge.templateIndices` 是连续正整数数组（L62-L69）、首项等于 `edge.templateIndex`（L70-L72），再判断候选索引在表中（L74-L77）；返回布尔，只读。语义：拒绝稀疏、别名或自相矛盾的 template 索引记录。 | **实现必需**：shellEdgeAllowed（L102）与 isCurrentShellWall（L193）共用的索引完整性判据，两处语义必须一致，内联会复制同一段校验。 |
| shellEdgeAllowed（L80） | boundary、tag、objectX/Y/Z。从 `tag.edgeKey` 取 `boundary.shellEdges` 项（L90-L91），要求 managed 的 originX/originY 与 `TemplateGeometry.anchorFromManaged` 可得（L83-L86）；随后要求 edge 与 tag 的 owner、rvId、generation、`replacementAllowed`、`templateIndices`，以及 `templateObjects[tag.templateIndex]` 的 north/x/y/z/role 与边界宿主坐标全部精确一致（L93-L113）；返回布尔，只读。语义：把 tag 授权为「当前 generation 的真实 shell edge」的唯一最终判定。 | **实现必需**：仅 isCurrentShellWall（L198）调用；它是 36 行判据集合，内联会把整段授权逻辑搬进公开函数，但对外行为并不因它单独变化。 |
| Boundary.isCurrentShellWall（L123） | object、boundary。要求 boundary 有非空 rvId、generation ≥ 1 整数、managed 与 shellEdges 均为 table（L128-L133）；对象须是 IsoThumpable 或 IsoWindow（L134-L138）、有非负 objectIndex（L139-L140）、有 square 且坐标落在 managed 范围内（L141-L146）；tag 的 rvId/generation 须与 boundary 一致（L148-L152）；role 限 wall-north／wall-west／corner-nw（L154-L158）；edgeKey 与 templateIndex 齐备（L159-L161）；再逐项比对 captured 模板项的 class/name/sprite/north/dir/role（L164-L187）与 shellEdges 项字段（L188-L197），最后交 shellEdgeAllowed（L198）。返回布尔，不写世界。语义：被拆除对象是否确为当前 generation 的 shell 构件（墙/栏杆/门/窗/角件）。 | **必须**：唯一跨模块消费方是 [RV_RailroaderServer_WallReload.lua:168](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua:168)（类型门）与 L182-L185（pcall 后要求严格 `== true`，重复身份即放弃）；它决定墙被移除后是否触发对应 RV 的 roof refresh 路径。 |
| appendShellEdgeKey（L201） | result：数组；seen：去重集合；key：候选 key。非 string 或已登记则丢弃，否则登记 seen 并追加到 result；无返回值。语义：候选 ledger key 去重构造。 | **实现必需**：shellEdgeKeysForAction 的三处合并（L234、L249、L258）共用同一去重规则。 |
| shellAxisMatches（L207） | edge、axis（可为 nil）。axis 为 nil 时放行任意 side；N/W/E/S 分别要求 `edge.side` 等于 north/west/east/south；未识别方向返回 false；只读。语义：按回调给出的方位过滤 shell ledger 候选。 | **实现必需**：shellEdgeKeysForAction（L254）在按宿主坐标扫描 ledger 时用它过滤；无方向时保留坐标兜底匹配。 |
| shellEdgeKeysForAction（L222） | boundary、x、y、z、axis。boundary 或 shellEdges 非 table 时返回空表（L224-L226）；按 axis 取 canonical key——N/W 用 `edgeKey`、E/S 用 `edgeForSide`（L228-L235）；axis 为 nil 时探测四边（L236-L252）；最后扫描全部 shellEdges 中 `objectX/Y/Z` 等于给定坐标且方位匹配的项（L253-L260）。返回去重 key 数组，不改 boundary。语义：兼容 PZ 建造回调「active edge cell」与「相邻 host tile」两种坐标约定（注释 L216-L221 说明东/南替换为何必须两路都认）。 | **必须**：onProcessAction（L444）靠它决定 action 的 edgeKey/edgeKeys，actionMatchesObject（L270）靠它把对象坐标映射回 ledger 项。 |
| actionMatchesObject（L264） | action、x、y、z。action 坐标与对象坐标完全相同即 true（L269）；否则经 shellEdgeKeysForAction 取候选，逐项要求 `edge.objectX/Y/Z` 等于对象坐标（L270-L280）；字段缺失或不匹配为 false，只读。语义：把「提交的建造意图」与「异步新增对象」关联起来。 | **必须**：uniqueCandidate（L378）与 onProcessAction（L474）都依赖它，是异步归属的唯一匹配判据。 |
| markTagPlayerBuilt（L287） | object；builder：identity 表（L312 取 `builder.key`）；action：ledger action。要求 modData 可取（L288-L289）、`action.rvId` 非空且 generation 为 ≥1 整数（L290-L294）；既有 tag 若 rvId/generation 不同即拒绝（L295-L302）；既有 tag 若非 `playerBuilt == true` 即拒绝（L303-L308）；否则整体重写 `data.RailroaderRV`（L309-L320）为 `{owner, playerBuilt=true, builder, rvId, generation, edgeKey, edgeKeys, footprint}`，成功 true、失败 false。**副作用：写 engine 对象 ModData，是本文件唯一的 canonical 命名空间写入点。** 语义：以已验证的服务端建造意图登记玩家建造归属，并拒绝把外代 tag 或模板/生成器对象改写成玩家对象。 | **必须**：onProcessAction（L475）与 onObjectAdded（L496）两条路径的落点；L485-L491 注释表明后续「自动删除」同时要求它与唯一 action 关联。 |
| commandArgument（L324） | args：事件参数容器；key。args 是 Lua table 时取 `args[key]`（L325），否则经 `call(args,"get",key)`（L326-L327），缺失返回 nil；只读。语义：兼容 Lua 表与 Java 风格参数容器两种形态。 | **实现必需**：仅在 onProcessAction 内部使用（L331、L421-L423、L431、L435、L437-L438、L440-L441 共 8 处）；内联会把同一分支复制 8 遍。 |
| commandCoordinate（L330） | args、key。`integer(commandArgument(args,key))`；成功返回整数，否则 nil。语义：事件坐标整数化，供 managed 范围与 ledger 比较使用。 | **实现必需**：onProcessAction 的 x/y/z 读取（L421-L423）唯一使用点；它是「坐标必须为整数」这一门的单点实现。 |
| BuilderActionLedger.prune（L337） | tick：number（否则返回 false）。遍历 `actions`，删除「action 非 table」「expires 非 number」「tick > expires」的项（L339-L344）；返回 true。语义：ledger 唯一的过期清理，防短期意图泄漏。 | **必须**：外部每 tick 调用——[RV_BoundaryServer_Sweep.lua:111-L113](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Sweep.lua:111)（`type(actionLedger)=="table"` 才调，失败开放）；内部 L375、L414、L482。 |
| BuilderActionLedger.invalidateForGeneration（L348） | rvId、generation。rvId 非空、generation 为 ≥1 整数，否则 false（L349-L354）；删除「action 非 table」或「rvId 相同且 generation 不同」的项（L355-L361）；返回 true（**无匹配也 true**，L362）。语义：换代时作废旧异步意图，避免跨代误归属。 | **必须**：外部调用 [RV_RailroaderServer_EntryExit.lua:527-L533](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:527)，且该处 **fail-closed**（ledger 非 table、方法缺失或返回值非严格 true 即 `return false, C.INVALID_RV_DATA` 阻断本次 mapping 提交）；内部 L455（提交前清同 rv 其它代）。 |
| BuilderActionLedger.submit（L365） | key：非空 string；action：含 number `expires` 的 table。任一不合法返回 false，否则 `actions[key] = action` 并返回 true。语义：ledger 的唯一写入口。 | **必须**：onProcessAction（L457-L458）以 `id.key .. ":" .. rvId .. ":" .. generation` 为键提交；键同时限定玩家与 generation（注释 L450-L454）。 |
| BuilderActionLedger.uniqueCandidate（L374） | object、x、y、z、tick。先 `prune(tick)`（L375，失败即返回 nil）；遍历 actions，用 `actionMatchesObject` 过滤（L378），并要求 `Boundary.boundaryForPlayer(action.player)` 的 rvId/generation 与 `action.boundary` 相同（L380-L383）、对象坐标在该 boundary 的 managed 内（L384-L385）；出现第二个候选立即返回 nil（L386-L387），唯一则返回 action，无候选 nil。语义：唯一候选判定——同格两人同时放置或身份已过期时宁可放弃归属。 | **必须**：onObjectAdded（L492-L493）唯一的关联入口；它同时承担「action 仍然属于当前 boundary 身份」的复核，删除会让异步归属失去 generation 门。 |
| BuilderActionLedger.objectMatchConsumed（L394） | action、object。要求 `action.matchedObjects` 是 table 且以 object 为键为 true；返回布尔，只读。语义：消费状态查询。 | **必须**：onObjectAdded（L495）的重复事件门；同一对象重复触发 `OnObjectAdded` 时不得重复打标。 |
| BuilderActionLedger.consumeObjectMatch（L399） | action、object。action 非 table 或 object 为 nil 返回 false；`matchedObjects` 缺失时按需创建（L401-L405）；已登记返回 false，否则登记并返回 true。**副作用：写 action 表。** 语义：消费登记，与 objectMatchConsumed 构成一对。 | **必须**：onObjectAdded（L497）在 `markTagPlayerBuilt` 成功后才登记，保证「标记成功」与「消费」原子配对（L496-L498）。 |
| Boundary.onProcessAction（L413） | actionName、player、args；无返回。先 `prune(Boundary._tick)`（L414）；动作名小写后含 build/place/moveable 才继续（L415-L420，子串匹配）；取整数 x/y/z（L421-L424）；取 `Boundary.boundaryForPlayer(player)` 并要求坐标在 managed 内（L425-L428）；取 identity（L429-L430）；组装 action（player/identity/rvId/generation/x/y/z/boundary/footprint/`expires = Boundary._tick + 2`，L432-L436）；解析 axis（L437-L442）；用 shellEdgeKeysForAction 的结果写 `edgeKey`（唯一）或 `edgeKeys`（多个，L444-L449）；随后 `invalidateForGeneration` + `submit`（L455-L458）；若 `args.item` 已暴露 Java 对象，则取坐标并在 managed 内且 `actionMatchesObject` 为真时**立即** `markTagPlayerBuilt`（L463-L477）。语义：把服务端接受的建造意图登记为有界生命的待关联 action，并对已经可见的 builder 立即打标；绝不单凭客户端坐标授予归属。 | **必须**：[RV_Server_Commands.lua:389](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:389) 已把它注册为 Core 的 `OnProcessAction` handler；是 ledger 的唯一写入驱动。 |
| Boundary.onObjectAdded（L480） | object；无返回。空对象直接返回（L481）；`prune(Boundary._tick)`（L482）；取坐标（L483-L484）；`uniqueCandidate`（L492-L493）；`objectMatchConsumed` 门（L495）；`markTagPlayerBuilt` 成功才 `consumeObjectMatch`（L496-L498）。语义：异步关联的唯一消费者；不唯一、无候选或已消费时对象保持未标记，即 fail-open 保留（注释 L485-L491、L499-L500）。 | **必须**：[RV_Server_Commands.lua:390](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:390) 已注册为 Core 的 `OnObjectAdded` handler；它是「短暂意图 → 持久 tag」的唯一转换点。 |

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **已正确复用的共享件，不要再造第二份**：几何与模板知识全部来自 shared —— `TemplateGeometry.anchorFromManaged`（L85）、`inManagedRegion`（L143、L384、L426、L471）、`edgeKey`（L229、L242-L243）、`edgeForSide`（L231、L244-L245），定义见 [RV_TemplateGeometry.lua:164-L206](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_TemplateGeometry.lua:164)；模板与有序对象表来自 `RoomTemplate.get/orderedObjects`（L15-L16，[RV_RoomTemplate.lua:149](../../contents/mods/RailroaderRV/42/media/lua/shared/RailroaderRV/RoomTemplate/RV_RoomTemplate.lua:149)）；数值/Java 调用/身份原语由 Geometry 注入 ctx（[RV_BoundaryServer_Geometry.lua:378-L387](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Geometry.lua:378)）。判断：现状合理，本文件不应再自造几何或模板索引逻辑。
- **`Common.classInstance` 的直连是刻意的边界**：本文件 L12 直接 `require("RailroaderRV/Common/RV_Common")`，用途仅 L134-L135（IsoThumpable/IsoWindow 判定）。这是全树唯一直接 require RV_Common 的 server 模块；其余模块走 ServerUtil 门面或 ctx。判断：保留（ServerUtil 门面的存在理由是 Kahlua 活跃局部上限，见 RV_ServerUtil.lua L1-L5；本文件只需要一个类判定，转出整表反而增加绑定）。
- **`objectModData` 有一份重复实现，且保护强度不同（可提取，但净收益小）**：本文件 L18-L21 走 Geometry 的 `call`，而 [RV_BoundaryServer_Geometry.lua:38-L45](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Geometry.lua:38) 在 pcall **之前**先执行 `type(target[method])`——属性读取本身不受 pcall 保护；[RV_ServerWorld.lua:167-L173](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua:167) 走 `ServerUtil.invoke` → [RV_Common.lua:7](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_Common.lua:7) 的 pcall 包装属性读取，失败折叠为 nil。证据与净收益：统一可去掉 4 行并消除「同一原语两种失败语义」（属**条件性推断**：只有 Java proxy 属性读取会抛错的场景才可观测）；成本是本文件需新增 `require RV_ServerWorld`（连带 ServerUtil）或新增 ctx 注入，且要重新评估活跃局部上限。判断：**方向正确但当前净收益小**；若统一，优先在 ctx/Core 层注入一个共享 `objectModData`，而不是让 BoundaryServer 反向依赖 480 行的 RV_ServerWorld。
- **`data.RailroaderRV` 的读取习惯语在 server 树有 6 处并行实现，但「门」各不相同，不宜合并**：本文件 L27（仅 owner 门）、[RV_ServerWorld.lua:218](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua:213)（`isTaggedForGeneration`：owner+generation+rvId）、RV_ServerWorld.lua L321/L364、[RV_Server_WorldObjects.lua:351](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Construction/RV_Server_WorldObjects.lua:351)、[RV_UtilityPower.lua:59](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Power/RV_UtilityPower.lua:59)、[RV_Server_TemplateProtectionRepair.lua:141](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:141)、[RV_RailroaderServer_WallReload.lua:145/L207](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua:145)（后者不校验 owner）；另有 3 个客户端文件（RV_BoundaryWallVisuals.lua L44、RV_WardrobeVisuals.lua L51、RV_ProtectedDemolition.lua L195，客户端不能 require server 模块，属正常边界）。判断：语义在于**每处的门**而不是取表动作，把「读 tag」抽成一个函数会诱导调用方绕过各自的门；若确实要收敛，应在 ServerWorld 提供只读访问器 `tagOf(object)`，并在出现第 3 个需要**相同 owner 门**的消费者时再做。
- **`objectCell` 有第二份实现，且两者合同不同（不宜合并）**：本文件 L40-L56 优先 square、返回 4 值（含 square），[RV_Server_TemplateProtectionRepair.lua:153](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:153) 只用对象自身坐标、经 `ServerUtil.invoke`、返回 3 值。差异根源是本文件把「square 非空」当作 L142 的门（对象确在世界中），而 TemplateRecovery 不需要该门。判断：**不合并**；可提取的只是「object → 整数坐标」最小原语，但会牺牲本文件的 square 门或给 TemplateRecovery 引入无用的 square 依赖。
- **`commandArgument` 有第二份实现（可提取，收益小）**：本文件 L324-L328 与 [RV_RailroaderServer_Sentinel.lua:24-L29](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_RailroaderServer_Sentinel.lua:24) 几乎相同（Sentinel 版多一个 `args == nil` 早退；本文件版依赖 `call` 对 nil target 已返回 false,nil，行为等价）。净收益：去掉一处 5 行重复并统一 nil 语义；成本：Sentinel 在 Core 层、本文件在 BoundaryServer 层，需放进 Common/ServerUtil 或注入 ctx。判断：当前仅 2 处，**暂不提取**，出现第 3 处再合并。`commandCoordinate`（L330-L332）在全树没有第二份实现。
- **shell 身份/edge 判定系列（shellEdgeHasTemplateIndex、shellEdgeAllowed、isCurrentShellWall、shellEdgeKeysForAction、shellAxisMatches、appendShellEdgeKey）不应提取到公共层**：它们是「tag 形状 + 模板索引 + managed 范围 + 当前 generation」的 RV 专属**策略**，几何原语已在 shared（见上）；生产侧是 [RV_BoundaryServer_Geometry.lua:148-L174](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Geometry.lua:148) 的 `encodeShellEdges`，消费侧是本文件，两者通过字段名通信（注释 L88-L89、L162-L163 明确「tag 只存索引，属性从模板解析」）。判断：提取会把 BoundaryServer 的策略塞进共享层，并强制 ledger 形状与校验规则同步演进，净收益为负。
- **canonical 命名空间的两个 writer 是可讨论的复用缺口**：本文件 L309-L320 与 [RV_ServerWorld.lua:178-L211](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Common/RV_ServerWorld.lua:178) 的 `tagObject` 都写 `data.RailroaderRV`，字段集不同（详见接口章节）。判断：当前**不建议合并**——统一 writer 需要把「playerBuilt 模式 + ledger 唯一匹配结果」变成 `tagObject` 的参数，接口面比现在更大，而两套形状在身份字段（owner/rvId/generation）上是兼容的；应在 tag 文档中显式声明「playerBuilt 是受支持的第二形状」，或出现第三个 writer 时再统一。
- **`Boundary._tick` 的 4 处读取是唯一可低成本消除的跨模块私有访问**：本文件 L414、L436、L482、L493，替代品是 L4 已捕获但当前无读取者的 `ctx.Core`（[RV_Server_Core.lua:32/L92](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Core.lua:32) 的 `Core.getTick`），而 `Boundary._tick` 本身就来自它（RV_BoundaryServer.lua L36、Sweep L110）。判断见接口章节。

### 是否进一步拆分

- **现状**：504 行，是 BoundaryGuard 包内最大文件（Geometry 388、Validation 247、Sweep 180、RV_BoundaryServer 51）。六段职责清晰：tag 与坐标基础设施（L18-L56）、shell 身份授权（L58-L199）、action↔object 关联判据（L201-L282）、tag 写入（L287-L322）、异步 ledger（L334-L409）、事件回调（L411-L501）。
- **当前不建议拆分**，三条边界成本（源码事实）：
  1. **私有 helper 跨段共享**：`shellEdgeHasTemplateIndex` 被第 2 段内两处使用（L102、L193）；`shellEdgeKeysForAction` 被第 3 段（L270）与第 6 段（L444）使用；`objectCell` 被第 2 段（L141）与第 6 段（L469、L483）使用；`rvTag` 被第 2 段（L148）与第 4 段（L295）使用。任何切分都要先把这 4 个 helper 提升为新的跨文件 ctx 合同。
  2. **boundary 值对象贯穿三段**：`boundaryForPlayer` 调用（L380、L425）与 `boundary.managed/shellEdges` 直读散布在第 2、5、6 段，拆出的每个新文件都要重新捕获 Boundary 依赖。
  3. **Kahlua 活跃局部上限**：本文件在 L3-L16 已捕获 13 个 ctx/require 绑定；拆文件会让 `require Common/RoomTemplate/TemplateGeometry` 与 `Template`/`templateObjects` 初始化各来一遍（RV_ServerUtil.lua L1-L5 记录了同类约束的存在）。
- **若必须拆，缝在哪里**：ledger（L334-L409，76 行）是唯一自洽的状态机，且只有 2 个外部消费者（Sweep L111-L113、EntryExit L527-L533），是最干净的缝；但拆出后需要注入 `actionMatchesObject`、`Boundary.boundaryForPlayer`、`TemplateGeometry.inManagedRegion`、当前 tick 四个依赖，等于把 4 个文件内 upvalue 变成跨文件合同。第二候选是 shell 身份授权段（L58-L199），但它与第 6 段的 tag/坐标读取强耦合，且对外只暴露 `isCurrentShellWall` 一个函数。**触发条件**：ledger 方法数增长到约 10 个、出现第 3 个外部消费者、或需要把 action 状态持久化到 ModData 时再拆；在此之前保持单文件。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

本模块在 Boundary 命名空间上安装 4 个字段（源码事实）：

| 字段（起始行） | 形态与合同 | 当前消费者 |
|---|---|---|
| `Boundary.isCurrentShellWall`（L123） | `function(object, boundary) -> boolean`；boundary 必须带 managed 与 shellEdges（L130-L131） | [RV_RailroaderServer_WallReload.lua:168/L182](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua:168)（fail-open：类型门 + pcall + 严格 `== true`） |
| `Boundary.builderActionLedger`（L411） | 表：`actions` 数据表 + 6 个方法（prune L337、invalidateForGeneration L348、submit L365、uniqueCandidate L374、objectMatchConsumed L394、consumeObjectMatch L399）；加载期赋值一次，之后不重新赋值 | [RV_BoundaryServer_Sweep.lua:111-L113](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Sweep.lua:111)（只调 prune）、[RV_RailroaderServer_EntryExit.lua:527-L533](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:527)（只调 invalidateForGeneration） |
| `Boundary.onProcessAction`（L413） | `function(actionName, player, args)`，无返回 | Core 注册：[RV_Server_Commands.lua:389](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:389) |
| `Boundary.onObjectAdded`（L480） | `function(object)`，无返回 | Core 注册：[RV_Server_Commands.lua:390](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:390) |

- 加载合同：`require("RailroaderRV/DemolitionProtection/RV_BoundaryServer_Objects")(ctx)`，唯一调用方 [RV_BoundaryServer.lua:48](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer.lua:48)；ctx 的数值/调用/身份字段由 Geometry 在 L47 时先注入（Geometry L378-L387）。同包加载顺序是 Geometry → DemolitionProtection → Sweep。
- 事件语义（外部事实，影响本模块的失败模式）：Core 的 `dispatch` 对每个 handler 逐个 pcall，**首个失败即中止该事件后续 handler**（[RV_Server_Core.lua:55-L66](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server_Core.lua:55)）。因此本模块回调内部抛错只会中断同一事件链，不会崩溃引擎事件；但 `Objects` 之后注册的同事件 handler（如 RoomOwnership 的 scan）会因此被跳过。
- 本模块**不持有持久状态、不写 ModData 键以外的存档**：唯一的持久副作用是对象 ModData 的 tag（L309）；ledger 是进程内短期表。

### 直接读写其他模块的数据

**(a) 本模块访问其他模块的数据（文件:行）**

1. **`Boundary._tick` 读取 4 处、无写入**：L414、L436、L482、L493。写者：RV_BoundaryServer.lua L36（初始化，值取自 `Core.getTick()`）与 [RV_BoundaryServer_Sweep.lua:110](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Sweep.lua:110)（每 tick，`tick or Core.getTick()`，而注册处 `pcall(Boundary.onTick)` 不传参，见 RV_Server_Commands.lua L282）。这是**跨模块私有字段读取**（下划线前缀、无访问器）。
2. **`Boundary.boundaryForPlayer` 调用 2 处**：L380、L425。定义在 [RV_BoundaryServer_Geometry.lua:236](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Geometry.lua:236)，最终返回 `Boundary.boundaryFor(record)` 的 derived boundary（[RV_RailroaderServer_BoundaryValidation.lua:150/L166](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_RailroaderServer_BoundaryValidation.lua:150)）。属公开方法调用，不是私有访问。
3. **boundary 值对象字段直读**：`managed`（L82-L84、L131、L143-L144、L384-L385、L426-L427、L471-L473）、`shellEdges`（L90-L91、L131、L188、L224、L233、L248、L253、L273）、`rvId`/`generation`（L97-L100、L128-L129、L149-L150、L382-L383、L432-L433）。形状由 Geometry 的 `makeBoundary`（L197-L202）与 `encodeShellEdges`（L148-L174）生产，且**不持久化**（Geometry L205-L209 注释：managed/shellEdges 是模板的纯函数，读者按当前模板重新查询）。
4. **写 engine 对象的 ModData**：`data.RailroaderRV = {...}`（L309）。写入前经 `objectModData`（L288）取表、经 `rvTag`（L295）做覆盖保护；本文件是 canonical 命名空间的**第二个 writer**（另一个是 ServerWorld.tagObject，L206）。
5. **共享模块公开 API**：`TemplateGeometry`（L85、L143、L229、L231、L242-L245、L384、L426、L471）、`RoomTemplate`（L15-L16）、`Common.classInstance`（L134-L135）。属正常依赖。

**(b) 其他模块访问本模块 ledger 或其他状态（文件:行）**

1. **[RV_BoundaryServer_Sweep.lua:111-L113](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Sweep.lua:111)**：`local actionLedger = Boundary.builderActionLedger`；`type(actionLedger) == "table"` 才 `actionLedger.prune(Boundary._tick)`。**失败开放**：ledger 缺失只是不清理。
2. **[RV_RailroaderServer_EntryExit.lua:527-L533](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:527)**：取 `Boundary.builderActionLedger`，要求非 nil table、`invalidateForGeneration` 是函数、且调用结果严格 `== true`，否则 `return false, C.INVALID_RV_DATA`。**失败关闭**：字段或方法缺失即阻断本次 generation 的 mapping 提交。
3. **[RV_RailroaderServer_WallReload.lua:168/L182-L185](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/WallReloadProtection/RV_RailroaderServer_WallReload.lua:168)**：`type(Boundary.isCurrentShellWall) ~= "function"` 即放弃；调用走 pcall 并要求严格 `== true`，两个 record 同时匹配时放弃。**失败开放**。
4. **全树检索结论**：没有任何模块读取 `BuilderActionLedger.actions` 数据表本身（命中仅本文件 + 上述两个消费者）；`_builders` 在 `media/lua` 全树 **0 命中**（旧 phase2 报告 L94 的结论当前成立）；`Boundary.isCurrentShellWall` 无其他消费者（客户端也没有）。

**(c) 是否应改为接口（判断）**

- **ledger 表导出（L411）当前不必改为窄接口**：两个消费者只使用方法、不触碰 `actions`；赋值只发生一次（加载期），不存在引用失效或双写；EntryExit 的 fail-closed 判定依赖「方法存在且返回 true」这一合同，若改成 Boundary 上的包装函数，包装层必须复制同样的返回值语义（含「无匹配也返回 true」，L362），否则会让换代后无 action 的服务器永久无法提交 mapping。收益只是隐藏一个表引用，成本是多一层失败语义。**触发条件**：出现第 3 个消费者、或消费者开始读写 action 字段时，再按 phase2 报告 L62 的方向改为 `Boundary.pruneBuilderActionLedger(tick)` / `Boundary.invalidateBuilderActionsForGeneration(rvId, generation)`。
- **`Boundary._tick` 读取应当改掉（收益高于成本）**：本文件 L4 已捕获 `ctx.Core` 但当前无读取者，`Core.getTick` 是 Core 的公开方法（RV_Server_Core.lua L32/L92），且 `Boundary._tick` 本身就取自它（RV_BoundaryServer.lua L36、Sweep L110）。改用它可消除 4 处跨模块私有读取，且不需要任何新接口。语义差异有界（**条件性推断**）：`_tick` 是最近一次 `Boundary.onTick` 的快照，若某 tick 中 OnTick 链的前序 handler 抛错，`dispatch` 会提前返回（RV_Server_Core.lua L60-L66），`_tick` 可能落后一 tick 以上，使 2 tick 的 action 存活窗口略微延长；`Core.getTick()` 则始终是最新值。
- **不能用 Geometry 的 `stateFor` 替代 tick 探测**：`stateFor`（[RV_BoundaryServer_Geometry.lua:271-L282](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/BoundaryGuard/RV_BoundaryServer_Geometry.lua:271)）返回的是 `Boundary._states` 的 per-player 状态表，**不含 tick**，且缺失时会创建并写入 `Boundary._states[id.key]`（L276-L277）——读操作会改状态。因此以它作为「探测 Boundary 内部状态」的手段会引入副作用；本报告以源码行号复核确认该结论成立。
- **boundary 值对象字段直读不应改为逐字段 getter**：字段名即跨模块数据合同，且要从模板派生、不持久化；要收紧只能整体提供语义方法（而「对象是否当前 shell 构件」已经是 `isCurrentShellWall` 本身）。逐字段 getter 会与 Geometry 的派生实现重复，收益低于直接访问。

### 接口边界问题

1. **`_tick` 私有读取与「已捕获未使用的 Core」同时存在**（L414/L436/L482/L493 与 L4）：这是本模块唯一可零成本消除的隐藏状态依赖。同类的死捕获还有 L5 `C`、L11 `square`；其中 L11 之所以看似被使用，是因为 L141 的 `local x, y, z, square = objectCell(object)` 遮蔽了该 upvalue（L142 用的是 objectCell 的返回值）。建议：删掉 L5/L11 捕获，把 4 处 `Boundary._tick` 改为 `Core.getTick()`。
2. **canonical 命名空间有两个 writer、两种形状（本报告的核心接口判断）**。本文件 L309-L320 写 `{owner, playerBuilt, builder, rvId, generation, edgeKey, edgeKeys, footprint}`；ServerWorld 的 `tagObject`（L178-L211）写 owner/rvId/generation/role 并把身份字段放在 extraData 之后覆盖。**我的判断：这是「有身份门的登记项」，与既有审计结论一致**——写入前必须依次通过 (i) `boundaryForPlayer` 有效且坐标在 managed 内（L425-L428）、(ii) identity 非空（L429-L430）、(iii) modData 可写且 `action.rvId`/`generation` 合法（L288-L294）、(iv) 既有 tag 不接受跨 rv/generation 覆盖（L295-L302）、(v) 既有 tag 必须已是 `playerBuilt` 才允许重写（L303-L308），并且要么对象坐标与 action 的坐标或 shell edge 精确匹配（L469-L474），要么在 ledger 唯一候选 + boundary 身份复核通过之后（L374-L391）。因此不存在「仅凭客户端坐标即可写入归属」的路径。两点补充：
   - **(源码事实)** 两套形状的身份字段（owner/rvId/generation）是兼容的，`ServerWorld.isTaggedForGeneration`（L213-L222）会把 playerBuilt tag 视为本代 tagged 对象——这正是 L485-L491 注释期望的效果（自动删除要求当前 generation 的 playerBuilt tag）。
   - **(条件性推断)** 写入侧存在不对称：`rvTag`（L28）在 owner 不符时返回 nil，而 `markTagPlayerBuilt` 只在 `rvTag` 返回 table 时才做覆盖保护（L295-L308），因此一个携带 `RailroaderRV = {owner = "其他值"}`（或该键非 table）的对象，在唯一匹配的建造事件下会被整体改写成我们的 tag（L309）。当前仓库内 `owner` 只可能等于 `C.MOD_ID`（RV_BoundaryServer.lua L33、RV_ServerWorld.lua L8），该路径在本仓不可达；要收紧只需在写入前补一次 owner 判定。是否需要收紧取决于「是否有外部模组复用同一 ModData 键」这一仓外事实。
3. **`onProcessAction` 的动作名判定是子串匹配**（L416-L419：`string.find(actionText, "build"/"place"/"moveable", 1, true)`）。源码事实：任何包含这些子串的动作名（例如含 "place" 的 "replace"）都会进入记录分支。**条件性推断**：多记的 action 仍须通过 managed 范围（L426-L428）、ledger 唯一候选（L386-L387）、boundary 身份复核（L382-L383）与对象坐标/edge 精确匹配（L378、L474）才能产生 tag，故单独不能造成误打标；代价只是 ledger 中多出存活 2 tick 的条目。
4. **EntryExit 的 fail-closed 依赖使 ledger 形状成为跨包硬合同**（L527-L533）：改名、改成 getter、或让 `invalidateForGeneration` 返回非 true（除参数非法外）都会阻断 generation 的 mapping 提交。注意 L362「无匹配也返回 true」是刻意的——否则换代后没有待失效 action 的服务器会永久无法提交 mapping。任何重构必须保持该返回值语义。
5. **同一个 ledger 表在 Sweep 是失败开放、在 EntryExit 是失败关闭**（L112 与 L528-L532）：不是缺陷，因为后果不同（不清理只是短期意图多活 2 tick；不失效则跨代误归属会导致新代对象被旧代 intent 打标），但应在 ledger 文档中显式声明这两种缺失语义。
6. **`isCurrentShellWall` 的 boundary 形状要求与当前生产者一致**（源码事实）：它要求 `managed` 与 `shellEdges` 均为 table（L130-L131）；WallReload 传入的是 `Boundary.boundaryFor(record)`（Geometry L197-L202 的 derived boundary，含两者），`boundaryForPlayer` 最终返回同一形状（BoundaryValidation L150/L166）。因此旧报告中「registered view 缺 managed 会让 shellEdgeAllowed 恒 false」的担心在当前源码**不成立**。条件依赖：adapter 提供的 `current` 必须带 `managed`，否则 Geometry L253 的 `anchorFromManaged(current.managed, Template)` 会让 `boundaryForPlayer` 直接返回 nil（失败关闭），本模块的建造关联也随之整体静默——这是"外部模块合同"而非本文件缺陷。
7. **`Boundary.isCurrentShellWall` 的参数合同未在文档层声明**：它接受「本代 derived boundary」，而不是 record 或 player；WallReload 用 `boundaryFor(record)` 直传（L183）是唯一当前用法。若将来有调用方传 `boundaryForPlayer` 的返回值，也同样成立（同一形状），但传 record 会在 L128-L133 直接 false——属可接受的失败关闭，只是接口语义目前只体现在代码里。

## 函数清单、覆盖和验证记录

- **扫描文件**：DemolitionProtection/ 目录经目录列举与 glob 确认只含 `RV_BoundaryServer_Objects.lua`，**504 行**；`media/lua` 全树中 require 该路径的只有 RV_BoundaryServer.lua L48 一处。
- **函数清单（机械核对）**：`function` 关键字全行扫描命中 **23** 行，逐行核对**全部是定义**；本文件 **0** 处 `type(x) == "function"` 比较行、**0** 条含 "function" 字样的注释行，故 23 = 定义数 = 本报告表格条目数。分解：13 个 `local function` + 9 个表方法（Boundary 3、BuilderActionLedger 6）+ 1 个匿名模块工厂（L2）；无全局具名函数、无作为参数/回调传入的匿名函数表达式（本文件不传回调）。23 个函数**全部有当前调用者**（跨模块 4 个：isCurrentShellWall、builderActionLedger 上的 prune 与 invalidateForGeneration、两个 Core 注册回调；其余为本文件内部消费）。
- **函数索引（文件 TAB 起始行 TAB 名称 TAB kind；kind ∈ named/local/method/anon，本文件 named = 0）**：
  - `RV_BoundaryServer_Objects.lua	2	(anonymous module factory)	anon`
  - `RV_BoundaryServer_Objects.lua	18	objectModData	local`
  - `RV_BoundaryServer_Objects.lua	25	rvTag	local`
  - `RV_BoundaryServer_Objects.lua	34	objectSquare	local`
  - `RV_BoundaryServer_Objects.lua	40	objectCell	local`
  - `RV_BoundaryServer_Objects.lua	58	shellEdgeHasTemplateIndex	local`
  - `RV_BoundaryServer_Objects.lua	80	shellEdgeAllowed	local`
  - `RV_BoundaryServer_Objects.lua	123	Boundary.isCurrentShellWall	method`
  - `RV_BoundaryServer_Objects.lua	201	appendShellEdgeKey	local`
  - `RV_BoundaryServer_Objects.lua	207	shellAxisMatches	local`
  - `RV_BoundaryServer_Objects.lua	222	shellEdgeKeysForAction	local`
  - `RV_BoundaryServer_Objects.lua	264	actionMatchesObject	local`
  - `RV_BoundaryServer_Objects.lua	287	markTagPlayerBuilt	local`
  - `RV_BoundaryServer_Objects.lua	324	commandArgument	local`
  - `RV_BoundaryServer_Objects.lua	330	commandCoordinate	local`
  - `RV_BoundaryServer_Objects.lua	337	BuilderActionLedger.prune	method`
  - `RV_BoundaryServer_Objects.lua	348	BuilderActionLedger.invalidateForGeneration	method`
  - `RV_BoundaryServer_Objects.lua	365	BuilderActionLedger.submit	method`
  - `RV_BoundaryServer_Objects.lua	374	BuilderActionLedger.uniqueCandidate	method`
  - `RV_BoundaryServer_Objects.lua	394	BuilderActionLedger.objectMatchConsumed	method`
  - `RV_BoundaryServer_Objects.lua	399	BuilderActionLedger.consumeObjectMatch	method`
  - `RV_BoundaryServer_Objects.lua	413	Boundary.onProcessAction	method`
  - `RV_BoundaryServer_Objects.lua	480	Boundary.onObjectAdded	method`
- **逐行交叉核对**：带行号读取全文 504 行；表格中的所有起始行取自本次读取的当前版本。旧版报告的 25 函数/约 665 行口径以及 `footprint`、`sameOwner`、`removeObject`、`protectedWorldObject`、`auditObject`、`isDisallowedPlayerBuild`、`shellHostOwnershipUnknown`、`Boundary._builders` 在当前源码中**已不存在**（`media/lua` 全树检索：`_builders`、`auditObject`、`isDisallowedPlayerBuild`、`sameOwner`、`shellHostOwnershipUnknown` 均 0 命中；`protectedWorldObject` 仅保留在 [RV_Server_TemplateProtectionRepair.lua:286](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/TemplateRecovery/RV_Server_TemplateProtectionRepair.lua:286)，与本模块无关）。
- **跨模块扫描**：在 `contents/mods/RailroaderRV/42/media/lua` 全树检索 `builderActionLedger`、`BuilderActionLedger`、`_builders`、`_tick`、`isCurrentShellWall`、`boundaryForPlayer`、`Boundary.boundaryFor`、`_states`、`RailroaderRV`（tag 读写点）、`local function objectModData/objectCell/commandArgument` 等符号，结论见接口与复用章节；`_tick` 命中已逐条区分「本模块读取」与「BoundaryGuard 写入/其他模块自有 *_TICKS 常量」。
- **未覆盖项 / 条件性推断**：未运行游戏、服务器或任何测试脚本；未穷举 PZ engine 传给 `OnProcessAction` 的 args 容器 Java 形状（本报告只按 `call(args,"get",key)` 的合同推断）；「`_tick` 改为 `Core.getTick()` 的净收益」「拆出 ledger 的收益」「外来 owner 被覆盖的实际风险」「动作名子串误匹配的实际频率」均为**条件性推断**，未做改造或运行时实验；adapter 返回 boundary 必带 `managed`/`shellEdges` 的结论由 RV_RailroaderServer_BoundaryValidation.lua L150/L166 与 Geometry L193-L202/L253 的调用链推断，未在所有分支逐一验证。
- **修改范围**：仅重写本分析文档；未修改任何 Lua 源码、配置或测试文件，未运行任何测试。
