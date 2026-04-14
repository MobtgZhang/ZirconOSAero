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

//! Explorer Command Bar - Windows 7 Style
//!
//! Implements the command bar (Folder Band) with Cut/Copy/Paste/Delete/Rename/Properties.
//! Clean-room implementation based on publicly documented Windows 7 Explorer behavior.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");
const icons = @import("../icons/root.zig");
const explorer_state = @import("../shell/explorer_state.zig");
const shell_mui = @import("../strings/shell_mui.zig");

const rgb = theme.rgb;

// ── Command Bar Button Types ──────────────────────────────────────────────────

pub const CmdButtonId = enum(u8) {
    organize,
    open,
    more,
    cut,
    copy,
    paste,
    delete,
    rename,
    properties,
    new_folder,
    include_lib,
    share_with,
    view,
    system_properties,
    // Sort buttons
    sort_name,
    sort_date,
    sort_size,
    sort_type,
};

pub const CmdButton = struct {
    id: CmdButtonId,
    label: []const u8,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    enabled: bool,
};

const MAX_CMD_BUTTONS = 16;
var cmd_buttons: [MAX_CMD_BUTTONS]CmdButton = undefined;
var cmd_button_count: usize = 0;
var cmd_hover_button: ?CmdButtonId = null;

// Command bar mouse tracking
var cmd_mouse_x: i32 = -1;
var cmd_mouse_y: i32 = -1;
var cmd_hovered: bool = false;

// ── Command Bar Layout ────────────────────────────────────────────────────────

fn layoutComputerCommandBar(base_x: i32, base_y: i32, has_selection: bool, has_clipboard: bool, _: i32) void {
    cmd_button_count = 0;
    var bx: i32 = base_x + 8;
    const by: i32 = base_y + 6;
    const btn_h: i32 = 20;
    
    // Row 1: Organize | Open | More | ... | Include in library | Share with
    // Organize
    cmd_buttons[cmd_button_count] = .{
        .id = .organize,
        .label = shell_mui.loadString(.ex_cmp_organize, &[_]u8{0} ** 1),
        .x = bx,
        .y = by,
        .w = 60,
        .h = btn_h,
        .enabled = true,
    };
    bx += 68;
    cmd_button_count += 1;
    
    // Open
    cmd_buttons[cmd_button_count] = .{
        .id = .open,
        .label = shell_mui.loadString(.ex_cmp_open, &[_]u8{0} ** 1),
        .x = bx,
        .y = by,
        .w = 50,
        .h = btn_h,
        .enabled = has_selection,
    };
    bx += 58;
    cmd_button_count += 1;
    
    // More (dropdown)
    cmd_buttons[cmd_button_count] = .{
        .id = .more,
        .label = "▼",
        .x = bx,
        .y = by,
        .w = 20,
        .h = btn_h,
        .enabled = true,
    };
    bx += 28;
    cmd_button_count += 1;
    
    // Separator + Include in library
    const lib_x: i32 = base_x + 200;
    cmd_buttons[cmd_button_count] = .{
        .id = .include_lib,
        .label = shell_mui.loadString(.ex_cmp_include_lib, &[_]u8{0} ** 1),
        .x = lib_x,
        .y = by,
        .w = 100,
        .h = btn_h,
        .enabled = has_selection,
    };
    cmd_button_count += 1;
    
    // Share with
    cmd_buttons[cmd_button_count] = .{
        .id = .share_with,
        .label = shell_mui.loadString(.ex_cmp_share_with, &[_]u8{0} ** 1),
        .x = lib_x + 110,
        .y = by,
        .w = 70,
        .h = btn_h,
        .enabled = has_selection,
    };
    cmd_button_count += 1;
    
    // Row 2: Cut | Copy | Paste | Delete | Rename | Properties | System Properties | View
    bx = base_x + 8;
    const row2_y: i32 = base_y + 30;
    
    // Cut
    cmd_buttons[cmd_button_count] = .{
        .id = .cut,
        .label = "剪切",
        .x = bx,
        .y = row2_y,
        .w = 40,
        .h = btn_h,
        .enabled = has_selection,
    };
    bx += 48;
    cmd_button_count += 1;
    
    // Copy
    cmd_buttons[cmd_button_count] = .{
        .id = .copy,
        .label = "复制",
        .x = bx,
        .y = row2_y,
        .w = 40,
        .h = btn_h,
        .enabled = has_selection,
    };
    bx += 48;
    cmd_button_count += 1;
    
    // Paste
    cmd_buttons[cmd_button_count] = .{
        .id = .paste,
        .label = "粘贴",
        .x = bx,
        .y = row2_y,
        .w = 40,
        .h = btn_h,
        .enabled = has_clipboard,
    };
    bx += 48;
    cmd_button_count += 1;
    
    // Delete
    cmd_buttons[cmd_button_count] = .{
        .id = .delete,
        .label = "删除",
        .x = bx,
        .y = row2_y,
        .w = 40,
        .h = btn_h,
        .enabled = has_selection,
    };
    bx += 48;
    cmd_button_count += 1;
    
    // Rename
    cmd_buttons[cmd_button_count] = .{
        .id = .rename,
        .label = "重命名",
        .x = bx,
        .y = row2_y,
        .w = 50,
        .h = btn_h,
        .enabled = has_selection,
    };
    bx += 58;
    cmd_button_count += 1;
    
    // Separator
    bx += 8;
    
    // Properties
    cmd_buttons[cmd_button_count] = .{
        .id = .properties,
        .label = shell_mui.loadString(.ex_cmd_properties, &[_]u8{0} ** 1),
        .x = bx,
        .y = row2_y,
        .w = 55,
        .h = btn_h,
        .enabled = has_selection,
    };
    bx += 63;
    cmd_button_count += 1;
    
    // System Properties
    cmd_buttons[cmd_button_count] = .{
        .id = .system_properties,
        .label = shell_mui.loadString(.ex_cmd_system_properties, &[_]u8{0} ** 1),
        .x = bx,
        .y = row2_y,
        .w = 85,
        .h = btn_h,
        .enabled = true,
    };
    bx += 93;
    cmd_button_count += 1;
    
    // Separator
    bx += 8;
    
    // View
    cmd_buttons[cmd_button_count] = .{
        .id = .view,
        .label = shell_mui.loadString(.ex_cmd_view, &[_]u8{0} ** 1),
        .x = bx,
        .y = row2_y,
        .w = 40,
        .h = btn_h,
        .enabled = true,
    };
    cmd_button_count += 1;
}

