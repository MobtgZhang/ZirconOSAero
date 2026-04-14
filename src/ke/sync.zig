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

//! Kernel Synchronization Primitives
//! Event, Mutex, Semaphore, SpinLock
//!
//! Mutex `acquireWithInheritance` / `release` 与 `ke/scheduler.zig` 的 `beginMutexInheritance` / `endMutexInheritance` 联动；
//! 每条 mutex 等待边配对一次深度计数，多锁并行时避免过早清零 `mutex_inherit_floor`。
//!
//! PI-02 链式优先级继承：当等待者线程本身继承了其他互斥锁的优先级时，
//! 这个优先级应传播到当前互斥锁的持有者，形成优先级继承链。

const ob = @import("../ob/object.zig");
const scheduler = @import("scheduler.zig");
const arch = @import("../arch.zig");

pub const Event = struct {
    header: ob.ObjectHeader = .{ .obj_type = .event },
    signaled: bool = false,
    auto_reset: bool = false,

    pub fn init(auto_reset: bool) Event {
        return .{
            .header = .{ .obj_type = .event },
            .signaled = false,
            .auto_reset = auto_reset,
        };
    }

    pub fn set(self: *Event) void {
        self.setSignaledAtomic(true);
    }

    pub fn reset(self: *Event) void {
        self.setSignaledAtomic(false);
    }

    pub fn isSignaled(self: *const Event) bool {
        return self.signaled;
    }

    /// 原子化检查 signaled 状态，避免 TOCTOU 问题。
    fn checkSignaled(self: *const Event) bool {
        return @atomicLoad(bool, &self.signaled, .seq_cst);
    }

    /// 原子化设置 signaled 状态。
    fn setSignaledAtomic(self: *Event, value: bool) void {
        @atomicStore(bool, &self.signaled, value, .seq_cst);
    }

    pub fn wait(self: *Event) void {
        const tk = @import("timekeeping.zig");
        const deadline = tk.readInterruptTicks() +| 10_000; // 默认 10 秒超时
        while (!self.checkSignaled()) {
            const now = tk.readInterruptTicks();
            if (now >= deadline) {
                return; // 超时返回
            }
            scheduler.yield();
            arch.spinCpuRelax();
        }
        if (self.auto_reset) {
            self.setSignaledAtomic(false);
        }
    }

    /// 带超时的等待（单位：滴答数）
    pub fn waitWithTimeout(self: *Event, timeout_ticks: u64) bool {
        const tk = @import("timekeeping.zig");
        const deadline = tk.readInterruptTicks() +| timeout_ticks;
        while (!self.checkSignaled()) {
            const now = tk.readInterruptTicks();
            if (now >= deadline) {
                return false; // 超时
            }
            scheduler.yield();
            arch.spinCpuRelax();
        }
        if (self.auto_reset) {
            self.setSignaledAtomic(false);
        }
        return true; // 成功等到信号
    }
};

