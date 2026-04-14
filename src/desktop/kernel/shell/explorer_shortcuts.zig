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

//! Explorer Keyboard Shortcuts - Windows 7 Style
//!
//! Implements the Windows 7-style keyboard shortcuts for the explorer.
//! Clean-room implementation based on publicly documented Windows 7 Explorer behavior.

const explorer_state = @import("../shell/explorer_state.zig");
const explorer_selection = @import("../shell/explorer_selection.zig");
const explorer_search = @import("../shell/explorer_search.zig");
const explorer_panes = @import("../shell/explorer_panes.zig");
const explorer_file_ops = @import("../shell/explorer_file_ops.zig");
const explorer_command_bar = @import("../shell/explorer_command_bar.zig");

// ── Key Codes ────────────────────────────────────────────────────────────────

pub const VirtualKey = enum(u8) {
    vk_back = 0x08,
    vk_tab = 0x09,
    vk_return = 0x0D,
    vk_shift = 0x10,
    vk_control = 0x11,
    vk_alt = 0x12,
    vk_escape = 0x1B,
    vk_space = 0x20,
    vk_page_up = 0x21,
    vk_page_down = 0x22,
    vk_end = 0x23,
    vk_home = 0x24,
    vk_left = 0x25,
    vk_up = 0x26,
    vk_right = 0x27,
    vk_down = 0x28,
    vk_delete = 0x2E,
    vk_f2 = 0x71,
    vk_f5 = 0x74,
    vk_a = 0x41,
    vk_c = 0x43,
    vk_v = 0x56,
    vk_x = 0x58,
    vk_n = 0x4E,
};

// ── Modifier State ────────────────────────────────────────────────────────────

var ctrl_pressed: bool = false;
var shift_pressed: bool = false;
var alt_pressed: bool = false;

pub fn setCtrlPressed(pressed: bool) void {
    ctrl_pressed = pressed;
}

pub fn setShiftPressed(pressed: bool) void {
    shift_pressed = pressed;
}

pub fn setAltPressed(pressed: bool) void {
    alt_pressed = pressed;
}

pub fn isCtrlPressed() bool {
    return ctrl_pressed;
}

pub fn isShiftPressed() bool {
    return shift_pressed;
}

pub fn isAltPressed() bool {
    return alt_pressed;
}

// ── Key Action Result ─────────────────────────────────────────────────────────

pub const KeyAction = enum {
    handled,
    unhandled,
    handled_with_refresh,
};

// ── Key Handler ──────────────────────────────────────────────────────────────

pub fn handleExplorerKey(key: VirtualKey, total_items: usize, column_count: usize) KeyAction {
    if (ctrl_pressed) {
        return handleCtrlKey(key, total_items, column_count);
    }
    if (shift_pressed) {
        return handleShiftKey(key, total_items);
    }
    if (alt_pressed) {
        return handleAltKey(key);
    }
    
    return handlePlainKey(key, total_items, column_count);
}

fn handleCtrlKey(key: VirtualKey, total_items: usize, _column_count: usize) KeyAction {
    _ = _column_count;
    switch (key) {
        .vk_a => {
            // Ctrl+A: Select all
            explorer_selection.selectAll(total_items);
            return .handled;
        },
        .vk_c => {
            // Ctrl+C: Copy
            // TODO: Implement copy to clipboard
            return .handled;
        },
        .vk_v => {
            // Ctrl+V: Paste
            // TODO: Implement paste from clipboard
            return .handled;
        },
        .vk_x => {
            // Ctrl+X: Cut
            // TODO: Implement cut to clipboard
            return .handled;
        },
        .vk_n => {
            // Ctrl+Shift+N: New folder
            if (shift_pressed) {
                // TODO: Create new folder
                return .handled;
            }
            return .unhandled;
        },
        else => return .unhandled,
    }
}

fn handleShiftKey(key: VirtualKey, _total_items: usize) KeyAction {
    _ = _total_items;
    switch (key) {
        .vk_n => {
            // Ctrl+Shift+N: New folder
            if (ctrl_pressed) {
                // TODO: Create new folder
                return .handled;
            }
            return .unhandled;
        },
        .vk_delete => {
            // Shift+Delete: Permanent delete
            // TODO: Confirm and delete
            return .handled;
        },
        else => return .unhandled,
    }
}

fn handleAltKey(key: VirtualKey) KeyAction {
    switch (key) {
        .vk_left => {
            // Alt+Left: Back
            if (explorer_state.explorerCanNavigateBack()) {
                explorer_state.explorerNavigateBack();
                return .handled_with_refresh;
            }
            return .handled;
        },
        .vk_right => {
            // Alt+Right: Forward
            if (explorer_state.explorerCanNavigateForward()) {
                explorer_state.explorerNavigateForward();
                return .handled_with_refresh;
            }
            return .handled;
        },
        .vk_up => {
            // Alt+Up: Navigate up
            if (explorer_state.explorerCanNavigateUp()) {
                explorer_state.explorerNavigateUp();
                return .handled_with_refresh;
            }
            return .handled;
        },
        else => return .unhandled,
    }
}

