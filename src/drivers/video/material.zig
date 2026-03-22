//! Material Rendering System
//! Implements the three generations of Windows visual materials:
//!
//!   Glass (Win7 Aero):
//!     Background → Multi-pass Gaussian blur → Desaturate → Tint blend → Specular band
//!
//!   Acrylic (Win10 Fluent):
//!     Background → Gaussian blur → Noise texture overlay → Luminosity tint blend
//!     + Reveal highlight (radial gradient tracking pointer position)
//!
//!   Mica (Win11 Sun Valley):
//!     Wallpaper texture → Large-radius blur → Desaturate → Theme-tint blend
//!     + Acrylic 2.0 (adds Luminosity Blend layer between blur and tint)
//!
//! All pipelines operate on the raw framebuffer; in a GPU-accelerated build these
//! would map to HLSL/SPIR-V compute shaders running in the DWM composition pass.

const fb = @import("framebuffer.zig");

pub const MaterialType = enum(u8) {
    opaque_solid = 0,
    glass = 1,
    acrylic = 2,
    mica = 3,
    acrylic2 = 4,
    reveal = 5,
};

// ── Active Material State ──

var active_material: MaterialType = .opaque_solid;
var glass_cfg: GlassConfig = .{};
var acrylic_cfg: AcrylicConfig = .{};
var mica_cfg: MicaConfig = .{};
var material_initialized: bool = false;

// ── Configuration Structures ──

pub const GlassConfig = struct {
    blur_radius: u8 = 12,
    blur_passes: u8 = 3,
    tint_color: u32 = 0x4068A0,
    tint_opacity: u8 = 60,
    saturation: u8 = 200,
    specular_intensity: u8 = 35,
};

pub const AcrylicConfig = struct {
    blur_radius: u8 = 20,
    blur_passes: u8 = 4,
    noise_opacity: u8 = 8,
    luminosity_blend: u8 = 140,
    tint_color: u32 = 0x202020,
    tint_opacity: u8 = 70,
};

pub const MicaConfig = struct {
    blur_radius: u8 = 60,
    opacity: u8 = 200,
    luminosity: u8 = 160,
    tint_color: u32 = 0x202020,
};

// ── Initialization ──

pub fn init(primary: MaterialType) void {
    active_material = primary;
    material_initialized = true;
}

pub fn configureGlass(cfg: GlassConfig) void {
    glass_cfg = cfg;
}

pub fn configureAcrylic(cfg: AcrylicConfig) void {
    acrylic_cfg = cfg;
}

pub fn configureMica(cfg: MicaConfig) void {
    mica_cfg = cfg;
}

// ════════════════════════════════════════════════════
//  Glass Material (Win7 Aero DWM)
// ════════════════════════════════════════════════════
//
// Rendering pipeline:
//   1. Read existing framebuffer content behind the target rect
//   2. Apply multi-pass separable box blur (approximates Gaussian)
//   3. Desaturate towards grey by `saturation` factor
//   4. Alpha-blend tint color with `tint_opacity`
//   5. Add specular highlight band on the upper third
//   6. Draw 1px bright edge at the very top for reflection

pub fn renderGlass(x: i32, y: i32, w: i32, h: i32) void {
    if (!fb.isInitialized()) return;

    if (glass_cfg.blur_radius > 0) {
        fb.boxBlurRect(x, y, w, h, @as(u32, glass_cfg.blur_radius), glass_cfg.blur_passes);
    }

    fb.blendTintRect(x, y, w, h, glass_cfg.tint_color, glass_cfg.tint_opacity, glass_cfg.saturation);

    if (glass_cfg.specular_intensity > 0) {
        const shine_h = @divTrunc(h, 3);
        if (shine_h > 1) {
            fb.addSpecularBand(x, y, w, shine_h, glass_cfg.specular_intensity);
            fb.drawHLine(x, y, w, 0x00FFFFFF);
        }
    }
}

// ════════════════════════════════════════════════════
//  Acrylic Material (Win10 Fluent)
// ════════════════════════════════════════════════════
//
// Pipeline:
//   1. Multi-pass Gaussian blur on backdrop content
//   2. Overlay pseudo-random noise texture (frosted glass grain)
//   3. Luminosity tint blend (mix blurred result with solid tint
//      using luminosity as blending weight — brighter areas get
//      more tint, preserving depth perception)

