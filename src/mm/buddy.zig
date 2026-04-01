// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/buddy.zig
// Purpose: 物理页级伙伴分配器（按 2^order 块分配/合并），主机单元测试验证；可与 `frame.zig` 位图后端渐进整合。
//
// This is an independent clean-room implementation.
// Reference: classic OS textbook buddy system (e.g. Knuth / Silberschatz); no Windows/ReactOS code.

const std = @import("std");

/// `max_order`：最大阶数；块总数 = `2^max_order`（每块为一个逻辑页帧槽位，索引 0..2^max_order-1）。
pub fn Buddy(comptime max_order: u5) type {
    const num_blocks: usize = @as(usize, 1) << max_order;
    return struct {
        const Self = @This();

        /// 各阶空闲链头（块起始下标）。
        heads: [max_order + 1]?usize = .{null} ** (max_order + 1),
        /// 空闲链下一节点；仅 `free_order[i] != null` 的槽位参与链表。
        next: [num_blocks]?usize = .{null} ** num_blocks,
        /// 若 `free_order[i] == o`，则 `i` 是某块的起始且大小为 `2^o`。
        free_order: [num_blocks]?u5 = .{null} ** num_blocks,

        pub fn init() Self {
            var s: Self = .{};
            s.pushFree(max_order, 0);
            return s;
        }

        fn pushFree(self: *Self, order: u5, idx: usize) void {
            std.debug.assert(self.free_order[idx] == null);
            const o: usize = order;
            self.next[idx] = self.heads[o];
            self.heads[o] = idx;
            self.free_order[idx] = order;
        }

        fn popFree(self: *Self, order: u5) ?usize {
            const o: usize = order;
            const h = self.heads[o] orelse return null;
            self.heads[o] = self.next[h];
            self.next[h] = null;
            self.free_order[h] = null;
            return h;
        }

        fn removeFromFree(self: *Self, order: u5, idx: usize) bool {
            if (self.free_order[idx] != order) return false;
            const o: usize = order;
            var prev: ?usize = null;
            var cur = self.heads[o];
            while (cur) |c| {
                if (c == idx) {
                    if (prev) |p| {
                        self.next[p] = self.next[c];
                    } else {
                        self.heads[o] = self.next[c];
                    }
                    self.next[c] = null;
                    self.free_order[c] = null;
                    return true;
                }
                prev = c;
                cur = self.next[c];
            }
            return false;
        }

        /// 分配 `2^req_order` 个连续块；成功返回起始下标。
        pub fn alloc(self: *Self, req_order: u5) ?usize {
            var k: u5 = req_order;
            while (k <= max_order) : (k += 1) {
                if (self.popFree(k)) |idx| {
                    var cur_k = k;
                    const cur_idx = idx;
                    while (cur_k > req_order) {
                        cur_k -= 1;
                        const half: usize = @as(usize, 1) << cur_k;
                        const right = cur_idx + half;
                        self.pushFree(cur_k, right);
                    }
                    return cur_idx;
                }
            }
            return null;
        }

        /// 释放从 `idx` 开始、大小为 `2^order` 的块（须与 `alloc` 配对）。
        pub fn free(self: *Self, idx: usize, order: u5) void {
            var cur_o = order;
            var cur_i = idx;
            while (cur_o < max_order) {
                const bud = cur_i ^ (@as(usize, 1) << cur_o);
                if (bud >= num_blocks) break;
                if (!self.removeFromFree(cur_o, bud)) break;
                cur_i = @min(cur_i, bud);
                cur_o += 1;
            }
            self.pushFree(cur_o, cur_i);
        }

        /// 是否整块内存已归还为单一 `max_order` 空闲块（用于泄漏检测）。
        pub fn isEmpty(self: *const Self) bool {
            var count: usize = 0;
            for (self.free_order) |fo| {
                if (fo != null) count += 1;
            }
            if (count != 1) return false;
            return self.heads[max_order] == 0 and self.free_order[0] == max_order;
        }
    };
}

test "buddy alloc free roundtrip" {
    var b = Buddy(6).init();
    const a = b.alloc(2) orelse unreachable;
    const c = b.alloc(3) orelse unreachable;
    b.free(a, 2);
    b.free(c, 3);
    try std.testing.expect(b.isEmpty());
}

test "buddy random stress" {
    const BO: u5 = 8;
    var b = Buddy(BO).init();
    var prng = std.Random.DefaultPrng.init(0xB0B0);
    const rnd = prng.random();

    const MaxLive = 40;
    var live_idx: [MaxLive]usize = undefined;
    var live_ord: [MaxLive]u5 = undefined;
    var n: usize = 0;

    for (0..2500) |_| {
        if (n > 0 and (n == MaxLive or rnd.float(f32) < 0.38)) {
            const i = rnd.uintLessThan(usize, n);
            n -= 1;
            const idx = live_idx[i];
            const ord = live_ord[i];
            if (i != n) {
                live_idx[i] = live_idx[n];
                live_ord[i] = live_ord[n];
            }
            b.free(idx, ord);
        } else {
            const ord = @as(u5, @truncate(rnd.uintLessThan(u32, BO)));
            if (b.alloc(ord)) |idx| {
                if (n < MaxLive) {
                    live_idx[n] = idx;
                    live_ord[n] = ord;
                    n += 1;
                } else {
                    b.free(idx, ord);
                }
            }
        }
    }

    while (n > 0) {
        n -= 1;
        b.free(live_idx[n], live_ord[n]);
    }
    try std.testing.expect(b.isEmpty());
}
