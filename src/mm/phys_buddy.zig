// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/phys_buddy.zig
// Purpose: 将 `buddy.zig` 逻辑块索引锚定到 **连续物理 PFN 区域**（从 `FrameAllocator` carve），供 2^order 页分配。
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
            const self_pb = Self{
                .inner = BuddyType.init(),
                .base_phys = phys,
                .num_leaf_pages = n,
                .inited = true,
            };
            fa.markBuddyArenaFrames(phys, n);
            return self_pb;
        }

        /// 分配 `2^order` 个连续 **物理** 页；失败返回 null。
        pub fn allocPhys(self: *Self, order: u5) ?u64 {
            if (!self.inited) return null;
            if (order > max_order) return null;
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
            var i: usize = 0;
            while (i < self.num_leaf_pages) : (i += 1) {
                fa.free(self.base_phys + @as(u64, @intCast(i)) * FRAME_SIZE);
            }
            self.inited = false;
            self.base_phys = 0;
            self.num_leaf_pages = 0;
            self.inner = BuddyType.init();
        }
    };
}

/// 首选 carve 阶数（256 页）；失败时依次尝试 7、6（P0 回退）。
pub const kernel_contiguous_max_order: u5 = 8;

const ActiveTag = enum(u8) { none, o8, o7, o6 };

var g_tag: ActiveTag = .none;
var g_pb8: PhysBuddy(8) = undefined;
var g_pb7: PhysBuddy(7) = undefined;
var g_pb6: PhysBuddy(6) = undefined;

/// 从 `FrameAllocator` carve 一块连续 PFN 区并初始化伙伴；按 8→7→6 阶尝试直至成功或全部失败。
pub fn initKernelContiguousBuddy(fa: *frame_mod.FrameAllocator) void {
    g_tag = .none;
    g_pb8 = PhysBuddy(8).initFromFrameAllocator(fa);
    if (g_pb8.inited) {
        g_tag = .o8;
        return;
    }
    g_pb7 = PhysBuddy(7).initFromFrameAllocator(fa);
    if (g_pb7.inited) {
        g_tag = .o7;
        return;
    }
    g_pb6 = PhysBuddy(6).initFromFrameAllocator(fa);
    if (g_pb6.inited) {
        g_tag = .o6;
    }
}

pub fn kernelContiguousBuddyReady() bool {
    return g_tag != .none;
}

/// 当前 arena 的最大 `order`（与 `kernelAllocContiguousPhys` 可请求上界一致）。
pub fn kernelContiguousMaxOrder() u5 {
    return switch (g_tag) {
        .none => 0,
        .o8 => 8,
        .o7 => 7,
        .o6 => 6,
    };
}

pub fn kernelContiguousLeafPages() usize {
    return switch (g_tag) {
        .none => 0,
        .o8 => g_pb8.num_leaf_pages,
        .o7 => g_pb7.num_leaf_pages,
        .o6 => g_pb6.num_leaf_pages,
    };
}

/// 分配 `2^order` 个连续物理页的首地址；未初始化或失败返回 null。
pub fn kernelAllocContiguousPhys(order: u5) ?u64 {
    return switch (g_tag) {
        .none => null,
        .o8 => g_pb8.allocPhys(order),
        .o7 => g_pb7.allocPhys(order),
        .o6 => g_pb6.allocPhys(order),
    };
}

pub fn kernelFreeContiguousPhys(phys: u64, order: u5) void {
    switch (g_tag) {
        .none => {},
        .o8 => g_pb8.freePhys(phys, order),
        .o7 => g_pb7.freePhys(phys, order),
        .o6 => g_pb6.freePhys(phys, order),
    }
}

/// 伙伴耗尽或未就绪时，回退到 `FrameAllocator.allocContiguous`（须用 `kernelFreeContiguousEx` 配对释放）。
pub const ContiguousSource = enum(u8) { buddy, frame_bitmap };

pub fn kernelAllocContiguousPhysWithFallback(order: u5) struct { phys: ?u64, source: ContiguousSource } {
    if (kernelAllocContiguousPhys(order)) |p| return .{ .phys = p, .source = .buddy };
    const fa = frame_mod.getKernelFrameAllocator() orelse return .{ .phys = null, .source = .frame_bitmap };
    const n = @as(usize, 1) << order;
    const p = fa.allocContiguous(n) orelse return .{ .phys = null, .source = .frame_bitmap };
    return .{ .phys = p, .source = .frame_bitmap };
}

pub fn kernelFreeContiguousEx(phys: u64, order: u5, source: ContiguousSource) void {
    const n = @as(usize, 1) << order;
    switch (source) {
        .buddy => kernelFreeContiguousPhys(phys, order),
        .frame_bitmap => {
            if (frame_mod.getKernelFrameAllocator()) |fa| fa.freeContiguousRange(phys, n);
        },
    }
}

// 与 `FrameAllocator` 的联合主机单测受 Zig 模块根路径限制（`frame.zig` 依赖 `arch`）；算法见 `buddy.zig` 单测，接线验证见内核启动 klog `PhysBuddy:`。
