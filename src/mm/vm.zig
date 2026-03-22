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
