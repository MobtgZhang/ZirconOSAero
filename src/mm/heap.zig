// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/heap.zig
// Purpose: 内核通用堆 — bump 增长区 + 按块 `FreeBlock` 元数据的空闲链表（支持 kfree）；大块不走伙伴合并（相邻块不合并），复杂碎片控制见 `pool.zig` 档位与路线图 slab/伙伴评估。
//
// This is an independent clean-room implementation.
// Reference: OS textbook free-list heap; MS Learn — kernel pool concepts (behavioral only).

const std = @import("std");

const HEAP_SIZE: usize = 512 * 1024;
var heap_storage: [HEAP_SIZE]u8 align(16) = undefined;
var heap_pos: usize = 0;
var heap_initialized: bool = false;

const FreeBlock = struct {
    size: usize,
    next: ?*FreeBlock,
};

var free_head: ?*FreeBlock = null;

pub fn init() void {
    heap_pos = 0;
    free_head = null;
    heap_initialized = true;
}

fn alignUp(v: usize, alignment: usize) usize {
    const m = alignment - 1;
    return (v + m) & ~m;
}

fn blockOverhead() usize {
    return alignUp(@sizeOf(FreeBlock), @alignOf(FreeBlock));
}

/// 从空闲块取出 `total` 字节（含块首元数据），返回 **用户** 区起始指针。
fn takeFromFreeBlock(block: *FreeBlock) [*]u8 {
    const hdr = blockOverhead();
    return @as([*]u8, @ptrCast(block)) + hdr;
}

pub fn alloc(size: usize, alignment: usize) ?[*]u8 {
    if (!heap_initialized or size == 0 or alignment == 0) return null;
    const hdr = blockOverhead();
    const need_user = alignUp(size, alignment);
    const total = hdr + need_user;

    var prev: ?*FreeBlock = null;
    var cur = free_head;
    while (cur) |b| {
        if (b.size >= total) {
            if (prev) |p| {
                p.next = b.next;
            } else {
                free_head = b.next;
            }
            const rest = b.size - total;
            const min_split = blockOverhead() + 16;
            if (rest >= min_split) {
                const remainder: *FreeBlock = @ptrFromInt(@intFromPtr(b) + total);
                remainder.size = rest;
                remainder.next = free_head;
                free_head = remainder;
            }
            b.size = total;
            b.next = null;
            return takeFromFreeBlock(b);
        }
        prev = b;
        cur = b.next;
    }

    const aligned_pos = alignUp(heap_pos, @max(alignment, 16));
    if (aligned_pos + total > HEAP_SIZE) return null;
    const block: *FreeBlock = @ptrCast(@alignCast(&heap_storage[aligned_pos]));
    block.size = total;
    block.next = null;
    heap_pos = aligned_pos + total;
    return takeFromFreeBlock(block);
}

/// `ptr` / `user_size` / `alignment` 须与同次 `alloc(size, alignment)` 一致。
/// 与路线图「kfree」命名对齐的别名。
pub const kfree = free;

pub fn free(ptr: [*]u8, user_size: usize, alignment: usize) void {
    if (!heap_initialized or user_size == 0) return;
    const hdr = blockOverhead();
    const need_user = alignUp(user_size, alignment);
    const total = hdr + need_user;
    const block_addr = @intFromPtr(ptr) -% hdr;
    if (block_addr < @intFromPtr(&heap_storage) or block_addr >= @intFromPtr(&heap_storage) + HEAP_SIZE) return;
    const block: *FreeBlock = @ptrFromInt(block_addr);
    block.size = total;
    block.next = free_head;
    free_head = block;
}

pub fn allocSlice(comptime T: type, count: usize) ?[]T {
    const size = @sizeOf(T) * count;
    const ptr = alloc(size, @alignOf(T)) orelse return null;
    return @as([*]T, @ptrCast(@alignCast(ptr)))[0..count];
}

pub fn allocObj(comptime T: type) ?*T {
    const ptr = alloc(@sizeOf(T), @alignOf(T)) orelse return null;
    const result: *T = @ptrCast(@alignCast(ptr));
    result.* = undefined;
    return result;
}

pub fn allocZeroed(size: usize, alignment: usize) ?[*]u8 {
    const ptr = alloc(size, alignment) orelse return null;
    const slice = ptr[0..size];
    @memset(slice, 0);
    return ptr;
}

pub fn usedBytes() usize {
    return heap_pos;
}

pub fn freeBytes() usize {
    return HEAP_SIZE - heap_pos;
}

pub fn totalBytes() usize {
    return HEAP_SIZE;
}

pub const pool = @import("pool.zig");

test "heap alloc kfree roundtrip" {
    init();
    const p = alloc(64, 16) orelse {
        std.debug.panic("alloc", .{});
    };
    @memset(p[0..64], 0xAA);
    kfree(p, 64, 16);
    const q = alloc(64, 16) orelse {
        std.debug.panic("realloc after free", .{});
    };
    try std.testing.expect(@intFromPtr(q) != 0);
    kfree(q, 64, 16);
}

test "heap split large free block" {
    init();
    const big = alloc(256, 8) orelse {
        std.debug.panic("big", .{});
    };
    kfree(big, 256, 8);
    _ = alloc(32, 8) orelse std.debug.panic("a", .{});
    _ = alloc(32, 8) orelse std.debug.panic("b", .{});
}

test "heap interleaved alloc free reuses bump region" {
    init();
    var ptrs: [24]?[*]u8 = .{null} ** 24;
    for (0..24) |i| {
        ptrs[i] = alloc(48, 16);
        try std.testing.expect(ptrs[i] != null);
    }
    for (0..24) |i| {
        if (ptrs[i]) |p| kfree(p, 48, 16);
    }
    const again = alloc(48, 16) orelse std.debug.panic("again", .{});
    kfree(again, 48, 16);
}
