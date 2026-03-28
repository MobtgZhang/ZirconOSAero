//! Graphical framebuffer miniport (NT6: analog to display miniport + surface IOCTLs)
//! Pixel primitives, bulk ops, and IRP/IOCTL dispatch for the DWM/compositor path.
//! Original ZirconOS implementation; registers `\\Driver\\Framebuf` / `\\Device\\Framebuf0`.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");
const cjk_font = @import("cjk_font.zig");
const config_mod = @import("../../config/config.zig");
const frame_mod = @import("../../mm/frame.zig");

// ── Pixel Format ──

pub const PixelFormat = enum(u8) {
    rgb565 = 0,
    rgb888 = 1,
    xrgb8888 = 2,
    argb8888 = 3,
    bgr888 = 4,
    xbgr8888 = 5,
    indexed_8bpp = 6,
};

pub fn RGB(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) << 16 | @as(u32, g) << 8 | @as(u32, b);
}

pub fn ARGB(a: u8, r: u8, g: u8, b: u8) u32 {
    return @as(u32, a) << 24 | @as(u32, r) << 16 | @as(u32, g) << 8 | @as(u32, b);
}

pub fn getRed(color: u32) u8 {
    return @truncate((color >> 16) & 0xFF);
}

pub fn getGreen(color: u32) u8 {
    return @truncate((color >> 8) & 0xFF);
}

pub fn getBlue(color: u32) u8 {
    return @truncate(color & 0xFF);
}

pub fn getAlpha(color: u32) u8 {
    return @truncate((color >> 24) & 0xFF);
}

// ── Framebuffer Configuration ──

pub const FramebufferConfig = struct {
    address: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    bpp: u8 = 0,
    pixel_format: PixelFormat = .xrgb8888,
    double_buffer: bool = false,
    /// true：显存为 BGRx（首字节蓝，UEFI/QEMU GOP 常见）；false：RGBx（首字节红）
    pixel_bgr: bool = true,
};

// ── Rect / Point types ──

pub const Point = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.x + other.w and self.x + self.w > other.x and
            self.y < other.y + other.h and self.y + self.h > other.y;
    }
};

/// `origin + delta` 与 `limit` 比较后再截断为 u32，避免 `x0 + w` 在 u32 上先溢出（Debug 下 panic）。
fn addU32Clamped(origin: u32, delta: u32, limit: u32) u32 {
    const s = @as(u64, origin) + @as(u64, delta);
    const l = @as(u64, limit);
    return @intCast(@min(s, l));
}

/// `y * pitch + x * bytes_pp`，u64 中间值避免 u32 乘法在 Debug 下溢出。
fn pixelByteOffset(x: u32, y: u32, bytes_pp: u32) usize {
    const p = @as(u64, y) * @as(u64, fb_config.pitch) + @as(u64, x) * @as(u64, bytes_pp);
    return @intCast(p);
}

// ── Dirty Region Tracking ──

const MAX_DIRTY_RECTS: usize = 32;

var dirty_rects: [MAX_DIRTY_RECTS]Rect = [_]Rect{.{}} ** MAX_DIRTY_RECTS;
var dirty_count: usize = 0;

pub fn addDirtyRect(r: Rect) void {
    if (dirty_count < MAX_DIRTY_RECTS) {
        dirty_rects[dirty_count] = r;
        dirty_count += 1;
    }
}

pub fn markDirtyRegion(x: i32, y: i32, w: i32, h: i32) void {
    if (w <= 0 or h <= 0) return;
    addDirtyRect(.{ .x = x, .y = y, .w = w, .h = h });
}

pub fn markFullScreenDirty() void {
    dirty_count = MAX_DIRTY_RECTS;
}

// ── Driver State ──

var fb_config: FramebufferConfig = .{};
var back_buffer_addr: usize = 0;
var back_buffer_size: usize = 0;

var driver_idx: u32 = 0;
var device_idx: u32 = 0;
var driver_initialized: bool = false;
var config_ready: bool = false;
var total_draw_calls: u64 = 0;
var total_flips: u64 = 0;

// ── Double / triple off-screen buffering ──
// 双缓冲：单离屏槽 + GOP。三缓冲（乒乓）：两离屏槽 + GOP；present 后切换 draw_slot（概念见 mdcs/ideas.md，自研非 DXGI）。
// 单缓冲（double_buffer_active=false）：getDrawBuffer() 即 GOP；flipDirty() 仅清 dirty 计数、不做 memcpy（屏前直绘 + 软件光标 save-under 同面）。
const BACK_BUF_MAX: usize = 10 * 1024 * 1024; // 10 MB – covers up to 1920×1080@32bpp
var back_buf: [BACK_BUF_MAX]u8 align(1) = undefined;
var double_buffer_active: bool = false;
/// 第二离屏槽；flip 提交后 draw_slot 翻转。
var triple_buffer_active: bool = false;
var draw_slot: u32 = 0;
/// 单槽字节数 (= pitch*height)。
var bytes_per_slot: usize = 0;
/// `allocContiguous` 后备时使用；可能容纳 1 或 2 槽。
var back_buffer_heap_nframes: usize = 0;

// ── IOCTL Codes ──

pub const IOCTL_FB_GET_CONFIG: u32 = 0x00090000;
pub const IOCTL_FB_SET_CONFIG: u32 = 0x00090004;
pub const IOCTL_FB_MAP_BUFFER: u32 = 0x00090008;
pub const IOCTL_FB_FLIP: u32 = 0x0009000C;
pub const IOCTL_FB_FILL_RECT: u32 = 0x00090010;
pub const IOCTL_FB_COPY_RECT: u32 = 0x00090014;
pub const IOCTL_FB_DRAW_LINE: u32 = 0x00090018;
pub const IOCTL_FB_GET_STATS: u32 = 0x0009001C;

// ── Internal Helpers ──

fn activeDrawSlotOffset() usize {
    if (triple_buffer_active) return @as(usize, draw_slot) * bytes_per_slot;
    return 0;
}

fn drawBufferBytePtr() [*]u8 {
    const off = activeDrawSlotOffset();
    if (back_buffer_addr != 0) {
        return @ptrFromInt(back_buffer_addr + off);
    }
    return @as([*]u8, @ptrCast(&back_buf)) + off;
}

fn getDrawBuffer() [*]volatile u8 {
    if (double_buffer_active) {
        return @volatileCast(drawBufferBytePtr());
    }
    return @ptrFromInt(fb_config.address);
}

fn backBufSrcPtr() [*]const u8 {
    return drawBufferBytePtr();
}

/// Pre-pack a color into the native pixel word so that solid fills can write
/// one u32 per pixel instead of four individual bytes.
fn packPixel32(color: u32) u32 {
    if (fb_config.pixel_bgr) {
        return color | 0xFF000000;
    } else {
        const b = color & 0xFF;
        const g = (color >> 8) & 0xFF;
        const r = (color >> 16) & 0xFF;
        return r | (g << 8) | (b << 16) | 0xFF000000;
    }
}

/// color 为与 `display.rgb` 一致：低 8 位 B，中 G，高 R（无 Alpha 语义）
fn writePixel4(ptr: [*]volatile u8, offset: usize, color: u32) void {
    const b = color & 0xFF;
    const g = (color >> 8) & 0xFF;
    const r = (color >> 16) & 0xFF;
    if (fb_config.pixel_bgr) {
        ptr[offset] = @truncate(b);
        ptr[offset + 1] = @truncate(g);
        ptr[offset + 2] = @truncate(r);
    } else {
        ptr[offset] = @truncate(r);
        ptr[offset + 1] = @truncate(g);
        ptr[offset + 2] = @truncate(b);
    }
    // XRGB：Alpha 为 0 时部分固件/合成路径会当作全透明，强制不透明
    ptr[offset + 3] = 0xFF;
}

fn writePixel3(ptr: [*]volatile u8, offset: usize, color: u32) void {
    const b = color & 0xFF;
    const g = (color >> 8) & 0xFF;
    const r = (color >> 16) & 0xFF;
    if (fb_config.pixel_bgr) {
        ptr[offset] = @truncate(b);
        ptr[offset + 1] = @truncate(g);
        ptr[offset + 2] = @truncate(r);
    } else {
        ptr[offset] = @truncate(r);
        ptr[offset + 1] = @truncate(g);
        ptr[offset + 2] = @truncate(b);
    }
}

// ── Pixel Operations ──

