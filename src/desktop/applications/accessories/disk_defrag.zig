// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/disk_defrag.zig
// Purpose: Disk Defragmenter utility
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const DiskDefragWindow = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    volumes: [4]VolumeInfo,
    volume_count: usize,
    selected_volume: usize,
    defrag_state: DefragState,
    progress_percent: i32,
    current_file: [128]u8,
    current_file_len: usize,
    estimated_time: u32,
    fragments_found: u32,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };
    pub const DefragState = enum { idle, analyzing, defragmenting, paused, complete };

    pub const VolumeInfo = struct {
        drive_letter: u8,
        label: [32]u8,
        total_size: u64,
        free_size: u64,
        fragmentation_percent: i32,
        volume_type: VolumeType,

        pub const VolumeType = enum { ntfs, fat32, exfat, unknown };
    };

    pub fn create(x_pos: i32, y_pos: i32) DiskDefragWindow {
        var dd: DiskDefragWindow = .{
            .x = x_pos,
            .y = y_pos,
            .width = 580,
            .height = 500,
            .visible = true,
            .caption_hover = .none,
            .volumes = undefined,
            .volume_count = 0,
            .selected_volume = 0,
            .defrag_state = .idle,
            .progress_percent = 0,
            .current_file = undefined,
            .current_file_len = 0,
            .estimated_time = 0,
            .fragments_found = 0,
        };

        dd.addVolume('C', "ZirconOSAero", 53687091200, 21474836480, 15, .ntfs);
        dd.addVolume('D', "Data", 107374182400, 53687091200, 8, .ntfs);

        return dd;
    }

    fn addVolume(dd: *DiskDefragWindow, letter: u8, label: []const u8, total: u64, free: u64, frag: i32, vtype: VolumeInfo.VolumeType) void {
        if (dd.volume_count < dd.volumes.len) {
            dd.volumes[dd.volume_count] = .{
                .drive_letter = letter,
                .label = undefined,
                .total_size = total,
                .free_size = free,
                .fragmentation_percent = frag,
                .volume_type = vtype,
            };
            @memcpy(dd.volumes[dd.volume_count].label[0..@min(label.len, 32)], label);
            dd.volume_count += 1;
        }
    }

    pub fn startAnalyze(dd: *DiskDefragWindow) void {
        dd.defrag_state = .analyzing;
        dd.progress_percent = 0;
    }

    pub fn startDefrag(dd: *DiskDefragWindow) void {
        dd.defrag_state = .defragmenting;
        dd.progress_percent = 0;
        dd.fragments_found = 247;
    }

    pub fn pauseDefrag(dd: *DiskDefragWindow) void {
        if (dd.defrag_state == .defragmenting) {
            dd.defrag_state = .paused;
        }
    }

    pub fn resumeDefrag(dd: *DiskDefragWindow) void {
        if (dd.defrag_state == .paused) {
            dd.defrag_state = .defragmenting;
        }
    }

    pub fn tick(dd: *DiskDefragWindow) void {
        if (dd.defrag_state == .analyzing) {
            dd.progress_percent += 1;
            if (dd.progress_percent >= 100) {
                dd.defrag_state = .idle;
                dd.progress_percent = 100;
            }
        } else if (dd.defrag_state == .defragmenting) {
            dd.progress_percent += 1;
            if (dd.progress_percent >= 100) {
                dd.defrag_state = .complete;
                dd.progress_percent = 100;
                dd.fragments_found = 0;
            }
        }
    }

    pub fn render(dd: *DiskDefragWindow, t: *const theme_mod.ThemeColors) void {
        if (!dd.visible) return;
        _ = t;

        const wx = dd.x;
        const wy = dd.y;
        const ww = dd.width;
        const wh = dd.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 10, "Disk Defragmenter", rgb(0xFF, 0xFF, 0xFF));
        const close_x = wx + ww - 48;
        if (dd.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 34, rgb(0xF8, 0xFC, 0xFF));

        dd.renderVolumeSelection();
        dd.renderDefragVisualization();
        dd.renderProgress();
        dd.renderButtons();
    }

    fn renderVolumeSelection(dd: *DiskDefragWindow) void {
        const cx = dd.x + 16;
        var cy = dd.y + 50;

        fb.drawTextTransparent(cx, cy, "Current status:", rgb(0x20, 0x40, 0x80));
        cy += 26;

        for (dd.volumes[0..dd.volume_count], 0..) |vol, i| {
            const selected = (i == dd.selected_volume);
            const by = cy + @as(i32, @intCast(i)) * 50;

            const bg = if (selected) rgb(0xE8, 0xF0, 0xFF) else rgb(0xF8, 0xFC, 0xFF);
            fb.fillRect(cx, by, dd.width - 32, 46, bg);
            fb.draw3DRect(cx, by, dd.width - 32, 46,
                if (selected) rgb(0x3D, 0x7E, 0xCB) else rgb(0xC0, 0xC8, 0xD8),
                if (selected) rgb(0x5A, 0x9E, 0xEB) else rgb(0xFF, 0xFF, 0xFF));

            const letter_str = [_]u8{vol.drive_letter};
            fb.drawTextTransparent(cx + 8, by + 8, &letter_str, rgb(0x10, 0x10, 0x50));
            fb.drawTextTransparent(cx + 28, by + 8, ":", rgb(0x10, 0x10, 0x50));

            const label_len = for (vol.label, 0..) |b, j| {
                if (b == 0) break j;
            } else vol.label.len;
            const label_str = vol.label[0..label_len];
            fb.drawTextTransparent(cx + 44, by + 8, label_str, rgb(0x20, 0x20, 0x30));

            const total_gb = vol.total_size / (1024 * 1024 * 1024);
            const free_gb = vol.free_size / (1024 * 1024 * 1024);
            var buf: [48]u8 = undefined;
            const size_str = std.fmt.bufPrint(&buf, "{d} GB total, {d} GB free", .{ total_gb, free_gb }) catch "";
            fb.drawTextTransparent(cx + 8, by + 24, size_str, rgb(0x60, 0x60, 0x60));

            var frag_buf: [32]u8 = undefined;
            const frag_str = std.fmt.bufPrint(&frag_buf, "Fragmentation: {d}%", .{vol.fragmentation_percent}) catch "";
            const frag_color = if (vol.fragmentation_percent > 10) rgb(0xCC, 0x00, 0x00) else rgb(0x00, 0x80, 0x00);
            fb.drawTextTransparent(cx + 280, by + 8, frag_str, frag_color);
        }
    }

    fn renderDefragVisualization(dd: *DiskDefragWindow) void {
        const vx = dd.x + 16;
        const vy = dd.y + 260;
        const vw = dd.width - 32;
        const vh: i32 = 80;

        fb.drawTextTransparent(vx, vy, "Disk fragmentation visualization:", rgb(0x20, 0x20, 0x30));
        fb.draw3DRect(vx, vy + 18, vw, vh, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(vx + 2, vy + 20, vw - 4, vh - 4, rgb(0xF0, 0xF4, 0xF8));

        const block_count: i32 = 100;
        const block_w = @divTrunc(vw - 4, block_count);
        const used_ratio: f32 = 0.75;

        for (0..@as(usize, @intCast(block_count))) |i| {
            const bx = vx + 2 + @as(i32, @intCast(i)) * block_w;
            const by = vy + 20;
            const bh = vh - 4;

            const frag_seed = @as(u32, @intCast(i * 17 + 7)) % 100;
            const is_fragmented = (frag_seed < dd.fragments_found / 2);
            const is_used = (frag_seed < @as(u32, @intFromFloat(used_ratio * 100.0)));

            const block_color: u32 = if (!is_used) rgb(0xE0, 0xE8, 0xF0)
                else if (is_fragmented) rgb(0xCC, 0x40, 0x00)
                else rgb(0x3D, 0x7E, 0xCB);
            fb.fillRect(bx, by, block_w - 1, bh, block_color);
        }

        const legend_y = vy + vh + 8;
        const legend_items = [_]LegendItem{
            .{ .label = "Used", .color = rgb(0x3D, 0x7E, 0xCB) },
            .{ .label = "Fragmented", .color = rgb(0xCC, 0x40, 0x00) },
            .{ .label = "Free", .color = rgb(0xE0, 0xE8, 0xF0) },
        };
        var lx = vx;
        for (legend_items) |item| {
            fb.fillRect(lx, legend_y, 12, 12, item.color);
            fb.drawTextTransparent(lx + 16, legend_y, item.label, rgb(0x40, 0x40, 0x50));
            lx += 80;
        }
    }

    fn renderProgress(dd: *DiskDefragWindow) void {
        const px = dd.x + 16;
        var py = dd.y + 370;

        const status_text = switch (dd.defrag_state) {
            .idle => "Ready",
            .analyzing => "Analyzing...",
            .defragmenting => "Defragmenting...",
            .paused => "Paused",
            .complete => "Defragmentation complete",
        };
        const status_color = switch (dd.defrag_state) {
            .idle => rgb(0x40, 0x40, 0x50),
            .analyzing => rgb(0x00, 0x80, 0xCC),
            .defragmenting => rgb(0xCC, 0x80, 0x00),
            .paused => rgb(0x80, 0x80, 0x80),
            .complete => rgb(0x00, 0x80, 0x00),
        };
        fb.drawTextTransparent(px, py, status_text, status_color);
        py += 22;

        if (dd.defrag_state != .idle) {
            const bar_x = px;
            const bar_y = py;
            const bar_w = dd.width - 32;
            const bar_h: i32 = 20;

            fb.draw3DRect(bar_x, bar_y, bar_w, bar_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
            const fill_w = @as(i32, @intCast(@as(f32, @floatFromInt(bar_w - 4)) * @as(f32, @floatFromInt(dd.progress_percent)) / 100.0));
            if (fill_w > 0) {
                fb.drawGradientH(bar_x + 2, bar_y + 2, fill_w, bar_h - 4, rgb(0x00, 0x66, 0xCC), rgb(0x3D, 0x7E, 0xCB));
            }

            var pct_buf: [16]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d}%", .{dd.progress_percent}) catch "";
            fb.drawTextTransparent(bar_x + @divTrunc(bar_w, 2) - 12, bar_y + 3, pct_str, rgb(0xFF, 0xFF, 0xFF));
        }
    }

    fn renderButtons(dd: *DiskDefragWindow) void {
        const bx = dd.x + dd.width - 220;
        const by = dd.y + dd.height - 50;
        const btn_w: i32 = 100;
        const btn_h: i32 = 28;
        const spacing: i32 = 8;

        const can_analyze = (dd.defrag_state == .idle);
        const can_defrag = (dd.defrag_state == .idle or dd.defrag_state == .complete);
        const can_pause = (dd.defrag_state == .defragmenting);
        const can_resume = (dd.defrag_state == .paused);

        dd.renderActionButton(bx, by, btn_w, btn_h, "Analyze", can_analyze);
        dd.renderActionButton(bx + @as(i32, @intCast(btn_w + spacing)), by, btn_w, btn_h, "Defragment", can_defrag);
        dd.renderActionButton(bx + @as(i32, @intCast((btn_w + spacing) * 2)), by, btn_w, btn_h, if (can_resume) "Resume" else "Pause", can_pause or can_resume);
    }

    fn renderActionButton(dd: *DiskDefragWindow, px: i32, py: i32, pw: i32, ph: i32, label: []const u8, enabled: bool) void {
        _ = dd;
        const bg = if (!enabled) rgb(0xE0, 0xE0, 0xE0) else rgb(0xE8, 0xEC, 0xF4);
        fb.fillRect(px, py, pw, ph, bg);
        fb.draw3DRect(px, py, pw, ph, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        const text_x = px + @divTrunc(pw, 2) - @as(i32, @intCast(label.len)) * 3;
        const text_y = py + 8;
        fb.drawTextTransparent(text_x, text_y, label, if (enabled) rgb(0x20, 0x20, 0x30) else rgb(0xC0, 0xC0, 0xC0));
    }

    const LegendItem = struct {
        label: []const u8,
        color: u32,
    };
};
