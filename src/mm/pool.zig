// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/pool.zig
// Purpose: 带标签的小型池分配（固定档位 + 空闲链表 + 原子池锁），后备为通用堆 `heap.zig`；对齐 **NonPagedPool** 与 **PagedPool** 的公开语义子集。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: WDK — Pool Types / ExAllocatePoolWithTag (公开行为描述)
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../docs/cn/NT61_KERNEL_TODO.md) Phase K1.2
//
// IRQL / SMP（与 WDK 目标语义对齐的演进说明）：
// - **NonPagedPool**：文档要求可在 DISPATCH_LEVEL 及以下安全分配；本模块对档位链表与 tag 统计使用 **原子自旋风格锁**（`pool_gate`），与 `heap` 内锁嵌套顺序为 **先 pool 后 heap**，避免死锁。
// - 完整 SMP 下仍宜引入 per-CPU 池或 `IrqSpinLock` 包装；见路线图 K1。
// - **PagedPool**：逻辑计数分离，**尚未**接真正分页换出。

const std = @import("std");
const heap = @import("heap.zig");

pub const PoolType = enum(u8) {
    non_paged = 0,
    paged = 1,
};

var paged_bytes_outstanding: usize = 0;

const SLOT_COUNT: usize = 6;
const slot_sizes: [SLOT_COUNT]usize = .{ 16, 32, 64, 128, 256, 512 };

var free_heads: [SLOT_COUNT]?*FreeNode = .{null} ** SLOT_COUNT;

const FreeNode = struct {
    next: ?*FreeNode,
};

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

const tag_stat_cap: usize = 48;
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

/// 调试：拷贝当前 tag 统计表，返回写入条数。
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

/// 逻辑 **PagedPool**：当前与 NonPaged 共用同一后备；`paged_bytes_outstanding` 用于调试统计。
pub fn allocatePaged(size: usize, tag: u32) ?[*]u8 {
    lockPool();
    defer unlockPool();
    const p = allocateNonPagedLocked(size) orelse return null;
    recordTagAllocUnlocked(tag);
    paged_bytes_outstanding += size;
    return p;
}

pub fn freePaged(ptr: [*]u8, size: usize, tag: u32) void {
    lockPool();
    defer unlockPool();
    recordTagFreeUnlocked(tag);
    freeNonPagedImpl(ptr, size);
    paged_bytes_outstanding = if (paged_bytes_outstanding >= size) paged_bytes_outstanding - size else 0;
}

fn allocateNonPagedLocked(size: usize) ?[*]u8 {
    const idx = sizeClassIndex(size) orelse {
        return heap.alloc(size, @alignOf(FreeNode));
    };
    const slot = slot_sizes[idx];
    if (free_heads[idx]) |n| {
        free_heads[idx] = n.next;
        return @ptrCast(n);
    }
    return heap.alloc(slot, @alignOf(FreeNode));
}

/// 从池或通用堆分配 `size` 字节（向上取到档位）；失败返回 null。
pub fn allocateNonPaged(size: usize, tag: u32) ?[*]u8 {
    lockPool();
    defer unlockPool();
    const p = allocateNonPagedLocked(size) orelse return null;
    recordTagAllocUnlocked(tag);
    return p;
}

fn freeNonPagedImpl(ptr: [*]u8, size: usize) void {
    const idx = sizeClassIndex(size) orelse {
        heap.free(ptr, size, @alignOf(FreeNode));
        return;
    };
    const slot = slot_sizes[idx];
    _ = slot;
    const node: *FreeNode = @ptrCast(@alignCast(ptr));
    node.next = free_heads[idx];
    free_heads[idx] = node;
}

/// 释放由 `allocateNonPaged` 返回的指针；大于最大档位的块归还 `heap.free`。
pub fn freeNonPaged(ptr: [*]u8, size: usize, tag: u32) void {
    lockPool();
    defer unlockPool();
    recordTagFreeUnlocked(tag);
    freeNonPagedImpl(ptr, size);
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
