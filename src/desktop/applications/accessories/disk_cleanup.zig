// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/disk_cleanup.zig
// Purpose: Disk Cleanup utility
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const DiskCleanupWindow = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    total_size: u64,
    free_size: u64,
    selected_items: [12]bool,
    analysis_complete: bool,
    cleaning: bool,
    clean_progress: i32,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) DiskCleanupWindow {
        return .{
            .x = x_pos,
            .y = y_pos,
            .width = 560,
            .height = 480,
            .visible = true,
            .caption_hover = .none,
            .total_size = 53687091200,
            .free_size = 21474836480,
            .selected_items = [_]bool{true} ** 12,
            .analysis_complete = false,
            .cleaning = false,
            .clean_progress = 0,
        };
    }

    pub fn analyze(dc: *DiskCleanupWindow) void {
        dc.analysis_complete = true;
    }

    pub fn render(dc: *DiskCleanupWindow, t: *const theme_mod.ThemeColors) void {
        if (!dc.visible) return;
        _ = t;

        const wx = dc.x;
        const wy = dc.y;
        const ww = dc.width;
        const wh = dc.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 10, "Disk Cleanup", rgb(0xFF, 0xFF, 0xFF));
        const close_x = wx + ww - 48;
        if (dc.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 34, rgb(0xF8, 0xFC, 0xFF));

        dc.renderDriveInfo();
        dc.renderFileCategories();
        dc.renderButtons();
    }

    fn renderDriveInfo(dc: *DiskCleanupWindow) void {
        const cx = dc.x + 16;
        var cy = dc.y + 50;

        fb.drawTextTransparent(cx, cy, "Select drive: C: (ZirconOSAero)", rgb(0x20, 0x20, 0x30));
        cy += 24;

        const total_gb = dc.total_size / (1024 * 1024 * 1024);
        const free_gb = dc.free_size / (1024 * 1024 * 1024);
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Total: {d} GB | Free: {d} GB", .{ total_gb, free_gb }) catch "";
        fb.drawTextTransparent(cx, cy, text, rgb(0x40, 0x40, 0x50));
        cy += 30;

        const bar_x = cx;
        const bar_y = cy;
        const bar_w = dc.width - 32;
        const bar_h = 16;
        const used_size = dc.total_size - dc.free_size;
        const used_ratio = @as(f32, @floatFromInt(used_size)) / @as(f32, @floatFromInt(dc.total_size));

        fb.draw3DRect(bar_x, bar_y, bar_w, bar_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        const fill_w = @as(i32, @intCast(@as(f32, @floatFromInt(bar_w - 4)) * used_ratio));
        if (fill_w > 0) {
            fb.fillRect(bar_x + 2, bar_y + 2, fill_w, bar_h - 4, rgb(0x3D, 0x7E, 0xCB));
        }
    }

    fn renderFileCategories(dc: *DiskCleanupWindow) void {
        const cx = dc.x + 16;
        var cy = dc.y + 140;

        fb.drawTextTransparent(cx, cy, "Files to delete:", rgb(0x20, 0x40, 0x80));
        cy += 24;

        const categories = [_][]const u8{
            "Downloaded Program Files",
            "Temporary Internet Files",
            "Thumbnails",
            "Windows Update Cleanup",
            "Recycle Bin",
            "Temporary Files",
            "Offline Pages",
            "Old Windows Installation",
            "Windows Defender",
            "Error Reports",
            "DirectX Shader Cache",
            "User File History",
        };
        const size_labels = [_][]const u8{
            "0.01 MB", "45.2 MB", "3.5 MB", "120 MB",
            "250 MB", "180 MB", "0 MB", "2.5 GB",
            "45 MB", "0.5 MB", "12 MB", "800 MB",
        };

        for (categories, 0..) |cat, i| {
            const by = cy + @as(i32, @intCast(i)) * 26;
            const selected = dc.selected_items[i];

            fb.fillRect(cx, by, 16, 16, rgb(0xFF, 0xFF, 0xFF));
            fb.draw3DRect(cx, by, 16, 16, rgb(0x80, 0x80, 0x88), rgb(0xFF, 0xFF, 0xFF));
            if (selected) {
                fb.drawTextTransparent(cx + 2, by, "X", rgb(0x10, 0x40, 0x10));
            }
            fb.drawTextTransparent(cx + 24, by + 2, cat, rgb(0x20, 0x20, 0x30));
            fb.drawTextTransparent(cx + 280, by + 2, size_labels[i], rgb(0x60, 0x60, 0x70));
        }
    }

    fn renderButtons(dc: *DiskCleanupWindow) void {
        const bx = dc.x + 16;
        const by = dc.y + dc.height - 60;
        const btn_w: i32 = 120;
        const btn_h: i32 = 28;

        const label = if (!dc.analysis_complete) "Analyze" else "Clean up System Files";
        const btn_x = bx;

        fb.fillRect(btn_x, by, btn_w, btn_h, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(btn_x, by, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        const text_x = btn_x + 10;
        const text_y = by + 10;
        fb.drawTextTransparent(text_x, text_y, label, rgb(0x20, 0x20, 0x30));
    }
};
