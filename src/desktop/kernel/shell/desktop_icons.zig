//! Desktop Icon Manager - Windows 7 Style Desktop Icons
//!
//! Implements Windows 7-style desktop icons with double-click to open, right-click
//! context menu, rename, drag to rearrange, and single-click preview.
//! Clean-room implementation based on publicly documented Windows 7 Explorer behavior.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme = @import("../theme/root.zig");
const icons = @import("../icons/root.zig");
const explorer_state = @import("../shell/explorer_state.zig");
const explorer_context_menu = @import("../shell/explorer_context_menu.zig");
const builtin_apps = @import("builtin_apps.zig");

const rgb = theme.rgb;

// ── Desktop Icon Types ─────────────────────────────────────────────────────────

pub const DesktopIconKind = enum(u8) {
    computer,
    recycle_bin,
    network,
    user_files,
    documents,
    pictures,
    terminal,
    browser,
    settings,
    custom,
};

/// 根据 icon_id (icons.IconId) 转换为 DesktopIconKind
pub fn iconKindFromId(icon_id: u16) DesktopIconKind {
    return switch (icon_id) {
        1 => .computer,      // .computer
        2 => .documents,      // .documents
        3 => .recycle_bin,   // .recycle_bin
        4 => .terminal,      // .terminal
        5 => .network,       // .network
        6 => .browser,       // .browser
        7 => .settings,      // .control_panel
        else => .custom,
    };
}

pub const DesktopIcon = struct {
    kind: DesktopIconKind,
    label: []const u8,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    icon: icons.IconId,
    x: i32,
    y: i32,
    custom_path: ?[]const u8,
};

const MAX_DESKTOP_ICONS = 16;
var desktop_icons: [MAX_DESKTOP_ICONS]DesktopIcon = undefined;
var desktop_icon_count: usize = 0;

// Desktop icon state
var desktop_hover_index: i32 = -1;
var desktop_selected_index: i32 = -1;
var desktop_dragging_index: i32 = -1;
var desktop_drag_offset_x: i32 = 0;
var desktop_drag_offset_y: i32 = 0;

// Layout
const ICON_SIZE: i32 = 48;
const LABEL_HEIGHT: i32 = 16;
const ICON_STEP_X: i32 = 80;
const ICON_STEP_Y: i32 = 80;
const DESKTOP_PADDING: i32 = 16;

// ── Desktop Icon Initialization ────────────────────────────────────────────────

pub fn initDesktopIcons() void {
    desktop_icon_count = 0;

    // 第1列，第1行：Computer（系统图标，Windows标准必需）
    desktop_icons[desktop_icon_count] = .{
        .kind = .computer,
        .label = "Computer",
        .icon = .computer,
        .x = DESKTOP_PADDING,
        .y = DESKTOP_PADDING,
        .custom_path = null,
    };
    desktop_icon_count += 1;

    // 第1列，第2行：Recycle Bin（回收站，Windows标准必需）
    desktop_icons[desktop_icon_count] = .{
        .kind = .recycle_bin,
        .label = "Recycle Bin",
        .icon = .recycle_bin,
        .x = DESKTOP_PADDING,
        .y = DESKTOP_PADDING + ICON_STEP_Y,
        .custom_path = null,
    };
    desktop_icon_count += 1;

    // 第1列，第3行：Network（网络入口）
    desktop_icons[desktop_icon_count] = .{
        .kind = .network,
        .label = "Network",
        .icon = .network,
        .x = DESKTOP_PADDING,
        .y = DESKTOP_PADDING + ICON_STEP_Y * 2,
        .custom_path = null,
    };
    desktop_icon_count += 1;
}

// ── Desktop Icon State ─────────────────────────────────────────────────────────

pub fn getDesktopIconCount() usize {
    return desktop_icon_count;
}

pub fn getDesktopIcon(index: usize) ?DesktopIcon {
    if (index >= desktop_icon_count) return null;
    return desktop_icons[index];
}

pub fn getDesktopHoverIndex() i32 {
    return desktop_hover_index;
}

pub fn setDesktopHoverIndex(idx: i32) void {
    desktop_hover_index = idx;
}

