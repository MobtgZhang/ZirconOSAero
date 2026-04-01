// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/scheduler.zig
// Purpose: 定时器驱动的多级优先级就绪调度（抢占式）；API 说明见 docs/cn/SCHEDULER_API.md
//
// This is an independent clean-room implementation.
// Reference: OS textbook priority scheduling; MS Learn — threading (behavioral only).

const builtin = @import("builtin");
const klog = @import("../rtl/klog.zig");
const vm_mod = @import("../mm/vm.zig");
const process_mod = @import("../ps/process.zig");
const spinlock_mod = @import("spinlock.zig");
const percpu_sched = @import("percpu_sched.zig");

var sched_irq_lock: spinlock_mod.IrqSpinLock = .{};

fn activateCr3ForProcessId(pid: u32) void {
    if (builtin.cpu.arch != .x86_64) return;
    if (pid == 0) {
        if (vm_mod.kernelAddressSpace()) |ks| {
            ks.activate();
        }
        return;
    }
    if (process_mod.findProcess(pid)) |pp| {
        if (pp.address_space) |asp| {
            var a = asp;
            a.activate();
            return;
        }
    }
    if (vm_mod.kernelAddressSpace()) |ks| {
        ks.activate();
    }
}

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
/// 就绪链分桶上界（与 `madt.logical_cpu_count` 取 min）；AP 未进调度前仅 BSP 桶活跃。
const MAX_SCHED_CPUS: usize = 8;

var ready_head: [MAX_SCHED_CPUS]i32 = @splat(-1);
var ready_tail: [MAX_SCHED_CPUS]i32 = @splat(-1);

fn schedNumCpus() usize {
    if (builtin.cpu.arch == .x86_64) {
        const madt = @import("../hal/x86_64/madt.zig");
        const n: u32 = madt.logical_cpu_count;
        return @max(@as(usize, 1), @min(@as(usize, @intCast(n)), MAX_SCHED_CPUS));
    }
    return 1;
}

fn homeCpuSchedSlot(home: u32) usize {
    const n = schedNumCpus();
    return @intCast(home % n);
}

fn resetReadyQueues() void {
    for (&ready_head) |*h| h.* = -1;
    for (&ready_tail) |*t| t.* = -1;
}

fn enqueueReady(tid: usize) void {
    if (tid >= thread_count) return;
    if (threads[tid].in_ready_queue) return;
    const cpu = homeCpuSchedSlot(threads[tid].home_cpu);
    threads[tid].next_ready = -1;
    threads[tid].in_ready_queue = true;
    const th: i32 = @intCast(tid);
    const tail = ready_tail[cpu];
    if (tail < 0) {
        ready_head[cpu] = th;
        ready_tail[cpu] = th;
    } else {
        threads[@intCast(tail)].next_ready = th;
        ready_tail[cpu] = th;
    }
}

fn removeFromReadyQueue(tid: usize) void {
    if (tid >= thread_count or !threads[tid].in_ready_queue) return;
    threads[tid].in_ready_queue = false;
    const n = schedNumCpus();
    var c: usize = 0;
    while (c < n) : (c += 1) {
        var prev: i32 = -1;
        var cur_tid = ready_head[c];
        while (cur_tid >= 0) {
            const ct: usize = @intCast(cur_tid);
            const next = threads[ct].next_ready;
            if (ct == tid) {
                if (prev < 0) {
                    ready_head[c] = next;
                } else {
                    threads[@intCast(prev)].next_ready = next;
                }
                if (ready_tail[c] == cur_tid) {
                    ready_tail[c] = prev;
                }
                threads[ct].next_ready = -1;
                return;
            }
            prev = cur_tid;
            cur_tid = next;
        }
    }
    threads[tid].next_ready = -1;
}

fn popHeadQueue(cpu: usize) ?usize {
    const h = ready_head[cpu];
    if (h < 0) return null;
    const tid: usize = @intCast(h);
    const next = threads[tid].next_ready;
    ready_head[cpu] = next;
    if (next < 0) ready_tail[cpu] = -1;
    threads[tid].next_ready = -1;
    threads[tid].in_ready_queue = false;
    return tid;
}

fn isBspIdleThreadForSteal() bool {
    return current_thread < thread_count and
        threads[current_thread].id == 0 and
        threads[current_thread].priority == PRIORITY_IDLE;
}

fn workStealBalanceIfIdleImpl() void {
    const n = schedNumCpus();
    if (n <= 1) return;
    if (!isBspIdleThreadForSteal()) return;
    const here: usize = 0;
    if (ready_head[here] >= 0) return;
    var best_c: usize = 0;
    var best_len: usize = 0;
    var c: usize = 0;
    while (c < n) : (c += 1) {
        if (c == here) continue;
        var len: usize = 0;
        var t = ready_head[c];
        while (t >= 0) {
            len += 1;
            t = threads[@intCast(t)].next_ready;
        }
        if (len > best_len) {
            best_len = len;
            best_c = c;
        }
    }
    if (best_len == 0) return;
    const stolen = popHeadQueue(best_c) orelse return;
    threads[stolen].home_cpu = @intCast(here);
    enqueueReady(stolen);
}

fn isSchedulable(idx: usize) bool {
    if (idx >= thread_count) return false;
    const t = &threads[idx];
    if (t.state == .running) return true;
    return t.state == .ready and t.in_ready_queue;
}

