// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/desktop/wallpaper_bitmap.zig
// Purpose: Draw build-embedded RGBA wallpaper presets (cover scaling) into the framebuffer.
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.

const std = @import("std");
const fb = @import("../core/framebuffer.zig");
const wd = @import("wallpaper_data");

/// Kernel framebuffer color packing: low=B, mid=G, high=R (see `theme.rgb` / `nt61_aero_defaults`).
fn packRgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, b) | (@as(u32, g) << 8) | (@as(u32, r) << 16);
}

fn sampleRgba(bytes: []const u8, sw: u32, sh: u32, sx: u32, sy: u32) u32 {
    if (sw == 0 or sh == 0 or bytes.len < 4) return 0;
    const x = @min(sx, sw - 1);
    const y = @min(sy, sh - 1);
    const i = (@as(usize, y) * @as(usize, sw) + @as(usize, x)) * 4;
    if (i + 3 >= bytes.len) return 0;
    const r = bytes[i];
    const g = bytes[i + 1];
    const b = bytes[i + 2];
    const a = bytes[i + 3];
    if (a == 255) return packRgb(r, g, b);
    if (a == 0) return packRgb(0, 0, 0);
    const rr = @as(u32, r) * @as(u32, a) / 255;
    const gg = @as(u32, g) * @as(u32, a) / 255;
    const bb = @as(u32, b) * @as(u32, a) / 255;
    return packRgb(@truncate(rr), @truncate(gg), @truncate(bb));
}

/// Map destination pixel (dx,dy) to source (sx,sy) using cover crop (centered).
fn coverMap(dx: u32, dy: u32, sw: u32, sh: u32, dw: u32, dh: u32) struct { sx: u32, sy: u32 } {
    if (sw == 0 or sh == 0 or dw == 0 or dh == 0) return .{ .sx = 0, .sy = 0 };
    const swdh = @as(u64, sw) * @as(u64, dh);
    const shdw = @as(u64, sh) * @as(u64, dw);
    const dx_d: u64 = if (dw <= 1) 1 else @intCast(dw - 1);
    const dy_d: u64 = if (dh <= 1) 1 else @intCast(dh - 1);

    if (swdh > shdw) {
        var vis_w: u32 = @intCast((@as(u64, dw) * @as(u64, sh)) / @as(u64, dh));
        if (vis_w == 0) vis_w = 1;
        if (vis_w > sw) vis_w = sw;
        const x0 = (sw - vis_w) / 2;
        const vw1: u64 = if (vis_w <= 1) 0 else @intCast(vis_w - 1);
        const sx = x0 + @as(u32, @intCast((@as(u64, dx) * vw1) / dx_d));
        const sy = @as(u32, @intCast((@as(u64, dy) * @as(u64, sh -| 1)) / dy_d));
        return .{ .sx = @min(sx, sw - 1), .sy = @min(sy, sh - 1) };
    }
    var vis_h: u32 = @intCast((@as(u64, dh) * @as(u64, sw)) / @as(u64, dw));
    if (vis_h == 0) vis_h = 1;
    if (vis_h > sh) vis_h = sh;
    const y0 = (sh - vis_h) / 2;
    const vh1: u64 = if (vis_h <= 1) 0 else @intCast(vis_h - 1);
    const sy = y0 + @as(u32, @intCast((@as(u64, dy) * vh1) / dy_d));
    const sx = @as(u32, @intCast((@as(u64, dx) * @as(u64, sw -| 1)) / dx_d));
    return .{ .sx = @min(sx, sw - 1), .sy = @min(sy, sh - 1) };
}

/// 与 `renderer_aero.wallpaper_preset_count`（12）一致；用于开始菜单局部重绘门闸。
/// 真值当且仅当该预设的嵌入位图在构建产物中非空尺寸；**非**「仅 Harmony 预设」专用逻辑。
pub fn presetSupportsPartialRedraw(preset: u8) bool {
    const sl = presetSlice(preset % 12) orelse return false;
    return sl.w > 0 and sl.h > 0;
}

