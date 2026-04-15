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

//! ZirconOS Aero Theme Definition (ZirconAero — Windows 7 Aero homage)
//! Glass borders, DWM-style blur, specular highlights, soft shadows,
//! Harmony-style wallpaper palette, taskbar/tray/show-desktop layout.

pub const COLORREF = u32;

/// 与 MS Learn **COLORREF** 低 24 位一致（R 在最低字节）。与内核 `drivers/video/desktop/theme.zig` 的 BGR 打包不同 — 跨边界请用 `src/config/color_nt61.zig`。
pub fn rgb(r: u32, g: u32, b: u32) u32 {
    return r | (g << 8) | (b << 16);
}

pub const RGB = rgb;

pub fn argb(a: u32, r: u32, g: u32, b: u32) u32 {
    return r | (g << 8) | (b << 16) | (a << 24);
}

pub fn alphaBlend(fg: u32, bg: u32, alpha: u8) u32 {
    const a: u32 = @as(u32, alpha);
    const inv_a: u32 = 255 - a;
    const fr = fg & 0xFF;
    const fg_ = (fg >> 8) & 0xFF;
    const fb = (fg >> 16) & 0xFF;
    const br = bg & 0xFF;
    const bg_ = (bg >> 8) & 0xFF;
    const bb = (bg >> 16) & 0xFF;
    const or_ = (fr * a + br * inv_a) / 255;
    const og = (fg_ * a + bg_ * inv_a) / 255;
    const ob = (fb * a + bb * inv_a) / 255;
    return (or_ & 0xFF) | ((og & 0xFF) << 8) | ((ob & 0xFF) << 16);
}

// ── Font Constants (resolved from ZirconOSFonts) ──

pub const FONT_SYSTEM = "Lato";
pub const FONT_SYSTEM_SIZE: i32 = 12;
pub const FONT_MONO = "Source Code Pro";
pub const FONT_MONO_SIZE: i32 = 10;
pub const FONT_CJK = "Noto Sans CJK SC";
pub const FONT_CJK_SIZE: i32 = 12;
pub const FONT_TITLE_SIZE: i32 = 11;

// ── Visual Geometry Constants ──

pub const WINDOW_SHADOW_SIZE: i32 = 8;
pub const TITLEBAR_CORNER_RADIUS: i32 = 6;

// ── Color Schemes ──

pub const ColorScheme = enum {
    zircon_blue,
    zircon_graphite,
    zircon_aurora,
    zircon_characters,
    zircon_nature,
    zircon_scenes,
    zircon_landscapes,
    zircon_architecture,
    highcontrast,
};

pub const SchemeColors = struct {
    glass_tint: u32,
    glass_opacity: u8,
    glass_saturation: u8,
    glass_tint_opacity: u8,
    titlebar_text: u32,
    desktop_bg: u32,
    accent: u32,
};

pub const scheme_blue = SchemeColors{
    .glass_tint = rgb(0x38, 0x62, 0x98),
    .glass_opacity = 210,
    .glass_saturation = 208,
    .glass_tint_opacity = 62,
    .titlebar_text = rgb(0x00, 0x00, 0x00),
    // Harmony-style deep blue (solid fallback when wallpaper not sampled)
    .desktop_bg = rgb(0x12, 0x38, 0x62),
    .accent = rgb(0x3D, 0x8E, 0xD8),
};

pub const scheme_graphite = SchemeColors{
    .glass_tint = rgb(0x60, 0x60, 0x68),
    .glass_opacity = 170,
    .glass_saturation = 140,
    .glass_tint_opacity = 50,
    .titlebar_text = rgb(0xFF, 0xFF, 0xFF),
    .desktop_bg = rgb(0x3A, 0x3A, 0x42),
    .accent = rgb(0x70, 0x70, 0x78),
};

pub const scheme_aurora = SchemeColors{
    .glass_tint = rgb(0x30, 0x80, 0x60),
    .glass_opacity = 175,
    .glass_saturation = 180,
    .glass_tint_opacity = 55,
    .titlebar_text = rgb(0x00, 0x00, 0x00),
    .desktop_bg = rgb(0x1A, 0x4A, 0x38),
    .accent = rgb(0x38, 0x90, 0x6C),
};

