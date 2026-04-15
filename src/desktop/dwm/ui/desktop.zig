// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// Desktop - D3D10 渲染的桌面组件
// 支持图标布局、右键菜单、壁纸

const std = @import("std");
const dwm = @import("../root.zig");
const theme = @import("../config/theme.zig");
const compositor = @import("../compositor/compositor.zig");
const surface_mgr = @import("../compositor/surface_mgr.zig");

// ============================================================================
// 常量定义
// ============================================================================

pub const ICON_SIZE: i32 = 48;
pub const ICON_TEXT_MARGIN: i32 = 4;
pub const ICON_SPACING_X: i32 = 80;
pub const ICON_SPACING_Y: i32 = 90;
pub const DESKTOP_MARGIN_TOP: i32 = 10;
pub const DESKTOP_MARGIN_LEFT: i32 = 10;

// ============================================================================
// 桌面图标
// ============================================================================

pub const DesktopIcon = struct {
    id: u32,
    name: []const u8,
    icon_id: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    selected: bool,
    double_clicked: bool,
};

pub const ContextMenuItem = struct {
    id: u32,
    text: []const u8,
    enabled: bool,
    separator_before: bool,
};

var g_desktop_icons: [32]DesktopIcon = undefined;
var g_icon_count: usize = 0;
var g_context_menu_items: [16]ContextMenuItem = undefined;
var g_context_menu_item_count: usize = 0;
var g_context_menu_visible: bool = false;
var g_context_menu_x: i32 = 0;
var g_context_menu_y: i32 = 0;
var g_initialized: bool = false;

// ============================================================================
// 桌面初始化
// ============================================================================

pub fn initDesktop(screen_width: u32, screen_height: u32) void {
    _ = screen_width;
    _ = screen_height;
    if (g_initialized) return;

    // 添加默认图标
    addDefaultIcons();

    // 初始化右键菜单
    initContextMenu();

    g_initialized = true;
}

pub fn deinitDesktop() void {
    if (!g_initialized) return;
    g_initialized = false;
}

pub fn isInitialized() bool {
    return g_initialized;
}

// ============================================================================
// 默认图标
// ============================================================================

fn addDefaultIcons() void {
    g_icon_count = 0;

    // 我的电脑
    addIcon(1, "我的电脑", 1);
    // 网络
    addIcon(2, "网络", 5);
    // 回收站
    addIcon(3, "回收站", 3);
    // 文档
    addIcon(4, "文档", 2);
    // 图片
    addIcon(5, "图片", 10);
    // 下载
    addIcon(6, "下载", 28);
}

fn addIcon(id: u32, name: []const u8, icon_id: u32) void {
    if (g_icon_count >= 32) return;

    const col = @as(i32, @intCast(g_icon_count % 4));
    const row = @as(i32, @intCast(g_icon_count / 4));

    const icon = &g_desktop_icons[g_icon_count];
    icon.* = .{
        .id = id,
        .name = name,
        .icon_id = icon_id,
        .x = DESKTOP_MARGIN_LEFT + col * ICON_SPACING_X,
        .y = DESKTOP_MARGIN_TOP + row * ICON_SPACING_Y,
        .width = ICON_SIZE,
        .height = ICON_SIZE,
        .selected = false,
        .double_clicked = false,
    };

    g_icon_count += 1;
}

// ============================================================================
// 右键菜单
// ============================================================================

fn initContextMenu() void {
    g_context_menu_item_count = 0;

    addContextMenuItem(1, "查看", true, false);
    addContextMenuItem(2, "排序方式", true, false);
    addContextMenuItem(3, "刷新", true, false);
    addContextMenuItem(100, "", true, true); // 分隔符
    addContextMenuItem(4, "个性化", true, false);
    addContextMenuItem(100, "", true, true); // 分隔符
    addContextMenuItem(5, "新建文件夹", true, false);
    addContextMenuItem(6, "新建文本文档", true, false);
}

fn addContextMenuItem(id: u32, text: []const u8, enabled: bool, separator_before: bool) void {
    if (g_context_menu_item_count >= 16) return;

    const item = &g_context_menu_items[g_context_menu_item_count];
    item.* = .{
        .id = id,
        .text = text,
        .enabled = enabled,
        .separator_before = separator_before,
    };

    g_context_menu_item_count += 1;
}

pub fn showContextMenu(x: i32, y: i32) void {
    g_context_menu_visible = true;
    g_context_menu_x = x;
    g_context_menu_y = y;
}

pub fn hideContextMenu() void {
    g_context_menu_visible = false;
}

pub fn isContextMenuVisible() bool {
    return g_context_menu_visible;
}

// ============================================================================
// 图标管理
// ============================================================================

