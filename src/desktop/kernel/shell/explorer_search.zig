//! Explorer Search Box - Windows 7 Style Instant Search with AQS
//!
//! Implements the Windows 7-style search box with instant filtering, search history,
//! and Advanced Query Syntax (AQS) support. Clean-room implementation based on
//! publicly documented Windows 7 Explorer behavior.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");
const explorer_vol_snap = @import("../../../fs/explorer_volume_snapshot.zig");

const rgb = theme.rgb;

// ── Search State ────────────────────────────────────────────────────────────

var search_text: [256]u8 = undefined;
var search_len: usize = 0;
var search_active: bool = false;
var search_focused: bool = false;
var search_hover: bool = false;
var search_cursor_pos: usize = 0;

// Search history
const MAX_SEARCH_HISTORY = 10;
var search_history: [MAX_SEARCH_HISTORY][256]u8 = undefined;
var search_history_lens: [MAX_SEARCH_HISTORY]usize = undefined;
var search_history_count: usize = 0;

// Search results
var search_filtered_indices: [256]usize = undefined;
var search_filtered_count: usize = 0;

// AQS parsing state
var aqs_size_min: u64 = 0;
var aqs_size_max: u64 = 0;
var aqs_size_specified: bool = false;
var aqs_type_filter: [16]u8 = undefined;
var aqs_type_len: usize = 0;

// ── Search Box Layout ──────────────────────────────────────────────────────

const SEARCH_BOX_H: i32 = 24;
const SEARCH_BOX_W: i32 = 250;
const SEARCH_MARGIN_X: i32 = 8;
const SEARCH_ICON_SIZE: i32 = 16;
const SEARCH_PADDING_X: i32 = 24;

// ── AQS Parsing ─────────────────────────────────────────────────────────────

pub const AqsQuery = struct {
    text_filter: []const u8,
    size_min: u64,
    size_max: u64,
    size_specified: bool,
    type_filter: []const u8,
    date_from: ?u64,
    date_to: ?u64,
};

fn parseAqsQuery(input: []const u8) AqsQuery {
    var result = AqsQuery{
        .text_filter = input,
        .size_min = 0,
        .size_max = 0,
        .size_specified = false,
        .type_filter = "",
        .date_from = null,
        .date_to = null,
    };
    
    var i: usize = 0;
    while (i < input.len) {
        // Check for size: operator
        if (i + 6 <= input.len and std.mem.eql(u8, input[i..i+6], "size:>")) {
            i += 6;
            // Parse size value (e.g., "1MB", "1GB")
            const size_start = i;
            while (i < input.len and input[i] != ' ' and input[i] != '\t') {
                i += 1;
            }
            const size_str = input[size_start..i];
            const size = parseSizeString(size_str);
            result.size_min = size;
            result.size_specified = true;
            continue;
        }
        
        if (i + 6 <= input.len and std.mem.eql(u8, input[i..i+6], "size:<")) {
            i += 6;
            const size_start = i;
            while (i < input.len and input[i] != ' ' and input[i] != '\t') {
                i += 1;
            }
            const size_str = input[size_start..i];
            const size = parseSizeString(size_str);
            result.size_max = size;
            result.size_specified = true;
            continue;
        }
        
        // Check for type: operator
        if (i + 6 <= input.len and std.mem.eql(u8, input[i..i+6], "type:")) {
            i += 6;
            const type_start = i;
            while (i < input.len and input[i] != ' ' and input[i] != '\t') {
                i += 1;
            }
            result.type_filter = input[type_start..i];
            continue;
        }
        
        i += 1;
    }
    
    return result;
}

fn parseSizeString(s: []const u8) u64 {
    if (s.len == 0) return 0;
    
    var multiplier: u64 = 1;
    var num_str = s;
    
    // Check suffix
    const last = std.ascii.toLower(s[s.len - 1]);
    switch (last) {
        'k' => {
            multiplier = 1024;
            num_str = s[0..s.len-1];
        },
        'm' => {
            multiplier = 1024 * 1024;
            num_str = s[0..s.len-1];
        },
        'g' => {
            multiplier = 1024 * 1024 * 1024;
            num_str = s[0..s.len-1];
        },
        'b' => {
            multiplier = 1;
            num_str = s[0..s.len-1];
        },
        else => {},
    }
    
    // Parse number
    var value: u64 = 0;
    for (num_str) |c| {
        if (c >= '0' and c <= '9') {
            value = value * 10 + @as(u64, c - '0');
        }
    }
    
    return value * multiplier;
}

// ── Search Filtering ─────────────────────────────────────────────────────────

