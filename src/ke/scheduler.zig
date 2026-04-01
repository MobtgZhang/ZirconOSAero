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
    priority: u8 = 0,
    name: [16]u8 = [_]u8{0} ** 16,
};

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

    var max_pri: u8 = 0;
    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        const t = &threads[i];
        if (t.state == .ready or t.state == .running) {
            if (t.priority > max_pri) max_pri = t.priority;
        }
    }

    var next: usize = current_thread;
    var off: usize = 1;
    while (off <= thread_count) : (off += 1) {
        const idx = (current_thread + off) % thread_count;
        const t = &threads[idx];
        if ((t.state == .ready or t.state == .running) and t.priority == max_pri) {
            next = idx;
            break;
        }
    }

    if (next != current_thread and threads[next].state != .terminated) {
        threads[current_thread].state = .ready;
        threads[next].state = .running;
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
