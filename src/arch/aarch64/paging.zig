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

pub const Present: u64 = Valid;
pub const Write: u64 = AP_RW_EL1;
pub const User: u64 = AP_RW_ALL;
pub const WriteThrough: u64 = 0;
pub const CacheDisable: u64 = AttrIdx_Device;
pub const Accessed: u64 = AF;
pub const Dirty: u64 = 0;
pub const LargePage: u64 = 0;
pub const Global: u64 = 0;
pub const NoExecute: u64 = PXN | UXN;

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

pub fn unmapPage(pgd_phys: u64, virt: u64) bool {
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
        : [phys] "r" (phys)
    );
}

fn tlbiVmalle1() void {
    asm volatile ("tlbi vmalle1\ndsb sy\nisb");
}
