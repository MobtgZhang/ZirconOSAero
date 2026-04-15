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

//! Window Manager - Implements core window management features
//! including Aero Snap, Aero Shake, window animations, drag and resize,
//! and window z-order management.
//! Reference: Windows 7 Aero user experience public documentation.

const std = @import("std");
const compositor = @import("compositor.zig");
const theme = @import("theme.zig");

pub const MAX_WINDOWS = compositor.MAX_SURFACES;
pub const SNAP_EDGE_THRESHOLD = 10; // pixels from edge to trigger snap
pub const SHAKE_THRESHOLD = 15; // pixels movement to count as shake
pub const SHAKE_COUNT_THRESHOLD = 5; // number of direction changes to trigger shake
pub const ANIMATION_DURATION_MS = 250; // standard window animation duration
pub const RESIZE_BORDER_WIDTH = 8; // width of window resize border
pub const MIN_WINDOW_WIDTH = 100;
pub const MIN_WINDOW_HEIGHT = 100;

/// Window state enum
pub const WindowState = enum(u8) {
    normal,
    maximized,
    minimized,
    snapped_left,
    snapped_right,
    snapped_top_left,
    snapped_top_right,
    snapped_bottom_left,
    snapped_bottom_right,
};

/// Window drag mode enum
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

/// Animation type enum
pub const AnimationType = enum(u8) {
    none,
    open,
    close,
    minimize,
    restore,
    maximize,
    snap,
    flip3d_enter,
    flip3d_leave,
    flip3d_switch,
};

/// Flip3D state structure
pub const Flip3DState = struct {
    active: bool = false,
    selected_index: usize = 0,
    window_list: std.ArrayList(*Window) = undefined,
    start_time: u64 = 0,
    animation_progress: f32 = 0.0,
    switch_progress: f32 = 0.0,
    last_switch_dir: i32 = 0,
};

var flip3d_state: Flip3DState = .{};

/// Window structure
pub const Window = struct {
    surface_id: u32 = compositor.INVALID_SURFACE,
    title: []const u8 = "",
    state: WindowState = .normal,
    prev_state: WindowState = .normal,
    normal_rect: compositor.Rect = .{}, // position and size when in normal state
    z_level: i32 = 0,
    is_topmost: bool = false,
    is_modal: bool = false,
    is_active: bool = false,
    // Drag state
    drag_mode: DragMode = .none,
    drag_start_pos: struct { x: i32, y: i32 } = .{ .x = 0, .y = 0 },
    drag_start_rect: compositor.Rect = .{},
    // Shake detection
    shake_start_time: u64 = 0,
    shake_last_dir: i32 = 0,
    shake_count: u32 = 0,
    // Animation state
    animation_type: AnimationType = .none,
    animation_start_time: u64 = 0,
    animation_start_rect: compositor.Rect = .{},
    animation_end_rect: compositor.Rect = .{},
    animation_start_alpha: u8 = 0,
    animation_end_alpha: u8 = 0,
    // Snap preview
    snap_preview_active: bool = false,
    snap_preview_state: WindowState = .normal,
    snap_preview_rect: compositor.Rect = .{},
};

var windows: [MAX_WINDOWS]Window = [_]Window{.{}} ** MAX_WINDOWS;
var window_count: usize = 0;
var active_window: ?*Window = null;
var shake_minimized_windows: std.AutoHashMap(u32, void) = undefined;
var initialized: bool = false;

/// Initialize window manager
pub fn init(allocator: std.mem.Allocator) void {
    shake_minimized_windows = std.AutoHashMap(u32, void).init(allocator);
    flip3d_state.window_list = std.ArrayList(*Window).init(allocator);
    initialized = true;
    window_count = 0;
    active_window = null;
}

/// Deinitialize window manager
pub fn deinit() void {
    shake_minimized_windows.deinit();
    initialized = false;
}

