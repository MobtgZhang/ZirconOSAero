//! MIPS64EL software-managed TLB with three-level page table.
//! Page size: 4KiB, 512 entries per level (9 bits per index).
//! PTE format follows MIPS EntryLo: PFN in bits [29:6], flags in bits [5:0].

const builtin = @import("builtin");
const is_freestanding = (builtin.os.tag == .freestanding);

pub const page_size: usize = 4096;
pub const page_mask: usize = page_size - 1;

const L0_SHIFT: u6 = 30;
const L1_SHIFT: u6 = 21;
const L2_SHIFT: u6 = 12;
const INDEX_MASK: u64 = 0x1FF;

// MIPS EntryLo flag bits
pub const G_BIT: u64 = 1 << 0;
pub const V: u64 = 1 << 1;
pub const D_BIT: u64 = 1 << 2;
pub const C_CACHED: u64 = 3 << 3;
pub const C_UNCACHED: u64 = 2 << 3;
pub const C_MASK: u64 = 7 << 3;

// Aliases matching the vm.zig contract
pub const Present: u64 = V;
pub const Write: u64 = D_BIT;
pub const User: u64 = 0;
pub const WriteThrough: u64 = 0;
pub const CacheDisable: u64 = C_UNCACHED;
pub const Accessed: u64 = 0;
pub const Dirty: u64 = D_BIT;
pub const LargePage: u64 = 0;
pub const Global: u64 = G_BIT;
pub const NoExecute: u64 = 0;

/// User half: L0 indices [0..256), kernel: [256..512).
pub const user_half_l0_end_exclusive: u9 = 256;
pub const kernel_linked_l0_begin: u9 = 256;

pub const PageTableEntry = packed struct(u64) {
    raw: u64 = 0,

    pub fn isPresent(self: PageTableEntry) bool {
        return (self.raw & V) != 0;
    }

    pub fn toFrame(self: PageTableEntry) u64 {
        return (self.raw >> 6) << 12;
    }

    pub fn fromFrame(frame: u64, flags: u64) PageTableEntry {
        const pfn = (frame >> 12) << 6;
        return .{ .raw = pfn | flags | V | C_CACHED };
    }

    pub fn flagBits(self: PageTableEntry) u64 {
        return self.raw & 0x3F;
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
        return @truncate((self.value >> L2_SHIFT) & INDEX_MASK);
    }
};

pub const AllocFrameFn = *const fn (?*anyopaque) ?u64;
/// 与 `vm.freeFrameForRelease` / LoongArch 一致：`(ctx, phys)`。
pub const FreeFrameFn = *const fn (?*anyopaque, u64) void;

var last_loaded_pgd_phys: u64 = 0;

/// Invalidate all TLB entries by writing invalid entries to each slot.
pub fn invtlbAll() void {
    if (!is_freestanding) return;
    // Read Config1.MMUSize to get TLB entry count
    const config1: u32 = asm ("mfc0 %[result], $16, 1"
        : [result] "=r" (-> u32),
    );
    const mmu_size: u32 = ((config1 >> 25) & 0x3F) + 1;
    var i: u32 = 0;
    while (i < mmu_size) : (i += 1) {
        asm volatile (
            "mtc0 %[idx], $0\n" ++
                "ehb\n" ++
                "dmtc0 $zero, $10\n" ++
                "dmtc0 $zero, $2\n" ++
                "dmtc0 $zero, $3\n" ++
                "mtc0  $zero, $5\n" ++
                "ehb\n" ++
                "tlbwi"
            :
            : [idx] "r" (i),
        );
    }
}

