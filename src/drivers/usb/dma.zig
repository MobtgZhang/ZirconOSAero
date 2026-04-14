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
