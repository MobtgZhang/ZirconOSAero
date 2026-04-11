//! Explorer Selection Manager - Windows 7 Style Multi-Select Model
//!
//! Implements the Windows 7-style file selection model including single-click select,
//! Ctrl+click multi-select, Shift+click range select, and rubber-band selection.
//! Clean-room implementation based on publicly documented Windows 7 Explorer behavior.

const std = @import("std");
const explorer_state = @import("../shell/explorer_state.zig");

// ── Selection Types ─────────────────────────────────────────────────────────

pub const SelectionMode = enum {
    none,
    single,
    multi,
    range,
    rubberband,
};

pub const SelectionRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

// ── Selection State ─────────────────────────────────────────────────────────

const MAX_SELECTION = 128;

var selection_indices: [MAX_SELECTION]usize = undefined;
var selection_count: usize = 0;
var selection_anchor: usize = 0;
var last_clicked_index: usize = 0;
var selection_mode: SelectionMode = .none;

// Rubber-band selection state
var rubber_band: SelectionRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
var is_rubber_banding: bool = false;

// ── Selection Core Functions ────────────────────────────────────────────────

pub fn clearSelection() void {
    selection_count = 0;
    selection_mode = .none;
}

pub fn isSelected(index: usize) bool {
    for (0..selection_count) |i| {
        if (selection_indices[i] == index) return true;
    }
    return false;
}

pub fn addToSelection(index: usize) void {
    if (selection_count >= MAX_SELECTION) return;
    if (isSelected(index)) return;
    
    selection_indices[selection_count] = index;
    selection_count += 1;
}

pub fn removeFromSelection(index: usize) void {
    var i: usize = 0;
    while (i < selection_count) {
        if (selection_indices[i] == index) {
            // Shift remaining elements
            var j = i;
            while (j < selection_count - 1) : (j += 1) {
                selection_indices[j] = selection_indices[j + 1];
            }
            selection_count -= 1;
            return;
        }
        i += 1;
    }
}

pub fn toggleSelection(index: usize) void {
    if (isSelected(index)) {
        removeFromSelection(index);
    } else {
        addToSelection(index);
    }
}

pub fn selectOnly(index: usize) void {
    clearSelection();
    selection_indices[0] = index;
    selection_count = 1;
    last_clicked_index = index;
    selection_mode = .single;
}

pub fn selectRange(from: usize, to: usize) void {
    const start = @min(from, to);
    const end = @max(from, to);
    
    for (start..end + 1) |i| {
        addToSelection(i);
    }
    selection_mode = .range;
}

pub fn selectAll(total_items: usize) void {
    clearSelection();
    selection_count = @min(total_items, MAX_SELECTION);
    for (0..selection_count) |i| {
        selection_indices[i] = i;
    }
    selection_mode = .multi;
}

pub fn invertSelection(total_items: usize) void {
    var new_selection: [MAX_SELECTION]usize = undefined;
    var new_count: usize = 0;
    
    for (0..total_items) |i| {
        if (!isSelected(i) and new_count < MAX_SELECTION) {
            new_selection[new_count] = i;
            new_count += 1;
        }
    }
    
    for (0..new_count) |i| {
        selection_indices[i] = new_selection[i];
    }
    selection_count = new_count;
}

// ── Selection Query Functions ────────────────────────────────────────────────

pub fn getSelectionCount() usize {
    return selection_count;
}

pub fn getSelectedIndices() []const usize {
    return selection_indices[0..selection_count];
}

pub fn getFirstSelected() ?usize {
    if (selection_count == 0) return null;
    return selection_indices[0];
}

pub fn getLastSelected() ?usize {
    if (selection_count == 0) return null;
    return selection_indices[selection_count - 1];
}

pub fn hasSelection() bool {
    return selection_count > 0;
}

// ── Click Handling ─────────────────────────────────────────────────────────

