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
var desktop_icons_initialized: bool = false;

/// 显式初始化所有桌面图标数组元素
fn initDesktopIconsArray() void {
    if (desktop_icons_initialized) return;
    for (&desktop_icons) |*icon| {
        icon.* = .{
            .kind = .custom,
            .label = "",
            .name = [_]u8{0} ** 64,
            .name_len = 0,
            .icon = .computer,
            .x = 0,
            .y = 0,
            .custom_path = null,
        };
    }
    desktop_icons_initialized = true;
}

// Desktop icon state
var desktop_hover_index: i32 = -1;
var desktop_selected_index: i32 = -1;
var desktop_dragging_index: i32 = -1;
var desktop_drag_offset_x: i32 = 0;
var desktop_drag_offset_y: i32 = 0;
var desktop_focused: bool = false;

// Hover enhancement state
var desktop_hover_start_tick: u32 = 0;  // 悬停开始时间
var desktop_hover_tick: u32 = 0;        // 当前tick
const HOVER_DELAY_TICKS: u32 = 5;        // 悬停延迟（帧数）
const HOVER_ANIM_TICKS: u32 = 3;        // 悬停动画持续时间

// Layout
const ICON_SIZE: i32 = 48;
const LABEL_HEIGHT: i32 = 16;
const ICON_STEP_X: i32 = 80;
const ICON_STEP_Y: i32 = 80;
const DESKTOP_PADDING: i32 = 16;

/// 获取桌面图标网格的列数（根据屏幕宽度动态计算）
fn getDesktopIconColumnCount() i32 {
    const screen_w = fb.getWidth();
    return @max(1, @as(i32, @intCast((screen_w - 2 * DESKTOP_PADDING) / ICON_STEP_X)));
}

/// 检查桌面是否有焦点（用于键盘导航）
pub fn isDesktopFocused() bool {
    return desktop_focused;
}

/// 设置桌面焦点状态
pub fn setDesktopFocused(focused: bool) void {
    desktop_focused = focused;
}

/// 键盘导航：向上移动
pub fn navigateUp() void {
    if (desktop_icon_count == 0) return;

    const col_count = getDesktopIconColumnCount();
    if (desktop_selected_index < 0) {
        desktop_selected_index = 0;
        return;
    }

    const current_idx = @as(i32, @intCast(desktop_selected_index));
    const current_col = current_idx % col_count;
    const current_row = current_idx / col_count;

    if (current_row > 0) {
        const new_row = current_row - 1;
        const new_index = new_row * col_count + current_col;
        if (new_index < @as(i32, @intCast(desktop_icon_count))) {
            desktop_selected_index = new_index;
        } else {
            desktop_selected_index = @min(
                @as(i32, @intCast(desktop_icon_count)) - 1,
                (new_row + 1) * col_count - 1
            );
        }
    } else {
        const last_row = (@as(i32, @intCast(desktop_icon_count)) - 1) / col_count;
        const max_col_in_last_row = @as(i32, @intCast(desktop_icon_count)) - last_row * col_count - 1;
        const target_col = @min(current_col, max_col_in_last_row);
        desktop_selected_index = last_row * col_count + target_col;
    }
}

/// 键盘导航：向下移动
pub fn navigateDown() void {
    if (desktop_icon_count == 0) return;

    const col_count = getDesktopIconColumnCount();
    if (desktop_selected_index < 0) {
        desktop_selected_index = 0;
        return;
    }

    const current_idx = @as(i32, @intCast(desktop_selected_index));
    const current_col = current_idx % col_count;
    const current_row = current_idx / col_count;
    const last_row = (@as(i32, @intCast(desktop_icon_count)) - 1) / col_count;

    if (current_row < last_row) {
        const new_row = current_row + 1;
        const new_index = new_row * col_count + current_col;
        if (new_index < @as(i32, @intCast(desktop_icon_count))) {
            desktop_selected_index = new_index;
        } else {
            desktop_selected_index = @as(i32, @intCast(desktop_icon_count)) - 1;
        }
    } else {
        desktop_selected_index = current_col;
    }
}

