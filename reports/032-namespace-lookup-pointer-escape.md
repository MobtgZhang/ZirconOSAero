# 问题 #32：命名空间查找返回锁保护槽位的裸指针

## 1. 问题编号

`32`

## 2. 问题位置

- 文件路径：`src/ob/object.zig`
- 函数/模块：`lookupNamespace`、`NamespaceEntry`、`namespace_lock`
- 行号或代码片段：修复前 `lookupNamespace` 在 `namespace_lock.unlock()` 后返回 `?*NamespaceEntry`，调用方继续读取 `obj_type`、`object_ptr`、`link_target` 等字段。

## 3. 问题描述

`lookupNamespace` 使用 `IrqSpinLock` 保护命名空间数组，但返回的是静态槽位指针。锁释放后，另一个 CPU 可以执行 `removeNamespace`、`insertNamespace` 或 `initNamespace`，从而重置、复用或整体清空同一个槽位。调用方随后读取的指针可能指向已被复用的条目，导致打开错误对象类型或错误对象指针。

## 4. 复现路径

1. CPU A 调用 `lookupNamespace("\\BaseNamedObjects\\Example")` 并获得 `NamespaceEntry` 指针。
2. CPU A 尚未读取 `object_ptr`。
3. CPU B 调用 `removeNamespace("\\BaseNamedObjects\\Example")` 后用同名 `insertNamespace` 插入不同对象。
4. CPU A 读取原指针指向的字段，可能看到新条目的 `obj_type` 和 `object_ptr`。
5. 若 `initNamespace` 被调用，原指针还会指向被批量重置的存储区。

## 5. 影响范围

- 对象管理器：可能用错误对象指针分配句柄。
- IPC 与命名对象：`NtOpenEvent`、`NtOpenMutant`、`NtOpenSemaphore` 可能打开错误对象。
- 目录对象：`NtOpenDirectoryObject` 可能对错误类型返回句柄。
- 并发安全：造成数据竞争和类型混淆。
- 稳定性：极端情况下可能解引用无效或错误的对象指针。

## 6. 严重程度

- High

## 7. 可能原因

查找函数把“锁内定位”和“锁外读取”合并在同一个返回值中，但没有定义调用方持有的生命周期契约。命名空间槽位是可复用的静态存储，不能把裸指针作为快照交给调用方。

## 8. 权威参考依据

- 公开 NT 对象管理器语义：命名对象路径由 Object Manager 解析，命名条目与对象打开操作存在同步关系；Microsoft Learn 的 Kernel Object Manager 和 object namespaces 文档描述了路径解析与安全打开的整体模型。
- Zig 并发语义：受自旋锁保护的共享存储在锁释放后不应继续以裸指针访问。
- ReactOS 兼容性判断：ReactOS 公开文档也把命名对象打开描述为受对象管理器同步保护的路径操作；本修复未复制 ReactOS 源码。
- REA 镜像对照：本条未执行 Windows 7 `ntoskrnl.exe` 中命名空间查找函数的 REA 函数级分析。当前 REA 快照只有 `ExFlushLookasideListEx` 与 `ExInterlockedPopEntryList` 两个函数级记录，不足以支撑本路径的镜像逐函数结论。
- `/home/mobtgzhang/api.json`：该文件是 REA provider 配置，不是 Windows API 文档；本条未从中提取行为依据。

## 9. 建议修复方案

将 `lookupNamespace` 返回类型从 `?*NamespaceEntry` 改为 `?NamespaceEntry`，在 `namespace_lock` 释放前返回完整值拷贝。调用方继续只读取 `obj_type`、`object_ptr`、`link_target` 等快照字段；修改命名空间仍必须通过 `insertNamespace` / `removeNamespace` 等锁保护接口。

修复后不再存在锁外访问命名空间槽位的数据竞争路径；打开命名对象时使用的是锁保护瞬间的类型与对象指针快照。

## 10. 验证方法

- 新增主机测试 `namespace lookup returns detached snapshot`：先插入对象指针 `0x1100`，取得快照，删除并复用同名条目为 `0x2200`，验证快照仍保留 `0x1100`，当前查找返回 `0x2200`。
- 执行 `zig build test`。
- 执行 `zig build -Darch=x86_64`。
- 后续多核 QEMU 压力验证应覆盖并发插入、删除和打开同名命名对象。

## 11. 状态

- Fixed

## 12. 修复记录与二进制对照结论

已修复文件：

- `src/ob/object.zig:496`
- `tests/host/zircon_host_ob_test.zig:237`

验证结果：主机测试通过；x86-64 构建通过；`git diff --check` 通过。

与原始二进制对照结论：**未对照**。当前 REA 快照没有 Object Manager 命名空间查找、插入、删除或相关 `Obp` 路径的函数级记录。结论限定为“已消除源码级锁外指针逃逸并符合公开 NT 语义方向；与 Windows 7 镜像逐函数等价性待 REA 验证”。
