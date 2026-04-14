// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/media_player/media_player_main.zig
// Purpose: Windows Media Player 12 style application
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const PlaylistManager = @import("playlist.zig").PlaylistManager;
const Visualizer = @import("visualization.zig").Visualizer;

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const PlayerState = enum(u8) {
    stopped = 0,
    playing = 1,
    paused = 2,
    buffering = 3,
};

pub const MediaPlayerWindow = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    state: PlayerState,
    volume: f32,
    muted: bool,
    current_position_secs: u32,
    total_duration_secs: u32,
    playlist: PlaylistManager,
    visualizer: Visualizer,
    playlist_scroll: usize,
    now_playing_panel: bool,
    view_mode: ViewMode,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };
    pub const ViewMode = enum(u8) { full_mode, compact, mini };

    pub fn create(x_pos: i32, y_pos: i32) MediaPlayerWindow {
        return .{
            .x = x_pos,
            .y = y_pos,
            .width = 800,
            .height = 600,
            .visible = true,
            .caption_hover = .none,
            .state = .stopped,
            .volume = 0.7,
            .muted = false,
            .current_position_secs = 0,
            .total_duration_secs = 180,
            .playlist = PlaylistManager.create(),
            .visualizer = Visualizer.create(),
            .playlist_scroll = 0,
            .now_playing_panel = true,
            .view_mode = .full_mode,
        };
    }

    pub fn play(wp: *MediaPlayerWindow) void {
        if (wp.playlist.item_count > 0) {
            wp.state = .playing;
            if (wp.total_duration_secs == 0) {
                if (wp.playlist.getCurrentItem()) |item| {
                    wp.total_duration_secs = item.duration_secs;
                }
            }
        }
    }

    pub fn pause(wp: *MediaPlayerWindow) void {
        if (wp.state == .playing) {
            wp.state = .paused;
        }
    }

    pub fn stop(wp: *MediaPlayerWindow) void {
        wp.state = .stopped;
        wp.current_position_secs = 0;
    }

    pub fn togglePlayPause(wp: *MediaPlayerWindow) void {
        switch (wp.state) {
            .playing => wp.pause(),
            .paused, .stopped => wp.play(),
            else => {},
        }
    }

    pub fn seek(wp: *MediaPlayerWindow, position_secs: u32) void {
        wp.current_position_secs = @min(position_secs, wp.total_duration_secs);
    }

    pub fn setVolume(wp: *MediaPlayerWindow, vol: f32) void {
        wp.volume = @max(0.0, @min(1.0, vol));
    }

    pub fn toggleMute(wp: *MediaPlayerWindow) void {
        wp.muted = !wp.muted;
    }

    pub fn nextTrack(wp: *MediaPlayerWindow) void {
        wp.playlist.next();
        wp.current_position_secs = 0;
        if (wp.playlist.getCurrentItem()) |item| {
            wp.total_duration_secs = item.duration_secs;
        }
    }

    pub fn previousTrack(wp: *MediaPlayerWindow) void {
        if (wp.current_position_secs > 3) {
            wp.current_position_secs = 0;
        } else {
            wp.playlist.previous();
            wp.current_position_secs = 0;
            if (wp.playlist.getCurrentItem()) |item| {
                wp.total_duration_secs = item.duration_secs;
            }
        }
    }

    pub fn tick(wp: *MediaPlayerWindow) void {
        wp.visualizer.tick(wp.state == .playing);
        if (wp.state == .playing) {
            wp.current_position_secs += 1;
            if (wp.current_position_secs >= wp.total_duration_secs) {
                wp.nextTrack();
            }
        }
    }

    pub fn render(wp: *MediaPlayerWindow, t: *const theme_mod.ThemeColors) void {
        if (!wp.visible) return;

        const wx = wp.x;
        const wy = wp.y;
        const ww = wp.width;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 10, "Zircon Media Player", rgb(0xFF, 0xFF, 0xFF));
        const close_x = wx + ww - 48;
        if (wp.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        wp.renderMenuBar();
        wp.renderNowPlayingPanel();
        wp.renderPlaylistPanel(t);
        wp.renderBottomControls();
    }

    fn renderMenuBar(wp: *MediaPlayerWindow) void {
        const my = wp.y + 32;
        const mh: i32 = 24;
        const menus = [_][]const u8{ "File", "View", "Play", "Tools", "Help" };

        fb.fillRect(wp.x, my, wp.width, mh, rgb(0xF0, 0xF4, 0xF8));
        var mx = wp.x + 4;
        for (menus) |menu| {
            fb.drawTextTransparent(mx, my + 6, menu, rgb(0x20, 0x20, 0x30));
            mx += 60;
        }
        fb.fillRect(wp.x, my + mh, wp.width, 1, rgb(0xC0, 0xC8, 0xD8));
    }

    fn renderNowPlayingPanel(wp: *MediaPlayerWindow) void {
        const px = wp.x + 8;
        const py = wp.y + 60;
        const pw = wp.width / 2 - 16;
        const ph = wp.height - 200;

        fb.draw3DRect(px, py, pw, ph, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(px + 2, py + 2, pw - 4, ph - 4, rgb(0x15, 0x15, 0x20));

        const vis_h: i32 = ph - 100;
        wp.visualizer.render(px + 4, py + 4, pw - 8, vis_h);

        if (wp.playlist.getCurrentItem()) |item| {
            const info_y = py + vis_h + 10;
            fb.drawTextTransparent(px + 10, info_y, item.getDisplayTitle(), rgb(0xFF, 0xFF, 0xFF));
            fb.drawTextTransparent(px + 10, info_y + 18, item.artist[0..item.artist_len], rgb(0xB0, 0xB0, 0xC0));
            fb.drawTextTransparent(px + 10, info_y + 36, item.album[0..item.album_len], rgb(0x90, 0x90, 0xA0));
        }
    }

    fn renderPlaylistPanel(wp: *MediaPlayerWindow, t: *const theme_mod.ThemeColors) void {
        const px = wp.x + wp.width / 2;
        const py = wp.y + 60;
        const pw = wp.width / 2 - 16;
        const ph = wp.height - 200;

        wp.playlist.renderPlaylist(px, py, pw, ph, wp.playlist_scroll, t);
    }

    fn renderBottomControls(wp: *MediaPlayerWindow) void {
        const by = wp.y + wp.height - 120;
        const bw = wp.width - 16;

        fb.fillRect(wp.x + 8, by, bw, 100, rgb(0xF0, 0xF4, 0xF8));
        fb.draw3DRect(wp.x + 8, by, bw, 100, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        wp.renderProgressBar(by - 24, bw);
        wp.renderTransportControls(by + 10);
        wp.renderVolumeControl(by + 40);
    }

    fn renderProgressBar(wp: *MediaPlayerWindow, y: i32, w: i32) void {
        const px = wp.x + 8;
        const bar_w = w - 200;
        const bar_h: i32 = 8;

        fb.draw3DRect(px, y, bar_w, bar_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        const progress = if (wp.total_duration_secs > 0)
            @as(f32, @floatFromInt(wp.current_position_secs)) / @as(f32, @floatFromInt(wp.total_duration_secs))
        else
            0.0;
        const fill_w = @as(i32, @intCast(@as(f32, @floatFromInt(bar_w - 4)) * progress));
        if (fill_w > 0) {
            fb.drawGradientH(px + 2, y + 2, fill_w, bar_h - 4, rgb(0x3D, 0x7E, 0xCB), rgb(0x1A, 0x5C, 0xB8));
        }

        var cur_buf: [16]u8 = undefined;
        var tot_buf: [16]u8 = undefined;
        const cur_str = formatTime(wp.current_position_secs, &cur_buf);
        const tot_str = formatTime(wp.total_duration_secs, &tot_buf);

        fb.drawTextTransparent(px + bar_w + 10, y - 2, cur_str, rgb(0x40, 0x40, 0x60));
        fb.drawTextTransparent(px + w - 50, y - 2, tot_str, rgb(0x40, 0x40, 0x60));
    }

    fn renderTransportControls(wp: *MediaPlayerWindow) void {
        const cx = wp.x + @divTrunc(wp.width, 2);
        const cy = wp.y + wp.height - 80;

        const btn_size: i32 = 32;

        wp.renderTransportButton(cx - 50, cy, btn_size, btn_size, "<<", wp.current_position_secs > 0);
        wp.renderTransportButton(cx - 18, cy, btn_size + 4, btn_size + 4, if (wp.state == .playing) "||" else ">", true);
        wp.renderTransportButton(cx + 22, cy, btn_size, btn_size, ">>", true);
    }

    fn renderTransportButton(wp: *MediaPlayerWindow, px: i32, py: i32, pw: i32, ph: i32, label: []const u8, enabled: bool) void {
        _ = wp;
        const bg = if (!enabled) rgb(0xD0, 0xD0, 0xD8) else rgb(0xE8, 0xEC, 0xF4);
        fb.fillRect(px, py, pw, ph, bg);
        fb.draw3DRect(px, py, pw, ph, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        const text_x = px + @divTrunc(pw, 2) - @as(i32, @intCast(label.len)) * 3;
        const text_y = py + @divTrunc(ph, 2) - 4;
        fb.drawTextTransparent(text_x, text_y, label, if (enabled) rgb(0x20, 0x20, 0x30) else rgb(0xC0, 0xC0, 0xC8));
    }

    fn renderVolumeControl(wp: *MediaPlayerWindow) void {
        const vx = wp.x + wp.width - 180;
        const vy = wp.y + wp.height - 100;

        const mute_icon = if (wp.muted) "X" else "O";
        fb.fillRect(vx, vy, 24, 24, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(vx, vy, 24, 24, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        fb.drawTextTransparent(vx + 6, vy + 6, mute_icon, rgb(0x40, 0x40, 0x50));

        const slider_x = vx + 30;
        const slider_y = vy + 8;
        const slider_w: i32 = 80;
        const slider_h: i32 = 8;

        fb.draw3DRect(slider_x, slider_y, slider_w, slider_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        const vol = if (wp.muted) 0.0 else wp.volume;
        const fill_w = @as(i32, @intCast(@as(f32, @floatFromInt(slider_w - 4)) * vol));
        if (fill_w > 0) {
            fb.fillRect(slider_x + 2, slider_y + 2, fill_w, slider_h - 4, rgb(0x3D, 0x7E, 0xCB));
        }
    }

    fn formatTime(secs: u32, buf: *[16]u8) []const u8 {
        const mins = secs / 60;
        const s = secs % 60;
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ mins, s }) catch "00:00";
    }
};
