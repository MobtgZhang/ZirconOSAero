// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/slab.zig
// Purpose: 固定对象大小的 slab cache（单链 slabs + 位图占用），与 `pool.zig` 档位池互补；LPC `Message` 等热点对象可逐步迁入 `SlabCache`（K1.3）。
//
// This is an independent clean-room implementation.
// Reference: OS textbook slab allocator; MS Learn — pool concepts (behavioral only).

const std = @import("std");

pub fn SlabCache(comptime Obj: type, comptime objects_per_slab: usize) type {
    const Slab = struct {
        used_mask: std.StaticBitSet(objects_per_slab),
        next: ?*@This() = null,
        objects: [objects_per_slab]Obj = undefined,
    };
    return struct {
        const Self = @This();
        slabs: ?*Slab = null,

        pub fn alloc(self: *Self, slab_alloc: *const fn (usize, usize) ?[*]u8) ?*Obj {
            var cur = self.slabs;
            while (cur) |slab| {
                var i: usize = 0;
                while (i < objects_per_slab) : (i += 1) {
                    if (!slab.used_mask.isSet(i)) {
                        slab.used_mask.set(i);
                        return &slab.objects[i];
                    }
                }
                cur = slab.next;
            }
            const slab_size = @sizeOf(Slab);
            const raw = slab_alloc(slab_size, @alignOf(Slab)) orelse return null;
            const slab: *Slab = @ptrCast(@alignCast(raw));
            slab.* = .{ .used_mask = std.StaticBitSet(objects_per_slab).initEmpty() };
            slab.used_mask.set(0);
            slab.next = self.slabs;
            self.slabs = slab;
            return &slab.objects[0];
        }

        pub fn free(self: *Self, ptr: *Obj, slab_free: *const fn ([*]u8, usize, usize) void) void {
            var cur: ?*Slab = self.slabs;
            var prev: ?*Slab = null;
            while (cur) |slab| {
                const base = @intFromPtr(&slab.objects[0]);
                const p = @intFromPtr(ptr);
                const span = objects_per_slab * @sizeOf(Obj);
                if (p >= base and p < base + span) {
                    const idx = (p - base) / @sizeOf(Obj);
                    if (idx < objects_per_slab) {
                        slab.used_mask.unset(idx);
                        if (slab.used_mask.count() == 0) {
                            if (prev) |pr| {
                                pr.next = slab.next;
                            } else {
                                self.slabs = slab.next;
                            }
                            slab_free(@ptrCast(slab), @sizeOf(Slab), @alignOf(Slab));
                        }
                    }
                    return;
                }
                prev = slab;
                cur = slab.next;
            }
        }
    };
}

/// Slab 元数据走池层 tag，便于 `pool.copyTagStats` 与泄漏审计（与 `ex_pool.zig` 一致）。
pub const slab_pool_tag: u32 = 0x536C6142;

test "slab cache roundtrip uses ex_pool" {
    const heap = @import("heap.zig");
    const ex = @import("ex_pool.zig");
    heap.init();
    var cache = SlabCache(u32, 8){};
    const allocFn = struct {
        fn f(sz: usize, al: usize) ?[*]u8 {
            _ = al;
            return ex.exAllocatePoolWithTag(sz, slab_pool_tag);
        }
    }.f;
    const freeFn = struct {
        fn f(p: [*]u8, sz: usize, al: usize) void {
            _ = al;
            ex.exFreePoolWithTag(p, sz, slab_pool_tag);
        }
    }.f;
    const p = cache.alloc(allocFn) orelse {
        std.debug.panic("slab alloc", .{});
    };
    p.* = 0x11223344;
    cache.free(p, freeFn);
}
