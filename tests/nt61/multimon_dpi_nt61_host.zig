// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/nt61/multimon_dpi_nt61_host.zig
// Purpose: Host tests for DPI scaling formula aligned with framebuffer.zig.
//
// Clean-room; Ref: https://learn.microsoft.com/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows
//! 与 `framebuffer.physicalToLogicalPx` / `MonitorLayoutNt61` 公式一致的主机锚点（无驱动链接）。
//! Ref: https://learn.microsoft.com/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows
const std = @import("std");

fn physicalToLogicalPx(dpi: u16, physical_px: i32) i32 {
    const d: i64 = if (dpi == 0) 96 else @intCast(dpi);
    return @intCast(@divTrunc(@as(i64, physical_px) * 96, @max(1, d)));
}

test "physicalToLogicalPx 192 DPI halves logical extent" {
    try std.testing.expectEqual(@as(i32, 480), physicalToLogicalPx(192, 960));
    try std.testing.expectEqual(@as(i32, 96), physicalToLogicalPx(192, 192));
}

test "physicalToLogicalPx 96 DPI identity" {
    try std.testing.expectEqual(@as(i32, 100), physicalToLogicalPx(96, 100));
    try std.testing.expectEqual(@as(i32, 100), physicalToLogicalPx(0, 100));
}
