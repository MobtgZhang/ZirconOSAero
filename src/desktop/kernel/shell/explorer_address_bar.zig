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

//! Explorer Address Bar - Windows 7 Style Breadcrumb Navigation
//!
//! Implements the breadcrumb-style address bar with clickable segments,
//! dropdown history (F4), and path autocomplete.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");
const icons = @import("../icons/root.zig");
const explorer_state = @import("../shell/explorer_state.zig");
const explorer_format = @import("../shell/explorer_format.zig");
const shell_mui = @import("../strings/shell_mui.zig");

const rgb = theme.rgb;

// ── Address Bar Types ───────────────────────────────────────────────────────

pub const AddressBarSegment = struct {
    label: []const u8,
    path: []const u8,
};

const MAX_SEGMENTS = 8;
var addr_segments: [MAX_SEGMENTS]AddressBarSegment = undefined;
var addr_segment_count: usize = 0;

// Address bar editing state
var addr_editing: bool = false;
var addr_edit_buf: [256]u8 = undefined;
var addr_edit_len: usize = 0;
var addr_cursor_pos: usize = 0;

// Address bar dropdown
var addr_dropdown_visible: bool = false;
var addr_dropdown_items: [20][]const u8 = undefined;
var addr_dropdown_count: usize = 0;
var addr_dropdown_hover: i32 = -1;

// Typed path history (F4)
const MAX_TYPED_PATHS = 20;
var typed_path_history: [MAX_TYPED_PATHS][256]u8 = undefined;
var typed_path_count: usize = 0;

// ── Address Bar State ───────────────────────────────────────────────────────

pub fn isAddressBarEditing() bool {
    return addr_editing;
}

pub fn getAddressEditBuffer() []u8 {
    return addr_edit_buf[0..addr_edit_len];
}

pub fn getAddressCursorPos() usize {
    return addr_cursor_pos;
}

pub fn setAddressEditBuffer(buf: []const u8) void {
    @memcpy(addr_edit_buf[0..buf.len], buf);
    addr_edit_len = buf.len;
    addr_cursor_pos = buf.len;
}

pub fn setAddressBarEditing(editing: bool) void {
    addr_editing = editing;
}

pub fn clearAddressEditBuffer() void {
    addr_edit_len = 0;
    addr_cursor_pos = 0;
}

// ── Address Bar Segments ──────────────────────────────────────────────────────

fn buildAddressSegments() void {
    addr_segment_count = 0;
    
    const view = explorer_state.getExplorerView();
    const loc = explorer_state.getExplorerLocation();
    
    switch (view) {
        .libraries => {
            // Libraries root: show "Libraries"
            addr_segments[0] = .{
                .label = shell_mui.loadString(.ex_lib_title, &[_]u8{0} ** 1),
                .path = "",
            };
            addr_segment_count = 1;
        },
        .computer => {
            switch (loc) {
                .libraries_root => {
                    addr_segments[0] = .{
                        .label = shell_mui.loadString(.ex_lib_title, &[_]u8{0} ** 1),
                        .path = "",
                    };
                    addr_segment_count = 1;
                },
                .computer_root => {
                    addr_segments[0] = .{
                        .label = shell_mui.loadString(.ex_addr_computer, &[_]u8{0} ** 1),
                        .path = "",
                    };
                    addr_segment_count = 1;
                },
                .drive_root => |L| {
                    // Drive: Computer > C:
                    addr_segments[0] = .{
                        .label = shell_mui.loadString(.ex_addr_computer, &[_]u8{0} ** 1),
                        .path = "",
                    };
                    var drive_buf: [8]u8 = undefined;
                    const drive_label = explorer_format.formatDriveNavLabel(&drive_buf, L);
                    addr_segments[1] = .{
                        .label = drive_label,
                        .path = explorer_format.formatDriveRootPath(&[_]u8{0} ** 1, L)[0..0],
                    };
                    addr_segment_count = 2;
                    
                    // Add subdirectory segments if navigating in subdirectory
                    if (explorer_state.explorerHasSubdirectory()) {
                        // TODO: Parse subdirectory path and add segments for each level
                    }
                },
            }
        },
    }
}

pub fn getAddressSegments() []AddressBarSegment {
    buildAddressSegments();
    return addr_segments[0..addr_segment_count];
}

// ── Address Bar Dropdown ─────────────────────────────────────────────────────

pub fn showAddressDropdown() void {
    addr_dropdown_visible = true;
    addr_dropdown_hover = -1;
    
    // Populate with typed path history
    addr_dropdown_count = typed_path_count;
    var i: usize = 0;
    while (i < typed_path_count) : (i += 1) {
        addr_dropdown_items[i] = std.mem.sliceTo(&typed_path_history[i], 0);
    }
}

pub fn hideAddressDropdown() void {
    addr_dropdown_visible = false;
    addr_dropdown_hover = -1;
}

pub fn isAddressDropdownVisible() bool {
    return addr_dropdown_visible;
}

pub fn updateAddressDropdownHover(y: i32, dropdown_y: i32, dropdown_h: i32) void {
    if (!addr_dropdown_visible) {
        addr_dropdown_hover = -1;
        return;
    }
    
    const item_h: i32 = 22;
    const rel_y = y - dropdown_y;
    if (rel_y < 0 or rel_y >= dropdown_h) {
        addr_dropdown_hover = -1;
        return;
    }
    
    addr_dropdown_hover = @divTrunc(rel_y, item_h);
    if (addr_dropdown_hover >= @as(i32, @intCast(addr_dropdown_count))) {
        addr_dropdown_hover = -1;
    }
}

pub fn getAddressDropdownHoverItem() ?[]const u8 {
    if (addr_dropdown_hover < 0 or @as(usize, @intCast(addr_dropdown_hover)) >= addr_dropdown_count) {
        return null;
    }
    return addr_dropdown_items[@as(usize, @intCast(addr_dropdown_hover))];
}

