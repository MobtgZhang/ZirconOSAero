// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/char_map.zig
// Purpose: Character Map application
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const CharMapWindow = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    selected_char: u32,
    selected_index: usize,
    font_name: FontChoice,
    char_grid: [256]u32,
    recent_chars: [16]u32,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };
    pub const FontChoice = enum { arial, times, courier, segoe };

    pub fn create(x_pos: i32, y_pos: i32) CharMapWindow {
        var cm: CharMapWindow = .{
            .x = x_pos,
            .y = y_pos,
            .width = 620,
            .height = 520,
            .visible = true,
            .caption_hover = .none,
            .selected_char = 'A',
            .selected_index = 0,
            .font_name = .segoe,
            .char_grid = undefined,
            .recent_chars = [_]u32{0} ** 16,
        };
        for (&cm.char_grid, 0..) |*cell, i| {
            cell.* = 0x20 + @as(u32, @intCast(i));
        }
        return cm;
    }

    pub fn selectChar(cm: *CharMapWindow, index: usize) void {
        if (index < cm.char_grid.len) {
            cm.selected_index = index;
            cm.selected_char = cm.char_grid[index];
            for (cm.recent_chars[1..], 0..) |*r, i| {
                r.* = cm.recent_chars[i + 1];
            }
            cm.recent_chars[0] = cm.selected_char;
        }
    }

    pub fn render(cm: *CharMapWindow, t: *const theme_mod.ThemeColors) void {
        if (!cm.visible) return;
        _ = t;

        const wx = cm.x;
        const wy = cm.y;
        const ww = cm.width;
        const wh = cm.height;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 10, "Character Map", rgb(0xFF, 0xFF, 0xFF));
        const close_x = wx + ww - 48;
        if (cm.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(wx + 1, wy + 33, ww - 2, wh - 34, rgb(0xF8, 0xFC, 0xFF));

        cm.renderFontSelector();
        cm.renderCharGrid();
        cm.renderPreview();
        cm.renderCharacterInfo();
    }

    fn renderFontSelector(cm: *CharMapWindow) void {
        const cx = cm.x + 16;
        var cy = cm.y + 50;

        fb.drawTextTransparent(cx, cy, "Font:", rgb(0x20, 0x20, 0x30));
        const fonts = [_][]const u8{ "Arial", "Times New Roman", "Courier New", "Segoe UI" };
        for (fonts, 0..) |font_name, i| {
            const bx = cx + 50 + @as(i32, @intCast(i)) * 110;
            fb.fillRect(bx, cy, 100, 20, rgb(0xE8, 0xEC, 0xF4));
            fb.draw3DRect(bx, cy, 100, 20, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
            fb.drawTextTransparent(bx + 4, cy + 4, font_name, rgb(0x20, 0x20, 0x30));
        }
        cy += 40;

        fb.drawTextTransparent(cx, cy, "Unicode Block: Basic Latin (0000-00FF)", rgb(0x40, 0x40, 0x60));
    }

    fn renderCharGrid(cm: *CharMapWindow) void {
        const gx = cm.x + 16;
        const gy = cm.y + 120;
        const cell_w: i32 = 30;
        const cell_h: i32 = 30;
        const spacing: i32 = 2;

        for (cm.char_grid, 0..) |char, i| {
            const col = @as(i32, @intCast(i % 16));
            const row = @as(i32, @intCast(i / 16));
            const cx = gx + col * (cell_w + spacing);
            const cy = gy + row * (cell_h + spacing);

            const selected = (i == cm.selected_index);
            const bg = if (selected) rgb(0x3D, 0x7E, 0xCB) else rgb(0xF8, 0xFC, 0xFF);
            fb.fillRect(cx, cy, cell_w, cell_h, bg);
            fb.draw3DRect(cx, cy, cell_w, cell_h,
                if (selected) rgb(0x2A, 0x5C, 0xA8) else rgb(0xC0, 0xC8, 0xD8),
                if (selected) rgb(0x4A, 0x8E, 0xDB) else rgb(0xFF, 0xFF, 0xFF));

            if (char >= 0x20 and char <= 0x7E) {
                const char_str = [_]u8{ @as(u8, @intCast(char)) };
                fb.drawTextTransparent(cx + 8, cy + 8, &char_str, if (selected) rgb(0xFF, 0xFF, 0xFF) else rgb(0x20, 0x20, 0x30));
            } else if (char > 0xFF) {
                var buf: [8]u8 = undefined;
                const hex_str = std.fmt.bufPrint(&buf, "{X}", .{char}) catch "";
                fb.drawTextTransparent(cx + 2, cy + 10, hex_str, if (selected) rgb(0xFF, 0xFF, 0xFF) else rgb(0x60, 0x60, 0x80));
            }
        }
    }

    fn renderPreview(cm: *CharMapWindow) void {
        const px = cm.x + cm.width - 160;
        const py = cm.y + 50;

        fb.drawTextTransparent(px, py, "Preview:", rgb(0x20, 0x20, 0x30));
        fb.draw3DRect(px, py + 20, 130, 80, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        var char_buf: [4]u8 = undefined;
        const char_str = std.unicode.utf32ToUtf8StringLiteral(&char_buf, cm.selected_char);
        fb.drawTextTransparent(px + 40, py + 30, char_str, rgb(0x20, 0x20, 0x40));
    }

    fn renderCharacterInfo(cm: *CharMapWindow) void {
        const ix = cm.x + 16;
        const iy = cm.y + cm.height - 90;

        fb.draw3DRect(ix, iy, cm.width - 32, 80, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(ix + 2, iy + 2, cm.width - 36, 76, rgb(0xF8, 0xFC, 0xFF));

        fb.drawTextTransparent(ix + 10, iy + 10, "Character:", rgb(0x20, 0x20, 0x30));
        var char_buf: [4]u8 = undefined;
        const char_str = std.unicode.utf32ToUtf8StringLiteral(&char_buf, cm.selected_char);
        fb.drawTextTransparent(ix + 80, iy + 10, char_str, rgb(0x10, 0x10, 0x40));

        fb.drawTextTransparent(ix + 10, iy + 30, "Unicode:", rgb(0x20, 0x20, 0x30));
        var buf: [16]u8 = undefined;
        const hex_str = std.fmt.bufPrint(&buf, "U+{X:0>4}", .{cm.selected_char}) catch "";
        fb.drawTextTransparent(ix + 80, iy + 30, hex_str, rgb(0x10, 0x10, 0x40));

        fb.drawTextTransparent(ix + 10, iy + 50, "From: Segoe UI", rgb(0x60, 0x60, 0x60));
    }
};
