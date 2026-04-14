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
// Module: src/desktop/applications/accessories/notepad.zig
// Purpose: Windows 7 style Notepad with VFS file I/O
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const dwm_mod = @import("../../../drivers/video/core/dwm.zig");
const vfs = @import("../../../fs/vfs.zig");
const klog = @import("../../../rtl/klog.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

/// Notepad file dialog result
pub const FileDialogResult = struct {
    success: bool,
    path: []const u8,
};

/// Notepad error types
pub const NotepadError = enum {
    success,
    file_not_found,
    access_denied,
    io_error,
    invalid_path,
    out_of_memory,
};

/// Notepad App with VFS file I/O support
pub const NotepadApp = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    title: []const u8,
    visible: bool,
    focused: bool,

    // Text buffer (fixed size for VFS operations)
    text: [65536]u8,
    text_len: usize,

    cursor_x: i32,
    cursor_y: i32,
    scroll_x: i32,
    scroll_y: i32,
    line_count: usize,
    modified: bool,

    // File operations
    file_path: [vfs.MAX_PATH]u8,
    file_path_len: usize,
    file_handle: ?*vfs.FileObject,
    last_error: NotepadError,

    caption_hover: CaptionButtonType,
    show_menu: bool,
    menu_selection: i32,

    const CaptionButtonType = enum { none, minimize, maximize, close };

    /// Create a new Notepad instance
    pub fn create(x_pos: i32, y_pos: i32) NotepadApp {
        return .{
            .x = x_pos, .y = y_pos,
            .width = 640, .height = 480,
            .title = "Untitled - Notepad",
            .visible = true,
            .focused = false,
            .text = [_]u8{0} ** 65536,
            .text_len = 0,
            .cursor_x = 0,
            .cursor_y = 0,
            .scroll_x = 0,
            .scroll_y = 0,
            .line_count = 1,
            .modified = false,
            .file_path = [_]u8{0} ** vfs.MAX_PATH,
            .file_path_len = 0,
            .file_handle = null,
            .last_error = .success,
            .caption_hover = .none,
            .show_menu = true,
            .menu_selection = -1,
        };
    }

    /// Get the file path as a string slice
    pub fn getFilePath(n: *NotepadApp) []const u8 {
        return n.file_path[0..n.file_path_len];
    }

    /// Set file path from a string
    pub fn setFilePath(n: *NotepadApp, path: []const u8) void {
        n.file_path_len = @min(path.len, vfs.MAX_PATH - 1);
        @memcpy(n.file_path[0..n.file_path_len], path[0..n.file_path_len]);
        n.file_path[n.file_path_len] = 0;
    }

    /// Get window title with file name
    pub fn getWindowTitle(n: *NotepadApp) []const u8 {
        var title_buf: [128]u8 = undefined;
        const prefix: []const u8 = if (n.modified) "*" else "";

        if (n.file_path_len > 0) {
            // Extract filename from path
            var name_start: usize = n.file_path_len;
            while (name_start > 0) {
                if (n.file_path[name_start - 1] == '\\' or n.file_path[name_start - 1] == '/') {
                    name_start += 1;
                    break;
                }
                name_start -= 1;
            }
            const filename = n.file_path[name_start..n.file_path_len];
            const len = std.fmt.bufPrint(&title_buf, "{s}{s} - Notepad", .{ prefix, filename }) catch "Untitled - Notepad";
            return len;
        }
        return "Untitled - Notepad";
    }

    /// Open file from VFS path
    /// Returns: NotepadError.success on success
    pub fn openFile(n: *NotepadApp, path: []const u8) NotepadError {
        // Close existing file if open
        if (n.file_handle) |_| {
            n.closeFile();
        }

        // Find or allocate a file slot
        var file_idx: usize = 0;
        var found = false;
        for (0..vfs.MAX_OPEN_FILES) |i| {
            if (!vfs.files[i].is_open) {
                file_idx = i;
                found = true;
                break;
            }
        }
        if (!found) {
            n.last_error = .io_error;
            return .io_error;
        }

        // Open the file
        const status = vfs.open(&vfs.files[file_idx], path, .read);
        if (status != .success) {
            n.last_error = switch (status) {
                .not_found => .file_not_found,
                .access_denied => .access_denied,
                else => .io_error,
            };
            return n.last_error;
        }

        n.file_handle = &vfs.files[file_idx];
        n.setFilePath(path);

        // Read file contents
        const result = vfs.read(n.file_handle.?, &n.text);
        if (result.status != .success) {
            n.closeFile();
            n.last_error = .io_error;
            return .io_error;
        }

        n.text_len = result.bytes_read;
        n.text[n.text_len] = 0; // Null terminate
        n.modified = false;
        n.updateLineCount();
        n.last_error = .success;

        klog.info("notepad: opened file '{s}' ({d} bytes)", .{ path, result.bytes_read });
        return .success;
    }

    /// Save file to VFS path
    /// Returns: NotepadError.success on success
    pub fn saveFile(n: *NotepadApp, path: []const u8) NotepadError {
        // Close existing file if open
        if (n.file_handle) |_| {
            n.closeFile();
        }

        // Find or allocate a file slot
        var file_idx: usize = 0;
        var found = false;
        for (0..vfs.MAX_OPEN_FILES) |i| {
            if (!vfs.files[i].is_open) {
                file_idx = i;
                found = true;
                break;
            }
        }
        if (!found) {
            n.last_error = .io_error;
            return .io_error;
        }

        // Create/open the file for writing
        const status = vfs.open(&vfs.files[file_idx], path, .write);
        if (status != .success and status != .success) {
            n.last_error = switch (status) {
                .not_found => .invalid_path,
                .access_denied => .access_denied,
                else => .io_error,
            };
            return n.last_error;
        }

        n.file_handle = &vfs.files[file_idx];
        n.setFilePath(path);

        // Write file contents
        const text_slice = n.text[0..n.text_len];
        const result = vfs.write(n.file_handle.?, text_slice);
        if (result.status != .success) {
            n.closeFile();
            n.last_error = .io_error;
            return .io_error;
        }

        n.modified = false;
        n.last_error = .success;

        klog.info("notepad: saved file '{s}' ({d} bytes)", .{ path, result.bytes_written });
        return .success;
    }

    /// Save to current file (if path is set)
    /// Returns: NotepadError.success on success
    pub fn saveCurrentFile(n: *NotepadApp) NotepadError {
        if (n.file_path_len == 0) {
            return .invalid_path;
        }
        return n.saveFile(n.getFilePath());
    }

    /// Close the current file
    pub fn closeFile(n: *NotepadApp) void {
        if (n.file_handle) |handle| {
            vfs.close(handle);
            n.file_handle = null;
        }
    }

    /// Get last error as string
    pub fn getErrorString(n: *NotepadApp) []const u8 {
        return switch (n.last_error) {
            .success => "Success",
            .file_not_found => "File not found",
            .access_denied => "Access denied",
            .io_error => "I/O error",
            .invalid_path => "Invalid path",
            .out_of_memory => "Out of memory",
        };
    }

    /// Set text content
    pub fn setText(n: *NotepadApp, content: []const u8) void {
        const len = @min(content.len, n.text.len - 1);
        @memcpy(n.text[0..len], content[0..len]);
        n.text_len = len;
        n.text[len] = 0;
        n.updateLineCount();
    }

    /// Append text at current position
    pub fn appendText(n: *NotepadApp, content: []const u8) void {
        if (n.text_len + content.len >= n.text.len) return;
        @memcpy(n.text[n.text_len..][0..content.len], content);
        n.text_len += content.len;
        n.text[n.text_len] = 0;
        n.updateLineCount();
        n.modified = true;
    }

    /// Insert a single character at current position
    pub fn insertChar(n: *NotepadApp, ch: u8) void {
        if (n.text_len >= n.text.len - 1) return;
        // Shift existing content
        var i = n.text_len;
        while (i > 0) : (i -= 1) {
            n.text[i] = n.text[i - 1];
        }
        n.text[0] = ch;
        n.text_len += 1;
        n.text[n.text_len] = 0;
        n.modified = true;
        n.updateLineCount();
    }

    /// Delete the last character
    pub fn deleteChar(n: *NotepadApp) void {
        if (n.text_len > 0) {
            n.text_len -= 1;
            n.text[n.text_len] = 0;
            n.modified = true;
            n.updateLineCount();
        }
    }

    fn updateLineCount(n: *NotepadApp) void {
        n.line_count = 1;
        for (n.text[0..n.text_len]) |ch| {
            if (ch == '\n') n.line_count += 1;
        }
    }

    /// Render the Notepad window
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

        // Draw title with modified indicator
        const prefix: []const u8 = if (n.modified) "* " else "";
        const title = n.getWindowTitle();
        fb.drawTextTransparent(wx + 8, wy + 10, prefix, t.titlebar_text);
        fb.drawTextTransparent(wx + 8 + @as(i32, @intCast(prefix.len * 8)), wy + 10, title, t.titlebar_text);

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

        var buf: [64]u8 = undefined;
        const pos_text = std.fmt.bufPrint(&buf, "Ln {d}, Col {d} | {d} bytes", .{ n.cursor_y + 1, n.cursor_x + 1, n.text_len }) catch "";
        fb.drawTextTransparent(sx + 8, sy + 4, pos_text, rgb(0x30, 0x30, 0x40));
    }
};
