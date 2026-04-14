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
// Module: src/desktop/applications/control_panel/applets/power_options.zig
// Purpose: Power Options Control Panel Applet
//
// This is an independent clean-room implementation.

const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const PowerOptionsApplet = struct {
    base: applet_base.ControlPanelApplet,
    selected_plan: Plan,
    brightness: i32,
    lid_action: LidAction,
    power_button_action: PowerButtonAction,
    sleep_timeout: i32,
    display_timeout: i32,
    hover_state: HoverArea,

    pub const Plan = enum { balanced, high_perf, power_saver };

    pub const LidAction = enum { do_nothing, sleep, hibernate, shutdown };
    pub const PowerButtonAction = enum { do_nothing, sleep, hibernate, shutdown, lock };

    pub const HoverArea = enum { none, btn_apply, btn_cancel, plan_balanced, plan_perf, plan_saver };

    pub fn create(x: i32, y: i32, w: i32, h: i32) PowerOptionsApplet {
        return .{
            .base = applet_base.ControlPanelApplet.create(.power_options, x, y, w, h),
            .selected_plan = .balanced,
            .brightness = 80,
            .lid_action = .sleep,
            .power_button_action = .shutdown,
            .sleep_timeout = 30,
            .display_timeout = 15,
            .hover_state = .none,
        };
    }

    pub fn onMouseMove(_: *PowerOptionsApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *PowerOptionsApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Power Options");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        // Plans
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 140, "Select a Power Plan");
        applet.drawPlansSection(client.x + 24, cy + 24, client.width - 48);
        cy += 160;

        // Brightness
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 80, "Display Brightness");
        applet.drawBrightnessSection(client.x + 24, cy + 24, client.width - 48);
        cy += 100;

        // Sleep settings
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 100, "Sleep");
        applet.drawSleepSection(client.x + 24, cy + 24, client.width - 48);
        cy += 120;

        // Power buttons
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 100, "Power Button Actions");
        applet.drawPowerButtonsSection(client.x + 24, cy + 24, client.width - 48);
        cy += 120;

        applet.base.drawButton(client.x + 16, cy, 90, 28, "Apply", applet.hover_state == .btn_apply);
        applet.base.drawButton(client.x + 116, cy, 90, 28, "Cancel", applet.hover_state == .btn_cancel);
    }

    fn drawPlansSection(applet: *PowerOptionsApplet, x: i32, y: i32, w: i32) void {
        const plans = [_][]const u8{
            "Balanced (Recommended)",
            "High performance",
            "Power saver",
        };
        const plan_vals = [_]Plan{ .balanced, .high_perf, .power_saver };
        const descriptions = [_][]const u8{
            "Automatically balances performance with energy consumption",
            "Maximizes processor performance",
            "Saves energy by reducing performance",
        };
        const btn_w = @divTrunc(w - 8, 3);

        inline for (plans, 0..) |name, i| {
            const bx = x + @as(i32, @intCast(i)) * (btn_w + 4);
            const selected = (plan_vals[i] == applet.selected_plan);
            const hovered = switch (plan_vals[i]) {
                .balanced => applet.hover_state == .plan_balanced,
                .high_perf => applet.hover_state == .plan_perf,
                .power_saver => applet.hover_state == .plan_saver,
            };
            const bg = if (selected) rgb(0xC8, 0xDC, 0xF0) else if (hovered) rgb(0xE8, 0xEC, 0xF4) else rgb(0xF0, 0xF4, 0xF8);

            fb.fillRect(bx, y, btn_w, 100, bg);
            fb.draw3DRect(bx, y, btn_w, 100, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 8, y + 8, name, rgb(0x20, 0x20, 0x30));
            fb.drawTextTransparent(bx + 8, y + 50, descriptions[i], rgb(0x60, 0x60, 0x70));

            if (selected) {
                fb.drawTextTransparent(bx + 8, y + 85, "[ Active ]", rgb(0x10, 0x60, 0x20));
            }
        }
    }

    fn drawBrightnessSection(applet: *PowerOptionsApplet, x: i32, y: i32, w: i32) void {
        applet.base.drawLabel(x, y, "Adjust brightness:", rgb(0x20, 0x20, 0x30));
        applet.base.drawSlider(x + 120, y + 4, w - 140, applet.brightness, 0, 100);
    }

    fn drawSleepSection(applet: *PowerOptionsApplet, x: i32, y: i32, w: i32) void {
        _ = w;
        applet.base.drawLabel(x, y, "Sleep after:", rgb(0x20, 0x20, 0x30));
        applet.base.drawLabel(x + 100, y, "30 minutes", rgb(0x10, 0x10, 0x20));

        applet.base.drawLabel(x, y + 30, "Display off:", rgb(0x20, 0x20, 0x30));
        applet.base.drawLabel(x + 100, y + 30, "15 minutes", rgb(0x10, 0x10, 0x20));

        applet.base.drawCheckbox(x, y + 60, "Allow hybrid sleep", true);
    }

    fn drawPowerButtonsSection(applet: *PowerOptionsApplet, x: i32, y: i32, w: i32) void {
        _ = w;
        applet.base.drawLabel(x, y, "When I press the power button:", rgb(0x20, 0x20, 0x30));
        applet.base.drawLabel(x + 220, y, "Shutdown", rgb(0x10, 0x10, 0x20));

        applet.base.drawLabel(x, y + 30, "When I press the sleep button:", rgb(0x20, 0x20, 0x30));
        applet.base.drawLabel(x + 220, y + 30, "Sleep", rgb(0x10, 0x10, 0x20));

        applet.base.drawLabel(x, y + 60, "When I close the lid:", rgb(0x20, 0x20, 0x30));
        applet.base.drawLabel(x + 220, y + 60, "Sleep", rgb(0x10, 0x10, 0x20));
    }
};