pub fn putPixel32(x: u32, y: u32, color: u32) void {
    if (x >= fb_config.width or y >= fb_config.height) return;
    const bpp = fb_config.bpp;
    const bytes_pp = @as(u32, bpp) / 8;
    const offset = pixelByteOffset(x, y, bytes_pp);
    const ptr = getDrawBuffer();

    if (bytes_pp >= 4) {
        writePixel4(ptr, offset, color);
    } else if (bytes_pp == 3) {
        writePixel3(ptr, offset, color);
    } else if (bytes_pp == 2) {
        const r: u16 = @truncate((color >> 19) & 0x1F);
        const g: u16 = @truncate((color >> 10) & 0x3F);
        const b: u16 = @truncate((color >> 3) & 0x1F);
        const c16: u16 = (r << 11) | (g << 5) | b;
        ptr[offset] = @truncate(c16);
        ptr[offset + 1] = @truncate(c16 >> 8);
    }
}

pub fn getPixel32(x: u32, y: u32) u32 {
    if (x >= fb_config.width or y >= fb_config.height) return 0;
    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const offset = pixelByteOffset(x, y, bytes_pp);
    const ptr = getDrawBuffer();

    if (bytes_pp >= 3) {
        if (fb_config.pixel_bgr) {
            return @as(u32, ptr[offset]) |
                (@as(u32, ptr[offset + 1]) << 8) |
                (@as(u32, ptr[offset + 2]) << 16) |
                if (bytes_pp == 4) (@as(u32, ptr[offset + 3]) << 24) else 0;
        } else {
            const pr = ptr[offset];
            const pg = ptr[offset + 1];
            const pb = ptr[offset + 2];
            const pa = if (bytes_pp == 4) ptr[offset + 3] else 0;
            return pb | (@as(u32, pg) << 8) | (@as(u32, pr) << 16) | (@as(u32, pa) << 24);
        }
    }
    return 0;
}

/// Alpha-blend a single pixel at (x, y) with the given color and alpha.
/// Used by material effects like Reveal Highlight.
pub fn blendPixel(x: u32, y: u32, color: u32, alpha: u8) void {
    if (x >= fb_config.width or y >= fb_config.height) return;
    if (alpha == 0) return;
    const existing = getPixel32(x, y);
    const er: u32 = (existing >> 0) & 0xFF;
    const eg: u32 = (existing >> 8) & 0xFF;
    const eb: u32 = (existing >> 16) & 0xFF;
    const cr: u32 = (color >> 0) & 0xFF;
    const cg: u32 = (color >> 8) & 0xFF;
    const cb: u32 = (color >> 16) & 0xFF;
    const a: u32 = @intCast(alpha);
    const inv: u32 = 255 - a;
    const nr = (er * inv + cr * a) / 255;
    const ng = (eg * inv + cg * a) / 255;
    const nb = (eb * inv + cb * a) / 255;
    putPixel32(x, y, nr | (ng << 8) | (nb << 16));
}

// ── Optimized Drawing Primitives ──

fn fillRowDirect(py: u32, x0: u32, x1: u32, color: u32) void {
    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();
    const row_offset = pixelByteOffset(x0, py, bytes_pp);
    const count = x1 - x0;

    if (bytes_pp == 4) {
        const pxval = packPixel32(color);
        const base_addr = @intFromPtr(ptr) + row_offset;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const word_ptr: *align(1) volatile u32 = @ptrFromInt(base_addr + @as(usize, i) * 4);
            word_ptr.* = pxval;
        }
    } else if (bytes_pp == 3) {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            writePixel3(ptr, row_offset + @as(usize, i) * 3, color);
        }
    } else {
        var px: u32 = x0;
        while (px < x1) : (px += 1) {
            putPixel32(px, py, color);
        }
    }
}

pub fn fillRect(x: i32, y: i32, w: i32, h: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = addU32Clamped(x0, @intCast(w), fb_config.width);
    const y1: u32 = addU32Clamped(y0, @intCast(h), fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        fillRowDirect(py, x0, x1, color);
    }

    total_draw_calls += 1;
    addDirtyRect(.{ .x = x, .y = y, .w = w, .h = h });
}

fn clampDrawCoordI64(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

pub fn drawRect(x: i32, y: i32, w: i32, h: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    drawHLine(x, y, w, color);
    drawHLine(x, clampDrawCoordI64(@as(i64, y) + @as(i64, h) - 1), w, color);
    drawVLine(x, y, h, color);
    drawVLine(clampDrawCoordI64(@as(i64, x) + @as(i64, w) - 1), y, h, color);
}

pub fn drawHLine(x: i32, y: i32, length: i32, color: u32) void {
    if (length <= 0 or y < 0 or y >= @as(i32, @intCast(fb_config.height))) return;
    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const x1: u32 = addU32Clamped(x0, @intCast(length), fb_config.width);
    if (x0 >= x1) return;
    fillRowDirect(@intCast(y), x0, x1, color);
}

pub fn drawVLine(x: i32, y: i32, length: i32, color: u32) void {
    if (length <= 0 or x < 0 or x >= @as(i32, @intCast(fb_config.width))) return;
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const y1: u32 = addU32Clamped(y0, @intCast(length), fb_config.height);
    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        putPixel32(@intCast(x), py, color);
    }
}

pub fn drawGradientH(x: i32, y: i32, w: i32, h: i32, color1: u32, color2: u32) void {
    if (w <= 0 or h <= 0) return;
    const uw: u32 = @intCast(w);
    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = addU32Clamped(x0, uw, fb_config.width);
    const y1: u32 = addU32Clamped(y0, @intCast(h), fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();
    const row_pixels = x1 - x0;
    const base_x: u32 = if (x < 0) 0 else @intCast(x);

    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        const row_offset = pixelByteOffset(x0, py, bytes_pp);
        var px: u32 = 0;
        while (px < row_pixels) : (px += 1) {
            const t = (x0 + px) -| base_x;
            const color = interpolateColor(color1, color2, t, uw);
            if (bytes_pp == 4) {
                writePixel4(ptr, row_offset + @as(usize, px) * 4, color);
            } else if (bytes_pp == 3) {
                writePixel3(ptr, row_offset + @as(usize, px) * 3, color);
            } else {
                putPixel32(x0 + px, py, color);
            }
        }
    }
    total_draw_calls += 1;
    addDirtyRect(.{ .x = x, .y = y, .w = w, .h = h });
}

pub fn drawGradientV(x: i32, y: i32, w: i32, h: i32, color1: u32, color2: u32) void {
    if (w <= 0 or h <= 0) return;
    const uh: u32 = @intCast(h);
    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = addU32Clamped(x0, @intCast(w), fb_config.width);
    const y1: u32 = addU32Clamped(y0, uh, fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    const base_y: u32 = if (y < 0) 0 else @intCast(y);
    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        const t = py -| base_y;
        const color = interpolateColor(color1, color2, t, uh);
        fillRowDirect(py, x0, x1, color);
    }
    total_draw_calls += 1;
    addDirtyRect(.{ .x = x, .y = y, .w = w, .h = h });
}

pub fn interpolateColor(c1: u32, c2: u32, t: u32, total: u32) u32 {
    if (total == 0) return c1;
    const r1 = c1 & 0xFF;
    const g1 = (c1 >> 8) & 0xFF;
    const b1 = (c1 >> 16) & 0xFF;
    const r2 = c2 & 0xFF;
    const g2 = (c2 >> 8) & 0xFF;
    const b2 = (c2 >> 16) & 0xFF;

    const r = blendChannel(r1, r2, t, total);
    const g = blendChannel(g1, g2, t, total);
    const b = blendChannel(b1, b2, t, total);

    return (r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16);
}

fn blendChannel(a: u32, b: u32, t: u32, total: u32) u32 {
    if (b >= a) {
        const da: u64 = b - a;
        return @truncate(a + @as(u32, @intCast(da * @as(u64, t) / @as(u64, total))));
    } else {
        const da: u64 = a - b;
        return @truncate(a - @as(u32, @intCast(da * @as(u64, t) / @as(u64, total))));
    }
}

pub fn clearScreen(color: u32) void {
    if (fb_config.width == 0 or fb_config.height == 0) return;
    const bytes_pp = @as(u32, fb_config.bpp) / 8;

    if (bytes_pp == 4) {
        const pxval = packPixel32(color);
        const ptr = getDrawBuffer();
        const base_addr = @intFromPtr(ptr);
        const total: usize = @intCast(@as(u64, fb_config.pitch) * @as(u64, fb_config.height));
        var off: usize = 0;
        while (off < total) : (off += 4) {
            const word_ptr: *align(1) volatile u32 = @ptrFromInt(base_addr + off);
            word_ptr.* = pxval;
        }
        total_draw_calls += 1;
    } else {
        fillRect(0, 0, @intCast(fb_config.width), @intCast(fb_config.height), color);
    }
}

