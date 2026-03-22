//! Kernel Synchronization Primitives
//! Event, Mutex, Semaphore, SpinLock

const ob = @import("../ob/object.zig");

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
            self.owner_tid = 0;
            self.locked = false;
        }
        return true;
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
