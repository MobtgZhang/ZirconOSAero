//! Virtual Memory Manager
//! NT style: provides address space, map/unmap, permissions
//! Kernel provides mechanism; policy is in user-space services

const arch = @import("../arch.zig");
const paging = arch.impl.paging;
const FrameAllocator = @import("frame.zig").FrameAllocator;

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

/// 当前内核地址空间（供 PCI MMIO / VirtIO 等在驱动层做 identity map）
var g_kernel_space: ?*AddressSpace = null;

pub fn bindKernelAddressSpace(space: *AddressSpace) void {
    g_kernel_space = space;
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

pub const AddressSpace = struct {
    pml4_phys: u64,
    allocator: *FrameAllocator,

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

    pub fn unmapPage(self: *AddressSpace, virt: u64) ?u64 {
        const phys = self.getPhysical(virt) orelse return null;
        _ = paging.unmapPage(self.pml4_phys, virt);
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

pub fn mapRange(space: *AddressSpace, virt_base: u64, num_pages: usize, flags: MapFlags) bool {
    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        const virt = virt_base + i * paging.page_size;
        if (space.mapPageAlloc(virt, flags) == null) {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                space.unmapAndFree(virt_base + j * paging.page_size);
            }
            return false;
        }
    }
    return true;
}

pub fn unmapRange(space: *AddressSpace, virt_base: u64, num_pages: usize) void {
    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        space.unmapAndFree(virt_base + i * paging.page_size);
    }
}
