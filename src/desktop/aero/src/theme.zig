//! ZirconOS Aero Theme Definition (ZirconAero — Windows 7 Aero homage)
//! Glass borders, DWM-style blur, specular highlights, soft shadows,
//! Harmony-style wallpaper palette, taskbar/tray/show-desktop layout.

pub const COLORREF = u32;

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
    .glass_opacity = 188,
    .glass_saturation = 205,
    .glass_tint_opacity = 58,
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

pub fn getWallpaperForScheme(cs: ColorScheme) WallpaperPath {
    var wp = WallpaperPath{};
    const src = switch (cs) {
        .zircon_blue => "resources/wallpapers/zircon_harmony_win7.svg",
        .zircon_graphite => "resources/wallpapers/zircon_crystal.svg",
        .zircon_aurora => "resources/wallpapers/zircon_aurora.svg",
        .zircon_characters => "resources/wallpapers/zircon_characters.svg",
        .zircon_nature => "resources/wallpapers/zircon_nature.svg",
        .zircon_scenes => "resources/wallpapers/zircon_scenes.svg",
        .zircon_landscapes => "resources/wallpapers/zircon_landscapes.svg",
        .zircon_architecture => "resources/wallpapers/zircon_architecture.svg",
        .highcontrast => "resources/wallpapers/zircon_default.svg",
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

pub const search_box_bg = rgb(0xFF, 0xFF, 0xFF);
pub const search_box_border = rgb(0xA0, 0xB0, 0xC0);
pub const search_placeholder = rgb(0xA0, 0xA0, 0xA0);

pub const shutdown_btn_bg = rgb(0xE0, 0x40, 0x30);
pub const shutdown_btn_text = rgb(0xFF, 0xFF, 0xFF);

pub const login_bg_top = rgb(0x14, 0x32, 0x5A);
pub const login_bg_bottom = rgb(0x0A, 0x1E, 0x38);
pub const login_panel_glass = rgb(0x30, 0x50, 0x80);

pub const button_face = rgb(0xF0, 0xF0, 0xF0);
pub const button_highlight = rgb(0xFF, 0xFF, 0xFF);
pub const button_shadow = rgb(0xA0, 0xA0, 0xA0);
pub const selection_bg = rgb(0x33, 0x99, 0xFF);

// ── DWM Configuration Defaults ──

pub const DwmDefaults = struct {
    pub const glass_enabled: bool = true;
    pub const glass_opacity: u8 = 188;
    pub const blur_radius: u8 = 14;
    pub const blur_passes: u8 = 3;
    pub const glass_saturation: u8 = 205;
    pub const glass_tint_color: u32 = rgb(0x38, 0x62, 0x98);
    pub const glass_tint_opacity: u8 = 58;
    pub const animation_enabled: bool = true;
    pub const peek_enabled: bool = true;
    pub const shadow_enabled: bool = true;
    pub const shadow_size: u8 = 8;
    pub const shadow_layers: u8 = 4;
    pub const vsync: bool = true;
};

// ── Layout Constants ──

pub const Layout = struct {
    pub const taskbar_height: i32 = 40;
    pub const titlebar_height: i32 = 26;
    pub const start_btn_width: i32 = 108;
    pub const start_btn_orb_size: i32 = 36;
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
