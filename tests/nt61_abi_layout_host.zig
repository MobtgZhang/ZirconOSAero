// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/nt61_abi_layout_host.zig
// Purpose: 主机断言 `TEB`/`KUSER_SHARED_DATA` 契约与 Phase1（ABI-1.4/1.5）文档一致。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.

const std = @import("std");
const teb = @import("teb");
const kuser = @import("kuser");

test "TEB x64 LastErrorValue offset 0x68" {
    try std.testing.expectEqual(@as(usize, 0x68), @offsetOf(teb.TebNt61X64, "LastErrorValue"));
}

test "KUSER_SHARED_DATA VA and version field offsets" {
    try std.testing.expectEqual(@as(u64, 0x7FFE0000), kuser.KUSER_SHARED_DATA_VA_X64);
    try std.testing.expect(kuser.kuser_nt_major_version_offset < 4096);
    try std.testing.expect(kuser.kuser_nt_minor_version_offset < 4096);
}
