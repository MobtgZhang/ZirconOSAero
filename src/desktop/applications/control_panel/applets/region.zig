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
// Module: src/desktop/applications/control_panel/applets/region.zig
// Purpose: Region and Language Settings Applet
//
// This is an independent clean-room implementation.

const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const RegionApplet = struct {
    base: applet_base.ControlPanelApplet,
    selected_country: usize,
    selected_language: usize,
    short_date_format: i32,
    long_date_format: i32,
    hover_state: HoverArea,

    pub const HoverArea = enum { none, btn_apply, btn_cancel, country_item };

    pub fn create(x: i32, y: i32, w: i32, h: i32) RegionApplet {
        return .{
            .base = applet_base.ControlPanelApplet.create(.region, x, y, w, h),
            .selected_country = 0,
            .selected_language = 0,
            .short_date_format = 0,
            .long_date_format = 0,
            .hover_state = .none,
        };
    }

    pub fn onMouseMove(_: *RegionApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *RegionApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Region and Language");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 140, "Formats");
        applet.drawFormatsSection(client.x + 24, cy + 24, client.width - 48);
        cy += 160;

        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 100, "Location");
        applet.drawLocationSection(client.x + 24, cy + 24, client.width - 48);
        cy += 120;

        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 80, "Administrative");
        applet.drawAdminSection(client.x + 24, cy + 24, client.width - 48);
        cy += 100;

        applet.base.drawButton(client.x + 16, cy, 90, 28, "Apply", applet.hover_state == .btn_apply);
        applet.base.drawButton(client.x + 116, cy, 90, 28, "Cancel", applet.hover_state == .btn_cancel);
    }

    fn drawFormatsSection(applet: *RegionApplet, x: i32, y: i32, w: i32) void {
        const formats = [_][]const u8{
            "English (United States)",
            "English (United Kingdom)",
            "Chinese (Simplified, PRC)",
            "Chinese (Traditional, Taiwan)",
            "Japanese",
            "Korean",
        };
        const date_formats = [_][]const u8{
            "M/d/yyyy",
            "dd/MM/yyyy",
            "yyyy-MM-dd",
            "dd.MM.yyyy",
        };

        applet.base.drawLabel(x, y, "Format:", rgb(0x20, 0x20, 0x30));
        for (formats, 0..) |fmt, i| {
            const selected = (@as(usize, @intCast(i)) == applet.selected_language);
            applet.base.drawListItem(x, y + 20 + @as(i32, @intCast(i)) * 28, w - 120, fmt, selected, null);
        }

        const dx = x + w - 110;
        applet.base.drawLabel(dx, y, "Short date:", rgb(0x20, 0x20, 0x30));
        applet.base.drawLabel(dx, y + 60, "Long date:", rgb(0x20, 0x20, 0x30));
        applet.base.drawCheckbox(dx, y + 24, date_formats[0], applet.short_date_format == 0);
        applet.base.drawCheckbox(dx, y + 84, date_formats[1], applet.long_date_format == 0);
    }

    fn drawLocationSection(applet: *RegionApplet, x: i32, y: i32, w: i32) void {
        const locations = [_][]const u8{ "United States", "United Kingdom", "China", "Japan", "Korea" };
        const btn_w = @divTrunc(w - 8, 5);

        inline for (locations, 0..) |loc, i| {
            const bx = x + @as(i32, @intCast(i)) * (btn_w + 2);
            const selected = (@as(usize, @intCast(i)) == applet.selected_country);
            const bg = if (selected) rgb(0xC8, 0xDC, 0xF0) else rgb(0xE8, 0xEC, 0xF4);
            fb.fillRect(bx, y, btn_w, 50, bg);
            fb.draw3DRect(bx, y, btn_w, 50, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 4, y + 18, loc, rgb(0x20, 0x20, 0x30));
        }
    }

    fn drawAdminSection(applet: *RegionApplet, x: i32, y: i32, w: i32) void {
        _ = w;
        applet.base.drawCheckbox(x, y, "Welcome screen and new user accounts", true);
        applet.base.drawCheckbox(x, y + 24, "Copy your settings to system account", false);
    }
};
