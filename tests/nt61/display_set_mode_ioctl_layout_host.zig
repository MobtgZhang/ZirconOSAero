// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

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
