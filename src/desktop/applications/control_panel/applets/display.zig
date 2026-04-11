// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/display.zig
// Purpose: Display Settings Control Panel Applet
//
// This is an independent clean-room implementation.

const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const DisplayApplet = struct {
    base: applet_base.ControlPanelApplet,
    resolution_index: i32,
    orientation: Orientation,
    brightness: i32,
    refresh_rate: i32,
    hover_state: HoverArea,

    pub const Orientation = enum { landscape, portrait, landscape_flipped, portrait_flipped };
    pub const HoverArea = enum { none, btn_apply, btn_cancel, res_option };

    pub fn create(x: i32, y: i32, w: i32, h: i32) DisplayApplet {
        return .{
            .base = applet_base.ControlPanelApplet.create(.display, x, y, w, h),
            .resolution_index = 2,
            .orientation = .landscape,
            .brightness = 75,
            .refresh_rate = 60,
            .hover_state = .none,
        };
    }

    pub fn onMouseMove(_: *DisplayApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *DisplayApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Display Settings");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        // Resolution
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 120, "Resolution");
        applet.drawResolutionSection(client.x + 24, cy + 24, client.width - 48);
        cy += 140;

        // Orientation
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 100, "Orientation");
        applet.drawOrientationSection(client.x + 24, cy + 24, client.width - 48);
        cy += 120;

        // Brightness
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 80, "Brightness");
        applet.drawBrightnessSection(client.x + 24, cy + 24, client.width - 48);
        cy += 100;

        applet.base.drawButton(client.x + 16, cy, 90, 28, "Apply", applet.hover_state == .btn_apply);
        applet.base.drawButton(client.x + 116, cy, 90, 28, "Cancel", applet.hover_state == .btn_cancel);
    }

    fn drawResolutionSection(applet: *DisplayApplet, x: i32, y: i32, w: i32) void {
        const resolutions = [_][]const u8{
            "800 x 600",
            "1024 x 768",
            "1280 x 720",
            "1366 x 768",
            "1440 x 900",
            "1600 x 900",
            "1920 x 1080",
        };

        const btn_h: i32 = 24;
        applet.base.drawLabel(x, y, "Select resolution:", rgb(0x20, 0x20, 0x30));
        for (resolutions, 0..) |res, i| {
            const selected = (@as(i32, @intCast(i)) == applet.resolution_index);
            const bx = x + 4;
            const by = y + 20 + @as(i32, @intCast(i)) * (btn_h + 4);
            applet.base.drawListItem(bx, by, w - 8, res, selected, null);
        }
    }

    fn drawOrientationSection(applet: *DisplayApplet, x: i32, y: i32, w: i32) void {
        const orientations = [_][]const u8{ "Landscape", "Portrait", "Landscape (flipped)", "Portrait (flipped)" };
        const orient_vals = [_]Orientation{ .landscape, .portrait, .landscape_flipped, .portrait_flipped };
        const btn_w = @divTrunc(w - 12, 4);

        inline for (orientations, 0..) |name, i| {
            const bx = x + @as(i32, @intCast(i)) * (btn_w + 4);
            const selected = (orient_vals[i] == applet.orientation);
            const bg = if (selected) rgb(0xC8, 0xDC, 0xF0) else rgb(0xE8, 0xEC, 0xF4);
            fb.fillRect(bx, y, btn_w, 50, bg);
            fb.draw3DRect(bx, y, btn_w, 50, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 4, y + 18, name, rgb(0x20, 0x20, 0x30));
        }
    }

    fn drawBrightnessSection(applet: *DisplayApplet, x: i32, y: i32, w: i32) void {
        applet.base.drawLabel(x, y, "Adjust brightness:", rgb(0x20, 0x20, 0x30));
        applet.base.drawSlider(x + 130, y + 4, w - 140, applet.brightness, 0, 100);
    }
};
