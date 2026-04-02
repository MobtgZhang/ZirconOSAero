// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/arch/x86_64/ssdt_nt61.zig
// Purpose: Windows NT 6.1 x64 (build 7600) **公开 SSDT 服务索引**子集，供 `syscall` 分发与文档对照。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: 公开 syscall 枚举（如社区维护的 NT 构建版本表 j00ru/windows-syscalls）；本文件仅收录本内核已实现或桩实现的服务号。
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../../docs/cn/NT61_KERNEL_TODO.md) Phase K7（扩展须双端 ntdll/syscall + probe）。

//! x64 `syscall` 调用约定（与 AMD64 长模式一致）：`RAX`=下表索引；第 1 参在 **`R10`**（因 `RCX` 存返回 RIP）；
//! 第 2–4 参为 `RDX`、`R8`、`R9`；更多参数在**用户栈**上（相对于 SYSCALL 时 `RSP`，第 5 参常为 `+0x28`）。
//! `int 0x80`（向量 128）使用同一 `InterruptFrame` 与同一分发器；调用方须遵守 **NT x64 寄存器约定**（第 1 参在 **R10**），而非 Linux `int 0x80` 风格。

pub const NtClose = 0x0C;
pub const NtWaitForSingleObject = 0x04;
pub const NtAllocateVirtualMemory = 0x18;
pub const NtFreeVirtualMemory = 0x1B;
pub const NtQuerySystemInformation = 0x25;
pub const NtCreateFile = 0x2C;
pub const NtYieldExecution = 0x43;
pub const NtTerminateProcess = 0x29;
/// Ref: j00ru `nt-per-system.json` — Windows 7 SP1 x64（与 `NtProtectVirtualMemory` 0x4D 区分）。
pub const NtCreateThread = 0x4B;
/// Ref: j00ru — Windows 7 SP1 x64。
pub const NtProtectVirtualMemory = 0x4D;
/// Ref: j00ru — Windows 7 SP1 x64。
pub const NtDelayExecution = 0x31;
/// Ref: j00ru — Windows 7 SP1 x64。
pub const NtOpenKey = 0x0F;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtQueryValueKey = 0x14;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtCreateKey = 0x1A;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64（与 `NtQueryValueKey` 不同索引）。
pub const NtSetValueKey = 0x5D;
pub const NtWriteFile = 0x08;
pub const NtReadFile = 0x07;
/// Win32k 在真实 Windows 上为独立服务表；本内核将用户消息 syscall 折叠进同一分发器。
/// 索引与项目路线图（NT 6.1 x64 公开对照表）对齐；完整核对见 j00ru/windows-syscalls 等公开枚举。
pub const NtUserGetMessage = 0x58;
pub const NtUserPeekMessage = 0x59;

/// Ref: j00ru/windows-syscalls `nt-per-syscall.json` — Windows 7 SP1 x64.
pub const NtRequestWaitReplyPort = 0x1F;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64.
pub const NtConnectPort = 0x8F;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64.
pub const NtCreatePort = 0x9D;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64（早期内核调试输出；本内核可作串口跟踪）。
pub const NtDisplayString = 0xB8;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64（节对象；本内核 `section.zig` + `ntdll`）。
pub const NtCreateSection = 0x47;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtMapViewOfSection = 0x48;
/// Ref: j00ru/windows-syscalls — Windows 7 SP1 x64。
pub const NtUnmapViewOfSection = 0x2A;
/// Ref: j00ru `nt-per-system.json` — Windows 7 SP1（与 NtCreatePort 0x9D 等同表）。
pub const NtQueryVirtualMemory = 0x20;
/// Ref: j00ru `nt-per-system.json` — Windows 7 SP1。
pub const NtOpenProcess = 0x23;
/// Ref: 公开 Windows 7 x64 syscall 列表（如 OpenRCE / j00ru 对照表）；与 SP1 构建对齐。
pub const NtDuplicateObject = 0x44;

const std = @import("std");

test "SSDT NT 6.1 x64 public indices (Win7 SP1 reference)" {
    try std.testing.expect(NtAllocateVirtualMemory == 0x18);
    try std.testing.expect(NtTerminateProcess == 0x29);
    try std.testing.expect(NtCreateThread == 0x4B);
    try std.testing.expect(NtProtectVirtualMemory == 0x4D);
    try std.testing.expect(NtDelayExecution == 0x31);
    try std.testing.expect(NtOpenKey == 0x0F);
    try std.testing.expect(NtQueryValueKey == 0x14);
    try std.testing.expect(NtCreateKey == 0x1A);
    try std.testing.expect(NtSetValueKey == 0x5D);
    try std.testing.expect(NtUnmapViewOfSection == 0x2A);
    try std.testing.expect(NtCreatePort == 0x9D);
    try std.testing.expect(NtConnectPort == 0x8F);
    try std.testing.expect(NtDisplayString == 0xB8);
    try std.testing.expect(NtRequestWaitReplyPort == 0x1F);
    try std.testing.expect(NtCreateSection == 0x47);
    try std.testing.expect(NtMapViewOfSection == 0x48);
    try std.testing.expect(NtQuerySystemInformation == 0x25);
    try std.testing.expect(NtQueryVirtualMemory == 0x20);
    try std.testing.expect(NtOpenProcess == 0x23);
    try std.testing.expect(NtDuplicateObject == 0x44);
}
