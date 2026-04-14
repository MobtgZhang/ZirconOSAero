// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/heap_boot.zig
// Purpose: 在 `vm.bindKernelAddressSpace` 之后将 `heap.zig` 接到 `AddressSpace.mapPageAlloc`；避免 `heap.zig` 直接依赖 `vm.zig` 以便主机单测。
//
// This is an independent clean-room implementation.
// Reference: MS Learn — virtual memory commit (behavioral only).

const std = @import("std");
const arch = @import("../arch.zig");
const heap = @import("heap.zig");
const vm = @import("vm.zig");
const klog = @import("../rtl/klog.zig");

pub fn kernelMapRange(ctx: *anyopaque, virt_lo: usize, byte_len: usize) bool {
    if (byte_len == 0) return true;
    const sp: *vm.AddressSpace = @ptrCast(@alignCast(ctx));
    const ps = arch.impl.paging.page_size;
    if (byte_len % ps != 0) return false;
    klog.info("Heap: mapping 0x%x + 0x%x bytes (0x%x pages)", .{ virt_lo, byte_len, byte_len / ps });
    arch.flushDebugSerialOutput();
    var off: usize = 0;
    while (off < byte_len) : (off += ps) {
        if (sp.mapPageAlloc(virt_lo + off, .{ .writable = true, .executable = false, .no_cache = false }) == null)
            return false;
    }
    return true;
}

/// `max_size_kb` 来自配置 `memory.heap_size_kb`；上限 512MiB 以免虚址窗口失控。
pub fn initKernelHeapAfterVm(space: *vm.AddressSpace, max_size_kb: u32) void {
    klog.info("Heap init: max_kb=%u", .{max_size_kb});
    const ps = arch.impl.paging.page_size;
    const max_bytes_u64 = @as(u64, @intCast(max_size_kb)) * 1024;
    const cap_u64 = @min(
        @as(u64, 512) * 1024 * 1024,
        @max(@as(u64, 512 * 1024), max_bytes_u64),
    );
    const cap: usize = if (cap_u64 > std.math.maxInt(usize))
        std.math.maxInt(usize)
    else
        @intCast(cap_u64);
    const capacity = std.mem.alignBackward(usize, cap, ps);
    klog.info("Heap init: cap=%u bytes (%.1f MiB)", .{ capacity, @as(f64, @floatFromInt(capacity)) / 1024.0 / 1024.0 });
    if (capacity < 512 * 1024) {
        klog.info("Heap init: capacity too small (<512KB), using static fallback", .{});
        heap.init();
        return;
    }
    const initial_target = @min(capacity, 512 * 1024);
    const initial_commit = std.mem.alignForward(usize, initial_target, ps);
    klog.info("Heap init: initial_commit=%u bytes", .{initial_commit});
    arch.flushDebugSerialOutput();
    if (heap.initGrowable(.{
        .base_virt = heap.KERNEL_HEAP_VIRT_BASE,
        .capacity = capacity,
        .initial_commit = initial_commit,
        .page_size = ps,
        .map_ctx = @ptrCast(space),
        .map_range = kernelMapRange,
    })) {
        klog.info("Heap init: growable succeeded", .{});
        return;
    }
    klog.info("Heap init: growable failed, using static fallback", .{});
    heap.init();
}