// ── Text Rendering (8x16 bitmap font) ──

const CHAR_W: u32 = 8;
const CHAR_H: u32 = 16;

pub fn drawChar(x: i32, y: i32, ch: u8, fg: u32, bg: u32) void {
    const glyph = getGlyph(ch);
    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();

    var dy: u32 = 0;
    while (dy < CHAR_H) : (dy += 1) {
        const py = if (y < 0) return else @as(u32, @intCast(y)) + dy;
        if (py >= fb_config.height) break;
        const bits = glyph[dy];

        var dx: u32 = 0;
        while (dx < CHAR_W) : (dx += 1) {
            const px = if (x < 0) continue else @as(u32, @intCast(x)) + dx;
            if (px >= fb_config.width) break;
            const on = (bits >> @intCast(7 - dx)) & 1;
            const color: u32 = if (on != 0) fg else bg;
            const off = pixelByteOffset(px, py, bytes_pp);
            if (bytes_pp == 4) {
                writePixel4(ptr, off, color);
            } else if (bytes_pp == 3) {
                writePixel3(ptr, off, color);
            }
        }
    }
}

pub fn drawCharTransparent(x: i32, y: i32, ch: u8, fg: u32) void {
    const glyph = getGlyph(ch);

    var dy: u32 = 0;
    while (dy < CHAR_H) : (dy += 1) {
        const py_i = y + @as(i32, @intCast(dy));
        if (py_i < 0 or py_i >= @as(i32, @intCast(fb_config.height))) continue;
        const bits = glyph[dy];

        var dx: u32 = 0;
        while (dx < CHAR_W) : (dx += 1) {
            if ((bits >> @intCast(7 - dx)) & 1 != 0) {
                const px_i = x + @as(i32, @intCast(dx));
                if (px_i >= 0 and px_i < @as(i32, @intCast(fb_config.width))) {
                    putPixel32(@intCast(px_i), @intCast(py_i), fg);
                }
            }
        }
    }
}

fn drawCjk16Transparent(x: i32, y: i32, rows: [16]u16, fg: u32) void {
    var dy: u32 = 0;
    while (dy < cjk_font.CJK_H) : (dy += 1) {
        const py_i = y + @as(i32, @intCast(dy));
        if (py_i < 0 or py_i >= @as(i32, @intCast(fb_config.height))) continue;
        const bits = rows[dy];
        var dx: u32 = 0;
        while (dx < cjk_font.CJK_W) : (dx += 1) {
            if ((bits >> @intCast(15 - dx)) & 1 != 0) {
                const px_i = x + @as(i32, @intCast(dx));
                if (px_i >= 0 and px_i < @as(i32, @intCast(fb_config.width))) {
                    putPixel32(@intCast(px_i), @intCast(py_i), fg);
                }
            }
        }
    }
}

fn drawTextTransparentClippedInner(x: i32, y: i32, text: []const u8, fg: u32, clip_max_x: ?i32) void {
    const view = std.unicode.Utf8View.init(text) catch {
        var cx64 = @as(i64, x);
        for (text) |b| {
            if (clip_max_x) |mx| {
                if (cx64 + @as(i64, CHAR_W) > @as(i64, mx)) break;
            }
            const cx_clamped = std.math.clamp(cx64, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32)));
            const cxi: i32 = @intCast(cx_clamped);
            drawCharTransparent(cxi, y, b, fg);
            cx64 += @as(i64, CHAR_W);
        }
        return;
    };
    var it = view.iterator();
    var cx64 = @as(i64, x);
    while (it.nextCodepoint()) |cp| {
        const adv64 = @as(i64, @intCast(cjk_font.codepointWidth(cp)));
        if (clip_max_x) |mx| {
            if (cx64 + adv64 > @as(i64, mx)) break;
        }
        const cx_clamped = std.math.clamp(cx64, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32)));
        const cxi: i32 = @intCast(cx_clamped);
        if (cp < 0x80) {
            drawCharTransparent(cxi, y, @truncate(cp), fg);
        } else if (cjk_font.lookup(cp)) |rows| {
            drawCjk16Transparent(cxi, y, rows, fg);
        } else if (cjk_font.isWideCodepoint(cp)) {
            drawCjk16Transparent(cxi, y, cjk_font.tofu_rows, fg);
        } else {
            drawCharTransparent(cxi, y, '?', fg);
        }
        cx64 += adv64;
    }
}

/// 在 [x, x_max_excl) 内绘制 UTF-8 文本，超出右边界则截断。
pub fn drawTextTransparentClipped(x: i32, y: i32, x_max_excl: i32, text: []const u8, fg: u32) void {
    drawTextTransparentClippedInner(x, y, text, fg, x_max_excl);
}

pub fn drawText(x: i32, y: i32, text: []const u8, fg: u32, bg: u32) void {
    var cx = x;
    for (text) |ch| {
        if (cx + @as(i32, CHAR_W) > @as(i32, @intCast(fb_config.width))) break;
        drawChar(cx, y, ch, fg, bg);
        cx += @as(i32, CHAR_W);
    }
}

pub fn drawTextTransparent(x: i32, y: i32, text: []const u8, fg: u32) void {
    drawTextTransparentClippedInner(x, y, text, fg, @intCast(fb_config.width));
}

/// Aero / Win7 风格 UI 文本：轻微投影，减轻纯 8×16 点阵「固件控制台」观感（内核自绘，与 UEFI ConOut 无关）。
pub fn drawTextTransparentUi(x: i32, y: i32, text: []const u8, fg: u32) void {
    const r = @as(u32, getRed(fg)) * 12 / 40;
    const g = @as(u32, getGreen(fg)) * 12 / 40;
    const b = @as(u32, getBlue(fg)) * 12 / 40;
    const shadow = (r << 16) | (g << 8) | b;
    drawTextTransparent(x + 1, y + 1, text, shadow);
    drawTextTransparent(x, y, text, fg);
}

/// `drawTextTransparentUi` 在矩形内水平垂直居中（字宽与 `textWidth` / UTF-8 路径一致）。
pub fn drawTextTransparentUiCenteredInRect(rx: i32, ry: i32, rw: i32, rh: i32, text: []const u8, fg: u32) void {
    if (rw <= 0 or rh <= 0) return;
    const tw = textWidth(text);
    var tx = rx + @divTrunc(rw - tw, 2);
    if (tx < rx) tx = rx;
    const ty = ry + @divTrunc(rh - @as(i32, CHAR_H), 2);
    drawTextTransparentUi(tx, ty, text, fg);
}

/// 2× / 3× scaled glyphs for taskbar and status lines (clearer than 8×16 on large panels).
pub fn drawCharTransparentScaled(x: i32, y: i32, ch: u8, fg: u32, scale: u32) void {
    if (scale < 1) return;
    const glyph = getGlyph(ch);
    var dy: u32 = 0;
    while (dy < CHAR_H) : (dy += 1) {
        const bits = glyph[dy];
        var dx: u32 = 0;
        while (dx < CHAR_W) : (dx += 1) {
            if ((bits >> @intCast(7 - dx)) & 1 != 0) {
                const px = x + @as(i32, @intCast(@as(u64, dx) *% @as(u64, scale)));
                const py = y + @as(i32, @intCast(@as(u64, dy) *% @as(u64, scale)));
                fillRect(px, py, @as(i32, @intCast(scale)), @as(i32, @intCast(scale)), fg);
            }
        }
    }
}

pub fn drawTextTransparentScaled(x: i32, y: i32, text: []const u8, fg: u32, scale: u32) void {
    if (scale < 1) return;
    var cx = x;
    const adv: i32 = @as(i32, @intCast(@as(u64, CHAR_W) *% @as(u64, scale)));
    const fb_w_i64: i64 = @intCast(fb_config.width);
    for (text) |ch| {
        if (@as(i64, cx) + @as(i64, adv) > fb_w_i64) break;
        drawCharTransparentScaled(cx, y, ch, fg, scale);
        cx += adv;
    }
}

