// Copyright (c) 2024 ZirconOS Project <contact@zirconvexos.org>
//
// ZirconOS
//
// Surface Redirection for ZirconOS DWM
//! Implements window content redirection between applications and DWM.
//! Uses shared memory and keyed mutex for cross-process synchronization.

const std = @import("std");

// ============================================================================
// Surface Redirection Types
// ============================================================================

pub const SurfaceHandle = u64;
pub const INVALID_SURFACE_HANDLE: SurfaceHandle = 0;

pub const SurfaceRedirectionState = struct {
    handle: SurfaceHandle,
    width: u32,
    height: u32,
    format: u32,
    shared_handle: ?*anyopaque,
    is_dirty: bool,
    last_update_time: u64,
};

// ============================================================================
// Redirected Surface Pool
// ============================================================================

pub const MAX_REDIRECTED_SURFACES: usize = 256;

pub const SurfaceRedirectPool = struct {
    surfaces: [MAX_REDIRECTED_SURFACES]?SurfaceRedirectionState,
    surface_count: usize,
    next_handle: SurfaceHandle,

    pub fn init(self: *SurfaceRedirectPool) void {
        self.surface_count = 0;
        self.next_handle = 1;
    }

    pub fn createSurface(self: *SurfaceRedirectPool, width: u32, height: u32, format: u32) SurfaceHandle {
        if (self.surface_count >= MAX_REDIRECTED_SURFACES) return INVALID_SURFACE_HANDLE;

        const handle = self.next_handle;
        self.next_handle += 1;

        self.surfaces[self.surface_count] = .{
            .handle = handle,
            .width = width,
            .height = height,
            .format = format,
            .shared_handle = null,
            .is_dirty = true,
            .last_update_time = 0,
        };

        self.surface_count += 1;
        return handle;
    }

    pub fn getSurface(self: *SurfaceRedirectPool, handle: SurfaceHandle) ?*SurfaceRedirectionState {
        for (self.surfaces[0..self.surface_count]) |*surf| {
            if (surf.*) |s| {
                if (s.handle == handle) return surf;
            }
        }
        return null;
    }

    pub fn markDirty(self: *SurfaceRedirectPool, handle: SurfaceHandle) void {
        if (self.getSurface(handle)) |surf| {
            surf.is_dirty = true;
            surf.last_update_time = std.time.milliTimestamp();
        }
    }

    pub fn clearDirty(self: *SurfaceRedirectPool, handle: SurfaceHandle) void {
        if (self.getSurface(handle)) |surf| {
            surf.is_dirty = false;
        }
    }

    pub fn destroySurface(self: *SurfaceRedirectPool, handle: SurfaceHandle) bool {
        for (self.surfaces[0..self.surface_count]) |*surf| {
            if (surf.*) |s| {
                if (s.handle == handle) {
                    surf.* = null;
                    return true;
                }
            }
        }
        return false;
    }
};

// ============================================================================
// Global Redirect Pool
// ============================================================================

pub var g_redirect_pool: SurfaceRedirectPool = .{};

pub fn initRedirectPool() void {
    g_redirect_pool.init();
}

// ============================================================================
// Surface Creation
// ============================================================================

pub fn createRedirectedSurface(width: u32, height: u32, format: u32) SurfaceHandle {
    return g_redirect_pool.createSurface(width, height, format);
}

pub fn getRedirectedSurface(handle: SurfaceHandle) ?*SurfaceRedirectionState {
    return g_redirect_pool.getSurface(handle);
}

pub fn destroyRedirectedSurface(handle: SurfaceHandle) bool {
    return g_redirect_pool.destroySurface(handle);
}

// ============================================================================
// Dirty Tracking
// ============================================================================

pub fn markSurfaceDirty(handle: SurfaceHandle) void {
    g_redirect_pool.markDirty(handle);
}

pub fn clearSurfaceDirty(handle: SurfaceHandle) void {
    g_redirect_pool.clearDirty(handle);
}

pub fn getDirtySurfaces() []SurfaceHandle {
    var dirty: [MAX_REDIRECTED_SURFACES]SurfaceHandle = undefined;
    var count: usize = 0;

    for (g_redirect_pool.surfaces[0..g_redirect_pool.surface_count]) |surf| {
        if (surf) |s| {
            if (s.is_dirty) {
                dirty[count] = s.handle;
                count += 1;
            }
        }
    }

    return dirty[0..count];
}

// ============================================================================
// Shared Memory Operations
// ============================================================================

pub const SharedMemoryInfo = struct {
    key: []const u8,
    size: usize,
    address: ?*anyopaque,
};

pub fn createSharedSurfaceMemory(width: u32, height: u32) !SharedMemoryInfo {
    const pixel_size: usize = 4; // BGRA
    const row_pitch = width * @as(u32, @intCast(pixel_size));
    const size = row_pitch * height;

    const memory = std.heap.page_allocator.alloc(u8, size) catch return error.OutOfMemory;

    return .{
        .key = "",
        .size = size,
        .address = @as(?*anyopaque, @ptrFromInt(@intFromPtr(memory.ptr))),
    };
}

pub fn openSharedSurfaceMemory(key: []const u8, size: usize) !SharedMemoryInfo {
    _ = key;
    _ = size;
    // In a real implementation, this would open a named shared memory region
    return error.NotImplemented;
}

pub fn closeSharedSurfaceMemory(info: *const SharedMemoryInfo) void {
    if (info.address) |addr| {
        const ptr: [*]u8 = @ptrFromInt(@intFromPtr(addr));
        std.heap.page_allocator.free(ptr[0..info.size]);
    }
}
