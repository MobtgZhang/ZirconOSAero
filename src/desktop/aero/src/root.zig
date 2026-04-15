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

//! ZirconOS Aero — DWM-composited Glass Desktop Theme
//! Library root: re-exports all public modules for use by the kernel
//! display compositor and the standalone desktop shell executable.
//!
//! Architecture aligns with NT 6.1-style session/desktop/DWM concepts (Microsoft Learn);
//! implementation is original Zig — see docs/cn/DesktopManagerSpec.md.
//!   winlogon → shell (explorer) → DWM compositor → desktop/taskbar/startmenu
//! Each layer communicates through the exported Zig API below.

pub const theme = @import("theme.zig");
pub const dwm = @import("dwm.zig");
pub const dwm_internal = @import("dwm_internal.zig");
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
pub const icon_resource_ids = @import("icon_resource_ids.zig");
pub const pe_icon_resource = @import("pe_icon_resource.zig");
pub const pe_icon_loader = @import("pe_icon_loader.zig");
pub const shell_icons_manifest = @import("shell_icons_manifest.zig");
pub const font_loader = @import("font_loader.zig");
pub const window_manager = @import("window_manager.zig");
pub const compositor = @import("compositor.zig");
pub const renderer = @import("renderer.zig");
pub const input = @import("input.zig");
pub const cursor = @import("cursor.zig");

// ── Theme identity ──

pub const theme_name = "Aero";
pub const theme_version = "1.3.0";
pub const theme_description = "ZirconAero — glass desktop (Harmony wallpaper, taskbar, tray, gadgets, compositor blur)";

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