pub fn textWidthScaled(text: []const u8, scale: u32) i32 {
    if (scale < 1) return 0;
    const prod = @as(u128, text.len) *% @as(u128, CHAR_W) *% @as(u128, scale);
    const capped = @min(prod, @as(u128, std.math.maxInt(i32)));
    return @as(i32, @intCast(capped));
}

pub fn drawTextCentered(x: i32, y: i32, w: i32, h: i32, text: []const u8, fg: u32) void {
    const text_w: i32 = textWidth(text);
    const tx = x + @divTrunc(w - text_w, 2);
    const ty = y + @divTrunc(h - @as(i32, CHAR_H), 2);
    drawTextTransparent(tx, ty, text, fg);
}

pub fn textWidth(text: []const u8) i32 {
    const view = std.unicode.Utf8View.init(text) catch {
        const prod = @as(u128, text.len) *% @as(u128, CHAR_W);
        const capped = @min(prod, @as(u128, std.math.maxInt(i32)));
        return @as(i32, @intCast(capped));
    };
    var it = view.iterator();
    var w64: i64 = 0;
    while (it.nextCodepoint()) |cp| {
        w64 += @as(i64, @intCast(cjk_font.codepointWidth(cp)));
        if (w64 > std.math.maxInt(i32)) return std.math.maxInt(i32);
    }
    const w_clamped = std.math.clamp(w64, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32)));
    return @as(i32, @intCast(w_clamped));
}

// ── Rounded Rectangle ──

pub fn fillRoundedRect(x: i32, y: i32, w: i32, h: i32, radius: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    const r = @min(radius, @min(@divTrunc(w, 2), @divTrunc(h, 2)));

    fillRect(x + r, y, w - 2 * r, r, color);
    fillRect(x, y + r, w, h - 2 * r, color);
    fillRect(x + r, y + h - r, w - 2 * r, r, color);

    fillCircleQuarter(x + r, y + r, r, 0, color);
    fillCircleQuarter(x + w - r - 1, y + r, r, 1, color);
    fillCircleQuarter(x + r, y + h - r - 1, r, 2, color);
    fillCircleQuarter(x + w - r - 1, y + h - r - 1, r, 3, color);
}

fn fillCircleQuarter(cx: i32, cy: i32, radius: i32, quarter: u2, color: u32) void {
    if (radius <= 0) return;
    const r64 = @as(i64, radius);
    const r2 = r64 * r64;
    var dy: i32 = 0;
    while (dy <= radius) : (dy += 1) {
        var dx: i32 = 0;
        while (dx <= radius) : (dx += 1) {
            const dx64 = @as(i64, dx);
            const dy64 = @as(i64, dy);
            if (dx64 * dx64 + dy64 * dy64 <= r2) {
                const px: i32 = switch (quarter) {
                    0 => cx - dx,
                    1 => cx + dx,
                    2 => cx - dx,
                    3 => cx + dx,
                };
                const py: i32 = switch (quarter) {
                    0 => cy - dy,
                    1 => cy - dy,
                    2 => cy + dy,
                    3 => cy + dy,
                };
                if (px >= 0 and px < @as(i32, @intCast(fb_config.width)) and
                    py >= 0 and py < @as(i32, @intCast(fb_config.height)))
                {
                    putPixel32(@intCast(px), @intCast(py), color);
                }
            }
        }
    }
}

/// Filled circle centered at `(cx, cy)` with integer radius (bounding box `2r×2r`).
pub fn fillCircle(cx: i32, cy: i32, radius: i32, color: u32) void {
    if (radius <= 0) return;
    const d = 2 * radius;
    fillRoundedRect(cx - radius, cy - radius, d, d, radius, color);
}

/// Aero-style orb sheen: blend `sheen_rgb` toward the top and upper-left inside the disk.
/// Ref: public Win7 Aero orb appearance (gloss + sphere read); clean-room pixel recipe.
pub fn aeroSheenDisk(cx: i32, cy: i32, radius: i32, sheen_rgb: u32) void {
    if (radius <= 0) return;
    const r64 = @as(i64, radius);
    const r2 = r64 * r64;
    const top = cy - radius;
    const span: i32 = @max(1, 2 * radius);

    var py = cy - radius;
    while (py <= cy + radius) : (py += 1) {
        const dy64 = @as(i64, py - cy);
        const from_top: i32 = py - top;
        const base_a: u32 = @intCast(@min(95, @max(0, @divTrunc(from_top * 95, span))));
        if (base_a == 0) continue;

        var px = cx - radius;
        while (px <= cx + radius) : (px += 1) {
            const dx64 = @as(i64, px - cx);
            if (dx64 * dx64 + dy64 * dy64 > r2) continue;
            if (px < 0 or py < 0) continue;
            const ux: u32 = @intCast(px);
            const uy: u32 = @intCast(py);
            if (ux >= fb_config.width or uy >= fb_config.height) continue;

            var a: u32 = base_a;
            if (px <= cx and py <= cy + @divTrunc(radius, 4)) {
                a +|= 42;
            }
            if (a > 155) a = 155;
            blendPixel(ux, uy, sheen_rgb, @intCast(a));
        }
    }
    markDirtyRegion(cx - radius, cy - radius, 2 * radius + 1, 2 * radius + 1);
}

// ── 3D-style border effects ──

pub fn draw3DRect(x: i32, y: i32, w: i32, h: i32, highlight: u32, shadow: u32) void {
    if (w <= 0 or h <= 0) return;
    drawHLine(x, y, w, highlight);
    drawVLine(x, y, h, highlight);
    drawHLine(x, clampDrawCoordI64(@as(i64, y) + @as(i64, h) - 1), w, shadow);
    drawVLine(clampDrawCoordI64(@as(i64, x) + @as(i64, w) - 1), y, h, shadow);
}

// ── Aero Glass Blur (Multi-pass Box Blur) ──
// Three passes of separable box blur approximate a Gaussian blur.
// Operates directly on the framebuffer using a static line buffer.
// 每像素内层循环随 radius 增长；中长期可改滑动窗口累和或降采样 blur 再上采样（自研，见 DesktopManagerSpec §8）。

const BLUR_MAX_LINE: usize = 4096;
var blur_line: [BLUR_MAX_LINE]u32 = [_]u32{0} ** BLUR_MAX_LINE;