pub const scheme_characters = SchemeColors{
    .glass_tint = rgb(0x78, 0x5A, 0x28),
    .glass_opacity = 175,
    .glass_saturation = 160,
    .glass_tint_opacity = 55,
    .titlebar_text = rgb(0xFF, 0xFF, 0xFF),
    .desktop_bg = rgb(0x2A, 0x1E, 0x10),
    .accent = rgb(0xC8, 0x98, 0x30),
};

pub const scheme_nature = SchemeColors{
    .glass_tint = rgb(0x64, 0x3C, 0x80),
    .glass_opacity = 178,
    .glass_saturation = 170,
    .glass_tint_opacity = 58,
    .titlebar_text = rgb(0xFF, 0xFF, 0xFF),
    .desktop_bg = rgb(0x1A, 0x0E, 0x28),
    .accent = rgb(0x88, 0x58, 0xA0),
};

pub const scheme_scenes = SchemeColors{
    .glass_tint = rgb(0x50, 0x28, 0x80),
    .glass_opacity = 180,
    .glass_saturation = 175,
    .glass_tint_opacity = 60,
    .titlebar_text = rgb(0xFF, 0xFF, 0xFF),
    .desktop_bg = rgb(0x1A, 0x10, 0x30),
    .accent = rgb(0x6E, 0x3B, 0xA1),
};

pub const scheme_landscapes = SchemeColors{
    .glass_tint = rgb(0x48, 0x48, 0x48),
    .glass_opacity = 185,
    .glass_saturation = 120,
    .glass_tint_opacity = 65,
    .titlebar_text = rgb(0xFF, 0xFF, 0xFF),
    .desktop_bg = rgb(0x18, 0x18, 0x18),
    .accent = rgb(0x55, 0x55, 0x55),
};

pub const scheme_architecture = SchemeColors{
    .glass_tint = rgb(0x18, 0x30, 0x80),
    .glass_opacity = 180,
    .glass_saturation = 190,
    .glass_tint_opacity = 62,
    .titlebar_text = rgb(0xFF, 0xFF, 0xFF),
    .desktop_bg = rgb(0x0A, 0x08, 0x20),
    .accent = rgb(0x00, 0x46, 0xAD),
};

pub fn getScheme(cs: ColorScheme) SchemeColors {
    return switch (cs) {
        .zircon_blue => scheme_blue,
        .zircon_graphite => scheme_graphite,
        .zircon_aurora => scheme_aurora,
        .zircon_characters => scheme_characters,
        .zircon_nature => scheme_nature,
        .zircon_scenes => scheme_scenes,
        .zircon_landscapes => scheme_landscapes,
        .zircon_architecture => scheme_architecture,
        .highcontrast => scheme_blue,
    };
}

// ── Wallpaper Paths ──

pub const WallpaperPath = struct {
    path: [128]u8 = [_]u8{0} ** 128,
    len: u8 = 0,
};

/// 字体配置
pub const FontConfig = struct {
    system_font: [64]u8 = [_]u8{0} ** 64,
    system_font_size: i32 = 12,
    mono_font: [64]u8 = [_]u8{0} ** 64,
    mono_font_size: i32 = 10,
    cjk_font: [64]u8 = [_]u8{0} ** 64,
    cjk_font_size: i32 = 12,
    title_font_size: i32 = 11,
    menu_font_size: i32 = 12,
    icon_font_size: i32 = 11,
};

/// 主题配置结构体，兼容Windows 7 .theme文件格式
pub const ThemeConfig = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    display_name: [128]u8 = [_]u8{0} ** 128,
    version: [32]u8 = [_]u8{0} ** 32,
    author: [128]u8 = [_]u8{0} ** 128,

    // 颜色配置
    colors: SchemeColors = scheme_blue,

    // 字体配置
    fonts: FontConfig = .{},

    // 壁纸配置
    wallpaper_path: WallpaperPath = .{},
    wallpaper_style: enum { center, tile, stretch, fit, fill } = .stretch,

    // 光标配置
    cursor_scheme: [64]u8 = [_]u8{0} ** 64,

    // 声音配置
    sound_scheme: [64]u8 = [_]u8{0} ** 64,

    // 图标配置
    icon_scheme: [64]u8 = [_]u8{0} ** 64,

    // 高对比度
    is_high_contrast: bool = false,
};

// 全局活动主题配置
var active_theme: ThemeConfig = .{};

