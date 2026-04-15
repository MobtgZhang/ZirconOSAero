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
// Purpose: Windows 7 style Command Prompt with real filesystem support
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const vfs = @import("../../../fs/vfs.zig");
const explorer_vol_snap = @import("../../../fs/explorer_volume_snapshot.zig");

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
    // Filesystem state
    current_drive: u8,
    current_path: [256]u8,
    current_path_len: usize,

    const CaptionButtonType = enum { none, minimize, maximize, close };

    pub const CmdLine = struct {
        prompt: []const u8,
        command: []const u8,
        output: []const u8,
    };

    pub fn create(x_pos: i32, y_pos: i32) CmdShell {
        var shell = CmdShell{
            .x = x_pos,
            .y = y_pos,
            .width = 700,
            .height = 450,
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
            .current_drive = 'C',
            .current_path = undefined,
            .current_path_len = 0,
        };
        // Initialize current path to Users directory
        const default_path = "\\Users\\User";
        @memcpy(shell.current_path[0..default_path.len], default_path);
        shell.current_path_len = default_path.len;
        shell.addWelcomeLine();
        return shell;
    }

    pub fn getPrompt(shell: *const CmdShell) []const u8 {
        var prompt_buf: [272]u8 = undefined;
        var pos: usize = 0;

        // Drive letter
        prompt_buf[pos] = shell.current_drive;
        pos += 1;
        prompt_buf[pos] = ':';
        pos += 1;

        // Current path
        if (shell.current_path_len > 0) {
            @memcpy(prompt_buf[pos..][0..shell.current_path_len], shell.current_path[0..shell.current_path_len]);
            pos += shell.current_path_len;
        }

        prompt_buf[pos] = '>';
        pos += 1;

        return prompt_buf[0..pos];
    }

    fn addWelcomeLine(shell: *CmdShell) void {
        if (shell.line_count < shell.lines.len) {
            shell.lines[shell.line_count] = .{
                .prompt = "",
                .command = "",
                .output = "ZirconOS [Version 6.1.7601]\r\nCopyright (c) 2009 Microsoft Corporation. All rights reserved.\r\n\r\n",
            };
            shell.line_count += 1;
        }
    }

    pub fn executeCommand(shell: *CmdShell, cmd: []const u8) void {
        if (shell.line_count >= shell.lines.len) {
            // Shift all lines up by one
            var i: usize = 0;
            while (i < shell.lines.len - 1) : (i += 1) {
                shell.lines[i] = shell.lines[i + 1];
            }
            shell.line_count -= 1;
        }

        var output_buf: [4096]u8 = undefined;
        var output_len: usize = 0;

        if (cmd.len > 0) {
            output_len = shell.processCommandEx(cmd, &output_buf);
        }

        const prompt = shell.getPrompt();
        shell.lines[shell.line_count] = .{
            .prompt = prompt,
            .command = cmd,
            .output = output_buf[0..output_len],
        };
        shell.line_count += 1;
    }

    fn processCommandEx(shell: *CmdShell, cmd: []const u8, out_buf: []u8) usize {
        // Parse command and arguments
        var cmd_buf: [256]u8 = undefined;
        var arg_buf: [256]u8 = undefined;
        var cmd_len: usize = 0;
        var arg_len: usize = 0;

        // Find command end (first space)
        var i: usize = 0;
        while (i < cmd.len and cmd[i] == ' ') i += 1;
        while (i < cmd.len and cmd[i] != ' ' and cmd_len < cmd_buf.len) {
            cmd_buf[cmd_len] = cmd[i];
            cmd_len += 1;
            i += 1;
        }
        while (i < cmd.len and cmd[i] == ' ') i += 1;
        while (i < cmd.len and arg_len < arg_buf.len) {
            arg_buf[arg_len] = cmd[i];
            arg_len += 1;
            i += 1;
        }

        const cmd_str = cmd_buf[0..cmd_len];
        const arg_str = arg_buf[0..arg_len];

        // Command handlers
        if (std.ascii.eqlIgnoreCase(cmd_str, "help")) {
            return formatOutputStatic(out_buf, "Available commands:\r\n\r\n" ++
                "  help     - Display this help message\r\n" ++
                "  cls      - Clear the screen\r\n" ++
                "  dir      - Display a list of files and subdirectories\r\n" ++
                "  cd       - Display the name of or change the current directory\r\n" ++
                "  cd ..    - Go to parent directory\r\n" ++
                "  cd \\     - Go to root directory\r\n" ++
                "  mkdir    - Creates a directory (not implemented)\r\n" ++
                "  type     - Displays the contents of a text file\r\n" ++
                "  echo     - Displays text or toggles command echoing\r\n" ++
                "  ver      - Display the version number\r\n" ++
                "  date     - Display or set the date\r\n" ++
                "  time     - Display or set the time\r\n" ++
                "  vol      - Display disk volume label and serial number\r\n" ++
                "  color    - Set the default console color\r\n" ++
                "  prompt   - Change the command prompt\r\n" ++
                "  path     - Display or set a search path\r\n" ++
                "  set      - Display, set, or remove environment variables\r\n");
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "cls")) {
            shell.line_count = 0;
            return 0;
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "dir")) {
            return shell.processDirCommand(arg_str, out_buf);
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "cd") or std.ascii.eqlIgnoreCase(cmd_str, "chdir")) {
            return shell.processCdCommand(arg_str, out_buf);
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "mkdir") or std.ascii.eqlIgnoreCase(cmd_str, "md")) {
            return formatOutputStatic(out_buf, "'mkdir' is not implemented in InitFS.\r\n");
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "type")) {
            return shell.processTypeCommand(arg_str, out_buf);
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "ver")) {
            return formatOutputStatic(out_buf, "ZirconOSAero NT 6.1 [Version 1.0.0.0]\r\n");
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "date")) {
            return formatOutputStatic(out_buf, "Current date: 04/15/2026\r\n");
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "time")) {
            return formatOutputStatic(out_buf, "Current time: 12:00:00.00\r\n");
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "vol")) {
            return shell.processVolCommand(out_buf);
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "echo")) {
            if (arg_len == 0) {
                return formatOutputStatic(out_buf, "ECHO is on.\r\n");
            }
            if (std.ascii.eqlIgnoreCase(arg_buf[0..arg_len], "off")) {
                return formatOutputStatic(out_buf, "ECHO is off.\r\n");
            }
            return formatOutput(out_buf, "{s}\r\n", .{arg_str});
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "prompt")) {
            if (arg_len == 0) {
                return formatOutputStatic(out_buf, "PROMPT {text}\r\n");
            }
                return formatOutput(out_buf, "Prompt changed to: {s}\r\n", .{arg_str});
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "path")) {
            if (arg_len == 0) {
                return formatOutputStatic(out_buf, "PATH=C:\\Windows\\System32;C:\\Windows\r\n");
            }
            return formatOutput(out_buf, "PATH={s}\r\n", .{arg_str});
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "set")) {
            if (arg_len == 0) {
                return formatOutputStatic(out_buf, "TEMP=C:\\Windows\\Temp\r\n" ++
                    "TMP=C:\\Windows\\Temp\r\n" ++
                    "PATH=C:\\Windows\\System32;C:\\Windows\r\n" ++
                    "PATHEXT=.COM;.EXE;.BAT;.CMD\r\n" ++
                    "windir=C:\\Windows\r\n" ++
                    "systemroot=C:\\Windows\r\n" ++
                    "userprofile=C:\\Users\\Administrator\r\n" ++
                    "computername=ZIRCONOSAERO\r\n");
            }
            return formatOutput(out_buf, "SET {s}\r\n", .{arg_str});
        }

        if (std.ascii.eqlIgnoreCase(cmd_str, "color")) {
            if (arg_len == 0) {
                return formatOutputStatic(out_buf, "Sets the default console foreground and background colors.\r\nUsage: color [attr]\r\n");
            }
            return formatOutput(out_buf, "Color set to: {s}\r\n", .{arg_str});
        }

        // Unknown command
        return formatOutput(out_buf, "'{s}' is not recognized as an internal or external command,\r\noperable program or batch file.\r\n", .{cmd_str});
    }

    fn processDirCommand(shell: *CmdShell, path_arg: []const u8, out_buf: []u8) usize {
        var offset: usize = 0;

        // Determine path to list
        var target_drive = shell.current_drive;
        var target_path: ?[]const u8 = null;

        if (path_arg.len > 0) {
            // Check if it's a drive letter
            if (path_arg.len >= 2 and path_arg[1] == ':') {
                target_drive = if (path_arg[0] >= 'a' and path_arg[0] <= 'z')
                    path_arg[0] - 32
                else
                    path_arg[0];
                if (path_arg.len > 2) {
                    // Skip drive letter and check for path
                    var path_start: usize = 2;
                    while (path_start < path_arg.len and path_arg[path_start] == ' ') path_start += 1;
                    if (path_start < path_arg.len) {
                        target_path = path_arg[path_start..];
                    }
                }
            } else {
                target_path = path_arg;
            }
        } else {
            // Use current path
            if (shell.current_path_len > 1) {
                target_path = shell.current_path[1..shell.current_path_len]; // Skip leading \
            }
        }

        // Format header
        var header_buf: [256]u8 = undefined;
        const header_result = std.fmt.bufPrint(&header_buf, " Volume in drive {c} is ZirconOS\r\n", .{@as(u8, target_drive)}) catch null;
        const header_len = if (header_result) |r| r.len else 0;
        @memcpy(out_buf[0..header_len], header_buf[0..header_len]);
        offset = header_len;

        var path_desc_buf: [256]u8 = undefined;
        var path_desc: []const u8 = undefined;
        if (target_path) |tp| {
            path_desc = std.fmt.bufPrint(&path_desc_buf, " Directory of {c}:{s}\r\n\r\n", .{ @as(u8, target_drive), tp }) catch "";
        } else {
            path_desc = std.fmt.bufPrint(&path_desc_buf, " Directory of {c}:\\\r\n\r\n", .{@as(u8, target_drive)}) catch "";
        }
        @memcpy(out_buf[offset..][0..path_desc.len], path_desc);
        offset += path_desc.len;

        // Read directory entries
        var entries: [64]explorer_vol_snap.ExplorerListEntry = undefined;
        const count = explorer_vol_snap.readDirectoryGeneric(target_drive, target_path, entries[0..], .name, true);

        if (count == 0) {
            @memcpy(out_buf[offset..], "Directory is empty.\r\n");
            offset += 18;
            return offset;
        }

        var file_count: usize = 0;
        var dir_count: usize = 0;
        var total_size: u64 = 0;

        for (entries[0..count]) |entry| {
            if (entry.name_len == 0) continue;

            // Date/time column
            var date_str: [24]u8 = undefined;
            @memcpy(&date_str, &entry.date);

            // Size or <DIR>
            var size_str: [32]u8 = undefined;
            var size_len: usize = 0;
            if (entry.is_directory) {
                const result = std.fmt.bufPrint(&size_str, "    <DIR>", .{}) catch null;
                if (result) |r| size_len = r.len;
                dir_count += 1;
            } else {
                const result = std.fmt.bufPrint(&size_str, "{d:>10} ", .{entry.file_size}) catch null;
                if (result) |r| size_len = r.len;
                file_count += 1;
                total_size += entry.file_size;
            }

            // Format line: MM/DD/YYYY  HH:MM    size    name
            var line_buf: [320]u8 = undefined;
            const line_result = std.fmt.bufPrint(&line_buf, "{s}  {s}{s}\r\n", .{ date_str[0..entry.date_len], size_str[0..size_len], entry.name[0..entry.name_len] }) catch null;
            const line_len = if (line_result) |r| r.len else 0;

            if (offset + line_len < out_buf.len) {
                @memcpy(out_buf[offset..][0..line_len], line_buf[0..line_len]);
                offset += line_len;
            }
        }

        // Summary line
        var summary_buf: [256]u8 = undefined;
        const summary_result = std.fmt.bufPrint(&summary_buf, "\r\n       {d} File(s)    {d} bytes\r\n       {d} Dir(s)     {d} bytes free\r\n", .{ file_count, total_size, dir_count, @as(u64, 512 * 1024 * 1024) }) catch null;
        const summary_len = if (summary_result) |r| r.len else 0;

        if (offset + summary_len < out_buf.len) {
            @memcpy(out_buf[offset..][0..summary_len], summary_buf[0..summary_len]);
            offset += summary_len;
        }

        return offset;
    }

    fn processCdCommand(shell: *CmdShell, path_arg: []const u8, out_buf: []u8) usize {
        if (path_arg.len == 0) {
            // Display current directory
            var curdir_buf: [256]u8 = undefined;
            const result = std.fmt.bufPrint(&curdir_buf, "{c}:{s}\r\n", .{ @as(u8, shell.current_drive), shell.current_path[0..shell.current_path_len] }) catch null;
            const len = if (result) |r| r.len else 0;
            @memcpy(out_buf[0..len], curdir_buf[0..len]);
            return len;
        }

        // Handle special cases
        if (std.mem.eql(u8, path_arg, "..") or std.mem.eql(u8, path_arg, "..\\")) {
            // Go to parent directory
            if (shell.current_path_len > 1) {
                // Find last \ in path
                var last_sep: usize = shell.current_path_len - 1;
                while (last_sep > 0 and shell.current_path[last_sep - 1] != '\\') {
                    last_sep -= 1;
                }
                if (last_sep > 0) {
                    shell.current_path_len = last_sep;
                }
            }
            return 0;
        }

        if (std.mem.eql(u8, path_arg, "\\") or std.mem.eql(u8, path_arg, "\\\"")) {
            // Go to root
            shell.current_path[0] = '\\';
            shell.current_path_len = 1;
            return 0;
        }

        // Handle drive letter change
        if (path_arg.len >= 2 and path_arg[1] == ':') {
            const new_drive = if (path_arg[0] >= 'a' and path_arg[0] <= 'z')
                path_arg[0] - 32
            else
                path_arg[0];

            // Verify drive exists
            var vol_buf: [64]explorer_vol_snap.ExplorerVolume = undefined;
            const vol_count = explorer_vol_snap.refreshVolumes(vol_buf[0..]);
            var found = false;

            for (vol_buf[0..vol_count]) |vol| {
                if (vol.letter == new_drive) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                return formatOutputStatic(out_buf, "The system cannot find the drive specified.\r\n");
            }

            shell.current_drive = new_drive;

            // If just drive letter, stay at root
            if (path_arg.len == 2) {
                shell.current_path[0] = '\\';
                shell.current_path_len = 1;
                return 0;
            }
        }

        // Try to navigate to the specified directory
        var path_buf: [256]u8 = undefined;
        var path_len: usize = 0;

        if (path_arg[0] != '\\' and path_arg[0] != '/') {
            // Relative path - append to current
            if (shell.current_path_len > 0 and shell.current_path[0] == '\\') {
                @memcpy(path_buf[0..shell.current_path_len], shell.current_path[0..shell.current_path_len]);
                path_len = shell.current_path_len;
                if (path_len > 0 and path_buf[path_len - 1] != '\\') {
                    path_buf[path_len] = '\\';
                    path_len += 1;
                }
            }
        }

        // Append the target path
        @memcpy(path_buf[path_len..][0..path_arg.len], path_arg);
        path_len += path_arg.len;

        // Try to open the directory
        var full_path_buf: [272]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_path_buf, "{c}:{s}", .{ shell.current_drive, path_buf[0..path_len] }) catch "";

        if (vfs.open(full_path, .read)) |h| {
            if (h.file_type == .directory) {
                // Success - update current path
                shell.current_path_len = path_len;
                _ = vfs.close(h);
                return 0;
            }
            _ = vfs.close(h);
            return formatOutputStatic(out_buf, "The directory name is invalid.\r\n");
        }

            return formatOutputStatic(out_buf, "The system cannot find the path specified.\r\n");
    }

    fn processTypeCommand(shell: *CmdShell, filename: []const u8, out_buf: []u8) usize {
        if (filename.len == 0) {
            return formatOutputStatic(out_buf, "Type the file name. Syntax: TYPE [drive:][path]filename\r\n");
        }

        // Build full path
        var full_path_buf: [272]u8 = undefined;
        var full_path: []const u8 = undefined;

        if (filename.len >= 2 and filename[1] == ':') {
            // Already has drive letter
            full_path = filename;
        } else {
            full_path = std.fmt.bufPrint(&full_path_buf, "{c}:{s}{s}", .{ shell.current_drive, shell.current_path[0..shell.current_path_len], filename }) catch filename;
        }

        // Open and read file
        if (vfs.open(full_path, .read)) |h| {
            if (h.file_type == .directory) {
                _ = vfs.close(h);
                return formatOutputStatic(out_buf, "Access Denied.\r\n");
            }

            var read_buf: [4096]u8 = undefined;
            const result = vfs.read(h, &read_buf);
            _ = vfs.close(h);

            if (result.status == .success) {
                const copy_len = @min(result.bytes_read, out_buf.len - 2);
                @memcpy(out_buf[0..copy_len], read_buf[0..copy_len]);
                out_buf[copy_len] = '\r';
                out_buf[copy_len + 1] = '\n';
                return copy_len + 2;
            }

            return formatOutputStatic(out_buf, "Error reading file.\r\n");
        }

            return formatOutputStatic(out_buf, "The system cannot find the file specified.\r\n");
    }

    fn processVolCommand(shell: *CmdShell, out_buf: []u8) usize {
        var vol_buf: [64]explorer_vol_snap.ExplorerVolume = undefined;
        const vol_count = explorer_vol_snap.refreshVolumes(vol_buf[0..]);

        for (vol_buf[0..vol_count]) |vol| {
            if (vol.letter == shell.current_drive) {
                if (vol.space_known) {
                    var vol_buf_out: [256]u8 = undefined;
                    const result = std.fmt.bufPrint(&vol_buf_out, " Volume in drive {c} is {s}\r\n" ++
                        " Volume Serial Number is A4B3-C2D1\r\n\r\n" ++
                        " {d} bytes total disk space\r\n" ++
                        " {d} bytes free\r\n", .{ vol.letter, vol.label[0..vol.label_len], vol.total_mb * 1024 * 1024, vol.free_mb * 1024 * 1024 }) catch null;
                    if (result) |r| {
                        @memcpy(out_buf[0..r.len], r);
                        return r.len;
                    }
                    return 0;
                }
                var vol_buf_out: [256]u8 = undefined;
                const result = std.fmt.bufPrint(&vol_buf_out, " Volume in drive {c} is {s}\r\n" ++
                    " Volume Serial Number is A4B3-C2D1\r\n", .{ vol.letter, vol.label[0..vol.label_len] }) catch null;
                if (result) |r| {
                    @memcpy(out_buf[0..r.len], r);
                    return r.len;
                }
                return 0;
            }
        }

            return formatOutputStatic(out_buf, "Volume information not available.\r\n");
    }

    fn formatOutput(buf: []u8, comptime fmt: []const u8, args: anytype) usize {
        const result = std.fmt.bufPrint(buf, fmt, args) catch return 0;
        return result.len;
    }

    fn formatOutputStatic(buf: []u8, text: []const u8) usize {
        const len = @min(text.len, buf.len);
        @memcpy(buf[0..len], text);
        return len;
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

        fb.fillRect(wx, wy + ch, ww, wh - ch, rgb(0x00, 0x00, 0x00));
        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));

        const title = "Administrator: C:\\Windows\\system32\\cmd.exe";
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
                fb.drawTextTransparent(shell.x + 8, y_offset, cmdline.prompt, rgb(0xFF, 0xFF, 0xFF));
            }

            if (cmdline.command.len > 0) {
                fb.drawTextTransparent(shell.x + 8 + @as(i32, @intCast(cmdline.prompt.len * 8)), y_offset, cmdline.command, rgb(0xFF, 0xFF, 0xFF));
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

        const prompt = shell.getPrompt();
        const prompt_x = shell.x + 8;
        const prompt_y = shell.y + shell.height - 24;
        fb.drawTextTransparent(prompt_x, prompt_y, prompt, rgb(0xFF, 0xFF, 0xFF));

        const input_x = prompt_x + @as(i32, @intCast(prompt.len * 8));
        if (shell.input_len > 0) {
            fb.drawTextTransparent(input_x, prompt_y, shell.input_buffer[0..shell.input_len], rgb(0xFF, 0xFF, 0xFF));
        }

        if (shell.focused and shell.cursor_blink) {
            const cursor_screen_x = input_x + shell.cursor_x * 8;
            fb.drawVLine(cursor_screen_x, prompt_y, 14, rgb(0xFF, 0xFF, 0xFF));
        }
    }
};