/// 键盘导航：向左移动
pub fn navigateLeft() void {
    if (desktop_icon_count == 0) return;

    const col_count = getDesktopIconColumnCount();
    if (desktop_selected_index < 0) {
        desktop_selected_index = 0;
        return;
    }

    const current_idx = @as(i32, @intCast(desktop_selected_index));
    const current_col = current_idx % col_count;
    const current_row = current_idx / col_count;

    if (current_col > 0) {
        desktop_selected_index -= 1;
    } else {
        const max_col_in_row = @min(col_count - 1, @as(i32, @intCast(desktop_icon_count)) - current_row * col_count - 1);
        desktop_selected_index = current_row * col_count + max_col_in_row;
    }
}

/// 键盘导航：向右移动
pub fn navigateRight() void {
    if (desktop_icon_count == 0) return;

    const col_count = getDesktopIconColumnCount();
    if (desktop_selected_index < 0) {
        desktop_selected_index = 0;
        return;
    }

    const current_idx = @as(i32, @intCast(desktop_selected_index));
    const current_col = current_idx % col_count;
    const current_row = current_idx / col_count;
    const max_col_in_row = @min(col_count - 1, @as(i32, @intCast(desktop_icon_count)) - current_row * col_count - 1);

    if (current_col < max_col_in_row) {
        desktop_selected_index += 1;
    } else {
        desktop_selected_index = current_row * col_count;
    }
}

/// 打开选中的桌面图标
pub fn openSelected() void {
    const idx = @as(usize, @intCast(desktop_selected_index));
    if (idx < desktop_icon_count) {
        handleDesktopIconOpen(desktop_icons[idx]);
    }
}

/// 清除选中状态
pub fn clearSelection() void {
    desktop_selected_index = -1;
}

// ── Desktop Icon Initialization ────────────────────────────────────────────────

pub fn initDesktopIcons() void {
    initDesktopIconsArray();
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

// ── Desktop Icon Hover Enhancement ─────────────────────────────────────────────

/// 更新悬停状态 - 每帧调用
pub fn updateDesktopHover(new_hover_index: i32) void {
    if (new_hover_index != desktop_hover_index) {
        // 悬停目标改变，重置计时器
        desktop_hover_index = new_hover_index;
        if (new_hover_index >= 0) {
            desktop_hover_start_tick = desktop_hover_tick;
        }
    }
    // 增加tick计数
    desktop_hover_tick +%= 1;
}

/// 获取悬停是否有效（延迟后生效）
pub fn isHoverEffective() bool {
    if (desktop_hover_index < 0) return false;
    return (desktop_hover_tick - desktop_hover_start_tick) >= HOVER_DELAY_TICKS;
}

/// 获取悬停动画进度 (0.0 - 1.0)
pub fn getHoverAnimProgress() f32 {
    if (desktop_hover_index < 0) return 0.0;
    const elapsed = desktop_hover_tick - desktop_hover_start_tick;
    if (elapsed < HOVER_DELAY_TICKS) return 0.0;
    if (elapsed >= HOVER_DELAY_TICKS + HOVER_ANIM_TICKS) return 1.0;
    return @as(f32, @floatFromInt(elapsed - HOVER_DELAY_TICKS)) / @as(f32, @floatFromInt(HOVER_ANIM_TICKS));
}

/// 获取悬停透明度 (用于延迟显示)
pub fn getHoverAlpha() u8 {
    if (!isHoverEffective()) return 0;
    const progress = getHoverAnimProgress();
    return @as(u8, @intFromFloat(progress * @as(f32, 255.0)));
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
        // 悬停效果：带有透明度的背景
        const hover_alpha = getHoverAlpha();
        if (hover_alpha > 0) {
            // 绘制带有透明度的悬停背景
            const hover_color = blendColors(rgb(0xE8, 0xF0, 0xF8), rgb(0x00, 0x00, 0x00), hover_alpha);
            fb.fillRect(x - 2, y - 2, ICON_SIZE + 4, ICON_SIZE + LABEL_HEIGHT + 4, hover_color);

            // 悬停时有柔和的选择框
            const anim_progress = getHoverAnimProgress();
            const border_alpha = @as(u8, @intFromFloat(anim_progress * 180.0));
            const border_color = blendColors(rgb(0x40, 0x80, 0xC0), rgb(0x00, 0x00, 0x00), border_alpha);
            fb.drawRect(x - 2, y - 2, ICON_SIZE + 4, ICON_SIZE + LABEL_HEIGHT + 4, border_color);
        }
    }

    // Icon - 悬停时轻微放大
    const icon_scale: f32 = if (is_hover and isHoverEffective()) 1.05 else 1.0;
    const icon_offset_x: i32 = if (is_hover and isHoverEffective()) -1 else 0;
    const icon_offset_y: i32 = if (is_hover and isHoverEffective()) -1 else 0;
    icons.drawThemedIcon(icon.icon, x + icon_offset_x, y + icon_offset_y, icon_scale, .aero, is_selected);

    // Label background (semi-transparent for readability)
    fb.fillRect(x - 2, y + ICON_SIZE, ICON_SIZE + 4, LABEL_HEIGHT + 2, rgb(0xF0, 0xF0, 0xF0));

    // Label text
    const label_color: u32 = if (is_selected) rgb(0x00, 0x3C, 0x80) else if (is_hover and isHoverEffective()) rgb(0xFF, 0xFF, 0xFF) else rgb(0xFF, 0xFF, 0xFF);

    // Text shadow for readability
    fb.drawTextTransparent(x + 1, y + ICON_SIZE + 3, icon.label, rgb(0x00, 0x00, 0x00));
    fb.drawTextTransparent(x, y + ICON_SIZE + 2, icon.label, label_color);

    // 悬停时显示Tooltip（名称预览）
    if (is_hover and isHoverEffective()) {
        renderIconTooltip(icon.label, x, y);
    }
}

