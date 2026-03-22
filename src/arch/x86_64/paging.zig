//! x86_64 四级分页 (4-level paging)
//! PML4 -> PDPT -> PD -> PT -> 4KB Page
//!
//! NT 风格：内核提供映射/解映射机制，策略由用户态服务决定

const PAGE_SIZE: usize = 4096;
const PAGE_MASK: usize = PAGE_SIZE - 1;

/// 页表项标志 (Intel Vol.3 Table 4-12)
pub const Present: u64 = 1 << 0;
pub const Write: u64 = 1 << 1;
pub const User: u64 = 1 << 2;
pub const WriteThrough: u64 = 1 << 3;
pub const CacheDisable: u64 = 1 << 4;
pub const Accessed: u64 = 1 << 5;
pub const Dirty: u64 = 1 << 6; // 仅 PDE/PTE
pub const LargePage: u64 = 1 << 7; // 2MB/1GB 大页
pub const Global: u64 = 1 << 8;
pub const NoExecute: u64 = 1 << 63;

/// 四级页表索引位宽
const PML4_SHIFT: u6 = 39;
const PDPT_SHIFT: u6 = 30;
const PD_SHIFT: u6 = 21;
const PT_SHIFT: u6 = 12;

const PML4_INDEX_MASK: u64 = 0x1FF;
const PDPT_INDEX_MASK: u64 = 0x1FF;
const PD_INDEX_MASK: u64 = 0x1FF;
const PT_INDEX_MASK: u64 = 0x1FF;

/// 页表项 (64 位)
pub const PageTableEntry = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    large: bool = false,
    global: bool = false,
    _reserved1: u3 = 0,
    frame: u40 = 0, // 物理页帧号 (高 40 位)
    _reserved2: u11 = 0,
    no_execute: bool = false,

    pub fn fromFrame(frame: u64, flags: u64) PageTableEntry {
        return .{
            .present = (flags & Present) != 0,
            .writable = (flags & Write) != 0,
            .user = (flags & User) != 0,
            .write_through = (flags & WriteThrough) != 0,
            .cache_disable = (flags & CacheDisable) != 0,
            .accessed = (flags & Accessed) != 0,
            .dirty = (flags & Dirty) != 0,
            .large = (flags & LargePage) != 0,
            .global = (flags & Global) != 0,
            .frame = @as(u40, @truncate(frame >> 12)),
            .no_execute = (flags & NoExecute) != 0,
        };
    }

    pub fn toFrame(self: PageTableEntry) u64 {
        return @as(u64, self.frame) << 12;
    }

    pub fn isPresent(self: PageTableEntry) bool {
        return self.present;
    }
};

/// 页表：512 个条目
pub const PageTable = struct {
    entries: [512]PageTableEntry,

    pub fn zero(self: *PageTable) void {
        for (&self.entries) |*e| e.* = .{};
    }
};

/// 虚拟地址分解
pub const VirtAddr = struct {
    value: u64,

    pub fn pml4Index(self: VirtAddr) u9 {
        return @as(u9, @truncate((self.value >> PML4_SHIFT) & PML4_INDEX_MASK));
    }
    pub fn pdptIndex(self: VirtAddr) u9 {
        return @as(u9, @truncate((self.value >> PDPT_SHIFT) & PDPT_INDEX_MASK));
    }
    pub fn pdIndex(self: VirtAddr) u9 {
        return @as(u9, @truncate((self.value >> PD_SHIFT) & PD_INDEX_MASK));
    }
    pub fn ptIndex(self: VirtAddr) u9 {
        return @as(u9, @truncate((self.value >> PT_SHIFT) & PT_INDEX_MASK));
    }
    pub fn offset(self: VirtAddr) u12 {
        return @as(u12, @truncate(self.value & PAGE_MASK));
    }
};

/// 物理地址
pub const PhysAddr = struct {
    value: u64,

    pub fn frameNumber(self: PhysAddr) u64 {
        return self.value >> 12;
    }
    pub fn alignDown(self: *PhysAddr) void {
        self.value &= ~PAGE_MASK;
    }
};

