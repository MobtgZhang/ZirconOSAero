//! MIPS64EL page table
//! Software-managed TLB with multi-level page table
//! Page size: 4KB, using CP0 TLB instructions

pub const page_size: usize = 4096;
pub const page_mask: usize = page_size - 1;

const L0_SHIFT: u6 = 30;
const L1_SHIFT: u6 = 21;
const L2_SHIFT: u6 = 12;
const INDEX_MASK: u64 = 0x1FF;

pub const V: u64 = 1 << 1;
pub const D_BIT: u64 = 1 << 2;
pub const C_CACHED: u64 = 3 << 3;
pub const C_UNCACHED: u64 = 2 << 3;
pub const G_BIT: u64 = 1 << 0;

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

const PFN_MASK: u64 = 0x03FF_FFFF_FFFF_F000;

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
        return @truncate((self.value >> L1_SHIFT) & INDEX_MASK);
    }
    pub fn ptIndex(self: VirtAddr) u9 {
        return @truncate((self.value >> L2_SHIFT) & INDEX_MASK);
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
    const aligned_phys = phys & ~@as(u64, page_mask);

    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));

    const l0_idx = v.pml4Index();
    var l0e = &pgd.entries[l0_idx];
    if (!l0e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l0e.* = .{ .raw = ((frame >> 12) << 6) | V | C_CACHED };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const l1_table = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    const l1_idx = v.pdptIndex();
    var l1e = &l1_table.entries[l1_idx];
    if (!l1e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l1e.* = .{ .raw = ((frame >> 12) << 6) | V | C_CACHED };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const l2_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l2_idx = v.ptIndex();
    var l2e = &l2_table.entries[l2_idx];
    if (l2e.isPresent()) return false;
    l2e.* = PageTableEntry.fromFrame(aligned_phys, flags | D_BIT);
    return true;
}

pub fn unmapPage(pgd_phys: u64, virt: u64) bool {
    const v = VirtAddr{ .value = virt };
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));
    const l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) return false;
    const l1_table = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    const l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return false;
    const l2_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l2e = &l2_table.entries[v.ptIndex()];
    if (!l2e.isPresent()) return false;
    l2e.* = .{};
    return true;
}

pub fn loadCr3(_: u64) void {}
