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
// Module: src/desktop/applications/mail/calendar.zig
// Purpose: Windows Calendar - Calendar application
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const CalendarEvent = struct {
    id: u32,
    title: [64]u8,
    title_len: usize,
    location: [64]u8,
    location_len: usize,
    start_time: u32,
    end_time: u32,
    all_day: bool,
    reminder: u8,
    color: u32,
};

pub const CalendarView = enum {
    month,
    week,
    day,
};

pub const CalendarApp = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    
    current_view: CalendarView,
    current_month: u8,
    current_day: u8,
    current_year: u16,
    selected_date: u8,
    
    events: [20]CalendarEvent,
    event_count: usize,
    selected_event: i32,
    
    hover_today: bool,
    hover_prev: bool,
    hover_next: bool,
    hover_add: bool,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) CalendarApp {
        return .{
            .x = x_pos, .y = y_pos,
            .width = 700, .height = 500,
            .visible = true, .caption_hover = .none,
            .current_view = .month,
            .current_month = 4, // April
            .current_day = 13,
            .current_year = 2026,
            .selected_date = 13,
            .events = undefined, .event_count = 0,
            .selected_event = -1,
            .hover_today = false, .hover_prev = false,
            .hover_next = false, .hover_add = false,
        };
    }

    pub fn render(app: *const CalendarApp, t: *const theme_mod.ThemeColors) void {
        if (!app.visible) return;
        _ = t;

        const wx = app.x;
        const wy = app.y;
        const ww = app.width;
        const wh = app.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x00, 0x64, 0xC4), rgb(0x00, 0x88, 0xE8));
        fb.drawTextTransparent(wx + 8, wy + 6, "Calendar", rgb(0xFF, 0xFF, 0xFF));

        const close_x = wx + ww - 48;
        if (app.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        // Header section
        const header_y = wy + 40;
        
        // Navigation buttons
        const nav_btn_w: i32 = 35;
        const nav_btn_h: i32 = 28;
        
        // Previous month
        fb.fillRect(wx + 10, header_y, nav_btn_w, nav_btn_h, if (app.hover_prev) rgb(0xD0, 0xD0, 0xD0) else rgb(0xE8, 0xE8, 0xE8));
        fb.draw3DRect(wx + 10, header_y, nav_btn_w, nav_btn_h, rgb(0xB0, 0xB0, 0xB0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(wx + 18, header_y + 8, "<", rgb(0x40, 0x40, 0x50));
        
        // Next month
        fb.fillRect(wx + 50, header_y, nav_btn_w, nav_btn_h, if (app.hover_next) rgb(0xD0, 0xD0, 0xD0) else rgb(0xE8, 0xE8, 0xE8));
        fb.draw3DRect(wx + 50, header_y, nav_btn_w, nav_btn_h, rgb(0xB0, 0xB0, 0xB0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(wx + 58, header_y + 8, ">", rgb(0x40, 0x40, 0x50));
        
        // Month/Year display
        const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
        const month_name = months[@as(usize, @intCast(app.current_month - 1))];
        
        var date_buf: [64]u8 = undefined;
        const date_str = std.fmt.bufPrint(&date_buf, "{s} {d}", .{ month_name, app.current_year }) catch "";
        fb.drawTextTransparent(wx + 100, header_y + 6, date_str, rgb(0x18, 0x18, 0x20));
        
        // Today button
        fb.fillRect(wx + ww - 90, header_y, 80, nav_btn_h, if (app.hover_today) rgb(0x60, 0x90, 0xC0) else rgb(0x40, 0x70, 0xA0));
        fb.draw3DRect(wx + ww - 90, header_y, 80, nav_btn_h, rgb(0x30, 0x60, 0x90), rgb(0x80, 0xB0, 0xE0));
        fb.drawTextTransparent(wx + ww - 75, header_y + 8, "Today", rgb(0xFF, 0xFF, 0xFF));
        
        // Add event button
        fb.fillRect(wx + ww - 180, header_y, 80, nav_btn_h, if (app.hover_add) rgb(0x60, 0xA0, 0x60) else rgb(0x40, 0x80, 0x40));
        fb.draw3DRect(wx + ww - 180, header_y, 80, nav_btn_h, rgb(0x30, 0x70, 0x30), rgb(0x80, 0xC0, 0x80));
        fb.drawTextTransparent(wx + ww - 170, header_y + 8, "+ Add", rgb(0xFF, 0xFF, 0xFF));
        
        // Day of week headers
        const cal_y = header_y + 45;
        const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const cell_w: i32 = (ww - 20) / 7;
        const cell_h: i32 = (wh - cal_y - wy - 10) / 6;
        
        for (days, 0..) |day, i| {
            const day_x = wx + 10 + @as(i32, @intCast(i)) * cell_w;
            fb.fillRect(day_x, cal_y, cell_w, 25, rgb(0xF0, 0xF4, 0xF8));
            fb.drawTextTransparent(day_x + cell_w/2 - 15, cal_y + 6, day, rgb(0x40, 0x50, 0x60));
        }
        
        // Calendar grid
        const grid_y = cal_y + 25;
        const first_day = app.getFirstDayOfMonth();
        const days_in_month = app.getDaysInMonth();
        
        var day_num: u8 = 1;
        var week: i32 = 0;
        
        while (week < 6 and day_num <= days_in_month) {
            var day_of_week: i32 = 0;
            
            while (day_of_week < 7) {
                if (week == 0 and day_of_week < first_day) {
                    // Empty cell before first day
                    day_of_week += 1;
                    continue;
                }
                
                if (day_num > days_in_month) break;
                
                const cell_x = wx + 10 + day_of_week * cell_w;
                const cell_y = grid_y + week * cell_h;
                
                // Cell background
                var cell_bg = rgb(0xFF, 0xFF, 0xFF);
                if (day_num == app.current_day) {
                    cell_bg = rgb(0xD0, 0xE8, 0xFF);
                }
                if (day_num == app.selected_date) {
                    cell_bg = rgb(0x00, 0x78, 0xD4);
                }
                fb.fillRect(cell_x, cell_y, cell_w, cell_h, cell_bg);
                
                // Day number
                const num_color = if (day_num == app.selected_date) rgb(0xFF, 0xFF, 0xFF) else rgb(0x18, 0x18, 0x20);
                var num_buf: [4]u8 = undefined;
                const num_str2 = std.fmt.bufPrint(&num_buf, "{d}", .{day_num}) catch "";
                fb.drawTextTransparent(cell_x + 5, cell_y + 5, num_str2, num_color);
                
                // Event indicators
                var event_count = 0;
                for (0..app.event_count) |e| {
                    if (app.events[e].start_time == day_num) {
                        event_count += 1;
                    }
                }
                
                if (event_count > 0) {
                    var evt_buf: [8]u8 = undefined;
                    const evt_str = std.fmt.bufPrint(&evt_buf, "+{d}", .{event_count}) catch "";
                    const evt_color = if (day_num == app.selected_date) rgb(0xE0, 0xF0, 0xFF) else rgb(0x00, 0x78, 0xD4);
                    fb.drawTextTransparent(cell_x + 5, cell_y + cell_h - 20, evt_str, evt_color);
                }
                
                day_num += 1;
                day_of_week += 1;
            }
            week += 1;
        }
    }

    fn getFirstDayOfMonth(app: *const CalendarApp) i32 {
        // Zeller's congruence simplified for month/year
        const m = app.current_month;
        const y = app.current_year;
        var yy = y;
        var mm = m;
        
        if (mm < 3) {
            mm += 12;
            yy -= 1;
        }
        
        const k = yy % 100;
        const j = yy / 100;
        
        const h = (1 + @divTrunc(13 * (mm + 1), 5) + k + @divTrunc(k, 4) + @divTrunc(j, 4) + 5 * @as(i32, @intCast(j))) % 7;
        return (h + 6) % 7; // Convert to Sunday = 0
    }

    fn getDaysInMonth(app: *const CalendarApp) u8 {
        const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        
        // Leap year check
        if (app.current_month == 2) {
            const y = app.current_year;
            if ((y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)) {
                return 29;
            }
        }
        
        return days[@as(usize, @intCast(app.current_month - 1))];
    }

    pub fn handleMouseMove(app: *CalendarApp, px: i32, py: i32) void {
        const wx = app.x;
        const wy = app.y;
        const ww = app.width;
        
        app.hover_prev = (px >= wx + 10 and px < wx + 45 and py >= wy + 40 and py < wy + 68);
        app.hover_next = (px >= wx + 50 and px < wx + 85 and py >= wy + 40 and py < wy + 68);
        app.hover_today = (px >= wx + ww - 90 and px < wx + ww - 10 and py >= wy + 40 and py < wy + 68);
        app.hover_add = (px >= wx + ww - 180 and px < wx + ww - 100 and py >= wy + 40 and py < wy + 68);
    }

    pub fn handleClick(app: *CalendarApp, px: i32, py: i32) void {
        const wx = app.x;
        const wy = app.y;
        const ww = app.width;
        
        // Navigation buttons
        if (app.hover_prev) {
            if (app.current_month == 1) {
                app.current_month = 12;
                app.current_year -= 1;
            } else {
                app.current_month -= 1;
            }
            return;
        }
        
        if (app.hover_next) {
            if (app.current_month == 12) {
                app.current_month = 1;
                app.current_year += 1;
            } else {
                app.current_month += 1;
            }
            return;
        }
        
        if (app.hover_today) {
            app.selected_date = app.current_day;
            return;
        }
        
        if (app.hover_add) {
            // Would show add event dialog
            return;
        }
        
        // Calendar grid click
        const cal_y = wy + 113;
        const cell_w: i32 = (ww - 20) / 7;
        const cell_h: i32 = (app.height - cal_y + wy - 10) / 6;
        
        if (py >= cal_y and px >= wx + 10) {
            const day_of_week = @divTrunc(px - wx - 10, cell_w);
            const week = @divTrunc(py - cal_y, cell_h);
            
            const first_day = app.getFirstDayOfMonth();
            const day_offset = week * 7 + day_of_week - first_day;
            
            if (day_offset >= 0 and @as(u8, @intCast(day_offset)) < app.getDaysInMonth()) {
                app.selected_date = @as(u8, @intCast(day_offset)) + 1;
            }
        }
    }
};
