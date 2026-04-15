// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS DWM Shaders - Shadow Effect Implementation
//! Multi-layer soft drop shadow effect.

const std = @import("std");
const blur = @import("blur_shader.zig");

// ============================================================================
// Shadow Configuration
// ============================================================================

pub const ShadowConfig = struct {
    enabled: bool = true,
    size: u8 = 8,
    layers: u8 = 4,
    tint_r: u8 = 0x30,
    tint_g: u8 = 0x48,
    tint_b: u8 = 0x60,
};

pub var g_shadow_config: ShadowConfig = .{};

// ============================================================================
// Shadow Rendering
// ============================================================================

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
    if (!g_shadow_config.enabled or rect_w <= 0 or rect_h <= 0) return;

    const px = blur.PixelReader{
        .base = fb_addr,
        .pitch = fb_pitch,
        .width = fb_width,
        .height = fb_height,
        .bpp = fb_bpp,
    };

    const layers = @as(u32, g_shadow_config.layers);
    const size = @as(i32, @intCast(g_shadow_config.size));
    const shadow_tint_r: u32 = @as(u32, g_shadow_config.tint_r);
    const shadow_tint_g: u32 = @as(u32, g_shadow_config.tint_g);
    const shadow_tint_b: u32 = @as(u32, g_shadow_config.tint_b);

    var layer: u32 = 0;
    while (layer < layers) : (layer += 1) {
        const offset = size - @as(i32, @intCast(layer * 2));
        if (offset <= 0) break;

        // Alpha: outer layer is darker, inner layer is lighter
        const base_alpha: u32 = 18 - @min(layer * 4, 14);
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

                // Blend with cold blue-tinted shadow color
                const blend_r = (er * (255 - shadow_alpha) + shadow_tint_r * shadow_alpha) / 255;
                const blend_g = (eg * (255 - shadow_alpha) + shadow_tint_g * shadow_alpha) / 255;
                const blend_b = (eb * (255 - shadow_alpha) + shadow_tint_b * shadow_alpha) / 255;
                px.writePixel(col, row, (blend_r & 0xFF) | ((blend_g & 0xFF) << 8) | ((blend_b & 0xFF) << 16));
            }
        }
    }
}

// ============================================================================
// Shadow Preset
// ============================================================================

pub const ShadowPreset = enum {
    none,
    light,
    medium,
    heavy,
};

pub fn applyShadowPreset(preset: ShadowPreset) void {
    switch (preset) {
        .none => {
            g_shadow_config.enabled = false;
        },
        .light => {
            g_shadow_config.enabled = true;
            g_shadow_config.size = 4;
            g_shadow_config.layers = 2;
        },
        .medium => {
            g_shadow_config.enabled = true;
            g_shadow_config.size = 8;
            g_shadow_config.layers = 4;
        },
        .heavy => {
            g_shadow_config.enabled = true;
            g_shadow_config.size = 16;
            g_shadow_config.layers = 8;
        },
    }
}
