// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/control_panel/applets/network_center.zig
// Purpose: Network and Sharing Center Applet
//
// This is an independent clean-room implementation.

const std = @import("std");
const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const NetworkCenterApplet = struct {
    base: applet_base.ControlPanelApplet,
    active_connections: [5]ConnectionInfo,
    connection_count: usize,
    selected_connection: usize,
    hover_state: HoverArea,

    pub const ConnectionInfo = struct {
        name: [32]u8,
        name_len: usize,
        status: ConnectionStatus,
        network_type: NetworkType,
        signal_strength: i32,
    };

    pub const ConnectionStatus = enum { connected, disconnected, limited, searching };
    pub const NetworkType = enum { ethernet, wifi, vpn, dialup };

    pub const HoverArea = enum { none, btn_apply, btn_cancel, conn_item, btn_diagnose, btn_properties };

    pub fn create(x: i32, y: i32, w: i32, h: i32) NetworkCenterApplet {
        var nc = NetworkCenterApplet{
            .base = applet_base.ControlPanelApplet.create(.network_center, x, y, w, h),
            .active_connections = std.mem.zeroes([5]ConnectionInfo),
            .connection_count = 2,
            .selected_connection = 0,
            .hover_state = .none,
        };

        @memcpy(nc.active_connections[0].name[0..8], "Ethernet");
        nc.active_connections[0].name_len = 8;
        nc.active_connections[0].status = .connected;
        nc.active_connections[0].network_type = .ethernet;
        nc.active_connections[0].signal_strength = 100;

        @memcpy(nc.active_connections[1].name[0..6], "Wi-Fi");
        nc.active_connections[1].name_len = 6;
        nc.active_connections[1].status = .connected;
        nc.active_connections[1].network_type = .wifi;
        nc.active_connections[1].signal_strength = 85;

        return nc;
    }

    pub fn onMouseMove(_: *NetworkCenterApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *NetworkCenterApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Network and Sharing Center");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        // Network map
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 200, "Network Map");
        applet.drawNetworkMap(client.x + 24, cy + 24, client.width - 48);
        cy += 220;

        // Connections
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 180, "Active Networks");
        applet.drawConnectionList(client.x + 24, cy + 24, client.width - 48);
        cy += 200;

        // Actions
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 60, "Related Tasks");
        applet.drawTasks(client.x + 24, cy + 24, client.width - 48);
        cy += 80;

        applet.base.drawButton(client.x + 16, cy, 100, 28, "Diagnose", applet.hover_state == .btn_diagnose);
        applet.base.drawButton(client.x + 126, cy, 110, 28, "Properties", applet.hover_state == .btn_properties);
    }

    fn drawNetworkMap(_: *NetworkCenterApplet, x: i32, y: i32, w: i32) void {
        fb.fillRect(x, y, w, 170, rgb(0xFF, 0xFF, 0xFF));

        // Internet cloud
        fb.fillEllipse(x + w - 100, y + 40, 80, 50, rgb(0xE0, 0xE8, 0xF0), rgb(0xC0, 0xC8, 0xD0));
        fb.drawTextTransparent(x + w - 75, y + 55, "Internet", rgb(0x40, 0x40, 0x60));

        // Router
        fb.fillRect(x + w / 2 - 40, y + 30, 80, 60, rgb(0xD0, 0xD8, 0xE0));
        fb.drawTextTransparent(x + w / 2 - 30, y + 55, "Router", rgb(0x30, 0x30, 0x40));

        // Lines
        fb.drawLine(x + w / 2 - 40, y + 60, x + w - 100, y + 65, rgb(0xA0, 0xA8, 0xB0));
        fb.drawLine(x + w / 2 + 40, y + 60, x + w / 2 - 20, y + 130, rgb(0xA0, 0xA8, 0xB0));

        // PC
        fb.fillRect(x + w / 2 - 20, y + 120, 60, 40, rgb(0xC8, 0xD0, 0xD8));
        fb.drawTextTransparent(x + w / 2 - 10, y + 135, "PC", rgb(0x30, 0x30, 0x40));
    }

    fn drawConnectionList(applet: *NetworkCenterApplet, x: i32, y: i32, w: i32) void {
        for (applet.active_connections[0..applet.connection_count], 0..) |*conn, i| {
            const selected = (@as(usize, @intCast(i)) == applet.selected_connection);
            const by = y + @as(i32, @intCast(i)) * 60;
            const bg = if (selected) rgb(0xC8, 0xDC, 0xF0) else rgb(0xFF, 0xFF, 0xFF);

            fb.fillRect(x, by, w, 56, bg);
            fb.draw3DRect(x, by, w, 56, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

            const status_color = switch (conn.status) {
                .connected => rgb(0x20, 0x80, 0x20),
                .disconnected => rgb(0xC0, 0x20, 0x20),
                .limited => rgb(0xC0, 0xA0, 0x20),
                .searching => rgb(0x20, 0x60, 0xC0),
            };

            const status_text = switch (conn.status) {
                .connected => "Connected",
                .disconnected => "Disconnected",
                .limited => "Limited",
                .searching => "Searching...",
            };

            fb.drawTextTransparent(x + 8, by + 8, conn.name[0..conn.name_len], rgb(0x20, 0x20, 0x30));
            fb.drawTextTransparent(x + 8, by + 28, status_text, status_color);

            if (conn.signal_strength > 0) {
                var sig_buf: [16]u8 = undefined;
                const sig_str = std.fmt.bufPrint(&sig_buf, "{d}%", .{conn.signal_strength}) catch "";
                fb.drawTextTransparent(x + w - 70, by + 28, sig_str, rgb(0x40, 0x40, 0x50));
            }
        }
    }

    fn drawTasks(_: *NetworkCenterApplet, x: i32, y: i32, w: i32) void {
        const tasks = [_][]const u8{ "New connection", "Adapter settings", "Sharing options" };
        const btn_w = @divTrunc(w - 8, 3);

        inline for (tasks, 0..) |name, i| {
            const bx = x + @as(i32, @intCast(i)) * (btn_w + 4);
            fb.fillRect(bx, y, btn_w, 32, rgb(0xE8, 0xEC, 0xF4));
            fb.draw3DRect(bx, y, btn_w, 32, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 4, y + 10, name, rgb(0x20, 0x20, 0x30));
        }
    }
};
