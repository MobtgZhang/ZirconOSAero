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

//! Explorer File Operations - Windows 7 Style Drag-Drop, Copy, Move, Rename
//!
//! Implements the Windows 7-style file operations including drag-and-drop,
//! clipboard-based copy/move, and inline rename. Clean-room implementation based on
//! publicly documented Windows 7 Explorer behavior.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");
const icons = @import("../icons/root.zig");
const explorer_state = @import("../shell/explorer_state.zig");
const builtin_apps = @import("builtin_apps.zig");
const vfs = @import("../../../fs/vfs.zig");
const klog = @import("../../../rtl/klog.zig");
const rgb = theme.rgb;

// ── File Operation Types ─────────────────────────────────────────────────────

pub const FileOperation = enum {
    none,
    copy,
    move,
    link,
};

pub const DragState = enum {
    none,
    dragging,
    drop_pending,
};

pub const DropEffect = enum {
    none,
    copy,
    move,
    link,
    cancel,
};

// ── Drag State ────────────────────────────────────────────────────────────────

var current_drag_state: DragState = .none;
var drag_operation: FileOperation = .none;
var drag_source_indices: [32]usize = undefined;
var drag_source_count: usize = 0;
var drag_ghost_x: i32 = 0;
var drag_ghost_y: i32 = 0;
var drag_ghost_icon: icons.IconId = .folder;
var drag_over_target: ?usize = null;
var drop_effect: DropEffect = .none;

// Drag feedback
var show_drop_indicator: bool = false;
var drop_indicator_x: i32 = 0;
var drop_indicator_y: i32 = 0;
var drop_indicator_h: i32 = 0;

// ── Rename State ─────────────────────────────────────────────────────────────

var rename_active: bool = false;
var rename_index: usize = 0;
var rename_text: [256]u8 = undefined;
var rename_len: usize = 0;
var rename_cursor_pos: usize = 0;
var rename_old_name_buf: [256]u8 = undefined;
var rename_old_name_len: usize = 0;

// ── Clipboard Operations ─────────────────────────────────────────────────────

var clipboard_operation: FileOperation = .none;
var clipboard_source: [32]u8 = undefined;
var clipboard_source_len: usize = 0;

// ── Drag Start ──────────────────────────────────────────────────────────────

pub fn startDrag(
    operation: FileOperation,
    source_indices: []const usize,
    icon: icons.IconId,
    start_x: i32,
    start_y: i32,
) void {
    current_drag_state = .dragging;
    drag_operation = operation;

    drag_source_count = @min(source_indices.len, drag_source_indices.len);
    for (0..drag_source_count) |i| {
        drag_source_indices[i] = source_indices[i];
    }

    drag_ghost_icon = icon;
    drag_ghost_x = start_x;
    drag_ghost_y = start_y;
    show_drop_indicator = false;
}

pub fn updateDrag(x: i32, y: i32) void {
    if (current_drag_state != .dragging) return;
    drag_ghost_x = x;
    drag_ghost_y = y;
}

pub fn setDragTarget(target_idx: ?usize) void {
    drag_over_target = target_idx;
    if (target_idx) |_| {
        show_drop_indicator = true;
    } else {
        show_drop_indicator = false;
    }
}

pub fn endDrag(_drop_x: i32, _drop_y: i32) DropEffect {
    _ = _drop_x;
    _ = _drop_y;
    const result = if (drag_over_target != null) drop_effect else .cancel;

    current_drag_state = .none;
    show_drop_indicator = false;
    drag_over_target = null;

    return result;
}

pub fn cancelDrag() void {
    current_drag_state = .none;
    show_drop_indicator = false;
    drag_over_target = null;
    drop_effect = .cancel;
}

// ── Drag Rendering ───────────────────────────────────────────────────────────

const GHOST_OFFSET_X: i32 = 4;
const GHOST_OFFSET_Y: i32 = 4;

pub fn renderDragGhost(x: i32, y: i32) void {
    if (current_drag_state != .dragging) return;

    // Semi-transparent ghost at cursor position
    const ghost_x = x - GHOST_OFFSET_X;
    const ghost_y = y - GHOST_OFFSET_Y;

    // Draw ghost icon with transparency effect
    icons.drawThemedIcon(drag_ghost_icon, ghost_x, ghost_y, 1, .aero, false);

    // Cursor indicator based on operation
    const cursor_text = switch (drag_operation) {
        .copy => "+",
        .move => "",
        .link => "⤷",
        else => "",
    };

    if (cursor_text.len > 0) {
        fb.drawTextTransparent(x + 8, y - 8, cursor_text, rgb(0x00, 0x51, 0x9E));
    }
}

pub fn renderDropIndicator(x: i32, y: i32, h: i32) void {
    if (!show_drop_indicator) return;

    // Blue line indicator
    fb.drawRect(x + 2, y, 50, h, rgb(0x00, 0x51, 0x9E));
    fb.fillRect(x + 4, y, 48, h - 1, rgb(0x00, 0x51, 0x9E));

    drop_indicator_x = x;
    drop_indicator_y = y;
    drop_indicator_h = h;
}