pub fn boxBlurRect(x: i32, y: i32, w: i32, h: i32, radius: u32, passes: u32) void {
    if (w <= 0 or h <= 0 or radius == 0 or passes == 0) return;
    if (!config_ready) return;
    if (fb_config.bpp < 24) return;

    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = addU32Clamped(x0, @intCast(w), fb_config.width);
    const y1: u32 = addU32Clamped(y0, @intCast(h), fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    const rw = x1 - x0;
    const rh = y1 - y0;
    if (rw > BLUR_MAX_LINE or rh > BLUR_MAX_LINE) return;

    const buf = getDrawBuffer();
    const pitch = fb_config.pitch;
    const bpp: u32 = @as(u32, fb_config.bpp) / 8;

    var pass: u32 = 0;
    while (pass < passes) : (pass += 1) {
        // Horizontal pass: process each row
        var row: u32 = y0;
        while (row < y1) : (row += 1) {
            const row_base: usize = @as(usize, row) * @as(usize, pitch) + @as(usize, x0) * @as(usize, bpp);
            // Read entire row into blur_line as packed XRGB u32
            var i: u32 = 0;
            while (i < rw) : (i += 1) {
                const off = row_base + @as(usize, i) * @as(usize, bpp);
                blur_line[i] = @as(u32, buf[off]) | (@as(u32, buf[off + 1]) << 8) | (@as(u32, buf[off + 2]) << 16);
            }
            // Running-sum horizontal blur (u64 sums: wide rects × large radius would overflow u32)
            i = 0;
            while (i < rw) : (i += 1) {
                const lo: u32 = if (i >= radius) i - radius else 0;
                const hi_u64 = @as(u64, i) + @as(u64, radius) + 1;
                const hi: u32 = if (hi_u64 > rw) rw else @intCast(hi_u64);
                if (hi <= lo) continue;
                const cnt: u64 = hi - lo;
                var sr: u64 = 0;
                var sg: u64 = 0;
                var sb: u64 = 0;
                var k: u32 = lo;
                while (k < hi) : (k += 1) {
                    const px = blur_line[k];
                    sr += @as(u64, px & 0xFF);
                    sg += @as(u64, (px >> 8) & 0xFF);
                    sb += @as(u64, (px >> 16) & 0xFF);
                }
                const off = row_base + @as(usize, i) * @as(usize, bpp);
                const rb: u8 = @truncate(sr / cnt);
                const gb: u8 = @truncate(sg / cnt);
                const bb: u8 = @truncate(sb / cnt);
                buf[off] = rb;
                buf[off + 1] = gb;
                buf[off + 2] = bb;
            }
        }

        // Vertical pass: process each column
        var col: u32 = x0;
        while (col < x1) : (col += 1) {
            const col_off: usize = @as(usize, col) * @as(usize, bpp);
            // Read column pixels into blur_line
            var j: u32 = 0;
            while (j < rh) : (j += 1) {
                const off = @as(usize, y0 + j) * @as(usize, pitch) + col_off;
                blur_line[j] = @as(u32, buf[off]) | (@as(u32, buf[off + 1]) << 8) | (@as(u32, buf[off + 2]) << 16);
            }
            // Running-sum vertical blur
            j = 0;
            while (j < rh) : (j += 1) {
                const lo: u32 = if (j >= radius) j - radius else 0;
                const hi_u64 = @as(u64, j) + @as(u64, radius) + 1;
                const hi: u32 = if (hi_u64 > rh) rh else @intCast(hi_u64);
                if (hi <= lo) continue;
                const cnt: u64 = hi - lo;
                var sr: u64 = 0;
                var sg: u64 = 0;
                var sb: u64 = 0;
                var k: u32 = lo;
                while (k < hi) : (k += 1) {
                    const px = blur_line[k];
                    sr += @as(u64, px & 0xFF);
                    sg += @as(u64, (px >> 8) & 0xFF);
                    sb += @as(u64, (px >> 16) & 0xFF);
                }
                const off = @as(usize, y0 + j) * @as(usize, pitch) + col_off;
                const rb: u8 = @truncate(sr / cnt);
                const gb: u8 = @truncate(sg / cnt);
                const bb: u8 = @truncate(sb / cnt);
                buf[off] = rb;
                buf[off + 1] = gb;
                buf[off + 2] = bb;
            }
        }
    }
    total_draw_calls += 1;
}

/// Alpha-blend a tint color over a framebuffer rect with saturation control.
pub fn blendTintRect(x: i32, y: i32, w: i32, h: i32, tint: u32, alpha: u8, saturation: u8) void {
    if (w <= 0 or h <= 0) return;
    if (!config_ready) return;

    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = addU32Clamped(x0, @intCast(w), fb_config.width);
    const y1: u32 = addU32Clamped(y0, @intCast(h), fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    const t_b: u32 = tint & 0xFF;
    const t_g: u32 = (tint >> 8) & 0xFF;
    const t_r: u32 = (tint >> 16) & 0xFF;
    const a: u32 = @as(u32, alpha);
    const inv_a: u32 = 255 - a;
    const sat: u32 = @as(u32, saturation);

    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();

    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        var px: u32 = x0;
        while (px < x1) : (px += 1) {
            const off = @as(usize, py) * @as(usize, fb_config.pitch) + @as(usize, px) * @as(usize, bytes_pp);
            var r: u32 = undefined;
            var g: u32 = undefined;
            var b: u32 = undefined;
            if (fb_config.pixel_bgr) {
                b = @as(u32, ptr[off]);
                g = @as(u32, ptr[off + 1]);
                r = @as(u32, ptr[off + 2]);
            } else {
                r = @as(u32, ptr[off]);
                g = @as(u32, ptr[off + 1]);
                b = @as(u32, ptr[off + 2]);
            }

            const lum: u32 = @truncate((@as(u64, r) * 77 + @as(u64, g) * 150 + @as(u64, b) * 29) >> 8);
            const inv_sat: u32 = 255 - sat;
            r = @truncate((@as(u64, r) * sat + @as(u64, lum) * inv_sat) / 255);
            g = @truncate((@as(u64, g) * sat + @as(u64, lum) * inv_sat) / 255);
            b = @truncate((@as(u64, b) * sat + @as(u64, lum) * inv_sat) / 255);

            const out_r: u32 = @truncate((@as(u64, t_r) * a + @as(u64, r) * inv_a) / 255);
            const out_g: u32 = @truncate((@as(u64, t_g) * a + @as(u64, g) * inv_a) / 255);
            const out_b: u32 = @truncate((@as(u64, t_b) * a + @as(u64, b) * inv_a) / 255);

            if (fb_config.pixel_bgr) {
                ptr[off] = @truncate(out_b);
                ptr[off + 1] = @truncate(out_g);
                ptr[off + 2] = @truncate(out_r);
            } else {
                ptr[off] = @truncate(out_r);
                ptr[off + 1] = @truncate(out_g);
                ptr[off + 2] = @truncate(out_b);
            }
            if (bytes_pp == 4) ptr[off + 3] = 0xFF;
        }
    }
    total_draw_calls += 1;
}

/// Add a specular highlight (brightness boost that fades down) over a rect.
pub fn addSpecularBand(x: i32, y: i32, w: i32, band_h: i32, intensity: u32) void {
    if (w <= 0 or band_h <= 0) return;
    if (!config_ready) return;

    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = addU32Clamped(x0, @intCast(w), fb_config.width);
    const y1: u32 = addU32Clamped(y0, @intCast(band_h), fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    const bh = y1 - y0;
    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();

    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        const t = py - y0;
        const boost = intensity - (intensity * t / bh);

        var px: u32 = x0;
        while (px < x1) : (px += 1) {
            const off = pixelByteOffset(px, py, bytes_pp);
            var r: u32 = undefined;
            var g: u32 = undefined;
            var b: u32 = undefined;
            if (fb_config.pixel_bgr) {
                b = @as(u32, ptr[off]);
                g = @as(u32, ptr[off + 1]);
                r = @as(u32, ptr[off + 2]);
            } else {
                r = @as(u32, ptr[off]);
                g = @as(u32, ptr[off + 1]);
                b = @as(u32, ptr[off + 2]);
            }
            r = @min(r + boost, 255);
            g = @min(g + boost, 255);
            b = @min(b + boost, 255);
            if (fb_config.pixel_bgr) {
                ptr[off] = @truncate(b);
                ptr[off + 1] = @truncate(g);
                ptr[off + 2] = @truncate(r);
            } else {
                ptr[off] = @truncate(r);
                ptr[off + 1] = @truncate(g);
                ptr[off + 2] = @truncate(b);
            }
            if (bytes_pp == 4) ptr[off + 3] = 0xFF;
        }
    }
}

// ── Buffer Management ──

/// 大块 memcpy 到屏前/ramfb 后做内存栅栏，避免弱序模型下设备侧先看到旧像素（LoongArch 上尤为明显）。
fn fenceScanoutAfterMemcpy() void {
    fenceScanoutVisibleWrites();
}

/// 任意写入客户机线性帧缓冲（含直接绘制到 scanout）之后可调用，保证 Store 对设备可见（当前实现：LoongArch `dbar 0`）。
pub fn fenceScanoutVisibleWrites() void {
    switch (builtin.target.cpu.arch) {
        .loongarch64 => asm volatile ("dbar 0" ::: .{ .memory = true }),
        else => {},
    }
}

pub fn flip() void {
    if (double_buffer_active) {
        const size = bytes_per_slot;
        const dst: [*]u8 = @ptrFromInt(fb_config.address);
        const src = backBufSrcPtr();
        @memcpy(dst[0..size], src[0..size]);
        fenceScanoutAfterMemcpy();
        if (triple_buffer_active) {
            draw_slot ^= 1;
        }
    }
    dirty_count = 0;
    total_flips += 1;
}

pub fn flipDirty() void {
    if (double_buffer_active) {
        const src = backBufSrcPtr();
        if (dirty_count == 0 or dirty_count >= MAX_DIRTY_RECTS) {
            const size = @as(usize, fb_config.pitch) * @as(usize, fb_config.height);
            const dst: [*]u8 = @ptrFromInt(fb_config.address);
            @memcpy(dst[0..size], src[0..size]);
            fenceScanoutAfterMemcpy();
        } else {
            const bytes_pp: usize = @as(usize, fb_config.bpp) / 8;
            const dst_base: [*]u8 = @ptrFromInt(fb_config.address);
            for (dirty_rects[0..dirty_count]) |r| {
                const rx0: u32 = if (r.x < 0) 0 else @intCast(r.x);
                const ry0: u32 = if (r.y < 0) 0 else @intCast(r.y);
                const rw: u32 = if (r.w < 0) 0 else @intCast(r.w);
                const rh: u32 = if (r.h < 0) 0 else @intCast(r.h);
                const rx1: u32 = addU32Clamped(rx0, rw, fb_config.width);
                const ry1: u32 = addU32Clamped(ry0, rh, fb_config.height);
                if (rx0 >= rx1 or ry0 >= ry1) continue;
                const row_bytes = @as(usize, rx1 - rx0) * bytes_pp;
                var py: u32 = ry0;
                while (py < ry1) : (py += 1) {
                    const off = pixelByteOffset(rx0, py, @intCast(bytes_pp));
                    @memcpy(dst_base[off .. off + row_bytes], src[off .. off + row_bytes]);
                }
            }
            fenceScanoutAfterMemcpy();
        }
    }
    dirty_count = 0;
    total_flips += 1;
}

/// 自当前绘制缓冲拷贝矩形像素到 `dst`（按行紧密排列）。返回写入字节数。
pub fn copyDrawBufferRectBytes(dx: i32, dy: i32, w: i32, h: i32, dst: []u8) usize {
    if (w <= 0 or h <= 0) return 0;
    const bytes_pp: usize = @as(usize, fb_config.bpp) / 8;

    var x0: i32 = dx;
    var y0: i32 = dy;
    var cw: i32 = w;
    var ch: i32 = h;
    if (x0 < 0) {
        cw += x0;
        x0 = 0;
    }
    if (y0 < 0) {
        ch += y0;
        y0 = 0;
    }
    const fw: i32 = @intCast(fb_config.width);
    const fh: i32 = @intCast(fb_config.height);
    if (x0 >= fw or y0 >= fh) return 0;
    // i64 边界：`x0 + cw` 在 i32 上先加再比会在 Debug 下溢出 panic（与 material.rectScanEnd 注释同源）。
    {
        const x0i = @as(i64, x0);
        const y0i = @as(i64, y0);
        const fwi = @as(i64, fw);
        const fhi = @as(i64, fh);
        if (x0i + @as(i64, cw) > fwi) cw = @intCast(fwi - x0i);
        if (y0i + @as(i64, ch) > fhi) ch = @intCast(fhi - y0i);
    }
    if (cw <= 0 or ch <= 0) return 0;

    const row_bytes: usize = @as(usize, @intCast(cw)) * bytes_pp;
    const need: usize = @as(usize, @intCast(ch)) * row_bytes;
    if (dst.len < need) return 0;

    const ptr = getDrawBuffer();
    var dst_off: usize = 0;
    var row: i32 = 0;
    while (row < ch) : (row += 1) {
        const py: u32 = @intCast(y0 + row);
        const off: usize = @as(usize, py) * @as(usize, fb_config.pitch) + @as(usize, @intCast(x0)) * bytes_pp;
        const src_row = @as([*]u8, @volatileCast(ptr))[off .. off + row_bytes];
        @memcpy(dst[dst_off..][0..row_bytes], src_row);
        dst_off += row_bytes;
    }
    return dst_off;
}

/// 将 `src` 按行写回绘制缓冲（与 `copyDrawBufferRectBytes` 相同裁剪语义）。
pub fn pasteDrawBufferRectBytes(dx: i32, dy: i32, w: i32, h: i32, src: []const u8) void {
    if (w <= 0 or h <= 0) return;
    const bytes_pp: usize = @as(usize, fb_config.bpp) / 8;

    var x0: i32 = dx;
    var y0: i32 = dy;
    var cw: i32 = w;
    var ch: i32 = h;
    if (x0 < 0) {
        cw += x0;
        x0 = 0;
    }
    if (y0 < 0) {
        ch += y0;
        y0 = 0;
    }
    const fw: i32 = @intCast(fb_config.width);
    const fh: i32 = @intCast(fb_config.height);
    if (x0 >= fw or y0 >= fh) return;
    {
        const x0i = @as(i64, x0);
        const y0i = @as(i64, y0);
        const fwi = @as(i64, fw);
        const fhi = @as(i64, fh);
        if (x0i + @as(i64, cw) > fwi) cw = @intCast(fwi - x0i);
        if (y0i + @as(i64, ch) > fhi) ch = @intCast(fhi - y0i);
    }
    if (cw <= 0 or ch <= 0) return;

    const row_bytes: usize = @as(usize, @intCast(cw)) * bytes_pp;
    const need: usize = @as(usize, @intCast(ch)) * row_bytes;
    if (src.len < need) return;

    const ptr = getDrawBuffer();
    var src_off: usize = 0;
    var row: i32 = 0;
    while (row < ch) : (row += 1) {
        const py: u32 = @intCast(y0 + row);
        const off: usize = @as(usize, py) * @as(usize, fb_config.pitch) + @as(usize, @intCast(x0)) * bytes_pp;
        const dst_row = @as([*]u8, @volatileCast(ptr))[off .. off + row_bytes];
        @memcpy(dst_row, src[src_off..][0..row_bytes]);
        src_off += row_bytes;
    }
}

pub fn isDoubleBuffered() bool {
    return double_buffer_active;
}

pub fn isTripleBuffered() bool {
    return triple_buffer_active;
}

/// 离屏槽数量（不含 GOP）：0 = 单缓冲直写屏前，1 = 双缓冲，2 = 三缓冲乒乓。
pub fn getOffscreenSlotCount() u32 {
    if (!double_buffer_active) return 0;
    return if (triple_buffer_active) 2 else 1;
}

/// 离屏区域总预留字节（所有槽之和）。
pub fn getOffscreenReservedBytes() usize {
    if (!double_buffer_active or bytes_per_slot == 0) return 0;
    return bytes_per_slot * @as(usize, getOffscreenSlotCount());
}

/// 可选：把当前 GOP 内容拷入离屏槽（配置 `display.seed_gop_to_back`）。
pub fn seedDrawBufferFromVisibleIfConfigured() void {
    if (!double_buffer_active or fb_config.address == 0 or bytes_per_slot == 0) return;
    if (!config_mod.isSeedDrawBufferFromGopEnabled()) return;
    const size = bytes_per_slot;
    const src: [*]const u8 = @ptrFromInt(fb_config.address);
    const nslots: u32 = if (triple_buffer_active) 2 else 1;
    var s: u32 = 0;
    while (s < nslots) : (s += 1) {
        const off = @as(usize, s) * size;
        const dst: [*]u8 = if (back_buffer_addr != 0)
            @ptrFromInt(back_buffer_addr + off)
        else
            @as([*]u8, @ptrCast(&back_buf)) + off;
        @memcpy(dst[0..size], src[0..size]);
    }
}

/// 桌面启动摘要：与 AeroDesktopRuntime §3.1 对照「坐标 vs 像素」排查。
pub fn logDesktopPointerDiagnostics(virtio_input_active: bool, ps2_hw_ok: bool) void {
    if (!config_ready) return;
    klog.info("DesktopPointerDiag: double_buf=%s triple_buf=%s offscreen_slots=%u reserved_B=%u present_full_flip=%s seed_gop=%s fall_back_alloc=%s virtio_input=%s ps2_hw=%s — see docs/cn/AeroDesktopRuntime.md §3.1", .{
        if (double_buffer_active) "ON" else "OFF",
        if (triple_buffer_active) "ON" else "OFF",
        getOffscreenSlotCount(),
        @as(u32, @truncate(getOffscreenReservedBytes())),
        if (config_mod.isPresentFullFlipEnabled()) "ON" else "OFF",
        if (config_mod.isSeedDrawBufferFromGopEnabled()) "ON" else "OFF",
        if (config_mod.allowSingleBufferOnLargeAllocFail()) "ON" else "OFF",
        if (virtio_input_active) "active" else "inactive",
        if (ps2_hw_ok) "ok" else "no",
    });
}

/// GOP 几何一行摘要（排查 LoongArch UEFI / Multiboot 与盒式模糊成本：`w*h`）。
pub fn logDesktopGopSummary() void {
    if (!config_ready) return;
    klog.info("DesktopGOP: %ux%u pitch=%u bpp=%u (see DesktopManagerSpec blur tuning)", .{
        fb_config.width, fb_config.height, fb_config.pitch, fb_config.bpp,
    });
}

/// 帧缓冲 + 离屏内存一行摘要（回归 / QA）。
pub fn logFramebufferMemorySummary() void {
    if (!config_ready) return;
    const vis = @as(usize, fb_config.pitch) * @as(usize, fb_config.height);
    klog.info("FramebufferMem: visible_B=%u offscreen_B=%u total_managed_B=%u flips=%u", .{
        @as(u32, @truncate(vis)),
        @as(u32, @truncate(getOffscreenReservedBytes())),
        @as(u32, @truncate(vis + getOffscreenReservedBytes())),
        @as(u32, @truncate(total_flips)),
    });
}

// ── IRP Dispatch ──

fn fbDispatch(irp: *io.Irp) io.IoStatus {
    switch (irp.major_function) {
        .create, .close => {
            irp.complete(.success, 0);
            return .success;
        },
        .ioctl => return handleIoctl(irp),
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
        },
    }
}

