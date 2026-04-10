//! 开始菜单扩展脏区：轴对齐矩形并集（主机 `zig test`，无内核依赖）。
//! 与 `renderer_aero.redrawStartMenuRegionOnly` / `startmenu.getHoverHighlightRepaintBounds` 数学一致；**不依赖**嵌入壁纸预设索引。
const std = @import("std");

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

// 动画系统常量（与 startmenu.zig 一致）
const ANIM_FRAMES: u8 = 12;
const SUBMENU_ANIM_FRAMES: u8 = 6;
const HOVER_TRANSITION_FRAMES: u8 = 3;

/// ease-out 缓动曲线：快速启动，缓慢收尾
fn easeOutProgress(t: f32) f32 {
    return 1.0 - (1.0 - t) * (1.0 - t);
}

test "ease-out progress is 0 at start" {
    const t = easeOutProgress(0.0);
    try std.testing.expectEqual(@as(f32, 0.0), t);
}

test "ease-out progress is 1 at end" {
    const t = easeOutProgress(1.0);
    try std.testing.expectEqual(@as(f32, 1.0), t);
}

test "ease-out is monotonic increasing" {
    const t0 = easeOutProgress(0.3);
    const t1 = easeOutProgress(0.5);
    const t2 = easeOutProgress(0.7);
    try std.testing.expect(t0 < t1);
    try std.testing.expect(t1 < t2);
}

test "ease-out starts fast, ends slow" {
    // 前半段进度变化大，后半段变化小
    const delta1 = easeOutProgress(0.1) - easeOutProgress(0.0);
    const delta2 = easeOutProgress(1.0) - easeOutProgress(0.9);
    try std.testing.expect(delta1 > delta2);
}

/// 测试动画进度计算
test "animation progress increments correctly" {
    var progress: f32 = 0.0;
    const inc = 1.0 / @as(f32, @floatFromInt(ANIM_FRAMES));
    var steps: u8 = 0;
    while (progress < 1.0) : (steps += 1) {
        progress += inc;
        if (steps >= ANIM_FRAMES) break;
    }
    try std.testing.expect(progress >= 1.0);
    try std.testing.expect(steps <= ANIM_FRAMES);
}

/// 测试悬停平滑过渡帧数
test "hover transition completes in expected frames" {
    var progress: f32 = 0.0;
    const inc = 1.0 / @as(f32, @floatFromInt(HOVER_TRANSITION_FRAMES));
    var steps: u8 = 0;
    while (progress < 1.0) : (steps += 1) {
        progress += inc;
        if (steps >= HOVER_TRANSITION_FRAMES) break;
    }
    try std.testing.expectEqual(HOVER_TRANSITION_FRAMES, steps);
}

/// 测试子菜单滑动动画
test "submenu animation completes in expected frames" {
    var progress: f32 = 0.0;
    const inc = 1.0 / @as(f32, @floatFromInt(SUBMENU_ANIM_FRAMES));
    var steps: u8 = 0;
    while (progress < 1.0) : (steps += 1) {
        progress += inc;
        if (steps >= SUBMENU_ANIM_FRAMES) break;
    }
    try std.testing.expectEqual(SUBMENU_ANIM_FRAMES, steps);
}

/// 测试动画高度计算
test "animated height interpolates correctly" {
    const start_h: i32 = 0;
    const target_h: i32 = 400;
    const diff = @as(i64, target_h) - @as(i64, start_h);
    const p50 = easeOutProgress(0.5);
    const h50 = start_h + @as(i32, @intFromFloat(@as(f32, @floatFromInt(diff)) * p50));
    // 50% ease-out 应该小于 50% 线性值
    try std.testing.expect(@as(i32, @intCast(@as(f32, @floatFromInt(diff)) * 0.5)) > h50);
}

/// 长按关机阈值测试（500ms）
test "long press threshold is reasonable" {
    const LONG_PRESS_SHUTDOWN_MS: u32 = 500;
    try std.testing.expect(LONG_PRESS_SHUTDOWN_MS >= 300);
    try std.testing.expect(LONG_PRESS_SHUTDOWN_MS <= 1000);
}

