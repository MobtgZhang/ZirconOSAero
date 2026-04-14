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

//! ZirconOSAero — NT 6.1 风格 Aero 桌面合成默认参数 — **唯一数值源**（与 `docs/cn/AeroRendering.md`、`docs/cn/DesktopManagerSpec.md` 一致）。
//! 内核帧缓冲路径（`src/drivers/video/`）与用户态 Aero 库（`src/desktop/aero/`）均应通过本模块引用，
//! 避免 `initAeroDwm` 与 `theme.DwmDefaults` 漂移。（对外 ABI 对齐目标为 NT 6.1 档公开行为描述。）
//!
//! 注意：`src/desktop/kernel/theme/theme.zig` 的 `rgb()` 为 **低字节=B、中=G、高字节=R**（`b|(g<<8)|(r<<16)`），
//! 与 Win32 `COLORREF`/本内核帧缓冲一致；`src/desktop/aero/src/theme.zig` 的 `rgb()` 为 `r|(g<<8)|(b<<16)`，二者字节序相反。
//! `glass_tint_color` 此处为内核侧 **u32 字面值**（与 `dwm.zig` / `theme.rgb` 一致）；勿直接复制到 Aero 库主题常量而不换算。

/// 合成参数表版本：内核 `display` 与用户态 `desktop/aero` 变更默认时应 bump，便于检测双轨漂移（DesktopManagerSpec）。
///
/// **阶段 D0**：与 `dwm_nt61_api_contract.zig`（`WM_DWM*`、Flip3D shell cap）的数值对齐由主机测 `dwm_nt61_integration_host` / `dwm_messages_nt61` 锚定；本文件**不** `@import` 该模块，避免与 `nt61_aero_defaults` 作为独立 module root 时 Zig 0.15「单文件仅属一 module」冲突。
pub const compositor_config_epoch: u32 = 4;

/// 内核 `dwm.zig` / `display.initAeroDwm` / `renderer_aero.initDwm` 使用的玻璃与行为开关
pub const KernelDwm = struct {
    /// 桌面合成器「开启」（与 Aero 玻璃材质 `glass_enabled` 分离；`WM_DWMCOMPOSITIONCHANGED` 仅随此项变化）。
    pub const composition_enabled = true;
    pub const glass_enabled = true;
    pub const glass_opacity: u8 = 210;
    pub const glass_blur_radius: u8 = 7;
    pub const glass_blur_passes: u8 = 3;
    pub const glass_saturation: u8 = 208;
    pub const glass_tint_color: u32 = 0x4068A0;
    pub const glass_tint_opacity: u8 = 62;
    pub const glass_taskbar_tint_opacity: u8 = 88;
    pub const specular_intensity: u8 = 42;
    pub const animation_enabled = true;
    pub const peek_enabled = true;
    pub const shadow_enabled = true;
    pub const vsync_compositor = true;
    pub const smooth_cursor = true;
    pub const cursor_lerp_factor: i32 = 255;
    /// 每帧盒式模糊「像素·遍」近似预算（宽×高×pass 累加超过则跳过后续 blur，保留 tint/高光）。
    /// 略低于 12M：高分辨率下减轻壳层交互与全帧叠加之 CPU 占用（仍优先 tint/高光）。
    pub const blur_budget_pixel_passes_per_frame: u32 = 10_000_000;
    /// 0 = 不限制；否则任务栏 `boxBlur` 半径上限（减轻全宽条带成本）。
    pub const taskbar_blur_radius_cap: u8 = 5;
    /// 单块 `boxBlurRect` 面积超过则跳过该次模糊（防全屏条带拖死主循环）。
    pub const blur_max_single_rect_pixels: u32 = 320_000;
    /// 每帧最多执行多少次 `boxBlurRect`（与面积上限叠加）。
    pub const blur_max_rect_calls_per_frame: u32 = 12;
    /// 帧像素数 ≥ 此阈值时下调半径/遍数（如 1280×720）。
    pub const blur_resolution_downgrade_pixel_threshold: u32 = 921_600;
    pub const glass_blur_radius_hd_cap: u8 = 5;
    pub const glass_blur_passes_hd_cap: u8 = 2;
    /// LoongArch / QEMU 下 CPU 盒式模糊成本更高，启动后再由 `dwm.applyPlatformAndResolutionTuning` 收紧。
    pub const glass_blur_radius_loongarch_cap: u8 = 4;
    pub const glass_blur_passes_loongarch_cap: u8 = 2;
};

