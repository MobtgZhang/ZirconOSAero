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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/kernel/shell/process_table.zig
// Purpose: Desktop-visible process record table for Task Manager integration.
//
// This is an independent clean-room implementation.

const std = @import("std");
const klog = @import("../../../rtl/klog.zig");
const ps = @import("../../../ps/process.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return b | (g << 8) | (r << 16);
}

/// 桌面进程表条目 - 用于任务管理器显示
pub const DesktopProcessEntry = struct {
    pid: u32,
    name: [48]u8,
    name_len: usize,
    cpu_percent: f32,
    mem_kb: u32,
    state: DesktopProcessState,
    is_visible: bool,       // 是否在任务管理器中可见
    window_title: [64]u8,   // 关联的窗口标题
    window_title_len: usize,
    app_id: u16,            // builtin_apps.BuiltinAppId 对应的ID
};

pub const DesktopProcessState = enum(u8) {
    running = 0,
    not_responding = 1,
    suspended = 2,
};

const MAX_DESKTOP_PROCESSES: usize = 32;

/// 桌面进程记录表
pub var desktop_processes: [MAX_DESKTOP_PROCESSES]DesktopProcessEntry = undefined;
pub var desktop_process_count: usize = 0;

/// 任务管理器显示的应用列表（从shell托管窗口或独立进程）
pub var taskbar_app_list: [MAX_DESKTOP_PROCESSES]TaskbarAppEntry = undefined;
pub var taskbar_app_count: usize = 0;

/// 任务栏应用条目
pub const TaskbarAppEntry = struct {
    app_id: u16,
    pid: u32,
    title: [64]u8,
    title_len: usize,
    is_minimized: bool,
    is_active: bool,
    icon_id: u16,
};

/// 初始化桌面进程表
pub fn initDesktopProcessTable() void {
    desktop_process_count = 0;
    taskbar_app_count = 0;
    for (&desktop_processes) |*p| {
        p.* = .{
            .pid = 0,
            .name = [_]u8{0} ** 48,
            .name_len = 0,
            .cpu_percent = 0.0,
            .mem_kb = 0,
            .state = .running,
            .is_visible = false,
            .window_title = [_]u8{0} ** 64,
            .window_title_len = 0,
            .app_id = 0,
        };
    }
    for (&taskbar_app_list) |*a| {
        a.* = .{
            .app_id = 0,
            .pid = 0,
            .title = [_]u8{0} ** 64,
            .title_len = 0,
            .is_minimized = false,
            .is_active = false,
            .icon_id = 0,
        };
    }
    klog.info("DesktopProcessTable: initialized", .{});
}

/// 注册一个桌面可见的进程
pub fn registerDesktopProcess(
    pid: u32,
    name: []const u8,
    app_id: u16,
    window_title: []const u8,
) bool {
    // 检查是否已存在
    if (findDesktopProcessByPid(pid)) |existing| {
        // 更新现有条目
        @memcpy(existing.name[0..@min(name.len, 48)], name[0..@min(name.len, 48)]);
        existing.name_len = @min(name.len, 48);
        existing.app_id = app_id;
        if (window_title.len > 0) {
            @memcpy(existing.window_title[0..@min(window_title.len, 64)], window_title[0..@min(window_title.len, 64)]);
            existing.window_title_len = @min(window_title.len, 64);
        }
        existing.is_visible = true;
        return true;
    }

    // 添加新条目
    if (desktop_process_count >= MAX_DESKTOP_PROCESSES) {
        klog.warn("DesktopProcessTable: full, cannot register PID={}", .{pid});
        return false;
    }

    var entry = &desktop_processes[desktop_process_count];
    entry.* = .{
        .pid = pid,
        .name = [_]u8{0} ** 48,
        .name_len = 0,
        .cpu_percent = 0.0,
        .mem_kb = 0,
        .state = .running,
        .is_visible = true,
        .window_title = [_]u8{0} ** 64,
        .window_title_len = 0,
        .app_id = app_id,
    };

    @memcpy(entry.name[0..@min(name.len, 48)], name[0..@min(name.len, 48)]);
    entry.name_len = @min(name.len, 48);

    if (window_title.len > 0) {
        @memcpy(entry.window_title[0..@min(window_title.len, 64)], window_title[0..@min(window_title.len, 64)]);
        entry.window_title_len = @min(window_title.len, 64);
    }

    desktop_process_count += 1;
    klog.info("DesktopProcessTable: registered PID={} name='{s}'", .{ pid, entry.name[0..entry.name_len] });
    return true;
}

