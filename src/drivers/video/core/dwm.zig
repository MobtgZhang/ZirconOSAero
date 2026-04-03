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
//!
//! ## `DwmConfig` 变更路径与 `WM_DWM*` 广播（问题二闭合）
//! - **写入 `config`（应用可见语义）**：`init`、`applyPlatformAndResolutionTuning`（模糊半径/遍数上限）、
//!   `syncPolicyFromRegistry`、`setColorizationTint`、`setGlass`、`setCompositionEnabled`。
//! - **不写入 `DwmConfig`（实现细节，不广播）**：`setSkipGlassBoxBlur`、`setGlassLiteBlurEnabled`、帧内 `blur_budget_*`。
//! - **广播决策表**（须广播 / 启动豁免）：见 [docs/cn/DWM_NOTIFY_MODEL_NT61.md](../../docs/cn/DWM_NOTIFY_MODEL_NT61.md) §「广播策略决策表」。

const std = @import("std");
const fb = @import("framebuffer.zig");
const theme = @import("../desktop/theme.zig");
const nt61_aero = @import("nt61_aero_defaults");
const color_nt61 = @import("../../../config/color_nt61.zig");
const dwm_blur_budget = @import("../../../config/dwm_blur_budget.zig");
const virtio_gpu_pci = @import("../virtio/virtio_gpu_pci.zig");
const dwm_registry_sync = @import("../../../config/dwm_config_registry_sync.zig");
const rgb = theme.rgb;

/// 与 `nt61_aero_defaults.compositor_config_epoch` 一致；`display` 等仅通过本模块读取，避免重复依赖 `nt61_aero_defaults` 模块。
pub const compositor_config_epoch: u32 = nt61_aero.compositor_config_epoch;

