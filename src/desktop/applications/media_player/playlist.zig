// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/media_player/playlist.zig
// Purpose: Playlist management for Media Player
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const PlaylistItem = struct {
    title: [128]u8,
    title_len: usize,
    artist: [64]u8,
    artist_len: usize,
    album: [64]u8,
    album_len: usize,
    duration_secs: u32,
    file_path: [256]u8,
    file_path_len: usize,
    file_type: FileType,
    is_playing: bool,
    is_selected: bool,

    pub const FileType = enum(u8) {
        unknown = 0,
        mp3 = 1,
        wav = 2,
        flac = 3,
        ogg = 4,
        wma = 5,
        m4a = 6,
        video_mp4 = 10,
        video_avi = 11,
        video_wmv = 12,
        video_mkv = 13,
    };

    pub fn getDisplayTitle(item: *const PlaylistItem) []const u8 {
        if (item.title_len > 0) {
            return item.title[0..item.title_len];
        }
        return item.file_path[0..item.file_path_len];
    }

    pub fn formatDuration(item: *const PlaylistItem, buf: *[16]u8) []const u8 {
        const mins = item.duration_secs / 60;
        const secs = item.duration_secs % 60;
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ mins, secs }) catch "00:00";
    }
};

pub const PlaylistManager = struct {
    items: [100]PlaylistItem,
    item_count: usize,
    current_index: usize,
    shuffle_enabled: bool,
    repeat_mode: RepeatMode,
    sort_by: SortField,
    sort_ascending: bool,

    pub const RepeatMode = enum(u8) { none, one, all };
    pub const SortField = enum(u8) { title, artist, album, duration, added };

    pub fn create() PlaylistManager {
        var pm: PlaylistManager = .{
            .items = undefined,
            .item_count = 0,
            .current_index = 0,
            .shuffle_enabled = false,
            .repeat_mode = .none,
            .sort_by = .added,
            .sort_ascending = true,
        };
        pm.addDefaultItems();
        return pm;
    }

    fn addDefaultItems(pm: *PlaylistManager) void {
        pm.addItem("Welcome Song", "ZirconOSAero", "Demo Album", 180, "C:\\Music\\welcome.mp3", .mp3);
        pm.addItem("System Chime", "ZirconOSAero", "System Sounds", 15, "C:\\Music\\chime.wav", .wav);
        pm.addItem("Ambient Loop", "ZirconOSAero", "Ambient", 240, "C:\\Music\\ambient.ogg", .ogg);
        pm.addItem("Startup Theme", "ZirconOSAero", "System Sounds", 30, "C:\\Music\\startup.wav", .wav);
        pm.addItem("Notification Ping", "ZirconOSAero", "System Sounds", 5, "C:\\Music\\ping.wav", .wav);
        pm.addItem("Demo Track 1", "Artist A", "Album A", 210, "C:\\Music\\track1.mp3", .mp3);
        pm.addItem("Demo Track 2", "Artist B", "Album B", 195, "C:\\Music\\track2.flac", .flac);
        pm.addItem("Demo Track 3", "Artist C", "Album C", 300, "C:\\Music\\track3.wma", .wma);
    }

    pub fn addItem(pm: *PlaylistManager, title: []const u8, artist: []const u8, album: []const u8, duration: u32, path: []const u8, ftype: PlaylistItem.FileType) void {
        if (pm.item_count >= pm.items.len) return;
        var item = &pm.items[pm.item_count];
        item.* = .{
            .title = undefined,
            .title_len = 0,
            .artist = undefined,
            .artist_len = 0,
            .album = undefined,
            .album_len = 0,
            .duration_secs = duration,
            .file_path = undefined,
            .file_path_len = 0,
            .file_type = ftype,
            .is_playing = false,
            .is_selected = false,
        };
        @memcpy(item.title[0..@min(title.len, item.title.len)], title);
        item.title_len = @min(title.len, item.title.len);
        @memcpy(item.artist[0..@min(artist.len, item.artist.len)], artist);
        item.artist_len = @min(artist.len, item.artist.len);
        @memcpy(item.album[0..@min(album.len, item.album.len)], album);
        item.album_len = @min(album.len, item.album.len);
        @memcpy(item.file_path[0..@min(path.len, item.file_path.len)], path);
        item.file_path_len = @min(path.len, item.file_path.len);
        pm.item_count += 1;
    }

    pub fn removeItem(pm: *PlaylistManager, index: usize) void {
        if (index >= pm.item_count) return;
        var i = index;
        while (i < pm.item_count - 1) : (i += 1) {
            pm.items[i] = pm.items[i + 1];
        }
        pm.item_count -= 1;
        if (pm.current_index >= pm.item_count) {
            pm.current_index = if (pm.item_count > 0) pm.item_count - 1 else 0;
        }
    }

    pub fn getCurrentItem(pm: *const PlaylistManager) ?*const PlaylistItem {
        if (pm.current_index < pm.item_count) {
            return &pm.items[pm.current_index];
        }
        return null;
    }

    pub fn playItem(pm: *PlaylistManager, index: usize) void {
        for (&pm.items, 0..) |*item, i| {
            item.is_playing = (i == index);
        }
        if (index < pm.item_count) {
            pm.current_index = index;
        }
    }

    pub fn next(pm: *PlaylistManager) void {
        if (pm.item_count == 0) return;
        pm.items[pm.current_index].is_playing = false;
        switch (pm.repeat_mode) {
            .one => {},
            .all => {
                pm.current_index = (pm.current_index + 1) % pm.item_count;
            },
            .none => {
                if (pm.current_index + 1 < pm.item_count) {
                    pm.current_index += 1;
                }
            },
        }
        pm.items[pm.current_index].is_playing = true;
    }

    pub fn previous(pm: *PlaylistManager) void {
        if (pm.item_count == 0) return;
        pm.items[pm.current_index].is_playing = false;
        if (pm.current_index > 0) {
            pm.current_index -= 1;
        }
        pm.items[pm.current_index].is_playing = true;
    }

    pub fn toggleShuffle(pm: *PlaylistManager) void {
        pm.shuffle_enabled = !pm.shuffle_enabled;
    }

    pub fn cycleRepeat(pm: *PlaylistManager) void {
        pm.repeat_mode = switch (pm.repeat_mode) {
            .none => .all,
            .all => .one,
            .one => .none,
        };
    }

    pub fn selectItem(pm: *PlaylistManager, index: usize) void {
        for (&pm.items, 0..) |*item, i| {
            item.is_selected = (i == index);
        }
    }

    pub fn clearSelection(pm: *PlaylistManager) void {
        for (&pm.items) |*item| {
            item.is_selected = false;
        }
    }

    pub fn renderPlaylist(pm: *PlaylistManager, x: i32, y: i32, w: i32, h: i32, scroll_offset: usize, t: *const theme_mod.ThemeColors) void {
        _ = t;
        fb.draw3DRect(x, y, w, h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(x + 2, y + 2, w - 4, h - 4, rgb(0xF8, 0xFC, 0xFF));

        const header_h: i32 = 24;
        fb.fillRect(x + 2, y + 2, w - 4, header_h, rgb(0xE8, 0xEC, 0xF4));
        fb.drawTextTransparent(x + 8, y + 6, "Title", rgb(0x30, 0x30, 0x50));
        fb.drawTextTransparent(x + 200, y + 6, "Artist", rgb(0x30, 0x30, 0x50));
        fb.drawTextTransparent(x + 320, y + 6, "Duration", rgb(0x30, 0x30, 0x50));
        fb.fillRect(x + 2, y + header_h + 2, w - 4, 1, rgb(0xC0, 0xC8, 0xD0));

        const row_h: i32 = 20;
        var row_y = y + header_h + 4;
        const visible_rows = @as(usize, @intCast((h - header_h - 8) / row_h));

        var i: usize = 0;
        while (i < visible_rows and i + scroll_offset < pm.item_count) : (i += 1) {
            const item_index = i + scroll_offset;
            const item = &pm.items[item_index];

            const row_bg = if (item.is_selected) rgb(0xD8, 0xE8, 0xF8)
                else if (item.is_playing) rgb(0xE8, 0xF0, 0xFF)
                else if (i % 2 == 0) rgb(0xF8, 0xFC, 0xFF)
                else rgb(0xF0, 0xF8, 0xFF);

            fb.fillRect(x + 2, row_y, w - 4, row_h, row_bg);

            const title_str = item.getDisplayTitle();
            const text_color = if (item.is_playing) rgb(0x00, 0x50, 0xCC) else rgb(0x20, 0x20, 0x40);
            fb.drawTextTransparent(x + 8, row_y + 4, title_str, text_color);

            fb.drawTextTransparent(x + 200, row_y + 4, item.artist[0..item.artist_len], rgb(0x60, 0x60, 0x70));

            var dur_buf: [16]u8 = undefined;
            const dur_str = item.formatDuration(&dur_buf);
            fb.drawTextTransparent(x + 320, row_y + 4, dur_str, rgb(0x60, 0x60, 0x70));

            if (item.is_playing) {
                fb.drawTextTransparent(x + w - 40, row_y + 4, "[>]", rgb(0x00, 0x80, 0x00));
            }

            row_y += row_h;
        }
    }
};
