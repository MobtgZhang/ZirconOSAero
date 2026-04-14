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
// Module: src/desktop/applications/accessories/cmd_shell.zig
// Purpose: Windows 7 style Command Prompt
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const CmdShell = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    focused: bool,
    lines: [100]CmdLine,
    line_count: usize,
    input_buffer: [256]u8,
    input_len: usize,
    cursor_x: i32,
    cursor_blink: bool,
    cursor_timer: u32,
    scroll_offset: i32,
    max_lines: usize,
    caption_hover: CaptionButtonType,

    const CaptionButtonType = enum { none, minimize, maximize, close };

    pub const CmdLine = struct {
        prompt: []const u8,
        command: []const u8,
        output: []const u8,
    };

    pub fn create(x_pos: i32, y_pos: i32) CmdShell {
        var shell = CmdShell{
            .x = x_pos, .y = y_pos,
            .width = 700, .height = 450,
            .visible = true,
            .focused = false,
            .lines = undefined,
            .line_count = 0,
            .input_buffer = undefined,
            .input_len = 0,
            .cursor_x = 0,
            .cursor_blink = true,
            .cursor_timer = 0,
            .scroll_offset = 0,
            .max_lines = 100,
            .caption_hover = .none,
        };
        shell.addWelcomeLine();
        return shell;
    }

    fn addWelcomeLine(shell: *CmdShell) void {
        if (shell.line_count < shell.lines.len) {
            shell.lines[shell.line_count] = .{
                .prompt = "ZirconOSAero",
                .command = "",
                .output = "NT 6.1 Command Prompt\r\nType 'help' for available commands.",
            };
            shell.line_count += 1;
        }
    }

    pub fn executeCommand(shell: *CmdShell, cmd: []const u8) void {
        if (shell.line_count >= shell.lines.len) {
            @memcpy(&shell.lines, &shell.lines[1]);
            shell.line_count -= 1;
        }

        var output: []const u8 = "";
        if (cmd.len > 0) {
            output = shell.processCommand(cmd);
        }

        shell.lines[shell.line_count] = .{
            .prompt = "C:\\>",
            .command = cmd,
            .output = output,
        };
        shell.line_count += 1;
    }

    fn processCommand(shell: *CmdShell, cmd: []const u8) []const u8 {
        if (cmd.len >= 4 and std.mem.startsWith(u8, cmd[0..4], "help")) {
            return "Available commands:\r\n  help    - Show this help\r\n  cls     - Clear screen\r\n  dir     - List directory\r\n  cd      - Change directory\r\n  echo    - Display text\r\n  ver     - Show version\r\n  date    - Show date\r\n  time    - Show time";
        }
        if (cmd.len >= 3 and std.mem.startsWith(u8, cmd[0..3], "cls")) {
            shell.line_count = 0;
            return "";
        }
        if (cmd.len >= 3 and std.mem.startsWith(u8, cmd[0..3], "dir")) {
            return " Volume in drive C is ZirconOS\r\n Directory of C:\\\r\n\r\n06/11/2026  12:00 AM    <DIR>          Program Files\r\n06/11/2026  12:00 AM    <DIR>          Windows\r\n               0 File(s)              0 bytes\r\n               2 Dir(s)   21,900,000,000 bytes free";
        }
        if (cmd.len >= 3 and std.mem.startsWith(u8, cmd[0..3], "ver")) {
            return "ZirconOSAero NT 6.1 [Version 1.0.0.0]";
        }
        if (cmd.len >= 4 and std.mem.startsWith(u8, cmd[0..4], "date")) {
            return "Current date: 04/11/2026";
        }
        if (cmd.len >= 4 and std.mem.startsWith(u8, cmd[0..4], "time")) {
            return "Current time: 12:00:00.00";
        }
        if (cmd.len >= 4 and std.mem.startsWith(u8, cmd[0..4], "echo")) {
            const text_start = if (cmd.len > 5) cmd[5..] else "";
            return text_start;
        }
        return "'" ++ cmd ++ "' is not recognized as an internal or external command.";
    }

    pub fn appendChar(shell: *CmdShell, ch: u8) void {
        if (shell.input_len < shell.input_buffer.len - 1) {
            shell.input_buffer[shell.input_len] = ch;
            shell.input_len += 1;
            shell.cursor_x += 1;
        }
    }

    pub fn backspace(shell: *CmdShell) void {
        if (shell.input_len > 0) {
            shell.input_len -= 1;
            shell.input_buffer[shell.input_len] = 0;
            shell.cursor_x -= 1;
        }
    }

    pub fn clearInput(shell: *CmdShell) void {
        shell.input_len = 0;
        shell.cursor_x = 0;
        @memset(&shell.input_buffer, 0);
    }

    pub fn updateCursor(shell: *CmdShell) void {
        shell.cursor_timer += 1;
        if (shell.cursor_timer >= 30) {
            shell.cursor_timer = 0;
            shell.cursor_blink = !shell.cursor_blink;
        }
    }

    pub fn render(shell: *CmdShell, t: *const theme_mod.ThemeColors) void {
        if (!shell.visible) return;
        shell.renderWindowFrame(t);
        shell.renderContent(t);
    }

    fn renderWindowFrame(shell: *CmdShell, t: *const theme_mod.ThemeColors) void {
        const wx = shell.x;
        const wy = shell.y;
        const ww = shell.width;
        const wh = shell.height;
        const ch: i32 = 32;

        fb.fillRect(wx, wy + ch, ww, wh - ch, rgb(0x00, 0x30, 0x00));
        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));

        const title = "Command Prompt";
        fb.drawTextTransparent(wx + 8, wy + 10, title, t.titlebar_text);

        const btn_h = 18;
        const btn_y = wy + @divTrunc(ch - btn_h, 2);
        const btn_w_close: i32 = 48;
        const close_x = wx + ww - btn_w_close;

        if (shell.caption_hover == .close) {
            fb.fillRect(close_x, btn_y, btn_w_close, btn_h, rgb(0xE8, 0x11, 0x23));
        }

        const cx = close_x + @divTrunc(btn_w_close, 2);
        const cy = btn_y + @divTrunc(btn_h, 2);
        var d: i32 = -4;
        while (d <= 4) : (d += 1) {
            fb.putPixel32(@intCast(cx + d), @intCast(cy + d), if (shell.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
            fb.putPixel32(@intCast(cx + d), @intCast(cy - d), if (shell.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
        }
    }

    fn renderContent(shell: *CmdShell, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const line_height: i32 = 16;
        const start_y = shell.y + 36;

        var display_count: usize = @intCast(@as(i32, @intCast(shell.line_count)) - shell.scroll_offset);
        if (display_count > @as(usize, @intCast((shell.height - 60) / line_height))) {
            display_count = @as(usize, @intCast((shell.height - 60) / line_height));
        }

        var y_offset: i32 = start_y;
        var line_idx: usize = if (shell.scroll_offset > 0) shell.scroll_offset else 0;

        while (line_idx < shell.line_count and y_offset < shell.y + shell.height - 30) {
            const cmdline = shell.lines[line_idx];

            if (cmdline.prompt.len > 0) {
                fb.drawTextTransparent(shell.x + 8, y_offset, cmdline.prompt, rgb(0x00, 0xFF, 0x00));
            }

            if (cmdline.command.len > 0) {
                fb.drawTextTransparent(shell.x + 60, y_offset, cmdline.command, rgb(0xFF, 0xFF, 0xFF));
            }

            y_offset += line_height;

            if (cmdline.output.len > 0) {
                const output_lines: usize = @divTrunc(@as(i32, @intCast(cmdline.output.len)), 70) + 1;
                var out_idx: usize = 0;
                var line_num: usize = 0;
                while (out_idx < cmdline.output.len and line_num < output_lines and y_offset < shell.y + shell.height - 30) {
                    var line_end = out_idx;
                    var chars_on_line: usize = 0;
                    while (line_end < cmdline.output.len and chars_on_line < 70) {
                        if (cmdline.output[line_end] == '\n' or cmdline.output[line_end] == '\r') {
                            line_end += 1;
                            if (line_end < cmdline.output.len and cmdline.output[line_end] == '\n') {
                                line_end += 1;
                            }
                            break;
                        }
                        line_end += 1;
                        chars_on_line += 1;
                    }
                    fb.drawTextTransparent(shell.x + 8, y_offset, cmdline.output[out_idx..line_end], rgb(0xFF, 0xFF, 0xFF));
                    y_offset += line_height;
                    out_idx = line_end;
                    line_num += 1;
                }
            }

            line_idx += 1;
        }

        const prompt_x = shell.x + 8;
        const prompt_y = shell.y + shell.height - 24;
        fb.drawTextTransparent(prompt_x, prompt_y, "C:\\>", rgb(0x00, 0xFF, 0x00));

        const input_x = prompt_x + 30;
        if (shell.input_len > 0) {
            fb.drawTextTransparent(input_x, prompt_y, shell.input_buffer[0..shell.input_len], rgb(0xFF, 0xFF, 0xFF));
        }

        if (shell.focused and shell.cursor_blink) {
            const cursor_screen_x = input_x + shell.cursor_x * 8;
            fb.drawVLine(cursor_screen_x, prompt_y, 14, rgb(0x00, 0xFF, 0x00));
        }
    }
};
