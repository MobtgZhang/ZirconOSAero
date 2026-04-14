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
// Module: src/desktop/applications/control_panel/applets/mouse.zig
// Purpose: Mouse settings Control Panel Applet
//
// This is an independent clean-room implementation.

const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const MouseApplet = struct {
    base: applet_base.ControlPanelApplet,
    left_handed: bool,
    double_click_speed: i32,
    pointer_speed: i32,
    pointer_scheme: PointerScheme,
    enable_hover_select: bool,
    show_pointer_trail: bool,
    hover_state: HoverArea,

    pub const PointerScheme = enum { aero_pointer, classic, hands, none };
    pub const HoverArea = enum { none, btn_apply, btn_cancel, scheme_aero, scheme_classic, scheme_hands };

    pub fn create(x: i32, y: i32, w: i32, h: i32) MouseApplet {
        return .{
            .base = applet_base.ControlPanelApplet.create(.mouse, x, y, w, h),
            .left_handed = false,
            .double_click_speed = 50,
            .pointer_speed = 50,
            .pointer_scheme = .aero_pointer,
            .enable_hover_select = false,
            .show_pointer_trail = false,
            .hover_state = .none,
        };
    }

    pub fn onMouseMove(_: *MouseApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *MouseApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Mouse Properties");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        // Buttons tab
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 120, "Buttons");
        applet.drawButtonsSection(client.x + 24, cy + 24, client.width - 48);
        cy += 140;

        // Pointers tab
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 100, "Pointers");
        applet.drawPointersSection(client.x + 24, cy + 24, client.width - 48);
        cy += 120;

        // Pointer Options
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 90, "Pointer Options");
        applet.drawPointerOptions(client.x + 24, cy + 24, client.width - 48);
        cy += 110;

        // Buttons
        applet.base.drawButton(client.x + 16, cy, 90, 28, "Apply", applet.hover_state == .btn_apply);
        applet.base.drawButton(client.x + 116, cy, 90, 28, "Cancel", applet.hover_state == .btn_cancel);
    }

    fn drawButtonsSection(applet: *MouseApplet, x: i32, y: i32, w: i32) void {
        const label1 = if (applet.left_handed) "Switch primary and secondary buttons" else "Left-handed";
        applet.base.drawCheckbox(x, y, label1, applet.left_handed);
        applet.base.drawCheckbox(x, y + 24, "Double-click speed:", applet.double_click_speed > 0);
        applet.base.drawSlider(x + 120, y + 28, w - 140, applet.double_click_speed, 0, 100);
        applet.base.drawCheckbox(x, y + 52, "ClickLock (hold down to select)", false);
    }

    fn drawPointersSection(applet: *MouseApplet, x: i32, y: i32, w: i32) void {
        const schemes = [_][]const u8{ "Aero Pointer", "Classic", "Hands" };
        const scheme_vals = [_]PointerScheme{ .aero_pointer, .classic, .hands };
        const btn_w = @divTrunc(w - 8, 3);

        applet.base.drawLabel(x, y, "Scheme:", rgb(0x20, 0x20, 0x30));

        inline for (schemes, 0..) |name, i| {
            const bx = x + @as(i32, @intCast(i)) * (btn_w + 4);
            const selected = (scheme_vals[i] == applet.pointer_scheme);
            const bg = if (selected) rgb(0xC8, 0xDC, 0xF0) else rgb(0xE8, 0xEC, 0xF4);
            fb.fillRect(bx, y + 20, btn_w, 36, bg);
            fb.draw3DRect(bx, y + 20, btn_w, 36, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 4, y + 30, name, rgb(0x20, 0x20, 0x30));
        }
    }

    fn drawPointerOptions(applet: *MouseApplet, x: i32, y: i32, w: i32) void {
        applet.base.drawLabel(x, y, "Select a pointer speed:", rgb(0x20, 0x20, 0x30));
        applet.base.drawSlider(x + 130, y + 4, w - 140, applet.pointer_speed, 0, 100);
        applet.base.drawCheckbox(x, y + 30, "Enhance pointer precision", true);
        applet.base.drawCheckbox(x, y + 54, "Show pointer trail", applet.show_pointer_trail);
        applet.base.drawCheckbox(x + 160, y + 54, "Hover select", applet.enable_hover_select);
    }
};
