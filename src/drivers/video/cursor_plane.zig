// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/cursor_plane.zig
// Purpose: Software cursor plane — save-under blit after scene compose (conceptual split from main frame).
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Concept (pointer vs main frame decoupling): mdcs/ideas.md; public behavior refs:
// https://learn.microsoft.com/en-us/windows/win32/dwm/dwm-overview
// https://learn.microsoft.com/en-us/windows-hardware/drivers/display/dxgkddisetpointerposition

//! 软件指针「图层」：在离屏/屏前绘制缓冲上，于场景合成之后做 save-under 与叠加。
//! 与 DWM 合成主帧分离的**概念**一致；本实现为 CPU 位图叠加，非 WDDM 硬件 sprite。

const std = @import("std");
const fb = @import("framebuffer.zig");
const aero_cursor_shape = @import("aero_cursor_shape.zig");

pub const CursorDrawFn = *const fn (i32, i32) void;

const sw_cursor_max_bytes: usize = 48 * 48 * 4;
var sw_cursor_saved: [sw_cursor_max_bytes]u8 align(1) = undefined;
var sw_cursor_saved_len: usize = 0;
var sw_cursor_sx: i32 = 0;
var sw_cursor_sy: i32 = 0;
var sw_cursor_sw: i32 = 0;
var sw_cursor_sh: i32 = 0;
var sw_cursor_placed: bool = false;
var sw_cursor_saved_kind: aero_cursor_shape.CursorKind = .arrow;

fn softwareCursorExtent(cx: i32, cy: i32) fb.Rect {
    const margin: i32 = 8;
    if (!fb.isInitialized()) return .{ .x = 0, .y = 0, .w = 40, .h = 44 };
    const w_i32: i32 = @intCast(fb.getWidth());
    const h_i32: i32 = @intCast(fb.getHeight());
    const max_x = if (w_i32 > 0) w_i32 - 1 else 0;
    const max_y = if (h_i32 > 0) h_i32 - 1 else 0;
    const cxx = std.math.clamp(cx, 0, max_x);
    const cyy = std.math.clamp(cy, 0, max_y);
    return .{ .x = cxx - margin, .y = cyy - margin, .w = 40, .h = 44 };
}

fn markDirtyUnionFromPoints(ax: i32, ay: i32, bx: i32, by: i32) void {
    const ra = softwareCursorExtent(ax, ay);
    const rb = softwareCursorExtent(bx, by);
    const ux = @min(ra.x, rb.x);
    const uy = @min(ra.y, rb.y);
    const rx: i64 = @max(@as(i64, ra.x) + ra.w, @as(i64, rb.x) + rb.w);
    const ry: i64 = @max(@as(i64, ra.y) + ra.h, @as(i64, rb.y) + rb.h);
    const rw = rx - @as(i64, ux);
    const rh = ry - @as(i64, uy);
    if (rw <= 0 or rh <= 0) return;
    if (rw > std.math.maxInt(i32) or rh > std.math.maxInt(i32)) return;
    fb.markDirtyRegion(ux, uy, @intCast(rw), @intCast(rh));
}

pub fn invalidate() void {
    sw_cursor_placed = false;
    sw_cursor_saved_len = 0;
}

/// 局部重绘（如标题栏热态）之前：若上一帧已叠加软件指针，先把 save-under 贴回绘制缓冲，避免留下光标轨迹。
pub fn restoreSaveUnderIfPlaced() void {
    if (!fb.isInitialized()) return;
    if (!sw_cursor_placed or sw_cursor_saved_len == 0) {
        invalidate();
        return;
    }
    fb.pasteDrawBufferRectBytes(sw_cursor_sx, sw_cursor_sy, sw_cursor_sw, sw_cursor_sh, sw_cursor_saved[0..sw_cursor_saved_len]);
    invalidate();
}

/// 旧/新指针位置并入脏矩形（供 `flipDirty` 与局部提交路径）。
pub fn markMotionDirty(ax: i32, ay: i32, bx: i32, by: i32) void {
    if (!fb.isInitialized()) return;
    markDirtyUnionFromPoints(ax, ay, bx, by);
}

/// 场景合成完成后调用：保存指针下像素并绘制指针（须在 `present` 之前）。
pub fn composeAfterScene(cursor_visible: bool, cx: i32, cy: i32, kind: aero_cursor_shape.CursorKind, draw: CursorDrawFn) void {
    if (!fb.isInitialized()) return;
    if (!cursor_visible) {
        invalidate();
        return;
    }
    const ext = softwareCursorExtent(cx, cy);
    sw_cursor_saved_len = fb.copyDrawBufferRectBytes(ext.x, ext.y, ext.w, ext.h, &sw_cursor_saved);
    sw_cursor_sx = ext.x;
    sw_cursor_sy = ext.y;
    sw_cursor_sw = ext.w;
    sw_cursor_sh = ext.h;
    sw_cursor_saved_kind = kind;
    draw(cx, cy);
    sw_cursor_placed = sw_cursor_saved_len > 0;
    markDirtyUnionFromPoints(cx, cy, cx, cy);
}

/// 仅指针移动或 **光标形态变化**（箭头/I-beam 等）：先恢复 save-under，再在新位置按当前形态 copy+draw。
/// 各形态位图同为 14×20，`softwareCursorExtent` 一致，故无需整场景重绘。
/// 返回 false 时调用方应整场景重绘。
pub fn moveOnly(cursor_visible: bool, cx: i32, cy: i32, prev_x: i32, prev_y: i32, kind: aero_cursor_shape.CursorKind, draw: CursorDrawFn) bool {
    if (!fb.isInitialized()) return false;
    if (!cursor_visible) return false;
    if (!sw_cursor_placed) return false;

    fb.pasteDrawBufferRectBytes(sw_cursor_sx, sw_cursor_sy, sw_cursor_sw, sw_cursor_sh, sw_cursor_saved[0..sw_cursor_saved_len]);

    const ext = softwareCursorExtent(cx, cy);
    sw_cursor_saved_len = fb.copyDrawBufferRectBytes(ext.x, ext.y, ext.w, ext.h, &sw_cursor_saved);
    if (sw_cursor_saved_len == 0) {
        invalidate();
        return false;
    }
    sw_cursor_sx = ext.x;
    sw_cursor_sy = ext.y;
    sw_cursor_sw = ext.w;
    sw_cursor_sh = ext.h;
    sw_cursor_saved_kind = kind;
    draw(cx, cy);
    markDirtyUnionFromPoints(prev_x, prev_y, cx, cy);
    return true;
}
