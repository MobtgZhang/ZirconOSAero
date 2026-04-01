// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/ssdt_x64_x86_namespace.zig
// Purpose: Host regression — x64 SSDT indices (Win7 SP1 ref) differ from x86 native table for the same logical services; documents dual-table maintenance for WOW64 work.
//
// This is an independent clean-room implementation.
// Ref: j00ru/windows-syscalls nt-per-system.json (x64 vs x86); see docs/cn/SyscallABI.md.

const std = @import("std");
const x64 = @import("ssdt_x64");
const x86 = @import("ssdt_x86");

test "Win7 SP1 public ref: NtClose index differs x64 vs x86 namespace" {
    try std.testing.expect(x64.NtClose != x86.NtClose);
    try std.testing.expect(x64.NtClose == 0x0C);
    try std.testing.expect(x86.NtClose == 0x32);
}

test "Win7 SP1 public ref: NtAllocateVirtualMemory index differs x64 vs x86" {
    try std.testing.expect(x64.NtAllocateVirtualMemory != x86.NtAllocateVirtualMemory);
    try std.testing.expect(x64.NtAllocateVirtualMemory == 0x18);
    try std.testing.expect(x86.NtAllocateVirtualMemory == 0x13);
}

test "Win7 SP1 public ref: NtOpenProcess index differs x64 vs x86" {
    try std.testing.expect(x64.NtOpenProcess != x86.NtOpenProcess);
    try std.testing.expect(x64.NtOpenProcess == 0x23);
    try std.testing.expect(x86.NtOpenProcess == 0xBE);
}

test "Win7 SP1 public ref: NtQueryVirtualMemory index differs x64 vs x86" {
    try std.testing.expect(x64.NtQueryVirtualMemory != x86.NtQueryVirtualMemory);
    try std.testing.expect(x64.NtQueryVirtualMemory == 0x20);
    try std.testing.expect(x86.NtQueryVirtualMemory == 0x10B);
}
