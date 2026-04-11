// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/sysinfo.zig
// Purpose: System Information utility
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const SysInfoWindow = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    active_tab: InfoTab,
    cpu_name: [64]u8,
    cpu_name_len: usize,
    ram_total: u64,
    ram_available: u64,
    os_version: [32]u8,
    os_version_len: usize,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };
    pub const InfoTab = enum(u8) { system, hardware, software, performance };

    pub fn create(x_pos: i32, y_pos: i32) SysInfoWindow {
        var si: SysInfoWindow = .{
            .x = x_pos,
            .y = y_pos,
            .width = 550,
            .height = 460,
            .visible = true,
            .caption_hover = .none,
            .active_tab = .system,
            .cpu_name = undefined,
            .cpu_name_len = 0,
            .ram_total = 8589934592,
            .ram_available = 4294967296,
            .os_version = undefined,
            .os_version_len = 0,
        };

        @memcpy(si.cpu_name[0..14], "ZirconOSAero NT");
        si.cpu_name_len = 14;
        @memcpy(si.os_version[0..18], "ZirconOSAero 6.1");
        si.os_version_len = 18;

        return si;
    }

    pub fn setTab(si: *SysInfoWindow, tab: InfoTab) void {
        si.active_tab = tab;
    }

    pub fn render(si: *SysInfoWindow, t: *const theme_mod.ThemeColors) void {
        if (!si.visible) return;
        _ = t;

        const wx = si.x;
        const wy = si.y;
        const ww = si.width;
        const wh = si.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 10, "System Information", rgb(0xFF, 0xFF, 0xFF));
        const close_x = wx + ww - 48;
        if (si.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 34, rgb(0xF8, 0xFC, 0xFF));

        si.renderTabs();
        si.renderContent();
    }

    fn renderTabs(si: *SysInfoWindow) void {
        const tabs = [_][]const u8{ "System", "Hardware", "Software", "Performance" };
        var tx = si.x + 8;
        const ty = si.y + 40;

        for (tabs, 0..) |tab_name, i| {
            const tab_enum: InfoTab = @enumFromInt(i);
            const selected = (si.active_tab == tab_enum);
            const tab_w: i32 = 80;
            const tab_h: i32 = 28;

            const bg = if (selected) rgb(0xF8, 0xFC, 0xFF) else rgb(0xE8, 0xEC, 0xF4);
            fb.fillRect(tx, ty, tab_w, tab_h, bg);
            fb.draw3DRect(tx, ty, tab_w, tab_h,
                if (selected) rgb(0xFF, 0xFF, 0xFF) else rgb(0xD0, 0xD8, 0xE0),
                if (selected) rgb(0xC8, 0xD4, 0xE0) else rgb(0xFF, 0xFF, 0xFF));

            fb.drawTextTransparent(tx + 4, ty + 8, tab_name,
                if (selected) rgb(0x20, 0x40, 0x80) else rgb(0x40, 0x40, 0x50));
            tx += tab_w + 4;
        }
    }

    fn renderContent(si: *SysInfoWindow) void {
        const cx = si.x + 16;
        var cy = si.y + 80;

        switch (si.active_tab) {
            .system => si.renderSystemInfo(cx, &cy),
            .hardware => si.renderHardwareInfo(cx, &cy),
            .software => si.renderSoftwareInfo(cx, &cy),
            .performance => si.renderPerformanceInfo(cx, &cy),
        }
    }

    fn renderSystemInfo(si: *SysInfoWindow, cx: *i32, cy: *i32) void {
        _ = si;
        const labels = [_][]const u8{
            "OS Name:",           "Version:",
            "System Type:",       "Registered Owner:",
            "Product ID:",        "Original Install Date:",
        };

        const values = [_][]const u8{
            "ZirconOSAero Enterprise",
            "6.1 (Build 7601)",
            "LoongArch64 / x86_64",
            "ZirconOSAero User",
            "00426-OEM-xxxxxxx-xxxxx",
            "2026-04-11",
        };

        for (labels, values, 0..) |label, value, i| {
            fb.drawTextTransparent(cx.*, cy.*, label, rgb(0x20, 0x20, 0x30));
            const val_color = if (i == 0) rgb(0x10, 0x10, 0x50) else rgb(0x40, 0x40, 0x50);
            fb.drawTextTransparent(cx.* + 140, cy.*, value, val_color);
            cy.* += 24;
        }
    }

    fn renderHardwareInfo(si: *SysInfoWindow, cx: *i32, cy: *i32) void {
        const cpu_str = si.cpu_name[0..si.cpu_name_len];
        fb.drawTextTransparent(cx.*, cy.*, "Processor:", rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(cx.* + 140, cy.*, cpu_str, rgb(0x10, 0x10, 0x50));
        cy.* += 24;

        fb.drawTextTransparent(cx.*, cy.*, "Number of Processors:", rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(cx.* + 140, cy.*, "4", rgb(0x40, 0x40, 0x50));
        cy.* += 24;

        const ram_gb_total = si.ram_total / (1024 * 1024 * 1024);
        const ram_gb_avail = si.ram_available / (1024 * 1024 * 1024);
        var buf: [32]u8 = undefined;
        const ram_str = std.fmt.bufPrint(&buf, "{d} GB Physical RAM", .{ram_gb_total}) catch "";
        fb.drawTextTransparent(cx.*, cy.*, "Installed Memory (RAM):", rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(cx.* + 140, cy.*, ram_str, rgb(0x40, 0x40, 0x50));
        cy.* += 24;

        const avail_str = std.fmt.bufPrint(&buf, "{d} GB available", .{ram_gb_avail}) catch "";
        fb.drawTextTransparent(cx.* + 140, cy.*, avail_str, rgb(0x60, 0x60, 0x60));
        cy.* += 30;

        fb.drawTextTransparent(cx.*, cy.*, "Video Adapter:", rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(cx.* + 140, cy.*, "VirtIO GPU (LoongArch)", rgb(0x40, 0x40, 0x50));
        cy.* += 24;

        fb.drawTextTransparent(cx.*, cy.*, "Display Mode:", rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(cx.* + 140, cy.*, "1920 x 1080, 32-bit", rgb(0x40, 0x40, 0x50));
    }

    fn renderSoftwareInfo(si: *SysInfoWindow, cx: *i32, cy: *i32) void {
        _ = si;
        const items = [_][]const u8{
            "DirectX Version:      11.0",
            "OpenGL Version:       4.6",
            ".NET Framework:       4.8",
            "Windows Script:       5.8",
            "Internet Explorer:    9.0",
            "Adobe Flash Player:   34.0",
        };
        for (items) |item| {
            fb.drawTextTransparent(cx.*, cy.*, item, rgb(0x40, 0x40, 0x50));
            cy.* += 22;
        }
    }

    fn renderPerformanceInfo(si: *SysInfoWindow, cx: *i32, cy: *i32) void {
        fb.drawTextTransparent(cx.*, cy.*, "CPU Usage:", rgb(0x20, 0x20, 0x30));
        const usage_percent: i32 = 23;
        var buf: [16]u8 = undefined;
        const usage_str = std.fmt.bufPrint(&buf, "{d}%", .{usage_percent}) catch "";
        fb.drawTextTransparent(cx.* + 100, cy.*, usage_str, rgb(0x40, 0x80, 0x40));
        cy.* += 30;

        fb.drawTextTransparent(cx.*, cy.*, "Memory Usage:", rgb(0x20, 0x20, 0x30));
        const mem_percent: i32 = 50;
        const mem_str = std.fmt.bufPrint(&buf, "{d}%", .{mem_percent}) catch "";
        fb.drawTextTransparent(cx.* + 100, cy.*, mem_str, rgb(0x40, 0x40, 0x80));
        cy.* += 30;

        const bar_x = cx.*;
        const bar_y = cy.*;
        const bar_w = si.width - 48;
        const bar_h = 16;

        fb.draw3DRect(bar_x, bar_y, bar_w, bar_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        const fill_w = @as(i32, @intCast(@as(f32, @floatFromInt(bar_w - 4)) * @as(f32, @floatFromInt(mem_percent)) / 100.0));
        if (fill_w > 0) {
            fb.fillRect(bar_x + 2, bar_y + 2, fill_w, bar_h - 4, rgb(0x3D, 0x7E, 0xCB));
        }
    }
};
