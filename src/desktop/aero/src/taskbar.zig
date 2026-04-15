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

//! Aero Taskbar
//! Start orb, quick launch, task buttons, notification area (tray),
//! stacked clock (time + date), and Aero Peek show-desktop strip.
//! 任务栏缩略图 / 实时预览应对接合成器离屏表面（DWM 缩略图概念），见 `compositor` 与 `docs/cn/DesktopManagerSpec.md`。

const std = @import("std");
const theme = @import("theme.zig");
const compositor = @import("compositor.zig");
const window_manager = @import("window_manager.zig");

pub const HitRect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

pub const TaskbarConfig = struct {
    glass_enabled: bool = true,
    height: i32 = theme.Layout.taskbar_height,
};

pub const TaskButton = struct {
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: u8 = 0,
    icon_id: u16 = 0,
    window_id: u32 = compositor.INVALID_SURFACE,
    active: bool = false,
    flashing: bool = false,
    group_id: u8 = 0, // For grouping multiple windows of same app
};

/// Taskbar thumbnail preview
pub const Thumbnail = struct {
    window_id: u32 = compositor.INVALID_SURFACE,
    surface_id: u32 = compositor.INVALID_SURFACE,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    close_button_hover: bool = false,
};

const MAX_THUMBNAILS_PER_GROUP: usize = 8;
const THUMBNAIL_MARGIN: i32 = 8;
const THUMBNAIL_PADDING: i32 = 6;
const CLOSE_BUTTON_SIZE: i32 = 16;

const MAX_TASK_BUTTONS: usize = 32;
var buttons: [MAX_TASK_BUTTONS]TaskButton = [_]TaskButton{.{}} ** MAX_TASK_BUTTONS;
var button_count: usize = 0;
var cfg: TaskbarConfig = .{};
var initialized_flag: bool = false;
/// Shell / 合成器可查询：用户按住 Show Desktop 条时的 Aero Peek 预览态（阶段 2 Shell 占位）。
var aero_peek_active: bool = false;

/// Thumbnail preview state
var show_thumbnails: bool = false;
var hover_button_index: ?usize = null;
var active_thumbnails: [MAX_THUMBNAILS_PER_GROUP]Thumbnail = [_]Thumbnail{.{}} ** MAX_THUMBNAILS_PER_GROUP;
var active_thumbnail_count: usize = 0;
var hover_thumbnail_index: ?usize = null;

/// 开始按钮长按状态
var start_btn_pressed: bool = false;
var start_btn_press_time: u32 = 0;
/// 长按关机阈值（毫秒）
const LONG_PRESS_SHUTDOWN_MS: u32 = 500;

pub fn setAeroPeekActive(active: bool) void {
    aero_peek_active = active;
}

pub fn isAeroPeekActive() bool {
    return aero_peek_active;
}

/// 开始按钮按下时调用（返回是否触发长按关机）
pub fn onStartButtonDown(press_time: u32) bool {
    start_btn_pressed = true;
    start_btn_press_time = press_time;
    return false; // 短按先打开菜单，长按由 updateLongPress 检测
}

/// 开始按钮释放时调用
pub fn onStartButtonUp() void {
    start_btn_pressed = false;
    start_btn_press_time = 0;
}

/// 检查是否触发长按关机（每帧调用）
pub fn updateLongPress(current_time: u32) bool {
    if (!start_btn_pressed) return false;
    if (current_time -% start_btn_press_time >= LONG_PRESS_SHUTDOWN_MS) {
        start_btn_pressed = false;
        start_btn_press_time = 0;
        return true; // 触发关机
    }
    return false;
}

/// 获取开始按钮是否正在被按压
pub fn isStartButtonPressed() bool {
    return start_btn_pressed;
}

pub fn init(config: TaskbarConfig) void {
    cfg = config;
    button_count = 0;
    initialized_flag = true;
}

pub fn getHeight() i32 {
    return cfg.height;
}

pub fn isGlassEnabled() bool {
    return cfg.glass_enabled;
}