/// 内核 `dwm_compositor.zig`（重定向表面 / 元数据）
pub const KernelCompositor = struct {
    pub const shadow_layers: u8 = 3;
    pub const shadow_offset: u8 = 6;
    pub const peek_enabled = true;
    pub const flip3d_enabled = true;
    pub const animation_speed: u16 = 250;
    /// Aero Snap / 贴靠壳策略总开关（与 `dwm_surface_spec.KernelCompositorSurfaceFlags.snap_target` 配对）。
    pub const snap_shell_enabled = true;
};

/// 用户 Aero `theme.DwmDefaults` — 数值与 `KernelDwm` 对齐（命名沿用 Shell 侧习惯）
pub const UserShellDwm = struct {
    pub const glass_enabled = KernelDwm.glass_enabled;
    pub const glass_opacity = KernelDwm.glass_opacity;
    pub const blur_radius = KernelDwm.glass_blur_radius;
    pub const blur_passes = KernelDwm.glass_blur_passes;
    pub const glass_saturation = KernelDwm.glass_saturation;
    pub const glass_tint_color = KernelDwm.glass_tint_color;
    pub const glass_tint_opacity = KernelDwm.glass_tint_opacity;
    pub const animation_enabled = KernelDwm.animation_enabled;
    pub const peek_enabled = KernelDwm.peek_enabled;
    pub const shadow_enabled = KernelDwm.shadow_enabled;
    pub const shadow_size = KernelCompositor.shadow_offset;
    pub const shadow_layers = KernelCompositor.shadow_layers;
    pub const vsync = KernelDwm.vsync_compositor;
};

const std = @import("std");
comptime {
    // UserShellDwm ↔ KernelDwm / KernelCompositor：凡应对齐的字段全部编译期锁（改一侧须同步另一侧并 bump compositor_config_epoch）。
    std.debug.assert(UserShellDwm.glass_enabled == KernelDwm.glass_enabled);
    std.debug.assert(UserShellDwm.glass_opacity == KernelDwm.glass_opacity);
    std.debug.assert(UserShellDwm.blur_radius == KernelDwm.glass_blur_radius);
    std.debug.assert(UserShellDwm.blur_passes == KernelDwm.glass_blur_passes);
    std.debug.assert(UserShellDwm.glass_saturation == KernelDwm.glass_saturation);
    std.debug.assert(UserShellDwm.glass_tint_color == KernelDwm.glass_tint_color);
    std.debug.assert(UserShellDwm.glass_tint_opacity == KernelDwm.glass_tint_opacity);
    std.debug.assert(UserShellDwm.animation_enabled == KernelDwm.animation_enabled);
    std.debug.assert(UserShellDwm.peek_enabled == KernelDwm.peek_enabled);
    std.debug.assert(UserShellDwm.shadow_enabled == KernelDwm.shadow_enabled);
    std.debug.assert(UserShellDwm.vsync == KernelDwm.vsync_compositor);
    std.debug.assert(UserShellDwm.shadow_size == KernelCompositor.shadow_offset);
    std.debug.assert(UserShellDwm.shadow_layers == KernelCompositor.shadow_layers);
}

test "KernelDwm CPU blur budget constants are usable" {
    try std.testing.expect(KernelDwm.blur_budget_pixel_passes_per_frame > 0);
    try std.testing.expect(KernelDwm.blur_max_rect_calls_per_frame > 0);
    try std.testing.expect(KernelDwm.blur_max_single_rect_pixels > 0);
    try std.testing.expect(KernelCompositor.snap_shell_enabled);
}
