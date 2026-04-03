// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/drivers/video/gpu_device.zig
// Purpose: Abstract display backend (ramfb vs future VirtIO-GPU 2D); scalar-only pixel paths.
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Reference: https://docs.oasis-open.org/virtio/virtio-v1.2-csd01/virtio-v1.2-csd01.html (VirtIO-GPU)

const std = @import("std");

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const SurfaceHandle = usize;

/// VTable for kernel display backends (Phase B scaffold).
pub const VTable = struct {
    create_surface: *const fn (ctx: *anyopaque, w: u32, h: u32) SurfaceHandle,
    flush_rect: *const fn (ctx: *anyopaque, surf: SurfaceHandle, rect: Rect) void,
    destroy_surface: *const fn (ctx: *anyopaque, surf: SurfaceHandle) void,
};

pub const GpuDevice = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn createSurface(self: GpuDevice, w: u32, h: u32) SurfaceHandle {
        return self.vtable.create_surface(self.ctx, w, h);
    }

    pub fn flushRect(self: GpuDevice, surf: SurfaceHandle, rect: Rect) void {
        self.vtable.flush_rect(self.ctx, surf, rect);
    }

    pub fn destroySurface(self: GpuDevice, surf: SurfaceHandle) void {
        self.vtable.destroy_surface(self.ctx, surf);
    }
};

var ramfb_stub_next: SurfaceHandle = 1;

fn ramfbCreateSurface(ctx: *anyopaque, w: u32, h: u32) SurfaceHandle {
    _ = ctx;
    _ = w;
    _ = h;
    const hnd = ramfb_stub_next;
    ramfb_stub_next +|= 1;
    return hnd;
}

fn ramfbFlushRect(ctx: *anyopaque, surf: SurfaceHandle, rect: Rect) void {
    _ = ctx;
    _ = surf;
    _ = rect;
}

fn ramfbDestroySurface(ctx: *anyopaque, surf: SurfaceHandle) void {
    _ = ctx;
    _ = surf;
}

const ramfb_vtable = VTable{
    .create_surface = ramfbCreateSurface,
    .flush_rect = ramfbFlushRect,
    .destroy_surface = ramfbDestroySurface,
};

var ramfb_ctx_state: u8 = 0;

/// Placeholder backend until VirtIO-GPU commands drive `GpuDevice` (see `virtio_gpu_spec.zig` / `virtio_gpu_pci.zig`).
pub fn ramfbStubDevice() GpuDevice {
    return .{
        .ctx = @ptrCast(&ramfb_ctx_state),
        .vtable = &ramfb_vtable,
    };
}

test "GpuDevice ramfb stub returns handles" {
    var dev = ramfbStubDevice();
    const a = dev.createSurface(64, 64);
    const b = dev.createSurface(32, 32);
    try std.testing.expect(a != b);
    dev.flushRect(a, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    dev.destroySurface(a);
}
