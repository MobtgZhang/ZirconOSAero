# SSDT / 服务号映射路线图（ZirconOSAero）

## 目标

在保持 **clean-room** 的前提下，把当前内核使用的 **`SYS_*` 内部编号**（见 [`src/arch/x86_64/syscall.zig`](../../src/arch/x86_64/syscall.zig)）与 **公开文档中的 NT 服务语义**分层对齐，并明确与 **Windows 7 x64 构建版本 SSDT 索引** 的关系。

## 当前状态

| 层级 | 说明 |
|------|------|
| **A. NT 6.1 SSDT 子集** | `src/arch/x86_64/ssdt_nt61.zig` + `syscall.zig`：仅 **`syscall`/`sysret`** 进入分发；仅公开 SSDT 索引。见 [SyscallABI.md](SyscallABI.md)。 |
| **B. 文档化语义** | 每个已实现 SSDT 索引应在契约矩阵标注 **Partial / Stub** 与对应 **Nt*** 名称。 |
| **C. Windows 二进制兼容** | 与 **完整** 微软 `ntdll` SSDT 仍不一致；需按构建版本扩充表与 Win32k 影子项。 |

## 分阶段建议

1. **阶段 1（当前）**：按 **Win7 SP1 x64** 公开表扩充 `ssdt_nt61.zig` 与 `syscall.dispatch` 分支；在 [NT61_CONTRACT_MATRIX.md](NT61_CONTRACT_MATRIX.md) 中标注 **Partial / Stub**。
2. **阶段 2**：对已实现路径保证 **ntdll 桩号 = 内核分发号**；未实现服务返回 `STATUS_NOT_IMPLEMENTED` 或 `STATUS_INVALID_PARAMETER`（依契约）。
3. **阶段 3**：WOW64 将 32 位服务号映射到同一 64 位语义（见 [PHASE_G_WOW64.md](PHASE_G_WOW64.md)、[`wow64/thunk.zig`](../../src/subsystems/win32/wow64/thunk.zig)、[`x64_semantic_alias.zig`](../../src/subsystems/win32/wow64/x64_semantic_alias.zig)）。

## 阶段 E（Native API 深度补全 — 索引与文档）

- **完成定义**：[PHASE_E_NATIVE_API.md](PHASE_E_NATIVE_API.md)（与 [NT61_PLAN_REMAINING.md](NT61_PLAN_REMAINING.md) 内 **Phase E — Shell** 非同一里程碑）。
- **新增折叠槽**：`NtDeviceIoControlFile` **0x52**、`NtLockVirtualMemory` **0x53**、`NtUnlockVirtualMemory` **0x54**（理由见 [SyscallABI.md](SyscallABI.md)）。

## 阶段 B（x64 系统调用子集）完成定义（可验收）

- **机制**：`main.zig` 在 IDT 就绪后调用 `initSyscallInstructionPath`；用户态仅 **`syscall`/`sysret`** 进入 `syscall.zig`；说明见 [SyscallABI.md](SyscallABI.md)。
- **折叠槽**：`NtWaitForMultipleObjects` / `NtSetInformationObject` 与 Win7 SP1 公开 **0x58/0x59** 冲突时，本仓库使用 **0x57/0x56**（见 `ssdt_nt61.zig` 注释）。
- **门禁**：`zig build test` 须通过 **ssdt**、**ssdt_stub_parity**（[`ntdll_syscall_win64.zig`](../../src/sdk/ntdll_syscall_win64.zig) 与 `ssdt_nt61` 同步子集）、主机 **rtl_verify_version_info_host**（[`rtl_verify_version_info_host.zig`](../../src/rtl_verify_version_info_host.zig) — `RtlVerifyVersionInfo` 语义子集）。
- **扩展 syscall**：`NtCreateProcess`（0x9F）、`NtCreateUserProcess`（0xAA，`syscall_nt_extras.dispatchNtCreateUserProcess`）、`NtSignalAndWaitForSingleObject`（0x176）、进程/线程/同步/文件打开等 SSDT 项在 `syscall.zig` 与 [`syscall_nt_extras.zig`](../../src/arch/x86_64/syscall_nt_extras.zig) 中**逐项**分支配对（未实现项单独列于 `switch` 并返回契约 NTSTATUS）。

## 参考（白名单）

- [Microsoft Learn — Syscall（体系结构概述）](https://learn.microsoft.com/)
- 本仓库 [SyscallABI.md](SyscallABI.md)、[PROCESS_NT61.md](PROCESS_NT61.md)