/// Create a new window
pub fn createWindow(
    title: []const u8,
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    is_glass: bool,
) ?u32 {
    if (!initialized or window_count >= MAX_WINDOWS) return null;

    const surface_id = compositor.createSurface(width, height, .{
        .has_alpha = true,
        .is_visible = true,
        .needs_shadow = true,
        .is_glass = is_glass,
    });

    if (surface_id == compositor.INVALID_SURFACE) return null;

    const win = &windows[window_count];
    win.* = .{
        .surface_id = surface_id,
        .title = title,
        .normal_rect = .{
            .x = x,
            .y = y,
            .w = @intCast(width),
            .h = @intCast(height),
        },
        .z_level = @intCast(window_count),
    };

    compositor.moveSurface(surface_id, x, y);
    compositor.setSurfaceZOrder(surface_id, win.z_level);
    window_count += 1;

    // Animate window opening
    startAnimation(win, .open, .{}, win.normal_rect, 0, 255);

    setActiveWindow(win);
    return surface_id;
}

/// Destroy a window
pub fn destroyWindow(surface_id: u32) bool {
    if (!initialized) return false;

    const win = getWindowBySurfaceId(surface_id) orelse return false;

    // Animate window closing
    startAnimation(win, .close, win.normal_rect, .{}, 255, 0);

    // Wait for animation to complete before actually destroying
    // For now, destroy immediately
    _ = compositor.destroySurface(surface_id);

    // Remove from windows array
    var i: usize = 0;
    while (i < window_count) : (i += 1) {
        if (windows[i].surface_id == surface_id) {
            var j = i;
            while (j + 1 < window_count) : (j += 1) {
                windows[j] = windows[j + 1];
            }
            windows[window_count - 1] = .{};
            window_count -= 1;
            break;
        }
    }

    // If this was the active window, activate the next one
    if (active_window != null and active_window.?.surface_id == surface_id) {
        active_window = null;
        if (window_count > 0) {
            setActiveWindow(&windows[window_count - 1]);
        }
    }

    return true;
}

/// Get window by surface ID
pub fn getWindowBySurfaceId(surface_id: u32) ?*Window {
    if (!initialized) return null;
    for (windows[0..window_count]) |*win| {
        if (win.surface_id == surface_id) return win;
    }
    return null;
}

/// Set active window
pub fn setActiveWindow(win: *Window) void {
    if (!initialized) return;

    // Deactivate previous active window
    if (active_window != null) {
        active_window.?.is_active = false;
    }

    win.is_active = true;
    active_window = win;

    // Bring to front
    bringToFront(win);
}

/// Bring window to front
pub fn bringToFront(win: *Window) void {
    if (!initialized) return;

    const max_z: i32 = if (window_count == 0) 0 else @intCast(window_count - 1);
    win.z_level = max_z;
    compositor.setSurfaceZOrder(win.surface_id, max_z);

    // Adjust other windows' z levels
    for (windows[0..window_count]) |*w| {
        if (w.surface_id != win.surface_id and w.z_level >= max_z) {
            w.z_level -= 1;
            compositor.setSurfaceZOrder(w.surface_id, w.z_level);
        }
    }
}

/// Toggle window topmost state
pub fn toggleTopmost(win: *Window) void {
    if (!initialized) return;

    win.is_topmost = !win.is_topmost;
    if (win.is_topmost) {
        win.z_level = 0x7FFFFF; // Very high z order
        compositor.setSurfaceZOrder(win.surface_id, win.z_level);
    } else {
        bringToFront(win);
    }
}

/// Maximize window
pub fn maximizeWindow(win: *Window) void {
    if (!initialized or win.state == .maximized) return;

    // Save current state for restore
    win.prev_state = win.state;
    if (win.state == .normal) {
        win.normal_rect = getWindowRect(win);
    }

    const screen_size = compositor.getScreenSize();
    const max_rect = compositor.Rect{
        .x = 0,
        .y = 0,
        .w = @intCast(screen_size.w),
        .h = @intCast(screen_size.h),
    };

    startAnimation(win, .maximize, getWindowRect(win), max_rect, 255, 255);

    win.state = .maximized;
    compositor.resizeSurface(win.surface_id, screen_size.w, screen_size.h);
    compositor.moveSurface(win.surface_id, 0, 0);
}

