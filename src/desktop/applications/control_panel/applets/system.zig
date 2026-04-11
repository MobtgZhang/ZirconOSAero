// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/system.zig
// Purpose: System Control Panel Applet
//
// This is an independent clean-room implementation.

const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const SystemApplet = struct {
    base: applet_base.ControlPanelApplet,
    computer_name: [64]u8,
    computer_name_len: usize,
    windows_edition: [32]u8,
    windows_edition_len: usize,
    processor_info: [64]u8,
    processor_info_len: usize,
    installed_ram: u64,
    product_id: [32]u8,
    product_id_len: usize,
    hover_state: HoverArea,

    pub const HoverArea = enum { none, btn_apply, btn_cancel, btn_computer_name, btn_device_manager, btn_remote, btn_performance };

    pub fn create(x: i32, y: i32, w: i32, h: i32) SystemApplet {
        const sa = SystemApplet{
            .base = applet_base.ControlPanelApplet.create(.system, x, y, w, h),
            .computer_name = "ZirconOSAero-PC".*,
            .computer_name_len = 16,
            .windows_edition = "ZirconOSAero Enterprise".*,
            .windows_edition_len = 24,
            .processor_info = "LoongArch64 @ 2.0GHz".*,
            .processor_info_len = 22,
            .installed_ram = 4294967296,
            .product_id = "00000-00000-00000-00000".*,
            .product_id_len = 24,
            .hover_state = .none,
        };
        return sa;
    }

    pub fn onMouseMove(_: *SystemApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *SystemApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("System");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        // Windows edition
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 100, "Windows Edition");
        applet.drawEditionSection(client.x + 24, cy + 24, client.width - 48);
        cy += 120;

        // System info
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 140, "System");
        applet.drawSystemSection(client.x + 24, cy + 24, client.width - 48);
        cy += 160;

        // Remote settings
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 80, "Remote");
        applet.drawRemoteSection(client.x + 24, cy + 24, client.width - 48);
        cy += 100;

        // Performance
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 100, "Performance");
        applet.drawPerformanceSection(client.x + 24, cy + 24, client.width - 48);
        cy += 120;

        applet.base.drawButton(client.x + 16, cy, 90, 28, "Apply", applet.hover_state == .btn_apply);
        applet.base.drawButton(client.x + 116, cy, 90, 28, "Cancel", applet.hover_state == .btn_cancel);
    }

    fn drawEditionSection(applet: *SystemApplet, x: i32, y: i32, w: i32) void {
        fb.fillRect(x, y, w, 60, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(x, y, w, 60, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(x + 8, y + 8, applet.windows_edition[0..applet.windows_edition_len], rgb(0x10, 0x10, 0x20));
        fb.drawTextTransparent(x + 8, y + 30, "Product ID: ", rgb(0x60, 0x60, 0x70));
        fb.drawTextTransparent(x + 90, y + 30, applet.product_id[0..applet.product_id_len], rgb(0x40, 0x40, 0x50));
    }

    fn drawSystemSection(applet: *SystemApplet, x: i32, y: i32, w: i32) void {
        _ = w;
        const labels = [_][]const u8{ "Processor:", "Installed memory (RAM):", "System type:", "Computer name:" };
        const values = [_][]const u8{
            applet.processor_info[0..applet.processor_info_len],
            "4.0 GB",
            "LoongArch64",
            applet.computer_name[0..applet.computer_name_len],
        };

        for (labels, 0..) |label, i| {
            const ly = y + @as(i32, @intCast(i)) * 28;
            fb.drawTextTransparent(x, ly, label, rgb(0x40, 0x40, 0x50));
            fb.drawTextTransparent(x + 150, ly, values[i], rgb(0x20, 0x20, 0x30));
        }
    }

    fn drawRemoteSection(applet: *SystemApplet, x: i32, y: i32, w: i32) void {
        _ = w;
        applet.base.drawCheckbox(x, y, "Allow Remote Assistance connections to this computer", true);
        applet.base.drawCheckbox(x, y + 24, "Allow connections from computers running any version of Remote Desktop", false);
    }

    fn drawPerformanceSection(applet: *SystemApplet, x: i32, y: i32, w: i32) void {
        _ = w;
        applet.base.drawLabel(x, y, "Visual effects:", rgb(0x40, 0x40, 0x50));
        applet.base.drawLabel(x + 120, y, "Let Windows choose what's best for my computer", rgb(0x20, 0x20, 0x30));

        applet.base.drawLabel(x, y + 30, "Virtual memory:", rgb(0x40, 0x40, 0x50));
        applet.base.drawLabel(x + 120, y + 30, "C: 2048 MB total, 0 MB available", rgb(0x20, 0x20, 0x30));

        applet.base.drawLabel(x, y + 60, "Settings:", rgb(0x40, 0x40, 0x50));
        applet.base.drawButton(x + 80, y + 54, 110, 26, "Settings...", false);
        applet.base.drawButton(x + 200, y + 54, 110, 26, "Device Manager", false);
    }
};