fn handleIoctl(irp: *io.Irp) io.IoStatus {
    switch (irp.ioctl_code) {
        IOCTL_FB_GET_CONFIG => {
            irp.buffer_ptr = fb_config.address;
            irp.bytes_transferred = @intCast(@as(u64, fb_config.pitch) * @as(u64, fb_config.height));
            irp.complete(.success, fb_config.width);
            return .success;
        },
        IOCTL_FB_MAP_BUFFER => {
            irp.buffer_ptr = fb_config.address;
            irp.complete(.success, @intCast(@as(u64, fb_config.pitch) * @as(u64, fb_config.height)));
            return .success;
        },
        IOCTL_FB_FLIP => {
            flip();
            irp.complete(.success, 0);
            return .success;
        },
        IOCTL_FB_FILL_RECT => {
            irp.complete(.success, 0);
            return .success;
        },
        IOCTL_FB_GET_STATS => {
            irp.buffer_ptr = total_draw_calls;
            irp.bytes_transferred = @intCast(total_flips);
            irp.complete(.success, 0);
            return .success;
        },
        else => {
            irp.complete(.not_implemented, 0);
            return .not_implemented;
        },
    }
}

// ── State Query ──

pub fn getConfig() *const FramebufferConfig {
    return &fb_config;
}

