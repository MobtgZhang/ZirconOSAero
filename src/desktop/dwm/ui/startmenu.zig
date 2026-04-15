// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// StartMenu - D3D10 渲染的开始菜单组件
// 支持 Aero 玻璃效果、动画、搜索框

const std = @import("std");
const dwm = @import("../root.zig");
const theme = @import("../config/theme.zig");
const compositor = @import("../compositor/compositor.zig");
const surface_mgr = @import("../compositor/surface_mgr.zig");

// 导入 taskbar 常量
const TASKBAR_HEIGHT: i32 = 40;

// ============================================================================
// 常量定义
// ============================================================================

pub const STARTMENU_WIDTH: i32 = 380;
pub const STARTMENU_HEIGHT: i32 = 480;
pub const SEARCH_BOX_HEIGHT: i32 = 28;
pub const PROGRAM_ITEM_HEIGHT: i32 = 40;
pub const POWER_BUTTON_SIZE: i32 = 32;

// ============================================================================
// 开始菜单状态
// ============================================================================

pub const MenuItemType = enum(u8) {
    program,
    folder,
    file,
    separator,
};

pub const MenuItem = struct {
    id: u32,
    name: []const u8,
    icon_id: u32,
    item_type: MenuItemType,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    hovered: bool,
};

pub const AnimationState = enum(u8) {
    closed,
    opening,
    open,
    closing,
};

pub const PowerAction = enum(u8) {
    shutdown,
    restart,
    sleep,
    lock,
};

pub const StartMenuState = struct {
    surface_id: u32,
    visible: bool,
    animation_state: AnimationState,
    animation_progress: f32,
    x: i32,
    y: i32,
    search_text: [128]u8,
    search_text_len: usize,
};

var g_startmenu_state: StartMenuState = undefined;
var g_menu_items: [32]MenuItem = undefined;
var g_menu_item_count: usize = 0;
var g_initialized: bool = false;
var g_animation_start_time: u64 = 0;

// ============================================================================
// 开始菜单初始化
// ============================================================================

pub fn initStartMenu() void {
    if (g_initialized) return;

    // 创建开始菜单表面
    g_startmenu_state.surface_id = surface_mgr.createSurface(STARTMENU_WIDTH, STARTMENU_HEIGHT, .{
        .has_alpha = true,
        .is_visible = false,
        .needs_blur = theme.isGlassEnabled(),
        .is_glass = theme.isGlassEnabled(),
    });

    // 初始化状态
    g_startmenu_state.visible = false;
    g_startmenu_state.animation_state = .closed;
    g_startmenu_state.animation_progress = 0.0;
    g_startmenu_state.search_text_len = 0;
    @memset(&g_startmenu_state.search_text, 0);

    // 添加默认菜单项
    addDefaultItems();

    g_initialized = true;
}

pub fn deinitStartMenu() void {
    if (!g_initialized) return;

    _ = surface_mgr.destroySurface(g_startmenu_state.surface_id);
    g_initialized = false;
}

pub fn isInitialized() bool {
    return g_initialized;
}

// ============================================================================
// 默认菜单项
// ============================================================================

fn addDefaultItems() void {
    g_menu_item_count = 0;

    // 用户文件夹
    addMenuItem(1, "文档", 2, .folder);
    addMenuItem(2, "图片", 10, .folder);
    addMenuItem(3, "音乐", 11, .folder);
    addMenuItem(4, "视频", 31, .folder);
    addMenuItem(5, "下载", 28, .folder);

    // 系统工具
    addMenuItem(10, "计算机", 1, .program);
    addMenuItem(11, "控制面板", 13, .program);
    addMenuItem(12, "设置", 7, .program);
    addMenuItem(13, "记事本", 9, .program);
    addMenuItem(14, "终端", 4, .program);
    addMenuItem(15, "浏览器", 6, .program);

    // 分隔符
    addMenuItem(100, "", 0, .separator);
}

fn addMenuItem(id: u32, name: []const u8, icon_id: u32, item_type: MenuItemType) void {
    if (g_menu_item_count >= 32) return;

    const item = &g_menu_items[g_menu_item_count];
    const y_offset = @as(i32, @intCast(g_menu_item_count)) * PROGRAM_ITEM_HEIGHT + SEARCH_BOX_HEIGHT + 10;

    item.* = .{
        .id = id,
        .name = name,
        .icon_id = icon_id,
        .item_type = item_type,
        .x = 0,
        .y = y_offset,
        .width = STARTMENU_WIDTH - 20,
        .height = PROGRAM_ITEM_HEIGHT,
        .hovered = false,
    };

    g_menu_item_count += 1;
}

// ============================================================================
// 显示/隐藏
// ============================================================================

