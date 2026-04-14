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
// Module: src/desktop/kernel/ime/input_context.zig
// Purpose: Input Context - per-window input state management
//
// Clean-room implementation. Reference: Microsoft IMM32 Input Context API.

const std = @import("std");
const klog = @import("../../../rtl/klog.zig");

/// IME mode
pub const ImeMode = enum {
    disabled,
    ime,        // IME enabled
    native,     // Native mode (full-width characters)
    alphanumeric, // Alphanumeric mode (half-width)
};

/// Composition state
pub const CompositionState = enum {
    none,           // No composition in progress
    composing,      // User is typing pinyin
    candidates,     // Showing candidate list
    committed,      // Just committed a character
};

/// Input context - stores per-window input state
pub const InputContext = struct {
    /// Window handle this context belongs to
    hwnd: u64,

    /// Current IME mode
    mode: ImeMode,

    /// Composition state
    composition_state: CompositionState,

    /// Pinyin buffer (what user is typing)
    pinyin_buffer: [64]u8,
    pinyin_len: usize,

    /// Composition string (converted characters)
    composition_string: [64]u8,
    composition_len: usize,

    /// Caret position within composition
    caret_pos: usize,

    /// Composition attributes (underline, etc.)
    composition_attr: [64]u8,

    /// Cursor position for display
    cursor_x: i32,
    cursor_y: i32,

    /// Flag indicating input is enabled
    is_enabled: bool,

    /// Flag indicating native mode
    is_native_mode: bool,

    /// Initialize input context for a window
    pub fn init(hwnd: u64) InputContext {
        return .{
            .hwnd = hwnd,
            .mode = .ime,
            .composition_state = .none,
            .pinyin_buffer = [_]u8{0} ** 64,
            .pinyin_len = 0,
            .composition_string = [_]u8{0} ** 64,
            .composition_len = 0,
            .caret_pos = 0,
            .composition_attr = [_]u8{0} ** 64,
            .cursor_x = 0,
            .cursor_y = 0,
            .is_enabled = true,
            .is_native_mode = true,
        };
    }

    /// Set IME mode
    pub fn setMode(ctx: *InputContext, mode: ImeMode) void {
        ctx.mode = mode;
        klog.info("ime: context {} mode set to {}", .{ ctx.hwnd, @tagName(mode) });
    }

    /// Check if IME is enabled
    pub fn isEnabled(ctx: *const InputContext) bool {
        return ctx.is_enabled and ctx.mode != .disabled;
    }

    /// Append character to pinyin buffer
    pub fn appendPinyin(ctx: *InputContext, ch: u8) bool {
        if (ctx.pinyin_len >= ctx.pinyin_buffer.len - 1) {
            return false;
        }
        ctx.pinyin_buffer[ctx.pinyin_len] = ch;
        ctx.pinyin_len += 1;
        ctx.composition_state = .composing;
        return true;
    }

    /// Remove last character from pinyin buffer
    pub fn backspacePinyin(ctx: *InputContext) bool {
        if (ctx.pinyin_len == 0) return false;
        ctx.pinyin_len -= 1;
        ctx.pinyin_buffer[ctx.pinyin_len] = 0;
        if (ctx.pinyin_len == 0) {
            ctx.composition_state = .none;
        }
        return true;
    }

    /// Get pinyin buffer
    pub fn getPinyin(ctx: *const InputContext) []const u8 {
        return ctx.pinyin_buffer[0..ctx.pinyin_len];
    }

    /// Set composition string (converted from pinyin)
    pub fn setComposition(ctx: *InputContext, text: []const u8) void {
        const len = @min(text.len, ctx.composition_string.len - 1);
        @memcpy(ctx.composition_string[0..len], text[0..len]);
        ctx.composition_len = len;
        ctx.composition_string[len] = 0;

        // Set default attributes (all underlined)
        @memset(ctx.composition_attr[0..len], 1); // ATTRIBUTE_INPUT
    }

    /// Get composition string
    pub fn getComposition(ctx: *const InputContext) []const u8 {
        return ctx.composition_string[0..ctx.composition_len];
    }

    /// Clear composition
    pub fn clearComposition(ctx: *InputContext) void {
        ctx.pinyin_len = 0;
        ctx.pinyin_buffer = [_]u8{0} ** 64;
        ctx.composition_len = 0;
        ctx.composition_string = [_]u8{0} ** 64;
        ctx.composition_state = .none;
    }

    /// Set cursor position
    pub fn setCursorPos(ctx: *InputContext, x: i32, y: i32) void {
        ctx.cursor_x = x;
        ctx.cursor_y = y;
    }

    /// Move caret
    pub fn moveCaret(ctx: *InputContext, delta: i32) void {
        const new_pos = @as(i32, @intCast(ctx.caret_pos)) + delta;
        ctx.caret_pos = @as(usize, @intCast(@max(0, @min(new_pos, @as(i32, @intCast(ctx.composition_len))))));
    }

    /// Set composition state
    pub fn setCompositionState(ctx: *InputContext, state: CompositionState) void {
        ctx.composition_state = state;
    }

    /// Check if composing
    pub fn isComposing(ctx: *const InputContext) bool {
        return ctx.composition_state == .composing or ctx.composition_state == .candidates;
    }

    /// Set native mode
    pub fn setNativeMode(ctx: *InputContext, native: bool) void {
        ctx.is_native_mode = native;
    }

    /// Get native mode
    pub fn isNativeMode(ctx: *const InputContext) bool {
        return ctx.is_native_mode;
    }
};
