//! Desktop Window Manager — **ZirconDWM**：合成配置与 Aero 玻璃效果（清洁室实现，非 Windows DWM 代码）。
//!
//! Provides the Aero Glass pipeline: backdrop sample → blur → tint blend →
//! specular highlight → chrome decoration. Also used by Fluent (Acrylic)
//! and Sun Valley (Mica) renderers for their material effects.
//!
//! DesktopManagerSpec.md / Aero 路径：合成循环在「提交帧」前应尽快产出可显示内容；首帧可跳过盒式模糊。
//! （仍保留 tint + 高光），在首次 `present()` 之后再跑全量模糊，避免双缓冲下长时间黑屏。
//!
//! 公开概念对照（clean-room，非 API 复制）：Microsoft Learn「Desktop Window Manager」— 合成启用、
//! Blur behind、扩展非客户区等用户态契约见 <https://learn.microsoft.com/en-us/windows/win32/api/_dwm/> 与概述
//! <https://learn.microsoft.com/en-us/windows/win32/learnwin32/the-desktop-window-manager>。
//! 本内核 CPU 路径用 `blur_budget_*` 与 `renderGlassTintOnly`（无盒式模糊）对应文档中的性能与交互注意点。

const std = @import("std");
const fb = @import("framebuffer.zig");
const theme = @import("theme.zig");
const nt61_aero = @import("nt61_aero_defaults");
const rgb = theme.rgb;

/// 与 `nt61_aero_defaults.compositor_config_epoch` 一致；`display` 等仅通过本模块读取，避免重复依赖 `nt61_aero_defaults` 模块。
pub const compositor_config_epoch: u32 = nt61_aero.compositor_config_epoch;

