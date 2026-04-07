//! AArch64 4-level page table (4KB granule)
//! L0 (PGD) -> L1 (PUD) -> L2 (PMD) -> L3 (PTE) -> 4KB page
//! Uses TTBR0_EL1 for user space, TTBR1_EL1 for kernel space

pub const page_size: usize = 4096;
pub const page_mask: usize = page_size - 1;

const L0_SHIFT: u6 = 39;
const L1_SHIFT: u6 = 30;
const L2_SHIFT: u6 = 21;
const L3_SHIFT: u6 = 12;
const INDEX_MASK: u64 = 0x1FF;

pub const Valid: u64 = 1 << 0;
pub const Table: u64 = 1 << 1;
pub const Page: u64 = (1 << 1) | (1 << 0);
pub const AttrIdx_Normal: u64 = 0 << 2;
pub const AttrIdx_Device: u64 = 1 << 2;
pub const AP_RW_EL1: u64 = 0 << 6;
pub const AP_RW_ALL: u64 = 1 << 6;
pub const SH_Inner: u64 = 3 << 8;
pub const AF: u64 = 1 << 10;
pub const PXN: u64 = @as(u64, 1) << 53;
pub const UXN: u64 = @as(u64, 1) << 54;

/// 2MiB block descriptor at L2 (ARM DDI 0487: D5-16 "Block descriptor").
pub const HUGE_PAGE_SIZE: usize = 2 * 1024 * 1024;

pub const Present: u64 = Valid;
pub const Write: u64 = AP_RW_EL1;
pub const User: u64 = AP_RW_ALL;
pub const WriteThrough: u64 = 0;
/// 当前用作 PTE AttrIdx=1。须与 `MAIR_EL1` 条目一致；未初始化 MAIR 时勿对 **DRAM** 帧缓冲使用（会成 Device 属性 → 大块 memcpy 可能异常）。
pub const CacheDisable: u64 = AttrIdx_Device;
pub const Accessed: u64 = AF;
pub const Dirty: u64 = 0;
pub const LargePage: u64 = 0;
pub const Global: u64 = 0;
pub const NoExecute: u64 = PXN | UXN;

/// PGD[0..256) is user half; PGD[256..512) is kernel half.
pub const user_half_l0_end_exclusive: usize = 256;
pub const kernel_linked_l0_begin: usize = user_half_l0_end_exclusive;

const ADDR_MASK: u64 = 0x0000_FFFF_FFFF_F000;

pub const PageTableEntry = packed struct(u64) {
    raw: u64 = 0,

    pub fn isPresent(self: PageTableEntry) bool {
        return (self.raw & Valid) != 0;
    }

    pub fn toFrame(self: PageTableEntry) u64 {
        return self.raw & ADDR_MASK;
    }

    pub fn fromFrame(frame: u64, flags: u64) PageTableEntry {
        return .{ .raw = (frame & ADDR_MASK) | flags | Valid | AF | SH_Inner | AttrIdx_Normal };
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
        return @truncate((self.value >> L0_SHIFT) & INDEX_MASK);
    }
    pub fn pdptIndex(self: VirtAddr) u9 {
        return @truncate((self.value >> L1_SHIFT) & INDEX_MASK);
    }
    pub fn pdIndex(self: VirtAddr) u9 {
        return @truncate((self.value >> L2_SHIFT) & INDEX_MASK);
    }
    pub fn ptIndex(self: VirtAddr) u9 {
        return @truncate((self.value >> L3_SHIFT) & INDEX_MASK);
    }
};

pub const AllocFrameFn = *const fn (?*anyopaque) ?u64;

pub fn mapPage(
    pgd_phys: u64,
    virt: u64,
    phys: u64,
    flags: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const aligned_phys = phys & ADDR_MASK;

    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));

    const l0_idx = v.pml4Index();
    var l0e = &pgd.entries[l0_idx];
    if (!l0e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l0e.* = .{ .raw = (frame & ADDR_MASK) | Valid | Table };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const pud = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    const l1_idx = v.pdptIndex();
    var l1e = &pud.entries[l1_idx];
    if (!l1e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l1e.* = .{ .raw = (frame & ADDR_MASK) | Valid | Table };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const pmd = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l2_idx = v.pdIndex();
    var l2e = &pmd.entries[l2_idx];
    if (!l2e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l2e.* = .{ .raw = (frame & ADDR_MASK) | Valid | Table };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const pt = @as(*PageTable, @ptrFromInt(l2e.toFrame()));
    const l3_idx = v.ptIndex();
    var l3e = &pt.entries[l3_idx];
    if (l3e.isPresent()) return false;
    l3e.* = PageTableEntry.fromFrame(aligned_phys, flags | Page);
    return true;
}

pub fn unmapPage(pgd_phys: u64, virt: u64, _: AllocFrameFn, _: ?*anyopaque) bool {
    const v = VirtAddr{ .value = virt };
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));
    const l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) return false;
    const pud = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    const l1e = &pud.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return false;
    const pmd = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l2e = &pmd.entries[v.pdIndex()];
    if (!l2e.isPresent()) return false;
    const pt = @as(*PageTable, @ptrFromInt(l2e.toFrame()));
    const l3e = &pt.entries[v.ptIndex()];
    if (!l3e.isPresent()) return false;
    l3e.* = .{};
    tlbiVmalle1();
    return true;
}

pub fn loadCr3(phys: u64) void {
    asm volatile ("msr ttbr0_el1, %[phys]\ntlbi vmalle1\ndsb sy\nisb"
        :
        : [phys] "r" (phys),
    );
}

fn tlbiVmalle1() void {
    asm volatile ("tlbi vmalle1\ndsb sy\nisb");
}

