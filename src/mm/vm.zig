//! Virtual Memory Manager
//! NT style: provides address space, map/unmap, permissions
//! Kernel provides mechanism; policy is in user-space services

const builtin = @import("builtin");
const arch = @import("../arch.zig");
const paging = arch.impl.paging;
const FrameAllocator = @import("frame.zig").FrameAllocator;

/// `mapIdentityByteRange` 统计：x86_64 填 `x86_huge_2m`，LoongArch 填 `la_blocks_32m`，其余为 `leaf_pages`。
pub const IdentityMapStats = struct {
    x86_huge_2m: usize = 0,
    la_blocks_32m: usize = 0,
    leaf_pages: usize = 0,
};

/// 按架构快速建立 **identity** 映射 `[range_start, range_start+range_len)`（`virt==phys`）。
/// - x86_64：优先 2MiB 大页，头尾不足 2MiB 用 4KiB（`mapPage` 遇大页会按需拆分）。
/// - LoongArch：优先 32MiB 整块填第三级表（2048×16KiB），余量逐 `mapPage`。
/// - 其它架构：逐叶映射。
pub fn mapIdentityByteRange(space: *AddressSpace, range_start: u64, range_len: u64, flags: MapFlags) ?IdentityMapStats {
    if (range_len == 0) return IdentityMapStats{};
    const ps: u64 = @intCast(paging.page_size);
    var va = range_start & ~(ps - 1);
    const range_end = range_start + range_len;
    var st = IdentityMapStats{};
    const pflags = flags.toPagingFlags();

    while (va < range_end) {
        if (builtin.cpu.arch == .x86_64 and @hasDecl(paging, "map2MiBPage") and @hasDecl(paging, "HUGE_PAGE_SIZE")) {
            const huge: u64 = paging.HUGE_PAGE_SIZE;
            if ((va % huge) == 0 and va + huge <= range_end) {
                if (paging.map2MiBPage(space.pml4_phys, va, va, pflags, allocFrameCb, space.allocator)) {
                    st.x86_huge_2m += 1;
                    va += huge;
                    continue;
                }
            }
        }
        if (builtin.cpu.arch == .loongarch64 and
            @hasDecl(paging, "mapIdentity32MiBlock") and
            @hasDecl(paging, "identity_bulk_bytes"))
        {
            const blk: u64 = paging.identity_bulk_bytes;
            if ((va % blk) == 0 and va + blk <= range_end) {
                if (paging.mapIdentity32MiBlock(space.pml4_phys, va, pflags, allocFrameCb, space.allocator)) {
                    st.la_blocks_32m += 1;
                    va += blk;
                    continue;
                }
            }
        }
        if (!space.mapPage(va, va, flags)) return null;
        st.leaf_pages += 1;
        va += ps;
    }
    return st;
}

pub const MapFlags = struct {
    writable: bool = false,
    user: bool = false,
    executable: bool = true,
    no_cache: bool = false,

    pub fn toPagingFlags(self: MapFlags) u64 {
        var f: u64 = paging.Present | paging.Accessed;
        if (self.writable) f |= paging.Write;
        if (self.user) f |= paging.User;
        if (!self.executable) f |= paging.NoExecute;
        if (self.no_cache) f |= paging.CacheDisable;
        return f;
    }
};

/// x86_64 用户态 canonical 低半区上界（文档常量；页表须与 `arch` 一致）。Ref: Intel SDM — canonical addresses.
pub const USER_VA_MAX_HINT_X86_64: u64 = 0x0000_7FFF_FFFF_FFFF;

/// NT 6.1 虚拟分配阶段（公开文档：`ZwAllocateVirtualMemory` / `VirtualAlloc` 的 MEM_RESERVE vs MEM_COMMIT）。
/// - **Reserved**：VA 区间计入地址空间，无页表 Present / 无物理页。
/// - **Committed**：页表项有效并具备后备（匿名页或段视图）。
/// 当前内核中 `mapPage` / `mapPageAlloc` / `mapRange` 表示已提交映射；独占式 VAD + 先 reserve 再按需 commit 为后续里程碑。
pub const VirtualCommitPhase = enum(u8) {
    reserved = 0,
    committed = 1,
};

