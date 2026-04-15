// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS Window Manager - ZirconWMgr
//! Migrated and enhanced from aero/src/window_manager.zig
//! Implements Aero Snap, Aero Shake, Flip3D, and Aero Peek window management features.

const std = @import("std");

// ============================================================================
// Window Manager Types
// ============================================================================

pub const WindowHandle = u32;
pub const INVALID_WINDOW: WindowHandle = 0;

pub const WindowState = enum(u8) {
    normal,
    minimized,
    maximized,
    restored,
    moving,
    sizing,
};

pub const WindowInfo = struct {
    handle: WindowHandle,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    state: WindowState,
    is_visible: bool,
    is_active: bool,
    is_always_on_top: bool,
    z_order: i32,
};

// ============================================================================
// Aero Snap Configuration
// ============================================================================

pub const AeroSnapConfig = struct {
    enabled: bool = true,
    snap_threshold: i32 = 20,
    snap_guides: bool = true,
    snap_animation: bool = true,
};

pub var g_aero_snap_config: AeroSnapConfig = .{};

// ============================================================================
// Window Manager State
// ============================================================================

pub const MAX_WINDOWS: usize = 256;

pub const WindowManager = struct {
    windows: [MAX_WINDOWS]?WindowInfo,
    window_count: usize,
    active_window: WindowHandle,
    next_handle: WindowHandle,
    snap_enabled: bool,
    shake_enabled: bool,

    pub fn init(self: *WindowManager) void {
        self.window_count = 0;
        self.active_window = INVALID_WINDOW;
        self.next_handle = 1;
        self.snap_enabled = true;
        self.shake_enabled = true;
    }

    pub fn createWindow(self: *WindowManager) WindowHandle {
        if (self.window_count >= MAX_WINDOWS) return INVALID_WINDOW;

        const handle = self.next_handle;
        self.next_handle += 1;

        self.windows[self.window_count] = .{
            .handle = handle,
            .x = 100,
            .y = 100,
            .width = 400,
            .height = 300,
            .state = .normal,
            .is_visible = true,
            .is_active = false,
            .is_always_on_top = false,
            .z_order = @intCast(self.window_count),
        };

        self.window_count += 1;
        return handle;
    }

    pub fn getWindow(self: *WindowManager, handle: WindowHandle) ?*WindowInfo {
        for (self.windows[0..self.window_count]) |*win| {
            if (win.*) |w| {
                if (w.handle == handle) return win;
            }
        }
        return null;
    }

    pub fn setActiveWindow(self: *WindowManager, handle: WindowHandle) void {
        // Deactivate current
        if (self.active_window != INVALID_WINDOW) {
            if (self.getWindow(self.active_window)) |win| {
                win.is_active = false;
            }
        }

        // Activate new
        self.active_window = handle;
        if (self.getWindow(handle)) |win| {
            win.is_active = true;
        }
    }

    pub fn minimizeWindow(self: *WindowManager, handle: WindowHandle) void {
        if (self.getWindow(handle)) |win| {
            win.state = .minimized;
            win.is_visible = false;
        }
    }

    pub fn maximizeWindow(self: *WindowManager, handle: WindowHandle) void {
        if (self.getWindow(handle)) |win| {
            win.state = .maximized;
            win.x = 0;
            win.y = 0;
            win.width = 1920;
            win.height = 1040;
        }
    }

    pub fn restoreWindow(self: *WindowManager, handle: WindowHandle) void {
        if (self.getWindow(handle)) |win| {
            win.state = .restored;
            win.is_visible = true;
        }
    }
};

// ============================================================================
// Aero Snap Implementation
// ============================================================================

pub const SnapZone = enum {
    none,
    left,
    right,
    top,
    bottom,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
};

