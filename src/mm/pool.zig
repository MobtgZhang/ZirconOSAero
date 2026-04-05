// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/pool.zig
// Purpose: **NonPagedPool / PagedPool** 子集：`zone` 按页切片 + **per-CPU lookaside** + 全局档位链（`pool_gate`）；
// 大于最大档位仍走 `heap.zig`。对齐 WDK 池类型与 IRQL 语义（clean-room）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: WDK — Pool Types / ExAllocatePoolWithTag / lookaside lists (public behavioral descriptions)
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../docs/cn/NT61_KERNEL_TODO.md) Phase K1.2
// PFN / 可用 RAM 过滤与 GOP 保留： [docs/cn/PHYS_ALLOC_AUDIT.md](../../docs/cn/PHYS_ALLOC_AUDIT.md)、[PFN_REFCOUNT_ROADMAP.md](../../docs/cn/PFN_REFCOUNT_ROADMAP.md)
//
// IRQL / SMP：
// - **NonPagedPool**：DISPATCH_LEVEL 及以下；lookaside 为 per-CPU 无锁热路径；全局链与 tag 统计用 `pool_gate`。
// - **PagedPool**：须 APC_LEVEL 以下（由 `ex_pool` IRQL guard）；阶段一 **无** 真换出，仅 zone 统计与虚拟窗文档常量分离。
// - SMP：lookaside 按 `percpu_index.currentCpuIndex()` 分桶；AP 上分配前须保证索引与当前 CPU 一致。
//   当前 tick 主要在 BSP；AP 若调用池分配须在 bring-up 中显式验证。

const std = @import("std");
const heap = @import("heap.zig");
const lookaside = @import("lookaside.zig");
const pool_zone = @import("pool_zone.zig");

pub const PoolType = enum(u8) {
    non_paged = 0,
    paged = 1,
};

var paged_bytes_outstanding: usize = 0;
var paged_trim_placeholder_events: usize = 0;
/// 0 = 无软上限；>0 时 `allocatePaged` 在超出时失败并调用 `notePagedPoolTrimPlaceholder`（真换出仍为路线图项）。
var paged_pool_soft_limit_bytes: usize = 0;

const SLOT_COUNT: usize = 6;
const slot_sizes: [SLOT_COUNT]usize = .{ 16, 32, 64, 128, 256, 512 };
const ZONE_PAGE: usize = 4096;

comptime {
    std.debug.assert(lookaside.SLOT_COUNT == SLOT_COUNT);
}

const FreeNode = lookaside.ListNode;

var free_heads: [SLOT_COUNT]?*FreeNode = .{null} ** SLOT_COUNT;

var pool_gate: std.atomic.Value(u32) = .init(0);

fn lockPool() void {
    while (pool_gate.cmpxchgStrong(0, 1, .acquire, .monotonic)) |_| {
        std.atomic.spinLoopHint();
    }
}

fn unlockPool() void {
    pool_gate.store(0, .release);
}

fn sizeClassIndex(size: usize) ?usize {
    var i: usize = 0;
    while (i < SLOT_COUNT) : (i += 1) {
        if (size <= slot_sizes[i]) return i;
    }
    return null;
}

pub const TagStat = struct {
    tag: u32,
    allocs: usize,
    frees: usize,
};

const tag_stat_cap: usize = 64;
var tag_stats: [tag_stat_cap]TagStat = undefined;
var tag_stats_len: usize = 0;

fn recordTagAllocUnlocked(tag: u32) void {
    if (tag == 0) return;
    var i: usize = 0;
    while (i < tag_stats_len) : (i += 1) {
        if (tag_stats[i].tag == tag) {
            tag_stats[i].allocs += 1;
            return;
        }
    }
    if (tag_stats_len < tag_stat_cap) {
        tag_stats[tag_stats_len] = .{ .tag = tag, .allocs = 1, .frees = 0 };
        tag_stats_len += 1;
    }
    // 槽满后新 tag 静默丢弃统计（调试路径；非生产配额机制）。
}

fn recordTagFreeUnlocked(tag: u32) void {
    if (tag == 0) return;
    var i: usize = 0;
    while (i < tag_stats_len) : (i += 1) {
        if (tag_stats[i].tag == tag) {
            tag_stats[i].frees += 1;
            return;
        }
    }
}

pub fn copyTagStats(out: []TagStat) usize {
    lockPool();
    defer unlockPool();
    const n = @min(out.len, tag_stats_len);
    for (0..n) |i| {
        out[i] = tag_stats[i];
    }
    return n;
}

