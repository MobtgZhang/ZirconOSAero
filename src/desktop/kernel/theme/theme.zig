//! NT 6.1 (Windows 7) Aero — 唯一受支持的桌面主题。

const color_nt61 = @import("../../../config/color_nt61.zig");

pub fn rgb(r: u32, g: u32, b: u32) u32 {
    return color_nt61.bgrPacked24FromRgbBytes(@intCast(r), @intCast(g), @intCast(b));
}

pub const ThemeColors = struct {
    desktop_bg: u32,
    taskbar_top: u32,
    taskbar_bottom: u32,
    start_btn_top: u32,
    start_btn_bottom: u32,
    start_btn_text: u32,
    titlebar_active_left: u32,
    titlebar_active_right: u32,
    titlebar_inactive_left: u32,
    titlebar_inactive_right: u32,
    titlebar_text: u32,
    window_bg: u32,
    window_border: u32,
    tray_bg: u32,
    clock_text: u32,
    icon_text: u32,
    icon_text_shadow: u32,
    btn_close_top: u32,
    btn_close_bottom: u32,
    btn_minmax_top: u32,
    btn_minmax_bottom: u32,
    selection_bg: u32,
    button_face: u32,
    button_highlight: u32,
    button_shadow: u32,
    tray_border: u32,
    start_label: []const u8,
};

pub const ThemeId = enum(u8) {
    aero = 0,
};

pub const THEME_AERO = ThemeColors{
    .desktop_bg = rgb(0x12, 0x38, 0x62),
    .taskbar_top = rgb(0x36, 0x4E, 0x6E),
    .taskbar_bottom = rgb(0x1A, 0x2C, 0x42),
    .start_btn_top = rgb(0x3D, 0x79, 0xCB),
    .start_btn_bottom = rgb(0x24, 0x56, 0x9D),
    .start_btn_text = rgb(0xFF, 0xFF, 0xFF),
    .titlebar_active_left = rgb(0x41, 0x80, 0xC8),
    .titlebar_active_right = rgb(0x6B, 0xA0, 0xD8),
    .titlebar_inactive_left = rgb(0x80, 0x90, 0xA0),
    .titlebar_inactive_right = rgb(0x70, 0x84, 0x94),
    .titlebar_text = rgb(0x00, 0x00, 0x00),
    .window_bg = rgb(0xFF, 0xFF, 0xFF),
    .window_border = rgb(0x50, 0x78, 0xA8),
    .tray_bg = rgb(0x1C, 0x2A, 0x3E),
    .clock_text = rgb(0xFF, 0xFF, 0xFF),
    .icon_text = rgb(0xFF, 0xFF, 0xFF),
    .icon_text_shadow = rgb(0x00, 0x00, 0x00),
    .btn_close_top = rgb(0xE0, 0x4B, 0x3A),
    .btn_close_bottom = rgb(0xC0, 0x30, 0x20),
    .btn_minmax_top = rgb(0x40, 0x60, 0x90),
    .btn_minmax_bottom = rgb(0x30, 0x50, 0x80),
    .selection_bg = rgb(0x33, 0x99, 0xFF),
    .button_face = rgb(0xF0, 0xF0, 0xF0),
    .button_highlight = rgb(0xFF, 0xFF, 0xFF),
    .button_shadow = rgb(0xA0, 0xA0, 0xA0),
    .tray_border = rgb(0x40, 0x58, 0x78),
    .start_label = "Start",
};

var active_theme: *const ThemeColors = &THEME_AERO;
var active_theme_id: ThemeId = .aero;

pub fn setTheme(id: ThemeId) void {
    _ = id;
    active_theme_id = .aero;
    active_theme = &THEME_AERO;
    const mouse = @import("../../../drivers/input/mouse.zig");
    mouse.setInterpolation(false, 1);
    mouse.setSmoothing(false);
    mouse.setSensitivity(10);
    mouse.setAcceleration(false, 3);
}

pub fn getActiveTheme() *const ThemeColors {
    return active_theme;
}

pub fn getActiveThemeId() ThemeId {
    return active_theme_id;
}

pub fn getThemeName() []const u8 {
    return "Aero";
}

pub fn getTaskbarHeight() i32 {
    return 40;
}
