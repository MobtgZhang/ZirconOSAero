# 执行体 Phase 3 子里程碑（PROCESS_NT61 对齐）

本文档将 [PROCESS_NT61.md](PROCESS_NT61.md) 中的 Phase 3 拆成可验收的子阶段，便于分 PR 推进。实现须保持 **原创代码**；行为可参考公开文档，禁止复制微软或泄漏源码。

## M3.1 — 对象与句柄

- **目标**：句柄分配/关闭与对象头 `ref_count` / `handle_count` 一致；按类型注册表可观测。
- **相关源码**：[`src/ob/object.zig`](../../src/ob/object.zig)、[`src/ps/process.zig`](../../src/ps/process.zig)。
- **验收**：同一进程内 `allocHandle` / `closeHandle` / `lookupHandle` 路径可测；无双重释放。

## M3.2 — 安全引用监视器与访问检查

- **目标**：令牌权限与句柄 `granted_access` 在打开对象时一并考虑（当前为可组合 API，逐步接入调用点）。
- **相关源码**：[`src/se/token.zig`](../../src/se/token.zig)（`checkAccess`、`checkHandleAccess`）。
- **验收**：非提升令牌对受保护对象返回拒绝的单元路径（随测试框架补充）。

## M3.3 — I/O 管理器与驱动栈

- **目标**：IRP 经设备对象分派；与文件系统打开路径协同。
- **相关源码**：[`src/io/io.zig`](../../src/io/io.zig)、[`src/fs/vfs.zig`](../../src/fs/vfs.zig)（`dispatchFileObjectIr`）。
- **验收**：`NtReadFile` / `NtWriteFile` / `NtClose` 经 `Irp` 调用 `vfs.read` / `write` / `close` 并写回 `IO_STATUS_BLOCK`。

## M3.4 — LPC / 端口与用户态 IPC

- **目标**：命名端口创建、连接与 `RequestWaitReply` 与内核 syscall 一致（见 x86_64 `SYS_CREATE_PORT` / `SYS_CONNECT_PORT`）；`NtRequestWaitReplyPort` 使用端口 **id** 解析服务端 `owner_pid`。
- **相关源码**：[`src/lpc/port.zig`](../../src/lpc/port.zig)、[`src/lpc/ipc.zig`](../../src/lpc/ipc.zig)、[`src/arch/x86_64/syscall.zig`](../../src/arch/x86_64/syscall.zig)。
- **验收**：两进程（或内核自测）经端口名完成一次往返消息。

## M3.5 — 注册表与 Native API 桩

- **目标**：`NtOpenKey` / `NtQueryValueKey` 等与 [`src/registry/registry.zig`](../../src/registry/registry.zig) 行为一致；错误码与 `NTSTATUS` 约定统一。
- **相关源码**：[`src/libs/ntdll.zig`](../../src/libs/ntdll.zig)、[`src/registry/registry.zig`](../../src/registry/registry.zig)。
- **验收**：`\Registry\Machine\...` 路径可打开；`KeyValuePartialInformation` 可读出内置值；未找到键/值返回 `STATUS_OBJECT_NAME_NOT_FOUND`；缓冲区不足返回 `STATUS_BUFFER_TOO_SMALL`。

## 依赖顺序

```text
M3.1 句柄/对象 → M3.2 安全检查 → M3.3 I/O ↔ VFS
                     ↘ M3.4 LPC / syscall
                     ↘ M3.5 注册表 / ntdll
```
