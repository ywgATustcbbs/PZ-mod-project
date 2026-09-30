# server/RailroaderRV 根目录模块分析

## 假设、范围与验收标准

- **假设：** 本报告的“本层”仅指 contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/ 直接包含的 Lua 文件。Core/ 等子目录由其他模块报告负责；同时只读查看转发目标和相关引用代码，作为返回接口与调用关系证据，但不将它们纳入本层文件清单或逐函数评审。
- **范围：** 只读静态分析，不修改 Lua 源码，不运行游戏、服务器或测试。目录直属文件清单为 RV_Server.lua、RV_RailroaderServer.lua。
- **成功标准：** 两个直属文件都被逐一登记；逐项说明其顶层调用的参数、返回值、加载副作用、当前用途与边界；检查函数定义和回调；给出精确行号与可复核调用证据；说明复用、拆分、跨模块数据访问和接口建议。
- **只读核对方式：** 用 Get-ChildItem -File -Filter '*.lua' 枚举直属文件；带行号读取每个文件；在模组源码中搜索两个顶层 require 路径，并检查被转发目标和一个相关调用点。没有进行运行时验证。

## 文件与模块清单

| 文件 | 本层职责 | 本文件定义的函数 |
|---|---|---|
| media/lua/server/RailroaderRV/RV_Server.lua | RV_Server 兼容/入口转发模块 | 无 |
| media/lua/server/RailroaderRV/RV_RailroaderServer.lua | RV_RailroaderServer 兼容/入口转发模块 | 无 |

两个文件都只有一条顶层 return require(...) 表达式。没有具名函数、函数赋值、嵌套函数、匿名回调或其他 Lua 语句；因此不存在本目录函数参数或函数级返回/副作用可逐项分析。以下按唯一顶层调用说明其参数与模块级结果。

## 逐文件分析

### RV_Server.lua

- **行 1：** return require("RailroaderRV/Core/RV_Server")
- **参数：** 一个固定字符串 RailroaderRV/Core/RV_Server，作为 Lua/PZ 模块路径；不接受调用者传入的运行时参数。
- **输出：** 原样返回目标 Core/RV_Server 模块的加载结果。目标文件在 [Core/RV_Server.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server.lua:220) 的第 220 行返回 RV.Server，因此正常加载时此入口向调用者暴露同一个 server facade 表。
- **副作用：** 执行目标模块及其加载链。目标在第 206–218 行将 ctx 传给屋顶所有权、建筑生成、玩家验证、清单验证、屋顶迁移、生成确认和命令等子模块；本包装文件本身不再修改结果。
- **本层语义与必要性：** 为根路径保留一个稳定的服务端入口，并把实际实现留在 Core/。仓库 Lua 源码中未找到 require("RailroaderRV/RV_Server") 的显式调用，所以静态证据不能证明仓库内部仍依赖此别名；外部模组、脚本装载约定或历史路径兼容仍可能依赖它。建议保留，除非另有证据确认这些入口消费者均不存在。其唯一表达式对转发功能是必要的；没有证据支持在这里增加逻辑。

### RV_RailroaderServer.lua

- **行 1：** return require("RailroaderRV/Core/RV_RailroaderServer")
- **参数：** 一个固定字符串 RailroaderRV/Core/RV_RailroaderServer；本文件没有函数参数。
- **输出：** 原样返回目标 Core/RV_RailroaderServer 的加载结果。目标第 34–37 行取得/创建 RailroaderRV.RailroaderServer 作为 Adapter，第 147 行返回该表；客户端专用进程由目标第 24–26 行短路并返回空表时，本入口也会原样转发空表。
- **副作用：** 执行适配器目标及其模块安装链。目标第 139–145 行把共享 ctx 传入 Train、Mapping、EntryExit、Sentinel、RoofRefresh 与 Tick 等子模块。
- **本层语义与必要性：** 提供根路径别名，指向独立的 Railroader 适配器。仓库中未发现 require("RailroaderRV/RV_RailroaderServer") 显式调用；现有命令代码在 [Core/RV_Server_Commands.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/Core/RV_Server_Commands.lua:300) 第 300–301 行通过 pcall(require, "RailroaderRV/Core/RV_RailroaderServer") 直接加载 Core 目标，并在第 302–306 行处理失败或安装接口。由此可确认仓库的该调用路径不依赖本别名，但仍不能排除外部消费者或加载器入口。建议保留根路径转发，直到入口兼容性被单独确认；本层转发表达式是此别名唯一的功能。

## 模块比较、复用与拆分

- 两个文件共享的只有“固定目标路径的 require 结果原样返回”这一行模式，目标和所暴露的模块 API 不同。把它抽成通用帮助函数会新增一层依赖和调用，却不减少有意义的行为重复；复用收益很低。
- 这两个文件不应再拆分：每个已是单一职责的一行转发器。目标实现的职责拆分由 Core/ 与其他子目录模块承担，不属于本目录范围。

## 跨模块访问与接口

- 本层没有读取或写入目标模块的局部变量、表字段或内部状态；唯一依赖是模块路径和目标模块的返回值。调用 require 会触发目标初始化，但这属于模块装载边界，不是直接访问目标内部数据。
- 两个转发器已通过返回目标模块对象保留其既有接口：RV.Server facade 与 RailroaderRV.RailroaderServer adapter。若额外包装或筛减导出内容，会改变对象/接口身份，当前看不出收益。
- 根目录内无其他共享算法、状态处理或回调可提取。本结论只覆盖两个包装器；目标模块之间的 ctx 内部状态共享需在其所属目录报告中审查。

## 调用证据与覆盖核对

- [RV_Server.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_Server.lua:1) 第 1 行转发至 Core/RV_Server；目标第 220 行返回 RV.Server。
- [RV_RailroaderServer.lua](../../contents/mods/RailroaderRVTest/42/media/lua/server/RailroaderRV/RV_RailroaderServer.lua:1) 第 1 行转发至 Core/RV_RailroaderServer；目标第 147 行返回 Adapter，第 139–145 行安装其功能子模块。
- 全模组 Lua 源码对精确字符串 require("RailroaderRV/RV_Server") 与 require("RailroaderRV/RV_RailroaderServer") 的搜索均无结果。相关的内部适配器调用证据为 Core/RV_Server_Commands.lua:300–306，其使用 Core 路径并将加载作为可选步骤处理。
- 直属文件核对结果为 **2 个 Lua 文件**，均已覆盖；子目录文件未纳入本报告。
- **未覆盖/未解决：** 静态源码不能确定 Project Zomboid 加载器是否会自动执行这两个根路径文件，也不能发现外部模组对它们的调用；未做运行时验证。其作为入口别名的外部必要性因此保留为待确认项。

