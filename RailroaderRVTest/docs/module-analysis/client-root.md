# client/RailroaderRV（根目录）模块分析

## 假设、范围、成功条件与验证方式

- **假设**：模块范围是 `contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/` 的**直接子级文件**（不含 `GUI/` 子目录）；`GUI/` 的逐函数分析属于 [client-GUI.md](client-GUI.md)。行号与文件清单以本次读取的当前版本为准。
- **范围**：只读枚举该目录当前全部条目（含隐藏项），并记录其是否含 Lua 代码；为核实入口引用，对 `42/media/lua` 全树搜索模块路径 `RailroaderRV/RV_ContextMenu` 与文件名 `RV_ContextMenu`。不修改任何 Lua 源码，不运行游戏或测试，唯一写入目标是本报告。
- **成功条件**：如实记录当前目录内容与"本层无函数可分析"的原因；明确标注旧报告描述的 `RV_ContextMenu.lua` 转发入口已在本轮之前的精简中删除、实现归属 `GUI/RV_ContextMenu.lua`；给出模块路径引用搜索结果；不虚构当前不存在的文件。
- **验证方式**：PowerShell 目录枚举（含 `-Force`）、递归 `.lua` 计数、agent.md 行数与 `function` 关键字扫描、`42/media/lua` 全树路径搜索；完成后检查报告的文件清单、引用路径与结论一致性。源码扫描是静态分析，不替代运行时验证。

## 目录职责与清单

目录 `client/RailroaderRV/` 当前**只有 1 个子目录和 1 个非 Lua 文件，没有任何 `.lua` 文件**：

```text
client/RailroaderRV/
  GUI/          （目录，含 11 个 .lua 文件，见 client-GUI.md）
  agent.md      （2033 字节，Markdown 工作区说明，非 Lua、不参与加载）
```

| 文件 | 函数定义数 | 主要职责 |
|---|---:|---|
| （无 `.lua` 文件） | 0 | 本层当前不含任何 Lua 代码，因此没有可分析的函数、导出或隐藏状态 |
| [agent.md](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/agent.md) | 0 | 工作区说明文件（Markdown）：描述 `GUI/` 的职责边界、`RV_BoundaryClient.lua`/`RV_UtilityClient.lua` 的定位、房间归属与迁移两个模块的约束，以及 Kahlua 环境不提供全局 `next` 的兼容要求；不是 Lua 代码，不计入函数清单 |
| **总计** | **0** | 本层无函数定义 |

## 逐文件、逐函数分析

**本层没有 `.lua` 文件，因此没有 `### 文件名.lua` 函数小节，也没有函数表可列。** 这不是"未分析"，而是目录当前的实际内容：旧的转发入口已被删除，实现全部位于 `GUI/` 子目录，本报告不对 `GUI/` 内函数重复列表（见 [client-GUI.md](client-GUI.md) 的 11 个文件、269 个函数条目）。

### 无 Lua 文件（本层无函数可分析）

- 目录枚举结果（含隐藏项）：仅 `GUI`（目录）与 `agent.md`（文件），无其它条目。
- 递归统计 `client/RailroaderRV/` 下的 `.lua` 文件：11 个，全部位于 `GUI/` 子目录；根目录自身为 0 个。
- 因此本层不存在具名函数、`local function`、表方法、匿名回调或模块导出值。

### agent.md（非 Lua 文件，不计入函数清单）

- **源码事实**：8 行 Markdown；正文出现 `function` 一词 1 次（第 8 行英文描述 "does not provide the global `next` function"），按 Lua 定义扫描口径（`function` 后接可选名字与左括号）命中 **0** 次；文件内无 Lua 语句、无 `require`、无函数定义。
- **本模块语义**：这是给后续 agent 的工作区约束说明，不是运行时代码；它不被 `require`，也不会被 Lua 加载器当作脚本执行。
- **必要性判断**：**保留理由**——它承载 `GUI/` 的边界约定（哪些模块负责哪些行为、Kahlua 兼容要求），删除会丢失本层的上下文；但它**不是**本层模块的公开接口，不能被任何 Lua 代码依赖。

### 旧报告描述的文件：已删除的转发入口

