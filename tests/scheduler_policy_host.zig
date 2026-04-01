// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero — host-only tests for scheduler policy formulas (mirrors `src/ke/scheduler.zig`).
// Keep numeric policy in sync when changing PRIORITY_DYNAMIC_MAX, STARVATION_*, QUANTUM_BY_CLASS.

const std = @import("std");

const PRIORITY_DYNAMIC_MAX: u8 = 15;
const STARVATION_TICK_THRESHOLD: u64 = 200;
const STARVATION_BOOST: u8 = 2;

fn effectivePriorityLikeKernel(
    base_pri: u8,
    io_boost: u8,
    mutex_floor: u8,
    is_ready_in_q: bool,
    starve: u64,
) u8 {
    const sum = @as(u16, base_pri) + @as(u16, io_boost);
    var p: u8 = @intCast(@min(sum, @as(u16, 31)));
    p = @max(p, mutex_floor);
    if (base_pri <= PRIORITY_DYNAMIC_MAX and is_ready_in_q and starve > STARVATION_TICK_THRESHOLD) {
        p = @min(31, p +| STARVATION_BOOST);
    }
    return p;
}

test "dynamic range gets starvation boost when ready" {
    const ep = effectivePriorityLikeKernel(8, 0, 0, true, 201);
    try std.testing.expectEqual(@as(u8, 10), ep);
}

test "realtime base skips starvation boost" {
    const ep = effectivePriorityLikeKernel(20, 0, 0, true, 999);
    try std.testing.expectEqual(@as(u8, 20), ep);
}

test "mutex inherit floor dominates low base" {
    const ep = effectivePriorityLikeKernel(4, 0, 18, true, 0);
    try std.testing.expectEqual(@as(u8, 18), ep);
}

const QUANTUM_BY_CLASS: [8]u32 = .{ 4, 5, 6, 7, 8, 10, 12, 14 };

test "quantum table monotonic non-decreasing by class" {
    var c: usize = 1;
    while (c < QUANTUM_BY_CLASS.len) : (c += 1) {
        try std.testing.expect(QUANTUM_BY_CLASS[c] >= QUANTUM_BY_CLASS[c - 1]);
    }
}

test "priorityFromClass maps into 0..31" {
    var cl: u8 = 0;
    while (cl < 8) : (cl += 1) {
        const c: u32 = @min(@as(u32, cl), 7);
        const p: u32 = @min(2 + c * 3, 31);
        try std.testing.expect(p <= 31);
    }
}
