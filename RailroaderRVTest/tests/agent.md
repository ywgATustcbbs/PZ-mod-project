# tests

结构：`test_rv_server.py` 为标准库 Python 静态与纯契约测试；Lua 语法检查使用项目内
`.rv-lua-parse/node_modules/.bin/luaparse.cmd`，不依赖游戏运行时；项目禁用 PowerShell 测试脚本。

职责：快速检查当前房间/对象生成阶段的固定 `(20050,2050,0)` anchor、由当前 layout/bitmap 管理 scope 中心计算且固定为 `z=-15` 的首次 generation staging 传送（不再使用边缘点）、服务端与客户端使用相同 staging 坐标、传送前仅用 `isValidSquare` 的目标/footprint 合法性预检及其先于 Relocate/`teleportTo` 的顺序、严格半开区间 `x=[20000,20100)`、
`y=[2000,2100)` 的 100×100 清场布局、入口拒绝条件、空 payload 的规范 `nil` 路径，以及普通 Lua
table/B42 `PZNetKahluaTableImpl` 双分支、UTF-8 服务器启动链、传送后已加载区域等待（缺失方格为无异常可重试状态）、重复锁和回滚不变量；
同时检查远端传送前不访问目标方格、加载等待期间不清理且硬超时取消、服务端与客户端双端撤离、
token-only 回执、跨 tick/超时/身份/权限/到达复核，以及固定 plan 不被客户端坐标覆盖；
同时断言 stale-room guard 在清除旧 generation 前向所有客户端广播并在服务端登记；已有 RV
entry 与 presence/reconnect 还必须由服务端按当前 manifest/mapping identity 定向重发，使用已包含
6x40 室内的旧/新完整 7x41 墙矩形与 6x40 屋顶 footprint（禁止冗余 interior loop/de-dup no-op），只对 `room!=nil && RoomDef==nil` 调用
`setRoomID(-1)`，保留有效新房 room；客户端 monitor 在稳定 warm-up 后仍以完整
`rvId:generation:bitmapVersion` identity 持续每 tick 扫描，以覆盖 READY 后的异步墙/地板移除；
静态契约还检查同进程掉线后的 stable-identity 续租/受控重发、完整 geometry cache 失效、
无状态哨兵的字符串诊断，以及 generation 临时阶段本地“正在生成房车”提示的周期刷新；
服务端拆墙回归还必须断言当前 42.20.4 的 `SledgehammerDestroyPacket` 服务端链通过
`OnObjectAboutToBeRemoved`，仅匹配当前 `IsoThumpable` 墙 tag 与 shell ledger；
`OnDestroyIsoThumpable` 只能作为同一严格匹配的直接销毁补充入口。两条事件按完整房间 key
去抖并启动 `queued → temporary → repairing → returning → complete` 状态机；先将玩家移到
当前 boundary bitmap 声明的 100×100 managed scope 中心与固定实验层
`ROOF_REPAIR_TEMP_Z=-15`，确认离开房间 geometry 且目标/相关方格已加载，再按
到达后的 5/10/15 server ticks 安排三次 roof repair。roof refresh 使用当前 bitmap 中心减去
`(18000,0,15)`，首次 generation staging 与此远点契约严格区分；generation 临时阶段客户端使用
本地常量显示“正在生成房车”，roof 临时阶段使用本地 roof 提示，均不信任任意网络文本；
只执行服务端坐标与 token-only ACK；修复后返回服务端事先捕获的合法 RV 位置。若事件未暴露，
30-tick authoritative presence 流程检测当前 RV 内 player square 的 inside→outside transition
后安排同一事务。每次尝试都必须重验 current schema、完整 identity、relation、online identity、scope
与 authoritative inside player，不得退化为客户端坐标或永久 0.5 秒无条件强制刷新；
同 x/y 改 z 不视为 chunk unload/reload，跨 chunk 仅列为第一阶段失败后的后续实验；
`OnTileRemoved` 不作为服务端 sledge packet 唯一入口；
服务端 generation guard 仍具有稳定 tick、硬超时和多 generation 清理；每个 relocation 在首次
`Relocate`/`teleportTo` 前只保存在服务进程内存，稳定 identity 与精确原坐标用于同进程掉线
重连回传；服务器重启不恢复该事务。玩家仍在 `z=-15` 时不得清理上下文或以 repair
成功掩盖回传失败，回传重试不设耗尽清理；并断言 return-before-repair 门、稳定 follow-up
墙事件队列、无状态 `z=-15` 哨兵以及 current-only exact-field 验证；
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

存档 schema 只测当前版本 gate：legacy/migration/alias/fallback 转换路径必须不存在；
schema mismatch 或 identity 缺失必须返回删档重建提示。不得新增旧存档兼容测试。