- 旧 [client-root.md](client-root.md) 记录的 `client/RailroaderRV/RV_ContextMenu.lua`（单行 `return require("RailroaderRV/GUI/RV_ContextMenu")`）**当前不存在**。按本轮任务给定的整理事实，该转发入口**已在本轮之前的精简中被删除**；本报告以当前目录枚举为准，不以旧报告的行号或文件内容作为现状依据。
- 该文件此前只做一件事：把 `RailroaderRV/GUI/RV_ContextMenu` 的返回值原样再导出。菜单与迁移的真实实现一直在 `GUI/RV_ContextMenu.lua`（当前 73 行、0 个函数定义，是客户端组合根：加载依赖、组装 `ctx`、调用两个职责工厂、返回 `RailroaderRV.Client`，见 [RV_ContextMenu.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:52)）。
- **职责归属结论**：转发入口删除后，客户端 GUI 的实现归属仍是 `GUI/`，没有代码迁移到根目录，也没有新增根目录入口文件。

## 模块间复用、提取和职责拆分

### 已有共用与可提取机会

- **本层没有可提取的实现**：目录内无 Lua 文件，既没有重复逻辑，也没有可复用的 helper、常量或状态表。
- **不需要"恢复转发入口"这一层复用**：被删除的文件只是模块路径别名，本身不含逻辑。全树搜索显示模块路径 `RailroaderRV/RV_ContextMenu` 当前**零引用**（详见"公开合同"），因此恢复它不会带来任何消费者收益，只会重新引入一条无调用方的模块路径。
- **值得保留的"复用"是加载方式本身**：`GUI/` 下的 11 个文件互相之间只通过 4 条显式 `require` 组合（[RV_ContextMenu.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:9)-L13、:70-L71 与 [RV_ContextMenu_Relocation.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua:440)、:447 的加载期 require），其余文件靠自己注册事件生效。目录内已有的可提取候选（安全调用包装、`text` 本地化、玩家身份解析、菜单去重、渲染隐藏、`validGenerationFinalHint` 双份实现等）全部记录在 [client-GUI.md](client-GUI.md) 第 4 节，本层不重复。

### 是否进一步拆分

- **本层无文件可拆**：根目录只剩说明文件与子目录，没有可拆分的代码单元。
- **不建议在根目录新增"再导出一层"的文件**：PZ 客户端 Lua 加载器按 `media/lua/client` 目录执行文件，**没有**任何模组内 `require` 依赖根目录路径；新增别名文件只会增加一条无人引用的路径和一次无意义的模块加载。
- **反向建议（供全局结构判断）**：`GUI/` 自身是否拆分见 [client-GUI.md](client-GUI.md) 第 4 节；本轮结论是仅 `RV_RailroaderContextMenu.lua`（719 行）与 `RV_UtilityDashboard.lua`（582 行）有拆分讨论价值，`RV_ContextMenu.lua` 作为 0 函数的薄组合根应保持最小。

## 对外接口、跨模块数据访问与隐藏状态

### 公开合同

- **本层不导出任何 API**：目录内没有 `.lua` 文件，因此没有返回值、没有写入 `RailroaderRV` 全局表的字段、没有事件处理器注册。
- **被移除的旧合同**：模块路径 `RailroaderRV/RV_ContextMenu` 曾返回 `GUI/RV_ContextMenu` 的导出值（即 `RailroaderRV.Client` 表，见 [RV_ContextMenu.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:73)）。该别名当前不可再被 `require`。
- **引用搜索结论（源码事实）**：在 `contents/mods/RailroaderRVTest/42/media/lua` 全树搜索字符串 `RailroaderRV/RV_ContextMenu`：**0 命中**。搜索裸文件名 `RV_ContextMenu` 共 9 处命中，全部是"指向 `GUI/` 文件"的引用，没有一处引用根目录模块路径：
  - [RV_ContextMenu.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:70)-L71 对 `RailroaderRV/GUI/RV_ContextMenu_RoomOwnership` 与 `RailroaderRV/GUI/RV_ContextMenu_Relocation` 的工厂 require；
  - [RV_ContextMenu_RoomOwnership.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_RoomOwnership.lua:1)、[RV_ContextMenu_Relocation.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua:1)、:438、[RV_RailroaderContextMenu.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:494)、:503 的注释文本；
  - [agent.md](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/agent.md:6)-L7 对 `GUI/RV_ContextMenu_RoomOwnership.lua`/`GUI/RV_ContextMenu_Relocation.lua` 的说明。
