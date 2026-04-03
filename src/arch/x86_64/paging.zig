//! x86_64 四级分页 (4-level paging)
//! PML4 -> PDPT -> PD -> PT -> 4KB Page
//!
//! NT 风格：内核提供映射/解映射机制，策略由用户态服务决定

const builtin = @import("builtin");
const PAGE_SIZE: usize = 4096;
const PAGE_MASK: usize = PAGE_SIZE - 1;

/// 2MiB 大页（PDE.PS=1）。用于启动 identity 映射，减少 PTE 写入次数。
pub const HUGE_PAGE_SIZE: usize = 2 * 1024 * 1024;
pub const huge_page_mask: usize = HUGE_PAGE_SIZE - 1;

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
        // 显式 u64 掩码：避免 `usize` 位宽与 `u64.value` 混算时在非 64 位 `usize` 目标上截断高位。
        const mask: u64 = @intCast(PAGE_MASK);
        self.value &= ~mask;
    }
};

/// 分配帧回调：传入 ctx，返回物理地址或 null
pub const AllocFrameFn = *const fn (?*anyopaque) ?u64;

/// 将 2MiB 大页拆成 512×4KiB（identity，权限继承自大页项）。供 MMIO 等对单页改属性路径使用。
pub fn split2MiBIdentityPageIfNeeded(
    pml4_phys: u64,
    virt: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));
    const pml4e = &pml4.entries[v.pml4Index()];
    if (!pml4e.isPresent()) return true;
    const pdpt = @as(*PageTable, @ptrFromInt(pml4e.toFrame()));
    const pdpte = &pdpt.entries[v.pdptIndex()];
    if (!pdpte.isPresent()) return true;
    const pd = @as(*PageTable, @ptrFromInt(pdpte.toFrame()));
    const pde = &pd.entries[v.pdIndex()];
    if (!pde.isPresent()) return true;
    const praw = @as(u64, @bitCast(pde.*));
    if ((praw & LargePage) == 0) return true;

    const huge_base = virt & ~@as(u64, huge_page_mask);
    var pte_flags: u64 = Present | Accessed;
    if ((praw & Write) != 0) pte_flags |= Write | Dirty;
    if ((praw & User) != 0) pte_flags |= User;
    if ((praw & WriteThrough) != 0) pte_flags |= WriteThrough;
    if ((praw & CacheDisable) != 0) pte_flags |= CacheDisable;
    if ((praw & Global) != 0) pte_flags |= Global;
    if ((praw & NoExecute) != 0) pte_flags |= NoExecute;

    const pt_frame = alloc_frame(alloc_ctx) orelse return false;
    const pt = @as(*PageTable, @ptrFromInt(pt_frame));
    pt.zero();
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        const off = @as(u64, @intCast(i)) * @as(u64, PAGE_SIZE);
        if (huge_base > std.math.maxInt(u64) - off) return false;
        const p = huge_base + off;
        pt.entries[i] = PageTableEntry.fromFrame(p, pte_flags);
    }
    pde.* = PageTableEntry.fromFrame(pt_frame, Present | Write);
    pde.accessed = true;
    invlpg(huge_base);
    return true;
}

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
    if (pde.isPresent()) {
        const praw = @as(u64, @bitCast(pde.*));
        if ((praw & LargePage) != 0) {
            if (!split2MiBIdentityPageIfNeeded(pml4_phys, virt, alloc_frame, alloc_ctx)) return false;
            pde = &pd.entries[pde_idx];
        }
    }
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
    if (pte.isPresent()) {
        // UEFI/引导器已建立恒等叶映射时须视为成功，否则 `mapIdentityByteRange` 整段失败。
        if (pte.toFrame() == p.value and leafPteFlagsMatch(pte.*, flags)) {
            pte.accessed = true;
            return true;
        }
        return false;
    }
    pte.* = PageTableEntry.fromFrame(p.value, flags | Present);
    pte.accessed = true;
    return true;
}

/// 已存在叶项是否与本次 `mapPage` 请求一致（可写/用户/NX）。
/// `Global`、**PAT/CD/WT** 等与固件/MTRR 可能不一致，不强制相等，避免恒等映射卡在大段 4K 回退。
fn leafPteFlagsMatch(pte: PageTableEntry, flags: u64) bool {
    if (!pte.present) return false;
    if (pte.writable != ((flags & Write) != 0)) return false;
    if (pte.user != ((flags & User) != 0)) return false;
    if (pte.no_execute != ((flags & NoExecute) != 0)) return false;
    return true;
}

