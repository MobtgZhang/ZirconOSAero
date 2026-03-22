//! Desktop Window Manager (DWM) — Aero Glass Compositor
//! Implements the core Aero visual effects:
//!   - Multi-pass box blur (approximates Gaussian blur)
//!   - Glass tint + saturation adjustment
//!   - Specular highlight band
//!   - Soft multi-layer drop shadow
//!
//! The blur operates on a scratch buffer to avoid reading pixels that
//! have already been modified in the same pass (separable two-pass).

const theme = @import("theme.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return r | (g << 8) | (b << 16);
}

pub const DwmConfig = struct {
    glass_enabled: bool = theme.DwmDefaults.glass_enabled,
    glass_opacity: u8 = theme.DwmDefaults.glass_opacity,
    blur_radius: u8 = theme.DwmDefaults.blur_radius,
    blur_passes: u8 = theme.DwmDefaults.blur_passes,
    glass_saturation: u8 = theme.DwmDefaults.glass_saturation,
    glass_tint_color: u32 = theme.DwmDefaults.glass_tint_color,
    glass_tint_opacity: u8 = theme.DwmDefaults.glass_tint_opacity,
    shadow_enabled: bool = theme.DwmDefaults.shadow_enabled,
    shadow_size: u8 = theme.DwmDefaults.shadow_size,
    shadow_layers: u8 = theme.DwmDefaults.shadow_layers,
};

var config: DwmConfig = .{};
var initialized: bool = false;

pub fn init(cfg: DwmConfig) void {
    config = cfg;
    initialized = true;
}

pub fn isEnabled() bool {
    return initialized and config.glass_enabled;
}

pub fn getConfig() *const DwmConfig {
    return &config;
}

pub fn setGlassEnabled(enabled: bool) void {
    config.glass_enabled = enabled;
}

pub fn updateGlassConfig(cfg: DwmConfig) void {
    config = cfg;
}

// ── Pixel helpers (work with raw framebuffer pointers) ──

