//! ZirconOS Aero — DWM-composited Glass Desktop Theme
//! Library root: re-exports all public modules for use by the kernel
//! display compositor and the standalone desktop shell executable.
//!
//! Architecture follows ReactOS NT6 desktop model:
//!   winlogon → shell (explorer) → DWM compositor → desktop/taskbar/startmenu
//! Each layer communicates through the exported Zig API below.

pub const theme = @import("theme.zig");
pub const dwm = @import("dwm.zig");
pub const desktop = @import("desktop.zig");
pub const taskbar = @import("taskbar.zig");
pub const startmenu = @import("startmenu.zig");
pub const gadgets = @import("gadgets.zig");
pub const window_decorator = @import("window_decorator.zig");
pub const shell = @import("shell.zig");
pub const controls = @import("controls.zig");
pub const winlogon = @import("winlogon.zig");
pub const theme_loader = @import("theme_loader.zig");
pub const resource_loader = @import("resource_loader.zig");
pub const font_loader = @import("font_loader.zig");

// ── Theme identity ──

pub const theme_name = "Aero";
pub const theme_version = "1.2.0";
pub const theme_description = "ZirconAero — Windows 7 Aero-style glass (Harmony wallpaper, taskbar, tray, gadgets, DWM blur)";

// ── Available theme variants ──

pub const available_themes = [_][]const u8{
    "zircon_aero",
    "zircon_aero_blue",
    "aero-graphite",
    "zircon_aero_characters",
    "zircon_aero_nature",
    "zircon_aero_scenes",
    "zircon_aero_landscapes",
    "zircon_aero_architecture",
};

// ── Quick accessors for the kernel display compositor ──

pub fn getGlassTintColor() u32 {
    return theme.getActiveGlassTint();
}

pub fn getGlassOpacity() u8 {
    return theme.getActiveColors().glass_opacity;
}

pub fn getDesktopBackground() u32 {
    return theme.getActiveDesktopBg();
}

pub fn getTaskbarHeight() i32 {
    return theme.Layout.taskbar_height;
}

pub fn getTitlebarHeight() i32 {
    return theme.Layout.titlebar_height;
}

pub fn isDwmEnabled() bool {
    return dwm.isEnabled();
}

pub fn initAeroDwm() void {
    shell.initShell();
}

pub fn switchTheme(cs: theme.ColorScheme) void {
    shell.switchTheme(cs);
}

pub fn switchThemeByName(name: []const u8) bool {
    return shell.switchThemeByName(name);
}

pub fn getActiveScheme() theme.ColorScheme {
    return theme.getActiveScheme();
}

pub fn getWallpaperPath() []const u8 {
    return desktop.getWallpaperPath();
}

pub fn getAvailableThemeCount() usize {
    return theme_loader.getThemeCount();
}