fn clampCoordI64(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

pub const DwmConfig = struct {
    /// 桌面合成总开关（与毛玻璃 `glass_enabled` 分离；见 Learn「Desktop Window Manager」概述）。
    composition_enabled: bool = nt61_aero.KernelDwm.composition_enabled,
    glass_enabled: bool = nt61_aero.KernelDwm.glass_enabled,
    glass_opacity: u8 = nt61_aero.KernelDwm.glass_opacity,
    /// 与 docs/cn/AeroRendering.md、`nt61_aero_defaults` 一致（标题栏/面板盒式模糊）
    glass_blur_radius: u8 = nt61_aero.KernelDwm.glass_blur_radius,
    glass_blur_passes: u8 = nt61_aero.KernelDwm.glass_blur_passes,
    glass_saturation: u8 = nt61_aero.KernelDwm.glass_saturation,
    glass_tint_color: color_nt61.KernelBgr888Low24 = nt61_aero.KernelDwm.glass_tint_color,
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
/// `-Ddwm_blur_stats=true`：本帧计数，在 `flushBlurFrameStatsDebug` 打一行 `klog.debug` 后仍保留末帧值供诊断。
var blur_frame_box_blur_calls: u32 = 0;
var blur_frame_budget_denials: u32 = 0;
var blur_frame_tint_only_calls: u32 = 0;

fn blurStatsEnabled() bool {
    return @import("build_options").dwm_blur_stats;
}

pub fn beginFrameBlurBudget() void {
    blur_budget_pixel_passes = nt61_aero.KernelDwm.blur_budget_pixel_passes_per_frame;
    blur_rect_calls_remaining = nt61_aero.KernelDwm.blur_max_rect_calls_per_frame;
    blur_frame_box_blur_calls = 0;
    blur_frame_budget_denials = 0;
    blur_frame_tint_only_calls = 0;
}

/// 每帧末尾调用（如 `display.renderDesktopFrameEx`）：`-Ddwm_blur_stats=true` 时输出本帧盒式模糊调用次数、预算拒绝次数、`renderGlassTintOnly` 次数。
pub fn flushBlurFrameStatsDebug() void {
    if (!blurStatsEnabled()) return;
    const klog = @import("../../../rtl/klog.zig");
    klog.debug("dwm blur frame: box_blur_calls=%u budget_denials=%u tint_only_calls=%u", .{
        blur_frame_box_blur_calls,
        blur_frame_budget_denials,
        blur_frame_tint_only_calls,
    });
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
    return dwm_blur_budget.trySubtractFromBudget(&blur_budget_pixel_passes, w, h, passes);
}

fn boxBlurRectBudgeted(x: i32, y: i32, w: i32, h: i32, radius: u32, passes: u32) void {
    if (virtio_gpu_pci.tryVirglBlurBoxDelegation(x, y, w, h, radius, passes)) return;
    if (w <= 0 or h <= 0 or radius == 0 or passes == 0) return;
    if (blur_rect_calls_remaining == 0) return;
    const area64 = @as(u64, @intCast(w)) *% @as(u64, @intCast(h));
    if (area64 > nt61_aero.KernelDwm.blur_max_single_rect_pixels) return;
    if (!tryConsumeBlurBudget(w, h, passes)) {
        if (blurStatsEnabled()) blur_frame_budget_denials += 1;
        return;
    }
    blur_rect_calls_remaining -= 1;
    if (blurStatsEnabled()) blur_frame_box_blur_calls += 1;
    fb.boxBlurRect(x, y, w, h, radius, passes);
}

/// 首帧快路径等：为 true 时跳过盒式模糊（仍可走 `renderGlassTintOnly`）。与 `setGlassLiteBlurEnabled` 关联合成策略见 `SOFTWARE_COMPOSITOR_WDDM.md`；**不**单独扣减 `blur_budget`，扣减仅在 `boxBlurRect` 内发生。
pub fn setSkipGlassBoxBlur(skip: bool) void {
    skip_glass_box_blur = skip;
}

pub fn shouldSkipGlassBoxBlur() bool {
    return skip_glass_box_blur;
}

/// 壳层/拖窗等轻量模糊路径开关；与 `display.renderDesktopFrameEx` + `syncAeroGlassFastPath` 组合使用，**后写者优先**。
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

/// 对齐「合成是否启用」语义（`DwmIsCompositionEnabled` 类契约）；毛玻璃见 `isGlassEnabled`。
pub fn isEnabled() bool {
    return initialized and config.composition_enabled;
}

pub fn getConfig() *const DwmConfig {
    return &config;
}

/// 从 `HKLM\SOFTWARE\Microsoft\Windows\DWM` 读常见 DWORD（与 Shell 文档化键名对齐）；未知或缺失则静默跳过。
/// 与 `registry.populateDefaults` 播种对齐的键：`AccentColor`、`ColorizationColor`、`ColorizationOpaqueBlend`、
/// `ColorPrevalence`、`EnableAeroPeek`、`Composition`（合成总开关）、`ColorizationGlass`（毛玻璃）。
///
/// **有 HWND 后的差异广播**：同步前后对 `dwm_registry_sync.RegistryVisibleDwmFields` 做快照；若
/// `user32.getWindowCount() > 0` 且字段相对变化，则按 [DWM_NOTIFY_MODEL_NT61.md](../../docs/cn/DWM_NOTIFY_MODEL_NT61.md)
/// 补发 `WM_DWMCOLORIZATIONCOLORCHANGED` / `WM_DWMNCRENDERINGCHANGED`（无变化则不投递，避免重复泵）。
/// **启动豁免**：尚无有效窗口时不广播（桌面 `enterDesktopSession` 在首窗创建前后可能多次调用本函数）。
pub fn syncPolicyFromRegistry() void {
    if (!initialized) return;
    const reg = @import("../../../registry/registry.zig");
    const k = reg.hklm_dwm_key orelse return;
    const before = dwm_registry_sync.snapshotFromDwmConfig(config);
    if (reg.queryValueDword(k, "AccentColor")) |ac| {
        config.glass_tint_color = color_nt61.kernelDwmTintFromColorrefLow24(ac);
    }
    if (reg.queryValueDword(k, "ColorizationColor")) |cc| {
        config.glass_tint_color = color_nt61.kernelDwmTintFromColorrefLow24(cc);
    }
    if (reg.queryValueDword(k, "ColorizationOpaqueBlend")) |oob| {
        if (oob != 0) {
            config.glass_opacity = @min(255, config.glass_opacity +| 32);
        }
    }
    if (reg.queryValueDword(k, "ColorPrevalence")) |cp| {
        if (cp != 0) {
            config.glass_taskbar_tint_opacity = @min(255, config.glass_taskbar_tint_opacity +| 16);
        }
    }
    if (reg.queryValueDword(k, "EnableAeroPeek")) |peek| {
        config.peek_enabled = (peek != 0);
    }
    if (reg.queryValueDword(k, "Composition")) |comp| {
        config.composition_enabled = (comp != 0);
    }
    if (reg.queryValueDword(k, "ColorizationGlass")) |gl| {
        config.glass_enabled = (gl != 0);
    }

    const after = dwm_registry_sync.snapshotFromDwmConfig(config);
    const hints = dwm_registry_sync.broadcastHintsAfterRegistryApply(before, after);
    if (!hints.colorization and !hints.nc_policy and !hints.composition) return;

    const user32 = @import("../../../subsystems/win32/user32.zig");
    if (user32.getWindowCount() == 0) return;

    if (hints.composition) {
        user32.broadcastDwmCompositionChanged(if (config.composition_enabled) user32.TRUE else user32.FALSE);
    }
    if (hints.colorization) {
        const cref = color_nt61.colorrefLow24FromKernelBgr24(config.glass_tint_color);
        user32.broadcastDwmColorizationChanged(cref, user32.TRUE);
    }
    if (hints.nc_policy) {
        user32.broadcastDwmNcRenderingChanged(user32.TRUE);
    }
}

/// 更新染色并广播 `WM_DWMCOLORIZATIONCOLORCHANGED`（`colorref_low24` 与 Learn 中 COLORREF 低 24 位一致）。
pub fn setColorizationTint(colorref_low24: color_nt61.ColorrefLow24, blend_enabled: bool) void {
    if (!initialized) return;
    config.glass_tint_color = color_nt61.kernelDwmTintFromColorrefLow24(colorref_low24);
    const user32 = @import("../../../subsystems/win32/user32.zig");
    user32.broadcastDwmColorizationChanged(colorref_low24, if (blend_enabled) user32.TRUE else user32.FALSE);
}

pub fn setGlass(enabled: bool) void {
    if (config.glass_enabled == enabled) return;
    config.glass_enabled = enabled;
    const user32 = @import("../../../subsystems/win32/user32.zig");
    // 毛玻璃/非客户区绘制策略变化；`WM_DWMCOMPOSITIONCHANGED` 仅随 `composition_enabled` 变化（见 `setCompositionEnabled`）。
    user32.broadcastDwmNcRenderingChanged(user32.TRUE);
}

/// 合成总开关变化时广播 `WM_DWMCOMPOSITIONCHANGED`（与 `glass_enabled` 独立）。
pub fn setCompositionEnabled(enabled: bool) void {
    if (config.composition_enabled == enabled) return;
    config.composition_enabled = enabled;
    const user32 = @import("../../../subsystems/win32/user32.zig");
    user32.broadcastDwmCompositionChanged(if (enabled) user32.TRUE else user32.FALSE);
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
pub fn renderGlassTintOnly(x: i32, y: i32, w: i32, h: i32, tint: color_nt61.KernelBgr888Low24, chrome: GlassChrome) void {
    if (blurStatsEnabled()) blur_frame_tint_only_calls += 1;
    renderGlassEffectInternal(x, y, w, h, tint, chrome, true);
}

pub fn renderGlassEffect(x: i32, y: i32, w: i32, h: i32, tint: color_nt61.KernelBgr888Low24, chrome: GlassChrome) void {
    renderGlassEffectInternal(x, y, w, h, tint, chrome, false);
}

fn renderGlassEffectInternal(x: i32, y: i32, w: i32, h: i32, tint: color_nt61.KernelBgr888Low24, chrome: GlassChrome, skip_box_blur: bool) void {
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
        const shine_h: i32 = if (h <= 0) 0 else @max(2, @as(i32, @intCast(@divTrunc(@as(i64, h), 3))));
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
