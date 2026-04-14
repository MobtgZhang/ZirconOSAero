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
// Module: src/desktop/applications/control_panel/applets/keyboard.zig
// Purpose: Keyboard Settings Applet
//
// This is an independent clean-room implementation.

const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const KeyboardApplet = struct {
    base: applet_base.ControlPanelApplet,
    repeat_delay: i32,
    repeat_rate: i32,
    cursor_blink_rate: i32,
    hover_state: HoverArea,

    pub const HoverArea = enum { none, btn_apply, btn_cancel };

    pub fn create(x: i32, y: i32, w: i32, h: i32) KeyboardApplet {
        return .{
            .base = applet_base.ControlPanelApplet.create(.keyboard, x, y, w, h),
            .repeat_delay = 30,
            .repeat_rate = 50,
            .cursor_blink_rate = 50,
            .hover_state = .none,
        };
    }

    pub fn onMouseMove(_: *KeyboardApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *KeyboardApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Keyboard Settings");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 160, "Character Repeat");
        applet.drawRepeatSection(client.x + 24, cy + 24, client.width - 48);
        cy += 180;

        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 80, "Cursor Blink Rate");
        applet.drawCursorSection(client.x + 24, cy + 24, client.width - 48);
        cy += 100;

        applet.base.drawButton(client.x + 16, cy, 90, 28, "Apply", applet.hover_state == .btn_apply);
        applet.base.drawButton(client.x + 116, cy, 90, 28, "Cancel", applet.hover_state == .btn_cancel);
    }

    fn drawRepeatSection(applet: *KeyboardApplet, x: i32, y: i32, w: i32) void {
        applet.base.drawLabel(x, y, "Repeat delay:", rgb(0x20, 0x20, 0x30));
        applet.base.drawSlider(x + 110, y + 4, w - 140, applet.repeat_delay, 0, 100);

        applet.base.drawLabel(x, y + 40, "Repeat rate:", rgb(0x20, 0x20, 0x30));
        applet.base.drawSlider(x + 110, y + 44, w - 140, applet.repeat_rate, 0, 100);

        // Preview
        fb.fillRect(x, y + 90, w, 40, rgb(0xE8, 0xEC, 0xF0));
        fb.draw3DRect(x, y + 90, w, 40, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        applet.base.drawLabel(x + 8, y + 104, "Preview: type here...", rgb(0x60, 0x60, 0x70));
    }

    fn drawCursorSection(applet: *KeyboardApplet, x: i32, y: i32, w: i32) void {
        applet.base.drawLabel(x, y, "Cursor blink rate:", rgb(0x20, 0x20, 0x30));
        applet.base.drawSlider(x + 140, y + 4, w - 160, applet.cursor_blink_rate, 0, 100);

        // Slow --|----------|-- Fast
        applet.base.drawLabel(x, y + 30, "Slow", rgb(0x80, 0x80, 0x80));
        applet.base.drawLabel(x + w - 50, y + 30, "Fast", rgb(0x80, 0x80, 0x80));
    }
};
