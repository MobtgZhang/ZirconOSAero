// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/sound_recorder.zig
// Purpose: Sound Recorder application with WAV support
//
// This is an independent clean-room implementation.
// Clean Room: Based on public Win7 UI behavior only. No source code copied.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const builtin_apps = @import("../../kernel/shell/builtin_apps.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

/// WAV file header structure
pub const WavHeader = struct {
    riff: [4]u8 = .{ 'R', 'I', 'F', 'F' },
    file_size: u32 = 0,
    wave: [4]u8 = .{ 'W', 'A', 'V', 'E' },
    fmt: [4]u8 = .{ 'f', 'm', 't', ' ' },
    fmt_size: u32 = 16,
    audio_format: u16 = 1,
    num_channels: u16 = 1,
    sample_rate: u32 = 44100,
    byte_rate: u32 = 88200,
    block_align: u16 = 2,
    bits_per_sample: u16 = 16,
    data: [4]u8 = .{ 'd', 'a', 't', 'a' },
    data_size: u32 = 0,
};

/// Audio format options
pub const AudioFormat = enum {
    pcm_44100_mono_16bit,
    pcm_22050_mono_16bit,
    pcm_48000_stereo_16bit,
};

/// Recording quality level
pub const RecordingQuality = enum {
    low,
    medium,
    high,
};

