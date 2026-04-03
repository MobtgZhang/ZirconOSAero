// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/subsystems/win32/wow64/redirect.zig
// Purpose: SysWOW64 风格路径/注册表重定向占位；行为仅对照 MSDN 描述，待接 VFS/配置树。
//
// This is an independent clean-room implementation.

const std = @import("std");

/// 若路径指向 `System32`，可改写为 `SysWOW64`（占位；未修改 `buf`）。
pub fn shouldRedirectSystem32ToSyswow64(path_utf16_len: usize) bool {
    _ = path_utf16_len;
    return false;
}

/// 注册表 `HKLM\Software` → `HKLM\Software\WOW6432Node` 等策略占位。
pub fn noteRegistryWow64Node(_: []const u8) void {}

test "SysWOW64 redirect placeholders are conservative" {
    try std.testing.expect(!shouldRedirectSystem32ToSyswow64(0));
    try std.testing.expect(!shouldRedirectSystem32ToSyswow64(4096));
    noteRegistryWow64Node("Software\\Classes");
}