pub fn renderAcrylic(x: i32, y: i32, w: i32, h: i32) void {
    if (!fb.isInitialized()) return;

    if (acrylic_cfg.blur_radius > 0) {
        fb.boxBlurRect(x, y, w, h, @as(u32, acrylic_cfg.blur_radius), acrylic_cfg.blur_passes);
    }

    if (acrylic_cfg.noise_opacity > 0) {
        applyNoiseOverlay(x, y, w, h, acrylic_cfg.noise_opacity);
    }

    applyLuminosityTint(x, y, w, h, acrylic_cfg.tint_color, acrylic_cfg.tint_opacity, acrylic_cfg.luminosity_blend);
}

// ════════════════════════════════════════════════════
//  Mica Material (Win11 Sun Valley)
// ════════════════════════════════════════════════════
//
// Unlike Acrylic which samples the content *behind* the window,
// Mica samples the desktop *wallpaper* and applies a large-radius
// blur + desaturation + theme tint. This means:
//   - The material colour shifts subtly as the window moves
//   - The computation cost is much lower (wallpaper is static)
//   - Other windows behind do NOT show through
//
// Pipeline:
//   1. Sample wallpaper region corresponding to window position
//   2. Large-radius blur (≈60px)
//   3. Reduce saturation
//   4. Luminosity-weighted theme tint blend

pub fn renderMica(x: i32, y: i32, w: i32, h: i32) void {
    if (!fb.isInitialized()) return;

    if (mica_cfg.blur_radius > 0) {
        const passes: u8 = if (mica_cfg.blur_radius > 30) 5 else 3;
        fb.boxBlurRect(x, y, w, h, @as(u32, mica_cfg.blur_radius), passes);
    }

    applyDesaturate(x, y, w, h, 120);

    applyLuminosityTint(x, y, w, h, mica_cfg.tint_color, mica_cfg.opacity, mica_cfg.luminosity);
}

// ════════════════════════════════════════════════════
//  Acrylic 2.0 (Win11 — enhanced Acrylic)
// ════════════════════════════════════════════════════
//
// Adds a Luminosity Blend layer between blur and tint that
// normalizes perceived brightness so the material looks
// consistent regardless of the backdrop content.
//
// Pipeline:  blur → luminosity_blend → tint → noise

pub fn renderAcrylic2(x: i32, y: i32, w: i32, h: i32) void {
    if (!fb.isInitialized()) return;

    fb.boxBlurRect(x, y, w, h, @as(u32, acrylic_cfg.blur_radius), acrylic_cfg.blur_passes);

    applyLuminosityNormalize(x, y, w, h, 160);

    applyLuminosityTint(x, y, w, h, acrylic_cfg.tint_color, acrylic_cfg.tint_opacity, acrylic_cfg.luminosity_blend);

    if (acrylic_cfg.noise_opacity > 0) {
        applyNoiseOverlay(x, y, w, h, acrylic_cfg.noise_opacity);
    }
}

// ════════════════════════════════════════════════════
//  Reveal Highlight (Fluent pointer light)
// ════════════════════════════════════════════════════
//
// A radial gradient light centered on the mouse cursor that
// illuminates UI element borders. In the real Windows implementation
// this is driven by ExpressionAnimation on the GPU compositor
// thread with zero CPU overhead per frame.

pub fn renderRevealHighlight(cx: i32, cy: i32, radius: u16, opacity: u8) void {
    if (!fb.isInitialized()) return;
    const r: i32 = @intCast(radius);
    const w_i32: i32 = @intCast(fb.getWidth());
    const h_i32: i32 = @intCast(fb.getHeight());
    const r_sq = r * r;

    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            const dist_sq = dx * dx + dy * dy;
            if (dist_sq > r_sq) continue;

            const px = cx + dx;
            const py = cy + dy;
            if (px < 0 or px >= w_i32 or py < 0 or py >= h_i32) continue;

            const dist = isqrt(@intCast(dist_sq));
            const falloff: u32 = @as(u32, opacity) * (@as(u32, @intCast(r)) - dist) / @as(u32, @intCast(r));
            const alpha: u8 = @intCast(if (falloff > 255) 255 else falloff);

            if (alpha > 2) {
                fb.blendPixel(@intCast(px), @intCast(py), 0x00FFFFFF, alpha);
            }
        }
    }
}

// ════════════════════════════════════════════════════
//  Shadow Rendering
// ════════════════════════════════════════════════════

pub fn renderShadow(x: i32, y: i32, w: i32, h: i32, size: u8, layers: u8) void {
    if (!fb.isInitialized()) return;
    const sz: i32 = @intCast(size);

    var layer: i32 = 0;
    const max_layers: i32 = @intCast(layers);
    while (layer < max_layers) : (layer += 1) {
        const offset = sz - layer * 2;
        if (offset <= 0) break;
        const alpha_val: u32 = @intCast(25 - @min(layer * 5, 24));
        const shadow_alpha: u8 = @intCast(alpha_val);
        fb.blendTintRect(x + offset, y + offset, w, h, 0x00000000, shadow_alpha, 255);
    }
}

