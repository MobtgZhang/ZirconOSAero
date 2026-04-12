// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/ke/wait.zig
// Purpose: 可等待对象上的 `KeWait*` 子集：对象头 FIFO 等待队列、`blockThread`/`tick` 协同、超时 tick、`alertable` 与用户 APC。
//
// This is an independent clean-room implementation.
// Ref: https://learn.microsoft.com/windows-hardware/drivers/kernel/wait-synchronization

const std = @import("std");
const scheduler = @import("scheduler.zig");
const ob = @import("../ob/object.zig");
const apc_mod = @import("apc.zig");

pub const STATUS_WAIT_0: i32 = 0;
pub const STATUS_TIMEOUT: i32 = 258;
/// `STATUS_ALERTED`（0x101）— `NtAlertThread` 与可告警等待。
pub const STATUS_ALERTED: i32 = 257;
/// `STATUS_USER_APC`（0xC0000012）
pub const STATUS_USER_APC: i32 = @bitCast(@as(u32, 0xC0000012));

fn threadAlertableReturn(th: *scheduler.Thread) ?i32 {
    if (th.alert_pending) {
        th.alert_pending = false;
        return STATUS_ALERTED;
    }
    if (apc_mod.hasPendingUserApcForThread(th)) return STATUS_USER_APC;
    return null;
}

fn isWaitableReady(hdr: *ob.ObjectHeader) bool {
    switch (hdr.obj_type) {
        .event, .mutex => return hdr.signal_state,
        .semaphore => return semaphoreCount(hdr) > 0,
        else => return hdr.signal_state,
    }
}

fn consumeEventSignalIfAuto(hdr: *ob.ObjectHeader) void {
    if (hdr.obj_type != .event) return;
    if ((hdr.flags & ob.OBJ_FLAG_EVENT_AUTO_RESET) != 0) {
        hdr.signal_state = false;
    }
}

fn semaphoreCount(hdr: *const ob.ObjectHeader) i32 {
    return @bitCast(@as(u32, @truncate(hdr.creation_time)));
}

fn semaphoreMax(hdr: *const ob.ObjectHeader) i32 {
    return @bitCast(@as(u32, @truncate(hdr.creation_time >> 32)));
}

fn semaphoreSet(hdr: *ob.ObjectHeader, cur: i32, maxv: i32) void {
    const low = @as(u64, @as(u32, @bitCast(cur)));
    const high = @as(u64, @as(u32, @bitCast(maxv))) << 32;
    hdr.creation_time = low | high;
    hdr.signal_state = cur > 0;
}

/// 满足一次等待：`event` 消耗自动复位；`mutex` 占有（清可用位）；`semaphore` 计数减一。
fn tryConsumeWaitable(hdr: *ob.ObjectHeader) bool {
    switch (hdr.obj_type) {
        .event => {
            if (!hdr.signal_state) return false;
            consumeEventSignalIfAuto(hdr);
            return true;
        },
        .mutex => {
            if (!hdr.signal_state) return false;
            hdr.signal_state = false;
            return true;
        },
        .semaphore => {
            const c = semaphoreCount(hdr);
            if (c <= 0) return false;
            semaphoreSet(hdr, c - 1, semaphoreMax(hdr));
            return true;
        },
        else => return hdr.signal_state,
    }
}

fn keWaitCooperativeSingle(
    hdr: *ob.ObjectHeader,
    alertable: bool,
    deadline_ticks: ?u64,
) i32 {
    while (true) {
        if (hdr.signal_state) return STATUS_WAIT_0;
        if (alertable) {
            const th = scheduler.getCurrentThread() orelse return STATUS_WAIT_0;
            if (threadAlertableReturn(th)) |st| return st;
        }
        if (deadline_ticks) |d| {
            if (scheduler.getTicks() >= d) return STATUS_TIMEOUT;
        }
        scheduler.yield();
    }
}

fn keWaitCooperativeAny(
    hdrs: []const *ob.ObjectHeader,
    alertable: bool,
    deadline_ticks: ?u64,
) i32 {
    while (true) {
        for (hdrs, 0..) |h, i| {
            if (tryConsumeWaitable(h)) return STATUS_WAIT_0 + @as(i32, @intCast(i));
        }
        if (alertable) {
            const th = scheduler.getCurrentThread() orelse return STATUS_WAIT_0;
            if (threadAlertableReturn(th)) |st| return st;
        }
        if (deadline_ticks) |d| {
            if (scheduler.getTicks() >= d) return STATUS_TIMEOUT;
        }
        scheduler.yield();
    }
}

