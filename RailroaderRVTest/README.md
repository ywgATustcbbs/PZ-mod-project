# RailroaderRVTest

RailroaderRVTest 是 Railroader RV 的内部技术验证包，不承诺对外功能。Lua 命名空间为
RailroaderRV；当前技术版本以 mod.info 和共享常量中的声明为准。

## 设计与安全边界

路线和房屋由服务端按需程序化生成，不内置地图。客户端只提交操作意图；服务端验证玩家、
权限、请求阶段和当前存档身份，负责世界修改、同步与失败回滚。

固定生成锚点为 (20050,2050,0)。RV 管理 XY 范围是半开区间
x=[20000,20100)、y=[2000,2100)，各 Z 层的布局、移动和建造判定由当前 bitmap 定义。
技术验证会清除该管理范围内的既有对象，选址前应确认范围内没有需要保留的内容。
服务端确认目标管理范围完整加载后才清场和生成；未完整加载时不做部分清场，也不生成路线、房屋或对象。

房屋净室内为 6×40，外墙为 7×41 墙环，屋顶为上层 6×40 地板。bitmap 是格子的最终
判定；AABB 只用于遍历。范围外不执行边界拦截或清理。

边界修正由服务端按当前 RV 身份和 bitmap 判定。建造审计只删除能够由当前 RV 身份、
完整 footprint 和 build bitmap 明确归属的对象；归属不明时保留。shell ledger 用于识别
当前墙边，不会重建玩家拆掉的墙。外墙变化触发的 roof refresh 由服务端核验当前身份和
几何，协调在场玩家临时离开、修复及权威回传；不信任客户端坐标。

## 开发期存档规则

只接受当前代码声明的 manifest、bitmap、shell ledger、RV mapping、异步身份和水电
schema。缺失、过期、部分写入或字段结构不符时，立即拒绝当前 RV 操作并提示删除测试
存档后重建；不得用旧数据生成 geometry、清理对象、运行 boundary guard 或传送玩家。
不自动迁移、转换、推断、兼容别名或修改旧存档。只有完全空的新容器可以按当前 schema
初始化。

## 水电事实源

水量只有一份服务端 canonicalTank.amount。隐藏 usage tank 和 fixture proxy
只是投影镜像，不是余额事实源，也不接受雨水自动补给。两种隐藏对象当前均以
IsoThumpable 创建，并通过 transmitAddObjectToSquare 附着和发送。

generator 原生对象是燃油与 condition 的唯一事实源；RV 水电记录不保存第二份燃油余额。

## 验证状态

本包包含程序化房屋、边界与建造审计、roof refresh 和水电管理代码。静态检查不能替代游戏
内联机验证。

2026-09-15 的历史人工测试曾报告拆墙、进出和补墙成功，但东/南墙格可建地板、东墙格可建
北墙仍待未来实机复核。当前源码包含相应 host 处理，尚无实机证据确认问题已解决。后续
人工测试不要要求用户提供客户端界面无法显示的实际坐标。

## 源包与导航

本地源包根目录为 RailroaderRVTest/，模组目录为
contents/mods/RailroaderRVTest/42/；media/lua/client/ 放客户端菜单与表现，
media/lua/server/ 放服务端玩法和世界操作，media/lua/shared/ 放共享契约；
tests/ 放静态检查。

照明灯依赖运行时启用的 BuildingCraft（Workshop ID 3459887404）提供灯具图集和 tile
definition；本包不复制其资源。workshop.txt 有意留空 Workshop ID，发布前由 Workshop
流程分配。游戏基线只以根目录
game-decompiled/42.20.4/metadata.txt 为事实源，本 README 不重复版本数字。
