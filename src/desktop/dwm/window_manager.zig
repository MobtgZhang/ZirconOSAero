// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// Window Manager - D3D10 DWM 的窗口管理器
// 支持窗口创建、销毁、移动、缩放、Aero Snap 等功能

const std = @import("std");
const dwm = @import("root.zig");
const compositor = @import("compositor/compositor.zig");
const surface_mgr = @import("compositor/surface_mgr.zig");
const theme = @import("config/theme.zig");

// ============================================================================
// 常量定义
// ============================================================================

pub const MAX_WINDOWS: usize = 64;
pub const SNAP_EDGE_THRESHOLD: i32 = 10;
pub const SHAKE_THRESHOLD: i32 = 15;
pub const SHAKE_COUNT_THRESHOLD: u32 = 5;
pub const ANIMATION_DURATION_MS: u64 = 250;
pub const RESIZE_BORDER_WIDTH: i32 = 8;
pub const MIN_WINDOW_WIDTH: i32 = 100;
pub const MIN_WINDOW_HEIGHT: i32 = 100;

// ============================================================================
// 窗口状态
// ============================================================================

pub const WindowState = enum(u8) {
    normal,
    maximized,
    minimized,
    snapped_left,
    snapped_right,
    snapped_top,
    snapped_bottom,
};

pub const DragMode = enum(u8) {
    none,
    move,
    resize_left,
    resize_right,
    resize_top,
    resize_bottom,
    resize_top_left,
    resize_top_right,
    resize_bottom_left,
    resize_bottom_right,
};

pub const AnimationType = enum(u8) {
    none,
    open,
    close,
    minimize,
    restore,
    maximize,
    snap,
};

// ============================================================================
// 窗口结构
// ============================================================================

pub const ManagedWindow = struct {
    surface_id: u32,
    title: []const u8,
    state: WindowState,
    prev_state: WindowState,
    normal_rect: Rect,
    current_rect: Rect,
    z_order: i32,
    is_topmost: bool,
    is_modal: bool,
    is_active: bool,
    is_visible: bool,
    drag_mode: DragMode,
    drag_start_x: i32,
    drag_start_y: i32,
    drag_start_rect: Rect,
    animation_type: AnimationType,
    animation_start_time: u64,
    animation_start_rect: Rect,
    animation_end_rect: Rect,
    animation_start_alpha: u8,
    animation_end_alpha: u8,
    glass_enabled: bool,
};

const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

// ============================================================================
// 全局状态
// ============================================================================

var g_windows: [MAX_WINDOWS]ManagedWindow = undefined;
var g_window_count: usize = 0;
var g_active_window: ?*ManagedWindow = null;
var g_initialized: bool = false;
var g_next_z_order: i32 = 0;

// ============================================================================
// 窗口管理器初始化
// ============================================================================

pub fn initWindowManager() void {
    if (g_initialized) return;

    g_window_count = 0;
    g_active_window = null;
    g_next_z_order = 0;
    g_initialized = true;
}

pub fn deinitWindowManager() void {
    if (!g_initialized) return;

    // 销毁所有窗口
    while (g_window_count > 0) {
        _ = destroyWindow(g_windows[0].surface_id);
    }

    g_initialized = false;
}

pub fn isInitialized() bool {
    return g_initialized;
}

// ============================================================================
// 窗口创建与销毁
// ============================================================================

pub fn createWindow(title: []const u8, width: u32, height: u32, x: i32, y: i32, glass: bool) ?u32 {
    if (g_window_count >= MAX_WINDOWS) return null;

    const win = &g_windows[g_window_count];

    // 创建表面
    const surface_id = surface_mgr.createSurface(width, height, .{
        .has_alpha = true,
        .is_visible = true,
        .needs_shadow = true,
        .is_glass = glass,
    });

    if (surface_id == 0) return null;

    // 初始化窗口结构
    win.* = .{
        .surface_id = surface_id,
        .title = title,
        .state = .normal,
        .prev_state = .normal,
        .normal_rect = .{ .x = x, .y = y, .w = @as(i32, @intCast(width)), .h = @as(i32, @intCast(height)) },
        .current_rect = .{ .x = x, .y = y, .w = @as(i32, @intCast(width)), .h = @as(i32, @intCast(height)) },
        .z_order = g_next_z_order,
        .is_topmost = false,
        .is_modal = false,
        .is_active = false,
        .is_visible = true,
        .drag_mode = .none,
        .drag_start_x = 0,
        .drag_start_y = 0,
        .drag_start_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .animation_type = .none,
        .animation_start_time = 0,
        .animation_start_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .animation_end_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .animation_start_alpha = 0,
        .animation_end_alpha = 255,
        .glass_enabled = glass,
    };

    // 设置表面属性
    surface_mgr.moveSurface(surface_id, x, y);
    surface_mgr.setSurfaceZOrder(surface_id, g_next_z_order);
    surface_mgr.setSurfaceGlass(surface_id, glass);

    g_next_z_order += 1;
    g_window_count += 1;

    // 激活新窗口
    activateWindow(win);

    return surface_id;
}