pub fn filterEntriesBySearch(
    entries: []const explorer_vol_snap.ExplorerListEntry,
    query: []const u8,
) usize {
    if (query.len == 0) {
        search_filtered_count = 0;
        return 0;
    }
    
    const aqs = parseAqsQuery(query);
    search_filtered_count = 0;
    
    for (entries, 0..) |entry, idx| {
        if (search_filtered_count >= 256) break;
        
        // Text filter
        const name = entry.name[0..entry.name_len];
        if (aqs.text_filter.len > 0 and !containsIgnoreCase(name, aqs.text_filter)) {
            continue;
        }
        
        // Size filter
        if (aqs.size_specified) {
            const file_size = entry.file_size;
            if (aqs.size_min > 0 and file_size < aqs.size_min) continue;
            if (aqs.size_max > 0 and file_size > aqs.size_max) continue;
        }
        
        // Type filter
        if (aqs.type_filter.len > 0) {
            const entry_type = getEntryType(entry.name[0..entry.name_len]);
            if (!containsIgnoreCase(entry_type, aqs.type_filter)) continue;
        }
        
        search_filtered_indices[search_filtered_count] = idx;
        search_filtered_count += 1;
    }
    
    return search_filtered_count;
}

fn getEntryType(name: []const u8) []const u8 {
    for (name, 0..) |c, idx| {
        if (c == '.') {
            return name[idx + 1..];
        }
    }
    return "";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    
    var i: usize = 0;
    while (i <= haystack.len - needle.len) {
        var j: usize = 0;
        while (j < needle.len) {
            const hc = std.ascii.toLower(haystack[i + j]);
            const nc = std.ascii.toLower(needle[j]);
            if (hc != nc) break;
            j += 1;
        }
        if (j == needle.len) return true;
        i += 1;
    }
    return false;
}

pub fn getFilteredIndices() []const usize {
    return search_filtered_indices[0..search_filtered_count];
}

pub fn getFilteredCount() usize {
    return search_filtered_count;
}

// ── Search History ───────────────────────────────────────────────────────────

pub fn addToSearchHistory(query: []const u8) void {
    if (query.len == 0) return;
    
    // Check if already exists
    for (0..search_history_count) |i| {
        if (search_history_lens[i] == query.len and
            std.mem.eql(u8, search_history[i][0..query.len], query)) {
            // Move to front
            var j = i;
            while (j > 0) : (j -= 1) {
                search_history[j] = search_history[j - 1];
                search_history_lens[j] = search_history_lens[j - 1];
            }
            @memcpy(search_history[0][0..query.len], query);
            search_history_lens[0] = query.len;
            return;
        }
    }
    
    // Add to front
    var i = search_history_count;
    while (i > 0) : (i -= 1) {
        search_history[i] = search_history[i - 1];
        search_history_lens[i] = search_history_lens[i - 1];
    }
    
    @memcpy(search_history[0][0..query.len], query);
    search_history_lens[0] = query.len;
    
    if (search_history_count < MAX_SEARCH_HISTORY) {
        search_history_count += 1;
    }
}

pub fn getSearchHistory() []const []const u8 {
    var result: [MAX_SEARCH_HISTORY][]const u8 = undefined;
    for (0..search_history_count) |i| {
        result[i] = search_history[i][0..search_history_lens[i]];
    }
    return result[0..search_history_count];
}

pub fn clearSearchHistory() void {
    search_history_count = 0;
}

// ── Search Box State ─────────────────────────────────────────────────────────

pub fn isSearchActive() bool {
    return search_active;
}

pub fn isSearchFocused() bool {
    return search_focused;
}

pub fn setSearchFocused(focused: bool) void {
    search_focused = focused;
    if (focused) {
        search_active = true;
    }
}

pub fn isSearchHover() bool {
    return search_hover;
}

pub fn setSearchHover(hover: bool) void {
    search_hover = hover;
}

pub fn getSearchText() []const u8 {
    return search_text[0..search_len];
}

pub fn setSearchText(text: []const u8) void {
    const len = @min(text.len, search_text.len);
    @memcpy(search_text[0..len], text[0..len]);
    search_len = len;
    search_cursor_pos = len;
}

pub fn appendSearchChar(c: u8) void {
    if (search_len >= search_text.len) return;
    search_text[search_len] = c;
    search_len += 1;
    search_cursor_pos = search_len;
}

pub fn deleteSearchChar() void {
    if (search_len == 0) return;
    search_len -= 1;
    if (search_cursor_pos > search_len) {
        search_cursor_pos = search_len;
    }
}

pub fn clearSearch() void {
    search_len = 0;
    search_cursor_pos = 0;
    search_active = false;
    search_filtered_count = 0;
}

pub fn getSearchCursorPos() usize {
    return search_cursor_pos;
}

pub fn setSearchCursorPos(pos: usize) void {
    search_cursor_pos = @min(pos, search_len);
}

// ── Search Box Rendering ─────────────────────────────────────────────────────

const SEARCH_BOX_X: i32 = 400;
const SEARCH_BOX_Y: i32 = 4;
const SEARCH_BOX_BORDER: i32 = 1;

