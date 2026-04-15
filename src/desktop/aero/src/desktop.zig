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

//! Aero Desktop Manager
//! Manages wallpaper, desktop icon grid, and right-click context menus.
//! Models Win7-style shortcuts (`.lnk` overlay) vs shell namespace icons.

const std = @import("std");
const mem = std.mem;
const theme = @import("theme.zig");

pub const DesktopIcon = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    grid_x: i32 = 0,
    grid_y: i32 = 0,
    icon_id: u16 = 0,
    /// True for shortcuts (small arrow overlay in compositors that support it)
    shortcut: bool = false,
    selected: bool = false,
    visible: bool = false,
};

const MAX_ICONS: usize = 128;
var icons: [MAX_ICONS]DesktopIcon = [_]DesktopIcon{.{}} ** MAX_ICONS;
var icon_count: usize = 0;

var context_menu_visible: bool = false;
var context_menu_x: i32 = 0;
var context_menu_y: i32 = 0;

var wallpaper_path: theme.WallpaperPath = .{};
var wallpaper_dirty: bool = true;

/// 图标大小设置
const IconSize = enum { small, medium, large };
var current_icon_size: IconSize = .medium;
var auto_arrange_icons: bool = true;
var align_to_grid: bool = true;

/// 拖拽状态
var dragging_icon: ?usize = null;
var drag_start_x: i32 = 0;
var drag_start_y: i32 = 0;
var drag_offset_x: i32 = 0;
var drag_offset_y: i32 = 0;

/// 回收站状态
var recycle_bin_full: bool = false;

/// 右键上下文菜单定义
const ContextMenuId = enum(u32) {
    open = 1,
    delete = 2,
    rename = 3,
    properties = 4,
    separator1 = 5,
    view_small_icons = 6,
    view_medium_icons = 7,
    view_large_icons = 8,
    separator2 = 9,
    sort_by_name = 10,
    sort_by_size = 11,
    sort_by_date_modified = 12,
    separator3 = 13,
    auto_arrange_icons = 14,
    align_to_grid = 15,
    separator4 = 16,
    new_folder = 17,
    new_shortcut = 18,
    refresh = 19,
    personalize = 20,
};

const ContextMenuItem = struct {
    name: []const u8,
    id: ContextMenuId,
    enabled: bool = true,
    checked: bool = false,
    separator: bool = false,
};

// 桌面空白处右键菜单
const desktop_context_menu = [_]ContextMenuItem{
    .{ .name = "View", .id = 0, .enabled = false },
    .{ .name = "Small icons", .id = .view_small_icons, .checked = false },
    .{ .name = "Medium icons", .id = .view_medium_icons, .checked = true },
    .{ .name = "Large icons", .id = .view_large_icons, .checked = false },
    .{ .name = "", .id = .separator1, .separator = true },
    .{ .name = "Sort by", .id = 0, .enabled = false },
    .{ .name = "Name", .id = .sort_by_name },
    .{ .name = "Size", .id = .sort_by_size },
    .{ .name = "Date modified", .id = .sort_by_date_modified },
    .{ .name = "", .id = .separator2, .separator = true },
    .{ .name = "Auto arrange icons", .id = .auto_arrange_icons, .checked = true },
    .{ .name = "Align icons to grid", .id = .align_to_grid, .checked = true },
    .{ .name = "", .id = .separator3, .separator = true },
    .{ .name = "New", .id = 0, .enabled = false },
    .{ .name = "Folder", .id = .new_folder },
    .{ .name = "Shortcut", .id = .new_shortcut },
    .{ .name = "", .id = .separator4, .separator = true },
    .{ .name = "Refresh", .id = .refresh },
    .{ .name = "Personalize", .id = .personalize },
};

// 图标右键菜单
const icon_context_menu = [_]ContextMenuItem{
    .{ .name = "Open", .id = .open },
    .{ .name = "Delete", .id = .delete },
    .{ .name = "Rename", .id = .rename },
    .{ .name = "", .id = .separator1, .separator = true },
    .{ .name = "Create shortcut", .id = .new_shortcut },
    .{ .name = "", .id = .separator2, .separator = true },
    .{ .name = "Properties", .id = .properties },
};

var clicked_icon_index: ?usize = null;

pub fn init() void {
    icon_count = 0;
    context_menu_visible = false;
    wallpaper_dirty = true;
    updateWallpaperPath();
    addDefaultIcons();
}