pub fn addTask(name: []const u8, icon_id: u16, window_id: u32) void {
    if (button_count >= MAX_TASK_BUTTONS) return;

    // Check if same app group exists
    var group_id: u8 = 0;
    var existing_group: bool = false;
    for (buttons[0..button_count]) |*btn| {
        if (btn.icon_id == icon_id) {
            group_id = btn.group_id;
            existing_group = true;
            break;
        }
    }
    if (!existing_group) {
        group_id = @intCast(button_count);
    }

    var btn = &buttons[button_count];
    const len = @min(name.len, 32);
    for (0..len) |i| {
        btn.name[i] = name[i];
    }
    btn.name_len = @intCast(len);
    btn.icon_id = icon_id;
    btn.window_id = window_id;
    btn.group_id = group_id;
    button_count += 1;
}

pub fn removeTask(window_id: u32) void {
    var i: usize = 0;
    while (i < button_count) {
        if (buttons[i].window_id == window_id) {
            var j = i;
            while (j + 1 < button_count) : (j += 1) {
                buttons[j] = buttons[j + 1];
            }
            buttons[button_count - 1] = .{};
            button_count -= 1;

            // Hide thumbnails if this was the hovered button
            if (hover_button_index == i) {
                hideThumbnails();
            }
            return;
        }
        i += 1;
    }
}

pub fn setActive(icon_id: u16) void {
    for (buttons[0..button_count]) |*btn| {
        btn.active = (btn.icon_id == icon_id);
    }
}

/// 按窗口索引设置活动按钮（由 shell.zig 窗口点击/激活时调用）
pub fn setActiveWindow(index: usize) void {
    var i: usize = 0;
    for (buttons[0..button_count]) |*btn| {
        if (i == index) {
            btn.active = true;
        } else {
            btn.active = false;
        }
        i += 1;
    }
}

/// 获取当前活动按钮索引（用于窗口切换检测）
pub fn getActiveIndex() ?usize {
    for (buttons[0..button_count], 0..) |btn, idx| {
        if (btn.active) return idx;
    }
    return null;
}

pub fn getButtons() []const TaskButton {
    return buttons[0..button_count];
}

/// Get task button rectangle for given index
pub fn getTaskButtonRect(index: usize, screen_w: i32, screen_h: i32) ?HitRect {
    _ = screen_w;
    if (index >= button_count) return null;

    const tb_y = screen_h - cfg.height;
    const start_x = theme.Layout.start_btn_width + 8;
    const btn_w = 160; // Fixed width per task button
    const btn_h = cfg.height - 4;
    const spacing = 4;

    return .{
        .x = start_x + @as(i32, @intCast(index)) * (btn_w + spacing),
        .y = tb_y + 2,
        .w = btn_w,
        .h = btn_h,
    };
}

/// Show thumbnails for a task button (and its group)
pub fn showThumbnailsForButton(index: usize, screen_w: i32, screen_h: i32) void {
    if (index >= button_count) return;

    hideThumbnails();

    hover_button_index = index;
    const group_id = buttons[index].group_id;

    // Collect all windows in this group
    var count: usize = 0;
    for (buttons[0..button_count]) |btn| {
        if (btn.group_id == group_id and count < MAX_THUMBNAILS_PER_GROUP) {
            const thumb = &active_thumbnails[count];
            thumb.* = .{};
            thumb.window_id = btn.window_id;
            thumb.surface_id = compositor.generateWindowThumbnail(btn.window_id);

            if (compositor.getSurface(thumb.surface_id)) |sfc| {
                thumb.w = @as(i32, @intCast(sfc.width)) + THUMBNAIL_PADDING * 2;
                thumb.h = @as(i32, @intCast(sfc.height)) + THUMBNAIL_PADDING * 2 + 24; // 24 for title bar
            }
            count += 1;
        }
    }
    active_thumbnail_count = count;
    if (count == 0) return;

    // Position thumbnails above taskbar, centered above button
    const btn_rect = getTaskButtonRect(index, screen_w, screen_h) orelse return;
    const total_width = @as(i32, @intCast(count)) * (active_thumbnails[0].w + THUMBNAIL_MARGIN) - THUMBNAIL_MARGIN;
    var start_x = btn_rect.x + @divTrunc(btn_rect.w, 2) - @divTrunc(total_width, 2);

    // Clamp to screen
    if (start_x < 0) start_x = 0;
    if (start_x + total_width > screen_w) start_x = screen_w - total_width;

    const start_y = (screen_h - cfg.height) - active_thumbnails[0].h - THUMBNAIL_MARGIN;

    // Set position for each thumbnail
    for (0..count) |i| {
        active_thumbnails[i].x = start_x + @as(i32, @intCast(i)) * (active_thumbnails[i].w + THUMBNAIL_MARGIN);
        active_thumbnails[i].y = start_y;
    }

    show_thumbnails = true;
}