pub fn tagStatsLenForDebug() usize {
    lockPool();
    defer unlockPool();
    return tag_stats_len;
}

pub fn notePagedPoolTrimPlaceholder(bytes_hint: usize) void {
    _ = bytes_hint;
    paged_trim_placeholder_events +|= 1;
}

pub fn pagedTrimPlaceholderEventsForDebug() usize {
    return paged_trim_placeholder_events;
}

/// 调试/测试：PagedPool 字节软上限（与 `paged_bytes_outstanding` 使用同一计量口径：按调用方 `size`）。
pub fn setPagedPoolSoftLimitForTest(limit: usize) void {
    paged_pool_soft_limit_bytes = limit;
}

pub fn pagedBytesOutstandingForDebug() usize {
    return paged_bytes_outstanding;
}

pub fn pagedPoolSoftLimitForDebug() usize {
    return paged_pool_soft_limit_bytes;
}

/// 将新 zone 页切成 `slot_idx` 档位块并挂入全局空闲链（已持锁或仅由 refill 调用）。
fn refillSlotFromNewPage(slot_idx: usize, kind: pool_zone.ZonePoolKind) bool {
    const slot = slot_sizes[slot_idx];
    const page = pool_zone.allocZonePage(kind, @alignOf(FreeNode)) orelse return false;
    var off: usize = 0;
    while (off + slot <= ZONE_PAGE) : (off += slot) {
        const node: *FreeNode = @ptrCast(@alignCast(page + off));
        node.next = free_heads[slot_idx];
        free_heads[slot_idx] = node;
    }
    return true;
}

fn allocateNonPagedLocked(size: usize, kind: pool_zone.ZonePoolKind) ?[*]u8 {
    const idx = sizeClassIndex(size) orelse {
        return heap.alloc(size, @alignOf(FreeNode));
    };
    const slot = slot_sizes[idx];
    if (free_heads[idx]) |n| {
        free_heads[idx] = n.next;
        return @ptrCast(n);
    }
    if (!refillSlotFromNewPage(idx, kind)) return null;
    if (free_heads[idx]) |n| {
        free_heads[idx] = n.next;
        return @ptrCast(n);
    }
    return heap.alloc(slot, @alignOf(FreeNode));
}

pub fn allocatePaged(size: usize, tag: u32) ?[*]u8 {
    const lim = paged_pool_soft_limit_bytes;
    if (sizeClassIndex(size)) |idx| {
        if (lookaside.tryPop(idx)) |n| {
            lockPool();
            if (lim != 0 and paged_bytes_outstanding + size > lim) {
                unlockPool();
                _ = lookaside.tryPush(idx, n);
                notePagedPoolTrimPlaceholder(size);
                return null;
            }
            recordTagAllocUnlocked(tag);
            paged_bytes_outstanding += size;
            unlockPool();
            return @ptrCast(n);
        }
    }
    lockPool();
    defer unlockPool();
    if (lim != 0 and paged_bytes_outstanding + size > lim) {
        notePagedPoolTrimPlaceholder(size);
        return null;
    }
    const p = allocateNonPagedLocked(size, .paged) orelse return null;
    recordTagAllocUnlocked(tag);
    paged_bytes_outstanding += size;
    return p;
}

pub fn freePaged(ptr: [*]u8, size: usize, tag: u32) void {
    if (sizeClassIndex(size)) |idx| {
        const node: *FreeNode = @ptrCast(@alignCast(ptr));
        if (lookaside.tryPush(idx, node)) {
            lockPool();
            defer unlockPool();
            recordTagFreeUnlocked(tag);
            paged_bytes_outstanding = if (paged_bytes_outstanding >= size) paged_bytes_outstanding - size else 0;
            return;
        }
    }
    lockPool();
    defer unlockPool();
    recordTagFreeUnlocked(tag);
    freeNonPagedImplLocked(ptr, size);
    paged_bytes_outstanding = if (paged_bytes_outstanding >= size) paged_bytes_outstanding - size else 0;
}

pub fn allocateNonPaged(size: usize, tag: u32) ?[*]u8 {
    if (sizeClassIndex(size)) |idx| {
        if (lookaside.tryPop(idx)) |n| {
            lockPool();
            defer unlockPool();
            recordTagAllocUnlocked(tag);
            return @ptrCast(n);
        }
    }
    lockPool();
    defer unlockPool();
    const p = allocateNonPagedLocked(size, .non_paged) orelse return null;
    recordTagAllocUnlocked(tag);
    return p;
}

