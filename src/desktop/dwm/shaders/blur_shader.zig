// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS DWM Shaders - Box Blur Implementation
//! Multi-pass box blur that approximates Gaussian blur.
//! Clean-room implementation based on public blur algorithms.

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

const MAX_LINE: usize = 4096;

// ============================================================================
// Blur State
// ============================================================================

var line_buf_r: [MAX_LINE]u32 = undefined;
var line_buf_g: [MAX_LINE]u32 = undefined;
var line_buf_b: [MAX_LINE]u32 = undefined;

// ============================================================================
// Pixel Operations
// ============================================================================

pub const PixelReader = struct {
    base: usize,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,

    pub fn readPixel(self: *const PixelReader, x: u32, y: u32) u32 {
        if (x >= self.width or y >= self.height) return 0;
        const bytes_pp = @as(u32, self.bpp) / 8;
        const ptr: [*]volatile u8 = @ptrFromInt(self.base);
        const off = y * self.pitch + x * bytes_pp;
        if (bytes_pp >= 3) {
            return @as(u32, ptr[off]) |
                (@as(u32, ptr[off + 1]) << 8) |
                (@as(u32, ptr[off + 2]) << 16);
        }
        return 0;
    }

    pub fn writePixel(self: *const PixelReader, x: u32, y: u32, color: u32) void {
        if (x >= self.width or y >= self.height) return;
        const bytes_pp = @as(u32, self.bpp) / 8;
        const ptr: [*]volatile u8 = @ptrFromInt(self.base);
        const off = y * self.pitch + x * bytes_pp;
        ptr[off] = @truncate(color);
        ptr[off + 1] = @truncate(color >> 8);
        ptr[off + 2] = @truncate(color >> 16);
        if (bytes_pp >= 4) {
            ptr[off + 3] = @truncate(color >> 24);
        }
    }
};

// ============================================================================
// Horizontal Blur
// ============================================================================

fn hblurReadRow(px: *const PixelReader, row: u32, x0: u32, x1: u32) void {
    var col: u32 = x0;
    while (col < x1) : (col += 1) {
        const c = px.readPixel(col, row);
        const idx = col - x0;
        line_buf_r[idx] = c & 0xFF;
        line_buf_g[idx] = (c >> 8) & 0xFF;
        line_buf_b[idx] = (c >> 16) & 0xFF;
    }
}

fn hblurWriteRow(px: *const PixelReader, row: u32, x0: u32, x1: u32, w: u32, radius: u32) void {
    var col: u32 = x0;
    while (col < x1) : (col += 1) {
        const idx = col - x0;
        const lo = if (idx >= radius) idx - radius else 0;
        const hi = @min(idx + radius + 1, w);
        const count = hi - lo;
        var sr: u32 = 0;
        var sg: u32 = 0;
        var sb: u32 = 0;
        var k: u32 = lo;
        while (k < hi) : (k += 1) {
            sr += line_buf_r[k];
            sg += line_buf_g[k];
            sb += line_buf_b[k];
        }
        px.writePixel(col, row, (sr / count) | ((sg / count) << 8) | ((sb / count) << 16));
    }
}

// ============================================================================
// Vertical Blur
// ============================================================================

fn vblurReadCol(px: *const PixelReader, col: u32, y0: u32, y1: u32) void {
    var row: u32 = y0;
    while (row < y1) : (row += 1) {
        const c = px.readPixel(col, row);
        const idx = row - y0;
        line_buf_r[idx] = c & 0xFF;
        line_buf_g[idx] = (c >> 8) & 0xFF;
        line_buf_b[idx] = (c >> 16) & 0xFF;
    }
}

fn vblurWriteCol(px: *const PixelReader, col: u32, y0: u32, y1: u32, h: u32, radius: u32) void {
    var row: u32 = y0;
    while (row < y1) : (row += 1) {
        const idx = row - y0;
        const lo = if (idx >= radius) idx - radius else 0;
        const hi = @min(idx + radius + 1, h);
        const count = hi - lo;
        var sr: u32 = 0;
        var sg: u32 = 0;
        var sb: u32 = 0;
        var k: u32 = lo;
        while (k < hi) : (k += 1) {
            sr += line_buf_r[k];
            sg += line_buf_g[k];
            sb += line_buf_b[k];
        }
        px.writePixel(col, row, (sr / count) | ((sg / count) << 8) | ((sb / count) << 16));
    }
}