/// Hide all visible thumbnails
pub fn hideThumbnails() void {
    show_thumbnails = false;
    hover_button_index = null;
    hover_thumbnail_index = null;

    // Free thumbnail surfaces
    for (active_thumbnails[0..active_thumbnail_count]) |*thumb| {
        if (thumb.surface_id != compositor.INVALID_SURFACE) {
            compositor.destroySurface(thumb.surface_id);
            thumb.surface_id = compositor.INVALID_SURFACE;
        }
    }
    active_thumbnail_count = 0;

    // Restore normal window state from Aero Peek
    if (compositor.getPeekState() != .disabled) {
        compositor.setPeekState(.disabled, compositor.INVALID_SURFACE);
    }
}

/// Update all thumbnails for current active group
pub fn updateThumbnails() void {
    if (!show_thumbnails) return;

    for (active_thumbnails[0..active_thumbnail_count]) |*thumb| {
        if (thumb.window_id == compositor.INVALID_SURFACE or thumb.surface_id == compositor.INVALID_SURFACE) continue;
        _ = compositor.updateWindowThumbnail(thumb.window_id, thumb.surface_id);
    }
}

/// Handle mouse hover on taskbar
pub fn onMouseHover(x: i32, y: i32, screen_w: i32, screen_h: i32) void {
    // Check if hovering over show desktop button
    if (isClickOnShowDesktopPeek(x, y, screen_w, screen_h)) {
        if (!aero_peek_active) {
            aero_peek_active = true;
            compositor.setPeekState(.desktop_peek, compositor.INVALID_SURFACE);
        }
        return;
    }

    // Check if hovering over task buttons
    for (0..button_count) |i| {
        const rect = getTaskButtonRect(i, screen_w, screen_h) orelse continue;
        if (x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h) {
            if (hover_button_index != i) {
                showThumbnailsForButton(i, screen_w, screen_h);
            }
            return;
        }
    }

    // Check if hovering over thumbnails
    if (show_thumbnails) {
        for (0..active_thumbnail_count) |i| {
            const thumb = &active_thumbnails[i];
            if (x >= thumb.x and x < thumb.x + thumb.w and y >= thumb.y and y < thumb.y + thumb.h) {
                hover_thumbnail_index = i;

                // Activate Aero Peek for this window
                compositor.setPeekState(.window_peek, thumb.window_id);

                // Check if hovering over close button
                const close_x = thumb.x + thumb.w - THUMBNAIL_PADDING - CLOSE_BUTTON_SIZE;
                const close_y = thumb.y + THUMBNAIL_PADDING;
                thumb.close_button_hover = x >= close_x and x < close_x + CLOSE_BUTTON_SIZE and
                    y >= close_y and y < close_y + CLOSE_BUTTON_SIZE;
                return;
            }
        }
    }

    // No hover, reset state
    if (aero_peek_active) {
        aero_peek_active = false;
        compositor.setPeekState(.disabled, compositor.INVALID_SURFACE);
    }

    hover_thumbnail_index = null;
}

