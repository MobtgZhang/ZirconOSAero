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
// Module: src/desktop/applications/control_panel/applets/default_programs.zig
// Purpose: Default Programs Settings Applet
//
// This is an clean-room implementation.

const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const DefaultProgramsApplet = struct {
    base: applet_base.ControlPanelApplet,
    selected_page: Page,
    hover_state: HoverArea,

    pub const Page = enum { set_default, associate_file, auto_play };

    pub const HoverArea = enum { none, btn_apply, btn_cancel, page_set_default, page_associate, page_autoplay };

    pub fn create(x: i32, y: i32, w: i32, h: i32) DefaultProgramsApplet {
        return .{
            .base = applet_base.ControlPanelApplet.create(.default_programs, x, y, w, h),
            .selected_page = .set_default,
            .hover_state = .none,
        };
    }

    pub fn onMouseMove(_: *DefaultProgramsApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *DefaultProgramsApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Default Programs");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        // Page selector
        applet.drawPageSelector(client.x + 16, cy, client.width - 32);
        cy += 80;

        // Page content
        switch (applet.selected_page) {
            .set_default => applet.drawSetDefaultPage(client.x + 16, cy, client.width - 32),
            .associate_file => applet.drawAssociateFilePage(client.x + 16, cy, client.width - 32),
            .auto_play => applet.drawAutoPlayPage(client.x + 16, cy, client.width - 32),
        }
    }

    fn drawPageSelector(applet: *DefaultProgramsApplet, x: i32, y: i32, w: i32) void {
        const pages = [_][]const u8{
            "Set Default Programs",
            "Associate a file type or protocol with a program",
            "Change AutoPlay settings",
        };
        const page_vals = [_]Page{ .set_default, .associate_file, .auto_play };
        const btn_w = @divTrunc(w - 8, 3);

        inline for (pages, 0..) |name, i| {
            const bx = x + @as(i32, @intCast(i)) * (btn_w + 4);
            const selected = (page_vals[i] == applet.selected_page);
            const hovered = switch (page_vals[i]) {
                .set_default => applet.hover_state == .page_set_default,
                .associate_file => applet.hover_state == .page_associate,
                .auto_play => applet.hover_state == .page_autoplay,
            };
            const bg = if (selected) rgb(0xC8, 0xDC, 0xF0) else if (hovered) rgb(0xE8, 0xEC, 0xF4) else rgb(0xF0, 0xF4, 0xF8);
            fb.fillRect(bx, y, btn_w, 60, bg);
            fb.draw3DRect(bx, y, btn_w, 60, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 4, y + 20, name, rgb(0x20, 0x20, 0x30));
        }
    }

    fn drawSetDefaultPage(applet: *DefaultProgramsApplet, x: i32, y: i32, w: i32) void {
        const h: i32 = 280;
        applet.base.drawGroupBox(x, y, w, h, "Set Program Associations");
        fb.fillRect(x + 8, y + 24, w - 16, h - 32, rgb(0xFF, 0xFF, 0xFF));

        const programs = [_][]const u8{
            "Notepad",
            "Calculator",
            "Paint",
            "Media Player",
            "IE Browser",
        };

        for (programs, 0..) |name, i| {
            const py = y + 30 + @as(i32, @intCast(i)) * 44;
            const selected = (i == 0);
            applet.base.drawListItem(x + 8, py, w - 16, name, selected, null);
            applet.base.drawButton(x + w - 140, py, 100, 28, "Set Default", false);
        }
    }

    fn drawAssociateFilePage(applet: *DefaultProgramsApplet, x: i32, y: i32, w: i32) void {
        const h: i32 = 280;
        applet.base.drawGroupBox(x, y, w, h, "Set Associations");
        applet.base.drawLabel(x + 12, y + 30, "Select an extension:", rgb(0x20, 0x20, 0x30));
        applet.base.drawLabel(x + 12, y + 100, "Current default:", rgb(0x20, 0x20, 0x30));
        applet.base.drawLabel(x + 140, y + 100, "Notepad", rgb(0x10, 0x10, 0x20));
        applet.base.drawButton(x + w - 200, y + 80, 180, 28, "Change Program...", false);
    }

    fn drawAutoPlayPage(applet: *DefaultProgramsApplet, x: i32, y: i32, w: i32) void {
        const h: i32 = 280;
        applet.base.drawGroupBox(x, y, w, h, "AutoPlay");
        applet.base.drawCheckbox(x + 12, y + 30, "Use AutoPlay for all media and devices", true);
        applet.base.drawLabel(x + 12, y + 70, "Choose a default:", rgb(0x20, 0x20, 0x30));

        const options = [_][]const u8{ "Take no action", "Ask me every time", "Open folder to view files", "Play using Windows Media Player" };
        for (options, 0..) |opt, i| {
            applet.base.drawRadioButton(x + 12, y + 90 + @as(i32, @intCast(i)) * 30, opt, i == 1);
        }
    }
};
