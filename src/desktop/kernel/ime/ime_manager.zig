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
// Module: src/desktop/kernel/ime/ime_manager.zig
// Purpose: IME Manager - manages IME instances and global input state
//
// Clean-room implementation. Reference: Microsoft IMM32 API behavior.

const std = @import("std");
const klog = @import("../../../rtl/klog.zig");
const input_context = @import("input_context.zig");
const candidates = @import("candidates.zig");
const pinyin_engine = @import("pinyin_engine.zig");
const imm_bridge = @import("imm_bridge.zig");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");

/// Maximum number of IME instances
pub const MAX_IME_INSTANCES: usize = 2;

/// Maximum number of input contexts per IME
pub const MAX_INPUT_CONTEXTS: usize = 16;

/// IME state
pub const ImeState = enum {
    disabled,    // IME disabled
    enabled,     // IME enabled, normal input
    chinese,     // Chinese input mode (pinyin)
    english,     // English input mode
};

/// IME instance
pub const ImeInstance = struct {
    id: u32,
    state: ImeState,
    active_context: ?*input_context.InputContext,
    pinyin: pinyin_engine.PinyinEngine,
    candidate_window: candidates.CandidateWindow,
    imm_bridge: imm_bridge.ImmBridge,
    x: i32,  // IME composition window position
    y: i32,
};

/// Global IME manager
pub const ImeManager = struct {
    instances: [MAX_IME_INSTANCES]?ImeInstance,
    instance_count: usize,
    active_instance: ?*ImeInstance,
    default_x: i32,
    default_y: i32,

    /// Initialize IME manager
    pub fn init() ImeManager {
        return .{
            .instances = [_]?ImeInstance{null} ** MAX_IME_INSTANCES,
            .instance_count = 0,
            .active_instance = null,
            .default_x = 100,
            .default_y = 400,
        };
    }

    /// Create a new IME instance
    pub fn createInstance(mgr: *ImeManager) ?*ImeInstance {
        if (mgr.instance_count >= MAX_IME_INSTANCES) {
            klog.info("ime: max instances reached", .{});
            return null;
        }

        const id = @as(u32, @intCast(mgr.instance_count + 1));
        const idx = mgr.instance_count;

        mgr.instances[idx] = .{
            .id = id,
            .state = .chinese,
            .active_context = null,
            .pinyin = pinyin_engine.PinyinEngine.init(),
            .candidate_window = candidates.CandidateWindow.create(100, 400),
            .imm_bridge = imm_bridge.ImmBridge.init(),
            .x = mgr.default_x,
            .y = mgr.default_y,
        };

        mgr.instance_count += 1;

        if (mgr.active_instance == null) {
            mgr.active_instance = &mgr.instances[idx].?;
        }

        klog.info("ime: created instance id={}", .{id});
        return &mgr.instances[idx].?;
    }

    /// Get active IME instance
    pub fn getActive(mgr: *ImeManager) ?*ImeInstance {
        return mgr.active_instance;
    }

    /// Set active IME instance
    pub fn setActive(mgr: *ImeManager, inst: *ImeInstance) void {
        mgr.active_instance = inst;
    }

    /// Toggle IME on/off
    pub fn toggleIme(mgr: *ImeManager) void {
        if (mgr.active_instance) |inst| {
            switch (inst.state) {
                .disabled => inst.state = .chinese,
                .chinese => inst.state = .english,
                .english => inst.state = .disabled,
                .enabled => inst.state = .disabled,
            }
            klog.info("ime: state changed to {}", .{@tagName(inst.state)});
        }
    }

    /// Handle key input
    /// Returns true if key was consumed by IME
    pub fn handleKey(mgr: *ImeManager, vk_code: u8, is_key_down: bool) bool {
        if (!is_key_down) return false;
        if (mgr.active_instance) |inst| {
            return inst.handleKey(vk_code);
        }
        return false;
    }

    /// Get current composition string
    pub fn getComposition(mgr: *ImeManager) []const u8 {
        if (mgr.active_instance) |inst| {
            return inst.getComposition();
        }
        return "";
    }

    /// Get selected candidate
    pub fn getSelectedCandidate(mgr: *ImeManager) []const u8 {
        if (mgr.active_instance) |inst| {
            return inst.getSelectedCandidate();
        }
        return "";
    }

    /// Commit composition (send to application)
    pub fn commitComposition(mgr: *ImeManager) []const u8 {
        if (mgr.active_instance) |inst| {
            return inst.commitComposition();
        }
        return "";
    }

    /// Update IME window position
    pub fn updatePosition(mgr: *ImeManager, x: i32, y: i32) void {
        mgr.default_x = x;
        mgr.default_y = y;
        if (mgr.active_instance) |inst| {
            inst.x = x;
            inst.y = y;
            inst.candidate_window.updatePosition(x, y + 24);
        }
    }

    /// Render IME composition and candidate windows
    pub fn render(mgr: *ImeManager) void {
        if (mgr.active_instance) |inst| {
            inst.render();
        }
    }

    /// Check if IME is active (has composition or candidates)
    pub fn isActive(mgr: *ImeManager) bool {
        if (mgr.active_instance) |inst| {
            return inst.state == .chinese and inst.pinyin.getBuffer().len > 0;
        }
        return false;
    }

    /// Get current input mode
    pub fn getMode(mgr: *ImeManager) ImeState {
        if (mgr.active_instance) |inst| {
            return inst.state;
        }
        return .disabled;
    }
};