pub fn renderSearchBox(x: i32, y: i32, w: i32, h: i32) void {
    const bg_color: u32 = if (search_focused or search_hover)
        rgb(0xFF, 0xFF, 0xFF)
    else
        rgb(0xF8, 0xF8, 0xF8);
    
    const border_color: u32 = if (search_focused)
        rgb(0x00, 0x51, 0x9E)
    else if (search_hover)
        rgb(0x70, 0x7A, 0x8C)
    else
        rgb(0xA0, 0xA4, 0xAE);
    
    // Background
    fb.fillRect(x, y, w, h, bg_color);
    
    // Border
    fb.drawRect(x, y, w, h, border_color);
    
    // Search icon (magnifying glass)
    const icon_x = x + 4;
    const icon_y = y + (h - SEARCH_ICON_SIZE) / 2;
    renderSearchIcon(icon_x, icon_y);
    
    // Text or placeholder
    const text_x = x + SEARCH_PADDING_X;
    const text_y = y + (h - 14) / 2;
    
    if (search_len > 0) {
        fb.drawTextTransparent(text_x, text_y, search_text[0..search_len], rgb(0x18, 0x18, 0x18));
        
        // Cursor
        if (search_focused) {
            const cursor_x = text_x + fb.textWidth(search_text[0..search_cursor_pos]);
            fb.fillRect(cursor_x, y + 4, 2, h - 8, rgb(0x00, 0x51, 0x9E));
        }
    } else if (!search_focused) {
        const placeholder = "Search";
        fb.drawTextTransparent(text_x, text_y, placeholder, rgb(0xA0, 0xA0, 0xA0));
    }
    
    // Clear button (X) when there's text
    if (search_len > 0) {
        const clear_x = x + w - 20;
        const clear_y = y + (h - 16) / 2;
        renderClearButton(clear_x, clear_y);
    }
    
    // Dropdown arrow
    const arrow_x = x + w - 16;
    const arrow_y = y + (h - 12) / 2;
    fb.drawTextTransparent(arrow_x, arrow_y, "▼", rgb(0x60, 0x60, 0x60));
}

fn renderSearchIcon(x: i32, y: i32) void {
    // Simple magnifying glass representation
    fb.drawCircle(x + 6, y + 6, 5, rgb(0x60, 0x60, 0x60));
    fb.drawLine(x + 9, y + 9, x + 13, y + 13, rgb(0x60, 0x60, 0x60));
}

fn renderClearButton(x: i32, y: i32) void {
    fb.drawTextTransparent(x, y, "×", rgb(0x60, 0x60, 0x60));
}

// ── Search History Dropdown ──────────────────────────────────────────────────

pub fn renderSearchHistoryDropdown(x: i32, y: i32, w: i32) void {
    if (search_history_count == 0) return;
    
    const item_h: i32 = 22;
    const dropdown_h = @as(i32, @intCast(search_history_count)) * item_h + 2;
    
    // Background
    fb.fillRect(x, y, w, dropdown_h, rgb(0xFF, 0xFF, 0xFF));
    fb.drawRect(x, y, w, dropdown_h, rgb(0xA0, 0xA4, 0xAE));
    
    // Items
    for (0..search_history_count) |i| {
        const item_y = y + 1 + @as(i32, @intCast(i)) * item_h;
        fb.drawTextTransparent(x + 8, item_y + 4, search_history[i][0..search_history_lens[i]], rgb(0x18, 0x18, 0x18));
        
        // Separator
        if (i < search_history_count - 1) {
            fb.drawHLine(x + 1, item_y + item_h - 1, w - 2, rgb(0xEE, 0xEE, 0xEE));
        }
    }
}

// ── Hit Testing ──────────────────────────────────────────────────────────────

pub fn isInSearchBox(px: i32, py: i32, sb_x: i32, sb_y: i32, sb_w: i32, sb_h: i32) bool {
    return px >= sb_x and px < sb_x + sb_w and py >= sb_y and py < sb_y + sb_h;
}

pub fn isInClearButton(px: i32, py: i32, sb_x: i32, sb_y: i32, sb_w: i32, sb_h: i32) bool {
    const clear_x = sb_x + sb_w - 20;
    const clear_y = sb_y + (sb_h - 16) / 2;
    return px >= clear_x and px < clear_x + 16 and py >= clear_y and py < clear_y + 16;
}

pub fn hitTestSearchHistory(px: i32, py: i32, sh_x: i32, sh_y: i32, sh_w: i32) ?usize {
    const item_h: i32 = 22;
    
    if (py < sh_y or py >= sh_y + @as(i32, @intCast(search_history_count)) * item_h) {
        return null;
    }
    if (px < sh_x or px >= sh_x + sh_w) {
        return null;
    }
    
    const idx = @as(usize, @intCast((py - sh_y) / item_h));
    if (idx < search_history_count) {
        return idx;
    }
    return null;
}
