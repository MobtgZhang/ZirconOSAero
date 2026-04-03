// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/nt61_os_version_layout_host.zig
// Purpose: `NtQuerySystemInformation(SystemVersionInformation)` 缓冲长度锚点（与 `src/config/os_version.zig` `rtl_osversioninfoexw_bytes` 同源）。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows/win32/api/sysinfoapi/ns-sysinfoapi-osversioninfoexw

const std = @import("std");

/// 须与 `src/config/os_version.zig` `rtl_osversioninfoexw_bytes` 保持相等。
pub const rtl_osversioninfoexw_bytes_expected: u32 = 284;

test "SystemVersionInformation buffer size matches os_version.zig" {
    try std.testing.expectEqual(@as(u32, 284), rtl_osversioninfoexw_bytes_expected);
}