/// Minimize window
pub fn minimizeWindow(win: *Window) void {
    if (!initialized or win.state == .minimized) return;

    win.prev_state = win.state;
    if (win.state == .normal) {
        win.normal_rect = getWindowRect(win);
    }

    const screen_size = compositor.getScreenSize();
    const taskbar_height = 40; // Assume taskbar is at bottom
    const min_rect = compositor.Rect{
        .x = @intCast(screen_size.w / 2),
        .y = @intCast(screen_size.h - taskbar_height),
        .w = 0,
        .h = 0,
    };

    startAnimation(win, .minimize, getWindowRect(win), min_rect, 255, 0);

    win.state = .minimized;
    compositor.setSurfaceVisible(win.surface_id, false);
}

/// Restore window from minimized/maximized/snapped state
pub fn restoreWindow(win: *Window) void {
    if (!initialized or win.state == .normal) return;

    const current_rect = getWindowRect(win);

    // If restoring from minimize, make surface visible first
    if (win.state == .minimized) {
        compositor.setSurfaceVisible(win.surface_id, true);
    }

    startAnimation(win, .restore, current_rect, win.normal_rect, win.animation_end_alpha, 255);

    win.state = .normal;
    compositor.resizeSurface(win.surface_id, @intCast(win.normal_rect.w), @intCast(win.normal_rect.h));
    compositor.moveSurface(win.surface_id, win.normal_rect.x, win.normal_rect.y);
}

/// Snap window to a specific state
pub fn snapWindow(win: *Window, state: WindowState) void {
    if (!initialized or state == .normal or state == .minimized or state == .maximized) return;

    // Save current state for restore
    win.prev_state = win.state;
    if (win.state == .normal) {
        win.normal_rect = getWindowRect(win);
    }

    const snap_rect = getSnapRectForState(state);
    startAnimation(win, .snap, getWindowRect(win), snap_rect, 255, 255);

    win.state = state;
    compositor.resizeSurface(win.surface_id, @intCast(snap_rect.w), @intCast(snap_rect.h));
    compositor.moveSurface(win.surface_id, snap_rect.x, snap_rect.y);
}

/// Aero Shake: minimize all other windows when current window is shaken
pub fn shakeWindow(win: *Window) void {
    if (!initialized) return;

    // If we have previously minimized windows via shake, restore them
    if (shake_minimized_windows.count() > 0) {
        var iter = shake_minimized_windows.keyIterator();
        while (iter.next()) |surface_id| {
            if (getWindowBySurfaceId(surface_id.*)) |w| {
                if (w.state == .minimized) {
                    restoreWindow(w);
                }
            }
        }
        shake_minimized_windows.clearAndFree();
        return;
    }

    // Otherwise minimize all other windows
    shake_minimized_windows.clearRetainingCapacity();
    for (windows[0..window_count]) |*w| {
        if (w.surface_id != win.surface_id and w.state != .minimized) {
            minimizeWindow(w);
            shake_minimized_windows.put(w.surface_id, {}) catch {};
        }
    }
}

/// Get current window rect
pub fn getWindowRect(win: *const Window) compositor.Rect {
    if (compositor.getSurface(win.surface_id)) |sfc| {
        return sfc.getBounds();
    }
    return win.normal_rect;
}

/// Start window animation
pub fn startAnimation(
    win: *Window,
    anim_type: AnimationType,
    start_rect: compositor.Rect,
    end_rect: compositor.Rect,
    start_alpha: u8,
    end_alpha: u8,
) void {
    win.animation_type = anim_type;
    win.animation_start_time = getCurrentTimeMs();
    win.animation_start_rect = start_rect;
    win.animation_end_rect = end_rect;
    win.animation_start_alpha = start_alpha;
    win.animation_end_alpha = end_alpha;
}

