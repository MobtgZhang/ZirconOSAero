// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS Graphics Rendering Engine (GRE)
//! Migrated from aero/src/renderer.zig
//! Implements GDI-style drawing operations on surfaces.

const std = @import("std");

// ============================================================================
// Color Utilities
// ============================================================================

pub fn rgb(r: u32, g: u32, b: u32) u32 {
    return r | (g << 8) | (b << 16);
}

pub fn rgba(r: u32, g: u32, b: u32, a: u32) u32 {
    return r | (g << 8) | (b << 16) | (a << 24);
}

pub fn getR(c: u32) u32 {
    return c & 0xFF;
}

pub fn getG(c: u32) u32 {
    return (c >> 8) & 0xFF;
}

pub fn getB(c: u32) u32 {
    return (c >> 16) & 0xFF;
}

pub fn getA(c: u32) u32 {
    return (c >> 24) & 0xFF;
}

// ============================================================================
// Framebuffer Operations
// ============================================================================

pub const Framebuffer = struct {
    base: usize,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u8,

    pub fn init(base: usize, width: u32, height: u32, pitch: u32, bpp: u8) Framebuffer {
        return .{
            .base = base,
            .width = width,
            .height = height,
            .pitch = pitch,
            .bpp = bpp,
        };
    }

    pub fn readPixel(self: *const Framebuffer, x: i32, y: i32) u32 {
        if (x < 0 or x >= @as(i32, @intCast(self.width)) or y < 0 or y >= @as(i32, @intCast(self.height))) return 0;
        const bytes_pp = @as(u32, self.bpp) / 8;
        const ptr: [*]volatile u8 = @ptrFromInt(self.base);
        const off = @as(u32, @intCast(y)) * self.pitch + @as(u32, @intCast(x)) * bytes_pp;
        if (bytes_pp >= 3) {
            return @as(u32, ptr[off]) | (@as(u32, ptr[off + 1]) << 8) | (@as(u32, ptr[off + 2]) << 16);
        }
        return 0;
    }

    pub fn writePixel(self: *const Framebuffer, x: i32, y: i32, color: u32) void {
        if (x < 0 or x >= @as(i32, @intCast(self.width)) or y < 0 or y >= @as(i32, @intCast(self.height))) return;
        const bytes_pp = @as(u32, self.bpp) / 8;
        const ptr: [*]volatile u8 = @ptrFromInt(self.base);
        const off = @as(u32, @intCast(y)) * self.pitch + @as(u32, @intCast(x)) * bytes_pp;
        ptr[off] = @truncate(color);
        ptr[off + 1] = @truncate(color >> 8);
        ptr[off + 2] = @truncate(color >> 16);
        if (bytes_pp >= 4) {
            ptr[off + 3] = @truncate(color >> 24);
        }
    }
};

// ============================================================================
// Basic Drawing Operations
// ============================================================================

pub fn fillRect(
    fb: *const Framebuffer,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: u32,
) void {
    if (w <= 0 or h <= 0) return;

    const x0: i32 = @max(0, x);
    const y0: i32 = @max(0, y);
    const x1: i32 = @min(@as(i32, @intCast(fb.width)), x + w);
    const y1: i32 = @min(@as(i32, @intCast(fb.height)), y + h);

    var row: i32 = y0;
    while (row < y1) : (row += 1) {
        var col: i32 = x0;
        while (col < x1) : (col += 1) {
            fb.writePixel(col, row, color);
        }
    }
}

pub fn fillRectAlpha(
    fb: *const Framebuffer,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: u32,
    alpha: u8,
) void {
    if (w <= 0 or h <= 0) return;

    const src_r = getR(color);
    const src_g = getG(color);
    const src_b = getB(color);
    const inv_alpha: u32 = 255 - @as(u32, alpha);

    const x0: i32 = @max(0, x);
    const y0: i32 = @max(0, y);
    const x1: i32 = @min(@as(i32, @intCast(fb.width)), x + w);
    const y1: i32 = @min(@as(i32, @intCast(fb.height)), y + h);

    var row: i32 = y0;
    while (row < y1) : (row += 1) {
        var col: i32 = x0;
        while (col < x1) : (col += 1) {
            const existing = fb.readPixel(col, row);
            const dst_r = getR(existing);
            const dst_g = getG(existing);
            const dst_b = getB(existing);

            const new_r = @as(u32, @intCast((src_r * alpha + dst_r * inv_alpha) / 255));
            const new_g = @as(u32, @intCast((src_g * alpha + dst_g * inv_alpha) / 255));
            const new_b = @as(u32, @intCast((src_b * alpha + dst_b * inv_alpha) / 255));

            fb.writePixel(col, row, rgb(new_r, new_g, new_b));
        }
    }
}