fn wakeOneFromObject(hdr: *ob.ObjectHeader) bool {
    const head = hdr.wait_list_head orelse return false;
    const tid = head.thread_index;
    const slot: i32 = @intCast(head.wait_slot);
    scheduler.completeObjectWait(tid, STATUS_WAIT_0 + slot);
    return true;
}

fn wakeAllFromObject(hdr: *ob.ObjectHeader) void {
    while (hdr.wait_list_head != null) {
        _ = wakeOneFromObject(hdr);
    }
}

/// `NtReleaseMutant` / `NtReleaseSemaphore` 在更新 dispatcher 状态后唤醒一名 FIFO 等待线程。
pub fn wakeOneWaiterFromDispatch(hdr: *ob.ObjectHeader) void {
    scheduler.lockSchedIrq();
    defer scheduler.unlockSchedIrq();
    _ = wakeOneFromObject(hdr);
}

/// `NtSetEvent` 后调用：`hdr.signal_state` 已由调用方置位；此处按手动/自动复位策略唤醒等待者。
pub fn onEventSet(hdr: *ob.ObjectHeader) void {
    scheduler.lockSchedIrq();
    defer scheduler.unlockSchedIrq();
    const auto = (hdr.flags & ob.OBJ_FLAG_EVENT_AUTO_RESET) != 0;
    if (auto) {
        if (wakeOneFromObject(hdr)) {
            hdr.signal_state = false;
        }
    } else {
        wakeAllFromObject(hdr);
    }
}

/// 单对象等待：`deadline_ticks == null` 为无限等待；否则与 `scheduler.tickCountLocked()` 比较（持 `sched_irq_lock` 时一致）。
pub fn keWaitForSingleObject(
    hdr: *ob.ObjectHeader,
    alertable: bool,
    deadline_ticks: ?u64,
) i32 {
    if (!scheduler.schedulingIsEnabled()) {
        return keWaitCooperativeSingle(hdr, alertable, deadline_ticks);
    }
    const tid = scheduler.getCurrentThreadId();
    while (true) {
        const outcome: ?i32 = blk: {
            scheduler.lockSchedIrq();
            defer scheduler.unlockSchedIrq();

            if (scheduler.consumePendingWaitStatus(tid)) |st| {
                break :blk st;
            }
            if (tryConsumeWaitable(hdr)) {
                break :blk STATUS_WAIT_0;
            }
            if (alertable) {
                const th2 = scheduler.getCurrentThread() orelse break :blk STATUS_WAIT_0;
                if (threadAlertableReturn(th2)) |st| break :blk st;
            }
            if (deadline_ticks) |d| {
                if (scheduler.tickCountLocked() >= d) break :blk STATUS_TIMEOUT;
            }

            const t = scheduler.getCurrentThread() orelse break :blk STATUS_WAIT_0;
            t.wait_entries[0] = .{};
            t.wait_entries[0].thread_index = tid;
            t.wait_entries[0].wait_slot = 0;
            t.wait_entries[0].hdr = hdr;
            ob.waitListAppend(hdr, &t.wait_entries[0]);
            t.wait_entry_count = 1;
            t.in_object_wait = true;
            t.wait_deadline_ticks = deadline_ticks;
            t.wait_alertable = alertable;
            scheduler.blockThread(tid);
            break :blk null;
        };
        if (outcome) |st| return st;
        scheduler.yield();
    }
}

/// `WaitAny`：任一对象已 signal 则返回 `STATUS_WAIT_0 + i`（`i` 为 `hdrs` 下标）。
pub fn keWaitForMultipleObjectsWaitAny(
    hdrs: []const *ob.ObjectHeader,
    alertable: bool,
    deadline_ticks: ?u64,
) i32 {
    if (!scheduler.schedulingIsEnabled()) {
        return keWaitCooperativeAny(hdrs, alertable, deadline_ticks);
    }
    std.debug.assert(hdrs.len <= 64);
    const tid = scheduler.getCurrentThreadId();
    while (true) {
        const outcome: ?i32 = blk: {
            scheduler.lockSchedIrq();
            defer scheduler.unlockSchedIrq();

            if (scheduler.consumePendingWaitStatus(tid)) |st| {
                break :blk st;
            }
            for (hdrs, 0..) |h, i| {
                if (tryConsumeWaitable(h)) {
                    break :blk STATUS_WAIT_0 + @as(i32, @intCast(i));
                }
            }
            if (alertable) {
                const thm = scheduler.getCurrentThread() orelse break :blk STATUS_WAIT_0;
                if (threadAlertableReturn(thm)) |st| break :blk st;
            }
            if (deadline_ticks) |d| {
                if (scheduler.tickCountLocked() >= d) break :blk STATUS_TIMEOUT;
            }

            const t = scheduler.getCurrentThread() orelse break :blk STATUS_WAIT_0;
            var k: u32 = 0;
            while (k < hdrs.len) : (k += 1) {
                t.wait_entries[k] = .{};
                t.wait_entries[k].thread_index = tid;
                t.wait_entries[k].wait_slot = k;
                t.wait_entries[k].hdr = hdrs[k];
                ob.waitListAppend(hdrs[k], &t.wait_entries[k]);
            }
            t.wait_entry_count = @truncate(hdrs.len);
            t.in_object_wait = true;
            t.wait_deadline_ticks = deadline_ticks;
            t.wait_alertable = alertable;
            scheduler.blockThread(tid);
            break :blk null;
        };
        if (outcome) |st| return st;
        scheduler.yield();
    }
}