fn addDefaultIcons() void {
    // Windows 7 default shell namespace + common shortcuts
    addIcon("Computer", 0, 0, 1, false);
    addIcon("Recycle Bin", 0, 1, 3, false);
    addIcon("Documents", 0, 2, 2, false);
    addIcon("Network", 0, 3, 5, false);
    addIcon("Control Panel", 1, 0, 13, true);
    addIcon("Zircon Browser", 1, 1, 6, true);
    addIcon("Terminal", 1, 2, 4, true);
    addIcon("Settings", 1, 3, 7, true);
}

fn addIcon(name: []const u8, gx: i32, gy: i32, id: u16, shortcut: bool) void {
    if (icon_count >= MAX_ICONS) return;
    var ic = &icons[icon_count];
    const len = @min(name.len, 64);
    for (0..len) |i| {
        ic.name[i] = name[i];
    }
    ic.name_len = @intCast(len);
    ic.grid_x = gx;
    ic.grid_y = gy;
    ic.icon_id = id;
    ic.shortcut = shortcut;
    ic.visible = true;
    icon_count += 1;
}

pub fn getIcons() []const DesktopIcon {
    return icons[0..icon_count];
}

pub fn getIconCount() usize {
    return icon_count;
}

pub fn selectIcon(index: usize) void {
    deselectAll();
    if (index < icon_count) {
        icons[index].selected = true;
    }
}

pub fn deselectAll() void {
    for (&icons) |*ic| {
        ic.selected = false;
    }
}

/// 显示上下文菜单，如果点击了图标则显示图标菜单，否则显示桌面菜单
pub fn showContextMenu(x: i32, y: i32, clicked_icon: ?usize) void {
    context_menu_visible = true;
    context_menu_x = x;
    context_menu_y = y;
    clicked_icon_index = clicked_icon;
}

pub fn hideContextMenu() void {
    context_menu_visible = false;
}

pub fn isContextMenuVisible() bool {
    return context_menu_visible;
}

pub fn getContextMenuPos() struct { x: i32, y: i32 } {
    return .{ .x = context_menu_x, .y = context_menu_y };
}

pub fn getDesktopBackground() u32 {
    return theme.getActiveDesktopBg();
}

pub fn getDesktopBackgroundDefault() u32 {
    return theme.desktop_bg;
}

fn updateWallpaperPath() void {
    wallpaper_path = theme.getWallpaperForScheme(theme.getActiveScheme());
    wallpaper_dirty = true;
}

pub fn getWallpaperPath() []const u8 {
    return wallpaper_path.path[0..wallpaper_path.len];
}

pub fn isWallpaperDirty() bool {
    return wallpaper_dirty;
}

pub fn clearWallpaperDirty() void {
    wallpaper_dirty = false;
}

pub fn applyTheme(cs: theme.ColorScheme) void {
    theme.setActiveScheme(cs);
    updateWallpaperPath();
}

pub fn iconHitTest(click_x: i32, click_y: i32) ?usize {
    const grid_x_step = theme.Layout.icon_grid_x;
    const grid_y_step = theme.Layout.icon_grid_y;
    const icon_sz = theme.Layout.icon_size;
    const margin_x: i32 = 16;
    const margin_y: i32 = 16;

    for (icons[0..icon_count], 0..) |ic, i| {
        if (!ic.visible) continue;
        const ix = margin_x + ic.grid_x * grid_x_step;
        const iy = margin_y + ic.grid_y * grid_y_step;
        if (click_x >= ix and click_x < ix + icon_sz and
            click_y >= iy and click_y < iy + icon_sz + 16)
        {
            return i;
        }
    }
    return null;
}

pub fn removeIcon(index: usize) void {
    if (index >= icon_count) return;
    var i = index;
    while (i + 1 < icon_count) : (i += 1) {
        icons[i] = icons[i + 1];
    }
    icons[icon_count - 1] = .{};
    icon_count -= 1;
}

pub fn moveIcon(index: usize, new_gx: i32, new_gy: i32) void {
    if (index >= icon_count) return;
    icons[index].grid_x = new_gx;
    icons[index].grid_y = new_gy;
}

// ── 拖拽功能实现 ──

