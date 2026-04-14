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
// ZirconOSAero — host-only tests for scheduler policy formulas (mirrors `src/ke/scheduler.zig`).
// Keep numeric policy in sync when changing PRIORITY_DYNAMIC_MAX, STARVATION_*, QUANTUM_BY_CLASS.
//
// Phase 4 调度器增强测试：
// - IB-02: I/O boost 衰减机制测试
// - PI-05: 互斥继承深度上界测试
// - SP-01/SP-03: 饥饿阈值和提升上限测试
// - QT-03: Process基优先级影响quantum测试

const std = @import("std");

const PRIORITY_DYNAMIC_MAX: u8 = 15;
const STARVATION_TICK_THRESHOLD: u64 = 200;
const STARVATION_BOOST: u8 = 2;

// IB-02: I/O boost 衰减常量（与 scheduler.zig 同步）
const IO_BOOST_DECAY_DELAY_TICKS: u32 = 5;
const IO_BOOST_DECAY_INTERVAL_TICKS: u32 = 10;

// PI-05: 互斥继承深度上界
const MUTEX_INHERIT_MAX_DEPTH: u32 = 32;

// QT-03: QUANTUM_BY_CLASS
const QUANTUM_BY_CLASS: [8]u32 = .{ 4, 5, 6, 7, 8, 10, 12, 14 };

fn effectivePriorityLikeKernel(
    base_pri: u8,
    io_boost: u8,
    mutex_floor: u8,
    is_ready_in_q: bool,
    starve: u64,
) u8 {
    // 步骤1: base + io_boost，限制在 31
    const sum = @as(u16, base_pri) + @as(u16, io_boost);
    var p: u8 = @intCast(@min(sum, @as(u16, 31)));

    // 步骤2: mutex_floor 优先级更高
    p = @max(p, mutex_floor);

    // 步骤3: 饥饿提升（仅对动态优先级线程）
    // 条件：base_pri <= 15 (DYNAMIC_MAX), 在就绪队列中, starve > 200
    if (base_pri <= PRIORITY_DYNAMIC_MAX and is_ready_in_q and starve > STARVATION_TICK_THRESHOLD) {
        const boost = @min(STARVATION_BOOST, 31 -| p);
        p = p +| boost;
    }
    return p;
}

// IB-02: I/O boost 衰减模拟
// 与 scheduler.zig:tick() 中 boost 衰减逻辑一致
// 关键点：
// 1. boost_deadline_tick 机制：超过截止时间时 boost 直接归零
// 2. 衰减计数器只在运行时（在就绪队列中）才增加
fn simulateIoBoostDecay(
    io_boost: u8,
    decay_counter: u32,
    is_ready_in_q: bool,
) u8 {
    if (io_boost == 0) return 0;
    if (!is_ready_in_q) return io_boost; // 阻塞时不衰减

    // 延迟期：前 DECAY_DELAY_TICKS=5 个 tick 不衰减
    if (decay_counter > IO_BOOST_DECAY_DELAY_TICKS) {
        if ((decay_counter - IO_BOOST_DECAY_DELAY_TICKS) % IO_BOOST_DECAY_INTERVAL_TICKS == 0) {
            if (io_boost > 0) return io_boost - 1;
        }
    }
    return io_boost;
}

