// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS Fence Synchronization

const std = @import("std");

// ============================================================================
// Fence State
// ============================================================================

pub const FenceState = enum {
    signaled,
    nonsignaled,
    abandoned,
};

// ============================================================================
// Fence Info
// ============================================================================

pub const FenceInfo = struct {
    id: u64,
    value: u64,
    state: FenceState,
    submitted_commands: u64,
};

// ============================================================================
// Fence Manager
// ============================================================================

pub const MAX_FENCES: usize = 256;

pub const FenceManager = struct {
    fences: [MAX_FENCES]?FenceInfo,
    fence_count: usize,
    next_fence_id: u64,
    next_fence_value: u64,
    completed_value: u64,

    pub fn init(self: *FenceManager) void {
        self.fence_count = 0;
        self.next_fence_id = 1;
        self.next_fence_value = 1;
        self.completed_value = 0;
    }

    pub fn createFence(self: *FenceManager) u64 {
        if (self.fence_count >= MAX_FENCES) return 0;

        const id = self.next_fence_id;
        self.next_fence_id += 1;

        self.fences[self.fence_count] = .{
            .id = id,
            .value = self.next_fence_value,
            .state = .nonsignaled,
            .submitted_commands = 0,
        };

        self.fence_count += 1;
        return id;
    }

    pub fn signal(self: *FenceManager, id: u64, value: u64) void {
        for (self.fences[0..self.fence_count]) |*fence| {
            if (fence.*) |*f| {
                if (f.id == id) {
                    f.state = .signaled;
                    f.value = value;
                    if (value > self.completed_value) {
                        self.completed_value = value;
                    }
                    return;
                }
            }
        }
    }

    pub fn getFenceState(self: *const FenceManager, id: u64) ?FenceState {
        for (self.fences[0..self.fence_count]) |fence| {
            if (fence) |f| {
                if (f.id == id) {
                    return f.state;
                }
            }
        }
        return null;
    }

    pub fn isCompleted(self: *const FenceManager, id: u64) bool {
        for (self.fences[0..self.fence_count]) |fence| {
            if (fence) |f| {
                if (f.id == id) {
                    return f.state == .signaled;
                }
            }
        }
        return true;
    }

    pub fn waitForFence(self: *FenceManager, id: u64, timeout_ms: u32) bool {
        _ = timeout_ms;

        // Simple spin wait (in real implementation, would use proper synchronization)
        var attempts: u32 = 0;
        while (attempts < 1000) : (attempts += 1) {
            if (self.isCompleted(id)) return true;
        }
        return self.isCompleted(id);
    }

    pub fn getCompletedValue(self: *const FenceManager) u64 {
        return self.completed_value;
    }

    pub fn advanceCompletedValue(self: *FenceManager) void {
        self.completed_value = self.next_fence_value;
        self.next_fence_value += 1;
    }
};

// ============================================================================
// Global Fence Manager
// ============================================================================

pub var g_fence_manager: FenceManager = .{};

pub fn initFenceManager() void {
    g_fence_manager.init();
}

pub fn createFence() u64 {
    return g_fence_manager.createFence();
}

pub fn signalFence(id: u64, value: u64) void {
    g_fence_manager.signal(id, value);
}

pub fn isFenceCompleted(id: u64) bool {
    return g_fence_manager.isCompleted(id);
}

pub fn waitForFence(id: u64, timeout_ms: u32) bool {
    return g_fence_manager.waitForFence(id, timeout_ms);
}

pub fn getLastCompletedValue() u64 {
    return g_fence_manager.getCompletedValue();
}
