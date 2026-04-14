// Copyright (c) 2024 Mobtgzhang <mobtgzhang@outlook.com>
//
// ZirconOS
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; either
// version 2.1 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public
// License along with this library; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

//! RISC-V 64 Sv39 page table (3-level, 4KB pages)
//! VPN[2] -> VPN[1] -> VPN[0] -> 4KB page
//! Uses SATP register for page table base
//!
//! Sv39 支持：只有 4KiB 页面，不支持 2MiB/1GiB 大页
//! RISC-V MMU walk: PPN[2] -> PPN[1] -> PPN[0] -> 4KB physical

const builtin = @import("builtin");

pub const page_size: usize = 4096;
pub const page_mask: usize = page_size - 1;

const VPN2_SHIFT: u6 = 30;
const VPN1_SHIFT: u6 = 21;
const VPN0_SHIFT: u6 = 12;
const VPN_MASK: u64 = 0x1FF;

pub const V: u64 = 1 << 0;
pub const R: u64 = 1 << 1;
pub const W: u64 = 1 << 2;
pub const X: u64 = 1 << 3;
pub const U: u64 = 1 << 4;
pub const G: u64 = 1 << 5;
pub const A: u64 = 1 << 6;
pub const D: u64 = 1 << 7;

pub const Present: u64 = V;
pub const Write: u64 = W;
pub const User: u64 = U;
pub const WriteThrough: u64 = 0;
pub const CacheDisable: u64 = 0;
pub const Accessed: u64 = A;
pub const Dirty: u64 = D;
pub const LargePage: u64 = 0;
pub const Global: u64 = G;
pub const NoExecute: u64 = 0;

const PPN_MASK: u64 = 0x003F_FFFF_FFFF_FC00;

/// 最近一次 loadCr3 写入 SATP 的根表物理地址；相等时可跳过 sfence.vma。
var last_loaded_pgdl_phys: u64 = 0xFFFF_FFFF_FFFF_FFFF;

fn ppnToAddr(ppn: u64) u64 {
    return (ppn >> 10) << 12;
}

fn addrToPpn(addr: u64) u64 {
    return (addr >> 12) << 10;
}

pub const PageTableEntry = packed struct(u64) {
    raw: u64 = 0,

    pub fn isPresent(self: PageTableEntry) bool {
        return (self.raw & V) != 0;
    }

    pub fn isLeaf(self: PageTableEntry) bool {
        return (self.raw & (R | W | X)) != 0;
    }

    pub fn toFrame(self: PageTableEntry) u64 {
        return ppnToAddr(self.raw & PPN_MASK);
    }

    pub fn fromFrame(frame: u64, flags: u64) PageTableEntry {
        return .{ .raw = addrToPpn(frame) | flags | V | A | D | R };
    }
};

pub const PageTable = struct {
    entries: [512]PageTableEntry,

    pub fn zero(self: *PageTable) void {
        for (&self.entries) |*e| e.* = .{};
    }
};

pub const VirtAddr = struct {
    value: u64,

    pub fn pml4Index(self: VirtAddr) u9 {
        return @truncate((self.value >> VPN2_SHIFT) & VPN_MASK);
    }
    pub fn pdptIndex(self: VirtAddr) u9 {
        return @truncate((self.value >> VPN1_SHIFT) & VPN_MASK);
    }
    /// Sv39 alias: same as pdptIndex (three-level walk only uses pml4/pdpt/pt).
    pub fn pdIndex(self: VirtAddr) u9 {
        return @truncate((self.value >> VPN0_SHIFT) & VPN_MASK);
    }
    pub fn ptIndex(self: VirtAddr) u9 {
        return @truncate((self.value >> VPN0_SHIFT) & VPN_MASK);
    }
};

pub const AllocFrameFn = *const fn (?*anyopaque) ?u64;

