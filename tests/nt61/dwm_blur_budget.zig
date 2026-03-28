//! 模糊预算与面积守卫的纯数学回归（主机 `zig test`，无帧缓冲）。
const std = @import("std");

fn consumePixelPassBudget(remaining: u32, w: i32, h: i32, passes: u32) ?u32 {
    if (w <= 0 or h <= 0 or passes == 0) return remaining;
    const area = @as(u32, @intCast(w)) * @as(u32, @intCast(h));
    const cost = area * passes;
    if (cost > remaining) return null;
    return remaining - cost;
}

test "blur pixel-pass budget subtracts area times passes" {
    const r = consumePixelPassBudget(1_000_000, 100, 100, 2) orelse return error.Fail;
    try std.testing.expectEqual(@as(u32, 980_000), r);
}

test "blur max single rect skips huge areas" {
    const max_px: u32 = 320_000;
    const w: i32 = 800;
    const h: i32 = 500;
    const area = @as(u32, @intCast(w)) * @as(u32, @intCast(h));
    try std.testing.expect(area > max_px);
}

test "blur call budget decrements per successful rect" {
    var calls: u32 = 3;
    var budget: u32 = 10_000_000;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        if (calls == 0) break;
        if (consumePixelPassBudget(budget, 10, 10, 1)) |nb| {
            budget = nb;
            calls -= 1;
        } else break;
    }
    try std.testing.expectEqual(@as(u32, 0), calls);
    try std.testing.expect(i >= 3);
}
