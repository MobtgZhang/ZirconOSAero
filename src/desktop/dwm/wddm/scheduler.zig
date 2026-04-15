// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS GPU Scheduler

const std = @import("std");

// ============================================================================
// Priority Levels
// ============================================================================

pub const PriorityLevel = enum(i32) {
    priority_low = -1,
    priority_normal = 0,
    priority_high = 1,
    priority_critical = 2,
};

// ============================================================================
// GPU Command Packet
// ============================================================================

pub const CommandPacket = struct {
    id: u64,
    priority: PriorityLevel,
    submission_id: u64,
    fence_id: u64,
    fence_value: u64,
    estimated_time_us: u64,
};

// ============================================================================
// GPU Queue
// ============================================================================

pub const MAX_QUEUE_SIZE: usize = 256;

pub const GPUQueue = struct {
    packets: [MAX_QUEUE_SIZE]?CommandPacket,
    count: usize,
    head: usize,
    tail: usize,

    pub fn init(self: *GPUQueue) void {
        self.count = 0;
        self.head = 0;
        self.tail = 0;
    }

    pub fn enqueue(self: *GPUQueue, packet: CommandPacket) bool {
        if (self.count >= MAX_QUEUE_SIZE) return false;
        self.packets[self.tail] = packet;
        self.tail = (self.tail + 1) % MAX_QUEUE_SIZE;
        self.count += 1;
        return true;
    }

    pub fn dequeue(self: *GPUQueue) ?CommandPacket {
        if (self.count == 0) return null;
        const packet = self.packets[self.head];
        self.head = (self.head + 1) % MAX_QUEUE_SIZE;
        self.count -= 1;
        return packet;
    }

    pub fn isEmpty(self: *const GPUQueue) bool {
        return self.count == 0;
    }

    pub fn isFull(self: *const GPUQueue) bool {
        return self.count >= MAX_QUEUE_SIZE;
    }
};

// ============================================================================
// GPU Scheduler
// ============================================================================

pub const GPUScheduler = struct {
    queues: [4]GPUQueue,
    active_priority: PriorityLevel,
    running: bool,
    total_scheduled: u64,

    pub fn init(self: *GPUScheduler) void {
        self.running = false;
        self.total_scheduled = 0;
        self.active_priority = .priority_normal;

        var i: usize = 0;
        while (i < 4) : (i += 1) {
            self.queues[i].init();
        }
    }

    pub fn start(self: *GPUScheduler) void {
        self.running = true;
    }

    pub fn stop(self: *GPUScheduler) void {
        self.running = false;
    }

    pub fn submit(self: *GPUScheduler, priority: PriorityLevel, packet: CommandPacket) bool {
        const queue_idx = @as(i32, @intFromEnum(priority)) + 2;
        const idx: usize = @intCast(@as(i32, @max(0, @min(3, queue_idx))));
        return self.queues[idx].enqueue(packet);
    }

    pub fn scheduleNext(self: *GPUScheduler) ?CommandPacket {
        if (!self.running) return null;

        // Check from highest to lowest priority
        var i: i32 = 3;
        while (i >= 0) : (i -= 1) {
            if (!self.queues[@as(usize, @intCast(i))].isEmpty()) {
                const packet = self.queues[@as(usize, @intCast(i))].dequeue();
                if (packet) |p| {
                    self.total_scheduled += 1;
                    return p;
                }
            }
        }

        return null;
    }

    pub fn getQueueDepth(self: *const GPUScheduler) struct { low: usize, normal: usize, high: usize, critical: usize } {
        return .{
            .low = self.queues[0].count,
            .normal = self.queues[1].count,
            .high = self.queues[2].count,
            .critical = self.queues[3].count,
        };
    }
};

// ============================================================================
// Global GPU Scheduler
// ============================================================================

pub var g_gpu_scheduler: GPUScheduler = .{};

pub fn initGPUScheduler() void {
    g_gpu_scheduler.init();
}

pub fn startScheduler() void {
    g_gpu_scheduler.start();
}

pub fn stopScheduler() void {
    g_gpu_scheduler.stop();
}

pub fn submitCommand(priority: PriorityLevel, id: u64, fence_id: u64, fence_value: u64) bool {
    const packet: CommandPacket = .{
        .id = id,
        .priority = priority,
        .submission_id = id,
        .fence_id = fence_id,
        .fence_value = fence_value,
        .estimated_time_us = 100,
    };
    return g_gpu_scheduler.submit(priority, packet);
}

pub fn scheduleNextCommand() ?CommandPacket {
    return g_gpu_scheduler.scheduleNext();
}

pub fn getSchedulerStats() struct { total: u64, queues: struct { low: usize, normal: usize, high: usize, critical: usize } } {
    return .{
        .total = g_gpu_scheduler.total_scheduled,
        .queues = g_gpu_scheduler.getQueueDepth(),
    };
}