/// 与 `NtAllocateVirtualMemory` 常见失败分类的语义对应（返回值仍用 `NtStatus` 在 syscall 层映射）。
pub const VirtualAllocFailureKind = enum(u8) {
    none = 0,
    invalid_parameter = 1,
    no_memory = 2,
    conflicting_addresses = 3,
    access_denied = 4,
    not_committed = 5,
};

/// 当前内核地址空间（供 PCI MMIO / VirtIO 等在驱动层做 identity map）
var g_kernel_space: ?*AddressSpace = null;

pub fn bindKernelAddressSpace(space: *AddressSpace) void {
    g_kernel_space = space;
}

pub fn kernelAddressSpace() ?*AddressSpace {
    return g_kernel_space;
}

fn freeFrameForRelease(ctx: ?*anyopaque, phys: u64) void {
    const a = ctx orelse return;
    const fa: *FrameAllocator = @ptrCast(@alignCast(a));
    fa.free(phys);
}

/// 释放进程 **用户半区** 页表子树与叶帧，并 `free` 顶层 PML4；调用方须将 `AddressSpace` 置为不再使用且 **不得** 再以该 CR3 运行。
/// 调用方还须保证 **无** 仍在运行的线程持有该 `pml4_phys` 作为当前 CR3（见 `ps/process.zig` `terminateProcess` 与调度器配合）。
pub fn releaseProcessAddressSpace(space: *AddressSpace) void {
    if (@hasDecl(paging, "releaseUserHalfAddressSpace")) {
        paging.releaseUserHalfAddressSpace(space.pml4_phys, freeFrameForRelease, @ptrCast(space.allocator));
    }
    space.reserved_count = 0;
    @memset(&space.reserved_base, 0);
    @memset(&space.reserved_pages, 0);
    space.section_view_count = 0;
    @memset(&space.section_view_base, 0);
    @memset(&space.section_view_pages, 0);
    @memset(&space.section_view_obj, 0);
    space.vma_len = 0;
    @memset(&space.vma_base, 0);
    @memset(&space.vma_pages, 0);
    @memset(&space.vma_user, false);
    @memset(&space.vma_writable, false);
    space.allocator.free(space.pml4_phys);
    if (builtin.cpu.arch == .x86_64) {
        const tlb = @import("../hal/x86_64/tlb_broadcast.zig");
        tlb.requestGlobalFlushStub();
    }
}

fn vmaRangeEnd(base: u64, num_pages: u32) u64 {
    return base + @as(u64, num_pages) * @as(u64, @intCast(paging.page_size));
}

fn vmaOverlaps(a0: u64, a1: u64, b0: u64, b1: u64) bool {
    return !(a1 <= b0 or b1 <= a0);
}

/// Win32 `PAGE_*` → x86_64 叶 PTE 标志（用户页）。未覆盖的组合返回 `null`。
fn ntProtectToPteFlags(prot: u32) ?u64 {
    const base = paging.Present | paging.User | paging.Accessed;
    return switch (prot) {
        0x02 => base | paging.NoExecute,
        0x04, 0x08, 0x80 => base | paging.Write | paging.NoExecute,
        0x10, 0x20 => base,
        0x40 => base | paging.Write,
        else => null,
    };
}

/// 通用 VMA 槽位（与 `MEM_RESERVE` 记录互补；供 `NtAllocateVirtualMemory` 等逐步接线）。
pub const max_vma: usize = 48;

pub const VmAreaDesc = struct {
    user: bool,
    writable: bool,
    from_reserved_record: bool,
};

