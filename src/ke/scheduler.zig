// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/scheduler.zig
// Purpose: 定时器驱动的每 CPU 32 级优先级分桶就绪队列 + 时间片（按优先级类）+ 动态/实时分野 + 互斥体继承钩子。
// API 说明见 docs/cn/SCHEDULER_API.md。
//
// This is an independent clean-room implementation.
// Reference: MS Learn — scheduling (conceptual); OS textbook MLQ; Intel SDM for syscall path elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const peb_stub_va = @import("../sdk/peb_nt61_x64.zig");
const klog = @import("../rtl/klog.zig");
const vm_mod = @import("../mm/vm.zig");
const process_mod = @import("../ps/process.zig");
const spinlock_mod = @import("spinlock.zig");
const percpu_sched = @import("percpu_sched.zig");
const kpcr = @import("kpcr.zig");
const ob = @import("../ob/object.zig");
const KeApc = @import("apc_object.zig").KeApc;

/// `tick` / `enqueueReady` 等在定时器 IRQ 路径持锁；`IrqSpinLock` 在 `unlock` 时恢复**加锁前** IF，不在 ISR 内误 `sti`。
var sched_irq_lock: spinlock_mod.IrqSpinLock = .{};

/// 前台会话进程时间片加成（tick；clean-room 常数，可调）。
const foreground_quantum_bonus_ticks: u32 = 4;