/// Sound Recorder window with enhanced functionality
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
    playback_duration: u32,
    audio_levels: [64]i32,
    audio_history: [8192]i16,
    audio_sample_count: usize,
    audio_format: AudioFormat,
    quality: RecordingQuality,

    file_name: [256]u8,
    file_name_len: usize,
    has_unsaved_data: bool,

    hover_record: bool,
    hover_stop: bool,
    hover_play: bool,
    hover_save: bool,
    hover_new: bool,
    hover_quality: i32,

    waveform_scroll: i32,
    waveform_zoom: f32,

    input_volume: f32,
    playback_volume: f32,

    slider_hover: bool,
    slider_dragging: bool,
    slider_position: f32,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };
    pub const RecorderState = enum { idle, recording, paused, playing, stopped };

    pub fn create(x_pos: i32, y_pos: i32) SoundRecorderWindow {
        return .{
            .x = x_pos,
            .y = y_pos,
            .width = 500,
            .height = 340,
            .visible = true,
            .caption_hover = .none,
            .state = .idle,
            .recording_time = 0,
            .playback_position = 0,
            .playback_duration = 0,
            .audio_levels = [_]i32{0} ** 64,
            .audio_history = [_]i16{0} ** 8192,
            .audio_sample_count = 0,
            .audio_format = .pcm_44100_mono_16bit,
            .quality = .medium,
            .file_name = undefined,
            .file_name_len = 0,
            .has_unsaved_data = false,
            .hover_record = false,
            .hover_stop = false,
            .hover_play = false,
            .hover_save = false,
            .hover_new = false,
            .hover_quality = -1,
            .waveform_scroll = 0,
            .waveform_zoom = 1.0,
            .input_volume = 0.8,
            .playback_volume = 0.8,
            .slider_hover = false,
            .slider_dragging = false,
            .slider_position = 0.0,
        };
    }

    pub fn startRecording(sr: *SoundRecorderWindow) void {
        sr.state = .recording;
        sr.recording_time = 0;
        sr.audio_sample_count = 0;
        sr.playback_duration = 0;
        sr.has_unsaved_data = true;
        for (&sr.audio_history) |*s| {
            s.* = 0;
        }
    }

    pub fn stopRecording(sr: *SoundRecorderWindow) void {
        if (sr.state == .recording or sr.state == .playing) {
            sr.state = .stopped;
            sr.playback_duration = sr.recording_time;
        }
    }

    pub fn pauseRecording(sr: *SoundRecorderWindow) void {
        if (sr.state == .recording) {
            sr.state = .paused;
        } else if (sr.state == .playing) {
            sr.state = .paused;
        }
    }

    pub fn resumeRecording(sr: *SoundRecorderWindow) void {
        if (sr.state == .paused) {
            sr.state = .recording;
        }
    }

    pub fn playRecording(sr: *SoundRecorderWindow) void {
        if (sr.audio_sample_count > 0) {
            sr.state = .playing;
            sr.playback_position = 0;
        }
    }

    pub fn addAudioSample(sr: *SoundRecorderWindow, sample: i16) void {
        if (sr.audio_sample_count < sr.audio_history.len) {
            sr.audio_history[sr.audio_sample_count] = sample;
            sr.audio_sample_count += 1;
        }
    }

    pub fn tick(sr: *SoundRecorderWindow) void {
        if (sr.state == .recording) {
            sr.recording_time += 1;
            for (&sr.audio_levels, 0..) |*level, i| {
                level.* = @as(i32, @intCast(@mod(@as(u32, @intCast(sr.recording_time)) * 17 + @as(u32, @intCast(i)) * 7, 100))) - 50;
            }
            if (sr.audio_sample_count < sr.audio_history.len) {
                const sample: i16 = @intCast(@mod(@as(u32, @intCast(sr.recording_time)) * 256, 65536) - 32768);
                sr.audio_history[sr.audio_sample_count] = sample;
                sr.audio_sample_count += 1;
            }
            sr.playback_duration = sr.recording_time;
        } else if (sr.state == .playing) {
            sr.playback_position += 1;
            if (sr.playback_position >= sr.playback_duration) {
                sr.state = .stopped;
                sr.playback_position = 0;
            }
            for (&sr.audio_levels, 0..) |*level, i| {
                const idx = (sr.playback_position * 64 + i) % sr.audio_sample_count;
                if (idx < sr.audio_sample_count) {
                    level.* = @as(i32, @intCast(sr.audio_history[idx])) / 256;
                } else {
                    level.* = 0;
                }
            }
        } else {
            for (&sr.audio_levels, 0..) |*level, i| {
                if (sr.audio_sample_count > 0) {
                    const idx = (i * sr.audio_sample_count) / 64;
                    if (idx < sr.audio_sample_count) {
                        level.* = @as(i32, @intCast(sr.audio_history[idx])) / 256;
                    } else {
                        level.* = 0;
                    }
                } else {
                    level.* = 0;
                }
            }
        }
    }

    pub fn setQuality(sr: *SoundRecorderWindow, quality: RecordingQuality) void {
        sr.quality = quality;
        sr.audio_format = switch (quality) {
            .low => .pcm_22050_mono_16bit,
            .medium => .pcm_44100_mono_16bit,
            .high => .pcm_48000_stereo_16bit,
        };
    }

    pub fn getSampleRate(sr: *const SoundRecorderWindow) u32 {
        return switch (sr.audio_format) {
            .pcm_22050_mono_16bit => 22050,
            .pcm_44100_mono_16bit => 44100,
            .pcm_48000_stereo_16bit => 48000,
        };
    }

    pub fn generateWavData(sr: *const SoundRecorderWindow, buf: []u8) usize {
        if (buf.len < 44) return 0;

        const sample_count = sr.audio_sample_count;
        const num_channels: u16 = switch (sr.audio_format) {
            .pcm_22050_mono_16bit, .pcm_44100_mono_16bit => 1,
            .pcm_48000_stereo_16bit => 2,
        };
        const bits_per_sample: u16 = 16;
        const sample_rate = sr.getSampleRate();
        const byte_rate = sample_rate * @as(u32, num_channels) * @as(u32, bits_per_sample / 8);
        const block_align = num_channels * (bits_per_sample / 8);
        const data_size = @as(u32, @intCast(sample_count)) * @as(u32, block_align);
        const file_size = 36 + data_size;

        var pos: usize = 0;

        buf[pos] = 'R';
        pos += 1;
        buf[pos] = 'I';
        pos += 1;
        buf[pos] = 'F';
        pos += 1;
        buf[pos] = 'F';
        pos += 1;

        std.mem.writeInt(u32, buf[pos..][0..4], file_size, .little);
        pos += 4;

        buf[pos] = 'W';
        pos += 1;
        buf[pos] = 'A';
        pos += 1;
        buf[pos] = 'V';
        pos += 1;
        buf[pos] = 'E';
        pos += 1;

        buf[pos] = 'f';
        pos += 1;
        buf[pos] = 'm';
        pos += 1;
        buf[pos] = 't';
        pos += 1;
        buf[pos] = ' ';
        pos += 1;

        std.mem.writeInt(u32, buf[pos..][0..4], 16, .little);
        pos += 4;

        std.mem.writeInt(u16, buf[pos..][0..2], 1, .little);
        pos += 2;

        std.mem.writeInt(u16, buf[pos..][0..2], num_channels, .little);
        pos += 2;

        std.mem.writeInt(u32, buf[pos..][0..4], sample_rate, .little);
        pos += 4;

        std.mem.writeInt(u32, buf[pos..][0..4], byte_rate, .little);
        pos += 4;

        std.mem.writeInt(u16, buf[pos..][0..2], block_align, .little);
        pos += 2;

        std.mem.writeInt(u16, buf[pos..][0..2], bits_per_sample, .little);
        pos += 2;

        buf[pos] = 'd';
        pos += 1;
        buf[pos] = 'a';
        pos += 1;
        buf[pos] = 't';
        pos += 1;
        buf[pos] = 'a';
        pos += 1;

        std.mem.writeInt(u32, buf[pos..][0..4], data_size, .little);
        pos += 4;

        var i: usize = 0;
        while (i < sample_count and pos + 2 < buf.len) : (i += 1) {
            const sample = sr.audio_history[i];
            std.mem.writeInt(i16, buf[pos..][0..2], sample, .little);
            pos += 2;

            if (num_channels == 2 and pos + 2 < buf.len) {
                std.mem.writeInt(i16, buf[pos..][0..2], sample, .little);
                pos += 2;
            }
        }

        return pos;
    }

    pub fn getEstimatedFileSize(sr: *const SoundRecorderWindow) u32 {
        const sample_rate = sr.getSampleRate();
        const num_channels: u32 = switch (sr.audio_format) {
            .pcm_22050_mono_16bit, .pcm_44100_mono_16bit => 1,
            .pcm_48000_stereo_16bit => 2,
        };
        const bytes_per_sample: u32 = 2 * num_channels;
        const bytes_per_second = sample_rate * bytes_per_sample;
        return 44 + bytes_per_second * @as(u32, @intCast(sr.recording_time / 60));
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
        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));

        sr.renderTimeDisplay();
        sr.renderWaveform();
        sr.renderControls();
        sr.renderStatusBar();
        sr.renderQualitySelector();
        sr.renderVolumeControls();
    }

    fn renderTimeDisplay(sr: *SoundRecorderWindow) void {
        const cx = sr.x + @divTrunc(sr.width, 2);
        const cy = sr.y + 70;

        const current_time = switch (sr.state) {
            .playing => sr.playback_position,
            .recording => sr.recording_time,
            else => sr.playback_duration,
        };

        const minutes = current_time / 3600;
        const seconds = (current_time / 60) % 60;
        const centisecs = current_time % 60;

        var buf: [32]u8 = undefined;
        const time_str = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ minutes, seconds, centisecs }) catch "";

        fb.fillRect(cx - 80, cy - 20, 160, 40, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(cx - 80, cy - 20, 160, 40, rgb(0xC0, 0xC8, 0xD0), rgb(0xF0, 0xF0, 0xF8));

        fb.drawTextTransparent(cx - 50, cy, time_str, rgb(0x10, 0x10, 0x40));

        if (sr.state == .recording) {
            const blink: u32 = @mod(current_time, 2);
            if (blink == 0) {
                fb.fillRect(cx + 70, cy + 5, 10, 10, rgb(0xCC, 0x00, 0x00));
            }
            fb.drawTextTransparent(cx + 65, cy - 10, "REC", rgb(0xCC, 0x00, 0x00));
        } else if (sr.state == .playing) {
            fb.drawTextTransparent(cx + 60, cy - 10, "PLAY", rgb(0x00, 0x66, 0xCC));
        }
    }

    fn renderWaveform(sr: *SoundRecorderWindow) void {
        const wx = sr.x + 20;
        const wy = sr.y + 120;
        const ww = sr.width - 40;
        const wh: i32 = 100;
        const bar_count: i32 = 64;
        const bar_w: i32 = @divTrunc(ww, bar_count);

        fb.draw3DRect(wx, wy, ww, wh, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(wx + 1, wy + 1, ww - 2, wh - 2, rgb(0xF8, 0xFC, 0xFF));

        const center_y = wy + @divTrunc(wh, 2);
        fb.drawHLine(wx, center_y, ww, rgb(0xC0, 0xC8, 0xD0));

        for (sr.audio_levels, 0..) |level, i| {
            const bx = wx + @as(i32, @intCast(i)) * bar_w;
            const normalized = @as(f32, @floatFromInt(@abs(level))) / 50.0;
            const bar_h = @as(i32, @intCast(normalized * @as(f32, @floatFromInt(wh - 8))));
            const bar_y = center_y - @divTrunc(bar_h, 2);

            const bar_color = switch (sr.state) {
                .recording => rgb(0xCC, 0x00, 0x00),
                .playing => rgb(0x00, 0x66, 0xCC),
                else => rgb(0x00, 0x99, 0x66),
            };

            fb.fillRect(bx + 1, bar_y, bar_w - 2, @max(2, bar_h), bar_color);
        }

        if (sr.state == .playing or sr.state == .paused) {
            const pos_ratio = @as(f32, @floatFromInt(sr.playback_position)) / @as(f32, @max(1, sr.playback_duration));
            const pos_x = wx + @as(i32, @intCast(@as(f32, @floatFromInt(ww)) * pos_ratio));
            fb.drawVLine(pos_x, wy + 1, wh - 2, rgb(0x00, 0x00, 0x80));
        }
    }

    fn renderControls(sr: *SoundRecorderWindow) void {
        const cx = sr.x + @divTrunc(sr.width, 2);
        const cy = sr.y + 240;
        const spacing: i32 = 70;

        const new_x = cx - spacing * 2 - 40;
        sr.renderControlButton(new_x, cy, 60, 36, "New", sr.state == .idle or sr.state == .stopped, sr.hover_new, rgb(0x60, 0x60, 0x60));

        const rec_enabled = sr.state == .idle or sr.state == .stopped or sr.state == .paused;
        sr.renderRecordButton(cx - 40, cy, 50, 50, sr.hover_record, rec_enabled);

        const stop_enabled = sr.state == .recording or sr.state == .playing or sr.state == .paused;
        sr.renderControlButton(cx + spacing - 30, cy, 60, 36, "Stop", stop_enabled, sr.hover_stop, rgb(0x80, 0x80, 0x80));

        const play_enabled = (sr.state == .stopped or sr.state == .paused) and sr.audio_sample_count > 0;
        sr.renderPlayButton(cx + spacing * 2 - 20, cy, 40, 36, sr.hover_play, play_enabled);
    }

    fn renderRecordButton(sr: *SoundRecorderWindow, px: i32, py: i32, pw: i32, ph: i32, hover: bool, enabled: bool) void {
        _ = sr;
        const bg = if (!enabled) rgb(0xE0, 0xE0, 0xE0) else if (hover) rgb(0xF0, 0xF0, 0xF0) else rgb(0xFF, 0xFF, 0xFF);

        fb.fillEllipse(px + @divTrunc(pw, 2), py + @divTrunc(ph, 2), @divTrunc(pw, 2), @divTrunc(ph, 2), bg);
        fb.drawEllipse(px + @divTrunc(pw, 2), py + @divTrunc(ph, 2), @divTrunc(pw, 2), @divTrunc(ph, 2), rgb(0xA0, 0xA8, 0xB8));

        if (enabled) {
            const inner_color = if (hover) rgb(0xFF, 0x00, 0x00) else rgb(0xCC, 0x00, 0x00);
            fb.fillEllipse(px + @divTrunc(pw, 2), py + @divTrunc(ph, 2), pw / 4, ph / 4, inner_color);
        }

        fb.drawTextTransparent(px + 12, py + ph + 4, "Record", if (enabled) rgb(0x40, 0x40, 0x50) else rgb(0xC0, 0xC0, 0xC0));
    }

    fn renderPlayButton(sr: *SoundRecorderWindow, px: i32, py: i32, pw: i32, ph: i32, hover: bool, enabled: bool) void {
        _ = sr;
        const bg = if (!enabled) rgb(0xE0, 0xE0, 0xE0) else if (hover) rgb(0xD0, 0xD8, 0xE8) else rgb(0xE8, 0xEC, 0xF4);

        fb.fillRect(px, py, pw, ph, bg);
        fb.draw3DRect(px, py, pw, ph, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));

        if (enabled) {
            const tx = px + 10;
            const ty = py + 6;
            fb.drawTextTransparent(tx, ty, ">", if (hover) rgb(0x00, 0x40, 0x80) else rgb(0x00, 0x80, 0x00));
        }

        fb.drawTextTransparent(px + 4, py + ph + 4, "Play", if (enabled) rgb(0x40, 0x40, 0x50) else rgb(0xC0, 0xC0, 0xC0));
    }

    fn renderControlButton(sr: *SoundRecorderWindow, px: i32, py: i32, pw: i32, ph: i32, label: []const u8, enabled: bool, hover: bool, accent: u32) void {
        _ = sr;
        const bg = if (!enabled) rgb(0xE0, 0xE0, 0xE0) else if (hover) rgb(0xD0, 0xD8, 0xE8) else rgb(0xE8, 0xEC, 0xF4);

        fb.fillRect(px, py, pw, ph, bg);
        fb.draw3DRect(px, py, pw, ph, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));

        const text_x = px + @divTrunc(pw, 2) - @as(i32, @intCast(label.len)) * 3;
        const text_y = py + @divTrunc(ph, 2) - 6;
        fb.drawTextTransparent(text_x, text_y, label, if (enabled) accent else rgb(0xC0, 0xC0, 0xC0));

        fb.drawTextTransparent(px + @divTrunc(pw, 2) - @as(i32, @intCast(label.len)) * 3, py + ph + 4, label, if (enabled) rgb(0x40, 0x40, 0x50) else rgb(0xC0, 0xC0, 0xC0));
    }

    fn renderQualitySelector(sr: *SoundRecorderWindow) void {
        const qx = sr.x + 20;
        const qy = sr.y + 285;

        fb.drawTextTransparent(qx, qy, "Quality:", rgb(0x40, 0x40, 0x50));

        const qualities = [_][]const u8{ "Low", "Medium", "High" };
        var qx_pos = qx + 60;

        for (qualities, 0..) |q, idx| {
            const is_selected = @as(u8, @intFromEnum(sr.quality)) == idx;
            const bw: i32 = 60;
            const bh: i32 = 18;

            if (is_selected) {
                fb.fillRect(qx_pos, qy - 2, bw, bh, rgb(0xD0, 0xD8, 0xE8));
                fb.draw3DRect(qx_pos, qy - 2, bw, bh, rgb(0x5C, 0x9E, 0xD6), rgb(0x5C, 0x9E, 0xD6));
            } else if (sr.hover_quality == @as(i32, @intCast(idx))) {
                fb.fillRect(qx_pos, qy - 2, bw, bh, rgb(0xE8, 0xEC, 0xF4));
                fb.draw3DRect(qx_pos, qy - 2, bw, bh, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
            } else {
                fb.fillRect(qx_pos, qy - 2, bw, bh, rgb(0xF0, 0xF4, 0xF8));
                fb.draw3DRect(qx_pos, qy - 2, bw, bh, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
            }

            fb.drawTextTransparent(qx_pos + 10, qy, q, if (is_selected) rgb(0x20, 0x40, 0x90) else rgb(0x40, 0x40, 0x50));
            qx_pos += bw + 4;
        }
    }

    fn renderVolumeControls(sr: *SoundRecorderWindow) void {
        const vx = sr.x + sr.width - 180;
        const vy = sr.y + 285;

        fb.drawTextTransparent(vx, vy, "Volume:", rgb(0x40, 0x40, 0x50));

        const bar_x = vx + 55;
        const bar_w: i32 = 80;
        const bar_h: i32 = 12;

        fb.draw3DRect(bar_x, vy - 2, bar_w, bar_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xF0, 0xF0, 0xF8));

        const vol_level = @as(i32, @intCast(@as(f32, @floatFromInt(bar_w - 4)) * sr.playback_volume));
        fb.fillRect(bar_x + 2, vy, vol_level, bar_h - 2, rgb(0x00, 0x80, 0x00));

        var size_buf: [32]u8 = undefined;
        const size_mb = @as(f32, @floatFromInt(sr.getEstimatedFileSize())) / (1024.0 * 1024.0);
        const size_str = std.fmt.bufPrint(&size_buf, "~{d:.1f}MB WAV", .{size_mb}) catch "~0MB";
        fb.drawTextTransparent(vx + 145, vy, size_str, rgb(0x60, 0x60, 0x70));
    }

    fn renderStatusBar(sr: *SoundRecorderWindow) void {
        const sy = sr.y + sr.height - 25;

        fb.fillRect(sr.x, sy, sr.width, 25, rgb(0xF0, 0xF4, 0xF8));
        fb.fillRect(sr.x, sy, sr.width, 1, rgb(0xC0, 0xC8, 0xD8));

        const status_text = switch (sr.state) {
            .idle => "Ready to record",
            .recording => "Recording...",
            .paused => "Paused",
            .playing => "Playing...",
            .stopped => if (sr.has_unsaved_data) "Recording saved" else "Ready to record",
        };

        const status_color = switch (sr.state) {
            .idle => rgb(0x60, 0x60, 0x60),
            .recording => rgb(0xCC, 0x00, 0x00),
            .paused => rgb(0xCC, 0xA0, 0x00),
            .playing => rgb(0x00, 0x80, 0xCC),
            .stopped => rgb(0x40, 0x40, 0x50),
        };

        fb.drawTextTransparent(sr.x + 8, sy + 7, status_text, status_color);

        if (sr.audio_sample_count > 0) {
            var sample_buf: [48]u8 = undefined;
            const sample_str = std.fmt.bufPrint(&sample_buf, "{d} samples @ {d}Hz", .{ sr.audio_sample_count, sr.getSampleRate() }) catch "";
            fb.drawTextTransparent(sr.x + sr.width - 180, sy + 7, sample_str, rgb(0x60, 0x60, 0x70));
        }
    }
};
