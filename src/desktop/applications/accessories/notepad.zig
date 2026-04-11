// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/notepad.zig
// Purpose: Windows 7 style Notepad
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const dwm_mod = @import("../../../drivers/video/core/dwm.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const NotepadApp = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    title: []const u8,
    visible: bool,
    focused: bool,
    text: []u8,
    text_len: usize,
    text_capacity: usize,
    cursor_x: i32,
    cursor_y: i32,
    scroll_x: i32,
    scroll_y: i32,
    line_count: usize,
    modified: bool,
    file_path: []const u8,
    caption_hover: CaptionButtonType,
    show_menu: bool,
    menu_selection: i32,

    const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32, capacity: usize) NotepadApp {
        var capacity_adjusted = capacity;
        if (capacity_adjusted < 4096) capacity_adjusted = 4096;
        var text: [65536]u8 = undefined;
        text[0] = 0;
        return .{
            .x = x_pos, .y = y_pos,
            .width = 640, .height = 480,
            .title = "Untitled - Notepad",
            .visible = true,
            .focused = false,
            .text = text[0..capacity_adjusted],
            .text_len = 0,
            .text_capacity = capacity_adjusted,
            .cursor_x = 0,
            .cursor_y = 0,
            .scroll_x = 0,
            .scroll_y = 0,
            .line_count = 1,
            .modified = false,
            .file_path = "",
            .caption_hover = .none,
            .show_menu = true,
            .menu_selection = -1,
        };
    }

    pub fn setText(n: *NotepadApp, content: []const u8) void {
        const len = @min(content.len, n.text_capacity - 1);
        @memcpy(n.text[0..len], content[0..len]);
        n.text.len = len;
        n.text_len = len;
        n.updateLineCount();
    }

    pub fn appendText(n: *NotepadApp, content: []const u8) void {
        if (n.text_len + content.len >= n.text_capacity) return;
        @memcpy(n.text[n.text_len..][0..content.len], content);
        n.text_len += content.len;
        n.text.len = n.text_len;
        n.updateLineCount();
        n.modified = true;
    }

    pub fn insertChar(n: *NotepadApp, ch: u8) void {
        if (n.text_len >= n.text_capacity - 1) return;
        if (n.cursor_y * 80 + n.cursor_x >= n.text_len) {
            n.text[n.text_len] = ch;
            n.text_len += 1;
            n.text.len = n.text_len;
        }
        n.modified = true;
        n.updateLineCount();
    }

    pub fn deleteChar(n: *NotepadApp) void {
        if (n.text_len > 0) {
            n.text_len -= 1;
            n.text.len = n.text_len;
            n.text[n.text_len] = 0;
        }
        n.modified = true;
        n.updateLineCount();
    }

    fn updateLineCount(n: *NotepadApp) void {
        n.line_count = 1;
        for (n.text[0..n.text_len]) |ch| {
            if (ch == '\n') n.line_count += 1;
        }
    }

    pub fn render(n: *NotepadApp, t: *const theme_mod.ThemeColors) void {
        if (!n.visible) return;
        n.renderWindowFrame(t);
        if (n.show_menu) n.renderMenuBar(t);
        n.renderTextArea(t);
        n.renderStatusBar(t);
    }

    fn renderWindowFrame(n: *NotepadApp, t: *const theme_mod.ThemeColors) void {
        const wx = n.x;
        const wy = n.y;
        const ww = n.width;
        const wh = n.height;
        const ch: i32 = 32;

        if (dwm_mod.isInitialized() and dwm_mod.getConfig().shadow_enabled) {
            fb.fillRect(wx + 4, wy + 4, ww, wh, rgb(0x28, 0x28, 0x30));
        }

        fb.fillRect(wx, wy + ch, ww, wh - ch, rgb(0xFF, 0xFF, 0xFF));

        if (dwm_mod.isGlassEnabled()) {
            dwm_mod.renderGlassEffect(wx, wy, ww, ch, t.titlebar_active_left, .caption);
        } else {
            fb.drawGradientH(wx, wy, ww, ch, t.titlebar_active_left, t.titlebar_active_right);
        }

        n.renderCaptionButtons(t);

        const title_text = if (n.modified) "*" else "";
        const title_x = wx + 8;
        const title_y = wy + 10;
        fb.drawTextTransparent(title_x, title_y, title_text, t.titlebar_text);

        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
    }

    fn renderCaptionButtons(n: *NotepadApp, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const wx = n.x;
        const wy = n.y;
        const ww = n.width;
        const ch: i32 = 32;

        const btn_h = 18;
        const btn_y = wy + @divTrunc(ch - btn_h, 2);
        const btn_w: i32 = 40;
        const btn_w_close: i32 = 48;
        const close_x = wx + ww - btn_w_close;
        const max_x = close_x - btn_w;
        _ = max_x;

        if (n.caption_hover == .close) {
            fb.fillRect(close_x, btn_y, btn_w_close, btn_h, rgb(0xE8, 0x11, 0x23));
        }

        const cx = close_x + @divTrunc(btn_w_close, 2);
        const cy = btn_y + @divTrunc(btn_h, 2);
        var d: i32 = -4;
        while (d <= 4) : (d += 1) {
            fb.putPixel32(@intCast(cx + d), @intCast(cy + d), if (n.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
            fb.putPixel32(@intCast(cx + d), @intCast(cy - d), if (n.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
        }
    }

    fn renderMenuBar(n: *NotepadApp, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const mx = n.x + 4;
        const my = n.y + 32;
        const mw = n.width - 8;
        const mh: i32 = 20;

        fb.fillRect(mx, my, mw, mh, rgb(0xF0, 0xF4, 0xF8));
        fb.drawHLine(mx, my + mh - 1, mw, rgb(0xC0, 0xC8, 0xD8));

        const menus = [_][]const u8{ "File", "Edit", "Format", "View", "Help" };
        var menu_x = mx + 4;
        for (menus) |menu| {
            const is_selected = false;
            if (is_selected) {
                fb.fillRect(menu_x - 2, my + 2, @as(i32, @intCast(menu.len)) * 7 + 8, mh - 4, rgb(0xE8, 0xF0, 0xF8));
            }
            fb.drawTextTransparent(menu_x, my + 4, menu, rgb(0x20, 0x20, 0x30));
            menu_x += @as(i32, @intCast(menu.len)) * 7 + 16;
        }
    }

    fn renderTextArea(n: *NotepadApp, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const tx = n.x + 4;
        const ty = n.y + 56;
        const tw = n.width - 8;
        const th = n.height - 80;

        fb.fillRect(tx, ty, tw, th, rgb(0xFF, 0xFF, 0xFF));

        const line_height: i32 = 14;
        const char_width: i32 = 8;
        var line_start: usize = 0;
        var line_num: i32 = 0;
        var text_y = ty + 2 - n.scroll_y;

        while (line_start < n.text_len and text_y < ty + th) {
            if (text_y >= ty - line_height) {
                var line_end = line_start;
                while (line_end < n.text_len and n.text[line_end] != '\n') line_end += 1;
                const line_text = n.text[line_start..line_end];
                if (line_text.len > 0) {
                    fb.drawTextTransparent(tx + 4 - n.scroll_x, text_y, line_text, rgb(0x10, 0x10, 0x10));
                }
            }
            var line_end = line_start;
            while (line_end < n.text_len and n.text[line_end] != '\n') line_end += 1;
            line_start += if (line_end < n.text_len and n.text[line_end] == '\n') line_end - line_start + 1 else line_end - line_start;
            text_y += line_height;
            line_num += 1;
        }

        if (n.focused) {
            const cursor_pixel_x = tx + 4 + n.cursor_x * char_width - n.scroll_x;
            const cursor_pixel_y = ty + 2 + n.cursor_y * line_height - n.scroll_y;
            if (cursor_pixel_y >= ty and cursor_pixel_y < ty + th) {
                fb.drawVLine(cursor_pixel_x, cursor_pixel_y, line_height, rgb(0x00, 0x00, 0x00));
            }
        }
    }

    fn renderStatusBar(n: *NotepadApp, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const sx = n.x + 4;
        const sy = n.y + n.height - 22;
        const sw = n.width - 8;
        const sh: i32 = 20;

        fb.fillRect(sx, sy, sw, sh, rgb(0xE8, 0xEC, 0xF0));
        fb.drawHLine(sx, sy, sw, rgb(0xFF, 0xFF, 0xFF));
        fb.drawHLine(sx, sy + sh - 1, sw, rgb(0xC0, 0xC8, 0xD8));

        var buf: [32]u8 = undefined;
        const pos_text = std.fmt.bufPrint(&buf, "Ln {d}, Col {d}", .{ n.cursor_y + 1, n.cursor_x + 1 }) catch "";
        fb.drawTextTransparent(sx + 8, sy + 4, pos_text, rgb(0x30, 0x30, 0x40));
    }
};