/// 开始拖拽图标
pub fn startDrag(index: usize, mouse_x: i32, mouse_y: i32) void {
    if (index >= icon_count) return;
    dragging_icon = index;
    drag_start_x = mouse_x;
    drag_start_y = mouse_y;

    const grid_x_step = theme.Layout.icon_grid_x;
    const grid_y_step = theme.Layout.icon_grid_y;
    const margin_x: i32 = 16;
    const margin_y: i32 = 16;
    const ic = &icons[index];

    const icon_x = margin_x + ic.grid_x * grid_x_step;
    const icon_y = margin_y + ic.grid_y * grid_y_step;
    drag_offset_x = mouse_x - icon_x;
    drag_offset_y = mouse_y - icon_y;
}

/// 更新拖拽位置
pub fn updateDrag(mouse_x: i32, mouse_y: i32) void {
    if (dragging_icon == null) return;
    const index = dragging_icon.?;

    const grid_x_step = theme.Layout.icon_grid_x;
    const grid_y_step = theme.Layout.icon_grid_y;
    const margin_x: i32 = 16;
    const margin_y: i32 = 16;

    // 计算新的实际位置
    const new_x = mouse_x - drag_offset_x - margin_x;
    const new_y = mouse_y - drag_offset_y - margin_y;

    // 如果对齐到网格，取网格位置
    if (align_to_grid) {
        // 手动实现四舍五入
        const new_gx = @divFloor(new_x + @divFloor(grid_x_step, 2), grid_x_step);
        const new_gy = @divFloor(new_y + @divFloor(grid_y_step, 2), grid_y_step);
        moveIcon(index, new_gx, new_gy);
    } else {
        // 自由位置（后续扩展支持）
        const new_gx = @divFloor(new_x, grid_x_step);
        const new_gy = @divFloor(new_y, grid_y_step);
        moveIcon(index, new_gx, new_gy);
    }
}

/// 结束拖拽
pub fn endDrag() void {
    dragging_icon = null;
    if (auto_arrange_icons) {
        arrangeIcons();
    }
    saveIconLayout();
}

/// 判断是否正在拖拽
pub fn isDragging() bool {
    return dragging_icon != null;
}

/// 获取正在拖拽的图标索引
pub fn getDraggingIcon() ?usize {
    return dragging_icon;
}

// ── 图标布局与显示设置 ──

/// 自动排列图标
pub fn arrangeIcons() void {
    var current_x: i32 = 0;
    var current_y: i32 = 0;
    // 后续可以实现排序逻辑，比如按名称、大小、类型等
    for (&icons[0..icon_count]) |*ic| {
        if (!ic.visible) continue;
        ic.grid_x = current_x;
        ic.grid_y = current_y;
        current_y += 1;
        // 假设桌面高度可以容纳10行图标，超过则换列
        if (current_y >= 10) {
            current_y = 0;
            current_x += 1;
        }
    }
}

/// 设置图标大小
pub fn setIconSize(size: IconSize) void {
    current_icon_size = size;
    // 后续需要通知渲染器更新图标大小
}

/// 获取当前图标大小
pub fn getIconSize() IconSize {
    return current_icon_size;
}

/// 设置自动排列图标
pub fn setAutoArrange(enable: bool) void {
    auto_arrange_icons = enable;
    if (enable) {
        arrangeIcons();
        saveIconLayout();
    }
}

/// 获取自动排列状态
pub fn getAutoArrange() bool {
    return auto_arrange_icons;
}

/// 设置对齐到网格
pub fn setAlignToGrid(enable: bool) void {
    align_to_grid = enable;
    if (enable) {
        // 重新对齐所有图标到网格
        arrangeIcons();
        saveIconLayout();
    }
}

/// 获取对齐到网格状态
pub fn getAlignToGrid() bool {
    return align_to_grid;
}

// ── 回收站功能 ──

/// 设置回收站状态
pub fn setRecycleBinFull(full: bool) void {
    recycle_bin_full = full;
    // 更新回收站图标ID
    for (&icons[0..icon_count]) |*ic| {
        if (ic.name_len == 11 and mem.eql(u8, ic.name[0..11], "Recycle Bin")) {
            ic.icon_id = if (full) 18 else 3; // 18是满的回收站图标ID，3是空的
            break;
        }
    }
}

/// 获取回收站状态
pub fn isRecycleBinFull() bool {
    return recycle_bin_full;
}

