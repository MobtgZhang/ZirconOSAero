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

// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/ex_pool.zig
// Purpose: `ExAllocatePoolWithTag` / `ExFreePoolWithTag` 语义子集的薄封装，统一内核与驱动的池分配入口（实现委托 `pool.zig`）。
//
// This is an independent clean-room implementation.
// Ref: WDK — ExAllocatePoolWithTag / ExFreePoolWithTag (public behavior names only).
//
// ## 分配路径全景（阶段 A 文档锚点）
//
// 1. `exAllocatePoolWithTag` / `exFreePoolWithTag` / **`exReallocatePoolWithTag`** → `pool.allocateNonPaged` / `pool.freeNonPaged` / `pool.reallocateNonPaged`
//    （NonPagedPool；≤512B 档位优先 **per-CPU lookaside**，否则 **全局档位链**，再大则 **`heap.zig` 空闲链表**）。
// 2. `exAllocatePoolWithTagType(.paged)` / `exFreePoolWithTagType(.paged)` → `pool.allocatePaged` / `pool.freePaged`
//    （须 **APC_LEVEL 以下**：`setPagedPoolIrqlGuard`；Paged 可与 NonPaged 共用 zone 页，**无真换出**；可选 **软上限** 见 `pool.setPagedPoolSoftLimitForTest`）。
// 3. `heap.zig`：可增长 arena（`heap_boot` 接线后）+ bump 快路径 + 地址有序空闲链表合并。
// 4. Tag 调试统计：`pool.copyTagStats`（槽满后新 tag 静默不记入，见 `pool.zig`）。
//
// IRQL（与 WDK 描述对齐的子集）：
// - `exAllocatePoolWithTag` / `free`：走 **NonPagedPool** 路径，须在 **DISPATCH_LEVEL 及以下** 使用（本内核由 `pool` 自旋风格锁保证）。
// - `exAllocatePoolWithTagType(.paged)`：须 **APC_LEVEL 以下**；由 `main` 注册的 `setPagedPoolIrqlGuard` 在违规时断言（占位换出未接真分页池）。

const pool = @import("pool.zig");

/// 默认无操作；内核启动后由 `main.zig` 注册为 `ke/irql.assertBelowDispatchForPagedPool`，
/// 避免 `ex_pool` 直接 `@import("ke/irql")` 导致 `zig test src/mm/slab.zig` 模块路径失败。
var paged_pool_irql_guard: *const fn () void = struct {
    fn noop() void {}
}.noop;

pub fn setPagedPoolIrqlGuard(guard: *const fn () void) void {
    paged_pool_irql_guard = guard;
}

fn assertPagedPoolIrqlOk() void {
    paged_pool_irql_guard();
}

/// 非分页池分配；`tag` 参与调试统计（见 `pool.zig`）。
pub fn exAllocatePoolWithTag(size: usize, tag: u32) ?[*]u8 {
    return pool.allocateNonPaged(size, tag);
}

pub fn exFreePoolWithTag(ptr: [*]u8, size: usize, tag: u32) void {
    pool.freeNonPaged(ptr, size, tag);
}

/// 显式池类型：`PagedPool` 经 `setPagedPoolIrqlGuard` 注册的回调断言 IRQL（内核默认注册 `ke/irql`）。
pub fn exAllocatePoolWithTagType(size: usize, tag: u32, pool_type: pool.PoolType) ?[*]u8 {
    return switch (pool_type) {
        .non_paged => pool.allocateNonPaged(size, tag),
        .paged => blk: {
            assertPagedPoolIrqlOk();
            break :blk pool.allocatePaged(size, tag);
        },
    };
}

pub fn exFreePoolWithTagType(ptr: [*]u8, size: usize, tag: u32, pool_type: pool.PoolType) void {
    switch (pool_type) {
        .non_paged => pool.freeNonPaged(ptr, size, tag),
        .paged => pool.freePaged(ptr, size, tag),
    }
}

/// 非分页池变长；`tag` 参与统计（先 `allocate` 后 `free` 旧块）。
pub fn exReallocatePoolWithTag(ptr: [*]u8, old_size: usize, new_size: usize, tag: u32) ?[*]u8 {
    return pool.reallocateNonPaged(ptr, old_size, new_size, tag);
}

pub fn exReallocatePoolWithTagType(ptr: [*]u8, old_size: usize, new_size: usize, tag: u32, pool_type: pool.PoolType) ?[*]u8 {
    return switch (pool_type) {
        .non_paged => pool.reallocateNonPaged(ptr, old_size, new_size, tag),
        .paged => blk: {
            assertPagedPoolIrqlOk();
            break :blk pool.reallocatePaged(ptr, old_size, new_size, tag);
        },
    };
}
