// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// ZirconOS Video Memory Manager (VidMM)
//! Manages GPU video memory allocation and deallocation.

const std = @import("std");

// ============================================================================
// Memory Types
// ============================================================================

pub const MemoryType = enum {
    video_local,
    video_system,
    video_shared,
};

// ============================================================================
// Allocation Types
// ============================================================================

pub const AllocationType = enum {
    surface,
    buffer,
    shader,
    temporary,
};

// ============================================================================
// Memory Segment
// ============================================================================

pub const MemorySegment = struct {
    base: usize,
    size: usize,
    used: usize,
    memory_type: MemoryType,
};

// ============================================================================
// Allocation Info
// ============================================================================

pub const AllocationInfo = struct {
    id: u64,
    segment: usize,
    offset: usize,
    size: usize,
    allocation_type: AllocationType,
    committed: bool,
    protected: bool,
};

// ============================================================================
// Video Memory Manager
// ============================================================================

pub const MAX_SEGMENTS: usize = 4;
pub const MAX_ALLOCATIONS: usize = 1024;

pub const VideoMemoryManager = struct {
    segments: [MAX_SEGMENTS]?MemorySegment,
    segment_count: usize,
    allocations: [MAX_ALLOCATIONS]?AllocationInfo,
    allocation_count: usize,
    next_allocation_id: u64,

    pub fn init(self: *VideoMemoryManager) void {
        self.segment_count = 0;
        self.allocation_count = 0;
        self.next_allocation_id = 1;
    }

    pub fn addSegment(self: *VideoMemoryManager, base: usize, size: usize, mem_type: MemoryType) void {
        if (self.segment_count >= MAX_SEGMENTS) return;
        self.segments[self.segment_count] = .{
            .base = base,
            .size = size,
            .used = 0,
            .memory_type = mem_type,
        };
        self.segment_count += 1;
    }

    pub fn allocate(self: *VideoMemoryManager, size: usize, alignment: usize, alloc_type: AllocationType) ?AllocationInfo {
        if (self.allocation_count >= MAX_ALLOCATIONS) return null;

        // Find segment with enough space
        for (self.segments[0..self.segment_count]) |*seg| {
            if (seg.*) |*s| {
                const aligned_offset = (s.used + alignment - 1) & ~(alignment - 1);
                if (aligned_offset + size <= s.size) {
                    const info: AllocationInfo = .{
                        .id = self.next_allocation_id,
                        .segment = @intFromPtr(seg),
                        .offset = aligned_offset,
                        .size = size,
                        .allocation_type = alloc_type,
                        .committed = true,
                        .protected = false,
                    };

                    self.next_allocation_id += 1;
                    s.used = aligned_offset + size;

                    self.allocations[self.allocation_count] = info;
                    self.allocation_count += 1;

                    return info;
                }
            }
        }

        return null;
    }

    pub fn free(self: *VideoMemoryManager, id: u64) bool {
        for (self.allocations[0..self.allocation_count]) |*alloc| {
            if (alloc.*) |a| {
                if (a.id == id) {
                    // Mark segment as freed (simplified)
                    alloc.* = null;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn getAllocation(self: *VideoMemoryManager, id: u64) ?*AllocationInfo {
        for (self.allocations[0..self.allocation_count]) |*alloc| {
            if (alloc.*) |a| {
                if (a.id == id) return alloc;
            }
        }
        return null;
    }

    pub fn getTotalUsed(self: *const VideoMemoryManager) usize {
        var total: usize = 0;
        for (self.segments[0..self.segment_count]) |seg| {
            if (seg) |s| {
                total += s.used;
            }
        }
        return total;
    }

    pub fn getTotalSize(self: *const VideoMemoryManager) usize {
        var total: usize = 0;
        for (self.segments[0..self.segment_count]) |seg| {
            if (seg) |s| {
                total += s.size;
            }
        }
        return total;
    }
};

// ============================================================================
// Global VidMM
// ============================================================================

pub var g_vidmm: VideoMemoryManager = .{};

pub fn initVidMM() void {
    g_vidmm.init();
}

pub fn allocateVideoMemory(size: usize, alignment: usize, alloc_type: AllocationType) ?AllocationInfo {
    return g_vidmm.allocate(size, alignment, alloc_type);
}

pub fn freeVideoMemory(id: u64) bool {
    return g_vidmm.free(id);
}

pub fn getAllocationInfo(id: u64) ?*AllocationInfo {
    return g_vidmm.getAllocation(id);
}

pub fn getMemoryStats() struct { used: usize, total: usize, available: usize } {
    const total = g_vidmm.getTotalSize();
    const used = g_vidmm.getTotalUsed();
    return .{
        .used = used,
        .total = total,
        .available = total - used,
    };
}
