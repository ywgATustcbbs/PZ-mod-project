# tests

结构：`test_rv_server.py` 为标准库 Python 静态与纯契约测试；Lua 语法检查使用项目内
`.rv-lua-parse/node_modules/.bin/luaparse.cmd`，不依赖游戏运行时；项目禁用 PowerShell 测试脚本。

职责：快速检查当前房间/对象生成阶段的固定 `(20050,2050,0)` anchor、由服务端优先选择居中上边缘 `(anchorX, clearMinY-1)` 并排除保存旧/新 footprint 的 staging 传送、服务端与客户端使用相同 staging 坐标、传送前仅用 `isValidSquare` 的目标/footprint 合法性预检及其先于 Relocate/`teleportTo` 的顺序、严格闭区间 `x=20000..20100`、
`y=2000..2100` 的 101×101 清场布局、入口拒绝条件、空 payload 的规范 `nil` 路径，以及普通 Lua
table/B42 `PZNetKahluaTableImpl` 双分支、UTF-8 服务器启动链、传送后已加载区域等待（缺失方格为无异常可重试状态）、重复锁和回滚不变量；
同时检查远端传送前不访问目标方格、加载等待期间不清理且硬超时取消、服务端与客户端双端撤离、
token-only 回执、跨 tick/超时/身份/权限/到达复核，以及固定 plan 不被客户端坐标覆盖；
同时断言 stale-room guard 在清除旧 generation 前向所有客户端广播并在服务端登记，使用已包含
6x40 室内的旧/新完整 7x41 墙矩形与 6x40 屋顶 footprint（禁止冗余 interior loop/de-dup no-op），只对 `room!=nil && RoomDef==nil` 调用
`setRoomID(-1)`，保留有效新房 room，并具有稳定 tick、硬超时和多 generation 清理；
并回归验证 RelocateAck 后服务端位置首次不匹配只等待、不生成且不取消，精确到达后才生成，
以及等待期间的超时、断线、身份变化、存活和权限检查仍安全取消；
房间/对象生成调用必须在清场成功门控之后启用；不应有 `PLAYER_METAL_FLOOR`/整片金属地板阶段，
但仍应生成 6×40 `floors_interior_carpet_01_5` 地板、7×41 墙环和对象；测试应锁定
`walls_interior_house_03_20/21` 直墙对及 tile-definition 查证的 `..._22` NW、`..._23` SE
角条，不得以未查证编号替代；并精确断言 staging 期间玩家不在危险 footprint、`FinalRelocate` 处理器在本地 teleport 前同步清 stale-room，及 `buildGeneration` 成功后、`READY` 提交前发送
`FinalRelocate` 到 `(20050.5,2050.5,0)`，最终命令不进入初次 token-only ack。测试精确断言清场失败会短路、生成或最终传送失败进入既有 generation 回滚路径。最终运行时联机验证仍由游戏环境完成。

运行：`python RailroaderRVTest/tests/test_rv_server.py`。

兼容性：测试脚本只使用 Python 标准库；读取仓库文本时接受 UTF-8 与 UTF-8 BOM，且不启动
服务器或游戏。后续新增静态断言应保持无运行时副作用。
