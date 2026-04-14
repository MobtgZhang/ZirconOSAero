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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/system_tools/event_viewer.zig
// Purpose: Event Viewer - System event log viewer
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const EventLevel = enum { info, warning, err, critical };

pub const LogEvent = struct {
    id: u32,
    time: [32]u8,
    time_len: usize,
    source: [64]u8,
    source_len: usize,
    message: [256]u8,
    message_len: usize,
    level: EventLevel,
    event_id: u32,
};

pub const EventLog = enum {
    application,
    system,
    security,
};

pub const EventViewerApp = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,

    current_log: EventLog,
    events: [50]LogEvent,
    event_count: usize,
    selected_event: i32,

    hover_app_log: bool,
    hover_sys_log: bool,
    hover_sec_log: bool,
    hover_refresh: bool,
    hover_clear: bool,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) EventViewerApp {
        var app: EventViewerApp = .{
            .x = x_pos,
            .y = y_pos,
            .width = 800,
            .height = 500,
            .visible = true,
            .caption_hover = .none,
            .current_log = .system,
            .events = undefined,
            .event_count = 0,
            .selected_event = -1,
            .hover_app_log = false,
            .hover_sys_log = false,
            .hover_sec_log = false,
            .hover_refresh = false,
            .hover_clear = false,
        };

        app.initSampleEvents();
        return app;
    }

    fn initSampleEvents(app: *EventViewerApp) void {
        const samples = [_]struct { source: []const u8, msg: []const u8, level: EventLevel, id: u32 }{
            .{ .source = "Disk", .msg = "The driver successfully loaded.", .level = .info, .id = 1 },
            .{ .source = "Ntfs", .msg = "Volume C: is healthy.", .level = .info, .id = 2 },
            .{ .source = "EventLog", .msg = "The system has started.", .level = .info, .id = 3 },
            .{ .source = "Disk", .msg = "Disk write cache may be disabled.", .level = .warning, .id = 4 },
            .{ .source = "Ntfs", .msg = "Disk cleanup found some items to remove.", .level = .info, .id = 5 },
            .{ .source = "Kernel", .msg = "System time was synchronized.", .level = .info, .id = 6 },
            .{ .source = "ACPI", .msg = "Power button pressed.", .level = .info, .id = 7 },
            .{ .source = "StorPort", .msg = "Storage device initialization failed.", .level = .err, .id = 8 },
            .{ .source = "NetBT", .msg = "Network interface configuration updated.", .level = .info, .id = 9 },
            .{ .source = "W32Time", .msg = "Time service has started.", .level = .info, .id = 10 },
        };

        app.event_count = 0;
        for (samples, 0..) |s, i| {
            var evt = &app.events[i];
            evt.id = @as(u32, @intCast(i));

            @memcpy(evt.source[0..s.source.len], s.source);
            evt.source_len = s.source.len;

            @memcpy(evt.message[0..s.msg.len], s.msg);
            evt.message_len = s.msg.len;

            @memcpy(evt.time[0..5], "Apr ");
            evt.time[4] = '0' + @as(u8, @intCast((i % 9) + 1));
            evt.time[5] = ' ';
            evt.time[6] = '1' + @as(u8, @intCast((i * 3) % 9));
            evt.time[7] = ':';
            evt.time[8] = '0' + @as(u8, @intCast((i * 7) % 6));
            evt.time[9] = '0';
            evt.time[10] = ':';
            evt.time[11] = '0' + @as(u8, @intCast((i * 11) % 6));
            evt.time[12] = '0';
            evt.time_len = 13;

            evt.level = s.level;
            evt.event_id = s.id;

            app.event_count += 1;
        }
    }

    pub fn render(app: *const EventViewerApp, t: *const theme_mod.ThemeColors) void {
        if (!app.visible) return;
        _ = t;

        const wx = app.x;
        const wy = app.y;
        const ww = app.width;
        const wh = app.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 6, "Event Viewer", rgb(0xFF, 0xFF, 0xFF));

        const close_x = wx + ww - 48;
        if (app.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        // Sidebar - Log selection
        const sidebar_w: i32 = 150;
        fb.fillRect(wx, wy + 32, sidebar_w, wh - 32, rgb(0xF0, 0xF4, 0xF8));
        fb.drawRect(wx + sidebar_w, wy + 32, 1, wh - 32, rgb(0xCC, 0xCC, 0xCC));

        // Log type buttons
        const btn_x = wx + 10;
        var btn_y = wy + 45;

        fb.drawTextTransparent(btn_x, btn_y, "Windows Logs", rgb(0x20, 0x40, 0x80));
        btn_y += 22;

        // Application log
        const app_bg = if (app.hover_app_log) rgb(0xD0, 0xE0, 0xF0) else if (app.current_log == .application) rgb(0xC0, 0xD0, 0xE0) else rgb(0xE8, 0xEC, 0xF2);
        fb.fillRect(btn_x - 5, btn_y, sidebar_w - 10, 30, app_bg);
        fb.drawTextTransparent(btn_x + 5, btn_y + 8, "Application", rgb(0x20, 0x20, 0x30));

        btn_y += 35;

        // System log
        const sys_bg = if (app.hover_sys_log) rgb(0xD0, 0xE0, 0xF0) else if (app.current_log == .system) rgb(0xC0, 0xD0, 0xE0) else rgb(0xE8, 0xEC, 0xF2);
        fb.fillRect(btn_x - 5, btn_y, sidebar_w - 10, 30, sys_bg);
        fb.drawTextTransparent(btn_x + 5, btn_y + 8, "System", rgb(0x20, 0x20, 0x30));

        btn_y += 35;

        // Security log
        const sec_bg = if (app.hover_sec_log) rgb(0xD0, 0xE0, 0xF0) else if (app.current_log == .security) rgb(0xC0, 0xD0, 0xE0) else rgb(0xE8, 0xEC, 0xF2);
        fb.fillRect(btn_x - 5, btn_y, sidebar_w - 10, 30, sec_bg);
        fb.drawTextTransparent(btn_x + 5, btn_y + 8, "Security", rgb(0x20, 0x20, 0x30));

        // Main content area
        const content_x = wx + sidebar_w + 1;
        const content_w = ww - sidebar_w - 1;

        // Toolbar
        const toolbar_y = wy + 35;
        fb.fillRect(content_x, toolbar_y, content_w, 35, rgb(0xF5, 0xF5, 0xF5));
        fb.drawHLine(content_x, toolbar_y + 35, content_w, rgb(0xCC, 0xCC, 0xCC));

        // Log name
        const log_name: []const u8 = switch (app.current_log) {
            .application => "Application",
            .system => "System",
            .security => "Security",
        };
        fb.drawTextTransparent(content_x + 10, toolbar_y + 10, log_name, rgb(0x18, 0x18, 0x20));

        // Refresh button
        const ref_x = content_x + content_w - 90;
        fb.fillRect(ref_x, toolbar_y + 5, 75, 26, if (app.hover_refresh) rgb(0xD0, 0xD0, 0xD0) else rgb(0xE8, 0xE8, 0xE8));
        fb.draw3DRect(ref_x, toolbar_y + 5, 75, 26, rgb(0xB0, 0xB0, 0xB0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(ref_x + 20, toolbar_y + 12, "Refresh", rgb(0x30, 0x30, 0x40));

        // Clear log button
        fb.fillRect(ref_x - 85, toolbar_y + 5, 75, 26, if (app.hover_clear) rgb(0xC0, 0x60, 0x60) else rgb(0xE8, 0xE8, 0xE8));
        fb.draw3DRect(ref_x - 85, toolbar_y + 5, 75, 26, rgb(0xB0, 0x50, 0x50), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(ref_x - 70, toolbar_y + 12, "Clear Log", rgb(0x40, 0x30, 0x30));

        // Event list header
        const header_y = toolbar_y + 40;
        fb.fillRect(content_x, header_y, content_w, 25, rgb(0xE8, 0xEC, 0xF0));

        fb.drawTextTransparent(content_x + 10, header_y + 6, "Level", rgb(0x40, 0x50, 0x60));
        fb.drawTextTransparent(content_x + 70, header_y + 6, "Date and Time", rgb(0x40, 0x50, 0x60));
        fb.drawTextTransparent(content_x + 220, header_y + 6, "Source", rgb(0x40, 0x50, 0x60));
        fb.drawTextTransparent(content_x + 350, header_y + 6, "Event ID", rgb(0x40, 0x50, 0x60));
        fb.drawTextTransparent(content_x + 450, header_y + 6, "Task Category", rgb(0x40, 0x50, 0x60));

        // Event list
        const list_y = header_y + 25;
        const item_h: i32 = 30;

        for (0..app.event_count) |i| {
            const item_y = list_y + @as(i32, @intCast(i)) * item_h;
            if (item_y > wy + wh - 60) break;

            const evt = app.events[i];
            const is_selected = @as(i32, @intCast(i)) == app.selected_event;

            // Row background
            var row_bg = rgb(0xFF, 0xFF, 0xFF);
            if (is_selected) {
                row_bg = rgb(0xD8, 0xE8, 0xF8);
            }
            fb.fillRect(content_x, item_y, content_w, item_h, row_bg);
            fb.drawHLine(content_x, item_y + item_h, content_w, rgb(0xE0, 0xE0, 0xE0));

            // Level icon
            const level_color: u32 = switch (evt.level) {
                .info => rgb(0x00, 0x78, 0xD4),
                .warning => rgb(0xE0, 0xA0, 0x00),
                .err => rgb(0xD0, 0x40, 0x40),
                .critical => rgb(0xA0, 0x00, 0x00),
            };
            fb.fillRect(content_x + 10, item_y + 10, 8, 8, level_color);

            // Date and time
            fb.drawTextTransparent(content_x + 70, item_y + 8, evt.time[0..evt.time_len], rgb(0x40, 0x40, 0x50));

            // Source
            fb.drawTextTransparent(content_x + 220, item_y + 8, evt.source[0..evt.source_len], rgb(0x20, 0x20, 0x30));

            // Event ID
            var id_buf: [16]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{evt.event_id}) catch "";
            fb.drawTextTransparent(content_x + 350, item_y + 8, id_str, rgb(0x40, 0x40, 0x50));

            // Category
            fb.drawTextTransparent(content_x + 450, item_y + 8, "General", rgb(0x60, 0x60, 0x70));
        }

        // Details pane
        const details_y = wy + wh - 120;
        fb.fillRect(wx, details_y, ww, 120, rgb(0xF8, 0xF8, 0xFC));
        fb.drawHLine(wx, details_y, ww, rgb(0xCC, 0xCC, 0xCC));

        if (app.selected_event >= 0) {
            const idx = @as(usize, @intCast(app.selected_event));
            if (idx < app.event_count) {
                const evt = app.events[idx];

                fb.drawTextTransparent(wx + 10, details_y + 10, "Event Properties", rgb(0x20, 0x40, 0x80));

                fb.drawTextTransparent(wx + 10, details_y + 35, "General", rgb(0x40, 0x40, 0x50));

                fb.drawTextTransparent(wx + 10, details_y + 55, "Message:", rgb(0x60, 0x60, 0x70));
                fb.drawTextTransparent(wx + 80, details_y + 55, evt.message[0..evt.message_len], rgb(0x30, 0x30, 0x40));

                fb.drawTextTransparent(wx + 10, details_y + 75, "Source:", rgb(0x60, 0x60, 0x70));
                fb.drawTextTransparent(wx + 80, details_y + 75, evt.source[0..evt.source_len], rgb(0x30, 0x30, 0x40));

                fb.drawTextTransparent(wx + 300, details_y + 55, "Event ID:", rgb(0x60, 0x60, 0x70));
                var id_buf: [16]u8 = undefined;
                const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{evt.event_id}) catch "";
                fb.drawTextTransparent(wx + 380, details_y + 55, id_str, rgb(0x30, 0x30, 0x40));
            }
        }
    }

    pub fn handleClick(app: *EventViewerApp, px: i32, py: i32) void {
        const wx = app.x;
        const wy = app.y;

        const sidebar_w: i32 = 150;

        // Sidebar clicks
        if (px >= wx and px < wx + sidebar_w) {
            if (py >= wy + 68 and py < wy + 98) {
                app.current_log = .application;
                app.selected_event = -1;
            } else if (py >= wy + 103 and py < wy + 133) {
                app.current_log = .system;
                app.selected_event = -1;
            } else if (py >= wy + 138 and py < wy + 168) {
                app.current_log = .security;
                app.selected_event = -1;
            }
            return;
        }

        // Content area clicks
        const content_x = wx + sidebar_w + 1;
        const header_y = wy + 110;
        const item_h: i32 = 30;

        if (py >= header_y + 25 and px >= content_x) {
            const idx = @divTrunc(py - header_y - 25, item_h);
            if (idx >= 0 and @as(usize, @intCast(idx)) < app.event_count) {
                app.selected_event = @as(i32, @intCast(idx));
            }
        }
    }

    pub fn handleMouseMove(app: *EventViewerApp, px: i32, py: i32) void {
        const wx = app.x;
        const wy = app.y;
        const ww = app.width;

        const sidebar_w: i32 = 150;

        app.hover_app_log = (px >= wx and px < wx + sidebar_w and py >= wy + 68 and py < wy + 98);
        app.hover_sys_log = (px >= wx and px < wx + sidebar_w and py >= wy + 103 and py < wy + 133);
        app.hover_sec_log = (px >= wx and px < wx + sidebar_w and py >= wy + 138 and py < wy + 168);

        const content_x = wx + sidebar_w + 1;
        const ref_x = content_x + ww - sidebar_w - 90;
        app.hover_refresh = (px >= ref_x and px < ref_x + 75 and py >= wy + 40 and py < wy + 66);
        app.hover_clear = (px >= ref_x - 85 and px < ref_x - 10 and py >= wy + 40 and py < wy + 66);
    }
};
