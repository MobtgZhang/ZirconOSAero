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
// Module: src/desktop/applications/accessories/magnifier.zig
// Purpose: Screen Magnifier application
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const MagnifierWindow = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    zoom_level: i32,
    follow_mouse: bool,
    track_mouse_x: i32,
    track_mouse_y: i32,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) MagnifierWindow {
        return .{
            .x = x_pos,
            .y = y_pos,
            .width = 400,
            .height = 320,
            .visible = true,
            .caption_hover = .none,
            .zoom_level = 200,
            .follow_mouse = true,
            .track_mouse_x = 0,
            .track_mouse_y = 0,
        };
    }

    pub fn setZoom(m: *MagnifierWindow, level: i32) void {
        m.zoom_level = @max(100, @min(800, level));
    }

    pub fn zoomIn(m: *MagnifierWindow) void {
        m.setZoom(m.zoom_level + 50);
    }

    pub fn zoomOut(m: *MagnifierWindow) void {
        m.setZoom(m.zoom_level - 50);
    }

    pub fn render(m: *MagnifierWindow, t: *const theme_mod.ThemeColors) void {
        if (!m.visible) return;
        _ = t;

        const wx = m.x;
        const wy = m.y;
        const ww = m.width;
        const wh = m.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 10, "Magnifier", rgb(0xFF, 0xFF, 0xFF));
        const close_x = wx + ww - 48;
        if (m.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 34, rgb(0xF8, 0xFC, 0xFF));

        m.renderControls();
        m.renderLens();
        m.renderZoomIndicator();
    }

    fn renderControls(m: *MagnifierWindow) void {
        const cx = m.x + 8;
        var cy = m.y + 40;

        var zoom_buf: [32]u8 = undefined;
        const zoom_text = std.fmt.bufPrint(&zoom_buf, "{d}%", .{m.zoom_level}) catch "";

        fb.drawTextTransparent(cx, cy, "Zoom:", rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(cx + 50, cy, zoom_text, rgb(0x20, 0x40, 0xA0));

        const btn_w: i32 = 30;
        const btn_h: i32 = 20;
        fb.fillRect(cx + 100, cy - 2, btn_w, btn_h, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(cx + 100, cy - 2, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        fb.drawTextTransparent(cx + 110, cy + 2, "-", rgb(0x20, 0x20, 0x30));

        fb.fillRect(cx + 134, cy - 2, btn_w, btn_h, rgb(0xE8, 0xEC, 0xF4));
        fb.draw3DRect(cx + 134, cy - 2, btn_w, btn_h, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        fb.drawTextTransparent(cx + 144, cy + 2, "+", rgb(0x20, 0x20, 0x30));

        cy += 30;
        fb.drawTextTransparent(cx, cy, "Follow mouse:", rgb(0x20, 0x20, 0x30));
        const checkbox_x = cx + 90;
        fb.fillRect(checkbox_x, cy + 2, 14, 14, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(checkbox_x, cy + 2, 14, 14, rgb(0x80, 0x80, 0x88), rgb(0xFF, 0xFF, 0xFF));
        if (m.follow_mouse) {
            fb.drawTextTransparent(checkbox_x + 2, cy, "X", rgb(0x10, 0x40, 0x10));
        }
    }

    fn renderLens(m: *MagnifierWindow) void {
        const lx = m.x + 8;
        const ly = m.y + 90;
        const lw = m.width - 16;
        const lh = m.height - 110;

        fb.draw3DRect(lx, ly, lw, lh, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(lx + 2, ly + 2, lw - 4, lh - 4, rgb(0xE8, 0xF0, 0xF8));

        const cx = lx + lw / 2;
        const cy = ly + lh / 2;
        fb.drawVLine(cx, ly + 2, lh - 4, rgb(0xCC, 0x00, 0x00));
        fb.drawHLine(lx + 2, cy, lw - 4, rgb(0xCC, 0x00, 0x00));
    }

    fn renderZoomIndicator(m: *MagnifierWindow) void {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Zoom: {d}%", .{m.zoom_level}) catch "";
        fb.drawTextTransparent(m.x + m.width - 80, m.y + m.height - 20, text, rgb(0x60, 0x60, 0x80));
    }
};
