//! Kernel Heap Allocator (Bump allocator)
//! Provides dynamic memory allocation for kernel-mode data structures

const HEAP_SIZE: usize = 512 * 1024;
var heap_storage: [HEAP_SIZE]u8 align(16) = undefined;
var heap_pos: usize = 0;
var heap_initialized: bool = false;

pub fn init() void {
    heap_pos = 0;
    heap_initialized = true;
}

pub fn alloc(size: usize, alignment: usize) ?[*]u8 {
    if (!heap_initialized or size == 0 or alignment == 0) return null;
    const align_mask = alignment - 1;
    const aligned_pos = (heap_pos + align_mask) & ~align_mask;
    if (aligned_pos + size > HEAP_SIZE) return null;
    const result = @as([*]u8, @ptrCast(&heap_storage[aligned_pos]));
    heap_pos = aligned_pos + size;
    return result;
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