/// Intel Vol.3 4-14：PDE 在 PS=1 时映射 2MiB；物理地址 = entry[51:21]<<21 | VA[20:0]。
fn encodePde2MiB(phys: u64, flags: u64) u64 {
    const aligned = phys & ~@as(u64, huge_page_mask);
    if (aligned != phys) return 0;
    var e = aligned | Present | LargePage | Accessed;
    if ((flags & Write) != 0) e |= Write | Dirty;
    if ((flags & User) != 0) e |= User;
    if ((flags & WriteThrough) != 0) e |= WriteThrough;
    if ((flags & CacheDisable) != 0) e |= CacheDisable;
    if ((flags & Global) != 0) e |= Global;
    if ((flags & NoExecute) != 0) e |= NoExecute;
    return e;
}

/// 建立 2MiB identity 映射（virt==phys，二者均 2MiB 对齐）。不在 PD 下分配 PT。
pub fn map2MiBPage(
    pml4_phys: u64,
    virt: u64,
    phys: u64,
    flags: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    if (virt != phys) return false;
    if ((virt & huge_page_mask) != 0) return false;
    if ((phys & huge_page_mask) != 0) return false;

    const enc = encodePde2MiB(phys, flags);
    if (enc == 0) return false;

    const v = VirtAddr{ .value = virt };
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
    if (pde.isPresent()) {
        const raw = @as(u64, @bitCast(pde.*));
        if ((raw & LargePage) != 0 and raw == enc) return true;
        return false;
    }
    pde.* = @bitCast(enc);
    return true;
}

/// 取消映射（单 4KiB）。
/// 若 PDE 为 2MiB 大页（PS=1），须先拆成 512×4KiB 再只清除目标 PTE。
/// 旧实现整项清零 PDE 会拆掉整块 2MiB identity，导致相邻内核页突然未映射（VirtIO `remapIdentityVirtPageUncached` 等路径会触发异常风暴）。
pub fn unmapPage(pml4_phys: u64, virt: u64, alloc_frame: AllocFrameFn, alloc_ctx: ?*anyopaque) bool {
    const v = VirtAddr{ .value = virt };
    const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));
    const pml4e = &pml4.entries[v.pml4Index()];
    if (!pml4e.isPresent()) return false;
    const pdpt = @as(*PageTable, @ptrFromInt(pml4e.toFrame()));
    const pdpte = &pdpt.entries[v.pdptIndex()];
    if (!pdpte.isPresent()) return false;
    const pd = @as(*PageTable, @ptrFromInt(pdpte.toFrame()));
    const pde_idx = v.pdIndex();
    var pde = &pd.entries[pde_idx];
    if (!pde.isPresent()) return false;
    const pde_raw = @as(u64, @bitCast(pde.*));
    if ((pde_raw & LargePage) != 0) {
        if (!split2MiBIdentityPageIfNeeded(pml4_phys, virt, alloc_frame, alloc_ctx)) return false;
        pde = &pd.entries[pde_idx];
        if (!pde.isPresent()) return false;
    }
    const pt = @as(*PageTable, @ptrFromInt(pde.toFrame()));
    const pte = &pt.entries[v.ptIndex()];
    if (!pte.isPresent()) return false;
    pte.* = .{};
    invlpg(virt);
    return true;
}

/// 更新已存在 **4KiB 叶** 映射的保护位（`flags` 为 `Present|User|Write|NoExecute` 等）；遇 2MiB PDE 则先拆分。
/// Ref: Intel SDM Vol.3 — PTE 标志；与 `ZwProtectVirtualMemory` 公开语义对齐的硬件侧实现。
pub fn protectLeafPage(
    pml4_phys: u64,
    virt: u64,
    flags: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    if (!split2MiBIdentityPageIfNeeded(pml4_phys, virt, alloc_frame, alloc_ctx)) return false;
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
    const pde_raw = @as(u64, @bitCast(pde.*));
    if ((pde_raw & LargePage) != 0) {
        if (!split2MiBIdentityPageIfNeeded(pml4_phys, virt, alloc_frame, alloc_ctx)) return false;
    }
    const pd2 = @as(*PageTable, @ptrFromInt(pdpte.toFrame()));
    const pde2 = &pd2.entries[v.pdIndex()];
    if (!pde2.isPresent()) return false;
    const pt = @as(*PageTable, @ptrFromInt(pde2.toFrame()));
    const pte = &pt.entries[v.ptIndex()];
    if (!pte.isPresent()) return false;
    const frame = pte.toFrame();
    const merged = flags | Present | Accessed;
    pte.* = PageTableEntry.fromFrame(frame, merged);
    invlpg(virt);
    return true;
}

