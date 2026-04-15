// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// WindowDecorator - D3D10 渲染的窗口装饰组件
// 支持 Aero 玻璃标题栏、窗口阴影、按钮

const std = @import("std");
const dwm = @import("../root.zig");
const theme = @import("../config/theme.zig");
const compositor = @import("../compositor/compositor.zig");
const surface_mgr = @import("../compositor/surface_mgr.zig");

// ============================================================================
// 常量定义
// ============================================================================

pub const TITLEBAR_HEIGHT: i32 = 26;
pub const BUTTON_SIZE: i32 = 21;
pub const BUTTON_MARGIN: i32 = 2;
pub const FRAME_WIDTH: i32 = 4;
pub const CORNER_RADIUS: i32 = 6;

// ============================================================================
// 窗口按钮
// ============================================================================

pub const CaptionButton = enum(u8) {
    minimize,
    maximize,
    close,
};

pub const ButtonState = enum(u8) {
    normal,
    hovered,
    pressed,
};

pub const WindowChrome = struct {
    surface_id: u32,
    window_handle: u32,
    title: []const u8,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    is_active: bool,
    minimize_hovered: bool,
    maximize_hovered: bool,
    close_hovered: bool,
    minimize_pressed: bool,
    maximize_pressed: bool,
    close_pressed: bool,
};

// ============================================================================
// 窗口装饰器状态
// ============================================================================

var g_window_chromes: [64]WindowChrome = undefined;
var g_chrome_count: usize = 0;
var g_initialized: bool = false;

// ============================================================================
// 窗口装饰器初始化
// ============================================================================

pub fn initWindowDecorator() void {
    if (g_initialized) return;

    g_chrome_count = 0;
    g_initialized = true;
}

pub fn deinitWindowDecorator() void {
    if (!g_initialized) return;

    for (0..g_chrome_count) |i| {
        if (g_window_chromes[i].surface_id != 0) {
            _ = surface_mgr.destroySurface(g_window_chromes[i].surface_id);
        }
    }

    g_initialized = false;
}

pub fn isInitialized() bool {
    return g_initialized;
}

// ============================================================================
// 窗口 Chrome 管理
// ============================================================================

pub fn createWindowChrome(window_handle: u32, title: []const u8, x: i32, y: i32, width: u32, height: u32) u32 {
    if (g_chrome_count >= 64) return 0;

    const chrome = &g_window_chromes[g_chrome_count];
    chrome.* = .{
        .surface_id = 0,
        .window_handle = window_handle,
        .title = title,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .is_active = true,
        .minimize_hovered = false,
        .maximize_hovered = false,
        .close_hovered = false,
        .minimize_pressed = false,
        .maximize_pressed = false,
        .close_pressed = false,
    };

    g_chrome_count += 1;
    return window_handle;
}

pub fn destroyWindowChrome(window_handle: u32) void {
    var i: usize = 0;
    while (i < g_chrome_count) {
        if (g_window_chromes[i].window_handle == window_handle) {
            if (g_window_chromes[i].surface_id != 0) {
                _ = surface_mgr.destroySurface(g_window_chromes[i].surface_id);
            }

            // 移除
            var j = i;
            while (j + 1 < g_chrome_count) : (j += 1) {
                g_window_chromes[j] = g_window_chromes[j + 1];
            }
            g_chrome_count -= 1;
            return;
        }
        i += 1;
    }
}

pub fn updateWindowChrome(window_handle: u32, x: i32, y: i32, width: u32, height: u32) void {
    for (0..g_chrome_count) |i| {
        if (g_window_chromes[i].window_handle == window_handle) {
            g_window_chromes[i].x = x;
            g_window_chromes[i].y = y;
            g_window_chromes[i].width = width;
            g_window_chromes[i].height = height;

            if (g_window_chromes[i].surface_id != 0) {
                surface_mgr.moveSurface(g_window_chromes[i].surface_id, x, y);
                surface_mgr.resizeSurface(g_window_chromes[i].surface_id, width, TITLEBAR_HEIGHT);
            }
            return;
        }
    }
}