// ── Command Bar Rendering ───────────────────────────────────────────────────

pub fn updateCommandBarState(mx: i32, my: i32, base_x: i32, base_y: i32, cmd_h: i32) void {
    cmd_mouse_x = mx;
    cmd_mouse_y = my;
    
    const has_selection = explorer_state.getExplorerListSelectedRow() != explorer_state.EXPLORER_LIST_SEL_NONE;
    const has_clipboard = builtin_apps.getClipboard().primary != .none;
    
    layoutComputerCommandBar(base_x, base_y, has_selection, has_clipboard, cmd_h);
    
    // Check hover
    cmd_hover_button = null;
    for (0..cmd_button_count) |i| {
        const btn = cmd_buttons[i];
        if (btn.enabled and mx >= btn.x and mx < btn.x + btn.w and my >= btn.y and my < btn.y + btn.h) {
            cmd_hover_button = btn.id;
            cmd_hovered = true;
            return;
        }
    }
    cmd_hovered = false;
}

pub fn renderCommandBar() void {
    for (0..cmd_button_count) |i| {
        const btn = cmd_buttons[i];
        const is_hover = cmd_hover_button == btn.id;
        
        // Button background
        const bg_color: u32 = if (is_hover and btn.enabled)
            rgb(0xD0, 0xE0, 0xF0)
        else if (btn.enabled)
            rgb(0xF0, 0xF4, 0xF8)
        else
            rgb(0xF8, 0xF8, 0xF8);
        
        fb.fillRect(btn.x, btn.y, btn.w, btn.h, bg_color);
        
        // Text
        const text_color: u32 = if (btn.enabled)
            rgb(0x00, 0x51, 0x9E)
        else
            rgb(0xA0, 0xA0, 0xA0);
        
        const tw = fb.textWidth(btn.label);
        const tx = btn.x + (btn.w - tw) / 2;
        const ty = btn.y + (btn.h - 14) / 2;
        fb.drawTextTransparent(tx, ty, btn.label, text_color);
        
        // Draw triangle for dropdown buttons
        if (btn.id == .more) {
            fb.drawTextTransparent(btn.x + btn.w - 8, ty, "▼", text_color);
        }
    }
}

pub fn getCommandBarHoverButton() ?CmdButtonId {
    return cmd_hover_button;
}

pub fn isCommandBarHovered() bool {
    return cmd_hovered;
}

pub fn handleCommandBarClick(x: i32, y: i32) ?CmdButtonId {
    for (0..cmd_button_count) |i| {
        const btn = cmd_buttons[i];
        if (btn.enabled and x >= btn.x and x < btn.x + btn.w and y >= btn.y and y < btn.y + btn.h) {
            return btn.id;
        }
    }
    return null;
}

// Builtin apps for clipboard check
const builtin_apps = @import("../shell/builtin_apps.zig");
