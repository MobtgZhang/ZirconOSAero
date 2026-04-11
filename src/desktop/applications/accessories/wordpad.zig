// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/wordpad.zig
// Purpose: WordPad - Rich Text Editor
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const WordPadWindow = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    caption_hover: CaptionButtonType,
    text_content: [8192]u8,
    text_len: usize,
    cursor_x: i32,
    cursor_y: i32,
    scroll_offset: i32,
    toolbar_state: ToolbarState,
    format_bold: bool,
    format_italic: bool,
    format_underline: bool,
    format_font_size: i32,
    format_font_name: FontChoice,
    modified: bool,
    file_name: [256]u8,
    file_name_len: usize,

    pub const CaptionButtonType = enum { none, minimize, maximize, close };
    pub const ToolbarState = struct {
        bold: bool,
        italic: bool,
        underline: bool,
        font_size: i32,
    };

    pub const FontChoice = enum(u8) { arial, times, courier, segoe };

    pub fn create(x_pos: i32, y_pos: i32) WordPadWindow {
        return .{
            .x = x_pos,
            .y = y_pos,
            .width = 800,
            .height = 600,
            .visible = true,
            .caption_hover = .none,
            .text_content = undefined,
            .text_len = 0,
            .cursor_x = 0,
            .cursor_y = 0,
            .scroll_offset = 0,
            .toolbar_state = .{ .bold = false, .italic = false, .underline = false, .font_size = 11 },
            .format_bold = false,
            .format_italic = false,
            .format_underline = false,
            .format_font_size = 11,
            .format_font_name = .segoe,
            .modified = false,
            .file_name = undefined,
            .file_name_len = 0,
        };
    }

    pub fn insertText(wp: *WordPadWindow, text: []const u8) void {
        if (wp.text_len + text.len < wp.text_content.len) {
            @memcpy(wp.text_content[wp.text_len..][0..text.len], text);
            wp.text_len += text.len;
            wp.modified = true;
        }
    }

    pub fn backspace(wp: *WordPadWindow) void {
        if (wp.text_len > 0) {
            wp.text_len -= 1;
            wp.modified = true;
        }
    }

    pub fn render(wp: *WordPadWindow, t: *const theme_mod.ThemeColors) void {
        if (!wp.visible) return;
        _ = t;

        const wx = wp.x;
        const wy = wp.y;
        const ww = wp.width;

        fb.drawGradientH(wx, wy, ww, 32, rgb(0x1A, 0x5C, 0xB8), rgb(0x3D, 0x7E, 0xCB));
        fb.drawTextTransparent(wx + 8, wy + 10, "WordPad", rgb(0xFF, 0xFF, 0xFF));
        const close_x = wx + ww - 48;
        if (wp.caption_hover == .close) {
            fb.fillRect(close_x, wy + 6, 48, 20, rgb(0xE8, 0x11, 0x23));
        }
        fb.drawTextTransparent(close_x + 16, wy + 10, "X", rgb(0xFF, 0xFF, 0xFF));

        wp.renderMenuBar();
        wp.renderToolbar();
        wp.renderTextArea();
        wp.renderStatusBar();
    }

    fn renderMenuBar(wp: *WordPadWindow) void {
        const my = wp.y + 32;
        const mh: i32 = 24;
        const menus = [_][]const u8{ "File", "Edit", "View", "Insert", "Format", "Help" };

        fb.fillRect(wp.x, my, wp.width, mh, rgb(0xF0, 0xF4, 0xF8));
        var mx = wp.x + 4;
        for (menus) |menu| {
            fb.drawTextTransparent(mx, my + 6, menu, rgb(0x20, 0x20, 0x30));
            mx += 60;
        }
        fb.fillRect(wp.x, my + mh, wp.width, 1, rgb(0xC0, 0xC8, 0xD8));
    }

    fn renderToolbar(wp: *WordPadWindow) void {
        const ty = wp.y + 57;
        const th: i32 = 36;
        const buttons = [_]ToolbarButton{
            .{ .label = "New", .icon = "N" },
            .{ .label = "Open", .icon = "O" },
            .{ .label = "Save", .icon = "S" },
            .{ .separator = true, .label = "", .icon = "" },
            .{ .label = "Cut", .icon = "X" },
            .{ .label = "Copy", .icon = "C" },
            .{ .label = "Paste", .icon = "V" },
            .{ .separator = true, .label = "", .icon = "" },
            .{ .label = "B", .icon = "B", .bold = true },
            .{ .label = "I", .icon = "I", .italic = true },
            .{ .label = "U", .icon = "U", .underline = true },
            .{ .separator = true, .label = "", .icon = "" },
            .{ .label = "Left", .icon = "L" },
            .{ .label = "Center", .icon = "C" },
            .{ .label = "Right", .icon = "R" },
        };

        fb.fillRect(wp.x, ty, wp.width, th, rgb(0xF8, 0xFC, 0xFF));
        var bx = wp.x + 4;
        for (buttons) |btn| {
            if (btn.separator) {
                fb.fillRect(bx + 2, ty + 6, 1, th - 12, rgb(0xC0, 0xC8, 0xD8));
                bx += 8;
            } else {
                const bw: i32 = 32;
                const bh: i32 = 28;
                const by = ty + 4;
                fb.fillRect(bx, by, bw, bh, rgb(0xE8, 0xEC, 0xF4));
                fb.draw3DRect(bx, by, bw, bh, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));
                const text_color = if (btn.bold) rgb(0x00, 0x00, 0x00) else if (btn.italic) rgb(0x20, 0x20, 0x80) else rgb(0x40, 0x40, 0x50);
                fb.drawTextTransparent(bx + 10, by + 8, btn.icon, text_color);
                bx += bw + 4;
            }
        }
        fb.fillRect(wp.x, ty + th, wp.width, 1, rgb(0xC0, 0xC8, 0xD8));
    }

    fn renderTextArea(wp: *WordPadWindow) void {
        const tx = wp.x + 8;
        const ty = wp.y + 94;
        const tw = wp.width - 16;
        const th = wp.height - 140;

        fb.draw3DRect(tx, ty, tw, th, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));
        fb.fillRect(tx + 2, ty + 2, tw - 4, th - 4, rgb(0xFF, 0xFF, 0xFF));

        const text_y = ty + 20 - wp.scroll_offset;
        var line_y = text_y;
        var char_x = tx + 20;

        for (wp.text_content[0..wp.text_len]) |byte| {
            if (byte == '\n' or char_x > tx + tw - 40) {
                line_y += 18;
                char_x = tx + 20;
            } else {
                const char_str = [_]u8{byte};
                const _bold = wp.format_bold;
                const _italic = wp.format_italic;
                const _underline = wp.format_underline;
                _ = _bold; _ = _italic; _ = _underline;
                fb.drawTextTransparent(char_x, line_y, &char_str, rgb(0x20, 0x20, 0x40));
                char_x += 8;
            }
        }

        const cursor_blink: bool = true;
        if (cursor_blink) {
            fb.fillRect(tx + 20 + wp.cursor_x * 8, ty + 20 + wp.cursor_y * 18, 1, 16, rgb(0x20, 0x20, 0x40));
        }
    }

    fn renderStatusBar(wp: *WordPadWindow) void {
        const sy = wp.y + wp.height - 26;
        const sh: i32 = 26;

        fb.fillRect(wp.x, sy, wp.width, sh, rgb(0xF0, 0xF4, 0xF8));
        fb.fillRect(wp.x, sy, wp.width, 1, rgb(0xC0, 0xC8, 0xD8));

        var buf: [64]u8 = undefined;
        const page_str = std.fmt.bufPrint(&buf, "Page 1, Line {d}, Col {d}", .{ wp.cursor_y + 1, wp.cursor_x + 1 }) catch "";
        fb.drawTextTransparent(wp.x + 8, sy + 7, page_str, rgb(0x40, 0x40, 0x50));

        const modified_str = if (wp.modified) "Modified" else "Ready";
        fb.drawTextTransparent(wp.x + wp.width - 70, sy + 7, modified_str, rgb(0x40, 0x40, 0x50));

        var size_buf: [16]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d} words", .{wp.text_len / 5}) catch "";
        fb.drawTextTransparent(wp.x + wp.width / 2 - 30, sy + 7, size_str, rgb(0x60, 0x60, 0x70));
    }

    const ToolbarButton = struct {
        separator: bool = false,
        label: []const u8 = "",
        icon: []const u8 = "",
        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
    };
};
