// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/scheduler.zig
// Purpose: 定时器驱动的多级优先级就绪调度（抢占式）；API 说明见 docs/cn/SCHEDULER_API.md
//
// This is an independent clean-room implementation.
// Reference: OS textbook priority scheduling; MS Learn — threading (behavioral only).

const klog = @import("../rtl/klog.zig");

pub const ThreadState = enum {
    ready,
    running,
    blocked,
    terminated,
};

pub const ThreadContext = struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    rbx: u64 = 0,
    rbp: u64 = 0,
    rip: u64 = 0,
};

const MAX_THREADS: usize = 32;
const STACK_SIZE: usize = 8192;

/// 与路线图 Task 7 对齐的三档命名优先级（数值越大越优先）。
pub const PRIORITY_IDLE: u8 = 4;
pub const PRIORITY_NORMAL: u8 = 8;
pub const PRIORITY_REALTIME: u8 = 16;

/// 文档化八档阶梯（映射建议见 `docs/cn/SCHEDULER_API.md`）；非 NT 32 级。
pub const PRIORITY_CLASS_COUNT: usize = 8;

/// 同等最高优先级线程间：连续占用的定时器 tick 数（`1` = 每 tick 可切换，兼容既有行为）。
pub const TIME_SLICE_TICKS: u32 = 1;

/// 从 `blocked` 唤醒时叠加到 `priority` 上的临时增量（clean-room 近似 I/O 完成提升，非 NT 精确语义）。
pub const IO_BOOST_PRIORITY_DELTA: u8 = 2;

/// I/O 提升持续的 tick 数（PIT ~100Hz 时约 `N * 10ms` 量级）。
pub const IO_BOOST_DURATION_TICKS: u64 = 20;

/// `class` 0..7 → 单调升高的优先级值（裁剪到 u8）。
pub fn priorityFromClass(class: u8) u8 {
    const c: u32 = @min(@as(u32, class), PRIORITY_CLASS_COUNT - 1);
    const p: u32 = 4 + c * 2;
    return @truncate(p);
}

pub const Thread = struct {
    id: usize = 0,
    process_id: u32 = 0,
    state: ThreadState = .ready,
    context: ThreadContext = .{},
    stack: [STACK_SIZE]u8 align(16) = undefined,
    stack_top: usize = 0,
    /// 基线优先级（`setThreadPriority` / 创建线程时设置）。
    priority: u8 = 0,
    /// 唤醒提升增量，在 `boost_deadline_tick` 之前参与调度。
    io_boost: u8 = 0,
    boost_deadline_tick: u64 = 0,
    /// 当前运行周期剩余时间片（仅 `running` 时递减）。
    slice_remaining: u32 = TIME_SLICE_TICKS,
    name: [16]u8 = [_]u8{0} ** 16,
};

fn effectivePriority(t: *const Thread) u8 {
    const sum = @as(u16, t.priority) + @as(u16, t.io_boost);
    return @truncate(@min(sum, @as(u16, 255)));
}

var threads: [MAX_THREADS]Thread = undefined;
var thread_count: usize = 0;
var current_thread: usize = 0;
var tick_count: u64 = 0;
var initialized: bool = false;
var scheduling_enabled: bool = false;

pub fn init() void {
    thread_count = 0;
    current_thread = 0;
    tick_count = 0;
    initialized = true;
    scheduling_enabled = false;

    _ = createIdleThread();
}

fn createIdleThread() ?usize {
    if (thread_count >= MAX_THREADS) return null;

    const idx = thread_count;
    threads[idx] = .{};
    threads[idx].id = idx;
    threads[idx].state = .running;
    threads[idx].priority = PRIORITY_IDLE;
    threads[idx].io_boost = 0;
    threads[idx].boost_deadline_tick = 0;
    threads[idx].slice_remaining = TIME_SLICE_TICKS;

    const idle_name = "idle";
    @memcpy(threads[idx].name[0..idle_name.len], idle_name);

    thread_count += 1;
    current_thread = idx;

    klog.info("Scheduler: idle thread (tid=%u) created", .{idx});
    return idx;
}

