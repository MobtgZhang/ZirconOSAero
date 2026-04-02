// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/config/dwm_blur_budget.zig
// Purpose: Box-blur pixel·pass cost model shared by `dwm.zig` and host tests (problem 3 / content2.4).
//
// This is an independent clean-room implementation.

const std = @import("std");

/// Saturating cost `width * height * passes` in u32 (matches `dwm.tryConsumeBlurBudget` clamp).
pub fn blurRectCostSaturating(w: i32, h: i32, passes: u32) u32 {
    if (w <= 0 or h <= 0 or passes == 0) return 0;
    const area64 = @as(u64, @intCast(w)) *% @as(u64, @intCast(h));
    const cost64 = area64 *% @as(u64, passes);
    return if (cost64 > std.math.maxInt(u32))
        std.math.maxInt(u32)
    else
        @intCast(cost64);
}

/// Returns true if `cost` was subtracted from `*remaining`; false if insufficient budget (unchanged).
pub fn trySubtractFromBudget(remaining: *u32, w: i32, h: i32, passes: u32) bool {
    const cost = blurRectCostSaturating(w, h, passes);
    if (cost == 0) return true;
    if (cost > remaining.*) return false;
    remaining.* -= cost;
    return true;
}

test "blur cost 10x10x3" {
    try std.testing.expectEqual(@as(u32, 300), blurRectCostSaturating(10, 10, 3));
}

test "blur cost clamps to max u32 on overflow" {
    const huge: i32 = 0x10000;
    const c = blurRectCostSaturating(huge, huge, 0xFFFF);
    try std.testing.expectEqual(std.math.maxInt(u32), c);
}

test "trySubtractFromBudget denies when over budget" {
    var b: u32 = 100;
    try std.testing.expect(!trySubtractFromBudget(&b, 10, 10, 2)); // 200 > 100
    try std.testing.expectEqual(@as(u32, 100), b);
}

test "trySubtractFromBudget succeeds and deducts" {
    var b: u32 = 500;
    try std.testing.expect(trySubtractFromBudget(&b, 10, 10, 2)); // 200
    try std.testing.expectEqual(@as(u32, 300), b);
}

test "blurRectCostSaturating zero width height or passes yields zero" {
    try std.testing.expectEqual(@as(u32, 0), blurRectCostSaturating(0, 10, 3));
    try std.testing.expectEqual(@as(u32, 0), blurRectCostSaturating(10, 0, 3));
    try std.testing.expectEqual(@as(u32, 0), blurRectCostSaturating(-1, 10, 3));
    try std.testing.expectEqual(@as(u32, 0), blurRectCostSaturating(10, 10, 0));
}

test "trySubtractFromBudget passes zero is no-op success" {
    var b: u32 = 5;
    try std.testing.expect(trySubtractFromBudget(&b, 100, 100, 0));
    try std.testing.expectEqual(@as(u32, 5), b);
}
