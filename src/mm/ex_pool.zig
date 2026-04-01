// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/ex_pool.zig
// Purpose: `ExAllocatePoolWithTag` / `ExFreePoolWithTag` 语义子集的薄封装，统一内核与驱动的池分配入口（实现委托 `pool.zig`）。
//
// This is an independent clean-room implementation.
// Ref: WDK — ExAllocatePoolWithTag / ExFreePoolWithTag (public behavior names only).

const pool = @import("pool.zig");

/// 非分页池分配；`tag` 参与调试统计（见 `pool.zig`）。
pub fn exAllocatePoolWithTag(size: usize, tag: u32) ?[*]u8 {
    return pool.allocateNonPaged(size, tag);
}

pub fn exFreePoolWithTag(ptr: [*]u8, size: usize, tag: u32) void {
    pool.freeNonPaged(ptr, size, tag);
}
