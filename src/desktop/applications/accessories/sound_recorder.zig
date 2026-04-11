// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/sound_recorder.zig
// Purpose: Sound Recorder application
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const SoundRecorderWindow = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    state: RecorderState,
    recording_time: u32,
    playback_position: u32,
    audio_levels: [32]i32,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };
    pub const RecorderState = enum { idle, recording, paused, playing };

    pub fn create(x_pos: i32, y_pos: i32) SoundRecorderWindow {
        return .{
            .x = x_pos,
            .y = y_pos,
            .width = 450,
            .height = 280,
            .visible = true,
            .caption_hover = .none,
            .state = .idle,
            .recording_time = 0,
            .playback_position = 0,
            .audio_levels = [_]i32{0} ** 32,
        };
    }

    pub fn startRecording(sr: *SoundRecorderWindow) void {
        sr.state = .recording;
        sr.recording_time = 0;
    }

    pub fn stopRecording(sr: *SoundRecorderWindow) void {
        sr.state = .idle;
    }

    pub fn playRecording(sr: *SoundRecorderWindow) void {
        if (sr.recording_time > 0) {
            sr.state = .playing;
            sr.playback_position = 0;
        }
    }

    pub fn tick(sr: *SoundRecorderWindow) void {
        if (sr.state == .recording) {
            sr.recording_time += 1;
            for (&sr.audio_levels, 0..) |*level, i| {
                level.* = @as(i32, @intCast(@mod(sr.recording_time * 17 + @as(u32, @intCast(i)) * 7, 100))) - 50;
            }
        } else if (sr.state == .playing) {
            sr.playback_position += 1;
            if (sr.playback_position >= sr.recording_time) {
                sr.state = .idle;
                sr.playback_position = 0;
            }
            for (&sr.audio_levels, 0..) |*level, i| {
                level.* = @as(i32, @intCast(@mod(sr.playback_position * 13 + @as(u32, @intCast(i)) * 7, 100))) - 50;
            }
        }
    }

    pub fn render(sr: *SoundRecorderWindow, t: *const theme_mod.ThemeColors) void {
        if (!sr.visible) return;
        _ = t;

        const wx = sr.x;
        const wy = sr.y;
        const ww = sr.width;
        const wh = sr.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 10, "Sound Recorder", rgb(0xFF, 0xFF, 0xFF));
        const close_x = wx + ww - 48;
        if (sr.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 34, rgb(0xF8, 0xFC, 0xFF));

        sr.renderTimeDisplay();
        sr.renderWaveform();
        sr.renderControls();
        sr.renderStatus();
    }

    fn renderTimeDisplay(sr: *SoundRecorderWindow) void {
        const cx = sr.x + @divTrunc(sr.width, 2);
        const cy = sr.y + 80;

        const current_time = if (sr.state == .playing) sr.playback_position else sr.recording_time;
        const minutes = current_time / 3600;
        const seconds = (current_time / 60) % 60;
        const centisecs = current_time % 60;

        var buf: [32]u8 = undefined;
        const time_str = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ minutes, seconds, centisecs }) catch "";

        fb.drawTextTransparent(cx - 40, cy, time_str, rgb(0x10, 0x10, 0x40));
    }

    fn renderWaveform(sr: *SoundRecorderWindow) void {
        const wx = sr.x + 20;
        const wy = sr.y + 120;
        const ww = sr.width - 40;
        const wh = 80;
        const bar_w: i32 = @divTrunc(ww, 32);

        fb.draw3DRect(wx, wy, ww, wh, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        for (sr.audio_levels, 0..) |level, i| {
            const bx = wx + @as(i32, @intCast(i)) * (bar_w + 1);
            const normalized = @as(f32, @floatFromInt(@abs(level))) / 50.0;
            const bar_h = @as(i32, @intCast(normalized * @as(f32, @floatFromInt(wh - 8))));
            const bar_y = wy + @divTrunc(wh, 2) - @divTrunc(bar_h, 2);
            const bar_color = switch (sr.state) {
                .recording => rgb(0xCC, 0x00, 0x00),
                .playing => rgb(0x00, 0x66, 0xCC),
                else => rgb(0x80, 0x80, 0x80),
            };
            fb.fillRect(bx, bar_y, bar_w, @max(2, bar_h), bar_color);
        }
    }

    fn renderControls(sr: *SoundRecorderWindow) void {
        const cx = sr.x + @divTrunc(sr.width, 2);
        const cy = sr.y + 220;
        const spacing: i32 = 60;

        sr.renderControlButton(cx - spacing - 25, cy, 50, 50, "REC", sr.state == .idle, rgb(0xCC, 0x00, 0x00));
        sr.renderControlButton(cx - 25, cy, 50, 50, "STOP", sr.state != .idle, rgb(0x80, 0x80, 0x80));
        sr.renderControlButton(cx + spacing - 25, cy, 50, 50, "PLAY", sr.state == .idle and sr.recording_time > 0, rgb(0x00, 0x80, 0x00));
    }

    fn renderControlButton(sr: *SoundRecorderWindow, px: i32, py: i32, pw: i32, ph: i32, label: []const u8, enabled: bool, accent: u32) void {
        _ = sr;
        const bg = if (!enabled) rgb(0xE0, 0xE0, 0xE0) else rgb(0xF0, 0xF4, 0xF8);
        fb.fillRect(px, py, pw, ph, bg);
        fb.draw3DRect(px, py, pw, ph, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));

        if (enabled) {
            fb.fillEllipse(px + pw / 2, py + ph / 2, pw / 4, ph / 4, accent);
        }

        const text_x = px + @divTrunc(pw, 2) - @as(i32, @intCast(label.len)) * 3;
        const text_y = py + ph + 4;
        fb.drawTextTransparent(text_x, text_y, label, if (enabled) rgb(0x40, 0x40, 0x50) else rgb(0xC0, 0xC0, 0xC0));
    }

    fn renderStatus(sr: *SoundRecorderWindow) void {
        const status_text = switch (sr.state) {
            .idle => "Ready to record",
            .recording => "Recording...",
            .paused => "Paused",
            .playing => "Playing...",
        };
        const status_color = switch (sr.state) {
            .idle => rgb(0x60, 0x60, 0x60),
            .recording => rgb(0xCC, 0x00, 0x00),
            .paused => rgb(0xCC, 0xA0, 0x00),
            .playing => rgb(0x00, 0x80, 0xCC),
        };
        fb.drawTextTransparent(sr.x + @divTrunc(sr.width, 2) - 50, sr.y + sr.height - 30, status_text, status_color);
    }
};