fn keWaitCooperativeAll(
    hdrs: []const *ob.ObjectHeader,
    alertable: bool,
    deadline_ticks: ?u64,
) i32 {
    while (true) {
        var all_ready = true;
        for (hdrs) |h| {
            if (!isWaitableReady(h)) {
                all_ready = false;
                break;
            }
        }
        if (all_ready) {
            for (hdrs) |h| {
                _ = tryConsumeWaitable(h);
            }
            return STATUS_WAIT_0;
        }
        if (alertable) {
            const th = scheduler.getCurrentThread() orelse return STATUS_WAIT_0;
            if (threadAlertableReturn(th)) |st| return st;
        }
        if (deadline_ticks) |d| {
            if (scheduler.getTicks() >= d) return STATUS_TIMEOUT;
        }
        scheduler.yield();
    }
}

/// `WaitAll`：抢占调度开启时实现复合等待唤醒。
/// 跟踪每个对象的 signal 状态，仅当全部 signaled 时才消耗并返回。
pub fn keWaitForMultipleObjectsWaitAll(
    hdrs: []const *ob.ObjectHeader,
    alertable: bool,
    deadline_ticks: ?u64,
) i32 {
    if (!scheduler.schedulingIsEnabled()) {
        return keWaitCooperativeAll(hdrs, alertable, deadline_ticks);
    }
    std.debug.assert(hdrs.len <= 64);
    const tid = scheduler.getCurrentThreadId();

    // 信号状态跟踪数组（true = 已满足）
    var signaled: [64]bool = [_]bool{false} ** 64;
    var signaled_count: usize = 0;

    while (true) {
        const outcome: ?i32 = blk: {
            scheduler.lockSchedIrq();
            defer scheduler.unlockSchedIrq();

            // 检查是否有待处理的等待状态
            if (scheduler.consumePendingWaitStatus(tid)) |st| {
                break :blk st;
            }

            // 检查并消耗已 signal 的对象
            var all_ready = true;
            signaled_count = 0;
            for (hdrs, 0..) |h, i| {
                if (signaled[i]) {
                    signaled_count += 1;
                    continue;
                }
                if (tryConsumeWaitable(h)) {
                    signaled[i] = true;
                    signaled_count += 1;
                } else {
                    all_ready = false;
                }
            }

            // 所有对象都已 signaled → 消耗并返回
            if (all_ready and signaled_count == hdrs.len) {
                // 再次消耗（因为上面的 tryConsumeWaitable 已经消耗过一次）
                for (hdrs) |h| {
                    _ = tryConsumeWaitable(h);
                }
                break :blk STATUS_WAIT_0;
            }

            // 检查 alertable 条件
            if (alertable) {
                const th = scheduler.getCurrentThread() orelse break :blk STATUS_WAIT_0;
                if (threadAlertableReturn(th)) |st| break :blk st;
            }

            // 检查超时
            if (deadline_ticks) |d| {
                if (scheduler.tickCountLocked() >= d) break :blk STATUS_TIMEOUT;
            }

            // 注册到所有对象的等待队列
            const t = scheduler.getCurrentThread() orelse break :blk STATUS_WAIT_0;
            var k: u32 = 0;
            while (k < hdrs.len) : (k += 1) {
                t.wait_entries[k] = .{};
                t.wait_entries[k].thread_index = tid;
                t.wait_entries[k].wait_slot = k;
                t.wait_entries[k].hdr = hdrs[k];
                ob.waitListAppend(hdrs[k], &t.wait_entries[k]);
            }
            t.wait_entry_count = @truncate(hdrs.len);
            t.in_object_wait = true;
            t.wait_deadline_ticks = deadline_ticks;
            t.wait_alertable = alertable;
            scheduler.blockThread(tid);
            break :blk null;
        };
        if (outcome) |st| return st;
        scheduler.yield();
    }
}
