// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/sounds.zig
// Purpose: Sound and Audio Device Settings Applet
//
// This is an independent clean-room implementation.

const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const SoundsApplet = struct {
    base: applet_base.ControlPanelApplet,
    master_volume: i32,
    mute_enabled: bool,
    selected_device: usize,
    selected_scheme: usize,
    hover_state: HoverArea,

    pub const HoverArea = enum { none, btn_apply, btn_cancel, device_item };

    pub fn create(x: i32, y: i32, w: i32, h: i32) SoundsApplet {
        return .{
            .base = applet_base.ControlPanelApplet.create(.sounds, x, y, w, h),
            .master_volume = 70,
            .mute_enabled = false,
            .selected_device = 0,
            .selected_scheme = 0,
            .hover_state = .none,
        };
    }

    pub fn onMouseMove(_: *SoundsApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *SoundsApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Sound");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        // Playback section
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 130, "Playback");
        applet.drawPlaybackSection(client.x + 24, cy + 24, client.width - 48);
        cy += 150;

        // Volume Mixer
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 110, "Volume Mixer");
        applet.drawVolumeMixer(client.x + 24, cy + 24, client.width - 48);
        cy += 130;

        // Sound Scheme
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 100, "Sound Scheme");
        applet.drawSchemeSection(client.x + 24, cy + 24, client.width - 48);
        cy += 120;

        applet.base.drawButton(client.x + 16, cy, 90, 28, "Apply", applet.hover_state == .btn_apply);
        applet.base.drawButton(client.x + 116, cy, 90, 28, "Cancel", applet.hover_state == .btn_cancel);
    }

    fn drawPlaybackSection(applet: *SoundsApplet, x: i32, y: i32, w: i32) void {
        const devices = [_][]const u8{ "Speakers (High Definition Audio)", "Headphones", "Digital Audio (S/PDIF)" };

        applet.base.drawLabel(x, y, "Select a playback device:", rgb(0x20, 0x20, 0x30));
        for (devices, 0..) |name, i| {
            const selected = (@as(usize, @intCast(i)) == applet.selected_device);
            applet.base.drawListItem(x, y + 20 + @as(i32, @intCast(i)) * 30, w, name, selected, null);
        }
    }

    fn drawVolumeMixer(applet: *SoundsApplet, x: i32, y: i32, w: i32) void {
        const channels = [_][]const u8{ "System", "Communications", "Applications" };
        const volumes = [_]i32{ applet.master_volume, 80, 60 };

        applet.base.drawLabel(x, y, "Device: Speakers", rgb(0x20, 0x20, 0x30));

        inline for (channels, 0..) |name, i| {
            const by = y + 24 + @as(i32, @intCast(i)) * 28;
            fb.drawTextTransparent(x, by, name, rgb(0x20, 0x20, 0x30));
            applet.base.drawSlider(x + 120, by + 4, w - 160, volumes[i], 0, 100);
        }

        // Master mute
        applet.base.drawCheckbox(x, y + 110, "Mute", applet.mute_enabled);
    }

    fn drawSchemeSection(applet: *SoundsApplet, x: i32, y: i32, w: i32) void {
        const schemes = [_][]const u8{ "Windows Default", "No Sounds", "Sage", "Afro" };
        const btn_w = @divTrunc(w - 12, 4);

        inline for (schemes, 0..) |name, i| {
            const bx = x + @as(i32, @intCast(i)) * (btn_w + 4);
            const selected = (@as(usize, @intCast(i)) == applet.selected_scheme);
            const bg = if (selected) rgb(0xC8, 0xDC, 0xF0) else rgb(0xE8, 0xEC, 0xF4);
            fb.fillRect(bx, y, btn_w, 50, bg);
            fb.draw3DRect(bx, y, btn_w, 50, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 4, y + 18, name, rgb(0x20, 0x20, 0x30));
        }
    }
};