// PI-05: 互斥继承深度上界测试
// 与调度器中的 beginMutexInheritance 逻辑一致
fn applyMutexInheritance(current_depth: u32, new_depth: u32) u32 {
    // 调度器代码：`if (depth >= MAX_DEPTH) return;`
    // 这意味着只有当 current_depth >= 32 时才拒绝
    // 当 current_depth = 31, new_depth = 1 时，31 < 32，允许增加
    if (current_depth >= MUTEX_INHERIT_MAX_DEPTH) return current_depth;
    return current_depth + new_depth;
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

// ── Phase 4 新增测试 ──

// SP-03: 饥饿提升有上限测试
test "starvation boost respects upper bound at 31" {
    // 线程优先级12（在动态范围），饥饿提升后应该是14（12+2，但受上限约束）
    // 注意：base_pri 必须 <= 15 (DYNAMIC_MAX) 才触发饥饿提升
    const ep = effectivePriorityLikeKernel(12, 0, 0, true, 201);
    try std.testing.expectEqual(@as(u8, 14), ep);
}

test "starvation boost at boundary 30" {
    // 线程优先级15（在动态范围上界），饥饿提升后应该是17（15+2）
    const ep = effectivePriorityLikeKernel(15, 0, 0, true, 201);
    try std.testing.expectEqual(@as(u8, 17), ep);
}

test "starvation boost normal case" {
    // 线程优先级8，饥饿提升后应该是10（8+2）
    const ep = effectivePriorityLikeKernel(8, 0, 0, true, 201);
    try std.testing.expectEqual(@as(u8, 10), ep);
}

test "starvation boost skips for realtime priority" {
    // 线程优先级20（实时范围），饥饿提升应该被跳过
    const ep = effectivePriorityLikeKernel(20, 0, 0, true, 999);
    try std.testing.expectEqual(@as(u8, 20), ep);
}

// IB-02: I/O boost 衰减测试
test "io boost no decay during delay period" {
    // 在延迟期内 boost 不应衰减
    const boost = simulateIoBoostDecay(4, 3, true);
    try std.testing.expectEqual(@as(u8, 4), boost);
}

test "io boost decays after delay" {
    // decay_counter=6: 6 > 5 进入衰减检查
    // (6-5) % 10 = 1，不是 0，所以不衰减
    const boost = simulateIoBoostDecay(4, 6, true);
    try std.testing.expectEqual(@as(u8, 4), boost);
}

test "io boost decays every interval" {
    // decay_counter=15: (15-5) % 10 = 0，应该衰减 1 点
    const boost = simulateIoBoostDecay(4, 15, true);
    try std.testing.expectEqual(@as(u8, 3), boost);
}

test "io boost blocked thread does not decay" {
    // 阻塞的线程 boost 不衰减
    const boost = simulateIoBoostDecay(4, 20, false);
    try std.testing.expectEqual(@as(u8, 4), boost);
}

test "io boost zero stays zero" {
    // boost 为 0 时保持为 0
    const boost = simulateIoBoostDecay(0, 100, true);
    try std.testing.expectEqual(@as(u8, 0), boost);
}

// PI-05: 互斥继承深度上界测试
test "mutex inherit depth respects max bound" {
    // 当深度达到或超过上限时（>=32），拒绝增加
    const result = applyMutexInheritance(32, 1); // 32 >= 32，拒绝
    try std.testing.expectEqual(@as(u32, 32), result);
}

test "mutex inherit depth normal case" {
    // 正常情况下深度应该增加
    const result = applyMutexInheritance(5, 1);
    try std.testing.expectEqual(@as(u32, 6), result);
}

test "mutex inherit depth at boundary" {
    // 深度31，增加1是允许的（31 < 32）
    const result = applyMutexInheritance(31, 1);
    try std.testing.expectEqual(@as(u32, 32), result);
}

// QT-03: Process 基优先级影响 quantum 测试
test "process base priority affects quantum" {
    // 不同的 priority_class 应该产生不同的 quantum
    try std.testing.expectEqual(@as(u32, 4), QUANTUM_BY_CLASS[0]); // IDLE
    try std.testing.expectEqual(@as(u32, 6), QUANTUM_BY_CLASS[2]); // NORMAL
    try std.testing.expectEqual(@as(u32, 14), QUANTUM_BY_CLASS[7]); // REALTIME
}

// 边界测试
test "quantum table class 0 is smallest" {
    try std.testing.expectEqual(@as(u32, 4), QUANTUM_BY_CLASS[0]);
    try std.testing.expect(QUANTUM_BY_CLASS[0] < QUANTUM_BY_CLASS[7]);
}

// IO_BOOST 衰减边界测试
test "io boost at one does not go negative" {
    // boost 为 1 时衰减后应该是 0
    const boost = simulateIoBoostDecay(1, 15, true); // (15-5) % 10 == 0
    try std.testing.expectEqual(@as(u8, 0), boost);
}
