# LPC 与 Win32 子系统握手 ABI（NT 6.1 目标）

本文件描述 ZirconOSAero 内核中 **LPC 端口** 与用户态 **csrss / Win32** 之间的 clean-room 约定；行为对齐 Microsoft 公开文档中的 **端口、连接、报文** 概念，**不**对照 Windows/ReactOS 源码实现。

**分阶段里程碑**（已实现 vs 长期）：与 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) §9.2 **csrss 风格子系统与 LPC 里程碑** 交叉引用；本文侧重握手字段与 `PortKind`，不表示完整 csrss 协议已完成。

## 命名与端口类型

- **服务器端口**：`NtCreatePort` 创建，由服务进程持有；名称经 `OBJECT_ATTRIBUTES` / `UNICODE_STRING` 传入（见 [src/lpc/port.zig](../../src/lpc/port.zig)）。
- **客户端连接**：`NtConnectPort` 按名查找已注册端口并建立客户端侧句柄。
- **请求-应答**：`NtRequestWaitReplyPort`（路线图扩展）须与 **单消息边界**、超时语义一致；当前未实现路径在 syscall 层返回 `STATUS_NOT_IMPLEMENTED`。

## 与子系统（csrss）的字段握手

- 端口对象上与大消息 / 节区视图相关的字段（如 `section_view_handle`）为 **占位**；与 [src/mm/section.zig](../../src/mm/section.zig) 映射就绪后，须在本文与 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 同步更新 **视图 token 或基址编码** 规则。
- **字节序与对齐**：报文缓冲按 **小端**、自然对齐；固定头长度变更时递增 **握手版本常量**（建议在 `port.zig` 或单独 `lpc_abi.zig` 中以 `comptime` 声明）。

## 验证

- 连接/创建路径：见 [MVT_NT61.md](MVT_NT61.md) 中 CI 与用户态用例（随测试增加而扩充）。
- `PortKind` 枚举底层值（`message = 0`、`connection_listener = 1`）由主机测试 **lpc_portkind_host** 固定；修改 `src/lpc/port.zig` 时须同步更新 [tests/lpc_portkind_host.zig](../../tests/lpc_portkind_host.zig)。
- 回归：对 `NtCreatePort` / `NtConnectPort` 的修改须保持 `zig build test` 与现有 syscall 分发探测（用户指针 `probe`）不回归。
