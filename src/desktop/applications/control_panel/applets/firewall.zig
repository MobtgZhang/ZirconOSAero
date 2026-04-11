// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/firewall.zig
// Purpose: Windows Firewall Settings Applet
//
// This is an independent clean-room implementation.

const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const FirewallApplet = struct {
    base: applet_base.ControlPanelApplet,
    firewall_enabled: bool,
    notifications_enabled: bool,
    exceptions_enabled: bool,
    selected_profile: Profile,
    hover_state: HoverArea,

    pub const Profile = enum { domain, private, public };

    pub const HoverArea = enum { none, btn_apply, btn_cancel, btn_restore };

    pub fn create(x: i32, y: i32, w: i32, h: i32) FirewallApplet {
        return .{
            .base = applet_base.ControlPanelApplet.create(.firewall, x, y, w, h),
            .firewall_enabled = true,
            .notifications_enabled = true,
            .exceptions_enabled = true,
            .selected_profile = .private,
            .hover_state = .none,
        };
    }

    pub fn onMouseMove(_: *FirewallApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *FirewallApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Windows Firewall");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        // Status
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 120, "Status");
        applet.drawStatusSection(client.x + 24, cy + 24, client.width - 48);
        cy += 140;

        // Profiles
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 160, "Customize Settings for Each Network Location");
        applet.drawProfilesSection(client.x + 24, cy + 24, client.width - 48);
        cy += 180;

        applet.base.drawButton(client.x + 16, cy, 120, 28, "Restore Defaults", applet.hover_state == .btn_restore);
        applet.base.drawButton(client.x + 146, cy, 90, 28, "Apply", applet.hover_state == .btn_apply);
        applet.base.drawButton(client.x + 246, cy, 90, 28, "Cancel", applet.hover_state == .btn_cancel);
    }

    fn drawStatusSection(applet: *FirewallApplet, x: i32, y: i32, w: i32) void {
        const status_text = if (applet.firewall_enabled) "Windows Firewall is ON" else "Windows Firewall is OFF";
        const status_color = if (applet.firewall_enabled) rgb(0x20, 0x80, 0x20) else rgb(0xC0, 0x20, 0x20);

        fb.fillRect(x, y, w, 40, if (applet.firewall_enabled) rgb(0xE8, 0xF8, 0xE8) else rgb(0xF8, 0xE8, 0xE8));
        fb.draw3DRect(x, y, w, 40, status_color, rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(x + 12, y + 12, status_text, status_color);

        applet.base.drawCheckbox(x, y + 50, "Notify me when Windows Firewall blocks a new program", applet.notifications_enabled);
    }

    fn drawProfilesSection(applet: *FirewallApplet, x: i32, y: i32, w: i32) void {
        const profiles = [_][]const u8{
            "Domain network: Home or work (private)",
            "Private network: Home or work (private)",
            "Public network: Shared locations (public)",
        };

        inline for (profiles, 0..) |name, i| {
            const by = y + @as(i32, @intCast(i)) * 40;
            const enabled = applet.firewall_enabled;
            const bg = if (enabled) rgb(0xE8, 0xF8, 0xE8) else rgb(0xF8, 0xE8, 0xE8);
            fb.fillRect(x, by, w, 36, bg);
            fb.draw3DRect(x, by, w, 36, rgb(0xC0, 0xD0, 0xC0), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(x + 8, by + 10, name, if (enabled) rgb(0x20, 0x60, 0x20) else rgb(0xA0, 0x40, 0x40));
        }
    }
};
