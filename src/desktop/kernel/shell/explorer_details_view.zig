//! Explorer Details View - Windows 7 Style Column View
//!
//! Implements the Details View with sortable column headers, grouping support,
//! and information-dense listing. Clean-room implementation based on publicly
//! documented Windows 7 Explorer behavior.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");
const icons = @import("../icons/root.zig");
const explorer_state = @import("../shell/explorer_state.zig");
const explorer_format = @import("../shell/explorer_format.zig");
const explorer_vol_snap = @import("../../../fs/explorer_volume_snapshot.zig");

const rgb = theme.rgb;

// ── Detail Column Types ─────────────────────────────────────────────────────

pub const DetailColumnKind = enum(u8) {
    name,
    size,
    item_type,
    date_modified,
    date_created,
    attributes,
    author,
    title,
    tags,
    folder_path,
};

pub const DetailColumn = struct {
    kind: DetailColumnKind,
    label: []const u8,
    width: i32,
    min_width: i32,
    sort_order: u2,
};

pub const DetailSortOrder = enum {
    none,
    ascending,
    descending,
};

// Column definitions
var detail_columns: [10]DetailColumn = undefined;
var detail_column_count: usize = 0;

// Sorting state
var sort_column: DetailColumnKind = .name;
var sort_ascending: bool = true;
var grouping_enabled: bool = false;
var group_field: DetailColumnKind = .item_type;

// Header interaction state
var header_hover_col: i32 = -1;
var header_resizing: bool = false;
var resize_col: i32 = -1;
var resize_start_x: i32 = 0;
var resize_start_width: i32 = 0;

// Column default widths
const COL_NAME: i32 = 220;
const COL_SIZE: i32 = 80;
const COL_TYPE: i32 = 120;
const COL_DATE: i32 = 140;
const COL_CREATED: i32 = 140;
const COL_ATTR: i32 = 80;
const COL_AUTHOR: i32 = 100;
const COL_TITLE: i32 = 100;
const COL_TAGS: i32 = 80;
const COL_PATH: i32 = 200;

// ── Column Initialization ───────────────────────────────────────────────────

pub fn initDetailColumns() void {
    detail_column_count = 0;
    
    detail_columns[detail_column_count] = .{
        .kind = .name,
        .label = "Name",
        .width = COL_NAME,
        .min_width = 100,
        .sort_order = 0,
    };
    detail_column_count += 1;
    
    detail_columns[detail_column_count] = .{
        .kind = .size,
        .label = "Size",
        .width = COL_SIZE,
        .min_width = 50,
        .sort_order = 0,
    };
    detail_column_count += 1;
    
    detail_columns[detail_column_count] = .{
        .kind = .item_type,
        .label = "Item type",
        .width = COL_TYPE,
        .min_width = 80,
        .sort_order = 0,
    };
    detail_column_count += 1;
    
    detail_columns[detail_column_count] = .{
        .kind = .date_modified,
        .label = "Date modified",
        .width = COL_DATE,
        .min_width = 100,
        .sort_order = 0,
    };
    detail_column_count += 1;
    
    detail_columns[detail_column_count] = .{
        .kind = .date_created,
        .label = "Date created",
        .width = COL_CREATED,
        .min_width = 100,
        .sort_order = 0,
    };
    detail_column_count += 1;
    
    detail_columns[detail_column_count] = .{
        .kind = .attributes,
        .label = "Attributes",
        .width = COL_ATTR,
        .min_width = 50,
        .sort_order = 0,
    };
    detail_column_count += 1;
    
    detail_columns[detail_column_count] = .{
        .kind = .author,
        .label = "Author",
        .width = COL_AUTHOR,
        .min_width = 60,
        .sort_order = 0,
    };
    detail_column_count += 1;
    
    detail_columns[detail_column_count] = .{
        .kind = .title,
        .label = "Title",
        .width = COL_TITLE,
        .min_width = 60,
        .sort_order = 0,
    };
    detail_column_count += 1;
}

pub fn getDetailColumnCount() usize {
    return detail_column_count;
}

pub fn getDetailColumn(index: usize) ?DetailColumn {
    if (index >= detail_column_count) return null;
    return detail_columns[index];
}

pub fn getDetailSortColumn() DetailColumnKind {
    return sort_column;
}

