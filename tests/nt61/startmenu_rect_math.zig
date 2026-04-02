//! 开始菜单扩展脏区：轴对齐矩形并集（主机 `zig test`，无内核依赖）。
//! 与 `renderer_aero.redrawStartMenuRegionOnly` / `startmenu.getHoverHighlightRepaintBounds` 数学一致；**不依赖**嵌入壁纸预设索引。
const std = @import("std");

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

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

test "rect union includes All Programs side panel to the right" {
    const base = Rect{ .x = 0, .y = 100, .w = 428, .h = 400 };
    // 侧栏与主列同高（含合并后的单行底栏）；数值为几何 smoke，非内核内联常量。
    const side = Rect{ .x = 428, .y = 154, .w = 196, .h = 354 };
    const u = rectUnion(base, side);
    try std.testing.expectEqual(@as(i32, 0), u.x);
    try std.testing.expectEqual(@as(i32, 100), u.y);
    try std.testing.expectEqual(@as(i32, 624), u.w);
    try std.testing.expectEqual(@as(i32, 408), u.h);
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
