// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/ssdt_x86_win7_sp1.zig
// Purpose: **x86（32 位）** NT 服务号子集，供 WOW64 `translateSyscall32to64`、thunk 表与主机回归；与 x64 `ssdt_nt61` 索引不同。
// **x64 孪生与映射**：[`../../../arch/x86_64/ssdt_nt61.zig`](../../../arch/x86_64/ssdt_nt61.zig)；[`x64_semantic_alias.zig`](x64_semantic_alias.zig)（`x64SsdtIndexForWin7Sp1X86`）；文档 [`../../../../docs/cn/PHASE_G_WOW64.md`](../../../../docs/cn/PHASE_G_WOW64.md)。
//
// This is an independent clean-room implementation.
// Ref: https://github.com/j00ru/windows-syscalls — `x86/json/nt-per-system.json`, Windows 7 **SP1**（十进制服务号 → 本文件十六进制常量）。

const std = @import("std");

pub const NtAllocateVirtualMemory: u32 = 0x13;
pub const NtClose: u32 = 0x32;
pub const NtCreateEvent: u32 = 0x40;
pub const NtCreateFile: u32 = 0x42;
pub const NtCreatePort: u32 = 0x4D;
/// 32 位进程连接 csrss / 子系统端口（与 DWM 通知 LPC 同机制族）；**Windows 7 SP1 x86** 服务号 **59**（`j00ru/windows-syscalls` `nt-per-system.json`）。
pub const NtConnectPort: u32 = 0x3B;
pub const NtCreateProcess: u32 = 0x4F;
pub const NtCreateSection: u32 = 0x54;
pub const NtCreateThread: u32 = 0x57;
/// Win7 SP1 x86 服务号 **98**（`j00ru/windows-syscalls` `x86/json/nt-per-system.json` → `Windows 7` / `SP1`）。
pub const NtDelayExecution: u32 = 0x62;
/// Win7 SP1 x86 服务号 **57**（十进制）→ 十六进制 **0x39**；数据源文件：`j00ru/windows-syscalls` 仓库内 `x86/json/nt-per-system.json`（Windows 7 / SP1 条目 `NtDuplicateObject`）。
pub const NtDuplicateObject: u32 = 0x39;
pub const NtFreeVirtualMemory: u32 = 0x83;
pub const NtMapViewOfSection: u32 = 0xA8;
pub const NtOpenFile: u32 = 0xB3;
pub const NtOpenProcess: u32 = 0xBE;
pub const NtProtectVirtualMemory: u32 = 0xD7;
pub const NtQueryInformationProcess: u32 = 0xEA;
pub const NtQuerySystemInformation: u32 = 0x105;
pub const NtQueryVirtualMemory: u32 = 0x10B;
pub const NtReadFile: u32 = 0x111;
pub const NtReadVirtualMemory: u32 = 0x115;
/// 同步 LPC 请求/应答（含 `CsrApiNumber` 窗口消息）；Win7 SP1 x86 **299**。
pub const NtRequestWaitReplyPort: u32 = 0x12B;
pub const NtTerminateProcess: u32 = 0x172;
pub const NtTerminateThread: u32 = 0x173;
pub const NtWaitForSingleObject: u32 = 0x187;
pub const NtWriteFile: u32 = 0x18C;
pub const NtWriteVirtualMemory: u32 = 0x18F;

/// **win32k** 服务十进制 **4111**（公开表：`NtUserPostMessage`）→ `0x100F`；与 x64 折叠槽 `ssdt_nt61.NtUserPostMessage == 0x5A` 为**名称对照**（非同一编号空间）。
pub const Win32kNtUserPostMessage_x86_index4111: u32 = 0x100F;

/// x86 **win32k.sys** 服务号与 ntos 不同命名空间；十进制服务号常 ≥ 0x1000（如公开表 `NtUserPostMessage`）。
/// Thunk 层对命中此范围的调用返回 `STATUS_NOT_IMPLEMENTED`，避免与 ntos 子集误映射。
pub fn isX86Win32kServiceIndex(syscall_num: u32) bool {
    return syscall_num >= 0x1000;
}

/// `translateSyscall32to64` 演示路径：对上述公开服务号返回成功；其余 `STATUS_NOT_IMPLEMENTED`。
pub fn wow64SyscallStubReturnsSuccess(syscall_num: u32) bool {
    inline for (.{
        NtAllocateVirtualMemory,
        NtClose,
        NtCreateEvent,
        NtCreateFile,
        NtCreatePort,
        NtConnectPort,
        NtCreateProcess,
        NtCreateSection,
        NtCreateThread,
        NtDuplicateObject,
        NtFreeVirtualMemory,
        NtMapViewOfSection,
        NtOpenFile,
        NtOpenProcess,
        NtProtectVirtualMemory,
        NtQueryInformationProcess,
        NtQuerySystemInformation,
        NtQueryVirtualMemory,
        NtReadFile,
        NtReadVirtualMemory,
        NtRequestWaitReplyPort,
        NtDelayExecution,
        NtTerminateProcess,
        NtTerminateThread,
        NtWaitForSingleObject,
        NtWriteFile,
        NtWriteVirtualMemory,
    }) |v| {
        if (syscall_num == v) return true;
    }
    return false;
}

test "WOW64 x86 Win7 SP1 reference indices" {
    try std.testing.expect(NtDuplicateObject == 0x39);
    try std.testing.expect(NtClose == 0x32);
    try std.testing.expect(NtOpenProcess == 0xBE);
    try std.testing.expect(NtQueryVirtualMemory == 0x10B);
    try std.testing.expect(NtTerminateProcess == 0x172);
    try std.testing.expect(NtDelayExecution == 0x62);
    try std.testing.expect(NtCreateFile == 0x42);
    try std.testing.expect(NtConnectPort == 0x3B);
    try std.testing.expect(NtRequestWaitReplyPort == 0x12B);
    try std.testing.expect(Win32kNtUserPostMessage_x86_index4111 == 0x100F);
}

test "wow64SyscallStubReturnsSuccess covers thunk table syscalls" {
    try std.testing.expect(wow64SyscallStubReturnsSuccess(NtCreateProcess));
    try std.testing.expect(wow64SyscallStubReturnsSuccess(NtWriteFile));
    try std.testing.expect(wow64SyscallStubReturnsSuccess(NtConnectPort));
    try std.testing.expect(wow64SyscallStubReturnsSuccess(NtRequestWaitReplyPort));
    try std.testing.expect(!wow64SyscallStubReturnsSuccess(0xFFFF));
}

test "x86 win32k service indices are not ntos stubs" {
    try std.testing.expect(isX86Win32kServiceIndex(Win32kNtUserPostMessage_x86_index4111));
    try std.testing.expect(!isX86Win32kServiceIndex(NtClose));
}
