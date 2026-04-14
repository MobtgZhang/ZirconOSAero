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
// Module: src/desktop/applications/accessories/paint.zig
// Purpose: Windows 7 style Paint application
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const dwm_mod = @import("../../../drivers/video/core/dwm.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const PaintTool = enum {
    pencil,
    brush,
    eraser,
    fill,
    text,
    line,
    rectangle,
    ellipse,
    rounded_rectangle,
    select,
    select_freeform,
};

pub const PaintColor = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const PaintApp = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    focused: bool,
    canvas_x: i32,
    canvas_y: i32,
    canvas_width: i32,
    canvas_height: i32,
    canvas: []u8,
    canvas_size: usize,
    current_tool: PaintTool,
    current_color: PaintColor,
    brush_size: i32,
    is_drawing: bool,
    last_x: i32,
    last_y: i32,
    undo_stack: [10][]u8,
    undo_count: i32,
    caption_hover: CaptionButtonType,
    selected_tool_index: i32,
    zoom_level: i32,
    show_grid: bool,
    transparent_bg: bool,

    const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) PaintApp {
        const cw: usize = 800 * 600 * 4;
        var canvas: [4000000]u8 = undefined;
        @memset(&canvas, 0xFF);

        return .{
            .x = x_pos, .y = y_pos,
            .width = 900, .height = 650,
            .visible = true,
            .focused = false,
            .canvas_x = 0,
            .canvas_y = 0,
            .canvas_width = 800,
            .canvas_height = 600,
            .canvas = canvas[0..cw],
            .canvas_size = cw,
            .current_tool = .pencil,
            .current_color = .{ .r = 0, .g = 0, .b = 0 },
            .brush_size = 1,
            .is_drawing = false,
            .last_x = 0,
            .last_y = 0,
            .undo_stack = undefined,
            .undo_count = 0,
            .caption_hover = .none,
            .selected_tool_index = 0,
            .zoom_level = 100,
            .show_grid = false,
            .transparent_bg = false,
        };
    }

    pub fn setTool(p: *PaintApp, tool: PaintTool) void {
        p.current_tool = tool;
    }

    pub fn setColor(p: *PaintApp, r: u8, g: u8, b: u8) void {
        p.current_color = .{ .r = r, .g = g, .b = b };
    }

    pub fn drawPixel(p: *PaintApp, px: i32, py: i32) void {
        if (px < 0 or py < 0 or px >= p.canvas_width or py >= p.canvas_height) return;
        const idx = (@as(usize, @intCast(py)) * @as(usize, @intCast(p.canvas_width)) + @as(usize, @intCast(px))) * 4;
        if (idx + 2 >= p.canvas_size) return;
        p.canvas[idx] = p.current_color.b;
        p.canvas[idx + 1] = p.current_color.g;
        p.canvas[idx + 2] = p.current_color.r;
        p.canvas[idx + 3] = 0xFF;
    }

    pub fn drawLine(p: *PaintApp, x0: i32, y0: i32, x1: i32, y1: i32) void {
        const dx = @abs(x1 - x0);
        const dy = @abs(y1 - y0);
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx - dy;
        var x = x0;
        var y = y0;

        while (true) {
            const brush_half = p.brush_size / 2;
            var bx: i32 = 0;
            while (bx < p.brush_size) : (bx += 1) {
                var by: i32 = 0;
                while (by < p.brush_size) : (by += 1) {
                    p.drawPixel(x - brush_half + bx, y - brush_half + by);
                }
            }

            if (x == x1 and y == y1) break;
            const e2 = 2 * err;
            if (e2 > -dy) {
                err -= dy;
                x += sx;
            }
            if (e2 < dx) {
                err += dx;
                y += sy;
            }
        }
    }

    pub fn fill(p: *PaintApp, start_x: i32, start_y: i32) void {
        if (start_x < 0 or start_y < 0 or start_x >= p.canvas_width or start_y >= p.canvas_height) return;
        const start_idx = (@as(usize, @intCast(start_y)) * @as(usize, @intCast(p.canvas_width)) + @as(usize, @intCast(start_x))) * 4;
        const target_color = [4]u8{ p.canvas[start_idx], p.canvas[start_idx + 1], p.canvas[start_idx + 2], p.canvas[start_idx + 3] };
        if (target_color[0] == p.current_color.b and target_color[1] == p.current_color.g and target_color[2] == p.current_color.r) return;

        var stack: [65536]struct { x: i32, y: i32 } = undefined;
        var stack_top: usize = 0;
        stack[stack_top] = .{ .x = start_x, .y = start_y };
        stack_top += 1;

        while (stack_top > 0) {
            stack_top -= 1;
            const pt = stack[stack_top];
            if (pt.x < 0 or pt.y < 0 or pt.x >= p.canvas_width or pt.y >= p.canvas_height) continue;

            const idx = (@as(usize, @intCast(pt.y)) * @as(usize, @intCast(p.canvas_width)) + @as(usize, @intCast(pt.x))) * 4;
            const current = [4]u8{ p.canvas[idx], p.canvas[idx + 1], p.canvas[idx + 2], p.canvas[idx + 3] };
            if (current[0] != target_color[0] or current[1] != target_color[1] or current[2] != target_color[2]) continue;

            p.drawPixel(pt.x, pt.y);

            if (stack_top < stack.len - 1) {
                stack[stack_top] = .{ .x = pt.x + 1, .y = pt.y };
                stack_top += 1;
            }
            if (stack_top < stack.len - 1) {
                stack[stack_top] = .{ .x = pt.x - 1, .y = pt.y };
                stack_top += 1;
            }
            if (stack_top < stack.len - 1) {
                stack[stack_top] = .{ .x = pt.x, .y = pt.y + 1 };
                stack_top += 1;
            }
            if (stack_top < stack.len - 1) {
                stack[stack_top] = .{ .x = pt.x, .y = pt.y - 1 };
                stack_top += 1;
            }
        }
    }

    pub fn startDrawing(p: *PaintApp, x: i32, y: i32) void {
        p.is_drawing = true;
        p.last_x = x;
        p.last_y = y;
        switch (p.current_tool) {
            .pencil, .brush, .eraser => p.drawPixel(x, y),
            .fill => p.fill(x, y),
            else => {},
        }
    }

    pub fn continueDrawing(p: *PaintApp, x: i32, y: i32) void {
        if (!p.is_drawing) return;
        switch (p.current_tool) {
            .pencil, .brush => p.drawLine(p.last_x, p.last_y, x, y),
            .eraser => {
                const old_color = p.current_color;
                p.current_color = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
                p.drawLine(p.last_x, p.last_y, x, y);
                p.current_color = old_color;
            },
            else => {},
        }
        p.last_x = x;
        p.last_y = y;
    }

    pub fn endDrawing(p: *PaintApp) void {
        p.is_drawing = false;
    }

    pub fn render(p: *PaintApp, t: *const theme_mod.ThemeColors) void {
        if (!p.visible) return;
        p.renderWindowFrame(t);
        p.renderToolbar(t);
        p.renderColorPalette(t);
        p.renderCanvas(t);
        p.renderStatusBar(t);
    }

    fn renderWindowFrame(p: *PaintApp, t: *const theme_mod.ThemeColors) void {
        const wx = p.x;
        const wy = p.y;
        const ww = p.width;
        const wh = p.height;
        const ch: i32 = 32;

        if (dwm_mod.isInitialized() and dwm_mod.getConfig().shadow_enabled) {
            fb.fillRect(wx + 4, wy + 4, ww, wh, rgb(0x28, 0x28, 0x30));
        }

        fb.fillRect(wx, wy + ch, ww, wh - ch, rgb(0xE8, 0xEC, 0xF0));

        if (dwm_mod.isGlassEnabled()) {
            dwm_mod.renderGlassEffect(wx, wy, ww, ch, t.titlebar_active_left, .caption);
        } else {
            fb.drawGradientH(wx, wy, ww, ch, t.titlebar_active_left, t.titlebar_active_right);
        }

        p.renderCaptionButtons(t);
        fb.drawTextTransparent(wx + 8, wy + 10, "Paint", t.titlebar_text);
        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
    }

    fn renderCaptionButtons(p: *PaintApp, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const wx = p.x;
        const wy = p.y;
        const ww = p.width;
        const ch: i32 = 32;

        const btn_h = 18;
        const btn_y = wy + @divTrunc(ch - btn_h, 2);
        const btn_w_close: i32 = 48;
        const close_x = wx + ww - btn_w_close;

        if (p.caption_hover == .close) {
            fb.fillRect(close_x, btn_y, btn_w_close, btn_h, rgb(0xE8, 0x11, 0x23));
        }

        const cx = close_x + @divTrunc(btn_w_close, 2);
        const cy = btn_y + @divTrunc(btn_h, 2);
        var d: i32 = -4;
        while (d <= 4) : (d += 1) {
            fb.putPixel32(@intCast(cx + d), @intCast(cy + d), if (p.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
            fb.putPixel32(@intCast(cx + d), @intCast(cy - d), if (p.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
        }
    }

    fn renderToolbar(p: *PaintApp, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const tx = p.x + 4;
        const ty = p.y + 36;
        const th: i32 = 36;

        fb.fillRect(tx, ty, p.width - 8, th, rgb(0xEC, 0xEC, 0xEC));
        fb.drawHLine(tx, ty + th - 1, p.width - 8, rgb(0xC0, 0xC8, 0xD8));

        const tools = [_][]const u8{ "P", "B", "E", "F", "T", "L", "R", "O" };
        var tool_x = tx + 8;
        for (tools, 0..) |tool, idx| {
            const is_selected = @as(i32, @intCast(idx)) == p.selected_tool_index;
            if (is_selected) {
                fb.fillRect(tool_x - 2, ty + 4, 28, 28, rgb(0xD0, 0xD8, 0xE8));
                fb.draw3DRect(tool_x - 2, ty + 4, 28, 28, rgb(0x5C, 0x9E, 0xD6), rgb(0x5C, 0x9E, 0xD6));
            } else {
                fb.fillRect(tool_x - 2, ty + 4, 28, 28, rgb(0xF0, 0xF4, 0xF8));
                fb.draw3DRect(tool_x - 2, ty + 4, 28, 28, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
            }
            fb.drawTextTransparent(tool_x + 8, ty + 12, tool, rgb(0x30, 0x30, 0x40));
            tool_x += 32;
        }

        tool_x += 16;

        const sizes = [_][]const u8{ "1", "2", "3", "4" };
        for (sizes) |size| {
            fb.fillRect(tool_x - 2, ty + 4, 24, 24, rgb(0xF0, 0xF4, 0xF8));
            fb.draw3DRect(tool_x - 2, ty + 4, 24, 24, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD8));
            fb.drawTextTransparent(tool_x + 6, ty + 12, size, rgb(0x30, 0x30, 0x40));
            tool_x += 28;
        }
    }

    fn renderColorPalette(p: *PaintApp, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const px = p.x + 4;
        const py = p.y + 76;
        const ph: i32 = 32;

        fb.fillRect(px, py, p.width - 8, ph, rgb(0xD8, 0xDC, 0xE4));
        fb.drawHLine(px, py + ph - 1, p.width - 8, rgb(0xC0, 0xC8, 0xD8));

        const colors = [_]struct { r: u8, g: u8, b: u8 }{
            .{ .r = 0, .g = 0, .b = 0 },
            .{ .r = 0x80, .g = 0x80, .b = 0x80 },
            .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
            .{ .r = 0xFF, .g = 0, .b = 0 },
            .{ .r = 0, .g = 0xFF, .b = 0 },
            .{ .r = 0, .g = 0, .b = 0xFF },
            .{ .r = 0xFF, .g = 0xFF, .b = 0 },
            .{ .r = 0, .g = 0xFF, .b = 0xFF },
            .{ .r = 0xFF, .g = 0, .b = 0xFF },
            .{ .r = 0x80, .g = 0, .b = 0 },
            .{ .r = 0, .g = 0x80, .b = 0 },
            .{ .r = 0, .g = 0, .b = 0x80 },
            .{ .r = 0x80, .g = 0x80, .b = 0 },
            .{ .r = 0, .g = 0x80, .b = 0x80 },
            .{ .r = 0x80, .g = 0, .b = 0x80 },
            .{ .r = 0xC0, .g = 0xC0, .b = 0xC0 },
        };

        var color_x = px + 8;
        var color_y = py + 4;
        for (colors) |color| {
            const is_current = color.r == p.current_color.r and color.g == p.current_color.g and color.b == p.current_color.b;
            fb.fillRect(color_x, color_y, 20, 20, rgb(color.r, color.g, color.b));
            if (is_current) {
                fb.drawRect(color_x, color_y, 20, 20, rgb(0x00, 0x00, 0x00));
            } else {
                fb.draw3DRect(color_x, color_y, 20, 20, rgb(0xFF, 0xFF, 0xFF), rgb(0x80, 0x80, 0x80));
            }
            color_x += 26;
            if (color_x > px + p.width - 40) {
                color_x = px + 8;
                color_y += 26;
            }
        }
    }

    fn renderCanvas(p: *PaintApp, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const cx = p.x + p.canvas_x;
        const cy = p.y + p.canvas_y;
        const cw = p.canvas_width;
        const ch = p.canvas_height;

        fb.fillRect(cx, cy, cw, ch, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(cx, cy, cw, ch, rgb(0x80, 0x80, 0x88), rgb(0xFF, 0xFF, 0xFF));

        var py: i32 = 0;
        while (py < ch) : (py += 1) {
            var px: i32 = 0;
            while (px < cw) : (px += 1) {
                const idx = (@as(usize, @intCast(py)) * @as(usize, @intCast(cw)) + @as(usize, @intCast(px))) * 4;
                if (idx + 2 < p.canvas.len and p.canvas[idx + 3] == 0xFF) {
                    fb.putPixel32(cx + px, cy + py, rgb(p.canvas[idx + 2], p.canvas[idx + 1], p.canvas[idx]));
                }
            }
        }

        if (p.show_grid) {
            var gx: i32 = 0;
            while (gx < cw) : (gx += 10) {
                fb.drawVLine(cx + gx, cy, ch, rgb(0xE0, 0xE0, 0xE0));
            }
            var gy: i32 = 0;
            while (gy < ch) : (gy += 10) {
                fb.drawHLine(cx, cy + gy, cw, rgb(0xE0, 0xE0, 0xE0));
            }
        }
    }

    fn renderStatusBar(p: *PaintApp, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const sx = p.x + 4;
        const sy = p.y + p.height - 22;
        const sw = p.width - 8;

        fb.fillRect(sx, sy, sw, 20, rgb(0xE8, 0xEC, 0xF0));
        fb.drawHLine(sx, sy, sw, rgb(0xFF, 0xFF, 0xFF));

        const tool_names = [_][]const u8{ "Pencil", "Brush", "Eraser", "Fill", "Text", "Line", "Rectangle", "Ellipse" };
        const tool_name = if (@intFromEnum(p.current_tool) < tool_names.len) tool_names[@intFromEnum(p.current_tool)] else "Unknown";
        var color_buf: [16]u8 = undefined;
        const color_str = std.fmt.bufPrint(&color_buf, "RGB({d},{d},{d})", .{ p.current_color.r, p.current_color.g, p.current_color.b }) catch "";
        var size_buf: [8]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "Size: {d}", .{p.brush_size}) catch "";

        fb.drawTextTransparent(sx + 8, sy + 4, tool_name, rgb(0x30, 0x30, 0x40));
        fb.drawTextTransparent(sx + 100, sy + 4, color_str, rgb(0x30, 0x30, 0x40));
        fb.drawTextTransparent(sx + 220, sy + 4, size_str, rgb(0x30, 0x30, 0x40));
        fb.drawTextTransparent(sx + sw - 80, sy + 4, "100%", rgb(0x30, 0x30, 0x40));
    }
};