/// 分配帧回调：传入 ctx，返回物理地址或 null
pub const AllocFrameFn = *const fn (?*anyopaque) ?u64;

/// 将物理地址映射到虚拟地址
/// pml4: 顶级页表物理地址（需已 identity map 或可访问）
/// virt: 虚拟地址
/// phys: 物理地址
/// flags: 页表项标志
/// 若中间表不存在则分配新页（需通过 alloc_frame 回调）
pub fn mapPage(
    pml4_phys: u64,
    virt: u64,
    phys: u64,
    flags: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    var p = PhysAddr{ .value = phys };
    p.alignDown();

    // 需要将 pml4_phys 转为可访问的虚拟地址
    // 在启用分页前，我们使用 identity mapping，故物理地址即虚拟地址
    const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));

    const pml4e_idx = v.pml4Index();
    var pml4e = &pml4.entries[pml4e_idx];
    if (!pml4e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        pml4e.* = PageTableEntry.fromFrame(frame, Present | Write);
        pml4e.accessed = true;
        const pdpt = @as(*PageTable, @ptrFromInt(frame));
        pdpt.zero();
    }
    const pdpt = @as(*PageTable, @ptrFromInt(pml4e.toFrame()));
    const pdpte_idx = v.pdptIndex();
    var pdpte = &pdpt.entries[pdpte_idx];
    if (!pdpte.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        pdpte.* = PageTableEntry.fromFrame(frame, Present | Write);
        pdpte.accessed = true;
        const pd = @as(*PageTable, @ptrFromInt(frame));
        pd.zero();
    }
    const pd = @as(*PageTable, @ptrFromInt(pdpte.toFrame()));
    const pde_idx = v.pdIndex();
    var pde = &pd.entries[pde_idx];
    if (!pde.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        pde.* = PageTableEntry.fromFrame(frame, Present | Write);
        pde.accessed = true;
        const pt = @as(*PageTable, @ptrFromInt(frame));
        pt.zero();
    }
    const pt = @as(*PageTable, @ptrFromInt(pde.toFrame()));
    const pte_idx = v.ptIndex();
    var pte = &pt.entries[pte_idx];
    if (pte.isPresent()) return false; // 已映射
    pte.* = PageTableEntry.fromFrame(p.value, flags | Present);
    pte.accessed = true;
    return true;
}

/// 取消映射
pub fn unmapPage(pml4_phys: u64, virt: u64) bool {
    const v = VirtAddr{ .value = virt };
    const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));
    const pml4e = &pml4.entries[v.pml4Index()];
    if (!pml4e.isPresent()) return false;
    const pdpt = @as(*PageTable, @ptrFromInt(pml4e.toFrame()));
    const pdpte = &pdpt.entries[v.pdptIndex()];
    if (!pdpte.isPresent()) return false;
    const pd = @as(*PageTable, @ptrFromInt(pdpte.toFrame()));
    const pde = &pd.entries[v.pdIndex()];
    if (!pde.isPresent()) return false;
    const pt = @as(*PageTable, @ptrFromInt(pde.toFrame()));
    const pte = &pt.entries[v.ptIndex()];
    if (!pte.isPresent()) return false;
    pte.* = .{};
    return true;
}

/// 加载 CR3
pub fn loadCr3(phys: u64) void {
    asm volatile ("mov %[phys], %%cr3"
        :
        : [phys] "r" (phys)
        : .{ .memory = true }
    );
}

/// 读取 CR3
pub fn readCr3() u64 {
    return asm ("mov %%cr3, %[result]"
        : [result] "=r" (-> u64)
    );
}

/// 刷新 TLB 中单页
pub fn invlpg(virt: u64) void {
    asm volatile ("invlpg [%[addr]]"
        :
        : [addr] "r" (virt)
        : .{ .memory = true }
    );
}

/// 刷新整个 TLB
pub fn flushTlb() void {
    loadCr3(readCr3());
}

pub const page_size = PAGE_SIZE;
pub const page_mask = PAGE_MASK;
