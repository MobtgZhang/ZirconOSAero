// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/heap.zig
// Purpose: 内核通用堆 — **bump 高水位仅作 arena 内快速路径**，与 **空闲链表合并** 并存；大块与 **池 zone**（`pool_zone.zig` + `pool.zig`）为热路径，勿依赖「纯 bump、不可释放」作为长期策略。可选可增长 arena（`heap_boot.zig` → `vm.mapPageAlloc`）。
//
// This is an independent clean-room implementation.
// Reference: OS textbook free-list heap with coalescing; MS Learn — kernel pool concepts (behavioral only).

const builtin = @import("builtin");
const std = @import("std");
const klog = @import("../rtl/klog.zig");

/// 主机 `zig test` 与可增长初始化失败时的后备大小。
const STATIC_FALLBACK_BYTES: usize = 512 * 1024;

/// 堆虚拟基址：置于常见 identity 低区之上；由 `heap_boot` 映射。
pub const KERNEL_HEAP_VIRT_BASE: usize = 0xC000_0000;

const host_heap: bool = builtin.os.tag != .freestanding;

var gate: std.atomic.Value(u32) = .init(0);

fn lockHeap() void {
    while (gate.cmpxchgStrong(0, 1, .acquire, .monotonic)) |_| {
        std.atomic.spinLoopHint();
    }
}

fn unlockHeap() void {
    gate.store(0, .release);
}

var alloc_count: usize = 0;
var free_count: usize = 0;
var live_bytes: usize = 0;

pub fn stats() struct { allocs: usize, frees: usize, live: usize } {
    lockHeap();
    defer unlockHeap();
    return .{ .allocs = alloc_count, .frees = free_count, .live = live_bytes };
}

pub fn freeListDebug() struct { nodes: usize, bytes: usize } {
    if (builtin.mode != .Debug) return .{ .nodes = 0, .bytes = 0 };
    lockHeap();
    defer unlockHeap();
    var nodes: usize = 0;
    var bytes: usize = 0;
    var cur = free_head;
    while (cur) |b| {
        nodes += 1;
        bytes += b.size;
        cur = b.next;
    }
    return .{ .nodes = nodes, .bytes = bytes };
}

var heap_storage: [STATIC_FALLBACK_BYTES]u8 align(16) = undefined;

var use_growable: bool = false;
var grow_ctx: ?*anyopaque = null;
/// 将 `[virt, virt+len)` 映射为可写匿名页（`len` 为页大小整数倍）；失败返回 false。
var grow_map_range: ?*const fn (*anyopaque, usize, usize) bool = null;

var arena_base: usize = 0;
var arena_committed: usize = 0;
var arena_capacity: usize = 0;

var heap_pos: usize = 0;
var heap_initialized: bool = false;

const FreeBlock = struct {
    size: usize,
    next: ?*FreeBlock,
};

var free_head: ?*FreeBlock = null;

/// 由 `initGrowable` 写入（内核来自 `heap_boot` 的架构页大小）；静态 `init` 下为 4KiB。
var heap_page_size: usize = 4096;

fn alignUp(v: usize, alignment: usize) usize {
    const m = alignment - 1;
    return (v + m) & ~m;
}

fn alignUpToPage(v: usize) usize {
    return std.mem.alignForward(usize, v, heap_page_size);
}

fn blockOverhead() usize {
    return alignUp(@sizeOf(FreeBlock), @alignOf(FreeBlock));
}

pub fn init() void {
    klog.info("Heap: using static fallback init", .{});
    lockHeap();
    defer unlockHeap();
    initUnlockedStatic();
}

fn initUnlockedStatic() void {
    use_growable = false;
    grow_ctx = null;
    grow_map_range = null;
    heap_page_size = 4096;
    arena_base = @intFromPtr(&heap_storage);
    arena_committed = STATIC_FALLBACK_BYTES;
    arena_capacity = STATIC_FALLBACK_BYTES;
    heap_pos = 0;
    free_head = null;
    live_bytes = 0;
    heap_initialized = true;
}

pub const GrowOptions = struct {
    base_virt: usize,
    capacity: usize,
    /// 须为页大小整数倍且 ≤ capacity。
    initial_commit: usize,
    /// 与 `map_range` 映射粒度一致（x86_64 常见 4096，LoongArch 可能为 16KiB）。
    page_size: usize,
    map_ctx: *anyopaque,
    map_range: *const fn (*anyopaque, usize, usize) bool,
};

