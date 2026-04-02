// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/usb/hid_boot_report.zig
// Purpose: USB HID Boot Protocol mouse report layout (host-testable).
//
// Clean-room. Ref: USB HID 1.11 Boot Interface Subclass (public spec).

pub const BootMouseReport = struct {
    buttons: u8,
    dx: i8,
    dy: i8,
    scroll: i8 = 0,
};

/// Returns `null` if buffer too short. Y axis sign is **device report** frame; caller may negate for screen coords.
pub fn parseBootMouseReport(buf: []const u8) ?BootMouseReport {
    if (buf.len < 3) return null;
    var r: BootMouseReport = .{
        .buttons = buf[0],
        .dx = @bitCast(buf[1]),
        .dy = @bitCast(buf[2]),
    };
    if (buf.len >= 4) r.scroll = @bitCast(buf[3]);
    return r;
}

const std = @import("std");

test "boot mouse minimal 3 bytes" {
    const b = [_]u8{ 0x01, 0xFE, 0x02 };
    const p = parseBootMouseReport(&b).?;
    try std.testing.expectEqual(@as(u8, 1), p.buttons);
    try std.testing.expectEqual(@as(i8, -2), p.dx);
    try std.testing.expectEqual(@as(i8, 2), p.dy);
}

test "boot mouse too short" {
    try std.testing.expect(parseBootMouseReport(&[_]u8{ 0, 1 }) == null);
}
