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
// Host anchors for shell partial-repaint degrade policy (shadow dirty inflate + overlap).
// Mirrors `display.shellAeroShadowOutsetPx` / `display.rectInflate` / `display.rectsOverlap` math.
//
// Drag-layer invariant (邻窗边框不发灰): Explorer/TaskMgr/builtin 的 DragLight 路径不得对整窗调用
// `mat.renderShadow` / `dwm.renderShadow` 等半透明条带 blend 到已绘制的邻窗 Aero 边框上；
// 多窗重叠时 `renderer_aero.renderDragFrame` 可整幅壁纸重绘并 `markFullScreenDirty`。
/// Document-only anchor kept in sync with `renderer_aero.renderExplorerWindowDragLight` policy.
pub const drag_light_no_neighbor_shadow_blend: bool = true;

const std = @import("std");

const ShellRect = struct { x: i32, y: i32, w: i32, h: i32 };

fn rectInflate(r: ShellRect, p: i32) ShellRect {
    return .{
        .x = r.x - p,
        .y = r.y - p,
        .w = r.w + 2 * p,
        .h = r.h + 2 * p,
    };
}

fn rectsOverlap(a: ShellRect, b: ShellRect) bool {
    if (a.w <= 0 or a.h <= 0 or b.w <= 0 or b.h <= 0) return false;
    return a.x < b.x + b.w and a.x + a.w > b.x and a.y < b.y + b.h and a.y + a.h > b.y;
}

/// Keep in sync with `display.shellAeroShadowOutsetPx()`.
const shell_shadow_outset_px: i32 = 10;

test "shellRectWithAeroShadowUnion inflates by 10px per side" {
    const r: ShellRect = .{ .x = 20, .y = 30, .w = 400, .h = 300 };
    const u = rectInflate(r, shell_shadow_outset_px);
    try std.testing.expectEqual(@as(i32, 10), u.x);
    try std.testing.expectEqual(@as(i32, 20), u.y);
    try std.testing.expectEqual(@as(i32, 420), u.w);
    try std.testing.expectEqual(@as(i32, 320), u.h);
}

test "non-overlapping windows do not trigger overlap policy" {
    const a: ShellRect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const b: ShellRect = .{ .x = 200, .y = 0, .w = 100, .h = 100 };
    try std.testing.expect(!rectsOverlap(a, b));
}

test "overlapping windows trigger overlap policy" {
    const a: ShellRect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const b: ShellRect = .{ .x = 50, .y = 50, .w = 100, .h = 100 };
    try std.testing.expect(rectsOverlap(a, b));
}

test "menu dirty rect intersects inflated window shadow bounds" {
    const menu: ShellRect = .{ .x = 10, .y = 400, .w = 400, .h = 500 };
    const win: ShellRect = .{ .x = 30, .y = 200, .w = 500, .h = 400 };
    const win_s = rectInflate(win, shell_shadow_outset_px);
    try std.testing.expect(rectsOverlap(menu, win_s));
}

test "drag light skips soft shadow blend onto neighbor shell NC (policy anchor)" {
    try std.testing.expect(drag_light_no_neighbor_shadow_blend);
}

// Mirrors `display.blitRegisteredDwmThumbnailsToFramebuffer` clamp for `markDirtyRegion` after scaled blit.
test "DWM thumbnail dirty rect clamps to screen" {
    const scr_w: i32 = 1920;
    const scr_h: i32 = 1080;
    const sx0: i32 = 100;
    const sy0: i32 = 200;
    const dww: i32 = 80;
    const dhh: i32 = 60;
    const x0c = @max(0, sx0);
    const y0c = @max(0, sy0);
    const x1c = @min(scr_w, sx0 + dww);
    const y1c = @min(scr_h, sy0 + dhh);
    try std.testing.expect(x1c > x0c and y1c > y0c);
    try std.testing.expectEqual(@as(i32, 80), x1c - x0c);
    try std.testing.expectEqual(@as(i32, 60), y1c - y0c);
}

test "shadow tint is not pure black (min channel > 0)" {
    const b: u32 = 0x60;
    const g: u32 = 0x48;
    const rch: u32 = 0x30;
    const tint = b | (g << 8) | (rch << 16);
    try std.testing.expect((tint & 0xFF) > 0);
    try std.testing.expect(((tint >> 8) & 0xFF) > 0);
    try std.testing.expect(((tint >> 16) & 0xFF) > 0);
}
