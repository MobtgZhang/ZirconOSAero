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
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: tests/nt61/taskbar_peek_hit_nt61_host.zig
// Purpose: Host tests for Aero Peek show-desktop strip hit testing.
//
// Clean-room; see docs/cn/DesktopManagerSpec.md
//! Aero Peek / Show Desktop 竖条命中（与 `src/desktop/aero/src/theme.zig` Layout、`taskbar.getShowDesktopButtonRect` 一致）。
const std = @import("std");

const show_desktop_peek_width: i32 = 14;
const taskbar_height: i32 = 40;

fn isClickOnShowDesktopPeek(x: i32, y: i32, screen_w: i32, screen_h: i32) bool {
    const rx = screen_w - show_desktop_peek_width;
    const ry = screen_h - taskbar_height;
    return x >= rx and x < rx + show_desktop_peek_width and y >= ry and y < ry + taskbar_height;
}

test "peek strip right edge inside 1280x1080" {
    try std.testing.expect(isClickOnShowDesktopPeek(1270, 1060, 1280, 1080));
}

test "peek strip misses above taskbar" {
    try std.testing.expect(!isClickOnShowDesktopPeek(1270, 1000, 1280, 1080));
}
