# server/RailroaderRV 根目录模块分析
> **状态（RailroaderRV 1.0）**：本文件是静态审计记录；其行号、计数和源码结论并非本次发布的全量重核，也不是运行时验证。当前实现以 [源码](../../contents/mods/RailroaderRV/42/) 与 [README](../../README.md) 为准，项目约束以 [agents.md](../../../agents.md) 为准。历史建议不构成修复授权，采纳前须按现行约束重新取证。

## 假设、范围、成功条件与验证方式

- **假设**：本报告的"本层"仅指 `contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/` **直接包含**的文件，不含子目录。子目录（Core/、Common/、RVMapping/、BoundaryGuard/、Construction/、RoomTemplate 等）的逐函数分析由各自模块报告负责；本报告只做只读的路径级与符号级核对，用来支撑结论。
- **范围**：只读静态分析，**不修改任何 Lua 源码、配置或测试文件，不运行游戏、服务器或任何测试脚本**。核对对象为本层文件清单、本层是否存在函数定义，以及全 `42/media/lua` 范围内对两个旧根路径入口的 `require` 引用和当前模块加载路径约定。
- **成功条件**：如实记录本层当前的文件构成与函数定义数；说明旧报告描述的两个转发入口的现状；用可复核的检索证据说明是否还有 `RailroaderRV/RV_Server` / `RailroaderRV/RV_RailroaderServer` 的 require 引用，以及模块加载是否改走 `RailroaderRV/Core/...`；不得虚构当前不存在的文件。
- **验证方式**：`Get-ChildItem -Recurse -Force -File` 枚举本层全部文件；`ReadAllText` + 正则对整个 `42/media/lua` 树做**跨行安全**的引号字符串穷举（不依赖逐行匹配，避免漏掉换行断开的 `require(\n "…")`）；另用逐行检索核对符号级引用。结论均为源码事实；无法由静态分析确定的边界（PZ 加载器的目录扫描行为）在下文显式标注为未验证项。

## 目录职责与清单

本层**当前不含任何 Lua 文件**。目录内唯一的常规文件是 `agent.md`（2,442 字节）——一份 Markdown 职责说明，不是代码，也不是模块。旧报告 `server-root.md` 描述的两个转发入口 `RV_Server.lua` 与 `RV_RailroaderServer.lua` **已在本轮之前的精简中从本目录删除**，其实现全部归入 `Core/`。

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| [agent.md](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/agent.md) | 0 | 非代码文件：为 `server/RailroaderRV/` 各子目录划分职责边界，并明确"实现归属各自模块目录下的文件、不在这些目录旁放扁平转发入口" |
| **总计** | **0** | 本层 0 个 Lua 文件、0 个函数定义；Lua 实现全部位于 `Core/` 等子目录 |

`agent.md` 与"转发入口"相关的原文证据在其第 8 行：`Implementation ownership stays with the file under its module directory; no flat forwarding entries sit beside these folders.` 这与本轮目录状态一致。

## 逐文件、逐函数分析

本层没有 Lua 文件，因此**没有任何函数可分析**：不存在具名函数、`local function`、表方法、模块加载闭包或匿名回调。下表的表头按要求列全，但内容为空（无条目）。

| 函数（起始行） | 参数、返回/副作用、本模块语义 | 当前功能是否必须及原因 |
|---|---|---|
| （无） | 本层不含 Lua 源文件，无函数定义可列举。 | 不适用：不存在函数，因此不存在必要性判断对象。 |

### agent.md（非 Lua 文件，仅登记不分析）

`agent.md` 是职责说明文档，全文 8 行（第 1 行为标题 `# RailroaderRV server Lua`，第 2–8 行为 7 条列表项），内容涉及各子目录的职责划分、生成流程的阶段约束与"不添加重复 schema 检查/兼容/迁移路径"的约定。它不参与运行、不定义任何符号、不被任何 Lua 代码 require，因此不产生函数条目，也不构成对外接口。

### 旧报告条目的处置（如实记录，不虚构）

旧 `server-root.md` 记录的两个文件在当前目录中**已不存在**，其在该报告中的全部行号引用（`RV_Server.lua:1`、`RV_RailroaderServer.lua:1`，以及"目标第 220 行/第 147 行/第 139–145 行"等）对应的是精简前的代码，**在当前源码中无对应物**：

| 旧报告文件 | 旧报告描述 | 当前状态 | 实现归属 |
|---|---|---|---|
| `media/lua/server/RailroaderRV/RV_Server.lua` | 一行转发器 `return require("RailroaderRV/Core/RV_Server")` | **已删除，目录中无此文件** | [Core/RV_Server.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server.lua)（152 行） |
| `media/lua/server/RailroaderRV/RV_RailroaderServer.lua` | 一行转发器 `return require("RailroaderRV/Core/RV_RailroaderServer")` | **已删除，目录中无此文件** | [Core/RV_RailroaderServer.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_RailroaderServer.lua)（119 行） |