// ════════════════════════════════════════════════════
//  Rounded Corner Clipping (SDF-based for Sun Valley)
// ════════════════════════════════════════════════════
//
// In the real Win11 DWM, rounded corners are implemented using
// Signed Distance Field (SDF) evaluation in a pixel shader —
// the distance from each pixel to the rounded rectangle boundary
// determines alpha, producing smooth anti-aliased corners.
//
// Here we approximate with a simple corner-mask clear.

pub fn applyRoundedClip(x: i32, y: i32, w: i32, h: i32, radius: u8) void {
    if (!fb.isInitialized() or radius == 0) return;
    const r: i32 = @intCast(radius);
    const w_i32: i32 = @intCast(fb.getWidth());
    const h_i32: i32 = @intCast(fb.getHeight());

    const corners = [_][2]i32{
        .{ x, y },
        .{ x + w - r, y },
        .{ x, y + h - r },
        .{ x + w - r, y + h - r },
    };

    const center_offsets = [_][2]i32{
        .{ r, r },
        .{ 0, r },
        .{ r, 0 },
        .{ 0, 0 },
    };

    for (corners, 0..) |corner, idx| {
        const co = center_offsets[idx];
        const center_x = corner[0] + co[0];
        const center_y = corner[1] + co[1];

        var dy: i32 = 0;
        while (dy < r) : (dy += 1) {
            var dx: i32 = 0;
            while (dx < r) : (dx += 1) {
                const cdx = dx - co[0];
                const cdy = dy - co[1];
                _ = center_x;
                _ = center_y;
                if (cdx * cdx + cdy * cdy > r * r) {
                    const px = corner[0] + dx;
                    const py = corner[1] + dy;
                    if (px >= 0 and px < w_i32 and py >= 0 and py < h_i32) {
                        fb.putPixel32(@intCast(px), @intCast(py), 0x00000000);
                    }
                }
            }
        }
    }
}

// ── Effect Helpers ──

fn applyNoiseOverlay(x: i32, y: i32, w: i32, h: i32, intensity: u8) void {
    const w_u: u32 = @intCast(if (w < 0) 0 else w);
    const h_u: u32 = @intCast(if (h < 0) 0 else h);
    const fb_w: u32 = fb.getWidth();
    const fb_h: u32 = fb.getHeight();

    var py: u32 = @intCast(if (y < 0) 0 else y);
    while (py < @as(u32, @intCast(y)) + h_u and py < fb_h) : (py += 1) {
        var px: u32 = @intCast(if (x < 0) 0 else x);
        while (px < @as(u32, @intCast(x)) + w_u and px < fb_w) : (px += 1) {
            const noise = pseudoNoise(px, py);
            const noise_val: i32 = @as(i32, @intCast(noise)) - 128;
            const scaled = @divTrunc(noise_val * @as(i32, intensity), 255);

            const pixel = fb.getPixel32(px, py);
            const r_ch: i32 = @intCast((pixel >> 0) & 0xFF);
            const g_ch: i32 = @intCast((pixel >> 8) & 0xFF);
            const b_ch: i32 = @intCast((pixel >> 16) & 0xFF);

            const nr = clampU8(r_ch + scaled);
            const ng = clampU8(g_ch + scaled);
            const nb = clampU8(b_ch + scaled);

            fb.putPixel32(px, py, @as(u32, nr) | (@as(u32, ng) << 8) | (@as(u32, nb) << 16));
        }
    }
}

fn applyLuminosityTint(x: i32, y: i32, w: i32, h: i32, tint: u32, opacity: u8, luminosity_weight: u8) void {
    const tr: u32 = (tint >> 0) & 0xFF;
    const tg: u32 = (tint >> 8) & 0xFF;
    const tb: u32 = (tint >> 16) & 0xFF;
    const fb_w: u32 = fb.getWidth();
    const fb_h: u32 = fb.getHeight();

    const w_u: u32 = @intCast(if (w < 0) 0 else w);
    const h_u: u32 = @intCast(if (h < 0) 0 else h);

    var py: u32 = @intCast(if (y < 0) 0 else y);
    while (py < @as(u32, @intCast(y)) + h_u and py < fb_h) : (py += 1) {
        var px: u32 = @intCast(if (x < 0) 0 else x);
        while (px < @as(u32, @intCast(x)) + w_u and px < fb_w) : (px += 1) {
            const pixel = fb.getPixel32(px, py);
            const pr: u32 = (pixel >> 0) & 0xFF;
            const pg: u32 = (pixel >> 8) & 0xFF;
            const pb: u32 = (pixel >> 16) & 0xFF;

            const lum = (pr * 77 + pg * 150 + pb * 29) >> 8;
            const eff_alpha = (@as(u32, opacity) * (@as(u32, luminosity_weight) + (255 - @as(u32, luminosity_weight)) * lum / 255)) >> 8;
            const a = if (eff_alpha > 255) 255 else eff_alpha;
            const inv = 255 - a;

            const nr = (pr * inv + tr * a) / 255;
            const ng = (pg * inv + tg * a) / 255;
            const nb = (pb * inv + tb * a) / 255;

            fb.putPixel32(px, py, nr | (ng << 8) | (nb << 16));
        }
    }
}

