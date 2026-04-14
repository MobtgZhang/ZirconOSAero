// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/kernel/ime/imm_bridge.zig
// Purpose: IMM Bridge - interfaces IME with Win32 message system
//
// Clean-room implementation. Reference: Microsoft IMM32 API behavior.
// This module bridges the IME framework with the Win32 message system.

const std = @import("std");
const klog = @import("../../../rtl/klog.zig");

/// Virtual key codes
pub const VK = struct {
    pub const SHIFT: u8 = 0x10;
    pub const CONTROL: u8 = 0x11;
    pub const MENU: u8 = 0x12;  // Alt key
    pub const SPACE: u8 = 0x20;
    pub const BACK: u8 = 0x08;
    pub const RETURN: u8 = 0x0D;
    pub const ESCAPE: u8 = 0x1B;
    pub const LEFT: u8 = 0x25;
    pub const UP: u8 = 0x26;
    pub const RIGHT: u8 = 0x27;
    pub const DOWN: u8 = 0x28;
    pub const HOME: u8 = 0x24;
    pub const END: u8 = 0x23;
    pub const PRIOR: u8 = 0x21;  // Page Up
    pub const NEXT: u8 = 0x22;   // Page Down
};

/// IMM Bridge - bridges IME with Win32 message system
pub const ImmBridge = struct {
    /// Output buffer for committed characters
    output_buffer: [64]u8,
    output_len: usize,

    /// Modifier key states (for detecting Ctrl+Space, Alt+Shift, etc.)
    shift_pressed: bool,
    ctrl_pressed: bool,
    alt_pressed: bool,

    /// Flag: output available
    output_ready: bool,

    /// Composition string (being edited)
    composition: [64]u8,
    composition_len: usize,

    /// Initialize IMM bridge
    pub fn init() ImmBridge {
        return .{
            .output_buffer = [_]u8{0} ** 64,
            .output_len = 0,
            .shift_pressed = false,
            .ctrl_pressed = false,
            .alt_pressed = false,
            .output_ready = false,
            .composition = [_]u8{0} ** 64,
            .composition_len = 0,
        };
    }

    /// Update modifier key states
    pub fn updateModifiers(bridge: *ImmBridge, vk_code: u8, is_pressed: bool) void {
        switch (vk_code) {
            VK.SHIFT => bridge.shift_pressed = is_pressed,
            VK.CONTROL => bridge.ctrl_pressed = is_pressed,
            VK.MENU => bridge.alt_pressed = is_pressed,
            else => {},
        }
    }

    /// Check if Ctrl is pressed
    pub fn isCtrlPressed(bridge: *ImmBridge) bool {
        return bridge.ctrl_pressed;
    }

    /// Check if Alt is pressed
    pub fn isAltPressed(bridge: *ImmBridge) bool {
        return bridge.alt_pressed;
    }

    /// Check if Shift is pressed
    pub fn isShiftPressed(bridge: *ImmBridge) bool {
        return bridge.shift_pressed;
    }

    /// Inject string into the application
    /// This simulates sending WM_CHAR messages to the focused window
    pub fn injectString(bridge: *ImmBridge, text: []const u8) void {
        // Copy to output buffer
        const len = @min(text.len, bridge.output_buffer.len - 1);
        @memcpy(bridge.output_buffer[0..len], text[0..len]);
        bridge.output_len = len;
        bridge.output_buffer[len] = 0;
        bridge.output_ready = true;

        klog.info("ime: committed '{}'", .{ text });
    }

    /// Get committed string
    pub fn getCommitted(bridge: *ImmBridge) []const u8 {
        return bridge.output_buffer[0..bridge.output_len];
    }

    /// Check if output is ready
    pub fn hasOutput(bridge: *ImmBridge) bool {
        return bridge.output_ready;
    }

    /// Consume output (clear after reading)
    pub fn consumeOutput(bridge: *ImmBridge) []const u8 {
        bridge.output_ready = false;
        const result = bridge.output_buffer[0..bridge.output_len];
        bridge.output_len = 0;
        @memset(&bridge.output_buffer, 0);
        return result;
    }

    /// Set composition string
    pub fn setComposition(bridge: *ImmBridge, text: []const u8) void {
        const len = @min(text.len, bridge.composition.len - 1);
        @memcpy(bridge.composition[0..len], text[0..len]);
        bridge.composition_len = len;
        bridge.composition[len] = 0;
    }

    /// Get composition string
    pub fn getComposition(bridge: *ImmBridge) []const u8 {
        return bridge.composition[0..bridge.composition_len];
    }

    /// Clear composition
    pub fn clearComposition(bridge: *ImmBridge) void {
        bridge.composition_len = 0;
        @memset(&bridge.composition, 0);
    }

    /// Generate WM_CHAR message parameters for a character
    /// Returns: .{ char, repeat_count, scan_code }
    pub fn generateWmCharParams(bridge: *ImmBridge, ch: u8) struct {
        ch: u32,
        repeat: u32,
        scan_code: u32,
    } {
        _ = bridge;
        // In a full implementation, this would generate proper virtual key codes
        return .{
            .ch = @as(u32, ch),
            .repeat = 1,
            .scan_code = 0,
        };
    }
};

/// Convert UTF-8 string to WM_CHAR messages
/// This function splits a UTF-8 string into individual characters
/// and prepares them for injection into the message queue.
pub fn utf8ToWmCharList(text: []const u8, output: *[256]u32) usize {
    var count: usize = 0;
    var i: usize = 0;

    while (i < text.len and count < 256) : (i += 1) {
        const byte = text[i];

        if (byte < 0x80) {
            // ASCII
            output[count] = byte;
            count += 1;
        } else if (byte < 0xC0) {
            // Continuation byte (shouldn't happen at start)
            continue;
        } else if (byte < 0xE0) {
            // 2-byte sequence
            if (i + 1 < text.len) {
                const codepoint = ((@as(u32, byte & 0x1F) << 6) |
                    @as(u32, text[i + 1] & 0x3F));
                output[count] = codepoint;
                count += 1;
                i += 1;
            }
        } else if (byte < 0xF0) {
            // 3-byte sequence (most common for Chinese)
            if (i + 2 < text.len) {
                const codepoint = ((@as(u32, byte & 0x0F) << 12) |
                    (@as(u32, text[i + 1] & 0x3F) << 6) |
                    @as(u32, text[i + 2] & 0x3F));
                output[count] = codepoint;
                count += 1;
                i += 2;
            }
        } else if (byte < 0xF8) {
            // 4-byte sequence
            if (i + 3 < text.len) {
                i += 3;
            }
        }
    }

    return count;
}