因此本层**无函数可分析、无接口可列举、无隐藏状态可审查**；旧报告中关于"保留根路径转发以兼容外部消费者"的建议在当前代码状态下已无对象可保护——转发文件本身已不存在，若确实需要根路径别名，必须重新创建文件，而不是"保留"。

### 全树 require 引用核对（本次实际检索）

- **检索范围**：`contents/mods/RailroaderRV/42/media/lua` 下全部 `*.lua`（client / server / shared 三棵树）。
- **两段式根路径入口引用**：对正则 `"RailroaderRV/(RV_[A-Za-z_]+)"`（**对整个文件内容**匹配，可跨行）穷举，命中 **0 处**。即**当前不存在任何** `require("RailroaderRV/RV_Server")` 或 `require("RailroaderRV/RV_RailroaderServer")` 的引用，既没有显式调用，也没有字符串形式的残留。
- **三棵树内的全部 `"RailroaderRV/..."` 模块路径**共 63 个唯一值，**全部是三段式**（`RailroaderRV/<子目录>/<文件>`），没有任何一段式或两段式的模块路径。按子目录归类：
  - `Core/`（7）：`RV_RailroaderServer`、`RV_RailroaderServer_Sentinel`、`RV_RailroaderServer_Tick`、`RV_Server_Commands`、`RV_Server_Core`、`RV_UtilityServer`、`RV_UtilityStore`；
  - `Common/`（9）、`Construction/`（7）、`RVMapping/`（5）、`BoundaryGuard/`（4）、`Water/`（6）、`Power/`（4）、`RoomTemplate/`（4）、`GUI/`（10）、`TemplateRecovery/`（2）、`WallReloadProtection/`（2）、`RoofRefresh/`（1）、`RoomOwnership/`（1）、`DemolitionProtection/`（1）。
- **结论（源码事实）**：模块加载**已经改走 `RailroaderRV/Core/...` 路径**。两个旧根路径入口在树内没有消费者。
- **附带事实**：`Core/RV_Server.lua` 本身**没有被任何 `require` 引用**（上表 `Core/` 的 7 个路径中不含 `RailroaderRV/Core/RV_Server`）。它只依赖 PZ 对 `media/lua/server/**` 的目录扫描被自动执行，从而创建 `RV.Server` facade；反向的 `require` 只有 `Core/RV_Server.lua:150` → `RailroaderRV/Core/RV_Server_Commands`、`:64` → `RailroaderRV/Core/RV_RailroaderServer`、`:84` → `RailroaderRV/Core/RV_UtilityServer` 等装配链。对照之下，`Core/RV_RailroaderServer.lua` 是被显式 require 的（`Core/RV_Server.lua:63-64`、`Core/RV_Server_Commands.lua:401-402`）。

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- 本层**没有代码**，因此不存在可提取的共用函数、重复实现或可收敛的多份规则。
- 旧报告提出的"两个一行转发器的公共模式"（固定目标路径的 require 结果原样返回）在当前代码中**已不存在实体**：转发器被删除后，这个模式既没有实现，也没有调用者，不属于可提取对象。
- 与"提取"相反的结论成立：本目录的正确形态是**空实现层**。`agent.md:8` 已把它写成显式约定（实现归属模块目录、不放扁平转发入口）。若要恢复根路径别名，那是**新增兼容层**的决策，需先证明存在树外消费者，而不是复用收益问题。

### 是否进一步拆分

- **不适用**：本层无文件可拆。0 个 Lua 文件不存在边界划分、职责重叠或文件过长问题。
- 需要拆分评估的对象在子目录：`Core/` 内 8 个文件、`Construction/` 内 7 个文件等。这些拆分判断由对应模块报告负责（`Core/` 见 [server-Core.md](server-Core.md)），不在本层范围内。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- 本层**不导出任何接口**：没有模块表、没有全局符号赋值、没有 `return` 表达式，也没有事件注册。删除两个转发器之后，根路径不再提供任何 `require` 目标。
- 当前对外可用的服务端契约全部由子目录提供：
  - `RV.Server` facade 由 [Core/RV_Server.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_Server.lua) 创建（`RV.Server = RV.Server or {}`，第 74 行）并由多个子模块追加方法；
  - `RailroaderRV.RailroaderServer` adapter 由 [Core/RV_RailroaderServer.lua](../../contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/Core/RV_RailroaderServer.lua) 创建（第 32–35 行）并返回（第 119 行）；
  - `RailroaderRV.Constants` 由 `shared/RailroaderRV/Common/RV_Constants.lua` 提供，服务端各模块经 `RailroaderRV/Common/RV_Constants` 加载。