pub fn setWindowActive(window_handle: u32, active: bool) void {
    for (0..g_chrome_count) |i| {
        if (g_window_chromes[i].window_handle == window_handle) {
            g_window_chromes[i].is_active = active;
            return;
        }
    }
}

pub fn getWindowChrome(window_handle: u32) ?*WindowChrome {
    for (0..g_chrome_count) |i| {
        if (g_window_chromes[i].window_handle == window_handle) {
            return &g_window_chromes[i];
        }
    }
    return null;
}

// ============================================================================
// 命中测试
// ============================================================================

pub fn hitTestCaption(window_handle: u32, px: i32, py: i32) ?enum { client, caption, close, minimize, maximize, resize_left, resize_right, resize_top, resize_bottom, resize_topleft, resize_topright, resize_bottomleft, resize_bottomright, none } {
    for (0..g_chrome_count) |i| {
        const chrome = g_window_chromes[i];
        if (chrome.window_handle != window_handle) continue;

        // 窗口边框区域
        const resize_border: i32 = FRAME_WIDTH;

        // 检查是否在窗口范围内
        if (px < chrome.x or px >= chrome.x + @as(i32, @intCast(chrome.width)) or
            py < chrome.y or py >= chrome.y + @as(i32, @intCast(chrome.height))) {
            continue;
        }

        const local_x = px - chrome.x;
        const local_y = py - chrome.y;

        // 检查标题栏按钮
        const button_start_x = @as(i32, @intCast(chrome.width)) - BUTTON_SIZE * 3 - BUTTON_MARGIN * 2;

        // 关闭按钮
        if (local_x >= button_start_x + BUTTON_SIZE * 2 and local_x < button_start_x + BUTTON_SIZE * 3 and
            local_y >= BUTTON_MARGIN and local_y < BUTTON_MARGIN + BUTTON_SIZE) {
            return .close;
        }

        // 最大化按钮
        if (local_x >= button_start_x + BUTTON_SIZE and local_x < button_start_x + BUTTON_SIZE * 2 and
            local_y >= BUTTON_MARGIN and local_y < BUTTON_MARGIN + BUTTON_SIZE) {
            return .maximize;
        }

        // 最小化按钮
        if (local_x >= button_start_x and local_x < button_start_x + BUTTON_SIZE and
            local_y >= BUTTON_MARGIN and local_y < BUTTON_MARGIN + BUTTON_SIZE) {
            return .minimize;
        }

        // 标题栏区域
        if (local_y >= 0 and local_y < TITLEBAR_HEIGHT) {
            return .caption;
        }

        // 客户端区域
        if (local_y >= TITLEBAR_HEIGHT and
            local_y < @as(i32, @intCast(chrome.height)) - resize_border and
            local_x >= resize_border and
            local_x < @as(i32, @intCast(chrome.width)) - resize_border) {
            return .client;
        }

        // 缩放边框
        if (local_x < resize_border) {
            if (local_y < resize_border) return .resize_topleft;
            if (local_y >= @as(i32, @intCast(chrome.height)) - resize_border) return .resize_bottomleft;
            return .resize_left;
        }
        if (local_x >= @as(i32, @intCast(chrome.width)) - resize_border) {
            if (local_y < resize_border) return .resize_topright;
            if (local_y >= @as(i32, @intCast(chrome.height)) - resize_border) return .resize_bottomright;
            return .resize_right;
        }
        if (local_y < resize_border) return .resize_top;
        if (local_y >= @as(i32, @intCast(chrome.height)) - resize_border) return .resize_bottom;

        return .client;
    }

    return null;
}

pub fn hitTestButton(window_handle: u32, px: i32, py: i32) ?CaptionButton {
    const result = hitTestCaption(window_handle, px, py) orelse return null;

    switch (result) {
        .close => return .close,
        .maximize => return .maximize,
        .minimize => return .minimize,
        else => return null,
    }
}

// ============================================================================
// 输入处理
// ============================================================================

