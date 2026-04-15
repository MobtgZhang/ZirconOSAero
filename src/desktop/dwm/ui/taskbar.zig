// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// Taskbar - D3D10 渲染的任务栏组件
// 支持 Aero 玻璃效果、缩略图预览、开始按钮

const std = @import("std");
const dwm = @import("../root.zig");
const theme = @import("../config/theme.zig");
const compositor = @import("../compositor/compositor.zig");
const surface_mgr = @import("../compositor/surface_mgr.zig");

// ============================================================================
// 常量定义
// ============================================================================

pub const TASKBAR_HEIGHT: i32 = 40;
pub const START_BUTTON_WIDTH: i32 = 48;
pub const TASK_BUTTON_WIDTH: i32 = 140;
pub const TASK_BUTTON_HEIGHT: i32 = 32;
pub const TRAY_AREA_WIDTH: i32 = 180;
pub const SHOW_DESKTOP_WIDTH: i32 = 14;

// ============================================================================
// 任务栏按钮状态
// ============================================================================

pub const TaskButtonState = enum(u8) {
    normal,
    hovered,
    pressed,
    active,
};

pub const TaskButton = struct {
    surface_id: u32,
    title: []const u8,
    icon_id: u32,
    state: TaskButtonState,
    window_handle: u32,
    is_active: bool,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const ThumbnailPreview = struct {
    source_window: u32,
    preview_surface_id: u32,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    visible: bool,
};

// ============================================================================
// 任务栏状态
// ============================================================================

pub const TaskbarState = struct {
    surface_id: u32,
    start_button_hovered: bool,
    show_desktop_hovered: bool,
    auto_hide_enabled: bool,
    auto_hide_offset: i32,
    is_auto_hidden: bool,
    taskbar_height: i32,
};

var g_taskbar_state: TaskbarState = undefined;
var g_task_buttons: [64]TaskButton = undefined;
var g_task_button_count: usize = 0;
var g_thumbnails: [16]ThumbnailPreview = undefined;
var g_thumbnail_count: usize = 0;
var g_initialized: bool = false;

// ============================================================================
// 任务栏初始化
// ============================================================================

pub fn initTaskbar(screen_width: u32, screen_height: u32) void {
    if (g_initialized) return;

    // 创建任务栏表面
    g_taskbar_state.surface_id = surface_mgr.createSurface(screen_width, TASKBAR_HEIGHT, .{
        .has_alpha = true,
        .is_visible = true,
        .is_taskbar = true,
        .needs_blur = theme.isGlassEnabled(),
        .is_glass = theme.isGlassEnabled(),
    });

    // 设置位置
    surface_mgr.moveSurface(g_taskbar_state.surface_id, 0, @as(i32, @intCast(screen_height - TASKBAR_HEIGHT)));
    surface_mgr.setSurfaceZOrder(g_taskbar_state.surface_id, 100);

    // 初始化状态
    g_taskbar_state.start_button_hovered = false;
    g_taskbar_state.show_desktop_hovered = false;
    g_taskbar_state.auto_hide_enabled = false;
    g_taskbar_state.auto_hide_offset = 0;
    g_taskbar_state.is_auto_hidden = false;
    g_taskbar_state.taskbar_height = TASKBAR_HEIGHT;

    // 初始化按钮数组
    g_task_button_count = 0;
    g_thumbnail_count = 0;

    g_initialized = true;
}

pub fn deinitTaskbar() void {
    if (!g_initialized) return;

    _ = surface_mgr.destroySurface(g_taskbar_state.surface_id);
    g_initialized = false;
}

pub fn isInitialized() bool {
    return g_initialized;
}

// ============================================================================
// 任务按钮管理
// ============================================================================

pub fn addTaskButton(window_handle: u32, title: []const u8, icon_id: u32) void {
    if (g_task_button_count >= 64) return;

    const btn = &g_task_buttons[g_task_button_count];
    btn.* = .{
        .surface_id = 0,
        .title = title,
        .icon_id = icon_id,
        .state = .normal,
        .window_handle = window_handle,
        .is_active = false,
        .x = START_BUTTON_WIDTH + @as(i32, @intCast(g_task_button_count)) * TASK_BUTTON_WIDTH,
        .y = (TASKBAR_HEIGHT - TASK_BUTTON_HEIGHT) / 2,
        .width = TASK_BUTTON_WIDTH,
        .height = TASK_BUTTON_HEIGHT,
    };

    g_task_button_count += 1;
}

pub fn removeTaskButton(window_handle: u32) void {
    var i: usize = 0;
    while (i < g_task_button_count) {
        if (g_task_buttons[i].window_handle == window_handle) {
            // 移除按钮
            var j = i;
            while (j + 1 < g_task_button_count) : (j += 1) {
                g_task_buttons[j] = g_task_buttons[j + 1];
            }
            g_task_button_count -= 1;
            return;
        }
        i += 1;
    }
}

pub fn setActiveTask(window_handle: u32) void {
    for (0..g_task_button_count) |i| {
        g_task_buttons[i].is_active = (g_task_buttons[i].window_handle == window_handle);
    }
}

pub fn getTaskButtonCount() usize {
    return g_task_button_count;
}

pub fn getTaskButtons() []TaskButton {
    return g_task_buttons[0..g_task_button_count];
}

// ============================================================================
// 缩略图预览管理
// ============================================================================

pub fn showThumbnail(window_handle: u32, x: i32, y: i32) void {
    // 查找或创建缩略图
    var thumb: *ThumbnailPreview = null;
    for (0..g_thumbnail_count) |i| {
        if (g_thumbnails[i].source_window == window_handle) {
            thumb = &g_thumbnails[i];
            break;
        }
    }

    if (thumb == null and g_thumbnail_count < 16) {
        thumb = &g_thumbnails[g_thumbnail_count];
        g_thumbnail_count += 1;
    }

    if (thumb) |t| {
        t.source_window = window_handle;
        t.x = x;
        t.y = y;
        t.width = 200;
        t.height = 150;
        t.visible = true;
    }
}

pub fn hideThumbnail(window_handle: u32) void {
    for (0..g_thumbnail_count) |i| {
        if (g_thumbnails[i].source_window == window_handle) {
            g_thumbnails[i].visible = false;
            return;
        }
    }
}

pub fn getThumbnailCount() usize {
    return g_thumbnail_count;
}

pub fn getThumbnails() []ThumbnailPreview {
    return g_thumbnails[0..g_thumbnail_count];
}

// ============================================================================
// 输入处理
// ============================================================================

pub fn hitTest(px: i32, py: i32) ?enum { start_button, task_button, thumbnail, show_desktop, none } {
    const screen_size = compositor.getScreenSize();
    const taskbar_y = @as(i32, @intCast(screen_size.h)) - TASKBAR_HEIGHT;

    // 检查是否在任务栏范围内
    if (py < taskbar_y) return .none;

    // 检查开始按钮
    if (px >= 0 and px < START_BUTTON_WIDTH) {
        return .start_button;
    }

    // 检查显示桌面按钮
    if (px >= @as(i32, @intCast(screen_size.w)) - SHOW_DESKTOP_WIDTH) {
        return .show_desktop;
    }

    // 检查任务按钮
    for (0..g_task_button_count) |i| {
        const btn = g_task_buttons[i];
        if (px >= btn.x and px < btn.x + btn.width) {
            return .task_button;
        }
    }

    return .none;
}

pub fn onMouseMove(px: i32, py: i32) void {
    const result = hitTest(px, py);

    // 更新开始按钮悬停状态
    g_taskbar_state.start_button_hovered = (result == .start_button);
    g_taskbar_state.show_desktop_hovered = (result == .show_desktop);

    // 更新任务按钮悬停状态
    for (0..g_task_button_count) |i| {
        const btn = g_task_buttons[i];
        if (px >= btn.x and px < btn.x + btn.width and
            py >= btn.y and py < btn.y + btn.height) {
            g_task_buttons[i].state = .hovered;
        } else if (!g_task_buttons[i].is_active) {
            g_task_buttons[i].state = .normal;
        }
    }
}

pub fn onMouseLeave() void {
    g_taskbar_state.start_button_hovered = false;
    g_taskbar_state.show_desktop_hovered = false;

    for (0..g_task_button_count) |i| {
        if (!g_task_buttons[i].is_active) {
            g_task_buttons[i].state = .normal;
        }
    }
}

// ============================================================================
// 渲染
// ============================================================================

pub fn render() void {
    if (!g_initialized) return;

    // 渲染任务栏背景 (玻璃效果)
    if (theme.isGlassEnabled()) {
        // 任务栏使用玻璃效果
        compositor.setSurfaceGlass(g_taskbar_state.surface_id, true);
    }

    // 标记表面需要重绘
    if (surface_mgr.getSurface(g_taskbar_state.surface_id)) |sfc| {
        sfc.markFullDirty();
    }
}

pub fn getSurfaceId() u32 {
    return g_taskbar_state.surface_id;
}

// ============================================================================
// 自动隐藏
// ============================================================================

pub fn setAutoHide(enabled: bool) void {
    g_taskbar_state.auto_hide_enabled = enabled;
}

pub fn isAutoHideEnabled() bool {
    return g_taskbar_state.auto_hide_enabled;
}

pub fn showTaskbar() void {
    if (!g_taskbar_state.auto_hide_enabled) return;
    g_taskbar_state.is_auto_hidden = false;
    g_taskbar_state.auto_hide_offset = 0;
    surface_mgr.moveSurface(g_taskbar_state.surface_id, 0,
        @as(i32, @intCast(compositor.getScreenSize().h)) - TASKBAR_HEIGHT);
}

pub fn hideTaskbar() void {
    if (!g_taskbar_state.auto_hide_enabled) return;
    g_taskbar_state.is_auto_hidden = true;
    g_taskbar_state.auto_hide_offset = TASKBAR_HEIGHT;
    surface_mgr.moveSurface(g_taskbar_state.surface_id, 0,
        @as(i32, @intCast(compositor.getScreenSize().h)));
}