pub fn vmaInsert(space: *AddressSpace, base: u64, num_pages: u32, user: bool, writable: bool) bool {
    if (num_pages == 0 or space.vma_len >= max_vma) return false;
    const end = vmaRangeEnd(base, num_pages);
    var i: u8 = 0;
    while (i < space.vma_len) : (i += 1) {
        const b = space.vma_base[i];
        const e = vmaRangeEnd(b, space.vma_pages[i]);
        if (vmaOverlaps(base, end, b, e)) return false;
    }
    var ri: u8 = 0;
    while (ri < space.reserved_count) : (ri += 1) {
        const b = space.reserved_base[ri];
        const e = vmaRangeEnd(b, space.reserved_pages[ri]);
        if (vmaOverlaps(base, end, b, e)) return false;
    }
    const slot = space.vma_len;
    space.vma_base[slot] = base;
    space.vma_pages[slot] = num_pages;
    space.vma_user[slot] = user;
    space.vma_writable[slot] = writable;
    space.vma_len += 1;
    return true;
}

pub fn vmaRemove(space: *AddressSpace, base: u64, num_pages: u32) bool {
    if (num_pages == 0) return false;
    const end = vmaRangeEnd(base, num_pages);
    var i: u8 = 0;
    while (i < space.vma_len) : (i += 1) {
        const b = space.vma_base[i];
        const e = vmaRangeEnd(b, space.vma_pages[i]);
        if (b == base and e == end) {
            const last = space.vma_len - 1;
            space.vma_base[i] = space.vma_base[last];
            space.vma_pages[i] = space.vma_pages[last];
            space.vma_user[i] = space.vma_user[last];
            space.vma_writable[i] = space.vma_writable[last];
            space.vma_len -= 1;
            return true;
        }
    }
    return false;
}

pub fn vmaFind(space: *const AddressSpace, va: u64) ?VmAreaDesc {
    var i: u8 = 0;
    while (i < space.vma_len) : (i += 1) {
        const b = space.vma_base[i];
        const e = vmaRangeEnd(b, space.vma_pages[i]);
        if (va >= b and va < e) {
            return .{
                .user = space.vma_user[i],
                .writable = space.vma_writable[i],
                .from_reserved_record = false,
            };
        }
    }
    var ri: u8 = 0;
    while (ri < space.reserved_count) : (ri += 1) {
        const b = space.reserved_base[ri];
        const e = vmaRangeEnd(b, space.reserved_pages[ri]);
        if (va >= b and va < e) {
            return .{
                .user = true,
                .writable = true,
                .from_reserved_record = true,
            };
        }
    }
    return null;
}

/// 将 `[phys_base, phys_base+size)` 按页做 identity 映射（MMIO：可写、不可执行、uncached）
/// Intel 核显 BAR、VirtIO PCI 等均须经此路径或 `remapIdentityVirtPageUncached`，避免 WB 缓存导致 MMIO 读写异常。
pub fn mapDeviceMmioIdentity(phys_base: u64, size: u64) bool {
    // 尚无内核页表时（如仍沿用 UEFI 映射）：假定固件已映射 MMIO，跳过以免阻塞 VirtIO attach
    const space = g_kernel_space orelse return true;
    if (size == 0) return true;
    const page_size = paging.page_size;
    const start = phys_base & ~@as(u64, page_size - 1);
    const end = (phys_base + size + page_size - 1) & ~@as(u64, page_size - 1);
    var addr = start;
    const flags = MapFlags{ .writable = true, .executable = false, .no_cache = true };
    while (addr < end) : (addr += page_size) {
        if (space.mapPage(addr, addr, flags)) continue;
        if (space.getPhysical(addr)) |p| {
            if (p == addr) {
                // LoongArch 等：启动时整段 identity 映射已为 WB/CC，须改为非缓存才能可靠访问 PCI BAR / VirtIO MMIO
                _ = space.unmapPage(addr);
                if (!space.mapPage(addr, addr, flags)) return false;
                continue;
            }
        }
        return false;
    }
    return true;
}