/// Update animations, should be called every frame
pub fn updateAnimations() void {
    if (!initialized) return;

    const now = getCurrentTimeMs();

    for (windows[0..window_count]) |*win| {
        if (win.animation_type == .none) continue;

        const elapsed = now - win.animation_start_time;
        if (elapsed >= ANIMATION_DURATION_MS) {
            // Animation complete
            win.animation_type = .none;
            compositor.setSurfaceAlpha(win.surface_id, win.animation_end_alpha);
            if (win.animation_end_rect.w > 0 and win.animation_end_rect.h > 0) {
                compositor.resizeSurface(
                    win.surface_id,
                    @intCast(win.animation_end_rect.w),
                    @intCast(win.animation_end_rect.h),
                );
                compositor.moveSurface(win.surface_id, win.animation_end_rect.x, win.animation_end_rect.y);
            }
            continue;
        }

        // Calculate progress with ease-out quadratic curve
        const t = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(ANIMATION_DURATION_MS));
        const progress = 1.0 - (1.0 - t) * (1.0 - t); // ease-out

        // Interpolate position and size
        const x = lerp(win.animation_start_rect.x, win.animation_end_rect.x, progress);
        const y = lerp(win.animation_start_rect.y, win.animation_end_rect.y, progress);
        const w = lerp(win.animation_start_rect.w, win.animation_end_rect.w, progress);
        const h = lerp(win.animation_start_rect.h, win.animation_end_rect.h, progress);

        // Interpolate alpha
        const alpha = lerpU8(win.animation_start_alpha, win.animation_end_alpha, progress);

        // Update surface
        if (w > 0 and h > 0) {
            compositor.resizeSurface(win.surface_id, @intFromFloat(w), @intFromFloat(h));
            compositor.moveSurface(win.surface_id, @intFromFloat(x), @intFromFloat(y));
        }
        compositor.setSurfaceAlpha(win.surface_id, alpha);
    }
}

/// Start window drag operation
pub fn startDrag(win: *Window, x: i32, y: i32, mode: DragMode) void {
    if (!initialized) return;

    win.drag_mode = mode;
    win.drag_start_pos = .{ .x = x, .y = y };
    win.drag_start_rect = getWindowRect(win);

    // If window is maximized or snapped, restore to normal when dragging starts
    if (win.state != .normal and win.state != .minimized) {
        restoreWindow(win);
        // Adjust drag start position to center of window
        win.drag_start_pos.x = @intCast(win.normal_rect.w / 2);
        win.drag_start_pos.y = 20; // Assume title bar height is 20
    }
}