pub fn mapPage(
    root_phys: u64,
    virt: u64,
    phys: u64,
    flags: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const aligned_phys = phys & ~@as(u64, page_mask);

    const root = @as(*PageTable, @ptrFromInt(root_phys));

    const vpn2 = v.pml4Index();
    var l2e = &root.entries[vpn2];
    if (!l2e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l2e.* = .{ .raw = addrToPpn(frame) | V };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const l1_table = @as(*PageTable, @ptrFromInt(l2e.toFrame()));
    const vpn1 = v.pdptIndex();
    var l1e = &l1_table.entries[vpn1];
    if (!l1e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l1e.* = .{ .raw = addrToPpn(frame) | V };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const l0_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const vpn0 = v.ptIndex();
    var l0e = &l0_table.entries[vpn0];
    if (l0e.isPresent()) return false;
    l0e.* = PageTableEntry.fromFrame(aligned_phys, flags | W | X);
    return true;
}

pub fn unmapPage(root_phys: u64, virt: u64, _: AllocFrameFn, _: ?*anyopaque) bool {
    const v = VirtAddr{ .value = virt };
    const root = @as(*PageTable, @ptrFromInt(root_phys));
    const l2e = &root.entries[v.pml4Index()];
    if (!l2e.isPresent()) return false;
    const l1_table = @as(*PageTable, @ptrFromInt(l2e.toFrame()));
    const l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return false;
    const l0_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l0e = &l0_table.entries[v.ptIndex()];
    if (!l0e.isPresent()) return false;
    l0e.* = .{};
    // 仅在当前加载的页表时才需要刷新 TLB
    if (root_phys == last_loaded_pgdl_phys) {
        asm volatile ("sfence.vma zero, zero");
    }
    return true;
}

pub fn loadCr3(phys: u64) void {
    if (builtin.os.tag != .freestanding) return;
    if (phys == last_loaded_pgdl_phys) return;
    const ppn = phys >> 12;
    const satp_val: u64 = (8 << 60) | ppn;
    asm volatile ("csrw satp, %[val]"
        :
        : [val] "r" (satp_val),
    );
    asm volatile ("sfence.vma zero, zero");
    last_loaded_pgdl_phys = phys;
}

pub fn translateVirtualToPhysical(root_phys: u64, virt: u64) ?u64 {
    const v = VirtAddr{ .value = virt };
    const root = @as(*PageTable, @ptrFromInt(root_phys));
    const l2e = &root.entries[v.pml4Index()];
    if (!l2e.isPresent()) return null;
    const l1_table = @as(*PageTable, @ptrFromInt(l2e.toFrame()));
    const l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return null;
    const l0_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l0e = &l0_table.entries[v.ptIndex()];
    if (!l0e.isPresent()) return null;
    return l0e.toFrame() | (virt & page_mask);
}

/// 刷新 TLB（单条目或全条目）
pub fn invlpg(virt: u64) void {
    _ = virt;
    flushTlb();
}

pub fn flushTlb() void {
    if (builtin.os.tag != .freestanding) return;
    asm volatile ("sfence.vma zero, zero");
}

/// 释放回调：phys 为 4KiB 对齐物理地址
pub const FreeFrameFn = *const fn (ctx: ?*anyopaque, phys: u64) void;

fn releasePtTable(pt_phys: u64, free_frame: FreeFrameFn, ctx: ?*anyopaque) void {
    const pt = @as(*PageTable, @ptrFromInt(pt_phys));
    for (&pt.entries) |*pte| {
        if (!pte.isPresent()) continue;
        free_frame(ctx, pte.toFrame());
        pte.* = .{};
    }
    free_frame(ctx, pt_phys);
}

fn releasePdAll(pd_phys: u64, free_frame: FreeFrameFn, ctx: ?*anyopaque) void {
    const pd = @as(*PageTable, @ptrFromInt(pd_phys));
    for (&pd.entries) |*pde| {
        if (!pde.isPresent()) continue;
        releasePtTable(pde.toFrame(), free_frame, ctx);
        pde.* = .{};
    }
    free_frame(ctx, pd_phys);
}

fn releasePdptAll(pdpt_phys: u64, free_frame: FreeFrameFn, ctx: ?*anyopaque) void {
    const pdpt = @as(*PageTable, @ptrFromInt(pdpt_phys));
    for (&pdpt.entries) |*pdpte| {
        if (!pdpte.isPresent()) continue;
        releasePdAll(pdpte.toFrame(), free_frame, ctx);
        pdpte.* = .{};
    }
    free_frame(ctx, pdpt_phys);
}

/// 释放 PML4 用户子树（索引 0..255，即低半区用户空间）
pub fn releaseUserHalfAddressSpace(pml4_phys: u64, free_frame: FreeFrameFn, ctx: ?*anyopaque) void {
    const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var pml4e = &pml4.entries[i];
        if (!pml4e.isPresent()) continue;
        const pdpt_phys = pml4e.toFrame();
        releasePdptAll(pdpt_phys, free_frame, ctx);
        pml4e.* = .{};
    }
}

/// 枚举 PML4[0..256) 下 4KiB 用户叶（Present 且 User）
pub fn forEachUser4KiPresentLeaf(
    pml4_phys: u64,
    ctx: ?*anyopaque,
    cb: *const fn (ctx: ?*anyopaque, virt: u64, phys: u64, pte_raw: u64) bool,
) bool {
    const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));
    var p4: usize = 0;
    while (p4 < 256) : (p4 += 1) {
        const pml4e = &pml4.entries[p4];
        if (!pml4e.isPresent()) continue;
        const pdpt = @as(*PageTable, @ptrFromInt(pml4e.toFrame()));
        var p3: usize = 0;
        while (p3 < 512) : (p3 += 1) {
            const pdpte = &pdpt.entries[p3];
            if (!pdpte.isPresent()) continue;
            const pd = @as(*PageTable, @ptrFromInt(pdpte.toFrame()));
            var p2: usize = 0;
            while (p2 < 512) : (p2 += 1) {
                const pde = &pd.entries[p2];
                if (!pde.isPresent()) continue;
                const pt = @as(*PageTable, @ptrFromInt(pde.toFrame()));
                var p1: usize = 0;
                while (p1 < 512) : (p1 += 1) {
                    const pte = &pt.entries[p1];
                    if (!pte.isPresent() or !pte.user) continue;
                    const virt = (@as(u64, @intCast(p4)) << VPN2_SHIFT) |
                        (@as(u64, @intCast(p3)) << VPN1_SHIFT) |
                        (@as(u64, @intCast(p2)) << VPN0_SHIFT) |
                        (@as(u64, @intCast(p1)) << 12);
                    const phys = pte.toFrame();
                    const pte_raw = pte.raw;
                    if (!cb(ctx, virt, phys, pte_raw)) return false;
                }
            }
        }
    }
    return true;
}