/// 当前内核页表下虚址对应的物理地址（VirtIO 环须用 GPA）；无绑定页表时假定 identity。
pub fn kernelVirtToPhys(virt: usize) usize {
    const space = g_kernel_space orelse return virt;
    return space.getPhysical(virt) orelse virt;
}

/// 将已 identity 映射的内核页改为非缓存，使 PCI DMA 与 CPU 对同一 GPA 的观测一致（见 H7：VA≠PA 时仅修正 GPA 仍不足）。
/// VirtIO-Input 事件环页在 LoongArch 上经 `virtio_input_pci.remapInstQueueDmaUncached` 整页调用本函数。
pub fn remapIdentityVirtPageUncached(virt: usize) bool {
    const space = g_kernel_space orelse return true;
    const page_size = paging.page_size;
    const va = virt & ~@as(usize, page_size - 1);
    const phys = space.getPhysical(va) orelse return false;
    _ = space.unmapPage(va);
    return space.mapPage(va, phys, .{ .writable = true, .executable = false, .no_cache = true });
}

/// 将 `[virt_base, virt_base+size)` 覆盖到的各页改为 **identity、可写、非缓存**（LoongArch：MAT_WUC）。
/// UEFI GOP / ramfb 扫描输出通常不经 CPU cache 一致性；若整段 identity 映射为 CC，桌面写入可能留在 cache，QEMU 仍显示固件画面。
pub fn remapIdentityRangeUncached(virt_base: usize, size: usize) bool {
    const space = g_kernel_space orelse return true;
    if (size == 0) return true;
    const ps = paging.page_size;
    const end = virt_base + size;
    const va0 = virt_base & ~@as(usize, ps - 1);
    const va1 = (end + ps - 1) & ~@as(usize, ps - 1);
    var va = va0;
    while (va < va1) : (va += ps) {
        const phys = space.getPhysical(va) orelse return false;
        _ = space.unmapPage(va);
        if (!space.mapPage(va, phys, .{ .writable = true, .executable = false, .no_cache = true }))
            return false;
    }
    if (@hasDecl(paging, "loadCr3")) {
        paging.loadCr3(space.pml4_phys);
    }
    return true;
}

pub const max_reserved_regions: usize = 32;
pub const max_section_views: usize = 32;