const PixelReader = struct {
    base: usize,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,

    inline fn readPixel(self: *const PixelReader, x: u32, y: u32) u32 {
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

    inline fn writePixel(self: *const PixelReader, x: u32, y: u32, color: u32) void {
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

// ── Box Blur (separable, in-place with row buffer) ──
// Three passes of box blur approximate a Gaussian blur.
// Each pass performs a horizontal then vertical averaging sweep.
// Uses a static scratch line buffer to avoid heap allocation.

const MAX_LINE: usize = 4096;
var line_buf_r: [MAX_LINE]u32 = undefined;
var line_buf_g: [MAX_LINE]u32 = undefined;
var line_buf_b: [MAX_LINE]u32 = undefined;

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

/// Apply multi-pass box blur to a rectangular region of the framebuffer.
/// `fb_addr` is the linear framebuffer base address.
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
) void {
    if (!config.glass_enabled or rect_w <= 0 or rect_h <= 0) return;

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

    const passes = config.blur_passes;
    const radius: u32 = @as(u32, config.blur_radius);
    if (radius == 0) return;

    var pass: u8 = 0;
    while (pass < passes) : (pass += 1) {
        // Horizontal blur pass
        var row: u32 = y0;
        while (row < y1) : (row += 1) {
            hblurReadRow(&px, row, x0, x1);
            hblurWriteRow(&px, row, x0, x1, w, radius);
        }

        // Vertical blur pass
        var vcol: u32 = x0;
        while (vcol < x1) : (vcol += 1) {
            vblurReadCol(&px, vcol, y0, y1);
            vblurWriteCol(&px, vcol, y0, y1, h, radius);
        }
    }
}

// ── Glass Tint + Saturation ──
// After blurring, apply a color tint over the region with controllable
// saturation (desaturate → tint blend) and alpha compositing.

pub fn applyGlassTint(
    fb_addr: usize,
    fb_width: u32,
    fb_height: u32,
    fb_pitch: u32,
    fb_bpp: u8,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    rect_h: i32,
    tint_color: u32,
    opacity: u8,
    saturation: u8,
) void {
    if (rect_w <= 0 or rect_h <= 0) return;

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

    const tr: u32 = tint_color & 0xFF;
    const tg: u32 = (tint_color >> 8) & 0xFF;
    const tb: u32 = (tint_color >> 16) & 0xFF;
    const alpha: u32 = @as(u32, opacity);
    const inv_alpha: u32 = 255 - alpha;
    const sat: u32 = @as(u32, saturation);

    var row: u32 = y0;
    while (row < y1) : (row += 1) {
        var col: u32 = x0;
        while (col < x1) : (col += 1) {
            const c = px.readPixel(col, row);
            var cr: u32 = c & 0xFF;
            var cg: u32 = (c >> 8) & 0xFF;
            var cb: u32 = (c >> 16) & 0xFF;

            // Desaturate based on saturation parameter
            const lum = (cr * 77 + cg * 150 + cb * 29) >> 8;
            cr = (cr * sat + lum * (255 - sat)) / 255;
            cg = (cg * sat + lum * (255 - sat)) / 255;
            cb = (cb * sat + lum * (255 - sat)) / 255;

            // Alpha blend with tint
            const out_r = (tr * alpha + cr * inv_alpha) / 255;
            const out_g = (tg * alpha + cg * inv_alpha) / 255;
            const out_b = (tb * alpha + cb * inv_alpha) / 255;

            px.writePixel(col, row, (out_r & 0xFF) | ((out_g & 0xFF) << 8) | ((out_b & 0xFF) << 16));
        }
    }
}

// ── Specular Highlight Band ──
// Draws a lighter gradient band at the top of a glass region to simulate
// light refraction through frosted glass.

pub fn applySpecularHighlight(
    fb_addr: usize,
    fb_width: u32,
    fb_height: u32,
    fb_pitch: u32,
    fb_bpp: u8,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    band_height: i32,
) void {
    if (rect_w <= 0 or band_height <= 0) return;

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
    const y1: u32 = @min(y0 + @as(u32, @intCast(band_height)), fb_height);
    if (x0 >= x1 or y0 >= y1) return;

    const h = y1 - y0;
    var row: u32 = y0;
    while (row < y1) : (row += 1) {
        // Intensity fades from ~40 at top to 0 at bottom of band
        const t = row - y0;
        const intensity: u32 = 40 - (40 * t / h);

        var col: u32 = x0;
        while (col < x1) : (col += 1) {
            const c = px.readPixel(col, row);
            const cr = @min((c & 0xFF) + intensity, 255);
            const cg = @min(((c >> 8) & 0xFF) + intensity, 255);
            const cb = @min(((c >> 16) & 0xFF) + intensity, 255);
            px.writePixel(col, row, (cr & 0xFF) | ((cg & 0xFF) << 8) | ((cb & 0xFF) << 16));
        }
    }
}

// ── Soft Drop Shadow ──
// Multi-layer shadow with decreasing opacity for soft edges.

pub fn renderSoftShadow(
    fb_addr: usize,
    fb_width: u32,
    fb_height: u32,
    fb_pitch: u32,
    fb_bpp: u8,
    rect_x: i32,
    rect_y: i32,
    rect_w: i32,
    rect_h: i32,
) void {
    if (!config.shadow_enabled or rect_w <= 0 or rect_h <= 0) return;

    const px = PixelReader{
        .base = fb_addr,
        .pitch = fb_pitch,
        .width = fb_width,
        .height = fb_height,
        .bpp = fb_bpp,
    };

    const layers = @as(u32, config.shadow_layers);
    const size = @as(i32, @intCast(config.shadow_size));

    var layer: u32 = 0;
    while (layer < layers) : (layer += 1) {
        const offset = size - @as(i32, @intCast(layer * 2));
        if (offset <= 0) break;

        // Outer layers are more transparent (darker with less contribution)
        const base_alpha: u32 = 30 - layer * 6;
        const shadow_alpha: u32 = if (base_alpha > 255) 0 else base_alpha;

        const sx: i32 = rect_x + offset;
        const sy: i32 = rect_y + offset;

        const x0: u32 = if (sx < 0) 0 else @intCast(sx);
        const y0: u32 = if (sy < 0) 0 else @intCast(sy);
        const x1: u32 = @min(x0 + @as(u32, @intCast(rect_w)), fb_width);
        const y1: u32 = @min(y0 + @as(u32, @intCast(rect_h)), fb_height);

        if (x0 >= x1 or y0 >= y1) continue;

        var row: u32 = y0;
        while (row < y1) : (row += 1) {
            var col: u32 = x0;
            while (col < x1) : (col += 1) {
                const existing = px.readPixel(col, row);
                const er: u32 = existing & 0xFF;
                const eg: u32 = (existing >> 8) & 0xFF;
                const eb: u32 = (existing >> 16) & 0xFF;

                const out_r = er * (255 - shadow_alpha) / 255;
                const out_g = eg * (255 - shadow_alpha) / 255;
                const out_b = eb * (255 - shadow_alpha) / 255;
                px.writePixel(col, row, (out_r & 0xFF) | ((out_g & 0xFF) << 8) | ((out_b & 0xFF) << 16));
            }
        }
    }
}

// ── Composite Glass Effect (full pipeline) ──
// Combines blur → desaturate/tint → specular highlight into one call.

pub fn renderGlassRegion(
    fb_addr: usize,
    fb_width: u32,
    fb_height: u32,
    fb_pitch: u32,
    fb_bpp: u8,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    tint: u32,
    opacity: u8,
) void {
    if (!config.glass_enabled) return;

    const eff_tint = if (tint == 0) config.glass_tint_color else tint;
    const eff_opacity = if (opacity == 0) config.glass_opacity else opacity;

    // Step 1: Multi-pass box blur (approximates Gaussian)
    blurRect(fb_addr, fb_width, fb_height, fb_pitch, fb_bpp, x, y, w, h);

    // Step 2: Desaturate + tint blend
    applyGlassTint(
        fb_addr,
        fb_width,
        fb_height,
        fb_pitch,
        fb_bpp,
        x,
        y,
        w,
        h,
        eff_tint,
        eff_opacity,
        config.glass_saturation,
    );

    // Step 3: Specular highlight on upper third
    const highlight_h = @divTrunc(h, 3);
    if (highlight_h > 1) {
        applySpecularHighlight(fb_addr, fb_width, fb_height, fb_pitch, fb_bpp, x, y, w, highlight_h);
    }
}
