//! Graphical framebuffer miniport (NT6: analog to display miniport + surface IOCTLs)
//! Pixel primitives, bulk ops, and IRP/IOCTL dispatch for the DWM/compositor path.
//! Original ZirconOS implementation; registers `\\Driver\\Framebuf` / `\\Device\\Framebuf0`.

const std = @import("std");
const io = @import("../../io/io.zig");
const klog = @import("../../rtl/klog.zig");
const cjk_font = @import("cjk_font.zig");

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

// ── Double Buffering (back buffer) ──
// All draw calls write to this off-screen buffer; flip() copies it to the
// visible framebuffer in one shot, eliminating partial-frame flickering.
const BACK_BUF_MAX: usize = 10 * 1024 * 1024; // 10 MB – covers up to 1920×1080@32bpp
var back_buf: [BACK_BUF_MAX]u8 = undefined;
var double_buffer_active: bool = false;

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

fn getDrawBuffer() [*]volatile u8 {
    if (double_buffer_active) {
        return @volatileCast(@as([*]u8, &back_buf));
    }
    return @ptrFromInt(fb_config.address);
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
fn writePixel4(ptr: [*]volatile u8, offset: u32, color: u32) void {
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

fn writePixel3(ptr: [*]volatile u8, offset: u32, color: u32) void {
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
    const offset = y * fb_config.pitch + x * bytes_pp;
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
    const offset = y * fb_config.pitch + x * bytes_pp;
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
    const row_offset = py * fb_config.pitch + x0 * bytes_pp;
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
            writePixel3(ptr, row_offset + i * 3, color);
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
    const x1: u32 = @min(x0 + @as(u32, @intCast(w)), fb_config.width);
    const y1: u32 = @min(y0 + @as(u32, @intCast(h)), fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        fillRowDirect(py, x0, x1, color);
    }

    total_draw_calls += 1;
    addDirtyRect(.{ .x = x, .y = y, .w = w, .h = h });
}

pub fn drawRect(x: i32, y: i32, w: i32, h: i32, color: u32) void {
    drawHLine(x, y, w, color);
    drawHLine(x, y + h - 1, w, color);
    drawVLine(x, y, h, color);
    drawVLine(x + w - 1, y, h, color);
}

pub fn drawHLine(x: i32, y: i32, length: i32, color: u32) void {
    if (length <= 0 or y < 0 or y >= @as(i32, @intCast(fb_config.height))) return;
    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const x1: u32 = @min(x0 + @as(u32, @intCast(length)), fb_config.width);
    if (x0 >= x1) return;
    fillRowDirect(@intCast(y), x0, x1, color);
}

pub fn drawVLine(x: i32, y: i32, length: i32, color: u32) void {
    if (length <= 0 or x < 0 or x >= @as(i32, @intCast(fb_config.width))) return;
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const y1: u32 = @min(y0 + @as(u32, @intCast(length)), fb_config.height);
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
    const x1: u32 = @min(x0 + uw, fb_config.width);
    const y1: u32 = @min(y0 + @as(u32, @intCast(h)), fb_config.height);
    if (x0 >= x1 or y0 >= y1) return;

    const bytes_pp = @as(u32, fb_config.bpp) / 8;
    const ptr = getDrawBuffer();
    const row_pixels = x1 - x0;
    const base_x: u32 = if (x < 0) 0 else @intCast(x);

    var py: u32 = y0;
    while (py < y1) : (py += 1) {
        const row_offset = py * fb_config.pitch + x0 * bytes_pp;
        var px: u32 = 0;
        while (px < row_pixels) : (px += 1) {
            const t = (x0 + px) -| base_x;
            const color = interpolateColor(color1, color2, t, uw);
            if (bytes_pp == 4) {
                writePixel4(ptr, row_offset + px * 4, color);
            } else if (bytes_pp == 3) {
                writePixel3(ptr, row_offset + px * 3, color);
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
    const x1: u32 = @min(x0 + @as(u32, @intCast(w)), fb_config.width);
    const y1: u32 = @min(y0 + uh, fb_config.height);
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
        return a + ((b - a) * t) / total;
    } else {
        return a - ((a - b) * t) / total;
    }
}

pub fn clearScreen(color: u32) void {
    if (fb_config.width == 0 or fb_config.height == 0) return;
    const bytes_pp = @as(u32, fb_config.bpp) / 8;

    if (bytes_pp == 4) {
        const pxval = packPixel32(color);
        const ptr = getDrawBuffer();
        const base_addr = @intFromPtr(ptr);
        const total = fb_config.pitch * fb_config.height;
        var off: u32 = 0;
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
        const row_base = py * fb_config.pitch;

        var dx: u32 = 0;
        while (dx < CHAR_W) : (dx += 1) {
            const px = if (x < 0) continue else @as(u32, @intCast(x)) + dx;
            if (px >= fb_config.width) break;
            const on = (bits >> @intCast(7 - dx)) & 1;
            const color: u32 = if (on != 0) fg else bg;
            const off = row_base + px * bytes_pp;
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
        var cx = x;
        for (text) |b| {
            if (clip_max_x) |mx| {
                if (cx + @as(i32, @intCast(CHAR_W)) > mx) break;
            }
            drawCharTransparent(cx, y, b, fg);
            cx += @as(i32, @intCast(CHAR_W));
        }
        return;
    };
    var it = view.iterator();
    var cx = x;
    while (it.nextCodepoint()) |cp| {
        const adv: i32 = @intCast(cjk_font.codepointWidth(cp));
        if (clip_max_x) |mx| {
            if (cx + adv > mx) break;
        }
        if (cp < 0x80) {
            drawCharTransparent(cx, y, @truncate(cp), fg);
        } else if (cjk_font.lookup(cp)) |rows| {
            drawCjk16Transparent(cx, y, rows, fg);
        } else if (cjk_font.isWideCodepoint(cp)) {
            drawCjk16Transparent(cx, y, cjk_font.tofu_rows, fg);
        } else {
            drawCharTransparent(cx, y, '?', fg);
        }
        cx += adv;
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
                const px = x + @as(i32, @intCast(dx * scale));
                const py = y + @as(i32, @intCast(dy * scale));
                fillRect(px, py, @as(i32, @intCast(scale)), @as(i32, @intCast(scale)), fg);
            }
        }
    }
}

pub fn drawTextTransparentScaled(x: i32, y: i32, text: []const u8, fg: u32, scale: u32) void {
    if (scale < 1) return;
    var cx = x;
    const adv: i32 = @as(i32, @intCast(CHAR_W * scale));
    for (text) |ch| {
        if (cx + adv > @as(i32, @intCast(fb_config.width))) break;
        drawCharTransparentScaled(cx, y, ch, fg, scale);
        cx += adv;
    }
}

pub fn textWidthScaled(text: []const u8, scale: u32) i32 {
    if (scale < 1) return 0;
    return @as(i32, @intCast(text.len * CHAR_W * scale));
}

pub fn drawTextCentered(x: i32, y: i32, w: i32, h: i32, text: []const u8, fg: u32) void {
    const text_w: i32 = @intCast(text.len * CHAR_W);
    const tx = x + @divTrunc(w - text_w, 2);
    const ty = y + @divTrunc(h - @as(i32, CHAR_H), 2);
    drawTextTransparent(tx, ty, text, fg);
}

pub fn textWidth(text: []const u8) i32 {
    const view = std.unicode.Utf8View.init(text) catch {
        return @intCast(text.len * CHAR_W);
    };
    var it = view.iterator();
    var w: i32 = 0;
    while (it.nextCodepoint()) |cp| {
        w += @as(i32, @intCast(cjk_font.codepointWidth(cp)));
    }
    return w;
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

// ── 3D-style border effects ──

pub fn draw3DRect(x: i32, y: i32, w: i32, h: i32, highlight: u32, shadow: u32) void {
    drawHLine(x, y, w, highlight);
    drawVLine(x, y, h, highlight);
    drawHLine(x, y + h - 1, w, shadow);
    drawVLine(x + w - 1, y, h, shadow);
}

// ── Aero Glass Blur (Multi-pass Box Blur) ──
// Three passes of separable box blur approximate a Gaussian blur.
// Operates directly on the framebuffer using a static line buffer.

const BLUR_MAX_LINE: usize = 4096;
var blur_line: [BLUR_MAX_LINE]u32 = [_]u32{0} ** BLUR_MAX_LINE;

pub fn boxBlurRect(x: i32, y: i32, w: i32, h: i32, radius: u32, passes: u32) void {
    if (w <= 0 or h <= 0 or radius == 0 or passes == 0) return;
    if (!config_ready) return;
    if (fb_config.bpp < 24) return;

    const x0: u32 = if (x < 0) 0 else @intCast(x);
    const y0: u32 = if (y < 0) 0 else @intCast(y);
    const x1: u32 = @min(x0 + @as(u32, @intCast(w)), fb_config.width);
    const y1: u32 = @min(y0 + @as(u32, @intCast(h)), fb_config.height);
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
            const row_base = row * pitch + x0 * bpp;
            // Read entire row into blur_line as packed XRGB u32
            var i: u32 = 0;
            while (i < rw) : (i += 1) {
                const off = row_base + i * bpp;
                blur_line[i] = @as(u32, buf[off]) | (@as(u32, buf[off + 1]) << 8) | (@as(u32, buf[off + 2]) << 16);
            }
            // Running-sum horizontal blur
            i = 0;
            while (i < rw) : (i += 1) {
                const lo = if (i >= radius) i - radius else 0;
                const hi = @min(i + radius + 1, rw);
                const cnt = hi - lo;
                var sr: u32 = 0;
                var sg: u32 = 0;
                var sb: u32 = 0;
                var k: u32 = lo;
                while (k < hi) : (k += 1) {
                    const px = blur_line[k];
                    sr += px & 0xFF;
                    sg += (px >> 8) & 0xFF;
                    sb += (px >> 16) & 0xFF;
                }
                const off = row_base + i * bpp;
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
            const col_off = col * bpp;
            // Read column pixels into blur_line
            var j: u32 = 0;
            while (j < rh) : (j += 1) {
                const off = (y0 + j) * pitch + col_off;
                blur_line[j] = @as(u32, buf[off]) | (@as(u32, buf[off + 1]) << 8) | (@as(u32, buf[off + 2]) << 16);
            }
            // Running-sum vertical blur
            j = 0;
            while (j < rh) : (j += 1) {
                const lo = if (j >= radius) j - radius else 0;
                const hi = @min(j + radius + 1, rh);
                const cnt = hi - lo;
                var sr: u32 = 0;
                var sg: u32 = 0;
                var sb: u32 = 0;
                var k: u32 = lo;
                while (k < hi) : (k += 1) {
                    const px = blur_line[k];
                    sr += px & 0xFF;
                    sg += (px >> 8) & 0xFF;
                    sb += (px >> 16) & 0xFF;
                }
                const off = (y0 + j) * pitch + col_off;
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
    const x1: u32 = @min(x0 + @as(u32, @intCast(w)), fb_config.width);
    const y1: u32 = @min(y0 + @as(u32, @intCast(h)), fb_config.height);
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
            const off = py * fb_config.pitch + px * bytes_pp;
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

            const lum = (r * 77 + g * 150 + b * 29) >> 8;
            r = (r * sat + lum * (255 - sat)) / 255;
            g = (g * sat + lum * (255 - sat)) / 255;
            b = (b * sat + lum * (255 - sat)) / 255;

            const out_r = (t_r * a + r * inv_a) / 255;
            const out_g = (t_g * a + g * inv_a) / 255;
            const out_b = (t_b * a + b * inv_a) / 255;

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
    const x1: u32 = @min(x0 + @as(u32, @intCast(w)), fb_config.width);
    const y1: u32 = @min(y0 + @as(u32, @intCast(band_h)), fb_config.height);
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
            const off = py * fb_config.pitch + px * bytes_pp;
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

pub fn flip() void {
    if (double_buffer_active) {
        const size = @as(usize, fb_config.pitch) * @as(usize, fb_config.height);
        const dst: [*]u8 = @ptrFromInt(fb_config.address);
        @memcpy(dst[0..size], back_buf[0..size]);
    }
    dirty_count = 0;
    total_flips += 1;
}

pub fn flipDirty() void {
    if (double_buffer_active) {
        if (dirty_count == 0 or dirty_count >= MAX_DIRTY_RECTS) {
            const size = @as(usize, fb_config.pitch) * @as(usize, fb_config.height);
            const dst: [*]u8 = @ptrFromInt(fb_config.address);
            @memcpy(dst[0..size], back_buf[0..size]);
        } else {
            const bytes_pp: usize = @as(usize, fb_config.bpp) / 8;
            const dst_base: [*]u8 = @ptrFromInt(fb_config.address);
            for (dirty_rects[0..dirty_count]) |r| {
                const rx0: u32 = if (r.x < 0) 0 else @intCast(r.x);
                const ry0: u32 = if (r.y < 0) 0 else @intCast(r.y);
                const rw: u32 = if (r.w < 0) 0 else @intCast(r.w);
                const rh: u32 = if (r.h < 0) 0 else @intCast(r.h);
                const rx1: u32 = @min(rx0 + rw, fb_config.width);
                const ry1: u32 = @min(ry0 + rh, fb_config.height);
                if (rx0 >= rx1 or ry0 >= ry1) continue;
                const row_bytes = @as(usize, rx1 - rx0) * bytes_pp;
                var py: u32 = ry0;
                while (py < ry1) : (py += 1) {
                    const off = @as(usize, py) * @as(usize, fb_config.pitch) + @as(usize, rx0) * bytes_pp;
                    @memcpy(dst_base[off .. off + row_bytes], back_buf[off .. off + row_bytes]);
                }
            }
        }
    }
    dirty_count = 0;
    total_flips += 1;
}

pub fn isDoubleBuffered() bool {
    return double_buffer_active;
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
            irp.bytes_transferred = fb_config.pitch * fb_config.height;
            irp.complete(.success, fb_config.width);
            return .success;
        },
        IOCTL_FB_MAP_BUFFER => {
            irp.buffer_ptr = fb_config.address;
            irp.complete(.success, fb_config.pitch * fb_config.height);
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

pub fn init(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8, pixel_bgr: bool) void {
    const required = @as(usize, pitch) * @as(usize, height);
    double_buffer_active = (required > 0 and required <= BACK_BUF_MAX);

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

    driver_idx = io.registerDriver("\\Driver\\Framebuf", fbDispatch) orelse {
        klog.err("Framebuffer: Failed to register IO driver (rendering still works)", .{});
        klog.info("Framebuffer Driver: %ux%u@%ubpp, pitch=%u, addr=0x%x, double_buf=%s", .{
            width, height, bpp, pitch, addr, if (double_buffer_active) "ON" else "OFF",
        });
        return;
    };

    device_idx = io.createDevice("\\Device\\Framebuf0", .framebuffer, driver_idx) orelse {
        klog.err("Framebuffer: Failed to create IO device (rendering still works)", .{});
        klog.info("Framebuffer Driver: %ux%u@%ubpp, pitch=%u, addr=0x%x, double_buf=%s", .{
            width, height, bpp, pitch, addr, if (double_buffer_active) "ON" else "OFF",
        });
        return;
    };

    driver_initialized = true;

    klog.info("Framebuffer Driver: %ux%u@%ubpp, pitch=%u, addr=0x%x, double_buf=%s", .{
        width, height, bpp, pitch, addr, if (double_buffer_active) "ON" else "OFF",
    });
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