pub fn getWallpaperForScheme(cs: ColorScheme) WallpaperPath {
    var wp = WallpaperPath{};
    const src = switch (cs) {
        .zircon_blue => "resources/wallpapers/Landscapes/zircon_harmony.png",
        .zircon_graphite => "resources/wallpapers/Architecture/zircon_crystal.png",
        .zircon_aurora => "resources/wallpapers/Landscapes/zircon_aurora.png",
        .zircon_characters => "resources/wallpapers/Characters/zircon_characters.png",
        .zircon_nature => "resources/wallpapers/Nature/zircon_nature.png",
        .zircon_scenes => "resources/wallpapers/Scenes/zircon_scenes.png",
        .zircon_landscapes => "resources/wallpapers/Landscapes/zircon_landscapes.png",
        .zircon_architecture => "resources/wallpapers/Architecture/zircon_architecture.png",
        .highcontrast => "resources/wallpapers/Nature/zircon_default.png",
    };
    const len = @min(src.len, 128);
    for (0..len) |i| {
        wp.path[i] = src[i];
    }
    wp.len = @intCast(len);
    return wp;
}

// ── Active Theme State ──

var active_scheme: ColorScheme = .zircon_blue;

pub fn setActiveScheme(cs: ColorScheme) void {
    active_scheme = cs;
}

pub fn getActiveScheme() ColorScheme {
    return active_scheme;
}

pub fn getActiveColors() SchemeColors {
    return getScheme(active_scheme);
}

pub fn getActiveDesktopBg() u32 {
    return getScheme(active_scheme).desktop_bg;
}

pub fn getActiveGlassTint() u32 {
    return getScheme(active_scheme).glass_tint;
}

/// 获取是否为深色主题
pub fn isDarkScheme() bool {
    return switch (active_scheme) {
        .zircon_graphite, .zircon_landscapes => true,
        else => false,
    };
}

/// 获取开始菜单背景色（根据主题）
pub fn getStartMenuBg() u32 {
    return if (isDarkScheme()) menu_bg_dark else menu_bg;
}

/// 获取开始菜单右侧背景色
pub fn getStartMenuRightBg() u32 {
    return if (isDarkScheme()) menu_right_bg_dark else menu_right_bg;
}

/// 获取开始菜单文字色
pub fn getStartMenuText() u32 {
    return if (isDarkScheme()) menu_text_dark else menu_text;
}

/// 获取开始菜单悬停背景色
pub fn getStartMenuHoverBg() u32 {
    return if (isDarkScheme()) menu_hover_bg_dark else menu_hover_bg;
}

/// 获取开始菜单分隔线色
pub fn getStartMenuSeparator() u32 {
    return if (isDarkScheme()) menu_separator_dark else menu_separator;
}

// ── Core Aero Palette (Default Blue / Win7 taskbar glass) ──

pub const desktop_bg = rgb(0x12, 0x38, 0x62);

pub const taskbar_glass_tint = rgb(0x22, 0x34, 0x4E);
pub const taskbar_glass_opacity: u8 = 192;
pub const taskbar_top_edge = rgb(0x58, 0x78, 0xA8);
pub const taskbar_bottom = rgb(0x18, 0x26, 0x3A);

pub const start_btn_outer = rgb(0x3D, 0x79, 0xCB);
pub const start_btn_inner = rgb(0x24, 0x56, 0x9D);
pub const start_btn_glow = rgb(0x60, 0xA0, 0xE0);
pub const start_btn_text = rgb(0xFF, 0xFF, 0xFF);
pub const start_label = "Start";

pub const titlebar_glass_tint = rgb(0x41, 0x80, 0xC8);
pub const titlebar_glass_right = rgb(0x6B, 0xA0, 0xD8);
pub const titlebar_text = rgb(0x00, 0x00, 0x00);
pub const titlebar_inactive_tint = rgb(0x80, 0x90, 0xA0);
pub const titlebar_inactive_text = rgb(0x60, 0x60, 0x60);

pub const window_bg = rgb(0xFF, 0xFF, 0xFF);
pub const window_border = rgb(0x50, 0x78, 0xA8);
pub const window_border_inactive = rgb(0x90, 0xA0, 0xB0);

pub const btn_close_top = rgb(0xE0, 0x4B, 0x3A);
pub const btn_close_bottom = rgb(0xC0, 0x30, 0x20);
pub const btn_close_glow = rgb(0xF0, 0x70, 0x60);
pub const btn_minmax_top = rgb(0x40, 0x60, 0x90);
pub const btn_minmax_bottom = rgb(0x30, 0x50, 0x80);

