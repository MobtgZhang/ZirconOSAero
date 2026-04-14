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

//! Explorer Context Menu - Windows 7 Style
//!
//! Implements right-click context menus for files, folders, drives, and empty areas.
//! Clean-room implementation based on publicly documented Windows 7 Explorer behavior.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");
const icons = @import("../icons/root.zig");
const explorer_state = @import("../shell/explorer_state.zig");
const shell_mui = @import("../strings/shell_mui.zig");

const rgb = theme.rgb;

// ── Context Menu Types ───────────────────────────────────────────────────────

const ExplorerContextMenuKind = explorer_state.ExplorerContextMenuKind;

pub const ContextMenuItem = struct {
    label: []const u8,
    enabled: bool = true,
    separator_after: bool = false,
    submenu: bool = false,
};

const CTX_MENU_PAD: i32 = 4;
const CTX_ITEM_H: i32 = 22;
const CTX_MENU_W: i32 = 200;
const CTX_SHADOW_OFFSET: i32 = 4;

// ── Context Menu State ──────────────────────────────────────────────────────

var ctx_menu_visible: bool = false;
var ctx_menu_x: i32 = 0;
var ctx_menu_y: i32 = 0;
var ctx_menu_kind: ExplorerContextMenuKind = .none;
var ctx_menu_item_count: usize = 0;
var ctx_menu_hover_index: i32 = -1;

// Submenu state
var ctx_submenu_visible: bool = false;
var ctx_submenu_items: [16][]const u8 = undefined;
var ctx_submenu_count: usize = 0;
var ctx_submenu_hover_index: i32 = -1;
var ctx_submenu_x: i32 = 0;
var ctx_submenu_y: i32 = 0;
var ctx_submenu_anim_progress: f32 = 1.0;

fn ctxMenuHeight() i32 {
    return CTX_MENU_PAD * 2 + @as(i32, @intCast(ctx_menu_item_count)) * CTX_ITEM_H;
}

fn submenuHeight() i32 {
    return CTX_MENU_PAD * 2 + @as(i32, @intCast(ctx_submenu_count)) * CTX_ITEM_H;
}

// ── Context Menu Items ────────────────────────────────────────────────────────

const CTX_MAX_ITEMS = 16;
var ctx_menu_items_buf: [CTX_MAX_ITEMS]ContextMenuItem = undefined;

fn buildFileContextMenu() void {
    ctx_menu_item_count = 0;
    const items = &ctx_menu_items_buf;
    
    // Open
    items[ctx_menu_item_count] = .{ .label = "打开" };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Cut
    items[ctx_menu_item_count] = .{ .label = "剪切" };
    ctx_menu_item_count += 1;
    
    // Copy
    items[ctx_menu_item_count] = .{ .label = "复制" };
    ctx_menu_item_count += 1;
    
    // Paste
    items[ctx_menu_item_count] = .{ .label = "粘贴", .enabled = false };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Rename
    items[ctx_menu_item_count] = .{ .label = "重命名" };
    ctx_menu_item_count += 1;
    
    // Delete
    items[ctx_menu_item_count] = .{ .label = "删除" };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Properties
    items[ctx_menu_item_count] = .{ .label = "属性" };
    ctx_menu_item_count += 1;
}

fn buildFolderContextMenu() void {
    ctx_menu_item_count = 0;
    const items = &ctx_menu_items_buf;
    
    // Open
    items[ctx_menu_item_count] = .{ .label = "打开" };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Cut
    items[ctx_menu_item_count] = .{ .label = "剪切" };
    ctx_menu_item_count += 1;
    
    // Copy
    items[ctx_menu_item_count] = .{ .label = "复制" };
    ctx_menu_item_count += 1;
    
    // Paste
    items[ctx_menu_item_count] = .{ .label = "粘贴" };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // New Folder
    items[ctx_menu_item_count] = .{ .label = "新建文件夹" };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Rename
    items[ctx_menu_item_count] = .{ .label = "重命名" };
    ctx_menu_item_count += 1;
    
    // Delete
    items[ctx_menu_item_count] = .{ .label = "删除" };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Properties
    items[ctx_menu_item_count] = .{ .label = "属性" };
    ctx_menu_item_count += 1;
}

