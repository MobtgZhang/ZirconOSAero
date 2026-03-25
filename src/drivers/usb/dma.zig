//! USB DMA：identity 映射下将缓冲区标为非缓存，供 TRB / 设备上下文与设备 DMA 一致观测。
//! 参考 VirtIO `remapIdentityVirtPageUncached`（`mm/vm.zig`）。

const vm = @import("../../mm/vm.zig");

const PAGE: usize = 4096;

/// 将 `slice` 覆盖的每个 4KiB 页改为非缓存（内核 identity 映射）。
pub fn prepareDmaSlice(slice: []u8) void {
    if (slice.len == 0) return;
    var p = @intFromPtr(slice.ptr) & ~(PAGE - 1);
    const end = @intFromPtr(slice.ptr) + slice.len;
    while (p < end) : (p += PAGE) {
        _ = vm.remapIdentityVirtPageUncached(p);
    }
}

/// 内核虚址 → 设备可见物理地址（GPA）。
pub fn virtToPhys(virt: usize) u64 {
    return @truncate(vm.kernelVirtToPhys(virt));
}