/// Process drag motion event
pub fn processDrag(win: *Window, x: i32, y: i32, shift_pressed: bool) void {
    if (!initialized or win.drag_mode == .none) return;

    const delta_x = x - win.drag_start_pos.x;
    const delta_y = y - win.drag_start_pos.y;

    switch (win.drag_mode) {
        .move => {
            // Update window position
            const new_x = win.drag_start_rect.x + delta_x;
            const new_y = win.drag_start_rect.y + delta_y;

            if (!shift_pressed) {
                // Check for snap to edges
                checkSnap(win, new_x, new_y);
            } else {
                // Shift pressed: disable snap preview
                win.snap_preview_active = false;
            }

            // Move window
            compositor.moveSurface(win.surface_id, new_x, new_y);

            // Check for shake gesture
            detectShake(win, delta_x);
        },
        .resize_left => {
            var new_width = win.drag_start_rect.w - delta_x;
            var new_x = win.drag_start_rect.x + delta_x;
            if (new_width < MIN_WINDOW_WIDTH) {
                new_width = MIN_WINDOW_WIDTH;
                new_x = win.drag_start_rect.x + win.drag_start_rect.w - MIN_WINDOW_WIDTH;
            }
            compositor.resizeSurface(win.surface_id, @intCast(new_width), @intCast(win.drag_start_rect.h));
            compositor.moveSurface(win.surface_id, new_x, win.drag_start_rect.y);
        },
        .resize_right => {
            var new_width = win.drag_start_rect.w + delta_x;
            if (new_width < MIN_WINDOW_WIDTH) new_width = MIN_WINDOW_WIDTH;
            compositor.resizeSurface(win.surface_id, @intCast(new_width), @intCast(win.drag_start_rect.h));
        },
        .resize_top => {
            var new_height = win.drag_start_rect.h - delta_y;
            var new_y = win.drag_start_rect.y + delta_y;
            if (new_height < MIN_WINDOW_HEIGHT) {
                new_height = MIN_WINDOW_HEIGHT;
                new_y = win.drag_start_rect.y + win.drag_start_rect.h - MIN_WINDOW_HEIGHT;
            }
            compositor.resizeSurface(win.surface_id, @intCast(win.drag_start_rect.w), @intCast(new_height));
            compositor.moveSurface(win.surface_id, win.drag_start_rect.x, new_y);
        },
        .resize_bottom => {
            var new_height = win.drag_start_rect.h + delta_y;
            if (new_height < MIN_WINDOW_HEIGHT) new_height = MIN_WINDOW_HEIGHT;
            compositor.resizeSurface(win.surface_id, @intCast(win.drag_start_rect.w), @intCast(new_height));
        },
        .resize_top_left => {
            var new_width = win.drag_start_rect.w - delta_x;
            var new_height = win.drag_start_rect.h - delta_y;
            var new_x = win.drag_start_rect.x + delta_x;
            var new_y = win.drag_start_rect.y + delta_y;

            if (new_width < MIN_WINDOW_WIDTH) {
                new_width = MIN_WINDOW_WIDTH;
                new_x = win.drag_start_rect.x + win.drag_start_rect.w - MIN_WINDOW_WIDTH;
            }
            if (new_height < MIN_WINDOW_HEIGHT) {
                new_height = MIN_WINDOW_HEIGHT;
                new_y = win.drag_start_rect.y + win.drag_start_rect.h - MIN_WINDOW_HEIGHT;
            }

            compositor.resizeSurface(win.surface_id, @intCast(new_width), @intCast(new_height));
            compositor.moveSurface(win.surface_id, new_x, new_y);
        },
        .resize_top_right => {
            var new_width = win.drag_start_rect.w + delta_x;
            var new_height = win.drag_start_rect.h - delta_y;
            var new_y = win.drag_start_rect.y + delta_y;

            if (new_width < MIN_WINDOW_WIDTH) new_width = MIN_WINDOW_WIDTH;
            if (new_height < MIN_WINDOW_HEIGHT) {
                new_height = MIN_WINDOW_HEIGHT;
                new_y = win.drag_start_rect.y + win.drag_start_rect.h - MIN_WINDOW_HEIGHT;
            }

            compositor.resizeSurface(win.surface_id, @intCast(new_width), @intCast(new_height));
            compositor.moveSurface(win.surface_id, win.drag_start_rect.x, new_y);
        },
        .resize_bottom_left => {
            var new_width = win.drag_start_rect.w - delta_x;
            var new_height = win.drag_start_rect.h + delta_y;
            var new_x = win.drag_start_rect.x + delta_x;

            if (new_width < MIN_WINDOW_WIDTH) {
                new_width = MIN_WINDOW_WIDTH;
                new_x = win.drag_start_rect.x + win.drag_start_rect.w - MIN_WINDOW_WIDTH;
            }
            if (new_height < MIN_WINDOW_HEIGHT) new_height = MIN_WINDOW_HEIGHT;

            compositor.resizeSurface(win.surface_id, @intCast(new_width), @intCast(new_height));
            compositor.moveSurface(win.surface_id, new_x, win.drag_start_rect.y);
        },
        .resize_bottom_right => {
            var new_width = win.drag_start_rect.w + delta_x;
            var new_height = win.drag_start_rect.h + delta_y;

            if (new_width < MIN_WINDOW_WIDTH) new_width = MIN_WINDOW_WIDTH;
            if (new_height < MIN_WINDOW_HEIGHT) new_height = MIN_WINDOW_HEIGHT;

            compositor.resizeSurface(win.surface_id, @intCast(new_width), @intCast(new_height));
        },
        .none => {},
    }
}

/// End drag operation
pub fn endDrag(win: *Window) void {
    if (!initialized) return;

    defer {
        win.drag_mode = .none;
        win.snap_preview_active = false;
        win.shake_count = 0;
    }

    // If snap preview is active, apply snap
    if (win.snap_preview_active) {
        if (win.snap_preview_state == .maximized) {
            maximizeWindow(win);
        } else {
            snapWindow(win, win.snap_preview_state);
        }
        return;
    }

    // Update normal rect if window is in normal state
    if (win.state == .normal) {
        win.normal_rect = getWindowRect(win);
    }
}

