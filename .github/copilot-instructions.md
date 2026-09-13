# Global Copilot Rules

## RailroaderRVTest 开发期存档 schema 强制要求

RailroaderRVTest 开发期 MUST 只支持当前代码声明的 manifest、bitmap、shell
ledger、RV mapping 与异步身份 schema。任何缺失或不匹配都必须拒绝当前 RV
操作，并明确通知用户删除该测试存档并重建。MUST NOT 自动迁移、转换、别名兼容、
推断旧字段、使用旧 bounds、自动删除/修改旧存档，或用不兼容数据执行 geometry、
对象清理、传送和 boundary guard。新建空容器按当前 schema 初始化不算迁移；未来
兼容需求必须由用户另行明确授权。
全部编码任务强制
1. 先读并遵守 karpathy-guidelines
2. 先想后写，只做最小正确改动，只改需求直接相关内容
3. 先给可验证成功条件；多步任务给简计划并做验证
4. 保持现有风格，避免无关重构/抽象/投机扩展
5. 不确定先停，说明假设与分歧，必要时提问

# Karpathy Guidelines

1. Think before coding: 显式写出假设、分歧、取舍；不清楚先停再问
2. Simplicity first: 只写解决当前问题的最少代码，禁止投机扩展
3. Surgical changes: 只改必要内容，匹配现有风格，只清理自己造成的残留
4. Goal-driven: 先定义成功条件与验证方式，改完必须验证
