// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/x64_semantic_alias.zig
// Purpose: Win7 SP1 **x86 SSDT 服务号** → **x64 `ssdt_nt61` 索引** 的同名 API 对照（可测子集）；**不**声称参数封送完整。
//
// This is an independent clean-room implementation.
// Ref: https://github.com/j00ru/windows-syscalls — `x86/json/nt-per-system.json` vs `x64/json/nt-per-system.json`（公开数据集名与 URL，非闭源表）。
// Doc: [docs/cn/PHASE_G_WOW64.md](../../../../docs/cn/PHASE_G_WOW64.md)、[docs/cn/SyscallABI.md](../../../../docs/cn/SyscallABI.md)
// 双表命名空间说明见同目录 `ssdt_x86_win7_sp1.zig` 与 `../../../arch/x86_64/ssdt_nt61.zig`（`@import` 路径相对**本文件**目录解析）。

const ssdt64 = @import("../../../arch/x86_64/ssdt_nt61.zig");
const x86 = @import("ssdt_x86_win7_sp1.zig");

/// 若 `syscall_num` 为 Win7 SP1 x86 上某 **ntos** 服务且本仓库 `ssdt_nt61` 有同名常量，返回对应 **x64** 索引；否则 `null`。
/// `NtTerminateThread`：x86 公开号与 x64 索引经 `ssdt_nt61.NtTerminateThread`（ZOA 槽 **0x55**，见该文件注释与 j00ru 冲突说明）对照。
pub fn x64SsdtIndexForWin7Sp1X86(syscall_num: u32) ?u32 {
    if (syscall_num == x86.NtAllocateVirtualMemory) return ssdt64.NtAllocateVirtualMemory;
    if (syscall_num == x86.NtClose) return ssdt64.NtClose;
    if (syscall_num == x86.NtCreateEvent) return ssdt64.NtCreateEvent;
    if (syscall_num == x86.NtCreateFile) return ssdt64.NtCreateFile;
    if (syscall_num == x86.NtCreatePort) return ssdt64.NtCreatePort;
    if (syscall_num == x86.NtConnectPort) return ssdt64.NtConnectPort;
    if (syscall_num == x86.NtCreateProcess) return ssdt64.NtCreateProcess;
    if (syscall_num == x86.NtCreateSection) return ssdt64.NtCreateSection;
    if (syscall_num == x86.NtCreateThread) return ssdt64.NtCreateThread;
    if (syscall_num == x86.NtDelayExecution) return ssdt64.NtDelayExecution;
    if (syscall_num == x86.NtFreeVirtualMemory) return ssdt64.NtFreeVirtualMemory;
    if (syscall_num == x86.NtMapViewOfSection) return ssdt64.NtMapViewOfSection;
    if (syscall_num == x86.NtOpenFile) return ssdt64.NtOpenFile;
    if (syscall_num == x86.NtOpenProcess) return ssdt64.NtOpenProcess;
    if (syscall_num == x86.NtProtectVirtualMemory) return ssdt64.NtProtectVirtualMemory;
    if (syscall_num == x86.NtQueryInformationProcess) return ssdt64.NtQueryInformationProcess;
    if (syscall_num == x86.NtQuerySystemInformation) return ssdt64.NtQuerySystemInformation;
    if (syscall_num == x86.NtQueryVirtualMemory) return ssdt64.NtQueryVirtualMemory;
    if (syscall_num == x86.NtReadFile) return ssdt64.NtReadFile;
    if (syscall_num == x86.NtReadVirtualMemory) return ssdt64.NtReadVirtualMemory;
    if (syscall_num == x86.NtRequestWaitReplyPort) return ssdt64.NtRequestWaitReplyPort;
    if (syscall_num == x86.NtTerminateProcess) return ssdt64.NtTerminateProcess;
    if (syscall_num == x86.NtTerminateThread) return ssdt64.NtTerminateThread;
    if (syscall_num == x86.NtWaitForSingleObject) return ssdt64.NtWaitForSingleObject;
    if (syscall_num == x86.NtWriteFile) return ssdt64.NtWriteFile;
    if (syscall_num == x86.NtWriteVirtualMemory) return ssdt64.NtWriteVirtualMemory;
    return null;
}