/// 清空回收站
pub fn emptyRecycleBin() void {
    setRecycleBinFull(false);
    // 后续实现实际删除文件逻辑
}

// ── 快捷方式功能 ─―

/// 创建快捷方式
pub fn createShortcut(name: []const u8, target_path: []const u8, icon_id: u16, grid_x: i32, grid_y: i32) bool {
    _ = target_path; // 后续实现目标路径存储
    addIcon(name, grid_x, grid_y, icon_id, true);
    saveIconLayout();
    return true;
}

/// 修改快捷方式目标
pub fn setShortcutTarget(index: usize, target_path: []const u8) bool {
    if (index >= icon_count or !icons[index].shortcut) return false;
    _ = target_path; // 后续实现目标路径存储
    return true;
}

// ── 布局持久化 ──

/// 保存图标布局到存储
pub fn saveIconLayout() void {
    // 后续实现将图标位置保存到注册表或配置文件
    // 格式可以是每个图标的名称、grid_x、grid_y、是否快捷方式等
}

/// 加载图标布局从存储
pub fn loadIconLayout() void {
    // 后续实现从配置文件加载图标位置
    // 如果加载失败则使用默认布局
}

/// 重命名图标
pub fn renameIcon(index: usize, new_name: []const u8) void {
    if (index >= icon_count) return;
    var ic = &icons[index];
    const len = @min(new_name.len, 63);
    @memcpy(&ic.name[0..len], new_name[0..len]);
    ic.name[len] = 0;
    ic.name_len = @intCast(len);
    saveIconLayout();
}

/// 获取当前显示的上下文菜单列表
pub fn getContextMenuItems() []const ContextMenuItem {
    if (clicked_icon_index != null) {
        return &icon_context_menu;
    } else {
        return &desktop_context_menu;
    }
}

/// 处理上下文菜单点击事件
pub fn handleContextMenuClick(menu_id: ContextMenuId) void {
    switch (menu_id) {
        .open => {
            // 打开选中的图标
            if (clicked_icon_index) |idx| {
                // 上层shell处理打开逻辑
                _ = idx;
            }
        },
        .delete => {
            // 删除选中的图标
            if (clicked_icon_index) |idx| {
                removeIcon(idx);
                saveIconLayout();
            }
        },
        .rename => {
            // 进入重命名状态
            if (clicked_icon_index) |idx| {
                // 上层shell处理重命名输入
                _ = idx;
            }
        },
        .properties => {
            // 打开图标属性窗口
            if (clicked_icon_index) |idx| {
                // 上层shell处理属性窗口显示
                _ = idx;
            }
        },
        .view_small_icons => {
            setIconSize(.small);
            // 更新菜单选中状态
            // 这里需要上层渲染器处理菜单状态更新
        },
        .view_medium_icons => {
            setIconSize(.medium);
        },
        .view_large_icons => {
            setIconSize(.large);
        },
        .sort_by_name => {
            // 按名称排序图标
            // 后续实现排序逻辑
            arrangeIcons();
            saveIconLayout();
        },
        .sort_by_size => {
            // 按大小排序图标
            arrangeIcons();
            saveIconLayout();
        },
        .sort_by_date_modified => {
            // 按修改日期排序图标
            arrangeIcons();
            saveIconLayout();
        },
        .auto_arrange_icons => {
            setAutoArrange(!getAutoArrange());
        },
        .align_to_grid => {
            setAlignToGrid(!getAlignToGrid());
        },
        .new_folder => {
            // 创建新文件夹
            addIcon("New Folder", 0, 0, 12, false);
            arrangeIcons();
            saveIconLayout();
        },
        .new_shortcut => {
            if (clicked_icon_index) |idx| {
                // 创建选中图标的快捷方式
                const ic = &icons[idx];
                createShortcut("Shortcut to " ++ ic.name[0..ic.name_len], "", ic.icon_id, 0, 0);
                arrangeIcons();
                saveIconLayout();
            } else {
                // 创建新的空白快捷方式
                createShortcut("New Shortcut", "", 12, 0, 0);
                arrangeIcons();
                saveIconLayout();
            }
        },
        .refresh => {
            // 刷新桌面
            loadIconLayout();
        },
        .personalize => {
            // 打开个性化设置
            // 上层shell处理打开个性化窗口
        },
        else => {},
    }
    hideContextMenu();
}
