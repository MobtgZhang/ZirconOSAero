// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/arch/x86_64/ssdt_nt61.zig
// Purpose: Windows NT 6.1 x64 (build 7600) **公开 SSDT 服务索引**子集，供 `syscall` 分发与文档对照。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: 公开 syscall 枚举（如社区维护的 NT 构建版本表 j00ru/windows-syscalls）；本文件仅收录本内核已实现或桩实现的服务号。

//! x64 `syscall` 调用约定（与 AMD64 长模式一致）：`RAX`=下表索引；第 1 参在 **`R10`**（因 `RCX` 存返回 RIP）；
//! 第 2–4 参为 `RDX`、`R8`、`R9`；更多参数在**用户栈**上（相对于 SYSCALL 时 `RSP`，第 5 参常为 `+0x28`）。

/// Zircon 内部遗留服务（非 Windows）：`RAX = legacy_base + 0..15`，参数走 `RDI/RSI/RDX`（`int 0x80` 路径）。
pub const zircon_legacy_syscall_base: u32 = 0x0010_0000;

pub const NtClose = 0x0C;
pub const NtWaitForSingleObject = 0x04;
pub const NtAllocateVirtualMemory = 0x18;
pub const NtFreeVirtualMemory = 0x1B;
pub const NtQuerySystemInformation = 0x25;
pub const NtCreateFile = 0x2C;
pub const NtYieldExecution = 0x43;
pub const NtTerminateProcess = 0x29;
pub const NtCreateThread = 0x4D;
pub const NtWriteFile = 0x08;
pub const NtReadFile = 0x07;
/// Win32k 在真实 Windows 上为独立服务表；本内核将用户消息 syscall 折叠进同一分发器。
/// 索引与项目路线图（NT 6.1 x64 公开对照表）对齐；完整核对见 j00ru/windows-syscalls 等公开枚举。
pub const NtUserGetMessage = 0x58;
pub const NtUserPeekMessage = 0x59;

const std = @import("std");

test "SSDT indices stay below Zircon legacy syscall base" {
    try std.testing.expect(NtUserGetMessage < zircon_legacy_syscall_base);
    try std.testing.expect(NtUserPeekMessage < zircon_legacy_syscall_base);
    try std.testing.expect(NtAllocateVirtualMemory == 0x18);
}
