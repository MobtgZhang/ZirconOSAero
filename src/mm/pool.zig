// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/pool.zig
// Purpose: 带标签的小型池分配（固定档位 + 空闲链表），作为 bump heap 的补充；语义对齐 NonPagedPool 子集。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: WDK — Pool Types / ExAllocatePoolWithTag (公开行为描述)

const heap = @import("heap.zig");

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