pub fn drawHLine(fb: *const Framebuffer, x: i32, y: i32, w: i32, color: u32) void {
    var col: i32 = x;
    const end = x + w;
    while (col < end) : (col += 1) {
        fb.writePixel(col, y, color);
    }
}

pub fn drawVLine(fb: *const Framebuffer, x: i32, y: i32, h: i32, color: u32) void {
    var row: i32 = y;
    const end = y + h;
    while (row < end) : (row += 1) {
        fb.writePixel(x, row, color);
    }
}

// ============================================================================
// Gradient Operations
// ============================================================================

pub fn drawGradientH(
    fb: *const Framebuffer,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color_left: u32,
    color_right: u32,
) void {
    if (w <= 0 or h <= 0) return;

    const r1 = getR(color_left);
    const g1 = getG(color_left);
    const b1 = getB(color_left);
    const r2 = getR(color_right);
    const g2 = getG(color_right);
    const b2 = getB(color_right);

    var col: i32 = 0;
    while (col < w) : (col += 1) {
        const t = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(w));
        const r = @as(u32, @intCast(@as(f32, @floatFromInt(r1)) * (1 - t) + @as(f32, @floatFromInt(r2)) * t));
        const g = @as(u32, @intCast(@as(f32, @floatFromInt(g1)) * (1 - t) + @as(f32, @floatFromInt(g2)) * t));
        const b = @as(u32, @intCast(@as(f32, @floatFromInt(b1)) * (1 - t) + @as(f32, @floatFromInt(b2)) * t));
        const c = rgb(r, g, b);

        var row: i32 = 0;
        while (row < h) : (row += 1) {
            fb.writePixel(x + col, y + row, c);
        }
    }
}

pub fn drawGradientV(
    fb: *const Framebuffer,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color_top: u32,
    color_bottom: u32,
) void {
    if (w <= 0 or h <= 0) return;

    const r1 = getR(color_top);
    const g1 = getG(color_top);
    const b1 = getB(color_top);
    const r2 = getR(color_bottom);
    const g2 = getG(color_bottom);
    const b2 = getB(color_bottom);

    var row: i32 = 0;
    while (row < h) : (row += 1) {
        const t = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(h));
        const r = @as(u32, @intCast(@as(f32, @floatFromInt(r1)) * (1 - t) + @as(f32, @floatFromInt(r2)) * t));
        const g = @as(u32, @intCast(@as(f32, @floatFromInt(g1)) * (1 - t) + @as(f32, @floatFromInt(g2)) * t));
        const b = @as(u32, @intCast(@as(f32, @floatFromInt(b1)) * (1 - t) + @as(f32, @floatFromInt(b2)) * t));
        const c = rgb(r, g, b);

        var col: i32 = 0;
        while (col < w) : (col += 1) {
            fb.writePixel(x + col, y + row, c);
        }
    }
}

// ============================================================================
// Alpha Blending
// ============================================================================

pub fn blendPixels(src: u32, dst: u32, alpha: u8) u32 {
    const src_a = @as(u32, alpha);
    const dst_a = 255 - src_a;

    const src_r = getR(src);
    const src_g = getG(src);
    const src_b = getB(src);

    const dst_r = getR(dst);
    const dst_g = getG(dst);
    const dst_b = getB(dst);

    const out_r = (src_r * src_a + dst_r * dst_a) / 255;
    const out_g = (src_g * src_a + dst_g * dst_a) / 255;
    const out_b = (src_b * src_a + dst_b * dst_a) / 255;

    return rgb(out_r, out_g, out_b);
}

// ============================================================================
// Blit Operations
// ============================================================================

pub fn blitSurface(
    dst: *const Framebuffer,
    src: *const Framebuffer,
    dst_x: i32,
    dst_y: i32,
    src_x: i32,
    src_y: i32,
    w: i32,
    h: i32,
    alpha: u8,
) void {
    if (w <= 0 or h <= 0) return;

    var row: i32 = 0;
    while (row < h) : (row += 1) {
        var col: i32 = 0;
        while (col < w) : (col += 1) {
            const sx = src_x + col;
            const sy = src_y + row;
            const dx = dst_x + col;
            const dy = dst_y + row;

            const src_pixel = src.readPixel(sx, sy);
            const dst_pixel = dst.readPixel(dx, dy);
            const blended = blendPixels(src_pixel, dst_pixel, alpha);
            dst.writePixel(dx, dy, blended);
        }
    }
}