/// 由 `heap_boot.zig` 在内核 VM 就绪后调用；失败时调用方应回退 `init()`。
pub fn initGrowable(opts: GrowOptions) bool {
    if (host_heap) return false;
    lockHeap();
    defer unlockHeap();
    if (opts.initial_commit > opts.capacity) return false;
    if (opts.page_size == 0) return false;
    if (opts.initial_commit > 0 and !opts.map_range(opts.map_ctx, opts.base_virt, opts.initial_commit))
        return false;

    heap_page_size = opts.page_size;
    use_growable = true;
    grow_ctx = opts.map_ctx;
    grow_map_range = opts.map_range;
    arena_base = opts.base_virt;
    arena_capacity = opts.capacity;
    arena_committed = opts.initial_commit;
    heap_pos = 0;
    free_head = null;
    live_bytes = 0;
    heap_initialized = true;
    return true;
}

pub fn kernelHeapBaseVirt() usize {
    return arena_base;
}

pub fn isGrowableBacked() bool {
    return use_growable;
}

pub fn heap_check() bool {
    if (builtin.mode != .Debug) return true;
    lockHeap();
    defer unlockHeap();
    const hdr = blockOverhead();
    var cur = free_head;
    const h0 = arena_base;
    const h1 = arena_base + arena_committed;
    while (cur) |b| {
        const p = @intFromPtr(b);
        if (p < h0 or p >= h1) return false;
        if (b.size < hdr) return false;
        cur = b.next;
    }
    return true;
}

fn takeFromFreeBlock(block: *FreeBlock) [*]u8 {
    const hdr = blockOverhead();
    return @as([*]u8, @ptrCast(block)) + hdr;
}

fn insertFreeBlock(block: *FreeBlock) void {
    const ba = @intFromPtr(block);
    var prev: ?*FreeBlock = null;
    var cur_o = free_head;
    while (cur_o) |c| {
        if (@intFromPtr(c) > ba) break;
        prev = c;
        cur_o = c.next;
    }
    block.next = cur_o;

    if (cur_o) |c| {
        if (ba + block.size == @intFromPtr(c)) {
            block.size += c.size;
            block.next = c.next;
        }
    }

    if (prev) |pr| {
        if (@intFromPtr(pr) + pr.size == ba) {
            pr.size += block.size;
            pr.next = block.next;
            return;
        }
        pr.next = block;
    } else {
        free_head = block;
    }
}

fn ensureCommitted(need_end: usize) bool {
    const need = alignUpToPage(need_end);
    if (need <= arena_committed) return true;
    if (!use_growable) return false;
    if (need > arena_capacity) return false;
    const g = grow_map_range orelse return false;
    const ctx = grow_ctx orelse return false;
    const extra = need - arena_committed;
    if (!g(ctx, arena_base + arena_committed, extra)) return false;
    arena_committed = need;
    return true;
}

pub fn alloc(size: usize, alignment: usize) ?[*]u8 {
    if (!heap_initialized or size == 0 or alignment == 0) return null;
    lockHeap();
    defer unlockHeap();

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
                insertFreeBlock(remainder);
            }
            b.size = total;
            b.next = null;
            alloc_count += 1;
            live_bytes += total;
            return takeFromFreeBlock(b);
        }
        prev = b;
        cur = b.next;
    }

    const aligned_pos = alignUp(heap_pos, @max(alignment, 16));
    const need_end = aligned_pos + total;
    if (!ensureCommitted(need_end)) return null;

    const block: *FreeBlock = @ptrCast(@alignCast(ptrAt(aligned_pos)));
    block.size = total;
    block.next = null;
    heap_pos = need_end;
    alloc_count += 1;
    live_bytes += total;
    return takeFromFreeBlock(block);
}

fn ptrAt(offset: usize) [*]u8 {
    return @ptrFromInt(arena_base + offset);
}

pub const kfree = free;

/// 释放通过 allocSlice 分配的切片
pub fn freeSlice(comptime T: type, slice: []T) void {
    const ptr: [*]u8 = @ptrCast(@alignCast(slice.ptr));
    const size = @sizeOf(T) * slice.len;
    free(ptr, size, @alignOf(T));
}

pub fn free(ptr: [*]u8, user_size: usize, alignment: usize) void {
    if (!heap_initialized or user_size == 0) return;
    lockHeap();
    defer unlockHeap();

    const hdr = blockOverhead();
    const need_user = alignUp(user_size, alignment);
    const total = hdr + need_user;
    const block_addr = @intFromPtr(ptr) -% hdr;
    const h0 = arena_base;
    const h1 = arena_base + arena_committed;
    if (block_addr < h0 or block_addr + total > h1) return;
    const block: *FreeBlock = @ptrFromInt(block_addr);
    block.size = total;
    insertFreeBlock(block);
    free_count += 1;
    live_bytes -|= total;
}

