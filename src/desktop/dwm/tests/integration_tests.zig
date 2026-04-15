// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// Integration Tests - D3D10 DWM 集成测试
// 测试窗口管理、合成器、UI 组件的集成

const std = @import("std");
const dwm = @import("../root.zig");
const compositor = @import("../compositor/compositor.zig");
const surface_mgr = @import("../compositor/surface_mgr.zig");
const window_manager = @import("../window_manager.zig");
const theme = @import("../config/theme.zig");
const ui = @import("../ui/root.zig");

test "DWM initialization" {
    dwm.init();
    try std.testing.expect(dwm.isInitialized());
    dwm.deinit();
}

test "Compositor surface management" {
    dwm.init();

    // 创建表面
    const surface_id = surface_mgr.createSurface(800, 600, .{
        .has_alpha = true,
        .is_visible = true,
    });
    try std.testing.expect(surface_id != 0);

    // 获取表面
    const surface = surface_mgr.getSurface(surface_id);
    try std.testing.expect(surface != null);

    // 销毁表面
    const result = surface_mgr.destroySurface(surface_id);
    try std.testing.expect(result);

    dwm.deinit();
}

test "Window manager basic operations" {
    dwm.init();
    window_manager.initWindowManager();

    // 创建窗口
    const win_id = window_manager.createWindow("Test Window", 400, 300, 100, 100, true);
    try std.testing.expect(win_id != null);

    if (win_id) |wid| {
        // 获取窗口
        const win = window_manager.getWindow(wid);
        try std.testing.expect(win != null);

        // 测试最大化
        if (win) |w| {
            window_manager.maximizeWindow(w);
            try std.testing.expect(w.state == .maximized);
        }

        // 销毁窗口
        const destroyed = window_manager.destroyWindow(wid);
        try std.testing.expect(destroyed);
    }

    window_manager.deinitWindowManager();
    dwm.deinit();
}

test "Window drag and snap" {
    dwm.init();
    window_manager.initWindowManager();

    const win_id = window_manager.createWindow("Snap Test", 400, 300, 100, 100, true);
    try std.testing.expect(win_id != null);

    if (win_id) |wid| {
        const win = window_manager.getWindow(wid);
        if (win) |w| {
            // 测试左边缘吸附
            window_manager.beginDrag(w, 10, 10, .move);
            window_manager.updateDrag(w, 5, 10);
            window_manager.endDrag(w);

            // 测试窗口应该吸附到左边
            // 注意：实际吸附发生在 endDrag 之后
        }
    }

    window_manager.deinitWindowManager();
    dwm.deinit();
}

test "Theme system" {
    dwm.init();

    // 获取主题颜色
    const colors = theme.getColors();
    try std.testing.expect(colors.desktop_background != 0);

    // 检查玻璃效果是否启用
    const glass_enabled = theme.isGlassEnabled();
    _ = glass_enabled; // 可能是 true 或 false

    dwm.deinit();
}

test "Surface z-order" {
    dwm.init();

    // 创建多个表面
    const surfaces = [_]u32{
        surface_mgr.createSurface(100, 100, .{}),
        surface_mgr.createSurface(100, 100, .{}),
        surface_mgr.createSurface(100, 100, .{}),
    };

    for (surfaces) |sid| {
        try std.testing.expect(sid != 0);
    }

    // 设置不同的 z-order
    surface_mgr.setSurfaceZOrder(surfaces[0], 1);
    surface_mgr.setSurfaceZOrder(surfaces[1], 2);
    surface_mgr.setSurfaceZOrder(surfaces[2], 0);

    // 清理
    for (surfaces) |sid| {
        _ = surface_mgr.destroySurface(sid);
    }

    dwm.deinit();
}

test "Cursor position update" {
    dwm.init();

    // 更新光标位置
    compositor.updateCursorPosition(100, 200);

    // 获取光标位置
    const pos = compositor.getCursorPosition();
    try std.testing.expect(pos.x == 100);
    try std.testing.expect(pos.y == 200);

    // 测试隐藏光标
    compositor.setCursorVisible(false);
    try std.testing.expect(!compositor.getCursorLayer().visible);

    // 重新显示
    compositor.setCursorVisible(true);
    try std.testing.expect(compositor.getCursorLayer().visible);

    dwm.deinit();
}

test "Compositor statistics" {
    dwm.init();

    const stats = compositor.getStats();
    try std.testing.expect(stats.total_frames == 0);

    dwm.deinit();
}

test "Hit test surfaces" {
    dwm.init();

    // 创建表面
    const surface_id = surface_mgr.createSurface(100, 100, .{});
    try std.testing.expect(surface_id != 0);

    // 移动表面到 (50, 50)
    if (surface_mgr.getSurface(surface_id)) |sfc| {
        sfc.x = 50;
        sfc.y = 50;
    }

    // 测试命中
    const hit = surface_mgr.hitTestTopMost(75, 75);
    try std.testing.expect(hit != null);

    // 测试未命中
    const miss = surface_mgr.hitTestTopMost(10, 10);
    try std.testing.expect(miss == null);

    _ = surface_mgr.destroySurface(surface_id);
    dwm.deinit();
}

test "Window activation" {
    dwm.init();
    window_manager.initWindowManager();

    // 创建多个窗口
    const win1 = window_manager.createWindow("Window 1", 200, 200, 0, 0, true);
    const win2 = window_manager.createWindow("Window 2", 200, 200, 50, 50, true);

    try std.testing.expect(win1 != null);
    try std.testing.expect(win2 != null);

    if (win1) |w1| {
        if (win2) |w2| {
            // 激活窗口1
            const w1_ptr = window_manager.getWindow(w1);
            const w2_ptr = window_manager.getWindow(w2);

            if (w1_ptr) |wp1| {
                window_manager.activateWindow(wp1);
                try std.testing.expect(window_manager.getActiveWindow().?.surface_id == w1);
            }

            // 激活窗口2
            if (w2_ptr) |wp2| {
                window_manager.activateWindow(wp2);
                try std.testing.expect(window_manager.getActiveWindow().?.surface_id == w2);
            }
        }
    }

    window_manager.deinitWindowManager();
    dwm.deinit();
}