/// 注销一个桌面可见的进程
pub fn unregisterDesktopProcess(pid: u32) void {
    for (0..desktop_process_count) |i| {
        if (desktop_processes[i].pid == pid) {
            // 标记为不可见而不是删除，保持数组紧凑
            desktop_processes[i].is_visible = false;
            desktop_processes[i].pid = 0;
            klog.info("DesktopProcessTable: unregistered PID={}", .{pid});
            return;
        }
    }
}

/// 根据PID查找进程
pub fn findDesktopProcessByPid(pid: u32) ?*DesktopProcessEntry {
    for (&desktop_processes) |*p| {
        if (p.pid == pid and p.is_visible) return p;
    }
    return null;
}

/// 更新进程的CPU使用率
pub fn updateProcessCpu(pid: u32, cpu_percent: f32) void {
    if (findDesktopProcessByPid(pid)) |p| {
        p.cpu_percent = cpu_percent;
    }
}

/// 更新进程的内存使用
pub fn updateProcessMem(pid: u32, mem_kb: u32) void {
    if (findDesktopProcessByPid(pid)) |p| {
        p.mem_kb = mem_kb;
    }
}

/// 更新进程状态
pub fn updateProcessState(pid: u32, state: DesktopProcessState) void {
    if (findDesktopProcessByPid(pid)) |p| {
        p.state = state;
    }
}

/// 更新进程窗口标题
pub fn updateProcessWindowTitle(pid: u32, title: []const u8) void {
    if (findDesktopProcessByPid(pid)) |p| {
        @memcpy(p.window_title[0..@min(title.len, 64)], title[0..@min(title.len, 64)]);
        p.window_title_len = @min(title.len, 64);
    }
}

/// 获取可见进程数量
pub fn getVisibleProcessCount() usize {
    var count: usize = 0;
    for (&desktop_processes) |*p| {
        if (p.is_visible and p.pid != 0) count += 1;
    }
    return count;
}

/// 获取可见进程列表
pub fn getVisibleProcessList() []DesktopProcessEntry {
    var result: [MAX_DESKTOP_PROCESSES]DesktopProcessEntry = undefined;
    var count: usize = 0;
    for (&desktop_processes) |*p| {
        if (p.is_visible and p.pid != 0) {
            result[count] = p.*;
            count += 1;
        }
    }
    // 返回静态切片，需要调用者处理
    return result[0..count];
}

/// 同步内核进程表到桌面进程表
pub fn syncFromKernelProcessTable() void {
    const kernel_procs = ps.getProcessList();
    for (kernel_procs) |*kp| {
        if (kp.state == .terminated or kp.state == .creating) continue;
        if (!findDesktopProcessByPid(kp.pid)) {
            // 新进程，注册为桌面可见
            const name_slice = kp.name[0..kp.name_len];
            _ = registerDesktopProcess(kp.pid, name_slice, 0, &[_]u8{});
        }
    }
    // 清理已终止的内核进程
    for (&desktop_processes) |*p| {
        if (p.pid == 0) continue;
        const kp = ps.findProcess(p.pid);
        if (kp == null or kp.?.state == .terminated) {
            p.is_visible = false;
            p.pid = 0;
        }
    }
}

// ── 任务栏应用列表管理 ─────────────────────────────────────────────────────────

/// 添加应用到任务栏
pub fn addTaskbarApp(
    app_id: u16,
    pid: u32,
    title: []const u8,
    icon_id: u16,
) bool {
    // 检查是否已存在
    for (0..taskbar_app_count) |i| {
        if (taskbar_app_list[i].app_id == app_id and taskbar_app_list[i].pid == pid) {
            return true;
        }
    }

    if (taskbar_app_count >= MAX_DESKTOP_PROCESSES) return false;

    var entry = &taskbar_app_list[taskbar_app_count];
    entry.* = .{
        .app_id = app_id,
        .pid = pid,
        .title = [_]u8{0} ** 64,
        .title_len = 0,
        .is_minimized = false,
        .is_active = true,
        .icon_id = icon_id,
    };

    @memcpy(entry.title[0..@min(title.len, 64)], title[0..@min(title.len, 64)]);
    entry.title_len = @min(title.len, 64);

    // 设置为活动
    for (0..taskbar_app_count) |i| {
        taskbar_app_list[i].is_active = false;
    }
    taskbar_app_count += 1;
    return true;
}

/// 从任务栏移除应用
pub fn removeTaskbarApp(app_id: u16, pid: u32) void {
    var shift_needed = false;
    var shift_from: usize = 0;

    for (0..taskbar_app_count) |i| {
        if (taskbar_app_list[i].app_id == app_id and taskbar_app_list[i].pid == pid) {
            shift_needed = true;
            shift_from = i;
        } else if (shift_needed) {
            taskbar_app_list[i - 1] = taskbar_app_list[i];
        }
    }

    if (shift_needed) {
        taskbar_app_count -= 1;
        // 设置最后一个为活动
        if (taskbar_app_count > 0) {
            taskbar_app_list[taskbar_app_count - 1].is_active = true;
        }
    }
}