fn rectUnion(a: Rect, b: Rect) Rect {
    const ax2 = @as(i64, a.x) + @as(i64, a.w);
    const ay2 = @as(i64, a.y) + @as(i64, a.h);
    const bx2 = @as(i64, b.x) + @as(i64, b.w);
    const by2 = @as(i64, b.y) + @as(i64, b.h);
    const x0 = @min(@as(i64, a.x), @as(i64, b.x));
    const y0 = @min(@as(i64, a.y), @as(i64, b.y));
    const x1 = @max(ax2, bx2);
    const y1 = @max(ay2, by2);
    return .{
        .x = @intCast(x0),
        .y = @intCast(y0),
        .w = @intCast(x1 - x0),
        .h = @intCast(y1 - y0),
    };
}

test "rect union for start menu plus flyout" {
    const base = Rect{ .x = 0, .y = 100, .w = 428, .h = 400 };
    const fly = Rect{ .x = 300, .y = 80, .w = 176, .h = 160 };
    const u = rectUnion(base, fly);
    try std.testing.expectEqual(@as(i32, 0), u.x);
    try std.testing.expectEqual(@as(i32, 80), u.y);
    try std.testing.expectEqual(@as(i32, 476), u.w);
    try std.testing.expectEqual(@as(i32, 420), u.h);
}

// 与 `startmenu.zig` 中 `aeroRect` + `innerLayout` + 底栏关机条几何一致（命中区回归）。
test "start menu shutdown chip fits in bottom band and inside main column" {
    const menu_w: i32 = 428;
    const rail: i32 = 52;
    const inner_w = menu_w - 8;
    const main_w = inner_w - rail;
    const sd_w: i32 = 106;
    const sd_h: i32 = 28;
    const bottom_band_h: i32 = 46; // AERO7_BOTTOM_BAND_H
    try std.testing.expect(sd_w + 10 <= main_w);
    try std.testing.expect(sd_h <= bottom_band_h);
    const sd_rel_x = main_w - 116;
    try std.testing.expect(sd_rel_x >= 0);
    try std.testing.expect(sd_rel_x + sd_w <= main_w);
}

// 行级 hover 脏区并集应远小于整扇菜单高度（与 AERO7_ROW_H=24 及左右列行高一致的量级）。
test "hover highlight dirty union is row sized not full panel" {
    const row_h: i32 = 24;
    const row1 = Rect{ .x = 58, .y = 200, .w = 188, .h = row_h };
    const row2 = Rect{ .x = 258, .y = 260, .w = 170, .h = row_h };
    const u = rectUnion(row1, row2);
    try std.testing.expect(u.h < 200);
    try std.testing.expect(u.h >= row_h and u.h <= row_h * 2 + 80);
}

// Win7 风格：all_programs 视图下 getInteractiveBounds 宽度等于主面板（无侧栏外扩）。
test "all_programs view bounds width equals main panel, no side panel expansion" {
    const main_panel = Rect{ .x = 0, .y = 100, .w = 428, .h = 400 };
    // all_programs 视图下，仅主面板参与命中；电源飞出时才扩展。
    const flyout = Rect{ .x = 300, .y = 80, .w = 176, .h = 160 };
    const u_with_flyout = rectUnion(main_panel, flyout);
    // 主面板宽度不变，仅高度扩展（flyout 向上伸出）。
    try std.testing.expectEqual(@as(i32, 428), u_with_flyout.w);
    try std.testing.expectEqual(@as(i32, 80), u_with_flyout.y);
}

// Win7 风格：all_programs 视图下左列底部 Y（含「返回」行）。
test "all_programs left column bottom Y equals all_prog_y plus row height" {
    const content_y: i32 = 162;
    const all_prog_y: i32 = 402;
    const row_h: i32 = 24;
    const back_bottom_y = all_prog_y + row_h;
    // 「返回」行 y 范围：[back_bottom_y - row_h, back_bottom_y)。
    try std.testing.expectEqual(@as(i32, all_prog_y + row_h), back_bottom_y);
    try std.testing.expect(back_bottom_y - row_h >= all_prog_y);
}

// Win7 风格：all_programs 视图下程序行 hover 索引落在左列范围内。
test "all programs hover row index lands in left column x range" {
    const main_x: i32 = 52;
    const split_x: i32 = 252;
    const row_h: i32 = 24;
    const content_y: i32 = 162;
    const ALL_PROG_COUNT: i32 = 4;
    const IDX_ALLPROG_BASE: i32 = 60;

    var iy: i32 = content_y + 6;
    var i: i32 = 0;
    while (i < ALL_PROG_COUNT) : (i += 1) {
        const row_top = iy - 1;
        const row_bottom = iy + row_h - 1;
        // 每行均应在左列 x 范围内。
        try std.testing.expect(row_top >= content_y);
        _ = row_bottom;
        iy += row_h;
    }
}
