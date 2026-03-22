//! RISC-V 64 Sv39 page table (3-level, 4KB pages)
//! VPN[2] -> VPN[1] -> VPN[0] -> 4KB page
//! Uses SATP register for page table base

pub const page_size: usize = 4096;
pub const page_mask: usize = page_size - 1;

const VPN2_SHIFT: u6 = 30;
const VPN1_SHIFT: u6 = 21;
const VPN0_SHIFT: u6 = 12;
const VPN_MASK: u64 = 0x1FF;

pub const V: u64 = 1 << 0;
pub const R: u64 = 1 << 1;
pub const W: u64 = 1 << 2;
pub const X: u64 = 1 << 3;
pub const U: u64 = 1 << 4;
pub const G: u64 = 1 << 5;
pub const A: u64 = 1 << 6;
pub const D: u64 = 1 << 7;

pub const Present: u64 = V;
pub const Write: u64 = W;
pub const User: u64 = U;
pub const WriteThrough: u64 = 0;
pub const CacheDisable: u64 = 0;
pub const Accessed: u64 = A;
pub const Dirty: u64 = D;
pub const LargePage: u64 = 0;
pub const Global: u64 = G;
pub const NoExecute: u64 = 0;

const PPN_MASK: u64 = 0x003F_FFFF_FFFF_FC00;

fn ppnToAddr(ppn: u64) u64 {
    return (ppn >> 10) << 12;
}

fn addrToPpn(addr: u64) u64 {
    return (addr >> 12) << 10;
}

pub const PageTableEntry = packed struct(u64) {
    raw: u64 = 0,

    pub fn isPresent(self: PageTableEntry) bool {
        return (self.raw & V) != 0;
    }

    pub fn isLeaf(self: PageTableEntry) bool {
        return (self.raw & (R | W | X)) != 0;
    }

    pub fn toFrame(self: PageTableEntry) u64 {
        return ppnToAddr(self.raw & PPN_MASK);
    }

    pub fn fromFrame(frame: u64, flags: u64) PageTableEntry {
        return .{ .raw = addrToPpn(frame) | flags | V | A | D | R };
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
        return @truncate((self.value >> VPN2_SHIFT) & VPN_MASK);
    }
    pub fn pdptIndex(self: VirtAddr) u9 {
        return @truncate((self.value >> VPN1_SHIFT) & VPN_MASK);
    }
    pub fn pdIndex(self: VirtAddr) u9 {
        return @truncate((self.value >> VPN1_SHIFT) & VPN_MASK);
    }
    pub fn ptIndex(self: VirtAddr) u9 {
        return @truncate((self.value >> VPN0_SHIFT) & VPN_MASK);
    }
};

pub const AllocFrameFn = *const fn (?*anyopaque) ?u64;

pub fn mapPage(
    root_phys: u64,
    virt: u64,
    phys: u64,
    flags: u64,
    alloc_frame: AllocFrameFn,
    alloc_ctx: ?*anyopaque,
) bool {
    const v = VirtAddr{ .value = virt };
    const aligned_phys = phys & ~@as(u64, page_mask);

    const root = @as(*PageTable, @ptrFromInt(root_phys));

    const vpn2 = v.pml4Index();
    var l2e = &root.entries[vpn2];
    if (!l2e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l2e.* = .{ .raw = addrToPpn(frame) | V };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const l1_table = @as(*PageTable, @ptrFromInt(l2e.toFrame()));
    const vpn1 = v.pdptIndex();
    var l1e = &l1_table.entries[vpn1];
    if (!l1e.isPresent()) {
        const frame = alloc_frame(alloc_ctx) orelse return false;
        l1e.* = .{ .raw = addrToPpn(frame) | V };
        @as(*PageTable, @ptrFromInt(frame)).zero();
    }

    const l0_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const vpn0 = v.ptIndex();
    var l0e = &l0_table.entries[vpn0];
    if (l0e.isPresent()) return false;
    l0e.* = PageTableEntry.fromFrame(aligned_phys, flags | W | X);
    return true;
}

pub fn unmapPage(root_phys: u64, virt: u64) bool {
    const v = VirtAddr{ .value = virt };
    const root = @as(*PageTable, @ptrFromInt(root_phys));
    const l2e = &root.entries[v.pml4Index()];
    if (!l2e.isPresent()) return false;
    const l1_table = @as(*PageTable, @ptrFromInt(l2e.toFrame()));
    const l1e = &l1_table.entries[v.pdptIndex()];
    if (!l1e.isPresent()) return false;
    const l0_table = @as(*PageTable, @ptrFromInt(l1e.toFrame()));
    const l0e = &l0_table.entries[v.ptIndex()];
    if (!l0e.isPresent()) return false;
    l0e.* = .{};
    asm volatile ("sfence.vma zero, zero");
    return true;
}

pub fn loadCr3(phys: u64) void {
    const ppn = phys >> 12;
    const satp_val: u64 = (8 << 60) | ppn;
    asm volatile ("csrw satp, %[val]\nsfence.vma zero, zero"
        :
        : [val] "r" (satp_val)
    );
}
