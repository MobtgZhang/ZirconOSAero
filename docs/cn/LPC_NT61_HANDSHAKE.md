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
- **csrss 同步应答**：`opcode` 在 `0x10000..0x1FFFF`（`CsrApiNumber`）且已注册 `port.setCsrRequestHandler` 时，`NtRequestWaitReplyPort` 在同内核模型下由回调直接构造 `ipc.Message` 应答（`data[0..4]` 为 `i32` 状态码），无需异步服务线程。
- **节区视图与大消息**：`Port.section_view_handle` 与 `NtMapViewOfSection` 返回 token 的绑定规则仍以 [MM_Section_Roadmap.md](MM_Section_Roadmap.md) 为准；窗口相关大 payload 须在 bump 握手版本后写入本文与契约矩阵。
- **csrss GUI 小消息布局**：`post_message` / `get_message` 固定字段偏移与 `subsystem.handleApiCall` 一致；主机 **`csr_lpc_policy_host`**、**`win32k_api_semantics_host`** 与 [src/subsystems/win32/csr_lpc_policy.zig](../../src/subsystems/win32/csr_lpc_policy.zig) 中 `post_message_*_off` / `get_message_*_off` 同步。

## 验证

- 连接/创建路径：见 [MVT_NT61.md](MVT_NT61.md) 中 CI 与用户态用例（随测试增加而扩充）。
- `PortKind` 枚举底层值（`message = 0`、`connection_listener = 1`）由主机测试 **lpc_portkind_host** 固定；修改 `src/lpc/port.zig` 时须同步更新 [tests/lpc_portkind_host.zig](../../tests/lpc_portkind_host.zig)。
- 回归：对 `NtCreatePort` / `NtConnectPort` 的修改须保持 `zig build test` 与现有 syscall 分发探测（用户指针 `probe`）不回归。