fn applyDesaturate(x: i32, y: i32, w: i32, h: i32, amount: u8) void {
    const fb_w: u32 = fb.getWidth();
    const fb_h: u32 = fb.getHeight();
    const w_u: u32 = @intCast(if (w < 0) 0 else w);
    const h_u: u32 = @intCast(if (h < 0) 0 else h);

    var py: u32 = @intCast(if (y < 0) 0 else y);
    while (py < @as(u32, @intCast(y)) + h_u and py < fb_h) : (py += 1) {
        var px: u32 = @intCast(if (x < 0) 0 else x);
        while (px < @as(u32, @intCast(x)) + w_u and px < fb_w) : (px += 1) {
            const pixel = fb.getPixel32(px, py);
            const r_val: u32 = (pixel >> 0) & 0xFF;
            const g_val: u32 = (pixel >> 8) & 0xFF;
            const b_val: u32 = (pixel >> 16) & 0xFF;

            const grey = (r_val * 77 + g_val * 150 + b_val * 29) >> 8;
            const amt: u32 = @intCast(amount);
            const inv = 255 - amt;

            const nr = (r_val * inv + grey * amt) / 255;
            const ng = (g_val * inv + grey * amt) / 255;
            const nb = (b_val * inv + grey * amt) / 255;

            fb.putPixel32(px, py, nr | (ng << 8) | (nb << 16));
        }
    }
}

fn applyLuminosityNormalize(x: i32, y: i32, w: i32, h: i32, target_lum: u8) void {
    const fb_w: u32 = fb.getWidth();
    const fb_h: u32 = fb.getHeight();
    const w_u: u32 = @intCast(if (w < 0) 0 else w);
    const h_u: u32 = @intCast(if (h < 0) 0 else h);
    const tl: u32 = @intCast(target_lum);

    var py: u32 = @intCast(if (y < 0) 0 else y);
    while (py < @as(u32, @intCast(y)) + h_u and py < fb_h) : (py += 1) {
        var px: u32 = @intCast(if (x < 0) 0 else x);
        while (px < @as(u32, @intCast(x)) + w_u and px < fb_w) : (px += 1) {
            const pixel = fb.getPixel32(px, py);
            const r_val: u32 = (pixel >> 0) & 0xFF;
            const g_val: u32 = (pixel >> 8) & 0xFF;
            const b_val: u32 = (pixel >> 16) & 0xFF;

            const lum = (r_val * 77 + g_val * 150 + b_val * 29) >> 8;
            if (lum == 0) continue;

            const nr = @min(r_val * tl / lum, 255);
            const ng = @min(g_val * tl / lum, 255);
            const nb = @min(b_val * tl / lum, 255);

            fb.putPixel32(px, py, nr | (ng << 8) | (nb << 16));
        }
    }
}

fn pseudoNoise(x: u32, y: u32) u8 {
    var h = x *% 374761393 +% y *% 668265263;
    h = (h ^ (h >> 13)) *% 1274126177;
    h = h ^ (h >> 16);
    return @truncate(h);
}

fn clampU8(val: i32) u8 {
    if (val < 0) return 0;
    if (val > 255) return 255;
    return @intCast(val);
}

fn isqrt(n: u32) u32 {
    if (n == 0) return 0;
    var x = n;
    var y = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    }
    return x;
}

// ── Query ──

pub fn isInitialized() bool {
    return material_initialized;
}

pub fn getActiveMaterial() MaterialType {
    return active_material;
}

pub fn getGlassConfig() *const GlassConfig {
    return &glass_cfg;
}

pub fn getAcrylicConfig() *const AcrylicConfig {
    return &acrylic_cfg;
}

pub fn getMicaConfig() *const MicaConfig {
    return &mica_cfg;
}