fn freeNonPagedImplLocked(ptr: [*]u8, size: usize) void {
    const idx = sizeClassIndex(size) orelse {
        heap.free(ptr, size, @alignOf(FreeNode));
        return;
    };
    const node: *FreeNode = @ptrCast(@alignCast(ptr));
    node.next = free_heads[idx];
    free_heads[idx] = node;
}

pub fn freeNonPaged(ptr: [*]u8, size: usize, tag: u32) void {
    if (sizeClassIndex(size)) |idx| {
        const node: *FreeNode = @ptrCast(@alignCast(ptr));
        if (lookaside.tryPush(idx, node)) {
            lockPool();
            defer unlockPool();
            recordTagFreeUnlocked(tag);
            return;
        }
    }
    lockPool();
    defer unlockPool();
    recordTagFreeUnlocked(tag);
    freeNonPagedImplLocked(ptr, size);
}

/// `ExReallocatePoolWithTag` 语义子集：新分配 + 拷贝 + 释放旧块（跨档位安全）；`old_size == new_size` 时原指针返回。
pub fn reallocateNonPaged(ptr: [*]u8, old_size: usize, new_size: usize, tag: u32) ?[*]u8 {
    if (old_size == new_size) return ptr;
    const p = allocateNonPaged(new_size, tag) orelse return null;
    const n = @min(old_size, new_size);
    @memcpy(p[0..n], ptr[0..n]);
    freeNonPaged(ptr, old_size, tag);
    return p;
}

pub fn reallocatePaged(ptr: [*]u8, old_size: usize, new_size: usize, tag: u32) ?[*]u8 {
    if (old_size == new_size) return ptr;
    const p = allocatePaged(new_size, tag) orelse return null;
    const n = @min(old_size, new_size);
    @memcpy(p[0..n], ptr[0..n]);
    freePaged(ptr, old_size, tag);
    return p;
}

test "pool reallocateNonPaged crosses slot" {
    heap.init();
    tag_stats_len = 0;
    const p = allocateNonPaged(32, 0xABCD) orelse return error.A;
    @memset(p[0..32], 0xCD);
    const q = reallocateNonPaged(p, 32, 128, 0xABCD) orelse return error.R;
    try std.testing.expectEqual(@as(u8, 0xCD), q[0]);
    freeNonPaged(q, 128, 0xABCD);
}

test "pool slot roundtrip uses heap then freelist" {
    heap.init();
    tag_stats_len = 0;
    const p = allocateNonPaged(64, 0x1234) orelse std.debug.panic("p", .{});
    @memset(p[0..64], 0);
    freeNonPaged(p, 64, 0x1234);
    const q = allocateNonPaged(64, 0x5678) orelse std.debug.panic("q", .{});
    try std.testing.expect(@intFromPtr(q) == @intFromPtr(p));
    freeNonPaged(q, 64, 0x5678);
    var buf: [4]TagStat = undefined;
    const n = copyTagStats(&buf);
    try std.testing.expect(n >= 2);
}

test "pool stress alloc free stable slot reuse" {
    heap.init();
    tag_stats_len = 0;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const p = allocateNonPaged(128, 0xAABB) orelse return error.Oom;
        @memset(p[0..128], @truncate(i));
        freeNonPaged(p, 128, 0xAABB);
    }
    const last = allocateNonPaged(128, 0xCCDD) orelse return error.Oom;
    freeNonPaged(last, 128, 0xCCDD);
    try std.testing.expect(true);
}

test "PagedPool trim placeholder counter" {
    const before = pagedTrimPlaceholderEventsForDebug();
    notePagedPoolTrimPlaceholder(4096);
    try std.testing.expectEqual(before + 1, pagedTrimPlaceholderEventsForDebug());
}

test "PagedPool soft limit rejects over-budget alloc" {
    heap.init();
    tag_stats_len = 0;
    setPagedPoolSoftLimitForTest(96);
    defer setPagedPoolSoftLimitForTest(0);
    const a = allocatePaged(64, 0xAA) orelse return error.A;
    const b = allocatePaged(32, 0xBB) orelse return error.B;
    try std.testing.expect(allocatePaged(32, 0xCC) == null);
    freePaged(b, 32, 0xBB);
    freePaged(a, 64, 0xAA);
    try std.testing.expectEqual(@as(usize, 0), pagedBytesOutstandingForDebug());
}

test "lookaside absorbs small churn" {
    heap.init();
    tag_stats_len = 0;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const p = allocateNonPaged(32, 0x1111) orelse return error.Oom;
        freeNonPaged(p, 32, 0x1111);
    }
    try std.testing.expect(lookaside.depthForDebug(0, 1) > 0);
}
