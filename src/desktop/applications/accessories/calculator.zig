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
// Module: src/desktop/applications/accessories/calculator.zig
// Purpose: Windows 7 style Calculator
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const dwm_mod = @import("../../../drivers/video/core/dwm.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const CalculatorMode = enum { standard, scientific, programmer, statistics };

pub const Calculator = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    focused: bool,
    mode: CalculatorMode,
    display: [32]u8,
    display_len: usize,
    memory: f64,
    has_decimal: bool,
    has_negative: bool,
    last_op: CalcOp,
    operand: f64,
    waiting_for_operand: bool,
    expression: [64]u8,
    expression_len: usize,
    caption_hover: CaptionButtonType,

    pub const CalcOp = enum { none, add, sub, mul, div, mod, pow, sqrt };

    const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) Calculator {
        var calc = Calculator{
            .x = x_pos, .y = y_pos,
            .width = 300, .height = 400,
            .visible = true,
            .focused = false,
            .mode = .standard,
            .display = undefined,
            .display_len = 1,
            .memory = 0.0,
            .has_decimal = false,
            .has_negative = false,
            .last_op = .none,
            .operand = 0.0,
            .waiting_for_operand = false,
            .expression = undefined,
            .expression_len = 0,
            .caption_hover = .none,
        };
        calc.display[0] = '0';
        calc.display_len = 1;
        return calc;
    }

    pub fn setMode(c: *Calculator, mode: CalculatorMode) void {
        c.mode = mode;
    }

    pub fn inputDigit(c: *Calculator, digit: u8) void {
        if (c.waiting_for_operand) {
            c.display_len = 0;
            c.waiting_for_operand = false;
            c.has_decimal = false;
            c.has_negative = false;
        }
        if (c.display_len < c.display.len - 1) {
            c.display[c.display_len] = digit;
            c.display_len += 1;
        }
    }

    pub fn inputDecimal(c: *Calculator) void {
        if (c.waiting_for_operand) {
            c.display_len = 0;
            c.waiting_for_operand = false;
        }
        if (!c.has_decimal and c.display_len < c.display.len - 1) {
            c.display[c.display_len] = '.';
            c.display_len += 1;
            c.has_decimal = true;
        }
    }

    pub fn inputOperator(c: *Calculator, op: CalcOp) void {
        c.waiting_for_operand = true;
        c.last_op = op;
    }

    pub fn calculate(c: *Calculator) void {
        const current = c.parseDisplay();
        switch (c.last_op) {
            .add => c.operand += current,
            .sub => c.operand -= current,
            .mul => c.operand *= current,
            .div => c.operand = if (current != 0) c.operand / current else 0,
            else => c.operand = current,
        }
        c.formatDisplay(c.operand);
        c.waiting_for_operand = true;
        c.last_op = .none;
    }

    pub fn memoryStore(c: *Calculator) void {
        c.memory = c.parseDisplay();
    }

    pub fn memoryRecall(c: *Calculator) void {
        c.formatDisplay(c.memory);
        c.waiting_for_operand = true;
    }

    pub fn memoryClear(c: *Calculator) void {
        c.memory = 0.0;
    }

    pub fn memoryAdd(c: *Calculator) void {
        c.memory += c.parseDisplay();
    }

    pub fn clear(c: *Calculator) void {
        c.display[0] = '0';
        c.display_len = 1;
        c.operand = 0.0;
        c.last_op = .none;
        c.waiting_for_operand = false;
        c.has_decimal = false;
        c.has_negative = false;
    }

    pub fn clearEntry(c: *Calculator) void {
        c.display[0] = '0';
        c.display_len = 1;
        c.has_decimal = false;
        c.has_negative = false;
    }

    pub fn backspace(c: *Calculator) void {
        if (c.display_len > 1) {
            c.display_len -= 1;
        } else {
            c.display[0] = '0';
            c.display_len = 1;
        }
    }

    fn parseDisplay(c: *const Calculator) f64 {
        const str = c.display[0..c.display_len];
        return std.fmt.parseFloat(f64, str) catch 0.0;
    }

    fn formatDisplay(c: *Calculator, value: f64) void {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d:.8}", .{value}) catch "0";
        const len = @min(str.len, c.display.len - 1);
        @memcpy(c.display[0..len], str[0..len]);
        c.display_len = len;
        c.has_decimal = std.mem.indexOfScalar(u8, str[0..len], '.') != null;
    }

    pub fn render(c: *Calculator, t: *const theme_mod.ThemeColors) void {
        if (!c.visible) return;
        c.renderWindowFrame(t);
        c.renderDisplay(t);
        c.renderKeypad(t);
    }

    fn renderWindowFrame(c: *Calculator, t: *const theme_mod.ThemeColors) void {
        const wx = c.x;
        const wy = c.y;
        const ww = c.width;
        const wh = c.height;
        const ch: i32 = 32;

        if (dwm_mod.isInitialized() and dwm_mod.getConfig().shadow_enabled) {
            fb.fillRect(wx + 4, wy + 4, ww, wh, rgb(0x28, 0x28, 0x30));
        }

        fb.fillRect(wx, wy + ch, ww, wh - ch, rgb(0xD8, 0xE0, 0xE8));
        fb.draw3DRect(wx, wy + ch, ww, wh - ch, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB8));

        if (dwm_mod.isGlassEnabled()) {
            dwm_mod.renderGlassEffect(wx, wy, ww, ch, t.titlebar_active_left, .caption);
        } else {
            fb.drawGradientH(wx, wy, ww, ch, t.titlebar_active_left, t.titlebar_active_right);
        }

        c.renderCaptionButtons(t);

        const title = switch (c.mode) {
            .standard => "Standard",
            .scientific => "Scientific",
            .programmer => "Programmer",
            .statistics => "Statistics",
        };
        fb.drawTextTransparent(wx + 8, wy + 10, title, t.titlebar_text);
        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
    }

    fn renderCaptionButtons(c: *Calculator, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const wx = c.x;
        const wy = c.y;
        const ww = c.width;
        const ch: i32 = 32;

        const btn_h = 18;
        const btn_y = wy + @divTrunc(ch - btn_h, 2);
        const btn_w: i32 = 40;
        const btn_w_close: i32 = 48;
        const close_x = wx + ww - btn_w_close;
        const max_x = close_x - btn_w;
        _ = max_x;

        if (c.caption_hover == .close) {
            fb.fillRect(close_x, btn_y, btn_w_close, btn_h, rgb(0xE8, 0x11, 0x23));
        }

        const cx = close_x + @divTrunc(btn_w_close, 2);
        const cy = btn_y + @divTrunc(btn_h, 2);
        var d: i32 = -4;
        while (d <= 4) : (d += 1) {
            fb.putPixel32(@intCast(cx + d), @intCast(cy + d), if (c.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
            fb.putPixel32(@intCast(cx + d), @intCast(cy - d), if (c.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
        }
    }

    fn renderDisplay(c: *Calculator, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const dx = c.x + 8;
        const dy = c.y + 40;
        const dw = c.width - 16;
        const dh = 50;

        fb.fillRect(dx, dy, dw, dh, rgb(0xF8, 0xFC, 0xFF));
        fb.draw3DRect(dx, dy, dw, dh, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        const display_text = c.display[0..c.display_len];
        const text_x = dx + dw - @as(i32, @intCast(c.display_len)) * 10 - 8;
        fb.drawTextTransparent(text_x, dy + 16, display_text, rgb(0x10, 0x10, 0x10));
    }

    fn renderKeypad(c: *Calculator, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const kx = c.x + 8;
        const ky = c.y + 100;
        const kw: i32 = 64;
        const kh: i32 = 36;
        const gap: i32 = 4;

        const buttons = c.getButtonsForMode();
        var row: u8 = 0;
        while (row < 6) : (row += 1) {
            var col: u8 = 0;
            while (col < 4) : (col += 1) {
                const idx = @as(usize, @intCast(row * 4 + col));
                if (idx >= buttons.len) continue;
                const btn = buttons[idx];
                const bx = kx + @as(i32, @intCast(col)) * (kw + gap);
                const by = ky + @as(i32, @intCast(row)) * (kh + gap);

                if (btn.is_operator) {
                    fb.fillRect(bx, by, kw, kh, rgb(0xD0, 0xD0, 0xD8));
                    fb.draw3DRect(bx, by, kw, kh, rgb(0xFF, 0xFF, 0xFF), rgb(0xA0, 0xA8, 0xB0));
                } else {
                    fb.fillRect(bx, by, kw, kh, rgb(0xF0, 0xF4, 0xF8));
                    fb.draw3DRect(bx, by, kw, kh, rgb(0xFF, 0xFF, 0xFF), rgb(0xC0, 0xC8, 0xD0));
                }

                const text_color = if (btn.is_operator) rgb(0x10, 0x20, 0x40) else rgb(0x20, 0x20, 0x28);
                const text_x = bx + @divTrunc(kw, 2) - @as(i32, @intCast(btn.label.len)) * 4;
                const text_y = by + @divTrunc(kh - 14, 2);
                fb.drawTextTransparent(text_x, text_y, btn.label, text_color);
            }
        }
    }

    const CalcButton = struct { label: []const u8, is_operator: bool };

    fn getButtonsForMode(c: *const Calculator) []const CalcButton {
        _ = c;
        return &[_]CalcButton{
            .{ .label = "MC", .is_operator = true },
            .{ .label = "MR", .is_operator = true },
            .{ .label = "MS", .is_operator = true },
            .{ .label = "M+", .is_operator = true },
            .{ .label = "←", .is_operator = false },
            .{ .label = "CE", .is_operator = false },
            .{ .label = "C", .is_operator = false },
            .{ .label = "±", .is_operator = false },
            .{ .label = "7", .is_operator = false },
            .{ .label = "8", .is_operator = false },
            .{ .label = "9", .is_operator = false },
            .{ .label = "/", .is_operator = true },
            .{ .label = "4", .is_operator = false },
            .{ .label = "5", .is_operator = false },
            .{ .label = "6", .is_operator = false },
            .{ .label = "*", .is_operator = true },
            .{ .label = "1", .is_operator = false },
            .{ .label = "2", .is_operator = false },
            .{ .label = "3", .is_operator = false },
            .{ .label = "-", .is_operator = true },
            .{ .label = "0", .is_operator = false },
            .{ .label = ".", .is_operator = false },
            .{ .label = "=", .is_operator = true },
            .{ .label = "+", .is_operator = true },
        };
    }
};
