// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS DWM Theme Configuration
//! Migrated and enhanced from aero/src/theme.zig

const std = @import("std");

// ============================================================================
// Color Scheme
// ============================================================================

pub const COLORREF = u32;

pub const ColorScheme = struct {
    name: []const u8,
    desktop_background: COLORREF,
    window_frame_active: COLORREF,
    window_frame_inactive: COLORREF,
    titlebar_active_left: COLORREF,
    titlebar_active_right: COLORREF,
    titlebar_inactive: COLORREF,
    window_button_hover: COLORREF,
    window_button_active: COLORREF,
    taskbar_top: COLORREF,
    taskbar_bottom: COLORREF,
    tray_border: COLORREF,
    tray_background: COLORREF,
    start_button_hover: COLORREF,
    start_button_active: COLORREF,
    scrollbar_arrow: COLORREF,
    scrollbar_thumb: COLORREF,
    menu_separator: COLORREF,
    menu_highlight: COLORREF,
};

// ============================================================================
// Theme Presets
// ============================================================================

pub const THEMES: []const ColorScheme = &.{
    .{
        .name = "ZirconOS Blue",
        .desktop_background = 0x001A1A,
        .window_frame_active = 0x1A1A1A,
        .window_frame_inactive = 0x4A4A4A,
        .titlebar_active_left = 0x0078D4,
        .titlebar_active_right = 0x005A9E,
        .titlebar_inactive = 0x8A8A8A,
        .window_button_hover = 0xE8E8E8,
        .window_button_active = 0xD0D0D0,
        .taskbar_top = 0x1A1A1A,
        .taskbar_bottom = 0x0A0A0A,
        .tray_border = 0x2A2A2A,
        .tray_background = 0x101010,
        .start_button_hover = 0x1A1A1A,
        .start_button_active = 0x005A9E,
        .scrollbar_arrow = 0x3A3A3A,
        .scrollbar_thumb = 0x5A5A5A,
        .menu_separator = 0x3A3A3A,
        .menu_highlight = 0x0078D4,
    },
    .{
        .name = "Classic",
        .desktop_background = 0x008080,
        .window_frame_active = 0x000080,
        .window_frame_inactive = 0x808080,
        .titlebar_active_left = 0x000080,
        .titlebar_active_right = 0x0000FF,
        .titlebar_inactive = 0x808080,
        .window_button_hover = 0xE8E8E8,
        .window_button_active = 0xD0D0D0,
        .taskbar_top = 0x000080,
        .taskbar_bottom = 0x000080,
        .tray_border = 0x000080,
        .tray_background = 0x000080,
        .start_button_hover = 0x000080,
        .start_button_active = 0x0000FF,
        .scrollbar_arrow = 0x000080,
        .scrollbar_thumb = 0x8080FF,
        .menu_separator = 0x000080,
        .menu_highlight = 0x0000FF,
    },
    .{
        .name = "Olive Green",
        .desktop_background = 0x002020,
        .window_frame_active = 0x2A2A1A,
        .window_frame_inactive = 0x5A5A4A,
        .titlebar_active_left = 0x4A6A2A,
        .titlebar_active_right = 0x3A5A1A,
        .titlebar_inactive = 0x7A7A6A,
        .window_button_hover = 0xE8E8E0,
        .window_button_active = 0xD0D0C0,
        .taskbar_top = 0x2A2A1A,
        .taskbar_bottom = 0x1A1A0A,
        .tray_border = 0x3A3A2A,
        .tray_background = 0x1A1A0A,
        .start_button_hover = 0x3A3A2A,
        .start_button_active = 0x4A6A2A,
        .scrollbar_arrow = 0x3A3A2A,
        .scrollbar_thumb = 0x5A5A4A,
        .menu_separator = 0x3A3A2A,
        .menu_highlight = 0x4A6A2A,
    },
    .{
        .name = "Silver",
        .desktop_background = 0x005A5A,
        .window_frame_active = 0x5A5A5A,
        .window_frame_inactive = 0x8A8A8A,
        .titlebar_active_left = 0x6A6A6A,
        .titlebar_active_right = 0x7A7A7A,
        .titlebar_inactive = 0x9A9A9A,
        .window_button_hover = 0xF0F0F0,
        .window_button_active = 0xE0E0E0,
        .taskbar_top = 0x5A5A5A,
        .taskbar_bottom = 0x4A4A4A,
        .tray_border = 0x6A6A6A,
        .tray_background = 0x4A4A4A,
        .start_button_hover = 0x6A6A6A,
        .start_button_active = 0x7A7A7A,
        .scrollbar_arrow = 0x5A5A5A,
        .scrollbar_thumb = 0x7A7A7A,
        .menu_separator = 0x5A5A5A,
        .menu_highlight = 0x6A6A6A,
    },
    .{
        .name = "Midnight",
        .desktop_background = 0x000A14,
        .window_frame_active = 0x0A1428,
        .window_frame_inactive = 0x28384A,
        .titlebar_active_left = 0x141E3A,
        .titlebar_active_right = 0x0A1428,
        .titlebar_inactive = 0x384858,
        .window_button_hover = 0x1A2840,
        .window_button_active = 0x283848,
        .taskbar_top = 0x0A1428,
        .taskbar_bottom = 0x050A14,
        .tray_border = 0x141E2A,
        .tray_background = 0x0A1428,
        .start_button_hover = 0x141E3A,
        .start_button_active = 0x1A2848,
        .scrollbar_arrow = 0x1A2838,
        .scrollbar_thumb = 0x283848,
        .menu_separator = 0x1A2838,
        .menu_highlight = 0x141E3A,
    },
    .{
        .name = "Desert",
        .desktop_background = 0x3A2A1A,
        .window_frame_active = 0x4A3A2A,
        .window_frame_inactive = 0x7A6A5A,
        .titlebar_active_left = 0x6A5A4A,
        .titlebar_active_right = 0x5A4A3A,
        .titlebar_inactive = 0x9A8A7A,
        .window_button_hover = 0xE8D8C0,
        .window_button_active = 0xD8C8B0,
        .taskbar_top = 0x4A3A2A,
        .taskbar_bottom = 0x3A2A1A,
        .tray_border = 0x5A4A3A,
        .tray_background = 0x3A2A1A,
        .start_button_hover = 0x5A4A3A,
        .start_button_active = 0x6A5A4A,
        .scrollbar_arrow = 0x5A4A3A,
        .scrollbar_thumb = 0x7A6A5A,
        .menu_separator = 0x5A4A3A,
        .menu_highlight = 0x6A5A4A,
    },
    .{
        .name = "Twilight",
        .desktop_background = 0x1A0A2A,
        .window_frame_active = 0x2A1A3A,
        .window_frame_inactive = 0x5A4A6A,
        .titlebar_active_left = 0x4A2A6A,
        .titlebar_active_right = 0x3A1A5A,
        .titlebar_inactive = 0x6A5A7A,
        .window_button_hover = 0xD8C8E8,
        .window_button_active = 0xC8B8D8,
        .taskbar_top = 0x2A1A3A,
        .taskbar_bottom = 0x1A0A2A,
        .tray_border = 0x3A2A4A,
        .tray_background = 0x2A1A3A,
        .start_button_hover = 0x3A2A5A,
        .start_button_active = 0x4A2A6A,
        .scrollbar_arrow = 0x3A2A4A,
        .scrollbar_thumb = 0x5A4A6A,
        .menu_separator = 0x3A2A4A,
        .menu_highlight = 0x4A2A6A,
    },
    .{
        .name = "Forest",
        .desktop_background = 0x0A1A0A,
        .window_frame_active = 0x1A2A1A,
        .window_frame_inactive = 0x3A4A3A,
        .titlebar_active_left = 0x2A4A2A,
        .titlebar_active_right = 0x1A3A1A,
        .titlebar_inactive = 0x4A5A4A,
        .window_button_hover = 0xD0E0D0,
        .window_button_active = 0xC0D0C0,
        .taskbar_top = 0x1A2A1A,
        .taskbar_bottom = 0x0A1A0A,
        .tray_border = 0x2A3A2A,
        .tray_background = 0x1A2A1A,
        .start_button_hover = 0x2A3A2A,
        .start_button_active = 0x3A4A3A,
        .scrollbar_arrow = 0x2A3A2A,
        .scrollbar_thumb = 0x3A4A3A,
        .menu_separator = 0x2A3A2A,
        .menu_highlight = 0x3A4A3A,
    },
};