pub fn handleItemClick(index: usize, ctrl_pressed: bool, shift_pressed: bool) void {
    if (ctrl_pressed) {
        // Toggle individual item
        toggleSelection(index);
        last_clicked_index = index;
        selection_anchor = index;
    } else if (shift_pressed) {
        // Range select from anchor
        selectRange(selection_anchor, index);
    } else {
        // Single select
        selectOnly(index);
    }
}

// ── Rubber-Band Selection ─────────────────────────────────────────────────

pub fn startRubberBand(x: i32, y: i32) void {
    rubber_band = .{ .x = x, .y = y, .w = 0, .h = 0 };
    is_rubber_banding = true;
    selection_mode = .rubberband;
}

pub fn updateRubberBand(x: i32, y: i32) void {
    rubber_band.w = x - rubber_band.x;
    rubber_band.h = y - rubber_band.y;
    
    // Normalize negative dimensions
    if (rubber_band.w < 0) {
        rubber_band.x += rubber_band.w;
        rubber_band.w = -rubber_band.w;
    }
    if (rubber_band.h < 0) {
        rubber_band.y += rubber_band.h;
        rubber_band.h = -rubber_band.h;
    }
}

pub fn endRubberBand() void {
    is_rubber_banding = false;
}

pub fn getRubberBand() SelectionRect {
    return rubber_band;
}

pub fn isRubberBanding() bool {
    return is_rubber_banding;
}

// ── Item Hit Test for Rubber-Band ─────────────────────────────────────────

pub fn isItemInRubberBand(
    item_x: i32,
    item_y: i32,
    item_w: i32,
    item_h: i32,
) bool {
    if (!is_rubber_banding) return false;
    
    // Check if item rect intersects with rubber band
    const rb_left = rubber_band.x;
    const rb_right = rubber_band.x + rubber_band.w;
    const rb_top = rubber_band.y;
    const rb_bottom = rubber_band.y + rubber_band.h;
    
    const it_left = item_x;
    const it_right = item_x + item_w;
    const it_top = item_y;
    const it_bottom = item_y + item_h;
    
    return !(rb_right < it_left or rb_left > it_right or
             rb_bottom < it_top or rb_top > it_bottom);
}

// ── Selection with Rubber-Band ─────────────────────────────────────────────

pub fn selectItemsInRubberBand(
    getItemRect: *const fn (index: usize) SelectionRect,
    total_items: usize,
) void {
    if (!is_rubber_banding) return;
    
    for (0..total_items) |i| {
        const rect = getItemRect(i);
        if (isItemInRubberBand(rect.x, rect.y, rect.w, rect.h)) {
            addToSelection(i);
        }
    }
}

// ── Keyboard Navigation ─────────────────────────────────────────────────────

pub fn navigateSelection(direction: SelectionDirection, total_items: usize, column_count: usize) void {
    if (total_items == 0) return;
    
    const current = last_clicked_index;
    
    var new_index: usize = current;
    
    switch (direction) {
        .up => {
            if (current >= column_count) {
                new_index = current - column_count;
            }
        },
        .down => {
            if (current + column_count < total_items) {
                new_index = current + column_count;
            }
        },
        .left => {
            if (current > 0) {
                new_index = current - 1;
            }
        },
        .right => {
            if (current + 1 < total_items) {
                new_index = current + 1;
            }
        },
        .home => {
            new_index = 0;
        },
        .end => {
            new_index = total_items - 1;
        },
        .page_up => {
            if (current >= column_count * 10) {
                new_index = current - column_count * 10;
            } else {
                new_index = 0;
            }
        },
        .page_down => {
            const new_pos = current + column_count * 10;
            new_index = @min(new_pos, total_items - 1);
        },
    }
    
    if (new_index != current) {
        selectOnly(new_index);
    }
}

pub const SelectionDirection = enum {
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
};

// ── Selection State Query ──────────────────────────────────────────────────

pub fn getSelectionMode() SelectionMode {
    return selection_mode;
}

pub fn getSelectionAnchor() usize {
    return selection_anchor;
}

pub fn setSelectionAnchor(index: usize) void {
    selection_anchor = index;
}
