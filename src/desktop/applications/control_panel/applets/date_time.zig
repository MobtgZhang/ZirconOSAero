// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/date_time.zig
// Purpose: Date and Time Settings Applet
//
// This is an independent clean-room implementation.

const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const DateTimeApplet = struct {
    base: applet_base.ControlPanelApplet,
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,
    selected_timezone: usize,
    sync_enabled: bool,
    hover_state: HoverArea,

    pub const HoverArea = enum { none, btn_apply, btn_cancel, btn_sync, calendar_day };

    pub fn create(x: i32, y: i32, w: i32, h: i32) DateTimeApplet {
        return .{
            .base = applet_base.ControlPanelApplet.create(.date_time, x, y, w, h),
            .year = 2026,
            .month = 4,
            .day = 11,
            .hour = 12,
            .minute = 0,
            .second = 0,
            .selected_timezone = 0,
            .sync_enabled = true,
            .hover_state = .none,
        };
    }

    pub fn onMouseMove(_: *DateTimeApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *DateTimeApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Date and Time");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        applet.base.drawGroupBox(client.x + 16, cy, 280, 200, "Date and Time");
        applet.drawDateTimeSection(client.x + 24, cy + 24, 260);
        cy += 220;

        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 90, "Time Zone");
        applet.drawTimeZoneSection(client.x + 24, cy + 24, client.width - 48);
        cy += 110;

        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 80, "Internet Time");
        applet.drawInternetTimeSection(client.x + 24, cy + 24, client.width - 48);
        cy += 100;

        applet.base.drawButton(client.x + 16, cy, 90, 28, "OK", applet.hover_state == .btn_apply);
        applet.base.drawButton(client.x + 116, cy, 90, 28, "Cancel", applet.hover_state == .btn_cancel);
    }

    fn drawDateTimeSection(applet: *DateTimeApplet, x: i32, y: i32, w: i32) void {
        // Calendar preview
        _ = w;
        const cal_x = x;
        const cal_y = y;
        fb.fillRect(cal_x, cal_y, 200, 160, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(cal_x, cal_y, 200, 160, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        applet.base.drawLabel(cal_x + 60, cal_y + 4, "April 2026", rgb(0x20, 0x20, 0x30));

        const days = [_][]const u8{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" };
        inline for (days, 0..) |d, i| {
            applet.base.drawLabel(cal_x + 8 + @as(i32, @intCast(i)) * 26, cal_y + 22, d, rgb(0x40, 0x40, 0x50));
        }

        // Time setting
        const time_x = x + 210;
        const time_y = y;

        applet.base.drawLabel(time_x, time_y, "Time:", rgb(0x20, 0x20, 0x30));
        var time_buf: [16]u8 = undefined;
        const std = @import("std");
        const time_str = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ applet.hour, applet.minute, applet.second }) catch "12:00:00";
        applet.base.drawLabel(time_x, time_y + 20, time_str, rgb(0x10, 0x10, 0x20));

        applet.base.drawLabel(time_x, time_y + 60, "Date:", rgb(0x20, 0x20, 0x30));
        var date_buf: [32]u8 = undefined;
        const date_str = std.fmt.bufPrint(&date_buf, "{d}/{d}/{d}", .{ applet.month, applet.day, applet.year }) catch "4/11/2026";
        applet.base.drawLabel(time_x, time_y + 80, date_str, rgb(0x10, 0x10, 0x20));

        applet.base.drawButton(time_x, time_y + 130, 60, 24, "Change", false);
    }

    fn drawTimeZoneSection(applet: *DateTimeApplet, x: i32, y: i32, w: i32) void {
        _ = w;
        const timezones = [_][]const u8{
            "(UTC-08:00) Pacific Time",
            "(UTC-05:00) Eastern Time",
            "(UTC+00:00) London",
            "(UTC+08:00) Beijing",
            "(UTC+09:00) Tokyo",
        };

        applet.base.drawCheckbox(x, y, "Automatically adjust clock for Daylight Saving Time", true);
        applet.base.drawLabel(x, y + 28, "Time zone:", rgb(0x20, 0x20, 0x30));
        applet.base.drawLabel(x + 80, y + 28, timezones[applet.selected_timezone], rgb(0x10, 0x10, 0x20));
    }

    fn drawInternetTimeSection(applet: *DateTimeApplet, x: i32, y: i32, w: i32) void {
        _ = w;
        applet.base.drawCheckbox(x, y, "Synchronize with an Internet time server", applet.sync_enabled);
        applet.base.drawButton(x + 300, y, 80, 24, "Update Now", applet.hover_state == .btn_sync);
    }
};
