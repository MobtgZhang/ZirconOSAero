//! ZirconOS Aero Theme - Windows Vista/7 Aero Visual Style Definitions
//! Defines colors, dimensions, gradients and style constants for the
//! Aero Blue (glass) and Aero Basic (no glass) color schemes.
//! Inspired by DWM composition with translucent glass frames.

pub const COLORREF = u32;

pub fn RGB(r: u8, g: u8, b: u8) COLORREF {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

pub fn RGBA(r: u8, g: u8, b: u8, a: u8) u64 {
    return @as(u64, r) | (@as(u64, g) << 8) | (@as(u64, b) << 16) | (@as(u64, a) << 24);
}

pub fn getRValue(color: COLORREF) u8 {
    return @intCast(color & 0xFF);
}

pub fn getGValue(color: COLORREF) u8 {
    return @intCast((color >> 8) & 0xFF);
}

pub fn getBValue(color: COLORREF) u8 {
    return @intCast((color >> 16) & 0xFF);
}

pub const ColorScheme = enum(u8) {
    aero_blue = 0,
    aero_basic = 1,
};

pub const GlassParams = struct {
    enabled: bool = true,
    default_alpha: u8 = 200,
    blur_radius: i32 = 10,
    colorization_color: COLORREF = 0,
    colorization_alpha: u8 = 120,
    frame_extend: i32 = 0,
};

pub const ThemeColors = struct {
    taskbar_top: COLORREF,
    taskbar_bottom: COLORREF,
    start_orb_top: COLORREF,
    start_orb_bottom: COLORREF,
    start_orb_glow: COLORREF,
    start_orb_text: COLORREF,
    titlebar_active_left: COLORREF,
    titlebar_active_right: COLORREF,
    titlebar_inactive_left: COLORREF,
    titlebar_inactive_right: COLORREF,
    titlebar_text_active: COLORREF,
    titlebar_text_inactive: COLORREF,
    window_border: COLORREF,
    window_background: COLORREF,
    desktop_background: COLORREF,
    menu_background: COLORREF,
    menu_highlight: COLORREF,
    menu_highlight_text: COLORREF,
    menu_text: COLORREF,
    menu_separator: COLORREF,
    button_face: COLORREF,
    button_highlight: COLORREF,
    button_shadow: COLORREF,
    button_text: COLORREF,
    button_glow: COLORREF,
    scrollbar_track: COLORREF,
    scrollbar_thumb: COLORREF,
    selection_bg: COLORREF,
    selection_text: COLORREF,
    tooltip_bg: COLORREF,
    tooltip_text: COLORREF,
    login_bg_top: COLORREF,
    login_bg_bottom: COLORREF,
    login_panel: COLORREF,
    login_text: COLORREF,
    tray_bg: COLORREF,
    clock_text: COLORREF,
    close_btn_hover: COLORREF,
    close_btn_glow: COLORREF,
    progress_fill_left: COLORREF,
    progress_fill_right: COLORREF,
    search_box_bg: COLORREF,
    search_box_border: COLORREF,
    glass: GlassParams,
};

pub const AERO_BLUE = ThemeColors{
    .taskbar_top = RGB(0x1C, 0x3B, 0x6A),
    .taskbar_bottom = RGB(0x2A, 0x5F, 0xB5),
    .start_orb_top = RGB(0x3A, 0x9C, 0x34),
    .start_orb_bottom = RGB(0x27, 0x6F, 0x22),
    .start_orb_glow = RGB(0x6A, 0xD6, 0x65),
    .start_orb_text = RGB(0xFF, 0xFF, 0xFF),
    .titlebar_active_left = RGB(0x2A, 0x5F, 0xB5),
    .titlebar_active_right = RGB(0x4A, 0x8F, 0xE5),
    .titlebar_inactive_left = RGB(0x8B, 0xA8, 0xCE),
    .titlebar_inactive_right = RGB(0xB0, 0xC4, 0xDE),
    .titlebar_text_active = RGB(0x00, 0x00, 0x00),
    .titlebar_text_inactive = RGB(0x68, 0x68, 0x68),
    .window_border = RGB(0x3B, 0x72, 0xA9),
    .window_background = RGB(0xFF, 0xFF, 0xFF),
    .desktop_background = RGB(0x3A, 0x6E, 0xA5),
    .menu_background = RGB(0xFF, 0xFF, 0xFF),
    .menu_highlight = RGB(0x33, 0x99, 0xFF),
    .menu_highlight_text = RGB(0xFF, 0xFF, 0xFF),
    .menu_text = RGB(0x00, 0x00, 0x00),
    .menu_separator = RGB(0xD0, 0xD0, 0xD0),
    .button_face = RGB(0xF0, 0xF0, 0xF0),
    .button_highlight = RGB(0xFF, 0xFF, 0xFF),
    .button_shadow = RGB(0xA0, 0xA0, 0xA0),
    .button_text = RGB(0x00, 0x00, 0x00),
    .button_glow = RGB(0x7E, 0xB4, 0xEA),
    .scrollbar_track = RGB(0xF0, 0xF0, 0xF0),
    .scrollbar_thumb = RGB(0xC0, 0xC0, 0xC0),
    .selection_bg = RGB(0x33, 0x99, 0xFF),
    .selection_text = RGB(0xFF, 0xFF, 0xFF),
    .tooltip_bg = RGB(0xFF, 0xFF, 0xFF),
    .tooltip_text = RGB(0x57, 0x57, 0x57),
    .login_bg_top = RGB(0x2A, 0x5F, 0xB5),
    .login_bg_bottom = RGB(0x12, 0x2D, 0x52),
    .login_panel = RGB(0xE8, 0xF0, 0xFA),
    .login_text = RGB(0x00, 0x00, 0x00),
    .tray_bg = RGB(0x1C, 0x3B, 0x6A),
    .clock_text = RGB(0xFF, 0xFF, 0xFF),
    .close_btn_hover = RGB(0xE8, 0x11, 0x23),
    .close_btn_glow = RGB(0xF1, 0x70, 0x7A),
    .progress_fill_left = RGB(0x06, 0xB0, 0x25),
    .progress_fill_right = RGB(0x2F, 0xD6, 0x4E),
    .search_box_bg = RGB(0xFF, 0xFF, 0xFF),
    .search_box_border = RGB(0x7A, 0xB0, 0xDA),
    .glass = .{
        .enabled = true,
        .default_alpha = 200,
        .blur_radius = 10,
        .colorization_color = RGB(0x4A, 0x8F, 0xE5),
        .colorization_alpha = 120,
        .frame_extend = 0,
    },
};

pub const AERO_BASIC = ThemeColors{
    .taskbar_top = RGB(0xD0, 0xD8, 0xE0),
    .taskbar_bottom = RGB(0xB0, 0xB8, 0xC8),
    .start_orb_top = RGB(0x5C, 0xA8, 0x55),
    .start_orb_bottom = RGB(0x3D, 0x85, 0x37),
    .start_orb_glow = RGB(0x7E, 0xD0, 0x78),
    .start_orb_text = RGB(0xFF, 0xFF, 0xFF),
    .titlebar_active_left = RGB(0xA0, 0xB4, 0xCE),
    .titlebar_active_right = RGB(0xB8, 0xCE, 0xE4),
    .titlebar_inactive_left = RGB(0xC0, 0xC0, 0xC0),
    .titlebar_inactive_right = RGB(0xD8, 0xD8, 0xD8),
    .titlebar_text_active = RGB(0x00, 0x00, 0x00),
    .titlebar_text_inactive = RGB(0x80, 0x80, 0x80),
    .window_border = RGB(0x86, 0x8E, 0x96),
    .window_background = RGB(0xFF, 0xFF, 0xFF),
    .desktop_background = RGB(0x3A, 0x6E, 0xA5),
    .menu_background = RGB(0xF0, 0xF0, 0xF0),
    .menu_highlight = RGB(0x91, 0xC9, 0xF7),
    .menu_highlight_text = RGB(0x00, 0x00, 0x00),
    .menu_text = RGB(0x00, 0x00, 0x00),
    .menu_separator = RGB(0xD5, 0xD5, 0xD5),
    .button_face = RGB(0xE1, 0xE1, 0xE1),
    .button_highlight = RGB(0xFF, 0xFF, 0xFF),
    .button_shadow = RGB(0xA0, 0xA0, 0xA0),
    .button_text = RGB(0x00, 0x00, 0x00),
    .button_glow = RGB(0xB0, 0xC8, 0xE0),
    .scrollbar_track = RGB(0xF0, 0xF0, 0xF0),
    .scrollbar_thumb = RGB(0xC8, 0xC8, 0xC8),
    .selection_bg = RGB(0x91, 0xC9, 0xF7),
    .selection_text = RGB(0x00, 0x00, 0x00),
    .tooltip_bg = RGB(0xFF, 0xFF, 0xFF),
    .tooltip_text = RGB(0x57, 0x57, 0x57),
    .login_bg_top = RGB(0x80, 0xA0, 0xC0),
    .login_bg_bottom = RGB(0x40, 0x60, 0x80),
    .login_panel = RGB(0xE8, 0xEC, 0xF0),
    .login_text = RGB(0x00, 0x00, 0x00),
    .tray_bg = RGB(0xC0, 0xC8, 0xD8),
    .clock_text = RGB(0x00, 0x00, 0x00),
    .close_btn_hover = RGB(0xE8, 0x11, 0x23),
    .close_btn_glow = RGB(0xF1, 0x70, 0x7A),
    .progress_fill_left = RGB(0x06, 0xB0, 0x25),
    .progress_fill_right = RGB(0x2F, 0xD6, 0x4E),
    .search_box_bg = RGB(0xFF, 0xFF, 0xFF),
    .search_box_border = RGB(0xA0, 0xA8, 0xB0),
    .glass = .{
        .enabled = false,
        .default_alpha = 255,
        .blur_radius = 0,
        .colorization_color = RGB(0xB8, 0xCE, 0xE4),
        .colorization_alpha = 255,
        .frame_extend = 0,
    },
};

// ── Dimension Constants ──

pub const TITLEBAR_HEIGHT: i32 = 30;
pub const TITLEBAR_BUTTON_SIZE: i32 = 21;
pub const TITLEBAR_BUTTON_MARGIN: i32 = 2;
pub const TITLEBAR_ICON_SIZE: i32 = 16;
pub const TITLEBAR_ICON_MARGIN: i32 = 4;
pub const TITLEBAR_TEXT_OFFSET_X: i32 = 28;
pub const TITLEBAR_TEXT_OFFSET_Y: i32 = 7;
pub const TITLEBAR_CORNER_RADIUS: i32 = 4;

pub const WINDOW_BORDER_WIDTH: i32 = 3;
pub const WINDOW_RESIZE_BORDER: i32 = 4;
pub const WINDOW_SHADOW_SIZE: i32 = 8;
pub const WINDOW_MIN_WIDTH: i32 = 150;
pub const WINDOW_MIN_HEIGHT: i32 = 50;

pub const TASKBAR_HEIGHT: i32 = 40;
pub const TASKBAR_BUTTON_HEIGHT: i32 = 34;
pub const TASKBAR_CLOCK_WIDTH: i32 = 90;
pub const TASKBAR_BUTTON_MAX_WIDTH: i32 = 160;

pub const START_ORB_WIDTH: i32 = 40;
pub const START_ORB_HEIGHT: i32 = 30;

pub const STARTMENU_WIDTH: i32 = 410;
pub const STARTMENU_HEIGHT: i32 = 500;
pub const STARTMENU_LEFT_WIDTH: i32 = 210;
pub const STARTMENU_RIGHT_WIDTH: i32 = 200;
pub const STARTMENU_ITEM_HEIGHT: i32 = 32;
pub const STARTMENU_ICON_SIZE: i32 = 32;
pub const STARTMENU_HEADER_HEIGHT: i32 = 60;
pub const STARTMENU_FOOTER_HEIGHT: i32 = 36;
pub const STARTMENU_SEARCH_HEIGHT: i32 = 28;
pub const STARTMENU_SEPARATOR_HEIGHT: i32 = 8;

pub const DESKTOP_ICON_SIZE: i32 = 48;
pub const DESKTOP_ICON_SPACING_X: i32 = 80;
pub const DESKTOP_ICON_SPACING_Y: i32 = 80;
pub const DESKTOP_ICON_TEXT_WIDTH: i32 = 72;
pub const DESKTOP_ICON_MARGIN: i32 = 10;

pub const LOGIN_PANEL_WIDTH: i32 = 400;
pub const LOGIN_PANEL_HEIGHT: i32 = 320;
pub const LOGIN_AVATAR_SIZE: i32 = 96;
pub const LOGIN_INPUT_WIDTH: i32 = 220;
pub const LOGIN_INPUT_HEIGHT: i32 = 26;
pub const LOGIN_BUTTON_WIDTH: i32 = 32;
pub const LOGIN_BUTTON_HEIGHT: i32 = 26;

pub const BUTTON_HEIGHT: i32 = 23;
pub const BUTTON_MIN_WIDTH: i32 = 75;
pub const BUTTON_CORNER_RADIUS: i32 = 3;
pub const CHECKBOX_SIZE: i32 = 13;
pub const RADIO_SIZE: i32 = 13;
pub const TEXTBOX_HEIGHT: i32 = 23;

pub const TOOLTIP_PADDING: i32 = 5;
pub const MENU_ITEM_HEIGHT: i32 = 24;
pub const MENU_ICON_WIDTH: i32 = 28;
pub const SCROLLBAR_WIDTH: i32 = 17;

pub const THUMBNAIL_WIDTH: i32 = 200;
pub const THUMBNAIL_HEIGHT: i32 = 140;

// ── Font Definitions ──

pub const FONT_SYSTEM = "Segoe UI";
pub const FONT_SYSTEM_SIZE: i32 = 9;
pub const FONT_TITLEBAR = "Segoe UI";
pub const FONT_TITLEBAR_SIZE: i32 = 9;
pub const FONT_MENU = "Segoe UI";
pub const FONT_MENU_SIZE: i32 = 9;
pub const FONT_ICON = "Segoe UI";
pub const FONT_ICON_SIZE: i32 = 9;
pub const FONT_STARTMENU_USER = "Segoe UI";
pub const FONT_STARTMENU_USER_SIZE: i32 = 14;
pub const FONT_TOOLTIP = "Segoe UI";
pub const FONT_TOOLTIP_SIZE: i32 = 9;
pub const FONT_CLOCK = "Segoe UI";
pub const FONT_CLOCK_SIZE: i32 = 9;
pub const FONT_SEARCH = "Segoe UI";
pub const FONT_SEARCH_SIZE: i32 = 9;

// ── Theme State ──

var current_scheme: ColorScheme = .aero_blue;
var current_colors: *const ThemeColors = &AERO_BLUE;

pub fn setColorScheme(scheme: ColorScheme) void {
    current_scheme = scheme;
    current_colors = switch (scheme) {
        .aero_blue => &AERO_BLUE,
        .aero_basic => &AERO_BASIC,
    };
}

pub fn getColorScheme() ColorScheme {
    return current_scheme;
}

pub fn getColors() *const ThemeColors {
    return current_colors;
}

pub fn isGlassEnabled() bool {
    return current_colors.glass.enabled;
}

pub fn getGlassAlpha() u8 {
    return current_colors.glass.default_alpha;
}

pub fn getBlurRadius() i32 {
    return current_colors.glass.blur_radius;
}

pub fn getThemeName() []const u8 {
    return switch (current_scheme) {
        .aero_blue => "Aero Blue (Glass)",
        .aero_basic => "Aero Basic",
    };
}

pub fn interpolateColor(c1: COLORREF, c2: COLORREF, t_num: u32, t_den: u32) COLORREF {
    if (t_den == 0) return c1;
    const r1: i32 = @intCast(c1 & 0xFF);
    const g1: i32 = @intCast((c1 >> 8) & 0xFF);
    const b1: i32 = @intCast((c1 >> 16) & 0xFF);
    const r2: i32 = @intCast(c2 & 0xFF);
    const g2: i32 = @intCast((c2 >> 8) & 0xFF);
    const b2: i32 = @intCast((c2 >> 16) & 0xFF);

    const t_n: i32 = @intCast(t_num);
    const t_d: i32 = @intCast(t_den);

    const r: u32 = @intCast(clamp(r1 + @divTrunc((r2 - r1) * t_n, t_d), 0, 255));
    const g: u32 = @intCast(clamp(g1 + @divTrunc((g2 - g1) * t_n, t_d), 0, 255));
    const b: u32 = @intCast(clamp(b1 + @divTrunc((b2 - b1) * t_n, t_d), 0, 255));

    return r | (g << 8) | (b << 16);
}

pub fn alphaBlend(src: COLORREF, dst: COLORREF, alpha: u8) COLORREF {
    const a: u32 = alpha;
    const inv_a: u32 = 255 - a;
    const sr: u32 = src & 0xFF;
    const sg: u32 = (src >> 8) & 0xFF;
    const sb: u32 = (src >> 16) & 0xFF;
    const dr: u32 = dst & 0xFF;
    const dg: u32 = (dst >> 8) & 0xFF;
    const db: u32 = (dst >> 16) & 0xFF;

    const r = (sr * a + dr * inv_a) / 255;
    const g_val = (sg * a + dg * inv_a) / 255;
    const b_val = (sb * a + db * inv_a) / 255;
    return (r & 0xFF) | ((g_val & 0xFF) << 8) | ((b_val & 0xFF) << 16);
}

pub fn glassBlend(color: COLORREF, background: COLORREF) COLORREF {
    return alphaBlend(color, background, current_colors.glass.default_alpha);
}

fn clamp(val: i32, min_val: i32, max_val: i32) i32 {
    if (val < min_val) return min_val;
    if (val > max_val) return max_val;
    return val;
}

pub fn init() void {
    current_scheme = .aero_blue;
    current_colors = &AERO_BLUE;
}