pub fn addIconItem(id: u32, name: []const u8, icon_id: u32, x: i32, y: i32) void {
    if (g_icon_count >= 32) return;

    const icon = &g_desktop_icons[g_icon_count];
    icon.* = .{
        .id = id,
        .name = name,
        .icon_id = icon_id,
        .x = x,
        .y = y,
        .width = ICON_SIZE,
        .height = ICON_SIZE,
        .selected = false,
        .double_clicked = false,
    };

    g_icon_count += 1;
}

pub fn removeIcon(id: u32) void {
    var i: usize = 0;
    while (i < g_icon_count) {
        if (g_desktop_icons[i].id == id) {
            var j = i;
            while (j + 1 < g_icon_count) : (j += 1) {
                g_desktop_icons[j] = g_desktop_icons[j + 1];
            }
            g_icon_count -= 1;
            return;
        }
        i += 1;
    }
}

pub fn selectIcon(id: u32) void {
    for (0..g_icon_count) |i| {
        g_desktop_icons[i].selected = (g_desktop_icons[i].id == id);
    }
}

pub fn clearSelection() void {
    for (0..g_icon_count) |i| {
        g_desktop_icons[i].selected = false;
    }
}

pub fn getIconCount() usize {
    return g_icon_count;
}

pub fn getIcons() []DesktopIcon {
    return g_desktop_icons[0..g_icon_count];
}

// ============================================================================
// 输入处理
// ============================================================================

pub fn hitTestIcon(px: i32, py: i32) ?usize {
    // 从下往上检测（后绘制的图标在上层）
    var i: usize = g_icon_count;
    while (i > 0) {
        i -= 1;
        const icon = g_desktop_icons[i];
        if (px >= icon.x and px < icon.x + ICON_SPACING_X and
            py >= icon.y and py < icon.y + ICON_SPACING_Y) {
            return i;
        }
    }
    return null;
}

pub fn onMouseMove(px: i32, py: i32) void {
    _ = hitTestIcon(px, py);
}

pub fn onClick(px: i32, py: i32) ?u32 {
    if (g_context_menu_visible) {
        // 检查是否点击右键菜单
        const menu_item = hitTestContextMenu(px, py);
        if (menu_item) |item| {
            return item.id;
        }
        hideContextMenu();
        return null;
    }

    // 检查是否点击图标
    if (hitTestIcon(px, py)) |idx| {
        selectIcon(g_desktop_icons[idx].id);
        return g_desktop_icons[idx].id;
    }

    // 点击空白区域，取消选择
    clearSelection();
    return null;
}

pub fn onDoubleClick(px: i32, py: i32) ?u32 {
    if (hitTestIcon(px, py)) |idx| {
        g_desktop_icons[idx].double_clicked = true;
        return g_desktop_icons[idx].id;
    }
    return null;
}

pub fn onRightClick(px: i32, py: i32) void {
    if (hitTestIcon(px, py)) |idx| {
        selectIcon(g_desktop_icons[idx].id);
    }
    showContextMenu(px, py);
}

pub fn hitTestContextMenu(px: i32, py: i32) ?ContextMenuItem {
    if (!g_context_menu_visible) return null;

    const menu_item_height: i32 = 24;
    const menu_width: i32 = 160;

    if (px >= g_context_menu_x and px < g_context_menu_x + menu_width and
        py >= g_context_menu_y and py < g_context_menu_y + @as(i32, @intCast(g_context_menu_item_count)) * menu_item_height) {
        const idx = @as(usize, @intCast((py - g_context_menu_y) / menu_item_height));
        if (idx < g_context_menu_item_count) {
            return g_context_menu_items[idx];
        }
    }

    return null;
}

// ============================================================================
// 布局
// ============================================================================

pub fn autoArrange() void {
    for (0..g_icon_count) |i| {
        const col = @as(i32, @intCast(i % 4));
        const row = @as(i32, @intCast(i / 4));

        g_desktop_icons[i].x = DESKTOP_MARGIN_LEFT + col * ICON_SPACING_X;
        g_desktop_icons[i].y = DESKTOP_MARGIN_TOP + row * ICON_SPACING_Y;
    }
}

pub fn alignToGrid() void {
    autoArrange();
}

// ============================================================================
// 渲染
// ============================================================================

pub fn render() void {
    if (!g_initialized) return;

    // 桌面背景使用主题颜色
    // 壁纸渲染在 compositor 层面处理
}

pub fn getWallpaperRect(screen_width: u32, screen_height: u32) struct { x: i32, y: i32, w: i32, h: i32 } {
    _ = screen_width;
    _ = screen_height;
    return .{
        .x = 0,
        .y = 0,
        .w = @intCast(compositor.getScreenSize().w),
        .h = @intCast(compositor.getScreenSize().h),
    };
}