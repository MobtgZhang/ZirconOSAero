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

//! Explorer View Modes - Windows 7 Style Icon/List/Content Views
//!
//! Implements the various view modes for Windows 7 Explorer: Large Icons, Medium Icons,
//! Small Icons, List, and Content. Clean-room implementation based on publicly
//! documented Windows 7 Explorer behavior.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");
const icons = @import("../icons/root.zig");
const explorer_state = @import("../shell/explorer_state.zig");
const explorer_vol_snap = @import("../../../fs/explorer_volume_snapshot.zig");

const rgb = theme.rgb;

// Type alias for convenience
const ExplorerViewMode = explorer_state.ExplorerViewMode;

pub const ViewItemLayout = struct {
    icon_size: i32,
    label_lines: u8,
    item_width: i32,
    item_height: i32,
    label_offset_y: i32,
};

fn getLayoutForView(mode: ExplorerViewMode) ViewItemLayout {
    return switch (mode) {
        .large_icon => .{
            .icon_size = 96,
            .label_lines = 2,
            .item_width = 96,
            .item_height = 110,
            .label_offset_y = 96,
        },
        .medium_icon => .{
            .icon_size = 48,
            .label_lines = 2,
            .item_width = 96,
            .item_height = 72,
            .label_offset_y = 48,
        },
        .small_icon => .{
            .icon_size = 16,
            .label_lines = 1,
            .item_width = 110,
            .item_height = 20,
            .label_offset_y = 16,
        },
        .list => .{
            .icon_size = 16,
            .label_lines = 1,
            .item_width = 200,
            .item_height = 20,
            .label_offset_y = 16,
        },
        .content => .{
            .icon_size = 48,
            .label_lines = 1,
            .item_width = 200,
            .item_height = 64,
            .label_offset_y = 48,
        },
    };
}

// ── Item Rendering Helpers ─────────────────────────────────────────────────

const MAX_ITEMS_PER_ROW: usize = 50;

fn renderItemIcon(icon: icons.IconId, x: i32, y: i32, size: i32, is_selected: bool) void {
    const scale: f32 = @as(f32, @floatFromInt(size)) / 48.0;
    icons.drawThemedIcon(icon, x, y, scale, .aero, is_selected);
}

fn renderItemLabel(
    x: i32,
    y: i32,
    width: i32,
    name: []const u8,
    subtitle: ?[]const u8,
    mode: ExplorerViewMode,
    is_selected: bool,
    is_focus: bool,
) void {
    const label_h: i32 = switch (mode) {
        .large_icon, .medium_icon => 28,
        else => 16,
    };
    
    const text_color: u32 = if (is_selected)
        rgb(0xFF, 0xFF, 0xFF)
    else
        rgb(0x18, 0x18, 0x18);
    
    // Background for selected item
    if (is_selected) {
        fb.fillRect(x, y - 2, width, label_h + 4, rgb(0x00, 0x51, 0x9E));
    }
    
    // Text shadow for non-selected items
    if (!is_selected) {
        const shadow_x = x + 1;
        const shadow_y = y + 1;
        fb.drawTextTransparent(shadow_x, shadow_y, name, rgb(0xFF, 0xFF, 0xFF));
    }
    
    fb.drawTextTransparent(x, y, name, text_color);
    
    // Subtitle for large/medium icons
    if (subtitle) |sub| {
        fb.drawTextTransparent(x, y + 14, sub, if (is_selected) rgb(0xD0, 0xE0, 0xF0) else rgb(0x60, 0x60, 0x60));
    }
    
    // Focus rectangle
    if (is_focus) {
        fb.drawRect(x - 1, y - 3, width + 2, label_h + 6, rgb(0x00, 0x51, 0x9E));
    }
}

// ── Grid Layout Calculation ───────────────────────────────────────────────

const GridLayout = struct {
    cols: usize,
    item_w: i32,
    item_h: i32,
};

fn calculateGridLayout(_mode: ExplorerViewMode, content_width: i32) GridLayout {
    const layout = getLayoutForView(_mode);
    
    const cols = switch (_mode) {
        .large_icon, .medium_icon, .content => @as(usize, @intCast(@max(1, content_width / layout.item_width))),
        .small_icon, .list => 1,
    };
    
    return .{
        .cols = cols,
        .item_w = layout.item_width,
        .item_h = layout.item_height,
    };
}

// ── Large Icons View ─────────────────────────────────────────────────────

