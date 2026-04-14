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
// Module: src/desktop/kernel/ime/root.zig
// Purpose: Input Method Framework - IME Manager and IMM Bridge
//
// Clean-room implementation of IME framework for NT 6.1 compatibility.
// Reference: Microsoft Learn - Input Method Manager (IMM) and Text Input Stack.
//
// This module provides:
// - IME Manager: manages multiple IME instances (max 2)
// - Input Context: manages per-window input state
// - Candidate Window: displays candidate list
// - Pinyin Engine: simple pinyin input method
// - IMM Bridge: interfaces with Win32 message system

pub const ime_manager = @import("ime_manager.zig");
pub const input_context = @import("input_context.zig");
pub const candidates = @import("candidates.zig");
pub const pinyin_engine = @import("pinyin_engine.zig");
pub const imm_bridge = @import("imm_bridge.zig");

// Re-export core types
pub const ImeManager = ime_manager.ImeManager;
pub const InputContext = input_context.InputContext;
pub const CandidateWindow = candidates.CandidateWindow;
pub const PinyinEngine = pinyin_engine.PinyinEngine;
pub const ImmBridge = imm_bridge.ImmBridge;
pub const ImeMode = input_context.ImeMode;
pub const CompositionState = input_context.CompositionState;

/// Global IME manager instance
pub var global_ime_manager: ImeManager = undefined;

/// Initialize the global IME manager
pub fn initIme() void {
    global_ime_manager = ImeManager.init();
}

/// Get the global IME manager
pub fn getImeManager() *ImeManager {
    return &global_ime_manager;
}