pub const tray_bg = rgb(0x1C, 0x2A, 0x3E);
pub const tray_border = rgb(0x40, 0x58, 0x78);
pub const clock_text = rgb(0xFF, 0xFF, 0xFF);

pub const icon_text = rgb(0xFF, 0xFF, 0xFF);
pub const icon_text_shadow = rgb(0x00, 0x00, 0x00);
pub const icon_selection = rgb(0x33, 0x99, 0xFF);

pub const menu_bg = rgb(0xF5, 0xF5, 0xF5);
pub const menu_right_bg = rgb(0xE8, 0xED, 0xF4);
pub const menu_header_left = rgb(0x40, 0x80, 0xC8);
pub const menu_header_right = rgb(0x60, 0x98, 0xD8);
pub const menu_separator = rgb(0xD8, 0xD8, 0xD8);
pub const menu_text = rgb(0x1A, 0x1A, 0x1A);
pub const menu_hover_bg = rgb(0xD8, 0xE8, 0xF8);
pub const menu_glass_border = rgb(0x40, 0x68, 0xA0);

// 深色模式开始菜单配色
pub const menu_bg_dark = rgb(0x1E, 0x22, 0x28);
pub const menu_right_bg_dark = rgb(0x28, 0x30, 0x38);
pub const menu_header_left_dark = rgb(0x30, 0x50, 0x80);
pub const menu_header_right_dark = rgb(0x40, 0x60, 0x90);
pub const menu_separator_dark = rgb(0x40, 0x48, 0x50);
pub const menu_text_dark = rgb(0xE8, 0xEC, 0xF0);
pub const menu_hover_bg_dark = rgb(0x30, 0x40, 0x50);
pub const menu_glass_border_dark = rgb(0x50, 0x68, 0x90);

pub const search_box_bg = rgb(0xFF, 0xFF, 0xFF);
pub const search_box_border = rgb(0xA0, 0xB0, 0xC0);
pub const search_placeholder = rgb(0xA0, 0xA0, 0xA0);
pub const search_box_bg_dark = rgb(0x2A, 0x30, 0x38);
pub const search_box_border_dark = rgb(0x50, 0x58, 0x60);
pub const search_placeholder_dark = rgb(0x70, 0x78, 0x80);

pub const shutdown_btn_bg = rgb(0xE0, 0x40, 0x30);
pub const shutdown_btn_text = rgb(0xFF, 0xFF, 0xFF);
pub const shutdown_btn_bg_dark = rgb(0xC0, 0x30, 0x20);

pub const login_bg_top = rgb(0x14, 0x32, 0x5A);
pub const login_bg_bottom = rgb(0x0A, 0x1E, 0x38);
pub const login_panel_glass = rgb(0x30, 0x50, 0x80);

pub const button_face = rgb(0xF0, 0xF0, 0xF0);
pub const button_highlight = rgb(0xFF, 0xFF, 0xFF);
pub const button_shadow = rgb(0xA0, 0xA0, 0xA0);
pub const selection_bg = rgb(0x33, 0x99, 0xFF);

// ── DWM Configuration Defaults ──
const nt61_aero = @import("nt61_aero_defaults");

/// 与 `src/config/nt61_aero_defaults.zig` / 内核 `initAeroDwm` 数值一致（单一源）
pub const DwmDefaults = struct {
    pub const glass_enabled: bool = nt61_aero.UserShellDwm.glass_enabled;
    pub const glass_opacity: u8 = nt61_aero.UserShellDwm.glass_opacity;
    pub const blur_radius: u8 = nt61_aero.UserShellDwm.blur_radius;
    pub const blur_passes: u8 = nt61_aero.UserShellDwm.blur_passes;
    pub const glass_saturation: u8 = nt61_aero.UserShellDwm.glass_saturation;
    /// 与内核相同的 u32 打包值（勿用本文件 `rgb()` 重算，避免与帧缓冲路径色差）
    pub const glass_tint_color: u32 = nt61_aero.UserShellDwm.glass_tint_color;
    pub const glass_tint_opacity: u8 = nt61_aero.UserShellDwm.glass_tint_opacity;
    pub const animation_enabled: bool = nt61_aero.UserShellDwm.animation_enabled;
    pub const peek_enabled: bool = nt61_aero.UserShellDwm.peek_enabled;
    pub const shadow_enabled: bool = nt61_aero.UserShellDwm.shadow_enabled;
    pub const shadow_size: u8 = nt61_aero.UserShellDwm.shadow_size;
    pub const shadow_layers: u8 = nt61_aero.UserShellDwm.shadow_layers;
    pub const vsync: bool = nt61_aero.UserShellDwm.vsync;
};

