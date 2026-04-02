// SPDX-License-Identifier: MIT OR Apache-2.0
//
// ZirconOSAero - NT 6.1 Compatible Kernel
// Module: src/mm/mdl.zig
// Purpose: 内存描述符列表（MDL）内核占位 — 描述「虚拟范围 ↔ 物理页」映射；扩展 PFN 槽位与恒等映射填 PFN（锁页 / 散列 DMA 仍待 K1.7）。
//
// This is an independent clean-room implementation.
// No Windows source code or ReactOS source code was referenced.
// Ref: WDK — Memory Descriptor Lists (conceptual: byte offset, byte count, PFN array); Intel SDM — physical address width.
// Milestone: [docs/cn/NT61_KERNEL_TODO.md](../../docs/cn/NT61_KERNEL_TODO.md) Phase K1.7
//
// 生命周期（K1.4/K1.7）：由 `ex_pool`/`pool`/`heap` 分配的 MDL 后备缓冲，须在解除仍引用该 VA 的页表映射 **之前** 释放，避免 UAF 与 DMA 窗口悬空。

const std = @import("std");

/// 与 WDK MDL 标志 **概念** 对齐的最小子集（本结构仍无 IOMMU / 散列列表）。
pub const MdlFlags = packed struct(u8) {
    /// 页框已解析进 `pfns`（不等价于「已锁入工作集」）。
    pages_populated: bool = false,
    /// 由 `vm.mdlLockPagesInFrameAllocator` 置位。
    pages_locked: bool = false,
    _pad: u6 = 0,
};

/// 单块 MDL 内联 PFN 上限（避免早期内核堆分配；大缓冲将来用池化扩展）。
pub const max_mdl_pfns: usize = 64;

/// 描述一段虚拟范围及其解析出的物理页帧号（子集实现）。
pub const Mdl = struct {
    start_va: u64,
    byte_count: u32,
    flags: MdlFlags = .{},
    pfn_count: u8 = 0,
    pfns: [max_mdl_pfns]u64 = .{0} ** max_mdl_pfns,

    pub fn init(start_va: u64, byte_count: u32) Mdl {
        return .{
            .start_va = start_va,
            .byte_count = byte_count,
        };
    }

    /// 返回已写入的 PFN 个数。
    pub fn populatedPfnCount(self: *const Mdl) u8 {
        return self.pfn_count;
    }

    /// **占位**：假设 `start_va` 起为 **4KiB 恒等映射** 内核区，按 `byte_count` 向上取整填 PFN。
    /// 真实路径须遍历页表、`MmProbeAndLockPages` 语义由调用方 IRQL/池类型保证（见 WDK 公开说明）。
    pub fn fillPfnsIdentityAssume4k(self: *Mdl) void {
        self.pfn_count = 0;
        self.flags.pages_populated = false;
        if (self.byte_count == 0) return;

        const page: u64 = 4096;
        const pages_needed = (self.byte_count + @as(u32, @truncate(page)) - 1) / @as(u32, @truncate(page));
        var i: u32 = 0;
        while (i < pages_needed and self.pfn_count < max_mdl_pfns) : (i += 1) {
            const va = self.start_va + @as(u64, i) * page;
            self.pfns[self.pfn_count] = va >> 12;
            self.pfn_count += 1;
        }
        if (self.pfn_count > 0) self.flags.pages_populated = true;
    }

    /// 散列 DMA 占位：返回连续 PFN 个数（当前与 `pfn_count` 相同；将来多段时返回段数）。
    pub fn scatterSegmentCount(self: *const Mdl) u8 {
        if (self.pfn_count == 0) return 0;
        return 1;
    }

};

test "Mdl PFN identity mapping two pages" {
    var m = Mdl.init(0x1000, 5000);
    m.fillPfnsIdentityAssume4k();
    try std.testing.expect(m.flags.pages_populated);
    try std.testing.expectEqual(@as(u8, 2), m.pfn_count);
    try std.testing.expectEqual(@as(u64, 1), m.pfns[0]);
    try std.testing.expectEqual(@as(u64, 2), m.pfns[1]);
    try std.testing.expectEqual(@as(u8, 1), m.scatterSegmentCount());
}

test "Mdl layout stable for host regression" {
    try std.testing.expect(@sizeOf(Mdl) <= 1024);
    const m = Mdl.init(0xFFFF_8000_0000_1000, 4096);
    try std.testing.expectEqual(@as(u64, 0xFFFF_8000_0000_1000), m.start_va);
    try std.testing.expectEqual(@as(u32, 4096), m.byte_count);
}