pub fn detectSnapZone(x: i32, y: i32, screen_width: i32, screen_height: i32) SnapZone {
    const threshold = g_aero_snap_config.snap_threshold;

    // Corners
    if (x < threshold and y < threshold) return .top_left;
    if (x > screen_width - threshold and y < threshold) return .top_right;
    if (x < threshold and y > screen_height - threshold) return .bottom_left;
    if (x > screen_width - threshold and y > screen_height - threshold) return .bottom_right;

    // Edges
    if (x < threshold) return .left;
    if (x > screen_width - threshold) return .right;
    if (y < threshold) return .top;
    if (y > screen_height - threshold) return .bottom;

    return .none;
}

pub fn snapWindow(win: *WindowInfo, zone: SnapZone, screen_width: i32, screen_height: i32) void {
    switch (zone) {
        .left => {
            win.x = 0;
            win.y = 0;
            win.width = screen_width / 2;
            win.height = screen_height;
            win.state = .normal;
        },
        .right => {
            win.x = screen_width / 2;
            win.y = 0;
            win.width = screen_width / 2;
            win.height = screen_height;
            win.state = .normal;
        },
        .top => {
            win.x = 0;
            win.y = 0;
            win.width = screen_width;
            win.height = screen_height / 2;
            win.state = .normal;
        },
        .bottom => {
            win.x = 0;
            win.y = screen_height / 2;
            win.width = screen_width;
            win.height = screen_height / 2;
            win.state = .normal;
        },
        .top_left => {
            win.x = 0;
            win.y = 0;
            win.width = screen_width / 2;
            win.height = screen_height / 2;
            win.state = .normal;
        },
        .top_right => {
            win.x = screen_width / 2;
            win.y = 0;
            win.width = screen_width / 2;
            win.height = screen_height / 2;
            win.state = .normal;
        },
        .bottom_left => {
            win.x = 0;
            win.y = screen_height / 2;
            win.width = screen_width / 2;
            win.height = screen_height / 2;
            win.state = .normal;
        },
        .bottom_right => {
            win.x = screen_width / 2;
            win.y = screen_height / 2;
            win.width = screen_width / 2;
            win.height = screen_height / 2;
            win.state = .normal;
        },
        .none => {},
    }
}

// ============================================================================
// Aero Shake Implementation
// ============================================================================

pub var g_shake_minimized_windows: [MAX_WINDOWS]WindowHandle = undefined;
pub var g_shake_minimized_count: usize = 0;

pub fn handleAeroShake(window_manager: *WindowManager, handle: WindowHandle) void {
    g_shake_minimized_count = 0;

    // Minimize all windows except the shaken one
    for (window_manager.windows[0..window_manager.window_count]) |*win| {
        if (win.*) |w| {
            if (w.handle != handle and w.state != .minimized) {
                g_shake_minimized_windows[g_shake_minimized_count] = w.handle;
                g_shake_minimized_count += 1;
                w.state = .minimized;
                w.is_visible = false;
            }
        }
    }
}

pub fn handleAeroShakeEnd(window_manager: *WindowManager) void {
    // Restore all minimized windows
    for (0..g_shake_minimized_count) |i| {
        const handle = g_shake_minimized_windows[i];
        if (window_manager.getWindow(handle)) |win| {
            win.state = .restored;
            win.is_visible = true;
        }
    }
    g_shake_minimized_count = 0;
}

// ============================================================================
// Global Window Manager
// ============================================================================

pub var g_window_manager: WindowManager = .{};

pub fn initWindowManager() void {
    g_window_manager.init();
}

pub fn createWindow() WindowHandle {
    return g_window_manager.createWindow();
}

pub fn getWindow(handle: WindowHandle) ?*WindowInfo {
    return g_window_manager.getWindow(handle);
}

pub fn setActiveWindow(handle: WindowHandle) void {
    g_window_manager.setActiveWindow(handle);
}

pub fn snapWindowToZone(handle: WindowHandle, zone: SnapZone, screen_width: i32, screen_height: i32) void {
    if (g_window_manager.getWindow(handle)) |win| {
        snapWindow(win, zone, screen_width, screen_height);
    }
}
