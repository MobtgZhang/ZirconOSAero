//! NT 6.1 Aero 默认参数 — **唯一数值源**（与 `docs/cn/AeroRendering.md`、`docs/cn/DesktopManagerSpec.md` 一致）。
//! 内核帧缓冲路径（`src/drivers/video/`）与用户态 Aero 库（`src/desktop/aero/`）均应通过本模块引用，
//! 避免 `initAeroDwm` 与 `theme.DwmDefaults` 漂移。
//!
//! 注意：`src/drivers/video/theme.zig` 的 `rgb()` 为 **低字节=B、中=G、高字节=R**（`b|(g<<8)|(r<<16)`），
//! 与 Win32 `COLORREF`/本内核帧缓冲一致；`src/desktop/aero/src/theme.zig` 的 `rgb()` 为 `r|(g<<8)|(b<<16)`，二者字节序相反。
//! `glass_tint_color` 此处为内核侧 **u32 字面值**（与 `dwm.zig` / `theme.rgb` 一致）；勿直接复制到 Aero 库主题常量而不换算。

/// 内核 `dwm.zig` / `display.initAeroDwm` / `renderer_aero.initDwm` 使用的玻璃与行为开关
pub const KernelDwm = struct {
    pub const glass_enabled = true;
    pub const glass_opacity: u8 = 210;
    pub const glass_blur_radius: u8 = 6;
    pub const glass_blur_passes: u8 = 2;
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
};

/// 内核 `dwm_compositor.zig`（重定向表面 / 元数据）
pub const KernelCompositor = struct {
    pub const shadow_layers: u8 = 3;
    pub const shadow_offset: u8 = 6;
    pub const peek_enabled = true;
    pub const flip3d_enabled = true;
    pub const animation_speed: u16 = 250;
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
