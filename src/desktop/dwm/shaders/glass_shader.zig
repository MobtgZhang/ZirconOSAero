// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS DWM Shaders - Glass Effect Implementation
//! Combines blur, tint, and specular highlight for Aero Glass effect.

const std = @import("std");
const blur = @import("blur_shader.zig");

// ============================================================================
// Glass Effect Configuration
// ============================================================================

pub const GlassConfig = struct {
    enabled: bool = true,
    opacity: u8 = 200,
    saturation: u8 = 180,
    tint_color: u32 = 0x996666,
    specular_intensity: u8 = 40,
};

pub var g_glass_config: GlassConfig = .{};

// ============================================================================
// Tint Configuration
// ============================================================================

pub const TintConfig = struct {
    color: u32,
    opacity: u8,
    saturation: u8,
};

pub const TINT_DEFAULT: TintConfig = .{
    .color = 0x996666,
    .opacity = 200,
    .saturation = 180,
};

pub const TINT_TASKBAR: TintConfig = .{
    .color = 0x885555,
    .opacity = 180,
    .saturation = 170,
};

pub const TINT_PANEL: TintConfig = .{
    .color = 0x778888,
    .opacity = 150,
    .saturation = 160,
};

// ============================================================================
// Glass Tint Application
// ============================================================================

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

    const px = blur.PixelReader{
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

// ============================================================================
// Specular Highlight
// ============================================================================

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
    intensity: u8,
) void {
    if (rect_w <= 0 or band_height <= 0) return;

    const px = blur.PixelReader{
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
    const base_intensity: u32 = @as(u32, intensity);

    var row: u32 = y0;
    while (row < y1) : (row += 1) {
        // Intensity fades from base at top to 0 at bottom of band
        const t = row - y0;
        const intensity_val: u32 = base_intensity - (base_intensity * t / h);

        var col: u32 = x0;
        while (col < x1) : (col += 1) {
            const c = px.readPixel(col, row);
            const cr = @min((c & 0xFF) + intensity_val, 255);
            const cg = @min(((c >> 8) & 0xFF) + intensity_val, 255);
            const cb = @min(((c >> 16) & 0xFF) + intensity_val, 255);
            px.writePixel(col, row, (cr & 0xFF) | ((cg & 0xFF) << 8) | ((cb & 0xFF) << 16));
        }
    }
}

// ============================================================================
// Full Glass Effect (Pipeline)
// ============================================================================

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
    saturation: u8,
    blur_radius: u32,
    blur_passes: u8,
) void {
    if (!g_glass_config.enabled or w <= 0 or h <= 0) return;

    // Step 1: Multi-pass box blur (approximates Gaussian)
    if (blur_radius > 0 and blur_passes > 0) {
        blur.blurRect(fb_addr, fb_width, fb_height, fb_pitch, fb_bpp, x, y, w, h, blur_radius, blur_passes);
    }

    // Step 2: Desaturate + tint blend
    const eff_tint = if (tint != 0) tint else g_glass_config.tint_color;
    const eff_opacity = if (opacity != 0) opacity else g_glass_config.opacity;
    const eff_saturation = if (saturation != 0) saturation else g_glass_config.saturation;
    applyGlassTint(fb_addr, fb_width, fb_height, fb_pitch, fb_bpp, x, y, w, h, eff_tint, eff_opacity, eff_saturation);

    // Step 3: Specular highlight on upper third
    const highlight_h = @divTrunc(h, 3);
    if (highlight_h > 1 and g_glass_config.specular_intensity > 0) {
        applySpecularHighlight(fb_addr, fb_width, fb_height, fb_pitch, fb_bpp, x, y, w, highlight_h, g_glass_config.specular_intensity);
    }
}