fn buildEmptyAreaContextMenu() void {
    ctx_menu_item_count = 0;
    const items = &ctx_menu_items_buf;
    
    // View submenu placeholder
    items[ctx_menu_item_count] = .{ .label = "视图", .submenu = true };
    ctx_menu_item_count += 1;
    
    // Sort by
    items[ctx_menu_item_count] = .{ .label = "排序方式", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Paste
    items[ctx_menu_item_count] = .{ .label = "粘贴" };
    ctx_menu_item_count += 1;
    
    // New Folder
    items[ctx_menu_item_count] = .{ .label = "新建文件夹" };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Refresh
    items[ctx_menu_item_count] = .{ .label = "刷新" };
    ctx_menu_item_count += 1;
}

fn buildDriveContextMenu() void {
    ctx_menu_item_count = 0;
    const items = &ctx_menu_items_buf;
    
    // Open
    items[ctx_menu_item_count] = .{ .label = "打开" };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Include in library
    items[ctx_menu_item_count] = .{ .label = "包含到库中", .submenu = true };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Format (for removable)
    items[ctx_menu_item_count] = .{ .label = "格式化...", .enabled = false };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Properties
    items[ctx_menu_item_count] = .{ .label = "属性" };
    ctx_menu_item_count += 1;
}

fn buildMultipleSelectionContextMenu() void {
    ctx_menu_item_count = 0;
    const items = &ctx_menu_items_buf;
    
    // Open
    items[ctx_menu_item_count] = .{ .label = "打开" };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Cut
    items[ctx_menu_item_count] = .{ .label = "剪切" };
    ctx_menu_item_count += 1;
    
    // Copy
    items[ctx_menu_item_count] = .{ .label = "复制" };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Delete
    items[ctx_menu_item_count] = .{ .label = "删除" };
    ctx_menu_item_count += 1;
    
    // Separator
    items[ctx_menu_item_count] = .{ .label = "---", .separator_after = false };
    ctx_menu_item_count += 1;
    
    // Properties
    items[ctx_menu_item_count] = .{ .label = "属性" };
    ctx_menu_item_count += 1;
}

// ── Context Menu Show/Hide ───────────────────────────────────────────────────

pub fn showExplorerContextMenu(kind: ExplorerContextMenuKind, x: i32, y: i32) void {
    ctx_menu_kind = kind;
    ctx_menu_x = x;
    ctx_menu_y = y;
    
    switch (kind) {
        .file => buildFileContextMenu(),
        .folder => buildFolderContextMenu(),
        .empty_area => buildEmptyAreaContextMenu(),
        .drive => buildDriveContextMenu(),
        .multiple_selection => buildMultipleSelectionContextMenu(),
        .none => {},
    }
    
    ctx_menu_visible = true;
    ctx_menu_hover_index = -1;
    ctx_submenu_visible = false;
    ctx_submenu_anim_progress = 0.0;
}

pub fn hideExplorerContextMenu() void {
    ctx_menu_visible = false;
    ctx_menu_kind = .none;
    ctx_menu_hover_index = -1;
    ctx_submenu_visible = false;
}

pub fn isExplorerContextMenuVisible() bool {
    return ctx_menu_visible;
}

pub fn getExplorerContextMenuKind() ExplorerContextMenuKind {
    return ctx_menu_kind;
}

// ── Context Menu Rendering ───────────────────────────────────────────────────

pub fn renderExplorerContextMenu() void {
    if (!ctx_menu_visible) return;
    
    const mh = ctxMenuHeight();
    const mw: i32 = CTX_MENU_W;
    const sx = ctx_menu_x;
    const sy = ctx_menu_y;
    
    // Shadow
    fb.fillRect(sx + CTX_SHADOW_OFFSET, sy + CTX_SHADOW_OFFSET, mw, mh, rgb(0x40, 0x40, 0x40));
    
    // Background
    fb.fillRect(sx, sy, mw, mh, rgb(0xF8, 0xF8, 0xF8));
    fb.drawRect(sx, sy, mw, mh, rgb(0xA0, 0xA0, 0xA0));
    
    // Items
    var iy: i32 = sy + CTX_MENU_PAD;
    var item_idx: usize = 0;
    while (item_idx < ctx_menu_item_count) : (item_idx += 1) {
        const item = ctx_menu_items_buf[item_idx];
        
        if (std.mem.eql(u8, item.label, "---")) {
            fb.drawHLine(sx + 4, iy + 4, mw - 8, rgb(0xC0, 0xC0, 0xC0));
            iy += 8;
            continue;
        }
        
        const is_hover = (@as(i32, @intCast(item_idx)) == ctx_menu_hover_index);
        if (is_hover) {
            fb.fillRect(sx + 2, iy, mw - 4, CTX_ITEM_H, rgb(0xD8, 0xE8, 0xF8));
        }
        
        const tc: u32 = if (item.enabled) rgb(0x10, 0x10, 0x10) else rgb(0x80, 0x80, 0x80);
        fb.drawTextTransparent(sx + 8, iy + 4, item.label, tc);
        
        // Submenu arrow
        if (item.submenu) {
            fb.drawTextTransparent(sx + mw - 16, iy + 4, "▶", rgb(0x40, 0x40, 0x40));
        }
        
        iy += CTX_ITEM_H;
    }
    
    // Render submenu if visible
    if (ctx_submenu_visible) {
        renderContextSubmenu();
    }
}

fn renderContextSubmenu() void {
    const smh = submenuHeight();
    const smw: i32 = CTX_MENU_W;
    
    // Animate
    ctx_submenu_anim_progress = @min(1.0, ctx_submenu_anim_progress + 0.15);
    if (ctx_submenu_anim_progress > 1.0) ctx_submenu_anim_progress = 1.0;
    
    const anim_offset = @as(i32, @intFromFloat(@as(f32, @floatFromInt(smw)) * (1.0 - ctx_submenu_anim_progress)));
    const ax = ctx_submenu_x + anim_offset;
    const ay = ctx_submenu_y;
    
    // Shadow
    fb.fillRect(ax + CTX_SHADOW_OFFSET, ay + CTX_SHADOW_OFFSET, smw, smh, rgb(0x40, 0x40, 0x40));
    
    // Background
    fb.fillRect(ax, ay, smw, smh, rgb(0xF8, 0xF8, 0xF8));
    fb.drawRect(ax, ay, smw, smh, rgb(0xA0, 0xA0, 0xA0));
    
    // Items
    var iy: i32 = ay + CTX_MENU_PAD;
    var i: usize = 0;
    while (i < ctx_submenu_count) : (i += 1) {
        const is_hover = (@as(i32, @intCast(i)) == ctx_submenu_hover_index);
        if (is_hover) {
            fb.fillRect(ax + 2, iy, smw - 4, CTX_ITEM_H, rgb(0xD8, 0xE8, 0xF8));
        }
        
        fb.drawTextTransparent(ax + 8, iy + 4, ctx_submenu_items[i], rgb(0x10, 0x10, 0x10));
        iy += CTX_ITEM_H;
    }
}

// ── Context Menu Hit Testing ─────────────────────────────────────────────────

pub fn isInsideExplorerContextMenu(x: i32, y: i32) bool {
    if (!ctx_menu_visible) return false;
    
    // Check submenu first
    if (ctx_submenu_visible) {
        const smh = submenuHeight();
        const smw: i32 = CTX_MENU_W;
        const anim_offset = @as(i32, @intFromFloat(@as(f32, @floatFromInt(smw)) * (1.0 - ctx_submenu_anim_progress)));
        if (x >= ctx_submenu_x + anim_offset and x < ctx_submenu_x + anim_offset + smw and
            y >= ctx_submenu_y and y < ctx_submenu_y + smh) {
            return true;
        }
    }
    
    return x >= ctx_menu_x and x < ctx_menu_x + CTX_MENU_W and
           y >= ctx_menu_y and y < ctx_menu_y + ctxMenuHeight();
}

pub fn updateExplorerContextMenuHover(x: i32, y: i32) void {
    if (!ctx_menu_visible) {
        ctx_menu_hover_index = -1;
        return;
    }
    
    // Check submenu hover
    if (ctx_submenu_visible) {
        const smh = submenuHeight();
        const smw: i32 = CTX_MENU_W;
        const anim_offset = @as(i32, @intFromFloat(@as(f32, @floatFromInt(smw)) * (1.0 - ctx_submenu_anim_progress)));
        if (x >= ctx_submenu_x + anim_offset and x < ctx_submenu_x + anim_offset + smw and
            y >= ctx_submenu_y and y < ctx_submenu_y + smh) {
            const rel_y = y - ctx_submenu_y - CTX_MENU_PAD;
            ctx_submenu_hover_index = @divTrunc(rel_y, CTX_ITEM_H);
            return;
        }
    }
    
    // Main menu hover
    if (x >= ctx_menu_x and x < ctx_menu_x + CTX_MENU_W and
        y >= ctx_menu_y and y < ctx_menu_y + ctxMenuHeight()) {
        const rel_y = y - ctx_menu_y - CTX_MENU_PAD;
        const idx = @divTrunc(rel_y, CTX_ITEM_H);
        if (idx >= 0 and @as(usize, @intCast(idx)) < ctx_menu_item_count) {
            ctx_menu_hover_index = idx;
            return;
        }
    }
    
    ctx_menu_hover_index = -1;
    ctx_submenu_hover_index = -1;
}

pub fn getExplorerContextMenuHoverItem() ?ContextMenuItem {
    if (ctx_menu_hover_index < 0 or @as(usize, @intCast(ctx_menu_hover_index)) >= ctx_menu_item_count) {
        return null;
    }
    return ctx_menu_items_buf[@as(usize, @intCast(ctx_menu_hover_index))];
}

pub fn getExplorerContextMenuClickResult() ?struct { action: []const u8, kind: ExplorerContextMenuKind } {
    if (ctx_menu_hover_index < 0) return null;
    if (@as(usize, @intCast(ctx_menu_hover_index)) >= ctx_menu_item_count) return null;
    
    const item = ctx_menu_items_buf[@as(usize, @intCast(ctx_menu_hover_index))];
    if (!item.enabled) return null;
    if (std.mem.eql(u8, item.label, "---")) return null;
    
    const result = .{ .action = item.label, .kind = ctx_menu_kind };
    hideExplorerContextMenu();
    return result;
}

// ── Context Menu Update ─────────────────────────────────────────────────────

pub fn updateExplorerContextMenuAnimation() void {
    // Submenu animation update handled in render
}