pub fn createThread(entry: u64, process_id: u32) ?usize {
    if (!initialized or thread_count >= MAX_THREADS) return null;

    const idx = thread_count;
    threads[idx] = .{};
    threads[idx].id = idx;
    threads[idx].process_id = process_id;
    threads[idx].state = .ready;
    threads[idx].priority = PRIORITY_NORMAL;
    threads[idx].io_boost = 0;
    threads[idx].boost_deadline_tick = 0;
    threads[idx].slice_remaining = TIME_SLICE_TICKS;

    const stack_base = @intFromPtr(&threads[idx].stack);
    const stack_end = stack_base + STACK_SIZE;
    var sp = stack_end;

    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = entry;
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;

    threads[idx].stack_top = sp;
    threads[idx].context.rip = entry;

    thread_count += 1;

    klog.debug("Scheduler: thread %u created (entry=0x%x, pid=%u)", .{
        idx, entry, process_id,
    });
    return idx;
}

pub fn enableScheduling() void {
    scheduling_enabled = true;
    klog.info("Scheduler: preemptive scheduling enabled", .{});
}

pub fn tick() void {
    tick_count += 1;

    if (!scheduling_enabled or thread_count <= 1) return;

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        if (tick_count >= threads[i].boost_deadline_tick) {
            threads[i].io_boost = 0;
        }
    }

    const cur = current_thread;
    if (threads[cur].state == .running and threads[cur].slice_remaining > 0) {
        threads[cur].slice_remaining -= 1;
    }

    var max_pri: u8 = 0;
    i = 0;
    while (i < thread_count) : (i += 1) {
        const t = &threads[i];
        if (t.state == .ready or t.state == .running) {
            const ep = effectivePriority(t);
            if (ep > max_pri) max_pri = ep;
        }
    }

    const cur_ep = effectivePriority(&threads[cur]);
    const higher = max_pri > cur_ep;
    const slice_done = threads[cur].slice_remaining == 0;
    const rr = !higher and slice_done and max_pri == cur_ep;

    if (!higher and !rr) return;

    var next: usize = cur;
    if (higher) {
        i = 0;
        while (i < thread_count) : (i += 1) {
            const t = &threads[i];
            if ((t.state == .ready or t.state == .running) and effectivePriority(t) == max_pri) {
                next = i;
                break;
            }
        }
    } else {
        var off: usize = 1;
        while (off <= thread_count) : (off += 1) {
            const idx = (cur + off) % thread_count;
            const t = &threads[idx];
            if ((t.state == .ready or t.state == .running) and effectivePriority(t) == max_pri) {
                next = idx;
                break;
            }
        }
    }

    if (next != cur and threads[next].state != .terminated) {
        if (threads[cur].state == .running) {
            threads[cur].state = .ready;
            threads[cur].slice_remaining = TIME_SLICE_TICKS;
        }
        threads[next].state = .running;
        threads[next].slice_remaining = TIME_SLICE_TICKS;
        current_thread = next;
    }
}

pub fn yield() void {
    tick();
}

pub fn getCurrentThread() ?*Thread {
    if (!initialized or thread_count == 0) return null;
    return &threads[current_thread];
}

pub fn getCurrentThreadId() usize {
    return current_thread;
}

pub fn blockThread(tid: usize) void {
    if (tid < thread_count) {
        threads[tid].state = .blocked;
    }
}

pub fn unblockThread(tid: usize) void {
    if (tid < thread_count and threads[tid].state == .blocked) {
        threads[tid].state = .ready;
        const cap = @as(u16, 255) - @as(u16, threads[tid].priority);
        const nb = @as(u16, threads[tid].io_boost) + @as(u16, IO_BOOST_PRIORITY_DELTA);
        threads[tid].io_boost = @truncate(@min(nb, cap));
        threads[tid].boost_deadline_tick = tick_count + IO_BOOST_DURATION_TICKS;
    }
}

pub fn terminateThread(tid: usize) void {
    if (tid < thread_count) {
        threads[tid].state = .terminated;
        klog.debug("Scheduler: thread %u terminated", .{tid});
    }
}

pub fn getTicks() u64 {
    return tick_count;
}

pub fn getThreadCount() usize {
    return thread_count;
}

pub fn setThreadPriority(tid: usize, priority: u8) void {
    if (tid >= thread_count) return;
    threads[tid].priority = priority;
}

pub fn isInitialized() bool {
    return initialized;
}