pub fn destroyWindow(surface_id: u32) bool {
    var i: usize = 0;
    while (i < g_window_count) {
        if (g_windows[i].surface_id == surface_id) {
            // 如果是活动窗口，激活下一个
            if (g_active_window != null and g_active_window.?.surface_id == surface_id) {
                if (g_window_count > 1) {
                    const next_idx = if (i == 0) 1 else i - 1;
                    activateWindow(&g_windows[next_idx]);
                } else {
                    g_active_window = null;
                }
            }

            // 销毁表面
            _ = surface_mgr.destroySurface(surface_id);

            // 移除窗口
            var j = i;
            while (j + 1 < g_window_count) : (j += 1) {
                g_windows[j] = g_windows[j + 1];
            }
            g_window_count -= 1;

            return true;
        }
        i += 1;
    }
    return false;
}

pub fn getWindow(surface_id: u32) ?*ManagedWindow {
    for (0..g_window_count) |i| {
        if (g_windows[i].surface_id == surface_id) {
            return &g_windows[i];
        }
    }
    return null;
}

// ============================================================================
// 窗口激活
// ============================================================================

pub fn activateWindow(win: *ManagedWindow) void {
    // 停用之前的活动窗口
    if (g_active_window != null) {
        g_active_window.?.is_active = false;
    }

    // 激活新窗口
    win.is_active = true;
    g_active_window = win;

    // 移到顶层
    bringToFront(win);
}

pub fn bringToFront(win: *ManagedWindow) void {
    win.z_order = g_next_z_order;
    g_next_z_order += 1;
    surface_mgr.setSurfaceZOrder(win.surface_id, win.z_order);
}

pub fn sendToBack(win: *ManagedWindow) void {
    // 找到最小 z-order 并减 1
    var min_z: i32 = 0;
    for (0..g_window_count) |i| {
        if (g_windows[i].z_order < min_z) {
            min_z = g_windows[i].z_order;
        }
    }
    win.z_order = min_z - 1;
    surface_mgr.setSurfaceZOrder(win.surface_id, win.z_order);
}

// ============================================================================
// 窗口操作
// ============================================================================

pub fn maximizeWindow(win: *ManagedWindow) void {
    if (win.state == .maximized) {
        restoreWindow(win);
        return;
    }

    win.prev_state = win.state;
    if (win.state == .normal) {
        win.normal_rect = win.current_rect;
    }

    const screen_size = compositor.getScreenSize();
    win.state = .maximized;
    win.current_rect = .{ .x = 0, .y = 0, .w = @as(i32, @intCast(screen_size.w)), .h = @as(i32, @intCast(screen_size.h)) };

    surface_mgr.resizeSurface(win.surface_id, screen_size.w, screen_size.h);
    surface_mgr.moveSurface(win.surface_id, 0, 0);
}

pub fn minimizeWindow(win: *ManagedWindow) void {
    if (win.state == .minimized) return;

    win.prev_state = win.state;
    if (win.state == .normal) {
        win.normal_rect = win.current_rect;
    }

    win.state = .minimized;
    win.is_visible = false;
    surface_mgr.setSurfaceVisible(win.surface_id, false);
}

pub fn restoreWindow(win: *ManagedWindow) void {
    if (win.state == .minimized) {
        win.is_visible = true;
        surface_mgr.setSurfaceVisible(win.surface_id, true);
    }

    win.state = win.prev_state;
    win.current_rect = win.normal_rect;

    surface_mgr.resizeSurface(win.surface_id, @as(u32, @intCast(win.normal_rect.w)), @as(u32, @intCast(win.normal_rect.h)));
    surface_mgr.moveSurface(win.surface_id, win.normal_rect.x, win.normal_rect.y);
}

pub fn snapWindowLeft(win: *ManagedWindow) void {
    win.prev_state = win.state;
    if (win.state == .normal) {
        win.normal_rect = win.current_rect;
    }

    const screen_size = compositor.getScreenSize();
    const half_w = @as(i32, @intCast(screen_size.w)) / 2;

    win.state = .snapped_left;
    win.current_rect = .{ .x = 0, .y = 0, .w = half_w, .h = @as(i32, @intCast(screen_size.h)) };

    surface_mgr.resizeSurface(win.surface_id, @as(u32, @intCast(half_w)), screen_size.h);
    surface_mgr.moveSurface(win.surface_id, 0, 0);
}