// ── Layout Constants ──
// 高 DPI / 缩放策略见 docs/cn/DpiDesktop.md（当前为参考分辨率下像素常量）。

pub const Layout = struct {
    pub const taskbar_height: i32 = 40;
    pub const titlebar_height: i32 = 26;
    /// 左槽宽度（与内核 `display.aeroTaskbarStartOrb` 的 `slot_w` 一致）
    pub const start_btn_width: i32 = 48;
    pub const start_btn_orb_size: i32 = 30;
    /// Aero Peek strip at the far right (click/hover → show desktop)
    pub const show_desktop_peek_width: i32 = 14;
    /// Notification area: clock column (time + stacked date)
    pub const tray_clock_width: i32 = 76;
    /// Chevron width for "show hidden icons"
    pub const tray_hidden_icons_width: i32 = 18;
    pub const icon_size: i32 = 48;
    pub const icon_grid_x: i32 = 80;
    pub const icon_grid_y: i32 = 90;
    pub const window_border_width: i32 = 4;
    pub const corner_radius: i32 = 6;
    pub const btn_size: i32 = 21;
    pub const tray_height: i32 = 24;
    pub const startmenu_width: i32 = 380;
    pub const startmenu_height: i32 = 420;
    /// Floating CPU / network meter (default position for 1024×768-class)
    pub const gadget_cpu_radius: i32 = 52;
    pub const gadget_cpu_default_x: i32 = 900;
    pub const gadget_cpu_default_y: i32 = 200;
};

// ── Compositor Helper Functions ──
// Used by renderer.zig and compositor.zig for DWM pipeline queries.

pub fn isGlassEnabled() bool {
    return DwmDefaults.glass_enabled;
}

pub fn getGlassAlpha() u8 {
    return getActiveColors().glass_opacity;
}

pub fn getBlurRadius() i32 {
    return @as(i32, DwmDefaults.blur_radius);
}

pub const ThemeColors = struct {
    desktop_background: u32,
    window_border_active: u32,
    window_border_inactive: u32,
    button_highlight: u32,
    button_shadow: u32,
    titlebar_active_top: u32,
    titlebar_active_bottom: u32,
    titlebar_text: u32,
};

pub fn getColors() ThemeColors {
    const sc = getActiveColors();
    return .{
        .desktop_background = sc.desktop_bg,
        .window_border_active = window_border,
        .window_border_inactive = window_border_inactive,
        .button_highlight = button_highlight,
        .button_shadow = button_shadow,
        .titlebar_active_top = titlebar_glass_tint,
        .titlebar_active_bottom = titlebar_glass_right,
        .titlebar_text = sc.titlebar_text,
    };
}

pub const GlassParams = struct {
    blur_radius: u8,
    tint_color: u32,
    tint_opacity: u8,
};

pub fn getGlassParams() GlassParams {
    const sc = getActiveColors();
    return .{
        .blur_radius = DwmDefaults.blur_radius,
        .tint_color = sc.glass_tint,
        .tint_opacity = sc.glass_tint_opacity,
    };
}

// ── Theme System Management ──

/// 初始化主题系统
pub fn init() void {
    // 设置默认字体
    @memcpy(&active_theme.fonts.system_font, FONT_SYSTEM);
    active_theme.fonts.system_font_size = FONT_SYSTEM_SIZE;
    @memcpy(&active_theme.fonts.mono_font, FONT_MONO);
    active_theme.fonts.mono_font_size = FONT_MONO_SIZE;
    @memcpy(&active_theme.fonts.cjk_font, FONT_CJK);
    active_theme.fonts.cjk_font_size = FONT_CJK_SIZE;
    active_theme.fonts.title_font_size = FONT_TITLE_SIZE;
    active_theme.fonts.menu_font_size = FONT_SYSTEM_SIZE;
    active_theme.fonts.icon_font_size = FONT_TITLE_SIZE;

    // 设置默认配色方案
    active_theme.colors = scheme_blue;

    // 默认壁纸
    active_theme.wallpaper_path = getWallpaperForScheme(.zircon_blue);

    // 默认主题名称
    const default_name = "Zircon Aero Blue";
    @memcpy(&active_theme.name, default_name);
    @memcpy(&active_theme.display_name, default_name);
}