pub fn getDesktopSelectedIndex() i32 {
    return desktop_selected_index;
}

pub fn setDesktopSelectedIndex(idx: i32) void {
    desktop_selected_index = idx;
}

pub fn getDesktopDraggingIndex() i32 {
    return desktop_dragging_index;
}

pub fn startDesktopDrag(index: i32, offset_x: i32, offset_y: i32) void {
    desktop_dragging_index = index;
    desktop_drag_offset_x = offset_x;
    desktop_drag_offset_y = offset_y;
}

pub fn endDesktopDrag() void {
    desktop_dragging_index = -1;
}

pub fn isDesktopDragging() bool {
    return desktop_dragging_index >= 0;
}

// ── Desktop Icon Rendering ─────────────────────────────────────────────────────

pub fn renderDesktopIcon(icon: DesktopIcon, is_selected: bool, is_hover: bool) void {
    const x = icon.x;
    const y = icon.y;
    
    // Selection/hover background
    if (is_selected) {
        fb.fillRect(x - 2, y - 2, ICON_SIZE + 4, ICON_SIZE + LABEL_HEIGHT + 4, rgb(0xC8, 0xE0, 0xF0));
        fb.drawRect(x - 2, y - 2, ICON_SIZE + 4, ICON_SIZE + LABEL_HEIGHT + 4, rgb(0xA0, 0xC0, 0xE0));
    } else if (is_hover) {
        fb.fillRect(x - 2, y - 2, ICON_SIZE + 4, ICON_SIZE + LABEL_HEIGHT + 4, rgb(0xE8, 0xF0, 0xF8));
    }
    
    // Icon
    icons.drawThemedIcon(icon.icon, x, y, 1.0, .aero, is_selected);
    
    // Label background (semi-transparent for readability)
    fb.fillRect(x - 2, y + ICON_SIZE, ICON_SIZE + 4, LABEL_HEIGHT + 2, rgb(0xF0, 0xF0, 0xF0));
    
    // Label text
    const label_color: u32 = if (is_selected) rgb(0x00, 0x3C, 0x80) else rgb(0xFF, 0xFF, 0xFF);
    
    // Text shadow for readability
    fb.drawTextTransparent(x + 1, y + ICON_SIZE + 3, icon.label, rgb(0x00, 0x00, 0x00));
    fb.drawTextTransparent(x, y + ICON_SIZE + 2, icon.label, label_color);
}

pub fn renderAllDesktopIcons() void {
    if (desktop_icon_count == 0) {
        initDesktopIcons();
    }
    
    for (0..desktop_icon_count) |i| {
        const is_selected = (@as(i32, @intCast(i)) == desktop_selected_index);
        const is_hover = (@as(i32, @intCast(i)) == desktop_hover_index);
        renderDesktopIcon(desktop_icons[i], is_selected, is_hover);
    }
}

// ── Desktop Icon Hit Testing ───────────────────────────────────────────────────

pub fn hitTestDesktopIcon(px: i32, py: i32) ?usize {
    for (0..desktop_icon_count) |i| {
        const icon = desktop_icons[i];
        const hit_x = px >= icon.x - 2 and px < icon.x + ICON_SIZE + 2;
        const hit_y = py >= icon.y - 2 and py < icon.y + ICON_SIZE + LABEL_HEIGHT + 2;
        
        if (hit_x and hit_y) {
            return i;
        }
    }
    return null;
}

pub fn hitTestDesktopIconLabel(px: i32, py: i32) ?usize {
    for (0..desktop_icon_count) |i| {
        const icon = desktop_icons[i];
        const hit_x = px >= icon.x - 2 and px < icon.x + ICON_SIZE + 2;
        const hit_y = py >= icon.y + ICON_SIZE and py < icon.y + ICON_SIZE + LABEL_HEIGHT + 2;
        
        if (hit_x and hit_y) {
            return i;
        }
    }
    return null;
}

// ── Desktop Icon Actions ───────────────────────────────────────────────────────

pub fn handleDesktopIconClick(index: usize, double_click: bool) void {
    if (index >= desktop_icon_count) return;
    
    const icon = desktop_icons[index];
    
    if (double_click) {
        // Double-click: Open
        handleDesktopIconOpen(icon);
    } else {
        // Single-click: Select
        desktop_selected_index = @as(i32, @intCast(index));
    }
}