/// Check if cursor is on window resize border
pub fn getDragModeAtPosition(win: *Window, x: i32, y: i32) DragMode {
    const rect = getWindowRect(win);
    const on_left_edge = x >= rect.x and x <= rect.x + RESIZE_BORDER_WIDTH;
    const on_right_edge = x >= rect.x + rect.w - RESIZE_BORDER_WIDTH and x <= rect.x + rect.w;
    const on_top_edge = y >= rect.y and y <= rect.y + RESIZE_BORDER_WIDTH;
    const on_bottom_edge = y >= rect.y + rect.h - RESIZE_BORDER_WIDTH and y <= rect.y + rect.h;

    if (on_top_edge and on_left_edge) return .resize_top_left;
    if (on_top_edge and on_right_edge) return .resize_top_right;
    if (on_bottom_edge and on_left_edge) return .resize_bottom_left;
    if (on_bottom_edge and on_right_edge) return .resize_bottom_right;
    if (on_left_edge) return .resize_left;
    if (on_right_edge) return .resize_right;
    if (on_top_edge) return .resize_top;
    if (on_bottom_edge) return .resize_bottom;

    // Check if on title bar
    const title_bar_height = 32;
    if (y >= rect.y and y <= rect.y + title_bar_height and x >= rect.x and x <= rect.x + rect.w) {
        return .move;
    }

    return .none;
}

/// Check if window should snap to edges
fn checkSnap(win: *Window, x: i32, y: i32) void {
    const screen_size = compositor.getScreenSize();
    const rect = getWindowRect(win);
    win.snap_preview_active = false;

    // Check each snap region
    if (x <= SNAP_EDGE_THRESHOLD and y <= SNAP_EDGE_THRESHOLD) {
        win.snap_preview_state = .snapped_top_left;
        win.snap_preview_active = true;
        win.snap_preview_rect = getSnapRectForState(.snapped_top_left);
    } else if (x >= screen_size.w - rect.w - SNAP_EDGE_THRESHOLD and y <= SNAP_EDGE_THRESHOLD) {
        win.snap_preview_state = .snapped_top_right;
        win.snap_preview_active = true;
        win.snap_preview_rect = getSnapRectForState(.snapped_top_right);
    } else if (x <= SNAP_EDGE_THRESHOLD and y >= screen_size.h - rect.h - SNAP_EDGE_THRESHOLD) {
        win.snap_preview_state = .snapped_bottom_left;
        win.snap_preview_active = true;
        win.snap_preview_rect = getSnapRectForState(.snapped_bottom_left);
    } else if (x >= screen_size.w - rect.w - SNAP_EDGE_THRESHOLD and y >= screen_size.h - rect.h - SNAP_EDGE_THRESHOLD) {
        win.snap_preview_state = .snapped_bottom_right;
        win.snap_preview_active = true;
        win.snap_preview_rect = getSnapRectForState(.snapped_bottom_right);
    } else if (x <= SNAP_EDGE_THRESHOLD) {
        win.snap_preview_state = .snapped_left;
        win.snap_preview_active = true;
        win.snap_preview_rect = getSnapRectForState(.snapped_left);
    } else if (x >= screen_size.w - rect.w - SNAP_EDGE_THRESHOLD) {
        win.snap_preview_state = .snapped_right;
        win.snap_preview_active = true;
        win.snap_preview_rect = getSnapRectForState(.snapped_right);
    } else if (y <= SNAP_EDGE_THRESHOLD) {
        win.snap_preview_state = .maximized;
        win.snap_preview_active = true;
        win.snap_preview_rect = getSnapRectForState(.maximized);
    }
}

/// Detect Aero Shake gesture
fn detectShake(win: *Window, delta_x: i32) void {
    const now = getCurrentTimeMs();
    const current_dir = if (delta_x > 0) 1 else if (delta_x < 0) -1 else 0;

    // Reset shake count if too much time passed
    if (now - win.shake_start_time > 1000) {
        win.shake_count = 0;
        win.shake_start_time = now;
    }

    // Count direction changes
    if (current_dir != 0 and current_dir != win.shake_last_dir and @abs(delta_x) > SHAKE_THRESHOLD) {
        win.shake_count += 1;
        win.shake_last_dir = current_dir;
        win.shake_start_time = now;
    }

    // Trigger shake if threshold reached
    if (win.shake_count >= SHAKE_COUNT_THRESHOLD) {
        shakeWindow(win);
        win.shake_count = 0;
    }
}

