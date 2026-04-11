// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets_detail.zig
// Purpose: Detailed Control Panel applets implementation
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const dwm_mod = @import("../../../drivers/video/core/dwm.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

// Appearance and Personalization Applet
pub const AppearanceApplet = struct {
    x: i32, y: i32, width: i32, height: i32,
    visible: bool,
    selected_theme: i32,
    selected_background: i32,
    color_scheme: i32,

    pub fn create() AppearanceApplet {
        return .{
            .x = 0, .y = 0, .width = 600, .height = 450,
            .visible = true,
            .selected_theme = 0,
            .selected_background = 0,
            .color_scheme = 0,
        };
    }

    pub fn render(ap: *AppearanceApplet, _: *const theme_mod.ThemeColors) void {
        if (!ap.visible) return;
        fb.fillRect(ap.x, ap.y, ap.width, ap.height, rgb(0xF0, 0xF4, 0xF8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 16, "Appearance Settings", rgb(0x20, 0x40, 0x80));
        fb.drawHLine(ap.x + 16, ap.y + 40, ap.width - 32, rgb(0xC0, 0xC8, 0xD8));

        const themes = [_][]const u8{ "Windows Aero", "Windows Basic", "Classic" };
        var theme_y = ap.y + 60;
        for (themes, 0..) |theme, idx| {
            const is_selected = @as(i32, @intCast(idx)) == ap.selected_theme;
            if (is_selected) {
                fb.fillRect(ap.x + 20, theme_y, 400, 30, rgb(0xD8, 0xE4, 0xF0));
            }
            fb.drawTextTransparent(ap.x + 30, theme_y + 8, theme, rgb(0x20, 0x20, 0x30));
            theme_y += 36;
        }

        fb.drawTextTransparent(ap.x + 16, theme_y + 20, "Desktop Background", rgb(0x20, 0x40, 0x80));
        var bg_y = theme_y + 50;
        var bg_x = ap.x + 20;
        var bg_idx: i32 = 0;
        while (bg_idx < 6) : (bg_idx += 1) {
            fb.fillRect(bg_x, bg_y, 80, 60, rgb(0xC8, 0xD0, 0xD8));
            fb.draw3DRect(bg_x, bg_y, 80, 60, rgb(0xA0, 0xA8, 0xB8), rgb(0xF0, 0xF0, 0xF0));
            bg_x += 90;
            if (bg_x > ap.x + ap.width - 100) {
                bg_x = ap.x + 20;
                bg_y += 70;
            }
        }
    }
};

// Display Applet
pub const DisplayApplet = struct {
    x: i32, y: i32, width: i32, height: i32,
    visible: bool,
    resolution_index: i32,
    orientation: i32,
    brightness: i32,

    pub fn create() DisplayApplet {
        return .{
            .x = 0, .y = 0, .width = 600, .height = 450,
            .visible = true,
            .resolution_index = 2,
            .orientation = 0,
            .brightness = 75,
        };
    }

    pub fn render(ap: *DisplayApplet, _: *const theme_mod.ThemeColors) void {
        if (!ap.visible) return;
        fb.fillRect(ap.x, ap.y, ap.width, ap.height, rgb(0xF0, 0xF4, 0xF8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 16, "Display Settings", rgb(0x20, 0x40, 0x80));

        fb.drawTextTransparent(ap.x + 16, ap.y + 60, "Resolution", rgb(0x20, 0x20, 0x30));
        const resolutions = [_][]const u8{ "1024x768", "1280x720", "1280x800", "1366x768", "1920x1080" };
        var res_y = ap.y + 85;
        for (resolutions, 0..) |res, idx| {
            const is_selected = @as(i32, @intCast(idx)) == ap.resolution_index;
            if (is_selected) {
                fb.fillRect(ap.x + 20, res_y, 120, 24, rgb(0xD8, 0xE4, 0xF0));
                fb.draw3DRect(ap.x + 20, res_y, 120, 24, rgb(0x5C, 0x9E, 0xD6), rgb(0x5C, 0x9E, 0xD6));
            } else {
                fb.fillRect(ap.x + 20, res_y, 120, 24, rgb(0xFF, 0xFF, 0xFF));
                fb.draw3DRect(ap.x + 20, res_y, 120, 24, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            }
            fb.drawTextTransparent(ap.x + 30, res_y + 5, res, rgb(0x10, 0x10, 0x10));
            res_y += 28;
        }

        fb.drawTextTransparent(ap.x + 16, ap.y + 240, "Orientation", rgb(0x20, 0x20, 0x30));
        const orientations = [_][]const u8{ "Landscape", "Portrait", "Landscape (flipped)", "Portrait (flipped)" };
        var orient_y = ap.y + 265;
        for (orientations) |orient| {
            fb.fillRect(ap.x + 20, orient_y, 160, 24, rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(ap.x + 20, orient_y, 160, 24, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(ap.x + 30, orient_y + 5, orient, rgb(0x10, 0x10, 0x10));
            orient_y += 28;
        }
    }
};

// Sound Applet
pub const SoundApplet = struct {
    x: i32, y: i32, width: i32, height: i32,
    visible: bool,
    selected_device: i32,
    volume: i32,
    selected_scheme: i32,

    pub fn create() SoundApplet {
        return .{
            .x = 0, .y = 0, .width = 600, .height = 450,
            .visible = true,
            .selected_device = 0,
            .volume = 75,
            .selected_scheme = 0,
        };
    }

    pub fn render(ap: *SoundApplet, _: *const theme_mod.ThemeColors) void {
        if (!ap.visible) return;
        fb.fillRect(ap.x, ap.y, ap.width, ap.height, rgb(0xF0, 0xF4, 0xF8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 16, "Sound Settings", rgb(0x20, 0x40, 0x80));
        fb.drawHLine(ap.x + 16, ap.y + 40, ap.width - 32, rgb(0xC0, 0xC8, 0xD8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 60, "Playback", rgb(0x20, 0x20, 0x30));
        fb.fillRect(ap.x + 20, ap.y + 85, ap.width - 40, 60, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(ap.x + 20, ap.y + 85, ap.width - 40, 60, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(ap.x + 30, ap.y + 105, "Speakers (High Definition Audio)", rgb(0x10, 0x10, 0x10));

        fb.drawTextTransparent(ap.x + 16, ap.y + 160, "Volume", rgb(0x20, 0x20, 0x30));
        const vol_x = ap.x + 20;
        const vol_y = ap.y + 185;
        const vol_w = ap.width - 100;
        const vol_h = 24;
        fb.fillRect(vol_x, vol_y, vol_w, vol_h, rgb(0xD0, 0xD8, 0xE0));
        const fill_w = @as(i32, @intCast(@as(f32, @floatFromInt(ap.volume)) / 100.0 * @as(f32, @floatFromInt(vol_w))));
        if (fill_w > 0) {
            fb.fillRect(vol_x, vol_y, fill_w, vol_h, rgb(0x38, 0x78, 0x38));
        }

        fb.drawTextTransparent(ap.x + 16, ap.y + 230, "Sound Scheme", rgb(0x20, 0x20, 0x30));
        const schemes = [_][]const u8{ "No Sounds", "Windows Default", "Windows Vista", "Sci-Fi" };
        var scheme_y = ap.y + 255;
        for (schemes, 0..) |scheme, idx| {
            const is_selected = @as(i32, @intCast(idx)) == ap.selected_scheme;
            fb.fillRect(ap.x + 20, scheme_y, 200, 24, rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(ap.x + 20, scheme_y, 200, 24, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            if (is_selected) {
                fb.drawTextTransparent(ap.x + 24, scheme_y + 5, ">>", rgb(0x10, 0x40, 0x90));
            }
            fb.drawTextTransparent(ap.x + 48, scheme_y + 5, scheme, rgb(0x10, 0x10, 0x10));
            scheme_y += 28;
        }
    }
};

// Mouse Applet
pub const MouseApplet = struct {
    x: i32, y: i32, width: i32, height: i32,
    visible: bool,
    primary_button: i32,
    double_click_speed: i32,
    pointer_speed: i32,
    pointer_scheme: i32,

    pub fn create() MouseApplet {
        return .{
            .x = 0, .y = 0, .width = 600, .height = 450,
            .visible = true,
            .primary_button = 0,
            .double_click_speed = 50,
            .pointer_speed = 50,
            .pointer_scheme = 0,
        };
    }

    pub fn render(ap: *MouseApplet, _: *const theme_mod.ThemeColors) void {
        if (!ap.visible) return;
        fb.fillRect(ap.x, ap.y, ap.width, ap.height, rgb(0xF0, 0xF4, 0xF8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 16, "Mouse Properties", rgb(0x20, 0x40, 0x80));
        fb.drawHLine(ap.x + 16, ap.y + 40, ap.width - 32, rgb(0xC0, 0xC8, 0xD8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 60, "Buttons", rgb(0x20, 0x40, 0x80));

        fb.drawTextTransparent(ap.x + 20, ap.y + 90, "Primary and secondary buttons", rgb(0x20, 0x20, 0x30));
        const button_opts = [_][]const u8{ "Left-handed", "Right-handed" };
        var btn_y = ap.y + 115;
        for (button_opts, 0..) |opt, idx| {
            const is_selected = @as(i32, @intCast(idx)) == ap.primary_button;
            fb.fillRect(ap.x + 30, btn_y, 200, 24, rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(ap.x + 30, btn_y, 200, 24, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            if (is_selected) {
                fb.fillRect(ap.x + 32, btn_y + 2, 8, 20, rgb(0x10, 0x40, 0x90));
            }
            fb.drawTextTransparent(ap.x + 50, btn_y + 5, opt, rgb(0x10, 0x10, 0x10));
            btn_y += 28;
        }

        fb.drawTextTransparent(ap.x + 16, ap.y + 200, "Double-click speed", rgb(0x20, 0x20, 0x30));
        const dc_x = ap.x + 20;
        const dc_y = ap.y + 225;
        fb.fillRect(dc_x, dc_y, 300, 20, rgb(0xD0, 0xD8, 0xE0));
        const dc_fill = @as(i32, @intCast(@as(f32, @floatFromInt(ap.double_click_speed)) / 100.0 * 300.0));
        fb.fillRect(dc_x, dc_y, dc_fill, 20, rgb(0x5C, 0x9E, 0xD6));

        fb.drawTextTransparent(ap.x + 16, ap.y + 260, "Pointer speed", rgb(0x20, 0x20, 0x30));
        const ps_x = ap.x + 20;
        const ps_y = ap.y + 285;
        fb.fillRect(ps_x, ps_y, 300, 20, rgb(0xD0, 0xD8, 0xE0));
        const ps_fill = @as(i32, @intCast(@as(f32, @floatFromInt(ap.pointer_speed)) / 100.0 * 300.0));
        fb.fillRect(ps_x, ps_y, ps_fill, 20, rgb(0x5C, 0x9E, 0xD6));
    }
};

// Date and Time Applet
pub const DateTimeApplet = struct {
    x: i32, y: i32, width: i32, height: i32,
    visible: bool,
    day: i32,
    month: i32,
    year: i32,
    hour: i32,
    minute: i32,
    second: i32,
    timezone_index: i32,

    pub fn create() DateTimeApplet {
        return .{
            .x = 0, .y = 0, .width = 500, .height = 400,
            .visible = true,
            .day = 11,
            .month = 4,
            .year = 2026,
            .hour = 12,
            .minute = 0,
            .second = 0,
            .timezone_index = 0,
        };
    }

    pub fn render(ap: *DateTimeApplet, _: *const theme_mod.ThemeColors) void {
        if (!ap.visible) return;
        fb.fillRect(ap.x, ap.y, ap.width, ap.height, rgb(0xF0, 0xF4, 0xF8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 16, "Date and Time", rgb(0x20, 0x40, 0x80));
        fb.drawHLine(ap.x + 16, ap.y + 40, ap.width - 32, rgb(0xC0, 0xC8, 0xD8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 60, "Date", rgb(0x20, 0x40, 0x80));
        var date_buf: [32]u8 = undefined;
        const date_str = std.fmt.bufPrint(&date_buf, "{d}/{d}/{d}", .{ ap.month, ap.day, ap.year }) catch "";
        fb.fillRect(ap.x + 20, ap.y + 85, 200, 30, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(ap.x + 20, ap.y + 85, 200, 30, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(ap.x + 30, ap.y + 92, date_str, rgb(0x10, 0x10, 0x10));

        fb.drawTextTransparent(ap.x + 16, ap.y + 140, "Time", rgb(0x20, 0x40, 0x80));
        var time_buf: [32]u8 = undefined;
        const time_str = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ ap.hour, ap.minute, ap.second }) catch "";
        fb.fillRect(ap.x + 20, ap.y + 165, 200, 30, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(ap.x + 20, ap.y + 165, 200, 30, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(ap.x + 30, ap.y + 172, time_str, rgb(0x10, 0x10, 0x10));

        fb.drawTextTransparent(ap.x + 16, ap.y + 220, "Time Zone", rgb(0x20, 0x40, 0x80));
        const timezones = [_][]const u8{ "UTC+8:00 Beijing", "UTC+0:00 London", "UTC-5:00 New York", "UTC-8:00 Los Angeles" };
        var tz_y = ap.y + 245;
        for (timezones) |tz| {
            fb.fillRect(ap.x + 20, tz_y, 200, 24, rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(ap.x + 20, tz_y, 200, 24, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(ap.x + 30, tz_y + 5, tz, rgb(0x10, 0x10, 0x10));
            tz_y += 28;
        }
    }
};

// User Accounts Applet
pub const UserAccountsApplet = struct {
    x: i32, y: i32, width: i32, height: i32,
    visible: bool,
    selected_user: i32,

    pub fn create() UserAccountsApplet {
        return .{
            .x = 0, .y = 0, .width = 550, .height = 400,
            .visible = true,
            .selected_user = 0,
        };
    }

    pub fn render(ap: *UserAccountsApplet, _: *const theme_mod.ThemeColors) void {
        if (!ap.visible) return;
        fb.fillRect(ap.x, ap.y, ap.width, ap.height, rgb(0xF0, 0xF4, 0xF8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 16, "User Accounts", rgb(0x20, 0x40, 0x80));
        fb.drawHLine(ap.x + 16, ap.y + 40, ap.width - 32, rgb(0xC0, 0xC8, 0xD8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 60, "Current User", rgb(0x20, 0x40, 0x80));

        fb.fillRect(ap.x + 20, ap.y + 85, ap.width - 40, 80, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(ap.x + 20, ap.y + 85, ap.width - 40, 80, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        fb.fillRect(ap.x + 30, ap.y + 95, 48, 48, rgb(0xE8, 0xEC, 0xF4));
        fb.drawTextTransparent(ap.x + 90, ap.y + 100, "User", rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(ap.x + 90, ap.y + 120, "Administrator", rgb(0x10, 0x40, 0x90));

        const options = [_][]const u8{ "Change your account name", "Change your password", "Change your picture", "Manage another account" };
        var opt_y = ap.y + 190;
        for (options) |opt| {
            fb.fillRect(ap.x + 20, opt_y, ap.width - 40, 28, rgb(0xE8, 0xEC, 0xF4));
            fb.draw3DRect(ap.x + 20, opt_y, ap.width - 40, 28, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
            fb.drawTextTransparent(ap.x + 30, opt_y + 7, opt, rgb(0x10, 0x40, 0x90));
            opt_y += 32;
        }
    }
};

// System Applet
pub const SystemApplet = struct {
    x: i32, y: i32, width: i32, height: i32,
    visible: bool,

    pub fn create() SystemApplet {
        return .{
            .x = 0, .y = 0, .width = 550, .height = 450,
            .visible = true,
        };
    }

    pub fn render(ap: *SystemApplet, _: *const theme_mod.ThemeColors) void {
        if (!ap.visible) return;
        fb.fillRect(ap.x, ap.y, ap.width, ap.height, rgb(0xF0, 0xF4, 0xF8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 16, "System", rgb(0x20, 0x40, 0x80));
        fb.drawHLine(ap.x + 16, ap.y + 40, ap.width - 32, rgb(0xC0, 0xC8, 0xD8));

        fb.fillRect(ap.x + 20, ap.y + 55, ap.width - 40, 100, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(ap.x + 20, ap.y + 55, ap.width - 40, 100, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        const info_items = [_][]const u8{
            "Windows version: ZirconOSAero NT 6.1",
            "Processor: LoongArch64 @ 2.0GHz",
            "Installed memory (RAM): 4.00 GB",
            "System type: 64-bit operating system",
        };

        var info_y = ap.y + 70;
        for (info_items) |item| {
            fb.drawTextTransparent(ap.x + 30, info_y, item, rgb(0x10, 0x10, 0x10));
            info_y += 18;
        }

        fb.drawTextTransparent(ap.x + 16, ap.y + 175, "Device Manager", rgb(0x20, 0x40, 0x80));
        fb.fillRect(ap.x + 20, ap.y + 200, ap.width - 40, 36, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(ap.x + 20, ap.y + 200, ap.width - 40, 36, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
        fb.drawTextTransparent(ap.x + 30, ap.y + 210, "View device configuration", rgb(0x10, 0x40, 0x90));

        fb.drawTextTransparent(ap.x + 16, ap.y + 260, "Remote settings", rgb(0x20, 0x40, 0x80));
        fb.fillRect(ap.x + 20, ap.y + 285, ap.width - 40, 36, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(ap.x + 20, ap.y + 285, ap.width - 40, 36, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
        fb.drawTextTransparent(ap.x + 30, ap.y + 295, "Configure remote access", rgb(0x10, 0x40, 0x90));

        fb.drawTextTransparent(ap.x + 16, ap.y + 345, "System protection", rgb(0x20, 0x40, 0x80));
        fb.fillRect(ap.x + 20, ap.y + 370, ap.width - 40, 36, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(ap.x + 20, ap.y + 370, ap.width - 40, 36, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
        fb.drawTextTransparent(ap.x + 30, ap.y + 380, "Configure system restore", rgb(0x10, 0x40, 0x90));
    }
};

// Power Options Applet
pub const PowerApplet = struct {
    x: i32, y: i32, width: i32, height: i32,
    visible: bool,
    selected_plan: i32,

    pub fn create() PowerApplet {
        return .{
            .x = 0, .y = 0, .width = 600, .height = 450,
            .visible = true,
            .selected_plan = 0,
        };
    }

    pub fn render(ap: *PowerApplet, _: *const theme_mod.ThemeColors) void {
        if (!ap.visible) return;
        fb.fillRect(ap.x, ap.y, ap.width, ap.height, rgb(0xF0, 0xF4, 0xF8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 16, "Power Options", rgb(0x20, 0x40, 0x80));
        fb.drawHLine(ap.x + 16, ap.y + 40, ap.width - 32, rgb(0xC0, 0xC8, 0xD8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 60, "Select a power plan", rgb(0x20, 0x20, 0x30));

        const plans = [_][]const u8{
            "Balanced (recommended)",
            "High performance",
            "Power saver",
        };

        var plan_y = ap.y + 90;
        for (plans, 0..) |plan, idx| {
            const is_selected = @as(i32, @intCast(idx)) == ap.selected_plan;
            fb.fillRect(ap.x + 20, plan_y, ap.width - 40, 60, if (is_selected) rgb(0xD8, 0xE4, 0xF0) else rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(ap.x + 20, plan_y, ap.width - 40, 60, if (is_selected) rgb(0x5C, 0x9E, 0xD6) else rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(ap.x + 30, plan_y + 10, plan, if (is_selected) rgb(0x10, 0x40, 0x90) else rgb(0x10, 0x10, 0x10));
            if (idx == 0) {
                fb.drawTextTransparent(ap.x + 30, plan_y + 30, "Automatically balance performance and energy consumption", rgb(0x60, 0x60, 0x60));
            }
            plan_y += 70;
        }
    }
};

// Windows Firewall Applet
pub const FirewallApplet = struct {
    x: i32, y: i32, width: i32, height: i32,
    visible: bool,
    firewall_on: bool,
    blocked_apps_count: i32,

    pub fn create() FirewallApplet {
        return .{
            .x = 0, .y = 0, .width = 550, .height = 400,
            .visible = true,
            .firewall_on = true,
            .blocked_apps_count = 0,
        };
    }

    pub fn render(ap: *FirewallApplet, _: *const theme_mod.ThemeColors) void {
        if (!ap.visible) return;
        fb.fillRect(ap.x, ap.y, ap.width, ap.height, rgb(0xF0, 0xF4, 0xF8));

        fb.drawTextTransparent(ap.x + 16, ap.y + 16, "Windows Firewall", rgb(0x20, 0x40, 0x80));
        fb.drawHLine(ap.x + 16, ap.y + 40, ap.width - 32, rgb(0xC0, 0xC8, 0xD8));

        const status_color = if (ap.firewall_on) rgb(0x20, 0x80, 0x20) else rgb(0x80, 0x20, 0x20);
        const status_text = if (ap.firewall_on) "Firewall is ON" else "Firewall is OFF";
        fb.drawTextTransparent(ap.x + 20, ap.y + 60, status_text, status_color);

        const locations = [_][]const u8{ "Home network", "Work network", "Public networks" };
        var loc_y = ap.y + 100;
        for (locations) |loc| {
            fb.fillRect(ap.x + 20, loc_y, ap.width - 40, 50, rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(ap.x + 20, loc_y, ap.width - 40, 50, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(ap.x + 30, loc_y + 10, loc, rgb(0x10, 0x10, 0x10));
            fb.drawTextTransparent(ap.x + 30, loc_y + 28, if (ap.firewall_on) "Connected (firewall ON)" else "Connected (firewall OFF)", status_color);
            loc_y += 60;
        }

        fb.fillRect(ap.x + 20, loc_y + 10, ap.width - 40, 36, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(ap.x + 20, loc_y + 10, ap.width - 40, 36, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
        fb.drawTextTransparent(ap.x + 30, loc_y + 20, "Allow an app through Windows Firewall", rgb(0x10, 0x40, 0x90));
    }
};
