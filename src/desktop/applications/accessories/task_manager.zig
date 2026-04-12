// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/desktop/applications/accessories/task_manager.zig
// Purpose: Windows 7 style Task Manager
//
// This is an independent clean-room implementation.

const std = @import("std");
const fb = @import("../../../drivers/video/core/framebuffer.zig");
const theme_mod = @import("../../kernel/theme/root.zig");
const dwm_mod = @import("../../../drivers/video/core/dwm.zig");
const process_table = @import("../../kernel/shell/process_table.zig");

fn rgb(r: u32, g: u32, b: u32) u32 {
    return theme_mod.rgb(r, g, b);
}

pub const TaskManagerTab = enum {
    applications,
    processes,
    performance,
    networking,
    users,
};

pub const TaskManager = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    visible: bool,
    focused: bool,
    current_tab: TaskManagerTab,
    selected_app: i32,
    selected_process: i32,
    hover_app: i32,
    hover_process: i32,
    caption_hover: CaptionButtonType,

    const CaptionButtonType = enum { none, minimize, maximize, close };

    pub fn create(x_pos: i32, y_pos: i32) TaskManager {
        return .{
            .x = x_pos, .y = y_pos,
            .width = 600, .height = 500,
            .visible = true,
            .focused = false,
            .current_tab = .applications,
            .selected_app = -1,
            .selected_process = -1,
            .hover_app = -1,
            .hover_process = -1,
            .caption_hover = .none,
        };
    }

    pub fn setTab(tm: *TaskManager, tab: TaskManagerTab) void {
        tm.current_tab = tab;
    }

    /// 键盘导航：在应用列表中向上移动
    pub fn navigateAppsUp(tm: *TaskManager) void {
        const taskbar_apps = process_table.getTaskbarAppList();
        const app_count = @as(i32, @intCast(@min(taskbar_apps.len, 16)));

        if (app_count == 0) return;

        if (tm.selected_app <= 0) {
            tm.selected_app = app_count - 1;
        } else {
            tm.selected_app -= 1;
        }
    }

    /// 键盘导航：在应用列表中向下移动
    pub fn navigateAppsDown(tm: *TaskManager) void {
        const taskbar_apps = process_table.getTaskbarAppList();
        const app_count = @as(i32, @intCast(@min(taskbar_apps.len, 16)));

        if (app_count == 0) return;

        if (tm.selected_app >= app_count - 1) {
            tm.selected_app = 0;
        } else {
            tm.selected_app += 1;
        }
    }

    /// 键盘导航：在进程列表中向上移动
    pub fn navigateProcessesUp(tm: *TaskManager) void {
        const processes = process_table.getVisibleProcessList();
        const proc_count = @as(i32, @intCast(@min(processes.len, 20)));

        if (proc_count == 0) return;

        if (tm.selected_process <= 0) {
            tm.selected_process = proc_count - 1;
        } else {
            tm.selected_process -= 1;
        }
    }

    /// 键盘导航：在进程列表中向下移动
    pub fn navigateProcessesDown(tm: *TaskManager) void {
        const processes = process_table.getVisibleProcessList();
        const proc_count = @as(i32, @intCast(@min(processes.len, 20)));

        if (proc_count == 0) return;

        if (tm.selected_process >= proc_count - 1) {
            tm.selected_process = 0;
        } else {
            tm.selected_process += 1;
        }
    }

    /// 键盘导航：Tab 键切换标签页
    pub fn navigateTabNext(tm: *TaskManager) void {
        tm.current_tab = switch (tm.current_tab) {
            .applications => .processes,
            .processes => .performance,
            .performance => .networking,
            .networking => .users,
            .users => .applications,
        };
    }

    /// 键盘导航：Shift+Tab 切换到上一个标签页
    pub fn navigateTabPrev(tm: *TaskManager) void {
        tm.current_tab = switch (tm.current_tab) {
            .applications => .users,
            .processes => .applications,
            .performance => .processes,
            .networking => .performance,
            .users => .networking,
        };
    }

    /// 处理键盘导航（根据当前标签页）
    pub fn handleNavigate(tm: *TaskManager, direction: NavigationDirection) void {
        switch (tm.current_tab) {
            .applications, .processes => {
                // 应用和进程列表使用上下键导航
                switch (direction) {
                    .up => {
                        if (tm.current_tab == .applications) {
                            tm.navigateAppsUp();
                        } else {
                            tm.navigateProcessesUp();
                        }
                    },
                    .down => {
                        if (tm.current_tab == .applications) {
                            tm.navigateAppsDown();
                        } else {
                            tm.navigateProcessesDown();
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    pub const NavigationDirection = enum {
        up,
        down,
        left,
        right,
    };

    /// 刷新任务管理器数据
    pub fn refresh(tm: *TaskManager) void {
        // 同步进程表
        process_table.syncFromKernelProcessTable();
        // 更新任务栏应用列表
        _ = tm;
    }

    pub fn render(tm: *TaskManager, t: *const theme_mod.ThemeColors) void {
        if (!tm.visible) return;
        tm.renderWindowFrame(t);
        tm.renderTabBar(t);
        tm.renderContent(t);
        tm.renderStatusBar(t);
    }

    fn renderWindowFrame(tm: *TaskManager, t: *const theme_mod.ThemeColors) void {
        const wx = tm.x;
        const wy = tm.y;
        const ww = tm.width;
        const wh = tm.height;
        const ch: i32 = 32;

        if (dwm_mod.isInitialized() and dwm_mod.getConfig().shadow_enabled) {
            fb.fillRect(wx + 4, wy + 4, ww, wh, rgb(0x28, 0x28, 0x30));
        }

        fb.fillRect(wx, wy + ch, ww, wh - ch, rgb(0xF0, 0xF4, 0xF8));

        if (dwm_mod.isGlassEnabled()) {
            dwm_mod.renderGlassEffect(wx, wy, ww, ch, t.titlebar_active_left, .caption);
        } else {
            fb.drawGradientH(wx, wy, ww, ch, t.titlebar_active_left, t.titlebar_active_right);
        }

        tm.renderCaptionButtons(t);
        fb.drawTextTransparent(wx + 8, wy + 10, "Windows Task Manager", t.titlebar_text);
        fb.draw3DRect(wx, wy, ww, wh, rgb(0xE8, 0xF0, 0xF8), rgb(0x50, 0x60, 0x70));
    }

    fn renderCaptionButtons(tm: *TaskManager, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const wx = tm.x;
        const wy = tm.y;
        const ww = tm.width;
        const ch: i32 = 32;

        const btn_h = 18;
        const btn_y = wy + @divTrunc(ch - btn_h, 2);
        const btn_w_close: i32 = 48;
        const close_x = wx + ww - btn_w_close;

        if (tm.caption_hover == .close) {
            fb.fillRect(close_x, btn_y, btn_w_close, btn_h, rgb(0xE8, 0x11, 0x23));
        }

        const cx = close_x + @divTrunc(btn_w_close, 2);
        const cy = btn_y + @divTrunc(btn_h, 2);
        var d: i32 = -4;
        while (d <= 4) : (d += 1) {
            fb.putPixel32(@intCast(cx + d), @intCast(cy + d), if (tm.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
            fb.putPixel32(@intCast(cx + d), @intCast(cy - d), if (tm.caption_hover == .close) rgb(0xFF, 0xFF, 0xFF) else rgb(0xE8, 0xF2, 0xFA));
        }
    }

    fn renderTabBar(tm: *TaskManager, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const tx = tm.x + 4;
        const ty = tm.y + 36;
        const th: i32 = 28;

        fb.fillRect(tx, ty, tm.width - 8, th, rgb(0xEC, 0xEC, 0xEC));
        fb.drawHLine(tx, ty + th - 1, tm.width - 8, rgb(0xC0, 0xC8, 0xD8));

        const tabs = [_][]const u8{ "Applications", "Processes", "Performance", "Networking", "Users" };
        var tab_x = tx + 8;
        for (tabs, 0..) |tab, idx| {
            const is_active = @as(TaskManagerTab, @enumFromInt(idx)) == tm.current_tab;
            const tab_w: i32 = @as(i32, @intCast(tab.len)) * 7 + 16;

            if (is_active) {
                fb.fillRect(tab_x, ty + 2, tab_w, th - 4, rgb(0xF8, 0xFC, 0xFF));
                fb.drawHLine(tab_x, ty + th - 2, tab_w, rgb(0xF8, 0xFC, 0xFF));
            } else {
                fb.fillRect(tab_x, ty + 4, tab_w, th - 6, rgb(0xEC, 0xEC, 0xEC));
            }

            fb.drawTextTransparent(tab_x + 8, ty + 7, tab, if (is_active) rgb(0x10, 0x40, 0x90) else rgb(0x30, 0x30, 0x40));
            tab_x += tab_w + 8;
        }
    }

    fn renderContent(tm: *TaskManager, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const cx = tm.x + 8;
        const cy = tm.y + 70;
        const cw = tm.width - 16;
        const ch = tm.height - 110;

        fb.fillRect(cx, cy, cw, ch, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(cx, cy, cw, ch, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        switch (tm.current_tab) {
            .applications => tm.renderApplicationsTab(cx, cy, cw, ch),
            .processes => tm.renderProcessesTab(cx, cy, cw, ch),
            .performance => tm.renderPerformanceTab(cx, cy, cw, ch),
            .networking => tm.renderNetworkingTab(cx, cy, cw, ch),
            .users => tm.renderUsersTab(cx, cy, cw, ch),
        }
    }

    fn renderApplicationsTab(tm: *TaskManager, x: i32, y: i32, w: i32, h: i32) void {
        _ = h;
        fb.drawHLine(x + 2, y + 22, @as(i32, @intCast(w)) - 4, rgb(0xC0, 0xC8, 0xD0));
        fb.drawTextTransparent(x + 8, y + 5, "Task Name", rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(x + w - 80, y + 5, "Status", rgb(0x20, 0x20, 0x30));

        // 从任务栏应用列表获取数据
        const taskbar_apps = process_table.getTaskbarAppList();
        const app_count = @min(taskbar_apps.len, 16); // 最多显示16个

        var app_y = y + 28;
        var idx: i32 = 0;
        while (idx < app_count) : (idx += 1) {
            const app = taskbar_apps[@intCast(idx)];
            const is_selected = idx == tm.selected_app;
            const is_hover = idx == tm.hover_app;

            if (is_selected) {
                fb.fillRect(x + 2, app_y, w - 4, 20, rgb(0xC8, 0xDC, 0xF0));
            } else if (is_hover) {
                fb.fillRect(x + 2, app_y, w - 4, 20, rgb(0xE8, 0xF0, 0xF8));
            }

            // 绘制应用名称
            const name_slice = app.title[0..app.title_len];
            fb.drawTextTransparent(x + 8, app_y + 4, name_slice, rgb(0x10, 0x10, 0x18));

            // 绘制状态
            const status: []const u8 = if (app.is_minimized) "Minimized" else "Running";
            fb.drawTextTransparent(x + w - 80, app_y + 4, status, rgb(0x20, 0x80, 0x20));

            app_y += 22;
        }

        // 如果没有应用，显示默认信息
        if (app_count == 0) {
            fb.drawTextTransparent(x + 8, app_y, "(No running applications)", rgb(0x80, 0x80, 0x80));
        }
    }

    fn renderProcessesTab(tm: *TaskManager, x: i32, y: i32, w: i32, h: i32) void {
        _ = h;
        fb.drawHLine(x + 2, y + 22, @as(i32, @intCast(w)) - 4, rgb(0xC0, 0xC8, 0xD0));
        fb.drawTextTransparent(x + 8, y + 5, "Process Name", rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(x + 200, y + 5, "PID", rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(x + 260, y + 5, "CPU", rgb(0x20, 0x20, 0x30));
        fb.drawTextTransparent(x + 320, y + 5, "Memory", rgb(0x20, 0x20, 0x30));

        // 从桌面进程表获取数据
        const processes = process_table.getVisibleProcessList();
        const proc_count = @min(processes.len, 20); // 最多显示20个

        var proc_y = y + 28;
        var idx: i32 = 0;
        while (idx < proc_count) : (idx += 1) {
            const proc = processes[@intCast(idx)];
            const is_selected = idx == tm.selected_process;
            const is_hover = idx == tm.hover_process;

            if (is_selected) {
                fb.fillRect(x + 2, proc_y, w - 4, 18, rgb(0xC8, 0xDC, 0xF0));
            } else if (is_hover) {
                fb.fillRect(x + 2, proc_y, w - 4, 18, rgb(0xE8, 0xF0, 0xF8));
            }

            // 绘制进程名称
            const name_slice = proc.name[0..proc.name_len];
            fb.drawTextTransparent(x + 8, proc_y + 2, name_slice, rgb(0x10, 0x10, 0x18));

            // 绘制PID
            var pid_buf: [16]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{proc.pid}) catch "";
            fb.drawTextTransparent(x + 200, proc_y + 2, pid_str, rgb(0x10, 0x10, 0x18));

            // 绘制CPU使用率
            var cpu_buf: [16]u8 = undefined;
            const cpu_str = std.fmt.bufPrint(&cpu_buf, "{d:.1}%", .{proc.cpu_percent}) catch "";
            fb.drawTextTransparent(x + 260, proc_y + 2, cpu_str, rgb(0x10, 0x10, 0x18));

            // 绘制内存使用
            var mem_buf: [16]u8 = undefined;
            const mem_str = std.fmt.bufPrint(&mem_buf, "{d}K", .{proc.mem_kb}) catch "";
            fb.drawTextTransparent(x + 320, proc_y + 2, mem_str, rgb(0x10, 0x10, 0x18));

            proc_y += 20;
        }

        // 如果没有进程，显示默认信息
        if (proc_count == 0) {
            fb.drawTextTransparent(x + 8, proc_y, "(No processes)", rgb(0x80, 0x80, 0x80));
        }
    }

    fn renderPerformanceTab(tm: *TaskManager, x: i32, y: i32, w: i32, h: i32) void {
        _ = tm;
        const graph_w = @divTrunc(w, 2) - 20;
        const graph_h = @as(i32, @intCast(@as(f32, @floatFromInt(h)) * 0.6));

        fb.drawTextTransparent(x + 8, y + 8, "CPU Usage", rgb(0x20, 0x40, 0x80));
        fb.fillRect(x + 8, y + 28, graph_w, graph_h, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(x + 8, y + 28, graph_w, graph_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        // 获取进程数量
        const proc_count = process_table.getVisibleProcessCount();

        // 模拟CPU使用率（实际需要从内核采样）
        var graph_x = x + 12;
        const graph_y = y + 30;
        var cpu_val: f32 = @as(f32, @floatFromInt(proc_count)) * 3.0; // 基于进程数估算
        while (graph_x < x + 8 + graph_w - 2) : (graph_x += 3) {
            cpu_val += (std.mem.readIntLittle(u32, &[_]u8{0}) % 10) - 5;
            if (cpu_val < 5) cpu_val = 5;
            if (cpu_val > 90) cpu_val = 90;
            const bar_h = @as(i32, @intCast(@as(f32, @floatFromInt(graph_h - 4)) * cpu_val / 100.0));
            fb.fillRect(graph_x, graph_y + graph_h - 4 - bar_h, 2, bar_h, rgb(0x00, 0xC0, 0x60));
        }

        fb.drawTextTransparent(x + graph_w + 30, y + 8, "Memory Usage", rgb(0x20, 0x40, 0x80));
        fb.fillRect(x + graph_w + 30, y + 28, graph_w, graph_h, rgb(0xFF, 0xFF, 0xFF));
        fb.draw3DRect(x + graph_w + 30, y + 28, graph_w, graph_h, rgb(0xC0, 0xC8, 0xD0), rgb(0xFF, 0xFF, 0xFF));

        // 显示内存信息
        var mem_buf: [64]u8 = undefined;
        const mem_str = std.fmt.bufPrint(&mem_buf, "Processes: {d}", .{proc_count}) catch "";
        fb.drawTextTransparent(x + graph_w + 40, y + graph_h + 40, mem_str, rgb(0x20, 0x20, 0x30));
    }

    fn renderNetworkingTab(tm: *TaskManager, x: i32, y: i32, w: i32, h: i32) void {
        _ = tm;
        const _h = h;
        const _w = w;
        fb.drawTextTransparent(x + 8, y + 8, "Network Adapters", rgb(0x20, 0x40, 0x80));
        fb.drawHLine(x + 2, y + 26, _w - 4, rgb(0xC0, 0xC8, 0xD0));
        _ = _h;
        fb.drawTextTransparent(x + 8, y + 30, "Adapter: VirtIO Network Adapter", rgb(0x10, 0x10, 0x18));
        fb.drawTextTransparent(x + 8, y + 50, "Status: Connected", rgb(0x20, 0x80, 0x20));
        fb.drawTextTransparent(x + 8, y + 70, "Speed: 1 Gbps", rgb(0x10, 0x10, 0x18));
    }

    fn renderUsersTab(tm: *TaskManager, x: i32, y: i32, w: i32, h: i32) void {
        _ = tm;
        const _w = w;
        const _h = h;
        fb.drawTextTransparent(x + 8, y + 8, "Users", rgb(0x20, 0x40, 0x80));
        fb.drawHLine(x + 2, y + 26, _w - 4, rgb(0xC0, 0xC8, 0xD0));
        _ = _h;
        fb.drawTextTransparent(x + 8, y + 30, "User: Administrator", rgb(0x10, 0x10, 0x18));
        fb.drawTextTransparent(x + 8, y + 50, "Session: Active", rgb(0x20, 0x80, 0x20));
    }

    fn renderStatusBar(tm: *TaskManager, t: *const theme_mod.ThemeColors) void {
        _ = t;
        const sx = tm.x + 4;
        const sy = tm.y + tm.height - 24;
        const sw = tm.width - 8;

        fb.fillRect(sx, sy, sw, 20, rgb(0xE8, 0xEC, 0xF0));
        fb.drawHLine(sx, sy, sw, rgb(0xFF, 0xFF, 0xFF));

        // 使用真实的进程数量
        const proc_count = process_table.getVisibleProcessCount();

        var proc_buf: [32]u8 = undefined;
        const proc_str = std.fmt.bufPrint(&proc_buf, "{d} processes", .{proc_count}) catch "";
        fb.drawTextTransparent(sx + 8, sy + 4, proc_str, rgb(0x30, 0x30, 0x40));
        fb.drawTextTransparent(sx + sw - 100, sy + 4, "Performance: Normal", rgb(0x30, 0x30, 0x40));
    }
};