const LARGE_ICON_SIZE: i32 = 96;
const LARGE_ITEM_W: i32 = 96;
const LARGE_ITEM_H: i32 = 110;

pub fn renderLargeIconsView(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    entries: []const explorer_vol_snap.ExplorerListEntry,
    selected_indices: []const usize,
    focus_index: usize,
    scroll_offset: i32,
) void {
    const cols = @as(usize, @intCast(@max(1, width / LARGE_ITEM_W)));
    const padding_x: i32 = 16;
    const padding_y: i32 = 16;
    const item_y = y + padding_y - scroll_offset;
    var item_idx: usize = 0;
    
    while (item_idx < entries.len) {
        const entry = entries[item_idx];
        const row: usize = item_idx / cols;
        const col: usize = item_idx % cols;
        
        const item_x = x + padding_x + @as(i32, @intCast(col)) * LARGE_ITEM_W;
        const iy = item_y + @as(i32, @intCast(row)) * LARGE_ITEM_H;
        
        if (iy + LARGE_ITEM_H < y) {
            item_idx += 1;
            continue;
        }
        if (iy > y + height) break;
        
        const is_selected = for (selected_indices) |si| {
            if (si == item_idx) break true;
        } else false;
        const is_focus = item_idx == focus_index;
        
        // Icon
        const icon_x = item_x + (LARGE_ITEM_W - LARGE_ICON_SIZE) / 2;
        const icon_y = iy + 4;
        renderItemIcon(entry.icon, icon_x, icon_y, LARGE_ICON_SIZE, is_selected);
        
        // Label background for selected item
        const label_y = iy + LARGE_ICON_SIZE + 4;
        renderItemLabel(
            item_x + 4,
            label_y,
            LARGE_ITEM_W - 8,
            entry.name[0..entry.name_len],
            null,
            .large_icon,
            is_selected,
            is_focus,
        );
        
        item_idx += 1;
    }
}

// ── Medium Icons View ────────────────────────────────────────────────────

const MED_ICON_SIZE: i32 = 48;
const MED_ITEM_W: i32 = 96;
const MED_ITEM_H: i32 = 72;

pub fn renderMediumIconsView(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    entries: []const explorer_vol_snap.ExplorerListEntry,
    selected_indices: []const usize,
    focus_index: usize,
    scroll_offset: i32,
) void {
    const cols = @as(usize, @intCast(@max(1, width / MED_ITEM_W)));
    const padding_x: i32 = 16;
    const padding_y: i32 = 16;
    
    var item_idx: usize = 0;
    
    while (item_idx < entries.len) {
        const entry = entries[item_idx];
        const row: usize = item_idx / cols;
        const col: usize = item_idx % cols;
        
        const item_x = x + padding_x + @as(i32, @intCast(col)) * MED_ITEM_W;
        const iy = y + padding_y + @as(i32, @intCast(row)) * MED_ITEM_H - scroll_offset;
        
        if (iy + MED_ITEM_H < y) {
            item_idx += 1;
            continue;
        }
        if (iy > y + height) break;
        
        const is_selected = for (selected_indices) |si| {
            if (si == item_idx) break true;
        } else false;
        const is_focus = item_idx == focus_index;
        
        // Icon
        const icon_x = item_x + (MED_ITEM_W - MED_ICON_SIZE) / 2;
        const icon_y = iy + 4;
        renderItemIcon(entry.icon, icon_x, icon_y, MED_ICON_SIZE, is_selected);
        
        // Label
        const label_y = iy + MED_ICON_SIZE + 4;
        renderItemLabel(
            item_x + 4,
            label_y,
            MED_ITEM_W - 8,
            entry.name[0..entry.name_len],
            null,
            .medium_icon,
            is_selected,
            is_focus,
        );
        
        item_idx += 1;
    }
}

// ── Small Icons View ──────────────────────────────────────────────────────

const SMALL_ICON_SIZE: i32 = 16;
const SMALL_ITEM_W: i32 = 200;
const SMALL_ITEM_H: i32 = 20;