pub const AddressSpace = struct {
    pml4_phys: u64,
    allocator: *FrameAllocator,
    /// `MEM_RESERVE` 未提交区间（无 Present PTE）；与 `#PF` 惰性提交配合。
    reserved_count: u8 = 0,
    reserved_base: [max_reserved_regions]u64 = @splat(0),
    reserved_pages: [max_reserved_regions]u32 = @splat(0),
    /// `NtMapViewOfSection` 登记的区间，供 `NtUnmapViewOfSection` 成组解除映射。
    section_view_count: u8 = 0,
    section_view_base: [max_section_views]u64 = @splat(0),
    section_view_pages: [max_section_views]u32 = @splat(0),
    section_view_obj: [max_section_views]u64 = @splat(0),
    /// 显式 VMA 记录（与 `reserved_*` 不重复登记：reserve 仅走 `reserved_*`；`vmaInsert` 用于已映射或其它视图）。
    vma_len: u8 = 0,
    vma_base: [max_vma]u64 = @splat(0),
    vma_pages: [max_vma]u32 = @splat(0),
    vma_user: [max_vma]bool = @splat(false),
    vma_writable: [max_vma]bool = @splat(false),

    pub fn reserveVirtualRange(self: *AddressSpace, virt_base: u64, num_pages: u32) bool {
        if (self.reserved_count >= max_reserved_regions) return false;
        if (num_pages == 0) return false;
        const i = self.reserved_count;
        self.reserved_base[i] = virt_base;
        self.reserved_pages[i] = num_pages;
        self.reserved_count += 1;
        return true;
    }

    fn removeReservedCovering(self: *AddressSpace, virt_base: u64, num_pages: u64) void {
        if (num_pages == 0) return;
        const page_size = paging.page_size;
        const end = virt_base + num_pages * page_size;
        var i: u8 = 0;
        while (i < self.reserved_count) {
            const b = self.reserved_base[i];
            const n = @as(u64, self.reserved_pages[i]) * page_size;
            const e = b + n;
            if (b == virt_base and e == end) {
                const last = self.reserved_count - 1;
                self.reserved_base[i] = self.reserved_base[last];
                self.reserved_pages[i] = self.reserved_pages[last];
                self.reserved_count -= 1;
                continue;
            }
            i += 1;
        }
    }

    /// 若 `fault_va` 落在某 `MEM_RESERVE` 区间内且尚无 PTE，则提交一页匿名映射。
    pub fn tryLazyCommitFault(self: *AddressSpace, fault_va: u64) bool {
        const page_size = paging.page_size;
        const page = fault_va & ~@as(u64, page_size - 1);
        if (self.getPhysical(page)) |_| return false;
        var ri: u8 = 0;
        while (ri < self.reserved_count) : (ri += 1) {
            const b = self.reserved_base[ri];
            const e = b + @as(u64, self.reserved_pages[ri]) * page_size;
            if (fault_va >= b and fault_va < e) {
                const flags = MapFlags{ .writable = true, .user = true, .executable = false };
                return self.mapPageAlloc(page, flags) != null;
            }
        }
        return false;
    }

    pub fn mapPage(self: *AddressSpace, virt: u64, phys: u64, flags: MapFlags) bool {
        return paging.mapPage(
            self.pml4_phys,
            virt,
            phys,
            flags.toPagingFlags(),
            allocFrameCb,
            self.allocator,
        );
    }

    pub fn mapPageAlloc(self: *AddressSpace, virt: u64, flags: MapFlags) ?u64 {
        const phys = self.allocator.allocZeroed() orelse return null;
        if (!self.mapPage(virt, phys, flags)) {
            self.allocator.free(phys);
            return null;
        }
        return phys;
    }

    /// `NtProtectVirtualMemory` 路径：按 Win32 `PAGE_*` 更新已映射叶项。未映射页返回 `false`。
    /// Ref: https://learn.microsoft.com/windows/win32/memory/memory-protection-constants
    pub fn protectVirtualRange(self: *AddressSpace, base: u64, size_bytes: u64, new_protect: u32) bool {
        if (size_bytes == 0) return false;
        if (!@hasDecl(paging, "protectLeafPage")) return false;
        const pte_flags = ntProtectToPteFlags(new_protect) orelse return false;
        const ps: u64 = @intCast(paging.page_size);
        var va = base & ~(ps - 1);
        const end = base + size_bytes;
        while (va < end) {
            if (!paging.protectLeafPage(
                self.pml4_phys,
                va,
                pte_flags,
                allocFrameCb,
                @ptrCast(self.allocator),
            )) return false;
            va += ps;
        }
        return true;
    }

    pub fn unmapPage(self: *AddressSpace, virt: u64) ?u64 {
        const phys = self.getPhysical(virt) orelse return null;
        _ = paging.unmapPage(self.pml4_phys, virt, allocFrameCb, @ptrCast(self.allocator));
        return phys;
    }

    pub fn unmapAndFree(self: *AddressSpace, virt: u64) bool {
        const phys = self.unmapPage(virt) orelse return false;
        self.allocator.free(phys);
        return true;
    }

    pub fn getPhysical(self: *AddressSpace, virt: u64) ?u64 {
        if (@hasDecl(paging, "translateVirtualToPhysical")) {
            return paging.translateVirtualToPhysical(self.pml4_phys, virt);
        }
        const v = paging.VirtAddr{ .value = virt };
        const pml4 = @as(*paging.PageTable, @ptrFromInt(self.pml4_phys));
        const pml4e = &pml4.entries[v.pml4Index()];
        if (!pml4e.isPresent()) return null;
        const pdpt = @as(*paging.PageTable, @ptrFromInt(pml4e.toFrame()));
        const pdpte = &pdpt.entries[v.pdptIndex()];
        if (!pdpte.isPresent()) return null;
        const pd = @as(*paging.PageTable, @ptrFromInt(pdpte.toFrame()));
        const pde = &pd.entries[v.pdIndex()];
        if (!pde.isPresent()) return null;
        const pt = @as(*paging.PageTable, @ptrFromInt(pde.toFrame()));
        const pte = &pt.entries[v.ptIndex()];
        if (!pte.isPresent()) return null;
        return pte.toFrame() | (virt & paging.page_mask);
    }

    pub fn activate(self: *AddressSpace) void {
        paging.loadCr3(self.pml4_phys);
    }

    pub fn recordSectionView(self: *AddressSpace, base: u64, pages: u32, sec_ptr: u64) bool {
        if (self.section_view_count >= max_section_views) return false;
        const i = self.section_view_count;
        self.section_view_base[i] = base;
        self.section_view_pages[i] = pages;
        self.section_view_obj[i] = sec_ptr;
        self.section_view_count += 1;
        return true;
    }

    /// 按视图基址查找并移除记录，返回页数。
    pub fn takeSectionView(self: *AddressSpace, base: u64) ?u32 {
        var i: u8 = 0;
        while (i < self.section_view_count) : (i += 1) {
            if (self.section_view_base[i] == base) {
                const pages = self.section_view_pages[i];
                const last = self.section_view_count - 1;
                self.section_view_base[i] = self.section_view_base[last];
                self.section_view_pages[i] = self.section_view_pages[last];
                self.section_view_obj[i] = self.section_view_obj[last];
                self.section_view_count -= 1;
                return pages;
            }
        }
        return null;
    }
};