- **GUI 文件的加载来源（条件性推断）**：既然模组内没有任何 Lua 文件 `require` `RailroaderRV/GUI/RV_ContextMenu`（或其它 GUI 路径的入口聚合文件），`GUI/` 下的文件只能由游戏客户端 Lua 加载器按 `media/lua/client` 目录自动执行；这是对当前目录结构与全树 `require` 搜索结果的推断，**未经运行游戏验证**。

### 直接读写其他模块的数据

- **无访问点**：本层没有 Lua 代码，因此不存在对 `RailroaderRV.Constants`、`GUI/` 内部表、服务端 wire payload 字段、world object ModData tag 或 Railroader 官方表（`RR.Ride`/`RR.TrainEntity`/`RR.BoardMenu`/`AnimalContextMenu`）的读写。
- **核验方式**：目录枚举确认无 `.lua` 文件；`agent.md` 内无 `require` 与字段访问语句。`GUI/` 内的跨模块数据访问位置逐条列在 [client-GUI.md](client-GUI.md) 第 5 节。
- **旧报告的对应结论已失效**：旧报告在该章节讨论的是"转发文件原样导出被依赖模块返回值"，属于对已删除文件的描述，不能作为当前接口边界的证据。

### 接口边界问题

- **模块路径别名消失，且模组内无消费者**：删除 `client/RailroaderRV/RV_ContextMenu.lua` 后，任何按旧路径 `require("RailroaderRV/RV_ContextMenu")` 的调用都会失败。模组 Lua 树内没有这样的调用（0 命中），因此当前不存在破坏点；但**若有模组外脚本或文档/约定依赖该路径，本仓库内无法证明其存在**。若确实需要保留对外路径，应显式恢复并通过 `GUI/` 的稳定导出定义它，而不是长期保留一个无人引用的文件。
- **旧报告的行号与结构引用不可再用**：旧 [client-root.md](client-root.md) 以"1 行文件"为前提，并引用 `GUI/RV_ContextMenu.lua:76-77` 作为两个职责模块的调用位置；当前 [RV_ContextMenu.lua](../../contents/mods/RailroaderRVTest/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu.lua:70) 的实际调用位置是 L70-L71，文件共 73 行。任何引用旧行号的文档都需要按当前版本更新。
- **本层与 `GUI/` 的边界需要在文档层保持明确**：根目录承担"工作区说明"，`GUI/` 承担全部客户端实现。新增客户端代码应放进 `GUI/`（或 `GUI/` 内新建的职责文件），不要为了"入口"而在根目录再造转发文件。

## 函数清单、覆盖和验证记录

- **扫描文件**：`client/RailroaderRV/` 直接子级条目 2 个——`GUI`（目录）与 `agent.md`（文件）；递归 `.lua` 文件 11 个，全部位于 `GUI/`。直接子级 `.lua` 文件数：**0**。
- **扫描函数计数**：本层函数定义数 **0**（无具名函数、无 `local function`、无表方法、无匿名函数表达式、无导出别名）。`agent.md` 的 `function` 关键字出现 1 次，按定义口径命中 0 次（英文描述，不是 Lua 代码）。
- **逐行交叉核对**：逐行读取 `agent.md` 全部 8 行；确认无 Lua 语句、无 `require`、无函数定义。目录清单用 `Get-ChildItem -Force` 枚举（含隐藏项）核对，无遗漏条目。
- **跨模块调用扫描**：在 `42/media/lua` 全树搜索 `RailroaderRV/RV_ContextMenu`（0 命中）与 `RV_ContextMenu`（9 命中，全部指向 `GUI/` 文件或 `agent.md` 文档），用于确认旧入口的引用面与当前实现的归属。
- **文档验证**：本报告记录的目录内容、`.lua` 计数（0）、函数计数（0）与引用搜索结果均由上述命令输出直接支撑；同时明确指出旧报告描述的 `RV_ContextMenu.lua` 已被删除，不再作为现状依据。
- **未覆盖项**：未运行游戏/服务器/runtime 测试；未验证 PZ 客户端 Lua 加载器对 `media/lua/client` 子目录的实际加载顺序（属条件性推断）；未审计模组外部（其它模组、外部脚本或文档）是否依赖旧模块路径 `RailroaderRV/RV_ContextMenu`；`GUI/` 内 11 个文件、269 个函数的逐条分析不在本报告范围（见 [client-GUI.md](client-GUI.md)）。
- **修改范围**：仅重写本分析文档与 [client-GUI.md](client-GUI.md)；未修改任何 Lua 源码、配置或测试文件，未运行测试。