pub const Mutex = struct {
    header: ob.ObjectHeader = .{ .obj_type = .mutex },
    locked: bool = false,
    owner_tid: u32 = 0,
    recursion_count: u32 = 0,
    /// 本 mutex 上已安装一条「等待者 → 持有者」继承边（`beginMutexInheritance` 恰好一次）。
    inheritance_wait_edge: bool = false,

    pub fn init() Mutex {
        return .{
            .header = .{ .obj_type = .mutex },
            .locked = false,
            .owner_tid = 0,
            .recursion_count = 0,
        };
    }

    pub fn acquire(self: *Mutex, tid: u32) bool {
        if (self.locked and self.owner_tid == tid) {
            self.recursion_count += 1;
            return true;
        }
        if (self.locked) return false;
        self.locked = true;
        self.owner_tid = tid;
        self.recursion_count = 1;
        return true;
    }

    pub fn release(self: *Mutex, tid: u32) bool {
        if (!self.locked or self.owner_tid != tid) return false;
        self.recursion_count -= 1;
        if (self.recursion_count == 0) {
            const owner_snapshot = self.owner_tid;
            const had_edge = self.inheritance_wait_edge;
            self.owner_tid = 0;
            self.locked = false;
            if (had_edge) {
                self.inheritance_wait_edge = false;
                scheduler.endMutexInheritance(@intCast(owner_snapshot));
                // PI-02: 链式继承传播 — 如果释放者本身继承了其他互斥锁的优先级，
                // 需要把这个优先级也传播到当前锁的等待者（如果有的话）
                scheduler.propagateChainInheritance(@intCast(owner_snapshot));
            }
        }
        return true;
    }

    /// 与 `acquire` 相同，但若已被其他线程持有，则按等待者有效优先级抬升持有者（NT 式优先级继承的最小子集）。
    /// 注意：此函数不执行真正的等待，调用者应自行处理等待逻辑。
    pub fn acquireWithInheritance(self: *Mutex, tid: u32, waiter_tid: u32) bool {
        if (self.acquire(tid)) return true;
        // 获取失败：锁被其他线程持有，需要传播优先级继承
        const owner = self.owner_tid;
        // tid 和 waiter_tid 是不同角色：tid 是当前尝试获取者，waiter_tid 是等待该锁的线程
        const w_ep = scheduler.effectivePriorityForThread(@intCast(waiter_tid)) orelse 0;
        if (!self.inheritance_wait_edge) {
            self.inheritance_wait_edge = true;
            scheduler.beginMutexInheritance(@intCast(owner), w_ep);
        } else {
            scheduler.updateMutexInheritFloor(@intCast(owner), w_ep);
        }
        return false;
    }

    pub fn isSignaled(self: *const Mutex) bool {
        return !self.locked;
    }
};

pub const Semaphore = struct {
    header: ob.ObjectHeader = .{ .obj_type = .semaphore },
    count: i32 = 0,
    max_count: i32 = 1,

    pub fn init(initial: i32, max: i32) Semaphore {
        return .{
            .header = .{ .obj_type = .semaphore },
            .count = initial,
            .max_count = max,
        };
    }

    pub fn acquire(self: *Semaphore) bool {
        // 使用原子操作读取当前计数
        const current = @atomicLoad(i32, &self.count, .seq_cst);
        if (current <= 0) return false;
        // 使用原子操作尝试递减
        const new_val = @atomicRmw(i32, &self.count, .sub, 1, .seq_cst);
        // 如果递减前 <= 0，说明另一个线程已经取走了，撤销操作
        if (new_val <= 0) {
            @atomicStore(i32, &self.count, new_val, .seq_cst);
            return false;
        }
        return true;
    }

    pub fn release(self: *Semaphore) bool {
        // 使用原子操作读取当前计数
        const current = @atomicLoad(i32, &self.count, .seq_cst);
        if (current >= self.max_count) return false;
        // 使用原子操作尝试递增
        const new_val = @atomicRmw(i32, &self.count, .add, 1, .seq_cst);
        // 如果递增前 >= max_count，说明另一个线程已经达到了最大值，撤销操作
        if (new_val >= self.max_count) {
            @atomicStore(i32, &self.count, new_val, .seq_cst);
            return false;
        }
        return true;
    }

    pub fn isSignaled(self: *const Semaphore) bool {
        return @atomicLoad(i32, &self.count, .seq_cst) > 0;
    }
};

