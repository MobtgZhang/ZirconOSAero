//! Round-Robin Scheduler
//! Manages kernel threads with cooperative/timer-driven context switching

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
    threads[idx].priority = 0;

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
    threads[idx].priority = 1;

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

    var next = (current_thread + 1) % thread_count;
    var checked: usize = 0;
    while (checked < thread_count) : (checked += 1) {
        if (threads[next].state == .ready or threads[next].state == .running) {
            break;
        }
        next = (next + 1) % thread_count;
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

pub fn isInitialized() bool {
    return initialized;
}
