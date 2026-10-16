# 问题 #30：对象安全描述符分配失败导致访问检查 fail-open

## 1. 问题编号

`30`

## 2. 问题位置

- 文件路径：`src/ob/object.zig`、`src/se/security_descriptor.zig`
- 函数/模块：`ObjectHeader`、`createObject`、`checkObjectAccess`、`SECURITY_DESCRIPTOR.initDefault`
- 行号或代码片段：原实现用 `std.heap.page_allocator.create(se.ObjectSecurity)`；失败时 `security == null`，`checkObjectAccess` 直接返回 true。`initDefault` 还动态分配 ACL，失败时保留 `dacl_present = true` 但 `dacl == null`，访问检查同样返回 true。

## 3. 问题描述

内核 freestanding 目标中的页分配器是显式空实现，默认安全描述符和 ACL 分配会失败。由于失败路径被解释为“无安全描述符，允许完全访问”，普通调用方可获得本应受限的对象访问权。

## 4. 复现路径

在 freestanding 内核中创建进程或线程对象，随后以非 SYSTEM、非提权 Token 调用 `openProcess(..., GENERIC_ALL)` 等对象访问检查；安全描述符为 null 或 DACL 为 null 时检查通过。

## 5. 影响范围

影响对象管理器的权限边界，尤其是进程打开、线程打开和后续句柄访问检查。可导致越权访问进程/线程句柄、句柄复制和内存操作接口滥用，破坏安全隔离。

## 6. 严重程度

Critical

## 7. 可能原因

将资源分配失败与“对象没有安全描述符”混用；默认 DACL 使用运行时堆分配，未与内核无堆约束匹配；`checkObjectAccess` 对空安全描述符采用 fail-open。

## 8. 权威参考依据

- Windows 安全描述符访问检查语义：DACL 存在但检查失败时应拒绝；空 DACL（NULL DACL）才表示允许所有人。该依据来自 Microsoft 公开安全描述符/DACL 文档语义。
- 本次修复来自源码审计和 freestanding 构建约束审查，未将 REA 二进制分析结论作为修复依据；未执行 `ntoskrnl.exe` 对应函数级对照。

## 9. 建议修复方案

已将默认 DACL 改为编译期常量表，`SECURITY_DESCRIPTOR` 持有只读 ACL 指针，消除默认安全路径的运行时分配和泄漏。`ObjectHeader` 增加内联 `security_storage` 与 `ensureDefaultSecurity`；`createObject` 不再分配安全描述符。`checkObjectAccess` 在缺少安全描述符时改为拒绝访问，避免 fail-open。同时将 `findAcesForSid` 改为调用方提供输出缓冲，移除隐藏堆分配。

## 10. 验证方法

现有安全描述符测试验证 SYSTEM/管理员获得完全访问、普通用户读访问通过但写访问被拒绝、NULL DACL 显式允许全部访问。新增检查应覆盖 `createObject` 后 `security != null`、普通 Token 对默认对象的写访问被拒绝，以及 freestanding 构建不再依赖页分配器。

## 11. 状态

Fixed

## 12. 修复验证记录

- `zig build test` 通过。
- `zig build -Darch=x86_64` 通过。
- REA 与 Windows 7 镜像逐函数对照：未执行。