/// NT 6.1 风格 **0–31** 数值档（越大越优先）；idle 取低端，交互/实时取高端。
pub const PRIORITY_IDLE: u8 = 1;
pub const PRIORITY_NORMAL: u8 = 8;
pub const PRIORITY_REALTIME: u8 = 24;

/// 仍支持 0..7 **class** 到基线优先级的映射（见 `priorityFromClass`）。
pub const PRIORITY_CLASS_COUNT: usize = 8;

/// 同等最高优先级线程间：连续占用的定时器 tick 数（`1` = 每 tick 可切换，兼容既有行为）。
pub const TIME_SLICE_TICKS: u32 = 1;

/// 从 `blocked` 唤醒时叠加到 `priority` 上的临时增量（clean-room 近似 I/O 完成提升）。
pub const IO_BOOST_PRIORITY_DELTA: u8 = 2;

/// I/O 提升持续的 tick 数（PIT ~100Hz 时约 `N * 10ms` 量级）。
pub const IO_BOOST_DURATION_TICKS: u64 = 20;

/// 就绪过久临时抬升阈值（tick）；减轻纯优先级饿死（非 Windows 精确算法）。
pub const STARVATION_TICK_THRESHOLD: u64 = 200;
pub const STARVATION_BOOST: u8 = 2;

/// `class` 0..7 → 0..31 内的基线优先级。
pub fn priorityFromClass(class: u8) u8 {
    const c: u32 = @min(@as(u32, class), PRIORITY_CLASS_COUNT - 1);
    const p: u32 = 2 + c * 3;
    return @truncate(@min(p, 31));
}

pub const Thread = struct {
    id: usize = 0,
    process_id: u32 = 0,
    /// 目标运行 CPU（SMP 演进：`assignCpuForNewThread`）。
    home_cpu: u32 = 0,
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
    /// 每 CPU 就绪链（`home_cpu` 分桶）；`running` / `blocked` 不在链上。
    next_ready: i32 = -1,
    in_ready_queue: bool = false,
    name: [16]u8 = [_]u8{0} ** 16,
};

fn effectivePriority(t: *const Thread) u8 {
    const sum = @as(u16, t.priority) + @as(u16, t.io_boost);
    const capped: u16 = @min(sum, 31);
    var p: u8 = @intCast(capped);
    if (t.state == .ready and t.in_ready_queue and starve_ticks[t.id] > STARVATION_TICK_THRESHOLD) {
        p = @min(31, p +| STARVATION_BOOST);
    }
    return p;
}

var threads: [MAX_THREADS]Thread = undefined;
var thread_count: usize = 0;
var current_thread: usize = 0;
var tick_count: u64 = 0;
var initialized: bool = false;
var scheduling_enabled: bool = false;

var starve_ticks: [MAX_THREADS]u64 = @splat(0);

pub fn init() void {
    resetReadyQueues();
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
    threads[idx].home_cpu = percpu_sched.assignCpuForNewThread();
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
    threads[idx].home_cpu = percpu_sched.assignCpuForNewThread();
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
    enqueueReady(idx);

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
    sched_irq_lock.lock();
    defer sched_irq_lock.unlock();

    tick_count += 1;
    workStealBalanceIfIdleImpl();

    if (!scheduling_enabled or thread_count <= 1) return;

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        if (tick_count >= threads[i].boost_deadline_tick) {
            threads[i].io_boost = 0;
        }
    }

    const cur = current_thread;
    i = 0;
    while (i < thread_count) : (i += 1) {
        if (threads[i].state == .ready and threads[i].in_ready_queue and i != cur) {
            starve_ticks[i] += 1;
        } else if (threads[i].state != .ready) {
            starve_ticks[i] = 0;
        }
    }
    if (cur < thread_count) starve_ticks[cur] = 0;
    if (threads[cur].state == .running and threads[cur].slice_remaining > 0) {
        threads[cur].slice_remaining -= 1;
    }

    var max_pri: u8 = 0;
    i = 0;
    while (i < thread_count) : (i += 1) {
        if (!isSchedulable(i)) continue;
        const ep = effectivePriority(&threads[i]);
        if (ep > max_pri) max_pri = ep;
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
            if (!isSchedulable(i)) continue;
            if (effectivePriority(&threads[i]) == max_pri) {
                next = i;
                break;
            }
        }
    } else {
        var off: usize = 1;
        while (off <= thread_count) : (off += 1) {
            const idx = (cur + off) % thread_count;
            if (!isSchedulable(idx)) continue;
            if (effectivePriority(&threads[idx]) == max_pri) {
                next = idx;
                break;
            }
        }
    }

    if (next != cur and threads[next].state != .terminated) {
        removeFromReadyQueue(next);
        if (threads[cur].state == .running) {
            threads[cur].state = .ready;
            threads[cur].slice_remaining = TIME_SLICE_TICKS;
            enqueueReady(cur);
        }
        threads[next].state = .running;
        threads[next].slice_remaining = TIME_SLICE_TICKS;
        current_thread = next;
        activateCr3ForProcessId(threads[next].process_id);
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
        removeFromReadyQueue(tid);
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
        enqueueReady(tid);
    }
}

pub fn terminateThread(tid: usize) void {
    if (tid < thread_count) {
        removeFromReadyQueue(tid);
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
