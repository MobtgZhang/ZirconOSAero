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
// Module: src/desktop/applications/media_player/visualization.zig
// Purpose: Audio visualization for Media Player
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const VisualizerMode = enum(u8) {
    bars = 0,
    wave = 1,
    circles = 2,
    off = 3,
};

pub const Visualizer = struct {
    mode: VisualizerMode,
    bars: [32]f32,
    wave_data: [128]f32,
    time_offset: u32,
    color_scheme: ColorScheme,

    pub const ColorScheme = enum(u8) {
        blue = 0,
        green = 1,
        purple = 2,
        fire = 3,
        rainbow = 4,
    };

    pub fn create() Visualizer {
        return .{
            .mode = .bars,
            .bars = [_]f32{0} ** 32,
            .wave_data = [_]f32{0} ** 128,
            .time_offset = 0,
            .color_scheme = .blue,
        };
    }

    pub fn tick(v: *Visualizer, is_playing: bool) void {
        v.time_offset +%= 1;
        if (is_playing) {
            v.updateBars();
            v.updateWave();
        } else {
            for (&v.bars) |*b| {
                b.* *= 0.95;
                if (b.* < 0.01) b.* = 0;
            }
            for (&v.wave_data) |*w| {
                w.* *= 0.95;
            }
        }
    }

    fn updateBars(v: *Visualizer) void {
        for (&v.bars, 0..) |*b, i| {
            const target = 0.3 + 0.7 * (@as(f32, @floatFromInt((v.time_offset * @as(u32, @intCast(i + 3))) % 100)) / 100.0);
            const delta = target - b.*;
            b.* += delta * 0.3;
        }
    }

    fn updateWave(v: *Visualizer) void {
        for (&v.wave_data, 0..) |*w, i| {
            const t = @as(f32, @floatFromInt(v.time_offset + @as(u32, @intCast(i)))) * 0.1;
            w.* = 0.5 + 0.5 * @sin(t) * @cos(t * 0.7 + 1.3);
        }
    }

    pub fn setMode(v: *Visualizer, mode: VisualizerMode) void {
        v.mode = mode;
    }

    pub fn nextMode(v: *Visualizer) void {
        v.mode = switch (v.mode) {
            .bars => .wave,
            .wave => .circles,
            .circles => .off,
            .off => .bars,
        };
    }

    pub fn setColorScheme(v: *Visualizer, scheme: ColorScheme) void {
        v.color_scheme = scheme;
    }

    pub fn cycleColorScheme(v: *Visualizer) void {
        v.color_scheme = switch (v.color_scheme) {
            .blue => .green,
            .green => .purple,
            .purple => .fire,
            .fire => .rainbow,
            .rainbow => .blue,
        };
    }

    fn getColor(v: *const Visualizer, intensity: f32, index: usize) u32 {
        const t = @as(f32, @floatFromInt(index)) / 32.0;
        switch (v.color_scheme) {
            .blue => {
                const r = @as(u32, @intCast(20.0 * intensity));
                const g = @as(u32, @intCast(100.0 * intensity));
                const b = @as(u32, @intCast(220.0 * intensity));
                return rgb(r, g, b);
            },
            .green => {
                const r = @as(u32, @intCast(20.0 * intensity * 0.5));
                const g = @as(u32, @intCast(200.0 * intensity));
                const b = @as(u32, @intCast(80.0 * intensity * 0.5));
                return rgb(r, g, b);
            },
            .purple => {
                const r = @as(u32, @intCast(150.0 * intensity * 0.7));
                const g = @as(u32, @intCast(50.0 * intensity * 0.5));
                const b = @as(u32, @intCast(220.0 * intensity));
                return rgb(r, g, b);
            },
            .fire => {
                const r = @as(u32, @intCast(255.0 * intensity));
                const g = @as(u32, @intCast(150.0 * intensity * (1.0 - t)));
                const b = @as(u32, @intCast(30.0 * intensity * (1.0 - t * 0.5)));
                return rgb(r, g, b);
            },
            .rainbow => {
                const hue = t * 6.283;
                const r = @as(u32, @intCast((@sin(hue) * 0.5 + 0.5) * 255.0 * intensity));
                const g = @as(u32, @intCast((@sin(hue + 2.094) * 0.5 + 0.5) * 255.0 * intensity));
                const b = @as(u32, @intCast((@sin(hue + 4.189) * 0.5 + 0.5) * 255.0 * intensity));
                return rgb(r, g, b);
            },
        }
    }

    pub fn render(v: *Visualizer, x: i32, y: i32, w: i32, h: i32) void {
        switch (v.mode) {
            .off => {
                fb.fillRect(x, y, w, h, rgb(0x10, 0x10, 0x18));
                fb.drawTextTransparent(x + @divTrunc(w, 2) - 40, y + @divTrunc(h, 2) - 6, "Visualization Off", rgb(0x60, 0x60, 0x80));
            },
            .bars => v.renderBars(x, y, w, h),
            .wave => v.renderWave(x, y, w, h),
            .circles => v.renderCircles(x, y, w, h),
        }
    }

    fn renderBars(v: *Visualizer, x: i32, y: i32, w: i32, h: i32) void {
        fb.fillRect(x, y, w, h, rgb(0x10, 0x10, 0x18));
        const bar_count: i32 = 32;
        const bar_w = @divTrunc(w, bar_count);
        const spacing: i32 = 1;

        for (v.bars, 0..) |bar, i| {
            const bar_height = @as(i32, @intCast(@as(f32, @floatFromInt(h)) * bar));
            const bx = x + @as(i32, @intCast(i)) * bar_w;
            const by = y + h - bar_height;
            const color = v.getColor(bar, i);
            fb.fillRect(bx + spacing, by, bar_w - spacing, bar_height, color);
        }
    }

    fn renderWave(v: *Visualizer, x: i32, y: i32, w: i32, h: i32) void {
        fb.fillRect(x, y, w, h, rgb(0x10, 0x10, 0x18));
        const mid_y = y + @divTrunc(h, 2);
        const sample_step = @divTrunc(w, 128);

        for (v.wave_data, 0..) |sample, i| {
            const sx = x + @as(i32, @intCast(i)) * sample_step;
            const sy = mid_y + @as(i32, @intCast(sample * @as(f32, @floatFromInt(h * 2))));
            const intensity = @abs(sample);
            const color = v.getColor(intensity, i);
            fb.fillRect(sx, sy, @max(1, sample_step), 2, color);
        }
    }

    fn renderCircles(v: *Visualizer, x: i32, y: i32, w: i32, h: i32) void {
        fb.fillRect(x, y, w, h, rgb(0x10, 0x10, 0x18));
        const cx = x + @divTrunc(w, 2);
        const cy = y + @divTrunc(h, 2);
        const max_r = @min(w, h) / 2 - 4;

        for (v.bars, 0..) |bar, i| {
            const r = @as(i32, @intCast(@as(f32, @floatFromInt(max_r)) * bar));
            const color = v.getColor(bar, i);
            const angle = @as(f32, @floatFromInt(i)) / 32.0 * 6.283;
            const px = cx + @as(i32, @intCast(@cos(angle) * @as(f32, @floatFromInt(r))));
            const py = cy + @as(i32, @intCast(@sin(angle) * @as(f32, @floatFromInt(r))));
            fb.fillRect(px - 2, py - 2, 4, 4, color);
        }
    }
};
