# client

结构：`RailroaderRV/` 客户端上下文菜单、请求入口与服务端定向撤离桥。

职责：发送无坐标、空参数的生成意图；接受初次 `Relocate` 后将服务端选定且位于旧/新
结构 footprint 外的 staging 坐标应用到匹配本地玩家，并只回传无坐标 token。建造完成后
接受独立 `FinalRelocate` 入室命令，在处理器内同步清理 `room!=nil && RoomDef==nil`
引用后，将服务端选定的 `(20050.5,2050.5,0)` 应用到本地玩家，不发送 ack，也不把
最终命令混入初次 pending relocation。客户端不提交可信世界状态、不执行世界生成。