pub fn translateVirtualToPhysical(pgd_phys: u64, virt: u64) ?u64 {
    const v = VirtAddr{ .value = virt };
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));
    const l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) return null;
    const pud = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    const l1e = &pud.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return null;
    const pmd = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l2e = &pmd.entries[v.pdIndex()];
    if (!l2e.isPresent()) return null;
    // L2 block descriptor (2MiB)
    if (isBlockDescriptor(l2e.raw)) {
        const block_mask: u64 = HUGE_PAGE_SIZE - 1;
        return l2e.toFrame() | (virt & block_mask);
    }
    const pt = @as(*PageTable, @ptrFromInt(l2e.toFrame()));
    const l3e = &pt.entries[v.ptIndex()];
    if (!l3e.isPresent()) return null;
    return l3e.toFrame() | (virt & page_mask);
}

fn isBlockDescriptor(raw: u64) bool {
    return (raw & Valid) != 0 and (raw & Table) == 0;
}

fn isUserLeaf(raw: u64) bool {
    return (raw & Valid) != 0 and (raw & AP_RW_ALL) != 0;
}

pub const FreeFrameFn = *const fn (?*anyopaque, u64) void;

/// Map a 2MiB block at L2 (virt and phys must be 2MiB-aligned).
pub fn map2MiBPage(
    pgd_phys: u64,
    virt: u64,
    phys: u64,
    flags: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));

    var l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l0e.* = .{ .raw = (frame & ADDR_MASK) | Valid | Table };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const pud = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    var l1e = &pud.entries[v.pdptIndex()];
    if (!l1e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l1e.* = .{ .raw = (frame & ADDR_MASK) | Valid | Table };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const pmd = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    var l2e = &pmd.entries[v.pdIndex()];
    if (l2e.isPresent()) return false;

    // Block descriptor: bit[1]=0, bit[0]=1 (Valid but not Table)
    const block_addr = phys & ~@as(u64, HUGE_PAGE_SIZE - 1);
    l2e.* = .{ .raw = block_addr | flags | Valid | AF | SH_Inner | AttrIdx_Normal };
    return true;
}

fn releasePtTable(pt_phys: u64, free_frame: FreeFrameFn, ctx: ?*anyopaque) void {
    const pt = @as(*PageTable, @ptrFromInt(pt_phys));
    for (&pt.entries) |*e| {
        if (e.isPresent()) {
            free_frame(ctx, e.toFrame());
        }
    }
    free_frame(ctx, pt_phys);
}

fn releasePmdTable(pmd_phys: u64, free_frame: FreeFrameFn, ctx: ?*anyopaque) void {
    const pmd = @as(*PageTable, @ptrFromInt(pmd_phys));
    for (&pmd.entries) |*e| {
        if (!e.isPresent()) continue;
        if (isBlockDescriptor(e.raw)) {
            // 2MiB block: free the physical block itself (not a table)
        } else {
            releasePtTable(e.toFrame(), free_frame, ctx);
        }
    }
    free_frame(ctx, pmd_phys);
}

fn releasePudTable(pud_phys: u64, free_frame: FreeFrameFn, ctx: ?*anyopaque) void {
    const pud = @as(*PageTable, @ptrFromInt(pud_phys));
    for (&pud.entries) |*e| {
        if (!e.isPresent()) continue;
        releasePmdTable(e.toFrame(), free_frame, ctx);
    }
    free_frame(ctx, pud_phys);
}

/// Release user half of the address space: PGD[0..256).
/// Kernel half PGD[256..512) is shared and must not be freed.
pub fn releaseUserHalfAddressSpace(pgd_phys: u64, free_frame: FreeFrameFn, ctx: ?*anyopaque) void {
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));
    var i: usize = 0;
    while (i < user_half_l0_end_exclusive) : (i += 1) {
        var l0e = &pgd.entries[i];
        if (!l0e.isPresent()) continue;
        releasePudTable(l0e.toFrame(), free_frame, ctx);
        l0e.* = .{};
    }
}

/// Enumerate all user 4KiB present leaf pages in PGD[0..256).
/// Callback returns false to abort; function returns false if aborted.
pub fn forEachUser4KiPresentLeaf(
    pgd_phys: u64,
    ctx: ?*anyopaque,
    cb: *const fn (ctx: ?*anyopaque, virt: u64, phys: u64, pte_raw: u64) bool,
) bool {
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));
    var l0i: usize = 0;
    while (l0i < user_half_l0_end_exclusive) : (l0i += 1) {
        const l0e = pgd.entries[l0i];
        if (!l0e.isPresent()) continue;
        const pud = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
        var l1i: usize = 0;
        while (l1i < 512) : (l1i += 1) {
            const l1e = pud.entries[l1i];
            if (!l1e.isPresent()) continue;
            const pmd = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
            var l2i: usize = 0;
            while (l2i < 512) : (l2i += 1) {
                const l2e = pmd.entries[l2i];
                if (!l2e.isPresent()) continue;
                if (isBlockDescriptor(l2e.raw)) continue;
                const pt = @as(*PageTable, @ptrFromInt(l2e.toFrame()));
                var l3i: usize = 0;
                while (l3i < 512) : (l3i += 1) {
                    const l3e = pt.entries[l3i];
                    if (!l3e.isPresent()) continue;
                    if (!isUserLeaf(l3e.raw)) continue;
                    const virt = (@as(u64, @intCast(l0i)) << L0_SHIFT) |
                        (@as(u64, @intCast(l1i)) << L1_SHIFT) |
                        (@as(u64, @intCast(l2i)) << L2_SHIFT) |
                        (@as(u64, @intCast(l3i)) << L3_SHIFT);
                    if (!cb(ctx, virt, l3e.toFrame(), l3e.raw)) return false;
                }
            }
        }
    }
    return true;
}
