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
// Module: tests/nt61/startmenu_paint_hint_nt61_host.zig
// Purpose: Host anchors for start-menu partial repaint policy vs full scene (must stay aligned with display.MouseMovePaintHint).
//
// This is an independent clean-room implementation.

const std = @import("std");

/// Mirrors `display.MouseMovePaintHint.merge` semantics for regression if that struct changes.
const PaintHint = struct {
    needs_full_scene: bool = false,
    needs_startmenu_repaint: bool = false,
    needs_drag_repaint: bool = false,
    needs_shell_frame_repaint: bool = false,
    needs_post_drag_composite: bool = false,
    needs_caption_chrome_only: bool = false,
    cursor_shape_changed: bool = false,

    fn merge(a: PaintHint, b: PaintHint) PaintHint {
        return .{
            .needs_full_scene = a.needs_full_scene or b.needs_full_scene,
            .needs_startmenu_repaint = a.needs_startmenu_repaint or b.needs_startmenu_repaint,
            .needs_drag_repaint = a.needs_drag_repaint or b.needs_drag_repaint,
            .needs_shell_frame_repaint = a.needs_shell_frame_repaint or b.needs_shell_frame_repaint,
            .needs_post_drag_composite = a.needs_post_drag_composite or b.needs_post_drag_composite,
            .needs_caption_chrome_only = a.needs_caption_chrome_only or b.needs_caption_chrome_only,
            .cursor_shape_changed = a.cursor_shape_changed or b.cursor_shape_changed,
        };
    }
};

test "startmenu row hover hint does not set needs_full_scene" {
    const sm = PaintHint{ .needs_startmenu_repaint = true };
    const m = PaintHint.merge(.{}, sm);
    try std.testing.expect(!m.needs_full_scene);
    try std.testing.expect(m.needs_startmenu_repaint);
}

test "startmenu repaint can combine with caption chrome without full scene" {
    const m = PaintHint.merge(
        .{ .needs_startmenu_repaint = true },
        .{ .needs_caption_chrome_only = true },
    );
    try std.testing.expect(!m.needs_full_scene);
    try std.testing.expect(m.needs_startmenu_repaint);
    try std.testing.expect(m.needs_caption_chrome_only);
}