// ============================================================================
// Theme Manager
// ============================================================================

pub const ThemeManager = struct {
    current_theme_idx: usize,
    glass_enabled: bool,
    glass_alpha: u8,
    blur_radius: i32,

    pub fn init(self: *ThemeManager) void {
        self.current_theme_idx = 0;
        self.glass_enabled = true;
        self.glass_alpha = 200;
        self.blur_radius = 8;
    }

    pub fn getCurrentTheme(self: *const ThemeManager) ColorScheme {
        return THEMES[self.current_theme_idx];
    }

    pub fn setTheme(self: *ThemeManager, idx: usize) void {
        if (idx < THEMES.len) {
            self.current_theme_idx = idx;
        }
    }

    pub fn setGlassEnabled(self: *ThemeManager, enabled: bool) void {
        self.glass_enabled = enabled;
    }

    pub fn setGlassAlpha(self: *ThemeManager, alpha: u8) void {
        self.glass_alpha = alpha;
    }

    pub fn setBlurRadius(self: *ThemeManager, radius: i32) void {
        self.blur_radius = radius;
    }
};

// ============================================================================
// Global Theme Manager
// ============================================================================

pub var g_theme_manager: ThemeManager = .{
    .current_theme_idx = 0,
    .glass_enabled = true,
    .glass_alpha = 200,
    .blur_radius = 8,
};

pub fn initThemeManager() void {
    g_theme_manager.init();
}

pub fn getCurrentTheme() ColorScheme {
    return g_theme_manager.getCurrentTheme();
}

pub fn setTheme(idx: usize) void {
    g_theme_manager.setTheme(idx);
}

pub fn isGlassEnabled() bool {
    return g_theme_manager.glass_enabled;
}

pub fn getGlassAlpha() u8 {
    return g_theme_manager.glass_alpha;
}

pub fn getBlurRadius() i32 {
    return g_theme_manager.blur_radius;
}

pub fn setGlassEnabled(enabled: bool) void {
    g_theme_manager.setGlassEnabled(enabled);
}

pub fn setGlassAlpha(alpha: u8) void {
    g_theme_manager.setGlassAlpha(alpha);
}

pub fn setBlurRadius(radius: i32) void {
    g_theme_manager.setBlurRadius(radius);
}
