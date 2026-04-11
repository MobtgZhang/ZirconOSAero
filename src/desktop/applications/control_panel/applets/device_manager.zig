// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/device_manager.zig
// Purpose: Device Manager Applet
//
// This is an independent clean-room implementation.

const std = @import("std");
const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const DeviceManagerApplet = struct {
    base: applet_base.ControlPanelApplet,
    categories: [8]DeviceCategory,
    category_count: usize,
    expanded_category: usize,
    selected_device: usize,
    hover_state: HoverArea,

    pub const DeviceCategory = struct {
        name: [48]u8,
        name_len: usize,
        devices: [10]DeviceInfo,
        device_count: usize,
        icon: ?u16,
    };

    pub const DeviceInfo = struct {
        name: [64]u8,
        name_len: usize,
        status: DeviceStatus,
        driver_date: u32,
    };

    pub const DeviceStatus = enum { ok, err, warning, disabled, unknown };

    pub const HoverArea = enum { none, btn_apply, btn_cancel, btn_scan, category_item };

    pub fn create(x: i32, y: i32, w: i32, h: i32) DeviceManagerApplet {
        var dm = DeviceManagerApplet{
            .base = applet_base.ControlPanelApplet.create(.device_manager, x, y, w, h),
            .categories = undefined,
            .category_count = 4,
            .expanded_category = 0,
            .selected_device = 0,
            .hover_state = .none,
        };

        dm.categories[0] = .{
            .name = std.mem.zeroes([48]u8),
            .name_len = 16,
            .devices = std.mem.zeroes([10]DeviceInfo),
            .device_count = 2,
            .icon = null,
        };
        @memcpy(dm.categories[0].name[0..16], "Network adapters");
        dm.categories[0].devices[0] = .{
            .name = std.mem.zeroes([64]u8),
            .name_len = 22,
            .status = .ok,
            .driver_date = 20260301,
        };
        @memcpy(dm.categories[0].devices[0].name[0..22], "Intel(R) PRO/1000 MT");
        dm.categories[0].devices[1] = .{
            .name = std.mem.zeroes([64]u8),
            .name_len = 19,
            .status = .ok,
            .driver_date = 20260301,
        };
        @memcpy(dm.categories[0].devices[1].name[0..19], "Realtek PCIe GBE");

        dm.categories[1] = .{
            .name = std.mem.zeroes([48]u8),
            .name_len = 17,
            .devices = std.mem.zeroes([10]DeviceInfo),
            .device_count = 1,
            .icon = null,
        };
        @memcpy(dm.categories[1].name[0..17], "Display adapters");
        dm.categories[1].devices[0] = .{
            .name = std.mem.zeroes([64]u8),
            .name_len = 20,
            .status = .ok,
            .driver_date = 20260301,
        };
        @memcpy(dm.categories[1].devices[0].name[0..20], "VirtIO GPU Adapter");

        dm.categories[2] = .{
            .name = std.mem.zeroes([48]u8),
            .name_len = 17,
            .devices = std.mem.zeroes([10]DeviceInfo),
            .device_count = 2,
            .icon = null,
        };
        @memcpy(dm.categories[2].name[0..17], "Sound controllers");
        dm.categories[2].devices[0] = .{
            .name = std.mem.zeroes([64]u8),
            .name_len = 17,
            .status = .ok,
            .driver_date = 20260301,
        };
        @memcpy(dm.categories[2].devices[0].name[0..17], "Intel HDA Audio");
        dm.categories[2].devices[1] = .{
            .name = std.mem.zeroes([64]u8),
            .name_len = 14,
            .status = .ok,
            .driver_date = 20260301,
        };
        @memcpy(dm.categories[2].devices[1].name[0..14], "VirtIO Sound");

        dm.categories[3] = .{
            .name = std.mem.zeroes([48]u8),
            .name_len = 16,
            .devices = std.mem.zeroes([10]DeviceInfo),
            .device_count = 2,
            .icon = null,
        };
        @memcpy(dm.categories[3].name[0..16], "USB controllers");
        dm.categories[3].devices[0] = .{
            .name = std.mem.zeroes([64]u8),
            .name_len = 17,
            .status = .ok,
            .driver_date = 20260301,
        };
        @memcpy(dm.categories[3].devices[0].name[0..17], "VirtIO USB EHCI");
        dm.categories[3].devices[1] = .{
            .name = std.mem.zeroes([64]u8),
            .name_len = 17,
            .status = .ok,
            .driver_date = 20260301,
        };
        @memcpy(dm.categories[3].devices[1].name[0..17], "VirtIO USB KHCI");

        return dm;
    }

    pub fn onMouseMove(_: *DeviceManagerApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *DeviceManagerApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Device Manager");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        // Toolbar
        applet.drawToolbar(client.x + 16, cy, client.width - 32);
        cy += 50;

        // Category list
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 300, "");
        applet.drawCategoryList(client.x + 24, cy + 8, client.width - 48, cy + 308);
        cy += 320;

        applet.base.drawButton(client.x + 16, cy, 120, 28, "Scan for Hardware", applet.hover_state == .btn_scan);
        applet.base.drawButton(client.x + 146, cy, 90, 28, "Apply", applet.hover_state == .btn_apply);
        applet.base.drawButton(client.x + 246, cy, 90, 28, "Cancel", applet.hover_state == .btn_cancel);
    }

    fn drawToolbar(_: *DeviceManagerApplet, x: i32, y: i32, w: i32) void {
        fb.fillRect(x, y, w, 40, rgb(0xF0, 0xF4, 0xF8));
        fb.drawHLine(x, y + 39, w, rgb(0xC0, 0xC8, 0xD8));
        fb.drawTextTransparent(x + 8, y + 12, "View:", rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(x + 60, y + 12, "Devices by type", rgb(0x10, 0x40, 0x90));
    }

    fn drawCategoryList(applet: *DeviceManagerApplet, x: i32, y: i32, w: i32, bottom: i32) void {
        _ = bottom;
        var current_y = y;
        for (applet.categories[0..applet.category_count], 0..) |*cat, ci| {
            const expanded = (ci == applet.expanded_category);

            fb.fillRect(x, current_y, w, 32, rgb(0xE8, 0xEC, 0xF4));
            fb.draw3DRect(x, current_y, w, 32, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

            const arrow = if (expanded) "- " else "+ ";
            fb.drawTextTransparent(x + 4, current_y + 8, arrow, rgb(0x20, 0x20, 0x30));
            fb.drawTextTransparent(x + 20, current_y + 8, cat.name[0..cat.name_len], rgb(0x20, 0x20, 0x30));

            const count_str = "(" ++ "?" ++ ")";
            fb.drawTextTransparent(x + w - 40, current_y + 8, count_str, rgb(0x60, 0x60, 0x70));

            current_y += 36;

            if (expanded) {
                for (cat.devices[0..cat.device_count], 0..) |*dev, di| {
                    const is_selected = (di == applet.selected_device);
                    const dev_y = current_y + @as(i32, @intCast(di)) * 28;

                    const bg = if (is_selected) rgb(0xC8, 0xDC, 0xF0) else rgb(0xF8, 0xFC, 0xFF);
                    fb.fillRect(x + 20, dev_y, w - 20, 26, bg);

                    const status_color = switch (dev.status) {
                        .ok => rgb(0x00, 0x80, 0x00),
                        .warning => rgb(0xCC, 0x80, 0x00),
                        .err => rgb(0xCC, 0x00, 0x00),
                        .disabled => rgb(0x80, 0x80, 0x80),
                        .unknown => rgb(0x60, 0x60, 0x60),
                    };
                    fb.drawTextTransparent(x + 36, dev_y + 5, dev.name[0..dev.name_len], rgb(0x20, 0x20, 0x30));
                    fb.drawTextTransparent(x + w - 60, dev_y + 5, @tagName(dev.status), status_color);
                }
                current_y += @as(i32, @intCast(cat.device_count)) * 28 + 4;
            }
        }
    }
};
