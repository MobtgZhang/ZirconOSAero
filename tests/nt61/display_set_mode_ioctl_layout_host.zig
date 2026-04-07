// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Host anchor: IOCTL_DISPLAY_SET_MODE payload layout (see docs/specs/DisplayModeChange_NT61.md).
const std = @import("std");

/// Must match `src/drivers/video/core/display.zig` `DisplaySetModeRequestV1`.
const DisplaySetModeRequestV1 = extern struct {
    version: u32,
    flags: u32,
    width: u32,
    height: u32,
    bpp: u8,
    pixel_bgr: u8,
    _pad: [2]u8,
    pitch: u32,
    fb_address: u64,
};

test "DisplaySetModeRequestV1 is 32 bytes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(DisplaySetModeRequestV1));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(DisplaySetModeRequestV1, "fb_address"));
}
