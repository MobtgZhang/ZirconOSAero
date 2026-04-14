// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

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

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/theme.zig");
const rgb = theme.rgb;

fn clampCoordI64(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

// ── Blur Performance Configuration ──

/// 小于此面积（像素数）的区域直接跳过模糊（避免过度计算）
const BLUR_MIN_AREA_PIXELS: u32 = 64 * 64;

/// 下采样阈值：宽或高超过此值时启用下采样模糊
const BLUR_DOWNSCALE_THRESHOLD: u32 = 512;

/// 下采样比例（2=缩小一半，4=缩小1/4）
const BLUR_DOWNSCALE_FACTOR: u32 = 2;

/// 最小可模糊面积（避免死循环或极小区域开销不成比例）
const BLUR_MIN_DIMENSION: u32 = 8;

// ── Blur Efficiency Helper ──

/// 判断给定矩形是否应该跳过模糊处理（面积太小不值得模糊）
fn shouldSkipBlur(w: u32, h: u32) bool {
    return w < BLUR_MIN_DIMENSION or h < BLUR_MIN_DIMENSION or
        w * h < BLUR_MIN_AREA_PIXELS;
}

/// 检查是否应该使用下采样模糊
fn shouldUseDownscaledBlur(w: u32, h: u32) bool {
    return w > BLUR_DOWNSCALE_THRESHOLD or h > BLUR_DOWNSCALE_THRESHOLD;
}

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

// ── Blur Caching for Dirty Region Optimization ──

/// 模糊缓存：记录最近一次模糊的矩形区域和配置
/// 避免在同一区域重复模糊，提升性能
const BLUR_CACHE_SIZE: usize = 4;
var blur_cache: [BLUR_CACHE_SIZE]BlurCacheEntry = [_]BlurCacheEntry{.{}} ** BLUR_CACHE_SIZE;

/// 模糊缓存条目
const BlurCacheEntry = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    radius: u32 = 0,
    passes: u32 = 0,
    valid: bool = false,

    /// 检查缓存是否匹配当前请求
    fn matches(self: *const BlurCacheEntry, nx: i32, ny: i32, nw: i32, nh: i32, nr: u32, np: u32) bool {
        return self.valid and
            self.x == nx and self.y == ny and
            self.w == nw and self.h == nh and
            self.radius == nr and self.passes == np;
    }
};

/// 检查模糊缓存是否命中
fn isBlurCached(x: i32, y: i32, w: i32, h: i32, radius: u32, passes: u32) bool {
    for (&blur_cache) |*entry| {
        if (entry.matches(x, y, w, h, radius, passes)) {
            return true;
        }
    }
    return false;
}

/// 更新模糊缓存
fn updateBlurCache(x: i32, y: i32, w: i32, h: i32, radius: u32, passes: u32) void {
    // 移动缓存，腾出空间
    var i: usize = BLUR_CACHE_SIZE - 1;
    while (i > 0) : (i -= 1) {
        blur_cache[i] = blur_cache[i - 1];
    }
    // 插入新条目
    blur_cache[0] = .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .radius = radius,
        .passes = passes,
        .valid = true,
    };
}

