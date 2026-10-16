# 问题 #31：文件对象在 NtClose 时泄漏打开槽位并提前触发重复关闭

## 1. 问题编号

`31`

## 2. 问题位置

- 文件路径：`src/libs/ntdll.zig`、`src/fs/vfs.zig`、`src/ob/object.zig`、`src/ob/cleanup_hooks.zig`
- 函数/模块：`NtClose`、`vfs.openEx`、`vfs.close`、`HandleTable.closeHandle`
- 行号或代码片段：修复前 `NtClose` 在 `closeHandle()` 前无条件向 `.file` 对象发送 `IRP major_function = .close`；`vfs.close()` 只设置 `is_open = false`；`vfs.openEx()` 只能使用 `files[file_count]` 追加新槽位。

## 3. 问题描述

`NtCreateFile` / `NtOpenFile` 先通过 `vfs.openEx()` 分配并保持 `FileObject.is_open = true`，再在句柄表中登记。`NtClose` 原实现没有判断是否为最后一个句柄，就向文件对象发送关闭 IRP；同时 `HandleTable.closeHandle()` 也没有为 `.file` 类型调用真正的 VFS 关闭回收路径。结果包括：

1. 同一文件对象存在重复句柄时，第一次 `NtClose` 会提前执行 `vfs.close()`；
2. 最后一次 `NtClose` 只释放句柄表槽位，`FileObject.is_open` 仍保持已关闭状态，但 VFS 槽位不会被重新分配；
3. 连续打开关闭文件最终耗尽 `MAX_OPEN_FILES`。

## 4. 复现路径

1. 初始化 VFS 并挂载一个可用文件系统。
2. 通过 `NtCreateFile` 或 `NtOpenFile` 获得文件句柄。
3. 对同一句柄表中的同一对象复制句柄，或重复执行“打开、关闭”若干次。
4. 观察重复句柄首次关闭即触发关闭 IRP，以及 `vfs.getFileCount()` 与可打开文件数在多次关闭后不恢复。

## 5. 影响范围

- 文件系统层：打开文件槽位泄漏，长运行进程可能达到 128 个文件对象上限。
- I/O 路径：重复句柄关闭会提前发出 cleanup/close 语义，可能破坏文件驱动状态。
- 对象管理器：文件对象生命周期与句柄引用计数不一致。
- 兼容性：偏离 NT 中文件对象在最后引用释放后才完成清理的通用模型。
- 稳定性：文件句柄反复打开关闭的服务或 Shell 程序可能逐渐无法打开新文件。

## 6. 严重程度

- High

## 7. 可能原因

对象管理器此前只给 Section 类型接入了最后引用回调，文件类型缺少等价的 last-reference 钩子。VFS 的槽位数组也没有从“追加索引”改为“活跃对象计数 + 空槽复用”。`NtClose` 又把句柄关闭和文件对象关闭混在一个前置路径中，导致重复句柄提前触发关闭。

## 8. 权威参考依据

- 公开 NT/Win32 语义：`CloseHandle` 关闭调用进程中的句柄；文件驱动清理与关闭的生命周期由对象引用决定，重复句柄不应使其他有效句柄提前失效。参考 Microsoft Learn 的 `CloseHandle`、`CreateFile`、Kernel-mode Driver Architecture 与 IRP 主要功能描述。
- ReactOS 兼容性判断：ReactOS 公开文档描述的 Object Manager 句柄表和 I/O 生命周期与上述 NT 语义一致；本修复未复制 ReactOS 代码。
- REA 镜像对照：本条未对 Windows 7 镜像中的 `NtClose` 做函数级反汇编对比。当前 REA 快照只有 `ExFlushLookasideListEx` 与 `ExInterlockedPopEntryList` 两个函数级记录，不足以支撑 `NtClose` 逐指令结论。因此本报告基于源码审计和公开 NT 语义，修复保持最小行为兼容方向，未声称与镜像逐指令等价。
- `/home/mobtgzhang/api.json`：该文件是 REA 的 provider 配置，不是 Windows API 文档，本条未从中提取 API 行为依据。

## 9. 建议修复方案

1. 在 `cleanup_hooks` 中增加 `file_last_reference` 回调，并在 VFS 初始化时注册。
2. `HandleTable.closeHandle()` 在文件对象引用计数降为最后一个引用时调用该回调。
3. VFS 回调通过既有文件对象 IRP 分发路径执行关闭，保留卷设备栈路径。
4. `NtClose()` 删除文件对象的前置无条件关闭 IRP，避免重复句柄提前关闭。
5. VFS 槽位分配改为扫描空闲槽位，`vfs.close()` 在成功进入关闭路径时递减活跃文件计数，`init()` 重置全部文件槽位。

修复后，重复句柄关闭只释放句柄表引用；最后一个句柄关闭时才进入 VFS cleanup/close；关闭后的文件槽位可再次分配。

## 10. 验证方法

- 新增主机测试 `file last reference invokes cleanup hook`，验证 `.file` 对象引用计数降到最后一个引用时回调被调用且参数正确。
- 执行 `zig build test`。
- 执行 `zig build -Darch=x86_64`、`zig build -Darch=aarch64`、`zig build -Darch=riscv64`、`zig build -Darch=loongarch64`。
- 后续 QEMU 系统级验证应覆盖：打开文件、复制句柄、关闭第一个句柄后继续读写，再关闭最后句柄；以及循环打开关闭同一文件后确认新文件仍可打开。

## 11. 状态

- Fixed

## 12. 修复记录与二进制对照结论

已修复文件：

- `src/ob/cleanup_hooks.zig:31`
- `src/ob/object.zig:279`
- `src/fs/vfs.zig:344`
- `src/fs/vfs.zig:455`
- `src/fs/vfs.zig:508`
- `src/fs/vfs.zig:527`
- `src/libs/ntdll.zig:1284`
- `tests/host/zircon_host_ob_test.zig:100`

验证结果：主机测试通过；x86-64、aarch64、riscv64、loongarch64 构建通过；`git diff --check` 通过。

与原始二进制对照结论：**未对照**。原因是现有 REA 快照没有 `NtClose`、`ObpCloseHandleTableEntry` 或 I/O cleanup 的函数级记录。当前结论为“已修复源码生命周期缺陷，行为方向与公开 NT 语义一致；与 Windows 7 镜像逐函数等价性待 REA 验证”。