pub fn renderSmallIconsView(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    entries: []const explorer_vol_snap.ExplorerListEntry,
    selected_indices: []const usize,
    focus_index: usize,
    scroll_offset: i32,
) void {
    const padding_x: i32 = 8;
    const padding_y: i32 = 4;
    
    for (entries, 0..) |entry, idx| {
        const iy = y + padding_y + @as(i32, @intCast(idx)) * SMALL_ITEM_H - scroll_offset;
        
        if (iy + SMALL_ITEM_H < y) continue;
        if (iy > y + height) break;
        
        const is_selected = for (selected_indices) |si| {
            if (si == idx) break true;
        } else false;
        const is_focus = idx == focus_index;
        
        const item_x = x + padding_x;
        
        // Selection background
        if (is_selected) {
            fb.fillRect(x, iy, width, SMALL_ITEM_H, rgb(0xC8, 0xE0, 0xF0));
        }
        
        // Icon
        renderItemIcon(entry.icon, item_x, iy + 2, SMALL_ICON_SIZE, is_selected);
        
        // Label
        renderItemLabel(
            item_x + SMALL_ICON_SIZE + 4,
            iy + 2,
            SMALL_ITEM_W - SMALL_ICON_SIZE - 8,
            entry.name[0..entry.name_len],
            null,
            .small_icon,
            is_selected,
            is_focus,
        );
    }
}

// ── List View ─────────────────────────────────────────────────────────────

const LIST_ICON_SIZE: i32 = 16;
const LIST_ITEM_W: i32 = 250;
const LIST_ITEM_H: i32 = 20;

pub fn renderListView(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    entries: []const explorer_vol_snap.ExplorerListEntry,
    selected_indices: []const usize,
    focus_index: usize,
    scroll_offset: i32,
) void {
    const padding_x: i32 = 8;
    const padding_y: i32 = 4;
    
    // Column header
    fb.fillRect(x, y, width, 20, rgb(0xEE, 0xEE, 0xEE));
    fb.drawTextTransparent(x + padding_x + LIST_ICON_SIZE + 4, y + 3, "Name", rgb(0x18, 0x18, 0x18));
    fb.drawHLine(x, y + 20, width, rgb(0xAA, 0xAA, 0xAA));
    
    for (entries, 0..) |entry, idx| {
        const iy = y + 20 + padding_y + @as(i32, @intCast(idx)) * LIST_ITEM_H - scroll_offset;
        
        if (iy + LIST_ITEM_H < y + 20) continue;
        if (iy > y + height) break;
        
        const is_selected = for (selected_indices) |si| {
            if (si == idx) break true;
        } else false;
        const is_focus = idx == focus_index;
        
        // Alternating background
        if (idx % 2 == 1 and !is_selected) {
            fb.fillRect(x, iy, width, LIST_ITEM_H, rgb(0xF8, 0xF8, 0xFA));
        }
        
        // Selection background
        if (is_selected) {
            fb.fillRect(x, iy, width, LIST_ITEM_H, rgb(0xC8, 0xE0, 0xF0));
        }
        
        // Icon
        renderItemIcon(entry.icon, x + padding_x, iy + 2, LIST_ICON_SIZE, is_selected);
        
        // Label
        renderItemLabel(
            x + padding_x + LIST_ICON_SIZE + 4,
            iy + 2,
            LIST_ITEM_W - LIST_ICON_SIZE - 8,
            entry.name[0..entry.name_len],
            null,
            .list,
            is_selected,
            is_focus,
        );
        
        // Separator
        fb.drawHLine(x, iy + LIST_ITEM_H, width, rgb(0xDD, 0xDD, 0xDD));
    }
}

// ── Content View ──────────────────────────────────────────────────────────

const CONTENT_ICON_SIZE: i32 = 48;
const CONTENT_ITEM_W: i32 = 220;
const CONTENT_ITEM_H: i32 = 64;

