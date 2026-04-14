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
// Module: src/desktop/applications/control_panel/applets/programs.zig
// Purpose: Programs and Features Applet
//
// This is an independent clean-room implementation.

const std = @import("std");
const applet_base = @import("applet_base.zig");
const fb = @import("../../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../../kernel/theme/root.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const ProgramsApplet = struct {
    base: applet_base.ControlPanelApplet,
    programs: [20]ProgramInfo,
    program_count: usize,
    selected_index: usize,
    sort_by: SortField,
    hover_state: HoverArea,

    pub const ProgramInfo = struct {
        name: [64]u8,
        name_len: usize,
        size: u64,
        date_installed: u32,
        publisher: [32]u8,
        publisher_len: usize,
    };

    pub const SortField = enum { name, size, date };

    pub const HoverArea = enum { none, btn_uninstall, btn_change, btn_online };

    pub fn create(x: i32, y: i32, w: i32, h: i32) ProgramsApplet {
        var pa = ProgramsApplet{
            .base = applet_base.ControlPanelApplet.create(.programs, x, y, w, h),
            .programs = std.mem.zeroes([20]ProgramInfo),
            .program_count = 5,
            .selected_index = 0,
            .sort_by = .name,
            .hover_state = .none,
        };

        @memcpy(pa.programs[0].name[0..19], "ZirconOSAero System");
        pa.programs[0].name_len = 19;
        pa.programs[0].size = 524288000;
        pa.programs[0].date_installed = 20260401;
        @memcpy(pa.programs[0].publisher[0..13], "ZirconOS Team");
        pa.programs[0].publisher_len = 13;

        @memcpy(pa.programs[1].name[0..7], "Notepad");
        pa.programs[1].name_len = 7;
        pa.programs[1].size = 204800;
        pa.programs[1].date_installed = 20260401;
        @memcpy(pa.programs[1].publisher[0..13], "ZirconOS Team");
        pa.programs[1].publisher_len = 13;

        @memcpy(pa.programs[2].name[0..10], "Calculator");
        pa.programs[2].name_len = 10;
        pa.programs[2].size = 102400;
        pa.programs[2].date_installed = 20260401;
        @memcpy(pa.programs[2].publisher[0..13], "ZirconOS Team");
        pa.programs[2].publisher_len = 13;

        @memcpy(pa.programs[3].name[0..5], "Paint");
        pa.programs[3].name_len = 5;
        pa.programs[3].size = 307200;
        pa.programs[3].date_installed = 20260401;
        @memcpy(pa.programs[3].publisher[0..13], "ZirconOS Team");
        pa.programs[3].publisher_len = 13;

        @memcpy(pa.programs[4].name[0..10], "Minesweeper");
        pa.programs[4].name_len = 10;
        pa.programs[4].size = 512000;
        pa.programs[4].date_installed = 20260401;
        @memcpy(pa.programs[4].publisher[0..13], "ZirconOS Team");
        pa.programs[4].publisher_len = 13;

        return pa;
    }

    pub fn onMouseMove(_: *ProgramsApplet, px: i32, py: i32) void {
        _ = px;
        _ = py;
    }

    pub fn render(applet: *ProgramsApplet) void {
        if (!applet.base.visible) return;
        applet.base.renderCaptionBar("Programs and Features");

        const client = applet.base.getClientRect();
        fb.fillRect(client.x + 1, client.y + 1, client.width - 2, client.height - 2, rgb(0xF8, 0xFC, 0xFF));

        var cy = client.y + 20;

        // Toolbar
        applet.drawToolbar(client.x + 16, cy, client.width - 32);
        cy += 50;

        // Program list
        applet.base.drawGroupBox(client.x + 16, cy, client.width - 32, 240, "Installed Programs");
        applet.drawProgramList(client.x + 24, cy + 24, client.width - 48, client.y + cy + 264);
        cy += 260;

        applet.base.drawButton(client.x + 16, cy, 110, 28, "Uninstall", applet.hover_state == .btn_uninstall);
        applet.base.drawButton(client.x + 136, cy, 100, 28, "Change", applet.hover_state == .btn_change);
        applet.base.drawButton(client.x + 246, cy, 110, 28, "Check Online", applet.hover_state == .btn_online);
    }

    fn drawToolbar(applet: *ProgramsApplet, x: i32, y: i32, w: i32) void {
        _ = w;
        fb.fillRect(x, y, 400, 40, rgb(0xF0, 0xF4, 0xF8));
        fb.drawHLine(x, y + 39, 400, rgb(0xC0, 0xC8, 0xD8));

        const fields = [_][]const u8{ "Name", "Size", "Installed On" };
        const sort_x = [_]i32{ x + 8, x + 250, x + 350 };

        inline for (fields, 0..) |field, i| {
            const is_selected = (@as(usize, @intCast(@intFromEnum(applet.sort_by))) == i);
            fb.drawTextTransparent(sort_x[i], y + 12, field, if (is_selected) rgb(0x10, 0x40, 0x90) else rgb(0x30, 0x30, 0x50));
        }
    }

    fn drawProgramList(applet: *ProgramsApplet, x: i32, y: i32, w: i32, bottom: i32) void {
        const row_h: i32 = 36;
        const cols = [_]i32{ x, x + 240, x + 340 };

        fb.fillRect(x, y, w, bottom - y, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(x, y, w, bottom - y, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        for (applet.programs[0..applet.program_count], 0..) |*prog, i| {
            const ry = y + @as(i32, @intCast(i)) * row_h;
            if (ry + row_h > bottom) break;

            const selected = (@as(usize, @intCast(i)) == applet.selected_index);
            if (selected) {
                fb.fillRect(x + 1, ry + 1, w - 2, row_h - 2, rgb(0xC8, 0xDC, 0xF0));
            }

            fb.drawTextTransparent(cols[0], ry + 10, prog.name[0..prog.name_len], if (selected) rgb(0x10, 0x30, 0x70) else rgb(0x10, 0x10, 0x18));

            var size_buf: [16]u8 = undefined;
            const size_mb = prog.size / (1024 * 1024);
            const size_str = std.fmt.bufPrint(&size_buf, "{d} MB", .{size_mb}) catch "";
            fb.drawTextTransparent(cols[1], ry + 10, size_str, rgb(0x40, 0x40, 0x40));

            fb.drawTextTransparent(cols[2], ry + 10, "2026-04-11", rgb(0x40, 0x40, 0x40));
        }
    }
};