// ── Drop Target Feedback ─────────────────────────────────────────────────────

pub fn highlightDropTarget(_target_idx: usize, highlight: bool) void {
    _ = _target_idx;
    if (highlight) {
        drop_effect = switch (drag_operation) {
            .copy => .copy,
            .move => .move,
            .link => .link,
            else => .none,
        };
    }
}

// ── Rename Operations ────────────────────────────────────────────────────────

pub fn startRename(item_index: usize, old_name: []const u8) void {
    rename_active = true;
    rename_index = item_index;

    const len = @min(old_name.len, rename_text.len);
    @memcpy(rename_text[0..len], old_name[0..len]);
    rename_len = len;
    rename_cursor_pos = len;

    const old_len = @min(old_name.len, rename_old_name_buf.len);
    @memcpy(rename_old_name_buf[0..old_len], old_name[0..old_len]);
    rename_old_name_len = old_len;
}

pub fn isRenameActive() bool {
    return rename_active;
}

pub fn getRenameIndex() usize {
    return rename_index;
}

pub fn getRenameText() []const u8 {
    return rename_text[0..rename_len];
}

pub fn appendRenameChar(c: u8) void {
    if (rename_len >= rename_text.len) return;
    rename_text[rename_len] = c;
    rename_len += 1;
    rename_cursor_pos = rename_len;
}

pub fn deleteRenameChar() void {
    if (rename_len == 0) return;
    rename_len -= 1;
    if (rename_cursor_pos > rename_len) {
        rename_cursor_pos = rename_len;
    }
}

pub fn setRenameCursorPos(pos: usize) void {
    rename_cursor_pos = @min(pos, rename_len);
}

pub fn commitRename() bool {
    if (!rename_active) return false;

    // Validate the new name
    if (rename_len == 0) {
        cancelRename();
        return false;
    }

    // TODO: Call VFS rename operation
    // const success = vfs.rename(rename_old_name_buf[0..rename_old_name_len], rename_text[0..rename_len]);

    rename_active = false;
    return true;
}

pub fn cancelRename() void {
    rename_active = false;
}

// ── Rename Rendering ─────────────────────────────────────────────────────────

pub fn renderRenameOverlay(
    x: i32,
    y: i32,
    w: i32,
    h: i32,
) void {
    if (!rename_active) return;

    // Background
    fb.fillRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF));
    fb.drawRect(x, y, w, h, rgb(0x00, 0x51, 0x9E));

    // Text
    const text_x = x + 4;
    const text_y = y + (h - 14) / 2;
    fb.drawTextTransparent(text_x, text_y, rename_text[0..rename_len], rgb(0x18, 0x18, 0x18));

    // Cursor
    const cursor_x = text_x + fb.textWidth(rename_text[0..rename_cursor_pos]);
    fb.fillRect(cursor_x, y + 2, 2, h - 4, rgb(0x00, 0x51, 0x9E));
}

// ── Clipboard Operations ─────────────────────────────────────────────────────

pub fn copyToClipboard(paths: []const []const u8) void {
    clipboard_operation = .copy;
    // Store paths in clipboard buffer
    var offset: usize = 0;
    for (paths) |path| {
        if (offset + path.len + 1 < clipboard_source.len) {
            @memcpy(clipboard_source[offset..][0..path.len], path);
            offset += path.len;
            clipboard_source[offset] = 0;
            offset += 1;
        }
    }
    clipboard_source_len = offset;
}

pub fn cutToClipboard(paths: []const []const u8) void {
    clipboard_operation = .move;
    copyToClipboard(paths);
}

pub fn getClipboardOperation() FileOperation {
    return clipboard_operation;
}

pub fn hasClipboardContent() bool {
    return clipboard_source_len > 0;
}

pub fn clearClipboard() void {
    clipboard_operation = .none;
    clipboard_source_len = 0;
}

// ── File Delete Operations ───────────────────────────────────────────────────

pub fn moveToRecycleBin(indices: []const usize) bool {
    // TODO: Implement move to recycle bin
    _ = indices;
    return true;
}

pub fn permanentDelete(indices: []const usize) bool {
    // TODO: Implement permanent delete
    _ = indices;
    return true;
}

// ── New Folder Creation ──────────────────────────────────────────────────────

pub fn createNewFolder() void {
    // TODO: Create "New Folder" at current location
    // Default name should be selected for immediate rename
}

// ── Query Functions ──────────────────────────────────────────────────────────

pub fn getDragState() DragState {
    return current_drag_state;
}

pub fn isDragging() bool {
    return current_drag_state == .dragging;
}

pub fn getDragOperation() FileOperation {
    return drag_operation;
}

pub fn getDragSourceCount() usize {
    return drag_source_count;
}

pub fn getDragSourceIndices() []const usize {
    return drag_source_indices[0..drag_source_count];
}