pub fn getDetailSortAscending() bool {
    return sort_ascending;
}

// ── Column Resize ──────────────────────────────────────────────────────────

pub fn startColumnResize(col: i32, start_x: i32) void {
    if (col >= 0 and col < @as(i32, @intCast(detail_column_count))) {
        header_resizing = true;
        resize_col = col;
        resize_start_x = start_x;
        resize_start_width = detail_columns[@as(usize, @intCast(col))].width;
    }
}

pub fn updateColumnResize(current_x: i32) void {
    if (!header_resizing) return;
    const delta = current_x - resize_start_x;
    const new_width = @max(detail_columns[@as(usize, @intCast(resize_col))].min_width, resize_start_width + delta);
    detail_columns[@as(usize, @intCast(resize_col))].width = new_width;
}

pub fn endColumnResize() void {
    header_resizing = false;
    resize_col = -1;
}

pub fn autoFitColumn(col: usize) void {
    if (col >= detail_column_count) return;
    detail_columns[col].width = COL_NAME;
}

// ── Sorting ────────────────────────────────────────────────────────────────

pub fn sortDetailsByColumn(kind: DetailColumnKind) void {
    if (sort_column == kind) {
        sort_ascending = !sort_ascending;
    } else {
        sort_column = kind;
        sort_ascending = true;
    }
    
    // Update sort order indicators
    for (0..detail_column_count) |i| {
        detail_columns[i].sort_order = 0;
        if (detail_columns[i].kind == kind) {
            detail_columns[i].sort_order = if (sort_ascending) 1 else 2;
        }
    }
    
    // Sync with explorer state
    const field: explorer_state.ExplorerSortField = switch (kind) {
        .name => .name,
        .date_modified, .date_created => .date,
        .size => .size,
        .item_type => .type_,
        else => .name,
    };
    explorer_state.setExplorerSortField(field);
}

pub fn setGroupingEnabled(enabled: bool) void {
    grouping_enabled = enabled;
}

pub fn isGroupingEnabled() bool {
    return grouping_enabled;
}

pub fn getGroupField() DetailColumnKind {
    return group_field;
}

pub fn setGroupField(kind: DetailColumnKind) void {
    group_field = kind;
    grouping_enabled = true;
}

// ── Group Rendering ─────────────────────────────────────────────────────────

const GROUP_HEADER_H: i32 = 22;
const GROUP_EXPAND_W: i32 = 16;

fn renderGroupHeader(x: i32, y: i32, width: i32, group_name: []const u8, item_count: usize, expanded: bool) void {
    fb.fillRect(x, y, width, GROUP_HEADER_H, rgb(0xEE, 0xEE, 0xEE));
    fb.drawHLine(x, y + GROUP_HEADER_H - 1, width, rgb(0xCC, 0xCC, 0xCC));
    
    const chevron = if (expanded) "▼" else "▶";
    fb.drawTextTransparent(x + 4, y + (GROUP_HEADER_H - 14) / 2, chevron, rgb(0x50, 0x50, 0x50));
    
    fb.drawTextTransparent(x + 20, y + (GROUP_HEADER_H - 14) / 2, group_name, rgb(0x18, 0x18, 0x18));
    
    var count_buf: [32]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, " ({d} items)", .{item_count}) catch " (0 items)";
    fb.drawTextTransparent(x + 20 + @as(i32, @intCast(group_name.len * 7)), y + (GROUP_HEADER_H - 14) / 2, count_text, rgb(0x70, 0x70, 0x70));
}

// ── Details View Row Rendering ──────────────────────────────────────────────

const ROW_H: i32 = 18;
const ROW_ICON_SIZE: i32 = 16;
const ROW_PADDING: i32 = 4;