/// 枚举 2MiB 用户大页（Sv39 不支持，但提供空实现以保持接口兼容）
pub fn forEachUser2MiPresentLeaf(
    pml4_phys: u64,
    ctx: ?*anyopaque,
    cb: *const fn (ctx: ?*anyopaque, virt: u64, phys: u64, pte_raw: u64) bool,
) bool {
    _ = pml4_phys;
    _ = ctx;
    _ = cb;
    // Sv39 不支持 2MiB 大页，直接返回
    return true;
}

/// 更新已存在 4KiB 叶映射的保护位
pub fn protectLeafPage(
    pml4_phys: u64,
    virt: u64,
    flags: u64,
    _: AllocFrameFn,
    _: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));
    const l2e = &pml4.entries[v.pml4Index()];
    if (!l2e.isPresent()) return false;
    const l1_table = @as(*PageTable, @ptrFromInt(l2e.toFrame()));
    const l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return false;
    const l0_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l0e = &l0_table.entries[v.ptIndex()];
    if (!l0e.isPresent()) return false;
    const frame = l0e.toFrame();
    l0e.* = PageTableEntry{ .raw = addrToPpn(frame) | flags | V | A | D | R };
    invlpg(virt);
    return true;
}

/// 将已存在 4KiB 叶的物理帧替换为 new_phys（CoW 写分裂）
pub fn remapLeafPhysical(
    pml4_phys: u64,
    virt: u64,
    new_phys: u64,
    flags: u64,
    _: AllocFrameFn,
    _: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));
    const l2e = &pml4.entries[v.pml4Index()];
    if (!l2e.isPresent()) return false;
    const l1_table = @as(*PageTable, @ptrFromInt(l2e.toFrame()));
    const l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return false;
    const l0_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l0e = &l0_table.entries[v.ptIndex()];
    if (!l0e.isPresent()) return false;
    const merged = flags | V | A | D | R;
    l0e.* = PageTableEntry{ .raw = addrToPpn(new_phys) | merged };
    invlpg(virt);
    return true;
}