fn activateCr3ForProcessId(pid: u32) void {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .loongarch64 and builtin.cpu.arch != .riscv64 and builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .mips64el) return;
    if (pid == 0) {
        if (vm_mod.kernelAddressSpace()) |ks| {
            ks.activate();
        }
        return;
    }
    if (process_mod.findProcess(pid)) |pp| {
        if (pp.address_space) |asp| {
            asp.activate();
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

/// 线程槽上限；`-Dmax_scheduler_threads=` 覆盖（8..256，默认见 `build.zig`）。
const MAX_THREADS: usize = blk: {
    const v = build_options.max_scheduler_threads;
    break :blk @max(8, @min(256, @as(usize, v)));
};
const STACK_SIZE: usize = 8192;
/// 就绪队列 **CPU 槽** 上限；`schedNumCpus()` 将 MADT `logical_cpu_count` 截断到 `[1..@min(n, MAX_SCHED_CPUS)]`。
const MAX_SCHED_CPUS: usize = 8;
const NUM_PRI: usize = 32;

var ready_head: [MAX_SCHED_CPUS][NUM_PRI]i32 = @splat(@splat(-1));
var ready_tail: [MAX_SCHED_CPUS][NUM_PRI]i32 = @splat(@splat(-1));
/// Bit `p` set if bucket `(cpu, p)` 非空。
var non_empty: [MAX_SCHED_CPUS]u32 = @splat(0);
/// 同优先级跨 CPU 取头的轮询起点（近似全局 FIFO）。
var rr_cpu_cursor: [NUM_PRI]u8 = @splat(0);

fn schedNumCpus() usize {
    if (builtin.cpu.arch == .x86_64) {
        const madt = @import("../hal/x86_64/madt.zig");
        const n: u32 = madt.logical_cpu_count;
        return @max(@as(usize, 1), @min(@as(usize, @intCast(n)), MAX_SCHED_CPUS));
    }
    if (builtin.cpu.arch == .loongarch64) {
        const topo = @import("../hal/loongarch64/cpu_topology.zig");
        const n: u32 = topo.logicalCpuCount();
        return @max(@as(usize, 1), @min(@as(usize, @intCast(n)), MAX_SCHED_CPUS));
    }
    if (builtin.cpu.arch == .mips64el) {
        const topo = @import("../hal/mips64el/cpu_topology.zig");
        const n: u32 = topo.logicalCpuCount();
        return @max(@as(usize, 1), @min(@as(usize, @intCast(n)), MAX_SCHED_CPUS));
    }
    return 1;
}

fn homeCpuSchedSlot(home: u32) usize {
    const n = schedNumCpus();
    return @intCast(home % n);
}

/// 亲和：位掩码为 0 表示「允许当前构建中全部逻辑 CPU」。
fn affinityCpuMask(t: *const Thread) u64 {
    if (t.affinity_mask == 0) {
        const n = schedNumCpus();
        if (n >= 64) return 0xFFFFFFFFFFFFFFFF;
        return (@as(u64, 1) << @intCast(n)) - 1;
    }
    return t.affinity_mask;
}

fn pickHomeCpuForAffinity(mask: u64) u32 {
    const n = schedNumCpus();
    var c: u32 = 0;
    while (c < n) : (c += 1) {
        if ((mask & (@as(u64, 1) << @intCast(c))) != 0) return c;
    }
    return 0;
}

fn resetReadyQueues() void {
    for (&ready_head) |*row| {
        for (row) |*h| h.* = -1;
    }
    for (&ready_tail) |*row| {
        for (row) |*t| t.* = -1;
    }
    for (&non_empty) |*m| m.* = 0;
    for (&rr_cpu_cursor) |*c| c.* = 0;
}

fn refreshNonEmptyBit(cpu: usize, pri: u8) void {
    std.debug.assert(pri < NUM_PRI);
    const bit: u32 = @as(u32, 1) << @intCast(pri);
    if (ready_head[cpu][pri] < 0) {
        non_empty[cpu] &= ~bit;
    } else {
        non_empty[cpu] |= bit;
    }
}

fn unlinkFromBucket(cpu: usize, pri: u8, tid: usize) void {
    var prev: i32 = -1;
    var cur = ready_head[cpu][pri];
    while (cur >= 0) {
        const ct: usize = @intCast(cur);
        if (ct == tid) {
            const next = threads[ct].next_ready;
            if (prev < 0) {
                ready_head[cpu][pri] = next;
            } else {
                threads[@intCast(prev)].next_ready = next;
            }
            if (ready_tail[cpu][pri] == cur) {
                ready_tail[cpu][pri] = prev;
            }
            threads[ct].next_ready = -1;
            refreshNonEmptyBit(cpu, pri);
            return;
        }
        prev = cur;
        cur = threads[ct].next_ready;
    }
}

fn removeFromBucketForTid(tid: usize) void {
    if (tid >= thread_count) return;
    if (!threads[tid].in_ready_queue) return;
    const cpu: usize = @intCast(threads[tid].ready_sched_cpu);
    const pri = threads[tid].ready_bucket_pri;
    if (pri >= NUM_PRI) return;
    unlinkFromBucket(cpu, @truncate(pri), tid);
    threads[tid].in_ready_queue = false;
    threads[tid].ready_bucket_pri = 255;
}

fn enqueueToBucket(cpu: usize, pri: u8, tid: usize) void {
    std.debug.assert(pri < NUM_PRI);
    if (tid >= thread_count) return;
    threads[tid].next_ready = -1;
    threads[tid].in_ready_queue = true;
    threads[tid].ready_bucket_pri = pri;
    threads[tid].ready_sched_cpu = @truncate(cpu);
    const th: i32 = @intCast(tid);
    const tail = ready_tail[cpu][pri];
    if (tail < 0) {
        ready_head[cpu][pri] = th;
        ready_tail[cpu][pri] = th;
    } else {
        threads[@intCast(tail)].next_ready = th;
        ready_tail[cpu][pri] = th;
    }
    non_empty[cpu] |= @as(u32, 1) << @intCast(pri);
}

/// 按当前 `effectivePriority` 入队（`home_cpu` 决定 CPU 槽；受亲和掩码约束）。
fn enqueueReady(tid: usize) void {
    if (tid >= thread_count) return;
    if (threads[tid].in_ready_queue) return;
    const ep = effectivePriority(&threads[tid]);
    var slot = homeCpuSchedSlot(threads[tid].home_cpu);
    const mask = affinityCpuMask(&threads[tid]);
    if ((mask & (@as(u64, 1) << @intCast(slot % schedNumCpus()))) == 0) {
        threads[tid].home_cpu = pickHomeCpuForAffinity(mask);
        slot = homeCpuSchedSlot(threads[tid].home_cpu);
    }
    enqueueToBucket(slot, ep, tid);
}

fn removeFromReadyQueue(tid: usize) void {
    removeFromBucketForTid(tid);
}

fn rebalanceReadyBuckets() void {
    var tid: usize = 0;
    while (tid < thread_count) : (tid += 1) {
        if (!threads[tid].in_ready_queue) continue;
        const want = effectivePriority(&threads[tid]);
        if (threads[tid].ready_bucket_pri == want) continue;
        removeFromBucketForTid(tid);
        enqueueReady(tid);
    }
}

fn popHeadBucket(cpu: usize, pri: u8) ?usize {
    const h = ready_head[cpu][pri];
    if (h < 0) return null;
    const tid: usize = @intCast(h);
    const next = threads[tid].next_ready;
    ready_head[cpu][pri] = next;
    if (next < 0) ready_tail[cpu][pri] = -1;
    threads[tid].next_ready = -1;
    threads[tid].in_ready_queue = false;
    threads[tid].ready_bucket_pri = 255;
    refreshNonEmptyBit(cpu, pri);
    return tid;
}

fn popHeadFairAtPriority(pri: u8) ?usize {
    std.debug.assert(pri < NUM_PRI);
    const n = schedNumCpus();
    if (n == 0) return null;
    const start: usize = @intCast(rr_cpu_cursor[pri] % n);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cpu = (start + i) % n;
        if ((non_empty[cpu] & (@as(u32, 1) << @intCast(pri))) != 0) {
            rr_cpu_cursor[pri] = @truncate((cpu + 1) % n);
            return popHeadBucket(cpu, pri);
        }
    }
    return null;
}

fn maxNonemptyPriAcrossCpus() ?u8 {
    var combined: u32 = 0;
    const n = schedNumCpus();
    var c: usize = 0;
    while (c < n) : (c += 1) {
        combined |= non_empty[c];
    }
    if (combined == 0) return null;
    return @intCast(31 - @clz(combined));
}

fn hasOtherReadyAtPriority(pri: u8, except_tid: usize) bool {
    const n = schedNumCpus();
    var cpu: usize = 0;
    while (cpu < n) : (cpu += 1) {
        var t = ready_head[cpu][pri];
        while (t >= 0) {
            const ct: usize = @intCast(t);
            if (ct != except_tid) return true;
            t = threads[ct].next_ready;
        }
    }
    return false;
}

fn popHeadHighestGlobal() ?usize {
    const mp = maxNonemptyPriAcrossCpus() orelse return null;
    var p: u8 = mp;
    while (true) {
        if (popHeadFairAtPriority(p)) |tid| return tid;
        if (p == 0) return null;
        p -= 1;
    }
}

fn popHeadHighestFromCpu(cpu: usize) ?usize {
    const m = non_empty[cpu];
    if (m == 0) return null;
    const pri: u8 = @intCast(31 - @clz(m));
    return popHeadBucket(cpu, pri);
}

fn cpuHasAnyReady(cpu: usize) bool {
    return non_empty[cpu] != 0;
}

/// K2.6：统计某 CPU 槽上就绪链中的线程数（供新线程 `home_cpu` 负载均衡）。
fn readyThreadCountOnCpu(cpu: usize) usize {
    var len: usize = 0;
    var pri: u8 = 0;
    while (pri < NUM_PRI) : (pri += 1) {
        var t = ready_head[cpu][pri];
        while (t >= 0) {
            len += 1;
            t = threads[@intCast(t)].next_ready;
        }
    }
    return len;
}

/// 在可见逻辑 CPU 中选择 **当前就绪队列最短** 的槽位，降低偏斜（SMP 下与窃取协同）。
fn pickBalancedHomeCpu() u32 {
    const n = schedNumCpus();
    if (n <= 1) return 0;
    var best_c: u32 = 0;
    var best_len: usize = std.math.maxInt(usize);
    var c: u32 = 0;
    while (c < n) : (c += 1) {
        const slot: usize = @intCast(c);
        const len = readyThreadCountOnCpu(slot);
        if (len < best_len) {
            best_len = len;
            best_c = c;
        }
    }
    return best_c;
}

fn isBspIdleThreadForSteal() bool {
    return current_thread < thread_count and
        threads[current_thread].id == 0 and
        threads[current_thread].priority == PRIORITY_IDLE;
}

/// J8：BSP（调度 **槽 0**）idle 时从其它逻辑 CPU **最长就绪链**窃取一头，与 `pickBalancedHomeCpu` 的新线程均衡协同。
fn workStealBalanceIfIdleImpl() void {
    const n = schedNumCpus();
    if (n <= 1) return;
    const here: usize = @intCast(kpcr.currentProcessorNumber());
    if (here != 0) return; // AP 上 `tick` 已跳过或尚无每核 current_thread；窃取仅 BSP 槽直至全每核调度闭环。
    if (!isBspIdleThreadForSteal()) return;
    if (cpuHasAnyReady(here)) return;
    var best_c: usize = 0;
    var best_len: usize = 0;
    var c: usize = 0;
    while (c < n) : (c += 1) {
        if (c == here) continue;
        var len: usize = 0;
        var pri: usize = 0;
        while (pri < NUM_PRI) : (pri += 1) {
            var t = ready_head[c][pri];
            while (t >= 0) {
                len += 1;
                t = threads[@intCast(t)].next_ready;
            }
        }
        if (len > best_len) {
            best_len = len;
            best_c = c;
        }
    }
    if (best_len == 0) return;
    const stolen = popHeadHighestFromCpu(best_c) orelse return;
    threads[stolen].home_cpu = @intCast(here);
    enqueueReady(stolen);
}

fn isSchedulable(idx: usize) bool {
    if (idx >= thread_count) return false;
    const t = &threads[idx];
    if (t.state == .running) return true;
    return t.state == .ready and t.in_ready_queue;
}

/// NT 6.1 风格 **0–31**（越大越优先）。
pub const PRIORITY_IDLE: u8 = 1;
pub const PRIORITY_NORMAL: u8 = 8;
pub const PRIORITY_REALTIME: u8 = 24;

pub const PRIORITY_CLASS_COUNT: usize = 8;

/// 动态优先级区间上界（含）：`priority <=` 此值时参与防饥饿抬升；**实时**线程通常保持基线不被动态饿死（clean-room 近似）。
pub const PRIORITY_DYNAMIC_MAX: u8 = 15;

/// 兼容旧名：默认定时器 tick 数（已由 `quantumTicksForThread` 取代）。
pub const TIME_SLICE_TICKS: u32 = 6;

pub const IO_BOOST_PRIORITY_DELTA: u8 = 2;
pub const IO_BOOST_DURATION_TICKS: u64 = 20;
pub const STARVATION_TICK_THRESHOLD: u64 = 200;
pub const STARVATION_BOOST: u8 = 2;

/// 每 **优先级类** 的量子（timer tick）；数值越大同优先级占用越久。clean-room，非 Windows 内部表。
const QUANTUM_BY_CLASS: [PRIORITY_CLASS_COUNT]u32 = .{ 4, 5, 6, 7, 8, 10, 12, 14 };

pub fn priorityFromClass(class: u8) u8 {
    const c: u32 = @min(@as(u32, class), PRIORITY_CLASS_COUNT - 1);
    const p: u32 = 2 + c * 3;
    return @truncate(@min(p, 31));
}

pub fn quantumTicksForClass(class: u8) u32 {
    const c: usize = @min(@as(usize, class), PRIORITY_CLASS_COUNT - 1);
    return QUANTUM_BY_CLASS[c];
}

fn quantumTicksForThread(t: *const Thread) u32 {
    const c: usize = @min(@as(usize, t.priority_class), PRIORITY_CLASS_COUNT - 1);
    var q = QUANTUM_BY_CLASS[c];
    if (process_mod.findProcess(t.process_id)) |p| {
        if (p.is_foreground) q +%= foreground_quantum_bonus_ticks;
    }
    return q;
}

pub const Thread = struct {
    id: usize = 0,
    process_id: u32 = 0,
    home_cpu: u32 = 0,
    /// 亲和掩码：位 i = 可运行在逻辑 CPU i；0 = 全部允许（受 `MAX_SCHED_CPUS` 截断）。
    affinity_mask: u64 = 0,
    state: ThreadState = .ready,
    context: ThreadContext = .{},
    stack: [STACK_SIZE]u8 align(16) = undefined,
    stack_top: usize = 0,
    priority: u8 = 0,
    /// 0..7，影响时间片长度（`QUANTUM_BY_CLASS`）。
    priority_class: u8 = 4,
    io_boost: u8 = 0,
    boost_deadline_tick: u64 = 0,
    slice_remaining: u32 = TIME_SLICE_TICKS,
    next_ready: i32 = -1,
    in_ready_queue: bool = false,
    /// 当前就绪桶优先级；255 = 不在任何桶。
    ready_bucket_pri: u8 = 255,
    ready_sched_cpu: u8 = 0,
    /// 互斥体等待者抬升的**下限**（effective 至少为此值）。
    mutex_inherit_floor: u8 = 0,
    /// 并行等待边数量：每有一条「本 mutex 触发的继承边」+1；最后一次 `endMutexInheritance` 时若归零则清零 floor。
    mutex_inherit_depth: u32 = 0,
    name: [16]u8 = [_]u8{0} ** 16,
    kernel_apc_head: ?*KeApc = null,
    user_apc_head: ?*KeApc = null,
    /// `keWait*` 阻塞在对象等待队列上时为 true（与 `ob.WaitEntry` 链一致）。
    in_object_wait: bool = false,
    wait_entries: [64]ob.WaitEntry = undefined,
    wait_entry_count: u32 = 0,
    wait_deadline_ticks: ?u64 = null,
    wait_alertable: bool = false,
    /// 超时 / APC / `notifyEventSet` 完成等待时在 `unblock` 前写入；`keWait` 持锁消费。
    pending_wait_status: ?i32 = null,
    /// `NtAlertThread` 置位；可告警等待路径在 `STATUS_USER_APC` 之前消费并返回 `STATUS_ALERTED`。
    alert_pending: bool = false,
    /// 非 0：阻塞在 **该 receiver_pid** 的 LPC 入站队列上（`ipc`）；与 `wakeLpcWaitersForReceiverPid` 配对。
    lpc_wait_receiver_pid: u32 = 0,
    /// NT 6.1：`ThreadBasicInformation.TebBaseAddress` / 用户调试子集；与 `peb_nt61_x64.stubUserTebPageVa` 对齐，映射由进程创建路径提交。
    teb_user_va: u64 = 0,
    /// WOW64：与所属 `Process.is_wow64` 同步（`attachWow64IfPresent` / `createThread`）。
    is_wow64: bool = false,
    /// LoongArch64：`thread_switch.LaThreadContext` 的 11×u64 镜像；其它架构下保留为 0 占位。
    la_context_raw: [11]u64 align(8) = @splat(0),
    /// RISC-V64：`thread_switch.RvThreadContext` 的 14×u64 镜像；其它架构下保留为 0 占位。
    rv_context_raw: [14]u64 align(8) = @splat(0),
    /// AArch64：`thread_switch.A64ThreadContext` 的 13×u64 镜像；其它架构下保留为 0 占位。
    a64_context_raw: [13]u64 align(8) = @splat(0),
    /// MIPS64EL：`thread_switch.MipsThreadContext` 的 13×u64 镜像；其它架构下保留为 0 占位。
    mips_context_raw: [13]u64 align(8) = @splat(0),
};

fn effectivePriority(t: *const Thread) u8 {
    const sum = @as(u16, t.priority) + @as(u16, t.io_boost);
    var p: u8 = @intCast(@min(sum, @as(u16, 31)));
    p = @max(p, t.mutex_inherit_floor);
    if (t.priority <= PRIORITY_DYNAMIC_MAX and
        t.state == .ready and
        t.in_ready_queue and
        starve_ticks[t.id] > STARVATION_TICK_THRESHOLD)
    {
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

/// 从所有对象等待队列摘除本线程（持 `sched_irq_lock`）。
pub fn detachThreadFromWaitQueues(tid: usize) void {
    if (tid >= thread_count) return;
    const t = &threads[tid];
    if (!t.in_object_wait) return;
    var j: u32 = 0;
    while (j < t.wait_entry_count) : (j += 1) {
        ob.waitListRemove(&t.wait_entries[j]);
    }
    t.wait_entry_count = 0;
    t.in_object_wait = false;
    t.wait_deadline_ticks = null;
    t.wait_alertable = false;
}

/// 唤醒因对象等待阻塞的线程（持 `sched_irq_lock`）；`status` 常为 `STATUS_WAIT_0 + slot`。
pub fn completeObjectWait(tid: usize, status: i32) void {
    if (tid >= thread_count) return;
    detachThreadFromWaitQueues(tid);
    threads[tid].pending_wait_status = status;
    unblockThread(tid);
}

fn processBlockedObjectWaitsLocked() void {
    if (!scheduling_enabled) return;
    const status_timeout: i32 = 258;
    const status_user_apc: i32 = @bitCast(@as(u32, 0xC0000012));
    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        if (threads[i].state != .blocked) continue;
        if (!threads[i].in_object_wait) continue;
        if (threads[i].pending_wait_status != null) continue;

        if (threads[i].wait_deadline_ticks) |d| {
            if (tick_count >= d) {
                completeObjectWait(i, status_timeout);
                continue;
            }
        }
        if (threads[i].wait_alertable and threads[i].user_apc_head != null) {
            completeObjectWait(i, status_user_apc);
        }
    }
}

fn terminateThreadsForProcess(pid: u32) void {
    if (pid == 0) return;
    sched_irq_lock.lock();
    defer sched_irq_lock.unlock();

    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        if (i == 0) continue; // idle
        if (threads[i].process_id == pid) {
            detachThreadFromWaitQueues(i);
            removeFromReadyQueue(i);
            threads[i].lpc_wait_receiver_pid = 0;
            threads[i].state = .terminated;
            threads[i].mutex_inherit_floor = 0;
            threads[i].mutex_inherit_depth = 0;
        }
    }
    if (current_thread < thread_count and threads[current_thread].process_id == pid) {
        current_thread = 0;
        kpcr.setCurrentThreadIndex(0);
        activateCr3ForProcessId(0);
    }
}

pub fn init() void {
    kpcr.setProcessorNumber(0);
    resetReadyQueues();
    thread_count = 0;
    current_thread = 0;
    kpcr.setCurrentThreadIndex(0);
    tick_count = 0;
    initialized = true;
    scheduling_enabled = false;

    process_mod.before_release_process_address_space = terminateThreadsForProcess;
    process_mod.after_attach_wow64 = syncWow64FlagForProcessThreads;

    _ = createIdleThread();
}

fn syncWow64FlagForProcessThreads(pid: u32) void {
    var i: usize = 1;
    while (i < thread_count) : (i += 1) {
        if (threads[i].process_id == pid) {
            threads[i].is_wow64 = true;
        }
    }
}

/// 权威 WOW64 线程标志：与 `Process.is_wow64` 一致；`int 0x2E` 路径可双重校验。
pub fn currentThreadIsWow64() bool {
    if (current_thread >= thread_count) return false;
    return threads[current_thread].is_wow64;
}

fn createIdleThread() ?usize {
    if (thread_count >= MAX_THREADS) return null;

    const idx = thread_count;
    threads[idx] = .{};
    threads[idx].id = idx;
    threads[idx].home_cpu = percpu_sched.assignCpuForNewThread();
    threads[idx].affinity_mask = 0;
    threads[idx].state = .running;
    threads[idx].priority = PRIORITY_IDLE;
    threads[idx].priority_class = 0;
    threads[idx].io_boost = 0;
    threads[idx].boost_deadline_tick = 0;
    threads[idx].slice_remaining = quantumTicksForThread(&threads[idx]);
    threads[idx].teb_user_va = peb_stub_va.stubUserTebPageVa(idx);

    const idle_name = "idle";
    @memcpy(threads[idx].name[0..idle_name.len], idle_name);

    thread_count += 1;
    current_thread = idx;
    kpcr.setCurrentThreadIndex(@intCast(idx));

    klog.info("Scheduler: idle thread (tid=%u) created", .{idx});
    return idx;
}

pub fn createThread(entry: u64, process_id: u32) ?usize {
    if (!initialized or thread_count >= MAX_THREADS) return null;

    const idx = thread_count;
    threads[idx] = .{};
    threads[idx].id = idx;
    threads[idx].process_id = process_id;
    threads[idx].home_cpu = pickBalancedHomeCpu();
    threads[idx].affinity_mask = 0;
    threads[idx].state = .ready;
    threads[idx].priority = PRIORITY_NORMAL;
    threads[idx].priority_class = 4;
    threads[idx].io_boost = 0;
    threads[idx].boost_deadline_tick = 0;
    threads[idx].slice_remaining = quantumTicksForThread(&threads[idx]);

    const stack_base = @intFromPtr(&threads[idx].stack);
    const stack_end = stack_base + STACK_SIZE;

    if (builtin.target.cpu.arch == .loongarch64) {
        const la_ts = @import("../arch/loongarch64/thread_switch.zig");
        const la_ptr: *la_ts.LaThreadContext = @ptrCast(&threads[idx].la_context_raw);
        la_ts.initNewThread(la_ptr, entry, stack_end);
        threads[idx].stack_top = la_ptr.sp;
    } else if (builtin.target.cpu.arch == .riscv64) {
        const rv_ts = @import("../arch/riscv64/thread_switch.zig");
        const rv_ptr: *rv_ts.RvThreadContext = @ptrCast(&threads[idx].rv_context_raw);
        rv_ts.initNewThread(rv_ptr, entry, stack_end);
        threads[idx].stack_top = rv_ptr.sp;
    } else if (builtin.target.cpu.arch == .aarch64) {
        const a64_ts = @import("../arch/aarch64/thread_switch.zig");
        const a64_ptr: *a64_ts.A64ThreadContext = @ptrCast(&threads[idx].a64_context_raw);
        a64_ts.initNewThread(a64_ptr, entry, stack_end);
        threads[idx].stack_top = a64_ptr.sp;
    } else if (builtin.target.cpu.arch == .mips64el) {
        const mips_ts = @import("../arch/mips64el/thread_switch.zig");
        const mips_ptr: *mips_ts.MipsThreadContext = @ptrCast(&threads[idx].mips_context_raw);
        mips_ts.initNewThread(mips_ptr, entry, stack_end);
        threads[idx].stack_top = mips_ptr.sp;
    } else {
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
    }
    threads[idx].context.rip = entry;
    threads[idx].teb_user_va = peb_stub_va.stubUserTebPageVa(idx);
    threads[idx].is_wow64 = if (process_mod.findProcess(process_id)) |pr| pr.is_wow64 else false;

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

    rebalanceReadyBuckets();

    processBlockedObjectWaitsLocked();

    if (cur >= thread_count) return;

    // 当前线程已阻塞时必须让出 CPU（否则 `keWait` 在单核上无法前进）。
    if (threads[cur].state == .blocked) {
        const next_blk = popHeadHighestGlobal() orelse return;
        if (next_blk == cur or threads[next_blk].state == .terminated) return;
        threads[next_blk].state = .running;
        threads[next_blk].slice_remaining = quantumTicksForThread(&threads[next_blk]);
        current_thread = next_blk;
        kpcr.setCurrentThreadIndex(@intCast(next_blk));
        activateCr3ForProcessId(threads[next_blk].process_id);
        if (builtin.target.cpu.arch == .loongarch64) {
            performLoongArchContextSwitch(cur, next_blk);
        }
        if (builtin.target.cpu.arch == .riscv64) {
            performRiscvContextSwitch(cur, next_blk);
        }
        if (builtin.target.cpu.arch == .aarch64) {
            performAarch64ContextSwitch(cur, next_blk);
        }
        if (builtin.target.cpu.arch == .mips64el) {
            performMipsContextSwitch(cur, next_blk);
        }
        return;
    }

    if (threads[cur].state == .running and threads[cur].slice_remaining > 0) {
        threads[cur].slice_remaining -= 1;
    }

    const cur_ep = effectivePriority(&threads[cur]);
    const max_ready_pri = maxNonemptyPriAcrossCpus() orelse 0;
    const higher = max_ready_pri > cur_ep;
    const slice_done = threads[cur].slice_remaining == 0;
    const rr = !higher and slice_done and max_ready_pri == cur_ep and
        hasOtherReadyAtPriority(cur_ep, cur);

    if (!higher and !rr) return;

    const next: usize = if (higher)
        popHeadHighestGlobal() orelse return
    else
        popHeadFairAtPriority(cur_ep) orelse return;

    if (next == cur or threads[next].state == .terminated) return;

    if (threads[cur].state == .running) {
        threads[cur].state = .ready;
        threads[cur].slice_remaining = quantumTicksForThread(&threads[cur]);
        enqueueReady(cur);
    }
    threads[next].state = .running;
    threads[next].slice_remaining = quantumTicksForThread(&threads[next]);
    current_thread = next;
    kpcr.setCurrentThreadIndex(@intCast(next));
    activateCr3ForProcessId(threads[next].process_id);
    if (builtin.target.cpu.arch == .loongarch64) {
        performLoongArchContextSwitch(cur, next);
    }
    if (builtin.target.cpu.arch == .riscv64) {
        performRiscvContextSwitch(cur, next);
    }
    if (builtin.target.cpu.arch == .aarch64) {
        performAarch64ContextSwitch(cur, next);
    }
    if (builtin.target.cpu.arch == .mips64el) {
        performMipsContextSwitch(cur, next);
    }
}

fn performLoongArchContextSwitch(from_idx: usize, to_idx: usize) void {
    if (builtin.target.cpu.arch != .loongarch64) return;
    const la_ts = @import("../arch/loongarch64/thread_switch.zig");
    const from_ctx: *la_ts.LaThreadContext = @ptrCast(&threads[from_idx].la_context_raw);
    const to_ctx: *la_ts.LaThreadContext = @ptrCast(&threads[to_idx].la_context_raw);
    la_ts.loongarch_switch_context(from_ctx, to_ctx);
}

fn performRiscvContextSwitch(from_idx: usize, to_idx: usize) void {
    if (builtin.target.cpu.arch != .riscv64) return;
    const rv_ts = @import("../arch/riscv64/thread_switch.zig");
    const from_ctx: *rv_ts.RvThreadContext = @ptrCast(&threads[from_idx].rv_context_raw);
    const to_ctx: *rv_ts.RvThreadContext = @ptrCast(&threads[to_idx].rv_context_raw);
    rv_ts.riscv_switch_context(from_ctx, to_ctx);
}

fn performAarch64ContextSwitch(from_idx: usize, to_idx: usize) void {
    if (builtin.target.cpu.arch != .aarch64) return;
    const a64_ts = @import("../arch/aarch64/thread_switch.zig");
    const from_ctx: *a64_ts.A64ThreadContext = @ptrCast(&threads[from_idx].a64_context_raw);
    const to_ctx: *a64_ts.A64ThreadContext = @ptrCast(&threads[to_idx].a64_context_raw);
    a64_ts.aarch64_switch_context(from_ctx, to_ctx);
}

fn performMipsContextSwitch(from_idx: usize, to_idx: usize) void {
    if (builtin.target.cpu.arch != .mips64el) return;
    const mips_ts = @import("../arch/mips64el/thread_switch.zig");
    const from_ctx: *mips_ts.MipsThreadContext = @ptrCast(&threads[from_idx].mips_context_raw);
    const to_ctx: *mips_ts.MipsThreadContext = @ptrCast(&threads[to_idx].mips_context_raw);
    mips_ts.mips64_switch_context(from_ctx, to_ctx);
}

pub fn yield() void {
    tick();
}

pub fn getThreadByIndex(idx: usize) ?*Thread {
    if (idx >= thread_count) return null;
    return &threads[idx];
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

/// 持 `sched_irq_lock`：将线程标为阻塞在 `receiver_pid` 的 LPC 队列上（须已 `removeFromReadyQueue` 等价效果由本函数完成）。
pub fn prepareLpcReceiveBlockLocked(tid: usize, receiver_pid: u32) void {
    if (tid >= thread_count) return;
    threads[tid].lpc_wait_receiver_pid = receiver_pid;
    removeFromReadyQueue(tid);
    threads[tid].state = .blocked;
}

/// `ipc` 在成功 `push` 后调用：唤醒所有等待该接收方队列的阻塞线程。
pub fn wakeLpcWaitersForReceiverPid(receiver_pid: u32) void {
    if (receiver_pid == 0) return;
    sched_irq_lock.lock();
    defer sched_irq_lock.unlock();
    var i: usize = 0;
    while (i < thread_count) : (i += 1) {
        if (threads[i].state != .blocked) continue;
        if (threads[i].lpc_wait_receiver_pid != receiver_pid) continue;
        threads[i].lpc_wait_receiver_pid = 0;
        unblockThread(i);
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

pub fn lockSchedIrq() void {
    sched_irq_lock.lock();
}

pub fn unlockSchedIrq() void {
    sched_irq_lock.unlock();
}

pub fn schedulingIsEnabled() bool {
    return scheduling_enabled;
}

/// 与 `sched_irq_lock` 同锁下读取（`tick` / `keWait*`）。
pub fn tickCountLocked() u64 {
    return tick_count;
}

pub fn consumePendingWaitStatus(tid: usize) ?i32 {
    if (tid >= thread_count) return null;
    const st = threads[tid].pending_wait_status orelse return null;
    threads[tid].pending_wait_status = null;
    return st;
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

/// `NtQueryInformationThread`：`sched_tid` 为 `createThread` / `createIdleThread` 返回的槽索引。
pub fn getTebUserVaForSchedIndex(sched_tid: usize) u64 {
    if (sched_tid >= thread_count) return 0;
    return threads[sched_tid].teb_user_va;
}

/// 进程创建路径在用户区映射 TEB 页后同步（与 `stubUserTebPageVa` 一致）。
pub fn setTebUserVaForSchedIndex(sched_tid: usize, teb_va: u64) void {
    if (sched_tid >= thread_count) return;
    threads[sched_tid].teb_user_va = teb_va;
}

pub fn setThreadPriority(tid: usize, priority: u8) void {
    if (tid >= thread_count) return;
    threads[tid].priority = priority;
}

pub fn setThreadPriorityClass(tid: usize, class: u8) void {
    if (tid >= thread_count) return;
    threads[tid].priority_class = @min(class, PRIORITY_CLASS_COUNT - 1);
}

pub fn setThreadAffinityMask(tid: usize, mask: u64) void {
    if (tid >= thread_count) return;
    threads[tid].affinity_mask = mask;
    threads[tid].home_cpu = pickHomeCpuForAffinity(affinityCpuMask(&threads[tid]));
}

/// 本 mutex 上**首次**建立等待继承边：深度 +1 并抬升 floor。
pub fn beginMutexInheritance(owner_tid: usize, waiter_effective_pri: u8) void {
    if (owner_tid >= thread_count) return;
    threads[owner_tid].mutex_inherit_depth +|= 1;
    threads[owner_tid].mutex_inherit_floor = @max(threads[owner_tid].mutex_inherit_floor, waiter_effective_pri);
}

/// 同一条等待边上 waiter 有效优先级变化时仅刷新 floor（不增减深度）。
pub fn updateMutexInheritFloor(owner_tid: usize, waiter_effective_pri: u8) void {
    if (owner_tid >= thread_count) return;
    threads[owner_tid].mutex_inherit_floor = @max(threads[owner_tid].mutex_inherit_floor, waiter_effective_pri);
}

/// 释放 mutex 时配对调用：深度减一；仅当深度归零时清零 floor（多锁时避免过早回落）。
pub fn endMutexInheritance(owner_tid: usize) void {
    if (owner_tid >= thread_count) return;
    if (threads[owner_tid].mutex_inherit_depth == 0) return;
    threads[owner_tid].mutex_inherit_depth -= 1;
    if (threads[owner_tid].mutex_inherit_depth == 0) {
        threads[owner_tid].mutex_inherit_floor = 0;
    }
}

/// 遗留/调试：强制清空继承状态。
pub fn clearMutexInheritFloor(owner_tid: usize) void {
    if (owner_tid >= thread_count) return;
    threads[owner_tid].mutex_inherit_depth = 0;
    threads[owner_tid].mutex_inherit_floor = 0;
}

/// 兼容旧名：等价于 `updateMutexInheritFloor`（不推荐新代码使用）。
pub fn applyMutexInheritFloor(owner_tid: usize, waiter_effective_pri: u8) void {
    updateMutexInheritFloor(owner_tid, waiter_effective_pri);
}

/// GUI / 输入完成路径可调用此占位钩子，将来接线 `io_boost` 或前台会话（见 `Process.is_foreground`）。
pub fn noteGuiInputBoostStub() void {}

pub fn isInitialized() bool {
    return initialized;
}

/// AP 在线程/按核 tick 全量镜像前：开中断并在 **sti;hlt** 中等待（PIT/IOAPIC 或 IPI 可唤醒）。
pub fn apProcessorIdleLoop() noreturn {
    if (builtin.cpu.arch == .x86_64) {
        const arch_x = @import("../arch/x86_64/mod.zig");
        arch_x.enableInterrupts();
        while (true) {
            asm volatile ("sti; hlt" ::: .{ .memory = true });
        }
    }
    if (builtin.cpu.arch == .loongarch64) {
        const arch_la = @import("../arch/loongarch64/mod.zig");
        arch_la.enableInterrupts();
        while (true) {
            asm volatile ("idle 0" ::: .{ .memory = true });
        }
    }
    if (builtin.cpu.arch == .mips64el) {
        const arch_mips = @import("../arch/mips64el/mod.zig");
        arch_mips.enableInterrupts();
        while (true) {
            asm volatile ("wait" ::: .{ .memory = true });
        }
    }
    while (true) {
        std.atomic.spinLoopHint();
    }
}

/// 供测试或调试对照 `effectivePriority`（与内部算法一致）。
pub fn effectivePriorityForThread(tid: usize) ?u8 {
    if (tid >= thread_count) return null;
    return effectivePriority(&threads[tid]);
}