pub fn getWidth() u32 {
    return fb_config.width;
}

pub fn getHeight() u32 {
    return fb_config.height;
}

pub fn getBpp() u8 {
    return fb_config.bpp;
}

pub fn getPitch() u32 {
    return fb_config.pitch;
}

pub fn getAddress() usize {
    return fb_config.address;
}

pub fn isInitialized() bool {
    return config_ready;
}

pub fn isDriverRegistered() bool {
    return driver_initialized;
}

pub fn getTotalDrawCalls() u64 {
    return total_draw_calls;
}

pub fn getTotalFlips() u64 {
    return total_flips;
}

// ── Initialization ──

fn zeroHeapBack(total_bytes: usize) void {
    const p: [*]u8 = @ptrFromInt(back_buffer_addr);
    @memset(p[0..total_bytes], 0);
    if (back_buffer_size > total_bytes) {
        @memset(p[total_bytes..back_buffer_size], 0);
    }
}

pub fn init(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8, pixel_bgr: bool) void {
    const required = @as(usize, pitch) * @as(usize, height);
    back_buffer_addr = 0;
    back_buffer_size = 0;
    back_buffer_heap_nframes = 0;
    double_buffer_active = false;
    triple_buffer_active = false;
    draw_slot = 0;
    bytes_per_slot = 0;

    const want_db_base = config_mod.isDoubleBufferEnabled() and required > 0 and addr != 0;
    var want_triple = want_db_base and config_mod.isTripleBufferEnabled();
    const allow_single_on_fail = config_mod.allowSingleBufferOnLargeAllocFail();

    if (want_db_base) {
        bytes_per_slot = required;
        const total_for_triple = required * 2;

        if (required <= BACK_BUF_MAX and (!want_triple or total_for_triple <= BACK_BUF_MAX)) {
            double_buffer_active = true;
            triple_buffer_active = want_triple and total_for_triple <= BACK_BUF_MAX;
            const zbytes = if (triple_buffer_active) total_for_triple else required;
            @memset(back_buf[0..zbytes], 0);
        } else if (required <= BACK_BUF_MAX and want_triple and total_for_triple > BACK_BUF_MAX) {
            if (frame_mod.getKernelFrameAllocator()) |fa| {
                const nframes2 = (total_for_triple + frame_mod.FRAME_SIZE - 1) / frame_mod.FRAME_SIZE;
                if (fa.allocContiguous(nframes2)) |base_phys| {
                    back_buffer_addr = @as(usize, @truncate(base_phys));
                    back_buffer_heap_nframes = nframes2;
                    back_buffer_size = nframes2 * frame_mod.FRAME_SIZE;
                    double_buffer_active = true;
                    triple_buffer_active = true;
                    zeroHeapBack(total_for_triple);
                    klog.info("Framebuffer: heap ping-pong %u pages phys=0x%x (%u bytes 2 slots)", .{
                        nframes2, back_buffer_addr, total_for_triple,
                    });
                } else {
                    klog.warn("Framebuffer: triple allocContiguous failed; trying single back buffer", .{});
                    want_triple = false;
                }
            } else {
                klog.warn("Framebuffer: triple needs heap; no allocator — single static back", .{});
                want_triple = false;
            }
            if (!double_buffer_active and !want_triple) {
                double_buffer_active = true;
                triple_buffer_active = false;
                @memset(back_buf[0..required], 0);
            }
        } else if (required > BACK_BUF_MAX) {
            if (frame_mod.getKernelFrameAllocator()) |fa| {
                if (want_triple) {
                    const nframes2 = (total_for_triple + frame_mod.FRAME_SIZE - 1) / frame_mod.FRAME_SIZE;
                    if (fa.allocContiguous(nframes2)) |base_phys| {
                        back_buffer_addr = @as(usize, @truncate(base_phys));
                        back_buffer_heap_nframes = nframes2;
                        back_buffer_size = nframes2 * frame_mod.FRAME_SIZE;
                        double_buffer_active = true;
                        triple_buffer_active = true;
                        zeroHeapBack(total_for_triple);
                        klog.info("Framebuffer: heap ping-pong %u pages phys=0x%x (%u bytes)", .{
                            nframes2, back_buffer_addr, total_for_triple,
                        });
                    } else {
                        klog.warn("Framebuffer: large FB triple alloc failed; trying single back", .{});
                        want_triple = false;
                    }
                }
                if (!double_buffer_active) {
                    const nframes = (required + frame_mod.FRAME_SIZE - 1) / frame_mod.FRAME_SIZE;
                    if (fa.allocContiguous(nframes)) |base_phys| {
                        back_buffer_addr = @as(usize, @truncate(base_phys));
                        back_buffer_heap_nframes = nframes;
                        back_buffer_size = nframes * frame_mod.FRAME_SIZE;
                        double_buffer_active = true;
                        triple_buffer_active = false;
                        zeroHeapBack(required);
                        klog.info("Framebuffer: heap back buffer %u pages phys=0x%x (%u bytes)", .{
                            nframes, back_buffer_addr, required,
                        });
                    } else if (allow_single_on_fail) {
                        klog.warn("Framebuffer: allocContiguous failed (%u bytes); strategy=single_buffer_direct (GOP)", .{required});
                    } else {
                        klog.err("Framebuffer: allocContiguous failed and fall_back_single_on_alloc_fail=false; double_buf=OFF", .{});
                    }
                }
            } else if (allow_single_on_fail) {
                klog.warn("Framebuffer: no kernel frame allocator; large FB strategy=single_buffer_direct", .{});
            } else {
                klog.err("Framebuffer: no allocator and fall_back_single_on_alloc_fail=false; double_buf=OFF", .{});
            }
        }
    }

    fb_config = .{
        .address = addr,
        .width = width,
        .height = height,
        .pitch = pitch,
        .bpp = bpp,
        .pixel_format = if (bpp == 32) .xrgb8888 else if (bpp == 24) .rgb888 else .rgb565,
        .double_buffer = double_buffer_active,
        .pixel_bgr = pixel_bgr,
    };

    config_ready = (addr != 0 and width > 0 and height > 0 and bpp > 0);

    seedDrawBufferFromVisibleIfConfigured();

    driver_idx = io.registerDriver("\\Driver\\Framebuf", fbDispatch) orelse {
        klog.err("Framebuffer: Failed to register IO driver (rendering still works)", .{});
        klog.info("Framebuffer Driver: %ux%u@%ubpp, pitch=%u, addr=0x%x, double_buf=%s triple=%s", .{
            width, height, bpp, pitch, addr,
            if (double_buffer_active) "ON" else "OFF",
            if (triple_buffer_active) "ON" else "OFF",
        });
        return;
    };

    device_idx = io.createDevice("\\Device\\Framebuf0", .framebuffer, driver_idx) orelse {
        klog.err("Framebuffer: Failed to create IO device (rendering still works)", .{});
        klog.info("Framebuffer Driver: %ux%u@%ubpp, pitch=%u, addr=0x%x, double_buf=%s triple=%s", .{
            width, height, bpp, pitch, addr,
            if (double_buffer_active) "ON" else "OFF",
            if (triple_buffer_active) "ON" else "OFF",
        });
        return;
    };

    driver_initialized = true;

    klog.info("Framebuffer Driver: %ux%u@%ubpp, pitch=%u, addr=0x%x, double_buf=%s triple=%s offscreen_B=%u", .{
        width, height, bpp, pitch, addr,
        if (double_buffer_active) "ON" else "OFF",
        if (triple_buffer_active) "ON" else "OFF",
        @as(u32, @truncate(getOffscreenReservedBytes())),
    });
    logFramebufferMemorySummary();
}

