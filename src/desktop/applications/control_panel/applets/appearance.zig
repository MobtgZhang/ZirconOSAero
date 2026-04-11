// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/appearance.zig
// Purpose: Appearance and Personalization Control Panel Applet
//
// This is an independent clean-room implementation.

const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const ThemeChoice = enum { aero, basic, classic };
pub const BackgroundChoice = enum { solid, gradient, picture, slideshow };

pub const AppearanceApplet = struct {
    base: applet_base.ControlPanelApplet,
    selected_theme: ThemeChoice,
    selected_bg: BackgroundChoice,
    color_intensity: i32,
    enable_transparency: bool,
    hover_state: HoverArea,

    pub const HoverArea = enum { none, theme_aero, theme_basic, theme_classic, bg_solid, bg_gradient, bg_picture, bg_slideshow, btn_apply, btn_cancel };

    pub fn create(x: i32, y: i32, w: i32, h: i32) AppearanceApplet {
        return .{
            .base = applet_base.ControlPanelApplet.create(.appearance, x, y, w, h),
            .selected_theme = .aero,
            .selected_bg = .solid,
            .color_intensity = 50,
            .enable_transparency = true,
            .hover_state = .none,
        };
    }

    pub fn onMouseMove(applet: *AppearanceApplet, px: i32, py: i32) void {
        _ = applet.base.getClientRect();
        applet.hover_state = .none;
        _ = px;
        _ = py;
    }

    pub fn render(applet: *AppearanceApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Appearance and Personalization");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        // Theme section
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 90, "Theme");
        applet.drawThemeButtons(client.x + 24, cy + 24, client.width - 48);
        cy += 110;

        // Background section
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 90, "Desktop Background");
        applet.drawBackgroundOptions(client.x + 24, cy + 24, client.width - 48);
        cy += 110;

        // Color section
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 80, "Window Color and Appearance");
        applet.drawColorSettings(client.x + 24, cy + 24, client.width - 48);
        cy += 100;

        // Buttons
        applet.base.drawButton(client.x + 16, cy, 90, 28, "Apply", applet.hover_state == .btn_apply);
        applet.base.drawButton(client.x + 116, cy, 90, 28, "Cancel", applet.hover_state == .btn_cancel);
    }

    fn drawThemeButtons(applet: *AppearanceApplet, x: i32, y: i32, w: i32) void {
        const themes = [_][]const u8{ "Aero", "Basic", "Classic" };
        const theme_vals = [_]ThemeChoice{ .aero, .basic, .classic };
        const btn_w = @divTrunc(w - 16, 3);

        inline for (themes, 0..) |name, i| {
            const bx = x + @as(i32, @intCast(i)) * (btn_w + 4);
            const selected = (theme_vals[i] == applet.selected_theme);
            const hovered = switch (theme_vals[i]) {
                .aero => applet.hover_state == .theme_aero,
                .basic => applet.hover_state == .theme_basic,
                .classic => applet.hover_state == .theme_classic,
            };
            const bg = if (selected) rgb(0xC8, 0xDC, 0xF0) else if (hovered) rgb(0xE8, 0xEC, 0xF4) else rgb(0xF0, 0xF4, 0xF8);
            fb.fillRect(bx, y, btn_w, 50, bg);
            fb.draw3DRect(bx, y, btn_w, 50, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + @divTrunc(btn_w, 2) - @as(i32, @intCast(name.len)) * 4, y + 18, name, rgb(0x20, 0x20, 0x30));
        }
    }

    fn drawBackgroundOptions(applet: *AppearanceApplet, x: i32, y: i32, w: i32) void {
        const options = [_][]const u8{ "Solid", "Gradient", "Picture", "Slideshow" };
        const opt_vals = [_]BackgroundChoice{ .solid, .gradient, .picture, .slideshow };
        const btn_w = @divTrunc(w - 12, 4);

        inline for (options, 0..) |name, i| {
            const bx = x + @as(i32, @intCast(i)) * (btn_w + 4);
            const selected = (opt_vals[i] == applet.selected_bg);
            const bg = if (selected) rgb(0xC8, 0xDC, 0xF0) else rgb(0xE8, 0xEC, 0xF4);
            fb.fillRect(bx, y, btn_w, 50, bg);
            fb.draw3DRect(bx, y, btn_w, 50, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + @divTrunc(btn_w, 2) - @as(i32, @intCast(name.len)) * 4, y + 18, name, rgb(0x20, 0x20, 0x30));
        }
    }

    fn drawColorSettings(applet: *AppearanceApplet, x: i32, y: i32, w: i32) void {
        _ = w;
        const colors = [_]u32{
            rgb(0x1A, 0x5C, 0xB8),
            rgb(0x36, 0x6B, 0x22),
            rgb(0x8B, 0x45, 0x13),
            rgb(0x70, 0x30, 0xA0),
            rgb(0xC0, 0x00, 0x00),
            rgb(0x00, 0x50, 0x98),
        };

        const swatch_size: i32 = 28;
        const spacing: i32 = 6;

        inline for (colors, 0..) |color, i| {
            const sx = x + @as(i32, @intCast(i)) * (swatch_size + spacing);
            fb.fillRect(sx, y, swatch_size, swatch_size, color);
            fb.draw3DRect(sx, y, swatch_size, swatch_size, rgb(0xFF, 0xFF, 0xFF), rgb(0x80, 0x80, 0x88));
        }

        const label_x = x + @as(i32, @intCast(colors.len)) * (swatch_size + spacing) + 16;
        fb.drawTextTransparent(label_x, y + 8, "Intensity:", rgb(0x20, 0x20, 0x30));

        const slider_x = label_x + 72;
        applet.base.drawSlider(slider_x, y + 6, 100, applet.color_intensity, 0, 100);

        const trans_x = slider_x + 120;
        applet.base.drawCheckbox(trans_x, y, "Enable Transparency", applet.enable_transparency);
    }
};