/// 设置应用最小化状态
pub fn setTaskbarAppMinimized(app_id: u16, pid: u32, minimized: bool) void {
    for (0..taskbar_app_count) |i| {
        if (taskbar_app_list[i].app_id == app_id and taskbar_app_list[i].pid == pid) {
            taskbar_app_list[i].is_minimized = minimized;
            return;
        }
    }
}

/// 激活指定应用
pub fn activateTaskbarApp(app_id: u16, pid: u32) void {
    for (0..taskbar_app_count) |i| {
        taskbar_app_list[i].is_active = (taskbar_app_list[i].app_id == app_id and taskbar_app_list[i].pid == pid);
        if (taskbar_app_list[i].is_active) {
            taskbar_app_list[i].is_minimized = false;
        }
    }
}

/// 获取活动应用
pub fn getActiveTaskbarApp() ?*TaskbarAppEntry {
    for (&taskbar_app_list[0..taskbar_app_count]) |*a| {
        if (a.is_active) return a;
    }
    return null;
}

/// 获取任务栏应用数量
pub fn getTaskbarAppCount() usize {
    return taskbar_app_count;
}

/// 获取任务栏应用列表
pub fn getTaskbarAppList() []TaskbarAppEntry {
    return taskbar_app_list[0..taskbar_app_count];
}

// ── 任务栏键盘导航 ─────────────────────────────────────────────────────────

var taskbar_selected_index: usize = 0;
var taskbar_navigation_active: bool = false;

pub fn isTaskbarNavigationActive() bool {
    return taskbar_navigation_active;
}

pub fn activateTaskbarNavigation(active: bool) void {
    taskbar_navigation_active = active;
    if (active) {
        taskbar_selected_index = 0;
    }
}

/// 获取任务栏当前选中的索引
pub fn getTaskbarSelectedIndex() usize {
    return taskbar_selected_index;
}

/// 键盘导航：在任务栏中向上移动
pub fn navigateTaskbarUp() void {
    if (taskbar_app_count == 0) return;

    if (taskbar_selected_index == 0) {
        taskbar_selected_index = taskbar_app_count - 1;
    } else {
        taskbar_selected_index -= 1;
    }

    // 激活选中的应用
    if (taskbar_selected_index < taskbar_app_count) {
        activateTaskbarApp(taskbar_app_list[taskbar_selected_index].app_id, taskbar_app_list[taskbar_selected_index].pid);
    }
}

/// 键盘导航：在任务栏中向下移动
pub fn navigateTaskbarDown() void {
    if (taskbar_app_count == 0) return;

    if (taskbar_selected_index >= taskbar_app_count - 1) {
        taskbar_selected_index = 0;
    } else {
        taskbar_selected_index += 1;
    }

    // 激活选中的应用
    if (taskbar_selected_index < taskbar_app_count) {
        activateTaskbarApp(taskbar_app_list[taskbar_selected_index].app_id, taskbar_app_list[taskbar_selected_index].pid);
    }
}

/// 键盘导航：在任务栏中向左移动（上一个任务栏按钮）
pub fn navigateTaskbarLeft() void {
    if (taskbar_app_count == 0) return;

    if (taskbar_selected_index == 0) {
        taskbar_selected_index = taskbar_app_count - 1;
    } else {
        taskbar_selected_index -= 1;
    }

    // 激活选中的应用
    if (taskbar_selected_index < taskbar_app_count) {
        activateTaskbarApp(taskbar_app_list[taskbar_selected_index].app_id, taskbar_app_list[taskbar_selected_index].pid);
    }
}

/// 键盘导航：在任务栏中向右移动（下一个任务栏按钮）
pub fn navigateTaskbarRight() void {
    if (taskbar_app_count == 0) return;

    if (taskbar_selected_index >= taskbar_app_count - 1) {
        taskbar_selected_index = 0;
    } else {
        taskbar_selected_index += 1;
    }

    // 激活选中的应用
    if (taskbar_selected_index < taskbar_app_count) {
        activateTaskbarApp(taskbar_app_list[taskbar_selected_index].app_id, taskbar_app_list[taskbar_selected_index].pid);
    }
}

/// 激活当前选中的应用
pub fn activateSelectedTaskbarApp() void {
    if (taskbar_selected_index < taskbar_app_count) {
        const entry = taskbar_app_list[taskbar_selected_index];
        activateTaskbarApp(entry.app_id, entry.pid);
    }
}