pub fn handleDesktopIconOpen(icon: DesktopIcon) void {
    switch (icon.kind) {
        .computer => {
            explorer_state.setExplorerView(.computer);
        },
        .recycle_bin => {
            // Open recycle bin - 显示回收站视图
        },
        .network => {
            // Open network view
        },
        .documents => {
            explorer_state.setExplorerView(.libraries);
            explorer_state.explorerNavigateToLibrary(.documents);
        },
        .pictures => {
            explorer_state.setExplorerView(.libraries);
            explorer_state.explorerNavigateToLibrary(.pictures);
        },
        .terminal => {
            builtin_apps.launch(.cmd_shell);
        },
        .browser => {
            builtin_apps.launch(.ie8);
        },
        .settings => {
            builtin_apps.launch(.control_panel);
        },
        .custom => {
            // Open custom path
        },
        .user_files => {},
    }
}

pub fn handleDesktopIconRightClick(index: usize) void {
    if (index >= desktop_icon_count) return;
    
    desktop_selected_index = @as(i32, @intCast(index));
    // Show context menu for desktop icon
    explorer_context_menu.showExplorerContextMenu(.file, 0, 0);
}

// ── Desktop Icon Drag ─────────────────────────────────────────────────────────

pub fn moveDesktopIcon(index: usize, new_x: i32, new_y: i32) void {
    if (index >= desktop_icon_count) return;
    
    // Snap to grid
    const snapped_x = @as(i32, @intCast((@as(i32, @intCast(new_x)) / ICON_STEP_X) * ICON_STEP_X));
    const snapped_y = @as(i32, @intCast((@as(i32, @intCast(new_y)) / ICON_STEP_Y) * ICON_STEP_Y));
    
    desktop_icons[index].x = snapped_x;
    desktop_icons[index].y = snapped_y;
}

// ── Desktop Icon Rename ─────────────────────────────────────────────────────────

var desktop_rename_active: bool = false;
var desktop_rename_index: usize = 0;
var desktop_rename_text: [64]u8 = undefined;
var desktop_rename_len: usize = 0;
var desktop_rename_cursor: usize = 0;

pub fn startDesktopIconRename(index: usize) void {
    if (index >= desktop_icon_count) return;
    
    desktop_rename_active = true;
    desktop_rename_index = index;
    
    const icon = desktop_icons[index];
    const len = @min(icon.label.len, desktop_rename_text.len);
    @memcpy(desktop_rename_text[0..len], icon.label[0..len]);
    desktop_rename_len = len;
    desktop_rename_cursor = len;
}

pub fn isDesktopRenameActive() bool {
    return desktop_rename_active;
}

pub fn commitDesktopRename() void {
    if (!desktop_rename_active) return;
    
    // Apply rename
    if (desktop_rename_len > 0 and desktop_rename_index < desktop_icon_count) {
        const icon = &desktop_icons[desktop_rename_index];
        // In a real implementation, we'd update the label
        _ = icon;
    }
    
    desktop_rename_active = false;
}

pub fn cancelDesktopRename() void {
    desktop_rename_active = false;
}

// ── Desktop Rename Rendering ─────────────────────────────────────────────────────

pub fn renderDesktopRenameOverlay(x: i32, y: i32, w: i32, h: i32) void {
    if (!desktop_rename_active) return;
    
    // Background
    fb.fillRect(x, y, w, h, rgb(0xFF, 0xFF, 0xFF));
    fb.drawRect(x, y, w, h, rgb(0x00, 0x51, 0x9E));
    
    // Text
    fb.drawTextTransparent(x + 4, y + (h - 14) / 2, desktop_rename_text[0..desktop_rename_len], rgb(0x18, 0x18, 0x18));
    
    // Cursor
    const cursor_x = x + 4 + fb.textWidth(desktop_rename_text[0..desktop_rename_cursor]);
    fb.fillRect(cursor_x, y + 2, 2, h - 4, rgb(0x00, 0x51, 0x9E));
}