/// Handle mouse click on taskbar (including thumbnails)
pub fn onMouseClick(x: i32, y: i32, screen_w: i32, screen_h: i32) void {
    // Check if clicking show desktop button
    if (isClickOnShowDesktopPeek(x, y, screen_w, screen_h)) {
        window_manager.minimizeAll();
        return;
    }

    // Check if clicking on thumbnails
    if (show_thumbnails) {
        for (0..active_thumbnail_count) |i| {
            const thumb = &active_thumbnails[i];
            if (x >= thumb.x and x < thumb.x + thumb.w and y >= thumb.y and y < thumb.y + thumb.h) {
                // Check close button first
                const close_x = thumb.x + thumb.w - THUMBNAIL_PADDING - CLOSE_BUTTON_SIZE;
                const close_y = thumb.y + THUMBNAIL_PADDING;
                if (x >= close_x and x < close_x + CLOSE_BUTTON_SIZE and
                    y >= close_y and y < close_y + CLOSE_BUTTON_SIZE)
                {
                    // Close the window
                    window_manager.closeWindow(thumb.window_id);
                    hideThumbnails();
                    return;
                }

                // Switch to the window
                window_manager.activateWindow(thumb.window_id);
                hideThumbnails();
                return;
            }
        }
    }

    // Check if clicking on task buttons
    for (0..button_count) |i| {
        const rect = getTaskButtonRect(i, screen_w, screen_h) orelse continue;
        if (x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h) {
            if (buttons[i].active) {
                // Minimize if already active
                window_manager.minimizeWindow(buttons[i].window_id);
            } else {
                // Activate the window
                window_manager.activateWindow(buttons[i].window_id);
            }
            return;
        }
    }
}

/// Check if thumbnails are currently visible
pub fn areThumbnailsVisible() bool {
    return show_thumbnails;
}

/// Get active thumbnails for rendering
pub fn getActiveThumbnails() []const Thumbnail {
    return active_thumbnails[0..active_thumbnail_count];
}

/// Get index of currently hovered thumbnail
pub fn getHoveredThumbnailIndex() ?usize {
    return hover_thumbnail_index;
}

pub fn isClickOnStartButton(x: i32, y: i32, screen_h: i32) bool {
    const tb_y = screen_h - cfg.height;
    if (y < tb_y or y >= screen_h) return false;
    const slot_w = theme.Layout.start_btn_width;
    const r = @divTrunc(theme.Layout.start_btn_orb_size, 2);
    const cx = @divTrunc(slot_w, 2);
    const cy = tb_y + @divTrunc(cfg.height, 2);
    const dx = x - cx;
    const dy = y - cy;
    const hit_r = r + 2;
    return dx * dx + dy * dy <= hit_r * hit_r;
}

pub fn isClickOnTaskbar(x: i32, y: i32, screen_h: i32) bool {
    _ = x;
    const tb_y = screen_h - cfg.height;
    return y >= tb_y and y < screen_h;
}

pub fn getGlassTint() u32 {
    return theme.taskbar_glass_tint;
}

pub fn getGlassOpacity() u8 {
    return theme.taskbar_glass_opacity;
}

/// 命中 Show Desktop / Peek 竖条（含右缘 inclusive 边界）。
pub fn isClickOnShowDesktopPeek(x: i32, y: i32, screen_w: i32, screen_h: i32) bool {
    const r = getShowDesktopButtonRect(screen_w, screen_h);
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

/// Far-right vertical strip used for Show Desktop / Aero Peek hit testing.
pub fn getShowDesktopButtonRect(screen_w: i32, screen_h: i32) HitRect {
    const tb_h = cfg.height;
    const peek_w = theme.Layout.show_desktop_peek_width;
    return .{
        .x = screen_w - peek_w,
        .y = screen_h - tb_h,
        .w = peek_w,
        .h = tb_h,
    };
}

/// Typical Win7 tray: network, volume, action center, clock, hidden-icons chevron.
pub const tray_notification_slot_count: usize = 6;