pub fn renderContentView(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    entries: []const explorer_vol_snap.ExplorerListEntry,
    selected_indices: []const usize,
    focus_index: usize,
    scroll_offset: i32,
) void {
    const cols = @as(usize, @intCast(@max(1, width / CONTENT_ITEM_W)));
    const padding_x: i32 = 16;
    const padding_y: i32 = 16;
    
    for (entries, 0..) |entry, idx| {
        const row: usize = idx / cols;
        const col: usize = idx % cols;
        
        const item_x = x + padding_x + @as(i32, @intCast(col)) * CONTENT_ITEM_W;
        const iy = y + padding_y + @as(i32, @intCast(row)) * CONTENT_ITEM_H - scroll_offset;
        
        if (iy + CONTENT_ITEM_H < y) continue;
        if (iy > y + height) break;
        
        const is_selected = for (selected_indices) |si| {
            if (si == idx) break true;
        } else false;
        const is_focus = idx == focus_index;
        
        // Selection background
        if (is_selected) {
            fb.fillRect(item_x, iy, CONTENT_ITEM_W, CONTENT_ITEM_H, rgb(0xC8, 0xE0, 0xF0));
        }
        
        // Icon
        const icon_x = item_x + 8;
        const icon_y = iy + (CONTENT_ITEM_H - CONTENT_ICON_SIZE) / 2;
        renderItemIcon(entry.icon, icon_x, icon_y, CONTENT_ICON_SIZE, is_selected);
        
        // Label + info below icon
        const label_x = item_x + CONTENT_ICON_SIZE + 16;
        const label_y = iy + 8;
        
        renderItemLabel(
            label_x,
            label_y,
            CONTENT_ITEM_W - CONTENT_ICON_SIZE - 24,
            entry.name[0..entry.name_len],
            null,
            .content,
            is_selected,
            is_focus,
        );
        
        // Size/type info
        if (!entry.is_directory) {
            const info_y = iy + 40;
            fb.drawTextTransparent(label_x, info_y, entry.size[0..entry.size_len], if (is_selected) rgb(0xD0, 0xE0, 0xF0) else rgb(0x60, 0x60, 0x60));
        }
    }
}

// ── Unified View Dispatcher ───────────────────────────────────────────────

pub fn renderExplorerItemsByViewMode(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    entries: []const explorer_vol_snap.ExplorerListEntry,
    selected_indices: []const usize,
    focus_index: usize,
    scroll_offset: i32,
    mode: ExplorerViewMode,
) void {
    switch (mode) {
        .large_icon => renderLargeIconsView(x, y, width, height, entries, selected_indices, focus_index, scroll_offset),
        .medium_icon => renderMediumIconsView(x, y, width, height, entries, selected_indices, focus_index, scroll_offset),
        .small_icon => renderSmallIconsView(x, y, width, height, entries, selected_indices, focus_index, scroll_offset),
        .list => renderListView(x, y, width, height, entries, selected_indices, focus_index, scroll_offset),
        .content => renderContentView(x, y, width, height, entries, selected_indices, focus_index, scroll_offset),
    }
}

// ── Item Hit Testing ───────────────────────────────────────────────────────

pub fn hitTestIconView(
    px: i32,
    py: i32,
    mode: ExplorerViewMode,
    content_x: i32,
    content_y: i32,
    content_width: i32,
    content_height: i32,
    scroll_offset: i32,
    item_count: usize,
) ?usize {
    if (px < content_x or px >= content_x + content_width) return null;
    if (py < content_y or py >= content_y + content_height) return null;
    
    const layout = getLayoutForView(mode);
    
    switch (mode) {
        .large_icon, .medium_icon, .content => {
            const padding_x: i32 = 16;
            const padding_y: i32 = 16;
            const col = @as(i32, @intCast((px - content_x - padding_x) / layout.item_width));
            const row = @as(i32, @intCast((py - content_y - padding_y + scroll_offset) / layout.item_height));
            
            if (col < 0 or row < 0) return null;
            
            const idx = @as(i32, @intCast(row)) * @as(i32, @intCast(@max(1, content_width / layout.item_width))) + col;
            if (idx >= 0 and @as(usize, @intCast(idx)) < item_count) {
                return @as(usize, @intCast(idx));
            }
        },
        .small_icon, .list => {
            const padding_y: i32 = 4;
            const row = @as(i32, @intCast((py - content_y - padding_y + scroll_offset) / layout.item_height));
            if (row >= 0 and @as(usize, @intCast(row)) < item_count) {
                return @as(usize, @intCast(row));
            }
        },
    }
    
    return null;
}

// ── Scroll Calculation ─────────────────────────────────────────────────────

pub fn calculateTotalHeight(mode: ExplorerViewMode, item_count: usize, content_width: i32) i32 {
    const layout = getLayoutForView(mode);
    
    switch (mode) {
        .large_icon, .medium_icon, .content => {
            const cols = @as(usize, @intCast(@max(1, content_width / layout.item_width)));
            const rows = (item_count + cols - 1) / cols;
            const padding: i32 = 32;
            return @as(i32, @intCast(rows)) * layout.item_height + padding;
        },
        .small_icon, .list => {
            return 4 + @as(i32, @intCast(item_count)) * layout.item_height + 4;
        },
    }
}