/// 简单的颜色混合函数
fn blendColors(color1: u32, color2: u32, alpha: u8) u32 {
    const a = @as(f32, @floatFromInt(alpha)) / 255.0;
    const inv_a = 1.0 - a;

    const r1 = @as(u8, @truncate(color1 >> 16));
    const g1 = @as(u8, @truncate(color1 >> 8));
    const b1 = @as(u8, @truncate(color1));

    const r2 = @as(u8, @truncate(color2 >> 16));
    const g2 = @as(u8, @truncate(color2 >> 8));
    const b2 = @as(u8, @truncate(color2));

    const r = @as(u8, @intFromFloat(@as(f32, @floatFromInt(r1)) * inv_a + @as(f32, @floatFromInt(r2)) * a));
    const g = @as(u8, @intFromFloat(@as(f32, @floatFromInt(g1)) * inv_a + @as(f32, @floatFromInt(g2)) * a));
    const b = @as(u8, @intFromFloat(@as(f32, @floatFromInt(b1)) * inv_a + @as(f32, @floatFromInt(b2)) * a));

    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

/// 在图标下方绘制Tooltip
fn renderIconTooltip(label: []const u8, icon_x: i32, icon_y: i32) void {
    const tooltip_y = icon_y + ICON_SIZE + LABEL_HEIGHT + 4;
    const tooltip_text_w = fb.textWidth(label);
    const tooltip_w = tooltip_text_w + 16;
    const tooltip_h = 20;

    // 居中对齐
    const tooltip_x = icon_x + (ICON_SIZE - tooltip_w) / 2;

    // Tooltip背景
    fb.fillRect(tooltip_x, tooltip_y, tooltip_w, tooltip_h, rgb(0xFF, 0xFF, 0xEE));
    fb.drawRect(tooltip_x, tooltip_y, tooltip_w, tooltip_h, rgb(0x80, 0x80, 0x60));

    // Tooltip文本
    fb.drawTextTransparent(tooltip_x + 8, tooltip_y + 4, label, rgb(0x20, 0x20, 0x20));
}

pub fn renderAllDesktopIcons() void {
    if (!desktop_icons_initialized) initDesktopIcons();
    
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
