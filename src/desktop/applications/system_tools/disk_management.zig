// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/system_tools/disk_management.zig
// Purpose: Disk Management - Storage device management utility
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");
const explorer_vol_snap = @import("../../../../fs/explorer_volume_snapshot.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const VolumeInfo = struct {
    letter: u8,
    label: [32]u8,
    label_len: usize,
    total_size: u64,
    free_space: u64,
    fs_type: [16]u8,
    fs_type_len: usize,
};

pub const DiskManagementApp = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    
    volumes: [8]VolumeInfo,
    volume_count: usize,
    selected_volume: i32,
    
    hover_refresh: bool,
    hover_action: bool,
    hover_compress: bool,
    hover_format: bool,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) DiskManagementApp {
        var app: DiskManagementApp = .{
            .x = x_pos, .y = y_pos,
            .width = 640, .height = 480,
            .visible = true, .caption_hover = .none,
            .volumes = undefined, .volume_count = 0,
            .selected_volume = -1,
            .hover_refresh = false, .hover_action = false,
            .hover_compress = false, .hover_format = false,
        };
        
        app.initVolumes();
        return app;
    }

    fn initVolumes(app: *DiskManagementApp) void {
        explorer_vol_snap.explorerEnsureVolumeSnapshot();
        const vols = explorer_vol_snap.explorerVolumes();
        
        app.volume_count = 0;
        for (vols) |v| {
            if (app.volume_count >= app.volumes.len) break;
            
            var vol = &app.volumes[app.volume_count];
            vol.letter = v.letter;
            
            // Parse label from name
            var name_copy: [64]u8 = undefined;
            var name_len: usize = 0;
            for (v.name) |c| {
                if (c == 0) break;
                name_copy[name_len] = c;
                name_len += 1;
            }
            
            vol.label_len = @min(name_len, vol.label.len);
            @memcpy(vol.label[0..vol.label_len], name_copy[0..vol.label_len]);
            
            // Calculate sizes
            vol.total_size = v.total_sectors * v.bytes_per_sector;
            vol.free_space = v.free_sectors * v.bytes_per_sector;
            
            // File system type
            const fs = switch (v.fs_type) {
                .fat12, .fat16, .fat32 => "FAT32",
                .ntfs => "NTFS",
                .exfat => "exFAT",
                .iso9660 => "ISO9660",
                .udf => "UDF",
                else => "Unknown",
            };
            vol.fs_type_len = fs.len;
            @memcpy(vol.fs_type[0..fs.len], fs);
            
            app.volume_count += 1;
        }
        
        // Add sample entries if none found
        if (app.volume_count == 0) {
            app.volumes[0].letter = 'C';
            const c_label = "System";
            @memcpy(app.volumes[0].label[0..c_label.len], c_label);
            app.volumes[0].label_len = c_label.len;
            app.volumes[0].total_size = 50 * 1024 * 1024 * 1024;
            app.volumes[0].free_space = 30 * 1024 * 1024 * 1024;
            const c_fs = "NTFS";
            @memcpy(app.volumes[0].fs_type[0..c_fs.len], c_fs);
            app.volumes[0].fs_type_len = c_fs.len;
            app.volume_count = 1;
        }
    }

    pub fn refresh(app: *DiskManagementApp) void {
        app.initVolumes();
    }

    pub fn render(app: *const DiskManagementApp, t: *const theme_mod.ThemeColors) void {
        if (!app.visible) return;
        _ = t;

        const wx = app.x;
        const wy = app.y;
        const ww = app.width;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 6, "Disk Management", rgb(0xFF, 0xFF, 0xFF));

        const close_x = wx + ww - 48;
        if (app.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        // Toolbar
        const toolbar_y = wy + 38;
        fb.fillRect(wx, toolbar_y, ww, 35, rgb(0xF0, 0xF4, 0xF8));
        fb.drawHLine(wx, toolbar_y + 35, ww, rgb(0xCC, 0xCC, 0xCC));
        
        // Refresh button
        const ref_x = wx + 10;
        fb.fillRect(ref_x, toolbar_y + 5, 80, 26, if (app.hover_refresh) rgb(0xD0, 0xD0, 0xD0) else rgb(0xE8, 0xE8, 0xE8));
        fb.draw3DRect(ref_x, toolbar_y + 5, 80, 26, rgb(0xB0, 0xB0, 0xB0), rgb(0xFF, 0xFF, 0xFF));
        fb.drawTextTransparent(ref_x + 20, toolbar_y + 12, "Refresh", rgb(0x30, 0x30, 0x40));
        
        // Volume list header
        const list_y = toolbar_y + 45;
        fb.fillRect(wx, list_y, ww, 25, rgb(0xE8, 0xEC, 0xF0));
        fb.drawTextTransparent(wx + 10, list_y + 6, "Volume", rgb(0x20, 0x40, 0x80));
        fb.drawTextTransparent(wx + 80, list_y + 6, "Layout", rgb(0x20, 0x40, 0x80));
        fb.drawTextTransparent(wx + 250, list_y + 6, "Type", rgb(0x20, 0x40, 0x80));
        fb.drawTextTransparent(wx + 350, list_y + 6, "File System", rgb(0x20, 0x40, 0x80));
        fb.drawTextTransparent(wx + 450, list_y + 6, "Size", rgb(0x20, 0x40, 0x80));
        fb.drawTextTransparent(wx + 530, list_y + 6, "Free", rgb(0x20, 0x40, 0x80));
        
        // Volume list
        const item_h: i32 = 50;
        for (0..app.volume_count) |i| {
            const item_y = list_y + 25 + @as(i32, @intCast(i)) * item_h;
            const vol = app.volumes[i];
            const is_selected = @as(i32, @intCast(i)) == app.selected_volume;
            
            // Row background
            var row_bg = rgb(0xFF, 0xFF, 0xFF);
            if (is_selected) {
                row_bg = rgb(0xD0, 0xE8, 0xF8);
            }
            fb.fillRect(wx, item_y, ww, item_h, row_bg);
            fb.drawHLine(wx, item_y + item_h, ww, rgb(0xE0, 0xE0, 0xE0));
            
            // Volume letter and label
            var letter_buf: [4]u8 = .{ @as(u8, vol.letter), ':', ' ', 0 };
            fb.drawTextTransparent(wx + 10, item_y + 8, &letter_buf, rgb(0x20, 0x20, 0x30));
            fb.drawTextTransparent(wx + 10, item_y + 24, vol.label[0..vol.label_len], rgb(0x60, 0x60, 0x70));
            
            // Layout bar (visual representation)
            const bar_x = wx + 80;
            const bar_y = item_y + 15;
            const bar_w: i32 = 150;
            const bar_h: i32 = 16;
            
            fb.fillRect(bar_x, bar_y, bar_w, bar_h, rgb(0xD0, 0xD0, 0xD8));
            fb.drawRect(bar_x, bar_y, bar_w, bar_h, rgb(0x80, 0x80, 0x90));
            
            // Used space
            const used_ratio = if (vol.total_size > 0)
                @as(f32, @floatFromInt(vol.total_size - vol.free_space)) / @as(f32, @floatFromInt(vol.total_size))
            else
                0.0;
            const used_w = @as(i32, @intFromFloat(used_ratio * @as(f32, @floatFromInt(bar_w))));
            
            const used_color = if (used_ratio > 0.9)
                rgb(0xE0, 0x40, 0x40)
            else if (used_ratio > 0.7)
                rgb(0xE0, 0xA0, 0x40)
            else
                rgb(0x40, 0xA0, 0x40);
            
            if (used_w > 0) {
                fb.fillRect(bar_x, bar_y, used_w, bar_h, used_color);
            }
            
            // Type
            fb.drawTextTransparent(wx + 250, item_y + 18, "Basic", rgb(0x40, 0x40, 0x50));
            
            // File system
            fb.drawTextTransparent(wx + 350, item_y + 18, vol.fs_type[0..vol.fs_type_len], rgb(0x40, 0x40, 0x50));
            
            // Size
            var size_buf: [32]u8 = undefined;
            const size_str = formatSize(&size_buf, vol.total_size);
            fb.drawTextTransparent(wx + 450, item_y + 18, size_str, rgb(0x40, 0x40, 0x50));
            
            // Free space
            var free_buf: [32]u8 = undefined;
            const free_str = formatSize(&free_buf, vol.free_space);
            const free_color = if (vol.total_size > 0 and @as(f32, @floatFromInt(vol.free_space)) / @as(f32, @floatFromInt(vol.total_size)) < 0.1)
                rgb(0xC0, 0x40, 0x40)
            else
                rgb(0x40, 0x40, 0x50);
            fb.drawTextTransparent(wx + 530, item_y + 18, free_str, free_color);
        }
        
        // Details pane
        const details_y = list_y + 25 + @as(i32, @intCast(app.volume_count)) * item_h + 10;
        
        if (app.selected_volume >= 0) {
            const idx = @as(usize, @intCast(app.selected_volume));
            if (idx < app.volume_count) {
                const vol = app.volumes[idx];
                
                fb.fillRect(wx + 10, details_y, ww - 20, 80, rgb(0xF8, 0xFA, 0xFC));
                fb.draw3DRect(wx + 10, details_y, ww - 20, 80, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
                
                var letter_buf: [4]u8 = .{ vol.letter, ':', ' ', 0 };
                fb.drawTextTransparent(wx + 20, details_y + 10, &letter_buf, rgb(0x20, 0x40, 0x80));
                fb.drawTextTransparent(wx + 50, details_y + 10, vol.label[0..vol.label_len], rgb(0x20, 0x20, 0x30));
                
                fb.drawTextTransparent(wx + 20, details_y + 35, "Capacity:", rgb(0x60, 0x60, 0x70));
                var cap_buf: [32]u8 = undefined;
                const cap_str = formatSize(&cap_buf, vol.total_size);
                fb.drawTextTransparent(wx + 90, details_y + 35, cap_str, rgb(0x40, 0x40, 0x50));
                
                fb.drawTextTransparent(wx + 200, details_y + 35, "Free:", rgb(0x60, 0x60, 0x70));
                var free_buf: [32]u8 = undefined;
                const free_str = formatSize(&free_buf, vol.free_space);
                fb.drawTextTransparent(wx + 240, details_y + 35, free_str, rgb(0x40, 0x40, 0x50));
                
                fb.drawTextTransparent(wx + 20, details_y + 55, "File System:", rgb(0x60, 0x60, 0x70));
                fb.drawTextTransparent(wx + 110, details_y + 55, vol.fs_type[0..vol.fs_type_len], rgb(0x40, 0x40, 0x50));
                
                fb.drawTextTransparent(wx + 200, details_y + 55, "Used:", rgb(0x60, 0x60, 0x70));
                var used_buf: [32]u8 = undefined;
                const used_str = formatSize(&used_buf, vol.total_size - vol.free_space);
                fb.drawTextTransparent(wx + 250, details_y + 55, used_str, rgb(0x40, 0x40, 0x50));
            }
        }
    }

    fn formatSize(buf: *[32]u8, size: u64) []const u8 {
        const kb = size / 1024;
        const mb = kb / 1024;
        const gb = mb / 1024;
        const tb = gb / 1024;
        
        if (tb > 0) {
            const frac_gb = @as(u32, @intCast(gb % 1024)) / 100;
            return std.fmt.bufPrint(buf, "{d}.{d} TB", .{ tb, frac_gb }) catch "";
        } else if (gb > 0) {
            const frac_mb = @as(u32, @intCast(mb % 1024)) / 100;
            return std.fmt.bufPrint(buf, "{d}.{d} GB", .{ gb, frac_mb }) catch "";
        } else if (mb > 0) {
            return std.fmt.bufPrint(buf, "{d} MB", .{ mb }) catch "";
        } else {
            return std.fmt.bufPrint(buf, "{d} KB", .{ kb }) catch "";
        }
    }

    pub fn handleClick(app: *DiskManagementApp, px: i32, py: i32) void {
        const wx = app.x;
        const wy = app.y;

        // Refresh button
        if (px >= wx + 10 and px < wx + 90 and py >= wy + 43 and py < wy + 69) {
            app.refresh();
            return;
        }
        
        // Volume list
        const list_y = wy + 108;
        const item_h: i32 = 50;
        
        if (py >= list_y + 25) {
            const idx = @divTrunc(py - list_y - 25, item_h);
            if (idx >= 0 and @as(usize, @intCast(idx)) < app.volume_count) {
                app.selected_volume = @as(i32, @intCast(idx));
            }
        }
    }

    pub fn handleMouseMove(app: *DiskManagementApp, px: i32, py: i32) void {
        const wx = app.x;
        const wy = app.y;
        
        app.hover_refresh = (px >= wx + 10 and px < wx + 90 and py >= wy + 43 and py < wy + 69);
    }
};