fn allocFrameCb(ctx: ?*anyopaque) ?u64 {
    const a = ctx orelse return null;
    return @as(*FrameAllocator, @ptrCast(@alignCast(a))).allocZeroed();
}

pub fn createAddressSpace(allocator: *FrameAllocator) ?AddressSpace {
    const pml4_phys = allocator.allocZeroed() orelse return null;
    return .{
        .pml4_phys = pml4_phys,
        .allocator = allocator,
    };
}

pub fn handleLazyCommitFault(space: *AddressSpace, fault_va: u64) bool {
    return space.tryLazyCommitFault(fault_va);
}

/// 是否与任一 `MEM_RESERVE` 记录区间重叠（用于选 `base==0` 时的空洞搜索）。
pub fn isVirtInReservedRange(space: *const AddressSpace, virt_base: u64, num_pages: usize) bool {
    const ps: u64 = @intCast(paging.page_size);
    const end = virt_base + @as(u64, @intCast(num_pages)) * ps;
    var ri: u8 = 0;
    while (ri < space.reserved_count) : (ri += 1) {
        const b = space.reserved_base[ri];
        const e = b + @as(u64, space.reserved_pages[ri]) * ps;
        if (!(end <= b or virt_base >= e)) return true;
    }
    return false;
}

pub fn mapRange(space: *AddressSpace, virt_base: u64, num_pages: usize, flags: MapFlags) bool {
    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        const virt = virt_base + i * paging.page_size;
        if (space.mapPageAlloc(virt, flags) == null) {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                _ = space.unmapAndFree(virt_base + j * paging.page_size);
            }
            return false;
        }
    }
    return true;
}

pub fn unmapRange(space: *AddressSpace, virt_base: u64, num_pages: usize) void {
    space.removeReservedCovering(virt_base, @intCast(num_pages));
    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        _ = space.unmapAndFree(virt_base + i * paging.page_size);
    }
}

/// `MmFreeVirtualMemory` 语义子集：解除映射并尝试自 `vma` 表移除精确匹配项。
pub fn mmFreeVirtualRange(space: *AddressSpace, virt_base: u64, num_pages: u32) void {
    unmapRange(space, virt_base, num_pages);
    _ = vmaRemove(space, virt_base, num_pages);
}
