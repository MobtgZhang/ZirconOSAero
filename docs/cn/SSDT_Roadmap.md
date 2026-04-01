# SSDT / 服务号映射路线图（ZirconOSAero）

## 目标

在保持 **clean-room** 的前提下，把当前内核使用的 **`SYS_*` 内部编号**（见 [`src/arch/x86_64/syscall.zig`](../../src/arch/x86_64/syscall.zig)）与 **公开文档中的 NT 服务语义**分层对齐，并明确与 **Windows 7 x64 构建版本 SSDT 索引** 的关系。

## 当前状态

| 层级 | 说明 |
|------|------|
| **A. NT 6.1 SSDT 子集** | `src/arch/x86_64/ssdt_nt61.zig` + `syscall.zig`：`syscall`/`int 0x80` 共用同一分发；仅公开 SSDT 索引。见 [SyscallABI.md](SyscallABI.md)。 |
| **B. 文档化语义** | 每个已实现 SSDT 索引应在契约矩阵标注 **Partial / Stub** 与对应 **Nt*** 名称。 |
| **C. Windows 二进制兼容** | 与 **完整** 微软 `ntdll` SSDT 仍不一致；需按构建版本扩充表与 Win32k 影子项。 |

## 分阶段建议

1. **阶段 1（当前）**：按 **Win7 SP1 x64** 公开表扩充 `ssdt_nt61.zig` 与 `syscall.dispatch` 分支；在 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 中标注 **Partial / Stub**。
2. **阶段 2**：对已实现路径保证 **ntdll 桩号 = 内核分发号**；未实现服务返回 `STATUS_NOT_IMPLEMENTED` 或 `STATUS_INVALID_PARAMETER`（依契约）。
3. **阶段 3**：WOW64 将 32 位服务号映射到同一 64 位语义（见 `wow64.zig`）。

## 参考（白名单）

- [Microsoft Learn — Syscall（体系结构概述）](https://learn.microsoft.com/)
- 本仓库 [SyscallABI.md](SyscallABI.md)、[PROCESS_NT61.md](PROCESS_NT61.md)