fn renderDetailRow(
    x: i32,
    y: i32,
    width: i32,
    entry: explorer_vol_snap.ExplorerListEntry,
    is_selected: bool,
    is_focus: bool,
    row_idx: usize,
) void {
    const h = ROW_H;
    
    if (row_idx % 2 == 1) {
        fb.fillRect(x, y, width, h, rgb(0xF8, 0xF8, 0xFA));
    }
    
    if (is_selected) {
        fb.fillRect(x, y, width, h, rgb(0xC8, 0xE0, 0xF0));
    }
    
    if (is_focus) {
        fb.drawRect(x + 1, y + 1, width - 2, h - 2, rgb(0x50, 0x50, 0x50));
    }
    
    var col_x: i32 = x + ROW_PADDING + ROW_ICON_SIZE + 4;
    const icon_x = x + ROW_PADDING;
    const icon_y = y + (h - ROW_ICON_SIZE) / 2;
    
    // Render each column
    for (0..detail_column_count) |ci| {
        const col = detail_columns[ci];
        const col_w = col.width;
        const text_y = y + (h - 14) / 2;
        
        switch (col.kind) {
            .name => {
                // Icon
                icons.drawThemedIcon(entry.icon, icon_x, icon_y, 1, .aero, is_selected);
                
                // Name
                const name_color: u32 = if (entry.is_directory)
                    rgb(0x18, 0x18, 0x80)
                else
                    rgb(0x18, 0x18, 0x18);
                
                const name_len = @min(entry.name_len, 40);
                fb.drawTextTransparent(col_x, text_y, entry.name[0..name_len], name_color);
            },
            .size => {
                if (!entry.is_directory) {
                    const size_color: u32 = rgb(0x18, 0x18, 0x18);
                    fb.drawTextTransparent(col_x, text_y, entry.size[0..entry.size_len], size_color);
                }
            },
            .item_type => {
                const type_color: u32 = rgb(0x50, 0x50, 0x50);
                if (entry.is_directory) {
                    fb.drawTextTransparent(col_x, text_y, "File folder", type_color);
                } else {
                    var ext_buf: [16]u8 = undefined;
                    const ext = getExtensionFromName(entry.name[0..entry.name_len], &ext_buf);
                    if (ext.len > 0) {
                        const type_str = std.fmt.bufPrint(&ext_buf, "{s} File", .{ext}) catch "File";
                        fb.drawTextTransparent(col_x, text_y, type_str, type_color);
                    }
                }
            },
            .date_modified => {
                fb.drawTextTransparent(col_x, text_y, entry.date[0..entry.date_len], rgb(0x18, 0x18, 0x18));
            },
            .date_created => {
                fb.drawTextTransparent(col_x, text_y, entry.date[0..entry.date_len], rgb(0x18, 0x18, 0x18));
            },
            .attributes => {
                const attr_text = formatAttr(entry.is_directory);
                fb.drawTextTransparent(col_x, text_y, attr_text, rgb(0x50, 0x50, 0x50));
            },
            .author => {
                fb.drawTextTransparent(col_x, text_y, "", rgb(0x18, 0x18, 0x18));
            },
            .title => {
                fb.drawTextTransparent(col_x, text_y, "", rgb(0x18, 0x18, 0x18));
            },
            .tags => {
                fb.drawTextTransparent(col_x, text_y, "", rgb(0x18, 0x18, 0x18));
            },
            .folder_path => {
                fb.drawTextTransparent(col_x, text_y, "", rgb(0x50, 0x50, 0x50));
            },
        }
        
        fb.drawVLine(col_x + col_w - 1, y, h, rgb(0xDD, 0xDD, 0xDD));
        col_x += col_w;
    }
}

fn getExtensionFromName(name: []const u8, buf: []u8) []const u8 {
    for (name, 0..) |c, idx| {
        if (c == '.') {
            const ext = name[idx + 1..];
            const len = @min(ext.len, buf.len - 1);
            @memcpy(buf[0..len], ext[0..len]);
            buf[len] = 0;
            const upper_ext = std.ascii.upperString(buf, buf);
            return upper_ext;
        }
    }
    return "";
}

fn formatAttr(is_dir: bool) []const u8 {
    return if (is_dir) "D" else "";
}

// ── Details View Header Rendering ─────────────────────────────────────────

const HEADER_H: i32 = 22;