/// Get rect for a snap state
pub fn getSnapRectForState(state: WindowState) compositor.Rect {
    const screen_size = compositor.getScreenSize();
    const half_w = screen_size.w / 2;
    const half_h = screen_size.h / 2;

    return switch (state) {
        .maximized => .{ .x = 0, .y = 0, .w = @intCast(screen_size.w), .h = @intCast(screen_size.h) },
        .snapped_left => .{ .x = 0, .y = 0, .w = @intCast(half_w), .h = @intCast(screen_size.h) },
        .snapped_right => .{ .x = @intCast(half_w), .y = 0, .w = @intCast(half_w), .h = @intCast(screen_size.h) },
        .snapped_top_left => .{ .x = 0, .y = 0, .w = @intCast(half_w), .h = @intCast(half_h) },
        .snapped_top_right => .{ .x = @intCast(half_w), .y = 0, .w = @intCast(half_w), .h = @intCast(half_h) },
        .snapped_bottom_left => .{ .x = 0, .y = @intCast(half_h), .w = @intCast(half_w), .h = @intCast(half_h) },
        .snapped_bottom_right => .{ .x = @intCast(half_w), .y = @intCast(half_h), .w = @intCast(half_w), .h = @intCast(half_h) },
        else => .{},
    };
}

/// Linear interpolation for integers
fn lerp(a: anytype, b: anytype, t: f32) f32 {
    return @as(f32, @floatFromInt(a)) * (1 - t) + @as(f32, @floatFromInt(b)) * t;
}

/// Linear interpolation for u8 values
fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const val = @as(f32, @floatFromInt(a)) * (1 - t) + @as(f32, @floatFromInt(b)) * t;
    return @intFromFloat(@max(0, @min(255, val)));
}

/// Get current time in milliseconds
fn getCurrentTimeMs() u64 {
    return @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))) / 1_000_000;
}

pub fn getActiveWindow() ?*Window {
    return active_window;
}

pub fn getWindowCount() usize {
    return window_count;
}

pub fn iterWindows() []Window {
    return windows[0..window_count];
}

/// Toggle Flip3D mode
pub fn toggleFlip3D() void {
    if (!initialized or window_count == 0) return;

    if (flip3d_state.active) {
        // Exit Flip3D mode
        flip3d_state.active = false;
        flip3d_state.window_list.clearRetainingCapacity();

        // Restore all windows to their original positions
        for (windows[0..window_count]) |*win| {
            if (win.state != .minimized) {
                compositor.setSurfaceVisible(win.surface_id, true);
                compositor.setSurfaceAlpha(win.surface_id, 255);
                // Restore original transform
                compositor.setSurfaceTransform(win.surface_id, 0, 0, 1.0, 0.0);
            }
        }
    } else {
        // Enter Flip3D mode
        flip3d_state.active = true;
        flip3d_state.start_time = getCurrentTimeMs();
        flip3d_state.animation_progress = 0.0;
        flip3d_state.switch_progress = 0.0;

        // Collect all non-minimized windows
        flip3d_state.window_list.clearRetainingCapacity();
        for (windows[0..window_count]) |*win| {
            if (win.state != .minimized) {
                flip3d_state.window_list.append(win) catch {};
            }
        }

        // Select the last active window
        if (flip3d_state.window_list.items.len > 0) {
            flip3d_state.selected_index = flip3d_state.window_list.items.len - 1;
        }
    }
}

/// Process Flip3D key input
pub fn processFlip3DKey(key: enum { left, right, escape, enter }) void {
    if (!initialized or !flip3d_state.active) return;

    const len = flip3d_state.window_list.items.len;
    if (len == 0) return;

    switch (key) {
        .left => {
            if (flip3d_state.selected_index > 0) {
                flip3d_state.selected_index -= 1;
                flip3d_state.last_switch_dir = -1;
                flip3d_state.switch_progress = 0.0;
            }
        },
        .right => {
            if (flip3d_state.selected_index < len - 1) {
                flip3d_state.selected_index += 1;
                flip3d_state.last_switch_dir = 1;
                flip3d_state.switch_progress = 0.0;
            }
        },
        .escape => {
            toggleFlip3D();
        },
        .enter => {
            // Select the current window and exit Flip3D
            const win = flip3d_state.window_list.items[flip3d_state.selected_index];
            setActiveWindow(win);
            toggleFlip3D();
        },
    }
}

