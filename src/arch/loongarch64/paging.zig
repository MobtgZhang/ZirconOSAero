//! LoongArch64 page table
//! Uses software-managed TLB with multi-level page table
//! Page sizes: 16KB (default for QEMU virt)

pub const page_size: usize = 16384;
pub const page_mask: usize = page_size - 1;

/// 单张第三级表 2048×16KiB = 32MiB VA；`mapIdentity32MiBlock` 一次填充整块。
pub const identity_bulk_bytes: u64 = 2048 * page_size;

const L0_SHIFT: u6 = 36;
const L1_SHIFT: u6 = 25;
const L2_SHIFT: u6 = 14;
/// 每级 2048 项 → 索引占 **11 位**（勿用 `u9`：512..2047 会截断后与 0..511 别名，identity map 恰在 8MiB 处失败）
const INDEX_MASK: u64 = 0x7FF;

pub const V: u64 = 1 << 0;
pub const D: u64 = 1 << 1;
pub const PLV_KERNEL: u64 = 0 << 2;
pub const PLV_USER: u64 = 3 << 2;
/// MAT[5:4]：0=SUC 强非缓存，1=CC 一致可缓存，2=WUC 弱非缓存（MMIO 常用）
pub const MAT_CC: u64 = 1 << 4;
pub const MAT_SUC: u64 = 0 << 4;
pub const MAT_WUC: u64 = 2 << 4;
pub const MAT_MASK: u64 = 3 << 4;
pub const NR: u64 = @as(u64, 1) << 61;
pub const NX: u64 = @as(u64, 1) << 62;
pub const RPLV: u64 = @as(u64, 1) << 63;

pub const Present: u64 = V;
pub const Write: u64 = D;
pub const User: u64 = PLV_USER;
pub const WriteThrough: u64 = 0;
/// 须为非零 MAT，否则 `fromFrame` 会默认加 CC；`0<<4` 无法与「未指定 MAT」区分
pub const CacheDisable: u64 = MAT_WUC;
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
        var raw = (frame & ADDR_MASK) | flags | V | PLV_KERNEL;
        if ((raw & MAT_MASK) == 0) raw |= MAT_CC;
        return .{ .raw = raw };
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

    pub fn pml4Index(self: VirtAddr) u16 {
        return @truncate((self.value >> L0_SHIFT) & INDEX_MASK);
    }
    pub fn pdptIndex(self: VirtAddr) u16 {
        return @truncate((self.value >> L1_SHIFT) & INDEX_MASK);
    }
    /// 第三级页表索引（与 `ptIndex` 相同位段；仅用于与 x86 命名对齐的 API）
    pub fn pdIndex(self: VirtAddr) u16 {
        return @truncate((self.value >> L2_SHIFT) & INDEX_MASK);
    }
    pub fn ptIndex(self: VirtAddr) u16 {
        return @truncate((self.value >> L2_SHIFT) & INDEX_MASK);
    }
};

/// 遍历三级页表得到叶子物理帧 + 页内偏移（与 `mapPage`/`unmapPage` 一致）
pub fn translateVirtualToPhysical(pgd_phys: u64, virt: u64) ?u64 {
    const v = VirtAddr{ .value = virt };
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));
    const l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) return null;
    const l1 = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    const l1e = &l1.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return null;
    const l2 = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l2e = &l2.entries[v.ptIndex()];
    if (!l2e.isPresent()) return null;
    return l2e.toFrame() | (virt & page_mask);
}

pub const AllocFrameFn = *const fn (?*anyopaque) ?u64;

/// `block_base` 须 32MiB 对齐；整表 identity 映射（减少启动时 `mapPage` 次）。
pub fn mapIdentity32MiBlock(
    pgd_phys: u64,
    block_base: u64,
    flags: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    if ((block_base % identity_bulk_bytes) != 0) return false;
    const v = VirtAddr{ .value = block_base };
    const pgd = @as(*PageTable, @ptrFromInt(pgd_phys));

    var l0e = &pgd.entries[v.pml4Index()];
    if (!l0e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l0e.* = .{ .raw = (frame & ADDR_MASK) | V };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }
    const l1_table = @as(*PageTable, @ptrFromInt(l0e.toFrame()));
    var l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l1e.* = .{ .raw = (frame & ADDR_MASK) | V };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }
    const l2_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    var i: usize = 0;
    while (i < 2048) : (i += 1) {
        if (l2_table.entries[i].isPresent()) return false;
        const virt = block_base + i * page_size;
        l2_table.entries[i] = PageTableEntry.fromFrame(virt, flags | D);
    }
    asm volatile ("invtlb 0x0, $zero, $zero");
    return true;
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

pub fn unmapPage(pgd_phys: u64, virt: u64, _: AllocFrameFn, _: ?*anyopaque) bool {
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
        : [val] "r" (phys),
    );
    asm volatile ("invtlb 0x0, $zero, $zero");
}