// ── Embedded 8x16 bitmap font (ASCII 32-126 + fallback) ──

fn getGlyph(ch: u8) *const [16]u8 {
    if (ch >= 32 and ch < 127) {
        return &font_8x16[ch - 32];
    }
    return &font_8x16[95];
}

const font_8x16 = [96][16]u8{
    // 32: space
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 33: !
    .{ 0x00, 0x00, 0x18, 0x3C, 0x3C, 0x3C, 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
    // 34: "
    .{ 0x00, 0x66, 0x66, 0x66, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 35: #
    .{ 0x00, 0x00, 0x00, 0x6C, 0x6C, 0xFE, 0x6C, 0x6C, 0xFE, 0x6C, 0x6C, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 36: $
    .{ 0x18, 0x18, 0x7C, 0xC6, 0xC2, 0xC0, 0x7C, 0x06, 0x06, 0x86, 0xC6, 0x7C, 0x18, 0x18, 0x00, 0x00 },
    // 37: %
    .{ 0x00, 0x00, 0x00, 0x00, 0xC2, 0xC6, 0x0C, 0x18, 0x30, 0x60, 0xC6, 0x86, 0x00, 0x00, 0x00, 0x00 },
    // 38: &
    .{ 0x00, 0x00, 0x38, 0x6C, 0x6C, 0x38, 0x76, 0xDC, 0xCC, 0xCC, 0xCC, 0x76, 0x00, 0x00, 0x00, 0x00 },
    // 39: '
    .{ 0x00, 0x30, 0x30, 0x30, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 40: (
    .{ 0x00, 0x00, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00 },
    // 41: )
    .{ 0x00, 0x00, 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00 },
    // 42: *
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 43: +
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 44: ,
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x18, 0x30, 0x00, 0x00, 0x00 },
    // 45: -
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 46: .
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
    // 47: /
    .{ 0x00, 0x00, 0x00, 0x00, 0x02, 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00, 0x00, 0x00, 0x00 },
    // 48-57: 0-9
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xCE, 0xDE, 0xF6, 0xE6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x18, 0x38, 0x78, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0xC6, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0x06, 0x06, 0x3C, 0x06, 0x06, 0x06, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x0C, 0x1C, 0x3C, 0x6C, 0xCC, 0xFE, 0x0C, 0x0C, 0x0C, 0x1E, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0xC0, 0xC0, 0xC0, 0xFC, 0x06, 0x06, 0x06, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x38, 0x60, 0xC0, 0xC0, 0xFC, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0xC6, 0x06, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x30, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0x7E, 0x06, 0x06, 0x06, 0x0C, 0x78, 0x00, 0x00, 0x00, 0x00 },
    // 58: :
    .{ 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 59: ;
    .{ 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00 },
    // 60-62: < = >
    .{ 0x00, 0x00, 0x00, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x00, 0x00, 0x00, 0x00 },
    // 63: ?
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0x0C, 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
    // 64: @
    .{ 0x00, 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xDE, 0xDE, 0xDE, 0xDC, 0xC0, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    // 65-90: A-Z
    .{ 0x00, 0x00, 0x10, 0x38, 0x6C, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFC, 0x66, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x66, 0x66, 0xFC, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x66, 0xC2, 0xC0, 0xC0, 0xC0, 0xC0, 0xC2, 0x66, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xF8, 0x6C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x6C, 0xF8, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0x66, 0x62, 0x68, 0x78, 0x68, 0x60, 0x62, 0x66, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0x66, 0x62, 0x68, 0x78, 0x68, 0x60, 0x60, 0x60, 0xF0, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x66, 0xC2, 0xC0, 0xC0, 0xDE, 0xC6, 0xC6, 0x66, 0x3A, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0xCC, 0xCC, 0xCC, 0x78, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xE6, 0x66, 0x66, 0x6C, 0x78, 0x78, 0x6C, 0x66, 0x66, 0xE6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xF0, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x62, 0x66, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xEE, 0xFE, 0xFE, 0xD6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xE6, 0xF6, 0xFE, 0xDE, 0xCE, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFC, 0x66, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x60, 0xF0, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xD6, 0xDE, 0x7C, 0x0C, 0x0E, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFC, 0x66, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x66, 0xE6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0x60, 0x38, 0x0C, 0x06, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFF, 0xDB, 0x99, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x10, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xD6, 0xD6, 0xD6, 0xFE, 0xEE, 0x6C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0x6C, 0x7C, 0x38, 0x38, 0x7C, 0x6C, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xFE, 0xC6, 0x86, 0x0C, 0x18, 0x30, 0x60, 0xC2, 0xC6, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    // 91-96: [ \ ] ^ _ `
    .{ 0x00, 0x00, 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x80, 0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x10, 0x38, 0x6C, 0xC6, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00 },
    .{ 0x00, 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 97-122: a-z
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x78, 0x0C, 0x7C, 0xCC, 0xCC, 0xCC, 0x76, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0xE0, 0x60, 0x60, 0x78, 0x6C, 0x66, 0x66, 0x66, 0x66, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7C, 0xC6, 0xC0, 0xC0, 0xC0, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x1C, 0x0C, 0x0C, 0x3C, 0x6C, 0xCC, 0xCC, 0xCC, 0xCC, 0x76, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7C, 0xC6, 0xFE, 0xC0, 0xC0, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x1C, 0x36, 0x32, 0x30, 0x78, 0x30, 0x30, 0x30, 0x30, 0x78, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x76, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0x7C, 0x0C, 0xCC, 0x78, 0x00 },
    .{ 0x00, 0x00, 0xE0, 0x60, 0x60, 0x6C, 0x76, 0x66, 0x66, 0x66, 0x66, 0xE6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x18, 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x06, 0x06, 0x00, 0x0E, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x66, 0x66, 0x3C, 0x00 },
    .{ 0x00, 0x00, 0xE0, 0x60, 0x60, 0x66, 0x6C, 0x78, 0x78, 0x6C, 0x66, 0xE6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xE6, 0xFF, 0xDB, 0xDB, 0xDB, 0xDB, 0xDB, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xDC, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xDC, 0x66, 0x66, 0x66, 0x66, 0x66, 0x7C, 0x60, 0x60, 0xF0, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x76, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0x7C, 0x0C, 0x0C, 0x1E, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xDC, 0x76, 0x66, 0x60, 0x60, 0x60, 0xF0, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x7C, 0xC6, 0x60, 0x38, 0x0C, 0xC6, 0x7C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x10, 0x30, 0x30, 0xFC, 0x30, 0x30, 0x30, 0x30, 0x36, 0x1C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0x76, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6, 0xC6, 0xD6, 0xD6, 0xD6, 0xFE, 0x6C, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6, 0x6C, 0x38, 0x38, 0x38, 0x6C, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7E, 0x06, 0x0C, 0xF8, 0x00 },
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0xFE, 0xCC, 0x18, 0x30, 0x60, 0xC6, 0xFE, 0x00, 0x00, 0x00, 0x00 },
    // 123-126: { | } ~
    .{ 0x00, 0x00, 0x0E, 0x18, 0x18, 0x18, 0x70, 0x18, 0x18, 0x18, 0x18, 0x0E, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x70, 0x18, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x18, 0x18, 0x70, 0x00, 0x00, 0x00, 0x00 },
    .{ 0x00, 0x00, 0x76, 0xDC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 127: fallback (solid block)
    .{ 0x00, 0x00, 0x00, 0x00, 0xFE, 0xFE, 0xFE, 0xFE, 0xFE, 0xFE, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00 },
};