fn renderDetailsHeader(x: i32, y: i32, width: i32) void {
    fb.drawGradientH(x, y, width, HEADER_H, rgb(0xEE, 0xEE, 0xEE), rgb(0xE0, 0xE0, 0xE8));
    fb.drawHLine(x, y + HEADER_H - 1, width, rgb(0xAA, 0xAA, 0xAA));
    
    var col_x: i32 = x;
    
    for (0..detail_column_count) |ci| {
        const col = detail_columns[ci];
        const col_w = col.width;
        const is_hover = (@as(i32, @intCast(ci)) == header_hover_col);
        const is_sort = col.sort_order != 0;
        
        if (is_hover) {
            fb.fillRect(col_x, y + 1, col_w, HEADER_H - 2, rgb(0xDD, 0xDD, 0xDD));
        }
        
        const arrow = if (col.sort_order == 1) "▲" else if (col.sort_order == 2) "▼" else "";
        
        fb.drawTextTransparent(col_x + 4, y + (HEADER_H - 14) / 2, col.label, rgb(0x18, 0x18, 0x18));
        
        if (is_sort) {
            fb.drawTextTransparent(col_x + col_w - 14, y + (HEADER_H - 14) / 2, arrow, rgb(0x40, 0x40, 0x40));
        }
        
        fb.drawVLine(col_x + col_w - 1, y, HEADER_H, rgb(0xAA, 0xAA, 0xAA));
        
        col_x += col_w;
    }
}

// ── Main Details View Render ────────────────────────────────────────────────

var expanded_groups: [16]bool = undefined;
var expanded_group_count: usize = 0;

fn initExpandedGroups() void {
    for (0..16) |i| {
        expanded_groups[i] = true;
    }
    expanded_group_count = 16;
}

pub fn renderDetailsView(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    entries: []const explorer_vol_snap.ExplorerListEntry,
    selected_indices: []const usize,
    focus_index: usize,
    scroll_offset: i32,
) void {
    if (detail_column_count == 0) {
        initDetailColumns();
    }
    if (expanded_group_count == 0) {
        initExpandedGroups();
    }
    
    renderDetailsHeader(x, y, width);
    
    const content_y = y + HEADER_H;
    const content_h = height - HEADER_H;
    
    var row_y: i32 = content_y - scroll_offset;
    
    for (entries, 0..) |entry, ei| {
        if (row_y >= content_y and row_y + ROW_H <= content_y + content_h) {
            const is_selected = for (selected_indices) |si| {
                if (si == ei) break true;
            } else false;
            renderDetailRow(x, row_y, width, entry, is_selected, ei == focus_index, ei);
        }
        row_y += ROW_H;
    }
}

// ── Hit Testing ────────────────────────────────────────────────────────────

pub fn hitTestDetailsHeader(px: i32, py: i32, header_x: i32, header_y: i32, header_w: i32) ?usize {
    if (py < header_y or py >= header_y + HEADER_H) return null;
    if (px < header_x or px >= header_x + header_w) return null;
    
    var col_x: i32 = header_x;
    
    for (0..detail_column_count) |ci| {
        const col_w = detail_columns[ci].width;
        
        if (px >= col_x + col_w - 5 and px <= col_x + col_w + 3) {
            return ci;
        }
        
        if (px < col_x + col_w - 5) {
            return ci;
        }
        
        col_x += col_w;
    }
    
    return null;
}

pub fn isInHeaderResizeZone(px: i32, header_x: i32) bool {
    var col_x: i32 = header_x;
    
    for (0..detail_column_count) |ci| {
        const col_w = detail_columns[ci].width;
        if (px >= col_x + col_w - 5 and px <= col_x + col_w + 3) {
            return true;
        }
        col_x += col_w;
    }
    
    return false;
}

pub fn getDetailRowAtPoint(px: i32, py: i32, content_x: i32, content_y: i32, content_h: i32, scroll_offset: i32) ?usize {
    if (px < content_x) return null;
    if (py < content_y or py >= content_y + content_h) return null;
    
    const row_relative = py - content_y + scroll_offset - HEADER_H;
    if (row_relative < 0) return null;
    
    return @as(usize, @intCast(row_relative / ROW_H));
}

// ── Group Interaction ──────────────────────────────────────────────────────

pub fn toggleGroupExpanded(group_idx: usize) void {
    if (group_idx < 16) {
        expanded_groups[group_idx] = !expanded_groups[group_idx];
    }
}

pub fn hitTestGroupHeader(py: i32, scroll_offset: i32, content_y: i32) ?usize {
    _ = scroll_offset;
    _ = content_y;
    _ = py;
    return null;
}
