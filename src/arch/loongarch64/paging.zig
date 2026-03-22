//! LoongArch64 page table
//! Uses software-managed TLB with multi-level page table
//! Page sizes: 16KB (default for QEMU virt)

pub const page_size: usize = 16384;
pub const page_mask: usize = page_size - 1;

const L0_SHIFT: u6 = 36;
const L1_SHIFT: u6 = 25;
const L2_SHIFT: u6 = 14;
const INDEX_MASK: u64 = 0x7FF;

pub const V: u64 = 1 << 0;
pub const D: u64 = 1 << 1;
pub const PLV_KERNEL: u64 = 0 << 2;
pub const PLV_USER: u64 = 3 << 2;
pub const MAT_CC: u64 = 1 << 4;
pub const MAT_SUC: u64 = 0 << 4;
pub const NR: u64 = @as(u64, 1) << 61;
pub const NX: u64 = @as(u64, 1) << 62;
pub const RPLV: u64 = @as(u64, 1) << 63;

pub const Present: u64 = V;
pub const Write: u64 = D;
pub const User: u64 = PLV_USER;
pub const WriteThrough: u64 = 0;
pub const CacheDisable: u64 = MAT_SUC;
pub const Accessed: u64 = 0;
pub const Dirty: u64 = D;
pub const LargePage: u64 = 0;
pub const Global: u64 = 0;
pub const NoExecute: u64 = NX;

const ADDR_MASK: u64 = 0x0000_FFFF_FFFF_C000;

pub const PageTableEntry = packed struct(u64) {
    raw: u64 = 0,

    pub fn isPresent(self: PageTableEntry) bool {
        return (self.raw & V) != 0;
    }

    pub fn toFrame(self: PageTableEntry) u64 {
        return self.raw & ADDR_MASK;
    }

    pub fn fromFrame(frame: u64, flags: u64) PageTableEntry {
        return .{ .raw = (frame & ADDR_MASK) | flags | V | MAT_CC | PLV_KERNEL };
    }
};

pub const PageTable = struct {
    entries: [2048]PageTableEntry,

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
    const aligned_phys = phys & ADDR_MASK;

    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));

    const l0_idx = v.pml4Index();
    var l0e = &pgd.entries[l0_idx];
    if (!l0e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l0e.* = .{ .raw = (frame & ADDR_MASK) | V };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const l1_table = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    const l1_idx = v.pdptIndex();
    var l1e = &l1_table.entries[l1_idx];
    if (!l1e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l1e.* = .{ .raw = (frame & ADDR_MASK) | V };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const l2_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l2_idx = v.ptIndex();
    var l2e = &l2_table.entries[l2_idx];
    if (l2e.isPresent()) return false;
    l2e.* = PageTableEntry.fromFrame(aligned_phys, flags | D);
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
    asm volatile ("invtlb 0x0, $zero, $zero");
    return true;
}

pub fn loadCr3(phys: u64) void {
    asm volatile ("csrwr %[val], 0x18"
        :
        : [val] "r" (phys)
    );
    asm volatile ("invtlb 0x0, $zero, $zero");
}