/// 调整已分配块大小：`ptr == null` 时等价 `alloc`；`new_user_size == 0` 时释放并返回 null。
/// 非平凡变长：新分配 + 拷贝 + 释放旧块（与空闲链表/合并语义一致，避免错误拆块）。
pub fn realloc(
    ptr: ?[*]u8,
    old_user_size: usize,
    old_alignment: usize,
    new_user_size: usize,
    new_alignment: usize,
) ?[*]u8 {
    if (!heap_initialized or new_alignment == 0) return null;
    if (new_user_size == 0) {
        if (ptr) |p| free(p, old_user_size, old_alignment);
        return null;
    }
    if (ptr == null) return alloc(new_user_size, new_alignment);
    if (new_user_size == old_user_size and new_alignment == old_alignment)
        return ptr;

    const newp = alloc(new_user_size, new_alignment) orelse return null;
    const copy_n = @min(old_user_size, new_user_size);
    @memcpy(newp[0..copy_n], ptr.?[0..copy_n]);
    free(ptr.?, old_user_size, old_alignment);
    return newp;
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
    @memset(ptr[0..size], 0);
    return ptr;
}

pub fn usedBytes() usize {
    lockHeap();
    defer unlockHeap();
    return live_bytes;
}

pub fn freeBytes() usize {
    lockHeap();
    defer unlockHeap();
    if (arena_committed >= live_bytes) {
        return arena_committed - live_bytes;
    }
    return 0;
}

pub fn totalBytes() usize {
    lockHeap();
    defer unlockHeap();
    return arena_committed;
}

pub fn capacityBytes() usize {
    lockHeap();
    defer unlockHeap();
    return arena_capacity;
}

pub const pool = @import("pool.zig");

test "heap realloc grow and shrink" {
    init();
    const p = alloc(32, 8) orelse return error.Oom;
    @memset(p[0..32], 0xAB);
    const q = realloc(p, 32, 8, 64, 8) orelse return error.Realloc;
    try std.testing.expectEqual(@as(u8, 0xAB), q[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), q[31]);
    const r = realloc(q, 64, 8, 16, 8) orelse return error.Realloc2;
    try std.testing.expectEqual(@as(u8, 0xAB), r[0]);
    kfree(r, 16, 8);
}

test "heap realloc null is alloc" {
    init();
    const p = realloc(null, 0, 8, 40, 8) orelse return error.Oom;
    kfree(p, 40, 8);
}

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

test "heap adjacent free coalesces" {
    init();
    const a = alloc(32, 8) orelse return error.Oom;
    const b = alloc(32, 8) orelse return error.Oom;
    kfree(a, 32, 8);
    kfree(b, 32, 8);
    const st = freeListDebug();
    try std.testing.expectEqual(@as(usize, 1), st.nodes);
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

test "heap random alloc free stress" {
    init();
    const max_live = 48;
    var live_p: [max_live][*]u8 = undefined;
    var live_sz: [max_live]usize = undefined;
    var live_al: [max_live]usize = undefined;
    var n: usize = 0;

    var prng = std.Random.DefaultPrng.init(0x5A49_5243);
    const rnd = prng.random();
    const sizes = [_]usize{ 16, 24, 32, 48, 64, 96, 128, 192 };
    const aligns = [_]usize{ 8, 16 };

    for (0..1200) |_| {
        const want_free = n > 0 and (n == max_live or rnd.float(f32) < 0.42);
        if (want_free) {
            const idx = rnd.uintLessThan(usize, n);
            n -= 1;
            kfree(live_p[idx], live_sz[idx], live_al[idx]);
            if (idx != n) {
                live_p[idx] = live_p[n];
                live_sz[idx] = live_sz[n];
                live_al[idx] = live_al[n];
            }
        } else {
            const sz = sizes[rnd.uintLessThan(usize, sizes.len)];
            const al = aligns[rnd.uintLessThan(usize, aligns.len)];
            if (alloc(sz, al)) |p| {
                if (n < max_live) {
                    live_p[n] = p;
                    live_sz[n] = sz;
                    live_al[n] = al;
                    n += 1;
                } else {
                    kfree(p, sz, al);
                }
            }
        }
    }

    while (n > 0) {
        n -= 1;
        kfree(live_p[n], live_sz[n], live_al[n]);
    }
    try std.testing.expect(heap_check());

    for (0..40) |_| {
        const p = alloc(512, 16) orelse {
            return std.testing.expect(false);
        };
        kfree(p, 512, 16);
    }
}

test "heap stats live tracks kfree" {
    init();
    try std.testing.expectEqual(@as(usize, 0), usedBytes());
    const p = alloc(100, 8) orelse return error.Oom;
    try std.testing.expect(usedBytes() > 0);
    kfree(p, 100, 8);
    try std.testing.expectEqual(@as(usize, 0), usedBytes());
}