pub const SpinLock = struct {
    locked: bool = false,
    owner_tid: u32 = 0,
    recursion_count: u32 = 0,
    saved_if: bool = false,

    /// 获取自旋锁。如果当前线程已持有该锁则 panic（防止递归锁覆盖 saved_if）。
    pub fn acquire(self: *SpinLock) void {
        const tid = @as(u32, @intCast(scheduler.getCurrentThreadId()));
        // 检测递归锁：同一线程重复获取会导致 saved_if 被覆盖
        if (self.locked and self.owner_tid == tid) {
            @panic("SpinLock: recursive acquisition by same thread");
        }
        self.saved_if = arch.saveAndDisableInterrupts();
        self.locked = true;
        self.owner_tid = tid;
        self.recursion_count = 1;
    }

    /// 释放自旋锁。
    pub fn release(self: *SpinLock) void {
        const tid = @as(u32, @intCast(scheduler.getCurrentThreadId()));
        if (!self.locked or self.owner_tid != tid) {
            @panic("SpinLock: release by non-owner or unlocked");
        }
        self.recursion_count -= 1;
        if (self.recursion_count == 0) {
            self.owner_tid = 0;
            self.locked = false;
        }
        arch.restoreInterrupts(self.saved_if);
    }
};

/// NT 兼容临界区结构，支持用户态快速进入、递归获取、TryEnter 语义
pub const RTL_CRITICAL_SECTION = extern struct {
    header: ob.ObjectHeader = .{ .obj_type = .critical_section },
    lock_count: i32 = 0, // <0: 未锁定; 0: 已锁定无等待者; >0: 已锁定有等待者
    recursion_count: u32 = 0,
    owner_tid: u32 = 0,
    lock_sem: Semaphore = Semaphore.init(0, 1), // 等待者信号量
    spin_count: u32 = 4000, // 自旋次数，用户态自旋后进入等待

    pub fn init(spin_count: u32) RTL_CRITICAL_SECTION {
        return .{
            .header = .{ .obj_type = .critical_section },
            .lock_count = -1,
            .recursion_count = 0,
            .owner_tid = 0,
            .spin_count = spin_count,
            .lock_sem = Semaphore.init(0, 1),
        };
    }

    /// 尝试进入临界区，不阻塞
    pub fn tryEnter(self: *RTL_CRITICAL_SECTION) bool {
        const tid = @as(u32, @intCast(scheduler.getCurrentThreadId()));
        // 检查是否已持有锁（递归情况）
        if (self.owner_tid == tid) {
            self.recursion_count += 1;
            _ = @atomicRmw(i32, &self.lock_count, .add, 1, .seq_cst);
            return true;
        }
        // 尝试原子交换将lock_count从-1变为0
        const old = @atomicRmw(i32, &self.lock_count, .xchg, 0, .seq_cst);
        if (old == -1) {
            // 获取成功
            self.owner_tid = tid;
            self.recursion_count = 1;
            return true;
        }
        // 获取失败
        _ = @atomicRmw(i32, &self.lock_count, .add, 1, .seq_cst); // 回滚计数
        return false;
    }

    /// 进入临界区，阻塞直到获取成功
    pub fn enter(self: *RTL_CRITICAL_SECTION) void {
        if (self.tryEnter()) return;

        var spin_remaining = self.spin_count;

        // 自旋阶段
        while (spin_remaining > 0) {
            if (self.tryEnter()) return;
            spin_remaining -= 1;
            arch.spinCpuRelax();
        }

        // 自旋失败，进入等待
        while (!self.tryEnter()) {
            _ = self.lock_sem.acquire();
        }
    }

    /// 离开临界区
    pub fn leave(self: *RTL_CRITICAL_SECTION) bool {
        const tid = @as(u32, @intCast(scheduler.getCurrentThreadId()));
        if (self.owner_tid != tid) return false;

        self.recursion_count -= 1;
        const old_count = @atomicRmw(i32, &self.lock_count, .sub, 1, .seq_cst);

        if (self.recursion_count == 0) {
            // 完全释放锁
            self.owner_tid = 0;
            if (old_count > 0) {
                // 有等待者，唤醒一个
                _ = self.lock_sem.release();
            }
        }

        return true;
    }

    pub fn isSignaled(self: *const RTL_CRITICAL_SECTION) bool {
        return @atomicLoad(i32, &self.lock_count, .seq_cst) < 0;
    }
};
