// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/on_screen_keyboard.zig
// Purpose: On-Screen Keyboard application
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const OSKWindow = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    current_page: KeyboardPage,
    shift_active: bool,
    ctrl_active: bool,
    alt_active: bool,
    caps_lock: bool,
    text_buffer: [256]u8,
    text_len: usize,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };
    pub const KeyboardPage = enum { main, numpad, symbols };

    pub fn create(x_pos: i32, y_pos: i32) OSKWindow {
        return .{
            .x = x_pos,
            .y = y_pos,
            .width = 680,
            .height = 260,
            .visible = true,
            .caption_hover = .none,
            .current_page = .main,
            .shift_active = false,
            .ctrl_active = false,
            .alt_active = false,
            .caps_lock = false,
            .text_buffer = undefined,
            .text_len = 0,
        };
    }

    pub fn render(osk: *OSKWindow, t: *const theme_mod.ThemeColors) void {
        if (!osk.visible) return;
        _ = t;
        const wx = osk.x;
        const wy = osk.y;
        const ww = osk.width;
        const wh = osk.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 10, "On-Screen Keyboard", rgb(0xFF, 0xFF, 0xFF));
        const close_x = wx + ww - 48;
        if (osk.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 34, rgb(0xF0, 0xF4, 0xF8));
        osk.renderKeyboard();
    }

    fn renderKeyboard(osk: *OSKWindow) void {
        const kx = osk.x + 8;
        var ky = osk.y + 50;
        const row_spacing: i32 = 40;

        osk.renderKeyRow1(kx, ky);
        ky += row_spacing;
        osk.renderKeyRow2(kx, ky);
        ky += row_spacing;
        osk.renderKeyRow3(kx, ky);
        ky += row_spacing;
        osk.renderKeyRow4(kx, ky);
    }

    fn renderKeyRow1(osk: *OSKWindow, x: i32, y: i32) void {
        const keys1 = [_][]const u8{ "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P" };
        const kw: i32 = 36;
        const kh: i32 = 36;
        const spacing: i32 = 4;

        for (keys1, 0..) |key, i| {
            const kx = x + @as(i32, @intCast(i)) * (kw + spacing);
            const label = if (osk.shift_active or osk.caps_lock) key else key;
            osk.renderKey(kx, y, kw, kh, label);
        }
    }

    fn renderKeyRow2(osk: *OSKWindow, x: i32, y: i32) void {
        const keys2 = [_][]const u8{ "A", "S", "D", "F", "G", "H", "J", "K", "L" };
        const kw: i32 = 36;
        const kh: i32 = 36;
        const spacing: i32 = 4;
        const offset: i32 = 20;

        for (keys2, 0..) |key, i| {
            const kx = x + offset + @as(i32, @intCast(i)) * (kw + spacing);
            const label = if (osk.shift_active or osk.caps_lock) key else key;
            osk.renderKey(kx, y, kw, kh, label);
        }
        osk.renderKey(x + offset + 9 * (kw + spacing), y, 60, kh, "Enter");
    }

    fn renderKeyRow3(osk: *OSKWindow, x: i32, y: i32) void {
        const keys3 = [_][]const u8{ "Z", "X", "C", "V", "B", "N", "M" };
        const kw: i32 = 36;
        const kh: i32 = 36;
        const spacing: i32 = 4;

        osk.renderKey(x, y, 50, kh, "Shift");
        for (keys3, 0..) |key, i| {
            const kx = x + 54 + @as(i32, @intCast(i)) * (kw + spacing);
            const label = if (osk.shift_active or osk.caps_lock) key else key;
            osk.renderKey(kx, y, kw, kh, label);
        }
        osk.renderKey(x + 54 + 7 * (kw + spacing), y, 80, kh, "Back");
    }

    fn renderKeyRow4(osk: *OSKWindow, x: i32, y: i32) void {
        osk.renderKey(x, y, 60, 36, "Ctrl");
        osk.renderKey(x + 64, y, 60, 36, "Alt");
        osk.renderKey(x + 128, y, 300, 36, "Space");
        osk.renderKey(x + 432, y, 60, 36, "Alt");
        osk.renderKey(x + 496, y, 60, 36, "Ctrl");
    }

    fn renderKey(osk: *OSKWindow, kx: i32, ky: i32, kw: i32, kh: i32, label: []const u8) void {
        _ = osk;
        fb.fillRect(kx, ky, kw, kh, rgb(0xF8, 0xFC, 0xFF));
        fb.draw3DRect(kx, ky, kw, kh, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
        const text_x = kx + @divTrunc(kw, 2) - @as(i32, @intCast(label.len)) * 4;
        const text_y = ky + @divTrunc(kh, 2) - 6;
        fb.drawTextTransparent(text_x, text_y, label, rgb(0x20, 0x20, 0x30));
    }
};