pub fn snapWindowRight(win: *ManagedWindow) void {
    win.prev_state = win.state;
    if (win.state == .normal) {
        win.normal_rect = win.current_rect;
    }

    const screen_size = compositor.getScreenSize();
    const half_w = @as(i32, @intCast(screen_size.w)) / 2;

    win.state = .snapped_right;
    win.current_rect = .{ .x = half_w, .y = 0, .w = half_w, .h = @as(i32, @intCast(screen_size.h)) };

    surface_mgr.resizeSurface(win.surface_id, @as(u32, @intCast(half_w)), screen_size.h);
    surface_mgr.moveSurface(win.surface_id, half_w, 0);
}

// ============================================================================
// 拖拽操作
// ============================================================================

pub fn beginDrag(win: *ManagedWindow, x: i32, y: i32, mode: DragMode) void {
    win.drag_mode = mode;
    win.drag_start_x = x;
    win.drag_start_y = y;
    win.drag_start_rect = win.current_rect;

    // 如果最大化或停靠，还原为正常大小
    if (win.state != .normal) {
        restoreWindow(win);
        // 调整拖拽起始位置到窗口中心
        win.drag_start_x = win.current_rect.x + win.current_rect.w / 2;
        win.drag_start_y = win.current_rect.y + 20;
    }
}

pub fn updateDrag(win: *ManagedWindow, x: i32, y: i32) void {
    if (win.drag_mode == .none) return;

    const delta_x = x - win.drag_start_x;
    const delta_y = y - win.drag_start_y;

    switch (win.drag_mode) {
        .move => {
            const new_x = win.drag_start_rect.x + delta_x;
            const new_y = win.drag_start_rect.y + delta_y;
            win.current_rect.x = new_x;
            win.current_rect.y = new_y;
            surface_mgr.moveSurface(win.surface_id, new_x, new_y);

            // 检查边缘吸附
            checkSnap(win, new_x, new_y);
        },
        .resize_left => {
            var new_w = win.drag_start_rect.w - delta_x;
            var new_x = win.drag_start_rect.x + delta_x;
            if (new_w < MIN_WINDOW_WIDTH) {
                new_w = MIN_WINDOW_WIDTH;
                new_x = win.drag_start_rect.x + win.drag_start_rect.w - MIN_WINDOW_WIDTH;
            }
            win.current_rect.w = new_w;
            win.current_rect.x = new_x;
            surface_mgr.resizeSurface(win.surface_id, @as(u32, @intCast(new_w)), @as(u32, @intCast(win.current_rect.h)));
            surface_mgr.moveSurface(win.surface_id, new_x, win.current_rect.y);
        },
        .resize_right => {
            var new_w = win.drag_start_rect.w + delta_x;
            if (new_w < MIN_WINDOW_WIDTH) new_w = MIN_WINDOW_WIDTH;
            win.current_rect.w = new_w;
            surface_mgr.resizeSurface(win.surface_id, @as(u32, @intCast(new_w)), @as(u32, @intCast(win.current_rect.h)));
        },
        .resize_top => {
            var new_h = win.drag_start_rect.h - delta_y;
            var new_y = win.drag_start_rect.y + delta_y;
            if (new_h < MIN_WINDOW_HEIGHT) {
                new_h = MIN_WINDOW_HEIGHT;
                new_y = win.drag_start_rect.y + win.drag_start_rect.h - MIN_WINDOW_HEIGHT;
            }
            win.current_rect.h = new_h;
            win.current_rect.y = new_y;
            surface_mgr.resizeSurface(win.surface_id, @as(u32, @intCast(win.current_rect.w)), @as(u32, @intCast(new_h)));
            surface_mgr.moveSurface(win.surface_id, win.current_rect.x, new_y);
        },
        .resize_bottom => {
            var new_h = win.drag_start_rect.h + delta_y;
            if (new_h < MIN_WINDOW_HEIGHT) new_h = MIN_WINDOW_HEIGHT;
            win.current_rect.h = new_h;
            surface_mgr.resizeSurface(win.surface_id, @as(u32, @intCast(win.current_rect.w)), @as(u32, @intCast(new_h)));
        },
        else => {},
    }
}

pub fn endDrag(win: *ManagedWindow) void {
    win.drag_mode = .none;

    // 如果在拖拽过程中被吸附，应用吸附位置
    if (win.state != .normal) {
        win.normal_rect = win.current_rect;
    }
}

fn checkSnap(win: *ManagedWindow, x: i32, y: i32) void {
    const screen_size = compositor.getScreenSize();

    // 左边缘吸附
    if (x <= SNAP_EDGE_THRESHOLD) {
        snapWindowLeft(win);
        return;
    }

    // 右边缘吸附
    if (x + win.current_rect.w >= @as(i32, @intCast(screen_size.w)) - SNAP_EDGE_THRESHOLD) {
        snapWindowRight(win);
        return;
    }

    // 上边缘最大化
    if (y <= SNAP_EDGE_THRESHOLD) {
        maximizeWindow(win);
        return;
    }
}

