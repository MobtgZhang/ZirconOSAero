// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/phys_buddy.zig
// Purpose: 将 `buddy.zig` 逻辑块索引锚定到 **连续物理 PFN 区域**（从 `FrameAllocator`  carve），供 2^order 页分配。
//
// This is an independent clean-room implementation.
// Reference: textbook buddy system; no Windows/ReactOS code.

const buddy_mod = @import("buddy.zig");
const frame_mod = @import("frame.zig");

pub const FRAME_SIZE = frame_mod.FRAME_SIZE;

/// `max_order`：伙伴阶数上界；arena 大小 = `2^max_order` 页。
pub fn PhysBuddy(comptime max_order: u5) type {
    const BuddyType = buddy_mod.Buddy(max_order);
    return struct {
        const Self = @This();
        inner: BuddyType,
        base_phys: u64,
        num_leaf_pages: usize,
        inited: bool = false,

        /// 从 `alloc` 中取出 `2^max_order` 个连续物理页作为 arena；失败则 `inited` 保持 false。
        pub fn initFromFrameAllocator(fa: *frame_mod.FrameAllocator) Self {
            const n = @as(usize, 1) << max_order;
            const phys = fa.allocContiguous(n) orelse return .{
                .inner = BuddyType.init(),
                .base_phys = 0,
                .num_leaf_pages = 0,
                .inited = false,
            };
            return .{
                .inner = BuddyType.init(),
                .base_phys = phys,
                .num_leaf_pages = n,
                .inited = true,
            };
        }

        /// 分配 `2^order` 个连续 **物理** 页；失败返回 null。
        pub fn allocPhys(self: *Self, order: u5) ?u64 {
            if (!self.inited) return null;
            const idx = self.inner.alloc(order) orelse return null;
            const off = @as(u64, @intCast(idx)) * FRAME_SIZE;
            return self.base_phys + off;
        }

        /// 与 `allocPhys` 配对；`phys` 须为某次分配的首地址。
        pub fn freePhys(self: *Self, phys: u64, order: u5) void {
            if (!self.inited) return;
            if (phys < self.base_phys) return;
            const rel = phys - self.base_phys;
            if (rel % FRAME_SIZE != 0) return;
            const idx: usize = @intCast(rel / FRAME_SIZE);
            if (idx >= self.num_leaf_pages) return;
            self.inner.free(idx, order);
        }

        /// 整块 arena 归还到 `FrameAllocator`（须已 `freePhys` 全部子分配）。
        pub fn releaseArena(self: *Self, fa: *frame_mod.FrameAllocator) void {
            if (!self.inited) return;
            if (!self.inner.isEmpty()) return;
            fa.free(self.base_phys);
            self.inited = false;
            self.base_phys = 0;
            self.num_leaf_pages = 0;
            self.inner = BuddyType.init();
        }
    };
}
