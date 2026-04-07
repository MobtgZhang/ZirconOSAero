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
/// USB HID Boot Protocol keyboard：modifiers、保留、最多 6 个按键 usage。
pub const BootKeyboardReport = struct {
    modifiers: u8,
    keys: [6]u8,
};

pub fn parseBootKeyboardReport(buf: []const u8) ?BootKeyboardReport {
    if (buf.len < 8) return null;
    return .{
        .modifiers = buf[0],
        .keys = .{
            buf[2], buf[3], buf[4], buf[5], buf[6], buf[7],
        },
    };
}

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

test "boot keyboard 8 bytes" {
    const b = [_]u8{ 0x02, 0, 0x04, 0, 0, 0, 0, 0 };
    const k = parseBootKeyboardReport(&b).?;
    try std.testing.expectEqual(@as(u8, 0x02), k.modifiers);
    try std.testing.expectEqual(@as(u8, 0x04), k.keys[0]);
}
