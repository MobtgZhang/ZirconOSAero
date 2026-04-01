//! Kernel Synchronization Primitives
//! Event, Mutex, Semaphore, SpinLock
//!
//! Mutex `acquireWithInheritance` / `release` 与 `ke/scheduler.zig` 的 `mutex_inherit_floor` 联动；
//! 多互斥同时持有时当前实现仅在**最后一次 release** 清零继承（限制见 `release` 注释）。

const ob = @import("../ob/object.zig");
const scheduler = @import("scheduler.zig");

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
        self.signaled = true;
    }

    pub fn reset(self: *Event) void {
        self.signaled = false;
    }

    pub fn isSignaled(self: *const Event) bool {
        return self.signaled;
    }

    pub fn wait(self: *Event) void {
        while (!self.signaled) {
            asm volatile ("pause");
        }
        if (self.auto_reset) {
            self.signaled = false;
        }
    }
};

pub const Mutex = struct {
    header: ob.ObjectHeader = .{ .obj_type = .mutex },
    locked: bool = false,
    owner_tid: u32 = 0,
    recursion_count: u32 = 0,

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
            const owner = self.owner_tid;
            self.owner_tid = 0;
            self.locked = false;
            // 单互斥/顺序持锁场景足够；多互斥并行时需按持锁集合重算 floor（未实现）。
            scheduler.clearMutexInheritFloor(@intCast(owner));
        }
        return true;
    }

    /// 与 `acquire` 相同，但若已被其他线程持有，则按等待者有效优先级抬升持有者（NT 式优先级继承的最小子集）。
    pub fn acquireWithInheritance(self: *Mutex, tid: u32, waiter_tid: u32) bool {
        if (self.acquire(tid)) return true;
        if (!self.locked) return false;
        const owner = self.owner_tid;
        if (owner == tid) return true;
        const w_ep = scheduler.effectivePriorityForThread(@intCast(waiter_tid)) orelse 0;
        scheduler.applyMutexInheritFloor(@intCast(owner), w_ep);
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
        if (self.count <= 0) return false;
        self.count -= 1;
        return true;
    }

    pub fn release(self: *Semaphore) bool {
        if (self.count >= self.max_count) return false;
        self.count += 1;
        return true;
    }

    pub fn isSignaled(self: *const Semaphore) bool {
        return self.count > 0;
    }
};

pub const SpinLock = struct {
    locked: bool = false,

    pub fn acquire(self: *SpinLock) void {
        asm volatile ("cli");
        self.locked = true;
    }

    pub fn release(self: *SpinLock) void {
        self.locked = false;
        asm volatile ("sti");
    }
};