pub fn getAddressDropdownItem(index: usize) ?[]const u8 {
    if (index >= addr_dropdown_count) return null;
    return addr_dropdown_items[index];
}

pub fn getAddressDropdownCount() usize {
    return addr_dropdown_count;
}

// ── Typed Path History ───────────────────────────────────────────────────────

pub fn addTypedPathToHistory(path: []const u8) void {
    if (path.len == 0) return;
    
    // Check if already in history
    var i: usize = 0;
    while (i < typed_path_count) : (i += 1) {
        if (std.mem.eql(u8, std.mem.sliceTo(&typed_path_history[i], 0), path)) {
            // Move to front
            var j: usize = i;
            while (j > 0) : (j -= 1) {
                const prev = std.mem.sliceTo(&typed_path_history[j - 1], 0);
                @memcpy(std.mem.sliceTo(&typed_path_history[j], 0), prev);
            }
            @memcpy(std.mem.sliceTo(&typed_path_history[0], 0), path);
            return;
        }
    }
    
    // Add new entry
    if (typed_path_count < MAX_TYPED_PATHS) {
        typed_path_count += 1;
    }
    
    // Shift and add
    var j: usize = typed_path_count - 1;
    while (j > 0) : (j -= 1) {
        const prev = std.mem.sliceTo(&typed_path_history[j - 1], 0);
        @memcpy(std.mem.sliceTo(&typed_path_history[j], 0), prev);
    }
    
    const copy_len = @min(path.len, 255);
    @memcpy(typed_path_history[0][0..copy_len], path[0..copy_len]);
    typed_path_history[0][copy_len] = 0;
}

// ── Address Bar Rendering ────────────────────────────────────────────────────

pub fn renderAddressBarSegments(x: i32, y: i32, w: i32, h: i32) void {
    _ = w;
    buildAddressSegments();
    
    const seg_h: i32 = h;
    var sx: i32 = x;
    
    for (0..addr_segment_count) |i| {
        const seg = addr_segments[i];
        const sw = fb.textWidth(seg.label) + 16;
        
        // Background
        fb.fillRect(sx, y, sw, seg_h, rgb(0xF8, 0xF9, 0xFC));
        
        // Chevron
        if (i < addr_segment_count - 1) {
            fb.drawTextTransparent(sx + sw - 12, y + (seg_h - 14) / 2, "▸", rgb(0x60, 0x60, 0x60));
        }
        
        // Text
        fb.drawTextTransparent(sx + 6, y + (seg_h - 14) / 2, seg.label, rgb(0x00, 0x00, 0x00));
        
        sx += sw;
    }
}

pub fn renderAddressDropdown(x: i32, y: i32, max_w: i32) i32 {
    if (!addr_dropdown_visible or addr_dropdown_count == 0) return 0;
    
    const item_h: i32 = 22;
    const dropdown_h = @as(i32, @intCast(addr_dropdown_count)) * item_h + 8;
    const dropdown_w = max_w;
    
    // Background
    fb.fillRect(x, y, dropdown_w, dropdown_h, rgb(0xFF, 0xFF, 0xFF));
    fb.drawRect(x, y, dropdown_w, dropdown_h, rgb(0xA0, 0xA0, 0xA0));
    
    // Items
    var iy: i32 = y + 4;
    var i: usize = 0;
    while (i < addr_dropdown_count) : (i += 1) {
        const is_hover = (@as(i32, @intCast(i)) == addr_dropdown_hover);
        
        if (is_hover) {
            fb.fillRect(x + 2, iy, dropdown_w - 4, item_h, rgb(0xD8, 0xE8, 0xF8));
        }
        
        fb.drawTextTransparent(x + 8, iy + 4, addr_dropdown_items[i], rgb(0x00, 0x00, 0x00));
        iy += item_h;
    }
    
    return dropdown_h;
}

pub fn renderAddressEditField(x: i32, y: i32, w: i32, h: i32) void {
    // Field background
    fb.fillRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF));
    fb.drawRect(x, y, w, h, rgb(0x9C, 0xA8, 0xB8));
    
    // Text
    if (addr_edit_len > 0) {
        const text = addr_edit_buf[0..addr_edit_len];
        fb.drawTextTransparent(x + 4, y + (h - 14) / 2, text, rgb(0x00, 0x00, 0x00));
        
        // Cursor
        if (addr_editing) {
            const cursor_x = x + 4 + fb.textWidth(text[0..addr_cursor_pos]);
            fb.fillRect(cursor_x, y + 4, 2, h - 8, rgb(0x00, 0x51, 0x9E));
        }
    } else if (!addr_editing) {
        // Placeholder
        const placeholder = "Type path and press Enter...";
        fb.drawTextTransparent(x + 4, y + (h - 14) / 2, placeholder, rgb(0x78, 0x80, 0x88));
    }
}

// ── Address Bar Hit Testing ──────────────────────────────────────────────────

pub fn hitTestAddressSegment(px: i32, py: i32, x: i32, y: i32, h: i32) ?usize {
    if (py < y or py >= y + h) return null;
    
    buildAddressSegments();
    
    var sx: i32 = x;
    for (0..addr_segment_count) |i| {
        const seg = addr_segments[i];
        const sw = fb.textWidth(seg.label) + 16;
        
        if (px >= sx and px < sx + sw) {
            return i;
        }
        sx += sw;
    }
    
    return null;
}

pub fn hitTestAddressDropdown(px: i32, py: i32, x: i32, y: i32, h: i32) bool {
    if (!addr_dropdown_visible) return false;
    return px >= x and px < x + 300 and py >= y and py < y + h;
}