/// IME instance methods
fn handleKey(inst: *ImeInstance, vk_code: u8) bool {
    // Toggle IME with Ctrl+Space or Left Alt+Shift
    if (vk_code == 0x20 and inst.imm_bridge.isCtrlPressed()) {
        toggleMode(inst);
        return true;
    }

    // Alt+Shift toggles between Chinese and English
    if (vk_code == 0x10 and inst.imm_bridge.isAltPressed()) {
        toggleMode(inst);
        return true;
    }

    switch (inst.state) {
        .chinese => return handleChineseKey(inst, vk_code),
        .english => return false,  // Pass through
        .disabled, .enabled => return false,
    }
}

/// Handle key in Chinese mode
fn handleChineseKey(inst: *ImeInstance, vk_code: u8) bool {
    // Backspace
    if (vk_code == 0x08) {
        if (inst.pinyin.backspace()) {
            updateCandidates(inst);
        }
        return true;
    }

    // Escape - cancel composition
    if (vk_code == 0x1B) {
        cancelComposition(inst);
        return true;
    }

    // Enter - commit current selection
    if (vk_code == 0x0D) {
        _ = commitComposition(inst);
        return true;
    }

    // Space - select first candidate
    if (vk_code == 0x20) {
        if (inst.pinyin.getBuffer().len > 0) {
            selectCandidate(inst, 0);
            return true;
        }
        return false;
    }

    // Number keys 1-9 - select candidate
    if (vk_code >= 0x30 and vk_code <= 0x39) {
        const idx = vk_code - 0x30;
        if (idx < inst.candidate_window.count) {
            selectCandidate(inst, @as(usize, idx));
            return true;
        }
    }

    // Letter keys - add to pinyin buffer
    if ((vk_code >= 0x41 and vk_code <= 0x5A) or (vk_code >= 0x61 and vk_code <= 0x7A)) {
        // Convert to lowercase for pinyin
        const ch = if (vk_code >= 0x61) vk_code else vk_code + 0x20;
        const c: u8 = @as(u8, ch);
        if (inst.pinyin.append(c)) {
            updateCandidates(inst);
            return true;
        }
    }

    return false;
}

/// Toggle between Chinese and English mode
fn toggleMode(inst: *ImeInstance) void {
    switch (inst.state) {
        .chinese => inst.state = .english,
        .english => inst.state = .chinese,
        else => inst.state = .chinese,
    }
    klog.info("ime: instance {} mode changed to {}", .{ inst.id, @tagName(inst.state) });
}

/// Update candidate list
fn updateCandidates(inst: *ImeInstance) void {
    const pinyin_buf = inst.pinyin.getBuffer();
    if (pinyin_buf.len == 0) {
        inst.candidate_window.clear();
        return;
    }

    // Search pinyin dictionary
    var results: [candidates.MAX_CANDIDATES][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** candidates.MAX_CANDIDATES;
    const count = inst.pinyin.search(pinyin_buf, &results);

    inst.candidate_window.setCandidates(&results, count);
}

/// Select a candidate
fn selectCandidate(inst: *ImeInstance, idx: usize) void {
    const text = inst.candidate_window.getCandidate(idx);
    if (text.len > 0) {
        inst.imm_bridge.injectString(text);
        inst.pinyin.clear();
        inst.candidate_window.clear();
    }
}

/// Get current composition string
fn getComposition(inst: *ImeInstance) []const u8 {
    return inst.pinyin.getBuffer();
}

/// Get selected candidate
fn getSelectedCandidate(inst: *ImeInstance) []const u8 {
    return inst.candidate_window.getSelected();
}

/// Commit composition to application
fn commitComposition(inst: *ImeInstance) []const u8 {
    const selected = inst.candidate_window.getSelected();
    if (selected.len > 0) {
        inst.imm_bridge.injectString(selected);
        inst.pinyin.clear();
        inst.candidate_window.clear();
        return selected;
    }
    return "";
}

/// Cancel current composition
fn cancelComposition(inst: *ImeInstance) void {
    inst.pinyin.clear();
    inst.candidate_window.clear();
}

/// Render IME windows
fn render(inst: *ImeInstance) void {
    // Render candidate window if active
    if (inst.candidate_window.count > 0) {
        inst.candidate_window.render(inst.x, inst.y);
    }

    // Render mode indicator
    renderModeIndicator(inst);
}

/// Render mode indicator (Chinese/English toggle)
fn renderModeIndicator(inst: *ImeInstance) void {
    const x = inst.x;
    const y = inst.y;

    // Draw small indicator
    const label: []const u8 = switch (inst.state) {
        .chinese => "中",
        .english => "英",
        .disabled => "英",
        .enabled => "中",
    };

    fb.fillRect(x - 24, y - 4, 20, 18, theme.rgb(0xE8, 0xE8, 0xE8));
    fb.draw3DRect(x - 24, y - 4, 20, 18, theme.rgb(0xFF, 0xFF, 0xFF), theme.rgb(0xA0, 0xA0, 0xA0));
    fb.drawTextTransparent(x - 20, y, label, theme.rgb(0x20, 0x20, 0x20));
}
