// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/ssdt_x86_win7_sp1.zig
// Purpose: **x86（32 位）** NT 服务号子集，供 WOW64 映射与文档对照；与 x64 索引不同。
//
// This is an independent clean-room implementation.
// Ref: j00ru/windows-syscalls `x86/json/nt-per-system.json` — Windows 7 SP1。

//! 真实 SysWOW64 经 `syscall` 进入 64 位内核时仍使用 **64 位 SSDT**；本表为 **原生 x86** 内核或
//! `int 2E` 风格入口的服务号参考，用于 `translateSyscall32to64` 演进。
//!
//! **NtUser***：x86 与 x64 服务号不同；`ssdt_nt61.zig` 每增一条 x64 `NtUser*`，须在此或专用映射中核对公开 x86 表后再接 WOW64。

pub const NtClose = 0x32;
pub const NtAllocateVirtualMemory = 0x13;
pub const NtOpenProcess = 0xBE;
pub const NtQueryVirtualMemory = 0x10B;

const std = @import("std");

test "WOW64 x86 Win7 SP1 reference indices" {
    try std.testing.expect(NtClose == 0x32);
    try std.testing.expect(NtOpenProcess == 0xBE);
}
