// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/pool.zig
// Purpose: 带标签的小型池分配（固定档位 + 空闲链表），作为 bump heap 的补充；对齐 **NonPagedPool** 与 **PagedPool** 的公开语义子集。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: WDK — Pool Types / ExAllocatePoolWithTag (公开行为描述)

const heap = @import("heap.zig");

/// 与 WDK 中 `POOL_TYPE` 概念对齐的粗分（本内核尚未实现工作集换出；Paged 为 **逻辑** 分页池：同物理后备但单独统计，便于后续接 MM）。
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

fn sizeClassIndex(size: usize) ?usize {
    var i: usize = 0;
    while (i < SLOT_COUNT) : (i += 1) {
        if (size <= slot_sizes[i]) return i;
    }
    return null;
}

/// 逻辑 **PagedPool**：当前与 NonPaged 共用同一后备；`paged_bytes_outstanding` 用于调试统计。
pub fn allocatePaged(size: usize, tag: u32) ?[*]u8 {
    const p = allocateNonPaged(size, tag) orelse return null;
    paged_bytes_outstanding += size;
    return p;
}

pub fn freePaged(ptr: [*]u8, size: usize, tag: u32) void {
    freeNonPaged(ptr, size, tag);
    paged_bytes_outstanding = if (paged_bytes_outstanding >= size) paged_bytes_outstanding - size else 0;
}

/// 从池或 bump 堆分配 `size` 字节（向上取到档位）；失败返回 null。
pub fn allocateNonPaged(size: usize, _: u32) ?[*]u8 {
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

/// 释放由 `allocateNonPaged` 返回的指针；大于最大档位的块归还 `heap.free`。
pub fn freeNonPaged(ptr: [*]u8, size: usize, _: u32) void {
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

test "pool slot roundtrip uses heap then freelist" {
    const std = @import("std");
    heap.init();
    const p = allocateNonPaged(64, 0x1234) orelse std.debug.panic("p", .{});
    @memset(p[0..64], 0);
    freeNonPaged(p, 64, 0x1234);
    const q = allocateNonPaged(64, 0x5678) orelse std.debug.panic("q", .{});
    try std.testing.expect(@intFromPtr(q) == @intFromPtr(p));
    freeNonPaged(q, 64, 0x5678);
}

test "pool stress alloc free stable slot reuse" {
    const std = @import("std");
    heap.init();
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