pub fn onMouseMove(window_handle: u32, px: i32, py: i32) void {
    for (0..g_chrome_count) |i| {
        if (g_window_chromes[i].window_handle != window_handle) continue;

        const chrome = &g_window_chromes[i];
        const local_x = px - chrome.x;
        const local_y = py - chrome.y;
        const button_start_x = @as(i32, @intCast(chrome.width)) - BUTTON_SIZE * 3 - BUTTON_MARGIN * 2;

        chrome.minimize_hovered = (local_x >= button_start_x and local_x < button_start_x + BUTTON_SIZE and
            local_y >= BUTTON_MARGIN and local_y < BUTTON_MARGIN + BUTTON_SIZE);

        chrome.maximize_hovered = (local_x >= button_start_x + BUTTON_SIZE and local_x < button_start_x + BUTTON_SIZE * 2 and
            local_y >= BUTTON_MARGIN and local_y < BUTTON_MARGIN + BUTTON_SIZE);

        chrome.close_hovered = (local_x >= button_start_x + BUTTON_SIZE * 2 and local_x < button_start_x + BUTTON_SIZE * 3 and
            local_y >= BUTTON_MARGIN and local_y < BUTTON_MARGIN + BUTTON_SIZE);

        return;
    }
}

pub fn onMouseLeave(window_handle: u32) void {
    for (0..g_chrome_count) |i| {
        if (g_window_chromes[i].window_handle == window_handle) {
            g_window_chromes[i].minimize_hovered = false;
            g_window_chromes[i].maximize_hovered = false;
            g_window_chromes[i].close_hovered = false;
            g_window_chromes[i].minimize_pressed = false;
            g_window_chromes[i].maximize_pressed = false;
            g_window_chromes[i].close_pressed = false;
            return;
        }
    }
}

pub fn onButtonDown(window_handle: u32, button: CaptionButton) void {
    for (0..g_chrome_count) |i| {
        if (g_window_chromes[i].window_handle != window_handle) continue;

        switch (button) {
            .minimize => g_window_chromes[i].minimize_pressed = true,
            .maximize => g_window_chromes[i].maximize_pressed = true,
            .close => g_window_chromes[i].close_pressed = true,
        }
        return;
    }
}

pub fn onButtonUp(window_handle: u32, button: CaptionButton) enum { minimize, maximize, close, none } {
    for (0..g_chrome_count) |i| {
        if (g_window_chromes[i].window_handle != window_handle) continue;

        switch (button) {
            .minimize => {
                const was_pressed = g_window_chromes[i].minimize_pressed;
                g_window_chromes[i].minimize_pressed = false;
                if (was_pressed and g_window_chromes[i].minimize_hovered) return .minimize;
            },
            .maximize => {
                const was_pressed = g_window_chromes[i].maximize_pressed;
                g_window_chromes[i].maximize_pressed = false;
                if (was_pressed and g_window_chromes[i].maximize_hovered) return .maximize;
            },
            .close => {
                const was_pressed = g_window_chromes[i].close_pressed;
                g_window_chromes[i].close_pressed = false;
                if (was_pressed and g_window_chromes[i].close_hovered) return .close;
            },
        }
        return;
    }
    return .none;
}

// ============================================================================
// 渲染
// ============================================================================

pub fn renderTitlebarGlass(window_handle: u32) void {
    for (0..g_chrome_count) |i| {
        if (g_window_chromes[i].window_handle == window_handle) {
            // 使用玻璃效果渲染标题栏
            const chrome = &g_window_chromes[i];

            if (surface_mgr.getSurface(chrome.surface_id)) |sfc| {
                sfc.flags.is_glass = theme.isGlassEnabled();
                sfc.flags.needs_blur = theme.isGlassEnabled();
                sfc.markFullDirty();
            }
            return;
        }
    }
}

pub fn renderWindowShadow(window_handle: u32) void {
    for (0..g_chrome_count) |i| {
        if (g_window_chromes[i].window_handle == window_handle) {
            // 窗口阴影在 compositor 层渲染
            return;
        }
    }
}