fn presetSlice(preset: u8) ?struct { bytes: []const u8, w: u32, h: u32 } {
    return switch (preset) {
        0 => .{ .bytes = wd.p0[0..], .w = wd.p0_w, .h = wd.p0_h },
        1 => .{ .bytes = wd.p1[0..], .w = wd.p1_w, .h = wd.p1_h },
        2 => .{ .bytes = wd.p2[0..], .w = wd.p2_w, .h = wd.p2_h },
        3 => .{ .bytes = wd.p3[0..], .w = wd.p3_w, .h = wd.p3_h },
        4 => .{ .bytes = wd.p4[0..], .w = wd.p4_w, .h = wd.p4_h },
        5 => .{ .bytes = wd.p5[0..], .w = wd.p5_w, .h = wd.p5_h },
        6 => .{ .bytes = wd.p6[0..], .w = wd.p6_w, .h = wd.p6_h },
        7 => .{ .bytes = wd.p7[0..], .w = wd.p7_w, .h = wd.p7_h },
        8 => .{ .bytes = wd.p8[0..], .w = wd.p8_w, .h = wd.p8_h },
        9 => .{ .bytes = wd.p9[0..], .w = wd.p9_w, .h = wd.p9_h },
        10 => .{ .bytes = wd.p10[0..], .w = wd.p10_w, .h = wd.p10_h },
        11 => .{ .bytes = wd.p11[0..], .w = wd.p11_w, .h = wd.p11_h },
        else => null,
    };
}

/// Fill entire framebuffer with wallpaper `preset` (0..11).
pub fn drawPreset(preset: u8, scr_w: i32, scr_h: i32) void {
    drawPresetRegion(preset, scr_w, scr_h, 0, 0, scr_w, scr_h);
}

/// Redraw wallpaper in [rx,ry)+size intersected with screen (for dirty rectangles).
pub fn drawPresetRegion(preset: u8, scr_w: i32, scr_h: i32, rx: i32, ry: i32, rw: i32, rh: i32) void {
    if (!fb.isInitialized()) return;
    if (scr_w <= 0 or scr_h <= 0 or rw <= 0 or rh <= 0) return;
    const info = presetSlice(preset) orelse return;
    if (info.w == 0 or info.h == 0) return;

    const dw: u32 = @intCast(scr_w);
    const dh: u32 = @intCast(scr_h);
    const sw = info.w;
    const sh = info.h;

    // 脏区外包矩形用 i64 与屏幕求交，避免 `rx + rw` 等在 i32 上 Debug 溢出 panic。
    const sw_i = @as(i64, scr_w);
    const sh_i = @as(i64, scr_h);
    const x0 = @max(@as(i64, rx), 0);
    const y0 = @max(@as(i64, ry), 0);
    const x1 = @min(@as(i64, rx) + @as(i64, rw), sw_i);
    const y1 = @min(@as(i64, ry) + @as(i64, rh), sh_i);
    if (x0 >= x1 or y0 >= y1) return;

    var py: i32 = @intCast(y0);
    const y1_i: i32 = @intCast(y1);
    while (py < y1_i) : (py += 1) {
        var px: i32 = @intCast(x0);
        const x1_i: i32 = @intCast(x1);
        while (px < x1_i) : (px += 1) {
            const dx: u32 = @intCast(px);
            const dy: u32 = @intCast(py);
            const m = coverMap(dx, dy, sw, sh, dw, dh);
            const c = sampleRgba(info.bytes, sw, sh, m.sx, m.sy);
            fb.putPixel32(dx, dy, c);
        }
    }
}

test "all embedded wallpaper presets support partial redraw regions" {
    var p: u8 = 0;
    while (p < 12) : (p += 1) {
        try std.testing.expect(presetSupportsPartialRedraw(p));
    }
}