// ============================================================================
// Box Blur Implementation
// ============================================================================

fn blurRectImpl(
    px: *const PixelReader,
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    w: u32,
    h: u32,
    passes: u8,
    radius: u32,
) void {
    var pass: u8 = 0;
    while (pass < passes) : (pass += 1) {
        // Horizontal blur pass
        var row: u32 = y0;
        while (row < y1) : (row += 1) {
            hblurReadRow(px, row, x0, x1);
            hblurWriteRow(px, row, x0, x1, w, radius);
        }

        // Vertical blur pass
        var vcol: u32 = x0;
        while (vcol < x1) : (vcol += 1) {
            vblurReadCol(px, vcol, y0, y1);
            vblurWriteCol(px, vcol, y0, y1, h, radius);
        }
    }
}

// ============================================================================
// Public API
// ============================================================================

pub fn blurRect(
    fb_addr: usize,
    fb_width: u32,
    fb_height: u32,
    fb_pitch: u32,
    fb_bpp: u8,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    rect_h: i32,
    radius: u32,
    passes: u8,
) void {
    if (rect_w <= 0 or rect_h <= 0 or radius == 0) return;

    const px = PixelReader{
        .base = fb_addr,
        .pitch = fb_pitch,
        .width = fb_width,
        .height = fb_height,
        .bpp = fb_bpp,
    };

    const x0: u32 = if (rect_x < 0) 0 else @intCast(rect_x);
    const y0: u32 = if (rect_y < 0) 0 else @intCast(rect_y);
    const x1: u32 = @min(x0 + @as(u32, @intCast(rect_w)), fb_width);
    const y1: u32 = @min(y0 + @as(u32, @intCast(rect_h)), fb_height);
    if (x0 >= x1 or y0 >= y1) return;

    const w = x1 - x0;
    const h = y1 - y0;
    if (w > MAX_LINE or h > MAX_LINE) return;

    blurRectImpl(&px, x0, y0, x1, y1, w, h, passes, radius);
}

// Light blur for dragging (single pass, reduced radius)
pub fn blurRectLight(
    fb_addr: usize,
    fb_width: u32,
    fb_height: u32,
    fb_pitch: u32,
    fb_bpp: u8,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    rect_h: i32,
    radius: u32,
) void {
    blurRect(fb_addr, fb_width, fb_height, fb_pitch, fb_bpp, rect_x, rect_y, rect_w, rect_h, radius / 2, 1);
}

// Box blur with configurable budget
pub const BlurBudget = struct {
    pixel_passes_remaining: u32,
    rect_calls_remaining: u32,
    max_single_rect_pixels: u32 = 1024 * 1024,
};

pub var g_blur_budget: BlurBudget = .{
    .pixel_passes_remaining = 500000,
    .rect_calls_remaining = 16,
};

pub fn resetBlurBudget(max_pixel_passes: u32, max_rect_calls: u32) void {
    g_blur_budget.pixel_passes_remaining = max_pixel_passes;
    g_blur_budget.rect_calls_remaining = max_rect_calls;
}

pub fn tryBlurRect(
    fb_addr: usize,
    fb_width: u32,
    fb_height: u32,
    fb_pitch: u32,
    fb_bpp: u8,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    rect_h: i32,
    radius: u32,
    passes: u8,
) bool {
    if (g_blur_budget.rect_calls_remaining == 0) return false;
    const area = @as(u32, @intCast(@abs(rect_w))) * @as(u32, @intCast(@abs(rect_h)));
    if (area > g_blur_budget.max_single_rect_pixels) return false;

    const passes32 = @as(u32, passes);
    const cost = area * passes32;
    if (cost > g_blur_budget.pixel_passes_remaining) return false;

    g_blur_budget.pixel_passes_remaining -= cost;
    g_blur_budget.rect_calls_remaining -= 1;

    blurRect(fb_addr, fb_width, fb_height, fb_pitch, fb_bpp, rect_x, rect_y, rect_w, rect_h, radius, passes);
    return true;
}