/// Invalidate a single TLB entry matching the given virtual address.
pub fn invtlbAddrVa(va: u64) void {
    if (!is_freestanding) return;
    const aligned_va = va & ~@as(u64, 0x1FFF);
    asm volatile ("dmtc0 %[va], $10\n\tehb\n\ttlbp\n\tehb"
        :
        : [va] "r" (aligned_va),
    );
    const idx: i32 = asm ("mfc0 %[o], $0"
        : [o] "=r" (-> i32),
    );
    if (idx < 0) return;
    asm volatile ("dmtc0 $zero, $10\n\tdmtc0 $zero, $2\n\tdmtc0 $zero, $3\n\tehb\n\ttlbwi"
        :
        :
    );
}

/// Switch root page table and flush TLB. Equivalent to x86 CR3 load.
pub fn loadCr3(pgd_phys: u64) void {
    if (!is_freestanding) return;
    if (pgd_phys == last_loaded_pgd_phys) return;
    last_loaded_pgd_phys = pgd_phys;
    // MIPS has no hardware page walker — the TLB refill handler reads our
    // page table in software. We store the root pointer in CP0 Context
    // (PTEBase field, bits [63:23]) so the refill handler can find it.
    const pte_base = pgd_phys & 0xFFFFFFFFFF800000;
    asm volatile (
        "dmtc0 %[val], $4\n" ++
            "ehb"
        :
        : [val] "r" (pte_base),
    );
    invtlbAll();
}

pub fn noteCurrentPageTablePossiblyMutated() void {
    last_loaded_pgd_phys = 0;
}

pub fn mapPage(
    pgd_phys: u64,
    virt: u64,
    phys: u64,
    flags: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const aligned_phys = phys & ~@as(u64, page_mask);

    const pgd: *PageTable = @ptrFromInt(pgd_phys);

    const l0_idx = v.pml4Index();
    const l0e = &pgd.entries[l0_idx];
    if (!l0e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l0e.* = .{ .raw = ((frame >> 12) << 6) | V | C_CACHED };
        const tbl: *PageTable = @ptrFromInt(frame);
        tbl.zero();
    }

    const l1_table: *PageTable = @ptrFromInt(l0e.toFrame());
    const l1_idx = v.pdptIndex();
    const l1e = &l1_table.entries[l1_idx];
    if (!l1e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l1e.* = .{ .raw = ((frame >> 12) << 6) | V | C_CACHED };
        const tbl: *PageTable = @ptrFromInt(frame);
        tbl.zero();
    }

    const l2_table: *PageTable = @ptrFromInt(l1e.toFrame());
    const l2_idx = v.ptIndex();
    const l2e = &l2_table.entries[l2_idx];
    if (l2e.isPresent()) return false;
    l2e.* = PageTableEntry.fromFrame(aligned_phys, flags | D_BIT);
    return true;
}

pub fn unmapPage(pgd_phys: u64, virt: u64, _: AllocFrameFn, _: ?*anyopaque) bool {
    const v = VirtAddr{ .value = virt };
    const pgd: *PageTable = @ptrFromInt(pgd_phys);
    const l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) return false;
    const l1_table: *PageTable = @ptrFromInt(l0e.toFrame());
    const l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return false;
    const l2_table: *PageTable = @ptrFromInt(l1e.toFrame());
    const l2e = &l2_table.entries[v.ptIndex()];
    if (!l2e.isPresent()) return false;
    l2e.* = .{};
    invtlbAddrVa(virt);
    return true;
}

pub fn translateVirtualToPhysical(pgd_phys: u64, virt: u64) ?u64 {
    const v = VirtAddr{ .value = virt };
    const pgd: *PageTable = @ptrFromInt(pgd_phys);
    const l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) return null;
    const l1_table: *PageTable = @ptrFromInt(l0e.toFrame());
    const l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return null;
    const l2_table: *PageTable = @ptrFromInt(l1e.toFrame());
    const l2e = &l2_table.entries[v.ptIndex()];
    if (!l2e.isPresent()) return null;
    return l2e.toFrame() | (virt & page_mask);
}