/// 清除模糊缓存（窗口内容变化时调用）
pub fn invalidateBlurCache() void {
    for (&blur_cache) |*entry| {
        entry.valid = false;
    }
}

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

    const radius: u32 = glass_cfg.blur_radius;
    const passes: u32 = glass_cfg.blur_passes;

    // 缓存检查：避免重复模糊
    if (radius > 0 and !isBlurCached(x, y, w, h, radius, passes)) {
        fb.boxBlurRect(x, y, w, h, radius, passes);
        updateBlurCache(x, y, w, h, radius, passes);
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

    const radius: u32 = acrylic_cfg.blur_radius;
    const passes: u32 = acrylic_cfg.blur_passes;

    // 缓存检查：避免重复模糊
    if (radius > 0 and !isBlurCached(x, y, w, h, radius, passes)) {
        fb.boxBlurRect(x, y, w, h, radius, passes);
        updateBlurCache(x, y, w, h, radius, passes);
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

    const radius: u32 = mica_cfg.blur_radius;
    const passes: u32 = if (radius > 30) 5 else 3;

    // 缓存检查：避免重复模糊
    if (radius > 0 and !isBlurCached(x, y, w, h, radius, passes)) {
        fb.boxBlurRect(x, y, w, h, radius, passes);
        updateBlurCache(x, y, w, h, radius, passes);
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

    const radius: u32 = acrylic_cfg.blur_radius;
    const passes: u32 = acrylic_cfg.blur_passes;

    // 缓存检查：避免重复模糊
    if (radius > 0 and !isBlurCached(x, y, w, h, radius, passes)) {
        fb.boxBlurRect(x, y, w, h, radius, passes);
        updateBlurCache(x, y, w, h, radius, passes);
    }

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
    const r_sq = @as(i64, r) * @as(i64, r);

    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            const dx64 = @as(i64, dx);
            const dy64 = @as(i64, dy);
            const dist_sq = dx64 * dx64 + dy64 * dy64;
            if (dist_sq > r_sq) continue;

            const px = clampCoordI64(@as(i64, cx) + dx64);
            const py = clampCoordI64(@as(i64, cy) + dy64);
            if (px < 0 or px >= w_i32 or py < 0 or py >= h_i32) continue;

            const dist_sq_cap: u32 = if (dist_sq > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(dist_sq);
            const dist = isqrt(dist_sq_cap);
            const ru: u32 = @intCast(r);
            const du: u32 = dist;
            const dr: u32 = if (du >= ru) 0 else ru - du;
            const falloff: u32 = @as(u32, opacity) * dr / @max(ru, 1);
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
        const alpha_val: u32 = @intCast(18 - @min(layer * 4, 14));
        const shadow_alpha: u8 = @intCast(alpha_val);
        // 与 `dwm.renderShadow` 一致：冷灰蓝而非纯黑，减轻多窗重叠与局部重绘下的黑边观感。
        const shadow_tint = rgb(0x30, 0x48, 0x60);
        fb.blendTintRect(
            clampCoordI64(@as(i64, x) + @as(i64, offset)),
            clampCoordI64(@as(i64, y) + @as(i64, offset)),
            w,
            h,
            shadow_tint,
            shadow_alpha,
            255,
        );
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
// 这里使用 SDF（符号距离场）算法实现真正的抗锯齿圆角：
// - 计算每个像素到圆弧边界的距离
// - 根据距离计算透明度，实现边缘平滑过渡
// - 与 GPU shader 中的 smoothstep 效果等价

/// SDF 抗锯齿圆角裁剪（仅裁剪圆角区域）
/// 使用符号距离场算法实现边缘平滑过渡
pub fn applyRoundedClipAA(x: i32, y: i32, w: i32, h: i32, radius: u8) void {
    if (!fb.isInitialized() or radius == 0) return;
    const r: i32 = @intCast(radius);
    const w_i32: i32 = @intCast(fb.getWidth());
    const h_i32: i32 = @intCast(fb.getHeight());
    if (w_i32 <= 0 or h_i32 <= 0) return;

    // 每个像素的抗锯齿过渡宽度（像素数）
    // 值越大，边缘越柔和；值越小，边缘越锐利
    const aa_scale: f32 = 1.5;

    // 四个角的位置和圆心偏移
    const corners = [_]struct { cx: i32, cy: i32, corner_x: i32, corner_y: i32 }{
        // 左上角
        .{ .cx = x + r, .cy = y + r, .corner_x = x, .corner_y = y },
        // 右上角
        .{ .cx = x + w - r, .cy = y + r, .corner_x = x + w - r, .corner_y = y },
        // 左下角
        .{ .cx = x + r, .cy = y + h - r, .corner_x = x, .corner_y = y + h - r },
        // 右下角
        .{ .cx = x + w - r, .cy = y + h - r, .corner_x = x + w - r, .corner_y = y + h - r },
    };

    for (corners) |corner| {
        // 遍历圆角区域内的所有像素
        var dy: i32 = 0;
        while (dy < r) : (dy += 1) {
            var dx: i32 = 0;
            while (dx < r) : (dx += 1) {
                const px = corner.corner_x + dx;
                const py = corner.corner_y + dy;

                // 计算像素中心到圆心的距离（用于 SDF）
                const cdx = @as(f32, @intCast(dx)) + 0.5;
                const cdy = @as(f32, @intCast(dy)) + 0.5;
                const dist_sq = cdx * cdx + cdy * cdy;
                const r_f = @as(f32, @intCast(r));

                // SDF 距离：正值表示在圆外，负值表示在圆内
                const dist = @sqrt(dist_sq) - r_f;

                // 计算抗锯齿透明度
                // 当 dist < 0（在圆内）：alpha = 1.0
                // 当 dist > aa_scale（在 aa_scale 像素外）：alpha = 0.0
                // 中间地带平滑过渡
                var alpha: u8 = 255;
                if (dist > 0) {
                    // 在圆外：透明度根据距离衰减
                    const t = @min(dist / aa_scale, 1.0);
                    alpha = @intFromFloat(@round((1.0 - t) * 255.0));
                }

                if (alpha < 255) {
                    // 需要混合：获取现有像素颜色和填充颜色
                    const safe_x: i32 = std.math.clamp(px, @as(i32, 0), w_i32 - 1);
                    const safe_y: i32 = std.math.clamp(py, @as(i32, 0), h_i32 - 1);
                    const existing = fb.getPixel32(@as(u32, safe_x), @as(u32, safe_y));

                    // 获取圆弧边界内的样本点颜色（近似圆弧内的实际颜色）
                    const sample_x: i32 = std.math.clamp(corner.cx, @as(i32, 0), w_i32 - 1);
                    const sample_y: i32 = std.math.clamp(corner.cy, @as(i32, 0), h_i32 - 1);
                    const corner_fill = fb.getPixel32(@as(u32, @intCast(sample_x)), @as(u32, @intCast(sample_y))) & 0x00FFFFFF;

                    // Alpha 混合：corner_fill * alpha + existing * (1 - alpha)
                    const er = (existing >> 0) & 0xFF;
                    const eg = (existing >> 8) & 0xFF;
                    const eb = (existing >> 16) & 0xFF;
                    const fr = (corner_fill >> 0) & 0xFF;
                    const fg = (corner_fill >> 8) & 0xFF;
                    const fb_c = (corner_fill >> 16) & 0xFF;

                    const inv_alpha: u32 = 255 - @as(u32, alpha);
                    const out_r = (@as(u32, fr) * @as(u32, alpha) + @as(u32, er) * inv_alpha) / 255;
                    const out_g = (@as(u32, fg) * @as(u32, alpha) + @as(u32, eg) * inv_alpha) / 255;
                    const out_b = (@as(u32, fb_c) * @as(u32, alpha) + @as(u32, eb) * inv_alpha) / 255;

                    const out_color = out_r | (out_g << 8) | (out_b << 16) | 0xFF000000;

                    if (px >= 0 and px < w_i32 and py >= 0 and py < h_i32) {
                        fb.putPixel32(@as(u32, @intCast(px)), @as(u32, @intCast(py)), out_color);
                    }
                }
            }
        }
    }
}

/// 传统圆角裁剪（保持兼容性）
pub fn applyRoundedClip(x: i32, y: i32, w: i32, h: i32, radius: u8) void {
    if (!fb.isInitialized() or radius == 0) return;
    const r: i32 = @intCast(radius);
    const w_i32: i32 = @intCast(fb.getWidth());
    const h_i32: i32 = @intCast(fb.getHeight());
    if (w_i32 <= 0 or h_i32 <= 0) return;

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
        const cx = corner[0] + co[0];
        const cy = corner[1] + co[1];
        const samp_x: u32 = @intCast(std.math.clamp(cx, 0, w_i32 - 1));
        const samp_y: u32 = @intCast(std.math.clamp(cy, 0, h_i32 - 1));
        const corner_fill: u32 = fb.getPixel32(samp_x, samp_y) & 0x00FFFFFF;

        var dy: i32 = 0;
        while (dy < r) : (dy += 1) {
            var dx: i32 = 0;
            while (dx < r) : (dx += 1) {
                const cdx = dx - co[0];
                const cdy = dy - co[1];
                if (cdx * cdx + cdy * cdy > r * r) {
                    const px = corner[0] + dx;
                    const py = corner[1] + dy;
                    if (px >= 0 and px < w_i32 and py >= 0 and py < h_i32) {
                        fb.putPixel32(@intCast(px), @intCast(py), corner_fill);
                    }
                }
            }
        }
    }
}

// ── Effect Helpers ──

/// 扫描线终点 `min(start + extent, fb_lim)`；禁止对负坐标做 `i32→u32` 再与 `extent` 相加（Debug 会 integer overflow）。
fn rectScanEnd(start: u32, extent: u32, fb_lim: u32) u32 {
    const e = @as(u64, start) + @as(u64, extent);
    const lim = @as(u64, fb_lim);
    return @intCast(@min(e, lim));
}

fn applyNoiseOverlay(x: i32, y: i32, w: i32, h: i32, intensity: u8) void {
    const w_u: u32 = @intCast(if (w < 0) 0 else w);
    const h_u: u32 = @intCast(if (h < 0) 0 else h);
    const fb_w: u32 = fb.getWidth();
    const fb_h: u32 = fb.getHeight();

    const x0: u32 = @intCast(if (x < 0) 0 else x);
    const y0: u32 = @intCast(if (y < 0) 0 else y);
    const x_end = rectScanEnd(x0, w_u, fb_w);
    const y_end = rectScanEnd(y0, h_u, fb_h);

    var py: u32 = y0;
    while (py < y_end) : (py += 1) {
        var px: u32 = x0;
        while (px < x_end) : (px += 1) {
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

    const x0: u32 = @intCast(if (x < 0) 0 else x);
    const y0: u32 = @intCast(if (y < 0) 0 else y);
    const x_end = rectScanEnd(x0, w_u, fb_w);
    const y_end = rectScanEnd(y0, h_u, fb_h);

    var py: u32 = y0;
    while (py < y_end) : (py += 1) {
        var px: u32 = x0;
        while (px < x_end) : (px += 1) {
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

    const x0: u32 = @intCast(if (x < 0) 0 else x);
    const y0: u32 = @intCast(if (y < 0) 0 else y);
    const x_end = rectScanEnd(x0, w_u, fb_w);
    const y_end = rectScanEnd(y0, h_u, fb_h);

    var py: u32 = y0;
    while (py < y_end) : (py += 1) {
        var px: u32 = x0;
        while (px < x_end) : (px += 1) {
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

    const x0: u32 = @intCast(if (x < 0) 0 else x);
    const y0: u32 = @intCast(if (y < 0) 0 else y);
    const x_end = rectScanEnd(x0, w_u, fb_w);
    const y_end = rectScanEnd(y0, h_u, fb_h);

    var py: u32 = y0;
    while (py < y_end) : (py += 1) {
        var px: u32 = x0;
        while (px < x_end) : (px += 1) {
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
