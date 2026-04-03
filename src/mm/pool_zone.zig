// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/pool_zone.zig
// Purpose: 内核池 **zone**：按页向 backing 申请连续物理/虚拟页并切片为固定档位块；区分 NonPaged / Paged **统计与将来 VA 布局**（阶段一可与堆共用后备）。
//
// This is an independent clean-room implementation.
// Ref: WDK — Pool Types / lookaside (public behavioral descriptions only).

const heap = @import("heap.zig");

/// 文档化：将来 NonPagedPool 独占内核虚拟窗（与 `heap.KERNEL_HEAP_VIRT_BASE` 分离）。
pub const KERNEL_NONPAGED_POOL_HINT_VIRT: u64 = 0xC100_0000;
/// 文档化：将来 PagedPool 独占窗（接分页器后可修剪）；阶段一仅统计区分。
pub const KERNEL_PAGED_POOL_HINT_VIRT: u64 = 0xC200_0000;

pub const ZonePoolKind = enum(u8) {
    non_paged = 0,
    paged = 1,
};

const PAGE: usize = 4096;

var backing_alloc: ?*const fn (usize, usize) ?[*]u8 = null;
var backing_free: ?*const fn ([*]u8, usize, usize) void = null;

/// 内核启动后可将 zone 页接到 `vm.mapPageAlloc` 等；未设置时退回 `heap`。
pub fn setZoneBackingHooks(
    alloc: *const fn (usize, usize) ?[*]u8,
    free: *const fn ([*]u8, usize, usize) void,
) void {
    backing_alloc = alloc;
    backing_free = free;
}

var nonpaged_zone_pages: usize = 0;
var paged_zone_pages: usize = 0;

pub fn nonpagedZonePagesForDebug() usize {
    return nonpaged_zone_pages;
}

pub fn pagedZonePagesForDebug() usize {
    return paged_zone_pages;
}

fn noteZonePage(kind: ZonePoolKind) void {
    switch (kind) {
        .non_paged => nonpaged_zone_pages += 1,
        .paged => paged_zone_pages += 1,
    }
}

/// 申请一页供池切片；`align` 至少为 `FreeNode` 对齐。
pub fn allocZonePage(kind: ZonePoolKind, alignment: usize) ?[*]u8 {
    const a = @max(alignment, @as(usize, 16));
    if (backing_alloc) |ba| {
        const p = ba(PAGE, a) orelse return null;
        noteZonePage(kind);
        return p;
    }
    const p = heap.alloc(PAGE, a) orelse return null;
    noteZonePage(kind);
    return p;
}

pub fn freeZonePage(ptr: [*]u8, alignment: usize) void {
    if (backing_free) |bf| {
        bf(ptr, PAGE, alignment);
    } else {
        heap.free(ptr, PAGE, alignment);
    }
}