pub fn protectLeafPage(
    pgd_phys: u64,
    virt: u64,
    flags: u64,
    _: AllocFrameFn,
    _: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const pgd: *PageTable = @ptrFromInt(pgd_phys);
    const l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) return false;
    const l1_table: *PageTable = @ptrFromInt(l0e.toFrame());
    const l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return false;
    const l2_table: *PageTable = @ptrFromInt(l1e.toFrame());
    const l2e = &l2_table.entries[v.ptIndex()];
    if (!l2e.isPresent()) return false;
    const phys = l2e.toFrame();
    const merged = flags | Present | Accessed;
    l2e.* = PageTableEntry.fromFrame(phys, merged);
    invtlbAddrVa(virt);
    return true;
}

pub fn remapLeafPhysical(
    pgd_phys: u64,
    virt: u64,
    new_phys: u64,
    flags: u64,
    _: AllocFrameFn,
    _: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const aligned = new_phys & ~@as(u64, page_mask);
    const pgd: *PageTable = @ptrFromInt(pgd_phys);
    const l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) return false;
    const l1_table: *PageTable = @ptrFromInt(l0e.toFrame());
    const l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return false;
    const l2_table: *PageTable = @ptrFromInt(l1e.toFrame());
    const l2e = &l2_table.entries[v.ptIndex()];
    if (!l2e.isPresent()) return false;
    l2e.* = PageTableEntry.fromFrame(aligned, flags | D_BIT);
    invtlbAddrVa(virt);
    return true;
}

/// Release user-half page tables (L0 indices 0..user_half_l0_end_exclusive).
pub fn releaseUserHalfAddressSpace(pgd_phys: u64, free_frame: FreeFrameFn, free_ctx: ?*anyopaque) void {
    const pgd: *PageTable = @ptrFromInt(pgd_phys);
    var l0_idx: usize = 0;
    while (l0_idx < user_half_l0_end_exclusive) : (l0_idx += 1) {
        const l0e = &pgd.entries[l0_idx];
        if (!l0e.isPresent()) continue;
        const l1_table: *PageTable = @ptrFromInt(l0e.toFrame());
        var l1_idx: usize = 0;
        while (l1_idx < 512) : (l1_idx += 1) {
            const l1e = &l1_table.entries[l1_idx];
            if (!l1e.isPresent()) continue;
            const l2_phys = l1e.toFrame();
            free_frame(free_ctx, l2_phys);
            l1e.* = .{};
        }
        const l1_phys = l0e.toFrame();
        free_frame(free_ctx, l1_phys);
        l0e.* = .{};
    }
}

/// Walk all present user-half leaf PTEs and invoke callback.
pub fn forEachUser4KiPresentLeaf(
    pgd_phys: u64,
    callback: *const fn (va: u64, pte_raw: u64, ctx: ?*anyopaque) void,
    ctx: ?*anyopaque,
) void {
    const pgd: *PageTable = @ptrFromInt(pgd_phys);
    var l0_idx: u64 = 0;
    while (l0_idx < user_half_l0_end_exclusive) : (l0_idx += 1) {
        const l0e = &pgd.entries[@intCast(l0_idx)];
        if (!l0e.isPresent()) continue;
        const l1_table: *PageTable = @ptrFromInt(l0e.toFrame());
        var l1_idx: u64 = 0;
        while (l1_idx < 512) : (l1_idx += 1) {
            const l1e = &l1_table.entries[@intCast(l1_idx)];
            if (!l1e.isPresent()) continue;
            const l2_table: *PageTable = @ptrFromInt(l1e.toFrame());
            var l2_idx: u64 = 0;
            while (l2_idx < 512) : (l2_idx += 1) {
                const l2e = &l2_table.entries[@intCast(l2_idx)];
                if (!l2e.isPresent()) continue;
                const va = (l0_idx << L0_SHIFT) | (l1_idx << L1_SHIFT) | (l2_idx << L2_SHIFT);
                callback(va, l2e.raw, ctx);
            }
        }
    }
}
