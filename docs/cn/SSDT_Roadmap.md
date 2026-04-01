# SSDT / 服务号映射路线图（ZirconOSAero）

## 目标

在保持 **clean-room** 的前提下，把当前内核使用的 **`SYS_*` 内部编号**（见 [`src/arch/x86_64/syscall.zig`](../../src/arch/x86_64/syscall.zig)）与 **公开文档中的 NT 服务语义**分层对齐，并明确与 **Windows 7 x64 构建版本 SSDT 索引** 的关系。

## 当前状态

| 层级 | 说明 |
|------|------|
| **A. 内部表** | `rax` = `SYS_*`；`int 0x80` 与 **`syscall` + LSTAR** 共用同一分发例程（见 [SyscallABI.md](SyscallABI.md)）。 |
| **B. 文档化语义** | 每个 `SYS_*` 应在契约矩阵或本文件中标注对应的 **Nt*/Zw* 名称**（公开 ABI 名称合法）。 |
| **C. Windows 二进制兼容** | 与 **微软 `ntdll` 使用的 SSDT 序号**一致未声称；需单独里程碑：版本化表、探测或配置、回归策略。 |

## 分阶段建议

1. **阶段 1（当前）**：扩充 `SYS_*` 与 `syscall.dispatch` 分支，保持编号连续可测试；在 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 中标注 **Partial / Stub**。
2. **阶段 2**：引入 **别名层**（例如 `ServiceId{ .internal = 3, .nt_name = "NtClose" }`），仍不承诺与 Windows 构建一致序号。
3. **阶段 3（可选）**：在 **x86_64 单一目标**上提供 **Windows 7 SP1 x64 子集 SSDT 映射表**（仅公开文档与合法测试镜像验证），与 **WOW64** thunk 对齐（见 [`src/subsystems/win32/wow64.zig`](../../src/subsystems/win32/wow64.zig) 头注释）。

## 参考（白名单）

- [Microsoft Learn — Syscall（体系结构概述）](https://learn.microsoft.com/)
- 本仓库 [SyscallABI.md](SyscallABI.md)、[PROCESS_NT61.md](PROCESS_NT61.md)