/// 获取当前活动主题
pub fn getActiveTheme() *const ThemeConfig {
    return &active_theme;
}

/// 设置玻璃颜色
pub fn setGlassTint(color: u32) void {
    active_theme.colors.glass_tint = color;
    // 同步更新活动配色方案
    var sc = getScheme(active_scheme);
    sc.glass_tint = color;
    // 这里需要更新全局配色，后面实现
}

/// 设置玻璃透明度
pub fn setGlassOpacity(opacity: u8) void {
    active_theme.colors.glass_opacity = opacity;
}

/// 设置玻璃饱和度
pub fn setGlassSaturation(saturation: u8) void {
    active_theme.colors.glass_saturation = saturation;
}

/// 设置玻璃色调透明度
pub fn setGlassTintOpacity(opacity: u8) void {
    active_theme.colors.glass_tint_opacity = opacity;
}

/// 获取字体配置
pub fn getFontConfig() *const FontConfig {
    return &active_theme.fonts;
}

/// 设置系统字体
pub fn setSystemFont(name: []const u8, size: i32) void {
    const len = @min(name.len, 63);
    @memcpy(&active_theme.fonts.system_font[0..len], name[0..len]);
    active_theme.fonts.system_font[len] = 0;
    active_theme.fonts.system_font_size = size;
}

/// 设置标题字体大小
pub fn setTitleFontSize(size: i32) void {
    active_theme.fonts.title_font_size = size;
}

/// 设置菜单字体大小
pub fn setMenuFontSize(size: i32) void {
    active_theme.fonts.menu_font_size = size;
}

/// 设置图标字体大小
pub fn setIconFontSize(size: i32) void {
    active_theme.fonts.icon_font_size = size;
}

/// 应用主题更改，通知所有组件刷新
pub fn applyTheme() void {
    // 这里后续需要实现通知渲染器、窗口管理器等组件刷新
    // 包括重新渲染所有窗口、更新桌面背景等
}

/// 导出主题到文件
pub fn exportTheme(path: []const u8) bool {
    // 后续实现.theme文件导出功能
    // 兼容Windows 7 INI格式的.theme文件
    _ = path;
    return false;
}

/// 从文件加载主题
pub fn loadTheme(path: []const u8) bool {
    // 后续实现.theme文件解析功能
    // 支持Windows 7格式的主题文件读取
    _ = path;
    return false;
}

/// 设置为高对比度主题
pub fn setHighContrast(enable: bool) void {
    active_theme.is_high_contrast = enable;
    if (enable) {
        // 应用高对比度配色
        active_scheme = .highcontrast;
        // 高对比度下强制玻璃不透明，文字黑白分明
        active_theme.colors.glass_opacity = 255;
        active_theme.colors.glass_tint_opacity = 255;
    } else {
        // 恢复默认蓝色主题
        active_scheme = .zircon_blue;
        active_theme.colors = scheme_blue;
    }
    applyTheme();
}

/// 是否为高对比度主题
pub fn isHighContrast() bool {
    return active_theme.is_high_contrast;
}

/// 颜色混合函数，用于动态调整主题颜色
pub fn blendColors(fg: u32, bg: u32, amount: f32) u32 {
    const fr = fg & 0xFF;
    const fg_ = (fg >> 8) & 0xFF;
    const fb = (fg >> 16) & 0xFF;
    const br = bg & 0xFF;
    const bg_ = (bg >> 8) & 0xFF;
    const bb = (bg >> 16) & 0xFF;

    const r = @as(u32, @intFromFloat(@as(f32, @floatFromInt(br)) * (1.0 - amount) + @as(f32, @floatFromInt(fr)) * amount));
    const g = @as(u32, @intFromFloat(@as(f32, @floatFromInt(bg_)) * (1.0 - amount) + @as(f32, @floatFromInt(fg_)) * amount));
    const b = @as(u32, @intFromFloat(@as(f32, @floatFromInt(bb)) * (1.0 - amount) + @as(f32, @floatFromInt(fb)) * amount));

    return rgb(r & 0xFF, g & 0xFF, b & 0xFF);
}

/// 从图片采样颜色生成主题（类似Windows 7自动颜色功能）
pub fn generateThemeFromWallpaper(wallpaper_path: []const u8) void {
    // 后续实现从壁纸采样主色自动生成主题配色功能
    _ = wallpaper_path;
}