fn clampCoordI64(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

pub const DwmConfig = struct {
    glass_enabled: bool = nt61_aero.KernelDwm.glass_enabled,
    glass_opacity: u8 = nt61_aero.KernelDwm.glass_opacity,
    /// 与 docs/cn/AeroRendering.md、`nt61_aero_defaults` 一致（标题栏/面板盒式模糊）
    glass_blur_radius: u8 = nt61_aero.KernelDwm.glass_blur_radius,
    glass_blur_passes: u8 = nt61_aero.KernelDwm.glass_blur_passes,
    glass_saturation: u8 = nt61_aero.KernelDwm.glass_saturation,
    glass_tint_color: u32 = nt61_aero.KernelDwm.glass_tint_color,
    glass_tint_opacity: u8 = nt61_aero.KernelDwm.glass_tint_opacity,
    /// 任务栏略低于窗口标题栏的不透明度，更易透出 Harmony 壁纸（Win7 任务栏偏「实」仍保留）
    glass_taskbar_tint_opacity: u8 = nt61_aero.KernelDwm.glass_taskbar_tint_opacity,
    specular_intensity: u8 = nt61_aero.KernelDwm.specular_intensity,
    animation_enabled: bool = nt61_aero.KernelDwm.animation_enabled,
    peek_enabled: bool = nt61_aero.KernelDwm.peek_enabled,
    shadow_enabled: bool = nt61_aero.KernelDwm.shadow_enabled,
    vsync_compositor: bool = nt61_aero.KernelDwm.vsync_compositor,
    smooth_cursor: bool = nt61_aero.KernelDwm.smooth_cursor,
    cursor_lerp_factor: i32 = nt61_aero.KernelDwm.cursor_lerp_factor,
};

pub const GlassChrome = enum { taskbar, caption, panel };

var config: DwmConfig = .{};
var initialized: bool = false;

/// 由 display 在绘制前设置：首帧（尚未 present）为 true，跳过 `boxBlurRect`。
var skip_glass_box_blur: bool = false;
/// 拖窗等交互期：单遍小半径模糊，减轻 CPU 负载同时保留少许磨砂感。
var glass_lite_blur: bool = false;

/// 每帧 `renderDesktopFrameEx` 入口重置；`boxBlurRect` 消耗预算，耗尽则本帧后续 blur 跳过。
var blur_budget_pixel_passes: u32 = 0;
var blur_rect_calls_remaining: u32 = 0;

pub fn beginFrameBlurBudget() void {
    blur_budget_pixel_passes = nt61_aero.KernelDwm.blur_budget_pixel_passes_per_frame;
    blur_rect_calls_remaining = nt61_aero.KernelDwm.blur_max_rect_calls_per_frame;
}

/// 按架构与分辨率收紧 `config`（在 `init` 之后、`fb` 已就绪时调用）；与 `display.initAeroDwm` 同步写回 `dwm_config`。
pub fn applyPlatformAndResolutionTuning(width: u32, height: u32) void {
    if (!initialized) return;
    const builtin = @import("builtin");
    if (builtin.cpu.arch == .loongarch64) {
        config.glass_blur_radius = @min(config.glass_blur_radius, nt61_aero.KernelDwm.glass_blur_radius_loongarch_cap);
        config.glass_blur_passes = @min(config.glass_blur_passes, nt61_aero.KernelDwm.glass_blur_passes_loongarch_cap);
    }
    const pixels = width *| height;
    if (pixels >= nt61_aero.KernelDwm.blur_resolution_downgrade_pixel_threshold) {
        config.glass_blur_radius = @min(config.glass_blur_radius, nt61_aero.KernelDwm.glass_blur_radius_hd_cap);
        config.glass_blur_passes = @min(config.glass_blur_passes, nt61_aero.KernelDwm.glass_blur_passes_hd_cap);
    }
}

fn tryConsumeBlurBudget(w: i32, h: i32, passes: u32) bool {
    if (w <= 0 or h <= 0 or passes == 0) return true;
    const area64 = @as(u64, @intCast(w)) *% @as(u64, @intCast(h));
    const cost64 = area64 *% @as(u64, passes);
    const cost_u32: u32 = if (cost64 > std.math.maxInt(u32))
        std.math.maxInt(u32)
    else
        @intCast(cost64);
    if (cost_u32 > blur_budget_pixel_passes) return false;
    blur_budget_pixel_passes -= cost_u32;
    return true;
}

fn boxBlurRectBudgeted(x: i32, y: i32, w: i32, h: i32, radius: u32, passes: u32) void {
    if (w <= 0 or h <= 0 or radius == 0 or passes == 0) return;
    if (blur_rect_calls_remaining == 0) return;
    const area64 = @as(u64, @intCast(w)) *% @as(u64, @intCast(h));
    if (area64 > nt61_aero.KernelDwm.blur_max_single_rect_pixels) return;
    if (!tryConsumeBlurBudget(w, h, passes)) return;
    blur_rect_calls_remaining -= 1;
    fb.boxBlurRect(x, y, w, h, radius, passes);
}

pub fn setSkipGlassBoxBlur(skip: bool) void {
    skip_glass_box_blur = skip;
}

pub fn shouldSkipGlassBoxBlur() bool {
    return skip_glass_box_blur;
}

pub fn setGlassLiteBlurEnabled(enabled: bool) void {
    glass_lite_blur = enabled;
}

pub fn init(cfg: DwmConfig) void {
    config = cfg;
    const bo = @import("build_options");
    if (bo.aero_blur_light) {
        config.glass_blur_radius = @min(config.glass_blur_radius, 4);
        config.glass_blur_passes = @min(config.glass_blur_passes, 2);
    }
    initialized = true;
}

pub fn isInitialized() bool {
    return initialized;
}

pub fn isEnabled() bool {
    return initialized and config.glass_enabled;
}

pub fn getConfig() *const DwmConfig {
    return &config;
}

pub fn setGlass(enabled: bool) void {
    if (config.glass_enabled == enabled) return;
    config.glass_enabled = enabled;
    const user32 = @import("../../subsystems/win32/user32.zig");
    user32.broadcastDwmCompositionChanged(if (enabled) user32.TRUE else user32.FALSE);
    user32.broadcastDwmNcRenderingChanged(user32.TRUE);
    user32.broadcastDwmColorizationChanged(0, user32.FALSE);
}

pub fn getCursorLerpFactor() i32 {
    return config.cursor_lerp_factor;
}

pub fn isShadowEnabled() bool {
    return initialized and config.shadow_enabled;
}

pub fn isGlassEnabled() bool {
    return initialized and config.glass_enabled;
}

/// 无盒式模糊：tint + 高光 + 边框（拖窗标题栏、小菜单、开始菜单首帧等）。
pub fn renderGlassTintOnly(x: i32, y: i32, w: i32, h: i32, tint: u32, chrome: GlassChrome) void {
    renderGlassEffectInternal(x, y, w, h, tint, chrome, true);
}

pub fn renderGlassEffect(x: i32, y: i32, w: i32, h: i32, tint: u32, chrome: GlassChrome) void {
    renderGlassEffectInternal(x, y, w, h, tint, chrome, false);
}

fn renderGlassEffectInternal(x: i32, y: i32, w: i32, h: i32, tint: u32, chrome: GlassChrome, skip_box_blur: bool) void {
    if (!fb.isInitialized()) return;
    if (!config.glass_enabled) {
        fb.fillRect(x, y, w, h, if (tint != 0) tint else config.glass_tint_color);
        return;
    }

    const eff_tint = if (tint != 0) tint else config.glass_tint_color;
    var blur_r = @as(u32, config.glass_blur_radius);
    const passes = @as(u32, config.glass_blur_passes);
    const tint_alpha: u8 = switch (chrome) {
        .taskbar => config.glass_taskbar_tint_opacity,
        else => config.glass_tint_opacity,
    };

    const cap_tb = nt61_aero.KernelDwm.taskbar_blur_radius_cap;
    if (chrome == .taskbar and cap_tb > 0) {
        blur_r = @min(blur_r, @as(u32, cap_tb));
    }

    const do_blur = !skip_box_blur and blur_r > 0 and passes > 0;
    // NT 6.1 Aero 风格：标题栏/面板用多遍盒式模糊；任务栏薄但宽，小半径多遍 ≈ 更强磨砂感。
    if (do_blur and glass_lite_blur) {
        const tr = @min(blur_r, @as(u32, 4));
        boxBlurRectBudgeted(x, y, w, h, @max(1, tr), 1);
    } else if (do_blur and !skip_glass_box_blur) {
        if (chrome == .taskbar) {
            const tr = @min(blur_r, @as(u32, 6));
            boxBlurRectBudgeted(x, y, w, h, tr, 1);
            if (tr > 1) {
                boxBlurRectBudgeted(x, y, w, h, @max(2, tr * 2 / 3), 1);
            }
            boxBlurRectBudgeted(x, y, w, h, 2, 1);
        } else {
            // 标题栏/面板：递减半径的多遍盒式模糊，减轻纯盒式滤波在按钮区的块状边缘（与任务栏路径同思路，算法自研）。
            const tr = @max(1, blur_r);
            boxBlurRectBudgeted(x, y, w, h, tr, 1);
            if (tr >= 4) {
                boxBlurRectBudgeted(x, y, w, h, @max(2, tr * 2 / 3), 1);
            }
            if (passes > 1 and tr >= 2) {
                boxBlurRectBudgeted(x, y, w, h, 2, @min(passes, 2));
            }
        }
    }

    fb.blendTintRect(x, y, w, h, eff_tint, tint_alpha, config.glass_saturation);

    const spec = @as(u32, config.specular_intensity);
    if (spec > 0) {
        const shine_h = @max(2, @divTrunc(h, 3));
        if (shine_h > 1) {
            fb.addSpecularBand(x, y, w, shine_h, spec);
            // Win7 标题栏/面板顶缘高光；任务栏用更柔和的顶线，避免纯白条过曝。
            if (chrome == .taskbar) {
                fb.blendTintRect(x, y, w, 1, rgb(0xD8, 0xEC, 0xFF), 118, 255);
                fb.blendTintRect(x, clampCoordI64(@as(i64, y) + 1), w, 1, rgb(0x88, 0xA8, 0xC8), 45, 255);
            } else {
                fb.drawHLine(x, y, w, rgb(0xFF, 0xFF, 0xFF));
            }
        }
    }

    switch (chrome) {
        .taskbar => {
            fb.drawHLine(x, clampCoordI64(@as(i64, y) + @as(i64, h) - 1), w, rgb(0x08, 0x10, 0x20));
            fb.drawVLine(x, y, h, rgb(0x42, 0x62, 0x86));
            fb.drawVLine(clampCoordI64(@as(i64, x) + @as(i64, w) - 1), y, h, rgb(0x42, 0x62, 0x86));
        },
        .caption => {
            fb.drawHLine(x, clampCoordI64(@as(i64, y) + @as(i64, h) - 1), w, rgb(0x70, 0x90, 0xB8));
        },
        .panel => {
            fb.drawHLine(x, clampCoordI64(@as(i64, y) + @as(i64, h) - 1), w, rgb(0x40, 0x60, 0x88));
            fb.drawVLine(x, y, h, rgb(0x55, 0x75, 0x98));
            fb.drawVLine(clampCoordI64(@as(i64, x) + @as(i64, w) - 1), y, h, rgb(0x55, 0x75, 0x98));
        },
    }
}

pub fn renderShadow(x: i32, y: i32, w: i32, h: i32, size: i32) void {
    if (!config.shadow_enabled) return;
    if (!fb.isInitialized()) return;
    if (size <= 0) return;

    var layer: i32 = 0;
    while (layer < 4) : (layer += 1) {
        const offset = size - layer * 2;
        if (offset <= 0) break;
        const shadow_alpha: u8 = @intCast(@as(u32, @intCast(25 - layer * 5)));
        fb.blendTintRect(
            clampCoordI64(@as(i64, x) + @as(i64, offset)),
            clampCoordI64(@as(i64, y) + @as(i64, offset)),
            w,
            h,
            rgb(0x00, 0x00, 0x00),
            shadow_alpha,
            255,
        );
    }
}

pub fn renderAeroGlassBar(x: i32, y: i32, w: i32, h: i32) void {
    if (!fb.isInitialized()) return;
    const t = theme.getActiveTheme();
    if (isGlassEnabled()) {
        renderGlassEffect(x, y, w, h, config.glass_tint_color, .taskbar);
        fb.drawHLine(x, y, w, t.tray_border);
    } else {
        fb.drawGradientV(x, y, w, h, t.taskbar_top, t.taskbar_bottom);
        fb.drawHLine(x, y, w, t.tray_border);
    }
}

pub fn renderAeroTitlebar(x: i32, y: i32, w: i32, h: i32, is_active: bool) void {
    if (!fb.isInitialized()) return;
    const t = theme.getActiveTheme();
    if (isGlassEnabled() and is_active) {
        renderGlassEffect(x, y, w, h, t.titlebar_active_left, .caption);
    } else if (isGlassEnabled()) {
        renderGlassEffect(x, y, w, h, rgb(0x80, 0x90, 0xA0), .caption);
    } else {
        fb.drawGradientH(x, y, w, h, t.titlebar_active_left, t.titlebar_active_right);
    }
}