// ============================================================================
// 命中测试
// ============================================================================

pub fn hitTestWindow(px: i32, py: i32) ?*ManagedWindow {
    // 从顶层开始检测
    var max_z: i32 = -1;
    var result: ?*ManagedWindow = null;

    for (0..g_window_count) |i| {
        const win = &g_windows[i];
        if (!win.is_visible) continue;

        const rect = win.current_rect;
        if (px >= rect.x and px < rect.x + rect.w and
            py >= rect.y and py < rect.y + rect.h) {
            if (win.z_order > max_z) {
                max_z = win.z_order;
                result = win;
            }
        }
    }

    return result;
}

pub fn getDragModeAtPosition(win: *ManagedWindow, px: i32, py: i32) DragMode {
    const rect = win.current_rect;
    const x = px - rect.x;
    const y = py - rect.y;

    const on_left = x < RESIZE_BORDER_WIDTH;
    const on_right = x >= rect.w - RESIZE_BORDER_WIDTH;
    const on_top = y < RESIZE_BORDER_WIDTH;
    const on_bottom = y >= rect.h - RESIZE_BORDER_WIDTH;

    if (on_top and on_left) return .resize_top_left;
    if (on_top and on_right) return .resize_top_right;
    if (on_bottom and on_left) return .resize_bottom_left;
    if (on_bottom and on_right) return .resize_bottom_right;
    if (on_left) return .resize_left;
    if (on_right) return .resize_right;
    if (on_top) return .resize_top;
    if (on_bottom) return .resize_bottom;

    // 标题栏区域
    if (y < 30) return .move;

    return .none;
}

// ============================================================================
// 窗口遍历
// ============================================================================

pub fn getActiveWindow() ?*ManagedWindow {
    return g_active_window;
}

pub fn getWindowCount() usize {
    return g_window_count;
}

pub fn getWindows() []ManagedWindow {
    return g_windows[0..g_window_count];
}

// ============================================================================
// 更新动画
// ============================================================================

pub fn updateAnimations() void {
    const now = getCurrentTimeMs();

    for (0..g_window_count) |i| {
        const win = &g_windows[i];
        if (win.animation_type == .none) continue;

        const elapsed = now - win.animation_start_time;
        if (elapsed >= ANIMATION_DURATION_MS) {
            // 动画完成
            win.animation_type = .none;
            surface_mgr.setSurfaceAlpha(win.surface_id, win.animation_end_alpha);

            if (win.animation_end_rect.w > 0 and win.animation_end_rect.h > 0) {
                win.current_rect = win.animation_end_rect;
                surface_mgr.resizeSurface(
                    win.surface_id,
                    @as(u32, @intCast(win.animation_end_rect.w)),
                    @as(u32, @intCast(win.animation_end_rect.h))
                );
                surface_mgr.moveSurface(win.surface_id, win.animation_end_rect.x, win.animation_end_rect.y);
            }
            continue;
        }

        // 计算进度
        const t = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(ANIMATION_DURATION_MS));
        const progress = 1.0 - (1.0 - t) * (1.0 - t); // ease-out

        // 插值位置和大小
        const new_x = lerpInt(win.animation_start_rect.x, win.animation_end_rect.x, progress);
        const new_y = lerpInt(win.animation_start_rect.y, win.animation_end_rect.y, progress);
        const new_w = lerpInt(win.animation_start_rect.w, win.animation_end_rect.w, progress);
        const new_h = lerpInt(win.animation_start_rect.h, win.animation_end_rect.h, progress);

        // 插值透明度
        const new_alpha: u8 = @intFromFloat(
            @as(f32, @floatFromInt(win.animation_start_alpha)) * (1.0 - progress) +
            @as(f32, @floatFromInt(win.animation_end_alpha)) * progress
        );

        // 更新表面
        if (new_w > 0 and new_h > 0) {
            surface_mgr.resizeSurface(win.surface_id, @as(u32, @intCast(new_w)), @as(u32, @intCast(new_h)));
            surface_mgr.moveSurface(win.surface_id, new_x, new_y);
        }
        surface_mgr.setSurfaceAlpha(win.surface_id, new_alpha);
    }
}

// ============================================================================
// 工具函数
// ============================================================================

fn lerpInt(a: i32, b: i32, t: f32) i32 {
    return @as(i32, @intFromFloat(@as(f32, @floatFromInt(a)) * (1.0 - t) + @as(f32, @floatFromInt(b)) * t));
}

fn getCurrentTimeMs() u64 {
    return @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))) / 1_000_000;
}