- 若树外的某个模组或脚本装载约定仍按 `RailroaderRV/RV_Server` 或 `RailroaderRV/RV_RailroaderServer` 取模块，当前会得到加载失败（PZ 的 `require` 找不到文件）。**这是条件性推断**：本次检索只能证明**仓库内**没有消费者，无法证明树外不存在消费者；而 PZ 加载器是否会为本层自动执行任何文件属于运行时行为，未做验证。

### 直接读写其他模块的数据

- 本层**没有代码**，因此不存在直接读写其他模块内部数据的位置：没有下划线字段访问、没有模块私有状态表访问、没有 ModData 访问、没有 `ctx` 组合对象的使用。
- 反向核对：其他模块也没有写回本层——本层没有任何可被写入的表或全局名。旧报告中"两个转发器通过返回目标模块对象保留既有接口"的描述，对应的是已删除的文件，不构成当前的接口边界。

### 接口边界问题

1. **删除转发器后的根路径兼容性成为"纯外部问题"。** 树内已无消费者（检索证据见上节），因此删除本身在仓库范围内没有破坏点；风险面只剩树外模组或装载约定。**建议**：如果项目确认不存在树外消费者（例如发布物只含本模组包），应把 `agent.md:8` 的约定视为已落实并在 `README.md` 记录该移除；如果存在树外消费者，则必须显式重建两个一行转发器并为其写一条说明，而不是依赖"曾经存在"。
2. **`Core/RV_Server.lua` 只能靠目录扫描被加载，是被显式 require 的兄弟文件所不具备的隐式前提。** 源码事实：全树没有 `require("RailroaderRV/Core/RV_Server")`，而 `Core/RV_RailroaderServer.lua` 会被 `Core/RV_Server.lua:63-64` 与 `Core/RV_Server_Commands.lua:401-402` 显式 require。**条件性推断（未做运行时验证）**：若某个环境下 PZ 不自动执行 `media/lua/server/**` 的模块文件，`RV.Server` 将从不被创建，`Core/RV_RailroaderServer.lua` 的 `installTransactionGate` 也会因缺少 facade 而无法生效。**建议**：为 `RV.Server` 的创建增加一条显式的被 require 路径（例如让 `Core/RV_Server_Commands.lua` 或 adapter 在需要时 `require("RailroaderRV/Core/RV_Server")`），可消除这条隐式加载前提。
3. **`agent.md` 与实际目录状态已一致，不存在文档漂移。** 本次核对未发现本层文档与文件系统状态矛盾；不需要"外键校验、键集合校验或迁移脚本"来维持这份一致性（`agent.md` 自身也明确不添加重复检查与迁移路径）。

## 函数清单、覆盖和验证记录

- **扫描目录**：`contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/`（仅直接子文件，不含子目录）。`Get-ChildItem -Recurse -Force -File` 的顶层结果**仅 1 个文件**：`agent.md`（2,442 字节）。
- **扫描函数**：本层 Lua 文件数 0，函数定义数 **0**。按题目口径（具名函数、`local function`、表方法、作为参数/回调的匿名函数表达式）逐类核对，均无命中；不存在"零行文件"或"只有注释的 Lua 文件"这类中间状态——目录里根本没有 `.lua` 文件。
- **引用核对**：对 `42/media/lua` 全树 3 棵子树做跨行安全的引号字符串穷举，`"RailroaderRV/RV_Server"` 与 `"RailroaderRV/RV_RailroaderServer"` 命中 **0 处**；全部 63 个 `"RailroaderRV/…"` 路径均为三段式 `RailroaderRV/<子目录>/<文件>`；`Core/` 下的 7 个路径已在上文列出。
- **文档验证**：本报告列出本层 1 个文件（非代码）及 0 个函数条目；旧报告 `server-root.md` 描述的两个转发文件已被如实标注为"本轮之前已删除、实现归 Core/"，未虚构任何当前不存在的文件或行号。
- **未覆盖/未解决项**：树外模组或外部脚本装载约定对本层旧路径的依赖无法由静态检索证明或排除；PZ 加载器是否自动执行 `media/lua/server/**` 属运行时行为，本报告未验证，只在"接口边界问题 #2"中作为条件性推断列出。
- **修改范围**：仅重写本分析文档；**未修改任何 Lua 源码、配置或测试文件；未运行游戏、服务器或任何测试脚本**。