/// Process Flip3D mouse wheel input
pub fn processFlip3DWheel(delta: i32) void {
    if (!initialized or !flip3d_state.active) return;

    const len = flip3d_state.window_list.items.len;
    if (len == 0) return;

    if (delta > 0 and flip3d_state.selected_index > 0) {
        flip3d_state.selected_index -= 1;
        flip3d_state.last_switch_dir = -1;
        flip3d_state.switch_progress = 0.0;
    } else if (delta < 0 and flip3d_state.selected_index < len - 1) {
        flip3d_state.selected_index += 1;
        flip3d_state.last_switch_dir = 1;
        flip3d_state.switch_progress = 0.0;
    }
}

/// Update Flip3D animation, should be called every frame
pub fn updateFlip3D() void {
    if (!initialized or !flip3d_state.active) return;

    const now = getCurrentTimeMs();
    const elapsed = now - flip3d_state.start_time;

    // Update enter animation progress
    if (flip3d_state.animation_progress < 1.0) {
        flip3d_state.animation_progress = @min(1.0, @as(f32, @floatFromInt(elapsed)) / 300.0);
    }

    // Update switch animation progress
    if (flip3d_state.switch_progress < 1.0) {
        flip3d_state.switch_progress = @min(1.0, flip3d_state.switch_progress + 0.08);
    }

    const len = flip3d_state.window_list.items.len;
    if (len == 0) return;

    const screen_size = compositor.getScreenSize();
    const center_x = @as(f32, @floatFromInt(screen_size.w)) / 2.0;
    const center_y = @as(f32, @floatFromInt(screen_size.h)) / 2.0;

    // Update each window's position and transform
    for (flip3d_state.window_list.items, 0..) |win, index| {
        const relative_pos = @as(f32, @floatFromInt(index)) - @as(f32, @floatFromInt(flip3d_state.selected_index));

        // Calculate 3D effect parameters
        const z_offset = relative_pos * 150.0; // Depth offset
        const y_offset = relative_pos * 40.0; // Vertical offset
        const scale = 1.0 - @abs(relative_pos) * 0.08; // Scale factor
        const rotation = relative_pos * 5.0; // Rotation angle in degrees
        const alpha = @max(0.3, 1.0 - @abs(relative_pos) * 0.15); // Alpha transparency

        // Apply enter animation
        const enter_progress = 1.0 - std.math.pow(f32, 1.0 - flip3d_state.animation_progress, 3.0);
        const final_z_offset = z_offset * enter_progress;
        const final_y_offset = y_offset * enter_progress;
        const final_scale = 1.0 * (1.0 - enter_progress) + scale * enter_progress;
        const final_rotation = rotation * enter_progress;
        const final_alpha = alpha * enter_progress + 255.0 * (1.0 - enter_progress);

        // Calculate position
        const win_rect = getWindowRect(win);
        const final_x = center_x - @as(f32, @floatFromInt(win_rect.w)) / 2.0 + final_z_offset * 0.5;
        const final_y = center_y - @as(f32, @floatFromInt(win_rect.h)) / 2.0 + final_y_offset;

        // Update window
        compositor.setSurfaceVisible(win.surface_id, true);
        compositor.setSurfaceAlpha(win.surface_id, @intFromFloat(@min(255.0, @max(0.0, final_alpha))));
        compositor.setSurfaceTransform(win.surface_id, @intFromFloat(final_x), @intFromFloat(final_y), final_scale, final_rotation);
        compositor.setSurfaceZOrder(win.surface_id, @intCast(100 + index)); // Ensure correct stacking order
    }
}

/// Get current Flip3D state
pub fn getFlip3DState() *const Flip3DState {
    return &flip3d_state;
}