pub fn show() void {
    if (!g_initialized or g_startmenu_state.visible) return;

    g_startmenu_state.visible = true;
    g_startmenu_state.animation_state = .opening;
    g_startmenu_state.animation_progress = 0.0;
    g_animation_start_time = getCurrentTimeMs();

    // 计算位置 (左下角，开始按钮上方)
    const screen_size = compositor.getScreenSize();
    g_startmenu_state.x = 0;
    g_startmenu_state.y = @as(i32, @intCast(screen_size.h)) - STARTMENU_HEIGHT - TASKBAR_HEIGHT;

    surface_mgr.moveSurface(g_startmenu_state.surface_id, g_startmenu_state.x, g_startmenu_state.y);
    surface_mgr.setSurfaceVisible(g_startmenu_state.surface_id, true);
    surface_mgr.setSurfaceZOrder(g_startmenu_state.surface_id, 200);
}

pub fn hide() void {
    if (!g_initialized or !g_startmenu_state.visible) return;

    g_startmenu_state.animation_state = .closing;
    g_startmenu_state.animation_progress = 1.0;
    g_animation_start_time = getCurrentTimeMs();
}

pub fn toggle() void {
    if (g_startmenu_state.visible) {
        hide();
    } else {
        show();
    }
}

pub fn isVisible() bool {
    return g_startmenu_state.visible;
}

// ============================================================================
// 搜索功能
// ============================================================================

pub fn handleSearchInput(c: u8) void {
    if (g_startmenu_state.search_text_len < 127) {
        g_startmenu_state.search_text[g_startmenu_state.search_text_len] = c;
        g_startmenu_state.search_text_len += 1;
        g_startmenu_state.search_text[g_startmenu_state.search_text_len] = 0;
    }
}

pub fn clearSearch() void {
    g_startmenu_state.search_text_len = 0;
    @memset(&g_startmenu_state.search_text, 0);
}

pub fn getSearchText() []const u8 {
    return g_startmenu_state.search_text[0..g_startmenu_state.search_text_len];
}

// ============================================================================
// 电源按钮
// ============================================================================

pub fn handlePowerButton(action: PowerAction) void {
    switch (action) {
        .shutdown => {
            // 关机
        },
        .restart => {
            // 重启
        },
        .sleep => {
            // 睡眠
        },
        .lock => {
            // 锁屏
        },
    }
}

// ============================================================================
// 输入处理
// ============================================================================

pub fn hitTest(px: i32, py: i32) ?usize {
    const abs_x = px - g_startmenu_state.x;
    const abs_y = py - g_startmenu_state.y;

    for (0..g_menu_item_count) |i| {
        const item = g_menu_items[i];
        if (abs_x >= item.x and abs_x < item.x + item.width and
            abs_y >= item.y and abs_y < item.y + item.height) {
            return i;
        }
    }

    return null;
}

pub fn onMouseMove(px: i32, py: i32) void {
    if (hitTest(px, py)) |idx| {
        for (0..g_menu_item_count) |i| {
            g_menu_items[i].hovered = (i == idx);
        }
    } else {
        for (0..g_menu_item_count) |i| {
            g_menu_items[i].hovered = false;
        }
    }
}

pub fn onMouseLeave() void {
    for (0..g_menu_item_count) |i| {
        g_menu_items[i].hovered = false;
    }
}

pub fn onClick(px: i32, py: i32) ?u32 {
    if (hitTest(px, py)) |idx| {
        return g_menu_items[idx].id;
    }
    return null;
}

// ============================================================================
// 动画更新
// ============================================================================

pub fn updateAnimations() void {
    if (g_startmenu_state.animation_state == .closed or
        g_startmenu_state.animation_state == .open) {
        return;
    }

    const now = getCurrentTimeMs();
    const elapsed = now - g_animation_start_time;
    const duration: u64 = 200; // 动画持续时间

    switch (g_startmenu_state.animation_state) {
        .opening => {
            g_startmenu_state.animation_progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(duration)));
            if (g_startmenu_state.animation_progress >= 1.0) {
                g_startmenu_state.animation_state = .open;
            }
        },
        .closing => {
            g_startmenu_state.animation_progress = @max(0.0, 1.0 - @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(duration)));
            if (g_startmenu_state.animation_progress <= 0.0) {
                g_startmenu_state.animation_state = .closed;
                g_startmenu_state.visible = false;
                surface_mgr.setSurfaceVisible(g_startmenu_state.surface_id, false);
            }
        },
        else => {},
    }
}

// ============================================================================
// 渲染
// ============================================================================

pub fn render() void {
    if (!g_initialized) return;

    updateAnimations();

    // 更新表面位置和透明度
    if (surface_mgr.getSurface(g_startmenu_state.surface_id)) |sfc| {
        sfc.markFullDirty();
        sfc.alpha = @as(u8, @intFromFloat(g_startmenu_state.animation_progress * 255.0));
    }
}

pub fn getSurfaceId() u32 {
    return g_startmenu_state.surface_id;
}

// ============================================================================
// 工具函数
// ============================================================================

fn getCurrentTimeMs() u64 {
    return @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))) / 1_000_000;
}