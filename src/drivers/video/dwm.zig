//! Desktop Window Manager (DWM) compositor configuration and glass effects.
//!
//! Provides the Aero Glass pipeline: backdrop sample → blur → tint blend →
//! specular highlight → chrome decoration. Also used by Fluent (Acrylic)
//! and Sun Valley (Mica) renderers for their material effects.
//!
//! ideas/Win7B.md：合成循环在「提交帧」前应尽快产出可显示内容。首帧可跳过盒式模糊
//! （仍保留 tint + 高光），在首次 `present()` 之后再跑全量模糊，避免双缓冲下长时间黑屏。

const fb = @import("framebuffer.zig");
const theme = @import("theme.zig");
const nt61 = @import("dwm_nt61_defaults");
const rgb = theme.rgb;

pub const DwmConfig = struct {
    glass_enabled: bool = nt61.KernelDwm.glass_enabled,
    glass_opacity: u8 = nt61.KernelDwm.glass_opacity,
    /// 与 docs/cn/AeroRendering.md、`dwm_nt61_defaults` 一致（标题栏/面板盒式模糊）
    glass_blur_radius: u8 = nt61.KernelDwm.glass_blur_radius,
    glass_blur_passes: u8 = nt61.KernelDwm.glass_blur_passes,
    glass_saturation: u8 = nt61.KernelDwm.glass_saturation,
    glass_tint_color: u32 = nt61.KernelDwm.glass_tint_color,
    glass_tint_opacity: u8 = nt61.KernelDwm.glass_tint_opacity,
    /// 任务栏略低于窗口标题栏的不透明度，更易透出 Harmony 壁纸（Win7 任务栏偏「实」仍保留）
    glass_taskbar_tint_opacity: u8 = nt61.KernelDwm.glass_taskbar_tint_opacity,
    specular_intensity: u8 = nt61.KernelDwm.specular_intensity,
    animation_enabled: bool = nt61.KernelDwm.animation_enabled,
    peek_enabled: bool = nt61.KernelDwm.peek_enabled,
    shadow_enabled: bool = nt61.KernelDwm.shadow_enabled,
    vsync_compositor: bool = nt61.KernelDwm.vsync_compositor,
    smooth_cursor: bool = nt61.KernelDwm.smooth_cursor,
    cursor_lerp_factor: i32 = nt61.KernelDwm.cursor_lerp_factor,
};

pub const GlassChrome = enum { taskbar, caption, panel };

var config: DwmConfig = .{};
var initialized: bool = false;

/// 由 display 在绘制前设置：首帧（尚未 present）为 true，跳过 `boxBlurRect`。
var skip_glass_box_blur: bool = false;

pub fn setSkipGlassBoxBlur(skip: bool) void {
    skip_glass_box_blur = skip;
}

pub fn shouldSkipGlassBoxBlur() bool {
    return skip_glass_box_blur;
}

pub fn init(cfg: DwmConfig) void {
    config = cfg;
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
    config.glass_enabled = enabled;
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

pub fn renderGlassEffect(x: i32, y: i32, w: i32, h: i32, tint: u32, chrome: GlassChrome) void {
    if (!fb.isInitialized()) return;
    if (!config.glass_enabled) {
        fb.fillRect(x, y, w, h, if (tint != 0) tint else config.glass_tint_color);
        return;
    }

    const eff_tint = if (tint != 0) tint else config.glass_tint_color;
    const blur_r = @as(u32, config.glass_blur_radius);
    const passes = @as(u32, config.glass_blur_passes);
    const tint_alpha: u8 = switch (chrome) {
        .taskbar => config.glass_taskbar_tint_opacity,
        else => config.glass_tint_opacity,
    };

    // win7Desktop.md §4：标题栏/面板用多遍盒式模糊；任务栏薄但宽，三遍小半径 ≈ 更强磨砂感。
    if (!skip_glass_box_blur and blur_r > 0 and passes > 0) {
        if (chrome == .taskbar) {
            const tr = @min(blur_r, @as(u32, 6));
            fb.boxBlurRect(x, y, w, h, tr, 1);
            if (tr > 1) {
                fb.boxBlurRect(x, y, w, h, @max(2, tr * 2 / 3), 1);
            }
            fb.boxBlurRect(x, y, w, h, 2, 1);
        } else {
            fb.boxBlurRect(x, y, w, h, blur_r, if (passes < 1) 1 else passes);
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
                fb.blendTintRect(x, y + 1, w, 1, rgb(0x88, 0xA8, 0xC8), 45, 255);
            } else {
                fb.drawHLine(x, y, w, rgb(0xFF, 0xFF, 0xFF));
            }
        }
    }

    switch (chrome) {
        .taskbar => {
            fb.drawHLine(x, y + h - 1, w, rgb(0x08, 0x10, 0x20));
            fb.drawVLine(x, y, h, rgb(0x42, 0x62, 0x86));
            fb.drawVLine(x + w - 1, y, h, rgb(0x42, 0x62, 0x86));
        },
        .caption => {
            fb.drawHLine(x, y + h - 1, w, rgb(0x70, 0x90, 0xB8));
        },
        .panel => {
            fb.drawHLine(x, y + h - 1, w, rgb(0x40, 0x60, 0x88));
            fb.drawVLine(x, y, h, rgb(0x55, 0x75, 0x98));
            fb.drawVLine(x + w - 1, y, h, rgb(0x55, 0x75, 0x98));
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
        fb.blendTintRect(x + offset, y + offset, w, h, rgb(0x00, 0x00, 0x00), shadow_alpha, 255);
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
