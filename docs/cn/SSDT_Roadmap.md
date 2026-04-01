# SSDT / 服务号映射路线图（ZirconOSAero）

## 目标

在保持 **clean-room** 的前提下，把当前内核使用的 **`SYS_*` 内部编号**（见 [`src/arch/x86_64/syscall.zig`](../../src/arch/x86_64/syscall.zig)）与 **公开文档中的 NT 服务语义**分层对齐，并明确与 **Windows 7 x64 构建版本 SSDT 索引** 的关系。

## 当前状态

| 层级 | 说明 |
|------|------|
| **A. NT 6.1 SSDT 子集 + 遗留基址** | `src/arch/x86_64/ssdt_nt61.zig` + `syscall.zig`：`syscall`/`int 0x80` 共用分发；遗留号为 `0x0010_0000+n`。见 [SyscallABI.md](SyscallABI.md)。 |
| **B. 文档化语义** | 每个已实现 SSDT 索引应在契约矩阵标注 **Partial / Stub** 与对应 **Nt*** 名称。 |
| **C. Windows 二进制兼容** | 与 **完整** 微软 `ntdll` SSDT 仍不一致；需按构建版本扩充表与 Win32k 影子项。 |

## 分阶段建议

1. **阶段 1（当前）**：扩充 `SYS_*` 与 `syscall.dispatch` 分支，保持编号连续可测试；在 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 中标注 **Partial / Stub**。
2. **阶段 2**：引入 **别名层**（例如 `ServiceId{ .internal = 3, .nt_name = "NtClose" }`），仍不承诺与 Windows 构建一致序号。
3. **阶段 3（进行中）**：[`ssdt_nt61.zig`](../../src/arch/x86_64/ssdt_nt61.zig) 提供 **7600 档公开索引子集**；WOW64 仍须将 32 位服务号映射到同一 64 位表（见 `wow64.zig`）。

## 参考（白名单）

- [Microsoft Learn — Syscall（体系结构概述）](https://learn.microsoft.com/)
- 本仓库 [SyscallABI.md](SyscallABI.md)、[PROCESS_NT61.md](PROCESS_NT61.md)
