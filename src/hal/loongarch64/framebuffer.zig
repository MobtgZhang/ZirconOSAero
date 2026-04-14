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

//! LoongArch framebuffer (ramfb) — 供 arch.initFramebuffer / display 路径使用。
//! UEFI GOP 几何须与 `boot.zig`/`main_loongarch64.zig` 的 `EfiHandoff.fb_*` 一致；`display.initDesktopMode` 会校验 `pitch >= width*bpp/8` 并打 `DesktopGOP:`。

var fb_addr: usize = 0;
var fb_pitch: usize = 0;
var fb_width: usize = 0;
var fb_height: usize = 0;
var fb_bpp: usize = 0;
var ready: bool = false;
var console_enabled: bool = true;

pub fn setConsoleEnabled(e: bool) void {
    console_enabled = e;
}

pub fn isConsoleEnabled() bool {
    return console_enabled;
}

pub fn init(addr: usize, width: u32, height: u32, pitch: u32, bpp: u8) void {
    fb_addr = addr;
    fb_width = width;
    fb_height = height;
    fb_pitch = pitch;
    fb_bpp = bpp;
    ready = true;
}

pub fn isReady() bool {
    return ready;
}

pub fn clear() void {
    if (!ready or !console_enabled) return;
    const total_bytes = fb_pitch * fb_height;
    const ptr: [*]volatile u8 = @ptrFromInt(fb_addr);
    var i: usize = 0;
    while (i < total_bytes) : (i += 1) {
        ptr[i] = 0;
    }
}

var cursor_x: usize = 0;
var cursor_y: usize = 0;
const CHAR_W: usize = 8;
const CHAR_H: usize = 16;
const FG_COLOR: u32 = 0x00FFFFFF;

pub fn write(data: []const u8) void {
    if (!ready or !console_enabled) return;
    if (fb_bpp != 32) return;
    const max_cols = fb_width / CHAR_W;
    const max_rows = fb_height / CHAR_H;
    if (max_cols == 0 or max_rows == 0) return;

    for (data) |ch| {
        if (ch == '\n') {
            cursor_x = 0;
            cursor_y += 1;
            if (cursor_y >= max_rows) cursor_y = 0;
            continue;
        }
        if (ch == '\r') {
            cursor_x = 0;
            continue;
        }
        if (cursor_x >= max_cols) {
            cursor_x = 0;
            cursor_y += 1;
            if (cursor_y >= max_rows) cursor_y = 0;
        }
        drawChar(cursor_x * CHAR_W, cursor_y * CHAR_H, ch);
        cursor_x += 1;
    }
}

fn drawChar(x: usize, y: usize, ch: u8) void {
    const fb: [*]volatile u32 = @ptrFromInt(fb_addr);
    const pitch32 = fb_pitch / 4;
    const printable = if (ch >= 0x20 and ch < 0x7F) ch else '.';
    _ = printable;
    var row: usize = 0;
    while (row < CHAR_H) : (row += 1) {
        const py = y + row;
        if (py >= fb_height) break;
        var col: usize = 0;
        while (col < CHAR_W) : (col += 1) {
            const px = x + col;
            if (px >= fb_width) break;
            // Simple 1-pixel dot at center for visible characters
            if (row >= 2 and row < CHAR_H - 2 and col >= 1 and col < CHAR_W - 1) {
                fb[py * pitch32 + px] = FG_COLOR;
            }
        }
    }
}