/// 将已存在 **4KiB 叶** 的物理帧替换为 `new_phys`（CoW 写分裂）；`flags` 为完整叶标志（含 `Write`）。
pub fn remapLeafPhysical(
    pml4_phys: u64,
    virt: u64,
    new_phys: u64,
    flags: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    if (!split2MiBIdentityPageIfNeeded(pml4_phys, virt, alloc_frame, alloc_ctx)) return false;
    const v = VirtAddr{ .value = virt };
    const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));
    const pml4e = &pml4.entries[v.pml4Index()];
    if (!pml4e.isPresent()) return false;
    const pdpt = @as(*PageTable, @ptrFromInt(pml4e.toFrame()));
    const pdpte = &pdpt.entries[v.pdptIndex()];
    if (!pdpte.isPresent()) return false;
    const pd = @as(*PageTable, @ptrFromInt(pdpte.toFrame()));
    const pde2 = &pd.entries[v.pdIndex()];
    if (!pde2.isPresent()) return false;
    const pt = @as(*PageTable, @ptrFromInt(pde2.toFrame()));
    const pte = &pt.entries[v.ptIndex()];
    if (!pte.isPresent()) return false;
    const merged = flags | Present | Accessed;
    pte.* = PageTableEntry.fromFrame(new_phys, merged);
    invlpg(virt);
    return true;
}

/// 加载 CR3
pub fn loadCr3(phys: u64) void {
    if (builtin.os.tag != .freestanding) return;
    asm volatile ("mov %[phys], %%cr3"
        :
        : [phys] "r" (phys),
        : .{ .memory = true });
}

/// 读取 CR3
pub fn readCr3() u64 {
    if (builtin.os.tag != .freestanding) return 0;
    return asm ("mov %%cr3, %[result]"
        : [result] "=r" (-> u64),
    );
}

/// 刷新 TLB 中单页。Zig 0.15+ LLVM 对内联 `invlpg` 内存操作数约束过严，此处退化为全 TLB 刷新（与 `mov cr3` 等价）。
pub fn invlpg(virt: u64) void {
    _ = virt;
    flushTlb();
}

/// 刷新整个 TLB
pub fn flushTlb() void {
    if (builtin.os.tag != .freestanding) return;
    loadCr3(readCr3());
}

/// 释放回调：`phys` 为 4KiB 对齐物理地址（含页表页与匿名数据页）。
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
        const pde_raw = @as(u64, @bitCast(pde.*));
        if ((pde_raw & LargePage) != 0) {
            const base = pde.toFrame();
            var a = base;
            while (a < base + HUGE_PAGE_SIZE) : (a += PAGE_SIZE) {
                free_frame(ctx, a);
            }
        } else {
            releasePtTable(pde.toFrame(), free_frame, ctx);
        }
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

/// 枚举 PML4[0..256) 下 **4KiB 用户叶**（`Present` 且 `User`）。**1GiB / 2MiB 大页**当前跳过（fork 子集不展开大页；见 `duplicateUserMappingsForFork` 注释）。
/// 回调返回 `false` 时中止遍历并令本函数返回 `false`。
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
            const pdpte_raw = @as(u64, @bitCast(pdpte.*));
            if ((pdpte_raw & LargePage) != 0) continue;
            const pd = @as(*PageTable, @ptrFromInt(pdpte.toFrame()));
            var p2: usize = 0;
            while (p2 < 512) : (p2 += 1) {
                const pde = &pd.entries[p2];
                if (!pde.isPresent()) continue;
                const pde_raw = @as(u64, @bitCast(pde.*));
                if ((pde_raw & LargePage) != 0) continue;
                const pt = @as(*PageTable, @ptrFromInt(pde.toFrame()));
                var p1: usize = 0;
                while (p1 < 512) : (p1 += 1) {
                    const pte = &pt.entries[p1];
                    if (!pte.isPresent() or !pte.user) continue;
                    const virt = (@as(u64, @intCast(p4)) << 39) |
                        (@as(u64, @intCast(p3)) << 30) |
                        (@as(u64, @intCast(p2)) << 21) |
                        (@as(u64, @intCast(p1)) << 12);
                    const phys = pte.toFrame();
                    const pte_raw = @as(u64, @bitCast(pte.*));
                    if (!cb(ctx, virt, phys, pte_raw)) return false;
                }
            }
        }
    }
    return true;
}

/// 释放 PML4 **用户子树**（索引 **0..255**，即 NT/x86_64 典型布局下 canonical **低半区** 的 PML4 槽位）。
/// 索引 **256..511** 保留给内核共享映射（与内核 `CR3` 可能共享中间页表物理页），此处**绝不**释放，避免误拆内核页表。
/// 用户态应仅通过 **User** 位置位的叶映射访问低半区；高半区内核映射由各进程页表共享副本提供（与 `docs/cn/VM_ISOLATION.md` 一致）。
/// 调用后须由调用方释放顶层 `pml4_phys` 页本身（若专属于该进程）。
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