fn handlePlainKey(key: VirtualKey, total_items: usize, column_count: usize) KeyAction {
    switch (key) {
        .vk_back => {
            // Backspace: Navigate back
            if (explorer_state.explorerCanNavigateBack()) {
                explorer_state.explorerNavigateBack();
                return .handled_with_refresh;
            }
            return .handled;
        },
        .vk_delete => {
            // Delete: Move to recycle bin
            // TODO: Implement delete to recycle bin
            return .handled;
        },
        .vk_f2 => {
            // F2: Rename
            // TODO: Start inline rename for selected item
            return .handled;
        },
        .vk_f5 => {
            // F5: Refresh
            return .handled_with_refresh;
        },
        .vk_escape => {
            // Escape: Clear search / deselect
            if (explorer_search.isSearchActive()) {
                explorer_search.clearSearch();
                return .handled;
            }
            if (explorer_selection.hasSelection()) {
                explorer_selection.clearSelection();
                return .handled;
            }
            return .unhandled;
        },
        .vk_space => {
            // Space: Toggle selection of focused item
            const focused = explorer_selection.getSelectionCount();
            if (focused > 0) {
                // Toggle focused item
                return .handled;
            }
            return .unhandled;
        },
        .vk_up, .vk_down, .vk_left, .vk_right,
        .vk_home, .vk_end, .vk_page_up, .vk_page_down => {
            // Arrow keys: Navigate selection
            const direction = keyToDirection(key);
            if (direction) |dir| {
                explorer_selection.navigateSelection(dir, total_items, column_count);
                return .handled;
            }
            return .unhandled;
        },
        else => return .unhandled,
    }
}

fn keyToDirection(key: VirtualKey) ?explorer_selection.SelectionDirection {
    switch (key) {
        .vk_up => return .up,
        .vk_down => return .down,
        .vk_left => return .left,
        .vk_right => return .right,
        .vk_home => return .home,
        .vk_end => return .end,
        .vk_page_up => return .page_up,
        .vk_page_down => return .page_down,
        else => return null,
    }
}

// ── Navigation Shortcuts ──────────────────────────────────────────────────────

pub fn handleNavigationKey(key: VirtualKey) KeyAction {
    switch (key) {
        .vk_back => {
            if (explorer_state.explorerCanNavigateBack()) {
                explorer_state.explorerNavigateBack();
                return .handled_with_refresh;
            }
        },
        .vk_left => {
            if (alt_pressed and explorer_state.explorerCanNavigateBack()) {
                explorer_state.explorerNavigateBack();
                return .handled_with_refresh;
            }
        },
        .vk_right => {
            if (alt_pressed and explorer_state.explorerCanNavigateForward()) {
                explorer_state.explorerNavigateForward();
                return .handled_with_refresh;
            }
        },
        .vk_up => {
            if (alt_pressed and explorer_state.explorerCanNavigateUp()) {
                explorer_state.explorerNavigateUp();
                return .handled_with_refresh;
            }
        },
        else => {},
    }
    return .unhandled;
}

// ── Search Shortcuts ─────────────────────────────────────────────────────────

pub fn handleSearchKey(key: VirtualKey) KeyAction {
    switch (key) {
        .vk_f3 => {
            // F3: Focus search box
            explorer_search.setSearchFocused(true);
            return .handled;
        },
        .vk_escape => {
            if (explorer_search.isSearchFocused()) {
                explorer_search.clearSearch();
                explorer_search.setSearchFocused(false);
                return .handled;
            }
        },
        else => {},
    }
    return .unhandled;
}

// ── View Shortcuts ───────────────────────────────────────────────────────────

pub fn handleViewKey(key: VirtualKey) KeyAction {
    switch (key) {
        .vk_1 => {
            // Ctrl+Shift+1: Extra large icons
            explorer_state.setExplorerViewMode(.large_icon);
            return .handled;
        },
        .vk_2 => {
            // Ctrl+Shift+2: Large icons
            explorer_state.setExplorerViewMode(.large_icon);
            return .handled;
        },
        .vk_3 => {
            // Ctrl+Shift+3: Medium icons
            explorer_state.setExplorerViewMode(.medium_icon);
            return .handled;
        },
        .vk_4 => {
            // Ctrl+Shift+4: Small icons
            explorer_state.setExplorerViewMode(.small_icon);
            return .handled;
        },
        .vk_5 => {
            // Ctrl+Shift+5: List
            explorer_state.setExplorerViewMode(.list);
            return .handled;
        },
        .vk_6 => {
            // Ctrl+Shift+6: Details
            explorer_state.setExplorerViewMode(.details);
            return .handled;
        },
        else => {},
    }
    return .unhandled;
}

// ── Pane Shortcuts ───────────────────────────────────────────────────────────

pub fn handlePaneKey(key: VirtualKey) KeyAction {
    switch (key) {
        .vk_p => {
            // Alt+P: Toggle preview pane
            if (alt_pressed) {
                explorer_panes.togglePreviewPane();
                return .handled;
            }
        },
        else => {},
    }
    return .unhandled;
}
