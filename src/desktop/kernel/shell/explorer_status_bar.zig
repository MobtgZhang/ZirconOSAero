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

//! Explorer Status Bar - Windows 7 Style Status Bar
//!
//! Implements the Windows 7-style status bar showing item count, selection info,
//! storage space, and loading indicators. Clean-room implementation based on
//! publicly documented Windows 7 Explorer behavior.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");
const explorer_state = @import("../shell/explorer_state.zig");
const explorer_format = @import("../shell/explorer_format.zig");

const rgb = theme.rgb;

// ── Status Bar State ─────────────────────────────────────────────────────────

pub const StatusBarMode = enum {
    normal,
    loading,
    searching,
    status_error,
};

var status_bar_mode: StatusBarMode = .normal;
var status_bar_message: [128]u8 = undefined;
var status_bar_msg_len: usize = 0;
var item_count: usize = 0;
var selected_count: usize = 0;
var total_size: u64 = 0;
var free_space_mb: u32 = 0;
var total_space_mb: u32 = 0;
var space_known: bool = false;

// ── Status Bar Content ───────────────────────────────────────────────────────

pub const StatusInfo = struct {
    mode: StatusBarMode,
    message: []const u8,
    item_count: usize,
    selected_count: usize,
    total_size: u64,
    free_space_mb: u32,
    total_space_mb: u32,
    space_known: bool,
};

pub fn getStatusInfo() StatusInfo {
    return .{
        .mode = status_bar_mode,
        .message = status_bar_message[0..status_bar_msg_len],
        .item_count = item_count,
        .selected_count = selected_count,
        .total_size = total_size,
        .free_space_mb = free_space_mb,
        .total_space_mb = total_space_mb,
        .space_known = space_known,
    };
}

pub fn setStatusInfo(info: StatusInfo) void {
    status_bar_mode = info.mode;
    if (info.message.len < status_bar_message.len) {
        @memcpy(status_bar_message[0..info.message.len], info.message);
        status_bar_msg_len = info.message.len;
    }
    item_count = info.item_count;
    selected_count = info.selected_count;
    total_size = info.total_size;
    free_space_mb = info.free_space_mb;
    total_space_mb = info.total_space_mb;
    space_known = info.space_known;
}

// ── Status Bar Updates ────────────────────────────────────────────────────────

pub fn updateItemCount(count: usize) void {
    item_count = count;
}

pub fn updateSelectedCount(count: usize) void {
    selected_count = count;
}

pub fn updateTotalSize(size: u64) void {
    total_size = size;
}

pub fn updateSpaceInfo(free_mb: u32, total_mb: u32) void {
    free_space_mb = free_mb;
    total_space_mb = total_mb;
    space_known = true;
}

pub fn setStatusMode(mode: StatusBarMode) void {
    status_bar_mode = mode;
}

pub fn setStatusMessage(msg: []const u8) void {
    const len = @min(msg.len, status_bar_message.len);
    @memcpy(status_bar_message[0..len], msg[0..len]);
    status_bar_msg_len = len;
}

// ── Status Bar Text Generation ────────────────────────────────────────────────

pub fn generateStatusText(buf: []u8) []const u8 {
    switch (status_bar_mode) {
        .normal => {
            if (selected_count > 0) {
                return std.fmt.bufPrint(buf, "{d} items ({d} selected)", .{ item_count, selected_count }) catch "";
            } else {
                return std.fmt.bufPrint(buf, "{d} items", .{item_count}) catch "";
            }
        },
        .loading => {
            return std.fmt.bufPrint(buf, "Loading...", .{}) catch "";
        },
        .searching => {
            if (selected_count > 0) {
                return std.fmt.bufPrint(buf, "Searching... {d} items found ({d} selected)", .{ item_count, selected_count }) catch "";
            } else {
                return std.fmt.bufPrint(buf, "Searching... {d} items found", .{item_count}) catch "";
            }
        },
        .status_error => {
            if (status_bar_msg_len > 0) {
                return status_bar_message[0..status_bar_msg_len];
            }
            return "Error";
        },
    }
}

pub fn generateSpaceInfoText(buf: []u8) []const u8 {
    if (!space_known) return "";
    return explorer_format.formatVolumeFreeCaption(buf, free_space_mb, total_space_mb, space_known);
}

// ── Status Bar Rendering ──────────────────────────────────────────────────────

const STATUS_BAR_H: i32 = 24;
const STATUS_BAR_PADDING: i32 = 8;
const STATUS_BAR_DIVIDER: i32 = 100;

pub fn renderStatusBar(x: i32, y: i32, width: i32) void {
    const h = STATUS_BAR_H;
    
    // Background
    fb.fillRect(x, y, width, h, rgb(0xF0, 0xF0, 0xF0));
    
    // Top border
    fb.drawHLine(x, y, width, rgb(0xAA, 0xAA, 0xAA));
    
    // Left section: item count
    var count_buf: [64]u8 = undefined;
    const count_text = generateStatusText(&count_buf);
    fb.drawTextTransparent(x + STATUS_BAR_PADDING, y + (h - 14) / 2, count_text, rgb(0x18, 0x18, 0x18));
    
    // Divider
    fb.drawVLine(x + width - STATUS_BAR_DIVIDER - STATUS_BAR_PADDING, y + 4, h - 8, rgb(0xCC, 0xCC, 0xCC));
    
    // Right section: space info (for drive views)
    if (space_known) {
        var space_buf: [64]u8 = undefined;
        const space_text = generateSpaceInfoText(&space_buf);
        fb.drawTextTransparent(
            x + width - STATUS_BAR_DIVIDER,
            y + (h - 14) / 2,
            space_text,
            rgb(0x18, 0x18, 0x18),
        );
    }
    
    // Loading animation
    if (status_bar_mode == .loading or status_bar_mode == .searching) {
        renderLoadingIndicator(x + width - 60, y + (h - 14) / 2);
    }
}

fn renderLoadingIndicator(x: i32, y: i32) void {
    fb.drawTextTransparent(x, y, "...", rgb(0x60, 0x60, 0x60));
}

// ── Status Bar for Different Views ───────────────────────────────────────────

pub fn updateStatusForDriveView(letter: u8) void {
    const vol = explorer_state.explorerVolumeByLetter(letter);
    if (vol) |v| {
        updateSpaceInfo(v.free_mb, v.total_mb);
    }
}

pub fn updateStatusForFolderView(entry_count: usize, selected: usize) void {
    updateItemCount(entry_count);
    updateSelectedCount(selected);
    space_known = false;
}

// ── Status Bar with Progress ─────────────────────────────────────────────────

var progress_percent: u8 = 0;
var progress_shown: bool = false;

pub fn showProgress(percent: u8) void {
    progress_percent = @min(percent, 100);
    progress_shown = true;
}

pub fn hideProgress() void {
    progress_shown = false;
    progress_percent = 0;
}

pub fn renderStatusBarWithProgress(x: i32, y: i32, width: i32) void {
    renderStatusBar(x, y, width);
    
    if (progress_shown) {
        const progress_y = y + STATUS_BAR_H - 4;
        const progress_w = @as(i32, @intCast(@as(u16, width) * @as(u16, progress_percent) / 100));
        
        // Progress bar background
        fb.fillRect(x, progress_y, width, 4, rgb(0xDD, 0xDD, 0xDD));
        
        // Progress bar fill
        fb.fillRect(x, progress_y, progress_w, 4, rgb(0x00, 0x51, 0x9E));
    }
}