/// 叶级可写位（大页则看 PDE；否则看 PTE）。无映射返回 false。
pub fn isPageWritable(pml4_phys: u64, virt: u64) bool {
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
    const pde_raw = @as(u64, @bitCast(pde.*));
    if ((pde_raw & LargePage) != 0) {
        return pde.writable;
    }
    const pt = @as(*PageTable, @ptrFromInt(pde.toFrame()));
    const pte = &pt.entries[v.ptIndex()];
    if (!pte.isPresent()) return false;
    return pte.writable;
}

pub fn translateVirtualToPhysical(pml4_phys: u64, virt: u64) ?u64 {
    const v = VirtAddr{ .value = virt };
    const pml4 = @as(*PageTable, @ptrFromInt(pml4_phys));
    const pml4e = &pml4.entries[v.pml4Index()];
    if (!pml4e.isPresent()) return null;
    const pdpt = @as(*PageTable, @ptrFromInt(pml4e.toFrame()));
    const pdpte = &pdpt.entries[v.pdptIndex()];
    if (!pdpte.isPresent()) return null;
    const pd = @as(*PageTable, @ptrFromInt(pdpte.toFrame()));
    const pde = &pd.entries[v.pdIndex()];
    if (!pde.isPresent()) return null;
    const pde_raw = @as(u64, @bitCast(pde.*));
    if ((pde_raw & LargePage) != 0) {
        return (pde_raw & 0x0000_ffff_ffe0_0000) | (virt & huge_page_mask);
    }
    const pt = @as(*PageTable, @ptrFromInt(pde.toFrame()));
    const pte = &pt.entries[v.ptIndex()];
    if (!pte.isPresent()) return null;
    const pm: u64 = @intCast(page_mask);
    return pte.toFrame() | (virt & pm);
}

pub const page_size = PAGE_SIZE;
pub const page_mask = PAGE_MASK;

const std = @import("std");

test "x86_64 2MiB identity address recombine" {
    const virt: u64 = 0x123456;
    const entry_base: u64 = 0x400000;
    const pa = (entry_base & 0x0000_ffff_ffe0_0000) | (virt & huge_page_mask);
    try std.testing.expectEqual(@as(u64, 0x400000) | (virt & huge_page_mask), pa);
}

var release_user_half_free_count: usize = 0;

fn releaseUserHalfCountingFree(ctx: ?*anyopaque, phys: u64) void {
    _ = ctx;
    _ = phys;
    release_user_half_free_count += 1;
}

test "releaseUserHalfAddressSpace frees leaf and page-table pages" {
    var backing: [5 * 4096]u8 align(4096) = undefined;
    const pml4_mem = backing[0..4096];
    const pdpt_mem = backing[4096 .. 2 * 4096];
    const pd_mem = backing[2 * 4096 .. 3 * 4096];
    const pt_mem = backing[3 * 4096 .. 4 * 4096];
    const data_mem = backing[4 * 4096 .. 5 * 4096];

    const pml4_phys = @intFromPtr(pml4_mem.ptr);
    const pdpt_phys = @intFromPtr(pdpt_mem.ptr);
    const pd_phys = @intFromPtr(pd_mem.ptr);
    const pt_phys = @intFromPtr(pt_mem.ptr);
    const data_phys = @intFromPtr(data_mem.ptr);

    const pml4 = @as(*PageTable, @ptrCast(pml4_mem.ptr));
    pml4.zero();
    const pdpt = @as(*PageTable, @ptrCast(pdpt_mem.ptr));
    pdpt.zero();
    const pd = @as(*PageTable, @ptrCast(pd_mem.ptr));
    pd.zero();
    const pt = @as(*PageTable, @ptrCast(pt_mem.ptr));
    pt.zero();

    // VA 0x4000_0000：PML4[0] -> PDPT[1] -> PD[0] -> PT[0] -> data
    pml4.entries[0] = PageTableEntry.fromFrame(pdpt_phys, Present | Write);
    pml4.entries[0].accessed = true;
    pdpt.entries[1] = PageTableEntry.fromFrame(pd_phys, Present | Write);
    pdpt.entries[1].accessed = true;
    pd.entries[0] = PageTableEntry.fromFrame(pt_phys, Present | Write);
    pd.entries[0].accessed = true;
    pt.entries[0] = PageTableEntry.fromFrame(data_phys, Present | Write | User);
    pt.entries[0].accessed = true;

    release_user_half_free_count = 0;
    releaseUserHalfAddressSpace(pml4_phys, releaseUserHalfCountingFree, null);

    try std.testing.expectEqual(@as(usize, 4), release_user_half_free_count);
}
